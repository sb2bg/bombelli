//! Symbolic residual-row models for fitting runtime observation slices.
//!
//! A residual-row model is compiled once from a small fixed expression
//! program. At runtime the program is evaluated for each observation without
//! expanding the dataset into the compile-time expression graph.

const std = @import("std");
const ast = @import("expression.zig");
const linearization = @import("internal/model/linearization.zig");
const program = @import("internal/model/program.zig");
const row_least_squares = @import("internal/optimize/row_least_squares.zig");

/// Resolves the model type produced by a residual tuple and option struct.
pub fn ResidualModelType(
    comptime Sources: type,
    comptime Options: type,
) type {
    validateOptions(Options);
    if (!@hasField(Options, "variables")) {
        @compileError("Bombelli residualModel options require '.variables'");
    }
    if (!@hasField(Options, "data")) {
        @compileError("Bombelli residualModel options require '.data'");
    }
    return ResidualModel(
        ast.tupleLength(Sources),
        ast.tupleLength(@FieldType(Options, "variables")),
        ast.tupleLength(@FieldType(Options, "data")),
        @FieldType(Options, "variables"),
    );
}

/// A fixed residual kernel with fixed parameter and observation-data schemas.
pub fn ResidualModel(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
    comptime Variables: type,
) type {
    if (R == 0) {
        @compileError("Bombelli residualModel requires at least one residual");
    }
    if (N == 0) {
        @compileError("Bombelli residualModel requires at least one variable");
    }
    if (P == 0) {
        @compileError("Bombelli residualModel requires at least one data field");
    }

    return struct {
        residuals: ast.ExprVector(R),
        variable_tags: Variables,
        variables: [N][]const u8,
        data: [P][]const u8,

        pub const residual_count = R;
        pub const variable_count = N;
        pub const data_count = P;
        const Self = @This();

        /// Extracts one symbolic residual from the per-observation block.
        pub fn at(comptime self: Self, comptime index: usize) ast.Expr {
            if (index >= R) {
                @compileError("Bombelli residualModel residual index is out of bounds");
            }
            return self.residuals.at(index);
        }

        /// Evaluates one residual block from a flat struct containing the
        /// declared variables and data fields.
        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) [R]f64 {
            return program.evaluate(
                R,
                self.residuals,
                self.variables[0..] ++ self.data[0..],
                inputs,
                "residualModel eval",
            );
        }

        /// Evaluates one residual block into caller-owned storage.
        pub inline fn evalInto(
            comptime self: Self,
            output: *[R]f64,
            inputs: anytype,
        ) void {
            program.evaluateInto(
                R,
                self.residuals,
                self.variables[0..] ++ self.data[0..],
                output,
                inputs,
                "residualModel eval",
            );
        }

        /// Builds the symbolic per-observation Jacobian.
        pub fn jacobian(
            comptime self: Self,
        ) ast.ExprMatrix(R, N) {
            return program.jacobian(R, N, self.residuals, self.variable_tags);
        }

        /// Compiles residuals and first derivatives into one shared DAG.
        pub fn linearize(
            comptime self: Self,
        ) linearization.Program(R, N) {
            return program.linearize(R, N, self.residuals, self.variable_tags);
        }

        /// Evaluates one residual block and Jacobian in one shared DAG pass.
        pub inline fn valueAndJacobian(
            comptime self: Self,
            inputs: anytype,
        ) linearization.Result(R, N, f64) {
            return program.valueAndJacobian(
                R,
                N,
                self.residuals,
                self.variable_tags,
                self.variables[0..] ++ self.data[0..],
                inputs,
                "residualModel valueAndJacobian",
            );
        }

        /// Interprets each runtime observation as one residual block.
        pub fn leastSquares(
            comptime self: Self,
        ) row_least_squares.Problem(R, N, P) {
            return row_least_squares.makeProblem(R, N, P, self);
        }

        /// Emits the per-observation residual evaluator as Zig or C source.
        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            return self.residuals.emit(options);
        }

        /// Measures the residual block's shared expression DAG.
        pub fn metrics(
            comptime self: Self,
        ) @import("internal/core/metrics.zig").Metrics {
            return self.residuals.metrics();
        }
    };
}

/// Constructs a residual-row model from a non-empty tuple of expressions.
pub fn make(
    comptime sources: anytype,
    comptime options: anytype,
) ResidualModelType(@TypeOf(sources), @TypeOf(options)) {
    const R = ast.tupleLength(@TypeOf(sources));
    const N = ast.tupleLength(@TypeOf(options.variables));
    const P = ast.tupleLength(@TypeOf(options.data));
    if (R == 0) {
        @compileError("Bombelli residualModel requires at least one residual");
    }
    if (N == 0) {
        @compileError("Bombelli residualModel requires at least one variable");
    }
    if (P == 0) {
        @compileError("Bombelli residualModel requires at least one data field");
    }

    var variable_names: [N][]const u8 = undefined;
    inline for (options.variables, 0..) |variable, index| {
        variable_names[index] = @tagName(variable);
        validateReserved(variable_names[index]);
        inline for (0..index) |previous| {
            if (std.mem.eql(
                u8,
                variable_names[previous],
                variable_names[index],
            )) {
                @compileError("Bombelli residualModel variables must be unique");
            }
        }
    }

    var data_names: [P][]const u8 = undefined;
    inline for (options.data, 0..) |field, index| {
        data_names[index] = @tagName(field);
        validateReserved(data_names[index]);
        inline for (variable_names) |variable| {
            if (std.mem.eql(u8, variable, data_names[index])) {
                @compileError("Bombelli residualModel variables and data fields must be disjoint");
            }
        }
        inline for (0..index) |previous| {
            if (std.mem.eql(u8, data_names[previous], data_names[index])) {
                @compileError("Bombelli residualModel data fields must be unique");
            }
        }
    }

    const residuals = comptime program.parseVector(R, sources);
    comptime validateSymbols(
        R,
        N,
        P,
        residuals,
        variable_names,
        data_names,
    );
    return .{
        .residuals = residuals,
        .variable_tags = options.variables,
        .variables = variable_names,
        .data = data_names,
    };
}

fn validateOptions(comptime Options: type) void {
    const info = @typeInfo(Options);
    if (info != .@"struct") {
        @compileError("Bombelli residualModel options must be a struct");
    }
    for (info.@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "variables") and
            !std.mem.eql(u8, field.name, "data"))
        {
            @compileError(std.fmt.comptimePrint(
                "Bombelli residualModel option '.{s}' is not recognized",
                .{field.name},
            ));
        }
    }
}

fn validateReserved(comptime name: []const u8) void {
    if (std.mem.eql(u8, name, "initial") or
        std.mem.eql(u8, name, "observations") or
        ast.Constant.fromName(name) != null)
    {
        @compileError(std.fmt.comptimePrint(
            "Bombelli residualModel name '.{s}' is reserved by the runtime solver",
            .{name},
        ));
    }
}

fn validateSymbols(
    comptime R: usize,
    comptime N: usize,
    comptime P: usize,
    comptime residuals: ast.ExprVector(R),
    comptime variables: [N][]const u8,
    comptime data: [P][]const u8,
) void {
    program.validateSymbols(
        residuals,
        &variables,
        &data,
        "Bombelli residualModel symbol '{s}' is neither a variable nor a data field",
    );
}
