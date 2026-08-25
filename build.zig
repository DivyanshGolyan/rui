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
            .optimize = .ReleaseSmall,
        }),
    });
    core.entry = .disabled;
    core.rdynamic = true;
    core.export_memory = true;
    core.initial_memory = 64 * 1024;
    core.max_memory = 64 * 1024;
    core.stack_size = 4 * 1024;
    const cli = b.addExecutable(.{
        .name = "onepage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    cli.root_module.link_libc = true;
    b.installArtifact(cli);

    const test_step = b.step("test", "Run the deterministic spike tests");
    addTestGraph(b, test_step, core, native_target, optimize);

    const check_step = b.step(
        "check",
        "Check formatting and run ReleaseSafe tests against ReleaseSmall artifacts",
    );
    const format_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "--ast-check",
        b.pathFromRoot("build.zig"),
        b.pathFromRoot("src"),
    });
    check_step.dependOn(&format_check.step);
    addTestGraph(b, check_step, core, native_target, .ReleaseSafe);

    const release_small_cli = addNativeExecutable(
        b,
        "onepage-release-small-check",
        "src/cli.zig",
        native_target,
        .ReleaseSmall,
    );
    check_step.dependOn(&core.step);
    check_step.dependOn(&release_small_cli.step);

    const fixture_answer_step = b.step(
        "fixture-answer",
        "Run one durable fixture-model operation and print its Final Answer",
    );
    const run_fixture_answer = b.addRunArtifact(cli);
    run_fixture_answer.addArgs(&.{
        "--state",
        ".zig-cache/onepage-fixture-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:answer",
        "--fixture-response",
        "OnePage completed a durable model turn through one fixed Activation Slot.",
        "Explain this repository in one sentence.",
    });
    fixture_answer_step.dependOn(&run_fixture_answer.step);

    const fixture_bash_step = b.step(
        "fixture-bash",
        "Run a permissioned Bash call and continue to a second-turn Final Answer",
    );
    const run_fixture_bash = b.addRunArtifact(cli);
    run_fixture_bash.addArgs(&.{
        "--state",
        ".zig-cache/onepage-bash-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:bash",
        "--fixture-response",
        "Bash inspected the real worktree; its typed result became turn-two context.",
        "--fixture-bash-command",
        "grep -n '^# OnePage' README.md; test -f build.zig; git status --short",
        "--allow-bash",
        "Inspect this repository with Bash.",
    });
    fixture_bash_step.dependOn(&run_fixture_bash.step);

    const fixture_patch_step = b.step(
        "fixture-patch-deny",
        "Validate and deny one exact apply_patch call without changing the worktree",
    );
    const run_fixture_patch = b.addRunArtifact(cli);
    run_fixture_patch.addArgs(&.{
        "--state",
        ".zig-cache/onepage-patch-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:patch",
        "--fixture-response",
        "The exact patch was denied; its typed result reached turn two without changing the worktree.",
        "--fixture-patch",
        "fixtures/one-file.patch",
        "--deny-patch",
        "Validate this patch and request exact permission.",
    });
    fixture_patch_step.dependOn(&run_fixture_patch.step);

    const native_core_spike = b.addExecutable(.{
        .name = "onepage-native-core-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_core_spike.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    native_core_spike.root_module.link_libc = true;
    const run_native_core_spike = b.addRunArtifact(native_core_spike);
    run_native_core_spike.addFileArg(core.getEmittedBin());
    const native_core_step = b.step(
        "native-core",
        "Measure the native one-page Core and check it against the Wasm build",
    );
    native_core_step.dependOn(&run_native_core_spike.step);
    check_step.dependOn(&run_native_core_spike.step);
}

fn addTestGraph(
    b: *std.Build,
    parent: *std.Build.Step,
    core: *std.Build.Step.Compile,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const plain_test_roots = [_][]const u8{
        "src/core_state.zig",
        "src/wasm_inspect.zig",
        "src/checkpoint.zig",
        "src/core_image.zig",
        "src/checkpoint_store.zig",
        "src/operation_log.zig",
        "src/core_contract.zig",
        "src/harness.zig",
        "src/durable_transition.zig",
        "src/session.zig",
        "src/model_operation.zig",
    };
    for (plain_test_roots) |root| {
        addTestRun(b, parent, root, native_target, optimize, false);
    }

    const libc_test_roots = [_][]const u8{
        "src/bash_tool.zig",
        "src/patch_tool.zig",
        "src/cli.zig",
    };
    for (libc_test_roots) |root| {
        addTestRun(b, parent, root, native_target, optimize, true);
    }

    const core_contract_check = addNativeExecutable(
        b,
        "onepage-core-contract-check",
        "src/core_contract_check.zig",
        native_target,
        optimize,
    );
    const run_core_contract_check = b.addRunArtifact(core_contract_check);
    run_core_contract_check.addFileArg(core.getEmittedBin());
    parent.dependOn(&run_core_contract_check.step);

    const agent_integration = addNativeExecutable(
        b,
        "onepage-agent-integration",
        "src/agent_integration.zig",
        native_target,
        optimize,
    );
    const run_agent_integration = b.addRunArtifact(agent_integration);
    run_agent_integration.addFileArg(core.getEmittedBin());
    parent.dependOn(&run_agent_integration.step);
}

fn addTestRun(
    b: *std.Build,
    parent: *std.Build.Step,
    root: []const u8,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_libc: bool,
) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    tests.root_module.link_libc = link_libc;
    parent.dependOn(&b.addRunArtifact(tests).step);
}

fn addNativeExecutable(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    executable.root_module.link_libc = true;
    return executable;
}
