// expect-error: error: unexpected character at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x @ y");
}
