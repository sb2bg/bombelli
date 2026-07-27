// expect-error: error: Bombelli source emission supports '.target = .zig' and '.target = .c', not '.rust'
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").emit(.{
        .target = .rust,
        .mode = .out_of_place,
    });
}
