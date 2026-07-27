const std = @import("std");
const support = @import("support.zig");

const append = support.append;
const emitNodesAtIndent = support.emitNodesAtIndent;
const fill = support.fill;
const floatSource = support.floatSource;
const freeSymbolsOfAll = support.freeSymbolsOfAll;
const prelude = support.prelude;
const validateIdentifier = support.validateIdentifier;
const validateOptions = support.validateOptions;
const variableBindings = support.variableBindings;

pub fn emitNewton(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    const name = validateOptions(options);
    const Solver = @TypeOf(solver);
    const N = solver.unknowns.len;
    const bindings = variableBindings(&solver.unknowns);
    const parameters = freeSymbolsOfAll(
        &.{ solver.residuals.nodes, solver.jacobian_program.nodes },
        &solver.unknowns,
    );
    const slots = .{
        .{ "@name@", name },
        .{ "@n@", std.fmt.comptimePrint("{d}", .{N}) },
        .{ "@n1@", std.fmt.comptimePrint("{d}", .{N + 1}) },
        .{ "@iterations@", std.fmt.comptimePrint(
            "{d}",
            .{Solver.maximum_iterations},
        ) },
        .{ "@tolerance@", floatSource(solver.tolerance) },
        .{ "@pivot@", floatSource(solver.pivot_tolerance) },
    };

    var source: []const u8 = prelude();
    source = append(source, "#include <stddef.h>\n");
    source = append(source, inputsStruct(name, &solver.unknowns, parameters));
    source = append(source, fill(types, slots));
    source = append(source, fill(helpers, slots));
    source = append(source, fill(
        \\
        \\void @name@(const @name@_inputs *inputs, @name@_result *output);
        \\
        \\void @name@(const @name@_inputs *inputs, @name@_result *output) {
        \\    @scalar@ values[@n@];
        \\    @scalar@ residual[@n@];
        \\    @scalar@ residual_norm;
        \\    @scalar@ step_norm = 0;
        \\    size_t iteration;
        \\
    , slots));
    inline for (solver.unknowns, 0..) |unknown, index| {
        source = append(source, std.fmt.comptimePrint(
            "    values[{d}] = inputs->initial.{s};\n",
            .{ index, unknown },
        ));
    }
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
    source = append(source, fill(
        \\    residual_norm = @name@_infinity_norm(residual, @n@);
        \\    if (!@name@_finite_vector(values, @n@) ||
        \\        !@name@_finite_vector(residual, @n@) ||
        \\        !isfinite(residual_norm)) {
        \\        @name@_finish(
        \\            output, values, residual, 0, residual_norm, 0,
        \\            @name@_non_finite
        \\        );
        \\        return;
        \\    }
        \\    if (residual_norm <= @tolerance@) {
        \\        @name@_finish(
        \\            output, values, residual, 0, residual_norm, 0,
        \\            @name@_converged
        \\        );
        \\        return;
        \\    }
        \\    for (iteration = 0; iteration < @iterations@; ++iteration) {
        \\        @scalar@ jacobian[@n@][@n@];
        \\        @scalar@ right_hand_side[@n@];
        \\        @scalar@ step[@n@];
        \\        size_t index;
        \\
    , slots));
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
    source = append(source, fill(
        \\        if (!@name@_finite_matrix(jacobian)) {
        \\            @name@_finish(
        \\                output, values, residual, iteration, residual_norm,
        \\                step_norm, @name@_non_finite
        \\            );
        \\            return;
        \\        }
        \\        for (index = 0; index < @n@; ++index) {
        \\            right_hand_side[index] = -residual[index];
        \\        }
        \\        if (!@name@_solve(jacobian, right_hand_side, @pivot@, step)) {
        \\            @name@_finish(
        \\                output, values, residual, iteration, residual_norm,
        \\                step_norm, @name@_singular_jacobian
        \\            );
        \\            return;
        \\        }
        \\        step_norm = @name@_infinity_norm(step, @n@);
        \\        for (index = 0; index < @n@; ++index) {
        \\            values[index] += step[index];
        \\        }
        \\
    , slots));
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
    source = append(source, fill(
        \\        residual_norm = @name@_infinity_norm(residual, @n@);
        \\        if (!@name@_finite_vector(values, @n@) ||
        \\            !@name@_finite_vector(residual, @n@) ||
        \\            !isfinite(step_norm) ||
        \\            !isfinite(residual_norm)) {
        \\            @name@_finish(
        \\                output, values, residual, iteration + 1,
        \\                residual_norm, step_norm, @name@_non_finite
        \\            );
        \\            return;
        \\        }
        \\        if (residual_norm <= @tolerance@) {
        \\            @name@_finish(
        \\                output, values, residual, iteration + 1,
        \\                residual_norm, step_norm, @name@_converged
        \\            );
        \\            return;
        \\        }
        \\    }
        \\    @name@_finish(
        \\        output, values, residual, @iterations@, residual_norm,
        \\        step_norm, @name@_non_converged
        \\    );
        \\}
        \\
    , slots));
    return support.instantiate(source, support.scalarOption(options));
}

/// The initial iterate is nested so that a parameter and an unknown may share
/// a name, exactly as they may in the Zig target's `inputs.initial` struct.
fn inputsStruct(
    comptime name: []const u8,
    comptime unknowns: []const []const u8,
    comptime parameters: []const []const u8,
) []const u8 {
    var source: []const u8 = std.fmt.comptimePrint(
        "\ntypedef struct {s}_initial {{\n",
        .{name},
    );
    inline for (unknowns) |unknown| {
        validateIdentifier(unknown, "input name");
        source = append(source, std.fmt.comptimePrint(
            "    @scalar@ {s};\n",
            .{unknown},
        ));
    }
    source = append(source, std.fmt.comptimePrint(
        "}} {s}_initial;\n\ntypedef struct {s}_inputs {{\n    {s}_initial initial;\n",
        .{ name, name, name },
    ));
    inline for (parameters) |parameter| {
        validateIdentifier(parameter, "input name");
        source = append(source, std.fmt.comptimePrint(
            "    @scalar@ {s};\n",
            .{parameter},
        ));
    }
    return append(source, std.fmt.comptimePrint(
        "}} {s}_inputs;\n",
        .{name},
    ));
}

const types =
    \\
    \\typedef enum @name@_status {
    \\    @name@_converged,
    \\    @name@_singular_jacobian,
    \\    @name@_non_converged,
    \\    @name@_non_finite
    \\} @name@_status;
    \\
    \\typedef struct @name@_result {
    \\    @scalar@ values[@n@];
    \\    @scalar@ residual[@n@];
    \\    size_t iterations;
    \\    @scalar@ residual_norm;
    \\    @scalar@ step_norm;
    \\    @name@_status status;
    \\} @name@_result;
    \\
;

const helpers =
    \\
    \\static void @name@_finish(
    \\    @name@_result *output,
    \\    const @scalar@ *values,
    \\    const @scalar@ *residual,
    \\    size_t iterations,
    \\    @scalar@ residual_norm,
    \\    @scalar@ step_norm,
    \\    @name@_status status
    \\) {
    \\    size_t index;
    \\    for (index = 0; index < @n@; ++index) {
    \\        output->values[index] = values[index];
    \\        output->residual[index] = residual[index];
    \\    }
    \\    output->iterations = iterations;
    \\    output->residual_norm = residual_norm;
    \\    output->step_norm = step_norm;
    \\    output->status = status;
    \\}
    \\
    \\static @scalar@ @name@_infinity_norm(const @scalar@ *values, size_t count) {
    \\    @scalar@ norm = 0;
    \\    size_t index;
    \\    for (index = 0; index < count; ++index) {
    \\        const @scalar@ magnitude = fabs@suffix@(values[index]);
    \\        if (magnitude > norm) norm = magnitude;
    \\    }
    \\    return norm;
    \\}
    \\
    \\static int @name@_finite_vector(const @scalar@ *values, size_t count) {
    \\    size_t index;
    \\    for (index = 0; index < count; ++index) {
    \\        if (!isfinite(values[index])) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static int @name@_finite_matrix(@scalar@ matrix[@n@][@n@]) {
    \\    size_t row;
    \\    for (row = 0; row < @n@; ++row) {
    \\        if (!@name@_finite_vector(matrix[row], @n@)) return 0;
    \\    }
    \\    return 1;
    \\}
    \\
    \\static int @name@_solve(
    \\    @scalar@ matrix_input[@n@][@n@],
    \\    const @scalar@ *rhs_input,
    \\    @scalar@ pivot_tolerance,
    \\    @scalar@ *solution
    \\) {
    \\    @scalar@ matrix[@n@][@n1@];
    \\    @scalar@ scale = 0;
    \\    @scalar@ threshold;
    \\    size_t row;
    \\    size_t column;
    \\    size_t entry;
    \\    size_t reverse;
    \\    for (row = 0; row < @n@; ++row) {
    \\        for (column = 0; column < @n@; ++column) {
    \\            const @scalar@ magnitude = fabs@suffix@(matrix_input[row][column]);
    \\            matrix[row][column] = matrix_input[row][column];
    \\            if (magnitude > scale) scale = magnitude;
    \\        }
    \\        matrix[row][@n@] = rhs_input[row];
    \\    }
    \\    threshold = pivot_tolerance * ((scale > 1) ? scale : 1);
    \\    for (column = 0; column < @n@; ++column) {
    \\        size_t pivot_row = column;
    \\        @scalar@ pivot_magnitude = fabs@suffix@(matrix[column][column]);
    \\        for (row = column + 1; row < @n@; ++row) {
    \\            const @scalar@ magnitude = fabs@suffix@(matrix[row][column]);
    \\            if (magnitude > pivot_magnitude) {
    \\                pivot_magnitude = magnitude;
    \\                pivot_row = row;
    \\            }
    \\        }
    \\        if (!isfinite(pivot_magnitude) || pivot_magnitude <= threshold) {
    \\            return 0;
    \\        }
    \\        if (pivot_row != column) {
    \\            for (entry = 0; entry < @n1@; ++entry) {
    \\                const @scalar@ temporary = matrix[column][entry];
    \\                matrix[column][entry] = matrix[pivot_row][entry];
    \\                matrix[pivot_row][entry] = temporary;
    \\            }
    \\        }
    \\        for (row = column + 1; row < @n@; ++row) {
    \\            const @scalar@ factor = matrix[row][column] / matrix[column][column];
    \\            matrix[row][column] = 0;
    \\            for (entry = column + 1; entry < @n1@; ++entry) {
    \\                matrix[row][entry] -= factor * matrix[column][entry];
    \\            }
    \\        }
    \\    }
    \\    reverse = @n@;
    \\    while (reverse != 0) {
    \\        @scalar@ value;
    \\        reverse -= 1;
    \\        value = matrix[reverse][@n@];
    \\        for (column = reverse + 1; column < @n@; ++column) {
    \\            value -= matrix[reverse][column] * solution[column];
    \\        }
    \\        solution[reverse] = value / matrix[reverse][reverse];
    \\    }
    \\    return 1;
    \\}
    \\
;
