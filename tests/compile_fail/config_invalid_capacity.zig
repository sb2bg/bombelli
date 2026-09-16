// expect-error: error: Bombelli construction_nodes must be between 1 and 2147483647
// command: build-exe
const bombelli = @import("bombelli");
pub const bombelli_options: bombelli.Options = .{ .construction_nodes = 0 };
pub fn main() void {
    _ = comptime bombelli.expr("x");
}
