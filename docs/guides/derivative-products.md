# Compiling Jacobian products

For a model with `M` outputs and `N` declared variables, `compileJvp`
returns an `N`-seed, `M`-output program computing `Jv`. `compileVjp` returns
an `M`-seed, `N`-output program computing `Jᵀv`. Variable coordinates follow
declaration order; output coordinates follow expression order. Other inputs
are held constant.

```zig
const model = comptime bombelli.model(.{
    "x*sin(x+y+z)",
    "y*sin(x+y+z)",
    "z*sin(x+y+z)",
}, .{ .variables = .{ .x, .y, .z } });
const forward = comptime model.compileJvp(.{});
const reverse = comptime model.compileVjp(.{});
const point = .{ .x = 0.2, .y = 0.3, .z = 0.4 };
const jv = forward.eval(point, .{ 1.0, -2.0, 3.0 });
const vj = reverse.eval(point, .{ 0.5, 1.0, -0.5 });
```

`model.jvp(point, tangent)` and `model.vjp(point, cotangent)` are convenience
forms with automatic strategy selection. Compiled products also expose
`evalAs(T, inputs, seed)`, `evalInto(output, inputs, seed)`, and
`evalIntoAs(T, output, inputs, seed)`.

Existing `linearize()` and its JVP/VJP methods retain their behavior. Use
`linearize()` when values and the full Jacobian are needed; use a compiled
product when only the contraction is needed.

## Choosing and inspecting a strategy

The `strategy` option accepts:

- `.auto` (default): compare structural operation estimates before building
  one selected program. Ties select direct propagation.
- `.direct`: forward tangent propagation for JVP, reverse adjoint
  accumulation for VJP. No Jacobian entries are constructed.
- `.symbolic`: differentiate structurally nonzero entries, simplify them,
  and contract them with seeds into a shared expression vector. Entries
  are constructed at compile time; no matrix is evaluated at runtime.

Automatic estimates count local slope work, derivative propagation, and
contraction using variable-dependency masks. They do not model CPU cycles,
transcendental latency, cancellation, or all common-subexpression sharing.
They are a heuristic, not a guarantee of the fastest or smallest result.
An explicit strategy override makes comparisons reproducible. Only the
selected candidate is built, so choosing direct propagation does not first
pay for constructing a symbolic Jacobian.

```zig
const compiled = comptime model.compileVjp(.{ .strategy = .direct });
const info = comptime compiled.inspect();
```

Inspection distinguishes estimates from measurements of the constructed DAG:

| Field | Meaning |
| --- | --- |
| `method` | `forward`, `reverse`, or `symbolic` |
| `estimated_direct_operations`, `estimated_symbolic_operations` | Structural selection scores, in scalar-operation units |
| `structural_nonzeros`, `jacobian_entries` | Dependency upper bound versus `M*N`; algebraic cancellation may remove more entries |
| `operations` | Finished DAG operations; an n-ary operation counts `arity-1`, each other operation counts one |
| `node_count`, `temporary_scalars` | Finished nodes and logical evaluator scalar slots |
| `peak_live_values` | Peak simultaneous logical values, including retained output roots; not measured stack usage |
| `shared_nodes` | Nodes used more than once, including output-root uses |
| `construction_peak_nodes` | Construction peak reported by the selected expression's `metrics()` |

Logical scalar slots are not measured stack memory or register usage.
Backend optimization can remove or reuse storage. Counts include the
derivative seeds but exclude caller-owned input/output arrays. Construction
still uses Bombelli's guarded 1,024-node workspace. This product metric
excludes source-model construction and temporary local-slope templates.

## How propagation works

Compile-time dependency masks identify which source nodes depend on each
declared variable. Data-only paths do not receive derivatives. Forward mode
seeds the variable nodes and visits parents in topological order. Reverse
mode seeds output roots and visits nodes in reverse order, accumulating all
parent contributions before propagating to children. Duplicate outputs and
outputs that are also intermediate nodes therefore work without special
runtime handling.

Local slopes reuse Bombelli's existing elementary derivative rules. Wide
products use shared prefix/suffix products, so slope construction is linear
in their arity and does not divide by a potentially zero factor. The final
product is an ordinary shared expression DAG: it uses the existing evaluator
and emitters, without a runtime differentiation tape.

Derivative results have the usual mathematical domain restrictions. Holding
a data input fixed prunes its derivative path; it does not validate the
primal model value. Products can therefore be finite where a separately
evaluated primal is undefined. Reassociation also means different strategies
can differ in rounding, overflow behavior, and NaN propagation. A zero
runtime seed does not act as a request to skip an active derivative path.

## Standalone emission

```zig
const source = comptime compiled.emit(.{ .target = .c, .name = "apply_adjoint" });
const seed_fields = comptime compiled.seed_names;
```

Generated callables use the existing expression-vector ABI: ordinary inputs
and seed fields in one input struct, plus caller-owned output storage. Seed
names start at `bombelli_seed_0` and skip collisions with original symbols
and declared inputs/variables. Use `seed_names` to discover their order;
fields absent from the finished program are omitted by emission. Native
`eval` accepts seeds separately and rejects attempts to supply generated
seed fields through the ordinary model input struct.

Both Zig and C emission are compiled and executed in `zig build check`.

## Reproduce the comparison

```sh
zig build run-products
python3 benchmarks/measure_products.py --output /tmp/products-shared.json
python3 benchmarks/measure_products.py --shape sparse --output /tmp/products-sparse.json
```

The shared fixture is `f_i(x) = x_i*sin(sum(x))`; the sparse fixture couples
each variable to its neighbor. The script compares automatic and direct
products with a simplified explicit Jacobian followed by multiplication.
All inputs and seeds vary at runtime, and output checksums must agree.
ReleaseFast compile timings use separate local caches and the normal shared
global cache. Runtime medians include process startup. Run without other
builds competing for CPU, and treat results as fixture- and machine-specific.
The [recorded measurements](../validation/derivative-products.md) include
the shared dense family through 32 variables and a sparse comparison.
