const bombelli = @import("bombelli");

comptime {
    _ = bombelli.equationProblem("x = 1", .{
        .unknowns = .{ .x, .x },
        .domain = .real,
    });
}
