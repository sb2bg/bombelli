// expect-error: Bombelli model option '.input' is not recognized
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"a*x"}, .{
        .variables = .{.a},
        .input = .{.x},
    });
}
