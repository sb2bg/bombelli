const std = @import("std");

pub const Integer = i64;

pub const Error = error{
    ZeroDenominator,
    Overflow,
};

pub const Rational = struct {
    numerator: Integer,
    denominator: u64,

    pub fn init(numerator: Integer, denominator: Integer) Error!Rational {
        if (denominator == 0) return error.ZeroDenominator;
        var wide_numerator: i128 = numerator;
        var wide_denominator: i128 = denominator;
        if (wide_denominator < 0) {
            wide_numerator = -wide_numerator;
            wide_denominator = -wide_denominator;
        }
        return fromWide(wide_numerator, @intCast(wide_denominator));
    }

    pub fn fromInteger(value: Integer) Rational {
        return .{ .numerator = value, .denominator = 1 };
    }

    pub fn isInteger(self: Rational) bool {
        return self.denominator == 1;
    }

    pub fn isZero(self: Rational) bool {
        return self.numerator == 0;
    }

    pub fn isOne(self: Rational) bool {
        return self.numerator == 1 and self.denominator == 1;
    }

    pub fn eql(self: Rational, other: Rational) bool {
        return self.numerator == other.numerator and
            self.denominator == other.denominator;
    }

    pub fn negate(self: Rational) Error!Rational {
        if (self.numerator == std.math.minInt(Integer)) return error.Overflow;
        return .{
            .numerator = -self.numerator,
            .denominator = self.denominator,
        };
    }

    pub fn add(self: Rational, other: Rational) Error!Rational {
        return addSigned(self, other, false);
    }

    pub fn sub(self: Rational, other: Rational) Error!Rational {
        return addSigned(self, other, true);
    }

    pub fn mul(self: Rational, other: Rational) Error!Rational {
        if (self.isZero() or other.isZero()) return fromInteger(0);

        const left_cancel = gcd(absInteger(self.numerator), other.denominator);
        const right_cancel = gcd(absInteger(other.numerator), self.denominator);
        const left_numerator = @divExact(
            @as(i128, self.numerator),
            @as(i128, @intCast(left_cancel)),
        );
        const right_numerator = @divExact(
            @as(i128, other.numerator),
            @as(i128, @intCast(right_cancel)),
        );
        const numerator_product = @mulWithOverflow(left_numerator, right_numerator);
        if (numerator_product[1] != 0) return error.Overflow;

        const left_denominator = @divExact(self.denominator, right_cancel);
        const right_denominator = @divExact(other.denominator, left_cancel);
        const denominator_product = @mulWithOverflow(
            @as(u128, left_denominator),
            @as(u128, right_denominator),
        );
        if (denominator_product[1] != 0) return error.Overflow;
        return fromWide(numerator_product[0], denominator_product[0]);
    }

    pub fn div(self: Rational, other: Rational) Error!Rational {
        if (other.isZero()) return error.ZeroDenominator;
        if (self.isZero()) return fromInteger(0);

        const numerator_cancel = gcd(
            absInteger(self.numerator),
            absInteger(other.numerator),
        );
        const denominator_cancel = gcd(self.denominator, other.denominator);

        var left_numerator = @divExact(
            @as(i128, self.numerator),
            @as(i128, @intCast(numerator_cancel)),
        );
        if (other.numerator < 0) {
            if (left_numerator == std.math.minInt(i128)) return error.Overflow;
            left_numerator = -left_numerator;
        }
        const right_denominator = @divExact(other.denominator, denominator_cancel);
        const numerator_product = @mulWithOverflow(
            left_numerator,
            @as(i128, @intCast(right_denominator)),
        );
        if (numerator_product[1] != 0) return error.Overflow;

        const left_denominator = @divExact(self.denominator, denominator_cancel);
        const other_numerator = @divExact(
            absInteger(other.numerator),
            numerator_cancel,
        );
        const denominator_product = @mulWithOverflow(
            @as(u128, left_denominator),
            @as(u128, other_numerator),
        );
        if (denominator_product[1] != 0) return error.Overflow;
        return fromWide(numerator_product[0], denominator_product[0]);
    }

    pub fn powUnsigned(self: Rational, exponent: u32) Error!Rational {
        var result = fromInteger(1);
        var factor = self;
        var remaining = exponent;
        while (remaining != 0) : (remaining /= 2) {
            if (remaining % 2 == 1) result = try result.mul(factor);
            if (remaining > 1) factor = try factor.mul(factor);
        }
        return result;
    }

    pub fn toF64(self: Rational) f64 {
        return @as(f64, @floatFromInt(self.numerator)) /
            @as(f64, @floatFromInt(self.denominator));
    }

    fn addSigned(self: Rational, other: Rational, subtract: bool) Error!Rational {
        const denominator_gcd = gcd(self.denominator, other.denominator);
        const left_scale = @divExact(other.denominator, denominator_gcd);
        const right_scale = @divExact(self.denominator, denominator_gcd);

        const left_product = @mulWithOverflow(
            @as(i128, self.numerator),
            @as(i128, @intCast(left_scale)),
        );
        if (left_product[1] != 0) return error.Overflow;
        const right_product = @mulWithOverflow(
            @as(i128, other.numerator),
            @as(i128, @intCast(right_scale)),
        );
        if (right_product[1] != 0) return error.Overflow;
        const numerator_sum = if (subtract)
            @subWithOverflow(left_product[0], right_product[0])
        else
            @addWithOverflow(left_product[0], right_product[0]);
        if (numerator_sum[1] != 0) return error.Overflow;

        const denominator_product = @mulWithOverflow(
            @as(u128, self.denominator),
            @as(u128, left_scale),
        );
        if (denominator_product[1] != 0) return error.Overflow;
        return fromWide(numerator_sum[0], denominator_product[0]);
    }
};

pub fn checkedAdd(left: Integer, right: Integer) Error!Integer {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

pub fn checkedSub(left: Integer, right: Integer) Error!Integer {
    const result = @subWithOverflow(left, right);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

pub fn checkedMul(left: Integer, right: Integer) Error!Integer {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn fromWide(numerator: i128, denominator: u128) Error!Rational {
    if (denominator == 0) return error.ZeroDenominator;
    if (numerator == 0) return Rational.fromInteger(0);

    const numerator_magnitude: u128 = if (numerator < 0)
        @intCast(-numerator)
    else
        @intCast(numerator);
    const divisor = gcdWide(numerator_magnitude, denominator);
    const reduced_numerator = @divExact(numerator, @as(i128, @intCast(divisor)));
    const reduced_denominator = @divExact(denominator, divisor);

    if (reduced_numerator < std.math.minInt(Integer) or
        reduced_numerator > std.math.maxInt(Integer) or
        reduced_denominator > std.math.maxInt(u64))
    {
        return error.Overflow;
    }
    return .{
        .numerator = @intCast(reduced_numerator),
        .denominator = @intCast(reduced_denominator),
    };
}

fn absInteger(value: Integer) u64 {
    const wide: i128 = value;
    return @intCast(if (wide < 0) -wide else wide);
}

fn gcd(left: u64, right: u64) u64 {
    var a = left;
    var b = right;
    while (b != 0) {
        const remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

fn gcdWide(left: u128, right: u128) u128 {
    var a = left;
    var b = right;
    while (b != 0) {
        const remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}
