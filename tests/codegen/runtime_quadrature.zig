const bombelli = @import("bombelli");

const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 16,
});

export fn bombelli_quadrature(from: f64, to: f64, k: f64) f64 {
    return rule.eval(.{
        .from = from,
        .to = to,
        .k = k,
    });
}
