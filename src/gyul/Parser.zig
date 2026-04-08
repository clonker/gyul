const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("AST.zig");

const Parser = @This();

pub const Error = error{ParseError} || std.mem.Allocator.Error;

gpa: std.mem.Allocator,
source: [:0]const u8,
token_tags: []const tokenizer.Tag,
token_starts: []const ast.ByteOffset,
tok_i: ast.TokenIndex,
errors: std.ArrayListUnmanaged(ast.Error),
nodes: std.ArrayListUnmanaged(ast.Node),
extra: std.ArrayListUnmanaged(ast.NodeIndex),
scratch: std.ArrayListUnmanaged(ast.NodeIndex),

// --- Public API ---

pub fn parseRoot(self: *Parser) !void {
    // Reserve slot 0 for the root node
    try self.nodes.append(self.gpa, undefined);

    self.eatComments();
    const lbrace = try self.expectToken(.brace_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peek() != .brace_r and self.peek() != .eof) {
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    const body = self.addSpan(self.scratch.items[scratch_top..]);
    self.nodes.items[0] = .{ .root = .{ .token = lbrace, .body = body } };
}

// --- Statements ---

fn parseStatement(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .brace_l => self.parseBlock(),
        .keyword_let => self.parseVariableDeclaration(),
        .keyword_if => self.parseIf(),
        .keyword_for => self.parseForLoop(),
        .keyword_switch => self.parseSwitch(),
        .keyword_function => self.parseFunctionDefinition(),
        .keyword_break => self.parseBreak(),
        .keyword_continue => self.parseContinue(),
        .keyword_leave => self.parseLeave(),
        .identifier => self.parseIdentifierStatement(),
        else => self.failMsg(.{
            .tag = .expected_statement,
            .token = self.tok_i,
        }),
    };
}

fn parseBlock(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    const lbrace = try self.expectToken(.brace_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peek() != .brace_r and self.peek() != .eof) {
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    const stmts = self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .block = .{ .token = lbrace, .stmts = stmts } });
}

fn parseVariableDeclaration(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `let`

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    while (self.peek() == .comma) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    }

    const names = self.addSpan(self.scratch.items[scratch_top..]);

    var value: ast.NodeIndex = ast.null_node;
    if (self.peek() == .colon_assign) {
        _ = self.nextToken();
        value = try self.parseExpression();
    }

    return self.addNode(.{ .variable_declaration = .{
        .token = tok,
        .names = names,
        .value = value,
    } });
}

fn parseIf(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `if`
    const condition = try self.parseExpression();
    const body = try self.parseBlock();
    return self.addNode(.{ .if_statement = .{
        .token = tok,
        .condition = condition,
        .body = body,
    } });
}

fn parseForLoop(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `for`
    const pre = try self.parseBlock();
    const condition = try self.parseExpression();
    const post = try self.parseBlock();
    const body = try self.parseBlock();
    return self.addNode(.{ .for_loop = .{
        .token = tok,
        .pre = pre,
        .condition = condition,
        .post = post,
        .body = body,
    } });
}

fn parseSwitch(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `switch`
    const expr = try self.parseExpression();

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peek() == .keyword_case or self.peek() == .keyword_default) {
        if (self.peek() == .keyword_default) {
            const default_tok = self.nextToken();
            const body = try self.parseBlock();
            const node = try self.addNode(.{ .case_default = .{
                .token = default_tok,
                .body = body,
            } });
            try self.scratch.append(self.gpa, node);
        } else {
            const case_tok = self.nextToken();
            const value = try self.parseLiteral();
            const body = try self.parseBlock();
            const node = try self.addNode(.{ .case_clause = .{
                .token = case_tok,
                .value = value,
                .body = body,
            } });
            try self.scratch.append(self.gpa, node);
        }
    }

    const cases = self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .switch_statement = .{
        .token = tok,
        .expr = expr,
        .cases = cases,
    } });
}

fn parseFunctionDefinition(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `function`
    const name = try self.expectToken(.identifier);
    _ = try self.expectToken(.parenthesis_l);

    // Parse parameters
    const params_top = self.scratch.items.len;
    if (self.peek() == .identifier) {
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        }
    }
    _ = try self.expectToken(.parenthesis_r);
    const params = self.addSpan(self.scratch.items[params_top..]);
    self.scratch.shrinkRetainingCapacity(params_top);

    // Parse return variables
    const rets_top = self.scratch.items.len;
    if (self.peek() == .arrow) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        }
    }
    const return_vars = self.addSpan(self.scratch.items[rets_top..]);
    self.scratch.shrinkRetainingCapacity(rets_top);

    const body = try self.parseBlock();

    return self.addNode(.{ .function_definition = .{
        .token = tok,
        .name = name,
        .params = params,
        .return_vars = return_vars,
        .body = body,
    } });
}

fn parseBreak(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .@"break" = .{ .token = tok } });
}

fn parseContinue(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .@"continue" = .{ .token = tok } });
}

fn parseLeave(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .leave = .{ .token = tok } });
}

fn parseIdentifierStatement(self: *Parser) Error!ast.NodeIndex {
    // Could be: function call or assignment
    const ident = try self.parseIdentifierNode();

    if (self.peek() == .parenthesis_l) {
        // Function call as statement
        const call = try self.parseFunctionCallWithToken(self.nodes.items[ident].identifier.token);
        return self.addNode(.{ .expression_statement = .{
            .token = self.nodes.items[call].function_call.token,
            .expr = call,
        } });
    }

    // Assignment: x, y, z := expr
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.append(self.gpa, ident);

    while (self.peek() == .comma) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    }

    const assign_tok = try self.expectToken(.colon_assign);
    const value = try self.parseExpression();
    const targets = self.addSpan(self.scratch.items[scratch_top..]);

    return self.addNode(.{ .assignment = .{
        .token = assign_tok,
        .targets = targets,
        .value = value,
    } });
}

// --- Expressions ---

fn parseExpression(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .identifier => self.parseIdentifierExpression(),
        .number_literal, .hex_number_literal => self.parseNumberLiteral(),
        .string_literal => self.parseStringLiteral(),
        .keyword_true, .keyword_false => self.parseBoolLiteral(),
        .keyword_hex => self.parseHexLiteral(),
        else => self.failMsg(.{
            .tag = .expected_expression,
            .token = self.tok_i,
        }),
    };
}

fn parseLiteral(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .number_literal, .hex_number_literal => self.parseNumberLiteral(),
        .string_literal => self.parseStringLiteral(),
        .keyword_true, .keyword_false => self.parseBoolLiteral(),
        .keyword_hex => self.parseHexLiteral(),
        else => self.failMsg(.{
            .tag = .expected_expression,
            .token = self.tok_i,
        }),
    };
}

fn parseIdentifierExpression(self: *Parser) Error!ast.NodeIndex {
    const ident = try self.parseIdentifierNode();
    if (self.peek() == .parenthesis_l) {
        return self.parseFunctionCallWithToken(self.nodes.items[ident].identifier.token);
    }
    return ident;
}

fn parseFunctionCallWithToken(self: *Parser, name_token: ast.TokenIndex) Error!ast.NodeIndex {
    _ = try self.expectToken(.parenthesis_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    if (self.peek() != .parenthesis_r) {
        try self.scratch.append(self.gpa, try self.parseExpression());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseExpression());
        }
    }
    _ = try self.expectToken(.parenthesis_r);

    const args = self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .function_call = .{ .token = name_token, .args = args } });
}

fn parseIdentifierNode(self: *Parser) Error!ast.NodeIndex {
    const tok = try self.expectToken(.identifier);
    return self.addNode(.{ .identifier = .{ .token = tok } });
}

fn parseNumberLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .number_literal = .{ .token = tok } });
}

fn parseStringLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .string_literal = .{ .token = tok } });
}

fn parseBoolLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .bool_literal = .{ .token = tok } });
}

fn parseHexLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // `hex` keyword
    const value = try self.expectToken(.string_literal);
    return self.addNode(.{ .hex_literal = .{ .token = tok, .value = value } });
}

// --- Helpers ---

fn peek(self: *Parser) tokenizer.Tag {
    if (self.tok_i >= self.token_tags.len) return .eof;
    return self.token_tags[self.tok_i];
}

fn eatComments(self: *Parser) void {
    while (self.tok_i < self.token_tags.len and
        (self.token_tags[self.tok_i] == .comment_single_line or
        self.token_tags[self.tok_i] == .comment_multi_line))
    {
        _ = self.nextToken();
    }
}

fn nextToken(self: *Parser) ast.TokenIndex {
    const result = self.tok_i;
    self.tok_i += 1;
    return result;
}

fn expectToken(self: *Parser, tag: tokenizer.Tag) Error!ast.TokenIndex {
    if (self.peek() != tag) {
        return self.failMsg(.{
            .tag = .expected_token,
            .token = self.tok_i,
            .extra = .{ .expected_tag = tag },
        });
    }
    return self.nextToken();
}

fn addNode(self: *Parser, node: ast.Node) Error!ast.NodeIndex {
    const idx: ast.NodeIndex = @intCast(self.nodes.items.len);
    try self.nodes.append(self.gpa, node);
    return idx;
}

fn addSpan(self: *Parser, items: []const ast.NodeIndex) ast.Span {
    const start: u32 = @intCast(self.extra.items.len);
    self.extra.appendSlice(self.gpa, items) catch @panic("OOM");
    return .{ .start = start, .len = @intCast(items.len) };
}

fn failMsg(self: *Parser, msg: ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try self.warnMsg(msg);
    return error.ParseError;
}

fn warnMsg(self: *Parser, msg: ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);
    try self.errors.append(self.gpa, msg);
}
