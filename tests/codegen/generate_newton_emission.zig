const std = @import("std");
const bombelli = @import("bombelli");

const generated = bombelli.system(.{
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
}).emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "generated_newton",
});

pub fn main(init: std.process.Init) !void {
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.writeAll(
        \\
        \\export fn call_generated(
        \\    initial_x: f64,
        \\    initial_y: f64,
        \\    r: f64,
        \\    values: *[2]f64,
        \\    status: *u8,
        \\) void {
        \\    var output: generated_newtonResult = undefined;
        \\    generated_newton(
        \\        .{
        \\            .initial = .{ .x = initial_x, .y = initial_y },
        \\            .r = r,
        \\        },
        \\        &output,
        \\    );
        \\    values.* = output.values;
        \\    status.* = @intFromEnum(output.status);
        \\}
        \\
    );
    try writer.interface.flush();
}
