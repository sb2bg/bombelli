const std = @import("std");
const bombelli = @import("bombelli");

// NIST Statistical Reference Dataset Misra1a:
// https://www.itl.nist.gov/div898/strd/nls/data/LINKS/DATA/Misra1a.dat
//
// Volume is modeled as b1 * (1 - exp(-b2 * pressure)). The values below,
// both starting points, and the certified results are copied from the
// official dataset file.
const pressures = [14]f64{
    77.6,
    114.9,
    141.1,
    190.8,
    239.9,
    289.0,
    332.8,
    378.4,
    434.8,
    477.3,
    536.8,
    593.1,
    689.1,
    760.0,
};

const volumes = [14]f64{
    10.07,
    14.73,
    17.94,
    23.93,
    29.61,
    35.18,
    40.02,
    44.82,
    50.76,
    55.05,
    61.01,
    66.40,
    75.47,
    81.78,
};

const Observation = struct { pressure: f64, volume: f64 };

fn observations() [pressures.len]Observation {
    var result: [pressures.len]Observation = undefined;
    for (&result, pressures, volumes) |*observation, pressure, volume| {
        observation.* = .{ .pressure = pressure, .volume = volume };
    }
    return result;
}

fn expectCertified(
    result: anytype,
    data: []const Observation,
) !void {
    const certified_b1 = 2.3894212918e2;
    const certified_b2 = 5.5015643181e-4;
    const certified_half_rss = 0.5 * 1.2455138894e-1;
    var computed_half_rss: f64 = 0.0;
    for (data) |observation| {
        const residual = result.values[0] *
            (1.0 - @exp(-result.values[1] * observation.pressure)) -
            observation.volume;
        computed_half_rss += 0.5 * residual * residual;
    }

    try std.testing.expect(result.converged());
    try std.testing.expectApproxEqAbs(
        computed_half_rss,
        result.cost,
        1e-15,
    );
    try std.testing.expectApproxEqRel(
        certified_b1,
        result.values[0],
        5e-7,
    );
    try std.testing.expectApproxEqRel(
        certified_b2,
        result.values[1],
        5e-7,
    );
    try std.testing.expectApproxEqRel(
        certified_half_rss,
        result.cost,
        5e-7,
    );
}

test "NIST Misra1a reaches certified parameters and half-RSS from both starts" {
    const solver = comptime bombelli.residualModel(.{
        "b1*(1-exp(-b2*pressure))-volume",
    }, .{
        .variables = .{ .b1, .b2 },
        .data = .{ .pressure, .volume },
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .linear_solver = .streaming_qr,
        .max_iterations = 128,
        .tolerance = 1e-12,
        .function_tolerance = 1e-14,
    });

    const data = observations();
    const start_1 = solver.eval(.{
        .initial = .{ .b1 = 500.0, .b2 = 1e-4 },
        .observations = &data,
    });
    const start_2 = solver.eval(.{
        .initial = .{ .b1 = 250.0, .b2 = 5e-4 },
        .observations = &data,
    });

    try expectCertified(start_1, &data);
    try expectCertified(start_2, &data);
}
