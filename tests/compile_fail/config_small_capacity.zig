// expect-error: error: Bombelli construction exceeds the temporary arena limit of 3 nodes
// command: build-exe
const bombelli = @import("bombelli");
pub const bombelli_options: bombelli.Options = .{ .construction_nodes = 3 };
pub fn main() void {
    _ = comptime bombelli.expr("sin(cos(exp(x)))");
}
