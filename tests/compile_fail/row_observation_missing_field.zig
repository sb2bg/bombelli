// expect-error: Bombelli row least-squares observation is missing '.y'
const bombelli = @import("bombelli");

const solver = bombelli.residualModel(.{"a*x - y"}, .{
    .variables = .{.a},
    .data = .{ .x, .y },
}).leastSquares().compile(.{});

test {
    const observations = [_]struct { x: f64 }{
        .{ .x = 1.0 },
    };
    _ = solver.eval(.{
        .initial = .{ .a = 1.0 },
        .observations = &observations,
    });
}
