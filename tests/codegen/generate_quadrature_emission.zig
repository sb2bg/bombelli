const std = @import("std");
const bombelli = @import("bombelli");

const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 16,
});
const generated = rule.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "generated_quadrature",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.writeAll(
        \\
        \\export fn call_generated(from: f64, to: f64, k: f64) f64 {
        \\    var output: f64 = undefined;
        \\    generated_quadrature(
        \\        .{ .from = from, .to = to, .k = k },
        \\        &output,
        \\    );
        \\    return output;
        \\}
        \\
    );
    const expected = rule.eval(.{
        .from = 0.0,
        .to = 1.0,
        .k = 2.0,
    });
    try writer.interface.print(
        \\
        \\test "emitted quadrature matches direct compiled object" {{
        \\    var output: f64 = undefined;
        \\    generated_quadrature(
        \\        .{{ .from = 0.0, .to = 1.0, .k = 2.0 }},
        \\        &output,
        \\    );
        \\    try std.testing.expectApproxEqAbs({d}, output, 1e-15);
        \\}}
        \\
    , .{expected});
    try writer.interface.flush();
}
