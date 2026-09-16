# Compiler scalability and lifetime measurements

The compiler now supports root-module construction limits, validates graphs
before evaluation and emission, measures logical value lifetimes, and
assembles generated source from fragments. Usage and configuration details
are in the [compiler resources guide](../guides/compiler-resources.md).

## Measurement method

Measured on macOS 26.5.1, Apple arm64, Zig 0.16.0. Each compile-time result
is the median of three sequential ReleaseFast builds with separate local
caches and the normal shared global cache. Times include generator executable
compilation and linking, not execution of the emitted numerical kernel.
Peak RSS is the compiler process maximum reported by `/usr/bin/time -l`;
individual samples vary and are retained in the raw report.

The baseline is a saved copy of the working tree before these compiler
changes, including the compiled derivative-product implementation. The
comparison measures the combined changes, including validation and scratch
workspace sizing; it does not isolate text assembly from all other changes.

Jacobian fixtures use `f_i(x) = x_i*sin(sum(x))` and emit the simplified
explicit Jacobian. The fitter fixture uses a 12-parameter polynomial residual
over runtime observations. Every before/after sample must produce the same
SHA-256 of the complete emitted source. Generated C and Zig are separately
compiled and executed by `zig build check`.

| Generator fixture | Before (s) | After (s) | Speedup | Compiler RSS before → after (MiB) |
| --- | ---: | ---: | ---: | ---: |
| 8-variable Jacobian → C | 8.309 | 6.983 | 1.19× | 513.2 → 262.6 |
| 16-variable Jacobian → C | 33.998 | 11.224 | 3.03× | 738.1 → 375.8 |
| 12-parameter fitter → C | 22.716 | 10.053 | 2.26× | 409.9 → 414.6 |
| 16-variable Jacobian → Zig | 29.247 | 9.477 | 3.09× | 749.6 → 567.4 |

All four fixtures emit byte-for-byte identical source before and after.
Compiler RSS fell in the Jacobian cases; the fitter's median RSS was roughly
unchanged. These are fixture-specific measurements, not runtime speedups.

## Slot reuse experiment

The experiment rewrites the emitted C nodes into a conservatively reused
scratch array. Each slot remains reserved through its final consumer, and
output roots are pinned through the final output copy. It then compiles both
versions with Apple Clang 17.0.0, `-O2 -ffp-contract=off`, and compares the
complete optimized `kernel` function assembly.

For the 8-variable Jacobian, 27 logical node slots can be represented by 18
scratch slots. For the 16-variable case, 51 slots can be represented by 34.
Both pairs produce identical optimized kernel assembly. This experiment
therefore supplies no evidence that explicit reuse improves these kernels.
The production evaluator retains its existing unrolled implementation;
`peak_live_values` exposes the structural information without claiming a
physical stack bound. This conclusion is limited to the tested C kernels
and compiler, rather than a guarantee for every backend or build mode.

## Correctness coverage

- A configured 4,097-node workspace builds a 32-variable explicit Jacobian
  whose construction exceeds the default 1,024-node limit. Its entries are
  checked against an analytic oracle at a point with distinct coordinates.
- Compile-fail fixtures cover zero and exhausted construction limits,
  invalid child/root IDs, cyclic references, duplicate nodes, and unreachable
  nodes at evaluation, metrics, and emission boundaries.
- Lifetime fixtures cover chains, shared children, duplicate output roots,
  retained interior outputs, and primal edges through zero powers.
- Full validation includes the existing property/stress/hardening tests,
  SymPy differential comparisons, and independently compiled Zig/C emission.

## Validation result

`zig build check -j2 --summary all` passed all 104 build steps and 178 tests,
plus the configured-capacity executable and compile-fail diagnostics. SymPy
1.14.0 checked 342 programs/problems with 4,984 oracle assertions across 27
seeded batches. Standalone emission validation compiled and executed all
eight callable types in both targets (148,048 generated source bytes total).
Formatting, examples, and API documentation generation also passed.

## Reproduction

```sh
python3 benchmarks/measure_compiler.py \
  --baseline /path/to/saved/pre-change/bombelli \
  --samples 3 \
  --output /tmp/compiler-improvements.json
zig build test-configured
zig build check
```

[Raw measurements and generated-source hashes](compiler-improvements.json).
