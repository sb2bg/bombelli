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

    try out.flush();
}
