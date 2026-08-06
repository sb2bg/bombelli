const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodesAtIndent = support.emitNodesAtIndent;
const fill = support.fill;
const floatSource = support.floatSource;
const prelude = support.prelude;
const validateOptions = support.validateOptions;

pub fn emitRowLeastSquares(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    if (support.scalarOption(options) != .f64) {
        @compileError(
            "Bombelli runtime-observation least-squares source emission currently requires '.scalar = .f64'",
        );
    }

    const name = validateOptions(options);
    const Solver = @TypeOf(solver);
    const N = solver.variables.len;
    const R = Solver.residuals_per_observation;
    const slots = .{
        .{ "@name@", name },
        .{ "@n@", std.fmt.comptimePrint("{d}", .{N}) },
        .{ "@r@", std.fmt.comptimePrint("{d}", .{R}) },
        .{ "@iterations@", std.fmt.comptimePrint(
            "{d}",
            .{Solver.maximum_iterations},
        ) },
    };

    var source: []const u8 = prelude();
    source = append(source, fill(public_types, slots));
    source = append(source, configSource(solver));
    source = append(source, fill(runtime_support, slots));
    source = append(source, linearizationSource(solver));
    source = append(source, objectiveSource(solver));
    source = append(source, entrypointSource(solver, slots));
    return source;
}

fn configSource(comptime solver: anytype) []const u8 {
    var source: []const u8 =
        \\
        \\const bombelliConfig = struct {
    ;
    source = append(source, std.fmt.comptimePrint(
        "    const loss = bombelliLoss{{ .kind = .{s}, .scale = {s} }};\n",
        .{ @tagName(solver.loss.kind), floatSource(solver.loss.scale) },
    ));
    source = append(source, std.fmt.comptimePrint(
        "    const scaling: bombelliScaling = .{s};\n",
        .{@tagName(solver.scaling)},
    ));
    source = append(source, "    const parameter_scales = [_]f64{");
    inline for (solver.parameter_scales, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, floatSource(value));
    }
    source = append(source, "};\n    const lower = [_]f64{");
    inline for (solver.bounds.lower, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, boundSource(value));
    }
    source = append(source, "};\n    const upper = [_]f64{");
    inline for (solver.bounds.upper, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, boundSource(value));
    }
    source = append(source, std.fmt.comptimePrint(
        \\}};
        \\    const initial_bounds: bombelliInitialBounds = .{s};
        \\    const function_tolerance: f64 = {s};
        \\    const gradient_tolerance: f64 = {s};
        \\    const step_tolerance: f64 = {s};
        \\    const cost_tolerance: f64 = {s};
        \\    const damping_tau: f64 = {s};
        \\    const minimum_damping: f64 = {s};
        \\    const maximum_damping: f64 = {s};
        \\    const acceptance_threshold: f64 = {s};
        \\    const armijo_constant: f64 = {s};
        \\    const backtrack_factor: f64 = {s};
        \\    const rank_tolerance: f64 = {s};
        \\    const max_function_evaluations: usize = {d};
        \\    const max_damping_trials: usize = {d};
        \\    const max_line_search_steps: usize = {d};
        \\    const max_invalid_steps: usize = {d};
        \\}};
        \\
    , .{
        @tagName(solver.initial_bounds_policy),
        floatSource(solver.function_tolerance),
        floatSource(solver.gradient_tolerance),
        floatSource(solver.step_tolerance),
        floatSource(solver.cost_tolerance),
        floatSource(solver.damping_tau),
        floatSource(solver.minimum_damping),
        floatSource(solver.maximum_damping),
        floatSource(solver.acceptance_threshold),
        floatSource(solver.armijo_constant),
        floatSource(solver.backtrack_factor),
        floatSource(solver.rank_tolerance),
        solver.max_function_evaluations,
        solver.max_damping_trials,
        solver.max_line_search_steps,
        solver.max_invalid_steps,
    }));
    return source;
}

fn boundSource(comptime value: f64) []const u8 {
    if (value == std.math.inf(f64)) return "std.math.inf(f64)";
    if (value == -std.math.inf(f64)) return "-std.math.inf(f64)";
    return floatSource(value);
}

fn rowBindings(comptime solver: anytype) [solver.variables.len + solver.data.len]support.Binding {
    var bindings: [solver.variables.len + solver.data.len]support.Binding = undefined;
    inline for (solver.variables, 0..) |variable, index| {
        bindings[index] = .{
            .symbol = variable,
            .source = std.fmt.comptimePrint("values[{d}]", .{index}),
        };
    }
    inline for (solver.data, 0..) |field, index| {
        bindings[solver.variables.len + index] = .{
            .symbol = field,
            .source = std.fmt.comptimePrint(
                "bombelliNumber(observation.{s})",
                .{field},
            ),
        };
    }
    return bindings;
}

fn linearizationSource(comptime solver: anytype) []const u8 {
    const N = solver.variables.len;
    const R = @TypeOf(solver).residuals_per_observation;
    const bindings = rowBindings(solver);
    var source: []const u8 = std.fmt.comptimePrint(
        \\
        \\fn bombelliLinearize(
        \\    observations: anytype,
        \\    values: [{d}]f64,
        \\) bombelliLinearization {{
        \\    var result = bombelliLinearization.init();
        \\    for (observations) |observation| {{
        \\        result.visited += 1;
        \\        var residuals: [{d}]f64 = undefined;
        \\        var jacobian: [{d}][{d}]f64 = undefined;
        \\
    , .{ N, R, R, N });
    source = append(source, emitNodesAtIndent(
        solver.linearization_program.combined.nodes,
        "linear_n",
        &bindings,
        "        ",
    ));
    inline for (0..R) |row| {
        const residual_root = solver.linearization_program.combined.roots[row];
        source = append(source, std.fmt.comptimePrint(
            "        residuals[{d}] = linear_n{d};\n",
            .{ row, residual_root },
        ));
        inline for (0..N) |column| {
            const root = solver.linearization_program.combined.roots[
                R + row * N + column
            ];
            source = append(source, std.fmt.comptimePrint(
                "        jacobian[{d}][{d}] = linear_n{d};\n",
                .{ row, column, root },
            ));
        }
    }
    source = append(source, std.fmt.comptimePrint(
        \\        for (0..{d}) |row_index| {{
        \\            const residual = residuals[row_index];
        \\            if (!std.math.isFinite(residual)) {{
        \\                result.failure = .non_finite_residual;
        \\                return result;
        \\            }}
        \\            if (!bombelliAllFinite(jacobian[row_index])) {{
        \\                result.failure = .non_finite_jacobian;
        \\                return result;
        \\            }}
        \\            const robust = bombelliEvaluateLoss(residual);
        \\            if (!std.math.isFinite(robust.cost) or
        \\                !std.math.isFinite(robust.sqrt_weight))
        \\            {{
        \\                result.failure = .numerical;
        \\                return result;
        \\            }}
        \\            result.cost += robust.cost;
        \\            if (!std.math.isFinite(result.cost)) {{
        \\                result.failure = .numerical;
        \\                return result;
        \\            }}
        \\            const weighted_residual = robust.sqrt_weight * residual;
        \\            var weighted_row: [{d}]f64 = undefined;
        \\            for (0..{d}) |column| {{
        \\                weighted_row[column] =
        \\                    robust.sqrt_weight * jacobian[row_index][column];
        \\                result.gradient[column] +=
        \\                    weighted_row[column] * weighted_residual;
        \\                result.column_norms[column] = std.math.hypot(
        \\                    result.column_norms[column],
        \\                    weighted_row[column],
        \\                );
        \\            }}
        \\            if (!bombelliAllFinite(weighted_row) or
        \\                !bombelliAllFinite(result.gradient) or
        \\                !bombelliAllFinite(result.column_norms) or
        \\                !result.factor.addRow(weighted_row, -weighted_residual))
        \\            {{
        \\                result.failure = .numerical;
        \\                return result;
        \\            }}
        \\        }}
        \\    }}
        \\    result.rank = result.factor.rank(bombelliConfig.rank_tolerance);
        \\    return result;
        \\}}
        \\
    , .{ R, N, N }));
    return source;
}

fn objectiveSource(comptime solver: anytype) []const u8 {
    const N = solver.variables.len;
    const R = @TypeOf(solver).residuals_per_observation;
    const bindings = rowBindings(solver);
    var source: []const u8 = std.fmt.comptimePrint(
        \\
        \\fn bombelliObjective(
        \\    observations: anytype,
        \\    values: [{d}]f64,
        \\) bombelliObjectiveResult {{
        \\    var result = bombelliObjectiveResult{{}};
        \\    for (observations) |observation| {{
        \\        result.visited += 1;
        \\        var residuals: [{d}]f64 = undefined;
        \\
    , .{ N, R });
    source = append(source, emitNodesAtIndent(
        solver.residuals.nodes,
        "objective_n",
        &bindings,
        "        ",
    ));
    inline for (solver.residuals.roots, 0..) |root, row| {
        source = append(source, std.fmt.comptimePrint(
            "        residuals[{d}] = objective_n{d};\n",
            .{ row, root },
        ));
    }
    source = append(source,
        \\        for (residuals) |residual| {
        \\            if (!std.math.isFinite(residual)) {
        \\                result.valid = false;
        \\                return result;
        \\            }
        \\            const robust = bombelliEvaluateLoss(residual);
        \\            result.cost += robust.cost;
        \\            if (!std.math.isFinite(robust.cost) or
        \\                !std.math.isFinite(result.cost))
        \\            {
        \\                result.valid = false;
        \\                return result;
        \\            }
        \\        }
        \\    }
        \\    return result;
        \\}
        \\
    );
    return source;
}

fn entrypointSource(comptime solver: anytype, comptime slots: anytype) []const u8 {
    var source: []const u8 = fill(solver_entrypoint_prefix, slots);
    inline for (solver.variables) |variable| {
        source = append(source, std.fmt.comptimePrint(
            "        bombelliNumber(inputs.initial.{s}),\n",
            .{variable},
        ));
    }
    source = append(source, fill(solver_entrypoint_after_initial, slots));
    inline for (solver.data) |field| {
        source = append(source, std.fmt.comptimePrint(
            "        observation_finite = observation_finite and std.math.isFinite(bombelliNumber(observation.{s}));\n",
            .{field},
        ));
    }
    source = append(source, fill(solver_entrypoint_after_validation, slots));
    return source;
}

const public_types =
    \\
    \\pub const @name@Status = enum(u8) {
    \\    converged_gradient,
    \\    converged_cost,
    \\    converged_step,
    \\    max_iterations,
    \\    max_function_evaluations,
    \\    empty_observations,
    \\    infeasible_initial,
    \\    non_finite_initial,
    \\    non_finite_observation,
    \\    non_finite_jacobian,
    \\    too_many_invalid_trials,
    \\    line_search_failed,
    \\    numerical_failure,
    \\};
    \\
    \\pub const @name@BoundActivity = enum(u8) {
    \\    free,
    \\    lower,
    \\    upper,
    \\    fixed,
    \\};
    \\
    \\pub const @name@Result = struct {
    \\    values: [@n@]f64,
    \\    initial_cost: f64,
    \\    cost: f64,
    \\    observation_count: usize,
    \\    residual_count: usize,
    \\    iterations: usize,
    \\    function_evaluations: usize,
    \\    jacobian_evaluations: usize,
    \\    observation_evaluations: usize,
    \\    accepted_steps: usize,
    \\    rejected_steps: usize,
    \\    projected_gradient_steps: usize,
    \\    invalid_steps: usize,
    \\    rank: usize,
    \\    active_bounds: [@n@]@name@BoundActivity,
    \\    gradient_norm: f64,
    \\    step_norm: f64,
    \\    damping: f64,
    \\    status: @name@Status,
    \\
    \\    pub fn converged(self: @This()) bool {
    \\        return switch (self.status) {
    \\            .converged_gradient,
    \\            .converged_cost,
    \\            .converged_step,
    \\            => true,
    \\            else => false,
    \\        };
    \\    }
    \\};
    \\
;

const runtime_support =
    \\
    \\const bombelliLossKind = enum { linear, huber, soft_l1, cauchy };
    \\const bombelliLoss = struct { kind: bombelliLossKind, scale: f64 };
    \\const bombelliScaling = enum { none, jacobian, user };
    \\const bombelliInitialBounds = enum { reject, project };
    \\const bombelliLinearizationFailure = enum {
    \\    none,
    \\    non_finite_residual,
    \\    non_finite_jacobian,
    \\    numerical,
    \\};
    \\
    \\const bombelliCounters = struct {
    \\    function_evaluations: usize = 0,
    \\    jacobian_evaluations: usize = 0,
    \\    observation_evaluations: usize = 0,
    \\    accepted_steps: usize = 0,
    \\    rejected_steps: usize = 0,
    \\    projected_gradient_steps: usize = 0,
    \\    invalid_steps: usize = 0,
    \\};
    \\
    \\const bombelliFactor = struct {
    \\    upper: [@n@][@n@]f64,
    \\    transformed_rhs: [@n@]f64,
    \\    rows: usize,
    \\
    \\    fn init() @This() {
    \\        return .{
    \\            .upper = [_][@n@]f64{[_]f64{0.0} ** @n@} ** @n@,
    \\            .transformed_rhs = [_]f64{0.0} ** @n@,
    \\            .rows = 0,
    \\        };
    \\    }
    \\
    \\    fn addRow(self: *@This(), input_row: [@n@]f64, input_rhs: f64) bool {
    \\        if (!bombelliAllFinite(input_row) or
    \\            !std.math.isFinite(input_rhs)) return false;
    \\        var row = input_row;
    \\        var rhs = input_rhs;
    \\        for (0..@n@) |pivot| {
    \\            const below = row[pivot];
    \\            if (below == 0.0) continue;
    \\            const diagonal = self.upper[pivot][pivot];
    \\            const radius = std.math.hypot(diagonal, below);
    \\            if (!std.math.isFinite(radius) or radius == 0.0) return false;
    \\            const cosine = diagonal / radius;
    \\            const sine = below / radius;
    \\            self.upper[pivot][pivot] = radius;
    \\            row[pivot] = 0.0;
    \\            for (pivot + 1..@n@) |column| {
    \\                const upper_value = self.upper[pivot][column];
    \\                const row_value = row[column];
    \\                self.upper[pivot][column] =
    \\                    cosine * upper_value + sine * row_value;
    \\                row[column] =
    \\                    -sine * upper_value + cosine * row_value;
    \\            }
    \\            const upper_rhs = self.transformed_rhs[pivot];
    \\            self.transformed_rhs[pivot] =
    \\                cosine * upper_rhs + sine * rhs;
    \\            rhs = -sine * upper_rhs + cosine * rhs;
    \\            if (!bombelliAllFinite(self.upper[pivot]) or
    \\                !std.math.isFinite(self.transformed_rhs[pivot]) or
    \\                !std.math.isFinite(rhs)) return false;
    \\        }
    \\        self.rows +|= 1;
    \\        return true;
    \\    }
    \\
    \\    fn divideColumns(self: *@This(), diagonal: [@n@]f64) bool {
    \\        for (0..@n@) |column| {
    \\            if (!std.math.isFinite(diagonal[column]) or
    \\                diagonal[column] <= 0.0) return false;
    \\            for (0..column + 1) |row| {
    \\                self.upper[row][column] /= diagonal[column];
    \\                if (!std.math.isFinite(self.upper[row][column])) return false;
    \\            }
    \\        }
    \\        return true;
    \\    }
    \\
    \\    fn addDamping(self: *@This(), damping: f64) bool {
    \\        if (!std.math.isFinite(damping) or damping <= 0.0) return false;
    \\        const root = @sqrt(damping);
    \\        if (!std.math.isFinite(root) or root == 0.0) return false;
    \\        for (0..@n@) |column| {
    \\            var row = [_]f64{0.0} ** @n@;
    \\            row[column] = root;
    \\            if (!self.addRow(row, 0.0)) return false;
    \\        }
    \\        return true;
    \\    }
    \\
    \\    fn solve(self: @This()) ?[@n@]f64 {
    \\        var solution: [@n@]f64 = undefined;
    \\        var reverse: usize = @n@;
    \\        while (reverse != 0) {
    \\            reverse -= 1;
    \\            var value = self.transformed_rhs[reverse];
    \\            for (reverse + 1..@n@) |column| {
    \\                value -= self.upper[reverse][column] * solution[column];
    \\            }
    \\            const diagonal = self.upper[reverse][reverse];
    \\            if (!std.math.isFinite(diagonal) or diagonal == 0.0) return null;
    \\            solution[reverse] = value / diagonal;
    \\            if (!std.math.isFinite(solution[reverse])) return null;
    \\        }
    \\        return solution;
    \\    }
    \\
    \\    fn transformedNorm(self: @This(), vector: [@n@]f64) f64 {
    \\        var transformed: [@n@]f64 = undefined;
    \\        for (0..@n@) |row| {
    \\            var value: f64 = 0.0;
    \\            for (row..@n@) |column| {
    \\                value += self.upper[row][column] * vector[column];
    \\            }
    \\            transformed[row] = value;
    \\        }
    \\        return bombelliStableNorm(transformed);
    \\    }
    \\
    \\    fn rank(self: @This(), relative_tolerance: f64) usize {
    \\        var maximum: f64 = 0.0;
    \\        for (0..@n@) |index| {
    \\            maximum = @max(maximum, @abs(self.upper[index][index]));
    \\        }
    \\        if (maximum == 0.0 or !std.math.isFinite(maximum)) return 0;
    \\        const threshold = relative_tolerance * maximum;
    \\        var result: usize = 0;
    \\        for (0..@n@) |index| {
    \\            const diagonal = @abs(self.upper[index][index]);
    \\            if (std.math.isFinite(diagonal) and diagonal > threshold) {
    \\                result += 1;
    \\            }
    \\        }
    \\        return result;
    \\    }
    \\};
    \\
    \\const bombelliLinearization = struct {
    \\    cost: f64,
    \\    gradient: [@n@]f64,
    \\    column_norms: [@n@]f64,
    \\    factor: bombelliFactor,
    \\    rank: usize,
    \\    visited: usize,
    \\    failure: bombelliLinearizationFailure,
    \\
    \\    fn init() @This() {
    \\        return .{
    \\            .cost = 0.0,
    \\            .gradient = [_]f64{0.0} ** @n@,
    \\            .column_norms = [_]f64{0.0} ** @n@,
    \\            .factor = bombelliFactor.init(),
    \\            .rank = 0,
    \\            .visited = 0,
    \\            .failure = .none,
    \\        };
    \\    }
    \\};
    \\
    \\const bombelliObjectiveResult = struct {
    \\    cost: f64 = 0.0,
    \\    visited: usize = 0,
    \\    valid: bool = true,
    \\};
    \\
    \\const bombelliTrial = struct {
    \\    accepted: bool,
    \\    values: [@n@]f64,
    \\    step: [@n@]f64,
    \\    cost: f64,
    \\    evaluations: usize,
    \\    visited: usize,
    \\    invalid: usize,
    \\};
    \\
    \\const bombelliLossEvaluation = struct { cost: f64, sqrt_weight: f64 };
    \\
    \\fn bombelliEvaluateLoss(residual: f64) bombelliLossEvaluation {
    \\    const loss = bombelliConfig.loss;
    \\    if (loss.kind == .linear) {
    \\        return .{ .cost = 0.5 * residual * residual, .sqrt_weight = 1.0 };
    \\    }
    \\    const magnitude = @abs(residual);
    \\    const t = magnitude / loss.scale;
    \\    return switch (loss.kind) {
    \\        .linear => unreachable,
    \\        .huber => if (t <= 1.0)
    \\            .{ .cost = 0.5 * residual * residual, .sqrt_weight = 1.0 }
    \\        else
    \\            .{
    \\                .cost = loss.scale * (magnitude - 0.5 * loss.scale),
    \\                .sqrt_weight = @sqrt(loss.scale / magnitude),
    \\            },
    \\        .soft_l1 => blk: {
    \\            if (t < @sqrt(std.math.floatEps(f64))) {
    \\                break :blk .{
    \\                    .cost = 0.5 * residual * residual,
    \\                    .sqrt_weight = 1.0,
    \\                };
    \\            }
    \\            const hypotenuse = std.math.hypot(loss.scale, residual);
    \\            const difference = if (hypotenuse >
    \\                std.math.floatMax(f64) - loss.scale)
    \\                hypotenuse - loss.scale
    \\            else
    \\                magnitude * (magnitude / (hypotenuse + loss.scale));
    \\            break :blk .{
    \\                .cost = loss.scale * difference,
    \\                .sqrt_weight = @sqrt(loss.scale / hypotenuse),
    \\            };
    \\        },
    \\        .cauchy => blk: {
    \\            if (t < @sqrt(std.math.floatEps(f64))) {
    \\                break :blk .{
    \\                    .cost = 0.5 * residual * residual,
    \\                    .sqrt_weight = 1.0,
    \\                };
    \\            }
    \\            const hypotenuse = std.math.hypot(loss.scale, residual);
    \\            const log_ratio = if (magnitude == 0.0)
    \\                0.0
    \\            else if (!std.math.isFinite(t))
    \\                @log(hypotenuse) - @log(loss.scale)
    \\            else if (t <= @sqrt(std.math.floatMax(f64)))
    \\                0.5 * std.math.log1p(t * t)
    \\            else
    \\                @log(t) + 0.5 * std.math.log1p(1.0 / t / t);
    \\            break :blk .{
    \\                .cost = loss.scale * (loss.scale * log_ratio),
    \\                .sqrt_weight = loss.scale / hypotenuse,
    \\            };
    \\        },
    \\    };
    \\}
    \\
    \\fn bombelliStableNorm(vector: anytype) f64 {
    \\    var scale: f64 = 0.0;
    \\    var sum: f64 = 1.0;
    \\    for (vector) |value| {
    \\        const magnitude = @abs(value);
    \\        if (magnitude == 0.0) continue;
    \\        if (!std.math.isFinite(magnitude)) return magnitude;
    \\        if (scale < magnitude) {
    \\            const ratio = scale / magnitude;
    \\            sum = 1.0 + sum * ratio * ratio;
    \\            scale = magnitude;
    \\        } else {
    \\            const ratio = magnitude / scale;
    \\            sum += ratio * ratio;
    \\        }
    \\    }
    \\    return if (scale == 0.0) 0.0 else scale * @sqrt(sum);
    \\}
    \\
    \\fn bombelliAllFinite(vector: anytype) bool {
    \\    for (vector) |value| {
    \\        if (!std.math.isFinite(value)) return false;
    \\    }
    \\    return true;
    \\}
    \\
    \\fn bombelliDot(left: [@n@]f64, right: [@n@]f64) f64 {
    \\    var result: f64 = 0.0;
    \\    for (left, right) |a, b| result += a * b;
    \\    return result;
    \\}
    \\
    \\fn bombelliNormInf(vector: [@n@]f64) f64 {
    \\    var result: f64 = 0.0;
    \\    for (vector) |value| result = @max(result, @abs(value));
    \\    return result;
    \\}
    \\
    \\fn bombelliWithinBounds(values: [@n@]f64) bool {
    \\    for (0..@n@) |index| {
    \\        if (values[index] < bombelliConfig.lower[index] or
    \\            values[index] > bombelliConfig.upper[index]) return false;
    \\    }
    \\    return true;
    \\}
    \\
    \\fn bombelliProject(values: [@n@]f64) [@n@]f64 {
    \\    var result: [@n@]f64 = undefined;
    \\    for (0..@n@) |index| {
    \\        result[index] = std.math.clamp(
    \\            values[index],
    \\            bombelliConfig.lower[index],
    \\            bombelliConfig.upper[index],
    \\        );
    \\    }
    \\    return result;
    \\}
    \\
    \\fn bombelliUpdateScales(column_norms: [@n@]f64, scales: *[@n@]f64) void {
    \\    if (bombelliConfig.scaling != .jacobian) return;
    \\    for (0..@n@) |index| {
    \\        if (column_norms[index] > 0.0 and
    \\            std.math.isFinite(column_norms[index]))
    \\        {
    \\            scales[index] = @max(scales[index], column_norms[index]);
    \\        }
    \\    }
    \\}
    \\
    \\fn bombelliInitialDamping(column_norms: [@n@]f64, scales: [@n@]f64) f64 {
    \\    var largest: f64 = 0.0;
    \\    for (0..@n@) |index| {
    \\        largest = @max(largest, column_norms[index] / scales[index]);
    \\    }
    \\    const squared = if (largest > @sqrt(std.math.floatMax(f64)))
    \\        bombelliConfig.maximum_damping
    \\    else
    \\        largest * largest;
    \\    const raw = bombelliConfig.damping_tau * @max(squared, 1.0);
    \\    return std.math.clamp(
    \\        raw,
    \\        bombelliConfig.minimum_damping,
    \\        bombelliConfig.maximum_damping,
    \\    );
    \\}
    \\
    \\fn bombelliProjectedGradientDirection(
    \\    values: [@n@]f64,
    \\    gradient: [@n@]f64,
    \\    scales: [@n@]f64,
    \\) [@n@]f64 {
    \\    var result: [@n@]f64 = undefined;
    \\    for (0..@n@) |index| {
    \\        const candidate = std.math.clamp(
    \\            values[index] - gradient[index] / scales[index] / scales[index],
    \\            bombelliConfig.lower[index],
    \\            bombelliConfig.upper[index],
    \\        );
    \\        result[index] = candidate - values[index];
    \\    }
    \\    return result;
    \\}
    \\
    \\fn bombelliProjectedOptimality(
    \\    values: [@n@]f64,
    \\    gradient: [@n@]f64,
    \\    scales: [@n@]f64,
    \\) f64 {
    \\    var maximum: f64 = 0.0;
    \\    for (0..@n@) |index| {
    \\        const scaled_gradient = @abs(gradient[index] / scales[index]);
    \\        if (bombelliConfig.lower[index] == -std.math.inf(f64) and
    \\            bombelliConfig.upper[index] == std.math.inf(f64))
    \\        {
    \\            maximum = @max(maximum, scaled_gradient);
    \\            continue;
    \\        }
    \\        const feasible_distance = if (gradient[index] > 0.0)
    \\            values[index] - bombelliConfig.lower[index]
    \\        else if (gradient[index] < 0.0)
    \\            bombelliConfig.upper[index] - values[index]
    \\        else
    \\            0.0;
    \\        maximum = @max(
    \\            maximum,
    \\            @min(scaled_gradient, feasible_distance * scales[index]),
    \\        );
    \\    }
    \\    return maximum;
    \\}
    \\
    \\fn bombelliActiveBounds(
    \\    values: [@n@]f64,
    \\    gradient: [@n@]f64,
    \\) [@n@]@name@BoundActivity {
    \\    var result: [@n@]@name@BoundActivity = undefined;
    \\    for (0..@n@) |index| {
    \\        result[index] = if (bombelliConfig.lower[index] ==
    \\            bombelliConfig.upper[index])
    \\            .fixed
    \\        else if (values[index] <= bombelliConfig.lower[index] and
    \\            gradient[index] > 0.0)
    \\            .lower
    \\        else if (values[index] >= bombelliConfig.upper[index] and
    \\            gradient[index] < 0.0)
    \\            .upper
    \\        else
    \\            .free;
    \\    }
    \\    return result;
    \\}
    \\
    \\fn bombelliIncreaseDamping(damping: *f64, nu: *f64) void {
    \\    damping.* = @min(damping.* * nu.*, bombelliConfig.maximum_damping);
    \\    nu.* = @min(nu.* * 2.0, @sqrt(std.math.floatMax(f64)));
    \\}
    \\
    \\fn bombelliScaledNorm(values: [@n@]f64, scales: [@n@]f64) f64 {
    \\    var scaled: [@n@]f64 = undefined;
    \\    for (0..@n@) |index| scaled[index] = values[index] * scales[index];
    \\    return bombelliStableNorm(scaled);
    \\}
    \\
    \\fn bombelliLineSearch(
    \\    observations: anytype,
    \\    values: [@n@]f64,
    \\    cost: f64,
    \\    gradient: [@n@]f64,
    \\    direction: [@n@]f64,
    \\    max_evaluations: usize,
    \\) bombelliTrial {
    \\    var result = bombelliTrial{
    \\        .accepted = false,
    \\        .values = values,
    \\        .step = [_]f64{0.0} ** @n@,
    \\        .cost = cost,
    \\        .evaluations = 0,
    \\        .visited = 0,
    \\        .invalid = 0,
    \\    };
    \\    var alpha: f64 = 1.0;
    \\    for (0..@min(bombelliConfig.max_line_search_steps, max_evaluations)) |_| {
    \\        var candidate: [@n@]f64 = undefined;
    \\        for (0..@n@) |index| {
    \\            candidate[index] = std.math.clamp(
    \\                values[index] + alpha * direction[index],
    \\                bombelliConfig.lower[index],
    \\                bombelliConfig.upper[index],
    \\            );
    \\            result.step[index] = candidate[index] - values[index];
    \\        }
    \\        const directional_derivative = bombelliDot(gradient, result.step);
    \\        if (!std.math.isFinite(directional_derivative) or
    \\            directional_derivative >= 0.0 or
    \\            bombelliNormInf(result.step) == 0.0)
    \\        {
    \\            alpha *= bombelliConfig.backtrack_factor;
    \\            continue;
    \\        }
    \\        const trial = bombelliObjective(observations, candidate);
    \\        result.evaluations += 1;
    \\        result.visited += trial.visited;
    \\        if (!trial.valid) {
    \\            result.invalid += 1;
    \\            alpha *= bombelliConfig.backtrack_factor;
    \\            continue;
    \\        }
    \\        if (trial.cost <= cost +
    \\            bombelliConfig.armijo_constant * directional_derivative)
    \\        {
    \\            result.accepted = true;
    \\            result.values = candidate;
    \\            result.cost = trial.cost;
    \\            return result;
    \\        }
    \\        alpha *= bombelliConfig.backtrack_factor;
    \\    }
    \\    return result;
    \\}
    \\
    \\fn bombelliResultFrom(
    \\    values: [@n@]f64,
    \\    initial_cost: f64,
    \\    cost: f64,
    \\    observation_count: usize,
    \\    residual_count: usize,
    \\    iterations: usize,
    \\    counters: bombelliCounters,
    \\    damping: f64,
    \\    linearization: bombelliLinearization,
    \\    step_norm: f64,
    \\    gradient_norm: f64,
    \\    status: @name@Status,
    \\) @name@Result {
    \\    return .{
    \\        .values = values,
    \\        .initial_cost = initial_cost,
    \\        .cost = cost,
    \\        .observation_count = observation_count,
    \\        .residual_count = residual_count,
    \\        .iterations = iterations,
    \\        .function_evaluations = counters.function_evaluations,
    \\        .jacobian_evaluations = counters.jacobian_evaluations,
    \\        .observation_evaluations = counters.observation_evaluations,
    \\        .accepted_steps = counters.accepted_steps,
    \\        .rejected_steps = counters.rejected_steps,
    \\        .projected_gradient_steps = counters.projected_gradient_steps,
    \\        .invalid_steps = counters.invalid_steps,
    \\        .rank = linearization.rank,
    \\        .active_bounds = bombelliActiveBounds(values, linearization.gradient),
    \\        .gradient_norm = gradient_norm,
    \\        .step_norm = step_norm,
    \\        .damping = damping,
    \\        .status = status,
    \\    };
    \\}
    \\
    \\fn bombelliFailureResult(
    \\    values: [@n@]f64,
    \\    observation_count: usize,
    \\    residual_count: usize,
    \\    status: @name@Status,
    \\) @name@Result {
    \\    return .{
    \\        .values = values,
    \\        .initial_cost = std.math.nan(f64),
    \\        .cost = std.math.nan(f64),
    \\        .observation_count = observation_count,
    \\        .residual_count = residual_count,
    \\        .iterations = 0,
    \\        .function_evaluations = 0,
    \\        .jacobian_evaluations = 0,
    \\        .observation_evaluations = 0,
    \\        .accepted_steps = 0,
    \\        .rejected_steps = 0,
    \\        .projected_gradient_steps = 0,
    \\        .invalid_steps = 0,
    \\        .rank = 0,
    \\        .active_bounds = [_]@name@BoundActivity{.free} ** @n@,
    \\        .gradient_norm = std.math.nan(f64),
    \\        .step_norm = std.math.nan(f64),
    \\        .damping = std.math.nan(f64),
    \\        .status = status,
    \\    };
    \\}
    \\
    \\fn bombelliFailedLinearizationResultAt(
    \\    values: [@n@]f64,
    \\    initial_cost: f64,
    \\    cost: f64,
    \\    observation_count: usize,
    \\    residual_count: usize,
    \\    iterations: usize,
    \\    counters: bombelliCounters,
    \\    damping: f64,
    \\    step_norm: f64,
    \\    failure: bombelliLinearizationFailure,
    \\) @name@Result {
    \\    return .{
    \\        .values = values,
    \\        .initial_cost = initial_cost,
    \\        .cost = cost,
    \\        .observation_count = observation_count,
    \\        .residual_count = residual_count,
    \\        .iterations = iterations,
    \\        .function_evaluations = counters.function_evaluations,
    \\        .jacobian_evaluations = counters.jacobian_evaluations,
    \\        .observation_evaluations = counters.observation_evaluations,
    \\        .accepted_steps = counters.accepted_steps,
    \\        .rejected_steps = counters.rejected_steps,
    \\        .projected_gradient_steps = counters.projected_gradient_steps,
    \\        .invalid_steps = counters.invalid_steps,
    \\        .rank = 0,
    \\        .active_bounds = [_]@name@BoundActivity{.free} ** @n@,
    \\        .gradient_norm = std.math.nan(f64),
    \\        .step_norm = step_norm,
    \\        .damping = damping,
    \\        .status = switch (failure) {
    \\            .non_finite_residual => if (counters.accepted_steps == 0)
    \\                .non_finite_initial
    \\            else
    \\                .numerical_failure,
    \\            .non_finite_jacobian => .non_finite_jacobian,
    \\            .numerical => .numerical_failure,
    \\            .none => unreachable,
    \\        },
    \\    };
    \\}
    \\
;

const solver_entrypoint_prefix =
    \\
    \\pub fn @name@(inputs: anytype, output: *@name@Result) void {
    \\    const observations = inputs.observations;
    \\    const observation_count = observations.len;
    \\    const residual_count = std.math.mul(
    \\        usize,
    \\        observation_count,
    \\        @r@,
    \\    ) catch {
    \\        output.* = bombelliFailureResult(
    \\            [_]f64{std.math.nan(f64)} ** @n@,
    \\            observation_count,
    \\            0,
    \\            .numerical_failure,
    \\        );
    \\        return;
    \\    };
    \\    var values = [_]f64{
;

const solver_entrypoint_after_initial =
    \\    };
    \\    if (!bombelliAllFinite(values)) {
    \\        output.* = bombelliFailureResult(
    \\            values,
    \\            observation_count,
    \\            residual_count,
    \\            .non_finite_initial,
    \\        );
    \\        return;
    \\    }
    \\    if (observation_count == 0) {
    \\        output.* = bombelliFailureResult(values, 0, 0, .empty_observations);
    \\        return;
    \\    }
    \\    for (observations) |observation| {
    \\        var observation_finite = true;
;

const solver_entrypoint_after_validation =
    \\        if (!observation_finite) {
    \\            output.* = bombelliFailureResult(
    \\                values,
    \\                observation_count,
    \\                residual_count,
    \\                .non_finite_observation,
    \\            );
    \\            return;
    \\        }
    \\    }
    \\    if (!bombelliWithinBounds(values)) {
    \\        if (bombelliConfig.initial_bounds == .reject) {
    \\            output.* = bombelliFailureResult(
    \\                values,
    \\                observation_count,
    \\                residual_count,
    \\                .infeasible_initial,
    \\            );
    \\            return;
    \\        }
    \\        values = bombelliProject(values);
    \\    }
    \\
    \\    var counters = bombelliCounters{};
    \\    var current = bombelliLinearize(observations, values);
    \\    counters.function_evaluations = 1;
    \\    counters.jacobian_evaluations = 1;
    \\    counters.observation_evaluations = current.visited;
    \\    if (current.failure != .none) {
    \\        output.* = bombelliFailedLinearizationResultAt(
    \\            values,
    \\            std.math.nan(f64),
    \\            std.math.nan(f64),
    \\            observation_count,
    \\            residual_count,
    \\            0,
    \\            counters,
    \\            std.math.nan(f64),
    \\            std.math.nan(f64),
    \\            current.failure,
    \\        );
    \\        return;
    \\    }
    \\
    \\    const initial_cost = current.cost;
    \\    var scales = bombelliConfig.parameter_scales;
    \\    bombelliUpdateScales(current.column_norms, &scales);
    \\    var scaled_factor = current.factor;
    \\    if (!scaled_factor.divideColumns(scales)) {
    \\        output.* = bombelliResultFrom(
    \\            values,
    \\            initial_cost,
    \\            current.cost,
    \\            observation_count,
    \\            residual_count,
    \\            0,
    \\            counters,
    \\            0.0,
    \\            current,
    \\            std.math.nan(f64),
    \\            std.math.nan(f64),
    \\            .numerical_failure,
    \\        );
    \\        return;
    \\    }
    \\    var damping = bombelliInitialDamping(current.column_norms, scales);
    \\    var nu: f64 = 2.0;
    \\    var step_norm: f64 = 0.0;
    \\
    \\    if (current.cost <= bombelliConfig.cost_tolerance) {
    \\        output.* = bombelliResultFrom(
    \\            values,
    \\            initial_cost,
    \\            current.cost,
    \\            observation_count,
    \\            residual_count,
    \\            0,
    \\            counters,
    \\            damping,
    \\            current,
    \\            step_norm,
    \\            bombelliProjectedOptimality(values, current.gradient, scales),
    \\            .converged_cost,
    \\        );
    \\        return;
    \\    }
    \\
    \\    for (0..@iterations@) |iteration| {
    \\        const gradient_norm =
    \\            bombelliProjectedOptimality(values, current.gradient, scales);
    \\        if (!std.math.isFinite(gradient_norm)) {
    \\            output.* = bombelliResultFrom(
    \\                values, initial_cost, current.cost, observation_count,
    \\                residual_count, iteration, counters, damping, current,
    \\                step_norm, gradient_norm, .numerical_failure,
    \\            );
    \\            return;
    \\        }
    \\        if (gradient_norm <= bombelliConfig.gradient_tolerance) {
    \\            output.* = bombelliResultFrom(
    \\                values, initial_cost, current.cost, observation_count,
    \\                residual_count, iteration, counters, damping, current,
    \\                step_norm, gradient_norm, .converged_gradient,
    \\            );
    \\            return;
    \\        }
    \\        if (counters.function_evaluations >=
    \\            bombelliConfig.max_function_evaluations)
    \\        {
    \\            output.* = bombelliResultFrom(
    \\                values, initial_cost, current.cost, observation_count,
    \\                residual_count, iteration, counters, damping, current,
    \\                step_norm, gradient_norm, .max_function_evaluations,
    \\            );
    \\            return;
    \\        }
    \\
    \\        var accepted = false;
    \\        var accepted_values = values;
    \\        var accepted_cost = current.cost;
    \\        var accepted_step = [_]f64{0.0} ** @n@;
    \\        var accepted_rho: f64 = 0.0;
    \\        var used_projected_gradient = false;
    \\
    \\        for (0..bombelliConfig.max_damping_trials) |_| {
    \\            if (counters.function_evaluations >=
    \\                bombelliConfig.max_function_evaluations - 1) break;
    \\            var damped = scaled_factor;
    \\            if (!damped.addDamping(damping)) {
    \\                counters.invalid_steps += 1;
    \\                bombelliIncreaseDamping(&damping, &nu);
    \\                continue;
    \\            }
    \\            const scaled_direction = damped.solve() orelse {
    \\                counters.invalid_steps += 1;
    \\                bombelliIncreaseDamping(&damping, &nu);
    \\                continue;
    \\            };
    \\            var candidate: [@n@]f64 = undefined;
    \\            for (0..@n@) |index| {
    \\                candidate[index] = std.math.clamp(
    \\                    values[index] + scaled_direction[index] / scales[index],
    \\                    bombelliConfig.lower[index],
    \\                    bombelliConfig.upper[index],
    \\                );
    \\                accepted_step[index] = candidate[index] - values[index];
    \\            }
    \\            if (!bombelliAllFinite(candidate) or
    \\                bombelliNormInf(accepted_step) == 0.0)
    \\            {
    \\                counters.rejected_steps += 1;
    \\                bombelliIncreaseDamping(&damping, &nu);
    \\                continue;
    \\            }
    \\            var scaled_step: [@n@]f64 = undefined;
    \\            for (0..@n@) |index| {
    \\                scaled_step[index] = accepted_step[index] * scales[index];
    \\            }
    \\            const model_norm = scaled_factor.transformedNorm(scaled_step);
    \\            const predicted = -(bombelliDot(current.gradient, accepted_step) +
    \\                0.5 * model_norm * model_norm);
    \\            if (!std.math.isFinite(predicted) or predicted <= 0.0) {
    \\                counters.invalid_steps += 1;
    \\                bombelliIncreaseDamping(&damping, &nu);
    \\                continue;
    \\            }
    \\            if (counters.function_evaluations >=
    \\                bombelliConfig.max_function_evaluations) break;
    \\            const objective_trial = bombelliObjective(observations, candidate);
    \\            counters.function_evaluations += 1;
    \\            counters.observation_evaluations += objective_trial.visited;
    \\            if (!objective_trial.valid) {
    \\                counters.invalid_steps += 1;
    \\                bombelliIncreaseDamping(&damping, &nu);
    \\                if (counters.invalid_steps >= bombelliConfig.max_invalid_steps) {
    \\                    output.* = bombelliResultFrom(
    \\                        values, initial_cost, current.cost, observation_count,
    \\                        residual_count, iteration, counters, damping, current,
    \\                        step_norm, gradient_norm, .too_many_invalid_trials,
    \\                    );
    \\                    return;
    \\                }
    \\                continue;
    \\            }
    \\            const actual = current.cost - objective_trial.cost;
    \\            const rho = actual / predicted;
    \\            if (std.math.isFinite(rho) and
    \\                rho > bombelliConfig.acceptance_threshold and actual > 0.0)
    \\            {
    \\                accepted = true;
    \\                accepted_values = candidate;
    \\                accepted_cost = objective_trial.cost;
    \\                accepted_rho = rho;
    \\                break;
    \\            }
    \\            counters.rejected_steps += 1;
    \\            bombelliIncreaseDamping(&damping, &nu);
    \\        }
    \\
    \\        if (!accepted) {
    \\            if (counters.function_evaluations >=
    \\                bombelliConfig.max_function_evaluations - 1)
    \\            {
    \\                output.* = bombelliResultFrom(
    \\                    values, initial_cost, current.cost, observation_count,
    \\                    residual_count, iteration, counters, damping, current,
    \\                    step_norm, gradient_norm, .max_function_evaluations,
    \\                );
    \\                return;
    \\            }
    \\            const direction = bombelliProjectedGradientDirection(
    \\                values,
    \\                current.gradient,
    \\                scales,
    \\            );
    \\            const trial = bombelliLineSearch(
    \\                observations,
    \\                values,
    \\                current.cost,
    \\                current.gradient,
    \\                direction,
    \\                bombelliConfig.max_function_evaluations -
    \\                    counters.function_evaluations - 1,
    \\            );
    \\            counters.function_evaluations += trial.evaluations;
    \\            counters.observation_evaluations += trial.visited;
    \\            counters.invalid_steps += trial.invalid;
    \\            if (!trial.accepted) {
    \\                const status: @name@Status =
    \\                    if (counters.function_evaluations >=
    \\                    bombelliConfig.max_function_evaluations - 1)
    \\                        .max_function_evaluations
    \\                    else
    \\                        .line_search_failed;
    \\                output.* = bombelliResultFrom(
    \\                    values, initial_cost, current.cost, observation_count,
    \\                    residual_count, iteration, counters, damping, current,
    \\                    step_norm, gradient_norm, status,
    \\                );
    \\                return;
    \\            }
    \\            accepted = true;
    \\            used_projected_gradient = true;
    \\            accepted_values = trial.values;
    \\            accepted_step = trial.step;
    \\            accepted_cost = trial.cost;
    \\            counters.projected_gradient_steps += 1;
    \\            bombelliIncreaseDamping(&damping, &nu);
    \\        }
    \\
    \\        const old_cost = current.cost;
    \\        const old_value_norm = bombelliScaledNorm(values, scales);
    \\        step_norm = bombelliScaledNorm(accepted_step, scales);
    \\        values = accepted_values;
    \\        counters.accepted_steps += 1;
    \\
    \\        current = bombelliLinearize(observations, values);
    \\        counters.function_evaluations += 1;
    \\        counters.jacobian_evaluations += 1;
    \\        counters.observation_evaluations += current.visited;
    \\        if (current.failure != .none) {
    \\            output.* = bombelliFailedLinearizationResultAt(
    \\                values, initial_cost, accepted_cost, observation_count,
    \\                residual_count, iteration + 1, counters, damping,
    \\                step_norm, current.failure,
    \\            );
    \\            return;
    \\        }
    \\        bombelliUpdateScales(current.column_norms, &scales);
    \\        scaled_factor = current.factor;
    \\        if (!scaled_factor.divideColumns(scales)) {
    \\            output.* = bombelliResultFrom(
    \\                values, initial_cost, current.cost, observation_count,
    \\                residual_count, iteration + 1, counters, damping, current,
    \\                step_norm, std.math.nan(f64), .numerical_failure,
    \\            );
    \\            return;
    \\        }
    \\        if (!used_projected_gradient) {
    \\            const update = @max(
    \\                1.0 / 3.0,
    \\                1.0 - std.math.pow(f64, 2.0 * accepted_rho - 1.0, 3.0),
    \\            );
    \\            damping = std.math.clamp(
    \\                damping * update,
    \\                bombelliConfig.minimum_damping,
    \\                bombelliConfig.maximum_damping,
    \\            );
    \\            nu = 2.0;
    \\        }
    \\
    \\        const new_gradient_norm =
    \\            bombelliProjectedOptimality(values, current.gradient, scales);
    \\        var status: ?@name@Status = null;
    \\        if (new_gradient_norm <= bombelliConfig.gradient_tolerance) {
    \\            status = .converged_gradient;
    \\        } else if (current.cost <= bombelliConfig.cost_tolerance) {
    \\            status = .converged_cost;
    \\        } else if (step_norm <= bombelliConfig.step_tolerance *
    \\            (bombelliConfig.step_tolerance + old_value_norm))
    \\        {
    \\            status = .converged_step;
    \\        } else if (!used_projected_gradient and accepted_rho >= 0.25 and
    \\            old_cost - current.cost <=
    \\                bombelliConfig.function_tolerance * @max(old_cost, 1.0))
    \\        {
    \\            status = .converged_cost;
    \\        }
    \\        if (status) |terminal| {
    \\            output.* = bombelliResultFrom(
    \\                values, initial_cost, current.cost, observation_count,
    \\                residual_count, iteration + 1, counters, damping, current,
    \\                step_norm, new_gradient_norm, terminal,
    \\            );
    \\            return;
    \\        }
    \\    }
    \\
    \\    output.* = bombelliResultFrom(
    \\        values,
    \\        initial_cost,
    \\        current.cost,
    \\        observation_count,
    \\        residual_count,
    \\        @iterations@,
    \\        counters,
    \\        damping,
    \\        current,
    \\        step_norm,
    \\        bombelliProjectedOptimality(values, current.gradient, scales),
    \\        .max_iterations,
    \\    );
    \\}
    \\
;
