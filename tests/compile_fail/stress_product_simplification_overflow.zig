const bombelli = @import("bombelli");

comptime {
    const product = bombelli.expr(
        "(x + 1) * (x + 2) * (x + 3) * (x + 4) * (x + 5) * (x + 6) * " ++
            "(x + 7) * (x + 8) * (x + 9) * (x + 10) * (x + 11) * (x + 12)",
    );
    _ = product.diff(.x).simplify();
}
