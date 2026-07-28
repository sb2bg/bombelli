const std = @import("std");
const bombelli = @import("bombelli");

test "models unify evaluation differentiation and declared variables" {
    const rotation = comptime bombelli.model(.{
        "x*cos(theta) - y*sin(theta)",
        "x*sin(theta) + y*cos(theta)",
    }, .{
        .variables = .{ .x, .y, .theta },
    });

    const rotated = rotation.eval(.{
        .x = 1,
        .y = 0,
        .theta = std.math.pi / 2.0,
    });
    try std.testing.expectApproxEqAbs(0, rotated[0], 1e-15);
    try std.testing.expectApproxEqAbs(1, rotated[1], 1e-15);

    const jacobian = comptime rotation.jacobian();
    const actual = jacobian.eval(.{
        .x = 1,
        .y = 0,
        .theta = 0,
    });
    try std.testing.expectEqualDeep(
        [2][3]f64{
            .{ 1, 0, 0 },
            .{ 0, 1, 1 },
        },
        actual,
    );
}

test "models fuse value and Jacobian evaluation" {
    const model = comptime bombelli.model(.{
        "sin(x*y) + x^2",
        "sin(x*y) + y^2",
    }, .{
        .variables = .{ .x, .y },
    });
    const linearization = comptime model.linearize();
    const actual = linearization.eval(.{ .x = 0.5, .y = 2.0 });
    try std.testing.expectEqualDeep(
        model.eval(.{ .x = 0.5, .y = 2.0 }),
        actual.values,
    );
    const jacobian = comptime model.jacobian();
    try std.testing.expectEqualDeep(
        jacobian.eval(.{ .x = 0.5, .y = 2.0 }),
        actual.jacobian,
    );

    const typed = linearization.evalAs(
        f32,
        .{ .x = @as(f32, 0.5), .y = @as(f32, 2.0) },
    );
    try std.testing.expectEqual(@as(f32, @floatCast(actual.values[0])), typed.values[0]);

    const direct = model.valueAndJacobian(.{ .x = 0.5, .y = 2.0 });
    try std.testing.expectEqualDeep(actual, direct);

    const tangent = [2]f64{ 1.0, -1.0 };
    const jvp = linearization.jvp(
        .{ .x = 0.5, .y = 2.0 },
        tangent,
    );
    var expected_jvp: [2]f64 = undefined;
    for (0..2) |row| {
        expected_jvp[row] = actual.jacobian[row][0] -
            actual.jacobian[row][1];
    }
    try std.testing.expectEqualDeep(expected_jvp, jvp);

    const cotangent = [2]f64{ 2.0, -1.0 };
    const vjp = linearization.vjp(
        .{ .x = 0.5, .y = 2.0 },
        cotangent,
    );
    try std.testing.expectEqualDeep(
        [2]f64{
            2.0 * actual.jacobian[0][0] - actual.jacobian[1][0],
            2.0 * actual.jacobian[0][1] - actual.jacobian[1][1],
        },
        vjp,
    );
}

test "scalar model outputs compose with gradient transforms" {
    const objective = comptime bombelli.model(.{
        "x^2 + 3*x*y + y^2",
    }, .{
        .variables = .{ .x, .y },
    });
    const scalar = comptime objective.at(0);
    const gradient = comptime scalar.gradient(.{ .x, .y });
    try std.testing.expectEqualDeep(
        [2]f64{ 7, 8 },
        gradient.eval(.{ .x = 2, .y = 1 }),
    );
}

test "scalar model evaluates without extraction" {
    const objective = comptime bombelli.model(.{"x^2"}, .{
        .variables = .{.x},
    });
    try std.testing.expectEqualDeep([1]f64{4}, objective.eval(.{ .x = 2 }));
}

test "models preserve an explicit ordered data-input contract" {
    const affine = comptime bombelli.model(.{
        "slope*x + intercept",
    }, .{
        .variables = .{ .slope, .intercept },
        .inputs = .{.x},
    }).simplify();

    try std.testing.expectEqual(@as(usize, 1), affine.inputs.len);
    try std.testing.expectEqualStrings("x", affine.inputs[0]);
    try std.testing.expectEqualDeep(
        [1]f64{7},
        affine.eval(.{ .slope = 2, .intercept = 1, .x = 3 }),
    );
}

test "model transforms preserve variables and data ABI" {
    const polynomial = comptime bombelli.model(.{
        "a*x^2+b",
    }, .{
        .variables = .{.x},
        .inputs = .{ .a, .b },
    });
    const derivative = comptime polynomial.diff(.x).simplify();
    try std.testing.expectEqualDeep(
        [1]f64{12},
        derivative.eval(.{ .x = 3, .a = 2, .b = 7 }),
    );
    try std.testing.expectEqualStrings("x", derivative.variables[0]);
    try std.testing.expectEqualStrings("a", derivative.inputs[0]);

    const specialized = comptime polynomial
        .substitute(.{ .a = 2 })
        .simplify();
    try std.testing.expectEqualDeep(
        [1]f64{25},
        specialized.eval(.{ .x = 3, .a = 999, .b = 7 }),
    );
}

test "scalar model outputs compose with Hessian transforms" {
    const objective = comptime bombelli.model(.{
        "x^2 + 3*x*y + y^2",
    }, .{
        .variables = .{ .x, .y },
    });
    const scalar = comptime objective.at(0);
    const hessian = comptime scalar.hessian(.{ .x, .y });
    const actual = hessian.eval(.{ .x = 2, .y = 1 });
    try std.testing.expectEqualDeep(
        [2][2]f64{
            .{ 2, 3 },
            .{ 3, 2 },
        },
        actual,
    );
}

test "model least squares solves Rosenbrock residuals with augmented QR" {
    const problem = comptime bombelli.model(.{
        "10*(y-x^2)",
        "1-x",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares();
    const solver = comptime problem.compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .linear_solver = .qr,
        .max_iterations = 64,
        .tolerance = 1e-10,
    });
    const result = solver.eval(.{
        .initial = .{ .x = -1.2, .y = 1.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(1.0, result.values[0], 1e-8);
    try std.testing.expectApproxEqAbs(1.0, result.values[1], 1e-8);
    try std.testing.expect(result.cost < 1e-16);
    try std.testing.expect(result.function_evaluations >= result.accepted_steps + 1);
}

test "damped least squares supports rank-deficient and underdetermined models" {
    const duplicate = comptime bombelli.model(.{
        "x+y-1",
        "2*x+2*y-2",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 48,
    });
    const rank_deficient = duplicate.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expect(rank_deficient.converged());
    try std.testing.expectEqual(@as(usize, 1), rank_deficient.rank);
    try std.testing.expectApproxEqAbs(
        1.0,
        rank_deficient.values[0] + rank_deficient.values[1],
        1e-8,
    );

    const underdetermined = comptime bombelli.model(.{
        "x+y-1",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 48,
    });
    const result = underdetermined.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(0.5, result.values[0], 1e-7);
    try std.testing.expectApproxEqAbs(0.5, result.values[1], 1e-7);
}

test "least squares remains informative at extreme Jacobian scales" {
    const solver = comptime bombelli.model(.{
        "1e308*x - 1",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqRel(1e-308, result.values[0], 1e-8);
    try std.testing.expectApproxEqAbs(0.0, result.residuals[0], 1e-8);
    try std.testing.expect(result.function_evaluations > 1);
}

test "least squares robust losses resist scalar outliers" {
    const location = comptime bombelli.model(.{
        "x",
        "x",
        "x",
        "x-10",
    }, .{
        .variables = .{.x},
    }).leastSquares();
    const linear = comptime location.compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 48,
        .tolerance = 1e-10,
    });
    const robust = comptime location.compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .loss = bombelli.loss.huber(1.0),
        .max_iterations = 48,
        .tolerance = 1e-10,
        .function_tolerance = 1e-15,
    });
    const linear_result = linear.eval(.{
        .initial = .{ .x = 0.0 },
    });
    const robust_result = robust.eval(.{
        .initial = .{ .x = 0.0 },
    });
    try std.testing.expect(linear_result.converged());
    try std.testing.expect(robust_result.converged());
    try std.testing.expectApproxEqAbs(2.5, linear_result.values[0], 1e-8);
    try std.testing.expectApproxEqAbs(
        1.0 / 3.0,
        robust_result.values[0],
        1e-7,
    );
}

test "least squares honors upper and fixed box bounds" {
    const solver = comptime bombelli.model(.{
        "x-3",
        "y-5",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .bounds = .{
            .x = .{ .upper = 1.0 },
            .y = .{ .lower = 2.0, .upper = 2.0 },
        },
        .initial_bounds = .project,
        .max_iterations = 48,
        .tolerance = 1e-10,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(1.0, result.values[0], 1e-12);
    try std.testing.expectApproxEqAbs(2.0, result.values[1], 1e-12);
    try std.testing.expectEqualDeep([2]bool{ true, true }, result.active_bounds);
    try std.testing.expect(result.gradient_norm <= 1e-10);
}

test "least squares backtracks across a logarithm domain boundary" {
    const solver = comptime bombelli.model(.{
        "ln(x)+10",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 80,
        .tolerance = 1e-10,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 1.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqRel(@exp(-10.0), result.values[0], 1e-6);
    try std.testing.expect(
        result.function_evaluations > result.accepted_steps + 1,
    );
}

test "least squares refreshes diagnostics at the returned point" {
    const solver = comptime bombelli.model(.{
        "x-1",
        "y-2",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_iterations = 8,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 1.0, .y = 2.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectEqual(@as(usize, 2), result.rank);
    try std.testing.expectEqual(@as(usize, 1), result.jacobian_evaluations);
    try std.testing.expectEqual(@as(f64, 0.0), result.gradient_norm);
}

test "rank diagnostics do not alter the damped linear solve" {
    const solver = comptime bombelli.model(.{
        "x+y-1",
    }, .{
        .variables = .{ .x, .y },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .rank_tolerance = 0.1,
        .max_damping_trials = 1,
        .max_iterations = 16,
        .tolerance = 1e-10,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expect(result.converged());
    try std.testing.expectEqual(@as(usize, 1), result.rank);
    try std.testing.expectEqual(@as(usize, 0), result.rejected_steps);
}

test "last permitted step may satisfy gradient convergence" {
    const solver = comptime bombelli.model(.{
        "x-1",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .damping_tau = 1e-9,
        .max_iterations = 1,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0 },
    });
    try std.testing.expectEqual(
        bombelli.LeastSquaresStatus.converged_gradient,
        result.status,
    );
    try std.testing.expect(result.converged());
}

test "least squares reports lower bounds and rejects infeasible starts" {
    const problem = comptime bombelli.model(.{
        "x+2",
    }, .{
        .variables = .{.x},
    }).leastSquares();
    const solver = comptime problem.compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .bounds = .{ .x = .{ .lower = 0.0 } },
    });

    const active = solver.eval(.{
        .initial = .{ .x = 1.0 },
    });
    try std.testing.expect(active.converged());
    try std.testing.expectEqual(@as(f64, 0.0), active.values[0]);
    try std.testing.expect(active.active_bounds[0]);

    const rejected = solver.eval(.{
        .initial = .{ .x = -1.0 },
    });
    try std.testing.expectEqual(
        bombelli.LeastSquaresStatus.infeasible_initial,
        rejected.status,
    );
    try std.testing.expectEqual(@as(usize, 0), rejected.function_evaluations);
}

test "nonfinite initial residual counts its evaluation" {
    const solver = comptime bombelli.model(.{
        "ln(x)",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
    });
    const result = solver.eval(.{
        .initial = .{ .x = -1.0 },
    });
    try std.testing.expectEqual(
        bombelli.LeastSquaresStatus.non_finite_initial,
        result.status,
    );
    try std.testing.expectEqual(@as(usize, 1), result.function_evaluations);
}

test "projected optimality does not cancel at huge coordinates" {
    const solver = comptime bombelli.model(.{
        "x",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .loss = bombelli.loss.huber(1.0),
        .bounds = .{ .x = .{ .lower = 0.0 } },
        .max_iterations = 2,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 1e308 },
    });
    try std.testing.expect(!result.converged());
    try std.testing.expect(result.gradient_norm > 0.5);
}

test "user scales use characteristic parameter units" {
    const solver = comptime bombelli.model(.{
        "x-1",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .scaling = .user,
        .scales = .{ .x = 100.0 },
    });
    try std.testing.expectEqual(@as(f64, 0.01), solver.parameter_scales[0]);
}

test "least squares enforces a residual evaluation budget" {
    const solver = comptime bombelli.model(.{
        "x-10",
    }, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .max_function_evaluations = 1,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0 },
    });
    try std.testing.expectEqual(
        bombelli.LeastSquaresStatus.max_function_evaluations,
        result.status,
    );
    try std.testing.expectEqual(@as(usize, 1), result.function_evaluations);
}
