const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("ln(0 - 1) + x").simplify();
}
