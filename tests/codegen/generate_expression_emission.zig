const std = @import("std");
const bombelli = @import("bombelli");

const expression = bombelli.expr(
    "9007199254740993 / 7 + 1e300 + sin(x*y) + x^3",
);
const generated = expression.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "generated_expression",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}
