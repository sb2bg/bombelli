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
- Exact rational powers
- `sin`, `cos`, `tan`, `atan`, `abs`, `exp`, and `ln`
- Symbolic differentiation and deterministic simplification
- Compile-time rendering and allocation-free, DAG-aware `f64` evaluation

Power binds more tightly than unary negation, so `-x^2` means `-(x^2)`.
Invalid syntax and missing evaluation fields produce compile errors with focused
diagnostics.

## Fixed quadrature

Gauss–Legendre rules use literal, prevalidated tables for the supported orders
4, 8, 16, and 32:

```zig
const rule = comptime bombelli
    .expr("exp(-k*x^2)")
    .quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });

const value = rule.eval(.{
    .from = 0.0,
    .to = 1.0,
    .k = 2.0,
});
```

The runtime path contains only the selected fixed arithmetic and elementary
functions. `rule.diff(.k)` differentiates that fixed approximation exactly; it
does not, by itself, establish that the derivative equals the derivative of the
underlying mathematical integral. Runtime `from` and `to` inputs are treated as
independent endpoints, and differentiating with respect to either is rejected
until explicit Leibniz terms are requested.

For nonsmooth or sharply localized integrands, `adaptiveQuadrature` uses a
fixed-capacity depth-first stack whose size is selected by comptime
`max_depth`. Its result includes an error estimate, evaluation and interval
counts, and an explicit status. If the requested tolerance is not met before
the bound is reached, the status is `depth_exhausted`; Bombelli never presents
that estimate as converged.

An inspectable partial symbolic integral can be compiled with
`.compile(.{ .rule = .gauss_legendre, .order = 16 })`. The resulting callable
evaluates the closed portion directly and applies quadrature only to the
retained `IntegralProblem` remainder. Its `.diff(.parameter)` differentiates
that fixed split when the bounds are parameter-independent; otherwise it
requests explicit Leibniz boundary terms.

Square nonlinear systems can compile into bounded Newton callables with
symbolic residuals and a symbolic Jacobian generated at comptime. Runtime work
uses fixed-size vectors and matrices with partial pivoting. The numerical result
reports convergence, singular-Jacobian, non-convergence, or non-finite status
along with the final residual and iteration metadata.

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
their recursive work, evaluation computes each stored node once, and finished
expressions retain only reachable nodes in an exactly sized result.

Because `eval` takes the expression as a compile-time receiver, Zig resolves
the symbolic dispatch while compiling and emits topologically ordered numeric
work with shared results reused. The temporary construction workspace has a
guarded node limit; multiplicative factor counts are tracked compactly rather
than expanded into a tree. The stored expression does not carry the workspace
capacity and grows only with its unique, reachable nodes.

`metrics()` reports the finished `node_count`, `construction_peak_nodes`, and
`backing_bytes`. Measuring an expression also verifies topological order,
reachability, and structural uniqueness at compile time.

## Writing

- [Building a Symbolic Differentiator That Compiles Away Completely in Zig](docs/blog/building-a-symbolic-differentiator-that-compiles-away.md)
- [Disproving the Jacobian Conjecture with Bombelli](docs/blog/disproving-the-jacobian-conjecture-with-bombelli.md)
- [Expression-growth baseline](docs/architecture/stress-baseline.md)

## Commands

```sh
zig build test
zig build test-compile-fail
zig build run
zig build stress
```

Bombelli uses only Zig's standard library and targets Zig 0.16.0.
