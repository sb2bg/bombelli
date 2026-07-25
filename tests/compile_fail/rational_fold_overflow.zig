const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr(
        "9223372036854775807 / 2 + 9223372036854775807 / 3",
    ).simplify();
}
