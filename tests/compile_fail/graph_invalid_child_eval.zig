// expect-error: error: Bombelli invariant failure: child node is out of bounds
const bombelli = @import("bombelli");
const expression: bombelli.Expr = .{
    .nodes = &.{ .{ .integer = 1 }, .{ .sub = .{ .left = 0, .right = 99 } } },
    .root = 1,
    .source = "malformed graph",
    .construction_peak_nodes = 2,
};
test {
    _ = expression.eval(.{});
}
