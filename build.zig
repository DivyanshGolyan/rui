const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pinned_transport = addPinnedTransport(b, target);

    const latifa = addLatifa(b, target, optimize, "latifa", pinned_transport);
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
    configureTransport(b, tests, target, pinned_transport);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit, Store, and protocol tests");
    test_step.dependOn(&run_tests.step);

    const release_safe = addLatifa(b, target, .ReleaseSafe, "latifa-release-safe-check", pinned_transport);
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

    const control_integration = b.addSystemCommand(&.{"python3"});
    control_integration.addFileArg(b.path("tests/integration/control_integration.py"));
    control_integration.addArtifactArg(release_safe);
    const control_integration_step = b.step(
        "control-integration",
        "Run Session-stop, exact-interruption, and protected-capacity cases",
    );
    control_integration_step.dependOn(&control_integration.step);

    const debug = addLatifa(b, target, .Debug, "latifa-debug-check", pinned_transport);
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
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&integration.step);
    check_step.dependOn(&dispatch_integration.step);
    check_step.dependOn(&control_integration.step);
    check_step.dependOn(&debug_integration.step);

    const host_process_test = b.addSystemCommand(&.{"python3"});
    host_process_test.addFileArg(b.path("tests/integration/host_process_test.py"));
    check_step.dependOn(&host_process_test.step);

    const release = addLatifa(b, target, .ReleaseSmall, "latifa-release-small-check", pinned_transport);
    check_step.dependOn(&release.step);

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
        const cross_transport = if (sameTransportTarget(target, resolved))
            pinned_transport
        else
            addPinnedTransport(b, resolved);
        const executable = addLatifa(
            b,
            resolved,
            .ReleaseSmall,
            b.fmt("latifa-{s}-{s}", .{
                @tagName(resolved.result.cpu.arch),
                @tagName(resolved.result.os.tag),
            }),
            cross_transport,
        );
        cross_step.dependOn(&executable.step);
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
}

fn sameTransportTarget(a: std.Build.ResolvedTarget, b: std.Build.ResolvedTarget) bool {
    return a.result.cpu.arch == b.result.cpu.arch and
        a.result.os.tag == b.result.os.tag and
        a.result.abi == b.result.abi;
}

fn addLatifa(
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
