const std = @import("std");

pub const max_nodes = 512;
pub const NodeId = u16;

pub const Binary = struct {
    left: NodeId,
    right: NodeId,
};

pub const Power = struct {
    base: NodeId,
    exponent: u32,
};

pub const Node = union(enum) {
    integer: i64,
    float: f64,
    symbol: []const u8,
    add: Binary,
    sub: Binary,
    mul: Binary,
    div: Binary,
    pow: Power,
    negate: NodeId,
    sin: NodeId,
    cos: NodeId,
    exp: NodeId,
    ln: NodeId,
};

pub const Expr = struct {
    nodes: [max_nodes]Node = [_]Node{.{ .integer = 0 }} ** max_nodes,
    len: usize = 0,
    root: NodeId = 0,
    source: []const u8,

    pub fn init(source: []const u8) Expr {
        return .{ .source = source };
    }

    pub fn addNode(self: *Expr, new_node: Node) NodeId {
        if (self.len == max_nodes) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli expression exceeds the pilot AST capacity of {d} nodes",
                .{max_nodes},
            ));
        }
        const id: NodeId = @intCast(self.len);
        self.nodes[self.len] = new_node;
        self.len += 1;
        return id;
    }

    pub fn node(self: Expr, id: NodeId) Node {
        return self.nodes[@intCast(id)];
    }

    pub fn diff(comptime self: Expr, comptime variable: anytype) Expr {
        @setEvalBranchQuota(1_000_000);
        return @import("differentiation.zig").differentiate(self, @tagName(variable));
    }

    pub fn simplify(comptime self: Expr) Expr {
        @setEvalBranchQuota(1_000_000);
        return @import("simplification.zig").simplify(self);
    }

    pub fn eval(comptime self: Expr, values: anytype) f64 {
        return @import("evaluation.zig").evaluate(self, values);
    }

    pub fn render(comptime self: Expr) []const u8 {
        @setEvalBranchQuota(1_000_000);
        return @import("rendering.zig").render(self);
    }
};

pub fn equal(
    comptime left_expr: Expr,
    left_id: NodeId,
    comptime right_expr: Expr,
    right_id: NodeId,
) bool {
    const left = left_expr.node(left_id);
    const right = right_expr.node(right_id);
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .symbol => |name| std.mem.eql(u8, name, right.symbol),
        .add => |binary| equalBinary(left_expr, binary, right_expr, right.add),
        .sub => |binary| equalBinary(left_expr, binary, right_expr, right.sub),
        .mul => |binary| equalBinary(left_expr, binary, right_expr, right.mul),
        .div => |binary| equalBinary(left_expr, binary, right_expr, right.div),
        .pow => |power| power.exponent == right.pow.exponent and
            equal(left_expr, power.base, right_expr, right.pow.base),
        .negate => |child| equal(left_expr, child, right_expr, right.negate),
        .sin => |child| equal(left_expr, child, right_expr, right.sin),
        .cos => |child| equal(left_expr, child, right_expr, right.cos),
        .exp => |child| equal(left_expr, child, right_expr, right.exp),
        .ln => |child| equal(left_expr, child, right_expr, right.ln),
    };
}

fn equalBinary(
    comptime left_expr: Expr,
    left: Binary,
    comptime right_expr: Expr,
    right: Binary,
) bool {
    return equal(left_expr, left.left, right_expr, right.left) and
        equal(left_expr, left.right, right_expr, right.right);
}
