const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted gradient matches direct compiled object" {
    var actual: [2]f64 = undefined;
    generated.generated_gradient(cases.gradient_inputs, &actual);
    const expected = cases.gradient.eval(cases.gradient_inputs);

    try std.testing.expectApproxEqAbs(expected[0], actual[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], 1e-15);
}
