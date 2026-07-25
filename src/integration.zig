const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");
const differentiation = @import("differentiation.zig");
const domain_module = @import("domain.zig");
const exact = @import("exact.zig");
const multi = @import("multi.zig");
const parser = @import("parser.zig");
const polynomial = @import("polynomial.zig");
const substitution = @import("substitution.zig");

pub const IntegrationAlgorithm = enum {
    symbolic,
};

pub const IntegralBounds = struct {
    from: ast.Expr,
    to: ast.Expr,
};

pub const IntegralProblem = struct {
    integrand: ast.Expr,
    variable: []const u8,
    domain: domain_module.Domain,
    assumptions: []const domain_module.Assumption,
    bounds: ?IntegralBounds,

    pub fn solve(
        comptime self: IntegralProblem,
        comptime algorithm: anytype,
    ) IntegrationResult {
        @setEvalBranchQuota(50_000_000);
        if (!std.mem.eql(u8, @tagName(algorithm), "symbolic")) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli does not support the integration algorithm '.{s}'",
                .{@tagName(algorithm)},
            ));
        }
        return integrateProblem(self);
    }
};

pub const PartialIntegral = struct {
    closed_portion: ast.Expr,
    remainder: IntegralProblem,

    pub fn compile(
        comptime self: PartialIntegral,
        comptime options: anytype,
    ) @import("hybrid_integration.zig").HybridIntegral(options.order) {
        return @import("hybrid_integration.zig").compilePartial(self, options);
    }
};

pub const Proof = struct {
    message: []const u8,
};

pub const IntegrationDiagnostic = struct {
    message: []const u8,
};

pub const IntegrationResult = union(enum) {
    closed_form: ast.Expr,
    partial: PartialIntegral,
    no_elementary_form: Proof,
    unsupported: IntegrationDiagnostic,

    const Self = @This();

    pub fn unwrap(comptime self: Self) ast.Expr {
        return switch (self) {
            .closed_form => |expression| expression,
            .partial => |value| @compileError(std.fmt.comptimePrint(
                "Bombelli integration is partial; unresolved remainder: {s}",
                .{value.remainder.integrand.render()},
            )),
            .no_elementary_form => |proof| @compileError(std.fmt.comptimePrint(
                "Bombelli established that no elementary antiderivative is available: {s}",
                .{proof.message},
            )),
            .unsupported => |diagnostic| @compileError(std.fmt.comptimePrint(
                "Bombelli symbolic integration is unsupported: {s}",
                .{diagnostic.message},
            )),
        };
    }

    pub fn compile(
        comptime self: Self,
        comptime options: anytype,
    ) @import("hybrid_integration.zig").HybridIntegral(options.order) {
        return switch (self) {
            .partial => |value| value.compile(options),
            .closed_form => @compileError(
                "Bombelli integration is already closed form; compile the expression directly",
            ),
            .no_elementary_form => @compileError(
                "Bombelli cannot compile a no-elementary-form proof as a numerical integral",
            ),
            .unsupported => @compileError(
                "Bombelli cannot compile an unsupported symbolic integration result",
            ),
        };
    }
};

pub fn makeProblem(
    comptime expression: ast.Expr,
    comptime options: anytype,
) IntegralProblem {
    const Options = @TypeOf(options);
    if (!@hasField(Options, "variable")) {
        @compileError("Bombelli integration options require '.variable'");
    }
    if (!@hasField(Options, "domain")) {
        @compileError("Bombelli integration options require '.domain'");
    }
    const has_from = @hasField(Options, "from");
    const has_to = @hasField(Options, "to");
    if (has_from != has_to) {
        @compileError("Bombelli definite integration requires both '.from' and '.to'");
    }

    return .{
        .integrand = expression,
        .variable = @tagName(options.variable),
        .domain = @as(domain_module.Domain, options.domain),
        .assumptions = assumptionsFromOptions(options),
        .bounds = if (has_from) .{
            .from = expressionValue(options.from),
            .to = expressionValue(options.to),
        } else null,
    };
}

pub fn integrate(
    comptime expression: ast.Expr,
    comptime options: anytype,
) IntegrationResult {
    return makeProblem(expression, options).solve(.symbolic);
}

fn integrateProblem(comptime problem: IntegralProblem) IntegrationResult {
    const result = integrateIndefinite(problem);
    if (problem.bounds == null) return result;
    return switch (result) {
        .closed_form => |antiderivative| .{
            .closed_form = applyBounds(
                antiderivative,
                problem.variable,
                problem.bounds.?,
            ),
        },
        .partial => |value| .{ .partial = .{
            .closed_portion = applyBounds(
                value.closed_portion,
                problem.variable,
                problem.bounds.?,
            ),
            .remainder = value.remainder,
        } },
        .no_elementary_form => |proof| .{ .no_elementary_form = proof },
        .unsupported => |diagnostic| .{ .unsupported = diagnostic },
    };
}

fn integrateIndefinite(comptime problem: IntegralProblem) IntegrationResult {
    const expression = problem.integrand.simplify();
    if (integrateClosed(expression, problem)) |closed| {
        return .{ .closed_form = closed.simplify() };
    }

    const root = expression.node(expression.root);
    if (root != .add_nary and root != .add) {
        return unsupportedResult(expression);
    }

    var closed_terms: [ast.construction_node_limit]ast.Expr = undefined;
    var unresolved_terms: [ast.construction_node_limit]ast.Expr = undefined;
    var closed_count: usize = 0;
    var unresolved_count: usize = 0;
    const term_ids = additiveOperands(expression);
    for (term_ids) |term_id| {
        const term = multi.extractRoot(
            expression.nodes,
            term_id,
            expression.source,
        );
        if (integrateClosed(term, problem)) |closed| {
            closed_terms[closed_count] = closed;
            closed_count += 1;
        } else {
            unresolved_terms[unresolved_count] = term;
            unresolved_count += 1;
        }
    }

    if (closed_count == 0) return unsupportedResult(expression);
    if (unresolved_count == 0) {
        return .{
            .closed_form = addExpressions(closed_terms[0..closed_count]).simplify(),
        };
    }

    const remainder_integrand =
        addExpressions(unresolved_terms[0..unresolved_count]).simplify();
    var remainder = problem;
    remainder.integrand = remainder_integrand;
    return .{ .partial = .{
        .closed_portion = addExpressions(
            closed_terms[0..closed_count],
        ).simplify(),
        .remainder = remainder,
    } };
}

fn integrateClosed(
    comptime expression: ast.Expr,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const simplified = expression.simplify();
    if (polynomialConvertible(simplified)) {
        return simplified.asPolynomial()
            .antiderivativeName(problem.variable)
            .toExpr()
            .simplify();
    }
    if (!dependsOn(simplified, problem.variable)) {
        return multiplyExpressions(
            simplified,
            parser.parse(problem.variable),
        ).simplify();
    }

    return switch (simplified.node(simplified.root)) {
        .add, .add_nary => integrateAllTerms(simplified, problem),
        .sub => |binary| integrateDifference(simplified, binary, problem),
        .negate => |child| if (integrateClosed(
            multi.extractRoot(simplified.nodes, child, simplified.source),
            problem,
        )) |closed|
            negateExpression(closed).simplify()
        else
            null,
        .pow => |power| integratePower(simplified, power, problem),
        .div => |binary| integrateDivision(simplified, binary, problem),
        .sin => |child| integrateAffineFunction(
            simplified,
            child,
            .sin,
            problem,
        ),
        .cos => |child| integrateAffineFunction(
            simplified,
            child,
            .cos,
            problem,
        ),
        .exp => |child| integrateAffineFunction(
            simplified,
            child,
            .exp,
            problem,
        ),
        .mul, .mul_nary => integrateProduct(simplified, problem),
        else => null,
    };
}

fn integrateDifference(
    comptime expression: ast.Expr,
    comptime binary: ast.Binary,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const left = integrateClosed(
        multi.extractRoot(expression.nodes, binary.left, expression.source),
        problem,
    ) orelse return null;
    const right = integrateClosed(
        multi.extractRoot(expression.nodes, binary.right, expression.source),
        problem,
    ) orelse return null;
    return subtractExpressions(left, right).simplify();
}

fn integrateAllTerms(
    comptime expression: ast.Expr,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const term_ids = additiveOperands(expression);
    var closed: [ast.construction_node_limit]ast.Expr = undefined;
    for (term_ids, 0..) |term_id, index| {
        const term = multi.extractRoot(
            expression.nodes,
            term_id,
            expression.source,
        );
        closed[index] = integrateClosed(term, problem) orelse return null;
    }
    return addExpressions(closed[0..term_ids.len]).simplify();
}

fn integratePower(
    comptime expression: ast.Expr,
    comptime power: ast.Power,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const base = expression.node(power.base);
    if (base != .symbol or
        !std.mem.eql(u8, base.symbol, problem.variable))
    {
        return null;
    }
    if (power.exponent.eql(exact.Rational.fromInteger(-1))) {
        if (problem.domain != .real) return null;
        return parser.parse(std.fmt.comptimePrint(
            "ln(abs({s}))",
            .{problem.variable},
        ));
    }
    const raised_exponent = power.exponent.add(
        exact.Rational.fromInteger(1),
    ) catch @panic("Bombelli integral power exponent overflowed");
    if (raised_exponent.isZero()) return null;
    return parser.parse(std.fmt.comptimePrint(
        "({s}^{s}) / ({s})",
        .{
            problem.variable,
            rationalExponentSource(raised_exponent),
            rationalValueSource(raised_exponent),
        },
    )).simplify();
}

fn integrateDivision(
    comptime expression: ast.Expr,
    comptime binary: ast.Binary,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const denominator = expression.node(binary.right);
    if (denominator != .symbol or
        !std.mem.eql(u8, denominator.symbol, problem.variable) or
        problem.domain != .real)
    {
        return null;
    }
    const numerator = multi.extractRoot(
        expression.nodes,
        binary.left,
        expression.source,
    );
    if (dependsOn(numerator, problem.variable)) return null;
    const logarithm = parser.parse(std.fmt.comptimePrint(
        "ln(abs({s}))",
        .{problem.variable},
    ));
    return multiplyExpressions(numerator, logarithm).simplify();
}

const FunctionKind = enum {
    sin,
    cos,
    exp,
};

const AffineArgument = struct {
    argument: ast.Expr,
    slope: ast.Expr,
};

fn affineArgument(
    comptime expression: ast.Expr,
    child: ast.NodeId,
    comptime problem: IntegralProblem,
) ?AffineArgument {
    const argument = multi.extractRoot(
        expression.nodes,
        child,
        expression.source,
    ).simplify();
    const slope = differentiation.differentiate(
        argument,
        problem.variable,
    ).simplify();
    if (dependsOn(slope, problem.variable)) return null;
    if (isZeroExpression(slope)) return null;
    if (!provablyNonzero(slope, problem.assumptions)) return null;
    return .{ .argument = argument, .slope = slope };
}

fn integrateAffineFunction(
    comptime expression: ast.Expr,
    child: ast.NodeId,
    comptime function: FunctionKind,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const affine = affineArgument(expression, child, problem) orelse return null;
    const argument_source = affine.argument.render();
    const numerator = switch (function) {
        .sin => parser.parse(std.fmt.comptimePrint(
            "-cos({s})",
            .{argument_source},
        )),
        .cos => parser.parse(std.fmt.comptimePrint(
            "sin({s})",
            .{argument_source},
        )),
        .exp => parser.parse(std.fmt.comptimePrint(
            "exp({s})",
            .{argument_source},
        )),
    };
    return divideExpressions(numerator, affine.slope).simplify();
}

fn integrateProduct(
    comptime expression: ast.Expr,
    comptime problem: IntegralProblem,
) ?ast.Expr {
    const factors = multiplicativeOperands(expression);

    var function_index: ?usize = null;
    var function_kind: FunctionKind = undefined;
    var function_child: ast.NodeId = undefined;
    for (factors, 0..) |factor, index| {
        switch (expression.node(factor)) {
            .sin => |child| {
                if (function_index != null) return null;
                function_index = index;
                function_kind = .sin;
                function_child = child;
            },
            .cos => |child| {
                if (function_index != null) return null;
                function_index = index;
                function_kind = .cos;
                function_child = child;
            },
            .exp => |child| {
                if (function_index != null) return null;
                function_index = index;
                function_kind = .exp;
                function_child = child;
            },
            else => {},
        }
    }

    if (function_index) |special_index| {
        var polynomial_factors: [ast.construction_node_limit]ast.NodeId = undefined;
        var polynomial_factor_count: usize = 0;
        for (factors, 0..) |factor, index| {
            if (index == special_index) continue;
            polynomial_factors[polynomial_factor_count] = factor;
            polynomial_factor_count += 1;
        }
        const polynomial_expression = if (polynomial_factor_count == 0)
            parser.parse("1")
        else
            expressionFromFactors(
                expression,
                polynomial_factors[0..polynomial_factor_count],
            );
        if (polynomialConvertible(polynomial_expression)) {
            const affine = affineArgument(
                expression,
                function_child,
                problem,
            ) orelse return null;
            return integratePolynomialFunction(
                polynomial_expression.asPolynomial(),
                function_kind,
                affine.argument,
                affine.slope,
                problem.variable,
            ).simplify();
        }
    }

    var constant_factors: [ast.construction_node_limit]ast.NodeId = undefined;
    var dependent_factors: [ast.construction_node_limit]ast.NodeId = undefined;
    var constant_count: usize = 0;
    var dependent_count: usize = 0;
    for (factors) |factor| {
        const factor_expression = multi.extractRoot(
            expression.nodes,
            factor,
            expression.source,
        );
        if (dependsOn(factor_expression, problem.variable)) {
            dependent_factors[dependent_count] = factor;
            dependent_count += 1;
        } else {
            constant_factors[constant_count] = factor;
            constant_count += 1;
        }
    }
    if (constant_count == 0 or dependent_count == 0) return null;

    const dependent = expressionFromFactors(
        expression,
        dependent_factors[0..dependent_count],
    );
    const closed = integrateClosed(dependent, problem) orelse return null;
    const constant = expressionFromFactors(
        expression,
        constant_factors[0..constant_count],
    );
    return multiplyExpressions(constant, closed).simplify();
}

fn integratePolynomialFunction(
    comptime coefficient: polynomial.Polynomial,
    comptime function: FunctionKind,
    comptime argument: ast.Expr,
    comptime slope: ast.Expr,
    comptime variable: []const u8,
) ast.Expr {
    const coefficient_expression = coefficient.toExpr();
    const argument_source = argument.render();
    const boundary_factor = switch (function) {
        .sin => parser.parse(std.fmt.comptimePrint(
            "-cos({s})",
            .{argument_source},
        )),
        .cos => parser.parse(std.fmt.comptimePrint(
            "sin({s})",
            .{argument_source},
        )),
        .exp => parser.parse(std.fmt.comptimePrint(
            "exp({s})",
            .{argument_source},
        )),
    };
    const boundary = divideExpressions(
        multiplyExpressions(coefficient_expression, boundary_factor),
        slope,
    );
    const derivative = coefficient.diffName(variable);
    if (derivative.terms.len == 0) return boundary.simplify();

    const next_function: FunctionKind = switch (function) {
        .sin => .cos,
        .cos => .sin,
        .exp => .exp,
    };
    const remainder = divideExpressions(
        integratePolynomialFunction(
            derivative,
            next_function,
            argument,
            slope,
            variable,
        ),
        slope,
    );
    return switch (function) {
        .sin => addExpressions(&.{ boundary, remainder }).simplify(),
        .cos, .exp => subtractExpressions(boundary, remainder).simplify(),
    };
}

fn applyBounds(
    comptime antiderivative: ast.Expr,
    comptime variable: []const u8,
    comptime bounds: IntegralBounds,
) ast.Expr {
    const upper = substitution.substituteName(
        antiderivative,
        variable,
        bounds.to,
    );
    const lower = substitution.substituteName(
        antiderivative,
        variable,
        bounds.from,
    );
    return subtractExpressions(upper, lower).simplify();
}

fn unsupportedResult(comptime expression: ast.Expr) IntegrationResult {
    return .{ .unsupported = .{
        .message = std.fmt.comptimePrint(
            "no bounded symbolic strategy matched '{s}'",
            .{expression.render()},
        ),
    } };
}

fn assumptionsFromOptions(comptime options: anytype) []const domain_module.Assumption {
    if (!@hasField(@TypeOf(options), "assumptions")) return &.{};
    const count = ast.tupleLength(@TypeOf(options.assumptions));
    var storage: [count]domain_module.Assumption = undefined;
    inline for (options.assumptions, 0..) |assumption, index| {
        storage[index] = @as(domain_module.Assumption, assumption);
    }
    const exact_assumptions = storage;
    return &exact_assumptions;
}

fn expressionValue(comptime value: anytype) ast.Expr {
    const T = @TypeOf(value);
    if (T == ast.Expr) return value;
    var builder = build.Builder{};
    const root = if (T == exact.Rational)
        builder.rational(value)
    else switch (@typeInfo(T)) {
        .comptime_int, .int => builder.integer(
            std.math.cast(i64, value) orelse
                @compileError("Bombelli integral bound is outside exact i64 range"),
        ),
        .comptime_float, .float => blk: {
            const converted: f64 = @floatCast(value);
            if (!std.math.isFinite(converted)) {
                @compileError("Bombelli integral bound must be finite");
            }
            break :blk builder.float(converted);
        },
        .pointer => |pointer| if (isStringPointer(pointer))
            return parser.parse(value)
        else
            unsupportedBound(T),
        else => unsupportedBound(T),
    };
    return builder.finish(root, "integral bound");
}

fn additiveOperands(comptime expression: ast.Expr) []const ast.NodeId {
    return switch (expression.node(expression.root)) {
        .add_nary => |operands| operands,
        .add => |binary| &.{ binary.left, binary.right },
        else => &.{expression.root},
    };
}

fn multiplicativeOperands(comptime expression: ast.Expr) []const ast.NodeId {
    return switch (expression.node(expression.root)) {
        .mul_nary => |operands| operands,
        .mul => |binary| &.{ binary.left, binary.right },
        else => &.{expression.root},
    };
}

fn expressionFromFactors(
    comptime expression: ast.Expr,
    comptime factors: []const ast.NodeId,
) ast.Expr {
    var sources: [ast.construction_node_limit][]const u8 = undefined;
    for (factors, 0..) |factor, index| {
        sources[index] = multi.extractRoot(
            expression.nodes,
            factor,
            expression.source,
        ).render();
    }
    return parseProduct(sources[0..factors.len]).simplify();
}

fn addExpressions(comptime expressions: []const ast.Expr) ast.Expr {
    if (expressions.len == 0) return parser.parse("0");
    var source: []const u8 = std.fmt.comptimePrint(
        "({s})",
        .{expressions[0].render()},
    );
    for (expressions[1..]) |expression| {
        source = std.fmt.comptimePrint(
            "{s} + ({s})",
            .{ source, expression.render() },
        );
    }
    return parser.parse(source);
}

fn parseProduct(comptime sources: []const []const u8) ast.Expr {
    if (sources.len == 0) return parser.parse("1");
    var source: []const u8 = std.fmt.comptimePrint("({s})", .{sources[0]});
    for (sources[1..]) |factor| {
        source = std.fmt.comptimePrint("{s} * ({s})", .{ source, factor });
    }
    return parser.parse(source);
}

fn multiplyExpressions(
    comptime left: ast.Expr,
    comptime right: ast.Expr,
) ast.Expr {
    return parser.parse(std.fmt.comptimePrint(
        "({s}) * ({s})",
        .{ left.render(), right.render() },
    ));
}

fn divideExpressions(
    comptime numerator: ast.Expr,
    comptime denominator: ast.Expr,
) ast.Expr {
    return parser.parse(std.fmt.comptimePrint(
        "({s}) / ({s})",
        .{ numerator.render(), denominator.render() },
    ));
}

fn subtractExpressions(
    comptime left: ast.Expr,
    comptime right: ast.Expr,
) ast.Expr {
    return parser.parse(std.fmt.comptimePrint(
        "({s}) - ({s})",
        .{ left.render(), right.render() },
    ));
}

fn negateExpression(comptime expression: ast.Expr) ast.Expr {
    return parser.parse(std.fmt.comptimePrint(
        "-({s})",
        .{expression.render()},
    ));
}

fn polynomialConvertible(comptime expression: ast.Expr) bool {
    var convertible = [_]bool{false} ** expression.nodes.len;
    inline for (expression.nodes, 0..) |node, index| {
        convertible[index] = switch (node) {
            .integer, .rational, .symbol => true,
            .float, .div, .sin, .cos, .tan, .atan, .abs, .exp, .ln => false,
            .add, .sub, .mul => |binary| convertible[@intCast(binary.left)] and
                convertible[@intCast(binary.right)],
            .add_nary, .mul_nary => |operands| blk: {
                var all = true;
                for (operands) |child| all =
                    all and convertible[@intCast(child)];
                break :blk all;
            },
            .pow => |power| convertible[@intCast(power.base)] and
                power.exponent.isInteger() and
                power.exponent.numerator >= 0 and
                power.exponent.numerator <= std.math.maxInt(u32),
            .negate => |child| convertible[@intCast(child)],
        };
    }
    return convertible[@intCast(expression.root)];
}

fn dependsOn(
    comptime expression: ast.Expr,
    comptime variable: []const u8,
) bool {
    var dependent = [_]bool{false} ** expression.nodes.len;
    inline for (expression.nodes, 0..) |node, index| {
        dependent[index] = switch (node) {
            .integer, .rational, .float => false,
            .symbol => |name| std.mem.eql(u8, name, variable),
            .add, .sub, .mul, .div => |binary| dependent[@intCast(binary.left)] or
                dependent[@intCast(binary.right)],
            .add_nary, .mul_nary => |operands| blk: {
                var any = false;
                for (operands) |child| any =
                    any or dependent[@intCast(child)];
                break :blk any;
            },
            .pow => |power| dependent[@intCast(power.base)],
            .negate, .sin, .cos, .tan, .atan, .abs, .exp, .ln => |child| dependent[@intCast(child)],
        };
    }
    return dependent[@intCast(expression.root)];
}

fn provablyNonzero(
    comptime expression: ast.Expr,
    comptime assumptions: []const domain_module.Assumption,
) bool {
    var nonzero_nodes = [_]bool{false} ** expression.nodes.len;
    inline for (expression.nodes, 0..) |node, index| {
        nonzero_nodes[index] = switch (node) {
            .integer => |value| value != 0,
            .rational => |value| !value.isZero(),
            .float => |value| value != 0.0,
            .symbol => |name| symbolNonzero(name, assumptions),
            .mul => |binary| nonzero_nodes[@intCast(binary.left)] and
                nonzero_nodes[@intCast(binary.right)],
            .mul_nary => |operands| blk: {
                var all = true;
                for (operands) |child| all =
                    all and nonzero_nodes[@intCast(child)];
                break :blk all;
            },
            .div => |binary| nonzero_nodes[@intCast(binary.left)] and
                nonzero_nodes[@intCast(binary.right)],
            .pow => |power| power.exponent.isZero() or
                nonzero_nodes[@intCast(power.base)],
            .negate, .abs => |child| nonzero_nodes[@intCast(child)],
            .exp => true,
            else => false,
        };
    }
    return nonzero_nodes[@intCast(expression.root)];
}

fn symbolNonzero(
    comptime name: []const u8,
    comptime assumptions: []const domain_module.Assumption,
) bool {
    for (assumptions) |assumption| {
        if (std.mem.eql(u8, assumption.symbol, name) and
            (assumption.kind == .nonzero or assumption.kind == .positive))
        {
            return true;
        }
    }
    return false;
}

fn isZeroExpression(comptime expression: ast.Expr) bool {
    return switch (expression.node(expression.root)) {
        .integer => |value| value == 0,
        .rational => |value| value.isZero(),
        .float => |value| value == 0.0,
        else => false,
    };
}

fn rationalExponentSource(comptime value: exact.Rational) []const u8 {
    return if (value.denominator == 1)
        std.fmt.comptimePrint("{d}", .{value.numerator})
    else
        std.fmt.comptimePrint("({d}/{d})", .{
            value.numerator,
            value.denominator,
        });
}

fn rationalValueSource(comptime value: exact.Rational) []const u8 {
    return if (value.denominator == 1)
        std.fmt.comptimePrint("{d}", .{value.numerator})
    else
        std.fmt.comptimePrint("({d}/{d})", .{
            value.numerator,
            value.denominator,
        });
}

fn isStringPointer(comptime pointer: std.builtin.Type.Pointer) bool {
    if (pointer.size == .slice) return pointer.child == u8;
    if (pointer.size != .one) return false;
    return switch (@typeInfo(pointer.child)) {
        .array => |array| array.child == u8,
        else => false,
    };
}

fn unsupportedBound(comptime T: type) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli does not support integral bound type '{s}'",
        .{@typeName(T)},
    ));
}
