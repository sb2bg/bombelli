# Checking a Jacobian Conjecture Counterexample with Bombelli

In 2026, a three-variable polynomial map supplied a counterexample to the
Jacobian conjecture over the reals. It has an everywhere nonzero constant
Jacobian determinant but is not injective.

Bombelli can check both statements directly at compile time.

## Build the map and its Jacobian

```zig
const map = bombelli.exprVector(.{
    "(1 + x*y)^3*z + y^2*(1 + x*y)*(4 + 3*x*y)",
    "y + 3*x*(1 + x*y)^2*z + 3*x*y^2*(4 + 3*x*y)",
    "2*x - 3*x^2*y - x^3*z",
});

const determinant = map
    .jacobian(.{ .x, .y, .z })
    .determinant()
    .simplify();

comptime {
    if (!std.mem.eql(u8, determinant.render(), "-2")) {
        @compileError("the Jacobian determinant is not exactly -2");
    }
}
```

`exprVector` stores the three coordinate polynomials in one shared DAG.
`jacobian` differentiates every coordinate, and `determinant` uses exact
fraction-free elimination over polynomial entries. The result is the exact
integer `-2`, not a numerical sample.

## Check non-injectivity

The following three distinct points have the same image:

```zig
const points = [_]Point{
    .{ .x = 0,  .y = 0,    .z = -1.0 / 4.0 },
    .{ .x = 1,  .y = -1.5, .z = 6.5 },
    .{ .x = -1, .y = 1.5,  .z = 6.5 },
};

for (points) |point| {
    const image = map.eval(point);
    // image is (-0.25, 0, 0)
}
```

Thus the map is locally invertible everywhere—its Jacobian never
vanishes—but not globally one-to-one. The complete executable check is
[examples/jacobian_counterexample.zig](../../examples/jacobian_counterexample.zig).

This example exercises shared multi-output construction, symbolic
differentiation, exact polynomial conversion, fraction-free determinants,
simplification, and runtime evaluation in one short program.
