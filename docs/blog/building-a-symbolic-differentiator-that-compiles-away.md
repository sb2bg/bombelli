# Building a Symbolic Differentiator That Compiles Away Completely in Zig

Most mathematical code starts in a form that is easy to understand and ends in
a form that is easy for a computer to execute. The annoying part is everything
in between.

Take this expression:

```text
ln(1 + x^2 * y^2) + exp(sin(x * y))
```

Its derivative with respect to `x` is not especially exotic, but it combines a
logarithm, a quotient, two chain rules, and several products. Writing that
derivative by hand is manageable. Keeping it correct while the original
formula changes is where the trouble starts.

Bombelli lets the source expression remain the source of truth:

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

At compile time, Bombelli reduces the derivative to:

```text
2 * x * y^2 / (1 + x^2 * y^2) + y * cos(x * y) * exp(sin(x * y))
```

At runtime, there is no string, parser, allocator, syntax tree walk, or symbolic
virtual machine. There are only the floating-point operations and function
calls needed to evaluate the transformed expression.

That is the central idea behind Bombelli: write mathematical intent clearly,
do symbolic work while compiling, and leave ordinary numerical code in the
program.

## Why symbolic math belongs at compile time

Symbolic transformation is usually presented as an interactive activity. A
computer algebra system reads an expression, constructs a tree, manipulates
that tree, and returns another expression. That model is useful for notebooks
and exploratory tools, but it is awkward inside a systems program.

If the formula is known when the program is built, parsing it again at runtime
does not buy us anything. Neither does carrying a tagged tree through a hot
loop, allocating temporary nodes, or dispatching through an expression
interpreter.

Zig's compile-time execution model gives us another option. Bombelli's parser,
differentiator, and simplifier are normal Zig code evaluated with compile-time
inputs. The resulting expression is also a compile-time value. When `eval`
receives that value as a `comptime` parameter, every symbolic branch is resolved
by the compiler.

The runtime values of `x` and `y` remain dynamic. The shape of the computation
does not.

This distinction is what makes the API useful outside a demonstration. A
symbolic expression can define a derivative, gradient component, response
curve, or generated kernel without forcing the rest of the application to
adopt a symbolic runtime.

## A small API with a strict boundary

Bombelli exposes four core operations:

```zig
const expression = bombelli.expr("sin(x * y) + x^3");
const derivative = expression.diff(.x);
const simplified = derivative.simplify();
const source = simplified.render();

pub fn evaluate(x: f64, y: f64) f64 {
    return simplified.eval(.{ .x = x, .y = y });
}
```

The boundary is intentional:

- `expr` parses a source string known at compile time.
- `diff` transforms an expression with respect to an enum-literal symbol.
- `simplify` applies deterministic algebraic rules to a fixed point.
- `render` produces an inspectable canonical representation.
- `eval` accepts runtime numbers in a struct with matching field names.

Missing fields are compile errors. So are unknown functions, malformed powers,
unbalanced parentheses, trailing tokens, and unexpected characters. Parser
diagnostics include the source line and a caret near the problem.

The goal is not to make symbolic behavior implicit. It is to give it a narrow,
obvious place in the program.

## What happens under the API

The implementation starts with a hand-written lexer and recursive-descent
parser. The grammar covers literals, symbols, parentheses, unary negation,
arithmetic, non-negative integer powers, and an initial set of elementary
functions.

Parsed expressions use node indices rather than recursive owning pointers:

```zig
const Node = union(enum) {
    integer: i64,
    float: f64,
    symbol: []const u8,
    add: Binary,
    sub: Binary,
    mul: Binary,
    div: Binary,
    pow: Power,
    negate: NodeId,
    sin: NodeId,
    cos: NodeId,
    exp: NodeId,
    ln: NodeId,
};
```

Differentiation constructs a new expression using the familiar symbolic rules:
product, quotient, power, and chain rules. Simplification then removes
identities, folds constants, normalizes coefficients, flattens products, and
repeats until the result stops changing.

For example, differentiating `sin(x * y) + x^3` initially creates terms
containing `1 * y`, `x * 0`, `x^1`, and a final multiplication by `1`.
Simplification reduces those mechanics to:

```text
y * cos(x * y) + 3 * x^2
```

The evaluator recursively switches over nodes in the source, but both the
expression and node index are compile-time parameters. That recursion is
specialization logic, not runtime control flow. An optimized build of the
example contains direct multiplies, the required elementary-function calls,
and an addition. The symbolic representation has disappeared.

## Why Zig is a good fit

Bombelli depends on three Zig properties that work unusually well together.

First, compile-time code is Zig code. The parser and transformation passes do
not live in a macro language or a separate generator. They use the same types,
control flow, tests, and tooling as the rest of the library.

Second, `anytype`, reflection, and compile-time strings make the evaluation API
pleasant. Symbol names can map directly onto struct fields, and missing data can
be diagnosed before the program runs.

Third, specialization is explicit. Marking the expression receiver as
`comptime` creates a strong guarantee: runtime evaluation cannot quietly fall
back to walking symbolic data.

That makes it possible to keep the user-facing syntax high level without
giving up control over the generated program.

## Where Bombelli is going

Differentiation is the first vertical slice, not the boundary of the project.
Bombelli's long-term goal is to become a complete, practical mathematics
library covering most corners of mathematics that programmers regularly need.

The symbolic core will grow to include canonical algebra, exact integers and
rationals, polynomial and rational-function operations, factoring, assumptions,
rewriting, equation solving, limits, series, and symbolic integration.
Structural sharing, node interning, and memoized transformations provide the
base those larger operations need. The next scaling work is about genuine
mathematical growth: polynomial-specific forms, n-ary operations, factored
representations, and code-generation common-subexpression elimination.

Calculus should extend naturally from one derivative to partial derivatives,
gradients, Jacobians, Hessians, vector calculus, differential equations, and
automatic generation of efficient numerical kernels.

The same expression system should support linear algebra and tensors, complex
mathematics, transforms, numerical methods, probability and statistics,
combinatorics, number theory, and discrete mathematics. Some operations will be
best resolved at compile time. Others will deliberately produce efficient
runtime algorithms. They should still share notation, types, diagnostics, and
composition rules.

This is a broad destination, but the design standard is narrow:

1. Mathematical code should be easy to read.
2. Transformations should be deterministic and inspectable.
3. Compile-time work should remove runtime machinery, not hide it.
4. Numerical execution should remain predictable and efficient.
5. New areas of mathematics should compose with the same core expression model.

Bombelli should feel like one library, not a collection of unrelated math
utilities.

## Clean mathematics, ordinary programs

There is a useful middle ground between manually transcribing every formula and
embedding a full symbolic runtime in an application.

Bombelli occupies that space by treating symbolic mathematics as part of
compilation. The program keeps the expression that humans want to read. The
compiler gets the arithmetic that machines want to run.

Today that means a concise derivative can replace a fragile hand-maintained
function. Over time, it should mean the same clean path from mathematical intent
to executable Zig across algebra, calculus, linear algebra, analysis,
probability, and beyond.
