const std = @import("std");
const ast = @import("ast.zig");
const domain = @import("domain.zig");
const exact = @import("exact.zig");
const multi = @import("multi.zig");
const parser = @import("parser.zig");
const polynomial = @import("polynomial.zig");
const problem_module = @import("problem.zig");
const rational_function = @import("rational_function.zig");
const solution = @import("solution_set.zig");

pub fn Factorization(
    comptime M: usize,
    comptime N: usize,
    comptime Assumptions: type,
) type {
    return struct {
        coefficients: [M][N]polynomial.Polynomial,
        unknowns: [N][]const u8,
        domain: domain.Domain,
        assumptions: Assumptions,
        algorithm: problem_module.SolveAlgorithm,

        const Self = @This();

        pub fn solve(
            comptime self: Self,
            comptime rhs: anytype,
        ) solution.SolutionSet(N) {
            @setEvalBranchQuota(50_000_000);
            if (ast.tupleLength(@TypeOf(rhs)) != M) {
                @compileError("Bombelli factorization right-hand side has the wrong length");
            }
            var right_hand_side: [M]polynomial.Polynomial = undefined;
            inline for (rhs, 0..) |value, index| {
                right_hand_side[index] = valuePolynomial(value);
            }
            return solveData(
                M,
                N,
                self.coefficients,
                right_hand_side,
                self.domain,
                self.algorithm,
            );
        }
    };
}

pub fn factorSystem(
    comptime M: usize,
    comptime N: usize,
    comptime Assumptions: type,
    comptime problem: problem_module.SystemProblem(M, N, Assumptions),
    comptime algorithm_value: anytype,
) Factorization(M, N, Assumptions) {
    const algorithm = parseAlgorithm(algorithm_value);
    const extracted = extractLinearSystem(M, N, problem);
    return .{
        .coefficients = extracted.coefficients,
        .unknowns = problem.unknowns,
        .domain = problem.domain,
        .assumptions = problem.assumptions,
        .algorithm = algorithm,
    };
}

pub fn solveSystem(
    comptime M: usize,
    comptime N: usize,
    comptime Assumptions: type,
    comptime problem: problem_module.SystemProblem(M, N, Assumptions),
    comptime algorithm_value: anytype,
) solution.SolutionSet(N) {
    const algorithm = parseAlgorithm(algorithm_value);
    if (algorithm == .polynomial) {
        if (M != 1 or N != 1) {
            @compileError("Bombelli polynomial equation solving currently requires one equation and one unknown");
        }
        return @import("polynomial_solver.zig").solve(
            problem.equations[0],
            problem.unknowns[0],
            problem.domain,
        );
    }
    const extracted = extractLinearSystem(M, N, problem);
    return solveData(
        M,
        N,
        extracted.coefficients,
        extracted.rhs,
        problem.domain,
        algorithm,
    );
}

fn Extracted(comptime M: usize, comptime N: usize) type {
    return struct {
        coefficients: [M][N]polynomial.Polynomial,
        rhs: [M]polynomial.Polynomial,
    };
}

fn extractLinearSystem(
    comptime M: usize,
    comptime N: usize,
    comptime problem: anytype,
) Extracted(M, N) {
    var result: Extracted(M, N) = undefined;
    inline for (problem.equations, 0..) |equation, row| {
        const residual = polynomial.fromExpr(equation.residual);
        for (residual.terms) |term| {
            var unknown_degree: u32 = 0;
            inline for (problem.unknowns) |unknown| {
                const variable_index = findName(residual.variable_names, unknown);
                if (variable_index) |index| unknown_degree += term.exponents[index];
            }
            if (unknown_degree > 1) {
                @compileError("Bombelli linear solver received a nonlinear equation");
            }
        }

        var constant_part = residual;
        inline for (problem.unknowns, 0..) |unknown, column| {
            const coefficient = residual.diffName(unknown);
            inline for (problem.unknowns) |candidate| {
                if (coefficient.dependsOn(candidate)) {
                    @compileError("Bombelli linear solver received a nonlinear equation");
                }
            }
            result.coefficients[row][column] = coefficient;
            constant_part = constant_part.sub(
                coefficient.mul(polynomial.indeterminate(unknown)),
            );
        }
        result.rhs[row] = constant_part.scale(exact.Rational.fromInteger(-1));
    }
    return result;
}

fn solveData(
    comptime M: usize,
    comptime N: usize,
    comptime coefficients: [M][N]polynomial.Polynomial,
    comptime rhs: [M]polynomial.Polynomial,
    comptime problem_domain: domain.Domain,
    comptime algorithm: problem_module.SolveAlgorithm,
) solution.SolutionSet(N) {
    var exact_matrix: [M][N + 1]exact.Rational = undefined;
    var all_exact = true;
    inline for (0..M) |row| {
        inline for (0..N) |column| {
            exact_matrix[row][column] = polynomial.constantValue(
                coefficients[row][column],
            ) orelse blk: {
                all_exact = false;
                break :blk exact.Rational.fromInteger(0);
            };
        }
        exact_matrix[row][N] = polynomial.constantValue(rhs[row]) orelse blk: {
            all_exact = false;
            break :blk exact.Rational.fromInteger(0);
        };
    }
    if (all_exact) {
        return solveExact(M, N, exact_matrix, problem_domain);
    }
    if (algorithm != .bareiss) {
        @compileError("Bombelli symbolic linear coefficients require the .bareiss algorithm");
    }
    return solveSymbolic(M, N, coefficients, rhs, problem_domain);
}

fn solveExact(
    comptime M: usize,
    comptime N: usize,
    comptime input: [M][N + 1]exact.Rational,
    comptime problem_domain: domain.Domain,
) solution.SolutionSet(N) {
    var matrix = input;
    var pivot_columns: [@min(M, N)]usize = undefined;
    var rank: usize = 0;
    var column: usize = 0;
    while (column < N and rank < M) : (column += 1) {
        var pivot: ?usize = null;
        for (rank..M) |row| {
            if (!matrix[row][column].isZero()) {
                pivot = row;
                break;
            }
        }
        if (pivot == null) continue;
        if (pivot.? != rank) {
            const temporary = matrix[rank];
            matrix[rank] = matrix[pivot.?];
            matrix[pivot.?] = temporary;
        }
        const pivot_value = matrix[rank][column];
        for (column..N + 1) |entry| {
            matrix[rank][entry] = checked(
                matrix[rank][entry].div(pivot_value),
            );
        }
        for (0..M) |row| {
            if (row == rank or matrix[row][column].isZero()) continue;
            const factor = matrix[row][column];
            for (column..N + 1) |entry| {
                matrix[row][entry] = checked(matrix[row][entry].sub(
                    checked(factor.mul(matrix[rank][entry])),
                ));
            }
        }
        pivot_columns[rank] = column;
        rank += 1;
    }

    for (0..M) |row| {
        var zero_coefficients = true;
        for (0..N) |entry| {
            if (!matrix[row][entry].isZero()) zero_coefficients = false;
        }
        if (zero_coefficients and !matrix[row][N].isZero()) {
            return .{ .empty = problem_domain };
        }
    }
    if (rank == 0) return .{ .all = problem_domain };
    if (rank == N) {
        var expressions: [1][N]ast.Expr = undefined;
        for (0..rank) |row| {
            expressions[0][pivot_columns[row]] = rationalExpression(matrix[row][N]);
        }
        const values = multi.matrix(1, N, expressions);
        return .{ .finite = solution.finiteFromMatrix(1, N, values) };
    }

    var is_pivot = [_]bool{false} ** N;
    for (pivot_columns[0..rank]) |pivot| is_pivot[pivot] = true;
    var parameter_names: [N][]const u8 = undefined;
    var parameter_for_column: [N]?[]const u8 = [_]?[]const u8{null} ** N;
    var parameter_count: usize = 0;
    for (0..N) |free_column| {
        if (is_pivot[free_column]) continue;
        const name = std.fmt.comptimePrint("t{d}", .{parameter_count});
        parameter_names[parameter_count] = name;
        parameter_for_column[free_column] = name;
        parameter_count += 1;
    }

    var value_expressions: [N]ast.Expr = undefined;
    for (0..N) |unknown_column| {
        if (!is_pivot[unknown_column]) {
            value_expressions[unknown_column] = parser.parse(
                parameter_for_column[unknown_column].?,
            );
            continue;
        }
        var pivot_row: usize = 0;
        while (pivot_columns[pivot_row] != unknown_column) : (pivot_row += 1) {}
        var source = rationalSource(matrix[pivot_row][N]);
        for (0..N) |free_column| {
            if (is_pivot[free_column] or matrix[pivot_row][free_column].isZero()) continue;
            source = std.fmt.comptimePrint(
                "({s}) - ({s})*{s}",
                .{
                    source,
                    rationalSource(matrix[pivot_row][free_column]),
                    parameter_for_column[free_column].?,
                },
            );
        }
        value_expressions[unknown_column] = parser.parse(source).simplify();
    }
    const values = multi.vector(N, value_expressions);
    const exact_parameters = parameter_names[0..parameter_count].*;
    return .{ .parametric = .{
        .values = values,
        .parameters = &exact_parameters,
        .domain = problem_domain,
    } };
}

fn solveSymbolic(
    comptime M: usize,
    comptime N: usize,
    comptime coefficients: [M][N]polynomial.Polynomial,
    comptime rhs: [M]polynomial.Polynomial,
    comptime problem_domain: domain.Domain,
) solution.SolutionSet(N) {
    _ = problem_domain;
    if (M != N) {
        @compileError("Bombelli symbolic Bareiss elimination currently requires a square system");
    }

    var matrix: [N][N + 1]polynomial.Polynomial = undefined;
    inline for (0..N) |row| {
        inline for (0..N) |column| {
            matrix[row][column] = coefficients[row][column];
        }
        matrix[row][N] = rhs[row];
    }
    var previous_pivot = polynomial.exactConstant(
        exact.Rational.fromInteger(1),
    );

    for (0..N) |pivot_index| {
        var pivot_row: ?usize = null;
        for (pivot_index..N) |candidate| {
            if (matrix[candidate][pivot_index].terms.len != 0) {
                pivot_row = candidate;
                break;
            }
        }
        if (pivot_row == null) {
            @compileError("Bombelli symbolic Bareiss elimination found an identically singular coefficient matrix");
        }
        if (pivot_row.? != pivot_index) {
            const temporary = matrix[pivot_index];
            matrix[pivot_index] = matrix[pivot_row.?];
            matrix[pivot_row.?] = temporary;
        }

        const old = matrix;
        const pivot = old[pivot_index][pivot_index];
        for (0..N) |row| {
            if (row == pivot_index) continue;
            for (0..N + 1) |column| {
                if (column == pivot_index) continue;
                const numerator = pivot.mul(old[row][column]).sub(
                    old[row][pivot_index].mul(old[pivot_index][column]),
                );
                matrix[row][column] = numerator.divideExact(
                    previous_pivot,
                ) orelse @compileError(
                    "Bombelli Bareiss division was not exact in the polynomial coefficient domain",
                );
            }
            matrix[row][pivot_index] = polynomial.exactConstant(
                exact.Rational.fromInteger(0),
            );
        }
        previous_pivot = pivot;
    }

    const determinant = matrix[0][0];
    if (determinant.terms.len == 0) {
        @compileError("Bombelli symbolic Bareiss elimination found an identically zero determinant");
    }
    var expressions: [N]ast.Expr = undefined;
    inline for (0..N) |row| {
        if (!matrix[row][row].eql(determinant)) {
            @compileError("Bombelli fraction-free diagonalization produced inconsistent determinant pivots");
        }
        expressions[row] = rational_function.fromPolynomials(
            matrix[row][N],
            determinant,
        ).toExpr();
    }
    const values = multi.vector(N, expressions);
    const condition = solution.Condition{
        .expression = determinant.toExpr(),
        .relation = .nonzero,
    };
    return .{ .conditional = .{
        .values = values,
        .conditions = &.{condition},
    } };
}

fn valuePolynomial(comptime value: anytype) polynomial.Polynomial {
    const T = @TypeOf(value);
    if (T == exact.Rational) return polynomial.exactConstant(value);
    if (T == ast.Expr) return polynomial.fromExpr(value);
    return switch (@typeInfo(T)) {
        .comptime_int, .int => polynomial.exactConstant(
            exact.Rational.fromInteger(@intCast(value)),
        ),
        .pointer => parser.parse(value).asPolynomial(),
        else => @compileError("Bombelli factorization right-hand side must be exact or symbolic"),
    };
}

fn rationalExpression(comptime value: exact.Rational) ast.Expr {
    return parser.parse(rationalSource(value)).simplify();
}

fn rationalSource(comptime value: exact.Rational) []const u8 {
    return if (value.denominator == 1)
        std.fmt.comptimePrint("{d}", .{value.numerator})
    else
        std.fmt.comptimePrint("({d}/{d})", .{
            value.numerator,
            value.denominator,
        });
}

fn checked(result: exact.Error!exact.Rational) exact.Rational {
    return result catch @panic("Bombelli exact linear elimination overflowed");
}

fn parseAlgorithm(comptime value: anytype) problem_module.SolveAlgorithm {
    const name = @tagName(value);
    inline for (@typeInfo(problem_module.SolveAlgorithm).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    @compileError(std.fmt.comptimePrint(
        "Bombelli does not support the solver algorithm '.{s}'",
        .{name},
    ));
}

fn findName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return index;
    }
    return null;
}
