//! Prints the values Bombelli's own evaluator produces for every emission
//! case. The C drivers print the same labels from emitted C, and the
//! validation script compares the two.

const std = @import("std");
const cases = @import("cases.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &writer.interface;

    try out.print("expression {d:.17}\n", .{
        cases.expression.eval(cases.expression_inputs),
    });
    try out.print("smooth_expression {d:.17}\n", .{
        cases.smooth_expression.eval(cases.smooth_expression_inputs),
    });
    const gradient = cases.gradient.eval(cases.gradient_inputs);
    try out.print("gradient_x {d:.17}\n", .{gradient[0]});
    try out.print("gradient_y {d:.17}\n", .{gradient[1]});

    try out.print("quadrature {d:.17}\n", .{
        cases.rule.eval(cases.rule_inputs),
    });

    const solved = cases.solver.eval(cases.solver_inputs);
    try out.print("newton_status {d}\n", .{@intFromEnum(solved.status)});
    try out.print("newton_iterations {d}\n", .{solved.iterations});
    try out.print("newton_x {d:.17}\n", .{solved.values[0]});
    try out.print("newton_y {d:.17}\n", .{solved.values[1]});
    try out.print("newton_residual_norm {d:.17}\n", .{solved.residual_norm});

    const fitted = cases.fitter.eval(cases.fitter_inputs);
    try out.print("fitter_status {d}\n", .{@intFromEnum(fitted.status)});
    try out.print("fitter_iterations {d}\n", .{fitted.iterations});
    try out.print("fitter_rank {d}\n", .{fitted.rank});
    try out.print("fitter_function_evaluations {d}\n", .{fitted.function_evaluations});
    try out.print("fitter_offset {d:.17}\n", .{fitted.values[0]});
    try out.print("fitter_slope {d:.17}\n", .{fitted.values[1]});
    try out.print("fitter_cost {d:.17}\n", .{fitted.cost});
    try out.print("fitter_gradient_norm {d:.17}\n", .{fitted.gradient_norm});

    const empty_fit = cases.fitter.eval(.{
        .initial = cases.fitter_inputs.initial,
        .observations = cases.fit_observations[0..0],
    });
    try out.print("fitter_empty_status {d}\n", .{@intFromEnum(empty_fit.status)});
    const infeasible_fit = cases.fitter.eval(.{
        .initial = .{ .offset = 0.5, .slope = -0.5 },
        .observations = cases.fit_observations[0..],
    });
    try out.print("fitter_infeasible_status {d}\n", .{@intFromEnum(infeasible_fit.status)});
    var bad_fit_observations = cases.fit_observations;
    bad_fit_observations[2].y = std.math.nan(f64);
    const nonfinite_fit = cases.fitter.eval(.{
        .initial = cases.fitter_inputs.initial,
        .observations = bad_fit_observations[0..],
    });
    try out.print("fitter_nonfinite_observation_status {d}\n", .{
        @intFromEnum(nonfinite_fit.status),
    });

    try out.flush();
}
