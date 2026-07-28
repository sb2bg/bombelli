//! Numerical verification helpers plus implementation introspection used by
//! Bombelli's own tests and downstream package tests.

const std = @import("std");
const ast = @import("expression.zig");
const evaluation = @import("internal/runtime/evaluation.zig");

pub const Builder = @import("internal/core/builder.zig").Builder;
pub const gaussLegendreTable =
    @import("internal/integrate/gauss_legendre.zig").table;
pub const batchVectorLength =
    @import("internal/runtime/evaluation.zig").batch_vector_length;

/// The relative perturbation used by `checkJacobian` unless overridden.
///
/// A second-order central difference balances truncation and roundoff near
/// the cube root of machine epsilon.
pub const defaultJacobianRelativeStep: f64 = 6.055454452393343e-6;

/// Numerical and symbolic values plus the comparison diagnostics for one
/// Jacobian entry.
pub const JacobianCheckEntry = struct {
    row: usize,
    column: usize,
    variable: []const u8,
    analytic: f64,
    numerical: f64,
    step: f64,
    absolute_error: f64,
    relative_error: f64,
    allowed_error: f64,
    normalized_error: f64,
    analytic_finite: bool,
    numerical_finite: bool,
    passed: bool,
};

/// Returns the fixed-size result type for an `M`-by-`N` Jacobian check.
pub fn JacobianCheckResult(comptime M: usize, comptime N: usize) type {
    return struct {
        analytic: [M][N]f64,
        numerical: [M][N]f64,
        steps: [N]f64,
        entries: [M][N]JacobianCheckEntry,
        mismatch_count: usize,
        first_mismatch: ?JacobianCheckEntry,
        worst_entry: ?JacobianCheckEntry,
        max_absolute_error: f64,
        max_relative_error: f64,
        function_evaluations: usize,
        jacobian_evaluations: usize,

        const Self = @This();

        /// Returns true when every entry is finite and within tolerance.
        pub fn passed(self: Self) bool {
            return self.mismatch_count == 0;
        }
    };
}

/// Compares a symbolic Jacobian with second-order central differences.
///
/// Models contribute their declared variable order automatically:
///
/// ```zig
/// const result = bombelli.testing.checkJacobian(model, point, .{});
/// ```
///
/// A bare `ExprVector` declares the differentiation coordinates in `options`:
///
/// ```zig
/// const result = bombelli.testing.checkJacobian(outputs, point, .{
///     .variables = .{ .x, .y },
/// });
/// ```
///
/// Supported options are:
///
/// - `variables`: required for `ExprVector`; optional and verified for models.
/// - `relative_step`: scaled by `max(1, abs(variable))`.
/// - `absolute_step`: a lower bound for the perturbation.
/// - `absolute_tolerance` and `relative_tolerance`: an entry passes when
///   `abs(analytic - numerical) <= absolute + relative * max(abs(values))`.
///
/// All storage is fixed-size and allocation-free. Non-finite analytic or
/// numerical entries always fail and remain available in the diagnostics.
pub fn checkJacobian(
    comptime program: anytype,
    point: anytype,
    comptime options: anytype,
) JacobianCheckResult(
    outputCount(@TypeOf(program)),
    variableCount(program, options),
) {
    const Program = @TypeOf(program);
    const M = comptime outputCount(Program);
    const N = comptime variableCount(program, options);
    comptime validateProgramAndOptions(program, options);

    const names = comptime variableNames(program, options);
    const outputs = comptime if (isModelType(Program))
        program.outputs
    else
        program;
    const jacobian = comptime if (isModelType(Program))
        program.jacobian()
    else
        program.jacobian(options.variables);

    var variable_values: [N]f64 = undefined;
    inline for (names, 0..) |name, column| {
        variable_values[column] = pointValue(point, name);
    }

    const analytic = evaluation.evaluateMatrixWithVariables(
        M,
        N,
        N,
        jacobian,
        point,
        names,
        variable_values,
    );

    const relative_step = numericOption(
        options,
        "relative_step",
        defaultJacobianRelativeStep,
    );
    const absolute_step = numericOption(options, "absolute_step", 0.0);
    const absolute_tolerance = numericOption(
        options,
        "absolute_tolerance",
        1e-8,
    );
    const relative_tolerance = numericOption(
        options,
        "relative_tolerance",
        1e-6,
    );

    var numerical: [M][N]f64 = undefined;
    var steps: [N]f64 = undefined;
    inline for (0..N) |column| {
        const perturbation = makePerturbation(
            variable_values[column],
            relative_step,
            absolute_step,
        );
        steps[column] = perturbation.step;

        var lower_variables = variable_values;
        lower_variables[column] = perturbation.lower;
        const lower = evaluation.evaluateVectorWithVariables(
            M,
            N,
            outputs,
            point,
            names,
            lower_variables,
        );

        var upper_variables = variable_values;
        upper_variables[column] = perturbation.upper;
        const upper = evaluation.evaluateVectorWithVariables(
            M,
            N,
            outputs,
            point,
            names,
            upper_variables,
        );

        const denominator = perturbation.upper - perturbation.lower;
        inline for (0..M) |row| {
            numerical[row][column] =
                (upper[row] - lower[row]) / denominator;
        }
    }

    var entries: [M][N]JacobianCheckEntry = undefined;
    var mismatch_count: usize = 0;
    var first_mismatch: ?JacobianCheckEntry = null;
    var worst_entry: ?JacobianCheckEntry = null;
    var worst_score: f64 = -1.0;
    var max_absolute_error: f64 = 0.0;
    var max_relative_error: f64 = 0.0;

    inline for (names, 0..) |name, column| {
        inline for (0..M) |row| {
            const entry = compareEntry(
                row,
                column,
                name,
                analytic[row][column],
                numerical[row][column],
                steps[column],
                absolute_tolerance,
                relative_tolerance,
            );
            entries[row][column] = entry;
            if (!entry.passed) {
                mismatch_count += 1;
                if (first_mismatch == null) first_mismatch = entry;
            }

            const absolute_error = finiteOrInfinity(entry.absolute_error);
            const relative_error = finiteOrInfinity(entry.relative_error);
            max_absolute_error = @max(max_absolute_error, absolute_error);
            max_relative_error = @max(max_relative_error, relative_error);

            const score = finiteOrInfinity(entry.normalized_error);
            if (worst_entry == null or score > worst_score) {
                worst_entry = entry;
                worst_score = score;
            }
        }
    }

    return .{
        .analytic = analytic,
        .numerical = numerical,
        .steps = steps,
        .entries = entries,
        .mismatch_count = mismatch_count,
        .first_mismatch = first_mismatch,
        .worst_entry = worst_entry,
        .max_absolute_error = max_absolute_error,
        .max_relative_error = max_relative_error,
        .function_evaluations = 2 * N,
        .jacobian_evaluations = 1,
    };
}

fn isModelType(comptime Program: type) bool {
    if (comptime @typeInfo(Program) != .@"struct") return false;
    return @hasDecl(Program, "output_count") and
        @hasDecl(Program, "variable_count") and
        @hasField(Program, "outputs") and
        @hasField(Program, "variables");
}

fn outputCount(comptime Program: type) usize {
    if (comptime isModelType(Program)) return Program.output_count;
    if (comptime @typeInfo(Program) == .@"struct" and
        @hasField(Program, "roots"))
    {
        return switch (@typeInfo(@FieldType(Program, "roots"))) {
            .array => |array| array.len,
            else => @compileError(
                "Bombelli checkJacobian expects a Model or ExprVector program",
            ),
        };
    }
    @compileError("Bombelli checkJacobian expects a Model or ExprVector program");
}

fn variableCount(comptime program: anytype, comptime options: anytype) usize {
    const Options = @TypeOf(options);
    if (comptime @typeInfo(Options) != .@"struct") {
        @compileError("Bombelli checkJacobian options must be a struct");
    }
    if (comptime isModelType(@TypeOf(program))) {
        return @TypeOf(program).variable_count;
    }
    if (comptime !@hasField(Options, "variables")) {
        @compileError(
            "Bombelli checkJacobian requires '.variables' for an ExprVector",
        );
    }
    const count = ast.tupleLength(@TypeOf(options.variables));
    if (count == 0) {
        @compileError("Bombelli checkJacobian requires at least one variable");
    }
    return count;
}

fn variableNames(
    comptime program: anytype,
    comptime options: anytype,
) [variableCount(program, options)][]const u8 {
    const N = comptime variableCount(program, options);
    if (comptime isModelType(@TypeOf(program))) return program.variables;

    var names: [N][]const u8 = undefined;
    inline for (options.variables, 0..) |variable, index| {
        names[index] = @tagName(variable);
    }
    return names;
}

fn validateProgramAndOptions(
    comptime program: anytype,
    comptime options: anytype,
) void {
    const Program = @TypeOf(program);
    const Options = @TypeOf(options);
    const M = comptime outputCount(Program);
    const N = comptime variableCount(program, options);
    if (M == 0) {
        @compileError("Bombelli checkJacobian requires at least one output");
    }

    if (comptime !isModelType(Program) and
        @TypeOf(program) != ast.ExprVector(M))
    {
        @compileError("Bombelli checkJacobian expects a Model or ExprVector program");
    }

    for (@typeInfo(Options).@"struct".fields) |field| {
        const known = std.mem.eql(u8, field.name, "variables") or
            std.mem.eql(u8, field.name, "relative_step") or
            std.mem.eql(u8, field.name, "absolute_step") or
            std.mem.eql(u8, field.name, "absolute_tolerance") or
            std.mem.eql(u8, field.name, "relative_tolerance");
        if (!known) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli checkJacobian option '.{s}' is not recognized",
                .{field.name},
            ));
        }
    }

    const names = variableNames(program, options);
    inline for (names, 0..) |name, index| {
        inline for (0..index) |previous| {
            if (std.mem.eql(u8, names[previous], name)) {
                @compileError(
                    "Bombelli checkJacobian variables must be unique",
                );
            }
        }
    }

    if (comptime isModelType(Program) and
        @hasField(Options, "variables"))
    {
        const supplied = comptime namesFromTags(options.variables);
        if (supplied.len != N) {
            @compileError(
                "Bombelli checkJacobian variables do not match the model",
            );
        }
        inline for (supplied, 0..) |name, index| {
            if (!std.mem.eql(u8, name, program.variables[index])) {
                @compileError(
                    "Bombelli checkJacobian variables do not match the model",
                );
            }
        }
    }

    const relative_step = numericOption(
        options,
        "relative_step",
        defaultJacobianRelativeStep,
    );
    const absolute_step = numericOption(options, "absolute_step", 0.0);
    const absolute_tolerance = numericOption(
        options,
        "absolute_tolerance",
        1e-8,
    );
    const relative_tolerance = numericOption(
        options,
        "relative_tolerance",
        1e-6,
    );
    if (!std.math.isFinite(relative_step) or relative_step < 0.0) {
        @compileError(
            "Bombelli checkJacobian relative_step must be finite and nonnegative",
        );
    }
    if (!std.math.isFinite(absolute_step) or absolute_step < 0.0) {
        @compileError(
            "Bombelli checkJacobian absolute_step must be finite and nonnegative",
        );
    }
    if (relative_step == 0.0 and absolute_step == 0.0) {
        @compileError(
            "Bombelli checkJacobian requires a positive relative_step or absolute_step",
        );
    }
    if (!std.math.isFinite(absolute_tolerance) or
        absolute_tolerance < 0.0)
    {
        @compileError(
            "Bombelli checkJacobian absolute_tolerance must be finite and nonnegative",
        );
    }
    if (!std.math.isFinite(relative_tolerance) or
        relative_tolerance < 0.0)
    {
        @compileError(
            "Bombelli checkJacobian relative_tolerance must be finite and nonnegative",
        );
    }
}

fn namesFromTags(
    comptime variables: anytype,
) [ast.tupleLength(@TypeOf(variables))][]const u8 {
    const N = ast.tupleLength(@TypeOf(variables));
    var names: [N][]const u8 = undefined;
    inline for (variables, 0..) |variable, index| {
        names[index] = @tagName(variable);
    }
    return names;
}

fn numericOption(
    comptime options: anytype,
    comptime name: []const u8,
    comptime default: f64,
) f64 {
    if (comptime !@hasField(@TypeOf(options), name)) return default;
    return numericValue(@field(options, name), "option '." ++ name ++ "'");
}

fn pointValue(point: anytype, comptime name: []const u8) f64 {
    const Point = @TypeOf(point);
    if (comptime @typeInfo(Point) != .@"struct") {
        @compileError("Bombelli checkJacobian point must be a struct");
    }
    if (comptime !@hasField(Point, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli checkJacobian point is missing variable '.{s}'",
            .{name},
        ));
    }
    return numericValue(
        @field(point, name),
        "point field '." ++ name ++ "'",
    );
}

fn numericValue(value: anytype, comptime description: []const u8) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli checkJacobian {s} must be an integer or floating-point value",
            .{description},
        )),
    };
}

const Perturbation = struct {
    lower: f64,
    upper: f64,
    step: f64,
};

fn makePerturbation(
    value: f64,
    relative_step: f64,
    absolute_step: f64,
) Perturbation {
    const scale = @max(1.0, @abs(value));
    const requested = @max(absolute_step, relative_step * scale);
    var lower = value - requested;
    var upper = value + requested;

    if (lower == value) {
        lower = std.math.nextAfter(f64, value, -std.math.inf(f64));
    }
    if (upper == value) {
        upper = std.math.nextAfter(f64, value, std.math.inf(f64));
    }
    return .{
        .lower = lower,
        .upper = upper,
        .step = @abs(upper - lower) / 2.0,
    };
}

fn compareEntry(
    row: usize,
    column: usize,
    variable: []const u8,
    analytic: f64,
    numerical: f64,
    step: f64,
    absolute_tolerance: f64,
    relative_tolerance: f64,
) JacobianCheckEntry {
    const analytic_finite = std.math.isFinite(analytic);
    const numerical_finite = std.math.isFinite(numerical);
    const absolute_error = @abs(analytic - numerical);
    const scale = @max(@abs(analytic), @abs(numerical));
    const relative_error = if (absolute_error == 0.0)
        0.0
    else if (scale == 0.0)
        std.math.inf(f64)
    else
        absolute_error / scale;
    const allowed_error =
        absolute_tolerance + relative_tolerance * scale;
    const normalized_error = if (absolute_error == 0.0)
        0.0
    else if (allowed_error == 0.0)
        std.math.inf(f64)
    else
        absolute_error / allowed_error;
    return .{
        .row = row,
        .column = column,
        .variable = variable,
        .analytic = analytic,
        .numerical = numerical,
        .step = step,
        .absolute_error = absolute_error,
        .relative_error = relative_error,
        .allowed_error = allowed_error,
        .normalized_error = normalized_error,
        .analytic_finite = analytic_finite,
        .numerical_finite = numerical_finite,
        .passed = analytic_finite and numerical_finite and
            absolute_error <= allowed_error,
    };
}

fn finiteOrInfinity(value: f64) f64 {
    return if (std.math.isFinite(value)) value else std.math.inf(f64);
}
