const std = @import("std");
const gyul = @import("gyul");

const DEFAULT_SENDER: gyul.GlobalState.Address = .{ 0xde, 0xad, 0xbe, 0xef } ++ [_]u8{0} ** 16;

const Options = struct {
    filename: ?[]const u8 = null,
    calldata_hex: ?[]const u8 = null,
    ctor_args_hex: ?[]const u8 = null,
    from_hex: ?[]const u8 = null,
    value: u256 = 0,
    trace: bool = true,
    solc_compat: bool = false,
    /// Multiple sequential calls to make against the deployed contract
    /// after the constructor runs. Each entry is a hex string. Used by
    /// the differential test runner — each call output goes on its own
    /// line for easy parsing.
    calls: std.ArrayListUnmanaged([]const u8) = .{},
    quiet: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) std.debug.print("memory leaks detected\n", .{});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = parseArgs(allocator, args) catch |err| {
        std.debug.print("Argument error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer opts.calls.deinit(allocator);
    if (opts.filename == null) {
        printUsage();
        std.process.exit(1);
    }

    const contents = try std.fs.cwd().readFileAllocOptions(allocator, opts.filename.?, 1e8, null, .@"1", 0);
    defer allocator.free(contents);

    var parse_result = gyul.AST.parseAny(allocator, contents) catch |err| {
        const off = gyul.AST.last_parse_error_offset;
        var line: u32 = 1;
        var col: u32 = 1;
        for (contents[0..@min(off, contents.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        std.debug.print("{s}:{d}:{d}: parse error: {s}\n", .{
            opts.filename.?, line, col, @errorName(err),
        });
        std.process.exit(1);
    };

    // Decode calldata / ctor args once.
    const calldata = decodeHexOpt(allocator, opts.calldata_hex) catch |err| {
        std.debug.print("Error: bad --data hex: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (calldata.len > 0) allocator.free(calldata);

    const ctor_args = decodeHexOpt(allocator, opts.ctor_args_hex) catch |err| {
        std.debug.print("Error: bad --ctor-args hex: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (ctor_args.len > 0) allocator.free(ctor_args);

    const sender = decodeAddressOpt(opts.from_hex) catch |err| {
        std.debug.print("Error: bad --from hex: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    } orelse DEFAULT_SENDER;

    switch (parse_result) {
        .bare => |*ast| {
            // Legacy bare-block path: parse as a flat AST and run directly.
            defer ast.deinit(allocator);
            try runBareBlock(allocator, ast, opts.filename.?, calldata, opts, stdout);
        },
        .tree => |tree_value| {
            // Object-syntax path: deploy then optionally call. The
            // tree_root needs a stable heap address so the chain can
            // own it (the chain stores `*ObjectTreeRoot`).
            const tree_ptr = try allocator.create(gyul.AST.ObjectTreeRoot);
            tree_ptr.* = tree_value;

            // Build the post-deploy call list. `--data` is a single-call
            // shortcut and is implicitly the first --call entry.
            var calls_owned: std.ArrayListUnmanaged([]u8) = .{};
            defer {
                for (calls_owned.items) |c| if (c.len > 0) allocator.free(c);
                calls_owned.deinit(allocator);
            }
            if (opts.calldata_hex != null) {
                try calls_owned.append(allocator, try allocator.dupe(u8, calldata));
            }
            for (opts.calls.items) |hex| {
                const decoded = decodeHexOpt(allocator, hex) catch |err| {
                    std.debug.print("Error: bad --call hex: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
                try calls_owned.append(allocator, decoded);
            }

            try deployAndCall(
                allocator,
                tree_ptr,
                opts.filename.?,
                sender,
                opts.value,
                ctor_args,
                calls_owned.items,
                opts,
                stdout,
            );
        },
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: [][:0]u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--calldata") or std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--data")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.calldata_hex = args[i];
        } else if (std.mem.eql(u8, a, "--call")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try opts.calls.append(allocator, args[i]);
        } else if (std.mem.eql(u8, a, "--ctor-args")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.ctor_args_hex = args[i];
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.from_hex = args[i];
        } else if (std.mem.eql(u8, a, "--value")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.value = std.fmt.parseInt(u256, args[i], 0) catch return error.BadValue;
        } else if (std.mem.eql(u8, a, "--no-trace")) {
            opts.trace = false;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            opts.quiet = true;
            opts.trace = false;
        } else if (std.mem.eql(u8, a, "--solc-compat")) {
            opts.solc_compat = true;
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{a});
            return error.UnknownOption;
        } else {
            opts.filename = a;
        }
    }
    return opts;
}

fn printUsage() void {
    const text =
        \\Usage: gyul [options] <file.yul>
        \\
        \\Bare-block files (e.g. `{ ... }`) are run directly. Files that
        \\use Yul object syntax (`object "C" { code { ... } object "C_deployed" { ... } }`)
        \\are deployed against a fresh in-memory chain, and optionally
        \\called via --data in the same invocation.
        \\
        \\Options:
        \\  --data, --calldata, -d <hex>  Calldata / call payload (hex, with or without 0x).
        \\                                Bare blocks: passed as initial calldata.
        \\                                Object files: also triggers a call into the
        \\                                deployed contract after the constructor runs.
        \\  --ctor-args <hex>             Constructor args appended after the init sentinel.
        \\                                Object files only.
        \\  --from <hex>                  Sender address (default: 0xdeadbeef...00).
        \\  --value <n>                   Value forwarded to the constructor / call (decimal
        \\                                or 0x-prefixed hex).
        \\  --no-trace                    Disable execution tracing.
        \\  --solc-compat                 Match solc's yulInterpreter quirks. Strictly opt-in.
        \\
    ;
    std.debug.print("{s}", .{text});
}

fn decodeHexOpt(allocator: std.mem.Allocator, hex_opt: ?[]const u8) ![]u8 {
    const hex = hex_opt orelse return &.{};
    var s = hex;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    if (s.len % 2 != 0) return error.OddHexLength;
    const out = try allocator.alloc(u8, s.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, s) catch return error.BadHex;
    return out;
}

fn decodeAddressOpt(hex_opt: ?[]const u8) !?gyul.GlobalState.Address {
    const hex = hex_opt orelse return null;
    var s = hex;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    if (s.len > 40) return error.AddressTooLong;
    var buf: [40]u8 = .{'0'} ** 40;
    @memcpy(buf[40 - s.len ..], s);
    var addr: gyul.GlobalState.Address = undefined;
    _ = std.fmt.hexToBytes(&addr, &buf) catch return error.BadHex;
    return addr;
}

fn runBareBlock(
    allocator: std.mem.Allocator,
    ast: *gyul.AST,
    filename: []const u8,
    calldata: []const u8,
    opts: Options,
    stdout: *std.Io.Writer,
) !void {
    // Run the existing checker.
    var diags = try gyul.Checker.check(allocator, ast);
    defer diags.deinit();
    if (diags.items.len > 0) {
        var msg_buf: [256]u8 = undefined;
        var msg_writer = std.Io.Writer.fixed(&msg_buf);
        for (diags.items) |d| {
            const loc = ast.tokenLocation(d.token);
            msg_writer.end = 0;
            d.message(&msg_writer) catch {};
            std.debug.print("{s}:{d}:{d}: {s}\n", .{
                filename, loc.line, loc.col, msg_buf[0..msg_writer.end],
            });
        }
        std.process.exit(1);
    }

    var global = gyul.GlobalState.init(allocator);
    defer global.deinit();
    if (opts.trace) global.tracer = stdout;
    global.calldata = calldata;
    try global.importDataSections(&ast.data_sections);

    if (opts.solc_compat) {
        global.memory_policy = .lax;
        global.solc_compat = true;
        if (global.world == null) {
            global.world = gyul.GlobalState.solcCompatWorld(&global);
        }
    }

    var local = gyul.LocalState.init(allocator, null);
    defer local.deinit();

    var interp = gyul.Interpreter.init(allocator, ast, &global, &local);
    const result = interp.interpret() catch |err| {
        if (interp.errorLocation()) |loc| {
            const tok_text = interp.errorTokenText() orelse "?";
            std.debug.print("{s}:{d}:{d}: runtime error: {s} at '{s}'\n", .{
                filename, loc.line, loc.col, @errorName(err), tok_text,
            });
        } else {
            std.debug.print("Runtime error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    try printHaltLine(stdout, result.halt_reason, global.return_data);
    try printFinalState(&global, stdout);
}

fn deployAndCall(
    allocator: std.mem.Allocator,
    tree_root: *gyul.AST.ObjectTreeRoot,
    filename: []const u8,
    sender: gyul.GlobalState.Address,
    value: u256,
    ctor_args: []const u8,
    call_list: []const []u8,
    opts: Options,
    stdout: *std.Io.Writer,
) !void {
    // Run the checker against every code block in the tree.
    var diags = try gyul.Checker.checkTree(allocator, tree_root);
    defer diags.deinit();
    if (diags.items.len > 0) {
        var msg_buf: [256]u8 = undefined;
        var msg_writer = std.Io.Writer.fixed(&msg_buf);
        var view = tree_root.asAst();
        for (diags.items) |d| {
            const loc = view.tokenLocation(d.token);
            msg_writer.end = 0;
            d.message(&msg_writer) catch {};
            std.debug.print("{s}:{d}:{d}: {s}\n", .{
                filename, loc.line, loc.col, msg_buf[0..msg_writer.end],
            });
        }
        // Also need to free the tree before exit; the chain hasn't
        // taken ownership yet.
        tree_root.deinit(allocator);
        allocator.destroy(tree_root);
        std.process.exit(1);
    }

    // Build a chain and hand the parsed tree to it. The chain takes
    // ownership and frees the tree on its own deinit.
    var chain = gyul.Chain.Chain.init(allocator);
    defer chain.deinit();

    // Move the heap-allocated tree into the chain. parseAny returned
    // an `ObjectTreeRoot` by value; we re-allocate on the heap so the
    // chain can own it. (`tree_root` here is already a *ObjectTreeRoot
    // — the caller passed a heap pointer.)
    const tree = chain.addParseTree(tree_root) catch |err| {
        std.debug.print("Failed to register parse tree: {s}\n", .{@errorName(err)});
        tree_root.deinit(allocator);
        allocator.destroy(tree_root);
        std.process.exit(1);
    };

    // Give the sender a generous balance so value transfers don't fail.
    const sender_acc = try chain.getOrCreateAccount(sender);
    sender_acc.balance = std.math.maxInt(u256) >> 1;

    const tree_ast = tree_root.asAst();

    const opt_struct = gyul.Interpreter.DeployOptions{
        .tracer = if (opts.trace) stdout else null,
        .memory_policy = if (opts.solc_compat) .lax else .strict,
        .solc_compat = opts.solc_compat,
    };

    const deploy_result = gyul.Interpreter.deployFromTree(
        allocator,
        &chain,
        tree,
        tree_ast,
        sender,
        value,
        ctor_args,
        opt_struct,
    ) catch |err| {
        std.debug.print("Deployment failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (deploy_result.return_data.len > 0) allocator.free(deploy_result.return_data);

    // Quiet/script mode: one structured line per result, no chain dump.
    // Format: "DEPLOY OK 0x<addr>" / "DEPLOY REVERT[ 0x<reason>]"
    //         "CALL  OK[ 0x<retdata>]" / "CALL  REVERT[ 0x<reason>]"
    if (deploy_result.halt_reason) |reason| {
        if (reason == .reverted or reason == .invalid_) {
            if (opts.quiet) {
                try stdout.writeAll("DEPLOY REVERT");
                if (deploy_result.return_data.len > 0) {
                    try stdout.writeAll(" 0x");
                    try stdout.printHex(deploy_result.return_data, .lower);
                }
                try stdout.writeByte('\n');
            } else {
                try stdout.writeAll("Deployment reverted");
                if (deploy_result.return_data.len > 0) {
                    try stdout.writeAll(": 0x");
                    try stdout.printHex(deploy_result.return_data, .lower);
                }
                try stdout.writeByte('\n');
                try printFinalChain(&chain, stdout);
            }
            return;
        }
    }

    if (opts.quiet) {
        try stdout.writeAll("DEPLOY OK 0x");
        try stdout.printHex(&deploy_result.new_address, .lower);
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll("Deployed at: ");
        try writeAddress(stdout, deploy_result.new_address);
        try stdout.writeByte('\n');
    }

    for (call_list) |data| {
        const call_result = gyul.Interpreter.callTopLevel(
            allocator,
            &chain,
            sender,
            deploy_result.new_address,
            0, // no value on calls by default
            data,
            opt_struct,
        ) catch |err| {
            std.debug.print("Call failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer if (call_result.return_data.len > 0) allocator.free(call_result.return_data);

        if (opts.quiet) {
            if (call_result.success) {
                try stdout.writeAll("CALL OK");
                if (call_result.return_data.len > 0) {
                    try stdout.writeAll(" 0x");
                    try stdout.printHex(call_result.return_data, .lower);
                }
                try stdout.writeByte('\n');
            } else {
                try stdout.writeAll("CALL REVERT");
                if (call_result.return_data.len > 0) {
                    try stdout.writeAll(" 0x");
                    try stdout.printHex(call_result.return_data, .lower);
                }
                try stdout.writeByte('\n');
            }
        } else {
            if (call_result.success) {
                if (call_result.halt_reason == .returned and call_result.return_data.len > 0) {
                    try stdout.writeAll("Returned: 0x");
                    try stdout.printHex(call_result.return_data, .lower);
                    try stdout.writeByte('\n');
                } else {
                    try stdout.writeAll("Call succeeded.\n");
                }
            } else {
                try stdout.writeAll("Call reverted");
                if (call_result.return_data.len > 0) {
                    try stdout.writeAll(": 0x");
                    try stdout.printHex(call_result.return_data, .lower);
                }
                try stdout.writeByte('\n');
            }
        }
    }

    if (!opts.quiet) try printFinalChain(&chain, stdout);
}

fn printHaltLine(stdout: *std.Io.Writer, reason: ?gyul.Interpreter.HaltReason, return_data: []const u8) !void {
    if (reason) |r| {
        switch (r) {
            .stopped => try stdout.writeAll("Execution stopped.\n"),
            .returned => {
                try stdout.writeAll("Execution returned");
                if (return_data.len > 0) {
                    try stdout.writeAll(": 0x");
                    try stdout.printHex(return_data, .lower);
                }
                try stdout.writeByte('\n');
            },
            .reverted => try stdout.writeAll("Execution reverted.\n"),
            .invalid_ => try stdout.writeAll("Invalid instruction.\n"),
        }
    }
}

fn printFinalState(global: *gyul.GlobalState, stdout: *std.Io.Writer) !void {
    try printFinalChain(global.chain, stdout);

    const msize = global.getMsize();
    if (msize > 0) {
        try stdout.writeAll("\nMemory:\n");
        const limit: usize = if (msize > 4096) 4096 else @intCast(msize);
        var offset: usize = 0;
        while (offset < limit) : (offset += 32) {
            const word = global.memLoad(@intCast(offset)) catch break;
            if (word == 0) continue;
            try stdout.print("  [{x:0>4}] ", .{offset});
            try gyul.GlobalState.writeU256(stdout, word);
            try stdout.writeByte('\n');
        }
        if (msize > 4096) {
            try stdout.print("  ... ({} bytes total)\n", .{msize});
        }
    }

    if (global.log_entries.items.len > 0) {
        try stdout.writeAll("\nLogs:\n");
        for (global.log_entries.items, 0..) |entry, i| {
            try stdout.print("  log[{}]: ", .{i});
            try gyul.GlobalState.writeU256(stdout, entry.address);
            try stdout.print(" {} bytes, {} topics", .{ entry.data.len, entry.topics.len });
            if (entry.topics.len > 0) {
                try stdout.writeAll(" (");
                for (entry.topics, 0..) |topic, j| {
                    if (j > 0) try stdout.writeAll(", ");
                    try gyul.GlobalState.writeU256(stdout, topic);
                }
                try stdout.writeByte(')');
            }
            try stdout.writeByte('\n');
        }
    }
}

fn printFinalChain(chain: *gyul.Chain.Chain, stdout: *std.Io.Writer) !void {
    if (chain.storageCount() > 0) {
        try stdout.writeAll("\nStorage:\n");
        var it = chain.storage_map.iterator();
        while (it.next()) |entry| {
            try stdout.writeAll("  ");
            try writeAddress(stdout, entry.key_ptr.addr);
            try stdout.writeAll(" ");
            try gyul.GlobalState.writeU256(stdout, entry.key_ptr.slot);
            try stdout.writeAll(": ");
            try gyul.GlobalState.writeU256(stdout, entry.value_ptr.*);
            try stdout.writeByte('\n');
        }
    }

    if (chain.transientCount() > 0) {
        try stdout.writeAll("\nTransient storage:\n");
        var it = chain.transient_map.iterator();
        while (it.next()) |entry| {
            try stdout.writeAll("  ");
            try writeAddress(stdout, entry.key_ptr.addr);
            try stdout.writeAll(" ");
            try gyul.GlobalState.writeU256(stdout, entry.key_ptr.slot);
            try stdout.writeAll(": ");
            try gyul.GlobalState.writeU256(stdout, entry.value_ptr.*);
            try stdout.writeByte('\n');
        }
    }
}

fn writeAddress(stdout: *std.Io.Writer, addr: gyul.GlobalState.Address) !void {
    try stdout.writeAll("0x");
    try stdout.printHex(&addr, .lower);
}

test "parse empty block" {
    const allocator = std.testing.allocator;
    const source = "{}";
    var ast = try gyul.AST.parse(allocator, source);
    defer ast.deinit(allocator);
}
