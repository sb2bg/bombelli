const std = @import("std");
const bombelli = @import("bombelli");

const model = bombelli.model(.{
    "x*sin(x+y+z)",
    "y*sin(x+y+z)",
    "z*sin(x+y+z)",
}, .{ .variables = .{ .x, .y, .z } });
const forward = model.compileJvp(.{});
const reverse = model.compileVjp(.{});

pub fn main() void {
    const point = .{ .x = 0.2, .y = 0.3, .z = 0.4 };
    const tangent = [3]f64{ 1, -2, 3 };
    const cotangent = [3]f64{ 0.5, 1, -0.5 };
    std.debug.print("Jv = {any}\nJ^T v = {any}\n", .{
        forward.eval(point, tangent),
        reverse.eval(point, cotangent),
    });
    inline for (.{ forward, reverse }) |compiled| {
        const info = comptime compiled.inspect();
        std.debug.print(
            "{s}: {d} operations, {d} logical scalar slots ({d} peak live), {d} shared nodes; " ++
                "{d}/{d} structurally nonzero Jacobian entries\n" ++
                "  estimated direct/symbolic operations: {d}/{d}\n",
            .{
                @tagName(info.method),              info.operations,          info.temporary_scalars, info.peak_live_values,
                info.shared_nodes,                  info.structural_nonzeros, info.jacobian_entries,  info.estimated_direct_operations,
                info.estimated_symbolic_operations,
            },
        );
    }
}
