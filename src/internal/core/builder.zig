const std = @import("std");
const ast = @import("../../expression.zig");
const exact = @import("exact.zig");
const graph = @import("graph.zig");

const hash_table_size = ast.construction_node_limit * 2;
const hash_mask = hash_table_size - 1;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(hash_table_size));
}

pub const Builder = struct {
    nodes: [ast.construction_node_limit]ast.Node = undefined,
    len: usize = 0,
    hash_table: [hash_table_size]ast.NodeId =
        [_]ast.NodeId{ast.invalid_node} ** hash_table_size,

    pub fn node(self: *const Builder, id: ast.NodeId) ast.Node {
        return self.nodes[@intCast(id)];
    }

    pub fn integer(self: *Builder, value: i64) ast.NodeId {
        return self.intern(.{ .integer = value });
    }

    pub fn rational(self: *Builder, value: exact.Rational) ast.NodeId {
        if (value.denominator == 1) return self.integer(value.numerator);
        return self.intern(.{ .rational = value });
    }

    pub fn float(self: *Builder, value: f64) ast.NodeId {
        return self.intern(.{ .float = value });
    }

    pub fn constant(self: *Builder, value: ast.Constant) ast.NodeId {
        return self.intern(.{ .constant = value });
    }

    pub fn symbol(self: *Builder, name: []const u8) ast.NodeId {
        return self.intern(.{ .symbol = name });
    }

    pub fn add(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .add = .{ .left = left, .right = right } });
    }

    pub fn addNary(self: *Builder, operands: []const ast.NodeId) ast.NodeId {
        if (operands.len < 2) @compileError("Bombelli n-ary addition requires at least two operands");
        if (operands.len > ast.construction_node_limit) {
            @compileError("Bombelli n-ary addition exceeds construction workspace");
        }
        var storage: [ast.construction_node_limit]ast.NodeId = undefined;
        @memcpy(storage[0..operands.len], operands);
        const exact_operands = storage[0..operands.len].*;
        return self.intern(.{ .add_nary = &exact_operands });
    }

    pub fn sub(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .sub = .{ .left = left, .right = right } });
    }

    pub fn mul(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .mul = .{ .left = left, .right = right } });
    }

    pub fn mulNary(self: *Builder, operands: []const ast.NodeId) ast.NodeId {
        if (operands.len < 2) @compileError("Bombelli n-ary multiplication requires at least two operands");
        if (operands.len > ast.construction_node_limit) {
            @compileError("Bombelli n-ary multiplication exceeds construction workspace");
        }
        var storage: [ast.construction_node_limit]ast.NodeId = undefined;
        @memcpy(storage[0..operands.len], operands);
        const exact_operands = storage[0..operands.len].*;
        return self.intern(.{ .mul_nary = &exact_operands });
    }

    pub fn div(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .div = .{ .left = left, .right = right } });
    }

    pub fn power(self: *Builder, base: ast.NodeId, exponent: anytype) ast.NodeId {
        const canonical = canonicalExponent(exponent);
        return self.intern(.{ .pow = .{ .base = base, .exponent = canonical } });
    }

    pub fn negate(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .negate = child });
    }

    pub fn sine(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .sin = child });
    }

    pub fn cosine(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .cos = child });
    }

    pub fn tangent(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .tan = child });
    }

    pub fn arctangent(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .atan = child });
    }

    pub fn absolute(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .abs = child });
    }

    pub fn exponential(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .exp = child });
    }

    pub fn logarithm(self: *Builder, child: ast.NodeId) ast.NodeId {
        return self.intern(.{ .ln = child });
    }

    pub fn intern(self: *Builder, new_node: ast.Node) ast.NodeId {
        // Child nodes are interned before their parents, and structural identity
        // is defined entirely by the tag, payload, and canonical child ids. Thus
        // every finished expression is a topologically ordered DAG containing
        // exactly one reachable instance of each structural node.
        var slot: usize = @intCast(hashNode(new_node) & hash_mask);
        for (0..hash_table_size) |_| {
            const existing_id = self.hash_table[slot];
            if (existing_id == ast.invalid_node) {
                if (self.len == ast.construction_node_limit) {
                    @compileError(std.fmt.comptimePrint(
                        "Bombelli construction exceeds the temporary arena limit of {d} nodes",
                        .{ast.construction_node_limit},
                    ));
                }

                const id: ast.NodeId = @intCast(self.len);
                self.nodes[self.len] = new_node;
                self.len += 1;
                self.hash_table[slot] = id;
                return id;
            }

            if (ast.nodeEqual(self.node(existing_id), new_node)) return existing_id;
            slot = (slot + 1) & hash_mask;
        }

        @compileError("Bombelli node interning table is full");
    }

    pub fn finish(
        comptime self: *Builder,
        root: ast.NodeId,
        source: []const u8,
    ) ast.Expr {
        const finished = self.finishRoots(1, .{root});
        return .{
            .nodes = finished.nodes,
            .root = finished.roots[0],
            .source = source,
            .construction_peak_nodes = self.len,
        };
    }

    pub fn finishVector(
        comptime self: *Builder,
        comptime N: usize,
        roots: [N]ast.NodeId,
        sources: [N][]const u8,
    ) ast.ExprVector(N) {
        const finished = self.finishRoots(N, roots);
        return .{
            .nodes = finished.nodes,
            .roots = finished.roots,
            .sources = sources,
            .construction_peak_nodes = self.len,
        };
    }

    pub fn finishMatrix(
        comptime self: *Builder,
        comptime R: usize,
        comptime C: usize,
        roots: [R][C]ast.NodeId,
        sources: [R][C][]const u8,
    ) ast.ExprMatrix(R, C) {
        var flat_roots: [R * C]ast.NodeId = undefined;
        inline for (0..R) |row| {
            inline for (0..C) |column| {
                flat_roots[row * C + column] = roots[row][column];
            }
        }
        const finished = self.finishRoots(R * C, flat_roots);
        var compact_roots: [R][C]ast.NodeId = undefined;
        inline for (0..R) |row| {
            inline for (0..C) |column| {
                compact_roots[row][column] = finished.roots[row * C + column];
            }
        }
        return .{
            .nodes = finished.nodes,
            .roots = compact_roots,
            .sources = sources,
            .construction_peak_nodes = self.len,
        };
    }

    fn finishRoots(
        comptime self: *Builder,
        comptime N: usize,
        roots: [N]ast.NodeId,
    ) FinishedRoots(N) {
        var reachable = [_]bool{false} ** ast.construction_node_limit;
        for (roots) |root| {
            graph.markReachable(self.nodes[0..self.len], root, &reachable);
        }

        var remap = [_]ast.NodeId{ast.invalid_node} ** ast.construction_node_limit;
        var compact: [ast.construction_node_limit]ast.Node = undefined;
        var compact_len: usize = 0;

        for (self.nodes[0..self.len], 0..) |node_value, old_index| {
            if (!reachable[old_index]) continue;

            const new_id: ast.NodeId = @intCast(compact_len);
            remap[old_index] = new_id;
            compact[compact_len] = remapNode(node_value, &remap);
            compact_len += 1;
        }

        const exact_nodes = compact[0..compact_len].*;
        var compact_roots: [N]ast.NodeId = undefined;
        for (roots, 0..) |root, index| {
            compact_roots[index] = remap[@intCast(root)];
        }
        return .{ .nodes = &exact_nodes, .roots = compact_roots };
    }
};

fn FinishedRoots(comptime N: usize) type {
    return struct {
        nodes: []const ast.Node,
        roots: [N]ast.NodeId,
    };
}

fn remapNode(
    node_value: ast.Node,
    remap: *const [ast.construction_node_limit]ast.NodeId,
) ast.Node {
    return switch (node_value) {
        .integer => |value| .{ .integer = value },
        .rational => |value| .{ .rational = value },
        .float => |value| .{ .float = value },
        .constant => |value| .{ .constant = value },
        .symbol => |name| .{ .symbol = name },
        .add => |binary| .{ .add = remapBinary(binary, remap) },
        .add_nary => |operands| .{ .add_nary = remapOperands(operands, remap) },
        .sub => |binary| .{ .sub = remapBinary(binary, remap) },
        .mul => |binary| .{ .mul = remapBinary(binary, remap) },
        .mul_nary => |operands| .{ .mul_nary = remapOperands(operands, remap) },
        .div => |binary| .{ .div = remapBinary(binary, remap) },
        .pow => |power| .{ .pow = .{
            .base = remap[@intCast(power.base)],
            .exponent = power.exponent,
        } },
        .negate => |child| .{ .negate = remap[@intCast(child)] },
        .sin => |child| .{ .sin = remap[@intCast(child)] },
        .cos => |child| .{ .cos = remap[@intCast(child)] },
        .tan => |child| .{ .tan = remap[@intCast(child)] },
        .atan => |child| .{ .atan = remap[@intCast(child)] },
        .abs => |child| .{ .abs = remap[@intCast(child)] },
        .exp => |child| .{ .exp = remap[@intCast(child)] },
        .ln => |child| .{ .ln = remap[@intCast(child)] },
    };
}

fn remapOperands(
    operands: []const ast.NodeId,
    remap: *const [ast.construction_node_limit]ast.NodeId,
) []const ast.NodeId {
    var remapped: [ast.construction_node_limit]ast.NodeId = undefined;
    for (operands, 0..) |child, index| {
        remapped[index] = remap[@intCast(child)];
    }
    const exact_operands = remapped[0..operands.len].*;
    return &exact_operands;
}

fn remapBinary(
    binary: ast.Binary,
    remap: *const [ast.construction_node_limit]ast.NodeId,
) ast.Binary {
    return .{
        .left = remap[@intCast(binary.left)],
        .right = remap[@intCast(binary.right)],
    };
}

fn hashNode(node_value: ast.Node) u64 {
    var hash = mix(0xcbf29ce484222325, @intFromEnum(std.meta.activeTag(node_value)));
    return switch (node_value) {
        .integer => |value| mix(hash, @as(u64, @bitCast(value))),
        .rational => |value| mix(
            mix(hash, @as(u64, @bitCast(value.numerator))),
            value.denominator,
        ),
        .float => |value| mix(hash, @as(u64, @bitCast(value))),
        .constant => |value| mix(hash, @intFromEnum(value)),
        .symbol => |name| blk: {
            for (name) |byte| hash = mix(hash, byte);
            break :blk hash;
        },
        .add => |binary| hashBinary(hash, binary),
        .add_nary => |operands| hashOperands(hash, operands),
        .sub => |binary| hashBinary(hash, binary),
        .mul => |binary| hashBinary(hash, binary),
        .mul_nary => |operands| hashOperands(hash, operands),
        .div => |binary| hashBinary(hash, binary),
        .pow => |power| mix(
            mix(
                mix(hash, power.base),
                @as(u64, @bitCast(power.exponent.numerator)),
            ),
            power.exponent.denominator,
        ),
        .negate => |child| mix(hash, child),
        .sin => |child| mix(hash, child),
        .cos => |child| mix(hash, child),
        .tan => |child| mix(hash, child),
        .atan => |child| mix(hash, child),
        .abs => |child| mix(hash, child),
        .exp => |child| mix(hash, child),
        .ln => |child| mix(hash, child),
    };
}

fn canonicalExponent(exponent: anytype) exact.Rational {
    if (@TypeOf(exponent) == exact.Rational) return exponent;
    return switch (@typeInfo(@TypeOf(exponent))) {
        .comptime_int, .int => exact.Rational.fromInteger(@intCast(exponent)),
        else => @compileError("Bombelli power exponent must be an exact rational"),
    };
}

fn hashBinary(hash: u64, binary: ast.Binary) u64 {
    return mix(mix(hash, binary.left), binary.right);
}

fn hashOperands(initial_hash: u64, operands: []const ast.NodeId) u64 {
    var hash = mix(initial_hash, operands.len);
    for (operands) |child| hash = mix(hash, child);
    return hash;
}

fn mix(hash: u64, value: anytype) u64 {
    return (hash ^ @as(u64, @intCast(value))) *% 0x100000001b3;
}
