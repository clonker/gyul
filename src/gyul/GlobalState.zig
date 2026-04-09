const std = @import("std");

const Self = @This();

pub const PAGE_BITS = 12;
pub const PAGE_SIZE = 1 << PAGE_BITS; // 4096 bytes
pub const Page = [PAGE_SIZE]u8;

pub const LogEntry = struct {
    data: []u8,
    topics: []u256,
};

/// Custom hash context for u256 keys (Zig's AutoHashMap may not support u256).
pub const U256HashContext = struct {
    pub fn hash(_: U256HashContext, key: u256) u64 {
        const bytes: [32]u8 = @bitCast(@byteSwap(key));
        return std.hash.Wyhash.hash(0, &bytes);
    }
    pub fn eql(_: U256HashContext, a: u256, b: u256) bool {
        return a == b;
    }
};

pub fn U256HashMap(comptime V: type) type {
    return std.HashMapUnmanaged(u256, V, U256HashContext, 80);
}

// ── Fields ───────────────────────────────────────────────────────────

/// Sparse page-based memory. Key = offset >> PAGE_BITS.
pages: U256HashMap(*Page),
/// High-water mark: highest accessed byte rounded up to 32.
msize: u256,

/// Persistent storage.
storage: U256HashMap(u256),
/// Transient storage (per-tx, cleared after tx).
transient_storage: U256HashMap(u256),

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
        .pages = .{},
        .msize = 0,
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
    var page_iter = self.pages.iterator();
    while (page_iter.next()) |entry| {
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.pages.deinit(self.allocator);
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

// ── Memory Operations ────────────────────────────────────────────────

fn getOrCreatePage(self: *Self, page_num: u256) !*Page {
    const gop = try self.pages.getOrPut(self.allocator, page_num);
    if (!gop.found_existing) {
        const page = try self.allocator.create(Page);
        page.* = std.mem.zeroes(Page);
        gop.value_ptr.* = page;
    }
    return gop.value_ptr.*;
}

fn getPage(self: *const Self, page_num: u256) ?*const Page {
    const entry = self.pages.get(page_num);
    return if (entry) |p| p else null;
}

fn readByte(self: *const Self, offset: u256) u8 {
    const page_num = offset >> PAGE_BITS;
    const page_offset: u12 = @intCast(offset & (PAGE_SIZE - 1));
    const page = self.getPage(page_num) orelse return 0;
    return page[page_offset];
}

fn writeByte(self: *Self, offset: u256, value: u8) !void {
    const page_num = offset >> PAGE_BITS;
    const page_offset: u12 = @intCast(offset & (PAGE_SIZE - 1));
    const page = try self.getOrCreatePage(page_num);
    page[page_offset] = value;
}

pub fn updateMsize(self: *Self, offset: u256, len: u256) void {
    if (len == 0) return;
    const end = offset +% len;
    const rounded = (end +% 31) & ~@as(u256, 31);
    if (rounded > self.msize) {
        self.msize = rounded;
    }
}

/// Load 32 bytes from memory at offset as a big-endian u256.
pub fn memLoad(self: *Self, offset: u256) !u256 {
    self.updateMsize(offset, 32);
    var buf: [32]u8 = undefined;
    for (0..32) |i| {
        buf[i] = self.readByte(offset +% @as(u256, @intCast(i)));
    }
    return std.mem.readInt(u256, &buf, .big);
}

/// Store a u256 as 32 big-endian bytes at the given memory offset.
pub fn memStore(self: *Self, offset: u256, value: u256) !void {
    try self.logTrace("MSTORE", &.{ offset, value }, &.{}, true);
    self.updateMsize(offset, 32);
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, value, .big);
    for (0..32) |i| {
        try self.writeByte(offset +% @as(u256, @intCast(i)), buf[i]);
    }
}

/// Store a single byte (lowest byte of value) at the given memory offset.
pub fn memStore8(self: *Self, offset: u256, value: u256) !void {
    try self.logTrace("MSTORE8", &.{ offset, value }, &.{}, true);
    self.updateMsize(offset, 1);
    try self.writeByte(offset, @intCast(value & 0xFF));
}

/// Copy a range of memory bytes into the provided buffer.
pub fn memRead(self: *const Self, offset: u256, buf: []u8) void {
    for (buf, 0..) |*b, i| {
        b.* = self.readByte(offset +% @as(u256, @intCast(i)));
    }
}

/// Write a slice of bytes into memory starting at offset.
pub fn memWrite(self: *Self, offset: u256, data: []const u8) !void {
    if (data.len == 0) return;
    self.updateMsize(offset, @intCast(data.len));
    for (data, 0..) |b, i| {
        try self.writeByte(offset +% @as(u256, @intCast(i)), b);
    }
}

/// Stream a range of memory through a Keccak-256 hasher without
/// allocating the full range. Reads are page-aware: unallocated pages
/// contribute zero bytes. The address space is treated as a ring buffer
/// (matching EVM `MLOAD`/`MSTORE` semantics): the range [offset, offset+len)
/// wraps modulo 2^256. Length is bounded only by `usize`.
pub fn keccak256Range(self: *const Self, offset: u256, len: u256, out: *[32]u8) error{MemoryRangeTooLarge}!void {
    if (len > std.math.maxInt(usize)) return error.MemoryRangeTooLarge;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    if (len == 0) {
        hasher.final(out);
        return;
    }
    var remaining: usize = @intCast(len);
    var current = offset;
    var chunk_buf: [PAGE_SIZE]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, chunk_buf.len);
        for (chunk_buf[0..chunk], 0..) |*b, i| {
            b.* = self.readByte(current +% @as(u256, @intCast(i)));
        }
        hasher.update(chunk_buf[0..chunk]);
        current +%= @as(u256, @intCast(chunk));
        remaining -= chunk;
    }
    hasher.final(out);
}

/// Zero a range of memory [offset, offset + len). Only existing pages
/// are touched; unallocated pages stay absent because zero is the
/// default for unmapped reads. The address space is a ring buffer
/// (matching EVM semantics), so the range wraps modulo 2^256.
///
/// Length is bounded by `usize` so the page iteration is bounded. For
/// larger requested ranges, returns `error.MemoryRangeTooLarge`.
pub fn memZeroRange(self: *Self, offset: u256, len: u256) error{MemoryRangeTooLarge}!void {
    if (len == 0) return;
    if (len > std.math.maxInt(usize)) return error.MemoryRangeTooLarge;
    self.updateMsize(offset, len);

    const last_byte = offset +% (len - 1);
    const first_page = offset >> PAGE_BITS;
    const last_page = last_byte >> PAGE_BITS;

    if (last_byte >= offset) {
        // Non-wrapping range: walk page numbers from first_page to last_page.
        self.zeroPagesByLookup(first_page, last_page, offset, len);
    } else {
        // Range wraps past max u256: walk [first_page, max_page] then [0, last_page].
        const max_page: u256 = std.math.maxInt(u256) >> PAGE_BITS;
        self.zeroPagesByLookup(first_page, max_page, offset, len);
        self.zeroPagesByLookup(0, last_page, offset, len);
    }
}

/// Look up each page number in [first_page, last_page] and zero whatever
/// portion of it falls inside the destination range. Pages not in the map
/// are skipped (so no allocations happen). Iteration is inclusive on both
/// ends so the loop terminates correctly when last_page is at the very top
/// of the page-number space.
fn zeroPagesByLookup(self: *Self, first_page: u256, last_page: u256, offset: u256, len: u256) void {
    var page_num = first_page;
    while (true) : (page_num += 1) {
        if (self.pages.get(page_num)) |page| {
            zeroPageWithinRange(page, page_num << PAGE_BITS, offset, len);
        }
        if (page_num == last_page) break;
    }
}

/// Zero the bytes of `page` (located at `page_start`) that fall within
/// the destination range [offset, offset+len) modulo 2^256.
fn zeroPageWithinRange(page: *Page, page_start: u256, offset: u256, len: u256) void {
    const end = offset +% len;
    const wraps = end < offset; // len > 0 ⇒ end == offset is impossible
    // Last byte of the page. PAGE_SIZE is a power of two and pages are
    // word-aligned, so this is page_start with the low bits set. Always
    // fits in u256: the topmost page's last byte is exactly max u256.
    const page_last: u256 = page_start | (PAGE_SIZE - 1);

    if (!wraps) {
        if (offset > page_last or end <= page_start) return;
        const lo: usize = if (offset > page_start) @intCast(offset - page_start) else 0;
        const hi: usize = if (end > page_last) PAGE_SIZE else @intCast(end - page_start);
        @memset(page[lo..hi], 0);
    } else {
        // Range covers [offset, max u256] ∪ [0, end).
        if (offset <= page_last) {
            const lo: usize = if (offset > page_start) @intCast(offset - page_start) else 0;
            @memset(page[lo..], 0);
        }
        if (end > page_start) {
            const hi: usize = if (end > page_last) PAGE_SIZE else @intCast(end - page_start);
            @memset(page[0..hi], 0);
        }
    }
}

/// Copy memory from src to dst (may overlap).
pub fn memCopy(self: *Self, dst: u256, src: u256, len: u256) !void {
    try self.logTrace("MCOPY", &.{ dst, src, len }, &.{}, true);
    if (len == 0) return;
    self.updateMsize(dst, len);
    self.updateMsize(src, len);

    if (len <= 32768) {
        var buf: [32768]u8 = undefined;
        const n: usize = @intCast(len);
        for (0..n) |i| {
            buf[i] = self.readByte(src +% @as(u256, @intCast(i)));
        }
        for (0..n) |i| {
            try self.writeByte(dst +% @as(u256, @intCast(i)), buf[i]);
        }
    } else {
        if (dst <= src) {
            var i: u256 = 0;
            while (i < len) : (i += 1) {
                try self.writeByte(dst +% i, self.readByte(src +% i));
            }
        } else {
            var i: u256 = len;
            while (i > 0) {
                i -= 1;
                try self.writeByte(dst +% i, self.readByte(src +% i));
            }
        }
    }
}

pub fn getMsize(self: *const Self) u256 {
    return self.msize;
}

// ── Storage Operations ───────────────────────────────────────────────

pub fn sload(self: *const Self, key: u256) u256 {
    return self.storage.get(key) orelse 0;
}

pub fn sstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("SSTORE", &.{ key, value }, &.{}, false);
    try self.storage.put(self.allocator, key, value);
}

pub fn tload(self: *const Self, key: u256) u256 {
    return self.transient_storage.get(key) orelse 0;
}

pub fn tstore(self: *Self, key: u256, value: u256) !void {
    try self.logTrace("TSTORE", &.{ key, value }, &.{}, false);
    try self.transient_storage.put(self.allocator, key, value);
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

test "memory: store and load round-trip" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 0xDEADBEEF);
    const val = try gs.memLoad(0);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), val);
}

test "memory: store8 writes single byte" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore8(0, 0xAB);
    const val = try gs.memLoad(0);
    try testing.expectEqual(@as(u256, 0xAB) << 248, val);
}

test "memory: sparse access at high offset" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const high_offset: u256 = std.math.maxInt(u256) - 31;
    try gs.memStore(0, 42);
    try gs.memStore(high_offset, 99);

    try testing.expectEqual(@as(u256, 42), try gs.memLoad(0));
    try testing.expectEqual(@as(u256, 99), try gs.memLoad(high_offset));
}

test "memory: untouched read returns zero" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const val = try gs.memLoad(1000);
    try testing.expectEqual(@as(u256, 0), val);
}

test "memory: msize tracking" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try testing.expectEqual(@as(u256, 0), gs.getMsize());

    try gs.memStore(0, 1);
    try testing.expectEqual(@as(u256, 32), gs.getMsize());

    _ = try gs.memLoad(64);
    try testing.expectEqual(@as(u256, 96), gs.getMsize());

    try gs.memStore8(100, 0xFF);
    try testing.expectEqual(@as(u256, 128), gs.getMsize());
}

test "memory: cross-page read" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const offset: u256 = PAGE_SIZE - 2;
    try gs.memStore(offset, 0xCAFEBABE);
    const val = try gs.memLoad(offset);
    try testing.expectEqual(@as(u256, 0xCAFEBABE), val);
}

test "storage: default is zero" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try testing.expectEqual(@as(u256, 0), gs.sload(42));
    try testing.expectEqual(@as(u256, 0), gs.sload(0));
    try testing.expectEqual(@as(u256, 0), gs.sload(std.math.maxInt(u256)));
}

test "storage: store and load round-trip" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.sstore(1, 100);
    try testing.expectEqual(@as(u256, 100), gs.sload(1));

    try gs.sstore(1, 200);
    try testing.expectEqual(@as(u256, 200), gs.sload(1));
}

test "transient storage: isolated from persistent" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.tstore(1, 42);
    try testing.expectEqual(@as(u256, 42), gs.tload(1));
    try testing.expectEqual(@as(u256, 0), gs.sload(1));

    try gs.sstore(1, 99);
    try testing.expectEqual(@as(u256, 42), gs.tload(1));
    try testing.expectEqual(@as(u256, 99), gs.sload(1));
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

test "memory: memWrite and memRead" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try gs.memWrite(10, &data);

    var buf: [4]u8 = undefined;
    gs.memRead(10, &buf);
    try testing.expectEqualSlices(u8, &data, &buf);
}

test "memory: memCopy non-overlapping" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 0x1234);
    try gs.memCopy(32, 0, 32);
    try testing.expectEqual(@as(u256, 0x1234), try gs.memLoad(32));
}

// ── keccak256Range Tests ─────────────────────────────────────────────

/// Reference implementation: read the entire range into one allocation
/// and hash it in a single call. Used to validate the streaming version.
fn referenceKeccak256(gs: *const Self, allocator: std.mem.Allocator, offset: u256, len: u256, out: *[32]u8) !void {
    const size: usize = @intCast(len);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    gs.memRead(offset, buf);
    std.crypto.hash.sha3.Keccak256.hash(buf, out, .{});
}

fn expectKeccakMatchesReference(gs: *Self, offset: u256, len: u256) !void {
    var streaming: [32]u8 = undefined;
    try gs.keccak256Range(offset, len, &streaming);

    var reference: [32]u8 = undefined;
    try referenceKeccak256(gs, testing.allocator, offset, len, &reference);

    try testing.expectEqualSlices(u8, &reference, &streaming);
}

test "keccak256Range: empty range matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    try expectKeccakMatchesReference(&gs, 0, 0);
    try expectKeccakMatchesReference(&gs, 12345, 0);
}

test "keccak256Range: small range within one page matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 0xDEADBEEF);
    try gs.memStore(32, 0xCAFEBABE);

    try expectKeccakMatchesReference(&gs, 0, 64);
    try expectKeccakMatchesReference(&gs, 5, 50);
    try expectKeccakMatchesReference(&gs, 30, 4);
}

test "keccak256Range: range crossing page boundary matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    // Write across the boundary between page 0 and page 1.
    try gs.memStore(PAGE_SIZE - 32, 0x11);
    try gs.memStore(PAGE_SIZE, 0x22);

    try expectKeccakMatchesReference(&gs, PAGE_SIZE - 64, 128);
    try expectKeccakMatchesReference(&gs, PAGE_SIZE - 1, 33);
}

test "keccak256Range: sparse range with unallocated gaps matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    // Touch only pages 0 and 2; page 1 is unallocated zeros.
    try gs.memStore(0, 0xAAAA);
    try gs.memStore(2 * PAGE_SIZE, 0xBBBB);

    try expectKeccakMatchesReference(&gs, 0, 3 * PAGE_SIZE);
    try expectKeccakMatchesReference(&gs, PAGE_SIZE / 2, 2 * PAGE_SIZE);
}

test "keccak256Range: range entirely in unallocated memory matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try expectKeccakMatchesReference(&gs, 1_000_000, 200);
    try expectKeccakMatchesReference(&gs, 0, PAGE_SIZE);
}

test "keccak256Range: range larger than chunk buffer matches reference" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    // Several pages of data with varied content.
    var i: u256 = 0;
    while (i < 5 * PAGE_SIZE) : (i += 32) {
        try gs.memStore(i, i *% 0x9E3779B97F4A7C15);
    }

    try expectKeccakMatchesReference(&gs, 0, 5 * PAGE_SIZE);
    try expectKeccakMatchesReference(&gs, 7, 5 * PAGE_SIZE - 13);
}

test "keccak256Range: empty range hash equals known empty Keccak256" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    var hash: [32]u8 = undefined;
    try gs.keccak256Range(0, 0, &hash);
    const empty_keccak: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(empty_keccak, std.mem.readInt(u256, &hash, .big));
}

test "keccak256Range: rejects len exceeding usize" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    var hash: [32]u8 = undefined;
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, gs.keccak256Range(0, huge, &hash));
}

test "keccak256Range: ring-buffer wrap from top of address space to zero" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    const max = std.math.maxInt(u256);
    // Write a marker into the topmost page (last 4 bytes of u256 space) and
    // a marker at address 0 (page 0). A range starting near the top with a
    // length that crosses 2^256 should hash both markers.
    try gs.memStore8(max - 3, 0x11);
    try gs.memStore8(max - 2, 0x22);
    try gs.memStore8(max - 1, 0x33);
    try gs.memStore8(max - 0, 0x44);
    try gs.memStore8(0, 0x55);
    try gs.memStore8(1, 0x66);

    // Hash 6 bytes starting at max-3: should see 0x11,0x22,0x33,0x44,0x55,0x66.
    var streaming: [32]u8 = undefined;
    try gs.keccak256Range(max - 3, 6, &streaming);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 }, &expected, .{});

    try testing.expectEqualSlices(u8, &expected, &streaming);
}

// ── memZeroRange Tests ───────────────────────────────────────────────

/// Reference: byte-wise zero of [offset, offset+len) modulo 2^256, but
/// only touching pages that already exist (so it matches memZeroRange's
/// "leave unallocated pages absent" contract). O(len) — keep len small.
fn referenceMemZero(gs: *Self, offset: u256, len: u256) void {
    var i: u256 = 0;
    while (i < len) : (i += 1) {
        const addr = offset +% i;
        const page_num = addr >> PAGE_BITS;
        if (gs.pages.get(page_num)) |page| {
            const idx: u12 = @intCast(addr & (PAGE_SIZE - 1));
            page[idx] = 0;
        }
    }
}

/// Compare two GlobalStates: same set of pages and same byte contents.
fn expectStatesEqual(a: *const Self, b: *const Self) !void {
    try testing.expectEqual(a.pages.count(), b.pages.count());
    var it = a.pages.iterator();
    while (it.next()) |entry| {
        const other = b.pages.get(entry.key_ptr.*) orelse return error.PageMissing;
        try testing.expectEqualSlices(u8, entry.value_ptr.*, other);
    }
}

fn expectMemZeroMatchesReference(seed: *const fn (*Self) anyerror!void, offset: u256, len: u256) !void {
    var streaming = Self.init(testing.allocator);
    defer streaming.deinit();
    try seed(&streaming);
    try streaming.memZeroRange(offset, len);

    var reference = Self.init(testing.allocator);
    defer reference.deinit();
    try seed(&reference);
    referenceMemZero(&reference, offset, len);

    try expectStatesEqual(&streaming, &reference);
}

fn seedTwoPages(gs: *Self) anyerror!void {
    try gs.memStore(0, 0xAAAA_BBBB_CCCC_DDDD);
    try gs.memStore(PAGE_SIZE - 32, 0x1111_2222);
    try gs.memStore(PAGE_SIZE, 0x3333_4444);
    try gs.memStore(PAGE_SIZE * 3, 0xDEAD_BEEF);
}

fn seedTopAndBottom(gs: *Self) anyerror!void {
    const max = std.math.maxInt(u256);
    // Touch the topmost page and page 0 with non-zero data.
    var i: u256 = 0;
    while (i < 64) : (i += 1) {
        try gs.writeByte(max - i, @intCast((i & 0x3F) | 0x80));
        try gs.writeByte(i, @intCast((i & 0x3F) | 0x40));
    }
}

test "memZeroRange: non-wrap ranges match reference" {
    try expectMemZeroMatchesReference(&seedTwoPages, 16, 64);
    try expectMemZeroMatchesReference(&seedTwoPages, PAGE_SIZE - 8, 16);
    try expectMemZeroMatchesReference(&seedTwoPages, 0, 4 * PAGE_SIZE);
    try expectMemZeroMatchesReference(&seedTwoPages, 32, 0);
}

test "memZeroRange: wrap ranges match reference" {
    const max = std.math.maxInt(u256);
    try expectMemZeroMatchesReference(&seedTopAndBottom, max - 31, 64);
    try expectMemZeroMatchesReference(&seedTopAndBottom, max - 7, 16);
    try expectMemZeroMatchesReference(&seedTopAndBottom, max, 2);
}

test "memZeroRange: never allocates new pages" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 1);
    const before = gs.pages.count();

    // Range entirely in unallocated address space.
    try gs.memZeroRange(PAGE_SIZE * 100, PAGE_SIZE * 10);
    try testing.expectEqual(before, gs.pages.count());
}

test "memZeroRange: wrap range zeroes both halves of the ring" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();

    try gs.memStore(0, 0xAAAA);
    try gs.writeByte(std.math.maxInt(u256), 0xFF);

    // Range starts at max u256, length 65 → covers byte at max plus bytes 0..63.
    try gs.memZeroRange(std.math.maxInt(u256), 65);

    try testing.expectEqual(@as(u8, 0), gs.readByte(std.math.maxInt(u256)));
    try testing.expectEqual(@as(u256, 0), try gs.memLoad(0));
}

test "memZeroRange: rejects len exceeding usize" {
    var gs = Self.init(testing.allocator);
    defer gs.deinit();
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, gs.memZeroRange(0, huge));
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
