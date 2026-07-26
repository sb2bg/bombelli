const std = @import("std");
const ast = @import("ast.zig");
const build = @import("builder.zig");
const exact = @import("exact.zig");
const parser = @import("parser.zig");

pub fn substitute(
    comptime expression: ast.Expr,
    comptime replacements: anytype,
) ast.Expr {
    validateReplacements(@TypeOf(replacements));
    validateReplacementNames(@TypeOf(replacements), expression.nodes);
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    const root = rebuild(
        &builder,
        expression.nodes,
        expression.root,
        &cache,
        replacements,
    );
    return builder.finish(root, expression.source);
}

pub fn substituteName(
    comptime expression: ast.Expr,
    comptime name: []const u8,
    comptime replacement: ast.Expr,
) ast.Expr {
    var builder = build.Builder{};
    var rebuild_cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    var replacement_cache =
        [_]ast.NodeId{ast.invalid_node} ** replacement.nodes.len;
    const root = rebuildName(
        &builder,
        expression.nodes,
        expression.root,
        &rebuild_cache,
        name,
        replacement,
        &replacement_cache,
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
    var roots: [N]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |root, index| {
        roots[index] = rebuild(
            &builder,
            expression.nodes,
            root,
            &cache,
            replacements,
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
    var roots: [R][C]ast.NodeId = undefined;
    inline for (expression.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            roots[row_index][column_index] = rebuild(
                &builder,
                expression.nodes,
                root,
                &cache,
                replacements,
            );
        }
    }
    return builder.finishMatrix(R, C, roots, expression.sources);
}

fn rebuild(
    builder: *build.Builder,
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    cache: []ast.NodeId,
    comptime replacements: anytype,
) ast.NodeId {
    const index: usize = @intCast(id);
    if (cache[index] != ast.invalid_node) return cache[index];

    const result = switch (nodes[index]) {
        .symbol => |name| if (@hasField(@TypeOf(replacements), name))
            materializeReplacement(builder, @field(replacements, name))
        else
            builder.symbol(name),
        .integer => |value| builder.integer(value),
        .rational => |value| builder.rational(value),
        .float => |value| builder.float(value),
        .add => |binary| builder.add(
            rebuild(builder, nodes, binary.left, cache, replacements),
            rebuild(builder, nodes, binary.right, cache, replacements),
        ),
        .add_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuild(
                    builder,
                    nodes,
                    child,
                    cache,
                    replacements,
                );
            }
            break :blk builder.addNary(rebuilt[0..operands.len]);
        },
        .sub => |binary| builder.sub(
            rebuild(builder, nodes, binary.left, cache, replacements),
            rebuild(builder, nodes, binary.right, cache, replacements),
        ),
        .mul => |binary| builder.mul(
            rebuild(builder, nodes, binary.left, cache, replacements),
            rebuild(builder, nodes, binary.right, cache, replacements),
        ),
        .mul_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuild(
                    builder,
                    nodes,
                    child,
                    cache,
                    replacements,
                );
            }
            break :blk builder.mulNary(rebuilt[0..operands.len]);
        },
        .div => |binary| builder.div(
            rebuild(builder, nodes, binary.left, cache, replacements),
            rebuild(builder, nodes, binary.right, cache, replacements),
        ),
        .pow => |power| builder.power(
            rebuild(builder, nodes, power.base, cache, replacements),
            power.exponent,
        ),
        .negate => |child| builder.negate(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .sin => |child| builder.sine(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .cos => |child| builder.cosine(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .tan => |child| builder.tangent(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .atan => |child| builder.arctangent(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .abs => |child| builder.absolute(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .exp => |child| builder.exponential(
            rebuild(builder, nodes, child, cache, replacements),
        ),
        .ln => |child| builder.logarithm(
            rebuild(builder, nodes, child, cache, replacements),
        ),
    };
    cache[index] = result;
    return result;
}

fn rebuildName(
    builder: *build.Builder,
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    cache: []ast.NodeId,
    comptime name: []const u8,
    comptime replacement: ast.Expr,
    replacement_cache: []ast.NodeId,
) ast.NodeId {
    const index: usize = @intCast(id);
    if (cache[index] != ast.invalid_node) return cache[index];

    const result = switch (nodes[index]) {
        .symbol => |symbol_name| if (std.mem.eql(u8, symbol_name, name))
            cloneNode(
                builder,
                replacement.nodes,
                replacement.root,
                replacement_cache,
            )
        else
            builder.symbol(symbol_name),
        .integer => |value| builder.integer(value),
        .rational => |value| builder.rational(value),
        .float => |value| builder.float(value),
        .add => |binary| builder.add(
            rebuildName(
                builder,
                nodes,
                binary.left,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
            rebuildName(
                builder,
                nodes,
                binary.right,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
        ),
        .add_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuildName(
                    builder,
                    nodes,
                    child,
                    cache,
                    name,
                    replacement,
                    replacement_cache,
                );
            }
            break :blk builder.addNary(rebuilt[0..operands.len]);
        },
        .sub => |binary| builder.sub(
            rebuildName(
                builder,
                nodes,
                binary.left,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
            rebuildName(
                builder,
                nodes,
                binary.right,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
        ),
        .mul => |binary| builder.mul(
            rebuildName(
                builder,
                nodes,
                binary.left,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
            rebuildName(
                builder,
                nodes,
                binary.right,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
        ),
        .mul_nary => |operands| blk: {
            var rebuilt: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                rebuilt[operand_index] = rebuildName(
                    builder,
                    nodes,
                    child,
                    cache,
                    name,
                    replacement,
                    replacement_cache,
                );
            }
            break :blk builder.mulNary(rebuilt[0..operands.len]);
        },
        .div => |binary| builder.div(
            rebuildName(
                builder,
                nodes,
                binary.left,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
            rebuildName(
                builder,
                nodes,
                binary.right,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
        ),
        .pow => |power| builder.power(
            rebuildName(
                builder,
                nodes,
                power.base,
                cache,
                name,
                replacement,
                replacement_cache,
            ),
            power.exponent,
        ),
        .negate => |child| builder.negate(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .sin => |child| builder.sine(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .cos => |child| builder.cosine(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .tan => |child| builder.tangent(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .atan => |child| builder.arctangent(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .abs => |child| builder.absolute(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .exp => |child| builder.exponential(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
        .ln => |child| builder.logarithm(rebuildName(
            builder,
            nodes,
            child,
            cache,
            name,
            replacement,
            replacement_cache,
        )),
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
        return cloneExpression(builder, replacement);
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
            cloneExpression(builder, parser.parse(replacement))
        else
            unsupportedReplacement(Replacement),
        else => unsupportedReplacement(Replacement),
    };
}

fn cloneExpression(builder: *build.Builder, comptime expression: ast.Expr) ast.NodeId {
    var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
    return cloneNode(builder, expression.nodes, expression.root, &cache);
}

fn cloneNode(
    builder: *build.Builder,
    comptime nodes: []const ast.Node,
    id: ast.NodeId,
    cache: []ast.NodeId,
) ast.NodeId {
    const index: usize = @intCast(id);
    if (cache[index] != ast.invalid_node) return cache[index];

    const result = switch (nodes[index]) {
        .integer => |value| builder.integer(value),
        .rational => |value| builder.rational(value),
        .float => |value| builder.float(value),
        .symbol => |name| builder.symbol(name),
        .add => |binary| builder.add(
            cloneNode(builder, nodes, binary.left, cache),
            cloneNode(builder, nodes, binary.right, cache),
        ),
        .add_nary => |operands| blk: {
            var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                cloned[operand_index] = cloneNode(builder, nodes, child, cache);
            }
            break :blk builder.addNary(cloned[0..operands.len]);
        },
        .sub => |binary| builder.sub(
            cloneNode(builder, nodes, binary.left, cache),
            cloneNode(builder, nodes, binary.right, cache),
        ),
        .mul => |binary| builder.mul(
            cloneNode(builder, nodes, binary.left, cache),
            cloneNode(builder, nodes, binary.right, cache),
        ),
        .mul_nary => |operands| blk: {
            var cloned: [ast.construction_node_limit]ast.NodeId = undefined;
            for (operands, 0..) |child, operand_index| {
                cloned[operand_index] = cloneNode(builder, nodes, child, cache);
            }
            break :blk builder.mulNary(cloned[0..operands.len]);
        },
        .div => |binary| builder.div(
            cloneNode(builder, nodes, binary.left, cache),
            cloneNode(builder, nodes, binary.right, cache),
        ),
        .pow => |power| builder.power(
            cloneNode(builder, nodes, power.base, cache),
            power.exponent,
        ),
        .negate => |child| builder.negate(cloneNode(builder, nodes, child, cache)),
        .sin => |child| builder.sine(cloneNode(builder, nodes, child, cache)),
        .cos => |child| builder.cosine(cloneNode(builder, nodes, child, cache)),
        .tan => |child| builder.tangent(cloneNode(builder, nodes, child, cache)),
        .atan => |child| builder.arctangent(cloneNode(builder, nodes, child, cache)),
        .abs => |child| builder.absolute(cloneNode(builder, nodes, child, cache)),
        .exp => |child| builder.exponential(cloneNode(builder, nodes, child, cache)),
        .ln => |child| builder.logarithm(cloneNode(builder, nodes, child, cache)),
    };
    cache[index] = result;
    return result;
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
