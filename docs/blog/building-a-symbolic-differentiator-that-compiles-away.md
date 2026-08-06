# Building a Symbolic Differentiator That Compiles Away in Zig

Bombelli treats a mathematical expression as compile-time program data:

```zig
const derivative = comptime bombelli
    .expr("sin(x*y) + x^3")
    .diff(.x)
    .simplify();

pub fn evaluate(x: f64, y: f64) f64 {
    return derivative.eval(.{ .x = x, .y = y });
}
```

Parsing, differentiation, and simplification finish while Zig compiles the
program. The runtime function contains ordinary arithmetic and library math
calls.

## The representation

An expression is an immutable root into a canonical node array. Nodes cover
constants, variables, n-ary sums and products, tagged unary functions, powers,
and the few genuinely binary functions such as `atan2` and `hypot`.

The builder interns structurally equal nodes. Multi-output expressions share
one node store, so a repeated subexpression can be constructed and evaluated
once across a gradient or Jacobian. This also gives every transform the same
input and output shape: walk a DAG, memoize each old node, and intern the
replacement.

## Differentiation

The differentiator applies local rules while rebuilding the graph. For
example:

```text
d(a + b) = da + db
d(a * b) = da*b + a*db
d(sin(a)) = cos(a)*da
d(a^n) = n*a^(n-1)*da
```

N-ary addition and multiplication avoid arbitrary binary-tree shape. Unary
operators share traversal and dispatch code while retaining distinct
derivative rules. Node memoization prevents repeated differentiation of a
shared child.

The raw derivative then passes through exact simplification. Integer and
rational arithmetic remains exact during construction; like terms and powers
are combined before a runtime scalar type is chosen.

For `sin(x*y) + x^3`, differentiating by `x` yields:

```text
3 * x^2 + y * cos(x * y)
```

## The runtime boundary

`eval`, `evalAs`, and `evalInto` specialize the final DAG for a concrete input
shape and scalar. Zig can inline the fixed traversal and remove compile-time
structure. Source emission takes the other route: it serializes the same DAG
as a standalone Zig or C99 translation unit.

The important boundary is static shape. Expression structure, variables, and
output dimensions are compile-time facts; numerical inputs and observation
rows remain runtime data. This supports small fixed mathematical programs
without carrying a symbolic engine into the deployed binary.

The implementation is exercised at three levels: mathematical unit and
property tests, differential checks against SymPy, and standalone emission
tests that compile and run generated Zig and C without importing Bombelli.
