# Bombelli

[![CI](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml/badge.svg)](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml)

> A compile-time symbolic mathematics compiler for Zig. Write formulas as
> strings, differentiate, simplify, solve, and integrate them during
> compilation, and ship straight-line numerical code with zero runtime
> symbolic machinery.

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

Bombelli parses the string, applies the chain and product rules, and
simplifies the result to `3 * x^2 + y * cos(x * y)` all before your program
exists. At runtime there is no parser, allocator, symbolic graph walk,
node-kind switch, virtual machine, function pointer, or dynamic dispatch.
Zig specializes the compact DAG into ordinary numerical operations.

You don't have to take that on faith. Ask the same object to `emit()` and
read the code yourself:

```zig
const source = comptime derivative.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "evaluate_derivative",
});
```

The emitted evaluator is standalone Zig. It does not import Bombelli:

```zig
pub fn evaluate_derivative(inputs: anytype, output: *f64) void {
    const n0: f64 = @as(f64, @floatFromInt(@as(i64, 3)));
    const n1: f64 = bombelliNumber(inputs.x);
    const n2: f64 = bombelliRationalPower(n1, 2, 1);
    const n3: f64 = n0 * n2;
    const n4: f64 = bombelliNumber(inputs.y);
    const n5: f64 = n1 * n4;
    const n6: f64 = @cos(n5);
    const n7: f64 = n4 * n6;
    const n8: f64 = n3 + n7;
    output.* = n8;
}
```

(`bombelliNumber` and `bombelliRationalPower` are small inline helpers emitted
into the same file)

On a five-million-evaluation benchmark, a Bombelli-compiled expression ran at
0.9991× the speed of equivalent handwritten Zig. Parity, as it should be,
because by runtime it _is_ handwritten-shaped code
([measurements](docs/validation/release-baseline.md)).

Bombelli v0.1.0 targets Zig 0.16.0 and uses only Zig's standard library.

## From equations to a compiled solver

The workflows compose. Declare a nonlinear system as mathematical strings,
and Bombelli differentiates it symbolically, builds the exact Jacobian, and
compiles a fixed-size Newton solver, with no allocation and explicit status
reporting:

```zig
const problem = comptime bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});

const solver = comptime problem.compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
});

const result = solver.eval(.{
    .initial = .{ .x = 1.0, .y = 1.0 },
    .r = 2.0,
});
// result.values, result.status, result.iterations
```

Then differentiate the _solver itself_ with respect to a parameter. Bombelli
derives the implicit sensitivities `dx/dr` and `dy/dr` from the symbolic
Jacobian, with a nonsingularity check:

```zig
const sensitivity = comptime solver.diff(.r);

const ds = sensitivity.eval(.{
    .initial = .{ .x = 1.0, .y = 1.0 },
    .r = 2.0,
});
// ds.sensitivities = { dx/dr, dy/dr }
```

Both the solver and its sensitivities can be emitted as standalone Zig. The
full pipeline (strings in, inspectable allocation-free kernel out) is the
point.

## More workflows

**Shared multi-output programs.** One node store serves a gradient, Jacobian,
Hessian, or any typed multi-output program. Shared subexpressions such as
`sin(x*y)` are stored and evaluated once across outputs, and `evalInto`
writes into caller-provided fixed-size storage:

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

**Exact symbolic linear systems.** Solutions retain parameter conditions
instead of silently dividing by a pivot that might be zero:

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

**Integration that degrades gracefully.** A partial result preserves both the
closed portion and an `IntegralProblem` remainder, which compiles directly
into a symbolic-plus-quadrature hybrid:

```zig
const symbolic = comptime bombelli
    .expr("3*x^2 + exp(x^2)")
    .integrate(.{
        .variable = .x,
        .domain = .real,
    });
// x^3 integrates in closed form; exp(x^2) is kept as an explicit remainder

const compiled = comptime symbolic.compile(.{
    .rule = .gauss_legendre,
    .order = 16,
});

const value = compiled.eval(.{ .from = 0.0, .to = 1.0 });
```

See [examples/flagship.zig](examples/flagship.zig) for the release workflows
in one executable, and
[examples/jacobian_counterexample.zig](examples/jacobian_counterexample.zig)
for Bombelli checking the 2026 Jacobian conjecture counterexample at compile
time.

## Where Bombelli fits

Bombelli is not a general-purpose CAS, and it is not trying to compete with
Mathematica or SymPy on breadth. It is a bounded symbolic compiler: the
mathematics is known at compile time, the symbolic work disappears during
compilation, and what remains is a small, transparent numerical kernel.

That trade is a good fit when:

- the mathematical model is fixed at build time;
- runtime allocation or symbolic overhead is unacceptable;
- generated numerical code must be inspectable and auditable;
- exact rational coefficients matter during construction;
- dimensions are small and fixed;
- a compile-time failure beats a runtime surprise.

Think embedded control laws, fixed physical models, calibration routines,
generated Jacobians for simulation and estimation, specialized quadrature,
and tiny high-confidence numerical kernels. If you need arbitrary-precision
arithmetic, complex analysis, or open-ended equation solving at runtime, use
a CAS, possibly to derive the model you then hand to Bombelli.

## Getting started

```sh
zig fetch --save git+https://github.com/sb2bg/bombelli
```

Then in `build.zig`:

```zig
const bombelli = b.dependency("bombelli", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("bombelli", bombelli.module("bombelli"));
```

Forwarding `target` and `optimize` matters: without them the module resolves
for the host, which breaks cross-compilation.

Run the flagship example from a checkout with `zig build run`.

## Scope and limits

v0.1.0 is deliberately bounded: the real domain only, checked fixed-width
exact rationals (overflow is a precise compile error, not a wrap), symbolic
integration as a terminating subset that reports `unsupported` rather than
guessing, polynomial equation solving to degree two, and a guarded
1,024-node construction workspace (the largest release stress case peaks at
368). Simplification never erases singularities through unconditional
cancellation such as `x/x -> 1`, and assumptions like `nonzero(.a)` are
operation-local; symbols never acquire global attributes that silently alter
later behavior.

The full list of what ships and where it stops is in the
[changelog](CHANGELOG.md).

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

The implementation layout and dependency rules are documented in
[docs/architecture/code-organization.md](docs/architecture/code-organization.md).
Run `zig build check` for the complete formatting, test, differential,
standalone-emission, and documentation validation path.

## Validation

The release candidate passes:

- Core, compile-fail, property, and dangerous-case hardening suites
- Stress tests, including the original twenty-factor derivative
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

- [Changelog and v0.1.0 scope](CHANGELOG.md)
- [Expression-growth and construction baseline](docs/architecture/stress-baseline.md)
- [Building a Symbolic Differentiator That Compiles Away Completely in Zig](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Checking the Jacobian Conjecture Counterexample with Bombelli](docs/blog/checking-the-jacobian-conjecture-counterexample-with-bombelli.md)

## License

[MIT](LICENSE)
