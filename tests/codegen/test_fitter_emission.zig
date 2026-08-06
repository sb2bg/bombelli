const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted runtime-observation fitter matches direct compiled object" {
    var actual: generated.generated_fitterResult = undefined;
    generated.generated_fitter(cases.fitter_inputs, &actual);
    const expected = cases.fitter.eval(cases.fitter_inputs);

    try std.testing.expectEqual(
        @intFromEnum(expected.status),
        @intFromEnum(actual.status),
    );
    try std.testing.expectEqual(expected.iterations, actual.iterations);
    try std.testing.expectEqual(expected.rank, actual.rank);
    try std.testing.expectEqual(
        expected.function_evaluations,
        actual.function_evaluations,
    );
    try std.testing.expectApproxEqAbs(expected.values[0], actual.values[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected.values[1], actual.values[1], 1e-15);
    try std.testing.expectApproxEqAbs(expected.cost, actual.cost, 1e-15);
    try std.testing.expectApproxEqAbs(
        expected.gradient_norm,
        actual.gradient_norm,
        1e-15,
    );
}
