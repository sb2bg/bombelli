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
    min_batch_len: usize = 262_144,
    /// Target chunk size used to cap the number of worker threads.
    min_items_per_thread: usize = 65_536,
};

pub const batch_vector_length = std.simd.suggestVectorLength(f64) orelse 1;

pub inline fn evaluate(comptime expression: ast.Expr, values: anytype) f64 {
    const results = evaluateNodes(expression.nodes, values);
    return results[@intCast(expression.root)];
}

pub inline fn evaluateInto(
    comptime expression: ast.Expr,
    output: *f64,
    values: anytype,
) void {
    output.* = evaluate(expression, values);
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
    var output: [N]f64 = undefined;
    evaluateVectorInto(N, expression, &output, values);
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

pub inline fn evaluateMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    values: anytype,
) [R][C]f64 {
    var output: [R][C]f64 = undefined;
    evaluateMatrixInto(R, C, expression, &output, values);
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
    return evaluateNodesWithResolver(
        f64,
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
            .integer => |value| numberValue(
                Number,
                @as(f64, @floatFromInt(value)),
            ),
            .rational => |value| numberValue(Number, value.toF64()),
            .float => |value| numberValue(Number, value),
            .constant => |value| numberValue(Number, value.value()),
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

inline fn symbolValue(comptime name: []const u8, values: anytype) f64 {
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
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli eval field '.{s}' must be an integer or floating-point value",
            .{name},
        )),
    };
}

inline fn scalarSymbolValue(
    comptime Number: type,
    comptime name: []const u8,
    values: anytype,
) Number {
    return numberValue(Number, symbolValue(name, values));
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

inline fn numberValue(comptime Number: type, value: f64) Number {
    return switch (@typeInfo(Number)) {
        .float => @as(Number, @floatCast(value)),
        .vector => @as(Number, @splat(value)),
        else => @compileError("Bombelli internal evaluator expects a floating-point scalar or vector"),
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
    base: f64,
    comptime exponent: @import("../core/exact.zig").Rational,
) f64 {
    const magnitude = std.math.pow(
        f64,
        @abs(base),
        @as(f64, @floatFromInt(exponent.numerator)) /
            @as(f64, @floatFromInt(exponent.denominator)),
    );
    if (base >= 0.0) return magnitude;
    if (exponent.denominator % 2 == 0) return std.math.nan(f64);
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
    const Number = @Vector(batch_vector_length, f64);
    const Context = BatchContext(Values);
    var offset = start;
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
    while (offset < end) : (offset += 1) {
        const Tail = @Vector(1, f64);
        const results = evaluateNodesWithResolver(
            Tail,
            expression.nodes,
            Context{ .values = values, .offset = offset },
            batchSymbolValue,
        );
        output[offset] = results[@intCast(expression.root)][0];
    }
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
    const vector = @typeInfo(Number).vector;
    var result: Number = undefined;
    inline for (0..vector.len) |lane| {
        result[lane] = batchFieldValue(name, value, context.offset + lane);
    }
    return result;
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
