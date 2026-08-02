// expect-error: error: Bombelli imaginary unit 'i' requires std.math.Complex evaluation
const bombelli = @import("bombelli");

test {
    _ = bombelli.expr("i").eval(.{});
}
