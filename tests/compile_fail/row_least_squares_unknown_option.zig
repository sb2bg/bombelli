// expect-error: Bombelli row least-squares option '.gradient_tolernace' is not recognized
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.residualModel(.{"a*x - y"}, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .gradient_tolernace = 1e-8,
    });
}
