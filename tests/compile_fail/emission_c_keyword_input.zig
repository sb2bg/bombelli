// expect-error: error: Bombelli emitted C input name must not be a C keyword
const bombelli = @import("bombelli");

comptime {
    // A symbol that is fine in Bombelli and in Zig cannot become a C struct
    // field, so the collision is reported rather than emitted.
    _ = bombelli.expr("register * 2").emit(.{
        .target = .c,
        .name = "evaluate",
    });
}
