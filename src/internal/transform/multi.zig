const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");

pub fn vector(
    comptime N: usize,
    comptime expressions: [N]ast.Expr,
) ast.ExprVector(N) {
    var builder = build.Builder{};
    var construction_peak_nodes: usize = 0;
    var roots: [N]ast.NodeId = undefined;
    var sources: [N][]const u8 = undefined;
    inline for (expressions, 0..) |expression, index| {
        construction_peak_nodes = @max(
            construction_peak_nodes,
            expression.construction_peak_nodes,
        );
        var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
        roots[index] = builder.cloneNode(expression.nodes, expression.root, &cache);
        sources[index] = expression.source;
    }
    var result = builder.finishVector(N, roots, sources);
    result.construction_peak_nodes = @max(
        construction_peak_nodes,
        result.construction_peak_nodes,
    );
    return result;
}

pub fn matrix(
    comptime R: usize,
    comptime C: usize,
    comptime expressions: [R][C]ast.Expr,
) ast.ExprMatrix(R, C) {
    var builder = build.Builder{};
    var construction_peak_nodes: usize = 0;
    var roots: [R][C]ast.NodeId = undefined;
    var sources: [R][C][]const u8 = undefined;
    inline for (expressions, 0..) |row, row_index| {
        inline for (row, 0..) |expression, column_index| {
            construction_peak_nodes = @max(
                construction_peak_nodes,
                expression.construction_peak_nodes,
            );
            var cache = [_]ast.NodeId{ast.invalid_node} ** expression.nodes.len;
            roots[row_index][column_index] = builder.cloneNode(
                expression.nodes,
                expression.root,
                &cache,
            );
            sources[row_index][column_index] = expression.source;
        }
    }
    var result = builder.finishMatrix(R, C, roots, sources);
    result.construction_peak_nodes = @max(
        construction_peak_nodes,
        result.construction_peak_nodes,
    );
    return result;
}

pub fn gradient(
    comptime expression: ast.Expr,
    comptime variables: anytype,
) ast.ExprVector(ast.tupleLength(@TypeOf(variables))) {
    const N = ast.tupleLength(@TypeOf(variables));
    if (N == 0) @compileError("Bombelli gradient expects at least one variable");
    var derivatives: [N]ast.Expr = undefined;
    inline for (variables, 0..) |variable, index| {
        derivatives[index] = expression.diff(variable);
    }
    return vector(N, derivatives);
}

pub fn hessian(
    comptime expression: ast.Expr,
    comptime variables: anytype,
) ast.ExprMatrix(
    ast.tupleLength(@TypeOf(variables)),
    ast.tupleLength(@TypeOf(variables)),
) {
    return gradient(expression, variables).jacobian(variables);
}

pub fn scalarJacobian(
    comptime expression: ast.Expr,
    comptime variables: anytype,
) ast.ExprMatrix(1, ast.tupleLength(@TypeOf(variables))) {
    const N = ast.tupleLength(@TypeOf(variables));
    const derivatives = gradient(expression, variables);
    var entries: [1][N]ast.Expr = undefined;
    inline for (0..N) |column| {
        entries[0][column] = vectorElement(N, derivatives, column);
    }
    return matrix(1, N, entries);
}

pub fn jacobian(
    comptime R: usize,
    comptime expression: ast.ExprVector(R),
    comptime variables: anytype,
) ast.ExprMatrix(R, ast.tupleLength(@TypeOf(variables))) {
    const C = ast.tupleLength(@TypeOf(variables));
    if (C == 0) @compileError("Bombelli Jacobian expects at least one variable");
    var derivatives: [R][C]ast.Expr = undefined;
    inline for (0..R) |row| {
        const element = vectorElement(R, expression, row);
        inline for (variables, 0..) |variable, column| {
            derivatives[row][column] = element.diff(variable);
        }
    }
    return matrix(R, C, derivatives);
}

pub fn vectorElement(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime index: usize,
) ast.Expr {
    return extractRoot(expression.nodes, expression.roots[index], expression.sources[index]);
}

pub fn matrixElement(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime row: usize,
    comptime column: usize,
) ast.Expr {
    return extractRoot(
        expression.nodes,
        expression.roots[row][column],
        expression.sources[row][column],
    );
}

pub fn simplifyVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
) ast.ExprVector(N) {
    return @import("simplification.zig").simplifyVector(N, expression);
}

pub fn simplifyMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
) ast.ExprMatrix(R, C) {
    return @import("simplification.zig").simplifyMatrix(R, C, expression);
}

pub fn differentiateVector(
    comptime N: usize,
    comptime expression: ast.ExprVector(N),
    comptime variable: anytype,
) ast.ExprVector(N) {
    var derivatives: [N]ast.Expr = undefined;
    inline for (0..N) |index| {
        derivatives[index] = vectorElement(N, expression, index).diff(variable);
    }
    return vector(N, derivatives);
}

pub fn differentiateMatrix(
    comptime R: usize,
    comptime C: usize,
    comptime expression: ast.ExprMatrix(R, C),
    comptime variable: anytype,
) ast.ExprMatrix(R, C) {
    var derivatives: [R][C]ast.Expr = undefined;
    inline for (0..R) |row| {
        inline for (0..C) |column| {
            derivatives[row][column] = matrixElement(R, C, expression, row, column).diff(variable);
        }
    }
    return matrix(R, C, derivatives);
}

pub fn extractRoot(
    comptime nodes: []const ast.Node,
    comptime root: ast.NodeId,
    comptime source: []const u8,
) ast.Expr {
    var builder = build.Builder{};
    var cache = [_]ast.NodeId{ast.invalid_node} ** nodes.len;
    const cloned_root = builder.cloneNode(nodes, root, &cache);
    return builder.finish(cloned_root, source);
}
