const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");

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
            .integer, .float => self.builder.integer(0),
            .symbol => |name| self.builder.integer(
                if (std.mem.eql(u8, name, self.variable)) 1 else 0,
            ),
            .negate => |child| self.builder.negate(self.derivative(child)),
            .add => |binary| self.builder.add(
                self.derivative(binary.left),
                self.derivative(binary.right),
            ),
            .sub => |binary| self.builder.sub(
                self.derivative(binary.left),
                self.derivative(binary.right),
            ),
            .mul => |binary| blk: {
                const left_derivative = self.derivative(binary.left);
                const right_copy = self.clone(binary.right);
                const left_copy = self.clone(binary.left);
                const right_derivative = self.derivative(binary.right);
                const first = self.builder.mul(left_derivative, right_copy);
                const second = self.builder.mul(left_copy, right_derivative);
                break :blk self.builder.add(first, second);
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
                if (power.exponent == 0) break :blk self.builder.integer(0);
                const coefficient = self.builder.integer(@intCast(power.exponent));
                const base = self.clone(power.base);
                const reduced_power = self.builder.power(base, power.exponent - 1);
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
            .sin => |child| blk: {
                const child_copy = self.clone(child);
                const cosine = self.builder.cosine(child_copy);
                break :blk self.builder.mul(cosine, self.derivative(child));
            },
            .cos => |child| blk: {
                const child_copy = self.clone(child);
                const sine = self.builder.sine(child_copy);
                const negative_sine = self.builder.negate(sine);
                break :blk self.builder.mul(negative_sine, self.derivative(child));
            },
            .exp => |child| blk: {
                const child_copy = self.clone(child);
                const exponential = self.builder.exponential(child_copy);
                break :blk self.builder.mul(exponential, self.derivative(child));
            },
            .ln => |child| self.builder.div(
                self.derivative(child),
                self.clone(child),
            ),
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
            .float => |value| self.builder.float(value),
            .symbol => |name| self.builder.symbol(name),
            .add => |binary| self.builder.add(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .sub => |binary| self.builder.sub(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .mul => |binary| self.builder.mul(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .div => |binary| self.builder.div(
                self.clone(binary.left),
                self.clone(binary.right),
            ),
            .pow => |power| self.builder.power(
                self.clone(power.base),
                power.exponent,
            ),
            .negate => |child| self.builder.negate(self.clone(child)),
            .sin => |child| self.builder.sine(self.clone(child)),
            .cos => |child| self.builder.cosine(self.clone(child)),
            .exp => |child| self.builder.exponential(self.clone(child)),
            .ln => |child| self.builder.logarithm(self.clone(child)),
        };

        self.clone_cache[index] = result;
        return result;
    }
};
