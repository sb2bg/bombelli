// expect-error: error: Bombelli invariant failure: expression is not topologically ordered
const bombelli = @import("bombelli");
const expression: bombelli.Expr = .{
    .nodes = &.{.{ .unary = .{ .op = .sin, .child = 0 } }},
    .root = 0,
    .source = "malformed graph",
    .construction_peak_nodes = 1,
};
test {
    _ = comptime expression.emit(.{ .target = .zig });
}
