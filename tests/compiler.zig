const std = @import("std");
const bombelli = @import("bombelli");

test "a long unary chain has bounded live storage" {
    const expression = comptime bombelli.expr("sin(cos(exp(sin(cos(x)))))");
    const metrics = comptime expression.metrics();
    try std.testing.expectEqual(6, metrics.node_count);
    try std.testing.expectEqual(2, metrics.peak_live_values);
}

test "shared children and repeated output roots have one lifetime" {
    const expression = comptime bombelli.exprVector(.{ "sin(x)", "sin(x)", "cos(sin(x))" });
    const metrics = comptime expression.metrics();
    try std.testing.expectEqual(3, metrics.node_count);
    try std.testing.expectEqual(2, metrics.peak_live_values);
    const actual = expression.eval(.{ .x = 0.4 });
    try std.testing.expectEqual(actual[0], actual[1]);
}

test "early output roots are retained while later outputs are evaluated" {
    const expression = comptime bombelli.exprMatrix(.{
        .{ "x", "sin(x)" }, .{ "cos(sin(x))", "exp(cos(sin(x)))" },
    });
    const metrics = comptime expression.metrics();
    try std.testing.expectEqual(4, metrics.peak_live_values);
    try std.testing.expectEqual(4, metrics.node_count);
}

test "derivative inspection reports peak live values separately from node slots" {
    const model = comptime bombelli.model(.{"sin(cos(exp(x)))"}, .{ .variables = .{.x} });
    const product = comptime model.compileVjp(.{});
    const info = comptime product.inspect();
    try std.testing.expectEqual(info.node_count, info.temporary_scalars);
    try std.testing.expectEqual(product.expression.metrics().peak_live_values, info.peak_live_values);
    try std.testing.expect(info.peak_live_values < info.temporary_scalars);
}

test "lifetime analysis retains primal edges even for a zero power" {
    const expression = comptime bombelli.expr("sin(x)^0");
    const metrics = comptime expression.metrics();
    try std.testing.expectEqual(3, metrics.node_count);
    try std.testing.expectEqual(2, metrics.peak_live_values);
}
