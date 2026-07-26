const std = @import("std");

pub fn fail(
    comptime source: []const u8,
    comptime position: usize,
    comptime message: []const u8,
) noreturn {
    const safe_position = @min(position, source.len);
    const line_start = comptime blk: {
        var start: usize = safe_position;
        while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
        break :blk start;
    };
    const line_end = comptime blk: {
        var end: usize = safe_position;
        while (end < source.len and source[end] != '\n') : (end += 1) {}
        break :blk end;
    };
    const column = safe_position - line_start;
    const spaces = [_]u8{' '} ** column;

    @compileError(std.fmt.comptimePrint(
        "{s} at byte {d}\n{s}\n{s}^",
        .{ message, safe_position, source[line_start..line_end], spaces[0..] },
    ));
}
