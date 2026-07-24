const std = @import("std");
const ast = @import("ast.zig");

const BinaryKind = enum { add, sub, mul, div };

pub fn differentiate(comptime expression: ast.Expr, comptime variable: []const u8) ast.Expr {
    var result = ast.Expr.init(expression.source);
    result.root = differentiateNode(&result, expression, expression.root, variable);
    return result;
}

fn differentiateNode(
    result: *ast.Expr,
    comptime expression: ast.Expr,
    id: ast.NodeId,
    comptime variable: []const u8,
) ast.NodeId {
    return switch (expression.node(id)) {
        .integer, .float => integer(result, 0),
        .symbol => |name| integer(result, if (std.mem.eql(u8, name, variable)) 1 else 0),
        .negate => |child| result.addNode(.{
            .negate = differentiateNode(result, expression, child, variable),
        }),
        .add => |binary| binaryNode(
            result,
            .add,
            differentiateNode(result, expression, binary.left, variable),
            differentiateNode(result, expression, binary.right, variable),
        ),
        .sub => |binary| binaryNode(
            result,
            .sub,
            differentiateNode(result, expression, binary.left, variable),
            differentiateNode(result, expression, binary.right, variable),
        ),
        .mul => |binary| blk: {
            const left_derivative = differentiateNode(result, expression, binary.left, variable);
            const right_copy = cloneNode(result, expression, binary.right);
            const left_copy = cloneNode(result, expression, binary.left);
            const right_derivative = differentiateNode(result, expression, binary.right, variable);
            const first = binaryNode(result, .mul, left_derivative, right_copy);
            const second = binaryNode(result, .mul, left_copy, right_derivative);
            break :blk binaryNode(result, .add, first, second);
        },
        .div => |binary| blk: {
            const left_derivative = differentiateNode(result, expression, binary.left, variable);
            const right_copy_one = cloneNode(result, expression, binary.right);
            const left_copy = cloneNode(result, expression, binary.left);
            const right_derivative = differentiateNode(result, expression, binary.right, variable);
            const first = binaryNode(result, .mul, left_derivative, right_copy_one);
            const second = binaryNode(result, .mul, left_copy, right_derivative);
            const numerator = binaryNode(result, .sub, first, second);
            const right_copy_two = cloneNode(result, expression, binary.right);
            const denominator = result.addNode(.{ .pow = .{
                .base = right_copy_two,
                .exponent = 2,
            } });
            break :blk binaryNode(result, .div, numerator, denominator);
        },
        .pow => |power| blk: {
            if (power.exponent == 0) break :blk integer(result, 0);
            const coefficient = integer(result, @intCast(power.exponent));
            const base = cloneNode(result, expression, power.base);
            const reduced_power = result.addNode(.{ .pow = .{
                .base = base,
                .exponent = power.exponent - 1,
            } });
            const derivative = differentiateNode(result, expression, power.base, variable);
            const coefficient_times_power = binaryNode(result, .mul, coefficient, reduced_power);
            break :blk binaryNode(result, .mul, coefficient_times_power, derivative);
        },
        .sin => |child| blk: {
            const child_copy = cloneNode(result, expression, child);
            const cosine = result.addNode(.{ .cos = child_copy });
            const derivative = differentiateNode(result, expression, child, variable);
            break :blk binaryNode(result, .mul, cosine, derivative);
        },
        .cos => |child| blk: {
            const child_copy = cloneNode(result, expression, child);
            const sine = result.addNode(.{ .sin = child_copy });
            const negative_sine = result.addNode(.{ .negate = sine });
            const derivative = differentiateNode(result, expression, child, variable);
            break :blk binaryNode(result, .mul, negative_sine, derivative);
        },
        .exp => |child| blk: {
            const child_copy = cloneNode(result, expression, child);
            const exponential = result.addNode(.{ .exp = child_copy });
            const derivative = differentiateNode(result, expression, child, variable);
            break :blk binaryNode(result, .mul, exponential, derivative);
        },
        .ln => |child| blk: {
            const derivative = differentiateNode(result, expression, child, variable);
            const child_copy = cloneNode(result, expression, child);
            break :blk binaryNode(result, .div, derivative, child_copy);
        },
    };
}

fn cloneNode(result: *ast.Expr, comptime expression: ast.Expr, id: ast.NodeId) ast.NodeId {
    return switch (expression.node(id)) {
        .integer => |value| result.addNode(.{ .integer = value }),
        .float => |value| result.addNode(.{ .float = value }),
        .symbol => |name| result.addNode(.{ .symbol = name }),
        .add => |binary| cloneBinary(result, expression, .add, binary),
        .sub => |binary| cloneBinary(result, expression, .sub, binary),
        .mul => |binary| cloneBinary(result, expression, .mul, binary),
        .div => |binary| cloneBinary(result, expression, .div, binary),
        .pow => |power| result.addNode(.{ .pow = .{
            .base = cloneNode(result, expression, power.base),
            .exponent = power.exponent,
        } }),
        .negate => |child| result.addNode(.{ .negate = cloneNode(result, expression, child) }),
        .sin => |child| result.addNode(.{ .sin = cloneNode(result, expression, child) }),
        .cos => |child| result.addNode(.{ .cos = cloneNode(result, expression, child) }),
        .exp => |child| result.addNode(.{ .exp = cloneNode(result, expression, child) }),
        .ln => |child| result.addNode(.{ .ln = cloneNode(result, expression, child) }),
    };
}

fn cloneBinary(
    result: *ast.Expr,
    comptime expression: ast.Expr,
    comptime kind: BinaryKind,
    binary: ast.Binary,
) ast.NodeId {
    return binaryNode(
        result,
        kind,
        cloneNode(result, expression, binary.left),
        cloneNode(result, expression, binary.right),
    );
}

fn integer(result: *ast.Expr, value: i64) ast.NodeId {
    return result.addNode(.{ .integer = value });
}

fn binaryNode(
    result: *ast.Expr,
    comptime kind: BinaryKind,
    left: ast.NodeId,
    right: ast.NodeId,
) ast.NodeId {
    return switch (kind) {
        .add => result.addNode(.{ .add = .{ .left = left, .right = right } }),
        .sub => result.addNode(.{ .sub = .{ .left = left, .right = right } }),
        .mul => result.addNode(.{ .mul = .{ .left = left, .right = right } }),
        .div => result.addNode(.{ .div = .{ .left = left, .right = right } }),
    };
}
