const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("ASTPrinter.zig");
const YulGen = @import("YulGen.zig");
const ObjectTreeMod = @import("ObjectTree.zig");
pub const ObjectTree = ObjectTreeMod.ObjectTree;
pub const ObjectTreeRoot = ObjectTreeMod.ObjectTreeRoot;

const Self = @This();

source: [:0]const u8,
tokens: TokenList.Slice,
nodes: []const Node,
extra: []const NodeIndex,
errors: []const Error,
/// Top-level Yul object `data "name" ...` sections, decoded to bytes.
/// Empty when the source is a bare `{ ... }` block. Owned by the AST.
data_sections: std.StringHashMapUnmanaged([]const u8),

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

pub const SourceLocation = struct {
    line: u32,
    col: u32,
};

pub fn tokenLocation(self: *const Self, tok: TokenIndex) SourceLocation {
    const starts = self.tokens.items(.start);
    if (tok >= starts.len) return .{ .line = 1, .col = 1 };
    return self.byteOffsetLocation(starts[tok]);
}

pub fn byteOffsetLocation(self: *const Self, byte_offset: ByteOffset) SourceLocation {
    var line: u32 = 1;
    var col: u32 = 1;
    for (self.source[0..@min(byte_offset, self.source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

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
    if (source.len > std.math.maxInt(ByteOffset)) return error.SourceTooLarge;

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
        .depth = 0,
        .errors = .{},
        .nodes = .{},
        .extra = .{},
        .scratch = .{},
        .data_sections = .{},
    };
    defer parser.scratch.deinit(gpa);
    errdefer parser.nodes.deinit(gpa);
    errdefer parser.extra.deinit(gpa);
    errdefer parser.errors.deinit(gpa);
    errdefer {
        var it = parser.data_sections.iterator();
        while (it.next()) |e| gpa.free(e.value_ptr.*);
        parser.data_sections.deinit(gpa);
    }
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
        .data_sections = parser.data_sections,
    };
}

/// Result of `parseAny`. Source files that begin with an `object`
/// wrapper produce an `ObjectTreeRoot`; everything else (bare `{ ... }`
/// blocks) produces a flat `AST` matching the legacy shape.
pub const ParseResult = union(enum) {
    bare: Self,
    tree: ObjectTreeRoot,

    pub fn deinit(self: *ParseResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .bare => |*a| a.deinit(gpa),
            .tree => |*t| t.deinit(gpa),
        }
    }
};

/// Parse failure with byte offset of the offending token (for error
/// reporting). Set as a thread-local by `parseAny` on failure.
pub var last_parse_error_offset: ByteOffset = 0;

/// New entry point that knows about object syntax. Bare blocks become
/// `.bare`; object-wrapped sources become `.tree`. The legacy `parse`
/// function is unchanged for backwards compat with existing tests.
pub fn parseAny(gpa: std.mem.Allocator, source: [:0]const u8) !ParseResult {
    if (source.len > std.math.maxInt(ByteOffset)) return error.SourceTooLarge;

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
        try tokens.append(gpa, .{
            .tag = .eof,
            .start = @as(ByteOffset, tok.loc.start),
        });
    }

    // Detect mode by looking for an `object` identifier as the first
    // non-comment token. This mirrors the logic in `Parser.parseRoot`.
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    var i: usize = 0;
    while (i < tags.len and (tags[i] == .comment_single_line or tags[i] == .comment_multi_line)) : (i += 1) {}
    const is_object = i < tags.len and tags[i] == .identifier and blk: {
        const start = starts[i];
        const end: ByteOffset = if (i + 1 < starts.len) starts[i + 1] else @intCast(source.len);
        var e = end;
        while (e > start and (source[e - 1] == ' ' or source[e - 1] == '\n' or source[e - 1] == '\t' or source[e - 1] == '\r')) {
            e -= 1;
        }
        break :blk std.mem.eql(u8, source[start..e], "object");
    };

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .tok_i = 0,
        .depth = 0,
        .errors = .{},
        .nodes = .{},
        .extra = .{},
        .scratch = .{},
        .data_sections = .{},
    };
    defer parser.scratch.deinit(gpa);
    errdefer parser.nodes.deinit(gpa);
    errdefer parser.extra.deinit(gpa);
    errdefer parser.errors.deinit(gpa);
    errdefer {
        var it = parser.data_sections.iterator();
        while (it.next()) |e| {
            // Legacy data_sections has unowned keys (slices into source);
            // only free values.
            gpa.free(e.value_ptr.*);
        }
        parser.data_sections.deinit(gpa);
    }

    if (is_object) {
        var root_obj: ObjectTree = undefined;
        var root_initialized = false;
        errdefer if (root_initialized) root_obj.deinit(gpa);
        parser.parseRootObjectTree(&root_obj) catch |err| {
            last_parse_error_offset = if (parser.tok_i < parser.token_starts.len)
                parser.token_starts[parser.tok_i]
            else
                @intCast(source.len);
            return err;
        };
        root_initialized = true;

        const nodes = try parser.nodes.toOwnedSlice(gpa);
        errdefer gpa.free(nodes);
        const extra = try parser.extra.toOwnedSlice(gpa);
        errdefer gpa.free(extra);
        const errors = try parser.errors.toOwnedSlice(gpa);
        errdefer gpa.free(errors);

        // The legacy `data_sections` map should be empty in tree mode.
        parser.data_sections.deinit(gpa);

        return .{ .tree = .{
            .source = source,
            .tokens = tokens.toOwnedSlice(),
            .nodes = nodes,
            .extra = extra,
            .errors = errors,
            .root = root_obj,
        } };
    }

    try parser.parseRoot();

    const nodes = try parser.nodes.toOwnedSlice(gpa);
    errdefer gpa.free(nodes);
    const extra = try parser.extra.toOwnedSlice(gpa);
    errdefer gpa.free(extra);
    const errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);

    return .{ .bare = .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = nodes,
        .extra = extra,
        .errors = errors,
        .data_sections = parser.data_sections,
    } };
}

pub fn print(self: *const Self, gpa: std.mem.Allocator) ![]u8 {
    return Printer.print(gpa, self);
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.tokens.deinit(gpa);
    gpa.free(self.nodes);
    gpa.free(self.extra);
    gpa.free(self.errors);
    var it = self.data_sections.iterator();
    while (it.next()) |e| gpa.free(e.value_ptr.*);
    self.data_sections.deinit(gpa);
    self.* = undefined;
}

// --- Tests ---

fn expectPrint(source: [:0]const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var ast = try Self.parse(allocator, source);
    defer ast.deinit(allocator);
    const printed = try ast.print(allocator);
    defer allocator.free(printed);
    try std.testing.expectEqualStrings(expected, printed);
}

fn expectParseError(source: [:0]const u8) !void {
    const allocator = std.testing.allocator;
    const result = Self.parse(allocator, source);
    if (result) |*ast_ptr| {
        var ast = ast_ptr.*;
        ast.deinit(allocator);
        return error.ExpectedParseError;
    } else |_| {}
}

test "parse empty block" {
    try expectPrint("{}", "{\n}\n");
}

test "parse variable declaration" {
    try expectPrint("{ let x := 1 }", "{\n  let x := 1\n}\n");
}

test "parse variable declaration no init" {
    try expectPrint("{ let x }", "{\n  let x\n}\n");
}

test "parse multi variable declaration" {
    try expectPrint("{ let x, y := foo() }", "{\n  let x, y := foo()\n}\n");
}

test "parse assignment" {
    try expectPrint("{ let x x := 1 }", "{\n  let x\n  x := 1\n}\n");
}

test "parse multi assignment" {
    try expectPrint("{ let x let y x, y := foo() }", "{\n  let x\n  let y\n  x, y := foo()\n}\n");
}

test "parse function call statement" {
    try expectPrint("{ sstore(0, 1) }", "{\n  sstore(0, 1)\n}\n");
}

test "parse nested function call" {
    try expectPrint("{ sstore(add(1, 2), 3) }", "{\n  sstore(add(1, 2), 3)\n}\n");
}

test "parse function definition" {
    try expectPrint(
        "{ function f(a, b) -> r { r := add(a, b) } }",
        "{\n  function f(a, b) -> r {\n    r := add(a, b)\n  }\n}\n",
    );
}

test "parse function no params no returns" {
    try expectPrint(
        "{ function f() { } }",
        "{\n  function f() {\n  }\n}\n",
    );
}

test "parse if statement" {
    try expectPrint("{ if 1 { } }", "{\n  if 1 {\n  }\n}\n");
}

test "parse if with body" {
    try expectPrint(
        "{ let x if x { x := 0 } }",
        "{\n  let x\n  if x {\n    x := 0\n  }\n}\n",
    );
}

test "parse for loop" {
    try expectPrint(
        "{ for { let i := 0 } lt(i, 10) { i := add(i, 1) } { } }",
        "{\n  for { let i := 0 } lt(i, 10) { i := add(i, 1) } {\n  }\n}\n",
    );
}

test "parse for loop with break" {
    try expectPrint(
        "{ for { } 1 { } { break } }",
        "{\n  for {} 1 {} {\n    break\n  }\n}\n",
    );
}

test "parse for loop with continue" {
    try expectPrint(
        "{ for { } 1 { } { continue } }",
        "{\n  for {} 1 {} {\n    continue\n  }\n}\n",
    );
}

test "parse switch case default" {
    try expectPrint(
        "{ switch 1 case 0 { } case 1 { } default { } }",
        "{\n  switch 1\n  case 0 {\n  }\n  case 1 {\n  }\n  default {\n  }\n}\n",
    );
}

test "parse switch with body" {
    try expectPrint(
        "{ let y switch 1 case 0 { y := 0 } default { y := 1 } }",
        "{\n  let y\n  switch 1\n  case 0 {\n    y := 0\n  }\n  default {\n    y := 1\n  }\n}\n",
    );
}

test "parse leave in function" {
    try expectPrint(
        "{ function f() { leave } }",
        "{\n  function f() {\n    leave\n  }\n}\n",
    );
}

test "parse hex literal" {
    try expectPrint("{ let x := 0xFF }", "{\n  let x := 0xFF\n}\n");
}

test "parse comments are skipped" {
    try expectPrint(
        "{ /* comment */ let x := 1 // line\n }",
        "{\n  let x := 1\n}\n",
    );
}

test "parse nested blocks" {
    try expectPrint("{ { { } } }", "{\n  {\n    {\n    }\n  }\n}\n");
}

test "parse error: missing opening brace" {
    try expectParseError("let x := 1");
}

test "parse error: missing closing brace" {
    try expectParseError("{ let x := 1");
}

test "parse object: data sections captured into ast" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\object "Outer" {
        \\  code { sstore(0, 1) }
        \\  data "msg" "hello"
        \\  data "raw" hex"deadbeef"
        \\}
    ;
    var ast = try Self.parse(allocator, source);
    defer ast.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), ast.data_sections.count());
    try std.testing.expectEqualSlices(u8, "hello", ast.data_sections.get("msg").?);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, ast.data_sections.get("raw").?);
}

test "parseAny: bare block returns .bare" {
    const allocator = std.testing.allocator;
    var result = try Self.parseAny(allocator, "{ let x := 1 }");
    defer result.deinit(allocator);
    try std.testing.expect(result == .bare);
}

test "parseAny: object source returns .tree with sub-objects" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\object "C" {
        \\  code { sstore(0, 42) }
        \\  object "C_deployed" {
        \\    code { mstore(0, sload(0)) return(0, 32) }
        \\    data "msg" "hi"
        \\  }
        \\}
    ;
    var result = try Self.parseAny(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expect(result == .tree);
    const root = &result.tree.root;
    try std.testing.expectEqualStrings("C", root.name);
    try std.testing.expect(root.code_root != null_node);
    try std.testing.expect(root.sentinel != 0);

    try std.testing.expectEqual(@as(usize, 1), root.children.len);
    const child = &root.children[0];
    try std.testing.expectEqualStrings("C_deployed", child.name);
    try std.testing.expect(child.code_root != null_node);
    try std.testing.expect(child.sentinel != 0);
    try std.testing.expect(child.sentinel != root.sentinel);

    try std.testing.expectEqual(@as(u32, 1), child.data.count());
    try std.testing.expectEqualSlices(u8, "hi", child.data.get("msg").?);
}

test "parseAny: tree slot 0 is .root pointing at root code block" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 = "object \"X\" { code { sstore(0, 1) } }";
    var result = try Self.parseAny(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expect(result == .tree);
    const tree = &result.tree;
    try std.testing.expect(tree.nodes[0] == .root);
    const body = tree.nodes[0].root.body;
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const code_idx = tree.extra[body.start];
    try std.testing.expectEqual(tree.root.code_root, code_idx);
    try std.testing.expect(tree.nodes[code_idx] == .block);
}

test "fuzz parser raw bytes" {
    const Ctx = struct {
        fn run(_: @This(), input: []const u8) anyerror!void {
            const alloc = std.testing.allocator;
            const source = try alloc.allocSentinel(u8, input.len, 0);
            defer alloc.free(source);
            @memcpy(source[0..input.len], input);

            var ast = Self.parse(alloc, source) catch return;
            defer ast.deinit(alloc);

            const printed = ast.print(alloc) catch return;
            alloc.free(printed);
        }
    };
    try std.testing.fuzz(Ctx{}, Ctx.run, .{});
}

test "fuzz round trip" {
    const Ctx = struct {
        fn run(_: @This(), input: []const u8) anyerror!void {
            const alloc = std.testing.allocator;

            // Use entropy to generate valid Yul
            var gen = YulGen.init(alloc, input);
            defer gen.deinit();
            const source = gen.generate() catch return;

            // First parse
            var ast1 = Self.parse(alloc, source) catch return;
            defer ast1.deinit(alloc);

            const print1 = ast1.print(alloc) catch return;
            defer alloc.free(print1);

            // Re-parse the printed output
            const source2 = try alloc.allocSentinel(u8, print1.len, 0);
            defer alloc.free(source2);
            @memcpy(source2[0..print1.len], print1);

            var ast2 = Self.parse(alloc, source2) catch return;
            defer ast2.deinit(alloc);

            const print2 = ast2.print(alloc) catch return;
            defer alloc.free(print2);

            // Round-trip invariant: print(parse(print(parse(x)))) == print(parse(x))
            try std.testing.expectEqualStrings(print1, print2);
        }
    };
    try std.testing.fuzz(Ctx{}, Ctx.run, .{});
}

test "fuzz differential" {
    // Only runs if reference binary exists
    const ref_path = "test/ref/build/yul_ref";
    std.fs.cwd().access(ref_path, .{}) catch return;

    const Ctx = struct {
        fn run(_: @This(), input: []const u8) anyerror!void {
            const alloc = std.testing.allocator;

            // Use entropy to generate valid Yul
            var gen = YulGen.init(alloc, input);
            defer gen.deinit();
            const source = gen.generate() catch return;

            // A = gyul parse + print
            var ast1 = Self.parse(alloc, source) catch return;
            defer ast1.deinit(alloc);

            const print_a = ast1.print(alloc) catch return;
            defer alloc.free(print_a);

            // B = solc ref parse + print of A
            const print_b = runRef(alloc, print_a) catch return;
            defer alloc.free(print_b);

            // C = gyul parse + print of B
            const source_b = try alloc.allocSentinel(u8, print_b.len, 0);
            defer alloc.free(source_b);
            @memcpy(source_b[0..print_b.len], print_b);

            var ast3 = Self.parse(alloc, source_b) catch return;
            defer ast3.deinit(alloc);

            const print_c = ast3.print(alloc) catch return;
            defer alloc.free(print_c);

            // Invariant: A == C
            try std.testing.expectEqualStrings(print_a, print_c);
        }
    };
    try std.testing.fuzz(Ctx{}, Ctx.run, .{});
}

fn runRef(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{"test/ref/build/yul_ref"},
        alloc,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    child.stdin.?.writeAll(input) catch {};
    child.stdin.?.close();
    child.stdin = null;

    const stdout = try child.stdout.?.readToEndAlloc(alloc, 1024 * 1024);
    errdefer alloc.free(stdout);

    const term = try child.wait();
    if (term.Exited != 0) return error.RefFailed;

    // Trim trailing newline
    var len = stdout.len;
    while (len > 0 and stdout[len - 1] == '\n') len -= 1;
    if (len < stdout.len) {
        const trimmed = try alloc.alloc(u8, len);
        @memcpy(trimmed, stdout[0..len]);
        alloc.free(stdout);
        return trimmed;
    }
    return stdout;
}
