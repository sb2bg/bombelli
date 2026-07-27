const std = @import("std");
const bombelli = @import("bombelli");
const generated = @import("generated");

const expression = bombelli.expr(
    "9007199254740993 / 7 + 1e300 + sin(x*y) + x^3",
);

test "emitted expression matches direct compiled object" {
    const inputs = .{ .x = 1.25, .y = -0.75 };
    var actual: f64 = undefined;
    generated.generated_expression(inputs, &actual);

    try std.testing.expectApproxEqAbs(
        expression.eval(inputs),
        actual,
        1e-15,
    );
}
