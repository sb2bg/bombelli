// expect-error: Bombelli least-squares bound field '.uppper' must be 'lower' or 'upper'
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"x-3"}, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .bounds = .{ .x = .{ .uppper = 2.0 } },
    });
}
