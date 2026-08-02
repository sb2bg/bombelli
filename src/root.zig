//! Bombelli's documented public package façade.

const std = @import("std");
const expression = @import("expression.zig");
const adaptive_quadrature = @import("internal/integrate/adaptive.zig");
const domain = @import("internal/core/domain.zig");
const equation_module = @import("internal/solve/equation.zig");
const evaluation = @import("internal/runtime/evaluation.zig");
const exact = @import("internal/core/exact.zig");
const gauss_legendre = @import("internal/integrate/gauss_legendre.zig");
const hybrid = @import("internal/integrate/hybrid.zig");
const integration = @import("internal/integrate/symbolic.zig");
/// Allocation-free numerical linear algebra over native fixed-size arrays.
pub const linalg = @import("linalg.zig");
const multi = @import("internal/transform/multi.zig");
const model_module = @import("model.zig");
const model_linearization = @import("internal/model/linearization.zig");
const newton = @import("internal/solve/newton.zig");
const least_squares = @import("internal/optimize/least_squares.zig");
const residual_model_module = @import("residual_model.zig");
const row_least_squares = @import("internal/optimize/row_least_squares.zig");
const optimize_types = @import("internal/optimize/types.zig");
const parser = @import("internal/parse/parser.zig");
const polynomial = @import("internal/algebra/polynomial.zig");
const problem = @import("internal/solve/problem.zig");
const rational_function = @import("internal/algebra/rational_function.zig");
const rendering = @import("internal/codegen/rendering.zig");
const solution_set = @import("internal/solve/solution_set.zig");
const emit_codegen = @import("internal/codegen/emit.zig");
const system_module = @import("internal/solve/system.zig");

/// A compile-time scalar expression backed by a canonical shared DAG.
pub const Expr = expression.Expr;
/// Returns the type of a fixed-size compile-time expression vector.
pub const ExprVector = expression.ExprVector;
/// Returns the type of a fixed-size compile-time expression matrix.
pub const ExprMatrix = expression.ExprMatrix;
/// Returns the type of a fixed-output differentiable model.
pub const Model = model_module.Model;
/// Returns the type of a residual kernel evaluated over runtime observations.
pub const ResidualModel = residual_model_module.ResidualModel;
/// Returns the type of a fused value-and-Jacobian program.
pub const Linearization = model_linearization.Program;
/// Returns the result type from fused value-and-Jacobian evaluation.
pub const LinearizationResult = model_linearization.Result;
/// Structural and construction measurements for a compiled expression.
pub const Metrics = @import("internal/core/metrics.zig").Metrics;
/// Runtime validation errors produced by batch evaluation.
pub const BatchInputError = evaluation.BatchInputError;
/// Threading and partitioning controls for parallel batch evaluation.
pub const BatchOptions = evaluation.BatchOptions;
/// Bombelli's fixed-width exact integer representation.
pub const Integer = exact.Integer;
/// A normalized exact rational number.
pub const Rational = exact.Rational;
/// The mathematical domain in which an operation is interpreted.
pub const Domain = domain.Domain;
/// A local symbolic assumption attached to an operation or problem.
pub const Assumption = domain.Assumption;
/// A sparse exact multivariate polynomial.
pub const Polynomial = polynomial.Polynomial;
/// One coefficient-and-monomial entry in a sparse polynomial.
pub const PolynomialTerm = polynomial.Term;
/// A normalized ratio of exact multivariate polynomials.
pub const RationalFunction = rational_function.RationalFunction;
/// A condition that must hold for a rational-function denominator.
pub const DenominatorCondition = rational_function.DenominatorCondition;
/// Creates a positivity assumption for a symbol, such as `positive(.x)`.
pub const positive = domain.positive;
/// Creates a nonzero assumption for a symbol, such as `nonzero(.a)`.
pub const nonzero = domain.nonzero;
/// A parsed equation retaining both sides and its residual expression.
pub const Equation = equation_module.Equation;
/// A condition attached to one or more solution branches.
pub const SolutionCondition = solution_set.Condition;
/// The relation represented by a solution condition.
pub const SolutionRelation = solution_set.Relation;
/// Returns the fixed-width solution-set type for `N` unknowns.
pub const SolutionSet = solution_set.SolutionSet;
/// Exact and symbolic algorithms available to equation problems.
pub const SolveAlgorithm = problem.SolveAlgorithm;
/// Algorithms available to symbolic integral problems.
pub const IntegrationAlgorithm = integration.IntegrationAlgorithm;
/// Symbolic lower and upper bounds for a definite integral.
pub const IntegralBounds = integration.IntegralBounds;
/// A symbolic integral that can be solved or compiled.
pub const IntegralProblem = integration.IntegralProblem;
/// A closed portion plus an unresolved symbolic integral remainder.
pub const PartialIntegral = integration.PartialIntegral;
/// A proof explaining why an elementary antiderivative is unavailable.
pub const IntegrationProof = integration.Proof;
/// A diagnostic explaining an unsupported integration form.
pub const IntegrationDiagnostic = integration.IntegrationDiagnostic;
/// The result of symbolic integration.
pub const IntegrationResult = integration.IntegrationResult;
/// Fixed quadrature families supported by Bombelli.
pub const QuadratureKind = gauss_legendre.QuadratureKind;
/// Returns a fixed-order Gauss-Legendre quadrature program type.
pub const QuadratureRule = gauss_legendre.QuadratureRule;
/// Returns the type of a bounded adaptive quadrature program.
pub const AdaptiveQuadratureRule =
    adaptive_quadrature.AdaptiveQuadratureRule;
/// The value and convergence metadata from adaptive quadrature.
pub const AdaptiveQuadratureResult = adaptive_quadrature.AdaptiveResult;
/// Completion status from bounded adaptive quadrature.
pub const AdaptiveQuadratureStatus = adaptive_quadrature.AdaptiveStatus;
/// Returns the type of a compiled symbolic-plus-numerical integral.
pub const HybridIntegral = hybrid.HybridIntegral;
/// Completion status from a generated Newton solver.
pub const NewtonStatus = newton.NewtonStatus;
/// Newton step globalization strategy.
pub const NewtonGlobalization = newton.NewtonGlobalization;
/// Returns the result type for a Newton solver with `N` unknowns.
pub const NewtonResult = newton.NewtonResult;
/// Returns a Newton result type whose scalar follows `problem_domain`.
pub const NewtonResultForDomain = newton.NewtonResultForDomain;
/// Returns a fixed-size compiled Newton solver type.
pub const NewtonSolver = newton.NewtonSolver;
/// Returns a fixed-size Newton solver type specialized for a domain.
pub const NewtonSolverForDomain = newton.NewtonSolverForDomain;
/// Completion status from implicit Newton sensitivity evaluation.
pub const NewtonSensitivityStatus = newton.SensitivityStatus;
/// Returns the result type for implicit solver sensitivities.
pub const NewtonSensitivityResult = newton.SensitivityResult;
/// Returns an implicit-sensitivity result type specialized for a domain.
pub const NewtonSensitivityResultForDomain = newton.SensitivityResultForDomain;
/// Returns a compiled implicit-sensitivity solver type.
pub const NewtonSensitivitySolver = newton.NewtonSensitivitySolver;
/// Returns an implicit-sensitivity solver type specialized for a domain.
pub const NewtonSensitivitySolverForDomain =
    newton.NewtonSensitivitySolverForDomain;
/// Robust scalar-residual loss configuration.
pub const Loss = optimize_types.Loss;
/// Robust scalar-residual loss families.
pub const LossKind = optimize_types.LossKind;
/// Type-safe robust-loss constructors.
pub const loss = optimize_types.loss;
/// Parameter scaling strategies for nonlinear least squares.
pub const LeastSquaresScaling = optimize_types.LeastSquaresScaling;
/// Initial-bound handling for nonlinear least squares.
pub const InitialBoundsPolicy = optimize_types.InitialBoundsPolicy;
/// Completion reason from a nonlinear least-squares solve.
pub const LeastSquaresStatus = optimize_types.LeastSquaresStatus;
/// Returns the reusable nonlinear least-squares problem type.
pub const LeastSquaresProblem = least_squares.LeastSquaresProblem;
/// Returns a compiled fixed-size nonlinear least-squares solver type.
pub const LeastSquaresSolver = least_squares.LeastSquaresSolver;
/// Returns a nonlinear least-squares result type.
pub const LeastSquaresResult = least_squares.LeastSquaresResult;
/// Completion reason from runtime-observation nonlinear least squares.
pub const RowLeastSquaresStatus = row_least_squares.Status;
/// Whether a runtime-observation fit parameter is active at a bound.
pub const RowLeastSquaresBoundActivity = row_least_squares.BoundActivity;
/// Returns a runtime-observation nonlinear least-squares problem type.
pub const RowLeastSquaresProblem = row_least_squares.Problem;
/// Returns an allocation-free runtime-observation solver type.
pub const RowLeastSquaresSolver = row_least_squares.Solver;
/// Returns a runtime-observation nonlinear least-squares result type.
pub const RowLeastSquaresResult = row_least_squares.Result;
/// Human-readable expression rendering modes.
pub const RenderMode = rendering.RenderMode;
/// Source languages supported by Bombelli emission.
pub const EmitTarget = emit_codegen.EmitTarget;
/// Calling conventions supported by Bombelli emission.
pub const EmitMode = emit_codegen.EmitMode;
/// Structural helpers for evaluating and emitting compiled Bombelli values.
pub const callable = @import("callable.zig");
/// Evaluates a possibly temporary compiled value.
///
/// This free-function form also works around a Zig 0.16 compiler bug affecting
/// chained method calls on temporary comptime programs.
pub const eval = callable.eval;
/// Evaluates a possibly temporary expression program using scalar type `T`.
pub const evalAs = callable.evalAs;
/// Evaluates a possibly temporary compiled value into caller-owned storage.
pub const evalInto = callable.evalInto;
/// Typed caller-owned evaluation for a possibly temporary expression program.
pub const evalIntoAs = callable.evalIntoAs;
/// Unstable utilities for Bombelli's tests and downstream package tests.
pub const testing = @import("testing.zig");

/// Parses `source` into a compile-time expression.
pub fn expr(comptime source: []const u8) Expr {
    return parser.parse(source);
}

/// Constructs a normalized exact rational or emits a compile-time diagnostic.
pub fn rational(comptime numerator: Integer, comptime denominator: Integer) Rational {
    return Rational.init(numerator, denominator) catch |err| switch (err) {
        error.ZeroDenominator => @compileError("Bombelli rational denominator cannot be zero"),
        error.Overflow => @compileError("Bombelli rational does not fit fixed-width storage"),
    };
}

/// Parses a source string containing exactly one equality.
pub fn equation(comptime source: []const u8) Equation {
    return equation_module.parse(source);
}

/// Builds a typed equation-system problem from source strings and options.
pub fn system(
    comptime sources: anytype,
    comptime options: anytype,
) system_module.SystemType(@TypeOf(sources), @TypeOf(options)) {
    return system_module.make(sources, options);
}

/// Builds a typed single-equation problem from a source string and options.
pub fn equationProblem(
    comptime source: []const u8,
    comptime options: anytype,
) system_module.EquationProblemType(@TypeOf(options)) {
    return system_module.makeEquationProblem(source, options);
}

/// Parses a non-empty tuple of sources into one shared expression vector.
pub fn exprVector(comptime sources: anytype) ExprVector(expression.tupleLength(@TypeOf(sources))) {
    const N = expression.tupleLength(@TypeOf(sources));
    if (N == 0) @compileError("Bombelli expression vector expects at least one output");
    var expressions: [N]Expr = undefined;
    inline for (sources, 0..) |source, index| {
        expressions[index] = expr(source);
    }
    return multi.vector(N, expressions);
}

/// Parses a non-empty rectangular tuple of rows into one shared matrix.
pub fn exprMatrix(comptime sources: anytype) ExprMatrix(
    expression.tupleLength(@TypeOf(sources)),
    matrixColumnCount(@TypeOf(sources)),
) {
    const R = expression.tupleLength(@TypeOf(sources));
    const C = matrixColumnCount(@TypeOf(sources));
    var expressions: [R][C]Expr = undefined;
    inline for (sources, 0..) |row, row_index| {
        if (expression.tupleLength(@TypeOf(row)) != C) {
            @compileError("Bombelli expression matrix rows must have equal lengths");
        }
        inline for (row, 0..) |source, column_index| {
            expressions[row_index][column_index] = expr(source);
        }
    }
    return multi.matrix(R, C, expressions);
}

/// Builds a typed differentiable model from output expressions and variables.
pub fn model(
    comptime sources: anytype,
    comptime options: anytype,
) model_module.ModelType(@TypeOf(sources), @TypeOf(options)) {
    return model_module.make(sources, options);
}

/// Builds a symbolic residual kernel for fitting runtime observation slices.
pub fn residualModel(
    comptime sources: anytype,
    comptime options: anytype,
) residual_model_module.ResidualModelType(
    @TypeOf(sources),
    @TypeOf(options),
) {
    return residual_model_module.make(sources, options);
}

fn matrixColumnCount(comptime T: type) usize {
    const info = @typeInfo(T).@"struct";
    if (!info.is_tuple or info.fields.len == 0) {
        @compileError("Bombelli expression matrix expects a non-empty tuple of rows");
    }
    const columns = expression.tupleLength(info.fields[0].type);
    if (columns == 0) {
        @compileError("Bombelli expression matrix expects at least one column");
    }
    return columns;
}

test {
    std.testing.refAllDecls(@This());
}
