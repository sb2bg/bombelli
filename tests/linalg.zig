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
