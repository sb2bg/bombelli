# Changelog

## Unreleased

### Added

- Complex expression evaluation, exact `i`, complex quadratic branches, and
  `.complex` Newton systems using `std.math.Complex(f64)`.
- Named Newton value, residual, and sensitivity accessors.
- Optional sufficient-decrease Newton backtracking with stagnation,
  line-search, evaluation-count, backtrack, and step-scale diagnostics.
- Standalone allocation-free Zig and C99 emission for runtime-observation
  nonlinear least-squares fitters.

### Limits

- Complex Newton residuals must be holomorphic; `abs`, `atan2`, and `hypot`
  are rejected.
- Least squares, batch evaluation, quadrature, and source emission are
  real-only. Runtime-observation fitting uses `f64`.
- Newton source emission supports undamped `.globalization = .none` solvers.

## 0.2.0 — 2026-08-01

### Added

- Typed differentiable `model` programs with shared Jacobians, Hessians,
  linearization, JVP/VJP, transforms, and source emission.
- Allocation-free fixed-size and runtime-observation nonlinear least squares
  with robust losses, scaling, bounds, QR, evaluation budgets, and numerical
  diagnostics.
- Numerical linear algebra over native fixed-size Zig arrays: LU, Cholesky,
  pivoted QR, solves, inverse, determinant, products, norms, and utilities.
- `evalAs` and `evalIntoAs` for supported floating-point types.
- `testing.checkJacobian` with per-entry finite-difference diagnostics.
- `asin`, `acos`, hyperbolic functions, `log2`, `log10`, `atan2`, and `hypot`.
- Exact Bareiss determinants for polynomial expression matrices.
- Standalone C99 emission and `.scalar = .f32` for existing emitted callables.

### Changed

- Function parsing now validates arity and comma placement.
- Least-squares diagnostics are evaluated at the returned point, with
  independent rank tolerance and bounded invalid trials.
- Emission validates target-neutral options before dispatching to Zig or C.
- Generated Zig and C are compiled and executed independently in validation.

### Fixed

- Runtime-observation fitting reserves its final linearization within the
  function-evaluation budget.
- Robust objectives, damping initialization, and norms avoid overflow when a
  representable result exists.
- Top-level evaluation accepts temporary comptime programs without triggering
  the Zig 0.16 temporary-receiver failure.

See the [validation baseline](docs/validation/release-baseline.md).

## 0.1.0 — 2026-07-25

First public release for Zig 0.16.0.

### Added

- Hash-consed compile-time expression DAGs with exact integers, rationals,
  rational powers, and symbolic `pi`.
- Differentiation, simplification, substitution, expansion, gradients,
  Jacobians, Hessians, sparse polynomials, and rational functions.
- Exact linear systems, symbolic Bareiss solving, quadratic solving, and
  conditional solutions.
- Symbolic, fixed, adaptive, and hybrid integration.
- Fixed-size Newton solvers, implicit sensitivities, rendering, and standalone
  Zig emission.

### Initial limits

- Real-domain evaluation and fixed-width checked exact arithmetic.
- Polynomial solving through degree two; symbolic integration is a terminating
  subset.
- Fixed quadrature orders 4, 8, 16, and 32.
- A guarded 1,024-node construction workspace.
