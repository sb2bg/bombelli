const std = @import("std");
const ast = @import("ast.zig");

pub inline fn evaluate(comptime expression: ast.Expr, values: anytype) f64 {
    const results = evaluateNodes(expression.nodes, values);
    return results[@intCast(expression.root)];
}

pub inline fn evaluateVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    values: anytype,
) [N]f64 {
    var output: [N]f64 = undefined;
    evaluateVectorInto(N, expression, &output, values);
    return output;
}

pub inline fn evaluateVectorInto(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    output: anytype,
    values: anytype,
) void {
    validateOutput(N, output);
    const results = evaluateNodes(expression.nodes, values);
    inline for (expression.roots, 0..) |root, index| {
        output[index] = results[@intCast(root)];
    }
}

pub inline fn evaluateMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    values: anytype,
) [R][C]f64 {
    var output: [R][C]f64 = undefined;
    evaluateMatrixInto(R, C, expression, &output, values);
    return output;
}

pub inline fn evaluateMatrixInto(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    output: anytype,
    values: anytype,
) void {
    validateMatrixOutput(R, C, output);
    const results = evaluateNodes(expression.nodes, values);
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            output[row_index][column_index] = results[@intCast(root)];
        }
    }
}

inline fn evaluateNodes(comptime nodes: []const ast.Node, values: anytype) [nodes.len]f64 {
    // Finished programs are topologically ordered, so this unrolled loop emits
    // one numerical computation per stored node across every output root.
    var results: [nodes.len]f64 = undefined;
    inline for (nodes, 0..) |node, index| {
        results[index] = switch (node) {
            .integer => |value| @floatFromInt(value),
            .float => |value| value,
            .symbol => |name| symbolValue(name, values),
            .add => |binary| results[@intCast(binary.left)] +
                results[@intCast(binary.right)],
            .sub => |binary| results[@intCast(binary.left)] -
                results[@intCast(binary.right)],
            .mul => |binary| results[@intCast(binary.left)] *
                results[@intCast(binary.right)],
            .div => |binary| results[@intCast(binary.left)] /
                results[@intCast(binary.right)],
            .pow => |power| integerPower(
                results[@intCast(power.base)],
                power.exponent,
            ),
            .negate => |child| -results[@intCast(child)],
            .sin => |child| @sin(results[@intCast(child)]),
            .cos => |child| @cos(results[@intCast(child)]),
            .exp => |child| @exp(results[@intCast(child)]),
            .ln => |child| @log(results[@intCast(child)]),
        };
    }
    return results;
}

inline fn validateOutput(comptime N: usize, output: anytype) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalInto expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.len != N) {
                        @compileError("Bombelli evalInto output has the wrong length");
                    }
                    if (array.child != f64) {
                        @compileError("Bombelli evalInto output elements must be f64");
                    }
                },
                else => @compileError("Bombelli evalInto expects a pointer to a fixed-size output array"),
            }
        },
        else => @compileError("Bombelli evalInto expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn validateMatrixOutput(comptime R: usize, comptime C: usize, output: anytype) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalInto expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |outer| {
                    if (outer.len != R) {
                        @compileError("Bombelli evalInto output has the wrong row count");
                    }
                    switch (@typeInfo(outer.child)) {
                        .array => |inner| {
                            if (inner.len != C) {
                                @compileError("Bombelli evalInto output has the wrong column count");
                            }
                            if (inner.child != f64) {
                                @compileError("Bombelli evalInto output elements must be f64");
                            }
                        },
                        else => @compileError("Bombelli matrix evalInto expects two-dimensional output storage"),
                    }
                },
                else => @compileError("Bombelli evalInto expects a pointer to a fixed-size output matrix"),
            }
        },
        else => @compileError("Bombelli evalInto expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn symbolValue(comptime name: []const u8, values: anytype) f64 {
    const Values = @TypeOf(values);
    if (@typeInfo(Values) != .@"struct") {
        @compileError("Bombelli eval expects a struct value containing symbol fields");
    }
    if (!@hasField(Values, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli eval input is missing the field '.{s}'",
            .{name},
        ));
    }

    const value = @field(values, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli eval field '.{s}' must be an integer or floating-point value",
            .{name},
        )),
    };
}

inline fn integerPower(base: f64, comptime exponent: u32) f64 {
    if (exponent == 0) return 1.0;
    if (exponent == 1) return base;

    const half = integerPower(base, exponent / 2);
    const square = half * half;
    return if (exponent % 2 == 0) square else square * base;
}
