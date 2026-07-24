# Expression-growth baseline

Measured on July 24, 2026 with Zig 0.16.0 on arm64 macOS. The command used a
fresh local Zig cache:

```sh
zig build stress --summary all
```

The complete build took 8.34 seconds of wall time. Zig reported 3 seconds and
283 MiB maximum RSS for the stress-test compilation. These numbers are a local
baseline, not a portable benchmark.

Each current `Expr` contains a 512-node backing array and occupies 12,320 bytes
regardless of how many nodes it uses.

## Results

| Case | Phase | Stored | Reachable | Structurally unique | Duplicate occurrences | Unreachable construction nodes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Ten-factor product | Source | 39 | 39 | 30 | 9 | 0 |
| Ten-factor product | Derivative | 255 | 255 | 58 | 197 | 0 |
| Ten-factor product | Simplified | 299 | 215 | 46 | 169 | 84 |
| Deep composition | Source | 6 | 6 | 6 | 0 | 0 |
| Deep composition | Derivative | 26 | 26 | 14 | 12 | 0 |
| Deep composition | Simplified | 30 | 24 | 12 | 12 | 6 |
| Four derivatives of `x^12` | Final | 4 | 4 | 4 | 0 | 0 |
| Repeated `sin(x*y)` | Source | 17 | 17 | 9 | 8 | 0 |
| Repeated `sin(x*y)` | Derivative | 62 | 62 | 25 | 37 | 0 |
| Repeated `sin(x*y)` | Simplified | 52 | 43 | 21 | 22 | 9 |

Two larger compile-fail fixtures record the present capacity boundary:

- Differentiating the twenty-factor product exhausts the 512-node array.
- A twelve-factor product can be differentiated, but its simplification pass
  exhausts the array while rebuilding products.

## Interpretation

The ten-factor product derivative has 255 reachable node occurrences but only
58 structurally unique subexpressions. About 77% of its reachable representation
is duplication. After simplification, about 79% is still duplicated, and 84
additional constructed nodes are no longer reachable from the result.

That is strong evidence for a shared arena with hash-consed constructors.
Memoized differentiation will then prevent repeated transformation of shared
node IDs. The simplification numbers also show that canonical constructors
should be used during rebuilding so discarded intermediate nodes do not consume
arena capacity.

The repeated power derivative is the useful counterexample: because powers are
represented directly and simplification runs between derivatives, its fourth
derivative remains a four-node expression. Expression growth is therefore
highly shape-dependent; Bombelli needs to distinguish avoidable duplication
from genuinely large symbolic results.

The next representation milestone should pair structural interning with
memoized transformations. Merely increasing the fixed capacity would make each
`Expr` larger while leaving the measured duplication intact.
