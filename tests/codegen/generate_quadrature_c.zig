const std = @import("std");
const cases = @import("cases.zig");

const generated = cases.rule.emit(.{
    .target = .c,
    .mode = .out_of_place,
    .name = "generated_quadrature",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}
