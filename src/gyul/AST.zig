const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("ASTPrinter.zig");

const Self = @This();

source: [:0]const u8,
tokens: TokenList.Slice,
nodes: []const Node,
extra: []const NodeIndex,
errors: []const Error,

pub const TokenIndex = u32;
pub const ByteOffset = u32;
pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

pub const Span = struct {
    start: u32,
    len: u32,
};

pub const TokenList = std.MultiArrayList(struct {
    tag: tokenizer.Tag,
    start: ByteOffset,
});

pub const Node = union(enum) {
    // Top-level
    root: struct { token: TokenIndex, body: Span },

    // Statements
    block: struct { token: TokenIndex, stmts: Span },
    function_definition: struct {
        token: TokenIndex,
        name: TokenIndex,
        params: Span,
        return_vars: Span,
        body: NodeIndex,
    },
    variable_declaration: struct { token: TokenIndex, names: Span, value: NodeIndex },
    assignment: struct { token: TokenIndex, targets: Span, value: NodeIndex },
    if_statement: struct { token: TokenIndex, condition: NodeIndex, body: NodeIndex },
    switch_statement: struct { token: TokenIndex, expr: NodeIndex, cases: Span },
    case_clause: struct { token: TokenIndex, value: NodeIndex, body: NodeIndex },
    case_default: struct { token: TokenIndex, body: NodeIndex },
    for_loop: struct { token: TokenIndex, pre: NodeIndex, condition: NodeIndex, post: NodeIndex, body: NodeIndex },
    @"break": struct { token: TokenIndex },
    @"continue": struct { token: TokenIndex },
    leave: struct { token: TokenIndex },
    expression_statement: struct { token: TokenIndex, expr: NodeIndex },

    // Expressions
    function_call: struct { token: TokenIndex, args: Span },
    identifier: struct { token: TokenIndex },
    number_literal: struct { token: TokenIndex },
    string_literal: struct { token: TokenIndex },
    bool_literal: struct { token: TokenIndex },
    hex_literal: struct { token: TokenIndex, value: TokenIndex },

    pub fn getToken(self: Node) TokenIndex {
        return switch (self) {
            inline else => |payload| payload.token,
        };
    }
};

pub const Error = struct {
    tag: Tag,
    token: TokenIndex,
    extra: union {
        none: void,
        expected_tag: tokenizer.Tag,
    } = .{ .none = {} },

    pub const Tag = enum {
        expected_token,
        expected_expression,
        expected_block,
        expected_identifier,
        expected_statement,
    };
};

pub fn spanToList(self: *const Self, span: Span) []const NodeIndex {
    return self.extra[span.start..][0..span.len];
}

pub fn tokenSlice(self: *const Self, tok: TokenIndex) []const u8 {
    const starts = self.tokens.items(.start);
    const start = starts[tok];
    // Use next token's start as end, or source length for last token
    const end = if (tok + 1 < starts.len) starts[tok + 1] else @as(ByteOffset, @intCast(self.source.len));
    // Trim trailing whitespace
    var e = end;
    while (e > start and (self.source[e - 1] == ' ' or self.source[e - 1] == '\n' or self.source[e - 1] == '\t' or self.source[e - 1] == '\r')) {
        e -= 1;
    }
    return self.source[start..e];
}

pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Self {
    var tokens = TokenList{};
    defer tokens.deinit(gpa);

    {
        var lex = tokenizer.GYulTokenizer.init(source);
        var tok = lex.next();
        while (tok.tag != .eof) : (tok = lex.next()) {
            try tokens.append(gpa, .{
                .tag = tok.tag,
                .start = @as(ByteOffset, tok.loc.start),
            });
        }
        // Append the EOF token
        try tokens.append(gpa, .{
            .tag = .eof,
            .start = @as(ByteOffset, tok.loc.start),
        });
    }

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .tok_i = 0,
        .errors = .{},
        .nodes = .{},
        .extra = .{},
        .scratch = .{},
    };
    defer parser.scratch.deinit(gpa);
    try parser.parseRoot();

    const nodes = try parser.nodes.toOwnedSlice(gpa);
    errdefer gpa.free(nodes);

    const extra = try parser.extra.toOwnedSlice(gpa);
    errdefer gpa.free(extra);

    const errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);

    return Self{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = nodes,
        .extra = extra,
        .errors = errors,
    };
}

pub fn print(self: *const Self, gpa: std.mem.Allocator) ![]u8 {
    return Printer.print(gpa, self);
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.tokens.deinit(gpa);
    gpa.free(self.nodes);
    gpa.free(self.extra);
    gpa.free(self.errors);
    self.* = undefined;
}
