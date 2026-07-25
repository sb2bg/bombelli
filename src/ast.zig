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
    add_nary: []const NodeId,
    sub: Binary,
    mul: Binary,
    mul_nary: []const NodeId,
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

    pub fn jacobian(
        comptime self: Expr,
        comptime variables: anytype,
    ) ExprMatrix(1, tupleLength(@TypeOf(variables))) {
        @setEvalBranchQuota(20_000_000);
        return @import("multi.zig").scalarJacobian(self, variables);
    }

    pub fn simplify(comptime self: Expr) Expr {
        @setEvalBranchQuota(5_000_000);
        return @import("simplification.zig").simplify(self);
    }

    pub fn substitute(comptime self: Expr, comptime replacements: anytype) Expr {
        @setEvalBranchQuota(10_000_000);
        return @import("substitution.zig").substitute(self, replacements);
    }

    pub fn asPolynomial(comptime self: Expr) @import("polynomial.zig").Polynomial {
        @setEvalBranchQuota(20_000_000);
        return @import("polynomial.zig").fromExpr(self);
    }

    pub fn expand(comptime self: Expr) Expr {
        @setEvalBranchQuota(20_000_000);
        return self.asPolynomial().toExpr();
    }

    pub fn asRationalFunction(
        comptime self: Expr,
    ) @import("rational_function.zig").RationalFunction {
        @setEvalBranchQuota(30_000_000);
        return @import("rational_function.zig").fromExpr(self);
    }

    pub fn integral(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("integration.zig").IntegralProblem {
        @setEvalBranchQuota(50_000_000);
        return @import("integration.zig").makeProblem(self, options);
    }

    pub fn integrate(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("integration.zig").IntegrationResult {
        @setEvalBranchQuota(50_000_000);
        return @import("integration.zig").integrate(self, options);
    }

    pub fn quadrature(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("gauss_legendre.zig").QuadratureRule(options.order) {
        @setEvalBranchQuota(50_000_000);
        return @import("gauss_legendre.zig").make(self, options);
    }

    pub fn adaptiveQuadrature(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("adaptive_quadrature.zig").AdaptiveQuadratureRule(
        options.max_depth,
    ) {
        @setEvalBranchQuota(50_000_000);
        return @import("adaptive_quadrature.zig").make(self, options);
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

    pub fn renderMode(
        comptime self: Expr,
        comptime mode: @import("rendering.zig").RenderMode,
    ) []const u8 {
        @setEvalBranchQuota(1_000_000);
        return @import("rendering.zig").renderMode(self, mode);
    }

    pub fn emit(
        comptime self: Expr,
        comptime options: anytype,
    ) []const u8 {
        @setEvalBranchQuota(10_000_000);
        return @import("source_emission.zig").emitExpr(self, options);
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

        pub fn substitute(comptime self: Self, comptime replacements: anytype) Self {
            @setEvalBranchQuota(10_000_000);
            return @import("substitution.zig").substituteVector(
                N,
                self,
                replacements,
            );
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

        pub fn renderMode(
            comptime self: Self,
            comptime mode: @import("rendering.zig").RenderMode,
        ) [N][]const u8 {
            @setEvalBranchQuota(2_000_000);
            return @import("rendering.zig").renderVectorMode(N, self, mode);
        }

        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(20_000_000);
            return @import("source_emission.zig").emitVector(N, self, options);
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

        pub fn substitute(comptime self: Self, comptime replacements: anytype) Self {
            @setEvalBranchQuota(20_000_000);
            return @import("substitution.zig").substituteMatrix(
                R,
                C,
                self,
                replacements,
            );
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

        pub fn renderMode(
            comptime self: Self,
            comptime mode: @import("rendering.zig").RenderMode,
        ) [R][C][]const u8 {
            @setEvalBranchQuota(4_000_000);
            return @import("rendering.zig").renderMatrixMode(
                R,
                C,
                self,
                mode,
            );
        }

        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(30_000_000);
            return @import("source_emission.zig").emitMatrix(
                R,
                C,
                self,
                options,
            );
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
        .add_nary => |operands| std.mem.eql(NodeId, operands, right.add_nary),
        .sub => |binary| binaryEqual(binary, right.sub),
        .mul => |binary| binaryEqual(binary, right.mul),
        .mul_nary => |operands| std.mem.eql(NodeId, operands, right.mul_nary),
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
