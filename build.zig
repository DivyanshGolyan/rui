const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pinned_transport = addPinnedTransport(b, target);

    const rui = addRui(b, target, optimize, "rui", pinned_transport);
    b.installArtifact(rui);
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const model_queue_output = b.option([]const u8, "model-queue-output", "Write model-queue qualification JSON to this path");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    configureSqlite(b, tests);
    configureBashPlatform(b, tests);
    configureTransport(b, tests, target, pinned_transport);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit, Store, and protocol tests");
    test_step.dependOn(&run_tests.step);

    const release_safe = addRui(b, target, .ReleaseSafe, "rui-release-safe-check", pinned_transport);
    const integration = b.addSystemCommand(&.{"sh"});
    integration.addFileArg(b.path("tests/integration/admission_integration.sh"));
    integration.addArtifactArg(release_safe);
    const integration_step = b.step(
        "admission-integration",
        "Run fresh-process configuration/message admission and recovery cases",
    );
    integration_step.dependOn(&integration.step);

    const dispatch_integration = b.addSystemCommand(&.{"python3"});
    dispatch_integration.addFileArg(b.path("tests/integration/dispatch_integration.py"));
    dispatch_integration.addArtifactArg(release_safe);
    const dispatch_integration_step = b.step(
        "dispatch-integration",
        "Run the targeted model dispatch, output, retry, and recovery shortcut",
    );
    dispatch_integration_step.dependOn(&dispatch_integration.step);

    const bash_integration = b.addSystemCommand(&.{"python3"});
    bash_integration.addFileArg(b.path("tests/integration/bash_integration.py"));
    bash_integration.addArtifactArg(release_safe);
    const bash_integration_step = b.step(
        "bash-integration",
        "Run authorized Bash execution, stop, failure, and recovery cases",
    );
    bash_integration_step.dependOn(&bash_integration.step);

    const bash_lifecycle_integration = b.addSystemCommand(&.{"python3"});
    bash_lifecycle_integration.addFileArg(b.path("tests/integration/bash_lifecycle_integration.py"));
    bash_lifecycle_integration.addArtifactArg(release_safe);
    const bash_lifecycle_integration_step = b.step(
        "bash-lifecycle-integration",
        "Run Bash lifecycle syscall-failure and custody cases",
    );
    bash_lifecycle_integration_step.dependOn(&bash_lifecycle_integration.step);

    const control_integration = b.addSystemCommand(&.{"python3"});
    control_integration.addFileArg(b.path("tests/integration/control_integration.py"));
    control_integration.addArtifactArg(release_safe);
    const control_integration_step = b.step(
        "control-integration",
        "Run Session-stop, exact-interruption, and protected-capacity cases",
    );
    control_integration_step.dependOn(&control_integration.step);

    const debug = addRui(b, target, .Debug, "rui-debug-check", pinned_transport);
    const debug_integration = b.addSystemCommand(&.{"sh"});
    debug_integration.addFileArg(b.path("tests/integration/admission_integration.sh"));
    debug_integration.addArtifactArg(debug);
    const debug_integration_step = b.step(
        "admission-debug-integration",
        "Run the documented Debug artifact through configuration/message recovery",
    );
    debug_integration_step.dependOn(&debug_integration.step);

    const check_step = b.step(
        "check",
        "Run the canonical formatting, test, integration, and production-build gates",
    );
    const format = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "--ast-check",
        b.pathFromRoot("build.zig"),
        b.pathFromRoot("src"),
    });
    const release = addRui(b, target, .ReleaseSmall, "rui-release-small-check", pinned_transport);
    const process_integrations = b.addSystemCommand(&.{"sh"});
    process_integrations.addFileArg(b.path("tests/integration/check.sh"));
    process_integrations.addArtifactArg(release_safe);
    process_integrations.addArtifactArg(debug);
    process_integrations.step.dependOn(&format.step);
    process_integrations.step.dependOn(&run_tests.step);
    process_integrations.step.dependOn(&release.step);
    check_step.dependOn(&process_integrations.step);

    const measurement_tests = b.addSystemCommand(&.{
        "go", "test", "-mod=readonly", "./...",
    });
    measurement_tests.setCwd(b.path("tests/qualification"));
    measurement_tests.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const measurement_test_step = b.step(
        "measurement-check",
        "Compile and test the pinned Go measurement packages",
    );
    measurement_test_step.dependOn(&measurement_tests.step);

    const queue_audit_test = b.addSystemCommand(&.{
        "go", "test", "-mod=readonly", "-run", "^TestExecutionAuditQueryRejectsHiddenEntities$", "./model-queue", "-args", "-sqlite",
    });
    queue_audit_test.setCwd(b.path("tests/qualification"));
    queue_audit_test.setEnvironmentVariable("GOTOOLCHAIN", "local");
    queue_audit_test.addArtifactArg(addSqliteShell(b, target, .ReleaseSmall));
    measurement_test_step.dependOn(&queue_audit_test.step);

    const linux_cross_step = b.step(
        "cross-check-linux",
        "Compile the supported Linux x86-64/ARM64 targets",
    );
    const macos_cross_step = b.step(
        "cross-check-macos",
        "Compile the supported macOS x86-64/ARM64 targets (requires Xcode/Command Line Tools)",
    );
    const cross_step = b.step(
        "cross-check",
        "Compile the supported Linux/macOS x86-64/ARM64 targets",
    );
    cross_step.dependOn(linux_cross_step);
    cross_step.dependOn(macos_cross_step);
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const cross_transport = if (sameTransportTarget(target, resolved))
            pinned_transport
        else
            addPinnedTransport(b, resolved);
        const executable = addRui(
            b,
            resolved,
            .ReleaseSmall,
            b.fmt("rui-{s}-{s}", .{
                @tagName(resolved.result.cpu.arch),
                @tagName(resolved.result.os.tag),
            }),
            cross_transport,
        );
        switch (resolved.result.os.tag) {
            .linux => linux_cross_step.dependOn(&executable.step),
            .macos => macos_cross_step.dependOn(&executable.step),
            else => unreachable,
        }
    }

    const measure = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./configuration-admission",
    });
    measure.setCwd(b.path("tests/qualification"));
    measure.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure.addArtifactArg(release);
    const measure_step = b.step(
        "measure-admission",
        "Measure macOS Host and direct-client memory for configuration admission",
    );
    measure_step.dependOn(&measure.step);

    const measure_messages = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./message-admission",
    });
    measure_messages.setCwd(b.path("tests/qualification"));
    measure_messages.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure_messages.addArtifactArg(release);
    const measure_messages_step = b.step(
        "measure-message-admission",
        "Measure macOS message admission and observation scaling",
    );
    measure_messages_step.dependOn(&measure_messages.step);

    const measure_dispatch = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./model-dispatch",
    });
    measure_dispatch.setCwd(b.path("tests/qualification"));
    measure_dispatch.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure_dispatch.addArtifactArg(release);
    const measure_dispatch_step = b.step(
        "measure-model-dispatch",
        "Measure macOS frozen-request transport, scratch, descriptors, and custody",
    );
    measure_dispatch_step.dependOn(&measure_dispatch.step);

    const measure_output = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./model-output",
    });
    measure_output.setCwd(b.path("tests/qualification"));
    measure_output.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure_output.addArtifactArg(release);
    const measure_output_step = b.step(
        "measure-model-output",
        "Measure macOS model-output bytes, item counts, storage, and retained memory",
    );
    measure_output_step.dependOn(&measure_output.step);

    const measure_retry = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./model-retry",
    });
    measure_retry.setCwd(b.path("tests/qualification"));
    measure_retry.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure_retry.addArtifactArg(release);
    const measure_retry_step = b.step(
        "measure-model-retry",
        "Measure macOS retry discovery, launch separation, churn, and custody",
    );
    measure_retry_step.dependOn(&measure_retry.step);

    const measure_queue = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./model-queue",
    });
    measure_queue.setCwd(b.path("tests/qualification"));
    measure_queue.setEnvironmentVariable("GOTOOLCHAIN", "local");
    if (model_queue_output) |output| {
        measure_queue.addArgs(&.{ "-output", output });
    }
    measure_queue.addArtifactArg(release);
    measure_queue.addArtifactArg(addSqliteShell(b, target, .ReleaseSmall));
    const measure_queue_step = b.step(
        "measure-model-queue",
        "Measure model queue discovery, ordering, settlement, and portable mixed resources",
    );
    measure_queue_step.dependOn(&measure_queue.step);

    const measure_control = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./model-control",
    });
    measure_control.setCwd(b.path("tests/qualification"));
    measure_control.setEnvironmentVariable("GOTOOLCHAIN", "local");
    measure_control.addArtifactArg(release);
    const measure_control_step = b.step(
        "measure-model-control",
        "Measure control headroom, acknowledgment latency, and cleanup resources",
    );
    measure_control_step.dependOn(&measure_control.step);

    const measure_call_classification = b.addSystemCommand(&.{
        "go", "run", "-mod=readonly", "./call-classification",
    });
    measure_call_classification.setCwd(b.path("tests/qualification"));
    measure_call_classification.setEnvironmentVariable("GOTOOLCHAIN", "local");
    if (b.args) |args| measure_call_classification.addArgs(args);
    measure_call_classification.addArtifactArg(release);
    measure_call_classification.addArtifactArg(addSqliteShell(b, target, .ReleaseSmall));
    const measure_call_classification_step = b.step(
        "measure-call-classification",
        "Measure production call classification, exact denial, recovery, and population scaling",
    );
    measure_call_classification_step.dependOn(&measure_call_classification.step);
}

fn sameTransportTarget(a: std.Build.ResolvedTarget, b: std.Build.ResolvedTarget) bool {
    return a.result.cpu.arch == b.result.cpu.arch and
        a.result.os.tag == b.result.os.tag and
        a.result.abi == b.result.abi;
}

fn addRui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    pinned_transport: PinnedTransport,
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
    configureBashPlatform(b, executable);
    configureTransport(b, executable, target, pinned_transport);
    return executable;
}

const PinnedTransport = struct {
    output: std.Build.LazyPath,
};

fn addPinnedTransport(b: *std.Build, target: std.Build.ResolvedTarget) PinnedTransport {
    const openssl = b.dependency("openssl", .{});
    const curl = b.dependency("curl", .{});
    const build_transport = b.addSystemCommand(&.{"sh"});
    build_transport.addFileArg(b.path("src/build_transport.sh"));
    build_transport.addDirectoryArg(openssl.path("."));
    build_transport.addDirectoryArg(curl.path("."));
    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    const output = build_transport.addOutputDirectoryArg(b.fmt("pinned-transport-{s}", .{target_name}));
    build_transport.addArg(target_name);
    build_transport.addArg(b.graph.zig_exe);
    return .{ .output = output };
}

fn configureTransport(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    pinned: PinnedTransport,
) void {
    const enabled = (target.result.os.tag == .macos or target.result.os.tag == .linux) and
        (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .x86_64);
    const options = b.addOptions();
    options.addOption(bool, "enabled", enabled);
    compile.root_module.addOptions("transport_options", options);
    compile.root_module.addIncludePath(if (enabled)
        pinned.output.path(b, "include")
    else
        b.dependency("curl", .{}).path("include"));
    if (!enabled) return;
    compile.root_module.addObjectFile(pinned.output.path(b, "lib/libcurl.a"));
    compile.root_module.addObjectFile(pinned.output.path(b, "lib/libssl.a"));
    compile.root_module.addObjectFile(pinned.output.path(b, "lib/libcrypto.a"));
    if (target.result.os.tag == .macos) {
        // The selected transport build discovers the active CLT/Xcode SDK and
        // exposes these paths lazily. Constructing dormant macOS cross steps
        // therefore requires no Apple tooling on a Linux build host.
        compile.root_module.addSystemFrameworkPath(pinned.output.path(b, "sdk/System/Library/Frameworks"));
        compile.root_module.addSystemIncludePath(pinned.output.path(b, "sdk/usr/include"));
        compile.root_module.addLibraryPath(pinned.output.path(b, "sdk/usr/lib"));
        compile.root_module.linkFramework("Security", .{});
        compile.root_module.linkFramework("CoreFoundation", .{});
        compile.root_module.linkFramework("CoreServices", .{});
        compile.root_module.linkFramework("SystemConfiguration", .{});
    } else {
        compile.root_module.linkSystemLibrary("pthread", .{});
        compile.root_module.linkSystemLibrary("dl", .{});
    }
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

fn configureBashPlatform(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/bash_platform.c"),
        .flags = &.{"-std=c11"},
    });
}

fn addSqliteShell(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const sqlite = b.dependency("sqlite", .{});
    const executable = b.addExecutable(.{
        .name = "rui-qualification-sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    configureSqlite(b, executable);
    executable.root_module.addCSourceFile(.{
        .file = sqlite.path("shell.c"),
        .flags = &.{"-std=gnu99"},
    });
    return executable;
}
