const std = @import("std");
const gyul = @import("gyul");

fn stdoutWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    const file = std.fs.File.stdout();
    return file.write(bytes);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

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
        for (0..calldata.len) |j| {
            const hi = std.fmt.charToDigit(hex_str[j * 2], 16) catch {
                std.debug.print("Error: invalid hex character in calldata\n", .{});
                std.process.exit(1);
            };
            const lo = std.fmt.charToDigit(hex_str[j * 2 + 1], 16) catch {
                std.debug.print("Error: invalid hex character in calldata\n", .{});
                std.process.exit(1);
            };
            calldata[j] = @as(u8, hi) * 16 + lo;
        }
    }

    var global = gyul.GlobalState.init(allocator);
    defer global.deinit();
    if (trace) {
        global.tracer = .{
            .context = undefined,
            .writeFn = &stdoutWriteFn,
        };
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

    const w = std.fs.File.stdout();

    if (result.halt_reason) |reason| {
        switch (reason) {
            .stopped => try w.writeAll("Execution stopped.\n"),
            .returned => {
                try w.writeAll("Execution returned");
                if (global.return_data.len > 0) {
                    try w.writeAll(": 0x");
                    for (global.return_data) |b| {
                        var buf: [2]u8 = undefined;
                        _ = std.fmt.bufPrint(&buf, "{x:0>2}", .{b}) catch unreachable;
                        try w.writeAll(&buf);
                    }
                }
                try w.writeAll("\n");
            },
            .reverted => try w.writeAll("Execution reverted.\n"),
            .invalid_ => try w.writeAll("Invalid instruction.\n"),
        }
    }

    try printFinalState(&global, w);
}

fn printFinalState(global: *gyul.GlobalState, file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const stdout = file;

    // Storage
    if (global.storage.count() > 0) {
        try stdout.writeAll("\nStorage:\n");
        var it = global.storage.iterator();
        while (it.next()) |entry| {
            fbs.reset();
            try gyul.GlobalState.writeU256(writer, entry.key_ptr.*);
            try writer.writeAll(": ");
            try gyul.GlobalState.writeU256(writer, entry.value_ptr.*);
            try writer.writeByte('\n');
            try stdout.writeAll(fbs.getWritten());
        }
    }

    // Transient storage
    if (global.transient_storage.count() > 0) {
        try stdout.writeAll("\nTransient storage:\n");
        var it = global.transient_storage.iterator();
        while (it.next()) |entry| {
            fbs.reset();
            try gyul.GlobalState.writeU256(writer, entry.key_ptr.*);
            try writer.writeAll(": ");
            try gyul.GlobalState.writeU256(writer, entry.value_ptr.*);
            try writer.writeByte('\n');
            try stdout.writeAll(fbs.getWritten());
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
            fbs.reset();
            try std.fmt.format(writer, "  [{x:0>4}] ", .{offset});
            try gyul.GlobalState.writeU256(writer, word);
            try writer.writeByte('\n');
            try stdout.writeAll(fbs.getWritten());
        }
        if (msize > 4096) {
            fbs.reset();
            try std.fmt.format(writer, "  ... ({} bytes total)\n", .{msize});
            try stdout.writeAll(fbs.getWritten());
        }
    }

    // Logs
    if (global.log_entries.items.len > 0) {
        try stdout.writeAll("\nLogs:\n");
        for (global.log_entries.items, 0..) |entry, i| {
            fbs.reset();
            try std.fmt.format(writer, "  log[{}]: {} bytes, {} topics", .{ i, entry.data.len, entry.topics.len });
            if (entry.topics.len > 0) {
                try writer.writeAll(" (");
                for (entry.topics, 0..) |topic, j| {
                    if (j > 0) try writer.writeAll(", ");
                    try gyul.GlobalState.writeU256(writer, topic);
                }
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
            try stdout.writeAll(fbs.getWritten());
        }
    }
}

test "parse empty block" {
    const allocator = std.testing.allocator;
    const source = "{}";
    var ast = try gyul.AST.parse(allocator, source);
    defer ast.deinit(allocator);
}
