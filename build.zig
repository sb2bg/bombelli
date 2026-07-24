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
