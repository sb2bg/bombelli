pub inline fn eval(
    comptime value: anytype,
    inputs: anytype,
) @TypeOf(value.eval(inputs)) {
    return value.eval(inputs);
}

pub fn emit(
    comptime value: anytype,
    comptime options: anytype,
) []const u8 {
    return value.emit(options);
}

pub fn supports(comptime T: type, comptime operation: []const u8) bool {
    return @hasDecl(T, operation);
}
