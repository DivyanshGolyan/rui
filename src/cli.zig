const std = @import("std");
const deterministic_provider = @import("deterministic_provider.zig");
const codex_auth = @import("codex_auth.zig");
const codex_native = @import("codex_native.zig");
const codex_provider = @import("codex_provider.zig");
const harness = @import("harness.zig");
const bash_tool = @import("bash_tool.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

const output_window_size = 4096;
const max_permission_decision_line_size: usize = 64;

const Arguments = struct {
    state_path: ?[]const u8 = null,
    repo_path: ?[]const u8 = null,
    model: ?[]const u8 = null,
    fixture_response: ?[]const u8 = null,
    fixture_bash_command: ?[]const u8 = null,
    fixture_patch_path: ?[]const u8 = null,
    bash_timeout_ms: u32 = 5000,
    dangerously_bypass_permissions: bool = false,
    task: ?[]const u8 = null,
    resume_id: ?u64 = null,
    codex_login: bool = false,
    codex_logout: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const raw_args = try init.minimal.args.toSlice(allocator);
    const arguments = try parseArguments(raw_args);

    var native_http: codex_native.NativeHttp = .{ .io = init.io, .allocator = allocator };
    var keychain: codex_native.KeychainStore = .{};
    if (arguments.codex_login) {
        try loginCodex(init.io, allocator, native_http.capability(), keychain.capability());
        return;
    }
    if (arguments.codex_logout) {
        try logoutCodex(native_http.capability(), keychain.capability());
        return;
    }

    const state_path = try resolveStatePath(
        init.minimal.environ,
        allocator,
        arguments.state_path,
    );
    defer allocator.free(state_path);
    const runtime = try harness.HostRuntime.open(init.io, allocator, state_path, .{});
    defer runtime.close() catch unreachable;
    if (arguments.resume_id) |session_id| {
        var fixture: deterministic_provider.Fixture = .{
            .expected_task = null,
            .final_answer = arguments.fixture_response orelse "",
        };
        var authorization: codex_native.NativeAuthorization = .{
            .io = init.io,
            .allocator = allocator,
            .store = keychain.capability(),
            .http = native_http.capability(),
        };
        var transport: codex_native.NativeTransport = .{ .io = init.io, .allocator = allocator };
        var codex: codex_provider.CodexProvider = .{
            .authorization = authorization.capability(),
            .transport = transport.capability(),
        };
        const provider: ?model_operation.Provider = if (arguments.model) |model| provider: {
            if (std.mem.startsWith(u8, model, "codex:")) break :provider codex.provider();
            if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
            if (arguments.fixture_response == null) return error.MissingFixtureResponse;
            break :provider fixture.provider();
        } else null;
        var owner = try harness.Harness.open(.{
            .runtime = runtime,
            .permission_mode = if (arguments.dangerously_bypass_permissions) .bypass else .ask,
            .mode = .{ .restore = .{ .session_id = session_id, .provider = provider } },
        });
        defer owner.close();
        const identified = try owner.drive();
        try renderProgress(init.io, owner, &identified);
        try pumpOwner(init.io, owner);
        return;
    }
    {
        const model = arguments.model orelse return error.MissingModel;
        const task = arguments.task orelse return error.MissingTask;
        const workspace_path = try resolveWorkspacePath(init.io, allocator, arguments.repo_path);
        defer allocator.free(workspace_path);
        if (std.mem.startsWith(u8, model, "codex:")) {
            if (arguments.fixture_response != null or arguments.fixture_bash_command != null or
                arguments.fixture_patch_path != null)
            {
                return error.CodexFixtureArgumentsConflict;
            }
            var authorization: codex_native.NativeAuthorization = .{
                .io = init.io,
                .allocator = allocator,
                .store = keychain.capability(),
                .http = native_http.capability(),
            };
            var transport: codex_native.NativeTransport = .{ .io = init.io, .allocator = allocator };
            var codex: codex_provider.CodexProvider = .{
                .authorization = authorization.capability(),
                .transport = transport.capability(),
            };
            try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = codex.provider(),
            });
            return;
        }
        if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
        const response = arguments.fixture_response orelse return error.MissingFixtureResponse;
        if (arguments.fixture_bash_command != null and arguments.fixture_patch_path != null) {
            const patch = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                arguments.fixture_patch_path.?,
                allocator,
                .limited(patch_tool.max_patch_size),
            );
            defer allocator.free(patch);
            var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
            const encoded_call = try bash_tool.encodeCall(&call_buffer, .{
                .command = arguments.fixture_bash_command.?,
                .timeout_ms = arguments.bash_timeout_ms,
            });
            var fixture: deterministic_provider.RepairFixture = .{
                .expected_task = task,
                .bash_call = encoded_call,
                .patch = patch,
                .final_answer = response,
            };
            try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = fixture.provider(),
            });
            return;
        }
        if (arguments.fixture_patch_path) |patch_path| {
            const patch = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                patch_path,
                allocator,
                .limited(patch_tool.max_patch_size),
            );
            defer allocator.free(patch);
            var fixture: deterministic_provider.ToolFixture = .{
                .expected_task = task,
                .tool = .apply_patch,
                .tool_arguments = patch,
                .final_answer = response,
                .expected_patch_status = .denied,
            };
            try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = fixture.provider(),
            });
            return;
        }
        if (arguments.fixture_bash_command) |command| {
            var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
            const encoded_call = try bash_tool.encodeCall(&call_buffer, .{
                .command = command,
                .timeout_ms = arguments.bash_timeout_ms,
            });
            var fixture: deterministic_provider.ToolFixture = .{
                .expected_task = task,
                .tool_arguments = encoded_call,
                .final_answer = response,
            };
            try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = fixture.provider(),
            });
            return;
        }
        var fixture: deterministic_provider.Fixture = .{
            .expected_task = task,
            .final_answer = response,
        };
        try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
            .workspace_path = workspace_path,
            .model = model,
            .task = task,
            .provider = fixture.provider(),
        });
    }
}

fn runCreate(
    io: std.Io,
    runtime: *harness.HostRuntime,
    bypass_permissions: bool,
    create: harness.Create,
) !void {
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .permission_mode = if (bypass_permissions) .bypass else .ask,
        .mode = .{ .create = create },
    });
    defer owner.close();
    const identified = try owner.drive();
    try renderProgress(io, owner, &identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try pumpOwner(io, owner);
}

fn pumpOwner(io: std.Io, owner: *harness.Harness) !void {
    const recovery_drives = (harness.max_recovery_records +
        harness.default_recovery_quantum - 1) / harness.default_recovery_quantum;
    for (0..recovery_drives + 8) |_| {
        const progress = try owner.drive();
        try renderProgress(io, owner, &progress);
        if (approvalProjection(&progress)) |approval| {
            const allow = try promptPermission(io, owner, approval);
            const descriptor_digest = approval.descriptor_digest orelse
                return error.ApprovalProjectionIncomplete;
            if (owner.offer(.{ .permission = .{
                .operation_id = approval.operation_id,
                .operation_generation = approval.operation_generation,
                .descriptor_digest = descriptor_digest,
                .allow = allow,
            } }) != .accepted) return error.PermissionOfferRejected;
            continue;
        }
        switch (progress.state) {
            .finished, .cancelled, .closed => return,
            .failed, .unavailable => return error.SessionFailed,
            else => {},
        }
        if (progress.consumed == 0 and progress.committed == 0 and
            progress.dispatched == 0 and !progress.more)
        {
            return;
        }
    }
    return error.DriveQuantumExceeded;
}

fn renderProgress(io: std.Io, owner: *harness.Harness, progress: *const harness.Progress) !void {
    for (progress.projectionSlice()) |projection| switch (projection.kind) {
        .session => {
            var id_buffer: [16]u8 = undefined;
            const id = try session_store.formatId(projection.session_id, &id_buffer);
            var line_buffer: [32]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buffer, "Session: {s}\n", .{id});
            try std.Io.File.stdout().writeStreamingAll(io, line);
        },
        .final_answer => {
            try std.Io.File.stdout().writeStreamingAll(io, "Final Answer:\n");
            try writeFinalAnswer(io, owner, projection);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
        },
        .approval_required => try std.Io.File.stdout().writeStreamingAll(
            io,
            "Approval required. Resume in ask mode to decide the exact Action.\n",
        ),
        .indeterminate => try std.Io.File.stdout().writeStreamingAll(
            io,
            "The Bash Attempt may have executed and will not be replayed.\n",
        ),
        .cancelled => try std.Io.File.stdout().writeStreamingAll(io, "Cancelled.\n"),
        .failure => {
            var line_buffer: [192]u8 = undefined;
            const line = try failureProjectionLine(&line_buffer, &projection);
            try std.Io.File.stdout().writeStreamingAll(io, line);
        },
        .task_admitted, .outcome, .closed => {},
    };
}

fn failureLine(out: []u8, failure: model_protocol.Failure) ![]const u8 {
    const diagnostic = if (failure == .none) "unclassified" else @tagName(failure);
    return std.fmt.bufPrint(out, "Session failed: {s}.\n", .{diagnostic});
}

fn failureProjectionLine(out: []u8, projection: *const harness.Projection) ![]const u8 {
    if (projection.diagnostic_source == .none) return failureLine(out, projection.failure);
    const code = projection.diagnosticCode();
    const status = projection.diagnosticHttpStatus();
    if (status == null and code.len == 0) {
        return std.fmt.bufPrint(
            out,
            "Session failed: {s} ({s}).\n",
            .{ @tagName(projection.failure), @tagName(projection.diagnostic_source) },
        );
    }
    if (status) |value| {
        if (code.len == 0) {
            return std.fmt.bufPrint(
                out,
                "Session failed: {s} ({s}, status={d}).\n",
                .{ @tagName(projection.failure), @tagName(projection.diagnostic_source), value },
            );
        }
        return std.fmt.bufPrint(
            out,
            "Session failed: {s} ({s}, status={d}, code={s}).\n",
            .{ @tagName(projection.failure), @tagName(projection.diagnostic_source), value, code },
        );
    }
    return std.fmt.bufPrint(
        out,
        "Session failed: {s} ({s}, code={s}).\n",
        .{ @tagName(projection.failure), @tagName(projection.diagnostic_source), code },
    );
}

fn resolveStatePath(
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) ![]u8 {
    if (configured) |path| return allocator.dupe(u8, path);
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    const home = environment.get("HOME") orelse return error.MissingHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".onepage", "sessions" });
}

fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len < 1) return error.InvalidArguments;
    var parsed: Arguments = .{};
    var index: usize = 1;
    while (index < args.len) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--state")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.state_path = args[index];
        } else if (std.mem.eql(u8, argument, "--repo")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.repo_path = args[index];
        } else if (std.mem.eql(u8, argument, "--model")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.model = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-response")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_response = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-bash-command")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_bash_command = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-patch")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_patch_path = args[index];
        } else if (std.mem.eql(u8, argument, "--bash-timeout-ms")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.bash_timeout_ms = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, argument, "--dangerously-bypass-permissions")) {
            parsed.dangerously_bypass_permissions = true;
        } else if (std.mem.eql(u8, argument, "--codex-login")) {
            parsed.codex_login = true;
        } else if (std.mem.eql(u8, argument, "--codex-logout")) {
            parsed.codex_logout = true;
        } else if (std.mem.eql(u8, argument, "--resume")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.resume_id = try std.fmt.parseInt(u64, args[index], 16);
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else {
            if (parsed.task != null) return error.MultipleTasks;
            parsed.task = argument;
        }
        index += 1;
    }
    if (parsed.codex_login or parsed.codex_logout) {
        if (parsed.codex_login == parsed.codex_logout or parsed.task != null or parsed.model != null or
            parsed.resume_id != null or parsed.repo_path != null or parsed.state_path != null or
            parsed.fixture_response != null or parsed.fixture_bash_command != null or
            parsed.fixture_patch_path != null or parsed.dangerously_bypass_permissions)
        {
            return error.AuthorizationArgumentsConflict;
        }
        return parsed;
    }
    if (parsed.resume_id != null) {
        if (parsed.task != null or parsed.repo_path != null or
            parsed.fixture_bash_command != null or parsed.fixture_patch_path != null)
        {
            return error.ResumeArgumentsConflict;
        }
        if (parsed.model) |model| {
            if (std.mem.startsWith(u8, model, "fixture:") and parsed.fixture_response == null) {
                return error.ResumeProviderArgumentsIncomplete;
            }
            if (std.mem.startsWith(u8, model, "codex:") and parsed.fixture_response != null) {
                return error.ResumeProviderArgumentsIncomplete;
            }
        } else if (parsed.fixture_response != null) {
            return error.ResumeProviderArgumentsIncomplete;
        }
    }
    return parsed;
}

fn loginCodex(
    io: std.Io,
    allocator: std.mem.Allocator,
    http: codex_auth.Http,
    store: codex_auth.Store,
) !void {
    const device = try codex_auth.requestDeviceCode(http);
    var prompt: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &prompt,
        "Open {s} and enter code {s}. Waiting for authorization (up to 15 minutes).\n",
        .{ codex_auth.verification_url, device.userCode() },
    );
    try std.Io.File.stdout().writeStreamingAll(io, message);
    const opened = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/open", codex_auth.verification_url },
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(1024),
    }) catch null;
    if (opened) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
        .raw = std.Io.Duration.fromSeconds(15 * 60),
        .clock = .awake,
    });
    var poll_seconds = device.interval_seconds;
    while (std.Io.Clock.Timestamp.now(io, .awake).compare(.lt, deadline)) {
        switch (try codex_auth.pollDeviceCode(http, &device)) {
            .pending => try std.Io.sleep(io, std.Io.Duration.fromSeconds(poll_seconds), .awake),
            .slow_down => {
                poll_seconds = @min(@as(u16, 60), poll_seconds + 5);
                try std.Io.sleep(io, std.Io.Duration.fromSeconds(poll_seconds), .awake);
            },
            .authorization => |authorization| {
                var authorization_value = authorization;
                defer authorization_value.scrub();
                var tokens = try codex_auth.exchangeCode(http, &authorization_value);
                defer tokens.scrub();
                var stored: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
                defer std.crypto.secureZero(u8, &stored);
                const record = try codex_auth.encodeStored(&tokens, &stored);
                try store.save(record);
                try std.Io.File.stdout().writeStreamingAll(io, "Codex authorization saved in macOS Keychain.\n");
                return;
            },
        }
    }
    return error.DeviceAuthorizationTimedOut;
}

fn logoutCodex(http: codex_auth.Http, store: codex_auth.Store) !void {
    var stored: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &stored);
    if (try store.load(&stored)) |bytes| {
        var tokens = try codex_auth.decodeStored(bytes);
        defer tokens.scrub();
        // Local logout must still remove the credential when remote revocation is unavailable.
        codex_auth.revoke(http, &tokens) catch {};
    }
    try store.delete();
}

fn approvalProjection(progress: *const harness.Progress) ?harness.Projection {
    for (progress.projectionSlice()) |projection| {
        if (projection.kind == .approval_required) return projection;
    }
    return null;
}

fn promptPermission(io: std.Io, owner: *harness.Harness, approval: harness.Projection) !bool {
    var header: [192]u8 = undefined;
    const descriptor = approval.descriptor_digest orelse return error.ApprovalProjectionIncomplete;
    const digest_hex = std.fmt.bytesToHex(descriptor.bytes(), .lower);
    const prompt = try std.fmt.bufPrint(
        &header,
        "Action (operation {x:0>16}/{d}, binding {s}):\n",
        .{ approval.operation_id, approval.operation_generation, &digest_hex },
    );
    try std.Io.File.stdout().writeStreamingAll(io, prompt);
    var reader = try owner.openProjectionContent(approval);
    defer reader.close();
    var window: [output_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedActionDescriptor;
        const escaped = try escapePatch(std.heap.page_allocator, bytes);
        defer std.heap.page_allocator.free(escaped);
        try std.Io.File.stdout().writeStreamingAll(io, escaped);
        offset += bytes.len;
    }
    try std.Io.File.stdout().writeStreamingAll(io, "\nAllow? [y/N] ");
    var first: ?u8 = null;
    var byte: [1]u8 = undefined;
    var length: usize = 0;
    while (true) {
        const count = std.Io.File.stdin().readStreaming(io, &.{&byte}) catch |err| switch (err) {
            error.EndOfStream => return error.PermissionDecisionLineUnterminated,
            else => return err,
        };
        if (count == 0) return error.PermissionDecisionLineUnterminated;
        if (byte[0] == '\n') break;
        if (length == max_permission_decision_line_size) {
            return error.PermissionDecisionLineTooLong;
        }
        if (first == null) first = byte[0];
        length += 1;
    }
    return first == 'y' or first == 'Y';
}

fn escapePatch(allocator: std.mem.Allocator, patch: []const u8) ![]u8 {
    const capacity = try std.math.mul(usize, patch.len, 4);
    const out = try allocator.alloc(u8, capacity);
    errdefer allocator.free(out);
    const hex = "0123456789abcdef";
    var cursor: usize = 0;
    for (patch) |byte| {
        if (byte == '\n') {
            out[cursor] = '\n';
            cursor += 1;
        } else if (byte == '\\') {
            @memcpy(out[cursor..][0..2], "\\\\");
            cursor += 2;
        } else if (byte >= 0x20 and byte <= 0x7e) {
            out[cursor] = byte;
            cursor += 1;
        } else {
            out[cursor] = '\\';
            out[cursor + 1] = 'x';
            out[cursor + 2] = hex[byte >> 4];
            out[cursor + 3] = hex[byte & 0x0f];
            cursor += 4;
        }
    }
    return allocator.realloc(out, cursor);
}

fn resolveWorkspacePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const path = configured orelse return allocator.dupe(u8, cwd);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn writeFinalAnswer(io: std.Io, owner: *harness.Harness, projection: harness.Projection) !void {
    var reader = try owner.openProjectionContent(projection);
    defer reader.close();
    var window: [output_window_size]u8 = undefined;
    var safe: [output_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedFinalAnswer;
        for (bytes, 0..) |byte, index| {
            safe[index] = if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f)
                '?'
            else
                byte;
        }
        try std.Io.File.stdout().writeStreamingAll(io, safe[0..bytes.len]);
        offset += bytes.len;
    }
}

test "CLI arguments distinguish create from exact resume" {
    const create = try parseArguments(&.{
        "onepage",
        "--state",
        "state",
        "--model",
        "fixture:answer",
        "--fixture-response",
        "done",
        "task",
    });
    try std.testing.expectEqualStrings("task", create.task.?);
    const resumed = try parseArguments(&.{
        "onepage",
        "--state",
        "state",
        "--resume",
        "000000000000000a",
    });
    try std.testing.expectEqual(@as(u64, 10), resumed.resume_id.?);

    const resumed_with_provider = try parseArguments(&.{
        "onepage",
        "--state",
        "state",
        "--resume",
        "000000000000000a",
        "--model",
        "fixture:answer",
        "--fixture-response",
        "done",
    });
    try std.testing.expectEqualStrings("fixture:answer", resumed_with_provider.model.?);
    try std.testing.expectEqualStrings("done", resumed_with_provider.fixture_response.?);

    const codex_create = try parseArguments(&.{
        "onepage",
        "--model",
        "codex:gpt-5.3-codex",
        "task",
    });
    try std.testing.expectEqualStrings("codex:gpt-5.3-codex", codex_create.model.?);
    const codex_resume = try parseArguments(&.{
        "onepage",
        "--resume",
        "000000000000000a",
        "--model",
        "codex:gpt-5.3-codex",
    });
    try std.testing.expectEqualStrings("codex:gpt-5.3-codex", codex_resume.model.?);

    try std.testing.expect((try parseArguments(&.{ "onepage", "--codex-login" })).codex_login);
    try std.testing.expect((try parseArguments(&.{ "onepage", "--codex-logout" })).codex_logout);
    try std.testing.expectError(
        error.AuthorizationArgumentsConflict,
        parseArguments(&.{ "onepage", "--codex-login", "--fixture-response", "ignored" }),
    );

    const patch = try parseArguments(&.{
        "onepage",
        "--fixture-patch",
        "change.patch",
        "--dangerously-bypass-permissions",
        "task",
    });
    try std.testing.expectEqualStrings("change.patch", patch.fixture_patch_path.?);
    try std.testing.expect(patch.dangerously_bypass_permissions);
}

test "CLI failure rendering preserves the bounded typed cause" {
    var buffer: [192]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Session failed: transport_may_have_started.\n",
        try failureLine(&buffer, .transport_may_have_started),
    );
    var projection: harness.Projection = .{
        .kind = .failure,
        .session_id = 1,
        .failure = .authentication_expired,
        .diagnostic_source = .provider_http_403,
        .diagnostic_http_status = 403,
    };
    projection.setDiagnosticCode("originator_not_allowed");
    try std.testing.expectEqualStrings(
        "Session failed: authentication_expired (provider_http_403, status=403, code=originator_not_allowed).\n",
        try failureProjectionLine(&buffer, &projection),
    );
    projection.failure = .provider_error;
    projection.diagnostic_source = .provider_http_rejection;
    projection.diagnostic_http_status = 422;
    projection.setDiagnosticCode("");
    try std.testing.expectEqualStrings(
        "Session failed: provider_error (provider_http_rejection, status=422).\n",
        try failureProjectionLine(&buffer, &projection),
    );
}

test "patch display escapes terminal controls and backslashes losslessly" {
    const escaped = try escapePatch(std.testing.allocator, "safe\n\x1b[2J\\x1b\t\xff");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("safe\n\\x1b[2J\\\\x1b\\x09\\xff", escaped);
}
