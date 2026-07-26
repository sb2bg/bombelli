const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");
const diagnostic = @import("diagnostic.zig");
const exact = @import("exact.zig");

const BinaryOperation = enum { add, sub, mul, div };
const Function = enum { sin, cos, tan, atan, abs, exp, ln };

pub fn simplify(comptime expression: ast.Expr) ast.Expr {
    var current = expression;
    var construction_peak_nodes = expression.construction_peak_nodes;
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

pub fn simplifyVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) ast.ExprVector(N) {
    if (N == 0) @compileError("Bombelli cannot simplify an empty expression vector");
    var current = expression;
    var construction_peak_nodes = expression.construction_peak_nodes;
    inline for (0..32) |_| {
        var next = simplifyVectorOnce(N, current);
        construction_peak_nodes = @max(
            construction_peak_nodes,
            next.construction_peak_nodes,
        );
        if (std.mem.eql(ast.NodeId, &current.roots, &next.roots) and
            canonicalNodesEqual(current.nodes, next.nodes))
        {
            next.construction_peak_nodes = construction_peak_nodes;
            return next;
        }
        current = next;
    }
    diagnostic.fail(
        expression.sources[0],
        0,
        "simplification did not converge within 32 passes",
    );
}

pub fn simplifyMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) ast.ExprMatrix(R, C) {
    if (R == 0 or C == 0) {
        @compileError("Bombelli cannot simplify an empty expression matrix");
    }
    var current = expression;
    var construction_peak_nodes = expression.construction_peak_nodes;
    inline for (0..32) |_| {
        var next = simplifyMatrixOnce(R, C, current);
        construction_peak_nodes = @max(
            construction_peak_nodes,
            next.construction_peak_nodes,
        );
        if (std.mem.eql(
            u8,
            std.mem.asBytes(&current.roots),
            std.mem.asBytes(&next.roots),
        ) and canonicalNodesEqual(current.nodes, next.nodes)) {
            next.construction_peak_nodes = construction_peak_nodes;
            return next;
        }
        current = next;
    }
    diagnostic.fail(
        expression.sources[0][0],
        0,
        "simplification did not converge within 32 passes",
    );
}

fn canonicalEqual(comptime left: ast.Expr, comptime right: ast.Expr) bool {
    return left.root == right.root and
        canonicalNodesEqual(left.nodes, right.nodes);
}

fn canonicalNodesEqual(
    comptime left: []const ast.Node,
    comptime right: []const ast.Node,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_node, right_node| {
        if (!ast.nodeEqual(left_node, right_node)) return false;
    }
    return true;
}

fn simplifyOnce(comptime expression: ast.Expr) ast.Expr {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var context = Context{
        .builder = &builder,
        .nodes = expression.nodes,
        .source = expression.source,
        .cache = &cache,
    };
    const root = context.simplifyNode(expression.root);
    return builder.finish(root, expression.source);
}

fn simplifyVectorOnce(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) ast.ExprVector(N) {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var context = Context{
        .builder = &builder,
        .nodes = expression.nodes,
        .source = expression.sources[0],
        .cache = &cache,
    };
    var roots: [N]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |root, index| {
        context.source = expression.sources[index];
        roots[index] = context.simplifyNode(root);
    }
    return builder.finishVector(N, roots, expression.sources);
}

fn simplifyMatrixOnce(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) ast.ExprMatrix(R, C) {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var context = Context{
        .builder = &builder,
        .nodes = expression.nodes,
        .source = expression.sources[0][0],
        .cache = &cache,
    };
    var roots: [R][C]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            context.source = expression.sources[row_index][column_index];
            roots[row_index][column_index] = context.simplifyNode(root);
        }
    }
    return builder.finishMatrix(R, C, roots, expression.sources);
}

const Context = struct {
    builder: *build.Builder,
    nodes: []const ast.Node,
    source: []const u8,
    cache: []ast.NodeId,

    fn simplifyNode(self: *Context, id: ast.NodeId) ast.NodeId {
        const index: usize = @intCast(id);
        if (self.cache[index] != ast.invalid_node) return self.cache[index];

        const result = switch (self.nodes[index]) {
            .integer => |value| self.builder.integer(value),
            .rational => |value| self.builder.rational(value),
            .float => |value| self.builder.float(value),
            .symbol => |name| self.builder.symbol(name),
            .add => |binary| simplifyAdd(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.source,
            ),
            .add_nary => |operands| blk: {
                var simplified: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |child, operand_index| {
                    simplified[operand_index] = self.simplifyNode(child);
                }
                break :blk canonicalAdd(
                    self.builder,
                    simplified[0..operands.len],
                    self.source,
                );
            },
            .sub => |binary| simplifySub(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.source,
            ),
            .mul => |binary| canonicalMul(
                self.builder,
                &.{
                    self.simplifyNode(binary.left),
                    self.simplifyNode(binary.right),
                },
                self.source,
            ),
            .mul_nary => |operands| blk: {
                var simplified: [ast.construction_node_limit]ast.NodeId = undefined;
                for (operands, 0..) |child, operand_index| {
                    simplified[operand_index] = self.simplifyNode(child);
                }
                break :blk canonicalMul(
                    self.builder,
                    simplified[0..operands.len],
                    self.source,
                );
            },
            .div => |binary| simplifyDiv(
                self.builder,
                self.simplifyNode(binary.left),
                self.simplifyNode(binary.right),
                self.source,
            ),
            .pow => |power| simplifyPower(
                self.builder,
                self.simplifyNode(power.base),
                power.exponent,
                self.source,
            ),
            .negate => |child| simplifyNegate(
                self.builder,
                self.simplifyNode(child),
                self.source,
            ),
            .sin => |child| simplifyFunction(
                self.builder,
                .sin,
                self.simplifyNode(child),
                self.source,
            ),
            .cos => |child| simplifyFunction(
                self.builder,
                .cos,
                self.simplifyNode(child),
                self.source,
            ),
            .tan => |child| simplifyFunction(
                self.builder,
                .tan,
                self.simplifyNode(child),
                self.source,
            ),
            .atan => |child| simplifyFunction(
                self.builder,
                .atan,
                self.simplifyNode(child),
                self.source,
            ),
            .abs => |child| simplifyFunction(
                self.builder,
                .abs,
                self.simplifyNode(child),
                self.source,
            ),
            .exp => |child| simplifyFunction(
                self.builder,
                .exp,
                self.simplifyNode(child),
                self.source,
            ),
            .ln => |child| simplifyFunction(
                self.builder,
                .ln,
                self.simplifyNode(child),
                self.source,
            ),
        };

        self.cache[index] = result;
        return result;
    }
};

fn simplifyAdd(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    return canonicalAdd(builder, &.{ left, right }, source);
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
    return canonicalAdd(
        builder,
        &.{ left, simplifyNegate(builder, right, source) },
        source,
    );
}

fn simplifyDiv(
    builder: *build.Builder,
    left: ast.NodeId,
    right: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (isOne(builder, right)) return left;
    if (foldBinary(builder, .div, left, right, source)) |folded| return folded;
    if (exactValue(builder, right)) |denominator| {
        if (!denominator.isZero()) {
            const reciprocal = exact.Rational.fromInteger(1)
                .div(denominator) catch |err| exactFoldFailure(source, err);
            return canonicalMul(
                builder,
                &.{ builder.rational(reciprocal), left },
                source,
            );
        }
    }
    return builder.div(left, right);
}

fn canonicalAdd(
    builder: *build.Builder,
    operands: []const ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    var flattened: [ast.construction_node_limit]ast.NodeId = undefined;
    var flattened_len: usize = 0;
    for (operands) |operand| {
        collectAddOperands(builder, operand, &flattened, &flattened_len);
    }

    var bases: [ast.construction_node_limit]ast.NodeId = undefined;
    var coefficients: [ast.construction_node_limit]exact.Rational = undefined;
    var term_count: usize = 0;
    var exact_constant = exact.Rational.fromInteger(0);
    var exact_constant_is_integer = true;
    var approximate_constant: f64 = 0.0;
    var has_approximate_constant = false;

    for (flattened[0..flattened_len]) |operand| {
        if (builder.node(operand) == .float) {
            approximate_constant += builder.node(operand).float;
            has_approximate_constant = true;
            continue;
        }

        const term = decomposeTerm(builder, operand, source);
        if (term.basis == ast.invalid_node) {
            exact_constant_is_integer = exact_constant_is_integer and
                builder.node(operand) == .integer;
            exact_constant = exact_constant.add(term.coefficient) catch |err|
                exactArithmeticFailure(
                    source,
                    err,
                    exact_constant_is_integer,
                    operatorPosition(source, '+'),
                );
            continue;
        }

        var existing: ?usize = null;
        for (bases[0..term_count], 0..) |basis, index| {
            if (basis == term.basis) {
                existing = index;
                break;
            }
        }
        if (existing) |index| {
            coefficients[index] = coefficients[index].add(term.coefficient) catch |err|
                exactFoldFailure(source, err);
        } else {
            bases[term_count] = term.basis;
            coefficients[term_count] = term.coefficient;
            term_count += 1;
        }
    }

    var compact_count: usize = 0;
    for (0..term_count) |index| {
        if (coefficients[index].isZero()) continue;
        bases[compact_count] = bases[index];
        coefficients[compact_count] = coefficients[index];
        compact_count += 1;
    }
    term_count = compact_count;

    var sort_index: usize = 1;
    while (sort_index < term_count) : (sort_index += 1) {
        const basis = bases[sort_index];
        const coefficient = coefficients[sort_index];
        var insertion = sort_index;
        while (insertion > 0 and less(builder, basis, bases[insertion - 1])) {
            bases[insertion] = bases[insertion - 1];
            coefficients[insertion] = coefficients[insertion - 1];
            insertion -= 1;
        }
        bases[insertion] = basis;
        coefficients[insertion] = coefficient;
    }

    var result_operands: [ast.construction_node_limit]ast.NodeId = undefined;
    var result_len: usize = 0;
    for (bases[0..term_count], coefficients[0..term_count]) |basis, coefficient| {
        appendCanonicalResult(
            &result_operands,
            &result_len,
            makeCoefficientTerm(
                builder,
                coefficient,
                basis,
                source,
            ),
            "addition",
        );
    }

    if (has_approximate_constant) {
        approximate_constant += exact_constant.toF64();
        const constant = normalizedFloat(
            builder,
            approximate_constant,
            source,
            operatorPosition(source, '+'),
        );
        if (!isZero(builder, constant)) {
            appendCanonicalResult(
                &result_operands,
                &result_len,
                constant,
                "addition",
            );
        }
    } else if (!exact_constant.isZero()) {
        appendCanonicalResult(
            &result_operands,
            &result_len,
            builder.rational(exact_constant),
            "addition",
        );
    }

    return switch (result_len) {
        0 => builder.integer(0),
        1 => result_operands[0],
        else => builder.addNary(result_operands[0..result_len]),
    };
}

fn canonicalMul(
    builder: *build.Builder,
    operands: []const ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    var flattened: [ast.construction_node_limit]ast.NodeId = undefined;
    var flattened_len: usize = 0;
    for (operands) |operand| {
        collectMulOperands(builder, operand, &flattened, &flattened_len);
    }

    // A known zero wins before other coefficient folding, so a discarded huge
    // exact product cannot produce an irrelevant overflow.
    for (flattened[0..flattened_len]) |factor| {
        if (isZero(builder, factor)) return builder.integer(0);
    }

    var coefficient = exact.Rational.fromInteger(1);
    var coefficient_is_integer = true;
    var approximate_coefficient: f64 = 1.0;
    var has_approximate_coefficient = false;
    var bases: [ast.construction_node_limit]ast.NodeId = undefined;
    var exponents: [ast.construction_node_limit]i64 = undefined;
    var factor_count: usize = 0;

    for (flattened[0..flattened_len]) |factor| {
        if (exactValue(builder, factor)) |value| {
            coefficient_is_integer = coefficient_is_integer and
                builder.node(factor) == .integer;
            coefficient = coefficient.mul(value) catch |err|
                exactArithmeticFailure(
                    source,
                    err,
                    coefficient_is_integer,
                    operatorPosition(source, '*'),
                );
            continue;
        }
        if (builder.node(factor) == .float) {
            approximate_coefficient *= builder.node(factor).float;
            has_approximate_coefficient = true;
            continue;
        }

        var base = factor;
        var exponent: i64 = 1;
        if (builder.node(factor) == .pow) {
            const power = builder.node(factor).pow;
            if (power.exponent.isInteger() and power.exponent.numerator > 0) {
                base = power.base;
                exponent = power.exponent.numerator;
            }
        }

        var existing: ?usize = null;
        for (bases[0..factor_count], 0..) |candidate, index| {
            if (candidate == base) {
                existing = index;
                break;
            }
        }
        if (existing) |index| {
            exponents[index] = exact.checkedAdd(exponents[index], exponent) catch
                foldFailure(
                    source,
                    operatorPosition(source, '*'),
                    "combined factor exponent exceeds fixed-width range",
                );
        } else {
            bases[factor_count] = base;
            exponents[factor_count] = exponent;
            factor_count += 1;
        }
    }

    var sort_index: usize = 1;
    while (sort_index < factor_count) : (sort_index += 1) {
        const base = bases[sort_index];
        const exponent = exponents[sort_index];
        var insertion = sort_index;
        while (insertion > 0 and less(builder, base, bases[insertion - 1])) {
            bases[insertion] = bases[insertion - 1];
            exponents[insertion] = exponents[insertion - 1];
            insertion -= 1;
        }
        bases[insertion] = base;
        exponents[insertion] = exponent;
    }

    var result_factors: [ast.construction_node_limit]ast.NodeId = undefined;
    var result_len: usize = 0;
    if (has_approximate_coefficient) {
        approximate_coefficient *= coefficient.toF64();
        const folded = normalizedFloat(
            builder,
            approximate_coefficient,
            source,
            operatorPosition(source, '*'),
        );
        if (isZero(builder, folded)) return builder.integer(0);
        if (!isOne(builder, folded)) {
            appendCanonicalResult(
                &result_factors,
                &result_len,
                folded,
                "multiplication",
            );
        }
    } else if (!coefficient.isOne()) {
        appendCanonicalResult(
            &result_factors,
            &result_len,
            builder.rational(coefficient),
            "multiplication",
        );
    }

    for (bases[0..factor_count], exponents[0..factor_count]) |base, exponent| {
        appendCanonicalResult(
            &result_factors,
            &result_len,
            if (exponent == 1)
                base
            else
                builder.power(base, exact.Rational.fromInteger(exponent)),
            "multiplication",
        );
    }

    return switch (result_len) {
        0 => builder.integer(1),
        1 => result_factors[0],
        else => builder.mulNary(result_factors[0..result_len]),
    };
}

fn appendCanonicalResult(
    storage: *[ast.construction_node_limit]ast.NodeId,
    len: *usize,
    value: ast.NodeId,
    comptime operation: []const u8,
) void {
    if (len.* == storage.len) {
        @compileError(std.fmt.comptimePrint(
            "Bombelli canonical {s} exceeds construction workspace",
            .{operation},
        ));
    }
    storage[len.*] = value;
    len.* += 1;
}

const Term = struct {
    coefficient: exact.Rational,
    basis: ast.NodeId,
};

fn decomposeTerm(
    builder: *build.Builder,
    operand: ast.NodeId,
    comptime source: []const u8,
) Term {
    _ = source;
    if (exactValue(builder, operand)) |value| {
        return .{ .coefficient = value, .basis = ast.invalid_node };
    }
    return switch (builder.node(operand)) {
        .negate => |child| .{
            .coefficient = exact.Rational.fromInteger(-1),
            .basis = child,
        },
        .mul_nary => |factors| blk: {
            const leading = exactValue(builder, factors[0]) orelse break :blk .{
                .coefficient = exact.Rational.fromInteger(1),
                .basis = operand,
            };
            const basis = if (factors.len == 2)
                factors[1]
            else
                builder.mulNary(factors[1..]);
            break :blk .{ .coefficient = leading, .basis = basis };
        },
        else => .{
            .coefficient = exact.Rational.fromInteger(1),
            .basis = operand,
        },
    };
}

fn makeCoefficientTerm(
    builder: *build.Builder,
    coefficient: exact.Rational,
    basis: ast.NodeId,
    comptime source: []const u8,
) ast.NodeId {
    if (coefficient.isOne()) return basis;
    if (coefficient.eql(exact.Rational.fromInteger(-1))) {
        return simplifyNegate(builder, basis, source);
    }
    return canonicalMul(
        builder,
        &.{ builder.rational(coefficient), basis },
        source,
    );
}

fn collectAddOperands(
    builder: *const build.Builder,
    id: ast.NodeId,
    workspace: *[ast.construction_node_limit]ast.NodeId,
    len: *usize,
) void {
    switch (builder.node(id)) {
        .add => |binary| {
            collectAddOperands(builder, binary.left, workspace, len);
            collectAddOperands(builder, binary.right, workspace, len);
        },
        .add_nary => |operands| {
            for (operands) |child| collectAddOperands(builder, child, workspace, len);
        },
        else => {
            if (len.* == workspace.len) {
                @compileError("Bombelli canonical addition exceeds construction workspace");
            }
            workspace[len.*] = id;
            len.* += 1;
        },
    }
}

fn collectMulOperands(
    builder: *const build.Builder,
    id: ast.NodeId,
    workspace: *[ast.construction_node_limit]ast.NodeId,
    len: *usize,
) void {
    switch (builder.node(id)) {
        .mul => |binary| {
            collectMulOperands(builder, binary.left, workspace, len);
            collectMulOperands(builder, binary.right, workspace, len);
        },
        .mul_nary => |operands| {
            for (operands) |child| collectMulOperands(builder, child, workspace, len);
        },
        else => {
            if (len.* == workspace.len) {
                @compileError("Bombelli canonical multiplication exceeds construction workspace");
            }
            workspace[len.*] = id;
            len.* += 1;
        },
    }
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
        .pow => |inner| blk: {
            if (!exponent.isInteger()) break :blk builder.power(base, exponent);
            const combined = inner.exponent.mul(exponent) catch |err|
                exactFoldFailure(source, err);
            // For negative real bases, an even-denominator inner power is
            // undefined. Preserve that restriction if multiplying exponents
            // would cancel the even denominator (for example, sqrt(x)^2).
            if (inner.exponent.denominator % 2 == 0 and
                combined.denominator % 2 != 0)
            {
                break :blk builder.power(base, exponent);
            }
            break :blk simplifyPower(
                builder,
                inner.base,
                combined,
                source,
            );
        },
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

fn foldFailure(
    comptime source: []const u8,
    comptime position: usize,
    comptime message: []const u8,
) noreturn {
    diagnostic.fail(source, position, message);
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

fn exactArithmeticFailure(
    comptime source: []const u8,
    err: exact.Error,
    integer_only: bool,
    comptime position: usize,
) noreturn {
    if (err == error.Overflow and integer_only) {
        foldFailure(
            source,
            position,
            "integer constant folding exceeds i64 range",
        );
    }
    exactFoldFailure(source, err);
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

fn less(builder: *const build.Builder, left: ast.NodeId, right: ast.NodeId) bool {
    if (left == right) return false;

    const left_node = builder.node(left);
    const right_node = builder.node(right);
    const left_rank = rank(left_node);
    const right_rank = rank(right_node);
    if (left_rank != right_rank) return left_rank < right_rank;
    const left_tag = std.meta.activeTag(left_node);
    const right_tag = std.meta.activeTag(right_node);
    if (left_tag != right_tag) {
        // Binary and n-ary nodes intentionally share a rank. Order unlike
        // tags before reading either union payload.
        return @intFromEnum(left_tag) < @intFromEnum(right_tag);
    }

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
        .add_nary => |operands| lessOperands(
            builder,
            operands,
            right_node.add_nary,
        ),
        .sub => |binary| lessBinary(builder, binary, right_node.sub),
        .mul_nary => |operands| lessOperands(
            builder,
            operands,
            right_node.mul_nary,
        ),
        .div => |binary| lessBinary(builder, binary, right_node.div),
    };
}

fn lessOperands(
    builder: *const build.Builder,
    left: []const ast.NodeId,
    right: []const ast.NodeId,
) bool {
    const common = @min(left.len, right.len);
    for (left[0..common], right[0..common]) |left_child, right_child| {
        if (left_child == right_child) continue;
        return less(builder, left_child, right_child);
    }
    return left.len < right.len;
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
        .add, .add_nary => 14,
        .sub => 15,
        .mul_nary => 5,
        .div => 16,
    };
}
