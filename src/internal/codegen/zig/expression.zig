const Text = @import("../text.zig").Text;
const std = @import("std");
const ast = @import("../../../expression.zig");
const support = @import("support.zig");

const emitNodes = support.emitNodes;
const prelude = support.prelude;
const validateOptions = support.validateOptions;

pub fn emitExpr(
    comptime expression: ast.Expr,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source = Text.init(prelude());
    source.append(std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *f64) void {{\n",
        .{name},
    ));
    source.append(emitNodes(expression.nodes, "n", &.{}));
    source.append(std.fmt.comptimePrint(
        "    output.* = n{d};\n}}\n",
        .{expression.root},
    ));
    return support.applyScalar(source.finish(), support.scalarOption(options), name);
}

pub fn emitVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source = Text.init(prelude());
    source.append(std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *[{d}]f64) void {{\n",
        .{ name, N },
    ));
    source.append(emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |root, index| {
        source.append(std.fmt.comptimePrint(
            "    output[{d}] = n{d};\n",
            .{ index, root },
        ));
    }
    source.append("}\n");
    return support.applyScalar(source.finish(), support.scalarOption(options), name);
}

pub fn emitMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    var source = Text.init(prelude());
    source.append(std.fmt.comptimePrint(
        "\npub fn {s}(inputs: anytype, output: *[{d}][{d}]f64) void {{\n",
        .{ name, R, C },
    ));
    source.append(emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            source.append(std.fmt.comptimePrint(
                "    output[{d}][{d}] = n{d};\n",
                .{ row_index, column_index, root },
            ));
        }
    }
    source.append("}\n");
    return support.applyScalar(source.finish(), support.scalarOption(options), name);
}
