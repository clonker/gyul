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
    while(currentToken.tag != .invalid and currentToken.tag != .eof) : (currentToken = tokenizer.next()) {
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

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), gyul.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
