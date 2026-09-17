const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) return serve(init.io, args[2..]);
    if (std.mem.eql(u8, command, "configure")) return configure(init.io, args[2..]);
    if (std.mem.eql(u8, command, "message")) return message(init.io, args[2..]);
    if (std.mem.eql(u8, command, "stop-session")) return stopSession(init.io, args[2..]);
    if (std.mem.eql(u8, command, "interrupt-model")) return interruptModel(init.io, args[2..]);
    if (std.mem.eql(u8, command, "deny-action")) return denyAction(init.io, args[2..]);
    if (std.mem.eql(u8, command, "allow-action")) return decideAction(init.io, args[2..], .allow_once);
    if (std.mem.eql(u8, command, "retry")) return retry(init.io, args[2..]);
    if (std.mem.eql(u8, command, "observe-command")) return observe(init.io, args[2..]);
    if (std.mem.eql(u8, command, "read-result")) return readResult(init.io, args[2..]);
    if (std.mem.eql(u8, command, "read-action-call-id")) return readActionContent(init.io, args[2..], .call_id);
    if (std.mem.eql(u8, command, "read-action-arguments")) return readActionArguments(init.io, args[2..]);
    if (std.mem.eql(u8, command, "inspect-session")) return inspect(init.io, args[2..]);
    return usage();
}

fn serve(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var provider_endpoint: ?[]const u8 = null;
    var bash_path: []const u8 = server.default_bash_path;
    var bash_timeout_ms: u64 = server.default_bash_timeout_ms;
    var active_capacity: usize = server.default_active_capacity;
    var faults: server.Faults = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider-endpoint")) {
            provider_endpoint = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--bash-path")) {
            bash_path = try takeValue(args, &index);
            if (bash_path.len == 0) return error.InvalidBashPath;
        } else if (std.mem.eql(u8, arg, "--bash-timeout-ms")) {
            bash_timeout_ms = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        } else if (std.mem.eql(u8, arg, "--test-bash-scratch-limit-bytes")) {
            faults.bash_scratch_limit_bytes = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--active-capacity")) {
            active_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--fault")) {
            const fault = try takeValue(args, &index);
            if (std.mem.eql(u8, fault, "content-acquire")) faults.content_acquire = true else if (std.mem.eql(u8, fault, "content-write")) faults.content_write = true else if (std.mem.eql(u8, fault, "content-seal")) faults.content_seal = true else if (std.mem.eql(u8, fault, "content-read")) faults.content_read = true else if (std.mem.eql(u8, fault, "content-import")) faults.content_import = true else if (std.mem.eql(u8, fault, "before-commit")) faults.before_commit = true else if (std.mem.eql(u8, fault, "startup-cleanup")) faults.startup_cleanup = true else if (std.mem.eql(u8, fault, "shutdown-after-accept")) faults.shutdown_after_accept = true else if (std.mem.eql(u8, fault, "attempt-before-commit")) faults.attempt_before_commit = true else if (std.mem.eql(u8, fault, "result-before-commit")) faults.result_before_commit = true else if (std.mem.eql(u8, fault, "request-first-step")) faults.request_first_step = true else if (std.mem.eql(u8, fault, "request-write")) faults.request_write = true else if (std.mem.eql(u8, fault, "request-seal")) faults.request_seal = true else if (std.mem.eql(u8, fault, "request-scratch-acquire")) faults.request_scratch_acquire = true else if (std.mem.eql(u8, fault, "request-read")) faults.request_read = true else if (std.mem.eql(u8, fault, "request-unlink")) faults.request_unlink = true else if (std.mem.eql(u8, fault, "provider-prepare")) faults.provider_prepare = true else if (std.mem.eql(u8, fault, "completion-private-missing")) faults.completion_identity_fault = .missing else if (std.mem.eql(u8, fault, "completion-private-foreign")) faults.completion_identity_fault = .foreign else if (std.mem.eql(u8, fault, "completion-private-mismatch")) faults.completion_identity_fault = .mismatched else if (std.mem.eql(u8, fault, "response-acquire")) faults.response_acquire = true else if (std.mem.eql(u8, fault, "response-unlink")) faults.response_unlink = true else if (std.mem.eql(u8, fault, "response-write")) faults.response_write = true else if (std.mem.eql(u8, fault, "response-seal")) faults.response_seal = true else if (std.mem.eql(u8, fault, "response-metadata")) faults.response_metadata = true else if (std.mem.eql(u8, fault, "response-metadata-unlink")) faults.response_metadata_unlink = true else if (std.mem.eql(u8, fault, "response-read")) faults.response_read = true else if (std.mem.eql(u8, fault, "response-import")) faults.response_import = true else if (std.mem.eql(u8, fault, "response-commit")) faults.response_commit = true else if (std.mem.eql(u8, fault, "bash-preparation")) faults.bash_preparation = true else if (std.mem.eql(u8, fault, "bash-preparation-after-script")) faults.bash_preparation_after_script = true else if (std.mem.eql(u8, fault, "bash-spawn")) faults.bash_spawn = true else if (std.mem.eql(u8, fault, "bash-service")) faults.bash_service = true else if (std.mem.eql(u8, fault, "bash-capture-read")) faults.bash_capture_read = true else if (std.mem.eql(u8, fault, "bash-capture-write")) faults.bash_capture_write = true else if (std.mem.eql(u8, fault, "bash-seal")) faults.bash_seal = true else if (std.mem.eql(u8, fault, "bash-cleanup")) faults.bash_cleanup = true else if (std.mem.eql(u8, fault, "bash-observe")) faults.bash_lifecycle_fault = .observe else if (std.mem.eql(u8, fault, "bash-reap")) faults.bash_lifecycle_fault = .reap else if (std.mem.eql(u8, fault, "bash-reap-watchdog")) faults.bash_lifecycle_fault = .reap_watchdog else if (std.mem.eql(u8, fault, "bash-group-probe")) faults.bash_lifecycle_fault = .group_probe else if (std.mem.eql(u8, fault, "bash-tail-snapshot")) faults.bash_lifecycle_fault = .tail_snapshot else if (std.mem.eql(u8, fault, "bash-signal")) faults.bash_lifecycle_fault = .signal else if (std.mem.eql(u8, fault, "bash-cleanup-watchdog")) faults.bash_lifecycle_fault = .cleanup_watchdog else if (std.mem.eql(u8, fault, "report-unlink")) faults.report_unlink = true else return error.UnknownFault;
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
        } else return error.UnknownArgument;
        index += 1;
    }
    if ((faults.control_gate_keys == null) != (faults.control_gate_path == null)) return error.IncompleteControlGate;
    return server.serve(
        io,
        std.heap.c_allocator,
        store_path orelse return usage(),
        active_capacity,
        faults,
        provider_endpoint,
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

fn configure(io: std.Io, args: []const []const u8) !void {
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
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or !key_seen) return usage();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.configure(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn message(io: std.Io, args: []const []const u8) !void {
    var input = client.MessageInput{ .store = "", .record = "", .key = "", .session = "", .text_path = "" };
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or input.text_path.len == 0 or !key_seen) return usage();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.message(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
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

fn denyAction(io: std.Io, args: []const []const u8) !void {
    return decideAction(io, args, .deny);
}

fn decideAction(io: std.Io, args: []const []const u8, decision: @FieldType(client.PermissionDecisionInput, "decision")) !void {
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
        } else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or !key_seen or !action_seen) return usage();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.denyPermission(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
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

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgumentValue;
    return args[index.*];
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  rui serve --store PATH [--active-capacity N] [--provider-endpoint URL] [--fault NAME]
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
