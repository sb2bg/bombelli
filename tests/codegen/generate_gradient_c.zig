const std = @import("std");
const cases = @import("cases.zig");

const generated = cases.gradient.emit(.{
    .target = .c,
    .mode = .out_of_place,
    .name = "generated_gradient",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}
