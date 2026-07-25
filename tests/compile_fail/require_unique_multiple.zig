const bombelli = @import("bombelli");

comptime {
    _ = bombelli.equationProblem("x^2 - 4 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial).requireUnique();
}
