const std = @import("std");
const ast = @import("ast.zig");

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
    var result = ast.Expr.init(expression.source);
    result.root = simplifyNode(&result, expression, expression.root);
    return result;
}

fn simplifyNode(result: *ast.Expr, comptime expression: ast.Expr, id: ast.NodeId) ast.NodeId {
    return switch (expression.node(id)) {
        .integer => |value| result.addNode(.{ .integer = value }),
        .float => |value| result.addNode(.{ .float = value }),
        .symbol => |name| result.addNode(.{ .symbol = name }),
        .add => |binary| simplifyAdd(
            result,
            simplifyNode(result, expression, binary.left),
            simplifyNode(result, expression, binary.right),
        ),
        .sub => |binary| simplifySub(
            result,
            simplifyNode(result, expression, binary.left),
            simplifyNode(result, expression, binary.right),
        ),
        .mul => |binary| simplifyMul(
            result,
            simplifyNode(result, expression, binary.left),
            simplifyNode(result, expression, binary.right),
        ),
        .div => |binary| simplifyDiv(
            result,
            simplifyNode(result, expression, binary.left),
            simplifyNode(result, expression, binary.right),
        ),
        .pow => |power| simplifyPower(
            result,
            simplifyNode(result, expression, power.base),
            power.exponent,
        ),
        .negate => |child| simplifyNegate(
            result,
            simplifyNode(result, expression, child),
        ),
        .sin => |child| simplifyFunction(
            result,
            .sin,
            simplifyNode(result, expression, child),
        ),
        .cos => |child| simplifyFunction(
            result,
            .cos,
            simplifyNode(result, expression, child),
        ),
        .exp => |child| simplifyFunction(
            result,
            .exp,
            simplifyNode(result, expression, child),
        ),
        .ln => |child| simplifyFunction(
            result,
            .ln,
            simplifyNode(result, expression, child),
        ),
    };
}

fn simplifyAdd(result: *ast.Expr, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(result, left)) return right;
    if (isZero(result, right)) return left;
    if (foldBinary(result, .add, left, right)) |folded| return folded;
    return result.addNode(.{ .add = .{ .left = left, .right = right } });
}

fn simplifySub(result: *ast.Expr, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(result, right)) return left;
    if (ast.equal(result.*, left, result.*, right)) return integer(result, 0);
    if (foldBinary(result, .sub, left, right)) |folded| return folded;
    if (isZero(result, left)) return simplifyNegate(result, right);
    return result.addNode(.{ .sub = .{ .left = left, .right = right } });
}

fn simplifyMul(result: *ast.Expr, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    var factors: [ast.max_nodes]ast.NodeId = undefined;
    var factor_count: usize = 0;
    collectFactors(result, left, &factors, &factor_count);
    collectFactors(result, right, &factors, &factor_count);

    var coefficient: ?ast.NodeId = null;
    var symbolic_count: usize = 0;
    for (factors[0..factor_count]) |factor| {
        if (isZero(result, factor)) return integer(result, 0);
        if (isOne(result, factor)) continue;

        if (isConstant(result, factor)) {
            coefficient = if (coefficient) |current|
                foldBinary(result, .mul, current, factor).?
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
        while (insertion > 0 and less(result.*, factor, factors[insertion - 1])) {
            factors[insertion] = factors[insertion - 1];
            insertion -= 1;
        }
        factors[insertion] = factor;
    }

    var product: ?ast.NodeId = if (coefficient) |value|
        if (isOne(result, value)) null else value
    else
        null;
    for (factors[0..symbolic_count]) |factor| {
        product = if (product) |current|
            result.addNode(.{ .mul = .{ .left = current, .right = factor } })
        else
            factor;
    }

    return product orelse integer(result, 1);
}

fn collectFactors(
    expression: *const ast.Expr,
    id: ast.NodeId,
    factors: *[ast.max_nodes]ast.NodeId,
    count: *usize,
) void {
    switch (expression.node(id)) {
        .mul => |binary| {
            collectFactors(expression, binary.left, factors, count);
            collectFactors(expression, binary.right, factors, count);
        },
        else => {
            factors[count.*] = id;
            count.* += 1;
        },
    }
}

fn simplifyDiv(result: *ast.Expr, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
    if (isZero(result, left)) return integer(result, 0);
    if (isOne(result, right)) return left;
    if (foldBinary(result, .div, left, right)) |folded| return folded;
    return result.addNode(.{ .div = .{ .left = left, .right = right } });
}

fn simplifyPower(result: *ast.Expr, base: ast.NodeId, exponent: u32) ast.NodeId {
    if (exponent == 0) return integer(result, 1);
    if (exponent == 1) return base;

    return switch (result.node(base)) {
        .integer => |value| integer(result, integerPower(value, exponent)),
        .float => |value| float(result, floatPower(value, exponent)),
        else => result.addNode(.{ .pow = .{ .base = base, .exponent = exponent } }),
    };
}

fn simplifyNegate(result: *ast.Expr, child: ast.NodeId) ast.NodeId {
    return switch (result.node(child)) {
        .integer => |value| integer(result, -value),
        .float => |value| float(result, -value),
        .negate => |grandchild| grandchild,
        else => result.addNode(.{ .negate = child }),
    };
}

fn simplifyFunction(
    result: *ast.Expr,
    comptime function: enum { sin, cos, exp, ln },
    child: ast.NodeId,
) ast.NodeId {
    if (constantValue(result, child)) |value| {
        return float(result, switch (function) {
            .sin => @sin(value),
            .cos => @cos(value),
            .exp => @exp(value),
            .ln => @log(value),
        });
    }

    return switch (function) {
        .sin => result.addNode(.{ .sin = child }),
        .cos => result.addNode(.{ .cos = child }),
        .exp => result.addNode(.{ .exp = child }),
        .ln => result.addNode(.{ .ln = child }),
    };
}

fn foldBinary(
    result: *ast.Expr,
    comptime operation: enum { add, sub, mul, div },
    left: ast.NodeId,
    right: ast.NodeId,
) ?ast.NodeId {
    const left_node = result.node(left);
    const right_node = result.node(right);

    if (left_node == .integer and right_node == .integer) {
        const a = left_node.integer;
        const b = right_node.integer;
        return switch (operation) {
            .add => integer(result, a + b),
            .sub => integer(result, a - b),
            .mul => integer(result, a * b),
            .div => if (b == 0)
                null
            else if (@rem(a, b) == 0)
                integer(result, @divExact(a, b))
            else
                float(result, @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))),
        };
    }

    const a = constantValue(result, left) orelse return null;
    const b = constantValue(result, right) orelse return null;
    if (operation == .div and b == 0.0) return null;
    return float(result, switch (operation) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    });
}

fn constantValue(expression: *const ast.Expr, id: ast.NodeId) ?f64 {
    return switch (expression.node(id)) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => null,
    };
}

fn isConstant(expression: *const ast.Expr, id: ast.NodeId) bool {
    return constantValue(expression, id) != null;
}

fn isZero(expression: *const ast.Expr, id: ast.NodeId) bool {
    return switch (expression.node(id)) {
        .integer => |value| value == 0,
        .float => |value| value == 0.0,
        else => false,
    };
}

fn isOne(expression: *const ast.Expr, id: ast.NodeId) bool {
    return switch (expression.node(id)) {
        .integer => |value| value == 1,
        .float => |value| value == 1.0,
        else => false,
    };
}

fn integer(result: *ast.Expr, value: i64) ast.NodeId {
    return result.addNode(.{ .integer = value });
}

fn float(result: *ast.Expr, value: f64) ast.NodeId {
    if (value == 0.0) return integer(result, 0);
    if (value == 1.0) return integer(result, 1);
    return result.addNode(.{ .float = value });
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

fn less(comptime expression: ast.Expr, left: ast.NodeId, right: ast.NodeId) bool {
    const left_node = expression.node(left);
    const right_node = expression.node(right);
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
        .pow => |power| less(expression, power.base, right_node.pow.base),
        .mul => |binary| lessBinary(expression, binary, right_node.mul),
        .sin => |child| less(expression, child, right_node.sin),
        .cos => |child| less(expression, child, right_node.cos),
        .exp => |child| less(expression, child, right_node.exp),
        .ln => |child| less(expression, child, right_node.ln),
        .negate => |child| less(expression, child, right_node.negate),
        .add => |binary| lessBinary(expression, binary, right_node.add),
        .sub => |binary| lessBinary(expression, binary, right_node.sub),
        .div => |binary| lessBinary(expression, binary, right_node.div),
    };
}

fn lessBinary(comptime expression: ast.Expr, left: ast.Binary, right: ast.Binary) bool {
    if (ast.equal(expression, left.left, expression, right.left)) {
        return less(expression, left.right, right.right);
    }
    return less(expression, left.left, right.left);
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
