// expect-error: error: function 'atan2' expects 2 arguments, received 1
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("atan2(x)");
}
