//! Compile-time fragment collection with a single exact-sized final copy.
pub const Text = struct {
    const Fragment = struct { previous: ?*const Fragment, bytes: []const u8 };
    tail: ?*const Fragment = null,
    len: usize = 0,

    pub fn init(comptime bytes: []const u8) Text {
        var result = Text{};
        result.append(bytes);
        return result;
    }

    pub fn append(comptime self: *Text, comptime bytes: []const u8) void {
        if (bytes.len == 0) return;
        const fragment = Fragment{ .previous = self.tail, .bytes = bytes };
        self.tail = &fragment;
        self.len += bytes.len;
    }

    pub fn finish(comptime self: Text) []const u8 {
        var buffer: [self.len]u8 = undefined;
        var end = buffer.len;
        var cursor = self.tail;
        while (cursor) |fragment| {
            const start = end - fragment.bytes.len;
            @memcpy(buffer[start..end], fragment.bytes);
            end = start;
            cursor = fragment.previous;
        }
        const result = buffer;
        return &result;
    }
};
