// expect-error: error: Bombelli Jacobian product input field '.typo' does not name an input of this callable
const bombelli = @import("bombelli");
test {
    const compiled = comptime bombelli.model(.{"x^2"}, .{ .variables = .{.x} }).compileJvp(.{});
    _ = compiled.eval(.{ .x = 1.0, .typo = 2.0 }, .{1});
}
