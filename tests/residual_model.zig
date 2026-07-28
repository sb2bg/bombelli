const std = @import("std");
const bombelli = @import("bombelli");

const residualModel = bombelli.residualModel;

test "residual row models evaluate and linearize one observation" {
    const model = comptime residualModel(.{
        "a*x + b - y",
    }, .{
        .variables = .{ .a, .b },
        .data = .{ .x, .y },
    });
    const inputs = .{ .a = 2.0, .b = 1.0, .x = 3.0, .y = 6.5 };
    const values = model.eval(inputs);
    try std.testing.expectApproxEqAbs(0.5, values[0], 0.0);

    const linearized = model.valueAndJacobian(inputs);
    try std.testing.expectEqual(values, linearized.values);
    try std.testing.expectEqualDeep(
        [1][2]f64{.{ 3.0, 1.0 }},
        linearized.jacobian,
    );
    try std.testing.expectEqualStrings(
        "b - y + a * x",
        comptime model.at(0).simplify().render(),
    );
}

test "runtime observation model fits linear regression without allocation" {
    const Observation = struct {
        x: f64,
        y: f64,
        metadata: u8,
    };
    const observations = [_]Observation{
        .{ .x = 0.0, .y = 1.0, .metadata = 10 },
        .{ .x = 1.0, .y = 3.0, .metadata = 11 },
        .{ .x = 2.0, .y = 5.0, .metadata = 12 },
        .{ .x = 3.0, .y = 7.0, .metadata = 13 },
    };

    const model = comptime residualModel(.{
        "a*x + b - y",
    }, .{
        .variables = .{ .a, .b },
        .data = .{ .x, .y },
    });
    const solver = comptime model.leastSquares().compile(.{
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{
        .initial = .{ .a = 0.0, .b = 0.0 },
        .observations = observations[0..],
    });

    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(2.0, result.values[0], 1e-10);
    try std.testing.expectApproxEqAbs(1.0, result.values[1], 1e-10);
    try std.testing.expectApproxEqAbs(0.0, result.cost, 1e-20);
    try std.testing.expectEqual(observations.len, result.observation_count);
    try std.testing.expectEqual(observations.len, result.residual_count);
    try std.testing.expectEqual(@as(usize, 2), result.rank);
}

test "runtime observation model fits nonlinear exponential data" {
    const Observation = struct { x: f64, y: f64 };
    var observations: [16]Observation = undefined;
    for (&observations, 0..) |*observation, index| {
        const x = @as(f64, @floatFromInt(index)) / 4.0;
        observation.* = .{
            .x = x,
            .y = 2.5 * @exp(-0.7 * x),
        };
    }

    const solver = comptime residualModel(.{
        "a*exp(b*x) - y",
    }, .{
        .variables = .{ .a, .b },
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .tolerance = 1e-12,
        .max_iterations = 100,
    });
    const result = solver.eval(.{
        .initial = .{ .a = 1.0, .b = -0.1 },
        .observations = &observations,
    });

    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(2.5, result.values[0], 1e-9);
    try std.testing.expectApproxEqAbs(-0.7, result.values[1], 1e-9);
    try std.testing.expect(result.cost < 1e-20);
}

test "runtime observation model supports robust losses" {
    const Observation = struct { y: f64 };
    const observations = [_]Observation{
        .{ .y = 1.0 },
        .{ .y = 1.0 },
        .{ .y = 1.0 },
        .{ .y = 1.0 },
        .{ .y = 100.0 },
    };
    const problem = comptime residualModel(.{
        "location - y",
    }, .{
        .variables = .{.location},
        .data = .{.y},
    }).leastSquares();
    const linear_solver = comptime problem.compile(.{
        .tolerance = 1e-12,
    });
    const robust_solver = comptime problem.compile(.{
        .tolerance = 1e-12,
        .loss = bombelli.loss.cauchy(1.0),
    });
    const inputs = .{
        .initial = .{ .location = 0.0 },
        .observations = &observations,
    };
    const linear = linear_solver.eval(inputs);
    const robust = robust_solver.eval(inputs);

    try std.testing.expect(linear.converged());
    try std.testing.expect(robust.converged());
    try std.testing.expectApproxEqAbs(20.8, linear.values[0], 1e-8);
    try std.testing.expect(@abs(robust.values[0] - 1.0) < 0.01);
}

test "runtime observation model enforces parameter bounds" {
    const Observation = struct { x: f64, y: f64 };
    const observations = [_]Observation{
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 2.0, .y = 4.0 },
        .{ .x = 3.0, .y = 6.0 },
    };
    const solver = comptime residualModel(.{
        "a*x - y",
    }, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .tolerance = 1e-12,
        .bounds = .{
            .a = .{ .lower = 0.0, .upper = 1.0 },
        },
    });
    const result = solver.eval(.{
        .initial = .{ .a = 0.0 },
        .observations = observations,
    });

    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(1.0, result.values[0], 0.0);
    try std.testing.expectEqual(
        bombelli.RowLeastSquaresBoundActivity.upper,
        result.active_bounds[0],
    );
}

test "runtime observation model reports rank and residual block counts" {
    const Observation = struct { x: f64, y: f64, z: f64 };
    const observations = [_]Observation{
        .{ .x = 1.0, .y = 3.0, .z = -2.0 },
        .{ .x = 2.0, .y = 6.0, .z = -4.0 },
        .{ .x = 3.0, .y = 9.0, .z = -6.0 },
    };
    const solver = comptime residualModel(.{
        "a*x - y",
        "b*x - z",
    }, .{
        .variables = .{ .a, .b },
        .data = .{ .x, .y, .z },
    }).leastSquares().compile(.{
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{
        .initial = .{ .a = 0.0, .b = 0.0 },
        .observations = &observations,
    });

    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(3.0, result.values[0], 1e-10);
    try std.testing.expectApproxEqAbs(-2.0, result.values[1], 1e-10);
    try std.testing.expectEqual(@as(usize, 6), result.residual_count);
    try std.testing.expectEqual(@as(usize, 2), result.rank);
}

test "runtime observation model honors configured rank tolerance" {
    const Observation = struct { y: f64, z: f64 };
    const observations = [_]Observation{
        .{ .y = 2.0, .z = 3e-8 },
        .{ .y = 2.0, .z = 3e-8 },
    };
    const problem = comptime residualModel(.{
        "a - y",
        "1e-8*b - z",
    }, .{
        .variables = .{ .a, .b },
        .data = .{ .y, .z },
    }).leastSquares();
    const full_rank_solver = comptime problem.compile(.{
        .tolerance = 1e-12,
        .rank_tolerance = 1e-12,
        .scaling = .user,
        .scales = .{ .a = 1.0, .b = 1.0 },
    });
    const numerical_rank_solver = comptime problem.compile(.{
        .tolerance = 1e-12,
        .rank_tolerance = 1e-6,
        .scaling = .user,
        .scales = .{ .a = 1.0, .b = 1.0 },
    });
    const inputs = .{
        .initial = .{ .a = 0.0, .b = 0.0 },
        .observations = &observations,
    };
    const full_rank = full_rank_solver.eval(inputs);
    const numerical_rank = numerical_rank_solver.eval(inputs);

    try std.testing.expectEqual(@as(usize, 2), full_rank.rank);
    try std.testing.expectEqual(@as(usize, 1), numerical_rank.rank);
}

test "runtime observation model returns explicit data failures" {
    const solver = comptime residualModel(.{
        "a*x - y",
    }, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    }).leastSquares().compile(.{});
    const Observation = struct { x: f64, y: f64 };
    const empty = [_]Observation{};
    const empty_result = solver.eval(.{
        .initial = .{ .a = 1.0 },
        .observations = &empty,
    });
    try std.testing.expectEqual(
        bombelli.RowLeastSquaresStatus.empty_observations,
        empty_result.status,
    );

    const non_finite = [_]Observation{
        .{ .x = std.math.nan(f64), .y = 1.0 },
    };
    const non_finite_result = solver.eval(.{
        .initial = .{ .a = 1.0 },
        .observations = &non_finite,
    });
    try std.testing.expectEqual(
        bombelli.RowLeastSquaresStatus.non_finite_observation,
        non_finite_result.status,
    );
    try std.testing.expectEqual(@as(usize, 0), non_finite_result.function_evaluations);
}

test "runtime observation model respects its function evaluation budget" {
    const Observation = struct { x: f64, y: f64 };
    const observations = [_]Observation{
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 2.0, .y = 4.0 },
    };
    const solver = comptime residualModel(.{
        "a*x - y",
    }, .{
        .variables = .{.a},
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .max_function_evaluations = 2,
        .tolerance = 0.0,
    });
    const result = solver.eval(.{
        .initial = .{ .a = 0.0 },
        .observations = &observations,
    });

    try std.testing.expect(
        result.function_evaluations <= solver.max_function_evaluations,
    );
    try std.testing.expectEqual(
        bombelli.RowLeastSquaresStatus.max_function_evaluations,
        result.status,
    );
}
