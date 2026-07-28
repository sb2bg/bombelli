// expect-error: Bombelli residualModel option '.inputs' is not recognized
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.residualModel(.{"a*x - y"}, .{
        .variables = .{.a},
        .data = .{ .x, .y },
        .inputs = .{},
    });
}
