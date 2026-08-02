// expect-error: Bombelli nonlinear least squares currently supports only real-domain models
const bombelli = @import("bombelli");

test {
    _ = comptime bombelli.model(.{
        "z^2 + 1",
    }, .{
        .variables = .{.z},
        .domain = .complex,
    }).leastSquares();
}
