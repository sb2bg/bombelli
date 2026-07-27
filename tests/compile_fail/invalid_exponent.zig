// expect-error: error: power exponent must be an exact rational literal at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x^y");
}
