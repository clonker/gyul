const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", Tag.keyword_function },
        .{ "let", Tag.keyword_let },
        .{ "if", Tag.keyword_if },
        .{ "switch", Tag.keyword_switch },
        .{ "case", Tag.keyword_case },
        .{ "default", Tag.keyword_default },
        .{ "for", Tag.keyword_for },
        .{ "break", Tag.keyword_break },
        .{ "continue", Tag.keyword_continue },
        .{ "true", Tag.keyword_true },
        .{ "false", Tag.keyword_false },
        .{ "hex", Tag.keyword_hex },
    });

    pub const Loc = struct {
        start: usize,
        end: usize,
    };
};

pub const Tag = enum {
    invalid,
    string_literal,
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
    keyword_true,
    keyword_false,
    keyword_hex,
};

pub const GYulTokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn dump(self: *GYulTokenizer, token: *const Token) void {
        std.debug.print("{s} \"{s}\"\n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end] });
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
            .string_literal_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .string_literal,
                }
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

test "string literals" {
    const source = "\"fu\\nfu\" 8";
    var tokenizer = GYulTokenizer.init(source);
    var currentToken = tokenizer.next();
    while(currentToken.tag != .eof) : (currentToken = tokenizer.next()) {
        tokenizer.dump(&currentToken);
    }
    tokenizer.dump(&currentToken);
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
