# Expression-growth baseline

Bombelli expressions use hash-consed immutable DAGs. Builders intern equal
nodes, transforms memoize by source node, and finished programs retain only
unique reachable nodes. N-ary sums and products store exact-size operand
lists; multi-output programs share one node store.

`metrics()` validates reachability, topological order, and structural
uniqueness. It reports final nodes, n-ary operand edges, peak builder nodes,
remaining guarded workspace, and persisted backing bytes.

The stress suite covers:

- a twenty-factor product through differentiation and simplification
- deep function composition and repeated differentiation
- repeated shared subexpressions and products collapsing to powers
- a coupled four-output Jacobian
- canonical 48-term sums and 32-factor products
- expansion of a four-variable degree-eight polynomial
- exact symbolic systems and repeated integration by parts
- order-32 quadrature construction

Current enforced construction bounds keep the coupled Jacobian and polynomial
expansion below 512 nodes, and canonical large sums and products below 256.
The degree-eight polynomial is the largest measured fixture; its construction
peak is 368 of the guarded 1,024-node workspace.

Sparse polynomial multiplication accumulates equal monomials as it builds the
result, so temporary storage tracks unique terms instead of the Cartesian
product. Multiplication simplification also propagates factor multiplicity
through shared nodes; twenty repeated `x` factors finish as `x^20`.

Run the baseline with:

```sh
zig build stress --summary all
```

The thresholds are regression guards, not portable performance measurements.
