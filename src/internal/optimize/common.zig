const std = @import("std");
const types = @import("types.zig");

pub const Scope = enum { fixed, row };

pub fn Bounds(comptime N: usize) type {
    return struct {
        lower: [N]f64,
        upper: [N]f64,
    };
}

pub fn ScaleConfiguration(comptime N: usize) type {
    return struct {
        kind: types.LeastSquaresScaling,
        values: [N]f64,
    };
}

pub fn Config(comptime scope: Scope) type {
    return struct {
        pub fn parseLoss(comptime options: anytype) types.Loss {
            if (!@hasField(@TypeOf(options), "loss")) {
                if (@hasField(@TypeOf(options), "loss_scale")) {
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares loss_scale requires an enum loss selection"
                    else
                        "Bombelli row least-squares loss_scale requires an enum loss");
                }
                return types.loss.linear();
            }
            if (@TypeOf(options.loss) == types.Loss) {
                if (@hasField(@TypeOf(options), "loss_scale")) {
                    @compileError(if (scope == .fixed)
                        "Bombelli typed least-squares losses already contain their scale"
                    else
                        "Bombelli typed row least-squares losses already contain their scale");
                }
                return options.loss;
            }

            const name = @tagName(options.loss);
            if (std.mem.eql(u8, name, "linear")) {
                if (@hasField(@TypeOf(options), "loss_scale")) {
                    @compileError(if (scope == .fixed)
                        "Bombelli linear least-squares loss does not use loss_scale"
                    else
                        "Bombelli linear row least-squares loss does not use loss_scale");
                }
                return types.loss.linear();
            }
            const scale = option(options, "loss_scale", 1.0);
            if (std.mem.eql(u8, name, "huber")) return types.loss.huber(scale);
            if (std.mem.eql(u8, name, "soft_l1")) return types.loss.softL1(scale);
            if (std.mem.eql(u8, name, "cauchy")) return types.loss.cauchy(scale);
            @compileError(if (scope == .fixed)
                "Bombelli least-squares loss must be linear, huber, soft_l1, or cauchy"
            else
                "Bombelli row least-squares loss must be linear, huber, soft_l1, or cauchy");
        }

        pub fn parseScales(
            comptime N: usize,
            comptime variables: [N][]const u8,
            comptime options: anytype,
        ) ScaleConfiguration(N) {
            var result = ScaleConfiguration(N){
                .kind = if (@hasField(@TypeOf(options), "scaling"))
                    @as(types.LeastSquaresScaling, options.scaling)
                else
                    .jacobian,
                .values = [_]f64{1.0} ** N,
            };
            if (!@hasField(@TypeOf(options), "scales")) return result;
            if (result.kind != .user and @hasField(@TypeOf(options), "scaling")) {
                @compileError(if (scope == .fixed)
                    "Bombelli explicit least-squares scales require '.scaling = .user'"
                else
                    "Bombelli explicit row least-squares scales require '.scaling = .user'");
            }
            result.kind = .user;
            validateNamedFields(N, variables, @TypeOf(options.scales), "scale");
            inline for (variables, 0..) |variable, index| {
                if (!@hasField(@TypeOf(options.scales), variable)) continue;
                const characteristic = numeric(@field(options.scales, variable), "scale");
                if (!std.math.isFinite(characteristic) or characteristic <= 0.0) {
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares parameter scales must be positive and finite"
                    else
                        "Bombelli row least-squares scales must be positive and finite");
                }
                result.values[index] = 1.0 / characteristic;
                if (!std.math.isFinite(result.values[index]) or result.values[index] <= 0.0) {
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares parameter scales are outside the representable solver range"
                    else
                        "Bombelli row least-squares scales are outside the representable range");
                }
            }
            return result;
        }

        pub fn parseBounds(
            comptime N: usize,
            comptime variables: [N][]const u8,
            comptime options: anytype,
        ) Bounds(N) {
            var result = Bounds(N){
                .lower = [_]f64{-std.math.inf(f64)} ** N,
                .upper = [_]f64{std.math.inf(f64)} ** N,
            };
            if (!@hasField(@TypeOf(options), "bounds")) return result;
            validateNamedFields(N, variables, @TypeOf(options.bounds), "bound");
            inline for (variables, 0..) |variable, index| {
                if (!@hasField(@TypeOf(options.bounds), variable)) continue;
                const bound = @field(options.bounds, variable);
                const Bound = @TypeOf(bound);
                if (@typeInfo(Bound) != .@"struct") {
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares bounds must be structs with optional lower and upper fields"
                    else
                        "Bombelli row least-squares bounds must be structs");
                }
                for (@typeInfo(Bound).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, "lower") or
                        std.mem.eql(u8, field.name, "upper")) continue;
                    if (scope == .fixed) {
                        @compileError(std.fmt.comptimePrint(
                            "Bombelli least-squares bound field '.{s}' must be 'lower' or 'upper'",
                            .{field.name},
                        ));
                    }
                    @compileError("Bombelli row least-squares bounds accept only lower and upper");
                }
                if (@hasField(Bound, "lower")) {
                    result.lower[index] = numeric(bound.lower, "lower bound");
                }
                if (@hasField(Bound, "upper")) {
                    result.upper[index] = numeric(bound.upper, "upper bound");
                }
                if (std.math.isNan(result.lower[index]) or
                    std.math.isNan(result.upper[index]) or
                    result.lower[index] == std.math.inf(f64) or
                    result.upper[index] == -std.math.inf(f64) or
                    result.lower[index] > result.upper[index])
                {
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares bounds must define a nonempty set containing finite points"
                    else
                        "Bombelli row least-squares bounds must contain a finite point");
                }
            }
            return result;
        }

        fn validateNamedFields(
            comptime N: usize,
            comptime variables: [N][]const u8,
            comptime Named: type,
            comptime description: []const u8,
        ) void {
            if (@typeInfo(Named) != .@"struct") {
                @compileError(if (scope == .fixed)
                    "Bombelli named least-squares options must be a struct"
                else
                    "Bombelli named row least-squares options must be structs");
            }
            for (@typeInfo(Named).@"struct".fields) |field| {
                var found = false;
                for (variables) |variable| {
                    if (std.mem.eql(u8, field.name, variable)) found = true;
                }
                if (!found) {
                    @compileError(std.fmt.comptimePrint(
                        if (scope == .fixed)
                            "Bombelli least-squares {s} '.{s}' does not name a variable"
                        else
                            "Bombelli row least-squares {s} '.{s}' does not name a variable",
                        .{ description, field.name },
                    ));
                }
            }
        }

        pub fn option(
            comptime options: anytype,
            comptime name: []const u8,
            default: f64,
        ) f64 {
            if (!@hasField(@TypeOf(options), name)) return default;
            return numeric(@field(options, name), name);
        }

        pub fn integerOption(
            comptime options: anytype,
            comptime name: []const u8,
            comptime default: usize,
        ) usize {
            if (!@hasField(@TypeOf(options), name)) return default;
            const value = @field(options, name);
            return switch (@typeInfo(@TypeOf(value))) {
                .int, .comptime_int => if (value < 0)
                    @compileError(if (scope == .fixed)
                        "Bombelli least-squares iteration limits must be non-negative"
                    else
                        "Bombelli row least-squares limits must be non-negative")
                else
                    @intCast(value),
                else => @compileError(if (scope == .fixed)
                    "Bombelli least-squares iteration limits must be integers"
                else
                    "Bombelli row least-squares limits must be integers"),
            };
        }

        pub fn numeric(value: anytype, comptime description: []const u8) f64 {
            return switch (@typeInfo(@TypeOf(value))) {
                .int, .comptime_int => @floatFromInt(value),
                .float, .comptime_float => @floatCast(value),
                else => @compileError(std.fmt.comptimePrint(
                    if (scope == .fixed)
                        "Bombelli least-squares {s} must be numeric"
                    else
                        "Bombelli row least-squares {s} must be numeric",
                    .{description},
                )),
            };
        }

        pub fn validatePositiveFinite(value: f64, comptime name: []const u8) void {
            if (!std.math.isFinite(value) or value <= 0.0) {
                @compileError(std.fmt.comptimePrint(
                    if (scope == .fixed)
                        "Bombelli least-squares {s} must be positive and finite"
                    else
                        "Bombelli row least-squares {s} must be positive and finite",
                    .{name},
                ));
            }
        }

        pub fn validateNonnegativeFinite(value: f64, comptime name: []const u8) void {
            if (!std.math.isFinite(value) or value < 0.0) {
                @compileError(std.fmt.comptimePrint(
                    if (scope == .fixed)
                        "Bombelli least-squares {s} must be non-negative and finite"
                    else
                        "Bombelli row least-squares {s} must be non-negative and finite",
                    .{name},
                ));
            }
        }
    };
}

pub fn projectedGradientDirection(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    scales: [N]f64,
    bounds: Bounds(N),
) [N]f64 {
    var result: [N]f64 = undefined;
    for (0..N) |index| {
        result[index] = std.math.clamp(
            values[index] - gradient[index] / scales[index] / scales[index],
            bounds.lower[index],
            bounds.upper[index],
        ) - values[index];
    }
    return result;
}

pub fn projectedOptimality(
    comptime N: usize,
    values: [N]f64,
    gradient: [N]f64,
    scales: [N]f64,
    bounds: Bounds(N),
) f64 {
    var maximum: f64 = 0.0;
    for (0..N) |index| {
        const scaled_gradient = @abs(gradient[index] / scales[index]);
        if (bounds.lower[index] == -std.math.inf(f64) and
            bounds.upper[index] == std.math.inf(f64))
        {
            maximum = @max(maximum, scaled_gradient);
            continue;
        }
        const feasible_distance = if (gradient[index] > 0.0)
            values[index] - bounds.lower[index]
        else if (gradient[index] < 0.0)
            bounds.upper[index] - values[index]
        else
            0.0;
        maximum = @max(maximum, @min(
            scaled_gradient,
            feasible_distance * scales[index],
        ));
    }
    return maximum;
}

pub fn withinBounds(
    comptime N: usize,
    values: [N]f64,
    bounds: Bounds(N),
) bool {
    for (0..N) |index| {
        if (values[index] < bounds.lower[index] or values[index] > bounds.upper[index]) {
            return false;
        }
    }
    return true;
}

pub fn project(
    comptime N: usize,
    values: [N]f64,
    bounds: Bounds(N),
) [N]f64 {
    var result: [N]f64 = undefined;
    for (0..N) |index| {
        result[index] = std.math.clamp(values[index], bounds.lower[index], bounds.upper[index]);
    }
    return result;
}

pub fn increaseDamping(damping: *f64, nu: *f64, maximum: f64) void {
    damping.* = @min(damping.* * nu.*, maximum);
    nu.* = @min(nu.* * 2.0, @sqrt(std.math.floatMax(f64)));
}
