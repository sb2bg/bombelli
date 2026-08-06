const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodesAtIndent = support.emitNodesAtIndent;
const fill = support.fill;
const floatSource = support.floatSource;
const prelude = support.prelude;
const validateIdentifier = support.validateIdentifier;
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
        .{ "@epsilon@", floatSource(std.math.floatEps(f64)) },
        .{ "@maximum@", floatSource(std.math.floatMax(f64)) },
    };

    var source: []const u8 = prelude();
    source = append(source, "#include <stddef.h>\n");
    source = append(source, inputsSource(name, solver));
    source = append(source, fill(public_types, slots));
    source = append(source, configSource(name, solver));
    source = append(source, fill(runtime_support, slots));
    source = append(source, linearizationSource(name, solver));
    source = append(source, objectiveSource(name, solver));
    source = append(source, entrypointSource(name, solver, slots));
    return support.instantiate(source, .f64);
}

fn inputsSource(
    comptime name: []const u8,
    comptime solver: anytype,
) []const u8 {
    var source: []const u8 = std.fmt.comptimePrint(
        "\ntypedef struct {s}_initial {{\n",
        .{name},
    );
    inline for (solver.variables) |variable| {
        validateIdentifier(variable, "input name");
        source = append(source, std.fmt.comptimePrint(
            "    @scalar@ {s};\n",
            .{variable},
        ));
    }
    source = append(source, std.fmt.comptimePrint(
        "}} {s}_initial;\n\ntypedef struct {s}_observation {{\n",
        .{ name, name },
    ));
    inline for (solver.data) |field| {
        validateIdentifier(field, "input name");
        source = append(source, std.fmt.comptimePrint(
            "    @scalar@ {s};\n",
            .{field},
        ));
    }
    return append(source, std.fmt.comptimePrint(
        \\}} {s}_observation;
        \\
        \\typedef struct {s}_inputs {{
        \\    {s}_initial initial;
        \\    const {s}_observation *observations;
        \\    size_t observation_count;
        \\}} {s}_inputs;
        \\
    , .{ name, name, name, name, name }));
}

fn configSource(
    comptime name: []const u8,
    comptime solver: anytype,
) []const u8 {
    var source: []const u8 = std.fmt.comptimePrint(
        \\
        \\static const {s}_loss {s}_config_loss = {{ {s}_{s}, {s} }};
        \\static const {s}_scaling {s}_config_scaling = {s}_{s};
        \\static const {s}_initial_bounds {s}_config_initial_bounds = {s}_{s};
        \\static const @scalar@ {s}_config_parameter_scales[{d}] = {{
    , .{
        name,
        name,
        name,
        @tagName(solver.loss.kind),
        floatSource(solver.loss.scale),
        name,
        name,
        name,
        @tagName(solver.scaling),
        name,
        name,
        name,
        @tagName(solver.initial_bounds_policy),
        name,
        solver.variables.len,
    });
    inline for (solver.parameter_scales, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, floatSource(value));
    }
    source = append(source, std.fmt.comptimePrint(
        " }};\nstatic const @scalar@ {s}_config_lower[{d}] = {{ ",
        .{ name, solver.variables.len },
    ));
    inline for (solver.bounds.lower, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, boundSource(value));
    }
    source = append(source, std.fmt.comptimePrint(
        " }};\nstatic const @scalar@ {s}_config_upper[{d}] = {{ ",
        .{ name, solver.variables.len },
    ));
    inline for (solver.bounds.upper, 0..) |value, index| {
        if (index != 0) source = append(source, ", ");
        source = append(source, boundSource(value));
    }
    source = append(source, std.fmt.comptimePrint(
        \\ }};
        \\static const @scalar@ {s}_config_function_tolerance = {s};
        \\static const @scalar@ {s}_config_gradient_tolerance = {s};
        \\static const @scalar@ {s}_config_step_tolerance = {s};
        \\static const @scalar@ {s}_config_cost_tolerance = {s};
        \\static const @scalar@ {s}_config_damping_tau = {s};
        \\static const @scalar@ {s}_config_minimum_damping = {s};
        \\static const @scalar@ {s}_config_maximum_damping = {s};
        \\static const @scalar@ {s}_config_acceptance_threshold = {s};
        \\static const @scalar@ {s}_config_armijo_constant = {s};
        \\static const @scalar@ {s}_config_backtrack_factor = {s};
        \\static const @scalar@ {s}_config_rank_tolerance = {s};
        \\static const size_t {s}_config_max_function_evaluations = {d};
        \\static const size_t {s}_config_max_damping_trials = {d};
        \\static const size_t {s}_config_max_line_search_steps = {d};
        \\static const size_t {s}_config_max_invalid_steps = {d};
        \\
    , .{
        name,
        floatSource(solver.function_tolerance),
        name,
        floatSource(solver.gradient_tolerance),
        name,
        floatSource(solver.step_tolerance),
        name,
        floatSource(solver.cost_tolerance),
        name,
        floatSource(solver.damping_tau),
        name,
        floatSource(solver.minimum_damping),
        name,
        floatSource(solver.maximum_damping),
        name,
        floatSource(solver.acceptance_threshold),
        name,
        floatSource(solver.armijo_constant),
        name,
        floatSource(solver.backtrack_factor),
        name,
        floatSource(solver.rank_tolerance),
        name,
        solver.max_function_evaluations,
        name,
        solver.max_damping_trials,
        name,
        solver.max_line_search_steps,
        name,
        solver.max_invalid_steps,
    }));
    return source;
}

fn boundSource(comptime value: f64) []const u8 {
    if (value == std.math.inf(f64)) return "INFINITY";
    if (value == -std.math.inf(f64)) return "-INFINITY";
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
            .source = std.fmt.comptimePrint("observation->{s}", .{field}),
        };
    }
    return bindings;
}

fn linearizationSource(
    comptime name: []const u8,
    comptime solver: anytype,
) []const u8 {
    const N = solver.variables.len;
    const R = @TypeOf(solver).residuals_per_observation;
    const bindings = rowBindings(solver);
    const slots = .{
        .{ "@name@", name },
        .{ "@n@", std.fmt.comptimePrint("{d}", .{N}) },
        .{ "@r@", std.fmt.comptimePrint("{d}", .{R}) },
    };
    var source: []const u8 = fill(linearization_prefix, slots);
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
    source = append(source, fill(linearization_body, slots));
    return source;
}

fn objectiveSource(
    comptime name: []const u8,
    comptime solver: anytype,
) []const u8 {
    const R = @TypeOf(solver).residuals_per_observation;
    const bindings = rowBindings(solver);
    const slots = .{
        .{ "@name@", name },
        .{ "@n@", std.fmt.comptimePrint("{d}", .{solver.variables.len}) },
        .{ "@r@", std.fmt.comptimePrint("{d}", .{R}) },
    };
    var source: []const u8 = fill(objective_prefix, slots);
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
    source = append(source, fill(objective_body, slots));
    return source;
}

fn entrypointSource(
    comptime name: []const u8,
    comptime solver: anytype,
    comptime slots: anytype,
) []const u8 {
    var source: []const u8 = fill(entrypoint_prefix, slots);
    inline for (solver.variables, 0..) |variable, index| {
        source = append(source, std.fmt.comptimePrint(
            "    values[{d}] = inputs->initial.{s};\n",
            .{ index, variable },
        ));
    }
    source = append(source, fill(entrypoint_after_initial, slots));
    inline for (solver.data) |field| {
        source = append(source, std.fmt.comptimePrint(
            "        observation_finite = observation_finite && isfinite(observations[observation_index].{s});\n",
            .{field},
        ));
    }
    source = append(source, fill(entrypoint_after_validation, slots));
    _ = name;
    return source;
}

const entrypoint_prefix =
    \\
    \\void @name@(const @name@_inputs *inputs, @name@_result *output);
    \\
    \\void @name@(const @name@_inputs *inputs, @name@_result *output) {
    \\    const @name@_observation *observations = inputs->observations;
    \\    const size_t observation_count = inputs->observation_count;
    \\    size_t residual_count;
    \\    @scalar@ values[@n@];
    \\    size_t index;
    \\    if (observation_count > (size_t)-1 / @r@) {
    \\        for (index = 0; index < @n@; ++index) values[index] = NAN;
    \\        @name@_failure_result(
    \\            output,
    \\            values,
    \\            observation_count,
    \\            0,
    \\            @name@_numerical_failure
    \\        );
    \\        return;
    \\    }
    \\    residual_count = observation_count * @r@;
    \\
;

const entrypoint_after_initial =
    \\    if (!@name@_all_finite(values, @n@)) {
    \\        @name@_failure_result(
    \\            output,
    \\            values,
    \\            observation_count,
    \\            residual_count,
    \\            @name@_non_finite_initial
    \\        );
    \\        return;
    \\    }
    \\    if (observation_count == 0) {
    \\        @name@_failure_result(
    \\            output,
    \\            values,
    \\            0,
    \\            0,
    \\            @name@_empty_observations
    \\        );
    \\        return;
    \\    }
    \\    if (observations == NULL) {
    \\        @name@_failure_result(
    \\            output,
    \\            values,
    \\            observation_count,
    \\            residual_count,
    \\            @name@_numerical_failure
    \\        );
    \\        return;
    \\    }
    \\    for (index = 0; index < observation_count; ++index) {
    \\        const size_t observation_index = index;
    \\        int observation_finite = 1;
    \\
;

const entrypoint_after_validation =
    \\        if (!observation_finite) {
    \\            @name@_failure_result(
    \\                output,
    \\                values,
    \\                observation_count,
    \\                residual_count,
    \\                @name@_non_finite_observation
    \\            );
    \\            return;
    \\        }
    \\    }
    \\    if (!@name@_within_bounds(values)) {
    \\        if (@name@_config_initial_bounds == @name@_reject) {
    \\            @name@_failure_result(
    \\                output,
    \\                values,
    \\                observation_count,
    \\                residual_count,
    \\                @name@_infeasible_initial
    \\            );
    \\            return;
    \\        }
    \\        @name@_project_values(values);
    \\    }
    \\    {
    \\        @name@_counters counters = { 0 };
    \\        @name@_linearization current = @name@_linearize(
    \\            observations,
    \\            observation_count,
    \\            values
    \\        );
    \\        @scalar@ initial_cost;
    \\        @scalar@ scales[@n@];
    \\        @name@_factor scaled_factor;
    \\        @scalar@ damping;
    \\        @scalar@ nu = 2;
    \\        @scalar@ step_norm = 0;
    \\        size_t iteration;
    \\        counters.function_evaluations = 1;
    \\        counters.jacobian_evaluations = 1;
    \\        counters.observation_evaluations = current.visited;
    \\        if (current.failure != @name@_linearization_ok) {
    \\            @name@_failed_linearization_result_at(
    \\                output,
    \\                values,
    \\                NAN,
    \\                NAN,
    \\                observation_count,
    \\                residual_count,
    \\                0,
    \\                counters,
    \\                NAN,
    \\                NAN,
    \\                current.failure
    \\            );
    \\            return;
    \\        }
    \\        initial_cost = current.cost;
    \\        @name@_copy_vector(scales, @name@_config_parameter_scales);
    \\        @name@_update_scales(current.column_norms, scales);
    \\        scaled_factor = current.factor;
    \\        if (!@name@_factor_divide_columns(&scaled_factor, scales)) {
    \\            @name@_result_from(
    \\                output, values, initial_cost, current.cost,
    \\                observation_count, residual_count, 0, counters, 0,
    \\                &current, NAN, NAN, @name@_numerical_failure
    \\            );
    \\            return;
    \\        }
    \\        damping = @name@_initial_damping(current.column_norms, scales);
    \\        if (current.cost <= @name@_config_cost_tolerance) {
    \\            @name@_result_from(
    \\                output, values, initial_cost, current.cost,
    \\                observation_count, residual_count, 0, counters, damping,
    \\                &current, step_norm,
    \\                @name@_projected_optimality(
    \\                    values,
    \\                    current.gradient,
    \\                    scales
    \\                ),
    \\                @name@_converged_cost
    \\            );
    \\            return;
    \\        }
    \\        for (iteration = 0; iteration < @iterations@; ++iteration) {
    \\            const @scalar@ gradient_norm = @name@_projected_optimality(
    \\                values,
    \\                current.gradient,
    \\                scales
    \\            );
    \\            int accepted = 0;
    \\            @scalar@ accepted_values[@n@];
    \\            @scalar@ accepted_cost = current.cost;
    \\            @scalar@ accepted_step[@n@] = { 0 };
    \\            @scalar@ accepted_rho = 0;
    \\            int used_projected_gradient = 0;
    \\            size_t attempt;
    \\            if (!isfinite(gradient_norm)) {
    \\                @name@_result_from(
    \\                    output, values, initial_cost, current.cost,
    \\                    observation_count, residual_count, iteration, counters,
    \\                    damping, &current, step_norm, gradient_norm,
    \\                    @name@_numerical_failure
    \\                );
    \\                return;
    \\            }
    \\            if (gradient_norm <= @name@_config_gradient_tolerance) {
    \\                @name@_result_from(
    \\                    output, values, initial_cost, current.cost,
    \\                    observation_count, residual_count, iteration, counters,
    \\                    damping, &current, step_norm, gradient_norm,
    \\                    @name@_converged_gradient
    \\                );
    \\                return;
    \\            }
    \\            if (counters.function_evaluations >=
    \\                @name@_config_max_function_evaluations) {
    \\                @name@_result_from(
    \\                    output, values, initial_cost, current.cost,
    \\                    observation_count, residual_count, iteration, counters,
    \\                    damping, &current, step_norm, gradient_norm,
    \\                    @name@_max_function_evaluations
    \\                );
    \\                return;
    \\            }
    \\            @name@_copy_vector(accepted_values, values);
    \\            for (attempt = 0;
    \\                attempt < @name@_config_max_damping_trials;
    \\                ++attempt) {
    \\                @name@_factor damped;
    \\                @scalar@ scaled_direction[@n@];
    \\                @scalar@ candidate[@n@];
    \\                @scalar@ scaled_step[@n@];
    \\                @scalar@ model_norm;
    \\                @scalar@ predicted;
    \\                @name@_objective_result objective_trial;
    \\                @scalar@ actual;
    \\                @scalar@ rho;
    \\                if (counters.function_evaluations >=
    \\                    @name@_config_max_function_evaluations - 1) break;
    \\                damped = scaled_factor;
    \\                if (!@name@_factor_add_damping(&damped, damping)) {
    \\                    counters.invalid_steps += 1;
    \\                    @name@_increase_damping(&damping, &nu);
    \\                    continue;
    \\                }
    \\                if (!@name@_factor_solve(&damped, scaled_direction)) {
    \\                    counters.invalid_steps += 1;
    \\                    @name@_increase_damping(&damping, &nu);
    \\                    continue;
    \\                }
    \\                for (index = 0; index < @n@; ++index) {
    \\                    candidate[index] = @name@_clamp(
    \\                        values[index] + scaled_direction[index] / scales[index],
    \\                        @name@_config_lower[index],
    \\                        @name@_config_upper[index]
    \\                    );
    \\                    accepted_step[index] = candidate[index] - values[index];
    \\                }
    \\                if (!@name@_all_finite(candidate, @n@) ||
    \\                    @name@_norm_inf(accepted_step) == 0) {
    \\                    counters.rejected_steps += 1;
    \\                    @name@_increase_damping(&damping, &nu);
    \\                    continue;
    \\                }
    \\                for (index = 0; index < @n@; ++index) {
    \\                    scaled_step[index] = accepted_step[index] * scales[index];
    \\                }
    \\                model_norm = @name@_factor_transformed_norm(
    \\                    &scaled_factor,
    \\                    scaled_step
    \\                );
    \\                predicted = -(@name@_dot(current.gradient, accepted_step) +
    \\                    0.5 * model_norm * model_norm);
    \\                if (!isfinite(predicted) || predicted <= 0) {
    \\                    counters.invalid_steps += 1;
    \\                    @name@_increase_damping(&damping, &nu);
    \\                    continue;
    \\                }
    \\                if (counters.function_evaluations >=
    \\                    @name@_config_max_function_evaluations) break;
    \\                objective_trial = @name@_objective(
    \\                    observations,
    \\                    observation_count,
    \\                    candidate
    \\                );
    \\                counters.function_evaluations += 1;
    \\                counters.observation_evaluations += objective_trial.visited;
    \\                if (!objective_trial.valid) {
    \\                    counters.invalid_steps += 1;
    \\                    @name@_increase_damping(&damping, &nu);
    \\                    if (counters.invalid_steps >=
    \\                        @name@_config_max_invalid_steps) {
    \\                        @name@_result_from(
    \\                            output, values, initial_cost, current.cost,
    \\                            observation_count, residual_count, iteration,
    \\                            counters, damping, &current, step_norm,
    \\                            gradient_norm, @name@_too_many_invalid_trials
    \\                        );
    \\                        return;
    \\                    }
    \\                    continue;
    \\                }
    \\                actual = current.cost - objective_trial.cost;
    \\                rho = actual / predicted;
    \\                if (isfinite(rho) &&
    \\                    rho > @name@_config_acceptance_threshold && actual > 0) {
    \\                    accepted = 1;
    \\                    @name@_copy_vector(accepted_values, candidate);
    \\                    accepted_cost = objective_trial.cost;
    \\                    accepted_rho = rho;
    \\                    break;
    \\                }
    \\                counters.rejected_steps += 1;
    \\                @name@_increase_damping(&damping, &nu);
    \\            }
    \\            if (!accepted) {
    \\                @scalar@ direction[@n@];
    \\                @name@_trial trial;
    \\                if (counters.function_evaluations >=
    \\                    @name@_config_max_function_evaluations - 1) {
    \\                    @name@_result_from(
    \\                        output, values, initial_cost, current.cost,
    \\                        observation_count, residual_count, iteration,
    \\                        counters, damping, &current, step_norm,
    \\                        gradient_norm, @name@_max_function_evaluations
    \\                    );
    \\                    return;
    \\                }
    \\                @name@_projected_gradient_direction(
    \\                    values,
    \\                    current.gradient,
    \\                    scales,
    \\                    direction
    \\                );
    \\                trial = @name@_line_search(
    \\                    observations,
    \\                    observation_count,
    \\                    values,
    \\                    current.cost,
    \\                    current.gradient,
    \\                    direction,
    \\                    @name@_config_max_function_evaluations -
    \\                        counters.function_evaluations - 1
    \\                );
    \\                counters.function_evaluations += trial.evaluations;
    \\                counters.observation_evaluations += trial.visited;
    \\                counters.invalid_steps += trial.invalid;
    \\                if (!trial.accepted) {
    \\                    const @name@_status status =
    \\                        (counters.function_evaluations >=
    \\                            @name@_config_max_function_evaluations - 1)
    \\                            ? @name@_max_function_evaluations
    \\                            : @name@_line_search_failed;
    \\                    @name@_result_from(
    \\                        output, values, initial_cost, current.cost,
    \\                        observation_count, residual_count, iteration,
    \\                        counters, damping, &current, step_norm,
    \\                        gradient_norm, status
    \\                    );
    \\                    return;
    \\                }
    \\                used_projected_gradient = 1;
    \\                @name@_copy_vector(accepted_values, trial.values);
    \\                @name@_copy_vector(accepted_step, trial.step);
    \\                accepted_cost = trial.cost;
    \\                counters.projected_gradient_steps += 1;
    \\                @name@_increase_damping(&damping, &nu);
    \\            }
    \\            {
    \\                const @scalar@ old_cost = current.cost;
    \\                const @scalar@ old_value_norm = @name@_scaled_norm(values, scales);
    \\                @scalar@ new_gradient_norm;
    \\                @name@_status terminal_status = @name@_max_iterations;
    \\                int terminal = 0;
    \\                step_norm = @name@_scaled_norm(accepted_step, scales);
    \\                @name@_copy_vector(values, accepted_values);
    \\                counters.accepted_steps += 1;
    \\                current = @name@_linearize(
    \\                    observations,
    \\                    observation_count,
    \\                    values
    \\                );
    \\                counters.function_evaluations += 1;
    \\                counters.jacobian_evaluations += 1;
    \\                counters.observation_evaluations += current.visited;
    \\                if (current.failure != @name@_linearization_ok) {
    \\                    @name@_failed_linearization_result_at(
    \\                        output, values, initial_cost, accepted_cost,
    \\                        observation_count, residual_count, iteration + 1,
    \\                        counters, damping, step_norm, current.failure
    \\                    );
    \\                    return;
    \\                }
    \\                @name@_update_scales(current.column_norms, scales);
    \\                scaled_factor = current.factor;
    \\                if (!@name@_factor_divide_columns(&scaled_factor, scales)) {
    \\                    @name@_result_from(
    \\                        output, values, initial_cost, current.cost,
    \\                        observation_count, residual_count, iteration + 1,
    \\                        counters, damping, &current, step_norm, NAN,
    \\                        @name@_numerical_failure
    \\                    );
    \\                    return;
    \\                }
    \\                if (!used_projected_gradient) {
    \\                    const @scalar@ update = fmax@suffix@(
    \\                        1.0 / 3.0,
    \\                        1.0 - pow@suffix@(2.0 * accepted_rho - 1.0, 3.0)
    \\                    );
    \\                    damping = @name@_clamp(
    \\                        damping * update,
    \\                        @name@_config_minimum_damping,
    \\                        @name@_config_maximum_damping
    \\                    );
    \\                    nu = 2;
    \\                }
    \\                new_gradient_norm = @name@_projected_optimality(
    \\                    values,
    \\                    current.gradient,
    \\                    scales
    \\                );
    \\                if (new_gradient_norm <= @name@_config_gradient_tolerance) {
    \\                    terminal = 1;
    \\                    terminal_status = @name@_converged_gradient;
    \\                } else if (current.cost <= @name@_config_cost_tolerance) {
    \\                    terminal = 1;
    \\                    terminal_status = @name@_converged_cost;
    \\                } else if (step_norm <= @name@_config_step_tolerance *
    \\                    (@name@_config_step_tolerance + old_value_norm)) {
    \\                    terminal = 1;
    \\                    terminal_status = @name@_converged_step;
    \\                } else if (!used_projected_gradient && accepted_rho >= 0.25 &&
    \\                    old_cost - current.cost <=
    \\                        @name@_config_function_tolerance *
    \\                            fmax@suffix@(old_cost, 1)) {
    \\                    terminal = 1;
    \\                    terminal_status = @name@_converged_cost;
    \\                }
    \\                if (terminal) {
    \\                    @name@_result_from(
    \\                        output, values, initial_cost, current.cost,
    \\                        observation_count, residual_count, iteration + 1,
    \\                        counters, damping, &current, step_norm,
    \\                        new_gradient_norm, terminal_status
    \\                    );
    \\                    return;
    \\                }
    \\            }
    \\        }
    \\        @name@_result_from(
    \\            output,
    \\            values,
    \\            initial_cost,
    \\            current.cost,
    \\            observation_count,
    \\            residual_count,
    \\            @iterations@,
    \\            counters,
    \\            damping,
    \\            &current,
    \\            step_norm,
    \\            @name@_projected_optimality(values, current.gradient, scales),
    \\            @name@_max_iterations
    \\        );
    \\    }
    \\}
    \\
;

const linearization_prefix =
    \\
    \\static @name@_linearization @name@_linearize(
    \\    const @name@_observation *observations,
    \\    size_t observation_count,
    \\    const @scalar@ values[@n@]
    \\) {
    \\    @name@_linearization result;
    \\    size_t observation_index;
    \\    size_t index;
    \\    result.cost = 0;
    \\    result.factor = @name@_factor_init();
    \\    result.rank = 0;
    \\    result.visited = 0;
    \\    result.failure = @name@_linearization_ok;
    \\    for (index = 0; index < @n@; ++index) {
    \\        result.gradient[index] = 0;
    \\        result.column_norms[index] = 0;
    \\    }
    \\    for (observation_index = 0;
    \\        observation_index < observation_count;
    \\        ++observation_index) {
    \\        const @name@_observation *observation =
    \\            &observations[observation_index];
    \\        @scalar@ residuals[@r@];
    \\        @scalar@ jacobian[@r@][@n@];
    \\        size_t row_index;
    \\        result.visited += 1;
    \\
;

const linearization_body =
    \\        for (row_index = 0; row_index < @r@; ++row_index) {
    \\            const @scalar@ residual = residuals[row_index];
    \\            @name@_loss_evaluation robust;
    \\            @scalar@ weighted_residual;
    \\            @scalar@ weighted_row[@n@];
    \\            size_t column;
    \\            if (!isfinite(residual)) {
    \\                result.failure = @name@_non_finite_residual_failure;
    \\                return result;
    \\            }
    \\            if (!@name@_all_finite(jacobian[row_index], @n@)) {
    \\                result.failure = @name@_non_finite_jacobian_failure;
    \\                return result;
    \\            }
    \\            robust = @name@_evaluate_loss(residual);
    \\            if (!isfinite(robust.cost) || !isfinite(robust.sqrt_weight)) {
    \\                result.failure = @name@_numerical_failure_internal;
    \\                return result;
    \\            }
    \\            result.cost += robust.cost;
    \\            if (!isfinite(result.cost)) {
    \\                result.failure = @name@_numerical_failure_internal;
    \\                return result;
    \\            }
    \\            weighted_residual = robust.sqrt_weight * residual;
    \\            for (column = 0; column < @n@; ++column) {
    \\                weighted_row[column] =
    \\                    robust.sqrt_weight * jacobian[row_index][column];
    \\                result.gradient[column] +=
    \\                    weighted_row[column] * weighted_residual;
    \\                result.column_norms[column] = hypot@suffix@(
    \\                    result.column_norms[column],
    \\                    weighted_row[column]
    \\                );
    \\            }
    \\            if (!@name@_all_finite(weighted_row, @n@) ||
    \\                !@name@_all_finite(result.gradient, @n@) ||
    \\                !@name@_all_finite(result.column_norms, @n@) ||
    \\                !@name@_factor_add_row(
    \\                    &result.factor,
    \\                    weighted_row,
    \\                    -weighted_residual
    \\                )) {
    \\                result.failure = @name@_numerical_failure_internal;
    \\                return result;
    \\            }
    \\        }
    \\    }
    \\    result.rank = @name@_factor_rank(
    \\        &result.factor,
    \\        @name@_config_rank_tolerance
    \\    );
    \\    return result;
    \\}
    \\
;

const objective_prefix =
    \\
    \\static @name@_objective_result @name@_objective(
    \\    const @name@_observation *observations,
    \\    size_t observation_count,
    \\    const @scalar@ values[@n@]
    \\) {
    \\    @name@_objective_result result;
    \\    size_t observation_index;
    \\    result.cost = 0;
    \\    result.visited = 0;
    \\    result.valid = 1;
    \\    for (observation_index = 0;
    \\        observation_index < observation_count;
    \\        ++observation_index) {
    \\        const @name@_observation *observation =
    \\            &observations[observation_index];
    \\        @scalar@ residuals[@r@];
    \\        size_t row_index;
    \\        result.visited += 1;
    \\
;

const objective_body =
    \\        for (row_index = 0; row_index < @r@; ++row_index) {
    \\            const @scalar@ residual = residuals[row_index];
    \\            @name@_loss_evaluation robust;
    \\            if (!isfinite(residual)) {
    \\                result.valid = 0;
    \\                return result;
    \\            }
    \\            robust = @name@_evaluate_loss(residual);
    \\            result.cost += robust.cost;
    \\            if (!isfinite(robust.cost) || !isfinite(result.cost)) {
    \\                result.valid = 0;
    \\                return result;
    \\            }
    \\        }
    \\    }
    \\    return result;
    \\}
    \\
;

const public_types =
    \\
    \\typedef enum @name@_status {
    \\    @name@_converged_gradient,
    \\    @name@_converged_cost,
    \\    @name@_converged_step,
    \\    @name@_max_iterations,
    \\    @name@_max_function_evaluations,
    \\    @name@_empty_observations,
    \\    @name@_infeasible_initial,
    \\    @name@_non_finite_initial,
    \\    @name@_non_finite_observation,
    \\    @name@_non_finite_jacobian,
    \\    @name@_too_many_invalid_trials,
    \\    @name@_line_search_failed,
    \\    @name@_numerical_failure
    \\} @name@_status;
    \\
    \\typedef enum @name@_bound_activity {
    \\    @name@_free,
    \\    @name@_lower,
    \\    @name@_upper,
    \\    @name@_fixed
    \\} @name@_bound_activity;
    \\
    \\typedef struct @name@_result {
    \\    @scalar@ values[@n@];
    \\    @scalar@ initial_cost;
    \\    @scalar@ cost;
    \\    size_t observation_count;
    \\    size_t residual_count;
    \\    size_t iterations;
    \\    size_t function_evaluations;
    \\    size_t jacobian_evaluations;
    \\    size_t observation_evaluations;
    \\    size_t accepted_steps;
    \\    size_t rejected_steps;
    \\    size_t projected_gradient_steps;
    \\    size_t invalid_steps;
    \\    size_t rank;
    \\    @name@_bound_activity active_bounds[@n@];
    \\    @scalar@ gradient_norm;
    \\    @scalar@ step_norm;
    \\    @scalar@ damping;
    \\    @name@_status status;
    \\} @name@_result;
    \\
    \\typedef enum @name@_loss_kind {
    \\    @name@_linear,
    \\    @name@_huber,
    \\    @name@_soft_l1,
    \\    @name@_cauchy
    \\} @name@_loss_kind;
    \\
    \\typedef struct @name@_loss {
    \\    @name@_loss_kind kind;
    \\    @scalar@ scale;
    \\} @name@_loss;
    \\
    \\typedef enum @name@_scaling {
    \\    @name@_none,
    \\    @name@_jacobian,
    \\    @name@_user
    \\} @name@_scaling;
    \\
    \\typedef enum @name@_initial_bounds {
    \\    @name@_reject,
    \\    @name@_project
    \\} @name@_initial_bounds;
    \\
    \\typedef enum @name@_linearization_failure {
    \\    @name@_linearization_ok,
    \\    @name@_non_finite_residual_failure,
    \\    @name@_non_finite_jacobian_failure,
    \\    @name@_numerical_failure_internal
    \\} @name@_linearization_failure;
    \\
    \\typedef struct @name@_counters {
    \\    size_t function_evaluations;
    \\    size_t jacobian_evaluations;
    \\    size_t observation_evaluations;
    \\    size_t accepted_steps;
    \\    size_t rejected_steps;
    \\    size_t projected_gradient_steps;
    \\    size_t invalid_steps;
    \\} @name@_counters;
    \\
    \\typedef struct @name@_factor {
    \\    @scalar@ upper[@n@][@n@];
    \\    @scalar@ transformed_rhs[@n@];
    \\    size_t rows;
    \\} @name@_factor;
    \\
    \\typedef struct @name@_linearization {
    \\    @scalar@ cost;
    \\    @scalar@ gradient[@n@];
    \\    @scalar@ column_norms[@n@];
    \\    @name@_factor factor;
    \\    size_t rank;
    \\    size_t visited;
    \\    @name@_linearization_failure failure;
    \\} @name@_linearization;
    \\
    \\typedef struct @name@_objective_result {
    \\    @scalar@ cost;
    \\    size_t visited;
    \\    int valid;
    \\} @name@_objective_result;
    \\
    \\typedef struct @name@_trial {
    \\    int accepted;
    \\    @scalar@ values[@n@];
    \\    @scalar@ step[@n@];
    \\    @scalar@ cost;
    \\    size_t evaluations;
    \\    size_t visited;
    \\    size_t invalid;
    \\} @name@_trial;
    \\
    \\typedef struct @name@_loss_evaluation {
    \\    @scalar@ cost;
    \\    @scalar@ sqrt_weight;
    \\} @name@_loss_evaluation;
    \\
    \\static @name@_linearization @name@_linearize(
    \\    const @name@_observation *observations,
    \\    size_t observation_count,
    \\    const @scalar@ values[@n@]
    \\);
    \\static @name@_objective_result @name@_objective(
    \\    const @name@_observation *observations,
    \\    size_t observation_count,
    \\    const @scalar@ values[@n@]
    \\);
    \\
    \\int @name@_result_converged(const @name@_result *result) {
    \\    return result->status == @name@_converged_gradient ||
    \\        result->status == @name@_converged_cost ||
    \\        result->status == @name@_converged_step;
    \\}
    \\
;

const runtime_support = factor_support ++ optimizer_support;

const factor_support =
    \\
    \\static int @name@_all_finite(const @scalar@ *values, size_t count) {
    \\    size_t index;
    \\    for (index = 0; index < count; ++index) {
    \\        if (!isfinite(values[index])) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static @scalar@ @name@_stable_norm(const @scalar@ *values, size_t count) {
    \\    @scalar@ scale = 0;
    \\    @scalar@ sum = 1;
    \\    size_t index;
    \\    for (index = 0; index < count; ++index) {
    \\        const @scalar@ magnitude = fabs@suffix@(values[index]);
    \\        if (magnitude == 0) continue;
    \\        if (!isfinite(magnitude)) return magnitude;
    \\        if (scale < magnitude) {
    \\            const @scalar@ ratio = scale / magnitude;
    \\            sum = 1 + sum * ratio * ratio;
    \\            scale = magnitude;
    \\        } else {
    \\            const @scalar@ ratio = magnitude / scale;
    \\            sum += ratio * ratio;
    \\        }
    \\    }
    \\    return (scale == 0) ? 0 : scale * sqrt@suffix@(sum);
    \\}
    \\
    \\static void @name@_copy_vector(
    \\    @scalar@ destination[@n@],
    \\    const @scalar@ source[@n@]
    \\) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) destination[index] = source[index];
    \\}
    \\
    \\static @scalar@ @name@_clamp(
    \\    @scalar@ value,
    \\    @scalar@ lower,
    \\    @scalar@ upper
    \\) {
    \\    if (value < lower) return lower;
    \\    if (value > upper) return upper;
    \\    return value;
    \\}
    \\
    \\static @name@_factor @name@_factor_init(void) {
    \\    @name@_factor factor;
    \\    size_t row;
    \\    size_t column;
    \\    for (row = 0; row < @n@; ++row) {
    \\        factor.transformed_rhs[row] = 0;
    \\        for (column = 0; column < @n@; ++column) {
    \\            factor.upper[row][column] = 0;
    \\        }
    \\    }
    \\    factor.rows = 0;
    \\    return factor;
    \\}
    \\
    \\static int @name@_factor_add_row(
    \\    @name@_factor *factor,
    \\    const @scalar@ input_row[@n@],
    \\    @scalar@ input_rhs
    \\) {
    \\    @scalar@ row[@n@];
    \\    @scalar@ rhs = input_rhs;
    \\    size_t pivot;
    \\    size_t column;
    \\    @name@_copy_vector(row, input_row);
    \\    if (!@name@_all_finite(row, @n@) || !isfinite(rhs)) return 0;
    \\    for (pivot = 0; pivot < @n@; ++pivot) {
    \\        const @scalar@ below = row[pivot];
    \\        @scalar@ diagonal;
    \\        @scalar@ radius;
    \\        @scalar@ cosine;
    \\        @scalar@ sine;
    \\        @scalar@ upper_rhs;
    \\        if (below == 0) continue;
    \\        diagonal = factor->upper[pivot][pivot];
    \\        radius = hypot@suffix@(diagonal, below);
    \\        if (!isfinite(radius) || radius == 0) return 0;
    \\        cosine = diagonal / radius;
    \\        sine = below / radius;
    \\        factor->upper[pivot][pivot] = radius;
    \\        row[pivot] = 0;
    \\        for (column = pivot + 1; column < @n@; ++column) {
    \\            const @scalar@ upper_value = factor->upper[pivot][column];
    \\            const @scalar@ row_value = row[column];
    \\            factor->upper[pivot][column] =
    \\                cosine * upper_value + sine * row_value;
    \\            row[column] = -sine * upper_value + cosine * row_value;
    \\        }
    \\        upper_rhs = factor->transformed_rhs[pivot];
    \\        factor->transformed_rhs[pivot] = cosine * upper_rhs + sine * rhs;
    \\        rhs = -sine * upper_rhs + cosine * rhs;
    \\        if (!@name@_all_finite(factor->upper[pivot], @n@) ||
    \\            !isfinite(factor->transformed_rhs[pivot]) || !isfinite(rhs)) {
    \\            return 0;
    \\        }
    \\    }
    \\    if (factor->rows != (size_t)-1) factor->rows += 1;
    \\    return 1;
    \\}
    \\
    \\static int @name@_factor_divide_columns(
    \\    @name@_factor *factor,
    \\    const @scalar@ diagonal[@n@]
    \\) {
    \\    size_t column;
    \\    size_t row;
    \\    for (column = 0; column < @n@; ++column) {
    \\        if (!isfinite(diagonal[column]) || diagonal[column] <= 0) return 0;
    \\        for (row = 0; row <= column; ++row) {
    \\            factor->upper[row][column] /= diagonal[column];
    \\            if (!isfinite(factor->upper[row][column])) return 0;
    \\        }
    \\    }
    \\    return 1;
    \\}
    \\
    \\static int @name@_factor_add_damping(
    \\    @name@_factor *factor,
    \\    @scalar@ damping
    \\) {
    \\    const @scalar@ root = sqrt@suffix@(damping);
    \\    size_t column;
    \\    if (!isfinite(damping) || damping <= 0 ||
    \\        !isfinite(root) || root == 0) return 0;
    \\    for (column = 0; column < @n@; ++column) {
    \\        @scalar@ row[@n@] = { 0 };
    \\        row[column] = root;
    \\        if (!@name@_factor_add_row(factor, row, 0)) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static int @name@_factor_solve(
    \\    const @name@_factor *factor,
    \\    @scalar@ solution[@n@]
    \\) {
    \\    size_t reverse = @n@;
    \\    while (reverse != 0) {
    \\        @scalar@ value;
    \\        @scalar@ diagonal;
    \\        size_t column;
    \\        reverse -= 1;
    \\        value = factor->transformed_rhs[reverse];
    \\        for (column = reverse + 1; column < @n@; ++column) {
    \\            value -= factor->upper[reverse][column] * solution[column];
    \\        }
    \\        diagonal = factor->upper[reverse][reverse];
    \\        if (!isfinite(diagonal) || diagonal == 0) return 0;
    \\        solution[reverse] = value / diagonal;
    \\        if (!isfinite(solution[reverse])) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static @scalar@ @name@_factor_transformed_norm(
    \\    const @name@_factor *factor,
    \\    const @scalar@ vector[@n@]
    \\) {
    \\    @scalar@ transformed[@n@];
    \\    size_t row;
    \\    size_t column;
    \\    for (row = 0; row < @n@; ++row) {
    \\        @scalar@ value = 0;
    \\        for (column = row; column < @n@; ++column) {
    \\            value += factor->upper[row][column] * vector[column];
    \\        }
    \\        transformed[row] = value;
    \\    }
    \\    return @name@_stable_norm(transformed, @n@);
    \\}
    \\
    \\static size_t @name@_factor_rank(
    \\    const @name@_factor *factor,
    \\    @scalar@ relative_tolerance
    \\) {
    \\    @scalar@ maximum = 0;
    \\    @scalar@ threshold;
    \\    size_t result = 0;
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        maximum = fmax@suffix@(maximum, fabs@suffix@(factor->upper[index][index]));
    \\    }
    \\    if (maximum == 0 || !isfinite(maximum)) return 0;
    \\    threshold = relative_tolerance * maximum;
    \\    for (index = 0; index < @n@; ++index) {
    \\        const @scalar@ diagonal = fabs@suffix@(factor->upper[index][index]);
    \\        if (isfinite(diagonal) && diagonal > threshold) result += 1;
    \\    }
    \\    return result;
    \\}
    \\
;

const optimizer_support =
    \\
    \\static @name@_loss_evaluation @name@_evaluate_loss(@scalar@ residual) {
    \\    @name@_loss_evaluation result;
    \\    const @name@_loss loss = @name@_config_loss;
    \\    const @scalar@ magnitude = fabs@suffix@(residual);
    \\    const @scalar@ t = magnitude / loss.scale;
    \\    if (loss.kind == @name@_linear ||
    \\        (loss.kind == @name@_huber && t <= 1)) {
    \\        result.cost = 0.5 * residual * residual;
    \\        result.sqrt_weight = 1;
    \\        return result;
    \\    }
    \\    if (loss.kind == @name@_huber) {
    \\        result.cost = loss.scale * (magnitude - 0.5 * loss.scale);
    \\        result.sqrt_weight = sqrt@suffix@(loss.scale / magnitude);
    \\        return result;
    \\    }
    \\    if (t < sqrt@suffix@(@epsilon@)) {
    \\        result.cost = 0.5 * residual * residual;
    \\        result.sqrt_weight = 1;
    \\        return result;
    \\    }
    \\    if (loss.kind == @name@_soft_l1) {
    \\        const @scalar@ hypotenuse = hypot@suffix@(loss.scale, residual);
    \\        const @scalar@ difference =
    \\            (hypotenuse > @maximum@ - loss.scale)
    \\                ? hypotenuse - loss.scale
    \\                : magnitude * (magnitude / (hypotenuse + loss.scale));
    \\        result.cost = loss.scale * difference;
    \\        result.sqrt_weight = sqrt@suffix@(loss.scale / hypotenuse);
    \\        return result;
    \\    }
    \\    {
    \\        const @scalar@ hypotenuse = hypot@suffix@(loss.scale, residual);
    \\        @scalar@ log_ratio;
    \\        if (magnitude == 0) {
    \\            log_ratio = 0;
    \\        } else if (!isfinite(t)) {
    \\            log_ratio = log@suffix@(hypotenuse) - log@suffix@(loss.scale);
    \\        } else if (t <= sqrt@suffix@(@maximum@)) {
    \\            log_ratio = 0.5 * log1p@suffix@(t * t);
    \\        } else {
    \\            log_ratio = log@suffix@(t) + 0.5 * log1p@suffix@(1 / t / t);
    \\        }
    \\        result.cost = loss.scale * (loss.scale * log_ratio);
    \\        result.sqrt_weight = loss.scale / hypotenuse;
    \\        return result;
    \\    }
    \\}
    \\
    \\static @scalar@ @name@_dot(
    \\    const @scalar@ left[@n@],
    \\    const @scalar@ right[@n@]
    \\) {
    \\    @scalar@ result = 0;
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) result += left[index] * right[index];
    \\    return result;
    \\}
    \\
    \\static @scalar@ @name@_norm_inf(const @scalar@ vector[@n@]) {
    \\    @scalar@ result = 0;
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        result = fmax@suffix@(result, fabs@suffix@(vector[index]));
    \\    }
    \\    return result;
    \\}
    \\
    \\static int @name@_within_bounds(const @scalar@ values[@n@]) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        if (values[index] < @name@_config_lower[index] ||
    \\            values[index] > @name@_config_upper[index]) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static void @name@_project_values(@scalar@ values[@n@]) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        values[index] = @name@_clamp(
    \\            values[index],
    \\            @name@_config_lower[index],
    \\            @name@_config_upper[index]
    \\        );
    \\    }
    \\}
    \\
    \\static void @name@_update_scales(
    \\    const @scalar@ column_norms[@n@],
    \\    @scalar@ scales[@n@]
    \\) {
    \\    size_t index;
    \\    if (@name@_config_scaling != @name@_jacobian) return;
    \\    for (index = 0; index < @n@; ++index) {
    \\        if (column_norms[index] > 0 && isfinite(column_norms[index])) {
    \\            scales[index] = fmax@suffix@(scales[index], column_norms[index]);
    \\        }
    \\    }
    \\}
    \\
    \\static @scalar@ @name@_initial_damping(
    \\    const @scalar@ column_norms[@n@],
    \\    const @scalar@ scales[@n@]
    \\) {
    \\    @scalar@ largest = 0;
    \\    @scalar@ squared;
    \\    @scalar@ raw;
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        largest = fmax@suffix@(largest, column_norms[index] / scales[index]);
    \\    }
    \\    squared = (largest > sqrt@suffix@(@maximum@))
    \\        ? @name@_config_maximum_damping
    \\        : largest * largest;
    \\    raw = @name@_config_damping_tau * fmax@suffix@(squared, 1);
    \\    return @name@_clamp(
    \\        raw,
    \\        @name@_config_minimum_damping,
    \\        @name@_config_maximum_damping
    \\    );
    \\}
    \\
    \\static void @name@_projected_gradient_direction(
    \\    const @scalar@ values[@n@],
    \\    const @scalar@ gradient[@n@],
    \\    const @scalar@ scales[@n@],
    \\    @scalar@ result[@n@]
    \\) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        const @scalar@ candidate = @name@_clamp(
    \\            values[index] - gradient[index] / scales[index] / scales[index],
    \\            @name@_config_lower[index],
    \\            @name@_config_upper[index]
    \\        );
    \\        result[index] = candidate - values[index];
    \\    }
    \\}
    \\
    \\static @scalar@ @name@_projected_optimality(
    \\    const @scalar@ values[@n@],
    \\    const @scalar@ gradient[@n@],
    \\    const @scalar@ scales[@n@]
    \\) {
    \\    @scalar@ maximum = 0;
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        const @scalar@ scaled_gradient = fabs@suffix@(gradient[index] / scales[index]);
    \\        @scalar@ feasible_distance;
    \\        if (@name@_config_lower[index] == -INFINITY &&
    \\            @name@_config_upper[index] == INFINITY) {
    \\            maximum = fmax@suffix@(maximum, scaled_gradient);
    \\            continue;
    \\        }
    \\        if (gradient[index] > 0) {
    \\            feasible_distance = values[index] - @name@_config_lower[index];
    \\        } else if (gradient[index] < 0) {
    \\            feasible_distance = @name@_config_upper[index] - values[index];
    \\        } else {
    \\            feasible_distance = 0;
    \\        }
    \\        maximum = fmax@suffix@(
    \\            maximum,
    \\            fmin@suffix@(scaled_gradient, feasible_distance * scales[index])
    \\        );
    \\    }
    \\    return maximum;
    \\}
    \\
    \\static void @name@_active_bounds(
    \\    const @scalar@ values[@n@],
    \\    const @scalar@ gradient[@n@],
    \\    @name@_bound_activity result[@n@]
    \\) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        if (@name@_config_lower[index] == @name@_config_upper[index]) {
    \\            result[index] = @name@_fixed;
    \\        } else if (values[index] <= @name@_config_lower[index] &&
    \\            gradient[index] > 0) {
    \\            result[index] = @name@_lower;
    \\        } else if (values[index] >= @name@_config_upper[index] &&
    \\            gradient[index] < 0) {
    \\            result[index] = @name@_upper;
    \\        } else {
    \\            result[index] = @name@_free;
    \\        }
    \\    }
    \\}
    \\
    \\static void @name@_increase_damping(@scalar@ *damping, @scalar@ *nu) {
    \\    *damping = fmin@suffix@(
    \\        *damping * *nu,
    \\        @name@_config_maximum_damping
    \\    );
    \\    *nu = fmin@suffix@(*nu * 2, sqrt@suffix@(@maximum@));
    \\}
    \\
    \\static @scalar@ @name@_scaled_norm(
    \\    const @scalar@ values[@n@],
    \\    const @scalar@ scales[@n@]
    \\) {
    \\    @scalar@ scaled[@n@];
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        scaled[index] = values[index] * scales[index];
    \\    }
    \\    return @name@_stable_norm(scaled, @n@);
    \\}
    \\
    \\static @name@_trial @name@_line_search(
    \\    const @name@_observation *observations,
    \\    size_t observation_count,
    \\    const @scalar@ values[@n@],
    \\    @scalar@ cost,
    \\    const @scalar@ gradient[@n@],
    \\    const @scalar@ direction[@n@],
    \\    size_t max_evaluations
    \\) {
    \\    @name@_trial result;
    \\    @scalar@ alpha = 1;
    \\    size_t limit = @name@_config_max_line_search_steps;
    \\    size_t attempt;
    \\    size_t index;
    \\    result.accepted = 0;
    \\    @name@_copy_vector(result.values, values);
    \\    for (index = 0; index < @n@; ++index) result.step[index] = 0;
    \\    result.cost = cost;
    \\    result.evaluations = 0;
    \\    result.visited = 0;
    \\    result.invalid = 0;
    \\    if (max_evaluations < limit) limit = max_evaluations;
    \\    for (attempt = 0; attempt < limit; ++attempt) {
    \\        @scalar@ candidate[@n@];
    \\        @scalar@ directional_derivative;
    \\        @name@_objective_result trial;
    \\        for (index = 0; index < @n@; ++index) {
    \\            candidate[index] = @name@_clamp(
    \\                values[index] + alpha * direction[index],
    \\                @name@_config_lower[index],
    \\                @name@_config_upper[index]
    \\            );
    \\            result.step[index] = candidate[index] - values[index];
    \\        }
    \\        directional_derivative = @name@_dot(gradient, result.step);
    \\        if (!isfinite(directional_derivative) ||
    \\            directional_derivative >= 0 || @name@_norm_inf(result.step) == 0) {
    \\            alpha *= @name@_config_backtrack_factor;
    \\            continue;
    \\        }
    \\        trial = @name@_objective(observations, observation_count, candidate);
    \\        result.evaluations += 1;
    \\        result.visited += trial.visited;
    \\        if (!trial.valid) {
    \\            result.invalid += 1;
    \\            alpha *= @name@_config_backtrack_factor;
    \\            continue;
    \\        }
    \\        if (trial.cost <= cost +
    \\            @name@_config_armijo_constant * directional_derivative) {
    \\            result.accepted = 1;
    \\            @name@_copy_vector(result.values, candidate);
    \\            result.cost = trial.cost;
    \\            return result;
    \\        }
    \\        alpha *= @name@_config_backtrack_factor;
    \\    }
    \\    return result;
    \\}
    \\
    \\static void @name@_result_from(
    \\    @name@_result *output,
    \\    const @scalar@ values[@n@],
    \\    @scalar@ initial_cost,
    \\    @scalar@ cost,
    \\    size_t observation_count,
    \\    size_t residual_count,
    \\    size_t iterations,
    \\    @name@_counters counters,
    \\    @scalar@ damping,
    \\    const @name@_linearization *linearization,
    \\    @scalar@ step_norm,
    \\    @scalar@ gradient_norm,
    \\    @name@_status status
    \\) {
    \\    @name@_copy_vector(output->values, values);
    \\    output->initial_cost = initial_cost;
    \\    output->cost = cost;
    \\    output->observation_count = observation_count;
    \\    output->residual_count = residual_count;
    \\    output->iterations = iterations;
    \\    output->function_evaluations = counters.function_evaluations;
    \\    output->jacobian_evaluations = counters.jacobian_evaluations;
    \\    output->observation_evaluations = counters.observation_evaluations;
    \\    output->accepted_steps = counters.accepted_steps;
    \\    output->rejected_steps = counters.rejected_steps;
    \\    output->projected_gradient_steps = counters.projected_gradient_steps;
    \\    output->invalid_steps = counters.invalid_steps;
    \\    output->rank = linearization->rank;
    \\    @name@_active_bounds(values, linearization->gradient, output->active_bounds);
    \\    output->gradient_norm = gradient_norm;
    \\    output->step_norm = step_norm;
    \\    output->damping = damping;
    \\    output->status = status;
    \\}
    \\
    \\static void @name@_failure_result(
    \\    @name@_result *output,
    \\    const @scalar@ values[@n@],
    \\    size_t observation_count,
    \\    size_t residual_count,
    \\    @name@_status status
    \\) {
    \\    size_t index;
    \\    @name@_copy_vector(output->values, values);
    \\    output->initial_cost = NAN;
    \\    output->cost = NAN;
    \\    output->observation_count = observation_count;
    \\    output->residual_count = residual_count;
    \\    output->iterations = 0;
    \\    output->function_evaluations = 0;
    \\    output->jacobian_evaluations = 0;
    \\    output->observation_evaluations = 0;
    \\    output->accepted_steps = 0;
    \\    output->rejected_steps = 0;
    \\    output->projected_gradient_steps = 0;
    \\    output->invalid_steps = 0;
    \\    output->rank = 0;
    \\    for (index = 0; index < @n@; ++index) {
    \\        output->active_bounds[index] = @name@_free;
    \\    }
    \\    output->gradient_norm = NAN;
    \\    output->step_norm = NAN;
    \\    output->damping = NAN;
    \\    output->status = status;
    \\}
    \\
    \\static void @name@_failed_linearization_result_at(
    \\    @name@_result *output,
    \\    const @scalar@ values[@n@],
    \\    @scalar@ initial_cost,
    \\    @scalar@ cost,
    \\    size_t observation_count,
    \\    size_t residual_count,
    \\    size_t iterations,
    \\    @name@_counters counters,
    \\    @scalar@ damping,
    \\    @scalar@ step_norm,
    \\    @name@_linearization_failure failure
    \\) {
    \\    size_t index;
    \\    @name@_copy_vector(output->values, values);
    \\    output->initial_cost = initial_cost;
    \\    output->cost = cost;
    \\    output->observation_count = observation_count;
    \\    output->residual_count = residual_count;
    \\    output->iterations = iterations;
    \\    output->function_evaluations = counters.function_evaluations;
    \\    output->jacobian_evaluations = counters.jacobian_evaluations;
    \\    output->observation_evaluations = counters.observation_evaluations;
    \\    output->accepted_steps = counters.accepted_steps;
    \\    output->rejected_steps = counters.rejected_steps;
    \\    output->projected_gradient_steps = counters.projected_gradient_steps;
    \\    output->invalid_steps = counters.invalid_steps;
    \\    output->rank = 0;
    \\    for (index = 0; index < @n@; ++index) {
    \\        output->active_bounds[index] = @name@_free;
    \\    }
    \\    output->gradient_norm = NAN;
    \\    output->step_norm = step_norm;
    \\    output->damping = damping;
    \\    if (failure == @name@_non_finite_residual_failure) {
    \\        output->status = (counters.accepted_steps == 0)
    \\            ? @name@_non_finite_initial
    \\            : @name@_numerical_failure;
    \\    } else if (failure == @name@_non_finite_jacobian_failure) {
    \\        output->status = @name@_non_finite_jacobian;
    \\    } else {
    \\        output->status = @name@_numerical_failure;
    \\    }
    \\}
    \\
;
