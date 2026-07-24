const std = @import("std");
const bombelli = @import("bombelli");

const p = bombelli.expr(
    "(1 + x * y)^3 * z + y^2 * (1 + x * y) * (4 + 3 * x * y)",
);
const q = bombelli.expr(
    "y + 3 * x * (1 + x * y)^2 * z + 3 * x * y^2 * (4 + 3 * x * y)",
);
const r = bombelli.expr("2 * x - 3 * x^2 * y - x^3 * z");

const p_x = p.diff(.x).simplify();
const p_y = p.diff(.y).simplify();
const p_z = p.diff(.z).simplify();
const q_x = q.diff(.x).simplify();
const q_y = q.diff(.y).simplify();
const q_z = q.diff(.z).simplify();
const r_x = r.diff(.x).simplify();
const r_y = r.diff(.y).simplify();
const r_z = r.diff(.z).simplify();

const Point = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub fn main() void {
    for ([_]Point{
        .{ .x = 0.2, .y = 0.3, .z = 0.4 },
        .{ .x = -2.0, .y = 0.5, .z = 1.0 },
        .{ .x = 3.0, .y = -1.0, .z = 2.0 },
    }) |point| {
        std.debug.assert(@abs(jacobianDeterminant(point) + 2.0) < 1e-9);
    }

    const collision = [_]Point{
        .{ .x = 0, .y = 0, .z = -1.0 / 4.0 },
        .{ .x = 1, .y = -3.0 / 2.0, .z = 13.0 / 2.0 },
        .{ .x = -1, .y = 3.0 / 2.0, .z = 13.0 / 2.0 },
    };

    for (collision) |point| {
        const image = map(point);
        const determinant = jacobianDeterminant(point);
        std.debug.assert(@abs(determinant + 2.0) < 1e-12);
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
                determinant,
            },
        );
    }
}

fn map(point: Point) [3]f64 {
    return .{
        p.eval(point),
        q.eval(point),
        r.eval(point),
    };
}

fn jacobianDeterminant(point: Point) f64 {
    const px = p_x.eval(point);
    const py = p_y.eval(point);
    const pz = p_z.eval(point);
    const qx = q_x.eval(point);
    const qy = q_y.eval(point);
    const qz = q_z.eval(point);
    const rx = r_x.eval(point);
    const ry = r_y.eval(point);
    const rz = r_z.eval(point);

    return px * (qy * rz - qz * ry) -
        py * (qx * rz - qz * rx) +
        pz * (qx * ry - qy * rx);
}
