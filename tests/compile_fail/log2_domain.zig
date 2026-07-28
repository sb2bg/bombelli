// expect-error: error: log2 is undefined for non-positive constants
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("log2(0) + x").simplify();
}
