# Current validation baseline

Measured August 6, 2026 with Zig 0.16.0. Timing and memory vary by machine;
the test counts and emitted source sizes are reproducible repository checks.

## Validation surface

| Surface | Result |
| --- | ---: |
| Runtime, property, hardening, and stress tests | 163 passed |
| Automatically discovered compile-fail fixtures | 63 passed |
| SymPy differential programs/problems | 342 passed |
| Independent SymPy oracle assertions | 4,984 passed |
| Standalone emitted callable types and targets | 6 × 2 passed |
| Largest measured construction peak | 368 / 1,024 nodes |

`zig build check --summary all` checks formatting, every example, the complete
test graph, seeded SymPy differential validation, standalone Zig and C
emission, and API documentation generation. SymPy validation uses seed
`0xb0b3111` and SymPy 1.12.

## Generated source size

| Callable | Zig | C |
| --- | ---: | ---: |
| Scalar expression | 1,960 bytes | 2,163 bytes |
| Smooth expression | 2,362 bytes | 2,593 bytes |
| Gradient | 2,486 bytes | 2,682 bytes |
| Order-16 quadrature | 7,604 bytes | 8,005 bytes |
| 2×2 Newton solver | 9,145 bytes | 10,102 bytes |
| Runtime-observation fitter | 39,477 bytes | 50,517 bytes |

Together the twelve generated units contain 139,096 source bytes.

The emission gate rejects symbolic imports, compiles generated C as C99 with
strict warnings, and executes both targets independently of Bombelli.

Reproduce source-size and runtime measurements with:

```sh
python3 -B benchmarks/measure_release.py
```
