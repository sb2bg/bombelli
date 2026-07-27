# Changelog

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
[validation baseline](docs/validation/release-baseline.md).
