const std = @import("std");
const bombelli = @import("bombelli");

const expr = bombelli.expr;
const callable = bombelli.callable;

test "callable helpers preserve compile-time-specialized structural interfaces" {
    const expression = comptime expr("x^2 + y");
    try std.testing.expectEqual(
        @as(f64, 7.0),
        callable.eval(expression, .{ .x = 2.0, .y = 3.0 }),
    );

    const emitted = comptime callable.emit(expression, .{
        .target = .zig,
        .mode = .out_of_place,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "pub fn bombelli_generated",
    ) != null);

    const rule = comptime expr("x^2").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 4,
    });
    try std.testing.expectApproxEqAbs(
        1.0 / 3.0,
        callable.eval(rule, .{ .from = 0.0, .to = 1.0 }),
        1e-15,
    );
    try std.testing.expect(callable.supports(@TypeOf(expression), "diff"));
    try std.testing.expect(callable.supports(@TypeOf(rule), "emit"));
}

test "top-level evaluation composes temporary symbolic programs" {
    const Runtime = struct {
        fn scalar(x: f64) f64 {
            return bombelli.eval(
                bombelli.expr("x^2 + 1"),
                .{ .x = x },
            );
        }

        fn gradient(x: f64, y: f64) [2]f64 {
            return bombelli.eval(
                bombelli.expr("x^2 + x*y").gradient(.{ .x, .y }),
                .{ .x = x, .y = y },
            );
        }
    };

    try std.testing.expectEqual(@as(f64, 10), Runtime.scalar(3));
    try std.testing.expectEqualDeep(
        [2]f64{ 8, 3 },
        Runtime.gradient(3, 2),
    );

    const typed = bombelli.evalAs(
        f32,
        bombelli.exprVector(.{ "x/3", "x^2" }),
        .{ .x = @as(f32, 3) },
    );
    try std.testing.expectEqualDeep([2]f32{ 1, 9 }, typed);

    var hessian: [2][2]f64 = undefined;
    bombelli.evalInto(
        bombelli.expr("x^2 + 3*x*y + y^2").hessian(.{ .x, .y }),
        &hessian,
        .{ .x = 2, .y = 1 },
    );
    try std.testing.expectEqualDeep(
        [2][2]f64{
            .{ 2, 3 },
            .{ 3, 2 },
        },
        hessian,
    );
}
