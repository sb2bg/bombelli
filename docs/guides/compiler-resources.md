# Compiler resources and graph inspection

Bombelli defaults to 1,024 temporary nodes per symbolic construction
workspace. Applications can select a larger or smaller bound in their root
source file, without modifying the library:

```zig
const bombelli = @import("bombelli");

pub const bombelli_options: bombelli.Options = .{
    .construction_nodes = 4096,
};
```

The setting applies to the whole compilation, including transforms and
polynomial term storage. It is not a per-expression setting. The interning
hash table rounds its capacity independently, so the node limit need not be
a power of two. Increasing the bound permits larger intermediate programs;
it does not make symbolic expansion cheaper. Finished graphs still contain
only exact-sized reachable node and operand stores.

Construction limits are read from Zig's `@import("root")`. For `zig test`,
that root is the test runner, not the test source file. Set the option in a
custom test runner when required, or use an executable regression fixture
as in `tests/configured.zig`. `zig build test-configured` compiles and runs
a balanced 1,025-node expression with a non-power-of-two limit of 1,031.
It checks exact construction headroom and evaluates the original expression,
its simplification, and its derivative against independent formulas.

## Logical lifetimes

```zig
const expression = comptime bombelli.expr("sin(cos(exp(sin(cos(x)))))");
const metrics = comptime expression.metrics();
// metrics.node_count == 6
// metrics.peak_live_values == 2
```

`peak_live_values` measures simultaneous logical values in the existing
topological evaluation order. Each node lives through its final consumer;
output roots remain live until the final output copy. Repeated output roots
share one lifetime. The peak includes both a new result and its operands
during an operation, without assuming destructive updates.

These counts include constants and inputs. They are not measurements of
machine registers, stack bytes, or heap allocations. A vectorized evaluation
slot can contain a SIMD vector, and the backend compiler can fold constants
and eliminate storage. Compiled JVP/VJP `inspect()` reports the same peak
alongside `temporary_scalars`, which retains its meaning as the number of
logical evaluator slots before optimization.

## Validation and source generation

The shared validator checks root IDs, child IDs, topological order,
reachability, structural uniqueness, and construction metadata. Evaluation
and all source-emission entry points validate their expression programs at
compile time. Child references are checked before traversal, so malformed
graphs produce Bombelli diagnostics rather than indexing failures.

Source emitters collect immutable text fragments while counting bytes, then
copy them into one exact-sized buffer per assembled text. Node emission,
output assignments, solver templates, and scalar/placeholder substitutions
use this collector. Appending a fragment does not recopy the accumulated
prefix, and no collector exists in the emitted numerical program.

See the [compiler measurements](../validation/compiler-improvements.md) for
reproducible compilation and storage experiments.
