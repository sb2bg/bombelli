//! C source emission, organized by the artifact being generated.

const expression = @import("c/expression.zig");
const newton = @import("c/newton.zig");
const quadrature = @import("c/quadrature.zig");

pub const emitExpr = expression.emitExpr;
pub const emitVector = expression.emitVector;
pub const emitMatrix = expression.emitMatrix;
pub const emitFixedQuadrature = quadrature.emitFixedQuadrature;
pub const emitNewton = newton.emitNewton;
