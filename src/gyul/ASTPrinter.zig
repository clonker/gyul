const std = @import("std");
const assert = std.debug.assert;
const AST = @import("AST.zig");

pub fn print(gpa: std.mem.Allocator, ast: *const AST) ![]u8 {
    if (ast.nodes.len == 0) {
        return error.PrintingError;
    }

    const rootNode = ast.nodes.get(0);
    assert(rootNode.tag == .root);

    const serializedAST = try std.fmt.allocPrint(gpa, "{{\n\n}}", .{});
    errdefer gpa.free(serializedAST);
    return serializedAST;
}
