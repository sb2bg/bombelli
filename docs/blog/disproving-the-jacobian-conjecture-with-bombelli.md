# Disproving the Jacobian Conjecture with Bombelli

On July 20, 2026, Levent Alpöge announced an explicit polynomial map in three
complex variables that has constant nonzero Jacobian determinant and is not
injective. That is exactly the combination the Jacobian conjecture said could
not exist.

The certificate is short enough to check directly. It has since been
[independently formalized in Isabelle/HOL](https://isa-afp.org/entries/Jacobian_Counterexample.html),
including the determinant calculation, the collision, the absence of a
polynomial inverse, and stabilization to every dimension at least three.

So naturally, we gave it to Bombelli.

An important qualification comes first: Bombelli did not discover this
counterexample, and its current floating-point evaluator is not a proof
assistant. What it can already do is parse the three component polynomials,
differentiate all nine Jacobian entries at compile time, and reproduce the two
finite checks that kill the conjecture:

1. The Jacobian determinant is the nonzero constant `-2`.
2. Three distinct rational points have the same image.

That makes the counterexample a surprisingly good test of what Bombelli can do
today—and a precise specification for what it needs next.

## The conjecture in one paragraph

Let

```text
F = (P₁, …, Pₙ): ℂⁿ → ℂⁿ
```

be a polynomial map. Its Jacobian matrix contains every first partial
derivative:

```text
        ┌ ∂P₁/∂x₁  …  ∂P₁/∂xₙ ┐
JF  =   │    ⋮            ⋮    │
        └ ∂Pₙ/∂x₁  …  ∂Pₙ/∂xₙ ┘
```

If `det JF` is nonzero at a point, the inverse function theorem says that `F`
has a local inverse near that point. The Jacobian conjecture asserted something
far stronger for polynomial maps over characteristic zero: if `det JF` is a
nonzero constant, then `F` must be globally invertible, with a polynomial
inverse.

The leap from local to global was the conjecture.

In one complex variable this is easy. In two variables it remains open. In
three variables, the newly announced map shows that the leap fails.

## The map

Write `F = (P, Q, R): ℂ³ → ℂ³`, where

```text
P = (1 + x*y)^3*z + y^2*(1 + x*y)*(4 + 3*x*y)

Q = y
    + 3*x*(1 + x*y)^2*z
    + 3*x*y^2*(4 + 3*x*y)

R = 2*x - 3*x^2*y - x^3*z
```

Direct calculation gives:

```text
det JF = -2
```

Yet the three distinct points

```text
( 0,    0,  -1/4)
( 1, -3/2,  13/2)
(-1,  3/2,  13/2)
```

all map to:

```text
(-1/4, 0, 0)
```

The determinant can be normalized from `-2` to `1` by scaling one output
coordinate. The collision remains. A map with three inputs sharing one output
cannot have an inverse, polynomial or otherwise.

That is the entire disproof certificate.

## Asking Bombelli for the Jacobian

Bombelli currently represents scalar expressions, so we define the three
components separately:

```zig
const p = bombelli.expr(
    "(1 + x * y)^3 * z + y^2 * (1 + x * y) * (4 + 3 * x * y)",
);
const q = bombelli.expr(
    "y + 3 * x * (1 + x * y)^2 * z + 3 * x * y^2 * (4 + 3 * x * y)",
);
const r = bombelli.expr("2 * x - 3 * x^2 * y - x^3 * z");
```

The nine entries of the Jacobian are ordinary compile-time transformations:

```zig
const p_x = p.diff(.x).simplify();
const p_y = p.diff(.y).simplify();
const p_z = p.diff(.z).simplify();

const q_x = q.diff(.x).simplify();
const q_y = q.diff(.y).simplify();
const q_z = q.diff(.z).simplify();

const r_x = r.diff(.x).simplify();
const r_y = r.diff(.y).simplify();
const r_z = r.diff(.z).simplify();
```

At runtime we evaluate those already-transformed expressions and take the
three-by-three determinant:

```zig
return px * (qy * rz - qz * ry)
    - py * (qx * rz - qz * rx)
    + pz * (qx * ry - qy * rx);
```

The repository includes the
[complete companion example](../../examples/jacobian_counterexample.zig).

It prints:

```text
F(0, 0, -0.25) = (-0.25, 0, 0), det JF = -2
F(1, -1.5, 6.5) = (-0.25, 0, 0), det JF = -2
F(-1, 1.5, 6.5) = (-0.25, 0, 0), det JF = -2
```

Bombelli performs parsing, partial differentiation, and simplification while
compiling. Evaluation contains the numerical operations for the resulting
partials. There is no runtime symbolic tree walk.

Again, evaluating a polynomial at several points does not prove that it is
constant. The proof-grade version of this check should compute the determinant
as an exact multivariate polynomial and reduce it identically to `-2`. That
capability now has a very good acceptance test.

## How can a locally invertible map be three-to-one?

The counterexample feels paradoxical only if local and global invertibility are
allowed to blur together.

A nonzero Jacobian determinant says that every sufficiently small neighborhood
maps cleanly to a neighborhood in the target. It prevents folds, pinches, and
local collisions. It does not, by itself, prevent several far-apart regions of
the source from covering the same target region.

[Terence Tao's geometric digestion](https://terrytao.wordpress.com/2026/07/21/a-digestion-of-the-jacobian-conjecture-counterexample/)
starts with multiplication of binary forms. A generic homogeneous cubic in two
variables factors into three linear factors:

```text
C = L₁ L₂ L₃
```

There are then three ways to designate one factor as linear and the other two
as a quadratic:

```text
(L₁, L₂L₃)
(L₂, L₁L₃)
(L₃, L₁L₂)
```

All three pairs multiply to the same cubic. After quotienting a scaling
symmetry, imposing a resultant normalization, and taking a carefully selected
three-dimensional slice, the construction retains this generic three-to-one
behavior while becoming locally invertible on a space polynomially equivalent
to `ℂ³`.

This explains why the explicit coefficients are not just a lucky cancellation.
The collision comes from choosing which root receives the distinguished linear
factor.

Another useful description is non-properness. As a target point approaches a
special locus, some preimages can escape to infinity instead of colliding
locally. The Jacobian never has to vanish. The missing global behavior happens
at infinity, outside every bounded neighborhood where the inverse function
theorem applies.

## What broke—and what did not

The formal verification establishes counterexamples in dimension three and in
every higher finite dimension by adjoining identity coordinates. The
two-dimensional Jacobian conjecture remains open.

That distinction has already become mathematically productive. A
[new analysis of graded Keller maps](https://arxiv.org/abs/2607.20210) observes
that the counterexample is equivariant for the mixed-sign weights:

```text
wt(x, y, z) = (1, -1, -2)
```

For equivariant Keller maps with all-positive weights, the same paper proves
that the map must be an automorphism. It also proves that no weight signature
produces a graded counterexample in dimension two. The counterexample therefore
does more than say “false”: it points at mixed-sign grading and dimension three
as the first place this escape mechanism can live.

The arithmetic behavior is equally strange. Over `ℂ`, a generic target point
has three preimages. Over `ℚ`, the image of rational points is thin, so a generic
rational target has no rational preimage at all. The same polynomial map is
simultaneously many-to-one geometrically and sparse arithmetically.

## The consequence cascade

The Jacobian conjecture sat inside a network of implications. Once it failed,
several other statements had to fail with it.

### The Mathieu conjecture for `SU(3)`

A fixed-dimensional implication says that the relevant Mathieu conjecture for
`SU(N)` would imply the Jacobian conjecture in dimension `N`. The
three-dimensional counterexample therefore makes the Mathieu conjecture false
for `SU(3)`.

In informal terms, there are finite-type functions whose every pure-power
integral vanishes, while certain mixed integrals remain nonzero infinitely
often. The counterexample moves from polynomial invertibility into harmonic
analysis on compact groups.

### Gaussian moments

The Gaussian Moments Conjecture proposed that if all moments of powers of a
complex polynomial vanish under a standard real Gaussian, then multiplying by
any fixed polynomial should eventually preserve that vanishing.

Earlier work showed that the all-dimensional Gaussian statement would imply
the all-dimensional Jacobian conjecture. The new counterexample therefore
forces a Gaussian failure in some finite dimension. A
[July 2026 preprint](https://arxiv.org/abs/2607.18186) goes further: it tracks a
conservative route through a cubic-homogeneous reduction, and separately gives
much smaller explicit Gaussian counterexamples in dimensions three and four.
Those small examples were prompted by the Jacobian news but were not derived
from Alpöge's map.

### Hessian nilpotency and vanishing

[Zhao's Vanishing Conjecture](https://arxiv.org/abs/math/0409534) reformulates
the Jacobian problem using homogeneous quartic polynomials, powers of the
Laplacian, and nilpotent Hessian matrices. The all-dimensional statements are
equivalent, so a Jacobian counterexample forces a failure of the Vanishing
Conjecture in some finite dimension.

A
[very recent preprint](https://zenodo.org/records/21503372) claims an explicit
route: a cubic-homogeneous reduction, followed by a construction in 48
variables, yields a 382-monomial Hessian-nilpotent quartic whose gradient map has
an exact collision. It also claims an explicit Vanishing Conjecture witness.
This is interesting and machine-checked work, but it is only days old as this
article is written and should be read as an active follow-on result rather than
settled exposition.

That scale—48 variables and hundreds of monomials—is also a warning for
Bombelli. Correct symbolic representation is not an implementation detail when
the mathematics naturally produces expressions of that size.

## What this says about Bombelli's roadmap

The counterexample fits the library's long-term direction almost too well. A
complete verification wants:

- Exact integers and rationals
- Multivariate polynomial normal forms
- Symbolic matrices and determinants
- Exact substitution and equality
- Factoring, resultants, and polynomial maps
- Gradients, Jacobians, and Hessians as first-class operations
- Exportable certificates for proof assistants

It also wants a representation that can survive serious algebra.

Bombelli originally stored copied trees in a fixed 512-node array. Stress
measurements made the cost visible: a ten-factor product derivative contained
255 reachable nodes but only 58 structurally unique subexpressions. Roughly 77%
of the representation was duplication, and a twenty-factor derivative
exhausted the array.

That boundary drove the next architecture. Bombelli now stores an exactly sized,
node-indexed DAG. Hash-consed constructors reuse equivalent nodes, while
differentiation and simplification memoize work by `NodeId`. The twenty-factor
derivative now fits in 118 stored nodes, all unique and reachable; its simplified
form uses 96.

That does not abolish genuine expression swell. Polynomial-specific storage,
n-ary sums and products, factored forms, and more specialized numerical kernels
will still be needed as the mathematics grows. The current evaluator already
computes each stored DAG node once, while multiplication simplification combines
repeated factors into powers without expanding shared occurrences.

The Jacobian example makes the distinction concrete:

- Repeating the same partial derivative subtree is avoidable duplication.
- Expanding a 382-monomial quartic may be genuine mathematical size.

Bombelli needs to eliminate the first without pretending it can abolish the
second.

## So, did Bombelli disprove it?

No. The title is deliberately mischievous.

The disproof belongs to the announced counterexample and the mathematical work
that produced and verified it. Bombelli can already reconstruct the derivative
matrix and reproduce the numerical certificate in a small Zig program. It
cannot yet replace the exact algebra or the formal Isabelle development.

But this is exactly the kind of mathematics Bombelli is being built to make
clean, inspectable, and executable:

```text
polynomial map
    → symbolic Jacobian
    → exact determinant
    → simplified certificate
    → efficient evaluation
```

When exact polynomial arithmetic and matrix expressions land, the desired
Bombelli program should reduce `det JF` to `-2` at compile time and verify the
collision using rationals—not samples. From there, the deeper branches lead
toward Hessians, polynomial maps, invariant theory, Gaussian moments, and the
rest of the mathematics exposed by this remarkable counterexample.

That is a much more interesting destination than merely adding another
elementary function.

## Sources

- [Formal Verification of an Explicit Counterexample to the Jacobian Conjecture, Archive of Formal Proofs](https://isa-afp.org/entries/Jacobian_Counterexample.html)
- [A digestion of the Jacobian conjecture counterexample, Terence Tao](https://terrytao.wordpress.com/2026/07/21/a-digestion-of-the-jacobian-conjecture-counterexample/)
- [Direct Consequences of the Three-Dimensional Counterexample to the Jacobian Conjecture, Zihan Zhang](https://zzhang-iu.github.io/papers/direct-consequences-jacobian/)
- [Graded Keller maps and the Jacobian Conjecture, arXiv:2607.20210](https://arxiv.org/abs/2607.20210)
- [Small Counterexamples to the Gaussian Moments Conjecture, arXiv:2607.18186](https://arxiv.org/abs/2607.18186)
- [Hessian Nilpotent Polynomials and the Jacobian Conjecture, arXiv:math/0409534](https://arxiv.org/abs/math/0409534)
- [The consequence cascade of the Jacobian counterexample, Zenodo preprint](https://zenodo.org/records/21503372)
