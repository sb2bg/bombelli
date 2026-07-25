const ast = @import("ast.zig");
const domain = @import("domain.zig");
const equation_module = @import("equation.zig");

pub const SolveAlgorithm = enum {
    gaussian,
    bareiss,
    polynomial,
};

pub fn SystemProblem(
    comptime M: usize,
    comptime N: usize,
    comptime Assumptions: type,
) type {
    return struct {
        equations: [M]equation_module.Equation,
        residuals: ast.ExprVector(M),
        unknowns: [N][]const u8,
        domain: domain.Domain,
        assumptions: Assumptions,

        const Self = @This();

        pub fn solve(
            comptime self: Self,
            comptime algorithm: anytype,
        ) @import("solution_set.zig").SolutionSet(N) {
            @setEvalBranchQuota(50_000_000);
            return @import("linear_solver.zig").solveSystem(
                M,
                N,
                Assumptions,
                self,
                algorithm,
            );
        }

        pub fn factor(
            comptime self: Self,
            comptime algorithm: anytype,
        ) @import("linear_solver.zig").Factorization(M, N, Assumptions) {
            @setEvalBranchQuota(50_000_000);
            return @import("linear_solver.zig").factorSystem(
                M,
                N,
                Assumptions,
                self,
                algorithm,
            );
        }

        pub fn compile(
            comptime self: Self,
            comptime options: anytype,
        ) @import("newton.zig").NewtonSolver(N, options.max_iterations) {
            @setEvalBranchQuota(50_000_000);
            return @import("newton.zig").compileSystem(
                M,
                N,
                self,
                options,
            );
        }
    };
}

pub fn EquationProblem(
    comptime N: usize,
    comptime Assumptions: type,
) type {
    return struct {
        equation: equation_module.Equation,
        unknowns: [N][]const u8,
        domain: domain.Domain,
        assumptions: Assumptions,

        const Self = @This();

        pub fn solve(
            comptime self: Self,
            comptime algorithm: anytype,
        ) @import("solution_set.zig").SolutionSet(N) {
            @setEvalBranchQuota(50_000_000);
            const problem = systemFromEquation(N, Assumptions, self);
            return problem.solve(algorithm);
        }

        pub fn compile(
            comptime self: Self,
            comptime options: anytype,
        ) @import("newton.zig").NewtonSolver(N, options.max_iterations) {
            @setEvalBranchQuota(50_000_000);
            const problem = systemFromEquation(N, Assumptions, self);
            return problem.compile(options);
        }
    };
}

fn systemFromEquation(
    comptime N: usize,
    comptime Assumptions: type,
    comptime value: EquationProblem(N, Assumptions),
) SystemProblem(1, N, Assumptions) {
    return .{
        .equations = .{value.equation},
        .residuals = @import("multi.zig").vector(1, .{value.equation.residual}),
        .unknowns = value.unknowns,
        .domain = value.domain,
        .assumptions = value.assumptions,
    };
}
