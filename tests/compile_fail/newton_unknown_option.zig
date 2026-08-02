// expect-error: Bombelli Newton solver option '.backtrak_factor' is not recognized
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.equationProblem("x = 1", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 4,
        .tolerance = 1e-12,
        .backtrak_factor = 0.5,
    });
}
