const std = @import("std");
const bombelli = @import("bombelli");

const expression = bombelli.expr("sin(x*y) + x^3");
const generated = expression.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "generated_expression",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.writeAll(
        \\
        \\export fn call_generated(x: f64, y: f64) f64 {
        \\    var output: f64 = undefined;
        \\    generated_expression(.{ .x = x, .y = y }, &output);
        \\    return output;
        \\}
        \\
    );
    const expected = expression.eval(.{ .x = 1.25, .y = -0.75 });
    try writer.interface.print(
        \\
        \\test "emitted expression matches direct compiled object" {{
        \\    var output: f64 = undefined;
        \\    generated_expression(.{{ .x = 1.25, .y = -0.75 }}, &output);
        \\    try std.testing.expectApproxEqAbs({d}, output, 1e-15);
        \\}}
        \\
    , .{expected});
    try writer.interface.flush();
}
