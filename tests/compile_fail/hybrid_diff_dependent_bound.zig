// expect-error: error: Bombelli hybrid integration has parameter-dependent bounds; explicit Leibniz boundary terms are required
const bombelli = @import("bombelli");

comptime {
    const symbolic = bombelli.expr("x + exp(-k*x^2)").integrate(.{
        .variable = .x,
        .from = 0,
        .to = "k",
        .domain = .real,
    });
    const compiled = symbolic.compile(.{
        .rule = .gauss_legendre,
        .order = 16,
    });
    _ = compiled.diff(.k);
}
