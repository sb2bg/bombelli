const std = @import("std");
const ast = @import("../../../expression.zig");
const options_validation = @import("../../core/options.zig");

pub const Binding = struct {
    symbol: []const u8,
    source: []const u8,
};

pub fn emitNodes(
    comptime nodes: []const ast.Node,
    comptime prefix: []const u8,
    comptime bindings: []const Binding,
) []const u8 {
    return emitNodesAtIndent(nodes, prefix, bindings, "    ");
}

pub fn emitNodesAtIndent(
    comptime nodes: []const ast.Node,
    comptime prefix: []const u8,
    comptime bindings: []const Binding,
    comptime indent: []const u8,
) []const u8 {
    var source: []const u8 = "";
    inline for (nodes, 0..) |node, index| {
        source = append(source, std.fmt.comptimePrint(
            "{s}const {s}{d}: f64 = {s};\n",
            .{ indent, prefix, index, nodeSource(node, prefix, bindings) },
        ));
    }
    return source;
}

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

fn nodeSource(
    comptime node: ast.Node,
    comptime prefix: []const u8,
    comptime bindings: []const Binding,
) []const u8 {
    return switch (node) {
        .integer => |value| signedIntegerFloatSource(value),
        .rational => |value| std.fmt.comptimePrint(
            "({s} / {s})",
            .{
                signedIntegerFloatSource(value.numerator),
                unsignedIntegerFloatSource(value.denominator),
            },
        ),
        .float => |value| floatSource(value),
        .constant => |value| constantSource(value),
        .symbol => |name| symbolSource(name, bindings),
        .add => |binary| binarySource(binary, prefix, "+"),
        .sub => |binary| binarySource(binary, prefix, "-"),
        .mul => |binary| binarySource(binary, prefix, "*"),
        .div => |binary| binarySource(binary, prefix, "/"),
        .add_nary => |operands| narySource(operands, prefix, "+", "0.0"),
        .mul_nary => |operands| narySource(operands, prefix, "*", "1.0"),
        .pow => |power| std.fmt.comptimePrint(
            "bombelliRationalPower({s}{d}, {d}, {d})",
            .{
                prefix,
                power.base,
                power.exponent.numerator,
                power.exponent.denominator,
            },
        ),
        .negate => |child| std.fmt.comptimePrint("-{s}{d}", .{ prefix, child }),
        .sin => |child| unarySource(prefix, child, "@sin"),
        .cos => |child| unarySource(prefix, child, "@cos"),
        .tan => |child| unarySource(prefix, child, "@tan"),
        .atan => |child| unarySource(prefix, child, "std.math.atan"),
        .abs => |child| unarySource(prefix, child, "@abs"),
        .exp => |child| unarySource(prefix, child, "@exp"),
        .ln => |child| unarySource(prefix, child, "@log"),
    };
}

fn constantSource(comptime value: ast.Constant) []const u8 {
    return switch (value) {
        .pi => "std.math.pi",
    };
}

fn symbolSource(
    comptime name: []const u8,
    comptime bindings: []const Binding,
) []const u8 {
    inline for (bindings) |binding| {
        if (std.mem.eql(u8, name, binding.symbol)) return binding.source;
    }
    return std.fmt.comptimePrint("bombelliNumber(inputs.{s})", .{name});
}

fn binarySource(
    comptime binary: ast.Binary,
    comptime prefix: []const u8,
    comptime operator: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}{d} {s} {s}{d}",
        .{ prefix, binary.left, operator, prefix, binary.right },
    );
}

fn narySource(
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

fn unarySource(
    comptime prefix: []const u8,
    child: ast.NodeId,
    comptime function: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s}{d})",
        .{ function, prefix, child },
    );
}

pub fn validateOptions(comptime options: anytype) []const u8 {
    const Options = @TypeOf(options);
    options_validation.requireTag(
        options,
        "target",
        "zig",
        "Bombelli source emission currently requires '.target = .zig'",
    );
    options_validation.requireTag(
        options,
        "mode",
        "out_of_place",
        "Bombelli source emission currently requires '.mode = .out_of_place'",
    );
    const name = if (@hasField(Options, "name"))
        @as([]const u8, options.name)
    else
        "bombelli_generated";
    validateIdentifier(name);
    return name;
}

fn validateIdentifier(comptime name: []const u8) void {
    if (name.len == 0 or !identifierStart(name[0])) {
        @compileError("Bombelli emitted Zig function name must be an identifier");
    }
    for (name[1..]) |character| {
        if (!identifierStart(character) and
            !(character >= '0' and character <= '9'))
        {
            @compileError("Bombelli emitted Zig function name must be an identifier");
        }
    }
    if (std.zig.Token.getKeyword(name) != null) {
        @compileError("Bombelli emitted Zig function name must not be a Zig keyword");
    }
}

fn identifierStart(character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= 'A' and character <= 'Z') or
        character == '_';
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
    return if (scientific.len < typed_decimal.len)
        scientific
    else
        typed_decimal;
}

fn signedIntegerFloatSource(comptime value: i64) []const u8 {
    // Preserve the exact source integer and make the evaluator's f64 lowering
    // explicit instead of pre-rounding it while generating source.
    return std.fmt.comptimePrint(
        "@as(f64, @floatFromInt(@as(i64, {d})))",
        .{value},
    );
}

fn unsignedIntegerFloatSource(comptime value: u64) []const u8 {
    return std.fmt.comptimePrint(
        "@as(f64, @floatFromInt(@as(u64, {d})))",
        .{value},
    );
}

pub fn append(comptime left: []const u8, comptime right: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ left, right });
}

pub fn prelude() []const u8 {
    return
    \\const std = @import("std");
    \\
    \\inline fn bombelliNumber(value: anytype) f64 {
    \\    return switch (@typeInfo(@TypeOf(value))) {
    \\        .int, .comptime_int => @floatFromInt(value),
    \\        .float, .comptime_float => @floatCast(value),
    \\        else => @compileError("Bombelli generated input must be numeric"),
    \\    };
    \\}
    \\
    \\inline fn bombelliIntegerPower(base: f64, comptime exponent: u64) f64 {
    \\    if (exponent == 0) return 1.0;
    \\    if (exponent == 1) return base;
    \\    const half = bombelliIntegerPower(base, exponent / 2);
    \\    const square = half * half;
    \\    return if (exponent % 2 == 0) square else square * base;
    \\}
    \\
    \\inline fn bombelliRationalPower(
    \\    base: f64,
    \\    comptime numerator: i64,
    \\    comptime denominator: u64,
    \\) f64 {
    \\    if (numerator == 0) return 1.0;
    \\    if (denominator == 1) {
    \\        const magnitude: u64 = @intCast(if (numerator < 0)
    \\            -@as(i128, numerator)
    \\        else
    \\            numerator);
    \\        const powered = bombelliIntegerPower(base, magnitude);
    \\        return if (numerator < 0) 1.0 / powered else powered;
    \\    }
    \\    const magnitude = std.math.pow(
    \\        f64,
    \\        @abs(base),
    \\        @as(f64, @floatFromInt(numerator)) /
    \\            @as(f64, @floatFromInt(denominator)),
    \\    );
    \\    if (base >= 0.0) return magnitude;
    \\    if (denominator % 2 == 0) return std.math.nan(f64);
    \\    return if (@mod(numerator, 2) == 0) magnitude else -magnitude;
    \\}
    \\
    ;
}

pub fn newtonPrelude() []const u8 {
    return
    \\
    \\fn bombelliInfinityNorm(comptime N: usize, values: [N]f64) f64 {
    \\    var norm: f64 = 0.0;
    \\    for (values) |value| norm = @max(norm, @abs(value));
    \\    return norm;
    \\}
    \\
    \\fn bombelliFiniteVector(comptime N: usize, values: [N]f64) bool {
    \\    for (values) |value| {
    \\        if (!std.math.isFinite(value)) return false;
    \\    }
    \\    return true;
    \\}
    \\
    \\fn bombelliFiniteMatrix(comptime N: usize, values: [N][N]f64) bool {
    \\    for (values) |row| {
    \\        if (!bombelliFiniteVector(N, row)) return false;
    \\    }
    \\    return true;
    \\}
    \\
    \\fn bombelliSolve(
    \\    comptime N: usize,
    \\    matrix_input: [N][N]f64,
    \\    rhs_input: [N]f64,
    \\    pivot_tolerance: f64,
    \\) ?[N]f64 {
    \\    var matrix: [N][N + 1]f64 = undefined;
    \\    var scale: f64 = 0.0;
    \\    for (0..N) |row| {
    \\        for (0..N) |column| {
    \\            matrix[row][column] = matrix_input[row][column];
    \\            scale = @max(scale, @abs(matrix[row][column]));
    \\        }
    \\        matrix[row][N] = rhs_input[row];
    \\    }
    \\    const threshold = pivot_tolerance * @max(1.0, scale);
    \\    for (0..N) |column| {
    \\        var pivot_row = column;
    \\        var pivot_magnitude = @abs(matrix[column][column]);
    \\        for (column + 1..N) |row| {
    \\            const magnitude = @abs(matrix[row][column]);
    \\            if (magnitude > pivot_magnitude) {
    \\                pivot_magnitude = magnitude;
    \\                pivot_row = row;
    \\            }
    \\        }
    \\        if (!std.math.isFinite(pivot_magnitude) or
    \\            pivot_magnitude <= threshold)
    \\        {
    \\            return null;
    \\        }
    \\        if (pivot_row != column) {
    \\            const temporary = matrix[column];
    \\            matrix[column] = matrix[pivot_row];
    \\            matrix[pivot_row] = temporary;
    \\        }
    \\        for (column + 1..N) |row| {
    \\            const factor = matrix[row][column] / matrix[column][column];
    \\            matrix[row][column] = 0.0;
    \\            for (column + 1..N + 1) |entry| {
    \\                matrix[row][entry] -= factor * matrix[column][entry];
    \\            }
    \\        }
    \\    }
    \\    var solution: [N]f64 = undefined;
    \\    var reverse = N;
    \\    while (reverse != 0) {
    \\        reverse -= 1;
    \\        var value = matrix[reverse][N];
    \\        for (reverse + 1..N) |column| {
    \\            value -= matrix[reverse][column] * solution[column];
    \\        }
    \\        solution[reverse] = value / matrix[reverse][reverse];
    \\    }
    \\    return solution;
    \\}
    \\
    ;
}
