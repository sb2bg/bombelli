const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted expression matches direct compiled object" {
    var actual: f64 = undefined;
    generated.generated_expression(cases.expression_inputs, &actual);

    try std.testing.expectApproxEqAbs(
        cases.expression.eval(cases.expression_inputs),
        actual,
        1e-15,
    );
}
