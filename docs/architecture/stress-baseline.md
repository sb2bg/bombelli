# Expression-growth baseline

Measured on July 24, 2026 with Zig 0.16.0 on arm64 macOS. Each measurement used
fresh local and global Zig caches. The current command was:

```sh
zig build stress --summary all
```

The complete build took 9.83 seconds of wall time. Zig reported 2 seconds and
280 MiB maximum RSS for the stress-test compilation. The pre-DAG build took
8.34 seconds, with Zig reporting 3 seconds and 283 MiB. These numbers are local
baselines, not portable benchmarks.

## The boundary that prompted the change

Bombelli originally stored every expression in its own 512-node array. Each
`Expr` occupied 12,320 bytes, even when the expression contained only a few
nodes.

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

The ten-factor derivative was 77% structural duplication. Differentiating a
twenty-factor product exhausted the array, and simplifying a twelve-factor
product derivative exhausted it while retaining discarded construction nodes.

## Compact DAG results

Construction now goes through hash-consed constructors, transformations cache
results by source `NodeId`, and each finished expression retains an exactly
sized slice containing only unique, reachable nodes.

| Case | Phase | Stored | Reachable | Structurally unique | Backing bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| Twenty-factor product | Source | 60 | 60 | 60 | 1,480 |
| Twenty-factor product | Derivative | 118 | 118 | 118 | 2,872 |
| Twenty-factor product | Simplified | 96 | 96 | 96 | 2,344 |
| Deep composition | Source | 6 | 6 | 6 | 184 |
| Deep composition | Derivative | 14 | 14 | 14 | 376 |
| Deep composition | Simplified | 12 | 12 | 12 | 328 |
| Four derivatives of `x^12` | Final | 4 | 4 | 4 | 136 |
| Repeated `sin(x*y)` | Source | 9 | 9 | 9 | 256 |
| Repeated `sin(x*y)` | Derivative | 25 | 25 | 25 | 640 |
| Repeated `sin(x*y)` | Simplified | 21 | 21 | 21 | 544 |

Every measured result has zero structural duplicates and zero unreachable
nodes. More importantly, the twenty-factor case that previously failed now
completes with substantial headroom. Persisted storage is proportional to the
result rather than the temporary construction limit.

The ten-factor derivative gives a direct before-and-after comparison: its
stored representation fell from 255 nodes to the same 58 unique nodes the old
measurement had exposed.

## What remains

This change removes accidental representation duplication; it does not make
inherently large mathematics small. Nested products, quotients, compositions,
and repeated transformations can still produce genuinely large results.

The next scaling tools should therefore target expression swell itself:

- N-ary addition and multiplication
- Factored representations rather than eager expansion
- Polynomial-specific storage and algorithms
- Delayed or bounded simplification
- Common-subexpression elimination in generated numerical code
- Larger or segmented construction storage when real workloads require it

The stress suite keeps the important distinction explicit: unique reachable
node count measures mathematical size, while duplicate and unreachable counts
measure representation waste.
