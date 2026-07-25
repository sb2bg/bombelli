const bombelli = @import("bombelli");

const rule = bombelli.expr("exp(-k*x^2)").adaptiveQuadrature(.{
    .variable = .x,
    .max_depth = 8,
    .tolerance = 1e-10,
});

export fn bombelli_adaptive_quadrature(
    from: f64,
    to: f64,
    k: f64,
    value: *f64,
    status: *u8,
) void {
    const result = rule.eval(.{
        .from = from,
        .to = to,
        .k = k,
    });
    value.* = result.value;
    status.* = @intFromEnum(result.status);
}
