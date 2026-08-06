//! Allocation-free nonlinear least squares over runtime observation slices.
//!
//! A fixed symbolic residual block is evaluated once per observation. Its
//! weighted Jacobian rows are immediately folded into a Givens QR factor, so
//! solver storage is `O(N²)` in the parameter count and independent of the
//! number of observations.

const std = @import("std");
const ast = @import("../../expression.zig");
const evaluation = @import("../runtime/evaluation.zig");
const loss_functions = @import("loss.zig");
const model_linearization = @import("../model/linearization.zig");
const streaming_qr = @import("streaming_qr.zig");
const types = @import("types.zig");

/// Completion reason from a runtime-observation least-squares solve.
pub const Status = enum {
    converged_gradient,
    converged_cost,
    converged_step,
    max_iterations,
    max_function_evaluations,
    empty_observations,
    infeasible_initial,
    non_finite_initial,
    non_finite_observation,
    non_finite_jacobian,
    too_many_invalid_trials,
    line_search_failed,
    numerical_failure,
};

/// Whether a parameter is constrained at the returned point.
pub const BoundActivity = enum {
    free,
    lower,
    upper,
    fixed,
};

/// A fixed residual kernel interpreted over a runtime observation collection.
pub fn Problem(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
) type {
    return struct {
        residuals: ast.ExprVector(R),
        jacobian_program: ast.ExprMatrix(R, N),
        linearization_program: model_linearization.Program(R, N),
        variables: [N][]const u8,
        data: [P][]const u8,

        const Self = @This();

        /// Compiles the symbolic row kernel and numerical policy into a solver.
        pub fn compile(
            comptime self: Self,
            comptime options: anytype,
        ) Solver(R, N, P, maxIterations(options)) {
            return compileProblem(R, N, P, self, options);
        }
    };
}

pub fn makeProblem(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
    comptime model: anytype,
) Problem(R, N, P) {
    const residuals = comptime model.residuals.simplify();
    const jacobian = comptime model.jacobian().simplify();
    return .{
        .residuals = residuals,
        .jacobian_program = jacobian,
        .linearization_program = model_linearization.make(
            R,
            N,
            residuals,
            jacobian,
        ),
        .variables = model.variables,
        .data = model.data,
    };
}

/// Result of fitting a runtime observation collection.
pub fn Result(comptime N: usize) type {
    return struct {
        values: [N]f64,
        initial_cost: f64,
        cost: f64,
        observation_count: usize,
        residual_count: usize,
        iterations: usize,
        function_evaluations: usize,
        jacobian_evaluations: usize,
        observation_evaluations: usize,
        accepted_steps: usize,
        rejected_steps: usize,
        projected_gradient_steps: usize,
        invalid_steps: usize,
        rank: usize,
        active_bounds: [N]BoundActivity,
        gradient_norm: f64,
        step_norm: f64,
        damping: f64,
        status: Status,

        /// Whether a numerical convergence criterion was satisfied.
        pub fn converged(self: @This()) bool {
            return switch (self.status) {
                .converged_gradient,
                .converged_cost,
                .converged_step,
                => true,
                else => false,
            };
        }
    };
}

fn Bounds(comptime N: usize) type {
    return struct {
        lower: [N]f64,
        upper: [N]f64,
    };
}

/// A compiled runtime-row nonlinear least-squares solver.
pub fn Solver(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
    comptime max_iterations: usize,
) type {
    return struct {
        residuals: ast.ExprVector(R),
        linearization_program: model_linearization.Program(R, N),
        variables: [N][]const u8,
        data: [P][]const u8,
        loss: types.Loss,
        scaling: types.LeastSquaresScaling,
        parameter_scales: [N]f64,
        bounds: Bounds(N),
        initial_bounds_policy: types.InitialBoundsPolicy,
        function_tolerance: f64,
        gradient_tolerance: f64,
        step_tolerance: f64,
        cost_tolerance: f64,
        damping_tau: f64,
        minimum_damping: f64,
        maximum_damping: f64,
        acceptance_threshold: f64,
        armijo_constant: f64,
        backtrack_factor: f64,
        rank_tolerance: f64,
        max_function_evaluations: usize,
        max_damping_trials: usize,
        max_line_search_steps: usize,
        max_invalid_steps: usize,

        pub const maximum_iterations = max_iterations;
        pub const residuals_per_observation = R;
        pub const parameter_count = N;
        const Self = @This();

        /// Returns a fitted parameter by its declared name.
        pub inline fn parameter(
            comptime self: Self,
            result: Result(N),
            comptime variable: anytype,
        ) f64 {
            return result.values[self.parameterIndex(variable)];
        }

        /// Returns the array index assigned to a declared parameter.
        pub fn parameterIndex(
            comptime self: Self,
            comptime variable: anytype,
        ) usize {
            const name = @tagName(variable);
            inline for (self.variables, 0..) |candidate, index| {
                if (comptime std.mem.eql(u8, name, candidate)) return index;
            }
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares variable '.{s}' is not declared",
                .{name},
            ));
        }

        /// Emits this compiled runtime-observation fitter as a standalone
        /// Zig or C callable. The symbolic residual/Jacobian kernel and every
        /// numerical policy option are baked into the emitted source.
        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(@import("../core/limits.zig").eval_branch.solve);
            return @import("../codegen/emit.zig").emitRowLeastSquares(
                self,
                options,
            );
        }

        /// Fits `inputs.initial` to `inputs.observations`.
        ///
        /// Observations may be a fixed array, pointer to a fixed array, or
        /// slice. Each element must be a struct containing the declared data
        /// fields; additional metadata fields are allowed.
        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) Result(N) {
            comptime validateEvalInput(
                N,
                P,
                self.variables,
                self.data,
                @TypeOf(inputs),
            );
            const observations = inputs.observations;
            const observation_count = observations.len;
            const residual_count = std.math.mul(
                usize,
                observation_count,
                R,
            ) catch {
                return failureResult(
                    N,
                    [_]f64{std.math.nan(f64)} ** N,
                    observation_count,
                    0,
                    .numerical_failure,
                );
            };

            var values = initialValues(N, self.variables, inputs.initial);
            if (!allFinite(values)) {
                return failureResult(
                    N,
                    values,
                    observation_count,
                    residual_count,
                    .non_finite_initial,
                );
            }
            if (observation_count == 0) {
                return failureResult(
                    N,
                    values,
                    0,
                    0,
                    .empty_observations,
                );
            }
            for (observations) |observation| {
                if (!observationFinite(P, self.data, observation)) {
                    return failureResult(
                        N,
                        values,
                        observation_count,
                        residual_count,
                        .non_finite_observation,
                    );
                }
            }
            if (!withinBounds(N, values, self.bounds)) {
                if (self.initial_bounds_policy == .reject) {
                    return failureResult(
                        N,
                        values,
                        observation_count,
                        residual_count,
                        .infeasible_initial,
                    );
                }
                values = project(N, values, self.bounds);
            }

            var counters = Counters{};
            var current = linearize(
                R,
                N,
                self,
                observations,
                values,
            );
            counters.function_evaluations = 1;
            counters.jacobian_evaluations = 1;
            counters.observation_evaluations = current.visited;
            if (current.failure != .none) {
                return failedLinearizationResult(
                    N,
                    values,
                    observation_count,
                    residual_count,
                    counters,
                    current.failure,
                );
            }

            const initial_cost = current.cost;
            var scales = self.parameter_scales;
            updateScales(N, self.scaling, current.column_norms, &scales);
            var scaled_factor = current.factor;
            if (!scaled_factor.divideColumns(scales)) {
                return resultFrom(
                    N,
                    values,
                    initial_cost,
                    current.cost,
                    observation_count,
                    residual_count,
                    0,
                    counters,
                    0,
                    scales,
                    current,
                    std.math.nan(f64),
                    std.math.nan(f64),
                    .numerical_failure,
                    self.bounds,
                );
            }
            var damping = initialDamping(
                N,
                current.column_norms,
                scales,
                self.damping_tau,
                self.minimum_damping,
                self.maximum_damping,
            );
            var nu: f64 = 2.0;
            var step_norm: f64 = 0.0;

            if (current.cost <= self.cost_tolerance) {
                return resultFrom(
                    N,
                    values,
                    initial_cost,
                    current.cost,
                    observation_count,
                    residual_count,
                    0,
                    counters,
                    damping,
                    scales,
                    current,
                    step_norm,
                    projectedOptimality(
                        N,
                        values,
                        current.gradient,
                        scales,
                        self.bounds,
                    ),
                    .converged_cost,
                    self.bounds,
                );
            }

            for (0..max_iterations) |iteration| {
                const gradient_norm = projectedOptimality(
                    N,
                    values,
                    current.gradient,
                    scales,
                    self.bounds,
                );
                if (!std.math.isFinite(gradient_norm)) {
                    return resultFrom(
                        N,
                        values,
                        initial_cost,
                        current.cost,
                        observation_count,
                        residual_count,
                        iteration,
                        counters,
                        damping,
                        scales,
                        current,
                        step_norm,
                        gradient_norm,
                        .numerical_failure,
                        self.bounds,
                    );
                }
                if (gradient_norm <= self.gradient_tolerance) {
                    return resultFrom(
                        N,
                        values,
                        initial_cost,
                        current.cost,
                        observation_count,
                        residual_count,
                        iteration,
                        counters,
                        damping,
                        scales,
                        current,
                        step_norm,
                        gradient_norm,
                        .converged_gradient,
                        self.bounds,
                    );
                }
                if (counters.function_evaluations >=
                    self.max_function_evaluations)
                {
                    return resultFrom(
                        N,
                        values,
                        initial_cost,
                        current.cost,
                        observation_count,
                        residual_count,
                        iteration,
                        counters,
                        damping,
                        scales,
                        current,
                        step_norm,
                        gradient_norm,
                        .max_function_evaluations,
                        self.bounds,
                    );
                }

                var accepted = false;
                var accepted_values = values;
                var accepted_cost = current.cost;
                var accepted_step = [_]f64{0.0} ** N;
                var accepted_rho: f64 = 0.0;
                var used_projected_gradient = false;

                for (0..self.max_damping_trials) |_| {
                    // A successful objective trial must be followed by one
                    // fused value-and-Jacobian pass at the accepted point.
                    // Reserve that pass so the advertised evaluation budget
                    // remains a hard upper bound.
                    if (counters.function_evaluations >=
                        self.max_function_evaluations - 1)
                    {
                        break;
                    }
                    var damped = scaled_factor;
                    if (!damped.addDamping(damping)) {
                        counters.invalid_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    }
                    const scaled_direction = damped.solve() orelse {
                        counters.invalid_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    };
                    var candidate: [N]f64 = undefined;
                    for (0..N) |index| {
                        candidate[index] = std.math.clamp(
                            values[index] +
                                scaled_direction[index] / scales[index],
                            self.bounds.lower[index],
                            self.bounds.upper[index],
                        );
                        accepted_step[index] =
                            candidate[index] - values[index];
                    }
                    if (!allFinite(candidate) or
                        normInf(accepted_step) == 0.0)
                    {
                        counters.rejected_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    }
                    var scaled_step: [N]f64 = undefined;
                    for (0..N) |index| {
                        scaled_step[index] =
                            accepted_step[index] * scales[index];
                    }
                    const model_norm =
                        scaled_factor.transformedNorm(scaled_step);
                    const predicted = -(dot(
                        current.gradient,
                        accepted_step,
                    ) + 0.5 * model_norm * model_norm);
                    if (!std.math.isFinite(predicted) or predicted <= 0.0) {
                        counters.invalid_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    }
                    if (counters.function_evaluations >=
                        self.max_function_evaluations)
                    {
                        break;
                    }
                    const trial = objective(
                        R,
                        N,
                        self,
                        observations,
                        candidate,
                    );
                    counters.function_evaluations += 1;
                    counters.observation_evaluations += trial.visited;
                    if (!trial.valid) {
                        counters.invalid_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        if (counters.invalid_steps >=
                            self.max_invalid_steps)
                        {
                            return resultFrom(
                                N,
                                values,
                                initial_cost,
                                current.cost,
                                observation_count,
                                residual_count,
                                iteration,
                                counters,
                                damping,
                                scales,
                                current,
                                step_norm,
                                gradient_norm,
                                .too_many_invalid_trials,
                                self.bounds,
                            );
                        }
                        continue;
                    }
                    const actual = current.cost - trial.cost;
                    const rho = actual / predicted;
                    if (std.math.isFinite(rho) and
                        rho > self.acceptance_threshold and actual > 0.0)
                    {
                        accepted = true;
                        accepted_values = candidate;
                        accepted_cost = trial.cost;
                        accepted_rho = rho;
                        break;
                    }
                    counters.rejected_steps += 1;
                    increaseDamping(
                        &damping,
                        &nu,
                        self.maximum_damping,
                    );
                }

                if (!accepted) {
                    if (counters.function_evaluations >=
                        self.max_function_evaluations - 1)
                    {
                        return resultFrom(
                            N,
                            values,
                            initial_cost,
                            current.cost,
                            observation_count,
                            residual_count,
                            iteration,
                            counters,
                            damping,
                            scales,
                            current,
                            step_norm,
                            gradient_norm,
                            .max_function_evaluations,
                            self.bounds,
                        );
                    }
                    const direction = projectedGradientDirection(
                        N,
                        values,
                        current.gradient,
                        scales,
                        self.bounds,
                    );
                    const trial = lineSearch(
                        R,
                        N,
                        self,
                        observations,
                        values,
                        current.cost,
                        current.gradient,
                        direction,
                        self.max_function_evaluations -
                            counters.function_evaluations - 1,
                    );
                    counters.function_evaluations += trial.evaluations;
                    counters.observation_evaluations += trial.visited;
                    counters.invalid_steps += trial.invalid;
                    if (!trial.accepted) {
                        const status: Status =
                            if (counters.function_evaluations >=
                            self.max_function_evaluations - 1)
                                .max_function_evaluations
                            else
                                .line_search_failed;
                        return resultFrom(
                            N,
                            values,
                            initial_cost,
                            current.cost,
                            observation_count,
                            residual_count,
                            iteration,
                            counters,
                            damping,
                            scales,
                            current,
                            step_norm,
                            gradient_norm,
                            status,
                            self.bounds,
                        );
                    }
                    accepted = true;
                    used_projected_gradient = true;
                    accepted_values = trial.values;
                    accepted_step = trial.step;
                    accepted_cost = trial.cost;
                    counters.projected_gradient_steps += 1;
                    increaseDamping(
                        &damping,
                        &nu,
                        self.maximum_damping,
                    );
                }

                const old_cost = current.cost;
                const old_value_norm = scaledNorm(N, values, scales);
                step_norm = scaledNorm(N, accepted_step, scales);
                values = accepted_values;
                counters.accepted_steps += 1;

                current = linearize(
                    R,
                    N,
                    self,
                    observations,
                    values,
                );
                counters.function_evaluations += 1;
                counters.jacobian_evaluations += 1;
                counters.observation_evaluations += current.visited;
                if (current.failure != .none) {
                    return failedLinearizationResultAt(
                        N,
                        values,
                        initial_cost,
                        accepted_cost,
                        observation_count,
                        residual_count,
                        iteration + 1,
                        counters,
                        damping,
                        step_norm,
                        current.failure,
                    );
                }
                // The accepted objective pass and fused pass should agree to
                // rounding. Use the fused value so all returned diagnostics
                // describe exactly the same point.
                accepted_cost = current.cost;
                updateScales(
                    N,
                    self.scaling,
                    current.column_norms,
                    &scales,
                );
                scaled_factor = current.factor;
                if (!scaled_factor.divideColumns(scales)) {
                    return resultFrom(
                        N,
                        values,
                        initial_cost,
                        current.cost,
                        observation_count,
                        residual_count,
                        iteration + 1,
                        counters,
                        damping,
                        scales,
                        current,
                        step_norm,
                        std.math.nan(f64),
                        .numerical_failure,
                        self.bounds,
                    );
                }
                if (!used_projected_gradient) {
                    const update = @max(
                        1.0 / 3.0,
                        1.0 - std.math.pow(
                            f64,
                            2.0 * accepted_rho - 1.0,
                            3.0,
                        ),
                    );
                    damping = std.math.clamp(
                        damping * update,
                        self.minimum_damping,
                        self.maximum_damping,
                    );
                    nu = 2.0;
                }

                const new_gradient_norm = projectedOptimality(
                    N,
                    values,
                    current.gradient,
                    scales,
                    self.bounds,
                );
                var status: ?Status = null;
                if (new_gradient_norm <= self.gradient_tolerance) {
                    status = .converged_gradient;
                } else if (current.cost <= self.cost_tolerance) {
                    status = .converged_cost;
                } else if (step_norm <= self.step_tolerance *
                    (self.step_tolerance + old_value_norm))
                {
                    status = .converged_step;
                } else if (!used_projected_gradient and
                    accepted_rho >= 0.25 and
                    old_cost - current.cost <=
                        self.function_tolerance * @max(old_cost, 1.0))
                {
                    status = .converged_cost;
                }
                if (status) |terminal| {
                    return resultFrom(
                        N,
                        values,
                        initial_cost,
                        current.cost,
                        observation_count,
                        residual_count,
                        iteration + 1,
                        counters,
                        damping,
                        scales,
                        current,
                        step_norm,
                        new_gradient_norm,
                        terminal,
                        self.bounds,
                    );
                }
            }

            return resultFrom(
                N,
                values,
                initial_cost,
                current.cost,
                observation_count,
                residual_count,
                max_iterations,
                counters,
                damping,
                scales,
                current,
                step_norm,
                projectedOptimality(
                    N,
                    values,
                    current.gradient,
                    scales,
                    self.bounds,
                ),
                .max_iterations,
                self.bounds,
            );
        }
    };
}

const Counters = struct {
    function_evaluations: usize = 0,
    jacobian_evaluations: usize = 0,
    observation_evaluations: usize = 0,
    accepted_steps: usize = 0,
    rejected_steps: usize = 0,
    projected_gradient_steps: usize = 0,
    invalid_steps: usize = 0,
};

const LinearizationFailure = enum {
    none,
    non_finite_residual,
    non_finite_jacobian,
    numerical,
};

fn Linearization(comptime N: usize) type {
    return struct {
        cost: f64,
        gradient: [N]f64,
        column_norms: [N]f64,
        factor: streaming_qr.Factor(N),
        rank: usize,
        visited: usize,
        failure: LinearizationFailure,
    };
}

fn linearize(
    comptime R: usize,
    comptime N: usize,
    comptime solver: anytype,
    observations: anytype,
    values: [N]f64,
) Linearization(N) {
    var result = Linearization(N){
        .cost = 0.0,
        .gradient = [_]f64{0.0} ** N,
        .column_norms = [_]f64{0.0} ** N,
        .factor = streaming_qr.Factor(N).init(),
        .rank = 0,
        .visited = 0,
        .failure = .none,
    };
    for (observations) |observation| {
        result.visited += 1;
        const block = solver.linearization_program.evalWithVariables(
            observation,
            solver.variables,
            values,
        );
        for (0..R) |row_index| {
            const residual = block.values[row_index];
            if (!std.math.isFinite(residual)) {
                result.failure = .non_finite_residual;
                return result;
            }
            if (!allFinite(block.jacobian[row_index])) {
                result.failure = .non_finite_jacobian;
                return result;
            }
            const robust = loss_functions.evaluate(solver.loss, residual);
            if (!std.math.isFinite(robust.cost) or
                !std.math.isFinite(robust.sqrt_weight))
            {
                result.failure = .numerical;
                return result;
            }
            result.cost += robust.cost;
            if (!std.math.isFinite(result.cost)) {
                result.failure = .numerical;
                return result;
            }
            const weighted_residual = robust.sqrt_weight * residual;
            var weighted_row: [N]f64 = undefined;
            for (0..N) |column| {
                weighted_row[column] =
                    robust.sqrt_weight * block.jacobian[row_index][column];
                result.gradient[column] +=
                    weighted_row[column] * weighted_residual;
                result.column_norms[column] = std.math.hypot(
                    result.column_norms[column],
                    weighted_row[column],
                );
            }
            if (!allFinite(weighted_row) or
                !allFinite(result.gradient) or
                !allFinite(result.column_norms) or
                !result.factor.addRow(
                    weighted_row,
                    -weighted_residual,
                ))
            {
                result.failure = .numerical;
                return result;
            }
        }
    }
    result.rank = result.factor.rank(solver.rank_tolerance);
    return result;
}

const Objective = struct {
    cost: f64,
    visited: usize,
    valid: bool,
};

fn objective(
    comptime R: usize,
    comptime N: usize,
    comptime solver: anytype,
    observations: anytype,
    values: [N]f64,
) Objective {
    var result = Objective{ .cost = 0.0, .visited = 0, .valid = true };
    for (observations) |observation| {
        result.visited += 1;
        const residuals = evaluation.evaluateVectorWithVariables(
            R,
            N,
            solver.residuals,
            observation,
            solver.variables,
            values,
        );
        for (residuals) |residual| {
            if (!std.math.isFinite(residual)) {
                result.valid = false;
                return result;
            }
            const robust = loss_functions.evaluate(solver.loss, residual);
            result.cost += robust.cost;
            if (!std.math.isFinite(robust.cost) or
                !std.math.isFinite(result.cost))
            {
                result.valid = false;
                return result;
            }
        }
    }
    return result;
}

fn Trial(comptime N: usize) type {
    return struct {
        accepted: bool,
        values: [N]f64,
        step: [N]f64,
        cost: f64,
        evaluations: usize,
        visited: usize,
        invalid: usize,
    };
}

fn lineSearch(
    comptime R: usize,
    comptime N: usize,
    comptime solver: anytype,
    observations: anytype,
    values: [N]f64,
    cost: f64,
    gradient: [N]f64,
    direction: [N]f64,
    max_evaluations: usize,
) Trial(N) {
    var result = Trial(N){
        .accepted = false,
        .values = values,
        .step = [_]f64{0.0} ** N,
        .cost = cost,
        .evaluations = 0,
        .visited = 0,
        .invalid = 0,
    };
    var alpha: f64 = 1.0;
    for (0..@min(solver.max_line_search_steps, max_evaluations)) |_| {
        var candidate: [N]f64 = undefined;
        for (0..N) |index| {
            candidate[index] = std.math.clamp(
                values[index] + alpha * direction[index],
                solver.bounds.lower[index],
                solver.bounds.upper[index],
            );
            result.step[index] = candidate[index] - values[index];
        }
        const directional_derivative = dot(gradient, result.step);
        if (!std.math.isFinite(directional_derivative) or
            directional_derivative >= 0.0 or
            normInf(result.step) == 0.0)
        {
            alpha *= solver.backtrack_factor;
            continue;
        }
        const trial = objective(
            R,
            N,
            solver,
            observations,
            candidate,
        );
        result.evaluations += 1;
        result.visited += trial.visited;
        if (!trial.valid) {
            result.invalid += 1;
            alpha *= solver.backtrack_factor;
            continue;
        }
        if (trial.cost <=
            cost + solver.armijo_constant * directional_derivative)
        {
            result.accepted = true;
            result.values = candidate;
            result.cost = trial.cost;
            return result;
        }
        alpha *= solver.backtrack_factor;
    }
    return result;
}

fn resultFrom(
    comptime N: usize,
    values: [N]f64,
    initial_cost: f64,
    cost: f64,
    observation_count: usize,
    residual_count: usize,
    iterations: usize,
    counters: Counters,
    damping: f64,
    scales: [N]f64,
    linearization: Linearization(N),
    step_norm: f64,
    gradient_norm: f64,
    status: Status,
    bounds: Bounds(N),
) Result(N) {
    _ = scales;
    return .{
        .values = values,
        .initial_cost = initial_cost,
        .cost = cost,
        .observation_count = observation_count,
        .residual_count = residual_count,
        .iterations = iterations,
        .function_evaluations = counters.function_evaluations,
        .jacobian_evaluations = counters.jacobian_evaluations,
        .observation_evaluations = counters.observation_evaluations,
        .accepted_steps = counters.accepted_steps,
        .rejected_steps = counters.rejected_steps,
        .projected_gradient_steps = counters.projected_gradient_steps,
        .invalid_steps = counters.invalid_steps,
        .rank = linearization.rank,
        .active_bounds = activeBounds(
            N,
            values,
            linearization.gradient,
            bounds,
        ),
        .gradient_norm = gradient_norm,
        .step_norm = step_norm,
        .damping = damping,
        .status = status,
    };
}

fn failedLinearizationResult(
    comptime N: usize,
    values: [N]f64,
    observation_count: usize,
    residual_count: usize,
    counters: Counters,
    failure: LinearizationFailure,
) Result(N) {
    return failedLinearizationResultAt(
        N,
        values,
        std.math.nan(f64),
        std.math.nan(f64),
        observation_count,
        residual_count,
        0,
        counters,
        std.math.nan(f64),
        std.math.nan(f64),
        failure,
    );
}

fn failedLinearizationResultAt(
    comptime N: usize,
    values: [N]f64,
    initial_cost: f64,
    cost: f64,
    observation_count: usize,
    residual_count: usize,
    iterations: usize,
    counters: Counters,
    damping: f64,
    step_norm: f64,
    failure: LinearizationFailure,
) Result(N) {
    return .{
        .values = values,
        .initial_cost = initial_cost,
        .cost = cost,
        .observation_count = observation_count,
        .residual_count = residual_count,
        .iterations = iterations,
        .function_evaluations = counters.function_evaluations,
        .jacobian_evaluations = counters.jacobian_evaluations,
        .observation_evaluations = counters.observation_evaluations,
        .accepted_steps = counters.accepted_steps,
        .rejected_steps = counters.rejected_steps,
        .projected_gradient_steps = counters.projected_gradient_steps,
        .invalid_steps = counters.invalid_steps,
        .rank = 0,
        .active_bounds = [_]BoundActivity{.free} ** N,
        .gradient_norm = std.math.nan(f64),
        .step_norm = step_norm,
        .damping = damping,
        .status = switch (failure) {
            .non_finite_residual => if (counters.accepted_steps == 0)
                .non_finite_initial
            else
                .numerical_failure,
            .non_finite_jacobian => .non_finite_jacobian,
            .numerical => .numerical_failure,
            .none => unreachable,
        },
    };
}

fn failureResult(
    comptime N: usize,
    values: [N]f64,
    observation_count: usize,
    residual_count: usize,
    status: Status,
) Result(N) {
    return .{
        .values = values,
        .initial_cost = std.math.nan(f64),
        .cost = std.math.nan(f64),
        .observation_count = observation_count,
        .residual_count = residual_count,
        .iterations = 0,
        .function_evaluations = 0,
        .jacobian_evaluations = 0,
        .observation_evaluations = 0,
        .accepted_steps = 0,
        .rejected_steps = 0,
        .projected_gradient_steps = 0,
        .invalid_steps = 0,
        .rank = 0,
        .active_bounds = [_]BoundActivity{.free} ** N,
        .gradient_norm = std.math.nan(f64),
        .step_norm = std.math.nan(f64),
        .damping = std.math.nan(f64),
        .status = status,
    };
}

fn maxIterations(comptime options: anytype) usize {
    const value = integerOption(options, "max_iterations", 50);
    if (value == 0) {
        @compileError("Bombelli row least-squares max_iterations must be positive");
    }
    return value;
}

fn compileProblem(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
    comptime problem: Problem(R, N, P),
    comptime options: anytype,
) Solver(R, N, P, maxIterations(options)) {
    validateOptions(options);
    requireOptionalTag(
        options,
        "algorithm",
        "levenberg_marquardt",
        "Bombelli row least-squares requires '.algorithm = .levenberg_marquardt'",
    );
    requireOptionalTag(
        options,
        "jacobian",
        "symbolic",
        "Bombelli row least-squares requires '.jacobian = .symbolic'",
    );
    requireOptionalTag(
        options,
        "linear_solver",
        "streaming_qr",
        "Bombelli row least-squares requires '.linear_solver = .streaming_qr'",
    );

    const generic_tolerance = option(options, "tolerance", 1e-8);
    const function_tolerance = option(
        options,
        "function_tolerance",
        generic_tolerance,
    );
    const gradient_tolerance = option(
        options,
        "gradient_tolerance",
        generic_tolerance,
    );
    const step_tolerance = option(
        options,
        "step_tolerance",
        generic_tolerance,
    );
    const cost_tolerance = option(options, "cost_tolerance", 0.0);
    validateNonnegativeFinite(function_tolerance, "function_tolerance");
    validateNonnegativeFinite(gradient_tolerance, "gradient_tolerance");
    validateNonnegativeFinite(step_tolerance, "step_tolerance");
    validateNonnegativeFinite(cost_tolerance, "cost_tolerance");

    const configured_loss = parseLoss(options);
    if (!std.math.isFinite(configured_loss.scale) or
        configured_loss.scale <= 0.0)
    {
        @compileError("Bombelli row least-squares loss scale must be positive and finite");
    }
    const scale_configuration = parseScales(
        N,
        problem.variables,
        options,
    );
    const configured_bounds = parseBounds(
        N,
        problem.variables,
        options,
    );
    const initial_bounds_policy: types.InitialBoundsPolicy =
        if (@hasField(@TypeOf(options), "initial_bounds"))
            @as(types.InitialBoundsPolicy, options.initial_bounds)
        else
            .reject;

    const damping_tau = option(options, "damping_tau", 1e-3);
    const minimum_damping = option(
        options,
        "minimum_damping",
        std.math.floatEps(f64),
    );
    const maximum_damping = option(
        options,
        "maximum_damping",
        1.0 / std.math.floatEps(f64) / std.math.floatEps(f64),
    );
    validatePositiveFinite(damping_tau, "damping_tau");
    validatePositiveFinite(minimum_damping, "minimum_damping");
    validatePositiveFinite(maximum_damping, "maximum_damping");
    if (minimum_damping > maximum_damping) {
        @compileError("Bombelli row least-squares minimum_damping exceeds maximum_damping");
    }
    const acceptance_threshold =
        option(options, "acceptance_threshold", 1e-4);
    if (!std.math.isFinite(acceptance_threshold) or
        acceptance_threshold < 0.0 or acceptance_threshold >= 1.0)
    {
        @compileError("Bombelli row least-squares acceptance_threshold must be in [0, 1)");
    }
    const armijo_constant = option(options, "armijo_constant", 1e-4);
    if (!std.math.isFinite(armijo_constant) or
        armijo_constant <= 0.0 or armijo_constant >= 1.0)
    {
        @compileError("Bombelli row least-squares armijo_constant must be in (0, 1)");
    }
    const backtrack_factor = option(options, "backtrack_factor", 0.5);
    if (!std.math.isFinite(backtrack_factor) or
        backtrack_factor <= 0.0 or backtrack_factor >= 1.0)
    {
        @compileError("Bombelli row least-squares backtrack_factor must be in (0, 1)");
    }
    const rank_tolerance = option(
        options,
        "rank_tolerance",
        @as(f64, @floatFromInt(N)) * std.math.floatEps(f64),
    );
    validateNonnegativeFinite(rank_tolerance, "rank_tolerance");

    const max_function_evaluations = integerOption(
        options,
        "max_function_evaluations",
        10_000,
    );
    const max_damping_trials =
        integerOption(options, "max_damping_trials", 10);
    const max_line_search_steps =
        integerOption(options, "max_line_search_steps", 20);
    const max_invalid_steps =
        integerOption(options, "max_invalid_steps", 5);
    if (max_function_evaluations == 0 or
        max_damping_trials == 0 or
        max_line_search_steps == 0 or
        max_invalid_steps == 0)
    {
        @compileError("Bombelli row least-squares iteration limits must be positive");
    }

    return .{
        .residuals = problem.residuals,
        .linearization_program = problem.linearization_program,
        .variables = problem.variables,
        .data = problem.data,
        .loss = configured_loss,
        .scaling = scale_configuration.kind,
        .parameter_scales = scale_configuration.values,
        .bounds = configured_bounds,
        .initial_bounds_policy = initial_bounds_policy,
        .function_tolerance = function_tolerance,
        .gradient_tolerance = gradient_tolerance,
        .step_tolerance = step_tolerance,
        .cost_tolerance = cost_tolerance,
        .damping_tau = damping_tau,
        .minimum_damping = minimum_damping,
        .maximum_damping = maximum_damping,
        .acceptance_threshold = acceptance_threshold,
        .armijo_constant = armijo_constant,
        .backtrack_factor = backtrack_factor,
        .rank_tolerance = rank_tolerance,
        .max_function_evaluations = max_function_evaluations,
        .max_damping_trials = max_damping_trials,
        .max_line_search_steps = max_line_search_steps,
        .max_invalid_steps = max_invalid_steps,
    };
}

fn validateOptions(comptime options: anytype) void {
    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("Bombelli row least-squares compile options must be a struct");
    }
    const allowed = [_][]const u8{
        "algorithm",
        "jacobian",
        "linear_solver",
        "max_iterations",
        "tolerance",
        "function_tolerance",
        "gradient_tolerance",
        "step_tolerance",
        "cost_tolerance",
        "loss",
        "loss_scale",
        "scaling",
        "scales",
        "bounds",
        "initial_bounds",
        "damping_tau",
        "minimum_damping",
        "maximum_damping",
        "acceptance_threshold",
        "armijo_constant",
        "backtrack_factor",
        "rank_tolerance",
        "max_function_evaluations",
        "max_damping_trials",
        "max_line_search_steps",
        "max_invalid_steps",
    };
    for (@typeInfo(Options).@"struct".fields) |field| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, field.name, name)) known = true;
        }
        if (!known) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares option '.{s}' is not recognized",
                .{field.name},
            ));
        }
    }
}

fn requireOptionalTag(
    comptime options: anytype,
    comptime field: []const u8,
    comptime expected: []const u8,
    comptime message: []const u8,
) void {
    if (@hasField(@TypeOf(options), field) and
        !std.mem.eql(u8, @tagName(@field(options, field)), expected))
    {
        @compileError(message);
    }
}

fn parseLoss(comptime options: anytype) types.Loss {
    if (!@hasField(@TypeOf(options), "loss")) {
        if (@hasField(@TypeOf(options), "loss_scale")) {
            @compileError("Bombelli row least-squares loss_scale requires an enum loss");
        }
        return types.loss.linear();
    }
    if (@TypeOf(options.loss) == types.Loss) {
        if (@hasField(@TypeOf(options), "loss_scale")) {
            @compileError("Bombelli typed row least-squares losses already contain their scale");
        }
        return options.loss;
    }
    const name = @tagName(options.loss);
    if (std.mem.eql(u8, name, "linear")) {
        if (@hasField(@TypeOf(options), "loss_scale")) {
            @compileError("Bombelli linear row least-squares loss does not use loss_scale");
        }
        return types.loss.linear();
    }
    const scale = option(options, "loss_scale", 1.0);
    if (std.mem.eql(u8, name, "huber")) return types.loss.huber(scale);
    if (std.mem.eql(u8, name, "soft_l1")) return types.loss.softL1(scale);
    if (std.mem.eql(u8, name, "cauchy")) return types.loss.cauchy(scale);
    @compileError("Bombelli row least-squares loss must be linear, huber, soft_l1, or cauchy");
}

fn ScaleConfiguration(comptime N: usize) type {
    return struct {
        kind: types.LeastSquaresScaling,
        values: [N]f64,
    };
}

fn parseScales(
    comptime N: usize,
    comptime variables: [N][]const u8,
    comptime options: anytype,
) ScaleConfiguration(N) {
    var result = ScaleConfiguration(N){
        .kind = if (@hasField(@TypeOf(options), "scaling"))
            @as(types.LeastSquaresScaling, options.scaling)
        else
            .jacobian,
        .values = [_]f64{1.0} ** N,
    };
    if (!@hasField(@TypeOf(options), "scales")) return result;
    if (result.kind != .user and @hasField(@TypeOf(options), "scaling")) {
        @compileError("Bombelli explicit row least-squares scales require '.scaling = .user'");
    }
    result.kind = .user;
    validateNamedFields(N, variables, @TypeOf(options.scales), "scale");
    inline for (variables, 0..) |variable, index| {
        if (!@hasField(@TypeOf(options.scales), variable)) continue;
        const characteristic =
            numeric(@field(options.scales, variable), "scale");
        if (!std.math.isFinite(characteristic) or characteristic <= 0.0) {
            @compileError("Bombelli row least-squares scales must be positive and finite");
        }
        result.values[index] = 1.0 / characteristic;
        if (!std.math.isFinite(result.values[index]) or
            result.values[index] <= 0.0)
        {
            @compileError("Bombelli row least-squares scales are outside the representable range");
        }
    }
    return result;
}

fn parseBounds(
    comptime N: usize,
    comptime variables: [N][]const u8,
    comptime options: anytype,
) Bounds(N) {
    var result = Bounds(N){
        .lower = [_]f64{-std.math.inf(f64)} ** N,
        .upper = [_]f64{std.math.inf(f64)} ** N,
    };
    if (!@hasField(@TypeOf(options), "bounds")) return result;
    validateNamedFields(N, variables, @TypeOf(options.bounds), "bound");
    inline for (variables, 0..) |variable, index| {
        if (!@hasField(@TypeOf(options.bounds), variable)) continue;
        const bound = @field(options.bounds, variable);
        const Bound = @TypeOf(bound);
        if (@typeInfo(Bound) != .@"struct") {
            @compileError("Bombelli row least-squares bounds must be structs");
        }
        for (@typeInfo(Bound).@"struct".fields) |field| {
            if (!std.mem.eql(u8, field.name, "lower") and
                !std.mem.eql(u8, field.name, "upper"))
            {
                @compileError("Bombelli row least-squares bounds accept only lower and upper");
            }
        }
        if (@hasField(Bound, "lower")) {
            result.lower[index] = numeric(bound.lower, "lower bound");
        }
        if (@hasField(Bound, "upper")) {
            result.upper[index] = numeric(bound.upper, "upper bound");
        }
        if (std.math.isNan(result.lower[index]) or
            std.math.isNan(result.upper[index]) or
            result.lower[index] == std.math.inf(f64) or
            result.upper[index] == -std.math.inf(f64) or
            result.lower[index] > result.upper[index])
        {
            @compileError("Bombelli row least-squares bounds must contain a finite point");
        }
    }
    return result;
}

fn validateNamedFields(
    comptime N: usize,
    comptime variables: [N][]const u8,
    comptime Named: type,
    comptime description: []const u8,
) void {
    if (@typeInfo(Named) != .@"struct") {
        @compileError("Bombelli named row least-squares options must be structs");
    }
    for (@typeInfo(Named).@"struct".fields) |field| {
        var found = false;
        for (variables) |variable| {
            if (std.mem.eql(u8, field.name, variable)) found = true;
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares {s} '.{s}' does not name a variable",
                .{ description, field.name },
            ));
        }
    }
}

fn validateEvalInput(
    comptime N: usize,
    comptime P: usize,
    comptime variables: [N][]const u8,
    comptime data: [P][]const u8,
    comptime Inputs: type,
) void {
    if (@typeInfo(Inputs) != .@"struct") {
        @compileError("Bombelli row least-squares eval expects a struct");
    }
    if (!@hasField(Inputs, "initial")) {
        @compileError("Bombelli row least-squares eval requires '.initial'");
    }
    if (!@hasField(Inputs, "observations")) {
        @compileError("Bombelli row least-squares eval requires '.observations'");
    }
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "initial") and
            !std.mem.eql(u8, field.name, "observations"))
        {
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares eval field '.{s}' is not recognized",
                .{field.name},
            ));
        }
    }
    const Observation = observationType(
        @FieldType(Inputs, "observations"),
    );
    if (@typeInfo(Observation) != .@"struct") {
        @compileError("Bombelli row least-squares observations must be structs");
    }
    inline for (data) |name| {
        if (!@hasField(Observation, name)) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares observation is missing '.{s}'",
                .{name},
            ));
        }
        requireNumeric(
            @FieldType(Observation, name),
            "observation data",
        );
    }
    _ = variables;
}

fn observationType(comptime Collection: type) type {
    return switch (@typeInfo(Collection)) {
        .array => |array| array.child,
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child,
                else => @compileError("Bombelli observations must be an array or slice"),
            },
            else => @compileError("Bombelli observations must be an array or slice"),
        },
        else => @compileError("Bombelli observations must be an array or slice"),
    };
}

fn observationFinite(
    comptime P: usize,
    comptime data: [P][]const u8,
    observation: anytype,
) bool {
    inline for (data) |name| {
        if (!std.math.isFinite(runtimeNumeric(@field(observation, name)))) {
            return false;
        }
    }
    return true;
}

fn initialValues(
    comptime N: usize,
    comptime variables: [N][]const u8,
    initial: anytype,
) [N]f64 {
    const Initial = @TypeOf(initial);
    if (@typeInfo(Initial) != .@"struct") {
        @compileError("Bombelli row least-squares '.initial' must be a struct");
    }
    comptime {
        field_check: for (@typeInfo(Initial).@"struct".fields) |field| {
            for (variables) |name| {
                if (std.mem.eql(u8, field.name, name)) {
                    continue :field_check;
                }
            }
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares initial field '.{s}' does not name a variable",
                .{field.name},
            ));
        }
    }
    var result: [N]f64 = undefined;
    inline for (variables, 0..) |name, index| {
        if (!@hasField(Initial, name)) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli row least-squares initial point is missing '.{s}'",
                .{name},
            ));
        }
        requireNumeric(@FieldType(Initial, name), "initial value");
        result[index] = runtimeNumeric(@field(initial, name));
    }
    return result;
}

fn requireNumeric(comptime T: type, comptime description: []const u8) void {
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => {},
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli row least-squares {s} must be numeric",
            .{description},
        )),
    }
}

fn runtimeNumeric(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => unreachable,
    };
}

fn option(
    comptime options: anytype,
    comptime name: []const u8,
    comptime default: f64,
) f64 {
    return if (@hasField(@TypeOf(options), name))
        numeric(@field(options, name), name)
    else
        default;
}

fn integerOption(
    comptime options: anytype,
    comptime name: []const u8,
    comptime default: usize,
) usize {
    if (!@hasField(@TypeOf(options), name)) return default;
    const value = @field(options, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => if (value < 0)
            @compileError("Bombelli row least-squares limits must be non-negative")
        else
            @intCast(value),
        else => @compileError("Bombelli row least-squares limits must be integers"),
    };
}

fn numeric(value: anytype, comptime description: []const u8) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli row least-squares {s} must be numeric",
            .{description},
        )),
    };
}

fn validatePositiveFinite(value: f64, comptime name: []const u8) void {
    if (!std.math.isFinite(value) or value <= 0.0) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli row least-squares {s} must be positive and finite",
            .{name},
        ));
    }
}

fn validateNonnegativeFinite(value: f64, comptime name: []const u8) void {
    if (!std.math.isFinite(value) or value < 0.0) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli row least-squares {s} must be non-negative and finite",
            .{name},
        ));
    }
}

fn updateScales(
    comptime N: usize,
    scaling: types.LeastSquaresScaling,
    column_norms: [N]f64,
    scales: *[N]f64,
) void {
    if (scaling != .jacobian) return;
    for (0..N) |index| {
        if (column_norms[index] > 0.0 and
            std.math.isFinite(column_norms[index]))
        {
            scales[index] = @max(scales[index], column_norms[index]);
        }
    }
}

fn initialDamping(
    comptime N: usize,
    column_norms: [N]f64,
    scales: [N]f64,
    tau: f64,
    minimum: f64,
    maximum: f64,
) f64 {
    var largest: f64 = 0.0;
    for (0..N) |index| {
        largest = @max(largest, column_norms[index] / scales[index]);
    }
    const squared = if (largest > @sqrt(std.math.floatMax(f64)))
        maximum
    else
        largest * largest;
    const raw = tau * @max(squared, 1.0);
    return std.math.clamp(raw, minimum, maximum);
}

fn projectedGradientDirection(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    scales: [N]f64,
    bounds: Bounds(N),
) [N]f64 {
    var result: [N]f64 = undefined;
    for (0..N) |index| {
        const candidate = std.math.clamp(
            values[index] -
                gradient[index] / scales[index] / scales[index],
            bounds.lower[index],
            bounds.upper[index],
        );
        result[index] = candidate - values[index];
    }
    return result;
}

fn projectedOptimality(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    scales: [N]f64,
    bounds: Bounds(N),
) f64 {
    var maximum: f64 = 0.0;
    for (0..N) |index| {
        const scaled_gradient = @abs(gradient[index] / scales[index]);
        if (bounds.lower[index] == -std.math.inf(f64) and
            bounds.upper[index] == std.math.inf(f64))
        {
            maximum = @max(maximum, scaled_gradient);
            continue;
        }
        const feasible_distance = if (gradient[index] > 0.0)
            values[index] - bounds.lower[index]
        else if (gradient[index] < 0.0)
            bounds.upper[index] - values[index]
        else
            0.0;
        maximum = @max(
            maximum,
            @min(scaled_gradient, feasible_distance * scales[index]),
        );
    }
    return maximum;
}

fn activeBounds(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    bounds: Bounds(N),
) [N]BoundActivity {
    var result: [N]BoundActivity = undefined;
    for (0..N) |index| {
        result[index] = if (bounds.lower[index] == bounds.upper[index])
            .fixed
        else if (values[index] <= bounds.lower[index] and
            gradient[index] > 0.0)
            .lower
        else if (values[index] >= bounds.upper[index] and
            gradient[index] < 0.0)
            .upper
        else
            .free;
    }
    return result;
}

fn withinBounds(
    comptime N: usize,
    values: [N]f64,
    bounds: Bounds(N),
) bool {
    for (0..N) |index| {
        if (values[index] < bounds.lower[index] or
            values[index] > bounds.upper[index])
        {
            return false;
        }
    }
    return true;
}

fn project(
    comptime N: usize,
    values: [N]f64,
    bounds: Bounds(N),
) [N]f64 {
    var result: [N]f64 = undefined;
    for (0..N) |index| {
        result[index] = std.math.clamp(
            values[index],
            bounds.lower[index],
            bounds.upper[index],
        );
    }
    return result;
}

fn increaseDamping(
    damping: *f64,
    nu: *f64,
    maximum: f64,
) void {
    damping.* = @min(damping.* * nu.*, maximum);
    nu.* = @min(nu.* * 2.0, @sqrt(std.math.floatMax(f64)));
}

fn scaledNorm(
    comptime N: usize,
    values: [N]f64,
    scales: [N]f64,
) f64 {
    var scaled: [N]f64 = undefined;
    for (0..N) |index| scaled[index] = values[index] * scales[index];
    return stableNorm(scaled);
}

fn stableNorm(vector: anytype) f64 {
    var scale: f64 = 0.0;
    var sum: f64 = 1.0;
    for (vector) |value| {
        const magnitude = @abs(value);
        if (magnitude == 0.0) continue;
        if (!std.math.isFinite(magnitude)) return magnitude;
        if (scale < magnitude) {
            const ratio = scale / magnitude;
            sum = 1.0 + sum * ratio * ratio;
            scale = magnitude;
        } else {
            const ratio = magnitude / scale;
            sum += ratio * ratio;
        }
    }
    return if (scale == 0.0) 0.0 else scale * @sqrt(sum);
}

fn dot(left: anytype, right: @TypeOf(left)) f64 {
    var result: f64 = 0.0;
    for (left, right) |a, b| result += a * b;
    return result;
}

fn normInf(vector: anytype) f64 {
    var result: f64 = 0.0;
    for (vector) |value| result = @max(result, @abs(value));
    return result;
}

fn allFinite(vector: anytype) bool {
    for (vector) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}
