const std = @import("std");
const ast = @import("ast.zig");
const composition = @import("composition.zig");
const parser = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");

pub const Equation = struct {
    lhs: ast.Expr,
    rhs: ast.Expr,
    residual: ast.Expr,
    source: []const u8,

    pub fn render(comptime self: Equation) []const u8 {
        return std.fmt.comptimePrint(
            "{s} = {s}",
            .{ self.lhs.render(), self.rhs.render() },
        );
    }
};

pub fn parse(comptime source: []const u8) Equation {
    const first_optional = comptime std.mem.indexOfScalar(u8, source, '=');
    if (first_optional == null) {
        diagnostic.fail(source, 0, "equation must contain exactly one '='");
    }
    const first = comptime first_optional.?;
    const second = comptime std.mem.indexOfScalarPos(u8, source, first + 1, '=');
    if (second != null) {
        diagnostic.fail(source, first + 1, "equation must contain exactly one '='");
    }
    const lhs_source = comptime std.mem.trim(u8, source[0..first], " \t\r\n");
    const rhs_source = comptime std.mem.trim(u8, source[first + 1 ..], " \t\r\n");
    if (lhs_source.len == 0 or rhs_source.len == 0) {
        diagnostic.fail(source, first, "equation requires expressions on both sides");
    }
    const lhs = comptime parser.parse(lhs_source);
    const rhs = comptime parser.parse(rhs_source);
    const residual = comptime composition.subtract(lhs, rhs).simplify();
    return .{
        .lhs = lhs,
        .rhs = rhs,
        .residual = residual,
        .source = source,
    };
}
