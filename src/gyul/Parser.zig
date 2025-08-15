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

fn listToSpan(p: *Parser, list: []const ast.Node.Index) !ast.Node.SubRange {
    try p.extra_data.appendSlice(p.gpa, list);
    return ast.Node.SubRange{
        .start = @as(ast.Node.Index, @intCast(p.extra_data.items.len - list.len)),
        .end = @as(ast.Node.Index, @intCast(p.extra_data.items.len)),
    };
}

pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.gpa);
    self.extra_data.deinit(self.gpa);
    self.scratch.deinit(self.gpa);
}

pub fn parseRoot(self: *Parser) !void {
    eatDocs(self);
    _ = try expectToken(self, .brace_l);
    try self.nodes.append(self.gpa, .{
        .tag = .root,
        .data = undefined,
    });
    // const root_members = try self.parseContainerMembers();
    // const root_decls = try root_members.toSpan(self);
    //if (self.token_tags[self.tok_i] != .eof) {
    //    try self.warnExpected(.eof);
    //}
    //self.nodes.items(.data)[0] = .{
    //    .lhs = root_decls.start,
    //    .rhs = root_decls.end,
    //};
    _ = try expectToken(self, .brace_r);
}

fn eatDocs(self: *Parser) void {
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
