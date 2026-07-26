const bombelli = @import("bombelli");

comptime {
    _ = bombelli.system(.{"x = 1"}, .{
        .unknowns = .{ .x, .x },
        .domain = .real,
    });
}
