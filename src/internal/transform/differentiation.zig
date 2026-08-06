const std = @import("std");
const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");
const exact = @import("../core/exact.zig");

pub fn differentiate(comptime expression: ast.Expr, comptime variable: []const u8) ast.Expr {
    var builder = build.Builder{};
    var clone_cache =
        [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var derivative_cache =
        [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var context = Context{
        .builder = &builder,
        .expression = expression,
        .variable = variable,
        .clone_cache = &clone_cache,
        .derivative_cache = &derivative_cache,
    };
    const root = context.derivative(expression.root);
    return builder.finish(root, expression.source);
}

const Context = struct {
    builder: *build.Builder,
    expression: ast.Expr,
    variable: []const u8,
    clone_cache: []ast.NodeId,
    derivative_cache: []ast.NodeId,

    fn derivative(self: *Context, id: ast.NodeId) ast.NodeId {
        const index: usize = @intCast(id);
        if (self.derivative_cache[index] != ast.invalid_node) {
            return self.derivative_cache[index];
        }

        const result = switch (self.expression.node(id)) {
            .integer, .rational, .float, .constant => self.builder.integer(0),
            .symbol => |name| self.builder.integer(
                if (std.mem.eql(u8, name, self.variable)) 1 else 0,
            ),
            .add_nary => |operands| blk: {
                var derivatives: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |child, operand_index| {
                    derivatives[operand_index] = self.derivative(child);
                }
                break :blk self.builder.addNary(derivatives[0..operands.len]);
            },
            .sub => |binary| self.builder.sub(
                self.derivative(binary.left),
                self.derivative(binary.right),
            ),
            .mul_nary => |operands| blk: {
                var terms: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |_, derivative_index| {
                    var factors: [ast.construction_node_limit]ast.NodeId = undefined;
                    for (operands, 0..) |child, factor_index| {
                        factors[factor_index] = if (factor_index == derivative_index)
                            self.derivative(child)
                        else
                            self.clone(child);
                    }
                    terms[derivative_index] = self.builder.mulNary(
                        factors[0..operands.len],
                    );
                }
                break :blk self.builder.addNary(terms[0..operands.len]);
            },
            .div => |binary| blk: {
                const left_derivative = self.derivative(binary.left);
                const right_copy = self.clone(binary.right);
                const left_copy = self.clone(binary.left);
                const right_derivative = self.derivative(binary.right);
                const first = self.builder.mul(left_derivative, right_copy);
                const second = self.builder.mul(left_copy, right_derivative);
                const numerator = self.builder.sub(first, second);
                const denominator = self.builder.power(right_copy, 2);
                break :blk self.builder.div(numerator, denominator);
            },
            .pow => |power| blk: {
                if (power.exponent.isZero()) break :blk self.builder.integer(0);
                const coefficient = self.builder.rational(power.exponent);
                const base = self.clone(power.base);
                const reduced_exponent = power.exponent.sub(
                    exact.Rational.fromInteger(1),
                ) catch @compileError(
                    "Bombelli derivative exponent exceeds fixed-width rational range",
                );
                const reduced_power = self.builder.power(base, reduced_exponent);
                const base_derivative = self.derivative(power.base);
                const coefficient_times_power = self.builder.mul(
                    coefficient,
                    reduced_power,
                );
                break :blk self.builder.mul(
                    coefficient_times_power,
                    base_derivative,
                );
            },
            .unary => |unary| unary_block: {
                const child = unary.child;
                break :unary_block switch (unary.op) {
                    .negate => self.builder.negate(self.derivative(child)),
                    .sin => blk: {
                        const child_copy = self.clone(child);
                        const cosine = self.builder.cosine(child_copy);
                        break :blk self.builder.mul(cosine, self.derivative(child));
                    },
                    .cos => blk: {
                        const child_copy = self.clone(child);
                        const sine = self.builder.sine(child_copy);
                        const negative_sine = self.builder.negate(sine);
                        break :blk self.builder.mul(negative_sine, self.derivative(child));
                    },
                    .tan => blk: {
                        const cosine = self.builder.cosine(self.clone(child));
                        const denominator = self.builder.power(cosine, 2);
                        break :blk self.builder.div(self.derivative(child), denominator);
                    },
                    .asin => blk: {
                        const child_copy = self.clone(child);
                        const square = self.builder.power(child_copy, 2);
                        const radicand = self.builder.sub(
                            self.builder.integer(1),
                            square,
                        );
                        const denominator = self.builder.power(
                            radicand,
                            exact.Rational{ .numerator = 1, .denominator = 2 },
                        );
                        break :blk self.builder.div(
                            self.derivative(child),
                            denominator,
                        );
                    },
                    .acos => blk: {
                        const child_copy = self.clone(child);
                        const square = self.builder.power(child_copy, 2);
                        const radicand = self.builder.sub(
                            self.builder.integer(1),
                            square,
                        );
                        const denominator = self.builder.power(
                            radicand,
                            exact.Rational{ .numerator = 1, .denominator = 2 },
                        );
                        break :blk self.builder.div(
                            self.builder.negate(self.derivative(child)),
                            denominator,
                        );
                    },
                    .atan => blk: {
                        const child_copy = self.clone(child);
                        const square = self.builder.power(child_copy, 2);
                        const denominator = self.builder.add(self.builder.integer(1), square);
                        break :blk self.builder.div(self.derivative(child), denominator);
                    },
                    .sinh => blk: {
                        const hyperbolic_cosine = self.builder.hyperbolicCosine(
                            self.clone(child),
                        );
                        break :blk self.builder.mul(
                            hyperbolic_cosine,
                            self.derivative(child),
                        );
                    },
                    .cosh => blk: {
                        const hyperbolic_sine = self.builder.hyperbolicSine(
                            self.clone(child),
                        );
                        break :blk self.builder.mul(
                            hyperbolic_sine,
                            self.derivative(child),
                        );
                    },
                    .tanh => blk: {
                        const hyperbolic_cosine = self.builder.hyperbolicCosine(
                            self.clone(child),
                        );
                        const denominator = self.builder.power(
                            hyperbolic_cosine,
                            2,
                        );
                        break :blk self.builder.div(
                            self.derivative(child),
                            denominator,
                        );
                    },
                    .abs => blk: {
                        const child_copy = self.clone(child);
                        const absolute = self.builder.absolute(child_copy);
                        const slope = self.builder.div(child_copy, absolute);
                        break :blk self.builder.mul(slope, self.derivative(child));
                    },
                    .exp => blk: {
                        const child_copy = self.clone(child);
                        const exponential = self.builder.exponential(child_copy);
                        break :blk self.builder.mul(exponential, self.derivative(child));
                    },
                    .ln => self.builder.div(
                        self.derivative(child),
                        self.clone(child),
                    ),
                    .log2 => blk: {
                        const logarithm_of_base = self.builder.logarithm(
                            self.builder.integer(2),
                        );
                        const denominator = self.builder.mul(
                            self.clone(child),
                            logarithm_of_base,
                        );
                        break :blk self.builder.div(
                            self.derivative(child),
                            denominator,
                        );
                    },
                    .log10 => blk: {
                        const logarithm_of_base = self.builder.logarithm(
                            self.builder.integer(10),
                        );
                        const denominator = self.builder.mul(
                            self.clone(child),
                            logarithm_of_base,
                        );
                        break :blk self.builder.div(
                            self.derivative(child),
                            denominator,
                        );
                    },
                };
            },
            .atan2 => |binary| blk: {
                const y = self.clone(binary.left);
                const x = self.clone(binary.right);
                const x_times_dy = self.builder.mul(
                    x,
                    self.derivative(binary.left),
                );
                const y_times_dx = self.builder.mul(
                    y,
                    self.derivative(binary.right),
                );
                const numerator = self.builder.sub(
                    x_times_dy,
                    y_times_dx,
                );
                const denominator = self.builder.add(
                    self.builder.power(x, 2),
                    self.builder.power(y, 2),
                );
                break :blk self.builder.div(numerator, denominator);
            },
            .hypot => |binary| blk: {
                const x = self.clone(binary.left);
                const y = self.clone(binary.right);
                const numerator = self.builder.add(
                    self.builder.mul(
                        x,
                        self.derivative(binary.left),
                    ),
                    self.builder.mul(
                        y,
                        self.derivative(binary.right),
                    ),
                );
                const denominator = self.builder.hypotenuse(x, y);
                break :blk self.builder.div(numerator, denominator);
            },
        };

        self.derivative_cache[index] = result;
        return result;
    }

    fn clone(self: *Context, id: ast.NodeId) ast.NodeId {
        const index: usize = @intCast(id);
        if (self.clone_cache[index] != ast.invalid_node) {
            return self.clone_cache[index];
        }

        const result = switch (self.expression.node(id)) {
            .integer => |value| self.builder.integer(value),
            .rational => |value| self.builder.rational(value),
            .float => |value| self.builder.float(value),
            .constant => |value| self.builder.constant(value),
            .symbol => |name| self.builder.symbol(name),
            .add_nary => |operands| blk: {
                var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |child, operand_index| {
                    cloned[operand_index] = self.clone(child);
                }
                break :blk self.builder.addNary(cloned[0..operands.len]);
            },
            .sub => |binary| self.builder.sub(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .mul_nary => |operands| blk: {
                var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |child, operand_index| {
                    cloned[operand_index] = self.clone(child);
                }
                break :blk self.builder.mulNary(cloned[0..operands.len]);
            },
            .div => |binary| self.builder.div(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .pow => |power| self.builder.power(
                self.clone(power.base),
                power.exponent,
            ),
            .unary => |unary| self.builder.unary(
                unary.op,
                self.clone(unary.child),
            ),
            .atan2 => |binary| self.builder.arctangent2(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .hypot => |binary| self.builder.hypotenuse(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
        };

        self.clone_cache[index] = result;
        return result;
    }
};
