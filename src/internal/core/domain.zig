//! Mathematical domains and operation-local symbolic assumptions.

pub const Domain = enum {
    real,
};

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
