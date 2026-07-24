# Bombelli

> A compile-time symbolic mathematics library for Zig.

Bombelli is a pilot, not a complete computer algebra system. It demonstrates a
Zig-native API in which parsing, differentiation, and simplification happen at
compile time, while evaluation specializes to direct arithmetic with no
allocation, runtime parsing, or runtime symbolic data traversal.

```zig
const std = @import("std");
const bombelli = @import("bombelli");

const f = bombelli.expr("sin(x * y) + x^3");
const derivative = f.diff(.x);
const dx = derivative.simplify();

test "symbolic derivative" {
    const source = comptime dx.render();
    try std.testing.expectEqualStrings(
        "y * cos(x * y) + 3 * x^2",
        source,
    );

    const result = dx.eval(.{ .x = 2.0, .y = 3.0 });
    const expected = 3.0 * @cos(6.0) + 12.0;
    try std.testing.expectApproxEqAbs(expected, result, 1e-12);
}
```

File-scope constants are already evaluated at compile time, so Zig 0.16 rejects
an explicit `comptime` there as redundant. In function scope, the operations can
be chained with an explicit `comptime`:

```zig
test {
    const dx = comptime bombelli
        .expr("sin(x * y) + x^3")
        .diff(.x)
        .simplify();
    _ = dx;
}
```

## Supported syntax

The pilot supports integer and floating-point literals, identifier symbols,
parentheses, unary negation, `+`, `-`, `*`, `/`, non-negative integer powers,
and the functions `sin`, `cos`, `exp`, and `ln`. Power binds more tightly than
unary negation, so `-x^2` means `-(x^2)`.

`eval` accepts a struct whose field names match the expression's symbols.
Integer and floating-point field values are converted to `f64`. Missing or
non-numeric fields produce compile-time diagnostics.

## Implementation

The hand-written lexer and recursive-descent parser build an immutable,
fixed-capacity AST represented by node indices. Differentiation and
simplification rebuild that AST at compile time. `eval` requires its expression
receiver at compile time, so recursive AST dispatch is resolved during
specialization and only the resulting arithmetic remains at runtime.

The fixed node capacity is deliberately simple and auditable for the pilot. It
is not suitable for large expressions or advanced algebraic transformations.

## Commands

```sh
zig build test
zig build run
```

Bombelli uses only Zig's standard library and targets Zig 0.16.0.
