//! Fused fixed-size value-and-Jacobian programs.

const ast = @import("../../expression.zig");
const evaluation = @import("../runtime/evaluation.zig");
const multi = @import("../transform/multi.zig");

/// Values and first derivatives produced by one shared DAG evaluation.
pub fn Result(
    comptime M: usize,
    comptime N: usize,
    comptime T: type,
) type {
    return struct {
        values: [M]T,
        jacobian: [M][N]T,
    };
}

/// A compiled program whose primal and derivative roots share one node store.
pub fn Program(comptime M: usize, comptime N: usize) type {
    const K = M + M * N;
    return struct {
        combined: ast.ExprVector(K),

        const Self = @This();

        /// Evaluates values and their Jacobian in one shared DAG pass.
        pub inline fn eval(
            comptime self: Self,
            inputs: anytype,
        ) Result(M, N, f64) {
            return unpack(
                M,
                N,
                f64,
                self.combined.eval(inputs),
            );
        }

        /// Typed fused evaluation using floating-point scalar `T`.
        pub inline fn evalAs(
            comptime self: Self,
            comptime T: type,
            inputs: anytype,
        ) Result(M, N, T) {
            return unpack(
                M,
                N,
                T,
                self.combined.evalAs(T, inputs),
            );
        }

        /// Evaluates into caller-owned result storage.
        pub inline fn evalInto(
            comptime self: Self,
            output: *Result(M, N, f64),
            inputs: anytype,
        ) void {
            output.* = self.eval(inputs);
        }

        /// Typed fused evaluation into caller-owned result storage.
        pub inline fn evalIntoAs(
            comptime self: Self,
            comptime T: type,
            output: *Result(M, N, T),
            inputs: anytype,
        ) void {
            output.* = self.evalAs(T, inputs);
        }

        /// Applies the Jacobian to a tangent without exposing matrix layout.
        pub inline fn jvp(
            comptime self: Self,
            inputs: anytype,
            tangent: [N]f64,
        ) [M]f64 {
            return self.jvpAs(f64, inputs, tangent);
        }

        /// Typed Jacobian-vector product.
        pub inline fn jvpAs(
            comptime self: Self,
            comptime T: type,
            inputs: anytype,
            tangent: [N]T,
        ) [M]T {
            const linearized = self.evalAs(T, inputs);
            var result: [M]T = [_]T{0} ** M;
            for (0..M) |row| {
                for (0..N) |column| {
                    result[row] +=
                        linearized.jacobian[row][column] * tangent[column];
                }
            }
            return result;
        }

        /// Applies the transposed Jacobian to an output cotangent.
        pub inline fn vjp(
            comptime self: Self,
            inputs: anytype,
            cotangent: [M]f64,
        ) [N]f64 {
            return self.vjpAs(f64, inputs, cotangent);
        }

        /// Typed vector-Jacobian product.
        pub inline fn vjpAs(
            comptime self: Self,
            comptime T: type,
            inputs: anytype,
            cotangent: [M]T,
        ) [N]T {
            const linearized = self.evalAs(T, inputs);
            var result: [N]T = [_]T{0} ** N;
            for (0..M) |row| {
                for (0..N) |column| {
                    result[column] +=
                        cotangent[row] * linearized.jacobian[row][column];
                }
            }
            return result;
        }

        pub inline fn evalWithVariables(
            comptime self: Self,
            inputs: anytype,
            comptime variable_names: [N][]const u8,
            variable_values: [N]f64,
        ) Result(M, N, f64) {
            return unpack(
                M,
                N,
                f64,
                evaluation.evaluateVectorWithVariables(
                    K,
                    N,
                    self.combined,
                    inputs,
                    variable_names,
                    variable_values,
                ),
            );
        }

        /// Measures the fused shared DAG.
        pub fn metrics(
            comptime self: Self,
        ) @import("../core/metrics.zig").Metrics {
            return self.combined.metrics();
        }
    };
}

pub fn make(
    comptime M: usize,
    comptime N: usize,
    comptime values: ast.ExprVector(M),
    comptime jacobian: ast.ExprMatrix(M, N),
) Program(M, N) {
    const K = M + M * N;
    var expressions: [K]ast.Expr = undefined;
    inline for (0..M) |row| {
        expressions[row] = values.at(row);
    }
    inline for (0..M) |row| {
        inline for (0..N) |column| {
            expressions[M + row * N + column] =
                jacobian.at(row, column);
        }
    }
    return .{ .combined = multi.vector(K, expressions) };
}

fn unpack(
    comptime M: usize,
    comptime N: usize,
    comptime T: type,
    combined: [M + M * N]T,
) Result(M, N, T) {
    var result: Result(M, N, T) = undefined;
    for (0..M) |row| {
        result.values[row] = combined[row];
        for (0..N) |column| {
            result.jacobian[row][column] =
                combined[M + row * N + column];
        }
    }
    return result;
}
