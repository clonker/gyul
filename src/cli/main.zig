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

    var ast = gyul.AST.parse(allocator, contents) catch |err| {
        std.log.err("err: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ast.deinit(allocator);

    std.debug.print("len: {}\n", .{ast.nodes.len});

    // var tokenizer = gyul.GYulTokenizer.init(contents);
    // var currentToken = tokenizer.next();
    // while(currentToken.tag != .eof) : (currentToken = tokenizer.next()) {
    //     tokenizer.dump(&currentToken);
    // }
    // tokenizer.dump(&currentToken);
}

test "ast" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const filename = "src/cli/main.zig";
    const contents = try std.fs.cwd().readFileAllocOptions(allocator, filename, 1e8, null, @alignOf(u8), 0);
    defer allocator.free(contents);

    var x = std.zig.Ast.parse(allocator, contents, .zig) catch |err| {
        std.log.err("err: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer x.deinit(allocator);
}
