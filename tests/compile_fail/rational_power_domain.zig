// expect-error: error: even-denominator rational power is not real for a negative base
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("(-1.0)^(1/2)").simplify();
}
