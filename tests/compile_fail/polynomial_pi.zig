// expect-error: error: Bombelli expression is not an exact polynomial: transcendental constants are not exact polynomials
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("pi * x^2").asPolynomial();
}
