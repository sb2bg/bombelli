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

    var empty_actual: generated.generated_fitterResult = undefined;
    const empty_inputs = .{
        .initial = cases.fitter_inputs.initial,
        .observations = cases.fit_observations[0..0],
    };
    generated.generated_fitter(empty_inputs, &empty_actual);
    const empty_expected = cases.fitter.eval(empty_inputs);
    try std.testing.expectEqual(
        @intFromEnum(empty_expected.status),
        @intFromEnum(empty_actual.status),
    );

    var infeasible_actual: generated.generated_fitterResult = undefined;
    const infeasible_inputs = .{
        .initial = .{ .offset = 0.5, .slope = -0.5 },
        .observations = cases.fit_observations[0..],
    };
    generated.generated_fitter(infeasible_inputs, &infeasible_actual);
    const infeasible_expected = cases.fitter.eval(infeasible_inputs);
    try std.testing.expectEqual(
        @intFromEnum(infeasible_expected.status),
        @intFromEnum(infeasible_actual.status),
    );

    var bad_observations = cases.fit_observations;
    bad_observations[2].y = std.math.nan(f64);
    var nonfinite_actual: generated.generated_fitterResult = undefined;
    const nonfinite_inputs = .{
        .initial = cases.fitter_inputs.initial,
        .observations = bad_observations[0..],
    };
    generated.generated_fitter(nonfinite_inputs, &nonfinite_actual);
    const nonfinite_expected = cases.fitter.eval(nonfinite_inputs);
    try std.testing.expectEqual(
        @intFromEnum(nonfinite_expected.status),
        @intFromEnum(nonfinite_actual.status),
    );
}
