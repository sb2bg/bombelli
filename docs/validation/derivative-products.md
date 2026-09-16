# Derivative-product measurements

Measured September 7, 2026 on an Apple M1 Pro, macOS 26.5.1, Zig 0.16.0,
ReleaseFast. Each runtime value is the median of three process runs with
1,000,000 evaluations per run, after a warm-up run. Inputs and seeds vary
at runtime; every output remains observable. Timings include process
startup and the common input/checksum loop.

The explicit baseline builds `model.jacobian().simplify()` and multiplies
it by the seed. Direct products use forward propagation for JVP and reverse
propagation for VJP. This compares against a simplified Jacobian, not the
larger fused value-and-Jacobian program. Checksums agree to the benchmark's
tolerance; unit tests additionally check individual outputs against explicit
Jacobians, finite differences, duality, and analytic formulas.

## Shared dense model

The model family is `f_i(x) = x_i*sin(sum(x))`. Its Jacobian is structurally
dense, but derivative products can share the sum and its derivative work.

| Variables/outputs | Explicit JVP (ns) | Direct JVP (ns) | Explicit VJP (ns) | Direct VJP (ns) |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 22.66 | 20.43 | 22.41 | 20.61 |
| 8 | 45.58 | 25.31 | 32.06 | 26.30 |
| 16 | 135.59 | 36.64 | 101.49 | 34.35 |
| 32 | Construction limit | 70.02 | Construction limit | 65.37 |

At 16 variables, these are 3.70× and 2.95× speedups for JVP and VJP.
Automatic selection chose the same forward/reverse methods throughout this
family; its separate timing samples are included in the raw results.

| Variables/outputs | Explicit construction peak | Direct construction peak | Explicit JVP compile (s) | Direct JVP compile (s) |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 60 | 34 | 5.070 | 4.989 |
| 8 | 198 | 66 | 5.562 | 5.061 |
| 16 | 714 | 130 | 8.972 | 5.316 |
| 32 | Exceeds 1,024 | 258 | Failed | 5.950 |

Construction peaks are the expression metrics, not process memory. Each
compile uses a fresh local cache and the normal shared global compiler
cache. Compile times therefore include substantial fixed compiler/linker
costs and are not fully cold toolchain measurements.

The explicit Jacobian's final DAG can have fewer nodes than the complete
seed-dependent product while still requiring more contraction work. Its
node count excludes the matrix multiplication that follows evaluation.
Raw node counts for these two artifacts should not be interpreted as a
direct comparison of their runtime work or storage.

## Sparse neighbor model

The second fixture is `f_i(x) = sin(x_i*x_(i+1)) + x_i^2`, with cyclic
neighbor indices. At 16 variables it has 32 structurally nonzero Jacobian
entries out of 256.

| Product | Explicit (ns) | Direct (ns) | Speedup |
| --- | ---: | ---: | ---: |
| JVP | 155.77 | 58.29 | 2.67× |
| VJP | 98.08 | 65.82 | 1.49× |

The reported construction peak falls from 323 to 178 nodes. Automatic
selection chose direct propagation for both products. Improvements are
smaller than in the 16-variable shared dense fixture, particularly for VJP.

## Validation boundary

The 32-variable case is also checked against an independent analytic oracle
in `tests/products.zig`. The explicit benchmark fails while constructing
the Jacobian, before runtime evaluation; the direct products succeed.

A standalone benchmark exposed a separate compile-time quota issue that
the original large unit test masked. Constructing the model inside the test
body raised its branch quota, allowing subsequent input validation to pass.
The regression now keeps model construction in a separate declaration;
removing the product evaluator's quota increase makes that test fail.

## Reproduction

```sh
python3 benchmarks/measure_products.py --sizes 4 8 16 32 --output /tmp/products-shared.json
python3 benchmarks/measure_products.py --shape sparse --sizes 16 --output /tmp/products-sparse.json
```

Results are fixture- and machine-specific. The strategy estimator is a
structural heuristic and does not predict CPU cycles. The compiler supports
overrides so callers can measure competing strategies for their own model.

Full results, including automatic-strategy samples and compile failures:
[shared model](derivative-products-shared.json) and
[sparse model](derivative-products-sparse.json).
