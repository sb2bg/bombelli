const std = @import("std");
const bombelli = @import("bombelli");

const order = 8;
const rounds = 7;
const nodes = [_]f64{
    -0.96028985649753618,
    -0.79666647741362673,
    -0.52553240991632899,
    -0.18343464249564981,
    0.18343464249564981,
    0.52553240991632899,
    0.79666647741362673,
    0.96028985649753618,
};
const weights = [_]f64{
    0.10122853629037637,
    0.22238103445337418,
    0.31370664587788744,
    0.36268378337836205,
    0.36268378337836205,
    0.31370664587788744,
    0.22238103445337418,
    0.10122853629037637,
};

const polynomial = bombelli.expr(
    "x^8/17 - 3*x^6/13 + k*x^4/11 - 2*x^2/7 + 1",
).simplify();
const polynomial_rule = polynomial.quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = order,
});

const transcendental = bombelli.expr("exp(-k*x^2)").simplify();
const transcendental_rule = transcendental.quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = order,
});

const Mode = enum {
    scalar,
    selected,
};

pub fn main(init: std.process.Init) !void {
    try runCase(
        "quadrature polynomial",
        polynomial,
        polynomial_rule,
        400_000,
        init.io,
    );
    try runCase(
        "quadrature transcendental",
        transcendental,
        transcendental_rule,
        100_000,
        init.io,
    );
}

fn runCase(
    comptime name: []const u8,
    comptime integrand: bombelli.Expr,
    comptime rule: anytype,
    iterations: usize,
    io: std.Io,
) !void {
    _ = measure(integrand, rule, .scalar, iterations, io);
    _ = measure(integrand, rule, .selected, iterations, io);

    var scalar_samples: [rounds]i96 = undefined;
    var selected_samples: [rounds]i96 = undefined;
    var scalar_checksum: f64 = 0.0;
    var selected_checksum: f64 = 0.0;
    for (0..rounds) |round| {
        const first: Mode = if (round % 2 == 0) .scalar else .selected;
        const second: Mode = if (first == .scalar) .selected else .scalar;
        inline for (0..2) |index| {
            const mode = if (index == 0) first else second;
            const result = measure(integrand, rule, mode, iterations, io);
            switch (mode) {
                .scalar => {
                    scalar_samples[round] = result.nanoseconds;
                    scalar_checksum = result.checksum;
                },
                .selected => {
                    selected_samples[round] = result.nanoseconds;
                    selected_checksum = result.checksum;
                },
            }
        }
    }
    if (!std.math.approxEqRel(
        f64,
        scalar_checksum,
        selected_checksum,
        2e-13,
    )) {
        return error.ChecksumMismatch;
    }

    const scalar_ns = median(&scalar_samples);
    const selected_ns = median(&selected_samples);
    std.debug.print(
        "{s}: scalar {d:.3} ns/integral, selected {d:.3} ns/integral " ++
            "({d:.2}x), order {d}, lanes {d}\n",
        .{
            name,
            perIntegral(scalar_ns, iterations),
            perIntegral(selected_ns, iterations),
            @as(f64, @floatFromInt(scalar_ns)) /
                @as(f64, @floatFromInt(selected_ns)),
            order,
            bombelli.testing.batchVectorLength,
        },
    );
}

const Result = struct {
    nanoseconds: i96,
    checksum: f64,
};

fn measure(
    comptime integrand: bombelli.Expr,
    comptime rule: anytype,
    mode: Mode,
    iterations: usize,
    io: std.Io,
) Result {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    var checksum: f64 = 0.0;
    for (0..iterations) |index| {
        const phase = @as(f64, @floatFromInt(index % 1024)) / 1024.0;
        const from = -1.0 + phase * 0.01;
        const to = 1.0 + phase * 0.02;
        const k = 1.25 + phase * 0.5;
        checksum += switch (mode) {
            .scalar => scalarQuadrature(integrand, from, to, k),
            .selected => rule.eval(.{ .from = from, .to = to, .k = k }),
        };
    }
    const finished = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .nanoseconds = finished - started,
        .checksum = checksum,
    };
}

inline fn scalarQuadrature(
    comptime integrand: bombelli.Expr,
    from: f64,
    to: f64,
    k: f64,
) f64 {
    const midpoint = (from + to) * 0.5;
    const half_width = (to - from) * 0.5;
    var weighted_sum: f64 = 0.0;
    inline for (nodes, weights) |node, weight| {
        const point = midpoint + half_width * node;
        weighted_sum += weight * integrand.eval(.{ .x = point, .k = k });
    }
    return half_width * weighted_sum;
}

fn median(samples: *[rounds]i96) i96 {
    var index: usize = 1;
    while (index < samples.len) : (index += 1) {
        const value = samples[index];
        var insertion = index;
        while (insertion > 0 and samples[insertion - 1] > value) : (insertion -= 1) {
            samples[insertion] = samples[insertion - 1];
        }
        samples[insertion] = value;
    }
    return samples[samples.len / 2];
}

fn perIntegral(nanoseconds: i96, iterations: usize) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) /
        @as(f64, @floatFromInt(iterations));
}
