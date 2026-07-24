const std = @import("std");
const ast = @import("ast.zig");

pub inline fn evaluate(comptime expression: ast.Expr, values: anytype) f64 {
    return evaluateNode(expression, expression.root, values);
}

inline fn evaluateNode(comptime expression: ast.Expr, comptime id: ast.NodeId, values: anytype) f64 {
    const node = comptime expression.node(id);
    return switch (node) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        .symbol => symbolValue(node.symbol, values),
        .add => |binary| evaluateNode(expression, binary.left, values) +
            evaluateNode(expression, binary.right, values),
        .sub => |binary| evaluateNode(expression, binary.left, values) -
            evaluateNode(expression, binary.right, values),
        .mul => |binary| evaluateNode(expression, binary.left, values) *
            evaluateNode(expression, binary.right, values),
        .div => |binary| evaluateNode(expression, binary.left, values) /
            evaluateNode(expression, binary.right, values),
        .pow => |power| integerPower(
            evaluateNode(expression, power.base, values),
            power.exponent,
        ),
        .negate => |child| -evaluateNode(expression, child, values),
        .sin => |child| @sin(evaluateNode(expression, child, values)),
        .cos => |child| @cos(evaluateNode(expression, child, values)),
        .exp => |child| @exp(evaluateNode(expression, child, values)),
        .ln => |child| @log(evaluateNode(expression, child, values)),
    };
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
