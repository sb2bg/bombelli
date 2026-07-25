const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const exact = @import("exact.zig");

pub const Expr = ast.Expr;
pub const ExprVector = ast.ExprVector;
pub const ExprMatrix = ast.ExprMatrix;
pub const Node = ast.Node;
pub const NodeId = ast.NodeId;
pub const Metrics = @import("metrics.zig").Metrics;
pub const Integer = exact.Integer;
pub const Rational = exact.Rational;
pub const Domain = @import("domain.zig").Domain;
pub const Assumption = @import("domain.zig").Assumption;
pub const Polynomial = @import("polynomial.zig").Polynomial;
pub const PolynomialTerm = @import("polynomial.zig").Term;
pub const RationalFunction = @import("rational_function.zig").RationalFunction;
pub const DenominatorCondition = @import("rational_function.zig").DenominatorCondition;
pub const positive = @import("domain.zig").positive;
pub const nonzero = @import("domain.zig").nonzero;
pub const Equation = @import("equation.zig").Equation;
pub const SolutionCondition = @import("solution_set.zig").Condition;
pub const SolutionRelation = @import("solution_set.zig").Relation;
pub const SolutionSet = @import("solution_set.zig").SolutionSet;
pub const SolveAlgorithm = @import("problem.zig").SolveAlgorithm;
pub const IntegrationAlgorithm = @import("integration.zig").IntegrationAlgorithm;
pub const IntegralBounds = @import("integration.zig").IntegralBounds;
pub const IntegralProblem = @import("integration.zig").IntegralProblem;
pub const PartialIntegral = @import("integration.zig").PartialIntegral;
pub const IntegrationProof = @import("integration.zig").Proof;
pub const IntegrationDiagnostic = @import("integration.zig").IntegrationDiagnostic;
pub const IntegrationResult = @import("integration.zig").IntegrationResult;
pub const QuadratureKind = @import("gauss_legendre.zig").QuadratureKind;
pub const QuadratureRule = @import("gauss_legendre.zig").QuadratureRule;
pub const AdaptiveQuadratureRule = @import("adaptive_quadrature.zig").AdaptiveQuadratureRule;
pub const AdaptiveQuadratureResult = @import("adaptive_quadrature.zig").AdaptiveResult;
pub const AdaptiveQuadratureStatus = @import("adaptive_quadrature.zig").AdaptiveStatus;

pub fn expr(comptime source: []const u8) Expr {
    return parser.parse(source);
}

pub fn rational(comptime numerator: Integer, comptime denominator: Integer) Rational {
    return Rational.init(numerator, denominator) catch |err| switch (err) {
        error.ZeroDenominator => @compileError("Bombelli rational denominator cannot be zero"),
        error.Overflow => @compileError("Bombelli rational does not fit fixed-width storage"),
    };
}

pub fn equation(comptime source: []const u8) Equation {
    return @import("equation.zig").parse(source);
}

pub fn system(
    comptime sources: anytype,
    comptime options: anytype,
) @import("system.zig").SystemType(@TypeOf(sources), @TypeOf(options)) {
    return @import("system.zig").make(sources, options);
}

pub fn equationProblem(
    comptime source: []const u8,
    comptime options: anytype,
) @import("system.zig").EquationProblemType(@TypeOf(options)) {
    return @import("system.zig").makeEquationProblem(source, options);
}

pub fn exprVector(comptime sources: anytype) ExprVector(ast.tupleLength(@TypeOf(sources))) {
    const N = ast.tupleLength(@TypeOf(sources));
    if (N == 0) @compileError("Bombelli expression vector expects at least one output");
    var expressions: [N]Expr = undefined;
    inline for (sources, 0..) |source, index| {
        expressions[index] = expr(source);
    }
    return @import("multi.zig").vector(N, expressions);
}

pub fn exprMatrix(comptime sources: anytype) ExprMatrix(
    ast.tupleLength(@TypeOf(sources)),
    matrixColumnCount(@TypeOf(sources)),
) {
    const R = ast.tupleLength(@TypeOf(sources));
    const C = matrixColumnCount(@TypeOf(sources));
    var expressions: [R][C]Expr = undefined;
    inline for (sources, 0..) |row, row_index| {
        if (ast.tupleLength(@TypeOf(row)) != C) {
            @compileError("Bombelli expression matrix rows must have equal lengths");
        }
        inline for (row, 0..) |source, column_index| {
            expressions[row_index][column_index] = expr(source);
        }
    }
    return @import("multi.zig").matrix(R, C, expressions);
}

fn matrixColumnCount(comptime T: type) usize {
    const info = @typeInfo(T).@"struct";
    if (!info.is_tuple or info.fields.len == 0) {
        @compileError("Bombelli expression matrix expects a non-empty tuple of rows");
    }
    const columns = ast.tupleLength(info.fields[0].type);
    if (columns == 0) {
        @compileError("Bombelli expression matrix expects at least one column");
    }
    return columns;
}

test "flagship compile-time symbolic derivative" {
    const f = comptime expr(
        \\sin(x * y) + x^3
    );
    const dx = comptime f.diff(.x).simplify();
    const source = comptime dx.render();

    try std.testing.expectEqualStrings("3 * x^2 + y * cos(x * y)", source);

    const points = [_]struct { x: f64, y: f64 }{
        .{ .x = 2.0, .y = 3.0 },
        .{ .x = -0.5, .y = 1.25 },
        .{ .x = 4.0, .y = -2.0 },
    };
    for (points) |point| {
        const actual = dx.eval(.{ .x = point.x, .y = point.y });
        const expected = point.y * @cos(point.x * point.y) + 3.0 * point.x * point.x;
        try std.testing.expectApproxEqAbs(expected, actual, 1e-12);
    }
}

test "product rule" {
    const derivative = comptime expr("x * sin(x)").diff(.x).simplify();
    try std.testing.expectEqualStrings("x * cos(x) + sin(x)", comptime derivative.render());

    for ([_]f64{ -2.0, 0.0, 0.75, 3.0 }) |x| {
        try std.testing.expectApproxEqAbs(
            @sin(x) + x * @cos(x),
            derivative.eval(.{ .x = x }),
            1e-12,
        );
    }
}

test "quotient rule" {
    const derivative = comptime expr("sin(x) / x").diff(.x).simplify();
    try std.testing.expectEqualStrings(
        "(x * cos(x) - sin(x)) / x^2",
        comptime derivative.render(),
    );

    for ([_]f64{ -2.0, 0.5, 1.0, 3.0 }) |x| {
        const expected = (x * @cos(x) - @sin(x)) / (x * x);
        try std.testing.expectApproxEqAbs(expected, derivative.eval(.{ .x = x }), 1e-12);
    }
}

test "chain rule" {
    const derivative = comptime expr("sin(x^2)").diff(.x).simplify();
    try std.testing.expectEqualStrings("2 * x * cos(x^2)", comptime derivative.render());

    for ([_]f64{ -2.0, 0.0, 0.5, 3.0 }) |x| {
        const expected = 2.0 * x * @cos(x * x);
        try std.testing.expectApproxEqAbs(expected, derivative.eval(.{ .x = x }), 1e-12);
    }
}

test "multi-stage gradient renders as clean arithmetic" {
    const gradient = comptime expr(
        "ln(1 + x^2 * y^2) + exp(sin(x * y))",
    ).diff(.x).simplify();

    try std.testing.expectEqualStrings(
        "y * cos(x * y) * exp(sin(x * y)) + 2 * x * y^2 / (x^2 * y^2 + 1)",
        comptime gradient.render(),
    );

    const x = 1.25;
    const y = 0.75;
    const expected = 2.0 * x * y * y / (1.0 + x * x * y * y) +
        y * @cos(x * y) * @exp(@sin(x * y));
    try std.testing.expectApproxEqAbs(
        expected,
        gradient.eval(.{ .x = x, .y = y }),
        1e-12,
    );
}

test "different variables" {
    const f = comptime expr("x^2 * y + y^2");
    const dx = comptime f.diff(.x).simplify();
    const dy = comptime f.diff(.y).simplify();

    for ([_]struct { x: f64, y: f64 }{
        .{ .x = 2.0, .y = 3.0 },
        .{ .x = -1.5, .y = 0.25 },
        .{ .x = 0.0, .y = -4.0 },
    }) |point| {
        try std.testing.expectApproxEqAbs(
            2.0 * point.x * point.y,
            dx.eval(.{ .x = point.x, .y = point.y }),
            1e-12,
        );
        try std.testing.expectApproxEqAbs(
            point.x * point.x + 2.0 * point.y,
            dy.eval(.{ .x = point.x, .y = point.y }),
            1e-12,
        );
    }
}

test "repeated differentiation" {
    const d2x = comptime expr("x^4")
        .diff(.x)
        .simplify()
        .diff(.x)
        .simplify();

    try std.testing.expectEqualStrings("12 * x^2", comptime d2x.render());
    for ([_]f64{ -3.0, 0.0, 0.5, 4.0 }) |x| {
        try std.testing.expectApproxEqAbs(12.0 * x * x, d2x.eval(.{ .x = x }), 1e-12);
    }
}

test "constant folding and identities" {
    const simplified = comptime expr(
        "(2 + 3) * x + 0 * y + (x^1 - x) + 7^0",
    ).simplify();
    try std.testing.expectEqualStrings("5 * x + 1", comptime simplified.render());
    try std.testing.expectApproxEqAbs(21.0, simplified.eval(.{ .x = 4.0 }), 1e-12);

    const constants = comptime expr(
        "sin(0) + cos(0) + exp(0) + ln(1) + 8 / 4",
    ).simplify();
    try std.testing.expectEqualStrings("4", comptime constants.render());
    try std.testing.expectApproxEqAbs(4.0, constants.eval(.{}), 1e-12);
}

test "minimum simplification rules" {
    const Case = struct {
        input: []const u8,
        expected: []const u8,
    };
    inline for ([_]Case{
        .{ .input = "x + 0", .expected = "x" },
        .{ .input = "0 + x", .expected = "x" },
        .{ .input = "x - 0", .expected = "x" },
        .{ .input = "x - x", .expected = "0" },
        .{ .input = "x * 0", .expected = "0" },
        .{ .input = "0 * x", .expected = "0" },
        .{ .input = "x * 1", .expected = "x" },
        .{ .input = "1 * x", .expected = "x" },
        .{ .input = "x / 1", .expected = "x" },
        .{ .input = "0 / x", .expected = "0 / x" },
        .{ .input = "-(2 + 3)", .expected = "-5" },
        .{ .input = "x^0", .expected = "1" },
        .{ .input = "x^1", .expected = "x" },
    }) |case| {
        const actual = comptime expr(case.input).simplify().render();
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "negation and remaining function derivatives" {
    const derivative = comptime expr("-cos(x) + exp(x) + ln(x)")
        .diff(.x)
        .simplify();
    try std.testing.expectEqualStrings(
        "sin(x) + exp(x) + 1 / x",
        comptime derivative.render(),
    );

    for ([_]f64{ 0.25, 1.0, 2.5 }) |x| {
        const expected = @sin(x) + @exp(x) + 1.0 / x;
        try std.testing.expectApproxEqAbs(expected, derivative.eval(.{ .x = x }), 1e-12);
    }
}

test "unary negation binds less tightly than power" {
    const negative_square = comptime expr("-x^2");
    const parenthesized_negative = comptime expr("(-x)^2");

    try std.testing.expectEqualStrings("-x^2", comptime negative_square.render());
    try std.testing.expectEqualStrings("(-x)^2", comptime parenthesized_negative.render());
    try std.testing.expectApproxEqAbs(-9.0, negative_square.eval(.{ .x = 3.0 }), 1e-12);
    try std.testing.expectApproxEqAbs(9.0, parenthesized_negative.eval(.{ .x = 3.0 }), 1e-12);
}

test "all supported functions and floating-point literals" {
    const f = comptime expr("sin(x) + cos(x) + exp(x) + ln(x) + 1.5e1 / x");
    const x = 2.5;
    const expected = @sin(x) + @cos(x) + @exp(x) + @log(x) + 15.0 / x;
    try std.testing.expectApproxEqAbs(expected, f.eval(.{ .x = x }), 1e-12);
}

test "commutative multiplication puts coefficients first" {
    const simplified = comptime expr("x * 3").simplify();
    try std.testing.expectEqualStrings("3 * x", comptime simplified.render());
}

test "expressions retain one node per repeated subtree" {
    const repeated = comptime expr("sin(x * y) + sin(x * y)");
    const metrics = comptime repeated.metrics();

    try std.testing.expectEqual(@as(usize, 5), metrics.node_count);
    try std.testing.expectEqual(
        @sizeOf(Expr) + 5 * @sizeOf(Node),
        metrics.backing_bytes,
    );
}

test "simplification stays proportional to a compact multiplication DAG" {
    const repeated_square = comptime blk: {
        var builder = @import("builder.zig").Builder{};
        var current = builder.symbol("x");
        for (0..11) |_| {
            current = builder.mul(current, current);
        }
        break :blk builder.finish(current, "x squared eleven times");
    };

    try std.testing.expectEqual(@as(usize, 12), repeated_square.metrics().node_count);
    const simplified = comptime repeated_square.simplify();
    try std.testing.expectEqualStrings("x^2048", comptime simplified.render());
    try std.testing.expectEqual(@as(usize, 2), simplified.metrics().node_count);
    try std.testing.expectApproxEqAbs(
        std.math.pow(f64, 1.001, 2048),
        simplified.eval(.{ .x = 1.001 }),
        1e-10,
    );
}

test "factor multiplicities beyond u32 preserve the compact DAG" {
    const repeated_square = comptime blk: {
        var builder = @import("builder.zig").Builder{};
        var current = builder.symbol("x");
        for (0..40) |_| {
            current = builder.mul(current, current);
        }
        break :blk builder.finish(current, "x squared forty times");
    };

    const simplified = comptime repeated_square.simplify();
    try std.testing.expect(simplified.metrics().node_count <= repeated_square.metrics().node_count);
    try std.testing.expectEqual(@as(f64, 1.0), simplified.eval(.{ .x = 1.0 }));
}

test "power factors have a canonical total order and combine" {
    const ascending = comptime expr("x^2 * x^3").simplify();
    const descending = comptime expr("x^3 * x^2").simplify();
    const cancellation = comptime expr("x^2 * x^3 - x^3 * x^2").simplify();

    try std.testing.expectEqualStrings("x^5", comptime ascending.render());
    try std.testing.expectEqualStrings(
        comptime ascending.render(),
        comptime descending.render(),
    );
    try std.testing.expectEqualStrings("0", comptime cancellation.render());
}

test "rendered floating-point literals preserve their type and round trip" {
    const original = comptime expr("2.0 * x + 1.0 / 0.0");
    const source = comptime original.render();
    const reparsed = comptime expr(source);

    try std.testing.expectEqualStrings("2.0 * x + 1.0 / 0.0", source);
    try std.testing.expectEqual(original.metrics().node_count, reparsed.metrics().node_count);
    try std.testing.expectEqualStrings(source, comptime reparsed.render());
}

test "multi-root programs share nodes and evaluate into caller storage" {
    const functions = comptime exprVector(.{
        "sin(x * y) + x",
        "sin(x * y) + y",
    });
    const rendered = comptime functions.render();
    try std.testing.expectEqualStrings("sin(x * y) + x", rendered[0]);
    try std.testing.expectEqualStrings("sin(x * y) + y", rendered[1]);

    // x, y, x*y, sin(x*y), the two distinct sums: the shared transcendental
    // is represented and evaluated exactly once across both roots.
    try std.testing.expectEqual(@as(usize, 6), comptime functions.metrics().node_count);

    var output: [2]f64 = undefined;
    functions.evalInto(&output, .{ .x = 2.0, .y = 3.0 });
    try std.testing.expectApproxEqAbs(@sin(6.0) + 2.0, output[0], 1e-12);
    try std.testing.expectApproxEqAbs(@sin(6.0) + 3.0, output[1], 1e-12);

    const scalar = comptime expr("x + 1");
    var scalar_output: f64 = undefined;
    scalar.evalInto(&scalar_output, .{ .x = 2.0 });
    try std.testing.expectEqual(@as(f64, 3.0), scalar_output);
}

test "gradient jacobian and hessian are typed shared programs" {
    const f = comptime expr("x^2 * y + sin(x * y)");
    const gradient = comptime f.gradient(.{ .x, .y }).simplify();
    const gradient_rendered = comptime gradient.render();
    try std.testing.expectEqualStrings("2 * x * y + y * cos(x * y)", gradient_rendered[0]);
    try std.testing.expectEqualStrings("x^2 + x * cos(x * y)", gradient_rendered[1]);

    const functions = comptime exprVector(.{ "x^2 + y", "x * y" });
    const jacobian = comptime functions.jacobian(.{ .x, .y }).simplify();
    const jacobian_rendered = comptime jacobian.render();
    try std.testing.expectEqualStrings("2 * x", jacobian_rendered[0][0]);
    try std.testing.expectEqualStrings("1", jacobian_rendered[0][1]);
    try std.testing.expectEqualStrings("y", jacobian_rendered[1][0]);
    try std.testing.expectEqualStrings("x", jacobian_rendered[1][1]);

    const hessian = comptime expr("x^2 + x * y + y^2")
        .hessian(.{ .x, .y })
        .simplify();
    const hessian_values = hessian.eval(.{ .x = 4.0, .y = -2.0 });
    try std.testing.expectEqualDeep([2][2]f64{
        .{ 2.0, 1.0 },
        .{ 1.0, 2.0 },
    }, hessian_values);
}

test "exact rationals have one canonical representation" {
    try std.testing.expectEqualDeep(
        Rational{ .numerator = 1, .denominator = 2 },
        comptime rational(2, 4),
    );
    try std.testing.expectEqualDeep(
        Rational{ .numerator = 1, .denominator = 2 },
        comptime rational(-2, -4),
    );
    try std.testing.expectEqualDeep(
        Rational{ .numerator = -1, .denominator = 2 },
        comptime rational(2, -4),
    );
    try std.testing.expectEqualDeep(
        Rational{ .numerator = 0, .denominator = 1 },
        comptime rational(0, -17),
    );
    try std.testing.expectEqualDeep(
        Rational{ .numerator = 1, .denominator = 1 },
        comptime rational(std.math.minInt(i64), std.math.minInt(i64)),
    );
}

test "exact constants stay rational until numerical evaluation" {
    const sum = comptime expr("1 / 3 + 1 / 6").simplify();
    try std.testing.expectEqualStrings("1/2", comptime sum.render());
    try std.testing.expectEqualDeep(
        Rational{ .numerator = 1, .denominator = 2 },
        sum.node(sum.root).rational,
    );
    try std.testing.expectApproxEqAbs(0.5, sum.eval(.{}), 0.0);

    const large = comptime expr("9007199254740993 / 3").simplify();
    try std.testing.expectEqualStrings("3002399751580331", comptime large.render());
    try std.testing.expectEqual(
        @as(i64, 3002399751580331),
        large.node(large.root).integer,
    );
}

test "rational powers are canonical and preserve exact bases" {
    const negative = comptime expr("x^-2").simplify();
    try std.testing.expectEqualStrings("x^-2", comptime negative.render());
    try std.testing.expectApproxEqAbs(0.25, negative.eval(.{ .x = 2.0 }), 0.0);

    const square_root = comptime expr("sqrt(2)").simplify();
    try std.testing.expectEqualStrings("2^(1/2)", comptime square_root.render());
    try std.testing.expect(square_root.node(square_root.root) == .pow);
    try std.testing.expectApproxEqAbs(@sqrt(2.0), square_root.eval(.{}), 1e-15);

    const real_cube_root = comptime expr("(-8)^(1/3)").simplify();
    try std.testing.expectApproxEqAbs(-2.0, real_cube_root.eval(.{}), 1e-15);
    const nonreal_square_root = comptime expr("sqrt(-1)").simplify();
    try std.testing.expect(std.math.isNan(nonreal_square_root.eval(.{})));
}

test "closure functions evaluate and differentiate" {
    const f = comptime expr("sqrt(x) + abs(y) + atan(z) + tan(z)");
    const actual = f.eval(.{ .x = 9.0, .y = -2.0, .z = 0.25 });
    const expected = 3.0 + 2.0 + std.math.atan(@as(f64, 0.25)) + @tan(0.25);
    try std.testing.expectApproxEqAbs(expected, actual, 1e-12);

    const square_root_derivative = comptime expr("sqrt(x)").diff(.x).simplify();
    try std.testing.expectEqualStrings(
        "x^(-1/2) / 2",
        comptime square_root_derivative.render(),
    );
    try std.testing.expectApproxEqAbs(
        0.25,
        square_root_derivative.eval(.{ .x = 4.0 }),
        1e-15,
    );

    const inverse_tangent_derivative = comptime expr("atan(x)").diff(.x).simplify();
    try std.testing.expectEqualStrings(
        "1 / (x^2 + 1)",
        comptime inverse_tangent_derivative.render(),
    );
    const tangent_derivative = comptime expr("tan(x)").diff(.x).simplify();
    try std.testing.expectEqualStrings(
        "1 / cos(x)^2",
        comptime tangent_derivative.render(),
    );
    const absolute_derivative = comptime expr("abs(x)").diff(.x).simplify();
    try std.testing.expectEqualStrings("x / abs(x)", comptime absolute_derivative.render());
}

test "canonical n-ary algebra flattens sorts and collects exact coefficients" {
    const Case = struct {
        input: []const u8,
        expected: []const u8,
    };
    inline for ([_]Case{
        .{ .input = "x + x", .expected = "2 * x" },
        .{ .input = "x / 3 + x / 6", .expected = "x / 2" },
        .{ .input = "2 * x + 3 * x", .expected = "5 * x" },
        .{ .input = "x * x * x", .expected = "x^3" },
        .{ .input = "(x + y) + z", .expected = "x + y + z" },
        .{ .input = "x * (y * z)", .expected = "x * y * z" },
        .{ .input = "x * 0", .expected = "0" },
        .{ .input = "x * 1", .expected = "x" },
        .{ .input = "x / x", .expected = "x / x" },
    }) |case| {
        const simplified = comptime expr(case.input).simplify();
        try std.testing.expectEqualStrings(case.expected, comptime simplified.render());
    }

    const ascending = comptime expr("(x + y) + z").simplify();
    const permuted = comptime expr("z + (y + x)").simplify();
    try std.testing.expectEqualStrings(
        comptime ascending.render(),
        comptime permuted.render(),
    );
    try std.testing.expect(ascending.node(ascending.root) == .add_nary);
    try std.testing.expectEqual(
        @as(usize, 3),
        ascending.node(ascending.root).add_nary.len,
    );

    const factored = comptime expr("z * (x + y)").simplify();
    try std.testing.expectEqualStrings("z * (x + y)", comptime factored.render());
}

test "substitution is a simultaneous memoized DAG rebuild" {
    const completed_square = comptime expr("x^2 + 2*x*y + y^2")
        .substitute(.{
            .y = expr("x"),
        })
        .simplify();
    try std.testing.expectEqualStrings("4 * x^2", comptime completed_square.render());

    const simultaneous = comptime expr("x - y")
        .substitute(.{
            .x = "y",
            .y = "x",
        })
        .simplify();
    try std.testing.expectApproxEqAbs(
        3.0,
        simultaneous.eval(.{ .x = 2.0, .y = 5.0 }),
        0.0,
    );

    const exact_replacement = comptime expr("a*x + b")
        .substitute(.{
            .a = rational(1, 3),
            .b = 2,
        })
        .simplify();
    try std.testing.expectEqualStrings("x / 3 + 2", comptime exact_replacement.render());

    const shared = comptime expr("sin(y) + cos(y)")
        .substitute(.{ .y = expr("x^2") });
    // x, x^2, sin(x^2), cos(x^2), and the sum. Both functions retain the
    // same replacement root rather than cloning it independently.
    try std.testing.expectEqual(@as(usize, 5), shared.metrics().node_count);

    const vector = comptime exprVector(.{ "x + y", "x * y" })
        .substitute(.{ .y = "x" })
        .simplify();
    const rendered = comptime vector.render();
    try std.testing.expectEqualStrings("2 * x", rendered[0]);
    try std.testing.expectEqualStrings("x^2", rendered[1]);
}

test "domains and assumptions are operation-local values" {
    const assumptions = .{
        positive(.x),
        nonzero(.a),
    };
    try std.testing.expectEqual(Domain.real, .real);
    try std.testing.expectEqualStrings("x", assumptions[0].symbol);
    try std.testing.expectEqualStrings("a", assumptions[1].symbol);
    try std.testing.expectEqual(
        @import("domain.zig").AssumptionKind.positive,
        assumptions[0].kind,
    );
    try std.testing.expectEqual(
        @import("domain.zig").AssumptionKind.nonzero,
        assumptions[1].kind,
    );
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

test "equations and systems preserve statements and explicit unknowns" {
    const parsed = comptime equation("x + 1 = y");
    try std.testing.expectEqualStrings("x + 1 = y", comptime parsed.render());
    try std.testing.expectApproxEqAbs(
        0.0,
        parsed.residual.eval(.{ .x = 2.0, .y = 3.0 }),
        0.0,
    );

    const problem_value = comptime system(.{
        "2*x + y = 7",
        "x - y = 2",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
        .assumptions = .{nonzero(.a)},
    });
    try std.testing.expectEqualStrings("x", problem_value.unknowns[0]);
    try std.testing.expectEqualStrings("y", problem_value.unknowns[1]);
    try std.testing.expectEqual(@as(usize, 2), problem_value.residuals.roots.len);
}

test "exact Gaussian elimination classifies linear systems" {
    const unique_problem = comptime system(.{
        "2*x + y = 7",
        "x - y = 2",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    });
    const unique = comptime unique_problem.solve(.gaussian).requireUnique();
    const unique_values = unique.eval(.{});
    try std.testing.expectEqualDeep([2]f64{ 3.0, 1.0 }, unique_values);

    const underdetermined = comptime system(.{
        "x + y = 4",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).solve(.gaussian);
    try std.testing.expect(underdetermined == .parametric);
    const parametric_values = underdetermined.parametric.values.eval(.{ .t0 = 1.5 });
    try std.testing.expectEqualDeep([2]f64{ 2.5, 1.5 }, parametric_values);

    const inconsistent = comptime system(.{
        "x = 1",
        "x = 2",
    }, .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.gaussian);
    try std.testing.expect(inconsistent == .empty);

    const identity = comptime system(.{
        "x = x",
    }, .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.gaussian);
    try std.testing.expect(identity == .all);
}

test "four by four exact systems and reusable factorizations" {
    const exact_problem = comptime system(.{
        "x + y = 3",
        "y + z = 5",
        "z + w = 7",
        "x + 2*w = 9",
    }, .{
        .unknowns = .{ .x, .y, .z, .w },
        .domain = .real,
    });
    const solved = comptime exact_problem.solve(.bareiss).requireUnique();
    try std.testing.expectEqualDeep(
        [4]f64{ 1.0, 2.0, 3.0, 4.0 },
        solved.eval(.{}),
    );

    const two_by_two = comptime system(.{
        "2*x + y = 0",
        "x - y = 0",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    });
    const factorization = comptime two_by_two.factor(.bareiss);
    const first = comptime factorization.solve(.{ 7, 2 }).requireUnique();
    const second = comptime factorization.solve(.{ 4, 1 }).requireUnique();
    try std.testing.expectEqualDeep([2]f64{ 3.0, 1.0 }, first.eval(.{}));
    try std.testing.expectEqualDeep([2]f64{ 5.0 / 3.0, 2.0 / 3.0 }, second.eval(.{}));
}

test "symbolic Bareiss solving records the determinant pivot condition" {
    const symbolic_problem = comptime system(.{
        "a*x + b*y = e",
        "c*x + d*y = f",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    });
    const result = comptime symbolic_problem.solve(.bareiss);
    try std.testing.expect(result == .conditional);
    try std.testing.expectEqual(
        @as(usize, 1),
        comptime result.conditional.conditions.len,
    );
    try std.testing.expectEqualStrings(
        "a * d - b * c != 0",
        comptime result.conditional.conditions[0].render(),
    );
    const values = result.conditional.values.eval(.{
        .a = 2.0,
        .b = 1.0,
        .c = 1.0,
        .d = -1.0,
        .e = 7.0,
        .f = 2.0,
    });
    try std.testing.expectApproxEqAbs(3.0, values[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.0, values[1], 1e-12);
}

test "polynomial equation solver returns exact and radical branches" {
    const rational_roots = comptime equationProblem("x^2 - 4 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial).requireFinite();
    try std.testing.expectEqual(@as(usize, 2), rational_roots.branch_count);
    const rational_first = comptime rational_roots.branch(0);
    const rational_second = comptime rational_roots.branch(1);
    try std.testing.expectEqual(
        @as(f64, -2.0),
        rational_first.eval(.{})[0],
    );
    try std.testing.expectEqual(
        @as(f64, 2.0),
        rational_second.eval(.{})[0],
    );

    const repeated = comptime equationProblem("(x - 1)^2 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial).requireUnique();
    try std.testing.expectEqual(@as(f64, 1.0), repeated.eval(.{})[0]);

    const radical = comptime equationProblem("x^2 - 2 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial).requireFinite();
    const radical_first = comptime radical.branch(0);
    const radical_second = comptime radical.branch(1);
    try std.testing.expectApproxEqAbs(
        -@sqrt(2.0),
        radical_first.eval(.{})[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        @sqrt(2.0),
        radical_second.eval(.{})[0],
        1e-12,
    );

    const no_real_roots = comptime equationProblem("x^2 + 1 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial);
    try std.testing.expect(no_real_roots == .empty);
}

test "solution sets can retain solved branches with an unresolved remainder" {
    const Set = SolutionSet(1);
    const roots = comptime equationProblem("x^2 - 1 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).solve(.polynomial).requireFinite();
    const result = comptime Set{ .partial = .{
        .solved = roots,
        .unresolved_equations = &.{"x^5 + y*x + 1 = 0"},
    } };

    try std.testing.expect(result == .partial);
    try std.testing.expectEqual(@as(usize, 2), result.partial.solved.branch_count);
    try std.testing.expectEqualStrings(
        "x^5 + y*x + 1 = 0",
        result.partial.unresolved_equations[0],
    );
}

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
}

test "integration by parts terminates as polynomial degree decreases" {
    const cases = .{
        "x^3 * exp(2*x)",
        "x^3 * sin(2*x + 1)",
        "x^3 * cos(2*x + 1)",
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
        const selected = comptime @import("gauss_legendre.zig").table(order);
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
