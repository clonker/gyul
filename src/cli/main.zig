const std = @import("std");
const gyul = @import("gyul");

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

    var filename: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var trace: bool = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--calldata") or std.mem.eql(u8, args[i], "-d")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --calldata requires a hex argument\n", .{});
                std.process.exit(1);
            }
            calldata_hex = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-trace")) {
            trace = false;
        } else if (args[i][0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            std.process.exit(1);
        } else {
            filename = args[i];
        }
    }

    if (filename == null) {
        std.debug.print("Usage: gyul [options] <file>\n\nOptions:\n  --calldata, -d <hex>  Set calldata (hex-encoded, with or without 0x prefix)\n  --no-trace            Disable execution tracing\n", .{});
        std.process.exit(1);
    }

    const contents = try std.fs.cwd().readFileAllocOptions(allocator, filename.?, 1e8, null, .@"1", 0);
    defer allocator.free(contents);

    var ast = gyul.AST.parse(allocator, contents) catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ast.deinit(allocator);

    // Decode calldata
    var calldata: []u8 = &.{};
    defer if (calldata.len > 0) allocator.free(calldata);
    if (calldata_hex) |hex| {
        var hex_str = hex;
        if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X')) {
            hex_str = hex_str[2..];
        }
        if (hex_str.len % 2 != 0) {
            std.debug.print("Error: calldata hex string must have even length\n", .{});
            std.process.exit(1);
        }
        calldata = allocator.alloc(u8, hex_str.len / 2) catch {
            std.debug.print("Error: out of memory\n", .{});
            std.process.exit(1);
        };
        _ = std.fmt.hexToBytes(calldata, hex_str) catch {
            std.debug.print("Error: invalid hex character in calldata\n", .{});
            std.process.exit(1);
        };
    }

    var global = gyul.GlobalState.init(allocator);
    defer global.deinit();
    if (trace) {
        global.tracer = stdout;
    }
    global.calldata = calldata;

    var local = gyul.LocalState.init(allocator, null);
    defer local.deinit();

    var interp = gyul.Interpreter.init(allocator, &ast, &global, &local);
    const result = interp.interpret() catch |err| {
        if (interp.errorLocation()) |loc| {
            const tok_text = interp.errorTokenText() orelse "?";
            std.debug.print("{s}:{d}:{d}: runtime error: {s} at '{s}'\n", .{
                filename.?, loc.line, loc.col, @errorName(err), tok_text,
            });
        } else {
            std.debug.print("Runtime error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    if (result.halt_reason) |reason| {
        switch (reason) {
            .stopped => try stdout.writeAll("Execution stopped.\n"),
            .returned => {
                try stdout.writeAll("Execution returned");
                if (global.return_data.len > 0) {
                    try stdout.writeAll(": 0x");
                    try stdout.printHex(global.return_data, .lower);
                }
                try stdout.writeByte('\n');
            },
            .reverted => try stdout.writeAll("Execution reverted.\n"),
            .invalid_ => try stdout.writeAll("Invalid instruction.\n"),
        }
    }

    try printFinalState(&global, stdout);
}

fn printFinalState(global: *gyul.GlobalState, stdout: *std.Io.Writer) !void {
    // Storage
    if (global.storage.count() > 0) {
        try stdout.writeAll("\nStorage:\n");
        var it = global.storage.iterator();
        while (it.next()) |entry| {
            try gyul.GlobalState.writeU256(stdout, entry.key_ptr.*);
            try stdout.writeAll(": ");
            try gyul.GlobalState.writeU256(stdout, entry.value_ptr.*);
            try stdout.writeByte('\n');
        }
    }

    // Transient storage
    if (global.transient_storage.count() > 0) {
        try stdout.writeAll("\nTransient storage:\n");
        var it = global.transient_storage.iterator();
        while (it.next()) |entry| {
            try gyul.GlobalState.writeU256(stdout, entry.key_ptr.*);
            try stdout.writeAll(": ");
            try gyul.GlobalState.writeU256(stdout, entry.value_ptr.*);
            try stdout.writeByte('\n');
        }
    }

    // Memory
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

    // Logs
    if (global.log_entries.items.len > 0) {
        try stdout.writeAll("\nLogs:\n");
        for (global.log_entries.items, 0..) |entry, i| {
            try stdout.print("  log[{}]: {} bytes, {} topics", .{ i, entry.data.len, entry.topics.len });
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

test "parse empty block" {
    const allocator = std.testing.allocator;
    const source = "{}";
    var ast = try gyul.AST.parse(allocator, source);
    defer ast.deinit(allocator);
}
