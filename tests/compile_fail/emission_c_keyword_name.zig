// expect-error: error: Bombelli emitted C function name must not be a C keyword
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").emit(.{
        .target = .c,
        .name = "double",
    });
}
