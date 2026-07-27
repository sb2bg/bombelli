// expect-error: error: Bombelli substitution replacement '.z' does not name a symbol in the expression
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x + y").substitute(.{ .z = 5 });
}
