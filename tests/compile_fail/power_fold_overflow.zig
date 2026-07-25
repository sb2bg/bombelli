const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("3^40 + x").simplify();
}
