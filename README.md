# Bombelli

> Bombelli is a compile-time symbolic mathematics compiler for Zig. It
> differentiates, simplifies, solves, integrates, and generates
> allocation-free numerical code with no runtime symbolic machinery.

Write the mathematics at compile time:

```zig
const bombelli = @import("bombelli");

const derivative = comptime bombelli
    .expr("sin(x*y) + x^3")
    .diff(.x)
    .simplify();

pub fn evaluate(x: f64, y: f64) f64 {
    return derivative.eval(.{ .x = x, .y = y });
}
```

Bombelli renders the result as `3 * x^2 + y * cos(x * y)`. At runtime there is
no parser, allocator, symbolic graph walk, node-kind switch, virtual machine,
function pointer, or dynamic dispatch. Zig specializes the compact DAG into
ordinary numerical operations.

Bombelli v0.1.0 targets Zig 0.16.0 and uses only Zig's standard library.

## Flagship workflows

One shared node store can serve a gradient, Jacobian, Hessian, or any typed
multi-output program. Shared subexpressions are evaluated once, and
`evalInto` writes into caller-provided fixed-size storage:

```zig
const functions = comptime bombelli.exprVector(.{
    "sin(x*y) + x^2",
    "sin(x*y) + y^2",
});
const jacobian = comptime functions
    .jacobian(.{ .x, .y })
    .simplify();

var output: [2][2]f64 = undefined;
jacobian.evalInto(&output, .{ .x = 0.5, .y = 2.0 });
```

Exact symbolic linear systems retain parameter conditions instead of silently
dividing by a pivot that might be zero:

```zig
const problem = comptime bombelli.system(.{
    "a*x + b*y = e",
    "c*x + d*y = f",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});

const result = comptime problem.solve(.bareiss);
// result is conditional on a*d - b*c != 0
```

Symbolic integration is inspectable. A partial result preserves both the
closed portion and an `IntegralProblem` remainder, which can be compiled
directly into fixed quadrature:

```zig
const symbolic = comptime bombelli
    .expr("3*x^2 + exp(x^2)")
    .integrate(.{
        .variable = .x,
        .domain = .real,
    });

const compiled = comptime symbolic.compile(.{
    .rule = .gauss_legendre,
    .order = 16,
});

const value = compiled.eval(.{ .from = 0.0, .to = 1.0 });
```

Source emission is distinct from mathematical rendering:

```zig
const source = comptime derivative.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "evaluate_derivative",
});
```

The emitted evaluator is standalone Zig and does not import Bombelli. See
[examples/flagship.zig](examples/flagship.zig) for all five release workflows
in one executable.

## v0.1.0 scope

The release includes:

- Checked `i64` exact integers and canonical rationals with `u64`
  denominators
- Exact rational powers with explicit real-valued numerical behavior
- Canonical n-ary addition and multiplication without automatic expansion
- `sin`, `cos`, `tan`, `atan`, `abs`, `sqrt`, `exp`, and `ln`
- Memoized substitution, differentiation, gradients, Jacobians, and Hessians
- Sparse multivariate polynomials over exact rationals and explicit expansion
- Normalized rational functions that retain denominator conditions
- First-class equations, systems, and structured solution sets
- Exact rational RREF and fraction-free symbolic Bareiss solving
- Reusable square-system factorizations
- Linear and quadratic polynomial equation solving over the real domain
- Closed, partial, and unsupported symbolic integration results
- Fixed Gauss–Legendre rules of orders 4, 8, 16, and 32
- Allocation-free bounded adaptive quadrature with explicit status
- Symbolic-plus-quadrature compiled integrals
- Fixed-size Newton solvers with symbolic Jacobians and convergence metadata
- Implicit parameter sensitivities with nonsingularity checks
- Canonical/pretty rendering and standalone Zig source emission

`render()` is the canonical, re-parsable form. `renderMode(.pretty)` may use
presentation sugar such as `sqrt(x)`, while `renderMode(.canonical)` selects
the explicit canonical mode. Zig has no method overloading or default
arguments, so `renderMode` preserves the original zero-argument API.

## Deliberate limits

Bombelli keeps the v0.1.0 promise bounded and explicit:

- The only mathematical domain currently exposed is `.real`; Bombelli does
  not introduce complex branches.
- Exact arithmetic is fixed-width and checked. Overflow produces a precise
  compile-time diagnostic rather than wrapping or allocating a big integer.
- The construction workspace is guarded at 1,024 nodes. Finished DAG storage
  remains proportional to actual nodes and operand edges. The largest release
  stress case peaks at 368 nodes.
- Simplification preserves factored forms and does not erase singularities
  through unconditional cancellation such as `x/x -> 1`.
- Symbolic integration is a terminating subset: linearity, constant
  extraction, exact polynomials, the power rule, real `1/x`, affine
  sine/cosine/exponential forms, and decreasing-degree integration by parts.
  A heuristic stop is `unsupported`, never a claim of no elementary form.
- Exact Gaussian solving classifies constant rational systems. Symbolic
  Bareiss solving currently requires square systems and reports the
  determinant condition for its unique branch.
- Polynomial equation solving currently supports degree at most two with
  constant coefficients.
- Fixed quadrature supports only the four prevalidated orders above.
  Differentiating a rule differentiates the fixed approximation; it does not
  prove interchange of differentiation and mathematical integration.
- Adaptive quadrature is intentionally not differentiable because subdivision
  branches can change. `max_depth` is capped at 64.
- Newton compilation requires a square nonlinear system and a symbolic
  Jacobian. It reports singular, non-convergent, and non-finite outcomes.
- Source emission currently supports Zig and out-of-place callables only.

Assumptions are operation-local. Symbols never acquire global attributes that
silently alter later behavior:

```zig
const result = comptime bombelli.expr("exp(a*x + b)").integrate(.{
    .variable = .x,
    .domain = .real,
    .assumptions = .{bombelli.nonzero(.a)},
});
```

## Design

A hand-written lexer and recursive-descent parser build an immutable,
node-indexed DAG. Hash-consing gives structurally equal nodes one `NodeId`.
Transformations memoize DAG rebuilds, and finished programs retain only unique,
reachable, topologically ordered nodes in exactly sized storage.

Because each callable is a compile-time-specialized Zig type, runtime
evaluation becomes straight-line arithmetic plus only the bounded numerical
loops and explicit status branches appropriate to quadrature and solvers.
`metrics()` reports node count, operand edges, construction peak, and backing
bytes while also validating reachability, structural uniqueness, and
topological order.

## Validation

The release candidate passes:

- 76 core, compile-fail, property, and dangerous-case hardening tests
- 11 stress tests, including the original twenty-factor derivative
- 342 seeded programs/problems and 4,984 independent SymPy oracle assertions
- Standalone behavioral tests for emitted expression, quadrature, and Newton
  code, including forbidden-symbolic-machinery inspection

Run the complete validation surfaces with:

```sh
zig build test
zig build stress
zig build differential
zig build test-emission
```

`zig build differential` additionally requires Python 3 and SymPy. They are
validation dependencies only; Bombelli itself has no dependency beyond Zig's
standard library.

The measured compiler cost, 2×2–4×4 scaling, emitted sizes, and handwritten
runtime comparison are recorded in the
[v0.1.0 validation baseline](docs/validation/release-baseline.md). Reproduce
the scaling, size, and runtime measurements with:

```sh
python3 -B benchmarks/measure_release.py
```

## More

- [Expression-growth and construction baseline](docs/architecture/stress-baseline.md)
- [Building a Symbolic Differentiator That Compiles Away Completely in Zig](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Disproving the Jacobian Conjecture with Bombelli](docs/blog/disproving-the-jacobian-conjecture-with-bombelli.md)
