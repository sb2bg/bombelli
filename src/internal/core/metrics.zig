const ast = @import("../../expression.zig");
const validation = @import("validation.zig");

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
    validation.validate(
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
    validation.validate(
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
    validation.validate(
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
