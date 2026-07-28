//! Typed fixed-size mathematical models.
//!
//! A model gives a shared expression program an explicit ordered set of
//! variables.  Any other free symbols remain ordinary runtime parameters.
//! The distinction lets downstream algorithms build Jacobians and solve for
//! variables without inventing positional input conventions.

const std = @import("std");
const ast = @import("expression.zig");
const domain = @import("internal/core/domain.zig");
const evaluation = @import("internal/runtime/evaluation.zig");
const limits = @import("internal/core/limits.zig");
const multi = @import("internal/transform/multi.zig");
const parser = @import("internal/parse/parser.zig");

/// Resolves the model type produced by a source tuple and option struct.
pub fn ModelType(comptime Sources: type, comptime Options: type) type {
    if (!@hasField(Options, "variables")) {
        @compileError("Bombelli model options require '.variables'");
    }
    return Model(
        ast.tupleLength(Sources),
        ast.tupleLength(@FieldType(Options, "variables")),
        if (@hasField(Options, "inputs"))
            ast.tupleLength(@FieldType(Options, "inputs"))
        else
            0,
        @FieldType(Options, "variables"),
    );
}

/// Returns a fixed-output, fixed-variable model type.
pub fn Model(
    comptime M: usize,
    comptime N: usize,
    comptime P: usize,
    comptime Variables: type,
) type {
    if (M == 0) @compileError("Bombelli model requires at least one output");
    if (N == 0) @compileError("Bombelli model requires at least one variable");

    return struct {
        outputs: ast.ExprVector(M),
        variable_tags: Variables,
        variables: [N][]const u8,
        /// Ordered runtime data inputs when `.inputs` was declared.
        ///
        /// An empty slice means inputs are inferred from free symbols.
        inputs: [P][]const u8,
        explicit_inputs: bool,
        domain: domain.Domain,

        pub const output_count = M;
        pub const variable_count = N;
        const Self = @This();

        /// Extracts one symbolic model output.
        pub fn at(comptime self: Self, comptime index: usize) ast.Expr {
            if (index >= M) {
                @compileError("Bombelli model output index is out of bounds");
            }
            return self.outputs.at(index);
        }

        /// Evaluates every output while retaining the model's declared input
        /// contract by accepting declared variables even when simplification
        /// has eliminated them from the output DAG.
        pub inline fn eval(comptime self: Self, inputs: anytype) [M]f64 {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{self.outputs.nodes},
                self.variables[0..] ++ self.inputs[0..],
                &.{},
                "model eval",
            );
            return self.outputs.eval(inputs);
        }

        /// Evaluates every output into caller-owned fixed-size storage.
        pub inline fn evalInto(
            comptime self: Self,
            output: *[M]f64,
            inputs: anytype,
        ) void {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{self.outputs.nodes},
                self.variables[0..] ++ self.inputs[0..],
                &.{},
                "model eval",
            );
            self.outputs.evalInto(output, inputs);
        }

        /// Builds the symbolic Jacobian with columns in declared variable
        /// order.
        pub fn jacobian(comptime self: Self) ast.ExprMatrix(M, N) {
            return self.outputs.jacobian(self.variable_tags);
        }

        /// Differentiates every output with respect to one named symbol.
        pub fn diff(comptime self: Self, comptime symbol: anytype) Self {
            return .{
                .outputs = self.outputs.diff(symbol),
                .variable_tags = self.variable_tags,
                .variables = self.variables,
                .inputs = self.inputs,
                .explicit_inputs = self.explicit_inputs,
                .domain = self.domain,
            };
        }

        /// Simplifies all outputs while retaining variable metadata.
        pub fn simplify(comptime self: Self) Self {
            return .{
                .outputs = self.outputs.simplify(),
                .variable_tags = self.variable_tags,
                .variables = self.variables,
                .inputs = self.inputs,
                .explicit_inputs = self.explicit_inputs,
                .domain = self.domain,
            };
        }

        /// Applies simultaneous symbolic substitution to every output.
        pub fn substitute(
            comptime self: Self,
            comptime replacements: anytype,
        ) Self {
            comptime rejectVariableReplacements(
                N,
                self.variables,
                @TypeOf(replacements),
            );
            return .{
                .outputs = self.outputs.substitute(replacements),
                .variable_tags = self.variable_tags,
                .variables = self.variables,
                .inputs = self.inputs,
                .explicit_inputs = self.explicit_inputs,
                .domain = self.domain,
            };
        }

        /// Interprets this model's outputs as residuals in a nonlinear
        /// least-squares problem.
        pub fn leastSquares(
            comptime self: Self,
        ) @import("internal/optimize/least_squares.zig").LeastSquaresProblem(
            M,
            N,
            P,
        ) {
            return @import("internal/optimize/least_squares.zig").makeProblem(
                M,
                N,
                P,
                self,
            );
        }

        /// Emits the model evaluator as a standalone Zig or C callable.
        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            return self.outputs.emit(options);
        }

        /// Measures the shared output DAG.
        pub fn metrics(
            comptime self: Self,
        ) @import("internal/core/metrics.zig").Metrics {
            return self.outputs.metrics();
        }
    };
}

/// Constructs a model from a non-empty tuple of expression strings.
pub fn make(
    comptime sources: anytype,
    comptime options: anytype,
) ModelType(@TypeOf(sources), @TypeOf(options)) {
    const M = ast.tupleLength(@TypeOf(sources));
    const N = ast.tupleLength(@TypeOf(options.variables));
    if (M == 0) @compileError("Bombelli model requires at least one output");
    if (N == 0) @compileError("Bombelli model requires at least one variable");

    var names: [N][]const u8 = undefined;
    inline for (options.variables, 0..) |variable, index| {
        names[index] = @tagName(variable);
        inline for (0..index) |previous| {
            if (std.mem.eql(u8, names[previous], names[index])) {
                @compileError("Bombelli model variables must be unique");
            }
        }
    }
    var expressions: [M]ast.Expr = undefined;
    inline for (sources, 0..) |source, index| {
        expressions[index] = parser.parse(source);
    }
    const outputs = comptime multi.vector(M, expressions);
    const explicit_inputs = @hasField(@TypeOf(options), "inputs");
    const P = if (explicit_inputs)
        ast.tupleLength(@TypeOf(options.inputs))
    else
        0;
    const inputs = comptime inputNames(P, options, &names);
    comptime validateDeclaredSymbols(
        M,
        outputs,
        &names,
        &inputs,
        explicit_inputs,
    );
    return .{
        .outputs = outputs,
        .variable_tags = options.variables,
        .variables = names,
        .inputs = inputs,
        .explicit_inputs = explicit_inputs,
        .domain = if (@hasField(@TypeOf(options), "domain"))
            @as(domain.Domain, options.domain)
        else
            .real,
    };
}

fn inputNames(
    comptime P: usize,
    comptime options: anytype,
    comptime variables: []const []const u8,
) [P][]const u8 {
    if (!@hasField(@TypeOf(options), "inputs")) return .{};
    var names: [P][]const u8 = undefined;
    inline for (options.inputs, 0..) |input, index| {
        names[index] = @tagName(input);
        if (std.mem.eql(u8, names[index], "initial")) {
            @compileError("Bombelli model input '.initial' is reserved by compiled solvers");
        }
        for (variables) |variable| {
            if (std.mem.eql(u8, names[index], variable)) {
                @compileError("Bombelli model inputs and variables must be disjoint");
            }
        }
        inline for (0..index) |previous| {
            if (std.mem.eql(u8, names[previous], names[index])) {
                @compileError("Bombelli model inputs must be unique");
            }
        }
    }
    return names;
}

fn validateDeclaredSymbols(
    comptime M: usize,
    comptime outputs: ast.ExprVector(M),
    comptime variables: []const []const u8,
    comptime inputs: []const []const u8,
    comptime explicit_inputs: bool,
) void {
    if (!explicit_inputs) return;
    for (outputs.nodes) |node| {
        if (node != .symbol) continue;
        const symbol = node.symbol;
        var declared = false;
        for (variables) |variable| {
            if (std.mem.eql(u8, symbol, variable)) declared = true;
        }
        for (inputs) |input| {
            if (std.mem.eql(u8, symbol, input)) declared = true;
        }
        if (!declared) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli model symbol '{s}' is neither a declared variable nor input",
                .{symbol},
            ));
        }
    }
}

fn rejectVariableReplacements(
    comptime N: usize,
    comptime variables: [N][]const u8,
    comptime Replacements: type,
) void {
    const info = @typeInfo(Replacements);
    if (info != .@"struct") {
        @compileError("Bombelli model substitution expects a struct of replacements");
    }
    for (info.@"struct".fields) |field| {
        for (variables) |variable| {
            if (std.mem.eql(u8, field.name, variable)) {
                @compileError(
                    "Bombelli model substitution cannot replace a declared variable; substitute on model.outputs to intentionally change coordinates",
                );
            }
        }
    }
}
