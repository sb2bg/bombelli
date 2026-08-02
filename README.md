# Bombelli

[![CI](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml/badge.svg)](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml)

> A statically shaped differentiable model compiler for Zig. Declare the
> mathematics once at compile time; evaluate, differentiate, fit runtime data,
> solve, batch, and emit standalone allocation-free Zig or C.

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
exists. The same declared program can become a scalar evaluator, shared
Jacobian, nonlinear fitter, solver, batch kernel, or source file. At runtime
there is no parser, allocator, symbolic graph walk, virtual machine, function
pointer, or dynamic dispatch. Zig specializes the compact DAG into ordinary
numerical operations.

## Fit runtime data with a compile-time model

The model shape is static; the number of observations is not. This is the
usual curve-fitting shape: a handful of parameters and a runtime slice that
may contain ten rows or ten million.

```zig
const Observation = struct { time: f64, response: f64 };

const fit = comptime bombelli.residualModel(.{
    "offset + amplitude*exp(-rate*time) - response",
}, .{
    .variables = .{ .amplitude, .rate, .offset },
    .data = .{ .time, .response },
}).leastSquares().compile(.{
    .bounds = .{
        .amplitude = .{ .lower = 0.0 },
        .rate = .{ .lower = 0.0 },
    },
    .tolerance = 1e-11,
});

pub fn fitRate(observations: []const Observation) f64 {
    const result = fit.eval(.{
        .initial = .{
            .amplitude = 2.0,
            .rate = 0.5,
            .offset = 0.0,
        },
        .observations = observations,
    });
    return fit.parameter(result, .rate);
}
```

Bombelli differentiates the one-row residual symbolically and fuses its value
and Jacobian. During fitting, each runtime row is folded immediately into a
Givens QR factor. Storage is `O(parameters²)`, independent of observation
count, with no allocator and no materialized observation-by-parameter
Jacobian. The compiled Levenberg–Marquardt solver supports automatic or user
scaling, box bounds, linear/Huber/soft-L1/Cauchy losses, rank diagnostics,
hard evaluation budgets, and explicit terminal statuses.

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

Ask for `.target = .c` instead and the same object becomes a standalone C99
translation unit that depends only on the C standard library:

```c
typedef struct evaluate_derivative_inputs {
    double x;
    double y;
} evaluate_derivative_inputs;

void evaluate_derivative(const evaluate_derivative_inputs *inputs, double *output) {
    const double n0 = (double)(3LL);
    const double n1 = inputs->x;
    const double n2 = bombelli_rational_power_f64(n1, 2LL, 1ULL);
    const double n3 = n0 * n2;
    const double n4 = inputs->y;
    const double n5 = n1 * n4;
    const double n6 = cos(n5);
    const double n7 = n4 * n6;
    const double n8 = n3 + n7;
    *output = n8;
}
```

C has no `anytype`, so inputs arrive in a generated struct rather than as
positional parameters: a caller cannot transpose `x` and `y` the way
`evaluate_derivative(y, x)` would let them. `.scalar = .f32` switches both
targets to single precision, which in C also selects the `sinf`/`powf` family.
The test suite compiles the emitted C with `-std=c99 -Wall -Wextra -Werror`,
runs it, and compares it against Bombelli's own evaluator.

On a five-million-evaluation benchmark, a Bombelli-compiled expression took
0.9910× as long as equivalent handwritten Zig. Parity, as it should be,
because by runtime it _is_ handwritten-shaped code
([measurements](docs/validation/release-baseline.md)).

Bombelli targets Zig 0.16.0 and uses only Zig's standard library.

## One declaration, several useful kernels

| Declare | Compile-time products | Runtime products |
| --- | --- | --- |
| `expr` / `exprVector` | simplify, substitute, differentiate, integrate, emit | scalar, vector, matrix, and batch evaluation |
| `model` | Jacobian, Hessian, fused linearization | values, JVP, VJP, fixed-size least squares |
| `residualModel` | one symbolic residual-row kernel | robust bounded fitting over runtime observation slices |
| `system` | exact elimination or symbolic Jacobian | Newton solve and implicit sensitivities |
| native `[N]T` / `[R][C]T` arrays | fixed shape and type checking | LU, Cholesky, pivoted QR, solve, inverse, and matrix utilities |

Evaluation can keep intermediates in `f16`, `f32`, `f64`, `f80`, `f128`, or
Zig's standard `std.math.Complex(f32/f64)` with `evalAs`.
The expression language reserves exact symbolic constants `pi` and `i`; `i`
evaluates to the imaginary unit for a complex scalar and to `NaN` in a real
evaluation, like any other expression outside the real domain.
Structure-of-arrays batches remain real-valued and have sequential and
parallel caller-owned APIs. Supported elementary functions include
trigonometric, inverse trigonometric, hyperbolic, exponential, logarithmic,
`abs`, `sqrt`, `atan2`, and overflow-safe `hypot`; `atan2` and `hypot` are
real-only.

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
const x = solver.value(result, .x);
const y = solver.value(result, .y);
// result.status, result.iterations, result.residual_norm
```

For difficult initial points, opt into a sufficient-decrease backtracking
line search:

```zig
const robust_solver = comptime problem.compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
    .globalization = .backtracking,
    .max_backtracks = 16,
});
```

Undamped `.globalization = .none` remains the default. Backtracking defaults
to `.backtrack_factor = 0.5` and `.armijo_constant = 1e-4`.
`.step_tolerance` defaults to `.tolerance` and detects a step too small
relative to the current solution scale. Results distinguish `converged`,
`singular_jacobian`, `non_converged`, `non_finite`, `stagnated`, and
`line_search_failed`, and report `step_scale`, `function_evaluations`, and
`backtracks`. Standalone Newton source emission currently requires the
undamped default.

The same API compiles holomorphic systems over the complex domain. Solver
values, residuals, Jacobians, steps, parameters, and sensitivities then use
Zig's standard `std.math.Complex(f64)`; convergence norms and tolerances stay
`f64`:

```zig
const std = @import("std");
const Complex = std.math.Complex(f64);

const euler_zero = comptime bombelli
    .expr("exp(i*pi) + 1")
    .evalAs(Complex, .{});

const complex_solver = comptime bombelli
    .equationProblem("z^2 + 1 = 0", .{
        .unknowns = .{.z},
        .domain = .complex,
    })
    .compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 32,
        .tolerance = 1e-12,
    });

const complex_result = complex_solver.eval(.{
    .initial = .{ .z = Complex.init(0.5, 0.5) },
});
const z = complex_solver.value(complex_result, .z);
// z is approximately 0 + 1i
```

Complex Newton currently accepts holomorphic expression programs. `abs`,
`atan2`, and `hypot` residuals are rejected at compile time. Nonlinear least
squares, batch evaluation, quadrature, and standalone source emission remain
real-only. Exact quadratic solving retains complex radical branches; evaluate
those expression branches with `evalAs(std.math.Complex(f64), inputs)`.

Then differentiate the _solver itself_ with respect to a parameter. Bombelli
derives the implicit sensitivities `dx/dr` and `dy/dr` from the symbolic
Jacobian, with a nonsingularity check:

```zig
const sensitivity = comptime solver.diff(.r);

const ds = sensitivity.eval(.{
    .initial = .{ .x = 1.0, .y = 1.0 },
    .r = 2.0,
});
const dx_dr = sensitivity.sensitivity(ds, .x);
const dy_dr = sensitivity.sensitivity(ds, .y);
```

Real, undamped solvers can also be emitted as standalone Zig or C. The full
pipeline (strings in, inspectable allocation-free kernel out) is the point.

## More workflows

**Typed differentiable models.** Variables are declared explicitly, so every
downstream Jacobian column, tangent, fit parameter, and diagnostic has one
stable order. Other symbols are ordinary inputs:

```zig
const response = comptime bombelli.model(.{
    "scale*sin(x*y)",
    "scale*(x^2 + y^2)",
}, .{
    .variables = .{ .x, .y },
    .inputs = .{.scale},
});

const linearized = response.valueAndJacobian(.{
    .x = 0.5,
    .y = 2.0,
    .scale = 3.0,
});

const checked = bombelli.testing.checkJacobian(response, .{
    .x = 0.5,
    .y = 2.0,
    .scale = 3.0,
}, .{});
// checked.entries identifies any mismatched row, column, and variable
```

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

**Fixed-size linear algebra without a container type.** Numerical routines
accept and return ordinary native Zig arrays:

```zig
const matrix = [3][3]f64{
    .{ 0, 2, 1 },
    .{ 1, -2, -3 },
    .{ 4, -7, 1 },
};
const factor = bombelli.linalg.lu(matrix, .{});
const solution = factor.solve(.{ 3, 0, 2 }).?;
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

See [examples/curve_fit.zig](examples/curve_fit.zig) for the runtime-data
fitting workflow, [examples/flagship.zig](examples/flagship.zig) for the
symbolic release workflows in one executable, and
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
- parameter and output dimensions are small and fixed, even when the runtime
  dataset is large;
- runtime allocation or symbolic overhead is unacceptable;
- generated numerical code must be inspectable and auditable;
- exact rational coefficients matter during construction;
- a compile-time failure beats a runtime surprise.

Think curve fitting and calibration, regressions with custom symbolic
residuals, embedded control laws, fixed physical models, generated Jacobians
for simulation and estimation, specialized quadrature, and small
high-confidence numerical kernels. If the model structure itself must change
at runtime, or you need arbitrary-precision arithmetic, non-holomorphic
complex optimization, or open-ended equation solving, use a runtime numerical
framework or CAS, possibly to derive the model you then hand to Bombelli.

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

## More

- [Changelog and release history](CHANGELOG.md)
- [Fitting runtime data](docs/guides/fitting-runtime-data.md)
- [Expression-growth and construction baseline](docs/architecture/stress-baseline.md)
- [Building a Symbolic Differentiator That Compiles Away Completely in Zig](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Checking the Jacobian Conjecture Counterexample with Bombelli](docs/blog/checking-the-jacobian-conjecture-counterexample-with-bombelli.md)

## License

[MIT](LICENSE)
