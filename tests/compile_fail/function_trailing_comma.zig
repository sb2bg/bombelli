// expect-error: error: expected a function argument after ','
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("hypot(x,)");
}
