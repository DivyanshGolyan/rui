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
    const checkpoint_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/checkpoint_store.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const operation_log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/operation_log.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const core_contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_contract.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const core_contract_check = b.addExecutable(.{
        .name = "onepage-core-contract-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_contract_check.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    core_contract_check.root_module.link_libc = true;
    const run_core_contract_check = b.addRunArtifact(core_contract_check);
    run_core_contract_check.addFileArg(core.getEmittedBin());
    const harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/harness.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const durable_transition_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/durable_transition.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the deterministic spike tests");
    test_step.dependOn(&b.addRunArtifact(inspector_tests).step);
    test_step.dependOn(&b.addRunArtifact(checkpoint_tests).step);
    test_step.dependOn(&b.addRunArtifact(checkpoint_store_tests).step);
    test_step.dependOn(&b.addRunArtifact(operation_log_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_contract_tests).step);
    test_step.dependOn(&run_core_contract_check.step);
    test_step.dependOn(&b.addRunArtifact(harness_tests).step);
    test_step.dependOn(&b.addRunArtifact(durable_transition_tests).step);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);

    const run_step = b.step("run", "Run the memory-model spike");
    const run_host = b.addRunArtifact(host);
    run_host.addFileArg(core.getEmittedBin());
    run_step.dependOn(&run_host.step);

    const lifecycle_step = b.step("lifecycle", "Run the durable operation lifecycle spike");
    const prepare_lifecycle = b.addRunArtifact(host);
    prepare_lifecycle.addFileArg(core.getEmittedBin());
    prepare_lifecycle.addArg("lifecycle-prepare");
    const complete_lifecycle = b.addRunArtifact(host);
    complete_lifecycle.addFileArg(core.getEmittedBin());
    complete_lifecycle.addArg("lifecycle-complete");
    complete_lifecycle.step.dependOn(&prepare_lifecycle.step);
    const recover_lifecycle = b.addRunArtifact(host);
    recover_lifecycle.addFileArg(core.getEmittedBin());
    recover_lifecycle.addArg("lifecycle-recover");
    recover_lifecycle.step.dependOn(&complete_lifecycle.step);
    const replay_lifecycle = b.addRunArtifact(host);
    replay_lifecycle.addFileArg(core.getEmittedBin());
    replay_lifecycle.addArg("lifecycle-recover");
    replay_lifecycle.step.dependOn(&recover_lifecycle.step);
    lifecycle_step.dependOn(&replay_lifecycle.step);

    const owner_crash_step = b.step(
        "owner-crash",
        "Crash after completion sync and recover through the fixed-credit owner",
    );
    const run_owner_crash = b.addRunArtifact(host);
    run_owner_crash.addFileArg(core.getEmittedBin());
    run_owner_crash.addArg("owner-crash-suite");
    owner_crash_step.dependOn(&run_owner_crash.step);

    const checkpoint_crash_step = b.step(
        "checkpoint-crash",
        "Crash at every atomic checkpoint publication boundary",
    );
    const run_checkpoint_crash = b.addRunArtifact(host);
    run_checkpoint_crash.addFileArg(core.getEmittedBin());
    run_checkpoint_crash.addArg("checkpoint-crash-suite");
    checkpoint_crash_step.dependOn(&run_checkpoint_crash.step);
}
