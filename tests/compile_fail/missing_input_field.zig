const bombelli = @import("bombelli");

const f = bombelli.expr("x + y");

test {
    _ = f.eval(.{ .x = 1.0 });
}
