const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const Expr = ast.Expr;
pub const Node = ast.Node;
pub const NodeId = ast.NodeId;

pub fn expr(comptime source: []const u8) Expr {
    return parser.parse(source);
}

test "flagship compile-time symbolic derivative" {
    const f = comptime expr(
        \\sin(x * y) + x^3
    );
    const dx = comptime f.diff(.x).simplify();
    const source = comptime dx.render();

    try std.testing.expectEqualStrings("y * cos(x * y) + 3 * x^2", source);

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
    try std.testing.expectEqualStrings("sin(x) + x * cos(x)", comptime derivative.render());

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
        "2 * x * y^2 / (1 + x^2 * y^2) + y * cos(x * y) * exp(sin(x * y))",
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
        .{ .input = "0 / x", .expected = "0" },
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
