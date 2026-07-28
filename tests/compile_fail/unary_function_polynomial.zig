// expect-error: error: Bombelli expression is not an exact polynomial: transcendental functions are not polynomials
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("sinh(x)").asPolynomial();
}
