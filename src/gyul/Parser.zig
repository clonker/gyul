const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("AST.zig");
const ObjectTreeMod = @import("ObjectTree.zig");
const ObjectTree = ObjectTreeMod.ObjectTree;

const Parser = @This();

pub const Error = error{ParseError} || std.mem.Allocator.Error;

const max_nesting_depth = 256;

gpa: std.mem.Allocator,
source: [:0]const u8,
token_tags: []const tokenizer.Tag,
token_starts: []const ast.ByteOffset,
tok_i: ast.TokenIndex,
depth: u16,
errors: std.ArrayListUnmanaged(ast.Error),
nodes: std.ArrayListUnmanaged(ast.Node),
extra: std.ArrayListUnmanaged(ast.NodeIndex),
scratch: std.ArrayListUnmanaged(ast.NodeIndex),
/// Set once we've picked the root `code { ... }` body inside an object
/// wrapper. Subsequent `code` blocks encountered in sub-objects are still
/// parsed (to validate their syntax) but ignored. Used only by the
/// legacy `parseRoot` path; the tree builder (`parseObjectTreeRoot`)
/// keeps every code block.
root_populated: bool = false,
/// `data "name" ...` section content, decoded to bytes. Owned by the
/// parser; transferred to the AST on completion. Used only by the legacy
/// `parseRoot` path; the tree builder writes to per-object `data` maps.
data_sections: std.StringHashMapUnmanaged([]const u8),
/// Counter used to assign unique sentinels to `ObjectTree` nodes built
/// by the tree-mode entry point. Starts at 1; 0 is reserved as
/// "invalid/not-found" (see `ObjectTree.INVALID_SENTINEL`).
next_sentinel: u64 = 1,

// --- Public API ---

pub fn parseRoot(self: *Parser) !void {
    // Reserve slot 0 for the root node
    try self.nodes.append(self.gpa, undefined);

    self.eatComments();

    // Yul source can either be a bare code block `{ ... }` or an object
    // wrapper `object "name" { code { ... } ... }`. For the object case
    // we extract the first `code { body }` block we encounter (depth-first)
    // and use its body as the root; everything else (sub-objects, data
    // sections) is parsed for syntax but discarded.
    if (self.peek() == .identifier and self.tokenIs(self.tok_i, "object")) {
        try self.parseObject();
        if (!self.root_populated) return self.failMsg(.{
            .tag = .expected_block,
            .token = self.tok_i,
        });
        return;
    }

    const lbrace = try self.expectToken(.brace_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        self.eatComments();
        if (self.peek() == .brace_r or self.peek() == .eof) break;
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    const body = try self.addSpan(self.scratch.items[scratch_top..]);
    self.nodes.items[0] = .{ .root = .{ .token = lbrace, .body = body } };
}

// --- Yul object syntax ---

/// Returns true if the token at `tok` is an identifier with text equal
/// to `name`. Used to recognize the contextual keywords `object`, `code`,
/// and `data` which are not real tokenizer keywords.
fn tokenIs(self: *const Parser, tok: ast.TokenIndex, name: []const u8) bool {
    if (tok >= self.token_starts.len) return false;
    const start = self.token_starts[tok];
    const end: ast.ByteOffset = if (tok + 1 < self.token_starts.len)
        self.token_starts[tok + 1]
    else
        @intCast(self.source.len);
    // Trim trailing whitespace (same rule as AST.tokenSlice).
    var e = end;
    while (e > start and (self.source[e - 1] == ' ' or self.source[e - 1] == '\n' or self.source[e - 1] == '\t' or self.source[e - 1] == '\r')) {
        e -= 1;
    }
    return std.mem.eql(u8, self.source[start..e], name);
}

/// Parse `object "name" { (Code | Data | Object)* }`. The first `code`
/// body encountered (anywhere in the tree) becomes the AST root.
fn parseObject(self: *Parser) Error!void {
    if (self.depth >= max_nesting_depth) return self.failMsg(.{
        .tag = .expected_statement,
        .token = self.tok_i,
    });
    self.depth += 1;
    defer self.depth -= 1;

    _ = self.nextToken(); // consume `object`
    _ = try self.expectToken(.string_literal); // object name
    _ = try self.expectToken(.brace_l);

    while (true) {
        self.eatComments();
        const tag = self.peek();
        if (tag == .brace_r or tag == .eof) break;
        if (tag != .identifier) return self.failMsg(.{
            .tag = .expected_statement,
            .token = self.tok_i,
        });

        if (self.tokenIs(self.tok_i, "object")) {
            try self.parseObject();
        } else if (self.tokenIs(self.tok_i, "code")) {
            try self.parseObjectCode();
        } else if (self.tokenIs(self.tok_i, "data")) {
            try self.parseObjectData();
        } else {
            return self.failMsg(.{
                .tag = .expected_statement,
                .token = self.tok_i,
            });
        }
    }
    _ = try self.expectToken(.brace_r);
}

/// Parse a `code { body }` section. The first one encountered populates
/// the AST root; subsequent ones are parsed and discarded.
fn parseObjectCode(self: *Parser) Error!void {
    const code_tok = self.nextToken(); // consume `code`
    _ = try self.expectToken(.brace_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        self.eatComments();
        if (self.peek() == .brace_r or self.peek() == .eof) break;
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    if (!self.root_populated) {
        const body = try self.addSpan(self.scratch.items[scratch_top..]);
        self.nodes.items[0] = .{ .root = .{ .token = code_tok, .body = body } };
        self.root_populated = true;
    }
    // Else: statements are already in `self.nodes`, but the scratch span
    // is discarded so they're never referenced. Wasted storage, but the
    // parse remains well-formed.
}

/// Parse a `data "name" <value>` section. `<value>` is either a regular
/// string literal or a `hex"..."` literal. The decoded bytes are stored
/// in `data_sections` keyed by the unquoted name so the interpreter's
/// `datasize`/`dataoffset` builtins can resolve them.
fn parseObjectData(self: *Parser) Error!void {
    _ = self.nextToken(); // consume `data`
    const name_tok = try self.expectToken(.string_literal);
    const name_text = self.tokenSliceTrimmed(name_tok);
    if (name_text.len < 2 or name_text[0] != '"' or name_text[name_text.len - 1] != '"') {
        return self.failMsg(.{ .tag = .expected_token, .token = name_tok });
    }
    const name = name_text[1 .. name_text.len - 1];

    var bytes: []u8 = &.{};
    if (self.peek() == .keyword_hex) {
        _ = self.nextToken();
        const val_tok = try self.expectToken(.string_literal);
        const val_text = self.tokenSliceTrimmed(val_tok);
        if (val_text.len < 2 or val_text[0] != '"' or val_text[val_text.len - 1] != '"') {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        }
        const hex_str = val_text[1 .. val_text.len - 1];
        if (hex_str.len % 2 != 0) {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        }
        bytes = try self.gpa.alloc(u8, hex_str.len / 2);
        errdefer self.gpa.free(bytes);
        _ = std.fmt.hexToBytes(bytes, hex_str) catch {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        };
    } else {
        const val_tok = try self.expectToken(.string_literal);
        const val_text = self.tokenSliceTrimmed(val_tok);
        if (val_text.len < 2 or val_text[0] != '"' or val_text[val_text.len - 1] != '"') {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        }
        // Decode escape sequences (same set as the runtime literal helper).
        const inner = val_text[1 .. val_text.len - 1];
        bytes = try self.gpa.alloc(u8, inner.len);
        errdefer self.gpa.free(bytes);
        var pos: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\') {
                i += 1;
                if (i >= inner.len) return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
                bytes[pos] = switch (inner[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    'x' => x: {
                        if (i + 2 >= inner.len) return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
                        const byte = std.fmt.parseInt(u8, inner[i + 1 .. i + 3], 16) catch {
                            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
                        };
                        i += 2;
                        break :x byte;
                    },
                    else => return self.failMsg(.{ .tag = .expected_token, .token = val_tok }),
                };
            } else {
                bytes[pos] = inner[i];
            }
            pos += 1;
        }
        if (pos != inner.len) bytes = try self.gpa.realloc(bytes, pos);
    }

    // Last definition wins (matches solc).
    if (self.data_sections.fetchRemove(name)) |old| self.gpa.free(old.value);
    try self.data_sections.put(self.gpa, name, bytes);
}

// --- Tree-mode object parsing (additive, used by `AST.parseAny`) ---

/// Top-level entry point for tree mode. Source must begin with an
/// `object` wrapper. Reserves slot 0 as a `.root` placeholder, parses
/// the entire object tree (recursively), then fills slot 0 with a
/// `.root` whose body span is `[root_object_code_root]` so that
/// `Interpreter.execStmt(0)` runs the root object's constructor.
///
/// On success, `out` is fully populated and the parser's nodes/extra
/// pool is owned by the caller (typically transferred into an
/// `ObjectTreeRoot`).
pub fn parseRootObjectTree(self: *Parser, out: *ObjectTree) !void {
    try self.nodes.append(self.gpa, undefined); // reserve slot 0

    self.eatComments();
    if (!(self.peek() == .identifier and self.tokenIs(self.tok_i, "object"))) {
        return self.failMsg(.{
            .tag = .expected_block,
            .token = self.tok_i,
        });
    }

    try self.parseObjectTreeNode(out, null);

    if (out.code_root == ast.null_node) {
        // Root object must have a code block (solc-emitted shape).
        return self.failMsg(.{
            .tag = .expected_block,
            .token = self.tok_i,
        });
    }

    // Synthesize slot 0 as a `.root` whose single body entry is the
    // root object's code block. Reuses the existing `addSpan` extra-pool
    // mechanism so the interpreter walks `.root → .block → statements`.
    const span = try self.addSpan(&[_]ast.NodeIndex{out.code_root});
    const code_block = self.nodes.items[out.code_root];
    self.nodes.items[0] = .{ .root = .{
        .token = code_block.getToken(),
        .body = span,
    } };
}

/// Recursively parse one `object "name" { ... }` form into `out`.
/// `parent` is the enclosing object (null for the root). All children,
/// data sections, and the code block are populated on `out`.
fn parseObjectTreeNode(
    self: *Parser,
    out: *ObjectTree,
    parent: ?*const ObjectTree,
) Error!void {
    if (self.depth >= max_nesting_depth) return self.failMsg(.{
        .tag = .expected_statement,
        .token = self.tok_i,
    });
    self.depth += 1;
    defer self.depth -= 1;

    _ = self.nextToken(); // consume `object`
    const name_tok = try self.expectToken(.string_literal);
    const name_text = self.tokenSliceTrimmed(name_tok);
    if (name_text.len < 2 or name_text[0] != '"' or name_text[name_text.len - 1] != '"') {
        return self.failMsg(.{ .tag = .expected_token, .token = name_tok });
    }
    const name_owned = try self.gpa.dupe(u8, name_text[1 .. name_text.len - 1]);
    errdefer self.gpa.free(name_owned);

    out.* = .{
        .name = name_owned,
        .code_root = ast.null_node,
        .data = .{},
        .children = &.{},
        .sentinel = self.next_sentinel,
        .parent = parent,
    };
    self.next_sentinel += 1;
    if (self.next_sentinel == 0) self.next_sentinel = 1; // overflow guard

    // Track child objects in `child_scratch` so we can finalize a single
    // owned slice at the end. Use a separate ArrayList because children
    // are full ObjectTree values (not NodeIndices), so we can't use the
    // shared `scratch` array.
    var child_scratch: std.ArrayListUnmanaged(ObjectTree) = .{};
    errdefer {
        for (child_scratch.items) |*c| {
            var c_copy = c.*;
            c_copy.deinit(self.gpa);
        }
        child_scratch.deinit(self.gpa);
    }

    _ = try self.expectToken(.brace_l);
    while (true) {
        self.eatComments();
        const tag = self.peek();
        if (tag == .brace_r or tag == .eof) break;
        if (tag != .identifier) return self.failMsg(.{
            .tag = .expected_statement,
            .token = self.tok_i,
        });

        if (self.tokenIs(self.tok_i, "object")) {
            // Parse into a stack-local first so the errdefer doesn't
            // see a half-initialized slot if parsing fails midway.
            // The recursive call's own errdefer cleans up its state.
            var child: ObjectTree = undefined;
            try self.parseObjectTreeNode(&child, out);
            try child_scratch.append(self.gpa, child);
        } else if (self.tokenIs(self.tok_i, "code")) {
            try self.parseObjectTreeCode(out);
        } else if (self.tokenIs(self.tok_i, "data")) {
            try self.parseObjectTreeData(out);
        } else {
            return self.failMsg(.{
                .tag = .expected_statement,
                .token = self.tok_i,
            });
        }
    }
    _ = try self.expectToken(.brace_r);

    out.children = try child_scratch.toOwnedSlice(self.gpa);
}

/// Parse `code { body }` and store its `.block` NodeIndex on `out`.
/// Multiple `code` blocks per object are not allowed (matches solc).
fn parseObjectTreeCode(self: *Parser, out: *ObjectTree) Error!void {
    if (out.code_root != ast.null_node) {
        return self.failMsg(.{
            .tag = .expected_statement,
            .token = self.tok_i,
        });
    }

    const code_tok = self.nextToken(); // consume `code`
    const lbrace = try self.expectToken(.brace_l);
    _ = code_tok;

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        self.eatComments();
        if (self.peek() == .brace_r or self.peek() == .eof) break;
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    const stmts = try self.addSpan(self.scratch.items[scratch_top..]);
    out.code_root = try self.addNode(.{ .block = .{ .token = lbrace, .stmts = stmts } });
}

/// Parse a `data "name" <value>` section and write to `out.data`. The
/// payload format matches `parseObjectData` (string literal or
/// `hex"..."`). Both keys and values are owned by `out`.
fn parseObjectTreeData(self: *Parser, out: *ObjectTree) Error!void {
    _ = self.nextToken(); // consume `data`
    const name_tok = try self.expectToken(.string_literal);
    const name_text = self.tokenSliceTrimmed(name_tok);
    if (name_text.len < 2 or name_text[0] != '"' or name_text[name_text.len - 1] != '"') {
        return self.failMsg(.{ .tag = .expected_token, .token = name_tok });
    }
    const inner_name = name_text[1 .. name_text.len - 1];
    const name_owned = try self.gpa.dupe(u8, inner_name);
    errdefer self.gpa.free(name_owned);

    const bytes = try self.parseDataPayload();

    if (out.data.fetchRemove(inner_name)) |old| {
        self.gpa.free(old.key);
        self.gpa.free(old.value);
    }
    try out.data.put(self.gpa, name_owned, bytes);
}

/// Decode the value side of a `data` section: a regular string literal
/// (with `\xNN` escapes) or a `hex"..."` literal. Returns owned bytes.
fn parseDataPayload(self: *Parser) Error![]u8 {
    if (self.peek() == .keyword_hex) {
        _ = self.nextToken();
        const val_tok = try self.expectToken(.string_literal);
        const val_text = self.tokenSliceTrimmed(val_tok);
        if (val_text.len < 2 or val_text[0] != '"' or val_text[val_text.len - 1] != '"') {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        }
        const hex_str = val_text[1 .. val_text.len - 1];
        if (hex_str.len % 2 != 0) {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        }
        const out = try self.gpa.alloc(u8, hex_str.len / 2);
        errdefer self.gpa.free(out);
        _ = std.fmt.hexToBytes(out, hex_str) catch {
            return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
        };
        return out;
    }

    const val_tok = try self.expectToken(.string_literal);
    const val_text = self.tokenSliceTrimmed(val_tok);
    if (val_text.len < 2 or val_text[0] != '"' or val_text[val_text.len - 1] != '"') {
        return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
    }
    const inner = val_text[1 .. val_text.len - 1];
    const out = try self.gpa.alloc(u8, inner.len);
    errdefer self.gpa.free(out);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\') {
            i += 1;
            if (i >= inner.len) return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
            out[pos] = switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                'x' => x: {
                    if (i + 2 >= inner.len) return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
                    const byte = std.fmt.parseInt(u8, inner[i + 1 .. i + 3], 16) catch {
                        return self.failMsg(.{ .tag = .expected_token, .token = val_tok });
                    };
                    i += 2;
                    break :x byte;
                },
                else => return self.failMsg(.{ .tag = .expected_token, .token = val_tok }),
            };
        } else {
            out[pos] = inner[i];
        }
        pos += 1;
    }
    if (pos != inner.len) return try self.gpa.realloc(out, pos);
    return out;
}

/// Like `tokenSlice` on the AST but using parser-internal state.
fn tokenSliceTrimmed(self: *const Parser, tok: ast.TokenIndex) []const u8 {
    const start = self.token_starts[tok];
    const end: ast.ByteOffset = if (tok + 1 < self.token_starts.len)
        self.token_starts[tok + 1]
    else
        @intCast(self.source.len);
    var e = end;
    while (e > start and (self.source[e - 1] == ' ' or self.source[e - 1] == '\n' or self.source[e - 1] == '\t' or self.source[e - 1] == '\r')) {
        e -= 1;
    }
    return self.source[start..e];
}

// --- Statements ---

fn parseStatement(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .brace_l => self.parseBlock(),
        .keyword_let => self.parseVariableDeclaration(),
        .keyword_if => self.parseIf(),
        .keyword_for => self.parseForLoop(),
        .keyword_switch => self.parseSwitch(),
        .keyword_function => self.parseFunctionDefinition(),
        .keyword_break => self.parseBreak(),
        .keyword_continue => self.parseContinue(),
        .keyword_leave => self.parseLeave(),
        .identifier => self.parseIdentifierStatement(),
        else => self.failMsg(.{
            .tag = .expected_statement,
            .token = self.tok_i,
        }),
    };
}

fn parseBlock(self: *Parser) Error!ast.NodeIndex {
    if (self.depth >= max_nesting_depth) return self.failMsg(.{
        .tag = .expected_statement,
        .token = self.tok_i,
    });
    self.depth += 1;
    defer self.depth -= 1;

    self.eatComments();
    const lbrace = try self.expectToken(.brace_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        self.eatComments();
        if (self.peek() == .brace_r or self.peek() == .eof) break;
        const stmt = try self.parseStatement();
        try self.scratch.append(self.gpa, stmt);
    }
    _ = try self.expectToken(.brace_r);

    const stmts = try self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .block = .{ .token = lbrace, .stmts = stmts } });
}

fn parseVariableDeclaration(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `let`

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    while (self.peek() == .comma) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    }

    const names = try self.addSpan(self.scratch.items[scratch_top..]);

    var value: ast.NodeIndex = ast.null_node;
    if (self.peek() == .colon_assign) {
        _ = self.nextToken();
        value = try self.parseExpression();
    }

    return self.addNode(.{ .variable_declaration = .{
        .token = tok,
        .names = names,
        .value = value,
    } });
}

fn parseIf(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `if`
    const condition = try self.parseExpression();
    const body = try self.parseBlock();
    return self.addNode(.{ .if_statement = .{
        .token = tok,
        .condition = condition,
        .body = body,
    } });
}

fn parseForLoop(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `for`
    const pre = try self.parseBlock();
    const condition = try self.parseExpression();
    const post = try self.parseBlock();
    const body = try self.parseBlock();
    return self.addNode(.{ .for_loop = .{
        .token = tok,
        .pre = pre,
        .condition = condition,
        .post = post,
        .body = body,
    } });
}

fn parseSwitch(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `switch`
    const expr = try self.parseExpression();

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    self.eatComments();
    while (self.peek() == .keyword_case or self.peek() == .keyword_default) {
        if (self.peek() == .keyword_default) {
            const default_tok = self.nextToken();
            const body = try self.parseBlock();
            const node = try self.addNode(.{ .case_default = .{
                .token = default_tok,
                .body = body,
            } });
            try self.scratch.append(self.gpa, node);
        } else {
            const case_tok = self.nextToken();
            const value = try self.parseLiteral();
            const body = try self.parseBlock();
            const node = try self.addNode(.{ .case_clause = .{
                .token = case_tok,
                .value = value,
                .body = body,
            } });
            try self.scratch.append(self.gpa, node);
        }
    }

    const cases = try self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .switch_statement = .{
        .token = tok,
        .expr = expr,
        .cases = cases,
    } });
}

fn parseFunctionDefinition(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // consume `function`
    const name = try self.expectToken(.identifier);
    _ = try self.expectToken(.parenthesis_l);

    // Parse parameters
    const params_top = self.scratch.items.len;
    if (self.peek() == .identifier) {
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        }
    }
    _ = try self.expectToken(.parenthesis_r);
    const params = try self.addSpan(self.scratch.items[params_top..]);
    self.scratch.shrinkRetainingCapacity(params_top);

    // Parse return variables
    const rets_top = self.scratch.items.len;
    if (self.peek() == .arrow) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseIdentifierNode());
        }
    }
    const return_vars = try self.addSpan(self.scratch.items[rets_top..]);
    self.scratch.shrinkRetainingCapacity(rets_top);

    const body = try self.parseBlock();

    return self.addNode(.{ .function_definition = .{
        .token = tok,
        .name = name,
        .params = params,
        .return_vars = return_vars,
        .body = body,
    } });
}

fn parseBreak(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .@"break" = .{ .token = tok } });
}

fn parseContinue(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .@"continue" = .{ .token = tok } });
}

fn parseLeave(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .leave = .{ .token = tok } });
}

fn parseIdentifierStatement(self: *Parser) Error!ast.NodeIndex {
    // Could be: function call or assignment
    const ident = try self.parseIdentifierNode();

    if (self.peek() == .parenthesis_l) {
        // Function call as statement
        const call = try self.parseFunctionCallWithToken(self.nodes.items[ident].identifier.token);
        return self.addNode(.{ .expression_statement = .{
            .token = self.nodes.items[call].function_call.token,
            .expr = call,
        } });
    }

    // Assignment: x, y, z := expr
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.append(self.gpa, ident);

    while (self.peek() == .comma) {
        _ = self.nextToken();
        try self.scratch.append(self.gpa, try self.parseIdentifierNode());
    }

    const assign_tok = try self.expectToken(.colon_assign);
    const value = try self.parseExpression();
    const targets = try self.addSpan(self.scratch.items[scratch_top..]);

    return self.addNode(.{ .assignment = .{
        .token = assign_tok,
        .targets = targets,
        .value = value,
    } });
}

// --- Expressions ---

fn parseExpression(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .identifier => self.parseIdentifierExpression(),
        .number_literal, .hex_number_literal => self.parseNumberLiteral(),
        .string_literal => self.parseStringLiteral(),
        .keyword_true, .keyword_false => self.parseBoolLiteral(),
        .keyword_hex => self.parseHexLiteral(),
        else => self.failMsg(.{
            .tag = .expected_expression,
            .token = self.tok_i,
        }),
    };
}

fn parseLiteral(self: *Parser) Error!ast.NodeIndex {
    self.eatComments();
    return switch (self.peek()) {
        .number_literal, .hex_number_literal => self.parseNumberLiteral(),
        .string_literal => self.parseStringLiteral(),
        .keyword_true, .keyword_false => self.parseBoolLiteral(),
        .keyword_hex => self.parseHexLiteral(),
        else => self.failMsg(.{
            .tag = .expected_expression,
            .token = self.tok_i,
        }),
    };
}

fn parseIdentifierExpression(self: *Parser) Error!ast.NodeIndex {
    const ident = try self.parseIdentifierNode();
    if (self.peek() == .parenthesis_l) {
        return self.parseFunctionCallWithToken(self.nodes.items[ident].identifier.token);
    }
    return ident;
}

fn parseFunctionCallWithToken(self: *Parser, name_token: ast.TokenIndex) Error!ast.NodeIndex {
    _ = try self.expectToken(.parenthesis_l);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    if (self.peek() != .parenthesis_r) {
        try self.scratch.append(self.gpa, try self.parseExpression());
        while (self.peek() == .comma) {
            _ = self.nextToken();
            try self.scratch.append(self.gpa, try self.parseExpression());
        }
    }
    _ = try self.expectToken(.parenthesis_r);

    const args = try self.addSpan(self.scratch.items[scratch_top..]);
    return self.addNode(.{ .function_call = .{ .token = name_token, .args = args } });
}

fn parseIdentifierNode(self: *Parser) Error!ast.NodeIndex {
    const tok = try self.expectToken(.identifier);
    return self.addNode(.{ .identifier = .{ .token = tok } });
}

fn parseNumberLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .number_literal = .{ .token = tok } });
}

fn parseStringLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .string_literal = .{ .token = tok } });
}

fn parseBoolLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken();
    return self.addNode(.{ .bool_literal = .{ .token = tok } });
}

fn parseHexLiteral(self: *Parser) Error!ast.NodeIndex {
    const tok = self.nextToken(); // `hex` keyword
    const value = try self.expectToken(.string_literal);
    return self.addNode(.{ .hex_literal = .{ .token = tok, .value = value } });
}

// --- Helpers ---

fn peek(self: *Parser) tokenizer.Tag {
    if (self.tok_i >= self.token_tags.len) return .eof;
    return self.token_tags[self.tok_i];
}

fn eatComments(self: *Parser) void {
    while (self.tok_i < self.token_tags.len and
        (self.token_tags[self.tok_i] == .comment_single_line or
        self.token_tags[self.tok_i] == .comment_multi_line))
    {
        _ = self.nextToken();
    }
}

fn nextToken(self: *Parser) ast.TokenIndex {
    const result = self.tok_i;
    self.tok_i += 1;
    return result;
}

fn expectToken(self: *Parser, tag: tokenizer.Tag) Error!ast.TokenIndex {
    if (self.peek() != tag) {
        return self.failMsg(.{
            .tag = .expected_token,
            .token = self.tok_i,
            .extra = .{ .expected_tag = tag },
        });
    }
    return self.nextToken();
}

fn addNode(self: *Parser, node: ast.Node) Error!ast.NodeIndex {
    const idx: ast.NodeIndex = @intCast(self.nodes.items.len);
    try self.nodes.append(self.gpa, node);
    return idx;
}

fn addSpan(self: *Parser, items: []const ast.NodeIndex) Error!ast.Span {
    const start: u32 = @intCast(self.extra.items.len);
    try self.extra.appendSlice(self.gpa, items);
    return .{ .start = start, .len = @intCast(items.len) };
}

fn failMsg(self: *Parser, msg: ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try self.warnMsg(msg);
    return error.ParseError;
}

fn warnMsg(self: *Parser, msg: ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);
    try self.errors.append(self.gpa, msg);
}
