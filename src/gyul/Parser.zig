const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("AST.zig");

const Parser = @This();

pub const Error = error{ParseError} || std.mem.Allocator.Error;

gpa: std.mem.Allocator,
source: []const u8,
token_tags: []const tokenizer.Tag,
token_starts: []const ast.ByteOffset,
tok_i: ast.TokenIndex,
errors: std.ArrayListUnmanaged(ast.Error),
nodes: ast.NodeList,
extra_data: std.ArrayListUnmanaged(ast.Node.Index),
scratch: std.ArrayListUnmanaged(ast.Node.Index),

const Members = struct {
    len: usize,
    lhs: ast.Node.Index,
    rhs: ast.Node.Index,
    trailing: bool,

    fn toSpan(self: Members, parser: *Parser) !ast.Node.SubRange {
        if (self.len <= 2) {
            const nodes = [2]ast.Node.Index{ self.lhs, self.rhs };
            return parser.listToSpan(nodes[0..self.len]);
        } else {
            return ast.Node.SubRange{ .start = self.lhs, .end = self.rhs };
        }
    }
};

pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.gpa);
    self.extra_data.deinit(self.gpa);
    self.scratch.deinit(self.gpa);
}

pub fn parseRoot(self: *Parser) !void {
    self.eatComments();
    _ = try expectToken(self, .brace_l);
    try self.nodes.append(self.gpa, .{
        .tag = .root,
        .data = undefined,
    });

    // Skip body tokens until closing brace
    // TODO: replace with proper member/statement parsing
    while (self.tok_i < self.token_tags.len and self.token_tags[self.tok_i] != .brace_r) {
        _ = self.nextToken();
    }

    _ = try expectToken(self, .brace_r);
}

fn parseBlock(self: *Parser) Error!ast.Node.Index {
    self.eatComments();
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    _ = try self.expectToken(.brace_l);
    while (true) {
        if (self.tok_i >= self.token_tags.len or self.token_tags[self.tok_i] == .brace_r) break;
        const statement = try self.parseStatement();
        if (statement == 0) break;
        try self.scratch.append(self.gpa, statement);
    }
    _ = try self.expectToken(.brace_r);
    const statements = self.scratch.items[scratch_top..];
    return switch (statements.len) {
        0 => try self.addNode(.{
            .tag = .block2,
            .data = .{ .lhs = 0, .rhs = 0 },
        }),
        1 => try self.addNode(.{
            .tag = .block2,
            .data = .{ .lhs = statements[0], .rhs = 0 },
        }),
        2 => try self.addNode(.{
            .tag = .block2,
            .data = .{ .lhs = statements[0], .rhs = statements[1] },
        }),
        else => blk: {
            const span = try self.listToSpan(statements);
            break :blk try self.addNode(.{
                .tag = .block,
                .data = .{ .lhs = span.start, .rhs = span.end },
            });
        },
    };
}

fn parseStatement(self: *Parser) Error!ast.Node.Index {
    self.eatComments();
    if (self.tok_i >= self.token_tags.len) return 0;
    // TODO: implement statement parsing for each keyword
    // For now, skip tokens until we hit a closing brace or EOF
    _ = self.nextToken();
    return 0;
}

fn eatComments(self: *Parser) void {
    while (
        self.tok_i < self.token_tags.len and
        (self.token_tags[self.tok_i] == .comment_single_line or self.token_tags[self.tok_i] == .comment_multi_line)
    ) {
        _ = self.nextToken();
    }
}

fn eatToken(self: *Parser, tag: tokenizer.Tag) ?ast.TokenIndex {
    return if (self.token_tags[self.tok_i] == tag) self.nextToken() else null;
}

fn expectToken(p: *Parser, tag: tokenizer.Tag) Error!ast.TokenIndex {
    if (p.token_tags[p.tok_i] != tag) {
        return p.failMsg(.{
            .tag = .expected_token,
            .token = p.tok_i,
            .extra = .{ .expected_tag = tag },
        });
    }
    return p.nextToken();
}

fn nextToken(self: *Parser) ast.TokenIndex {
    const result = self.tok_i;
    self.tok_i += 1;
    return result;
}

fn failMsg(p: *Parser, msg: ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try p.warnMsg(msg);
    return error.ParseError;
}

fn tokensOnSameLine(p: *Parser, token1: ast.TokenIndex, token2: ast.TokenIndex) bool {
    return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
}

fn warnMsg(p: *Parser, msg: ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);
    switch (msg.tag) {
        .expected_token => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
            var copy = msg;
            copy.token -= 1;
            return p.errors.append(p.gpa, copy);
        },
    }
    try p.errors.append(p.gpa, msg);
}

fn addNode(self: *Parser, elem: ast.Node) std.mem.Allocator.Error!ast.Node.Index {
    const result = @as(ast.Node.Index, @intCast(self.nodes.len));
    try self.nodes.append(self.gpa, elem);
    return result;
}

fn listToSpan(self: *Parser, list: []const ast.Node.Index) !ast.Node.SubRange {
    try self.extra_data.appendSlice(self.gpa, list);
    return ast.Node.SubRange{
        .start = @as(ast.Node.Index, @intCast(self.extra_data.items.len - list.len)),
        .end = @as(ast.Node.Index, @intCast(self.extra_data.items.len)),
    };
}
