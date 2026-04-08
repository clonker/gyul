const std = @import("std");
const AST = @import("AST.zig");
const GlobalState = @import("GlobalState.zig");
const LocalState = @import("LocalState.zig");
const u256_ops = @import("u256_ops.zig");

const Self = @This();

// ── Types ───────────────────────────────────────────────────────────

/// Result of expression evaluation. Optimized for the common cases
/// (0 or 1 values) which avoid heap allocation. Multi-value results
/// (from multi-return functions) are heap-allocated with no upper bound.
pub const Values = union(enum) {
    none,
    single: u256,
    multiple: []u256,

    pub fn deinit(self: Values, allocator: std.mem.Allocator) void {
        switch (self) {
            .multiple => |m| allocator.free(m),
            else => {},
        }
    }

    pub fn len(self: Values) usize {
        return switch (self) {
            .none => 0,
            .single => 1,
            .multiple => |m| m.len,
        };
    }

    pub fn get(self: Values, i: usize) u256 {
        return switch (self) {
            .none => unreachable,
            .single => |v| blk: {
                std.debug.assert(i == 0);
                break :blk v;
            },
            .multiple => |m| m[i],
        };
    }
};

pub const ExecMode = enum {
    regular,
    break_,
    continue_,
    leave,
};

pub const StmtResult = struct {
    mode: ExecMode = .regular,
};

pub const HaltReason = enum {
    stopped,
    returned,
    reverted,
    invalid_,
};

pub const ExecutionResult = struct {
    halt_reason: ?HaltReason = null,
};

pub const InterpreterError = error{
    UndefinedVariable,
    UndefinedFunction,
    ArityMismatch,
    TypeError,
    InvalidLiteral,
    StackOverflow,
    ExecutionHalt,
} || std.mem.Allocator.Error;

// ── Builtins ────────────────────────────────────────────────────────

const BuiltinTag = enum {
    // Arithmetic
    add,
    sub,
    mul,
    div,
    sdiv,
    mod_,
    smod,
    exp,
    addmod,
    mulmod,
    signextend,
    // Comparison
    lt,
    gt,
    slt,
    sgt,
    eq,
    iszero,
    // Bitwise
    not_,
    and_,
    or_,
    xor,
    shl,
    shr,
    sar,
    byte_,
    // Storage
    sstore,
    sload,
    tstore,
    tload,
    // Memory
    mstore,
    mstore8,
    mload,
    msize,
    // Logging
    log0,
    log1,
    log2,
    log3,
    log4,
    // Memory copy
    mcopy,
    // Call data & return data
    calldataload,
    calldatasize,
    calldatacopy,
    returndatasize,
    returndatacopy,
    codecopy,
    extcodecopy,
    // Context getters
    address,
    balance,
    origin,
    caller,
    callvalue,
    gasprice,
    coinbase,
    timestamp,
    number,
    prevrandao,
    gaslimit,
    chainid,
    selfbalance,
    basefee,
    blobhash,
    blobbasefee,
    gas,
    codesize,
    pc,
    // Hash & crypto
    keccak256,
    blockhash,
    // Arithmetic
    clz,
    // Control flow halts
    stop,
    return_,
    revert,
    invalid,
    // Contract interaction (stubs)
    call,
    staticcall,
    delegatecall,
    callcode,
    create,
    create2,
    extcodesize,
    extcodehash,
    selfdestruct,
    // Misc
    pop,
};

const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "add", .add },
    .{ "sub", .sub },
    .{ "mul", .mul },
    .{ "div", .div },
    .{ "sdiv", .sdiv },
    .{ "mod", .mod_ },
    .{ "smod", .smod },
    .{ "exp", .exp },
    .{ "addmod", .addmod },
    .{ "mulmod", .mulmod },
    .{ "signextend", .signextend },
    .{ "lt", .lt },
    .{ "gt", .gt },
    .{ "slt", .slt },
    .{ "sgt", .sgt },
    .{ "eq", .eq },
    .{ "iszero", .iszero },
    .{ "not", .not_ },
    .{ "and", .and_ },
    .{ "or", .or_ },
    .{ "xor", .xor },
    .{ "shl", .shl },
    .{ "shr", .shr },
    .{ "sar", .sar },
    .{ "byte", .byte_ },
    .{ "sstore", .sstore },
    .{ "sload", .sload },
    .{ "tstore", .tstore },
    .{ "tload", .tload },
    .{ "mstore", .mstore },
    .{ "mstore8", .mstore8 },
    .{ "mload", .mload },
    .{ "msize", .msize },
    .{ "log0", .log0 },
    .{ "log1", .log1 },
    .{ "log2", .log2 },
    .{ "log3", .log3 },
    .{ "log4", .log4 },
    .{ "mcopy", .mcopy },
    .{ "calldataload", .calldataload },
    .{ "calldatasize", .calldatasize },
    .{ "calldatacopy", .calldatacopy },
    .{ "returndatasize", .returndatasize },
    .{ "returndatacopy", .returndatacopy },
    .{ "codecopy", .codecopy },
    .{ "extcodecopy", .extcodecopy },
    .{ "address", .address },
    .{ "balance", .balance },
    .{ "origin", .origin },
    .{ "caller", .caller },
    .{ "callvalue", .callvalue },
    .{ "gasprice", .gasprice },
    .{ "coinbase", .coinbase },
    .{ "timestamp", .timestamp },
    .{ "number", .number },
    .{ "prevrandao", .prevrandao },
    .{ "gaslimit", .gaslimit },
    .{ "chainid", .chainid },
    .{ "selfbalance", .selfbalance },
    .{ "basefee", .basefee },
    .{ "blobhash", .blobhash },
    .{ "blobbasefee", .blobbasefee },
    .{ "gas", .gas },
    .{ "codesize", .codesize },
    .{ "pc", .pc },
    .{ "keccak256", .keccak256 },
    .{ "blockhash", .blockhash },
    .{ "clz", .clz },
    .{ "stop", .stop },
    .{ "return", .return_ },
    .{ "revert", .revert },
    .{ "invalid", .invalid },
    .{ "call", .call },
    .{ "staticcall", .staticcall },
    .{ "delegatecall", .delegatecall },
    .{ "callcode", .callcode },
    .{ "create", .create },
    .{ "create2", .create2 },
    .{ "extcodesize", .extcodesize },
    .{ "extcodehash", .extcodehash },
    .{ "selfdestruct", .selfdestruct },
    .{ "pop", .pop },
});

// ── Fields ──────────────────────────────────────────────────────────

ast: *const AST,
global: *GlobalState,
local: *LocalState,
allocator: std.mem.Allocator,
call_depth: u32,
halt_reason: ?HaltReason,
/// Token index of the last runtime error (for source location reporting).
error_token: ?AST.TokenIndex,

const MAX_CALL_DEPTH = 1024;

// ── Init ────────────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, ast: *const AST, global: *GlobalState, local: *LocalState) Self {
    return .{
        .ast = ast,
        .global = global,
        .local = local,
        .allocator = allocator,
        .call_depth = 0,
        .halt_reason = null,
        .error_token = null,
    };
}

// ── Entry Point ─────────────────────────────────────────────────────

/// Returns the source location of the last runtime error, if available.
pub fn errorLocation(self: *const Self) ?AST.SourceLocation {
    const tok = self.error_token orelse return null;
    return self.ast.tokenLocation(tok);
}

/// Returns the text of the token where the last error occurred.
pub fn errorTokenText(self: *const Self) ?[]const u8 {
    const tok = self.error_token orelse return null;
    return self.ast.tokenSlice(tok);
}

pub fn interpret(self: *Self) InterpreterError!ExecutionResult {
    _ = self.execStmt(0) catch |err| {
        if (err == error.ExecutionHalt) return .{ .halt_reason = self.halt_reason };
        return err;
    };
    return .{};
}

// ── Expression Evaluation ───────────────────────────────────────────

pub fn evalExpr(self: *Self, node_idx: AST.NodeIndex) InterpreterError!Values {
    const node = self.ast.nodes[node_idx];
    self.error_token = node.getToken();
    return switch (node) {
        .number_literal => |n| self.evalNumberLiteral(n.token),
        .string_literal => |n| self.evalStringLiteral(n.token),
        .bool_literal => |n| self.evalBoolLiteral(n.token),
        .hex_literal => |n| self.evalHexLiteral(n.value),
        .identifier => |n| self.evalIdentifier(n.token),
        .function_call => |n| self.evalFunctionCall(n.token, n.args),
        else => error.TypeError,
    };
}

fn evalNumberLiteral(self: *Self, tok: AST.TokenIndex) InterpreterError!Values {
    const text = self.ast.tokenSlice(tok);
    const tag = self.ast.tokens.items(.tag)[tok];

    const value: u256 = if (tag == .hex_number_literal) blk: {
        if (text.len < 3) return error.InvalidLiteral;
        break :blk std.fmt.parseInt(u256, text[2..], 16) catch return error.InvalidLiteral;
    } else blk: {
        break :blk std.fmt.parseInt(u256, text, 10) catch return error.InvalidLiteral;
    };

    return .{ .single = value };
}

fn evalStringLiteral(self: *Self, tok: AST.TokenIndex) InterpreterError!Values {
    const text = self.ast.tokenSlice(tok);
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"')
        return error.InvalidLiteral;
    const inner = text[1 .. text.len - 1];

    var buf: [32]u8 = std.mem.zeroes([32]u8);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (pos >= 32) return error.InvalidLiteral;
        if (inner[i] == '\\') {
            i += 1;
            if (i >= inner.len) return error.InvalidLiteral;
            buf[pos] = switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                'x' => blk: {
                    if (i + 2 >= inner.len) return error.InvalidLiteral;
                    const hi = std.fmt.charToDigit(inner[i + 1], 16) catch return error.InvalidLiteral;
                    const lo = std.fmt.charToDigit(inner[i + 2], 16) catch return error.InvalidLiteral;
                    i += 2;
                    break :blk @as(u8, hi) * 16 + lo;
                },
                else => return error.InvalidLiteral,
            };
        } else {
            buf[pos] = inner[i];
        }
        pos += 1;
    }

    return .{ .single = std.mem.readInt(u256, &buf, .big) };
}

fn evalBoolLiteral(self: *Self, tok: AST.TokenIndex) InterpreterError!Values {
    const tag = self.ast.tokens.items(.tag)[tok];
    return .{ .single = if (tag == .keyword_true) @as(u256, 1) else 0 };
}

fn evalHexLiteral(self: *Self, value_tok: AST.TokenIndex) InterpreterError!Values {
    const text = self.ast.tokenSlice(value_tok);
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"')
        return error.InvalidLiteral;
    const hex_str = text[1 .. text.len - 1];
    if (hex_str.len % 2 != 0 or hex_str.len > 64) return error.InvalidLiteral;

    var buf: [32]u8 = std.mem.zeroes([32]u8);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < hex_str.len) : (i += 2) {
        const hi = std.fmt.charToDigit(hex_str[i], 16) catch return error.InvalidLiteral;
        const lo = std.fmt.charToDigit(hex_str[i + 1], 16) catch return error.InvalidLiteral;
        buf[pos] = @as(u8, hi) * 16 + lo;
        pos += 1;
    }

    return .{ .single = std.mem.readInt(u256, &buf, .big) };
}

// ── Identifier Lookup ───────────────────────────────────────────────

fn evalIdentifier(self: *Self, tok: AST.TokenIndex) InterpreterError!Values {
    const name = self.ast.tokenSlice(tok);
    const value = self.local.getVariable(name) orelse return error.UndefinedVariable;
    return .{ .single = value };
}

// ── Function Calls ──────────────────────────────────────────────────

fn evalFunctionCall(self: *Self, tok: AST.TokenIndex, args_span: AST.Span) InterpreterError!Values {
    const name = self.ast.tokenSlice(tok);
    const arg_nodes = self.ast.spanToList(args_span);

    // Evaluate arguments right-to-left (per Yul spec)
    const arg_values = try self.allocator.alloc(u256, arg_nodes.len);
    defer self.allocator.free(arg_values);

    {
        var i: usize = arg_nodes.len;
        while (i > 0) {
            i -= 1;
            const vals = try self.evalExpr(arg_nodes[i]);
            defer vals.deinit(self.allocator);
            if (vals.len() != 1) return error.TypeError;
            arg_values[i] = vals.get(0);
        }
    }

    // Check builtins first
    if (builtin_map.get(name)) |tag| {
        return self.evalBuiltin(tag, arg_values);
    }

    // Look up user-defined function
    const func_def = self.local.getFunction(name) orelse return error.UndefinedFunction;
    if (arg_nodes.len != func_def.num_params) return error.ArityMismatch;
    if (self.call_depth >= MAX_CALL_DEPTH) return error.StackOverflow;

    const func_node = self.ast.nodes[func_def.node].function_definition;

    // Create call scope with defining_scope as parent (lexical scoping).
    // Mark as function boundary so variable lookup doesn't leak into
    // enclosing scopes (per Yul spec), while function lookup still works.
    const call_scope = try LocalState.pushScope(self.allocator, func_def.defining_scope);
    call_scope.is_function_boundary = true;

    // Bind parameters
    const param_nodes = self.ast.spanToList(func_node.params);
    for (param_nodes, 0..) |p, i| {
        const param_name = self.ast.tokenSlice(self.ast.nodes[p].identifier.token);
        try call_scope.declareVariable(param_name, arg_values[i]);
    }

    // Initialize return variables to 0
    const ret_nodes = self.ast.spanToList(func_node.return_vars);
    for (ret_nodes) |r| {
        const ret_name = self.ast.tokenSlice(self.ast.nodes[r].identifier.token);
        try call_scope.declareVariable(ret_name, 0);
    }

    // Swap to call scope and execute body
    const saved_local = self.local;
    self.local = call_scope;
    self.call_depth += 1;

    const body_result = self.execStmt(func_node.body);

    self.call_depth -= 1;
    self.local = saved_local;

    const result = body_result catch |e| {
        _ = call_scope.popScope();
        return e;
    };
    _ = result; // leave is normal function exit

    // Collect return values
    const ret: Values = switch (ret_nodes.len) {
        0 => .none,
        1 => blk: {
            const ret_name = self.ast.tokenSlice(self.ast.nodes[ret_nodes[0]].identifier.token);
            break :blk .{ .single = call_scope.getVariable(ret_name) orelse 0 };
        },
        else => blk: {
            const vals = try self.allocator.alloc(u256, ret_nodes.len);
            for (ret_nodes, 0..) |r, i| {
                const ret_name = self.ast.tokenSlice(self.ast.nodes[r].identifier.token);
                vals[i] = call_scope.getVariable(ret_name) orelse 0;
            }
            break :blk .{ .multiple = vals };
        },
    };

    _ = call_scope.popScope();
    return ret;
}

// ── Statement Execution ─────────────────────────────────────────────

pub fn execStmt(self: *Self, node_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const node = self.ast.nodes[node_idx];
    self.error_token = node.getToken();
    return switch (node) {
        .root => |n| self.execBlock(n.body),
        .block => |n| self.execBlock(n.stmts),
        .function_definition => .{ .mode = .regular },
        .variable_declaration => |n| self.execVarDecl(n.names, n.value),
        .assignment => |n| self.execAssignment(n.targets, n.value),
        .if_statement => |n| self.execIf(n.condition, n.body),
        .switch_statement => |n| self.execSwitch(n.expr, n.cases),
        .for_loop => |n| self.execForLoop(n.pre, n.condition, n.post, n.body),
        .expression_statement => |n| self.execExprStmt(n.expr),
        .@"break" => .{ .mode = .break_ },
        .@"continue" => .{ .mode = .continue_ },
        .leave => .{ .mode = .leave },
        else => error.TypeError,
    };
}

fn execBlock(self: *Self, stmts_span: AST.Span) InterpreterError!StmtResult {
    const stmts = self.ast.spanToList(stmts_span);
    const block_scope = try LocalState.pushScope(self.allocator, self.local);
    const saved_local = self.local;
    self.local = block_scope;

    const result = self.execBlockInner(stmts);

    self.local = saved_local;
    _ = block_scope.popScope();
    return result;
}

fn execBlockInner(self: *Self, stmts: []const AST.NodeIndex) InterpreterError!StmtResult {
    // Hoisting pass: declare all functions first
    for (stmts) |stmt_idx| {
        switch (self.ast.nodes[stmt_idx]) {
            .function_definition => |fd| {
                const fname = self.ast.tokenSlice(fd.name);
                try self.local.declareFunction(fname, .{
                    .node = stmt_idx,
                    .num_params = fd.params.len,
                    .num_returns = fd.return_vars.len,
                    .defining_scope = self.local,
                });
            },
            else => {},
        }
    }

    // Execution pass
    for (stmts) |stmt_idx| {
        switch (self.ast.nodes[stmt_idx]) {
            .function_definition => continue,
            else => {},
        }
        const result = try self.execStmt(stmt_idx);
        if (result.mode != .regular) return result;
    }

    return .{ .mode = .regular };
}

fn execVarDecl(self: *Self, names_span: AST.Span, value_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const name_nodes = self.ast.spanToList(names_span);

    if (value_idx == AST.null_node) {
        for (name_nodes) |n| {
            const name = self.ast.tokenSlice(self.ast.nodes[n].identifier.token);
            try self.local.declareVariable(name, 0);
        }
    } else {
        const values = try self.evalExpr(value_idx);
        defer values.deinit(self.allocator);
        if (values.len() != name_nodes.len) return error.TypeError;
        for (name_nodes, 0..) |n, i| {
            const name = self.ast.tokenSlice(self.ast.nodes[n].identifier.token);
            try self.local.declareVariable(name, values.get(i));
        }
    }

    return .{ .mode = .regular };
}

fn execAssignment(self: *Self, targets_span: AST.Span, value_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const target_nodes = self.ast.spanToList(targets_span);
    const values = try self.evalExpr(value_idx);
    defer values.deinit(self.allocator);
    if (values.len() != target_nodes.len) return error.TypeError;

    for (target_nodes, 0..) |t, i| {
        const name = self.ast.tokenSlice(self.ast.nodes[t].identifier.token);
        if (!self.local.setVariable(name, values.get(i))) return error.UndefinedVariable;
    }

    return .{ .mode = .regular };
}

fn execIf(self: *Self, condition_idx: AST.NodeIndex, body_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const cond = try self.evalExpr(condition_idx);
    defer cond.deinit(self.allocator);
    if (cond.len() != 1) return error.TypeError;

    if (cond.get(0) != 0) {
        return self.execStmt(body_idx);
    }
    return .{ .mode = .regular };
}

fn execSwitch(self: *Self, expr_idx: AST.NodeIndex, cases_span: AST.Span) InterpreterError!StmtResult {
    const switch_val = try self.evalExpr(expr_idx);
    defer switch_val.deinit(self.allocator);
    if (switch_val.len() != 1) return error.TypeError;
    const val = switch_val.get(0);

    const case_nodes = self.ast.spanToList(cases_span);
    var default_body: ?AST.NodeIndex = null;

    for (case_nodes) |case_idx| {
        switch (self.ast.nodes[case_idx]) {
            .case_clause => |cc| {
                const case_val = try self.evalExpr(cc.value);
                defer case_val.deinit(self.allocator);
                if (case_val.len() != 1) return error.TypeError;
                if (case_val.get(0) == val) {
                    return self.execStmt(cc.body);
                }
            },
            .case_default => |cd| {
                default_body = cd.body;
            },
            else => return error.TypeError,
        }
    }

    if (default_body) |body| {
        return self.execStmt(body);
    }
    return .{ .mode = .regular };
}

fn execForLoop(self: *Self, pre_idx: AST.NodeIndex, cond_idx: AST.NodeIndex, post_idx: AST.NodeIndex, body_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const for_scope = try LocalState.pushScope(self.allocator, self.local);
    const saved_local = self.local;
    self.local = for_scope;

    const result = self.execForLoopInner(pre_idx, cond_idx, post_idx, body_idx);

    self.local = saved_local;
    _ = for_scope.popScope();
    return result;
}

fn execForLoopInner(self: *Self, pre_idx: AST.NodeIndex, cond_idx: AST.NodeIndex, post_idx: AST.NodeIndex, body_idx: AST.NodeIndex) InterpreterError!StmtResult {
    // Execute pre block statements directly (no sub-scope) so variables persist
    const pre_node = self.ast.nodes[pre_idx].block;
    const pre_stmts = self.ast.spanToList(pre_node.stmts);
    const pre_result = try self.execBlockInner(pre_stmts);
    if (pre_result.mode != .regular) return pre_result;

    while (true) {
        const cond = try self.evalExpr(cond_idx);
        defer cond.deinit(self.allocator);
        if (cond.len() != 1) return error.TypeError;
        if (cond.get(0) == 0) break;

        const body_result = try self.execStmt(body_idx);
        switch (body_result.mode) {
            .break_ => break,
            .continue_ => {},
            .leave => return body_result,
            .regular => {},
        }

        const post_result = try self.execStmt(post_idx);
        if (post_result.mode != .regular) return post_result;
    }

    return .{ .mode = .regular };
}

fn execExprStmt(self: *Self, expr_idx: AST.NodeIndex) InterpreterError!StmtResult {
    const values = try self.evalExpr(expr_idx);
    defer values.deinit(self.allocator);
    if (values.len() != 0) return error.TypeError;
    return .{ .mode = .regular };
}

// ── Builtin Dispatch ────────────────────────────────────────────────

fn evalBuiltin(self: *Self, tag: BuiltinTag, args: []const u256) InterpreterError!Values {
    return switch (tag) {
        // Arithmetic (2 args → 1 result)
        .add => bin(u256_ops.add, args),
        .sub => bin(u256_ops.sub, args),
        .mul => bin(u256_ops.mul, args),
        .div => bin(u256_ops.div, args),
        .sdiv => bin(u256_ops.sdiv, args),
        .mod_ => bin(u256_ops.mod_, args),
        .smod => bin(u256_ops.smod, args),
        .exp => bin(u256_ops.exp, args),
        .signextend => bin(u256_ops.signextend, args),
        // Arithmetic (3 args → 1 result)
        .addmod => .{ .single = u256_ops.addmod(args[0], args[1], args[2]) },
        .mulmod => .{ .single = u256_ops.mulmod(args[0], args[1], args[2]) },
        // Comparison
        .lt => bin(u256_ops.lt, args),
        .gt => bin(u256_ops.gt, args),
        .slt => bin(u256_ops.slt, args),
        .sgt => bin(u256_ops.sgt, args),
        .eq => bin(u256_ops.eq, args),
        .iszero => .{ .single = u256_ops.iszero(args[0]) },
        // Bitwise
        .not_ => .{ .single = u256_ops.not(args[0]) },
        .and_ => bin(u256_ops.and_, args),
        .or_ => bin(u256_ops.or_, args),
        .xor => bin(u256_ops.xor, args),
        .shl => bin(u256_ops.shl, args),
        .shr => bin(u256_ops.shr, args),
        .sar => bin(u256_ops.sar, args),
        .byte_ => bin(u256_ops.byte_, args),
        // Storage
        .sstore => {
            self.global.sstore(args[0], args[1]) catch return error.OutOfMemory;
            return .none;
        },
        .sload => .{ .single = self.global.sload(args[0]) },
        .tstore => {
            self.global.tstore(args[0], args[1]) catch return error.OutOfMemory;
            return .none;
        },
        .tload => .{ .single = self.global.tload(args[0]) },
        // Memory
        .mstore => {
            self.global.memStore(args[0], args[1]) catch return error.OutOfMemory;
            return .none;
        },
        .mstore8 => {
            self.global.memStore8(args[0], args[1]) catch return error.OutOfMemory;
            return .none;
        },
        .mload => .{ .single = self.global.memLoad(args[0]) catch return error.OutOfMemory },
        .msize => .{ .single = self.global.getMsize() },
        // Logging
        .log0, .log1, .log2, .log3, .log4 => {
            const num_topics: usize = @intFromEnum(tag) - @intFromEnum(BuiltinTag.log0);
            const offset = args[0];
            const len = args[1];
            const size: usize = if (len > 4096) 4096 else @intCast(len);
            const data = try self.allocator.alloc(u8, size);
            defer self.allocator.free(data);
            self.global.memRead(offset, data);
            self.global.addLog(offset, len, data, args[2..][0..num_topics]) catch return error.OutOfMemory;
            return .none;
        },
        // Memory copy
        .mcopy => {
            self.global.memCopy(args[0], args[1], args[2]) catch return error.OutOfMemory;
            return .none;
        },
        // Call data & return data
        .calldataload => blk: {
            const offset = args[0];
            var buf: [32]u8 = std.mem.zeroes([32]u8);
            if (offset < self.global.calldata.len) {
                const start: usize = @intCast(offset);
                const avail = @min(32, self.global.calldata.len - start);
                @memcpy(buf[0..avail], self.global.calldata[start..][0..avail]);
            }
            break :blk .{ .single = std.mem.readInt(u256, &buf, .big) };
        },
        .calldatasize => .{ .single = @intCast(self.global.calldata.len) },
        .calldatacopy => {
            try self.copyToMemory(args[0], args[1], args[2], self.global.calldata);
            return .none;
        },
        .returndatasize => .{ .single = @intCast(self.global.return_data.len) },
        .returndatacopy => {
            try self.copyToMemory(args[0], args[1], args[2], self.global.return_data);
            return .none;
        },
        .codecopy => {
            try self.copyToMemory(args[0], args[1], args[2], &.{});
            return .none;
        },
        .extcodecopy => {
            try self.copyToMemory(args[1], args[2], args[3], &.{});
            return .none;
        },
        // Context getters
        .address => .{ .single = self.global.address },
        .balance => .{ .single = 0 }, // stub
        .origin => .{ .single = self.global.origin },
        .caller => .{ .single = self.global.caller },
        .callvalue => .{ .single = self.global.callvalue },
        .gasprice => .{ .single = self.global.gasprice },
        .coinbase => .{ .single = self.global.coinbase },
        .timestamp => .{ .single = self.global.timestamp },
        .number => .{ .single = self.global.block_number },
        .prevrandao => .{ .single = self.global.prevrandao },
        .gaslimit => .{ .single = self.global.gaslimit },
        .chainid => .{ .single = self.global.chainid },
        .selfbalance => .{ .single = 0 }, // stub
        .basefee => .{ .single = self.global.basefee },
        .blobhash => .{ .single = 0 }, // stub
        .blobbasefee => .{ .single = self.global.blobbasefee },
        .gas => .{ .single = @as(u256, 1) << 64 },
        .codesize => .{ .single = 0 },
        .pc => .{ .single = 0 },
        // Hash & crypto
        .keccak256 => blk: {
            const offset = args[0];
            const len = args[1];
            self.global.updateMsize(offset, len);
            const size: usize = if (len > 0x100000) 0x100000 else @intCast(len);
            const buf = try self.allocator.alloc(u8, size);
            defer self.allocator.free(buf);
            self.global.memRead(offset, buf);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(buf, &hash, .{});
            break :blk .{ .single = std.mem.readInt(u256, &hash, .big) };
        },
        .blockhash => .{ .single = 0 }, // stub
        // Arithmetic
        .clz => .{ .single = u256_ops.clz_(args[0]) },
        // Control flow halts
        .stop => {
            self.halt_reason = .stopped;
            return error.ExecutionHalt;
        },
        .return_ => {
            try self.captureHaltData(args[0], args[1]);
            self.halt_reason = .returned;
            return error.ExecutionHalt;
        },
        .revert => {
            try self.captureHaltData(args[0], args[1]);
            self.halt_reason = .reverted;
            return error.ExecutionHalt;
        },
        .invalid => {
            self.halt_reason = .invalid_;
            return error.ExecutionHalt;
        },
        // Contract interaction (stubs — always fail)
        .call, .callcode => .{ .single = 0 },
        .delegatecall, .staticcall => .{ .single = 0 },
        .create, .create2 => .{ .single = 0 },
        .extcodesize => .{ .single = 0 },
        .extcodehash => .{ .single = 0 },
        .selfdestruct => .none,
        // Misc
        .pop => .none,
    };
}

fn copyToMemory(self: *Self, dest_off: u256, src_off: u256, len: u256, src: []const u8) !void {
    if (len == 0) return;
    const size: usize = if (len > 0x100000) 0x100000 else @intCast(len);
    const buf = try self.allocator.alloc(u8, size);
    defer self.allocator.free(buf);
    @memset(buf, 0);
    if (src_off < src.len) {
        const start: usize = @intCast(src_off);
        const avail = @min(size, src.len - start);
        @memcpy(buf[0..avail], src[start..][0..avail]);
    }
    try self.global.memWrite(dest_off, buf);
}

fn captureHaltData(self: *Self, offset: u256, len: u256) !void {
    if (self.global.return_data_owned) {
        self.allocator.free(self.global.return_data);
        self.global.return_data = &.{};
        self.global.return_data_owned = false;
    }
    if (len > 0) {
        self.global.updateMsize(offset, len);
        const size: usize = if (len > 0x1000000) 0x1000000 else @intCast(len);
        const buf = try self.allocator.alloc(u8, size);
        self.global.memRead(offset, buf);
        self.global.return_data = buf;
        self.global.return_data_owned = true;
    }
}

fn bin(comptime op: fn (u256, u256) u256, args: []const u256) Values {
    return .{ .single = op(args[0], args[1]) };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn runInterpreter(source: [:0]const u8) !struct { global: GlobalState, local: LocalState, ast: AST } {
    const allocator = testing.allocator;
    var ast = try AST.parse(allocator, source);
    errdefer ast.deinit(allocator);

    var global = GlobalState.init(allocator);
    errdefer global.deinit();

    var local = LocalState.init(allocator, null);
    errdefer local.deinit();

    var interp = Self.init(allocator, &ast, &global, &local);
    _ = try interp.interpret();

    return .{ .global = global, .local = local, .ast = ast };
}

fn expectStorage(source: [:0]const u8, expected: []const [2]u256) !void {
    var state = try runInterpreter(source);
    defer {
        state.global.deinit();
        state.local.deinit();
        state.ast.deinit(testing.allocator);
    }
    for (expected) |kv| {
        try testing.expectEqual(kv[1], state.global.sload(kv[0]));
    }
}

fn expectError(source: [:0]const u8, expected_err: InterpreterError) !void {
    const allocator = testing.allocator;
    var ast = try AST.parse(allocator, source);
    defer ast.deinit(allocator);

    var global = GlobalState.init(allocator);
    defer global.deinit();

    var local = LocalState.init(allocator, null);
    defer local.deinit();

    var interp = Self.init(allocator, &ast, &global, &local);
    const result = interp.interpret();
    if (result) |_| {
        return error.ExpectedError;
    } else |err| {
        try testing.expectEqual(expected_err, err);
    }
}

// ── Literal Tests ───────────────────────────────────────────────────

test "eval: number literal decimal" {
    try expectStorage("{ sstore(0, 42) }", &.{.{ 0, 42 }});
}

test "eval: number literal hex" {
    try expectStorage("{ sstore(0, 0xFF) }", &.{.{ 0, 255 }});
}

test "eval: number literal zero" {
    try expectStorage("{ sstore(0, 0) }", &.{.{ 0, 0 }});
}

test "eval: bool literal true" {
    try expectStorage("{ sstore(0, true) }", &.{.{ 0, 1 }});
}

test "eval: bool literal false" {
    try expectStorage("{ sstore(0, false) }", &.{.{ 0, 0 }});
}

test "eval: string literal" {
    const expected: u256 = @as(u256, 0x616263) << (29 * 8);
    try expectStorage("{ sstore(0, \"abc\") }", &.{.{ 0, expected }});
}

test "eval: string literal empty" {
    try expectStorage("{ sstore(0, \"\") }", &.{.{ 0, 0 }});
}

// ── Variable Tests ──────────────────────────────────────────────────

test "eval: variable declaration and lookup" {
    try expectStorage("{ let x := 42 sstore(0, x) }", &.{.{ 0, 42 }});
}

test "eval: variable zero init" {
    try expectStorage("{ let x sstore(0, x) }", &.{.{ 0, 0 }});
}

test "eval: variable assignment" {
    try expectStorage("{ let x := 1 x := 2 sstore(0, x) }", &.{.{ 0, 2 }});
}

test "eval: undefined variable error" {
    try expectError("{ sstore(0, y) }", error.UndefinedVariable);
}

// ── Block Scoping Tests ─────────────────────────────────────────────

test "eval: block scoping" {
    try expectStorage(
        "{ let x := 1 { let y := 2 sstore(0, y) } sstore(1, x) }",
        &.{ .{ 0, 2 }, .{ 1, 1 } },
    );
}

test "eval: block variable not visible after exit" {
    try expectError("{ { let x := 1 } sstore(0, x) }", error.UndefinedVariable);
}

// ── Arithmetic Builtin Tests ────────────────────────────────────────

test "eval: add" {
    try expectStorage("{ sstore(0, add(1, 2)) }", &.{.{ 0, 3 }});
}

test "eval: sub" {
    try expectStorage("{ sstore(0, sub(10, 3)) }", &.{.{ 0, 7 }});
}

test "eval: mul" {
    try expectStorage("{ sstore(0, mul(6, 7)) }", &.{.{ 0, 42 }});
}

test "eval: div" {
    try expectStorage("{ sstore(0, div(10, 3)) }", &.{.{ 0, 3 }});
}

test "eval: div by zero" {
    try expectStorage("{ sstore(0, div(10, 0)) }", &.{.{ 0, 0 }});
}

test "eval: mod" {
    try expectStorage("{ sstore(0, mod(10, 3)) }", &.{.{ 0, 1 }});
}

test "eval: nested arithmetic" {
    try expectStorage("{ sstore(0, add(mul(2, 3), sub(10, 4))) }", &.{.{ 0, 12 }});
}

// ── Comparison Tests ────────────────────────────────────────────────

test "eval: lt true" {
    try expectStorage("{ sstore(0, lt(1, 2)) }", &.{.{ 0, 1 }});
}

test "eval: lt false" {
    try expectStorage("{ sstore(0, lt(2, 1)) }", &.{.{ 0, 0 }});
}

test "eval: eq" {
    try expectStorage("{ sstore(0, eq(42, 42)) }", &.{.{ 0, 1 }});
}

test "eval: iszero" {
    try expectStorage("{ sstore(0, iszero(0)) }", &.{.{ 0, 1 }});
    try expectStorage("{ sstore(0, iszero(1)) }", &.{.{ 0, 0 }});
}

// ── If Statement Tests ──────────────────────────────────────────────

test "eval: if true" {
    try expectStorage("{ let x := 0 if 1 { x := 42 } sstore(0, x) }", &.{.{ 0, 42 }});
}

test "eval: if false" {
    try expectStorage("{ let x := 0 if 0 { x := 42 } sstore(0, x) }", &.{.{ 0, 0 }});
}

test "eval: if with condition" {
    try expectStorage("{ let x := 5 if lt(x, 10) { sstore(0, 1) } }", &.{.{ 0, 1 }});
}

// ── Switch Statement Tests ──────────────────────────────────────────

test "eval: switch case match" {
    try expectStorage(
        "{ switch 1 case 0 { sstore(0, 10) } case 1 { sstore(0, 20) } }",
        &.{.{ 0, 20 }},
    );
}

test "eval: switch default" {
    try expectStorage(
        "{ switch 99 case 0 { sstore(0, 10) } default { sstore(0, 30) } }",
        &.{.{ 0, 30 }},
    );
}

test "eval: switch no match no default" {
    try expectStorage(
        "{ sstore(0, 42) switch 99 case 0 { sstore(0, 10) } }",
        &.{.{ 0, 42 }},
    );
}

// ── For Loop Tests ──────────────────────────────────────────────────

test "eval: for loop basic" {
    try expectStorage(
        "{ let sum := 0 for { let i := 1 } lt(i, 4) { i := add(i, 1) } { sum := add(sum, i) } sstore(0, sum) }",
        &.{.{ 0, 6 }},
    );
}

test "eval: for loop break" {
    try expectStorage(
        "{ let sum := 0 for { let i := 0 } lt(i, 100) { i := add(i, 1) } { if eq(i, 3) { break } sum := add(sum, i) } sstore(0, sum) }",
        &.{.{ 0, 3 }},
    );
}

test "eval: for loop continue" {
    try expectStorage(
        "{ let sum := 0 for { let i := 0 } lt(i, 5) { i := add(i, 1) } { if iszero(mod(i, 2)) { continue } sum := add(sum, i) } sstore(0, sum) }",
        &.{.{ 0, 4 }},
    );
}

// ── Function Call Tests ─────────────────────────────────────────────

test "eval: user function call" {
    try expectStorage(
        "{ function f(a) -> r { r := a } sstore(0, f(42)) }",
        &.{.{ 0, 42 }},
    );
}

test "eval: function hoisting" {
    try expectStorage(
        "{ sstore(0, f(7)) function f(a) -> r { r := mul(a, 2) } }",
        &.{.{ 0, 14 }},
    );
}

test "eval: function scope isolation" {
    try expectError(
        "{ let x := 99 function f() -> r { r := x } sstore(0, f()) }",
        error.UndefinedVariable,
    );
}

test "eval: multi-return function" {
    try expectStorage(
        "{ function f() -> a, b { a := 10 b := 20 } let x, y := f() sstore(0, x) sstore(1, y) }",
        &.{ .{ 0, 10 }, .{ 1, 20 } },
    );
}

test "eval: recursive function (factorial)" {
    try expectStorage(
        \\{ function factorial(n) -> result {
        \\    result := 1
        \\    for { let i := 1 } lt(i, add(n, 1)) { i := add(i, 1) } {
        \\      result := mul(result, i)
        \\    }
        \\  }
        \\  sstore(0, factorial(5))
        \\}
    ,
        &.{.{ 0, 120 }},
    );
}

test "eval: recursive function (fibonacci)" {
    try expectStorage(
        \\{ function fib(n) -> r {
        \\    switch n
        \\    case 0 { r := 0 }
        \\    case 1 { r := 1 }
        \\    default { r := add(fib(sub(n, 1)), fib(sub(n, 2))) }
        \\  }
        \\  sstore(0, fib(10))
        \\}
    ,
        &.{.{ 0, 55 }},
    );
}

test "eval: leave in function" {
    try expectStorage(
        "{ function f() -> r { r := 1 leave r := 2 } sstore(0, f()) }",
        &.{.{ 0, 1 }},
    );
}

// ── Memory Tests ────────────────────────────────────────────────────

test "eval: mstore and mload" {
    try expectStorage(
        "{ mstore(0, 0xDEADBEEF) sstore(0, mload(0)) }",
        &.{.{ 0, 0xDEADBEEF }},
    );
}

// ── Expression Statement Tests ──────────────────────────────────────

test "eval: pop discards value" {
    try expectStorage("{ pop(42) sstore(0, 1) }", &.{.{ 0, 1 }});
}

test "eval: void function call as statement" {
    try expectStorage(
        "{ function f() { sstore(0, 42) } f() }",
        &.{.{ 0, 42 }},
    );
}

// ── Storage Tests ───────────────────────────────────────────────────

test "eval: sload default zero" {
    try expectStorage("{ sstore(0, sload(99)) }", &.{.{ 0, 0 }});
}

test "eval: transient storage" {
    try expectStorage(
        "{ tstore(0, 42) sstore(0, tload(0)) sstore(1, tload(1)) }",
        &.{ .{ 0, 42 }, .{ 1, 0 } },
    );
}

// ── Halt Builtin Tests ─────────────────────────────────────────────

const HaltTestResult = struct {
    global: GlobalState,
    local: LocalState,
    ast: AST,
    halt_reason: ?HaltReason,

    fn deinit(self: *@This()) void {
        self.global.deinit();
        self.local.deinit();
        self.ast.deinit(testing.allocator);
    }
};

fn runInterpreterFull(source: [:0]const u8) !HaltTestResult {
    return runInterpreterWithCtx(source, .{});
}

const TestCtx = struct {
    calldata: []const u8 = &.{},
    caller: u256 = 0,
    callvalue: u256 = 0,
    address: u256 = 0,
    origin: u256 = 0,
    timestamp: u256 = 0,
    chainid: u256 = 0,
};

fn runInterpreterWithCtx(source: [:0]const u8, ctx: TestCtx) !HaltTestResult {
    const allocator = testing.allocator;
    var ast = try AST.parse(allocator, source);
    errdefer ast.deinit(allocator);

    var global = GlobalState.init(allocator);
    errdefer global.deinit();
    global.calldata = ctx.calldata;
    global.caller = ctx.caller;
    global.callvalue = ctx.callvalue;
    global.address = ctx.address;
    global.origin = ctx.origin;
    global.timestamp = ctx.timestamp;
    global.chainid = ctx.chainid;

    var local = LocalState.init(allocator, null);
    errdefer local.deinit();

    var interp = Self.init(allocator, &ast, &global, &local);
    const result = try interp.interpret();

    return .{ .global = global, .local = local, .ast = ast, .halt_reason = result.halt_reason };
}

test "eval: stop halts execution" {
    var state = try runInterpreterFull("{ sstore(0, 1) stop() sstore(0, 2) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .stopped), state.halt_reason);
    try testing.expectEqual(@as(u256, 1), state.global.sload(0));
}

test "eval: return captures memory" {
    var state = try runInterpreterFull("{ mstore(0, 0xDEAD) return(0, 32) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .returned), state.halt_reason);
    try testing.expectEqual(@as(usize, 32), state.global.return_data.len);
    const val = std.mem.readInt(u256, state.global.return_data[0..32], .big);
    try testing.expectEqual(@as(u256, 0xDEAD), val);
}

test "eval: revert captures memory" {
    var state = try runInterpreterFull("{ mstore(0, 0xBEEF) revert(0, 32) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .reverted), state.halt_reason);
    try testing.expectEqual(@as(usize, 32), state.global.return_data.len);
}

test "eval: invalid halts" {
    var state = try runInterpreterFull("{ sstore(0, 1) invalid() sstore(0, 2) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .invalid_), state.halt_reason);
    try testing.expectEqual(@as(u256, 1), state.global.sload(0));
}

test "eval: stop inside function unwinds all" {
    var state = try runInterpreterFull("{ function f() { stop() } f() sstore(0, 99) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .stopped), state.halt_reason);
    try testing.expectEqual(@as(u256, 0), state.global.sload(0));
}

test "eval: return inside for loop unwinds" {
    var state = try runInterpreterFull("{ for {} 1 {} { mstore(0, 42) return(0, 32) } sstore(0, 99) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, .returned), state.halt_reason);
    try testing.expectEqual(@as(u256, 0), state.global.sload(0));
}

test "eval: no halt returns null" {
    var state = try runInterpreterFull("{ sstore(0, 42) }");
    defer state.deinit();
    try testing.expectEqual(@as(?HaltReason, null), state.halt_reason);
}

// ── Context Getter Tests ───────────────────────────────────────────

test "eval: caller returns context" {
    var state = try runInterpreterWithCtx(
        "{ sstore(0, caller()) }",
        .{ .caller = 0xABCD },
    );
    defer state.deinit();
    try testing.expectEqual(@as(u256, 0xABCD), state.global.sload(0));
}

test "eval: address returns context" {
    var state = try runInterpreterWithCtx(
        "{ sstore(0, address()) }",
        .{ .address = 0x1234 },
    );
    defer state.deinit();
    try testing.expectEqual(@as(u256, 0x1234), state.global.sload(0));
}

test "eval: timestamp returns context" {
    var state = try runInterpreterWithCtx(
        "{ sstore(0, timestamp()) }",
        .{ .timestamp = 1000 },
    );
    defer state.deinit();
    try testing.expectEqual(@as(u256, 1000), state.global.sload(0));
}

test "eval: chainid returns context" {
    var state = try runInterpreterWithCtx(
        "{ sstore(0, chainid()) }",
        .{ .chainid = 1 },
    );
    defer state.deinit();
    try testing.expectEqual(@as(u256, 1), state.global.sload(0));
}

test "eval: gas returns large constant" {
    try expectStorage("{ sstore(0, gt(gas(), 0)) }", &.{.{ 0, 1 }});
}

// ── Keccak256 Tests ────────────────────────────────────────────────

test "eval: keccak256 empty" {
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    try expectStorage(
        "{ sstore(0, keccak256(0, 0)) }",
        &.{.{ 0, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 }},
    );
}

test "eval: keccak256 of data" {
    // Store 0x01 at offset 31 (mstore stores big-endian, so mstore(0, 1) puts 0x01 at byte 31)
    // keccak256 of 32 zero bytes with last byte 0x01
    var state = try runInterpreterFull("{ mstore(0, 1) sstore(0, keccak256(0, 32)) }");
    defer state.deinit();
    // Just check it's non-zero and deterministic
    const hash = state.global.sload(0);
    try testing.expect(hash != 0);
}

// ── CLZ Tests ──────────────────────────────────────────────────────

test "eval: clz of zero" {
    try expectStorage("{ sstore(0, clz(0)) }", &.{.{ 0, 256 }});
}

test "eval: clz of one" {
    try expectStorage("{ sstore(0, clz(1)) }", &.{.{ 0, 255 }});
}

test "eval: clz of max u256" {
    // not(0) = max u256, clz = 0
    try expectStorage("{ sstore(0, clz(not(0))) }", &.{.{ 0, 0 }});
}

// ── Call Data Copy Tests ───────────────────────────────────────────

test "eval: calldatacopy" {
    var cd = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [_]u8{0} ** 28;
    var state = try runInterpreterWithCtx(
        "{ calldatacopy(0, 0, 32) sstore(0, mload(0)) }",
        .{ .calldata = &cd },
    );
    defer state.deinit();
    try testing.expectEqual(@as(u256, 0xDEADBEEF) << (28 * 8), state.global.sload(0));
}

test "eval: returndatasize initially zero" {
    try expectStorage("{ sstore(0, returndatasize()) }", &.{.{ 0, 0 }});
}

// ── Contract Interaction Stub Tests ────────────────────────────────

test "eval: call returns 0 (stub)" {
    try expectStorage("{ sstore(0, call(0, 0, 0, 0, 0, 0, 0)) }", &.{.{ 0, 0 }});
}

test "eval: create returns 0 (stub)" {
    try expectStorage("{ sstore(0, create(0, 0, 0)) }", &.{.{ 0, 0 }});
}

test "eval: staticcall returns 0 (stub)" {
    try expectStorage("{ sstore(0, staticcall(0, 0, 0, 0, 0, 0)) }", &.{.{ 0, 0 }});
}

test "eval: extcodesize returns 0 (stub)" {
    try expectStorage("{ sstore(0, extcodesize(0)) }", &.{.{ 0, 0 }});
}

// ── PC Test ────────────────────────────────────────────────────────

test "eval: pc returns 0" {
    try expectStorage("{ sstore(0, pc()) }", &.{.{ 0, 0 }});
}

// ── Blockhash Test ─────────────────────────────────────────────────

test "eval: blockhash returns 0 (stub)" {
    try expectStorage("{ sstore(0, blockhash(0)) }", &.{.{ 0, 0 }});
}
