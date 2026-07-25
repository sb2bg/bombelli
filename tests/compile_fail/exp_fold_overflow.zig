const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("exp(1000.0) * x").simplify();
}
