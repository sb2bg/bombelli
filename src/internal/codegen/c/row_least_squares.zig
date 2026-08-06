pub fn emitRowLeastSquares(
    comptime solver: anytype,
    comptime options: anytype,
) []const u8 {
    _ = solver;
    _ = options;
    @compileError("Bombelli C runtime-observation least-squares emission is not implemented yet");
}
