// expect-error: error: Bombelli Gauss-Legendre quadrature supports orders 4, 8, 16, and 32; received 12
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("x").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 12,
    });
}
