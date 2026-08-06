const std = @import("std");
const ast = @import("../../expression.zig");

pub const Binding = struct {
    symbol: []const u8,
    source: []const u8,
};

pub fn variableBindings(
    comptime unknowns: []const []const u8,
) [unknowns.len]Binding {
    var bindings: [unknowns.len]Binding = undefined;
    inline for (unknowns, 0..) |unknown, index| {
        bindings[index] = .{
            .symbol = unknown,
            .source = std.fmt.comptimePrint("values[{d}]", .{index}),
        };
    }
    return bindings;
}

pub fn append(comptime left: []const u8, comptime right: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ left, right });
}

pub fn fill(comptime template: []const u8, comptime pairs: anytype) []const u8 {
    var filled: []const u8 = template;
    inline for (pairs) |pair| {
        filled = replace(filled, pair[0], pair[1]);
    }
    return filled;
}

fn replace(
    comptime source: []const u8,
    comptime needle: []const u8,
    comptime replacement: []const u8,
) []const u8 {
    var rewritten: []const u8 = "";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, needle)) |found| {
        rewritten = rewritten ++ source[index..found] ++ replacement;
        index = found + needle.len;
    }
    return rewritten ++ source[index..];
}

pub fn binarySource(
    comptime binary: ast.Binary,
    comptime prefix: []const u8,
    comptime operator: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}{d} {s} {s}{d}",
        .{ prefix, binary.left, operator, prefix, binary.right },
    );
}

pub fn binaryFunctionSource(
    comptime binary: ast.Binary,
    comptime prefix: []const u8,
    comptime function: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s}{d}, {s}{d})",
        .{ function, prefix, binary.left, prefix, binary.right },
    );
}

pub fn narySource(
    comptime operands: []const ast.NodeId,
    comptime prefix: []const u8,
    comptime operator: []const u8,
    comptime identity: []const u8,
) []const u8 {
    if (operands.len == 0) return identity;
    var source: []const u8 = std.fmt.comptimePrint(
        "{s}{d}",
        .{ prefix, operands[0] },
    );
    inline for (operands[1..]) |operand| {
        source = append(source, std.fmt.comptimePrint(
            " {s} {s}{d}",
            .{ operator, prefix, operand },
        ));
    }
    return source;
}

pub fn unarySource(
    comptime prefix: []const u8,
    child: ast.NodeId,
    comptime function: []const u8,
) []const u8 {
    return std.fmt.comptimePrint("{s}({s}{d})", .{ function, prefix, child });
}

pub fn floatSource(comptime value: f64) []const u8 {
    if (!std.math.isFinite(value)) {
        @compileError("Bombelli cannot emit a non-finite constant");
    }
    const decimal = std.fmt.comptimePrint("{d}", .{value});
    const typed_decimal = if (std.mem.indexOfAny(u8, decimal, ".eE") == null)
        std.fmt.comptimePrint("{s}.0", .{decimal})
    else
        decimal;
    const scientific = std.fmt.comptimePrint("{e}", .{value});
    return if (scientific.len < typed_decimal.len) scientific else typed_decimal;
}

pub fn identifierStart(character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= 'A' and character <= 'Z') or
        character == '_';
}
