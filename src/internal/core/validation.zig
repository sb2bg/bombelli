//! Structural validation shared by compilation, evaluation, and emission.
const ast = @import("../../expression.zig");
const build = @import("builder.zig");
const graph = @import("graph.zig");
const limits = @import("limits.zig");

pub fn program(comptime expression: anytype) void {
    comptime validate(expression.nodes, roots(expression), expression.construction_peak_nodes);
}

/// Flatten scalar, vector, and matrix output IDs without copying node stores.
pub fn roots(comptime expression: anytype) []const ast.NodeId {
    if (@hasField(@TypeOf(expression), "root")) return &.{expression.root};
    const Root = @TypeOf(expression.roots);
    if (@typeInfo(@typeInfo(Root).array.child) != .array) return &expression.roots;
    const R = expression.roots.len;
    const C = @typeInfo(@typeInfo(Root).array.child).array.len;
    var flat: [R * C]ast.NodeId = undefined;
    for (expression.roots, 0..) |row, r| {
        for (row, 0..) |root, c| flat[r * C + c] = root;
    }
    const result = flat;
    return &result;
}

pub fn validate(
    comptime nodes: []const ast.Node,
    comptime output_roots: []const ast.NodeId,
    comptime construction_peak_nodes: usize,
) void {
    comptime {
        @setEvalBranchQuota(limits.eval_branch.transform);
        if (nodes.len == 0) @compileError("Bombelli invariant failure: expression has no nodes");
        if (output_roots.len == 0) @compileError("Bombelli invariant failure: expression has no roots");
        for (output_roots) |root| {
            if (root >= nodes.len) @compileError("Bombelli invariant failure: root node is out of bounds");
        }
        if (construction_peak_nodes < nodes.len or construction_peak_nodes > ast.construction_node_limit)
            @compileError("Bombelli invariant failure: invalid construction peak");
        // Validate every edge before a traversal can dereference one.
        references(nodes);
        var reachable = [_]bool{false} ** nodes.len;
        for (output_roots) |root| graph.markReachable(nodes, root, &reachable);
        var uniqueness = build.BuilderWithCapacity(nodes.len){};
        for (nodes, 0..) |node, index| {
            if (!reachable[index]) @compileError("Bombelli invariant failure: expression contains an unreachable node");
            if (uniqueness.intern(node) != index)
                @compileError("Bombelli invariant failure: expression contains duplicate nodes");
        }
    }
}

/// Also used before compacting a builder, where unreachable nodes are allowed.
pub fn references(comptime nodes: []const ast.Node) void {
    comptime {
        for (nodes, 0..) |node, parent| {
            if (node == .add_nary or node == .mul_nary) {
                if (graph.children(node).len < 2)
                    @compileError("Bombelli invariant failure: n-ary operation has fewer than two operands");
            }
            for (graph.children(node)) |child| {
                if (child >= nodes.len) @compileError("Bombelli invariant failure: child node is out of bounds");
                if (child >= parent) @compileError("Bombelli invariant failure: expression is not topologically ordered");
            }
        }
    }
}
