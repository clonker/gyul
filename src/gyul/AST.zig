const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Parser = @import("Parser.zig");
const Tokenizer = tokenizer.GYulTokenizer;

const Self = @This();

source: [:0]const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,
extra_data: []Node.Index,
errors: []const Error,

pub const TokenIndex = u32;
pub const ByteOffset = u32;
pub const TokenList = std.MultiArrayList(struct {
    tag: tokenizer.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = u32;

    pub const Tag = enum {
        root,
        ifStatement,
        forLoop,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};
pub const Error = struct {
    tag: Tag,
    pub const Tag = enum {
        type_of_error,
    };
};

pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error!Self {
    var tokens = TokenList{};
    defer tokens.deinit(gpa);

    {
        var lex = Tokenizer.init(source);
        var currentToken = lex.next();
        while(currentToken.tag != .eof) : (currentToken = lex.next()) {
            try tokens.append(gpa, .{
                .tag = currentToken.tag,
                .start = @as(ByteOffset, currentToken.loc.start)
            });
        }
    }

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .tok_i = 0,
        .nodes = .{},
        .extra_data = .{},
        .scratch = .{}
    };
    defer parser.deinit(gpa);

    try parser.parseRoot(gpa);

    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);

    return Self{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .errors = undefined, // todo
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
    };
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.tokens.deinit(gpa);
    self.nodes.deinit(gpa);
    gpa.free(self.errors);
    gpa.free(self.extra_data);
    self.* = undefined;
}
