// expect-error: error: constant folding produced a non-finite floating-point value
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("exp(1000.0) * x").simplify();
}
