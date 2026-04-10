//! EVM dialect builtin dispatch for the Yul interpreter.
//!
//! This module owns the static metadata (`BuiltinTag`, `builtin_info`,
//! `builtin_map`), the dispatch (`eval`), and all builtin-local helpers
//! (memory copy padding, return-data bounds checking, object-access
//! pseudo-builtins, etc.).
//!
//! The walker in `Interpreter.zig` evaluates expression arguments
//! right-to-left, validates arity against `builtin_info`, and then calls
//! `EVMBuiltins.eval(interp, tag, arg_nodes, arg_values)`. The functions
//! in this module take `*Interpreter` as their first parameter so that
//! halt reasons, the global state, and the allocator are reachable
//! without a back-pointer struct.

const std = @import("std");
const AST = @import("AST.zig");
const GlobalState = @import("GlobalState.zig");
const LocalState = @import("LocalState.zig");
const u256_ops = @import("u256_ops.zig");
const Interpreter = @import("Interpreter.zig");

const Values = Interpreter.Values;
const InterpreterError = Interpreter.InterpreterError;

/// Hard cap on contract call frame depth (matches EVM EIP-150).
const MAX_FRAME_DEPTH: u32 = 1024;

// ── Builtin tag table ───────────────────────────────────────────────

pub const BuiltinTag = enum {
    // Arithmetic
    add,
    sub,
    mul,
    div,
    sdiv,
    mod_,
    smod,
    exp,
    addmod,
    mulmod,
    signextend,
    // Comparison
    lt,
    gt,
    slt,
    sgt,
    eq,
    iszero,
    // Bitwise
    not_,
    and_,
    or_,
    xor,
    shl,
    shr,
    sar,
    byte_,
    // Storage
    sstore,
    sload,
    tstore,
    tload,
    // Memory
    mstore,
    mstore8,
    mload,
    msize,
    // Logging
    log0,
    log1,
    log2,
    log3,
    log4,
    // Memory copy
    mcopy,
    // Call data & return data
    calldataload,
    calldatasize,
    calldatacopy,
    returndatasize,
    returndatacopy,
    codecopy,
    extcodecopy,
    // Context getters
    address,
    balance,
    origin,
    caller,
    callvalue,
    gasprice,
    coinbase,
    timestamp,
    number,
    prevrandao,
    gaslimit,
    chainid,
    selfbalance,
    basefee,
    blobhash,
    blobbasefee,
    gas,
    codesize,
    pc,
    // Hash & crypto
    keccak256,
    blockhash,
    // Arithmetic
    clz,
    // Control flow halts
    stop,
    return_,
    revert,
    invalid,
    // Contract interaction (stubs)
    call,
    staticcall,
    delegatecall,
    callcode,
    create,
    create2,
    extcodesize,
    extcodehash,
    selfdestruct,
    // Misc
    pop,
    // Solidity/Yul pseudo-builtins
    memoryguard,
    // Object-access pseudo-builtins (first arg is a literal string)
    datasize,
    dataoffset,
    datacopy,
    setimmutable,
    loadimmutable,
    linkersymbol,
};

/// Static metadata for each builtin: arity, return count, and which
/// argument slots (if any) must be literal expressions rather than
/// evaluated values. The interpreter validates `args.len ==
/// num_params` before dispatch and refuses to evaluate slots that need
/// to remain literals.
pub const LiteralKind = enum { number, string };

pub const BuiltinInfo = struct {
    num_params: u32,
    num_returns: u32,
    /// One entry per parameter; null = ordinary expression slot.
    literal_args: []const ?LiteralKind = &.{},
};

pub const builtin_info = blk: {
    const max_tag = @typeInfo(BuiltinTag).@"enum".fields.len;
    var arr: [max_tag]BuiltinInfo = undefined;

    // Defaults: zero/zero. Real entries follow.
    for (&arr) |*e| e.* = .{ .num_params = 0, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.add)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.sub)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.mul)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.div)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.sdiv)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.mod_)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.smod)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.exp)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.addmod)] = .{ .num_params = 3, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.mulmod)] = .{ .num_params = 3, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.signextend)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.lt)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.gt)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.slt)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.sgt)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.eq)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.iszero)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.not_)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.and_)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.or_)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.xor)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.shl)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.shr)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.sar)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.byte_)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.clz)] = .{ .num_params = 1, .num_returns = 1 };

    arr[@intFromEnum(BuiltinTag.sstore)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.sload)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.tstore)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.tload)] = .{ .num_params = 1, .num_returns = 1 };

    arr[@intFromEnum(BuiltinTag.mstore)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.mstore8)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.mload)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.msize)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.mcopy)] = .{ .num_params = 3, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.log0)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.log1)] = .{ .num_params = 3, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.log2)] = .{ .num_params = 4, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.log3)] = .{ .num_params = 5, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.log4)] = .{ .num_params = 6, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.calldataload)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.calldatasize)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.calldatacopy)] = .{ .num_params = 3, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.returndatasize)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.returndatacopy)] = .{ .num_params = 3, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.codecopy)] = .{ .num_params = 3, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.extcodecopy)] = .{ .num_params = 4, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.address)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.balance)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.origin)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.caller)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.callvalue)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.gasprice)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.coinbase)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.timestamp)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.number)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.prevrandao)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.gaslimit)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.chainid)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.selfbalance)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.basefee)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.blobhash)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.blobbasefee)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.gas)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.codesize)] = .{ .num_params = 0, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.pc)] = .{ .num_params = 0, .num_returns = 1 };

    arr[@intFromEnum(BuiltinTag.keccak256)] = .{ .num_params = 2, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.blockhash)] = .{ .num_params = 1, .num_returns = 1 };

    arr[@intFromEnum(BuiltinTag.stop)] = .{ .num_params = 0, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.return_)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.revert)] = .{ .num_params = 2, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.invalid)] = .{ .num_params = 0, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.call)] = .{ .num_params = 7, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.callcode)] = .{ .num_params = 7, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.delegatecall)] = .{ .num_params = 6, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.staticcall)] = .{ .num_params = 6, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.create)] = .{ .num_params = 3, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.create2)] = .{ .num_params = 4, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.extcodesize)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.extcodehash)] = .{ .num_params = 1, .num_returns = 1 };
    arr[@intFromEnum(BuiltinTag.selfdestruct)] = .{ .num_params = 1, .num_returns = 0 };

    arr[@intFromEnum(BuiltinTag.pop)] = .{ .num_params = 1, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.memoryguard)] = .{ .num_params = 1, .num_returns = 1 };

    // Object-access pseudo-builtins. First arg is a literal string,
    // except `datacopy` (3 evaluated args) and `setimmutable` whose
    // *second* arg is the literal name.
    arr[@intFromEnum(BuiltinTag.datasize)] = .{
        .num_params = 1,
        .num_returns = 1,
        .literal_args = &[_]?LiteralKind{.string},
    };
    arr[@intFromEnum(BuiltinTag.dataoffset)] = .{
        .num_params = 1,
        .num_returns = 1,
        .literal_args = &[_]?LiteralKind{.string},
    };
    arr[@intFromEnum(BuiltinTag.datacopy)] = .{ .num_params = 3, .num_returns = 0 };
    arr[@intFromEnum(BuiltinTag.setimmutable)] = .{
        .num_params = 3,
        .num_returns = 0,
        .literal_args = &[_]?LiteralKind{ null, .string, null },
    };
    arr[@intFromEnum(BuiltinTag.loadimmutable)] = .{
        .num_params = 1,
        .num_returns = 1,
        .literal_args = &[_]?LiteralKind{.string},
    };
    arr[@intFromEnum(BuiltinTag.linkersymbol)] = .{
        .num_params = 1,
        .num_returns = 1,
        .literal_args = &[_]?LiteralKind{.string},
    };

    break :blk arr;
};

pub const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "add", .add },
    .{ "sub", .sub },
    .{ "mul", .mul },
    .{ "div", .div },
    .{ "sdiv", .sdiv },
    .{ "mod", .mod_ },
    .{ "smod", .smod },
    .{ "exp", .exp },
    .{ "addmod", .addmod },
    .{ "mulmod", .mulmod },
    .{ "signextend", .signextend },
    .{ "lt", .lt },
    .{ "gt", .gt },
    .{ "slt", .slt },
    .{ "sgt", .sgt },
    .{ "eq", .eq },
    .{ "iszero", .iszero },
    .{ "not", .not_ },
    .{ "and", .and_ },
    .{ "or", .or_ },
    .{ "xor", .xor },
    .{ "shl", .shl },
    .{ "shr", .shr },
    .{ "sar", .sar },
    .{ "byte", .byte_ },
    .{ "sstore", .sstore },
    .{ "sload", .sload },
    .{ "tstore", .tstore },
    .{ "tload", .tload },
    .{ "mstore", .mstore },
    .{ "mstore8", .mstore8 },
    .{ "mload", .mload },
    .{ "msize", .msize },
    .{ "log0", .log0 },
    .{ "log1", .log1 },
    .{ "log2", .log2 },
    .{ "log3", .log3 },
    .{ "log4", .log4 },
    .{ "mcopy", .mcopy },
    .{ "calldataload", .calldataload },
    .{ "calldatasize", .calldatasize },
    .{ "calldatacopy", .calldatacopy },
    .{ "returndatasize", .returndatasize },
    .{ "returndatacopy", .returndatacopy },
    .{ "codecopy", .codecopy },
    .{ "extcodecopy", .extcodecopy },
    .{ "address", .address },
    .{ "balance", .balance },
    .{ "origin", .origin },
    .{ "caller", .caller },
    .{ "callvalue", .callvalue },
    .{ "gasprice", .gasprice },
    .{ "coinbase", .coinbase },
    .{ "timestamp", .timestamp },
    .{ "number", .number },
    .{ "prevrandao", .prevrandao },
    .{ "gaslimit", .gaslimit },
    .{ "chainid", .chainid },
    .{ "selfbalance", .selfbalance },
    .{ "basefee", .basefee },
    .{ "blobhash", .blobhash },
    .{ "blobbasefee", .blobbasefee },
    .{ "gas", .gas },
    .{ "codesize", .codesize },
    .{ "pc", .pc },
    .{ "keccak256", .keccak256 },
    .{ "blockhash", .blockhash },
    .{ "clz", .clz },
    .{ "stop", .stop },
    .{ "return", .return_ },
    .{ "revert", .revert },
    .{ "invalid", .invalid },
    .{ "call", .call },
    .{ "staticcall", .staticcall },
    .{ "delegatecall", .delegatecall },
    .{ "callcode", .callcode },
    .{ "create", .create },
    .{ "create2", .create2 },
    .{ "extcodesize", .extcodesize },
    .{ "extcodehash", .extcodehash },
    .{ "selfdestruct", .selfdestruct },
    .{ "pop", .pop },
    .{ "memoryguard", .memoryguard },
    .{ "datasize", .datasize },
    .{ "dataoffset", .dataoffset },
    .{ "datacopy", .datacopy },
    .{ "setimmutable", .setimmutable },
    .{ "loadimmutable", .loadimmutable },
    .{ "linkersymbol", .linkersymbol },
});

// ── solc-compat trace pointer rewrite ──────────────────────────────
//
// solc's `loadResolver` optimizer pass rewrites the input memory
// pointer of certain instructions to zero when the corresponding
// length argument is zero. To keep traces equivalent before and
// after that pass, solc's `EVMInstructionInterpreter` reproduces the
// rewrite when formatting the trace. We mirror that behavior under
// `--solc-compat` only — outside of compat mode the trace prints
// the actual argument values per real EVM semantics.
//
// The table below records, for each builtin, which arg index holds
// the input memory pointer and which holds the length. A null entry
// means the rewrite does not apply.

const TracePtrRewrite = struct {
    ptr_arg_idx: u8,
    len_arg_idx: u8,
};

const trace_ptr_rewrite: [@typeInfo(BuiltinTag).@"enum".fields.len]?TracePtrRewrite = blk: {
    var arr: [@typeInfo(BuiltinTag).@"enum".fields.len]?TracePtrRewrite = @splat(null);
    arr[@intFromEnum(BuiltinTag.return_)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.revert)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.returndatacopy)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.calldatacopy)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.codecopy)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.datacopy)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.extcodecopy)] = .{ .ptr_arg_idx = 1, .len_arg_idx = 3 };
    arr[@intFromEnum(BuiltinTag.log0)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.log1)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.log2)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.log3)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.log4)] = .{ .ptr_arg_idx = 0, .len_arg_idx = 1 };
    arr[@intFromEnum(BuiltinTag.create)] = .{ .ptr_arg_idx = 1, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.create2)] = .{ .ptr_arg_idx = 1, .len_arg_idx = 2 };
    arr[@intFromEnum(BuiltinTag.call)] = .{ .ptr_arg_idx = 3, .len_arg_idx = 4 };
    arr[@intFromEnum(BuiltinTag.callcode)] = .{ .ptr_arg_idx = 3, .len_arg_idx = 4 };
    arr[@intFromEnum(BuiltinTag.delegatecall)] = .{ .ptr_arg_idx = 2, .len_arg_idx = 3 };
    arr[@intFromEnum(BuiltinTag.staticcall)] = .{ .ptr_arg_idx = 2, .len_arg_idx = 3 };
    break :blk arr;
};

/// Like `GlobalState.logTrace`, but consults the rewrite table when
/// `solc_compat` is enabled. If the builtin's length arg is zero, the
/// corresponding pointer arg prints as 0 instead of its actual value.
fn traceBuiltin(
    interp: *Interpreter,
    tag: BuiltinTag,
    name: []const u8,
    args: []const u256,
    data: []const u8,
    writes_memory: bool,
) void {
    if (interp.global.solc_compat) {
        if (trace_ptr_rewrite[@intFromEnum(tag)]) |rw| {
            if (rw.len_arg_idx < args.len and rw.ptr_arg_idx < args.len and args[rw.len_arg_idx] == 0) {
                // Stack-buffer the rewritten args. The largest arity we
                // care about is log4 (6 args) and call/callcode (7).
                var rewritten: [8]u256 = undefined;
                @memcpy(rewritten[0..args.len], args);
                rewritten[rw.ptr_arg_idx] = 0;
                interp.global.logTrace(name, rewritten[0..args.len], data, writes_memory) catch {};
                return;
            }
        }
    }
    interp.global.logTrace(name, args, data, writes_memory) catch {};
}

// ── Literal helpers (for object-access pseudo-builtins) ────────────

/// True if `node_idx` is a literal of the requested kind.
pub fn isLiteralOfKind(ast: *const AST, node_idx: AST.NodeIndex, kind: LiteralKind) bool {
    return switch (ast.nodes[node_idx]) {
        .number_literal => kind == .number,
        .hex_literal, .string_literal => kind == .string,
        else => false,
    };
}

/// Returns the unescaped/unquoted string contents of a literal node, used
/// by `datasize("name")` etc. The result borrows from the source text — for
/// `\xNN`-escaped string literals we allocate a fresh copy. The caller is
/// responsible for freeing if `owned == true`.
fn literalString(interp: *Interpreter, node_idx: AST.NodeIndex) InterpreterError!struct { text: []const u8, owned: bool } {
    const node = interp.ast.nodes[node_idx];
    return switch (node) {
        .string_literal => |n| blk: {
            const text = interp.ast.tokenSlice(n.token);
            if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"')
                return error.InvalidLiteral;
            const inner = text[1 .. text.len - 1];
            // Fast path: no escapes → borrow from source.
            if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
                break :blk .{ .text = inner, .owned = false };
            }
            // Slow path: decode escapes into a fresh buffer.
            const buf = try interp.allocator.alloc(u8, inner.len);
            errdefer interp.allocator.free(buf);
            var pos: usize = 0;
            var i: usize = 0;
            while (i < inner.len) : (i += 1) {
                if (inner[i] == '\\') {
                    i += 1;
                    if (i >= inner.len) return error.InvalidLiteral;
                    buf[pos] = switch (inner[i]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '0' => 0,
                        '\\' => '\\',
                        '"' => '"',
                        '\'' => '\'',
                        'x' => x: {
                            if (i + 2 >= inner.len) return error.InvalidLiteral;
                            const byte = std.fmt.parseInt(u8, inner[i + 1 .. i + 3], 16) catch return error.InvalidLiteral;
                            i += 2;
                            break :x byte;
                        },
                        else => return error.InvalidLiteral,
                    };
                } else {
                    buf[pos] = inner[i];
                }
                pos += 1;
            }
            break :blk .{ .text = buf[0..pos], .owned = true };
        },
        .hex_literal => |n| blk: {
            const text = interp.ast.tokenSlice(n.value);
            if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"')
                return error.InvalidLiteral;
            break :blk .{ .text = text[1 .. text.len - 1], .owned = false };
        },
        else => error.LiteralArgumentRequired,
    };
}

// ── Builtin Dispatch ────────────────────────────────────────────────

pub fn eval(interp: *Interpreter, tag: BuiltinTag, arg_nodes: []const AST.NodeIndex, args: []const u256) InterpreterError!Values {
    return switch (tag) {
        // Arithmetic (2 args → 1 result)
        .add => bin(u256_ops.add, args),
        .sub => bin(u256_ops.sub, args),
        .mul => bin(u256_ops.mul, args),
        .div => bin(u256_ops.div, args),
        .sdiv => bin(u256_ops.sdiv, args),
        .mod_ => bin(u256_ops.mod_, args),
        .smod => bin(u256_ops.smod, args),
        .exp => bin(u256_ops.exp, args),
        .signextend => bin(u256_ops.signextend, args),
        // Arithmetic (3 args → 1 result)
        .addmod => .{ .single = u256_ops.addmod(args[0], args[1], args[2]) },
        .mulmod => .{ .single = u256_ops.mulmod(args[0], args[1], args[2]) },
        // Comparison
        .lt => bin(u256_ops.lt, args),
        .gt => bin(u256_ops.gt, args),
        .slt => bin(u256_ops.slt, args),
        .sgt => bin(u256_ops.sgt, args),
        .eq => bin(u256_ops.eq, args),
        .iszero => .{ .single = u256_ops.iszero(args[0]) },
        // Bitwise
        .not_ => .{ .single = u256_ops.not(args[0]) },
        .and_ => bin(u256_ops.and_, args),
        .or_ => bin(u256_ops.or_, args),
        .xor => bin(u256_ops.xor, args),
        .shl => bin(u256_ops.shl, args),
        .shr => bin(u256_ops.shr, args),
        .sar => bin(u256_ops.sar, args),
        .byte_ => bin(u256_ops.byte_, args),
        // Storage
        .sstore => {
            if (interp.global.is_static) return staticViolation(interp);
            try interp.global.sstore(args[0], args[1]);
            return .none;
        },
        .sload => .{ .single = interp.global.sload(args[0]) },
        .tstore => {
            if (interp.global.is_static) return staticViolation(interp);
            try interp.global.tstore(args[0], args[1]);
            return .none;
        },
        .tload => .{ .single = interp.global.tload(args[0]) },
        // Memory
        .mstore => {
            if (try interp.global.accessMemory(args[0], 32)) {
                try interp.global.memStore(args[0], args[1]);
            }
            traceBuiltin(interp, .mstore, "MSTORE", args, &.{}, true);
            return .none;
        },
        .mstore8 => {
            if (try interp.global.accessMemory(args[0], 1)) {
                try interp.global.memStore8(args[0], args[1]);
            }
            traceBuiltin(interp, .mstore8, "MSTORE8", args, &.{}, true);
            return .none;
        },
        .mload => blk: {
            // Lax mode: if accessMemory rejects, return a deterministic 0.
            if (try interp.global.accessMemory(args[0], 32)) {
                break :blk .{ .single = try interp.global.memLoad(args[0]) };
            }
            break :blk .{ .single = 0 };
        },
        .msize => .{ .single = interp.global.getMsize() },
        // Logging
        .log0, .log1, .log2, .log3, .log4 => {
            if (interp.global.is_static) return staticViolation(interp);
            const num_topics: usize = @intFromEnum(tag) - @intFromEnum(BuiltinTag.log0);
            const offset = args[0];
            const len = args[1];
            const log_names = [_][]const u8{ "LOG0", "LOG1", "LOG2", "LOG3", "LOG4" };
            if (try interp.global.accessMemory(offset, len)) {
                const size: usize = @intCast(len);
                const data = try interp.allocator.alloc(u8, size);
                defer interp.allocator.free(data);
                interp.global.memRead(offset, data);
                // addLog records the entry and emits the trace internally,
                // but we want the solc-compat trace-pointer rewrite. Emit
                // the trace via traceBuiltin and append the entry without
                // re-tracing.
                traceBuiltin(interp, tag, log_names[num_topics], args, data, false);
                try interp.global.appendLogEntry(data, args[2..][0..num_topics]);
            } else {
                // Lax mode: trace without recording the log entry.
                traceBuiltin(interp, tag, log_names[num_topics], args, &.{}, false);
            }
            return .none;
        },
        // Memory copy
        .mcopy => {
            // mcopy reads `args[2]` bytes from src and writes them to dst —
            // both ranges must pass accessMemory.
            const dst = args[0];
            const src = args[1];
            const len = args[2];
            const dst_ok = try interp.global.accessMemory(dst, len);
            const src_ok = try interp.global.accessMemory(src, len);
            if (dst_ok and src_ok) {
                try interp.global.memCopy(dst, src, len);
            }
            traceBuiltin(interp, .mcopy, "MCOPY", args, &.{}, true);
            return .none;
        },
        // Call data & return data
        .calldataload => blk: {
            const offset = args[0];
            var buf: [32]u8 = std.mem.zeroes([32]u8);
            if (offset < interp.global.calldata.len) {
                const start: usize = @intCast(offset);
                const avail = @min(32, interp.global.calldata.len - start);
                @memcpy(buf[0..avail], interp.global.calldata[start..][0..avail]);
            }
            break :blk .{ .single = std.mem.readInt(u256, &buf, .big) };
        },
        .calldatasize => .{ .single = @intCast(interp.global.calldata.len) },
        .calldatacopy => {
            if (try interp.global.accessMemory(args[0], args[2])) {
                try copyToMemoryPadded(interp, args[0], args[1], args[2], interp.global.calldata);
            }
            traceBuiltin(interp, .calldatacopy, "CALLDATACOPY", args, &.{}, true);
            return .none;
        },
        .returndatasize => .{ .single = @intCast(interp.global.return_data.len) },
        .returndatacopy => {
            // EIP-211 returndata bounds check fires *before* memory access
            // and produces a hard revert in real EVM (consume all gas).
            // That's a returndata-bounds concern, distinct from memory
            // expansion — it remains in strict and lax modes alike.
            const dest_off = args[0];
            const src_off = args[1];
            const len = args[2];
            if (len > 0) {
                const rdata_len: u256 = @intCast(interp.global.return_data.len);
                const end = src_off +% len;
                if (end < src_off or end > rdata_len) {
                    interp.global.resetReturnData();
                    interp.halt_reason = .reverted;
                    return error.ExecutionHalt;
                }
            }
            if (try interp.global.accessMemory(dest_off, len)) {
                if (len > 0) {
                    const start: usize = @intCast(src_off);
                    const n: usize = @intCast(len);
                    try interp.global.memWrite(dest_off, interp.global.return_data[start..][0..n]);
                }
            }
            traceBuiltin(interp, .returndatacopy, "RETURNDATACOPY", args, &.{}, true);
            return .none;
        },
        .codecopy => {
            if (try interp.global.accessMemory(args[0], args[2])) {
                // Constructor frames see a synthetic blob of
                // `sentinel || ctor_args` so that the standard solc
                // pattern `codecopy(dst, sub(codesize(), n), n)` reads
                // the constructor args back out.
                const src_buf = interp.global.synthetic_init_blob orelse interp.global.code;
                try copyToMemoryPadded(interp, args[0], args[1], args[2], src_buf);
            }
            traceBuiltin(interp, .codecopy, "CODECOPY", args, &.{}, true);
            return .none;
        },
        .extcodecopy => {
            if (try interp.global.accessMemory(args[1], args[3])) {
                try extCodeCopy(interp, args[0], args[1], args[2], args[3]);
            }
            traceBuiltin(interp, .extcodecopy, "EXTCODECOPY", args, &.{}, true);
            return .none;
        },
        // Context getters
        .address => .{ .single = interp.global.getAddress() },
        .balance => .{ .single = balanceOf(interp, args[0]) },
        .origin => .{ .single = interp.global.getOrigin() },
        .caller => .{ .single = interp.global.getCaller() },
        .callvalue => .{ .single = interp.global.callvalue },
        .gasprice => .{ .single = interp.global.gasprice },
        .coinbase => .{ .single = interp.global.getCoinbase() },
        .timestamp => .{ .single = interp.global.timestamp },
        .number => .{ .single = interp.global.block_number },
        .prevrandao => .{ .single = interp.global.prevrandao },
        .gaslimit => .{ .single = interp.global.gaslimit },
        .chainid => .{ .single = interp.global.chainid },
        .selfbalance => .{ .single = balanceOf(interp, interp.global.getAddress()) },
        .basefee => .{ .single = interp.global.basefee },
        .blobhash => .{ .single = if (interp.global.world) |w| w.blobHash(args[0]) else 0 },
        .blobbasefee => .{ .single = interp.global.blobbasefee },
        .gas => .{ .single = @as(u256, 1) << 64 },
        .codesize => blk: {
            // Constructor frames see `sentinel || ctor_args` length so
            // that solc's `sub(codesize(), n)` ctor-args trick works.
            if (interp.global.synthetic_init_blob) |b| break :blk .{ .single = @intCast(b.len) };
            break :blk .{ .single = @intCast(interp.global.code.len) };
        },
        .pc => .{ .single = 0 },
        // Hash & crypto
        .keccak256 => blk: {
            const offset = args[0];
            const len = args[1];
            var result: u256 = undefined;
            if (try interp.global.accessMemory(offset, len)) {
                var hash: [32]u8 = undefined;
                try interp.global.keccak256Range(offset, len, &hash);
                result = std.mem.readInt(u256, &hash, .big);
            } else {
                // Lax mode: deterministic synthetic value (matches solc).
                result = @as(u256, 0x1234cafe1234cafe1234cafe) +% offset;
            }
            // KECCAK256 is not in the trace_ptr_rewrite table; keep the
            // direct logTrace call.
            interp.global.logTrace("KECCAK256", args, &.{}, false) catch {};
            break :blk .{ .single = result };
        },
        .blockhash => .{
            .single = if (interp.global.world) |w| w.blockHash(args[0]) else 0,
        },
        // Arithmetic
        .clz => .{ .single = u256_ops.clz_(args[0]) },
        // Control flow halts
        .stop => {
            interp.halt_reason = .stopped;
            return error.ExecutionHalt;
        },
        .return_ => {
            try captureHaltData(interp, args[0], args[1]);
            traceBuiltin(interp, .return_, "RETURN", args, interp.global.return_data, false);
            interp.halt_reason = .returned;
            return error.ExecutionHalt;
        },
        .revert => {
            try captureHaltData(interp, args[0], args[1]);
            traceBuiltin(interp, .revert, "REVERT", args, interp.global.return_data, false);
            interp.halt_reason = .reverted;
            return error.ExecutionHalt;
        },
        .invalid => {
            // Real EVM: INVALID consumes all gas and reverts state. It
            // does NOT preserve return data (REVERT does, because REVERT
            // carries an explicit revert reason). Clearing matches the
            // spec; log rollback is handled at the interpret() catch.
            //
            // Under --solc-compat, we additionally truncate logs and
            // (above) reset return data here so that any execution
            // path through INVALID looks identical observable-wise.
            // Outside compat mode, log rollback runs in the interpret
            // catch (matching real EVM rollback semantics).
            interp.global.resetReturnData();
            if (interp.global.solc_compat) {
                interp.global.truncateLogEntries(0);
            }
            interp.halt_reason = .invalid_;
            return error.ExecutionHalt;
        },
        // Contract interaction: real implementation routes through
        // `Chain` and spawns a child interpreter against the callee's
        // installed `ObjectTree`. Calls into accounts with no code
        // succeed silently (matching real EVM behavior for EOAs).
        .call => return try evalContractCall(interp, .call, args),
        .callcode => return try evalContractCall(interp, .callcode, args),
        .delegatecall => return try evalContractCall(interp, .delegatecall, args),
        .staticcall => return try evalContractCall(interp, .staticcall, args),
        .create => return try evalContractCreate(interp, .create, args),
        .create2 => return try evalContractCreate(interp, .create2, args),
        .extcodesize => .{
            .single = if (interp.global.world) |w| w.extCodeSize(u256_ops.maskAddress(args[0])) else 0,
        },
        .extcodehash => .{
            .single = if (interp.global.world) |w| w.extCodeHash(u256_ops.maskAddress(args[0])) else 0,
        },
        .selfdestruct => {
            if (interp.global.is_static) return staticViolation(interp);
            // Per EVM, SELFDESTRUCT halts execution. Argument is the
            // beneficiary address (we don't track balance transfers, but
            // record nothing else either — just halt).
            //
            // Under --solc-compat, also truncate logs to mirror solc's
            // "any path through SELFDESTRUCT looks identical" property.
            // Outside compat mode, the halt reason is .stopped, so logs
            // and return data persist (matching real EVM, which counts
            // SELFDESTRUCT as a clean halt for the executing frame).
            interp.global.logTrace("SELFDESTRUCT", &.{u256_ops.maskAddress(args[0])}, &.{}, false) catch {};
            interp.global.resetReturnData();
            if (interp.global.solc_compat) {
                interp.global.truncateLogEntries(0);
            }
            interp.halt_reason = .stopped;
            return error.ExecutionHalt;
        },
        // Misc
        .pop => .none,
        // Solidity pseudo-builtin: `memoryguard(size)` in the EVM dialect
        // is a compiler annotation that lowers to `PUSH size`. At runtime
        // it's the identity function.
        .memoryguard => .{ .single = args[0] },

        // ── Object-access pseudo-builtins ────────────────────────────
        // These look up a sub-object by literal-string name. Missing
        // entries return zero (the same default behavior as a fixture
        // that doesn't bother to register a sub-object).
        .datasize => try evalDataSize(interp, arg_nodes[0]),
        .dataoffset => try evalDataOffset(interp, arg_nodes[0]),
        .datacopy => blk: {
            const dst = args[0];
            const src = args[1];
            const len = args[2];
            // Sentinel-aware path: if `src` is a known sentinel in the
            // chain, write the 8-byte BE sentinel into memory and
            // zero-pad. CREATE will read it back and look up the
            // sub-object to instantiate.
            if (interp.global.chain.lookupSentinel(@as(u64, @truncate(src))) != null) {
                if (try interp.global.accessMemory(dst, len)) {
                    var sentinel_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &sentinel_bytes, @as(u64, @truncate(src)), .big);
                    const write_len = @min(len, SENTINEL_BYTES);
                    if (write_len > 0) {
                        try interp.global.memWrite(dst, sentinel_bytes[0..@intCast(write_len)]);
                    }
                    if (len > write_len) {
                        try interp.global.memZeroRange(dst +% write_len, len - write_len);
                    }
                }
                traceBuiltin(interp, .datacopy, "DATACOPY", args, &.{}, true);
                break :blk .none;
            }
            // Legacy: alias of codecopy.
            if (try interp.global.accessMemory(dst, len)) {
                try copyToMemoryPadded(interp, dst, src, len, interp.global.code);
            }
            traceBuiltin(interp, .datacopy, "DATACOPY", args, &.{}, true);
            break :blk .none;
        },
        .setimmutable => blk: {
            try evalSetImmutable(interp, arg_nodes, args);
            break :blk .none;
        },
        .loadimmutable => try evalLoadImmutable(interp, arg_nodes[0]),
        .linkersymbol => try evalLinkerSymbol(interp, arg_nodes[0]),
    };
}

// ── Builtin helpers ─────────────────────────────────────────────────

/// Bounds-checked balance lookup. Masks the address to 160 bits and
/// delegates to the optional WorldState.
fn balanceOf(interp: *Interpreter, addr: u256) u256 {
    const masked = u256_ops.maskAddress(addr);
    if (interp.global.world) |w| return w.balance(masked);
    return 0;
}

/// Bulk copy from a host-supplied byte slice into memory, zero-filling
/// the tail past `src.len`. Used by calldatacopy / codecopy / datacopy.
/// Caller is responsible for `accessMemory` — this helper assumes the
/// destination range has already been validated.
fn copyToMemoryPadded(interp: *Interpreter, dest_off: u256, src_off: u256, len: u256, src: []const u8) InterpreterError!void {
    if (len == 0) return;

    var data_len: u256 = 0;
    if (src_off < src.len) {
        const remaining: usize = src.len - @as(usize, @intCast(src_off));
        data_len = @min(len, @as(u256, remaining));
    }

    if (data_len > 0) {
        const start: usize = @intCast(src_off);
        const n: usize = @intCast(data_len);
        try interp.global.memWrite(dest_off, src[start..][0..n]);
    }

    if (data_len < len) {
        const zero_off = dest_off +% data_len;
        const zero_len = len - data_len;
        try interp.global.memZeroRange(zero_off, zero_len);
    }
}

/// extcodecopy(addr, dst, src, len). Uses WorldState if available; else
/// zero-fills the destination range. Caller is responsible for
/// `accessMemory` on the destination range.
fn extCodeCopy(interp: *Interpreter, addr: u256, dest_off: u256, src_off: u256, len: u256) InterpreterError!void {
    if (len == 0) return;
    const n: usize = @intCast(len);
    if (interp.global.world) |w| {
        const buf = try interp.allocator.alloc(u8, n);
        defer interp.allocator.free(buf);
        w.extCodeCopy(u256_ops.maskAddress(addr), buf, src_off);
        try interp.global.memWrite(dest_off, buf);
    } else {
        try interp.global.memZeroRange(dest_off, len);
    }
}

/// Encoded length of a sentinel inside an init blob: 8 BE bytes.
const SENTINEL_BYTES: u256 = 8;

fn evalDataSize(interp: *Interpreter, name_node: AST.NodeIndex) InterpreterError!Values {
    const lit = try literalString(interp, name_node);
    defer if (lit.owned) interp.allocator.free(lit.text);

    // Tree-mode lookup against the currently executing object.
    if (interp.global.current_object) |obj| {
        // Self-reference: solc constructors compute ctor-arg size as
        // `sub(codesize(), datasize(<own_name>))`. Under our synthetic
        // init-blob model, the "program" portion is exactly the
        // sentinel header (`SENTINEL_BYTES`); everything past it is
        // ctor args.
        if (std.mem.eql(u8, obj.name, lit.text)) {
            return .{ .single = SENTINEL_BYTES };
        }
        // Child sub-objects report `SENTINEL_BYTES` so the standard
        // `datacopy(dst, dataoffset(child), datasize(child))` writes
        // exactly the 8-byte sentinel.
        if (obj.findChild(lit.text)) |_| {
            return .{ .single = SENTINEL_BYTES };
        }
        if (obj.data.get(lit.text)) |bytes| {
            return .{ .single = @intCast(bytes.len) };
        }
    }

    // Legacy bare-block path.
    const sub = interp.global.sub_objects.get(lit.text);
    return .{ .single = if (sub) |o| o.size else 0 };
}

fn evalDataOffset(interp: *Interpreter, name_node: AST.NodeIndex) InterpreterError!Values {
    const lit = try literalString(interp, name_node);
    defer if (lit.owned) interp.allocator.free(lit.text);

    // Tree-mode: self-name returns offset 0 (start of synthetic blob);
    // child object → return its sentinel as a u256; data section → 0.
    if (interp.global.current_object) |obj| {
        if (std.mem.eql(u8, obj.name, lit.text)) {
            return .{ .single = 0 };
        }
        if (obj.findChild(lit.text)) |child| {
            return .{ .single = @as(u256, child.sentinel) };
        }
        if (obj.data.get(lit.text)) |_| {
            return .{ .single = 0 };
        }
    }

    const sub = interp.global.sub_objects.get(lit.text);
    return .{ .single = if (sub) |o| o.offset else 0 };
}

fn evalSetImmutable(interp: *Interpreter, arg_nodes: []const AST.NodeIndex, args: []const u256) InterpreterError!void {
    // setimmutable(memOffset, "name", value) — args[0] / args[2] are
    // evaluated, the literal name is in arg_nodes[1]. The chain owns
    // its own copy of the key, so we don't allocate one ourselves.
    const lit = try literalString(interp, arg_nodes[1]);
    defer if (lit.owned) interp.allocator.free(lit.text);
    try interp.global.chain.setImmutable(
        interp.global.currentAccountAddress(),
        lit.text,
        args[2],
    );
    _ = args[0]; // ignored — we don't model code-section writes
}

fn evalLoadImmutable(interp: *Interpreter, name_node: AST.NodeIndex) InterpreterError!Values {
    const lit = try literalString(interp, name_node);
    defer if (lit.owned) interp.allocator.free(lit.text);
    const value = interp.global.chain.loadImmutable(
        interp.global.currentAccountAddress(),
        lit.text,
    );
    return .{ .single = value };
}

fn evalLinkerSymbol(interp: *Interpreter, name_node: AST.NodeIndex) InterpreterError!Values {
    const lit = try literalString(interp, name_node);
    defer if (lit.owned) interp.allocator.free(lit.text);
    const value = interp.global.chain.linker_symbols.get(lit.text) orelse 0;
    return .{ .single = value };
}

// ── Contract call family ────────────────────────────────────────────

/// Static-frame state-mutation violation. Sets the halt reason to
/// `.reverted` and returns `error.ExecutionHalt` so the parent frame
/// (which spawned this static frame) sees a clean revert.
fn staticViolation(interp: *Interpreter) InterpreterError!Values {
    interp.global.resetReturnData();
    interp.halt_reason = .reverted;
    return error.ExecutionHalt;
}

const CallKind = enum { call, callcode, delegatecall, staticcall };

/// Real implementation of `call` / `callcode` / `delegatecall` /
/// `staticcall`. Builds a child `GlobalState` against the callee's
/// installed code, spawns a child interpreter, captures returndata,
/// and rolls back the chain journal on revert.
///
/// Argument layout (matches EVM ordering):
///   call/callcode:    gas, addr, value, in_off, in_len, out_off, out_len
///   delegatecall:     gas, addr,        in_off, in_len, out_off, out_len
///   staticcall:       gas, addr,        in_off, in_len, out_off, out_len
fn evalContractCall(
    interp: *Interpreter,
    kind: CallKind,
    args: []const u256,
) InterpreterError!Values {
    const callee_addr_u256 = args[1];
    const value: u256 = if (kind == .call or kind == .callcode) args[2] else 0;
    const arg_base: usize = if (kind == .call or kind == .callcode) 3 else 2;
    const in_off = args[arg_base];
    const in_len = args[arg_base + 1];
    const out_off = args[arg_base + 2];
    const out_len = args[arg_base + 3];

    // Per EVM: every CALL clears return_data on entry. Even a call that
    // immediately reverts leaves the parent's return_data empty (or
    // populated with the child's revert reason — see below).
    interp.global.resetReturnData();

    // Static-frame guard: a static frame cannot send value via CALL.
    // STATICCALL itself is fine (it forces is_static on the child).
    // CALLCODE / DELEGATECALL are not gated on value because they don't
    // perform a value transfer in the new frame.
    if (interp.global.is_static and kind == .call and value != 0) {
        return .{ .single = 0 };
    }

    if (interp.global.frame_depth +% 1 > MAX_FRAME_DEPTH) {
        return .{ .single = 0 };
    }

    const op_name: []const u8 = switch (kind) {
        .call => "CALL",
        .callcode => "CALLCODE",
        .delegatecall => "DELEGATECALL",
        .staticcall => "STATICCALL",
    };
    interp.global.logTrace(op_name, args, &.{}, false) catch {};

    const callee_addr = GlobalState.addressFromU256(callee_addr_u256);

    // Read input bytes from the parent's memory into a fresh buffer.
    // The buffer is owned by this stack frame and freed on return.
    var input: []u8 = &.{};
    if (in_len > 0) {
        if (try interp.global.accessMemory(in_off, in_len)) {
            const n: usize = @intCast(in_len);
            input = try interp.allocator.alloc(u8, n);
            interp.global.memRead(in_off, input);
        }
    }
    defer if (input.len > 0) interp.allocator.free(input);

    // Take a chain snapshot covering value transfer + child execution.
    const cp = interp.global.chain.snapshot(interp.global.log_entries.items.len);

    // Value transfer (call only).
    if (kind == .call and value != 0) {
        const sender_addr = interp.global.currentAccountAddress();
        const sender_acc = interp.global.chain.getAccount(sender_addr);
        const sender_bal: u256 = if (sender_acc) |a| a.balance else 0;
        if (sender_bal < value) {
            interp.global.chain.revertTo(cp);
            return .{ .single = 0 };
        }
        try interp.global.chain.setBalance(sender_addr, sender_bal - value);
        const receiver = try interp.global.chain.getOrCreateAccount(callee_addr);
        try interp.global.chain.setBalance(callee_addr, receiver.balance + value);
    }

    // Look up the callee. Missing accounts and EOAs (no installed code)
    // succeed silently with empty returndata — matching real EVM
    // behavior for calls to non-contract addresses.
    const callee_acc = interp.global.chain.getAccount(callee_addr);
    const callee_has_code = callee_acc != null and callee_acc.?.code != null and callee_acc.?.code_ast != null;
    if (!callee_has_code) {
        interp.global.chain.commitTo(cp);
        return .{ .single = 1 };
    }

    // Frame address: callee for call/staticcall/callcode (storage namespace
    // is the callee's), caller for delegatecall (executes callee code in
    // caller's storage namespace).
    const child_addr_u256: u256 = switch (kind) {
        .call, .staticcall, .callcode => callee_addr_u256,
        .delegatecall => interp.global.address,
    };
    const child_caller: u256 = switch (kind) {
        .delegatecall => interp.global.caller,
        .call, .callcode, .staticcall => interp.global.address,
    };
    const child_callvalue: u256 = switch (kind) {
        .call, .callcode => value,
        .delegatecall => interp.global.callvalue,
        .staticcall => 0,
    };

    var child_global = GlobalState.initForFrame(
        interp.allocator,
        interp.global.chain,
        child_addr_u256,
    );
    defer child_global.deinit();

    child_global.calldata = input;
    child_global.caller = child_caller;
    child_global.callvalue = child_callvalue;
    child_global.origin = interp.global.origin;
    child_global.gasprice = interp.global.gasprice;
    child_global.block_number = interp.global.block_number;
    child_global.timestamp = interp.global.timestamp;
    child_global.coinbase = interp.global.coinbase;
    child_global.gaslimit = interp.global.gaslimit;
    child_global.chainid = interp.global.chainid;
    child_global.basefee = interp.global.basefee;
    child_global.prevrandao = interp.global.prevrandao;
    child_global.blobbasefee = interp.global.blobbasefee;
    child_global.is_static = interp.global.is_static or (kind == .staticcall);
    child_global.frame_depth = interp.global.frame_depth + 1;
    // Inherit the *callee's* object context so that dataoffset /
    // datasize / loadimmutable inside the runtime resolve against the
    // runtime sub-object's siblings and immutables namespace.
    child_global.current_object = callee_acc.?.code;
    child_global.tracer = interp.global.tracer;
    child_global.disable_mem_write_trace = interp.global.disable_mem_write_trace;
    child_global.memory_policy = interp.global.memory_policy;
    child_global.solc_compat = interp.global.solc_compat;

    var child_local = LocalState.init(interp.allocator, null);
    defer child_local.deinit();

    // Pointer to the AST view embedded in the callee's account. Stable
    // because `AST` is by-value POD-ish (it holds slices owned by the
    // ObjectTreeRoot in `Chain.trees`, which outlives the call).
    const callee_ast: *const AST = &callee_acc.?.code_ast.?;
    const code_root_idx = callee_acc.?.code.?.code_root;

    var child_interp = Interpreter.init(interp.allocator, callee_ast, &child_global, &child_local);
    child_interp.max_steps = interp.max_steps;

    const child_result = child_interp.runFrame(code_root_idx) catch |err| {
        // Hard error from the child — roll back any frame mutations.
        interp.global.chain.revertTo(cp);
        return err;
    };

    const success = switch (child_result.halt_reason orelse .stopped) {
        .stopped, .returned => true,
        .reverted, .invalid_ => false,
    };

    // Capture child returndata into the parent BEFORE the child's
    // GlobalState is freed by the defer above. Both success and
    // revert paths take the same dupe — `invalid_` clears it via
    // `resetReturnData` already, so dupe of an empty slice is a no-op.
    if (child_global.return_data.len > 0) {
        const copy = try interp.allocator.dupe(u8, child_global.return_data);
        interp.global.return_data = copy;
        interp.global.return_data_owned = true;
    }
    if (out_len > 0) {
        if (try interp.global.accessMemory(out_off, out_len)) {
            try copyToMemoryPadded(interp, out_off, 0, out_len, interp.global.return_data);
        }
    }

    if (!success) {
        interp.global.chain.revertTo(cp);
        return .{ .single = 0 };
    }

    // Success: merge child logs into parent (move ownership), then
    // commit the journal so storage / balance / nonce changes persist.
    for (child_global.log_entries.items) |entry| {
        try interp.global.log_entries.append(interp.allocator, entry);
    }
    child_global.log_entries.shrinkRetainingCapacity(0);

    interp.global.chain.commitTo(cp);
    return .{ .single = 1 };
}

const CreateKind = enum { create, create2 };

/// Real implementation of `create` / `create2`. Reads the init blob
/// from memory, recovers the constructor `ObjectTree` from a sentinel
/// embedded in the first 8 bytes, runs the constructor against a fresh
/// account at the derived address, and installs the runtime sub-object
/// (resolved by sentinel from the constructor's return_data) as the
/// account's code.
///
/// Argument layout:
///   create:  value, in_off, in_len           (3 args)
///   create2: value, in_off, in_len, salt     (4 args)
fn evalContractCreate(
    interp: *Interpreter,
    kind: CreateKind,
    args: []const u256,
) InterpreterError!Values {
    const value = args[0];
    const in_off = args[1];
    const in_len = args[2];
    const salt: u256 = if (kind == .create2) args[3] else 0;

    interp.global.resetReturnData();

    if (interp.global.is_static) return staticViolation(interp);
    if (interp.global.frame_depth +% 1 > MAX_FRAME_DEPTH) {
        return .{ .single = 0 };
    }

    interp.global.logTrace(if (kind == .create) "CREATE" else "CREATE2", args, &.{}, false) catch {};

    // Read the init blob into a fresh, owned buffer.
    var init_blob: []u8 = &.{};
    if (in_len > 0) {
        if (try interp.global.accessMemory(in_off, in_len)) {
            const n: usize = @intCast(in_len);
            init_blob = try interp.allocator.alloc(u8, n);
            interp.global.memRead(in_off, init_blob);
        }
    }
    defer if (init_blob.len > 0) interp.allocator.free(init_blob);

    // Need at least 8 bytes for the sentinel. Below that, we have no
    // way to look up which object to instantiate — return failure.
    if (init_blob.len < 8) return .{ .single = 0 };

    const sentinel = std.mem.readInt(u64, init_blob[0..8], .big);
    const entry = interp.global.chain.lookupSentinel(sentinel) orelse return .{ .single = 0 };
    const ctor_tree = entry.tree;
    if (ctor_tree.code_root == AST.null_node) return .{ .single = 0 };

    // Reject creating a tree that has no children — there's nothing
    // to install as runtime code afterward.
    if (ctor_tree.children.len == 0) return .{ .single = 0 };

    const ctor_args = init_blob[8..];

    // Snapshot for revert: covers nonce bump, account creation, value
    // transfer, and constructor execution.
    const cp = interp.global.chain.snapshot(interp.global.log_entries.items.len);

    const sender_addr = interp.global.currentAccountAddress();
    const sender_acc_ptr = try interp.global.chain.getOrCreateAccount(sender_addr);
    const sender_nonce = sender_acc_ptr.nonce;
    const sender_bal = sender_acc_ptr.balance;
    if (sender_bal < value) {
        // Match EVM: insufficient balance → CREATE returns 0, no
        // observable state change beyond what's already journaled.
        interp.global.chain.revertTo(cp);
        return .{ .single = 0 };
    }

    // Derive the new address. The RLP encoder used by deriveCreate
    // can fail on inputs we never produce (RLP-too-long); treat those
    // as a CREATE failure rather than propagating an unrelated error.
    const new_addr: GlobalState.Address = switch (kind) {
        .create => @import("Chain.zig").deriveCreateAddress(
            interp.allocator,
            sender_addr,
            sender_nonce,
        ) catch {
            interp.global.chain.revertTo(cp);
            return .{ .single = 0 };
        },
        .create2 => @import("Chain.zig").deriveCreate2Address(
            sender_addr,
            salt,
            init_blob,
        ),
    };

    // Bump sender nonce, transfer value to new account.
    try interp.global.chain.bumpNonce(sender_addr);
    if (value != 0) {
        try interp.global.chain.setBalance(sender_addr, sender_bal - value);
    }
    const new_acc = try interp.global.chain.getOrCreateAccount(new_addr);
    if (value != 0) {
        try interp.global.chain.setBalance(new_addr, new_acc.balance + value);
    }

    // Build the synthetic init blob: sentinel(8 BE) || ctor_args. The
    // sentinel pads codesize() so `sub(codesize(), n)` lands at the
    // start of ctor_args (the standard solc constructor-args trick).
    const synth = try interp.allocator.alloc(u8, 8 + ctor_args.len);
    errdefer interp.allocator.free(synth);
    std.mem.writeInt(u64, synth[0..8], sentinel, .big);
    @memcpy(synth[8..], ctor_args);

    // Construct the constructor frame against the constructor object's
    // AST view. The AST is borrowed from `entry.root`, which lives in
    // chain.trees.
    const ctor_ast_view = entry.root.asAst();

    var child_global = GlobalState.initForFrame(
        interp.allocator,
        interp.global.chain,
        GlobalState.addressToU256(new_addr),
    );
    defer child_global.deinit();

    // Hand ownership of `synth` to the child frame; its deinit frees it.
    child_global.synthetic_init_blob = synth;

    child_global.calldata = &.{}; // constructors have no calldata
    child_global.caller = interp.global.address;
    child_global.callvalue = value;
    child_global.origin = interp.global.origin;
    child_global.gasprice = interp.global.gasprice;
    child_global.block_number = interp.global.block_number;
    child_global.timestamp = interp.global.timestamp;
    child_global.coinbase = interp.global.coinbase;
    child_global.gaslimit = interp.global.gaslimit;
    child_global.chainid = interp.global.chainid;
    child_global.basefee = interp.global.basefee;
    child_global.prevrandao = interp.global.prevrandao;
    child_global.blobbasefee = interp.global.blobbasefee;
    child_global.is_static = false; // constructors are never static
    child_global.frame_depth = interp.global.frame_depth + 1;
    child_global.current_object = ctor_tree;
    child_global.tracer = interp.global.tracer;
    child_global.disable_mem_write_trace = interp.global.disable_mem_write_trace;
    child_global.memory_policy = interp.global.memory_policy;
    child_global.solc_compat = interp.global.solc_compat;

    var child_local = LocalState.init(interp.allocator, null);
    defer child_local.deinit();

    var child_interp = Interpreter.init(interp.allocator, &ctor_ast_view, &child_global, &child_local);
    child_interp.max_steps = interp.max_steps;

    // Cast away const for the AST pointer — Interpreter.init takes
    // *const AST, but our local `ctor_ast_view` is on the stack.
    const ctor_root_idx = ctor_tree.code_root;
    const child_result = child_interp.runFrame(ctor_root_idx) catch |err| {
        interp.global.chain.revertTo(cp);
        return err;
    };

    const reason = child_result.halt_reason orelse .stopped;
    const ok = (reason == .stopped or reason == .returned);

    if (!ok) {
        // Revert: capture revert reason as parent's return_data, drop
        // all journaled state.
        if (child_global.return_data.len > 0) {
            const copy = try interp.allocator.dupe(u8, child_global.return_data);
            interp.global.return_data = copy;
            interp.global.return_data_owned = true;
        }
        interp.global.chain.revertTo(cp);
        return .{ .single = 0 };
    }

    // Constructor succeeded. Decode the runtime sentinel from
    // return_data — solc's pattern is `datacopy(p, dataoffset("X_dep"),
    // datasize("X_dep")); return(p, datasize("X_dep"))`, so the first
    // 8 bytes of return_data are the sentinel for the runtime
    // sub-object to install.
    var runtime_sentinel: u64 = 0;
    if (child_global.return_data.len >= 8) {
        runtime_sentinel = std.mem.readInt(u64, child_global.return_data[0..8], .big);
    }
    const runtime_entry = interp.global.chain.lookupSentinel(runtime_sentinel);
    var runtime_tree: ?*const ObjectTreeFromMod = null;
    if (runtime_entry) |re| {
        // Verify the runtime sentinel actually points to a child of
        // this constructor (defends against the constructor returning
        // a sentinel from a totally unrelated tree).
        for (ctor_tree.children) |*child| {
            if (child.sentinel == runtime_sentinel) {
                runtime_tree = child;
                break;
            }
        }
        _ = re;
    }
    if (runtime_tree == null) {
        // Fallback for solc-style "return the first child unconditionally":
        // pick the first child whose name ends with "_deployed", else
        // children[0].
        var picked: *const ObjectTreeFromMod = &ctor_tree.children[0];
        for (ctor_tree.children) |*child| {
            if (std.mem.endsWith(u8, child.name, "_deployed")) {
                picked = child;
                break;
            }
        }
        runtime_tree = picked;
    }

    // Install runtime code at the new address. The AST view borrows
    // the same shared pool as `entry.root` (sub-objects share their
    // root's pool), so it's safe to attach the same view here.
    try interp.global.chain.setCode(new_addr, runtime_tree, ctor_ast_view);

    // Merge child logs into parent and commit.
    for (child_global.log_entries.items) |entry_| {
        try interp.global.log_entries.append(interp.allocator, entry_);
    }
    child_global.log_entries.shrinkRetainingCapacity(0);

    interp.global.chain.commitTo(cp);

    // Return the new address as a u256.
    return .{ .single = GlobalState.addressToU256(new_addr) };
}

// Local alias to keep the type referenced consistently in helpers.
const ObjectTreeFromMod = @import("ObjectTree.zig").ObjectTree;

fn captureHaltData(interp: *Interpreter, offset: u256, len: u256) InterpreterError!void {
    interp.global.resetReturnData();
    if (len == 0) return;
    if (!try interp.global.accessMemory(offset, len)) {
        // Lax mode: oversized return/revert data is silently dropped
        // (return_data stays empty after the resetReturnData above).
        return;
    }
    const size: usize = @intCast(len);
    const buf = try interp.allocator.alloc(u8, size);
    errdefer interp.allocator.free(buf);
    interp.global.memRead(offset, buf);
    interp.global.return_data = buf;
    interp.global.return_data_owned = true;
}

fn bin(comptime op: fn (u256, u256) u256, args: []const u256) Values {
    return .{ .single = op(args[0], args[1]) };
}

/// Emit a one-line warning to the tracer that a stubbed builtin was hit
/// and return zero. Trace write errors are suppressed since they should
/// not derail program execution.
fn stub(interp: *Interpreter, name: []const u8) u256 {
    if (interp.global.tracer) |w| {
        w.print("WARN: {s} is a stub returning 0\n", .{name}) catch {};
    }
    return 0;
}
