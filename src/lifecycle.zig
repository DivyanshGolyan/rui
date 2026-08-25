const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const checkpoint = @import("checkpoint.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_wal = @import("session_wal.zig");

const agent_generation: u32 = 1;
const ProductionSlotPool = core_image.SlotPool(1);

/// Process-owned bounded activation capacity. Construct this once at host
/// startup and pass it through every agent lifecycle entry point.
pub const Host = struct {
    slots: ProductionSlotPool = .{},
};

pub const RuntimeConfig = struct {
    workspace_path: []const u8,
    fault: ?FaultHook = null,
    bash_policy: ?bash_tool.Policy = null,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    patch_policy: ?patch_tool.Policy = null,
    approval_hook: ?ApprovalHook = null,
    completion_hook: ?CompletionHook = null,
    settle_only: bool = false,
};

pub const ApprovalKind = enum { bash, apply_patch };

pub const Approval = struct {
    kind: ApprovalKind,
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: u64,
    descriptor_ref: u64,
};

pub const ApprovalHook = struct {
    context: *anyopaque,
    required: *const fn (*anyopaque, Approval) anyerror!void,
};

pub const CompletionHook = struct {
    context: *anyopaque,
    offered: *const fn (*anyopaque, completion_inbox.Envelope) anyerror!void,
};

pub const Control = enum { cancel, shutdown };

pub fn commitControl(session: *session_store.Session, control: Control) !void {
    const token = session.ownerToken();
    var state: ControlSearch = .{};
    _ = try session.replaySemantic(token, &state, ControlSearch.applyTransaction);
    if (state.open_operation) return error.AcceptedOperationUnsettled;
    const fact = semanticFact(if (control == .cancel) .cancellation else .shutdown, session);
    _ = try session.commitSemantic(token, &.{fact}, null);
}

pub fn restoredControl(session: *session_store.Session) !?Control {
    var state: ControlSearch = .{};
    _ = try session.replaySemantic(session.ownerToken(), &state, ControlSearch.applyTransaction);
    return state.control;
}

const ControlSearch = struct {
    open_operation: bool = false,
    operation_id: u64 = 0,
    generation: u32 = 0,
    control: ?Control = null,

    fn applyTransaction(context: *anyopaque, transaction: session_wal.Transaction) anyerror!void {
        const self: *ControlSearch = @ptrCast(@alignCast(context));
        for (transaction.factSlice()) |fact| switch (fact.kind) {
            .operation_accepted => {
                self.open_operation = true;
                self.operation_id = fact.operation_id;
                self.generation = fact.generation;
            },
            .result => if (self.open_operation and self.operation_id == fact.operation_id and
                self.generation == fact.generation)
            {
                self.open_operation = false;
            },
            .cancellation => self.control = .cancel,
            .shutdown => self.control = .shutdown,
            else => {},
        };
    }
};

pub const FaultBoundary = enum {
    after_model_dispatch,
    after_completion_inbox,
    after_completion_persist,
    after_final_blob,
    after_assistant_entry,
    after_bash_execution,
    after_bash_result,
    after_tool_result_entry,
    after_tool_checkpoint,
    after_patch_permission_binding,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, FaultBoundary) anyerror!void,
};

const OperationIds = struct {
    operation_id: u32,
    attempt_id: u64,
    request_ref: u64,
    response_ref: u32,
    final_ref: u64,
};

const ModelCompletion = struct {
    agent_id: u64,
    operation_id: u64,
    ownership_epoch: u64,
    result: u64,
    agent_generation: u32,
    operation_generation: u32,
};

fn finalReference(response_ref: u64) u64 {
    return (@as(u64, 1) << 63) | response_ref;
}

const Core = struct {
    lease: core_image.SlotLease,
    slot: *core_image.ActivationSlot,
    reducer: core_image.Core = undefined,
    encoded_state: [core_state.encoded_size]u8 = undefined,
    active: bool = false,

    fn open(pool: *ProductionSlotPool) !Core {
        const lease = try pool.borrow();
        return .{ .lease = lease, .slot = lease.slot };
    }

    fn initialize(self: *Core, agent_id: u64) !void {
        self.reducer = try core_image.Core.initialize(self.slot, .{
            .agent_id = agent_id,
            .generation = agent_generation,
        });
        self.active = true;
    }

    fn activate(self: *Core) !void {
        self.reducer = try core_image.Core.activate(self.slot, &self.encoded_state);
        self.active = true;
    }

    fn suspendIntoState(self: *Core) !void {
        try self.reducer.suspendInto(&self.encoded_state);
        self.active = false;
    }

    fn close(self: *Core) void {
        if (self.active) self.reducer.abandon();
        self.lease.release() catch unreachable;
        self.active = false;
    }
};

fn commitCoreFacts(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    checkpoint_buffer: []u8,
    core: *Core,
    facts: []const session_wal.Fact,
    reactivate: bool,
) !void {
    try core.suspendIntoState();
    _ = try session.commitSemantic(token, facts, &core.encoded_state);
    try session.publishCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        &core.encoded_state,
    );
    if (reactivate) try core.activate();
}

fn semanticFact(
    kind: session_wal.Kind,
    session: *const session_store.Session,
) session_wal.Fact {
    return .{
        .kind = kind,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .ownership_epoch = session.ownership_epoch,
    };
}

fn restoreCoreFromWal(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    checkpoint_buffer: []u8,
    core: *Core,
) !void {
    _ = checkpoint_buffer;
    var replay_context: u8 = 0;
    const replay = try session.replaySemantic(
        token,
        &replay_context,
        ignoreTransaction,
    );
    core.encoded_state = replay.last_core orelse return error.MissingWalCoreState;
    try core.activate();
}

fn ignoreTransaction(_: *anyopaque, _: session_wal.Transaction) anyerror!void {}

const ModelSlot = struct {
    core: *Core,
    session: *session_store.Session,
    token: session_store.OwnerToken,

    fn apply(context: *anyopaque, completion: ModelCompletion) anyerror!void {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        try self.core.reducer.completeOperation(.{
            .id = completion.operation_id,
            .generation = completion.operation_generation,
        }, completion.result);
        var response = try self.session.openBlob(self.token, completion.result);
        defer response.close();
        if (response.length() > model_protocol.max_response_size) return error.ResponseTooLarge;
        const length: usize = @intCast(response.length());
        var buffer: [model_protocol.max_response_size]u8 = undefined;
        const bytes = try response.readWindow(0, buffer[0..length]);
        if (bytes.len != length) return error.TruncatedModelResponse;
        _ = try self.core.reducer.interpretModelResponse(bytes, completion.result);
    }
};

pub fn advanceCreated(
    host: *Host,
    session: *session_store.Session,
    checkpoint_buffer: []u8,
    config: RuntimeConfig,
    provider: model_operation.Provider,
) !u64 {
    const io = session.io;
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    const token = session.ownerToken();
    try core.initialize(session.agent_id);
    try core.reducer.startTask(session.active_leaf_id);
    if (checkpoint_buffer.len != checkpoint.encoded_size) return error.InvalidCheckpointBuffer;
    var task_facts: [2]session_wal.Fact = undefined;
    task_facts[0] = semanticFact(.task_admitted, session);
    task_facts[0].subject = session.task_id;
    task_facts[0].reference = session.task_id;
    task_facts[1] = semanticFact(.conversation_advanced, session);
    task_facts[1].subject = session.active_leaf_id;
    task_facts[1].reference = session.task_id;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        &core,
        &task_facts,
        true,
    );
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        checkpoint_buffer,
        provider,
        1,
        config.completion_hook,
        config.fault,
    );
    return error.CompletionExpected;
}

fn performModelTurn(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    checkpoint_buffer: []u8,
    provider: model_operation.Provider,
    model_sequence: u32,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !OperationIds {
    const ids = try allocateOperationIds(io, session);
    const operation = try core.reducer.beginModelOperation(ids.operation_id, model_sequence);
    const context = try core.reducer.modelContext();
    const operation_generation = operation.generation;
    const descriptor = try model_operation.buildRequest(
        session,
        token,
        ids.request_ref,
        context.first_entry,
        context.entry_count,
    );
    try core.reducer.acceptOperation(.{ .id = ids.operation_id, .generation = operation_generation });
    var admission_facts: [3]session_wal.Fact = undefined;
    admission_facts[0] = semanticFact(.operation_submitted, session);
    admission_facts[0].operation_id = ids.operation_id;
    admission_facts[0].generation = operation_generation;
    admission_facts[0].reference = ids.request_ref;
    admission_facts[0].digest = descriptor.digest;
    admission_facts[1] = admission_facts[0];
    admission_facts[1].kind = .operation_accepted;
    admission_facts[2] = admission_facts[0];
    admission_facts[2].kind = .attempt_admitted;
    admission_facts[2].attempt_id = ids.attempt_id;
    admission_facts[2].recovery_class = .model;
    admission_facts[2].disposition = .possibly_executed;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &admission_facts,
        false,
    );
    core.close();
    core_open.* = false;

    var provider_io = try model_operation.ProviderIo.open(
        session,
        token,
        descriptor.request_ref,
        ids.response_ref,
    );
    defer provider_io.close();
    try provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    );
    try provider_io.ensureResponsePublished();
    try reach(fault, .after_model_dispatch);

    const result_digest = try blobDigest(session, token, ids.response_ref);
    const evidence: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = ids.operation_id,
        .operation_generation = operation_generation,
        .attempt_id = ids.attempt_id,
        .result_ref = ids.response_ref,
        .result_digest = result_digest,
    };
    try session.publishCompletionEvidence(token, evidence);
    try reach(fault, .after_completion_inbox);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn retryModelAttempt(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    checkpoint_buffer: []u8,
    provider: model_operation.Provider,
    completion_hook: ?CompletionHook,
) !void {
    const operation = try core.reducer.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    const descriptor = history.descriptor orelse return error.MissingModelDescriptor;
    var attempt_id: u64 = 0;
    var response_ref: u32 = 0;
    for (0..8) |_| {
        io.random(std.mem.asBytes(&attempt_id));
        io.random(std.mem.asBytes(&response_ref));
        if (attempt_id != 0 and response_ref != 0 and !history.containsAttempt(attempt_id)) {
            break;
        }
    }
    if (attempt_id == 0 or response_ref == 0) return error.OperationIdentityAllocationExhausted;
    var attempt = semanticFact(.attempt_admitted, session);
    attempt.operation_id = operation.id;
    attempt.generation = operation.generation;
    attempt.attempt_id = attempt_id;
    attempt.reference = descriptor.reference;
    attempt.digest = descriptor.digest;
    attempt.recovery_class = .model;
    attempt.disposition = .possibly_executed;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &.{attempt},
        false,
    );
    core.close();
    core_open.* = false;

    var provider_io = try model_operation.ProviderIo.open(
        session,
        token,
        descriptor.reference,
        response_ref,
    );
    defer provider_io.close();
    try provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    );
    try provider_io.ensureResponsePublished();
    const result_digest = try blobDigest(session, token, response_ref);
    const evidence: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = attempt_id,
        .result_ref = response_ref,
        .result_digest = result_digest,
    };
    try session.publishCompletionEvidence(token, evidence);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn executeBashCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    slot_pool: *ProductionSlotPool,
    checkpoint_buffer: []u8,
    ids: OperationIds,
    core_open: *bool,
    workspace_path: []const u8,
    policy: bash_tool.Policy,
    cancellation: ?*const std.atomic.Value(bool),
    approval_hook: ?ApprovalHook,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    const response = try core.reducer.response();
    if (response.tool != .bash) {
        return error.UnsupportedTool;
    }
    const arguments_length = response.arguments.length;
    if (arguments_length == 0 or arguments_length > bash_tool.call_header_size + bash_tool.max_command_size or
        arguments_length > model_protocol.max_response_size)
    {
        return error.InvalidBashCallRange;
    }
    var descriptor_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const descriptor_bytes = try core.reducer.copyResponseWindow(
        response.arguments,
        &descriptor_buffer,
    );
    const call = try bash_tool.decodeCall(descriptor_bytes);
    const digest = bash_tool.descriptorDigest(descriptor_bytes);
    const tool_operation_id = (@as(u64, 1) << 63) | ids.operation_id;
    const descriptor_ref = (@as(u64, 1) << 62) | ids.response_ref;
    const result_ref = (@as(u64, 1) << 61) | ids.response_ref;
    try session.storeBlob(token, descriptor_ref, descriptor_bytes);
    const call_entry = try session.appendConversation(token, .assistant, descriptor_ref, null);
    var descriptor_facts: [3]session_wal.Fact = undefined;
    descriptor_facts[0] = semanticFact(.operation_submitted, session);
    descriptor_facts[0].operation_id = tool_operation_id;
    descriptor_facts[0].generation = 1;
    descriptor_facts[0].reference = descriptor_ref;
    descriptor_facts[0].digest = digest;
    descriptor_facts[0].recovery_class = .consequential;
    descriptor_facts[1] = descriptor_facts[0];
    descriptor_facts[1].kind = .operation_accepted;
    descriptor_facts[2] = semanticFact(.conversation_advanced, session);
    descriptor_facts[2].subject = call_entry.entry_id;
    descriptor_facts[2].reference = descriptor_ref;
    _ = try session.commitSemantic(token, &descriptor_facts, null);

    const classification = try policy.classify_fn(policy.context, digest, call);
    if (classification == .ask) {
        var approval = semanticFact(.authorization, session);
        approval.operation_id = tool_operation_id;
        approval.generation = 1;
        approval.digest = digest;
        try commitCoreFacts(session, token, checkpoint_buffer, core, &.{approval}, true);
        if (approval_hook) |hook| try hook.required(hook.context, .{
            .kind = .bash,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = digest,
            .descriptor_ref = descriptor_ref,
        });
    }
    const allowed = switch (classification) {
        .allow => true,
        .deny => false,
        .ask => try policy.ask_fn(policy.context, digest, call),
    };
    var authorization = semanticFact(.authorization, session);
    authorization.operation_id = tool_operation_id;
    authorization.generation = 1;
    authorization.digest = digest;
    authorization.flags = if (allowed) 1 else 2;
    _ = try session.commitSemantic(token, &.{authorization}, null);

    var attempt_id: u64 = 0;
    var execution: bash_tool.Execution = undefined;
    if (allowed) {
        while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
        var attempt = semanticFact(.attempt_admitted, session);
        attempt.operation_id = tool_operation_id;
        attempt.generation = 1;
        attempt.attempt_id = attempt_id;
        attempt.digest = digest;
        attempt.recovery_class = .consequential;
        attempt.disposition = .possibly_executed;
        try commitCoreFacts(
            session,
            token,
            checkpoint_buffer,
            core,
            &.{attempt},
            false,
        );
        core.close();
        core_open.* = false;
        execution = try bash_tool.executeControlled(
            allocator,
            io,
            workspace_path,
            call,
            .{ .cancelled = cancellation },
        );
        try reach(fault, .after_bash_execution);
        core.* = try Core.open(slot_pool);
        core_open.* = true;
        try restoreCoreFromWal(session, token, checkpoint_buffer, core);
    } else {
        execution = .{
            .allocator = allocator,
            .status = .denied,
            .stdout = try allocator.alloc(u8, 0),
            .stderr = try allocator.alloc(u8, 0),
        };
    }
    defer execution.deinit();
    const result_buffer = try allocator.alloc(u8, bash_tool.result_header_size + 2 * bash_tool.max_output_size);
    defer allocator.free(result_buffer);
    const encoded_result = try bash_tool.encodeResult(result_buffer, execution);
    try session.storeBlob(token, result_ref, encoded_result);
    const result_digest = try blobDigest(session, token, result_ref);
    if (allowed) {
        const evidence: completion_inbox.Envelope = .{
            .kind = .bash,
            .session_id = session.session_id,
            .ownership_epoch = token.epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = result_digest,
        };
        try session.publishCompletionEvidence(token, evidence);
        if (completion_hook) |hook| try hook.offered(hook.context, evidence);
        return error.CompletionOffered;
    }
    try reach(fault, .after_bash_result);
    const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
    try reach(fault, .after_tool_result_entry);
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    var result_facts: [2]session_wal.Fact = undefined;
    result_facts[0] = semanticFact(.result, session);
    result_facts[0].operation_id = tool_operation_id;
    result_facts[0].generation = 1;
    result_facts[0].attempt_id = attempt_id;
    result_facts[0].reference = result_ref;
    result_facts[0].digest = result_digest;
    result_facts[0].flags = @intFromEnum(execution.status);
    result_facts[0].recovery_class = .consequential;
    result_facts[0].disposition = .terminal;
    result_facts[1] = semanticFact(.conversation_advanced, session);
    result_facts[1].subject = result_entry.entry_id;
    result_facts[1].reference = result_ref;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &result_facts,
        true,
    );
    try reach(fault, .after_tool_checkpoint);
}

const PatchPermissionOutcome = enum { ready, approved };

fn requestPatchPermission(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    ids: OperationIds,
    workspace_path: []const u8,
    policy: patch_tool.Policy,
    approval_hook: ?ApprovalHook,
    fault: ?FaultHook,
) !PatchPermissionOutcome {
    const response = try core.reducer.response();
    const arguments_length = response.arguments.length;
    if (arguments_length == 0 or arguments_length > patch_tool.max_patch_size or
        arguments_length > model_protocol.max_response_size)
    {
        return error.InvalidPatchRange;
    }
    var patch_buffer: [patch_tool.max_patch_size]u8 = undefined;
    const patch = try core.reducer.copyResponseWindow(response.arguments, &patch_buffer);
    const validation = try patch_tool.validate(allocator, io, workspace_path, patch);
    const tool_operation_id = (@as(u64, 3) << 62) | ids.operation_id;
    const patch_ref = (@as(u64, 1) << 60) | ids.response_ref;
    const approval_ref = (@as(u64, 1) << 59) | ids.response_ref;
    const permission_ref = (@as(u64, 1) << 58) | ids.response_ref;
    const result_ref = (@as(u64, 1) << 57) | ids.response_ref;
    try session.storeBlob(token, patch_ref, patch);
    const call_entry = try session.appendConversation(token, .assistant, patch_ref, null);
    var descriptor_facts: [3]session_wal.Fact = undefined;
    descriptor_facts[0] = semanticFact(.operation_submitted, session);
    descriptor_facts[0].operation_id = tool_operation_id;
    descriptor_facts[0].generation = 1;
    descriptor_facts[0].reference = patch_ref;
    descriptor_facts[0].digest = validation.patch_digest;
    descriptor_facts[0].recovery_class = .consequential;
    descriptor_facts[1] = descriptor_facts[0];
    descriptor_facts[1].kind = .operation_accepted;
    descriptor_facts[2] = semanticFact(.conversation_advanced, session);
    descriptor_facts[2].subject = call_entry.entry_id;
    descriptor_facts[2].reference = patch_ref;
    _ = try session.commitSemantic(token, &descriptor_facts, null);

    const subject: patch_tool.PermissionSubject = .{
        .operation_id = tool_operation_id,
        .operation_generation = 1,
        .validation = validation,
    };
    const classification = try policy.classify(subject, patch);
    var allowed = classification == .allow;
    if (classification == .ask) {
        try storePatchBinding(
            session,
            token,
            approval_ref,
            .ask,
            tool_operation_id,
            validation,
            patch_ref,
        );
        var approval = semanticFact(.authorization, session);
        approval.operation_id = tool_operation_id;
        approval.generation = 1;
        approval.digest = validation.patch_digest;
        approval.reference = approval_ref;
        try commitCoreFacts(
            session,
            token,
            checkpoint_buffer,
            core,
            &.{approval},
            true,
        );
        if (approval_hook) |hook| try hook.required(hook.context, .{
            .kind = .apply_patch,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = validation.patch_digest,
            .descriptor_ref = patch_ref,
        });
        allowed = try policy.ask(subject, patch);
    }
    const decision: patch_tool.Decision = if (allowed) .allow else .deny;
    try storePatchBinding(
        session,
        token,
        permission_ref,
        decision,
        tool_operation_id,
        validation,
        patch_ref,
    );
    var authorization = semanticFact(.authorization, session);
    authorization.operation_id = tool_operation_id;
    authorization.generation = 1;
    authorization.digest = validation.patch_digest;
    authorization.reference = permission_ref;
    authorization.flags = if (allowed) 1 else 2;
    _ = try session.commitSemantic(token, &.{authorization}, null);
    try reach(fault, .after_patch_permission_binding);

    var status: patch_tool.ResultStatus = .denied;
    var observed_workspace_digest: u64 = 0;
    if (allowed) {
        const observed = patch_tool.validate(allocator, io, workspace_path, patch) catch |err| switch (err) {
            error.FileNotFound,
            error.NotDir,
            error.SymLinkLoop,
            error.AccessDenied,
            error.UnsupportedSpecialFile,
            error.SymlinkEscape,
            error.PatchNotApplicable,
            error.NotTrackedRepositoryFile,
            error.PreimageChangedDuringRead,
            error.PreimageChangedDuringValidation,
            => null,
            else => return err,
        };
        if (observed) |current| {
            observed_workspace_digest = current.workspace_digest;
            if (patch_tool.sameWorkspace(validation, current)) {
                return .approved;
            }
        } else {
            observed_workspace_digest = 1;
        }
        status = .stale;
    }

    var result_bytes: [patch_tool.result_size]u8 = undefined;
    try patch_tool.encodeResult(&result_bytes, .{
        .status = status,
        .patch_digest = validation.patch_digest,
        .expected_workspace_digest = validation.workspace_digest,
        .observed_workspace_digest = observed_workspace_digest,
    });
    try session.storeBlob(token, result_ref, &result_bytes);
    const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    const result_digest = try blobDigest(session, token, result_ref);
    var result_facts: [2]session_wal.Fact = undefined;
    result_facts[0] = semanticFact(.result, session);
    result_facts[0].operation_id = tool_operation_id;
    result_facts[0].generation = 1;
    result_facts[0].reference = result_ref;
    result_facts[0].digest = result_digest;
    result_facts[0].flags = @intFromEnum(status);
    result_facts[0].recovery_class = .consequential;
    result_facts[0].disposition = .terminal;
    result_facts[1] = semanticFact(.conversation_advanced, session);
    result_facts[1].subject = result_entry.entry_id;
    result_facts[1].reference = result_ref;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &result_facts,
        true,
    );
    return .ready;
}

fn storePatchBinding(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    binding_ref: u64,
    decision: patch_tool.Decision,
    operation_id: u64,
    validation: patch_tool.Validation,
    patch_ref: u64,
) !void {
    var bytes: [patch_tool.binding_size]u8 = undefined;
    try patch_tool.encodeBinding(&bytes, .{
        .decision = decision,
        .operation_id = operation_id,
        .operation_generation = 1,
        .ownership_epoch = token.epoch,
        .patch_ref = patch_ref,
        .patch_digest = validation.patch_digest,
        .workspace_digest = validation.workspace_digest,
        .preimage_size = validation.preimage_size,
        .preimage_inode = @intCast(validation.preimage_inode),
        .preimage_digest = validation.preimage_digest,
    });
    try session.storeBlob(token, binding_ref, &bytes);
}

pub fn inspectRestored(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    checkpoint_buffer: []u8,
) !u64 {
    var core = try Core.open(&host.slots);
    defer core.close();
    const token = session.ownerToken();
    if (checkpoint_buffer.len != checkpoint.encoded_size) return error.InvalidCheckpointBuffer;
    try restoreCoreFromWal(session, token, checkpoint_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        const completion = try durableCompletion(session, token, &core);
        var slot: ModelSlot = .{ .core = &core, .session = session, .token = token };
        try ModelSlot.apply(&slot, completion);
        var applied = semanticFact(.result_applied, session);
        applied.operation_id = completion.operation_id;
        applied.generation = completion.operation_generation;
        applied.reference = completion.result;
        try commitCoreFacts(
            session,
            token,
            checkpoint_buffer,
            &core,
            &.{applied},
            true,
        );
        try stageDurableResponse(
            session,
            token,
            &core,
            try core.reducer.response(),
        );
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .final_candidate) {
        const final_ref = try finalizeCandidate(
            session,
            token,
            &core,
            checkpoint_buffer,
            null,
        );
        return final_ref;
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            session,
            token,
            &core,
            checkpoint_buffer,
            allocator,
            session.workspacePath(),
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => return error.SessionNeedsModel,
            .approval_required => return error.PatchApprovalRequired,
            .approved => return error.PatchExecutionDeferred,
            .none => return error.ToolCallDeferred,
        }
    }
    if (outcome == .failed) return modelFailure(@intFromEnum((try core.reducer.response()).failure));
    if (outcome == .ready) {
        if (try hasIndeterminateBash(session, token)) {
            return error.BashPossiblyExecuted;
        }
        return error.SessionNeedsModel;
    }
    if (outcome != .finished) return error.SessionNotFinished;
    const entry_id = (try core.reducer.task()).final_entry_id;
    if (entry_id != session.active_leaf_id) return error.FinalEntryMismatch;
    const entry = try session.readEntry(entry_id);
    if (entry.kind != .assistant) return error.InvalidFinalEntry;
    return entry.content_ref;
}

pub fn advanceRestored(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    checkpoint_buffer: []u8,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const io = session.io;
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    const token = session.ownerToken();
    if (checkpoint_buffer.len != checkpoint.encoded_size) return error.InvalidCheckpointBuffer;
    try restoreCoreFromWal(session, token, checkpoint_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        if (durableCompletion(session, token, &core)) |completion| {
            var slot: ModelSlot = .{
                .core = &core,
                .session = session,
                .token = token,
            };
            try ModelSlot.apply(&slot, completion);
            var applied = semanticFact(.result_applied, session);
            applied.operation_id = completion.operation_id;
            applied.generation = completion.operation_generation;
            applied.reference = completion.result;
            try commitCoreFacts(
                session,
                token,
                checkpoint_buffer,
                &core,
                &.{applied},
                true,
            );
            try stageDurableResponse(
                session,
                token,
                &core,
                try core.reducer.response(),
            );
        } else |err| switch (err) {
            error.SessionOperationPending => try retryModelAttempt(
                io,
                session,
                token,
                &core,
                &core_open,
                checkpoint_buffer,
                provider orelse return error.SessionOperationPending,
                config.completion_hook,
            ),
            else => return err,
        }
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .final_candidate) {
        return finalizeCandidate(
            session,
            token,
            &core,
            checkpoint_buffer,
            null,
        );
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            session,
            token,
            &core,
            checkpoint_buffer,
            allocator,
            session.workspacePath(),
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => outcome = .ready,
            .approval_required => return error.PatchApprovalRequired,
            .approved => return error.PatchExecutionDeferred,
            .none => {
                if (config.settle_only) return error.ToolCallDeferred;
                const observation = try core.reducer.operation();
                const ids: OperationIds = .{
                    .operation_id = @intCast(observation.id),
                    .attempt_id = 0,
                    .request_ref = 0,
                    .response_ref = @truncate(observation.result_ref),
                    .final_ref = finalReference(observation.result_ref),
                };
                switch ((try core.reducer.response()).tool) {
                    .bash => try executeBashCall(
                        io,
                        allocator,
                        session,
                        token,
                        &core,
                        &host.slots,
                        checkpoint_buffer,
                        ids,
                        &core_open,
                        config.workspace_path,
                        config.bash_policy orelse return error.ToolCallDeferred,
                        config.bash_cancelled,
                        config.approval_hook,
                        config.completion_hook,
                        config.fault,
                    ),
                    .apply_patch => {
                        const permission = try requestPatchPermission(
                            io,
                            allocator,
                            session,
                            token,
                            &core,
                            checkpoint_buffer,
                            ids,
                            config.workspace_path,
                            config.patch_policy orelse return error.ToolCallDeferred,
                            config.approval_hook,
                            config.fault,
                        );
                        if (permission == .approved) return error.PatchExecutionDeferred;
                    },
                    else => return error.UnsupportedTool,
                }
                outcome = (try core.reducer.task()).phase;
            },
        }
    }
    if (outcome != .ready) return error.SessionNotReadyForModel;
    if (config.settle_only) return error.SessionNeedsModel;
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        checkpoint_buffer,
        provider orelse return error.SessionNeedsModel,
        2,
        config.completion_hook,
        null,
    );
    if ((try core.reducer.response()).disposition != .final_answer) {
        return error.ResumedModelDidNotFinish;
    }
    const final_ref = try finalizeCandidate(
        session,
        token,
        &core,
        checkpoint_buffer,
        null,
    );
    return final_ref;
}

pub fn resolvePermission(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    checkpoint_buffer: []u8,
    decision: Approval,
    allow: bool,
    provider: ?model_operation.Provider,
    cancellation: ?*const std.atomic.Value(bool),
    completion_hook: ?CompletionHook,
) !u64 {
    const io = session.io;
    const token = session.ownerToken();
    if (checkpoint_buffer.len != checkpoint.encoded_size) return error.InvalidCheckpointBuffer;
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    try restoreCoreFromWal(session, token, checkpoint_buffer, &core);
    if ((try core.reducer.task()).phase != .awaiting_tool) return error.PermissionNoLongerRequired;
    const response = try core.reducer.response();
    const observation = try core.reducer.operation();
    const expected_operation_id = switch (response.tool) {
        .bash => (@as(u64, 1) << 63) | observation.id,
        .apply_patch => (@as(u64, 3) << 62) | observation.id,
        else => return error.UnsupportedTool,
    };
    if (decision.operation_id != expected_operation_id or
        decision.operation_generation != 1)
    {
        return error.StalePermissionDecision;
    }
    var history: FactSearch = .{
        .operation_id = expected_operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    const descriptor = history.descriptor orelse return error.MissingActionDescriptor;
    if (descriptor.digest != decision.descriptor_digest or
        descriptor.reference != decision.descriptor_ref)
    {
        return error.StalePermissionDecision;
    }
    if (history.result != null or history.attempt != null) return error.PermissionNoLongerRequired;
    const pending = history.authorization orelse return error.ApprovalNotCommitted;
    if (pending.flags != 0 or pending.digest != descriptor.digest) return error.PermissionNoLongerRequired;

    switch (response.tool) {
        .bash => {
            var authorization = semanticFact(.authorization, session);
            authorization.operation_id = expected_operation_id;
            authorization.generation = 1;
            authorization.digest = descriptor.digest;
            authorization.flags = if (allow) 1 else 2;
            _ = try session.commitSemantic(token, &.{authorization}, null);
            var descriptor_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
            var reader = try session.openBlob(token, descriptor.reference);
            defer reader.close();
            if (reader.length() > descriptor_buffer.len) return error.InvalidBashCallRange;
            const descriptor_length: usize = @intCast(reader.length());
            const descriptor_bytes = try reader.readWindow(0, descriptor_buffer[0..descriptor_length]);
            if (descriptor_bytes.len != descriptor_length) return error.TruncatedBashDescriptor;
            const call = try bash_tool.decodeCall(descriptor_bytes);
            const result_ref = (@as(u64, 1) << 61) | @as(u32, @truncate(observation.result_ref));
            var attempt_id: u64 = 0;
            var execution: bash_tool.Execution = undefined;
            if (allow) {
                while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
                var attempt = semanticFact(.attempt_admitted, session);
                attempt.operation_id = expected_operation_id;
                attempt.generation = 1;
                attempt.attempt_id = attempt_id;
                attempt.digest = descriptor.digest;
                attempt.recovery_class = .consequential;
                attempt.disposition = .possibly_executed;
                try commitCoreFacts(session, token, checkpoint_buffer, &core, &.{attempt}, false);
                core.close();
                core_open = false;
                execution = try bash_tool.executeControlled(
                    allocator,
                    io,
                    session.workspacePath(),
                    call,
                    .{ .cancelled = cancellation },
                );
                core = try Core.open(&host.slots);
                core_open = true;
                try restoreCoreFromWal(session, token, checkpoint_buffer, &core);
            } else {
                execution = .{
                    .allocator = allocator,
                    .status = .denied,
                    .stdout = try allocator.alloc(u8, 0),
                    .stderr = try allocator.alloc(u8, 0),
                };
            }
            defer execution.deinit();
            const result_buffer = try allocator.alloc(u8, bash_tool.result_header_size + 2 * bash_tool.max_output_size);
            defer allocator.free(result_buffer);
            const encoded = try bash_tool.encodeResult(result_buffer, execution);
            try session.storeBlob(token, result_ref, encoded);
            const result_digest = try blobDigest(session, token, result_ref);
            if (allow) {
                const evidence: completion_inbox.Envelope = .{
                    .kind = .bash,
                    .session_id = session.session_id,
                    .ownership_epoch = token.epoch,
                    .agent_id = session.agent_id,
                    .agent_generation = agent_generation,
                    .operation_id = expected_operation_id,
                    .operation_generation = 1,
                    .attempt_id = attempt_id,
                    .result_ref = result_ref,
                    .result_digest = result_digest,
                };
                try session.publishCompletionEvidence(token, evidence);
                if (completion_hook) |hook| try hook.offered(hook.context, evidence);
                return error.CompletionOffered;
            }
            const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
            try core.reducer.commitToolResult(session.active_leaf_id, result_entry.entry_id);
            var facts: [2]session_wal.Fact = undefined;
            facts[0] = semanticFact(.result, session);
            facts[0].operation_id = expected_operation_id;
            facts[0].generation = 1;
            facts[0].attempt_id = attempt_id;
            facts[0].reference = result_ref;
            facts[0].digest = result_digest;
            facts[0].flags = @intFromEnum(execution.status);
            facts[0].recovery_class = .consequential;
            facts[0].disposition = .terminal;
            facts[1] = semanticFact(.conversation_advanced, session);
            facts[1].subject = result_entry.entry_id;
            facts[1].reference = result_ref;
            try commitCoreFacts(session, token, checkpoint_buffer, &core, &facts, false);
        },
        .apply_patch => {
            var binding_bytes: [patch_tool.binding_size]u8 = undefined;
            var binding_reader = try session.openBlob(token, pending.reference);
            defer binding_reader.close();
            if (binding_reader.length() != binding_bytes.len or
                (try binding_reader.readWindow(0, &binding_bytes)).len != binding_bytes.len)
            {
                return error.InvalidPatchBinding;
            }
            const binding = try patch_tool.decodeBinding(&binding_bytes);
            if (binding.operation_id != expected_operation_id or
                binding.operation_generation != 1 or
                binding.patch_ref != descriptor.reference or
                binding.patch_digest != descriptor.digest)
            {
                return error.StalePermissionDecision;
            }
            const permission_ref = (@as(u64, 1) << 58) | @as(u32, @truncate(observation.result_ref));
            try storePatchBinding(
                session,
                token,
                permission_ref,
                if (allow) .allow else .deny,
                expected_operation_id,
                .{
                    .target_path = "",
                    .patch_digest = binding.patch_digest,
                    .preimage_digest = binding.preimage_digest,
                    .workspace_digest = binding.workspace_digest,
                    .preimage_size = binding.preimage_size,
                    .preimage_inode = @intCast(binding.preimage_inode),
                },
                binding.patch_ref,
            );
            var authorization = semanticFact(.authorization, session);
            authorization.operation_id = expected_operation_id;
            authorization.generation = 1;
            authorization.digest = descriptor.digest;
            authorization.reference = permission_ref;
            authorization.flags = if (allow) 1 else 2;
            _ = try session.commitSemantic(token, &.{authorization}, null);
            if (allow) return error.PatchExecutionDeferred;
            const result_ref = (@as(u64, 1) << 57) | @as(u32, @truncate(observation.result_ref));
            var result_bytes: [patch_tool.result_size]u8 = undefined;
            try patch_tool.encodeResult(&result_bytes, .{
                .status = .denied,
                .patch_digest = descriptor.digest,
                .expected_workspace_digest = binding.workspace_digest,
                .observed_workspace_digest = 0,
            });
            try session.storeBlob(token, result_ref, &result_bytes);
            const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
            try core.reducer.commitToolResult(session.active_leaf_id, result_entry.entry_id);
            var facts: [2]session_wal.Fact = undefined;
            facts[0] = semanticFact(.result, session);
            facts[0].operation_id = expected_operation_id;
            facts[0].generation = 1;
            facts[0].reference = result_ref;
            facts[0].digest = try blobDigest(session, token, result_ref);
            facts[0].flags = @intFromEnum(patch_tool.ResultStatus.denied);
            facts[0].recovery_class = .consequential;
            facts[0].disposition = .terminal;
            facts[1] = semanticFact(.conversation_advanced, session);
            facts[1].subject = result_entry.entry_id;
            facts[1].reference = result_ref;
            try commitCoreFacts(session, token, checkpoint_buffer, &core, &facts, false);
        },
        else => unreachable,
    }
    core.close();
    core_open = false;
    const next_provider = provider orelse return error.SessionNeedsModel;
    return advanceRestored(
        host,
        allocator,
        session,
        checkpoint_buffer,
        .{
            .workspace_path = session.workspacePath(),
            .bash_cancelled = cancellation,
            .completion_hook = completion_hook,
        },
        next_provider,
    );
}

pub fn acceptCompletion(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    checkpoint_buffer: []u8,
    offered: completion_inbox.Envelope,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const token = session.ownerToken();
    if (offered.session_id != session.session_id or offered.agent_id != session.agent_id or
        offered.agent_generation != agent_generation or
        offered.ownership_epoch > token.epoch)
    {
        return error.StaleCompletion;
    }
    var history: FactSearch = .{
        .operation_id = offered.operation_id,
        .generation = offered.operation_generation,
        .target_attempt_id = offered.attempt_id,
        .recovery_class = switch (offered.kind) {
            .model => .model,
            .bash, .apply_patch => .consequential,
        },
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    const attempt = history.attempt orelse return error.StaleCompletion;
    if (attempt.attempt_id != offered.attempt_id) return error.StaleCompletion;
    if (history.result) |result| {
        if (result.reference != offered.result_ref or result.digest != offered.result_digest) {
            return error.ConflictingCompletionEvidence;
        }
    }
    var inbox: InboxSearch = .{
        .session_id = offered.session_id,
        .agent_id = offered.agent_id,
        .operation_id = offered.operation_id,
        .operation_generation = offered.operation_generation,
        .attempt_id = offered.attempt_id,
        .maximum_epoch = token.epoch,
    };
    _ = try session.scanCompletionEvidence(token, &inbox, InboxSearch.apply);
    const evidence = inbox.match orelse return error.CompletionEvidenceMissing;
    if (evidence.result_ref != offered.result_ref or evidence.result_digest != offered.result_digest) {
        return error.ConflictingCompletionEvidence;
    }
    return advanceRestored(host, allocator, session, checkpoint_buffer, config, provider);
}

const ToolRecovery = enum { none, ready, indeterminate, approval_required, approved };

fn reconcileToolCall(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
) !ToolRecovery {
    return switch ((try core.reducer.response()).tool) {
        .bash => reconcileBash(session, token, core, checkpoint_buffer),
        .apply_patch => reconcilePatch(
            session,
            token,
            core,
            checkpoint_buffer,
            allocator,
            workspace_path,
        ),
        else => error.UnsupportedTool,
    };
}

fn reconcileBash(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
) !ToolRecovery {
    const model_observation = try core.reducer.operation();
    const operation_id = (@as(u64, 1) << 63) | model_observation.id;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    const descriptor = history.descriptor orelse return .none;
    if (history.result) |result| {
        try reconcileBashResult(
            session,
            token,
            core,
            checkpoint_buffer,
            recordFromFact(result),
        );
        return if (result.flags == @intFromEnum(bash_tool.Status.indeterminate))
            .indeterminate
        else
            .ready;
    }
    const attempt = history.attempt orelse {
        const authorization = history.authorization orelse return .none;
        if (authorization.flags == 0) return .approval_required;
        if (authorization.flags != 2) return .none;
        const response_ref: u32 = @truncate(model_observation.result_ref);
        const result_ref = (@as(u64, 1) << 61) | response_ref;
        var empty: [0]u8 = .{};
        const execution: bash_tool.Execution = .{
            .allocator = undefined,
            .status = .denied,
            .stdout = &empty,
            .stderr = &empty,
        };
        var encoded: [bash_tool.result_header_size]u8 = undefined;
        _ = try bash_tool.encodeResult(&encoded, execution);
        try storeOrExpectBlob(session, token, result_ref, &encoded);
        var denied = semanticFact(.result, session);
        denied.operation_id = operation_id;
        denied.generation = 1;
        denied.reference = result_ref;
        denied.digest = try blobDigest(session, token, result_ref);
        denied.flags = @intFromEnum(bash_tool.Status.denied);
        denied.recovery_class = .consequential;
        denied.disposition = .terminal;
        _ = try session.commitSemantic(token, &.{denied}, null);
        try reconcileBashResult(
            session,
            token,
            core,
            checkpoint_buffer,
            recordFromFact(denied),
        );
        return .ready;
    };
    var inbox: InboxSearch = .{
        .session_id = session.session_id,
        .agent_id = session.agent_id,
        .operation_id = operation_id,
        .operation_generation = 1,
        .attempt_id = attempt.attempt_id,
        .maximum_epoch = token.epoch,
    };
    _ = try session.scanCompletionEvidence(token, &inbox, InboxSearch.apply);
    var result = semanticFact(.result, session);
    result.operation_id = operation_id;
    result.generation = 1;
    result.attempt_id = attempt.attempt_id;
    result.recovery_class = .consequential;
    result.disposition = .terminal;
    result.digest = descriptor.digest;
    if (inbox.match) |envelope| {
        if (try blobDigest(session, token, envelope.result_ref) != envelope.result_digest) {
            return error.CompletionResultDigestMismatch;
        }
        result.reference = envelope.result_ref;
        result.digest = envelope.result_digest;
        result.ownership_epoch = envelope.ownership_epoch;
        result.flags = @intFromEnum(try readBashStatus(session, token, envelope.result_ref));
    } else {
        const response_ref: u32 = @truncate(model_observation.result_ref);
        result.reference = (@as(u64, 1) << 61) | response_ref;
        var empty: [0]u8 = .{};
        const execution: bash_tool.Execution = .{
            .allocator = undefined,
            .status = .indeterminate,
            .stdout = &empty,
            .stderr = &empty,
        };
        var encoded: [bash_tool.result_header_size]u8 = undefined;
        _ = try bash_tool.encodeResult(&encoded, execution);
        try storeOrExpectBlob(session, token, result.reference, &encoded);
        result.digest = try blobDigest(session, token, result.reference);
        result.flags = @intFromEnum(bash_tool.Status.indeterminate);
    }
    _ = try session.commitSemantic(token, &.{result}, null);
    try reconcileBashResult(
        session,
        token,
        core,
        checkpoint_buffer,
        recordFromFact(result),
    );
    return if (result.flags == @intFromEnum(bash_tool.Status.indeterminate))
        .indeterminate
    else
        .ready;
}

fn readBashStatus(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    reference: u64,
) !bash_tool.Status {
    var reader = try session.openBlob(token, reference);
    defer reader.close();
    if (reader.length() < bash_tool.result_header_size) return error.TruncatedBashResult;
    var header: [bash_tool.result_header_size]u8 = undefined;
    const bytes = try reader.readWindow(0, &header);
    if (bytes.len != header.len) return error.TruncatedBashResult;
    return bash_tool.decodeResultHeader(&header, reader.length());
}

fn recordFromFact(fact: session_wal.Fact) ToolResult {
    return .{
        .agent_id = fact.agent_id,
        .agent_generation = fact.agent_generation,
        .operation_id = fact.operation_id,
        .operation_generation = fact.generation,
        .attempt_id = fact.attempt_id,
        .ownership_epoch = fact.ownership_epoch,
        .descriptor_digest = fact.digest,
        .result = fact.reference,
    };
}

fn reconcilePatch(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
) !ToolRecovery {
    const operation_observation = try core.reducer.operation();
    const model_operation_id = operation_observation.id;
    const response_ref: u32 = @truncate(operation_observation.result_ref);
    const operation_id = (@as(u64, 3) << 62) | model_operation_id;
    const patch_ref = (@as(u64, 1) << 60) | response_ref;
    const result_ref = (@as(u64, 1) << 57) | response_ref;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    const validated = history.descriptor orelse return .none;
    if (validated.digest == 0 or validated.reference != patch_ref) {
        return error.InvalidPatchHistory;
    }
    if (history.result) |settled| {
        if (settled.reference != result_ref) {
            return error.InvalidPatchHistory;
        }
        try reconcileToolResult(
            session,
            token,
            core,
            checkpoint_buffer,
            patch_ref,
            recordFromFact(settled),
        );
        return .ready;
    }
    const authorization = history.authorization orelse return .none;
    if (authorization.flags == 0) return .approval_required;
    if (authorization.digest != validated.digest or authorization.reference == 0) {
        return error.InvalidPatchHistory;
    }
    var binding_bytes: [patch_tool.binding_size]u8 = undefined;
    try readExactBlob(session, token, authorization.reference, &binding_bytes);
    const binding = try patch_tool.decodeBinding(&binding_bytes);
    if (binding.operation_id != operation_id or binding.operation_generation != 1 or
        binding.patch_ref != patch_ref or binding.patch_digest != validated.digest)
    {
        return error.InvalidPatchPermissionBinding;
    }
    if ((authorization.flags == 1 and binding.decision != .allow) or
        (authorization.flags == 2 and binding.decision != .deny))
    {
        return error.InvalidPatchHistory;
    }
    if (binding.decision == .allow) {
        var patch_buffer: [patch_tool.max_patch_size]u8 = undefined;
        const patch = try readBoundedBlob(session, token, patch_ref, &patch_buffer);
        const target_path = try patch_tool.validateStructure(patch);
        const expected: patch_tool.Validation = .{
            .target_path = target_path,
            .patch_digest = binding.patch_digest,
            .preimage_digest = binding.preimage_digest,
            .workspace_digest = binding.workspace_digest,
            .preimage_size = binding.preimage_size,
            .preimage_inode = @intCast(binding.preimage_inode),
        };
        const observed = patch_tool.validate(allocator, session.io, workspace_path, patch) catch null;
        if (observed) |current| {
            if (patch_tool.sameWorkspace(expected, current)) return .approved;
        }
        const observed_digest = if (observed) |current| current.workspace_digest else 1;
        try persistPatchPreflightResult(
            session,
            token,
            core,
            checkpoint_buffer,
            operation_id,
            patch_ref,
            result_ref,
            validated.digest,
            .stale,
            binding.workspace_digest,
            observed_digest,
        );
        return .ready;
    }
    try persistPatchPreflightResult(
        session,
        token,
        core,
        checkpoint_buffer,
        operation_id,
        patch_ref,
        result_ref,
        validated.digest,
        .denied,
        binding.workspace_digest,
        0,
    );
    return .ready;
}

const ToolResult = struct {
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    ownership_epoch: u64,
    descriptor_digest: u64,
    result: u64,
};

fn persistPatchPreflightResult(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    operation_id: u64,
    patch_ref: u64,
    result_ref: u64,
    descriptor_digest: u64,
    status: patch_tool.ResultStatus,
    expected_workspace_digest: u64,
    observed_workspace_digest: u64,
) !void {
    var result_bytes: [patch_tool.result_size]u8 = undefined;
    try patch_tool.encodeResult(&result_bytes, .{
        .status = status,
        .patch_digest = descriptor_digest,
        .expected_workspace_digest = expected_workspace_digest,
        .observed_workspace_digest = observed_workspace_digest,
    });
    try storeOrExpectBlob(session, token, result_ref, &result_bytes);
    var terminal = semanticFact(.result, session);
    terminal.operation_id = operation_id;
    terminal.generation = 1;
    terminal.reference = result_ref;
    terminal.digest = try blobDigest(session, token, result_ref);
    terminal.flags = @intFromEnum(status);
    terminal.recovery_class = .consequential;
    terminal.disposition = .terminal;
    _ = try session.commitSemantic(token, &.{terminal}, null);
    try reconcileToolResult(
        session,
        token,
        core,
        checkpoint_buffer,
        patch_ref,
        .{
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = 0,
            .ownership_epoch = token.epoch,
            .descriptor_digest = descriptor_digest,
            .result = result_ref,
        },
    );
}

fn reconcileBashResult(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    result: ToolResult,
) !void {
    const response_ref: u32 = @truncate(result.result);
    if (result.result != ((@as(u64, 1) << 61) | response_ref)) return error.InvalidToolResultReference;
    const descriptor_ref = (@as(u64, 1) << 62) | response_ref;
    try reconcileToolResult(session, token, core, checkpoint_buffer, descriptor_ref, result);
}

fn reconcileToolResult(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    descriptor_ref: u64,
    result: ToolResult,
) !void {
    const active = try session.readEntry(session.active_leaf_id);
    var call_entry: session_store.ConversationEntry = undefined;
    var result_entry: session_store.ConversationEntry = undefined;
    if (active.kind == .tool_result and active.content_ref == result.result) {
        result_entry = active;
        call_entry = try session.readEntry(active.parent_id);
    } else if (active.kind == .assistant and active.content_ref == descriptor_ref) {
        call_entry = active;
        result_entry = try session.appendConversation(token, .tool_result, result.result, null);
    } else {
        return error.ToolConversationMismatch;
    }
    if (call_entry.kind != .assistant or call_entry.content_ref != descriptor_ref or
        result_entry.parent_id != call_entry.entry_id)
    {
        return error.ToolConversationMismatch;
    }
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    var applied_facts: [2]session_wal.Fact = undefined;
    applied_facts[0] = semanticFact(.result_applied, session);
    applied_facts[0].operation_id = result.operation_id;
    applied_facts[0].generation = result.operation_generation;
    applied_facts[0].attempt_id = result.attempt_id;
    applied_facts[0].reference = result.result;
    applied_facts[0].digest = try blobDigest(session, token, result.result);
    applied_facts[0].recovery_class = .consequential;
    applied_facts[1] = semanticFact(.conversation_advanced, session);
    applied_facts[1].subject = result_entry.entry_id;
    applied_facts[1].reference = result.result;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &applied_facts,
        true,
    );
}

fn durableCompletion(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
) !ModelCompletion {
    const operation = try core.reducer.operation();
    const operation_id = operation.id;
    const operation_generation = operation.generation;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = operation_generation,
        .recovery_class = .model,
    };
    _ = try session.replaySemantic(token, &history, FactSearch.applyTransaction);
    if (history.attempt_count == 0) return error.MissingAcceptedAttempt;
    var intent: ?session_wal.Fact = null;
    var result = history.result;
    if (result) |completed| {
        for (history.attemptSlice()) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            if (attempt.attempt_id == completed.attempt_id) {
                intent = attempt;
                break;
            }
        }
    } else {
        var matched_envelope: ?completion_inbox.Envelope = null;
        for (history.attemptSlice()) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            var inbox: InboxSearch = .{
                .session_id = session.session_id,
                .agent_id = session.agent_id,
                .operation_id = operation_id,
                .operation_generation = operation_generation,
                .attempt_id = attempt.attempt_id,
                .maximum_epoch = token.epoch,
            };
            _ = try session.scanCompletionEvidence(token, &inbox, InboxSearch.apply);
            if (inbox.match) |envelope| {
                intent = attempt;
                matched_envelope = envelope;
                break;
            }
        }
        const envelope = matched_envelope orelse return error.SessionOperationPending;
        if (try blobDigest(session, token, envelope.result_ref) != envelope.result_digest) {
            return error.CompletionResultDigestMismatch;
        }
        var terminal = semanticFact(.result, session);
        terminal.operation_id = operation_id;
        terminal.generation = operation_generation;
        terminal.attempt_id = intent.?.attempt_id;
        terminal.recovery_class = .model;
        terminal.disposition = .terminal;
        terminal.reference = envelope.result_ref;
        terminal.digest = envelope.result_digest;
        terminal.ownership_epoch = envelope.ownership_epoch;
        _ = try session.commitSemantic(token, &.{terminal}, null);
        result = terminal;
    }
    const accepted = intent orelse return error.InvalidOperationHistory;
    const completed = result.?;
    if (completed.attempt_id != accepted.attempt_id or
        completed.digest == 0 or completed.reference == 0)
    {
        return error.InvalidOperationHistory;
    }
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = accepted.ownership_epoch,
        .result = completed.reference,
    };
}

const FactSearch = struct {
    const max_attempts = 8;

    operation_id: u64,
    generation: u32,
    recovery_class: session_wal.RecoveryClass,
    descriptor: ?session_wal.Fact = null,
    attempt: ?session_wal.Fact = null,
    attempts: [max_attempts]?session_wal.Fact = @splat(null),
    attempt_count: u8 = 0,
    target_attempt_id: u64 = 0,
    authorization: ?session_wal.Fact = null,
    result: ?session_wal.Fact = null,

    fn applyTransaction(context: *anyopaque, transaction: session_wal.Transaction) anyerror!void {
        const self: *FactSearch = @ptrCast(@alignCast(context));
        for (transaction.factSlice()) |fact| {
            if (fact.operation_id != self.operation_id or fact.generation != self.generation) continue;
            if (fact.recovery_class != .none and fact.recovery_class != self.recovery_class) continue;
            switch (fact.kind) {
                .operation_submitted => self.descriptor = try uniqueFact(self.descriptor, fact),
                .attempt_admitted => {
                    var found = false;
                    for (self.attempts[0..self.attempt_count]) |maybe_existing| {
                        const existing = maybe_existing.?;
                        if (existing.attempt_id != fact.attempt_id) continue;
                        if (!std.meta.eql(existing, fact)) return error.ConflictingWalFacts;
                        found = true;
                        break;
                    }
                    if (!found) {
                        if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
                        self.attempts[self.attempt_count] = fact;
                        self.attempt_count += 1;
                    }
                    if (self.target_attempt_id == 0 or self.target_attempt_id == fact.attempt_id) {
                        self.attempt = fact;
                    }
                },
                .authorization => self.authorization = fact,
                .result => self.result = try uniqueFact(self.result, fact),
                else => {},
            }
        }
    }

    fn attemptSlice(self: *const FactSearch) []const ?session_wal.Fact {
        return self.attempts[0..self.attempt_count];
    }

    fn containsAttempt(self: *const FactSearch, attempt_id: u64) bool {
        for (self.attemptSlice()) |maybe_attempt| {
            if (maybe_attempt.?.attempt_id == attempt_id) return true;
        }
        return false;
    }
};

pub fn pendingApproval(session: *session_store.Session) !?Approval {
    var search: PendingApprovalSearch = .{};
    _ = try session.replaySemantic(
        session.ownerToken(),
        &search,
        PendingApprovalSearch.applyTransaction,
    );
    return search.approval;
}

const PendingApprovalSearch = struct {
    approval: ?Approval = null,

    fn applyTransaction(context: *anyopaque, transaction: session_wal.Transaction) anyerror!void {
        const self: *PendingApprovalSearch = @ptrCast(@alignCast(context));
        for (transaction.factSlice()) |fact| switch (fact.kind) {
            .operation_submitted => if (fact.recovery_class == .consequential) {
                self.approval = .{
                    .kind = if ((fact.operation_id >> 62) == 3) .apply_patch else .bash,
                    .operation_id = fact.operation_id,
                    .operation_generation = fact.generation,
                    .descriptor_digest = fact.digest,
                    .descriptor_ref = fact.reference,
                };
            },
            .authorization => if (self.approval) |approval| {
                if (approval.operation_id == fact.operation_id and
                    approval.operation_generation == fact.generation and fact.flags != 0)
                {
                    self.approval = null;
                }
            },
            .attempt_admitted, .result => if (self.approval) |approval| {
                if (approval.operation_id == fact.operation_id and
                    approval.operation_generation == fact.generation)
                {
                    self.approval = null;
                }
            },
            else => {},
        };
    }
};

const InboxSearch = struct {
    session_id: u64,
    agent_id: u64,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    maximum_epoch: u64,
    match: ?completion_inbox.Envelope = null,

    fn apply(context: *anyopaque, envelope: completion_inbox.Envelope) anyerror!void {
        const self: *InboxSearch = @ptrCast(@alignCast(context));
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id or
            envelope.operation_id != self.operation_id or
            envelope.operation_generation != self.operation_generation or
            envelope.attempt_id != self.attempt_id)
        {
            return;
        }
        if (envelope.ownership_epoch > self.maximum_epoch) return error.FutureCompletionEpoch;
        if (self.match) |existing| {
            if (!std.meta.eql(existing, envelope)) return error.ConflictingCompletionEvidence;
            return;
        }
        self.match = envelope;
    }
};

fn uniqueFact(existing: ?session_wal.Fact, fact: session_wal.Fact) !session_wal.Fact {
    if (existing) |value| {
        if (!std.meta.eql(value, fact)) return error.ConflictingWalFacts;
        return value;
    }
    return fact;
}

fn hasIndeterminateBash(
    session: *session_store.Session,
    token: session_store.OwnerToken,
) !bool {
    var found = false;
    _ = try session.replaySemantic(token, &found, detectIndeterminate);
    return found;
}

fn detectIndeterminate(context: *anyopaque, transaction: session_wal.Transaction) anyerror!void {
    const found: *bool = @ptrCast(@alignCast(context));
    for (transaction.factSlice()) |fact| {
        if (fact.kind == .result and fact.recovery_class == .consequential and
            fact.flags == @intFromEnum(bash_tool.Status.indeterminate))
        {
            found.* = true;
        }
    }
}

fn finalizeCandidate(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    fault: ?FaultHook,
) !u64 {
    const task = try core.reducer.task();
    const response = try core.reducer.response();
    if (task.phase != .final_candidate or response.disposition != .final_answer) {
        return error.FinalAnswerNotCandidate;
    }
    try stageDurableResponse(session, token, core, response);
    var final_buffer: [model_protocol.max_response_size]u8 = undefined;
    const expected = try core.reducer.copyResponseWindow(response.text, &final_buffer);
    if (expected.len == 0) {
        return error.InvalidFinalAnswerRange;
    }
    const response_ref = response.content_ref;
    if (response_ref == 0) return error.InvalidModelResponseReference;
    const final_ref = finalReference(response_ref);

    var final_blob = session.openBlob(token, final_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try session.storeBlob(token, final_ref, expected);
            break :blk try session.openBlob(token, final_ref);
        },
        else => return err,
    };
    defer final_blob.close();
    try expectBlob(&final_blob, expected);
    try reach(fault, .after_final_blob);

    var entry = try session.readEntry(session.active_leaf_id);
    if (entry.kind != .assistant or entry.content_ref != final_ref) {
        entry = try session.appendConversation(token, .assistant, final_ref, null);
    }
    try reach(fault, .after_assistant_entry);
    try core.reducer.commitFinalAnswer(entry.entry_id);
    var final_facts: [2]session_wal.Fact = undefined;
    final_facts[0] = semanticFact(.conversation_advanced, session);
    final_facts[0].subject = entry.entry_id;
    final_facts[0].reference = final_ref;
    final_facts[1] = semanticFact(.outcome, session);
    final_facts[1].subject = session.task_id;
    final_facts[1].reference = final_ref;
    try commitCoreFacts(
        session,
        token,
        checkpoint_buffer,
        core,
        &final_facts,
        true,
    );
    return final_ref;
}

fn stageDurableResponse(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    response: core_image.Response,
) !void {
    var blob = try session.openBlob(token, response.content_ref);
    defer blob.close();
    if (blob.length() == 0 or blob.length() > model_protocol.max_response_size) {
        return error.ResponseTooLarge;
    }
    var buffer: [model_protocol.max_response_size]u8 = undefined;
    const length: usize = @intCast(blob.length());
    const bytes = try blob.readWindow(0, buffer[0..length]);
    if (bytes.len != length) return error.TruncatedModelResponse;
    try core.reducer.stageResponse(bytes, response.content_ref);
}

fn reach(fault: ?FaultHook, boundary: FaultBoundary) !void {
    if (fault) |hook| try hook.reached(hook.context, boundary);
}

fn expectBlob(reader: *session_store.BlobReader, expected: []const u8) !void {
    if (reader.length() != expected.len) return error.FinalAnswerBlobMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, expected[offset..][0..actual.len])) {
            return error.FinalAnswerBlobMismatch;
        }
        offset += actual.len;
    }
}

fn readExactBlob(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    reference: u64,
    out: []u8,
) !void {
    var reader = try session.openBlob(token, reference);
    defer reader.close();
    if (reader.length() != out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out);
    if (bytes.len != out.len) return error.TruncatedBlob;
}

fn readBoundedBlob(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    reference: u64,
    out: []u8,
) ![]const u8 {
    var reader = try session.openBlob(token, reference);
    defer reader.close();
    if (reader.length() == 0 or reader.length() > out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out[0..@intCast(reader.length())]);
    if (bytes.len != reader.length()) return error.TruncatedBlob;
    return bytes;
}

fn storeOrExpectBlob(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    reference: u64,
    bytes: []const u8,
) !void {
    var reader = session.openBlob(token, reference) catch |err| switch (err) {
        error.FileNotFound => {
            try session.storeBlob(token, reference, bytes);
            return;
        },
        else => return err,
    };
    defer reader.close();
    if (reader.length() != bytes.len) return error.BlobContentMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, bytes[offset..][0..actual.len])) {
            return error.BlobContentMismatch;
        }
        offset += actual.len;
    }
}

fn blobDigest(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    reference: u64,
) !u64 {
    var reader = try session.openBlob(token, reference);
    defer reader.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var window: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedBlob;
        hasher.update(bytes);
        offset += bytes.len;
    }
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    var digest = std.mem.readInt(u64, digest_bytes[0..8], .little);
    if (digest == 0) digest = 1;
    return digest;
}

fn allocateOperationIds(io: std.Io, session: *const session_store.Session) !OperationIds {
    for (0..8) |_| {
        var ids: OperationIds = undefined;
        io.random(std.mem.asBytes(&ids));
        ids.final_ref = finalReference(ids.response_ref);
        if (ids.operation_id == 0 or ids.attempt_id == 0 or ids.request_ref == 0 or
            ids.response_ref == 0)
        {
            continue;
        }
        const values = [_]u64{
            ids.operation_id,
            ids.attempt_id,
            ids.request_ref,
            ids.response_ref,
            ids.final_ref,
            session.task_id,
        };
        var distinct = true;
        for (values, 0..) |value, index| {
            for (values[index + 1 ..]) |other| distinct = distinct and value != other;
        }
        if (distinct) return ids;
    }
    return error.OperationIdentityAllocationExhausted;
}

fn modelFailure(value: u32) anyerror {
    return switch (value) {
        1 => error.ModelResponseTruncated,
        2 => error.ModelResponseAborted,
        3 => error.ModelProviderFailed,
        4 => error.MalformedModelResponse,
        5 => error.EmptyModelResponse,
        6 => error.MultipleModelTools,
        else => error.UnknownModelFailure,
    };
}
