const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bombelli = b.addModule("bombelli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const context = Context{
        .b = b,
        .bombelli = bombelli,
        .target = target,
        .optimize = optimize,
    };

    const test_step = context.addTestSuite(.{
        .name = "test",
        .description = "Run the Bombelli test suite",
        .source = "tests/root.zig",
    });

    addCompileFailTests(b, test_step);

    inline for ([_]Suite{
        .{ .name = "stress", .description = "Run compile-time expression stress tests", .source = "tests/stress.zig" },
        .{ .name = "properties", .description = "Run deterministic mathematical and DAG property tests", .source = "tests/properties.zig" },
        .{ .name = "hardening", .description = "Run domain, singularity, and numerical-status hardening tests", .source = "tests/hardening.zig" },
    }) |suite| test_step.dependOn(context.addTestSuite(suite));

    const differential = b.addSystemCommand(&.{
        "python3",
        "tests/differential_sympy.py",
    });
    differential.setName("SymPy differential validation");
    const differential_step = b.step(
        "differential",
        "Run seeded differential validation against SymPy",
    );
    differential_step.dependOn(&differential.step);

    const emission_validation = b.addSystemCommand(&.{
        "python3",
        "tests/codegen/validate_emission.py",
    });
    emission_validation.setName("standalone source emission validation");
    const emission_step = b.step(
        "test-emission",
        "Generate and execute standalone emitted Zig and C",
    );
    emission_step.dependOn(&emission_validation.step);

    const docs_object = b.addObject(.{
        .name = "bombelli-docs",
        .root_module = bombelli,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_object.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation in zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const formatting = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "build.zig",
        "src",
        "tests",
        "examples",
        "benchmarks",
    });
    formatting.setName("Zig formatting check");
    const formatting_step = b.step("fmt-check", "Check Zig source formatting");
    formatting_step.dependOn(&formatting.step);

    const check_step = b.step(
        "check",
        "Run formatting, tests, differential checks, emission validation, and docs",
    );
    check_step.dependOn(formatting_step);
    check_step.dependOn(test_step);
    check_step.dependOn(differential_step);
    check_step.dependOn(emission_step);
    check_step.dependOn(docs_step);

    const examples_step = b.step("examples", "Compile all examples");
    inline for ([_]Example{
        .{ .name = "bombelli-example", .source = "examples/flagship.zig", .run_name = "run", .description = "Run the Bombelli example", .install = true },
        .{ .name = "bombelli-curve-fit", .source = "examples/curve_fit.zig", .run_name = "run-curve-fit", .description = "Fit an exponential curve to runtime observations" },
        .{ .name = "bombelli-jacobian-counterexample", .source = "examples/jacobian_counterexample.zig", .run_name = "run-jacobian", .description = "Check the Jacobian conjecture counterexample at compile time" },
    }) |example| context.addExample(examples_step, example);
    check_step.dependOn(examples_step);
}

const Suite = struct {
    name: []const u8,
    description: []const u8,
    source: []const u8,
};

const Example = struct {
    name: []const u8,
    source: []const u8,
    run_name: []const u8,
    description: []const u8,
    install: bool = false,
};

const Context = struct {
    b: *std.Build,
    bombelli: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn addTestSuite(self: Context, suite: Suite) *std.Build.Step {
        const tests = self.b.addTest(.{
            .root_module = self.module(suite.source),
        });
        const run = self.b.addRunArtifact(tests);
        const step = self.b.step(suite.name, suite.description);
        step.dependOn(&run.step);
        return step;
    }

    fn addExample(self: Context, examples_step: *std.Build.Step, options: Example) void {
        const example = self.b.addExecutable(.{
            .name = options.name,
            .root_module = self.module(options.source),
        });
        if (options.install) self.b.installArtifact(example);
        examples_step.dependOn(&example.step);

        const run = self.b.addRunArtifact(example);
        const run_step = self.b.step(options.run_name, options.description);
        run_step.dependOn(&run.step);
    }

    fn module(self: Context, source: []const u8) *std.Build.Module {
        return self.b.createModule(.{
            .root_source_file = self.b.path(source),
            .target = self.target,
            .optimize = self.optimize,
            .imports = &.{.{ .name = "bombelli", .module = self.bombelli }},
        });
    }
};

fn addCompileFailTests(b: *std.Build, test_step: *std.Build.Step) void {
    const directory_path = "tests/compile_fail";
    const expectation_prefix = "// expect-error: ";
    const io = b.graph.io;

    var directory = b.build_root.handle.openDir(
        io,
        directory_path,
        .{ .iterate = true },
    ) catch |err| {
        std.debug.panic(
            "unable to open {s}: {s}",
            .{ directory_path, @errorName(err) },
        );
    };
    defer directory.close(io);

    const compile_fail_step = b.step(
        "test-compile-fail",
        "Verify automatically discovered compile-time diagnostics",
    );
    var discovered: usize = 0;
    var iterator = directory.iterate();
    while (iterator.next(io) catch |err| {
        std.debug.panic(
            "unable to enumerate {s}: {s}",
            .{ directory_path, @errorName(err) },
        );
    }) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.name, ".zig"))
        {
            continue;
        }

        const contents = directory.readFileAlloc(
            io,
            entry.name,
            b.allocator,
            .limited(64 * 1024),
        ) catch |err| {
            std.debug.panic(
                "unable to read {s}/{s}: {s}",
                .{ directory_path, entry.name, @errorName(err) },
            );
        };
        const line_end = std.mem.indexOfScalar(u8, contents, '\n') orelse
            contents.len;
        const first_line = std.mem.trimEnd(
            u8,
            contents[0..line_end],
            "\r",
        );
        if (!std.mem.startsWith(u8, first_line, expectation_prefix)) {
            std.debug.panic(
                "{s}/{s} must begin with '{s}<diagnostic>'",
                .{ directory_path, entry.name, expectation_prefix },
            );
        }
        const expected = first_line[expectation_prefix.len..];
        if (expected.len == 0) {
            std.debug.panic(
                "{s}/{s} has an empty compile-fail expectation",
                .{ directory_path, entry.name },
            );
        }

        const case_path = b.fmt(
            "{s}/{s}",
            .{ directory_path, entry.name },
        );
        const check = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "--dep",
            "bombelli",
        });
        check.setName(b.fmt("compile-fail {s}", .{entry.name}));
        check.addPrefixedFileArg("-Mroot=", b.path(case_path));
        check.addPrefixedFileArg("-Mbombelli=", b.path("src/root.zig"));
        check.expectExitCode(1);
        check.expectStdErrMatch(expected);
        compile_fail_step.dependOn(&check.step);
        discovered += 1;
    }

    if (discovered == 0) {
        std.debug.panic("no compile-fail cases found in {s}", .{directory_path});
    }
    test_step.dependOn(compile_fail_step);
}
