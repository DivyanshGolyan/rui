const std = @import("std");

pub fn add(b: *std.Build, dependency: *std.Build.Dependency) *std.Build.Module {
    const module = dependency.module("vaxis");
    if (!b.top_level_steps.contains("test-vaxis-clipboard")) {
        const tests = b.addTest(.{
            .name = "test-vaxis-clipboard",
            .root_module = module,
            .filters = &.{ "test.refAllDecls", "OSC 5522" },
        });
        b.step("test-vaxis-clipboard", "Test Vaxis OSC 5522 transport").dependOn(&b.addRunArtifact(tests).step);
    }
    return module;
}
