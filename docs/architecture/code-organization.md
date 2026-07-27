# Code organization

Bombelli follows the same broad shape used by mature Zig packages: one small
public façade, capability-oriented implementation directories, and a separate
test root that imports behavior suites by category.

## Public surface

`src/root.zig` is the package façade. It owns public names and documentation,
but not implementations or behavior tests. `src/expression.zig` defines the
three immutable expression program types and their fluent methods.

The `bombelli.testing` namespace is explicitly unstable. It exposes only the
small set of internals needed by package, downstream, and benchmark tests
without making those details part of the stable top-level API.

## Internal capabilities

- `internal/core`: DAG construction, traversal, invariants, limits, exact
  arithmetic, domains, and shared option validation.
- `internal/parse`: lexing, parsing, and parse diagnostics.
- `internal/transform`: differentiation, simplification, substitution,
  composition, dependency checks, and multi-output DAG operations.
- `internal/algebra`: exact polynomial and rational-function representations.
- `internal/solve`: equations, systems, symbolic elimination, polynomial
  solving, Newton compilation, and solution types.
- `internal/integrate`: symbolic, fixed, adaptive, and hybrid integration.
- `internal/runtime`: specialized runtime evaluation.
- `internal/codegen`: human-readable rendering and standalone source emission.

`codegen/emit.zig` owns `EmitTarget` and `EmitMode`, validates the
target-independent options, and dispatches to one backend per language.
Each backend is split again by generated artifact, so `zig/expression.zig`,
`zig/quadrature.zig`, and `zig/newton.zig` use the private primitives in
`zig/support.zig`, and the `c/` directory mirrors that shape. Backends share
only `codegen/scalar.zig`: a backend renders its own language and never reads
another's spellings.

The two targets differ in how a caller supplies inputs. Zig emission takes
`inputs: anytype` and reads fields from it; C has no such type, so C emission
declares a `<name>_inputs` struct alongside the function. Fields are
alphabetical, which keeps the struct stable under unrelated edits to the
expression, and named fields cannot be silently transposed the way positional
`double` parameters can.

## Dependency rule

Internal modules never import `root.zig`. Most dependencies point from a
feature toward `expression.zig` and lower-level core modules. The deliberate
exception is the fluent method table in `expression.zig`: those methods use
lazy function-local imports to dispatch into features. Keeping this single
documented back-edge preserves `expr.diff(...).simplify()` without turning the
package façade into an implementation hub.

Shared identifiers and data that cross feature boundaries belong in neutral
modules such as `solve/algorithm.zig` and `integrate/types.zig`. Feature
implementations should not import one another merely to name such a type.

## Tests and validation

Behavior tests live under `tests/` by capability and are collected by
`tests/root.zig`. Every negative compile test in `tests/compile_fail` carries
its expected diagnostic in the first line:

```zig
// expect-error: error: expected diagnostic substring
```

The build discovers these files automatically, so adding a negative test never
requires editing a central registry. `zig build check` is the complete local
validation path; it runs formatting, unit/property/stress/hardening and
compile-fail tests, SymPy differential checks, emitted-source validation, and
API documentation generation.
