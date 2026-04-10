const std = @import("std");
const sparse = @import("sparse.zig");
const PagedMemory = @import("PagedMemory.zig");
const u256_ops = @import("u256_ops.zig");
const ChainMod = @import("Chain.zig");
const ObjectTreeMod = @import("ObjectTree.zig");
pub const Chain = ChainMod.Chain;
pub const Address = ChainMod.Address;
pub const ZERO_ADDRESS = ChainMod.ZERO_ADDRESS;
pub const addressFromU256 = ChainMod.addressFromU256;
pub const addressToU256 = ChainMod.addressToU256;
const ObjectTree = ObjectTreeMod.ObjectTree;

const Self = @This();

/// Re-exported page constants for backward compatibility.
pub const PAGE_BITS = PagedMemory.PAGE_BITS;
pub const PAGE_SIZE = PagedMemory.PAGE_SIZE;
pub const Page = PagedMemory.Page;

/// Strategy for memory accesses that exceed our modeling capacity.
///
/// In `.strict` (default) mode, oversized or overflowing memory accesses
/// raise `error.MemoryRangeTooLarge`, which the interpreter's top-level
/// catch converts to a revert. This approximates real-EVM out-of-gas
/// behavior on infeasible memory expansion: the access cannot occur and
/// the execution halts.
///
/// In `.lax` mode (only enabled under `--solc-compat`), the same accesses
/// silently skip the side effect but allow execution to continue, with
/// the trace still emitted. This matches solc's `EVMInstructionInterpreter`
/// design and is required for trace equivalence under optimizer
/// transformations that may rewrite or remove such accesses.
pub const MemoryPolicy = enum { strict, lax };

/// Maximum byte length of any single memory access in `.lax` mode.
/// Mirrors solc's `EVMInstructionInterpreter::s_maxRangeSize`.
pub const MAX_RANGE_SIZE_LAX: u256 = 0xffff;

pub const LogEntry = struct {
    /// Emitting contract address (matches EVM log structure).
    address: u256,
    data: []u8,
    topics: []u256,
};

/// Optional pluggable interface for the parts of the EVM world state that
/// the interpreter cannot derive from its own fields. All callbacks are
/// optional; missing ones return zero (the same default as the previous
/// stub behavior).
pub const WorldState = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        balance: ?*const fn (?*anyopaque, address: u256) u256 = null,
        ext_code_size: ?*const fn (?*anyopaque, address: u256) u256 = null,
        ext_code_hash: ?*const fn (?*anyopaque, address: u256) u256 = null,
        /// Read up to `dest.len` bytes of the account's code starting at
        /// `src_off`. Bytes past the end of the code must be zero-filled.
        ext_code_copy: ?*const fn (?*anyopaque, address: u256, dest: []u8, src_off: u256) void = null,
        block_hash: ?*const fn (?*anyopaque, block_num: u256) u256 = null,
        blob_hash: ?*const fn (?*anyopaque, index: u256) u256 = null,
    };

    pub fn balance(self: WorldState, addr: u256) u256 {
        const f = self.vtable.balance orelse return 0;
        return f(self.ctx, addr);
    }
    pub fn extCodeSize(self: WorldState, addr: u256) u256 {
        const f = self.vtable.ext_code_size orelse return 0;
        return f(self.ctx, addr);
    }
    pub fn extCodeHash(self: WorldState, addr: u256) u256 {
        const f = self.vtable.ext_code_hash orelse return 0;
        return f(self.ctx, addr);
    }
    pub fn extCodeCopy(self: WorldState, addr: u256, dest: []u8, src_off: u256) void {
        const f = self.vtable.ext_code_copy orelse {
            @memset(dest, 0);
            return;
        };
        f(self.ctx, addr, dest, src_off);
    }
    pub fn blockHash(self: WorldState, block_num: u256) u256 {
        const f = self.vtable.block_hash orelse return 0;
        return f(self.ctx, block_num);
    }
    pub fn blobHash(self: WorldState, index: u256) u256 {
        const f = self.vtable.blob_hash orelse return 0;
        return f(self.ctx, index);
    }
};

// ── solc-compat synthetic WorldState ─────────────────────────────────
//
// Mirrors solc's `EVMInstructionInterpreter` deterministic stubs for
// host-state queries. These exist *only* to support differential
// fuzzing equivalence — gyul's default behavior remains "missing
// callback → return 0" so spec-compliant programs are not affected.
//
// Construct via `solcCompatWorld(global)` so the vtable callbacks have
// access to `block_number`, `code`, and `address` for the formulas
// that depend on them.

fn solcCompatBalance(ctx: ?*anyopaque, addr: u256) u256 {
    if (ctx) |c| {
        const gs: *Self = @ptrCast(@alignCast(c));
        if (u256_ops.maskAddress(addr) == gs.getAddress()) return 0x22223333;
    }
    return 0x22222222;
}

fn solcCompatExtCodeSize(_: ?*anyopaque, addr: u256) u256 {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, addr, .big);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&bytes, &hash, .{});
    return std.mem.readInt(u256, &hash, .big) & 0xffffff;
}

fn solcCompatExtCodeHash(_: ?*anyopaque, addr: u256) u256 {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, addr +% 1, .big);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&bytes, &hash, .{});
    return std.mem.readInt(u256, &hash, .big);
}

fn solcCompatExtCodeCopy(ctx: ?*anyopaque, _: u256, dest: []u8, src_off: u256) void {
    @memset(dest, 0);
    const c = ctx orelse return;
    const gs: *const Self = @ptrCast(@alignCast(c));
    if (src_off >= gs.code.len) return;
    const start: usize = @intCast(src_off);
    const avail = @min(dest.len, gs.code.len - start);
    @memcpy(dest[0..avail], gs.code[start..][0..avail]);
}

fn solcCompatBlockHash(ctx: ?*anyopaque, num: u256) u256 {
    const c = ctx orelse return 0;
    const gs: *const Self = @ptrCast(@alignCast(c));
    const block_number = gs.block_number;
    // solc returns 0 unless num is in the (blockNumber - 256, blockNumber)
    // range. The formula 0xaaaaaaaa + (num - blockNumber - 256) is the
    // synthetic value, computed with u256 wrapping.
    if (num >= block_number) return 0;
    if (num +% 256 < block_number) return 0;
    return @as(u256, 0xaaaaaaaa) +% num -% block_number -% 256;
}

fn solcCompatBlobHash(_: ?*anyopaque, _: u256) u256 {
    // solc derives this from a fixed blob_commitments array. We don't
    // model blob commitments, so 0 matches gyul's default and is also
    // what solc returns when no commitment is configured for the index.
    return 0;
}

const solc_compat_vtable: WorldState.VTable = .{
    .balance = solcCompatBalance,
    .ext_code_size = solcCompatExtCodeSize,
    .ext_code_hash = solcCompatExtCodeHash,
    .ext_code_copy = solcCompatExtCodeCopy,
    .block_hash = solcCompatBlockHash,
    .blob_hash = solcCompatBlobHash,
};

/// Construct a `WorldState` whose callbacks return solc's deterministic
/// synthetic values. The returned struct holds a pointer back into the
/// supplied `GlobalState` so callbacks like `block_hash` can read its
/// block context.
pub fn solcCompatWorld(global: *Self) WorldState {
    return .{
        .ctx = @ptrCast(global),
        .vtable = &solc_compat_vtable,
    };
}

/// Static metadata for a Yul sub-object referenced by `datasize` /
/// `dataoffset`. The interpreter does not actually link sub-objects, so
/// these are user-supplied for tests / fixtures.
pub const SubObject = struct {
    /// Reported by `datasize("name")`.
    size: u256,
    /// Reported by `dataoffset("name")`.
    offset: u256,
    /// Optional raw bytes used by `datacopy`/codecopy when targeting this
    /// object — may be empty.
    data: []const u8 = &.{},
};

/// Re-exported from sparse.zig for backward compatibility.
pub const U256HashContext = sparse.U256HashContext;
pub const U256HashMap = sparse.U256HashMap;

// ── Fields ───────────────────────────────────────────────────────────

/// Paged byte-addressable memory + msize. Per-frame.
memory: PagedMemory,

/// Log entries recorded during execution. Per-frame for now; Phase 4
/// adds journal-based rollback for cross-frame correctness.
log_entries: std.ArrayListUnmanaged(LogEntry),

/// Return data from last external call.
return_data: []u8,
/// Whether return_data was allocated by the interpreter (so deinit can free it).
return_data_owned: bool,

/// Call data for current execution.
calldata: []const u8,
/// Bytecode of the executing contract. Used by `codesize`/`codecopy`.
/// In a runtime frame this points at the callee's `code_canonical`
/// cache (Phase 8); in a constructor frame `synthetic_init_blob`
/// overrides it. Empty by default for legacy / bare-block runs.
code: []const u8,
/// Synthetic init blob for the current CREATE frame: `sentinel(8 BE) ||
/// ctor_args`. When non-null, `codesize` returns its length and
/// `codecopy` reads from it instead of `code`. Owned by the frame.
/// Used only inside Phase 6 CREATE handlers; null otherwise.
synthetic_init_blob: ?[]const u8 = null,

/// Multi-account chain state. Required — every `GlobalState` belongs
/// to exactly one `Chain`. Storage / transient / immutables / balances
/// route through here keyed by `address`.
chain: *Chain,
/// True when this `GlobalState` was constructed via `init` (the
/// test/standalone convenience), in which case `deinit` also frees
/// the heap-allocated chain. False for `initForFrame`, where the chain
/// is borrowed from a longer-lived owner.
owns_chain: bool = false,

/// Optional pluggable view of the rest of the EVM world. Defaults to
/// the chain's world view; tests / solc-compat may override.
world: ?WorldState,

/// Sub-object table for the legacy flat `datasize` / `dataoffset` /
/// `datacopy` mechanism. Phase 6 introduces sentinel-based dispatch
/// for object-syntax sources; this map remains for the bare-block path.
sub_objects: std.StringHashMapUnmanaged(SubObject),

/// The currently executing Yul object, when running tree-mode source.
/// `dataoffset("name")` / `datasize("name")` look here first to find
/// child sub-objects (returning their sentinels) and per-object data
/// sections. Null in bare-block mode and in legacy tests.
current_object: ?*const ObjectTree = null,

// Execution context (immutable during execution)
caller: u256,
callvalue: u256,
address: u256,
origin: u256,
gasprice: u256,
/// True inside a STATICCALL frame (or any frame inheriting it).
/// Forbids `sstore`, `tstore`, `log*`, `create*`, `selfdestruct`, and
/// `call` with non-zero value. Phase 5 enforces this.
is_static: bool = false,
/// Contract call frame depth (NOT the same as `Interpreter.call_depth`,
/// which counts user-function recursion). Capped at 1024 in Phase 5.
frame_depth: u32 = 0,

// Block context (immutable during execution)
block_number: u256,
timestamp: u256,
coinbase: u256,
gaslimit: u256,
chainid: u256,
basefee: u256,
prevrandao: u256,
blobbasefee: u256,

// ── Trace ────────────────────────────────────────────────────────────

/// Optional writer for execution trace. Set to any writer (stderr, file,
/// buffer, etc.) to enable tracing. null = no tracing.
tracer: ?*std.Io.Writer,
/// When true, memory-writing instructions are not traced.
disable_mem_write_trace: bool,

// ── Compatibility flags ──────────────────────────────────────────────

/// Memory access policy. Default `.strict` reverts on oversized
/// accesses (matching real-EVM out-of-gas semantics). `.lax` silently
/// skips the side effect to match solc's `EVMInstructionInterpreter`.
memory_policy: MemoryPolicy,
/// Master switch for solc-compat fuzzing accommodations. When true,
/// the interpreter mimics solc's yulInterpreter quirks (synthetic
/// host stubs, trace-pointer rewriting, INVALID/SELFDESTRUCT trace
/// nuke). Default false: gyul behaves per real EVM semantics.
solc_compat: bool,

allocator: std.mem.Allocator,

// ── Init / Deinit ────────────────────────────────────────────────────

/// Build a `GlobalState` for a top-level (or test) frame against an
/// existing `Chain`. The chain pointer must outlive the returned state.
/// Per-frame fields (memory, log_entries, calldata, code) start empty.
/// Storage, immutables, and balances route through `chain` keyed by
/// `address`.
pub fn initForFrame(allocator: std.mem.Allocator, chain: *Chain, address: u256) Self {
    return .{
        .memory = PagedMemory.init(allocator),
        .log_entries = .{},
        .return_data = &.{},
        .return_data_owned = false,
        .calldata = &.{},
        .code = &.{},
        .synthetic_init_blob = null,
        .chain = chain,
        .owns_chain = false,
        // Default world is the chain's own view; tests / solc-compat
        // may overwrite this field after construction.
        .world = chain.worldState(),
        .sub_objects = .{},
        .current_object = null,
        .caller = 0,
        .callvalue = 0,
        .address = address,
        .origin = 0,
        .gasprice = 0,
        .is_static = false,
        .frame_depth = 0,
        .block_number = 0,
        .timestamp = 0,
        .coinbase = 0,
        .gaslimit = 0,
        .chainid = 0,
        .basefee = 0,
        .prevrandao = 0,
        .blobbasefee = 0,
        .tracer = null,
        .disable_mem_write_trace = false,
        .memory_policy = .strict,
        .solc_compat = false,
        .allocator = allocator,
    };
}

/// Convenience for tests and the bare-block CLI path. Heap-allocates a
/// private `Chain` owned by the returned `GlobalState`; `deinit` frees
/// both. Production callers that share a chain across frames should use
/// `initForFrame` directly.
pub fn init(allocator: std.mem.Allocator) Self {
    const chain_ptr = allocator.create(Chain) catch @panic("OOM in GlobalState.init");
    chain_ptr.* = Chain.init(allocator);
    var self = initForFrame(allocator, chain_ptr, 0);
    self.owns_chain = true;
    return self;
}

pub fn deinit(self: *Self) void {
    self.memory.deinit();
    if (self.return_data_owned) {
        self.allocator.free(self.return_data);
    }
    for (self.log_entries.items) |entry| {
        self.allocator.free(entry.data);
        self.allocator.free(entry.topics);
    }
    self.log_entries.deinit(self.allocator);
    self.sub_objects.deinit(self.allocator);
    if (self.synthetic_init_blob) |blob| self.allocator.free(blob);
    if (self.owns_chain) {
        self.chain.deinit();
        self.allocator.destroy(self.chain);
    }
}

/// Free any owned return data and reset the buffer to empty.
pub fn resetReturnData(self: *Self) void {
    if (self.return_data_owned) {
        self.allocator.free(self.return_data);
    }
    self.return_data = &.{};
    self.return_data_owned = false;
}

/// Truncate `log_entries` back to `len`, freeing the dropped entries.
/// Used by the interpreter to roll back logs on REVERT/INVALID, matching
/// real EVM behavior where state changes (including logs) emitted in the
/// reverted call frame are discarded along with the rest of the frame.
pub fn truncateLogEntries(self: *Self, len: usize) void {
    if (len >= self.log_entries.items.len) return;
    for (self.log_entries.items[len..]) |entry| {
        self.allocator.free(entry.data);
        self.allocator.free(entry.topics);
    }
    self.log_entries.shrinkRetainingCapacity(len);
}

/// Import sub-object data sections (typically from `AST.data_sections`)
/// into `sub_objects`, allowing `datasize`/`dataoffset`/`datacopy` to
/// resolve them. Sizes come from the byte length of each section; offsets
/// are accumulated sequentially in declaration order. The keys and the
/// underlying byte slices are borrowed from the source map — the caller
/// must keep it alive for the lifetime of this state.
pub fn importDataSections(self: *Self, src: *const std.StringHashMapUnmanaged([]const u8)) !void {
    var offset: u256 = 0;
    var it = src.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const data = entry.value_ptr.*;
        const size: u256 = @intCast(data.len);
        try self.sub_objects.put(self.allocator, name, .{
            .size = size,
            .offset = offset,
            .data = data,
        });
        offset +%= size;
    }
}

// ── Address-typed context getters (apply 160-bit mask) ───────────────

pub fn getAddress(self: *const Self) u256 {
    return u256_ops.maskAddress(self.address);
}
pub fn getCaller(self: *const Self) u256 {
    return u256_ops.maskAddress(self.caller);
}
pub fn getOrigin(self: *const Self) u256 {
    return u256_ops.maskAddress(self.origin);
}
pub fn getCoinbase(self: *const Self) u256 {
    return u256_ops.maskAddress(self.coinbase);
}

// ── Storage / Transient Storage (routed through Chain) ───────────────
//
// Each frame holds its own `address: u256`. Storage / transient /
// immutables are keyed in the chain by the converted 20-byte address.

pub fn currentAccountAddress(self: *const Self) Address {
    return addressFromU256(self.address);
}

pub fn sload(self: *const Self, key: u256) u256 {
    return self.chain.sload(self.currentAccountAddress(), key);
}

pub fn sstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("SSTORE", &.{ key, value }, &.{}, false);
    try self.chain.sstore(self.currentAccountAddress(), key, value);
}

pub fn tload(self: *const Self, key: u256) u256 {
    return self.chain.tload(self.currentAccountAddress(), key);
}

pub fn tstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("TSTORE", &.{ key, value }, &.{}, false);
    try self.chain.tstore(self.currentAccountAddress(), key, value);
}

// ── Trace ────────────────────────────────────────────────────────────

/// Emit a trace line: "NAME(arg1, arg2, ...) [hexdata]\n"
/// No-op if tracer is null, or if writes_memory and mem write tracing is disabled.
pub fn logTrace(self: *Self, name: []const u8, args: []const u256, data: []const u8, writes_memory: bool) std.Io.Writer.Error!void {
    const w = self.tracer orelse return;
    if (writes_memory and self.disable_mem_write_trace) return;

    try w.writeAll(name);
    try w.writeByte('(');
    for (args, 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try writeU256(w, arg);
    }
    try w.writeByte(')');
    if (data.len > 0) {
        try w.writeAll(" [0x");
        try w.printHex(data, .lower);
        try w.writeByte(']');
    }
    try w.writeByte('\n');
}

/// Format a u256 as "0x" + minimal hex digits. Zero is "0x00".
pub fn writeU256(writer: *std.Io.Writer, value: u256) std.Io.Writer.Error!void {
    if (value == 0) {
        try writer.writeAll("0x00");
        return;
    }
    const bytes: [32]u8 = @bitCast(@byteSwap(value));
    var start: usize = 0;
    while (start < 32 and bytes[start] == 0) start += 1;
    try writer.writeAll("0x");
    try writer.printHex(bytes[start..], .lower);
}

// ── Memory operations (delegated to PagedMemory, with tracing) ───────

pub fn updateMsize(self: *Self, offset: u256, len: u256) void {
    self.memory.updateMsize(offset, len);
}

/// Centralized memory access check. Mirrors solc's
/// `EVMInstructionInterpreter::accessMemory`. Behavior:
///
/// - Zero-size accesses are a no-op (no msize update, no overflow
///   check). Matches EVM semantics: a zero-length access does not
///   expand memory.
/// - For non-overflowing accesses, msize is updated unconditionally so
///   that `msize()` reflects what real EVM would have expanded to.
/// - On `(offset + size + 31)` overflow: strict mode throws
///   `error.MemoryRangeTooLarge` (the top-level `interpret()` catch
///   converts that to a revert, approximating real-EVM OOG); lax mode
///   sets msize to max u256 and returns false (matches solc).
/// - In lax mode, the additional cap `size > MAX_RANGE_SIZE_LAX` returns
///   false to skip the side effect — but msize is still updated above,
///   so trace equivalence is preserved.
/// - On strict-mode `size > maxInt(usize)`, throws (we cannot materialize
///   a buffer larger than that).
///
/// Call pattern in builtins:
///
///     if (try self.global.accessMemory(off, size)) {
///         // perform the read/write
///     }
///     self.global.logTrace(...);  // trace fires even on lax skip
pub fn accessMemory(self: *Self, offset: u256, size: u256) error{MemoryRangeTooLarge}!bool {
    if (size == 0) return true;

    // (offset + size + 31) must not wrap u256.
    const end = offset +% size;
    const overflow_end = end < offset;
    const padded = end +% 31;
    const overflow_padded = padded < end;
    if (overflow_end or overflow_padded) {
        // Match solc: signal "memory in undefined oversized state".
        if (self.memory_policy == .lax) {
            self.memory.msize = std.math.maxInt(u256);
            return false;
        }
        return error.MemoryRangeTooLarge;
    }

    // For valid (non-overflowing) ranges, expand msize regardless of
    // whether we will actually perform the side effect.
    self.memory.updateMsize(offset, size);

    // Cannot materialize buffers larger than usize.
    if (size > std.math.maxInt(usize)) {
        if (self.memory_policy == .lax) return false;
        return error.MemoryRangeTooLarge;
    }

    // Lax-mode soft cap: skip the side effect for sizes beyond what
    // solc's fuzzer wants to model, but msize is already updated.
    if (self.memory_policy == .lax and size > MAX_RANGE_SIZE_LAX) return false;

    return true;
}

pub fn getMsize(self: *const Self) u256 {
    return self.memory.getMsize();
}

/// Load 32 bytes from memory at offset as a big-endian u256.
/// Caller is responsible for calling `accessMemory` first.
pub fn memLoad(self: *Self, offset: u256) !u256 {
    return self.memory.loadWord(offset);
}

/// Store a u256 as 32 big-endian bytes at the given memory offset.
/// Caller is responsible for calling `accessMemory` and emitting any
/// trace line (the trace must appear even when lax-mode skips the
/// store, so the caller drives both sides).
pub fn memStore(self: *Self, offset: u256, value: u256) !void {
    try self.memory.storeWord(offset, value);
}

/// Store a single byte (lowest byte of value) at the given memory offset.
/// Caller is responsible for `accessMemory` and tracing — see `memStore`.
pub fn memStore8(self: *Self, offset: u256, value: u256) !void {
    try self.memory.storeByte(offset, @intCast(value & 0xFF));
}

/// Copy a range of memory bytes into the provided buffer. Bytes from
/// unallocated pages are zero-filled.
pub fn memRead(self: *const Self, offset: u256, buf: []u8) void {
    self.memory.read(offset, buf);
}

/// Write a slice of bytes into memory starting at offset.
pub fn memWrite(self: *Self, offset: u256, data: []const u8) !void {
    try self.memory.write(offset, data);
}

/// Stream a range of memory through a Keccak-256 hasher.
pub fn keccak256Range(self: *const Self, offset: u256, len: u256, out: *[32]u8) error{MemoryRangeTooLarge}!void {
    return self.memory.hashKeccak256(offset, len, out);
}

/// Zero a range of memory.
pub fn memZeroRange(self: *Self, offset: u256, len: u256) error{MemoryRangeTooLarge}!void {
    try self.memory.zero(offset, len);
}

/// Copy memory from src to dst (may overlap, ring-buffer aware,
/// sparse-aware). Caller is responsible for `accessMemory` and tracing.
pub fn memCopy(self: *Self, dst: u256, src: u256, len: u256) !void {
    try self.memory.copy(dst, src, len);
}

// ── Logging ──────────────────────────────────────────────────────────

/// Record a log entry without emitting a trace line. The caller is
/// responsible for tracing (the EVMBuiltins dispatch routes traces
/// through `traceBuiltin` so the solc-compat pointer-rewrite kicks in
/// correctly).
pub fn appendLogEntry(self: *Self, data: []const u8, topics: []const u256) !void {
    const data_copy = try self.allocator.dupe(u8, data);
    errdefer self.allocator.free(data_copy);
    const topics_copy = try self.allocator.dupe(u256, topics);
    errdefer self.allocator.free(topics_copy);
    try self.log_entries.append(self.allocator, .{
        .address = self.getAddress(),
        .data = data_copy,
        .topics = topics_copy,
    });
}

/// Convenience: trace + record. Used by tests / direct callers; the
/// EVMBuiltins dispatch instead splits these so it can route the trace
/// through `traceBuiltin` for solc-compat pointer rewriting.
pub fn addLog(self: *Self, offset: u256, data: []const u8, topics: []const u256) !void {
    var trace_args: [6]u256 = undefined;
    trace_args[0] = offset;
    trace_args[1] = data.len;
    for (topics, 0..) |t, i| {
        trace_args[2 + i] = t;
    }
    const log_names = [_][]const u8{ "LOG0", "LOG1", "LOG2", "LOG3", "LOG4" };
    try self.logTrace(log_names[topics.len], trace_args[0 .. 2 + topics.len], data, false);
    try self.appendLogEntry(data, topics);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test fixture: stack-allocates a `Chain` and a `GlobalState` together
/// so that the global's `chain` pointer is valid for the test's
/// lifetime. Use as:
///
///     var th: TestFrame = undefined;
///     th.setup(testing.allocator);
///     defer th.teardown();
///     // th.global is the per-frame state;
///     // th.chain is the multi-account backing store.
pub const TestFrame = struct {
    chain: Chain,
    global: Self,

    pub fn setup(self: *TestFrame, allocator: std.mem.Allocator) void {
        self.chain = Chain.init(allocator);
        self.global = Self.initForFrame(allocator, &self.chain, 0);
    }

    pub fn teardown(self: *TestFrame) void {
        self.global.deinit();
        self.chain.deinit();
    }
};

/// Helper: create a GlobalState with tracing into an Allocating writer.
const TraceTestHelper = struct {
    alloc: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) TraceTestHelper {
        return .{ .alloc = std.Io.Writer.Allocating.init(allocator) };
    }

    fn writer(self: *TraceTestHelper) *std.Io.Writer {
        return &self.alloc.writer;
    }

    fn output(self: *TraceTestHelper) []const u8 {
        return self.alloc.written();
    }

    fn deinit(self: *TraceTestHelper) void {
        self.alloc.deinit();
    }
};

// ── Orchestration tests ──────────────────────────────────────────────
//
// These verify GlobalState's pass-through methods correctly delegate to
// the substructs. Detailed memory and storage behavior is tested in
// PagedMemory.zig and sparse.zig respectively.

test "orchestration: memStore/memLoad delegates to PagedMemory" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 0xDEADBEEF);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), try gs.memLoad(0));
    // Confirm the value lives in the underlying PagedMemory.
    try testing.expectEqual(@as(u256, 0xDEADBEEF), gs.memory.loadWord(0));
}

test "orchestration: sstore/sload routes through Chain" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.sstore(7, 42);
    try testing.expectEqual(@as(u256, 42), gs.sload(7));
    // Confirm the value lives in the underlying chain at the frame's address.
    try testing.expectEqual(@as(u256, 42), gs.chain.sload(gs.currentAccountAddress(), 7));
}

test "orchestration: tstore/tload delegates to SparseSlots and is isolated" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.tstore(7, 42);
    try gs.sstore(7, 99);
    try testing.expectEqual(@as(u256, 42), gs.tload(7));
    try testing.expectEqual(@as(u256, 99), gs.sload(7));
}

test "orchestration: getMsize reflects PagedMemory's msize" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try testing.expectEqual(@as(u256, 0), gs.getMsize());
    try gs.memStore(0, 1);
    try testing.expectEqual(@as(u256, 32), gs.getMsize());
    try testing.expectEqual(@as(u256, 32), gs.memory.getMsize());
}

test "logging: records entries with address" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.address = 0xDEADBEEF;

    const data = "hello";
    const topics = [_]u256{ 1, 2, 3 };
    try gs.addLog(0, data, &topics);

    try testing.expectEqual(@as(usize, 1), gs.log_entries.items.len);
    try testing.expectEqualSlices(u8, "hello", gs.log_entries.items[0].data);
    try testing.expectEqualSlices(u256, &topics, gs.log_entries.items[0].topics);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), gs.log_entries.items[0].address);
}

test "address mask: high bits stripped on read" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    // upper 96 bits set
    gs.address = (@as(u256, 0xCAFE) << 160) | 0xBEEF;
    try testing.expectEqual(@as(u256, 0xBEEF), gs.getAddress());
}

// ── Trace Tests ──────────────────────────────────────────────────────

test "trace: sstore emits trace line" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.sstore(1, 0xFF);
    try testing.expectEqualStrings("SSTORE(0x01, 0xff)\n", th.output());
}

test "trace: mstore line format" {
    // memStore is a pure operation; the trace line is emitted by the
    // caller (the EVMBuiltins dispatch arm). Verify the line shape via
    // a direct logTrace call.
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.logTrace("MSTORE", &.{ 0, 42 }, &.{}, true);
    try testing.expectEqualStrings("MSTORE(0x00, 0x2a)\n", th.output());
}

test "trace: mstore8 line format" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.logTrace("MSTORE8", &.{ 10, 0xAB }, &.{}, true);
    try testing.expectEqualStrings("MSTORE8(0x0a, 0xab)\n", th.output());
}

test "trace: tstore emits trace line" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.tstore(5, 99);
    try testing.expectEqualStrings("TSTORE(0x05, 0x63)\n", th.output());
}

test "trace: log emits trace with data" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    const topics = [_]u256{0xDEAD};
    try gs.addLog(0, &[_]u8{ 0xCA, 0xFE, 0x01 }, &topics);
    try testing.expectEqualStrings("LOG1(0x00, 0x03, 0xdead) [0xcafe01]\n", th.output());
}

test "trace: disable_mem_write_trace suppresses memory writes" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();
    gs.disable_mem_write_trace = true;

    // logTrace honors the disable flag for any caller passing
    // writes_memory = true, regardless of which builtin invoked it.
    try gs.logTrace("MSTORE", &.{ 0, 1 }, &.{}, true);
    try gs.logTrace("MSTORE8", &.{ 0, 2 }, &.{}, true);
    try gs.logTrace("MCOPY", &.{ 32, 0, 32 }, &.{}, true);
    try testing.expectEqualStrings("", th.output());

    // Storage trace is unaffected.
    try gs.sstore(1, 1);
    try testing.expectEqualStrings("SSTORE(0x01, 0x01)\n", th.output());
}

test "trace: null tracer is silent" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    // tracer is null by default - operations succeed silently
    try gs.sstore(1, 1);
    try gs.memStore(0, 1);
}

test "trace: multiple operations accumulate" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.sstore(0, 1);
    try gs.sstore(1, 2);
    try testing.expectEqualStrings(
        "SSTORE(0x00, 0x01)\nSSTORE(0x01, 0x02)\n",
        th.output(),
    );
}

test "trace: writeU256 zero" {
    var alloc = std.Io.Writer.Allocating.init(testing.allocator);
    defer alloc.deinit();
    try writeU256(&alloc.writer, 0);
    try testing.expectEqualStrings("0x00", alloc.written());
}

test "trace: writeU256 large value" {
    var alloc = std.Io.Writer.Allocating.init(testing.allocator);
    defer alloc.deinit();
    try writeU256(&alloc.writer, std.math.maxInt(u256));
    try testing.expectEqualStrings("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", alloc.written());
}

// ── accessMemory chokepoint ──────────────────────────────────────────

test "accessMemory: zero size returns true and skips msize update" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    try testing.expectEqual(@as(u256, 0), gs.getMsize());
    try testing.expectEqual(true, try gs.accessMemory(0, 0));
    try testing.expectEqual(@as(u256, 0), gs.getMsize());
    // Even at a huge offset, zero-size is a no-op.
    try testing.expectEqual(true, try gs.accessMemory(std.math.maxInt(u256), 0));
    try testing.expectEqual(@as(u256, 0), gs.getMsize());
}

test "accessMemory: normal access updates msize" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    try testing.expectEqual(true, try gs.accessMemory(0, 32));
    try testing.expectEqual(@as(u256, 32), gs.getMsize());
    // Higher access expands msize, rounded up to multiples of 32.
    try testing.expectEqual(true, try gs.accessMemory(100, 32));
    try testing.expectEqual(@as(u256, 160), gs.getMsize());
}

test "accessMemory: strict mode rejects oversized size" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    // size > maxInt(usize) → strict mode throws.
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, gs.accessMemory(0, huge));
}

test "accessMemory: strict mode rejects wraparound" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    // offset + size + 31 wraps u256 → strict mode throws (matches real
    // EVM, where the gas cost would OOG before this access happened).
    try testing.expectError(error.MemoryRangeTooLarge, gs.accessMemory(std.math.maxInt(u256), 32));
}

test "accessMemory: lax mode skips oversized size, msize still updated" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.memory_policy = .lax;
    // Beyond MAX_RANGE_SIZE_LAX but not overflowing.
    const big: u256 = MAX_RANGE_SIZE_LAX + 1;
    try testing.expectEqual(false, try gs.accessMemory(0, big));
    // msize was bumped per solc's trace-equivalence rule.
    try testing.expect(gs.getMsize() > 0);
}

test "accessMemory: lax mode signals overflow via max msize" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.memory_policy = .lax;
    try testing.expectEqual(false, try gs.accessMemory(std.math.maxInt(u256), 32));
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), gs.getMsize());
}

test "accessMemory: lax mode allows in-cap accesses" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.memory_policy = .lax;
    try testing.expectEqual(true, try gs.accessMemory(0, 32));
    try testing.expectEqual(@as(u256, 32), gs.getMsize());
}

// ── solc-compat WorldState ───────────────────────────────────────────

test "solc-compat: extcodesize is deterministic per address" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    const w = solcCompatWorld(&gs);
    const a = w.extCodeSize(0xdeadbeef);
    const b = w.extCodeSize(0xdeadbeef);
    try testing.expectEqual(a, b);
    // Different addresses produce different values (statistically).
    const c = w.extCodeSize(0xcafe);
    try testing.expect(a != c);
    // Bounded by 24 bits (matches solc).
    try testing.expect(a <= 0xffffff);
    try testing.expect(c <= 0xffffff);
}

test "solc-compat: extcodehash is deterministic per address" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    const w = solcCompatWorld(&gs);
    try testing.expectEqual(w.extCodeHash(0x42), w.extCodeHash(0x42));
    try testing.expect(w.extCodeHash(0x42) != w.extCodeHash(0x43));
}

test "solc-compat: blockhash respects [n - 256, n) window" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.block_number = 1024;
    const w = solcCompatWorld(&gs);
    // Inside the window: returns nonzero formula value.
    try testing.expect(w.blockHash(1023) != 0);
    try testing.expect(w.blockHash(769) != 0);
    try testing.expect(w.blockHash(768) != 0); // lower bound is inclusive
    // At or above current block: 0.
    try testing.expectEqual(@as(u256, 0), w.blockHash(1024));
    try testing.expectEqual(@as(u256, 0), w.blockHash(2000));
    // More than 256 blocks behind: 0.
    try testing.expectEqual(@as(u256, 0), w.blockHash(767));
    try testing.expectEqual(@as(u256, 0), w.blockHash(0));
}

test "solc-compat: balance returns sentinel + selfbalance for self" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.address = 0x1234;
    const w = solcCompatWorld(&gs);
    try testing.expectEqual(@as(u256, 0x22223333), w.balance(0x1234));
    try testing.expectEqual(@as(u256, 0x22222222), w.balance(0xABCD));
}

test "solc-compat: blob_hash returns 0" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    const w = solcCompatWorld(&gs);
    try testing.expectEqual(@as(u256, 0), w.blobHash(0));
    try testing.expectEqual(@as(u256, 0), w.blobHash(1));
}

test "solc-compat: ext_code_copy mirrors local code" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.code = "\xAA\xBB\xCC\xDD";
    const w = solcCompatWorld(&gs);
    var buf: [8]u8 = [_]u8{0} ** 8;
    w.extCodeCopy(0xDEADBEEF, &buf, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 0 }, &buf);
}
