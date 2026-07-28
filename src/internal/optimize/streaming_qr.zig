//! Incremental Givens QR for fixed-column, runtime-row least squares.
//!
//! Each row is folded into an upper-triangular factor immediately. Storage is
//! therefore `O(N²)` and does not depend on the number of observations.

const std = @import("std");

/// Upper-triangular QR state for `N` unknowns and an arbitrary row count.
pub fn Factor(comptime N: usize) type {
    if (N == 0) {
        @compileError("Bombelli streaming QR requires at least one column");
    }

    return struct {
        upper: [N][N]f64,
        transformed_rhs: [N]f64,
        rows: usize,

        const Self = @This();

        pub fn init() Self {
            return .{
                .upper = [_][N]f64{[_]f64{0.0} ** N} ** N,
                .transformed_rhs = [_]f64{0.0} ** N,
                .rows = 0,
            };
        }

        /// Orthogonally folds one `a*x = b` row into the factor.
        pub fn addRow(
            self: *Self,
            input_row: [N]f64,
            input_rhs: f64,
        ) bool {
            if (!allFinite(input_row) or !std.math.isFinite(input_rhs)) {
                return false;
            }

            var row = input_row;
            var rhs = input_rhs;
            for (0..N) |pivot| {
                const below = row[pivot];
                if (below == 0.0) continue;

                const diagonal = self.upper[pivot][pivot];
                const radius = std.math.hypot(diagonal, below);
                if (!std.math.isFinite(radius) or radius == 0.0) {
                    return false;
                }
                const cosine = diagonal / radius;
                const sine = below / radius;

                self.upper[pivot][pivot] = radius;
                row[pivot] = 0.0;
                for (pivot + 1..N) |column| {
                    const upper_value = self.upper[pivot][column];
                    const row_value = row[column];
                    self.upper[pivot][column] =
                        cosine * upper_value + sine * row_value;
                    row[column] =
                        -sine * upper_value + cosine * row_value;
                }

                const upper_rhs = self.transformed_rhs[pivot];
                self.transformed_rhs[pivot] =
                    cosine * upper_rhs + sine * rhs;
                rhs = -sine * upper_rhs + cosine * rhs;
                if (!allFinite(self.upper[pivot]) or
                    !std.math.isFinite(self.transformed_rhs[pivot]) or
                    !std.math.isFinite(rhs))
                {
                    return false;
                }
            }
            self.rows +|= 1;
            return true;
        }

        /// Divides column `j` by `diagonal[j]`.
        ///
        /// If this factor represents `A`, the result represents
        /// `A*diag(1/diagonal)`, with the same implicit orthogonal factor.
        pub fn divideColumns(
            self: *Self,
            diagonal: [N]f64,
        ) bool {
            for (0..N) |column| {
                if (!std.math.isFinite(diagonal[column]) or
                    diagonal[column] <= 0.0)
                {
                    return false;
                }
                for (0..column + 1) |row| {
                    self.upper[row][column] /= diagonal[column];
                    if (!std.math.isFinite(self.upper[row][column])) {
                        return false;
                    }
                }
            }
            return true;
        }

        /// Adds `sqrt(damping) * I` regularization rows.
        pub fn addDamping(self: *Self, damping: f64) bool {
            if (!std.math.isFinite(damping) or damping <= 0.0) {
                return false;
            }
            const root = @sqrt(damping);
            if (!std.math.isFinite(root) or root == 0.0) return false;
            for (0..N) |column| {
                var row = [_]f64{0.0} ** N;
                row[column] = root;
                if (!self.addRow(row, 0.0)) return false;
            }
            return true;
        }

        /// Solves the represented full-rank least-squares problem.
        pub fn solve(self: Self) ?[N]f64 {
            var solution: [N]f64 = undefined;
            var reverse = N;
            while (reverse != 0) {
                reverse -= 1;
                var value = self.transformed_rhs[reverse];
                for (reverse + 1..N) |column| {
                    value -=
                        self.upper[reverse][column] * solution[column];
                }
                const diagonal = self.upper[reverse][reverse];
                if (!std.math.isFinite(diagonal) or diagonal == 0.0) {
                    return null;
                }
                solution[reverse] = value / diagonal;
                if (!std.math.isFinite(solution[reverse])) return null;
            }
            return solution;
        }

        /// Computes `||R*x||₂`, equal to `||A*x||₂` for the represented
        /// factorization.
        pub fn transformedNorm(self: Self, vector: [N]f64) f64 {
            var transformed: [N]f64 = undefined;
            for (0..N) |row| {
                var value: f64 = 0.0;
                for (row..N) |column| {
                    value += self.upper[row][column] * vector[column];
                }
                transformed[row] = value;
            }
            return stableNorm(transformed);
        }

        /// Estimates numerical rank from the unregularized triangular factor.
        pub fn rank(self: Self, relative_tolerance: f64) usize {
            var maximum: f64 = 0.0;
            for (0..N) |index| {
                maximum = @max(maximum, @abs(self.upper[index][index]));
            }
            if (maximum == 0.0 or !std.math.isFinite(maximum)) return 0;
            const threshold = relative_tolerance * maximum;
            var result: usize = 0;
            for (0..N) |index| {
                const diagonal = @abs(self.upper[index][index]);
                if (std.math.isFinite(diagonal) and diagonal > threshold) {
                    result += 1;
                }
            }
            return result;
        }
    };
}

fn stableNorm(vector: anytype) f64 {
    var scale: f64 = 0.0;
    var sum: f64 = 1.0;
    for (vector) |value| {
        const magnitude = @abs(value);
        if (magnitude == 0.0) continue;
        if (!std.math.isFinite(magnitude)) return magnitude;
        if (scale < magnitude) {
            const ratio = scale / magnitude;
            sum = 1.0 + sum * ratio * ratio;
            scale = magnitude;
        } else {
            const ratio = magnitude / scale;
            sum += ratio * ratio;
        }
    }
    return if (scale == 0.0) 0.0 else scale * @sqrt(sum);
}

fn allFinite(vector: anytype) bool {
    for (vector) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

test "streaming QR solves a runtime-row linear regression" {
    var factor = Factor(2).init();
    const matrix = [4][2]f64{
        .{ 1.0, 1.0 },
        .{ 1.0, 2.0 },
        .{ 1.0, 3.0 },
        .{ 1.0, 4.0 },
    };
    const rhs = [4]f64{ 6.0, 5.0, 7.0, 10.0 };
    for (matrix, rhs) |row, value| {
        try std.testing.expect(factor.addRow(row, value));
    }
    const solution = factor.solve().?;
    try std.testing.expectApproxEqAbs(3.5, solution[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.4, solution[1], 1e-12);
}

test "streaming QR damping makes a rank-deficient factor solvable" {
    var factor = Factor(2).init();
    try std.testing.expect(factor.addRow(.{ 1.0, 1.0 }, 1.0));
    try std.testing.expectEqual(@as(usize, 1), factor.rank(1e-12));
    try std.testing.expect(factor.addDamping(1e-6));
    const solution = factor.solve().?;
    try std.testing.expectApproxEqAbs(solution[0], solution[1], 1e-12);
    try std.testing.expectApproxEqAbs(
        1.0 / (2.0 + 1e-6),
        solution[0],
        1e-10,
    );
}
