const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");

const BinaryOperation = enum { add, sub, mul, div };
const Function = enum { sin, cos, exp, ln };

pub fn simplify(comptime expression: ast.Expr) ast.Expr {
    var current = expression;
    inline for (0..32) |_| {
        const next = simplifyOnce(current);
        if (ast.equal(current, current.root, next, next.root)) return next;
        current = next;
    }
    return current;
}

fn simplifyOnce(comptime expression: ast.Expr) ast.Expr {
    var builder = build.Builder{};
    var context = Context{
        .builder = &builder,
        .expression = expression,
    };
    const root = context.simplifyNode(expression.root);
    return builder.finish(root, expression.source);
}

const Context = struct {
    builder: *build.Builder,
    expression: ast.Expr,
    cache: [ast.construction_node_limit]ast.NodeId =
        [_]ast.NodeId{ast.invalid_node} ** ast.construction_node_limit,

    fn simplifyNode(self: *Context, id: ast.NodeId) ast.NodeId {
        const index: usize = @intCast(id);
        if (self.cache[index] != ast.invalid_node) return self.cache[index];

        const result = switch (self.expression.node(id)) {
            .integer => |value| self.builder.integer(value),
            .float => |value| self.builder.float(value),
            .symbol => |name| self.builder.symbol(name),
            .add => |binary| simplifyAdd(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
            ),
            .sub => |binary| simplifySub(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
            ),
            .mul => |binary| simplifyMul(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
            ),
            .div => |binary| simplifyDiv(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
            ),
            .pow => |power| simplifyPower(
                self.builder,
                self.simplifyNode(power.base),
                power.exponent,
            ),
            .negate => |child| simplifyNegate(
                self.builder,
                self.simplifyNode(child),
            ),
            .sin => |child| simplifyFunction(
                self.builder,
                .sin,
                self.simplifyNode(child),
            ),
            .cos => |child| simplifyFunction(
                self.builder,
                .cos,
                self.simplifyNode(child),
            ),
            .exp => |child| simplifyFunction(
                self.builder,
                .exp,
                self.simplifyNode(child),
            ),
            .ln => |child| simplifyFunction(
                self.builder,
                .ln,
                self.simplifyNode(child),
            ),
        };

        self.cache[index] = result;
        return result;
    }
};

fn simplifyAdd(builder: *build.Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(builder, left)) return right;
    if (isZero(builder, right)) return left;
    if (foldBinary(builder, .add, left, right)) |folded| return folded;
    return builder.add(left, right);
}

fn simplifySub(builder: *build.Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(builder, right)) return left;
    if (left == right) return builder.integer(0);
    if (foldBinary(builder, .sub, left, right)) |folded| return folded;
    if (isZero(builder, left)) return simplifyNegate(builder, right);
    return builder.sub(left, right);
}

fn simplifyMul(builder: *build.Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    var factors: [ast.construction_node_limit]ast.NodeId = undefined;
    var factor_count: usize = 0;
    collectFactors(builder, left, &factors, &factor_count);
    collectFactors(builder, right, &factors, &factor_count);

    var coefficient: ?ast.NodeId = null;
    var symbolic_count: usize = 0;
    for (factors[0..factor_count]) |factor| {
        if (isZero(builder, factor)) return builder.integer(0);
        if (isOne(builder, factor)) continue;

        if (isConstant(builder, factor)) {
            coefficient = if (coefficient) |current|
                foldBinary(builder, .mul, current, factor).?
            else
                factor;
        } else {
            factors[symbolic_count] = factor;
            symbolic_count += 1;
        }
    }

    var index: usize = 1;
    while (index < symbolic_count) : (index += 1) {
        const factor = factors[index];
        var insertion = index;
        while (insertion > 0 and less(builder, factor, factors[insertion - 1])) {
            factors[insertion] = factors[insertion - 1];
            insertion -= 1;
        }
        factors[insertion] = factor;
    }

    var product: ?ast.NodeId = if (coefficient) |value|
        if (isOne(builder, value)) null else value
    else
        null;
    for (factors[0..symbolic_count]) |factor| {
        product = if (product) |current|
            builder.mul(current, factor)
        else
            factor;
    }

    return product orelse builder.integer(1);
}

fn collectFactors(
    builder: *const build.Builder,
    id: ast.NodeId,
    factors: *[ast.construction_node_limit]ast.NodeId,
    count: *usize,
) void {
    switch (builder.node(id)) {
        .mul => |binary| {
            collectFactors(builder, binary.left, factors, count);
            collectFactors(builder, binary.right, factors, count);
        },
        else => {
            factors[count.*] = id;
            count.* += 1;
        },
    }
}

fn simplifyDiv(builder: *build.Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(builder, left)) return builder.integer(0);
    if (isOne(builder, right)) return left;
    if (foldBinary(builder, .div, left, right)) |folded| return folded;
    return builder.div(left, right);
}

fn simplifyPower(builder: *build.Builder, base: ast.NodeId, exponent: u32) ast.NodeId {
    if (exponent == 0) return builder.integer(1);
    if (exponent == 1) return base;

    return switch (builder.node(base)) {
        .integer => |value| builder.integer(integerPower(value, exponent)),
        .float => |value| normalizedFloat(builder, floatPower(value, exponent)),
        else => builder.power(base, exponent),
    };
}

fn simplifyNegate(builder: *build.Builder, child: ast.NodeId) ast.NodeId {
    return switch (builder.node(child)) {
        .integer => |value| builder.integer(-value),
        .float => |value| normalizedFloat(builder, -value),
        .negate => |grandchild| grandchild,
        else => builder.negate(child),
    };
}

fn simplifyFunction(
    builder: *build.Builder,
    comptime function: Function,
    child: ast.NodeId,
) ast.NodeId {
    if (constantValue(builder, child)) |value| {
        return normalizedFloat(builder, switch (function) {
            .sin => @sin(value),
            .cos => @cos(value),
            .exp => @exp(value),
            .ln => @log(value),
        });
    }

    return switch (function) {
        .sin => builder.sine(child),
        .cos => builder.cosine(child),
        .exp => builder.exponential(child),
        .ln => builder.logarithm(child),
    };
}

fn foldBinary(
    builder: *build.Builder,
    comptime operation: BinaryOperation,
    left: ast.NodeId,
    right: ast.NodeId,
) ?ast.NodeId {
    const left_node = builder.node(left);
    const right_node = builder.node(right);

    if (left_node == .integer and right_node == .integer) {
        const a = left_node.integer;
        const b = right_node.integer;
        return switch (operation) {
            .add => builder.integer(a + b),
            .sub => builder.integer(a - b),
            .mul => builder.integer(a * b),
            .div => if (b == 0)
                null
            else if (@rem(a, b) == 0)
                builder.integer(@divExact(a, b))
            else
                normalizedFloat(
                    builder,
                    @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b)),
                ),
        };
    }

    const a = constantValue(builder, left) orelse return null;
    const b = constantValue(builder, right) orelse return null;
    if (operation == .div and b == 0.0) return null;
    return normalizedFloat(builder, switch (operation) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    });
}

fn constantValue(builder: *const build.Builder, id: ast.NodeId) ?f64 {
    return switch (builder.node(id)) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => null,
    };
}

fn isConstant(builder: *const build.Builder, id: ast.NodeId) bool {
    return constantValue(builder, id) != null;
}

fn isZero(builder: *const build.Builder, id: ast.NodeId) bool {
    return switch (builder.node(id)) {
        .integer => |value| value == 0,
        .float => |value| value == 0.0,
        else => false,
    };
}

fn isOne(builder: *const build.Builder, id: ast.NodeId) bool {
    return switch (builder.node(id)) {
        .integer => |value| value == 1,
        .float => |value| value == 1.0,
        else => false,
    };
}

fn normalizedFloat(builder: *build.Builder, value: f64) ast.NodeId {
    if (value == 0.0) return builder.integer(0);
    if (value == 1.0) return builder.integer(1);
    return builder.float(value);
}

fn integerPower(base: i64, exponent: u32) i64 {
    var result: i64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining != 0) : (remaining /= 2) {
        if (remaining % 2 == 1) result *= factor;
        if (remaining > 1) factor *= factor;
    }
    return result;
}

fn floatPower(base: f64, exponent: u32) f64 {
    var result: f64 = 1.0;
    var factor = base;
    var remaining = exponent;
    while (remaining != 0) : (remaining /= 2) {
        if (remaining % 2 == 1) result *= factor;
        if (remaining > 1) factor *= factor;
    }
    return result;
}

fn less(builder: *const build.Builder, left: ast.NodeId, right: ast.NodeId) bool {
    if (left == right) return false;

    const left_node = builder.node(left);
    const right_node = builder.node(right);
    const left_rank = rank(left_node);
    const right_rank = rank(right_node);
    if (left_rank != right_rank) return left_rank < right_rank;

    return switch (left_node) {
        .integer => |value| switch (right_node) {
            .integer => value < right_node.integer,
            .float => @as(f64, @floatFromInt(value)) < right_node.float,
            else => false,
        },
        .float => |value| switch (right_node) {
            .integer => value < @as(f64, @floatFromInt(right_node.integer)),
            .float => value < right_node.float,
            else => false,
        },
        .symbol => |name| std.mem.order(u8, name, right_node.symbol) == .lt,
        .pow => |power| less(builder, power.base, right_node.pow.base),
        .mul => |binary| lessBinary(builder, binary, right_node.mul),
        .sin => |child| less(builder, child, right_node.sin),
        .cos => |child| less(builder, child, right_node.cos),
        .exp => |child| less(builder, child, right_node.exp),
        .ln => |child| less(builder, child, right_node.ln),
        .negate => |child| less(builder, child, right_node.negate),
        .add => |binary| lessBinary(builder, binary, right_node.add),
        .sub => |binary| lessBinary(builder, binary, right_node.sub),
        .div => |binary| lessBinary(builder, binary, right_node.div),
    };
}

fn lessBinary(builder: *const build.Builder, left: ast.Binary, right: ast.Binary) bool {
    if (left.left == right.left) return less(builder, left.right, right.right);
    return less(builder, left.left, right.left);
}

fn rank(node: ast.Node) u8 {
    return switch (node) {
        .integer, .float => 0,
        .symbol => 1,
        .pow => 2,
        .mul => 3,
        .sin => 4,
        .cos => 5,
        .exp => 6,
        .ln => 7,
        .negate => 8,
        .add => 9,
        .sub => 10,
        .div => 11,
    };
}
