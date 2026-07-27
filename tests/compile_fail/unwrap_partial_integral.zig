// expect-error: error: Bombelli integration is partial; unresolved remainder: exp(x^2)
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.expr("3*x^2 + exp(x^2)").integrate(.{
        .variable = .x,
        .domain = .real,
    }).unwrap();
}
