const std = @import("std");
const ast = @import("../../expression.zig");

pub fn dependsOn(
    comptime expression: ast.Expr,
    comptime variable: []const u8,
) bool {
    var dependent = [_]bool{false} ** expression.nodes.len;
    inline for (expression.nodes, 0..) |node, index| {
        dependent[index] = switch (node) {
            .integer, .rational, .float => false,
            .symbol => |name| std.mem.eql(u8, name, variable),
            .add, .sub, .mul, .div => |binary| dependent[@intCast(binary.left)] or
                dependent[@intCast(binary.right)],
            .add_nary, .mul_nary => |operands| blk: {
                var any = false;
                for (operands) |child| {
                    any = any or dependent[@intCast(child)];
                }
                break :blk any;
            },
            .pow => |power| dependent[@intCast(power.base)],
            .negate, .sin, .cos, .tan, .atan, .abs, .exp, .ln => |child| dependent[@intCast(child)],
        };
    }
    return dependent[@intCast(expression.root)];
}
