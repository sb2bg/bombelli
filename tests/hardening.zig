const std = @import("std");
const bombelli = @import("bombelli");

test "constant invertible matrices with symbolic right hand sides are unconditional" {
    const result = comptime bombelli.system(.{
        "2*x + y = e",
        "x - y = f",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).solve(.bareiss);

    try std.testing.expect(result == .finite);
    const values = comptime result.requireUnique();
    const evaluated = values.eval(.{ .e = 7.0, .f = 2.0 });
    try std.testing.expectApproxEqAbs(3.0, evaluated[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, evaluated[1], 1e-15);
}

test "symbolic pivots retain exactly the unique-branch condition" {
    const result = comptime bombelli.system(.{
        "a*x + y = e",
        "x + a*y = f",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).solve(.bareiss);

    try std.testing.expect(result == .conditional);
    try std.testing.expectEqual(@as(usize, 1), result.conditional.conditions.len);
    const condition = result.conditional.conditions[0];
    try std.testing.expectEqual(bombelli.SolutionRelation.nonzero, condition.relation);
    try std.testing.expectEqual(
        @as(f64, 0.0),
        condition.expression.eval(.{ .a = 1.0 }),
    );
    try std.testing.expect(
        condition.expression.eval(.{ .a = 2.0 }) != 0.0,
    );
}

test "real rational powers expose invalid branches at the numerical boundary" {
    const cube_root = comptime bombelli.expr("x^(1/3)");
    const two_thirds = comptime bombelli.expr("x^(2/3)");
    const reciprocal_cube_root = comptime bombelli.expr("x^(-1/3)");
    const square_root = comptime bombelli.expr("sqrt(x)");

    try std.testing.expectApproxEqAbs(-2.0, cube_root.eval(.{ .x = -8.0 }), 1e-15);
    try std.testing.expectApproxEqAbs(4.0, two_thirds.eval(.{ .x = -8.0 }), 1e-15);
    try std.testing.expectApproxEqAbs(
        -0.5,
        reciprocal_cube_root.eval(.{ .x = -8.0 }),
        1e-15,
    );
    try std.testing.expect(std.math.isNan(square_root.eval(.{ .x = -1.0 })));
}

test "ln abs has the expected punctured-real derivative" {
    const logarithm = comptime bombelli.expr("ln(abs(x))");
    const derivative = comptime logarithm.diff(.x).simplify();

    inline for (.{ -3.0, -0.25, 0.4, 2.0 }) |x| {
        try std.testing.expectApproxEqAbs(
            1.0 / x,
            derivative.eval(.{ .x = x }),
            1e-14,
        );
    }
    try std.testing.expect(!std.math.isFinite(derivative.eval(.{ .x = 0.0 })));
}

test "removable singularities are never erased without their condition" {
    const uncancelled = comptime bombelli.expr("x/x").simplify();
    try std.testing.expectEqualStrings("x / x", comptime uncancelled.render());
    try std.testing.expect(std.math.isNan(uncancelled.eval(.{ .x = 0.0 })));

    const rational = comptime uncancelled.asRationalFunction();
    const one = comptime bombelli.expr("1").asRationalFunction();
    try std.testing.expectEqual(
        @as(usize, 1),
        rational.denominator_conditions.len,
    );
    try std.testing.expect(comptime !rational.eql(one));
}

test "partial integration preserves every unresolved term and original bounds" {
    const result = comptime bombelli.expr(
        "3*x^2 + exp(x^2) + sin(x^2)",
    ).integrate(.{
        .variable = .x,
        .from = 0,
        .to = 1,
        .domain = .real,
    });

    try std.testing.expect(result == .partial);
    try std.testing.expectEqualStrings(
        "1",
        comptime result.partial.closed_portion.render(),
    );
    try std.testing.expectEqualStrings(
        "sin(x^2) + exp(x^2)",
        comptime result.partial.remainder.integrand.render(),
    );
    try std.testing.expect(result.partial.remainder.bounds != null);
    try std.testing.expectEqual(
        @as(f64, 0.0),
        result.partial.remainder.bounds.?.from.eval(.{}),
    );
    try std.testing.expectEqual(
        @as(f64, 1.0),
        result.partial.remainder.bounds.?.to.eval(.{}),
    );
}

test "differentiated fixed quadrature agrees with finite differences of the rule" {
    const rule = comptime bombelli.expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const derivative = comptime rule.diff(.k);
    const h = 1e-5;
    const plus = rule.eval(.{ .from = 0.0, .to = 1.0, .k = 2.0 + h });
    const minus = rule.eval(.{ .from = 0.0, .to = 1.0, .k = 2.0 - h });
    const finite_difference = (plus - minus) / (2.0 * h);

    try std.testing.expectApproxEqAbs(
        finite_difference,
        derivative.eval(.{ .from = 0.0, .to = 1.0, .k = 2.0 }),
        2e-11,
    );
}

test "near-singular sensitivities and non-finite Newton inputs report status" {
    const solver = comptime bombelli.equationProblem("x^2 = p", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-20,
        .pivot_tolerance = 1e-14,
    });
    const sensitivity = comptime solver.diff(.p);
    const near_singular = sensitivity.eval(.{
        .initial = .{ .x = 1e-16 },
        .p = 1e-32,
    });
    try std.testing.expectEqual(
        bombelli.NewtonStatus.converged,
        near_singular.root.status,
    );
    try std.testing.expectEqual(
        bombelli.NewtonSensitivityStatus.singular_jacobian,
        near_singular.status,
    );

    const non_finite = solver.eval(.{
        .initial = .{ .x = std.math.nan(f64) },
        .p = 1.0,
    });
    try std.testing.expectEqual(
        bombelli.NewtonStatus.non_finite,
        non_finite.status,
    );
}

test "adaptive quadrature preserves orientation and explicit exhaustion" {
    const convergent = comptime bombelli.expr("x^2").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 4,
        .tolerance = 1e-12,
    }).eval(.{ .from = 1.0, .to = 0.0 });
    try std.testing.expectEqual(
        bombelli.AdaptiveQuadratureStatus.converged,
        convergent.status,
    );
    try std.testing.expectApproxEqAbs(-1.0 / 3.0, convergent.value, 1e-14);

    const exhausted = comptime bombelli.expr("exp(20*x)").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 0,
        .tolerance = 1e-16,
    }).eval(.{ .from = 0.0, .to = 1.0 });
    try std.testing.expectEqual(
        bombelli.AdaptiveQuadratureStatus.depth_exhausted,
        exhausted.status,
    );
    try std.testing.expect(exhausted.estimated_error > 1e-16);
}
