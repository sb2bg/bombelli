//! Compile Jacobian products as ordinary expression DAGs. Forward tangents
//! and reverse adjoints are symbolic seeds, eliminated into straight-line
//! runtime code by the existing evaluator and emission backends.

const std = @import("std");
const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");
const limits = @import("../core/limits.zig");
const differentiation = @import("../transform/differentiation.zig");
const evaluation = @import("../runtime/evaluation.zig");

pub const Kind = enum { jvp, vjp };
pub const Strategy = enum { auto, direct, symbolic };
pub const Method = enum { forward, reverse, symbolic };
pub const Options = struct { strategy: Strategy = .auto };

/// Counts are scalar DAG operations, not CPU cycles. Estimates ignore
/// simplification and cross-node sharing of local slopes.
pub const Inspection = struct {
    method: Method,
    estimated_direct_operations: usize,
    estimated_symbolic_operations: usize,
    structural_nonzeros: usize,
    jacobian_entries: usize,
    operations: usize,
    node_count: usize,
    /// Nodes consumed more than once, including uses as output roots.
    shared_nodes: usize,
    /// Logical evaluator slots, before backend optimization/register allocation.
    temporary_scalars: usize,
    construction_peak_nodes: usize,
};

pub fn Program(comptime R: usize, comptime S: usize) type {
    return struct {
        expression: ast.ExprVector(R),
        seed_names: [S][]const u8,
        input_nodes: []const ast.Node,
        contract: []const []const u8,
        inspection: Inspection,

        const Self = @This();

        pub inline fn eval(comptime self: Self, inputs: anytype, seed: [S]f64) [R]f64 {
            return self.evalAs(f64, inputs, seed);
        }

        pub inline fn evalAs(comptime self: Self, comptime T: type, inputs: anytype, seed: [S]T) [R]T {
            @setEvalBranchQuota(limits.eval_branch.evaluation);
            comptime evaluation.validateInputFields(@TypeOf(inputs), &.{self.input_nodes}, self.contract, &.{}, "Jacobian product");
            return evaluation.evaluateVectorWithVariablesAs(T, R, S, self.expression, inputs, self.seed_names, seed);
        }

        pub inline fn evalInto(comptime self: Self, output: *[R]f64, inputs: anytype, seed: [S]f64) void {
            output.* = self.eval(inputs, seed);
        }

        pub inline fn evalIntoAs(comptime self: Self, comptime T: type, output: *[R]T, inputs: anytype, seed: [S]T) void {
            output.* = self.evalAs(T, inputs, seed);
        }

        pub fn inspect(comptime self: Self) Inspection {
            return self.inspection;
        }

        /// Emitted inputs include the ordinary model symbols and seed_names.
        /// Seeds absent from the finished DAG are omitted by the backend.
        pub fn emit(comptime self: Self, comptime options: anytype) []const u8 {
            return self.expression.emit(options);
        }
    };
}

pub fn compile(comptime kind: Kind, comptime model: anytype, comptime options: Options) Program(
    if (kind == .jvp) @TypeOf(model).output_count else @TypeOf(model).variable_count,
    if (kind == .jvp) @TypeOf(model).variable_count else @TypeOf(model).output_count,
) {
    @setEvalBranchQuota(limits.eval_branch.transform);
    const M = @TypeOf(model).output_count;
    const N = @TypeOf(model).variable_count;
    const R = if (kind == .jvp) M else N;
    const S = if (kind == .jvp) N else M;
    const dependencies = dependencyMasks(model.outputs.nodes, model.outputs.roots, model.variables);
    const contract = model.variables[0..] ++ model.inputs[0..];
    const seeds = seedNames(S, model.outputs.nodes, contract);
    var inspection = estimate(kind, model, dependencies);
    inspection.method = switch (options.strategy) {
        .direct => if (kind == .jvp) .forward else .reverse,
        .symbolic => .symbolic,
        .auto => if (inspection.estimated_symbolic_operations < inspection.estimated_direct_operations)
            .symbolic
        else if (kind == .jvp) .forward else .reverse,
    };
    const expression = if (inspection.method == .symbolic)
        symbolic(kind, model, dependencies, seeds)
    else
        direct(kind, model, dependencies, seeds);
    const metrics = expression.metrics();
    inspection.operations = operationCount(expression.nodes);
    inspection.node_count = metrics.node_count;
    inspection.shared_nodes = sharedNodeCount(expression);
    inspection.temporary_scalars = metrics.node_count;
    inspection.construction_peak_nodes = metrics.construction_peak_nodes;
    return Program(R, S){
        .expression = expression,
        .seed_names = seeds,
        .input_nodes = model.outputs.nodes,
        .contract = contract,
        .inspection = inspection,
    };
}

fn children(comptime node: ast.Node) []const ast.NodeId {
    return switch (node) {
        .add_nary, .mul_nary => |operands| operands,
        .sub, .div, .atan2, .hypot => |binary| &.{ binary.left, binary.right },
        .pow => |power| if (power.exponent.isZero()) &.{} else &.{power.base},
        .unary => |unary| &.{unary.child},
        else => &.{},
    };
}

fn dependencyMasks(comptime nodes: []const ast.Node, comptime roots: anytype, comptime variables: anytype) [nodes.len][variables.len]bool {
    var result = [_][variables.len]bool{[_]bool{false} ** variables.len} ** nodes.len;
    for (nodes, 0..) |node, index| {
        if (node == .symbol) {
            for (variables, 0..) |name, column| result[index][column] = std.mem.eql(u8, node.symbol, name);
        } else {
            for (children(node)) |child| {
                for (0..variables.len) |column| result[index][column] = result[index][column] or result[child][column];
            }
        }
    }
    // Intersect variable dependence with derivative reachability from outputs.
    // For example, none of the work below f(x)^0 needs a tangent or adjoint.
    var needed = [_]bool{false} ** nodes.len;
    for (roots) |root| needed[root] = active(result[root]);
    for (0..nodes.len) |offset| {
        const index = nodes.len - 1 - offset;
        if (!needed[index]) continue;
        for (children(nodes[index])) |child| {
            if (active(result[child])) needed[child] = true;
        }
    }
    for (needed, 0..) |used, index| {
        if (!used) result[index] = [_]bool{false} ** variables.len;
    }
    return result;
}

fn active(comptime mask: anytype) bool {
    for (mask) |value| if (value) return true;
    return false;
}

fn seedNames(comptime S: usize, comptime nodes: []const ast.Node, comptime contract: []const []const u8) [S][]const u8 {
    var names: [S][]const u8 = undefined;
    var candidate: usize = 0;
    for (0..S) |index| {
        while (true) : (candidate += 1) {
            const name = std.fmt.comptimePrint("bombelli_seed_{d}", .{candidate});
            var collision = false;
            for (nodes) |node| {
                if (node == .symbol and std.mem.eql(u8, node.symbol, name)) collision = true;
            }
            for (contract) |entry| {
                if (std.mem.eql(u8, entry, name)) collision = true;
            }
            if (!collision) {
                names[index] = name;
                candidate += 1;
                break;
            }
        }
    }
    return names;
}

// Differentiate a tiny local expression using the established derivative
// rules. Placeholder nodes are rebound to primal children during cloning.
// This keeps all elementary-function mathematics in one implementation.
fn localSlope(comptime node: ast.Node, comptime operand: usize) ast.Expr {
    var builder = build.Builder{};
    const left = builder.symbol("left");
    const right = builder.symbol("right");
    const root = switch (node) {
        .sub => builder.sub(left, right),
        .div => builder.div(left, right),
        .atan2 => builder.arctangent2(left, right),
        .hypot => builder.hypotenuse(left, right),
        .pow => |power| builder.power(left, power.exponent),
        .unary => |unary| builder.unary(unary.op, left),
        else => unreachable,
    };
    return differentiation.differentiate(builder.finish(root, "local derivative"), if (operand == 0) "left" else "right").simplify();
}

const Context = struct {
    builder: *build.Builder,
    clones: []ast.NodeId,

    fn clone(self: Context, comptime nodes: []const ast.Node, comptime id: ast.NodeId) ast.NodeId {
        return self.builder.cloneNode(nodes, id, self.clones);
    }

    fn multiply(self: Context, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        if (self.builder.node(left) == .integer and self.builder.node(left).integer == 1) return right;
        if (self.builder.node(right) == .integer and self.builder.node(right).integer == 1) return left;
        return self.builder.mul(left, right);
    }

    fn accumulate(self: Context, slot: *ast.NodeId, term: ast.NodeId) void {
        slot.* = if (slot.* == ast.invalid_node) term else self.builder.add(slot.*, term);
    }

    fn slopes(self: Context, comptime nodes: []const ast.Node, comptime node: ast.Node, comptime dependencies: anytype) [children(node).len]ast.NodeId {
        const operands = children(node);
        var result = [_]ast.NodeId{ast.invalid_node} ** operands.len;
        if (node == .add_nary) {
            for (operands, 0..) |child, i| {
                if (active(dependencies[child])) result[i] = self.builder.integer(1);
            }
        } else if (node == .mul_nary) {
            // Prefix/suffix products keep wide products linear in arity and
            // remain valid at zero factors (no division by the primal value).
            var prefix: [operands.len + 1]ast.NodeId = undefined;
            prefix[0] = self.builder.integer(1);
            for (operands, 0..) |child, i| prefix[i + 1] = self.multiply(prefix[i], self.clone(nodes, child));
            var suffix = self.builder.integer(1);
            for (0..operands.len) |offset| {
                const i = operands.len - 1 - offset;
                const child = operands[i];
                if (active(dependencies[child])) result[i] = self.multiply(prefix[i], suffix);
                suffix = self.multiply(self.clone(nodes, child), suffix);
            }
        } else {
            for (operands, 0..) |child, i| {
                if (!active(dependencies[child])) continue;
                const slope = localSlope(node, i);
                var cache = [_]ast.NodeId{ast.invalid_node} ** slope.nodes.len;
                for (slope.nodes, 0..) |slope_node, index| {
                    if (slope_node == .symbol) {
                        cache[index] = self.clone(nodes, operands[if (std.mem.eql(u8, slope_node.symbol, "left")) 0 else 1]);
                    }
                }
                result[i] = self.builder.cloneNode(slope.nodes, slope.root, &cache);
            }
        }
        return result;
    }
};

fn direct(comptime kind: Kind, comptime model: anytype, comptime dependencies: anytype, comptime seeds: anytype) ast.ExprVector(if (kind == .jvp) @TypeOf(model).output_count else @TypeOf(model).variable_count) {
    const nodes = model.outputs.nodes;
    const M = @TypeOf(model).output_count;
    const N = @TypeOf(model).variable_count;
    const R = if (kind == .jvp) M else N;
    var builder = build.Builder{};
    var clones = [_]ast.NodeId{ast.invalid_node} ** nodes.len;
    const context = Context{ .builder = &builder, .clones = &clones };
    var derivatives = [_]ast.NodeId{ast.invalid_node} ** nodes.len;
    var roots = [_]ast.NodeId{ast.invalid_node} ** R;
    if (kind == .jvp) {
        for (nodes, 0..) |node, index| {
            if (!active(dependencies[index])) continue;
            if (node == .symbol) {
                for (model.variables, 0..) |name, column| {
                    if (std.mem.eql(u8, node.symbol, name)) derivatives[index] = builder.symbol(seeds[column]);
                }
                continue;
            }
            const slopes = context.slopes(nodes, node, dependencies);
            for (children(node), slopes) |child, slope| {
                if (slope != ast.invalid_node) context.accumulate(&derivatives[index], context.multiply(slope, derivatives[child]));
            }
        }
        for (model.outputs.roots, 0..) |root, row| roots[row] = derivatives[root];
    } else {
        for (model.outputs.roots, 0..) |root, row| {
            if (active(dependencies[root])) context.accumulate(&derivatives[root], builder.symbol(seeds[row]));
        }
        for (0..nodes.len) |offset| {
            const index = nodes.len - 1 - offset;
            if (derivatives[index] == ast.invalid_node) continue;
            const node = nodes[index];
            if (node == .symbol) {
                for (model.variables, 0..) |name, column| {
                    if (std.mem.eql(u8, node.symbol, name)) roots[column] = derivatives[index];
                }
                continue;
            }
            const slopes = context.slopes(nodes, node, dependencies);
            for (children(node), slopes) |child, slope| {
                if (slope != ast.invalid_node) context.accumulate(&derivatives[child], context.multiply(slope, derivatives[index]));
            }
        }
    }
    for (&roots) |*root| {
        if (root.* == ast.invalid_node) root.* = builder.integer(0);
    }
    return builder.finishVector(R, roots, [_][]const u8{"Jacobian product"} ** R);
}

fn symbolic(comptime kind: Kind, comptime model: anytype, comptime dependencies: anytype, comptime seeds: anytype) ast.ExprVector(if (kind == .jvp) @TypeOf(model).output_count else @TypeOf(model).variable_count) {
    const R = if (kind == .jvp) @TypeOf(model).output_count else @TypeOf(model).variable_count;
    var builder = build.Builder{};
    var clones: [0]ast.NodeId = .{};
    const context = Context{ .builder = &builder, .clones = &clones };
    var roots = [_]ast.NodeId{ast.invalid_node} ** R;
    var peak: usize = 0;
    for (model.outputs.roots, 0..) |root, row| {
        for (model.variable_tags, 0..) |variable, column| {
            if (!dependencies[root][column]) continue;
            const derivative = model.outputs.at(row).diff(variable).simplify();
            peak = @max(peak, derivative.construction_peak_nodes);
            const term = context.multiply(builder.cloneExpression(derivative), builder.symbol(seeds[if (kind == .jvp) column else row]));
            context.accumulate(&roots[if (kind == .jvp) row else column], term);
        }
    }
    for (&roots) |*root| {
        if (root.* == ast.invalid_node) root.* = builder.integer(0);
    }
    var result = builder.finishVector(R, roots, [_][]const u8{"symbolic Jacobian product"} ** R);
    result.construction_peak_nodes = @max(peak, result.construction_peak_nodes);
    return result;
}

fn operationCount(comptime nodes: []const ast.Node) usize {
    var total: usize = 0;
    for (nodes) |node| total += switch (node) {
        .integer, .rational, .float, .constant, .symbol => 0,
        .add_nary, .mul_nary => |operands| operands.len - 1,
        else => 1,
    };
    return total;
}

fn sharedNodeCount(comptime expression: anytype) usize {
    var uses = [_]usize{0} ** expression.nodes.len;
    for (expression.nodes) |node| {
        // A zero power still has a primal operand in the stored program.
        if (node == .pow) {
            uses[node.pow.base] += 1;
        } else {
            for (children(node)) |child| uses[child] += 1;
        }
    }
    for (expression.roots) |root| uses[root] += 1;
    var count: usize = 0;
    for (uses) |use| {
        if (use > 1) count += 1;
    }
    return count;
}

fn estimate(comptime kind: Kind, comptime model: anytype, comptime dependencies: anytype) Inspection {
    var direct_ops = operationCount(model.outputs.nodes);
    var symbolic_ops = direct_ops;
    var nonzeros: usize = 0;
    for (model.outputs.roots) |root| {
        for (dependencies[root]) |dependent| {
            if (dependent) nonzeros += 1;
        }
    }
    for (model.outputs.nodes) |node| {
        for (children(node), 0..) |child, operand| {
            if (!active(dependencies[child])) continue;
            const slope_ops = switch (node) {
                .add_nary => 0,
                .mul_nary => |operands| operands.len - 2,
                else => operationCount(localSlope(node, operand).nodes),
            };
            direct_ops += slope_ops + 2;
            for (dependencies[child]) |dependent| {
                if (dependent) symbolic_ops += slope_ops + 1;
            }
        }
    }
    symbolic_ops += 2 * nonzeros;
    // Reverse mode also merges repeated output seeds at shared roots.
    if (kind == .vjp) direct_ops += model.outputs.roots.len;
    return .{
        .method = undefined,
        .estimated_direct_operations = direct_ops,
        .estimated_symbolic_operations = symbolic_ops,
        .structural_nonzeros = nonzeros,
        .jacobian_entries = @TypeOf(model).output_count * @TypeOf(model).variable_count,
        .operations = 0,
        .node_count = 0,
        .shared_nodes = 0,
        .temporary_scalars = 0,
        .construction_peak_nodes = 0,
    };
}
