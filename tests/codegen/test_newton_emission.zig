const std = @import("std");
const bombelli = @import("bombelli");
const generated = @import("generated");

const solver = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
}).compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
});

test "emitted Newton solver matches direct compiled object" {
    const inputs = .{
        .initial = .{ .x = 0.7, .y = 0.7 },
        .r = 1.0,
    };
    var actual: generated.generated_newtonResult = undefined;
    generated.generated_newton(inputs, &actual);
    const expected = solver.eval(inputs);

    try std.testing.expectEqual(
        @intFromEnum(expected.status),
        @intFromEnum(actual.status),
    );
    try std.testing.expectEqual(expected.iterations, actual.iterations);
    try std.testing.expectApproxEqAbs(
        expected.values[0],
        actual.values[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        expected.values[1],
        actual.values[1],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        expected.residual_norm,
        actual.residual_norm,
        1e-20,
    );
}
