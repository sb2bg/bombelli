const std = @import("std");
const ast = @import("ast.zig");
const domain = @import("domain.zig");
const equation_module = @import("equation.zig");
const multi = @import("multi.zig");
const problem = @import("problem.zig");

pub fn SystemType(comptime Sources: type, comptime Options: type) type {
    return problem.SystemProblem(
        ast.tupleLength(Sources),
        ast.tupleLength(@FieldType(Options, "unknowns")),
        assumptionsType(Options),
    );
}

pub fn EquationProblemType(comptime Options: type) type {
    return problem.EquationProblem(
        ast.tupleLength(@FieldType(Options, "unknowns")),
        assumptionsType(Options),
    );
}

pub fn make(
    comptime sources: anytype,
    comptime options: anytype,
) problem.SystemProblem(
    ast.tupleLength(@TypeOf(sources)),
    ast.tupleLength(@TypeOf(options.unknowns)),
    assumptionsType(@TypeOf(options)),
) {
    const M = comptime ast.tupleLength(@TypeOf(sources));
    const N = comptime ast.tupleLength(@TypeOf(options.unknowns));
    const Assumptions = assumptionsType(@TypeOf(options));
    if (M == 0) @compileError("Bombelli system expects at least one equation");
    if (N == 0) @compileError("Bombelli system requires explicit unknowns");

    const equations = comptime blk: {
        var values: [M]equation_module.Equation = undefined;
        for (sources, 0..) |source, index| {
            values[index] = equation_module.parse(source);
        }
        break :blk values;
    };
    const residuals = comptime blk: {
        var values: [M]ast.Expr = undefined;
        for (equations, 0..) |parsed, index| {
            values[index] = parsed.residual;
        }
        break :blk values;
    };

    const unknowns = comptime blk: {
        var values: [N][]const u8 = undefined;
        for (options.unknowns, 0..) |unknown, index| {
            values[index] = @tagName(unknown);
            for (0..index) |previous| {
                if (std.mem.eql(u8, values[previous], values[index])) {
                    @compileError("Bombelli system unknowns must be unique");
                }
            }
        }
        break :blk values;
    };

    const assumptions: Assumptions = if (@hasField(@TypeOf(options), "assumptions"))
        options.assumptions
    else
        .{};
    return .{
        .equations = equations,
        .residuals = multi.vector(M, residuals),
        .unknowns = unknowns,
        .domain = @as(domain.Domain, options.domain),
        .assumptions = assumptions,
    };
}

pub fn makeEquationProblem(
    comptime source: []const u8,
    comptime options: anytype,
) problem.EquationProblem(
    ast.tupleLength(@TypeOf(options.unknowns)),
    assumptionsType(@TypeOf(options)),
) {
    const N = comptime ast.tupleLength(@TypeOf(options.unknowns));
    const Assumptions = assumptionsType(@TypeOf(options));
    if (N == 0) @compileError("Bombelli equation problem requires explicit unknowns");
    const unknowns = comptime blk: {
        var values: [N][]const u8 = undefined;
        for (options.unknowns, 0..) |unknown, index| {
            values[index] = @tagName(unknown);
            for (0..index) |previous| {
                if (std.mem.eql(u8, values[previous], values[index])) {
                    @compileError("Bombelli equation problem unknowns must be unique");
                }
            }
        }
        break :blk values;
    };
    const assumptions: Assumptions = if (@hasField(@TypeOf(options), "assumptions"))
        options.assumptions
    else
        .{};
    return .{
        .equation = equation_module.parse(source),
        .unknowns = unknowns,
        .domain = @as(domain.Domain, options.domain),
        .assumptions = assumptions,
    };
}

fn assumptionsType(comptime Options: type) type {
    return if (@hasField(Options, "assumptions"))
        @FieldType(Options, "assumptions")
    else
        @TypeOf(.{});
}
