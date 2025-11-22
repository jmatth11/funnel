const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // create module
    const mod = b.addModule("funnel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Link mode for utf8-zig library",
    ) orelse .static;
    const lib = b.addLibrary(.{
        .root_module = mod,
        .linkage = linkage,
        .name = "funnel",
    });

    lib.bundle_compiler_rt = true;
    lib.linkLibC();

    b.installArtifact(lib);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });
    lib_unit_tests.linkLibC();

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
