const std = @import("std");
const bombelli = @import("bombelli");
const generated = @import("generated");

const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 16,
});

test "emitted quadrature matches direct compiled object" {
    const inputs = .{
        .from = 0.0,
        .to = 1.0,
        .k = 2.0,
    };
    var actual: f64 = undefined;
    generated.generated_quadrature(inputs, &actual);

    try std.testing.expectApproxEqAbs(
        rule.eval(inputs),
        actual,
        1e-15,
    );
}
