const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted Newton solver matches direct compiled object" {
    var actual: generated.generated_newtonResult = undefined;
    generated.generated_newton(cases.solver_inputs, &actual);
    const expected = cases.solver.eval(cases.solver_inputs);

    try std.testing.expectEqual(
        @intFromEnum(expected.status),
        @intFromEnum(actual.status),
    );
    try std.testing.expectEqual(expected.iterations, actual.iterations);
    try std.testing.expectApproxEqAbs(
        expected.values[0],
        actual.values[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        expected.values[1],
        actual.values[1],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        expected.residual_norm,
        actual.residual_norm,
        1e-20,
    );
}
