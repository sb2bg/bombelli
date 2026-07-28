const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");
const exact = @import("../core/exact.zig");

const composed_source = "internally composed expression";

pub const Unary = enum {
    negate,
    sine,
    cosine,
    tangent,
    arcsine,
    arccosine,
    arctangent,
    hyperbolic_sine,
    hyperbolic_cosine,
    hyperbolic_tangent,
    absolute,
    exponential,
    logarithm,
    logarithm2,
    logarithm10,
};

pub fn integer(value: i64) ast.Expr {
    var builder = build.Builder{};
    return builder.finish(builder.integer(value), composed_source);
}

pub fn rational(value: exact.Rational) ast.Expr {
    var builder = build.Builder{};
    return builder.finish(builder.rational(value), composed_source);
}

pub fn symbol(comptime name: []const u8) ast.Expr {
    var builder = build.Builder{};
    return builder.finish(builder.symbol(name), composed_source);
}

pub fn add(comptime expressions: []const ast.Expr) ast.Expr {
    if (expressions.len == 0) return integer(0);

    var builder = build.Builder{};
    var root = cloneExpression(&builder, expressions[0]);
    for (expressions[1..]) |expression| {
        root = builder.add(root, cloneExpression(&builder, expression));
    }
    return finish(&builder, root, expressions);
}

pub fn productRoots(
    comptime expression: ast.Expr,
    comptime roots: []const ast.NodeId,
) ast.Expr {
    if (roots.len == 0) return integer(1);

    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var root = cloneNode(
        &builder,
        expression.nodes,
        roots[0],
        &cache,
    );
    for (roots[1..]) |factor| {
        root = builder.mul(
            root,
            cloneNode(&builder, expression.nodes, factor, &cache),
        );
    }
    var result = builder.finish(root, expression.source);
    result.construction_peak_nodes = @max(
        expression.construction_peak_nodes,
        result.construction_peak_nodes,
    );
    return result;
}

pub fn subtract(comptime left: ast.Expr, comptime right: ast.Expr) ast.Expr {
    return binary(left, right, .subtract);
}

pub fn multiply(comptime left: ast.Expr, comptime right: ast.Expr) ast.Expr {
    return binary(left, right, .multiply);
}

pub fn divide(comptime left: ast.Expr, comptime right: ast.Expr) ast.Expr {
    return binary(left, right, .divide);
}

pub fn power(comptime base: ast.Expr, exponent: exact.Rational) ast.Expr {
    var builder = build.Builder{};
    const root = builder.power(cloneExpression(&builder, base), exponent);
    return finish(&builder, root, &.{base});
}

pub fn unary(comptime operation: Unary, comptime expression: ast.Expr) ast.Expr {
    var builder = build.Builder{};
    const child = cloneExpression(&builder, expression);
    const root = switch (operation) {
        .negate => builder.negate(child),
        .sine => builder.sine(child),
        .cosine => builder.cosine(child),
        .tangent => builder.tangent(child),
        .arcsine => builder.arcsine(child),
        .arccosine => builder.arccosine(child),
        .arctangent => builder.arctangent(child),
        .hyperbolic_sine => builder.hyperbolicSine(child),
        .hyperbolic_cosine => builder.hyperbolicCosine(child),
        .hyperbolic_tangent => builder.hyperbolicTangent(child),
        .absolute => builder.absolute(child),
        .exponential => builder.exponential(child),
        .logarithm => builder.logarithm(child),
        .logarithm2 => builder.logarithm2(child),
        .logarithm10 => builder.logarithm10(child),
    };
    return finish(&builder, root, &.{expression});
}

const Binary = enum {
    subtract,
    multiply,
    divide,
};

fn binary(
    comptime left: ast.Expr,
    comptime right: ast.Expr,
    comptime operation: Binary,
) ast.Expr {
    var builder = build.Builder{};
    const left_root = cloneExpression(&builder, left);
    const right_root = cloneExpression(&builder, right);
    const root = switch (operation) {
        .subtract => builder.sub(left_root, right_root),
        .multiply => builder.mul(left_root, right_root),
        .divide => builder.div(left_root, right_root),
    };
    return finish(&builder, root, &.{ left, right });
}

fn finish(
    comptime builder: *build.Builder,
    root: ast.NodeId,
    comptime inputs: []const ast.Expr,
) ast.Expr {
    var result = builder.finish(root, composed_source);
    for (inputs) |input| {
        result.construction_peak_nodes = @max(
            input.construction_peak_nodes,
            result.construction_peak_nodes,
        );
    }
    return result;
}

fn cloneExpression(builder: *build.Builder, comptime expression: ast.Expr) ast.NodeId {
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    return cloneNode(builder, expression.nodes, expression.root, &cache);
}

fn cloneNode(
    builder: *build.Builder,
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    cache: []ast.NodeId,
) ast.NodeId {
    const index: usize = @intCast(id);
    if (cache[index] != ast.invalid_node) return cache[index];

    const result = switch (nodes[index]) {
        .integer => |value| builder.integer(value),
        .rational => |value| builder.rational(value),
        .float => |value| builder.float(value),
        .constant => |value| builder.constant(value),
        .symbol => |name| builder.symbol(name),
        .add => |value| builder.add(
            cloneNode(builder, nodes, value.left, cache),
            cloneNode(builder, nodes, value.right, cache),
        ),
        .add_nary => |operands| blk: {
            var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                cloned[operand_index] = cloneNode(builder, nodes, child, cache);
            }
            break :blk builder.addNary(cloned[0..operands.len]);
        },
        .sub => |value| builder.sub(
            cloneNode(builder, nodes, value.left, cache),
            cloneNode(builder, nodes, value.right, cache),
        ),
        .mul => |value| builder.mul(
            cloneNode(builder, nodes, value.left, cache),
            cloneNode(builder, nodes, value.right, cache),
        ),
        .mul_nary => |operands| blk: {
            var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                cloned[operand_index] = cloneNode(builder, nodes, child, cache);
            }
            break :blk builder.mulNary(cloned[0..operands.len]);
        },
        .div => |value| builder.div(
            cloneNode(builder, nodes, value.left, cache),
            cloneNode(builder, nodes, value.right, cache),
        ),
        .pow => |value| builder.power(
            cloneNode(builder, nodes, value.base, cache),
            value.exponent,
        ),
        .negate => |child| builder.negate(cloneNode(builder, nodes, child, cache)),
        .sin => |child| builder.sine(cloneNode(builder, nodes, child, cache)),
        .cos => |child| builder.cosine(cloneNode(builder, nodes, child, cache)),
        .tan => |child| builder.tangent(cloneNode(builder, nodes, child, cache)),
        .asin => |child| builder.arcsine(cloneNode(builder, nodes, child, cache)),
        .acos => |child| builder.arccosine(cloneNode(builder, nodes, child, cache)),
        .atan => |child| builder.arctangent(cloneNode(builder, nodes, child, cache)),
        .sinh => |child| builder.hyperbolicSine(cloneNode(builder, nodes, child, cache)),
        .cosh => |child| builder.hyperbolicCosine(cloneNode(builder, nodes, child, cache)),
        .tanh => |child| builder.hyperbolicTangent(cloneNode(builder, nodes, child, cache)),
        .abs => |child| builder.absolute(cloneNode(builder, nodes, child, cache)),
        .exp => |child| builder.exponential(cloneNode(builder, nodes, child, cache)),
        .ln => |child| builder.logarithm(cloneNode(builder, nodes, child, cache)),
        .log2 => |child| builder.logarithm2(cloneNode(builder, nodes, child, cache)),
        .log10 => |child| builder.logarithm10(cloneNode(builder, nodes, child, cache)),
    };
    cache[index] = result;
    return result;
}
