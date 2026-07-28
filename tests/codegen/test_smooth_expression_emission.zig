const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted smooth expression matches Bombelli's evaluator" {
    var actual: f64 = undefined;
    generated.generated_smooth_expression(
        cases.smooth_expression_inputs,
        &actual,
    );

    try std.testing.expectApproxEqAbs(
        cases.smooth_expression.eval(cases.smooth_expression_inputs),
        actual,
        1e-15,
    );
}
