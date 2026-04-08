const std = @import("std");

const LocationOffset = u32;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "function", Tag.keyword_function },
        .{ "let", Tag.keyword_let },
        .{ "if", Tag.keyword_if },
        .{ "switch", Tag.keyword_switch },
        .{ "case", Tag.keyword_case },
        .{ "default", Tag.keyword_default },
        .{ "for", Tag.keyword_for },
        .{ "break", Tag.keyword_break },
        .{ "continue", Tag.keyword_continue },
        .{ "leave", Tag.keyword_leave },
        .{ "true", Tag.keyword_true },
        .{ "false", Tag.keyword_false },
        .{ "hex", Tag.keyword_hex },
    });

    pub const Loc = struct {
        start: LocationOffset,
        end: LocationOffset,
    };
};

pub const Tag = enum {
    invalid,
    string_literal,
    number_literal,
    hex_number_literal,
    comment_single_line,
    comment_multi_line,
    identifier,
    parenthesis_l,
    parenthesis_r,
    bracket_l,
    bracket_r,
    brace_l,
    brace_r,
    colon_assign,
    arrow,
    comma,
    eof,
    // keywords
    keyword_function,
    keyword_let,
    keyword_if,
    keyword_switch,
    keyword_case,
    keyword_default,
    keyword_for,
    keyword_break,
    keyword_continue,
    keyword_leave,
    keyword_true,
    keyword_false,
    keyword_hex,
};

pub const GYulTokenizer = struct {
    buffer: [:0]const u8,
    index: LocationOffset,

    pub fn dump(self: *GYulTokenizer, token: *const Token) void {
        std.debug.print("{s} \"{s}\": [{}:{}]\n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end], token.loc.start, token.loc.end });
    }

    pub fn init(buffer: [:0]const u8) GYulTokenizer {
        // Skip the UTF-8 BOM if present.
        return .{
            .buffer = buffer,
            .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
        };
    }

    const State = enum {
        start,
        string_literal,
        string_literal_backslash,
        number_literal,
        number_literal_zero,
        hex_number_literal,
        identifier,
        slash,
        colon,
        minus,
        comment_single_line,
        comment_multi_line,
        comment_multi_line_end,
        invalid,
    };

    pub fn next(self: *GYulTokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index == self.buffer.len) {
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\t', '\n', '\r' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                '0' => {
                    result.tag = .number_literal;
                    continue :state .number_literal_zero;
                },
                '1'...'9' => {
                    result.tag = .number_literal;
                    continue :state .number_literal;
                },
                '_', 'a' ... 'z', 'A' ... 'Z' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '/' => continue :state .slash,
                ':' => continue :state .colon,
                '-' => continue :state .minus,
                ',' => { self.index += 1; result.tag = .comma; },
                '(' => { self.index += 1; result.tag = .parenthesis_l; },
                ')' => { self.index += 1; result.tag = .parenthesis_r; },
                '[' => { self.index += 1; result.tag = .bracket_l; },
                ']' => { self.index += 1; result.tag = .bracket_r; },
                '{' => { self.index += 1; result.tag = .brace_l; },
                '}' => { self.index += 1; result.tag = .brace_r; },
                else => continue :state .invalid,
            },
            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => result.tag = .invalid, // stop the invalid range at next newline
                    else => continue :state .invalid,
                }
            },
            .string_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_literal_backslash,
                    '"' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .string_literal,
                }
            },
            .number_literal_zero => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'x', 'X' => {
                        result.tag = .hex_number_literal;
                        continue :state .hex_number_literal;
                    },
                    '0'...'9' => continue :state .number_literal,
                    else => {},
                }
            },
            .number_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '0'...'9' => continue :state .number_literal,
                    else => {},
                }
            },
            .hex_number_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => continue :state .hex_number_literal,
                    else => {},
                }
            },
            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        if (Token.keywords.get(self.buffer[result.loc.start..self.index])) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },
            .string_literal_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .string_literal,
                }
            },
            .slash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '/' => {
                        result.tag = .comment_single_line;
                        continue :state .comment_single_line;
                    },
                    '*' => {
                        result.tag = .comment_multi_line;
                        continue :state .comment_multi_line;
                    },
                    else => {},
                }
            },
            .colon => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        self.index += 1;
                        result.tag = .colon_assign;
                    },
                    else => result.tag = .invalid,
                }
            },
            .minus => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '>' => {
                        self.index += 1;
                        result.tag = .arrow;
                    },
                    else => result.tag = .invalid,
                }
            },
            .comment_single_line => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '\n' => {},
                    else => continue :state .comment_single_line
                }
            },
            .comment_multi_line => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '*' => continue :state .comment_multi_line_end,
                    else => continue :state .comment_multi_line
                }
            },
            .comment_multi_line_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '/' => self.index += 1,
                    else => continue :state .comment_multi_line
                }
            }
        }

        result.loc.end = self.index;
        return result;
    }
};

const TagResult = struct { tags: [64]Tag, len: usize };

fn collectTags(source: [:0]const u8) TagResult {
    var result: TagResult = .{ .tags = undefined, .len = 0 };
    var tok = GYulTokenizer.init(source);
    while (true) {
        const t = tok.next();
        result.tags[result.len] = t.tag;
        result.len += 1;
        if (t.tag == .eof) break;
    }
    return result;
}

fn expectTags(source: [:0]const u8, expected: []const Tag) !void {
    const result = collectTags(source);
    try std.testing.expectEqual(expected.len, result.len);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp, result.tags[i]);
    }
}

test "empty input" {
    try expectTags("", &.{.eof});
}

test "whitespace only" {
    try expectTags("  \t\n\r  ", &.{.eof});
}

test "keywords" {
    try expectTags("function", &.{ .keyword_function, .eof });
    try expectTags("let", &.{ .keyword_let, .eof });
    try expectTags("if", &.{ .keyword_if, .eof });
    try expectTags("switch", &.{ .keyword_switch, .eof });
    try expectTags("case", &.{ .keyword_case, .eof });
    try expectTags("default", &.{ .keyword_default, .eof });
    try expectTags("for", &.{ .keyword_for, .eof });
    try expectTags("break", &.{ .keyword_break, .eof });
    try expectTags("continue", &.{ .keyword_continue, .eof });
    try expectTags("leave", &.{ .keyword_leave, .eof });
    try expectTags("true", &.{ .keyword_true, .eof });
    try expectTags("false", &.{ .keyword_false, .eof });
    try expectTags("hex", &.{ .keyword_hex, .eof });
}

test "keyword prefixes are identifiers" {
    try expectTags("func", &.{ .identifier, .eof });
    try expectTags("letting", &.{ .identifier, .eof });
    try expectTags("iffy", &.{ .identifier, .eof });
    try expectTags("forked", &.{ .identifier, .eof });
    try expectTags("breaking", &.{ .identifier, .eof });
}

test "operators" {
    try expectTags(":=", &.{ .colon_assign, .eof });
    try expectTags("->", &.{ .arrow, .eof });
    try expectTags(",", &.{ .comma, .eof });
}

test "delimiters" {
    try expectTags("(", &.{ .parenthesis_l, .eof });
    try expectTags(")", &.{ .parenthesis_r, .eof });
    try expectTags("{", &.{ .brace_l, .eof });
    try expectTags("}", &.{ .brace_r, .eof });
    try expectTags("[", &.{ .bracket_l, .eof });
    try expectTags("]", &.{ .bracket_r, .eof });
    try expectTags("()[]{}", &.{ .parenthesis_l, .parenthesis_r, .bracket_l, .bracket_r, .brace_l, .brace_r, .eof });
}

test "number literals" {
    try expectTags("42", &.{ .number_literal, .eof });
    try expectTags("0", &.{ .number_literal, .eof });
    try expectTags("123456789", &.{ .number_literal, .eof });
}

test "hex number literals" {
    try expectTags("0x0", &.{ .hex_number_literal, .eof });
    try expectTags("0x2a", &.{ .hex_number_literal, .eof });
    try expectTags("0xFF", &.{ .hex_number_literal, .eof });
    try expectTags("0xDeAdBeEf", &.{ .hex_number_literal, .eof });
}

test "string literals" {
    try expectTags("\"hello\"", &.{ .string_literal, .eof });
    try expectTags("\"\"", &.{ .string_literal, .eof });
    try expectTags("\"fu\\nfu\"", &.{ .string_literal, .eof });
    try expectTags("\"a\\\"b\"", &.{ .string_literal, .eof });
}

test "string literal edge cases" {
    // Unterminated string
    try expectTags("\"hello", &.{ .invalid, .eof });
    // String with newline (invalid)
    try expectTags("\"hello\nworld\"", &.{ .invalid, .identifier, .invalid, .eof });
}

test "comments" {
    try expectTags("// single line\n42", &.{ .comment_single_line, .number_literal, .eof });
    try expectTags("/* multi */", &.{ .comment_multi_line, .eof });
    try expectTags("/* multi\nline\ncomment */", &.{ .comment_multi_line, .eof });
    try expectTags("/* a */ /* b */", &.{ .comment_multi_line, .comment_multi_line, .eof });
}

test "unterminated comment" {
    try expectTags("/* no end", &.{ .invalid, .eof });
}

test "identifiers" {
    try expectTags("x", &.{ .identifier, .eof });
    try expectTags("_foo", &.{ .identifier, .eof });
    try expectTags("camelCase123", &.{ .identifier, .eof });
    try expectTags("ALL_CAPS", &.{ .identifier, .eof });
}

test "invalid characters" {
    try expectTags(":", &.{ .invalid, .eof });
    try expectTags("-", &.{ .invalid, .eof });
    try expectTags("/", &.{ .invalid, .eof });
    try expectTags("@", &.{ .invalid, .eof });
}

test "complex token sequence" {
    try expectTags("let x := add(1, 0x2a)", &.{
        .keyword_let,
        .identifier,
        .colon_assign,
        .identifier,
        .parenthesis_l,
        .number_literal,
        .comma,
        .hex_number_literal,
        .parenthesis_r,
        .eof,
    });
}

test "function definition tokens" {
    try expectTags("function f(a, b) -> r {}", &.{
        .keyword_function,
        .identifier,
        .parenthesis_l,
        .identifier,
        .comma,
        .identifier,
        .parenthesis_r,
        .arrow,
        .identifier,
        .brace_l,
        .brace_r,
        .eof,
    });
}

test "for loop tokens" {
    try expectTags("for { } 1 { } { }", &.{
        .keyword_for,
        .brace_l,
        .brace_r,
        .number_literal,
        .brace_l,
        .brace_r,
        .brace_l,
        .brace_r,
        .eof,
    });
}

test "fuzz tokenizer" {
    const Context = struct {
        fn testEndInEOF(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            const null_terminated = try std.testing.allocator.allocSentinel(u8, input.len, 0);
            defer std.testing.allocator.free(null_terminated);
            @memcpy(null_terminated[0..input.len], input);

            var tokenizer = GYulTokenizer.init(null_terminated);
            var currentToken = tokenizer.next();
            while(currentToken.tag != .eof) : (currentToken = tokenizer.next()) {}

            try std.testing.expectEqual(currentToken.loc.start, currentToken.loc.end);
            try std.testing.expectEqual(currentToken.loc.start, input.len);
        }
    };
    try std.testing.fuzz(Context{}, Context.testEndInEOF, .{});
}
