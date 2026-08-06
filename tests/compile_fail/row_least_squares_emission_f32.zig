// expect-error: error: Bombelli runtime-observation least-squares source emission currently requires '.scalar = .f64'
const bombelli = @import("bombelli");

test {
    const fitter = comptime bombelli.residualModel(.{
        "a*x - y",
    }, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    }).leastSquares().compile(.{});
    _ = comptime fitter.emit(.{
        .target = .c,
        .mode = .out_of_place,
        .name = "fit_line",
        .scalar = .f32,
    });
}
