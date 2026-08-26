const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

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
    approval_required_hook: ?ApprovalRequiredHook = null,
    completion_hook: ?CompletionHook = null,
    settle_only: bool = false,
};

pub const ApprovalRequiredKind = enum { bash, apply_patch };

pub const ApprovalRequired = struct {
    kind: ApprovalRequiredKind,
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: u64,
    descriptor_ref: u64,
};

pub const ApprovalRequiredHook = struct {
    context: *anyopaque,
    required: *const fn (*anyopaque, ApprovalRequired) anyerror!void,
};

pub const CompletionHook = struct {
    context: *anyopaque,
    offered: *const fn (*anyopaque, completion_inbox.Envelope) anyerror!void,
};

pub const Control = enum { cancel, shutdown };

pub fn commitControl(session: *session_store.Session, control: Control) !void {
    const token = session.ownerToken();
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(token, &state, ControlSearch.applyFact);
    if (state.open_operation) return error.AcceptedOperationUnsettled;
    const agent = agentContext(session);
    const fact = if (control == .cancel)
        session_transition.cancellation(agent)
    else
        session_transition.shutdown(agent);
    _ = try session.commitSemantic(token, &.{fact}, null);
}

pub fn restoredControl(session: *session_store.Session) !?Control {
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(session.ownerToken(), &state, ControlSearch.applyFact);
    return state.control;
}

const ControlSearch = struct {
    open_operation: bool = false,
    operation_id: u64 = 0,
    generation: u32 = 0,
    control: ?Control = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *ControlSearch = @ptrCast(@alignCast(context));
        switch (fact.kind()) {
            .operation_accepted => {
                self.open_operation = true;
                self.operation_id = fact.operationId();
                self.generation = fact.generation();
            },
            .result => if (self.open_operation and self.operation_id == fact.operationId() and
                self.generation == fact.generation())
            {
                self.open_operation = false;
            },
            .cancellation => self.control = .cancel,
            .shutdown => self.control = .shutdown,
            else => {},
        }
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
    after_tool_state_commit,
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

const ModelDispatch = struct {
    request_ref: u64,
    response_ref: u64,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
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
    core_state_buffer: []u8,
    core: *Core,
    facts: []const session_transition.Fact,
    reactivate: bool,
) !void {
    _ = core_state_buffer;
    try core.suspendIntoState();
    _ = try session.commitSemantic(token, facts, &core.encoded_state);
    if (reactivate) try core.activate();
}

fn agentContext(session: *const session_store.Session) session_transition.AgentContext {
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .ownership_epoch = session.ownership_epoch,
    };
}

fn operationContext(
    session: *const session_store.Session,
    operation_id: u64,
    generation: u32,
) session_transition.OperationContext {
    return .{ .agent = agentContext(session), .operation_id = operation_id, .generation = generation };
}

fn restoreCoreFromLedger(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core_state_buffer: []u8,
    core: *Core,
) !void {
    _ = core_state_buffer;
    var replay_context: u8 = 0;
    const replay = try session.inspectSemantic(
        token,
        &replay_context,
        ignoreFact,
    );
    core.encoded_state = replay.last_core orelse return error.MissingLedgerCoreState;
    try core.activate();
}

fn ignoreFact(_: *anyopaque, _: session_transition.Fact) anyerror!void {}

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
    core_state_buffer: []u8,
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
    if (core_state_buffer.len != core_state.encoded_size) return error.InvalidCoreStateBuffer;
    const task_facts = [_]session_transition.Fact{
        session_transition.taskAdmitted(agentContext(session), session.task_id, session.task_id),
        session_transition.conversationAdvanced(
            agentContext(session),
            session.active_leaf_id,
            session.task_id,
        ),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
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
        core_state_buffer,
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
    core_state_buffer: []u8,
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
    const operation_context = operationContext(session, ids.operation_id, operation_generation);
    const admission_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            ids.request_ref,
            descriptor.digest,
            .none,
        ),
        session_transition.operationAccepted(
            operation_context,
            ids.request_ref,
            descriptor.digest,
            .none,
        ),
        session_transition.attemptAdmitted(
            operation_context,
            ids.attempt_id,
            ids.request_ref,
            descriptor.digest,
            .model,
        ),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
        core,
        &admission_facts,
        false,
    );
    core.close();
    core_open.* = false;

    try dispatchModelAttempt(session, token, provider, .{
        .request_ref = descriptor.request_ref,
        .response_ref = ids.response_ref,
        .operation_id = ids.operation_id,
        .operation_generation = operation_generation,
        .attempt_id = ids.attempt_id,
    }, completion_hook, fault);
    return error.CompletionExpected;
}

fn retryModelAttempt(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    core_state_buffer: []u8,
    provider: model_operation.Provider,
    completion_hook: ?CompletionHook,
) !void {
    const operation = try core.reducer.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
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
    const attempt = session_transition.attemptAdmitted(
        operationContext(session, operation.id, operation.generation),
        attempt_id,
        descriptor.reference(),
        descriptor.digest(),
        .model,
    );
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
        core,
        &.{attempt},
        false,
    );
    core.close();
    core_open.* = false;

    return dispatchModelAttempt(session, token, provider, .{
        .request_ref = descriptor.reference(),
        .response_ref = response_ref,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = attempt_id,
    }, completion_hook, null);
}

fn dispatchModelAttempt(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    provider: model_operation.Provider,
    dispatch: ModelDispatch,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    var provider_io = try model_operation.ProviderIo.open(
        session,
        token,
        dispatch.request_ref,
        dispatch.response_ref,
    );
    defer provider_io.close();
    var result_ref = dispatch.response_ref;
    var provider_failed = false;
    provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    ) catch {
        result_ref = try provider_io.publishProviderFailure(
            session,
            token,
            dispatch.response_ref,
        );
        provider_failed = true;
    };
    if (!provider_failed) {
        try provider_io.ensureResponsePublished();
        try reach(fault, .after_model_dispatch);
    }
    const evidence: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = dispatch.operation_id,
        .operation_generation = dispatch.operation_generation,
        .attempt_id = dispatch.attempt_id,
        .result_ref = result_ref,
        .result_digest = try blobDigest(session, token, result_ref),
    };
    try session.publishCompletionEvidence(token, evidence);
    try reach(fault, .after_completion_inbox);
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
    core_state_buffer: []u8,
    ids: OperationIds,
    core_open: *bool,
    workspace_path: []const u8,
    policy: bash_tool.Policy,
    cancellation: ?*const std.atomic.Value(bool),
    approval_required_hook: ?ApprovalRequiredHook,
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
    const operation_context = operationContext(session, tool_operation_id, 1);
    const descriptor_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(operation_context, descriptor_ref, digest, .consequential),
        session_transition.operationAccepted(operation_context, descriptor_ref, digest, .consequential),
        session_transition.conversationAdvanced(
            agentContext(session),
            call_entry.entry_id,
            descriptor_ref,
        ),
    };
    _ = try session.commitSemantic(token, &descriptor_facts, null);

    const classification = try policy.classify_fn(policy.context, digest, call);
    if (classification == .ask) {
        const approval = session_transition.approvalRequired(
            operation_context,
            0,
            descriptor_ref,
            digest,
        );
        try commitCoreFacts(session, token, core_state_buffer, core, &.{approval}, true);
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
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
    const authorization = session_transition.authorization(operation_context, 0, digest, allowed);
    _ = try session.commitSemantic(token, &.{authorization}, null);

    var attempt_id: u64 = 0;
    var execution: bash_tool.Execution = undefined;
    if (allowed) {
        while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
        const attempt = session_transition.attemptAdmitted(
            operation_context,
            attempt_id,
            descriptor_ref,
            digest,
            .consequential,
        );
        try commitCoreFacts(
            session,
            token,
            core_state_buffer,
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
        try restoreCoreFromLedger(session, token, core_state_buffer, core);
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
    const result_facts = [_]session_transition.Fact{
        session_transition.result(.{
            .operation = operation_context,
            .result_ref = result_ref,
            .result_digest = result_digest,
            .class = if (execution.status == .indeterminate) .indeterminate else .ordinary,
            .evidence = if (attempt_id == 0)
                .{ .immediate = .consequential }
            else
                .{ .durable = .{ .bash = attempt_id } },
        }),
        session_transition.conversationAdvanced(
            agentContext(session),
            result_entry.entry_id,
            result_ref,
        ),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
        core,
        &result_facts,
        true,
    );
    try reach(fault, .after_tool_state_commit);
}

const PatchPermissionOutcome = enum { ready, approved };

fn requestPatchPermission(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
    ids: OperationIds,
    workspace_path: []const u8,
    policy: patch_tool.Policy,
    approval_required_hook: ?ApprovalRequiredHook,
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
    const operation_context = operationContext(session, tool_operation_id, 1);
    const descriptor_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            patch_ref,
            validation.patch_digest,
            .consequential,
        ),
        session_transition.operationAccepted(
            operation_context,
            patch_ref,
            validation.patch_digest,
            .consequential,
        ),
        session_transition.conversationAdvanced(agentContext(session), call_entry.entry_id, patch_ref),
    };
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
        const approval = session_transition.approvalRequired(
            operation_context,
            approval_ref,
            patch_ref,
            validation.patch_digest,
        );
        try commitCoreFacts(
            session,
            token,
            core_state_buffer,
            core,
            &.{approval},
            true,
        );
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
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
    const authorization = session_transition.authorization(
        operation_context,
        permission_ref,
        validation.patch_digest,
        allowed,
    );
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
    const result_facts = [_]session_transition.Fact{
        session_transition.result(.{
            .operation = operation_context,
            .result_ref = result_ref,
            .result_digest = result_digest,
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
        }),
        session_transition.conversationAdvanced(
            agentContext(session),
            result_entry.entry_id,
            result_ref,
        ),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
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
    core_state_buffer: []u8,
) !u64 {
    var core = try Core.open(&host.slots);
    defer core.close();
    const token = session.ownerToken();
    if (core_state_buffer.len != core_state.encoded_size) return error.InvalidCoreStateBuffer;
    try restoreCoreFromLedger(session, token, core_state_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        const completion = try durableCompletion(session, token, &core);
        var slot: ModelSlot = .{ .core = &core, .session = session, .token = token };
        try ModelSlot.apply(&slot, completion);
        const applied = session_transition.resultApplied(
            operationContext(session, completion.operation_id, completion.operation_generation),
            0,
            completion.result,
            0,
            .none,
        );
        try commitCoreFacts(
            session,
            token,
            core_state_buffer,
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
            core_state_buffer,
            null,
        );
        return final_ref;
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            session,
            token,
            &core,
            core_state_buffer,
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
    core_state_buffer: []u8,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const io = session.io;
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    const token = session.ownerToken();
    if (core_state_buffer.len != core_state.encoded_size) return error.InvalidCoreStateBuffer;
    try restoreCoreFromLedger(session, token, core_state_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        if (durableCompletion(session, token, &core)) |completion| {
            var slot: ModelSlot = .{
                .core = &core,
                .session = session,
                .token = token,
            };
            try ModelSlot.apply(&slot, completion);
            const applied = session_transition.resultApplied(
                operationContext(session, completion.operation_id, completion.operation_generation),
                0,
                completion.result,
                0,
                .none,
            );
            try commitCoreFacts(
                session,
                token,
                core_state_buffer,
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
                core_state_buffer,
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
            core_state_buffer,
            null,
        );
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            session,
            token,
            &core,
            core_state_buffer,
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
                        core_state_buffer,
                        ids,
                        &core_open,
                        config.workspace_path,
                        config.bash_policy orelse return error.ToolCallDeferred,
                        config.bash_cancelled,
                        config.approval_required_hook,
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
                            core_state_buffer,
                            ids,
                            config.workspace_path,
                            config.patch_policy orelse return error.ToolCallDeferred,
                            config.approval_required_hook,
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
    if (outcome == .failed) return modelFailure(@intFromEnum((try core.reducer.response()).failure));
    if (outcome != .ready) return error.SessionNotReadyForModel;
    if (config.settle_only) return error.SessionNeedsModel;
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        core_state_buffer,
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
        core_state_buffer,
        null,
    );
    return final_ref;
}

pub fn resolvePermission(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    core_state_buffer: []u8,
    decision: ApprovalRequired,
    allow: bool,
    provider: ?model_operation.Provider,
    cancellation: ?*const std.atomic.Value(bool),
    completion_hook: ?CompletionHook,
) !u64 {
    const io = session.io;
    const token = session.ownerToken();
    if (core_state_buffer.len != core_state.encoded_size) return error.InvalidCoreStateBuffer;
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    try restoreCoreFromLedger(session, token, core_state_buffer, &core);
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
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return error.MissingActionDescriptor;
    if (descriptor.digest() != decision.descriptor_digest or
        descriptor.reference() != decision.descriptor_ref)
    {
        return error.StalePermissionDecision;
    }
    if (history.result != null or history.attempt != null) return error.PermissionNoLongerRequired;
    const pending = history.approval_required orelse return error.ApprovalNotCommitted;
    if (history.authorization != null or pending.digest() != descriptor.digest()) {
        return error.PermissionNoLongerRequired;
    }

    switch (response.tool) {
        .bash => {
            const operation_context = operationContext(session, expected_operation_id, 1);
            const authorization = session_transition.authorization(
                operation_context,
                0,
                descriptor.digest(),
                allow,
            );
            _ = try session.commitSemantic(token, &.{authorization}, null);
            var descriptor_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
            var reader = try session.openBlob(token, descriptor.reference());
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
                const attempt = session_transition.attemptAdmitted(
                    operation_context,
                    attempt_id,
                    descriptor.reference(),
                    descriptor.digest(),
                    .consequential,
                );
                try commitCoreFacts(session, token, core_state_buffer, &core, &.{attempt}, false);
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
                try restoreCoreFromLedger(session, token, core_state_buffer, &core);
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
            const facts = [_]session_transition.Fact{
                session_transition.result(.{
                    .operation = operation_context,
                    .result_ref = result_ref,
                    .result_digest = result_digest,
                    .class = if (execution.status == .indeterminate) .indeterminate else .ordinary,
                    .evidence = if (attempt_id == 0)
                        .{ .immediate = .consequential }
                    else
                        .{ .durable = .{ .bash = attempt_id } },
                }),
                session_transition.conversationAdvanced(
                    agentContext(session),
                    result_entry.entry_id,
                    result_ref,
                ),
            };
            try commitCoreFacts(session, token, core_state_buffer, &core, &facts, false);
        },
        .apply_patch => {
            var binding_bytes: [patch_tool.binding_size]u8 = undefined;
            var binding_reader = try session.openBlob(token, pending.subject());
            defer binding_reader.close();
            if (binding_reader.length() != binding_bytes.len or
                (try binding_reader.readWindow(0, &binding_bytes)).len != binding_bytes.len)
            {
                return error.InvalidPatchBinding;
            }
            const binding = try patch_tool.decodeBinding(&binding_bytes);
            if (binding.operation_id != expected_operation_id or
                binding.operation_generation != 1 or
                binding.patch_ref != descriptor.reference() or
                binding.patch_digest != descriptor.digest())
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
            const operation_context = operationContext(session, expected_operation_id, 1);
            const authorization = session_transition.authorization(
                operation_context,
                permission_ref,
                descriptor.digest(),
                allow,
            );
            _ = try session.commitSemantic(token, &.{authorization}, null);
            if (allow) return error.PatchExecutionDeferred;
            const result_ref = (@as(u64, 1) << 57) | @as(u32, @truncate(observation.result_ref));
            var result_bytes: [patch_tool.result_size]u8 = undefined;
            try patch_tool.encodeResult(&result_bytes, .{
                .status = .denied,
                .patch_digest = descriptor.digest(),
                .expected_workspace_digest = binding.workspace_digest,
                .observed_workspace_digest = 0,
            });
            try session.storeBlob(token, result_ref, &result_bytes);
            const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
            try core.reducer.commitToolResult(session.active_leaf_id, result_entry.entry_id);
            const facts = [_]session_transition.Fact{
                session_transition.result(.{
                    .operation = operation_context,
                    .result_ref = result_ref,
                    .result_digest = try blobDigest(session, token, result_ref),
                    .class = .ordinary,
                    .evidence = .{ .immediate = .consequential },
                }),
                session_transition.conversationAdvanced(
                    agentContext(session),
                    result_entry.entry_id,
                    result_ref,
                ),
            };
            try commitCoreFacts(session, token, core_state_buffer, &core, &facts, false);
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
        core_state_buffer,
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
    core_state_buffer: []u8,
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
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
    const attempt = history.attempt orelse return error.StaleCompletion;
    if (attempt.attemptId() != offered.attempt_id) return error.StaleCompletion;
    if (history.result) |result| {
        if (result.reference() != offered.result_ref or result.digest() != offered.result_digest) {
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
    return advanceRestored(host, allocator, session, core_state_buffer, config, provider);
}

const ToolRecovery = enum { none, ready, indeterminate, approval_required, approved };

fn reconcileToolCall(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
) !ToolRecovery {
    return switch ((try core.reducer.response()).tool) {
        .bash => reconcileBash(session, token, core, core_state_buffer),
        .apply_patch => reconcilePatch(
            session,
            token,
            core,
            core_state_buffer,
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
    core_state_buffer: []u8,
) !ToolRecovery {
    const model_observation = try core.reducer.operation();
    const operation_id = (@as(u64, 1) << 63) | model_observation.id;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return .none;
    if (history.result) |result| {
        try reconcileBashResult(
            session,
            token,
            core,
            core_state_buffer,
            recordFromFact(result),
        );
        return if (result.isIndeterminate())
            .indeterminate
        else
            .ready;
    }
    const attempt = history.attempt orelse {
        if (history.authorization == null and history.approval_required != null) {
            return .approval_required;
        }
        const authorization = history.authorization orelse return .none;
        if (authorization.flags() != 2) return .none;
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
        const denied = session_transition.result(.{
            .operation = operationContext(session, operation_id, 1),
            .result_ref = result_ref,
            .result_digest = try blobDigest(session, token, result_ref),
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
        });
        _ = try session.commitSemantic(token, &.{denied}, null);
        try reconcileBashResult(
            session,
            token,
            core,
            core_state_buffer,
            recordFromFact(denied),
        );
        return .ready;
    };
    var inbox: InboxSearch = .{
        .session_id = session.session_id,
        .agent_id = session.agent_id,
        .operation_id = operation_id,
        .operation_generation = 1,
        .attempt_id = attempt.attemptId(),
        .maximum_epoch = token.epoch,
    };
    _ = try session.scanCompletionEvidence(token, &inbox, InboxSearch.apply);
    var evidence_agent = agentContext(session);
    var result_ref: u64 = undefined;
    var result_digest: u64 = descriptor.digest();
    var status: bash_tool.Status = undefined;
    if (inbox.match) |envelope| {
        if (try blobDigest(session, token, envelope.result_ref) != envelope.result_digest) {
            return error.CompletionResultDigestMismatch;
        }
        result_ref = envelope.result_ref;
        result_digest = envelope.result_digest;
        evidence_agent.ownership_epoch = envelope.ownership_epoch;
        status = try readBashStatus(session, token, envelope.result_ref);
    } else {
        const response_ref: u32 = @truncate(model_observation.result_ref);
        result_ref = (@as(u64, 1) << 61) | response_ref;
        var empty: [0]u8 = .{};
        const execution: bash_tool.Execution = .{
            .allocator = undefined,
            .status = .indeterminate,
            .stdout = &empty,
            .stderr = &empty,
        };
        var encoded: [bash_tool.result_header_size]u8 = undefined;
        _ = try bash_tool.encodeResult(&encoded, execution);
        try storeOrExpectBlob(session, token, result_ref, &encoded);
        result_digest = try blobDigest(session, token, result_ref);
        status = .indeterminate;
        try session.publishCompletionEvidence(token, .{
            .kind = .bash,
            .session_id = session.session_id,
            .ownership_epoch = token.epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = attempt.attemptId(),
            .result_ref = result_ref,
            .result_digest = result_digest,
        });
    }
    const result = session_transition.result(.{
        .operation = .{ .agent = evidence_agent, .operation_id = operation_id, .generation = 1 },
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (status == .indeterminate) .indeterminate else .ordinary,
        .evidence = .{ .durable = .{ .bash = attempt.attemptId() } },
    });
    _ = try session.commitSemantic(token, &.{result}, null);
    try reconcileBashResult(
        session,
        token,
        core,
        core_state_buffer,
        recordFromFact(result),
    );
    return if (result.isIndeterminate())
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

fn recordFromFact(fact: session_transition.Fact) ToolResult {
    return .{
        .agent_id = fact.agentId(),
        .agent_generation = fact.agentGeneration(),
        .operation_id = fact.operationId(),
        .operation_generation = fact.generation(),
        .attempt_id = fact.attemptId(),
        .ownership_epoch = fact.ownershipEpoch(),
        .descriptor_digest = fact.digest(),
        .result = fact.reference(),
    };
}

fn reconcilePatch(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
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
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
    const validated = history.descriptor orelse return .none;
    if (validated.digest() == 0 or validated.reference() != patch_ref) {
        return error.InvalidPatchHistory;
    }
    if (history.result) |settled| {
        if (settled.reference() != result_ref) {
            return error.InvalidPatchHistory;
        }
        try reconcileToolResult(
            session,
            token,
            core,
            core_state_buffer,
            patch_ref,
            recordFromFact(settled),
        );
        return .ready;
    }
    if (history.authorization == null and history.approval_required != null) {
        return .approval_required;
    }
    const authorization = history.authorization orelse return .none;
    if (authorization.digest() != validated.digest() or authorization.reference() == 0) {
        return error.InvalidPatchHistory;
    }
    var binding_bytes: [patch_tool.binding_size]u8 = undefined;
    try readExactBlob(session, token, authorization.reference(), &binding_bytes);
    const binding = try patch_tool.decodeBinding(&binding_bytes);
    if (binding.operation_id != operation_id or binding.operation_generation != 1 or
        binding.patch_ref != patch_ref or binding.patch_digest != validated.digest())
    {
        return error.InvalidPatchPermissionBinding;
    }
    if ((authorization.flags() == 1 and binding.decision != .allow) or
        (authorization.flags() == 2 and binding.decision != .deny))
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
            core_state_buffer,
            operation_id,
            patch_ref,
            result_ref,
            validated.digest(),
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
        core_state_buffer,
        operation_id,
        patch_ref,
        result_ref,
        validated.digest(),
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
    core_state_buffer: []u8,
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
    const terminal = session_transition.result(.{
        .operation = operationContext(session, operation_id, 1),
        .result_ref = result_ref,
        .result_digest = try blobDigest(session, token, result_ref),
        .class = .ordinary,
        .evidence = .{ .immediate = .consequential },
    });
    _ = try session.commitSemantic(token, &.{terminal}, null);
    try reconcileToolResult(
        session,
        token,
        core,
        core_state_buffer,
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
    core_state_buffer: []u8,
    result: ToolResult,
) !void {
    const response_ref: u32 = @truncate(result.result);
    if (result.result != ((@as(u64, 1) << 61) | response_ref)) return error.InvalidToolResultReference;
    const descriptor_ref = (@as(u64, 1) << 62) | response_ref;
    try reconcileToolResult(session, token, core, core_state_buffer, descriptor_ref, result);
}

fn reconcileToolResult(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
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
    const applied_facts = [_]session_transition.Fact{
        session_transition.resultApplied(
            operationContext(session, result.operation_id, result.operation_generation),
            result.attempt_id,
            result.result,
            try blobDigest(session, token, result.result),
            .consequential,
        ),
        session_transition.conversationAdvanced(
            agentContext(session),
            result_entry.entry_id,
            result.result,
        ),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
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
    _ = try session.inspectSemantic(token, &history, FactSearch.applyFact);
    if (history.attempt_count == 0) return error.MissingAcceptedAttempt;
    var intent: ?session_transition.Fact = null;
    var result = history.result;
    if (result) |completed| {
        for (history.attemptSlice()) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            if (attempt.attemptId() == completed.attemptId()) {
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
                .attempt_id = attempt.attemptId(),
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
        var evidence_agent = agentContext(session);
        evidence_agent.ownership_epoch = envelope.ownership_epoch;
        const terminal = session_transition.result(.{
            .operation = .{
                .agent = evidence_agent,
                .operation_id = operation_id,
                .generation = operation_generation,
            },
            .result_ref = envelope.result_ref,
            .result_digest = envelope.result_digest,
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = intent.?.attemptId() } },
        });
        _ = try session.commitSemantic(token, &.{terminal}, null);
        result = terminal;
    }
    const accepted = intent orelse return error.InvalidOperationHistory;
    const completed = result.?;
    if (completed.attemptId() != accepted.attemptId() or
        completed.digest() == 0 or completed.reference() == 0)
    {
        return error.InvalidOperationHistory;
    }
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = accepted.ownershipEpoch(),
        .result = completed.reference(),
    };
}

const FactSearch = struct {
    const max_attempts = 8;

    operation_id: u64,
    generation: u32,
    recovery_class: session_transition.RecoveryClass,
    descriptor: ?session_transition.Fact = null,
    attempt: ?session_transition.Fact = null,
    attempts: [max_attempts]?session_transition.Fact = @splat(null),
    attempt_count: u8 = 0,
    target_attempt_id: u64 = 0,
    approval_required: ?session_transition.Fact = null,
    authorization: ?session_transition.Fact = null,
    result: ?session_transition.Fact = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *FactSearch = @ptrCast(@alignCast(context));
        if (fact.operationId() != self.operation_id or fact.generation() != self.generation) return;
        if (fact.recoveryClass() != .none and fact.recoveryClass() != self.recovery_class) return;
        switch (fact.kind()) {
            .operation_submitted => self.descriptor = try uniqueFact(self.descriptor, fact),
            .attempt_admitted => {
                var found = false;
                for (self.attempts[0..self.attempt_count]) |maybe_existing| {
                    const existing = maybe_existing.?;
                    if (existing.attemptId() != fact.attemptId()) continue;
                    if (!std.meta.eql(existing, fact)) return error.ConflictingLedgerFacts;
                    found = true;
                    break;
                }
                if (!found) {
                    if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
                    self.attempts[self.attempt_count] = fact;
                    self.attempt_count += 1;
                }
                if (self.target_attempt_id == 0 or self.target_attempt_id == fact.attemptId()) {
                    self.attempt = fact;
                }
            },
            .approval_required => self.approval_required = try uniqueFact(
                self.approval_required,
                fact,
            ),
            .authorization => self.authorization = try uniqueFact(self.authorization, fact),
            .result => self.result = try uniqueFact(self.result, fact),
            else => {},
        }
    }

    fn attemptSlice(self: *const FactSearch) []const ?session_transition.Fact {
        return self.attempts[0..self.attempt_count];
    }

    fn containsAttempt(self: *const FactSearch, attempt_id: u64) bool {
        for (self.attemptSlice()) |maybe_attempt| {
            if (maybe_attempt.?.attemptId() == attempt_id) return true;
        }
        return false;
    }
};

pub fn pendingApprovalRequired(session: *session_store.Session) !?ApprovalRequired {
    var search: PendingApprovalSearch = .{};
    _ = try session.inspectSemantic(
        session.ownerToken(),
        &search,
        PendingApprovalSearch.applyFact,
    );
    return search.approval;
}

const PendingApprovalSearch = struct {
    approval: ?ApprovalRequired = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *PendingApprovalSearch = @ptrCast(@alignCast(context));
        switch (fact.kind()) {
            .approval_required => {
                self.approval = .{
                    .kind = if ((fact.operationId() >> 62) == 3) .apply_patch else .bash,
                    .operation_id = fact.operationId(),
                    .operation_generation = fact.generation(),
                    .descriptor_digest = fact.digest(),
                    .descriptor_ref = fact.reference(),
                };
            },
            .authorization => if (self.approval) |approval| {
                if (approval.operation_id == fact.operationId() and
                    approval.operation_generation == fact.generation())
                {
                    self.approval = null;
                }
            },
            .attempt_admitted, .result => if (self.approval) |approval| {
                if (approval.operation_id == fact.operationId() and
                    approval.operation_generation == fact.generation())
                {
                    self.approval = null;
                }
            },
            else => {},
        }
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

fn uniqueFact(existing: ?session_transition.Fact, fact: session_transition.Fact) !session_transition.Fact {
    if (existing) |value| {
        if (!std.meta.eql(value, fact)) return error.ConflictingLedgerFacts;
        return value;
    }
    return fact;
}

fn hasIndeterminateBash(
    session: *session_store.Session,
    token: session_store.OwnerToken,
) !bool {
    var found = false;
    _ = try session.inspectSemantic(token, &found, detectIndeterminate);
    return found;
}

fn detectIndeterminate(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
    const found: *bool = @ptrCast(@alignCast(context));
    if (fact.kind() == .result and fact.recoveryClass() == .consequential and
        fact.isIndeterminate())
    {
        found.* = true;
    }
}

fn finalizeCandidate(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
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
    const final_facts = [_]session_transition.Fact{
        session_transition.conversationAdvanced(agentContext(session), entry.entry_id, final_ref),
        session_transition.outcome(agentContext(session), session.task_id, final_ref),
    };
    try commitCoreFacts(
        session,
        token,
        core_state_buffer,
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
