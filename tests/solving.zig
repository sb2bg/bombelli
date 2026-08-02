const std = @import("std");
const bombelli = @import("bombelli");

const equation = bombelli.equation;
const system = bombelli.system;
const equationProblem = bombelli.equationProblem;
const nonzero = bombelli.nonzero;
const SolutionSet = bombelli.SolutionSet;
const NewtonStatus = bombelli.NewtonStatus;
const NewtonSensitivityStatus = bombelli.NewtonSensitivityStatus;
const Complex = std.math.Complex(f64);

fn expectComplexApprox(expected: Complex, actual: Complex, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.re, actual.re, tolerance);
    try std.testing.expectApproxEqAbs(expected.im, actual.im, tolerance);
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

test "symbolic factorizations reuse precomputed inverse programs" {
    const problem_value = comptime system(.{
        "a*x + b*y = 0",
        "c*x + d*y = 0",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    });
    const factorization = comptime problem_value.factor(.bareiss);
    try std.testing.expectEqual(
        @as(usize, 1),
        factorization.conditions.len,
    );
    const inverse_metrics = comptime factorization.inverse_program.metrics();
    try std.testing.expect(inverse_metrics.node_count > 0);
    try std.testing.expectEqual(
        @as(usize, 2),
        factorization.inverse_program.roots.len,
    );

    const first = comptime factorization.solve(.{ "e", "f" });
    const second = comptime factorization.solve(.{ 1, 0 });
    try std.testing.expect(first == .conditional);
    try std.testing.expect(second == .conditional);
    const parameters = .{
        .a = 2.0,
        .b = 1.0,
        .c = 1.0,
        .d = -1.0,
        .e = 7.0,
        .f = 2.0,
    };
    const first_values = first.conditional.values.eval(parameters);
    try std.testing.expectApproxEqAbs(3.0, first_values[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.0, first_values[1], 1e-12);
    const second_values = second.conditional.values.eval(parameters);
    try std.testing.expectApproxEqAbs(1.0 / 3.0, second_values[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / 3.0, second_values[1], 1e-12);
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

test "fraction-free Bareiss diagonalizes general symbolic square systems" {
    const symbolic_problem = comptime system(.{
        "a*x + y + z = e",
        "x + b*y + z = f",
        "x + y + c*z = g",
    }, .{
        .unknowns = .{ .x, .y, .z },
        .domain = .real,
    });
    const result = comptime symbolic_problem.solve(.bareiss);
    try std.testing.expect(result == .conditional);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.conditional.conditions.len,
    );
    const inputs = .{
        .a = 2.0,
        .b = 3.0,
        .c = 4.0,
        .e = 7.0,
        .f = 10.0,
        .g = 15.0,
    };
    try std.testing.expectEqual(
        @as(f64, 17.0),
        result.conditional.conditions[0].expression.eval(inputs),
    );
    try std.testing.expectEqualDeep(
        [3]f64{ 1.0, 2.0, 3.0 },
        result.conditional.values.eval(inputs),
    );

    const row_swap = comptime system(.{
        "y = e",
        "a*x + b*y = f",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).solve(.bareiss);
    try std.testing.expect(row_swap == .conditional);
    try std.testing.expectEqualDeep(
        [2]f64{ 3.0, 2.0 },
        row_swap.conditional.values.eval(.{
            .a = 2.0,
            .b = 1.0,
            .e = 2.0,
            .f = 8.0,
        }),
    );
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

test "polynomial equation solver retains complex radical branches" {
    const roots = comptime equationProblem("x^2 + 1 = 0", .{
        .unknowns = .{.x},
        .domain = .complex,
    }).solve(.polynomial).requireFinite();
    try std.testing.expectEqual(@as(usize, 2), roots.branch_count);

    const first = comptime roots.branch(0).evalAs(Complex, .{})[0];
    const second = comptime roots.branch(1).evalAs(Complex, .{})[0];
    try std.testing.expectApproxEqAbs(0.0, first.re, 1e-15);
    try std.testing.expectApproxEqAbs(1.0, @abs(first.im), 1e-15);
    try std.testing.expectApproxEqAbs(0.0, second.re, 1e-15);
    try std.testing.expectApproxEqAbs(1.0, @abs(second.im), 1e-15);
    try std.testing.expectApproxEqAbs(0.0, first.add(second).magnitude(), 1e-15);
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

test "generated Newton solvers converge with symbolic Jacobians" {
    const problem_value = comptime system(.{
        "x^2 + y^2 = r^2",
        "x - y = 0",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    });
    const solver = comptime problem_value.compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.7, .y = 0.7 },
        .r = 1.0,
    });
    try std.testing.expectEqual(NewtonStatus.converged, result.status);
    try std.testing.expectApproxEqAbs(
        1.0 / @sqrt(2.0),
        solver.value(result, .x),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        1.0 / @sqrt(2.0),
        solver.value(result, .y),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        result.residual[0],
        solver.residualAt(result, 0),
        0.0,
    );
    try std.testing.expectEqual(@as(usize, 1), comptime solver.unknownIndex(.y));
    try std.testing.expect(result.residual_norm <= 1e-12);
    try std.testing.expect(result.iterations > 0);
}

test "backtracking Newton globalizes difficult steps and reports diagnostics" {
    const problem_value = comptime equationProblem("x^3 = 1", .{
        .unknowns = .{.x},
        .domain = .real,
    });
    const undamped = comptime problem_value.compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 12,
        .tolerance = 1e-12,
    });
    const plain_result = undamped.eval(.{ .initial = .{ .x = 0.01 } });
    try std.testing.expectEqual(NewtonStatus.non_converged, plain_result.status);

    const damped = comptime problem_value.compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 12,
        .tolerance = 1e-12,
        .globalization = .backtracking,
        .max_backtracks = 16,
    });
    const damped_result = damped.eval(.{ .initial = .{ .x = 0.01 } });
    try std.testing.expectEqual(NewtonStatus.converged, damped_result.status);
    try std.testing.expectApproxEqAbs(
        1.0,
        damped.value(damped_result, .x),
        1e-12,
    );
    try std.testing.expect(damped_result.backtracks > 0);
    try std.testing.expect(
        damped_result.function_evaluations > damped_result.iterations + 1,
    );
    try std.testing.expect(damped_result.step_scale > 0.0);
    try std.testing.expect(damped_result.step_scale <= 1.0);

    const complex_damped = comptime equationProblem("z^3 = 1", .{
        .unknowns = .{.z},
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 12,
        .tolerance = 1e-12,
        .globalization = .backtracking,
        .max_backtracks = 16,
    });
    const complex_result = complex_damped.eval(.{
        .initial = .{ .z = Complex.init(0.01, 0.0) },
    });
    try std.testing.expectEqual(NewtonStatus.converged, complex_result.status);
    try expectComplexApprox(
        Complex.init(1.0, 0.0),
        complex_damped.value(complex_result, .z),
        1e-12,
    );
}

test "backtracking Newton distinguishes failed search from stagnation" {
    const failed = comptime equationProblem("x^3 - 2*x + 2 = 0", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
        .globalization = .backtracking,
        .max_backtracks = 0,
    }).eval(.{ .initial = .{ .x = 1.0 } });
    try std.testing.expectEqual(NewtonStatus.line_search_failed, failed.status);
    try std.testing.expectEqual(@as(usize, 0), failed.iterations);
    try std.testing.expectEqual(@as(usize, 2), failed.function_evaluations);
    try std.testing.expectEqual(@as(usize, 0), failed.backtracks);
    try std.testing.expectEqual(@as(f64, 1.0), failed.values[0]);

    const stagnated = comptime equationProblem("x^2 = 2", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 16,
        .tolerance = 1e-30,
        .step_tolerance = 1e-6,
        .globalization = .backtracking,
    }).eval(.{ .initial = .{ .x = 1.0 } });
    try std.testing.expectEqual(NewtonStatus.stagnated, stagnated.status);
    try std.testing.expect(stagnated.residual_norm > 1e-30);
    try std.testing.expect(stagnated.step_norm <= 1e-6 *
        (1.0 + @abs(stagnated.values[0])));
}

test "generated Newton solvers converge over complex systems" {
    const constant_solver = comptime equationProblem("z = i", .{
        .unknowns = .{.z},
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 4,
        .tolerance = 1e-12,
    });
    const constant_result = constant_solver.eval(.{
        .initial = .{ .z = 0.0 },
    });
    try std.testing.expectEqual(NewtonStatus.converged, constant_result.status);
    try expectComplexApprox(
        Complex.init(0.0, 1.0),
        constant_result.values[0],
        1e-12,
    );

    const scalar_solver = comptime equationProblem("z^2 + 1 = 0", .{
        .unknowns = .{.z},
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });
    const scalar_result = scalar_solver.eval(.{
        .initial = .{ .z = Complex.init(0.5, 0.5) },
    });
    try std.testing.expectEqual(NewtonStatus.converged, scalar_result.status);
    try expectComplexApprox(
        Complex.init(0.0, 1.0),
        scalar_result.values[0],
        1e-12,
    );
    try std.testing.expect(scalar_result.residual_norm <= 1e-12);

    const system_solver = comptime system(.{
        "a*x + y = b",
        "x - a*y = c",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 4,
        .tolerance = 1e-12,
    });
    const expected_x = Complex.init(1.0, 2.0);
    const expected_y = Complex.init(-0.5, 0.25);
    const a = Complex.init(2.0, -1.0);
    const system_result = system_solver.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
        .a = a,
        .b = a.mul(expected_x).add(expected_y),
        .c = expected_x.sub(a.mul(expected_y)),
    });
    try std.testing.expectEqual(NewtonStatus.converged, system_result.status);
    try expectComplexApprox(expected_x, system_result.values[0], 1e-12);
    try expectComplexApprox(expected_y, system_result.values[1], 1e-12);
}

test "generated Newton linear solves pivot at runtime" {
    const solver = comptime system(.{
        "y = 1",
        "x = 2",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 4,
        .tolerance = 1e-12,
    });
    const result = solver.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expectEqual(NewtonStatus.converged, result.status);
    try std.testing.expectEqualDeep([2]f64{ 2.0, 1.0 }, result.values);
}

test "generated Newton solvers report singular and non-convergent outcomes" {
    const singular_solver = comptime system(.{
        "x^2 = 1",
        "y^2 = 1",
    }, .{
        .unknowns = .{ .x, .y },
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
    });
    const singular = singular_solver.eval(.{
        .initial = .{ .x = 0.0, .y = 0.0 },
    });
    try std.testing.expectEqual(
        NewtonStatus.singular_jacobian,
        singular.status,
    );

    const bounded_solver = comptime equationProblem("x^2 = 2", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 1,
        .tolerance = 1e-15,
    });
    const bounded = bounded_solver.eval(.{
        .initial = .{ .x = 1.0 },
    });
    try std.testing.expectEqual(NewtonStatus.non_converged, bounded.status);
    try std.testing.expectEqual(@as(usize, 1), bounded.iterations);
    try std.testing.expect(bounded.residual_norm > 1e-15);
}

test "generated solver sensitivities use implicit differentiation" {
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
    const sensitivity_solver = comptime solver.diff(.r);
    const result = sensitivity_solver.eval(.{
        .initial = .{ .x = 0.7, .y = 0.7 },
        .r = 1.0,
    });
    try std.testing.expectEqual(
        NewtonSensitivityStatus.converged,
        result.status,
    );
    try std.testing.expectEqual(NewtonStatus.converged, result.root.status);
    try std.testing.expectApproxEqAbs(
        1.0 / @sqrt(2.0),
        sensitivity_solver.sensitivity(result, .x),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        1.0 / @sqrt(2.0),
        sensitivity_solver.sensitivity(result, .y),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        1.0 / @sqrt(2.0),
        sensitivity_solver.value(result, .x),
        1e-12,
    );
}

test "generated complex solver sensitivities stay in the complex domain" {
    const solver = comptime equationProblem("z^2 = p", .{
        .unknowns = .{.z},
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });
    const sensitivity = comptime solver.diff(.p);
    const expected_root = Complex.init(1.0, 1.0);
    const result = sensitivity.eval(.{
        .initial = .{ .z = Complex.init(0.8, 1.2) },
        .p = expected_root.mul(expected_root),
    });
    try std.testing.expectEqual(NewtonStatus.converged, result.root.status);
    try std.testing.expectEqual(
        NewtonSensitivityStatus.converged,
        result.status,
    );
    try expectComplexApprox(expected_root, result.root.values[0], 1e-12);
    try expectComplexApprox(
        Complex.init(0.25, -0.25),
        result.sensitivities[0],
        1e-12,
    );
}

test "generated sensitivities require a nonsingular local root" {
    const solver = comptime equationProblem("x^2 = p", .{
        .unknowns = .{.x},
        .domain = .real,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
    });
    const sensitivity_solver = comptime solver.diff(.p);
    const result = sensitivity_solver.eval(.{
        .initial = .{ .x = 0.0 },
        .p = 0.0,
    });
    try std.testing.expectEqual(NewtonStatus.converged, result.root.status);
    try std.testing.expectEqual(
        NewtonSensitivityStatus.singular_jacobian,
        result.status,
    );
}
