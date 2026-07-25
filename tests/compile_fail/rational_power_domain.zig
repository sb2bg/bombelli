const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("(-1.0)^(1/2)").simplify();
}
