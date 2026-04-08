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

    if (args.len != 2) {
        std.debug.print("Usage: gyul <file>\n", .{});
        std.process.exit(1);
    }

    const filename = args[1];
    const contents = try std.fs.cwd().readFileAllocOptions(allocator, filename, 1e8, null, .@"1", 0);
    defer allocator.free(contents);

    var ast = gyul.AST.parse(allocator, contents) catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ast.deinit(allocator);

    var global = gyul.GlobalState.init(allocator);
    defer global.deinit();
    global.tracer = .{
        .context = undefined,
        .writeFn = &stdoutWriteFn,
    };

    var local = gyul.LocalState.init(allocator, null);
    defer local.deinit();

    var interp = gyul.Interpreter.init(allocator, &ast, &global, &local);
    _ = interp.interpret() catch |err| {
        std.debug.print("Runtime error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const w = std.fs.File.stdout();
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
