//! Utilities for Bombelli's own tests and for downstream package tests that
//! need to inspect implementation invariants. This namespace is not part of
//! Bombelli's stable user-facing API.

pub const Builder = @import("internal/core/builder.zig").Builder;
pub const gaussLegendreTable =
    @import("internal/integrate/gauss_legendre.zig").table;
pub const batchVectorLength =
    @import("internal/runtime/evaluation.zig").batch_vector_length;
