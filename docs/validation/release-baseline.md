# v0.2.0 validation baseline

Measured July 30, 2026 on an Apple M1 Pro with 16 GiB RAM, macOS 26.5.1,
and Zig 0.16.0. These are machine-local progression numbers, not portable
performance promises.

## Validation surface

| Surface | Result |
| --- | ---: |
| Runtime, property, hardening, and stress tests | 155 passed |
| Automatically discovered compile-fail fixtures | 56 passed |
| SymPy differential programs/problems | 342 passed |
| Independent SymPy oracle assertions | 4,984 passed |
| Standalone emitted callable types and targets | 5 × 2 passed |
| Largest measured construction peak | 368 / 1,024 nodes |

The full `zig build check` gate passed. It checks formatting, the complete
test graph, seeded SymPy differential validation, standalone Zig and C
emission, and API documentation generation.

The differential corpus uses seed `0xb0b3111` and SymPy 1.12. It generates
temporary Zig batches for simplification, gradients and Hessians, polynomial
expansion, rational functions, supported symbolic integration, exact systems
from 2×2 through 4×4, fixed quadrature, and Newton solves. SymPy computes the
expected numeric constants independently. Temporary batches keep compiler
memory bounded and make a failure reproducible by category and batch.

The standalone emission check captures values from Bombelli's direct compiled
objects, emits Zig and C, rejects symbolic imports and machinery by source
inspection, and compiles and executes both targets independently. Expression,
smooth-expression, gradient, fixed-quadrature, and Newton callables pass.
Emitted C is compiled as C99 with strict warnings and depends only on
`<math.h>` and `<stddef.h>`.

## Compile cost

Fresh local and global Zig caches were used for these two top-level commands:

| Command | Wall time | Maximum resident set |
| --- | ---: | ---: |
| `zig build test --summary all` | 31.34 s | 987,299,840 bytes (942 MiB) |
| `zig build stress --summary all` | 16.27 s | 973,783,040 bytes (929 MiB) |

The `test` step now includes the core suite, compile-fail fixtures, stress
tests, deterministic properties, and numerical hardening. The full seeded
differential command takes approximately two minutes in 27 bounded compiler
invocations. Standalone emission validation takes approximately 15 seconds.

Zig does not report actual comptime backward-branch consumption. Bombelli
therefore records configured ceilings rather than pretending they are measured
usage: basic differentiation and simplification use 5 million; shared
multi-output transformations use 10–20 million; rational-function and emission
work uses up to 30 million; integration, solving, quadrature construction, and
generated solvers use 50 million. The release stress suite exercises every
ceiling class.

## Compile scaling

The reproducible scaling tool warms one shared global Zig cache, gives every
case a fresh local cache, and reports end-to-end `zig test` wall time.

| Case | Wall time |
| --- | ---: |
| Nested sine derivative, depth 4 | 1.828 s |
| Nested sine derivative, depth 8 | 1.924 s |
| Nested sine derivative, depth 12 | 1.961 s |
| Nested sine derivative, depth 16 | 2.063 s |
| Shared gradient, 2 symbols | 1.900 s |
| Shared gradient, 4 symbols | 2.371 s |
| Shared gradient, 8 symbols | 2.250 s |
| Shared gradient, 16 symbols | 2.663 s |
| Symbolic Bareiss system, 2×2 | 1.910 s |
| Symbolic Bareiss system, 3×3 | 2.183 s |
| Symbolic Bareiss system, 4×4 | 5.605 s |

The 4×4 symbolic system remains the clearest compile-time scaling pressure
point, but its measured time fell from 7.778 seconds in the v0.1.0 baseline to
5.605 seconds here. The current 368-node construction peak still leaves 656
nodes of measured workspace headroom.

## Generated size and runtime

| Callable | Emitted Zig | Emitted C |
| --- | ---: | ---: |
| Scalar expression | 1,960 bytes | 2,163 bytes |
| Smooth expression | 2,362 bytes | 2,593 bytes |
| Gradient | 2,486 bytes | 2,682 bytes |
| Order-16 quadrature | 7,604 bytes | 8,005 bytes |
| 2×2 Newton solver | 9,145 bytes | 10,102 bytes |

These five cases total 49,102 bytes across both targets. Source size is
reported instead of a standalone Zig object size because the emitted Zig API
is generic over its input struct. Compiling that source without a concrete
caller does not instantiate the callable and therefore measures a
dead-stripped object rather than the generated numerical kernel.

A five-million-evaluation scalar benchmark compares a Bombelli-compiled
expression with equivalent handwritten Zig. Medians over seven timed runs,
alternating execution order after warmup, were 33.258 ns/evaluation for
Bombelli and 33.559 ns/evaluation for handwritten Zig. Bombelli took 0.9910×
as long on this fixture. This supports runtime parity; it is not a general
performance claim.

Reproduce the scaling, emitted-source-size, and runtime measurements with:

```sh
python3 -B benchmarks/measure_release.py
```

## Audit findings

Release preparation found and fixed two regressions in the measurement path:

- The release script still named the three pre-refactor Zig emission
  generators, so the documented reproduction command failed after emission
  expanded to five callable types and two targets.
- Building a generated Zig file alone no longer measured the callable's object
  code because its `anytype` input remained uninstantiated. Nearly identical
  tiny objects exposed the dead-stripping. The benchmark now reports source
  sizes for all five Zig/C pairs, while the separate emission gate compiles and
  executes every concrete case.

Numerical release hardening also covers strict function-evaluation budgets,
extreme residual and parameter scales, refreshed terminal diagnostics,
rank-deficient fitting, bounded optimization, runtime observation slices,
extended elementary-function domains, and symbolic Jacobian verification.
