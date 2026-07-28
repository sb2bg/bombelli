const std = @import("std");
const ast = @import("../../../expression.zig");
const scalar_options = @import("../scalar.zig");

pub const Scalar = scalar_options.Scalar;
pub const scalarOption = scalar_options.scalarOption;

pub const Binding = struct {
    symbol: []const u8,
    source: []const u8,
};

/// The C templates are written against placeholders rather than a fixed
/// scalar type, so a template stays readable C instead of a format string
/// fighting with C's braces. `@scalar@` is the emitted arithmetic type,
/// `@suffix@` is the shared libm and float-literal suffix, and `@helper@`
/// keeps one scalar type's prelude helpers distinct from another's.
pub fn instantiate(
    comptime source: []const u8,
    comptime scalar: Scalar,
) []const u8 {
    return fill(source, .{
        .{ "@scalar@", typeName(scalar) },
        .{ "@suffix@", suffix(scalar) },
        .{ "@helper@", helperSuffix(scalar) },
    });
}

pub fn typeName(comptime scalar: Scalar) []const u8 {
    return switch (scalar) {
        .f64 => "double",
        .f32 => "float",
    };
}

fn suffix(comptime scalar: Scalar) []const u8 {
    return switch (scalar) {
        .f64 => "",
        .f32 => "f",
    };
}

fn helperSuffix(comptime scalar: Scalar) []const u8 {
    return switch (scalar) {
        .f64 => "f64",
        .f32 => "f32",
    };
}

/// Fills a template's `@placeholder@` slots from a tuple of pairs.
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

pub fn append(comptime left: []const u8, comptime right: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ left, right });
}

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
            "{s}const @scalar@ {s}{d} = {s};\n",
            .{ indent, prefix, index, nodeSource(node, prefix, bindings) },
        ));
    }
    return source;
}

fn nodeSource(
    comptime node: ast.Node,
    comptime prefix: []const u8,
    comptime bindings: []const Binding,
) []const u8 {
    return switch (node) {
        .integer => |value| signedIntegerSource(value),
        .rational => |value| std.fmt.comptimePrint(
            "({s} / {s})",
            .{
                signedIntegerSource(value.numerator),
                unsignedIntegerSource(value.denominator),
            },
        ),
        .float => |value| floatSource(value),
        .constant => |value| floatSource(value.value()),
        .symbol => |name| symbolSource(name, bindings),
        .add => |binary| binarySource(binary, prefix, "+"),
        .sub => |binary| binarySource(binary, prefix, "-"),
        .mul => |binary| binarySource(binary, prefix, "*"),
        .div => |binary| binarySource(binary, prefix, "/"),
        .add_nary => |operands| narySource(operands, prefix, "+", "0"),
        .mul_nary => |operands| narySource(operands, prefix, "*", "1"),
        .pow => |power| std.fmt.comptimePrint(
            "bombelli_rational_power_@helper@({s}{d}, {s}, {s})",
            .{
                prefix,
                power.base,
                signedLongLong(power.exponent.numerator),
                unsignedLongLong(power.exponent.denominator),
            },
        ),
        .negate => |child| std.fmt.comptimePrint("-{s}{d}", .{ prefix, child }),
        .sin => |child| unarySource(prefix, child, "sin@suffix@"),
        .cos => |child| unarySource(prefix, child, "cos@suffix@"),
        .tan => |child| unarySource(prefix, child, "tan@suffix@"),
        .asin => |child| unarySource(prefix, child, "asin@suffix@"),
        .acos => |child| unarySource(prefix, child, "acos@suffix@"),
        .atan => |child| unarySource(prefix, child, "atan@suffix@"),
        .sinh => |child| unarySource(prefix, child, "sinh@suffix@"),
        .cosh => |child| unarySource(prefix, child, "cosh@suffix@"),
        .tanh => |child| unarySource(prefix, child, "tanh@suffix@"),
        .abs => |child| unarySource(prefix, child, "fabs@suffix@"),
        .exp => |child| unarySource(prefix, child, "exp@suffix@"),
        .ln => |child| unarySource(prefix, child, "log@suffix@"),
        .log2 => |child| unarySource(prefix, child, "log2@suffix@"),
        .log10 => |child| unarySource(prefix, child, "log10@suffix@"),
        .atan2 => |binary| binaryFunctionSource(
            binary,
            prefix,
            "atan2@suffix@",
        ),
        .hypot => |binary| binaryFunctionSource(
            binary,
            prefix,
            "hypot@suffix@",
        ),
    };
}

fn symbolSource(
    comptime name: []const u8,
    comptime bindings: []const Binding,
) []const u8 {
    inline for (bindings) |binding| {
        if (std.mem.eql(u8, name, binding.symbol)) return binding.source;
    }
    return std.fmt.comptimePrint("inputs->{s}", .{name});
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

fn binaryFunctionSource(
    comptime binary: ast.Binary,
    comptime prefix: []const u8,
    comptime function: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s}{d}, {s}{d})",
        .{
            function,
            prefix,
            binary.left,
            prefix,
            binary.right,
        },
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
    comptime child: ast.NodeId,
    comptime function: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{s}({s}{d})",
        .{ function, prefix, child },
    );
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
    const shortest = if (scientific.len < typed_decimal.len)
        scientific
    else
        typed_decimal;
    return append(shortest, "@suffix@");
}

/// Preserves the exact source integer and makes the conversion to the emitted
/// scalar explicit instead of pre-rounding it while generating source.
fn signedIntegerSource(comptime value: i64) []const u8 {
    return std.fmt.comptimePrint(
        "(@scalar@)({s})",
        .{signedLongLong(value)},
    );
}

fn unsignedIntegerSource(comptime value: u64) []const u8 {
    return std.fmt.comptimePrint(
        "(@scalar@)({s})",
        .{unsignedLongLong(value)},
    );
}

fn signedLongLong(comptime value: i64) []const u8 {
    // C has no negative integer literals: `-9223372036854775808LL` is a
    // negated positive literal that does not fit in `long long`.
    if (value == std.math.minInt(i64)) {
        return "-9223372036854775807LL - 1LL";
    }
    return std.fmt.comptimePrint("{d}LL", .{value});
}

fn unsignedLongLong(comptime value: u64) []const u8 {
    return std.fmt.comptimePrint("{d}ULL", .{value});
}

/// Returns every symbol the DAG reads that is not already bound to storage,
/// in alphabetical order so that the emitted input struct does not silently
/// reorder itself when an unrelated part of the expression changes.
pub fn freeSymbols(
    comptime nodes: []const ast.Node,
    comptime bound: []const []const u8,
) []const []const u8 {
    return freeSymbolsOfAll(&.{nodes}, bound);
}

/// The same, over several DAGs that share one input struct.
pub fn freeSymbolsOfAll(
    comptime node_lists: []const []const ast.Node,
    comptime bound: []const []const u8,
) []const []const u8 {
    comptime {
        var symbols: []const []const u8 = &.{};
        for (node_lists) |nodes| {
            for (nodes) |node| {
                const name = switch (node) {
                    .symbol => |symbol| symbol,
                    else => continue,
                };
                if (contains(bound, name) or contains(symbols, name)) continue;

                var position = symbols.len;
                while (position > 0 and
                    std.mem.order(u8, name, symbols[position - 1]) == .lt)
                {
                    position -= 1;
                }
                symbols = symbols[0..position] ++
                    &[_][]const u8{name} ++
                    symbols[position..];
            }
        }
        return symbols;
    }
}

/// Binds each solved unknown to its slot in the iterate vector.
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

fn contains(
    comptime names: []const []const u8,
    comptime name: []const u8,
) bool {
    inline for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Emits the input struct definition for a callable that reads `symbols`.
pub fn inputsStruct(
    comptime name: []const u8,
    comptime symbols: []const []const u8,
) []const u8 {
    var source: []const u8 = std.fmt.comptimePrint(
        "typedef struct {s}_inputs {{\n",
        .{name},
    );
    if (symbols.len == 0) {
        // C forbids an empty struct, and this callable reads nothing.
        source = append(
            source,
            "    char bombelli_unused;\n",
        );
    }
    inline for (symbols) |symbol| {
        validateIdentifier(symbol, "input name");
        source = append(source, std.fmt.comptimePrint(
            "    @scalar@ {s};\n",
            .{symbol},
        ));
    }
    return append(source, std.fmt.comptimePrint(
        "}} {s}_inputs;\n",
        .{name},
    ));
}

/// Silences the unused parameter where a callable reads no inputs at all.
pub fn unusedInputs(comptime symbols: []const []const u8) []const u8 {
    return if (symbols.len == 0) "    (void)inputs;\n" else "";
}

/// Validates the C-specific options and returns the emitted function name.
/// The target and mode are already validated by the emission dispatcher.
pub fn validateOptions(comptime options: anytype) []const u8 {
    const name = if (@hasField(@TypeOf(options), "name"))
        @as([]const u8, options.name)
    else
        "bombelli_generated";
    validateIdentifier(name, "function name");
    return name;
}

pub fn validateIdentifier(
    comptime name: []const u8,
    comptime role: []const u8,
) void {
    if (name.len == 0 or !identifierStart(name[0])) {
        @compileError(
            "Bombelli emitted C " ++ role ++ " must be an identifier",
        );
    }
    for (name[1..]) |character| {
        if (!identifierStart(character) and
            !(character >= '0' and character <= '9'))
        {
            @compileError(
                "Bombelli emitted C " ++ role ++ " must be an identifier",
            );
        }
    }
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) {
            @compileError(
                "Bombelli emitted C " ++ role ++ " must not be a C keyword",
            );
        }
    }
}

fn identifierStart(comptime character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= 'A' and character <= 'Z') or
        character == '_';
}

const keywords = [_][]const u8{
    "auto",       "break",     "case",           "char",
    "const",      "continue",  "default",        "do",
    "double",     "else",      "enum",           "extern",
    "float",      "for",       "goto",           "if",
    "inline",     "int",       "long",           "register",
    "restrict",   "return",    "short",          "signed",
    "sizeof",     "static",    "struct",         "switch",
    "typedef",    "union",     "unsigned",       "void",
    "volatile",   "while",     "_Alignas",       "_Alignof",
    "_Atomic",    "_Bool",     "_Complex",       "_Generic",
    "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local",
};

/// The shared arithmetic helpers, guarded so that several emitted units can be
/// included into one translation unit.
pub fn prelude() []const u8 {
    return
    \\/* Generated by Bombelli. This is a standalone C99 translation unit: it
    \\   depends only on the C standard library, and it holds no symbolic
    \\   machinery and no dynamic memory. */
    \\#include <math.h>
    \\
    \\#ifndef BOMBELLI_PRELUDE_@helper@
    \\#define BOMBELLI_PRELUDE_@helper@
    \\
    \\static inline @scalar@ bombelli_integer_power_@helper@(
    \\    @scalar@ base,
    \\    unsigned long long exponent
    \\) {
    \\    if (exponent == 0ULL) return 1;
    \\    if (exponent == 1ULL) return base;
    \\    const @scalar@ half = bombelli_integer_power_@helper@(base, exponent / 2ULL);
    \\    const @scalar@ square = half * half;
    \\    return (exponent % 2ULL == 0ULL) ? square : square * base;
    \\}
    \\
    \\static inline @scalar@ bombelli_rational_power_@helper@(
    \\    @scalar@ base,
    \\    long long numerator,
    \\    unsigned long long denominator
    \\) {
    \\    if (numerator == 0LL) return 1;
    \\    if (denominator == 1ULL) {
    \\        const unsigned long long magnitude = (numerator < 0LL)
    \\            ? (unsigned long long)(-(numerator + 1LL)) + 1ULL
    \\            : (unsigned long long)numerator;
    \\        const @scalar@ powered = bombelli_integer_power_@helper@(base, magnitude);
    \\        return (numerator < 0LL) ? 1 / powered : powered;
    \\    }
    \\    const @scalar@ magnitude = pow@suffix@(
    \\        fabs@suffix@(base),
    \\        (@scalar@)numerator / (@scalar@)denominator
    \\    );
    \\    if (base >= 0) return magnitude;
    \\    if (denominator % 2ULL == 0ULL) return (@scalar@)NAN;
    \\    return (numerator % 2LL == 0LL) ? magnitude : -magnitude;
    \\}
    \\
    \\#endif /* BOMBELLI_PRELUDE_@helper@ */
    \\
    ;
}
