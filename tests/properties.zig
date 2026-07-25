const std = @import("std");
const bombelli = @import("bombelli");

const safe_points = [_]struct { x: f64, y: f64 }{
    .{ .x = -1.25, .y = 0.4 },
    .{ .x = -0.3, .y = 1.1 },
    .{ .x = 0.25, .y = -0.7 },
    .{ .x = 1.4, .y = 0.8 },
};

test "canonicalization is idempotent and canonical rendering round trips" {
    inline for (.{
        "x + x + y/3 + y/6",
        "(x + y) + (2*x - 3*y)",
        "x * (y * x) * (x^2)",
        "(x^2 + 1)^(-2) + 3/7",
        "sin(x*y) + cos(x+y) + exp(x/3-y/4)",
        "ln(x^2 + 2) + atan(x-y) + sqrt(x^2+1)",
    }) |source| {
        const canonical = comptime bombelli.expr(source).simplify();
        const canonical_again = comptime canonical.simplify();
        const reparsed = comptime bombelli.expr(canonical.render()).simplify();

        try std.testing.expectEqualStrings(
            comptime canonical.render(),
            comptime canonical_again.render(),
        );
        try std.testing.expectEqualStrings(
            comptime canonical.render(),
            comptime reparsed.render(),
        );

        // metrics() validates reachability, structural uniqueness, child order,
        // and construction-peak bounds at compile time.
        _ = comptime canonical.metrics();
        _ = comptime canonical_again.metrics();
        _ = comptime reparsed.metrics();

        for (safe_points) |point| {
            try std.testing.expectApproxEqRel(
                canonical.eval(point),
                reparsed.eval(point),
                1e-13,
            );
        }
    }
}

test "symbolic derivatives agree with centered finite differences" {
    inline for (.{
        "x^3 + 2*x*y - y^2 + 1/3",
        "sin(x*y) + cos(x+y)",
        "exp(x/3-y/4)",
        "ln(x^2+2)",
        "atan(x-y)",
        "sqrt(x^2+1)",
        "(x^2+1)^(-2)",
    }) |source| {
        const expression = comptime bombelli.expr(source).simplify();
        const derivative_x = comptime expression.diff(.x).simplify();
        const derivative_y = comptime expression.diff(.y).simplify();
        const h = 1e-6;

        for (safe_points) |point| {
            const finite_x = (expression.eval(.{
                .x = point.x + h,
                .y = point.y,
            }) - expression.eval(.{
                .x = point.x - h,
                .y = point.y,
            })) / (2.0 * h);
            const finite_y = (expression.eval(.{
                .x = point.x,
                .y = point.y + h,
            }) - expression.eval(.{
                .x = point.x,
                .y = point.y - h,
            })) / (2.0 * h);

            try std.testing.expectApproxEqAbs(
                finite_x,
                derivative_x.eval(point),
                2e-7,
            );
            try std.testing.expectApproxEqAbs(
                finite_y,
                derivative_y.eval(point),
                2e-7,
            );
        }
    }
}

test "closed symbolic antiderivatives differentiate back to their integrands" {
    inline for (.{
        "3*x^4 - 2*x^2 + x - 7",
        "x^(3/2)",
        "1/x",
        "sin(3*x+2)",
        "cos(2*x-1)",
        "exp(4*x+3)",
        "x^4*sin(2*x+1)",
        "x^3*cos(3*x-2)",
        "x^5*exp(2*x)",
    }) |source| {
        const integrand = comptime bombelli.expr(source).simplify();
        const antiderivative = comptime integrand.integrate(.{
            .variable = .x,
            .domain = .real,
        }).unwrap().simplify();
        const recovered = comptime antiderivative.diff(.x).simplify();

        inline for (.{ 0.2, 0.7, 1.3, 2.1 }) |x| {
            try std.testing.expectApproxEqAbs(
                integrand.eval(.{ .x = x }),
                recovered.eval(.{ .x = x }),
                2e-10,
            );
        }
    }
}

test "exact linear solutions annihilate residuals and reconstruct right hand sides" {
    const problem = comptime bombelli.system(.{
        "2*x - y + z = 7",
        "x + 3*y - 2*z = -4",
        "3*x + y + z = 10",
    }, .{
        .unknowns = .{ .x, .y, .z },
        .domain = .real,
    });
    const solution = comptime problem.solve(.bareiss).requireUnique();
    const solved = solution.eval(.{});

    inline for (0..3) |row| {
        const residual = comptime problem.residuals.at(row).substitute(.{
            .x = solution.at(0),
            .y = solution.at(1),
            .z = solution.at(2),
        }).simplify();
        try std.testing.expectEqualStrings("0", comptime residual.render());
        try std.testing.expectEqual(@as(f64, 0.0), residual.eval(.{}));
    }

    try std.testing.expectApproxEqAbs(7.0, 2.0 * solved[0] - solved[1] + solved[2], 1e-14);
    try std.testing.expectApproxEqAbs(-4.0, solved[0] + 3.0 * solved[1] - 2.0 * solved[2], 1e-14);
    try std.testing.expectApproxEqAbs(10.0, 3.0 * solved[0] + solved[1] + solved[2], 1e-14);
}

test "multi-root programs retain sharing and evalInto matches eval" {
    const outputs = comptime bombelli.exprVector(.{
        "sin(x*y) + x",
        "sin(x*y) + y",
        "sin(x*y)^2",
        "cos(x*y)",
    }).simplify();
    const metrics = comptime outputs.metrics();
    var sin_nodes: usize = 0;
    for (outputs.nodes) |node| {
        if (node == .sin) sin_nodes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), sin_nodes);
    try std.testing.expect(metrics.node_count < 16);

    const point = .{ .x = 0.75, .y = -1.2 };
    const returned = outputs.eval(point);
    var written: [4]f64 = undefined;
    outputs.evalInto(&written, point);
    try std.testing.expectEqualDeep(returned, written);

    const jacobian = comptime outputs.jacobian(.{ .x, .y }).simplify();
    _ = comptime jacobian.metrics();
    var matrix_written: [4][2]f64 = undefined;
    jacobian.evalInto(&matrix_written, point);
    try std.testing.expectEqualDeep(jacobian.eval(point), matrix_written);
}
