//! Solver algorithm identifiers shared by problem and implementation types.

pub const SolveAlgorithm = enum {
    gaussian,
    bareiss,
    polynomial,
};
