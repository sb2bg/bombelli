const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodes = support.emitNodes;
const floatSource = support.floatSource;
const freeSymbols = support.freeSymbols;
const inputsStruct = support.inputsStruct;
const prelude = support.prelude;
const validateOptions = support.validateOptions;

pub fn emitFixedQuadrature(
    comptime rule: anytype,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const selected = @TypeOf(rule).selected_table;
    // `from` and `to` are already carried by the input struct, so an integrand
    // symbol of either name reads the bound rather than adding a field.
    const bounds = [_][]const u8{ "from", "to" };
    const symbols = bounds ++ freeSymbols(
        rule.integrand.nodes,
        &(bounds ++ [_][]const u8{rule.variable}),
    );

    var source: []const u8 = prelude();
    source = append(source, "\n");
    source = append(source, inputsStruct(name, symbols));
    source = append(source, std.fmt.comptimePrint(
        \\
        \\void {s}(const {s}_inputs *inputs, @scalar@ *output);
        \\
        \\void {s}(const {s}_inputs *inputs, @scalar@ *output) {{
        \\    const @scalar@ from = inputs->from;
        \\    const @scalar@ to = inputs->to;
        \\    const @scalar@ midpoint = (from + to) * 0.5@suffix@;
        \\    const @scalar@ half_width = (to - from) * 0.5@suffix@;
        \\    @scalar@ weighted_sum = 0;
        \\
    , .{ name, name, name, name }));
    inline for (selected.nodes, selected.weights, 0..) |node, weight, index| {
        const point_name = std.fmt.comptimePrint("point_{d}", .{index});
        source = append(source, std.fmt.comptimePrint(
            "    const @scalar@ {s} = midpoint + half_width * {s};\n",
            .{ point_name, floatSource(node) },
        ));
        const prefix = std.fmt.comptimePrint("q{d}_n", .{index});
        source = append(source, emitNodes(
            rule.integrand.nodes,
            prefix,
            &.{.{ .symbol = rule.variable, .source = point_name }},
        ));
        source = append(source, std.fmt.comptimePrint(
            "    weighted_sum += {s} * {s}{d};\n",
            .{ floatSource(weight), prefix, rule.integrand.root },
        ));
    }
    source = append(source,
        \\    *output = half_width * weighted_sum;
        \\}
        \\
    );
    return support.instantiate(source, support.scalarOption(options));
}
