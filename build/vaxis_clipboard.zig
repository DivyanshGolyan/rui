const std = @import("std");
const CiArtifacts = @import("ci.zig").CiArtifacts;

pub fn add(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dependency = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "test-vaxis-clipboard",
        .root_module = dependency.module("vaxis"),
        .filters = &.{ "test.refAllDecls", "OSC 5522" },
    });
    b.step("test-vaxis-clipboard", "Test Vaxis OSC 5522 transport").dependOn(&ci.run(tests).step);
}
