//! Compiler construction options, selected by the application's root module.

pub const Options = struct {
    /// Maximum temporary nodes in each symbolic construction workspace.
    /// Finished programs keep only their reachable nodes.
    construction_nodes: usize = 1024,
};

pub const selected: Options = if (@hasDecl(@import("root"), "bombelli_options"))
    @import("root").bombelli_options
else
    .{};

comptime {
    if (selected.construction_nodes == 0 or selected.construction_nodes > 0x7fff_ffff)
        @compileError("Bombelli construction_nodes must be between 1 and 2147483647");
}
