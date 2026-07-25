const bombelli = @import("bombelli");

const response = bombelli.expr("sin(x * y) + x^3");
const gradient = response.gradient(.{ .x, .y }).simplify();

export fn bombelli_response(x: f64, y: f64) f64 {
    return response.eval(.{ .x = x, .y = y });
}

export fn bombelli_gradient(x: f64, y: f64, output: *[2]f64) void {
    gradient.evalInto(output, .{ .x = x, .y = y });
}
