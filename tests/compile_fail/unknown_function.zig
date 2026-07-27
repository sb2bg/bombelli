// expect-error: error: unknown function at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("floor(x)");
}
