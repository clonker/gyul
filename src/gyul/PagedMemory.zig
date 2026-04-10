//! Sparse byte-addressable memory backed by 4 KiB pages.
//!
//! The address space is `u256`. Pages are heap-allocated and kept in a
//! hashmap keyed by `offset >> PAGE_BITS`. Reads from missing pages
//! return zero. Writes allocate pages on demand.
//!
//! Wraparound semantics: page iteration uses wrapping arithmetic
//! (`+%`) at the offset-computation level so that pathological inputs
//! still produce a deterministic answer instead of crashing the
//! interpreter. This is **not** EVM-spec semantics — the yellow paper
//! explicitly notes that "the addition in the calculation of μ_i' is
//! not subject to the 2²⁵⁶ modulo" for every memory-touching opcode
//! (MLOAD/MSTORE/MSTORE8/CALLDATACOPY/CODECOPY/EXTCODECOPY/RETURNDATACOPY,
//! pages 33–35). Real EVM detects the overflow as out-of-gas. The
//! `GlobalState.accessMemory` chokepoint enforces this in strict mode
//! by rejecting wrapping accesses with `error.MemoryRangeTooLarge`,
//! which the interpreter's top-level catch converts to a revert. This
//! file's wrapping is a fallback for inputs that would never reach it
//! in spec-compliant execution.
//!
//! All length-taking operations are bounded by `usize` and reject
//! larger requests with `error.MemoryRangeTooLarge`. The iteration
//! over pages is page-aware (`Segments`), so a single `MLOAD`/`MSTORE`
//! is at most two hash lookups instead of 32 byte-by-byte lookups.

const std = @import("std");
const sparse = @import("sparse.zig");

const Self = @This();

pub const PAGE_BITS: u6 = 12;
pub const PAGE_SIZE: usize = 1 << PAGE_BITS; // 4096 bytes
pub const PAGE_MASK: u256 = PAGE_SIZE - 1;
pub const Page = [PAGE_SIZE]u8;

pages: sparse.SparseSlots(*Page) = .{},
msize: u256 = 0,
allocator: std.mem.Allocator,

// ── Init / Deinit ────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.pages.iterator();
    while (it.next()) |entry| {
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.pages.deinit(self.allocator);
}

/// Number of pages currently allocated. Test helper.
pub fn pageCount(self: *const Self) usize {
    return self.pages.count();
}

// ── Msize ────────────────────────────────────────────────────────────

pub fn getMsize(self: *const Self) u256 {
    return self.msize;
}

pub fn updateMsize(self: *Self, offset: u256, len: u256) void {
    if (len == 0) return;
    const end = offset +% len;
    const rounded = (end +% 31) & ~@as(u256, 31);
    if (rounded > self.msize) self.msize = rounded;
}

// ── Segment iterator ─────────────────────────────────────────────────

/// One contiguous run of bytes that lies entirely within a single page.
pub const Segment = struct {
    page_num: u256,
    in_page_offset: usize,
    len: usize,
};

/// Walks `len` bytes starting at `offset`, yielding one `Segment` per
/// page boundary crossing. Wraparound past `2^256` is implicit because
/// `current +%= seg_len` wraps as a u256.
pub const Segments = struct {
    current: u256,
    remaining: usize,

    pub fn next(self: *Segments) ?Segment {
        if (self.remaining == 0) return null;
        const page_num = self.current >> PAGE_BITS;
        const in_page_offset: usize = @intCast(self.current & PAGE_MASK);
        const seg_len = @min(self.remaining, PAGE_SIZE - in_page_offset);
        self.current +%= @as(u256, seg_len);
        self.remaining -= seg_len;
        return .{ .page_num = page_num, .in_page_offset = in_page_offset, .len = seg_len };
    }
};

pub fn segments(offset: u256, len: usize) Segments {
    return .{ .current = offset, .remaining = len };
}

// ── Page lookups ─────────────────────────────────────────────────────

fn getOrCreatePage(self: *Self, page_num: u256) !*Page {
    const gop = try self.pages.getOrPut(self.allocator, page_num);
    if (!gop.found_existing) {
        const page = try self.allocator.create(Page);
        page.* = std.mem.zeroes(Page);
        gop.value_ptr.* = page;
    }
    return gop.value_ptr.*;
}

/// Single-byte read from a known page index. Returns 0 for unallocated pages.
pub fn readByte(self: *const Self, offset: u256) u8 {
    const page_num = offset >> PAGE_BITS;
    const idx: usize = @intCast(offset & PAGE_MASK);
    const page = self.pages.lookup(page_num) orelse return 0;
    return page[idx];
}

/// Single-byte write. Allocates the destination page if needed.
pub fn writeByte(self: *Self, offset: u256, value: u8) !void {
    const page_num = offset >> PAGE_BITS;
    const idx: usize = @intCast(offset & PAGE_MASK);
    const page = try self.getOrCreatePage(page_num);
    page[idx] = value;
}

// ── Word-level access (specialized fast paths) ───────────────────────

/// Load a 32-byte big-endian word from `offset`. Updates msize.
/// Fast path: when the entire word fits in one page, this is one
/// hashmap lookup and one `std.mem.readInt`. The straddle case (word
/// crosses a page boundary) does two lookups into a 32-byte stack buffer.
pub fn loadWord(self: *Self, offset: u256) u256 {
    self.updateMsize(offset, 32);
    const page_num = offset >> PAGE_BITS;
    const in_page_offset: usize = @intCast(offset & PAGE_MASK);

    if (in_page_offset + 32 <= PAGE_SIZE) {
        const page = self.pages.lookup(page_num) orelse return 0;
        return std.mem.readInt(u256, page[in_page_offset..][0..32], .big);
    }

    // Word straddles two pages.
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const first_len: usize = PAGE_SIZE - in_page_offset;
    const second_len: usize = 32 - first_len;
    if (self.pages.lookup(page_num)) |page| {
        @memcpy(buf[0..first_len], page[in_page_offset..][0..first_len]);
    }
    const next_page_num = page_num +% 1;
    if (self.pages.lookup(next_page_num)) |page| {
        @memcpy(buf[first_len..32], page[0..second_len]);
    }
    return std.mem.readInt(u256, &buf, .big);
}

/// Store a 32-byte big-endian word at `offset`. Updates msize.
/// Same fast path as `loadWord`: a single page lookup + `writeInt` when
/// the word fits in one page; two lookups + `@memcpy` when it straddles.
pub fn storeWord(self: *Self, offset: u256, value: u256) !void {
    self.updateMsize(offset, 32);
    const page_num = offset >> PAGE_BITS;
    const in_page_offset: usize = @intCast(offset & PAGE_MASK);

    if (in_page_offset + 32 <= PAGE_SIZE) {
        const page = try self.getOrCreatePage(page_num);
        std.mem.writeInt(u256, page[in_page_offset..][0..32], value, .big);
        return;
    }

    // Straddles two pages. Reserve room for both before either lookup so a
    // rehash can't invalidate the first page pointer.
    try self.pages.ensureUnusedCapacity(self.allocator, 2);
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, value, .big);
    const first_len: usize = PAGE_SIZE - in_page_offset;
    const second_len: usize = 32 - first_len;
    {
        const page = try self.pageGetOrCreateAssumeCapacity(page_num);
        @memcpy(page[in_page_offset..][0..first_len], buf[0..first_len]);
    }
    {
        const next_page_num = page_num +% 1;
        const page = try self.pageGetOrCreateAssumeCapacity(next_page_num);
        @memcpy(page[0..second_len], buf[first_len..32]);
    }
}

/// Store a single byte at `offset`. Updates msize.
pub fn storeByte(self: *Self, offset: u256, value: u8) !void {
    self.updateMsize(offset, 1);
    try self.writeByte(offset, value);
}

// ── Bulk write ───────────────────────────────────────────────────────

/// Write `data` into memory starting at `offset`. Updates msize.
/// Walks page boundaries via `Segments` for `@memcpy`-per-segment
/// performance and pre-reserves capacity in the page map so the per-page
/// `getOrPut` lookups never trigger a mid-loop rehash (which would
/// invalidate any cached page pointers).
pub fn write(self: *Self, offset: u256, data: []const u8) !void {
    if (data.len == 0) return;
    self.updateMsize(offset, @as(u256, data.len));

    // Pre-reserve worst-case page slots so we can use `getOrPutAssumeCapacity`
    // inside the loop. Worst case: ceil(data.len / PAGE_SIZE) + 1 to account
    // for partial first/last pages. The hashmap will skip the reservation
    // for slots that already exist.
    const max_new_pages: u32 = @intCast((data.len / PAGE_SIZE) + 2);
    try self.pages.ensureUnusedCapacity(self.allocator, max_new_pages);

    var pos: usize = 0;
    var it = segments(offset, data.len);
    while (it.next()) |seg| {
        const page = try self.pageGetOrCreateAssumeCapacity(seg.page_num);
        @memcpy(page[seg.in_page_offset..][0..seg.len], data[pos..][0..seg.len]);
        pos += seg.len;
    }
}

/// Like `getOrCreatePage` but assumes the caller already reserved
/// capacity in `self.pages` so the lookup cannot trigger a rehash.
fn pageGetOrCreateAssumeCapacity(self: *Self, page_num: u256) !*Page {
    const gop = self.pages.getOrPutAssumeCapacity(page_num);
    if (!gop.found_existing) {
        const page = try self.allocator.create(Page);
        page.* = std.mem.zeroes(Page);
        gop.value_ptr.* = page;
    }
    return gop.value_ptr.*;
}

// ── Bulk read ────────────────────────────────────────────────────────

/// Fill `buf` with `buf.len` bytes from memory starting at `offset`.
/// Bytes from unallocated pages are zero-filled. Never errors and never
/// allocates. Walks page boundaries via `Segments` for `@memcpy`-per-segment
/// performance instead of byte-by-byte hashmap lookups.
pub fn read(self: *const Self, offset: u256, buf: []u8) void {
    var pos: usize = 0;
    var it = segments(offset, buf.len);
    while (it.next()) |seg| {
        const dst = buf[pos..][0..seg.len];
        if (self.pages.lookup(seg.page_num)) |page| {
            @memcpy(dst, page[seg.in_page_offset..][0..seg.len]);
        } else {
            @memset(dst, 0);
        }
        pos += seg.len;
    }
}

// ── Range zero ───────────────────────────────────────────────────────

/// Zero a range of memory `[offset, offset+len)`. Only existing pages are
/// touched; unallocated pages stay absent because zero is the default for
/// unmapped reads. Wrap is handled implicitly by the segment iterator.
pub fn zero(self: *Self, offset: u256, len: u256) error{MemoryRangeTooLarge}!void {
    if (len == 0) return;
    if (len > std.math.maxInt(usize)) return error.MemoryRangeTooLarge;
    self.updateMsize(offset, len);

    var it = segments(offset, @intCast(len));
    while (it.next()) |seg| {
        if (self.pages.lookup(seg.page_num)) |page| {
            @memset(page[seg.in_page_offset..][0..seg.len], 0);
        }
    }
}

// ── Memory copy ──────────────────────────────────────────────────────

/// Copy `len` bytes from `src` to `dst`. Handles overlap, ring-buffer
/// wrap, and sparse source regions correctly:
///
/// - Direction is chosen so reads always precede writes for any aliased
///   bytes: `(dst -% src) < n` ⇒ copy backward, otherwise forward.
/// - Ring-buffer wrap is implicit through `+%` arithmetic.
/// - Sparse-aware: each chunk is read into a stack scratch buffer; if no
///   page in the source chunk's range was allocated, we know the chunk is
///   all zeros and skip the destination write entirely (which avoids
///   allocating destination pages for zero-only ranges).
/// - Bounds `len` by `usize`. Returns `error.MemoryRangeTooLarge` for
///   anything larger.
pub fn copy(self: *Self, dst: u256, src: u256, len: u256) !void {
    if (len == 0 or dst == src) return;
    if (len > std.math.maxInt(usize)) return error.MemoryRangeTooLarge;
    self.updateMsize(dst, len);
    self.updateMsize(src, len);

    const n: usize = @intCast(len);
    const reverse = (dst -% src) < @as(u256, n);

    var buf: [PAGE_SIZE]u8 = undefined;
    var processed: usize = 0;
    while (processed < n) {
        const chunk = @min(n - processed, buf.len);
        const off = if (reverse) n - processed - chunk else processed;
        const src_chunk_off = src +% @as(u256, off);
        const dst_chunk_off = dst +% @as(u256, off);

        const had_src = self.readChecked(src_chunk_off, buf[0..chunk]);
        if (had_src) {
            try self.write(dst_chunk_off, buf[0..chunk]);
        } else {
            // Source range had no allocated pages → all zeros. Don't
            // allocate destination pages just to write zeros into them;
            // only the existing destination pages need to be zeroed.
            try self.zero(dst_chunk_off, @as(u256, chunk));
        }

        processed += chunk;
    }
}

/// Like `read`, but returns true if any source page in the range was
/// allocated. When this returns false, the buffer is filled with zeros
/// and `copy` knows it can skip allocating destination pages.
fn readChecked(self: *const Self, offset: u256, buf: []u8) bool {
    var pos: usize = 0;
    var any_present = false;
    var it = segments(offset, buf.len);
    while (it.next()) |seg| {
        const dst = buf[pos..][0..seg.len];
        if (self.pages.lookup(seg.page_num)) |page| {
            @memcpy(dst, page[seg.in_page_offset..][0..seg.len]);
            any_present = true;
        } else {
            @memset(dst, 0);
        }
        pos += seg.len;
    }
    return any_present;
}

// ── Streaming Keccak-256 ─────────────────────────────────────────────

/// Compute Keccak-256 of `len` bytes starting at `offset`. Streams the
/// data through the hasher one PAGE_SIZE chunk at a time using `read`,
/// so the maximum scratch is one page regardless of `len`. Wrap and
/// unallocated regions are handled by `read`.
pub fn hashKeccak256(self: *const Self, offset: u256, len: u256, out: *[32]u8) error{MemoryRangeTooLarge}!void {
    if (len > std.math.maxInt(usize)) return error.MemoryRangeTooLarge;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    if (len == 0) {
        hasher.final(out);
        return;
    }
    var buf: [PAGE_SIZE]u8 = undefined;
    var remaining: usize = @intCast(len);
    var current = offset;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        self.read(current, buf[0..chunk]);
        hasher.update(buf[0..chunk]);
        current +%= @as(u256, chunk);
        remaining -= chunk;
    }
    hasher.final(out);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

// ── store/load round trips ───────────────────────────────────────────

test "memory: store and load round-trip" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(0, 0xDEADBEEF);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), pm.loadWord(0));
}

test "memory: store8 writes single byte" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeByte(0, 0xAB);
    try testing.expectEqual(@as(u256, 0xAB) << 248, pm.loadWord(0));
}

test "memory: sparse access at high offset" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const high_offset: u256 = std.math.maxInt(u256) - 31;
    try pm.storeWord(0, 42);
    try pm.storeWord(high_offset, 99);

    try testing.expectEqual(@as(u256, 42), pm.loadWord(0));
    try testing.expectEqual(@as(u256, 99), pm.loadWord(high_offset));
}

test "memory: untouched read returns zero" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try testing.expectEqual(@as(u256, 0), pm.loadWord(1000));
}

test "memory: msize tracking" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try testing.expectEqual(@as(u256, 0), pm.getMsize());

    try pm.storeWord(0, 1);
    try testing.expectEqual(@as(u256, 32), pm.getMsize());

    _ = pm.loadWord(64);
    try testing.expectEqual(@as(u256, 96), pm.getMsize());

    try pm.storeByte(100, 0xFF);
    try testing.expectEqual(@as(u256, 128), pm.getMsize());
}

test "memory: cross-page read" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const offset: u256 = PAGE_SIZE - 2;
    try pm.storeWord(offset, 0xCAFEBABE);
    try testing.expectEqual(@as(u256, 0xCAFEBABE), pm.loadWord(offset));
}

test "memory: write and read round-trip" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try pm.write(10, &data);

    var buf: [4]u8 = undefined;
    pm.read(10, &buf);
    try testing.expectEqualSlices(u8, &data, &buf);
}

test "memory: copy non-overlapping" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(0, 0x1234);
    try pm.copy(32, 0, 32);
    try testing.expectEqual(@as(u256, 0x1234), pm.loadWord(32));
}

// ── Segments iterator ────────────────────────────────────────────────

test "Segments: empty range yields nothing" {
    var it = segments(100, 0);
    try testing.expect(it.next() == null);
}

test "Segments: range within a single page is one segment" {
    var it = segments(0, 32);
    const s = it.next().?;
    try testing.expectEqual(@as(u256, 0), s.page_num);
    try testing.expectEqual(@as(usize, 0), s.in_page_offset);
    try testing.expectEqual(@as(usize, 32), s.len);
    try testing.expect(it.next() == null);
}

test "Segments: range crossing one page boundary yields two segments" {
    // Start near end of page 0, total 64 bytes → 1 byte in page 0, 63 in page 1.
    var it = segments(PAGE_SIZE - 1, 64);
    const s1 = it.next().?;
    try testing.expectEqual(@as(u256, 0), s1.page_num);
    try testing.expectEqual(@as(usize, PAGE_SIZE - 1), s1.in_page_offset);
    try testing.expectEqual(@as(usize, 1), s1.len);

    const s2 = it.next().?;
    try testing.expectEqual(@as(u256, 1), s2.page_num);
    try testing.expectEqual(@as(usize, 0), s2.in_page_offset);
    try testing.expectEqual(@as(usize, 63), s2.len);

    try testing.expect(it.next() == null);
}

test "Segments: wraps past max u256" {
    // Last byte of address space + first byte of page 0.
    const max = std.math.maxInt(u256);
    var it = segments(max, 2);
    const s1 = it.next().?;
    try testing.expectEqual(max >> PAGE_BITS, s1.page_num);
    try testing.expectEqual(@as(usize, PAGE_SIZE - 1), s1.in_page_offset);
    try testing.expectEqual(@as(usize, 1), s1.len);

    const s2 = it.next().?;
    try testing.expectEqual(@as(u256, 0), s2.page_num);
    try testing.expectEqual(@as(usize, 0), s2.in_page_offset);
    try testing.expectEqual(@as(usize, 1), s2.len);

    try testing.expect(it.next() == null);
}

test "Segments: large range spanning many pages terminates correctly" {
    var it = segments(0, 5 * PAGE_SIZE);
    var count: usize = 0;
    var total: usize = 0;
    while (it.next()) |s| {
        count += 1;
        total += s.len;
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqual(@as(usize, 5 * PAGE_SIZE), total);
}

test "zero: unallocated range never allocates pages" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.zero(PAGE_SIZE * 100, PAGE_SIZE * 10);
    try testing.expectEqual(@as(usize, 0), pm.pages.count());
}

test "zero: range overlapping existing page zeros only the overlap" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Touch page 0 with non-zero data at offsets 0..32.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try pm.writeByte(@as(u256, i), 0xAA);
    }

    try pm.zero(8, 16);

    // Bytes 0..7 untouched, 8..23 zeroed, 24..31 untouched.
    try testing.expectEqual(@as(u8, 0xAA), pm.readByte(0));
    try testing.expectEqual(@as(u8, 0xAA), pm.readByte(7));
    try testing.expectEqual(@as(u8, 0), pm.readByte(8));
    try testing.expectEqual(@as(u8, 0), pm.readByte(23));
    try testing.expectEqual(@as(u8, 0xAA), pm.readByte(24));
    try testing.expectEqual(@as(u8, 0xAA), pm.readByte(31));
}

test "zero: rejects len exceeding usize" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, pm.zero(0, huge));
}

test "zero: wraps past max u256 without allocating absent pages" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Touch the topmost page and page 0.
    try pm.writeByte(std.math.maxInt(u256), 0xFF);
    try pm.writeByte(0, 0xEE);

    try pm.zero(std.math.maxInt(u256), 2);

    try testing.expectEqual(@as(u8, 0), pm.readByte(std.math.maxInt(u256)));
    try testing.expectEqual(@as(u8, 0), pm.readByte(0));
    // No new pages were allocated.
    try testing.expectEqual(@as(usize, 2), pm.pages.count());
}

test "zero: updates msize" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();
    try testing.expectEqual(@as(u256, 0), pm.getMsize());
    try pm.zero(0, 100);
    try testing.expectEqual(@as(u256, 128), pm.getMsize()); // 100 rounded up to 128
}

// ── copy tests ───────────────────────────────────────────────────────

test "copy: dst == src is a no-op and allocates nothing" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.copy(0, 0, 1024);
    try testing.expectEqual(@as(usize, 0), pm.pages.count());
}

test "copy: src in unallocated page → dst in allocated page produces zeros" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Allocate dst page with non-zero data.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try pm.writeByte(@as(u256, i), 0xAA);
    }
    const dst_pages_before = pm.pages.count();

    // Source is far away, in unallocated address space.
    try pm.copy(0, 100 * PAGE_SIZE, 32);

    // Destination should be zeroed; no NEW pages allocated.
    i = 0;
    while (i < 32) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), pm.readByte(@as(u256, i)));
    }
    try testing.expectEqual(dst_pages_before, pm.pages.count());
}

test "copy: src and dst both unallocated allocates nothing" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.copy(50 * PAGE_SIZE, 100 * PAGE_SIZE, 1024);
    try testing.expectEqual(@as(usize, 0), pm.pages.count());
}

test "copy: forward overlap by 1 byte at a page boundary" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Seed bytes 0..63 with a known pattern.
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        try pm.writeByte(@as(u256, i), i + 1);
    }
    // Copy from src=0 to dst=63 (overlap of 1 byte at the source's last byte).
    try pm.copy(63, 0, 64);

    // dst[0] = src[0] = 1, dst[1] = src[1] = 2, ..., dst[63] = src[63] = 64
    i = 0;
    while (i < 64) : (i += 1) {
        try testing.expectEqual(i + 1, pm.readByte(63 + @as(u256, i)));
    }
}

test "copy: backward overlap by 1 byte at a page boundary" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Seed bytes 1..64 (so overlap when copying to 0).
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        try pm.writeByte(1 + @as(u256, i), i + 1);
    }
    // Copy from src=1 to dst=0 (forward overlap).
    try pm.copy(0, 1, 64);

    i = 0;
    while (i < 64) : (i += 1) {
        try testing.expectEqual(i + 1, pm.readByte(@as(u256, i)));
    }
}

test "copy: round-trip across multiple pages" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Seed 5 pages of varied data.
    const total: usize = 5 * PAGE_SIZE;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try pm.writeByte(@as(u256, i), @intCast((i * 7 + 3) & 0xFF));
    }

    // Copy to a non-overlapping destination.
    try pm.copy(10 * PAGE_SIZE, 0, total);

    // Verify byte-for-byte.
    i = 0;
    while (i < total) : (i += 1) {
        try testing.expectEqual(
            pm.readByte(@as(u256, i)),
            pm.readByte(10 * PAGE_SIZE + @as(u256, i)),
        );
    }
}

test "copy: rejects len exceeding usize" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, pm.copy(0, 0x10000, huge));
}

test "copy: wraps past max u256" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const max = std.math.maxInt(u256);
    // Seed bytes at max-3..max-0 and 0..1 with known values.
    try pm.writeByte(max - 3, 0x11);
    try pm.writeByte(max - 2, 0x22);
    try pm.writeByte(max - 1, 0x33);
    try pm.writeByte(max - 0, 0x44);
    try pm.writeByte(0, 0x55);
    try pm.writeByte(1, 0x66);

    // Copy 6 bytes from (max-3) to a non-overlapping destination.
    try pm.copy(0x100000, max - 3, 6);

    try testing.expectEqual(@as(u8, 0x11), pm.readByte(0x100000));
    try testing.expectEqual(@as(u8, 0x22), pm.readByte(0x100001));
    try testing.expectEqual(@as(u8, 0x33), pm.readByte(0x100002));
    try testing.expectEqual(@as(u8, 0x44), pm.readByte(0x100003));
    try testing.expectEqual(@as(u8, 0x55), pm.readByte(0x100004));
    try testing.expectEqual(@as(u8, 0x66), pm.readByte(0x100005));
}

// ── Word-access tests ────────────────────────────────────────────────

test "loadWord/storeWord straddling the wrap point" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const max = std.math.maxInt(u256);
    // Word starting at offset = max - 15 occupies the last 16 bytes of
    // the topmost page and the first 16 bytes of page 0.
    try pm.storeWord(max - 15, 0xDEADBEEFCAFEBABE_1122334455667788);
    const v = pm.loadWord(max - 15);
    try testing.expectEqual(@as(u256, 0xDEADBEEFCAFEBABE_1122334455667788), v);
}

test "write of a single byte at offset == max u256" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.write(std.math.maxInt(u256), &[_]u8{0x42});
    try testing.expectEqual(@as(u8, 0x42), pm.readByte(std.math.maxInt(u256)));
}

// ── keccak256 streaming tests ────────────────────────────────────────

/// Reference: read the entire range into one allocation and hash in a
/// single call. Used to validate the streaming version.
fn referenceKeccak256(pm: *const Self, allocator: std.mem.Allocator, offset: u256, len: u256, out: *[32]u8) !void {
    const size: usize = @intCast(len);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    pm.read(offset, buf);
    std.crypto.hash.sha3.Keccak256.hash(buf, out, .{});
}

fn expectKeccakMatchesReference(pm: *Self, offset: u256, len: u256) !void {
    var streaming: [32]u8 = undefined;
    try pm.hashKeccak256(offset, len, &streaming);

    var reference: [32]u8 = undefined;
    try referenceKeccak256(pm, testing.allocator, offset, len, &reference);

    try testing.expectEqualSlices(u8, &reference, &streaming);
}

test "hashKeccak256: empty range matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();
    try expectKeccakMatchesReference(&pm, 0, 0);
    try expectKeccakMatchesReference(&pm, 12345, 0);
}

test "hashKeccak256: small range within one page matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(0, 0xDEADBEEF);
    try pm.storeWord(32, 0xCAFEBABE);

    try expectKeccakMatchesReference(&pm, 0, 64);
    try expectKeccakMatchesReference(&pm, 5, 50);
    try expectKeccakMatchesReference(&pm, 30, 4);
}

test "hashKeccak256: range crossing page boundary matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(PAGE_SIZE - 32, 0x11);
    try pm.storeWord(PAGE_SIZE, 0x22);

    try expectKeccakMatchesReference(&pm, PAGE_SIZE - 64, 128);
    try expectKeccakMatchesReference(&pm, PAGE_SIZE - 1, 33);
}

test "hashKeccak256: sparse range with unallocated gaps matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(0, 0xAAAA);
    try pm.storeWord(2 * PAGE_SIZE, 0xBBBB);

    try expectKeccakMatchesReference(&pm, 0, 3 * PAGE_SIZE);
    try expectKeccakMatchesReference(&pm, PAGE_SIZE / 2, 2 * PAGE_SIZE);
}

test "hashKeccak256: range entirely in unallocated memory matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try expectKeccakMatchesReference(&pm, 1_000_000, 200);
    try expectKeccakMatchesReference(&pm, 0, PAGE_SIZE);
}

test "hashKeccak256: range larger than chunk buffer matches reference" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    var i: u256 = 0;
    while (i < 5 * PAGE_SIZE) : (i += 32) {
        try pm.storeWord(i, i *% 0x9E3779B97F4A7C15);
    }

    try expectKeccakMatchesReference(&pm, 0, 5 * PAGE_SIZE);
    try expectKeccakMatchesReference(&pm, 7, 5 * PAGE_SIZE - 13);
}

test "hashKeccak256: empty range hash equals known empty Keccak256" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    var hash: [32]u8 = undefined;
    try pm.hashKeccak256(0, 0, &hash);
    const empty_keccak: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(empty_keccak, std.mem.readInt(u256, &hash, .big));
}

test "hashKeccak256: rejects len exceeding usize" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    var hash: [32]u8 = undefined;
    const huge: u256 = @as(u256, std.math.maxInt(usize)) + 1;
    try testing.expectError(error.MemoryRangeTooLarge, pm.hashKeccak256(0, huge, &hash));
}

test "hashKeccak256: ring-buffer wrap from top of address space to zero" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    const max = std.math.maxInt(u256);
    try pm.storeByte(max - 3, 0x11);
    try pm.storeByte(max - 2, 0x22);
    try pm.storeByte(max - 1, 0x33);
    try pm.storeByte(max - 0, 0x44);
    try pm.storeByte(0, 0x55);
    try pm.storeByte(1, 0x66);

    var streaming: [32]u8 = undefined;
    try pm.hashKeccak256(max - 3, 6, &streaming);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 }, &expected, .{});

    try testing.expectEqualSlices(u8, &expected, &streaming);
}

// ── memZeroRange match-reference tests ───────────────────────────────

/// Reference: byte-wise zero of [offset, offset+len) modulo 2^256, but
/// only touching pages that already exist.
fn referenceMemZero(pm: *Self, offset: u256, len: u256) void {
    var i: u256 = 0;
    while (i < len) : (i += 1) {
        const addr = offset +% i;
        const page_num = addr >> PAGE_BITS;
        if (pm.pages.lookup(page_num)) |page| {
            const idx: usize = @intCast(addr & PAGE_MASK);
            page[idx] = 0;
        }
    }
}

fn expectStatesEqual(a: *const Self, b: *const Self) !void {
    try testing.expectEqual(a.pages.count(), b.pages.count());
    var it = a.pages.iterator();
    while (it.next()) |entry| {
        const other = b.pages.lookup(entry.key_ptr.*) orelse return error.PageMissing;
        try testing.expectEqualSlices(u8, entry.value_ptr.*, other);
    }
}

fn expectZeroMatchesReference(seed: *const fn (*Self) anyerror!void, offset: u256, len: u256) !void {
    var streaming = Self.init(testing.allocator);
    defer streaming.deinit();
    try seed(&streaming);
    try streaming.zero(offset, len);

    var reference = Self.init(testing.allocator);
    defer reference.deinit();
    try seed(&reference);
    referenceMemZero(&reference, offset, len);

    try expectStatesEqual(&streaming, &reference);
}

fn seedTwoPages(pm: *Self) anyerror!void {
    try pm.storeWord(0, 0xAAAA_BBBB_CCCC_DDDD);
    try pm.storeWord(PAGE_SIZE - 32, 0x1111_2222);
    try pm.storeWord(PAGE_SIZE, 0x3333_4444);
    try pm.storeWord(PAGE_SIZE * 3, 0xDEAD_BEEF);
}

fn seedTopAndBottom(pm: *Self) anyerror!void {
    const max = std.math.maxInt(u256);
    var i: u256 = 0;
    while (i < 64) : (i += 1) {
        try pm.writeByte(max - i, @intCast((i & 0x3F) | 0x80));
        try pm.writeByte(i, @intCast((i & 0x3F) | 0x40));
    }
}

test "zero: non-wrap ranges match reference" {
    try expectZeroMatchesReference(&seedTwoPages, 16, 64);
    try expectZeroMatchesReference(&seedTwoPages, PAGE_SIZE - 8, 16);
    try expectZeroMatchesReference(&seedTwoPages, 0, 4 * PAGE_SIZE);
    try expectZeroMatchesReference(&seedTwoPages, 32, 0);
}

test "zero: wrap ranges match reference" {
    const max = std.math.maxInt(u256);
    try expectZeroMatchesReference(&seedTopAndBottom, max - 31, 64);
    try expectZeroMatchesReference(&seedTopAndBottom, max - 7, 16);
    try expectZeroMatchesReference(&seedTopAndBottom, max, 2);
}

test "zero: wrap range zeroes both halves of the ring" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    try pm.storeWord(0, 0xAAAA);
    try pm.writeByte(std.math.maxInt(u256), 0xFF);

    try pm.zero(std.math.maxInt(u256), 65);

    try testing.expectEqual(@as(u8, 0), pm.readByte(std.math.maxInt(u256)));
    try testing.expectEqual(@as(u256, 0), pm.loadWord(0));
}

test "write: many pages survives mid-loop rehash" {
    var pm = Self.init(testing.allocator);
    defer pm.deinit();

    // Build a 256 KiB buffer with a recognizable pattern.
    const total: usize = 64 * PAGE_SIZE;
    const data = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast((i * 13 + 5) & 0xFF);

    try pm.write(0, data);

    // Read back via word loads to ensure pages weren't corrupted by rehashes.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try testing.expectEqual(data[i], pm.readByte(@as(u256, i)));
    }
}
