//! Zig source emission, organized by the artifact being generated.

const expression = @import("zig/expression.zig");
const newton = @import("zig/newton.zig");
const quadrature = @import("zig/quadrature.zig");

pub const EmitTarget = enum {
    zig,
};

pub const EmitMode = enum {
    out_of_place,
};

pub const emitExpr = expression.emitExpr;
pub const emitVector = expression.emitVector;
pub const emitMatrix = expression.emitMatrix;
pub const emitFixedQuadrature = quadrature.emitFixedQuadrature;
pub const emitNewton = newton.emitNewton;
