const std = @import("std");
const ast = @import("../../expression.zig");
const differentiation = @import("../transform/differentiation.zig");
const evaluation = @import("../runtime/evaluation.zig");
const limits = @import("../core/limits.zig");
const multi = @import("../transform/multi.zig");
const options_validation = @import("../core/options.zig");

pub const NewtonStatus = enum {
    converged,
    singular_jacobian,
    non_converged,
    non_finite,
};

pub const SensitivityStatus = enum {
    converged,
    root_not_converged,
    singular_jacobian,
    non_finite,
};

pub fn NewtonResult(comptime N: usize) type {
    return struct {
        values: [N]f64,
        residual: [N]f64,
        iterations: usize,
        residual_norm: f64,
        step_norm: f64,
        status: NewtonStatus,
    };
}

pub fn NewtonSolver(
    comptime N: usize,
    comptime max_iterations: usize,
) type {
    if (N == 0) @compileError("Bombelli Newton solver requires at least one unknown");
    if (max_iterations == 0) {
        @compileError("Bombelli Newton solver max_iterations must be positive");
    }
    return struct {
        residuals: ast.ExprVector(N),
        jacobian_program: ast.ExprMatrix(N, N),
        unknowns: [N][]const u8,
        tolerance: f64,
        pivot_tolerance: f64,

        pub const maximum_iterations = max_iterations;
        const Self = @This();

        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) NewtonResult(N) {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{self.residuals.nodes},
                &.{"initial"},
                &self.unknowns,
                "Newton eval",
            );
            var values = initialValues(N, self.unknowns, inputs);
            var residual = evaluation.evaluateVectorWithVariables(
                N,
                N,
                self.residuals,
                inputs,
                self.unknowns,
                values,
            );
            var residual_norm = infinityNorm(N, residual);
            if (!allFiniteVector(N, values) or
                !allFiniteVector(N, residual) or
                !std.math.isFinite(residual_norm))
            {
                return result(
                    N,
                    values,
                    residual,
                    0,
                    residual_norm,
                    0.0,
                    .non_finite,
                );
            }
            if (residual_norm <= self.tolerance) {
                return result(
                    N,
                    values,
                    residual,
                    0,
                    residual_norm,
                    0.0,
                    .converged,
                );
            }

            var step_norm: f64 = 0.0;
            for (0..max_iterations) |iteration| {
                const jacobian = evaluation.evaluateMatrixWithVariables(
                    N,
                    N,
                    N,
                    self.jacobian_program,
                    inputs,
                    self.unknowns,
                    values,
                );
                if (!allFiniteMatrix(N, jacobian)) {
                    return result(
                        N,
                        values,
                        residual,
                        iteration,
                        residual_norm,
                        step_norm,
                        .non_finite,
                    );
                }
                var right_hand_side: [N]f64 = undefined;
                for (residual, 0..) |entry, index| {
                    right_hand_side[index] = -entry;
                }
                const step = solveLinearSystem(
                    N,
                    jacobian,
                    right_hand_side,
                    self.pivot_tolerance,
                ) orelse return result(
                    N,
                    values,
                    residual,
                    iteration,
                    residual_norm,
                    step_norm,
                    .singular_jacobian,
                );
                step_norm = infinityNorm(N, step);
                for (&values, step) |*value, increment| value.* += increment;
                residual = evaluation.evaluateVectorWithVariables(
                    N,
                    N,
                    self.residuals,
                    inputs,
                    self.unknowns,
                    values,
                );
                residual_norm = infinityNorm(N, residual);
                if (!allFiniteVector(N, values) or
                    !allFiniteVector(N, residual) or
                    !std.math.isFinite(step_norm) or
                    !std.math.isFinite(residual_norm))
                {
                    return result(
                        N,
                        values,
                        residual,
                        iteration + 1,
                        residual_norm,
                        step_norm,
                        .non_finite,
                    );
                }
                if (residual_norm <= self.tolerance) {
                    return result(
                        N,
                        values,
                        residual,
                        iteration + 1,
                        residual_norm,
                        step_norm,
                        .converged,
                    );
                }
            }
            return result(
                N,
                values,
                residual,
                max_iterations,
                residual_norm,
                step_norm,
                .non_converged,
            );
        }

        pub fn diff(
            comptime self: Self,
            comptime parameter: anytype,
        ) NewtonSensitivitySolver(N, max_iterations) {
            return compileSensitivity(N, max_iterations, self, parameter);
        }

        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(limits.eval_branch.solve);
            return @import("../codegen/emit.zig").emitNewton(self, options);
        }
    };
}

pub fn SensitivityResult(comptime N: usize) type {
    return struct {
        root: NewtonResult(N),
        sensitivities: [N]f64,
        status: SensitivityStatus,
    };
}

pub fn NewtonSensitivitySolver(
    comptime N: usize,
    comptime max_iterations: usize,
) type {
    return struct {
        solver: NewtonSolver(N, max_iterations),
        parameter_derivatives: ast.ExprVector(N),

        const Self = @This();

        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) SensitivityResult(N) {
            const root = self.solver.eval(inputs);
            if (root.status != .converged) {
                return .{
                    .root = root,
                    .sensitivities = nanVector(N),
                    .status = .root_not_converged,
                };
            }
            const jacobian = evaluation.evaluateMatrixWithVariables(
                N,
                N,
                N,
                self.solver.jacobian_program,
                inputs,
                self.solver.unknowns,
                root.values,
            );
            const parameter_derivatives =
                evaluation.evaluateVectorWithVariables(
                    N,
                    N,
                    self.parameter_derivatives,
                    inputs,
                    self.solver.unknowns,
                    root.values,
                );
            if (!allFiniteMatrix(N, jacobian) or
                !allFiniteVector(N, parameter_derivatives))
            {
                return .{
                    .root = root,
                    .sensitivities = nanVector(N),
                    .status = .non_finite,
                };
            }
            var right_hand_side: [N]f64 = undefined;
            for (parameter_derivatives, 0..) |value, index| {
                right_hand_side[index] = -value;
            }
            const sensitivities = solveLinearSystem(
                N,
                jacobian,
                right_hand_side,
                self.solver.pivot_tolerance,
            ) orelse return .{
                .root = root,
                .sensitivities = nanVector(N),
                .status = .singular_jacobian,
            };
            if (!allFiniteVector(N, sensitivities)) {
                return .{
                    .root = root,
                    .sensitivities = nanVector(N),
                    .status = .non_finite,
                };
            }
            return .{
                .root = root,
                .sensitivities = sensitivities,
                .status = .converged,
            };
        }
    };
}

fn compileSensitivity(
    comptime N: usize,
    comptime max_iterations: usize,
    comptime solver: NewtonSolver(N, max_iterations),
    comptime parameter: anytype,
) NewtonSensitivitySolver(N, max_iterations) {
    const name = @tagName(parameter);
    inline for (solver.unknowns) |unknown| {
        if (std.mem.eql(u8, name, unknown)) {
            @compileError("Bombelli Newton sensitivity parameter must not be one of the solved unknowns");
        }
    }
    var derivatives: [N]ast.Expr = undefined;
    inline for (0..N) |row| {
        derivatives[row] = differentiation.differentiate(
            multi.vectorElement(N, solver.residuals, row),
            name,
        ).simplify();
    }
    return .{
        .solver = solver,
        .parameter_derivatives = multi.vector(N, derivatives),
    };
}

pub fn compileSystem(
    comptime M: usize,
    comptime N: usize,
    comptime problem: anytype,
    comptime options: anytype,
) NewtonSolver(N, options.max_iterations) {
    if (M != N) {
        @compileError("Bombelli Newton solver currently requires a square system");
    }
    const Options = @TypeOf(options);
    options_validation.requireTag(
        options,
        "algorithm",
        "newton",
        "Bombelli generated system compilation requires '.algorithm = .newton'",
    );
    options_validation.requireTag(
        options,
        "jacobian",
        "symbolic",
        "Bombelli Newton solver requires '.jacobian = .symbolic'",
    );
    options_validation.requireField(
        Options,
        "tolerance",
        "Bombelli Newton solver options require '.tolerance'",
    );
    const tolerance: f64 = @floatCast(options.tolerance);
    if (!std.math.isFinite(tolerance) or tolerance <= 0.0) {
        @compileError("Bombelli Newton solver tolerance must be positive and finite");
    }
    const pivot_tolerance: f64 = if (@hasField(Options, "pivot_tolerance"))
        @floatCast(options.pivot_tolerance)
    else
        1e-14;
    if (!std.math.isFinite(pivot_tolerance) or pivot_tolerance <= 0.0) {
        @compileError("Bombelli Newton pivot_tolerance must be positive and finite");
    }

    var derivatives: [N][N]ast.Expr = undefined;
    inline for (0..N) |row| {
        const residual = multi.vectorElement(N, problem.residuals, row);
        inline for (0..N) |column| {
            derivatives[row][column] = differentiation.differentiate(
                residual,
                problem.unknowns[column],
            ).simplify();
        }
    }
    return .{
        .residuals = problem.residuals.simplify(),
        .jacobian_program = multi.matrix(N, N, derivatives),
        .unknowns = problem.unknowns,
        .tolerance = tolerance,
        .pivot_tolerance = pivot_tolerance,
    };
}

pub fn solveLinearSystem(
    comptime N: usize,
    matrix_input: [N][N]f64,
    rhs_input: [N]f64,
    pivot_tolerance: f64,
) ?[N]f64 {
    var matrix: [N][N + 1]f64 = undefined;
    var scale: f64 = 0.0;
    for (0..N) |row| {
        for (0..N) |column| {
            matrix[row][column] = matrix_input[row][column];
            scale = @max(scale, @abs(matrix[row][column]));
        }
        matrix[row][N] = rhs_input[row];
    }
    const threshold = pivot_tolerance * @max(1.0, scale);

    for (0..N) |column| {
        var pivot_row = column;
        var pivot_magnitude = @abs(matrix[column][column]);
        for (column + 1..N) |row| {
            const magnitude = @abs(matrix[row][column]);
            if (magnitude > pivot_magnitude) {
                pivot_magnitude = magnitude;
                pivot_row = row;
            }
        }
        if (!std.math.isFinite(pivot_magnitude) or
            pivot_magnitude <= threshold)
        {
            return null;
        }
        if (pivot_row != column) {
            const temporary = matrix[column];
            matrix[column] = matrix[pivot_row];
            matrix[pivot_row] = temporary;
        }
        for (column + 1..N) |row| {
            const factor = matrix[row][column] / matrix[column][column];
            matrix[row][column] = 0.0;
            for (column + 1..N + 1) |entry| {
                matrix[row][entry] -= factor * matrix[column][entry];
            }
        }
    }

    var solution: [N]f64 = undefined;
    var reverse = N;
    while (reverse != 0) {
        reverse -= 1;
        var value = matrix[reverse][N];
        for (reverse + 1..N) |column| {
            value -= matrix[reverse][column] * solution[column];
        }
        solution[reverse] = value / matrix[reverse][reverse];
    }
    return solution;
}

fn result(
    comptime N: usize,
    values: [N]f64,
    residual: [N]f64,
    iterations: usize,
    residual_norm: f64,
    step_norm: f64,
    status: NewtonStatus,
) NewtonResult(N) {
    return .{
        .values = values,
        .residual = residual,
        .iterations = iterations,
        .residual_norm = residual_norm,
        .step_norm = step_norm,
        .status = status,
    };
}

inline fn initialValues(
    comptime N: usize,
    comptime unknowns: [N][]const u8,
    inputs: anytype,
) [N]f64 {
    const Inputs = @TypeOf(inputs);
    if (@typeInfo(Inputs) != .@"struct" or !@hasField(Inputs, "initial")) {
        @compileError("Bombelli Newton eval input requires '.initial'");
    }
    const initial = inputs.initial;
    const Initial = @TypeOf(initial);
    if (@typeInfo(Initial) != .@"struct") {
        @compileError("Bombelli Newton '.initial' must be a struct of unknown values");
    }
    comptime {
        field_check: for (@typeInfo(Initial).@"struct".fields) |field| {
            for (unknowns) |name| {
                if (std.mem.eql(u8, field.name, name)) continue :field_check;
            }
            @compileError(std.fmt.comptimePrint(
                "Bombelli Newton initial point field '.{s}' does not name an unknown",
                .{field.name},
            ));
        }
    }
    var values: [N]f64 = undefined;
    inline for (unknowns, 0..) |name, index| {
        if (!@hasField(Initial, name)) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli Newton initial point is missing the field '.{s}'",
                .{name},
            ));
        }
        values[index] = numericValue(@field(initial, name), name);
    }
    return values;
}

inline fn numericValue(value: anytype, comptime name: []const u8) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli Newton value '.{s}' must be numeric",
            .{name},
        )),
    };
}

fn infinityNorm(comptime N: usize, values: [N]f64) f64 {
    var norm: f64 = 0.0;
    for (values) |value| norm = @max(norm, @abs(value));
    return norm;
}

fn allFiniteVector(comptime N: usize, values: [N]f64) bool {
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

fn allFiniteMatrix(comptime N: usize, values: [N][N]f64) bool {
    for (values) |row| {
        if (!allFiniteVector(N, row)) return false;
    }
    return true;
}

fn nanVector(comptime N: usize) [N]f64 {
    return [_]f64{std.math.nan(f64)} ** N;
}
