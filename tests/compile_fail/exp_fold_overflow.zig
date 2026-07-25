const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("exp(1000) * x").simplify();
}
