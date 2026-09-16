const std = @import("std");
const bombelli = @import("bombelli");

// Deliberately not a power of two: hash capacity is rounded independently.
pub const bombelli_options: bombelli.Options = .{ .construction_nodes = 1031 };

// One symbol, 512 distinct integers, and 512 additions cross the default
// 1,024-node boundary without constructing a dense Jacobian.
const term_count = 512;
const expression = blk: {
    @setEvalBranchQuota(100_000);
    break :blk bombelli.expr("x+" ++ integerSum(1, term_count));
};
const simplified = expression.simplify();
const derivative = expression.diff(.x).simplify();

fn integerSum(comptime first: usize, comptime count: usize) []const u8 {
    if (count == 1) return std.fmt.comptimePrint("{d}", .{first});
    const half = count / 2;
    return "(" ++ integerSum(first, half) ++ "+" ++ integerSum(first + half, count - half) ++ ")";
}

pub fn main() !void {
    const metrics = comptime expression.metrics();
    try std.testing.expectEqual(1025, metrics.node_count);
    try std.testing.expectEqual(1025, metrics.construction_peak_nodes);
    try std.testing.expectEqual(6, metrics.constructionHeadroom());

    const expected_sum: f64 = term_count * (term_count + 1) / 2;
    for ([_]f64{ -2.5, 0.0, 0.25 }) |x| {
        try std.testing.expectEqual(expected_sum + x, expression.eval(.{ .x = x }));
        try std.testing.expectEqual(expected_sum + x, simplified.eval(.{ .x = x }));
        try std.testing.expectEqual(@as(f64, 1), derivative.eval(.{}));
    }
}
