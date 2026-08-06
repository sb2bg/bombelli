// expect-error: Bombelli Newton source emission currently requires '.globalization = .none'
const bombelli = @import("bombelli");

comptime {
    const solver = bombelli.equationProblem("x^3 = 1", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
        .globalization = .backtracking,
    });
    _ = solver.emit(.{
        .target = .zig,
        .name = "solve",
    });
}
