//! Nested representation of a parsed Yul object tree.
//!
//! A `ParseResult` from `AST.parseAny` is either a bare code block
//! (today's flat AST) or an `ObjectTreeRoot` that owns the shared
//! token/node/extra pool plus a recursive `ObjectTree` of objects, each
//! with its own `code_root` index, `data` sections, and `children`.
//!
//! This module only defines the types. The parser populates them in
//! Phase 1; the interpreter consumes them in Phases 5-9.

const std = @import("std");
const AST = @import("AST.zig");

/// Sentinel value used to mean "invalid / not assigned". `dataoffset` of
/// a child sub-object returns the child's sentinel; the CREATE handler
/// reads the first 8 bytes of return_data to recover it. Sentinel 0 is
/// reserved as a not-found marker.
pub const INVALID_SENTINEL: u64 = 0;

/// One Yul object: name + a single `code` block + optional data sections
/// + optional nested sub-objects.
///
/// Children are owned by their parent. The shared token/node/extra pool
/// is owned by the enclosing `ObjectTreeRoot`; each `ObjectTree` only
/// holds an `AST.NodeIndex` into that pool.
pub const ObjectTree = struct {
    /// Object name as written in source (without quotes). Owned slice.
    name: []const u8,
    /// Index of this object's `code { ... }` block (a `.block` node) in
    /// the shared node pool. `AST.null_node` if this object has no code
    /// (e.g., a stub object that contains only sub-objects). Solc-emitted
    /// objects always have a code block.
    code_root: AST.NodeIndex,
    /// Per-object data sections. Keys and values are owned.
    data: std.StringHashMapUnmanaged([]const u8),
    /// Nested sub-objects. Owned slice.
    children: []ObjectTree,
    /// Unique-within-parse handle. Used by `dataoffset`/`datacopy` for
    /// the sentinel-based init-code dispatch trick (see Phase 6 of the
    /// implementation plan). Always nonzero for parsed objects.
    sentinel: u64,
    /// Backref to parent for dotted-name resolution. Null on the root.
    parent: ?*const ObjectTree = null,

    /// Lazy canonical print of this object's runtime form (Phase 8).
    /// Populated on first `extcodesize`/`extcodehash`/`extcodecopy`. Owned.
    canonical_print: ?[]const u8 = null,
    /// Cached keccak256 of `canonical_print`.
    canonical_hash: ?u256 = null,

    /// Recursively free children, data sections, name, and any cached
    /// canonical print. Does NOT free the shared node pool — that's the
    /// responsibility of the enclosing `ObjectTreeRoot`.
    pub fn deinit(self: *ObjectTree, gpa: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(gpa);
        if (self.children.len > 0) gpa.free(self.children);

        var it = self.data.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.data.deinit(gpa);

        if (self.canonical_print) |p| gpa.free(p);

        gpa.free(self.name);
        self.* = undefined;
    }

    /// Find an immediate child by name. Returns null if not found.
    pub fn findChild(self: *const ObjectTree, name: []const u8) ?*const ObjectTree {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }

    /// Resolve a (possibly dotted) sub-object path against this object.
    /// Solc emits names like `"C_42.C_42_deployed"` for nested references.
    /// Returns null if any segment is missing.
    pub fn resolvePath(self: *const ObjectTree, path: []const u8) ?*const ObjectTree {
        var current: *const ObjectTree = self;
        var it = std.mem.splitScalar(u8, path, '.');
        // The first segment may match `current.name` (solc convention) —
        // skip it if so, otherwise treat the entire path as relative.
        if (it.next()) |first| {
            if (!std.mem.eql(u8, first, current.name)) {
                current = current.findChild(first) orelse return null;
            }
        }
        while (it.next()) |seg| {
            current = current.findChild(seg) orelse return null;
        }
        return current;
    }
};

/// Owns the shared parse pool (tokens/nodes/extra/source) plus the root
/// `ObjectTree`. Returned from `AST.parseAny` for sources that begin
/// with an `object` wrapper.
pub const ObjectTreeRoot = struct {
    source: [:0]const u8,
    tokens: AST.TokenList.Slice,
    nodes: []const AST.Node,
    extra: []const AST.NodeIndex,
    errors: []const AST.Error,
    /// The root object. Owns its children recursively.
    root: ObjectTree,

    pub fn deinit(self: *ObjectTreeRoot, gpa: std.mem.Allocator) void {
        self.root.deinit(gpa);
        var tokens = self.tokens;
        tokens.deinit(gpa);
        gpa.free(self.nodes);
        gpa.free(self.extra);
        gpa.free(self.errors);
        self.* = undefined;
    }

    /// View this root as a borrowed `AST` for use with helpers that
    /// expect the flat-root shape. The caller must NOT call `deinit` on
    /// the returned AST — ownership stays with the `ObjectTreeRoot`.
    pub fn asAst(self: *const ObjectTreeRoot) AST {
        return .{
            .source = self.source,
            .tokens = self.tokens,
            .nodes = self.nodes,
            .extra = self.extra,
            .errors = self.errors,
            .data_sections = .{},
        };
    }
};

test "ObjectTree.findChild matches exact name" {
    const allocator = std.testing.allocator;
    var children = try allocator.alloc(ObjectTree, 1);
    children[0] = .{
        .name = try allocator.dupe(u8, "X_deployed"),
        .code_root = AST.null_node,
        .data = .{},
        .children = &.{},
        .sentinel = 2,
    };
    var parent = ObjectTree{
        .name = try allocator.dupe(u8, "X"),
        .code_root = AST.null_node,
        .data = .{},
        .children = children,
        .sentinel = 1,
    };
    defer parent.deinit(allocator);

    try std.testing.expect(parent.findChild("X_deployed") != null);
    try std.testing.expect(parent.findChild("missing") == null);
}

test "ObjectTree.resolvePath walks dotted segments" {
    const allocator = std.testing.allocator;
    var grandchildren = try allocator.alloc(ObjectTree, 1);
    grandchildren[0] = .{
        .name = try allocator.dupe(u8, "Inner"),
        .code_root = AST.null_node,
        .data = .{},
        .children = &.{},
        .sentinel = 3,
    };
    var children = try allocator.alloc(ObjectTree, 1);
    children[0] = .{
        .name = try allocator.dupe(u8, "Mid"),
        .code_root = AST.null_node,
        .data = .{},
        .children = grandchildren,
        .sentinel = 2,
    };
    var parent = ObjectTree{
        .name = try allocator.dupe(u8, "Root"),
        .code_root = AST.null_node,
        .data = .{},
        .children = children,
        .sentinel = 1,
    };
    defer parent.deinit(allocator);

    try std.testing.expect(parent.resolvePath("Mid") != null);
    try std.testing.expect(parent.resolvePath("Mid.Inner") != null);
    try std.testing.expect(parent.resolvePath("Root.Mid.Inner") != null);
    try std.testing.expect(parent.resolvePath("Mid.Missing") == null);
}
