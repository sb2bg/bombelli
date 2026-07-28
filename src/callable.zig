pub inline fn eval(
    comptime value: anytype,
    inputs: anytype,
) @TypeOf(value.eval(inputs)) {
    return value.eval(inputs);
}

pub inline fn evalAs(
    comptime T: type,
    comptime value: anytype,
    inputs: anytype,
) @TypeOf(value.evalAs(T, inputs)) {
    return value.evalAs(T, inputs);
}

pub inline fn evalInto(
    comptime value: anytype,
    output: anytype,
    inputs: anytype,
) void {
    value.evalInto(output, inputs);
}

pub inline fn evalIntoAs(
    comptime T: type,
    comptime value: anytype,
    output: anytype,
    inputs: anytype,
) void {
    value.evalIntoAs(T, output, inputs);
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
