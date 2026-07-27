// expect-error: error: power chaining is not supported; parenthesize the base at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x^2^3");
}
