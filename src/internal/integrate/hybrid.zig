const std = @import("std");
const ast = @import("../../expression.zig");
const dependsOn = @import("../transform/dependency.zig").dependsOn;
const evaluation = @import("../runtime/evaluation.zig");
const gauss = @import("gauss_legendre.zig");
const options_validation = @import("../core/options.zig");
const types = @import("types.zig");

pub fn HybridIntegral(comptime order: usize) type {
    return struct {
        closed_portion: ast.Expr,
        remainder_rule: gauss.QuadratureRule(order),
        variable: []const u8,
        bounds: ?types.IntegralBounds,

        const Self = @This();

        pub inline fn eval(comptime self: Self, inputs: anytype) f64 {
            const from = if (self.bounds) |bounds|
                bounds.from.eval(inputs)
            else
                inputValue(inputs, "from");
            const to = if (self.bounds) |bounds|
                bounds.to.eval(inputs)
            else
                inputValue(inputs, "to");
            const closed_value = if (self.bounds != null)
                self.closed_portion.eval(inputs)
            else
                evaluation.evaluateWithBoundVariable(
                    self.closed_portion,
                    inputs,
                    self.variable,
                    to,
                ) -
                    evaluation.evaluateWithBoundVariable(
                        self.closed_portion,
                        inputs,
                        self.variable,
                        from,
                    );
            return closed_value +
                self.remainder_rule.evalRange(inputs, from, to);
        }

        /// Differentiates the compiled fixed approximation. Parameter-dependent
        /// bounds are rejected until explicit Leibniz terms are requested.
        pub fn diff(
            comptime self: Self,
            comptime parameter: anytype,
        ) HybridIntegral(order) {
            const name = @tagName(parameter);
            if (self.bounds) |bounds| {
                if (dependsOn(bounds.from, name) or dependsOn(bounds.to, name)) {
                    @compileError("Bombelli hybrid integration has parameter-dependent bounds; explicit Leibniz boundary terms are required");
                }
            } else if (std.mem.eql(u8, name, "from") or
                std.mem.eql(u8, name, "to"))
            {
                @compileError("Bombelli hybrid integration runtime endpoints require explicit Leibniz boundary terms");
            }
            return .{
                .closed_portion = self.closed_portion.diff(parameter).simplify(),
                .remainder_rule = self.remainder_rule.diff(parameter),
                .variable = self.variable,
                .bounds = self.bounds,
            };
        }
    };
}

pub fn compilePartial(
    comptime partial: anytype,
    comptime options: anytype,
) HybridIntegral(options.order) {
    options_validation.requireField(
        @TypeOf(options),
        "rule",
        "Bombelli hybrid integration options require '.rule'",
    );
    options_validation.requireField(
        @TypeOf(options),
        "order",
        "Bombelli hybrid integration options require '.order'",
    );
    if (!std.mem.eql(u8, @tagName(options.rule), "gauss_legendre")) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli does not support the hybrid quadrature rule '.{s}'",
            .{@tagName(options.rule)},
        ));
    }
    return .{
        .closed_portion = partial.closed_portion,
        .remainder_rule = .{
            .integrand = partial.remainder.integrand,
            .variable = partial.remainder.variable,
        },
        .variable = partial.remainder.variable,
        .bounds = partial.remainder.bounds,
    };
}

inline fn inputValue(inputs: anytype, comptime name: []const u8) f64 {
    const Inputs = @TypeOf(inputs);
    if (@typeInfo(Inputs) != .@"struct" or !@hasField(Inputs, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli compiled integral input is missing the field '.{s}'",
            .{name},
        ));
    }
    const value = @field(inputs, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli compiled integral field '.{s}' must be numeric",
            .{name},
        )),
    };
}
