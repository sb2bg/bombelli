const std = @import("std");
const bombelli = @import("bombelli");

const expr = bombelli.expr;
const rational = bombelli.rational;
const nonzero = bombelli.nonzero;
const AdaptiveQuadratureStatus = bombelli.AdaptiveQuadratureStatus;

test "symbolic integration handles exact polynomials and rational powers" {
    const polynomial_integral = comptime expr("3*x^2 + 2*x + 1").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectEqualStrings(
        "x + x^2 + x^3",
        comptime polynomial_integral.render(),
    );

    const square_root = comptime expr("sqrt(x)").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        2.0 / 3.0,
        square_root.eval(.{ .x = 1.0 }),
        1e-12,
    );

    const reciprocal = comptime expr("1/x").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectEqualStrings(
        "ln(abs(x))",
        comptime reciprocal.render(),
    );

    const rational_power_coefficient = comptime expr(
        "(4/9)^(1/2) * sin(x)",
    ).integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        -2.0 / 3.0,
        rational_power_coefficient.eval(.{ .x = 0.0 }),
        1e-15,
    );
}

test "affine elementary integration uses operation-local assumptions" {
    const exact_slope = comptime expr("sin(2*x + 3)").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        -@cos(5.0) / 2.0,
        exact_slope.eval(.{ .x = 1.0 }),
        1e-12,
    );

    const without_assumption = comptime expr("exp(a*x + b)").integrate(.{
        .variable = .x,
        .domain = .real,
    });
    try std.testing.expect(without_assumption == .unsupported);

    const with_assumption = comptime expr("exp(a*x + b)").integrate(.{
        .variable = .x,
        .domain = .real,
        .assumptions = .{nonzero(.a)},
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        @exp(7.0) / 2.0,
        with_assumption.eval(.{ .x = 3.0, .a = 2.0, .b = 1.0 }),
        1e-12,
    );

    const hyperbolic = comptime expr(
        "sinh(2*x + 3) + cosh(2*x + 3)",
    ).integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        (std.math.cosh(@as(f64, 5.0)) + std.math.sinh(@as(f64, 5.0))) / 2.0,
        hyperbolic.eval(.{ .x = 1.0 }),
        1e-12,
    );
}

test "integration by parts terminates as polynomial degree decreases" {
    const cases = .{
        "x^3 * exp(2*x)",
        "x^3 * sin(2*x + 1)",
        "x^3 * cos(2*x + 1)",
        "x^3 * sinh(2*x + 1)",
        "x^3 * cosh(2*x + 1)",
    };
    inline for (cases) |source| {
        const original = comptime expr(source).simplify();
        const antiderivative = comptime original.integrate(.{
            .variable = .x,
            .domain = .real,
        }).unwrap().simplify();
        const recovered = comptime antiderivative.diff(.x).simplify();
        inline for (.{ -0.7, 0.25, 1.1 }) |x| {
            try std.testing.expectApproxEqRel(
                original.eval(.{ .x = x }),
                recovered.eval(.{ .x = x }),
                1e-11,
            );
        }
    }
}

test "partial integration preserves the unresolved integral problem" {
    const problem_value = comptime expr("3*x^2 + exp(x^2)").integral(.{
        .variable = .x,
        .domain = .real,
    });
    const result = comptime problem_value.solve(.symbolic);
    try std.testing.expect(result == .partial);
    try std.testing.expectEqualStrings(
        "x^3",
        comptime result.partial.closed_portion.render(),
    );
    try std.testing.expectEqualStrings(
        "exp(x^2)",
        comptime result.partial.remainder.integrand.render(),
    );
    try std.testing.expectEqualStrings(
        "x",
        result.partial.remainder.variable,
    );
}

test "complete definite integrals substitute exact and symbolic bounds" {
    const result = comptime expr("sin(x)").integrate(.{
        .variable = .x,
        .from = 0,
        .to = "y",
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        1.0 - @cos(0.75),
        result.eval(.{ .y = 0.75 }),
        1e-12,
    );
}

test "hardcoded Gauss-Legendre tables satisfy polynomial exactness" {
    @setEvalBranchQuota(100_000);
    inline for (.{ 4, 8, 16, 32 }) |order| {
        const selected = comptime bombelli.testing.gaussLegendreTable(order);
        inline for (0..2 * order) |degree| {
            var actual: f64 = 0.0;
            inline for (selected.nodes, selected.weights) |node, weight| {
                actual += weight * std.math.pow(
                    f64,
                    node,
                    @as(f64, @floatFromInt(degree)),
                );
            }
            const expected: f64 = if (degree % 2 == 0)
                2.0 / @as(f64, @floatFromInt(degree + 1))
            else
                0.0;
            try std.testing.expectApproxEqAbs(expected, actual, 5e-14);
        }
    }
}

test "fixed Gauss-Legendre quadrature specializes symbolic arithmetic" {
    const rule = comptime expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const value = rule.eval(.{
        .from = 0.0,
        .to = 1.0,
        .k = 2.0,
    });
    try std.testing.expectApproxEqAbs(
        0.5981440066613041,
        value,
        2e-15,
    );
}

test "fixed quadrature evaluates extended unary functions in lanes" {
    const rule = comptime expr(
        "asin(x) + acos(x) + sinh(x) + cosh(x) + tanh(x) + log2(x + 2) + log10(x + 2)",
    ).quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 32,
    });
    const value = rule.eval(.{
        .from = 0.0,
        .to = 0.5,
    });
    const upper = 2.5;
    const lower = 2.0;
    const logarithm_antiderivative_difference =
        upper * @log(upper) - upper -
        (lower * @log(lower) - lower);
    const expected = std.math.pi / 4.0 +
        std.math.cosh(@as(f64, 0.5)) - 1.0 +
        std.math.sinh(@as(f64, 0.5)) +
        @log(std.math.cosh(@as(f64, 0.5))) +
        logarithm_antiderivative_difference / @log(2.0) +
        logarithm_antiderivative_difference / @log(10.0);
    try std.testing.expectApproxEqAbs(expected, value, 2e-14);
}

test "vectorized fixed quadrature matches scalar node evaluation" {
    const integrand = comptime expr(
        "k*x^6 - 2*x^4/3 + 3*x^2/5 - 1",
    ).simplify();
    inline for (.{ 4, 8, 16, 32 }) |order| {
        const rule = comptime integrand.quadrature(.{
            .variable = .x,
            .rule = .gauss_legendre,
            .order = order,
        });
        const selected = comptime bombelli.testing.gaussLegendreTable(order);
        const from = -0.75;
        const to = 1.25;
        const midpoint = (from + to) * 0.5;
        const half_width = (to - from) * 0.5;
        var scalar_sum: f64 = 0.0;
        inline for (selected.nodes, selected.weights) |node, weight| {
            const point = midpoint + half_width * node;
            scalar_sum += weight * integrand.eval(.{ .x = point, .k = 1.7 });
        }
        try std.testing.expectApproxEqAbs(
            half_width * scalar_sum,
            rule.eval(.{ .from = from, .to = to, .k = 1.7 }),
            2e-15,
        );
    }
}

test "quadrature differentiation differentiates the fixed approximation" {
    const rule = comptime expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const derivative_rule = comptime rule.diff(.k);
    const direct_rule = comptime expr("-x^2 * exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const inputs = .{
        .from = 0.0,
        .to = 1.0,
        .k = 2.0,
    };
    try std.testing.expectApproxEqAbs(
        direct_rule.eval(inputs),
        derivative_rule.eval(inputs),
        1e-15,
    );
}

test "bounded adaptive quadrature reports convergence metadata" {
    const rule = comptime expr("exp(-100*x^2)").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 12,
        .tolerance = 1e-12,
    });
    const result = rule.eval(.{
        .from = -1.0,
        .to = 1.0,
    });
    try std.testing.expectEqual(
        AdaptiveQuadratureStatus.converged,
        result.status,
    );
    try std.testing.expectApproxEqAbs(
        @sqrt(std.math.pi / 100.0),
        result.value,
        2e-13,
    );
    try std.testing.expect(result.estimated_error <= 1e-12);
    try std.testing.expect(result.evaluations == result.intervals * 24);
    try std.testing.expect(result.intervals > 1);
}

test "bounded adaptive quadrature never hides depth exhaustion" {
    const rule = comptime expr("exp(20*x)").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 0,
        .tolerance = 1e-16,
    });
    const result = rule.eval(.{
        .from = 0.0,
        .to = 1.0,
    });
    try std.testing.expectEqual(
        AdaptiveQuadratureStatus.depth_exhausted,
        result.status,
    );
    try std.testing.expect(result.estimated_error > 1e-16);
    try std.testing.expectEqual(@as(usize, 24), result.evaluations);
}

test "bounded adaptive quadrature reports non-finite integrands" {
    const rule = comptime expr("ln(x)").adaptiveQuadrature(.{
        .variable = .x,
        .max_depth = 4,
        .tolerance = 1e-10,
    });
    const result = rule.eval(.{
        .from = -1.0,
        .to = 1.0,
    });
    try std.testing.expectEqual(
        AdaptiveQuadratureStatus.non_finite,
        result.status,
    );
}

test "compiled partial integrals quadrature only the unresolved remainder" {
    const symbolic = comptime expr("3*x^2 + exp(x^2)").integrate(.{
        .variable = .x,
        .from = 0,
        .to = 1,
        .domain = .real,
    });
    const compiled = comptime symbolic.compile(.{
        .rule = .gauss_legendre,
        .order = 32,
    });
    try std.testing.expectEqualStrings(
        "exp(x^2)",
        comptime compiled.remainder_rule.integrand.render(),
    );
    try std.testing.expectApproxEqAbs(
        2.4626517459071815,
        compiled.eval(.{}),
        3e-15,
    );
}

test "compiled partial integrals support runtime endpoints" {
    const symbolic = comptime expr("3*x^2 + exp(x^2)").integrate(.{
        .variable = .x,
        .domain = .real,
    });
    const compiled = comptime symbolic.compile(.{
        .rule = .gauss_legendre,
        .order = 32,
    });
    const full_rule = comptime expr("3*x^2 + exp(x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 32,
    });
    const inputs = .{ .from = 0.2, .to = 0.8 };
    try std.testing.expectApproxEqAbs(
        full_rule.eval(inputs),
        compiled.eval(inputs),
        2e-15,
    );
}

test "compiled partial integral differentiation preserves the fixed split" {
    const symbolic = comptime expr("x + exp(-k*x^2)").integrate(.{
        .variable = .x,
        .domain = .real,
    });
    const compiled = comptime symbolic.compile(.{
        .rule = .gauss_legendre,
        .order = 16,
    });
    const derivative = comptime compiled.diff(.k);
    const direct = comptime expr("-x^2 * exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const inputs = .{
        .from = 0.0,
        .to = 1.0,
        .k = 2.0,
    };
    try std.testing.expectApproxEqAbs(
        direct.eval(inputs),
        derivative.eval(inputs),
        1e-15,
    );
}
