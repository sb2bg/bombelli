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
    try writer.interface.flush();
}
