const std = @import("std");
const cases = @import("cases.zig");

const expression_zig = emit(cases.expression, .zig, "generated_expression");
const expression_c = emit(cases.expression, .c, "generated_expression");
const smooth_expression_zig = emit(
    cases.smooth_expression,
    .zig,
    "generated_smooth_expression",
);
const smooth_expression_c = emit(
    cases.smooth_expression,
    .c,
    "generated_smooth_expression",
);
const gradient_zig = emit(cases.gradient, .zig, "generated_gradient");
const gradient_c = emit(cases.gradient, .c, "generated_gradient");
const quadrature_zig = emit(cases.rule, .zig, "generated_quadrature");
const quadrature_c = emit(cases.rule, .c, "generated_quadrature");
const newton_zig = emit(cases.solver, .zig, "generated_newton");
const newton_c = emit(cases.solver, .c, "generated_newton");
const fitter_zig = emit(cases.fitter, .zig, "generated_fitter");
const fitter_c = emit(cases.fitter, .c, "generated_fitter");

fn emit(comptime value: anytype, comptime target: anytype, comptime name: []const u8) []const u8 {
    return value.emit(.{ .target = target, .name = name });
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const case = args.next() orelse return error.MissingCase;
    const target = args.next() orelse return error.MissingTarget;
    if (args.next() != null) return error.UnexpectedArgument;

    const generated = generatedSource(case, target) orelse
        return error.UnknownCaseOrTarget;
    var buffer: [65536]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(generated);
    try writer.interface.flush();
}

fn generatedSource(case: []const u8, target: []const u8) ?[]const u8 {
    const zig = std.mem.eql(u8, target, "zig");
    const c = std.mem.eql(u8, target, "c");
    if (!zig and !c) return null;
    if (std.mem.eql(u8, case, "expression")) return if (zig) expression_zig else expression_c;
    if (std.mem.eql(u8, case, "smooth_expression")) return if (zig)
        smooth_expression_zig
    else
        smooth_expression_c;
    if (std.mem.eql(u8, case, "gradient")) return if (zig) gradient_zig else gradient_c;
    if (std.mem.eql(u8, case, "quadrature")) return if (zig) quadrature_zig else quadrature_c;
    if (std.mem.eql(u8, case, "newton")) return if (zig) newton_zig else newton_c;
    if (std.mem.eql(u8, case, "fitter")) return if (zig) fitter_zig else fitter_c;
    return null;
}
