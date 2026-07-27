const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bombelli = b.addModule("bombelli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bombelli", .module = bombelli },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Bombelli test suite");
    test_step.dependOn(&run_tests.step);

    addCompileFailTests(b, test_step);

    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bombelli", .module = bombelli },
            },
        }),
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("stress", "Run compile-time expression stress tests");
    stress_step.dependOn(&run_stress_tests.step);
    test_step.dependOn(stress_step);

    const property_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/properties.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bombelli", .module = bombelli },
            },
        }),
    });
    const run_property_tests = b.addRunArtifact(property_tests);
    const property_step = b.step(
        "properties",
        "Run deterministic mathematical and DAG property tests",
    );
    property_step.dependOn(&run_property_tests.step);
    test_step.dependOn(property_step);

    const hardening_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/hardening.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bombelli", .module = bombelli },
            },
        }),
    });
    const run_hardening_tests = b.addRunArtifact(hardening_tests);
    const hardening_step = b.step(
        "hardening",
        "Run domain, singularity, and numerical-status hardening tests",
    );
    hardening_step.dependOn(&run_hardening_tests.step);
    test_step.dependOn(hardening_step);

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
    emission_validation.setName("standalone Zig emission validation");
    const emission_step = b.step(
        "test-emission",
        "Generate and execute standalone emitted Zig",
    );
    emission_step.dependOn(&emission_validation.step);

    const example = b.addExecutable(.{
        .name = "bombelli-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/flagship.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bombelli", .module = bombelli },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the Bombelli example");
    run_step.dependOn(&run_example.step);
}

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
