//! Yul semantic checker.
//!
//! Walks the AST once and reports structural / scoping violations that the
//! interpreter cannot catch at runtime, or only catches as a generic
//! `UndefinedVariable` after expensive setup. Spec source:
//! https://docs.soliditylang.org/en/latest/yul.html (scoping rules) and
//! `vendor/solidity/libyul/AsmAnalysis.cpp` for the canonical checks.
//!
//! Checks performed:
//!  - Variable / function / parameter redeclaration in the same scope.
//!  - Identifier shadowing across enclosing scopes.
//!  - Identifier collision with a reserved builtin name.
//!  - Duplicate parameter / return variable names within one function.
//!  - `break` / `continue` outside a for-loop body.
//!  - `break` / `continue` inside a for-loop's pre or post block (Yul
//!    only allows them in the body).
//!  - `leave` outside a function body.
//!  - Duplicate case literals in a switch statement.
//!
//! The checker does **not** validate undeclared name references or
//! arity — those are still caught by the interpreter at runtime.

const std = @import("std");
const AST = @import("AST.zig");
const ObjectTreeMod = @import("ObjectTree.zig");
const ObjectTree = ObjectTreeMod.ObjectTree;
const ObjectTreeRoot = ObjectTreeMod.ObjectTreeRoot;

const Self = @This();

pub const DiagnosticKind = enum {
    redeclared_in_scope,
    shadows_outer,
    shadows_builtin,
    duplicate_parameter,
    duplicate_return_var,
    function_redefinition,
    duplicate_case,
    break_outside_loop,
    continue_outside_loop,
    leave_outside_function,
    break_in_for_pre,
    continue_in_for_pre,
    leave_in_for_pre,
    break_in_for_post,
    continue_in_for_post,
    leave_in_for_post,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    token: AST.TokenIndex,
    name: []const u8,

    pub fn message(self: Diagnostic, writer: *std.Io.Writer) !void {
        switch (self.kind) {
            .redeclared_in_scope => try writer.print("'{s}' is already declared in this scope", .{self.name}),
            .shadows_outer => try writer.print("'{s}' shadows a name from an enclosing scope", .{self.name}),
            .shadows_builtin => try writer.print("'{s}' is a built-in name and cannot be redeclared", .{self.name}),
            .duplicate_parameter => try writer.print("duplicate parameter '{s}'", .{self.name}),
            .duplicate_return_var => try writer.print("duplicate return variable '{s}'", .{self.name}),
            .function_redefinition => try writer.print("function '{s}' is already defined in this scope", .{self.name}),
            .duplicate_case => try writer.print("duplicate switch case", .{}),
            .break_outside_loop => try writer.writeAll("'break' outside a for-loop body"),
            .continue_outside_loop => try writer.writeAll("'continue' outside a for-loop body"),
            .leave_outside_function => try writer.writeAll("'leave' outside a function body"),
            .break_in_for_pre => try writer.writeAll("'break' is not allowed in a for-loop pre block"),
            .continue_in_for_pre => try writer.writeAll("'continue' is not allowed in a for-loop pre block"),
            .leave_in_for_pre => try writer.writeAll("'leave' is not allowed in a for-loop pre block"),
            .break_in_for_post => try writer.writeAll("'break' is not allowed in a for-loop post block"),
            .continue_in_for_post => try writer.writeAll("'continue' is not allowed in a for-loop post block"),
            .leave_in_for_post => try writer.writeAll("'leave' is not allowed in a for-loop post block"),
        }
    }
};

pub const Diagnostics = struct {
    items: []const Diagnostic,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Diagnostics) void {
        self.allocator.free(self.items);
    }
};

const DeclKind = enum { variable, function };

const Decl = struct {
    kind: DeclKind,
    token: AST.TokenIndex,
};

const Scope = struct {
    names: std.StringHashMapUnmanaged(Decl) = .{},

    fn deinit(self: *Scope, alloc: std.mem.Allocator) void {
        self.names.deinit(alloc);
    }
};

allocator: std.mem.Allocator,
ast: *const AST,
diags: std.ArrayListUnmanaged(Diagnostic),
scopes: std.ArrayListUnmanaged(Scope),
loop_body_depth: u32,
function_body_depth: u32,
in_for_pre: bool,
in_for_post: bool,

const builtin_names = std.StaticStringMap(void).initComptime(.{
    .{ "add", {} },           .{ "sub", {} },           .{ "mul", {} },
    .{ "div", {} },           .{ "sdiv", {} },          .{ "mod", {} },
    .{ "smod", {} },          .{ "exp", {} },           .{ "addmod", {} },
    .{ "mulmod", {} },        .{ "signextend", {} },    .{ "lt", {} },
    .{ "gt", {} },            .{ "slt", {} },           .{ "sgt", {} },
    .{ "eq", {} },            .{ "iszero", {} },        .{ "and", {} },
    .{ "or", {} },            .{ "xor", {} },           .{ "not", {} },
    .{ "byte", {} },          .{ "shl", {} },           .{ "shr", {} },
    .{ "sar", {} },           .{ "clz", {} },           .{ "keccak256", {} },
    .{ "address", {} },       .{ "balance", {} },       .{ "origin", {} },
    .{ "caller", {} },        .{ "callvalue", {} },     .{ "calldataload", {} },
    .{ "calldatasize", {} },  .{ "calldatacopy", {} },  .{ "codesize", {} },
    .{ "codecopy", {} },      .{ "gasprice", {} },      .{ "extcodesize", {} },
    .{ "extcodecopy", {} },   .{ "returndatasize", {} },.{ "returndatacopy", {} },
    .{ "extcodehash", {} },   .{ "blockhash", {} },     .{ "coinbase", {} },
    .{ "timestamp", {} },     .{ "number", {} },        .{ "prevrandao", {} },
    .{ "gaslimit", {} },      .{ "chainid", {} },       .{ "selfbalance", {} },
    .{ "basefee", {} },       .{ "blobhash", {} },      .{ "blobbasefee", {} },
    .{ "pop", {} },           .{ "mload", {} },         .{ "mstore", {} },
    .{ "mstore8", {} },       .{ "sload", {} },         .{ "sstore", {} },
    .{ "tload", {} },         .{ "tstore", {} },        .{ "mcopy", {} },
    .{ "msize", {} },         .{ "gas", {} },           .{ "log0", {} },
    .{ "log1", {} },          .{ "log2", {} },          .{ "log3", {} },
    .{ "log4", {} },          .{ "create", {} },        .{ "call", {} },
    .{ "callcode", {} },      .{ "return", {} },        .{ "delegatecall", {} },
    .{ "create2", {} },       .{ "staticcall", {} },    .{ "revert", {} },
    .{ "invalid", {} },       .{ "selfdestruct", {} },  .{ "stop", {} },
    .{ "pc", {} },            .{ "memoryguard", {} },   .{ "datasize", {} },
    .{ "dataoffset", {} },    .{ "datacopy", {} },      .{ "setimmutable", {} },
    .{ "loadimmutable", {} }, .{ "linkersymbol", {} },
});

fn isBuiltinName(name: []const u8) bool {
    if (builtin_names.has(name)) return true;
    return std.mem.startsWith(u8, name, "verbatim_");
}

// ── Public API ──────────────────────────────────────────────────────

pub fn check(allocator: std.mem.Allocator, ast: *const AST) !Diagnostics {
    var self = Self{
        .allocator = allocator,
        .ast = ast,
        .diags = .{},
        .scopes = .{},
        .loop_body_depth = 0,
        .function_body_depth = 0,
        .in_for_pre = false,
        .in_for_post = false,
    };
    defer {
        for (self.scopes.items) |*s| s.deinit(allocator);
        self.scopes.deinit(allocator);
    }

    // Walk root statements as a single (top-level) block.
    try self.pushScope();
    const root_node = ast.nodes[0];
    if (root_node == .root) {
        try self.checkBlockStmts(ast.spanToList(root_node.root.body));
    }
    self.popScope();

    const items = try self.diags.toOwnedSlice(allocator);
    return .{ .items = items, .allocator = allocator };
}

/// Check every code block in an `ObjectTreeRoot`. Each object's code is
/// validated independently with a fresh top-level scope so that
/// functions / variables in one sub-object don't bleed into another.
/// Diagnostics from all blocks are merged into one list.
pub fn checkTree(allocator: std.mem.Allocator, root: *const ObjectTreeRoot) !Diagnostics {
    const ast_view = root.asAst();
    var diags: std.ArrayListUnmanaged(Diagnostic) = .{};
    errdefer diags.deinit(allocator);

    try checkObjectRecursive(allocator, &ast_view, &root.root, &diags);

    const items = try diags.toOwnedSlice(allocator);
    return .{ .items = items, .allocator = allocator };
}

fn checkObjectRecursive(
    allocator: std.mem.Allocator,
    ast: *const AST,
    obj: *const ObjectTree,
    out: *std.ArrayListUnmanaged(Diagnostic),
) !void {
    if (obj.code_root != AST.null_node) {
        try checkCodeRoot(allocator, ast, obj.code_root, out);
    }
    for (obj.children) |*child| {
        try checkObjectRecursive(allocator, ast, child, out);
    }
}

/// Run the per-block checks against a single `code { ... }` body
/// (a `.block` node). Internal helper used by both `check` (legacy) and
/// `checkTree`. Diagnostics are appended to `out`.
fn checkCodeRoot(
    allocator: std.mem.Allocator,
    ast: *const AST,
    code_idx: AST.NodeIndex,
    out: *std.ArrayListUnmanaged(Diagnostic),
) !void {
    var self = Self{
        .allocator = allocator,
        .ast = ast,
        .diags = .{},
        .scopes = .{},
        .loop_body_depth = 0,
        .function_body_depth = 0,
        .in_for_pre = false,
        .in_for_post = false,
    };
    defer {
        for (self.scopes.items) |*s| s.deinit(allocator);
        self.scopes.deinit(allocator);
    }

    try self.pushScope();
    const code_node = ast.nodes[code_idx];
    if (code_node == .block) {
        try self.checkBlockStmts(ast.spanToList(code_node.block.stmts));
    }
    self.popScope();

    // Move diagnostics from `self.diags` into `out`.
    try out.appendSlice(allocator, self.diags.items);
    self.diags.deinit(allocator);
}

// ── Scope helpers ───────────────────────────────────────────────────

fn pushScope(self: *Self) !void {
    try self.scopes.append(self.allocator, .{});
}

fn popScope(self: *Self) void {
    var s = self.scopes.pop().?;
    s.deinit(self.allocator);
}

fn currentScope(self: *Self) *Scope {
    return &self.scopes.items[self.scopes.items.len - 1];
}

fn declareName(self: *Self, name: []const u8, kind: DeclKind, token: AST.TokenIndex) !void {
    if (isBuiltinName(name)) {
        try self.diag(.shadows_builtin, token, name);
        return;
    }

    // Same-scope clash
    if (self.currentScope().names.get(name)) |existing| {
        const dk: DiagnosticKind = if (kind == .function and existing.kind == .function)
            .function_redefinition
        else
            .redeclared_in_scope;
        try self.diag(dk, token, name);
        return;
    }

    // Outer-scope shadowing
    if (self.scopes.items.len > 1) {
        var i: usize = self.scopes.items.len - 1;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].names.contains(name)) {
                try self.diag(.shadows_outer, token, name);
                break;
            }
        }
    }

    try self.currentScope().names.put(self.allocator, name, .{ .kind = kind, .token = token });
}

fn diag(self: *Self, kind: DiagnosticKind, token: AST.TokenIndex, name: []const u8) !void {
    try self.diags.append(self.allocator, .{ .kind = kind, .token = token, .name = name });
}

// ── Statement walking ───────────────────────────────────────────────

fn checkBlock(self: *Self, block_idx: AST.NodeIndex) !void {
    const stmts = self.ast.spanToList(self.ast.nodes[block_idx].block.stmts);
    try self.pushScope();
    defer self.popScope();
    try self.checkBlockStmts(stmts);
}

fn checkBlockStmts(self: *Self, stmts: []const AST.NodeIndex) !void {
    // Hoist function names first.
    for (stmts) |idx| {
        switch (self.ast.nodes[idx]) {
            .function_definition => |fd| {
                const name = self.ast.tokenSlice(fd.name);
                try self.declareName(name, .function, fd.name);
            },
            else => {},
        }
    }

    for (stmts) |idx| try self.checkStmt(idx);
}

fn checkStmt(self: *Self, node_idx: AST.NodeIndex) std.mem.Allocator.Error!void {
    const node = self.ast.nodes[node_idx];
    switch (node) {
        .block => try self.checkBlock(node_idx),

        .function_definition => |fd| {
            // Function body is a fresh scope. Save / restore the
            // loop depth so an enclosing loop's break/continue context
            // does not leak into the function body.
            const saved_loop = self.loop_body_depth;
            self.loop_body_depth = 0;
            self.function_body_depth += 1;
            defer {
                self.function_body_depth -= 1;
                self.loop_body_depth = saved_loop;
            }

            try self.pushScope();
            defer self.popScope();

            // Parameters
            const param_nodes = self.ast.spanToList(fd.params);
            for (param_nodes) |p| {
                const tok = self.ast.nodes[p].identifier.token;
                const name = self.ast.tokenSlice(tok);
                if (self.currentScope().names.contains(name)) {
                    try self.diag(.duplicate_parameter, tok, name);
                } else {
                    try self.declareName(name, .variable, tok);
                }
            }
            // Return vars
            const ret_nodes = self.ast.spanToList(fd.return_vars);
            for (ret_nodes) |r| {
                const tok = self.ast.nodes[r].identifier.token;
                const name = self.ast.tokenSlice(tok);
                if (self.currentScope().names.contains(name)) {
                    try self.diag(.duplicate_return_var, tok, name);
                } else {
                    try self.declareName(name, .variable, tok);
                }
            }
            // Body — checkBlockStmts (no extra scope, already inside function scope)
            const body_stmts = self.ast.spanToList(self.ast.nodes[fd.body].block.stmts);
            try self.checkBlockStmts(body_stmts);
        },

        .variable_declaration => |vd| {
            const name_nodes = self.ast.spanToList(vd.names);
            // First, check the rhs (in the scope before the new names go in).
            if (vd.value != AST.null_node) try self.checkExpr(vd.value);
            // Then declare each name.
            for (name_nodes) |n| {
                const tok = self.ast.nodes[n].identifier.token;
                const nm = self.ast.tokenSlice(tok);
                try self.declareName(nm, .variable, tok);
            }
        },

        .assignment => |a| {
            try self.checkExpr(a.value);
            // Targets are looked up at runtime; no static checks needed.
        },

        .if_statement => |is| {
            try self.checkExpr(is.condition);
            try self.checkBlock(is.body);
        },

        .switch_statement => |sw| {
            try self.checkExpr(sw.expr);
            // Walk cases, looking for duplicate literal values.
            const cases = self.ast.spanToList(sw.cases);

            // Track seen case literal token texts as a quick proxy.
            // Robust dup detection would parse them, but solc's check
            // uses canonical literal form too.
            var seen: std.StringHashMapUnmanaged(void) = .{};
            defer seen.deinit(self.allocator);
            var has_default = false;

            for (cases) |c| switch (self.ast.nodes[c]) {
                .case_clause => |cc| {
                    const tok = self.ast.nodes[cc.value].getToken();
                    const text = self.ast.tokenSlice(tok);
                    if (seen.contains(text)) {
                        try self.diag(.duplicate_case, tok, text);
                    } else {
                        try seen.put(self.allocator, text, {});
                    }
                    try self.checkBlock(cc.body);
                },
                .case_default => |cd| {
                    if (has_default) try self.diag(.duplicate_case, cd.token, "default");
                    has_default = true;
                    try self.checkBlock(cd.body);
                },
                else => {},
            };
        },

        .for_loop => |fl| {
            // Per spec, the for-loop's pre block establishes a scope
            // that also covers the cond / post / body. We model that as
            // a single scope around the whole loop.
            try self.pushScope();
            defer self.popScope();

            // Pre block: walk its statements directly (no extra scope).
            // break/continue/leave are not allowed inside the pre block.
            const pre_stmts = self.ast.spanToList(self.ast.nodes[fl.pre].block.stmts);
            const saved_pre = self.in_for_pre;
            self.in_for_pre = true;
            try self.checkBlockStmts(pre_stmts);
            self.in_for_pre = saved_pre;

            try self.checkExpr(fl.condition);

            // Post block: same — no scope, no break/continue/leave.
            const saved_post = self.in_for_post;
            self.in_for_post = true;
            const post_stmts = self.ast.spanToList(self.ast.nodes[fl.post].block.stmts);
            try self.checkBlockStmts(post_stmts);
            self.in_for_post = saved_post;

            // Body: scope created inside checkBlock, plus loop depth bump.
            self.loop_body_depth += 1;
            defer self.loop_body_depth -= 1;
            try self.checkBlock(fl.body);
        },

        .@"break" => |b| {
            if (self.in_for_pre) {
                try self.diag(.break_in_for_pre, b.token, "break");
            } else if (self.in_for_post) {
                try self.diag(.break_in_for_post, b.token, "break");
            } else if (self.loop_body_depth == 0) {
                try self.diag(.break_outside_loop, b.token, "break");
            }
        },
        .@"continue" => |c| {
            if (self.in_for_pre) {
                try self.diag(.continue_in_for_pre, c.token, "continue");
            } else if (self.in_for_post) {
                try self.diag(.continue_in_for_post, c.token, "continue");
            } else if (self.loop_body_depth == 0) {
                try self.diag(.continue_outside_loop, c.token, "continue");
            }
        },
        .leave => |lv| {
            if (self.in_for_pre) {
                try self.diag(.leave_in_for_pre, lv.token, "leave");
            } else if (self.in_for_post) {
                try self.diag(.leave_in_for_post, lv.token, "leave");
            } else if (self.function_body_depth == 0) {
                try self.diag(.leave_outside_function, lv.token, "leave");
            }
        },

        .expression_statement => |e| try self.checkExpr(e.expr),

        else => {},
    }
}

// ── Expression walking (only descends into function calls) ─────────

fn checkExpr(self: *Self, node_idx: AST.NodeIndex) std.mem.Allocator.Error!void {
    const node = self.ast.nodes[node_idx];
    switch (node) {
        .function_call => |fc| {
            const args = self.ast.spanToList(fc.args);
            for (args) |a| try self.checkExpr(a);
        },
        else => {},
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn expectDiagKinds(source: [:0]const u8, expected: []const DiagnosticKind) !void {
    const allocator = testing.allocator;
    var ast = try AST.parse(allocator, source);
    defer ast.deinit(allocator);
    var diags = try check(allocator, &ast);
    defer diags.deinit();
    if (diags.items.len != expected.len) {
        std.debug.print("expected {d} diagnostics, got {d}:\n", .{ expected.len, diags.items.len });
        for (diags.items) |d| std.debug.print("  {s} '{s}'\n", .{ @tagName(d.kind), d.name });
        return error.UnexpectedCount;
    }
    for (expected, diags.items) |exp, got| {
        try testing.expectEqual(exp, got.kind);
    }
}

fn expectClean(source: [:0]const u8) !void {
    try expectDiagKinds(source, &.{});
}

test "checker: clean program" {
    try expectClean("{ let x := 1 sstore(0, x) }");
}

test "checker: redeclaration in same block" {
    try expectDiagKinds(
        "{ let x := 1 let x := 2 }",
        &.{.redeclared_in_scope},
    );
}

test "checker: shadowing in nested block" {
    try expectDiagKinds(
        "{ let x := 1 { let x := 2 } }",
        &.{.shadows_outer},
    );
}

test "checker: builtin name as variable" {
    try expectDiagKinds(
        "{ let add := 1 }",
        &.{.shadows_builtin},
    );
}

test "checker: function redefinition" {
    try expectDiagKinds(
        "{ function f() {} function f() {} }",
        &.{.function_redefinition},
    );
}

test "checker: function name shadows builtin" {
    try expectDiagKinds(
        "{ function add() {} }",
        &.{.shadows_builtin},
    );
}

test "checker: duplicate parameter" {
    try expectDiagKinds(
        "{ function f(a, a) {} }",
        &.{.duplicate_parameter},
    );
}

test "checker: duplicate return var" {
    try expectDiagKinds(
        "{ function f() -> r, r {} }",
        &.{.duplicate_return_var},
    );
}

test "checker: parameter shadows outer var" {
    try expectDiagKinds(
        "{ let x function f(x) {} }",
        &.{.shadows_outer},
    );
}

test "checker: break outside loop" {
    try expectDiagKinds("{ break }", &.{.break_outside_loop});
}

test "checker: continue outside loop" {
    try expectDiagKinds("{ continue }", &.{.continue_outside_loop});
}

test "checker: leave outside function" {
    try expectDiagKinds("{ leave }", &.{.leave_outside_function});
}

test "checker: break inside for loop body OK" {
    try expectClean("{ for {} 1 {} { break } }");
}

test "checker: break in for-loop pre block" {
    try expectDiagKinds(
        "{ for { break } 1 {} {} }",
        &.{.break_in_for_pre},
    );
}

test "checker: continue in for-loop post block" {
    try expectDiagKinds(
        "{ for {} 1 { continue } {} }",
        &.{.continue_in_for_post},
    );
}

test "checker: leave inside for loop body inside function" {
    try expectClean(
        "{ function f() { for {} 1 {} { leave } } }",
    );
}

test "checker: break does not leak across function boundary" {
    // The function is inside a loop body, but inside the function,
    // break is invalid because the loop is in the outer context.
    try expectDiagKinds(
        "{ for {} 1 {} { function f() { break } } }",
        &.{.break_outside_loop},
    );
}

test "checker: switch duplicate case" {
    try expectDiagKinds(
        "{ switch 1 case 1 {} case 1 {} }",
        &.{.duplicate_case},
    );
}

test "checker: switch with default and unique cases is clean" {
    try expectClean(
        "{ switch 1 case 0 {} case 1 {} default {} }",
    );
}

test "checker: function hoisting allows forward call" {
    try expectClean(
        "{ pop(f()) function f() -> r { r := 1 } }",
    );
}

test "checker: variable redeclared via let in same scope after use" {
    try expectDiagKinds(
        "{ let x := 1 sstore(0, x) let x := 2 }",
        &.{.redeclared_in_scope},
    );
}

test "checkTree: clean nested object source" {
    const allocator = testing.allocator;
    const source: [:0]const u8 =
        \\object "C" {
        \\  code { let x := 42 sstore(0, x) }
        \\  object "C_deployed" {
        \\    code { let y := sload(0) mstore(0, y) return(0, 32) }
        \\  }
        \\}
    ;
    var result = try AST.parseAny(allocator, source);
    defer result.deinit(allocator);
    try testing.expect(result == .tree);
    var diags = try checkTree(allocator, &result.tree);
    defer diags.deinit();
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "checkTree: error in sub-object code is reported" {
    const allocator = testing.allocator;
    const source: [:0]const u8 =
        \\object "C" {
        \\  code { let x := 1 }
        \\  object "C_deployed" {
        \\    code { let y := 1 let y := 2 }
        \\  }
        \\}
    ;
    var result = try AST.parseAny(allocator, source);
    defer result.deinit(allocator);
    var diags = try checkTree(allocator, &result.tree);
    defer diags.deinit();
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(DiagnosticKind.redeclared_in_scope, diags.items[0].kind);
}

test "checkTree: code blocks have isolated scopes" {
    // A function `f` defined in the constructor must NOT collide with a
    // function `f` in the runtime — they're in different code roots.
    const allocator = testing.allocator;
    const source: [:0]const u8 =
        \\object "C" {
        \\  code { function f() { sstore(0, 1) } f() }
        \\  object "C_deployed" {
        \\    code { function f() { sstore(0, 2) } f() }
        \\  }
        \\}
    ;
    var result = try AST.parseAny(allocator, source);
    defer result.deinit(allocator);
    var diags = try checkTree(allocator, &result.tree);
    defer diags.deinit();
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}
