const std = @import("std");
const ast = @import("ast.zig");

pub fn render(comptime expression: ast.Expr) []const u8 {
    var rendered: [expression.nodes.len][]const u8 = undefined;
    inline for (expression.nodes, 0..) |node, index| {
        rendered[index] = renderBare(expression, node, rendered[0..index]);
    }
    return rendered[@intCast(expression.root)];
}

pub fn renderVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) [N][]const u8 {
    const rendered = renderNodes(expression.nodes);
    var outputs: [N][]const u8 = undefined;
    inline for (expression.roots, 0..) |root, index| {
        outputs[index] = rendered[@intCast(root)];
    }
    return outputs;
}

pub fn renderMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) [R][C][]const u8 {
    const rendered = renderNodes(expression.nodes);
    var outputs: [R][C][]const u8 = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            outputs[row_index][column_index] = rendered[@intCast(root)];
        }
    }
    return outputs;
}

fn renderNodes(comptime nodes: []const ast.Node) [nodes.len][]const u8 {
    const expression = ast.Expr{
        .nodes = nodes,
        .root = 0,
        .source = "",
        .construction_peak_nodes = nodes.len,
    };
    var rendered: [nodes.len][]const u8 = undefined;
    inline for (nodes, 0..) |node, index| {
        rendered[index] = renderBare(expression, node, rendered[0..index]);
    }
    return rendered;
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

fn renderBare(
    comptime expression: ast.Expr,
    comptime node: ast.Node,
    comptime rendered: []const []const u8,
) []const u8 {
    return switch (node) {
        .integer => |value| std.fmt.comptimePrint("{d}", .{value}),
        .float => |value| renderFloat(value),
        .symbol => |name| name,
        .add => |binary| std.fmt.comptimePrint(
            "{s} + {s}",
            .{
                renderChild(expression, binary.left, .add_left, rendered),
                renderChild(expression, binary.right, .add_right, rendered),
            },
        ),
        .sub => |binary| std.fmt.comptimePrint(
            "{s} - {s}",
            .{
                renderChild(expression, binary.left, .sub_left, rendered),
                renderChild(expression, binary.right, .sub_right, rendered),
            },
        ),
        .mul => |binary| std.fmt.comptimePrint(
            "{s} * {s}",
            .{
                renderChild(expression, binary.left, .mul_left, rendered),
                renderChild(expression, binary.right, .mul_right, rendered),
            },
        ),
        .div => |binary| std.fmt.comptimePrint(
            "{s} / {s}",
            .{
                renderChild(expression, binary.left, .div_left, rendered),
                renderChild(expression, binary.right, .div_right, rendered),
            },
        ),
        .pow => |power| std.fmt.comptimePrint(
            "{s}^{d}",
            .{
                renderChild(expression, power.base, .power_base, rendered),
                power.exponent,
            },
        ),
        .negate => |child| std.fmt.comptimePrint(
            "-{s}",
            .{renderChild(expression, child, .negate_child, rendered)},
        ),
        .sin => |child| renderFunction(expression, "sin", child, rendered),
        .cos => |child| renderFunction(expression, "cos", child, rendered),
        .exp => |child| renderFunction(expression, "exp", child, rendered),
        .ln => |child| renderFunction(expression, "ln", child, rendered),
    };
}

fn renderChild(
    comptime expression: ast.Expr,
    comptime id: ast.NodeId,
    comptime context: Context,
    comptime rendered: []const []const u8,
) []const u8 {
    const node = expression.node(id);
    const bare = rendered[@intCast(id)];
    return if (needsParentheses(node, context))
        std.fmt.comptimePrint("({s})", .{bare})
    else
        bare;
}

fn renderFunction(
    comptime expression: ast.Expr,
    comptime name: []const u8,
    comptime child: ast.NodeId,
    comptime rendered: []const []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s})",
        .{ name, renderChild(expression, child, .none, rendered) },
    );
}

fn renderFloat(comptime value: f64) []const u8 {
    if (!std.math.isFinite(value)) {
        @compileError("Bombelli cannot render a non-finite floating-point literal");
    }

    const formatted = std.fmt.comptimePrint("{d}", .{value});
    return if (std.mem.indexOfAny(u8, formatted, ".eE") == null)
        std.fmt.comptimePrint("{s}.0", .{formatted})
    else
        formatted;
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
