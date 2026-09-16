const std = @import("std");
const ast = @import("../../expression.zig");
const exact = @import("exact.zig");
const graph = @import("graph.zig");

pub const Builder = BuilderWithCapacity(ast.construction_node_limit);

/// Bounded construction storage; persisted graphs are compacted independently.
pub fn BuilderWithCapacity(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 0x7fff_ffff)
        @compileError("Bombelli builder capacity is outside the supported range");
    const hash_table_size = std.math.ceilPowerOfTwo(usize, capacity * 2) catch
        @compileError("Bombelli builder hash capacity overflow");
    const hash_mask = hash_table_size - 1;
    return struct {
        const Self = @This();
        nodes: [capacity]ast.Node = undefined,
        len: usize = 0,
        hash_table: [hash_table_size]ast.NodeId =
            [_]ast.NodeId{ast.invalid_node} ** hash_table_size,

        pub fn node(self: *const Self, id: ast.NodeId) ast.Node {
            return self.nodes[@intCast(id)];
        }

        pub fn integer(self: *Self, value: i64) ast.NodeId {
            return self.intern(.{ .integer = value });
        }

        pub fn rational(self: *Self, value: exact.Rational) ast.NodeId {
            if (value.denominator == 1) return self.integer(value.numerator);
            return self.intern(.{ .rational = value });
        }

        pub fn float(self: *Self, value: f64) ast.NodeId {
            return self.intern(.{ .float = value });
        }

        pub fn constant(self: *Self, value: ast.Constant) ast.NodeId {
            return self.intern(.{ .constant = value });
        }

        pub fn symbol(self: *Self, name: []const u8) ast.NodeId {
            return self.intern(.{ .symbol = name });
        }

        pub fn cloneExpression(
            self: *Self,
            comptime expression: ast.Expr,
        ) ast.NodeId {
            var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
            return self.cloneNode(expression.nodes, expression.root, &cache);
        }

        pub fn cloneNode(
            self: *Self,
            comptime nodes: []const ast.Node,
            id: ast.NodeId,
            cache: []ast.NodeId,
        ) ast.NodeId {
            const index: usize = @intCast(id);
            if (cache[index] != ast.invalid_node) return cache[index];

            const result = switch (nodes[index]) {
                .integer => |value| self.integer(value),
                .rational => |value| self.rational(value),
                .float => |value| self.float(value),
                .constant => |value| self.constant(value),
                .symbol => |name| self.symbol(name),
                .add_nary => |operands| blk: {
                    var cloned: [operands.len]ast.NodeId = undefined;
                    for (operands, 0..) |child, operand_index| {
                        cloned[operand_index] = self.cloneNode(nodes, child, cache);
                    }
                    break :blk self.addNary(cloned[0..operands.len]);
                },
                .sub => |binary| self.sub(
                    self.cloneNode(nodes, binary.left, cache),
                    self.cloneNode(nodes, binary.right, cache),
                ),
                .mul_nary => |operands| blk: {
                    var cloned: [operands.len]ast.NodeId = undefined;
                    for (operands, 0..) |child, operand_index| {
                        cloned[operand_index] = self.cloneNode(nodes, child, cache);
                    }
                    break :blk self.mulNary(cloned[0..operands.len]);
                },
                .div => |binary| self.div(
                    self.cloneNode(nodes, binary.left, cache),
                    self.cloneNode(nodes, binary.right, cache),
                ),
                .pow => |power_value| self.power(
                    self.cloneNode(nodes, power_value.base, cache),
                    power_value.exponent,
                ),
                .unary => |unary_value| self.unary(
                    unary_value.op,
                    self.cloneNode(nodes, unary_value.child, cache),
                ),
                .atan2 => |binary| self.arctangent2(
                    self.cloneNode(nodes, binary.left, cache),
                    self.cloneNode(nodes, binary.right, cache),
                ),
                .hypot => |binary| self.hypotenuse(
                    self.cloneNode(nodes, binary.left, cache),
                    self.cloneNode(nodes, binary.right, cache),
                ),
            };
            cache[index] = result;
            return result;
        }

        pub fn add(self: *Self, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
            return self.addNary(&.{ left, right });
        }

        pub fn addNary(self: *Self, operands: []const ast.NodeId) ast.NodeId {
            if (operands.len < 2) @compileError("Bombelli n-ary addition requires at least two operands");
            if (operands.len > capacity) {
                @compileError("Bombelli n-ary addition exceeds construction workspace");
            }
            var storage: [operands.len]ast.NodeId = undefined;
            @memcpy(storage[0..operands.len], operands);
            const exact_operands = storage[0..operands.len].*;
            return self.intern(.{ .add_nary = &exact_operands });
        }

        pub fn sub(self: *Self, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
            return self.intern(.{ .sub = .{ .left = left, .right = right } });
        }

        pub fn mul(self: *Self, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
            return self.mulNary(&.{ left, right });
        }

        pub fn mulNary(self: *Self, operands: []const ast.NodeId) ast.NodeId {
            if (operands.len < 2) @compileError("Bombelli n-ary multiplication requires at least two operands");
            if (operands.len > capacity) {
                @compileError("Bombelli n-ary multiplication exceeds construction workspace");
            }
            var storage: [operands.len]ast.NodeId = undefined;
            @memcpy(storage[0..operands.len], operands);
            const exact_operands = storage[0..operands.len].*;
            return self.intern(.{ .mul_nary = &exact_operands });
        }

        pub fn div(self: *Self, left: ast.NodeId, right: ast.NodeId) ast.NodeId {
            return self.intern(.{ .div = .{ .left = left, .right = right } });
        }

        pub fn power(self: *Self, base: ast.NodeId, exponent: anytype) ast.NodeId {
            const canonical = canonicalExponent(exponent);
            return self.intern(.{ .pow = .{ .base = base, .exponent = canonical } });
        }

        pub fn unary(self: *Self, op: ast.UnaryOp, child: ast.NodeId) ast.NodeId {
            return self.intern(.{ .unary = .{ .op = op, .child = child } });
        }

        pub fn negate(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.negate, child);
        }

        pub fn sine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.sin, child);
        }

        pub fn cosine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.cos, child);
        }

        pub fn tangent(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.tan, child);
        }

        pub fn arcsine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.asin, child);
        }

        pub fn arccosine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.acos, child);
        }

        pub fn arctangent(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.atan, child);
        }

        pub fn hyperbolicSine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.sinh, child);
        }

        pub fn hyperbolicCosine(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.cosh, child);
        }

        pub fn hyperbolicTangent(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.tanh, child);
        }

        pub fn absolute(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.abs, child);
        }

        pub fn exponential(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.exp, child);
        }

        pub fn logarithm(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.ln, child);
        }

        pub fn logarithm2(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.log2, child);
        }

        pub fn logarithm10(self: *Self, child: ast.NodeId) ast.NodeId {
            return self.unary(.log10, child);
        }

        pub fn arctangent2(
            self: *Self,
            y: ast.NodeId,
            x: ast.NodeId,
        ) ast.NodeId {
            return self.intern(.{ .atan2 = .{ .left = y, .right = x } });
        }

        pub fn hypotenuse(
            self: *Self,
            x: ast.NodeId,
            y: ast.NodeId,
        ) ast.NodeId {
            return self.intern(.{ .hypot = .{ .left = x, .right = y } });
        }

        pub fn intern(self: *Self, new_node: ast.Node) ast.NodeId {
            // Child nodes are interned before their parents, and structural identity
            // is defined entirely by the tag, payload, and canonical child ids. Thus
            // every finished expression is a topologically ordered DAG containing
            // exactly one reachable instance of each structural node.
            var slot: usize = @intCast(hashNode(new_node) & hash_mask);
            for (0..hash_table_size) |_| {
                const existing_id = self.hash_table[slot];
                if (existing_id == ast.invalid_node) {
                    if (self.len == capacity) {
                        @compileError(std.fmt.comptimePrint(
                            "Bombelli construction exceeds the temporary arena limit of {d} nodes",
                            .{capacity},
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
            comptime self: *Self,
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
            comptime self: *Self,
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
            comptime self: *Self,
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
            comptime self: *Self,
            comptime N: usize,
            roots: [N]ast.NodeId,
        ) FinishedRoots(N) {
            @setEvalBranchQuota(@import("limits.zig").eval_branch.transform);
            @import("validation.zig").references(self.nodes[0..self.len]);
            var reachable = [_]bool{false} ** self.len;
            for (roots) |root| {
                graph.markReachable(self.nodes[0..self.len], root, &reachable);
            }

            var remap = [_]ast.NodeId{ast.invalid_node} ** self.len;
            var compact: [self.len]ast.Node = undefined;
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
}

fn FinishedRoots(comptime N: usize) type {
    return struct {
        nodes: []const ast.Node,
        roots: [N]ast.NodeId,
    };
}

fn remapNode(
    node_value: ast.Node,
    remap: []const ast.NodeId,
) ast.Node {
    return switch (node_value) {
        .integer => |value| .{ .integer = value },
        .rational => |value| .{ .rational = value },
        .float => |value| .{ .float = value },
        .constant => |value| .{ .constant = value },
        .symbol => |name| .{ .symbol = name },
        .add_nary => |operands| .{ .add_nary = remapOperands(operands, remap) },
        .sub => |binary| .{ .sub = remapBinary(binary, remap) },
        .mul_nary => |operands| .{ .mul_nary = remapOperands(operands, remap) },
        .div => |binary| .{ .div = remapBinary(binary, remap) },
        .pow => |power| .{ .pow = .{
            .base = remap[@intCast(power.base)],
            .exponent = power.exponent,
        } },
        .unary => |unary_value| .{ .unary = .{
            .op = unary_value.op,
            .child = remap[@intCast(unary_value.child)],
        } },
        .atan2 => |binary| .{ .atan2 = remapBinary(binary, remap) },
        .hypot => |binary| .{ .hypot = remapBinary(binary, remap) },
    };
}

fn remapOperands(
    operands: []const ast.NodeId,
    remap: []const ast.NodeId,
) []const ast.NodeId {
    var remapped: [operands.len]ast.NodeId = undefined;
    for (operands, 0..) |child, index| {
        remapped[index] = remap[@intCast(child)];
    }
    const exact_operands = remapped[0..operands.len].*;
    return &exact_operands;
}

fn remapBinary(
    binary: ast.Binary,
    remap: []const ast.NodeId,
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
        .add_nary => |operands| hashOperands(hash, operands),
        .sub => |binary| hashBinary(hash, binary),
        .mul_nary => |operands| hashOperands(hash, operands),
        .div => |binary| hashBinary(hash, binary),
        .pow => |power| mix(
            mix(
                mix(hash, power.base),
                @as(u64, @bitCast(power.exponent.numerator)),
            ),
            power.exponent.denominator,
        ),
        .unary => |unary_value| mix(
            mix(hash, @intFromEnum(unary_value.op)),
            unary_value.child,
        ),
        .atan2 => |binary| hashBinary(hash, binary),
        .hypot => |binary| hashBinary(hash, binary),
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
