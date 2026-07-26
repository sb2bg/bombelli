const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "export",
    });
}
