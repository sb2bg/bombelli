const ast = @import("../../expression.zig");
const domain = @import("../core/domain.zig");
const equation_module = @import("equation.zig");
const limits = @import("../core/limits.zig");

pub const SolveAlgorithm = @import("algorithm.zig").SolveAlgorithm;

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
            @setEvalBranchQuota(limits.eval_branch.solve);
            return @import("linear.zig").solveSystem(
                M,
                N,
                self,
                algorithm,
            );
        }

        pub fn factor(
            comptime self: Self,
            comptime algorithm: anytype,
        ) @import("linear.zig").Factorization(M, N, Assumptions) {
            @setEvalBranchQuota(limits.eval_branch.solve);
            return @import("linear.zig").factorSystem(
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
            @setEvalBranchQuota(limits.eval_branch.solve);
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
            @setEvalBranchQuota(limits.eval_branch.solve);
            const problem = systemFromEquation(N, Assumptions, self);
            return problem.solve(algorithm);
        }

        pub fn compile(
            comptime self: Self,
            comptime options: anytype,
        ) @import("newton.zig").NewtonSolver(N, options.max_iterations) {
            @setEvalBranchQuota(limits.eval_branch.solve);
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
        .residuals = @import("../transform/multi.zig").vector(1, .{value.equation.residual}),
        .unknowns = value.unknowns,
        .domain = value.domain,
        .assumptions = value.assumptions,
    };
}
