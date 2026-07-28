//! Immutable scalar, vector, and matrix expression DAGs.

const std = @import("std");
const exact = @import("internal/core/exact.zig");
const limits = @import("internal/core/limits.zig");

pub const construction_node_limit = limits.construction_nodes;
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

pub const Constant = enum {
    pi,

    /// Returns the closest `f64` to the mathematical constant.
    pub fn value(self: Constant) f64 {
        return switch (self) {
            .pi => std.math.pi,
        };
    }

    /// Returns the canonical, re-parsable spelling.
    pub fn name(self: Constant) []const u8 {
        return switch (self) {
            .pi => "pi",
        };
    }
};

pub const Node = union(enum) {
    integer: exact.Integer,
    rational: exact.Rational,
    float: f64,
    constant: Constant,
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

    /// Returns a node from this expression's shared DAG.
    pub fn node(self: Expr, id: NodeId) Node {
        return self.nodes[@intCast(id)];
    }

    /// Symbolically differentiates the expression by one variable.
    pub fn diff(comptime self: Expr, comptime variable: anytype) Expr {
        @setEvalBranchQuota(limits.eval_branch.local_transform);
        return @import("internal/transform/differentiation.zig").differentiate(self, @tagName(variable));
    }

    /// Builds the gradient for the given tuple of variables.
    pub fn gradient(comptime self: Expr, comptime variables: anytype) ExprVector(tupleLength(@TypeOf(variables))) {
        @setEvalBranchQuota(limits.eval_branch.transform);
        return @import("internal/transform/multi.zig").gradient(self, variables);
    }

    /// Builds the Hessian for the given tuple of variables.
    pub fn hessian(comptime self: Expr, comptime variables: anytype) ExprMatrix(
        tupleLength(@TypeOf(variables)),
        tupleLength(@TypeOf(variables)),
    ) {
        @setEvalBranchQuota(limits.eval_branch.polynomial);
        return @import("internal/transform/multi.zig").hessian(self, variables);
    }

    /// Builds a one-row Jacobian for the given tuple of variables.
    pub fn jacobian(
        comptime self: Expr,
        comptime variables: anytype,
    ) ExprMatrix(1, tupleLength(@TypeOf(variables))) {
        @setEvalBranchQuota(limits.eval_branch.polynomial);
        return @import("internal/transform/multi.zig").scalarJacobian(self, variables);
    }

    /// Applies Bombelli's canonical symbolic simplifications.
    pub fn simplify(comptime self: Expr) Expr {
        @setEvalBranchQuota(limits.eval_branch.local_transform);
        return @import("internal/transform/simplification.zig").simplify(self);
    }

    /// Replaces symbols using fields from a comptime replacement struct.
    pub fn substitute(comptime self: Expr, comptime replacements: anytype) Expr {
        @setEvalBranchQuota(limits.eval_branch.transform);
        return @import("internal/transform/substitution.zig").substitute(self, replacements);
    }

    /// Converts the expression to an exact multivariate polynomial.
    pub fn asPolynomial(comptime self: Expr) @import("internal/algebra/polynomial.zig").Polynomial {
        @setEvalBranchQuota(limits.eval_branch.polynomial);
        return @import("internal/algebra/polynomial.zig").fromExpr(self);
    }

    /// Expands the expression through its exact polynomial representation.
    pub fn expand(comptime self: Expr) Expr {
        @setEvalBranchQuota(limits.eval_branch.polynomial);
        return self.asPolynomial().toExpr();
    }

    /// Converts the expression to an exact rational function.
    pub fn asRationalFunction(
        comptime self: Expr,
    ) @import("internal/algebra/rational_function.zig").RationalFunction {
        @setEvalBranchQuota(limits.eval_branch.rational);
        return @import("internal/algebra/rational_function.zig").fromExpr(self);
    }

    /// Creates a symbolic integration problem without solving it.
    pub fn integral(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("internal/integrate/symbolic.zig").IntegralProblem {
        @setEvalBranchQuota(limits.eval_branch.solve);
        return @import("internal/integrate/symbolic.zig").makeProblem(self, options);
    }

    /// Attempts symbolic integration immediately.
    pub fn integrate(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("internal/integrate/symbolic.zig").IntegrationResult {
        @setEvalBranchQuota(limits.eval_branch.solve);
        return @import("internal/integrate/symbolic.zig").integrate(self, options);
    }

    /// Compiles a fixed-order numerical quadrature rule.
    pub fn quadrature(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("internal/integrate/gauss_legendre.zig").QuadratureRule(options.order) {
        @setEvalBranchQuota(limits.eval_branch.solve);
        return @import("internal/integrate/gauss_legendre.zig").make(self, options);
    }

    /// Compiles an adaptive numerical quadrature rule.
    pub fn adaptiveQuadrature(
        comptime self: Expr,
        comptime options: anytype,
    ) @import("internal/integrate/adaptive.zig").AdaptiveQuadratureRule(
        options.max_depth,
    ) {
        @setEvalBranchQuota(limits.eval_branch.solve);
        return @import("internal/integrate/adaptive.zig").make(self, options);
    }

    /// Evaluates the expression and returns its scalar result.
    pub fn eval(comptime self: Expr, values: anytype) f64 {
        return @import("internal/runtime/evaluation.zig").evaluate(self, values);
    }

    /// Evaluates the expression using the requested floating-point scalar type.
    pub fn evalAs(comptime self: Expr, comptime T: type, values: anytype) T {
        return @import("internal/runtime/evaluation.zig").evaluateAs(
            T,
            self,
            values,
        );
    }

    /// Evaluates the expression into caller-owned storage.
    pub fn evalInto(comptime self: Expr, output: *f64, values: anytype) void {
        return @import("internal/runtime/evaluation.zig").evaluateInto(self, output, values);
    }

    /// Evaluates with `T` into caller-owned scalar storage.
    pub fn evalIntoAs(
        comptime self: Expr,
        comptime T: type,
        output: *T,
        values: anytype,
    ) void {
        return @import("internal/runtime/evaluation.zig").evaluateIntoAs(
            T,
            self,
            output,
            values,
        );
    }

    /// Evaluates a structure-of-arrays input batch into caller-owned storage.
    /// `output` must not overlap any input slice: lanes are written a whole
    /// vector at a time, so an offset overlap would read values this call
    /// has already overwritten.
    pub fn evalBatchInto(
        comptime self: Expr,
        output: []f64,
        values: anytype,
    ) @import("internal/runtime/evaluation.zig").BatchInputError!void {
        return @import("internal/runtime/evaluation.zig").evaluateBatchInto(
            self,
            output,
            values,
        );
    }

    /// Evaluates a batch in parallel using the supplied batch options.
    /// `output` must not overlap any input slice, and the overlap is
    /// additionally unordered here because ranges run concurrently.
    pub fn evalBatchParallelInto(
        comptime self: Expr,
        output: []f64,
        values: anytype,
        options: @import("internal/runtime/evaluation.zig").BatchOptions,
    ) @import("internal/runtime/evaluation.zig").BatchInputError!void {
        return @import("internal/runtime/evaluation.zig").evaluateBatchParallelInto(
            self,
            output,
            values,
            options,
        );
    }

    /// Renders the expression in Bombelli's default notation.
    pub fn render(comptime self: Expr) []const u8 {
        @setEvalBranchQuota(limits.eval_branch.render);
        return @import("internal/codegen/rendering.zig").render(self);
    }

    /// Renders the expression in the selected notation.
    pub fn renderMode(
        comptime self: Expr,
        comptime mode: @import("internal/codegen/rendering.zig").RenderMode,
    ) []const u8 {
        @setEvalBranchQuota(limits.eval_branch.render);
        return @import("internal/codegen/rendering.zig").renderMode(self, mode);
    }

    /// Emits a standalone source implementation of this expression.
    pub fn emit(
        comptime self: Expr,
        comptime options: anytype,
    ) []const u8 {
        @setEvalBranchQuota(limits.eval_branch.transform);
        return @import("internal/codegen/emit.zig").emitExpr(self, options);
    }

    /// Measures and validates the expression DAG.
    pub fn metrics(comptime self: Expr) @import("internal/core/metrics.zig").Metrics {
        @setEvalBranchQuota(limits.eval_branch.transform);
        return @import("internal/core/metrics.zig").measure(self);
    }
};

/// Returns the immutable expression-vector type with `N` components.
pub fn ExprVector(comptime N: usize) type {
    return struct {
        nodes: []const Node,
        roots: [N]NodeId,
        sources: [N][]const u8,
        construction_peak_nodes: usize,

        const Self = @This();

        /// Returns a node from this vector's shared DAG.
        pub fn node(self: Self, id: NodeId) Node {
            return self.nodes[@intCast(id)];
        }

        /// Extracts one scalar component.
        pub fn at(comptime self: Self, comptime index: usize) Expr {
            if (index >= N) @compileError("Bombelli vector expression index is out of bounds");
            return @import("internal/transform/multi.zig").vectorElement(N, self, index);
        }

        /// Symbolically differentiates every component.
        pub fn diff(comptime self: Self, comptime variable: anytype) Self {
            @setEvalBranchQuota(limits.eval_branch.transform);
            return @import("internal/transform/multi.zig").differentiateVector(N, self, variable);
        }

        /// Builds the Jacobian for the given tuple of variables.
        pub fn jacobian(comptime self: Self, comptime variables: anytype) ExprMatrix(
            N,
            tupleLength(@TypeOf(variables)),
        ) {
            @setEvalBranchQuota(limits.eval_branch.polynomial);
            return @import("internal/transform/multi.zig").jacobian(N, self, variables);
        }

        /// Simplifies every component while preserving shared nodes.
        pub fn simplify(comptime self: Self) Self {
            @setEvalBranchQuota(limits.eval_branch.transform);
            return @import("internal/transform/multi.zig").simplifyVector(N, self);
        }

        /// Substitutes symbols throughout every component.
        pub fn substitute(comptime self: Self, comptime replacements: anytype) Self {
            @setEvalBranchQuota(limits.eval_branch.transform);
            return @import("internal/transform/substitution.zig").substituteVector(
                N,
                self,
                replacements,
            );
        }

        /// Evaluates all components and returns a fixed-size array.
        pub fn eval(comptime self: Self, values: anytype) [N]f64 {
            return @import("internal/runtime/evaluation.zig").evaluateVector(N, self, values);
        }

        /// Evaluates all components using the requested floating-point type.
        pub fn evalAs(
            comptime self: Self,
            comptime T: type,
            values: anytype,
        ) [N]T {
            return @import("internal/runtime/evaluation.zig").evaluateVectorAs(
                T,
                N,
                self,
                values,
            );
        }

        /// Evaluates all components into caller-owned storage.
        pub fn evalInto(comptime self: Self, output: anytype, values: anytype) void {
            return @import("internal/runtime/evaluation.zig").evaluateVectorInto(N, self, output, values);
        }

        /// Evaluates all components with `T` into caller-owned storage.
        pub fn evalIntoAs(
            comptime self: Self,
            comptime T: type,
            output: anytype,
            values: anytype,
        ) void {
            return @import("internal/runtime/evaluation.zig").evaluateVectorIntoAs(
                T,
                N,
                self,
                output,
                values,
            );
        }

        /// Renders all components in Bombelli's default notation.
        pub fn render(comptime self: Self) [N][]const u8 {
            @setEvalBranchQuota(limits.eval_branch.vector_render);
            return @import("internal/codegen/rendering.zig").renderVector(N, self);
        }

        /// Renders all components in the selected notation.
        pub fn renderMode(
            comptime self: Self,
            comptime mode: @import("internal/codegen/rendering.zig").RenderMode,
        ) [N][]const u8 {
            @setEvalBranchQuota(limits.eval_branch.vector_render);
            return @import("internal/codegen/rendering.zig").renderVectorMode(N, self, mode);
        }

        /// Emits a standalone source implementation of this vector.
        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(limits.eval_branch.polynomial);
            return @import("internal/codegen/emit.zig").emitVector(N, self, options);
        }

        /// Measures and validates the vector's shared DAG.
        pub fn metrics(comptime self: Self) @import("internal/core/metrics.zig").Metrics {
            @setEvalBranchQuota(limits.eval_branch.transform);
            return @import("internal/core/metrics.zig").measureVector(N, self);
        }
    };
}

/// Returns the immutable expression-matrix type with `R` rows and `C` columns.
pub fn ExprMatrix(comptime R: usize, comptime C: usize) type {
    return struct {
        nodes: []const Node,
        roots: [R][C]NodeId,
        sources: [R][C][]const u8,
        construction_peak_nodes: usize,

        const Self = @This();

        /// Returns a node from this matrix's shared DAG.
        pub fn node(self: Self, id: NodeId) Node {
            return self.nodes[@intCast(id)];
        }

        /// Extracts one scalar matrix entry.
        pub fn at(comptime self: Self, comptime row: usize, comptime column: usize) Expr {
            if (row >= R or column >= C) {
                @compileError("Bombelli matrix expression index is out of bounds");
            }
            return @import("internal/transform/multi.zig").matrixElement(R, C, self, row, column);
        }

        /// Symbolically differentiates every matrix entry.
        pub fn diff(comptime self: Self, comptime variable: anytype) Self {
            @setEvalBranchQuota(limits.eval_branch.polynomial);
            return @import("internal/transform/multi.zig").differentiateMatrix(R, C, self, variable);
        }

        /// Simplifies every entry while preserving shared nodes.
        pub fn simplify(comptime self: Self) Self {
            @setEvalBranchQuota(limits.eval_branch.polynomial);
            return @import("internal/transform/multi.zig").simplifyMatrix(R, C, self);
        }

        /// Substitutes symbols throughout every matrix entry.
        pub fn substitute(comptime self: Self, comptime replacements: anytype) Self {
            @setEvalBranchQuota(limits.eval_branch.polynomial);
            return @import("internal/transform/substitution.zig").substituteMatrix(
                R,
                C,
                self,
                replacements,
            );
        }

        /// Computes this square polynomial matrix's exact determinant.
        pub fn determinant(comptime self: Self) Expr {
            @setEvalBranchQuota(limits.eval_branch.solve);
            return @import("internal/algebra/determinant.zig").determinant(
                R,
                C,
                self,
            );
        }

        /// Evaluates all entries and returns a fixed-size matrix.
        pub fn eval(comptime self: Self, values: anytype) [R][C]f64 {
            return @import("internal/runtime/evaluation.zig").evaluateMatrix(R, C, self, values);
        }

        /// Evaluates all entries using the requested floating-point type.
        pub fn evalAs(
            comptime self: Self,
            comptime T: type,
            values: anytype,
        ) [R][C]T {
            return @import("internal/runtime/evaluation.zig").evaluateMatrixAs(
                T,
                R,
                C,
                self,
                values,
            );
        }

        /// Evaluates all entries into caller-owned storage.
        pub fn evalInto(comptime self: Self, output: anytype, values: anytype) void {
            return @import("internal/runtime/evaluation.zig").evaluateMatrixInto(R, C, self, output, values);
        }

        /// Evaluates all entries with `T` into caller-owned storage.
        pub fn evalIntoAs(
            comptime self: Self,
            comptime T: type,
            output: anytype,
            values: anytype,
        ) void {
            return @import("internal/runtime/evaluation.zig").evaluateMatrixIntoAs(
                T,
                R,
                C,
                self,
                output,
                values,
            );
        }

        /// Renders all entries in Bombelli's default notation.
        pub fn render(comptime self: Self) [R][C][]const u8 {
            @setEvalBranchQuota(limits.eval_branch.matrix_render);
            return @import("internal/codegen/rendering.zig").renderMatrix(R, C, self);
        }

        /// Renders all entries in the selected notation.
        pub fn renderMode(
            comptime self: Self,
            comptime mode: @import("internal/codegen/rendering.zig").RenderMode,
        ) [R][C][]const u8 {
            @setEvalBranchQuota(limits.eval_branch.matrix_render);
            return @import("internal/codegen/rendering.zig").renderMatrixMode(
                R,
                C,
                self,
                mode,
            );
        }

        /// Emits a standalone source implementation of this matrix.
        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(limits.eval_branch.rational);
            return @import("internal/codegen/emit.zig").emitMatrix(
                R,
                C,
                self,
                options,
            );
        }

        /// Measures and validates the matrix's shared DAG.
        pub fn metrics(comptime self: Self) @import("internal/core/metrics.zig").Metrics {
            @setEvalBranchQuota(limits.eval_branch.transform);
            return @import("internal/core/metrics.zig").measureMatrix(R, C, self);
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
        .constant => |value| value == right.constant,
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
