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
    var root = builder.cloneExpression(expressions[0]);
    for (expressions[1..]) |expression| {
        root = builder.add(root, builder.cloneExpression(expression));
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
    var root = builder.cloneNode(
        expression.nodes,
        roots[0],
        &cache,
    );
    for (roots[1..]) |factor| {
        root = builder.mul(
            root,
            builder.cloneNode(expression.nodes, factor, &cache),
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
    const root = builder.power(builder.cloneExpression(base), exponent);
    return finish(&builder, root, &.{base});
}

pub fn unary(comptime operation: Unary, comptime expression: ast.Expr) ast.Expr {
    var builder = build.Builder{};
    const child = builder.cloneExpression(expression);
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
    const left_root = builder.cloneExpression(left);
    const right_root = builder.cloneExpression(right);
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
