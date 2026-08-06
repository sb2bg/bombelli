const std = @import("std");
const bombelli = @import("bombelli");

const map_program = bombelli.exprVector(.{
    "(1 + x * y)^3 * z + y^2 * (1 + x * y) * (4 + 3 * x * y)",
    "y + 3 * x * (1 + x * y)^2 * z + 3 * x * y^2 * (4 + 3 * x * y)",
    "2 * x - 3 * x^2 * y - x^3 * z",
});
const determinant = map_program.jacobian(.{ .x, .y, .z }).determinant().simplify();

comptime {
    if (!std.mem.eql(u8, determinant.render(), "-2")) {
        @compileError("the Jacobian determinant is not exactly -2");
    }
}

const Point = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub fn main() void {
    const collision = [_]Point{
        .{ .x = 0, .y = 0, .z = -1.0 / 4.0 },
        .{ .x = 1, .y = -3.0 / 2.0, .z = 13.0 / 2.0 },
        .{ .x = -1, .y = 3.0 / 2.0, .z = 13.0 / 2.0 },
    };

    for (collision) |point| {
        const image = map_program.eval(point);
        std.debug.assert(@abs(image[0] + 0.25) < 1e-12);
        std.debug.assert(@abs(image[1]) < 1e-12);
        std.debug.assert(@abs(image[2]) < 1e-12);

        std.debug.print(
            "F({d}, {d}, {d}) = ({d}, {d}, {d}), det JF = {d}\n",
            .{
                point.x,
                point.y,
                point.z,
                image[0],
                image[1],
                image[2],
                determinant.eval(point),
            },
        );
    }
}
