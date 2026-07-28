//! Exact symbolic determinants over Bombelli polynomial matrices.

const ast = @import("../../expression.zig");
const exact = @import("../core/exact.zig");
const multi = @import("../transform/multi.zig");
const polynomial = @import("polynomial.zig");

/// Computes a square expression matrix's determinant with fraction-free
/// Bareiss elimination.
///
/// Every entry must be an exact polynomial.  Unlike floating-point Gaussian
/// elimination, this operation neither samples the expressions nor introduces
/// roundoff or rational-function denominator conditions.
pub fn determinant(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) ast.Expr {
    if (R != C) {
        @compileError("Bombelli symbolic determinant requires a square matrix");
    }
    if (R == 0) {
        @compileError("Bombelli symbolic determinant requires a non-empty matrix");
    }

    var matrix: [R][R]polynomial.Polynomial = undefined;
    inline for (0..R) |row| {
        inline for (0..R) |column| {
            matrix[row][column] =
                multi.matrixElement(R, R, expression, row, column)
                    .asPolynomial();
        }
    }
    if (R == 1) return matrix[0][0].toExpr();

    var previous_pivot = polynomial.exactConstant(
        exact.Rational.fromInteger(1),
    );
    var swap_count: usize = 0;

    for (0..R - 1) |pivot_index| {
        var pivot_row: ?usize = null;
        for (pivot_index..R) |candidate| {
            if (matrix[candidate][pivot_index].terms.len != 0) {
                pivot_row = candidate;
                break;
            }
        }
        if (pivot_row == null) {
            return polynomial.exactConstant(
                exact.Rational.fromInteger(0),
            ).toExpr();
        }
        if (pivot_row.? != pivot_index) {
            const temporary = matrix[pivot_index];
            matrix[pivot_index] = matrix[pivot_row.?];
            matrix[pivot_row.?] = temporary;
            swap_count += 1;
        }

        const old = matrix;
        const pivot = old[pivot_index][pivot_index];
        for (pivot_index + 1..R) |row| {
            for (pivot_index + 1..R) |column| {
                const numerator = pivot.mul(old[row][column]).sub(
                    old[row][pivot_index].mul(old[pivot_index][column]),
                );
                matrix[row][column] = numerator.divideExact(
                    previous_pivot,
                ) orelse @compileError(
                    "Bombelli symbolic determinant encountered a non-exact Bareiss division",
                );
            }
            matrix[row][pivot_index] = polynomial.exactConstant(
                exact.Rational.fromInteger(0),
            );
        }
        previous_pivot = pivot;
    }

    const result = if (swap_count % 2 == 0)
        matrix[R - 1][R - 1]
    else
        matrix[R - 1][R - 1].scale(exact.Rational.fromInteger(-1));
    return result.toExpr();
}
