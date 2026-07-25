const bombelli = @import("bombelli");

const symbolic = bombelli.expr("3*x^2 + exp(x^2)").integrate(.{
    .variable = .x,
    .domain = .real,
});
const compiled = symbolic.compile(.{
    .rule = .gauss_legendre,
    .order = 16,
});

export fn bombelli_hybrid_integral(from: f64, to: f64) f64 {
    return compiled.eval(.{
        .from = from,
        .to = to,
    });
}
