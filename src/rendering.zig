const std = @import("std");
const ast = @import("ast.zig");

pub fn render(comptime expression: ast.Expr) []const u8 {
    return renderNode(expression, expression.root, .none);
}

const Context = enum {
    none,
    add_left,
    add_right,
    sub_left,
    sub_right,
    mul_left,
    mul_right,
    div_left,
    div_right,
    power_base,
    negate_child,
};

fn renderNode(
    comptime expression: ast.Expr,
    comptime id: ast.NodeId,
    comptime context: Context,
) []const u8 {
    const node = expression.node(id);
    const bare = switch (node) {
        .integer => |value| std.fmt.comptimePrint("{d}", .{value}),
        .float => |value| std.fmt.comptimePrint("{d}", .{value}),
        .symbol => |name| name,
        .add => |binary| std.fmt.comptimePrint(
            "{s} + {s}",
            .{
                renderNode(expression, binary.left, .add_left),
                renderNode(expression, binary.right, .add_right),
            },
        ),
        .sub => |binary| std.fmt.comptimePrint(
            "{s} - {s}",
            .{
                renderNode(expression, binary.left, .sub_left),
                renderNode(expression, binary.right, .sub_right),
            },
        ),
        .mul => |binary| std.fmt.comptimePrint(
            "{s} * {s}",
            .{
                renderNode(expression, binary.left, .mul_left),
                renderNode(expression, binary.right, .mul_right),
            },
        ),
        .div => |binary| std.fmt.comptimePrint(
            "{s} / {s}",
            .{
                renderNode(expression, binary.left, .div_left),
                renderNode(expression, binary.right, .div_right),
            },
        ),
        .pow => |power| std.fmt.comptimePrint(
            "{s}^{d}",
            .{
                renderNode(expression, power.base, .power_base),
                power.exponent,
            },
        ),
        .negate => |child| std.fmt.comptimePrint(
            "-{s}",
            .{renderNode(expression, child, .negate_child)},
        ),
        .sin => |child| renderFunction(expression, "sin", child),
        .cos => |child| renderFunction(expression, "cos", child),
        .exp => |child| renderFunction(expression, "exp", child),
        .ln => |child| renderFunction(expression, "ln", child),
    };

    return if (needsParentheses(node, context))
        std.fmt.comptimePrint("({s})", .{bare})
    else
        bare;
}

fn renderFunction(
    comptime expression: ast.Expr,
    comptime name: []const u8,
    comptime child: ast.NodeId,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s})",
        .{ name, renderNode(expression, child, .none) },
    );
}

fn needsParentheses(node: ast.Node, context: Context) bool {
    if (context == .none) return false;

    const precedence = nodePrecedence(node);
    return switch (context) {
        .none => false,
        .add_left => precedence < 10,
        .add_right => precedence < 10 or node == .sub,
        .sub_left => precedence < 10,
        .sub_right => precedence <= 10,
        .mul_left => precedence < 20,
        .mul_right => precedence < 20,
        .div_left => precedence < 20,
        .div_right => precedence <= 20,
        .power_base => precedence <= 40,
        .negate_child => precedence <= 30,
    };
}

fn nodePrecedence(node: ast.Node) u8 {
    return switch (node) {
        .add, .sub => 10,
        .mul, .div => 20,
        .negate => 30,
        .pow => 40,
        .integer => |value| if (value < 0) 30 else 50,
        .float => |value| if (value < 0.0) 30 else 50,
        .symbol, .sin, .cos, .exp, .ln => 50,
    };
}
