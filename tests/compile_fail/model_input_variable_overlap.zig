// expect-error: Bombelli model inputs and variables must be disjoint
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"x^2"}, .{
        .variables = .{.x},
        .inputs = .{.x},
    });
}
