const std = @import("std");
const AST = @import("AST.zig");

const Writer = std.io.AnyWriter;

pub fn print(gpa: std.mem.Allocator, tree: *const AST) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(gpa);

    printNode(tree, 0, 0, buf.writer(gpa).any());
    return buf.toOwnedSlice(gpa);
}

fn printNode(tree: *const AST, idx: AST.NodeIndex, indent: u32, writer: Writer) void {
    if (idx == AST.null_node) return;
    if (idx >= tree.nodes.len) return;
    const node = tree.nodes[idx];
    switch (node) {
        .root => |r| {
            writer.writeAll("{\n") catch return;
            for (tree.spanToList(r.body)) |child| {
                printNode(tree, child, indent + 2, writer);
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .block => |b| {
            writeIndent(writer, indent);
            writer.writeAll("{\n") catch return;
            for (tree.spanToList(b.stmts)) |child| {
                printNode(tree, child, indent + 2, writer);
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .function_definition => |f| {
            writeIndent(writer, indent);
            writer.writeAll("function ") catch return;
            writer.writeAll(tree.tokenSlice(f.name)) catch return;
            writer.writeByte('(') catch return;
            for (tree.spanToList(f.params), 0..) |param, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, param, 0, writer);
            }
            writer.writeByte(')') catch return;
            const rets = tree.spanToList(f.return_vars);
            if (rets.len > 0) {
                writer.writeAll(" -> ") catch return;
                for (rets, 0..) |ret, i| {
                    if (i > 0) writer.writeAll(", ") catch return;
                    printNode(tree, ret, 0, writer);
                }
            }
            writer.writeAll(" {\n") catch return;
            if (tree.nodes[f.body] == .block) {
                for (tree.spanToList(tree.nodes[f.body].block.stmts)) |child| {
                    printNode(tree, child, indent + 2, writer);
                }
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .variable_declaration => |v| {
            writeIndent(writer, indent);
            writer.writeAll("let ") catch return;
            for (tree.spanToList(v.names), 0..) |name, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, name, 0, writer);
            }
            if (v.value != AST.null_node) {
                writer.writeAll(" := ") catch return;
                printNode(tree, v.value, 0, writer);
            }
            writer.writeByte('\n') catch return;
        },
        .assignment => |a| {
            writeIndent(writer, indent);
            for (tree.spanToList(a.targets), 0..) |target, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, target, 0, writer);
            }
            writer.writeAll(" := ") catch return;
            printNode(tree, a.value, 0, writer);
            writer.writeByte('\n') catch return;
        },
        .if_statement => |s| {
            writeIndent(writer, indent);
            writer.writeAll("if ") catch return;
            printNode(tree, s.condition, 0, writer);
            writer.writeAll(" {\n") catch return;
            if (tree.nodes[s.body] == .block) {
                for (tree.spanToList(tree.nodes[s.body].block.stmts)) |child| {
                    printNode(tree, child, indent + 2, writer);
                }
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .switch_statement => |s| {
            writeIndent(writer, indent);
            writer.writeAll("switch ") catch return;
            printNode(tree, s.expr, 0, writer);
            writer.writeByte('\n') catch return;
            for (tree.spanToList(s.cases)) |c| {
                printNode(tree, c, indent, writer);
            }
        },
        .case_clause => |c| {
            writeIndent(writer, indent);
            writer.writeAll("case ") catch return;
            printNode(tree, c.value, 0, writer);
            writer.writeAll(" {\n") catch return;
            if (tree.nodes[c.body] == .block) {
                for (tree.spanToList(tree.nodes[c.body].block.stmts)) |child| {
                    printNode(tree, child, indent + 2, writer);
                }
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .case_default => |d| {
            writeIndent(writer, indent);
            writer.writeAll("default {\n") catch return;
            if (tree.nodes[d.body] == .block) {
                for (tree.spanToList(tree.nodes[d.body].block.stmts)) |child| {
                    printNode(tree, child, indent + 2, writer);
                }
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .for_loop => |f| {
            writeIndent(writer, indent);
            writer.writeAll("for ") catch return;
            printInlineBlock(tree, f.pre, indent, writer);
            writer.writeByte(' ') catch return;
            printNode(tree, f.condition, 0, writer);
            writer.writeByte(' ') catch return;
            printInlineBlock(tree, f.post, indent, writer);
            writer.writeAll(" {\n") catch return;
            if (tree.nodes[f.body] == .block) {
                for (tree.spanToList(tree.nodes[f.body].block.stmts)) |child| {
                    printNode(tree, child, indent + 2, writer);
                }
            }
            writeIndent(writer, indent);
            writer.writeAll("}\n") catch return;
        },
        .@"break" => {
            writeIndent(writer, indent);
            writer.writeAll("break\n") catch return;
        },
        .@"continue" => {
            writeIndent(writer, indent);
            writer.writeAll("continue\n") catch return;
        },
        .leave => {
            writeIndent(writer, indent);
            writer.writeAll("leave\n") catch return;
        },
        .expression_statement => |e| {
            writeIndent(writer, indent);
            printNode(tree, e.expr, 0, writer);
            writer.writeByte('\n') catch return;
        },
        .function_call => |f| {
            writer.writeAll(tree.tokenSlice(f.token)) catch return;
            writer.writeByte('(') catch return;
            for (tree.spanToList(f.args), 0..) |arg, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, arg, 0, writer);
            }
            writer.writeByte(')') catch return;
        },
        .identifier => |id| {
            writer.writeAll(tree.tokenSlice(id.token)) catch return;
        },
        .number_literal => |n| {
            writer.writeAll(tree.tokenSlice(n.token)) catch return;
        },
        .string_literal => |s| {
            writer.writeAll(tree.tokenSlice(s.token)) catch return;
        },
        .bool_literal => |b| {
            writer.writeAll(tree.tokenSlice(b.token)) catch return;
        },
        .hex_literal => |h| {
            writer.writeAll("hex") catch return;
            writer.writeAll(tree.tokenSlice(h.value)) catch return;
        },
    }
}

fn printInlineBlock(tree: *const AST, idx: AST.NodeIndex, indent: u32, writer: Writer) void {
    if (idx >= tree.nodes.len) return;
    if (tree.nodes[idx] == .block) {
        const stmts = tree.spanToList(tree.nodes[idx].block.stmts);
        if (stmts.len == 0) {
            writer.writeAll("{}") catch return;
        } else {
            writer.writeAll("{ ") catch return;
            for (stmts, 0..) |child, i| {
                if (i > 0) writer.writeByte(' ') catch return;
                printNodeInline(tree, child, indent, writer);
            }
            writer.writeAll(" }") catch return;
        }
    } else {
        printNode(tree, idx, indent, writer);
    }
}

fn printNodeInline(tree: *const AST, idx: AST.NodeIndex, _: u32, writer: Writer) void {
    if (idx == AST.null_node or idx >= tree.nodes.len) return;
    const node = tree.nodes[idx];
    switch (node) {
        .variable_declaration => |v| {
            writer.writeAll("let ") catch return;
            for (tree.spanToList(v.names), 0..) |name, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, name, 0, writer);
            }
            if (v.value != AST.null_node) {
                writer.writeAll(" := ") catch return;
                printNode(tree, v.value, 0, writer);
            }
        },
        .assignment => |a| {
            for (tree.spanToList(a.targets), 0..) |target, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                printNode(tree, target, 0, writer);
            }
            writer.writeAll(" := ") catch return;
            printNode(tree, a.value, 0, writer);
        },
        .expression_statement => |e| {
            printNode(tree, e.expr, 0, writer);
        },
        else => printNode(tree, idx, 0, writer),
    }
}

fn writeIndent(writer: Writer, indent: u32) void {
    for (0..indent) |_| {
        writer.writeByte(' ') catch return;
    }
}
