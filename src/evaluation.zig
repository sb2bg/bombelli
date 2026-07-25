const std = @import("std");
const ast = @import("ast.zig");

pub inline fn evaluate(comptime expression: ast.Expr, values: anytype) f64 {
    // Finished expressions are topologically ordered, so this inline loop emits
    // one numerical computation per stored node and reuses shared subexpressions.
    var results: [expression.nodes.len]f64 = undefined;
    inline for (expression.nodes, 0..) |node, index| {
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
    return results[@intCast(expression.root)];
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
