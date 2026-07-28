//! Allocation-free linear algebra over fixed-size native Zig arrays.
//!
//! The public functions intentionally accept and return `[N]T` and
//! `[R][C]T`.  Bombelli therefore composes with ordinary Zig code without
//! requiring callers to adopt an owned matrix container or a particular
//! storage allocator.

const std = @import("std");

/// Completion state for a numerical matrix factorization.
pub const FactorizationStatus = enum {
    success,
    singular,
    non_finite,
    not_positive_definite,
};

/// Options shared by pivoted numerical factorizations.
pub const FactorizationOptions = struct {
    /// A pivot is treated as zero when it is no larger than this value times
    /// the largest magnitude in the original matrix.
    relative_tolerance: ?f64 = null,
};

/// Returns the result of an LU factorization with partial pivoting.
pub fn Lu(comptime T: type, comptime N: usize) type {
    requireFloat(T);
    if (N == 0) @compileError("Bombelli LU factorization requires a non-empty matrix");
    return struct {
        factors: [N][N]T,
        permutation: [N]usize,
        swap_count: usize,
        rank: usize,
        threshold: T,
        status: FactorizationStatus,

        const Self = @This();

        /// Solves `A*x = rhs` using this factorization.
        pub fn solve(self: Self, rhs: [N]T) ?[N]T {
            if (self.status != .success or !allFiniteVector(rhs)) return null;

            var solution: [N]T = undefined;
            for (0..N) |row| {
                var value = rhs[self.permutation[row]];
                for (0..row) |column| {
                    value -= self.factors[row][column] * solution[column];
                }
                solution[row] = value;
            }

            var reverse = N;
            while (reverse != 0) {
                reverse -= 1;
                var value = solution[reverse];
                for (reverse + 1..N) |column| {
                    value -= self.factors[reverse][column] * solution[column];
                }
                const pivot = self.factors[reverse][reverse];
                if (!std.math.isFinite(pivot) or @abs(pivot) <= self.threshold) {
                    return null;
                }
                solution[reverse] = value / pivot;
            }
            return if (allFiniteVector(solution)) solution else null;
        }

        /// Computes the determinant of the original matrix.
        pub fn determinant(self: Self) T {
            if (self.status == .non_finite) return std.math.nan(T);
            if (self.status != .success) return 0;
            var value: T = if (self.swap_count % 2 == 0) 1 else -1;
            for (0..N) |index| value *= self.factors[index][index];
            return value;
        }
    };
}

/// Computes an LU factorization with scaled partial pivoting.
pub fn lu(
    matrix: anytype,
    options: FactorizationOptions,
) Lu(matrixScalar(@TypeOf(matrix)), matrixRows(@TypeOf(matrix))) {
    const Matrix = @TypeOf(matrix);
    const T = matrixScalar(Matrix);
    const N = comptime matrixRows(Matrix);
    comptime requireSquareMatrix(Matrix);

    var result = Lu(T, N){
        .factors = matrix,
        .permutation = undefined,
        .swap_count = 0,
        .rank = 0,
        .threshold = 0,
        .status = .success,
    };
    for (0..N) |index| result.permutation[index] = index;

    if (!allFiniteMatrix(matrix)) {
        result.status = .non_finite;
        return result;
    }

    const scale = maxAbsMatrix(matrix);
    const relative = tolerance(T, options.relative_tolerance);
    result.threshold = relative * @max(@as(T, 1), scale);

    for (0..N) |column| {
        var pivot_row = column;
        var pivot_magnitude = @abs(result.factors[column][column]);
        for (column + 1..N) |row| {
            const magnitude = @abs(result.factors[row][column]);
            if (magnitude > pivot_magnitude) {
                pivot_magnitude = magnitude;
                pivot_row = row;
            }
        }
        if (!std.math.isFinite(pivot_magnitude) or
            pivot_magnitude <= result.threshold)
        {
            result.status = .singular;
            return result;
        }
        if (pivot_row != column) {
            const temporary = result.factors[column];
            result.factors[column] = result.factors[pivot_row];
            result.factors[pivot_row] = temporary;

            const permutation = result.permutation[column];
            result.permutation[column] = result.permutation[pivot_row];
            result.permutation[pivot_row] = permutation;
            result.swap_count += 1;
        }

        const pivot = result.factors[column][column];
        for (column + 1..N) |row| {
            result.factors[row][column] /= pivot;
            const multiplier = result.factors[row][column];
            for (column + 1..N) |entry| {
                result.factors[row][entry] -=
                    multiplier * result.factors[column][entry];
            }
        }
        result.rank += 1;
    }
    if (!allFiniteMatrix(result.factors)) result.status = .non_finite;
    return result;
}

/// Solves one fixed-size square linear system with partial pivoting.
pub fn solve(
    matrix: anytype,
    rhs: anytype,
    options: FactorizationOptions,
) ?@TypeOf(rhs) {
    const Matrix = @TypeOf(matrix);
    const Vector = @TypeOf(rhs);
    comptime {
        requireSquareMatrix(Matrix);
        requireVector(Vector);
        if (matrixRows(Matrix) != vectorLength(Vector)) {
            @compileError("Bombelli linear solve matrix and right-hand side dimensions do not agree");
        }
        if (matrixScalar(Matrix) != vectorScalar(Vector)) {
            @compileError("Bombelli linear solve matrix and right-hand side scalar types must agree");
        }
    }
    return lu(matrix, options).solve(rhs);
}

/// Returns a lower-triangular Cholesky factorization `A = L*Lᵀ`.
pub fn Cholesky(comptime T: type, comptime N: usize) type {
    requireFloat(T);
    if (N == 0) @compileError("Bombelli Cholesky factorization requires a non-empty matrix");
    return struct {
        lower: [N][N]T,
        threshold: T,
        status: FactorizationStatus,

        const Self = @This();

        /// Solves `A*x = rhs` using the Cholesky factor.
        pub fn solve(self: Self, rhs: [N]T) ?[N]T {
            if (self.status != .success or !allFiniteVector(rhs)) return null;
            var solution: [N]T = undefined;
            for (0..N) |row| {
                var value = rhs[row];
                for (0..row) |column| {
                    value -= self.lower[row][column] * solution[column];
                }
                const diagonal = self.lower[row][row];
                if (@abs(diagonal) <= self.threshold) return null;
                solution[row] = value / diagonal;
            }
            var reverse = N;
            while (reverse != 0) {
                reverse -= 1;
                var value = solution[reverse];
                for (reverse + 1..N) |row| {
                    value -= self.lower[row][reverse] * solution[row];
                }
                const diagonal = self.lower[reverse][reverse];
                if (@abs(diagonal) <= self.threshold) return null;
                solution[reverse] = value / diagonal;
            }
            return if (allFiniteVector(solution)) solution else null;
        }
    };
}

/// Computes a Cholesky factorization of a symmetric positive-definite matrix.
pub fn cholesky(
    matrix: anytype,
    options: FactorizationOptions,
) Cholesky(matrixScalar(@TypeOf(matrix)), matrixRows(@TypeOf(matrix))) {
    const Matrix = @TypeOf(matrix);
    const T = matrixScalar(Matrix);
    const N = comptime matrixRows(Matrix);
    comptime requireSquareMatrix(Matrix);

    const relative = tolerance(T, options.relative_tolerance);
    const scale = maxAbsMatrix(matrix);
    var result = Cholesky(T, N){
        .lower = zeroMatrix(T, N, N),
        .threshold = relative * @max(@as(T, 1), scale),
        .status = .success,
    };
    if (!allFiniteMatrix(matrix)) {
        result.status = .non_finite;
        return result;
    }

    for (0..N) |row| {
        for (0..row + 1) |column| {
            var value = matrix[row][column];
            for (0..column) |entry| {
                value -= result.lower[row][entry] *
                    result.lower[column][entry];
            }
            if (row == column) {
                if (!std.math.isFinite(value)) {
                    result.status = .non_finite;
                    return result;
                }
                if (value <= result.threshold) {
                    result.status = .not_positive_definite;
                    return result;
                }
                result.lower[row][column] = @sqrt(value);
            } else {
                result.lower[row][column] =
                    value / result.lower[column][column];
            }
        }
    }
    return result;
}

/// Returns a compact Householder QR factorization.
pub fn Qr(comptime T: type, comptime M: usize, comptime N: usize) type {
    requireFloat(T);
    if (M == 0 or N == 0) {
        @compileError("Bombelli QR factorization requires a non-empty matrix");
    }
    if (M < N) {
        @compileError("Bombelli QR factorization currently requires rows >= columns");
    }
    return struct {
        factors: [M][N]T,
        reflectors: [N]T,
        rank: usize,
        threshold: T,
        status: FactorizationStatus,

        const Self = @This();

        /// Applies `Qᵀ` to a vector without materializing `Q`.
        pub fn applyTranspose(self: Self, rhs: [M]T) ?[M]T {
            if (self.status == .non_finite or !allFiniteVector(rhs)) return null;
            var result = rhs;
            for (0..N) |column| {
                const tau = self.reflectors[column];
                if (tau == 0) continue;
                var projection = result[column];
                for (column + 1..M) |row| {
                    projection += self.factors[row][column] * result[row];
                }
                projection *= tau;
                result[column] -= projection;
                for (column + 1..M) |row| {
                    result[row] -= self.factors[row][column] * projection;
                }
            }
            return if (allFiniteVector(result)) result else null;
        }

        /// Solves the full-column-rank least-squares problem
        /// `min ||A*x-rhs||₂`.
        pub fn solveLeastSquares(self: Self, rhs: [M]T) ?[N]T {
            if (self.status != .success) return null;
            const transformed = self.applyTranspose(rhs) orelse return null;
            var solution: [N]T = undefined;
            var reverse = N;
            while (reverse != 0) {
                reverse -= 1;
                var value = transformed[reverse];
                for (reverse + 1..N) |column| {
                    value -= self.factors[reverse][column] *
                        solution[column];
                }
                const diagonal = self.factors[reverse][reverse];
                if (!std.math.isFinite(diagonal) or
                    @abs(diagonal) <= self.threshold)
                {
                    return null;
                }
                solution[reverse] = value / diagonal;
            }
            return if (allFiniteVector(solution)) solution else null;
        }
    };
}

/// Computes a Householder QR factorization of a tall or square matrix.
pub fn qr(
    matrix: anytype,
    options: FactorizationOptions,
) Qr(
    matrixScalar(@TypeOf(matrix)),
    matrixRows(@TypeOf(matrix)),
    matrixColumns(@TypeOf(matrix)),
) {
    const Matrix = @TypeOf(matrix);
    const T = matrixScalar(Matrix);
    const M = comptime matrixRows(Matrix);
    const N = comptime matrixColumns(Matrix);
    comptime requireMatrix(Matrix);

    var result = Qr(T, M, N){
        .factors = matrix,
        .reflectors = [_]T{0} ** N,
        .rank = 0,
        .threshold = 0,
        .status = .success,
    };
    if (!allFiniteMatrix(matrix)) {
        result.status = .non_finite;
        return result;
    }
    const scale = maxAbsMatrix(matrix);
    result.threshold = tolerance(T, options.relative_tolerance) *
        @max(@as(T, 1), scale);

    for (0..N) |column| {
        const column_norm = scaledNormColumn(T, M, N, result.factors, column);
        if (!std.math.isFinite(column_norm)) {
            result.status = .non_finite;
            return result;
        }
        if (column_norm <= result.threshold) {
            result.status = .singular;
            continue;
        }

        const leading = result.factors[column][column];
        const beta = if (leading >= 0) -column_norm else column_norm;
        const denominator = leading - beta;
        if (denominator == 0 or !std.math.isFinite(denominator)) {
            result.status = .singular;
            continue;
        }
        const tau = (beta - leading) / beta;
        result.factors[column][column] = beta;
        for (column + 1..M) |row| {
            result.factors[row][column] /= denominator;
        }
        result.reflectors[column] = tau;

        for (column + 1..N) |target| {
            var projection = result.factors[column][target];
            for (column + 1..M) |row| {
                projection += result.factors[row][column] *
                    result.factors[row][target];
            }
            projection *= tau;
            result.factors[column][target] -= projection;
            for (column + 1..M) |row| {
                result.factors[row][target] -=
                    result.factors[row][column] * projection;
            }
        }
        result.rank += 1;
    }
    if (result.rank != N) result.status = .singular;
    if (!allFiniteMatrix(result.factors)) result.status = .non_finite;
    return result;
}

/// Solves a tall or square full-column-rank least-squares problem with QR.
pub fn leastSquares(
    matrix: anytype,
    rhs: anytype,
    options: FactorizationOptions,
) ?[matrixColumns(@TypeOf(matrix))]matrixScalar(@TypeOf(matrix)) {
    const Matrix = @TypeOf(matrix);
    const Vector = @TypeOf(rhs);
    comptime {
        requireMatrix(Matrix);
        requireVector(Vector);
        if (matrixRows(Matrix) != vectorLength(Vector)) {
            @compileError("Bombelli QR least-squares matrix and right-hand side dimensions do not agree");
        }
        if (matrixScalar(Matrix) != vectorScalar(Vector)) {
            @compileError("Bombelli QR least-squares scalar types must agree");
        }
    }
    return qr(matrix, options).solveLeastSquares(rhs);
}

/// Computes a vector dot product.
pub fn dot(left: anytype, right: @TypeOf(left)) vectorScalar(@TypeOf(left)) {
    const Vector = @TypeOf(left);
    const T = vectorScalar(Vector);
    const N = comptime vectorLength(Vector);
    var result: T = 0;
    for (0..N) |index| result += left[index] * right[index];
    return result;
}

/// Computes a stable Euclidean vector norm.
pub fn norm2(vector: anytype) vectorScalar(@TypeOf(vector)) {
    const Vector = @TypeOf(vector);
    const T = vectorScalar(Vector);
    const N = comptime vectorLength(Vector);
    var scale: T = 0;
    var sum: T = 1;
    for (0..N) |index| {
        const magnitude = @abs(vector[index]);
        if (magnitude == 0) continue;
        if (scale < magnitude) {
            const ratio = scale / magnitude;
            sum = 1 + sum * ratio * ratio;
            scale = magnitude;
        } else {
            const ratio = magnitude / scale;
            sum += ratio * ratio;
        }
    }
    return if (scale == 0) 0 else scale * @sqrt(sum);
}

/// Computes the infinity norm of a vector.
pub fn normInf(vector: anytype) vectorScalar(@TypeOf(vector)) {
    const Vector = @TypeOf(vector);
    const T = vectorScalar(Vector);
    const N = comptime vectorLength(Vector);
    var maximum: T = 0;
    for (0..N) |index| maximum = @max(maximum, @abs(vector[index]));
    return maximum;
}

/// Transposes a fixed-size matrix.
pub fn transpose(
    matrix: anytype,
) [matrixColumns(@TypeOf(matrix))][matrixRows(@TypeOf(matrix))]matrixScalar(@TypeOf(matrix)) {
    const Matrix = @TypeOf(matrix);
    const T = matrixScalar(Matrix);
    const R = comptime matrixRows(Matrix);
    const C = comptime matrixColumns(Matrix);
    var result: [C][R]T = undefined;
    for (0..R) |row| {
        for (0..C) |column| result[column][row] = matrix[row][column];
    }
    return result;
}

/// Multiplies a matrix by a vector.
pub fn matVec(
    matrix: anytype,
    vector: anytype,
) [matrixRows(@TypeOf(matrix))]matrixScalar(@TypeOf(matrix)) {
    const Matrix = @TypeOf(matrix);
    const Vector = @TypeOf(vector);
    const T = matrixScalar(Matrix);
    const R = comptime matrixRows(Matrix);
    const C = comptime matrixColumns(Matrix);
    comptime {
        requireVector(Vector);
        if (C != vectorLength(Vector)) {
            @compileError("Bombelli matrix-vector dimensions do not agree");
        }
        if (T != vectorScalar(Vector)) {
            @compileError("Bombelli matrix-vector scalar types must agree");
        }
    }
    var result: [R]T = undefined;
    for (0..R) |row| {
        var value: T = 0;
        for (0..C) |column| value += matrix[row][column] * vector[column];
        result[row] = value;
    }
    return result;
}

/// Multiplies two fixed-size matrices.
pub fn matMul(
    left: anytype,
    right: anytype,
) [matrixRows(@TypeOf(left))][matrixColumns(@TypeOf(right))]matrixScalar(@TypeOf(left)) {
    const Left = @TypeOf(left);
    const Right = @TypeOf(right);
    const T = matrixScalar(Left);
    const R = comptime matrixRows(Left);
    const K = comptime matrixColumns(Left);
    const C = comptime matrixColumns(Right);
    comptime {
        requireMatrix(Right);
        if (K != matrixRows(Right)) {
            @compileError("Bombelli matrix multiplication dimensions do not agree");
        }
        if (T != matrixScalar(Right)) {
            @compileError("Bombelli matrix multiplication scalar types must agree");
        }
    }
    var result: [R][C]T = undefined;
    for (0..R) |row| {
        for (0..C) |column| {
            var value: T = 0;
            for (0..K) |inner| value += left[row][inner] * right[inner][column];
            result[row][column] = value;
        }
    }
    return result;
}

/// Computes a square matrix determinant using pivoted LU.
pub fn determinant(
    matrix: anytype,
    options: FactorizationOptions,
) matrixScalar(@TypeOf(matrix)) {
    comptime requireSquareMatrix(@TypeOf(matrix));
    return lu(matrix, options).determinant();
}

/// Returns an identity matrix.
pub fn identity(
    comptime T: type,
    comptime N: usize,
) [N][N]T {
    requireFloat(T);
    if (N == 0) @compileError("Bombelli identity matrix requires a positive dimension");
    var result = zeroMatrix(T, N, N);
    for (0..N) |index| result[index][index] = 1;
    return result;
}

fn zeroMatrix(
    comptime T: type,
    comptime R: usize,
    comptime C: usize,
) [R][C]T {
    return [_][C]T{[_]T{0} ** C} ** R;
}

fn tolerance(comptime T: type, requested: ?f64) T {
    if (requested) |value| {
        if (!std.math.isFinite(value) or value < 0) {
            @panic("Bombelli factorization tolerance must be finite and non-negative");
        }
        return @floatCast(value);
    }
    return @sqrt(std.math.floatEps(T));
}

fn scaledNormColumn(
    comptime T: type,
    comptime M: usize,
    comptime N: usize,
    matrix: [M][N]T,
    column: usize,
) T {
    var scale: T = 0;
    var sum: T = 1;
    for (column..M) |row| {
        const magnitude = @abs(matrix[row][column]);
        if (magnitude == 0) continue;
        if (scale < magnitude) {
            const ratio = scale / magnitude;
            sum = 1 + sum * ratio * ratio;
            scale = magnitude;
        } else {
            const ratio = magnitude / scale;
            sum += ratio * ratio;
        }
    }
    return if (scale == 0) 0 else scale * @sqrt(sum);
}

fn allFiniteVector(vector: anytype) bool {
    for (vector) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

fn allFiniteMatrix(matrix: anytype) bool {
    for (matrix) |row| {
        if (!allFiniteVector(row)) return false;
    }
    return true;
}

fn maxAbsMatrix(matrix: anytype) matrixScalar(@TypeOf(matrix)) {
    const T = matrixScalar(@TypeOf(matrix));
    var maximum: T = 0;
    for (matrix) |row| {
        for (row) |value| maximum = @max(maximum, @abs(value));
    }
    return maximum;
}

fn requireFloat(comptime T: type) void {
    if (@typeInfo(T) != .float) {
        @compileError("Bombelli numerical linear algebra requires a floating-point scalar type");
    }
}

fn requireVector(comptime Vector: type) void {
    const info = @typeInfo(Vector);
    if (info != .array) {
        @compileError("Bombelli linear algebra vectors must be fixed-size arrays");
    }
    requireFloat(info.array.child);
    if (info.array.len == 0) {
        @compileError("Bombelli linear algebra vectors must be non-empty");
    }
}

fn vectorLength(comptime Vector: type) usize {
    requireVector(Vector);
    return @typeInfo(Vector).array.len;
}

fn vectorScalar(comptime Vector: type) type {
    requireVector(Vector);
    return @typeInfo(Vector).array.child;
}

fn requireMatrix(comptime Matrix: type) void {
    const outer = @typeInfo(Matrix);
    if (outer != .array or @typeInfo(outer.array.child) != .array) {
        @compileError("Bombelli linear algebra matrices must be fixed-size two-dimensional arrays");
    }
    const inner = @typeInfo(outer.array.child).array;
    requireFloat(inner.child);
    if (outer.array.len == 0 or inner.len == 0) {
        @compileError("Bombelli linear algebra matrices must be non-empty");
    }
}

fn requireSquareMatrix(comptime Matrix: type) void {
    requireMatrix(Matrix);
    if (matrixRows(Matrix) != matrixColumns(Matrix)) {
        @compileError("Bombelli operation requires a square matrix");
    }
}

fn matrixRows(comptime Matrix: type) usize {
    requireMatrix(Matrix);
    return @typeInfo(Matrix).array.len;
}

fn matrixColumns(comptime Matrix: type) usize {
    requireMatrix(Matrix);
    return @typeInfo(@typeInfo(Matrix).array.child).array.len;
}

fn matrixScalar(comptime Matrix: type) type {
    requireMatrix(Matrix);
    return @typeInfo(@typeInfo(Matrix).array.child).array.child;
}

test "native array operations preserve dimensions and scalar types" {
    const matrix = [2][3]f32{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
    };
    const vector = [3]f32{ 2, -1, 0.5 };
    try std.testing.expectEqualDeep([2]f32{ 1.5, 6 }, matVec(matrix, vector));
    try std.testing.expectEqualDeep(
        [3][2]f32{
            .{ 1, 4 },
            .{ 2, 5 },
            .{ 3, 6 },
        },
        transpose(matrix),
    );
}

test "LU pivots, solves, and retains determinant sign" {
    const matrix = [3][3]f64{
        .{ 0, 2, 1 },
        .{ 1, -2, -3 },
        .{ 4, -7, 1 },
    };
    const expected = [3]f64{ 1, 2, -1 };
    const rhs = matVec(matrix, expected);
    const factorization = lu(matrix, .{});
    try std.testing.expectEqual(FactorizationStatus.success, factorization.status);
    try std.testing.expectEqualDeep(expected, factorization.solve(rhs).?);
    try std.testing.expectApproxEqAbs(-25.0, factorization.determinant(), 1e-14);
}

test "Cholesky solves a symmetric positive-definite system" {
    const matrix = [3][3]f64{
        .{ 4, 12, -16 },
        .{ 12, 37, -43 },
        .{ -16, -43, 98 },
    };
    const factorization = cholesky(matrix, .{});
    try std.testing.expectEqual(FactorizationStatus.success, factorization.status);
    try std.testing.expectEqualDeep(
        [3]f64{ 1, 2, 3 },
        factorization.solve(matVec(matrix, [3]f64{ 1, 2, 3 })).?,
    );
}

test "Householder QR solves a tall least-squares problem" {
    const matrix = [4][2]f64{
        .{ 1, 1 },
        .{ 1, 2 },
        .{ 1, 3 },
        .{ 1, 4 },
    };
    const rhs = [4]f64{ 6, 5, 7, 10 };
    const solution = leastSquares(matrix, rhs, .{}).?;
    try std.testing.expectApproxEqAbs(3.5, solution[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.4, solution[1], 1e-12);
}
