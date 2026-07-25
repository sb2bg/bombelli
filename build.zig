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
        .root_module = bombelli,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Bombelli test suite");
    test_step.dependOn(&run_tests.step);

    const compile_fail_step = b.step(
        "test-compile-fail",
        "Verify source-focused compile-time diagnostics",
    );
    const compile_fail_cases = [_]struct {
        path: []const u8,
        expected: []const u8,
        source_diagnostic: bool = true,
    }{
        .{ .path = "tests/compile_fail/trailing_token.zig", .expected = "unexpected trailing token" },
        .{ .path = "tests/compile_fail/unexpected_character.zig", .expected = "unexpected character" },
        .{
            .path = "tests/compile_fail/missing_input_field.zig",
            .expected = "Bombelli eval input is missing the field '.y'",
            .source_diagnostic = false,
        },
        .{ .path = "tests/compile_fail/invalid_exponent.zig", .expected = "power exponent must be a non-negative integer literal" },
        .{ .path = "tests/compile_fail/missing_parenthesis.zig", .expected = "missing closing parenthesis" },
        .{ .path = "tests/compile_fail/unknown_function.zig", .expected = "unknown function" },
        .{ .path = "tests/compile_fail/power_chaining.zig", .expected = "power chaining is not supported; parenthesize the base" },
        .{
            .path = "tests/compile_fail/integer_fold_overflow.zig",
            .expected = "integer constant folding exceeds i64 range",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/nested_integer_fold_overflow.zig",
            .expected = "integer constant folding exceeds i64 range",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/power_fold_overflow.zig",
            .expected = "integer constant folding exceeds i64 range",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/rational_fold_overflow.zig",
            .expected = "exact rational constant folding exceeds fixed-width range",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/ln_domain.zig",
            .expected = "ln is undefined for non-positive constants",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/ln_negative_domain.zig",
            .expected = "ln is undefined for non-positive constants",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/exp_fold_overflow.zig",
            .expected = "constant folding produced a non-finite floating-point value",
            .source_diagnostic = false,
        },
        .{ .path = "tests/compile_fail/float_literal_overflow.zig", .expected = "floating-point literal is out of range" },
    };
    for (compile_fail_cases) |case| {
        const check = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "--dep",
            "bombelli",
        });
        check.setName(b.fmt("compile-fail {s}", .{case.path}));
        check.addPrefixedFileArg("-Mroot=", b.path(case.path));
        check.addPrefixedFileArg("-Mbombelli=", b.path("src/root.zig"));
        check.expectExitCode(1);
        check.expectStdErrMatch(if (case.source_diagnostic)
            b.fmt("error: {s} at byte", .{case.expected})
        else
            b.fmt("error: {s}", .{case.expected}));
        compile_fail_step.dependOn(&check.step);
    }
    test_step.dependOn(compile_fail_step);

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
