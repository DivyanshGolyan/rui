const std = @import("std");
const CiArtifacts = @import("ci.zig").CiArtifacts;

pub fn add(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dependency = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis = dependency.module("vaxis");
    const tests = b.addTest(.{
        .name = "test-vaxis-clipboard",
        .root_module = vaxis,
        .filters = &.{ "test.refAllDecls", "OSC 5522" },
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", "test");
    const header = b.addTranslateC(.{
        .root_source_file = dependency.path("include/vaxis.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_tests = b.addTest(.{
        .name = "test-vaxis-c-api",
        .root_module = b.createModule(.{
            .root_source_file = dependency.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "vaxis_h", .module = header.createModule() },
            },
        }),
        .filters = &.{ "c api: conformance with vaxis.h", "c api: ignores internal clipboard protocol events" },
    });
    const ci_names = b.addTest(.{
        .name = "test-ci-artifact-names",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/ci.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"CI artifact names"},
    });
    const owners = b.addSystemCommand(&.{ "python3", "-B" });
    owners.addFileArg(b.path("tests/ci/verify_vaxis_test_owners.py"));
    owners.addFileArg(b.path("tests/ci/vaxis_test_owners.json"));
    owners.addFileArg(b.path("build.zig.zon"));
    owners.addDirectoryArg(dependency.path("src"));
    const step = b.step("test-vaxis-clipboard", "Test Vaxis OSC 5522 transport and C compatibility");
    step.dependOn(&ci.run(tests).step);
    step.dependOn(&ci.run(c_tests).step);
    step.dependOn(&ci.run(ci_names).step);
    step.dependOn(&owners.step);
}
