//! The scalar type emitted code computes in, shared by every emission target.

/// Bombelli always evaluates in `f64`; this selects the emitted arithmetic
/// type only.
pub const Scalar = enum { f32, f64 };

pub fn scalarOption(comptime options: anytype) Scalar {
    if (!@hasField(@TypeOf(options), "scalar")) return .f64;
    const scalar: Scalar = options.scalar;
    return scalar;
}
