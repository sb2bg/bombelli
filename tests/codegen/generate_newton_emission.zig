const std = @import("std");
const bombelli = @import("bombelli");

const solver = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
}).compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
});
const generated = solver.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "generated_newton",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}
