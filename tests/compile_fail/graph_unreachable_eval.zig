// expect-error: error: Bombelli invariant failure: expression contains an unreachable node
const bombelli = @import("bombelli");
const expression: bombelli.Expr = .{
    .nodes = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
    .root = 1,
    .source = "malformed graph",
    .construction_peak_nodes = 2,
};
test {
    _ = expression.eval(.{});
}
