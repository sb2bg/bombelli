const std = @import("std");
const ast = @import("../../../expression.zig");
const support = @import("support.zig");

const append = support.append;
const emitNodes = support.emitNodes;
const prelude = support.prelude;
const validateOptions = support.validateOptions;

pub fn emitExpr(
    comptime expression: ast.Expr,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source: []const u8 = prelude();
    source = append(source, std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *f64) void {{\n",
        .{name},
    ));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    source = append(source, std.fmt.comptimePrint(
        "    output.* = n{d};\n}}\n",
        .{expression.root},
    ));
    return source;
}

pub fn emitVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source: []const u8 = prelude();
    source = append(source, std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *[{d}]f64) void {{\n",
        .{ name, N },
    ));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |root, index| {
        source = append(source, std.fmt.comptimePrint(
            "    output[{d}] = n{d};\n",
            .{ index, root },
        ));
    }
    return append(source, "}\n");
}

pub fn emitMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source: []const u8 = prelude();
    source = append(source, std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *[{d}][{d}]f64) void {{\n",
        .{ name, R, C },
    ));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            source = append(source, std.fmt.comptimePrint(
                "    output[{d}][{d}] = n{d};\n",
                .{ row_index, column_index, root },
            ));
        }
    }
    return append(source, "}\n");
}
