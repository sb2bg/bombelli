const ast = @import("ast.zig");

pub const Metrics = struct {
    node_count: usize,
    operand_count: usize,
    construction_peak_nodes: usize,
    backing_bytes: usize,

    pub fn constructionHeadroom(self: Metrics) usize {
        return ast.construction_node_limit - self.construction_peak_nodes;
    }
};

pub fn measure(comptime expression: ast.Expr) Metrics {
    validateProgram(
        expression.nodes,
        &[_]ast.NodeId{expression.root},
        expression.construction_peak_nodes,
    );
    return .{
        .node_count = expression.nodes.len,
        .operand_count = operandCount(expression.nodes),
        .construction_peak_nodes = expression.construction_peak_nodes,
        .backing_bytes = @sizeOf(ast.Expr) +
            expression.nodes.len * @sizeOf(ast.Node) +
            operandBytes(expression.nodes),
    };
}

pub fn measureVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) Metrics {
    validateProgram(
        expression.nodes,
        &expression.roots,
        expression.construction_peak_nodes,
    );
    return .{
        .node_count = expression.nodes.len,
        .operand_count = operandCount(expression.nodes),
        .construction_peak_nodes = expression.construction_peak_nodes,
        .backing_bytes = @sizeOf(ast.ExprVector(N)) +
            expression.nodes.len * @sizeOf(ast.Node) +
            operandBytes(expression.nodes),
    };
}

pub fn measureMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) Metrics {
    var roots: [R * C]ast.NodeId = undefined;
    inline for (0..R) |row| {
        inline for (0..C) |column| {
            roots[row * C + column] = expression.roots[row][column];
        }
    }
    validateProgram(
        expression.nodes,
        &roots,
        expression.construction_peak_nodes,
    );
    return .{
        .node_count = expression.nodes.len,
        .operand_count = operandCount(expression.nodes),
        .construction_peak_nodes = expression.construction_peak_nodes,
        .backing_bytes = @sizeOf(ast.ExprMatrix(R, C)) +
            expression.nodes.len * @sizeOf(ast.Node) +
            operandBytes(expression.nodes),
    };
}

fn validateProgram(
    comptime nodes: []const ast.Node,
    comptime roots: []const ast.NodeId,
    comptime construction_peak_nodes: usize,
) void {
    comptime {
        if (nodes.len == 0) {
            @compileError("Bombelli invariant failure: expression has no nodes");
        }
        if (roots.len == 0) {
            @compileError("Bombelli invariant failure: expression has no roots");
        }
        for (roots) |root| {
            if (root >= nodes.len) {
                @compileError("Bombelli invariant failure: root node is out of bounds");
            }
        }
        if (construction_peak_nodes < nodes.len or
            construction_peak_nodes > ast.construction_node_limit)
        {
            @compileError("Bombelli invariant failure: invalid construction peak");
        }

        var reachable = [_]bool{false} ** nodes.len;
        for (roots) |root| markReachable(nodes, root, &reachable);

        for (nodes, 0..) |node_value, index| {
            validateChildren(node_value, index);
            if (!reachable[index]) {
                @compileError("Bombelli invariant failure: expression contains an unreachable node");
            }

            for (nodes[0..index]) |previous| {
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
        .integer, .rational, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            validateChild(binary.left, parent_index);
            validateChild(binary.right, parent_index);
        },
        .add_nary, .mul_nary => |operands| {
            for (operands) |child| validateChild(child, parent_index);
        },
        .pow => |power| validateChild(power.base, parent_index),
        .negate, .sin, .cos, .tan, .atan, .abs, .exp, .ln => |child| {
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
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    reachable: []bool,
) void {
    const index: usize = @intCast(id);
    if (reachable[index]) return;
    reachable[index] = true;

    switch (nodes[index]) {
        .integer, .rational, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            markReachable(nodes, binary.left, reachable);
            markReachable(nodes, binary.right, reachable);
        },
        .add_nary, .mul_nary => |operands| {
            for (operands) |child| markReachable(nodes, child, reachable);
        },
        .pow => |power| markReachable(nodes, power.base, reachable),
        .negate, .sin, .cos, .tan, .atan, .abs, .exp, .ln => |child| {
            markReachable(nodes, child, reachable);
        },
    }
}

fn operandBytes(comptime nodes: []const ast.Node) usize {
    return operandCount(nodes) * @sizeOf(ast.NodeId);
}

fn operandCount(comptime nodes: []const ast.Node) usize {
    var count: usize = 0;
    for (nodes) |node| {
        count += switch (node) {
            .add_nary, .mul_nary => |operands| operands.len,
            else => 0,
        };
    }
    return count;
}
