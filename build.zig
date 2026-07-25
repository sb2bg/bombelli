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
        .{ .path = "tests/compile_fail/invalid_exponent.zig", .expected = "power exponent must be an exact rational literal" },
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
            .path = "tests/compile_fail/rational_power_domain.zig",
            .expected = "even-denominator rational power is not real for a negative base",
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
        .{ .path = "tests/compile_fail/equation_missing_equals.zig", .expected = "equation must contain exactly one '='" },
        .{ .path = "tests/compile_fail/equation_multiple_equals.zig", .expected = "equation must contain exactly one '='" },
        .{
            .path = "tests/compile_fail/require_unique_multiple.zig",
            .expected = "Bombelli expected one solution, but found 2",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/unwrap_partial_integral.zig",
            .expected = "Bombelli integration is partial; unresolved remainder: exp(x^2)",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/unsupported_quadrature_order.zig",
            .expected = "Bombelli Gauss-Legendre quadrature supports orders 4, 8, 16, and 32; received 12",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/quadrature_diff_bound.zig",
            .expected = "Bombelli quadrature endpoints are runtime inputs; parameter-dependent bounds require explicit Leibniz terms",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/hybrid_diff_dependent_bound.zig",
            .expected = "Bombelli hybrid integration has parameter-dependent bounds; explicit Leibniz boundary terms are required",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/newton_missing_initial.zig",
            .expected = "Bombelli Newton eval input requires '.initial'",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/newton_diff_unknown.zig",
            .expected = "Bombelli Newton sensitivity parameter must not be one of the solved unknowns",
            .source_diagnostic = false,
        },
        .{
            .path = "tests/compile_fail/callable_unsupported_diff.zig",
            .expected = "Bombelli adaptive quadrature is not differentiable because its runtime subdivision branches may change",
            .source_diagnostic = false,
        },
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
