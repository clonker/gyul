const std = @import("std");
const gyul = @import("gyul");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("Needs exactly one argument.\n", .{});
        return;
    }

    const filename = args[1];
    const contents = try std.fs.cwd().readFileAllocOptions(allocator, filename, 1e8, null, @alignOf(u8), 0);
    defer allocator.free(contents);

    var tokenizer = gyul.GYulTokenizer.init(contents);
    var currentToken = tokenizer.next();
    while(currentToken.tag != .eof) : (currentToken = tokenizer.next()) {
        tokenizer.dump(&currentToken);
    }
    tokenizer.dump(&currentToken);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

