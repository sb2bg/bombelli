// expect-error: Bombelli residualModel symbol 'offset' is neither a variable nor a data field
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.residualModel(.{"a*x + offset - y"}, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    });
}
