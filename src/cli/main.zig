const std = @import("std");
const clap = @import("clap");
const build_options = @import("cli_build_options");

const driver_source = @embedFile("emit_driver.zig");

const cli_params = clap.parseParamsComptime(
    \\-h, --help       Display this help and exit.
    \\    --emit <str> Emission target: zig or c.
    \\    --name <str> Generated function name. Defaults to evaluate.
    \\<str>...         Command arguments.
    \\
);

const usage =
    \\Usage:
    \\  bombelli --emit <zig|c> [--name <identifier>] <expression>
    \\  bombelli emit <zig|c> [--name <identifier>] <expression>
    \\
    \\Examples:
    \\  bombelli --emit zig "x + 5"
    \\  bombelli --emit c --name evaluate "sin(x) + x^2"
    \\
;

const EmitConfig = struct {
    target: []const u8,
    name: []const u8,
    expression: []const u8,
};

const Command = union(enum) {
    help,
    emit: EmitConfig,
};

const ArgumentError = error{
    MissingCommand,
    UnknownCommand,
    MissingTarget,
    UnsupportedTarget,
    MissingExpression,
    UnexpectedArgument,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        writer.interface.print(
            "bombelli: {s}\n",
            .{@errorName(err)},
        ) catch {};
        writer.interface.flush() catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    var diagnostic = clap.Diagnostic{};
    var parsed = clap.parse(
        clap.Help,
        &cli_params,
        clap.parsers.default,
        init.minimal.args,
        .{
            .allocator = init.gpa,
            .diagnostic = &diagnostic,
        },
    ) catch |err| {
        try diagnostic.reportToFile(init.io, .stderr(), err);
        try writeFile(init.io, std.Io.File.stderr(), usage);
        return 2;
    };
    defer parsed.deinit();

    const command = commandFromParsed(
        parsed.args.help,
        parsed.args.emit,
        parsed.args.name,
        parsed.positionals[0],
    ) catch |err| {
        try writeArgumentError(init.io, err);
        return 2;
    };

    return switch (command) {
        .help => blk: {
            try writeFile(init.io, std.Io.File.stdout(), usage);
            break :blk 0;
        },
        .emit => |config| try emitSource(init, config),
    };
}

fn commandFromParsed(
    help_count: u8,
    emit_target: ?[]const u8,
    requested_name: ?[]const u8,
    positionals: []const []const u8,
) ArgumentError!Command {
    if (help_count != 0 or
        (emit_target == null and
            positionals.len == 1 and
            std.mem.eql(u8, positionals[0], "help")))
    {
        return .help;
    }

    const target, const expression = if (emit_target) |target| blk: {
        if (positionals.len == 0) return error.MissingExpression;
        if (positionals.len != 1) return error.UnexpectedArgument;
        break :blk .{ target, positionals[0] };
    } else blk: {
        if (positionals.len == 0) return error.MissingCommand;
        if (!std.mem.eql(u8, positionals[0], "emit")) {
            return error.UnknownCommand;
        }
        if (positionals.len < 2) return error.MissingTarget;
        if (positionals.len < 3) return error.MissingExpression;
        if (positionals.len != 3) return error.UnexpectedArgument;
        break :blk .{ positionals[1], positionals[2] };
    };
    if (!std.mem.eql(u8, target, "zig") and
        !std.mem.eql(u8, target, "c"))
    {
        return error.UnsupportedTarget;
    }

    return .{ .emit = .{
        .target = target,
        .name = requested_name orelse "evaluate",
        .expression = expression,
    } };
}

fn emitSource(init: std.process.Init, config: EmitConfig) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const bombelli_root = try locateBombelliRoot(init, arena);

    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var encoded: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 =
        undefined;
    _ = std.base64.url_safe.Encoder.encode(&encoded, &random_bytes);
    const temporary_name = try std.fmt.allocPrint(
        arena,
        "bombelli-{s}",
        .{encoded},
    );
    const temporary_base = init.environ_map.get("TMPDIR") orelse
        init.environ_map.get("TEMP") orelse
        init.environ_map.get("TMP") orelse
        ".";
    const temporary_path = try std.fs.path.resolve(
        arena,
        &.{ temporary_base, temporary_name },
    );

    const cwd = std.Io.Dir.cwd();
    var temporary = try cwd.createDirPathOpen(io, temporary_path, .{});
    defer cwd.deleteTree(io, temporary_path) catch {};
    defer temporary.close(io);

    const options_source = try std.fmt.allocPrint(
        arena,
        \\pub const expression = "{f}";
        \\pub const target = "{f}";
        \\pub const name = "{f}";
        \\
    ,
        .{
            std.zig.fmtString(config.expression),
            std.zig.fmtString(config.target),
            std.zig.fmtString(config.name),
        },
    );
    try temporary.writeFile(io, .{
        .sub_path = "driver.zig",
        .data = driver_source,
    });
    try temporary.writeFile(io, .{
        .sub_path = "options.zig",
        .data = options_source,
    });

    const driver_path = try std.fs.path.join(
        arena,
        &.{ temporary_path, "driver.zig" },
    );
    const options_path = try std.fs.path.join(
        arena,
        &.{ temporary_path, "options.zig" },
    );
    const root_argument = try std.fmt.allocPrint(
        arena,
        "-Mroot={s}",
        .{driver_path},
    );
    const bombelli_argument = try std.fmt.allocPrint(
        arena,
        "-Mbombelli={s}",
        .{bombelli_root},
    );
    const options_argument = try std.fmt.allocPrint(
        arena,
        "-Mcli_options={s}",
        .{options_path},
    );
    const zig_executable = init.environ_map.get("ZIG_EXE") orelse "zig";
    var child = try std.process.spawn(io, .{
        .argv = &.{
            zig_executable,
            "run",
            "--dep",
            "bombelli",
            "--dep",
            "cli_options",
            root_argument,
            bombelli_argument,
            options_argument,
        },
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn locateBombelliRoot(
    init: std.process.Init,
    arena: std.mem.Allocator,
) ![]const u8 {
    if (init.environ_map.get("BOMBELLI_ROOT")) |override| {
        const resolved = try std.fs.path.resolve(arena, &.{override});
        try std.Io.Dir.accessAbsolute(init.io, resolved, .{});
        return resolved;
    }

    const executable_dir = try std.process.executableDirPathAlloc(
        init.io,
        arena,
    );
    const prefix = std.fs.path.dirname(executable_dir) orelse
        return error.InvalidExecutablePath;
    const installed = try std.fs.path.resolve(arena, &.{
        prefix,
        "share",
        "bombelli",
        "src",
        "root.zig",
    });
    if (std.Io.Dir.accessAbsolute(init.io, installed, .{})) |_| {
        return installed;
    } else |_| {}

    if (std.Io.Dir.accessAbsolute(
        init.io,
        build_options.development_bombelli_root,
        .{},
    )) |_| {
        return build_options.development_bombelli_root;
    } else |_| {
        return error.BombelliSourcesNotFound;
    }
}

fn writeArgumentError(io: std.Io, err: ArgumentError) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print("bombelli: {s}\n\n", .{switch (err) {
        error.MissingCommand => "missing command",
        error.UnknownCommand => "unknown command",
        error.MissingTarget => "missing emission target",
        error.UnsupportedTarget => "emission target must be 'zig' or 'c'",
        error.MissingExpression => "missing expression",
        error.UnexpectedArgument => "unexpected extra argument",
    }});
    try writer.interface.writeAll(usage);
    try writer.interface.flush();
}

fn writeFile(io: std.Io, file: std.Io.File, contents: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}

test "CLI accepts both emission command spellings" {
    const flag_command = try commandFromParsed(
        0,
        "zig",
        null,
        &.{"x + 5"},
    );
    try std.testing.expectEqualStrings(
        "x + 5",
        flag_command.emit.expression,
    );
    try std.testing.expectEqualStrings("evaluate", flag_command.emit.name);

    const subcommand = try commandFromParsed(
        0,
        null,
        "calculate",
        &.{ "emit", "c", "sin(x)" },
    );
    try std.testing.expectEqualStrings("c", subcommand.emit.target);
    try std.testing.expectEqualStrings("calculate", subcommand.emit.name);
}

test "CLI rejects unsupported targets and extra expressions" {
    try std.testing.expectError(
        error.UnsupportedTarget,
        commandFromParsed(
            0,
            null,
            null,
            &.{
                "emit",
                "rust",
                "x",
            },
        ),
    );

    try std.testing.expectError(
        error.UnexpectedArgument,
        commandFromParsed(
            0,
            "zig",
            null,
            &.{
                "x",
                "y",
            },
        ),
    );
}

test "CLI help works as a flag or command" {
    try std.testing.expect(
        (try commandFromParsed(
            1,
            null,
            null,
            &.{},
        )) == .help,
    );
    try std.testing.expect(
        (try commandFromParsed(
            0,
            null,
            null,
            &.{"help"},
        )) == .help,
    );
}
