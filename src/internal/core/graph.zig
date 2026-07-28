//! Traversal helpers for Bombelli's immutable expression DAGs.

const ast = @import("../../expression.zig");

pub fn markReachable(
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    reachable: anytype,
) void {
    const index: usize = @intCast(id);
    if (reachable[index]) return;
    reachable[index] = true;

    switch (nodes[index]) {
        .integer, .rational, .float, .constant, .symbol => {},
        .add, .sub, .mul, .div, .atan2, .hypot => |binary| {
            markReachable(nodes, binary.left, reachable);
            markReachable(nodes, binary.right, reachable);
        },
        .add_nary, .mul_nary => |operands| {
            for (operands) |child| markReachable(nodes, child, reachable);
        },
        .pow => |power| markReachable(nodes, power.base, reachable),
        .negate,
        .sin,
        .cos,
        .tan,
        .asin,
        .acos,
        .atan,
        .sinh,
        .cosh,
        .tanh,
        .abs,
        .exp,
        .ln,
        .log2,
        .log10,
        => |child| {
            markReachable(nodes, child, reachable);
        },
    }
}
