//! The callables exercised by standalone emission validation, shared by the
//! generators, the Zig harnesses, and the C reference so that every target is
//! generated from one definition.

const bombelli = @import("bombelli");

pub const expression = bombelli.expr(
    "9007199254740993 / 7 + 1e300 + sin(x*y) + x^3",
);
pub const expression_inputs = .{ .x = 1.25, .y = -0.75 };

/// Exercises smooth elementary functions whose emitted spelling differs
/// between Zig builtins, Zig's standard library, and C99 libm.
pub const smooth_expression = bombelli.expr(
    "asin(u) + acos(v) + sinh(u-v) + cosh(u+v) + tanh(u*v) + log2(a) + log10(b) + atan2(u, v) + hypot(u, v)",
);
pub const smooth_expression_inputs = .{
    .u = 0.35,
    .v = -0.2,
    .a = 3.25,
    .b = 12.5,
};

/// The expression case is dominated by its `1e300` term, so it pins down
/// literal fidelity rather than arithmetic. This one is scaled to catch a
/// wrong operator, and it is the only multi-output case.
pub const gradient = bombelli.expr(
    "sin(x*y) + exp(-x) / (1 + y^2) - x^3",
).gradient(.{ .x, .y }).simplify();
pub const gradient_inputs = .{ .x = 0.6, .y = -1.3 };

pub const rule = bombelli.expr("exp(-k*x^2)").quadrature(.{
    .variable = .x,
    .rule = .gauss_legendre,
    .order = 16,
});
pub const rule_inputs = .{ .from = 0.0, .to = 1.0, .k = 2.0 };

pub const solver = bombelli.system(.{
    "x^2 + y^2 = r^2",
    "x - y = 0",
}, .{
    .unknowns = .{ .x, .y },
    .domain = .real,
}).compile(.{
    .algorithm = .newton,
    .jacobian = .symbolic,
    .max_iterations = 32,
    .tolerance = 1e-12,
});
pub const solver_inputs = .{
    .initial = .{ .x = 0.7, .y = 0.7 },
    .r = 1.0,
};

pub const fit_observations = [_]struct { x: f64, y: f64 }{
    .{ .x = 0.0, .y = 1.0 },
    .{ .x = 1.0, .y = 3.0 },
    .{ .x = 2.0, .y = 5.0 },
    .{ .x = 3.0, .y = 7.0 },
};

pub const fitter = bombelli.residualModel(.{
    "offset + slope*x - y",
}, .{
    .variables = .{ .offset, .slope },
    .data = .{ .x, .y },
}).leastSquares().compile(.{
    .bounds = .{ .slope = .{ .lower = 0.0 } },
    .loss = bombelli.loss.huber(0.5),
    .tolerance = 1e-12,
    .max_iterations = 32,
});

pub const fitter_inputs = .{
    .initial = .{ .offset = 0.5, .slope = 0.5 },
    .observations = fit_observations[0..],
};
