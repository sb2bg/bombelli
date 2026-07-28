const std = @import("std");
const bombelli = @import("bombelli");

const expr = bombelli.expr;
const exprMatrix = bombelli.exprMatrix;
const exprVector = bombelli.exprVector;
const rational = bombelli.rational;
const Expr = bombelli.Expr;
const Rational = bombelli.Rational;
const nonzero = bombelli.nonzero;

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
    try std.testing.expect(metrics.backing_bytes > @sizeOf(Expr));
}

test "simplification stays proportional to a compact multiplication DAG" {
    const repeated_square = comptime blk: {
        var builder = bombelli.testing.Builder{};
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
        var builder = bombelli.testing.Builder{};
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

test "nested power simplification preserves real-domain restrictions" {
    const odd_root = comptime expr("(x^(1/3))^3").simplify();
    try std.testing.expectEqualStrings("x", comptime odd_root.render());
    const repeated_odd_root = comptime expr(
        "x^(1/3) * x^(1/3) * x^(1/3)",
    ).simplify();
    try std.testing.expectEqualStrings("x", comptime repeated_odd_root.render());

    const square_root = comptime expr("(x^(1/2))^2").simplify();
    try std.testing.expectEqualStrings("(x^(1/2))^2", comptime square_root.render());
    try std.testing.expect(std.math.isNan(square_root.eval(.{ .x = -1.0 })));
}

test "rendered floating-point literals preserve their type and round trip" {
    const original = comptime expr("2.0 * x + 1.0 / 0.0");
    const source = comptime original.render();
    const reparsed = comptime expr(source);

    try std.testing.expectEqualStrings("2.0 * x + 1.0 / 0.0", source);
    try std.testing.expectEqual(original.metrics().node_count, reparsed.metrics().node_count);
    try std.testing.expectEqualStrings(source, comptime reparsed.render());

    const huge = comptime expr("1e300");
    try std.testing.expectEqualStrings("1e300", comptime huge.render());
    try std.testing.expectEqualStrings(
        comptime huge.render(),
        comptime expr(huge.render()).render(),
    );
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

test "evalAs evaluates scalar vector and matrix programs in f32" {
    const scalar = comptime expr(
        "atan(x) + sqrt(y) + sin(x*y) + exp(x)/7 + ln(y) + pi",
    );
    const scalar_inputs = .{
        .x = @as(f32, 0.25),
        .y = @as(f32, 4.0),
    };
    const scalar_value = scalar.evalAs(f32, scalar_inputs);
    comptime std.debug.assert(@TypeOf(scalar_value) == f32);

    const expected_scalar: f32 = std.math.atan(@as(f32, 0.25)) +
        @sqrt(@as(f32, 4.0)) +
        @sin(@as(f32, 1.0)) +
        @exp(@as(f32, 0.25)) / 7.0 +
        @log(@as(f32, 4.0)) +
        std.math.pi;
    try std.testing.expectApproxEqAbs(expected_scalar, scalar_value, 2e-6);

    var scalar_output: f32 = undefined;
    scalar.evalIntoAs(f32, &scalar_output, scalar_inputs);
    try std.testing.expectEqual(scalar_value, scalar_output);

    const vector = comptime exprVector(.{
        "x + 1/3",
        "x^(1/3)",
    });
    const vector_value = vector.evalAs(f32, .{ .x = @as(f32, -8.0) });
    comptime std.debug.assert(@TypeOf(vector_value) == [2]f32);
    try std.testing.expectApproxEqAbs(@as(f32, -8.0 + 1.0 / 3.0), vector_value[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), vector_value[1], 1e-6);

    var vector_output: [2]f32 = undefined;
    vector.evalIntoAs(f32, &vector_output, .{ .x = @as(f32, -8.0) });
    try std.testing.expectEqualDeep(vector_value, vector_output);

    const matrix = comptime exprMatrix(.{
        .{ "x", "x^2" },
        .{ "2*x", "pi" },
    });
    const matrix_value = matrix.evalAs(f32, .{ .x = @as(f32, 1.5) });
    comptime std.debug.assert(@TypeOf(matrix_value) == [2][2]f32);
    try std.testing.expectEqualDeep([2][2]f32{
        .{ 1.5, 2.25 },
        .{ 3.0, std.math.pi },
    }, matrix_value);

    var matrix_output: [2][2]f32 = undefined;
    matrix.evalIntoAs(f32, &matrix_output, .{ .x = @as(f32, 1.5) });
    try std.testing.expectEqualDeep(matrix_value, matrix_output);
}

test "evalAs performs intermediate arithmetic in the requested type" {
    const precision_boundary = comptime expr("x + 1 - x");
    const x: f32 = 16_777_216.0;

    try std.testing.expectEqual(
        @as(f32, 0.0),
        precision_boundary.evalAs(f32, .{ .x = x }),
    );
    try std.testing.expectEqual(
        @as(f64, 1.0),
        precision_boundary.eval(.{ .x = x }),
    );
    try std.testing.expectEqual(
        precision_boundary.eval(.{ .x = x }),
        precision_boundary.evalAs(f64, .{ .x = x }),
    );
}

test "evalAs supports Zig floating-point scalar widths" {
    const program = comptime expr("x^(1/3) + 1/7");

    inline for (.{ f16, f32, f64, f80, f128 }) |T| {
        const value = program.evalAs(T, .{ .x = @as(T, -8.0) });
        comptime std.debug.assert(@TypeOf(value) == T);
        try std.testing.expectApproxEqAbs(
            @as(T, -2.0 + 1.0 / 7.0),
            value,
            @as(T, 0.002),
        );
    }
}

test "batch evaluation vectorizes SoA inputs and broadcasts scalar parameters" {
    const program = comptime expr(
        "sin(x*y) + exp((x-y)/k) + x^3/7 + sqrt(x^2+1)",
    ).simplify();
    const xs = [_]f64{ -1.4, -0.9, -0.2, 0.0, 0.35, 0.8, 1.25 };
    const ys = [_]f64{ 0.2, -0.5, 1.1, -0.7, 0.4, 1.3, -1.0 };
    var actual: [xs.len]f64 = undefined;

    try program.evalBatchInto(&actual, .{
        .x = &xs,
        .y = ys[0..],
        .k = 8.0,
    });

    for (actual, xs, ys) |batch_value, x, y| {
        try std.testing.expectApproxEqAbs(
            program.eval(.{ .x = x, .y = y, .k = 8.0 }),
            batch_value,
            2e-15,
        );
    }

    var wrong_length: [xs.len - 1]f64 = undefined;
    try std.testing.expectError(
        error.InputLengthMismatch,
        program.evalBatchInto(&wrong_length, .{
            .x = &xs,
            .y = ys[0..],
            .k = 8.0,
        }),
    );
}

test "batch evaluation supports vector math and mixed numeric inputs" {
    const program = comptime expr(
        "tan(x/4) + atan(x) + abs(x-1/4) + ln(x+2) + n + k",
    ).simplify();
    const xs = [_]f32{ -0.8, -0.25, 0.0, 0.45, 1.1 };
    const ns = [_]i16{ -2, 1, 0, 3, -1 };
    const k: f32 = 0.375;
    var actual: [xs.len]f64 = undefined;

    try program.evalBatchInto(&actual, .{
        .x = xs[0..],
        .n = &ns,
        .k = &k,
    });

    for (actual, xs, ns) |batch_value, x, n| {
        try std.testing.expectApproxEqAbs(
            program.eval(.{ .x = x, .n = n, .k = k }),
            batch_value,
            2e-15,
        );
    }
}

test "parallel batch evaluation partitions output without changing values" {
    const program = comptime expr(
        "sin(x*y) + cos(x+y) + exp((x-y)/8) + x^3/7 - 2*x*y",
    ).simplify();
    const count = 257;
    var xs: [count]f64 = undefined;
    var ys: [count]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, index| {
        x.* = @as(f64, @floatFromInt(index)) / 64.0 - 2.0;
        y.* = @as(f64, @floatFromInt((index * 37) % count)) / 80.0 - 1.5;
    }

    var sequential: [count]f64 = undefined;
    var parallel: [count]f64 = undefined;
    const inputs = .{ .x = xs[0..], .y = ys[0..] };
    try program.evalBatchInto(&sequential, inputs);
    try program.evalBatchParallelInto(&parallel, inputs, .{
        .max_threads = 4,
        .min_batch_len = 0,
        .min_items_per_thread = 1,
    });
    try std.testing.expectEqualDeep(sequential, parallel);
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

test "extended unary functions parse render and evaluate across scalar widths" {
    const functions = comptime exprVector(.{
        "asin(x)",
        "acos(x)",
        "sinh(x)",
        "cosh(x)",
        "tanh(x)",
        "log2(y)",
        "log10(y)",
    });
    const rendered = comptime functions.render();
    inline for (rendered, 0..) |source, index| {
        const expected = comptime [_][]const u8{
            "asin(x)",
            "acos(x)",
            "sinh(x)",
            "cosh(x)",
            "tanh(x)",
            "log2(y)",
            "log10(y)",
        };
        try std.testing.expectEqualStrings(expected[index], source);
    }
    try std.testing.expectEqual(
        @as(usize, 9),
        comptime functions.metrics().node_count,
    );

    const x: f64 = 0.25;
    const y: f64 = 4.0;
    const expected = [7]f64{
        std.math.asin(x),
        std.math.acos(x),
        std.math.sinh(x),
        std.math.cosh(x),
        std.math.tanh(x),
        @log2(y),
        @log10(y),
    };
    const actual = functions.eval(.{ .x = x, .y = y });
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 1e-15);
    }

    const portable = comptime expr(
        "asin(x) + acos(x) + sinh(x) + cosh(x) + tanh(x) + log2(y) + log10(y)",
    );
    const expected_sum = expected[0] + expected[1] + expected[2] +
        expected[3] + expected[4] + expected[5] + expected[6];
    inline for (.{ f16, f32, f64, f80, f128 }) |T| {
        const value = portable.evalAs(T, .{
            .x = @as(T, x),
            .y = @as(T, y),
        });
        comptime std.debug.assert(@TypeOf(value) == T);
        try std.testing.expectApproxEqAbs(
            @as(T, @floatCast(expected_sum)),
            value,
            @as(T, 0.004),
        );
    }

    const xs = [_]f64{ 0.1, 0.25, 0.5 };
    var batch: [xs.len]f64 = undefined;
    try portable.evalBatchInto(&batch, .{ .x = &xs, .y = y });
    for (xs, batch) |batch_x, value| {
        try std.testing.expectApproxEqAbs(
            portable.eval(.{ .x = batch_x, .y = y }),
            value,
            1e-15,
        );
    }
}

test "extended unary function derivatives are symbolic and composable" {
    const x: f64 = 0.25;
    const root = @sqrt(1.0 - x * x);
    const hyperbolic_cosine = std.math.cosh(x);
    const Case = struct {
        source: []const u8,
        rendered: []const u8,
    };
    const cases = comptime [_]Case{
        .{
            .source = "asin(x)",
            .rendered = "1 / (-x^2 + 1)^(1/2)",
        },
        .{
            .source = "acos(x)",
            .rendered = "-1 / (-x^2 + 1)^(1/2)",
        },
        .{
            .source = "sinh(x)",
            .rendered = "cosh(x)",
        },
        .{
            .source = "cosh(x)",
            .rendered = "sinh(x)",
        },
        .{
            .source = "tanh(x)",
            .rendered = "1 / cosh(x)^2",
        },
        .{
            .source = "log2(x)",
            .rendered = "1 / (x * ln(2))",
        },
        .{
            .source = "log10(x)",
            .rendered = "1 / (x * ln(10))",
        },
    };
    const expected = [7]f64{
        1.0 / root,
        -1.0 / root,
        hyperbolic_cosine,
        std.math.sinh(x),
        1.0 / (hyperbolic_cosine * hyperbolic_cosine),
        1.0 / (x * @log(2.0)),
        1.0 / (x * @log(10.0)),
    };
    inline for (cases, 0..) |case, index| {
        const derivative = comptime expr(case.source).diff(.x).simplify();
        try std.testing.expectEqualStrings(
            case.rendered,
            comptime derivative.render(),
        );
        try std.testing.expectApproxEqAbs(
            expected[index],
            derivative.eval(.{ .x = x }),
            1e-14,
        );
    }
}

test "extended unary functions simplify substitute and round trip" {
    const identities = comptime expr(
        "asin(0) + acos(1) + sinh(0) + cosh(0) + tanh(0) + log2(2) + log10(10)",
    ).simplify();
    try std.testing.expectEqualStrings("3", comptime identities.render());

    const folded = comptime expr(
        "asin(0.5) + acos(0.5) + sinh(0.5) + cosh(0.5) + tanh(0.5) + log2(8.0) + log10(100.0)",
    ).simplify();
    const expected = std.math.asin(@as(f64, 0.5)) +
        std.math.acos(@as(f64, 0.5)) +
        std.math.sinh(@as(f64, 0.5)) +
        std.math.cosh(@as(f64, 0.5)) +
        std.math.tanh(@as(f64, 0.5)) +
        @log2(8.0) +
        @log10(100.0);
    try std.testing.expectApproxEqAbs(expected, folded.eval(.{}), 1e-14);

    const source = comptime expr(
        "asin(x) + acos(x) + sinh(x) + cosh(x) + tanh(x) + log2(x) + log10(x)",
    );
    const substituted = comptime source.substitute(.{ .x = "y/2" });
    const y = 0.5;
    try std.testing.expectApproxEqAbs(
        source.eval(.{ .x = y / 2.0 }),
        substituted.eval(.{ .y = y }),
        1e-15,
    );
    const round_trip = comptime expr(substituted.render());
    try std.testing.expectEqualStrings(
        comptime substituted.render(),
        comptime round_trip.render(),
    );
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

    const rational_denominator = comptime expr("x/a")
        .substitute(.{ .a = rational(1, 3) });
    try std.testing.expectEqualStrings(
        "x / (1/3)",
        comptime rational_denominator.render(),
    );

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

test "pi is an exact symbolic constant" {
    const circumference = comptime expr("2 * pi * r");
    try std.testing.expectEqualStrings(
        "2 * pi * r",
        comptime circumference.simplify().render(),
    );
    try std.testing.expectApproxEqAbs(
        2.0 * std.math.pi * 3.0,
        circumference.eval(.{ .r = 3.0 }),
        1e-12,
    );

    const round_trip = comptime expr(expr("pi").render());
    try std.testing.expectEqual(std.math.pi, round_trip.eval(.{}));

    const area_derivative = comptime expr("pi * r^2").diff(.r).simplify();
    try std.testing.expectEqualStrings(
        "2 * pi * r",
        comptime area_derivative.render(),
    );
    try std.testing.expectApproxEqAbs(
        2.0 * std.math.pi * 2.0,
        area_derivative.eval(.{ .r = 2.0 }),
        1e-12,
    );

    // pi never becomes an eval input, and repeated uses share one node.
    const wave = comptime expr("sin(pi * x) + cos(pi * x)");
    try std.testing.expectApproxEqAbs(
        -1.0,
        wave.eval(.{ .x = 1.0 }),
        1e-12,
    );

    // pi is provably nonzero, so affine integration needs no assumption.
    const integral = comptime expr("exp(pi*x + 1)").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap().simplify();
    try std.testing.expectApproxEqAbs(
        @exp(std.math.pi + 1.0) / std.math.pi,
        integral.eval(.{ .x = 1.0 }),
        1e-11,
    );
}

test "batch evaluation vectorizes lane-friendly programs including the tail" {
    // Integer powers and rational arithmetic only: this is the shape that
    // takes the explicit-lane path, unlike the transcendental cases above.
    const program = comptime expr(
        "x^4/7 + y^3/5 + 3*x^2*y - 2*x*y^2 + x/11 - y/13",
    ).simplify();

    // A prime length guarantees a partial final vector.
    const count = 23;
    var xs: [count]f64 = undefined;
    var ys: [count]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, index| {
        x.* = @as(f64, @floatFromInt(index)) / 8.0 - 1.5;
        y.* = @as(f64, @floatFromInt((index * 13) % count)) / 6.0 - 2.0;
    }

    var actual: [count]f64 = undefined;
    try program.evalBatchInto(&actual, .{ .x = xs[0..], .y = ys[0..] });
    for (actual, xs, ys) |batch_value, x, y| {
        try std.testing.expectApproxEqAbs(
            program.eval(.{ .x = x, .y = y }),
            batch_value,
            2e-14,
        );
    }

    var parallel: [count]f64 = undefined;
    try program.evalBatchParallelInto(&parallel, .{
        .x = xs[0..],
        .y = ys[0..],
    }, .{
        .max_threads = 3,
        .min_batch_len = 0,
        .min_items_per_thread = 1,
    });
    try std.testing.expectEqualDeep(actual, parallel);
}
