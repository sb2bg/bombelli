# Bombelli

> A compile-time symbolic mathematics library for Zig.

Write the expression you mean. Bombelli parses, transforms, and simplifies it
at compile time, then leaves only the arithmetic your program needs at runtime.

```zig
const bombelli = @import("bombelli");

const response_gradient = bombelli
    .expr("ln(1 + x^2 * y^2) + exp(sin(x * y))")
    .diff(.x)
    .simplify();

pub fn responseGradient(x: f64, y: f64) f64 {
    return response_gradient.eval(.{ .x = x, .y = y });
}
```

Bombelli renders the derivative as:

```text
2 * x * y^2 / (1 + x^2 * y^2) + y * cos(x * y) * exp(sin(x * y))
```

No runtime parser, allocator, symbolic tree walk, or virtual machine is involved.
The evaluator specializes to the operations in that transformed expression.

## API

Expressions can be transformed in a single compile-time chain:

```zig
const derivative = comptime bombelli
    .expr("sin(x * y) + x^3")
    .diff(.x)
    .simplify();

const source = comptime derivative.render();
const value = derivative.eval(.{ .x = 2.0, .y = 3.0 });
```

File-scope constants are already evaluated at compile time, so the explicit
`comptime` keyword is only needed when building expressions in function scope.
`diff` accepts Zig enum-literal syntax, and `eval` accepts a struct whose fields
provide the expression's symbols.

## Expressions

Bombelli currently supports:

- Integer and floating-point literals
- Symbols with Zig identifier syntax
- Parentheses and unary negation
- Addition, subtraction, multiplication, and division
- Non-negative integer powers
- `sin`, `cos`, `exp`, and `ln`
- Symbolic differentiation and deterministic simplification
- Compile-time rendering and allocation-free `f64` evaluation

Power binds more tightly than unary negation, so `-x^2` means `-(x^2)`.
Invalid syntax and missing evaluation fields produce compile errors with focused
diagnostics.

## Direction

Bombelli is growing into a complete, practical mathematics library for Zig. The
long-term goal is one coherent system spanning symbolic algebra, calculus,
linear algebra, exact and approximate arithmetic, complex mathematics,
equations and solvers, transforms and series, probability and statistics,
discrete mathematics, and efficient numerical evaluation.

That breadth will grow around the same core idea: mathematical code should be
clear at the call site and should compile into straightforward machine code.

## Design

A hand-written lexer and recursive-descent parser build an immutable,
node-indexed DAG. Every node goes through a hash-consing builder, so repeated
subexpressions share one `NodeId`. Differentiation and simplification memoize
their recursive work, then retain only the reachable nodes in an exactly sized
result.

Because `eval` takes the expression as a compile-time receiver, Zig resolves
the recursive symbolic dispatch while compiling. The temporary construction
workspace has a guarded limit; the stored expression does not carry that
capacity and grows only with its unique, reachable nodes.

## Writing

- [Building a Symbolic Differentiator That Compiles Away Completely in Zig](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Disproving the Jacobian Conjecture with Bombelli](docs/blog/disproving-the-jacobian-conjecture-with-bombelli.md)
- [Expression-growth baseline](docs/architecture/stress-baseline.md)

## Commands

```sh
zig build test
zig build run
zig build stress
```

Bombelli uses only Zig's standard library and targets Zig 0.16.0.
