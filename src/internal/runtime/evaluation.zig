const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../../expression.zig");

pub const BatchInputError = error{
    InputLengthMismatch,
};

pub const BatchOptions = struct {
    /// Zero selects the number of logical CPUs visible to the process.
    max_threads: usize = 0,
    /// Batches at or below this length remain on the calling thread.
    /// Measured against serial evaluation of a polynomial fixture,
    /// spawning costs more than it saves below roughly 65,536 items
    /// (0.65x at 32,768), breaks even through 131,072, then pays: 1.65x
    /// at 262,144 and 2.45x at 524,288. The default sits at the top of
    /// the break-even band so threads are spawned only once they earn it.
    min_batch_len: usize = 131_072,
    /// Target chunk size used to cap the number of worker threads.
    min_items_per_thread: usize = 65_536,
};

pub const batch_vector_length = std.simd.suggestVectorLength(f64) orelse 1;

pub inline fn evaluate(comptime expression: ast.Expr, values: anytype) f64 {
    return evaluateAs(f64, expression, values);
}

pub inline fn evaluateAs(
    comptime T: type,
    comptime expression: ast.Expr,
    values: anytype,
) T {
    validateEvaluationScalar(T);
    const results = evaluateNodesAs(T, expression.nodes, values);
    return results[@intCast(expression.root)];
}

/// Rejects input struct fields that name neither a symbol in any of the
/// node stores nor a reserved field. Fields naming a bound variable get a
/// dedicated diagnostic because they are the likeliest confusion.
/// Plain expression eval stays permissive: transformations such as
/// differentiation legitimately eliminate symbols, and evaluating the
/// result at a full point must keep working. Structured callables with
/// explicit input contracts (quadrature, compiled integrals, Newton)
/// validate strictly.
pub fn validateInputFields(
    comptime Values: type,
    comptime node_sets: []const []const ast.Node,
    comptime reserved: []const []const u8,
    comptime bound: []const []const u8,
    comptime description: []const u8,
) void {
    if (@typeInfo(Values) != .@"struct") return;
    for (@typeInfo(Values).@"struct".fields) |field| {
        const name = field.name;
        var expected = false;
        for (reserved) |entry| {
            if (std.mem.eql(u8, entry, name)) expected = true;
        }
        for (bound) |entry| {
            if (std.mem.eql(u8, entry, name)) {
                @compileError(std.fmt.comptimePrint(
                    "Bombelli {s} input field '.{s}' names a bound variable, not an input",
                    .{ description, name },
                ));
            }
        }
        if (!expected) {
            outer: for (node_sets) |nodes| {
                for (nodes) |node| {
                    if (node == .symbol and std.mem.eql(u8, node.symbol, name)) {
                        expected = true;
                        break :outer;
                    }
                }
            }
        }
        if (!expected) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli {s} input field '.{s}' does not name an input of this callable",
                .{ description, name },
            ));
        }
    }
}

pub inline fn evaluateInto(
    comptime expression: ast.Expr,
    output: *f64,
    values: anytype,
) void {
    evaluateIntoAs(f64, expression, output, values);
}

pub inline fn evaluateIntoAs(
    comptime T: type,
    comptime expression: ast.Expr,
    output: *T,
    values: anytype,
) void {
    output.* = evaluateAs(T, expression, values);
}

pub inline fn evaluateBatchInto(
    comptime expression: ast.Expr,
    output: []f64,
    values: anytype,
) BatchInputError!void {
    try validateBatchInputs(expression.nodes, values, output.len);
    evaluateBatchRange(expression, output, &values, 0, output.len);
}

pub fn evaluateBatchParallelInto(
    comptime expression: ast.Expr,
    output: []f64,
    values: anytype,
    options: BatchOptions,
) BatchInputError!void {
    try validateBatchInputs(expression.nodes, values, output.len);
    if (output.len == 0) return;

    if (comptime !threadsAvailable()) {
        evaluateBatchRange(expression, output, &values, 0, output.len);
        return;
    }
    if (output.len <= options.min_batch_len) {
        evaluateBatchRange(expression, output, &values, 0, output.len);
        return;
    }

    const minimum = @max(options.min_items_per_thread, 1);
    const available = if (options.max_threads == 0)
        std.Thread.getCpuCount() catch 1
    else
        options.max_threads;
    const thread_count = @min(
        @max(available, 1),
        @max(output.len / minimum, 1),
        max_batch_threads,
    );

    if (thread_count == 1) {
        evaluateBatchRange(expression, output, &values, 0, output.len);
        return;
    }

    const Values = @TypeOf(values);
    const Worker = struct {
        fn run(
            worker_output: []f64,
            worker_values: *const Values,
            start: usize,
            end: usize,
        ) void {
            evaluateBatchRange(
                expression,
                worker_output,
                worker_values,
                start,
                end,
            );
        }
    };

    var threads: [max_batch_threads - 1]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..thread_count - 1) |worker_index| {
        const start = output.len / thread_count * worker_index +
            @min(worker_index, output.len % thread_count);
        const end = output.len / thread_count * (worker_index + 1) +
            @min(worker_index + 1, output.len % thread_count);
        const thread = std.Thread.spawn(
            .{ .stack_size = batch_thread_stack_size },
            Worker.run,
            .{ output, &values, start, end },
        ) catch {
            evaluateBatchRange(expression, output, &values, start, end);
            continue;
        };
        threads[spawned] = thread;
        spawned += 1;
    }

    const calling_start = output.len / thread_count * (thread_count - 1) +
        @min(thread_count - 1, output.len % thread_count);
    evaluateBatchRange(
        expression,
        output,
        &values,
        calling_start,
        output.len,
    );
    for (threads[0..spawned]) |thread| thread.join();
}

pub inline fn evaluateWithBoundVariable(
    comptime expression: ast.Expr,
    values: anytype,
    comptime variable: []const u8,
    variable_value: f64,
) f64 {
    const results = evaluateNodesWithBoundVariable(
        expression.nodes,
        values,
        variable,
        variable_value,
    );
    return results[@intCast(expression.root)];
}

pub inline fn evaluateWithBoundVariableLanes(
    comptime lane_count: usize,
    comptime expression: ast.Expr,
    values: anytype,
    comptime variable: []const u8,
    variable_values: @Vector(lane_count, f64),
) @Vector(lane_count, f64) {
    const Number = @Vector(lane_count, f64);
    const Context = BoundContext(
        @TypeOf(values),
        Number,
        variable,
    );
    const results = evaluateNodesWithResolver(
        Number,
        expression.nodes,
        Context{
            .values = values,
            .variable_value = variable_values,
        },
        boundSymbolValue,
    );
    return results[@intCast(expression.root)];
}

pub inline fn evaluateVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    values: anytype,
) [N]f64 {
    return evaluateVectorAs(f64, N, expression, values);
}

pub inline fn evaluateVectorAs(
    comptime T: type,
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    values: anytype,
) [N]T {
    validateEvaluationScalar(T);
    var output: [N]T = undefined;
    evaluateVectorIntoAs(T, N, expression, &output, values);
    return output;
}

pub inline fn evaluateVectorInto(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    output: anytype,
    values: anytype,
) void {
    validateOutput(N, output);
    const results = evaluateNodes(expression.nodes, values);
    inline for (expression.roots, 0..) |root, index| {
        output[index] = results[@intCast(root)];
    }
}

pub inline fn evaluateVectorIntoAs(
    comptime T: type,
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    output: anytype,
    values: anytype,
) void {
    validateEvaluationScalar(T);
    validateOutputAs(T, N, output);
    const results = evaluateNodesAs(T, expression.nodes, values);
    inline for (expression.roots, 0..) |root, index| {
        output[index] = results[@intCast(root)];
    }
}

pub inline fn evaluateMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    values: anytype,
) [R][C]f64 {
    return evaluateMatrixAs(f64, R, C, expression, values);
}

pub inline fn evaluateMatrixAs(
    comptime T: type,
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    values: anytype,
) [R][C]T {
    validateEvaluationScalar(T);
    var output: [R][C]T = undefined;
    evaluateMatrixIntoAs(T, R, C, expression, &output, values);
    return output;
}

pub inline fn evaluateMatrixInto(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    output: anytype,
    values: anytype,
) void {
    validateMatrixOutput(R, C, output);
    const results = evaluateNodes(expression.nodes, values);
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            output[row_index][column_index] = results[@intCast(root)];
        }
    }
}

pub inline fn evaluateMatrixIntoAs(
    comptime T: type,
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    output: anytype,
    values: anytype,
) void {
    validateEvaluationScalar(T);
    validateMatrixOutputAs(T, R, C, output);
    const results = evaluateNodesAs(T, expression.nodes, values);
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            output[row_index][column_index] = results[@intCast(root)];
        }
    }
}

pub inline fn evaluateVectorWithVariables(
    comptime R: usize,
    comptime N: usize,
    comptime expression: ast.ExprVector(R),
    values: anytype,
    comptime variable_names: [N][]const u8,
    variable_values: [N]f64,
) [R]f64 {
    const results = evaluateNodesWithVariables(
        N,
        expression.nodes,
        values,
        variable_names,
        variable_values,
    );
    var output: [R]f64 = undefined;
    inline for (expression.roots, 0..) |root, index| {
        output[index] = results[@intCast(root)];
    }
    return output;
}

pub inline fn evaluateMatrixWithVariables(
    comptime R: usize,
    comptime C: usize,
    comptime N: usize,
    comptime expression: ast.ExprMatrix(R, C),
    values: anytype,
    comptime variable_names: [N][]const u8,
    variable_values: [N]f64,
) [R][C]f64 {
    const results = evaluateNodesWithVariables(
        N,
        expression.nodes,
        values,
        variable_names,
        variable_values,
    );
    var output: [R][C]f64 = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            output[row_index][column_index] = results[@intCast(root)];
        }
    }
    return output;
}

inline fn evaluateNodes(comptime nodes: []const ast.Node, values: anytype) [nodes.len]f64 {
    return evaluateNodesAs(f64, nodes, values);
}

inline fn evaluateNodesAs(
    comptime T: type,
    comptime nodes: []const ast.Node,
    values: anytype,
) [nodes.len]T {
    return evaluateNodesWithResolver(
        T,
        nodes,
        values,
        scalarSymbolValue,
    );
}

inline fn evaluateNodesWithResolver(
    comptime Number: type,
    comptime nodes: []const ast.Node,
    context: anytype,
    comptime resolveSymbol: anytype,
) [nodes.len]Number {
    // Finished programs are topologically ordered, so this unrolled loop emits
    // one numerical computation per stored node across every output root.
    var results: [nodes.len]Number = undefined;
    inline for (nodes, 0..) |node, index| {
        results[index] = switch (node) {
            .integer => |value| numberValue(Number, value),
            .rational => |value| numberValue(Number, value.numerator) /
                numberValue(Number, value.denominator),
            .float => |value| numberValue(Number, value),
            .constant => |value| constantValue(Number, value),
            .symbol => |name| resolveSymbol(Number, name, context),
            .add => |binary| results[@intCast(binary.left)] +
                results[@intCast(binary.right)],
            .add_nary => |operands| blk: {
                var sum = numberValue(Number, 0.0);
                inline for (operands) |child| sum += results[@intCast(child)];
                break :blk sum;
            },
            .sub => |binary| results[@intCast(binary.left)] -
                results[@intCast(binary.right)],
            .mul => |binary| results[@intCast(binary.left)] *
                results[@intCast(binary.right)],
            .mul_nary => |operands| blk: {
                var product = numberValue(Number, 1.0);
                inline for (operands) |child| product *= results[@intCast(child)];
                break :blk product;
            },
            .div => |binary| results[@intCast(binary.left)] /
                results[@intCast(binary.right)],
            .pow => |power| integerPower(
                results[@intCast(power.base)],
                power.exponent,
            ),
            .negate => |child| -results[@intCast(child)],
            .sin => |child| @sin(results[@intCast(child)]),
            .cos => |child| @cos(results[@intCast(child)]),
            .tan => |child| @tan(results[@intCast(child)]),
            .atan => |child| std.math.atan(results[@intCast(child)]),
            .abs => |child| @abs(results[@intCast(child)]),
            .exp => |child| @exp(results[@intCast(child)]),
            .ln => |child| @log(results[@intCast(child)]),
        };
    }
    return results;
}

inline fn evaluateNodesWithBoundVariable(
    comptime nodes: []const ast.Node,
    values: anytype,
    comptime variable: []const u8,
    variable_value: f64,
) [nodes.len]f64 {
    const Context = BoundContext(
        @TypeOf(values),
        f64,
        variable,
    );
    return evaluateNodesWithResolver(
        f64,
        nodes,
        Context{
            .values = values,
            .variable_value = variable_value,
        },
        boundSymbolValue,
    );
}

inline fn evaluateNodesWithVariables(
    comptime N: usize,
    comptime nodes: []const ast.Node,
    values: anytype,
    comptime variable_names: [N][]const u8,
    variable_values: [N]f64,
) [nodes.len]f64 {
    var results: [nodes.len]f64 = undefined;
    inline for (nodes, 0..) |node, index| {
        results[index] = switch (node) {
            .integer => |value| @floatFromInt(value),
            .rational => |value| value.toF64(),
            .float => |value| value,
            .constant => |value| value.value(),
            .symbol => |name| variableValue(
                N,
                name,
                values,
                variable_names,
                variable_values,
            ),
            .add => |binary| results[@intCast(binary.left)] +
                results[@intCast(binary.right)],
            .add_nary => |operands| blk: {
                var sum: f64 = 0.0;
                inline for (operands) |child| sum += results[@intCast(child)];
                break :blk sum;
            },
            .sub => |binary| results[@intCast(binary.left)] -
                results[@intCast(binary.right)],
            .mul => |binary| results[@intCast(binary.left)] *
                results[@intCast(binary.right)],
            .mul_nary => |operands| blk: {
                var product: f64 = 1.0;
                inline for (operands) |child| product *= results[@intCast(child)];
                break :blk product;
            },
            .div => |binary| results[@intCast(binary.left)] /
                results[@intCast(binary.right)],
            .pow => |power| integerPower(
                results[@intCast(power.base)],
                power.exponent,
            ),
            .negate => |child| -results[@intCast(child)],
            .sin => |child| @sin(results[@intCast(child)]),
            .cos => |child| @cos(results[@intCast(child)]),
            .tan => |child| @tan(results[@intCast(child)]),
            .atan => |child| std.math.atan(results[@intCast(child)]),
            .abs => |child| @abs(results[@intCast(child)]),
            .exp => |child| @exp(results[@intCast(child)]),
            .ln => |child| @log(results[@intCast(child)]),
        };
    }
    return results;
}

inline fn validateOutput(comptime N: usize, output: anytype) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalInto expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.len != N) {
                        @compileError("Bombelli evalInto output has the wrong length");
                    }
                    if (array.child != f64) {
                        @compileError("Bombelli evalInto output elements must be f64");
                    }
                },
                else => @compileError("Bombelli evalInto expects a pointer to a fixed-size output array"),
            }
        },
        else => @compileError("Bombelli evalInto expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn validateOutputAs(
    comptime T: type,
    comptime N: usize,
    output: anytype,
) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalIntoAs expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.len != N) {
                        @compileError("Bombelli evalIntoAs output has the wrong length");
                    }
                    if (array.child != T) {
                        @compileError("Bombelli evalIntoAs output elements must match the requested scalar type");
                    }
                },
                else => @compileError("Bombelli evalIntoAs expects a pointer to a fixed-size output array"),
            }
        },
        else => @compileError("Bombelli evalIntoAs expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn validateMatrixOutput(comptime R: usize, comptime C: usize, output: anytype) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalInto expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |outer| {
                    if (outer.len != R) {
                        @compileError("Bombelli evalInto output has the wrong row count");
                    }
                    switch (@typeInfo(outer.child)) {
                        .array => |inner| {
                            if (inner.len != C) {
                                @compileError("Bombelli evalInto output has the wrong column count");
                            }
                            if (inner.child != f64) {
                                @compileError("Bombelli evalInto output elements must be f64");
                            }
                        },
                        else => @compileError("Bombelli matrix evalInto expects two-dimensional output storage"),
                    }
                },
                else => @compileError("Bombelli evalInto expects a pointer to a fixed-size output matrix"),
            }
        },
        else => @compileError("Bombelli evalInto expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn validateMatrixOutputAs(
    comptime T: type,
    comptime R: usize,
    comptime C: usize,
    output: anytype,
) void {
    const Output = @TypeOf(output);
    switch (@typeInfo(Output)) {
        .pointer => |pointer| {
            if (pointer.is_const) {
                @compileError("Bombelli evalIntoAs expects mutable caller-provided output storage");
            }
            switch (@typeInfo(pointer.child)) {
                .array => |outer| {
                    if (outer.len != R) {
                        @compileError("Bombelli evalIntoAs output has the wrong row count");
                    }
                    switch (@typeInfo(outer.child)) {
                        .array => |inner| {
                            if (inner.len != C) {
                                @compileError("Bombelli evalIntoAs output has the wrong column count");
                            }
                            if (inner.child != T) {
                                @compileError("Bombelli evalIntoAs output elements must match the requested scalar type");
                            }
                        },
                        else => @compileError("Bombelli matrix evalIntoAs expects two-dimensional output storage"),
                    }
                },
                else => @compileError("Bombelli evalIntoAs expects a pointer to a fixed-size output matrix"),
            }
        },
        else => @compileError("Bombelli evalIntoAs expects a pointer to mutable caller-provided output storage"),
    }
}

inline fn symbolValue(comptime name: []const u8, values: anytype) f64 {
    return scalarSymbolValue(f64, name, values);
}

inline fn scalarSymbolValue(
    comptime Number: type,
    comptime name: []const u8,
    values: anytype,
) Number {
    const Values = @TypeOf(values);
    if (@typeInfo(Values) != .@"struct") {
        @compileError("Bombelli eval expects a struct value containing symbol fields");
    }
    if (!@hasField(Values, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli eval input is missing the field '.{s}'",
            .{name},
        ));
    }

    const value = @field(values, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int, .float, .comptime_float => numberValue(
            Number,
            value,
        ),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli eval field '.{s}' must be an integer or floating-point value",
            .{name},
        )),
    };
}

fn BoundContext(
    comptime Values: type,
    comptime Number: type,
    comptime variable: []const u8,
) type {
    return struct {
        pub const variable_name = variable;
        values: Values,
        variable_value: Number,
    };
}

inline fn boundSymbolValue(
    comptime Number: type,
    comptime name: []const u8,
    context: anytype,
) Number {
    return if (comptime std.mem.eql(
        u8,
        name,
        @TypeOf(context).variable_name,
    ))
        context.variable_value
    else
        scalarSymbolValue(Number, name, context.values);
}

inline fn variableValue(
    comptime N: usize,
    comptime name: []const u8,
    values: anytype,
    comptime variable_names: [N][]const u8,
    variable_values: [N]f64,
) f64 {
    inline for (variable_names, 0..) |candidate, index| {
        if (comptime std.mem.eql(u8, name, candidate)) {
            return variable_values[index];
        }
    }
    return symbolValue(name, values);
}

inline fn validateEvaluationScalar(comptime T: type) void {
    if (@typeInfo(T) != .float) {
        @compileError("Bombelli evalAs expects a floating-point scalar type");
    }
}

inline fn numberValue(comptime Number: type, value: anytype) Number {
    const Scalar = switch (@typeInfo(Number)) {
        .float => Number,
        .vector => |vector| switch (@typeInfo(vector.child)) {
            .float => vector.child,
            else => @compileError("Bombelli internal evaluator expects a floating-point scalar or vector"),
        },
        else => @compileError("Bombelli internal evaluator expects a floating-point scalar or vector"),
    };
    const scalar: Scalar = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("Bombelli internal evaluator cannot convert this numerical value"),
    };
    return switch (@typeInfo(Number)) {
        .float => scalar,
        .vector => @as(Number, @splat(scalar)),
        else => comptime unreachable,
    };
}

inline fn constantValue(
    comptime Number: type,
    value: ast.Constant,
) Number {
    return switch (value) {
        // Keep the literal at comptime precision until it is converted to the
        // requested scalar. Constant.value() intentionally remains the f64
        // convenience API.
        .pi => numberValue(Number, std.math.pi),
    };
}

inline fn integerPower(
    base: anytype,
    comptime exponent: @import("../core/exact.zig").Rational,
) @TypeOf(base) {
    const Number = @TypeOf(base);
    if (exponent.numerator == 0) return numberValue(Number, 1.0);
    if (exponent.numerator == 1 and exponent.denominator == 1) return base;

    if (exponent.denominator == 1) {
        const magnitude: u64 = @intCast(if (exponent.numerator < 0)
            -@as(i128, exponent.numerator)
        else
            exponent.numerator);
        const powered = unsignedIntegerPower(base, magnitude);
        return if (exponent.numerator < 0)
            numberValue(Number, 1.0) / powered
        else
            powered;
    }

    return switch (@typeInfo(Number)) {
        .float => rationalPowerScalar(base, exponent),
        .vector => |vector| blk: {
            var result: Number = undefined;
            inline for (0..vector.len) |lane| {
                result[lane] = rationalPowerScalar(base[lane], exponent);
            }
            break :blk result;
        },
        else => comptime unreachable,
    };
}

inline fn rationalPowerScalar(
    base: anytype,
    comptime exponent: @import("../core/exact.zig").Rational,
) @TypeOf(base) {
    const Scalar = @TypeOf(base);
    const exponent_value = numberValue(Scalar, exponent.numerator) /
        numberValue(Scalar, exponent.denominator);
    const magnitude = if (Scalar == f32 or Scalar == f64)
        std.math.pow(Scalar, @abs(base), exponent_value)
    else
        @exp(@log(@abs(base)) * exponent_value);
    if (base >= 0.0) return magnitude;
    if (exponent.denominator % 2 == 0) return std.math.nan(Scalar);
    return if (@mod(exponent.numerator, 2) == 0) magnitude else -magnitude;
}

inline fn unsignedIntegerPower(
    base: anytype,
    comptime exponent: u64,
) @TypeOf(base) {
    if (exponent == 0) return numberValue(@TypeOf(base), 1.0);
    if (exponent == 1) return base;

    const half = unsignedIntegerPower(base, exponent / 2);
    const square = half * half;
    return if (exponent % 2 == 0) square else square * base;
}

const max_batch_threads = 32;
const batch_thread_stack_size = 512 * 1024;

inline fn evaluateBatchRange(
    comptime expression: ast.Expr,
    output: []f64,
    values: anytype,
    start: usize,
    end: usize,
) void {
    const Values = @typeInfo(@TypeOf(values)).pointer.child;
    const Context = BatchContext(Values);
    var offset = start;
    if (comptime prefersVectorLanes(expression)) {
        const Number = @Vector(batch_vector_length, f64);
        while (offset + batch_vector_length <= end) : (offset += batch_vector_length) {
            const results = evaluateNodesWithResolver(
                Number,
                expression.nodes,
                Context{ .values = values, .offset = offset },
                batchSymbolValue,
            );
            output[offset..][0..batch_vector_length].* =
                results[@intCast(expression.root)];
        }
    }
    // Also the whole range when lanes are unprofitable. Evaluating the tail
    // as f64 rather than a one-lane vector keeps the node evaluator from
    // being instantiated a second time.
    while (offset < end) : (offset += 1) {
        const results = evaluateNodesWithResolver(
            f64,
            expression.nodes,
            Context{ .values = values, .offset = offset },
            batchSymbolValue,
        );
        output[offset] = results[@intCast(expression.root)];
    }
}

/// Explicit lanes pay off only when every node lowers to vector hardware.
/// Transcendentals and rational powers lower to per-lane scalar library
/// calls, so vectorizing them costs lane assembly for no arithmetic win.
pub fn prefersVectorLanes(comptime expression: ast.Expr) bool {
    if (batch_vector_length == 1) return false;
    inline for (expression.nodes) |node| {
        switch (node) {
            .sin, .cos, .tan, .atan, .exp, .ln => return false,
            .pow => |power| if (power.exponent.denominator != 1) return false,
            else => {},
        }
    }
    return true;
}

fn BatchContext(comptime Values: type) type {
    return struct {
        values: *const Values,
        offset: usize,
    };
}

inline fn batchSymbolValue(
    comptime Number: type,
    comptime name: []const u8,
    context: anytype,
) Number {
    const Values = @typeInfo(@TypeOf(context.values)).pointer.child;
    if (@typeInfo(Values) != .@"struct") {
        @compileError("Bombelli batch eval expects a struct value containing symbol fields");
    }
    if (!@hasField(Values, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli batch eval input is missing the field '.{s}'",
            .{name},
        ));
    }

    const value = @field(context.values.*, name);
    return switch (@typeInfo(Number)) {
        .vector => |vector| blk: {
            var result: Number = undefined;
            inline for (0..vector.len) |lane| {
                result[lane] = batchFieldValue(name, value, context.offset + lane);
            }
            break :blk result;
        },
        else => batchFieldValue(name, value, context.offset),
    };
}

inline fn validateBatchInputs(
    comptime nodes: []const ast.Node,
    values: anytype,
    expected_len: usize,
) BatchInputError!void {
    const Values = @TypeOf(values);
    if (@typeInfo(Values) != .@"struct") {
        @compileError("Bombelli batch eval expects a struct value containing symbol fields");
    }
    inline for (nodes) |node| {
        switch (node) {
            .symbol => |name| {
                if (!@hasField(Values, name)) {
                    @compileError(std.fmt.comptimePrint(
                        "Bombelli batch eval input is missing the field '.{s}'",
                        .{name},
                    ));
                }
                if (batchFieldLength(name, @field(values, name))) |actual_len| {
                    if (actual_len != expected_len) {
                        return error.InputLengthMismatch;
                    }
                }
            },
            else => {},
        }
    }
}

inline fn batchFieldLength(
    comptime name: []const u8,
    value: anytype,
) ?usize {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .int, .comptime_int, .float, .comptime_float => null,
        .array => |array| blk: {
            validateBatchElement(name, array.child);
            break :blk array.len;
        },
        .vector => |vector| blk: {
            validateBatchElement(name, vector.child);
            break :blk vector.len;
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => blk: {
                validateBatchElement(name, pointer.child);
                break :blk value.len;
            },
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| blk: {
                    validateBatchElement(name, array.child);
                    break :blk array.len;
                },
                .int, .float => blk: {
                    validateBatchElement(name, pointer.child);
                    break :blk null;
                },
                else => batchFieldTypeError(name),
            },
            else => batchFieldTypeError(name),
        },
        else => batchFieldTypeError(name),
    };
}

inline fn batchFieldValue(
    comptime name: []const u8,
    value: anytype,
    index: usize,
) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        .array, .vector => numericBatchElement(name, value[index]),
        .pointer => |pointer| switch (pointer.size) {
            .slice => numericBatchElement(name, value[index]),
            .one => switch (@typeInfo(pointer.child)) {
                .array => numericBatchElement(name, value.*[index]),
                .int, .float => numericBatchElement(name, value.*),
                else => batchFieldTypeError(name),
            },
            else => batchFieldTypeError(name),
        },
        else => batchFieldTypeError(name),
    };
}

inline fn numericBatchElement(
    comptime name: []const u8,
    value: anytype,
) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => batchElementTypeError(name),
    };
}

inline fn validateBatchElement(
    comptime name: []const u8,
    comptime Element: type,
) void {
    switch (@typeInfo(Element)) {
        .int, .float => {},
        else => batchElementTypeError(name),
    }
}

fn batchFieldTypeError(comptime name: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli batch eval field '.{s}' must be numeric or a numeric array, vector, or slice",
        .{name},
    ));
}

fn batchElementTypeError(comptime name: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli batch eval field '.{s}' must contain numeric elements",
        .{name},
    ));
}

fn threadsAvailable() bool {
    if (builtin.single_threaded) return false;
    return switch (builtin.os.tag) {
        .windows,
        .linux,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        .dragonfly,
        .freebsd,
        .netbsd,
        .openbsd,
        .illumos,
        .serenity,
        => true,
        else => false,
    };
}
