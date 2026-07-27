const std = @import("std");
const bombelli = @import("bombelli");

const expr = bombelli.expr;
const exprVector = bombelli.exprVector;
const exprMatrix = bombelli.exprMatrix;
const rational = bombelli.rational;
const equation = bombelli.equation;
const system = bombelli.system;
const equationProblem = bombelli.equationProblem;
const Expr = bombelli.Expr;
const Rational = bombelli.Rational;
const Domain = bombelli.Domain;
const positive = bombelli.positive;
const nonzero = bombelli.nonzero;
const SolutionSet = bombelli.SolutionSet;
const AdaptiveQuadratureStatus = bombelli.AdaptiveQuadratureStatus;
const NewtonStatus = bombelli.NewtonStatus;
const NewtonSensitivityStatus = bombelli.NewtonSensitivityStatus;
const callable = bombelli.callable;

test "domains and assumptions are operation-local values" {
    const assumptions = .{
        positive(.x),
        nonzero(.a),
    };
    try std.testing.expectEqual(Domain.real, .real);
    try std.testing.expectEqualStrings("x", assumptions[0].symbol);
    try std.testing.expectEqualStrings("a", assumptions[1].symbol);
    try std.testing.expect(assumptions[0].kind == .positive);
    try std.testing.expect(assumptions[1].kind == .nonzero);
}

test "sparse exact polynomial conversion algebra and expansion" {
    const factored = comptime expr("(x + y)^3").asPolynomial();
    try std.testing.expectEqual(@as(?u32, 3), comptime factored.degree());
    try std.testing.expectEqual(@as(usize, 2), comptime factored.variables().len);
    try std.testing.expectEqualStrings("x", comptime factored.variables()[0]);
    try std.testing.expectEqualStrings("y", comptime factored.variables()[1]);
    try std.testing.expectEqual(
        comptime rational(3, 1),
        comptime factored.coefficient(.{ .x = 2, .y = 1 }),
    );
    try std.testing.expect(comptime !factored.isLinear());

    const expanded_input = comptime expr("x^3 + 3*x^2*y + 3*x*y^2 + y^3")
        .asPolynomial();
    try std.testing.expect(comptime factored.eql(expanded_input));

    const derivative = comptime factored.diff(.x);
    const expected_derivative = comptime expr("3*x^2 + 6*x*y + 3*y^2")
        .asPolynomial();
    try std.testing.expect(comptime derivative.eql(expected_derivative));
    try std.testing.expect(
        comptime derivative.antiderivative(.x).diff(.x).eql(derivative),
    );

    const linear = comptime expr("2*x - y + 4").asPolynomial();
    try std.testing.expect(comptime linear.isLinear());
    try std.testing.expect(
        comptime linear.add(linear).sub(linear).eql(linear),
    );

    const expanded = comptime expr("(x + y)^3").expand();
    try std.testing.expect(comptime expanded.asPolynomial().eql(factored));
    try std.testing.expectApproxEqAbs(
        125.0,
        expanded.eval(.{ .x = 2.0, .y = 3.0 }),
        0.0,
    );
}

test "normalized rational functions preserve denominator conditions" {
    const uncancelled = comptime expr("x / x").asRationalFunction();
    try std.testing.expectEqual(
        @as(usize, 1),
        comptime uncancelled.denominator_conditions.len,
    );
    try std.testing.expectEqualStrings(
        "x / x",
        comptime uncancelled.toExpr().render(),
    );

    const normalized = comptime expr("(2*x) / (2*y)").asRationalFunction();
    try std.testing.expectEqualStrings(
        "x / y",
        comptime normalized.toExpr().render(),
    );

    const first = comptime expr("1 / x").asRationalFunction();
    const second = comptime expr("2 / (2*x)").asRationalFunction();
    try std.testing.expect(comptime first.eql(second));

    const combined = comptime first.add(first);
    const combined_expression = comptime combined.toExpr();
    try std.testing.expectApproxEqAbs(
        1.0,
        combined_expression.eval(.{ .x = 2.0 }),
        0.0,
    );
    try std.testing.expect(
        comptime combined.denominator_conditions.len >= 1,
    );
}

test "sparse polynomials support exact multivariate division" {
    const dividend = comptime expr("a*b + a*c").asPolynomial();
    const divisor = comptime expr("a").asPolynomial();
    const quotient = comptime dividend.divideExact(divisor).?;
    try std.testing.expect(
        comptime quotient.eql(expr("b + c").asPolynomial()),
    );
    try std.testing.expect(
        comptime expr("a + b").asPolynomial()
            .divideExact(expr("a").asPolynomial()) == null,
    );
}
