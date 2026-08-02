// expect-error: Bombelli complex Newton requires holomorphic residuals; abs is not holomorphic
const bombelli = @import("bombelli");

test {
    _ = comptime bombelli.equationProblem("abs(z) = 1", .{
        .unknowns = .{.z},
        .domain = .complex,
    }).compile(.{
        .algorithm = .newton,
        .jacobian = .symbolic,
        .max_iterations = 8,
        .tolerance = 1e-12,
    });
}
