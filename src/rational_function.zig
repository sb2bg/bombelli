const std = @import("std");
const ast = @import("ast.zig");
const exact = @import("exact.zig");
const parser = @import("parser.zig");
const polynomial = @import("polynomial.zig");

const condition_limit = 128;

pub const DenominatorCondition = struct {
    polynomial: polynomial.Polynomial,
};

pub const RationalFunction = struct {
    numerator: polynomial.Polynomial,
    denominator: polynomial.Polynomial,
    denominator_conditions: []const DenominatorCondition,

    pub fn eql(
        comptime self: RationalFunction,
        comptime other: RationalFunction,
    ) bool {
        if (!self.numerator.mul(other.denominator).eql(
            other.numerator.mul(self.denominator),
        )) return false;
        return conditionsEqual(
            self.denominator_conditions,
            other.denominator_conditions,
        );
    }

    pub fn add(
        comptime self: RationalFunction,
        comptime other: RationalFunction,
    ) RationalFunction {
        const numerator = self.numerator.mul(other.denominator)
            .add(other.numerator.mul(self.denominator));
        const denominator = self.denominator.mul(other.denominator);
        return normalized(
            numerator,
            denominator,
            combineConditions(
                self.denominator_conditions,
                other.denominator_conditions,
            ),
        );
    }

    pub fn sub(
        comptime self: RationalFunction,
        comptime other: RationalFunction,
    ) RationalFunction {
        return self.add(other.negate());
    }

    pub fn mul(
        comptime self: RationalFunction,
        comptime other: RationalFunction,
    ) RationalFunction {
        return normalized(
            self.numerator.mul(other.numerator),
            self.denominator.mul(other.denominator),
            combineConditions(
                self.denominator_conditions,
                other.denominator_conditions,
            ),
        );
    }

    pub fn div(
        comptime self: RationalFunction,
        comptime other: RationalFunction,
    ) RationalFunction {
        var conditions: [condition_limit]DenominatorCondition = undefined;
        var len: usize = 0;
        appendConditions(&conditions, &len, self.denominator_conditions);
        appendConditions(&conditions, &len, other.denominator_conditions);
        appendCondition(&conditions, &len, other.numerator);
        return normalized(
            self.numerator.mul(other.denominator),
            self.denominator.mul(other.numerator),
            conditions[0..len],
        );
    }

    pub fn pow(
        comptime self: RationalFunction,
        comptime exponent: i64,
    ) RationalFunction {
        if (exponent >= 0) {
            return normalized(
                self.numerator.pow(@intCast(exponent)),
                self.denominator.pow(@intCast(exponent)),
                self.denominator_conditions,
            );
        }
        var conditions: [condition_limit]DenominatorCondition = undefined;
        var len: usize = 0;
        appendConditions(&conditions, &len, self.denominator_conditions);
        appendCondition(&conditions, &len, self.numerator);
        const magnitude: u64 = @intCast(-@as(i128, exponent));
        if (magnitude > std.math.maxInt(u32)) {
            @compileError("Bombelli rational-function exponent exceeds u32 magnitude");
        }
        return normalized(
            self.denominator.pow(@intCast(magnitude)),
            self.numerator.pow(@intCast(magnitude)),
            conditions[0..len],
        );
    }

    pub fn negate(comptime self: RationalFunction) RationalFunction {
        return normalized(
            self.numerator.scale(exact.Rational.fromInteger(-1)),
            self.denominator,
            self.denominator_conditions,
        );
    }

    pub fn toExpr(comptime self: RationalFunction) ast.Expr {
        const numerator_source = self.numerator.toExpr().render();
        if (polynomial.constantValue(self.denominator)) |value| {
            if (value.isOne()) return self.numerator.toExpr();
        }
        const denominator_source = self.denominator.toExpr().render();
        return parser.parse(std.fmt.comptimePrint(
            "({s}) / ({s})",
            .{ numerator_source, denominator_source },
        )).simplify();
    }
};

pub fn fromExpr(comptime expression: ast.Expr) RationalFunction {
    var cache = [_]?RationalFunction{null} ** expression.nodes.len;
    var context = ConversionContext{
        .expression = expression,
        .cache = &cache,
    };
    return context.convert(expression.root);
}

const ConversionContext = struct {
    expression: ast.Expr,
    cache: []?RationalFunction,

    fn convert(self: *ConversionContext, id: ast.NodeId) RationalFunction {
        const index: usize = @intCast(id);
        if (self.cache[index]) |cached| return cached;
        const result = switch (self.expression.node(id)) {
            .integer => |value| fromPolynomial(polynomial.exactConstant(
                exact.Rational.fromInteger(value),
            )),
            .rational => |value| fromPolynomial(polynomial.exactConstant(value)),
            .symbol => |name| fromPolynomial(polynomial.indeterminate(name)),
            .add => |binary| self.convert(binary.left).add(self.convert(binary.right)),
            .add_nary => |operands| blk: {
                var sum = fromPolynomial(polynomial.exactConstant(
                    exact.Rational.fromInteger(0),
                ));
                for (operands) |child| sum = sum.add(self.convert(child));
                break :blk sum;
            },
            .sub => |binary| self.convert(binary.left).sub(self.convert(binary.right)),
            .mul => |binary| self.convert(binary.left).mul(self.convert(binary.right)),
            .mul_nary => |operands| blk: {
                var product = fromPolynomial(polynomial.exactConstant(
                    exact.Rational.fromInteger(1),
                ));
                for (operands) |child| product = product.mul(self.convert(child));
                break :blk product;
            },
            .div => |binary| self.convert(binary.left).div(self.convert(binary.right)),
            .pow => |power| blk: {
                if (!power.exponent.isInteger()) {
                    unsupported("rational exponents are not rational functions");
                }
                break :blk self.convert(power.base).pow(power.exponent.numerator);
            },
            .negate => |child| self.convert(child).negate(),
            .float => unsupported("floating-point constants are not exact rational functions"),
            .sin, .cos, .tan, .atan, .abs, .exp, .ln => unsupported(
                "transcendental functions are not rational functions",
            ),
        };
        self.cache[index] = result;
        return result;
    }
};

fn fromPolynomial(comptime value: polynomial.Polynomial) RationalFunction {
    return normalized(
        value,
        polynomial.exactConstant(exact.Rational.fromInteger(1)),
        &.{},
    );
}

fn normalized(
    comptime numerator_input: polynomial.Polynomial,
    comptime denominator_input: polynomial.Polynomial,
    input_conditions: []const DenominatorCondition,
) RationalFunction {
    if (denominator_input.terms.len == 0) {
        @compileError("Bombelli rational-function denominator is the zero polynomial");
    }
    var numerator = numerator_input;
    var denominator = denominator_input;
    const leading = denominator.terms[0].coefficient;
    const reciprocal = exact.Rational.fromInteger(1).div(leading) catch
        @panic("Bombelli rational-function normalization overflowed");
    numerator = numerator.scale(reciprocal);
    denominator = denominator.scale(reciprocal);

    var conditions: [condition_limit]DenominatorCondition = undefined;
    var condition_count: usize = 0;
    appendConditions(&conditions, &condition_count, input_conditions);
    if (polynomial.constantValue(denominator) == null) {
        appendCondition(&conditions, &condition_count, denominator);
    }
    return .{
        .numerator = numerator,
        .denominator = denominator,
        .denominator_conditions = conditions[0..condition_count],
    };
}

fn combineConditions(
    comptime left: []const DenominatorCondition,
    comptime right: []const DenominatorCondition,
) []const DenominatorCondition {
    var storage: [condition_limit]DenominatorCondition = undefined;
    var len: usize = 0;
    appendConditions(&storage, &len, left);
    appendConditions(&storage, &len, right);
    return storage[0..len];
}

fn appendConditions(
    storage: *[condition_limit]DenominatorCondition,
    len: *usize,
    conditions: []const DenominatorCondition,
) void {
    for (conditions) |condition| {
        appendCondition(storage, len, condition.polynomial);
    }
}

fn appendCondition(
    storage: *[condition_limit]DenominatorCondition,
    len: *usize,
    condition_input: polynomial.Polynomial,
) void {
    if (polynomial.constantValue(condition_input)) |value| {
        if (!value.isZero()) return;
    }
    if (condition_input.terms.len == 0) {
        @compileError("Bombelli rational-function construction divides by zero");
    }
    const reciprocal = exact.Rational.fromInteger(1).div(
        condition_input.terms[0].coefficient,
    ) catch @panic("Bombelli denominator-condition normalization overflowed");
    const condition = condition_input.scale(reciprocal);
    for (storage[0..len.*]) |existing| {
        if (existing.polynomial.eql(condition)) return;
    }
    if (len.* == condition_limit) {
        @panic("Bombelli rational function has too many denominator conditions");
    }
    storage[len.*] = .{ .polynomial = condition };
    len.* += 1;
}

fn conditionsEqual(
    comptime left: []const DenominatorCondition,
    comptime right: []const DenominatorCondition,
) bool {
    if (left.len != right.len) return false;
    for (left) |left_condition| {
        var found = false;
        for (right) |right_condition| {
            if (left_condition.polynomial.eql(right_condition.polynomial)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn unsupported(comptime reason: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli expression is not an exact rational function: {s}",
        .{reason},
    ));
}
