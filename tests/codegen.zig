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

test "human rendering modes remain separate from source emission" {
    const expression = comptime expr("sqrt(x) + x^2");
    try std.testing.expectEqualStrings(
        "x^(1/2) + x^2",
        comptime expression.renderMode(.canonical),
    );
    try std.testing.expectEqualStrings(
        "sqrt(x) + x^2",
        comptime expression.renderMode(.pretty),
    );
    try std.testing.expectEqualStrings(
        comptime expression.render(),
        comptime expression.renderMode(.canonical),
    );
}

test "Zig emission computes shared DAG nodes once" {
    const expression = comptime expr("sin(x*y) + sin(x*y) + x^3").simplify();
    const source = comptime expression.emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_expression",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn evaluate_expression(inputs: anytype, output: *f64)",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@sin("),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "switch (node") == null);

    const vector = comptime exprVector(.{
        "sin(x*y) + x",
        "sin(x*y) + y",
    }).simplify();
    const vector_source = comptime vector.emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_vector",
    });
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, vector_source, "@sin("),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        vector_source,
        "output[1]",
    ) != null);

    const exact_literal_source = comptime expr("9007199254740993").emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_exact_literal",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_literal_source,
        "9007199254740993",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_literal_source,
        "@floatFromInt",
    ) != null);

    const exact_rational_source = comptime expr(
        "9007199254740993 / 7",
    ).simplify().emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_exact_rational",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_rational_source,
        "9007199254740993",
    ) != null);

    const huge_float_source = comptime expr("1e300").emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_huge_float",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        huge_float_source,
        "1e300",
    ) != null);
    try std.testing.expect(huge_float_source.len < 2_000);
}

test "fixed quadrature Zig emission contains only the selected table" {
    const rule = comptime expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const source = comptime rule.emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "evaluate_integral",
    });
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "@exp("),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "weighted_sum +="),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "Builder") == null);
}

test "Newton Zig emission is standalone fixed-size numerical code" {
    const solver = comptime system(.{
        "x^2 + y^2 = r^2",
        "x - y = 0",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });
    const source = comptime solver.emit(.{
        .target = .zig,
        .mode = .out_of_place,
        .name = "solve_system",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn solve_system(inputs: anytype, output: *solve_systemResult)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "for (0..32) |iteration|",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "@import(\"bombelli\")",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
}
