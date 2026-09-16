const ast = @import("../../expression.zig");
const lifetime = @import("lifetime.zig");

pub const Metrics = struct {
    node_count: usize,
    operand_count: usize,
    construction_peak_nodes: usize,
    backing_bytes: usize,
    /// Logical peak, including retained outputs; not backend stack usage.
    peak_live_values: usize,

    pub fn constructionHeadroom(self: Metrics) usize {
        return ast.construction_node_limit - self.construction_peak_nodes;
    }
};

pub fn measure(comptime expression: ast.Expr) Metrics {
    return comptime measureProgram(expression);
}

pub fn measureVector(comptime N: usize, comptime expression: ast.ExprVector(N)) Metrics {
    return comptime measureProgram(expression);
}

pub fn measureMatrix(comptime R: usize, comptime C: usize, comptime expression: ast.ExprMatrix(R, C)) Metrics {
    return comptime measureProgram(expression);
}

fn measureProgram(comptime expression: anytype) Metrics {
    // Lifetime analysis first validates all references and program invariants.
    const live = lifetime.analyze(expression);
    var operands: usize = 0;
    for (expression.nodes) |node| {
        operands += switch (node) {
            .add_nary, .mul_nary => |children| children.len,
            else => 0,
        };
    }
    return .{
        .node_count = expression.nodes.len,
        .operand_count = operands,
        .construction_peak_nodes = expression.construction_peak_nodes,
        .peak_live_values = live.peak_live_values,
        .backing_bytes = @sizeOf(@TypeOf(expression)) + expression.nodes.len * @sizeOf(ast.Node) + operands * @sizeOf(ast.NodeId),
    };
}
