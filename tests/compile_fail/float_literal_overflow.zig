const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("1e999");
}
