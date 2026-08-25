const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const checkpoint = @import("checkpoint.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const durable_transition = @import("durable_transition.zig");
const harness = @import("harness.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const operation_log = @import("operation_log.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

const agent_generation: u32 = 1;
const ProductionSlotPool = core_image.SlotPool(1);

/// Process-owned bounded activation capacity. Construct this once at host
/// startup and pass it through every agent lifecycle entry point.
pub const Host = struct {
    slots: ProductionSlotPool = .{},
};

pub const NewConfig = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
    fault: ?FaultHook = null,
    bash_policy: ?bash_tool.Policy = null,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    patch_policy: ?patch_tool.Policy = null,
};

pub const FaultBoundary = enum {
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

pub const Observer = struct {
    context: *anyopaque,
    session_created: *const fn (*anyopaque, u64) anyerror!void,
};

pub const Completed = struct {
    session: session_store.Session,
    final_ref: u64,

    pub fn close(self: *Completed) void {
        self.session.close();
    }
};

const OperationIds = struct {
    operation_id: u32,
    attempt_id: u64,
    request_ref: u64,
    response_ref: u32,
    final_ref: u64,
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

fn publishCoreCheckpoint(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    checkpoint_buffer: []u8,
    core: *Core,
    reactivate: bool,
) !void {
    try core.suspendIntoState();
    try session.publishCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        &core.encoded_state,
    );
    if (reactivate) try core.activate();
}

fn restoreCoreCheckpoint(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    checkpoint_buffer: []u8,
    core: *Core,
) !void {
    try session.restoreCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        &core.encoded_state,
    );
    try core.activate();
}

const ModelSlot = struct {
    core: *Core,
    session: *session_store.Session,
    token: session_store.OwnerToken,

    fn inspect(
        context: *anyopaque,
        completion: harness.Completion,
    ) anyerror!durable_transition.SlotState {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        const operation = try self.core.reducer.operation();
        if (operation.id != completion.operation_id or
            operation.generation != completion.operation_generation)
        {
            return error.CoreOperationMismatch;
        }
        return switch (operation.phase) {
            .accepted => .accepted,
            .completed => blk: {
                if (operation.result_ref != completion.result) {
                    return error.CoreResultMismatch;
                }
                break :blk .completed;
            },
            else => error.InvalidCoreOperationState,
        };
    }

    fn apply(context: *anyopaque, completion: harness.Completion) anyerror!void {
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

    fn interface(self: *ModelSlot) durable_transition.Slot {
        return .{ .context = self, .inspect = inspect, .apply = apply };
    }
};

const PersistFault = struct {
    hook: FaultHook,

    fn afterPersist(context: *anyopaque) anyerror!void {
        const self: *PersistFault = @ptrCast(@alignCast(context));
        try self.hook.reached(self.hook.context, .after_completion_persist);
    }
};

pub fn runNew(
    host: *Host,
    sessions: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    config: NewConfig,
    provider: model_operation.Provider,
    observer: ?Observer,
) !Completed {
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    var session = try session_store.Session.create(sessions, io, .{
        .workspace_path = config.workspace_path,
        .model = config.model,
        .task = config.task,
    });
    errdefer session.close();
    if (observer) |value| try value.session_created(value.context, session.session_id);
    const token = session.ownerToken();
    try core.initialize(session.agent_id);
    try core.reducer.startTask(session.active_leaf_id);
    var journal = try session.openOperationJournal(token);
    defer journal.close(io);
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    var model_sequence: u32 = 1;
    while (model_sequence <= 2) : (model_sequence += 1) {
        const ids = try performModelTurn(
            io,
            &session,
            token,
            &core,
            &host.slots,
            &core_open,
            checkpoint_buffer,
            &journal,
            provider,
            model_sequence,
            config.fault,
        );
        const response = try core.reducer.response();
        if (response.disposition == .final_answer) {
            const final_ref = try finalizeCandidate(
                &session,
                token,
                &core,
                checkpoint_buffer,
                config.fault,
            );
            return .{ .session = session, .final_ref = final_ref };
        }
        if (response.disposition != .tool_call) {
            return modelFailure(@intFromEnum(response.failure));
        }
        if (model_sequence != 1) return error.TooManyModelTurns;
        switch (response.tool) {
            .bash => {
                const policy = config.bash_policy orelse return error.ToolCallDeferred;
                try executeBashCall(
                    io,
                    allocator,
                    &session,
                    token,
                    &core,
                    &host.slots,
                    checkpoint_buffer,
                    &journal,
                    ids,
                    &core_open,
                    config.workspace_path,
                    policy,
                    config.bash_cancelled,
                    config.fault,
                );
            },
            .apply_patch => {
                const policy = config.patch_policy orelse return error.ToolCallDeferred;
                const outcome = try requestPatchPermission(
                    io,
                    allocator,
                    &session,
                    token,
                    &core,
                    checkpoint_buffer,
                    &journal,
                    ids,
                    config.workspace_path,
                    policy,
                    config.fault,
                );
                if (outcome == .approved) return error.PatchExecutionDeferred;
            },
            else => return error.UnsupportedTool,
        }
    }
    return error.FinalAnswerMissing;
}

fn performModelTurn(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    slot_pool: *ProductionSlotPool,
    core_open: *bool,
    checkpoint_buffer: []u8,
    journal: *operation_log.Writer,
    provider: model_operation.Provider,
    model_sequence: u32,
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
    try journal.appendDurable(io, .{
        .kind = .accepted,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = ids.operation_id,
        .operation_generation = operation_generation,
        .attempt_id = ids.attempt_id,
        .ownership_epoch = token.epoch,
        .recovery_class = .billable_retry,
        .sequence = journal.last_sequence + 1,
        .descriptor_digest = descriptor.digest,
        .result = 0,
    });
    try core.reducer.acceptOperation(.{ .id = ids.operation_id, .generation = operation_generation });
    try publishCoreCheckpoint(session, token, checkpoint_buffer, core, false);
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

    core.* = try Core.open(slot_pool);
    core_open.* = true;
    try restoreCoreCheckpoint(session, token, checkpoint_buffer, core);
    var slot: ModelSlot = .{ .core = core, .session = session, .token = token };
    var persist_fault: PersistFault = undefined;
    if (fault) |hook| persist_fault = .{ .hook = hook };
    var adapter: durable_transition.Adapter = .{
        .io = io,
        .dir = session.dir,
        .journal_path = "operations.log",
        .writer = journal,
        .ownership_epoch = token.epoch,
        .slot = slot.interface(),
        .fault = if (fault != null) .{
            .context = &persist_fault,
            .after_persist = PersistFault.afterPersist,
        } else null,
    };
    var owner = try harness.Harness.open(.{
        .input_capacity = 1,
        .drive_quantum = 1,
        .transition = adapter.transition(),
        .owner_fence = session.fence(),
    });
    try expectQueued(owner.offer(.{ .completion = .{
        .agent_id = session.agent_id,
        .operation_id = ids.operation_id,
        .ownership_epoch = token.epoch,
        .result = ids.response_ref,
        .agent_generation = agent_generation,
        .operation_generation = operation_generation,
    } }));
    _ = try owner.drive();
    return ids;
}

fn executeBashCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    slot_pool: *ProductionSlotPool,
    checkpoint_buffer: []u8,
    journal: *operation_log.Writer,
    ids: OperationIds,
    core_open: *bool,
    workspace_path: []const u8,
    policy: bash_tool.Policy,
    cancellation: ?*const std.atomic.Value(bool),
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
    try appendToolRecord(journal, io, session, token, .descriptor_validated, tool_operation_id, 0, digest, 0);
    const call_entry = try session.appendConversation(token, .assistant, descriptor_ref, null);

    const allowed = try policy.decide(digest, call);
    try appendToolRecord(
        journal,
        io,
        session,
        token,
        .permission_decided,
        tool_operation_id,
        0,
        digest,
        if (allowed) 1 else 2,
    );

    var attempt_id: u64 = 0;
    var execution: bash_tool.Execution = undefined;
    if (allowed) {
        while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
        try appendToolRecord(journal, io, session, token, .attempt_started, tool_operation_id, attempt_id, digest, 0);
        try publishCoreCheckpoint(session, token, checkpoint_buffer, core, false);
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
        try restoreCoreCheckpoint(session, token, checkpoint_buffer, core);
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
    if (allowed) {
        try appendToolRecord(journal, io, session, token, .attempt_result, tool_operation_id, attempt_id, digest, result_ref);
    } else {
        try appendToolRecord(journal, io, session, token, .denied_result, tool_operation_id, 0, digest, result_ref);
    }
    try reach(fault, .after_bash_result);
    const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
    try reach(fault, .after_tool_result_entry);
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
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
    journal: *operation_log.Writer,
    ids: OperationIds,
    workspace_path: []const u8,
    policy: patch_tool.Policy,
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
    try appendToolRecord(
        journal,
        io,
        session,
        token,
        .descriptor_validated,
        tool_operation_id,
        0,
        validation.patch_digest,
        0,
    );
    const call_entry = try session.appendConversation(token, .assistant, patch_ref, null);

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
        try appendToolRecord(
            journal,
            io,
            session,
            token,
            .approval_required,
            tool_operation_id,
            0,
            validation.patch_digest,
            approval_ref,
        );
        try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
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
    try appendToolRecord(
        journal,
        io,
        session,
        token,
        .permission_bound,
        tool_operation_id,
        0,
        validation.patch_digest,
        permission_ref,
    );
    try reach(fault, .after_patch_permission_binding);
    try appendToolRecord(
        journal,
        io,
        session,
        token,
        .permission_decided,
        tool_operation_id,
        0,
        validation.patch_digest,
        if (allowed) 1 else 2,
    );

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
                try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
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
    try appendToolRecord(
        journal,
        io,
        session,
        token,
        .preflight_result,
        tool_operation_id,
        0,
        validation.patch_digest,
        result_ref,
    );
    const result_entry = try session.appendConversation(token, .tool_result, result_ref, null);
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
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

fn appendToolRecord(
    journal: *operation_log.Writer,
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    kind: operation_log.Kind,
    operation_id: u64,
    attempt_id: u64,
    digest: u64,
    result: u64,
) !void {
    try journal.appendDurable(io, .{
        .kind = kind,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = 1,
        .attempt_id = attempt_id,
        .ownership_epoch = token.epoch,
        .recovery_class = .consequential,
        .sequence = journal.last_sequence + 1,
        .descriptor_digest = digest,
        .result = result,
    });
}

pub fn resumeSession(
    host: *Host,
    sessions: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    session_id: u64,
) !Completed {
    var core = try Core.open(&host.slots);
    defer core.close();
    var manifest_buffer: [session_store.manifest_max_size]u8 = undefined;
    var restored = try session_store.Session.openExisting(
        sessions,
        io,
        session_id,
        &manifest_buffer,
    );
    errdefer restored.session.close();
    const token = restored.session.ownerToken();
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    try restoreCoreCheckpoint(&restored.session, token, checkpoint_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        const completion = try durableCompletion(&restored.session, token, &core);
        var slot: ModelSlot = .{ .core = &core, .session = &restored.session, .token = token };
        try ModelSlot.apply(&slot, completion);
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .final_candidate) {
        const final_ref = try finalizeCandidate(
            &restored.session,
            token,
            &core,
            checkpoint_buffer,
            null,
        );
        return .{ .session = restored.session, .final_ref = final_ref };
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            &restored.session,
            token,
            &core,
            checkpoint_buffer,
            allocator,
            restored.manifest.workspace_path,
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => return error.SessionNeedsModel,
            .approval_required => return error.PatchApprovalRequired,
            .approved => return error.PatchExecutionDeferred,
            .none => return error.ToolCallDeferred,
        }
    }
    if (outcome == .failed) return modelFailure(@intFromEnum((try core.reducer.response()).failure));
    if (outcome == .ready) return error.SessionNeedsModel;
    if (outcome != .finished) return error.SessionNotFinished;
    const entry_id = (try core.reducer.task()).final_entry_id;
    if (entry_id != restored.session.active_leaf_id) return error.FinalEntryMismatch;
    const entry = try restored.session.readEntry(entry_id);
    if (entry.kind != .assistant) return error.InvalidFinalEntry;
    return .{ .session = restored.session, .final_ref = entry.content_ref };
}

pub fn resumeWithProvider(
    host: *Host,
    sessions: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    session_id: u64,
    provider: model_operation.Provider,
) !Completed {
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    var manifest_buffer: [session_store.manifest_max_size]u8 = undefined;
    var restored = try session_store.Session.openExisting(
        sessions,
        io,
        session_id,
        &manifest_buffer,
    );
    errdefer restored.session.close();
    const token = restored.session.ownerToken();
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    try restoreCoreCheckpoint(&restored.session, token, checkpoint_buffer, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        const completion = try durableCompletion(&restored.session, token, &core);
        var slot: ModelSlot = .{ .core = &core, .session = &restored.session, .token = token };
        try ModelSlot.apply(&slot, completion);
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            &restored.session,
            token,
            &core,
            checkpoint_buffer,
            allocator,
            restored.manifest.workspace_path,
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => outcome = .ready,
            .approval_required => return error.PatchApprovalRequired,
            .approved => return error.PatchExecutionDeferred,
            .none => return error.ToolCallDeferred,
        }
    }
    if (outcome != .ready) return error.SessionNotReadyForModel;
    var journal = try restored.session.openOperationJournal(token);
    defer journal.close(io);
    _ = try performModelTurn(
        io,
        &restored.session,
        token,
        &core,
        &host.slots,
        &core_open,
        checkpoint_buffer,
        &journal,
        provider,
        2,
        null,
    );
    if ((try core.reducer.response()).disposition != .final_answer) {
        return error.ResumedModelDidNotFinish;
    }
    const final_ref = try finalizeCandidate(
        &restored.session,
        token,
        &core,
        checkpoint_buffer,
        null,
    );
    return .{ .session = restored.session, .final_ref = final_ref };
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
    var reader = try session.openOperationReader(token);
    defer reader.close(session.io);
    var started: ?operation_log.Record = null;
    var settlement: ?operation_log.Record = null;
    var denied: ?operation_log.Record = null;
    while (try reader.next(session.io)) |record| {
        switch (record.kind) {
            .attempt_started => {
                if (record.recovery_class != .consequential) continue;
                if (started != null and settlement == null) return error.MultipleUnsettledEffects;
                started = record;
                settlement = null;
            },
            .attempt_result, .attempt_indeterminate => if (started) |attempt| {
                if (record.operation_id == attempt.operation_id and
                    record.attempt_id == attempt.attempt_id and
                    record.descriptor_digest == attempt.descriptor_digest)
                {
                    settlement = record;
                }
            },
            .denied_result => {
                if (record.recovery_class != .consequential or record.attempt_id != 0) {
                    return error.InvalidDeniedResult;
                }
                if (denied != null) return error.MultipleDeniedResults;
                denied = record;
            },
            else => {},
        }
    }
    const attempt = started orelse {
        const denied_result = denied orelse return .none;
        try reconcileBashResult(session, token, core, checkpoint_buffer, denied_result);
        return .ready;
    };
    if (settlement) |record| {
        if (record.kind == .attempt_indeterminate) return .indeterminate;
        try reconcileBashResult(session, token, core, checkpoint_buffer, record);
        return .ready;
    }
    var journal = try session.openOperationJournal(token);
    defer journal.close(session.io);
    try appendToolRecord(
        &journal,
        session.io,
        session,
        token,
        .attempt_indeterminate,
        attempt.operation_id,
        attempt.attempt_id,
        attempt.descriptor_digest,
        0,
    );
    return .indeterminate;
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
    var reader = try session.openOperationReader(token);
    defer reader.close(session.io);
    var descriptor: ?operation_log.Record = null;
    var approval: ?operation_log.Record = null;
    var permission_binding: ?operation_log.Record = null;
    var decision: ?operation_log.Record = null;
    var result: ?operation_log.Record = null;
    while (try reader.next(session.io)) |record| {
        if (record.operation_id != operation_id) continue;
        switch (record.kind) {
            .descriptor_validated => descriptor = try uniqueRecord(descriptor, record),
            .approval_required => approval = try uniqueRecord(approval, record),
            .permission_bound => permission_binding = try uniqueRecord(permission_binding, record),
            .permission_decided => decision = try uniqueRecord(decision, record),
            .preflight_result => result = try uniqueRecord(result, record),
            else => {},
        }
    }
    const validated = descriptor orelse return .none;
    if (validated.descriptor_digest == 0 or validated.operation_generation != 1) {
        return error.InvalidPatchHistory;
    }
    if (result) |settled| {
        if (settled.descriptor_digest != validated.descriptor_digest or settled.result != result_ref) {
            return error.InvalidPatchHistory;
        }
        try reconcileToolResult(session, token, core, checkpoint_buffer, patch_ref, settled);
        return .ready;
    }
    const bound = permission_binding orelse return if (approval != null) .approval_required else .none;
    if (bound.descriptor_digest != validated.descriptor_digest) {
        return error.InvalidPatchHistory;
    }
    var binding_bytes: [patch_tool.binding_size]u8 = undefined;
    try readExactBlob(session, token, bound.result, &binding_bytes);
    const binding = try patch_tool.decodeBinding(&binding_bytes);
    if (binding.operation_id != operation_id or binding.operation_generation != 1 or
        binding.patch_ref != patch_ref or binding.patch_digest != validated.descriptor_digest)
    {
        return error.InvalidPatchPermissionBinding;
    }
    const decision_result: u64 = switch (binding.decision) {
        .allow => 1,
        .deny => 2,
        .ask => return error.InvalidFinalPatchPermission,
    };
    if (decision) |decided| {
        if (decided.descriptor_digest != validated.descriptor_digest or decided.result != decision_result) {
            return error.InvalidPatchHistory;
        }
    } else {
        var journal = try session.openOperationJournal(token);
        defer journal.close(session.io);
        try appendToolRecord(
            &journal,
            session.io,
            session,
            token,
            .permission_decided,
            operation_id,
            0,
            validated.descriptor_digest,
            decision_result,
        );
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
            validated.descriptor_digest,
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
        validated.descriptor_digest,
        .denied,
        binding.workspace_digest,
        0,
    );
    return .ready;
}

fn uniqueRecord(existing: ?operation_log.Record, record: operation_log.Record) !operation_log.Record {
    if (existing != null) return error.DuplicatePatchRecord;
    return record;
}

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
    var journal = try session.openOperationJournal(token);
    defer journal.close(session.io);
    try appendToolRecord(
        &journal,
        session.io,
        session,
        token,
        .preflight_result,
        operation_id,
        0,
        descriptor_digest,
        result_ref,
    );
    try reconcileToolResult(
        session,
        token,
        core,
        checkpoint_buffer,
        patch_ref,
        .{
            .kind = .preflight_result,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = 0,
            .ownership_epoch = token.epoch,
            .recovery_class = .consequential,
            .sequence = journal.last_sequence,
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
    result: operation_log.Record,
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
    result: operation_log.Record,
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
    try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
}

fn durableCompletion(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
) !harness.Completion {
    const operation = try core.reducer.operation();
    const operation_id = operation.id;
    const operation_generation = operation.generation;
    var reader = try session.openOperationReader(token);
    defer reader.close(session.io);
    var accepted: ?operation_log.Record = null;
    var completed: ?operation_log.Record = null;
    while (try reader.next(session.io)) |record| {
        if (record.agent_id != session.agent_id or
            record.agent_generation != agent_generation or
            record.operation_id != operation_id or
            record.operation_generation != operation_generation)
        {
            continue;
        }
        switch (record.kind) {
            .accepted => {
                if (accepted != null) return error.InvalidOperationHistory;
                accepted = record;
            },
            .completed => {
                if (completed != null) return error.InvalidOperationHistory;
                completed = record;
            },
            else => {},
        }
    }
    const intent = accepted orelse return error.MissingAcceptedAttempt;
    const result = completed orelse return error.SessionOperationPending;
    if (result.attempt_id != intent.attempt_id or
        result.ownership_epoch != intent.ownership_epoch or
        result.recovery_class != intent.recovery_class or
        result.descriptor_digest != intent.descriptor_digest or
        result.sequence <= intent.sequence or result.result == 0)
    {
        return error.InvalidOperationHistory;
    }
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = intent.ownership_epoch,
        .result = result.result,
    };
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
    try publishCoreCheckpoint(session, token, checkpoint_buffer, core, true);
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

fn expectQueued(result: harness.OfferResult) !void {
    if (result != .queued) return error.CompletionAdmissionFailed;
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
