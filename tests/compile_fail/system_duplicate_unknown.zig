// expect-error: error: Bombelli system unknowns must be unique
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.system(.{"x = 1"}, .{
        .unknowns = .{ .x, .x },
        .domain = .real,
    });
}
