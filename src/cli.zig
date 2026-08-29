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
const codex_login_timeout = std.Io.Duration.fromSeconds(15 * 60);

const LoginClock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) std.Io.Timestamp,
    sleep_fn: *const fn (*anyopaque, std.Io.Duration) anyerror!void,

    fn now(self: LoginClock) std.Io.Timestamp {
        return self.now_fn(self.context);
    }

    fn sleep(self: LoginClock, duration: std.Io.Duration) !void {
        try self.sleep_fn(self.context, duration);
    }
};

const NativeLoginClock = struct {
    io: std.Io,

    fn capability(self: *NativeLoginClock) LoginClock {
        return .{ .context = self, .now_fn = now, .sleep_fn = sleep };
    }

    fn now(context: *anyopaque) std.Io.Timestamp {
        const self: *NativeLoginClock = @ptrCast(@alignCast(context));
        return std.Io.Timestamp.now(self.io, .awake);
    }

    fn sleep(context: *anyopaque, duration: std.Io.Duration) anyerror!void {
        const self: *NativeLoginClock = @ptrCast(@alignCast(context));
        try std.Io.sleep(self.io, duration, .awake);
    }
};

const LoginDeadline = struct {
    at: std.Io.Timestamp,

    fn start(clock: LoginClock, budget: std.Io.Duration) LoginDeadline {
        return .{ .at = clock.now().addDuration(budget) };
    }

    fn remaining(self: LoginDeadline, clock: LoginClock) !std.Io.Duration {
        const now = clock.now();
        if (now.nanoseconds >= self.at.nanoseconds) return error.DeviceAuthorizationTimedOut;
        return now.durationTo(self.at);
    }

    fn sleep(self: LoginDeadline, clock: LoginClock, requested: std.Io.Duration) !void {
        const available = try self.remaining(clock);
        const bounded = if (requested.nanoseconds < available.nanoseconds) requested else available;
        try clock.sleep(bounded);
        _ = try self.remaining(clock);
    }

    fn callError(self: LoginDeadline, clock: LoginClock, err: anyerror) anyerror {
        if (clock.now().nanoseconds >= self.at.nanoseconds) return error.DeviceAuthorizationTimedOut;
        return err;
    }
};

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
            .mode = .{ .restore = .{
                .session_id = session_id,
                .model_binding = if (provider) |value| .{
                    .model = arguments.model.?,
                    .provider = value,
                } else null,
            } },
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
                .model_binding = .{ .model = model, .provider = codex.provider() },
                .task = task,
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
                .model_binding = .{ .model = model, .provider = fixture.provider() },
                .task = task,
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
                .model_binding = .{ .model = model, .provider = fixture.provider() },
                .task = task,
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
                .model_binding = .{ .model = model, .provider = fixture.provider() },
                .task = task,
            });
            return;
        }
        var fixture: deterministic_provider.Fixture = .{
            .expected_task = task,
            .final_answer = response,
        };
        try runCreate(init.io, runtime, arguments.dangerously_bypass_permissions, .{
            .workspace_path = workspace_path,
            .model_binding = .{ .model = model, .provider = fixture.provider() },
            .task = task,
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
    if (code.len == 0) {
        return std.fmt.bufPrint(
            out,
            "Session failed: {s} ({s}).\n",
            .{ @tagName(projection.failure), @tagName(projection.diagnostic_source) },
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
    if (parsed.model) |model| try validateModelArgument(model);
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

const ModelProvider = enum { codex, fixture };

fn validateModelArgument(model: []const u8) !void {
    if (model.len == 0 or model.len > session_store.model_name_capacity or
        !std.unicode.utf8ValidateSlice(model))
    {
        return error.InvalidModelArgument;
    }
    const provider, const suffix = if (std.mem.startsWith(u8, model, "codex:"))
        .{ ModelProvider.codex, model["codex:".len..] }
    else if (std.mem.startsWith(u8, model, "fixture:"))
        .{ ModelProvider.fixture, model["fixture:".len..] }
    else
        return error.UnsupportedModel;
    if (suffix.len == 0 or suffix[0] == ' ' or suffix[suffix.len - 1] == ' ') {
        return error.InvalidModelArgument;
    }
    for (suffix) |byte| {
        if (byte < 0x20 or byte == 0x7f or (provider == .codex and byte == ' ')) {
            return error.InvalidModelArgument;
        }
    }
}

fn loginCodex(
    io: std.Io,
    allocator: std.mem.Allocator,
    http: codex_auth.Http,
    store: codex_auth.Store,
) !void {
    var native_clock: NativeLoginClock = .{ .io = io };
    const clock = native_clock.capability();
    const deadline = LoginDeadline.start(clock, codex_login_timeout);
    const device = try requestLoginDevice(clock, deadline, http);
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
    try completeCodexLogin(clock, deadline, http, store, &device);
    try std.Io.File.stdout().writeStreamingAll(io, "Codex authorization saved in macOS Keychain.\n");
}

fn requestLoginDevice(clock: LoginClock, deadline: LoginDeadline, http: codex_auth.Http) !codex_auth.DeviceCode {
    const budget = try deadline.remaining(clock);
    const device = codex_auth.requestDeviceCode(http.withTimeout(budget)) catch |err|
        return deadline.callError(clock, err);
    _ = try deadline.remaining(clock);
    return device;
}

fn completeCodexLogin(
    clock: LoginClock,
    deadline: LoginDeadline,
    http: codex_auth.Http,
    store: codex_auth.Store,
    device: *const codex_auth.DeviceCode,
) !void {
    var poll_seconds = device.interval_seconds;
    while (true) {
        const poll_budget = try deadline.remaining(clock);
        const poll = codex_auth.pollDeviceCode(http.withTimeout(poll_budget), device) catch |err|
            return deadline.callError(clock, err);
        switch (poll) {
            .pending => try deadline.sleep(clock, std.Io.Duration.fromSeconds(poll_seconds)),
            .slow_down => {
                poll_seconds = @min(@as(u16, 60), poll_seconds + 5);
                try deadline.sleep(clock, std.Io.Duration.fromSeconds(poll_seconds));
            },
            .authorization => |authorization| {
                var authorization_value = authorization;
                defer authorization_value.scrub();
                const exchange_budget = try deadline.remaining(clock);
                var tokens = codex_auth.exchangeCode(http.withTimeout(exchange_budget), &authorization_value) catch |err|
                    return deadline.callError(clock, err);
                defer tokens.scrub();
                _ = try deadline.remaining(clock);
                var stored: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
                defer std.crypto.secureZero(u8, &stored);
                const record = try codex_auth.encodeStored(&tokens, &stored);
                try store.save(record);
                return;
            },
        }
    }
}

fn logoutCodex(http: codex_auth.Http, store: codex_auth.Store) !void {
    revokeStoredCodexCredential(http, store) catch {};
    try store.delete();
}

fn revokeStoredCodexCredential(http: codex_auth.Http, store: codex_auth.Store) !void {
    var stored: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &stored);
    if (try store.load(&stored)) |bytes| {
        var tokens = try codex_auth.decodeStored(bytes);
        defer tokens.scrub();
        try codex_auth.revoke(http, &tokens);
    }
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
        "codex:gpt-5.6-sol",
        "task",
    });
    try std.testing.expectEqualStrings("codex:gpt-5.6-sol", codex_create.model.?);
    const codex_resume = try parseArguments(&.{
        "onepage",
        "--resume",
        "000000000000000a",
        "--model",
        "codex:caller-selected-model",
    });
    try std.testing.expectEqualStrings("codex:caller-selected-model", codex_resume.model.?);

    const invalid_models = [_][]const u8{
        "codex:",
        "codex: ",
        "codex:gpt 5",
        "codex:gpt\n5",
        "fixture:",
        "fixture: ",
        "fixture:answer ",
    };
    for (invalid_models) |model| {
        try std.testing.expectError(
            error.InvalidModelArgument,
            parseArguments(&.{ "onepage", "--model", model, "task" }),
        );
    }
    try std.testing.expectError(
        error.UnsupportedModel,
        parseArguments(&.{ "onepage", "--model", "unknown:model", "task" }),
    );
    var oversized_model: [session_store.model_name_capacity + 1]u8 = @splat('m');
    @memcpy(oversized_model[0.."codex:".len], "codex:");
    try std.testing.expectError(
        error.InvalidModelArgument,
        parseArguments(&.{ "onepage", "--model", &oversized_model, "task" }),
    );
    const invalid_utf8_model = [_]u8{ 'c', 'o', 'd', 'e', 'x', ':', 0xff };
    try std.testing.expectError(
        error.InvalidModelArgument,
        parseArguments(&.{ "onepage", "--model", &invalid_utf8_model, "task" }),
    );
    try std.testing.expectEqualStrings(
        "fixture:path with space",
        (try parseArguments(&.{ "onepage", "--model", "fixture:path with space", "task" })).model.?,
    );

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
        .diagnostic_source = .provider,
    };
    projection.setDiagnosticCode("originator_not_allowed");
    try std.testing.expectEqualStrings(
        "Session failed: authentication_expired (provider, code=originator_not_allowed).\n",
        try failureProjectionLine(&buffer, &projection),
    );
    projection.failure = .provider_error;
    projection.diagnostic_source = .provider;
    projection.setDiagnosticCode("");
    try std.testing.expectEqualStrings(
        "Session failed: provider_error (provider).\n",
        try failureProjectionLine(&buffer, &projection),
    );
    projection.failure = .model_unavailable;
    projection.diagnostic_source = .provider;
    projection.setDiagnosticCode("model_not_supported");
    const model_line = try failureProjectionLine(&buffer, &projection);
    try std.testing.expectEqualStrings(
        "Session failed: model_unavailable (provider, code=model_not_supported).\n",
        model_line,
    );
    try std.testing.expect(std.mem.indexOf(u8, model_line, "using Codex with a ChatGPT account") == null);
}

test "Codex login caps a pending poll interval to the overall deadline" {
    var clock_fixture: FakeLoginClock = .{};
    const clock = clock_fixture.capability();
    const deadline = LoginDeadline.start(clock, std.Io.Duration.fromSeconds(10));
    clock_fixture.now = std.Io.Timestamp.fromNanoseconds(9 * std.time.ns_per_s);
    var http_fixture: LoginHttp = .{ .clock = &clock_fixture, .poll = .pending };
    var store_fixture: LoginStore = .{};
    var device = loginDevice(5);

    try std.testing.expectError(
        error.DeviceAuthorizationTimedOut,
        completeCodexLogin(clock, deadline, http_fixture.capability(), store_fixture.capability(), &device),
    );

    try std.testing.expectEqual(@as(u8, 1), http_fixture.poll_calls);
    try std.testing.expectEqual(std.time.ns_per_s, http_fixture.poll_budget.nanoseconds);
    try std.testing.expectEqual(std.time.ns_per_s, clock_fixture.slept.nanoseconds);
    try std.testing.expectEqual(@as(u8, 0), http_fixture.exchange_calls);
    try std.testing.expectEqual(@as(u8, 0), store_fixture.save_calls);
}

test "Codex login rejects authorization observed at the overall deadline" {
    var clock_fixture: FakeLoginClock = .{};
    const clock = clock_fixture.capability();
    const deadline = LoginDeadline.start(clock, std.Io.Duration.fromSeconds(10));
    clock_fixture.now = std.Io.Timestamp.fromNanoseconds(9 * std.time.ns_per_s);
    var http_fixture: LoginHttp = .{
        .clock = &clock_fixture,
        .poll = .authorization,
        .poll_advance = std.Io.Duration.fromSeconds(1),
    };
    var store_fixture: LoginStore = .{};
    var device = loginDevice(5);

    try std.testing.expectError(
        error.DeviceAuthorizationTimedOut,
        completeCodexLogin(clock, deadline, http_fixture.capability(), store_fixture.capability(), &device),
    );

    try std.testing.expectEqual(std.time.ns_per_s, http_fixture.poll_budget.nanoseconds);
    try std.testing.expectEqual(@as(u8, 0), http_fixture.exchange_calls);
    try std.testing.expectEqual(@as(u8, 0), store_fixture.save_calls);
}

test "Codex login caps token exchange to its remaining overall budget" {
    var clock_fixture: FakeLoginClock = .{};
    const clock = clock_fixture.capability();
    const deadline = LoginDeadline.start(clock, std.Io.Duration.fromSeconds(10));
    clock_fixture.now = std.Io.Timestamp.fromNanoseconds(7 * std.time.ns_per_s);
    var http_fixture: LoginHttp = .{
        .clock = &clock_fixture,
        .poll = .authorization,
        .poll_advance = std.Io.Duration.fromSeconds(1),
        .exchange_advance = std.Io.Duration.fromSeconds(2),
    };
    var store_fixture: LoginStore = .{};
    var device = loginDevice(5);

    try std.testing.expectError(
        error.DeviceAuthorizationTimedOut,
        completeCodexLogin(clock, deadline, http_fixture.capability(), store_fixture.capability(), &device),
    );

    try std.testing.expectEqual(@as(u8, 1), http_fixture.exchange_calls);
    try std.testing.expectEqual(2 * std.time.ns_per_s, http_fixture.exchange_budget.nanoseconds);
    try std.testing.expectEqual(@as(u8, 0), store_fixture.save_calls);
}

test "Codex login caps the initial device request to the overall deadline" {
    var clock_fixture: FakeLoginClock = .{};
    const clock = clock_fixture.capability();
    const deadline = LoginDeadline.start(clock, std.Io.Duration.fromSeconds(10));
    clock_fixture.now = std.Io.Timestamp.fromNanoseconds(9 * std.time.ns_per_s);
    var http_fixture: LoginHttp = .{
        .clock = &clock_fixture,
        .device_advance = std.Io.Duration.fromSeconds(1),
    };

    try std.testing.expectError(
        error.DeviceAuthorizationTimedOut,
        requestLoginDevice(clock, deadline, http_fixture.capability()),
    );

    try std.testing.expectEqual(@as(u8, 1), http_fixture.device_calls);
    try std.testing.expectEqual(std.time.ns_per_s, http_fixture.device_budget.nanoseconds);
    try std.testing.expectEqual(@as(u8, 0), http_fixture.poll_calls);

    var long_clock_fixture: FakeLoginClock = .{};
    const long_clock = long_clock_fixture.capability();
    const long_deadline = LoginDeadline.start(long_clock, codex_login_timeout);
    var long_http_fixture: LoginHttp = .{ .clock = &long_clock_fixture };
    _ = try requestLoginDevice(long_clock, long_deadline, long_http_fixture.capability());
    try std.testing.expectEqual(
        codex_auth.request_timeout.nanoseconds,
        long_http_fixture.device_budget.nanoseconds,
    );
}

const FakeLoginClock = struct {
    now: std.Io.Timestamp = .zero,
    slept: std.Io.Duration = .zero,

    fn capability(self: *FakeLoginClock) LoginClock {
        return .{ .context = self, .now_fn = read, .sleep_fn = sleep };
    }

    fn read(context: *anyopaque) std.Io.Timestamp {
        const self: *FakeLoginClock = @ptrCast(@alignCast(context));
        return self.now;
    }

    fn sleep(context: *anyopaque, duration: std.Io.Duration) anyerror!void {
        const self: *FakeLoginClock = @ptrCast(@alignCast(context));
        self.slept.nanoseconds += duration.nanoseconds;
        self.now = self.now.addDuration(duration);
    }
};

const LoginHttp = struct {
    const Poll = enum { pending, authorization };

    clock: *FakeLoginClock,
    poll: Poll = .pending,
    device_advance: std.Io.Duration = .zero,
    poll_advance: std.Io.Duration = .zero,
    exchange_advance: std.Io.Duration = .zero,
    device_budget: std.Io.Duration = .zero,
    poll_budget: std.Io.Duration = .zero,
    exchange_budget: std.Io.Duration = .zero,
    device_calls: u8 = 0,
    poll_calls: u8 = 0,
    exchange_calls: u8 = 0,

    fn capability(self: *LoginHttp) codex_auth.Http {
        return .{ .context = self, .post_fn = post };
    }

    fn post(
        context: *anyopaque,
        url: []const u8,
        _: []const u8,
        _: []const u8,
        out: []u8,
        timeout: std.Io.Duration,
    ) anyerror!codex_auth.HttpResponse {
        const self: *LoginHttp = @ptrCast(@alignCast(context));
        const body = if (std.mem.endsWith(u8, url, "/deviceauth/usercode")) body: {
            self.device_calls += 1;
            self.device_budget = timeout;
            self.clock.now = self.clock.now.addDuration(self.device_advance);
            break :body "{\"device_auth_id\":\"device\",\"user_code\":\"CODE\",\"interval\":5}";
        } else if (std.mem.endsWith(u8, url, "/deviceauth/token")) body: {
            self.poll_calls += 1;
            self.poll_budget = timeout;
            self.clock.now = self.clock.now.addDuration(self.poll_advance);
            break :body switch (self.poll) {
                .pending => "{\"error\":\"deviceauth_authorization_pending\"}",
                .authorization => "{\"authorization_code\":\"code\",\"code_verifier\":\"verifier\"}",
            };
        } else if (std.mem.endsWith(u8, url, "/oauth/token")) body: {
            self.exchange_calls += 1;
            self.exchange_budget = timeout;
            self.clock.now = self.clock.now.addDuration(self.exchange_advance);
            break :body "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\",\"account_id\":\"account\"}";
        } else return error.UnexpectedLoginUrl;
        @memcpy(out[0..body.len], body);
        return .{ .status = 200, .body = out[0..body.len] };
    }
};

const LoginStore = struct {
    save_calls: u8 = 0,

    fn capability(self: *LoginStore) codex_auth.Store {
        return .{
            .context = self,
            .load_fn = load,
            .save_fn = save,
            .delete_fn = delete,
        };
    }

    fn load(_: *anyopaque, _: []u8) anyerror!?[]const u8 {
        return error.UnexpectedLoad;
    }

    fn save(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *LoginStore = @ptrCast(@alignCast(context));
        self.save_calls += 1;
    }

    fn delete(_: *anyopaque) anyerror!void {
        return error.UnexpectedDelete;
    }
};

fn loginDevice(interval_seconds: u16) codex_auth.DeviceCode {
    var device: codex_auth.DeviceCode = .{
        .device_id_length = "device".len,
        .user_code_length = "CODE".len,
        .interval_seconds = interval_seconds,
    };
    @memcpy(device.device_id[0.."device".len], "device");
    @memcpy(device.user_code[0.."CODE".len], "CODE");
    return device;
}

test "Codex logout deletes a malformed stored credential without remote revocation" {
    var store_fixture: LogoutStore = .{ .record = "{truncated" };
    var http_fixture: LogoutHttp = .{};

    try logoutCodex(http_fixture.capability(), store_fixture.capability());

    try std.testing.expect(store_fixture.delete_called);
    try std.testing.expect(!store_fixture.present);
    try std.testing.expectEqual(@as(u8, 0), http_fixture.calls);
}

test "Codex logout surfaces local deletion failure after malformed stored credential" {
    var store_fixture: LogoutStore = .{
        .record = "{truncated",
        .delete_error = error.TestDeleteFailed,
    };
    var http_fixture: LogoutHttp = .{};

    try std.testing.expectError(
        error.TestDeleteFailed,
        logoutCodex(http_fixture.capability(), store_fixture.capability()),
    );

    try std.testing.expect(store_fixture.delete_called);
    try std.testing.expect(store_fixture.present);
    try std.testing.expectEqual(@as(u8, 0), http_fixture.calls);
}

const LogoutStore = struct {
    record: []const u8,
    present: bool = true,
    delete_called: bool = false,
    delete_error: ?anyerror = null,

    fn capability(self: *LogoutStore) codex_auth.Store {
        return .{
            .context = self,
            .load_fn = load,
            .save_fn = save,
            .delete_fn = delete,
        };
    }

    fn load(context: *anyopaque, out: []u8) anyerror!?[]const u8 {
        const self: *LogoutStore = @ptrCast(@alignCast(context));
        if (!self.present) return null;
        if (self.record.len > out.len) return error.TestRecordTooLarge;
        @memcpy(out[0..self.record.len], self.record);
        return out[0..self.record.len];
    }

    fn save(_: *anyopaque, _: []const u8) anyerror!void {
        return error.UnexpectedSave;
    }

    fn delete(context: *anyopaque) anyerror!void {
        const self: *LogoutStore = @ptrCast(@alignCast(context));
        self.delete_called = true;
        if (self.delete_error) |err| return err;
        self.present = false;
    }
};

const LogoutHttp = struct {
    calls: u8 = 0,

    fn capability(self: *LogoutHttp) codex_auth.Http {
        return .{ .context = self, .post_fn = post };
    }

    fn post(
        context: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []u8,
        _: std.Io.Duration,
    ) anyerror!codex_auth.HttpResponse {
        const self: *LogoutHttp = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.UnexpectedRevoke;
    }
};

test "patch display escapes terminal controls and backslashes losslessly" {
    const escaped = try escapePatch(std.testing.allocator, "safe\n\x1b[2J\\x1b\t\xff");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("safe\n\\x1b[2J\\\\x1b\\x09\\xff", escaped);
}
