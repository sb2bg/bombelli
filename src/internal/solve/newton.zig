const std = @import("std");
const ast = @import("../../expression.zig");
const differentiation = @import("../transform/differentiation.zig");
const domain = @import("../core/domain.zig");
const evaluation = @import("../runtime/evaluation.zig");
const limits = @import("../core/limits.zig");
const multi = @import("../transform/multi.zig");
const number = @import("../runtime/number.zig");
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
    return NewtonResultForDomain(.real, N);
}

pub fn NewtonResultForDomain(
    comptime problem_domain: domain.Domain,
    comptime N: usize,
) type {
    const Scalar = domain.Scalar(problem_domain);
    return struct {
        values: [N]Scalar,
        residual: [N]Scalar,
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
    return NewtonSolverForDomain(.real, N, max_iterations);
}

pub fn NewtonSolverForDomain(
    comptime problem_domain: domain.Domain,
    comptime N: usize,
    comptime max_iterations: usize,
) type {
    if (N == 0) @compileError("Bombelli Newton solver requires at least one unknown");
    if (max_iterations == 0) {
        @compileError("Bombelli Newton solver max_iterations must be positive");
    }
    const Scalar = domain.Scalar(problem_domain);
    return struct {
        residuals: ast.ExprVector(N),
        jacobian_program: ast.ExprMatrix(N, N),
        unknowns: [N][]const u8,
        tolerance: f64,
        pivot_tolerance: f64,

        pub const mathematical_domain = problem_domain;
        pub const ScalarType = Scalar;
        pub const maximum_iterations = max_iterations;
        const Self = @This();

        /// Returns a solved value by its declared unknown name.
        pub inline fn value(
            comptime self: Self,
            solve_result: NewtonResultForDomain(problem_domain, N),
            comptime unknown: anytype,
        ) Scalar {
            return solve_result.values[self.unknownIndex(unknown)];
        }

        /// Returns the array index assigned to a declared unknown.
        pub fn unknownIndex(
            comptime self: Self,
            comptime unknown: anytype,
        ) usize {
            const name = @tagName(unknown);
            inline for (self.unknowns, 0..) |candidate, index| {
                if (comptime std.mem.eql(u8, name, candidate)) return index;
            }
            @compileError(std.fmt.comptimePrint(
                "Bombelli Newton unknown '.{s}' is not declared",
                .{name},
            ));
        }

        /// Returns the residual for an equation in declaration order.
        pub inline fn residualAt(
            comptime self: Self,
            solve_result: NewtonResultForDomain(problem_domain, N),
            comptime equation_index: usize,
        ) Scalar {
            _ = self;
            if (equation_index >= N) {
                @compileError("Bombelli Newton residual index is out of bounds");
            }
            return solve_result.residual[equation_index];
        }

        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) NewtonResultForDomain(problem_domain, N) {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{self.residuals.nodes},
                &.{"initial"},
                &self.unknowns,
                "Newton eval",
            );
            var values = initialValues(Scalar, N, self.unknowns, inputs);
            var residual = evaluation.evaluateVectorWithVariablesAs(
                Scalar,
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
                    problem_domain,
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
                    problem_domain,
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
                const jacobian = evaluation.evaluateMatrixWithVariablesAs(
                    Scalar,
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
                        problem_domain,
                        N,
                        values,
                        residual,
                        iteration,
                        residual_norm,
                        step_norm,
                        .non_finite,
                    );
                }
                var right_hand_side: [N]Scalar = undefined;
                for (residual, 0..) |entry, index| {
                    right_hand_side[index] = number.neg(entry);
                }
                const step = solveLinearSystemForScalar(
                    Scalar,
                    N,
                    jacobian,
                    right_hand_side,
                    self.pivot_tolerance,
                ) orelse return result(
                    problem_domain,
                    N,
                    values,
                    residual,
                    iteration,
                    residual_norm,
                    step_norm,
                    .singular_jacobian,
                );
                step_norm = infinityNorm(N, step);
                for (&values, step) |*entry, increment| {
                    entry.* = number.add(entry.*, increment);
                }
                residual = evaluation.evaluateVectorWithVariablesAs(
                    Scalar,
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
                        problem_domain,
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
                        problem_domain,
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
                problem_domain,
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
        ) NewtonSensitivitySolverForDomain(problem_domain, N, max_iterations) {
            return compileSensitivity(
                problem_domain,
                N,
                max_iterations,
                self,
                parameter,
            );
        }

        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(limits.eval_branch.solve);
            if (problem_domain == .complex) {
                @compileError("Bombelli complex Newton source emission is not implemented yet");
            }
            return @import("../codegen/emit.zig").emitNewton(self, options);
        }
    };
}

pub fn SensitivityResult(comptime N: usize) type {
    return SensitivityResultForDomain(.real, N);
}

pub fn SensitivityResultForDomain(
    comptime problem_domain: domain.Domain,
    comptime N: usize,
) type {
    const Scalar = domain.Scalar(problem_domain);
    return struct {
        root: NewtonResultForDomain(problem_domain, N),
        sensitivities: [N]Scalar,
        status: SensitivityStatus,
    };
}

pub fn NewtonSensitivitySolver(
    comptime N: usize,
    comptime max_iterations: usize,
) type {
    return NewtonSensitivitySolverForDomain(.real, N, max_iterations);
}

pub fn NewtonSensitivitySolverForDomain(
    comptime problem_domain: domain.Domain,
    comptime N: usize,
    comptime max_iterations: usize,
) type {
    const Scalar = domain.Scalar(problem_domain);
    return struct {
        solver: NewtonSolverForDomain(problem_domain, N, max_iterations),
        parameter_derivatives: ast.ExprVector(N),

        const Self = @This();

        /// Returns a root value by its declared unknown name.
        pub inline fn value(
            comptime self: Self,
            solve_result: SensitivityResultForDomain(problem_domain, N),
            comptime unknown: anytype,
        ) Scalar {
            return self.solver.value(solve_result.root, unknown);
        }

        /// Returns a root sensitivity by its declared unknown name.
        pub inline fn sensitivity(
            comptime self: Self,
            solve_result: SensitivityResultForDomain(problem_domain, N),
            comptime unknown: anytype,
        ) Scalar {
            return solve_result.sensitivities[
                self.solver.unknownIndex(unknown)
            ];
        }

        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) SensitivityResultForDomain(problem_domain, N) {
            const root = self.solver.eval(inputs);
            if (root.status != .converged) {
                return .{
                    .root = root,
                    .sensitivities = nanVector(Scalar, N),
                    .status = .root_not_converged,
                };
            }
            const jacobian = evaluation.evaluateMatrixWithVariablesAs(
                Scalar,
                N,
                N,
                N,
                self.solver.jacobian_program,
                inputs,
                self.solver.unknowns,
                root.values,
            );
            const parameter_derivatives =
                evaluation.evaluateVectorWithVariablesAs(
                    Scalar,
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
                    .sensitivities = nanVector(Scalar, N),
                    .status = .non_finite,
                };
            }
            var right_hand_side: [N]Scalar = undefined;
            for (parameter_derivatives, 0..) |derivative, index| {
                right_hand_side[index] = number.neg(derivative);
            }
            const sensitivities = solveLinearSystemForScalar(
                Scalar,
                N,
                jacobian,
                right_hand_side,
                self.solver.pivot_tolerance,
            ) orelse return .{
                .root = root,
                .sensitivities = nanVector(Scalar, N),
                .status = .singular_jacobian,
            };
            if (!allFiniteVector(N, sensitivities)) {
                return .{
                    .root = root,
                    .sensitivities = nanVector(Scalar, N),
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
    comptime problem_domain: domain.Domain,
    comptime N: usize,
    comptime max_iterations: usize,
    comptime solver: NewtonSolverForDomain(problem_domain, N, max_iterations),
    comptime parameter: anytype,
) NewtonSensitivitySolverForDomain(problem_domain, N, max_iterations) {
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
) NewtonSolverForDomain(problem.domain, N, options.max_iterations) {
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
    if (problem.domain == .complex) {
        validateHolomorphic(N, problem.residuals);
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

fn validateHolomorphic(
    comptime N: usize,
    comptime residuals: ast.ExprVector(N),
) void {
    inline for (residuals.nodes) |node| {
        switch (node) {
            .abs => @compileError(
                "Bombelli complex Newton requires holomorphic residuals; abs is not holomorphic",
            ),
            .atan2 => @compileError(
                "Bombelli complex Newton requires holomorphic residuals; atan2 is real-only",
            ),
            .hypot => @compileError(
                "Bombelli complex Newton requires holomorphic residuals; hypot is real-only",
            ),
            else => {},
        }
    }
}

pub fn solveLinearSystem(
    comptime N: usize,
    matrix_input: [N][N]f64,
    rhs_input: [N]f64,
    pivot_tolerance: f64,
) ?[N]f64 {
    return solveLinearSystemForScalar(
        f64,
        N,
        matrix_input,
        rhs_input,
        pivot_tolerance,
    );
}

pub fn solveLinearSystemForScalar(
    comptime Scalar: type,
    comptime N: usize,
    matrix_input: [N][N]Scalar,
    rhs_input: [N]Scalar,
    pivot_tolerance: f64,
) ?[N]Scalar {
    var matrix: [N][N + 1]Scalar = undefined;
    var scale: f64 = 0.0;
    for (0..N) |row| {
        for (0..N) |column| {
            matrix[row][column] = matrix_input[row][column];
            scale = @max(scale, number.magnitude(matrix[row][column]));
        }
        matrix[row][N] = rhs_input[row];
    }
    const threshold = pivot_tolerance * @max(1.0, scale);

    for (0..N) |column| {
        var pivot_row = column;
        var pivot_magnitude = number.magnitude(matrix[column][column]);
        for (column + 1..N) |row| {
            const magnitude = number.magnitude(matrix[row][column]);
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
            const factor = number.div(matrix[row][column], matrix[column][column]);
            matrix[row][column] = number.fromReal(Scalar, 0.0);
            for (column + 1..N + 1) |entry| {
                matrix[row][entry] = number.sub(
                    matrix[row][entry],
                    number.mul(factor, matrix[column][entry]),
                );
            }
        }
    }

    var solution: [N]Scalar = undefined;
    var reverse = N;
    while (reverse != 0) {
        reverse -= 1;
        var value = matrix[reverse][N];
        for (reverse + 1..N) |column| {
            value = number.sub(
                value,
                number.mul(matrix[reverse][column], solution[column]),
            );
        }
        solution[reverse] = number.div(value, matrix[reverse][reverse]);
    }
    return solution;
}

fn result(
    comptime problem_domain: domain.Domain,
    comptime N: usize,
    values: [N]domain.Scalar(problem_domain),
    residual: [N]domain.Scalar(problem_domain),
    iterations: usize,
    residual_norm: f64,
    step_norm: f64,
    status: NewtonStatus,
) NewtonResultForDomain(problem_domain, N) {
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
    comptime Scalar: type,
    comptime N: usize,
    comptime unknowns: [N][]const u8,
    inputs: anytype,
) [N]Scalar {
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
    var values: [N]Scalar = undefined;
    inline for (unknowns, 0..) |name, index| {
        if (!@hasField(Initial, name)) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli Newton initial point is missing the field '.{s}'",
                .{name},
            ));
        }
        values[index] = numericValue(Scalar, @field(initial, name), name);
    }
    return values;
}

inline fn numericValue(
    comptime Scalar: type,
    value: anytype,
    comptime name: []const u8,
) Scalar {
    const Value = @TypeOf(value);
    if (comptime number.isComplex(Scalar) and Value == Scalar) return value;
    return switch (@typeInfo(Value)) {
        .int, .comptime_int, .float, .comptime_float => number.fromReal(
            Scalar,
            value,
        ),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli Newton value '.{s}' must be real numeric or match the solver's complex scalar type",
            .{name},
        )),
    };
}

fn infinityNorm(comptime N: usize, values: anytype) f64 {
    _ = N;
    var norm: f64 = 0.0;
    for (values) |value| norm = @max(norm, number.magnitude(value));
    return norm;
}

fn allFiniteVector(comptime N: usize, values: anytype) bool {
    _ = N;
    for (values) |value| {
        if (!number.isFinite(value)) return false;
    }
    return true;
}

fn allFiniteMatrix(comptime N: usize, values: anytype) bool {
    for (values) |row| {
        if (!allFiniteVector(N, row)) return false;
    }
    return true;
}

fn nanVector(comptime Scalar: type, comptime N: usize) [N]Scalar {
    return [_]Scalar{number.nan(Scalar)} ** N;
}
