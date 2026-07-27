const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted quadrature matches direct compiled object" {
    var actual: f64 = undefined;
    generated.generated_quadrature(cases.rule_inputs, &actual);

    try std.testing.expectApproxEqAbs(
        cases.rule.eval(cases.rule_inputs),
        actual,
        1e-15,
    );
}
