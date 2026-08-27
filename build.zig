const std = @import("std");

const fixture_state_namespace = ".zig-cache/onepage-fixture-v2-";

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
    configureSqlite(b, cli);
    b.installArtifact(cli);

    const test_step = b.step("test", "Run the deterministic product and storage tests");
    addTestGraph(b, test_step, cli, native_target, optimize);

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
    addTestGraph(b, check_step, cli, native_target, .ReleaseSafe);

    const release_small_cli = addNativeExecutable(
        b,
        "onepage-release-small-check",
        "src/cli.zig",
        native_target,
        .ReleaseSmall,
    );
    check_step.dependOn(&release_small_cli.step);

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
}

fn addTestGraph(
    b: *std.Build,
    parent: *std.Build.Step,
    cli: *std.Build.Step.Compile,
    native_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const plain_test_roots = [_][]const u8{
        "src/binding.zig",
        "src/core_state.zig",
        "src/core_image.zig",
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
        "src/host_store_test.zig",
        "src/patch_tool.zig",
        "src/cli.zig",
    };
    for (libc_test_roots) |root| {
        addTestRun(b, parent, root, native_target, optimize, true);
    }

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
        "src/harness.zig",
        "src/host_runtime_lock_fixture.zig",
        "src/host_store_test.zig",
        "src/model_operation.zig",
        "src/session.zig",
    };
    for (roots) |candidate| {
        if (std.mem.eql(u8, root, candidate)) return true;
    }
    return false;
}
