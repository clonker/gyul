//! Sparse u256-keyed primitives shared by EVM-style state structures.
//!
//! - `U256HashContext` / `U256HashMap(V)`: a hashmap context for u256 keys
//!   plus a convenience alias. Used by `SparseSlots` and by
//!   `PagedMemory.pages`.
//! - `SparseSlots(V)`: a thin wrapper around `U256HashMap(V)` providing
//!   zero-default reads (`getOrZero`) — the access pattern needed for EVM
//!   storage and transient storage.
//!
//! `SparseSlots` is intentionally **unmanaged** (it does not own its
//! allocator) to match the project convention of `ArrayListUnmanaged` and
//! friends. Pass an allocator into every mutating call.

const std = @import("std");

/// Hashing context for u256 keys. `std.AutoHashMap` does not handle u256
/// directly, so we hash the big-endian bytes via Wyhash.
pub const U256HashContext = struct {
    pub fn hash(_: U256HashContext, key: u256) u64 {
        const bytes: [32]u8 = @bitCast(@byteSwap(key));
        return std.hash.Wyhash.hash(0, &bytes);
    }
    pub fn eql(_: U256HashContext, a: u256, b: u256) bool {
        return a == b;
    }
};

/// Convenience alias for an unmanaged u256→V hashmap.
pub fn U256HashMap(comptime V: type) type {
    return std.HashMapUnmanaged(u256, V, U256HashContext, 80);
}

/// A sparse u256-keyed map of `V` values where missing keys read as the
/// zero value of `V`. Suitable for EVM storage and transient storage.
///
/// Semantics:
/// - `getOrZero(k)` returns `std.mem.zeroes(V)` for keys that have never
///   been set, matching EVM SLOAD/TLOAD behavior on cold slots.
/// - `set(k, v)` always inserts an entry, including when `v` is the zero
///   value. Iteration sees every set key. This matches the existing
///   GlobalState behavior; if you want "clear on zero" semantics later,
///   add an explicit `clear` method.
pub fn SparseSlots(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Map = U256HashMap(V);
        pub const Iterator = Map.Iterator;
        pub const GetOrPutResult = Map.GetOrPutResult;

        map: Map = .{},

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
        }

        /// Read a slot. Returns the zero value of `V` if the slot was
        /// never set. Only meaningful when `V` has a sensible zero value
        /// (e.g. integers). For pointer values use `lookup`.
        pub fn getOrZero(self: *const Self, key: u256) V {
            return self.map.get(key) orelse std.mem.zeroes(V);
        }

        /// Read a slot. Returns `null` if the slot was never set.
        /// Use this when `V` has no meaningful zero value (e.g. `*T`).
        pub fn lookup(self: *const Self, key: u256) ?V {
            return self.map.get(key);
        }

        /// Write a slot. Always inserts (even when value is zero).
        pub fn set(self: *Self, allocator: std.mem.Allocator, key: u256, value: V) !void {
            try self.map.put(allocator, key, value);
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.map.iterator();
        }

        /// Reserve enough capacity for `additional` more inserts so
        /// subsequent `getOrPutAssumeCapacity` calls cannot trigger a
        /// rehash (which would invalidate any cached value pointers).
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: u32) !void {
            try self.map.ensureUnusedCapacity(allocator, additional);
        }

        /// Get-or-insert. The caller must initialize `value_ptr` if
        /// `found_existing` is false. May rehash.
        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: u256) !GetOrPutResult {
            return self.map.getOrPut(allocator, key);
        }

        /// Like `getOrPut` but never rehashes. Caller must have called
        /// `ensureUnusedCapacity` first.
        pub fn getOrPutAssumeCapacity(self: *Self, key: u256) GetOrPutResult {
            return self.map.getOrPutAssumeCapacity(key);
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "SparseSlots: getOrZero returns zero for absent key" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try testing.expectEqual(@as(u256, 0), slots.getOrZero(0));
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(42));
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(std.math.maxInt(u256)));
}

test "SparseSlots: set then getOrZero round-trips" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try slots.set(testing.allocator, 1, 100);
    try slots.set(testing.allocator, std.math.maxInt(u256), 0xCAFE);
    try testing.expectEqual(@as(u256, 100), slots.getOrZero(1));
    try testing.expectEqual(@as(u256, 0xCAFE), slots.getOrZero(std.math.maxInt(u256)));
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(2));
}

test "SparseSlots: overwrite replaces previous value" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try slots.set(testing.allocator, 1, 100);
    try slots.set(testing.allocator, 1, 200);
    try testing.expectEqual(@as(u256, 200), slots.getOrZero(1));
    try testing.expectEqual(@as(usize, 1), slots.count());
}

test "SparseSlots: set to zero stores the entry" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try slots.set(testing.allocator, 5, 0);
    try testing.expectEqual(@as(usize, 1), slots.count());
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(5));
}

test "SparseSlots: count reflects unique keys" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), slots.count());
    try slots.set(testing.allocator, 1, 1);
    try slots.set(testing.allocator, 2, 2);
    try slots.set(testing.allocator, 3, 3);
    try testing.expectEqual(@as(usize, 3), slots.count());
    try slots.set(testing.allocator, 2, 99); // overwrite, not new
    try testing.expectEqual(@as(usize, 3), slots.count());
}

test "SparseSlots: iterator yields all set entries including zero values" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try slots.set(testing.allocator, 1, 10);
    try slots.set(testing.allocator, 2, 0);
    try slots.set(testing.allocator, 3, 30);

    var seen_keys: u8 = 0;
    var sum_values: u256 = 0;
    var it = slots.iterator();
    while (it.next()) |entry| {
        seen_keys += 1;
        sum_values += entry.value_ptr.*;
        try testing.expect(entry.key_ptr.* == 1 or entry.key_ptr.* == 2 or entry.key_ptr.* == 3);
    }
    try testing.expectEqual(@as(u8, 3), seen_keys);
    try testing.expectEqual(@as(u256, 40), sum_values);
}

test "SparseSlots: works with non-u256 value types" {
    var slots: SparseSlots(u32) = .{};
    defer slots.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), slots.getOrZero(7));
    try slots.set(testing.allocator, 7, 42);
    try testing.expectEqual(@as(u32, 42), slots.getOrZero(7));
}

// EVM-storage-style tests (moved from GlobalState.zig). They use
// `SparseSlots(u256)` directly rather than going through GlobalState's
// sstore/sload pass-throughs — those pass-throughs are exercised by the
// orchestration tests in GlobalState.zig.

test "EVM storage: default is zero" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try testing.expectEqual(@as(u256, 0), slots.getOrZero(42));
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(0));
    try testing.expectEqual(@as(u256, 0), slots.getOrZero(std.math.maxInt(u256)));
}

test "EVM storage: store and load round-trip" {
    var slots: SparseSlots(u256) = .{};
    defer slots.deinit(testing.allocator);

    try slots.set(testing.allocator, 1, 100);
    try testing.expectEqual(@as(u256, 100), slots.getOrZero(1));

    try slots.set(testing.allocator, 1, 200);
    try testing.expectEqual(@as(u256, 200), slots.getOrZero(1));
}

test "EVM transient storage: isolated from persistent" {
    // Two SparseSlots instances are inherently independent.
    var persistent: SparseSlots(u256) = .{};
    defer persistent.deinit(testing.allocator);
    var transient: SparseSlots(u256) = .{};
    defer transient.deinit(testing.allocator);

    try transient.set(testing.allocator, 1, 42);
    try testing.expectEqual(@as(u256, 42), transient.getOrZero(1));
    try testing.expectEqual(@as(u256, 0), persistent.getOrZero(1));

    try persistent.set(testing.allocator, 1, 99);
    try testing.expectEqual(@as(u256, 42), transient.getOrZero(1));
    try testing.expectEqual(@as(u256, 99), persistent.getOrZero(1));
}
