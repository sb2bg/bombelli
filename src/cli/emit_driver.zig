const std = @import("std");
const bombelli = @import("bombelli");
const options = @import("cli_options");

const target: bombelli.EmitTarget = if (std.mem.eql(
    u8,
    options.target,
    "zig",
))
    .zig
else
    .c;

const generated = bombelli.expr(options.expression).emit(.{
    .target = target,
    .mode = .out_of_place,
    .name = options.name,
});

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}
