const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const codex_auth = @import("codex_auth.zig");
const codex_native = @import("codex_native.zig");
const codex_provider = @import("codex_provider.zig");
const conversation = @import("conversation.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const store_module = @import("host_store.zig");
const coordinator = @import("turn_coordinator.zig");
const execution_cells = @import("execution_cells.zig");

const request_buffer_size: usize = 1024 * 1024;

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
    codex_capture_metrics_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    try model_contract.validateBuiltinCatalog();
    const arguments = try parseArguments(try init.minimal.args.toSlice(allocator));
    var native_http: codex_native.NativeHttp = .{ .io = init.io, .allocator = allocator };
    var keychain: codex_native.KeychainStore = .{};
    if (arguments.codex_login) return loginCodex(init.io, native_http.capability(), keychain.capability());
    if (arguments.codex_logout) return logoutCodex(native_http.capability(), keychain.capability());

    const model = arguments.model orelse return error.MissingModel;
    const uses_codex = std.mem.startsWith(u8, model, "codex:");
    if (uses_codex) try codex_native.initializeModelTransport();
    defer if (uses_codex) codex_native.deinitializeModelTransport();
    const state_path = try resolveStatePath(init.minimal.environ, allocator, arguments.state_path);
    defer allocator.free(state_path);
    var state_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, state_path, .{ .permissions = .fromMode(0o700) });
    defer state_dir.close(init.io);
    const database_path = try std.fs.path.join(allocator, &.{ state_path, "host.sqlite3" });
    defer allocator.free(database_path);
    var store = try store_module.Store.open(database_path);
    defer store.close();

    if (uses_codex) {
        if (arguments.fixture_response != null or arguments.fixture_bash_command != null or
            arguments.fixture_patch_path != null) return error.CodexFixtureArgumentsConflict;
        var authorization: codex_native.NativeAuthorization = .{
            .io = init.io,
            .store = keychain.capability(),
            .http = native_http.capability(),
        };
        var transport: codex_native.NativeTransport = .{ .io = init.io };
        var metrics: codex_provider.CaptureMetrics = .{};
        var codex: codex_provider.CodexProvider = .{
            .allocator = allocator,
            .authorization = authorization.capability(),
            .transport = transport.capability(),
            .capture_metrics = if (arguments.codex_capture_metrics_path != null) &metrics else null,
        };
        try runInvocation(init.io, allocator, &store, arguments, model, codex.provider());
        if (arguments.codex_capture_metrics_path) |path| try writeCaptureMetrics(init.io, path, metrics);
        return;
    }
    if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
    const response = arguments.fixture_response orelse return error.MissingFixtureResponse;
    if (arguments.fixture_bash_command != null and arguments.fixture_patch_path != null) {
        const patch = try readPatch(init.io, allocator, arguments.fixture_patch_path.?);
        defer allocator.free(patch);
        var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
        const call = try bash_tool.encodeCall(&call_buffer, .{
            .command = arguments.fixture_bash_command.?,
            .timeout_ms = arguments.bash_timeout_ms,
        });
        var fixture: deterministic_provider.RepairFixture = .{
            .expected_task = arguments.task orelse return error.MissingTask,
            .bash_call = call,
            .patch = patch,
            .final_answer = response,
        };
        return runInvocation(init.io, allocator, &store, arguments, model, fixture.provider());
    }
    if (arguments.fixture_patch_path) |path| {
        const patch = try readPatch(init.io, allocator, path);
        defer allocator.free(patch);
        var fixture: deterministic_provider.ToolFixture = .{
            .expected_task = arguments.task orelse return error.MissingTask,
            .tool = .apply_patch,
            .tool_arguments = patch,
            .final_answer = response,
            .expected_patch_status = if (arguments.dangerously_bypass_permissions) .applied else .denied,
        };
        return runInvocation(init.io, allocator, &store, arguments, model, fixture.provider());
    }
    if (arguments.fixture_bash_command) |command| {
        var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
        const call = try bash_tool.encodeCall(&call_buffer, .{ .command = command, .timeout_ms = arguments.bash_timeout_ms });
        var fixture: deterministic_provider.ToolFixture = .{
            .expected_task = arguments.task orelse return error.MissingTask,
            .tool_arguments = call,
            .final_answer = response,
        };
        return runInvocation(init.io, allocator, &store, arguments, model, fixture.provider());
    }
    var fixture: deterministic_provider.Fixture = .{ .expected_task = arguments.task, .final_answer = response };
    try runInvocation(init.io, allocator, &store, arguments, model, fixture.provider());
}

fn runInvocation(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store_module.Store,
    arguments: Arguments,
    model: []const u8,
    provider: model_operation.Provider,
) !void {
    var ids = coordinator.IdentitySource.random(io);
    var workspace_buffer: [store_module.max_path_bytes]u8 = undefined;
    const session_id, const turn_id = if (arguments.resume_id) |session_id| blk: {
        const session = try store.readSession(session_id);
        const workspace = try store.readSessionWorkspace(session_id, &workspace_buffer);
        if (session.active_turn_id) |active| {
            if (arguments.task != null) return error.SessionBusy;
            break :blk .{ session_id, active };
        }
        const task = arguments.task orelse {
            try renderTurn(io, store, session.latest_turn_id orelse return error.SessionHasNoTurns);
            return;
        };
        const new_turn_id = try ids.take();
        _ = try store.admitTurn(.{
            .session_id = session_id,
            .turn_id = new_turn_id,
            .turn_ordinal = try store.nextTurnOrdinalForSession(session_id),
            .entry_id = try ids.take(),
            .content_id = try ids.take(),
            .expected_conversation_revision = session.conversation_revision,
            .workspace_path = workspace,
            .access_scope_digest = store_module.semanticDigest(.access_scope, workspace),
            .admission_digest = store_module.semanticDigest(.turn, task),
            .user_text = task,
        });
        break :blk .{ session_id, new_turn_id };
    } else blk: {
        const task = arguments.task orelse return error.MissingTask;
        const workspace = try resolveWorkspacePath(io, allocator, arguments.repo_path);
        defer allocator.free(workspace);
        if (workspace.len > workspace_buffer.len) return error.WorkspacePathTooLong;
        @memcpy(workspace_buffer[0..workspace.len], workspace);
        const session_id = try ids.take();
        const turn_id = try ids.take();
        _ = try store.admitTurn(.{
            .session_id = session_id,
            .turn_id = turn_id,
            .turn_ordinal = 1,
            .entry_id = try ids.take(),
            .content_id = try ids.take(),
            .expected_conversation_revision = 0,
            .workspace_path = workspace,
            .access_scope_digest = store_module.semanticDigest(.access_scope, workspace),
            .admission_digest = store_module.semanticDigest(.turn, task),
            .user_text = task,
        });
        break :blk .{ session_id, turn_id };
    };
    var line: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&line, "Session: {x:0>16}\n", .{session_id});
    try std.Io.File.stdout().writeStreamingAll(io, label);
    const workspace = try store.readSessionWorkspace(session_id, &workspace_buffer);
    try driveTurn(io, allocator, store, &ids, turn_id, model, workspace, provider, arguments.dangerously_bypass_permissions);
}

fn driveTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store_module.Store,
    ids: *coordinator.IdentitySource,
    turn_id: u64,
    model: []const u8,
    workspace: []const u8,
    provider: model_operation.Provider,
    bypass_permissions: bool,
) !void {
    const request = try allocator.alloc(u8, request_buffer_size);
    defer allocator.free(request);
    const candidate = try allocator.alloc(u8, model_protocol.max_response_size);
    defer allocator.free(candidate);
    const tool_call_stride = conversation.call_header_size + model_contract.max_tool_key_size + model_contract.max_tool_arguments_envelope_size;
    const tool_call = try allocator.alloc(u8, model_contract.max_tool_count * tool_call_stride);
    defer allocator.free(tool_call);
    const descriptor = try allocator.alloc(u8, model_contract.max_tool_count * coordinator.max_patch_descriptor_size);
    defer allocator.free(descriptor);
    const completion = try allocator.alloc(u8, @max(patch_tool.result_size, bash_tool.result_header_size + bash_tool.max_output_size));
    defer allocator.free(completion);
    const visible = try allocator.alloc(u8, conversation.result_header_size + 2 * bash_tool.max_output_size + 256);
    defer allocator.free(visible);
    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    // Capacity is a runtime host choice, not retained Session state or a
    // persisted product limit. The synchronous CLI needs one physical cell.
    var cells = try execution_cells.Pool.init(allocator, 1);
    defer cells.deinit();
    for (0..128) |_| {
        const snapshot = try store.loadDecisionSnapshot(turn_id);
        switch (store_module.classify(snapshot)) {
            .completed, .failed, .cancelled => return renderTurn(io, store, turn_id),
            .in_flight => {
                var lost_frontier: [8]store_module.OperationView = undefined;
                const lost_count = try store.readUnresolvedOperations(turn_id, &lost_frontier);
                var lost_operation_id: ?u64 = null;
                for (lost_frontier[0..lost_count]) |lost_candidate| {
                    if (try store.nextAttemptOrdinalForOperation(lost_candidate.operation_id) == 1) continue;
                    if (lost_operation_id != null) return error.AmbiguousEffectRecovery;
                    lost_operation_id = lost_candidate.operation_id;
                }
                const lost = try store.readOperation(lost_operation_id orelse return error.MissingEffectRecovery);
                if (lost.kind == .model) {
                    try coordinator.failLostModel(store, ids, turn_id, lost.operation_id);
                    continue;
                }
                const action: coordinator.Action = .{
                    .turn_id = turn_id,
                    .parent_model_operation_id = lost.caused_by_operation_id orelse return error.InvalidActionProvenance,
                    .operation_id = lost.operation_id,
                    .call_entry_id = lost.caused_by_entry_id orelse return error.InvalidActionProvenance,
                    .kind = lost.kind,
                };
                switch (lost.kind) {
                    .bash => try coordinator.resolveLostAction(store, ids, action, visible),
                    .apply_patch => {
                        const cell = try cells.reserve();
                        defer cell.release();
                        try coordinator.executePatchAction(store, ids, io, action, cell, .{
                            .descriptor = descriptor,
                            .completion = completion,
                            .visible_result = visible,
                        });
                    },
                    .model => unreachable,
                }
                continue;
            },
            .runnable => {},
        }
        var frontier: [8]store_module.OperationView = undefined;
        const count = try store.readUnresolvedOperations(turn_id, &frontier);
        if (count != 0 and frontier[0].kind != .model) {
            const operation = try store.readOperation(frontier[0].operation_id);
            const action: coordinator.Action = .{
                .turn_id = turn_id,
                .parent_model_operation_id = operation.caused_by_operation_id orelse return error.InvalidActionProvenance,
                .operation_id = operation.operation_id,
                .call_entry_id = operation.caused_by_entry_id orelse return error.InvalidActionProvenance,
                .kind = operation.kind,
            };
            const has_completion = (try store.readUnresolvedCompletion(operation.operation_id)) != null;
            if (!has_completion and !bypass_permissions and
                !try promptPermission(io, &stdin_reader.interface, operation))
            {
                try coordinator.denyAction(store, ids, action, visible);
                continue;
            }
            const cell = try cells.reserve();
            defer cell.release();
            switch (action.kind) {
                .bash => try coordinator.executeBashAction(store, ids, io, allocator, action, cell, .{ .descriptor = descriptor, .completion = completion, .visible_result = visible }),
                .apply_patch => try coordinator.executePatchAction(store, ids, io, action, cell, .{ .descriptor = descriptor, .completion = completion, .visible_result = visible }),
                .model => unreachable,
            }
            continue;
        }
        if (try coordinator.publishPendingToolResults(store, ids, turn_id)) continue;
        const cell = try cells.reserve();
        defer cell.release();
        const advanced = try coordinator.advanceModel(store, ids, turn_id, model, workspace, io, provider, cell, .{
            .request = request,
            .candidate = candidate,
            .tool_call = tool_call,
            .descriptor = descriptor,
        });
        switch (advanced) {
            .completed, .failed => return renderTurn(io, store, turn_id),
            .action => {},
        }
    }
    return error.AdvancementLimitExceeded;
}

fn renderTurn(io: std.Io, store: *store_module.Store, turn_id: u64) !void {
    const turn = try store.readTurn(turn_id);
    switch (turn.outcome orelse return error.TurnStillActive) {
        .completed => {
            const content_id = turn.outcome_content_id orelse return error.MissingFinalAnswer;
            const length = try store.contentLength(content_id);
            if (length > model_protocol.max_assistant_text_size) return error.InvalidFinalAnswer;
            var bytes: [model_protocol.max_assistant_text_size]u8 = undefined;
            const answer = try store.readContent(content_id, bytes[0..length]);
            try std.Io.File.stdout().writeStreamingAll(io, "Final Answer:\n");
            try std.Io.File.stdout().writeStreamingAll(io, answer);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
        },
        .failed => return error.TurnFailed,
        .cancelled => try std.Io.File.stdout().writeStreamingAll(io, "Cancelled.\n"),
    }
}

fn promptPermission(
    io: std.Io,
    reader: *std.Io.Reader,
    operation: store_module.OperationRecord,
) !bool {
    var prompt: [160]u8 = undefined;
    const bytes = try std.fmt.bufPrint(
        &prompt,
        "Approval required. Allow {s} Action {d}? [y/N] ",
        .{ @tagName(operation.kind), operation.operation_id },
    );
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
    const line = (try reader.takeDelimiter('\n')) orelse return false;
    const answer = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn readPatch(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(patch_tool.max_patch_size));
}

fn resolveWorkspacePath(io: std.Io, allocator: std.mem.Allocator, configured: ?[]const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const joined = if (configured) |path|
        if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ cwd, path })
    else
        try allocator.dupe(u8, cwd);
    defer allocator.free(joined);
    var canonical: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try std.Io.Dir.cwd().realPathFile(io, joined, &canonical);
    return allocator.dupe(u8, canonical[0..length]);
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
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--dangerously-bypass-permissions")) {
            parsed.dangerously_bypass_permissions = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--codex-login")) {
            parsed.codex_login = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--codex-logout")) {
            parsed.codex_logout = true;
            continue;
        }
        const target: enum { state, repo, model, response, bash, patch, timeout, resume_id, metrics } =
            if (std.mem.eql(u8, argument, "--state")) .state else if (std.mem.eql(u8, argument, "--repo")) .repo else if (std.mem.eql(u8, argument, "--model")) .model else if (std.mem.eql(u8, argument, "--fixture-response")) .response else if (std.mem.eql(u8, argument, "--fixture-bash-command")) .bash else if (std.mem.eql(u8, argument, "--fixture-patch")) .patch else if (std.mem.eql(u8, argument, "--bash-timeout-ms")) .timeout else if (std.mem.eql(u8, argument, "--resume")) .resume_id else if (std.mem.eql(u8, argument, "--codex-capture-metrics")) .metrics else if (std.mem.startsWith(u8, argument, "--")) return error.UnknownOption else {
                if (parsed.task != null) return error.MultipleTasks;
                parsed.task = argument;
                continue;
            };
        index += 1;
        if (index == args.len) return error.InvalidArguments;
        switch (target) {
            .state => parsed.state_path = args[index],
            .repo => parsed.repo_path = args[index],
            .model => parsed.model = args[index],
            .response => parsed.fixture_response = args[index],
            .bash => parsed.fixture_bash_command = args[index],
            .patch => parsed.fixture_patch_path = args[index],
            .timeout => parsed.bash_timeout_ms = try std.fmt.parseInt(u32, args[index], 10),
            .resume_id => parsed.resume_id = try std.fmt.parseInt(u64, args[index], 16),
            .metrics => parsed.codex_capture_metrics_path = args[index],
        }
    }
    if (parsed.codex_login or parsed.codex_logout) {
        if (parsed.codex_login == parsed.codex_logout or parsed.task != null or parsed.model != null or
            parsed.resume_id != null or parsed.repo_path != null or parsed.state_path != null)
            return error.AuthorizationArgumentsConflict;
        return parsed;
    }
    if (parsed.model) |model| try validateModelArgument(model);
    return parsed;
}

fn validateModelArgument(model: []const u8) !void {
    if (model.len == 0 or model.len > model_operation.max_model_name_size or
        !std.unicode.utf8ValidateSlice(model)) return error.InvalidModelArgument;
    const suffix = if (std.mem.startsWith(u8, model, "codex:"))
        model["codex:".len..]
    else if (std.mem.startsWith(u8, model, "fixture:"))
        model["fixture:".len..]
    else
        return error.UnsupportedModel;
    if (suffix.len == 0 or suffix[0] == ' ' or suffix[suffix.len - 1] == ' ') return error.InvalidModelArgument;
}

fn writeCaptureMetrics(io: std.Io, path: []const u8, metrics: codex_provider.CaptureMetrics) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(
        &buffer,
        "{{\"dispatch_count\":{d},\"decoded_occupied_high_water_bytes\":{d},\"decoded_capacity_high_water_bytes\":{d}}}\n",
        .{ metrics.dispatch_count, metrics.decoded_occupied_high_water_bytes, metrics.decoded_capacity_high_water_bytes },
    );
    try file.writeStreamingAll(io, report);
}

fn loginCodex(io: std.Io, http: codex_auth.Http, store: codex_auth.Store) !void {
    const device = try codex_auth.requestDeviceCode(http);
    var prompt: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &prompt,
        "Open {s} and enter code {s}. Waiting for authorization.\n",
        .{ codex_auth.verification_url, device.userCode() },
    );
    try std.Io.File.stdout().writeStreamingAll(io, message);
    var poll_seconds = device.interval_seconds;
    while (true) switch (try codex_auth.pollDeviceCode(http, &device)) {
        .pending => try std.Io.sleep(io, .fromSeconds(poll_seconds), .awake),
        .slow_down => {
            poll_seconds = @min(@as(u16, 60), poll_seconds + 5);
            try std.Io.sleep(io, .fromSeconds(poll_seconds), .awake);
        },
        .authorization => |authorization| {
            var authorization_value = authorization;
            defer authorization_value.scrub();
            var tokens = try codex_auth.exchangeCode(http, &authorization_value);
            defer tokens.scrub();
            var encoded: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
            defer std.crypto.secureZero(u8, &encoded);
            try store.save(try codex_auth.encodeStored(&tokens, &encoded));
            return;
        },
    };
}

fn logoutCodex(http: codex_auth.Http, store: codex_auth.Store) !void {
    var encoded: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded);
    if (try store.load(&encoded)) |bytes| {
        var tokens = codex_auth.decodeStored(bytes) catch null;
        if (tokens) |*value| {
            defer value.scrub();
            codex_auth.revoke(http, value) catch {};
        }
    }
    try store.delete();
}
