const ast = @import("ast.zig");

pub const Metrics = struct {
    node_count: usize,
    construction_peak_nodes: usize,
    backing_bytes: usize,

    pub fn constructionHeadroom(self: Metrics) usize {
        return ast.construction_node_limit - self.construction_peak_nodes;
    }
};

pub fn measure(comptime expression: ast.Expr) Metrics {
    validate(expression);
    return .{
        .node_count = expression.nodes.len,
        .construction_peak_nodes = expression.construction_peak_nodes,
        .backing_bytes = @sizeOf(ast.Expr) + expression.nodes.len * @sizeOf(ast.Node),
    };
}

fn validate(comptime expression: ast.Expr) void {
    comptime {
        if (expression.nodes.len == 0) {
            @compileError("Bombelli invariant failure: expression has no nodes");
        }
        if (expression.root >= expression.nodes.len) {
            @compileError("Bombelli invariant failure: root node is out of bounds");
        }
        if (expression.construction_peak_nodes < expression.nodes.len or
            expression.construction_peak_nodes > ast.construction_node_limit)
        {
            @compileError("Bombelli invariant failure: invalid construction peak");
        }

        var reachable = [_]bool{false} ** expression.nodes.len;
        markReachable(expression, expression.root, &reachable);

        for (expression.nodes, 0..) |node_value, index| {
            validateChildren(node_value, index);
            if (!reachable[index]) {
                @compileError("Bombelli invariant failure: expression contains an unreachable node");
            }

            for (expression.nodes[0..index]) |previous| {
                if (ast.nodeEqual(node_value, previous)) {
                    @compileError("Bombelli invariant failure: expression contains duplicate nodes");
                }
            }
        }
    }
}

fn validateChildren(
    comptime node_value: ast.Node,
    comptime parent_index: usize,
) void {
    switch (node_value) {
        .integer, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            validateChild(binary.left, parent_index);
            validateChild(binary.right, parent_index);
        },
        .pow => |power| validateChild(power.base, parent_index),
        .negate, .sin, .cos, .exp, .ln => |child| {
            validateChild(child, parent_index);
        },
    }
}

fn validateChild(
    comptime child: ast.NodeId,
    comptime parent_index: usize,
) void {
    if (child >= parent_index) {
        @compileError("Bombelli invariant failure: expression is not topologically ordered");
    }
}

fn markReachable(
    comptime expression: ast.Expr,
    id: ast.NodeId,
    reachable: []bool,
) void {
    const index: usize = @intCast(id);
    if (reachable[index]) return;
    reachable[index] = true;

    switch (expression.node(id)) {
        .integer, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            markReachable(expression, binary.left, reachable);
            markReachable(expression, binary.right, reachable);
        },
        .pow => |power| markReachable(expression, power.base, reachable),
        .negate, .sin, .cos, .exp, .ln => |child| {
            markReachable(expression, child, reachable);
        },
    }
}
