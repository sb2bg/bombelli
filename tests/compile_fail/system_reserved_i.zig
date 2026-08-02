// expect-error: error: Bombelli system unknown '.i' is a reserved mathematical constant
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.system(.{"i = 1"}, .{
        .unknowns = .{.i},
        .domain = .complex,
    });
}
