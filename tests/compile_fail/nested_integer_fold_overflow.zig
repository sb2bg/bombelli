const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x + (9223372036854775807 + 1)").simplify();
}
