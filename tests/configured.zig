const std = @import("std");
const bombelli = @import("bombelli");

// Deliberately not a power of two: hash capacity is rounded independently.
pub const bombelli_options: bombelli.Options = .{ .construction_nodes = 4097 };

const variables = .{
    .x00, .x01, .x02, .x03, .x04, .x05, .x06, .x07,
    .x08, .x09, .x10, .x11, .x12, .x13, .x14, .x15,
    .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
    .x24, .x25, .x26, .x27, .x28, .x29, .x30, .x31,
};
const names = blk: {
    var result: [32][]const u8 = undefined;
    for (variables, 0..) |tag, i| result[i] = @tagName(tag);
    break :blk result;
};
const model = blk: {
    var sum: []const u8 = names[0];
    for (names[1..]) |name| sum = sum ++ "+" ++ name;
    var sources: @Tuple(&([_]type{[]const u8} ** 32)) = undefined;
    for (names, 0..) |name, i| sources[i] = name ++ "*sin(" ++ sum ++ ")";
    break :blk bombelli.model(sources, .{ .variables = variables });
};
const jacobian = model.jacobian().simplify();

pub fn main() !void {
    const metrics = comptime jacobian.metrics();
    try std.testing.expect(metrics.construction_peak_nodes > 1024);
    try std.testing.expectEqual(4097 - metrics.construction_peak_nodes, metrics.constructionHeadroom());
    // Named input fields follow the model's symbol contract.
    const Inputs = @Struct(.auto, null, &names, &([_]type{f64} ** 32), &([_]std.builtin.Type.StructField.Attributes{.{}} ** 32));
    var point: Inputs = undefined;
    var sum: f64 = 0;
    inline for (names, 0..) |name, i| {
        const value = 0.01 + @as(f64, @floatFromInt(i)) * 0.001;
        @field(point, name) = value;
        sum += value;
    }
    const actual = jacobian.eval(point);
    for (0..32) |r| {
        for (0..32) |c| {
            const x = 0.01 + @as(f64, @floatFromInt(r)) * 0.001;
            const expected = x * @cos(sum) + (if (r == c) @sin(sum) else 0.0);
            try std.testing.expectApproxEqAbs(expected, actual[r][c], 1e-12);
        }
    }
}
