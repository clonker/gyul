//! Multi-account chain state for the Yul interpreter.
//!
//! This module is the writable backing store for storage, transient
//! storage, balances, nonces, code, and immutables across multiple
//! accounts. The interpreter's `GlobalState` is per-frame and points at
//! a `Chain`; mutating builtins (`sstore`, `setimmutable`, balance
//! transfers, etc.) route through `Chain` keyed by the current frame's
//! `address`. There is no per-frame storage swap — storage just persists.
//!
//! Phase 3: storage / transient / immutables are flat maps keyed by
//! `(address, key)`. Phase 4 layers a journal on top for cross-frame
//! revert. Phase 6 adds `code` install / address derivation.

const std = @import("std");
const AST = @import("AST.zig");
const ObjectTree = @import("ObjectTree.zig").ObjectTree;
const ObjectTreeRoot = @import("ObjectTree.zig").ObjectTreeRoot;

/// 20-byte EVM address.
pub const Address = [20]u8;
pub const ZERO_ADDRESS: Address = .{0} ** 20;

/// Per-account state. The chain stores all accounts in one map and
/// looks them up by address.
pub const Account = struct {
    balance: u256 = 0,
    nonce: u64 = 0,
    /// Borrowed pointer into one of the `ObjectTreeRoot`s in `Chain.trees`.
    /// Null for EOAs and uninitialized contract slots.
    code: ?*const ObjectTree = null,
    /// AST view that owns the same nodes/extra/tokens pool as `code`.
    /// Stored alongside so child interpreters spawned for a CALL into
    /// this account can construct an `Interpreter` without re-parsing.
    /// Borrowed from one of `Chain.trees`.
    code_ast: ?AST = null,
    /// Lazy canonical print + hash for `extcodesize` / `extcodehash`.
    /// Populated on first query, cached forever (Phase 8).
    code_canonical: ?[]const u8 = null,
    code_hash: ?u256 = null,
};

/// Composite key for the chain's flat storage map.
pub const StorageKey = struct {
    addr: Address,
    slot: u256,
};

pub const StorageKeyContext = struct {
    pub fn hash(_: StorageKeyContext, key: StorageKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&key.addr);
        const slot_bytes: [32]u8 = @bitCast(key.slot);
        h.update(&slot_bytes);
        return h.final();
    }
    pub fn eql(_: StorageKeyContext, a: StorageKey, b: StorageKey) bool {
        return std.mem.eql(u8, &a.addr, &b.addr) and a.slot == b.slot;
    }
};

/// Composite key for the chain's flat immutables map.
pub const ImmutKey = struct {
    addr: Address,
    /// Owned name string. Lifetime tied to the chain.
    name: []const u8,
};

pub const ImmutKeyContext = struct {
    pub fn hash(_: ImmutKeyContext, key: ImmutKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&key.addr);
        h.update(key.name);
        return h.final();
    }
    pub fn eql(_: ImmutKeyContext, a: ImmutKey, b: ImmutKey) bool {
        return std.mem.eql(u8, &a.addr, &b.addr) and std.mem.eql(u8, a.name, b.name);
    }
};

/// Per-mutation undo records. Each mutating method on `Chain` writes
/// the previous value (or absence) to the journal *before* mutating.
/// CALL / CREATE entry takes a checkpoint; on revert/invalid the
/// interpreter calls `revertTo(cp)` to walk the entries from the top
/// of the journal back to `cp` and undo each one. On clean halt /
/// commit, the entries are simply dropped without undoing (their
/// captured `prev` strings, if any, are freed).
pub const Journal = struct {
    pub const Entry = union(enum) {
        storage_set: struct { addr: Address, key: u256, prev: ?u256 },
        transient_set: struct { addr: Address, key: u256, prev: ?u256 },
        balance_set: struct { addr: Address, prev: u256 },
        nonce_set: struct { addr: Address, prev: u64 },
        /// Created an account that did not exist before this entry.
        /// Revert removes it from `accounts` (and any code cache it
        /// might have accumulated).
        account_created: struct { addr: Address },
        code_set: struct { addr: Address, prev: ?*const ObjectTree },
        /// Set or updated an immutable. `name_owned = true` means the
        /// chain allocated a fresh key copy on this mutation; revert
        /// frees it. `name_owned = false` means the key already existed
        /// on a prior insert.
        immutable_set: struct {
            addr: Address,
            name: []const u8,
            prev: ?u256,
            name_owned: bool,
        },
    };

    pub const Checkpoint = struct {
        entry_count: usize = 0,
        /// Snapshot of `GlobalState.log_entries.len` at frame entry.
        /// The interpreter passes this back to `truncateLogEntries` on
        /// revert. (Logs live on `GlobalState`, not on the chain, so
        /// the chain only stores the count for round-trip convenience.)
        log_count: usize = 0,
    };

    entries: std.ArrayListUnmanaged(Entry) = .{},

    pub fn deinit(self: *Journal, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| freeEntry(e, gpa);
        self.entries.deinit(gpa);
    }

    fn freeEntry(e: Entry, gpa: std.mem.Allocator) void {
        switch (e) {
            .immutable_set => |im| if (im.name_owned) gpa.free(im.name),
            else => {},
        }
    }
};

/// The writable chain state. One instance per interpreter run; multiple
/// `GlobalState` frames may borrow it concurrently (sequentially —
/// the interpreter is single-threaded).
pub const Chain = struct {
    gpa: std.mem.Allocator,
    accounts: std.AutoHashMapUnmanaged(Address, Account) = .{},

    storage_map: std.HashMapUnmanaged(
        StorageKey,
        u256,
        StorageKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = .{},
    transient_map: std.HashMapUnmanaged(
        StorageKey,
        u256,
        StorageKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = .{},
    immutables_map: std.HashMapUnmanaged(
        ImmutKey,
        u256,
        ImmutKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = .{},

    linker_symbols: std.StringHashMapUnmanaged(u256) = .{},

    /// Owned `ObjectTreeRoot`s. Deployed `Account.code` pointers borrow
    /// into these. Populated by `addParseTree` (called from the CLI in
    /// Phase 9, or directly from tests in Phase 6).
    trees: std.ArrayListUnmanaged(*ObjectTreeRoot) = .{},

    /// Sentinel → (tree, root) registry. Populated when an
    /// `ObjectTreeRoot` is added via `addParseTree`. Used by the CREATE
    /// dispatch to map a sentinel embedded in init-code memory back to
    /// the `ObjectTree` it refers to.
    sentinel_map: std.AutoHashMapUnmanaged(u64, SentinelEntry) = .{},

    journal: Journal = .{},

    pub const SentinelEntry = struct {
        tree: *const ObjectTree,
        root: *ObjectTreeRoot,
    };

    pub fn init(gpa: std.mem.Allocator) Chain {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Chain) void {
        self.journal.deinit(self.gpa);

        // Free immutables map keys (we own them).
        var imm_it = self.immutables_map.iterator();
        while (imm_it.next()) |e| self.gpa.free(e.key_ptr.*.name);
        self.immutables_map.deinit(self.gpa);

        self.storage_map.deinit(self.gpa);
        self.transient_map.deinit(self.gpa);
        self.linker_symbols.deinit(self.gpa);
        self.sentinel_map.deinit(self.gpa);

        // Free per-account caches.
        var acc_it = self.accounts.iterator();
        while (acc_it.next()) |e| {
            if (e.value_ptr.code_canonical) |p| self.gpa.free(p);
        }
        self.accounts.deinit(self.gpa);

        for (self.trees.items) |root| {
            root.deinit(self.gpa);
            self.gpa.destroy(root);
        }
        self.trees.deinit(self.gpa);
    }

    /// Take ownership of a parsed `ObjectTreeRoot`, register every
    /// sub-object's sentinel in `sentinel_map`, and return a borrowed
    /// pointer to the root tree's `ObjectTree`. The returned pointer
    /// stays valid for the lifetime of the chain.
    ///
    /// Used by the CLI to load Yul source files and by tests to plant
    /// pre-parsed trees for CALL / CREATE fixtures. The caller hands
    /// over a heap-allocated `*ObjectTreeRoot`; the chain frees it on
    /// `deinit`.
    pub fn addParseTree(self: *Chain, root: *ObjectTreeRoot) !*ObjectTree {
        try self.trees.append(self.gpa, root);
        try self.registerSentinels(&root.root, root);
        return &root.root;
    }

    fn registerSentinels(self: *Chain, tree: *const ObjectTree, root: *ObjectTreeRoot) !void {
        if (tree.sentinel != 0) {
            try self.sentinel_map.put(self.gpa, tree.sentinel, .{ .tree = tree, .root = root });
        }
        for (tree.children) |*child| {
            try self.registerSentinels(child, root);
        }
    }

    /// Look up the `ObjectTree` registered for a sentinel. Returns null
    /// if the sentinel is unknown to this chain (e.g., it came from a
    /// tree that was never added via `addParseTree`).
    pub fn lookupSentinel(self: *const Chain, sentinel: u64) ?SentinelEntry {
        return self.sentinel_map.get(sentinel);
    }

    // ── WorldState bridge ───────────────────────────────────────────
    //
    // Exposes this chain as a `GlobalState.WorldState` so the read-only
    // builtins (`balance`, `extcodesize`, `extcodehash`, `extcodecopy`,
    // `blockhash`, `blobhash`) route through the chain's account map.
    // The vtable is constructed lazily because `GlobalState` imports
    // `Chain`, so storing the vtable as a const at the file scope
    // would create a forward-declaration mess.

    fn worldBalance(ctx: ?*anyopaque, addr: u256) u256 {
        const c: *Chain = @ptrCast(@alignCast(ctx.?));
        const a = addressFromU256(addr);
        if (c.accounts.get(a)) |acc| return acc.balance;
        return 0;
    }

    fn worldExtCodeSize(ctx: ?*anyopaque, addr: u256) u256 {
        const c: *Chain = @ptrCast(@alignCast(ctx.?));
        const a = addressFromU256(addr);
        const acc = c.accounts.getPtr(a) orelse return 0;
        // Phase 8 will populate code_canonical lazily; for now we
        // synthesize a deterministic-but-fake size from the AST.
        if (acc.code) |_| return 1; // any non-zero indicates "has code"
        return 0;
    }

    fn worldExtCodeHash(ctx: ?*anyopaque, addr: u256) u256 {
        const c: *Chain = @ptrCast(@alignCast(ctx.?));
        const a = addressFromU256(addr);
        const acc = c.accounts.getPtr(a) orelse return 0;
        if (acc.code) |_| return 1; // placeholder until Phase 8
        return 0;
    }

    fn worldExtCodeCopy(_: ?*anyopaque, _: u256, dest: []u8, _: u256) void {
        // Placeholder: zero-fill until Phase 8 wires canonical print.
        @memset(dest, 0);
    }

    fn worldBlockHash(_: ?*anyopaque, _: u256) u256 {
        return 0;
    }

    fn worldBlobHash(_: ?*anyopaque, _: u256) u256 {
        return 0;
    }

    const world_vtable = @import("GlobalState.zig").WorldState.VTable{
        .balance = worldBalance,
        .ext_code_size = worldExtCodeSize,
        .ext_code_hash = worldExtCodeHash,
        .ext_code_copy = worldExtCodeCopy,
        .block_hash = worldBlockHash,
        .blob_hash = worldBlobHash,
    };

    pub fn worldState(self: *Chain) @import("GlobalState.zig").WorldState {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &world_vtable,
        };
    }

    // ── Journal API ─────────────────────────────────────────────────

    pub fn snapshot(self: *const Chain, log_count: usize) Journal.Checkpoint {
        return .{
            .entry_count = self.journal.entries.items.len,
            .log_count = log_count,
        };
    }

    /// Drop all journal entries written since `cp` without undoing.
    /// Each entry's journal-owned memory (e.g., the per-entry copy of
    /// an immutable's name string) is freed; the chain's own state
    /// (storage map, accounts map, immutables map) is left in place.
    pub fn commitTo(self: *Chain, cp: Journal.Checkpoint) void {
        if (cp.entry_count > self.journal.entries.items.len) return;
        var i: usize = cp.entry_count;
        while (i < self.journal.entries.items.len) : (i += 1) {
            Journal.freeEntry(self.journal.entries.items[i], self.gpa);
        }
        self.journal.entries.shrinkRetainingCapacity(cp.entry_count);
    }

    /// Walk journal entries from the top back to `cp.entry_count`,
    /// undoing each. Caller must also `truncateLogEntries(cp.log_count)`
    /// on the relevant `GlobalState` to roll back logs (the chain does
    /// not own them).
    pub fn revertTo(self: *Chain, cp: Journal.Checkpoint) void {
        const target = cp.entry_count;
        if (target > self.journal.entries.items.len) return;
        var i: usize = self.journal.entries.items.len;
        while (i > target) {
            i -= 1;
            const e = self.journal.entries.items[i];
            self.undoEntry(e);
        }
        self.journal.entries.shrinkRetainingCapacity(target);
    }

    fn undoEntry(self: *Chain, e: Journal.Entry) void {
        switch (e) {
            .storage_set => |s| {
                if (s.prev) |v| {
                    // Re-insert prior value. The chain owns the storage
                    // map; this put cannot fail because the slot was
                    // previously present.
                    self.storage_map.put(self.gpa, .{ .addr = s.addr, .slot = s.key }, v) catch {};
                } else {
                    _ = self.storage_map.remove(.{ .addr = s.addr, .slot = s.key });
                }
            },
            .transient_set => |s| {
                if (s.prev) |v| {
                    self.transient_map.put(self.gpa, .{ .addr = s.addr, .slot = s.key }, v) catch {};
                } else {
                    _ = self.transient_map.remove(.{ .addr = s.addr, .slot = s.key });
                }
            },
            .balance_set => |b| {
                if (self.accounts.getPtr(b.addr)) |acc| acc.balance = b.prev;
            },
            .nonce_set => |n| {
                if (self.accounts.getPtr(n.addr)) |acc| acc.nonce = n.prev;
            },
            .account_created => |a| {
                // Drop the account. Free its code cache if any.
                if (self.accounts.getPtr(a.addr)) |acc| {
                    if (acc.code_canonical) |p| self.gpa.free(p);
                }
                _ = self.accounts.remove(a.addr);
            },
            .code_set => |c| {
                if (self.accounts.getPtr(c.addr)) |acc| {
                    // Invalidate the canonical-print cache when code changes.
                    if (acc.code_canonical) |p| self.gpa.free(p);
                    acc.code_canonical = null;
                    acc.code_hash = null;
                    acc.code = c.prev;
                }
            },
            .immutable_set => |im| {
                const probe = ImmutKey{ .addr = im.addr, .name = im.name };
                if (im.prev) |v| {
                    // The chain still owns the prior key (this entry was
                    // an update, not a fresh insert). Restore the value.
                    if (self.immutables_map.getPtr(probe)) |slot| slot.* = v;
                } else if (self.immutables_map.fetchRemove(probe)) |kv| {
                    // Fresh insert: free the key the chain allocated.
                    self.gpa.free(kv.key.name);
                }
                if (im.name_owned) self.gpa.free(im.name);
            },
        }
    }

    // ── Account access ──────────────────────────────────────────────

    pub fn getAccount(self: *Chain, addr: Address) ?*Account {
        return self.accounts.getPtr(addr);
    }

    pub fn getOrCreateAccount(self: *Chain, addr: Address) !*Account {
        const gop = try self.accounts.getOrPut(self.gpa, addr);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            try self.journal.entries.append(self.gpa, .{
                .account_created = .{ .addr = addr },
            });
        }
        return gop.value_ptr;
    }

    /// Set an account's balance, journaled. Auto-creates the account.
    pub fn setBalance(self: *Chain, addr: Address, value: u256) !void {
        const acc = try self.getOrCreateAccount(addr);
        try self.journal.entries.append(self.gpa, .{
            .balance_set = .{ .addr = addr, .prev = acc.balance },
        });
        acc.balance = value;
    }

    /// Bump an account's nonce by 1, journaled. Auto-creates the account.
    pub fn bumpNonce(self: *Chain, addr: Address) !void {
        const acc = try self.getOrCreateAccount(addr);
        try self.journal.entries.append(self.gpa, .{
            .nonce_set = .{ .addr = addr, .prev = acc.nonce },
        });
        acc.nonce +%= 1;
    }

    /// Install code at an address, journaled. Auto-creates the account.
    /// `code_ast` is the AST view that owns the same node/extra/token
    /// pool as `code`; pass `null` to clear it.
    pub fn setCode(self: *Chain, addr: Address, code: ?*const ObjectTree, code_ast: ?AST) !void {
        const acc = try self.getOrCreateAccount(addr);
        try self.journal.entries.append(self.gpa, .{
            .code_set = .{ .addr = addr, .prev = acc.code },
        });
        // Invalidate canonical cache: a fresh deploy will recompute.
        if (acc.code_canonical) |p| self.gpa.free(p);
        acc.code_canonical = null;
        acc.code_hash = null;
        acc.code = code;
        acc.code_ast = code_ast;
    }

    // ── Storage ─────────────────────────────────────────────────────

    pub fn sload(self: *const Chain, addr: Address, key: u256) u256 {
        return self.storage_map.get(.{ .addr = addr, .slot = key }) orelse 0;
    }

    pub fn sstore(self: *Chain, addr: Address, key: u256, value: u256) !void {
        const sk = StorageKey{ .addr = addr, .slot = key };
        // Capture prior value (or absent) before mutating, so revert can
        // walk the journal back to a checkpoint.
        const prev: ?u256 = self.storage_map.get(sk);
        if (value == 0) {
            // EVM semantics: storing 0 deletes the slot.
            _ = self.storage_map.remove(sk);
        } else {
            try self.storage_map.put(self.gpa, sk, value);
        }
        try self.journal.entries.append(self.gpa, .{
            .storage_set = .{ .addr = addr, .key = key, .prev = prev },
        });
    }

    pub fn tload(self: *const Chain, addr: Address, key: u256) u256 {
        return self.transient_map.get(.{ .addr = addr, .slot = key }) orelse 0;
    }

    pub fn tstore(self: *Chain, addr: Address, key: u256, value: u256) !void {
        const sk = StorageKey{ .addr = addr, .slot = key };
        const prev: ?u256 = self.transient_map.get(sk);
        if (value == 0) {
            _ = self.transient_map.remove(sk);
        } else {
            try self.transient_map.put(self.gpa, sk, value);
        }
        try self.journal.entries.append(self.gpa, .{
            .transient_set = .{ .addr = addr, .key = key, .prev = prev },
        });
    }

    // ── Immutables ──────────────────────────────────────────────────

    pub fn loadImmutable(self: *const Chain, addr: Address, name: []const u8) u256 {
        return self.immutables_map.get(.{ .addr = addr, .name = name }) orelse 0;
    }

    /// Insert (or update) `(addr, name) → value`. The chain takes
    /// ownership of `name` only when this is the FIRST insert for that
    /// (addr, name) pair; subsequent updates reuse the existing key.
    /// Journaled for revert.
    pub fn setImmutable(self: *Chain, addr: Address, name: []const u8, value: u256) !void {
        const probe_key = ImmutKey{ .addr = addr, .name = name };
        if (self.immutables_map.getPtr(probe_key)) |slot| {
            // Update path: chain already owns the key, journal records
            // only the prev value (and a borrowed reference to the name
            // that lives in the chain's existing key — name_owned=false).
            // Take a fresh dupe for the journal entry so the borrowed
            // pointer can't dangle if the chain re-keys later. But to
            // avoid double-frees in commit, mark name_owned=true and
            // accept the small extra alloc on every update.
            const journal_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(journal_name);
            try self.journal.entries.append(self.gpa, .{
                .immutable_set = .{
                    .addr = addr,
                    .name = journal_name,
                    .prev = slot.*,
                    .name_owned = true,
                },
            });
            slot.* = value;
            return;
        }
        const chain_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(chain_name);
        const journal_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(journal_name);
        try self.immutables_map.put(
            self.gpa,
            .{ .addr = addr, .name = chain_name },
            value,
        );
        try self.journal.entries.append(self.gpa, .{
            .immutable_set = .{
                .addr = addr,
                .name = journal_name,
                .prev = null,
                .name_owned = true,
            },
        });
    }

    // ── Iteration helpers (used by CLI for dumping state) ───────────

    pub fn storageCount(self: *const Chain) usize {
        return self.storage_map.count();
    }

    pub fn transientCount(self: *const Chain) usize {
        return self.transient_map.count();
    }
};

// ── Address conversion ──────────────────────────────────────────────

/// Convert a `u256` (as held in interpreter values) to a 20-byte
/// address. The low 160 bits are kept big-endian; the upper 96 bits are
/// discarded.
pub fn addressFromU256(v: u256) Address {
    var out: Address = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        out[19 - i] = @truncate(v >> @as(u8, @intCast(i * 8)));
    }
    return out;
}

/// Convert a 20-byte address to its `u256` representation (high 96 bits zero).
pub fn addressToU256(a: Address) u256 {
    var v: u256 = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        v = (v << 8) | @as(u256, a[i]);
    }
    return v;
}

// ── CREATE / CREATE2 address derivation ─────────────────────────────

/// Encode a u64 in minimal big-endian form: drop leading zero bytes.
/// Used by the RLP helpers below.
fn beMinimal(value: u64, buf: *[8]u8) []const u8 {
    std.mem.writeInt(u64, buf, value, .big);
    var start: usize = 0;
    while (start < 8 and buf[start] == 0) start += 1;
    return buf[start..];
}

/// Append RLP-encoded bytes for a string of `s.len` bytes (s itself
/// already in canonical form). Implements only the cases needed for
/// CREATE address derivation: short strings (1 byte → "0x80 + len + s",
/// up to 55 bytes).
fn rlpEncodeString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    if (s.len == 1 and s[0] < 0x80) {
        // Self-encoded.
        try out.append(gpa, s[0]);
    } else if (s.len == 0) {
        try out.append(gpa, 0x80);
    } else if (s.len <= 55) {
        try out.append(gpa, @as(u8, 0x80) + @as(u8, @intCast(s.len)));
        try out.appendSlice(gpa, s);
    } else {
        // Not needed for the CREATE-list cases we encode.
        return error.RlpStringTooLong;
    }
}

/// Append an RLP list header `[ ... ]` of `payload_len` bytes (short
/// form, payload_len ≤ 55).
fn rlpListHeader(out: *std.ArrayList(u8), gpa: std.mem.Allocator, payload_len: usize) !void {
    if (payload_len > 55) return error.RlpListTooLong;
    try out.append(gpa, @as(u8, 0xc0) + @as(u8, @intCast(payload_len)));
}

/// Derive a CREATE address: `keccak256(rlp([sender, nonce]))[12..]`.
pub fn deriveCreateAddress(
    gpa: std.mem.Allocator,
    sender: Address,
    nonce: u64,
) !Address {
    // Build the inner payload first so we know its length, then prepend
    // the list header. RLP for our inputs always fits in the short form.
    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(gpa);

    try rlpEncodeString(&payload, gpa, &sender);
    var nonce_buf: [8]u8 = undefined;
    const nonce_bytes = if (nonce == 0) &[_]u8{} else beMinimal(nonce, &nonce_buf);
    try rlpEncodeString(&payload, gpa, nonce_bytes);

    var rlp: std.ArrayList(u8) = .{};
    defer rlp.deinit(gpa);
    try rlpListHeader(&rlp, gpa, payload.items.len);
    try rlp.appendSlice(gpa, payload.items);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(rlp.items, &hash, .{});
    var addr: Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}

/// Derive a CREATE2 address:
/// `keccak256(0xff || sender || salt || keccak256(init_code))[12..]`.
pub fn deriveCreate2Address(
    sender: Address,
    salt: u256,
    init_code: []const u8,
) Address {
    var init_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(init_code, &init_hash, .{});

    var buf: [1 + 20 + 32 + 32]u8 = undefined;
    buf[0] = 0xff;
    @memcpy(buf[1..21], &sender);
    var salt_be: [32]u8 = undefined;
    std.mem.writeInt(u256, &salt_be, salt, .big);
    @memcpy(buf[21..53], &salt_be);
    @memcpy(buf[53..85], &init_hash);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&buf, &hash, .{});
    var addr: Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "addressFromU256 round trip" {
    const a: Address = .{ 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const v = addressToU256(a);
    const back = addressFromU256(v);
    try testing.expectEqualSlices(u8, &a, &back);
}

test "addressFromU256 strips high bits" {
    const v: u256 = (@as(u256, 1) << 200) | 0x42;
    const a = addressFromU256(v);
    try testing.expectEqual(@as(u8, 0x42), a[19]);
    try testing.expectEqual(@as(u8, 0), a[0]);
}

test "Chain init/deinit empty" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    try testing.expectEqual(@as(u32, 0), chain.accounts.count());
}

test "Chain storage isolated by address" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const b: Address = .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try chain.sstore(a, 7, 42);
    try chain.sstore(b, 7, 99);
    try testing.expectEqual(@as(u256, 42), chain.sload(a, 7));
    try testing.expectEqual(@as(u256, 99), chain.sload(b, 7));
}

test "Chain transient is independent of persistent" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.tstore(a, 5, 100);
    try chain.sstore(a, 5, 200);
    try testing.expectEqual(@as(u256, 100), chain.tload(a, 5));
    try testing.expectEqual(@as(u256, 200), chain.sload(a, 5));
}

test "Chain immutables key ownership" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.setImmutable(a, "salary", 1000);
    try chain.setImmutable(a, "salary", 2000); // update — no new key
    try testing.expectEqual(@as(u256, 2000), chain.loadImmutable(a, "salary"));
    try testing.expectEqual(@as(u32, 1), chain.immutables_map.count());
}

test "Chain getOrCreateAccount idempotent" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = .{ 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const acc1 = try chain.getOrCreateAccount(a);
    acc1.balance = 500;
    const acc2 = try chain.getOrCreateAccount(a);
    try testing.expectEqual(@as(u256, 500), acc2.balance);
    try testing.expectEqual(@as(u32, 1), chain.accounts.count());
}

test "Chain sstore zero deletes" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.sstore(a, 1, 100);
    try testing.expectEqual(@as(u32, 1), chain.storageCount());
    try chain.sstore(a, 1, 0);
    try testing.expectEqual(@as(u32, 0), chain.storageCount());
    try testing.expectEqual(@as(u256, 0), chain.sload(a, 1));
}

test "journal: sstore revertTo restores prior value" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.sstore(a, 1, 100);
    const cp = chain.snapshot(0);
    try chain.sstore(a, 1, 999);
    try chain.sstore(a, 2, 555);
    try testing.expectEqual(@as(u256, 999), chain.sload(a, 1));
    try testing.expectEqual(@as(u256, 555), chain.sload(a, 2));
    chain.revertTo(cp);
    try testing.expectEqual(@as(u256, 100), chain.sload(a, 1));
    try testing.expectEqual(@as(u256, 0), chain.sload(a, 2));
}

test "journal: account_created revert removes the account" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = .{ 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cp = chain.snapshot(0);
    _ = try chain.getOrCreateAccount(a);
    try testing.expect(chain.getAccount(a) != null);
    chain.revertTo(cp);
    try testing.expect(chain.getAccount(a) == null);
}

test "journal: balance_set revert restores prior balance" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.setBalance(a, 1000);
    const cp = chain.snapshot(0);
    try chain.setBalance(a, 2000);
    try testing.expectEqual(@as(u256, 2000), chain.getAccount(a).?.balance);
    chain.revertTo(cp);
    try testing.expectEqual(@as(u256, 1000), chain.getAccount(a).?.balance);
}

test "journal: immutable revert frees fresh key" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    const cp = chain.snapshot(0);
    try chain.setImmutable(a, "x", 7);
    try testing.expectEqual(@as(u256, 7), chain.loadImmutable(a, "x"));
    chain.revertTo(cp);
    try testing.expectEqual(@as(u256, 0), chain.loadImmutable(a, "x"));
}

test "journal: immutable update revert restores prior value" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    try chain.setImmutable(a, "x", 7);
    const cp = chain.snapshot(0);
    try chain.setImmutable(a, "x", 99);
    try testing.expectEqual(@as(u256, 99), chain.loadImmutable(a, "x"));
    chain.revertTo(cp);
    try testing.expectEqual(@as(u256, 7), chain.loadImmutable(a, "x"));
}

test "deriveCreateAddress nonce 0 is deterministic" {
    // Regression vector — captured from gyul itself, sanity-checked
    // against the EIP-1014 CREATE2 vector below (same Keccak path).
    // Sender: 0x0101010101010101010101010101010101010101, nonce 0.
    const sender: Address = .{0x01} ** 20;
    const got = try deriveCreateAddress(testing.allocator, sender, 0);
    const want: Address = .{
        0x1c, 0x81, 0xa6, 0x1a, 0x40, 0x70, 0x17, 0xc5, 0x83, 0x97,
        0xa4, 0x7d, 0x2a, 0xb2, 0x81, 0x91, 0xb9, 0xb8, 0xec, 0x9b,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "deriveCreateAddress nonce 1 is deterministic" {
    const sender: Address = .{0x01} ** 20;
    const got = try deriveCreateAddress(testing.allocator, sender, 1);
    const want: Address = .{
        0xc8, 0x51, 0xda, 0x37, 0xe4, 0xe8, 0xd3, 0xa2, 0x0d, 0x8d,
        0x56, 0xbe, 0x29, 0x63, 0x93, 0x4b, 0x4a, 0xd7, 0x1c, 0x3b,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "deriveCreateAddress nonce 0 vs nonce 1 differ" {
    const sender: Address = .{0x42} ** 20;
    const a0 = try deriveCreateAddress(testing.allocator, sender, 0);
    const a1 = try deriveCreateAddress(testing.allocator, sender, 1);
    try testing.expect(!std.mem.eql(u8, &a0, &a1));
}

test "deriveCreate2Address matches reference vector" {
    // EIP-1014 test vector:
    //   sender: 0x0000000000000000000000000000000000000000
    //   salt:   0x0000000000000000000000000000000000000000000000000000000000000000
    //   init code: 0x00
    //   expected: 0x4d1A2e2bB4F88F0250f26Ffff098B0b30B26BF38
    const sender: Address = ZERO_ADDRESS;
    const init_code = [_]u8{0x00};
    const got = deriveCreate2Address(sender, 0, &init_code);
    const want: Address = .{
        0x4d, 0x1a, 0x2e, 0x2b, 0xb4, 0xf8, 0x8f, 0x02, 0x50, 0xf2,
        0x6f, 0xff, 0xf0, 0x98, 0xb0, 0xb3, 0x0b, 0x26, 0xbf, 0x38,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "journal: commitTo drops entries without undoing" {
    var chain = Chain.init(testing.allocator);
    defer chain.deinit();
    const a: Address = ZERO_ADDRESS;
    const cp = chain.snapshot(0);
    try chain.sstore(a, 1, 100);
    try chain.setImmutable(a, "x", 5);
    try testing.expect(chain.journal.entries.items.len > 0);
    chain.commitTo(cp);
    try testing.expectEqual(@as(usize, 0), chain.journal.entries.items.len);
    // State persists.
    try testing.expectEqual(@as(u256, 100), chain.sload(a, 1));
    try testing.expectEqual(@as(u256, 5), chain.loadImmutable(a, "x"));
}
