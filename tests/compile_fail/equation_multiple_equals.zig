// expect-error: error: equation must contain exactly one '=' at byte
const bombelli = @import("bombelli");

comptime {
    _ = bombelli.equation("x = y = z");
}
