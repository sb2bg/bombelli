# v0.1.0 validation baseline

Measured July 24, 2026 on an Apple M1 Pro with 16 GiB RAM, macOS 26.5.1,
and Zig 0.16.0. These are machine-local progression numbers, not portable
performance promises.

## Validation surface

| Surface | Result |
| --- | ---: |
| Core, property, hardening, and compile-fail tests | 76 passed |
| Stress tests | 11 passed |
| SymPy differential programs/problems | 342 passed |
| Independent SymPy oracle assertions | 4,984 passed |
| Standalone emitted callable types | 3 passed |
| Largest measured construction peak | 368 / 1,024 nodes |

The differential corpus uses seed `0xb0b3111` and SymPy 1.12. It generates
temporary Zig batches for simplification, gradients and Hessians, polynomial
expansion, rational functions, supported symbolic integration, exact systems
from 2×2 through 4×4, fixed quadrature, and Newton solves. SymPy computes the
expected numeric constants independently. Temporary batches keep compiler
memory bounded and make a failure reproducible by category and batch.

The standalone emission check captures values from Bombelli's direct compiled
objects, emits Zig, rejects symbolic imports and machinery by source
inspection, then compiles and executes the emitted code independently.
Expression, fixed-quadrature, and Newton emission pass this check.

## Compile cost

Fresh local and global Zig caches were used for these two top-level commands:

| Command | Wall time | Maximum resident set |
| --- | ---: | ---: |
| `zig build test --summary all` | 19.41 s | 813,711,360 bytes (776 MiB) |
| `zig build stress --summary all` | 18.56 s | 1,118,289,920 bytes (1.04 GiB) |

The full seeded differential command takes approximately two minutes in 27
bounded compiler invocations. Standalone emission validation takes
approximately 15 seconds.

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
| Nested sine derivative, depth 4 | 1.854 s |
| Nested sine derivative, depth 8 | 1.876 s |
| Nested sine derivative, depth 12 | 1.894 s |
| Nested sine derivative, depth 16 | 1.971 s |
| Shared gradient, 2 symbols | 1.886 s |
| Shared gradient, 4 symbols | 1.953 s |
| Shared gradient, 8 symbols | 2.282 s |
| Shared gradient, 16 symbols | 3.359 s |
| Symbolic Bareiss system, 2×2 | 1.982 s |
| Symbolic Bareiss system, 3×3 | 2.496 s |
| Symbolic Bareiss system, 4×4 | 7.778 s |

The 4×4 result shows the expected symbolic-elimination cost curve. It remains
within the current construction workspace but is the first clear compile-time
scaling pressure point.

## Generated size and runtime

| Callable | Emitted Zig | ReleaseFast object |
| --- | ---: | ---: |
| Scalar expression | 2,101 bytes | 4,176 bytes |
| Order-16 quadrature | 8,079 bytes | 16,632 bytes |
| 2×2 Newton solver | 10,175 bytes | 14,032 bytes |

A five-million-evaluation scalar benchmark compares a Bombelli-compiled
expression with equivalent handwritten Zig. Medians over seven timed runs,
alternating execution order after warmup, were 32.854 ns/evaluation for
Bombelli and 32.882 ns/evaluation for handwritten Zig (0.9991×). This supports
runtime parity on this fixture; it is not a general performance claim.

Reproduce the scaling, size, and runtime measurements with:

```sh
python3 -B benchmarks/measure_release.py
```

## Audit findings

Release hardening found and fixed two defects that example-based tests had
missed:

- Rendering a negative rational n-ary term with more than two factors inferred
  a comptime string's first exact array length. A longer next fragment then
  failed compilation. The renderer now uses an explicit string slice.
- An invertible constant coefficient matrix with symbolic right-hand sides
  returned a vacuous conditional solution. It now returns an unconditional
  finite solution; genuinely symbolic determinants retain one explicit
  nonzero condition.

Focused hardening tests also cover real rational-power branches,
`ln(abs(x))` away from its singularity, preservation of removable
singularities, multi-term partial integration, differentiated fixed
quadrature, near-singular sensitivities, non-finite Newton inputs, adaptive
orientation, and depth exhaustion.
