const Text = @import("../text.zig").Text;
const std = @import("std");
const ast = @import("../../../expression.zig");
const support = @import("support.zig");

const emitNodes = support.emitNodes;
const freeSymbols = support.freeSymbols;
const inputsStruct = support.inputsStruct;
const prelude = support.prelude;
const unusedInputs = support.unusedInputs;
const validateOptions = support.validateOptions;

pub fn emitExpr(
    comptime expression: ast.Expr,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const symbols = freeSymbols(expression.nodes, &.{});

    var source = Text.init(prelude());
    source.append("\n");
    source.append(inputsStruct(name, symbols));
    source.append(std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ *output);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ *output) {{\n",
        .{ name, name, name, name },
    ));
    source.append(unusedInputs(symbols));
    source.append(emitNodes(expression.nodes, "n", &.{}));
    source.append(std.fmt.comptimePrint(
        "    *output = n{d};\n}}\n",
        .{expression.root},
    ));
    return support.instantiate(source.finish(), support.scalarOption(options));
}

pub fn emitVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const symbols = freeSymbols(expression.nodes, &.{});

    var source = Text.init(prelude());
    source.append("\n");
    source.append(inputsStruct(name, symbols));
    source.append(std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}]);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}]) {{\n",
        .{ name, name, N, name, name, N },
    ));
    source.append(unusedInputs(symbols));
    source.append(emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |root, index| {
        source.append(std.fmt.comptimePrint(
            "    output[{d}] = n{d};\n",
            .{ index, root },
        ));
    }
    source.append("}\n");
    return support.instantiate(source.finish(), support.scalarOption(options));
}

pub fn emitMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const symbols = freeSymbols(expression.nodes, &.{});

    var source = Text.init(prelude());
    source.append("\n");
    source.append(inputsStruct(name, symbols));
    source.append(std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}][{d}]);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}][{d}]) {{\n",
        .{ name, name, R, C, name, name, R, C },
    ));
    source.append(unusedInputs(symbols));
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
    return support.instantiate(source.finish(), support.scalarOption(options));
}
