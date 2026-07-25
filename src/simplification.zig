const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");
const diagnostic = @import("diagnostic.zig");
const exact = @import("exact.zig");

const BinaryOperation = enum { add, sub, mul, div };
const Function = enum { sin, cos, tan, atan, abs, exp, ln };

pub fn simplify(comptime expression: ast.Expr) ast.Expr {
    var current = expression;
    var construction_peak_nodes: usize = 0;
    inline for (0..32) |_| {
        var next = simplifyOnce(current);
        construction_peak_nodes = @max(
            construction_peak_nodes,
            next.construction_peak_nodes,
        );
        if (canonicalEqual(current, next)) {
            next.construction_peak_nodes = construction_peak_nodes;
            return next;
        }
        current = next;
    }
    diagnostic.fail(
        expression.source,
        0,
        "simplification did not converge within 32 passes",
    );
}

fn canonicalEqual(comptime left: ast.Expr, comptime right: ast.Expr) bool {
    if (left.root != right.root or left.nodes.len != right.nodes.len) return false;
    for (left.nodes, right.nodes) |left_node, right_node| {
        if (!ast.nodeEqual(left_node, right_node)) return false;
    }
    return true;
}

fn simplifyOnce(comptime expression: ast.Expr) ast.Expr {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var context = Context{
        .builder = &builder,
        .expression = expression,
        .cache = &cache,
    };
    const root = context.simplifyNode(expression.root);
    return builder.finish(root, expression.source);
}

const Context = struct {
    builder: *build.Builder,
    expression: ast.Expr,
    cache: []ast.NodeId,

    fn simplifyNode(self: *Context, id: ast.NodeId) ast.NodeId {
        const index: usize = @intCast(id);
        if (self.cache[index] != ast.invalid_node) return self.cache[index];

        const result = switch (self.expression.node(id)) {
            .integer => |value| self.builder.integer(value),
            .rational => |value| self.builder.rational(value),
            .float => |value| self.builder.float(value),
            .symbol => |name| self.builder.symbol(name),
            .add => |binary| simplifyAdd(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.expression.source,
            ),
            .sub => |binary| simplifySub(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.expression.source,
            ),
            .mul => |binary| self.simplifyMul(
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
            ),
            .div => |binary| simplifyDiv(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.expression.source,
            ),
            .pow => |power| simplifyPower(
                self.builder,
                self.simplifyNode(power.base),
                power.exponent,
                self.expression.source,
            ),
            .negate => |child| simplifyNegate(
                self.builder,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .sin => |child| simplifyFunction(
                self.builder,
                .sin,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .cos => |child| simplifyFunction(
                self.builder,
                .cos,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .tan => |child| simplifyFunction(
                self.builder,
                .tan,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .atan => |child| simplifyFunction(
                self.builder,
                .atan,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .abs => |child| simplifyFunction(
                self.builder,
                .abs,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .exp => |child| simplifyFunction(
                self.builder,
                .exp,
                self.simplifyNode(child),
                self.expression.source,
            ),
            .ln => |child| simplifyFunction(
                self.builder,
                .ln,
                self.simplifyNode(child),
                self.expression.source,
            ),
        };

        self.cache[index] = result;
        return result;
    }

    fn simplifyMul(self: *Context, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        const node_len = self.builder.len;
        var factor_workspace = [_]u32{0} ** node_len;
        if (!addFactorWeight(&factor_workspace, left, 1) or
            !addFactorWeight(&factor_workspace, right, 1))
        {
            return orderedMul(self.builder, left, right);
        }

        // Builder ids are topological: every child id is lower than its parent.
        // Propagating multiplicities in reverse order therefore visits each DAG
        // node once, even when its number of tree occurrences is exponential.
        var index = node_len;
        while (index > 0) {
            index -= 1;
            const weight = factor_workspace[index];
            if (weight == 0) continue;

            switch (self.builder.nodes[index]) {
                .mul => |binary| {
                    factor_workspace[index] = 0;
                    if (!addFactorWeight(&factor_workspace, binary.left, weight) or
                        !addFactorWeight(&factor_workspace, binary.right, weight))
                    {
                        return orderedMul(self.builder, left, right);
                    }
                },
                .pow => |power| {
                    if (power.exponent.denominator != 1 or
                        power.exponent.numerator <= 0 or
                        power.exponent.numerator > std.math.maxInt(u32))
                    {
                        continue;
                    }
                    factor_workspace[index] = 0;
                    const weighted_exponent = checkedU32Mul(
                        weight,
                        @intCast(power.exponent.numerator),
                    ) orelse return orderedMul(self.builder, left, right);
                    if (!addFactorWeight(
                        &factor_workspace,
                        power.base,
                        weighted_exponent,
                    )) {
                        return orderedMul(self.builder, left, right);
                    }
                },
                else => {},
            }
        }

        // A zero factor wins before folding any other coefficient, avoiding an
        // irrelevant overflow in products such as huge_constant * 0.
        for (0..node_len) |factor_index| {
            if (factor_workspace[factor_index] == 0) continue;
            const factor: ast.NodeId = @intCast(factor_index);
            if (isZero(self.builder, factor)) return self.builder.integer(0);
        }

        var coefficient: ?ast.NodeId = null;
        var symbolic_count: usize = 0;
        for (0..node_len) |factor_index| {
            const multiplicity = factor_workspace[factor_index];
            if (multiplicity == 0) continue;

            const factor: ast.NodeId = @intCast(factor_index);
            if (isOne(self.builder, factor)) continue;

            if (isConstant(self.builder, factor)) {
                const powered = simplifyPower(
                    self.builder,
                    factor,
                    exact.Rational.fromInteger(multiplicity),
                    self.expression.source,
                );
                coefficient = if (coefficient) |current|
                    foldBinary(
                        self.builder,
                        .mul,
                        current,
                        powered,
                        self.expression.source,
                    ).?
                else
                    powered;
            } else {
                const powered = if (multiplicity == 1)
                    factor
                else
                    self.builder.power(factor, multiplicity);

                // The compacted output index never exceeds the input index
                // currently being read, so this workspace is safely reused as
                // the sorted factor-id list after multiplicities are consumed.
                factor_workspace[symbolic_count] = powered;
                symbolic_count += 1;
            }
        }

        var sort_index: usize = 1;
        while (sort_index < symbolic_count) : (sort_index += 1) {
            const factor: ast.NodeId = factor_workspace[sort_index];
            var insertion = sort_index;
            while (insertion > 0 and less(
                self.builder,
                factor,
                factor_workspace[insertion - 1],
            )) {
                factor_workspace[insertion] = factor_workspace[insertion - 1];
                insertion -= 1;
            }
            factor_workspace[insertion] = factor;
        }

        var product: ?ast.NodeId = if (coefficient) |value|
            if (isOne(self.builder, value)) null else value
        else
            null;
        for (factor_workspace[0..symbolic_count]) |factor| {
            product = if (product) |current|
                self.builder.mul(current, factor)
            else
                factor;
        }

        return product orelse self.builder.integer(1);
    }
};

fn addFactorWeight(workspace: []u32, id: ast.NodeId, amount: u32) bool {
    const index: usize = @intCast(id);
    const sum = @addWithOverflow(workspace[index], amount);
    if (sum[1] != 0) return false;
    workspace[index] = sum[0];
    return true;
}

fn simplifyAdd(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (isZero(builder, left)) return right;
    if (isZero(builder, right)) return left;
    if (foldBinary(builder, .add, left, right, source)) |folded| return folded;
    return builder.add(left, right);
}

fn simplifySub(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (isZero(builder, right)) return left;
    if (left == right) return builder.integer(0);
    if (foldBinary(builder, .sub, left, right, source)) |folded| return folded;
    if (isZero(builder, left)) return simplifyNegate(builder, right, source);
    return builder.sub(left, right);
}

fn simplifyDiv(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (isZero(builder, left)) return builder.integer(0);
    if (isOne(builder, right)) return left;
    if (foldBinary(builder, .div, left, right, source)) |folded| return folded;
    return builder.div(left, right);
}

fn simplifyPower(
    builder: *build.Builder,
    base: ast.NodeId,
    exponent: exact.Rational,
    comptime source: []const u8,
) ast.NodeId {
    if (exponent.isZero()) return builder.integer(1);
    if (exponent.isOne()) return base;
    if (isZero(builder, base) and exponent.numerator < 0) {
        foldFailure(
            source,
            operatorPosition(source, '^'),
            "zero cannot be raised to a negative power",
        );
    }

    return switch (builder.node(base)) {
        .integer => |value| if (exponent.isInteger())
            builder.rational(
                exact.Rational.fromInteger(value)
                    .powInteger(exponent.numerator) catch
                    foldFailure(
                        source,
                        operatorPosition(source, '^'),
                        "integer constant folding exceeds i64 range",
                    ),
            )
        else
            builder.power(base, exponent),
        .rational => |value| if (exponent.isInteger())
            builder.rational(
                value.powInteger(exponent.numerator) catch |err|
                    exactFoldFailure(source, err),
            )
        else
            builder.power(base, exponent),
        .float => |value| normalizedFloat(
            builder,
            realPower(value, exponent, source),
            source,
            operatorPosition(source, '^'),
        ),
        else => builder.power(base, exponent),
    };
}

fn simplifyNegate(
    builder: *build.Builder,
    child: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    return switch (builder.node(child)) {
        .integer => |value| blk: {
            if (value == std.math.minInt(i64)) {
                foldFailure(source, operatorPosition(source, '-'), "integer constant folding exceeds i64 range");
            }
            break :blk builder.integer(-value);
        },
        .rational => |value| builder.rational(
            value.negate() catch exactFoldFailure(source, error.Overflow),
        ),
        .float => |value| normalizedFloat(
            builder,
            -value,
            source,
            operatorPosition(source, '-'),
        ),
        .negate => |grandchild| grandchild,
        else => builder.negate(child),
    };
}

fn simplifyFunction(
    builder: *build.Builder,
    comptime function: Function,
    child: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (exactValue(builder, child)) |value| {
        const position = functionPosition(source, @tagName(function));
        if (function == .ln and value.numerator <= 0) {
            foldFailure(source, position, "ln is undefined for non-positive constants");
        }

        if (function == .abs) {
            return builder.rational(
                value.abs() catch exactFoldFailure(source, error.Overflow),
            );
        }
        if (value.isZero()) {
            return switch (function) {
                .sin, .tan, .atan => builder.integer(0),
                .cos, .exp => builder.integer(1),
                .ln => unreachable,
                .abs => builder.integer(0),
            };
        }
        if (function == .ln and value.isOne()) return builder.integer(0);
        return makeFunction(builder, function, child);
    }

    if (builder.node(child) == .float) {
        const value = builder.node(child).float;
        const position = functionPosition(source, @tagName(function));
        if (function == .ln and value <= 0.0) {
            foldFailure(source, position, "ln is undefined for non-positive constants");
        }
        return normalizedFloat(builder, switch (function) {
            .sin => @sin(value),
            .cos => @cos(value),
            .tan => @tan(value),
            .atan => std.math.atan(value),
            .abs => @abs(value),
            .exp => @exp(value),
            .ln => @log(value),
        }, source, position);
    }

    return makeFunction(builder, function, child);
}

fn makeFunction(
    builder: *build.Builder,
    comptime function: Function,
    child: ast.NodeId,
) ast.NodeId {
    return switch (function) {
        .sin => builder.sine(child),
        .cos => builder.cosine(child),
        .tan => builder.tangent(child),
        .atan => builder.arctangent(child),
        .abs => builder.absolute(child),
        .exp => builder.exponential(child),
        .ln => builder.logarithm(child),
    };
}

fn foldBinary(
    builder: *build.Builder,
    comptime operation: BinaryOperation,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ?ast.NodeId {
    const left_node = builder.node(left);
    const right_node = builder.node(right);
    const position = operatorPosition(source, operationByte(operation));

    if (left_node == .integer and right_node == .integer) {
        const a = left_node.integer;
        const b = right_node.integer;
        return switch (operation) {
            .add => builder.integer(checkedIntegerAdd(a, b, source, position)),
            .sub => builder.integer(checkedIntegerSub(a, b, source, position)),
            .mul => builder.integer(checkedIntegerMul(a, b, source, position)),
            .div => if (b == 0) null else builder.rational(
                exact.Rational.fromInteger(a)
                    .div(exact.Rational.fromInteger(b)) catch
                    foldFailure(
                        source,
                        position,
                        "integer constant folding exceeds i64 range",
                    ),
            ),
        };
    }

    if (exactValue(builder, left)) |a| {
        if (exactValue(builder, right)) |b| {
            if (operation == .div and b.isZero()) return null;
            const folded = switch (operation) {
                .add => a.add(b),
                .sub => a.sub(b),
                .mul => a.mul(b),
                .div => a.div(b),
            } catch |err| exactFoldFailure(source, err);
            return builder.rational(folded);
        }
    }

    const a = constantValue(builder, left) orelse return null;
    const b = constantValue(builder, right) orelse return null;
    if (operation == .div and b == 0.0) return null;
    return normalizedFloat(builder, switch (operation) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    }, source, position);
}

fn constantValue(builder: *const build.Builder, id: ast.NodeId) ?f64 {
    return switch (builder.node(id)) {
        .integer => |value| @floatFromInt(value),
        .rational => |value| value.toF64(),
        .float => |value| value,
        else => null,
    };
}

fn exactValue(builder: *const build.Builder, id: ast.NodeId) ?exact.Rational {
    return switch (builder.node(id)) {
        .integer => |value| exact.Rational.fromInteger(value),
        .rational => |value| value,
        else => null,
    };
}

fn isConstant(builder: *const build.Builder, id: ast.NodeId) bool {
    return constantValue(builder, id) != null;
}

fn isZero(builder: *const build.Builder, id: ast.NodeId) bool {
    return switch (builder.node(id)) {
        .integer => |value| value == 0,
        .rational => |value| value.isZero(),
        .float => |value| value == 0.0,
        else => false,
    };
}

fn isOne(builder: *const build.Builder, id: ast.NodeId) bool {
    return switch (builder.node(id)) {
        .integer => |value| value == 1,
        .rational => |value| value.isOne(),
        .float => |value| value == 1.0,
        else => false,
    };
}

fn normalizedFloat(
    builder: *build.Builder,
    value: f64,
    comptime source: []const u8,
    comptime position: usize,
) ast.NodeId {
    if (!std.math.isFinite(value)) {
        foldFailure(
            source,
            position,
            "constant folding produced a non-finite floating-point value",
        );
    }
    if (value == 0.0) return builder.integer(0);
    if (value == 1.0) return builder.integer(1);
    return builder.float(value);
}

fn integerPower(
    base: i64,
    exponent: u32,
    comptime source: []const u8,
) i64 {
    var result: i64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining != 0) : (remaining /= 2) {
        if (remaining % 2 == 1) {
            result = checkedIntegerMul(
                result,
                factor,
                source,
                operatorPosition(source, '^'),
            );
        }
        if (remaining > 1) {
            factor = checkedIntegerMul(
                factor,
                factor,
                source,
                operatorPosition(source, '^'),
            );
        }
    }
    return result;
}

fn realPower(
    base: f64,
    exponent: exact.Rational,
    comptime source: []const u8,
) f64 {
    if (base == 0.0 and exponent.numerator < 0) {
        foldFailure(source, operatorPosition(source, '^'), "zero cannot be raised to a negative power");
    }
    if (base < 0.0 and exponent.denominator % 2 == 0) {
        foldFailure(
            source,
            operatorPosition(source, '^'),
            "even-denominator rational power is not real for a negative base",
        );
    }

    const magnitude = std.math.pow(
        f64,
        @abs(base),
        exponent.toF64(),
    );
    if (base >= 0.0 or exponent.denominator % 2 == 0) return magnitude;
    return if (@mod(exponent.numerator, 2) == 0) magnitude else -magnitude;
}

fn checkedIntegerAdd(
    left: i64,
    right: i64,
    comptime source: []const u8,
    comptime position: usize,
) i64 {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) {
        foldFailure(source, position, "integer constant folding exceeds i64 range");
    }
    return result[0];
}

fn checkedIntegerSub(
    left: i64,
    right: i64,
    comptime source: []const u8,
    comptime position: usize,
) i64 {
    const result = @subWithOverflow(left, right);
    if (result[1] != 0) {
        foldFailure(source, position, "integer constant folding exceeds i64 range");
    }
    return result[0];
}

fn checkedIntegerMul(
    left: i64,
    right: i64,
    comptime source: []const u8,
    comptime position: usize,
) i64 {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) {
        foldFailure(source, position, "integer constant folding exceeds i64 range");
    }
    return result[0];
}

fn checkedU32Mul(left: u32, right: u32) ?u32 {
    const result = @mulWithOverflow(left, right);
    return if (result[1] == 0) result[0] else null;
}

fn foldFailure(
    comptime source: []const u8,
    comptime position: usize,
    comptime message: []const u8,
) noreturn {
    _ = position;
    diagnostic.failExpression(source, message);
}

fn exactFoldFailure(
    comptime source: []const u8,
    err: exact.Error,
) noreturn {
    switch (err) {
        error.ZeroDenominator => foldFailure(
            source,
            operatorPosition(source, '/'),
            "exact rational denominator cannot be zero",
        ),
        error.Overflow => foldFailure(
            source,
            0,
            "exact rational constant folding exceeds fixed-width range",
        ),
    }
}

fn operationByte(comptime operation: BinaryOperation) u8 {
    return switch (operation) {
        .add => '+',
        .sub => '-',
        .mul => '*',
        .div => '/',
    };
}

fn operatorPosition(comptime source: []const u8, comptime operator: u8) usize {
    return std.mem.indexOfScalar(u8, source, operator) orelse 0;
}

fn functionPosition(comptime source: []const u8, comptime name: []const u8) usize {
    return std.mem.indexOf(u8, source, name) orelse 0;
}

fn orderedMul(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
) ast.NodeId {
    return if (less(builder, right, left))
        builder.mul(right, left)
    else
        builder.mul(left, right);
}

fn less(builder: *const build.Builder, left: ast.NodeId, right: ast.NodeId) bool {
    if (left == right) return false;

    const left_node = builder.node(left);
    const right_node = builder.node(right);
    const left_rank = rank(left_node);
    const right_rank = rank(right_node);
    if (left_rank != right_rank) return left_rank < right_rank;

    return switch (left_node) {
        .integer => |value| value < right_node.integer,
        .rational => |value| if (value.numerator != right_node.rational.numerator)
            value.numerator < right_node.rational.numerator
        else
            value.denominator < right_node.rational.denominator,
        .float => |value| if (value != right_node.float)
            value < right_node.float
        else
            @as(u64, @bitCast(value)) < @as(u64, @bitCast(right_node.float)),
        .symbol => |name| std.mem.order(u8, name, right_node.symbol) == .lt,
        .pow => |power| if (power.base == right_node.pow.base)
            if (power.exponent.numerator != right_node.pow.exponent.numerator)
                power.exponent.numerator < right_node.pow.exponent.numerator
            else
                power.exponent.denominator < right_node.pow.exponent.denominator
        else
            less(builder, power.base, right_node.pow.base),
        .mul => |binary| lessBinary(builder, binary, right_node.mul),
        .sin => |child| less(builder, child, right_node.sin),
        .cos => |child| less(builder, child, right_node.cos),
        .tan => |child| less(builder, child, right_node.tan),
        .atan => |child| less(builder, child, right_node.atan),
        .abs => |child| less(builder, child, right_node.abs),
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
        .integer => 0,
        .rational => 1,
        .float => 2,
        .symbol => 3,
        .pow => 4,
        .mul => 5,
        .sin => 6,
        .cos => 7,
        .tan => 8,
        .atan => 9,
        .abs => 10,
        .exp => 11,
        .ln => 12,
        .negate => 13,
        .add => 14,
        .sub => 15,
        .div => 16,
    };
}
