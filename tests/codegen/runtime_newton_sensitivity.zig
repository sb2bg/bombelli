const bombelli = @import("bombelli");

const problem = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});
const sensitivity_solver = problem.compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
}).diff(.r);

export fn bombelli_newton_sensitivity(
    initial_x: f64,
    initial_y: f64,
    r: f64,
    sensitivities: *[2]f64,
    status: *u8,
) void {
    const result = sensitivity_solver.eval(.{
        .initial = .{ .x = initial_x, .y = initial_y },
        .r = r,
    });
    sensitivities.* = result.sensitivities;
    status.* = @intFromEnum(result.status);
}
