// expect-error: Bombelli model symbol 'offset' is neither a declared variable nor input
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"slope*x + offset"}, .{
        .variables = .{.slope},
        .inputs = .{.x},
    });
}
