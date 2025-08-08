const std = @import("std");

pub const YulTokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn init(buffer: [:0]const u8) YulTokenizer {
        // Skip the UTF-8 BOM if present.
            return .{
            .buffer = buffer,
            .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
        };
    }

    const State = enum {
        start,
        eof,
        lparen,
        rparen,
        lbrack,
        rbrack,
        lbrace,
        rbrace,
        colon,
        semicolon,
        period,
        conditional,
        doublearrow,
        rightarrow,

    };
};

