const std = @import("std");
const bombelli = @import("bombelli");

const generated = bombelli.expr("exp(-k*x^2)").quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 16,
}).emit(.{
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
    try writer.interface.flush();
}
