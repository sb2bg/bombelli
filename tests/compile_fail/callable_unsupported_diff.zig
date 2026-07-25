const bombelli = @import("bombelli");

comptime {
    const rule = bombelli.expr("exp(-x^2)").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 8,
        .tolerance = 1e-10,
    });
    _ = rule.diff(.k);
}
