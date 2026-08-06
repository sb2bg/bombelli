const ast = @import("../../expression.zig");
const evaluation = @import("../runtime/evaluation.zig");
const linearization = @import("linearization.zig");
const multi = @import("../transform/multi.zig");
const parser = @import("../parse/parser.zig");
const std = @import("std");

pub fn parseVector(comptime N: usize, comptime sources: anytype) ast.ExprVector(N) {
    var expressions: [N]ast.Expr = undefined;
    inline for (sources, 0..) |source, index| {
        expressions[index] = parser.parse(source);
    }
    return multi.vector(N, expressions);
}

pub inline fn evaluate(
    comptime M: usize,
    comptime outputs: ast.ExprVector(M),
    comptime contract: []const []const u8,
    inputs: anytype,
    comptime description: []const u8,
) [M]f64 {
    comptime evaluation.validateInputFields(
        @TypeOf(inputs),
        &.{outputs.nodes},
        contract,
        &.{},
        description,
    );
    return outputs.eval(inputs);
}

pub inline fn evaluateInto(
    comptime M: usize,
    comptime outputs: ast.ExprVector(M),
    comptime contract: []const []const u8,
    output: *[M]f64,
    inputs: anytype,
    comptime description: []const u8,
) void {
    output.* = evaluate(M, outputs, contract, inputs, description);
}

pub fn jacobian(
    comptime M: usize,
    comptime N: usize,
    comptime outputs: ast.ExprVector(M),
    comptime variables: anytype,
) ast.ExprMatrix(M, N) {
    return outputs.jacobian(variables);
}

pub fn linearize(
    comptime M: usize,
    comptime N: usize,
    comptime outputs: ast.ExprVector(M),
    comptime variables: anytype,
) linearization.Program(M, N) {
    return linearization.make(M, N, outputs, jacobian(M, N, outputs, variables));
}

pub inline fn valueAndJacobian(
    comptime M: usize,
    comptime N: usize,
    comptime outputs: ast.ExprVector(M),
    comptime variables: anytype,
    comptime contract: []const []const u8,
    inputs: anytype,
    comptime description: []const u8,
) linearization.Result(M, N, f64) {
    const program = comptime linearize(M, N, outputs, variables);
    comptime evaluation.validateInputFields(
        @TypeOf(inputs),
        &.{program.combined.nodes},
        contract,
        &.{},
        description,
    );
    return program.eval(inputs);
}

pub fn validateSymbols(
    comptime outputs: anytype,
    comptime first_group: []const []const u8,
    comptime second_group: []const []const u8,
    comptime diagnostic: []const u8,
) void {
    for (outputs.nodes) |node| {
        if (node != .symbol) continue;
        const symbol = node.symbol;
        if (contains(first_group, symbol) or contains(second_group, symbol)) continue;
        @compileError(std.fmt.comptimePrint(diagnostic, .{symbol}));
    }
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}
