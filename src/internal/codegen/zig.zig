//! Zig source emission, organized by the artifact being generated.

const expression = @import("zig/expression.zig");
const newton = @import("zig/newton.zig");
const quadrature = @import("zig/quadrature.zig");
const row_least_squares = @import("zig/row_least_squares.zig");

pub const emitExpr = expression.emitExpr;
pub const emitVector = expression.emitVector;
pub const emitMatrix = expression.emitMatrix;
pub const emitFixedQuadrature = quadrature.emitFixedQuadrature;
pub const emitNewton = newton.emitNewton;
pub const emitRowLeastSquares = row_least_squares.emitRowLeastSquares;
