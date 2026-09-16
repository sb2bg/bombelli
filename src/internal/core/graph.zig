//! Traversal helpers for Bombelli's immutable expression DAGs.

const ast = @import("../../expression.zig");

/// Structural edges, including operands whose derivative may be inactive.
pub fn children(comptime node: ast.Node) []const ast.NodeId {
    return switch (node) {
        .sub, .div, .atan2, .hypot => |binary| &.{ binary.left, binary.right },
        .add_nary, .mul_nary => |operands| operands,
        .pow => |power| &.{power.base},
        .unary => |unary| &.{unary.child},
        else => &.{},
    };
}

pub fn markReachable(
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    reachable: anytype,
) void {
    const index: usize = @intCast(id);
    if (index >= nodes.len) @compileError("Bombelli invariant failure: root or child node is out of bounds");
    if (reachable[index]) return;
    reachable[index] = true;

    switch (nodes[index]) {
        .integer, .rational, .float, .constant, .symbol => {},
        .sub, .div, .atan2, .hypot => |binary| {
            markReachable(nodes, binary.left, reachable);
            markReachable(nodes, binary.right, reachable);
        },
        .add_nary, .mul_nary => |operands| {
            for (operands) |child| markReachable(nodes, child, reachable);
        },
        .pow => |power| markReachable(nodes, power.base, reachable),
        .unary => |unary| markReachable(nodes, unary.child, reachable),
    }
}
