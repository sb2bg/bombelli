//! Numerical operations shared by typed expression evaluation and solvers.
//!
//! Zig's standard complex type deliberately uses methods rather than operator
//! overloading. Keeping that distinction here lets the generated evaluator
//! remain generic without wrapping or replacing `std.math.Complex`.

const std = @import("std");
const exact = @import("../core/exact.zig");

const Complex32 = std.math.Complex(f32);
const Complex64 = std.math.Complex(f64);

pub fn isComplex(comptime T: type) bool {
    return T == Complex32 or T == Complex64;
}

pub fn isEvaluationNumber(comptime T: type) bool {
    if (isComplex(T)) return true;
    return switch (@typeInfo(T)) {
        .float => true,
        .vector => |vector| @typeInfo(vector.child) == .float,
        else => false,
    };
}

pub fn Real(comptime T: type) type {
    if (T == Complex32) return f32;
    if (T == Complex64) return f64;
    return switch (@typeInfo(T)) {
        .float => T,
        else => @compileError("Bombelli numerical scalar must be floating-point or complex"),
    };
}

pub inline fn fromReal(comptime T: type, value: anytype) T {
    if (comptime isComplex(T)) {
        const Component = Real(T);
        return T.init(realValue(Component, value), 0.0);
    }
    return switch (@typeInfo(T)) {
        .float => realValue(T, value),
        .vector => |vector| @as(T, @splat(realValue(vector.child, value))),
        else => comptime unreachable,
    };
}

pub inline fn add(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (comptime isComplex(@TypeOf(left)))
        left.add(right)
    else
        left + right;
}

pub inline fn sub(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (comptime isComplex(@TypeOf(left)))
        left.sub(right)
    else
        left - right;
}

pub inline fn mul(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (comptime isComplex(@TypeOf(left)))
        left.mul(right)
    else
        left * right;
}

pub inline fn div(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (comptime isComplex(@TypeOf(left)))
        left.div(right)
    else
        left / right;
}

pub inline fn neg(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value))) value.neg() else -value;
}

/// The expression-language `abs` remains scalar-valued. For complex
/// evaluation its real magnitude is embedded back into the complex scalar.
pub inline fn absolute(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    return if (comptime isComplex(T))
        fromReal(T, std.math.complex.abs(value))
    else
        @abs(value);
}

pub inline fn magnitude(value: anytype) Real(@TypeOf(value)) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.abs(value)
    else
        @abs(value);
}

pub inline fn isFinite(value: anytype) bool {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.isFinite(value.re) and std.math.isFinite(value.im)
    else
        std.math.isFinite(value);
}

pub inline fn nan(comptime T: type) T {
    if (comptime isComplex(T)) {
        const Component = Real(T);
        return T.init(std.math.nan(Component), std.math.nan(Component));
    }
    return std.math.nan(T);
}

pub inline fn sin(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.sin(value)
    else
        @sin(value);
}

pub inline fn cos(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.cos(value)
    else
        @cos(value);
}

pub inline fn tan(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.tan(value)
    else
        @tan(value);
}

pub inline fn asin(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.asin(value)
    else
        std.math.asin(value);
}

pub inline fn acos(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.acos(value)
    else
        std.math.acos(value);
}

pub inline fn atan(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.atan(value)
    else
        std.math.atan(value);
}

pub inline fn sinh(value: anytype) @TypeOf(value) {
    if (comptime isComplex(@TypeOf(value))) {
        return std.math.complex.sinh(value);
    }
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .float => if (comptime T == f32 or T == f64)
            std.math.sinh(value)
        else
            div(sub(exp(value), exp(neg(value))), fromReal(T, 2.0)),
        .vector => |vector| blk: {
            var result: T = undefined;
            inline for (0..vector.len) |lane| result[lane] = sinh(value[lane]);
            break :blk result;
        },
        else => comptime unreachable,
    };
}

pub inline fn cosh(value: anytype) @TypeOf(value) {
    if (comptime isComplex(@TypeOf(value))) {
        return std.math.complex.cosh(value);
    }
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .float => if (comptime T == f32 or T == f64)
            std.math.cosh(value)
        else
            div(add(exp(value), exp(neg(value))), fromReal(T, 2.0)),
        .vector => |vector| blk: {
            var result: T = undefined;
            inline for (0..vector.len) |lane| result[lane] = cosh(value[lane]);
            break :blk result;
        },
        else => comptime unreachable,
    };
}

pub inline fn tanh(value: anytype) @TypeOf(value) {
    if (comptime isComplex(@TypeOf(value))) {
        return std.math.complex.tanh(value);
    }
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .float => if (comptime T == f32 or T == f64)
            std.math.tanh(value)
        else
            div(sinh(value), cosh(value)),
        .vector => |vector| blk: {
            var result: T = undefined;
            inline for (0..vector.len) |lane| result[lane] = tanh(value[lane]);
            break :blk result;
        },
        else => comptime unreachable,
    };
}

pub inline fn exp(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.exp(value)
    else
        @exp(value);
}

pub inline fn log(value: anytype) @TypeOf(value) {
    return if (comptime isComplex(@TypeOf(value)))
        std.math.complex.log(value)
    else
        @log(value);
}

pub inline fn log2(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    return if (comptime isComplex(T))
        div(log(value), fromReal(T, @log(2.0)))
    else
        @log2(value);
}

pub inline fn log10(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    return if (comptime isComplex(T))
        div(log(value), fromReal(T, @log(10.0)))
    else
        @log10(value);
}

pub inline fn rationalPower(
    base: anytype,
    comptime exponent: exact.Rational,
) @TypeOf(base) {
    const T = @TypeOf(base);
    if (comptime isComplex(T)) {
        const exponent_value = div(
            fromReal(T, exponent.numerator),
            fromReal(T, exponent.denominator),
        );
        // Exact negative literals are often represented by a negation node,
        // which turns the promoted imaginary +0 into -0. Normalize points on
        // the branch cut so `sqrt(-1)` takes the conventional +i branch.
        const normalized = if (base.im == 0.0) T.init(base.re, 0.0) else base;
        return std.math.complex.pow(normalized, exponent_value);
    }
    return switch (@typeInfo(T)) {
        .float => rationalPowerReal(base, exponent),
        .vector => |vector| blk: {
            var result: T = undefined;
            inline for (0..vector.len) |lane| {
                result[lane] = rationalPowerReal(base[lane], exponent);
            }
            break :blk result;
        },
        else => comptime unreachable,
    };
}

fn rationalPowerReal(
    base: anytype,
    comptime exponent: exact.Rational,
) @TypeOf(base) {
    const T = @TypeOf(base);
    const exponent_value = fromReal(T, exponent.numerator) /
        fromReal(T, exponent.denominator);
    const powered = if (T == f32 or T == f64)
        std.math.pow(T, @abs(base), exponent_value)
    else
        @exp(@log(@abs(base)) * exponent_value);
    if (base >= 0.0) return powered;
    if (exponent.denominator % 2 == 0) return std.math.nan(T);
    return if (@mod(exponent.numerator, 2) == 0) powered else -powered;
}

fn realValue(comptime T: type, value: anytype) T {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("Bombelli cannot convert this value to a numerical scalar"),
    };
}
