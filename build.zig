const std = @import("std");
const persisted_format = @import("src/persisted_format.zig");

const fixture_state_namespace = std.fmt.comptimePrint(
    ".zig-cache/onepage-fixture-format-v{d}-",
    .{persisted_format.epoch},
);

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});

    const cli = b.addExecutable(.{
        .name = "onepage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    cli.root_module.link_libc = true;
    cli.root_module.linkFramework("Security", .{});
    cli.root_module.linkFramework("CoreFoundation", .{});
    configureSqlite(b, cli);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    const workflow_evaluator = addWorkflowEvaluator(
        b,
        "onepage-workflow-evaluator",
        native_target,
        optimize,
    );
    b.installArtifact(workflow_evaluator);

    const test_step = b.step("test", "Run the deterministic product and storage tests");
    addTestGraph(b, test_step, cli, workflow_evaluator, native_target, optimize);

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
    const release_safe_workflow_evaluator = addWorkflowEvaluator(
        b,
        "onepage-workflow-evaluator-release-safe-check",
        native_target,
        .ReleaseSafe,
    );
    addTestGraph(
        b,
        check_step,
        cli,
        release_safe_workflow_evaluator,
        native_target,
        .ReleaseSafe,
    );

    const release_small_cli = addNativeExecutable(
        b,
        "onepage-release-small-check",
        "src/cli.zig",
        native_target,
        .ReleaseSmall,
    );
    check_step.dependOn(&release_small_cli.step);
    const release_small_workflow_evaluator = addWorkflowEvaluator(
        b,
        "onepage-workflow-evaluator-release-small-check",
        native_target,
        .ReleaseSmall,
    );
    check_step.dependOn(&release_small_workflow_evaluator.step);

    const workflow_sanitize_step = b.step(
        "workflow-sanitize",
        "Run the focused evaluator suite with C undefined-behavior sanitization",
    );
    const workflow_sanitize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/workflow_evaluator_test.zig"),
            .target = native_target,
            .optimize = .ReleaseSafe,
            .sanitize_c = .full,
        }),
    });
    configureQuickJs(b, workflow_sanitize_tests);
    const run_workflow_sanitize = b.addRunArtifact(workflow_sanitize_tests);
    workflow_sanitize_step.dependOn(&run_workflow_sanitize.step);
    check_step.dependOn(&run_workflow_sanitize.step);

    const fixture_answer_step = b.step(
        "fixture-answer",
        "Run one durable fixture-model operation and print its Final Answer",
    );
    const run_fixture_answer = b.addRunArtifact(cli);
    run_fixture_answer.addArgs(&.{
        "--state",
        fixture_state_namespace ++ "answer-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:answer",
        "--fixture-response",
        "OnePage completed a durable model turn through one fixed Activation Slot.",
        "Explain this repository in one sentence.",
    });
    fixture_answer_step.dependOn(&run_fixture_answer.step);
    check_step.dependOn(&run_fixture_answer.step);

    const fixture_bash_step = b.step(
        "fixture-bash",
        "Run a permissioned Bash call and continue to a second-turn Final Answer",
    );
    const run_fixture_bash = b.addRunArtifact(cli);
    run_fixture_bash.addArgs(&.{
        "--state",
        fixture_state_namespace ++ "bash-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:bash",
        "--fixture-response",
        "Bash inspected the real worktree; its typed result became turn-two context.",
        "--fixture-bash-command",
        "grep -n '^# OnePage' README.md; test -f build.zig; git status --short",
        "--dangerously-bypass-permissions",
        "Inspect this repository with Bash.",
    });
    fixture_bash_step.dependOn(&run_fixture_bash.step);
    check_step.dependOn(&run_fixture_bash.step);

    const fixture_patch_step = b.step(
        "fixture-patch-deny",
        "Validate and deny one exact apply_patch call without changing the worktree",
    );
    const run_fixture_patch = b.addRunArtifact(cli);
    run_fixture_patch.addArgs(&.{
        "--state",
        fixture_state_namespace ++ "patch-sessions",
        "--repo",
        ".",
        "--model",
        "fixture:patch",
        "--fixture-response",
        "The exact patch was denied; its typed result reached turn two without changing the worktree.",
        "--fixture-patch",
        "fixtures/one-file.patch",
        "Validate this patch and request exact permission.",
    });
    run_fixture_patch.setStdIn(.{ .bytes = "n\n" });
    fixture_patch_step.dependOn(&run_fixture_patch.step);
    check_step.dependOn(&run_fixture_patch.step);

    const fixture_repair_step = b.step(
        "fixture-repair",
        "Repair a failing test through Bash, apply_patch, Bash, and a Final Answer",
    );
    const run_fixture_repair = b.addSystemCommand(&.{"sh"});
    run_fixture_repair.addFileArg(b.path("src/repair_integration.sh"));
    run_fixture_repair.addArtifactArg(cli);
    fixture_repair_step.dependOn(&run_fixture_repair.step);
    check_step.dependOn(&run_fixture_repair.step);

    const native_core_spike = addNativeExecutable(
        b,
        "onepage-native-core-spike",
        "src/native_core_spike.zig",
        native_target,
        optimize,
    );
    const run_native_core_spike = b.addRunArtifact(native_core_spike);
    const native_core_step = b.step(
        "native-core",
        "Measure and exercise the native one-page Core",
    );
    native_core_step.dependOn(&run_native_core_spike.step);

    const release_safe_native_core = addNativeExecutable(
        b,
        "onepage-native-core-check",
        "src/native_core_spike.zig",
        native_target,
        .ReleaseSafe,
    );
    check_step.dependOn(&b.addRunArtifact(release_safe_native_core).step);

    const codex_live_step = b.step(
        "codex-live-repair",
        "Run and measure the opt-in controlled repair through the live Codex subscription Provider",
    );
    const codex_memory_contract = addNativeExecutable(
        b,
        "onepage-codex-memory-contract",
        "src/codex_memory_contract.zig",
        native_target,
        optimize,
    );
    const run_codex_live = b.addSystemCommand(&.{"sh"});
    run_codex_live.addFileArg(b.path("src/codex_live_repair.sh"));
    run_codex_live.addArg(b.getInstallPath(.bin, "onepage"));
    run_codex_live.addArtifactArg(codex_memory_contract);
    run_codex_live.addArg(".zig-cache/codex-live-capacity-one.json");
    run_codex_live.step.dependOn(&install_cli.step);
    codex_live_step.dependOn(&run_codex_live.step);
    check_step.dependOn(&codex_memory_contract.step);
    const check_codex_live_script = b.addSystemCommand(&.{ "sh", "-n" });
    check_codex_live_script.addFileArg(b.path("src/codex_live_repair.sh"));
    check_step.dependOn(&check_codex_live_script.step);
}

fn addTestGraph(
    b: *std.Build,
    parent: *std.Build.Step,
    cli: *std.Build.Step.Compile,
    workflow_evaluator: *std.Build.Step.Compile,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const plain_test_roots = [_][]const u8{
        "src/binding.zig",
        "src/core_state.zig",
        "src/core_image.zig",
        "src/codex_provider.zig",
        "src/codex_harness_test.zig",
        "src/deterministic_provider.zig",
        "src/harness.zig",
        "src/session.zig",
        "src/session_transition_test.zig",
        "src/model_operation.zig",
    };
    for (plain_test_roots) |root| {
        addTestRun(b, parent, root, native_target, optimize, false);
    }

    const libc_test_roots = [_][]const u8{
        "src/bash_tool.zig",
        "src/codex_auth.zig",
        "src/codex_native.zig",
        "src/host_store_test.zig",
        "src/patch_tool.zig",
        "src/cli.zig",
    };
    for (libc_test_roots) |root| {
        addTestRun(b, parent, root, native_target, optimize, true);
    }

    const workflow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/workflow_evaluator_test.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    configureQuickJs(b, workflow_tests);
    parent.dependOn(&b.addRunArtifact(workflow_tests).step);

    const workflow_parent_fixture = addNativeExecutable(
        b,
        "onepage-workflow-evaluator-parent-fixture",
        "src/workflow_evaluator_parent_fixture.zig",
        native_target,
        optimize,
    );
    const workflow_abnormal_fixture = addNativeExecutable(
        b,
        "onepage-workflow-evaluator-abnormal-fixture",
        "src/workflow_evaluator_abnormal_fixture.zig",
        native_target,
        optimize,
    );
    const run_workflow_integration = b.addRunArtifact(workflow_parent_fixture);
    run_workflow_integration.addArtifactArg(workflow_evaluator);
    run_workflow_integration.addArtifactArg(workflow_abnormal_fixture);
    parent.dependOn(&run_workflow_integration.step);

    const agent_integration = addNativeExecutable(
        b,
        "onepage-agent-integration",
        "src/agent_integration.zig",
        native_target,
        optimize,
    );
    const run_agent_integration = b.addRunArtifact(agent_integration);
    parent.dependOn(&run_agent_integration.step);

    const cli_resume_fixture = addNativeExecutable(
        b,
        "onepage-cli-resume-fixture",
        "src/cli_resume_fixture.zig",
        native_target,
        optimize,
    );
    const run_cli_resume = b.addSystemCommand(&.{"sh"});
    run_cli_resume.addFileArg(b.path("src/cli_resume_integration.sh"));
    run_cli_resume.addArtifactArg(cli_resume_fixture);
    run_cli_resume.addArtifactArg(cli);
    parent.dependOn(&run_cli_resume.step);

    const host_lock_fixture = addNativeExecutable(
        b,
        "onepage-host-runtime-lock-fixture",
        "src/host_runtime_lock_fixture.zig",
        native_target,
        optimize,
    );
    const run_host_lock = b.addSystemCommand(&.{"sh"});
    run_host_lock.addFileArg(b.path("src/host_runtime_lock_integration.sh"));
    run_host_lock.addArtifactArg(host_lock_fixture);
    parent.dependOn(&run_host_lock.step);

    const patch_recovery_fixture = addNativeExecutable(
        b,
        "onepage-patch-recovery-fixture",
        "src/patch_recovery_fixture.zig",
        native_target,
        optimize,
    );
    const run_patch_recovery = b.addSystemCommand(&.{"sh"});
    run_patch_recovery.addFileArg(b.path("src/patch_recovery_integration.sh"));
    run_patch_recovery.addArtifactArg(patch_recovery_fixture);
    parent.dependOn(&run_patch_recovery.step);

    const patch_git_environment_fixture = addNativeExecutable(
        b,
        "onepage-patch-git-environment-fixture",
        "src/patch_git_environment_fixture.zig",
        native_target,
        optimize,
    );
    const run_patch_git_environment = b.addSystemCommand(&.{"sh"});
    run_patch_git_environment.addFileArg(b.path("src/patch_git_environment_integration.sh"));
    run_patch_git_environment.addArtifactArg(patch_git_environment_fixture);
    parent.dependOn(&run_patch_git_environment.step);

    const effect_recovery_fixture = addNativeExecutable(
        b,
        "onepage-effect-recovery-fixture",
        "src/effect_recovery_fixture.zig",
        native_target,
        optimize,
    );
    const run_effect_recovery = b.addSystemCommand(&.{"sh"});
    run_effect_recovery.addFileArg(b.path("src/effect_recovery_integration.sh"));
    run_effect_recovery.addArtifactArg(effect_recovery_fixture);
    parent.dependOn(&run_effect_recovery.step);
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
    if (std.mem.eql(u8, root, "src/codex_native.zig") or
        std.mem.eql(u8, root, "src/cli.zig"))
    {
        tests.root_module.linkFramework("Security", .{});
        tests.root_module.linkFramework("CoreFoundation", .{});
    }
    if (usesHostStore(root)) configureSqlite(b, tests);
    parent.dependOn(&b.addRunArtifact(tests).step);
}

fn configureSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const module = compile.root_module;
    const sqlite = b.dependency("sqlite", .{});
    module.link_libc = true;
    module.addIncludePath(sqlite.path("."));
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-std=c99", "-fno-strict-aliasing" },
    });
    module.addCMacro("SQLITE_THREADSAFE", "0");
    module.addCMacro("SQLITE_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_MAX_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_DEFAULT_FOREIGN_KEYS", "1");
    module.addCMacro("SQLITE_DEFAULT_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_MAX_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_DEFAULT_SYNCHRONOUS", "3");
    module.addCMacro("SQLITE_DQS", "0");
    module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    module.addCMacro("SQLITE_OMIT_SHARED_CACHE", "1");
    module.addCMacro("SQLITE_TEMP_STORE", "1");
    module.addCMacro("SQLITE_USE_URI", "0");
    module.addCMacro("SQLITE_ENABLE_API_ARMOR", "1");
}

fn configureQuickJs(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const module = compile.root_module;
    const quickjs = b.dependency("quickjs_ng", .{});
    module.link_libc = true;
    module.addIncludePath(quickjs.path("."));
    module.addIncludePath(b.path("src"));
    module.addCMacro("QUICKJS_NG_BUILD", "1");
    module.addCMacro("_GNU_SOURCE", "1");
    module.addCSourceFiles(.{
        .root = quickjs.path("."),
        .files = &.{
            "dtoa.c",
            "libregexp.c",
            "libunicode.c",
            "quickjs.c",
        },
        .flags = &.{
            "-std=gnu11",
            "-funsigned-char",
            "-fvisibility=hidden",
        },
    });
}

fn addWorkflowEvaluator(
    b: *std.Build,
    name: []const u8,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const evaluator = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/workflow_evaluator_main.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    configureQuickJs(b, evaluator);
    return evaluator;
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
    if (usesHostStore(root)) configureSqlite(b, executable);
    return executable;
}

fn usesHostStore(root: []const u8) bool {
    const roots = [_][]const u8{
        "src/agent_integration.zig",
        "src/cli.zig",
        "src/cli_resume_fixture.zig",
        "src/codex_auth.zig",
        "src/codex_native.zig",
        "src/codex_provider.zig",
        "src/codex_harness_test.zig",
        "src/deterministic_provider.zig",
        "src/effect_recovery_fixture.zig",
        "src/harness.zig",
        "src/host_runtime_lock_fixture.zig",
        "src/host_store_test.zig",
        "src/model_operation.zig",
        "src/patch_recovery_fixture.zig",
        "src/session.zig",
    };
    for (roots) |candidate| {
        if (std.mem.eql(u8, root, candidate)) return true;
    }
    return false;
}
