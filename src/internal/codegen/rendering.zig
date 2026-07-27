const std = @import("std");
const ast = @import("../../expression.zig");

pub const RenderMode = enum {
    canonical,
    pretty,
};

pub fn render(comptime expression: ast.Expr) []const u8 {
    return renderMode(expression, .canonical);
}

pub fn renderMode(
    comptime expression: ast.Expr,
    comptime mode: RenderMode,
) []const u8 {
    var rendered: [expression.nodes.len][]const u8 = undefined;
    inline for (expression.nodes, 0..) |node, index| {
        rendered[index] = renderBare(
            expression,
            node,
            rendered[0..index],
            mode,
        );
    }
    return rendered[@intCast(expression.root)];
}

pub fn renderVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) [N][]const u8 {
    return renderVectorMode(N, expression, .canonical);
}

pub fn renderVectorMode(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime mode: RenderMode,
) [N][]const u8 {
    const rendered = renderNodes(expression.nodes, mode);
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
    return renderMatrixMode(R, C, expression, .canonical);
}

pub fn renderMatrixMode(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime mode: RenderMode,
) [R][C][]const u8 {
    const rendered = renderNodes(expression.nodes, mode);
    var outputs: [R][C][]const u8 = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            outputs[row_index][column_index] = rendered[@intCast(root)];
        }
    }
    return outputs;
}

fn renderNodes(
    comptime nodes: []const ast.Node,
    comptime mode: RenderMode,
) [nodes.len][]const u8 {
    const expression = ast.Expr{
        .nodes = nodes,
        .root = 0,
        .source = "",
        .construction_peak_nodes = nodes.len,
    };
    var rendered: [nodes.len][]const u8 = undefined;
    inline for (nodes, 0..) |node, index| {
        rendered[index] = renderBare(
            expression,
            node,
            rendered[0..index],
            mode,
        );
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
    comptime mode: RenderMode,
) []const u8 {
    return switch (node) {
        .integer => |value| std.fmt.comptimePrint("{d}", .{value}),
        .rational => |value| std.fmt.comptimePrint(
            "{d}/{d}",
            .{ value.numerator, value.denominator },
        ),
        .float => |value| renderFloat(value),
        .constant => |value| value.name(),
        .symbol => |name| name,
        .add => |binary| std.fmt.comptimePrint(
            "{s} + {s}",
            .{
                renderChild(expression, binary.left, .add_left, rendered),
                renderChild(expression, binary.right, .add_right, rendered),
            },
        ),
        .add_nary => |operands| renderNaryAdd(expression, operands, rendered),
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
        .mul_nary => |operands| renderNaryMul(expression, operands, rendered),
        .div => |binary| std.fmt.comptimePrint(
            "{s} / {s}",
            .{
                renderChild(expression, binary.left, .div_left, rendered),
                renderChild(expression, binary.right, .div_right, rendered),
            },
        ),
        .pow => |power| if (mode == .pretty and
            power.exponent.numerator == 1 and
            power.exponent.denominator == 2)
            renderFunction(expression, "sqrt", power.base, rendered)
        else if (power.exponent.denominator == 1)
            std.fmt.comptimePrint(
                "{s}^{d}",
                .{
                    renderChild(expression, power.base, .power_base, rendered),
                    power.exponent.numerator,
                },
            )
        else
            std.fmt.comptimePrint(
                "{s}^({d}/{d})",
                .{
                    renderChild(expression, power.base, .power_base, rendered),
                    power.exponent.numerator,
                    power.exponent.denominator,
                },
            ),
        .negate => |child| std.fmt.comptimePrint(
            "-{s}",
            .{renderChild(expression, child, .negate_child, rendered)},
        ),
        .sin => |child| renderFunction(expression, "sin", child, rendered),
        .cos => |child| renderFunction(expression, "cos", child, rendered),
        .tan => |child| renderFunction(expression, "tan", child, rendered),
        .atan => |child| renderFunction(expression, "atan", child, rendered),
        .abs => |child| renderFunction(expression, "abs", child, rendered),
        .exp => |child| renderFunction(expression, "exp", child, rendered),
        .ln => |child| renderFunction(expression, "ln", child, rendered),
    };
}

fn renderNaryAdd(
    comptime expression: ast.Expr,
    comptime operands: []const ast.NodeId,
    comptime rendered: []const []const u8,
) []const u8 {
    var result = renderChild(expression, operands[0], .add_left, rendered);
    inline for (operands[1..]) |child| {
        if (negativeMagnitude(expression, child, rendered)) |magnitude| {
            result = std.fmt.comptimePrint("{s} - {s}", .{ result, magnitude });
        } else {
            result = std.fmt.comptimePrint(
                "{s} + {s}",
                .{ result, renderChild(expression, child, .add_right, rendered) },
            );
        }
    }
    return result;
}

fn renderNaryMul(
    comptime expression: ast.Expr,
    comptime operands: []const ast.NodeId,
    comptime rendered: []const []const u8,
) []const u8 {
    const first_node = expression.node(operands[0]);
    if (first_node == .rational) {
        const coefficient = first_node.rational;
        var product = renderChild(expression, operands[1], .mul_right, rendered);
        inline for (operands[2..]) |child| {
            product = std.fmt.comptimePrint(
                "{s} * {s}",
                .{ product, renderChild(expression, child, .mul_right, rendered) },
            );
        }
        const numerator_magnitude: u64 = @intCast(if (coefficient.numerator < 0)
            -@as(i128, coefficient.numerator)
        else
            coefficient.numerator);
        const signed_product = if (numerator_magnitude == 1)
            if (coefficient.numerator < 0)
                std.fmt.comptimePrint("-{s}", .{product})
            else
                product
        else
            std.fmt.comptimePrint(
                "{d} * {s}",
                .{ coefficient.numerator, product },
            );
        return std.fmt.comptimePrint(
            "{s} / {d}",
            .{ signed_product, coefficient.denominator },
        );
    }

    var result = renderChild(expression, operands[0], .mul_left, rendered);
    inline for (operands[1..]) |child| {
        result = std.fmt.comptimePrint(
            "{s} * {s}",
            .{ result, renderChild(expression, child, .mul_right, rendered) },
        );
    }
    return result;
}

fn negativeMagnitude(
    comptime expression: ast.Expr,
    comptime child: ast.NodeId,
    comptime rendered: []const []const u8,
) ?[]const u8 {
    return switch (expression.node(child)) {
        .negate => |grandchild| renderChild(
            expression,
            grandchild,
            .sub_right,
            rendered,
        ),
        .integer => |value| if (value < 0 and value != std.math.minInt(i64))
            std.fmt.comptimePrint("{d}", .{-value})
        else
            null,
        .rational => |value| if (value.numerator < 0 and
            value.numerator != std.math.minInt(i64))
            std.fmt.comptimePrint(
                "{d}/{d}",
                .{ -value.numerator, value.denominator },
            )
        else
            null,
        .mul_nary => |operands| blk: {
            const coefficient_node = expression.node(operands[0]);
            const rational_coefficient = coefficient_node == .rational and
                coefficient_node.rational.numerator < 0;
            const integer_coefficient = coefficient_node == .integer and
                coefficient_node.integer < 0;
            if (!rational_coefficient and !integer_coefficient) break :blk null;

            const numerator: i64 = if (rational_coefficient)
                coefficient_node.rational.numerator
            else
                coefficient_node.integer;
            if (numerator == std.math.minInt(i64)) break :blk null;
            const magnitude_numerator = -numerator;
            var magnitude: []const u8 = if (magnitude_numerator == 1)
                renderChild(expression, operands[1], .mul_right, rendered)
            else
                std.fmt.comptimePrint(
                    "{d} * {s}",
                    .{
                        magnitude_numerator,
                        renderChild(expression, operands[1], .mul_right, rendered),
                    },
                );
            inline for (operands[2..]) |factor| {
                magnitude = std.fmt.comptimePrint(
                    "{s} * {s}",
                    .{ magnitude, renderChild(expression, factor, .mul_right, rendered) },
                );
            }
            break :blk if (rational_coefficient)
                std.fmt.comptimePrint(
                    "{s} / {d}",
                    .{ magnitude, coefficient_node.rational.denominator },
                )
            else
                magnitude;
        },
        else => null,
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

    const decimal = std.fmt.comptimePrint("{d}", .{value});
    const typed_decimal = if (std.mem.indexOfAny(u8, decimal, ".eE") == null)
        std.fmt.comptimePrint("{s}.0", .{decimal})
    else
        decimal;
    const scientific = std.fmt.comptimePrint("{e}", .{value});
    return if (scientific.len < typed_decimal.len)
        scientific
    else
        typed_decimal;
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
        .add, .add_nary, .sub => 10,
        .mul, .mul_nary, .div => 20,
        .negate => 30,
        .pow => 40,
        .integer => |value| if (value < 0) 30 else 50,
        // Rationals render as infix division, so they must retain division
        // precedence even when their numerator is non-negative.
        .rational => 20,
        .float => |value| if (value < 0.0) 30 else 50,
        .constant, .symbol, .sin, .cos, .tan, .atan, .abs, .exp, .ln => 50,
    };
}
