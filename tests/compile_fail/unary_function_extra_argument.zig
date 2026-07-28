// expect-error: error: function 'sin' expects 1 argument, received 2
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("sin(x, y)");
}
