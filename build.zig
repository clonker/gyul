const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/gyul/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("gyul", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "gyul",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "gyul",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Differential corpus test against vendor/solidity yul optimizer
    // fixtures. Slow (642 fixtures) and depends on the submodule being
    // checked out, so it's its own build step rather than part of the
    // default `zig build test`.
    const spec_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gyul/spec_corpus_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spec_unit_tests = b.addTest(.{
        .root_module = spec_test_mod,
    });
    const run_spec_unit_tests = b.addRunArtifact(spec_unit_tests);
    run_spec_unit_tests.has_side_effects = true; // always re-run, never cache
    const spec_test_step = b.step("spec-test", "Run yul optimizer corpus differential tests");
    spec_test_step.dependOn(&run_spec_unit_tests.step);
}
