const bombelli = @import("bombelli");

const problem = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});
const solver = problem.compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
});

export fn bombelli_newton(
    initial_x: f64,
    initial_y: f64,
    r: f64,
    values: *[2]f64,
    status: *u8,
    iterations: *usize,
) void {
    const result = solver.eval(.{
        .initial = .{ .x = initial_x, .y = initial_y },
        .r = r,
    });
    values.* = result.values;
    status.* = @intFromEnum(result.status);
    iterations.* = result.iterations;
}
