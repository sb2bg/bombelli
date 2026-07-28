// expect-error: error: asin is undefined outside [-1, 1] for real constants
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("asin(2.0) + x").simplify();
}
