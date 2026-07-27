const std = @import("std");
const ast = @import("../../expression.zig");
const domain = @import("../core/domain.zig");
const multi = @import("../transform/multi.zig");

pub const Relation = enum {
    equal_zero,
    nonzero,
    positive,
};

pub const Condition = struct {
    expression: ast.Expr,
    relation: Relation,

    pub fn render(comptime self: Condition) []const u8 {
        return std.fmt.comptimePrint(
            "{s} {s}",
            .{
                self.expression.render(),
                switch (self.relation) {
                    .equal_zero => "= 0",
                    .nonzero => "!= 0",
                    .positive => "> 0",
                },
            },
        );
    }
};

pub fn FiniteSolutions(comptime N: usize) type {
    return struct {
        nodes: []const ast.Node,
        roots: []const ast.NodeId,
        sources: []const []const u8,
        branch_count: usize,

        const Self = @This();

        pub fn branch(comptime self: Self, comptime index: usize) ast.ExprVector(N) {
            if (index >= self.branch_count) {
                @compileError("Bombelli finite-solution branch index is out of bounds");
            }
            var expressions: [N]ast.Expr = undefined;
            inline for (0..N) |column| {
                const flat_index = index * N + column;
                expressions[column] = multi.extractRoot(
                    self.nodes,
                    self.roots[flat_index],
                    self.sources[flat_index],
                );
            }
            return multi.vector(N, expressions);
        }
    };
}

pub fn ParametricSolution(comptime N: usize) type {
    return struct {
        values: ast.ExprVector(N),
        parameters: []const []const u8,
        domain: domain.Domain,
    };
}

pub fn ConditionalSolution(comptime N: usize) type {
    return struct {
        values: ast.ExprVector(N),
        conditions: []const Condition,
    };
}

pub fn PartialSolution(comptime N: usize) type {
    return struct {
        solved: FiniteSolutions(N),
        unresolved_equations: []const []const u8,
    };
}

pub fn SolutionSet(comptime N: usize) type {
    return union(enum) {
        empty: domain.Domain,
        all: domain.Domain,
        finite: FiniteSolutions(N),
        parametric: ParametricSolution(N),
        conditional: ConditionalSolution(N),
        partial: PartialSolution(N),

        const Self = @This();

        pub fn requireFinite(comptime self: Self) FiniteSolutions(N) {
            return switch (self) {
                .finite => |solutions| solutions,
                .empty => @compileError("Bombelli expected finite solutions, but the solution set is empty"),
                .all => @compileError("Bombelli expected finite solutions, but every value is a solution"),
                .parametric => @compileError("Bombelli expected finite solutions, but the result is parametric"),
                .conditional => @compileError("Bombelli expected finite solutions, but the result is conditional"),
                .partial => @compileError("Bombelli expected finite solutions, but unresolved branches remain"),
            };
        }

        pub fn requireUnique(comptime self: Self) ast.ExprVector(N) {
            const finite = self.requireFinite();
            if (finite.branch_count != 1) {
                @compileError(std.fmt.comptimePrint(
                    "Bombelli expected one solution, but found {d}",
                    .{finite.branch_count},
                ));
            }
            return finite.branch(0);
        }

        pub fn requireSingle(comptime self: Self) ast.ExprVector(N) {
            return self.requireUnique();
        }
    };
}

pub fn finiteFromMatrix(
    comptime K: usize,
    comptime N: usize,
    comptime values: ast.ExprMatrix(K, N),
) FiniteSolutions(N) {
    var roots: [K * N]ast.NodeId = undefined;
    var sources: [K * N][]const u8 = undefined;
    inline for (0..K) |row| {
        inline for (0..N) |column| {
            roots[row * N + column] = values.roots[row][column];
            sources[row * N + column] = values.sources[row][column];
        }
    }
    const exact_roots = roots[0 .. K * N].*;
    const exact_sources = sources[0 .. K * N].*;
    return .{
        .nodes = values.nodes,
        .roots = &exact_roots,
        .sources = &exact_sources,
        .branch_count = K,
    };
}
