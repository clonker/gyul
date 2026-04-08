const std = @import("std");
const AST = @import("AST.zig");

const Self = @This();

pub const FunctionDef = struct {
    /// Index of the function_definition node in the AST.
    node: AST.NodeIndex,
    /// Number of parameters (for arity checking at call sites).
    num_params: u32,
    /// Number of return values.
    num_returns: u32,
    /// The scope where this function was defined.
    /// Function calls create a new scope with this as parent,
    /// NOT the caller's scope. This gives correct lexical scoping:
    /// the function body can see sibling functions (mutual recursion)
    /// and enclosing-scope functions, but NOT the caller's local variables.
    defining_scope: *Self,
};

variables: std.StringHashMapUnmanaged(u256),
functions: std.StringHashMapUnmanaged(FunctionDef),
parent: ?*Self,
allocator: std.mem.Allocator,

// ── Init / Deinit ────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, parent: ?*Self) Self {
    return .{
        .variables = .{},
        .functions = .{},
        .parent = parent,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.variables.deinit(self.allocator);
    self.functions.deinit(self.allocator);
}

// ── Variable Operations ──────────────────────────────────────────────

/// Declare a new variable in the current scope.
pub fn declareVariable(self: *Self, name: []const u8, value: u256) !void {
    try self.variables.put(self.allocator, name, value);
}

/// Look up a variable, walking the scope chain.
pub fn getVariable(self: *const Self, name: []const u8) ?u256 {
    if (self.variables.get(name)) |v| return v;
    if (self.parent) |p| return p.getVariable(name);
    return null;
}

/// Update an existing variable in the nearest enclosing scope that declares it.
/// Returns false if the variable is not found in any scope.
pub fn setVariable(self: *Self, name: []const u8, value: u256) bool {
    if (self.variables.getPtr(name)) |ptr| {
        ptr.* = value;
        return true;
    }
    if (self.parent) |p| return p.setVariable(name, value);
    return false;
}

// ── Function Operations ──────────────────────────────────────────────

/// Declare a function in the current scope (used during hoisting).
pub fn declareFunction(self: *Self, name: []const u8, def: FunctionDef) !void {
    try self.functions.put(self.allocator, name, def);
}

/// Look up a function definition, walking the scope chain.
pub fn getFunction(self: *const Self, name: []const u8) ?FunctionDef {
    if (self.functions.get(name)) |f| return f;
    if (self.parent) |p| return p.getFunction(name);
    return null;
}

// ── Scope Management ─────────────────────────────────────────────────

/// Create a new child scope on the heap.
pub fn pushScope(allocator: std.mem.Allocator, parent: *Self) !*Self {
    const child = try allocator.create(Self);
    child.* = Self.init(allocator, parent);
    return child;
}

/// Deinit this scope and free it, returning the parent.
pub fn popScope(self: *Self) ?*Self {
    const parent = self.parent;
    self.deinit();
    self.allocator.destroy(self);
    return parent;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "variable: declare and lookup" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try state.declareVariable("x", 42);
    try testing.expectEqual(@as(u256, 42), state.getVariable("x").?);
}

test "variable: scope chain lookup" {
    var parent = Self.init(testing.allocator, null);
    defer parent.deinit();

    try parent.declareVariable("x", 1);

    var child = Self.init(testing.allocator, &parent);
    defer child.deinit();

    // Child finds x in parent
    try testing.expectEqual(@as(u256, 1), child.getVariable("x").?);
}

test "variable: shadowing" {
    var parent = Self.init(testing.allocator, null);
    defer parent.deinit();

    try parent.declareVariable("x", 1);

    var child = Self.init(testing.allocator, &parent);
    defer child.deinit();

    try child.declareVariable("x", 2);

    // Child sees its own x
    try testing.expectEqual(@as(u256, 2), child.getVariable("x").?);
    // Parent's x is unchanged
    try testing.expectEqual(@as(u256, 1), parent.getVariable("x").?);
}

test "variable: setVariable updates correct scope" {
    var parent = Self.init(testing.allocator, null);
    defer parent.deinit();

    try parent.declareVariable("x", 1);

    var child = Self.init(testing.allocator, &parent);
    defer child.deinit();

    // Child doesn't declare x, but sets it -> should update parent
    try testing.expect(child.setVariable("x", 99));
    try testing.expectEqual(@as(u256, 99), parent.getVariable("x").?);
}

test "variable: undefined returns null" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try testing.expectEqual(@as(?u256, null), state.getVariable("nonexistent"));
}

test "variable: setVariable on undefined returns false" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try testing.expect(!state.setVariable("nonexistent", 1));
}

test "function: declare and lookup" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try state.declareFunction("f", .{ .node = 5, .num_params = 2, .num_returns = 1, .defining_scope = &state });
    const f = state.getFunction("f").?;
    try testing.expectEqual(@as(u32, 5), f.node);
    try testing.expectEqual(@as(u32, 2), f.num_params);
    try testing.expectEqual(@as(u32, 1), f.num_returns);
}

test "function: scope chain lookup" {
    var parent = Self.init(testing.allocator, null);
    defer parent.deinit();

    try parent.declareFunction("f", .{ .node = 3, .num_params = 0, .num_returns = 0, .defining_scope = &parent });

    var child = Self.init(testing.allocator, &parent);
    defer child.deinit();

    // Child finds f in parent
    try testing.expectEqual(@as(u32, 3), child.getFunction("f").?.node);
}

test "function: defining_scope enables lexical scoping" {
    // Simulate: block_scope defines function f and variable x
    // When f is called, the call scope's parent is block_scope (defining_scope),
    // so f can see sibling functions but NOT the caller's variables.
    var block_scope = Self.init(testing.allocator, null);
    defer block_scope.deinit();

    try block_scope.declareVariable("x", 42);
    try block_scope.declareFunction("f", .{
        .node = 1,
        .num_params = 0,
        .num_returns = 0,
        .defining_scope = &block_scope,
    });

    // Caller has its own variable y
    var caller_scope = Self.init(testing.allocator, &block_scope);
    defer caller_scope.deinit();
    try caller_scope.declareVariable("y", 99);

    // Look up f, then create call scope with defining_scope as parent
    const f = caller_scope.getFunction("f").?;
    const call_scope = try Self.pushScope(testing.allocator, f.defining_scope);
    defer _ = call_scope.popScope();

    // Call scope can see x (from defining scope) but NOT y (caller's variable)
    try testing.expectEqual(@as(u256, 42), call_scope.getVariable("x").?);
    try testing.expectEqual(@as(?u256, null), call_scope.getVariable("y"));
}

test "function: recursive calls get independent scopes" {
    var root = Self.init(testing.allocator, null);
    defer root.deinit();

    try root.declareFunction("f", .{
        .node = 1,
        .num_params = 1,
        .num_returns = 1,
        .defining_scope = &root,
    });

    // Simulate two recursive call frames, both parented to root
    const call1 = try Self.pushScope(testing.allocator, &root);
    try call1.declareVariable("n", 5);

    const call2 = try Self.pushScope(testing.allocator, &root);
    try call2.declareVariable("n", 4);

    // Each frame has its own n
    try testing.expectEqual(@as(u256, 5), call1.getVariable("n").?);
    try testing.expectEqual(@as(u256, 4), call2.getVariable("n").?);

    // Both can see the function f for further recursion
    try testing.expect(call1.getFunction("f") != null);
    try testing.expect(call2.getFunction("f") != null);

    _ = call2.popScope();
    _ = call1.popScope();
}

test "function: undefined returns null" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try testing.expectEqual(@as(?FunctionDef, null), state.getFunction("nonexistent"));
}

test "scope: pushScope and popScope lifecycle" {
    var parent = Self.init(testing.allocator, null);
    defer parent.deinit();

    try parent.declareVariable("x", 1);

    const child = try Self.pushScope(testing.allocator, &parent);
    try child.declareVariable("y", 2);

    // Child can see both
    try testing.expectEqual(@as(u256, 1), child.getVariable("x").?);
    try testing.expectEqual(@as(u256, 2), child.getVariable("y").?);

    // Pop returns parent
    const returned_parent = child.popScope();
    try testing.expectEqual(&parent, returned_parent.?);

    // Parent doesn't see y
    try testing.expectEqual(@as(?u256, null), parent.getVariable("y"));
    // Parent still has x
    try testing.expectEqual(@as(u256, 1), parent.getVariable("x").?);
}

test "variable: default value is zero" {
    var state = Self.init(testing.allocator, null);
    defer state.deinit();

    try state.declareVariable("x", 0);
    try testing.expectEqual(@as(u256, 0), state.getVariable("x").?);
}
