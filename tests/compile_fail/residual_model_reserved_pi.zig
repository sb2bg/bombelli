// expect-error: Bombelli residualModel name '.pi' is reserved by the runtime solver
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.residualModel(.{"pi*x - y"}, .{
        .variables = .{.pi},
        .data = .{ .x, .y },
    });
}
