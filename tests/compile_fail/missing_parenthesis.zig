// expect-error: error: missing closing parenthesis at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("sin(x");
}
