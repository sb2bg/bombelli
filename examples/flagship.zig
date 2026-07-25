const std = @import("std");
const bombelli = @import("bombelli");

const response_gradient = bombelli
    .expr("ln(1 + x^2 * y^2) + exp(sin(x * y))")
    .diff(.x)
    .simplify();

const coupled = bombelli.exprVector(.{
    "sin(x*y) + x^2",
    "sin(x*y) + y^2",
});
const coupled_jacobian = coupled.jacobian(.{ .x, .y }).simplify();
const coupled_hessian = bombelli.expr("sin(x*y) + x^2 + y^2")
    .hessian(.{ .x, .y })
    .simplify();

const symbolic_system = bombelli.system(.{
    "a*x + b*y = e",
    "c*x + d*y = f",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
});
const symbolic_solution = symbolic_system.solve(.bareiss);

const partial_integral = bombelli.expr("3*x^2 + exp(x^2)").integrate(.{
    .variable = .x,
    .domain = .real,
});
const compiled_integral = partial_integral.compile(.{
    .rule = .gauss_legendre,
    .order = 16,
});

const emitted_evaluator = response_gradient.emit(.{
    .target = .zig,
    .mode = .out_of_place,
    .name = "response_gradient",
});

pub fn responseGradient(x: f64, y: f64) f64 {
    return response_gradient.eval(.{ .x = x, .y = y });
}

pub fn main() void {
    const x = 1.25;
    const y = 0.75;

    std.debug.print("{s}\nvalue at x={d}, y={d}: {d}\n", .{
        comptime response_gradient.render(),
        x,
        y,
        responseGradient(x, y),
    });

    const jacobian = coupled_jacobian.eval(.{ .x = x, .y = y });
    const hessian = coupled_hessian.eval(.{ .x = x, .y = y });
    std.debug.print(
        "shared Jacobian[0]={any}\nshared Hessian[0]={any}\n",
        .{ jacobian[0], hessian[0] },
    );

    const parameters = .{
        .a = 2.0,
        .b = 1.0,
        .c = 1.0,
        .d = -1.0,
        .e = 7.0,
        .f = 2.0,
    };
    std.debug.print(
        "symbolic condition: {s}\nsolution: {any}\n",
        .{
            comptime symbolic_solution.conditional.conditions[0].render(),
            symbolic_solution.conditional.values.eval(parameters),
        },
    );

    std.debug.print(
        "partial integral [0,1]: {d}\nstandalone Zig source: {d} bytes\n",
        .{
            compiled_integral.eval(.{ .from = 0.0, .to = 1.0 }),
            emitted_evaluator.len,
        },
    );
}
