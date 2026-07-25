const bombelli = @import("bombelli");

comptime {
    const solver = bombelli.equationProblem("x^2 = p", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
    });
    _ = solver.diff(.x);
}
