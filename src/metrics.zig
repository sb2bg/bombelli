const ast = @import("ast.zig");

pub const Metrics = struct {
    capacity: usize,
    backing_bytes: usize,
    stored_nodes: usize,
    reachable_nodes: usize,
    unique_structural_nodes: usize,

    pub fn duplicateOccurrences(self: Metrics) usize {
        return self.reachable_nodes - self.unique_structural_nodes;
    }

    pub fn unreachableConstructionNodes(self: Metrics) usize {
        return self.stored_nodes - self.reachable_nodes;
    }
};

pub fn measure(comptime expression: ast.Expr) Metrics {
    var visited = [_]bool{false} ** ast.max_nodes;
    var reachable: [ast.max_nodes]ast.NodeId = undefined;
    var reachable_count: usize = 0;
    collectReachable(
        expression,
        expression.root,
        &visited,
        &reachable,
        &reachable_count,
    );

    var unique: [ast.max_nodes]ast.NodeId = undefined;
    var unique_count: usize = 0;
    for (reachable[0..reachable_count]) |candidate| {
        var found = false;
        for (unique[0..unique_count]) |existing| {
            if (ast.equal(expression, candidate, expression, existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            unique[unique_count] = candidate;
            unique_count += 1;
        }
    }

    return .{
        .capacity = ast.max_nodes,
        .backing_bytes = @sizeOf(ast.Expr),
        .stored_nodes = expression.len,
        .reachable_nodes = reachable_count,
        .unique_structural_nodes = unique_count,
    };
}

fn collectReachable(
    comptime expression: ast.Expr,
    id: ast.NodeId,
    visited: *[ast.max_nodes]bool,
    reachable: *[ast.max_nodes]ast.NodeId,
    count: *usize,
) void {
    const index: usize = @intCast(id);
    if (visited[index]) return;
    visited[index] = true;

    reachable[count.*] = id;
    count.* += 1;

    switch (expression.node(id)) {
        .integer, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            collectReachable(expression, binary.left, visited, reachable, count);
            collectReachable(expression, binary.right, visited, reachable, count);
        },
        .pow => |power| {
            collectReachable(expression, power.base, visited, reachable, count);
        },
        .negate, .sin, .cos, .exp, .ln => |child| {
            collectReachable(expression, child, visited, reachable, count);
        },
    }
}
