// expect-error: error: Bombelli source emission requires '.target = .zig' or '.target = .c'
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").emit(.{});
}
