// expect-error: error: Bombelli emitted Zig function name must not be a Zig keyword
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").emit(.{
        .target = .zig,
        .name = "export",
    });
}
