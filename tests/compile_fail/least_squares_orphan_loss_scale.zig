// expect-error: Bombelli least-squares loss_scale requires an enum loss selection
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.model(.{"x-1"}, .{
        .variables = .{.x},
    }).leastSquares().compile(.{
        .algorithm = .levenberg_marquardt,
        .jacobian = .symbolic,
        .loss_scale = 2.0,
    });
}
