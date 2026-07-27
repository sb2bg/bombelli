//! Reusable validation for comptime option structs.

const std = @import("std");

pub fn requireField(
    comptime Options: type,
    comptime field: []const u8,
    comptime message: []const u8,
) void {
    if (!@hasField(Options, field)) @compileError(message);
}

pub fn requireTag(
    comptime value: anytype,
    comptime field: []const u8,
    comptime expected: []const u8,
    comptime message: []const u8,
) void {
    const Options = @TypeOf(value);
    requireField(Options, field, message);
    if (!std.mem.eql(u8, @tagName(@field(value, field)), expected)) {
        @compileError(message);
    }
}
