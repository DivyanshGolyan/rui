const std = @import("std");
const server_mcp = @import("server_mcp.zig");
const server_mcp_relist = @import("server_mcp_relist.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");
const tool_record = @import("tool_record.zig");
const server_read_image = @import("server_read_image.zig");
const action_attempt = @import("action_attempt.zig");
const bash = @import("bash.zig");
const codecs = @import("codecs.zig");
const execution = @import("execution.zig");
const failure_class = @import("failure_class.zig");
const DispatchCapacity = @import("execution.zig").DispatchCapacity;
const execution_turn = @import("execution_turn.zig");
const failed_responses = @import("failed_responses.zig");
const model_adapter = @import("model_adapter.zig");
const models_dev = @import("models_dev.zig");
const model_list = @import("model_list.zig");
const named_scratch = @import("named_scratch.zig");
const output_decode = @import("output_decode.zig");
const output_format = @import("output_format.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const process = @import("os/process.zig");
const provider = @import("provider.zig");
const providers = @import("providers.zig");
const turn_states_module = @import("turn_states.zig");
const protocol = @import("protocol.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const wire_request = @import("wire_request.zig");
const retry_policy = @import("retry_policy.zig");
const store_module = @import("store.zig");
const stderr = @import("stderr.zig");
const server_host = @import("server_host.zig");
const execution_owner = @import("execution_owner.zig");
const host_drain = @import("host_drain.zig");
const signal_stack = @import("signal_stack.zig");
const child_exit_wake = @import("child_exit_wake.zig");
const tools = @import("tools.zig");
const test_poll = @import("test_poll");
const bash_service = @import("testing/bash_service.zig");
const environment = @import("environment.zig");
const SessionEnvironments = @import("SessionEnvironments.zig");
const child_environment = @import("child_environment.zig");
const find_tools = @import("find_tools.zig");
const h2 = @import("h2");
const read_action_tool = @import("read_action_tool.zig");
const read_transcript = @import("read_transcript.zig");
const session_skills = @import("session_skills.zig");
const Host = server_host.Host;
const AuthWorker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: State = .idle,
    credential: providers.Lease = undefined,
    work: providers.Work = undefined,
    stopping: bool = false,

    const Job = union(enum) { acquire: providers.Authentication, refresh: providers.Credential.Refresh };
    const State = union(enum) { idle, requested: Job, ready, in_use, refreshed: bool, failed: anyerror };
    const Result = union(enum) { ready: *const providers.Lease, refreshed: bool, failed: anyerror };

    pub fn idle(self: *AuthWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .idle;
    }

    pub fn request(self: *AuthWorker, source: providers.Authentication) void {
        self.requestJob(.{ .acquire = source });
    }

    pub fn requestRefresh(self: *AuthWorker, refresh: providers.Credential.Refresh) void {
        self.requestJob(.{ .refresh = refresh });
    }

    fn requestJob(self: *AuthWorker, job: Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.state == .idle);
        self.state = .{ .requested = job };
        self.condition.broadcast(self.io);
    }

    pub fn take(self: *AuthWorker) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result: Result = switch (self.state) {
            .idle, .requested, .in_use => return null,
            .ready => .{ .ready = &self.credential },
            .refreshed => |refreshed| .{ .refreshed = refreshed },
            .failed => |err| .{ .failed = err },
        };
        self.state = if (result == .ready) .in_use else .idle;
        return result;
    }

    pub fn finish(self: *AuthWorker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.state == .in_use);
        self.credential.release();
        self.state = .idle;
    }

    pub fn stop(self: *AuthWorker, thread: std.Thread) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        thread.join();
        std.debug.assert(self.state != .in_use);
        if (self.state == .ready) self.credential.release();
    }

    pub fn run(self: *AuthWorker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.state != .requested)
                self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.state.requested;
            self.mutex.unlock(self.io);
            const answer: State = switch (job) {
                .acquire => |source| if (providers.acquire(source, self.io, &self.work, &self.credential)) |_| .ready else |err| .{ .failed = err },
                .refresh => |refresh| if (providers.refresh(refresh.source, self.io, refresh.generation)) |refreshed| .{ .refreshed = refreshed } else |err| .{ .failed = err },
            };
            self.mutex.lockUncancelable(self.io);
            self.state = answer;
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

const BashWork = union {
    execution: bash.Execution,
    prepared_cleanup: bash.PreparedCleanup,
};

/// The execution thread's own state: rows of the thread's table, guarded by the thread alone.
const Run = struct {
    host: *Host,
    settings: Settings,
    execution: *execution_owner.Execution,
    custody: *execution.CustodyPool,
    auth_worker: ?*AuthWorker = null,
    scratch_budget: ?provider.ScratchBudget = null,
    turn_states: turn_states_module.PerProvider = .{},
    history_memos: model_adapter.HistoryMemos = .{},
    bash_work: []BashWork = &.{},
    slot_changes: u64 = 0,
};

/// Settings the execution thread reads for its whole life, passed in by the thread's spawn.
pub const Settings = struct {
    bash_path: []const u8 = server_host.default_bash_path,
    bash_timeout_ms: u64 = server_host.default_bash_timeout_ms,
    background_after_ms: u64 = @import("host_settings.zig").default_background_after_ms,
    catalog_url: ?[]const u8 = null,
    failed_response_store: ?std.Io.Dir = null,
};

const pages = @import("os/pages.zig");
const mapZeroed = pages.mapZeroed;
const unmapZeroed = pages.unmapZeroed;
const Limits = server_host.Limits;
const SettlementTrace = server_host.SettlementTrace;
const default_bash_path = server_host.default_bash_path;
const test_pause = @import("testing/pause.zig");
const pause = server_host.pause;
const bashReclaimHeld = server_host.bashReclaimHeld;
const retryRecovered = server_host.retryRecovered;

fn reachAction(run: *Run, point: test_pause.Point, binding: store_module.ActionAttemptBinding) void {
    if (comptime test_pause.enabled) if (run.host.probes.pause_owner) |owner| {
        _ = owner.reach(point, .{
            .operation = binding.parent_operation_id,
            .action = binding.action_id,
            .attempt = @import("attempt.zig").action_attempt_ordinal,
        }) catch {};
    };
}

fn reachModel(run: *Run, point: test_pause.Point, binding: store_module.AttemptBinding) void {
    if (comptime test_pause.enabled) if (run.host.probes.pause_owner) |owner| {
        _ = owner.reach(point, .{ .operation = binding.operation_id, .attempt = binding.attempt_ordinal }) catch {};
    };
}

const AttemptOwner = struct {
    token: execution.CustodyToken = undefined,
    binding: store_module.AttemptBinding = undefined,
    purpose: store_module.ModelOperationKind = undefined,
};

const ProviderSlot = struct {
    owner: AttemptOwner,
    rejection: providers.Credential.Rejection = .settle,
    transfer: provider.Transfer = undefined,

    fn failureCode(self: *const ProviderSlot, failure: execution.TransferFailure, buffer: *[96]u8) []const u8 {
        if (execution.rejectsCredential(failure)) switch (self.rejection) {
            .key_rejected => return failure_class.api_key_rejected,
            .settle, .refresh_once => {},
        };
        return failure.codeText(buffer);
    }
};

const NamedScratchSlot = struct {
    token: execution.CustodyToken,
    owner: named_scratch.Owner,
};

const BashSlot = struct {
    attempt: action_attempt.Attempt,
    execution: *bash.Execution,
    stop_accepted: bool = false,
    delivery: union(enum) {
        open,
        closed: struct {
            closing: action_attempt.Closing,
            reclaim_at: std.Io.Clock.Timestamp,
            reclaim_failed: bool = false,
        },
    } = .open,
};

const BashPreparedCleanupSlot = struct {
    closing: action_attempt.Closing,
    cleanup: *bash.PreparedCleanup,
};

const BashPreparingSlot = struct {
    attempt: action_attempt.Attempt,
};

const bash_labels: action_attempt.Labels = .{
    .admission = "Bash Attempt admission",
    .custody = "Bash custody attachment",
    .stop = "Bash stop reconciliation",
    .result = "Bash result settlement",
    .failure = "Bash failure settlement",
};

const ModelPreparingSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    purpose: ?store_module.ModelOperationKind = null,
};

const ModelAuthenticatingSlot = struct {
    owner: ModelPreparingSlot,
    requested: bool = false,
    cancelled: bool = false,
};

const ModelRefreshingSlot = struct {
    owner: AttemptOwner,
    refresh: providers.Credential.Refresh,
    request_id: protocol.Bounded(256),
    requested: bool = false,
    cancelled: bool = false,
};

const PendingFailure = struct {
    floor: store_module.HistoryFloorPreparation,
    code: protocol.Bounded(96),
    diagnostic: protocol.Bounded(512),
    report: output_decode.Report,
    request_id: protocol.Bounded(256),
    kind: std.meta.Tag(store_module.ModelFailure),

    fn init(self: *PendingFailure, operation: u64, failure: store_module.ModelFailure) void {
        self.code = .{};
        self.diagnostic = .{};
        self.report = .{};
        self.request_id = .{};
        self.kind = failure;
        self.code.set(failure.code()) catch unreachable;
        self.report.set(failure.report()) catch unreachable;
        if (failure.diagnostic()) |detail| self.diagnostic.set(detail) catch unreachable;
        switch (failure) {
            .uncorrelated => {},
            .correlated => |record| self.request_id = record.request_id,
            .rejected => |record| self.request_id = record.request_id,
        }
        self.floor.init(operation);
    }

    fn value(self: *const PendingFailure) store_module.ModelFailure {
        return switch (self.kind) {
            .uncorrelated => .{ .uncorrelated = self.code.slice() },
            .correlated => .{ .correlated = .{ .code = self.code.slice(), .request_id = self.request_id, .report = self.report.slice() } },
            .rejected => .{ .rejected = .{ .code = self.code.slice(), .request_id = self.request_id, .report = self.report.slice(), .diagnostic = self.diagnostic.slice() } },
        };
    }
};

const ModelFailurePreparingSlot = struct {
    owner: AttemptOwner,
    response: provider.SealedResponse,

    fn deinit(self: *ModelFailurePreparingSlot) void {
        self.response.state(PendingFailure).floor.deinit();
        self.response.deinit();
    }
};

comptime {
    if (@sizeOf(ModelFailurePreparingSlot) > @sizeOf(ProviderSlot) or @alignOf(ModelFailurePreparingSlot) > @alignOf(ProviderSlot))
        @compileError("pending overflow failure exceeds an existing provider slot");
}

pub const ExecutionSlot = union(enum) {
    free,
    model_preparing: ModelPreparingSlot,
    model_authenticating: ModelAuthenticatingSlot,
    model_refreshing: ModelRefreshingSlot,
    model_failure_preparing: ModelFailurePreparingSlot,
    provider: ProviderSlot,
    bash_preparing: BashPreparingSlot,
    bash: BashSlot,
    bash_prepared_cleanup: BashPreparedCleanupSlot,
    named_scratch: NamedScratchSlot,
};

const SlotCustody = enum { free, attached, detached };

fn slotCustody(slot: *const ExecutionSlot) SlotCustody {
    return switch (slot.*) {
        .free => .free,
        .model_preparing, .model_authenticating, .model_refreshing, .model_failure_preparing, .provider, .bash_preparing => .attached,
        .bash => |*active| switch (active.delivery) {
            .open => .attached,
            .closed => .detached,
        },
        .bash_prepared_cleanup, .named_scratch => .detached,
    };
}

fn slotToken(slot: *const ExecutionSlot) ?execution.CustodyToken {
    return switch (slot.*) {
        .free => null,
        .model_preparing => |*active| active.token,
        .model_authenticating => |*active| active.owner.token,
        .model_refreshing => |*active| active.owner.token,
        .model_failure_preparing => |*active| active.owner.token,
        .provider => |*active| active.owner.token,
        .bash_preparing => |*active| active.attempt.token,
        .bash => |*active| active.attempt.token,
        .bash_prepared_cleanup => |*retained| retained.closing.token,
        .named_scratch => |*retained| retained.token,
    };
}

fn slotBinding(slot: *const ExecutionSlot) ?execution.CustodyBinding {
    return switch (slot.*) {
        .free, .bash_prepared_cleanup, .named_scratch => null,
        .model_preparing => |*active| .{ .model = active.binding },
        .model_authenticating => |*active| .{ .model = active.owner.binding },
        .model_refreshing => |*active| .{ .model = active.owner.binding },
        .model_failure_preparing => |*active| .{ .model = active.owner.binding },
        .provider => |*active| .{ .model = active.owner.binding },
        .bash_preparing => |*active| .{ .action = active.attempt.binding },
        .bash => |*active| .{ .action = active.attempt.binding },
    };
}

fn attachSlot(
    run: *Run,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: anytype,
) !@TypeOf(permit.binding) {
    std.debug.assert(slot.* == .free);
    const binding = try run.custody.attach(token, permit);
    slot.* = switch (@TypeOf(binding)) {
        store_module.AttemptBinding => .{ .model_preparing = .{ .token = token, .binding = binding } },
        else => @compileError("not a model Attempt binding: " ++ @typeName(@TypeOf(binding))),
    };
    run.slot_changes +%= 1;
    return binding;
}

fn isActionSlot(slot: *const ExecutionSlot) bool {
    return switch (slot.*) {
        .bash_preparing, .bash, .bash_prepared_cleanup => true,
        else => false,
    };
}

/// Moves a slot between arms. Action custody is not moved here: an action
/// slot's Attempt closes it and its Closing finishes it, so moves into or out
/// of an action arm change only the slot.
fn moveSlot(
    run: *Run,
    slot: *ExecutionSlot,
    comptime arm: std.meta.Tag(ExecutionSlot),
    payload: @FieldType(ExecutionSlot, @tagName(arm)),
) void {
    const token = slotToken(slot);
    const from = slotCustody(slot);
    const action = isActionSlot(slot) or comptime switch (arm) {
        .bash_preparing, .bash, .bash_prepared_cleanup => true,
        else => false,
    };
    slot.* = @unionInit(ExecutionSlot, @tagName(arm), payload);
    run.slot_changes +%= 1;
    if (slotToken(slot)) |kept| std.debug.assert(token == null or std.meta.eql(kept, token.?));
    if (action) return;
    const to = slotCustody(slot);
    if (from == .attached and to != .attached) {
        std.debug.assert(!run.custody.holdsUndeliveredAction(token.?) or !run.host.lifecycle.launchAllowed());
        run.custody.detach(token.?) catch unreachable;
    }
    switch (to) {
        .attached => std.debug.assert(from == .attached),
        .detached => {},
        .free => run.custody.cleanupComplete(token.?) catch unreachable,
    }
}

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;

/// Test-only Attempt over a custody record the test attaches itself.
fn testAttempt(host: *Host, custody: *execution.CustodyPool, token: execution.CustodyToken, binding: store_module.ActionAttemptBinding) action_attempt.Attempt {
    return .{
        .parts = .{ .store = host.store, .lifecycle = host.lifecycle, .probes = host.probes, .custody = custody },
        .token = token,
        .labels = bash_labels,
        .binding = binding,
    };
}

fn testBashAttempt(host: *Host, custody: *execution.CustodyPool, token: execution.CustodyToken, permit: anytype) !action_attempt.Attempt {
    return testAttempt(host, custody, token, try custody.attach(token, permit));
}

test "execution slots change only through attachSlot and moveSlot" {
    const source = @embedFile("server_execution.zig");
    var production: std.ArrayList(u8) = .empty;
    defer production.deinit(std.testing.allocator);
    var rest: []const u8 = source;
    while (std.mem.indexOf(u8, rest, "\ntest \"")) |start| {
        try production.appendSlice(std.testing.allocator, rest[0..start]);
        const end = std.mem.indexOfPos(u8, rest, start, "\n}\n") orelse return error.UnterminatedTest;
        rest = rest[end + 2 ..];
    }
    try production.appendSlice(std.testing.allocator, rest);
    const code = production.items;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "slot.*" ++ " = "));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "run.slot_changes" ++ " +%= 1;"));
    inline for (comptime std.meta.fieldNames(ExecutionSlot)) |arm| {
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, code, " = ." ++ arm ++ ";"));
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, code, " = .{ ." ++ arm ++ " ="));
    }
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, code, "]" ++ " = ."));
}

fn checkSlotCustodyAgreement(slots: []const ExecutionSlot, custody: *execution.CustodyPool, mcp: ?*const server_mcp.Calls) !void {
    var represented: usize = 0;
    for (slots, 0..) |*slot, i| {
        const token = slotToken(slot) orelse continue;
        switch (slotCustody(slot)) {
            .free => unreachable,
            .attached => try custody.checkAttached(token, slotBinding(slot).?),
            .detached => try custody.checkDetached(token, slotBinding(slot)),
        }
        represented += 1;
        if (mcp) |calls| for (calls.entries) |entry| if (entry) |active| {
            if (std.meta.eql(active.attempt.token, token)) return error.DuplicateExecutionToken;
        };
        for (slots[i + 1 ..]) |*later| {
            const other = slotToken(later) orelse continue;
            if (other.index == token.index and other.generation == token.generation) return error.DuplicateExecutionToken;
        }
    }
    if (mcp) |calls| for (calls.entries, 0..) |entry, i| if (entry) |active| {
        try custody.checkAttached(active.attempt.token, .{ .action = active.attempt.binding });
        represented += 1;
        for (calls.entries[i + 1 ..]) |later| if (later) |other| {
            if (std.meta.eql(active.attempt.token, other.attempt.token)) return error.DuplicateExecutionToken;
        };
    };
    if (represented != custody.occupied()) return error.OrphanedExecutionCustody;
}

fn checkSharedPreparation(
    slots: []const ExecutionSlot,
    model_preparation: ?*model_adapter.Preparation,
    bash_preparation: ?*const bash.Preparation,
) !void {
    var model_slot: ?store_module.AttemptBinding = null;
    var bash_slot: ?store_module.ActionAttemptBinding = null;
    for (slots) |*slot| switch (slot.*) {
        .model_preparing => |*active| {
            if (model_slot != null) return error.PreparationOwnershipMismatch;
            model_slot = active.binding;
        },
        .bash_preparing => |*active| {
            if (bash_slot != null) return error.PreparationOwnershipMismatch;
            bash_slot = active.attempt.binding;
        },
        else => {},
    };
    if (model_preparation) |preparation| {
        const binding = model_slot orelse return error.PreparationOwnershipMismatch;
        try preparation.checkIntegrity(binding);
    } else if (model_slot != null) {
        return error.PreparationOwnershipMismatch;
    }
    if (bash_slot) |slot_binding| {
        const preparation = bash_preparation orelse return error.PreparationOwnershipMismatch;
        if (preparation.action_id != slot_binding.action_id) return error.PreparationOwnershipMismatch;
    }
}

const AdmissionProgress = enum { no_work, retry_later, progress, admitted };

const LifecycleMeasurement = struct {
    last_service_at: ?std.Io.Clock.Timestamp = null,
    next_trace_at: ?std.Io.Clock.Timestamp = null,
    maximum_gap_ns: u64 = 0,
    wait_since_service_ns: u64 = 0,
};

const lifecycle_trace_interval_ms = 100;

const Workspace = struct {
    model_preparation: model_adapter.Preparation,
    model_admission: store_module.ModelAdmissionPreparation,
    bash_window: [bash.copy_window_bytes]u8,
    auth_worker: AuthWorker,
    bash_input: store_module.ActionExecutionInput,
    bash_preparation: bash.Preparation,
    bash_prepared: bash.Prepared,
    event_data: output_decode.EventData,
    interpret: output_decode.Interpret,
    failure_after: usize,
    interpretation: output_decode.Interpretation,
    provider_failure: output_decode.ProviderFailure,
    decode: output_decode.Decode,
    settlement: store_module.ValidatedOutput,
    listings: std.EnumArray(provider.ListingKind, ListingWork),
    image_calls: server_read_image.Calls,
    turn_state: execution_turn.State,
};

// Shape of the removed in-workspace Bash outcome, used only to preserve and
// check the original workspace allocation ceiling.
const OriginalBashOutcome = struct {
    code: store_module.ActionResolutionCode,
    content: [bash.excerpt_bytes + 4096]u8,
    content_len: usize,
    tail: [bash.excerpt_bytes + 14]u8,
};

const WorkspaceBeforeBashResult = blk: {
    const fields = std.meta.fieldNames(Workspace);
    var names: [fields.len + 1][:0]const u8 = undefined;
    var types: [names.len]type = undefined;
    for (fields, 0..) |name, i| {
        names[i] = name;
        types[i] = @FieldType(Workspace, name);
    }
    names[fields.len] = "original_bash_outcome";
    types[fields.len] = OriginalBashOutcome;
    break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
};

// Keep admission and dispatch state within the original mapped workspace pages.
// Exclude every added owner so its state cannot silently raise the baseline.
const WorkspaceBeforeAdmissionAndDispatch = blk: {
    const fields = std.meta.fieldNames(Workspace);
    var names: [fields.len - 2][:0]const u8 = undefined;
    var types: [names.len]type = undefined;
    var next: usize = 0;
    for (fields) |name| {
        if (std.mem.eql(u8, name, "model_admission") or
            std.mem.eql(u8, name, "image_calls") or
            std.mem.eql(u8, name, "turn_state")) continue;
        names[next] = name;
        types[next] = @FieldType(Workspace, name);
        next += 1;
    }
    // The original baseline included Bash's in-workspace outcome. Its
    // replacement is heap-owned; keep the original page ceiling while the
    // actual workspace becomes smaller.
    names[next] = "original_bash_outcome";
    types[next] = OriginalBashOutcome;
    break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
};

comptime {
    const page = std.heap.page_size_min;
    if (@sizeOf(Workspace) >= @sizeOf(WorkspaceBeforeBashResult))
        @compileError("Bash result migration must reduce workspace allocation");
    if (std.mem.alignForward(usize, @sizeOf(Workspace), page) > std.mem.alignForward(usize, @sizeOf(WorkspaceBeforeAdmissionAndDispatch), page))
        @compileError(std.fmt.comptimePrint("admission and dispatch state must fit existing workspace pages: {d} -> {d} bytes", .{
            @sizeOf(WorkspaceBeforeAdmissionAndDispatch), @sizeOf(Workspace),
        }));
}

const ListingWork = struct {
    fetch: provider.ListingFetch,
    credential: ?*provider.SharedCredential,
    response: ?[]u8,
    url: ?[]const u8 = null,
    auth: enum { none, waiting, requested } = .none,
};

pub fn executionMain(host: *Host, settings: Settings, execution_state: *execution_owner.Execution) void {
    const parts = execution_state.attempts(host.store, host.probes);
    var run: Run = .{ .host = host, .settings = settings, .execution = execution_state, .custody = parts.custody };
    const mapped_workspace = pages.Mapped(Workspace).map() catch |err| {
        run.host.lifecycle.fenceDispatch("execution workspace allocation", err);
        return;
    };
    defer mapped_workspace.unmap();
    const workspace = mapped_workspace.value;
    workspace.failure_after = 0;
    workspace.model_admission.init();
    defer workspace.model_admission.deinit();
    const auth_worker: ?*AuthWorker = if (run.host.providers.anySignIn()) worker: {
        workspace.auth_worker = .{ .io = run.host.io };
        break :worker &workspace.auth_worker;
    } else null;
    const auth_thread: ?std.Thread = if (auth_worker) |worker|
        signal_stack.spawn(.{}, AuthWorker.run, .{worker}) catch |err| {
            run.host.lifecycle.fenceDispatch("authentication worker initialization", err);
            return;
        }
    else
        null;
    run.auth_worker = auth_worker;
    defer if (auth_thread) |thread| {
        run.auth_worker = null;
        auth_worker.?.stop(thread);
    };
    const slots = mapZeroed(ExecutionSlot, run.custody.records.len) catch |err| {
        run.host.lifecycle.fenceDispatch("execution workspace allocation", err);
        return;
    };
    defer unmapZeroed(slots);
    const turn_states = mapZeroed(turn_states_module.TurnStates.Entry, slots.len * std.enums.values(protocol.Provider).len) catch |err| {
        run.host.lifecycle.fenceDispatch("execution workspace allocation", err);
        return;
    };
    run.turn_states = .init(turn_states);
    defer {
        run.turn_states.deinit();
        run.turn_states = .{};
        unmapZeroed(turn_states);
    }
    const history_memos = mapZeroed(model_adapter.HistoryMemos.Entry, slots.len) catch |err| {
        run.host.lifecycle.fenceDispatch("execution workspace allocation", err);
        return;
    };
    run.history_memos = .{ .entries = history_memos, .scratch_path = run.host.lease.paths.scratch.slice() };
    defer {
        run.history_memos.deinit(run.host.io);
        unmapZeroed(history_memos);
    }
    const bash_work = mapZeroed(BashWork, slots.len) catch |err| {
        run.host.lifecycle.fenceDispatch("execution workspace allocation", err);
        return;
    };
    run.bash_work = bash_work;
    defer {
        run.bash_work = &.{};
        unmapZeroed(bash_work);
    }
    const budget = run.host.retention.sharedBudget().narrowed(
        if (run.host.probes.fails(.request_scratch_acquire)) 0 else run.host.limits.request_scratch_limit_bytes,
    );
    var listing_urls: std.EnumArray(provider.ListingKind, ?[]const u8) = .initFill(null);
    defer for (listing_urls.values, std.enums.values(provider.ListingKind)) |url, kind| {
        if (kind != .catalog) if (url) |owned| run.host.allocator.free(owned);
    };
    for (std.enums.values(provider.ListingKind)) |kind| {
        const name = provider.listedProvider(kind) orelse continue;
        const served = run.host.providers.liveList(name) orelse continue;
        listing_urls.set(kind, std.fmt.allocPrint(run.host.allocator, "{s}/models", .{providers.responsesBase(served.endpoint).?}) catch |err| {
            run.host.model_lists.publish(name, err);
            continue;
        });
    }
    const catalog_url = run.settings.catalog_url orelse "https://models.dev/api.json";
    listing_urls.set(.catalog, catalog_url);
    for (listing_urls.values, &workspace.listings.values) |url, *work| work.url = url;
    var reactor_storage: provider.Reactor = undefined;
    const reactor: ?*provider.Reactor = reactor: {
        const any_listing = for (listing_urls.values) |url| {
            if (url != null) break true;
        } else false;
        if (slots.len == 0 and !any_listing) break :reactor null;
        var endpoints: std.EnumArray(protocol.Provider, ?[]const u8) = .initFill(null);
        for (run.host.providers.table.values, &endpoints.values) |served, *endpoint| {
            if (served) |value| endpoint.* = value.endpoint;
        }
        reactor_storage.init(run.host.allocator, run.host.io, .{
            .endpoints = endpoints,
            .ca_file = run.host.providers.ca_file,
            .capacity = slots.len,
            .inactivity_seconds = @intCast(run.host.limits.provider_inactivity_seconds),
            .observation = .{ .turn_state = run.turn_states.sink() },
            .scratch_path = run.host.lease.paths.scratch.slice(),
            .budget = budget,
            .listing_urls = listing_urls,
        }) catch |err| {
            if (!run.host.providers.any()) {
                listingFailed(&run, .catalog, err);
                break :reactor null;
            }
            run.host.lifecycle.fenceDispatch("transport reactor initialization", err);
            return;
        };
        if (reactor_storage.catalog_endpoint_error) |err| listingFailed(&run, .catalog, err);
        break :reactor &reactor_storage;
    };
    defer if (reactor) |active| active.deinit();
    if (reactor) |active| startListings(&run, active, &workspace.listings);
    defer if (reactor) |active| {
        for (std.enums.values(provider.ListingKind)) |kind| endListing(active, kind, workspace.listings.getPtr(kind));
    };
    run.host.lifecycle.connectDispatchWake(reactor, run.host.store);
    defer run.host.store.commitWake().store(null, .release);
    // The loop's own commits stay unsynced until something could observe
    // them; Store.settle syncs once for all of them.
    run.host.store.queue().deferring.store(std.Thread.getCurrentId(), .monotonic);
    defer run.host.store.queue().deferring.store(0, .monotonic);
    // One process-wide SIGCHLD owner: with two Hosts in one process the later
    // attach wins and the other falls back to its Bash wait timeout.
    const child_wake: child_exit_wake.Wake = run.host.lifecycle.childExitWake();
    child_exit_wake.attach(&child_wake);
    defer child_exit_wake.detach(&child_wake);
    const transport: ?std.Thread = if (reactor) |active|
        signal_stack.spawn(.{}, provider.Reactor.serve, .{active}) catch |err| {
            run.host.lifecycle.fenceDispatch("transport thread start", err);
            return;
        }
    else
        null;
    defer if (transport) |thread| {
        reactor.?.stop();
        thread.join();
    };
    if (reactor != null) run.scratch_budget = budget;
    defer run.scratch_budget = null;
    var mcp_calls: server_mcp.Calls = .{};
    const attempts: action_attempt.Parts = run.execution.attempts(run.host.store, run.host.probes);
    workspace.image_calls = .{};
    defer workspace.image_calls.shutdown(run.host);
    defer shutdownExecution(&run, slots, workspace);
    defer mcp_calls.shutdown(run.host);

    workspace.turn_state = .{ .capacity_was_full = slots.len == 0 };
    var measurement: LifecycleMeasurement = .{};
    var heap_release: HeapRelease = .{};
    var drain: ?host_drain.Watch = null;
    while (!run.host.lifecycle.executionEnding()) {
        var native = NativeTurn{
            .run = &run,
            .reactor = reactor,
            .slots = slots,
            .workspace = workspace,
            .measurement = &measurement,
            .mcp = &mcp_calls,
            .images = &workspace.image_calls,
            .attempts = attempts,
            .fenced = false,
        };
        run.host.lifecycle.resetDispatchWake();
        const outcome = execution_turn.run(&workspace.turn_state, &native);
        const drain_wait_ms = if (watchDrain(&run, &drain, workspace, &native, outcome)) |wait| wait else break;
        switch (outcome) {
            .continue_immediately => heap_release.worked = true,
            .wait => |kind| {
                if (heap_release.due(slots, if (reactor) |active| active.listingPending() else false)) process.releaseFreeHeap();
                const wait_started = std.Io.Clock.Timestamp.now(run.host.io, .awake);
                const kind_ms: u32 = switch (kind) {
                    .transport => if (mcp_calls.any()) 25 else transportWaitMs(slots),
                    .bash => 25,
                    .idle => 100,
                };
                awaitDispatchWake(&run, @intCast(@min(drain_wait_ms, kind_ms, relistWaitMs(&run))));
                const wait_finished = std.Io.Clock.Timestamp.now(run.host.io, .awake);
                measurement.wait_since_service_ns += @intCast(wait_started.durationTo(wait_finished).raw.nanoseconds);
            },
            .terminate => break,
        }
        if (native.fenced) break;
    }
    const stopped_at = std.Io.Clock.Timestamp.now(run.host.io, .awake);
    if (measurement.last_service_at) |last| {
        run.host.probes.traceServiceBoundary(
            @intCast(last.raw.nanoseconds),
            @intCast(stopped_at.raw.nanoseconds),
            measurement.wait_since_service_ns,
        );
        measurement.maximum_gap_ns = @max(
            measurement.maximum_gap_ns,
            @as(u64, @intCast(last.durationTo(stopped_at).raw.nanoseconds)),
        );
    }
    run.host.probes.traceLifecycleService(measurement.maximum_gap_ns);
}

/// Judges a draining pause after each pass. Returns how long the loop may
/// wait before deciding again, or null once the drain has ended the Host.
fn watchDrain(run: *Run, drain: *?host_drain.Watch, workspace: *Workspace, native: *NativeTurn, outcome: execution_turn.Outcome) ?u64 {
    const until = run.host.lifecycle.drainUntil() orelse return std.math.maxInt(u64);
    if (drain.* == null) drain.* = .{ .until_ns = until };
    drain.*.?.until_ns = until;
    const decision = drain.*.?.observe(.{
        .now_ns = server_host.nowNs(run.host.io),
        .idle = outcome == .wait and !native.workInFlight(),
        .running = run.custody.running(),
        // A fenced Host admits no retry, so a retry row cannot hold the drain.
        .retry = if (native.dispatchFenced()) .none else workspace.turn_state.retryOutlook(native.unixMilliseconds()),
    });
    switch (decision) {
        .wait_at_most_ns => |ns| return std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable,
        .stop => |ended| {
            if (run.host.lifecycle.finishDrain(ended)) run.host.lifecycle.wakeListener();
            return null;
        },
    }
}

// executionMain runs every NativeTurn step through execution_turn.run. Steps
// that never lead to a completion stay out of line, so their locals do not
// widen the frame under serviceOneCompletion, the engine's deepest chain.
const NativeTurn = struct {
    run: *Run,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    workspace: *Workspace,
    measurement: *LifecycleMeasurement,
    mcp: *server_mcp.Calls,
    images: ?*server_read_image.Calls = null,
    attempts: action_attempt.Parts,
    fenced: bool,
    scheduled_retry: execution_turn.ScheduledRetry = .unknown,

    pub fn now(self: *NativeTurn) std.Io.Clock.Timestamp {
        return std.Io.Clock.Timestamp.now(self.run.host.io, .awake);
    }

    pub fn noteLifecycleOpportunity(self: *NativeTurn) void {
        if (self.run.host.model_lists.takeAsk()) {
            if (self.reactor) |reactor| startListings(self.run, reactor, &self.workspace.listings);
        }
        const observed = self.now();
        if (self.measurement.last_service_at) |last| {
            self.run.host.probes.traceServiceBoundary(
                @intCast(last.raw.nanoseconds),
                @intCast(observed.raw.nanoseconds),
                self.measurement.wait_since_service_ns,
            );
            self.measurement.maximum_gap_ns = @max(
                self.measurement.maximum_gap_ns,
                @as(u64, @intCast(last.durationTo(observed).raw.nanoseconds)),
            );
        }
        self.measurement.last_service_at = observed;
        self.measurement.wait_since_service_ns = 0;
        const trace_due = if (self.measurement.next_trace_at) |deadline| deadline.compare(.lte, observed) else true;
        if (trace_due) {
            self.run.host.probes.traceLifecycleService(self.measurement.maximum_gap_ns);
            self.measurement.next_trace_at = observed.addDuration(.{
                .raw = .fromMilliseconds(lifecycle_trace_interval_ms),
                .clock = .awake,
            });
        }
    }

    pub fn consumeControlHint(self: *NativeTurn) bool {
        return self.run.host.lifecycle.takeControlsChanged();
    }

    pub fn commitGeneration(self: *const NativeTurn) u64 {
        return self.run.host.store.commitGeneration();
    }

    pub fn publishRetryCrossings(self: *NativeTurn, from: u64, now_ms: u64) error{Fence}!execution_turn.DeadlineRead {
        const read = self.run.host.store.publishRetryCrossings(from, now_ms) catch |err| {
            self.run.host.lifecycle.fenceDispatch("retry deadline read", err);
            self.fenced = true;
            return error.Fence;
        };
        return .{ .generation = read.generation, .next = read.next };
    }

    pub fn controlGeneration(self: *const NativeTurn) u64 {
        return self.run.host.store.controlGeneration();
    }

    pub fn slotChanges(self: *const NativeTurn) u64 {
        return self.run.slot_changes;
    }

    pub noinline fn reconcileControls(self: *NativeTurn) void {
        self.workspace.model_admission.deinit();
        cancelSupersededTransfers(
            self.run,
            self.slots,
            self.workspace,
        );
        stopSupersededBash(self.run, self.slots, &self.workspace.bash_preparation);
    }

    pub noinline fn advanceBashPreparation(self: *NativeTurn) bool {
        return callAdvanceBashPreparation(self.run, self.slots, self.workspace);
    }

    pub noinline fn advanceLiveBash(self: *NativeTurn) bool {
        const observed = std.Io.Clock.Timestamp.now(self.run.host.io, .awake);
        const generation = self.run.host.store.commitGeneration();
        var cursor: usize = 0;
        while (self.run.custody.nextMessageWatch(&cursor, generation)) |watch| {
            const interrupt = self.run.host.store.messageAfterActionLaunch(watch.binding, watch.cutoff) catch |err| {
                self.run.host.lifecycle.fenceDispatch("Message Action selection", err);
                break;
            };
            if (!interrupt) continue;
            const reply = self.run.host.store.backgroundAction(.{ .live_action = watch.binding.action_id }, self.run.host.probes.storeFaults(.action_result));
            if (reply == .infrastructure_failure or reply == .conflict) {
                self.run.host.lifecycle.fenceDispatch("Message Action promotion", error.ActionPromotionFailed);
                break;
            }
        }
        while (self.run.custody.nextBackgroundDue(observed, self.run.settings.background_after_ms)) |binding| {
            const reply = self.run.host.store.backgroundAction(.{ .live_action = binding.action_id }, self.run.host.probes.storeFaults(.action_result));
            if (reply == .infrastructure_failure or reply == .conflict) {
                self.run.host.lifecycle.fenceDispatch("automatic Action promotion", error.ActionPromotionFailed);
                break;
            }
        }
        const mcp_progress = self.mcp.service(self.run.host);
        const relist_progress = serviceRelist(self.run);
        const image_progress = if (self.images) |images| images.service(self.run.host) else false;
        return advanceBash(self.run, self.slots, self.workspace) or mcp_progress or relist_progress or image_progress;
    }

    pub noinline fn advanceRetainedCleanup(self: *NativeTurn, observed: std.Io.Clock.Timestamp, retry_at: *std.Io.Clock.Timestamp) bool {
        return callAdvanceRetainedCleanup(self.run, self.slots, observed, retry_at);
    }

    pub fn dispatchFenced(self: *const NativeTurn) bool {
        return !self.run.host.lifecycle.launchAllowed();
    }

    pub fn providerConfigured(self: *const NativeTurn) bool {
        return self.run.host.providers.any();
    }

    pub fn dispatchCapacity(self: *const NativeTurn) DispatchCapacity {
        return self.run.custody.dispatchCapacity(!self.mcp.full());
    }

    pub fn freeSlots(self: *const NativeTurn) usize {
        return @min(countFreeSlots(self.slots), self.run.custody.records.len - self.run.custody.occupied());
    }

    pub fn bashPreparationOpen(self: *const NativeTurn) bool {
        for (self.slots) |slot| {
            if (slot == .bash_preparing) return false;
        }
        return true;
    }

    pub fn modelPreparationOpen(self: *const NativeTurn) bool {
        for (self.slots) |slot| switch (slot) {
            .model_preparing, .model_authenticating => return false,
            else => {},
        };
        return true;
    }

    /// A model call, Bash command, MCP call or image read holds execution.
    /// Pooled provider connections and catalog listings are not Turn work.
    pub fn workInFlight(self: *const NativeTurn) bool {
        if (hasOwnedSlots(self.slots) or self.mcp.any()) return true;
        return if (self.images) |images| images.any() else false;
    }

    pub fn hasTransport(self: *const NativeTurn) bool {
        if (slotsHaveTransport(self.slots)) return true;
        const reactor = self.reactor orelse return false;
        return reactor.hasConnections() or reactor.listingPending();
    }

    pub fn hasBash(self: *const NativeTurn) bool {
        return slotsHaveBash(self.slots) or self.mcp.any() or (if (self.images) |images| images.any() else false);
    }

    pub noinline fn recoverUncertainAction(self: *NativeTurn) error{Fence}!bool {
        const active_slots = ActiveSlots{ .slots = self.slots, .mcp = self.mcp, .images = self.images };
        const active_actions = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeActionContains,
            .maximum_exclusions = self.run.custody.records.len,
        };
        return self.run.host.store.recoverOneUncertainAction(active_actions) catch |err| {
            self.run.host.lifecycle.fenceDispatch("uncertain Action recovery", err);
            self.fenced = true;
            return error.Fence;
        };
    }

    pub noinline fn recoverExhaustedRetry(self: *NativeTurn) error{Fence}!bool {
        if (self.run.host.probes.releaseRetryRecovery()) return false;
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        const recovered = self.run.host.store.recoverOneExhaustedModelAttempt(active_filter) catch |err| {
            self.run.host.lifecycle.fenceDispatch("exhausted retry recovery", err);
            self.fenced = true;
            return error.Fence;
        };
        if (recovered) retryRecovered(self.run.host);
        return recovered;
    }

    fn firstFreeSlot(self: *NativeTurn) ?*ExecutionSlot {
        for (self.slots) |*slot| {
            if (slotIsFree(slot)) return slot;
        }
        return null;
    }

    pub fn runCoreAction(self: *NativeTurn) execution_turn.Admission {
        return runNextCoreAction(self.run, self.attempts, self.mcp, self.images);
    }

    pub noinline fn admitBash(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitBashAttempt(self.run, self.attempts, slot, self.workspace)) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
            .progress => .progress,
        };
    }

    pub noinline fn admitRetry(self: *NativeTurn) execution_turn.Admission {
        if (self.workspace.model_admission.pending()) return .no_work;
        const slot = self.firstFreeSlot() orelse return .no_work;
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        self.scheduled_retry = .unknown;
        var scanned = false;
        var due_ms: ?u64 = null;
        const progress = admitRetryAttempt(
            self.run,
            slot,
            active_filter,
            &self.workspace.model_preparation,
            &scanned,
            &due_ms,
        );
        if (scanned) self.scheduled_retry = if (due_ms) |ms| .{ .at_unix_ms = ms } else .none;
        return switch (progress) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
            .progress => .progress,
        };
    }

    pub noinline fn scanWork(self: *NativeTurn, paused: bool, capacity: DispatchCapacity) error{Fence}!execution_turn.Work {
        const found = self.run.host.store.dispatchWork(paused, capacity) catch |err| {
            self.run.host.lifecycle.fenceDispatch("dispatch work read", err);
            self.fenced = true;
            return error.Fence;
        };
        return .{ .core = found.core, .mcp = found.mcp, .bash = found.bash, .message = found.message, .tool_continuation = found.tool_continuation, .retry = found.retry, .retry_waiting = found.retry_waiting };
    }

    pub fn scheduledRetry(self: *const NativeTurn) execution_turn.ScheduledRetry {
        return self.scheduled_retry;
    }

    pub fn unixMilliseconds(self: *const NativeTurn) ?u64 {
        return std.math.cast(u64, store_module.readUnixMilliseconds(self.run.host.io) catch return null);
    }

    pub fn admitNewModel(self: *NativeTurn, paused: bool) execution_turn.Admission {
        return self.admitModel(if (paused) .open_turn_message else .message);
    }

    pub fn turnsPaused(self: *const NativeTurn) bool {
        return self.run.host.lifecycle.turnsHeld();
    }

    pub fn admitToolContinuation(self: *NativeTurn) execution_turn.Admission {
        return self.admitModel(.tool_continuation);
    }

    pub fn pendingModelAdmission(self: *const NativeTurn) ?execution_turn.PendingModelAdmission {
        const preparation = &self.workspace.model_admission;
        if (!preparation.pending()) return null;
        return switch (preparation.kind.?) {
            .message, .open_turn_message => .message,
            .tool_continuation => .tool_continuation,
        };
    }

    pub noinline fn advanceModelAdmission(self: *NativeTurn) bool {
        const preparation = &self.workspace.model_admission;
        if (!preparation.pending()) return false;
        if (!self.run.host.lifecycle.launchAllowed() or
            (preparation.kind == .message and self.turnsPaused()))
        {
            preparation.deinit();
            return true;
        }
        if (preparation.pendingReady()) return false;
        const progress = self.run.host.store.admitModelAttemptStep(
            preparation.kind.?,
            self.run.host.probes.storeFaults(.attempt_admission),
            null,
            preparation,
        ) catch |err| {
            preparation.deinit();
            self.run.host.lifecycle.fenceDispatch("Attempt admission preflight", err);
            self.fenced = true;
            return true;
        };
        switch (progress) {
            .progress => {},
            .done => |admitted| std.debug.assert(admitted == null),
        }
        return true;
    }

    noinline fn admitModel(self: *NativeTurn, requested: store_module.ModelAdmissionKind) execution_turn.Admission {
        const pending = &self.workspace.model_admission;
        if (self.pendingModelAdmission()) |kind| {
            const requested_kind: execution_turn.PendingModelAdmission = if (requested == .tool_continuation) .tool_continuation else .message;
            if (kind != requested_kind) return .no_work;
            if (pending.kind == .message and self.turnsPaused()) {
                pending.deinit();
                return .progress;
            }
            if (!pending.pendingReady()) return .progress;
        }
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitNewAttempt(
            self.run,
            slot,
            pending.kind orelse requested,
            &self.workspace.model_preparation,
            pending,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
            .progress => .progress,
        };
    }

    pub fn driveTransport(self: *NativeTurn) error{Fence}!void {
        if (self.reactor.?.failed()) |err| {
            self.run.host.lifecycle.fenceDispatch("transport reactor", err);
            self.fenced = true;
            return error.Fence;
        }
        self.run.host.probes.observeUnprocessedCompletions(self.reactor.?);
    }

    pub noinline fn serviceOneCompletion(self: *NativeTurn) bool {
        if (callServiceOneCompletion(self.run, self.reactor, self.slots, self.workspace)) return true;
        const reactor = self.reactor orelse return false;
        for (std.enums.values(provider.ListingKind)) |kind| {
            if (reactor.finishedListing(kind) == null) continue;
            finishListing(self.run, reactor, kind, self.workspace.listings.getPtr(kind));
            return true;
        }
        return false;
    }

    pub fn modelPreparationAllowance(self: *const NativeTurn) execution_turn.Allowance {
        return .{
            .bytes = self.run.host.limits.request_preparation_byte_allowance,
            .items = self.run.host.limits.request_preparation_item_allowance,
        };
    }

    pub noinline fn advanceModelPreparation(self: *NativeTurn, byte_allowance: usize, item_allowance: usize) bool {
        const pending_progress = advancePendingFailure(self.run, self.slots, self.workspace);
        return callAdvanceModelPreparation(
            self.run,
            self.reactor,
            self.slots,
            &self.workspace.model_preparation,
            &self.workspace.listings,
            byte_allowance,
            item_allowance,
        ) or pending_progress;
    }
};

const max_catalog_response_bytes = 16 * 1024 * 1024;

noinline fn startListings(run: *Run, reactor: *provider.Reactor, works: *std.EnumArray(provider.ListingKind, ListingWork)) void {
    for (std.enums.values(provider.ListingKind)) |kind| {
        const work = works.getPtr(kind);
        if (reactor.listings.get(kind) != null or work.auth != .none or reactor.listing_endpoints.get(kind) == null) continue;
        if (listingCredential(run, kind)) |credential| if (credential.leased()) {
            work.auth = .waiting;
            continue;
        };
        startLeasedListing(run, reactor, kind, work, null);
    }
}

fn listingCredential(run: *Run, kind: provider.ListingKind) ?providers.Credential {
    const name = provider.listedProvider(kind) orelse return null;
    return run.host.providers.liveList(name).?.credential;
}

fn startLeasedListing(run: *Run, reactor: *provider.Reactor, kind: provider.ListingKind, work: *ListingWork, lease: ?*const providers.Lease) void {
    startListing(run, reactor, kind, work, lease) catch |err| {
        endListing(reactor, kind, work);
        listingFailed(run, kind, err);
    };
}

noinline fn startListing(run: *Run, reactor: *provider.Reactor, kind: provider.ListingKind, work: *ListingWork, lease: ?*const providers.Lease) !void {
    var headers: providers.Headers = .{};
    defer headers.deinit();
    var source: ?store_module.ModelCatalogSource = null;
    var fields: [1]h2.Field = undefined;
    const request_fields: []const h2.Field = if (listingCredential(run, kind)) |credential| fields: {
        try credential.fields(work.url.?, run.host.providers.ca_file, lease, &reactor.credentials, &headers);
        work.credential = headers.takeCredential();
        break :fields headers.fields();
    } else fields: {
        source = try run.host.store.readModelCatalogSource();
        if (source) |*saved| if (saved.etag) |*etag| {
            fields[0] = h2.Field{ .name = "if-none-match", .value = etag.slice() };
            break :fields &fields;
        };
        break :fields &.{};
    };
    work.response = try pages.mapZeroed(u8, if (kind == .catalog) max_catalog_response_bytes else model_list.max_response_bytes);
    try reactor.startListing(kind, &work.fetch, request_fields, work.response.?);
}

fn listingFailed(run: *Run, kind: provider.ListingKind, err: anyerror) void {
    if (provider.listedProvider(kind)) |name| return run.host.model_lists.publish(name, err);
    stderr.print("rui: models.dev catalog unavailable ({s}); the saved catalog stands\n", .{@errorName(err)});
}

noinline fn finishListing(run: *Run, reactor: *provider.Reactor, kind: provider.ListingKind, work: *ListingWork) void {
    defer endListing(reactor, kind, work);
    const stream = &reactor.finishedListing(kind).?.stream;
    if (stream.end().?.cause != .complete) return listingFailed(run, kind, error.ListingTransportFailed);
    if (stream.status() != 200 and !(kind == .catalog and stream.status() == 304)) return listingFailed(run, kind, error.ListingRefused);
    const body = work.response.?[0..@intCast(stream.responseLength())];
    if (provider.listedProvider(kind)) |name| return run.host.model_lists.publish(name, body);
    saveCatalogAnswer(run.host.store, work, stream.status().?, body) catch |err| listingFailed(run, kind, err);
}

noinline fn saveCatalogAnswer(store: *store_module.Store, work: *ListingWork, status: u16, body: []const u8) !void {
    if (status == 304) return;
    std.debug.assert(status == 200);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = try models_dev.parse(arena.allocator(), body);
    pages.unmapZeroed(work.response.?);
    work.response = null;
    try store.saveModelFacts(entries, if (work.fetch.etag) |*etag| etag.slice() else null);
}

fn endListing(reactor: *provider.Reactor, kind: provider.ListingKind, work: *ListingWork) void {
    reactor.endListing(kind);
    work.auth = .none;
    if (work.credential) |shared| reactor.credentials.release(shared);
    work.credential = null;
    if (work.response) |response| pages.unmapZeroed(response);
    work.response = null;
}

const callServiceOneCompletion = serviceOneCompletion;
const callAdvanceBashPreparation = advanceBashPreparation;
const callAdvanceModelPreparation = advanceModelPreparation;
const callAdvanceRetainedCleanup = advanceRetainedCleanup;
const slotsHaveTransport = hasTransport;
const slotsHaveBash = hasBash;

fn serviceOneCompletion(run: *Run, reactor: ?*provider.Reactor, slots: []ExecutionSlot, workspace: *Workspace) bool {
    const active_reactor = reactor orelse return false;
    const completion = active_reactor.nextCompletion(run.host.probes.fails(.response_seal)) catch |err| {
        run.host.lifecycle.fenceDispatch("transport completion", err);
        return false;
    } orelse return false;
    const slot = slotOfTransfer(slots, completion.transfer) orelse {
        run.host.lifecycle.fenceDispatch("transport completion", error.UnknownTransportCompletion);
        return false;
    };
    completeTransfer(run, workspace, slot, completion);
    return true;
}

fn slotOfTransfer(slots: []ExecutionSlot, transfer: *provider.Transfer) ?*ExecutionSlot {
    const base = @intFromPtr(slots.ptr);
    const address = @intFromPtr(transfer);
    if (address < base or address >= base + slots.len * @sizeOf(ExecutionSlot)) return null;
    const slot = &slots[(address - base) / @sizeOf(ExecutionSlot)];
    if (slot.* != .provider or &slot.provider.transfer != transfer) return null;
    return slot;
}

const HeapRelease = struct {
    worked: bool = false,

    fn due(self: *HeapRelease, slots: []const ExecutionSlot, listing_pending: bool) bool {
        if (listing_pending or !self.worked or countFreeSlots(slots) != slots.len) return false;
        self.worked = false;
        return true;
    }
};

test "heap release is due once per return to all slots free" {
    var slots = [_]ExecutionSlot{ .free, .free };
    var release: HeapRelease = .{};
    try std.testing.expect(!release.due(&slots, false));
    release.worked = true;
    slots[0] = .{ .provider = .{ .owner = .{} } };
    for (0..3) |_| {
        try std.testing.expect(!release.due(&slots, false));
        release.worked = true;
    }
    slots[0] = .free;
    try std.testing.expect(release.due(&slots, false));
    try std.testing.expect(!release.due(&slots, false));
    try std.testing.expect(!release.due(&slots, false));
    release.worked = true;
    try std.testing.expect(!release.due(&slots, true));
    try std.testing.expect(release.due(&slots, false));
    try std.testing.expect(!release.due(&slots, false));
}

/// How long the loop may wait for a re-list: 25 ms while one is listing, else until the
/// earliest backoff retry or pending ask. Unbounded when no re-list is due.
fn serviceRelist(run: *Run) bool {
    const owner = run.execution.relist orelse return false;
    var failure: ?anyerror = null;
    const progress = owner.service(run.host.store, server_host.nowNs(run.host.io) / std.time.ns_per_ms, &failure);
    if (failure) |err| run.host.lifecycle.fenceDispatch("MCP tool set publication", err);
    return progress;
}

fn relistWaitMs(run: *Run) u64 {
    const owner = run.execution.relist orelse return std.math.maxInt(u64);
    if (owner.listing()) return 25;
    const at = owner.wakeAt() orelse return std.math.maxInt(u64);
    return at -| server_host.nowNs(run.host.io) / std.time.ns_per_ms;
}

fn awaitDispatchWake(run: *Run, timeout_ms: u32) void {
    run.host.lifecycle.awaitDispatchWake(timeout_ms);
}

fn transportWaitMs(slots: []const ExecutionSlot) u32 {
    return if (slotsHaveBash(slots)) 25 else 100;
}

test "transport waits at the idle cadence unless Bash runs" {
    var slots = [_]ExecutionSlot{ .free, .free };
    try std.testing.expectEqual(@as(u32, 100), transportWaitMs(&slots));
    slots[0] = .{ .provider = .{ .owner = .{} } };
    try std.testing.expectEqual(@as(u32, 100), transportWaitMs(&slots));
    slots[1] = .{ .bash_preparing = undefined };
    try std.testing.expectEqual(@as(u32, 25), transportWaitMs(&slots));
}

test "a completed Transfer finds its own slot and nothing else" {
    var slots = [_]ExecutionSlot{ .free, .{ .provider = .{ .owner = .{} } }, .{ .provider = .{ .owner = .{} } } };
    try std.testing.expectEqual(&slots[1], slotOfTransfer(&slots, &slots[1].provider.transfer).?);
    try std.testing.expectEqual(&slots[2], slotOfTransfer(&slots, &slots[2].provider.transfer).?);
    try std.testing.expect(slotOfTransfer(slots[0..1], &slots[1].provider.transfer) == null);
    try std.testing.expect(slotOfTransfer(slots[2..], &slots[1].provider.transfer) == null);
    const stale = &slots[2].provider.transfer;
    slots[2] = .free;
    try std.testing.expect(slotOfTransfer(&slots, stale) == null);
}

fn cancelSupersededTransfers(
    run: *Run,
    slots: []ExecutionSlot,
    workspace: *Workspace,
) void {
    for (slots) |*slot| switch (slot.*) {
        .model_preparing => |active| {
            const superseded = run.host.store.operationSupersededByControl(active.binding) catch |err| {
                run.host.lifecycle.fenceDispatch("preparation control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            run.host.probes.traceOperationControl("effect_stop_requested", control.command_key.slice(), active.binding);
            workspace.model_preparation.cancel();
            finishCustodyNow(run, slot);
        },
        .model_authenticating => |*active| {
            if (active.cancelled) continue;
            const superseded = run.host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                run.host.lifecycle.fenceDispatch("authentication control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                run.host.probes.traceOperationControl("effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.cancelled = true;
            }
        },
        .model_refreshing => |*active| {
            if (active.cancelled) continue;
            const superseded = run.host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                run.host.lifecycle.fenceDispatch("refresh control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                run.host.probes.traceOperationControl("effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.cancelled = true;
            }
        },
        .model_failure_preparing => |*active| {
            const superseded = run.host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                run.host.lifecycle.fenceDispatch("overflow control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                run.host.probes.traceOperationControl("effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.deinit();
                finishCustodyNow(run, slot);
            }
        },
        .provider => |*active| {
            const superseded = run.host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                run.host.lifecycle.fenceDispatch("control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            const owner = active.owner;
            run.host.probes.traceOperationControl("effect_stop_requested", control.command_key.slice(), owner.binding);
            active.transfer.deinit();
            finishCustodyNow(run, slot);
        },
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
}

test "an execution slot is sized for a model Attempt, not for Bash" {
    const model = @max(@sizeOf(ProviderSlot), @sizeOf(ModelAuthenticatingSlot), @sizeOf(ModelRefreshingSlot));
    try std.testing.expect(@sizeOf(ExecutionSlot) <= model + @alignOf(ExecutionSlot));
}

test "zeroed pages are free slots and empty Turn and history memo entries" {
    const slots = try mapZeroed(ExecutionSlot, 3);
    defer unmapZeroed(slots);
    for (slots) |*slot| try std.testing.expect(slotIsFree(slot));
    try std.testing.expectEqual(slots.len, countFreeSlots(slots));
    try std.testing.expect(@sizeOf(turn_states_module.TurnStates.Entry) < 64);
    const entries = try mapZeroed(turn_states_module.TurnStates.Entry, 2);
    defer unmapZeroed(entries);
    for (entries) |entry| {
        try std.testing.expectEqual(@as(?turn_states_module.TurnStates.Held, null), entry.held);
        try std.testing.expectEqual(@as(u64, 0), entry.used);
    }
    var states: turn_states_module.TurnStates = .{ .entries = entries };
    defer states.deinit();
    try std.testing.expectEqualStrings("", states.replay(7, @splat(1)).value);
    const memos = try mapZeroed(model_adapter.HistoryMemos.Entry, 2);
    defer unmapZeroed(memos);
    for (memos) |entry| {
        try std.testing.expect(entry.memo == null);
        try std.testing.expectEqual(@as(u64, 0), entry.file_bytes);
        try std.testing.expectEqual(@as(u64, 0), entry.used);
    }
    try std.testing.expectEqual(@as(usize, 0), (try mapZeroed(ExecutionSlot, 0)).len);
}

fn countFreeSlots(slots: []const ExecutionSlot) usize {
    var free: usize = 0;
    for (slots) |slot| {
        if (slot == .free) free += 1;
    }
    return free;
}

fn slotIsFree(slot: *const ExecutionSlot) bool {
    return slot.* == .free;
}

const ActiveSlots = struct {
    slots: []ExecutionSlot,
    mcp: ?*const server_mcp.Calls = null,
    images: ?*const server_read_image.Calls = null,
};

fn activeOperationContains(context: *const anyopaque, operation_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |slot| switch (slot) {
        .provider => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_preparing => |value| if (value.binding.operation_id == operation_id) return true,
        .model_authenticating => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_refreshing => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_failure_preparing => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
    return false;
}

fn activeActionContains(context: *const anyopaque, action_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    if (active.mcp) |mcp| if (mcp.contains(action_id)) return true;
    if (active.images) |images| if (images.contains(action_id)) return true;
    for (active.slots) |slot| switch (slot) {
        .bash_preparing => |value| if (value.attempt.binding.action_id == action_id) return true,
        .bash => |value| if (value.attempt.binding.action_id == action_id) return true,
        else => {},
    };
    return false;
}

fn bashScratch(run: *Run) bash.Scratch {
    return .{
        .io = run.host.io,
        .path = run.host.lease.paths.scratch.slice(),
        .budget = run.host.retention.sharedBudget().narrowed(run.host.limits.bash_scratch_limit_bytes),
    };
}

fn advanceBash(run: *Run, slots: []ExecutionSlot, workspace: *Workspace) bool {
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash => |*active| {
            const was_running = active.execution.lifecycle.process == .running;
            const service = active.execution.service(bashScratch(run), &workspace.bash_window);
            if (was_running and active.execution.lifecycle.process != .running) {
                run.host.store.revokeActionSender(active.attempt.binding) catch |err| {
                    _ = failBash(run, slot, "Bash sender retirement", err);
                };
            }
            made_progress = made_progress or service.made_progress;
            if (service.timeout_action) |action| {
                run.host.probes.traceActionDeadline("bash_deadline_serviced", action.deadline_ns, action.signal_failed, active.attempt.binding);
            }
            if (service.leader_observed_with_open_pipes) {
                run.host.probes.traceAction("bash_leader_observed_with_open_pipes", active.attempt.binding);
                if (comptime test_pause.enabled) reachAction(run, .action_bash_exit_observed, active.attempt.binding);
            }
            if (service.fault) |err| {
                made_progress = failBash(run, slot, "Bash process service", err) or made_progress;
            }
            if (active.delivery == .open and service.retired) {
                completeBash(run, slot);
                made_progress = true;
            }
            if (active.delivery == .closed and service.retired) {
                const closed = &active.delivery.closed;
                const now = std.Io.Clock.Timestamp.now(run.host.io, .awake);
                if (now.raw.nanoseconds >= closed.reclaim_at.raw.nanoseconds) {
                    made_progress = reclaimBash(run, slot, now) or made_progress;
                }
            }
        },
        else => {},
    };
    return made_progress;
}

noinline fn runNextCoreAction(run: *Run, attempts: action_attempt.Parts, mcp: *server_mcp.Calls, images: ?*server_read_image.Calls) execution_turn.Admission {
    const work = (run.host.store.nextCoreWork(run.custody.dispatchCapacity(!mcp.full())) catch |err| {
        run.host.lifecycle.fenceDispatch("core tool selection", err);
        return .retry_later;
    }) orelse return .no_work;
    return switch (work) {
        .stop => |*owed| runOwedStop(run, owed),
        .mcp => |call| mcp.admit(run.host, attempts, call),
        .read_image => |call| if (images) |calls| calls.admit(run.host, attempts, call) else .retry_later,
        .ending => |*owed| runOwedEnding(run, owed),
        .forward => |id| runSessionForward(run, id),
        .auto_deny => |decision| runMessageDecline(run, decision.action_id, decision.session.slice()),
        .action => |*input| switch (input.tool) {
            .find_tools => runFindTools(run, input),
            .message_agent => runMessageAgent(run, input),
            .read_action => runReadAction(run, input),
            .stop_action => runStopAction(run, input),
            .read_transcript => runReadTranscript(run, input),
            .start_agent => runStartAgent(run, input),
            .skill => runSkill(run, input),
        },
    };
}

noinline fn runMessageDecline(run: *Run, action_id: u64, session: []const u8) execution_turn.Admission {
    var command: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .deny };
    command.session.set(session) catch unreachable;
    const key = std.fmt.bufPrint(&command.key.bytes, "rui.core/message-decline/{d}", .{action_id}) catch unreachable;
    command.key.len = key.len;
    switch (run.host.store.declineForMessage(&command, run.host.probes.storeFaults(.action_result))) {
        .accepted, .rejected, .conflict => return .admitted,
        .infrastructure_failure => {
            run.host.lifecycle.fenceDispatch("Message approval decline", error.CanonicalStoreFailure);
            return .retry_later;
        },
    }
}

noinline fn runOwedStop(run: *Run, owed: *const store_module.OwedStop) execution_turn.Admission {
    var command: protocol.SessionStopCommand = .{ .key = owed.key };
    command.session.set(owed.session.slice()) catch unreachable;
    switch (run.host.store.stopOwedSession(&command, run.host.probes.storeFaults(.action_result))) {
        .accepted, .rejected, .conflict => {},
        .infrastructure_failure => {
            run.host.lifecycle.fenceDispatch("owed stop", error.CanonicalStoreFailure);
            return .retry_later;
        },
    }
    run.host.lifecycle.noteControlsChanged();
    return .admitted;
}

noinline fn runOwedEnding(run: *Run, owed: *const store_module.OwedEnding) execution_turn.Admission {
    var arena_state: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena_state.deinit();
    const captured: ?store_module.CapturedMessageSkills = if (owed.answer != null and !owed.quiet)
        session_skills.bindTo(arena_state.allocator(), run.host.io, run.host.store, owed.parent.slice(), .{ .stored = .{ .store = run.host.store, .reference = owed.answer.? } }) catch |err| switch (err) {
            error.OutOfMemory => return .retry_later,
            else => {
                run.host.lifecycle.fenceDispatch("child ending", err);
                return .retry_later;
            },
        }
    else
        null;
    _ = run.host.store.deliverChildEndingBound(owed.turn_id, if (captured) |*value| value else null, run.host.probes.storeFaults(.action_result)) catch |err| {
        run.host.lifecycle.fenceDispatch("child ending", err);
        return .retry_later;
    };
    return .admitted;
}

noinline fn runSessionForward(run: *Run, forward_id: u64) execution_turn.Admission {
    _ = run.host.store.deliverSessionForward(forward_id, run.host.probes.storeFaults(.action_result)) catch |err| {
        run.host.lifecycle.fenceDispatch("session forward", err);
        return .retry_later;
    };
    return .admitted;
}

noinline fn runMessageAgent(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    const arguments_bytes = run.host.allocator.alloc(u8, std.math.cast(usize, input.arguments.length) orelse return .retry_later) catch return .retry_later;
    defer run.host.allocator.free(arguments_bytes);
    run.host.store.readCoreArguments(input, arguments_bytes) catch |err| {
        run.host.lifecycle.fenceDispatch("core tool input", err);
        return .retry_later;
    };
    var source: tools.core_tools.SliceSource = .{ .bytes = arguments_bytes };
    const Text = struct {
        list: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }
    };
    var text: Text = .{ .allocator = run.host.allocator };
    defer text.list.deinit(run.host.allocator);
    const check = tools.core_tools.checkMessageAgent(&source, &text) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        else => {
            run.host.lifecycle.fenceDispatch("core tool input", err);
            return .retry_later;
        },
    };
    const arguments = switch (check) {
        .accepted => |accepted| accepted,
        .rejected => {
            run.host.lifecycle.fenceDispatch("core tool input", error.CorruptStore);
            return .retry_later;
        },
    };
    var arena_state: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena_state.deinit();
    const captured = session_skills.bindTo(arena_state.allocator(), run.host.io, run.host.store, arguments.id.slice(), .{ .bytes = text.list.items }) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        else => {
            run.host.lifecycle.fenceDispatch("core tool command", err);
            return .retry_later;
        },
    };
    _ = run.host.store.deliverAgentMessageBound(input.binding, arguments.id.slice(), text.list.items, if (captured) |*value| value else null, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("core tool command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

noinline fn runFindTools(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var arena: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena.deinit();
    var call = find_tools.read(run.host.store, arena.allocator(), input) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        else => {
            run.host.lifecycle.fenceDispatch("find_tools core command", err);
            return .retry_later;
        },
    };
    if (call.reloads()) {
        // The report writer fails only when the arena is out of memory, the same retry as the search's.
        call.words.report = findToolsReload(run, arena.allocator()) catch return .retry_later;
    }
    find_tools.settle(run.host.store, input, &call, arena.allocator(), run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("find_tools core command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

/// A `find_tools` reload asks every configured server through the re-list owner, the same ask `tools_reload` makes,
/// and settles in this pass: the lists land on the execution loop later, so nothing here waits.
fn findToolsReload(run: *Run, arena: std.mem.Allocator) ![]const u8 {
    var asked: [@import("host_settings.zig").max_mcp_servers]server_mcp_relist.Relist.Asked = undefined;
    const count = run.execution.askMcpLists(null, &asked);
    var out: std.Io.Writer.Allocating = .init(arena);
    try find_tools.writeReload(&out.writer, asked[0..count]);
    return out.written();
}

noinline fn runReadTranscript(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var arena: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena.deinit();
    read_transcript.run(run.host.store, arena.allocator(), input, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("read_transcript core command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

noinline fn runStopAction(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var arena: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena.deinit();
    @import("stop_action_tool.zig").run(run.host.store, arena.allocator(), input, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("stop_action core command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

noinline fn runReadAction(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var arena: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena.deinit();
    read_action_tool.run(run.host.store, arena.allocator(), input, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.OutOfMemory => return .retry_later,
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("read_action core command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

noinline fn runSkill(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var memory: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var request: protocol.SkillRequest = .{};
    const check: tools.core_tools.StartAgentCheck = if (input.arguments.length > tools.core_tools.skill_max_argument_bytes)
        .{ .rejected = "the arguments take more than 4096 bytes" }
    else checked: {
        const bytes = arena.alloc(u8, @intCast(input.arguments.length)) catch return .retry_later;
        run.host.store.readCoreArguments(input, bytes) catch |err| {
            run.host.lifecycle.fenceDispatch("skill core input", err);
            return .retry_later;
        };
        break :checked tools.core_tools.checkSkill(arena, bytes, &request) catch return .retry_later;
    };
    const captured: store_module.CapturedSkill = if (check == .rejected)
        .{ .failed = .{ .code = .skills_unavailable, .bytes = check.rejected } }
    else
        session_skills.capture(arena, run.host.allocator, run.host.io, run.host.store, input.session.slice(), &request, run.host.bash_facts.home) catch |err| {
            if (err != error.OutOfMemory) run.host.lifecycle.fenceDispatch("skill capture", err);
            return .retry_later;
        };
    _ = run.host.store.settleSkillTool(input.binding, arena, &captured, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.StaleActionAttemptBinding => return .admitted,
        error.OutOfMemory => return .retry_later,
        else => {
            run.host.lifecycle.fenceDispatch("skill core settlement", err);
            return .retry_later;
        },
    };
    return .admitted;
}

noinline fn runStartAgent(run: *Run, input: *const store_module.CoreActionInput) execution_turn.Admission {
    var arena_state: std.heap.ArenaAllocator = .init(run.host.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = arena.create(tools.core_tools.StartAgent) catch return .retry_later;
    const check: tools.core_tools.StartAgentCheck = if (input.arguments.length > tools.core_tools.start_agent_max_argument_bytes)
        .{ .rejected = std.fmt.comptimePrint("the arguments take more than {d} bytes", .{tools.core_tools.start_agent_max_argument_bytes}) }
    else check: {
        const bytes = arena.alloc(u8, @intCast(input.arguments.length)) catch return .retry_later;
        run.host.store.readCoreArguments(input, bytes) catch |err| {
            run.host.lifecycle.fenceDispatch("core tool input", err);
            return .retry_later;
        };
        break :check tools.core_tools.checkStartAgentWithPresets(arena, bytes, run.host.presets, start) catch return .retry_later;
    };
    switch (check) {
        .accepted => {},
        .rejected => |reason| {
            const result = std.fmt.allocPrint(arena, "Rui could not start the agent: {s}. Nothing was started.", .{reason}) catch return .retry_later;
            _ = run.host.store.failCoreCall(input.binding, result, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
                error.StaleActionAttemptBinding => {},
                else => run.host.lifecycle.fenceDispatch("core tool command", err),
            };
            return .admitted;
        },
    }
    var inheritance = child_environment.Inheritance.init(run.host.environments, input.session.slice(), run.host.allocator, arena) catch return .retry_later;
    defer inheritance.deinit(run.host.allocator);
    const committed = inheritance.messageCallback();
    const parent_skills = run.host.store.readSkills(arena, input.session.slice()) catch return .retry_later;
    const prepared = session_skills.prepareCreation(arena, run.host.allocator, run.host.io, parent_skills.workspace.slice(), run.host.bash_facts.home, .{ .bytes = start.task }) catch return .retry_later;
    _ = run.host.store.startAgentWithInitialSkills(input.binding, input.session.slice(), start.task, start.attached, &start.configuration, committed, prepared.initial, if (prepared.captured) |*value| value else null, run.host.probes.storeFaults(.action_result)) catch |err| switch (err) {
        error.StaleActionAttemptBinding => return .admitted,
        else => {
            run.host.lifecycle.fenceDispatch("core tool command", err);
            return .retry_later;
        },
    };
    return .admitted;
}

fn admitBashAttempt(
    run: *Run,
    parts: action_attempt.Parts,
    slot: *ExecutionSlot,
    workspace: *Workspace,
) AdmissionProgress {
    const selected = (run.host.store.nextAction(.bash, run.custody.dispatchCapacity(false)) catch |err| {
        run.host.lifecycle.fenceDispatch("Bash Action selection", err);
        return .retry_later;
    }) orelse return .no_work;
    const attempt = switch (action_attempt.admit(parts, selected, run.settings.bash_timeout_ms, bash_labels)) {
        .attempt => |attempt| attempt,
        .busy, .none => return .no_work,
        .refused => return .retry_later,
        .unattached => return .admitted,
    };
    std.debug.assert(slot.* == .free);
    moveSlot(run, slot, .bash_preparing, .{ .attempt = attempt });
    const action_binding = attempt.binding;
    // This blocking pause holds the shared execution loop until release.
    if (comptime test_pause.enabled) reachAction(run, .action_attempt_committed, action_binding);
    const input = &workspace.bash_input;
    run.host.store.readActionExecutionInput(.bash, action_binding, input) catch |err| {
        settleActionFailure(slot, .storage_failed, "Bash input could not be read.");
        finishCustodyNow(run, slot);
        if (run.host.store.isFenced()) run.host.lifecycle.fenceDispatch("Bash canonical input", err);
        return .admitted;
    };
    const arguments = run.host.store.openContent(input.arguments) catch |err| {
        settleActionFailure(slot, .storage_failed, "Bash input could not be opened.");
        finishCustodyNow(run, slot);
        run.host.lifecycle.fenceDispatch("Bash canonical input", err);
        return .admitted;
    };
    if (workspace.bash_preparation.start(
        bashScratch(run),
        run.host.allocator,
        arguments,
        input,
        run.host.lease.paths.selector(),
        run.settings.bash_path,
        action_binding.action_id,
        run.host.probes.bashFaults(),
    )) |failure| {
        var owned = failure;
        finishBashPreparationFailure(run, slot, &owned);
    }
    return .admitted;
}

fn advanceBashPreparation(
    run: *Run,
    slots: []ExecutionSlot,
    workspace: *Workspace,
) bool {
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .bash_preparing => break candidate,
        else => {},
    } else return false;
    const preparation = &workspace.bash_preparation;
    if (!run.host.lifecycle.launchAllowed()) {
        discardBashResources(run, slot, preparation.cancel());
        return true;
    }
    var progress = preparation.advance(&workspace.bash_prepared);
    switch (progress) {
        .pending => return true,
        .failed => |*failure| finishBashPreparationFailure(run, slot, failure),
        .prepared => launchPreparedBash(run, slot, &workspace.bash_prepared),
    }
    return true;
}

fn finishBashPreparationFailure(run: *Run, slot: *ExecutionSlot, failure: *bash.PreparationFailure) void {
    const canonical_failure = failure.cause == error.InvalidCanonicalBashDescriptor or
        failure.cause == error.ShortCanonicalRead;
    if (failure.cause == error.BashCommandTooLong) {
        settleActionFailure(slot, .spawn_failed, std.fmt.comptimePrint(
            "Bash was not started: the decoded command exceeds {d} bytes. Split long content across several smaller commands.",
            .{tools.bash_max_command_bytes},
        ));
    } else if (failure.cause == error.BashStdinTooLong) {
        settleActionFailure(slot, .spawn_failed, std.fmt.comptimePrint(
            "Bash was not started: decoded stdin exceeds {d} bytes. Split the input across smaller calls or read an existing file.",
            .{tools.bash_max_stdin_bytes},
        ));
    } else if (!canonical_failure) {
        settleActionFailure(slot, .storage_failed, "Bash preparation failed.");
    }
    failure.cleanup.cleanup(bashScratch(run)) catch |cleanup_err| {
        retainBashPreparedCleanup(run, slot, failure.cleanup, cleanup_err);
        return;
    };
    if (canonical_failure or run.host.store.isFenced()) {
        run.host.lifecycle.fenceDispatch("Bash canonical preparation", failure.cause);
    }
    finishCustodyNow(run, slot);
}

fn discardBashResources(
    run: *Run,
    slot: *ExecutionSlot,
    resources: bash.PreparedCleanup,
) void {
    var cleanup = resources;
    cleanup.cleanup(bashScratch(run)) catch |err| {
        retainBashPreparedCleanup(run, slot, cleanup, err);
        return;
    };
    finishCustodyNow(run, slot);
}

fn launchPreparedBash(run: *Run, slot: *ExecutionSlot, prepared: *bash.Prepared) void {
    const token = slot.bash_preparing.attempt.token;
    const action_binding = slot.bash_preparing.attempt.binding;
    // This blocking pause holds the shared execution loop until release.
    if (comptime test_pause.enabled) reachAction(run, .action_before_handoff, action_binding);
    pause(run.host, .{ .action_launch = action_binding });
    if (!run.host.lifecycle.launchAllowed()) {
        discardBashResources(run, slot, prepared.takeCleanup());
        return;
    }
    const base = launchBase(run.host.environments, prepared.session.slice(), prepared.allocator) catch {
        settleActionFailure(slot, .spawn_failed, "Bash was not started: the Host could not copy the Session's environment.");
        discardBashResources(run, slot, prepared.takeCleanup());
        return;
    };
    defer if (base) |bytes| prepared.allocator.free(bytes);
    const work = &run.bash_work[token.index];
    var refused: bash.ArgumentSizes = .{};
    switch (slot.bash_preparing.attempt.launch(.effect, std.Io.Clock.Timestamp.now(run.host.io, .awake), .{
        .host = run.host,
        .prepared = prepared,
        .base = base,
        .work = work,
        .refused = &refused,
    }, startBash)) {
        .started => {},
        .authority => |err| {
            run.host.lifecycle.fenceDispatch("Bash launch authority", err);
            discardBashResources(run, slot, prepared.takeCleanup());
            return;
        },
        .handoff => |err| {
            if (err == error.SupersededByControl) {
                settleActionFailure(slot, .cancelled, "Bash was stopped before launch.");
            } else if (err == error.BashSpawnFailed) {
                settleActionFailure(slot, .spawn_failed, "Bash process creation failed.");
            } else if (err == error.BashArgumentsTooLarge) {
                settleArgumentsTooLarge(slot, refused);
            } else if (err != error.HostDispatchSuppressed) {
                run.host.lifecycle.fenceDispatch("Bash dispatch handoff", err);
            }
            discardBashResources(run, slot, prepared.takeCleanup());
            return;
        },
    }
    const attempt = slot.bash_preparing.attempt;
    moveSlot(run, slot, .bash, .{
        .attempt = attempt,
        .execution = &work.execution,
    });
    run.host.probes.traceAction("bash_handoff_committed", action_binding);
    const deadline_ns = slot.bash.execution.deadlineNs();
    run.host.probes.traceActionDeadline("bash_deadline_established", deadline_ns, false, action_binding);
}

fn startBash(context: anytype) !void {
    context.work.* = .{ .execution = try context.prepared.launch(context.host.bash_facts, context.base, context.host.lease.paths.runtimeHint(), context.refused) };
}

fn stopSupersededBash(
    run: *Run,
    slots: []ExecutionSlot,
    preparation: *bash.Preparation,
) void {
    for (slots) |*slot| switch (slot.*) {
        .bash_preparing => {
            const control = switch (slot.bash_preparing.attempt.stopped()) {
                .fenced => return,
                .running => continue,
                .stopped => |control| control,
            };
            run.host.probes.traceActionControl("effect_stop_requested", control.command_key.slice(), slot.bash_preparing.attempt.binding);
            var cleanup = preparation.cancel();
            settleActionFailure(slot, .cancelled, "Bash was stopped before launch.");
            cleanup.cleanup(bashScratch(run)) catch |cleanup_err| {
                retainBashPreparedCleanup(run, slot, cleanup, cleanup_err);
                continue;
            };
            finishCustodyNow(run, slot);
        },
        .bash => |*active| {
            const control = switch (active.attempt.stopped()) {
                .fenced => return,
                .running => continue,
                .stopped => |control| control,
            };
            if (!active.stop_accepted) {
                active.stop_accepted = true;
                run.host.probes.traceActionControl("effect_stop_requested", control.command_key.slice(), active.attempt.binding);
                const action = active.execution.requestStop(.now(run.host.io, .awake));
                run.host.store.revokeActionSender(active.attempt.binding) catch |err| {
                    _ = failBash(run, slot, "Bash sender retirement", err);
                };
                run.host.probes.traceActionControlOutcome(
                    "lifecycle_action_attempted",
                    control.command_key.slice(),
                    action.attempted,
                    action.signal_failed,
                    active.attempt.binding,
                );
            }
        },
        else => {},
    };
}

noinline fn completeBash(run: *Run, slot: *ExecutionSlot) void {
    const active = &slot.bash;
    const binding = active.attempt.binding;
    const profile = tool_record.Runner.bash.resultProfile(true);
    const result = @import("tool_result.zig").Result.create(run.host, binding.action_id, profile) catch |err| {
        _ = failBash(run, slot, "Bash result allocation", err);
        return;
    };
    defer result.destroy();
    const materialized = materializeBashResult(run, slot, result) orelse return;
    const code = materialized.code;
    const value = materialized.value;
    pause(run.host, .{ .action_result = binding });
    // This blocking pause holds the shared execution loop until release.
    if (comptime test_pause.enabled) reachAction(run, .action_result_ready, binding);
    const delivered = active.attempt.settle(.{ .result = .{ .code = code, .value = value, .retained = result } });
    switch (delivered) {
        // This blocking pause holds the shared execution loop until release.
        .delivered, .session_stop => if (comptime test_pause.enabled) reachAction(run, .action_result_committed, binding),
        .lost, .fenced => {},
    }
    closeBashDelivery(run, slot);
}

const MaterializedBashResult = struct {
    code: store_module.ActionResolutionCode,
    value: @import("tool_result.zig").Value,
};

/// Keeps output materialization's frame off the stack while the result settles.
noinline fn materializeBashResult(run: *Run, slot: *ExecutionSlot, result: *@import("tool_result.zig").Result) ?MaterializedBashResult {
    const code = slot.bash.execution.writeResult(bashScratch(run), run.host.retention, result) catch |err| {
        _ = failBash(run, slot, "Bash outcome materialization", err);
        return null;
    };
    return switch (result.finish()) {
        .value => |value| .{ .code = code, .value = value },
        .failed => |failure| {
            _ = slot.bash.attempt.settle(.{ .fence = .{ .phase = "Bash result finalization", .fault = failure.failure } });
            closeBashDelivery(run, slot);
            return null;
        },
    };
}

fn failBash(run: *Run, slot: *ExecutionSlot, phase: []const u8, err: anyerror) bool {
    _ = slot.bash.attempt.settle(.{ .fence = .{ .phase = phase, .fault = .{ .capture = err } } });
    if (slot.bash.delivery != .open) return false;
    closeBashDelivery(run, slot);
    return true;
}

fn closeBashDelivery(run: *Run, slot: *ExecutionSlot) void {
    var closed = slot.bash;
    std.debug.assert(closed.delivery == .open);
    closed.delivery = .{ .closed = .{ .closing = closed.attempt.close(), .reclaim_at = .now(run.host.io, .awake) } };
    moveSlot(run, slot, .bash, closed);
    run.host.probes.traceAction("cleanup_started", closed.attempt.binding);
}

fn reclaimBash(run: *Run, slot: *ExecutionSlot, now: std.Io.Clock.Timestamp) bool {
    const active = &slot.bash;
    const closed = &active.delivery.closed;
    const retry_at = now.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    if (bashReclaimHeld(run.host, active.attempt.binding, closed.reclaim_failed)) {
        closed.reclaim_at = retry_at;
        return false;
    }
    active.execution.reclaim(bashScratch(run), run.host.retention) catch |err| {
        const first_failure = !closed.reclaim_failed;
        closed.reclaim_failed = true;
        closed.reclaim_at = retry_at;
        if (first_failure) run.host.lifecycle.retainDispatchFence("Bash resource reclamation", err);
        return first_failure;
    };
    const binding = active.attempt.binding;
    const closing = closed.closing;
    moveSlot(run, slot, .free, {});
    closing.finish();
    run.host.probes.traceAction("cleanup_completed", binding);
    return true;
}

fn retainBashPreparedCleanup(
    run: *Run,
    slot: *ExecutionSlot,
    cleanup: bash.PreparedCleanup,
    err: anyerror,
) void {
    run.host.lifecycle.retainDispatchFence("Bash preparation cleanup", err);
    const closing = slot.bash_preparing.attempt.close();
    const work = &run.bash_work[closing.token.index];
    work.* = .{ .prepared_cleanup = cleanup };
    moveSlot(run, slot, .bash_prepared_cleanup, .{
        .closing = closing,
        .cleanup = &work.prepared_cleanup,
    });
}

noinline fn settleArgumentsTooLarge(slot: *ExecutionSlot, sizes: bash.ArgumentSizes) void {
    var message: [bash.arguments_message_bytes]u8 = undefined;
    settleActionFailure(slot, .spawn_failed, bash.argumentsTooLargeMessage(&message, sizes));
}

/// Settles the preparing slot's Attempt with a fixed result.
fn settleActionFailure(
    slot: *ExecutionSlot,
    code: store_module.ActionResolutionCode,
    result: []const u8,
) void {
    _ = slot.bash_preparing.attempt.settle(.{ .text = .{ .code = code, .text = result } });
}

fn admitNewAttempt(
    run: *Run,
    slot: *ExecutionSlot,
    kind: store_module.ModelAdmissionKind,
    preparation: *model_adapter.Preparation,
    pending: *store_module.ModelAdmissionPreparation,
) AdmissionProgress {
    if (!run.host.lifecycle.launchAllowed()) {
        pending.deinit();
        return .no_work;
    }
    if (pending.pending() and !pending.pendingReady()) return .progress;
    const token = run.custody.reserve() orelse return .no_work;
    const progress = run.host.store.admitModelAttemptStep(kind, run.host.probes.storeFaults(.attempt_admission), .{
        .view = &preparation.page,
        .settings = &preparation.settings,
        .remembered = model_adapter.remembered(&run.history_memos),
    }, pending) catch |err| {
        run.custody.releaseUnused(token) catch unreachable;
        pending.deinit();
        run.host.lifecycle.fenceDispatch("Attempt admission", err);
        return .retry_later;
    };
    var admission = switch (progress) {
        .progress => {
            run.custody.releaseUnused(token) catch unreachable;
            return .progress;
        },
        .done => |admitted| admitted orelse {
            run.custody.releaseUnused(token) catch unreachable;
            return .no_work;
        },
    };
    return beginAdmittedAttempt(run, slot, token, &admission.permit, preparation, admission.request_started);
}

fn admitRetryAttempt(
    run: *Run,
    slot: *ExecutionSlot,
    active: store_module.ActiveOperationFilter,
    preparation: *model_adapter.Preparation,
    scanned: *bool,
    due_ms: *?u64,
) AdmissionProgress {
    const token = run.custody.reserve() orelse return .no_work;
    var admission = run.host.store.tryAdmitNextModelRetry(active, run.host.probes.storeFaults(.attempt_admission), due_ms) catch |err| {
        run.custody.releaseUnused(token) catch unreachable;
        run.host.lifecycle.fenceDispatch("retry Attempt admission", err);
        return .retry_later;
    } orelse {
        run.custody.releaseUnused(token) catch unreachable;
        scanned.* = true;
        return .no_work;
    };
    return beginAdmittedAttempt(run, slot, token, &admission.permit, preparation, false);
}

fn beginAdmittedAttempt(
    run: *Run,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: *store_module.DispatchPermit,
    preparation: *model_adapter.Preparation,
    started: bool,
) AdmissionProgress {
    const binding = attachSlot(run, slot, token, permit) catch |err| {
        if (started) preparation.page.close();
        run.custody.releaseUnused(token) catch unreachable;
        run.host.lifecycle.fenceDispatch("custody attachment", err);
        return .admitted;
    };
    if (!started) preparation.page.open(binding);
    var retained_scratch: ?named_scratch.Owner = null;
    preparation.init(
        run.host.io,
        run.host.lease.paths.scratch.slice(),
        run.scratch_budget.?,
        run.host.providers.served(),
        &run.history_memos,
        run.host.probes.preparationFaults(),
        &retained_scratch,
    ) catch |err| {
        finishModelPreparationFailure(run, slot, slot.model_preparing, err, retained_scratch);
        return .admitted;
    };
    run.host.probes.traceOperation("preparation_started", binding);
    return .admitted;
}

fn advanceModelPreparation(
    run: *Run,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
    listings: *std.EnumArray(provider.ListingKind, ListingWork),
    byte_allowance: usize,
    item_allowance: usize,
) bool {
    if (run.auth_worker) |worker| {
        if (advanceCredentialWork(run, reactor.?, slots, worker, &preparation.request, listings)) return true;
        for (slots) |*slot| if (slot.* == .model_authenticating) return false;
    }
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .model_preparing => break candidate,
        else => {},
    } else return false;
    var owner = slot.model_preparing;
    if (execution.modelDecision(.{ .preparing = .{ .launch_allowed = run.host.lifecycle.launchAllowed() } }) == .abandon) {
        preparation.cancel();
        finishCustodyNow(run, slot);
        return true;
    }
    run.host.probes.traceOperation("preparation_advance_started", owner.binding);
    var progress = preparation.advance(byte_allowance, item_allowance);
    while (progress == .read) {
        run.host.store.readRequestPage(&preparation.page) catch |err| {
            progress = .{ .failed = err };
            break;
        };
        progress = preparation.proceed();
    }
    const stats = preparation.advanceStats();
    switch (progress) {
        .read => unreachable,
        .pending => {
            run.host.probes.tracePreparationAdvance("preparation_advance_completed", stats, owner.binding);
            // This blocking pause holds the shared execution loop until release.
            if (comptime test_pause.enabled) reachModel(run, .model_preparation_advanced, owner.binding);
        },
        .failed => |err| {
            run.host.probes.tracePreparationAdvanceError("preparation_advance_failed", err, stats, owner.binding);
            preparation.cancel();
            finishModelPreparationFailure(run, slot, owner, err, null);
        },
        .prepared => |request| {
            owner.purpose = preparation.settings.operation;
            run.host.probes.tracePreparationAdvance("preparation_advance_completed", stats, owner.binding);
            run.host.probes.traceOperation("preparation_completed", owner.binding);
            const leased = run.host.providers.get(request.provider).?.credential.leased();
            switch (execution.modelDecision(.{ .prepared = .{ .authentication_required = leased } })) {
                .authenticate => {
                    moveSlot(run, slot, .model_authenticating, .{ .owner = owner });
                    _ = advanceCredentialWork(run, reactor.?, slots, run.auth_worker.?, request, listings);
                },
                .launch => launchPreparedRequest(run, reactor.?, slot, owner, request, null),
                else => unreachable,
            }
        },
    }
    return true;
}

fn advanceCredentialWork(run: *Run, reactor: *provider.Reactor, slots: []ExecutionSlot, worker: *AuthWorker, request: *provider.PreparedRequest, listings: *std.EnumArray(provider.ListingKind, ListingWork)) bool {
    for (slots) |*slot| switch (slot.*) {
        .model_authenticating => |*active| if (active.requested) return advanceAuthentication(run, reactor, slot, request),
        .model_refreshing => |*active| if (active.requested) return advanceRefresh(run, slot),
        else => {},
    };
    for (&listings.values, std.enums.values(provider.ListingKind)) |*work, kind| {
        if (work.auth == .requested) return advanceListingAuthentication(run, reactor, worker, kind, work);
    }
    if (!worker.idle()) return false;
    for (slots) |*slot| switch (slot.*) {
        .model_authenticating => |*active| {
            if (active.cancelled) {
                request.deinit(run.host.io, run.scratch_budget.?);
                finishCustodyNow(run, slot);
            } else {
                active.requested = true;
                worker.request(run.host.providers.get(request.provider).?.credential.signIn().?);
            }
            return true;
        },
        .model_refreshing => |*active| {
            if (active.cancelled) {
                finishCustodyNow(run, slot);
            } else {
                active.requested = true;
                worker.requestRefresh(active.refresh);
            }
            return true;
        },
        else => {},
    };
    for (&listings.values, std.enums.values(provider.ListingKind)) |*work, kind| {
        if (work.auth != .waiting) continue;
        work.auth = .requested;
        worker.request(listingCredential(run, kind).?.signIn().?);
        return true;
    }
    return false;
}

noinline fn advanceListingAuthentication(run: *Run, reactor: *provider.Reactor, worker: *AuthWorker, kind: provider.ListingKind, work: *ListingWork) bool {
    const result = worker.take() orelse return false;
    work.auth = .none;
    switch (result) {
        .ready => |lease| {
            defer worker.finish();
            startLeasedListing(run, reactor, kind, work, lease);
        },
        .failed => |err| listingFailed(run, kind, err),
        .refreshed => unreachable,
    }
    return true;
}

fn advanceRefresh(run: *Run, slot: *ExecutionSlot) bool {
    const result = run.auth_worker.?.take() orelse return false;
    const active = slot.model_refreshing;
    if (!active.cancelled) {
        const rejected: store_module.ModelFailure = .{ .correlated = .{ .code = "provider_http_401", .request_id = active.request_id, .report = "" } };
        switch (result) {
            .refreshed => |refreshed| settleFailure(run, active.owner.token, active.owner.binding, rejected, if (refreshed) .refreshed else .ordinary),
            .failed => |err| settleFailure(run, active.owner.token, active.owner.binding, .{ .uncorrelated = providers.leaseFailureCode(err) }, .ordinary),
            .ready => unreachable,
        }
    }
    finishCustodyNow(run, slot);
    return true;
}

fn retireAnsweredResponse(response: *?provider.SealedResponse) void {
    if (response.*) |*sealed| sealed.deinit();
    response.* = null;
}

fn beginForcedRefresh(run: *Run, slot: *ExecutionSlot, answered: *const AnsweredAttempt, refresh: providers.Credential.Refresh, response: *?provider.SealedResponse) bool {
    const owner = answered.owner;
    const claimed = run.host.store.claimModelAuthRefresh(owner.binding) catch |err| {
        if (err != error.SupersededByControl) run.host.lifecycle.fenceDispatch("credential refresh claim", err);
        slot.provider.transfer.deinit();
        retireAnsweredResponse(response);
        finishCustodyNow(run, slot);
        return true;
    };
    if (!claimed) return false;
    slot.provider.transfer.deinit();
    retireAnsweredResponse(response);
    moveSlot(run, slot, .model_refreshing, .{
        .owner = owner,
        .refresh = refresh,
        .request_id = answered.request_id,
    });
    return true;
}

fn advanceAuthentication(run: *Run, reactor: *provider.Reactor, slot: *ExecutionSlot, request: *provider.PreparedRequest) bool {
    const worker = run.auth_worker.?;
    const result = worker.take();
    const active = &slot.model_authenticating;
    const decision = execution.modelDecision(.{ .authenticating = .{
        .cancelled = active.cancelled,
        .launch_allowed = run.host.lifecycle.launchAllowed(),
        .result = if (result) |value| (if (value == .ready) .ready else .failed) else .pending,
    } });
    if (decision == .wait) return false;
    defer if (result.? == .ready) worker.finish();
    const owner = active.owner;
    switch (decision) {
        .launch => launchPreparedRequest(run, reactor, slot, owner, request, result.?.ready),
        .abandon, .settle_authentication_failure => {
            request.deinit(run.host.io, run.scratch_budget.?);
            if (decision == .settle_authentication_failure)
                settleUnansweredFailure(run, owner.token, owner.binding, providers.leaseFailureCode(result.?.failed), .ordinary);
            finishCustodyNow(run, slot);
        },
        else => unreachable,
    }
    return true;
}

fn finishModelPreparationFailure(
    run: *Run,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    err: anyerror,
    retained_scratch: ?named_scratch.Owner,
) void {
    switch (execution.modelDecision(.{ .preparation_failed = .{
        .retained_scratch = retained_scratch != null,
        .canonical_fenced = retained_scratch == null and run.host.store.isFenced(),
        .superseded = err == error.SupersededByControl,
    } })) {
        .retain_cleanup => {
            moveSlot(run, slot, .named_scratch, .{ .token = owner.token, .owner = retained_scratch.? });
            run.host.lifecycle.retainDispatchFence("request scratch unlink", err);
            return;
        },
        .fence => run.host.lifecycle.fenceDispatch("canonical request read", err),
        .settle_preparation_failure => settleUnansweredFailure(run, owner.token, owner.binding, model_adapter.preparationFailureCode(err), .ordinary),
        .abandon => {},
        else => unreachable,
    }
    finishCustodyNow(run, slot);
}

fn launchPreparedRequest(
    run: *Run,
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    request: *provider.PreparedRequest,
    lease: ?*const providers.Lease,
) void {
    const token = owner.token;
    const binding = owner.binding;
    if (!run.host.lifecycle.launchAllowed()) {
        request.deinit(run.host.io, run.scratch_budget.?);
        finishCustodyNow(run, slot);
        return;
    }
    var retained_response: ?named_scratch.Owner = null;
    if (failedAtProviderPrepare(run, slot, token, binding, request)) return;
    const served = run.host.providers.get(request.provider).?;
    var headers: providers.Headers = .{};
    defer headers.deinit();
    served.credential.fields(served.endpoint, run.host.providers.ca_file, lease, &reactor.credentials, &headers) catch |err| {
        request.deinit(run.host.io, run.scratch_budget.?);
        run.host.lifecycle.fenceDispatch("provider preparation", err);
        finishCustodyNow(run, slot);
        return;
    };
    moveSlot(run, slot, .provider, .{
        .owner = .{ .token = token, .binding = binding, .purpose = owner.purpose.? },
        .rejection = served.credential.rejection(lease),
    });
    const active = &slot.provider;
    active.transfer.start(reactor, request, binding, .{
        .fields = headers.fields(),
        .observe_allowance = run.host.probes.hooks.observe_allowance and served.credential.signIn() != null,
        .timing = run.custody.modelTiming(token) catch unreachable,
        .credential = headers.takeCredential(),
        .routing = .{ .turn_id = binding.turn_id, .owner = served.credential.routingOwner(lease) },
        .faults = run.host.probes.transferFaults(),
        .response_workspace_bytes = if (owner.purpose == .compaction) @sizeOf(PendingFailure) else 0,
    }, &retained_response) catch |err| {
        request.deinit(run.host.io, run.scratch_budget.?);
        if (retained_response) |retained| {
            moveSlot(run, slot, .named_scratch, .{
                .token = token,
                .owner = retained,
            });
            run.host.lifecycle.retainDispatchFence("response scratch unlink", err);
            return;
        }
        stderr.print("rui: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleUnansweredFailure(run, token, binding, "response_capture_failed", .ordinary);
        } else {
            run.host.lifecycle.fenceDispatch("provider preparation", err);
        }
        finishCustodyNow(run, slot);
        return;
    };
    run.host.probes.noteTransferStarted();
    // This blocking pause holds the shared execution loop until release.
    if (comptime test_pause.enabled) reachModel(run, .model_before_handoff, binding);
    pause(run.host, .{ .model_launch = binding });
    run.custody.consumeLaunchAuthority(token, .{ .model = binding }, std.Io.Clock.Timestamp.now(run.host.io, .awake)) catch |err| {
        active.transfer.deinit();
        stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        run.host.lifecycle.fenceDispatch("dispatch handoff", err);
        finishCustodyNow(run, slot);
        return;
    };
    run.host.store.withDispatchHandoff(
        binding,
        .{ .host = run.host, .reactor = reactor, .transfer = &active.transfer },
        struct {
            fn handoff(context: anytype) !void {
                try context.host.lifecycle.withEffectLaunch(context, launch);
            }

            fn launch(context: anytype) !void {
                context.reactor.launch(context.transfer);
            }
        }.handoff,
    ) catch |err| {
        active.transfer.deinit();
        switch (execution.modelDecision(.{ .handoff_failed = if (err == error.HostDispatchSuppressed)
            .suppressed
        else if (err == error.SupersededByControl)
            .superseded
        else
            .unexpected })) {
            .abandon => if (err == error.SupersededByControl) {
                run.host.probes.traceOperation("canonical_handoff_superseded", binding);
            },
            .fence => {
                stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
                run.host.lifecycle.fenceDispatch("dispatch handoff", err);
            },
            else => unreachable,
        }
        finishCustodyNow(run, slot);
        return;
    };
    run.host.probes.traceOperation("transport_handoff_committed", binding);
}

fn completeTransfer(
    run: *Run,
    workspace: *Workspace,
    slot: *ExecutionSlot,
    completion: provider.Completion,
) void {
    const active = &slot.provider;
    const owner = active.owner;
    if (active.transfer.allowance) |observation| server_host.writeAllowance(&run.host.allowance_diagnostic, observation);
    run.host.probes.traceCompletionQueue(completion.queued_after, owner.binding);
    defer run.host.probes.traceOperation("provider_completion_serviced", owner.binding);
    if (run.host.providers.anySignIn()) run.host.probes.traceTransfer(&active.transfer, owner.binding);
    var error_response: execution.ErrorResponse = .ordinary;
    var answered_response: ?provider.SealedResponse = null;
    defer retireAnsweredResponse(&answered_response);
    var http_status: ?u16 = null;
    switch (completion.outcome) {
        .transport_finished => |evidence| {
            http_status = evidence.http_status;
            if (evidence.disposition.answered()) {
                answered_response = active.transfer.takeResponse();
                const response = &answered_response.?;
                error_response = model_adapter.interpretErrorResponse(&workspace.decode, active.transfer.codec(), run.host.io, response.file, response.length, evidence.http_status, &workspace.provider_failure);
                if (error_response == .unreadable) stderr.print("rui: provider error capture unreadable for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(error_response.unreadable) });
            }
        },
        else => {},
    }
    const decision = execution.transferDecision(completion.outcome, error_response);
    var code_buffer: [96]u8 = undefined;
    var diagnostic_buffer: [512]u8 = undefined;
    const diagnostic = if (decision == .fail and decision.fail.quota != null)
        decision.fail.quota.?.format(&diagnostic_buffer)
    else
        null;
    if (answered_response) |*response| {
        retainFailedResponse(run, .{ .file = response.file, .length = response.length, .transfer = .complete }, .{
            .binding = owner.binding,
            .code = active.failureCode(decision.fail, &code_buffer),
            .diagnostic = diagnostic,
            .http_status = http_status,
            .request_id = active.transfer.requestId(),
        });
    }
    switch (decision) {
        .interpret_output => {
            var completed = completeSuccessfulTransfer(run, workspace, active, http_status.?);
            switch (completed) {
                .cleanup => finishCustodyNow(run, slot),
                .rejected => |*rejected| completeRejectedTransfer(run, workspace, slot, rejected, http_status.?),
                .named_scratch => |scratch| {
                    moveSlot(run, slot, .named_scratch, .{
                        .token = owner.token,
                        .owner = scratch,
                    });
                },
            }
            return;
        },
        .fence_request_source => run.host.lifecycle.fenceDispatch("request scratch read", error.RequestScratchReadFailed),
        .fail => |failure| {
            const code = active.failureCode(failure, &code_buffer);
            const disposition = failureClass(run.host, failure.kind, failure.retry_after_ms, failure.retry_after_deadline_ms);
            if (failure.answered) {
                const answered: AnsweredAttempt = .init(run, owner, &active.transfer);
                if (execution.rejectsCredential(failure)) switch (active.rejection) {
                    .refresh_once => |refresh| if (beginForcedRefresh(run, slot, &answered, refresh, &answered_response)) return,
                    .settle, .key_rejected => {},
                };
                const failure_record: store_module.ModelFailure = if (diagnostic) |detail|
                    answered.rejection(code, detail, workspace.provider_failure.report.slice())
                else
                    .{ .correlated = .{ .code = code, .request_id = answered.request_id, .report = workspace.provider_failure.report.slice() } };
                if (beginOverflowFailure(run, owner, failure_record, disposition, &answered_response.?)) |pending| {
                    if (pending) {
                        const response = answered_response.?;
                        answered_response = null;
                        active.transfer.deinit();
                        moveSlot(run, slot, .model_failure_preparing, .{ .owner = owner, .response = response });
                        return;
                    }
                } else if (diagnostic) |detail| {
                    answered.reject(code, detail, workspace.provider_failure.report.slice(), disposition);
                } else {
                    answered.fail(code, workspace.provider_failure.report.slice(), disposition);
                }
            } else {
                const response = active.transfer.partialResponse();
                if (response.length != 0) retainFailedResponse(run, .{
                    .file = response.file,
                    .length = response.length,
                    .transfer = if (completion.outcome == .response_capture_failed) .capture_failed else .interrupted,
                }, .{ .binding = owner.binding, .code = code, .request_id = active.transfer.requestId() });
                settleFailure(run, owner.token, owner.binding, .{ .uncorrelated = code }, disposition);
            }
        },
    }
    active.transfer.deinit();
    retireAnsweredResponse(&answered_response);
    finishCustodyNow(run, slot);
}

fn failureClass(
    host: *const Host,
    kind: execution.FailureKind,
    retry_after_ms: ?u64,
    retry_after_deadline_ms: ?i64,
) store_module.ModelFailureClass {
    return switch (kind) {
        .permanent => .ordinary,
        .effort_change_refused => .effort_change_refused,
        .context_overflow => .context_overflow,
        .temporary => .{ .retryable = .{
            .waits_ms = host.limits.retry_waits_ms,
            .retry_after_ms = retry_after_ms,
            .retry_after_deadline_ms = retry_after_deadline_ms,
        } },
    };
}

const RejectedCompletion = struct {
    response: provider.SealedResponse,
    request_id: protocol.Bounded(256),
};

const SuccessfulCompletion = union(enum) {
    cleanup,
    rejected: RejectedCompletion,
    named_scratch: named_scratch.Owner,
};

// Keep failure settlement outside the parser's metadata and diagnostic frame.
// The returned capture and request ID preserve ownership after transport ends.
noinline fn completeRejectedTransfer(run: *Run, workspace: *Workspace, slot: *ExecutionSlot, rejected: *RejectedCompletion, http_status: u16) void {
    const owner = slot.provider.owner;
    const answered: AnsweredAttempt = .{ .run = run, .owner = owner, .request_id = rejected.request_id };
    const response = &rejected.response;
    var response_owned = true;
    defer if (response_owned) response.deinit();
    const rejection = &workspace.interpretation.rejected;
    run.host.probes.traceOperation("validation_failed", owner.binding);
    stderr.print("rui: provider output rejected for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(rejection.reason) });
    var detail: [512]u8 = undefined;
    const diagnostic = rejection.format(&detail);
    retainFailedResponse(run, .{ .file = response.file, .length = response.length, .transfer = .complete }, answered.retention(rejection.code, diagnostic, http_status));
    const disposition = failureClass(run.host, rejection.kind, null, null);
    if (beginOverflowFailure(run, owner, answered.rejection(rejection.code, diagnostic, workspace.provider_failure.report.slice()), disposition, response)) |pending| {
        if (pending) {
            response_owned = false;
            moveSlot(run, slot, .model_failure_preparing, .{ .owner = owner, .response = response.* });
            return;
        }
    } else answered.reject(rejection.code, diagnostic, workspace.provider_failure.report.slice(), disposition);
    response.deinit();
    response_owned = false;
    finishCustodyNow(run, slot);
}

noinline fn completeSuccessfulTransfer(run: *Run, workspace: *Workspace, active: *ProviderSlot, http_status: u16) SuccessfulCompletion {
    const owner = active.owner;
    const structured_output = active.transfer.hasStructuredOutput();
    const answered: AnsweredAttempt = .init(run, owner, &active.transfer);
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(active.transfer.observedModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(active.transfer.observedAlternateModel()) catch unreachable;
    const codec = active.transfer.codec();
    var response = active.transfer.takeResponse();
    active.transfer.deinit();
    var response_owned = true;
    defer if (response_owned) response.deinit();
    const rejected: failed_responses.Source = .{ .file = response.file, .length = response.length, .transfer = .complete };
    if (model_adapter.outputSchemaRejection(structured_output, response.length)) |rejection| {
        rejectOutputSchema(run, rejected, &answered, rejection, http_status);
        return .cleanup;
    }

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = named_scratch.NumericName.@"response-metadata".format(
        &metadata_name_buffer,
        owner.binding.operation_id,
        owner.binding.attempt_ordinal,
    ) catch unreachable;
    var retained_metadata: ?named_scratch.Owner = null;
    const metadata_budget = run.host.retention.sharedBudget().narrowed(run.host.limits.request_scratch_limit_bytes);
    var metadata = output_format.OutputMetadataWriter.init(
        run.host.io,
        run.host.lease.paths.scratch.slice(),
        metadata_name,
        metadata_budget,
        run.host.probes.fails(.response_metadata_unlink),
        &retained_metadata,
    ) catch |err| {
        if (retained_metadata) |retained| {
            run.host.lifecycle.retainDispatchFence("response metadata unlink", err);
            return .{ .named_scratch = retained };
        }
        stderr.print("rui: response metadata acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        retainFailedResponse(run, rejected, answered.retention("response_metadata_exhausted", null, http_status));
        answered.fail("response_metadata_exhausted", "", .ordinary);
        return .cleanup;
    };
    defer metadata.deinit();
    var data_name_buffer: [96]u8 = undefined;
    const data_name = named_scratch.NumericName.response.format(&data_name_buffer, owner.binding.operation_id, owner.binding.attempt_ordinal) catch unreachable;
    var retained_data: ?named_scratch.Owner = null;
    const event_data = &workspace.event_data;
    event_data.init(run.host.io, run.host.lease.paths.scratch.slice(), data_name, metadata_budget, false, &retained_data) catch |err| {
        if (retained_data) |retained| {
            run.host.lifecycle.retainDispatchFence("response data unlink", err);
            return .{ .named_scratch = retained };
        }
        stderr.print("rui: response data acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        retainFailedResponse(run, rejected, answered.retention("response_data_exhausted", null, http_status));
        answered.fail("response_data_exhausted", "", .ordinary);
        return .cleanup;
    };
    defer event_data.deinit();
    run.host.probes.traceOperation("validation_started", owner.binding);
    const operation = owner.purpose;
    metadata.fail_writes = run.host.probes.fails(.response_metadata);
    output_decode.interpret(&workspace.interpret, codec, run.host.io, response.file, response.length, &metadata, event_data, operation, .{
        .openai = openai_model.slice(),
        .alternate = x_openai_model.slice(),
    }, &workspace.provider_failure, &workspace.interpretation);
    const accepted = switch (workspace.interpretation) {
        .accepted => |*value| value,
        .rejected => {
            response_owned = false;
            return .{ .rejected = .{ .response = response, .request_id = answered.request_id } };
        },
    };
    const validated = &accepted.output;
    run.host.probes.traceOperation("validation_completed", owner.binding);
    if (comptime test_pause.enabled) reachModel(run, .model_result_ready, owner.binding);
    pause(run.host, .{ .model_result = owner.binding });
    if (!run.custody.claimTerminalDelivery(owner.token)) return .cleanup;
    var settlement_trace = SettlementTrace.init(run.host, owner.binding);
    workspace.settlement = .{
        .source = validated.source,
        .source_length = validated.source_length,
        .metadata = metadata.file,
        .item_count = validated.item_count,
        .call_count = validated.call_count,
        .answer_item_ordinal = validated.answer_item_ordinal,
        .answer_length = validated.answer_length,
        .answer_digest = validated.answer_digest,
        .response_id = validated.evidence.response_id,
        .model_evidence = accepted.model_evidence,
        .request_id = answered.request_id,
    };
    run.host.store.settleModelSuccess(owner.binding, &workspace.settlement, run.host.probes.storeFaults(.{ .model_output = settlement_trace.storeTrace() })) catch |err| {
        if (err == error.SupersededByControl) {
            run.host.probes.traceOperation("model_settlement_superseded", owner.binding);
        } else if (err == error.InvalidProviderEnvelope) {
            rejectContradictoryOutput(run, rejected, &answered, err, http_status);
        } else {
            run.host.lifecycle.fenceDispatch("model output import", err);
        }
        return .cleanup;
    };
    run.host.probes.traceOperation("model_settlement_committed", owner.binding);
    return .cleanup;
}

// Diagnostic buffers and the failure's Store settlement live in these frames,
// not in completeSuccessfulTransfer's, which already holds the response
// decode state on the engine's deepest stack chain.
noinline fn rejectOutputSchema(
    run: *Run,
    rejected: failed_responses.Source,
    answered: *const AnsweredAttempt,
    rejection: output_decode.Rejected,
    http_status: u16,
) void {
    var detail: [512]u8 = undefined;
    const diagnostic = rejection.format(&detail);
    retainFailedResponse(run, rejected, answered.retention(rejection.code, diagnostic, http_status));
    answered.reject(rejection.code, diagnostic, "", .ordinary);
}

noinline fn rejectContradictoryOutput(
    run: *Run,
    rejected: failed_responses.Source,
    answered: *const AnsweredAttempt,
    err: anyerror,
    http_status: u16,
) void {
    const rejection: output_decode.Rejection = .{ .stage = .response, .byte_offset = rejected.length };
    var detail: [512]u8 = undefined;
    const diagnostic = rejection.format(err, &detail);
    retainFailedResponse(run, rejected, answered.retention("contradictory_provider_output", diagnostic, http_status));
    saveImmediateFailure(run, answered.owner.binding, answered.rejection("contradictory_provider_output", diagnostic, ""), .ordinary);
}

fn advanceRetainedCleanup(
    run: *Run,
    slots: []ExecutionSlot,
    now: std.Io.Clock.Timestamp,
    retry_at: *std.Io.Clock.Timestamp,
) bool {
    if (now.raw.nanoseconds < retry_at.raw.nanoseconds) return false;
    retry_at.* = now.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash_prepared_cleanup => |*retained| {
            retained.cleanup.cleanup(bashScratch(run)) catch continue;
            const closing = retained.closing;
            moveSlot(run, slot, .free, {});
            closing.finish();
            made_progress = true;
        },
        .named_scratch => |*retained| {
            _ = retained.owner.reclaim(run.host.lease.paths.scratch.slice()) catch continue;
            moveSlot(run, slot, .free, {});
            made_progress = true;
        },
        else => {},
    };
    return made_progress;
}

fn shutdownExecution(run: *Run, slots: []ExecutionSlot, workspace: *Workspace) void {
    workspace.model_admission.deinit();
    for (slots) |*slot| switch (slot.*) {
        .free => {},
        .model_preparing => {
            workspace.model_preparation.cancel();
            finishCustodyNow(run, slot);
        },
        .model_authenticating => {
            workspace.model_preparation.request.deinit(run.host.io, run.scratch_budget.?);
            finishCustodyNow(run, slot);
        },
        .model_refreshing => finishCustodyNow(run, slot),
        .model_failure_preparing => |*active| {
            active.deinit();
            finishCustodyNow(run, slot);
        },
        .bash_preparing => discardBashResources(run, slot, workspace.bash_preparation.cancel()),
        .bash => |*active| active.execution.requestInfrastructureShutdown(.now(run.host.io, .awake)),
        .bash_prepared_cleanup, .named_scratch => {},
        .provider => |*active| {
            active.transfer.deinit();
            finishCustodyNow(run, slot);
        },
    };
    if (comptime test_pause.enabled) if (run.host.probes.pause_owner) |owner| {
        _ = owner.reach(.host_shutdown_signalled, .{}) catch {};
    };
    var retained_cleanup_at = std.Io.Clock.Timestamp.now(run.host.io, .awake);
    while (hasOwnedSlots(slots)) {
        var made_progress = advanceBash(run, slots, workspace);
        const now = std.Io.Clock.Timestamp.now(run.host.io, .awake);
        made_progress = advanceRetainedCleanup(run, slots, now, &retained_cleanup_at) or made_progress;
        if (!made_progress) _ = run.host.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

fn hasTransport(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot == .provider) return true;
    }
    return false;
}

fn hasBash(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot == .bash_preparing or slot == .bash) return true;
    }
    return false;
}

fn hasOwnedSlots(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot != .free) return true;
    }
    return false;
}

const AnsweredAttempt = struct {
    run: *Run,
    owner: AttemptOwner,
    request_id: protocol.Bounded(256),

    fn init(run: *Run, owner: AttemptOwner, transfer: *const provider.Transfer) AnsweredAttempt {
        var request_id: protocol.Bounded(256) = .{};
        request_id.set(transfer.requestId()) catch unreachable;
        return .{ .run = run, .owner = owner, .request_id = request_id };
    }

    fn fail(self: *const AnsweredAttempt, code: []const u8, report: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.run, self.owner.token, self.owner.binding, .{ .correlated = .{
            .code = code,
            .request_id = self.request_id,
            .report = report,
        } }, disposition);
    }

    fn reject(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8, report: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.run, self.owner.token, self.owner.binding, self.rejection(code, diagnostic, report), disposition);
    }

    fn rejection(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8, report: []const u8) store_module.ModelFailure {
        return .{ .rejected = .{ .code = code, .diagnostic = diagnostic, .request_id = self.request_id, .report = report } };
    }

    fn retention(self: *const AnsweredAttempt, code: []const u8, diagnostic: ?[]const u8, http_status: u16) failed_responses.Failure {
        return .{
            .binding = self.owner.binding,
            .code = code,
            .diagnostic = diagnostic,
            .http_status = http_status,
            .request_id = self.request_id.slice(),
        };
    }
};

fn retainFailedResponse(run: *Run, source: failed_responses.Source, failure: failed_responses.Failure) void {
    if (source.length == 0) return;
    const store_dir = run.settings.failed_response_store orelse return;
    const status = status: {
        var dir = failed_responses.open(run.host.io, store_dir) catch |err| break :status err;
        defer dir.close(run.host.io);
        const retained = failed_responses.retain(run.host.io, dir, .{}, source, failure) catch |err| break :status err;
        break :status retained.omission orelse return;
    };
    stderr.print("rui: failed response for operation {d} attempt {d} not retained ({s}); its saved failure is unchanged\n", .{
        failure.binding.operation_id, failure.binding.attempt_ordinal, @errorName(status),
    });
}

fn failedAtProviderPrepare(
    run: *Run,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    request: *provider.PreparedRequest,
) bool {
    if (!run.host.probes.fails(.provider_prepare)) return false;
    request.deinit(run.host.io, run.scratch_budget.?);
    settleUnansweredFailure(run, token, binding, "provider_transport_failure", failureClass(run.host, .temporary, null, null));
    finishCustodyNow(run, slot);
    return true;
}

fn settleUnansweredFailure(
    run: *Run,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    code: []const u8,
    disposition: store_module.ModelFailureClass,
) void {
    settleFailure(run, token, binding, .{ .uncorrelated = code }, disposition);
}

fn settleFailure(
    run: *Run,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    failure: store_module.ModelFailure,
    disposition: store_module.ModelFailureClass,
) void {
    if (!run.custody.claimTerminalDelivery(token)) return;
    saveImmediateFailure(run, binding, failure, disposition);
}

fn saveImmediateFailure(run: *Run, binding: store_module.AttemptBinding, failure: store_module.ModelFailure, disposition: store_module.ModelFailureClass) void {
    const settled = run.host.store.settleModelAttemptFailurePrepared(binding, failure, disposition, run.host.probes.storeFaults(.model_failure), null) catch |err| {
        if (err != error.SupersededByControl) run.host.lifecycle.fenceDispatch("model failure save", err);
        return;
    };
    // Compaction overflow is staged by beginOverflowFailure while its response
    // still owns the pre-reserved continuation storage. No service caller may
    // fall back to a synchronous history scan.
    if (!settled) run.host.lifecycle.fenceDispatch("model failure preparation", error.MissingOverflowPreparation);
}

fn beginOverflowFailure(
    run: *Run,
    owner: AttemptOwner,
    failure: store_module.ModelFailure,
    disposition: store_module.ModelFailureClass,
    response: *provider.SealedResponse,
) ?bool {
    if (owner.purpose != .compaction or disposition != .context_overflow) return null;
    if (!run.custody.claimTerminalDelivery(owner.token)) return false;
    const settled = run.host.store.settleModelAttemptFailurePrepared(owner.binding, failure, disposition, run.host.probes.storeFaults(.model_failure), null) catch |err| {
        if (err != error.SupersededByControl) run.host.lifecycle.fenceDispatch("model failure save", err);
        return false;
    };
    if (settled) return false;
    // This storage was reserved and mapped before the provider was launched.
    // Retaining an overflow therefore needs neither spare scratch nor a handle.
    response.state(PendingFailure).init(owner.binding.operation_id, failure);
    return true;
}

fn advancePendingFailure(run: *Run, slots: []ExecutionSlot, workspace: *Workspace) bool {
    if (slots.len == 0) return false;
    for (0..slots.len) |offset| {
        const index = (workspace.failure_after + offset) % slots.len;
        const slot = &slots[index];
        if (slot.* != .model_failure_preparing) continue;
        workspace.failure_after = (index + 1) % slots.len;
        const active = &slot.model_failure_preparing;
        const owner = active.owner;
        const pending = active.response.state(PendingFailure);
        if (!run.host.lifecycle.launchAllowed()) {
            active.deinit();
            finishCustodyNow(run, slot);
            return true;
        }
        if (!pending.floor.ready) {
            _ = run.host.store.advanceHistoryFloor(&pending.floor) catch |err| {
                if (err != error.SupersededByControl) run.host.lifecycle.fenceDispatch("overflow floor preparation", err);
                active.deinit();
                finishCustodyNow(run, slot);
            };
            return true;
        }
        const settled = run.host.store.settleModelAttemptFailurePrepared(
            owner.binding,
            pending.value(),
            .context_overflow,
            run.host.probes.storeFaults(.model_failure),
            &pending.floor.prepared.?,
        ) catch |err| {
            if (err != error.SupersededByControl) run.host.lifecycle.fenceDispatch("model failure save", err);
            active.deinit();
            finishCustodyNow(run, slot);
            return true;
        };
        if (settled) {
            active.deinit();
            finishCustodyNow(run, slot);
        } else {
            pending.floor.deinit();
            pending.floor.init(owner.binding.operation_id);
        }
        return true;
    }
    return false;
}

fn finishCustodyNow(run: *Run, slot: *ExecutionSlot) void {
    const traced = if (run.host.probes.hooks.phase_trace) run.custody.binding(slotToken(slot).?) catch unreachable else null;
    switch (slot.*) {
        .bash_preparing => |*active| {
            const closing = active.attempt.close();
            moveSlot(run, slot, .free, {});
            closing.finish();
        },
        else => moveSlot(run, slot, .free, {}),
    }
    if (traced) |binding| switch (binding) {
        .model => |model| run.host.probes.traceOperation("cleanup_completed", model),
        .action => |action| run.host.probes.traceAction("cleanup_completed", action),
    };
}

test "model retry and inactivity defaults match the owning resource contract" {
    try std.testing.expectEqual([3]u64{ 2_000, 4_000, 8_000 }, retry_policy.default_waits_ms);
    try std.testing.expectEqual(@as(u64, 4), retry_policy.maximum_attempts);
    try std.testing.expectEqual(@as(i64, 5 * 60), (Limits{}).provider_inactivity_seconds);
}

test "authentication handoff borrows the sole credential lease and releases it once" {
    const credentials = @import("codex_credentials.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{
        .permissions = .fromMode(0o700),
    });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/auth", .{root[0..root_len]});
    var record = credentials.Record{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 1_750_000_000,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set("test-account");
    try record.id_token.set("aaa.bbb.ccc");
    try record.access_token.set("aaa.bbb.ccc");
    try record.refresh_token.set("test-refresh");
    var worker = AuthWorker{ .io = io };
    try credentials.install(path, &record, null, &worker.work.credentials);
    try credentials.leaseInto(path, &worker.credential, &worker.work.credentials);
    worker.state = .ready;
    defer if (worker.state == .ready or worker.state == .in_use) worker.credential.release();
    const borrowed = worker.take().?.ready;
    try std.testing.expect(borrowed == &worker.credential);
    try std.testing.expect(worker.take() == null);
    try std.testing.expectEqualStrings("test-refresh", borrowed.record.refresh_token.slice());
    worker.finish();
    try std.testing.expect(worker.state == .idle);
    worker.request(.{ .path = path, .wire = .codex_device });
    try std.testing.expect(worker.state == .requested);
    var next: credentials.Lease = undefined;
    try credentials.leaseInto(path, &next, &worker.work.credentials);
    next.release();

    for ([_]bool{ false, true }) |ready| {
        var records: [1]execution.CustodyRecord = @splat(.{});
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{}, .auth_worker = &worker };
        const token = execution_state.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 7,
            .operation_id = 19,
            .attempt_ordinal = 3,
        } };
        const binding = try execution_state.custody.attach(token, &permit);
        const output = try tmp.dir.createFile(io, "request", .{});
        try output.writeStreamingAll(io, "body");
        output.close(io);
        const input = try tmp.dir.openFile(io, "request", .{});
        try tmp.dir.deleteFile(io, "request");
        host.scratch_used.store(4, .release);
        run.scratch_budget = .{ .used = &host.scratch_used, .limit = 4 };
        var request: provider.PreparedRequest = .{
            .file = input,
            .length = 4,
            .charged = 4,
            .structured_output = false,
            .provider = .codex,
            .codec = .@"openai-responses/1",
            .headers = .{ .count = 0 },
        };
        var slot = ExecutionSlot{ .model_authenticating = .{
            .owner = .{ .token = token, .binding = binding },
            .cancelled = true,
        } };
        defer if (slot == .model_authenticating) request.deinit(io, run.scratch_budget.?);
        var reactor: provider.Reactor = undefined;
        worker.state = .{ .requested = .{ .acquire = .{ .path = path, .wire = .codex_device } } };
        try std.testing.expect(!advanceAuthentication(&run, &reactor, &slot, &request));
        try std.testing.expect(slot == .model_authenticating);
        try std.testing.expectEqual(@as(u64, 4), host.scratch_used.load(.acquire));
        try std.testing.expect(execution_state.custody.reserve() == null);
        if (ready) {
            try credentials.leaseInto(path, &worker.credential, &worker.work.credentials);
            worker.state = .ready;
        } else worker.state = .{ .failed = error.AuthenticationFailed };
        try std.testing.expect(advanceAuthentication(&run, &reactor, &slot, &request));
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
        try std.testing.expect(worker.state == .idle);
        const reused = execution_state.custody.reserve().?;
        try std.testing.expect(reused.generation != token.generation);
        try std.testing.expect(!execution_state.custody.claimTerminalDelivery(token));
        try execution_state.custody.releaseUnused(reused);
    }
}

test "a leased model list waits behind every model slot, and its lease always goes back" {
    const credentials = @import("codex_credentials.zig");
    const credential_policy = @import("codex_credential_policy.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/chatgpt.json", .{root[0..root_len]});
    var record = credentials.Record{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 1_750_000_000,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set("test-subject");
    try record.id_token.set("aaa.bbb.ccc");
    try record.access_token.set("test-plan-access");
    try record.refresh_token.set("test-refresh");
    try record.client_id.set(credential_policy.fixture_client_id);
    var worker = AuthWorker{ .io = io };
    try credentials.install(path, &record, null, &worker.work.credentials);
    defer if (worker.state == .ready or worker.state == .in_use) worker.credential.release();

    const models_url = "http://127.0.0.1:1/v1/models";
    var served: providers.Providers = .{};
    served.table.set(.codex, .{ .endpoint = "http://127.0.0.1:1/responses", .credential = .{ .chatgpt_device = .{ .path = path, .refresh = .synthetic } } });
    served.table.set(.chatgpt, .{ .endpoint = "http://127.0.0.1:1/v1/responses", .credential = .{ .chatgpt_plan = .{ .path = path, .refresh = .{ .fixture_endpoint = "http://127.0.0.1:1/token" } } } });
    const plan_source = served.get(.chatgpt).?.credential.signIn().?;
    const device_source = served.get(.codex).?.credential.signIn().?;
    var records: [1]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .providers = &served,
        .model_lists = .init(io, std.testing.allocator, &served),
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{}, .auth_worker = &worker };
    defer host.model_lists.deinit();
    var used: std.atomic.Value(u64) = .init(0);
    var urls: std.EnumArray(provider.ListingKind, ?[]const u8) = .initFill(null);
    urls.set(provider.providerListing(.chatgpt).?, models_url);
    var reactor: provider.Reactor = undefined;
    try reactor.init(std.testing.allocator, io, .{
        .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = "http://127.0.0.1:1/v1/responses" }),
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = "/nonexistent",
        .budget = .{ .used = &used, .limit = 1 },
        .listing_urls = urls,
    });
    defer reactor.deinit();
    var listings: std.EnumArray(provider.ListingKind, ListingWork) = .initFill(.{ .fetch = undefined, .credential = null, .response = null });
    for (urls.values, &listings.values) |url, *work| work.url = url;
    const kind = provider.providerListing(.chatgpt).?;
    const work = listings.getPtr(kind);
    defer endListing(&reactor, kind, work);
    var request: provider.PreparedRequest = undefined;
    request.provider = .codex;
    const waiting: ExecutionSlot = .{ .model_authenticating = .{ .owner = .{ .token = undefined, .binding = undefined } } };
    var slots = [_]ExecutionSlot{waiting};

    startListings(&run, &reactor, &listings);
    try std.testing.expect(work.auth == .waiting and !reactor.listingPending());
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(slots[0].model_authenticating.requested and work.auth == .waiting);
    try std.testing.expectEqual(device_source, worker.state.requested.acquire);
    try std.testing.expect(!advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(work.auth == .waiting);
    worker.state = .idle;
    slots[0] = .free;
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(work.auth == .requested);
    try std.testing.expectEqual(plan_source, worker.state.requested.acquire);
    slots[0] = waiting;
    try std.testing.expect(!advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(!slots[0].model_authenticating.requested);
    worker.state = .{ .failed = error.FileNotFound };
    try std.testing.expect(host.model_lists.live.get(.chatgpt) == .pending);
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(work.auth == .none and worker.state == .idle and !reactor.listingPending());
    try std.testing.expect(host.model_lists.live.get(.chatgpt) == .catalog_fallback);
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(slots[0].model_authenticating.requested);
    worker.state = .idle;
    slots[0] = .free;

    host.model_lists.set(.chatgpt, .pending);
    startListings(&run, &reactor, &listings);
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try credentials.leaseInto(path, &worker.credential, &worker.work.credentials);
    worker.state = .ready;
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(worker.state == .idle and work.auth == .none);
    try std.testing.expect(reactor.listings.get(kind) != null and work.credential != null);
    try std.testing.expect(host.model_lists.live.get(.chatgpt) == .pending);
    startListings(&run, &reactor, &listings);
    try std.testing.expect(work.auth == .none);
    endListing(&reactor, kind, work);

    work.url = "https://api.openai.com/v1/models";
    startListings(&run, &reactor, &listings);
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try credentials.leaseInto(path, &worker.credential, &worker.work.credentials);
    worker.state = .ready;
    try std.testing.expect(advanceCredentialWork(&run, &reactor, &slots, &worker, &request, &listings));
    try std.testing.expect(worker.state == .idle and work.auth == .none and !reactor.listingPending());
    try std.testing.expect(work.credential == null and work.response == null);
    try std.testing.expect(host.model_lists.live.get(.chatgpt) == .catalog_fallback);
}

test "authentication worker answers each job with that job's result" {
    const credentials = @import("codex_credentials.zig");
    const codex_auth = @import("codex_auth.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/codex.json", .{root[0..root_len]});
    var record: credentials.Record = .{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 100,
    };
    try record.account_id.set(codex_auth.fixture_account_id);
    try record.id_token.set(codex_auth.fixture_id_token);
    try record.access_token.set(codex_auth.fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
    var worker = AuthWorker{ .io = io };
    try credentials.install(path, &record, null, &worker.work.credentials);
    var other_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const other_path = try std.fmt.bufPrint(&other_buffer, "{s}/other.json", .{std.fs.path.dirname(path).?});
    try credentials.install(other_path, &record, null, &worker.work.credentials);
    try credentials.install(other_path, &record, null, &worker.work.credentials);
    const source: providers.Authentication = .{ .path = path, .wire = .codex_device, .refresh = .synthetic };
    const other: providers.Authentication = .{ .path = other_path, .wire = .codex_device, .refresh = .synthetic };
    const thread = try std.Thread.spawn(.{}, AuthWorker.run, .{&worker});
    defer worker.stop(thread);
    const answered = struct {
        fn check(target: *AuthWorker) bool {
            target.mutex.lockUncancelable(target.io);
            defer target.mutex.unlock(target.io);
            return target.state != .requested;
        }
    }.check;

    worker.request(source);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expect(worker.take().?.ready == &worker.credential);
    try std.testing.expectEqualStrings("synthetic-refresh", worker.credential.record.refresh_token.slice());
    try std.testing.expectEqual(@as(u64, 1), worker.credential.record.generation);
    worker.finish();
    worker.request(other);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expectEqual(@as(u64, 2), worker.take().?.ready.record.generation);
    worker.finish();
    worker.requestRefresh(.{ .source = source, .generation = 2 });
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expect(!worker.take().?.refreshed);
    worker.requestRefresh(.{ .source = other, .generation = 2 });
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expect(worker.take().?.refreshed);
    worker.requestRefresh(.{ .source = source, .generation = 1 });
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expect(worker.take().?.refreshed);
    try std.testing.expect(worker.take() == null);
    worker.requestRefresh(.{ .source = source, .generation = 1 });
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expect(!worker.take().?.refreshed);
    try tmp.dir.deleteFile(io, "private/codex.json");
    worker.requestRefresh(.{ .source = source, .generation = 2 });
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(5)), &worker, answered);
    try std.testing.expectEqual(error.FileNotFound, worker.take().?.failed);
    try std.testing.expect(worker.take() == null);
    try std.testing.expect(worker.idle());
}

test "HTTP error capture retires before execution custody" {
    const Boundary = struct {
        var slot: *ExecutionSlot = undefined;
        var custody: *execution.CustodyPool = undefined;
        var used: *std.atomic.Value(u64) = undefined;
        var response_fd: std.Io.File.Handle = -1;
        var closes: usize = 0;
        var retirement_observed: bool = false;

        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            for (files) |file| if (file.handle == response_fd) {
                std.debug.assert(slot.* == .provider);
                std.debug.assert(custody.occupied() == 1);
                closes += 1;
            };
            std.testing.io.vtable.fileClose(userdata, files);
        }

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (slot.* == .free) {
                std.debug.assert(closes == 1);
                std.debug.assert(std.c.fcntl(response_fd, std.c.F.GETFD) < 0);
                std.debug.assert(used.load(.acquire) == 17);
                retirement_observed = true;
            }
            return std.testing.io.vtable.now(userdata, clock);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var vtable = std.testing.io.vtable.*;
    vtable.fileClose = Boundary.close;
    vtable.now = Boundary.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const workspace = try pages.Mapped(Workspace).map();
    defer workspace.unmap();
    for (0..3) |kind| {
        var used: std.atomic.Value(u64) = .init(17);
        const budget = ScratchBudget{ .used = &used, .limit = 4096 };
        var records: [1]execution.CustodyRecord = @splat(.{});
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        host_parts.probes.hooks = .{ .phase_trace = true };
        const token = execution_state.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 3,
            .operation_id = 7,
            .attempt_ordinal = 2,
        } };
        const binding = try execution_state.custody.attach(token, &permit);
        try std.testing.expect(execution_state.custody.claimTerminalDelivery(token));
        var slot: ExecutionSlot = .{ .provider = .{ .owner = .{ .token = token, .binding = binding } } };
        Boundary.slot = &slot;
        Boundary.custody = &execution_state.custody;
        Boundary.used = &used;
        Boundary.response_fd = -1;
        Boundary.closes = 0;
        Boundary.retirement_observed = false;
        const request_file = try tmp.dir.createFile(io, "request", .{ .read = true });
        try request_file.writeStreamingAll(io, "{}");
        try std.testing.expect(budget.charge(2));
        var reactor: provider.Reactor = undefined;
        try reactor.init(std.testing.allocator, io, .{
            .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }),
            .capacity = 1,
            .inactivity_seconds = 1,
            .scratch_path = root,
            .budget = budget,
        });
        defer reactor.deinit();
        var retained: ?named_scratch.Owner = null;
        try slot.provider.transfer.start(&reactor, &.{
            .file = request_file,
            .length = 2,
            .charged = 2,
            .structured_output = false,
            .provider = .codex,
            .codec = .@"openai-responses/1",
            .headers = .{ .count = 0 },
        }, binding, .{}, &retained);
        errdefer if (slot == .provider) slot.provider.transfer.deinit();
        const body = if (kind == 2) "{\"error\":{\"code\":\"invalid_api_key\"}}" else "{\"error\":{\"code\":\"context_length_exceeded\"}}";
        const response = &slot.provider.transfer.response;
        try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&slot.provider.transfer.stream, .{ .body = body.len }));
        try response.file.writeStreamingAll(io, body);
        try response.seal(io, false, body.len);
        Boundary.response_fd = response.file.handle;
        if (kind == 1) {
            response.length += 1;
            const unreadable = model_adapter.interpretErrorResponse(&workspace.value.decode, slot.provider.transfer.codec(), io, response.file, response.length, 400, &workspace.value.provider_failure);
            try std.testing.expectEqual(execution.ErrorResponse{ .unreadable = error.ShortSealedRead }, unreadable);
        }
        completeTransfer(&run, workspace.value, &slot, .{
            .transfer = &slot.provider.transfer,
            .outcome = .{ .transport_finished = .{ .disposition = .permanent_http, .http_status = 400 } },
            .queued_after = 0,
        });
        try std.testing.expect(Boundary.retirement_observed);
        try std.testing.expectEqual(@as(usize, 1), Boundary.closes);
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
        try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
        try std.testing.expect(slot == .free);
        try std.testing.expect(execution_state.custody.reserve() != null);
    }
}

test "forced refresh captures retire before custody publication across Store claims" {
    const Case = enum { superseded, unreadable_store, declined, accepted };
    const Fixture = struct {
        tmp: std.testing.TmpDir,
        storage: store_module.Store,
        root: [platform.max_scratch_path_bytes]u8,
        records: [1]execution.CustodyRecord,
        host: Host,
        host_parts: TestParts,
        execution: execution_owner.Execution,
        run: Run,
        slot: ExecutionSlot,
        reactor: provider.Reactor,
        workspace: Workspace,
    };
    const Boundary = struct {
        var slot: *ExecutionSlot = undefined;
        var custody: *execution.CustodyPool = undefined;
        var token: execution.CustodyToken = undefined;
        var binding: store_module.AttemptBinding = undefined;
        var used: *std.atomic.Value(u64) = undefined;
        var response_fd: std.Io.File.Handle = -1;
        var response_charge: u64 = 0;
        var closes: usize = 0;
        var observing: bool = false;
        var retirement_observed: bool = false;

        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            if (observing) {
                for (files) |file| {
                    if (file.handle != response_fd) continue;
                    custody.checkAttached(token, .{ .model = binding }) catch unreachable;
                    std.debug.assert(used.load(.acquire) >= 17 + response_charge);
                    closes += 1;
                }
            }
            std.testing.io.vtable.fileClose(userdata, files);
        }

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (observing and slot.* == .free) {
                std.debug.assert(closes == 1);
                std.debug.assert(std.c.fcntl(response_fd, std.c.F.GETFD) < 0);
                std.debug.assert(used.load(.acquire) == 17);
                custody.checkFree(token) catch unreachable;
                retirement_observed = true;
            }
            return std.testing.io.vtable.now(userdata, clock);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.fileClose = Boundary.close;
    vtable.now = Boundary.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    for ([_]Case{ .superseded, .unreadable_store, .declined, .accepted }) |kind| {
        const mapped = try pages.Mapped(Fixture).map();
        defer mapped.unmap();
        const fixture = mapped.value;
        fixture.tmp = std.testing.tmpDir(.{});
        defer fixture.tmp.cleanup();
        try store_module.testingStoreWith(&.{ .engine = .sqlite }, &fixture.storage, &fixture.tmp, std.testing.io, .{});
        defer fixture.storage.close() catch unreachable;
        const root = fixture.root[0..try fixture.tmp.dir.realPath(std.testing.io, &fixture.root)];
        const session = try store_module.testing.configureTestSession(&fixture.storage, "refresh-custody-config");
        try store_module.testingSubmitMessage(&fixture.storage, &fixture.tmp, "refresh-custody-message", "refresh-custody-message", session.slice(), "hello");
        var admitted = (try fixture.storage.admitNextModelAttempt(.{})).?;
        fixture.records = @splat(.{});
        fixture.host = .{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = &fixture.storage,
        };
        fixture.host_parts.attach(&fixture.host, undefined);
        fixture.execution.init(&fixture.records, null, &fixture.host_parts.lifecycle, &fixture.host.scratch_used, null);
        fixture.run = .{ .host = &fixture.host, .settings = .{}, .execution = &fixture.execution, .custody = &fixture.execution.custody };
        fixture.host_parts.probes.hooks = .{ .phase_trace = true };
        fixture.host.scratch_used.store(17, .release);
        const budget = ScratchBudget{ .used = &fixture.host.scratch_used, .limit = 4 * 1024 * 1024 };
        const token = fixture.execution.custody.reserve().?;
        const binding = try fixture.execution.custody.attach(token, &admitted.permit);
        fixture.slot = .{ .provider = .{
            .owner = .{ .token = token, .binding = binding, .purpose = .assistant_response },
            .rejection = .{ .refresh_once = .{
                .source = .{ .path = root, .wire = .codex_device },
                .generation = 7,
            } },
        } };
        try fixture.reactor.init(std.testing.allocator, io, .{
            .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }),
            .capacity = 1,
            .inactivity_seconds = 1,
            .scratch_path = root,
            .budget = budget,
        });
        defer fixture.reactor.deinit();
        const request_file = try fixture.tmp.dir.createFile(io, "refresh-custody-request", .{ .read = true });
        try request_file.writeStreamingAll(io, "{}");
        try std.testing.expect(budget.charge(2));
        var retained: ?named_scratch.Owner = null;
        try fixture.slot.provider.transfer.start(&fixture.reactor, &.{
            .file = request_file,
            .length = 2,
            .charged = 2,
            .structured_output = false,
            .provider = .codex,
            .codec = .@"openai-responses/1",
            .headers = .{ .count = 0 },
        }, binding, .{ .response_workspace_bytes = @sizeOf(PendingFailure) }, &retained);
        defer if (fixture.slot == .provider) {
            fixture.slot.provider.transfer.deinit();
            finishCustodyNow(&fixture.run, &fixture.slot);
        };
        const body = "{\"error\":{\"code\":\"invalid_api_key\"}}";
        const response = &fixture.slot.provider.transfer.response;
        try std.testing.expectEqual(@as(usize, @sizeOf(PendingFailure)), response.workspace.len);
        try std.testing.expectEqual(h2.Verdict.accept, fixture.reactor.observe(&fixture.slot.provider.transfer.stream, .{ .body = body.len }));
        try response.file.writePositionalAll(io, body, 0);
        try response.seal(io, false, body.len);
        try std.testing.expectEqual(@as(u64, @max(@sizeOf(PendingFailure), body.len)), response.charged);
        try std.testing.expectEqual(@as(u64, 19) + response.charged, fixture.host.scratch_used.load(.acquire));
        switch (kind) {
            .superseded => {
                var stop: protocol.SessionStopCommand = .{};
                try stop.key.set("refresh-custody-stop");
                try stop.session.set(session.slice());
                try std.testing.expect(fixture.storage.stopSession(&stop, .{}) == .accepted);
            },
            .unreadable_store => try store_module.testingFailReadsOf(&fixture.storage, "model_operation"),
            .declined => try std.testing.expect(try fixture.storage.claimModelAuthRefresh(binding)),
            .accepted => {},
        }
        Boundary.slot = &fixture.slot;
        Boundary.custody = &fixture.execution.custody;
        Boundary.token = token;
        Boundary.binding = binding;
        Boundary.used = &fixture.host.scratch_used;
        Boundary.response_fd = response.file.handle;
        Boundary.response_charge = response.charged;
        Boundary.closes = 0;
        Boundary.retirement_observed = false;
        Boundary.observing = true;
        defer Boundary.observing = false;
        completeTransfer(&fixture.run, &fixture.workspace, &fixture.slot, .{
            .transfer = &fixture.slot.provider.transfer,
            .outcome = .{ .transport_finished = .{ .disposition = .permanent_http, .http_status = 401 } },
            .queued_after = 0,
        });
        Boundary.observing = false;
        try std.testing.expectEqual(@as(usize, 1), Boundary.closes);
        try std.testing.expect(std.c.fcntl(Boundary.response_fd, std.c.F.GETFD) < 0);
        try std.testing.expectEqual(@as(u64, 17), fixture.host.scratch_used.load(.acquire));
        try std.testing.expectEqual(kind != .accepted, Boundary.retirement_observed);
        try std.testing.expectEqual(kind != .unreadable_store, fixture.host.lifecycle.launchAllowed());
        if (kind == .accepted) {
            try std.testing.expect(fixture.slot == .model_refreshing);
            try fixture.execution.custody.checkAttached(token, .{ .model = binding });
            try std.testing.expectEqual(@as(usize, 1), fixture.execution.custody.occupied());
            try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND auth_refresh_claimed=1 AND last_failure_code IS NULL AND resolution_code IS NULL", .{binding.operation_id}));
            finishCustodyNow(&fixture.run, &fixture.slot);
        } else {
            try std.testing.expect(fixture.slot == .free);
            if (kind == .declined) try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND auth_refresh_claimed=1 AND last_failure_code IS NULL AND resolution_code='provider_http_401'", .{binding.operation_id}));
            if (kind == .superseded) try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND auth_refresh_claimed=0 AND last_failure_code IS NULL AND interrupted_by_command_key='refresh-custody-stop'", .{binding.operation_id}));
        }
        try fixture.execution.custody.checkFree(token);
        try std.testing.expectEqual(@as(usize, 0), fixture.execution.custody.occupied());
        const reused = fixture.execution.custody.reserve().?;
        try fixture.execution.custody.releaseUnused(reused);
    }
}

test "cleanup publication follows complete execution retirement" {
    const Boundary = struct {
        slot: *const ExecutionSlot = undefined,
        custody: *execution.CustodyPool = undefined,
        token: execution.CustodyToken = undefined,
        observed: bool = false,
        release_expected: bool = false,
        releases: usize = 0,

        fn now(context: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.release_expected) {
                std.debug.assert(self.slot.* == .bash);
                self.custody.checkDetached(self.token, null) catch unreachable;
                self.release_expected = false;
                self.releases += 1;
                return clock.now(std.testing.io);
            }
            std.debug.assert(self.slot.* == .free);
            self.custody.checkFree(self.token) catch unreachable;
            checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(self.slot))[0..1], self.custody, null) catch unreachable;
            self.observed = true;
            return clock.now(std.testing.io);
        }
    };
    var boundary: Boundary = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Boundary.now;
    var records: [1]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = .{ .userdata = &boundary, .vtable = &vtable },
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    host_parts.probes.hooks = .{ .phase_trace = true };
    var slot: ExecutionSlot = .free;
    boundary.slot = &slot;
    boundary.custody = &execution_state.custody;
    for (0..2) |kind| {
        const token = execution_state.custody.reserve().?;
        boundary.token = token;
        boundary.observed = false;
        if (kind == 0) {
            var permit = store_module.DispatchPermit{ .binding = .{
                .turn_id = 3,
                .operation_id = 7,
                .attempt_ordinal = 2,
            } };
            _ = try attachSlot(&run, &slot, token, &permit);
            try std.testing.expect(slot == .model_preparing);
            finishCustodyNow(&run, &slot);
        } else {
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 3,
                .parent_operation_id = 7,
                .action_id = 11,
            } };
            slot = .{ .bash_preparing = .{ .attempt = try testBashAttempt(&host, &execution_state.custody, token, &permit) } };
            try std.testing.expect(slot == .bash_preparing);
            try std.testing.expect(execution_state.custody.claimTerminalDelivery(token));
            finishCustodyNow(&run, &slot);
        }
        try std.testing.expect(boundary.observed);
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    const arguments = "{\"description\":\"Print test marker\",\"cmd\":\"printf x\",\"timeout_ms\":1000}";
    const content = try store_module.testingPublicProjection(&storage, &tmp, &.{.{
        .encoded = "{\\\"description\\\":\\\"Print test marker\\\",\\\"cmd\\\":\\\"printf x\\\",\\\"timeout_ms\\\":1000}",
        .decoded = arguments,
    }});
    const arguments_location = try storage.openPublicConversationContent(&content);
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(root);
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 4096 };
    var entries: [2]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    host.retention = &retention;
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    host.lease = &lease;
    var scratch = bashScratch(&run);
    scratch.io = std.testing.io;
    var input: store_module.ActionExecutionInput = .{
        .binding = .{ .action_id = 11, .parent_operation_id = 1, .turn_id = 1 },
        .session = .{},
        .sender_handle = .{},
        .runner = .{ .bash = .{ .workspace = workspace } },
        .arguments = .{ .length = arguments.len, .digest = undefined },
        .timeout_ms = 1000,
    };
    try input.session.set("k7m2qx");
    const work = try pages.Mapped(struct { preparation: bash.Preparation, prepared: bash.Prepared }).map();
    defer work.unmap();
    const preparation = &work.value.preparation;
    if (preparation.start(scratch, std.testing.allocator, arguments_location, &input, root, default_bash_path, 11, .{})) |initial| {
        var failure = initial;
        try failure.cleanup.cleanup(scratch);
        return failure.cause;
    }
    var preparation_owned = true;
    defer if (preparation_owned) {
        var cleanup = preparation.cancel();
        cleanup.cleanup(scratch) catch unreachable;
    };
    const prepared = &work.value.prepared;
    while (true) {
        var progress = preparation.advance(prepared);
        switch (progress) {
            .pending => {},
            .prepared => {
                preparation_owned = false;
                break;
            },
            .failed => |*failure| {
                preparation_owned = false;
                try failure.cleanup.cleanup(scratch);
                return failure.cause;
            },
        }
    }
    defer prepared.cleanup() catch unreachable;
    const token = execution_state.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 3,
        .parent_operation_id = 7,
        .action_id = 11,
    } };
    const binding = try execution_state.custody.attach(token, &permit);
    try execution_state.custody.detach(token);
    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{
        .raw = .fromSeconds(5),
        .clock = .awake,
    });
    var refused: bash.ArgumentSizes = .{};
    var bash_execution = try prepared.launch(bash.default_facts, null, null, &refused);
    slot = .{ .bash = .{ .attempt = testAttempt(&host, &execution_state.custody, token, binding), .execution = &bash_execution, .delivery = .{ .closed = .{ .closing = .{ .custody = &execution_state.custody, .token = token }, .reclaim_at = deadline } } } };
    var window: [bash.copy_window_bytes]u8 = undefined;
    const service = .{ .execution = slot.bash.execution, .scratch = scratch, .window = &window };
    defer if (slot == .bash) {
        slot.bash.execution.requestInfrastructureShutdown(.now(std.testing.io, .awake));
        test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(5)), service, bash_service.retired) catch unreachable;
        slot.bash.execution.reclaim(scratch, &retention) catch unreachable;
    };
    try test_poll.waitUntil(std.testing.io, deadline, service, bash_service.retired);
    try slot.bash.execution.checkRetired();
    try std.testing.expectEqual(store_module.ActionResolutionCode.succeeded, slot.bash.execution.resultCode(scratch));
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    boundary.token = token;
    boundary.observed = false;
    var gate_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    host.probes.hooks.bash_reclaim_gate_path = try std.fmt.bufPrint(&gate_path_buffer, "{s}/released-gate", .{root});
    slot.bash.execution.stdout_capture.cleanup_fault = .persistent;
    boundary.release_expected = true;
    try std.testing.expect(reclaimBash(&run, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expect(!boundary.observed);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(&slot))[0..1], &execution_state.custody, null);
    try std.testing.expect(!reclaimBash(&run, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try execution_state.custody.checkDetached(token, .{ .action = binding });
    slot.bash.execution.stdout_capture.cleanup_fault = .none;
    try std.testing.expect(reclaimBash(&run, &slot, deadline));
    try std.testing.expect(boundary.observed);
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "Bash releases both spills after lost custody or fenced settlement" {
    // EXR-54
    const Completion = struct {
        state: *Run,
        slot: *ExecutionSlot,
        fn run(self: *@This()) void {
            completeBash(self.state, self.slot);
        }
    };
    for ([_]enum { lost, fenced }{ .lost, .fenced }) |outcome| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store_module.Store = undefined;
        try store_module.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{});
        defer storage.close() catch unreachable;
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var command = try store_module.testingCompleteConfiguration("bash-spill-config", "", root, "model-a");
        command.configuration.tools = try .of(&.{"bash"});
        command.configuration.permission_mode.state = .value;
        try command.configuration.permission_mode.value.set("bypass");
        const configured = try storage.configure(&command, .{});
        try std.testing.expect(configured == .accepted);
        const session = configured.accepted.session;
        try store_module.testingSubmitMessage(&storage, &tmp, "bash-spill-message", "bash-spill-message", session.slice(), "run");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const arguments = "{\"description\":\"Write both streams\",\"cmd\":\"printf '%024000d' 0; printf '%024000d' 0 >&2\",\"timeout_ms\":10000}";
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
        defer std.testing.allocator.free(encoded);
        try store_module.settleCallsForTesting(&storage, &tmp, model, "bash-spill-calls", &.{.{
            .item_id = "item-1",
            .name = "bash",
            .encoded_call_id = "call-1",
            .decoded_call_id = "call-1",
            .encoded_arguments = encoded[1 .. encoded.len - 1],
            .decoded_arguments = arguments,
        }});
        var admission = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 10_000, .{})).?;
        var records: [1]execution.CustodyRecord = @splat(.{});
        var lease: platform.StoreLease = undefined;
        lease.paths = .{};
        try lease.paths.scratch.set(root);
        var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, &lease);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        var entries: [2]output_retention.Entry = @splat(.{});
        var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &host.scratch_used, .limit = 1024 * 1024 }, &entries);
        defer retention.cleanupAll();
        host.retention = &retention;
        const token = execution_state.custody.reserve().?;
        var slot: ExecutionSlot = .free;
        slot = .{ .bash_preparing = .{ .attempt = try testBashAttempt(&host, &execution_state.custody, token, &admission.permit) } };
        const binding = slot.bash_preparing.attempt.binding;
        var input: store_module.ActionExecutionInput = undefined;
        try storage.readActionExecutionInput(.bash, binding, &input);
        const arguments_location = try storage.openContent(input.arguments);
        const scratch = bashScratch(&run);
        const work = try pages.Mapped(struct { preparation: bash.Preparation, prepared: bash.Prepared }).map();
        defer work.unmap();
        const preparation = &work.value.preparation;
        if (preparation.start(scratch, std.testing.allocator, arguments_location, &input, root, default_bash_path, binding.action_id, .{})) |initial| {
            var failure = initial;
            try failure.cleanup.cleanup(scratch);
            return failure.cause;
        }
        var preparation_owned = true;
        defer if (preparation_owned) {
            var cleanup = preparation.cancel();
            cleanup.cleanup(scratch) catch unreachable;
        };
        const prepared = &work.value.prepared;
        while (true) {
            var progress = preparation.advance(prepared);
            switch (progress) {
                .pending => {},
                .prepared => {
                    preparation_owned = false;
                    break;
                },
                .failed => |*failure| {
                    preparation_owned = false;
                    try failure.cleanup.cleanup(scratch);
                    return failure.cause;
                },
            }
        }
        defer prepared.cleanup() catch unreachable;
        var refused: bash.ArgumentSizes = .{};
        var bash_execution = try prepared.launch(bash.default_facts, null, null, &refused);
        moveSlot(&run, &slot, .bash, .{ .attempt = slot.bash_preparing.attempt, .execution = &bash_execution });
        var window: [bash.copy_window_bytes]u8 = undefined;
        const service = .{ .execution = &bash_execution, .scratch = scratch, .window = &window };
        defer if (slot == .bash) {
            bash_execution.requestInfrastructureShutdown(.now(std.testing.io, .awake));
            test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(5)), service, bash_service.retired) catch unreachable;
            bash_execution.reclaim(scratch, &retention) catch unreachable;
        };
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), service, bash_service.retired);
        try bash_execution.checkRetired();
        try std.testing.expectEqual(store_module.ActionResolutionCode.succeeded, bash_execution.resultCode(scratch));
        const stdout_name = bash_execution.stdout_capture.name;
        const stderr_name = bash_execution.stderr_capture.name;
        const bytes = try std.testing.allocator.alloc(u8, 24_000);
        defer std.testing.allocator.free(bytes);
        for ([_]protocol.Bounded(96){ stdout_name, stderr_name }) |name| {
            const file = try tmp.dir.openFile(std.testing.io, name.slice(), .{});
            defer file.close(std.testing.io);
            try std.testing.expectEqual(@as(usize, 24_000), try file.readPositionalAll(std.testing.io, bytes, 0));
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, '0'), byte);
        }
        try std.testing.expectEqual(@as(u64, 48_000), host.scratch_used.load(.acquire));
        if (outcome == .lost) {
            try std.testing.expectEqual(action_attempt.Delivered.delivered, slot.bash.attempt.settle(.{ .text = .{ .code = .succeeded, .text = "prior result" } }));
        } else host.probes.arm(.result_before_commit);

        var owner = test_pause.PauseController.init(std.testing.io, std.heap.c_allocator);
        defer owner.deinit();
        try owner.arm(.{ .point = .action_result_ready });
        host.probes.pause_owner = &owner;
        var completion: Completion = .{ .state = &run, .slot = &slot };
        const thread = try std.Thread.spawn(.{}, Completion.run, .{&completion});
        var joined = false;
        defer {
            owner.close();
            if (!joined) thread.join();
        }
        const arrival = try owner.wait(.{ .point = .action_result_ready });
        try std.testing.expectEqual(@as(usize, 2), retention.occupied());
        try std.testing.expectEqual(@as(u64, 48_000), host.scratch_used.load(.acquire));
        for ([_]protocol.Bounded(96){ stdout_name, stderr_name }) |name| {
            const stat = try tmp.dir.statFile(std.testing.io, name.slice(), .{});
            try std.testing.expectEqual(@as(u64, 24_000), stat.size);
            var reserved = false;
            for (retention.entries) |entry| {
                if (entry.state == .reserved and std.mem.eql(u8, entry.name.slice(), name.slice())) reserved = true;
            }
            try std.testing.expect(reserved);
        }
        try owner.release(arrival.id, .proceed);
        thread.join();
        joined = true;
        host.probes.pause_owner = null;
        try std.testing.expect(slot == .bash and slot.bash.delivery == .closed);
        try execution_state.custody.checkDetached(token, .{ .action = binding });
        try std.testing.expectEqual(outcome == .lost, host.lifecycle.launchAllowed());
        try std.testing.expectEqual(@as(usize, 0), retention.occupied());
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, stdout_name.slice(), .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, stderr_name.slice(), .{}));
        try std.testing.expect(reclaimBash(&run, &slot, .now(std.testing.io, .awake)));
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
        try storage.close();
        try store_module.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{});
        const resolved = try store_module.testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='succeeded'", .{binding.action_id});
        try std.testing.expectEqual(@as(u64, if (outcome == .lost) 1 else 0), resolved);
        const unresolved = try store_module.testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{binding.action_id});
        try std.testing.expectEqual(@as(u64, if (outcome == .fenced) 1 else 0), unresolved);
        if (outcome == .lost) {
            const report = try store_module.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            try std.testing.expect(std.mem.indexOf(u8, report, "prior result") != null);
        }
    }
}

test "named scratch retry releases custody through the shutdown owner path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const scratch_path_length = try tmp.dir.realPath(std.testing.io, &scratch_path_buffer);
    var paths: platform.Paths = .{};
    try paths.scratch.set(scratch_path_buffer[0..scratch_path_length]);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var scratch = try std.Io.Dir.cwd().openDir(std.testing.io, lease.paths.scratch.slice(), .{});
    defer scratch.close(std.testing.io);
    const primary = try scratch.createFile(std.testing.io, "named-owner.tmp", .{ .read = true });
    const secondary = try scratch.openFile(std.testing.io, "named-owner.tmp", .{});
    var scratch_used: std.atomic.Value(u64) = .init(9);
    var removal_gate: std.atomic.Value(bool) = .init(true);
    var records: [1]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    const token = execution_state.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try execution_state.custody.attach(token, &permit);
    const owner = ModelPreparingSlot{ .token = token, .binding = binding };
    var slots = [_]ExecutionSlot{.{ .model_preparing = owner }};
    finishModelPreparationFailure(
        &run,
        &slots[0],
        owner,
        error.InjectedScratchRemovalFailure,
        .init(
            std.testing.io,
            primary,
            secondary,
            "named-owner.tmp",
            .{ .used = &scratch_used, .limit = 9 },
            9,
            .{ .gated = &removal_gate },
        ),
    );
    try std.testing.expect(slots[0] == .named_scratch);
    try std.testing.expect(!host.lifecycle.launchAllowed());
    try execution_state.custody.checkDetached(token, .{ .model = binding });

    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = now;
    try std.testing.expect(!advanceRetainedCleanup(&run, &slots, now, &retry_at));
    try std.testing.expectEqual(@as(usize, 1), execution_state.custody.occupied());
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-owner.tmp", .{});

    const workspace = try pages.Mapped(Workspace).map();
    defer workspace.unmap();
    const shutdown = try std.Thread.spawn(
        .{},
        shutdownExecution,
        .{ &run, slots[0..], workspace.value },
    );
    removal_gate.store(false, .release);
    shutdown.join();

    try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-owner.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&run, &slots, now, &retry_at));
}

test "execution slots agree with custody across the complete population" {
    var records: [2]execution.CustodyRecord = @splat(.{});
    var custody = execution.CustodyPool.initialize(&records);

    var model_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const model_token = custody.reserve().?;
    const model_binding = try custody.attach(model_token, &model_permit);
    var action_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 2,
    } };
    const action_token = custody.reserve().?;
    const action_binding = try custody.attach(action_token, &action_permit);

    var slots = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .{ .bash = .{
            .attempt = .{ .parts = undefined, .token = action_token, .labels = undefined, .binding = action_binding },
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody, null);

    slots[0] = .{ .provider = .{ .owner = .{
        .token = model_token,
        .binding = .{ .turn_id = 9, .operation_id = 9, .attempt_ordinal = 9 },
    } } };
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody, null));
    slots[0] = .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } };
    try checkSlotCustodyAgreement(&slots, &custody, null);

    var orphan = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .free,
    };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody, null));
    try custody.detach(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody, null));
    var empty = [_]ExecutionSlot{ .free, .free };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody, null));
    try custody.cleanupComplete(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody, null));
    try custody.detach(model_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody, null));
    try custody.cleanupComplete(model_token);
    try checkSlotCustodyAgreement(&empty, &custody, null);

    const retoken = custody.reserve().?;
    var repermit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 3,
        .operation_id = 3,
        .attempt_ordinal = 1,
    } };
    const rebinding = try custody.attach(retoken, &repermit);
    var shared = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
    };
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&shared, &custody, null));

    try custody.detach(retoken);
    try custody.cleanupComplete(retoken);
    const reused = custody.reserve().?;
    var reused_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    const reused_binding = try custody.attach(reused, &reused_permit);
    var stale = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
    };
    try std.testing.expectError(error.StaleCustody, checkSlotCustodyAgreement(&stale, &custody, null));
    var current = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = reused, .binding = reused_binding } } },
    };
    try checkSlotCustodyAgreement(&current, &custody, null);
    try custody.detach(reused);
    try custody.cleanupComplete(reused);
}

test "compound admission preflight releases transient custody and cancels its readers" {
    const Exit = enum { admit, control, pause, fence, shutdown };
    for (std.enums.values(Exit)) |exit| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
        var storage: store_module.Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        const session = try store_module.testing.configureTestSession(&storage, "preflight-config");
        try store_module.testing.answerTestTurn(&storage, &tmp, session.slice(), "preflight-prior", &.{.{ .encoded = "prior", .decoded = "prior" }});
        try store_module.testing.submitTestMessageParts(&storage, &tmp, "preflight-parts", session.slice(), &.{
            .{ .bytes = "next" },
            .{ .bytes = @embedFile("testing/fixtures/input-baseline.jpg"), .kind = .{ .image = .{ .assertion = .jpeg } } },
        });
        var paths: platform.Paths = .{};
        try paths.scratch.set(root);
        var lease = platform.StoreLease{
            .io = std.testing.io,
            .paths = paths,
            .store_dir = undefined,
            .lock_file = undefined,
        };
        var records: [1]execution.CustodyRecord = @splat(.{});
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = &lease,
            .store = &storage,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, &lease);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        run.scratch_budget = .{ .used = &host.scratch_used, .limit = 1024 * 1024 };
        const mapped = try pages.Mapped(Workspace).map();
        defer mapped.unmap();
        const workspace = mapped.value;
        workspace.model_admission.init();
        defer workspace.model_admission.deinit();
        var slots = [_]ExecutionSlot{.free};
        defer if (slots[0] == .model_preparing) {
            workspace.model_preparation.cancel();
            finishCustodyNow(&run, &slots[0]);
        };
        var measurement: LifecycleMeasurement = .{};
        var mcp: server_mcp.Calls = .{};
        var native = NativeTurn{
            .run = &run,
            .reactor = null,
            .slots = &slots,
            .workspace = workspace,
            .measurement = &measurement,
            .mcp = &mcp,
            .attempts = .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &execution_state.custody },
            .fenced = false,
        };
        const generation = storage.commitGeneration();
        try std.testing.expectEqual(execution_turn.Admission.progress, native.admitNewModel(false));
        try std.testing.expectEqual(execution_turn.PendingModelAdmission.message, native.pendingModelAdmission().?);
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
        try std.testing.expect(slots[0] == .free);
        try std.testing.expectEqual(generation, storage.commitGeneration());
        try std.testing.expectEqual(execution_turn.Admission.no_work, native.admitRetry());
        try std.testing.expectEqual(execution_turn.Admission.no_work, native.admitToolContinuation());

        // Fill ordinary custody independently: preflight must still advance,
        // and no model Attempt or request may exist until its final commit.
        const held = execution_state.custody.reserve().?;
        var held_owned = true;
        defer if (held_owned) execution_state.custody.releaseUnused(held) catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), native.freeSlots());
        var reads: usize = 0;
        while (workspace.model_admission.read.cursor == null) : (reads += 1) {
            try std.testing.expect(reads < 256);
            try std.testing.expect(native.advanceModelAdmission());
            try std.testing.expect(workspace.model_admission.pending());
            try std.testing.expectEqual(@as(usize, 1), execution_state.custody.occupied());
            try std.testing.expectEqual(generation, storage.commitGeneration());
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        }
        try execution_state.custody.releaseUnused(held);
        held_owned = false;

        switch (exit) {
            .admit => {
                var steps: usize = 0;
                while (!workspace.model_admission.pendingReady()) : (steps += 1) {
                    try std.testing.expect(steps < 256);
                    try std.testing.expect(native.advanceModelAdmission());
                    try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
                    try std.testing.expect(slots[0] == .free);
                    try std.testing.expectEqual(generation, storage.commitGeneration());
                }
                try std.testing.expect(!native.advanceModelAdmission());
                try std.testing.expectEqual(execution_turn.Admission.admitted, native.admitNewModel(false));
                try std.testing.expect(native.pendingModelAdmission() == null);
                try std.testing.expect(slots[0] == .model_preparing);
                try std.testing.expect(workspace.model_preparation.state.active);
                try std.testing.expectEqual(@as(usize, 1), execution_state.custody.occupied());
                try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
            },
            .control => native.reconcileControls(),
            .pause => {
                host.lifecycle.setTurnsPaused(true);
                try std.testing.expect(native.advanceModelAdmission());
            },
            .fence => {
                _ = host.lifecycle.advance(.fenced);
                try std.testing.expect(native.advanceModelAdmission());
            },
            .shutdown => shutdownExecution(&run, &slots, workspace),
        }
        if (exit != .admit) {
            try std.testing.expect(native.pendingModelAdmission() == null);
            try std.testing.expect(workspace.model_admission.read.cursor == null);
            try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
            try std.testing.expect(slots[0] == .free);
            try std.testing.expectEqual(generation, storage.commitGeneration());
        }
    }
}

test "no-work admission restores only its temporary custody reservation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;

    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var records: [3]execution.CustodyRecord = @splat(.{});
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
            };
            var host_parts: TestParts = undefined;
            host_parts.attach(&host, undefined);
            var execution_state: execution_owner.Execution = undefined;
            execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
            var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) execution_state.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try execution_state.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                execution_state.custody.detach(token) catch unreachable;
                execution_state.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var admission_preparation: store_module.ModelAdmissionPreparation = undefined;
            admission_preparation.init();
            defer admission_preparation.deinit();
            const workspace = try pages.Mapped(Workspace).map();
            defer workspace.unmap();
            var retry_scanned = false;
            var retry_due_ms: ?u64 = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&run, .{ .store = host.store, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &execution_state.custody }, &slots[0], workspace.value),
                .retry => admitRetryAttempt(&run, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation, &retry_scanned, &retry_due_ms),
                .message => admitNewAttempt(&run, &slots[0], .message, &model_preparation, &admission_preparation),
                .tool_continuation => admitNewAttempt(&run, &slots[0], .tool_continuation, &model_preparation, &admission_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.no_work, progress);
            try std.testing.expect(slots[0] == .free);
            try std.testing.expect(host.lifecycle.launchAllowed());
            try std.testing.expectEqual(baseline, execution_state.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
            try std.testing.expect(!(try storage.inspectSessionForTesting("direct/no-work")).found);

            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = execution_state.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(execution_state.custody.reserve() == null);
            for (reused[0..free]) |token| try execution_state.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, execution_state.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
        }
    }
}

test "failed admission releases its reservation and fences the Store and dispatch" {
    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var root_buffer: [protocol.max_store_bytes]u8 = undefined;
            const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
            var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
            const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
            var storage: store_module.Store = undefined;
            try storage.open(std.testing.io, database, root);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
            defer directory.close(std.testing.io);
            const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
            var command: wire_request.ConfigureCommand = .{};
            try command.key.set("failed-admission-config");
            command.configuration.workspace.state = .value;
            try command.configuration.workspace.value.set(workspace);
            command.configuration.provider.state = .value;
            try command.configuration.provider.value.set("codex");
            command.configuration.model.state = .value;
            try command.configuration.model.value.set("model-a");
            command.configuration.tools = try .of(&.{ "bash", "web_search" });
            command.configuration.permission_mode.state = .value;
            try command.configuration.permission_mode.value.set("bypass");
            command.configuration.compaction_trigger.state = .value;
            try command.configuration.compaction_trigger.value.set("115200");
            command.configuration.reasoning_effort.state = .explicit_null;
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const file = try tmp.dir.createFile(std.testing.io, "failed-admission-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "hello");
            try file.sync(std.testing.io);
            var message: wire_request.MessageCommand = .{};
            try message.key.set("failed-admission-key");
            message.session = configured.accepted.session;
            message.text = .{
                .state = .value,
                .file = file,
                .length = 5,
                .digest = protocol.contentDigest("hello"),
            };
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
            if (kind != .message) {
                try std.testing.expectError(
                    error.InjectedAttemptCommitFailure,
                    storage.admitModelAttempt(.message, .{ .attempt_before_commit = true }),
                );
                try std.testing.expect(storage.isFenced());
            }

            var records: [3]execution.CustodyRecord = @splat(.{});
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
            };
            var host_parts: TestParts = undefined;
            host_parts.attach(&host, undefined);
            var execution_state: execution_owner.Execution = undefined;
            execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
            var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
            host_parts.probes.hooks = .{ .failures = if (kind == .message) .initOne(.attempt_before_commit) else .empty };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) execution_state.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try execution_state.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                execution_state.custody.detach(token) catch unreachable;
                execution_state.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var admission_preparation: store_module.ModelAdmissionPreparation = undefined;
            admission_preparation.init();
            defer admission_preparation.deinit();
            const engine_workspace = try pages.Mapped(Workspace).map();
            defer engine_workspace.unmap();
            var retry_scanned = false;
            var retry_due_ms: ?u64 = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&run, .{ .store = host.store, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &execution_state.custody }, &slots[0], engine_workspace.value),
                .retry => admitRetryAttempt(&run, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation, &retry_scanned, &retry_due_ms),
                .message => admitNewAttempt(&run, &slots[0], .message, &model_preparation, &admission_preparation),
                .tool_continuation => admitNewAttempt(&run, &slots[0], .tool_continuation, &model_preparation, &admission_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.retry_later, progress);
            try std.testing.expect(storage.isFenced());
            try std.testing.expect(!host.lifecycle.launchAllowed());
            try std.testing.expect(slots[0] == .free);
            try std.testing.expectEqual(baseline, execution_state.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);

            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = execution_state.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(execution_state.custody.reserve() == null);
            for (reused[0..free]) |token| try execution_state.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, execution_state.custody.occupied());
        }
    }
}

test "closed Bash delivery retains its payload with detached custody" {
    var records: [2]execution.CustodyRecord = @splat(.{});
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = .{},
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    const token = execution_state.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 2,
    } };
    const binding = try execution_state.custody.attach(token, &permit);
    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .attempt = testAttempt(&host, &execution_state.custody, token, binding),
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);

    try std.testing.expect(execution_state.custody.claimTerminalDelivery(token));
    closeBashDelivery(&run, &slots[0]);
    try std.testing.expect(slots[0].bash.delivery == .closed);
    try execution_state.custody.checkDetached(token, .{ .action = binding });
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
    slots[0].bash.delivery.closed.reclaim_failed = true;
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);

    const second = execution_state.custody.reserve().?;
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 4,
        .parent_operation_id = 4,
        .action_id = 5,
    } };
    const second_binding = try execution_state.custody.attach(second, &second_permit);
    const bad = [_]ExecutionSlot{
        .{ .bash = .{
            .attempt = .{ .parts = undefined, .token = second, .labels = undefined, .binding = second_binding },
            .execution = undefined,
            .delivery = .{ .closed = .{
                .closing = .{ .custody = &execution_state.custody, .token = second },
                .reclaim_at = std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            } },
        } },
        .free,
    };
    var both = [_]ExecutionSlot{ slots[0], bad[0] };
    try std.testing.expectError(error.InvalidCustodyTransition, checkSlotCustodyAgreement(&both, &execution_state.custody, null));
    try execution_state.custody.detach(second);
    try execution_state.custody.cleanupComplete(second);
    try execution_state.custody.cleanupComplete(token);
    slots[0] = .free;
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
}

test "closed Bash payloads keep their typed binding identity" {
    var records: [2]execution.CustodyRecord = @splat(.{});
    var custody = execution.CustodyPool.initialize(&records);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);

    var first_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 1,
    } };
    const first_token = custody.reserve().?;
    const first_binding = try custody.attach(first_token, &first_permit);
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 2,
        .parent_operation_id = 2,
        .action_id = 2,
    } };
    const second_token = custody.reserve().?;
    const second_binding = try custody.attach(second_token, &second_permit);
    try custody.detach(first_token);
    try custody.detach(second_token);

    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .attempt = .{ .parts = undefined, .token = first_token, .labels = undefined, .binding = first_binding },
            .execution = undefined,
            .delivery = .{ .closed = .{ .closing = .{ .custody = &custody, .token = first_token }, .reclaim_at = now } },
        } },
        .{ .bash = .{
            .attempt = .{ .parts = undefined, .token = second_token, .labels = undefined, .binding = second_binding },
            .execution = undefined,
            .delivery = .{ .closed = .{ .closing = .{ .custody = &custody, .token = second_token }, .reclaim_at = now } },
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody, null);

    slots[0].bash.attempt.token = second_token;
    slots[1].bash.attempt.token = first_token;
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody, null));
    slots[0].bash.attempt.token = first_token;
    slots[1].bash.attempt.token = second_token;
    try checkSlotCustodyAgreement(&slots, &custody, null);
    try custody.cleanupComplete(first_token);
    try custody.cleanupComplete(second_token);
}

test "preparing slots belong to their live preparations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
    var command: wire_request.ConfigureCommand = .{};
    try command.key.set("prep-belong-config");
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set("model-a");
    command.configuration.tools = try .of(&.{ "bash", "web_search" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    command.configuration.compaction_trigger.state = .value;
    try command.configuration.compaction_trigger.value.set("115200");
    command.configuration.reasoning_effort.state = .explicit_null;
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "prep-belong-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "hello");
    try file.sync(std.testing.io);
    var message: wire_request.MessageCommand = .{};
    try message.key.set("prep-belong-key");
    message.session = configured.accepted.session;
    message.text = .{
        .state = .value,
        .file = file,
        .length = 5,
        .digest = protocol.contentDigest("hello"),
    };
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding_a = try admitted.permit.consume();

    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: model_adapter.Preparation = undefined;
    preparation.page.open(binding_a);
    try preparation.init(std.testing.io, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, protocol.servedBuiltIns(.endpoint), null, .{}, &retained);
    var preparation_active = true;
    defer if (preparation_active) preparation.cancel();

    var records: [1]execution.CustodyRecord = @splat(.{});
    var custody = execution.CustodyPool.initialize(&records);
    const token = custody.reserve().?;
    var permit_b = store_module.DispatchPermit{ .binding = .{
        .turn_id = binding_a.turn_id + 100,
        .operation_id = binding_a.operation_id + 100,
        .attempt_ordinal = binding_a.attempt_ordinal,
    } };
    const binding_b = try custody.attach(token, &permit_b);
    var mismatched = [_]ExecutionSlot{
        .{ .model_preparing = .{ .token = token, .binding = binding_b } },
    };
    try checkSlotCustodyAgreement(&mismatched, &custody, null);
    try std.testing.expectError(error.PreparationBindingMismatch, checkSharedPreparation(&mismatched, &preparation, null));

    var matched = [_]ExecutionSlot{
        .{ .model_preparing = .{ .token = token, .binding = binding_a } },
    };
    try custody.detach(token);
    try custody.cleanupComplete(token);
    const retoken = custody.reserve().?;
    var permit_a = store_module.DispatchPermit{ .binding = binding_a };
    const attached_a = try custody.attach(retoken, &permit_a);
    matched[0] = .{ .model_preparing = .{ .token = retoken, .binding = attached_a } };
    try checkSlotCustodyAgreement(&matched, &custody, null);
    try checkSharedPreparation(&matched, &preparation, null);

    var empty = [_]ExecutionSlot{.free};
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&empty, &preparation, null));
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&matched, null, null));
    try checkSharedPreparation(&empty, null, null);

    var bash_preparation = bash.Preparation{
        .scratch = .{ .io = std.testing.io, .path = root, .budget = undefined },
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = root,
        .workspace = .{},
        .bash_path = default_bash_path,
        .timeout_ms = 1,
        .action_id = 7,
        .faults = .{},
        .source = undefined,
    };
    var bash_matched = [_]ExecutionSlot{
        .{ .bash_preparing = .{ .attempt = .{ .parts = undefined, .token = retoken, .labels = undefined, .binding = .{
            .turn_id = 1,
            .parent_operation_id = 1,
            .action_id = 7,
        } } } },
    };
    try checkSharedPreparation(&bash_matched, null, &bash_preparation);
    bash_matched[0].bash_preparing.attempt.binding.action_id = 8;
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&bash_matched, null, &bash_preparation));

    try custody.detach(retoken);
    try custody.cleanupComplete(retoken);
    preparation.cancel();
    preparation_active = false;
}

test "retained named scratch blocks its slot until the same owner reclaims" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const scratch_path_length = try tmp.dir.realPath(std.testing.io, &scratch_path_buffer);
    var paths: platform.Paths = .{};
    try paths.scratch.set(scratch_path_buffer[0..scratch_path_length]);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var scratch = try std.Io.Dir.cwd().openDir(std.testing.io, lease.paths.scratch.slice(), .{});
    defer scratch.close(std.testing.io);
    const primary = try scratch.createFile(std.testing.io, "named-direct.tmp", .{ .read = true });
    const secondary = try scratch.openFile(std.testing.io, "named-direct.tmp", .{});
    var scratch_used: std.atomic.Value(u64) = .init(9);
    var removal_gate: std.atomic.Value(bool) = .init(true);
    var records: [1]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    const token = execution_state.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try execution_state.custody.attach(token, &permit);
    try std.testing.expectEqual(@as(u64, 1), binding.operation_id);
    try execution_state.custody.detach(token);
    var slots = [_]ExecutionSlot{.{ .named_scratch = .{
        .token = token,
        .owner = .init(
            std.testing.io,
            primary,
            secondary,
            "named-direct.tmp",
            .{ .used = &scratch_used, .limit = 9 },
            9,
            .{ .gated = &removal_gate },
        ),
    } }};

    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = start;
    var reclaimed = false;
    errdefer if (!reclaimed) {
        removal_gate.store(false, .release);
        var retry = retry_at;
        _ = advanceRetainedCleanup(&run, &slots, retry, &retry);
    };
    try std.testing.expect(!advanceRetainedCleanup(&run, &slots, start, &retry_at));
    try execution_state.custody.checkDetached(token, null);
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
    try checkSharedPreparation(&slots, null, null);
    try std.testing.expectEqual(@as(usize, 1), execution_state.custody.occupied());
    try std.testing.expectEqual(@as(usize, 0), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-direct.tmp", .{});

    try std.testing.expect(!advanceRetainedCleanup(&run, &slots, start, &retry_at));

    removal_gate.store(false, .release);
    try std.testing.expect(advanceRetainedCleanup(&run, &slots, retry_at, &retry_at));
    reclaimed = true;
    try execution_state.custody.checkFree(token);
    try checkSlotCustodyAgreement(&slots, &execution_state.custody, null);
    try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    try std.testing.expectEqual(@as(usize, 1), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-direct.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&run, &slots, retry_at, &retry_at));
}

test "provider metadata uses shared scratch reclamation without widening its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const root_budget = ScratchBudget{ .used = &used, .limit = 104 };
    var entries: [2]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, root_budget, &entries);
    defer retention.cleanupAll();

    var stdout = output_retention.Spill.open(&retention, "stdout") orelse return error.TestUnexpectedResult;
    var stderr_file = output_retention.Spill.open(&retention, "stderr") orelse return error.TestUnexpectedResult;
    stdout.write("a");
    stderr_file.write("b");
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root,
        "metadata",
        retention.sharedBudget(),
        false,
        &retained_metadata,
    );
    try std.testing.expectError(
        error.MetadataScratchExhausted,
        metadata.append(&.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), retention.occupied());

    stdout.close();
    stderr_file.close();
    stdout.keep();
    stderr_file.keep();
    try metadata.append(&.{ .tag = .usage, .start = 0, .length = 0 });
    try std.testing.expectEqual(@as(u64, 104), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), retention.occupied());
    metadata.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

    var limited = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root,
        "limited-metadata",
        retention.sharedBudget().narrowed(103),
        false,
        &retained_metadata,
    );
    defer limited.deinit();
    try std.testing.expectError(
        error.MetadataScratchExhausted,
        limited.append(&.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "Host fences dispose admitted preparation without touching canonical state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    for ([_]server_host.Phase{ .fenced, .stopping }) |phase| {
        var records: [1]execution.CustodyRecord = @splat(.{});
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        const token = execution_state.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try execution_state.custody.attach(token, &permit);
        var preparation: model_adapter.Preparation = undefined;
        var retained: ?named_scratch.Owner = null;
        preparation.page = .{ .binding = binding };
        try preparation.init(
            std.testing.io,
            root,
            .{ .used = &host.scratch_used, .limit = 1024 },
            protocol.servedBuiltIns(.endpoint),
            null,
            .{},
            &retained,
        );
        try preparation.writer.write("partial request");
        var slots = [_]ExecutionSlot{.{ .model_preparing = .{
            .token = token,
            .binding = binding,
        } }};
        _ = host.lifecycle.advance(phase);
        var listings: std.EnumArray(provider.ListingKind, ListingWork) = .initFill(.{ .fetch = undefined, .credential = null, .response = null });
        try std.testing.expect(advanceModelPreparation(
            &run,
            null,
            &slots,
            &preparation,
            &listings,
            host.limits.request_preparation_byte_allowance,
            host.limits.request_preparation_item_allowance,
        ));
        try std.testing.expect(!preparation.state.active and !preparation.page.active);
        try std.testing.expect(slots[0] == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    }
}

test "an encode failure settles unanswered and releases request scratch" {
    const CountedEndpoint = struct {
        peer: *h2.testing.Peer,
        reactor: provider.Reactor,
        requests: usize,

        fn init(self: *@This(), root: []const u8, budget: ScratchBudget) !void {
            self.requests = 0;
            const Counter = @This();
            self.peer = try h2.testing.Peer.start(std.testing.allocator, .{
                .context = self,
                .on_request = struct {
                    fn received(peer: *h2.testing.Peer, stream: *h2.testing.Peer.Stream) void {
                        const counter: *Counter = @ptrCast(@alignCast(peer.options.context.?));
                        // Retain the observation before replying to either control.
                        counter.requests += 1;
                        peer.respond(stream, 200, "ok");
                    }
                }.received,
            });
            errdefer self.peer.stop();
            try self.reactor.initForTesting(std.testing.allocator, std.testing.io, .{
                .endpoints = .init(.{ .codex = self.peer.url(), .openai = null, .chatgpt = null }),
                .capacity = 1,
                .inactivity_seconds = 5,
                .scratch_path = root,
                .budget = budget,
            });
        }

        fn deinit(self: *@This()) void {
            self.reactor.deinit();
            self.peer.stop();
        }

        fn pump(self: *@This()) !void {
            try self.reactor.client.drive(&self.reactor);
            try self.peer.pump();
            try self.reactor.client.drive(&self.reactor);
        }

        fn positiveControl(self: *@This(), tmp: *std.testing.TmpDir) !void {
            const expected = self.requests + 1;
            const file = try tmp.dir.createFile(std.testing.io, "count-control", .{ .read = true });
            var file_owned = true;
            defer if (file_owned) file.close(std.testing.io);
            try tmp.dir.deleteFile(std.testing.io, "count-control");
            try file.writeStreamingAll(std.testing.io, "{}");
            try file.sync(std.testing.io);
            const budget = self.reactor.budget;
            try std.testing.expect(budget.allocate(2));
            var request = provider.PreparedRequest{
                .file = file,
                .length = 2,
                .charged = 2,
                .structured_output = false,
                .provider = .codex,
                .codec = .@"openai-responses/1",
                .headers = .{ .count = 0 },
            };
            file_owned = false;
            var request_owned = true;
            defer if (request_owned) request.deinit(std.testing.io, budget);
            var transfer: provider.Transfer = undefined;
            var retained: ?named_scratch.Owner = null;
            try transfer.start(&self.reactor, &request, .{
                .turn_id = 1,
                .operation_id = 9999,
                .attempt_ordinal = @intCast(expected),
            }, .{}, &retained);
            request_owned = false;
            defer transfer.deinit();
            self.reactor.launch(&transfer);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(5)), .{
                .counter = self,
                .expected = expected,
            }, struct {
                fn completed(context: anytype) !bool {
                    try context.counter.pump();
                    return context.counter.requests >= context.expected and context.counter.reactor.finishedCount() != 0;
                }
            }.completed);
            try std.testing.expectEqual(expected, self.requests);
            try std.testing.expectEqual(expected, self.peer.streams.items.len);
            try std.testing.expectEqualStrings("{}", self.peer.streams.items[expected - 1].body.items);
            try std.testing.expect(retained == null);
        }
    };
    for ([_]bool{ false, true }) |ordered_limit| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
        var storage: store_module.Store = undefined;
        try storage.open(std.testing.io, database, root);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
        defer directory.close(std.testing.io);
        const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
        var command: wire_request.ConfigureCommand = .{};
        try command.key.set("encode-failure-config");
        command.configuration.workspace.state = .value;
        try command.configuration.workspace.value.set(workspace);
        command.configuration.provider.state = .value;
        try command.configuration.provider.value.set("codex");
        command.configuration.model.state = .value;
        try command.configuration.model.value.set("model-a");
        command.configuration.tools = try .of(&.{ "bash", "web_search" });
        command.configuration.permission_mode.state = .value;
        try command.configuration.permission_mode.value.set("bypass");
        command.configuration.compaction_trigger.state = .value;
        try command.configuration.compaction_trigger.value.set("115200");
        command.configuration.reasoning_effort.state = .explicit_null;
        const configured = try storage.configure(&command, .{});
        try std.testing.expect(configured == .accepted);
        const file = try tmp.dir.createFile(std.testing.io, "encode-failure-message", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, "hello");
        try file.sync(std.testing.io);
        var message: wire_request.MessageCommand = .{};
        try message.key.set("encode-failure-key");
        message.session = configured.accepted.session;
        message.text = .{
            .state = .value,
            .file = file,
            .length = 5,
            .digest = protocol.contentDigest("hello"),
        };
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        if (ordered_limit) {
            const Capture = @import("InputCapture.zig");
            const image = @embedFile("testing/fixtures/input-baseline.jpg");
            // Each Message fits the canonical part bound; their selected history
            // exceeds the request-wide image limit by exactly one.
            for ([_]usize{ 1500, 1 }, 0..) |image_count, ordinal| {
                const files = files: {
                    const spool = try tmp.dir.createFile(std.testing.io, "limit-spool", .{ .read = true });
                    errdefer spool.close(std.testing.io);
                    try tmp.dir.deleteFile(std.testing.io, "limit-spool");
                    const index = try tmp.dir.createFile(std.testing.io, "limit-index", .{ .read = true });
                    errdefer index.close(std.testing.io);
                    try tmp.dir.deleteFile(std.testing.io, "limit-index");
                    break :files .{ .spool = spool, .index = index };
                };
                var capture_used: std.atomic.Value(u64) = .init(0);
                var capture: Capture = undefined;
                capture.init(std.testing.io, files.spool, files.index, .{ .used = &capture_used, .limit = 2 * 1024 * 1024 });
                defer capture.close();
                for (0..image_count) |_| {
                    try capture.begin(.{ .image = .{ .assertion = .jpeg } }, image.len);
                    var allowance: usize = image.len;
                    try std.testing.expectEqual(image.len, try capture.append(image, &allowance, false));
                    try capture.end();
                }
                const loan = try capture.seal();
                var ordered_message: wire_request.MessageCommand = .{};
                try ordered_message.key.set(if (ordinal == 0) "encode-failure-key" else "encode-failure-over-limit");
                ordered_message.session = configured.accepted.session;
                try std.testing.expect((try storage.submitMessageParts(&ordered_message, loan, null, .{})) == .accepted);
                capture.close();
                try std.testing.expectEqual(@as(u64, 0), capture_used.load(.acquire));
            }
        } else try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        var admitted = (try storage.admitNextModelAttempt(.{})).?;

        var paths: platform.Paths = .{};
        try paths.scratch.set(root);
        var lease = platform.StoreLease{
            .io = std.testing.io,
            .paths = paths,
            .store_dir = undefined,
            .lock_file = undefined,
        };
        var records: [1]execution.CustodyRecord = @splat(.{});
        var served: providers.Providers = .{};
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = &lease,
            .store = &storage,
            .providers = &served,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, &lease);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        run.scratch_budget = .{ .used = &host.scratch_used, .limit = if (ordered_limit) 2 * 1024 * 1024 else 1024 * 1024 };
        var counted: CountedEndpoint = undefined;
        if (ordered_limit) {
            try counted.init(root, run.scratch_budget.?);
            served.table.set(.codex, .{ .endpoint = counted.peer.url(), .credential = .none });
        }
        defer if (ordered_limit) counted.deinit();
        if (ordered_limit) {
            try counted.positiveControl(&tmp);
            try std.testing.expectEqual(@as(usize, 1), counted.requests);
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        }
        const token = execution_state.custody.reserve().?;
        const binding = try execution_state.custody.attach(token, &admitted.permit);
        var slots = [_]ExecutionSlot{.{ .model_preparing = .{ .token = token, .binding = binding } }};
        var preparation: model_adapter.Preparation = undefined;
        var retained: ?named_scratch.Owner = null;
        preparation.page.open(binding);
        try preparation.init(
            std.testing.io,
            root,
            .{ .used = &host.scratch_used, .limit = if (ordered_limit) 2 * 1024 * 1024 else 1024 * 1024 },
            protocol.servedBuiltIns(.endpoint),
            null,
            if (ordered_limit) .{} else .{ .codec_declines = .request_end },
            &retained,
        );
        defer if (preparation.state.active) preparation.cancel();
        var listings: std.EnumArray(provider.ListingKind, ListingWork) = .initFill(.{ .fetch = undefined, .credential = null, .response = null });
        // The ordered-input case has a working counted loopback transport.
        // The Text codec-decline control retains its original null reactor.
        defer if (slots[0] == .provider) {
            slots[0].provider.transfer.deinit();
            finishCustodyNow(&run, &slots[0]);
        };
        var advances: usize = 0;
        var scratch_written = false;
        while (slots[0] != .free) : (advances += 1) {
            try std.testing.expect(advances < if (ordered_limit) @as(usize, 65536) else 4096);
            try std.testing.expect(advanceModelPreparation(&run, if (ordered_limit) &counted.reactor else null, &slots, &preparation, &listings, 64, 4));
            scratch_written = scratch_written or host.scratch_used.load(.acquire) != 0;
        }
        try std.testing.expect(advances > 1 and scratch_written);
        try std.testing.expect(retained == null);
        try std.testing.expect(!preparation.state.active and !preparation.page.active);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
        var observed: store_module.Observed = undefined;
        if (ordered_limit) {
            try counted.pump();
            try std.testing.expectEqual(@as(usize, 1), counted.requests);
            // A second real request drains the same connection after failure.
            // Only these two controls may reach the peer, including headers.
            try counted.positiveControl(&tmp);
            try std.testing.expectEqual(@as(usize, 2), counted.requests);
            try std.testing.expectEqual(@as(usize, 2), counted.peer.streams.items.len);
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
            // The command observation preserves its compound input identity.
            try storage.observeCommand("encode-failure-key", null, &observed);
            try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(
                &storage,
                "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND attempt_ordinal=?3 AND turn_id=?4 AND resolution_code=?5 AND resolved_at IS NOT NULL AND retry_due_at_ms IS NULL AND attempt_at IS NULL AND request_id IS NULL",
                .{ binding.operation_id, configured.accepted.session.slice(), binding.attempt_ordinal, binding.turn_id, "local_ordered_input_limit" },
            ));
            try std.testing.expect(@import("marks.zig").cause("local_ordered_input_limit", null).key == null);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expect(!storage.isFenced());
            continue;
        }
        try storage.observeCommand("encode-failure-key", null, &observed);
        const failed = observed.full.observation.kind.message.?.queue.?.state.failed;
        try std.testing.expectEqualStrings("provider_codec_failed", failed.code.slice());
        try std.testing.expectEqual(binding.attempt_ordinal, failed.binding.attempt_ordinal);
    }
}

test "Host fences dispose a sealed request before native transfer construction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]server_host.Phase{ .fenced, .stopping }) |phase| {
        var records: [1]execution.CustodyRecord = @splat(.{});
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var execution_state: execution_owner.Execution = undefined;
        execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
        var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
        const token = execution_state.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try execution_state.custody.attach(token, &permit);
        const writer = try tmp.dir.createFile(std.testing.io, "sealed", .{});
        try writer.writeStreamingAll(std.testing.io, "{}");
        writer.close(std.testing.io);
        const reader = try tmp.dir.openFile(std.testing.io, "sealed", .{});
        try tmp.dir.deleteFile(std.testing.io, "sealed");
        host.scratch_used.store(2, .release);
        run.scratch_budget = .{ .used = &host.scratch_used, .limit = 2 };
        var request = provider.PreparedRequest{
            .file = reader,
            .length = 2,
            .charged = 2,
            .structured_output = false,
            .provider = .codex,
            .codec = .@"openai-responses/1",
            .headers = .{ .count = 0 },
        };
        const owner = ModelPreparingSlot{ .token = token, .binding = binding };
        var slot = ExecutionSlot{ .model_preparing = owner };
        var reactor: provider.Reactor = undefined;
        _ = host.lifecycle.advance(phase);
        launchPreparedRequest(&run, &reactor, &slot, owner, &request, null);
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    }
}

test "Host fences discard prepared Bash without settling and retain failed cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var paths: platform.Paths = .{};
    try paths.scratch.set(root);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    for ([_]server_host.Phase{ .fenced, .stopping }) |phase| {
        for ([_]bool{ false, true }) |fail_cleanup| {
            var records: [1]execution.CustodyRecord = @splat(.{});
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = &lease,
                .store = undefined,
            };
            var host_parts: TestParts = undefined;
            host_parts.attach(&host, &lease);
            var execution_state: execution_owner.Execution = undefined;
            execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
            var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
            const token = execution_state.custody.reserve().?;
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 1,
                .parent_operation_id = 1,
                .action_id = 1,
            } };
            const binding = try execution_state.custody.attach(token, &permit);
            const file = try tmp.dir.createFile(std.testing.io, "suppressed-bash", .{});
            try file.writeStreamingAll(std.testing.io, "output\n");
            var name: protocol.Bounded(96) = .{};
            try name.set("suppressed-bash");
            host.scratch_used.store(7, .release);
            var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &host.scratch_used, .limit = 7 }, &.{});
            host.retention = &retention;
            if (fail_cleanup) {
                const gate = try tmp.dir.createFile(std.testing.io, bash.fault_gate_name, .{});
                gate.close(std.testing.io);
            }
            var prepared = bash.Prepared{
                .scratch = bashScratch(&run),
                .allocator = std.testing.allocator,
                .session = .{},
                .store_selector = "",
                .workspace = .{},
                .bash_path = undefined,
                .timeout_ms = 1,
                .faults = .{},
                .command = try std.testing.allocator.dupeSentinel(u8, "exit 0", 0),
                .stdout_capture = .{
                    .file = file,
                    .name = name,
                    .charged = 7,
                    .cleanup_fault = if (fail_cleanup) .gated else .none,
                },
                .stderr_capture = null,
            };
            var slots = [_]ExecutionSlot{.{ .bash_preparing = .{
                .attempt = testAttempt(&host, &execution_state.custody, token, binding),
            } }};
            var work: [1]BashWork = undefined;
            run.bash_work = &work;
            _ = host.lifecycle.advance(phase);
            launchPreparedBash(&run, &slots[0], &prepared);
            try std.testing.expect(prepared.stdout_capture == null);
            try std.testing.expect(prepared.command == null);
            try std.testing.expectEqual(phase, host.lifecycle.phase.load(.acquire));
            if (fail_cleanup) {
                try std.testing.expect(slots[0] == .bash_prepared_cleanup);
                try std.testing.expect(slots[0].bash_prepared_cleanup.cleanup.stdout_capture.?.file == null);
                try std.testing.expectEqual(@as(usize, 1), execution_state.custody.occupied());
                try std.testing.expectEqual(@as(u64, 7), host.scratch_used.load(.acquire));
                try tmp.dir.deleteFile(std.testing.io, bash.fault_gate_name);
                const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
                var retry_at = now;
                try std.testing.expect(advanceRetainedCleanup(&run, &slots, now, &retry_at));
            }
            try std.testing.expect(slots[0] == .free);
            try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "suppressed-bash", .{}));
        }
    }
}

fn launchBase(environments: ?*SessionEnvironments, session: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    const table = environments orelse return null;
    return table.copy(session, allocator);
}

test "a Session the register does not hold launches with the system PATH and the Host's HOME" {
    var environments: SessionEnvironments = undefined;
    try environments.init(std.testing.io, std.testing.allocator);
    defer environments.deinit();
    var offer: SessionEnvironments.Offer = try .init(std.testing.allocator, "PATH=/client/bin\x00HOME=/client\x00".len);
    defer offer.deinit(std.testing.allocator);
    @memcpy(offer.room(), "PATH=/client/bin\x00HOME=/client\x00");
    environments.offer("n3w5es", .{ .origin = .person, .admission = 1 }, &offer);
    const facts: environment.HostFacts = .{ .executable_dir = "/opt/rui/bin", .system_path = "/usr/bin:/bin", .home = "/home/host" };
    const identity: environment.Identity = .{ .address = "k7m2qx", .store = "/store", .sender_handle = "" };
    for ([_]?*SessionEnvironments{ null, &environments }) |table| {
        const base = try launchBase(table, "k7m2qx", std.testing.allocator);
        try std.testing.expectEqual(null, base);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const block = try environment.childBlock(arena.allocator(), base, facts, identity);
        try std.testing.expectEqualStrings("PATH=/opt/rui/bin:/usr/bin:/bin", std.mem.span(block[0].?));
        try std.testing.expectEqualStrings("HOME=/home/host", std.mem.span(block[1].?));
    }
    const held = (try launchBase(&environments, "n3w5es", std.testing.allocator)).?;
    defer std.testing.allocator.free(held);
    try std.testing.expectEqualStrings("PATH=/client/bin\x00HOME=/client\x00", held);
}

fn mappedResponse(bytes: []const u8) ![]u8 {
    const response = try pages.mapZeroed(u8, bytes.len);
    @memcpy(response, bytes);
    return response;
}

test "catalog answer slims saves and a 304 keeps its generation and facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/catalog.sqlite3", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    const fixture = "{\"openai\":{\"models\":{\"catalog-test\":{\"limit\":{\"context\":123}}}}}";
    var work: ListingWork = .{ .fetch = .{ .stream = .idle, .finished = true }, .credential = null, .response = try mappedResponse(fixture) };
    defer if (work.response) |bytes| pages.unmapZeroed(bytes);
    work.fetch.etag = .{};
    try work.fetch.etag.?.set("\"saved\"");
    try saveCatalogAnswer(&storage, &work, 200, work.response.?);
    try std.testing.expect(work.response == null);
    try std.testing.expectEqual(@as(?u32, 123), (try storage.modelFact("catalog-test")).?.context_window);
    const first = (try storage.readModelCatalogSource()).?;
    try saveCatalogAnswer(&storage, &work, 304, "not JSON, deliberately unread");
    const unchanged = (try storage.readModelCatalogSource()).?;
    try std.testing.expectEqual(first.generation, unchanged.generation);
    try std.testing.expectEqual(first.fetched_at, unchanged.fetched_at);
    try std.testing.expectEqualStrings("\"saved\"", unchanged.etag.?.slice());
    try std.testing.expectEqual(@as(?u32, 123), (try storage.modelFact("catalog-test")).?.context_window);
    work.response = try mappedResponse("not JSON");
    try std.testing.expectError(error.InvalidCatalog, saveCatalogAnswer(&storage, &work, 200, work.response.?));
    try std.testing.expectEqual(first.generation, (try storage.readModelCatalogSource()).?.generation);
}

test "Host resolves MCP calls without Bash admission and continues the Turn" {
    const records = comptime blk: {
        var out = tools.built_in_tool_set.records[0..tools.built_in_tool_set.records.len].* ++ [_]tools.Record{.{
            .name = "fetch_page",
            .owner = .mcp,
            .server = "docs",
            .description = "Fetch a page.",
            .input_schema = "{\"type\":\"object\"}",
        }};
        std.sort.heap(tools.Record, &out, {}, struct {
            fn lessThan(_: void, a: tools.Record, b: tools.Record) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        break :blk out;
    };
    const digests = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var out: [records.len][32]u8 = undefined;
        for (&records, &out) |*record, *digest| digest.* = tools.recordDigest(record);
        break :blk out;
    };
    const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_module.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var command = try store_module.testingCompleteConfiguration("host-mcp-config", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{ "bash", "fetch_page" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    try store_module.testingSubmitMessage(&storage, &tmp, "host-mcp-message", "host-mcp-message", session.slice(), "fetch");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, binding, "host-mcp-calls", &.{.{
        .item_id = "item-1",
        .name = "fetch_page",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{}",
        .decoded_arguments = "{}",
    }});
    try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
    {
        const pending = try store_module.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
        defer std.testing.allocator.free(pending);
        try std.testing.expect(std.mem.indexOf(u8, pending, "\"tool\":\"fetch_page\"") != null);
    }
    var custody: [1]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = &storage,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&custody, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    var mcp_calls: server_mcp.Calls = .{};
    defer mcp_calls.shutdown(&host);
    var native: NativeTurn = .{
        .mcp = &mcp_calls,
        .run = &run,
        .reactor = null,
        .slots = &.{},
        .workspace = undefined,
        .measurement = undefined,
        .attempts = .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &execution_state.custody },
        .fenced = false,
    };
    try std.testing.expect(native.runCoreAction() == .admitted);
    try std.testing.expect(native.runCoreAction() == .no_work);
    try std.testing.expectEqual(@as(usize, 0), execution_state.custody.occupied());
    const report = try store_module.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "mcp_server_unavailable") != null);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
}

test "a skill tool reload under heap exhaustion runs again later without fencing" {
    const skills = @import("skills.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{});
    defer storage.close() catch unreachable;
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = workspace_buffer[0..try tmp.dir.realPath(std.testing.io, &workspace_buffer)];
    var entries: [65]skills.Entry = undefined;
    var names: [65][6]u8 = undefined;
    for (&entries, &names, 0..) |*entry, *name, index| {
        _ = try std.fmt.bufPrint(name, "pad-{d:0>2}", .{index});
        entry.* = .{ .name = name, .description = "Metadata", .path = "/never-read" };
    }
    const initial = try skills.initialCatalog(memory.allocator(), .{ .entries = &entries });
    var command = try store_module.testingCompleteConfiguration("skill-reload-config", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"skill"});
    const configured = try storage.configureWithInitialSkills(&command, null, &.{ .ready = .{ .encoded = initial.encoded, .instruction = initial.instruction } }, .{});
    const session = configured.accepted.session;
    try store_module.testingSubmitMessage(&storage, &tmp, "skill-reload-message", "skill-reload-message", session.slice(), "reload");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, binding, "skill-reload-calls", &.{.{
        .item_id = "item-1",
        .name = "skill",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"operation\\\":\\\"reload\\\"}",
        .decoded_arguments = "{\"operation\":\"reload\"}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const admission = runSkill(&run, &input);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(execution_turn.Admission.admitted, admission);
            break;
        }
        try std.testing.expectEqual(execution_turn.Admission.retry_later, admission);
        try std.testing.expectEqual(entries.len, (try storage.readSkills(memory.allocator(), session.slice())).catalog.entries.len);
    }
    try std.testing.expect(fail_index > 2);
    try std.testing.expect((try storage.readSkills(memory.allocator(), session.slice())).catalog.entries.len != entries.len);
}

/// A reload's test fixture: one configured docs server whose startup list is `startup`, then `later` in order.
const ReloadScript = struct {
    const Script = @import("mcp/test_server.zig");
    script: Script,
    url: [128]u8 = undefined,
    servers: [1]server_mcp_settings.Server = .{.{}},
    fn start(self: *ReloadScript, startup: []const u8, later: []const []const u8) !void {
        self.script = .{ .reply = startup, .more = later };
        try self.script.start();
        try self.servers[0].name.set("docs");
        @memcpy(self.servers[0].bearer_token.bytes[0..6], "secret");
        self.servers[0].bearer_token.len = 6;
        try self.servers[0].url.set(try std.fmt.bufPrint(&self.url, "http://127.0.0.1:{d}/mcp", .{self.script.port}));
    }
};

fn listOf(comptime names: []const []const u8) []const u8 {
    const Script = @import("mcp/test_server.zig");
    const body = comptime blk: {
        var text: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[";
        for (names, 0..) |name, index| {
            if (index != 0) text = text ++ ",";
            text = text ++ "{\"name\":\"" ++ name ++ "\",\"inputSchema\":{\"type\":\"object\"}}";
        }
        break :blk text ++ "]}}";
    };
    return Script.jsonReply(body);
}

const reload_asked_one = "Asked 1 MCP server to list its tools again: docs. New tools can be searched for with find_tools after a server answers.";

fn reloadText(storage: *store_module.Store, session: @FieldType(@import("action_read.zig").Request, "session"), action_id: u64, out: []u8) ![]const u8 {
    var read: @import("action_read.zig").Read = undefined;
    try storage.readAction(&.{ .session = session, .action_id = action_id }, &read);
    const text = read.status.resolved.window.text.slice();
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// Configures a Session that offers only `find_tools` and submits one Message, so its next model Operation can settle
/// calls. Returns the Session.
fn reloadSession(storage: *store_module.Store, tmp: *std.testing.TmpDir, io: std.Io, comptime name: []const u8) !@FieldType(@import("action_read.zig").Request, "session") {
    const testing = store_module.testing;
    var cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try testing.completeConfiguration(name, "", try testing.canonicalCwd(io, &cwd), "model-a");
    configure.configuration.tools = try .of(&.{"find_tools"});
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try testing.submitTestMessage(storage, tmp, name ++ "-message", name ++ "-message", session.slice(), "reload");
    return session;
}

test "a model reload settles in the pass that asks, and a find_tools search finds the tool once its list lands" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture: ReloadScript = undefined;
    try fixture.start(listOf(&.{ "alpha", "gamma" }), &.{listOf(&.{ "alpha", "beta" })});
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    const session = try reloadSession(&storage, &tmp, io, "reload-config");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "reload-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true}",
        .decoded_arguments = "{\"reload\":true}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    try std.testing.expect(input.tool == .find_tools);
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };

    // One pass settles the reload: the server is asked again, its generation advanced, and nothing waits.
    try std.testing.expectEqual(@as(u64, 1), owner.asks[0].load(.acquire));
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &input));
    try std.testing.expectEqual(@as(u64, 2), owner.asks[0].load(.acquire));
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings(reload_asked_one, try reloadText(&storage, session, input.binding.action_id, &text));
    try std.testing.expect(!storage.isFenced());

    // The list lands in the owner, and a later find_tools search over the offered tools finds the new one.
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") != null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("gamma") == null);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try testing.settleItemsForTesting(&storage, &tmp, continuation, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
    // The search Session allows beta but has not loaded it, so a words search over its candidates finds beta.
    var search_cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var search_configure = try testing.completeConfiguration("reload-search-config", "", try testing.canonicalCwd(io, &search_cwd), "model-a");
    search_configure.configuration.tools = try .of(&.{ "beta", "find_tools" });
    search_configure.configuration.loaded_tools = try .of(&.{"find_tools"});
    const search = (try storage.configure(&search_configure, .{})).accepted.session;
    try testing.submitTestMessage(&storage, &tmp, "reload-search-config-message", "reload-search-config-message", search.slice(), "search");
    const search_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, search_model, "reload-search-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"words\\\":\\\"beta\\\"}",
        .decoded_arguments = "{\"words\":\"beta\"}",
    }});
    const search_input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &search_input));
    var found: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try reloadText(&storage, search, search_input.binding.action_id, &found), "- beta: ") != null);
}

test "a reload while a list is in flight folds into the next list, one extra list and not two" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const same = listOf(&.{"alpha"});
    var fixture: ReloadScript = undefined;
    try fixture.start(same, &.{ same, same });
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    const session = try reloadSession(&storage, &tmp, io, "fold-config");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "fold-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true}",
        .decoded_arguments = "{\"reload\":true}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };

    // A list is already in flight when the reload asks; the reload's generation waits for the list after it.
    _ = owner.ask(0);
    var failure: ?anyerror = null;
    _ = owner.service(&storage, 0, &failure);
    try std.testing.expect(owner.listing());
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &input));
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings(reload_asked_one, try reloadText(&storage, session, input.binding.action_id, &text));

    // The two asks made before the first list landed fold into one further list: three lists in all.
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expectEqual(@as(usize, 3), fixture.script.requests.load(.acquire));
    try std.testing.expectEqual(@as(?anyerror, null), failure);
}

test "a reload does not hold back a later core Action in another Session" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture: ReloadScript = undefined;
    try fixture.start(listOf(&.{"alpha"}), &.{});
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    // The reload Action is the lowest-id core Action; a search from another Session comes after it.
    _ = try reloadSession(&storage, &tmp, io, "hold-reload-config");
    const reload_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, reload_model, "hold-reload-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true}",
        .decoded_arguments = "{\"reload\":true}",
    }});
    _ = try reloadSession(&storage, &tmp, io, "hold-search-config");
    const search_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, search_model, "hold-search-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"words\\\":\\\"alpha\\\"}",
        .decoded_arguments = "{\"words\":\"alpha\"}",
    }});
    const reload = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &reload));

    // Once the reload settles, the next core Action is the other Session's search, not the reload again.
    const next = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    try std.testing.expect(next.binding.action_id != reload.binding.action_id);
    try std.testing.expect(next.tool == .find_tools);
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &next));
}

test "a reload with no MCP server configured says so and asks nothing" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, io, .{});
    defer storage.close() catch unreachable;
    var cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try testing.completeConfiguration("no-mcp-reload-config", "", try testing.canonicalCwd(io, &cwd), "model-a");
    configure.configuration.tools = try .of(&.{"find_tools"});
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try testing.submitTestMessage(&storage, &tmp, "no-mcp-reload-message", "no-mcp-reload-message", session.slice(), "reload");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "no-mcp-reload-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true,\\\"words\\\":\\\"alpha\\\"}",
        .decoded_arguments = "{\"reload\":true,\"words\":\"alpha\"}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, null, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &input));
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings("No MCP servers are configured, so nothing was reloaded.\nNo tools matched. 0 tools are still not loaded.", try reloadText(&storage, session, input.binding.action_id, &text));
}

test "a find_tools reload with words reports the asks, then the loaded tools, and writes one revision" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture: ReloadScript = undefined;
    try fixture.start(listOf(&.{"alpha"}), &.{});
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    // The Session offers alpha, which the startup list saved, but has not loaded it, so the search can load it.
    var cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try testing.completeConfiguration("reload-words-config", "", try testing.canonicalCwd(io, &cwd), "model-a");
    configure.configuration.tools = try .of(&.{ "alpha", "find_tools" });
    configure.configuration.loaded_tools = try .of(&.{"find_tools"});
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try testing.submitTestMessage(&storage, &tmp, "reload-words-message", "reload-words-message", session.slice(), "reload and search");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "reload-words-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true,\\\"words\\\":\\\"alpha\\\"}",
        .decoded_arguments = "{\"reload\":true,\"words\":\"alpha\"}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    const revisions = try testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session.slice()});

    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &input));
    try std.testing.expectEqual(@as(u64, 2), owner.asks[0].load(.acquire));
    var text: [512]u8 = undefined;
    const bytes = try reloadText(&storage, session, input.binding.action_id, &text);
    try std.testing.expect(std.mem.startsWith(u8, bytes, reload_asked_one ++ "\nLoaded these tools; they are available on your next request:\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "- alpha: ") != null);
    try std.testing.expectEqual(revisions + 1, try testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session.slice()}));
    try std.testing.expect(!storage.isFenced());
}

test "a find_tools reload with invalid words is refused and asks no server" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture: ReloadScript = undefined;
    try fixture.start(listOf(&.{"alpha"}), &.{});
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    const session = try reloadSession(&storage, &tmp, io, "reload-refused-config");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "reload-refused-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true,\\\"words\\\":7}",
        .decoded_arguments = "{\"reload\":true,\"words\":7}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    try std.testing.expectEqual(execution_turn.Admission.admitted, runFindTools(&run, &input));
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Rui could not find tools: words must be a string. Nothing was loaded.", try reloadText(&storage, session, input.binding.action_id, &text));
    // The refused call asked no server: the owner's generation is still the one the startup list left.
    try std.testing.expectEqual(@as(u64, 1), owner.asks[0].load(.acquire));
    try std.testing.expect(!storage.isFenced());
}

test "a find_tools reload under heap exhaustion retries later without fencing, and its asks fold into one more list" {
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const same = listOf(&.{"alpha"});
    var fixture: ReloadScript = undefined;
    try fixture.start(same, &.{ same, same, same });
    defer fixture.script.stop();
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &fixture.servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));

    const session = try reloadSession(&storage, &tmp, io, "reload-oom-config");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleCallsForTesting(&storage, &tmp, model, "reload-oom-calls", &.{.{
        .item_id = "item-1",
        .name = "find_tools",
        .encoded_call_id = "call-1",
        .decoded_call_id = "call-1",
        .encoded_arguments = "{\\\"reload\\\":true}",
        .decoded_arguments = "{\"reload\":true}",
    }});
    const input = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const admission = runFindTools(&run, &input);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(execution_turn.Admission.admitted, admission);
            break;
        }
        try std.testing.expectEqual(execution_turn.Admission.retry_later, admission);
    }
    // Attempts that failed after asking leave their asks in place; the owner's one list covers all of them.
    try std.testing.expect(owner.asks[0].load(.acquire) >= 3);
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings(reload_asked_one, try reloadText(&storage, session, input.binding.action_id, &text));
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expectEqual(@as(usize, 2), fixture.script.requests.load(.acquire));
    try std.testing.expect(!storage.isFenced());
}

test "aggregate custody reconciles MCP and slots and rejects tokens shared across populations" {
    var records: [3]execution.CustodyRecord = @splat(.{});
    var custody = execution.CustodyPool.initialize(&records);
    const model_token = custody.reserve().?;
    var model_permit: store_module.DispatchPermit = .{ .binding = .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 } };
    const model_binding = try custody.attach(model_token, &model_permit);
    const slots = [_]ExecutionSlot{.{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } }};
    const action_token = custody.reserve().?;
    var action_permit: store_module.ActionDispatchPermit = .{ .binding = .{ .turn_id = 3, .parent_operation_id = 4, .action_id = 5 } };
    const action_binding = try custody.attach(action_token, &action_permit);
    var active: server_mcp.Active = .{ .attempt = .{ .parts = undefined, .token = action_token, .labels = undefined, .binding = action_binding }, .arena = .init(std.testing.allocator) };
    defer active.arena.deinit();
    var mcp: server_mcp.Calls = .{};
    mcp.entries[0] = &active;
    try checkSlotCustodyAgreement(&slots, &custody, &mcp);
    try custody.consumeLaunchAuthority(action_token, .{ .action = action_binding }, std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expectError(error.DispatchPermitConsumed, custody.consumeLaunchAuthority(action_token, .{ .action = action_binding }, std.Io.Clock.Timestamp.now(std.testing.io, .awake)));
    try std.testing.expect(custody.claimTerminalDelivery(action_token));
    try std.testing.expect(!custody.claimTerminalDelivery(action_token));
    active.attempt.token = model_token;
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&slots, &custody, &mcp));
    active.attempt.token = action_token;
    mcp.entries[1] = &active;
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&slots, &custody, &mcp));
    mcp.entries[1] = null;
    active.attempt.binding.action_id += 1;
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody, &mcp));
    active.attempt.binding = action_binding;
    mcp.entries[0] = null;
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&slots, &custody, &mcp));
    mcp.entries[0] = &active;
    try checkSlotCustodyAgreement(&slots, &custody, &mcp);
    mcp.entries[0] = null;
    try custody.detach(action_token);
    try custody.cleanupComplete(action_token);
    try checkSlotCustodyAgreement(&slots, &custody, &mcp);
    try custody.detach(model_token);
    try custody.cleanupComplete(model_token);
    try checkSlotCustodyAgreement(&.{}, &custody, &mcp);
}

// These fixtures enter the real failure owner after transport completion. They
// intentionally create no network request; transfer scheduling has its own tests.
const PendingOverflowFixture = struct {
    tmp: std.testing.TmpDir,
    storage: store_module.Store,
    root: [protocol.max_store_bytes]u8,
    root_length: usize,
    lease: platform.StoreLease,
    records: [3]execution.CustodyRecord = @splat(.{}),
    slots: [3]ExecutionSlot = @splat(.free),
    sessions: [3]protocol.Bounded(protocol.max_session_bytes) = @splat(.{}),
    host: Host,
    run: Run,
    parts: TestParts = undefined,
    execution: execution_owner.Execution = undefined,
    work: pages.Mapped(Workspace),
    entries: [4]output_retention.Entry = @splat(.{}),
    retention: output_retention.Queue,

    fn init(self: *PendingOverflowFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try store_module.testingStoreWith(&.{ .engine = .sqlite }, &self.storage, &self.tmp, std.testing.io, .{});
        errdefer self.storage.close() catch unreachable;
        self.root_length = try self.tmp.dir.realPath(std.testing.io, &self.root);
        self.lease.paths = .{};
        try self.lease.paths.scratch.set(self.path());
        self.host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &self.lease, .store = &self.storage };
        self.parts.attach(&self.host, &self.lease);
        self.execution.init(&self.records, null, &self.parts.lifecycle, &self.host.scratch_used, null);
        self.run = .{ .host = &self.host, .settings = .{}, .execution = &self.execution, .custody = self.execution.attempts(&self.storage, self.host.probes).custody };
        self.retention = output_retention.Queue.initialize(std.testing.io, self.path(), self.budget(), &self.entries);
        self.host.retention = &self.retention;
        self.work = try pages.Mapped(Workspace).map();
        self.work.value.failure_after = 0;
        self.work.value.model_admission.init();
    }

    fn path(self: *PendingOverflowFixture) []const u8 {
        return self.root[0..self.root_length];
    }

    fn budget(self: *PendingOverflowFixture) ScratchBudget {
        return .{ .used = &self.host.scratch_used, .limit = 4 * 1024 * 1024 };
    }

    fn deinit(self: *PendingOverflowFixture) void {
        // model_preparing here is an admitted fixture with no request cursor.
        for (&self.slots) |*slot| if (slot.* == .model_preparing) finishCustodyNow(&self.run, slot);
        shutdownExecution(&self.run, &self.slots, self.work.value);
        self.work.unmap();
        self.retention.cleanupAll();
        self.storage.close() catch unreachable;
        self.tmp.cleanup();
    }

    fn admit(self: *PendingOverflowFixture, index: usize, key: []const u8, compound: bool) !AttemptOwner {
        const session = try store_module.testing.configureTestSession(&self.storage, key);
        self.sessions[index] = session;
        var name: [96]u8 = undefined;
        try store_module.testingSubmitMessage(&self.storage, &self.tmp, try std.fmt.bufPrint(&name, "{s}-first", .{key}), try std.fmt.bufPrint(&name, "{s}-first", .{key}), session.slice(), "first");
        if (compound) {
            const large = try std.testing.allocator.alloc(u8, 200_000);
            defer std.testing.allocator.free(large);
            @memset(large, 'x');
            try store_module.testing.submitTestMessageParts(&self.storage, &self.tmp, try std.fmt.bufPrint(&name, "{s}-middle", .{key}), session.slice(), &.{ .{ .bytes = large }, .{ .bytes = @embedFile("codecs/fixtures/image-input/pixel.png"), .kind = .{ .image = .{} } } });
            try store_module.testingSubmitMessage(&self.storage, &self.tmp, try std.fmt.bufPrint(&name, "{s}-last", .{key}), try std.fmt.bufPrint(&name, "{s}-last", .{key}), session.slice(), "last");
        }
        var admission = (try self.storage.admitNextModelAttempt(.{})).?;
        if (compound) {
            try self.storage.settleModelAttemptFailure(admission.permit.binding, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            admission = (try self.storage.admitNextModelAttempt(.{})).?;
        }
        const token = self.run.custody.reserve().?;
        const binding = try attachSlot(&self.run, &self.slots[index], token, &admission.permit);
        return .{ .token = token, .binding = binding, .purpose = if (compound) .compaction else .assistant_response };
    }

    fn stage(self: *PendingOverflowFixture, index: usize, owner: AttemptOwner) !void {
        var retained: ?named_scratch.Owner = null;
        var capture = try provider.ResponseCapture.init(std.testing.io, self.path(), self.budget(), owner.binding, false, false, &retained, @sizeOf(PendingFailure));
        errdefer capture.deinit(std.testing.io, self.budget());
        try capture.seal(std.testing.io, false, 0);
        var response: provider.SealedResponse = .{ .io = std.testing.io, .file = capture.file, .length = capture.length, .charged = capture.charged, .budget = self.budget(), .workspace = capture.workspace };
        var request_id: protocol.Bounded(256) = .{};
        try request_id.set("original-overflow-request");
        var diagnostic: [37]u8 = @splat('d');
        const failure: store_module.ModelFailure = .{ .rejected = .{ .code = "provider_context_overflow", .request_id = request_id, .diagnostic = &diagnostic, .report = "original report" } };
        try std.testing.expectEqual(@as(?bool, true), beginOverflowFailure(&self.run, owner, failure, .context_overflow, &response));
        @memset(&diagnostic, 'z');
        moveSlot(&self.run, &self.slots[index], .model_failure_preparing, .{ .owner = owner, .response = response });
        try std.testing.expectEqualStrings("ddddddddddddddddddddddddddddddddddddd", self.slots[index].model_failure_preparing.response.state(PendingFailure).diagnostic.slice());
    }

    fn expectReleased(self: *PendingOverflowFixture) !void {
        try std.testing.expectEqual(@as(u64, 0), self.host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), self.run.custody.occupied());
        for (self.slots) |slot| try std.testing.expect(slot == .free);
        try std.testing.expect(!self.storage.isFenced());
    }
};

test "pending compound overflow advances round robin while another completion settles" {
    var phase: []const u8 = "stage pending failures";
    errdefer std.debug.print("pending fairness phase {s}\n", .{phase});
    const mapped = try pages.Mapped(PendingOverflowFixture).map();
    defer mapped.unmap();
    const fixture = mapped.value;
    fixture.* = .{ .tmp = undefined, .storage = undefined, .root = undefined, .root_length = undefined, .lease = undefined, .host = undefined, .run = undefined, .work = undefined, .retention = undefined };
    try fixture.init();
    defer fixture.deinit();
    const first = try fixture.admit(0, "pending-first", true);
    try fixture.stage(0, first);
    const second = try fixture.admit(1, "pending-second", true);
    try fixture.stage(1, second);
    const work = fixture.work.value;
    try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, work));
    try std.testing.expectEqual(@as(usize, 1), work.failure_after);
    try std.testing.expect(fixture.slots[0].model_failure_preparing.response.state(PendingFailure).floor.stage == .walk);
    try std.testing.expect(fixture.slots[1].model_failure_preparing.response.state(PendingFailure).floor.stage == .start);
    try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, work));
    try std.testing.expectEqual(@as(usize, 2), work.failure_after);
    try std.testing.expect(fixture.slots[1].model_failure_preparing.response.state(PendingFailure).floor.stage == .walk);
    // A normal completed provider response is decoded and committed while both
    // independent compound floor walks still retain their response owners.
    const normal = try fixture.admit(2, "pending-normal", false);
    var reactor: provider.Reactor = undefined;
    try reactor.initForTesting(std.testing.allocator, std.testing.io, .{ .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }), .capacity = 1, .inactivity_seconds = 1, .scratch_path = fixture.path(), .budget = fixture.budget() });
    defer reactor.deinit();
    const item = "{\"type\":\"message\",\"id\":\"normal-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"normal completed\"}]}";
    const body = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ item ++ "}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"normal-response\",\"status\":\"completed\",\"output\":[" ++ item ++ "]}}\n\n";
    var retained: ?named_scratch.Owner = null;
    const request_file = try fixture.tmp.dir.createFile(std.testing.io, "normal-request", .{ .read = true });
    const request: provider.PreparedRequest = .{ .file = request_file, .length = 0, .charged = 0, .structured_output = false, .provider = .codex, .codec = .@"openai-responses/2", .headers = .{ .count = 0 } };
    var transfer: provider.Transfer = undefined;
    try transfer.start(&reactor, &request, normal.binding, .{ .response_workspace_bytes = body.len }, &retained);
    moveSlot(&fixture.run, &fixture.slots[2], .provider, .{ .owner = normal, .transfer = transfer });
    try fixture.slots[2].provider.transfer.response.file.writePositionalAll(std.testing.io, body, 0);
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&fixture.slots[2].provider.transfer.stream, .{ .body = body.len }));
    try fixture.slots[2].provider.transfer.response.seal(std.testing.io, false, body.len);
    completeTransfer(&fixture.run, work, &fixture.slots[2], .{ .transfer = &fixture.slots[2].provider.transfer, .outcome = .{ .transport_finished = .{ .disposition = .success, .http_status = 200 } }, .queued_after = 0 });
    try std.testing.expect(fixture.slots[2] == .free);
    phase = "normal completion committed its authoritative final output";
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code='answer' AND output_item_count=1", .{normal.binding.operation_id}));
    try std.testing.expectEqual(@as(usize, 2), fixture.execution.custody.occupied());
    var steps: usize = 0;
    while (fixture.execution.custody.occupied() != 0) : (steps += 1) {
        try std.testing.expect(steps < 512);
        try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, work));
    }
    try std.testing.expect(steps > 4);
    phase = "retained original failure committed";
    for ([_]AttemptOwner{ first, second }) |owner| {
        try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation o JOIN content c ON c.content_id=o.resolution_content_id WHERE o.operation_id=?1 AND resolution_code='context_overflow' AND last_failure_code='provider_context_overflow' AND request_id='original-overflow-request' AND c.digest=?2", .{ owner.binding.operation_id, store_module.testing.Blob{ .bytes = &protocol.contentDigest("ddddddddddddddddddddddddddddddddddddd") } }));
    }
    try fixture.expectReleased();
    try std.testing.expect(fixture.host.lifecycle.launchAllowed());
}

test "pending compound overflow cancellation fence and shutdown release partial floor owners" {
    for ([_]enum { stop_cursor, stop_ready, fence, shutdown }{ .stop_cursor, .stop_ready, .fence, .shutdown }) |mode| {
        const mapped = try pages.Mapped(PendingOverflowFixture).map();
        defer mapped.unmap();
        const fixture = mapped.value;
        fixture.* = .{ .tmp = undefined, .storage = undefined, .root = undefined, .root_length = undefined, .lease = undefined, .host = undefined, .run = undefined, .work = undefined, .retention = undefined };
        try fixture.init();
        defer fixture.deinit();
        const owner = try fixture.admit(0, "pending-control", true);
        try fixture.stage(0, owner);
        const pending = fixture.slots[0].model_failure_preparing.response.state(PendingFailure);
        var steps: usize = 0;
        while (if (mode == .stop_ready) !pending.floor.ready else pending.floor.cursor == null) : (steps += 1) {
            try std.testing.expect(steps < 256);
            try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, fixture.work.value));
        }
        try std.testing.expect(fixture.host.scratch_used.load(.acquire) >= @sizeOf(PendingFailure));
        switch (mode) {
            .stop_cursor, .stop_ready => {
                var stop: protocol.SessionStopCommand = .{};
                try stop.key.set("pending-stop");
                // The admitted Operation determines the Session; no fixture SQL
                // changes the stop or the retained failure's disposition.
                try stop.session.set(fixture.sessions[0].slice());
                try std.testing.expect(fixture.storage.stopSession(&stop, .{}) == .accepted);
                cancelSupersededTransfers(&fixture.run, &fixture.slots, fixture.work.value);
            },
            .fence => {
                _ = fixture.host.lifecycle.advance(.fenced);
                try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, fixture.work.value));
            },
            .shutdown => shutdownExecution(&fixture.run, &fixture.slots, fixture.work.value),
        }
        try fixture.expectReleased();
        try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND last_failure_code IS NULL", .{owner.binding.operation_id}));
    }
}

test "pending compound overflow sent through immediate failure fences without a history scan" {
    const mapped = try pages.Mapped(PendingOverflowFixture).map();
    defer mapped.unmap();
    const fixture = mapped.value;
    fixture.* = .{ .tmp = undefined, .storage = undefined, .root = undefined, .root_length = undefined, .lease = undefined, .host = undefined, .run = undefined, .work = undefined, .retention = undefined };
    try fixture.init();
    defer fixture.deinit();
    const owner = try fixture.admit(0, "pending-immediate", true);
    saveImmediateFailure(&fixture.run, owner.binding, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow);
    try std.testing.expect(!fixture.host.lifecycle.launchAllowed());
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code IS NULL AND last_failure_code IS NULL AND history_level IS NULL", .{owner.binding.operation_id}));
    try std.testing.expectEqual(@as(u64, 0), fixture.host.scratch_used.load(.acquire));
    try std.testing.expect(!fixture.storage.isFenced());
}

test "pending compound overflow from HTTP and SSE retains original failure through response ownership transfer" {
    const Transport = enum { http, sse };
    for ([_]Transport{ .http, .sse }) |transport| {
        var phase: []const u8 = "prepare real transfer";
        errdefer std.debug.print("pending {s} overflow phase {s}\n", .{ @tagName(transport), phase });
        const mapped = try pages.Mapped(PendingOverflowFixture).map();
        defer mapped.unmap();
        const fixture = mapped.value;
        fixture.* = .{ .tmp = undefined, .storage = undefined, .root = undefined, .root_length = undefined, .lease = undefined, .host = undefined, .run = undefined, .work = undefined, .retention = undefined };
        try fixture.init();
        defer fixture.deinit();
        const owner = try fixture.admit(0, if (transport == .http) "pending-http" else "pending-sse", true);
        var reactor: provider.Reactor = undefined;
        try reactor.initForTesting(std.testing.allocator, std.testing.io, .{
            .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }),
            .capacity = 1,
            .inactivity_seconds = 1,
            .scratch_path = fixture.path(),
            .budget = fixture.budget(),
            .observation = .{},
        });
        defer reactor.deinit();
        // Cleanup must precede the reactor even when an assertion leaves a
        // prepared transfer in its slot. No reactor launch is needed.
        defer shutdownExecution(&fixture.run, &fixture.slots, fixture.work.value);
        const body: []const u8 = if (transport == .http)
            "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"original HTTP report\"}}"
        else
            "data: {\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"original SSE report\"}\n\n";
        const report: []const u8 = if (transport == .http) "context_length_exceeded: original HTTP report" else "context_length_exceeded: original SSE report";
        const correlation: []const u8 = if (transport == .http) "original-http-request" else "original-sse-request";
        const status: u16 = if (transport == .http) 400 else 200;
        var retained: ?named_scratch.Owner = null;
        const request_file = try fixture.tmp.dir.createFile(std.testing.io, "pending-overflow-request", .{ .read = true });
        const request: provider.PreparedRequest = .{ .file = request_file, .length = 0, .charged = 0, .structured_output = false, .provider = .codex, .codec = .@"openai-responses/2", .headers = .{ .count = 0 } };
        var transfer: provider.Transfer = undefined;
        try transfer.start(&reactor, &request, owner.binding, .{ .response_workspace_bytes = @sizeOf(PendingFailure) }, &retained);
        const slot = &fixture.slots[0];
        moveSlot(&fixture.run, slot, .provider, .{ .owner = owner, .transfer = transfer });
        try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&slot.provider.transfer.stream, .{ .head = .{
            .kind = .final,
            .status = status,
            .fields = &.{.{ .name = "x-request-id", .value = correlation }},
        } }));
        try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&slot.provider.transfer.stream, .{ .body = body.len }));
        try slot.provider.transfer.response.file.writePositionalAll(std.testing.io, body, 0);
        try slot.provider.transfer.response.seal(std.testing.io, false, body.len);
        const response_fd = slot.provider.transfer.response.file.handle;
        try std.testing.expect(std.c.fcntl(response_fd, std.c.F.GETFD) >= 0);
        phase = "decode provider failure and hand response to pending owner";
        completeTransfer(&fixture.run, fixture.work.value, slot, .{
            .transfer = &slot.provider.transfer,
            .outcome = .{ .transport_finished = .{ .disposition = if (transport == .http) .permanent_http else .success, .http_status = status } },
            .queued_after = 0,
        });
        try std.testing.expect(slot.* == .model_failure_preparing);
        try std.testing.expectEqual(response_fd, slot.model_failure_preparing.response.file.handle);
        try std.testing.expect(std.c.fcntl(response_fd, std.c.F.GETFD) >= 0);
        try fixture.execution.custody.checkAttached(owner.token, .{ .model = owner.binding });
        try checkSlotCustodyAgreement(&fixture.slots, &fixture.execution.custody, null);
        const pending = slot.model_failure_preparing.response.state(PendingFailure);
        const expected_kind: std.meta.Tag(store_module.ModelFailure) = if (transport == .http) .correlated else .rejected;
        try std.testing.expectEqual(expected_kind, pending.kind);
        try std.testing.expectEqualStrings("provider_context_overflow", pending.code.slice());
        try std.testing.expectEqualStrings(correlation, pending.request_id.slice());
        try std.testing.expectEqualStrings(report, pending.report.slice());
        var diagnostic: protocol.Bounded(512) = .{};
        if (transport == .sse) {
            try std.testing.expectEqual(error.ContextOverflow, fixture.work.value.interpretation.rejected.reason);
            var expected_buffer: [512]u8 = undefined;
            try diagnostic.set(fixture.work.value.interpretation.rejected.format(&expected_buffer));
        }
        try std.testing.expectEqualStrings(diagnostic.slice(), pending.diagnostic.slice());
        // Only the response workspace backing the bounded floor walk remains
        // charged, including after the HTTP capture's local owner returns.
        try std.testing.expectEqual(@as(u64, @sizeOf(PendingFailure)), fixture.host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), fixture.execution.custody.occupied());
        fixture.work.value.provider_failure.clear();
        try fixture.work.value.provider_failure.report.set("later unrelated provider report");
        if (transport == .sse) fixture.work.value.interpretation.rejected.code = "later_unrelated_rejection";
        phase = "finish bounded floor walk with retained original failure";
        var steps: usize = 0;
        while (slot.* == .model_failure_preparing) : (steps += 1) {
            try std.testing.expect(steps < 512);
            try std.testing.expect(std.c.fcntl(response_fd, std.c.F.GETFD) >= 0);
            try fixture.execution.custody.checkAttached(owner.token, .{ .model = owner.binding });
            const saved = slot.model_failure_preparing.response.state(PendingFailure);
            try std.testing.expectEqual(expected_kind, saved.kind);
            try std.testing.expectEqualStrings("provider_context_overflow", saved.code.slice());
            try std.testing.expectEqualStrings(correlation, saved.request_id.slice());
            try std.testing.expectEqualStrings(report, saved.report.slice());
            try std.testing.expectEqualStrings(diagnostic.slice(), saved.diagnostic.slice());
            try std.testing.expect(advancePendingFailure(&fixture.run, &fixture.slots, fixture.work.value));
        }
        try std.testing.expect(steps > 1);
        try std.testing.expect(std.c.fcntl(response_fd, std.c.F.GETFD) < 0);
        if (transport == .http) {
            try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code='context_overflow' AND last_failure_code='provider_context_overflow' AND request_id=?2 AND resolution_content_id IS NULL", .{ owner.binding.operation_id, correlation }));
        } else {
            try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&fixture.storage, "SELECT count(*) FROM model_operation o JOIN content c ON c.content_id=o.resolution_content_id WHERE o.operation_id=?1 AND resolution_code='context_overflow' AND last_failure_code='provider_context_overflow' AND request_id=?2 AND c.digest=?3", .{ owner.binding.operation_id, correlation, store_module.testing.Blob{ .bytes = &protocol.contentDigest(diagnostic.slice()) } }));
        }
        try fixture.expectReleased();
        try std.testing.expect(fixture.host.lifecycle.launchAllowed());
    }
}

test "EXR-92 a Host started before its MCP server serves holds the server's new tool after a pushed list change" {
    const Script = @import("mcp/test_server.zig");
    const poll = @import("test_poll");
    const testing = store_module.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The server answers 503 while the Host starts, then lists `beta` on the stream's acknowledgment, then pushes a
    // change that adds `gamma`.
    var listening: Script.Listening = .{};
    var script: Script = .{ .reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n", .more = &.{
        listOf(&.{ "alpha", "beta" }),
        listOf(&.{ "alpha", "beta", "gamma" }),
    }, .listening = &listening };
    try script.start();
    defer script.stop();
    var url: [128]u8 = undefined;
    var server: server_mcp_settings.Server = .{};
    try server.name.set("docs");
    @memcpy(server.bearer_token.bytes[0..6], "secret");
    server.bearer_token.len = 6;
    try server.url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}));
    const servers = [_]server_mcp_settings.Server{server};
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&.{}, &owner, &host_parts.lifecycle, &host.scratch_used, null);
    var run: Run = .{ .host = &host, .execution = &execution_state, .custody = &execution_state.custody, .settings = .{} };

    try owner.startup(io, &storage, null, null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") == null);

    const Drive = struct {
        run: *Run,
        storage: *store_module.Store,
        script: *const Script,
        listening: *const Script.Listening,
        target: ?[]const u8,
        fn reached(drive: *@This()) bool {
            _ = serviceRelist(drive.run);
            if (drive.listening.opens.load(.acquire) < 1) return false;
            if (drive.target) |name| return drive.storage.hostTools().host_tool_set.find(name) != null;
            return false;
        }
    };
    // Startup's list failed and the stream's acknowledgment asks one more list, which lists `beta`.
    var first: Drive = .{ .run = &run, .storage = &storage, .script = &script, .listening = &listening, .target = "beta" };
    try poll.waitUntil(io, poll.after(io, .fromSeconds(30)), &first, Drive.reached);
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));

    // The server changes its list and pushes the notice; the next Operation's projected set holds `gamma`.
    listening.push("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n");
    var second: Drive = .{ .run = &run, .storage = &storage, .script = &script, .listening = &listening, .target = "gamma" };
    try poll.waitUntil(io, poll.after(io, .fromSeconds(30)), &second, Drive.reached);
    try std.testing.expectEqual(@as(usize, 3), script.requests.load(.acquire));
    listening.finish();
}
