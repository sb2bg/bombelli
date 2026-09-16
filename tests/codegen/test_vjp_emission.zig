const std = @import("std");
const cases = @import("cases.zig");
const generated = @import("generated");

test "emitted reverse product matches native evaluation" {
    var actual: [2]f64 = undefined;
    generated.generated_vjp(cases.emitted_product_inputs, &actual);
    const expected = cases.vjp.eval(cases.product_inputs, cases.product_seed);
    for (expected, actual) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-14);
}
