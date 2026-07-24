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

test "twenty-factor product fits in the compact DAG" {
    const source = comptime product_source.metrics();
    const derivative = comptime product_derivative.metrics();
    const simplified = comptime product_simplified.metrics();

    report("product-20", "source", source);
    report("product-20", "derivative", derivative);
    report("product-20", "simplified", simplified);

    try expectCompactDag(source);
    try expectCompactDag(derivative);
    try expectCompactDag(simplified);
    try std.testing.expect(derivative.reachable_nodes > source.reachable_nodes);
    try std.testing.expect(simplified.reachable_nodes < derivative.reachable_nodes);
}

test "stress metrics cover deep composition" {
    const source = comptime composition_source.metrics();
    const derivative = comptime composition_derivative.metrics();
    const simplified = comptime composition_simplified.metrics();

    report("deep-composition", "source", source);
    report("deep-composition", "derivative", derivative);
    report("deep-composition", "simplified", simplified);

    try expectCompactDag(source);
    try expectCompactDag(derivative);
    try expectCompactDag(simplified);
    try std.testing.expect(derivative.reachable_nodes > source.reachable_nodes);
    try std.testing.expect(simplified.reachable_nodes <= derivative.reachable_nodes);
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

    try expectCompactDag(source);
    try expectCompactDag(d1);
    try expectCompactDag(d2);
    try expectCompactDag(d3);
    try expectCompactDag(d4);
    try std.testing.expectEqualStrings("11880 * x^8", comptime repeated_d4.render());
}

test "repeated structural subtrees are hash-consed" {
    const source = comptime shared_source.metrics();
    const derivative = comptime shared_derivative.metrics();
    const simplified = comptime shared_simplified.metrics();

    report("shared-subtree", "source", source);
    report("shared-subtree", "derivative", derivative);
    report("shared-subtree", "simplified", simplified);

    try expectCompactDag(source);
    try expectCompactDag(derivative);
    try expectCompactDag(simplified);
}

fn expectCompactDag(metrics: bombelli.Metrics) !void {
    try std.testing.expectEqual(metrics.stored_nodes, metrics.reachable_nodes);
    try std.testing.expectEqual(metrics.reachable_nodes, metrics.unique_structural_nodes);
    try std.testing.expectEqual(@as(usize, 0), metrics.duplicateOccurrences());
    try std.testing.expectEqual(@as(usize, 0), metrics.unreachableConstructionNodes());
}

fn report(case_name: []const u8, phase: []const u8, metrics: bombelli.Metrics) void {
    std.debug.print(
        "{s}\t{s}\tstored={d}\treachable={d}\tunique={d}\tduplicates={d}\tunreachable={d}\tconstruction_limit={d}\tbacking_bytes={d}\n",
        .{
            case_name,
            phase,
            metrics.stored_nodes,
            metrics.reachable_nodes,
            metrics.unique_structural_nodes,
            metrics.duplicateOccurrences(),
            metrics.unreachableConstructionNodes(),
            metrics.construction_limit,
            metrics.backing_bytes,
        },
    );
}
