// expect-error: error: Bombelli Newton eval input field '.tolerance' does not name an input of this callable
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
        .initial = .{ .x = 1.0, .y = 1.0 },
        .r = 2.0,
        .tolerance = 1e-6,
    });
}
