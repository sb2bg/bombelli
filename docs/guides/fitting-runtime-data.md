# Fitting runtime data

Use `residualModel` when a fixed residual block repeats over observations that
arrive at runtime. Use `model` when the entire residual vector has a fixed
size.

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

Residuals conventionally use `prediction - observation`; reversing every
residual sign leaves an ordinary least-squares optimum unchanged.

## Observations and results

Each observation must be a struct with the declared `.data` fields. Fixed
arrays, pointers to fixed arrays, and slices are accepted. Extra fields are
ignored.

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
const rate = fit.parameter(result, .rate);
```

Parameters follow declared `.variables` order. Prefer `parameter(result,
name)` at call sites.

`result.converged()` recognizes gradient, cost, and step convergence.
`result.status` also distinguishes iteration or evaluation limits, invalid
data or trials, infeasible starts, line-search failure, and numerical failure.
The result includes cost, rank, norms, evaluation counts, damping, step counts,
and per-parameter bound activity. `max_function_evaluations` limits complete
passes over the observations; `observation_evaluations` counts visited rows.

## Losses, weights, bounds, and scaling

Available robust losses are `loss.linear()`, `loss.huber(scale)`,
`loss.softL1(scale)`, and `loss.cauchy(scale)`. Scales must be positive and
finite.

```zig
.loss = bombelli.loss.cauchy(0.25),
```

Represent observation weights in the residual itself:

```zig
const weighted = comptime bombelli.residualModel(.{
    "sqrt(weight) * (a*x + b - y)",
}, .{
    .variables = .{ .a, .b },
    .data = .{ .x, .y, .weight },
});
```

Bounds may be one-sided, two-sided, or fixed. `.initial_bounds = .project`
projects an infeasible initial point; the default is `.reject`. Automatic
Jacobian-column scaling is the default. User scaling accepts one positive
characteristic value per parameter:

```zig
.scaling = .user,
.scales = .{
    .amplitude = 100.0,
    .rate = 0.001,
    .offset = 10.0,
},
```

## Row kernels and standalone emission

The residual model exposes its fused row value and Jacobian independently:

```zig
const row = comptime bombelli.residualModel(.{
    "a*x + b - y",
}, .{
    .variables = .{ .a, .b },
    .data = .{ .x, .y },
});
const linearized = row.valueAndJacobian(.{
    .a = 2.0, .b = 1.0, .x = 3.0, .y = 6.5,
});
```

A compiled fitter can emit a standalone allocation-free Zig or C99 callable:

```zig
const source = comptime fit.emit(.{
    .target = .c,
    .name = "fit_decay",
});
```

The generated code contains the residual, symbolic Jacobian, and compile
options. C exposes named initial, observation, input, and result structs.
Runtime-observation fitting currently uses `f64`; `.scalar = .f32` is rejected
at compile time.

At runtime, robustly weighted rows are folded into an upper-triangular QR
factor. The full observation-by-parameter Jacobian is never stored, so working
storage remains `O(parameters²)`.
