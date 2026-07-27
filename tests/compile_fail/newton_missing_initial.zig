// expect-error: error: Bombelli Newton eval input requires '.initial'
const bombelli = @import("bombelli");

const solver = bombelli.equationProblem("x^2 = 2", .{
    .unknowns = .{.x},
    .domain = .real,
}).compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 8,
    .tolerance = 1e-12,
});

test {
    _ = solver.eval(.{});
}
