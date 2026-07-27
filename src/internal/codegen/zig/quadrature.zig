const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodes = support.emitNodes;
const floatSource = support.floatSource;
const prelude = support.prelude;
const validateOptions = support.validateOptions;

pub fn emitFixedQuadrature(
    comptime rule: anytype,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const selected = @TypeOf(rule).selected_table;
    var source: []const u8 = prelude();
    source = append(source, std.fmt.comptimePrint(
        \\
        \\pub fn {s}(inputs: anytype, output: *f64) void {{
        \\    const from = bombelliNumber(inputs.from);
        \\    const to = bombelliNumber(inputs.to);
        \\    const midpoint = (from + to) * 0.5;
        \\    const half_width = (to - from) * 0.5;
        \\    var weighted_sum: f64 = 0.0;
        \\
    , .{name}));
    inline for (selected.nodes, selected.weights, 0..) |node, weight, index| {
        const point_name = std.fmt.comptimePrint("point_{d}", .{index});
        source = append(source, std.fmt.comptimePrint(
            "    const {s}: f64 = midpoint + half_width * {s};\n",
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
    return append(source,
        \\    output.* = half_width * weighted_sum;
        \\}
        \\
    );
}
