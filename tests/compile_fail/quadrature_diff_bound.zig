// expect-error: error: Bombelli quadrature endpoints are runtime inputs; parameter-dependent bounds require explicit Leibniz terms
const bombelli = @import("bombelli");

comptime {
    const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    _ = rule.diff(.from);
}
