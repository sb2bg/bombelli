const std = @import("std");
const bombelli = @import("bombelli");

const iterations = 5_000_000;
const program = bombelli.expr(
    "sin(x*y) + cos(x+y) + exp((x-y)/8) + x^3/7 - 2*x*y",
).simplify();

pub fn main() void {
    var state: u64 = 0x6a09e667f3bcc909;
    var total: f64 = 0.0;
    for (0..iterations) |_| {
        const point = nextPoint(&state);
        total += program.eval(point);
    }
    std.mem.doNotOptimizeAway(total);
    std.debug.print("{d:.17}\n", .{total});
}

fn nextPoint(state: *u64) struct { x: f64, y: f64 } {
    state.* *%= 6364136223846793005;
    state.* +%= 1442695040888963407;
    const x_bits = state.* >> 11;
    state.* *%= 6364136223846793005;
    state.* +%= 1442695040888963407;
    const y_bits = state.* >> 11;
    const scale = 1.0 / 9007199254740992.0;
    return .{
        .x = @as(f64, @floatFromInt(x_bits)) * scale * 4.0 - 2.0,
        .y = @as(f64, @floatFromInt(y_bits)) * scale * 4.0 - 2.0,
    };
}
