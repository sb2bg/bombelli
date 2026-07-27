// expect-error: error: ln is undefined for non-positive constants
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("ln(0 - 1) + x").simplify();
}
