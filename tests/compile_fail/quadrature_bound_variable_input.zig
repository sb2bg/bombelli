// expect-error: error: Bombelli quadrature eval input field '.x' names a bound variable, not an input
const bombelli = @import("bombelli");

comptime {
    const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 4,
    });
    _ = rule.eval(.{ .from = 0.0, .to = 1.0, .k = 2.0, .x = 0.5 });
}
