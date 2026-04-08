//! Grammar-based Yul source generator for fuzz testing.
//! Consumes entropy bytes to make random choices about which constructs to emit.

const std = @import("std");

const Self = @This();

entropy: []const u8,
pos: usize,
buf: std.ArrayListUnmanaged(u8),
alloc: std.mem.Allocator,
/// Identifiers declared in the current scope (for valid references)
vars: std.ArrayListUnmanaged([]const u8),
depth: u8,
max_depth: u8,

const ident_pool = [_][]const u8{
    "x", "y", "z", "a", "b", "c", "r", "s", "t", "i", "j", "k",
    "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
};

const builtin_pool = [_][]const u8{
    "add",          "sub",      "mul",        "div",
    "sdiv",         "mod",      "smod",       "exp",
    "not",          "lt",       "gt",         "slt",
    "sgt",          "eq",       "iszero",     "and",
    "or",           "xor",      "byte",       "shl",
    "shr",          "sar",      "addmod",     "mulmod",
    "signextend",   "keccak256", "mload",     "mstore",
    "mstore8",      "sload",    "sstore",     "msize",
    "gas",          "address",  "balance",    "selfbalance",
    "caller",       "callvalue", "calldataload", "calldatasize",
    "calldatacopy", "returndatasize", "returndatacopy",
    "extcodesize",  "extcodecopy", "extcodehash",
    "pop",          "log0",     "log1",       "log2",
    "log3",         "log4",     "revert",     "return",
    "stop",         "invalid",
};

pub fn init(alloc: std.mem.Allocator, entropy: []const u8) Self {
    return .{
        .entropy = entropy,
        .pos = 0,
        .buf = .{},
        .alloc = alloc,
        .vars = .{},
        .depth = 0,
        .max_depth = 4,
    };
}

pub fn deinit(self: *Self) void {
    self.buf.deinit(self.alloc);
    self.vars.deinit(self.alloc);
}

/// Generate a complete Yul program from the entropy. Returns owned slice.
pub fn generate(self: *Self) ![:0]const u8 {
    try self.emit("{ ");
    const n_stmts = self.pick(4) + 1;
    for (0..n_stmts) |_| {
        try self.genStatement();
        try self.emit(" ");
    }
    try self.emit("}");
    try self.buf.append(self.alloc, 0);
    const slice = self.buf.items[0 .. self.buf.items.len - 1 :0];
    return slice;
}

fn genStatement(self: *Self) std.mem.Allocator.Error!void {
    if (self.depth >= self.max_depth) {
        // At max depth, only emit simple statements
        return switch (self.pick(3)) {
            0 => self.genLetSimple(),
            1 => self.genCallStmt(),
            2 => self.genAssignment(),
            else => unreachable,
        };
    }
    self.depth += 1;
    defer self.depth -= 1;

    switch (self.pick(8)) {
        0, 1 => try self.genLetSimple(),
        2 => try self.genLetCall(),
        3 => try self.genAssignment(),
        4 => try self.genCallStmt(),
        5 => try self.genIf(),
        6 => try self.genFor(),
        7 => try self.genSwitch(),
        else => unreachable,
    }
}

fn genLetSimple(self: *Self) !void {
    const name = self.pickIdent();
    try self.vars.append(self.alloc, name);
    try self.emit("let ");
    try self.emit(name);
    if (self.pick(2) == 0) {
        try self.emit(" := ");
        try self.genExpr();
    }
}

fn genLetCall(self: *Self) !void {
    const name = self.pickIdent();
    try self.vars.append(self.alloc, name);
    try self.emit("let ");
    try self.emit(name);
    try self.emit(" := ");
    try self.genCall();
}

fn genAssignment(self: *Self) !void {
    if (self.vars.items.len == 0) return self.genLetSimple();
    const name = self.pickVar();
    try self.emit(name);
    try self.emit(" := ");
    try self.genExpr();
}

fn genCallStmt(self: *Self) !void {
    try self.genCall();
}

fn genIf(self: *Self) !void {
    try self.emit("if ");
    try self.genExpr();
    try self.emit(" { ");
    const n = self.pick(3);
    for (0..n) |_| {
        try self.genStatement();
        try self.emit(" ");
    }
    try self.emit("}");
}

fn genFor(self: *Self) !void {
    try self.emit("for { ");
    // pre block — usually a let
    if (self.pick(2) == 0) {
        try self.genLetSimple();
        try self.emit(" ");
    }
    try self.emit("} ");
    try self.genExpr();
    try self.emit(" { ");
    // post block
    if (self.pick(2) == 0 and self.vars.items.len > 0) {
        try self.genAssignment();
        try self.emit(" ");
    }
    try self.emit("} { ");
    // body
    const n = self.pick(3);
    for (0..n) |_| {
        switch (self.pick(4)) {
            0 => try self.emit("break "),
            1 => try self.emit("continue "),
            else => {
                try self.genStatement();
                try self.emit(" ");
            },
        }
    }
    try self.emit("}");
}

fn genSwitch(self: *Self) !void {
    try self.emit("switch ");
    try self.genExpr();
    try self.emit(" ");
    const n_cases = self.pick(3) + 1;
    for (0..n_cases) |ci| {
        try self.emit("case ");
        try self.genNumber(@intCast(ci));
        try self.emit(" { ");
        if (self.pick(2) == 0) {
            try self.genStatement();
            try self.emit(" ");
        }
        try self.emit("} ");
    }
    if (self.pick(2) == 0) {
        try self.emit("default { ");
        if (self.pick(2) == 0) {
            try self.genStatement();
            try self.emit(" ");
        }
        try self.emit("}");
    }
}

fn genExpr(self: *Self) std.mem.Allocator.Error!void {
    switch (self.pick(4)) {
        0 => try self.genNumberLit(),
        1 => {
            // identifier (use existing var or fallback to number)
            if (self.vars.items.len > 0) {
                try self.emit(self.pickVar());
            } else {
                try self.genNumberLit();
            }
        },
        2, 3 => {
            if (self.depth < self.max_depth) {
                try self.genCall();
            } else {
                try self.genNumberLit();
            }
        },
        else => unreachable,
    }
}

fn genCall(self: *Self) std.mem.Allocator.Error!void {
    const builtin = builtin_pool[self.pick(builtin_pool.len)];
    try self.emit(builtin);
    try self.emit("(");
    // Most builtins take 1-3 args
    const n_args = self.pick(3) + 1;
    for (0..n_args) |ai| {
        if (ai > 0) try self.emit(", ");
        try self.genExpr();
    }
    try self.emit(")");
}

fn genNumberLit(self: *Self) !void {
    if (self.pick(3) == 0) {
        // hex literal
        try self.emit("0x");
        const n_digits = self.pick(4) + 1;
        const hex = "0123456789abcdef";
        for (0..n_digits) |_| {
            try self.buf.append(self.alloc, hex[self.pick(16)]);
        }
    } else {
        const val = self.pick(256);
        var num_buf: [4]u8 = undefined;
        const slice = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "0";
        try self.emit(slice);
    }
}

fn genNumber(self: *Self, val: u32) !void {
    var num_buf: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "0";
    try self.emit(slice);
}

// --- Helpers ---

fn pick(self: *Self, max: usize) usize {
    if (max == 0) return 0;
    if (self.pos >= self.entropy.len) return 0;
    const byte = self.entropy[self.pos];
    self.pos += 1;
    return @as(usize, byte) % max;
}

fn pickIdent(self: *Self) []const u8 {
    return ident_pool[self.pick(ident_pool.len)];
}

fn pickVar(self: *Self) []const u8 {
    if (self.vars.items.len == 0) return "x";
    return self.vars.items[self.pick(self.vars.items.len)];
}

fn emit(self: *Self, s: []const u8) !void {
    try self.buf.appendSlice(self.alloc, s);
}

test "generator produces parseable output" {
    const alloc = std.testing.allocator;
    const AST = @import("AST.zig");

    // Several different entropy seeds
    const seeds = [_][]const u8{
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        &.{ 255, 128, 64, 32, 16, 8, 4, 2, 1, 0, 200, 100, 50, 25 },
        &.{ 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42 },
        &.{ 7, 3, 5, 1, 0, 2, 6, 4, 7, 3, 5, 1, 0, 2, 6, 4, 7, 3, 5, 1 },
        &.{},
    };

    for (seeds) |seed| {
        var gen = Self.init(alloc, seed);
        defer gen.deinit();
        const source = try gen.generate();

        var ast = AST.parse(alloc, source) catch |err| {
            std.debug.print("Failed to parse generated Yul: {s}\nSource: {s}\n", .{ @errorName(err), source });
            return err;
        };
        defer ast.deinit(alloc);

        const printed = try ast.print(alloc);
        defer alloc.free(printed);
    }
}
