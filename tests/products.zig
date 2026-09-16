const std = @import("std");
const bombelli = @import("bombelli");

test "direct and symbolic products agree with explicit Jacobians and duality" {
    const model = comptime bombelli.model(.{
        "sin(x*y) + x^2",
        "sin(x*y) + y^2",
        "exp(x-y) + p*x",
    }, .{ .variables = .{ .y, .x, .unused }, .inputs = .{.p} });
    const jacobian = comptime model.jacobian();
    const tangent = [3]f64{ 0.7, -1.3, 4.0 };
    const cotangent = [3]f64{ -0.2, 0.6, 1.1 };
    inline for (.{ bombelli.DerivativeProductStrategy.direct, .symbolic, .auto }) |strategy| {
        const forward = comptime model.compileJvp(.{ .strategy = strategy });
        const reverse = comptime model.compileVjp(.{ .strategy = strategy });
        for ([_]f64{ -0.8, 0.0, 0.4, 1.2 }) |x| {
            const inputs = .{ .x = x, .y = 0.6, .p = 1.7, .unused = 9.0 };
            const j = jacobian.eval(inputs);
            const jv = forward.eval(inputs, tangent);
            const vj = reverse.eval(inputs, cotangent);
            var lhs: f64 = 0;
            var rhs: f64 = 0;
            for (0..3) |row| {
                var expected_jv: f64 = 0;
                var expected_vj: f64 = 0;
                for (0..3) |column| {
                    expected_jv += j[row][column] * tangent[column];
                    expected_vj += j[column][row] * cotangent[column];
                }
                try std.testing.expectApproxEqAbs(expected_jv, jv[row], 1e-12);
                try std.testing.expectApproxEqAbs(expected_vj, vj[row], 1e-12);
                lhs += cotangent[row] * jv[row];
                rhs += tangent[row] * vj[row];
            }
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-12);
        }
        try std.testing.expectEqual(@as(usize, 6), forward.inspect().structural_nonzeros);
        try std.testing.expectEqual(@as(usize, 9), forward.inspect().jacobian_entries);
    }
}

test "reverse accumulation handles repeated roots and interior output roots" {
    const model = comptime bombelli.model(.{ "x*y", "sin(x*y)", "x*y", "7" }, .{ .variables = .{ .x, .y } });
    const reverse = comptime model.compileVjp(.{ .strategy = .direct });
    const point = .{ .x = 0.5, .y = 2.0 };
    const actual = reverse.eval(point, .{ 2, 3, 4, 99 });
    const weight = 6 + 3 * @cos(@as(f64, 1));
    try std.testing.expectApproxEqAbs(2 * weight, actual[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.5 * weight, actual[1], 1e-12);
}

test "products at zero factors never divide by a primal product" {
    const model = comptime bombelli.model(.{"x*y*z*w"}, .{ .variables = .{ .x, .y, .z, .w } });
    const forward = comptime model.compileJvp(.{ .strategy = .direct });
    const reverse = comptime model.compileVjp(.{ .strategy = .direct });
    try std.testing.expectEqualDeep([1]f64{24}, forward.eval(.{ .x = 0.0, .y = 2.0, .z = 3.0, .w = 4.0 }, .{ 1, 1, 1, 1 }));
    try std.testing.expectEqualDeep([4]f64{ 24, 0, 0, 0 }, reverse.eval(.{ .x = 0.0, .y = 2.0, .z = 3.0, .w = 4.0 }, .{1}));
    try std.testing.expectEqualDeep([4]f64{ 0, 0, 0, 0 }, reverse.eval(.{ .x = 0.0, .y = 0.0, .z = 3.0, .w = 4.0 }, .{1}));
}

test "typed products retain input contracts and avoid seed collisions" {
    const model = comptime bombelli.model(.{ "x*bombelli_seed_0", "7" }, .{
        .variables = .{ .x, .unused },
        .inputs = .{.bombelli_seed_0},
    });
    const forward = comptime model.compileJvp(.{ .strategy = .direct });
    try std.testing.expect(!std.mem.eql(u8, "bombelli_seed_0", forward.seed_names[0]));
    const inputs = .{ .x = @as(f32, 3), .unused = @as(f32, 5), .bombelli_seed_0 = @as(f32, 2) };
    var output: [2]f32 = undefined;
    forward.evalIntoAs(f32, &output, inputs, .{ 4, 99 });
    try std.testing.expectEqualDeep([2]f32{ 8, 0 }, output);
    try std.testing.expectEqualDeep([2]f64{ 8, 0 }, model.jvp(inputs, .{ 4, 99 }));
    try std.testing.expectEqualDeep([2]f64{ 8, 0 }, model.vjp(inputs, .{ 4, 99 }));
}

test "elementary slopes agree with directional finite differences" {
    inline for (.{
        "sin(x)+cos(x)+tan(x)",
        "asin(x)+acos(y)+atan(x-y)",
        "sinh(x)+cosh(x*y)+tanh(y)",
        "exp(x-y)+ln(x)+log2(y)+log10(x+y)",
        "abs(x)+sqrt(y)+x^(1/3)+x^(-2)",
        "atan2(x,y)+hypot(x,y)+x/y",
    }) |source| {
        const model = comptime bombelli.model(.{source}, .{ .variables = .{ .x, .y } });
        const forward = comptime model.compileJvp(.{ .strategy = .direct });
        const reverse = comptime model.compileVjp(.{ .strategy = .direct });
        const point = .{ .x = 0.4, .y = 0.7 };
        const tangent = [2]f64{ 0.3, -0.2 };
        const h = 1e-6;
        const plus = model.eval(.{ .x = point.x + h * tangent[0], .y = point.y + h * tangent[1] });
        const minus = model.eval(.{ .x = point.x - h * tangent[0], .y = point.y - h * tangent[1] });
        const finite_difference = (plus[0] - minus[0]) / (2 * h);
        const actual = forward.eval(point, tangent);
        const adjoint = reverse.eval(point, .{1});
        try std.testing.expectApproxEqAbs(finite_difference, actual[0], 1e-7);
        try std.testing.expectApproxEqAbs(finite_difference, adjoint[0] * tangent[0] + adjoint[1] * tangent[1], 1e-7);
    }
}

test "inactive paths do not evaluate undefined data-only derivatives" {
    const model = comptime bombelli.model(.{ "sqrt(p)+x", "p^0" }, .{ .variables = .{ .x, .unused } });
    inline for (.{ bombelli.DerivativeProductStrategy.direct, .symbolic, .auto }) |strategy| {
        const forward = comptime model.compileJvp(.{ .strategy = strategy });
        const reverse = comptime model.compileVjp(.{ .strategy = strategy });
        // sqrt has an undefined derivative at p=0, but p is held constant.
        try std.testing.expectEqualDeep([2]f64{ 2, 0 }, forward.eval(.{ .x = 1.0, .p = 0.0 }, .{ 2, 3 }));
        try std.testing.expectEqualDeep([2]f64{ 2, 0 }, reverse.eval(.{ .x = 1.0, .p = 0.0 }, .{ 2, 3 }));
    }
    const singular = comptime bombelli.model(.{"x/x"}, .{ .variables = .{.x} }).compileJvp(.{ .strategy = .direct });
    try std.testing.expect(!std.math.isFinite(singular.eval(.{ .x = 0.0 }, .{1})[0]));
}

test "constant products need no seeds or model inputs at evaluation" {
    const model = comptime bombelli.model(.{ "7", "x^0" }, .{ .variables = .{.x} });
    const forward = comptime model.compileJvp(.{ .strategy = .direct });
    const reverse = comptime model.compileVjp(.{ .strategy = .direct });
    try std.testing.expectEqualDeep([2]f64{ 0, 0 }, forward.eval(.{}, .{std.math.nan(f64)}));
    try std.testing.expectEqualDeep([1]f64{0}, reverse.eval(.{}, .{ std.math.nan(f64), 1 }));
    try std.testing.expectEqual(@as(usize, 0), forward.inspect().structural_nonzeros);
}

test "automatic planning can choose symbolic contraction or direct propagation" {
    const narrow = comptime bombelli.model(.{"sin(sin(sin(sin(x))))"}, .{ .variables = .{.x} });
    const symbolic = comptime narrow.compileJvp(.{});
    try std.testing.expectEqual(.symbolic, symbolic.inspect().method);
    const coupled = comptime bombelli.model(.{
        "x*sin(x+y+z)", "y*sin(x+y+z)", "z*sin(x+y+z)",
    }, .{ .variables = .{ .x, .y, .z } });
    const forward = comptime coupled.compileJvp(.{});
    const reverse = comptime coupled.compileVjp(.{});
    try std.testing.expectEqual(.forward, forward.inspect().method);
    try std.testing.expectEqual(.reverse, reverse.inspect().method);
    try std.testing.expect(forward.inspect().shared_nodes > 0);
    const forced = comptime narrow.compileJvp(.{ .strategy = .direct });
    try std.testing.expectApproxEqAbs(symbolic.eval(.{ .x = 0.3 }, .{0.7})[0], forced.eval(.{ .x = 0.3 }, .{0.7})[0], 1e-14);
}

test "shared dense products compile to less work than symbolic entry contraction" {
    const model = comptime bombelli.model(.{
        "a*sin(a+b+c+d+e+f+g+h)", "b*sin(a+b+c+d+e+f+g+h)",
        "c*sin(a+b+c+d+e+f+g+h)", "d*sin(a+b+c+d+e+f+g+h)",
        "e*sin(a+b+c+d+e+f+g+h)", "f*sin(a+b+c+d+e+f+g+h)",
        "g*sin(a+b+c+d+e+f+g+h)", "h*sin(a+b+c+d+e+f+g+h)",
    }, .{ .variables = .{ .a, .b, .c, .d, .e, .f, .g, .h } });
    const forward = comptime model.compileJvp(.{ .strategy = .direct });
    const reverse = comptime model.compileVjp(.{ .strategy = .direct });
    const entries = comptime model.compileVjp(.{ .strategy = .symbolic });
    try std.testing.expect(reverse.inspect().operations < entries.inspect().operations);
    try std.testing.expect(reverse.inspect().construction_peak_nodes < entries.inspect().construction_peak_nodes);
    try std.testing.expect(forward.inspect().node_count < 64);
    try std.testing.expect(reverse.inspect().node_count < 64);
    const point = .{ .a = 0.01, .b = 0.02, .c = 0.03, .d = 0.04, .e = 0.05, .f = 0.06, .g = 0.07, .h = 0.08 };
    const seed = [8]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const actual = reverse.eval(point, seed);
    const expected = entries.eval(point, seed);
    for (actual, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-12);
}

// Keep construction outside the test body: its raised construction quota
// must not mask an insufficient quota in runtime-call input validation.
const LargeProduct = struct {
    const variables = .{
        .x00, .x01, .x02, .x03, .x04, .x05, .x06, .x07,
        .x08, .x09, .x10, .x11, .x12, .x13, .x14, .x15,
        .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
        .x24, .x25, .x26, .x27, .x28, .x29, .x30, .x31,
    };
    const N = variables.len;
    const model = blk: {
        var sum: []const u8 = "";
        for (variables, 0..) |variable, index| {
            if (index != 0) sum = sum ++ "+";
            sum = sum ++ @tagName(variable);
        }
        var sources: @Tuple(&([_]type{[]const u8} ** N)) = undefined;
        for (variables, 0..) |variable, index| sources[index] = @tagName(variable) ++ "*sin(" ++ sum ++ ")";
        break :blk bombelli.model(sources, .{ .variables = variables });
    };
    const Input = blk: {
        var names: [N][]const u8 = undefined;
        for (variables, 0..) |variable, index| names[index] = @tagName(variable);
        break :blk @Struct(.auto, null, &names, &([_]type{f64} ** N), &([_]std.builtin.Type.StructField.Attributes{.{}} ** N));
    };
    const forward = model.compileJvp(.{});
    const reverse = model.compileVjp(.{});
};

test "32 variable shared products stay bounded and match an analytic oracle" {
    const variables = LargeProduct.variables;
    const N = LargeProduct.N;
    const Input = LargeProduct.Input;
    const forward = LargeProduct.forward;
    const reverse = LargeProduct.reverse;
    try std.testing.expect(forward.inspect().construction_peak_nodes < 300);
    try std.testing.expect(reverse.inspect().construction_peak_nodes < 300);
    try std.testing.expectEqual(@as(usize, N * N), reverse.inspect().structural_nonzeros);
    var point: Input = undefined;
    var seed: [N]f64 = undefined;
    var sum: f64 = 0;
    var seed_sum: f64 = 0;
    var weighted_sum: f64 = 0;
    inline for (variables, 0..) |variable, i| {
        const x = @as(f64, @floatFromInt(i)) * 0.01;
        @field(point, @tagName(variable)) = x;
        seed[i] = @as(f64, @floatFromInt(i + 1)) * 0.02;
        sum += x;
        seed_sum += seed[i];
        weighted_sum += x * seed[i];
    }
    const jv = forward.eval(point, seed);
    const vj = reverse.eval(point, seed);
    inline for (variables, 0..) |variable, i| {
        try std.testing.expectApproxEqAbs(seed[i] * @sin(sum) + @field(point, @tagName(variable)) * @cos(sum) * seed_sum, jv[i], 1e-12);
        try std.testing.expectApproxEqAbs(seed[i] * @sin(sum) + @cos(sum) * weighted_sum, vj[i], 1e-12);
    }
}
