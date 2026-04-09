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
/// contribute zero bytes. Length is bounded only by `usize`.
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
/// default for unmapped reads. Wrap-around addressing is not supported
/// here — callers must ensure offset + len does not wrap.
pub fn memZeroRange(self: *Self, offset: u256, len: u256) void {
    if (len == 0) return;
    self.updateMsize(offset, len);
    const end = offset +% len;
    var it = self.pages.iterator();
    while (it.next()) |entry| {
        const page_num = entry.key_ptr.*;
        const page_start: u256 = page_num << PAGE_BITS;
        const page_end: u256 = page_start + PAGE_SIZE;
        const lo = @max(offset, page_start);
        const hi = @min(end, page_end);
        if (lo >= hi) continue;
        const page = entry.value_ptr.*;
        const lo_in_page: usize = @intCast(lo - page_start);
        const hi_in_page: usize = @intCast(hi - page_start);
        @memset(page[lo_in_page..hi_in_page], 0);
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
