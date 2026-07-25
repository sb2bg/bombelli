const std = @import("std");
const ast = @import("ast.zig");
const domain = @import("domain.zig");
const equation_module = @import("equation.zig");
const exact = @import("exact.zig");
const multi = @import("multi.zig");
const parser = @import("parser.zig");
const polynomial = @import("polynomial.zig");
const solution = @import("solution_set.zig");

pub fn solve(
    comptime equation: equation_module.Equation,
    comptime unknown: []const u8,
    comptime problem_domain: domain.Domain,
) solution.SolutionSet(1) {
    const value = polynomial.fromExpr(equation.residual);
    var coefficients = [_]exact.Rational{
        exact.Rational.fromInteger(0),
    } ** 3;
    for (value.terms) |term| {
        var unknown_exponent: u32 = 0;
        for (value.variable_names, term.exponents) |name, exponent| {
            if (std.mem.eql(u8, name, unknown)) {
                unknown_exponent = exponent;
            } else if (exponent != 0) {
                @compileError("Bombelli polynomial equation solving currently requires constant coefficients");
            }
        }
        if (unknown_exponent > 2) {
            @compileError("Bombelli polynomial equation solving currently supports degree at most two");
        }
        coefficients[unknown_exponent] = checked(
            coefficients[unknown_exponent].add(term.coefficient),
        );
    }

    const c = coefficients[0];
    const b = coefficients[1];
    const a = coefficients[2];
    if (a.isZero()) {
        if (b.isZero()) {
            return if (c.isZero())
                .{ .all = problem_domain }
            else
                .{ .empty = problem_domain };
        }
        const root = checked(c.negate()).div(b) catch
            @panic("Bombelli exact linear root overflowed");
        return finiteOne(rationalExpression(root));
    }

    const four_ac = checked(
        exact.Rational.fromInteger(4).mul(checked(a.mul(c))),
    );
    const discriminant = checked(checked(b.mul(b)).sub(four_ac));
    if (problem_domain == .real and discriminant.numerator < 0) {
        return .{ .empty = problem_domain };
    }

    const denominator = checked(exact.Rational.fromInteger(2).mul(a));
    if (exactSquareRoot(discriminant)) |square_root| {
        const negative_b = checked(b.negate());
        const first = checked(checked(negative_b.sub(square_root)).div(denominator));
        if (square_root.isZero()) return finiteOne(rationalExpression(first));
        const second = checked(checked(negative_b.add(square_root)).div(denominator));
        return finiteTwo(rationalExpression(first), rationalExpression(second));
    }

    const b_source = rationalSource(b);
    const discriminant_source = rationalSource(discriminant);
    const denominator_source = rationalSource(denominator);
    const first = parser.parse(std.fmt.comptimePrint(
        "(-({s}) - sqrt({s})) / ({s})",
        .{ b_source, discriminant_source, denominator_source },
    )).simplify();
    const second = parser.parse(std.fmt.comptimePrint(
        "(-({s}) + sqrt({s})) / ({s})",
        .{ b_source, discriminant_source, denominator_source },
    )).simplify();
    return finiteTwo(first, second);
}

fn finiteOne(comptime value: ast.Expr) solution.SolutionSet(1) {
    const expressions = [1][1]ast.Expr{.{value}};
    const values = multi.matrix(1, 1, expressions);
    return .{ .finite = solution.finiteFromMatrix(1, 1, values) };
}

fn finiteTwo(
    comptime first: ast.Expr,
    comptime second: ast.Expr,
) solution.SolutionSet(1) {
    const expressions = [2][1]ast.Expr{ .{first}, .{second} };
    const values = multi.matrix(2, 1, expressions);
    return .{ .finite = solution.finiteFromMatrix(2, 1, values) };
}

fn exactSquareRoot(value: exact.Rational) ?exact.Rational {
    if (value.numerator < 0) return null;
    const numerator: u64 = @intCast(value.numerator);
    const numerator_root = integerSquareRoot(numerator);
    const denominator_root = integerSquareRoot(value.denominator);
    if (numerator_root * numerator_root != numerator or
        denominator_root * denominator_root != value.denominator)
    {
        return null;
    }
    return exact.Rational.init(
        @intCast(numerator_root),
        @intCast(denominator_root),
    ) catch null;
}

fn integerSquareRoot(value: u64) u64 {
    if (value < 2) return value;
    var low: u64 = 1;
    var high: u64 = @min(value, @as(u64, 1) << 32);
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (middle <= value / middle)
            low = middle
        else
            high = middle;
    }
    return low;
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
    return result catch @panic("Bombelli exact polynomial root arithmetic overflowed");
}
