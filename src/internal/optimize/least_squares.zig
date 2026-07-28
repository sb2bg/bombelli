//! Bounded allocation-free nonlinear least squares.
//!
//! The default Levenberg-Marquardt step is solved with column-pivoted
//! Householder QR of the augmented system
//!
//!     [ J_w S          ] q = [ -r_w ]
//!     [ sqrt(lambda) I ]     [   0  ]
//!
//! and `step = S*q`.  This avoids forming `JᵀJ`, supports rectangular and
//! rank-deficient models through positive damping, and keeps all storage
//! fixed-size.

const std = @import("std");
const ast = @import("../../expression.zig");
const domain = @import("../core/domain.zig");
const evaluation = @import("../runtime/evaluation.zig");
const linalg = @import("../../linalg.zig");
const loss_functions = @import("loss.zig");
const options_validation = @import("../core/options.zig");
const types = @import("types.zig");

pub const LeastSquaresStatus = types.LeastSquaresStatus;

pub fn LeastSquaresProblem(
    comptime M: usize,
    comptime N: usize,
    comptime P: usize,
) type {
    if (M == 0) @compileError("Bombelli least-squares problem requires at least one residual");
    if (N == 0) @compileError("Bombelli least-squares problem requires at least one variable");
    return struct {
        residuals: ast.ExprVector(M),
        jacobian_program: ast.ExprMatrix(M, N),
        variables: [N][]const u8,
        inputs: [P][]const u8,
        domain: domain.Domain,

        const Self = @This();

        /// Compiles this residual problem into a fixed-size solver.
        pub fn compile(
            comptime self: Self,
            comptime options: anytype,
        ) LeastSquaresSolver(M, N, P, options.max_iterations) {
            return compileProblem(M, N, P, self, options);
        }
    };
}

pub fn makeProblem(
    comptime M: usize,
    comptime N: usize,
    comptime P: usize,
    comptime model: anytype,
) LeastSquaresProblem(M, N, P) {
    return .{
        .residuals = model.outputs.simplify(),
        .jacobian_program = model.jacobian().simplify(),
        .variables = model.variables,
        .inputs = model.inputs,
        .domain = model.domain,
    };
}

/// Returns the result type for an `M`-residual, `N`-variable solve.
pub fn LeastSquaresResult(comptime M: usize, comptime N: usize) type {
    return struct {
        values: [N]f64,
        residuals: [M]f64,
        initial_cost: f64,
        cost: f64,
        iterations: usize,
        function_evaluations: usize,
        jacobian_evaluations: usize,
        accepted_steps: usize,
        rejected_steps: usize,
        rank: usize,
        active_bounds: [N]bool,
        gradient_norm: f64,
        step_norm: f64,
        damping: f64,
        status: types.LeastSquaresStatus,

        /// Whether the solver stopped by satisfying a convergence condition.
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

/// Returns a compiled fixed-size nonlinear least-squares solver type.
pub fn LeastSquaresSolver(
    comptime M: usize,
    comptime N: usize,
    comptime P: usize,
    comptime max_iterations: usize,
) type {
    if (M == 0) @compileError("Bombelli least-squares solver requires at least one residual");
    if (N == 0) @compileError("Bombelli least-squares solver requires at least one variable");
    if (max_iterations == 0) {
        @compileError("Bombelli least-squares max_iterations must be positive");
    }

    return struct {
        residuals: ast.ExprVector(M),
        jacobian_program: ast.ExprMatrix(M, N),
        variables: [N][]const u8,
        inputs: [P][]const u8,
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
        max_damping_trials: usize,
        max_line_search_steps: usize,

        pub const maximum_iterations = max_iterations;
        const Self = @This();

        /// Solves from `inputs.initial`; every other free symbol is read as a
        /// fixed runtime parameter.
        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) LeastSquaresResult(M, N) {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{ self.residuals.nodes, self.jacobian_program.nodes },
                &(([_][]const u8{"initial"}) ++ self.inputs),
                &self.variables,
                "least-squares eval",
            );

            var values = initialValues(N, self.variables, inputs);
            if (!allFiniteVector(values)) {
                return failureResult(
                    M,
                    N,
                    values,
                    nanVector(M),
                    .non_finite_initial,
                );
            }
            if (!withinBounds(N, values, self.bounds)) {
                if (self.initial_bounds_policy == .reject) {
                    return failureResult(
                        M,
                        N,
                        values,
                        nanVector(M),
                        .infeasible_initial,
                    );
                }
                values = project(N, values, self.bounds);
            }

            var residuals = evaluation.evaluateVectorWithVariables(
                M,
                N,
                self.residuals,
                inputs,
                self.variables,
                values,
            );
            var function_evaluations: usize = 1;
            if (!allFiniteVector(residuals)) {
                return failureResult(
                    M,
                    N,
                    values,
                    residuals,
                    .non_finite_initial,
                );
            }
            var cost = objective(M, self.loss, residuals);
            if (!std.math.isFinite(cost)) {
                return failureResult(
                    M,
                    N,
                    values,
                    residuals,
                    .non_finite_initial,
                );
            }
            const initial_cost = cost;

            var scales = self.parameter_scales;
            var damping: f64 = 0.0;
            var nu: f64 = 2.0;
            var step_norm: f64 = 0.0;
            var gradient_norm: f64 = std.math.inf(f64);
            var rank: usize = 0;
            var active_bounds = [_]bool{false} ** N;
            var accepted_steps: usize = 0;
            var rejected_steps: usize = 0;
            var jacobian_evaluations: usize = 0;

            if (cost <= self.cost_tolerance) {
                return finalResultAt(
                    M,
                    N,
                    self,
                    inputs,
                    values,
                    residuals,
                    initial_cost,
                    cost,
                    0,
                    function_evaluations,
                    jacobian_evaluations,
                    accepted_steps,
                    rejected_steps,
                    scales,
                    0.0,
                    damping,
                    .converged_cost,
                );
            }

            for (0..max_iterations) |iteration| {
                const jacobian = evaluation.evaluateMatrixWithVariables(
                    M,
                    N,
                    N,
                    self.jacobian_program,
                    inputs,
                    self.variables,
                    values,
                );
                jacobian_evaluations += 1;
                if (!allFiniteMatrix(jacobian)) {
                    return makeResult(
                        M,
                        N,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        rank,
                        active_bounds,
                        gradient_norm,
                        step_norm,
                        damping,
                        .non_finite_jacobian,
                    );
                }

                var weighted_residuals: [M]f64 = undefined;
                var weighted_jacobian: [M][N]f64 = undefined;
                weightLinearization(
                    M,
                    N,
                    self.loss,
                    residuals,
                    jacobian,
                    &weighted_residuals,
                    &weighted_jacobian,
                );
                if (!allFiniteVector(weighted_residuals) or
                    !allFiniteMatrix(weighted_jacobian))
                {
                    return makeResult(
                        M,
                        N,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        rank,
                        active_bounds,
                        gradient_norm,
                        step_norm,
                        damping,
                        .non_finite_jacobian,
                    );
                }

                updateScales(
                    M,
                    N,
                    self.scaling,
                    weighted_jacobian,
                    &scales,
                );
                rank = estimateRank(
                    M,
                    N,
                    weighted_jacobian,
                    self.rank_tolerance,
                );
                const gradient = transposeProduct(
                    M,
                    N,
                    weighted_jacobian,
                    weighted_residuals,
                );
                gradient_norm = projectedOptimality(
                    N,
                    values,
                    gradient,
                    scales,
                    self.bounds,
                );
                active_bounds = activeBounds(
                    N,
                    values,
                    gradient,
                    self.bounds,
                );
                if (!std.math.isFinite(gradient_norm)) {
                    return makeResult(
                        M,
                        N,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        rank,
                        active_bounds,
                        gradient_norm,
                        step_norm,
                        damping,
                        .numerical_failure,
                    );
                }
                if (gradient_norm <= self.gradient_tolerance) {
                    return makeResult(
                        M,
                        N,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        rank,
                        active_bounds,
                        gradient_norm,
                        step_norm,
                        damping,
                        .converged_gradient,
                    );
                }

                if (damping == 0.0) {
                    var maximum_scaled_column_norm_squared: f64 = 0.0;
                    for (0..N) |column| {
                        var squared: f64 = 0.0;
                        for (0..M) |row| {
                            const value =
                                weighted_jacobian[row][column] /
                                scales[column];
                            squared += value * value;
                        }
                        maximum_scaled_column_norm_squared = @max(
                            maximum_scaled_column_norm_squared,
                            squared,
                        );
                    }
                    damping = self.damping_tau * if (maximum_scaled_column_norm_squared > 0.0)
                        maximum_scaled_column_norm_squared
                    else
                        1.0;
                    damping = std.math.clamp(
                        damping,
                        self.minimum_damping,
                        self.maximum_damping,
                    );
                }

                var accepted = false;
                var accepted_trial: Trial(M, N) = undefined;
                var accepted_rho: f64 = 0.0;
                for (0..self.max_damping_trials) |_| {
                    const direction = lmDirection(
                        M,
                        N,
                        weighted_jacobian,
                        weighted_residuals,
                        scales,
                        damping,
                    ) orelse {
                        rejected_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    };
                    const trial = lineSearch(
                        M,
                        N,
                        self,
                        inputs,
                        values,
                        cost,
                        gradient,
                        direction,
                    );
                    function_evaluations += trial.evaluations;
                    if (!trial.accepted) {
                        rejected_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    }
                    const prediction = predictedReduction(
                        M,
                        N,
                        weighted_jacobian,
                        gradient,
                        trial.step,
                    );
                    const actual_reduction = cost - trial.cost;
                    const rho = actual_reduction / prediction;
                    if (!std.math.isFinite(prediction) or
                        prediction <= 0.0 or
                        !std.math.isFinite(rho) or
                        actual_reduction <= 0.0 or
                        rho <= self.acceptance_threshold)
                    {
                        rejected_steps += 1;
                        increaseDamping(
                            &damping,
                            &nu,
                            self.maximum_damping,
                        );
                        continue;
                    }
                    accepted = true;
                    accepted_trial = trial;
                    accepted_rho = rho;
                    break;
                }

                var used_projected_gradient = false;
                if (!accepted) {
                    const direction = projectedGradientDirection(
                        N,
                        values,
                        gradient,
                        scales,
                        self.bounds,
                    );
                    const trial = lineSearch(
                        M,
                        N,
                        self,
                        inputs,
                        values,
                        cost,
                        gradient,
                        direction,
                    );
                    function_evaluations += trial.evaluations;
                    if (!trial.accepted) {
                        return makeResult(
                            M,
                            N,
                            values,
                            residuals,
                            initial_cost,
                            cost,
                            iteration,
                            function_evaluations,
                            jacobian_evaluations,
                            accepted_steps,
                            rejected_steps,
                            rank,
                            active_bounds,
                            gradient_norm,
                            step_norm,
                            damping,
                            .line_search_failed,
                        );
                    }
                    accepted = true;
                    accepted_trial = trial;
                    used_projected_gradient = true;
                    rejected_steps += 1;
                    increaseDamping(
                        &damping,
                        &nu,
                        self.maximum_damping,
                    );
                }

                std.debug.assert(accepted);
                const old_cost = cost;
                const actual_reduction = old_cost - accepted_trial.cost;
                step_norm = scaledNorm(N, accepted_trial.step, scales);
                const value_norm = scaledNorm(N, values, scales);
                values = accepted_trial.values;
                residuals = accepted_trial.residuals;
                cost = accepted_trial.cost;
                accepted_steps += 1;

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

                if (cost <= self.cost_tolerance) {
                    return finalResultAt(
                        M,
                        N,
                        self,
                        inputs,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration + 1,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        scales,
                        step_norm,
                        damping,
                        .converged_cost,
                    );
                }
                if (step_norm <= self.step_tolerance *
                    (self.step_tolerance + value_norm))
                {
                    return finalResultAt(
                        M,
                        N,
                        self,
                        inputs,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration + 1,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        scales,
                        step_norm,
                        damping,
                        .converged_step,
                    );
                }
                if (!used_projected_gradient and accepted_rho >= 0.25 and
                    actual_reduction <= self.function_tolerance * old_cost)
                {
                    return finalResultAt(
                        M,
                        N,
                        self,
                        inputs,
                        values,
                        residuals,
                        initial_cost,
                        cost,
                        iteration + 1,
                        function_evaluations,
                        jacobian_evaluations,
                        accepted_steps,
                        rejected_steps,
                        scales,
                        step_norm,
                        damping,
                        .converged_cost,
                    );
                }
            }

            return finalResultAt(
                M,
                N,
                self,
                inputs,
                values,
                residuals,
                initial_cost,
                cost,
                max_iterations,
                function_evaluations,
                jacobian_evaluations,
                accepted_steps,
                rejected_steps,
                scales,
                step_norm,
                damping,
                .max_iterations,
            );
        }
    };
}

fn finalResultAt(
    comptime M: usize,
    comptime N: usize,
    comptime solver: anytype,
    inputs: anytype,
    values: [N]f64,
    residuals: [M]f64,
    initial_cost: f64,
    cost: f64,
    iterations: usize,
    function_evaluations: usize,
    jacobian_evaluations: usize,
    accepted_steps: usize,
    rejected_steps: usize,
    input_scales: [N]f64,
    step_norm: f64,
    damping: f64,
    requested_status: types.LeastSquaresStatus,
) LeastSquaresResult(M, N) {
    const jacobian = evaluation.evaluateMatrixWithVariables(
        M,
        N,
        N,
        solver.jacobian_program,
        inputs,
        solver.variables,
        values,
    );
    const final_jacobian_evaluations = jacobian_evaluations + 1;
    if (!allFiniteMatrix(jacobian)) {
        return makeResult(
            M,
            N,
            values,
            residuals,
            initial_cost,
            cost,
            iterations,
            function_evaluations,
            final_jacobian_evaluations,
            accepted_steps,
            rejected_steps,
            0,
            [_]bool{false} ** N,
            std.math.nan(f64),
            step_norm,
            damping,
            .non_finite_jacobian,
        );
    }

    var weighted_residuals: [M]f64 = undefined;
    var weighted_jacobian: [M][N]f64 = undefined;
    weightLinearization(
        M,
        N,
        solver.loss,
        residuals,
        jacobian,
        &weighted_residuals,
        &weighted_jacobian,
    );
    if (!allFiniteVector(weighted_residuals) or
        !allFiniteMatrix(weighted_jacobian))
    {
        return makeResult(
            M,
            N,
            values,
            residuals,
            initial_cost,
            cost,
            iterations,
            function_evaluations,
            final_jacobian_evaluations,
            accepted_steps,
            rejected_steps,
            0,
            [_]bool{false} ** N,
            std.math.nan(f64),
            step_norm,
            damping,
            .non_finite_jacobian,
        );
    }

    var scales = input_scales;
    updateScales(M, N, solver.scaling, weighted_jacobian, &scales);
    const rank = estimateRank(
        M,
        N,
        weighted_jacobian,
        solver.rank_tolerance,
    );
    const gradient = transposeProduct(
        M,
        N,
        weighted_jacobian,
        weighted_residuals,
    );
    const gradient_norm = projectedOptimality(
        N,
        values,
        gradient,
        scales,
        solver.bounds,
    );
    const active_bounds = activeBounds(
        N,
        values,
        gradient,
        solver.bounds,
    );
    const status: types.LeastSquaresStatus =
        if (!std.math.isFinite(gradient_norm))
            .numerical_failure
        else if (gradient_norm <= solver.gradient_tolerance)
            .converged_gradient
        else
            requested_status;
    return makeResult(
        M,
        N,
        values,
        residuals,
        initial_cost,
        cost,
        iterations,
        function_evaluations,
        final_jacobian_evaluations,
        accepted_steps,
        rejected_steps,
        rank,
        active_bounds,
        gradient_norm,
        step_norm,
        damping,
        status,
    );
}

fn compileProblem(
    comptime M: usize,
    comptime N: usize,
    comptime P: usize,
    comptime problem: LeastSquaresProblem(M, N, P),
    comptime options: anytype,
) LeastSquaresSolver(M, N, P, options.max_iterations) {
    options_validation.requireTag(
        options,
        "algorithm",
        "levenberg_marquardt",
        "Bombelli least-squares compilation requires '.algorithm = .levenberg_marquardt'",
    );
    options_validation.requireTag(
        options,
        "jacobian",
        "symbolic",
        "Bombelli least-squares compilation requires '.jacobian = .symbolic'",
    );
    if (@hasField(@TypeOf(options), "linear_solver") and
        !std.mem.eql(u8, @tagName(options.linear_solver), "qr"))
    {
        @compileError("Bombelli least-squares currently requires '.linear_solver = .qr'");
    }

    const generic_tolerance = option(
        options,
        "tolerance",
        1e-8,
    );
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
        @compileError("Bombelli least-squares loss scale must be positive and finite");
    }

    const scale_configuration = parseScales(N, problem.variables, options);
    const configured_bounds = parseBounds(N, problem.variables, options);
    const initial_bounds_policy: types.InitialBoundsPolicy =
        if (@hasField(@TypeOf(options), "initial_bounds"))
            @as(types.InitialBoundsPolicy, options.initial_bounds)
        else
            .reject;

    const damping_tau = option(options, "initial_damping", 1e-3);
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
    validatePositiveFinite(damping_tau, "initial_damping");
    validatePositiveFinite(minimum_damping, "minimum_damping");
    validatePositiveFinite(maximum_damping, "maximum_damping");
    if (minimum_damping > maximum_damping) {
        @compileError("Bombelli least-squares minimum_damping exceeds maximum_damping");
    }

    const acceptance_threshold = option(
        options,
        "acceptance_threshold",
        1e-4,
    );
    if (!std.math.isFinite(acceptance_threshold) or
        acceptance_threshold < 0.0 or acceptance_threshold >= 1.0)
    {
        @compileError("Bombelli least-squares acceptance_threshold must be in [0, 1)");
    }
    const armijo_constant = option(options, "armijo_constant", 1e-4);
    if (!std.math.isFinite(armijo_constant) or
        armijo_constant <= 0.0 or armijo_constant >= 1.0)
    {
        @compileError("Bombelli least-squares armijo_constant must be in (0, 1)");
    }
    const backtrack_factor = option(options, "backtrack_factor", 0.5);
    if (!std.math.isFinite(backtrack_factor) or
        backtrack_factor <= 0.0 or backtrack_factor >= 1.0)
    {
        @compileError("Bombelli least-squares backtrack_factor must be in (0, 1)");
    }
    const rank_tolerance = option(
        options,
        "rank_tolerance",
        @as(f64, @floatFromInt(@max(M, N))) * std.math.floatEps(f64),
    );
    validateNonnegativeFinite(rank_tolerance, "rank_tolerance");

    const max_damping_trials = integerOption(
        options,
        "max_damping_trials",
        10,
    );
    const max_line_search_steps = integerOption(
        options,
        "max_line_search_steps",
        20,
    );
    if (max_damping_trials == 0 or max_line_search_steps == 0) {
        @compileError("Bombelli least-squares inner iteration limits must be positive");
    }

    return .{
        .residuals = problem.residuals,
        .jacobian_program = problem.jacobian_program,
        .variables = problem.variables,
        .inputs = problem.inputs,
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
        .max_damping_trials = max_damping_trials,
        .max_line_search_steps = max_line_search_steps,
    };
}

fn Trial(comptime M: usize, comptime N: usize) type {
    return struct {
        accepted: bool,
        values: [N]f64,
        residuals: [M]f64,
        step: [N]f64,
        cost: f64,
        evaluations: usize,
    };
}

fn lineSearch(
    comptime M: usize,
    comptime N: usize,
    comptime solver: anytype,
    inputs: anytype,
    values: [N]f64,
    cost: f64,
    gradient: [N]f64,
    direction: [N]f64,
) Trial(M, N) {
    var result = Trial(M, N){
        .accepted = false,
        .values = values,
        .residuals = nanVector(M),
        .step = [_]f64{0.0} ** N,
        .cost = cost,
        .evaluations = 0,
    };
    var alpha: f64 = 1.0;
    for (0..solver.max_line_search_steps) |_| {
        var candidate: [N]f64 = undefined;
        for (0..N) |index| {
            candidate[index] = std.math.clamp(
                values[index] + alpha * direction[index],
                solver.bounds.lower[index],
                solver.bounds.upper[index],
            );
            result.step[index] = candidate[index] - values[index];
        }
        const directional_derivative = linalg.dot(
            gradient,
            result.step,
        );
        if (!std.math.isFinite(directional_derivative) or
            directional_derivative >= 0.0 or
            linalg.normInf(result.step) == 0.0)
        {
            alpha *= solver.backtrack_factor;
            continue;
        }

        const candidate_residuals = evaluation.evaluateVectorWithVariables(
            M,
            N,
            solver.residuals,
            inputs,
            solver.variables,
            candidate,
        );
        result.evaluations += 1;
        if (!allFiniteVector(candidate_residuals)) {
            alpha *= solver.backtrack_factor;
            continue;
        }
        const candidate_cost = objective(
            M,
            solver.loss,
            candidate_residuals,
        );
        if (!std.math.isFinite(candidate_cost)) {
            alpha *= solver.backtrack_factor;
            continue;
        }
        if (candidate_cost <= cost +
            solver.armijo_constant * directional_derivative)
        {
            result.accepted = true;
            result.values = candidate;
            result.residuals = candidate_residuals;
            result.cost = candidate_cost;
            return result;
        }
        alpha *= solver.backtrack_factor;
    }
    return result;
}

fn lmDirection(
    comptime M: usize,
    comptime N: usize,
    weighted_jacobian: [M][N]f64,
    weighted_residuals: [M]f64,
    scales: [N]f64,
    damping: f64,
) ?[N]f64 {
    var augmented: [M + N][N]f64 =
        [_][N]f64{[_]f64{0.0} ** N} ** (M + N);
    var rhs: [M + N]f64 = [_]f64{0.0} ** (M + N);
    for (0..M) |row| {
        rhs[row] = -weighted_residuals[row];
        for (0..N) |column| {
            augmented[row][column] =
                weighted_jacobian[row][column] / scales[column];
        }
    }
    const root_damping = @sqrt(damping);
    for (0..N) |column| {
        augmented[M + column][column] = root_damping;
    }
    const scaled_step = linalg.leastSquares(
        augmented,
        rhs,
        .{},
    ) orelse return null;
    var direction: [N]f64 = undefined;
    for (0..N) |column| {
        direction[column] = scaled_step[column] / scales[column];
    }
    return if (allFiniteVector(direction)) direction else null;
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
        const scaled_gradient = gradient[index] / scales[index];
        const displacement = scaled_gradient / scales[index];
        const candidate = std.math.clamp(
            values[index] - displacement,
            bounds.lower[index],
            bounds.upper[index],
        );
        result[index] = candidate - values[index];
    }
    return result;
}

fn predictedReduction(
    comptime M: usize,
    comptime N: usize,
    weighted_jacobian: [M][N]f64,
    gradient: [N]f64,
    step: [N]f64,
) f64 {
    const linearized = linalg.matVec(weighted_jacobian, step);
    return -(linalg.dot(gradient, step) +
        0.5 * linalg.dot(linearized, linearized));
}

fn weightLinearization(
    comptime M: usize,
    comptime N: usize,
    loss: types.Loss,
    residuals: [M]f64,
    jacobian: [M][N]f64,
    weighted_residuals: *[M]f64,
    weighted_jacobian: *[M][N]f64,
) void {
    for (0..M) |row| {
        const robust = loss_functions.evaluate(loss, residuals[row]);
        weighted_residuals[row] =
            robust.sqrt_weight * residuals[row];
        for (0..N) |column| {
            weighted_jacobian[row][column] =
                robust.sqrt_weight * jacobian[row][column];
        }
    }
}

fn objective(
    comptime M: usize,
    loss: types.Loss,
    residuals: [M]f64,
) f64 {
    var cost: f64 = 0.0;
    for (residuals) |residual| {
        cost += loss_functions.evaluate(loss, residual).cost;
    }
    return cost;
}

fn transposeProduct(
    comptime M: usize,
    comptime N: usize,
    matrix: [M][N]f64,
    vector: [M]f64,
) [N]f64 {
    var result: [N]f64 = [_]f64{0.0} ** N;
    for (0..M) |row| {
        for (0..N) |column| {
            result[column] += matrix[row][column] * vector[row];
        }
    }
    return result;
}

fn updateScales(
    comptime M: usize,
    comptime N: usize,
    scaling: types.LeastSquaresScaling,
    jacobian: [M][N]f64,
    scales: *[N]f64,
) void {
    if (scaling != .jacobian) return;
    for (0..N) |column| {
        var column_values: [M]f64 = undefined;
        for (0..M) |row| column_values[row] = jacobian[row][column];
        const norm = linalg.norm2(column_values);
        if (norm > 0.0 and std.math.isFinite(norm)) {
            scales[column] = @max(scales[column], norm);
        }
    }
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
        if (bounds.lower[index] == -std.math.inf(f64) and
            bounds.upper[index] == std.math.inf(f64))
        {
            maximum = @max(
                maximum,
                @abs(gradient[index] / scales[index]),
            );
            continue;
        }
        const scaled_gradient = gradient[index] / scales[index];
        const displacement = scaled_gradient / scales[index];
        const projected = std.math.clamp(
            values[index] - displacement,
            bounds.lower[index],
            bounds.upper[index],
        );
        maximum = @max(
            maximum,
            @abs((values[index] - projected) * scales[index]),
        );
    }
    return maximum;
}

fn activeBounds(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    bounds: Bounds(N),
) [N]bool {
    var result: [N]bool = undefined;
    for (0..N) |index| {
        result[index] =
            bounds.lower[index] == bounds.upper[index] or
            (values[index] <= bounds.lower[index] and gradient[index] > 0.0) or
            (values[index] >= bounds.upper[index] and gradient[index] < 0.0);
    }
    return result;
}

fn estimateRank(
    comptime M: usize,
    comptime N: usize,
    input: [M][N]f64,
    relative_tolerance: f64,
) usize {
    var columns: [N][M]f64 = undefined;
    var norms: [N]f64 = undefined;
    var maximum_norm: f64 = 0.0;
    for (0..N) |column| {
        for (0..M) |row| columns[column][row] = input[row][column];
        norms[column] = linalg.norm2(columns[column]);
        maximum_norm = @max(maximum_norm, norms[column]);
    }
    const threshold = relative_tolerance * maximum_norm;
    var rank: usize = 0;
    for (0..@min(M, N)) |step| {
        var pivot = step;
        for (step + 1..N) |candidate| {
            if (norms[candidate] > norms[pivot]) pivot = candidate;
        }
        if (norms[pivot] <= threshold or !std.math.isFinite(norms[pivot])) {
            break;
        }
        if (pivot != step) {
            const column = columns[step];
            columns[step] = columns[pivot];
            columns[pivot] = column;
            const norm = norms[step];
            norms[step] = norms[pivot];
            norms[pivot] = norm;
        }
        const inverse_norm = 1.0 / norms[step];
        for (0..M) |row| columns[step][row] *= inverse_norm;
        for (step + 1..N) |candidate| {
            const projection = linalg.dot(
                columns[step],
                columns[candidate],
            );
            for (0..M) |row| {
                columns[candidate][row] -=
                    projection * columns[step][row];
            }
            norms[candidate] = linalg.norm2(columns[candidate]);
        }
        rank += 1;
    }
    return rank;
}

fn scaledNorm(
    comptime N: usize,
    values: [N]f64,
    scales: [N]f64,
) f64 {
    var scaled: [N]f64 = undefined;
    for (0..N) |index| scaled[index] = values[index] * scales[index];
    return linalg.norm2(scaled);
}

fn increaseDamping(
    damping: *f64,
    nu: *f64,
    maximum: f64,
) void {
    damping.* = @min(damping.* * nu.*, maximum);
    nu.* = @min(nu.* * 2.0, @sqrt(std.math.floatMax(f64)));
}

fn parseLoss(comptime options: anytype) types.Loss {
    if (!@hasField(@TypeOf(options), "loss")) return types.loss.linear();
    if (@TypeOf(options.loss) == types.Loss) return options.loss;

    const name = @tagName(options.loss);
    if (std.mem.eql(u8, name, "linear")) return types.loss.linear();
    const scale = option(options, "loss_scale", 1.0);
    if (std.mem.eql(u8, name, "huber")) return types.loss.huber(scale);
    if (std.mem.eql(u8, name, "soft_l1")) return types.loss.softL1(scale);
    if (std.mem.eql(u8, name, "cauchy")) return types.loss.cauchy(scale);
    @compileError("Bombelli least-squares loss must be linear, huber, soft_l1, or cauchy");
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
    if (result.kind != .user and
        @hasField(@TypeOf(options), "scaling"))
    {
        @compileError("Bombelli explicit least-squares scales require '.scaling = .user'");
    }
    result.kind = .user;
    validateNamedFields(
        N,
        variables,
        @TypeOf(options.scales),
        "scale",
    );
    inline for (variables, 0..) |variable, index| {
        if (@hasField(@TypeOf(options.scales), variable)) {
            result.values[index] = numeric(
                @field(options.scales, variable),
                "scale",
            );
        }
        if (!std.math.isFinite(result.values[index]) or
            result.values[index] <= 0.0)
        {
            @compileError("Bombelli least-squares parameter scales must be positive and finite");
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
    validateNamedFields(
        N,
        variables,
        @TypeOf(options.bounds),
        "bound",
    );
    inline for (variables, 0..) |variable, index| {
        if (!@hasField(@TypeOf(options.bounds), variable)) continue;
        const bound = @field(options.bounds, variable);
        const Bound = @TypeOf(bound);
        if (@typeInfo(Bound) != .@"struct") {
            @compileError("Bombelli least-squares bounds must be structs with optional lower and upper fields");
        }
        if (@hasField(Bound, "lower")) {
            result.lower[index] = numeric(bound.lower, "lower bound");
        }
        if (@hasField(Bound, "upper")) {
            result.upper[index] = numeric(bound.upper, "upper bound");
        }
        if (std.math.isNan(result.lower[index]) or
            std.math.isNan(result.upper[index]) or
            result.lower[index] > result.upper[index])
        {
            @compileError("Bombelli least-squares bounds must satisfy lower <= upper and may not be NaN");
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
    const info = @typeInfo(Named);
    if (info != .@"struct") {
        @compileError("Bombelli named least-squares options must be a struct");
    }
    for (info.@"struct".fields) |field| {
        var found = false;
        for (variables) |variable| {
            if (std.mem.eql(u8, field.name, variable)) found = true;
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli least-squares {s} '.{s}' does not name a variable",
                .{ description, field.name },
            ));
        }
    }
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
            @compileError("Bombelli least-squares iteration limits must be non-negative")
        else
            @intCast(value),
        else => @compileError("Bombelli least-squares iteration limits must be integers"),
    };
}

fn numeric(value: anytype, comptime description: []const u8) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli least-squares {s} must be numeric",
            .{description},
        )),
    };
}

fn validatePositiveFinite(value: f64, comptime name: []const u8) void {
    if (!std.math.isFinite(value) or value <= 0.0) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli least-squares {s} must be positive and finite",
            .{name},
        ));
    }
}

fn validateNonnegativeFinite(value: f64, comptime name: []const u8) void {
    if (!std.math.isFinite(value) or value < 0.0) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli least-squares {s} must be non-negative and finite",
            .{name},
        ));
    }
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

inline fn initialValues(
    comptime N: usize,
    comptime variables: [N][]const u8,
    inputs: anytype,
) [N]f64 {
    const Inputs = @TypeOf(inputs);
    if (@typeInfo(Inputs) != .@"struct" or !@hasField(Inputs, "initial")) {
        @compileError("Bombelli least-squares eval requires '.initial'");
    }
    const initial = inputs.initial;
    const Initial = @TypeOf(initial);
    if (@typeInfo(Initial) != .@"struct") {
        @compileError("Bombelli least-squares '.initial' must be a struct of variable values");
    }
    comptime {
        field_check: for (@typeInfo(Initial).@"struct".fields) |field| {
            for (variables) |name| {
                if (std.mem.eql(u8, field.name, name)) continue :field_check;
            }
            @compileError(std.fmt.comptimePrint(
                "Bombelli least-squares initial field '.{s}' does not name a variable",
                .{field.name},
            ));
        }
    }
    var values: [N]f64 = undefined;
    inline for (variables, 0..) |name, index| {
        if (!@hasField(Initial, name)) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli least-squares initial point is missing '.{s}'",
                .{name},
            ));
        }
        values[index] = numeric(@field(initial, name), name);
    }
    return values;
}

fn allFiniteVector(vector: anytype) bool {
    for (vector) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

fn allFiniteMatrix(matrix: anytype) bool {
    for (matrix) |row| {
        if (!allFiniteVector(row)) return false;
    }
    return true;
}

fn nanVector(comptime N: usize) [N]f64 {
    return [_]f64{std.math.nan(f64)} ** N;
}

fn failureResult(
    comptime M: usize,
    comptime N: usize,
    values: [N]f64,
    residuals: [M]f64,
    status: types.LeastSquaresStatus,
) LeastSquaresResult(M, N) {
    return makeResult(
        M,
        N,
        values,
        residuals,
        std.math.nan(f64),
        std.math.nan(f64),
        0,
        0,
        0,
        0,
        0,
        0,
        [_]bool{false} ** N,
        std.math.nan(f64),
        std.math.nan(f64),
        std.math.nan(f64),
        status,
    );
}

fn makeResult(
    comptime M: usize,
    comptime N: usize,
    values: [N]f64,
    residuals: [M]f64,
    initial_cost: f64,
    cost: f64,
    iterations: usize,
    function_evaluations: usize,
    jacobian_evaluations: usize,
    accepted_steps: usize,
    rejected_steps: usize,
    rank: usize,
    active_bounds: [N]bool,
    gradient_norm: f64,
    step_norm: f64,
    damping: f64,
    status: types.LeastSquaresStatus,
) LeastSquaresResult(M, N) {
    return .{
        .values = values,
        .residuals = residuals,
        .initial_cost = initial_cost,
        .cost = cost,
        .iterations = iterations,
        .function_evaluations = function_evaluations,
        .jacobian_evaluations = jacobian_evaluations,
        .accepted_steps = accepted_steps,
        .rejected_steps = rejected_steps,
        .rank = rank,
        .active_bounds = active_bounds,
        .gradient_norm = gradient_norm,
        .step_norm = step_norm,
        .damping = damping,
        .status = status,
    };
}
