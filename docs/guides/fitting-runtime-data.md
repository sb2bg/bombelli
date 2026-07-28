# Fitting runtime data

`residualModel` is for the common nonlinear-regression shape where the
parameter count and residual formula are known at build time, but observations
arrive at runtime.

Use `model` when the complete residual vector is fixed-size. Use
`residualModel` when one fixed residual block repeats over an array or slice:

```zig
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
```

The residual convention is `prediction - observation`; changing every sign
does not change an ordinary least-squares optimum.

## Data contract

Every observation must be a struct with the declared `.data` fields. The
collection may be a fixed array, pointer to a fixed array, or slice. Additional
observation metadata is ignored:

```zig
const Observation = struct {
    time: f64,
    response: f64,
    sensor_id: u16,
};

const result = fit.eval(.{
    .initial = .{
        .amplitude = 2.0,
        .rate = 0.5,
        .offset = 0.0,
    },
    .observations = observations[0..],
});
```

Parameters are stored in declared `.variables` order. Prefer the named
accessor at call sites:

```zig
const rate = fit.parameter(result, .rate);
```

The residual kernel can also be inspected independently:

```zig
const row = comptime bombelli.residualModel(.{
    "a*x + b - y",
}, .{
    .variables = .{ .a, .b },
    .data = .{ .x, .y },
});

const linearized = row.valueAndJacobian(.{
    .a = 2.0,
    .b = 1.0,
    .x = 3.0,
    .y = 6.5,
});
// linearized.values == .{0.5}
// linearized.jacobian == .{.{ 3.0, 1.0 }}
```

## Robust losses, weights, bounds, and scaling

Robust losses reduce the influence of outliers:

```zig
const robust = comptime row.leastSquares().compile(.{
    .loss = bombelli.loss.cauchy(0.25),
});
```

Available typed constructors are `loss.linear()`, `loss.huber(scale)`,
`loss.softL1(scale)`, and `loss.cauchy(scale)`. The scale is expressed in
residual units and must be positive and finite.

Observation weights stay explicit in the mathematical model. Declare a data
field and multiply the residual by its square root:

```zig
const weighted = comptime bombelli.residualModel(.{
    "sqrt(weight) * (a*x + b - y)",
}, .{
    .variables = .{ .a, .b },
    .data = .{ .x, .y, .weight },
});
```

Bounds may be one-sided, two-sided, or fixed:

```zig
.bounds = .{
    .a = .{ .lower = 0.0 },
    .b = .{ .lower = -1.0, .upper = 1.0 },
},
.initial_bounds = .project, // default is .reject
```

Jacobian column scaling is automatic by default. If parameter magnitudes are
known, provide characteristic values:

```zig
.scaling = .user,
.scales = .{
    .amplitude = 100.0,
    .rate = 0.001,
    .offset = 10.0,
},
```

## Result and termination

`result.converged()` is true only for gradient, cost, or step convergence.
The full `status` distinguishes those cases from iteration/evaluation limits,
empty or non-finite data, infeasible starts, invalid trials, line-search
failure, and numerical failure.

Useful diagnostics include:

- `cost` and `initial_cost`;
- `observation_count` and total `residual_count`;
- function, Jacobian, and per-observation evaluation counts;
- accepted, rejected, projected-gradient, and invalid step counts;
- numerical `rank`, `gradient_norm`, `step_norm`, and `damping`;
- one bound-activity value per parameter.

`max_function_evaluations` is a hard upper bound. One function evaluation
means one complete pass over the observation collection; the separate
`observation_evaluations` counter exposes the actual number of visited rows.

## Numerical design

Bombelli differentiates and simplifies the residual block at compile time,
then fuses its values and Jacobian into one shared expression DAG. At runtime,
each robustly weighted Jacobian row is folded into an upper-triangular factor
with Givens rotations. The full Jacobian is never stored.

The Levenberg–Marquardt step is solved as an augmented QR problem after
parameter scaling, avoiding explicit normal equations. Damping follows the
gain-ratio update described by Madsen, Nielsen, and Tingleff. Box-constrained
trials are projected; when the damped step is unusable, an Armijo
projected-gradient fallback preserves progress.

This design combines ideas from:

- [MINPACK](https://netlib.org/minpack/), especially its storage-conserving
  `lmstr` path and row-wise QR update routine;
- [Methods for Non-Linear Least Squares Problems](https://www2.imm.dtu.dk/pubdb/pubs/3215-full.html)
  by Madsen, Nielsen, and Tingleff;
- [Ceres TinySolver](https://ceres-solver.googlesource.com/ceres-solver/+/master/include/ceres/tiny_solver.h),
  which targets small low-overhead problems with fixed dimensions;
- [SciPy `least_squares`](https://scipy.github.io/devdocs/reference/generated/scipy.optimize.least_squares.html),
  whose bounds, scaling, robust-loss, and distinct termination controls are a
  useful public-API benchmark.

The regression suite also fits the
[NIST Misra1a Statistical Reference Dataset](https://www.itl.nist.gov/div898/strd/nls/data/misra1a.shtml)
from both published starts and checks the certified parameters and residual
sum of squares.
