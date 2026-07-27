const std = @import("std");
const ast = @import("../../../expression.zig");
const support = @import("support.zig");

const append = support.append;
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

    var source: []const u8 = prelude();
    source = append(source, "\n");
    source = append(source, inputsStruct(name, symbols));
    source = append(source, std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ *output);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ *output) {{\n",
        .{ name, name, name, name },
    ));
    source = append(source, unusedInputs(symbols));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    source = append(source, std.fmt.comptimePrint(
        "    *output = n{d};\n}}\n",
        .{expression.root},
    ));
    return support.instantiate(source, support.scalarOption(options));
}

pub fn emitVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const symbols = freeSymbols(expression.nodes, &.{});

    var source: []const u8 = prelude();
    source = append(source, "\n");
    source = append(source, inputsStruct(name, symbols));
    source = append(source, std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}]);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}]) {{\n",
        .{ name, name, N, name, name, N },
    ));
    source = append(source, unusedInputs(symbols));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |root, index| {
        source = append(source, std.fmt.comptimePrint(
            "    output[{d}] = n{d};\n",
            .{ index, root },
        ));
    }
    source = append(source, "}\n");
    return support.instantiate(source, support.scalarOption(options));
}

pub fn emitMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const symbols = freeSymbols(expression.nodes, &.{});

    var source: []const u8 = prelude();
    source = append(source, "\n");
    source = append(source, inputsStruct(name, symbols));
    source = append(source, std.fmt.comptimePrint(
        "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}][{d}]);\n" ++
            "\nvoid {s}(const {s}_inputs *inputs, @scalar@ output[{d}][{d}]) {{\n",
        .{ name, name, R, C, name, name, R, C },
    ));
    source = append(source, unusedInputs(symbols));
    source = append(source, emitNodes(expression.nodes, "n", &.{}));
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            source = append(source, std.fmt.comptimePrint(
                "    output[{d}][{d}] = n{d};\n",
                .{ row_index, column_index, root },
            ));
        }
    }
    source = append(source, "}\n");
    return support.instantiate(source, support.scalarOption(options));
}
