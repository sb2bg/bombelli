const std = @import("std");
const ast = @import("ast.zig");
const evaluation = @import("evaluation.zig");
const gauss = @import("gauss_legendre.zig");

pub const AdaptiveStatus = enum {
    converged,
    depth_exhausted,
    non_finite,
};

pub const AdaptiveResult = struct {
    value: f64,
    estimated_error: f64,
    evaluations: usize,
    intervals: usize,
    status: AdaptiveStatus,
};

const Segment = struct {
    from: f64,
    to: f64,
    depth: usize,
};

const Estimate = struct {
    value: f64,
    error_estimate: f64,
};

pub fn AdaptiveQuadratureRule(comptime max_depth: usize) type {
    if (max_depth > 64) {
        @compileError("Bombelli adaptive quadrature max_depth may not exceed 64");
    }
    return struct {
        integrand: ast.Expr,
        variable: []const u8,
        tolerance: f64,

        pub const maximum_depth = max_depth;
        const Self = @This();

        pub inline fn eval(comptime self: Self, inputs: anytype) AdaptiveResult {
            const from = inputValue(inputs, "from");
            const to = inputValue(inputs, "to");
            if (from == to) return .{
                .value = 0.0,
                .estimated_error = 0.0,
                .evaluations = 0,
                .intervals = 0,
                .status = .converged,
            };

            var stack: [max_depth + 1]Segment = undefined;
            stack[0] = .{ .from = from, .to = to, .depth = 0 };
            var stack_len: usize = 1;
            var value: f64 = 0.0;
            var estimated_error: f64 = 0.0;
            var evaluations: usize = 0;
            var intervals: usize = 0;
            var exhausted = false;
            const total_width = @abs(to - from);

            while (stack_len != 0) {
                stack_len -= 1;
                const segment = stack[stack_len];
                const segment_estimate = self.estimate(
                    inputs,
                    segment.from,
                    segment.to,
                );
                evaluations += 24;
                intervals += 1;
                if (!std.math.isFinite(segment_estimate.value) or
                    !std.math.isFinite(segment_estimate.error_estimate))
                {
                    return .{
                        .value = std.math.nan(f64),
                        .estimated_error = std.math.inf(f64),
                        .evaluations = evaluations,
                        .intervals = intervals,
                        .status = .non_finite,
                    };
                }

                const local_tolerance = self.tolerance *
                    (@abs(segment.to - segment.from) / total_width);
                if (segment_estimate.error_estimate <= local_tolerance) {
                    value += segment_estimate.value;
                    estimated_error += segment_estimate.error_estimate;
                    continue;
                }
                if (segment.depth == max_depth) {
                    value += segment_estimate.value;
                    estimated_error += segment_estimate.error_estimate;
                    exhausted = true;
                    continue;
                }

                const midpoint = (segment.from + segment.to) * 0.5;
                std.debug.assert(stack_len + 2 <= stack.len);
                stack[stack_len] = .{
                    .from = midpoint,
                    .to = segment.to,
                    .depth = segment.depth + 1,
                };
                stack[stack_len + 1] = .{
                    .from = segment.from,
                    .to = midpoint,
                    .depth = segment.depth + 1,
                };
                stack_len += 2;
            }

            return .{
                .value = value,
                .estimated_error = estimated_error,
                .evaluations = evaluations,
                .intervals = intervals,
                .status = if (exhausted) .depth_exhausted else .converged,
            };
        }

        inline fn estimate(
            comptime self: Self,
            inputs: anytype,
            from: f64,
            to: f64,
        ) Estimate {
            const low = self.integrateSegment(8, inputs, from, to);
            const high = self.integrateSegment(16, inputs, from, to);
            return .{
                .value = high,
                .error_estimate = @abs(high - low),
            };
        }

        inline fn integrateSegment(
            comptime self: Self,
            comptime order: usize,
            inputs: anytype,
            from: f64,
            to: f64,
        ) f64 {
            const midpoint = (from + to) * 0.5;
            const half_width = (to - from) * 0.5;
            const selected = gauss.table(order);
            var weighted_sum: f64 = 0.0;
            inline for (selected.nodes, selected.weights) |node, weight| {
                const point = midpoint + half_width * node;
                weighted_sum += weight * evaluation.evaluateWithBoundVariable(
                    self.integrand,
                    inputs,
                    self.variable,
                    point,
                );
            }
            return half_width * weighted_sum;
        }
    };
}

pub fn make(
    comptime expression: ast.Expr,
    comptime options: anytype,
) AdaptiveQuadratureRule(options.max_depth) {
    const Options = @TypeOf(options);
    if (!@hasField(Options, "variable")) {
        @compileError("Bombelli adaptive quadrature options require '.variable'");
    }
    if (!@hasField(Options, "max_depth")) {
        @compileError("Bombelli adaptive quadrature options require '.max_depth'");
    }
    if (!@hasField(Options, "tolerance")) {
        @compileError("Bombelli adaptive quadrature options require '.tolerance'");
    }
    const tolerance: f64 = @floatCast(options.tolerance);
    if (!std.math.isFinite(tolerance) or tolerance <= 0.0) {
        @compileError("Bombelli adaptive quadrature tolerance must be positive and finite");
    }
    return .{
        .integrand = expression,
        .variable = @tagName(options.variable),
        .tolerance = tolerance,
    };
}

inline fn inputValue(inputs: anytype, comptime name: []const u8) f64 {
    const Inputs = @TypeOf(inputs);
    if (@typeInfo(Inputs) != .@"struct" or !@hasField(Inputs, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli adaptive quadrature eval input is missing the field '.{s}'",
            .{name},
        ));
    }
    const value = @field(inputs, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli adaptive quadrature eval field '.{s}' must be numeric",
            .{name},
        )),
    };
}
