# Changelog

## 0.1.0 — 2026-07-25

Bombelli's first public release establishes a compile-time symbolic mathematics
compiler for Zig 0.16.0.

### Included

- Compact, hash-consed single- and multi-root symbolic DAGs
- Checked exact integers, canonical rationals, and rational powers
- `pi` as an exact symbolic constant (`e` stays an ordinary symbol; use
  `exp(1)`)
- Canonical n-ary algebra, substitution, sparse polynomials, and rational
  functions with retained denominator conditions
- Symbolic differentiation, gradients, Jacobians, Hessians, and explicit
  expansion
- Equations, systems, structured solution sets, exact rational RREF,
  fraction-free symbolic Bareiss solving, and reusable factorizations
- Linear and quadratic real polynomial equation solving
- Inspectable complete and partial symbolic integration
- Fixed and bounded adaptive quadrature, including differentiated fixed rules
- Symbolic-plus-quadrature compiled integrals
- Fixed-size Newton solvers and implicit parameter sensitivities
- Canonical and pretty rendering plus standalone Zig source emission
- Emission scalar retargeting via `.scalar = .f32` (default `.f64`)
- Strict eval input contracts on quadrature, compiled-integral, and Newton
  callables (unknown fields are compile errors)

### Runtime contract

Symbolic expressions and multi-output programs compile without a runtime
parser, allocator, symbolic graph traversal, node-kind dispatch, virtual
machine, or dynamic dispatch. Generated numerical routines use only bounded
numeric loops and explicit failure handling.

### Validation

- Core, property, hardening, compile-fail, and stress suites
- 342 seeded programs/problems and 4,984 SymPy oracle assertions
- Standalone behavioral validation of emitted expression, quadrature, and
  Newton code

See [the release baseline](docs/validation/release-baseline.md) for limitations,
compiler cost, scaling, code size, and runtime measurements.
