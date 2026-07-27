const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodesAtIndent = support.emitNodesAtIndent;
const floatSource = support.floatSource;
const newtonPrelude = support.newtonPrelude;
const prelude = support.prelude;
const validateOptions = support.validateOptions;
const variableBindings = support.variableBindings;

pub fn emitNewton(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const Solver = @TypeOf(solver);
    const N = solver.unknowns.len;
    const max_iterations = Solver.maximum_iterations;
    const status_name = std.fmt.comptimePrint("{s}Status", .{name});
    const result_name = std.fmt.comptimePrint("{s}Result", .{name});
    const finish_name = std.fmt.comptimePrint("{s}Finish", .{name});
    const bindings = variableBindings(&solver.unknowns);

    var source: []const u8 = prelude();
    source = append(source, newtonPrelude());
    source = append(source, std.fmt.comptimePrint(
        \\
        \\pub const {s} = enum(u8) {{
        \\    converged,
        \\    singular_jacobian,
        \\    non_converged,
        \\    non_finite,
        \\}};
        \\
        \\pub const {s} = struct {{
        \\    values: [{d}]f64,
        \\    residual: [{d}]f64,
        \\    iterations: usize,
        \\    residual_norm: f64,
        \\    step_norm: f64,
        \\    status: {s},
        \\}};
        \\
        \\fn {s}(
        \\    values: [{d}]f64,
        \\    residual: [{d}]f64,
        \\    iterations: usize,
        \\    residual_norm: f64,
        \\    step_norm: f64,
        \\    status: {s},
        \\) {s} {{
        \\    return .{{
        \\        .values = values,
        \\        .residual = residual,
        \\        .iterations = iterations,
        \\        .residual_norm = residual_norm,
        \\        .step_norm = step_norm,
        \\        .status = status,
        \\    }};
        \\}}
        \\
        \\pub fn {s}(inputs: anytype, output: *{s}) void {{
        \\
    , .{
        status_name,
        result_name,
        N,
        N,
        status_name,
        finish_name,
        N,
        N,
        status_name,
        result_name,
        name,
        result_name,
    }));
    source = append(source, "    var values = [_]f64{\n");
    inline for (solver.unknowns) |unknown| {
        source = append(source, std.fmt.comptimePrint(
            "        bombelliNumber(inputs.initial.{s}),\n",
            .{unknown},
        ));
    }
    source = append(source, "    };\n    var residual: [");
    source = append(source, std.fmt.comptimePrint(
        "{d}]f64 = undefined;\n",
        .{N},
    ));
    source = append(source, emitNodesAtIndent(
        solver.residuals.nodes,
        "initial_n",
        &bindings,
        "    ",
    ));
    inline for (solver.residuals.roots, 0..) |root, index| {
        source = append(source, std.fmt.comptimePrint(
            "    residual[{d}] = initial_n{d};\n",
            .{ index, root },
        ));
    }
    source = append(source, std.fmt.comptimePrint(
        \\    var residual_norm = bombelliInfinityNorm({d}, residual);
        \\    if (!bombelliFiniteVector({d}, values) or
        \\        !bombelliFiniteVector({d}, residual) or
        \\        !std.math.isFinite(residual_norm))
        \\    {{
        \\        output.* = {s}(
        \\            values,
        \\            residual,
        \\            0,
        \\            residual_norm,
        \\            0.0,
        \\            .non_finite,
        \\        );
        \\        return;
        \\    }}
        \\    if (residual_norm <= {s}) {{
        \\        output.* = {s}(
        \\            values,
        \\            residual,
        \\            0,
        \\            residual_norm,
        \\            0.0,
        \\            .converged,
        \\        );
        \\        return;
        \\    }}
        \\    var step_norm: f64 = 0.0;
        \\    for (0..{d}) |iteration| {{
        \\        var jacobian: [{d}][{d}]f64 = undefined;
        \\
    , .{
        N,
        N,
        N,
        finish_name,
        floatSource(solver.tolerance),
        finish_name,
        max_iterations,
        N,
        N,
    }));
    source = append(source, emitNodesAtIndent(
        solver.jacobian_program.nodes,
        "jacobian_n",
        &bindings,
        "        ",
    ));
    inline for (solver.jacobian_program.roots, 0..) |row, row_index| {
        inline for (row, 0..) |root, column_index| {
            source = append(source, std.fmt.comptimePrint(
                "        jacobian[{d}][{d}] = jacobian_n{d};\n",
                .{ row_index, column_index, root },
            ));
        }
    }
    source = append(source, std.fmt.comptimePrint(
        \\        if (!bombelliFiniteMatrix({d}, jacobian)) {{
        \\            output.* = {s}(
        \\                values,
        \\                residual,
        \\                iteration,
        \\                residual_norm,
        \\                step_norm,
        \\                .non_finite,
        \\            );
        \\            return;
        \\        }}
        \\        var right_hand_side: [{d}]f64 = undefined;
        \\        for (residual, 0..) |entry, index| {{
        \\            right_hand_side[index] = -entry;
        \\        }}
        \\        const step = bombelliSolve(
        \\            {d},
        \\            jacobian,
        \\            right_hand_side,
        \\            {s},
        \\        ) orelse {{
        \\            output.* = {s}(
        \\                values,
        \\                residual,
        \\                iteration,
        \\                residual_norm,
        \\                step_norm,
        \\                .singular_jacobian,
        \\            );
        \\            return;
        \\        }};
        \\        step_norm = bombelliInfinityNorm({d}, step);
        \\        for (&values, step) |*value, increment| value.* += increment;
        \\
    , .{
        N,
        finish_name,
        N,
        N,
        floatSource(solver.pivot_tolerance),
        finish_name,
        N,
    }));
    source = append(source, emitNodesAtIndent(
        solver.residuals.nodes,
        "next_n",
        &bindings,
        "        ",
    ));
    inline for (solver.residuals.roots, 0..) |root, index| {
        source = append(source, std.fmt.comptimePrint(
            "        residual[{d}] = next_n{d};\n",
            .{ index, root },
        ));
    }
    return append(source, std.fmt.comptimePrint(
        \\        residual_norm = bombelliInfinityNorm({d}, residual);
        \\        if (!bombelliFiniteVector({d}, values) or
        \\            !bombelliFiniteVector({d}, residual) or
        \\            !std.math.isFinite(step_norm) or
        \\            !std.math.isFinite(residual_norm))
        \\        {{
        \\            output.* = {s}(
        \\                values,
        \\                residual,
        \\                iteration + 1,
        \\                residual_norm,
        \\                step_norm,
        \\                .non_finite,
        \\            );
        \\            return;
        \\        }}
        \\        if (residual_norm <= {s}) {{
        \\            output.* = {s}(
        \\                values,
        \\                residual,
        \\                iteration + 1,
        \\                residual_norm,
        \\                step_norm,
        \\                .converged,
        \\            );
        \\            return;
        \\        }}
        \\    }}
        \\    output.* = {s}(
        \\        values,
        \\        residual,
        \\        {d},
        \\        residual_norm,
        \\        step_norm,
        \\        .non_converged,
        \\    );
        \\}}
        \\
    , .{
        N,
        N,
        N,
        finish_name,
        floatSource(solver.tolerance),
        finish_name,
        finish_name,
        max_iterations,
    }));
}
