# Bombelli

[![CI](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml/badge.svg)](https://github.com/sb2bg/bombelli/actions/workflows/ci.yml)

Bombelli is a statically shaped differentiable model compiler for Zig. It
parses, transforms, and differentiates mathematical programs at compile time,
then leaves allocation-free numerical code for runtime evaluation, fitting,
solving, batching, or standalone Zig/C emission.

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

The derivative simplifies to `3 * x^2 + y * cos(x * y)` during compilation.
Runtime code contains no parser, allocator, graph traversal, virtual machine,
or dynamic dispatch. Bombelli targets Zig 0.16.0 and uses only the standard
library.

## Runtime-data fitting

`residualModel` keeps the model and parameter count static while accepting a
runtime observation slice:

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
});

const result = fit.eval(.{
    .initial = .{ .amplitude = 2.0, .rate = 0.5, .offset = 0.0 },
    .observations = observations,
});
const rate = fit.parameter(result, .rate);
```

The row-wise Levenberg–Marquardt solver supports robust losses, bounds,
scaling, evaluation budgets, and explicit terminal diagnostics. It folds each
observation into a QR factor, so working storage is `O(parameters²)` rather
than `O(observations × parameters)`. See the
[runtime-data fitting guide](docs/guides/fitting-runtime-data.md).

## Capabilities

| Declaration | Compile-time work | Runtime product |
| --- | --- | --- |
| `expr`, `exprVector`, `exprMatrix` | simplify, substitute, differentiate, integrate | scalar, vector, matrix, and batch evaluators |
| `model` | Jacobian, Hessian, fused linearization | values, JVP, VJP, fixed-size least squares |
| `residualModel` | symbolic row kernel and Jacobian | fitting over runtime observations |
| `system`, `equationProblem` | exact elimination or symbolic Jacobian | Newton solvers and implicit sensitivities |
| native fixed-size arrays | shape and type checking | LU, Cholesky, pivoted QR, solve, inverse |

Expressions support exact integer and rational construction, real and complex
evaluation, shared multi-output DAGs, symbolic polynomial and rational
algebra, exact linear solving, symbolic-plus-numerical integration, and
caller-owned sequential or parallel batch output.

Compiled expressions, models, solvers, quadrature rules, and fitters can emit
standalone allocation-free Zig or C99:

```zig
const source = comptime derivative.emit(.{
    .target = .c,
    .name = "evaluate_derivative",
});
```

Generated C uses named input structs; `.scalar = .f32` selects single
precision where supported. Emission tests compile and run every generated Zig
and C kernel independently of Bombelli. Current compile, size, and runtime
measurements are recorded in the
[validation baseline](docs/validation/release-baseline.md).

## Install

```sh
zig fetch --save git+https://github.com/sb2bg/bombelli
```

Add the dependency to your executable in `build.zig`:

```zig
const bombelli = b.dependency("bombelli", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("bombelli", bombelli.module("bombelli"));
```

Useful repository commands:

```sh
zig build test          # unit, property, stress, and compile-fail tests
zig build check         # full validation, including SymPy and emission
zig build examples      # compile every example
zig build run           # run the flagship example
```

`zig build check` requires Python 3 with SymPy 1.12.

## Examples and notes

- [Flagship symbolic workflows](examples/flagship.zig)
- [Runtime curve fitting](examples/curve_fit.zig)
- [Exact Jacobian counterexample check](examples/jacobian_counterexample.zig)
- [Code organization](docs/architecture/code-organization.md)
- [Expression-growth baseline](docs/architecture/stress-baseline.md)
- [How the compile-time differentiator works](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Checking the Jacobian counterexample](docs/blog/checking-the-jacobian-conjecture-counterexample-with-bombelli.md)
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE)
