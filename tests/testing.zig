const std = @import("std");
const bombelli = @import("bombelli");

test "checkJacobian verifies model derivatives and declared input parameters" {
    const model = comptime bombelli.model(.{
        "scale*x^2 + sin(y)",
        "x*y + offset",
    }, .{
        .variables = .{ .x, .y },
        .inputs = .{ .scale, .offset },
    });
    const point = .{
        .x = @as(f64, 1.25),
        .y = @as(f64, -0.4),
        .scale = @as(f64, 3.0),
        .offset = @as(f64, 2.0),
    };

    const result = bombelli.testing.checkJacobian(model, point, .{});
    comptime std.debug.assert(@TypeOf(result.analytic) == [2][2]f64);
    comptime std.debug.assert(@TypeOf(result.numerical) == [2][2]f64);
    comptime std.debug.assert(@TypeOf(result.entries) ==
        [2][2]bombelli.testing.JacobianCheckEntry);

    try std.testing.expect(result.passed());
    try std.testing.expectEqual(@as(usize, 0), result.mismatch_count);
    try std.testing.expect(result.first_mismatch == null);
    try std.testing.expectEqual(@as(usize, 4), result.function_evaluations);
    try std.testing.expectEqual(@as(usize, 1), result.jacobian_evaluations);
    try std.testing.expectEqualStrings("x", result.entries[0][0].variable);
    try std.testing.expectEqualStrings("y", result.entries[1][1].variable);
    try std.testing.expectEqual(@as(usize, 0), result.entries[0][0].row);
    try std.testing.expectEqual(@as(usize, 1), result.entries[0][1].column);
    try std.testing.expectApproxEqAbs(7.5, result.analytic[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(
        @cos(@as(f64, -0.4)),
        result.analytic[0][1],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(-0.4, result.analytic[1][0], 1e-14);
    try std.testing.expectApproxEqAbs(1.25, result.analytic[1][1], 1e-14);
}

test "checkJacobian accepts ExprVector programs with explicit variables" {
    const outputs = comptime bombelli.exprVector(.{
        "x*y + sin(x)",
        "exp(y) - x",
    });
    const result = bombelli.testing.checkJacobian(
        outputs,
        .{ .x = @as(f64, 0.7), .y = @as(f64, -0.25) },
        .{ .variables = .{ .x, .y } },
    );

    try std.testing.expect(result.passed());
    try std.testing.expect(result.steps[0] > 0.0);
    try std.testing.expect(result.steps[1] > 0.0);
    try std.testing.expect(result.max_absolute_error < 1e-8);
    try std.testing.expect(result.worst_entry != null);
}

test "checkJacobian reports rich per-entry mismatch diagnostics" {
    const cubic = comptime bombelli.exprVector(.{"x^3"});
    const result = bombelli.testing.checkJacobian(
        cubic,
        .{ .x = @as(f64, 1.0) },
        .{
            .variables = .{.x},
            .relative_step = 0.0,
            .absolute_step = 0.1,
            .absolute_tolerance = 0.0,
            .relative_tolerance = 0.0,
        },
    );

    try std.testing.expect(!result.passed());
    try std.testing.expectEqual(@as(usize, 1), result.mismatch_count);
    const mismatch = result.first_mismatch.?;
    try std.testing.expectEqual(@as(usize, 0), mismatch.row);
    try std.testing.expectEqual(@as(usize, 0), mismatch.column);
    try std.testing.expectEqualStrings("x", mismatch.variable);
    try std.testing.expectApproxEqAbs(3.0, mismatch.analytic, 1e-14);
    try std.testing.expectApproxEqAbs(3.01, mismatch.numerical, 1e-13);
    try std.testing.expectApproxEqAbs(0.01, mismatch.absolute_error, 1e-13);
    try std.testing.expectEqual(@as(f64, 0.0), mismatch.allowed_error);
    try std.testing.expect(std.math.isPositiveInf(mismatch.normalized_error));
    try std.testing.expect(mismatch.analytic_finite);
    try std.testing.expect(mismatch.numerical_finite);
    try std.testing.expect(!mismatch.passed);
    try std.testing.expectEqualDeep(mismatch, result.worst_entry.?);
}

test "checkJacobian scales steps and preserves non-finite diagnostics" {
    const scaled = comptime bombelli.model(.{"x^2 + offset"}, .{
        .variables = .{.x},
        .inputs = .{.offset},
    });
    const scaled_result = bombelli.testing.checkJacobian(
        scaled,
        .{ .x = @as(f64, 1e8), .offset = @as(f64, 3.0) },
        .{},
    );
    try std.testing.expect(scaled_result.passed());
    try std.testing.expect(scaled_result.steps[0] > 600.0);
    try std.testing.expectApproxEqRel(
        @as(f64, 2e8),
        scaled_result.numerical[0][0],
        1e-10,
    );

    const square_root = comptime bombelli.exprVector(.{"sqrt(x)"});
    const non_finite = bombelli.testing.checkJacobian(
        square_root,
        .{ .x = @as(f64, 0.0) },
        .{ .variables = .{.x} },
    );
    try std.testing.expect(!non_finite.passed());
    const mismatch = non_finite.first_mismatch.?;
    try std.testing.expect(!mismatch.analytic_finite);
    try std.testing.expect(!mismatch.numerical_finite);
    try std.testing.expect(std.math.isPositiveInf(
        non_finite.max_absolute_error,
    ));
}
