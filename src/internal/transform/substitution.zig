const std = @import("std");
const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");
const exact = @import("../core/exact.zig");
const parser = @import("../parse/parser.zig");

pub fn substitute(
    comptime expression: ast.Expr,
    comptime replacements: anytype,
) ast.Expr {
    validateReplacements(@TypeOf(replacements));
    validateReplacementNames(@TypeOf(replacements), expression.nodes);
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    const resolver = ReplacementResolver(@TypeOf(replacements)){
        .replacements = replacements,
    };
    const root = rebuild(
        &builder,
        expression.nodes,
        expression.root,
        &cache,
        resolver,
    );
    return builder.finish(root, expression.source);
}

pub fn substituteName(
    comptime expression: ast.Expr,
    comptime name: []const u8,
    comptime replacement: ast.Expr,
) ast.Expr {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    const root = rebuild(
        &builder,
        expression.nodes,
        expression.root,
        &cache,
        NameResolver(name, replacement){},
    );
    return builder.finish(root, expression.source);
}

pub fn substituteVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime replacements: anytype,
) ast.ExprVector(N) {
    validateReplacements(@TypeOf(replacements));
    validateReplacementNames(@TypeOf(replacements), expression.nodes);
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    const resolver = ReplacementResolver(@TypeOf(replacements)){
        .replacements = replacements,
    };
    var roots: [N]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |root, index| {
        roots[index] = rebuild(
            &builder,
            expression.nodes,
            root,
            &cache,
            resolver,
        );
    }
    return builder.finishVector(N, roots, expression.sources);
}

pub fn substituteMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime replacements: anytype,
) ast.ExprMatrix(R, C) {
    validateReplacements(@TypeOf(replacements));
    validateReplacementNames(@TypeOf(replacements), expression.nodes);
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    const resolver = ReplacementResolver(@TypeOf(replacements)){
        .replacements = replacements,
    };
    var roots: [R][C]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            roots[row_index][column_index] = rebuild(
                &builder,
                expression.nodes,
                root,
                &cache,
                resolver,
            );
        }
    }
    return builder.finishMatrix(R, C, roots, expression.sources);
}

fn ReplacementResolver(comptime Replacements: type) type {
    return struct {
        replacements: Replacements,

        fn resolve(
            comptime self: @This(),
            builder: *build.Builder,
            comptime name: []const u8,
        ) ?ast.NodeId {
            if (!@hasField(Replacements, name)) return null;
            return materializeReplacement(builder, @field(self.replacements, name));
        }
    };
}

fn NameResolver(
    comptime target_name: []const u8,
    comptime replacement: ast.Expr,
) type {
    return struct {
        fn resolve(
            comptime _: @This(),
            builder: *build.Builder,
            comptime name: []const u8,
        ) ?ast.NodeId {
            if (!std.mem.eql(u8, name, target_name)) return null;
            return builder.cloneExpression(replacement);
        }
    };
}

fn rebuild(
    builder: *build.Builder,
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    cache: []ast.NodeId,
    comptime resolver: anytype,
) ast.NodeId {
    const index: usize = @intCast(id);
    if (cache[index] != ast.invalid_node) return cache[index];

    const result = switch (nodes[index]) {
        .symbol => |name| resolver.resolve(builder, name) orelse builder.symbol(name),
        .integer => |value| builder.integer(value),
        .rational => |value| builder.rational(value),
        .float => |value| builder.float(value),
        .constant => |value| builder.constant(value),
        .add_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuild(
                    builder,
                    nodes,
                    child,
                    cache,
                    resolver,
                );
            }
            break :blk builder.addNary(rebuilt[0..operands.len]);
        },
        .sub => |binary| builder.sub(
            rebuild(builder, nodes, binary.left, cache, resolver),
            rebuild(builder, nodes, binary.right, cache, resolver),
        ),
        .mul_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuild(
                    builder,
                    nodes,
                    child,
                    cache,
                    resolver,
                );
            }
            break :blk builder.mulNary(rebuilt[0..operands.len]);
        },
        .div => |binary| builder.div(
            rebuild(builder, nodes, binary.left, cache, resolver),
            rebuild(builder, nodes, binary.right, cache, resolver),
        ),
        .pow => |power| builder.power(
            rebuild(builder, nodes, power.base, cache, resolver),
            power.exponent,
        ),
        .unary => |unary| builder.unary(
            unary.op,
            rebuild(builder, nodes, unary.child, cache, resolver),
        ),
        .atan2 => |binary| builder.arctangent2(
            rebuild(builder, nodes, binary.left, cache, resolver),
            rebuild(builder, nodes, binary.right, cache, resolver),
        ),
        .hypot => |binary| builder.hypotenuse(
            rebuild(builder, nodes, binary.left, cache, resolver),
            rebuild(builder, nodes, binary.right, cache, resolver),
        ),
    };
    cache[index] = result;
    return result;
}

fn materializeReplacement(
    builder: *build.Builder,
    comptime replacement: anytype,
) ast.NodeId {
    const Replacement = @TypeOf(replacement);
    if (Replacement == ast.Expr) {
        return builder.cloneExpression(replacement);
    }
    if (Replacement == exact.Rational) {
        return builder.rational(replacement);
    }

    return switch (@typeInfo(Replacement)) {
        .comptime_int, .int => builder.integer(
            std.math.cast(i64, replacement) orelse
                @compileError("Bombelli substitution integer is outside exact i64 range"),
        ),
        .comptime_float, .float => blk: {
            const value: f64 = @floatCast(replacement);
            if (!std.math.isFinite(value)) {
                @compileError("Bombelli substitution float must be finite");
            }
            break :blk builder.float(value);
        },
        .pointer => |pointer| if (isStringPointer(pointer))
            builder.cloneExpression(parser.parse(replacement))
        else
            unsupportedReplacement(Replacement),
        else => unsupportedReplacement(Replacement),
    };
}

fn validateReplacements(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError("Bombelli substitution expects a struct of named replacements"),
    }
}

fn validateReplacementNames(
    comptime T: type,
    comptime nodes: []const ast.Node,
) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var found = false;
        for (nodes) |node| {
            if (node == .symbol and std.mem.eql(u8, node.symbol, field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "Bombelli substitution replacement '.{s}' does not name a symbol in the expression",
                .{field.name},
            ));
        }
    }
}

fn isStringPointer(comptime pointer: std.builtin.Type.Pointer) bool {
    if (pointer.size == .slice) return pointer.child == u8;
    if (pointer.size != .one) return false;
    return switch (@typeInfo(pointer.child)) {
        .array => |array| array.child == u8,
        else => false,
    };
}

fn unsupportedReplacement(comptime T: type) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Bombelli substitution does not support replacement type '{s}'",
        .{@typeName(T)},
    ));
}
