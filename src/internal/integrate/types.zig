//! Shared integration data types that do not depend on an integration engine.

const ast = @import("../../expression.zig");

pub const IntegralBounds = struct {
    from: ast.Expr,
    to: ast.Expr,
};
