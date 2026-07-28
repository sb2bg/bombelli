const std = @import("std");
const bombelli = @import("bombelli");

const Observation = struct {
    time: f64,
    response: f64,
};

const fit = bombelli.residualModel(.{
    "offset + amplitude*exp(-rate*time) - response",
}, .{
    .variables = .{ .amplitude, .rate, .offset },
    .data = .{ .time, .response },
}).leastSquares().compile(.{
    .algorithm = .levenberg_marquardt,
    .jacobian = .symbolic,
    .linear_solver = .streaming_qr,
    .bounds = .{
        .amplitude = .{ .lower = 0.0 },
        .rate = .{ .lower = 0.0 },
    },
    .tolerance = 1e-11,
});

pub fn main() void {
    const observations = [_]Observation{
        .{ .time = 0.0, .response = 3.500000 },
        .{ .time = 0.5, .response = 2.510960 },
        .{ .time = 1.0, .response = 1.847987 },
        .{ .time = 1.5, .response = 1.403583 },
        .{ .time = 2.0, .response = 1.105690 },
        .{ .time = 2.5, .response = 0.906006 },
        .{ .time = 3.0, .response = 0.772154 },
        .{ .time = 3.5, .response = 0.682430 },
    };
    const result = fit.eval(.{
        .initial = .{
            .amplitude = 2.0,
            .rate = 0.5,
            .offset = 0.0,
        },
        .observations = &observations,
    });

    std.debug.print(
        "status={s}, amplitude={d:.6}, rate={d:.6}, offset={d:.6}, cost={e:.3}\n",
        .{
            @tagName(result.status),
            fit.parameter(result, .amplitude),
            fit.parameter(result, .rate),
            fit.parameter(result, .offset),
            result.cost,
        },
    );
}
