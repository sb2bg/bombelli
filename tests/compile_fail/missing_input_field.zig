// expect-error: error: Bombelli eval input is missing the field '.y'
const bombelli = @import("bombelli");

const f = bombelli.expr("x + y");

test {
    _ = f.eval(.{ .x = 1.0 });
}
