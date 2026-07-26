const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");
const exact = @import("exact.zig");

const term_limit = ast.construction_node_limit;
const variable_limit = 128;

pub const Term = struct {
    coefficient: exact.Rational,
    exponents: []const u32,
};

pub const Polynomial = struct {
    variable_names: []const []const u8,
    terms: []const Term,

    pub fn eql(comptime self: Polynomial, comptime other: Polynomial) bool {
        const difference = self.sub(other);
        return difference.terms.len == 0;
    }

    pub fn add(comptime self: Polynomial, comptime other: Polynomial) Polynomial {
        const common_variables = comptime unionVariables(
            self.variable_names,
            other.variable_names,
        );
        const left = alignTo(self, common_variables);
        const right = alignTo(other, common_variables);
        var raw: [term_limit]RawTerm = undefined;
        var len: usize = 0;
        appendTerms(&raw, &len, left);
        appendTerms(&raw, &len, right);
        return finish(common_variables, raw[0..len]);
    }

    pub fn sub(comptime self: Polynomial, comptime other: Polynomial) Polynomial {
        return self.add(other.scale(exact.Rational.fromInteger(-1)));
    }

    pub fn mul(comptime self: Polynomial, comptime other: Polynomial) Polynomial {
        const common_variables = comptime unionVariables(
            self.variable_names,
            other.variable_names,
        );
        const left = alignTo(self, common_variables);
        const right = alignTo(other, common_variables);
        var raw: [term_limit]RawTerm = undefined;
        var len: usize = 0;
        for (left.terms) |left_term| {
            for (right.terms) |right_term| {
                var result = RawTerm{
                    .coefficient = left_term.coefficient.mul(
                        right_term.coefficient,
                    ) catch exactCapacityFailure(),
                    .exponents = [_]u32{0} ** variable_limit,
                };
                for (0..common_variables.len) |index| {
                    const sum = @addWithOverflow(
                        left_term.exponents[index],
                        right_term.exponents[index],
                    );
                    if (sum[1] != 0) {
                        @compileError("Bombelli polynomial exponent exceeds u32 range");
                    }
                    result.exponents[index] = sum[0];
                }
                accumulateRaw(
                    &raw,
                    &len,
                    result,
                    common_variables.len,
                );
            }
        }
        return finish(common_variables, raw[0..len]);
    }

    pub fn pow(comptime self: Polynomial, comptime exponent: u32) Polynomial {
        var result = constant(self.variable_names, exact.Rational.fromInteger(1));
        var factor = self;
        var remaining = exponent;
        while (remaining != 0) : (remaining /= 2) {
            if (remaining % 2 == 1) result = result.mul(factor);
            if (remaining > 1) factor = factor.mul(factor);
        }
        return result;
    }

    pub fn divideExact(
        comptime self: Polynomial,
        comptime divisor_input: Polynomial,
    ) ?Polynomial {
        if (divisor_input.terms.len == 0) {
            @compileError("Bombelli exact polynomial division by zero");
        }
        const common_variables = comptime unionVariables(
            self.variable_names,
            divisor_input.variable_names,
        );
        var remainder = alignTo(self, common_variables);
        const divisor = alignTo(divisor_input, common_variables);
        var quotient = zero(common_variables);
        var steps: usize = 0;
        while (remainder.terms.len != 0) {
            if (steps == term_limit) {
                @compileError("Bombelli exact polynomial division did not terminate within the term limit");
            }
            const remainder_leading = remainder.terms[0];
            const divisor_leading = divisor.terms[0];
            var quotient_raw = RawTerm{
                .coefficient = remainder_leading.coefficient.div(
                    divisor_leading.coefficient,
                ) catch exactCapacityFailure(),
                .exponents = [_]u32{0} ** variable_limit,
            };
            for (0..common_variables.len) |index| {
                if (remainder_leading.exponents[index] <
                    divisor_leading.exponents[index])
                {
                    return null;
                }
                quotient_raw.exponents[index] =
                    remainder_leading.exponents[index] -
                    divisor_leading.exponents[index];
            }
            const quotient_term = finish(
                common_variables,
                &.{quotient_raw},
            );
            quotient = quotient.add(quotient_term);
            remainder = remainder.sub(quotient_term.mul(divisor));
            steps += 1;
        }
        return quotient;
    }

    pub fn degree(comptime self: Polynomial) ?u32 {
        if (self.terms.len == 0) return null;
        var maximum: u32 = 0;
        inline for (self.terms) |term| {
            maximum = @max(maximum, totalDegree(term.exponents));
        }
        return maximum;
    }

    pub fn variables(comptime self: Polynomial) []const []const u8 {
        return self.variable_names;
    }

    pub fn coefficient(
        comptime self: Polynomial,
        comptime monomial: anytype,
    ) exact.Rational {
        var requested = [_]u32{0} ** variable_limit;
        inline for (self.variable_names, 0..) |name, index| {
            if (@hasField(@TypeOf(monomial), name)) {
                const exponent = @field(monomial, name);
                if (exponent < 0 or exponent > std.math.maxInt(u32)) {
                    @compileError("Bombelli monomial exponent must fit u32");
                }
                requested[index] = @intCast(exponent);
            }
        }
        inline for (self.terms) |term| {
            if (std.mem.eql(u32, term.exponents, requested[0..self.variable_names.len])) {
                return term.coefficient;
            }
        }
        return exact.Rational.fromInteger(0);
    }

    pub fn isLinear(comptime self: Polynomial) bool {
        for (self.terms) |term| {
            if (totalDegree(term.exponents) > 1) return false;
        }
        return true;
    }

    pub fn diff(comptime self: Polynomial, comptime variable: anytype) Polynomial {
        return self.diffName(@tagName(variable));
    }

    pub fn diffName(
        comptime self: Polynomial,
        comptime name: []const u8,
    ) Polynomial {
        const variable_index = findVariable(self.variable_names, name) orelse
            return zero(self.variable_names);
        var raw: [term_limit]RawTerm = undefined;
        var len: usize = 0;
        for (self.terms) |term| {
            const exponent = term.exponents[variable_index];
            if (exponent == 0) continue;
            var derivative = rawFromTerm(term, self.variable_names.len);
            derivative.coefficient = derivative.coefficient.mul(
                exact.Rational.fromInteger(exponent),
            ) catch exactCapacityFailure();
            derivative.exponents[variable_index] -= 1;
            raw[len] = derivative;
            len += 1;
        }
        return finish(self.variable_names, raw[0..len]);
    }

    pub fn dependsOn(
        comptime self: Polynomial,
        comptime name: []const u8,
    ) bool {
        const variable_index = findVariable(self.variable_names, name) orelse
            return false;
        for (self.terms) |term| {
            if (term.exponents[variable_index] != 0) return true;
        }
        return false;
    }

    pub fn antiderivative(
        comptime self: Polynomial,
        comptime variable: anytype,
    ) Polynomial {
        return self.antiderivativeName(@tagName(variable));
    }

    pub fn antiderivativeName(
        comptime self: Polynomial,
        comptime name: []const u8,
    ) Polynomial {
        const with_variable = ensureVariable(self, name);
        const variable_index = findVariable(with_variable.variable_names, name).?;
        var raw: [term_limit]RawTerm = undefined;
        for (with_variable.terms, 0..) |term, index| {
            var integral = rawFromTerm(term, with_variable.variable_names.len);
            const increment = @addWithOverflow(
                integral.exponents[variable_index],
                @as(u32, 1),
            );
            if (increment[1] != 0) {
                @compileError("Bombelli polynomial antiderivative exponent exceeds u32 range");
            }
            integral.exponents[variable_index] = increment[0];
            integral.coefficient = integral.coefficient.div(
                exact.Rational.fromInteger(increment[0]),
            ) catch exactCapacityFailure();
            raw[index] = integral;
        }
        return finish(with_variable.variable_names, raw[0..with_variable.terms.len]);
    }

    pub fn scale(
        comptime self: Polynomial,
        comptime scale_factor: exact.Rational,
    ) Polynomial {
        if (scale_factor.isZero()) return zero(self.variable_names);
        var raw: [term_limit]RawTerm = undefined;
        for (self.terms, 0..) |term, index| {
            raw[index] = rawFromTerm(term, self.variable_names.len);
            raw[index].coefficient = term.coefficient.mul(scale_factor) catch
                exactCapacityFailure();
        }
        return finish(self.variable_names, raw[0..self.terms.len]);
    }

    pub fn toExpr(comptime self: Polynomial) ast.Expr {
        var builder = build.Builder{};
        var term_roots: [term_limit]ast.NodeId = undefined;
        for (self.terms, 0..) |term, term_index| {
            var factors: [variable_limit + 1]ast.NodeId = undefined;
            var factor_count: usize = 0;
            const monomial_is_constant = totalDegree(term.exponents) == 0;
            if (!term.coefficient.isOne() or monomial_is_constant) {
                factors[factor_count] = builder.rational(term.coefficient);
                factor_count += 1;
            }
            for (self.variable_names, term.exponents) |name, exponent| {
                if (exponent == 0) continue;
                const symbol_node = builder.symbol(name);
                factors[factor_count] = if (exponent == 1)
                    symbol_node
                else
                    builder.power(symbol_node, exact.Rational.fromInteger(exponent));
                factor_count += 1;
            }
            term_roots[term_index] = switch (factor_count) {
                0 => builder.integer(1),
                1 => factors[0],
                else => builder.mulNary(factors[0..factor_count]),
            };
        }
        const root = switch (self.terms.len) {
            0 => builder.integer(0),
            1 => term_roots[0],
            else => builder.addNary(term_roots[0..self.terms.len]),
        };
        return builder.finish(root, "exact polynomial").simplify();
    }
};

pub fn fromExpr(comptime expression: ast.Expr) Polynomial {
    var variable_storage: [variable_limit][]const u8 = undefined;
    var variable_count: usize = 0;
    for (expression.nodes) |node| {
        if (node != .symbol) continue;
        if (findVariable(variable_storage[0..variable_count], node.symbol) != null) continue;
        if (variable_count == variable_limit) {
            @compileError("Bombelli polynomial has too many variables");
        }
        variable_storage[variable_count] = node.symbol;
        variable_count += 1;
    }
    sortVariables(variable_storage[0..variable_count]);
    const exact_variables = variable_storage[0..variable_count].*;

    var cache = [_]?Polynomial{null} ** expression.nodes.len;
    var context = ConversionContext{
        .expression = expression,
        .variables = &exact_variables,
        .cache = &cache,
    };
    return context.convert(expression.root);
}

pub fn exactConstant(comptime value: exact.Rational) Polynomial {
    return constant(&.{}, value);
}

pub fn indeterminate(comptime name: []const u8) Polynomial {
    return symbol(&.{name}, name);
}

pub fn constantValue(comptime polynomial: Polynomial) ?exact.Rational {
    return polynomialConstant(polynomial);
}

const ConversionContext = struct {
    expression: ast.Expr,
    variables: []const []const u8,
    cache: []?Polynomial,

    fn convert(self: *ConversionContext, id: ast.NodeId) Polynomial {
        const index: usize = @intCast(id);
        if (self.cache[index]) |cached| return cached;
        const result = switch (self.expression.node(id)) {
            .integer => |value| constant(
                self.variables,
                exact.Rational.fromInteger(value),
            ),
            .rational => |value| constant(self.variables, value),
            .symbol => |name| symbol(self.variables, name),
            .add => |binary| self.convert(binary.left).add(self.convert(binary.right)),
            .add_nary => |operands| blk: {
                var sum = zero(self.variables);
                for (operands) |child| sum = sum.add(self.convert(child));
                break :blk sum;
            },
            .sub => |binary| self.convert(binary.left).sub(self.convert(binary.right)),
            .mul => |binary| self.convert(binary.left).mul(self.convert(binary.right)),
            .mul_nary => |operands| blk: {
                var product = constant(
                    self.variables,
                    exact.Rational.fromInteger(1),
                );
                for (operands) |child| product = product.mul(self.convert(child));
                break :blk product;
            },
            .div => |binary| blk: {
                const numerator = self.convert(binary.left);
                const denominator = self.convert(binary.right);
                const scalar = polynomialConstant(denominator) orelse
                    unsupported("division by a non-constant polynomial");
                if (scalar.isZero()) unsupported("division by zero");
                break :blk numerator.scale(
                    exact.Rational.fromInteger(1).div(scalar) catch
                        exactCapacityFailure(),
                );
            },
            .pow => |power| blk: {
                if (!power.exponent.isInteger() or power.exponent.numerator < 0 or
                    power.exponent.numerator > std.math.maxInt(u32))
                {
                    unsupported("non-negative integer polynomial powers are required");
                }
                break :blk self.convert(power.base).pow(
                    @intCast(power.exponent.numerator),
                );
            },
            .negate => |child| self.convert(child).scale(
                exact.Rational.fromInteger(-1),
            ),
            .float => unsupported("floating-point constants are not exact polynomials"),
            .sin, .cos, .tan, .atan, .abs, .exp, .ln => unsupported(
                "transcendental functions are not polynomials",
            ),
        };
        self.cache[index] = result;
        return result;
    }
};

const RawTerm = struct {
    coefficient: exact.Rational,
    exponents: [variable_limit]u32,
};

fn finish(
    comptime variables: []const []const u8,
    raw_input: []const RawTerm,
) Polynomial {
    if (variables.len > variable_limit) {
        @compileError("Bombelli polynomial has too many variables");
    }
    var raw: [term_limit]RawTerm = undefined;
    var count: usize = 0;
    for (raw_input) |candidate| {
        if (candidate.coefficient.isZero()) continue;
        var existing: ?usize = null;
        for (raw[0..count], 0..) |term, index| {
            if (std.mem.eql(
                u32,
                term.exponents[0..variables.len],
                candidate.exponents[0..variables.len],
            )) {
                existing = index;
                break;
            }
        }
        if (existing) |index| {
            raw[index].coefficient = raw[index].coefficient.add(
                candidate.coefficient,
            ) catch exactCapacityFailure();
        } else {
            if (count == term_limit) polynomialCapacityFailure();
            raw[count] = candidate;
            count += 1;
        }
    }

    var compact_count: usize = 0;
    for (raw[0..count]) |term| {
        if (term.coefficient.isZero()) continue;
        raw[compact_count] = term;
        compact_count += 1;
    }
    count = compact_count;

    var sort_index: usize = 1;
    while (sort_index < count) : (sort_index += 1) {
        const term = raw[sort_index];
        var insertion = sort_index;
        while (insertion > 0 and monomialBefore(
            term.exponents[0..variables.len],
            raw[insertion - 1].exponents[0..variables.len],
        )) {
            raw[insertion] = raw[insertion - 1];
            insertion -= 1;
        }
        raw[insertion] = term;
    }

    var variable_storage: [variable_limit][]const u8 = undefined;
    @memcpy(variable_storage[0..variables.len], variables);
    var term_storage: [term_limit]Term = undefined;
    for (raw[0..count], 0..) |raw_term, index| {
        const exact_exponents = raw_term.exponents[0..variables.len].*;
        term_storage[index] = .{
            .coefficient = raw_term.coefficient,
            .exponents = &exact_exponents,
        };
    }
    const exact_variables = variable_storage[0..variables.len].*;
    const exact_terms = term_storage[0..count].*;
    return .{
        .variable_names = &exact_variables,
        .terms = &exact_terms,
    };
}

fn zero(comptime variables: []const []const u8) Polynomial {
    return finish(variables, &.{});
}

fn constant(
    comptime variables: []const []const u8,
    coefficient: exact.Rational,
) Polynomial {
    if (coefficient.isZero()) return zero(variables);
    const raw = RawTerm{
        .coefficient = coefficient,
        .exponents = [_]u32{0} ** variable_limit,
    };
    return finish(variables, &.{raw});
}

fn symbol(comptime variables: []const []const u8, name: []const u8) Polynomial {
    var raw = RawTerm{
        .coefficient = exact.Rational.fromInteger(1),
        .exponents = [_]u32{0} ** variable_limit,
    };
    raw.exponents[findVariable(variables, name).?] = 1;
    return finish(variables, &.{raw});
}

fn alignTo(
    comptime polynomial: Polynomial,
    comptime variables: []const []const u8,
) Polynomial {
    if (sameVariables(polynomial.variable_names, variables)) return polynomial;
    var raw: [term_limit]RawTerm = undefined;
    for (polynomial.terms, 0..) |term, term_index| {
        raw[term_index] = .{
            .coefficient = term.coefficient,
            .exponents = [_]u32{0} ** variable_limit,
        };
        for (polynomial.variable_names, term.exponents) |name, exponent| {
            raw[term_index].exponents[findVariable(variables, name).?] = exponent;
        }
    }
    return finish(variables, raw[0..polynomial.terms.len]);
}

fn ensureVariable(comptime polynomial: Polynomial, comptime name: []const u8) Polynomial {
    if (findVariable(polynomial.variable_names, name) != null) return polynomial;
    if (polynomial.variable_names.len == variable_limit) {
        @compileError("Bombelli polynomial has too many variables");
    }
    var storage: [variable_limit][]const u8 = undefined;
    @memcpy(
        storage[0..polynomial.variable_names.len],
        polynomial.variable_names,
    );
    storage[polynomial.variable_names.len] = name;
    const len = polynomial.variable_names.len + 1;
    sortVariables(storage[0..len]);
    const exact_variables = storage[0..len].*;
    return alignTo(polynomial, &exact_variables);
}

fn unionVariables(
    comptime left: []const []const u8,
    comptime right: []const []const u8,
) []const []const u8 {
    var storage: [variable_limit][]const u8 = undefined;
    var len: usize = 0;
    for (left) |name| {
        storage[len] = name;
        len += 1;
    }
    for (right) |name| {
        if (findVariable(storage[0..len], name) != null) continue;
        if (len == variable_limit) polynomialVariableCapacityFailure();
        storage[len] = name;
        len += 1;
    }
    sortVariables(storage[0..len]);
    const exact_variables = storage[0..len].*;
    return &exact_variables;
}

fn appendTerms(raw: *[term_limit]RawTerm, len: *usize, polynomial: Polynomial) void {
    for (polynomial.terms) |term| {
        if (len.* == term_limit) polynomialCapacityFailure();
        raw[len.*] = rawFromTerm(term, polynomial.variable_names.len);
        len.* += 1;
    }
}

fn accumulateRaw(
    raw: *[term_limit]RawTerm,
    len: *usize,
    candidate: RawTerm,
    variable_count: usize,
) void {
    if (candidate.coefficient.isZero()) return;
    for (raw[0..len.*]) |*existing| {
        if (!std.mem.eql(
            u32,
            existing.exponents[0..variable_count],
            candidate.exponents[0..variable_count],
        )) continue;
        existing.coefficient = existing.coefficient.add(candidate.coefficient) catch
            exactCapacityFailure();
        return;
    }
    if (len.* == term_limit) polynomialCapacityFailure();
    raw[len.*] = candidate;
    len.* += 1;
}

fn rawFromTerm(term: Term, variable_count: usize) RawTerm {
    var raw = RawTerm{
        .coefficient = term.coefficient,
        .exponents = [_]u32{0} ** variable_limit,
    };
    @memcpy(raw.exponents[0..variable_count], term.exponents);
    return raw;
}

fn polynomialConstant(polynomial: Polynomial) ?exact.Rational {
    if (polynomial.terms.len == 0) return exact.Rational.fromInteger(0);
    if (polynomial.terms.len != 1 or
        totalDegree(polynomial.terms[0].exponents) != 0)
    {
        return null;
    }
    return polynomial.terms[0].coefficient;
}

fn totalDegree(exponents: []const u32) u32 {
    var degree: u64 = 0;
    for (exponents) |exponent| {
        degree += exponent;
    }
    return std.math.cast(u32, degree) orelse unreachable;
}

fn monomialBefore(left: []const u32, right: []const u32) bool {
    const left_degree = totalDegree(left);
    const right_degree = totalDegree(right);
    if (left_degree != right_degree) return left_degree > right_degree;
    for (left, right) |left_exponent, right_exponent| {
        if (left_exponent != right_exponent) return left_exponent > right_exponent;
    }
    return false;
}

fn findVariable(variables: []const []const u8, name: []const u8) ?usize {
    for (variables, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return index;
    }
    return null;
}

fn sortVariables(variables: [][]const u8) void {
    var index: usize = 1;
    while (index < variables.len) : (index += 1) {
        const name = variables[index];
        var insertion = index;
        while (insertion > 0 and
            std.mem.order(u8, name, variables[insertion - 1]) == .lt)
        {
            variables[insertion] = variables[insertion - 1];
            insertion -= 1;
        }
        variables[insertion] = name;
    }
}

fn sameVariables(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_name, right_name| {
        if (!std.mem.eql(u8, left_name, right_name)) return false;
    }
    return true;
}

fn unsupported(comptime reason: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli expression is not an exact polynomial: {s}",
        .{reason},
    ));
}

fn exactCapacityFailure() noreturn {
    @compileError("Bombelli exact polynomial arithmetic exceeds fixed-width rational range");
}

fn polynomialCapacityFailure() noreturn {
    @compileError("Bombelli sparse polynomial exceeds the current term construction limit");
}

fn polynomialVariableCapacityFailure() noreturn {
    @compileError("Bombelli polynomial has too many variables");
}
