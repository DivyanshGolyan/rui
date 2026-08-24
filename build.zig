const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});

    const core = b.addExecutable(.{
        .name = "onepage-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    core.entry = .disabled;
    core.rdynamic = true;
    core.export_memory = true;
    core.initial_memory = 64 * 1024;
    core.max_memory = 64 * 1024;
    core.stack_size = 4 * 1024;
    b.installArtifact(core);

    const host = b.addExecutable(.{
        .name = "onepage-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    host.root_module.link_libc = true;
    b.installArtifact(host);

    const inspector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_inspect.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const checkpoint_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/checkpoint.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the deterministic spike tests");
    test_step.dependOn(&b.addRunArtifact(inspector_tests).step);
    test_step.dependOn(&b.addRunArtifact(checkpoint_tests).step);

    const run_step = b.step("run", "Run the memory-model spike");
    const run_host = b.addRunArtifact(host);
    run_host.addFileArg(core.getEmittedBin());
    run_step.dependOn(&run_host.step);
}
