const std = @import("std");
const ast = @import("../../expression.zig");
const limits = @import("../core/limits.zig");
const options_validation = @import("../core/options.zig");
const evaluation = @import("../runtime/evaluation.zig");

pub const QuadratureKind = enum {
    gauss_legendre,
};

pub fn QuadratureRule(comptime N: usize) type {
    validateOrder(N);
    return struct {
        integrand: ast.Expr,
        variable: []const u8,

        pub const order = N;
        pub const selected_table = table(N);
        const Self = @This();

        pub inline fn eval(comptime self: Self, inputs: anytype) f64 {
            comptime evaluation.validateInputFields(
                @TypeOf(inputs),
                &.{self.integrand.nodes},
                &.{ "from", "to" },
                &.{self.variable},
                "quadrature eval",
            );
            const from = inputValue(inputs, "from");
            const to = inputValue(inputs, "to");
            return self.evalRange(inputs, from, to);
        }

        pub inline fn evalRange(
            comptime self: Self,
            inputs: anytype,
            from: f64,
            to: f64,
        ) f64 {
            const midpoint = (from + to) * 0.5;
            const half_width = (to - from) * 0.5;
            const selected = table(N);
            var weighted_sum: f64 = 0.0;
            if (comptime evaluation.prefersVectorLanes(self.integrand)) {
                const lane_count = @min(N, evaluation.batch_vector_length);
                const Lanes = @Vector(lane_count, f64);
                const midpoint_lanes: Lanes = @splat(midpoint);
                const half_width_lanes: Lanes = @splat(half_width);
                inline for (0..N / lane_count) |chunk| {
                    const start = chunk * lane_count;
                    const nodes: Lanes =
                        selected.nodes[start..][0..lane_count].*;
                    const weights: Lanes =
                        selected.weights[start..][0..lane_count].*;
                    const points = midpoint_lanes + half_width_lanes * nodes;
                    const samples = evaluation.evaluateWithBoundVariableLanes(
                        lane_count,
                        self.integrand,
                        inputs,
                        self.variable,
                        points,
                    );
                    weighted_sum += @reduce(.Add, weights * samples);
                }
            } else {
                // LLVM already SLP-vectorizes useful pieces of this fully
                // unrolled form. Explicit vector transcendental intrinsics
                // regress on targets without a vector math implementation.
                inline for (selected.nodes, selected.weights) |node, weight| {
                    const point = midpoint + half_width * node;
                    weighted_sum += weight *
                        evaluation.evaluateWithBoundVariable(
                            self.integrand,
                            inputs,
                            self.variable,
                            point,
                        );
                }
            }
            return half_width * weighted_sum;
        }

        /// Differentiates the fixed quadrature approximation with respect to a
        /// parameter. This is not, by itself, a proof that differentiation may
        /// be exchanged with the underlying mathematical integral.
        pub fn diff(
            comptime self: Self,
            comptime parameter: anytype,
        ) QuadratureRule(N) {
            const name = @tagName(parameter);
            if (std.mem.eql(u8, name, self.variable)) {
                @compileError("Bombelli cannot differentiate a quadrature rule with respect to its bound variable");
            }
            if (std.mem.eql(u8, name, "from") or std.mem.eql(u8, name, "to")) {
                @compileError("Bombelli quadrature endpoints are runtime inputs; parameter-dependent bounds require explicit Leibniz terms");
            }
            return .{
                .integrand = self.integrand.diff(parameter).simplify(),
                .variable = self.variable,
            };
        }

        pub fn emit(
            comptime self: Self,
            comptime options: anytype,
        ) []const u8 {
            @setEvalBranchQuota(limits.eval_branch.rational);
            return @import("../codegen/emit.zig").emitFixedQuadrature(
                self,
                options,
            );
        }
    };
}

pub fn make(
    comptime expression: ast.Expr,
    comptime options: anytype,
) QuadratureRule(options.order) {
    const Options = @TypeOf(options);
    options_validation.requireField(
        Options,
        "variable",
        "Bombelli quadrature options require '.variable'",
    );
    options_validation.requireField(
        Options,
        "rule",
        "Bombelli quadrature options require '.rule'",
    );
    options_validation.requireField(
        Options,
        "order",
        "Bombelli quadrature options require '.order'",
    );
    if (!std.mem.eql(u8, @tagName(options.rule), "gauss_legendre")) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli does not support the quadrature rule '.{s}'",
            .{@tagName(options.rule)},
        ));
    }
    validateOrder(options.order);
    return .{
        .integrand = expression,
        .variable = @tagName(options.variable),
    };
}

pub fn Table(comptime N: usize) type {
    return struct {
        nodes: [N]f64,
        weights: [N]f64,
    };
}

pub fn table(comptime N: usize) Table(N) {
    validateOrder(N);
    return switch (N) {
        4 => .{
            .nodes = .{
                -0.86113631159405257,
                -0.33998104358485626,
                0.33998104358485626,
                0.86113631159405257,
            },
            .weights = .{
                0.34785484513745357,
                0.65214515486254665,
                0.65214515486254665,
                0.34785484513745357,
            },
        },
        8 => .{
            .nodes = .{
                -0.96028985649753618,
                -0.79666647741362673,
                -0.52553240991632899,
                -0.18343464249564981,
                0.18343464249564981,
                0.52553240991632899,
                0.79666647741362673,
                0.96028985649753618,
            },
            .weights = .{
                0.10122853629037637,
                0.22238103445337418,
                0.31370664587788744,
                0.36268378337836205,
                0.36268378337836205,
                0.31370664587788744,
                0.22238103445337418,
                0.10122853629037637,
            },
        },
        16 => .{
            .nodes = .{
                -0.98940093499164994,
                -0.9445750230732326,
                -0.86563120238783176,
                -0.755404408355003,
                -0.61787624440264377,
                -0.45801677765722737,
                -0.28160355077925892,
                -0.095012509837637441,
                0.095012509837637441,
                0.28160355077925892,
                0.45801677765722737,
                0.61787624440264377,
                0.755404408355003,
                0.86563120238783176,
                0.9445750230732326,
                0.98940093499164994,
            },
            .weights = .{
                0.027152459411753902,
                0.062253523938647824,
                0.095158511682492716,
                0.12462897125553399,
                0.14959598881657671,
                0.16915651939500265,
                0.18260341504492361,
                0.1894506104550685,
                0.1894506104550685,
                0.18260341504492361,
                0.16915651939500265,
                0.14959598881657671,
                0.12462897125553399,
                0.095158511682492716,
                0.062253523938647824,
                0.027152459411753902,
            },
        },
        32 => .{
            .nodes = .{
                -0.99726386184948157,
                -0.98561151154526827,
                -0.96476225558750639,
                -0.93490607593773967,
                -0.89632115576605209,
                -0.84936761373256997,
                -0.79448379596794239,
                -0.73218211874028971,
                -0.66304426693021523,
                -0.5877157572407623,
                -0.50689990893222936,
                -0.42135127613063533,
                -0.33186860228212767,
                -0.23928736225213706,
                -0.14447196158279652,
                -0.048307665687738324,
                0.048307665687738324,
                0.14447196158279652,
                0.23928736225213706,
                0.33186860228212767,
                0.42135127613063533,
                0.50689990893222936,
                0.5877157572407623,
                0.66304426693021523,
                0.73218211874028971,
                0.79448379596794239,
                0.84936761373256997,
                0.89632115576605209,
                0.93490607593773967,
                0.96476225558750639,
                0.98561151154526827,
                0.99726386184948157,
            },
            .weights = .{
                0.0070186100094691405,
                0.016274394730906284,
                0.02539206530926193,
                0.034273862913021563,
                0.042835898022226898,
                0.050998059262376265,
                0.058684093478535621,
                0.065822222776361697,
                0.072345794108848435,
                0.078193895787070269,
                0.08331192422694686,
                0.087652093004403894,
                0.091173878695763919,
                0.093844399080804483,
                0.095638720079274847,
                0.096540088514727854,
                0.096540088514727854,
                0.095638720079274847,
                0.093844399080804483,
                0.091173878695763919,
                0.087652093004403894,
                0.08331192422694686,
                0.078193895787070269,
                0.072345794108848435,
                0.065822222776361697,
                0.058684093478535621,
                0.050998059262376265,
                0.042835898022226898,
                0.034273862913021563,
                0.02539206530926193,
                0.016274394730906284,
                0.0070186100094691405,
            },
        },
        else => unreachable,
    };
}

fn validateOrder(comptime order: usize) void {
    switch (order) {
        4, 8, 16, 32 => {},
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli Gauss-Legendre quadrature supports orders 4, 8, 16, and 32; received {d}",
            .{order},
        )),
    }
}

inline fn inputValue(inputs: anytype, comptime name: []const u8) f64 {
    const Inputs = @TypeOf(inputs);
    if (@typeInfo(Inputs) != .@"struct" or !@hasField(Inputs, name)) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli quadrature eval input is missing the field '.{s}'",
            .{name},
        ));
    }
    const value = @field(inputs, name);
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError(std.fmt.comptimePrint(
            "Bombelli quadrature eval field '.{s}' must be numeric",
            .{name},
        )),
    };
}
