// expect-error: Bombelli least-squares option '.gradient_tolernace' is not recognized
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"x-1"}, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .gradient_tolernace = 1e-8,
    });
}
