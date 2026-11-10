const std = @import("std");
const product = @import("build/product.zig");
const ci_module = @import("build/ci.zig");
const screen_module = @import("build/screen.zig");
const unit_module = @import("build/unit.zig");
const measurement_module = @import("build/measurement.zig");
const cross_module = @import("build/cross.zig");

pub fn build(b: *std.Build) void {
    // PR fixtures need ReleaseSafe checks, not shipped LLVM code generation.
    // Qualification/release and ordinary local builds keep the production backend.
    const pr_ci = b.option(bool, "pr-ci", "Use the Linux x86_64 PR-only integration artifact") orelse false;
    const ci_targets = b.option([]const u8, "ci-targets", "Comma-separated CI targets to compile");
    const ci_part = b.option(ci_module.CiPart, "ci-part", "Which selected CI compiles this producer emits") orelse .all;
    const ci: ci_module.CiArtifacts = .{ .b = b, .directory = b.option([]const u8, "ci-artifacts", "Verified native CI executables") };
    // Hosted workers can have different CPUs. Transfer only the platform's
    // baseline instruction set; ordinary local builds still target their host.
    const ci_mode = ci_targets != null or ci.directory != null;
    const ci_query: std.Target.Query = .{ .cpu_model = .baseline };
    const target = b.standardTargetOptions(.{ .default_target = if (ci_mode) ci_query else .{} });
    const optimize = b.standardOptimizeOption(.{});
    if (pr_ci and (target.result.cpu.arch != .x86_64 or target.result.os.tag != .linux))
        @panic("The fast PR artifact is qualified only for x86_64 Linux");
    if (ci_mode and (!target.query.eql(ci_query) or optimize != .debug))
        @panic("CI artifacts require the native platform, baseline CPU and default optimization");
    const ci_cpu = std.json.Stringify.valueAlloc(b.allocator, .{
        .policy = "baseline",
        .arch = @tagName(target.result.cpu.arch),
        .model = target.result.cpu.model.name,
        .features = std.fmt.bytesToHex(target.result.cpu.features.asBytes().*, .lower),
    }, .{}) catch @panic("OOM");
    if (ci.directory) |directory| {
        const manifest_path = b.pathJoin(&.{ directory, "ci-cpu.json" });
        b.dependOnFileContents(.{ .cwd_relative = manifest_path });
        const recorded = std.Io.Dir.cwd().readFileAlloc(b.graph.io, manifest_path, b.allocator, .limited(4096)) catch
            @panic("Missing CI CPU identity");
        if (!std.mem.eql(u8, recorded, ci_cpu)) @panic("CI CPU identity mismatch");
    }
    const pinned_transport = product.addPinnedTransport(b, target);

    const rui = product.addRui(b, target, optimize, "rui", pinned_transport);
    b.installArtifact(rui);
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    const test_filters = b.option([]const []const u8, "test-filter", "Run tests whose names contain this text (repeatable)") orelse &.{};
    if (ci.directory != null and test_filters.len != 0) @panic("CI artifacts contain unfiltered tests");
    const model_queue_output = b.option([]const u8, "model-queue-output", "Write model-queue qualification JSON to this path");
    const units = unit_module.add(b, ci, target, pinned_transport, test_filters);

    const openapi_emitter = b.addExecutable(.{
        .name = "openapi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openapi_main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const emit_openapi = b.addRunArtifact(openapi_emitter);
    const update_openapi = b.addUpdateSourceFiles();
    update_openapi.addCopyFileToSource(emit_openapi.addOutputFileArg("openapi.json"), "openapi.json");
    b.step("openapi", "Write openapi.json from the wire types; a unit test fails while it is stale").dependOn(&update_openapi.step);

    const catalog_emitter = b.addExecutable(.{
        .name = "model-catalog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model_catalog_main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const emit_catalog = b.addRunArtifact(catalog_emitter);
    const snapshot = emit_catalog.addOutputFileArg("model_catalog_snapshot.zig");
    // Passthrough arguments disable caching: reread even an unchanged path.
    emit_catalog.addPassthruArgs();
    const update_catalog = b.addUpdateSourceFiles();
    update_catalog.addCopyFileToSource(snapshot, "src/model_catalog_snapshot.zig");
    b.step("model-catalog", "Write the shipped catalog from a models.dev api.json snapshot").dependOn(&update_catalog.step);

    const h2_test_step = b.step("test-h2", "Run the HTTP/2 client's own tests");
    const pg_test_step = b.step("test-pg", "Run the Postgres wire client's tests (live ones against RUI_TEST_PG_PORT)");
    if (product.addTlsClient(b, target, .ReleaseSafe, pinned_transport)) |tls_client| {
        const h2 = product.addH2(b, target, .ReleaseSafe, pinned_transport, product.addTestPoll(b), tls_client);
        const h2_tests = b.addTest(.{ .root_module = h2, .filters = test_filters });
        const run_h2_tests = ci.run(h2_tests);
        run_h2_tests.has_side_effects = true;
        h2_test_step.dependOn(&run_h2_tests.step);
        const pg_tests = b.addTest(.{ .root_module = product.addPg(b, target, .ReleaseSafe, tls_client), .filters = test_filters });
        const run_pg_tests = ci.run(pg_tests);
        run_pg_tests.has_side_effects = true;
        pg_test_step.dependOn(&run_pg_tests.step);
    }

    // Test actors are never shipped and run briefly. On x86_64, Zig's own
    // backend builds each in about a second, where LLVM pays a ~28 CPU-second
    // ReleaseSafe floor; safety checks stay on. Its aarch64-macos build of these
    // actors exhausts memory, so Apple Silicon keeps LLVM. Product binaries and
    // codegen witnesses such as the signal-stack probe always use LLVM.
    const test_actor_llvm: ?bool = if (target.result.cpu.arch == .x86_64) false else null;
    const terminal_notice = b.addExecutable(.{
        .name = "rui-terminal-notice-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_notice_test.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    product.configureTerminalEditor(b, terminal_notice);

    const production_safe = product.addRui(b, target, .ReleaseSafe, "rui-release-safe-check", pinned_transport);
    const release_safe = if (pr_ci) product.addRui(b, target, .ReleaseSafe, "rui-pr-check", pinned_transport) else production_safe;
    if (pr_ci) release_safe.use_llvm = false;
    // The PTY screen observer (tests/integration/terminal_screen.py) loads
    // libghostty-vt through ctypes. Its test-only package in screen-emulator
    // keeps it out of this manifest, which installs fetch whole; only steps
    // that run the observer build it, and no product artifact links it.
    const screen_emulator = screen_module.addScreenEmulator(b, ci, ci_mode);
    const screen = screen_emulator.library;
    const screen_emulator_step = b.step("screen-emulator", "Install the PTY screen observer's libghostty-vt, for harnesses outside build steps");
    screen_emulator_step.dependOn(&b.addInstallLibFile(screen_emulator.library, screen_emulator.name).step);
    const terminal_restoration = screen_module.screenCommand(b, screen, &.{});
    terminal_restoration.addPrefixedFileArg("RUI_TEST_TERMINAL_NOTICE=", ci.path(terminal_notice));
    terminal_restoration.addArg("python3");
    terminal_restoration.addFileArg(b.path("tests/integration/terminal_restoration_integration.py"));
    terminal_restoration.addFileArg(ci.path(release_safe));
    terminal_restoration.addPassthruArgs();
    const terminal_restoration_step = b.step("terminal-restoration-integration", "Run native terminal restoration with build-owned bindings");
    terminal_restoration_step.dependOn(&terminal_restoration.step);

    // Nonblocking renderer contracts. No gate root imports these sources, and
    // check, check-full, test and test-logic never depend on these steps.
    // Each Python harness requires a fresh evidence directory: -- --output DIR.
    const sequence_model = b.addSystemCommand(&.{"python3"});
    sequence_model.addFileArg(b.path("tests/integration/session_sequence_model.py"));
    sequence_model.addPassthruArgs();
    sequence_model.has_side_effects = true;
    b.step(
        "sequence-model",
        "Run TD1 sequence models through overlaid private frontend transitions (nonblocking)",
    ).dependOn(&sequence_model.step);
    const renderer_selftests = b.step(
        "renderer-contracts-selftest",
        "Run the direct-PTY, sequence-model and mutation harness self-tests (nonblocking)",
    );
    for ([_][]const u8{
        "tests/qualification/direct-pty/test_driver.py",
        "tests/integration/session_sequence_model_test.py",
        "tests/ci/renderer_mutation_test.py",
    }) |path| {
        const selftest = screen_module.screenCommand(b, screen, &.{ "python3", "-B" });
        selftest.addFileArg(b.path(path));
        selftest.has_side_effects = true;
        renderer_selftests.dependOn(&selftest.step);
    }
    b.step(
        "direct-pty",
        "Run the synthetic direct-PTY key matrix (nonblocking)",
    ).dependOn(&screen_module.addPtyHarness(b, screen, "tests/qualification/direct-pty/matrix.py", ci.path(release_safe)).step);
    b.step(
        "direct-pty-controls",
        "Run direct-PTY driver and disposal controls (nonblocking)",
    ).dependOn(&screen_module.addPtyHarness(b, screen, "tests/qualification/direct-pty/controls.py", ci.path(release_safe)).step);
    b.step(
        "input-equivalence",
        "Run TD2 original-recovery encodings through the direct-PTY matrix (nonblocking)",
    ).dependOn(&screen_module.addPtyHarness(b, screen, "tests/integration/input_equivalence.py", ci.path(release_safe)).step);

    const session_list_client = b.addExecutable(.{
        .name = "rui-session-list-client-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/session_list_client.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    session_list_client.root_module.link_libc = true;
    const read_client = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    product.configurePosix(b, read_client);
    session_list_client.root_module.addImport("rui_client", read_client);
    const session_list_integration = b.addSystemCommand(&.{"python3"});
    session_list_integration.addFileArg(b.path("tests/integration/session_list_integration.py"));
    session_list_integration.addFileArg(ci.path(release_safe));
    session_list_integration.addFileArg(ci.path(session_list_client));
    b.step("session-list-integration", "Run native Session listing and idle Host resource checks").dependOn(&session_list_integration.step);
    const activity_client = b.addExecutable(.{
        .name = "rui-activity-client-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/activity_client.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    activity_client.root_module.link_libc = true;
    activity_client.root_module.addImport("rui_client", read_client);
    const activity_integration = b.addSystemCommand(&.{"python3"});
    activity_integration.addFileArg(b.path("tests/integration/activity_integration.py"));
    activity_integration.addFileArg(ci.path(release_safe));
    activity_integration.addFileArg(ci.path(activity_client));
    b.step("activity-integration", "Run complete Session activity reads and typed Client consumption").dependOn(&activity_integration.step);
    const integration = b.addSystemCommand(&.{"sh"});
    integration.addFileArg(b.path("tests/integration/admission_integration.sh"));
    integration.addFileArg(ci.path(release_safe));
    const integration_step = b.step(
        "admission-integration",
        "Run fresh-process configuration/message admission and recovery cases",
    );
    integration_step.dependOn(&integration.step);

    const dispatch_integration = b.addSystemCommand(&.{"python3"});
    dispatch_integration.addFileArg(b.path("tests/integration/dispatch_integration.py"));
    dispatch_integration.addFileArg(ci.path(release_safe));
    const dispatch_integration_step = b.step(
        "dispatch-integration",
        "Run the targeted model dispatch, output, retry, and recovery shortcut",
    );
    dispatch_integration_step.dependOn(&dispatch_integration.step);

    const skills_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    skills_integration.addFileArg(b.path("tests/integration/skills_integration.py"));
    skills_integration.addFileArg(ci.path(release_safe));
    b.step("skills-integration", "Run isolated native skills capture, replay and creation cases").dependOn(&skills_integration.step);

    const login_signal_integration = b.addSystemCommand(&.{"python3"});
    login_signal_integration.addFileArg(b.path("tests/integration/login_signal_integration.py"));
    login_signal_integration.addFileArg(ci.path(release_safe));
    b.step("login-signal-integration", "Run the Linux-only one-shot login signal loader witness").dependOn(&login_signal_integration.step);

    const current_facts_integration = b.addSystemCommand(&.{"python3"});
    current_facts_integration.addFileArg(b.path("tests/integration/current_facts_integration.py"));
    current_facts_integration.addFileArg(ci.path(release_safe));
    b.step("current-facts-integration", "Run the real Current producer/consumer observation oracle").dependOn(&current_facts_integration.step);

    const request_wait_integration = b.addSystemCommand(&.{"python3"});
    request_wait_integration.addFileArg(b.path("tests/integration/request_wait_integration.py"));
    request_wait_integration.addFileArg(ci.path(release_safe));
    b.step("request-wait-integration", "Run request wait completion, recovery and conditional polling witnesses").dependOn(&request_wait_integration.step);

    const canonical_failure_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    canonical_failure_integration.addFileArg(b.path("tests/integration/canonical_failure_integration.py"));
    canonical_failure_integration.addFileArg(ci.path(release_safe));
    b.step("canonical-failure-integration", "Run canonical invocation failure at real producer and caller boundaries").dependOn(&canonical_failure_integration.step);

    const server_delivery_integration = b.addSystemCommand(&.{"python3"});
    server_delivery_integration.addFileArg(b.path("tests/integration/server_delivery_integration.py"));
    server_delivery_integration.addFileArg(ci.path(release_safe));
    b.step("server-delivery-integration", "Run real reply inactivity, connection headroom and Host drain separately from load").dependOn(&server_delivery_integration.step);

    const h2_integration = b.addSystemCommand(&.{"python3"});
    h2_integration.addFileArg(b.path("tests/integration/transport_h2_integration.py"));
    h2_integration.addFileArg(ci.path(release_safe));
    const h2_oracle_tests = b.addSystemCommand(&.{"python3"});
    h2_oracle_tests.addFileArg(b.path("tests/integration/transport_h2_integration_test.py"));
    h2_oracle_tests.addFileArg(ci.path(release_safe));
    h2_integration.step.dependOn(&h2_oracle_tests.step);
    const h2_integration_step = b.step(
        "transport-h2-integration",
        "Run the native TLS/H2 stream and bounded connection fixture (requires Python h2==4.3.0)",
    );
    h2_integration_step.dependOn(&h2_integration.step);

    const bash_integration = b.addSystemCommand(&.{"python3"});
    bash_integration.addFileArg(b.path("tests/integration/bash_integration.py"));
    bash_integration.addFileArg(ci.path(release_safe));
    const bash_integration_step = b.step(
        "bash-integration",
        "Run authorized Bash execution, stop, failure, and recovery cases",
    );
    bash_integration_step.dependOn(&bash_integration.step);

    const bash_walkthrough = b.addSystemCommand(&.{"python3"});
    bash_walkthrough.addFileArg(b.path("tests/integration/bash_integration.py"));
    bash_walkthrough.addFileArg(ci.path(release_safe));
    bash_walkthrough.addArg("--walkthrough");
    const bash_walkthrough_step = b.step(
        "bash-walkthrough",
        "Run the narrated public Bash approve-and-recover journey",
    );
    bash_walkthrough_step.dependOn(&bash_walkthrough.step);

    const bash_environment_integration = b.addSystemCommand(&.{"python3"});
    bash_environment_integration.addFileArg(b.path("tests/integration/bash_environment_integration.py"));
    bash_environment_integration.addFileArg(ci.path(release_safe));
    b.step(
        "bash-environment-integration",
        "Run Bash in the sending terminal's environment across terminals, peers and recovery",
    ).dependOn(&bash_environment_integration.step);

    const bash_owner_integration = b.addSystemCommand(&.{"python3"});
    bash_owner_integration.addFileArg(b.path("tests/integration/bash_owner_integration.py"));
    bash_owner_integration.addFileArg(ci.path(release_safe));
    const bash_owner_integration_step = b.step(
        "bash-owner-integration",
        "Run focused Bash owner transition cases",
    );
    bash_owner_integration_step.dependOn(&bash_owner_integration.step);

    const bash_lifecycle_integration = b.addSystemCommand(&.{"python3"});
    bash_lifecycle_integration.addFileArg(b.path("tests/integration/bash_lifecycle_integration.py"));
    bash_lifecycle_integration.addFileArg(ci.path(release_safe));
    const bash_lifecycle_integration_step = b.step(
        "bash-lifecycle-integration",
        "Run Bash lifecycle syscall-failure and custody cases",
    );
    bash_lifecycle_integration_step.dependOn(&bash_lifecycle_integration.step);

    const bash_recovery_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    bash_recovery_integration.addFileArg(b.path("tests/integration/bash_recovery_integration.py"));
    bash_recovery_integration.addFileArg(ci.path(release_safe));
    const bash_recovery_integration_step = b.step(
        "bash-recovery-integration",
        "Run fresh-Host Bash recovery cuts for admitted and committed Actions",
    );
    bash_recovery_integration_step.dependOn(&bash_recovery_integration.step);

    const codex_integration = b.addSystemCommand(&.{"python3"});
    codex_integration.addFileArg(b.path("tests/integration/codex_integration.py"));
    codex_integration.addFileArg(ci.path(release_safe));
    const codex_integration_step = b.step(
        "codex-integration",
        "Run synthetic managed-route credentials, Bash continuation and fresh-Host caller journey",
    );
    codex_integration_step.dependOn(&codex_integration.step);

    const credential_actor = b.addExecutable(.{
        .name = "codex-credential-actor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/codex_credential_actor.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    credential_actor.root_module.link_libc = true;
    const credentials_module = b.createModule(.{
        .root_source_file = b.path("src/codex_credentials.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    product.configurePosix(b, credentials_module);
    credential_actor.root_module.addImport("codex_credentials", credentials_module);
    const credential_integration = b.addSystemCommand(&.{"python3"});
    credential_integration.addFileArg(b.path("tests/integration/codex_credential_integration.py"));
    credential_integration.addFileArg(ci.path(credential_actor));
    const credential_integration_step = b.step(
        "codex-credential-integration",
        "Run native cross-process credential lock and refresh-generation transitions",
    );
    credential_integration_step.dependOn(&credential_integration.step);

    const preference_policy_actor = b.addExecutable(.{
        .name = "rui-preference-policy-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/preference_policy.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    preference_policy_actor.root_module.link_libc = true;
    const preferences_module = b.createModule(.{
        .root_source_file = b.path("src/preferences.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    product.configurePosix(b, preferences_module);
    preference_policy_actor.root_module.addImport("preferences", preferences_module);
    const preference_policy_integration = b.addSystemCommand(&.{"python3"});
    preference_policy_integration.addFileArg(b.path("tests/integration/preference_policy_integration.py"));
    preference_policy_integration.addFileArg(ci.path(preference_policy_actor));
    const preference_policy_step = b.step("preference-policy-integration", "Run native preference publication and privacy cases");
    preference_policy_step.dependOn(&preference_policy_integration.step);

    const mysql_wire_tests = b.addTest(.{
        .name = "rui-mysql-wire-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/mysql_wire_test.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const mysql_connection = b.createModule(.{
        .root_source_file = b.path("src/store/wire/mysql_connection.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // TLS: the connection's tls.zig is on tls_client's OpenSSL.
    if (product.addTlsClient(b, target, .ReleaseSafe, pinned_transport)) |tls_client| mysql_connection.addImport("tls_client", tls_client);
    mysql_wire_tests.root_module.addImport("mysql_connection", mysql_connection);
    const mysql_wire_integration = b.addSystemCommand(&.{"python3"});
    mysql_wire_integration.addFileArg(b.path("tests/integration/mysql_wire_integration.py"));
    mysql_wire_integration.addFileArg(ci.path(mysql_wire_tests));
    const mysql_wire_integration_step = b.step(
        "mysql-wire-integration",
        "Run the MySQL wire client against a real MySQL 8.4 server in Docker",
    );
    mysql_wire_integration_step.dependOn(&mysql_wire_integration.step);

    const codex_h2_integration = b.addSystemCommand(&.{"python3"});
    codex_h2_integration.addFileArg(b.path("tests/integration/codex_h2_integration.py"));
    codex_h2_integration.addFileArg(ci.path(release_safe));
    const codex_h2_integration_step = b.step(
        "codex-h2-integration",
        "Run synthetic managed TLS/H2 negotiation and observed sequential reuse (requires h2==4.3.0)",
    );
    codex_h2_integration_step.dependOn(&codex_h2_integration.step);

    const control_integration = b.addSystemCommand(&.{"python3"});
    control_integration.addFileArg(b.path("tests/integration/control_integration.py"));
    control_integration.addFileArg(ci.path(release_safe));
    const control_integration_step = b.step(
        "control-integration",
        "Run Session-stop, exact-interruption, and protected-capacity cases",
    );
    control_integration_step.dependOn(&control_integration.step);

    const descriptor_capacity_integration = b.addSystemCommand(&.{"python3"});
    descriptor_capacity_integration.addFileArg(b.path("tests/integration/descriptor_capacity_integration.py"));
    descriptor_capacity_integration.addFileArg(ci.path(release_safe));
    const descriptor_capacity_integration_step = b.step(
        "descriptor-capacity-integration",
        "Run reduced-limit startup rejection and adequate-limit fill/drain cases",
    );
    descriptor_capacity_integration_step.dependOn(&descriptor_capacity_integration.step);

    const host_status_actor = b.addExecutable(.{
        .name = "rui-host-status-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/host_status_actor.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    host_status_actor.root_module.link_libc = true;
    host_status_actor.root_module.addImport("client", read_client);
    const host_status_integration = b.addSystemCommand(&.{"python3"});
    host_status_integration.addFileArg(b.path("tests/integration/host_status_integration.py"));
    host_status_integration.addFileArg(ci.path(release_safe));
    host_status_integration.addFileArg(ci.path(host_status_actor));
    const host_status_step = b.step("host-status-integration", "Run native Host information and lease observation cases");
    host_status_step.dependOn(&host_status_integration.step);

    const host_launch_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    host_launch_integration.addFileArg(b.path("tests/integration/host_launch_integration.py"));
    host_launch_integration.addFileArg(ci.path(release_safe));
    const host_launch_step = b.step("host-launch-integration", "Run detached Host launch, alias convergence and startup-failure cases");
    host_launch_step.dependOn(&host_launch_integration.step);

    const installer_integration = b.addSystemCommand(&.{"python3"});
    installer_integration.addFileArg(b.path("tests/integration/installer_integration.py"));
    installer_integration.addFileArg(ci.path(release_safe));
    b.step("installer-integration", "Run source and release installer cases through the production publication owner").dependOn(&installer_integration.step);

    const upgrade_release = product.addRuiWithIdentity(b, target, .ReleaseSafe, "rui-upgrade-release-fixture", pinned_transport, .{
        .version = b.fmt("0.{d}.10000", .{@import("src/store/schema.zig").schema_version}),
        .revision = product.buildRevision(b),
    });
    const upgrade_fixture_step = b.step("upgrade-fixture", "Build the same-source native actor with synthetic release identity for upgrade evidence");
    upgrade_fixture_step.dependOn(&b.addInstallArtifact(upgrade_release, .{}).step);
    const upgrade_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    upgrade_integration.addFileArg(b.path("tests/integration/upgrade_integration.py"));
    upgrade_integration.addFileArg(ci.path(upgrade_release));
    const upgrade_step = b.step("upgrade-integration", "Run isolated release publication and exact Host upgrade lifecycle cases");
    upgrade_step.dependOn(&upgrade_integration.step);

    const launch_frame_integration = b.addSystemCommand(&.{"python3"});
    launch_frame_integration.addFileArg(b.path("tests/integration/launch_frame_integration.py"));
    launch_frame_integration.addFileArg(ci.path(release_safe));
    launch_frame_integration.addArg("--require-mcp-sdk");
    const mysql_launch_admin = b.addExecutable(.{
        .name = "rui-mysql-launch-admin",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/mysql_launch_admin.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    mysql_launch_admin.root_module.addImport("mysql_connection", mysql_connection);
    const mysql_launch_integration = b.addSystemCommand(&.{"python3"});
    mysql_launch_integration.addFileArg(b.path("tests/integration/launch_frame_mysql_integration.py"));
    mysql_launch_integration.addFileArg(ci.path(release_safe));
    mysql_launch_integration.addFileArg(ci.path(mysql_launch_admin));
    const launch_frame_step = b.step("launch-frame-integration", "Run SQLite and MySQL launch frames: readiness, safe credentials, ownership and stdin liveness");
    launch_frame_step.dependOn(&launch_frame_integration.step);
    launch_frame_step.dependOn(&mysql_launch_integration.step);

    // The TypeScript client against the Rui this build makes; Node strips the types.
    const ts_client = b.addSystemCommand(&.{"python3"});
    ts_client.addFileArg(b.path("tests/integration/host_process.py"));
    ts_client.addArgs(&.{ "exec", "env" });
    ts_client.addPrefixedFileArg("RUI_BINARY=", ci.path(release_safe));
    ts_client.addArgs(&.{ "node", "--experimental-strip-types", "--test", "--test-concurrency=1", "test/*.test.ts" });
    ts_client.setCwd(b.path("clients/ts"));
    b.step("ts-client", "Run the TypeScript client against a built Rui (needs Node 22.6 or later)").dependOn(&ts_client.step);

    const host_stop_integration = b.addSystemCommand(&.{"python3"});
    host_stop_integration.addFileArg(b.path("tests/integration/host_stop_integration.py"));
    host_stop_integration.addFileArg(ci.path(release_safe));
    host_stop_integration.addFileArg(ci.path(host_status_actor));
    const host_stop_step = b.step("host-stop-integration", "Run native exact-instance Host shutdown and custody drain");
    host_stop_step.dependOn(&host_stop_integration.step);

    // check runs these cases among its process integrations; each step runs
    // the same case alone, so selection can name only the ones a change reaches.
    // Its Session link journey reads the screen, as check's run of it does.
    const peer_integration = screen_module.screenCommand(b, screen, &.{"python3"});
    peer_integration.addFileArg(b.path("tests/integration/peer_integration.py"));
    peer_integration.addFileArg(ci.path(release_safe));
    b.step("peer-integration", "Run the peer round trip through Rui-launched Bash").dependOn(&peer_integration.step);
    b.step("sender-identity-integration", "Run Action sender authority through the installed CLI, exit, stop and restart")
        .dependOn(&addFixture(b, "tests/integration/sender_identity_integration.py", ci.path(release_safe)).step);
    b.step("conversation-page-integration", "Run public Conversation wire reads against a real Host and canonical Store")
        .dependOn(&addFixture(b, "tests/integration/conversation_page_integration.py", ci.path(release_safe)).step);
    b.step("host-allocator-integration", "Observe the Host allocator environment before main")
        .dependOn(&addFixture(b, "tests/integration/host_allocator_test.py", ci.path(release_safe)).step);
    const human_cli = screen_module.screenCommand(b, screen, &.{});
    human_cli.addPrefixedFileArg("RUI_TEST_TERMINAL_NOTICE=", ci.path(terminal_notice));
    human_cli.addArg("python3");
    human_cli.addFileArg(b.path("tests/integration/human_cli_integration.py"));
    human_cli.addFileArg(ci.path(release_safe));
    b.step(
        "human-cli-integration",
        "Run public caller recovery, the interactive frontend and exact Bash authorization (includes terminal restoration and canonical failure)",
    ).dependOn(&human_cli.step);
    const host_process_test = b.addSystemCommand(&.{"python3"});
    host_process_test.addFileArg(b.path("tests/integration/host_process_test.py"));
    b.step("host-process-test", "Run the bounded Host process fixture's own failure checks").dependOn(&host_process_test.step);

    const debug = product.addRui(b, target, .Debug, "rui-debug-check", pinned_transport);
    const debug_integration = b.addSystemCommand(&.{"sh"});
    debug_integration.addFileArg(b.path("tests/integration/admission_integration.sh"));
    debug_integration.addFileArg(ci.path(debug));
    const debug_integration_step = b.step(
        "admission-debug-integration",
        "Run the documented Debug artifact through configuration/message recovery",
    );
    debug_integration_step.dependOn(&debug_integration.step);
    // A bounded Debug subset of the dispatch scenarios: failure provenance
    // through SQLite. The full dispatch journey stays on ReleaseSafe.
    const dispatch_debug_integration = b.addSystemCommand(&.{"python3"});
    dispatch_debug_integration.addFileArg(b.path("tests/integration/dispatch_integration.py"));
    dispatch_debug_integration.addFileArg(ci.path(debug));
    dispatch_debug_integration.addArg("failure-correlation");
    b.step(
        "dispatch-debug-integration",
        "Run bounded model failure correlation through SQLite on the Debug artifact",
    ).dependOn(&dispatch_debug_integration.step);

    const check_step = b.step(
        "check",
        "Run formatting, native tests, process integrations in parallel, and production builds",
    );
    const format = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "--ast-check",
    });
    check_step.dependOn(h2_test_step);
    check_step.dependOn(pg_test_step);
    format.addFileArg(b.path("build.zig"));
    format.addDirectoryArg(b.path("build"));
    format.addDirectoryArg(b.path("src"));
    const release_small = product.addRui(b, target, .ReleaseSmall, "rui-release-small-check", pinned_transport);
    const fast_integrations = screen_module.screenCommand(b, screen, &.{"sh"});
    fast_integrations.addFileArg(b.path("tests/integration/check.sh"));
    fast_integrations.addFileArg(ci.path(release_safe));
    fast_integrations.addFileArg(ci.path(debug));
    fast_integrations.addArg("parallel");
    fast_integrations.addFileArg(ci.path(units.tests[0]));
    fast_integrations.addFileArg(ci.path(host_status_actor));
    fast_integrations.addFileArg(ci.path(session_list_client));
    fast_integrations.addFileArg(ci.path(activity_client));
    fast_integrations.addFileArg(ci.path(preference_policy_actor));
    fast_integrations.addFileArg(ci.path(terminal_notice));
    for (units.tests[1..]) |compile| fast_integrations.addFileArg(ci.path(compile));
    fast_integrations.step.dependOn(&format.step);
    // Release compilation coverage stays in qualification, not PR fixture startup.
    if (!pr_ci) fast_integrations.addFileInput(ci.path(release_small));
    fast_integrations.step.dependOn(&units.run_renderer_allocation.step);
    fast_integrations.step.dependOn(&units.signal_stack_probe.step);
    check_step.dependOn(&fast_integrations.step);
    // The gate reads x86-64 prologues; other targets have no frame reader.
    const stack_frames_step = b.step(
        "stack-frames",
        "Fail when a Host thread reaches a ReleaseSafe stack frame over budget (x86-64 Linux only)",
    );
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
        const stack_frames = b.addSystemCommand(&.{ "python3", "-B" });
        stack_frames.addFileArg(b.path("tests/ci/stack_frames.py"));
        // This is a production-codegen oracle, never a gate on the PR backend.
        stack_frames.addFileArg(ci.path(production_safe));
        stack_frames.addFileArg(b.path("tests/ci/stack_frames.json"));
        stack_frames_step.dependOn(&stack_frames.step);
    }
    // Selected PRs run this unchanged LLVM oracle in a separate required job,
    // so its compile cannot hold every integration shard behind it.
    if (!pr_ci) check_step.dependOn(stack_frames_step);

    const full_check_step = b.step(
        "check-full",
        "Run routine native tests and process integrations serially (long witnesses are separate)",
    );
    const check_part = b.option(enum { all, execution, callers }, "check-part", "Isolated full-check part (default all)") orelse .all;
    const process_integrations = screen_module.screenCommand(b, screen, &.{"sh"});
    process_integrations.addFileArg(b.path("tests/integration/check.sh"));
    process_integrations.addFileArg(ci.path(release_safe));
    process_integrations.addFileArg(ci.path(debug));
    process_integrations.addFileArg(ci.path(host_status_actor));
    process_integrations.addFileArg(ci.path(session_list_client));
    process_integrations.addFileArg(ci.path(activity_client));
    process_integrations.addFileArg(ci.path(preference_policy_actor));
    process_integrations.addArg(@tagName(check_part));
    process_integrations.addFileArg(ci.path(terminal_notice));
    process_integrations.step.dependOn(&format.step);
    // The execution partition overlaps native tests with its serial process
    // fixtures, just as check already does. Keep the unsplit gate serial and
    // the callers partition isolated on its own runner. Both peers must pass.
    const native_gate = if (check_part == .execution) full_check_step else &process_integrations.step;
    if (check_part != .callers) {
        native_gate.dependOn(&units.run_tests.step);
        native_gate.dependOn(&units.run_renderer_allocation.step);
        native_gate.dependOn(h2_test_step);
        native_gate.dependOn(pg_test_step);
    }
    if (!pr_ci) process_integrations.addFileInput(ci.path(release_small));
    full_check_step.dependOn(&process_integrations.step);

    const sqlite_shell = measurement_module.addCheck(b, ci, target, release_safe);
    cross_module.add(b, target, pinned_transport);
    measurement_module.add(b, ci, release_safe, sqlite_shell, model_queue_output);

    // Compile the selected gates once, without executing their fixture Run
    // steps. Workers still execute the original gates and their assertions.
    const ci_build = b.step("ci-build", "Compile selected CI gates without running tests");
    if (ci_targets) |selected| {
        if (ci_part != .unit) {
            const cpu_manifest = b.addWriteFiles().add("ci-cpu.json", ci_cpu);
            ci_build.dependOn(&b.addInstallBinFile(cpu_manifest, "ci-cpu.json").step);
        }
        var collection: ci_module.CiCollection = .{ .b = b, .destination = ci_build, .part = ci_part, .unit = units.tests, .screen = screen_emulator };
        var names = std.mem.splitScalar(u8, selected, ',');
        while (names.next()) |name| {
            const root = b.top_level_steps.get(name) orelse @panic("Unknown CI target");
            if (&root.step == ci_build) @panic("ci-build cannot select itself");
            collection.collect(&root.step);
        }
        // The plan splits by target name (qualification.UNIT_TARGETS); a split
        // that disagrees with this graph would idle a producer or drop a binary.
        if (ci_part != .all and !collection.reached_unit)
            @panic("Split CI producers selected without the unit test compile; update UNIT_TARGETS");
    }
}

/// A Python process fixture run against one Rui executable.
fn addFixture(b: *std.Build, script: []const u8, rui: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path(script));
    run.addFileArg(rui);
    return run;
}
