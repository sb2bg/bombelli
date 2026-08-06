const std = @import("std");
const bombelli = @import("bombelli");

const expr = bombelli.expr;
const exprVector = bombelli.exprVector;
const exprMatrix = bombelli.exprMatrix;
const system = bombelli.system;

test "human rendering modes remain separate from source emission" {
    const expression = comptime expr("sqrt(x) + x^2");
    try std.testing.expectEqualStrings(
        "x^(1/2) + x^2",
        comptime expression.renderMode(.canonical),
    );
    try std.testing.expectEqualStrings(
        "sqrt(x) + x^2",
        comptime expression.renderMode(.pretty),
    );
    try std.testing.expectEqualStrings(
        comptime expression.render(),
        comptime expression.renderMode(.canonical),
    );
}

test "smooth elementary functions emit native Zig and C math calls" {
    const expression = comptime expr(
        "asin(x) + acos(x) + sinh(x) + cosh(x) + tanh(x) + log2(x) + log10(x) + atan2(y, x) + hypot(x, y)",
    );
    const zig_source = comptime expression.emit(.{
        .target = .zig,
        .name = "evaluate_unary",
    });
    inline for (.{
        "std.math.asin(",
        "std.math.acos(",
        "std.math.sinh(",
        "std.math.cosh(",
        "std.math.tanh(",
        "@log2(",
        "@log10(",
        "std.math.atan2(",
        "std.math.hypot(",
    }) |spelling| {
        try std.testing.expect(
            std.mem.indexOf(u8, zig_source, spelling) != null,
        );
    }

    const c_source = comptime expression.emit(.{
        .target = .c,
        .name = "evaluate_unary",
    });
    inline for (.{
        "asin(",
        "acos(",
        "sinh(",
        "cosh(",
        "tanh(",
        "log2(",
        "log10(",
        "atan2(",
        "hypot(",
    }) |spelling| {
        try std.testing.expect(
            std.mem.indexOf(u8, c_source, spelling) != null,
        );
    }

    const c_f32_source = comptime expression.emit(.{
        .target = .c,
        .name = "evaluate_unary_f32",
        .scalar = .f32,
    });
    inline for (.{
        "asinf(",
        "acosf(",
        "sinhf(",
        "coshf(",
        "tanhf(",
        "log2f(",
        "log10f(",
        "atan2f(",
        "hypotf(",
    }) |spelling| {
        try std.testing.expect(
            std.mem.indexOf(u8, c_f32_source, spelling) != null,
        );
    }
}

test "Zig emission computes shared DAG nodes once" {
    const expression = comptime expr("sin(x*y) + sin(x*y) + x^3").simplify();
    const source = comptime expression.emit(.{
        .target = .zig,
        .name = "evaluate_expression",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn evaluate_expression(inputs: anytype, output: *f64)",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@sin("),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "switch (node") == null);

    const vector = comptime exprVector(.{
        "sin(x*y) + x",
        "sin(x*y) + y",
    }).simplify();
    const vector_source = comptime vector.emit(.{
        .target = .zig,
        .name = "evaluate_vector",
    });
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, vector_source, "@sin("),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        vector_source,
        "output[1]",
    ) != null);

    const exact_literal_source = comptime expr("9007199254740993").emit(.{
        .target = .zig,
        .name = "evaluate_exact_literal",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_literal_source,
        "9007199254740993",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_literal_source,
        "@floatFromInt",
    ) != null);

    const exact_rational_source = comptime expr(
        "9007199254740993 / 7",
    ).simplify().emit(.{
        .target = .zig,
        .name = "evaluate_exact_rational",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        exact_rational_source,
        "9007199254740993",
    ) != null);

    const huge_float_source = comptime expr("1e300").emit(.{
        .target = .zig,
        .name = "evaluate_huge_float",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        huge_float_source,
        "1e300",
    ) != null);
    try std.testing.expect(huge_float_source.len < 2_000);
}

test "C emission computes shared DAG nodes once" {
    const expression = comptime expr("sin(x*y) + sin(x*y) + x^3").simplify();
    const source = comptime expression.emit(.{
        .target = .c,
        .name = "evaluate_expression",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "void evaluate_expression(const evaluate_expression_inputs *inputs, double *output)",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "sin("),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import") == null);

    const vector_source = comptime exprVector(.{
        "sin(x*y) + x",
        "sin(x*y) + y",
    }).simplify().emit(.{
        .target = .c,
        .name = "evaluate_vector",
    });
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, vector_source, "sin("),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        vector_source,
        "double output[2]",
    ) != null);
}

test "C emission writes matrices through a sized output parameter" {
    const source = comptime exprMatrix(.{
        .{ "x * y", "x" },
        .{ "y", "1" },
    }).simplify().emit(.{
        .target = .c,
        .name = "evaluate_matrix",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "double output[2][2]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "output[1][1] =",
    ) != null);
}

test "C emission names its inputs instead of ordering them" {
    // Positional parameters would let a caller transpose two arguments
    // silently, so inputs arrive as a struct whose fields are alphabetical
    // rather than in the order the DAG happens to visit them.
    const source = comptime expr("y * b + a * x").simplify().emit(.{
        .target = .c,
        .name = "evaluate_named",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "typedef struct evaluate_named_inputs {\n" ++
            "    double a;\n" ++
            "    double b;\n" ++
            "    double x;\n" ++
            "    double y;\n" ++
            "} evaluate_named_inputs;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "inputs->a") != null);
}

test "C emission gives an input-free callable a usable struct" {
    // C rejects an empty struct, and an unused parameter is a warning, so a
    // callable that reads nothing still has to emit something compilable.
    const source = comptime expr("2 * x").diff(.x).simplify().emit(.{
        .target = .c,
        .name = "evaluate_constant",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "char bombelli_unused;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "(void)inputs;") != null);
}

test "C emission spells pi as a literal rather than a math.h extension" {
    const source = comptime expr("pi * r^2").emit(.{
        .target = .c,
        .name = "evaluate_area",
    });
    try std.testing.expect(std.mem.indexOf(u8, source, "M_PI") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "3.141592653589793",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "inputs->r") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "inputs->pi") == null);
}

test "C emission can retarget the scalar type to f32" {
    const source = comptime expr("sin(x) + x^(1/2)").emit(.{
        .target = .c,
        .name = "evaluate_single",
        .scalar = .f32,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "void evaluate_single(const evaluate_single_inputs *inputs, float *output)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sinf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "powf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "double") == null);

    const default_source = comptime expr("sin(x)").emit(.{
        .target = .c,
        .name = "evaluate_single",
    });
    try std.testing.expect(std.mem.indexOf(u8, default_source, "float") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "sinf(") == null);
}

test "fixed quadrature C emission contains only the selected table" {
    const rule = comptime expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const source = comptime rule.emit(.{
        .target = .c,
        .name = "evaluate_integral",
    });
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "exp("),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "weighted_sum +="),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "Builder") == null);
    // The integration bounds are already fields, so `k` is the only addition.
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "    double from;\n    double to;\n    double k;\n",
    ) != null);
}

test "Newton C emission is standalone fixed-size numerical code" {
    const solver = comptime system(.{
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
    const source = comptime solver.emit(.{
        .target = .c,
        .name = "solve_system",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "void solve_system(const solve_system_inputs *inputs, solve_system_result *output)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "for (iteration = 0; iteration < 32; ++iteration)",
    ) != null);
    // The initial iterate is nested so an unknown and a parameter may share
    // a name without colliding in one struct.
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "solve_system_initial initial;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "inputs->initial.x",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
}

test "the two targets emit the same callable without sharing spellings" {
    const expression = comptime expr("sin(x) + x^3").simplify();
    const zig_source = comptime expression.emit(.{
        .target = .zig,
        .name = "evaluate_shared",
    });
    const c_source = comptime expression.emit(.{
        .target = .c,
        .name = "evaluate_shared",
    });
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "@sin(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "inputs.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_source, "@sin(") == null);
    try std.testing.expect(std.mem.indexOf(u8, c_source, "inputs->x") != null);
}

test "fixed quadrature Zig emission contains only the selected table" {
    const rule = comptime expr("exp(-k*x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 16,
    });
    const source = comptime rule.emit(.{
        .target = .zig,
        .name = "evaluate_integral",
    });
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "@exp("),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        std.mem.count(u8, source, "weighted_sum +="),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "Builder") == null);
}

test "Newton Zig emission is standalone fixed-size numerical code" {
    const solver = comptime system(.{
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
    const source = comptime solver.emit(.{
        .target = .zig,
        .name = "solve_system",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn solve_system(inputs: anytype, output: *solve_systemResult)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "for (0..32) |iteration|",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "@import(\"bombelli\")",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ast.Node") == null);
}

test "runtime-observation least-squares Zig emission preserves the solver ABI" {
    const fitter = comptime bombelli.residualModel(.{
        "offset + slope*x - y",
    }, .{
        .variables = .{ .offset, .slope },
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .bounds = .{ .slope = .{ .lower = 0.0 } },
        .loss = bombelli.loss.huber(0.5),
        .max_iterations = 16,
    });
    const source = comptime fitter.emit(.{
        .target = .zig,
        .name = "fit_line",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn fit_line(inputs: anytype, output: *fit_lineResult)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "observations: anytype",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"bombelli\")") == null);
}

test "runtime-observation least-squares C emission uses named runtime-row types" {
    const fitter = comptime bombelli.residualModel(.{
        "offset + slope*x - y",
    }, .{
        .variables = .{ .offset, .slope },
        .data = .{ .x, .y },
    }).leastSquares().compile(.{
        .bounds = .{ .slope = .{ .lower = 0.0 } },
        .loss = bombelli.loss.huber(0.5),
        .max_iterations = 16,
    });
    const source = comptime fitter.emit(.{
        .target = .c,
        .name = "fit_line",
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "typedef struct fit_line_observation",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "const fit_line_observation *observations;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "void fit_line(const fit_line_inputs *inputs, fit_line_result *output)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import") == null);
}

test "Zig emission spells pi as an explicit std constant" {
    const source = comptime expr("pi * r^2").emit(.{
        .target = .zig,
        .name = "evaluate_area",
    });
    try std.testing.expect(std.mem.indexOf(u8, source, "std.math.pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "inputs.pi") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "inputs.r") != null);
}

test "Zig emission can retarget the scalar type to f32" {
    const source = comptime expr("sin(x) + x^2").emit(.{
        .target = .zig,
        .name = "evaluate_single",
        .scalar = .f32,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "pub fn evaluate_single(inputs: anytype, output: *f32)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "f64") == null);

    const default_source = comptime expr("sin(x) + x^2").emit(.{
        .target = .zig,
        .name = "evaluate_single",
    });
    try std.testing.expect(std.mem.indexOf(u8, default_source, "f32") == null);

    const quadrature_source = comptime expr("exp(-x^2)").quadrature(.{
        .variable = .x,
        .rule = .gauss_legendre,
        .order = 4,
    }).emit(.{
        .target = .zig,
        .name = "integrate_single",
        .scalar = .f32,
    });
    try std.testing.expect(std.mem.indexOf(u8, quadrature_source, "f64") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        quadrature_source,
        "var weighted_sum: f32 = 0.0;",
    ) != null);
}
