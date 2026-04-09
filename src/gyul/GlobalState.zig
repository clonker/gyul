const std = @import("std");
const sparse = @import("sparse.zig");
const PagedMemory = @import("PagedMemory.zig");

const Self = @This();

/// Re-exported page constants for backward compatibility.
pub const PAGE_BITS = PagedMemory.PAGE_BITS;
pub const PAGE_SIZE = PagedMemory.PAGE_SIZE;
pub const Page = PagedMemory.Page;

pub const LogEntry = struct {
    data: []u8,
    topics: []u256,
};

/// Re-exported from sparse.zig for backward compatibility.
pub const U256HashContext = sparse.U256HashContext;
pub const U256HashMap = sparse.U256HashMap;

// ── Fields ───────────────────────────────────────────────────────────

/// Paged byte-addressable memory + msize.
memory: PagedMemory,

/// Persistent storage.
storage: sparse.SparseSlots(u256),
/// Transient storage (per-tx, cleared after tx).
transient_storage: sparse.SparseSlots(u256),

/// Log entries recorded during execution.
log_entries: std.ArrayListUnmanaged(LogEntry),

/// Return data from last external call.
return_data: []u8,
/// Whether return_data was allocated by the interpreter (so deinit can free it).
return_data_owned: bool,

/// Call data for current execution.
calldata: []const u8,

// Execution context (immutable during execution)
caller: u256,
callvalue: u256,
address: u256,
origin: u256,
gasprice: u256,

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

allocator: std.mem.Allocator,

// ── Init / Deinit ────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .memory = PagedMemory.init(allocator),
        .storage = .{},
        .transient_storage = .{},
        .log_entries = .{},
        .return_data = &.{},
        .return_data_owned = false,
        .calldata = &.{},
        .caller = 0,
        .callvalue = 0,
        .address = 0,
        .origin = 0,
        .gasprice = 0,
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
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.memory.deinit();
    if (self.return_data_owned) {
        self.allocator.free(self.return_data);
    }
    self.storage.deinit(self.allocator);
    self.transient_storage.deinit(self.allocator);
    for (self.log_entries.items) |entry| {
        self.allocator.free(entry.data);
        self.allocator.free(entry.topics);
    }
    self.log_entries.deinit(self.allocator);
}

// ── Storage / Transient Storage (delegated to SparseSlots) ───────────

pub fn sload(self: *const Self, key: u256) u256 {
    return self.storage.getOrZero(key);
}

pub fn sstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("SSTORE", &.{ key, value }, &.{}, false);
    try self.storage.set(self.allocator, key, value);
}

pub fn tload(self: *const Self, key: u256) u256 {
    return self.transient_storage.getOrZero(key);
}

pub fn tstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("TSTORE", &.{ key, value }, &.{}, false);
    try self.transient_storage.set(self.allocator, key, value);
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

pub fn getMsize(self: *const Self) u256 {
    return self.memory.getMsize();
}

/// Load 32 bytes from memory at offset as a big-endian u256.
pub fn memLoad(self: *Self, offset: u256) !u256 {
    return self.memory.loadWord(offset);
}

/// Store a u256 as 32 big-endian bytes at the given memory offset.
pub fn memStore(self: *Self, offset: u256, value: u256) !void {
    try self.logTrace("MSTORE", &.{ offset, value }, &.{}, true);
    try self.memory.storeWord(offset, value);
}

/// Store a single byte (lowest byte of value) at the given memory offset.
pub fn memStore8(self: *Self, offset: u256, value: u256) !void {
    try self.logTrace("MSTORE8", &.{ offset, value }, &.{}, true);
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
/// sparse-aware).
pub fn memCopy(self: *Self, dst: u256, src: u256, len: u256) !void {
    try self.logTrace("MCOPY", &.{ dst, src, len }, &.{}, true);
    try self.memory.copy(dst, src, len);
}

// ── Logging ──────────────────────────────────────────────────────────

pub fn addLog(self: *Self, offset: u256, data: []const u8, topics: []const u256) !void {
    var trace_args: [6]u256 = undefined;
    trace_args[0] = offset;
    trace_args[1] = data.len;
    for (topics, 0..) |t, i| {
        trace_args[2 + i] = t;
    }
    const log_names = [_][]const u8{ "LOG0", "LOG1", "LOG2", "LOG3", "LOG4" };
    try self.logTrace(log_names[topics.len], trace_args[0 .. 2 + topics.len], data, false);

    const data_copy = try self.allocator.dupe(u8, data);
    errdefer self.allocator.free(data_copy);
    const topics_copy = try self.allocator.dupe(u256, topics);
    errdefer self.allocator.free(topics_copy);
    try self.log_entries.append(self.allocator, .{
        .data = data_copy,
        .topics = topics_copy,
    });
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

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

test "orchestration: sstore/sload delegates to SparseSlots" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.sstore(7, 42);
    try testing.expectEqual(@as(u256, 42), gs.sload(7));
    try testing.expectEqual(@as(u256, 42), gs.storage.getOrZero(7));
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

test "logging: records entries" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const data = "hello";
    const topics = [_]u256{ 1, 2, 3 };
    try gs.addLog(0, data, &topics);

    try testing.expectEqual(@as(usize, 1), gs.log_entries.items.len);
    try testing.expectEqualSlices(u8, "hello", gs.log_entries.items[0].data);
    try testing.expectEqualSlices(u256, &topics, gs.log_entries.items[0].topics);
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

test "trace: mstore emits trace line" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.memStore(0, 42);
    try testing.expectEqualStrings("MSTORE(0x00, 0x2a)\n", th.output());
}

test "trace: mstore8 emits trace line" {
    var th = TraceTestHelper.init(testing.allocator);
    defer th.deinit();

    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    gs.tracer = th.writer();

    try gs.memStore8(10, 0xAB);
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

    try gs.memStore(0, 1);
    try gs.memStore8(0, 2);
    try gs.memCopy(32, 0, 32);
    // Memory write traces suppressed
    try testing.expectEqualStrings("", th.output());

    // But storage is still traced
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
