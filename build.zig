const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const ci_targets = b.option([]const u8, "ci-targets", "Comma-separated CI targets to compile");
    const ci_part = b.option(CiPart, "ci-part", "Which selected CI compiles this producer emits") orelse .all;
    const ci: CiArtifacts = .{ .b = b, .directory = b.option([]const u8, "ci-artifacts", "Verified native CI executables") };
    // Hosted workers can have different CPUs. Transfer only the platform's
    // baseline instruction set; ordinary local builds still target their host.
    const ci_mode = ci_targets != null or ci.directory != null;
    const ci_query: std.Target.Query = .{ .cpu_model = .baseline };
    const target = b.standardTargetOptions(.{ .default_target = if (ci_mode) ci_query else .{} });
    const optimize = b.standardOptimizeOption(.{});
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
    const pinned_transport = addPinnedTransport(b, target);

    const rui = addRui(b, target, optimize, "rui", pinned_transport);
    b.installArtifact(rui);
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    if (ci.directory != null and test_filter != null) @panic("CI artifacts contain unfiltered tests");
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
    configureHostLaunch(b, tests);
    configureTerminalEditor(b, tests);
    configureTransport(b, tests, target, pinned_transport);
    const run_tests = ci.run(tests);
    // Reuse compiled artifacts, never a prior test outcome (even with a fixed seed).
    run_tests.has_side_effects = true;
    run_tests.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0");

    const test_step = b.step("test", "Run unit, Store, and protocol tests");
    test_step.dependOn(&run_tests.step);
    // Selection pairs test-full with check or check-full, which already run every
    // other native test, so this binary contains only the real-time witness.
    const deadline_witness = b.addTest(.{
        .name = "deadline-witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = &.{test_filter orelse "Host processing wait does not consume response transfer inactivity"},
    });
    configureSqlite(b, deadline_witness);
    configureBashPlatform(b, deadline_witness);
    configureHostLaunch(b, deadline_witness);
    configureTerminalEditor(b, deadline_witness);
    configureTransport(b, deadline_witness, target, pinned_transport);
    const run_full_tests = ci.run(deadline_witness);
    run_full_tests.has_side_effects = true;
    run_full_tests.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "1");
    const full_test_step = b.step("test-full", "Run the real 60-second client deadline witness");
    full_test_step.dependOn(&run_full_tests.step);

    const logic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/logic_tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    configureTerminalEditor(b, logic_tests);
    const run_logic_tests = ci.run(logic_tests);
    run_logic_tests.has_side_effects = true;
    const logic_test_step = b.step(
        "test-logic",
        "Run the shared execution turn and portable owner tests without Host, Bash, or transport fixtures",
    );
    logic_test_step.dependOn(&run_logic_tests.step);

    const h2_test_step = b.step("test-h2", "Run the HTTP/2 client's own tests");
    if (addH2(b, target, .ReleaseSafe, pinned_transport, addTestPoll(b))) |h2| {
        const h2_tests = b.addTest(.{ .root_module = h2, .filters = if (test_filter) |filter| &.{filter} else &.{} });
        const run_h2_tests = ci.run(h2_tests);
        run_h2_tests.has_side_effects = true;
        h2_test_step.dependOn(&run_h2_tests.step);
    }

    const codec_runtime_test_step = b.step("test-codec-runtime", "Run the codec sandbox's own tests against tiny modules");
    const codec_runtime_tests = b.addTest(.{
        .root_module = addCodecRuntime(b, target, .ReleaseSafe, true),
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    codec_runtime_tests.root_module.addAnonymousImport("codec_runtime_fixture", .{
        .root_source_file = addWasmModule(b, "codec-runtime-fixture", "src/codec_runtime/fixture.zig").getEmittedBin(),
    });
    const run_codec_runtime_tests = ci.run(codec_runtime_tests);
    run_codec_runtime_tests.has_side_effects = true;
    codec_runtime_test_step.dependOn(&run_codec_runtime_tests.step);

    const codec_runtime_bench = b.addExecutable(.{
        .name = "rui-codec-runtime-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codec_runtime/bench.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const bench_c_safety = b.option(bool, "codec-runtime-c-safety", "Keep Zig's C safety checks in WAMR for codec-runtime-bench (default true, as tests build it)") orelse true;
    codec_runtime_bench.root_module.addImport("codec_runtime", addCodecRuntime(b, target, .ReleaseSafe, bench_c_safety));
    codec_runtime_bench.root_module.addImport("scan", b.createModule(.{ .root_source_file = b.path("src/codec_runtime/scan.zig") }));
    codec_runtime_bench.root_module.addAnonymousImport("scan_wasm", .{
        .root_source_file = addWasmModule(b, "codec-runtime-scan", "src/codec_runtime/scan_module.zig").getEmittedBin(),
    });
    const run_codec_runtime_bench = b.addRunArtifact(codec_runtime_bench);
    run_codec_runtime_bench.has_side_effects = true;
    run_codec_runtime_bench.addPassthruArgs();
    b.step(
        "codec-runtime-bench",
        "Measure the codec sandbox: wasm vs native scan throughput and private memory per phase (nonblocking)",
    ).dependOn(&run_codec_runtime_bench.step);

    // Test actors are never shipped and run briefly. On x86_64, Zig's own
    // backend builds each in about a second, where LLVM pays a ~28 CPU-second
    // ReleaseSafe floor; safety checks stay on. Its aarch64-macos build of these
    // actors exhausts memory, so Apple Silicon keeps LLVM. Product binaries and
    // codegen witnesses such as the signal-stack probe always use LLVM.
    const test_actor_llvm: ?bool = if (target.result.cpu.arch == .x86_64) false else null;
    const renderer_allocation = b.addExecutable(.{
        .name = "rui-answer-renderer-allocation-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/answer_renderer_allocation.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    renderer_allocation.root_module.addImport("AnswerRenderer", b.createModule(.{
        .root_source_file = b.path("src/AnswerRenderer.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }));
    const run_renderer_allocation = ci.run(renderer_allocation);
    logic_test_step.dependOn(&run_renderer_allocation.step);
    test_step.dependOn(&run_renderer_allocation.step);

    const terminal_notice = b.addExecutable(.{
        .name = "rui-terminal-notice-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_notice_test.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    configureTerminalEditor(b, terminal_notice);

    const signal_stack_probe = ci.run(b.addExecutable(.{
        .name = "rui-signal-stack-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/signal_stack_probe.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    }));
    signal_stack_probe.has_side_effects = true;
    test_step.dependOn(&signal_stack_probe.step);

    const release_safe = addRui(b, target, .ReleaseSafe, "rui-release-safe-check", pinned_transport);
    const terminal_restoration = b.addSystemCommand(&.{"env"});
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
        const selftest = b.addSystemCommand(&.{ "python3", "-B" });
        selftest.addFileArg(b.path(path));
        selftest.has_side_effects = true;
        renderer_selftests.dependOn(&selftest.step);
    }
    b.step(
        "direct-pty",
        "Run the synthetic direct-PTY key matrix and tmux smoke (nonblocking)",
    ).dependOn(&addPtyHarness(b, "tests/qualification/direct-pty/matrix.py", ci.path(release_safe)).step);
    b.step(
        "direct-pty-controls",
        "Run direct-PTY driver and disposal controls (nonblocking)",
    ).dependOn(&addPtyHarness(b, "tests/qualification/direct-pty/controls.py", ci.path(release_safe)).step);
    b.step(
        "input-equivalence",
        "Run TD2 original-recovery encodings through the direct-PTY matrix (nonblocking)",
    ).dependOn(&addPtyHarness(b, "tests/integration/input_equivalence.py", ci.path(release_safe)).step);

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
    configurePosix(b, read_client);
    session_list_client.root_module.addImport("rui_client", read_client);
    const proposal_client = b.addExecutable(.{
        .name = "rui-proposal-client-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/proposal_client.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    proposal_client.root_module.link_libc = true;
    proposal_client.root_module.addImport("rui_client", read_client);
    const proposal_integration = b.addSystemCommand(&.{"python3"});
    proposal_integration.addFileArg(b.path("tests/integration/proposal_integration.py"));
    proposal_integration.addFileArg(ci.path(release_safe));
    proposal_integration.addFileArg(ci.path(proposal_client));
    b.step("proposal-integration", "Run historical proposal discovery and complete typed Client reads").dependOn(&proposal_integration.step);
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

    const login_signal_integration = b.addSystemCommand(&.{"python3"});
    login_signal_integration.addFileArg(b.path("tests/integration/login_signal_integration.py"));
    login_signal_integration.addFileArg(ci.path(release_safe));
    b.step("login-signal-integration", "Run the Linux-only one-shot login signal loader witness").dependOn(&login_signal_integration.step);

    const current_facts_integration = b.addSystemCommand(&.{"python3"});
    current_facts_integration.addFileArg(b.path("tests/integration/current_facts_integration.py"));
    current_facts_integration.addFileArg(ci.path(release_safe));
    b.step("current-facts-integration", "Run the real Current producer/consumer observation oracle").dependOn(&current_facts_integration.step);

    const canonical_failure_integration = b.addSystemCommand(&.{"python3"});
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

    const bash_recovery_integration = b.addSystemCommand(&.{"python3"});
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
    configurePosix(b, credentials_module);
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
    configurePosix(b, preferences_module);
    preference_policy_actor.root_module.addImport("preferences", preferences_module);
    const preference_policy_integration = b.addSystemCommand(&.{"python3"});
    preference_policy_integration.addFileArg(b.path("tests/integration/preference_policy_integration.py"));
    preference_policy_integration.addFileArg(ci.path(preference_policy_actor));
    const preference_policy_step = b.step("preference-policy-integration", "Run native preference publication and privacy cases");
    preference_policy_step.dependOn(&preference_policy_integration.step);

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

    const host_launch_integration = b.addSystemCommand(&.{"python3"});
    host_launch_integration.addFileArg(b.path("tests/integration/host_launch_integration.py"));
    host_launch_integration.addFileArg(ci.path(release_safe));
    const host_launch_step = b.step("host-launch-integration", "Run detached Host launch, alias convergence and startup-failure cases");
    host_launch_step.dependOn(&host_launch_integration.step);

    const host_stop_integration = b.addSystemCommand(&.{"python3"});
    host_stop_integration.addFileArg(b.path("tests/integration/host_stop_integration.py"));
    host_stop_integration.addFileArg(ci.path(release_safe));
    host_stop_integration.addFileArg(ci.path(host_status_actor));
    const host_stop_step = b.step("host-stop-integration", "Run native exact-instance Host shutdown and custody drain");
    host_stop_step.dependOn(&host_stop_integration.step);

    const debug = addRui(b, target, .Debug, "rui-debug-check", pinned_transport);
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
    check_step.dependOn(codec_runtime_test_step);
    format.addFileArg(b.path("build.zig"));
    format.addDirectoryArg(b.path("src"));
    const release = addRui(b, target, .ReleaseSmall, "rui-release-small-check", pinned_transport);
    const fast_integrations = b.addSystemCommand(&.{"sh"});
    fast_integrations.addFileArg(b.path("tests/integration/check.sh"));
    fast_integrations.addFileArg(ci.path(release_safe));
    fast_integrations.addFileArg(ci.path(debug));
    fast_integrations.addArg("parallel");
    fast_integrations.addFileArg(ci.path(tests));
    fast_integrations.addFileArg(ci.path(host_status_actor));
    fast_integrations.addFileArg(ci.path(session_list_client));
    fast_integrations.addFileArg(ci.path(proposal_client));
    fast_integrations.addFileArg(ci.path(activity_client));
    fast_integrations.addFileArg(ci.path(preference_policy_actor));
    fast_integrations.addFileArg(ci.path(terminal_notice));
    fast_integrations.step.dependOn(&format.step);
    fast_integrations.addFileInput(ci.path(release));
    fast_integrations.step.dependOn(&run_renderer_allocation.step);
    fast_integrations.step.dependOn(&signal_stack_probe.step);
    check_step.dependOn(&fast_integrations.step);
    // The gate reads x86-64 prologues; other targets have no frame reader.
    const stack_frames_step = b.step(
        "stack-frames",
        "Fail when a Host thread reaches a ReleaseSafe stack frame over budget (x86-64 Linux only)",
    );
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
        const stack_frames = b.addSystemCommand(&.{ "python3", "-B" });
        stack_frames.addFileArg(b.path("tests/ci/stack_frames.py"));
        stack_frames.addFileArg(ci.path(release_safe));
        stack_frames.addFileArg(b.path("tests/ci/stack_frames.json"));
        stack_frames_step.dependOn(&stack_frames.step);
    }
    check_step.dependOn(stack_frames_step);

    const full_check_step = b.step(
        "check-full",
        "Run routine native tests and process integrations serially (long witnesses are separate)",
    );
    const check_part = b.option(enum { all, execution, callers }, "check-part", "Isolated full-check part (default all)") orelse .all;
    const process_integrations = b.addSystemCommand(&.{"sh"});
    process_integrations.addFileArg(b.path("tests/integration/check.sh"));
    process_integrations.addFileArg(ci.path(release_safe));
    process_integrations.addFileArg(ci.path(debug));
    process_integrations.addFileArg(ci.path(host_status_actor));
    process_integrations.addFileArg(ci.path(session_list_client));
    process_integrations.addFileArg(ci.path(proposal_client));
    process_integrations.addFileArg(ci.path(activity_client));
    process_integrations.addFileArg(ci.path(preference_policy_actor));
    process_integrations.addArg(@tagName(check_part));
    process_integrations.addFileArg(ci.path(terminal_notice));
    process_integrations.step.dependOn(&format.step);
    // The execution part owns native tests. The callers
    // part runs on another machine, isolated from that child-process load.
    if (check_part != .callers) {
        process_integrations.step.dependOn(&run_tests.step);
        process_integrations.step.dependOn(&run_renderer_allocation.step);
        process_integrations.step.dependOn(h2_test_step);
        process_integrations.step.dependOn(codec_runtime_test_step);
    }
    process_integrations.addFileInput(ci.path(release));
    full_check_step.dependOn(&process_integrations.step);

    const measurement_tests = b.addSystemCommand(&.{
        "go", "test", "-count=1", "-mod=readonly", "./...",
    });
    measurement_tests.setCwd(b.path("tests/qualification"));
    measurement_tests.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const measurement_test_step = b.step(
        "measurement-check",
        "Compile and test the pinned Go measurement packages",
    );
    measurement_test_step.dependOn(&measurement_tests.step);

    const queue_audit_test = b.addSystemCommand(&.{
        "go", "test", "-count=1", "-mod=readonly", "-run", "^TestExecutionAuditQueryRejectsHiddenEntities$", "./model-queue", "-args", "-sqlite",
    });
    queue_audit_test.setCwd(b.path("tests/qualification"));
    queue_audit_test.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const sqlite_shell = addSqliteShell(b, target, .ReleaseSmall);
    queue_audit_test.addFileArg(ci.path(sqlite_shell));
    measurement_test_step.dependOn(&queue_audit_test.step);

    const linux_cross_step = b.step(
        "cross-check-linux",
        "Compile Linux x86-64 and experimental Linux ARM64",
    );
    const macos_cross_step = b.step(
        "cross-check-macos",
        "Compile Apple Silicon macOS and experimental Intel macOS (requires Xcode/Command Line Tools)",
    );
    const cross_step = b.step(
        "cross-check",
        "Compile supported native and experimental Linux/macOS architectures (not runtime qualification)",
    );
    cross_step.dependOn(linux_cross_step);
    cross_step.dependOn(macos_cross_step);
    const macos_types_step = b.step(
        "typecheck-macos",
        "Type-check Rui and its unit tests for Apple Silicon macOS on any host (no SDK, link or run)",
    );
    {
        const apple = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
        macos_types_step.dependOn(&addRui(b, apple, .ReleaseSafe, "rui-typecheck-macos", null).step);
        const apple_tests = b.addTest(.{
            .name = "test-typecheck-macos",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = apple,
                .optimize = .ReleaseSafe,
            }),
        });
        configureSqlite(b, apple_tests);
        configureBashPlatform(b, apple_tests);
        configureHostLaunch(b, apple_tests);
        configureTerminalEditor(b, apple_tests);
        configureTransport(b, apple_tests, apple, null);
        macos_types_step.dependOn(&apple_tests.step);
    }
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
            .linux => {
                linux_cross_step.dependOn(&executable.step);
            },
            .macos => {
                macos_cross_step.dependOn(&executable.step);
            },
            else => unreachable,
        }
    }

    const measure = addMeasurement(b, &.{"./configuration-admission"});
    measure.addFileArg(ci.path(release));
    const measure_step = b.step(
        "measure-admission",
        "Measure macOS Host and direct-client memory for configuration admission",
    );
    measure_step.dependOn(&measure.step);

    const measure_messages = addMeasurement(b, &.{"./message-admission"});
    measure_messages.addFileArg(ci.path(release));
    const measure_messages_step = b.step(
        "measure-message-admission",
        "Measure macOS message admission and observation scaling",
    );
    measure_messages_step.dependOn(&measure_messages.step);

    const measure_dispatch = addMeasurement(b, &.{"./model-dispatch"});
    measure_dispatch.addFileArg(ci.path(release));
    const measure_dispatch_step = b.step(
        "measure-model-dispatch",
        "Measure macOS frozen-request transport, scratch, descriptors, and custody",
    );
    measure_dispatch_step.dependOn(&measure_dispatch.step);

    const measure_output = addMeasurement(b, &.{"./model-output"});
    measure_output.addPassthruArgs();
    measure_output.addFileArg(ci.path(release));
    const measure_output_step = b.step(
        "measure-model-output",
        "Measure macOS model-output bytes, item counts, storage, and retained memory",
    );
    measure_output_step.dependOn(&measure_output.step);

    const measure_repeat_work = addMeasurement(b, &.{ "./model-output", "--repeat-work" });
    measure_repeat_work.addFileArg(ci.path(release));
    const measure_repeat_work_step = b.step(
        "measure-repeat-work",
        "Measure 20 same-Host waves across 100 stable Sessions with growing history",
    );
    measure_repeat_work_step.dependOn(&measure_repeat_work.step);

    const measure_retry = addMeasurement(b, &.{"./model-retry"});
    measure_retry.addFileArg(ci.path(release));
    const measure_retry_step = b.step(
        "measure-model-retry",
        "Measure macOS retry discovery, launch separation, churn, and custody",
    );
    measure_retry_step.dependOn(&measure_retry.step);

    const measure_queue = addMeasurement(b, &.{"./model-queue"});
    if (model_queue_output) |output| {
        measure_queue.addArgs(&.{ "-output", output });
    }
    measure_queue.addFileArg(ci.path(release));
    measure_queue.addFileArg(ci.path(sqlite_shell));
    const measure_queue_step = b.step(
        "measure-model-queue",
        "Measure model queue discovery, ordering, settlement, and portable mixed resources",
    );
    measure_queue_step.dependOn(&measure_queue.step);

    const measure_control = addMeasurement(b, &.{"./model-control"});
    measure_control.addFileArg(ci.path(release));
    const measure_control_step = b.step(
        "measure-model-control",
        "Measure control headroom, acknowledgment latency, and cleanup resources",
    );
    measure_control_step.dependOn(&measure_control.step);

    const measure_call_classification = addMeasurement(b, &.{"./call-classification"});
    measure_call_classification.addPassthruArgs();
    measure_call_classification.addFileArg(ci.path(release));
    measure_call_classification.addFileArg(ci.path(sqlite_shell));
    const measure_call_classification_step = b.step(
        "measure-call-classification",
        "Measure production call classification, exact denial, recovery, and population scaling",
    );
    measure_call_classification_step.dependOn(&measure_call_classification.step);

    const measure_execution_service = addMeasurement(b, &.{"./execution-service"});
    measure_execution_service.addPassthruArgs();
    measure_execution_service.addFileArg(ci.path(release));
    const measure_execution_service_step = b.step(
        "measure-execution-service",
        "Measure production execution service across completions, history, replay fields, and owner populations",
    );
    measure_execution_service_step.dependOn(&measure_execution_service.step);

    // Compile the selected gates once, without executing their fixture Run
    // steps. Workers still execute the original gates and their assertions.
    const ci_build = b.step("ci-build", "Compile selected CI gates without running tests");
    if (ci_targets) |selected| {
        if (ci_part != .unit) {
            const cpu_manifest = b.addWriteFiles().add("ci-cpu.json", ci_cpu);
            ci_build.dependOn(&b.addInstallBinFile(cpu_manifest, "ci-cpu.json").step);
        }
        var collection: CiCollection = .{ .b = b, .destination = ci_build, .part = ci_part, .unit = tests };
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

/// The unit test binary compiles single-threaded for minutes, so a separate
/// producer builds it beside everything else.
const CiPart = enum { all, unit, rest };

const CiCollection = struct {
    b: *std.Build,
    destination: *std.Build.Step,
    part: CiPart,
    unit: *std.Build.Step.Compile,
    visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    reached_unit: bool = false,

    fn collect(collection: *CiCollection, source: *std.Build.Step) void {
        const b = collection.b;
        const entry = collection.visited.getOrPut(b.allocator, source) catch @panic("OOM");
        if (entry.found_existing) return;
        if (source.cast(std.Build.Step.Compile)) |compile| {
            const unit = compile == collection.unit;
            collection.reached_unit = collection.reached_unit or unit;
            const emit = switch (collection.part) {
                .all => true,
                .unit => unit,
                .rest => !unit,
            };
            if (emit) collection.destination.dependOn(&b.addInstallBinFile(compile.getEmittedBin(), ciName(b, compile)).step);
            return;
        }
        for (source.dependencies.items) |dependency| collection.collect(dependency);
    }
};

fn ciName(b: *std.Build, compile: *std.Build.Step.Compile) []const u8 {
    // Both test roots use Zig's default executable name; distinguish their
    // source-owned roots without changing normal compilation or cache keys.
    return if (compile.kind == .@"test")
        b.fmt("{s}-{s}", .{ compile.name, std.fs.path.stem(compile.root_module.root_source_file.?.src_path.sub_path) })
    else
        compile.name;
}

const CiArtifacts = struct {
    b: *std.Build,
    directory: ?[]const u8,

    fn path(ci: CiArtifacts, compile: *std.Build.Step.Compile) std.Build.LazyPath {
        return if (ci.directory) |directory|
            .{ .cwd_relative = ci.b.pathJoin(&.{ directory, ciName(ci.b, compile) }) }
        else
            compile.getEmittedBin();
    }

    fn run(ci: CiArtifacts, compile: *std.Build.Step.Compile) *std.Build.Step.Run {
        if (ci.directory == null) return ci.b.addRunArtifact(compile);
        const command = ci.b.addRunFile(ci.path(compile));
        if (compile.kind == .@"test") command.enableTestRunnerMode();
        return command;
    }
};

/// Runs a direct-PTY harness against the build-owned ReleaseSafe Rui; callers
/// pass the harness's own options, including a fresh --output, after `--`.
// A Go measurement launches Rui, so it enters the fixture boundary like every
// fixture: root is refused and the environment is built there.
fn addMeasurement(b: *std.Build, arguments: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("tests/integration/host_process.py"));
    run.addArgs(&.{ "exec", "env", "GOTOOLCHAIN=local", "go", "run", "-mod=readonly" });
    run.addArgs(arguments);
    run.setCwd(b.path("tests/qualification"));
    return run;
}

fn addPtyHarness(b: *std.Build, harness: []const u8, rui: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path(harness));
    run.addFileArg(rui);
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
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
    pinned_transport: ?PinnedTransport,
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
    configureHostLaunch(b, executable);
    configureTerminalEditor(b, executable);
    configureTransport(b, executable, target, pinned_transport);
    return executable;
}

const PinnedTransport = struct {
    output: std.Build.LazyPath,
};

fn addPinnedTransport(b: *std.Build, target: std.Build.ResolvedTarget) PinnedTransport {
    const openssl = b.dependency("openssl", .{});
    const nghttp2 = b.dependency("nghttp2", .{});
    const build_transport = b.addSystemCommand(&.{"sh"});
    build_transport.addFileArg(b.path("src/build_transport.sh"));
    // Configure scripts change cwd and embed the installation prefix in Makefiles.
    build_transport.addDirectoryArg2(openssl.path("."), .{ .make_absolute = true });
    build_transport.addDirectoryArg2(nghttp2.path("."), .{ .make_absolute = true });
    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    const output = build_transport.addOutputDirectoryArg2(b.fmt("pinned-transport-{s}", .{target_name}), .{ .make_absolute = true });
    build_transport.addArg(target_name);
    build_transport.addArg(b.graph.zig_exe);
    return .{ .output = output };
}

fn buildRevision(b: *std.Build) []const u8 {
    return gitHead(b, &.{ "rev-parse", "HEAD" }) orelse "unknown";
}

/// The release version from a `vMAJOR.MINOR.PATCH` tag on the built commit.
/// Release publication tags the commit before building it.
fn buildVersion(b: *std.Build) []const u8 {
    const tag = gitHead(b, &.{ "describe", "--tags", "--exact-match", "--match", "v[0-9]*.[0-9]*.[0-9]*", "HEAD" }) orelse
        return "unreleased";
    return tag[1..];
}

fn gitHead(b: *std.Build, query: []const []const u8) ?[]const u8 {
    // Git refs can change without any build input changing.
    b.graph.poisonCache();
    // An archive nested in another checkout must not inherit that checkout's revision.
    _ = b.root.statFile(b.graph.io, ".git") catch return null;
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    const argv = std.mem.concat(b.allocator, []const u8, &.{ &.{ "git", "-C", root }, query }) catch @panic("OOM");
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| std.mem.trim(u8, stdout, "\r\n"),
        else => null,
    };
}

fn configureTransport(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    /// Null type-checks without the built transport: headers only, no link.
    maybe_pinned: ?PinnedTransport,
) void {
    const options = b.addOptions();
    options.addOption(bool, "enabled", transportEnabled(target));
    options.addOption([]const u8, "revision", buildRevision(b));
    options.addOption([]const u8, "version", buildVersion(b));
    compile.root_module.addOptions("transport_options", options);
    const test_poll = addTestPoll(b);
    compile.root_module.addImport("test_poll", test_poll);
    const h2 = addH2(b, target, compile.root_module.optimize.?, maybe_pinned, test_poll) orelse return;
    compile.root_module.addImport("h2", h2);
}

/// The one helper Rui's and h2's tests poll through. A module, so both
/// share one copy of the file.
fn addTestPoll(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/testing/poll.zig") });
}

/// The HTTP/2 client module, linked against the pinned nghttp2 and OpenSSL,
/// or null where the pinned transport is not built. With only headers it
/// type-checks and links nothing.
fn addH2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    maybe_pinned: ?PinnedTransport,
    test_poll: *std.Build.Module,
) ?*std.Build.Module {
    if (!transportEnabled(target)) return null;
    const module = b.createModule(.{
        .root_source_file = b.path("src/h2/h2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("test_poll", test_poll);
    const bindings = addBindings(b, module, "h2_c",
        \\#include <nghttp2/nghttp2.h>
        \\#include <openssl/ssl.h>
        \\#include <openssl/err.h>
        \\#include <openssl/x509v3.h>
        \\
    );
    const pinned = maybe_pinned orelse {
        bindings.addIncludePath(addTransportHeaders(b, target));
        return module;
    };
    bindings.addIncludePath(pinned.output.path(b, "include"));
    module.addObjectFile(pinned.output.path(b, "lib/libnghttp2.a"));
    module.addObjectFile(pinned.output.path(b, "lib/libssl.a"));
    module.addObjectFile(pinned.output.path(b, "lib/libcrypto.a"));
    if (target.result.os.tag == .macos) {
        module.addSystemFrameworkPath(pinned.output.path(b, "sdk/System/Library/Frameworks"));
        module.addSystemIncludePath(pinned.output.path(b, "sdk/usr/include"));
        module.addLibraryPath(pinned.output.path(b, "sdk/usr/lib"));
        bindings.addSystemFrameworkPath(pinned.output.path(b, "sdk/System/Library/Frameworks"));
        bindings.addSystemIncludePath(pinned.output.path(b, "sdk/usr/include"));
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
    } else {
        module.linkSystemLibrary("pthread", .{});
        module.linkSystemLibrary("dl", .{});
    }
    return module;
}

/// The codec sandbox: WAMR's fast interpreter built from the pinned source,
/// with no AOT, JIT, WASI, threads or host functions. Software bounds checks
/// keep WAMR from installing signal handlers or reserving 8 GiB per instance.
fn addCodecRuntime(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, c_safety: bool) *std.Build.Module {
    const wamr = b.dependency("wamr", .{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/codec_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const bindings = addBindings(b, module, "wamr",
        \\#include <wasm_export.h>
        \\
    );
    bindings.addIncludePath(wamr.path("core/iwasm/include"));
    const darwin = target.result.os.tag == .macos;
    for ([_][]const u8{
        "core/iwasm/include",
        "core/iwasm/common",
        "core/iwasm/interpreter",
        "core/shared/mem-alloc",
        "core/shared/utils",
        "core/shared/platform/include",
        if (darwin) "core/shared/platform/darwin" else "core/shared/platform/linux",
    }) |path| module.addIncludePath(wamr.path(path));
    const macros = [_][2][]const u8{
        .{ "BH_MALLOC", "wasm_runtime_malloc" },
        .{ "BH_FREE", "wasm_runtime_free" },
        .{ if (darwin) "BH_PLATFORM_DARWIN" else "BH_PLATFORM_LINUX", "1" },
        .{ if (target.result.cpu.arch == .aarch64) "BUILD_TARGET_AARCH64" else "BUILD_TARGET_X86_64", "1" },
        .{ "WASM_ENABLE_INTERP", "1" },
        .{ "WASM_ENABLE_FAST_INTERP", "1" },
        .{ "WASM_ENABLE_AOT", "0" },
        .{ "WASM_ENABLE_JIT", "0" },
        .{ "WASM_ENABLE_FAST_JIT", "0" },
        .{ "WASM_ENABLE_LIBC_BUILTIN", "0" },
        .{ "WASM_ENABLE_LIBC_WASI", "0" },
        .{ "WASM_ENABLE_MULTI_MODULE", "0" },
        .{ "WASM_ENABLE_MINI_LOADER", "0" },
        .{ "WASM_ENABLE_SHARED_MEMORY", "0" },
        .{ "WASM_ENABLE_THREAD_MGR", "0" },
        .{ "WASM_ENABLE_BULK_MEMORY", "1" },
        .{ "WASM_ENABLE_REF_TYPES", "1" },
        .{ "WASM_ENABLE_SIMD", "0" },
        .{ "WASM_ENABLE_INSTRUCTION_METERING", "1" },
        .{ "WASM_DISABLE_HW_BOUND_CHECK", "1" },
        .{ "WASM_DISABLE_STACK_HW_BOUND_CHECK", "1" },
        .{ "WASM_DISABLE_WAKEUP_BLOCKING_OP", "1" },
        .{ "WASM_HAVE_MREMAP", if (darwin) "0" else "1" },
        // Otherwise WAMR guesses from Zig and Clang globals that memory above
        // the heap base is unused, and cuts it from the module.
        .{ "WASM_ENABLE_SHRUNK_MEMORY", "0" },
    };
    for (macros) |macro| module.addCMacro(macro[0], macro[1]);
    if (!darwin) module.addCMacro("_GNU_SOURCE", "1");
    module.addCSourceFiles(.{
        .root = wamr.path("."),
        .files = &.{
            "core/shared/platform/common/posix/posix_blocking_op.c",
            "core/shared/platform/common/posix/posix_malloc.c",
            "core/shared/platform/common/posix/posix_memmap.c",
            "core/shared/platform/common/posix/posix_sleep.c",
            "core/shared/platform/common/posix/posix_thread.c",
            "core/shared/platform/common/posix/posix_time.c",
            "core/shared/mem-alloc/ems/ems_alloc.c",
            "core/shared/mem-alloc/ems/ems_gc.c",
            "core/shared/mem-alloc/ems/ems_hmu.c",
            "core/shared/mem-alloc/ems/ems_kfc.c",
            "core/shared/mem-alloc/mem_alloc.c",
            "core/shared/utils/bh_assert.c",
            "core/shared/utils/bh_bitmap.c",
            "core/shared/utils/bh_common.c",
            "core/shared/utils/bh_hashmap.c",
            "core/shared/utils/bh_leb128.c",
            "core/shared/utils/bh_list.c",
            "core/shared/utils/bh_log.c",
            "core/shared/utils/bh_queue.c",
            "core/shared/utils/bh_vector.c",
            "core/shared/utils/runtime_timer.c",
            "core/iwasm/common/wasm_blocking_op.c",
            "core/iwasm/common/wasm_c_api.c",
            "core/iwasm/common/wasm_exec_env.c",
            "core/iwasm/common/wasm_loader_common.c",
            "core/iwasm/common/wasm_memory.c",
            "core/iwasm/common/wasm_native.c",
            "core/iwasm/common/wasm_runtime_common.c",
            "core/iwasm/common/wasm_shared_memory.c",
            "core/iwasm/common/arch/invokeNative_general.c",
            "core/iwasm/interpreter/wasm_interp_fast.c",
            "core/iwasm/interpreter/wasm_loader.c",
            "core/iwasm/interpreter/wasm_runtime.c",
        },
        // WAMR reads unaligned values on purpose.
        .flags = &.{ "-std=gnu99", "-ffunction-sections", "-fdata-sections", if (c_safety) "-fno-sanitize=alignment" else "-fno-sanitize=undefined" },
    });
    module.addCSourceFile(.{
        .file = wamr.path(if (darwin) "core/shared/platform/darwin/platform_init.c" else "core/shared/platform/linux/platform_init.c"),
        .flags = &.{"-std=gnu99"},
    });
    if (darwin) module.addCSourceFile(.{ .file = wamr.path("core/shared/platform/common/memory/mremap.c"), .flags = &.{"-std=gnu99"} });
    return module;
}

/// A freestanding wasm32 module from `source`, the shape a user codec takes:
/// every `export fn` exported, no imports, a 64 KiB shadow stack. ReleaseSafe,
/// as the native code it is compared with.
fn addWasmModule(b: *std.Build, name: []const u8, source: []const u8) *std.Build.Step.Compile {
    const module = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSafe,
        }),
    });
    module.entry = .disabled;
    module.rdynamic = true;
    module.stack_size = 64 * 1024;
    return module;
}

/// The pinned OpenSSL and nghttp2 headers for `target`, generated without
/// building either library.
fn addTransportHeaders(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const generate = b.addSystemCommand(&.{"sh"});
    generate.addFileArg(b.path("src/build_transport_headers.sh"));
    generate.addDirectoryArg2(b.dependency("openssl", .{}).path("."), .{ .make_absolute = true });
    generate.addDirectoryArg2(b.dependency("nghttp2", .{}).path("."), .{ .make_absolute = true });
    const target_name = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    const output = generate.addOutputDirectoryArg2(b.fmt("transport-headers-{s}", .{target_name}), .{ .make_absolute = true });
    generate.addArg(target_name);
    return output.path(b, "include");
}

fn transportEnabled(target: std.Build.ResolvedTarget) bool {
    return (target.result.os.tag == .macos or target.result.os.tag == .linux) and
        (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .x86_64);
}

fn configureSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const sqlite = b.dependency("sqlite", .{});
    const module = compile.root_module;
    if (module.root_source_file != null) {
        const bindings = addBindings(b, module, "sqlite", "#include <sqlite3.h>\n");
        bindings.addIncludePath(sqlite.path("."));
    }
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
    // Every page cache, each ephemeral table's (IN lists, RETURNING) included,
    // otherwise bulk-allocates 20 pages on first fetch: they fault in, then
    // free returns them to the kernel. Per-page allocation skips that churn.
    module.addCMacro("SQLITE_DEFAULT_PCACHE_INITSZ", "0");
    module.addCMacro("SQLITE_USE_URI", "0");
    module.addCMacro("SQLITE_ENABLE_API_ARMOR", "1");
}

fn configureBashPlatform(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/bash_platform.c"),
        .flags = &.{"-std=c11"},
    });
}

fn configureHostLaunch(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/host_launch.c"),
        .flags = &.{"-std=c11"},
    });
}

fn configureTerminalEditor(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const utf8proc = b.dependency("utf8proc", .{});
    configurePosix(b, compile.root_module);
    configureVaxis(b, compile.root_module);
    compile.root_module.link_libc = true;
    compile.root_module.addIncludePath(utf8proc.path("."));
    compile.root_module.addCSourceFile(.{
        .file = utf8proc.path("utf8proc.c"),
        .flags = &.{ "-std=c99", "-O2" },
    });
}

fn configureVaxis(b: *std.Build, module: *std.Build.Module) void {
    const dependency = b.dependency("vaxis", .{
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    const upstream = dependency.module("vaxis");
    const prepare = b.addSystemCommand(&.{"bash"});
    prepare.addFileArg(b.path("src/prepare_vaxis.sh"));
    prepare.addDirectoryArg(dependency.path("."));
    prepare.addFileArg(b.path("src/vaxis-parser.patch"));
    const patched = prepare.addOutputDirectoryArg("vaxis");
    const vaxis = b.createModule(.{
        .root_source_file = patched.path(b, "src/main.zig"),
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    var imports = upstream.import_table.iterator();
    while (imports.next()) |entry| vaxis.addImport(entry.key_ptr.*, entry.value_ptr.*);
    // Layout can import only the dependency's value-only Unicode modules,
    // without acquiring its TTY, process or event-loop capabilities.
    for ([_][]const u8{ "unicode", "gwidth" }, [_][]const u8{ "terminal_unicode", "terminal_width" }) |source, name| {
        const pure = b.createModule(.{
            .root_source_file = patched.path(b, b.fmt("src/{s}.zig", .{source})),
            .target = module.resolved_target.?,
            .optimize = module.optimize.?,
        });
        pure.addImport("uucode", upstream.import_table.get("uucode").?);
        module.addImport(name, pure);
        vaxis.addImport(name, pure);
    }
    module.addImport("vaxis", vaxis);
}

fn addBindings(b: *std.Build, module: *std.Build.Module, name: []const u8, header: []const u8) Translator {
    const bindings: Translator = .init(b.dependency("translate_c", .{ .optimize = std.builtin.OptimizeMode.ReleaseFast }), .{
        .name = name,
        .c_source_file = b.addWriteFiles().add(b.fmt("{s}.h", .{name}), header),
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    module.addImport(name, bindings.mod);
    return bindings;
}

fn configurePosix(b: *std.Build, module: *std.Build.Module) void {
    _ = addBindings(b, module, "posix",
        // Fortified variadic open wrappers are not needed by these bindings.
        \\#undef _FORTIFY_SOURCE
        \\#include <unistd.h>
        \\#include <sys/stat.h>
        \\#include <sys/resource.h>
        \\#include <termios.h>
        \\#include <fcntl.h>
        \\#include <sys/mman.h>
        \\#include <sys/wait.h>
        \\#include <signal.h>
        \\#include <stdio.h>
        \\#include <poll.h>
        \\
    );
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
