const std = @import("std");
const tokenizer = @import("tokenizer.zig");

source: [:0]const u8,

pub const TokenIndex = u32;
pub const ByteOffset = u32;
pub const TokenList = std.MultiArrayList(struct {
    tag: tokenizer.Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = u32;

    pub const Tag = enum {
        root,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};
