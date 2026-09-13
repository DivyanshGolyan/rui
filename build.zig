const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const latifa = addLatifa(b, target, optimize, "latifa");
    b.installArtifact(latifa);
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    configureSqlite(b, tests);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit, Store, and protocol tests");
    test_step.dependOn(&run_tests.step);

    const release_safe = addLatifa(b, target, .ReleaseSafe, "latifa-release-safe-check");
    const integration = b.addSystemCommand(&.{"sh"});
    integration.addFileArg(b.path("src/admission_integration.sh"));
    integration.addArtifactArg(release_safe);
    const integration_step = b.step(
        "admission-integration",
        "Run fresh-process configuration/message admission and recovery cases",
    );
    integration_step.dependOn(&integration.step);

    const debug = addLatifa(b, target, .Debug, "latifa-debug-check");
    const debug_integration = b.addSystemCommand(&.{"sh"});
    debug_integration.addFileArg(b.path("src/admission_integration.sh"));
    debug_integration.addArtifactArg(debug);
    const debug_integration_step = b.step(
        "admission-debug-integration",
        "Run the documented Debug artifact through configuration/message recovery",
    );
    debug_integration_step.dependOn(&debug_integration.step);

    const check_step = b.step(
        "check",
        "Check formatting, tests, and configuration/message recovery",
    );
    const format = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "--ast-check",
        b.pathFromRoot("build.zig"),
        b.pathFromRoot("src"),
    });
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&integration.step);
    check_step.dependOn(&debug_integration.step);

    const release = addLatifa(b, target, .ReleaseSmall, "latifa-release-small-check");
    check_step.dependOn(&release.step);

    const measurement_tests = b.addSystemCommand(&.{
        "go", "test", "-mod=readonly", "./...",
    });
    measurement_tests.setCwd(b.path("research"));
    measurement_tests.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const measurement_test_step = b.step(
        "measurement-check",
        "Compile and test the pinned Go measurement packages",
    );
    measurement_test_step.dependOn(&measurement_tests.step);

    const cross_step = b.step(
        "cross-check",
        "Compile the supported Linux/macOS x86-64/ARM64 targets",
    );
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const executable = addLatifa(
            b,
            resolved,
            .ReleaseSmall,
            b.fmt("latifa-{s}-{s}", .{
                @tagName(resolved.result.cpu.arch),
                @tagName(resolved.result.os.tag),
            }),
        );
        cross_step.dependOn(&executable.step);
    }

    const measure = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./configuration-admission",
    });
    measure.setCwd(b.path("research"));
    measure.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure.addArtifactArg(release);
    const measure_step = b.step(
        "measure-admission",
        "Measure macOS Host and direct-client memory for configuration admission",
    );
    measure_step.dependOn(&measure.step);

    const measure_messages = b.addSystemCommand(&.{"python3"});
    measure_messages.addFileArg(b.path("research/message-admission/measure.py"));
    measure_messages.addArtifactArg(release);
    const measure_messages_step = b.step(
        "measure-message-admission",
        "Measure macOS message admission and observation scaling",
    );
    measure_messages_step.dependOn(&measure_messages.step);
}

fn addLatifa(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.link_libc = true;
    configureSqlite(b, executable);
    return executable;
}

fn configureSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const sqlite = b.dependency("sqlite", .{});
    const module = compile.root_module;
    module.link_libc = true;
    module.addIncludePath(sqlite.path("."));
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-std=c99", "-fno-strict-aliasing" },
    });
    module.addCMacro("SQLITE_THREADSAFE", "1");
    module.addCMacro("SQLITE_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_MAX_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_DEFAULT_FOREIGN_KEYS", "1");
    module.addCMacro("SQLITE_DEFAULT_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_MAX_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_DEFAULT_SYNCHRONOUS", "3");
    module.addCMacro("SQLITE_DQS", "0");
    module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    module.addCMacro("SQLITE_OMIT_SHARED_CACHE", "1");
    module.addCMacro("SQLITE_MAX_ATTACHED", "0");
    module.addCMacro("SQLITE_MAX_LENGTH", "1073741824");
    module.addCMacro("SQLITE_DEFAULT_WORKER_THREADS", "0");
    module.addCMacro("SQLITE_MAX_WORKER_THREADS", "0");
    module.addCMacro("SQLITE_TEMP_STORE", "1");
    module.addCMacro("SQLITE_USE_URI", "0");
    module.addCMacro("SQLITE_ENABLE_API_ARMOR", "1");
}
