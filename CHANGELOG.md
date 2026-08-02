# Changelog

## Unreleased

### Added

- `.complex` equation and system domains using Zig's standard
  `std.math.Complex(f64)` scalar. The existing `problem.compile(...).eval(...)`
  API now specializes Newton iteration, symbolic-Jacobian evaluation, runtime
  pivoting, result values, and implicit sensitivities from the problem domain.
- Complex `evalAs`/`evalIntoAs` support for scalar, vector, and matrix
  expression programs with real-input promotion, principal rational powers,
  and the standard complex trigonometric, inverse-trigonometric, hyperbolic,
  exponential, and logarithmic functions.
- Complex quadratic solution branches. Exact polynomial results remain
  symbolic and can be evaluated with `evalAs(std.math.Complex(f64), ...)`.
- The exact symbolic imaginary-unit constant `i`, including canonical
  rendering, differentiation, complex expression evaluation, and complex
  Newton residuals.
- Named Newton accessors for solved values, unknown indices, residual
  positions, root sensitivities, and sensitivity roots.
- Opt-in Newton globalization with sufficient-decrease backtracking over real
  and complex systems, scale-aware step stagnation, line-search failure
  status, and function-evaluation/backtrack/step-scale diagnostics.

### Limits

- Complex Newton residuals must be holomorphic. `abs`, `atan2`, and `hypot`
  are rejected at compile time.
- Nonlinear least squares, batch evaluation, quadrature, and standalone source
  emission remain real-only.
- Standalone Newton source emission currently supports only undamped
  `.globalization = .none` solvers.

## 0.2.0 — 2026-08-01

### Added

- `model` declares an ordered variable contract over one shared expression
  program. Models evaluate, build symbolic Jacobians, compile fused
  value-and-Jacobian programs, apply JVPs and VJPs, preserve metadata through
  transforms, and emit standalone evaluators.
- Fixed-size nonlinear least squares for `model` residuals: allocation-free
  Levenberg–Marquardt with augmented pivoted QR, automatic or user parameter
  scaling, box bounds, linear/Huber/soft-L1/Cauchy losses, projected-gradient
  fallback, rank and bound diagnostics, and hard evaluation budgets.
- `residualModel` compiles a symbolic residual block once and fits
  runtime-length observation arrays or slices. Incremental Givens QR consumes
  each weighted Jacobian row immediately, keeping solver storage
  `O(parameter_count²)` with no observation-sized allocation. The NIST
  Misra1a reference dataset converges to its certified parameters and
  half-RSS from both official starting points.
- `bombelli.linalg` numerical routines over native fixed-size Zig arrays:
  scaled-pivot LU, Cholesky, column-pivoted Householder QR, solve,
  positive-definite solve, least squares, inverse, determinant, transpose,
  matrix/vector and matrix/matrix products, dot products, norms, outer
  products, trace, and identity matrices.
- `evalAs`, `evalIntoAs`, and matching top-level callable helpers evaluate
  scalar, vector, and matrix programs with `f16`, `f32`, `f64`, `f80`, or
  `f128` intermediates.
- `testing.checkJacobian` compares symbolic Jacobians with scaled central
  differences and reports per-entry row, column, variable, step, error, and
  tolerance diagnostics.
- Elementary functions `asin`, `acos`, `sinh`, `cosh`, `tanh`, `log2`,
  `log10`, `atan2`, and overflow-safe `hypot` across parsing, rendering,
  evaluation, differentiation, transformation, and source emission.
- Exact Bareiss determinants for symbolic expression matrices.
- `.target = .c` emission for every callable that already emitted Zig:
  expressions, vectors, matrices, fixed quadrature, and Newton solvers. The
  emitted unit is C99 that includes only `<math.h>` and `<stddef.h>`.
- Inputs reach emitted C through a generated `<name>_inputs` struct with
  alphabetical fields, since C has no `anytype` and positional `double`
  parameters can be transposed silently. A Newton solver's initial iterate is
  nested in `<name>_initial` so an unknown and a parameter may share a name.
- `.scalar = .f32` applies to C as well, selecting `float` and the `sinf`
  family.
- Compile-time diagnostics for an unsupported or missing `.target`, and for a
  function or input name that collides with a C keyword.
- Standalone Zig and C execution coverage for the extended smooth elementary
  function set.

### Changed

- Bombelli's primary abstraction is now a statically shaped differentiable
  model compiler: one declaration can feed evaluation, differentiation,
  fitting, solving, batching, and source emission.
- Function parsing is arity-aware and reports missing, extra, empty, and
  trailing-comma arguments at compile time.
- Nonlinear least-squares diagnostics are refreshed at the returned point;
  numerical rank uses its independent configured tolerance, and invalid
  residual trials are bounded explicitly.
- Emission dispatches through `internal/codegen/emit.zig`, which owns
  `EmitTarget`, validates the target-independent options, and selects a
  backend. `EmitTarget` gained a `c` member.
- Emission validation generates each case for both targets from one shared
  definition, compiles the C with `-std=c99 -Wall -Wextra -Werror`, executes
  it, and compares it against Bombelli's own evaluator. A multi-output
  gradient case was added, so vector emission is now covered end to end.

### Fixed

- Runtime-observation fitting now reserves the final fused linearization pass,
  so `max_function_evaluations` is a strict upper bound even when the last
  trial is accepted.
- Extreme residual and parameter scales no longer overflow robust objectives,
  damping initialization, or scaled norms when a representable result exists.
- Top-level evaluation helpers safely accept temporary comptime programs,
  avoiding a Zig 0.16 temporary-receiver compiler failure in chained calls.

### Validation

- 155 runtime, property, hardening, and stress tests, plus 56 automatically
  discovered compile-fail fixtures.
- 342 seeded SymPy differential programs/problems and 4,984 independent oracle
  assertions.
- Standalone compilation and execution of five emitted callable types as both
  Zig and C.

Compiler cost, scaling, emitted size, and runtime measurements are in the
[v0.2.0 validation baseline](docs/validation/release-baseline.md).

## 0.1.0 — 2026-07-25

First public release. Bombelli is a compile-time symbolic mathematics
compiler for Zig 0.16.0: expressions are parsed, transformed, and compiled
during compilation, leaving straight-line numerical code with no runtime
parser, allocator, graph traversal, or dynamic dispatch.

### Added

- Hash-consed symbolic DAGs over exact integers, rationals, and rational
  powers
- `pi` as a symbolic constant (`e` stays an ordinary symbol; use `exp(1)`)
- Differentiation, gradients, Jacobians, Hessians, substitution, expansion
- Sparse polynomials and rational functions that retain denominator
  conditions
- Equations, systems, exact RREF, symbolic Bareiss solving, reusable
  factorizations
- Complete and partial symbolic integration, fixed and adaptive quadrature,
  and symbolic-plus-quadrature compiled integrals
- Fixed-size Newton solvers and implicit parameter sensitivities
- Rendering and standalone Zig emission, with `.scalar = .f32` retargeting

### Limits

- Real domain only; no complex branches
- Exact arithmetic is fixed-width and checked, so overflow is a compile error
- Simplification never cancels unconditionally: `x/x` stays `x/x`
- Integration is a terminating subset and reports `unsupported` rather than
  guessing
- Polynomial equation solving stops at degree two
- Fixed quadrature supports orders 4, 8, 16, and 32; adaptive quadrature is
  deliberately not differentiable
- Newton compilation requires a square system and a symbolic Jacobian
- Emission targets Zig and out-of-place callables only
- Compiled callables reject unknown `eval` fields; plain `Expr.eval` ignores
  them, because a symbol absent from an expression can still belong to its
  domain (`expr("x^2").diff(.y)` is zero on both variables)
- Evaluation is `f64`; `.scalar = .f32` applies to emitted code only
- Construction is guarded at 1,024 nodes
- Assumptions such as `nonzero(.a)` are operation-local; symbols never
  acquire global attributes

### Validation

- Core, property, hardening, compile-fail, and stress suites
- 342 seeded programs and 4,984 SymPy oracle assertions
- Standalone execution of emitted expression, quadrature, and Newton code

Compiler cost, scaling, code size, and runtime measurements are in the
[v0.1.0 validation baseline](docs/validation/v0.1.0.md).
