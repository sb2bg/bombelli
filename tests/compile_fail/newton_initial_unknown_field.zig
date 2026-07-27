// expect-error: error: Bombelli Newton initial point field '.z' does not name an unknown
const bombelli = @import("bombelli");

const solver = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
}).compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 8,
    .tolerance = 1e-12,
});

comptime {
    _ = solver.eval(.{
        .initial = .{ .x = 1.0, .y = 1.0, .z = 0.0 },
        .r = 2.0,
    });
}
