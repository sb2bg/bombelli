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
