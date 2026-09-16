//! Logical value lifetimes in the existing topological evaluation order.
const graph = @import("graph.zig");
const validation = @import("validation.zig");

pub fn Analysis(comptime N: usize) type {
    return struct {
        /// Inclusive final consumer; N means retained until outputs are copied.
        last_use: [N]usize,
        /// Includes the new result and its operands during each operation.
        /// This is a logical storage bound, not measured stack/register usage.
        peak_live_values: usize,
    };
}

pub fn analyze(comptime expression: anytype) Analysis(expression.nodes.len) {
    return comptime blk: {
        validation.program(expression);
        const nodes = expression.nodes;
        var last_use: [nodes.len]usize = undefined;
        for (0..nodes.len) |i| last_use[i] = i;
        for (nodes, 0..) |node, i| {
            for (graph.children(node)) |child| last_use[child] = i;
        }
        for (validation.roots(expression)) |root| last_use[root] = nodes.len;
        var deaths = [_]usize{0} ** (nodes.len + 1);
        for (last_use) |end| deaths[end] += 1;
        var live: usize = 0;
        var peak: usize = 0;
        for (0..nodes.len) |i| {
            live += 1;
            peak = @max(peak, live);
            live -= deaths[i];
        }
        break :blk .{ .last_use = last_use, .peak_live_values = peak };
    };
}
