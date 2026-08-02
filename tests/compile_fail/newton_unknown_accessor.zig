// expect-error: error: Bombelli Newton unknown '.z' is not declared
const bombelli = @import("bombelli");

test {
    const solver = comptime bombelli.equationProblem("x = 1", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 4,
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{ .initial = .{ .x = 0.0 } });
    _ = solver.value(result, .z);
}
