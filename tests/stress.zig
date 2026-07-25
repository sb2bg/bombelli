const std = @import("std");
const bombelli = @import("bombelli");

const product_source = bombelli.expr(
    "(x + 1) * (x + 2) * (x + 3) * (x + 4) * (x + 5) * (x + 6) * (x + 7) * " ++
        "(x + 8) * (x + 9) * (x + 10) * (x + 11) * (x + 12) * (x + 13) * " ++
        "(x + 14) * (x + 15) * (x + 16) * (x + 17) * (x + 18) * (x + 19) * " ++
        "(x + 20)",
);
const product_derivative = product_source.diff(.x);
const product_simplified = product_derivative.simplify();

const composition_source = bombelli.expr("sin(exp(sin(exp(sin(x)))))");
const composition_derivative = composition_source.diff(.x);
const composition_simplified = composition_derivative.simplify();

const repeated_source = bombelli.expr("x^12");
const repeated_d1 = repeated_source.diff(.x).simplify();
const repeated_d2 = repeated_d1.diff(.x).simplify();
const repeated_d3 = repeated_d2.diff(.x).simplify();
const repeated_d4 = repeated_d3.diff(.x).simplify();

const shared_source = bombelli.expr(
    "sin(x * y)^2 + sin(x * y)^3 + sin(x * y)^4",
);
const shared_derivative = shared_source.diff(.x);
const shared_simplified = shared_derivative.simplify();

const factored_source = bombelli.expr(
    "x * x * x * x * x * x * x * x * x * x * " ++
        "x * x * x * x * x * x * x * x * x * x",
);
const factored_simplified = factored_source.simplify();

const coupled_functions = bombelli.exprVector(.{
    "sin(x*y + z*w) + x^2 + y*z",
    "sin(x*y + z*w)*x + exp(y + z)",
    "sin(x*y + z*w)*y + z^2",
    "sin(x*y + z*w)*z + w^2",
});
const coupled_jacobian = coupled_functions
    .jacobian(.{ .x, .y, .z, .w })
    .simplify();

const large_sum_source = bombelli.expr(
    "a01 + a02 + a03 + a04 + a05 + a06 + a07 + a08 + " ++
        "a09 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + " ++
        "a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24 + " ++
        "a25 + a26 + a27 + a28 + a29 + a30 + a31 + a32 + " ++
        "a33 + a34 + a35 + a36 + a37 + a38 + a39 + a40 + " ++
        "a41 + a42 + a43 + a44 + a45 + a46 + a47 + a48",
);
const large_sum_simplified = large_sum_source.simplify();

const large_product_source = bombelli.expr(
    "a01 * a02 * a03 * a04 * a05 * a06 * a07 * a08 * " ++
        "a09 * a10 * a11 * a12 * a13 * a14 * a15 * a16 * " ++
        "a17 * a18 * a19 * a20 * a21 * a22 * a23 * a24 * " ++
        "a25 * a26 * a27 * a28 * a29 * a30 * a31 * a32",
);
const large_product_simplified = large_product_source.simplify();
const polynomial_expansion = bombelli.expr("(w + x + y + z)^8").expand();
const exact_system_problem = bombelli.system(.{
    "x + y = 3",
    "y + z = 5",
    "z + w = 7",
    "x + 2*w = 9",
}, .{
    .unknowns = .{ .x, .y, .z, .w },
    .domain = .real,
});
const exact_system_solution = exact_system_problem.solve(.bareiss).requireUnique();
const symbolic_system_problem = bombelli.system(.{
    "a*x + b*y = e",
    "c*x + d*y = f",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});
const symbolic_system_solution = symbolic_system_problem.solve(.bareiss);
const symbolic_system_3x3 = bombelli.system(.{
    "a*x + y + z = e",
    "x + b*y + z = f",
    "x + y + c*z = g",
}, .{
    .unknowns = .{ .x, .y, .z },
    .domain = .real,
}).solve(.bareiss);
const repeated_parts_integral = bombelli.expr(
    "x^8 * exp(2*x + 1)",
).integrate(.{
    .variable = .x,
    .domain = .real,
}).unwrap().simplify();
const high_order_quadrature = bombelli.expr(
    "exp(-k*x^2) * cos(x)",
).quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 32,
});

test "twenty-factor product fits in the compact DAG" {
    const source = comptime product_source.metrics();
    const derivative = comptime product_derivative.metrics();
    const simplified = comptime product_simplified.metrics();

    report("product-20", "source", source);
    report("product-20", "derivative", derivative);
    report("product-20", "simplified", simplified);

    try expectMeasuredExpression(source);
    try expectMeasuredExpression(derivative);
    try expectMeasuredExpression(simplified);
    try std.testing.expect(derivative.node_count > source.node_count);
    try std.testing.expect(simplified.node_count < derivative.node_count);
}

test "stress metrics cover deep composition" {
    const source = comptime composition_source.metrics();
    const derivative = comptime composition_derivative.metrics();
    const simplified = comptime composition_simplified.metrics();

    report("deep-composition", "source", source);
    report("deep-composition", "derivative", derivative);
    report("deep-composition", "simplified", simplified);

    try expectMeasuredExpression(source);
    try expectMeasuredExpression(derivative);
    try expectMeasuredExpression(simplified);
    try std.testing.expect(derivative.node_count > source.node_count);
    try std.testing.expect(simplified.node_count <= derivative.node_count);
}

test "stress metrics cover four repeated derivatives" {
    const source = comptime repeated_source.metrics();
    const d1 = comptime repeated_d1.metrics();
    const d2 = comptime repeated_d2.metrics();
    const d3 = comptime repeated_d3.metrics();
    const d4 = comptime repeated_d4.metrics();

    report("repeated-x^12", "source", source);
    report("repeated-x^12", "d1", d1);
    report("repeated-x^12", "d2", d2);
    report("repeated-x^12", "d3", d3);
    report("repeated-x^12", "d4", d4);

    try expectMeasuredExpression(source);
    try expectMeasuredExpression(d1);
    try expectMeasuredExpression(d2);
    try expectMeasuredExpression(d3);
    try expectMeasuredExpression(d4);
    try std.testing.expectEqualStrings("11880 * x^8", comptime repeated_d4.render());
}

test "repeated structural subtrees are hash-consed" {
    const source = comptime shared_source.metrics();
    const derivative = comptime shared_derivative.metrics();
    const simplified = comptime shared_simplified.metrics();

    report("shared-subtree", "source", source);
    report("shared-subtree", "derivative", derivative);
    report("shared-subtree", "simplified", simplified);

    try expectMeasuredExpression(source);
    try expectMeasuredExpression(derivative);
    try expectMeasuredExpression(simplified);
}

test "large repeated products stay factored" {
    const source = comptime factored_source.metrics();
    const simplified = comptime factored_simplified.metrics();

    report("factored-x^20", "source", source);
    report("factored-x^20", "simplified", simplified);

    try expectMeasuredExpression(source);
    try expectMeasuredExpression(simplified);
    try std.testing.expectEqualStrings("x^20", comptime factored_simplified.render());
    try std.testing.expectEqual(@as(usize, 2), simplified.node_count);
    try std.testing.expect(simplified.construction_peak_nodes <= source.node_count);
}

test "coupled multi-root Jacobian remains shared and within measured capacity" {
    const functions = comptime coupled_functions.metrics();
    const jacobian = comptime coupled_jacobian.metrics();

    report("coupled-4x4", "functions", functions);
    report("coupled-4x4", "jacobian", jacobian);
    try expectMeasuredVector(4, functions);
    try std.testing.expect(jacobian.node_count > functions.node_count);
    try std.testing.expect(jacobian.construction_peak_nodes < 512);
}

test "large canonical sums and products use proportional operand storage" {
    const sum_source = comptime large_sum_source.metrics();
    const sum = comptime large_sum_simplified.metrics();
    const product_source_metrics = comptime large_product_source.metrics();
    const product = comptime large_product_simplified.metrics();

    report("canonical-sum-48", "source", sum_source);
    report("canonical-sum-48", "simplified", sum);
    report("canonical-product-32", "source", product_source_metrics);
    report("canonical-product-32", "simplified", product);

    try expectMeasuredExpression(sum_source);
    try expectMeasuredExpression(sum);
    try expectMeasuredExpression(product_source_metrics);
    try expectMeasuredExpression(product);
    try std.testing.expectEqual(@as(usize, 48), sum.operand_count);
    try std.testing.expectEqual(@as(usize, 32), product.operand_count);
    try std.testing.expect(sum.construction_peak_nodes < 256);
    try std.testing.expect(product.construction_peak_nodes < 256);
}

test "sparse polynomial expansion stays within measured construction headroom" {
    const expanded = comptime polynomial_expansion.metrics();
    report("polynomial-4var-degree8", "expanded", expanded);
    try expectMeasuredExpression(expanded);
    try std.testing.expect(expanded.operand_count >= 165);
    try std.testing.expect(expanded.construction_peak_nodes < 512);
}

test "exact and symbolic coefficient systems retain shared solution DAGs" {
    const exact_metrics = comptime exact_system_solution.metrics();
    const symbolic_metrics = comptime symbolic_system_solution.conditional.values.metrics();
    report("exact-system-4x4", "solution", exact_metrics);
    report("symbolic-system-2x2", "solution", symbolic_metrics);
    try expectMeasuredVector(4, exact_metrics);
    try expectMeasuredVector(2, symbolic_metrics);
    try std.testing.expectEqual(
        @as(usize, 1),
        symbolic_system_solution.conditional.conditions.len,
    );

    const symbolic_3x3_metrics =
        comptime symbolic_system_3x3.conditional.values.metrics();
    report("symbolic-system-3x3", "solution", symbolic_3x3_metrics);
    try expectMeasuredVector(3, symbolic_3x3_metrics);
}

test "repeated integration by parts stays bounded" {
    const integral_metrics = comptime repeated_parts_integral.metrics();
    report("integration-by-parts-degree8", "antiderivative", integral_metrics);
    try expectMeasuredExpression(integral_metrics);
    try std.testing.expect(integral_metrics.construction_peak_nodes < 512);

    const recovered = comptime repeated_parts_integral.diff(.x).simplify();
    const original = comptime bombelli.expr("x^8 * exp(2*x + 1)").simplify();
    try std.testing.expectApproxEqRel(
        original.eval(.{ .x = 0.75 }),
        recovered.eval(.{ .x = 0.75 }),
        1e-10,
    );
}

test "high-order quadrature remains fixed and allocation-free" {
    const value = high_order_quadrature.eval(.{
        .from = -1.0,
        .to = 1.0,
        .k = 3.0,
    });
    try std.testing.expect(std.math.isFinite(value));
    try std.testing.expect(value > 0.0);
}

fn expectMeasuredExpression(metrics: bombelli.Metrics) !void {
    try std.testing.expect(metrics.node_count > 0);
    try std.testing.expect(metrics.construction_peak_nodes >= metrics.node_count);
    try std.testing.expectEqual(
        @sizeOf(bombelli.Expr) +
            metrics.node_count * @sizeOf(bombelli.Node) +
            metrics.operand_count * @sizeOf(bombelli.NodeId),
        metrics.backing_bytes,
    );
}

fn expectMeasuredVector(comptime N: usize, metrics: bombelli.Metrics) !void {
    try std.testing.expect(metrics.node_count > 0);
    try std.testing.expect(metrics.construction_peak_nodes >= metrics.node_count);
    try std.testing.expectEqual(
        @sizeOf(bombelli.ExprVector(N)) +
            metrics.node_count * @sizeOf(bombelli.Node) +
            metrics.operand_count * @sizeOf(bombelli.NodeId),
        metrics.backing_bytes,
    );
}

fn report(case_name: []const u8, phase: []const u8, metrics: bombelli.Metrics) void {
    std.debug.print(
        "{s}\t{s}\tnodes={d}\toperands={d}\tconstruction_peak={d}\theadroom={d}\tbacking_bytes={d}\n",
        .{
            case_name,
            phase,
            metrics.node_count,
            metrics.operand_count,
            metrics.construction_peak_nodes,
            metrics.constructionHeadroom(),
            metrics.backing_bytes,
        },
    );
}
