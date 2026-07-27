// expect-error: error: unexpected trailing token at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x y");
}
