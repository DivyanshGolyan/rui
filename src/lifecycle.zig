const std = @import("std");
const binding = @import("binding.zig");
const bash_tool = @import("bash_tool.zig");
const completion_inbox = @import("completion_inbox.zig");
const conversation = @import("conversation.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const agent_generation: u32 = 1;
const production_active_capacity: usize = 1;
const ProductionSlotPool = core_image.SlotPool(production_active_capacity);

comptime {
    std.debug.assert(model_contract.max_patch_input_bytes == patch_tool.max_patch_size);
}

/// Process-owned bounded activation capacity. Construct this once at host
/// startup and pass it through every agent lifecycle entry point.
pub const Host = struct {
    slots: ProductionSlotPool = .{},
    owner_scratch: [production_active_capacity]OwnerScratch = @splat(.{}),
};

const OwnerScratch = struct {
    response: [model_protocol.max_response_size]u8 = undefined,
    validation: model_protocol.ValidationScratch = .{},

    fn decoded(self: *OwnerScratch) []u8 {
        return &self.validation.json.normalized;
    }

    fn canonicalJsonWorkspace(self: *OwnerScratch) session_store.CanonicalJsonWorkspace {
        return .{
            .input = self.response[0..model_contract.max_tool_arguments_envelope_size],
            .scratch = &self.validation.json,
        };
    }

    fn scrub(self: *OwnerScratch) void {
        @memset(std.mem.asBytes(self), 0);
    }
};

const owner_scratch_size = @sizeOf(OwnerScratch);

comptime {
    std.debug.assert(owner_scratch_size ==
        model_protocol.max_response_size + @sizeOf(model_protocol.ValidationScratch));
}

pub const PermissionMode = enum {
    ask,
    bypass,
};

pub const RuntimeConfig = struct {
    workspace_path: []const u8,
    fault: ?FaultHook = null,
    permission_mode: PermissionMode = .ask,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    approval_required_hook: ?ApprovalRequiredHook = null,
    completion_hook: ?CompletionHook = null,
    settle_only: bool = false,
};

pub const ApprovalRequiredKind = enum { bash, apply_patch };

pub const ApprovalRequired = struct {
    kind: ApprovalRequiredKind,
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: binding.Descriptor,
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
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(&state, ControlSearch.applyFact);
    if (state.open_operation) return error.AcceptedOperationUnsettled;
    const agent = agentContext(session);
    const fact = if (control == .cancel)
        session_transition.cancellation(agent)
    else
        session_transition.shutdown(agent);
    _ = try session.commitSemantic(&.{fact}, null, null);
}

pub fn restoredControl(session: *session_store.Session) !?Control {
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(&state, ControlSearch.applyFact);
    return state.control;
}

pub fn recoverSemanticWindow(
    host: *Host,
    session: *session_store.Session,
    frame_budget: u8,
) !session_store.RecoveryProgress {
    var core = try Core.open(&host.slots);
    defer core.close();
    const scratch = &host.owner_scratch[core.lease.index];
    defer scratch.scrub();
    return session.recoverSemanticWindow(frame_budget, scratch.canonicalJsonWorkspace());
}

const ControlSearch = struct {
    open_operation: bool = false,
    operation_id: u64 = 0,
    generation: u32 = 0,
    control: ?Control = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *ControlSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .operation_accepted => |record| {
                self.open_operation = true;
                self.operation_id = record.operation.operation_id;
                self.generation = record.operation.generation;
            },
            .result => |record| if (self.open_operation and
                self.operation_id == record.operation.operation_id and
                self.generation == record.operation.generation)
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
    after_patch_authorization,
    after_patch_attempt,
    after_patch_mutation,
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
    request_digest: binding.ModelDescriptor,
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
    result_digest: binding.Result,
    agent_generation: u32,
    operation_generation: u32,
};

const ExecutableTool = enum { bash, apply_patch };

fn executableTool(session: *session_store.Session, core: *const core_image.Core) !ExecutableTool {
    const response = try core.response();
    var key_buffer: [model_contract.max_tool_key_size]u8 = undefined;
    const key = try readResponseWindow(session, core, response, response.tool_key, &key_buffer);
    return executableToolFromKey(key);
}

fn executableToolFromKey(key: []const u8) !ExecutableTool {
    if (std.mem.eql(u8, key, model_contract.bash_key)) return .bash;
    if (std.mem.eql(u8, key, model_contract.apply_patch_key)) return .apply_patch;
    return error.UnboundToolKey;
}

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
    core_state_buffer: []u8,
    core: *Core,
    facts: []const session_transition.Fact,
    reactivate: bool,
) !void {
    _ = core_state_buffer;
    try core.suspendIntoState();
    _ = try session.commitSemantic(facts, &core.encoded_state, null);
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
    core_state_buffer: []u8,
    core: *Core,
) !void {
    _ = core_state_buffer;
    var replay_context: u8 = 0;
    const replay = try session.inspectSemantic(&replay_context, ignoreFact);
    core.encoded_state = replay.last_core orelse return error.MissingLedgerCoreState;
    try core.activate();
}

fn ignoreFact(_: *anyopaque, _: session_transition.Fact) anyerror!void {}

const ModelSlot = struct {
    core: *Core,
    session: *session_store.Session,
    scratch: *OwnerScratch,

    fn apply(context: *anyopaque, completion: ModelCompletion) anyerror!void {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        defer self.scratch.scrub();
        var response = try self.session.openBlob(completion.result);
        defer response.close();
        if (response.length() == 0) return error.EmptyModelResponse;
        if (response.length() > model_protocol.max_response_size) return error.ResponseTooLarge;
        const length: usize = @intCast(response.length());
        const bytes = try readAndVerifyModelResponse(
            &response,
            completion.result_digest,
            self.scratch.response[0..length],
        );
        const validated = try model_protocol.validate(&self.scratch.validation, bytes);
        _ = try self.core.reducer.applyModelResponse(.{
            .id = completion.operation_id,
            .generation = completion.operation_generation,
        }, bytes, validated, completion.result);
    }
};

pub fn advanceCreated(
    host: *Host,
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
    try core.initialize(session.agent_id);
    try core.reducer.startTask(session.activeLeafId());
    if (core_state_buffer.len != core_state.encoded_size) return error.InvalidCoreStateBuffer;
    try commitCoreFacts(
        session,
        core_state_buffer,
        &core,
        &.{session_transition.taskAdmitted(
            agentContext(session),
            session.task_id,
            session.task_id,
        )},
        true,
    );
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        core_state_buffer,
        &host.owner_scratch[core.lease.index],
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
    scratch: *OwnerScratch,
    provider: ?model_operation.Provider,
    model_sequence: u32,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !OperationIds {
    const next_provider = provider orelse return error.SessionOperationPending;
    const ids = try allocateOperationIds(io, session);
    const operation = try core.reducer.beginModelOperation(ids.operation_id, model_sequence);
    const context = try core.reducer.modelContext();
    const operation_generation = operation.generation;
    const request_digest = try model_operation.buildRequest(
        session,
        ids.request_ref,
        context.first_entry,
        context.entry_count,
    );
    try model_operation.verifyRequestDigest(session, ids.request_ref, request_digest);
    try core.reducer.acceptOperation(.{ .id = ids.operation_id, .generation = operation_generation });
    const operation_context = operationContext(session, ids.operation_id, operation_generation);
    const admission_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            ids.request_ref,
            .{ .model = request_digest },
            .none,
        ),
        session_transition.operationAccepted(
            operation_context,
            ids.request_ref,
            .{ .model = request_digest },
            .none,
        ),
        session_transition.modelAttemptAdmitted(
            operation_context,
            ids.attempt_id,
            ids.request_ref,
            .{ .model = request_digest },
            0,
        ),
    };
    try commitCoreFacts(
        session,
        core_state_buffer,
        core,
        &admission_facts,
        false,
    );
    try dispatchModelAttempt(session, token, next_provider, scratch, .{
        .request_ref = ids.request_ref,
        .request_digest = request_digest,
        .response_ref = ids.response_ref,
        .operation_id = ids.operation_id,
        .operation_generation = operation_generation,
        .attempt_id = ids.attempt_id,
    }, completion_hook, fault);
    core.close();
    core_open.* = false;
    return error.CompletionExpected;
}

fn retryModelAttempt(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    core_state_buffer: []u8,
    scratch: *OwnerScratch,
    provider: ?model_operation.Provider,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    const operation = try core.reducer.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return error.MissingModelDescriptor;
    if (history.attempt_count == FactSearch.max_attempts) {
        const attempt = history.attempts[history.attempt_count - 1].?;
        const result_ref = try model_operation.publishFailureResult(
            session,
            attempt.attempt_id,
        );
        const evidence = completion_inbox.bind(.{
            .kind = .model,
            .session_id = session.session_id,
            .ownership_epoch = attempt.operation.agent.ownership_epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation.id,
            .operation_generation = operation.generation,
            .attempt_id = attempt.attempt_id,
            .result_ref = result_ref,
            .result_digest = try blobDigest(session, result_ref),
        });
        try session.publishCompletionEvidence(evidence);
        if (completion_hook) |hook| try hook.offered(hook.context, evidence);
        return error.CompletionOffered;
    }
    const next_provider = provider orelse return error.SessionOperationPending;
    const request_digest = switch (descriptor.descriptor_digest) {
        .model => |digest| digest,
        else => return error.InvalidModelDescriptor,
    };
    try model_operation.verifyRequestDigest(session, descriptor.descriptor_ref, request_digest);
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
    const attempt = session_transition.modelAttemptAdmitted(
        operationContext(session, operation.id, operation.generation),
        attempt_id,
        descriptor.descriptor_ref,
        descriptor.descriptor_digest,
        history.attempt_count,
    );
    try commitCoreFacts(
        session,
        core_state_buffer,
        core,
        &.{attempt},
        false,
    );
    try dispatchModelAttempt(session, token, next_provider, scratch, .{
        .request_ref = descriptor.descriptor_ref,
        .request_digest = request_digest,
        .response_ref = response_ref,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = attempt_id,
    }, completion_hook, fault);
    core.close();
    core_open.* = false;
}

fn dispatchModelAttempt(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    provider: model_operation.Provider,
    scratch: *OwnerScratch,
    dispatch: ModelDispatch,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    defer scratch.scrub();
    try model_operation.verifyRequestDigest(session, dispatch.request_ref, dispatch.request_digest);
    var provider_io = try model_operation.ProviderIo.open(
        session,
        dispatch.request_ref,
        dispatch.response_ref,
        scratch.canonicalJsonWorkspace(),
    );
    defer provider_io.close();
    var result_ref = dispatch.response_ref;
    var provider_failed = false;
    provider.dispatch(
        provider.context,
        try provider_io.request(),
        provider_io.responseCapability(),
    ) catch {
        result_ref = try provider_io.publishProviderFailure(
            session,
            dispatch.response_ref,
        );
        provider_failed = true;
    };
    if (!provider_failed) {
        try provider_io.ensureResponsePublished();
        try reach(fault, .after_model_dispatch);
    }
    const evidence = completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = dispatch.operation_id,
        .operation_generation = dispatch.operation_generation,
        .attempt_id = dispatch.attempt_id,
        .result_ref = result_ref,
        .result_digest = try blobDigest(session, result_ref),
    });
    try session.publishCompletionEvidence(evidence);
    try reach(fault, .after_completion_inbox);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

const BashArguments = struct { command: []const u8, timeout_ms: u32 };
const PatchArguments = struct { patch: []const u8 };

fn parseBashArguments(
    scratch: []u8,
    arguments: []const u8,
) !BashArguments {
    if (arguments.len == 0 or arguments.len > model_contract.max_tool_arguments_envelope_size) {
        return error.InvalidBashArguments;
    }
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSliceLeaky(BashArguments, fixed.allocator(), arguments, .{
        .max_value_len = model_contract.max_tool_arguments_envelope_size,
        .allocate = .alloc_if_needed,
        .duplicate_field_behavior = .@"error",
    }) catch
        return error.InvalidBashArguments;
    var validation: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    _ = bash_tool.encodeCall(&validation, .{
        .command = parsed.command,
        .timeout_ms = parsed.timeout_ms,
    }) catch return error.InvalidBashArguments;
    return parsed;
}

fn parsePatchArguments(
    scratch: []u8,
    arguments: []const u8,
) !PatchArguments {
    if (arguments.len == 0 or arguments.len > model_contract.max_tool_arguments_envelope_size) {
        return error.InvalidPatchArguments;
    }
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSliceLeaky(PatchArguments, fixed.allocator(), arguments, .{
        .max_value_len = model_contract.max_tool_arguments_envelope_size,
        .allocate = .alloc_if_needed,
        .duplicate_field_behavior = .@"error",
    }) catch
        return error.InvalidPatchArguments;
    model_contract.validatePatchInput(parsed.patch) catch return error.InvalidPatchArguments;
    return parsed;
}

fn executeBashCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    host: *Host,
    core_state_buffer: []u8,
    ids: OperationIds,
    core_open: *bool,
    workspace_path: []const u8,
    permission_mode: PermissionMode,
    cancellation: ?*const std.atomic.Value(bool),
    approval_required_hook: ?ApprovalRequiredHook,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    const scratch = &host.owner_scratch[core.lease.index];
    defer scratch.scrub();
    const response = try core.reducer.response();
    if (try executableTool(session, &core.reducer) != .bash) {
        return error.UnsupportedTool;
    }
    const arguments_length = response.arguments.length;
    if (arguments_length == 0 or
        arguments_length > model_contract.max_tool_arguments_envelope_size)
    {
        return error.InvalidBashCallRange;
    }
    const canonical_arguments = try readCanonicalResponseArguments(
        session,
        &core.reducer,
        response,
        scratch.response[0..arguments_length],
    );
    const parsed = try parseBashArguments(scratch.decoded(), canonical_arguments.bytes());
    const call: bash_tool.Call = .{
        .command = parsed.command,
        .timeout_ms = parsed.timeout_ms,
    };
    const tool_operation_id = (@as(u64, 1) << 63) | ids.operation_id;
    const descriptor: bash_tool.Descriptor = .{
        .operation_id = tool_operation_id,
        .operation_generation = 1,
        .workspace_path = workspace_path,
        .working_directory = workspace_path,
        .call = call,
    };
    var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const descriptor_bytes = try bash_tool.encodeDescriptor(&descriptor_buffer, descriptor);
    const digest = bash_tool.descriptorDigest(descriptor_bytes);
    const call_ref = (@as(u64, 1) << 59) | ids.response_ref;
    const descriptor_ref = (@as(u64, 1) << 62) | ids.response_ref;
    const result_ref = (@as(u64, 1) << 61) | ids.response_ref;
    try storeToolCall(
        session,
        call_ref,
        model_contract.bash_key,
        canonical_arguments,
    );
    try session.storeBlob(descriptor_ref, descriptor_bytes);
    const workspace = scratch.canonicalJsonWorkspace();
    const call_entry = try session.appendConversation(.tool_call, call_ref, null, workspace);
    const operation_context = operationContext(session, tool_operation_id, 1);
    const descriptor_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            descriptor_ref,
            .{ .bash = digest },
            .consequential,
        ),
        session_transition.operationAccepted(
            operation_context,
            descriptor_ref,
            .{ .bash = digest },
            .consequential,
        ),
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = call_entry.entry_id,
            .parent_id = call_entry.parent_id,
            .kind = call_entry.kind,
            .content_ref = call_ref,
        }),
    };
    _ = try session.commitSemantic(&descriptor_facts, null, workspace);

    if (permission_mode == .ask) {
        const approval = session_transition.approvalRequired(.{
            .operation = operation_context,
            .binding_ref = 0,
            .descriptor_ref = descriptor_ref,
            .descriptor_digest = .{ .bash = digest },
        });
        try commitCoreFacts(session, core_state_buffer, core, &.{approval}, true);
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
            .kind = .bash,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = .{ .bash = digest },
            .descriptor_ref = descriptor_ref,
        });
        return error.PermissionInputRequired;
    }
    const authorization = session_transition.authorization(.{
        .operation = operation_context,
        .permission_ref = 0,
        .descriptor_digest = .{ .bash = digest },
        .allowed = true,
    });
    _ = try session.commitSemantic(&.{authorization}, null, null);

    var attempt_id: u64 = 0;
    while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
    const attempt = session_transition.consequentialAttemptAdmitted(
        operation_context,
        attempt_id,
        descriptor_ref,
        .{ .bash = digest },
    );
    try commitCoreFacts(
        session,
        core_state_buffer,
        core,
        &.{attempt},
        false,
    );
    const admitted_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
    scratch.scrub();
    core.close();
    core_open.* = false;
    var execution = try bash_tool.executeDescriptor(
        allocator,
        io,
        admitted_descriptor,
        .{ .cancelled = cancellation },
    );
    try reach(fault, .after_bash_execution);
    core.* = try Core.open(&host.slots);
    core_open.* = true;
    try restoreCoreFromLedger(session, core_state_buffer, core);
    defer execution.deinit();
    try storeBashResult(session, result_ref, execution);
    const result_digest = try blobDigest(session, result_ref);
    const evidence = completion_inbox.bind(.{
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
    });
    try session.publishCompletionEvidence(evidence);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn requestPatchPermission(
    io: std.Io,
    scratch: *OwnerScratch,
    session: *session_store.Session,
    core: *Core,
    core_state_buffer: []u8,
    ids: OperationIds,
    workspace_path: []const u8,
    permission_mode: PermissionMode,
    approval_required_hook: ?ApprovalRequiredHook,
    fault: ?FaultHook,
) !void {
    defer scratch.scrub();
    const response = try core.reducer.response();
    const arguments_length = response.arguments.length;
    if (arguments_length == 0 or
        arguments_length > model_contract.max_tool_arguments_envelope_size)
    {
        return error.InvalidPatchRange;
    }
    const canonical_arguments = try readCanonicalResponseArguments(
        session,
        &core.reducer,
        response,
        scratch.response[0..arguments_length],
    );
    const parsed = try parsePatchArguments(scratch.decoded(), canonical_arguments.bytes());
    const patch = parsed.patch;
    const tool_operation_id = (@as(u64, 3) << 62) | ids.operation_id;
    const patch_ref = (@as(u64, 1) << 60) | ids.response_ref;
    const call_ref = (@as(u64, 1) << 59) | ids.response_ref;
    const intent_ref = (@as(u64, 1) << 58) | ids.response_ref;
    const intent = try patch_tool.prepare(io, workspace_path, patch, .{
        .operation_id = tool_operation_id,
        .operation_generation = 1,
        .patch_ref = patch_ref,
    });
    try session.storeBlob(patch_ref, patch);
    try storePatchIntent(session, intent_ref, intent);
    try storeToolCall(
        session,
        call_ref,
        model_contract.apply_patch_key,
        canonical_arguments,
    );
    const workspace = scratch.canonicalJsonWorkspace();
    const call_entry = try session.appendConversation(.tool_call, call_ref, null, workspace);
    const operation_context = operationContext(session, tool_operation_id, 1);
    const descriptor_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            intent_ref,
            .{ .apply_patch = intent.intent_digest },
            .consequential,
        ),
        session_transition.operationAccepted(
            operation_context,
            intent_ref,
            .{ .apply_patch = intent.intent_digest },
            .consequential,
        ),
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = call_entry.entry_id,
            .parent_id = call_entry.parent_id,
            .kind = call_entry.kind,
            .content_ref = call_ref,
        }),
    };
    _ = try session.commitSemantic(&descriptor_facts, null, workspace);

    if (permission_mode == .ask) {
        const approval = session_transition.approvalRequired(.{
            .operation = operation_context,
            .binding_ref = intent_ref,
            .descriptor_ref = patch_ref,
            .descriptor_digest = .{ .apply_patch = intent.intent_digest },
        });
        try commitCoreFacts(
            session,
            core_state_buffer,
            core,
            &.{approval},
            true,
        );
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
            .kind = .apply_patch,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = .{ .apply_patch = intent.intent_digest },
            .descriptor_ref = patch_ref,
        });
        return error.PermissionInputRequired;
    }
    const authorization = session_transition.authorization(.{
        .operation = operation_context,
        .permission_ref = intent_ref,
        .descriptor_digest = .{ .apply_patch = intent.intent_digest },
        .allowed = true,
    });
    _ = try session.commitSemantic(&.{authorization}, null, null);
    try reach(fault, .after_patch_authorization);
}

fn storePatchIntent(
    session: *session_store.Session,
    intent_ref: u64,
    intent: patch_tool.Intent,
) !void {
    var bytes: [patch_tool.max_intent_size]u8 = undefined;
    try session.storeBlob(intent_ref, try patch_tool.encodeIntent(&bytes, intent));
}

fn storeBashResult(
    session: *session_store.Session,
    result_ref: u64,
    execution: bash_tool.Execution,
) !void {
    var header: [bash_tool.result_header_size]u8 = undefined;
    const header_bytes = try bash_tool.encodeResultHeader(&header, execution);
    var writer = try session.beginBlob(result_ref);
    errdefer writer.abort();
    try writer.append(header_bytes);
    try writer.append(execution.stdout);
    try writer.append(execution.stderr);
    try writer.finish();
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
    try restoreCoreFromLedger(session, core_state_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        if (durableCompletion(session, token, &core)) |completion| {
            var slot: ModelSlot = .{
                .core = &core,
                .session = session,
                .scratch = &host.owner_scratch[core.lease.index],
            };
            try ModelSlot.apply(&slot, completion);
            const applied = session_transition.resultApplied(.{
                .operation = operationContext(session, completion.operation_id, completion.operation_generation),
                .attempt_id = 0,
                .result_ref = completion.result,
                .result_digest = completion.result_digest,
                .recovery_class = .none,
            });
            try commitCoreFacts(
                session,
                core_state_buffer,
                &core,
                &.{applied},
                true,
            );
        } else |err| switch (err) {
            error.SessionOperationPending => try retryModelAttempt(
                io,
                session,
                token,
                &core,
                &core_open,
                core_state_buffer,
                &host.owner_scratch[core.lease.index],
                provider,
                config.completion_hook,
                config.fault,
            ),
            else => return err,
        }
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .final_candidate) {
        return finalizeCandidate(
            session,
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
            session.workspacePath(),
            config.completion_hook,
            config.fault,
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => outcome = .ready,
            .approval_required => return error.PatchApprovalRequired,
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
                switch (try executableTool(session, &core.reducer)) {
                    .bash => try executeBashCall(
                        io,
                        allocator,
                        session,
                        token,
                        &core,
                        host,
                        core_state_buffer,
                        ids,
                        &core_open,
                        config.workspace_path,
                        config.permission_mode,
                        config.bash_cancelled,
                        config.approval_required_hook,
                        config.completion_hook,
                        config.fault,
                    ),
                    .apply_patch => {
                        try requestPatchPermission(
                            io,
                            &host.owner_scratch[core.lease.index],
                            session,
                            &core,
                            core_state_buffer,
                            ids,
                            config.workspace_path,
                            config.permission_mode,
                            config.approval_required_hook,
                            config.fault,
                        );
                        _ = try reconcilePatch(
                            session,
                            token,
                            &core,
                            core_state_buffer,
                            config.workspace_path,
                            config.completion_hook,
                            config.fault,
                        );
                    },
                }
                outcome = (try core.reducer.task()).phase;
            },
        }
    }
    if (outcome == .failed) {
        const response = try core.reducer.response();
        if (response.disposition == .input_request) return error.InteractionRequestLayerRequired;
        return modelFailure(@intFromEnum(response.failure));
    }
    if (outcome == .finished) {
        const entry_id = (try core.reducer.task()).final_entry_id;
        if (entry_id != session.activeLeafId()) return error.FinalEntryMismatch;
        const entry = try session.readEntry(entry_id);
        if (entry.kind != .assistant_text) return error.InvalidFinalEntry;
        return entry.content_ref;
    }
    if (outcome != .ready) return error.SessionNotReadyForModel;
    if (try hasIndeterminateBash(session)) return error.BashPossiblyExecuted;
    if (config.settle_only) return error.SessionNeedsModel;
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        core_state_buffer,
        &host.owner_scratch[core.lease.index],
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
    try restoreCoreFromLedger(session, core_state_buffer, &core);
    if ((try core.reducer.task()).phase != .awaiting_tool) return error.PermissionNoLongerRequired;
    const tool = try executableTool(session, &core.reducer);
    const observation = try core.reducer.operation();
    const expected_operation_id = switch (tool) {
        .bash => (@as(u64, 1) << 63) | observation.id,
        .apply_patch => (@as(u64, 3) << 62) | observation.id,
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
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return error.MissingActionDescriptor;
    if (!binding.descriptorEql(descriptor.descriptor_digest, decision.descriptor_digest)) {
        return error.StalePermissionDecision;
    }
    if (history.result != null or history.attempt != null) return error.PermissionNoLongerRequired;
    const pending = history.approval_required orelse return error.ApprovalNotCommitted;
    if (pending.descriptor_ref != decision.descriptor_ref) return error.StalePermissionDecision;
    if (history.authorization != null or
        !binding.descriptorEql(pending.descriptor_digest, descriptor.descriptor_digest))
    {
        return error.PermissionNoLongerRequired;
    }

    switch (tool) {
        .bash => {
            const operation_context = operationContext(session, expected_operation_id, 1);
            var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
            var reader = try session.openBlob(descriptor.descriptor_ref);
            defer reader.close();
            if (reader.length() > descriptor_buffer.len) return error.InvalidBashCallRange;
            const descriptor_length: usize = @intCast(reader.length());
            const descriptor_bytes = try reader.readWindow(0, descriptor_buffer[0..descriptor_length]);
            if (descriptor_bytes.len != descriptor_length) return error.TruncatedBashDescriptor;
            const bash_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
            const expected_bash_digest = switch (descriptor.descriptor_digest) {
                .bash => |value| value,
                else => return error.StalePermissionDecision,
            };
            if (bash_descriptor.operation_id != expected_operation_id or
                bash_descriptor.operation_generation != 1 or
                !std.mem.eql(u8, bash_descriptor.workspace_path, session.workspacePath()) or
                !binding.eql(
                    binding.BashDescriptor,
                    bash_tool.descriptorDigest(descriptor_bytes),
                    expected_bash_digest,
                ))
            {
                return error.StalePermissionDecision;
            }
            const authorization = session_transition.authorization(.{
                .operation = operation_context,
                .permission_ref = 0,
                .descriptor_digest = descriptor.descriptor_digest,
                .allowed = allow,
            });
            _ = try session.commitSemantic(&.{authorization}, null, null);
            const result_ref = (@as(u64, 1) << 61) | @as(u32, @truncate(observation.result_ref));
            var attempt_id: u64 = 0;
            var execution: bash_tool.Execution = undefined;
            if (allow) {
                while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
                const attempt = session_transition.consequentialAttemptAdmitted(
                    operation_context,
                    attempt_id,
                    descriptor.descriptor_ref,
                    descriptor.descriptor_digest,
                );
                try commitCoreFacts(session, core_state_buffer, &core, &.{attempt}, false);
                core.close();
                core_open = false;
                execution = try bash_tool.executeDescriptor(
                    allocator,
                    io,
                    bash_descriptor,
                    .{ .cancelled = cancellation },
                );
                core = try Core.open(&host.slots);
                core_open = true;
                try restoreCoreFromLedger(session, core_state_buffer, &core);
            } else {
                execution = .{
                    .allocator = allocator,
                    .status = .denied,
                    .stdout = try allocator.alloc(u8, 0),
                    .stderr = try allocator.alloc(u8, 0),
                };
            }
            defer execution.deinit();
            try storeBashResult(session, result_ref, execution);
            const result_digest = try blobDigest(session, result_ref);
            if (allow) {
                const evidence = completion_inbox.bind(.{
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
                });
                try session.publishCompletionEvidence(evidence);
                if (completion_hook) |hook| try hook.offered(hook.context, evidence);
                return error.CompletionOffered;
            }
            const terminal = session_transition.result(.{
                .operation = operation_context,
                .result_ref = result_ref,
                .result_digest = result_digest,
                .class = if (execution.status == .indeterminate) .indeterminate else .ordinary,
                .evidence = if (attempt_id == 0)
                    .{ .immediate = .consequential }
                else
                    .{ .durable = .{ .bash = attempt_id } },
            });
            _ = try session.commitSemantic(&.{terminal}, null, null);
            try reconcileBashResult(
                session,
                &core,
                core_state_buffer,
                toolResultFromRecord(terminal.result),
            );
        },
        .apply_patch => {
            var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
            const intent_slice = try readBoundedBlob(session, pending.binding_ref, &intent_bytes);
            const intent = try patch_tool.decodeIntent(intent_slice);
            const patch_descriptor = switch (descriptor.descriptor_digest) {
                .apply_patch => |value| value,
                else => return error.StalePermissionDecision,
            };
            if (descriptor.descriptor_ref != pending.binding_ref or
                intent.operation_id != expected_operation_id or
                intent.operation_generation != 1 or
                intent.patch_ref != pending.descriptor_ref or
                !binding.eql(binding.PatchIntent, intent.intent_digest, patch_descriptor))
            {
                return error.StalePermissionDecision;
            }
            const operation_context = operationContext(session, expected_operation_id, 1);
            const authorization = session_transition.authorization(.{
                .operation = operation_context,
                .permission_ref = pending.binding_ref,
                .descriptor_digest = descriptor.descriptor_digest,
                .allowed = allow,
            });
            _ = try session.commitSemantic(&.{authorization}, null, null);
        },
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
    try completion_inbox.validate(offered);
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
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const attempt = history.attempt orelse return error.StaleCompletion;
    if (attempt.attempt_id != offered.attempt_id) return error.StaleCompletion;
    if (offered.ownership_epoch != attempt.operation.agent.ownership_epoch) {
        return error.CompletionAttemptEpochMismatch;
    }
    if (offered.kind != std.meta.activeTag(attempt.descriptor_digest)) return error.StaleCompletion;
    if (history.result) |result| {
        if (resultAttemptId(result) != offered.attempt_id) {
            return advanceRestored(host, allocator, session, core_state_buffer, config, provider);
        }
        if (result.result_ref != offered.result_ref or
            !binding.eql(binding.Result, result.result_digest, offered.result_digest))
        {
            return error.ConflictingCompletionEvidence;
        }
        return advanceRestored(host, allocator, session, core_state_buffer, config, provider);
    }
    var inbox: InboxSearch = .{
        .session_id = offered.session_id,
        .agent_id = offered.agent_id,
        .operation_id = offered.operation_id,
        .operation_generation = offered.operation_generation,
        .attempt_id = offered.attempt_id,
        .maximum_epoch = token.epoch,
        .expected_epoch = attempt.operation.agent.ownership_epoch,
        .expected_kind = std.meta.activeTag(attempt.descriptor_digest),
    };
    _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
    const evidence = inbox.match orelse return error.CompletionEvidenceMissing;
    if (evidence.result_ref != offered.result_ref or
        !binding.eql(binding.Result, evidence.result_digest, offered.result_digest) or
        !binding.eql(binding.Completion, evidence.completion_digest, offered.completion_digest))
    {
        return error.ConflictingCompletionEvidence;
    }
    return advanceRestored(host, allocator, session, core_state_buffer, config, provider);
}

const ToolRecovery = enum { none, ready, indeterminate, approval_required };

fn reconcileToolCall(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    return switch (try executableTool(session, &core.reducer)) {
        .bash => reconcileBash(session, token, core, core_state_buffer),
        .apply_patch => reconcilePatch(
            session,
            token,
            core,
            core_state_buffer,
            workspace_path,
            completion_hook,
            fault,
        ),
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
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    _ = history.descriptor orelse return .none;
    if (history.result) |result| {
        try reconcileBashResult(
            session,
            core,
            core_state_buffer,
            toolResultFromRecord(result),
        );
        return if (result.class == .indeterminate)
            .indeterminate
        else
            .ready;
    }
    const attempt = history.attempt orelse {
        if (history.authorization == null and history.approval_required != null) {
            return .approval_required;
        }
        const authorization = history.authorization orelse return .none;
        if (authorization.allowed) return .none;
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
        try storeOrExpectBlob(session, result_ref, &encoded);
        const denied = session_transition.result(.{
            .operation = operationContext(session, operation_id, 1),
            .result_ref = result_ref,
            .result_digest = try blobDigest(session, result_ref),
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
        });
        _ = try session.commitSemantic(&.{denied}, null, null);
        try reconcileBashResult(
            session,
            core,
            core_state_buffer,
            toolResultFromRecord(denied.result),
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
        .expected_epoch = attempt.operation.agent.ownership_epoch,
        .expected_kind = .bash,
    };
    _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
    var evidence_agent = attempt.operation.agent;
    var result_ref: u64 = undefined;
    var result_digest: binding.Result = undefined;
    var status: bash_tool.Status = undefined;
    if (inbox.match) |envelope| {
        if (!binding.eql(
            binding.Result,
            try blobDigest(session, envelope.result_ref),
            envelope.result_digest,
        )) {
            return error.CompletionResultDigestMismatch;
        }
        result_ref = envelope.result_ref;
        result_digest = envelope.result_digest;
        evidence_agent.ownership_epoch = envelope.ownership_epoch;
        status = try readBashStatus(session, envelope.result_ref);
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
        try storeOrExpectBlob(session, result_ref, &encoded);
        result_digest = try blobDigest(session, result_ref);
        status = .indeterminate;
        try session.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = .bash,
            .session_id = session.session_id,
            .ownership_epoch = attempt.operation.agent.ownership_epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = attempt.attempt_id,
            .result_ref = result_ref,
            .result_digest = result_digest,
        }));
    }
    const result = session_transition.result(.{
        .operation = .{ .agent = evidence_agent, .operation_id = operation_id, .generation = 1 },
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (status == .indeterminate) .indeterminate else .ordinary,
        .evidence = .{ .durable = .{ .bash = attempt.attempt_id } },
    });
    _ = try session.commitSemantic(&.{result}, null, null);
    try reconcileBashResult(
        session,
        core,
        core_state_buffer,
        toolResultFromRecord(result.result),
    );
    return if (result.result.class == .indeterminate)
        .indeterminate
    else
        .ready;
}

fn readBashStatus(
    session: *session_store.Session,
    reference: u64,
) !bash_tool.Status {
    var reader = try session.openBlob(reference);
    defer reader.close();
    if (reader.length() < bash_tool.result_header_size) return error.TruncatedBashResult;
    var header: [bash_tool.result_header_size]u8 = undefined;
    const bytes = try reader.readWindow(0, &header);
    if (bytes.len != header.len) return error.TruncatedBashResult;
    return (try bash_tool.decodeResultHeader(&header, reader.length())).status;
}

fn toolResultFromRecord(result: session_transition.ResultRecord) ToolResult {
    const attempt_id: u64 = switch (result.evidence) {
        .immediate => 0,
        .durable => |evidence| switch (evidence) {
            inline else => |value| value,
        },
    };
    return .{
        .agent_id = result.operation.agent.agent_id,
        .agent_generation = result.operation.agent.agent_generation,
        .operation_id = result.operation.operation_id,
        .operation_generation = result.operation.generation,
        .attempt_id = attempt_id,
        .ownership_epoch = result.operation.agent.ownership_epoch,
        .result = result.result_ref,
    };
}

fn reconcilePatch(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_state_buffer: []u8,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    const operation_observation = try core.reducer.operation();
    const model_operation_id = operation_observation.id;
    const response_ref: u32 = @truncate(operation_observation.result_ref);
    const operation_id = (@as(u64, 3) << 62) | model_operation_id;
    const result_ref = (@as(u64, 1) << 57) | response_ref;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const validated = history.descriptor orelse return .none;
    const patch_descriptor = switch (validated.descriptor_digest) {
        .apply_patch => |value| value,
        else => return error.InvalidPatchHistory,
    };
    var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
    const intent = try readPatchIntent(session, validated.descriptor_ref, &intent_bytes);
    if (intent.operation_id != operation_id or intent.operation_generation != 1 or
        !binding.eql(binding.PatchIntent, intent.intent_digest, patch_descriptor) or
        !std.mem.eql(u8, intent.workspace_path, workspace_path))
    {
        return error.InvalidPatchHistory;
    }
    const patch_ref = intent.patch_ref;
    if (history.result) |settled| {
        if (settled.result_ref != result_ref) {
            return error.InvalidPatchHistory;
        }
        try reconcileToolResult(
            session,
            core,
            core_state_buffer,
            (@as(u64, 1) << 59) | response_ref,
            .apply_patch,
            toolResultFromRecord(settled),
        );
        return .ready;
    }
    if (history.authorization == null and history.approval_required != null) {
        return .approval_required;
    }
    const authorization = history.authorization orelse return .none;
    if (!binding.descriptorEql(authorization.descriptor_digest, validated.descriptor_digest) or
        authorization.permission_ref != validated.descriptor_ref)
    {
        return error.InvalidPatchHistory;
    }
    var patch_buffer: [patch_tool.max_patch_size]u8 = undefined;
    var patch: []const u8 = &.{};
    var attempt = history.attempt;
    var immediate_status: ?patch_tool.ResultStatus = if (authorization.allowed) null else .denied;
    if (!authorization.allowed and attempt != null) return error.InvalidPatchHistory;
    if (authorization.allowed) {
        patch = try readBoundedBlob(session, patch_ref, &patch_buffer);
    }
    if (authorization.allowed and attempt == null) {
        if (!try patch_tool.readyForAttempt(session.io, intent, patch)) {
            immediate_status = .stale;
        } else {
            var attempt_id: u64 = 0;
            while (attempt_id == 0) session.io.random(std.mem.asBytes(&attempt_id));
            const admitted = session_transition.consequentialAttemptAdmitted(
                operationContext(session, operation_id, 1),
                attempt_id,
                validated.descriptor_ref,
                validated.descriptor_digest,
            );
            try commitCoreFacts(session, core_state_buffer, core, &.{admitted}, false);
            attempt = admitted.attempt_admitted;
            try reach(fault, .after_patch_attempt);
        }
    }

    var result_digest: binding.Result = undefined;
    var result_status: patch_tool.ResultStatus = undefined;
    var evidence_agent = if (attempt) |admitted| admitted.operation.agent else agentContext(session);
    var result_evidence: session_transition.ResultEvidence = .{ .immediate = .consequential };
    if (immediate_status) |status| {
        result_status = status;
        var result_bytes: [patch_tool.result_size]u8 = undefined;
        try patch_tool.encodeResult(&result_bytes, .{
            .status = status,
            .intent_ref = validated.descriptor_ref,
            .intent_digest = patch_descriptor,
        });
        try storeOrExpectBlob(session, result_ref, &result_bytes);
        result_digest = try blobDigest(session, result_ref);
    } else {
        const admitted = attempt orelse return error.InvalidPatchHistory;
        if (admitted.descriptor_ref != validated.descriptor_ref or
            !binding.descriptorEql(admitted.descriptor_digest, validated.descriptor_digest))
        {
            return error.InvalidPatchHistory;
        }
        result_evidence = .{ .durable = .{ .apply_patch = admitted.attempt_id } };
        var inbox: InboxSearch = .{
            .session_id = session.session_id,
            .agent_id = session.agent_id,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = admitted.attempt_id,
            .maximum_epoch = token.epoch,
            .expected_epoch = admitted.operation.agent.ownership_epoch,
            .expected_kind = .apply_patch,
        };
        _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
        if (inbox.match) |envelope| {
            if (envelope.result_ref != result_ref or !binding.eql(
                binding.Result,
                try blobDigest(session, envelope.result_ref),
                envelope.result_digest,
            )) return error.CompletionResultDigestMismatch;
            result_digest = envelope.result_digest;
            evidence_agent.ownership_epoch = envelope.ownership_epoch;
            result_status = try readPatchResultStatus(
                session,
                envelope.result_ref,
                validated.descriptor_ref,
                patch_descriptor,
            );
        } else {
            const reconciliation = try patch_tool.reconcile(session.io, intent, patch);
            result_status = reconciliation.status;
            if (reconciliation.mutated) try reach(fault, .after_patch_mutation);
            var result_bytes: [patch_tool.result_size]u8 = undefined;
            try patch_tool.encodeResult(&result_bytes, .{
                .status = result_status,
                .intent_ref = validated.descriptor_ref,
                .intent_digest = patch_descriptor,
            });
            try storeOrExpectBlob(session, result_ref, &result_bytes);
            result_digest = try blobDigest(session, result_ref);
            const envelope = completion_inbox.bind(.{
                .kind = .apply_patch,
                .session_id = session.session_id,
                .ownership_epoch = admitted.operation.agent.ownership_epoch,
                .agent_id = session.agent_id,
                .agent_generation = agent_generation,
                .operation_id = operation_id,
                .operation_generation = 1,
                .attempt_id = admitted.attempt_id,
                .result_ref = result_ref,
                .result_digest = result_digest,
            });
            try session.publishCompletionEvidence(envelope);
            if (completion_hook) |hook| {
                try hook.offered(hook.context, envelope);
                return error.CompletionOffered;
            }
        }
    }
    const terminal = session_transition.result(.{
        .operation = .{ .agent = evidence_agent, .operation_id = operation_id, .generation = 1 },
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (result_status == .indeterminate) .indeterminate else .ordinary,
        .evidence = result_evidence,
    });
    _ = try session.commitSemantic(&.{terminal}, null, null);
    try reconcileToolResult(
        session,
        core,
        core_state_buffer,
        (@as(u64, 1) << 59) | response_ref,
        .apply_patch,
        toolResultFromRecord(terminal.result),
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
    result: u64,
};

fn readPatchIntent(
    session: *session_store.Session,
    intent_ref: u64,
    buffer: *[patch_tool.max_intent_size]u8,
) !patch_tool.Intent {
    return patch_tool.decodeIntent(try readBoundedBlob(session, intent_ref, buffer));
}

fn readPatchResultStatus(
    session: *session_store.Session,
    result_ref: u64,
    intent_ref: u64,
    intent_digest: binding.PatchIntent,
) !patch_tool.ResultStatus {
    var bytes: [patch_tool.result_size]u8 = undefined;
    try readExactBlob(session, result_ref, &bytes);
    const result = try patch_tool.decodeResult(&bytes);
    if (result.intent_ref != intent_ref or
        !binding.eql(binding.PatchIntent, result.intent_digest, intent_digest))
    {
        return error.InvalidPatchResult;
    }
    return result.status;
}

fn reconcileBashResult(
    session: *session_store.Session,
    core: *Core,
    core_state_buffer: []u8,
    result: ToolResult,
) !void {
    const response_ref: u32 = @truncate(result.result);
    if (result.result != ((@as(u64, 1) << 61) | response_ref)) return error.InvalidToolResultReference;
    const call_ref = (@as(u64, 1) << 59) | response_ref;
    try reconcileToolResult(session, core, core_state_buffer, call_ref, .bash, result);
}

fn reconcileToolResult(
    session: *session_store.Session,
    core: *Core,
    core_state_buffer: []u8,
    call_ref: u64,
    tool: ExecutableTool,
    result: ToolResult,
) !void {
    const visible_ref = (@as(u64, 1) << 55) | @as(u32, @truncate(result.result));
    const active = try session.readEntry(session.activeLeafId());
    var call_entry: session_store.ConversationEntry = undefined;
    var result_entry: session_store.ConversationEntry = undefined;
    if (active.kind == .tool_result and active.content_ref == visible_ref) {
        result_entry = active;
        call_entry = try session.readEntry(active.parent_id);
    } else if (active.kind == .tool_call and active.content_ref == call_ref) {
        call_entry = active;
        try storeVisibleToolResult(session, tool, result.result, visible_ref, call_entry.entry_id);
        result_entry = try session.appendConversation(.tool_result, visible_ref, null, null);
    } else {
        return error.ToolConversationMismatch;
    }
    if (call_entry.kind != .tool_call or call_entry.content_ref != call_ref or
        result_entry.parent_id != call_entry.entry_id)
    {
        return error.ToolConversationMismatch;
    }
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    const applied_facts = [_]session_transition.Fact{
        session_transition.resultApplied(.{
            .operation = operationContext(session, result.operation_id, result.operation_generation),
            .attempt_id = result.attempt_id,
            .result_ref = result.result,
            .result_digest = try blobDigest(session, result.result),
            .recovery_class = .consequential,
        }),
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = result_entry.entry_id,
            .parent_id = result_entry.parent_id,
            .kind = result_entry.kind,
            .content_ref = visible_ref,
        }),
    };
    try commitCoreFacts(
        session,
        core_state_buffer,
        core,
        &applied_facts,
        true,
    );
}

fn storeVisibleToolResult(
    session: *session_store.Session,
    tool: ExecutableTool,
    durable_ref: u64,
    visible_ref: u64,
    parent_id: u64,
) !void {
    var existing_length: ?u64 = null;
    var existing_digest: binding.Blob = undefined;
    var blob_writer: ?session_store.BlobWriter = null;
    var existing = session.openBlob(visible_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            blob_writer = try session.beginBlob(visible_ref);
            break :blk null;
        },
        else => return err,
    };
    if (existing) |*reader| {
        existing_length = reader.length();
        existing_digest = reader.digest();
        reader.close();
    }
    defer if (blob_writer) |*writer| writer.abort();

    var target: VisibleResultTarget = .{
        .writer = if (blob_writer) |*writer| writer else null,
    };
    try emitVisibleToolResult(session, tool, durable_ref, parent_id, &target);
    if (blob_writer) |*writer| {
        try writer.finish();
        blob_writer = null;
    } else if (existing_length.? != target.length or
        !binding.eql(binding.Blob, existing_digest, target.hasher.final()))
    {
        return error.BlobContentMismatch;
    }
}

const VisibleResultTarget = struct {
    writer: ?*session_store.BlobWriter,
    hasher: binding.Hasher(binding.Blob) = .init(),
    length: u64 = 0,

    fn append(self: *VisibleResultTarget, bytes: []const u8) !void {
        if (self.length + bytes.len > conversation.result_header_size +
            conversation.max_result_content_size) return error.ToolResultTooLarge;
        if (self.writer) |writer| try writer.append(bytes);
        self.hasher.update(bytes);
        self.length += bytes.len;
    }
};

fn emitVisibleToolResult(
    session: *session_store.Session,
    tool: ExecutableTool,
    durable_ref: u64,
    parent_id: u64,
    target: *VisibleResultTarget,
) !void {
    switch (tool) {
        .bash => {
            var durable = try session.openBlob(durable_ref);
            defer durable.close();
            var durable_header: [bash_tool.result_header_size]u8 = undefined;
            const header_bytes = try durable.readWindow(0, &durable_header);
            if (header_bytes.len != durable_header.len) return error.TruncatedBlob;
            const result = try bash_tool.decodeResultHeader(&durable_header, durable.length());
            var prefix_buffer: [96]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buffer, "status={s}\nexit_code={d}\nstdout_base64=", .{
                bashStatusName(result.status),
                result.exit_code,
            });
            const separator = "\nstderr_base64=";
            const content_length = prefix.len +
                std.base64.standard.Encoder.calcSize(result.stdout_length) + separator.len +
                std.base64.standard.Encoder.calcSize(result.stderr_length);
            var visible_header: [conversation.result_header_size]u8 = undefined;
            try target.append(try conversation.encodeToolResultHeader(
                &visible_header,
                parent_id,
                result.status != .success,
                content_length,
            ));
            try target.append(prefix);
            try appendBase64Windowed(
                &durable,
                bash_tool.result_header_size,
                result.stdout_length,
                target,
            );
            try target.append(separator);
            try appendBase64Windowed(
                &durable,
                bash_tool.result_header_size + @as(u64, result.stdout_length),
                result.stderr_length,
                target,
            );
        },
        .apply_patch => {
            var durable: [patch_tool.result_size]u8 = undefined;
            try readExactBlob(session, durable_ref, &durable);
            const result = try patch_tool.decodeResult(&durable);
            var content_buffer: [64]u8 = undefined;
            const content = try std.fmt.bufPrint(&content_buffer, "status={s}", .{patchStatusName(result.status)});
            var visible_header: [conversation.result_header_size]u8 = undefined;
            try target.append(try conversation.encodeToolResultHeader(
                &visible_header,
                parent_id,
                result.status != .applied,
                content.len,
            ));
            try target.append(content);
        },
    }
}

fn appendBase64Windowed(
    reader: *session_store.BlobReader,
    start: u64,
    length: u32,
    target: *VisibleResultTarget,
) !void {
    const input_window_size = 4095;
    var input: [input_window_size]u8 = undefined;
    var output: [std.base64.standard.Encoder.calcSize(input_window_size)]u8 = undefined;
    var consumed: u64 = 0;
    while (consumed < length) {
        const remaining = @as(u64, length) - consumed;
        const wanted: usize = @intCast(@min(remaining, input.len));
        const bytes = try reader.readWindow(start + consumed, input[0..wanted]);
        if (bytes.len != wanted) return error.TruncatedBlob;
        try target.append(std.base64.standard.Encoder.encode(
            output[0..std.base64.standard.Encoder.calcSize(bytes.len)],
            bytes,
        ));
        consumed += bytes.len;
    }
}

fn bashStatusName(status: bash_tool.Status) []const u8 {
    return switch (status) {
        .success => "success",
        .nonzero_exit => "nonzero_exit",
        .timeout => "timeout",
        .cancelled => "cancelled",
        .missing_executable => "missing_executable",
        .truncated => "truncated",
        .denied => "denied",
        .indeterminate => "indeterminate",
        .spawn_error => "spawn_error",
    };
}

fn patchStatusName(status: patch_tool.ResultStatus) []const u8 {
    return switch (status) {
        .denied => "denied",
        .stale => "stale",
        .applied => "applied",
        .indeterminate => "indeterminate",
    };
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
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    if (history.attempt_count == 0) return error.MissingAcceptedAttempt;
    var intent: ?session_transition.AttemptRecord = null;
    var result = history.result;
    if (result) |completed| {
        for (history.attemptSlice()) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            if (attempt.attempt_id == resultAttemptId(completed)) {
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
                .expected_epoch = attempt.operation.agent.ownership_epoch,
                .expected_kind = .model,
            };
            _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
            if (inbox.match) |envelope| {
                intent = attempt;
                matched_envelope = envelope;
                break;
            }
        }
        const envelope = matched_envelope orelse return error.SessionOperationPending;
        if (!binding.eql(
            binding.Result,
            try blobDigest(session, envelope.result_ref),
            envelope.result_digest,
        )) {
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
            .evidence = .{ .durable = .{ .model = intent.?.attempt_id } },
        });
        _ = try session.commitSemantic(&.{terminal}, null, null);
        result = terminal.result;
    }
    const accepted = intent orelse return error.InvalidOperationHistory;
    const completed = result.?;
    if (resultAttemptId(completed) != accepted.attempt_id or completed.result_ref == 0) {
        return error.InvalidOperationHistory;
    }
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = accepted.operation.agent.ownership_epoch,
        .result = completed.result_ref,
        .result_digest = completed.result_digest,
    };
}

const FactSearch = struct {
    const max_attempts = session_transition.max_operation_attempts;

    operation_id: u64,
    generation: u32,
    recovery_class: session_transition.RecoveryClass,
    descriptor: ?session_transition.OperationRecord = null,
    attempt: ?session_transition.AttemptRecord = null,
    attempts: [max_attempts]?session_transition.AttemptRecord = @splat(null),
    attempt_count: u8 = 0,
    target_attempt_id: u64 = 0,
    approval_required: ?session_transition.ApprovalRequiredRecord = null,
    authorization: ?session_transition.AuthorizationRecord = null,
    result: ?session_transition.ResultRecord = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *FactSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .operation_submitted => |record| {
                if (!self.accepts(record.operation) or !self.acceptsClass(record.recovery_class)) return;
                self.descriptor = try uniqueRecord(
                    session_transition.OperationRecord,
                    self.descriptor,
                    record,
                );
            },
            .attempt_admitted => |record| {
                if (!self.accepts(record.operation) or record.recovery_class != self.recovery_class) return;
                var found = false;
                for (self.attempts[0..self.attempt_count]) |maybe_existing| {
                    const existing = maybe_existing.?;
                    if (existing.attempt_id != record.attempt_id) continue;
                    if (!std.meta.eql(existing, record)) return error.ConflictingLedgerFacts;
                    found = true;
                    break;
                }
                if (!found) {
                    if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
                    self.attempts[self.attempt_count] = record;
                    self.attempt_count += 1;
                }
                if (self.target_attempt_id == 0 or self.target_attempt_id == record.attempt_id) {
                    self.attempt = record;
                }
            },
            .approval_required => |record| {
                if (!self.accepts(record.operation)) return;
                self.approval_required = try uniqueRecord(
                    session_transition.ApprovalRequiredRecord,
                    self.approval_required,
                    record,
                );
            },
            .authorization => |record| {
                if (!self.accepts(record.operation)) return;
                self.authorization = try uniqueRecord(
                    session_transition.AuthorizationRecord,
                    self.authorization,
                    record,
                );
            },
            .result => |record| {
                if (!self.accepts(record.operation) or
                    !self.acceptsClass(resultRecoveryClass(record))) return;
                self.result = try uniqueRecord(
                    session_transition.ResultRecord,
                    self.result,
                    record,
                );
            },
            else => {},
        }
    }

    fn accepts(self: *const FactSearch, operation: session_transition.OperationContext) bool {
        return operation.operation_id == self.operation_id and operation.generation == self.generation;
    }

    fn acceptsClass(self: *const FactSearch, recovery_class: session_transition.RecoveryClass) bool {
        return recovery_class == .none or recovery_class == self.recovery_class;
    }

    fn attemptSlice(self: *const FactSearch) []const ?session_transition.AttemptRecord {
        return self.attempts[0..self.attempt_count];
    }

    fn containsAttempt(self: *const FactSearch, attempt_id: u64) bool {
        for (self.attemptSlice()) |maybe_attempt| {
            if (maybe_attempt.?.attempt_id == attempt_id) return true;
        }
        return false;
    }
};

pub fn pendingApprovalRequired(session: *session_store.Session) !?ApprovalRequired {
    var search: PendingApprovalSearch = .{};
    _ = try session.inspectSemantic(
        &search,
        PendingApprovalSearch.applyFact,
    );
    return search.approval;
}

const PendingApprovalSearch = struct {
    approval: ?ApprovalRequired = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *PendingApprovalSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .approval_required => |record| {
                self.approval = .{
                    .kind = if ((record.operation.operation_id >> 62) == 3) .apply_patch else .bash,
                    .operation_id = record.operation.operation_id,
                    .operation_generation = record.operation.generation,
                    .descriptor_digest = record.descriptor_digest,
                    .descriptor_ref = record.descriptor_ref,
                };
            },
            .authorization => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
                {
                    self.approval = null;
                }
            },
            .attempt_admitted => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
                {
                    self.approval = null;
                }
            },
            .result => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
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
    expected_epoch: u64,
    expected_kind: completion_inbox.EvidenceKind,
    match: ?completion_inbox.Envelope = null,

    fn apply(context: *anyopaque, envelope: completion_inbox.Envelope) anyerror!void {
        const self: *InboxSearch = @ptrCast(@alignCast(context));
        if (envelope.kind != self.expected_kind) return;
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id or
            envelope.operation_id != self.operation_id or
            envelope.operation_generation != self.operation_generation or
            envelope.attempt_id != self.attempt_id)
        {
            return;
        }
        if (envelope.ownership_epoch > self.maximum_epoch) return error.FutureCompletionEpoch;
        if (envelope.ownership_epoch != self.expected_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (self.match) |existing| {
            if (!std.meta.eql(existing, envelope)) return error.ConflictingCompletionEvidence;
            return;
        }
        self.match = envelope;
    }
};

fn uniqueRecord(comptime T: type, existing: ?T, candidate: T) !T {
    if (existing) |value| {
        if (!std.meta.eql(value, candidate)) return error.ConflictingLedgerFacts;
        return value;
    }
    return candidate;
}

fn resultRecoveryClass(result: session_transition.ResultRecord) session_transition.RecoveryClass {
    return switch (result.evidence) {
        .immediate => |recovery_class| recovery_class,
        .durable => |evidence| switch (evidence) {
            .model => .model,
            .bash, .apply_patch => .consequential,
        },
    };
}

fn resultAttemptId(result: session_transition.ResultRecord) u64 {
    return switch (result.evidence) {
        .immediate => 0,
        .durable => |evidence| switch (evidence) {
            inline else => |attempt_id| attempt_id,
        },
    };
}

fn hasIndeterminateBash(
    session: *session_store.Session,
) !bool {
    var found = false;
    _ = try session.inspectSemantic(&found, detectIndeterminate);
    return found;
}

fn detectIndeterminate(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
    const found: *bool = @ptrCast(@alignCast(context));
    switch (fact) {
        .result => |result| if (result.class == .indeterminate) switch (result.evidence) {
            .durable => |evidence| switch (evidence) {
                .bash => found.* = true,
                else => {},
            },
            .immediate => {},
        },
        else => {},
    }
}

fn finalizeCandidate(
    session: *session_store.Session,
    core: *Core,
    core_state_buffer: []u8,
    fault: ?FaultHook,
) !u64 {
    const task = try core.reducer.task();
    const response = try core.reducer.response();
    if (task.phase != .final_candidate or response.disposition != .final_answer) {
        return error.FinalAnswerNotCandidate;
    }
    var final_buffer: [model_protocol.max_assistant_text_size]u8 = undefined;
    const expected = try readResponseWindow(session, &core.reducer, response, response.text, &final_buffer);
    if (expected.len == 0) {
        return error.InvalidFinalAnswerRange;
    }
    const response_ref = response.content_ref;
    if (response_ref == 0) return error.InvalidModelResponseReference;
    const final_ref = finalReference(response_ref);

    var final_blob = session.openBlob(final_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try session.storeBlob(final_ref, expected);
            break :blk try session.openBlob(final_ref);
        },
        else => return err,
    };
    defer final_blob.close();
    try expectBlob(&final_blob, expected);
    try reach(fault, .after_final_blob);

    var entry = try session.readEntry(session.activeLeafId());
    if (entry.kind != .assistant_text or entry.content_ref != final_ref) {
        entry = try session.appendConversation(.assistant_text, final_ref, null, null);
    }
    try reach(fault, .after_assistant_entry);
    try core.reducer.commitFinalAnswer(entry.entry_id);
    const final_facts = [_]session_transition.Fact{
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = entry.entry_id,
            .parent_id = entry.parent_id,
            .kind = entry.kind,
            .content_ref = final_ref,
        }),
        session_transition.outcome(agentContext(session), session.task_id, final_ref),
    };
    try commitCoreFacts(
        session,
        core_state_buffer,
        core,
        &final_facts,
        true,
    );
    return final_ref;
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
    reference: u64,
    out: []u8,
) !void {
    var reader = try session.openBlob(reference);
    defer reader.close();
    if (reader.length() != out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out);
    if (bytes.len != out.len) return error.TruncatedBlob;
}

fn readBoundedBlob(
    session: *session_store.Session,
    reference: u64,
    out: []u8,
) ![]const u8 {
    var reader = try session.openBlob(reference);
    defer reader.close();
    if (reader.length() == 0 or reader.length() > out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out[0..@intCast(reader.length())]);
    if (bytes.len != reader.length()) return error.TruncatedBlob;
    return bytes;
}

fn readResponseWindow(
    session: *session_store.Session,
    core: *const core_image.Core,
    response: core_image.Response,
    window: core_image.ContentWindow,
    out: []u8,
) ![]const u8 {
    if (window.length == 0 or window.length > out.len) return error.InvalidModelResponseWindow;
    const operation = try core.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const committed = history.result orelse return error.MissingModelResult;
    if (committed.result_ref != response.content_ref) return error.ModelResultReferenceMismatch;
    var reader = try session.openBlob(response.content_ref);
    defer reader.close();
    if (reader.length() == 0 or reader.length() > model_protocol.max_response_size) {
        return error.ResponseTooLarge;
    }
    try verifyModelResponse(&reader, committed.result_digest);
    const start: u64 = window.offset;
    const length: u64 = window.length;
    if (start > reader.length() or length > reader.length() - start) {
        return error.InvalidModelResponseWindow;
    }
    const bytes = try reader.readWindow(start, out[0..window.length]);
    if (bytes.len != window.length) return error.TruncatedModelResponse;
    return bytes;
}

fn readCanonicalResponseArguments(
    session: *session_store.Session,
    core: *const core_image.Core,
    response: core_image.Response,
    out: []u8,
) !model_contract.CanonicalJson {
    const bytes = try readResponseWindow(
        session,
        core,
        response,
        response.arguments.contentWindow(),
        out,
    );
    return model_contract.canonicalJsonFromEvidence(bytes, response.arguments.evidence);
}

fn readAndVerifyModelResponse(
    reader: *session_store.BlobReader,
    expected_digest: binding.Result,
    out: []u8,
) ![]const u8 {
    if (reader.length() != out.len) return error.TruncatedModelResponse;
    var hasher = binding.Hasher(binding.Result).init();
    var offset: usize = 0;
    while (offset < out.len) {
        const bytes = try reader.readWindow(offset, out[offset..][0..@min(4096, out.len - offset)]);
        if (bytes.len == 0) return error.TruncatedModelResponse;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.Result, hasher.final(), expected_digest)) {
        return error.CompletionResultDigestMismatch;
    }
    return out;
}

fn verifyModelResponse(reader: *session_store.BlobReader, expected_digest: binding.Result) !void {
    var window: [4096]u8 = undefined;
    var hasher = binding.Hasher(binding.Result).init();
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const wanted: usize = @intCast(@min(reader.length() - offset, window.len));
        const bytes = try reader.readWindow(offset, window[0..wanted]);
        if (bytes.len != wanted) return error.TruncatedModelResponse;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.Result, hasher.final(), expected_digest)) {
        return error.CompletionResultDigestMismatch;
    }
}

test "restored response metadata reads the exact durable content window" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    var git = try repo.openDir(io, ".git", .{});
    defer git.close(io);
    try git.createDir(io, "objects", .default_dir);
    try git.createDir(io, "refs", .default_dir);
    var config = try git.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);

    var repo_path_buffer: [160]u8 = undefined;
    const repo_path = try std.fmt.bufPrint(
        &repo_path_buffer,
        ".zig-cache/tmp/{s}/repo",
        .{tmp.sub_path},
    );
    var database_path_buffer: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:window",
        .task = "Recover the final answer window",
    });
    defer session.close();

    const response_ref: u64 = 2001;
    const answer = "the restored window comes from durable response bytes";
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const encoded_response = try model_protocol.encodeText(&response_buffer, answer);
    try session.storeBlob(response_ref, encoded_response);
    const descriptor_ref: u64 = 2000;
    const descriptor_bytes = "restored response test descriptor";
    try session.storeBlob(descriptor_ref, descriptor_bytes);
    const descriptor_digest: binding.Descriptor = .{
        .model = binding.hash(binding.ModelDescriptor, descriptor_bytes),
    };

    var initial_slot: core_image.ActivationSlot = undefined;
    var initial = try core_image.Core.initialize(&initial_slot, .{ .agent_id = session.agent_id, .generation = 1 });
    try initial.startTask(1);
    const operation = try initial.beginModelOperation(2, 1);
    const identity: core_image.OperationIdentity = .{
        .id = operation.id,
        .generation = operation.generation,
    };
    try initial.acceptOperation(identity);
    const ledger_operation = operationContext(&session, operation.id, operation.generation);
    const response_digest = binding.hash(binding.Result, encoded_response);
    _ = try session.commitSemantic(&.{
        session_transition.operationSubmitted(ledger_operation, descriptor_ref, descriptor_digest, .model),
        session_transition.modelAttemptAdmitted(ledger_operation, 9, descriptor_ref, descriptor_digest, 0),
    }, null, null);
    try session.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = session.ownership_epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 9,
        .result_ref = response_ref,
        .result_digest = response_digest,
    }));
    _ = try session.commitSemantic(&.{session_transition.result(.{
        .operation = ledger_operation,
        .result_ref = response_ref,
        .result_digest = response_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 9 } },
    })}, null, null);
    _ = try initial.applyModelResponse(
        identity,
        encoded_response,
        try model_protocol.validate(&validation, encoded_response),
        response_ref,
    );
    var encoded_state: [core_state.encoded_size]u8 = undefined;
    try initial.suspendInto(&encoded_state);

    var restored_slot: core_image.ActivationSlot = undefined;
    var restored = try core_image.Core.activate(&restored_slot, &encoded_state);
    defer restored.abandon();
    const response = try restored.response();
    var answer_buffer: [model_protocol.max_assistant_text_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        answer,
        try readResponseWindow(&session, &restored, response, response.text, &answer_buffer),
    );

    var blob_path: [64]u8 = undefined;
    const response_path = try std.fmt.bufPrint(&blob_path, "blobs/{x:0>16}.blob", .{response_ref});
    try session.dir.deleteFile(io, response_path);
    const substituted = try model_protocol.encodeText(&response_buffer, "substituted final answer");
    try session.storeBlob(response_ref, substituted);
    try std.testing.expectError(
        error.CompletionResultDigestMismatch,
        readResponseWindow(&session, &restored, response, response.text, &answer_buffer),
    );
}

test "restored tool arguments reject same-reference substitution and oversized blobs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    var database_path_buffer: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/tool-window-test.sqlite3",
        .{tmp.sub_path},
    );
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = ".",
        .model = "fixture:window",
        .task = "Recover tool arguments",
    });
    defer session.close();

    const response_ref: u64 = 3001;
    const descriptor_ref: u64 = 3000;
    const descriptor_bytes = "tool window descriptor";
    try session.storeBlob(descriptor_ref, descriptor_bytes);
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const original = try model_protocol.encodeTool(
        &validation.json.arena,
        &response_buffer,
        model_contract.bash_key,
        "{\"command\":\"true\",\"timeout_ms\":1000}",
    );
    try session.storeBlob(response_ref, original);

    var slot: core_image.ActivationSlot = undefined;
    var core = try core_image.Core.initialize(&slot, .{ .agent_id = session.agent_id, .generation = 1 });
    defer core.abandon();
    try core.startTask(1);
    const operation = try core.beginModelOperation(3, 1);
    const identity: core_image.OperationIdentity = .{ .id = operation.id, .generation = operation.generation };
    try core.acceptOperation(identity);
    _ = try core.applyModelResponse(
        identity,
        original,
        try model_protocol.validate(&validation, original),
        response_ref,
    );
    const context = operationContext(&session, operation.id, operation.generation);
    const descriptor_digest: binding.Descriptor = .{ .model = binding.hash(binding.ModelDescriptor, descriptor_bytes) };
    const response_digest = binding.hash(binding.Result, original);
    _ = try session.commitSemantic(&.{
        session_transition.operationSubmitted(context, descriptor_ref, descriptor_digest, .model),
        session_transition.modelAttemptAdmitted(context, 10, descriptor_ref, descriptor_digest, 0),
    }, null, null);
    try session.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = session.ownership_epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 10,
        .result_ref = response_ref,
        .result_digest = response_digest,
    }));
    _ = try session.commitSemantic(&.{session_transition.result(.{
        .operation = context,
        .result_ref = response_ref,
        .result_digest = response_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 10 } },
    })}, null, null);
    const response = try core.response();
    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"command\":\"true\",\"timeout_ms\":1000}",
        (try readCanonicalResponseArguments(&session, &core, response, &arguments_buffer)).bytes(),
    );

    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "blobs/{x:0>16}.blob", .{response_ref});
    try session.dir.deleteFile(io, path);
    const replacement = try model_protocol.encodeTool(
        &validation.json.arena,
        &response_buffer,
        model_contract.bash_key,
        "{\"command\":\"false\",\"timeout_ms\":1000}",
    );
    try session.storeBlob(response_ref, replacement);
    try std.testing.expectError(
        error.CompletionResultDigestMismatch,
        readCanonicalResponseArguments(&session, &core, response, &arguments_buffer),
    );

    try session.dir.deleteFile(io, path);
    var oversized: [model_protocol.max_response_size + 1]u8 = @splat('x');
    try session.storeBlob(response_ref, &oversized);
    try std.testing.expectError(
        error.ResponseTooLarge,
        readCanonicalResponseArguments(&session, &core, response, &arguments_buffer),
    );
}

fn storeToolCall(
    session: *session_store.Session,
    reference: u64,
    key: []const u8,
    canonical_arguments: model_contract.CanonicalJson,
) !void {
    try model_contract.validateToolKey(key);
    const arguments = canonical_arguments.bytes();
    var header: [conversation.call_header_size]u8 = undefined;
    const header_bytes = try conversation.encodeToolCallHeader(&header, key.len, arguments.len);
    var hasher = binding.Hasher(binding.Blob).init();
    hasher.update(header_bytes);
    hasher.update(key);
    hasher.update(arguments);
    const expected_length = header_bytes.len + key.len + arguments.len;

    var existing = session.openBlob(reference) catch |err| switch (err) {
        error.FileNotFound => {
            var writer = try session.beginBlob(reference);
            errdefer writer.abort();
            try writer.append(header_bytes);
            try writer.append(key);
            try writer.append(arguments);
            try writer.finish();
            return;
        },
        else => return err,
    };
    defer existing.close();
    if (existing.length() != expected_length or
        !binding.eql(binding.Blob, existing.digest(), hasher.final()))
    {
        return error.BlobContentMismatch;
    }
}

fn storeOrExpectBlob(
    session: *session_store.Session,
    reference: u64,
    bytes: []const u8,
) !void {
    var reader = session.openBlob(reference) catch |err| switch (err) {
        error.FileNotFound => {
            try session.storeBlob(reference, bytes);
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
    reference: u64,
) !binding.Result {
    var reader = try session.openBlob(reference);
    defer reader.close();
    var hasher = binding.Hasher(binding.Result).init();
    var window: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedBlob;
        hasher.update(bytes);
        offset += bytes.len;
    }
    return hasher.final();
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
        6 => error.MultipleModelOutputs,
        7 => error.ModelResponseOversized,
        8 => error.UnknownModelTool,
        else => error.UnknownModelFailure,
    };
}

test "generic tool and input dispositions cannot bypass the closed Action mapping" {
    var host: Host = .{};
    var core = try Core.open(&host.slots);
    defer core.close();
    try core.initialize(1);
    try core.reducer.startTask(1);
    const operation = try core.reducer.beginModelOperation(2, 1);
    try core.reducer.acceptOperation(.{ .id = operation.id, .generation = operation.generation });

    var response: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const generic = try model_protocol.encodeTool(&validation.json.arena, &response, "fixture.inspect.v1", "{}");
    _ = try core.reducer.applyModelResponse(
        .{ .id = operation.id, .generation = operation.generation },
        generic,
        try model_protocol.validate(&validation, generic),
        3,
    );
    try std.testing.expectError(error.UnboundToolKey, executableToolFromKey("fixture.inspect.v1"));

    core.close();
    core = try Core.open(&host.slots);
    try core.initialize(4);
    try core.reducer.startTask(1);
    const input_operation = try core.reducer.beginModelOperation(5, 1);
    try core.reducer.acceptOperation(.{ .id = input_operation.id, .generation = input_operation.generation });
    const input = try model_protocol.encodeInputText(&response, "Which migration should I use?");
    _ = try core.reducer.applyModelResponse(
        .{ .id = input_operation.id, .generation = input_operation.generation },
        input,
        try model_protocol.validate(&validation, input),
        6,
    );
    try std.testing.expectEqual(core_state.TaskPhase.failed, (try core.reducer.task()).phase);
    try std.testing.expectError(error.UnboundToolKey, executableToolFromKey(""));
}

test "model dispatch rejects a substituted request under the bound reference" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    var git = try repo.openDir(io, ".git", .{});
    defer git.close(io);
    try git.createDir(io, "objects", .default_dir);
    try git.createDir(io, "refs", .default_dir);
    var config = try git.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);

    var repo_path_buffer: [160]u8 = undefined;
    const repo_path = try std.fmt.bufPrint(
        &repo_path_buffer,
        ".zig-cache/tmp/{s}/repo",
        .{tmp.sub_path},
    );
    var database_path_buffer: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:bound",
        .task = "Check the request binding",
    });
    defer session.close();
    const request_digest = try model_operation.buildRequest(&session, 1001, 1, 1);
    var request_blob = try session.openBlob(1001);
    const request_length: usize = @intCast(request_blob.length());
    request_blob.close();
    var request: [32 * 1024]u8 = undefined;
    const original = try session.readBlob(1001, 0, request[0..request_length]);
    request[model_operation.request_header_size] ^= 1;
    var blob_path: [32]u8 = undefined;
    const substituted_path = try std.fmt.bufPrint(&blob_path, "blobs/{x:0>16}.blob", .{@as(u64, 1001)});
    try session.dir.deleteFile(io, substituted_path);
    try session.storeBlob(1001, original);

    const CountingProvider = struct {
        calls: u32 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            _: model_operation.ResponseWriter,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    var fixture: CountingProvider = .{};
    var scratch: OwnerScratch = .{};
    try std.testing.expectError(
        error.ModelRequestDigestMismatch,
        dispatchModelAttempt(
            &session,
            session.ownerToken(),
            fixture.provider(),
            &scratch,
            .{
                .request_ref = 1001,
                .request_digest = request_digest,
                .response_ref = 1002,
                .operation_id = 1003,
                .operation_generation = 1,
                .attempt_id = 1004,
            },
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.calls);
}

fn repeatedUtf8(
    allocator: std.mem.Allocator,
    codepoint_count: usize,
    codepoint: []const u8,
) ![]u8 {
    const bytes = try allocator.alloc(u8, codepoint_count * codepoint.len);
    for (0..codepoint_count) |index| {
        @memcpy(bytes[index * codepoint.len ..][0..codepoint.len], codepoint);
    }
    return bytes;
}

fn expectBashArgumentBoundary(
    envelope: []u8,
    command: []const u8,
    accepted: bool,
) !void {
    var scratch: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    var raw: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    var arena: model_contract.CanonicalJsonArena = undefined;
    const encoded = try model_contract.encodeJson(&arena, &raw, envelope, .{
        .command = command,
        .timeout_ms = bash_tool.max_timeout_ms,
    });
    if (accepted) {
        _ = try parseBashArguments(&scratch, encoded);
    } else {
        try std.testing.expectError(error.InvalidBashArguments, parseBashArguments(&scratch, encoded));
    }
}

fn expectPatchArgumentBoundary(
    envelope: []u8,
    patch: []const u8,
    accepted: bool,
) !void {
    var scratch: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    var raw: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    var arena: model_contract.CanonicalJsonArena = undefined;
    const encoded = try model_contract.encodeJson(&arena, &raw, envelope, .{ .patch = patch });
    if (accepted) {
        _ = try parsePatchArguments(&scratch, encoded);
    } else {
        try std.testing.expectError(error.InvalidPatchArguments, parsePatchArguments(&scratch, encoded));
    }
}

test "Host reserves and scrubs one complete owner workspace per Activation Slot" {
    var host: Host = .{};
    try std.testing.expectEqual(@as(usize, 344_300), owner_scratch_size);
    try std.testing.expectEqual(@as(usize, 352_680), @sizeOf(Host));
    try std.testing.expectEqual(
        production_active_capacity * owner_scratch_size,
        @sizeOf(@TypeOf(host.owner_scratch)),
    );
    try std.testing.expectEqual(
        @sizeOf(ProductionSlotPool),
        @offsetOf(Host, "owner_scratch"),
    );
    @memset(std.mem.asBytes(&host.owner_scratch[0]), 0xa5);
    host.owner_scratch[0].scrub();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&host.owner_scratch[0]), 0));
}

test "Tool Catalog preserves byte-bounded Unicode admission" {
    const allocator = std.testing.allocator;
    const envelope = try allocator.alloc(u8, model_contract.max_tool_arguments_envelope_size);
    defer allocator.free(envelope);
    var arena: model_contract.CanonicalJsonArena = undefined;
    var raw: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;

    const bash_ascii_exact = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes, "x");
    defer allocator.free(bash_ascii_exact);
    const bash_ascii_over = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes + 1, "x");
    defer allocator.free(bash_ascii_over);
    const bash_unicode_exact = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes / "é".len, "é");
    defer allocator.free(bash_unicode_exact);
    const bash_unicode_over = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes / "é".len + 1, "é");
    defer allocator.free(bash_unicode_over);
    try expectBashArgumentBoundary(envelope, bash_ascii_exact, true);
    try expectBashArgumentBoundary(envelope, bash_ascii_over, false);
    try expectBashArgumentBoundary(envelope, bash_unicode_exact, true);
    try expectBashArgumentBoundary(envelope, bash_unicode_over, false);
    const escaped_bash = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes, "\x01");
    defer allocator.free(escaped_bash);
    const encoded_escaped_bash = try model_contract.encodeJson(&arena, &raw, envelope, .{
        .command = escaped_bash,
        .timeout_ms = bash_tool.max_timeout_ms,
    });
    try std.testing.expect(encoded_escaped_bash.len <= model_contract.max_tool_arguments_envelope_size);
    try expectBashArgumentBoundary(envelope, escaped_bash, true);

    const patch_ascii_exact = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes, "x");
    defer allocator.free(patch_ascii_exact);
    const patch_ascii_over = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes + 1, "x");
    defer allocator.free(patch_ascii_over);
    const patch_unicode_exact = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes / "é".len, "é");
    defer allocator.free(patch_unicode_exact);
    const patch_unicode_over = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes / "é".len + 1, "é");
    defer allocator.free(patch_unicode_over);
    try expectPatchArgumentBoundary(envelope, patch_ascii_exact, true);
    try expectPatchArgumentBoundary(envelope, patch_ascii_over, false);
    try expectPatchArgumentBoundary(envelope, patch_unicode_exact, true);
    try expectPatchArgumentBoundary(envelope, patch_unicode_over, false);

    const escaped_patch = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes, "\x01");
    defer allocator.free(escaped_patch);
    const encoded_patch = try model_contract.encodeJson(&arena, &raw, envelope, .{ .patch = escaped_patch });
    try std.testing.expectEqual(
        model_contract.max_tool_arguments_envelope_size,
        encoded_patch.len,
    );
    var decode_scratch: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    _ = try parsePatchArguments(&decode_scratch, encoded_patch);
    const response_buffer = try allocator.alloc(u8, model_protocol.max_response_size);
    defer allocator.free(response_buffer);
    const response = try model_protocol.encodeTool(
        &arena,
        response_buffer,
        model_contract.apply_patch_key,
        encoded_patch,
    );
    var validation: model_protocol.ValidationScratch = undefined;
    try std.testing.expectEqual(
        model_protocol.Disposition.tool_call,
        model_protocol.parse(&validation, response).disposition,
    );
}

test "Completion Inbox search never crosses evidence kinds" {
    var search: InboxSearch = .{
        .session_id = 1,
        .agent_id = 2,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .maximum_epoch = 5,
        .expected_epoch = 5,
        .expected_kind = .apply_patch,
    };
    const wrong = completion_inbox.bind(.{
        .kind = .bash,
        .session_id = 1,
        .ownership_epoch = 5,
        .agent_id = 2,
        .agent_generation = agent_generation,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .result_ref = 6,
        .result_digest = binding.hash(binding.Result, "result"),
    });
    try InboxSearch.apply(&search, wrong);
    try std.testing.expect(search.match == null);
}

test "Completion Inbox search binds evidence to the admitted Attempt epoch" {
    var search: InboxSearch = .{
        .session_id = 1,
        .agent_id = 2,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .maximum_epoch = 6,
        .expected_epoch = 5,
        .expected_kind = .model,
    };
    const rebound = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 6,
        .agent_id = 2,
        .agent_generation = agent_generation,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .result_ref = 6,
        .result_digest = binding.hash(binding.Result, "result"),
    });
    try std.testing.expectError(
        error.CompletionAttemptEpochMismatch,
        InboxSearch.apply(&search, rebound),
    );
    try std.testing.expect(search.match == null);
}
