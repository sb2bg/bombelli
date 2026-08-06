//! Source emission, dispatched to one backend per target language.
//!
//! Every backend produces a standalone translation unit: the emitted source
//! never imports Bombelli, and it carries no symbolic machinery.

const std = @import("std");
const ast = @import("../../expression.zig");
const c_backend = @import("c.zig");
const options_validation = @import("../core/options.zig");
const zig_backend = @import("zig.zig");

/// Source languages supported by Bombelli emission.
pub const EmitTarget = enum {
    zig,
    c,
};

/// Calling conventions supported by Bombelli emission.
pub const EmitMode = enum {
    out_of_place,
};

pub fn emitExpr(
    comptime expression: ast.Expr,
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitExpr(expression, options),
        .c => c_backend.emitExpr(expression, options),
    };
}

pub fn emitVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitVector(N, expression, options),
        .c => c_backend.emitVector(N, expression, options),
    };
}

pub fn emitMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitMatrix(R, C, expression, options),
        .c => c_backend.emitMatrix(R, C, expression, options),
    };
}

pub fn emitFixedQuadrature(
    comptime rule: anytype,
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitFixedQuadrature(rule, options),
        .c => c_backend.emitFixedQuadrature(rule, options),
    };
}

pub fn emitNewton(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitNewton(solver, options),
        .c => c_backend.emitNewton(solver, options),
    };
}

pub fn emitRowLeastSquares(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    return switch (selectTarget(options)) {
        .zig => zig_backend.emitRowLeastSquares(solver, options),
        .c => c_backend.emitRowLeastSquares(solver, options),
    };
}

/// Validates the target-independent options and resolves the backend.
fn selectTarget(comptime options: anytype) EmitTarget {
    const Options = @TypeOf(options);
    options_validation.requireField(
        Options,
        "target",
        "Bombelli source emission requires '.target = .zig' or '.target = .c'",
    );
    options_validation.requireTag(
        options,
        "mode",
        "out_of_place",
        "Bombelli source emission currently requires '.mode = .out_of_place'",
    );

    const requested = @tagName(options.target);
    inline for (@typeInfo(EmitTarget).@"enum".fields) |field| {
        if (std.mem.eql(u8, requested, field.name)) {
            return @field(EmitTarget, field.name);
        }
    }
    @compileError(
        "Bombelli source emission supports '.target = .zig' and " ++
            "'.target = .c', not '." ++ requested ++ "'",
    );
}
