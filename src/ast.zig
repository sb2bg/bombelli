const std = @import("std");
const exact = @import("exact.zig");

pub const construction_node_limit = 1024;
pub const NodeId = u32;
pub const invalid_node: NodeId = std.math.maxInt(NodeId);

pub const Binary = struct {
    left: NodeId,
    right: NodeId,
};

pub const Power = struct {
    base: NodeId,
    exponent: exact.Rational,
};

pub const Node = union(enum) {
    integer: exact.Integer,
    rational: exact.Rational,
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
    tan: NodeId,
    atan: NodeId,
    abs: NodeId,
    exp: NodeId,
    ln: NodeId,
};

pub const Expr = struct {
    nodes: []const Node,
    root: NodeId,
    source: []const u8,
    construction_peak_nodes: usize,

    pub fn node(self: Expr, id: NodeId) Node {
        return self.nodes[@intCast(id)];
    }

    pub fn diff(comptime self: Expr, comptime variable: anytype) Expr {
        @setEvalBranchQuota(5_000_000);
        return @import("differentiation.zig").differentiate(self, @tagName(variable));
    }

    pub fn gradient(comptime self: Expr, comptime variables: anytype) ExprVector(tupleLength(@TypeOf(variables))) {
        @setEvalBranchQuota(10_000_000);
        return @import("multi.zig").gradient(self, variables);
    }

    pub fn hessian(comptime self: Expr, comptime variables: anytype) ExprMatrix(
        tupleLength(@TypeOf(variables)),
        tupleLength(@TypeOf(variables)),
    ) {
        @setEvalBranchQuota(20_000_000);
        return @import("multi.zig").hessian(self, variables);
    }

    pub fn simplify(comptime self: Expr) Expr {
        @setEvalBranchQuota(5_000_000);
        return @import("simplification.zig").simplify(self);
    }

    pub fn eval(comptime self: Expr, values: anytype) f64 {
        return @import("evaluation.zig").evaluate(self, values);
    }

    pub fn evalInto(comptime self: Expr, output: *f64, values: anytype) void {
        return @import("evaluation.zig").evaluateInto(self, output, values);
    }

    pub fn render(comptime self: Expr) []const u8 {
        @setEvalBranchQuota(1_000_000);
        return @import("rendering.zig").render(self);
    }

    pub fn metrics(comptime self: Expr) @import("metrics.zig").Metrics {
        @setEvalBranchQuota(10_000_000);
        return @import("metrics.zig").measure(self);
    }
};

pub fn ExprVector(comptime N: usize) type {
    return struct {
        nodes: []const Node,
        roots: [N]NodeId,
        sources: [N][]const u8,
        construction_peak_nodes: usize,

        const Self = @This();

        pub fn node(self: Self, id: NodeId) Node {
            return self.nodes[@intCast(id)];
        }

        pub fn at(comptime self: Self, comptime index: usize) Expr {
            if (index >= N) @compileError("Bombelli vector expression index is out of bounds");
            return @import("multi.zig").vectorElement(N, self, index);
        }

        pub fn diff(comptime self: Self, comptime variable: anytype) Self {
            @setEvalBranchQuota(10_000_000);
            return @import("multi.zig").differentiateVector(N, self, variable);
        }

        pub fn jacobian(comptime self: Self, comptime variables: anytype) ExprMatrix(
            N,
            tupleLength(@TypeOf(variables)),
        ) {
            @setEvalBranchQuota(20_000_000);
            return @import("multi.zig").jacobian(N, self, variables);
        }

        pub fn simplify(comptime self: Self) Self {
            @setEvalBranchQuota(10_000_000);
            return @import("multi.zig").simplifyVector(N, self);
        }

        pub fn eval(comptime self: Self, values: anytype) [N]f64 {
            return @import("evaluation.zig").evaluateVector(N, self, values);
        }

        pub fn evalInto(comptime self: Self, output: anytype, values: anytype) void {
            return @import("evaluation.zig").evaluateVectorInto(N, self, output, values);
        }

        pub fn render(comptime self: Self) [N][]const u8 {
            @setEvalBranchQuota(2_000_000);
            return @import("rendering.zig").renderVector(N, self);
        }

        pub fn metrics(comptime self: Self) @import("metrics.zig").Metrics {
            @setEvalBranchQuota(10_000_000);
            return @import("metrics.zig").measureVector(N, self);
        }
    };
}

pub fn ExprMatrix(comptime R: usize, comptime C: usize) type {
    return struct {
        nodes: []const Node,
        roots: [R][C]NodeId,
        sources: [R][C][]const u8,
        construction_peak_nodes: usize,

        const Self = @This();

        pub fn node(self: Self, id: NodeId) Node {
            return self.nodes[@intCast(id)];
        }

        pub fn at(comptime self: Self, comptime row: usize, comptime column: usize) Expr {
            if (row >= R or column >= C) {
                @compileError("Bombelli matrix expression index is out of bounds");
            }
            return @import("multi.zig").matrixElement(R, C, self, row, column);
        }

        pub fn diff(comptime self: Self, comptime variable: anytype) Self {
            @setEvalBranchQuota(20_000_000);
            return @import("multi.zig").differentiateMatrix(R, C, self, variable);
        }

        pub fn simplify(comptime self: Self) Self {
            @setEvalBranchQuota(20_000_000);
            return @import("multi.zig").simplifyMatrix(R, C, self);
        }

        pub fn eval(comptime self: Self, values: anytype) [R][C]f64 {
            return @import("evaluation.zig").evaluateMatrix(R, C, self, values);
        }

        pub fn evalInto(comptime self: Self, output: anytype, values: anytype) void {
            return @import("evaluation.zig").evaluateMatrixInto(R, C, self, output, values);
        }

        pub fn render(comptime self: Self) [R][C][]const u8 {
            @setEvalBranchQuota(4_000_000);
            return @import("rendering.zig").renderMatrix(R, C, self);
        }

        pub fn metrics(comptime self: Self) @import("metrics.zig").Metrics {
            @setEvalBranchQuota(10_000_000);
            return @import("metrics.zig").measureMatrix(R, C, self);
        }
    };
}

pub fn tupleLength(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple)
            info.fields.len
        else
            @compileError("Bombelli expects a tuple"),
        else => @compileError("Bombelli expects a tuple"),
    };
}

pub fn nodeEqual(left: Node, right: Node) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .integer => |value| value == right.integer,
        .rational => |value| value.eql(right.rational),
        .float => |value| @as(u64, @bitCast(value)) ==
            @as(u64, @bitCast(right.float)),
        .symbol => |name| std.mem.eql(u8, name, right.symbol),
        .add => |binary| binaryEqual(binary, right.add),
        .sub => |binary| binaryEqual(binary, right.sub),
        .mul => |binary| binaryEqual(binary, right.mul),
        .div => |binary| binaryEqual(binary, right.div),
        .pow => |power| power.base == right.pow.base and
            power.exponent.eql(right.pow.exponent),
        .negate => |child| child == right.negate,
        .sin => |child| child == right.sin,
        .cos => |child| child == right.cos,
        .tan => |child| child == right.tan,
        .atan => |child| child == right.atan,
        .abs => |child| child == right.abs,
        .exp => |child| child == right.exp,
        .ln => |child| child == right.ln,
    };
}

fn binaryEqual(left: Binary, right: Binary) bool {
    return left.left == right.left and left.right == right.right;
}
