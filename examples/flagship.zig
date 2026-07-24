const std = @import("std");
const bombelli = @import("bombelli");

const response_gradient = bombelli
    .expr("ln(1 + x^2 * y^2) + exp(sin(x * y))")
    .diff(.x)
    .simplify();

pub fn responseGradient(x: f64, y: f64) f64 {
    return response_gradient.eval(.{ .x = x, .y = y });
}

pub fn main() void {
    const x = 1.25;
    const y = 0.75;

    std.debug.print("{s}\nvalue at x={d}, y={d}: {d}\n", .{
        comptime response_gradient.render(),
        x,
        y,
        responseGradient(x, y),
    });
}
