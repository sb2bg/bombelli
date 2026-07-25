# Expression-growth baseline

Measured on July 24, 2026 with Zig 0.16.0 on arm64 macOS. Each measurement used
fresh local and global Zig caches. The current command was:

```sh
zig build stress --summary all
```

The current build took 9.75 seconds of wall time. Zig reported 2 seconds and
365 MiB maximum RSS for the stress-test compilation. The first compact-DAG
baseline took 9.83 seconds and 280 MiB; the pre-DAG build took 8.34 seconds and
283 MiB. The current suite performs more simplification and invariant checking,
so these are progression markers rather than like-for-like microbenchmarks.
They are local baselines, not portable measurements.

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

| Case | Phase | Nodes | Construction peak | Headroom | Backing bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| Twenty-factor product | Source | 60 | 60 | 964 | 1,488 |
| Twenty-factor product | Derivative | 118 | 118 | 906 | 2,880 |
| Twenty-factor product | Simplified | 96 | 97 | 927 | 2,352 |
| Deep composition | Source | 6 | 6 | 1,018 | 192 |
| Deep composition | Derivative | 14 | 14 | 1,010 | 384 |
| Deep composition | Simplified | 12 | 16 | 1,008 | 336 |
| Four derivatives of `x^12` | Final | 4 | 10 | 1,014 | 144 |
| Repeated `sin(x*y)` | Source | 9 | 9 | 1,015 | 264 |
| Repeated `sin(x*y)` | Derivative | 25 | 25 | 999 | 648 |
| Repeated `sin(x*y)` | Simplified | 21 | 27 | 997 | 552 |
| Twenty repeated `x` factors | Source | 20 | 20 | 1,004 | 528 |
| Twenty repeated `x` factors | Simplified | 2 | 20 | 1,004 | 96 |

Hash-consing and builder compaction make structural uniqueness, reachability,
and topological order invariants. `metrics()` verifies those invariants and
reports both persisted size and the peak monotonic builder length that produced
the expression.

The largest measured construction peak is 118 nodes, leaving 906 nodes of
headroom in the guarded 1,024-node workspace. That evidence does not justify an
unbounded builder rewrite today. Persisted storage remains proportional to the
result rather than the temporary construction limit.

## Exact, n-ary, and multi-root remeasurement

After exact rationals, rational powers, canonical n-ary addition and
multiplication, multi-root programs, and substitution landed, the stress suite
was expanded before reconsidering construction storage. N-ary operand lists are
stored as exact-size comptime-backed slices and therefore do not consume a
second fixed-capacity construction arena. Metrics now report both nodes and
operand edges.

| Case | Phase | Nodes | Operand edges | Construction peak | Headroom | Backing bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Coupled 4-output functions | Source | 22 | 0 | 22 | 1,002 | 808 |
| Coupled 4×4 Jacobian | Simplified | 40 | 64 | 40 | 984 | 1,880 |
| Canonical 48-term sum | Source | 95 | 0 | 95 | 929 | 3,088 |
| Canonical 48-term sum | Simplified | 49 | 48 | 95 | 929 | 1,808 |
| Canonical 32-factor product | Source | 63 | 0 | 63 | 961 | 2,064 |
| Canonical 32-factor product | Simplified | 33 | 32 | 63 | 961 | 1,232 |

The twenty-factor derivative remains the largest construction peak at 118
nodes. The new workloads therefore still leave 906 nodes of measured headroom,
and finished storage is proportional to actual nodes plus actual n-ary operand
edges. A segmented or otherwise scalable node builder remains the next response
if later polynomial, system-solving, or integration workloads materially close
that gap; globally enlarging the fixed array is not the planned response.

The ten-factor derivative gives a direct before-and-after comparison: its
stored representation fell from 255 nodes to the same 58 unique nodes the old
measurement had exposed.

Multiplication simplification now propagates factor multiplicities through the
DAG instead of recursively expanding occurrences. Twenty repeated `x` factors
finish as the two-node expression `x^20`. A repeatedly squared shared DAG can
likewise collapse to a power without walking its exponentially large tree
interpretation.

## What remains

This change removes accidental representation duplication; it does not make
inherently large mathematics small. Nested products, quotients, compositions,
and repeated transformations can still produce genuinely large results.

The next scaling tools should therefore target expression swell itself:

- N-ary addition and multiplication
- Factored representations rather than eager expansion
- Polynomial-specific storage and algorithms
- Delayed or bounded simplification
- Larger or segmented construction storage only when measured peaks require it

Generated numerical evaluation now follows the DAG in topological order and
computes every stored node once. Rendering likewise builds each node's source
fragment once, although a flat, re-parsable expression must still repeat shared
text at each use; shortening that final text would require adding named bindings
to Bombelli's source language.

The stress suite verifies the builder invariants and records mathematical node
count, peak construction use, remaining workspace headroom, and persisted
storage cost.
