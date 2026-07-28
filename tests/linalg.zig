const std = @import("std");
const bombelli = @import("bombelli");

test "public fixed-size linear algebra composes through native arrays" {
    const matrix = [3][3]f64{
        .{ 0, 2, 1 },
        .{ 1, -2, -3 },
        .{ 4, -7, 1 },
    };
    const expected = [3]f64{ 1, 2, -1 };
    const rhs = bombelli.linalg.matVec(matrix, expected);
    const actual = bombelli.linalg.solve(matrix, rhs, .{}).?;
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectApproxEqAbs(
        -25.0,
        bombelli.linalg.determinant(matrix, .{}),
        1e-14,
    );
}

test "public matrix utilities cover inversion geometry and SPD solves" {
    const matrix = [2][2]f64{
        .{ 4, 1 },
        .{ 1, 3 },
    };
    const inverse = bombelli.linalg.inverse(matrix, .{}).?;
    try std.testing.expectApproxEqAbs(
        1.0,
        bombelli.linalg.matMul(matrix, inverse)[0][0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        1.0,
        bombelli.linalg.matMul(matrix, inverse)[1][1],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        7.0,
        bombelli.linalg.trace(matrix),
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @sqrt(27.0),
        bombelli.linalg.normFrobenius(matrix),
        1e-14,
    );

    const expected = [2]f64{ 2, -1 };
    const rhs = bombelli.linalg.matVec(matrix, expected);
    const solved = bombelli.linalg.solvePositiveDefinite(matrix, rhs, .{}).?;
    try std.testing.expectApproxEqAbs(expected[0], solved[0], 1e-14);
    try std.testing.expectApproxEqAbs(expected[1], solved[1], 1e-14);
    try std.testing.expectEqualDeep(
        [2][3]f64{
            .{ 3, 4, 5 },
            .{ -6, -8, -10 },
        },
        bombelli.linalg.outer(
            [2]f64{ 1, -2 },
            [3]f64{ 3, 4, 5 },
        ),
    );
}
