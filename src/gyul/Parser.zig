const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("AST.zig");

const Self = @This();

gpa: std.mem.Allocator,
source: []const u8,
token_tags: []const tokenizer.Token.Tag,
token_starts: []const ast.ByteOffset,
tok_i: ast.TokenIndex,
nodes: ast.NodeList,
extra_data: std.ArrayListUnmanaged(ast.Node.Index),
scratch: std.ArrayListUnmanaged(ast.Node.Index),

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.nodes.deinit(gpa);
    self.extra_data.deinit(gpa);
    self.scratch.deinit(gpa);
}

pub fn parseRoot(self: *Self) !void {
    self.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    self.*.tok_i = 33;
}

fn eatToken(self: *Self, tag: tokenizer.Tag) ?ast.TokenIndex {
    return if (self.token_tags[self.tok_i] == tag) self.nextToken() else null;
}

fn nextToken(self: *Self) ast.TokenIndex {
    const result = self.tok_i;
    self.tok_i += 1;
    return result;
}
