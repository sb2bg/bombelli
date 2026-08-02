//! Mathematical domains and operation-local symbolic assumptions.

const std = @import("std");

pub const Domain = enum {
    real,
    complex,
};

/// Runtime scalar used by compiled numerical operations in this domain.
pub fn Scalar(comptime value: Domain) type {
    return switch (value) {
        .real => f64,
        .complex => std.math.Complex(f64),
    };
}

pub const AssumptionKind = enum {
    positive,
    nonzero,
};

pub const Assumption = struct {
    kind: AssumptionKind,
    symbol: []const u8,
};

pub fn positive(comptime symbol: anytype) Assumption {
    return .{ .kind = .positive, .symbol = @tagName(symbol) };
}

pub fn nonzero(comptime symbol: anytype) Assumption {
    return .{ .kind = .nonzero, .symbol = @tagName(symbol) };
}
