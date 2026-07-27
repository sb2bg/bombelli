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

test "callable helpers preserve compile-time-specialized structural interfaces" {
    const expression = comptime expr("x^2 + y");
    try std.testing.expectEqual(
        @as(f64, 7.0),
        callable.eval(expression, .{ .x = 2.0, .y = 3.0 }),
    );

    const emitted = comptime callable.emit(expression, .{
        .target = .zig,
        .mode = .out_of_place,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "pub fn bombelli_generated",
    ) != null);

    const rule = comptime expr("x^2").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 4,
    });
    try std.testing.expectApproxEqAbs(
        1.0 / 3.0,
        callable.eval(rule, .{ .from = 0.0, .to = 1.0 }),
        1e-15,
    );
    try std.testing.expect(callable.supports(@TypeOf(expression), "diff"));
    try std.testing.expect(callable.supports(@TypeOf(rule), "emit"));
}
