const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 12,
    });
}
