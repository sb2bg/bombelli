const std = @import("std");
const bombelli = @import("bombelli");

const sample_count = 2_000_000;
const rounds = 7;

const polynomial = bombelli.expr(
    "x^4/7 + y^3/5 + 3*x^2*y - 2*x*y^2 + x/11 - y/13",
).simplify();
const transcendental = bombelli.expr(
    "sin(x*y) + cos(x+y) + exp((x-y)/8) + x^3/7 - 2*x*y",
).simplify();

const Mode = enum {
    scalar,
    vector,
    parallel,
};

const Result = struct {
    nanoseconds: i96,
    checksum: f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const xs = try allocator.alloc(f64, sample_count);
    defer allocator.free(xs);
    const ys = try allocator.alloc(f64, sample_count);
    defer allocator.free(ys);
    const output = try allocator.alloc(f64, sample_count);
    defer allocator.free(output);

    fillInputs(xs, ys);
    try runProgram("polynomial", polynomial, xs, ys, output, init.io);
    try runProgram("transcendental", transcendental, xs, ys, output, init.io);
    try runThresholdSweep(polynomial, xs, ys, output, init.io);
}

fn runProgram(
    comptime name: []const u8,
    comptime program: bombelli.Expr,
    xs: []const f64,
    ys: []const f64,
    output: []f64,
    io: std.Io,
) !void {
    _ = try measure(program, .scalar, xs, ys, output, io);
    _ = try measure(program, .vector, xs, ys, output, io);
    _ = try measure(program, .parallel, xs, ys, output, io);

    var scalar_samples: [rounds]i96 = undefined;
    var vector_samples: [rounds]i96 = undefined;
    var parallel_samples: [rounds]i96 = undefined;
    var expected_checksum: ?f64 = null;
    for (0..rounds) |round| {
        const order = if (round % 2 == 0)
            [_]Mode{ .scalar, .vector, .parallel }
        else
            [_]Mode{ .parallel, .vector, .scalar };
        for (order) |mode| {
            const result = try measure(program, mode, xs, ys, output, io);
            if (expected_checksum) |expected| {
                if (!std.math.approxEqRel(f64, expected, result.checksum, 2e-13)) {
                    return error.ChecksumMismatch;
                }
            } else {
                expected_checksum = result.checksum;
            }
            switch (mode) {
                .scalar => scalar_samples[round] = result.nanoseconds,
                .vector => vector_samples[round] = result.nanoseconds,
                .parallel => parallel_samples[round] = result.nanoseconds,
            }
        }
    }

    const scalar_ns = median(&scalar_samples);
    const vector_ns = median(&vector_samples);
    const parallel_ns = median(&parallel_samples);
    std.debug.print(
        "{s}: scalar {d:.3} ns/item, vector {d:.3} ns/item ({d:.2}x), " ++
            "parallel {d:.3} ns/item ({d:.2}x), lanes {d}\n",
        .{
            name,
            perItem(scalar_ns),
            perItem(vector_ns),
            @as(f64, @floatFromInt(scalar_ns)) /
                @as(f64, @floatFromInt(vector_ns)),
            perItem(parallel_ns),
            @as(f64, @floatFromInt(scalar_ns)) /
                @as(f64, @floatFromInt(parallel_ns)),
            bombelli.testing.batchVectorLength,
        },
    );
}

fn measure(
    comptime program: bombelli.Expr,
    mode: Mode,
    xs: []const f64,
    ys: []const f64,
    output: []f64,
    io: std.Io,
) !Result {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    switch (mode) {
        .scalar => for (output, xs, ys) |*result, x, y| {
            result.* = program.eval(.{ .x = x, .y = y });
        },
        .vector => try program.evalBatchInto(output, .{ .x = xs, .y = ys }),
        .parallel => try program.evalBatchParallelInto(
            output,
            .{ .x = xs, .y = ys },
            .{},
        ),
    }
    const finished = std.Io.Clock.awake.now(io).nanoseconds;

    var checksum: f64 = 0.0;
    for (output) |value| checksum += value;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .nanoseconds = finished - started,
        .checksum = checksum,
    };
}

fn runThresholdSweep(
    comptime program: bombelli.Expr,
    xs: []const f64,
    ys: []const f64,
    output: []f64,
    io: std.Io,
) !void {
    inline for (.{ 131_072, 262_144, 524_288, 1_048_576 }) |count| {
        const batch_xs = xs[0..count];
        const batch_ys = ys[0..count];
        const batch_output = output[0..count];
        var vector_samples: [rounds]i96 = undefined;
        var parallel_samples: [rounds]i96 = undefined;
        for (0..rounds) |round| {
            vector_samples[round] = (try measure(
                program,
                .vector,
                batch_xs,
                batch_ys,
                batch_output,
                io,
            )).nanoseconds;
            parallel_samples[round] = (try measure(
                program,
                .parallel,
                batch_xs,
                batch_ys,
                batch_output,
                io,
            )).nanoseconds;
        }
        const vector_ns = median(&vector_samples);
        const parallel_ns = median(&parallel_samples);
        std.debug.print(
            "threshold {d}: vector {d:.3} ns/item, parallel {d:.3} " ++
                "ns/item ({d:.2}x)\n",
            .{
                count,
                perItemCount(vector_ns, count),
                perItemCount(parallel_ns, count),
                @as(f64, @floatFromInt(vector_ns)) /
                    @as(f64, @floatFromInt(parallel_ns)),
            },
        );
    }
}

fn fillInputs(xs: []f64, ys: []f64) void {
    var state: u64 = 0x6a09e667f3bcc909;
    for (xs, ys) |*x, *y| {
        state *%= 6364136223846793005;
        state +%= 1442695040888963407;
        const x_bits = state >> 11;
        state *%= 6364136223846793005;
        state +%= 1442695040888963407;
        const y_bits = state >> 11;
        const scale = 1.0 / 9007199254740992.0;
        x.* = @as(f64, @floatFromInt(x_bits)) * scale * 4.0 - 2.0;
        y.* = @as(f64, @floatFromInt(y_bits)) * scale * 4.0 - 2.0;
    }
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

fn perItem(nanoseconds: i96) f64 {
    return perItemCount(nanoseconds, sample_count);
}

fn perItemCount(nanoseconds: i96, count: usize) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) /
        @as(f64, @floatFromInt(count));
}
