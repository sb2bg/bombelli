const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x + y").substitute(.{ .z = 5 });
}
