// expect-error: error: floating-point literal is out of range at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("1e999");
}
