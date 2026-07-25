const std = @import("std");
const ast = @import("ast.zig");

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

    pub fn float(self: *Builder, value: f64) ast.NodeId {
        return self.intern(.{ .float = value });
    }

    pub fn symbol(self: *Builder, name: []const u8) ast.NodeId {
        return self.intern(.{ .symbol = name });
    }

    pub fn add(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .add = .{ .left = left, .right = right } });
    }

    pub fn sub(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .sub = .{ .left = left, .right = right } });
    }

    pub fn mul(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .mul = .{ .left = left, .right = right } });
    }

    pub fn div(self: *Builder, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
        return self.intern(.{ .div = .{ .left = left, .right = right } });
    }

    pub fn power(self: *Builder, base: ast.NodeId, exponent: u32) ast.NodeId {
        return self.intern(.{ .pow = .{ .base = base, .exponent = exponent } });
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
        var reachable = [_]bool{false} ** ast.construction_node_limit;
        markReachable(self, root, &reachable);

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
        return .{
            .nodes = &exact_nodes,
            .root = remap[@intCast(root)],
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
        for (roots) |root| markReachable(self, root, &reachable);

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

fn markReachable(
    builder: *const Builder,
    id: ast.NodeId,
    reachable: *[ast.construction_node_limit]bool,
) void {
    const index: usize = @intCast(id);
    if (reachable[index]) return;
    reachable[index] = true;

    switch (builder.node(id)) {
        .integer, .float, .symbol => {},
        .add, .sub, .mul, .div => |binary| {
            markReachable(builder, binary.left, reachable);
            markReachable(builder, binary.right, reachable);
        },
        .pow => |power| markReachable(builder, power.base, reachable),
        .negate, .sin, .cos, .exp, .ln => |child| {
            markReachable(builder, child, reachable);
        },
    }
}

fn remapNode(
    node_value: ast.Node,
    remap: *const [ast.construction_node_limit]ast.NodeId,
) ast.Node {
    return switch (node_value) {
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .symbol => |name| .{ .symbol = name },
        .add => |binary| .{ .add = remapBinary(binary, remap) },
        .sub => |binary| .{ .sub = remapBinary(binary, remap) },
        .mul => |binary| .{ .mul = remapBinary(binary, remap) },
        .div => |binary| .{ .div = remapBinary(binary, remap) },
        .pow => |power| .{ .pow = .{
            .base = remap[@intCast(power.base)],
            .exponent = power.exponent,
        } },
        .negate => |child| .{ .negate = remap[@intCast(child)] },
        .sin => |child| .{ .sin = remap[@intCast(child)] },
        .cos => |child| .{ .cos = remap[@intCast(child)] },
        .exp => |child| .{ .exp = remap[@intCast(child)] },
        .ln => |child| .{ .ln = remap[@intCast(child)] },
    };
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
        .float => |value| mix(hash, @as(u64, @bitCast(value))),
        .symbol => |name| blk: {
            for (name) |byte| hash = mix(hash, byte);
            break :blk hash;
        },
        .add => |binary| hashBinary(hash, binary),
        .sub => |binary| hashBinary(hash, binary),
        .mul => |binary| hashBinary(hash, binary),
        .div => |binary| hashBinary(hash, binary),
        .pow => |power| mix(mix(hash, power.base), power.exponent),
        .negate => |child| mix(hash, child),
        .sin => |child| mix(hash, child),
        .cos => |child| mix(hash, child),
        .exp => |child| mix(hash, child),
        .ln => |child| mix(hash, child),
    };
}

fn hashBinary(hash: u64, binary: ast.Binary) u64 {
    return mix(mix(hash, binary.left), binary.right);
}

fn mix(hash: u64, value: anytype) u64 {
    return (hash ^ @as(u64, @intCast(value))) *% 0x100000001b3;
}
