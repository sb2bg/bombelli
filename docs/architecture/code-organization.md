# Code organization

`src/root.zig` is the public package façade. Expression program types and
their fluent methods live in `src/expression.zig`; typed variable/data
contracts live in `src/model.zig` and `src/residual_model.zig`.

Implementation modules are grouped by capability:

- `internal/core`: DAG construction, invariants, limits, exact arithmetic,
  domains, and shared option validation
- `internal/parse` and `internal/transform`: parsing, diagnostics, graph
  transforms, and multi-output operations
- `internal/algebra`, `internal/solve`, and `internal/integrate`: symbolic
  algorithms
- `internal/model` and `internal/optimize`: fused model programs and nonlinear
  least squares
- `internal/runtime`: specialized evaluation
- `internal/codegen`: rendering plus standalone Zig and C emission

Language backends share target-neutral DAG, binding, literal, and option
logic. Each backend owns only its syntax and public calling convention.

## Dependency rule

Internal modules do not import `root.zig`. Features depend on
`expression.zig` and lower-level neutral modules. Fluent methods in
`expression.zig` use function-local imports to dispatch into features without
making the façade an implementation hub.

Cross-feature identifiers belong in neutral modules; one feature should not
import another solely to reuse a type name.

## Validation

Tests are grouped by capability under `tests/` and collected by
`tests/root.zig`. Files in `tests/compile_fail` declare their expected
diagnostic on the first line and are discovered automatically:

```zig
// expect-error: error: expected diagnostic substring
```

`zig build check` runs formatting, examples, unit/property/stress/hardening
and compile-fail tests, SymPy differential checks, standalone Zig/C emission,
and API documentation generation.
