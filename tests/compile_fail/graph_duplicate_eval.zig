// expect-error: error: Bombelli invariant failure: expression contains duplicate nodes
const bombelli = @import("bombelli");
const expression: bombelli.Expr = .{
    .nodes = &.{ .{ .integer = 1 }, .{ .integer = 1 }, .{ .sub = .{ .left = 0, .right = 1 } } },
    .root = 2,
    .source = "malformed graph",
    .construction_peak_nodes = 3,
};
test {
    _ = expression.eval(.{});
}
