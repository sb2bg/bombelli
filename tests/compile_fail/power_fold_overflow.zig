// expect-error: error: integer constant folding exceeds i64 range
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("3^40 + x").simplify();
}
