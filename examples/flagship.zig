const std = @import("std");
const bombelli = @import("bombelli");

const dx = bombelli
    .expr("sin(x * y) + x^3")
    .diff(.x)
    .simplify();

pub export fn bombelli_evaluate(x: f64, y: f64) f64 {
    return dx.eval(.{ .x = x, .y = y });
}

pub fn main() !void {
    const value = bombelli_evaluate(2.0, 3.0);

    std.debug.print("{s}\nvalue at x=2, y=3: {d}\n", .{
        comptime dx.render(),
        value,
    });
}
