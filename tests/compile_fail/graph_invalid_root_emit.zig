// expect-error: error: Bombelli invariant failure: root node is out of bounds
const bombelli = @import("bombelli");
const expression: bombelli.Expr = .{
    .nodes = &.{.{ .integer = 1 }},
    .root = 99,
    .source = "malformed graph",
    .construction_peak_nodes = 1,
};
test {
    _ = comptime expression.emit(.{ .target = .c });
}
