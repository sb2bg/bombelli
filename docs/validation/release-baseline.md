# Current validation baseline

Validated September 7, 2026 with Zig 0.16.0. Timing and memory vary by machine;
the test counts and emitted source sizes are reproducible repository checks.

## Validation surface

| Surface | Result |
| --- | ---: |
| Runtime, property, hardening, and stress tests | 173 passed |
| Automatically discovered compile-fail fixtures | 65 passed |
| SymPy differential programs/problems | 342 passed |
| Independent SymPy oracle assertions | 4,984 passed |
| Standalone emitted callable types and targets | 8 × 2 passed |
| Largest stress-suite construction peak | 368 / 1,024 nodes |

`zig build check --summary all` checks formatting, every example, the complete
test graph, seeded SymPy differential validation, standalone Zig and C
emission, and API documentation generation. This local run used seed
`0xb0b3111` and SymPy 1.14.0; CI continues to pin SymPy 1.12.

## Generated source size

| Callable | Zig | C |
| --- | ---: | ---: |
| Scalar expression | 1,960 bytes | 2,163 bytes |
| Smooth expression | 2,362 bytes | 2,593 bytes |
| Gradient | 2,486 bytes | 2,682 bytes |
| Order-16 quadrature | 7,604 bytes | 8,005 bytes |
| 2×2 Newton solver | 9,145 bytes | 10,102 bytes |
| Runtime-observation fitter | 39,477 bytes | 50,517 bytes |
| Direct JVP | 2,129 bytes | 2,347 bytes |
| Direct VJP | 2,129 bytes | 2,347 bytes |

Together the sixteen generated units contain 148,048 source bytes.

The emission gate rejects symbolic imports, compiles generated C as C99 with
strict warnings, and executes both targets independently of Bombelli.

Reproduce source-size and runtime measurements with:

```sh
python3 -B benchmarks/measure_release.py
```

Compiled JVP/VJP scaling, runtime, and construction-limit results are recorded
in the [derivative-product measurements](derivative-products.md).
