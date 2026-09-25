const std = @import("std");
const client = @import("client.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const model_adapter = @import("model_adapter.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) return serve(init, args[2..]);
    if (std.mem.eql(u8, command, "login")) return login(init, args[2..]);
    if (std.mem.eql(u8, command, "session")) try enterSession(init, args[2..]) else if (std.mem.eql(u8, command, "wait-session")) try waitSession(init, args[2..]) else if (std.mem.eql(u8, command, "configure")) try configure(init, args[2..]) else if (std.mem.eql(u8, command, "message")) try message(init, args[2..]) else if (std.mem.eql(u8, command, "stop-session")) try stopSession(init.io, args[2..]) else if (std.mem.eql(u8, command, "interrupt-model")) try interruptModel(init.io, args[2..]) else if (std.mem.eql(u8, command, "deny-action")) try decideAction(init, args[2..], .deny) else if (std.mem.eql(u8, command, "allow-action")) try decideAction(init, args[2..], .allow_once) else if (std.mem.eql(u8, command, "retry")) try retry(init.io, args[2..]) else if (std.mem.eql(u8, command, "observe-command")) try observe(init.io, args[2..]) else if (std.mem.eql(u8, command, "read-result")) try readResult(init.io, args[2..]) else if (std.mem.eql(u8, command, "read-action-call-id")) try readActionContent(init.io, args[2..], .call_id) else if (std.mem.eql(u8, command, "read-action-arguments")) try readActionArguments(init.io, args[2..]) else if (std.mem.eql(u8, command, "inspect-session")) try inspect(init.io, args[2..]) else if (std.mem.eql(u8, command, "requests")) try requests(init, args[2..]) else if (std.mem.eql(u8, command, "recover")) try recover(init, args[2..]) else if (std.mem.eql(u8, command, "follow")) try follow(init, args[2..]) else if (std.mem.eql(u8, command, "result")) try result(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-action")) try inspectAction(init, args[2..]) else return usage();
    try postCommandHold(init);
}

const post_command_ready_fd_environment = "RUI_TEST_POST_COMMAND_READY_FD";
const post_command_release_fd_environment = "RUI_TEST_POST_COMMAND_RELEASE_FD";

fn postCommandHold(init: std.process.Init) !void {
    const ready_text = init.environ_map.get(post_command_ready_fd_environment);
    const release_text = init.environ_map.get(post_command_release_fd_environment);
    if (ready_text == null and release_text == null) return;
    if (ready_text == null or release_text == null) return error.IncompletePostCommandHold;
    const ready = try std.fmt.parseInt(std.posix.fd_t, ready_text.?, 10);
    const release = try std.fmt.parseInt(std.posix.fd_t, release_text.?, 10);
    try postCommandHoldDescriptors(ready, release);
}

fn postCommandHoldDescriptors(ready: std.posix.fd_t, release: std.posix.fd_t) !void {
    defer closeDescriptor(ready);
    defer closeDescriptor(release);
    const signal = [_]u8{1};
    if (std.c.write(ready, &signal, signal.len) != 1) return error.PostCommandHoldSignalFailed;
    var acknowledgment: [1]u8 = undefined;
    if (std.c.read(release, &acknowledgment, acknowledgment.len) != 1) return error.PostCommandHoldClosed;
}

fn credentialPath(init: std.process.Init, buffer: []u8, create: bool) ![]const u8 {
    if (init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE")) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    if (create) {
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/.config/rui", .{home});
        var opened = try std.Io.Dir.cwd().createDirPathOpen(init.io, directory, .{
            .permissions = .fromMode(0o700),
        });
        opened.close(init.io);
    }
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/codex.json", .{home});
}

fn login(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "codex")) return usage();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, &path_buffer, true);
    {
        var existing = codex_credentials.load(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
    }
    try provider.initialize();
    defer provider.deinitialize();
    var tokens = try codex_auth.login(init.io, struct {
        fn display(code: []const u8) !void {
            std.debug.print("Open https://auth.openai.com/codex/device and enter code: {s}\n", .{code});
        }
    }.display);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
    var record: codex_credentials.Record = .{
        .generation = 0,
        .account_id = .{},
        .fedramp = (try codex_auth.parseAccount(tokens.id_token.slice())).fedramp,
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = (try codex_auth.parseExpiry(tokens.access_token.slice())) orelse 0,
        .refreshed_at = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s)),
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set(tokens.account_id.slice());
    try record.id_token.set(tokens.id_token.slice());
    try record.access_token.set(tokens.access_token.slice());
    try record.refresh_token.set(tokens.refresh_token.slice());
    try codex_credentials.install(path, &record, null);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Codex login installed.\n");
}

fn serve(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var provider_endpoint: ?[]const u8 = null;
    var provider_ca_file: ?[]const u8 = null;
    var managed = false;
    var fixture_endpoint: ?[]const u8 = null;
    var bash_path: []const u8 = server.default_bash_path;
    var bash_timeout_ms: u64 = server.default_bash_timeout_ms;
    var active_capacity: usize = server.default_active_capacity;
    var faults: server.Faults = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--codex")) {
            managed = true;
        } else if (std.mem.eql(u8, arg, "--test-codex-fixture-endpoint")) {
            fixture_endpoint = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider-endpoint")) {
            provider_endpoint = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider-ca-file")) {
            provider_ca_file = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--bash-path")) {
            bash_path = try takeValue(args, &index);
            if (bash_path.len == 0) return error.InvalidBashPath;
        } else if (std.mem.eql(u8, arg, "--bash-timeout-ms")) {
            bash_timeout_ms = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        } else if (std.mem.eql(u8, arg, "--test-bash-scratch-limit-bytes")) {
            faults.bash_scratch_limit_bytes = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-retention-entry-capacity")) {
            faults.retention_entry_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.retention_entry_capacity.? < 2 or
                faults.retention_entry_capacity.? > server.default_retention_entry_capacity)
            {
                return error.InvalidRetentionEntryCapacity;
            }
        } else if (std.mem.eql(u8, arg, "--test-retention-removal-failure")) {
            faults.retention_removal = true;
        } else if (std.mem.eql(u8, arg, "--active-capacity")) {
            active_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--fault")) {
            const fault = try takeValue(args, &index);
            if (std.mem.eql(u8, fault, "content-acquire")) faults.content_acquire = true else if (std.mem.eql(u8, fault, "content-write")) faults.content_write = true else if (std.mem.eql(u8, fault, "content-seal")) faults.content_seal = true else if (std.mem.eql(u8, fault, "content-read")) faults.content_read = true else if (std.mem.eql(u8, fault, "content-import")) faults.content_import = true else if (std.mem.eql(u8, fault, "before-commit")) faults.before_commit = true else if (std.mem.eql(u8, fault, "startup-cleanup")) faults.startup_cleanup = true else if (std.mem.eql(u8, fault, "shutdown-after-accept")) faults.shutdown_after_accept = true else if (std.mem.eql(u8, fault, "attempt-before-commit")) faults.attempt_before_commit = true else if (std.mem.eql(u8, fault, "result-before-commit")) faults.result_before_commit = true else if (std.mem.eql(u8, fault, "request-first-step")) faults.request_first_step = true else if (std.mem.eql(u8, fault, "request-write")) faults.request_write = true else if (std.mem.eql(u8, fault, "request-seal")) faults.request_seal = true else if (std.mem.eql(u8, fault, "request-scratch-acquire")) faults.request_scratch_acquire = true else if (std.mem.eql(u8, fault, "request-read")) faults.request_read = true else if (std.mem.eql(u8, fault, "request-unlink")) faults.request_unlink = true else if (std.mem.eql(u8, fault, "provider-prepare")) faults.provider_prepare = true else if (std.mem.eql(u8, fault, "completion-private-missing")) faults.completion_identity_fault = .missing else if (std.mem.eql(u8, fault, "completion-private-foreign")) faults.completion_identity_fault = .foreign else if (std.mem.eql(u8, fault, "completion-private-mismatch")) faults.completion_identity_fault = .mismatched else if (std.mem.eql(u8, fault, "response-acquire")) faults.response_acquire = true else if (std.mem.eql(u8, fault, "response-unlink")) faults.response_unlink = true else if (std.mem.eql(u8, fault, "response-write")) faults.response_write = true else if (std.mem.eql(u8, fault, "response-write-on-resume")) faults.response_write_on_resume = true else if (std.mem.eql(u8, fault, "response-seal")) faults.response_seal = true else if (std.mem.eql(u8, fault, "response-metadata")) faults.response_metadata = true else if (std.mem.eql(u8, fault, "response-metadata-unlink")) faults.response_metadata_unlink = true else if (std.mem.eql(u8, fault, "response-read")) faults.response_read = true else if (std.mem.eql(u8, fault, "response-import")) faults.response_import = true else if (std.mem.eql(u8, fault, "response-commit")) faults.response_commit = true else if (std.mem.eql(u8, fault, "bash-preparation")) faults.bash_preparation = true else if (std.mem.eql(u8, fault, "bash-preparation-after-script")) faults.bash_preparation_after_script = true else if (std.mem.eql(u8, fault, "bash-spawn")) faults.bash_spawn = true else if (std.mem.eql(u8, fault, "bash-service")) faults.bash_service = true else if (std.mem.eql(u8, fault, "bash-capture-read")) faults.bash_capture_read = true else if (std.mem.eql(u8, fault, "bash-capture-write")) faults.bash_capture_write = true else if (std.mem.eql(u8, fault, "bash-seal")) faults.bash_seal = true else if (std.mem.eql(u8, fault, "bash-cleanup")) faults.bash_cleanup = true else if (std.mem.eql(u8, fault, "bash-observe")) faults.bash_lifecycle_fault = .observe else if (std.mem.eql(u8, fault, "bash-reap")) faults.bash_lifecycle_fault = .reap else if (std.mem.eql(u8, fault, "bash-reap-watchdog")) faults.bash_lifecycle_fault = .reap_watchdog else if (std.mem.eql(u8, fault, "bash-group-probe")) faults.bash_lifecycle_fault = .group_probe else if (std.mem.eql(u8, fault, "bash-tail-snapshot")) faults.bash_lifecycle_fault = .tail_snapshot else if (std.mem.eql(u8, fault, "bash-signal")) faults.bash_lifecycle_fault = .signal else if (std.mem.eql(u8, fault, "bash-cleanup-watchdog")) faults.bash_lifecycle_fault = .cleanup_watchdog else if (std.mem.eql(u8, fault, "bash-fault-gated")) faults.bash_fault_gated = true else if (std.mem.eql(u8, fault, "report-unlink")) faults.report_unlink = true else return error.UnknownFault;
        } else if (std.mem.eql(u8, arg, "--test-cleanup-delay-ms")) {
            faults.cleanup_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.cleanup_delay_ms < 0 or faults.cleanup_delay_ms > 60_000) return error.InvalidCleanupDelay;
        } else if (std.mem.eql(u8, arg, "--test-provider-inactivity-seconds")) {
            faults.provider_inactivity_seconds = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.provider_inactivity_seconds < 1) return error.InvalidProviderInactivity;
            _ = std.math.mul(i64, faults.provider_inactivity_seconds, std.time.ns_per_s) catch
                return error.InvalidProviderInactivity;
        } else if (std.mem.eql(u8, arg, "--test-retry-waits-ms")) {
            faults.retry_waits_ms = try parseRetryWaits(try takeValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--test-before-launch-delay-ms")) {
            faults.before_launch_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.before_launch_delay_ms < 0 or faults.before_launch_delay_ms > 10_000) return error.InvalidLaunchDelay;
        } else if (std.mem.eql(u8, arg, "--test-before-result-delay-ms")) {
            faults.before_result_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.before_result_delay_ms < 0 or faults.before_result_delay_ms > 10_000) return error.InvalidResultDelay;
        } else if (std.mem.eql(u8, arg, "--test-inspection-reply-delay-ms")) {
            faults.inspection_reply_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.inspection_reply_delay_ms < 0 or faults.inspection_reply_delay_ms > 60_000) return error.InvalidInspectionReplyDelay;
        } else if (std.mem.eql(u8, arg, "--test-client-send-buffer-bytes")) {
            faults.client_send_buffer_bytes = try std.fmt.parseInt(u32, try takeValue(args, &index), 10);
            if (faults.client_send_buffer_bytes.? == 0 or faults.client_send_buffer_bytes.? > std.math.maxInt(c_int)) return error.InvalidClientSendBuffer;
        } else if (std.mem.eql(u8, arg, "--test-phase-trace")) {
            faults.test_phase_trace = true;
        } else if (std.mem.eql(u8, arg, "--test-transition")) {
            const transition = try takeValue(args, &index);
            if (std.mem.eql(u8, transition, "action-attempt-admitted")) faults.test_transition = .action_attempt_admitted else if (std.mem.eql(u8, transition, "action-result-ready")) faults.test_transition = .action_result_ready else if (std.mem.eql(u8, transition, "action-result-committed")) faults.test_transition = .action_result_committed else return error.UnknownTestTransition;
        } else if (std.mem.eql(u8, arg, "--test-transition-gate-path")) {
            faults.test_transition_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-model-cleanup-gate-path")) {
            faults.model_cleanup_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-response-capture-gate-path")) {
            faults.response_capture_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-response-capture-gate-min-written-bytes")) {
            faults.response_capture_gate_min_written_bytes = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-bash-observed-exit-gate-path")) {
            faults.bash_observed_exit_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-bash-cleanup-gate-path")) {
            faults.bash_cleanup_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-control-gate-keys")) {
            faults.control_gate_keys = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-control-gate-path")) {
            faults.control_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-suppress-first-control-hint")) {
            faults.suppress_first_control_hint = true;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-diagnostics")) {
            faults.sqlite_diagnostics = true;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-cache-spill-off")) {
            faults.sqlite_cache_spill = false;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-cache-kib")) {
            faults.sqlite_cache_kib = try std.fmt.parseInt(u32, try takeValue(args, &index), 10);
            if (faults.sqlite_cache_kib == 0 or faults.sqlite_cache_kib > 4096) return error.InvalidSqliteCacheSize;
        } else if (std.mem.eql(u8, arg, "--test-request-scratch-limit")) {
            faults.request_scratch_limit_bytes = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-byte-allowance")) {
            faults.request_preparation_byte_allowance = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.request_preparation_byte_allowance == 0) return error.InvalidRequestPreparationAllowance;
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-item-allowance")) {
            faults.request_preparation_item_allowance = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.request_preparation_item_allowance == 0) return error.InvalidRequestPreparationAllowance;
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-advance-delay-ms")) {
            faults.request_preparation_advance_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.request_preparation_advance_delay_ms < 0) return error.InvalidRequestPreparationDelay;
        } else return error.UnknownArgument;
        index += 1;
    }
    if ((faults.control_gate_keys == null) != (faults.control_gate_path == null)) return error.IncompleteControlGate;
    if ((faults.test_transition == null) != (faults.test_transition_gate_path == null)) return error.IncompleteTestTransitionGate;
    if ((managed and (provider_endpoint != null or provider_ca_file != null or fixture_endpoint != null)) or
        (fixture_endpoint != null and provider_endpoint != null)) return error.ManagedDevelopmentEndpointConflict;
    if (fixture_endpoint != null and init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE") == null)
        return error.FixtureCredentialPathRequired;
    var credential_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const credential_path: ?[]const u8 = if (managed or fixture_endpoint != null) try credentialPath(init, &credential_path_buffer, false) else null;
    return server.serve(
        io,
        std.heap.c_allocator,
        store_path orelse return usage(),
        active_capacity,
        faults,
        if (managed) model_adapter.managed_endpoint else fixture_endpoint orelse provider_endpoint,
        provider_ca_file,
        if (credential_path) |path| model_adapter.Authentication{ .path = path, .fixture = fixture_endpoint != null } else null,
        bash_path,
        bash_timeout_ms,
    );
}

fn parseRetryWaits(value: []const u8) ![3]u64 {
    var waits: [3]u64 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&waits) |*wait| {
        const part = parts.next() orelse return error.InvalidRetryWaits;
        wait.* = std.fmt.parseInt(u64, part, 10) catch return error.InvalidRetryWaits;
        if (wait.* == 0 or wait.* > std.math.maxInt(i64)) return error.InvalidRetryWaits;
    }
    if (parts.next() != null) return error.InvalidRetryWaits;
    return waits;
}

fn configure(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var json = false;
    var input = client.ConfigureInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
    };
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            input.provider = .{ .present = true, .value = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.session.len == 0 or (input.record.len == 0) != !key_seen) return usage();
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.configure(io, input, &reply_buffer);
    if (human) try writeAdmission(io, reply, if (json) input.record else null) else try writeCommandReply(io, reply);
    if (human and !json) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "configuration: {s} in {s}\n", .{ input.session, input.store }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, "next: rui session (same Store and Session)\n");
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn message(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var json = false;
    var input = client.MessageInput{ .store = "", .record = "", .key = "", .session = "", .text_path = "" };
    var positional: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else if (positional == null and (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-"))) positional = arg else return error.UnknownArgument;
        index += 1;
    }
    if (positional) |value| {
        if (key_seen or input.text_path.len != 0) return usage();
        if (std.mem.eql(u8, value, "-")) input.text_path = "-" else input.text = value;
    }
    if (input.store.len == 0 or input.session.len == 0 or (input.text_path.len == 0 and input.text == null) or (input.record.len == 0) != !key_seen) return usage();
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.message(io, input, &reply_buffer);
    if (human) try writeAdmission(io, reply, if (json) input.record else null) else try writeCommandReply(io, reply);
    if (human and !json) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 112]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "message: {s} in {s}\n", .{ input.session, input.store }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "next: rui follow {s}\n", .{input.key}));
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn selectedRequest(store: []const u8, session_ref: []const u8, key: []const u8) !SavedRequest {
    var saved: SavedRequest = .{};
    try saved.store.set(store);
    try saved.session.set(session_ref);
    try saved.key.set(key);
    try saved.kind.set("message");
    return saved;
}

fn acceptedReply(reply: client.CommandReply) !bool {
    if (reply.status != 200) return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    return std.mem.eql(u8, try stringField(try objectField(parsed.value, "answer"), "status"), "accepted");
}

fn waitSession(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var json = false;
    var terminal_only = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session_ref = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--terminal")) terminal_only = true else if (std.mem.eql(u8, args[index], "--json")) json = true else return error.UnknownArgument;
    }
    _ = waitForSession(init, store orelse return usage(), session_ref orelse return usage(), json, terminal_only) catch |err| {
        if (err == error.SessionNotConfigured) std.debug.print("rui: configure this Session before waiting for it\n", .{});
        return err;
    };
}

fn waitForSession(init: std.process.Init, store: []const u8, session_ref: []const u8, json: bool, terminal_only: bool) !?Work {
    const work = try inspectWork(init, store, session_ref);
    if (work.workspace.len == 0) return error.SessionNotConfigured;
    if (work.selected_message.len == 0) {
        if (json) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "{\"return\":\"idle\"}\n");
        } else try std.Io.File.stdout().writeStreamingAll(init.io, "return: idle (no active or queued message)\n");
        return null;
    }
    if (json) {
        const selection = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
            .event = "selection",
            .session = session_ref,
            .message = work.selected_message.slice(),
        }, .{});
        defer std.heap.c_allocator.free(selection);
        try std.Io.File.stdout().writeStreamingAll(init.io, selection);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    } else {
        var line: [protocol.max_key_bytes + 32]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "selected message: {s}\n", .{work.selected_message.slice()}));
    }
    const saved = try selectedRequest(store, session_ref, work.selected_message.slice());
    var attention = try followMessage(init, &saved, json, true, terminal_only);
    if (attention) |*pending| pending.selected_message = work.selected_message;
    if (attention == null and !json) try showResult(init, &saved, false);
    return attention;
}

fn showSessionStatus(init: std.process.Init, store: []const u8, session_ref: []const u8) !void {
    const work = try inspectWork(init, store, session_ref);
    if (work.workspace.len == 0) return error.SessionNotConfigured;
    var line: [protocol.max_store_bytes + protocol.max_session_bytes + protocol.max_workspace_bytes + 160]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Session: {s}\nStore: {s}\nWorkspace (Bash cwd): {s}\nPermission: {s}\nWork: {s}\n", .{ session_ref, store, work.workspace.slice(), work.permission_mode.slice(), work.status.slice() }));
    if (work.selected_message.len != 0)
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Current message: {s}\n", .{work.selected_message.slice()}));
    if (work.action.len != 0)
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Action requiring attention: {s}\n", .{work.action.slice()}));
    if (work.recent_count != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Recent messages (use /result KEY for an answer):\n");
        for (work.recent[0..work.recent_count]) |recent| {
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "  {s}: {s}\n", .{ recent.key.slice(), recent.outcome.slice() }));
        }
    }
}

fn sessionMessage(init: std.process.Init, store: []const u8, session_ref: []const u8, text: []const u8) !?Work {
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const record = try newRequest(init, &record_buffer, &key_buffer);
    const input = client.MessageInput{
        .store = store,
        .session = session_ref,
        .record = record,
        .key = &key_buffer,
        .text_path = "",
        .text = text,
        .captured = announceCapture,
    };
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.message(init.io, input, &reply_buffer);
    try writeAdmission(init.io, reply, null);
    if (reply.status != 200) return error.MessageNotAdmitted;
    if (!try acceptedReply(reply)) return null;
    const saved = try selectedRequest(store, session_ref, &key_buffer);
    var attention = try followMessage(init, &saved, false, false, false);
    if (attention) |*pending| try pending.selected_message.set(&key_buffer);
    if (attention == null) try showResult(init, &saved, false);
    return attention;
}

fn enterSession(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session_ref = try takeValue(args, &index) else return error.UnknownArgument;
    }
    const destination = store orelse return usage();
    const reference = session_ref orelse return usage();
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        std.debug.print("rui session needs terminal input and output; use one-shot commands for scripts\n", .{});
        return error.InteractiveTerminalRequired;
    }
    showSessionStatus(init, destination, reference) catch |err| {
        if (err == error.SessionNotConfigured) std.debug.print("rui: configure this Session before entering it\n", .{});
        return err;
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, "Type a message or /help. /exit detaches without stopping work.\n");
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    while (true) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "rui> ");
        const line = (input.interface.takeDelimiter('\n') catch |err| {
            if (err == error.StreamTooLong) std.debug.print("rui: terminal line exceeds 64 KiB; nothing sent. Use rui message --text FILE for longer input.\n", .{});
            return err;
        }) orelse break;
        const text = std.mem.trimEnd(u8, line, "\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/exit")) break;
        if (std.mem.eql(u8, text, "/help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "/status  /wait  /requests  /result KEY  /configure [settings]  /exit\nMessages are submitted as written. To send a leading /, prefix it with //; use the one-shot --text FILE for longer input.\n");
            continue;
        }
        const attention: ?Work = if (std.mem.eql(u8, text, "/status")) blk: {
            showSessionStatus(init, destination, reference) catch |err| std.debug.print("rui: status: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/requests")) blk: {
            sessionRequests(init, destination, reference) catch |err| std.debug.print("rui: requests: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/wait"))
            waitForSession(init, destination, reference, false, false) catch |err| blk: {
                std.debug.print("rui: wait: {s}\n", .{@errorName(err)});
                break :blk null;
            }
        else if (std.mem.startsWith(u8, text, "/result ")) blk: {
            const saved = selectedRequest(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
                std.debug.print("rui: result key: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            showResult(init, &saved, false) catch |err| std.debug.print("rui: result: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/configure") or std.mem.startsWith(u8, text, "/configure ")) blk: {
            var config_args: [24][]const u8 = undefined;
            config_args[0..4].* = .{ "--store", destination, "--session", reference };
            var count: usize = 4;
            var tokens = std.mem.tokenizeScalar(u8, text["/configure".len..], ' ');
            var valid = true;
            while (tokens.next()) |flag| {
                const takes_value = std.mem.eql(u8, flag, "--workspace") or std.mem.eql(u8, flag, "--provider") or
                    std.mem.eql(u8, flag, "--model") or std.mem.eql(u8, flag, "--instructions") or
                    std.mem.eql(u8, flag, "--tools") or std.mem.eql(u8, flag, "--permission-mode") or
                    std.mem.eql(u8, flag, "--output-schema");
                if (!takes_value and !std.mem.eql(u8, flag, "--text-output")) {
                    valid = false;
                    break;
                }
                const value = if (takes_value) tokens.next() else null;
                if ((takes_value and value == null) or count + (if (takes_value) @as(usize, 2) else 1) > config_args.len) {
                    valid = false;
                    break;
                }
                config_args[count] = flag;
                count += 1;
                if (value) |setting| {
                    config_args[count] = setting;
                    count += 1;
                }
            }
            if (valid and count > 4) {
                configure(init, config_args[0..count]) catch |err| std.debug.print("rui: configure: {s}\n", .{@errorName(err)});
            } else try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
            break :blk null;
        } else if (std.mem.startsWith(u8, text, "/")) blk: {
            if (std.mem.startsWith(u8, text, "//")) break :blk sessionMessage(init, destination, reference, text[1..]) catch |err| {
                std.debug.print("rui: message: {s}; check /requests before resubmitting\n", .{@errorName(err)});
                break :blk null;
            };
            try std.Io.File.stdout().writeStreamingAll(init.io, "Unknown command. Type /help.\n");
            break :blk null;
        } else sessionMessage(init, destination, reference, text) catch |err| blk: {
            std.debug.print("rui: message: {s}; check /requests before resubmitting\n", .{@errorName(err)});
            break :blk null;
        };
        if (attention) |action| interactiveAction(init, destination, reference, action, &input.interface) catch |err|
            std.debug.print("rui: Action observation or decision failed: {s}; check /requests and /status\n", .{@errorName(err)});
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "Detached. Host work continues.\n");
}

fn interactiveAction(init: std.process.Init, store: []const u8, session_ref: []const u8, initial: Work, reader: *std.Io.Reader) !void {
    const saved = try selectedRequest(store, session_ref, initial.selected_message.slice());
    var pending: ?Work = initial;
    while (pending) |work| {
        if (work.action.len == 0) return;
        const id = try std.fmt.parseInt(u64, work.action.slice(), 10);
        try inspectAction(init, &.{ "--store", store, "--session", session_ref, "--action", work.action.slice() });
        try std.Io.File.stdout().writeStreamingAll(init.io, "Allow once, deny, or later? [a/d/l] ");
        const choice = (try reader.takeDelimiter('\n')) orelse return;
        const selection = std.mem.trim(u8, choice, " \r");
        const decision: protocol.PermissionDecision = if (std.mem.eql(u8, selection, "a")) .allow_once else if (std.mem.eql(u8, selection, "d")) .deny else {
            try std.Io.File.stdout().writeStreamingAll(init.io, "No decision sent; use /wait to revisit.\n");
            return;
        };
        var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var key_buffer: [36]u8 = undefined;
        const record = try newRequest(init, &record_buffer, &key_buffer);
        var reply_buffer: client.ReplyBuffer = .{};
        const reply = try client.denyPermission(init.io, .{
            .store = store,
            .session = session_ref,
            .record = record,
            .key = &key_buffer,
            .action_id = id,
            .decision = decision,
            .captured = announceCapture,
        }, &reply_buffer);
        try writeAdmission(init.io, reply, null);
        if (reply.status != 200) return;
        if (!try acceptedReply(reply)) return;
        pending = try followMessage(init, &saved, false, false, false);
        if (pending == null) try showResult(init, &saved, false);
    }
}

fn sessionRequests(init: std.process.Init, store: []const u8, session_ref: []const u8) !void {
    const canonical = try platform.resolveClientPaths(init.io, store);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Local recovery handles (not Host work status):\n");
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        const saved = savedRequest(init, handle) catch continue;
        if (!saved.store.eql(canonical.store.slice()) or !saved.session.eql(session_ref)) continue;
        var line: [100]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "  {s} ({s})\n", .{ handle, saved.kind.slice() }));
    }
}

fn stopSession(io: std.Io, args: []const []const u8) !void {
    var input = client.SessionStopInput{ .store = "", .record = "", .key = "", .session = "" };
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or !key_seen) return usage();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.stopSession(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn interruptModel(io: std.Io, args: []const []const u8) !void {
    var input = client.ModelInterruptionInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
        .turn_id = 0,
        .operation_id = 0,
    };
    var key_seen = false;
    var turn_seen = false;
    var operation_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--turn")) {
            input.turn_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            turn_seen = true;
        } else if (std.mem.eql(u8, arg, "--operation")) {
            input.operation_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            operation_seen = true;
        } else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or
        !key_seen or !turn_seen or !operation_seen) return usage();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.interruptModel(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn decideAction(init: std.process.Init, args: []const []const u8, decision: @FieldType(client.PermissionDecisionInput, "decision")) !void {
    const io = init.io;
    var json = false;
    var input = client.PermissionDecisionInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
        .action_id = 0,
        .decision = decision,
    };
    var key_seen = false;
    var action_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--action")) {
            input.action_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.session.len == 0 or !action_seen or (input.record.len == 0) != !key_seen) return usage();
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.denyPermission(io, input, &reply_buffer);
    if (human) try writeAdmission(io, reply, if (json) input.record else null) else try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn retry(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var record: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--kind")) kind = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.retry(io, store_path orelse return usage(), record orelse return usage(), kind orelse return usage(), &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn observe(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.observeCommand(io, store_path orelse return usage(), key orelse return usage(), &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200) return error.HostInvocationFailed;
}

fn inspect(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var profile: protocol.ReportProfile = .current;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--session")) {
            session = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const value = try takeValue(args, &index);
            profile = if (std.mem.eql(u8, value, "current"))
                .current
            else if (std.mem.eql(u8, value, "full"))
                .full
            else
                return error.UnknownReportProfile;
        } else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(
        io,
        store_path orelse return usage(),
        session orelse return usage(),
        profile,
        std.Io.File.stdout(),
        &reply_buffer,
    );
    switch (reply) {
        .report => try std.Io.File.stdout().writeStreamingAll(io, "\n"),
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn readResult(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.readResult(
        io,
        store_path orelse return usage(),
        key orelse return usage(),
        std.Io.File.stdout(),
        &reply_buffer,
    );
    switch (reply) {
        .answer => {},
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn readActionArguments(io: std.Io, args: []const []const u8) !void {
    return readActionContent(io, args, .arguments);
}

fn readActionContent(io: std.Io, args: []const []const u8, field: enum { call_id, arguments }) !void {
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var action: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--session")) session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--action")) action = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = switch (field) {
        .call_id => try client.readActionCallId(io, store_path orelse return usage(), session orelse return usage(), action orelse return usage(), std.Io.File.stdout(), &reply_buffer),
        .arguments => try client.readActionArguments(io, store_path orelse return usage(), session orelse return usage(), action orelse return usage(), std.Io.File.stdout(), &reply_buffer),
    };
    switch (reply) {
        .answer => {},
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn writeCommandReply(io: std.Io, reply: client.CommandReply) !void {
    try std.Io.File.stdout().writeStreamingAll(io, reply.body);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn requestDirectory(init: std.process.Init, buffer: []u8) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/requests", .{home});
}

fn newRequest(init: std.process.Init, path: []u8, key: *[36]u8) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const id = try std.fmt.bufPrint(key, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        std.mem.readInt(u32, bytes[0..4], .big),
        std.mem.readInt(u16, bytes[4..6], .big),
        std.mem.readInt(u16, bytes[6..8], .big),
        std.mem.readInt(u16, bytes[8..10], .big),
        std.mem.readInt(u48, bytes[10..16], .big),
    });
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    return std.fmt.bufPrint(path, "{s}/{s}.json", .{ directory, id });
}

fn announceCapture(io: std.Io, record: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    const name = std.fs.path.basename(record);
    try std.Io.File.stdout().writeStreamingAll(io, "request: ");
    try std.Io.File.stdout().writeStreamingAll(io, name[0 .. name.len - ".json".len]);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn announceCaptureJson(io: std.Io, record: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    const name = std.fs.path.basename(record);
    var line: [96]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"event\":\"captured\",\"request\":\"{s}\"}}\n", .{name[0 .. name.len - ".json".len]}));
}

fn testGate(io: std.Io, name: [*:0]const u8) !void {
    const gate = std.c.getenv(name) orelse return;
    const path = std.mem.span(gate);
    var ready_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var release_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "{s}.ready", .{path});
    const release = try std.fmt.bufPrint(&release_buffer, "{s}.release", .{path});
    const marker = try std.Io.Dir.cwd().createFile(io, ready, .{ .exclusive = true });
    marker.close(io);
    while (true) {
        if (std.Io.Dir.cwd().statFile(io, release, .{})) |_| break else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

fn writeAdmission(io: std.Io, reply: client.CommandReply, json_record: ?[]const u8) !void {
    if (json_record) |record| {
        const name = std.fs.path.basename(record);
        var line: [112]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"event\":\"admission\",\"request\":\"{s}\",\"admission\":", .{name[0 .. name.len - ".json".len]}));
        try std.Io.File.stdout().writeStreamingAll(io, reply.body);
        return std.Io.File.stdout().writeStreamingAll(io, "}\n");
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    const answer = try objectField(parsed.value, "answer");
    const status = try stringField(answer, "status");
    var line: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "admitted: {s}\n", .{status}));
    const replayed = try objectField(answer, "replayed");
    if (replayed != .bool) return error.InvalidObservation;
    try std.Io.File.stdout().writeStreamingAll(io, if (replayed.bool) "replayed: true\n" else "replayed: false\n");
    if (answer.object.get("code")) |code| {
        if (code != .string) return error.InvalidObservation;
        try std.Io.File.stdout().writeStreamingAll(io, "code: ");
        try std.Io.File.stdout().writeStreamingAll(io, code.string);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    }
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidObservation;
    return value.object.get(name) orelse error.InvalidObservation;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const field = try objectField(value, name);
    if (field != .string) return error.InvalidObservation;
    return field.string;
}

const SavedRequest = struct {
    path: protocol.Bounded(std.Io.Dir.max_path_bytes) = .{},
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    kind: protocol.Bounded(32) = .{},
};

fn requestPath(init: std.process.Init, handle: []const u8, buffer: []u8) ![]const u8 {
    if (handle.len != 36) return error.InvalidRequestHandle;
    for (handle, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidRequestHandle;
        } else if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRequestHandle;
    }
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}.json", .{ directory, handle });
}

fn savedRequest(init: std.process.Init, handle: []const u8) !SavedRequest {
    var value: SavedRequest = .{};
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(init, handle, &path_buffer);
    try value.path.set(path);
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    // The capture owner writes these bounded identity fields before any
    // variable content. JSON escaping can expand each input byte sixfold.
    const header_bytes = 6 * (protocol.max_store_bytes + protocol.max_key_bytes + protocol.max_session_bytes) + 256;
    var buffer: [header_bytes]u8 = undefined;
    const count = try file.readPositionalAll(init.io, &buffer, 0);
    const prefix = buffer[0..count];
    const kind_marker = std.mem.indexOf(u8, prefix, ",\"configuration\"") orelse
        std.mem.indexOf(u8, prefix, ",\"text\"") orelse
        std.mem.indexOf(u8, prefix, ",\"decision\"") orelse
        return error.InvalidRequestRecord;
    var head: [header_bytes]u8 = undefined;
    if (kind_marker + 1 > head.len) return error.InvalidRequestRecord;
    @memcpy(head[0..kind_marker], prefix[0..kind_marker]);
    head[kind_marker] = '}';
    const Fields = struct {
        version: []const u8,
        kind: []const u8,
        store: []const u8,
        key: []const u8,
        session: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Fields, std.heap.c_allocator, head[0 .. kind_marker + 1], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, "1") or !std.mem.eql(u8, parsed.value.key, handle)) return error.InvalidRequestRecord;
    try value.store.set(parsed.value.store);
    try value.key.set(parsed.value.key);
    try value.session.set(parsed.value.session);
    try value.kind.set(parsed.value.kind);
    if (!value.kind.eql("configure") and !value.kind.eql("message") and
        !value.kind.eql("permission_decision")) return error.InvalidRequestRecord;
    return value;
}

fn requests(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 1 and std.mem.eql(u8, args[0], "--json");
    if (args.len != 0 and !json) return usage();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return if (json) std.Io.File.stdout().writeStreamingAll(init.io, "[]\n") else {},
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    if (json) try std.Io.File.stdout().writeStreamingAll(init.io, "[");
    var first = true;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = requestPath(init, handle, &path_buffer) catch continue;
        if (json) {
            if (!first) try std.Io.File.stdout().writeStreamingAll(init.io, ",");
            var line: [64]u8 = undefined;
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "\"{s}\"", .{handle}));
        } else {
            try std.Io.File.stdout().writeStreamingAll(init.io, handle);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        first = false;
    }
    if (json) try std.Io.File.stdout().writeStreamingAll(init.io, "]\n");
}

fn recover(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    const kind = if (saved.kind.eql("permission_decision")) "permission-decision" else saved.kind.slice();
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.retry(init.io, saved.store.slice(), saved.path.slice(), kind, &buffer);
    if (json) try writeCommandReply(init.io, reply) else try writeAdmission(init.io, reply, null);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn result(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    try showResult(init, &saved, json);
}

fn showResult(init: std.process.Init, saved: *const SavedRequest, json: bool) !void {
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.observeCommand(init.io, saved.store.slice(), saved.key.slice(), &buffer);
    if (reply.status != 200) return error.ObservationFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    const observation = try objectField(parsed.value, "observation");
    const status = try stringField(observation, "status");
    if (std.mem.eql(u8, status, "absent")) return error.RequestNotAdmitted;
    if (!std.mem.eql(u8, try stringField(observation, "kind"), "message") or
        !std.mem.eql(u8, try stringField(observation, "target"), saved.session.slice())) return error.RequestBindingMismatch;
    const observation_json = if (json) try std.json.Stringify.valueAlloc(std.heap.c_allocator, observation, .{}) else "";
    defer if (json) std.heap.c_allocator.free(observation_json);
    const result_value = observation.object.get("result");
    const state = if (std.mem.eql(u8, status, "rejected")) "rejected" else if (result_value) |value| try stringField(value, "status") else if (observation.object.get("queue")) |queue| try stringField(queue, "status") else "accepted";
    if (!json) {
        var line: [256]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "result: {s}\n", .{state}));
        const details = if (std.mem.eql(u8, state, "rejected")) observation else result_value;
        if (details) |value| {
            if (value.object.get("code")) |code| {
                if (code != .string) return error.InvalidObservation;
                try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "code: {s}\n", .{code.string}));
            }
        }
    }
    if (!std.mem.eql(u8, state, "completed")) {
        if (json) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
            try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
            try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":null}\n");
        }
        return;
    }
    if (json) {
        const file = try renderScratch(init);
        defer file.close(init.io);
        var read_buffer: client.ReplyBuffer = .{};
        const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), file, &read_buffer);
        if (answer != .answer) return error.ResultReadFailed;
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
        try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":\"");
        try writeJsonFileAt(init.io, file, 0, answer.answer.bytes, false);
        return std.Io.File.stdout().writeStreamingAll(init.io, "\"}\n");
    }
    var read_buffer: client.ReplyBuffer = .{};
    const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), std.Io.File.stdout(), &read_buffer);
    switch (answer) {
        .answer => {},
        .command => return error.ResultReadFailed,
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const Work = struct {
    const Recent = struct {
        key: protocol.Bounded(protocol.max_key_bytes) = .{},
        outcome: protocol.Bounded(96) = .{},
    };

    status: protocol.Bounded(32) = .{},
    turn: protocol.Bounded(32) = .{},
    action: protocol.Bounded(32) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    permission_mode: protocol.Bounded(16) = .{},
    selected_message: protocol.Bounded(protocol.max_key_bytes) = .{},
    recent: [10]Recent = [_]Recent{.{}} ** 10,
    recent_count: usize = 0,
};

fn renderScratch(init: std.process.Init) !std.Io.File {
    const path = init.environ_map.get("TMPDIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(path)) return error.InvalidTemporaryDirectory;
    const dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    return createRenderScratch(init.io, dir, false);
}

fn createRenderScratch(io: std.Io, dir: std.Io.Dir, fail_unlink: bool) !std.Io.File {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "rui-render-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    // Scratch is descriptor-owned: interrupted clients leave no named payload.
    if (fail_unlink) return error.RenderScratchCleanupFailed;
    dir.deleteFile(io, name) catch return error.RenderScratchCleanupFailed;
    return file;
}

fn tokenString(token: std.json.Token) ![]const u8 {
    return switch (token) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.InvalidObservation,
    };
}

fn freeToken(token: std.json.Token) void {
    if (token == .allocated_string) std.heap.c_allocator.free(token.allocated_string);
}

fn readWork(reader: *std.json.Reader) !Work {
    var work: Work = .{};
    if ((try reader.next()) != .object_begin) return error.InvalidObservation;
    while (true) {
        const name = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
        defer freeToken(name);
        if (name == .object_end) break;
        const field = try tokenString(name);
        if (std.mem.eql(u8, field, "session")) {
            if ((try reader.peekNextTokenType()) == .null) {
                _ = try reader.next();
                continue;
            }
            if ((try reader.next()) != .object_begin) return error.InvalidObservation;
            while (true) {
                const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(inner);
                if (inner == .object_end) break;
                const key = try tokenString(inner);
                if (std.mem.eql(u8, key, "workspace") or std.mem.eql(u8, key, "permission_mode")) {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_workspace_bytes);
                    defer freeToken(value);
                    if (std.mem.eql(u8, key, "workspace")) try work.workspace.set(try tokenString(value)) else try work.permission_mode.set(try tokenString(value));
                } else try reader.skipValue();
            }
        } else if (std.mem.eql(u8, field, "selected_message")) {
            const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_key_bytes);
            defer freeToken(value);
            if (value != .null) try work.selected_message.set(try tokenString(value));
        } else if (std.mem.eql(u8, field, "recent_messages")) {
            if ((try reader.next()) != .array_begin) return error.InvalidObservation;
            while (true) {
                const item = try reader.next();
                if (item == .array_end) break;
                if (item != .object_begin or work.recent_count == work.recent.len) return error.InvalidObservation;
                const recent = &work.recent[work.recent_count];
                while (true) {
                    const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                    defer freeToken(inner);
                    if (inner == .object_end) break;
                    const key = try tokenString(inner);
                    if (std.mem.eql(u8, key, "message") or std.mem.eql(u8, key, "outcome")) {
                        const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_key_bytes);
                        defer freeToken(value);
                        if (std.mem.eql(u8, key, "message")) try recent.key.set(try tokenString(value)) else try recent.outcome.set(try tokenString(value));
                    } else try reader.skipValue();
                }
                if (recent.key.len == 0 or recent.outcome.len == 0) return error.InvalidObservation;
                work.recent_count += 1;
            }
        } else if (std.mem.eql(u8, field, "work")) {
            if ((try reader.next()) != .object_begin) return error.InvalidObservation;
            while (true) {
                const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(inner);
                if (inner == .object_end) break;
                const key = try tokenString(inner);
                if (std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "turn")) {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                    defer freeToken(value);
                    if (std.mem.eql(u8, key, "status")) try work.status.set(try tokenString(value)) else try work.turn.set(try tokenString(value));
                } else try reader.skipValue();
            }
        } else if (std.mem.eql(u8, field, "actionable_permissions")) {
            if ((try reader.next()) != .array_begin) return error.InvalidObservation;
            while (true) {
                const item = try reader.next();
                if (item == .array_end) break;
                if (item != .object_begin) return error.InvalidObservation;
                while (true) {
                    const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                    defer freeToken(inner);
                    if (inner == .object_end) break;
                    if (std.mem.eql(u8, try tokenString(inner), "action")) {
                        const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                        defer freeToken(value);
                        if (work.action.len == 0) try work.action.set(try tokenString(value));
                    } else try reader.skipValue();
                }
            }
        } else try reader.skipValue();
    }
    if (work.status.len == 0 or (try reader.next()) != .end_of_document) return error.InvalidObservation;
    return work;
}

fn inspectWork(init: std.process.Init, store: []const u8, session_ref: []const u8) !Work {
    const file = try renderScratch(init);
    defer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(init.io, store, session_ref, .current, file, &response);
    switch (reply) {
        .report => {},
        .command => return error.ObservationFailed,
    }
    var input_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var json_reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer json_reader.deinit();
    return readWork(&json_reader);
}

fn writeFollowOutcome(init: std.process.Init, observation: std.json.Value, json: bool) !void {
    if (json) {
        const observation_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, observation, .{});
        defer std.heap.c_allocator.free(observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"return\":\"outcome\",\"observation\":");
        try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "}\n");
    } else {
        const status = try stringField(observation, "status");
        const state = if (std.mem.eql(u8, status, "rejected")) "rejected" else try stringField(try objectField(observation, "result"), "status");
        var line: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: outcome\nstatus: {s}\n", .{state}));
    }
}

fn follow(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    _ = try followMessage(init, &saved, json, false, false);
}

// null is the selected message's terminal observation; an Action is only a hint
// to inspect and decide against the Host's exact current target.
fn followMessage(init: std.process.Init, saved: *const SavedRequest, json: bool, session_wait: bool, terminal_only: bool) !?Work {
    while (true) {
        var response: client.ReplyBuffer = .{};
        const reply = try client.observeCommand(init.io, saved.store.slice(), saved.key.slice(), &response);
        if (reply.status != 200) return error.ObservationFailed;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
        defer parsed.deinit();
        const observation = try objectField(parsed.value, "observation");
        const status = try stringField(observation, "status");
        if (std.mem.eql(u8, status, "absent")) return error.RequestNotAdmitted;
        if (!std.mem.eql(u8, try stringField(observation, "kind"), "message") or
            !std.mem.eql(u8, try stringField(observation, "target"), saved.session.slice())) return error.RequestBindingMismatch;
        if (std.mem.eql(u8, status, "rejected") or observation.object.contains("result")) {
            try writeFollowOutcome(init, observation, json);
            return null;
        }
        const processing = observation.object.get("processing");
        const queue = try objectField(observation, "queue");
        if (processing != null or std.mem.eql(u8, try stringField(queue, "status"), "queued")) {
            // Test-only pause after observing the key, before reading Session Current.
            try testGate(init.io, "RUI_TEST_FOLLOW_GATE");
            const work = try inspectWork(init, saved.store.slice(), saved.session.slice());
            if (work.action.len != 0 and work.turn.len != 0) {
                var fresh_response: client.ReplyBuffer = .{};
                const fresh_reply = try client.observeCommand(init.io, saved.store.slice(), saved.key.slice(), &fresh_response);
                if (fresh_reply.status != 200) return error.ObservationFailed;
                var fresh_parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, fresh_reply.body, .{});
                defer fresh_parsed.deinit();
                const fresh = try objectField(fresh_parsed.value, "observation");
                const fresh_status = try stringField(fresh, "status");
                if (std.mem.eql(u8, fresh_status, "absent")) return error.RequestNotAdmitted;
                if (!std.mem.eql(u8, try stringField(fresh, "kind"), "message") or
                    !std.mem.eql(u8, try stringField(fresh, "target"), saved.session.slice())) return error.RequestBindingMismatch;
                if (std.mem.eql(u8, fresh_status, "rejected") or fresh.object.contains("result")) {
                    try writeFollowOutcome(init, fresh, json);
                    return null;
                }
                const fresh_processing = fresh.object.get("processing");
                const fresh_queue = try objectField(fresh, "queue");
                if (!terminal_only and (!session_wait or work.status.eql("waiting_for_permission")) and
                    (std.mem.eql(u8, try stringField(fresh_queue, "status"), "queued") or
                        (fresh_processing != null and std.mem.eql(u8, work.turn.slice(), try stringField(fresh_processing.?, "turn")))))
                {
                    if (json) {
                        var line: [160]u8 = undefined;
                        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "{{\"return\":\"attention\",\"status\":\"{s}\",\"action\":\"{s}\"}}\n", .{ work.status.slice(), work.action.slice() }));
                    } else {
                        var line: [160]u8 = undefined;
                        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: attention\nstatus: {s}\naction: {s}\n", .{ work.status.slice(), work.action.slice() }));
                    }
                    return work;
                }
            }
        }
        try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
}

fn inspectAction(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var action: ?u64 = null;
    var json = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--action")) action = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, args[index], "--json")) json = true else return error.UnknownArgument;
    }
    const target = action orelse return usage();
    const file = try renderScratch(init);
    defer file.close(io);
    var buffer: client.ReplyBuffer = .{};
    const call = try client.readActionCallId(io, store orelse return usage(), session orelse return usage(), target, file, &buffer);
    if (call != .answer) return error.ActionReadFailed;
    const arguments = try client.readActionArguments(io, store.?, session.?, target, file, &buffer);
    if (arguments != .answer) return error.ActionReadFailed;
    var line: [96]u8 = undefined;
    if (json) {
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"action\":\"{d}\",\"call_id\":\"", .{target}));
        try writeJsonFileAt(io, file, 0, call.answer.bytes, false);
        try std.Io.File.stdout().writeStreamingAll(io, "\",\"arguments\":\"");
        try writeJsonFileAt(io, file, call.answer.bytes, arguments.answer.bytes, false);
        return std.Io.File.stdout().writeStreamingAll(io, "\"}\n");
    }
    // Provider-controlled fields must not rewrite the approval display.
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "Action {d}\ncall ID: \"", .{target}));
    try writeJsonFileAt(io, file, 0, call.answer.bytes, true);
    try std.Io.File.stdout().writeStreamingAll(io, "\"\nBash arguments: \"");
    try writeJsonFileAt(io, file, call.answer.bytes, arguments.answer.bytes, true);
    try std.Io.File.stdout().writeStreamingAll(io, "\"\n");
}

fn writeJsonFileAt(io: std.Io, file: std.Io.File, start: u64, length: u64, escape_unicode: bool) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    var chunk: [protocol.content_window_bytes + 3]u8 = undefined;
    var offset: u64 = 0;
    var carry: usize = 0;
    while (offset < length) {
        const n = try file.readPositionalAll(io, chunk[carry..][0..@intCast(@min(length - offset, chunk.len - carry))], start + offset);
        if (n == 0) return error.TruncatedResult;
        offset += n;
        const available = carry + n;
        var complete = available;
        if (escape_unicode and offset < length) {
            var lead = available - 1;
            while (lead != 0 and chunk[lead] & 0xc0 == 0x80) lead -= 1;
            const width = try std.unicode.utf8ByteSequenceLength(chunk[lead]);
            if (lead + width > available) complete = lead;
        }
        try std.json.Stringify.encodeJsonStringChars(chunk[0..complete], .{ .escape_unicode = escape_unicode }, &writer.interface);
        carry = available - complete;
        std.mem.copyForwards(u8, chunk[0..carry], chunk[complete..available]);
    }
    if (carry != 0) return error.TruncatedResult;
    try writer.flush();
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgumentValue;
    return args[index.*];
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  rui login codex
        \\  rui serve --store PATH [--active-capacity N] [--codex | --provider-endpoint URL] [--provider-ca-file PATH] [--fault NAME]
        \\  rui configure --store PATH --session REF [settings] [--json]
        \\    First configuration requires --workspace PATH --provider codex --model MODEL.
        \\  rui session --store PATH --session REF
        \\    Enter a configured Session on a terminal; type /help for in-Session commands.
        \\  One-shot commands (never prompt or change meaning on redirection):
        \\  rui message --store PATH --session REF TEXT|- [--json]
        \\    --text FILE|- also captures a file or stdin before sending.
        \\  rui wait-session --store PATH --session REF [--terminal] [--json]
        \\    Select active/oldest queued work once; return idle if neither exists.
        \\  rui inspect-action --store PATH --session REF --action ID [--json]
        \\  rui allow-action --store PATH --session REF --action ID [--json]
        \\  rui deny-action --store PATH --session REF --action ID [--json]
        \\  rui requests [--json]
        \\  rui recover HANDLE [--json]
        \\  rui follow HANDLE [--json]
        \\    Follow this saved Message, not whatever the Session does next.
        \\  rui result HANDLE [--json]
        \\    Handles are saved under HOME/.config/rui/requests; Host startup is explicit.
        \\  Low-level explicit-key commands:
        \\  rui configure --store PATH --record FILE --key KEY --session REF [settings]
        \\  rui message --store PATH --record FILE --key KEY --session REF --text FILE|-
        \\  rui stop-session --store PATH --record FILE --key KEY --session REF
        \\  rui interrupt-model --store PATH --record FILE --key KEY --session REF --turn ID --operation ID
        \\  rui allow-action --store PATH --record FILE --key KEY --session REF --action ID
        \\  rui deny-action --store PATH --record FILE --key KEY --session REF --action ID
        \\  rui retry --store PATH --record FILE --kind configure|message|session-stop|model-interruption|permission-decision
        \\  rui observe-command --store PATH --key KEY
        \\  rui read-result --store PATH --key KEY
        \\  rui read-action-call-id --store PATH --session REF --action ID
        \\  rui read-action-arguments --store PATH --session REF --action ID
        \\  rui inspect-session --store PATH --session REF [--profile current|full]
        \\
    , .{});
    return error.InvalidArguments;
}

test "post-command hold signals only after work and exits on release" {
    const ready = try testPipe();
    defer closeDescriptor(ready[0]);
    const release = try testPipe();
    defer closeDescriptor(release[1]);
    const thread = try std.Thread.spawn(.{}, postCommandHoldDescriptors, .{ ready[1], release[0] });

    var signal: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(ready[0], &signal, signal.len));
    try std.testing.expectEqual(@as(u8, 1), signal[0]);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(release[1], &[_]u8{1}, 1));
    thread.join();
}

test "post-command hold reports release-pipe cleanup" {
    const ready = try testPipe();
    defer closeDescriptor(ready[0]);
    const release = try testPipe();
    closeDescriptor(release[1]);
    try std.testing.expectError(error.PostCommandHoldClosed, postCommandHoldDescriptors(ready[1], release[0]));
}

test "render scratch has no named payload and refuses failed unlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try createRenderScratch(io, tmp.dir, false);
    defer file.close(io);
    try file.writeStreamingAll(io, "private answer");
    var directory = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    try std.testing.expect((try iterator.next(io)) == null);

    try std.testing.expectError(error.RenderScratchCleanupFailed, createRenderScratch(io, tmp.dir, true));
    iterator = directory.iterate();
    const abandoned = (try iterator.next(io)).?;
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.statFile(io, abandoned.name, .{})).size);
}

fn testPipe() ![2]std.posix.fd_t {
    var descriptors: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&descriptors) != 0) return error.TestPipeFailed;
    return descriptors;
}

fn closeDescriptor(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}
