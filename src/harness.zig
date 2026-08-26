const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const core_state = @import("core_state.zig");
const completion_inbox = @import("completion_inbox.zig");
const host_runtime = @import("host_runtime.zig");
const host_store = @import("host_store.zig");
const lifecycle = @import("lifecycle.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

pub const HostRuntime = host_runtime.HostRuntime;
pub const HostRuntimeConfig = host_runtime.Config;
pub const FaultBoundary = lifecycle.FaultBoundary;
pub const FaultHook = lifecycle.FaultHook;
pub const default_recovery_quantum: u8 = 32;
pub const max_recovery_records: usize = session_transition.max_transitions + completion_inbox.max_records;

pub const PermissionMode = enum {
    ask,
    bypass,
};

pub const Create = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
    provider: model_operation.Provider,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    fault: ?FaultHook = null,
};

pub const Restore = struct {
    session_id: u64,
    provider: ?model_operation.Provider = null,
};

pub const OpenMode = union(enum) {
    create: Create,
    restore: Restore,
};

pub const Config = struct {
    runtime: *HostRuntime,
    mode: OpenMode,
    permission_mode: PermissionMode = .ask,
    recovery_quantum: u8 = default_recovery_quantum,
};

pub const Input = union(enum) {
    task,
    permission: PermissionDecision,
    completion: Completion,
    cancel,
    shutdown,
};

pub const PermissionDecision = struct {
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: u64,
    allow: bool,
};

pub const Completion = struct {
    kind: CompletionKind,
    session_id: u64,
    ownership_epoch: u64,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    result_ref: u64,
    result_digest: u64,
};

pub const CompletionKind = enum { model, bash, apply_patch };

pub const OfferResult = enum {
    accepted,
    full,
    busy,
    unavailable,
    closed,
    invalid,
};

pub const State = enum {
    ready,
    restoring,
    running,
    waiting,
    cancelling,
    finished,
    cancelled,
    failed,
    closed,
    unavailable,
};

pub const ProjectionKind = enum {
    session,
    task_admitted,
    approval_required,
    indeterminate,
    final_answer,
    cancelled,
    failure,
    outcome,
    closed,
};

pub const Projection = struct {
    kind: ProjectionKind,
    session_id: u64,
    task_id: u64 = 0,
    operation_id: u64 = 0,
    operation_generation: u32 = 0,
    descriptor_digest: u64 = 0,
    content_ref: u64 = 0,
    session: ?*session_store.Session = null,
    owner_generation: ?*const u64 = null,
    generation: u64 = 0,

    pub fn openContent(self: Projection) !session_store.BlobReader {
        const session = self.session orelse return error.ProjectionHasNoContent;
        const owner_generation = self.owner_generation orelse return error.StaleProjection;
        if (owner_generation.* != self.generation or self.content_ref == 0 or
            self.session_id != session.session_id)
        {
            return error.StaleProjection;
        }
        return session.openBlob(session.ownerToken(), self.content_ref);
    }
};

pub const Progress = struct {
    state: State,
    consumed: u8 = 0,
    committed: u8 = 0,
    dispatched: u8 = 0,
    projections: [4]Projection = undefined,
    projection_count: u8 = 0,
    more: bool = false,

    pub fn projectionSlice(self: *const Progress) []const Projection {
        return self.projections[0..self.projection_count];
    }
};

pub const Harness = struct {
    config: Config,
    pending: ?Input = null,
    state: State,
    session: ?session_store.Session = null,
    session_projection_pending: bool = false,
    final_ref: u64 = 0,
    core_state_buffer: [core_state.encoded_size]u8 = undefined,
    projection_generation: u64 = 0,
    awaiting_approval: ?lifecycle.ApprovalRequired = null,
    settling_control: ?lifecycle.Control = null,
    recovery_pending: bool = false,
    runtime_retained: bool = false,
    ingress_lock: std.Io.Mutex = .init,
    drive_lock: std.Io.Mutex = .init,

    pub fn open(config: Config) !Harness {
        if (config.recovery_quantum == 0) return error.InvalidRecoveryQuantum;
        switch (config.mode) {
            .create => |create| {
                if (create.workspace_path.len == 0 or create.model.len == 0 or
                    create.task.len == 0)
                {
                    return error.InvalidCreateRequest;
                }
            },
            .restore => |restore| if (restore.session_id == 0) return error.InvalidSessionIdentity,
        }
        try host_runtime.retainHarness(config.runtime);
        errdefer host_runtime.releaseHarness(config.runtime);
        var owner: Harness = .{
            .config = config,
            .state = switch (config.mode) {
                .create => .ready,
                .restore => .restoring,
            },
            .runtime_retained = true,
        };
        errdefer if (owner.session) |*session| session.close();
        switch (config.mode) {
            .create => |create| owner.session = try session_store.Session.create(
                host_runtime.stateRoot(config.runtime),
                host_runtime.storageOwner(config.runtime),
                host_runtime.getIo(config.runtime),
                .{
                    .workspace_path = create.workspace_path,
                    .model = create.model,
                    .task = create.task,
                },
            ),
            .restore => |restore| {
                const restored = try session_store.Session.openExisting(
                    host_runtime.stateRoot(config.runtime),
                    host_runtime.storageOwner(config.runtime),
                    host_runtime.getIo(config.runtime),
                    restore.session_id,
                );
                owner.session = restored.session;
                owner.recovery_pending = true;
                const session = &owner.session.?;
                if (try session.recoveryIsEmpty(session.ownerToken())) {
                    _ = try session.recoverSemanticWindow(session.ownerToken(), 1);
                    owner.recovery_pending = false;
                    owner.setState(.ready);
                }
            },
        }
        owner.session_projection_pending = true;
        return owner;
    }

    pub fn offer(self: *Harness, input: Input) OfferResult {
        if (!self.ingress_lock.tryLock()) return .busy;
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        if (self.state == .closed) return .closed;
        if (self.state == .unavailable) return .unavailable;
        if (self.pending != null) return .full;
        if (!self.accepts(input)) return .invalid;
        if (input == .permission) {
            const decision = input.permission;
            const expected = self.awaiting_approval orelse return .invalid;
            if (decision.operation_id != expected.operation_id or
                decision.operation_generation != expected.operation_generation or
                decision.descriptor_digest != expected.descriptor_digest)
            {
                return .invalid;
            }
        }
        self.pending = input;
        return .accepted;
    }

    pub fn drive(self: *Harness) !Progress {
        if (!self.drive_lock.tryLock()) return error.HarnessBusy;
        defer self.drive_lock.unlock(host_runtime.getIo(self.config.runtime));
        if (self.state == .unavailable) return error.HarnessUnavailable;
        if (self.projection_generation == std.math.maxInt(u64)) return error.ProjectionGenerationExhausted;
        self.projection_generation += 1;
        if (self.recovery_pending) {
            const session = &self.session.?;
            const recovery = session.recoverSemanticWindow(
                session.ownerToken(),
                self.config.recovery_quantum,
            ) catch |err| {
                self.setState(.unavailable);
                return err;
            };
            if (recovery.more) return .{
                .state = .restoring,
                .consumed = recovery.processed,
                .more = true,
            };
            if (self.session_projection_pending) {
                return self.publishSessionIdentity(true);
            }
            self.recovery_pending = false;
            const restored_control = lifecycle.restoredControl(session) catch |err| {
                self.setState(.unavailable);
                return err;
            };
            if (restored_control) |control| {
                self.setState(if (control == .cancel) .cancelled else .closed);
            }
        }

        if (self.session_projection_pending) {
            return self.publishSessionIdentity(false);
        }

        if (self.state == .closed or self.state == .cancelled) {
            const session = if (self.session) |*value| value else return error.SessionUnavailable;
            var terminal: Progress = .{ .state = self.state };
            terminal.projections[0] = .{
                .kind = if (self.state == .closed) .closed else .cancelled,
                .session_id = session.session_id,
                .task_id = session.task_id,
                .session = session,
            };
            terminal.projection_count = 1;
            return terminal;
        }

        const current_input = self.takePending();
        if (self.state == .cancelling and current_input == null) {
            return self.continueSettlingControl();
        }
        if (self.state == .finished and current_input == null) {
            if (self.final_ref != 0) return self.finish(.{ .state = .finished });
            return .{ .state = .finished };
        }
        var progress: Progress = .{ .state = self.state };
        if (current_input) |pending| switch (pending) {
            .permission => |decision| {
                progress.consumed = 1;
                const expected = self.approvalSnapshot() orelse return error.PermissionNotRequested;
                if (decision.operation_id != expected.operation_id or
                    decision.operation_generation != expected.operation_generation or
                    decision.descriptor_digest != expected.descriptor_digest)
                {
                    return error.StalePermissionDecision;
                }
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                const provider = switch (self.config.mode) {
                    .create => |create| @as(?model_operation.Provider, create.provider),
                    .restore => |restore| restore.provider,
                };
                self.setState(.running);
                self.final_ref = lifecycle.resolvePermission(
                    host_runtime.executionHost(self.config.runtime),
                    host_runtime.getAllocator(self.config.runtime),
                    session,
                    &self.core_state_buffer,
                    expected,
                    decision.allow,
                    provider,
                    switch (self.config.mode) {
                        .create => |create| create.bash_cancelled,
                        .restore => null,
                    },
                    self.completionHook(),
                ) catch |err| {
                    try self.refreshApprovalRequired(session);
                    return self.classifyLifecycleError(err, progress);
                };
                try self.refreshApprovalRequired(session);
                // Continue below to publish the terminal projections.
            },
            .completion => |completion| {
                progress.consumed = 1;
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                self.setState(.running);
                self.final_ref = lifecycle.acceptCompletion(
                    host_runtime.executionHost(self.config.runtime),
                    host_runtime.getAllocator(self.config.runtime),
                    session,
                    &self.core_state_buffer,
                    .{
                        .kind = switch (completion.kind) {
                            .model => .model,
                            .bash => .bash,
                            .apply_patch => .apply_patch,
                        },
                        .session_id = completion.session_id,
                        .ownership_epoch = completion.ownership_epoch,
                        .agent_id = completion.agent_id,
                        .agent_generation = completion.agent_generation,
                        .operation_id = completion.operation_id,
                        .operation_generation = completion.operation_generation,
                        .attempt_id = completion.attempt_id,
                        .result_ref = completion.result_ref,
                        .result_digest = completion.result_digest,
                    },
                    self.runtimeConfig(),
                    switch (self.config.mode) {
                        .create => |create| @as(?model_operation.Provider, create.provider),
                        .restore => |restore| restore.provider,
                    },
                ) catch |err| if (self.settlingControl() != null and switch (err) {
                    error.ToolCallDeferred,
                    error.SessionNeedsModel,
                    error.PatchExecutionDeferred,
                    error.PatchApprovalRequired,
                    error.BashPossiblyExecuted,
                    => true,
                    else => false,
                }) 0 else return self.classifyLifecycleError(err, progress);
                if (self.settlingControl() != null) return self.finishSettlingControl(
                    session,
                    progress,
                );
            },
            else => {},
        };
        if (self.final_ref != 0) return self.finish(progress);
        switch (self.config.mode) {
            .create => |create| {
                const input = current_input orelse return .{ .state = .ready };
                progress.consumed = 1;
                if (input != .task) return self.consumeControl(input, progress);
                self.setState(.running);
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                self.final_ref = lifecycle.advanceCreated(
                    host_runtime.executionHost(self.config.runtime),
                    session,
                    &self.core_state_buffer,
                    self.runtimeConfig(),
                    create.provider,
                ) catch |err| return self.classifyLifecycleError(err, progress);
            },
            .restore => |restore| {
                if (current_input) |input| {
                    progress.consumed = 1;
                    if (input == .shutdown or input == .cancel) {
                        return self.consumeControl(input, progress);
                    }
                    if (input == .task and self.state == .ready) {
                        const session = if (self.session) |*value| value else return error.SessionUnavailable;
                        self.setState(.running);
                        self.final_ref = lifecycle.advanceCreated(
                            host_runtime.executionHost(self.config.runtime),
                            session,
                            &self.core_state_buffer,
                            self.runtimeConfig(),
                            restore.provider orelse return error.SessionNeedsModel,
                        ) catch |err| return self.classifyLifecycleError(err, progress);
                        if (self.final_ref != 0) return self.finish(progress);
                        return error.CompletionExpected;
                    }
                    return error.InvalidResumeInput;
                }
                self.setState(.running);
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                self.final_ref = if (restore.provider) |provider|
                    lifecycle.advanceRestored(
                        host_runtime.executionHost(self.config.runtime),
                        host_runtime.getAllocator(self.config.runtime),
                        session,
                        &self.core_state_buffer,
                        self.runtimeConfig(),
                        provider,
                    ) catch |err| return self.classifyLifecycleError(err, progress)
                else
                    lifecycle.inspectRestored(
                        host_runtime.executionHost(self.config.runtime),
                        host_runtime.getAllocator(self.config.runtime),
                        session,
                        &self.core_state_buffer,
                    ) catch |err| return self.classifyLifecycleError(err, progress);
            },
        }
        return self.finish(progress);
    }

    fn finish(self: *Harness, initial: Progress) !Progress {
        var progress = initial;
        const session = if (self.session) |*value| value else return error.SessionUnavailable;
        const final_ref = self.final_ref;
        self.setState(.finished);
        progress.state = .finished;
        progress.committed = 1;
        progress.dispatched = 1;
        progress.projections[0] = .{
            .kind = .session,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .session = session,
        };
        progress.projections[1] = .{
            .kind = .final_answer,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .content_ref = final_ref,
            .session = session,
            .owner_generation = &self.projection_generation,
            .generation = self.projection_generation,
        };
        progress.projections[2] = .{
            .kind = .outcome,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .content_ref = final_ref,
            .session = session,
            .owner_generation = &self.projection_generation,
            .generation = self.projection_generation,
        };
        progress.projection_count = 3;
        return progress;
    }

    fn publishSessionIdentity(self: *Harness, restoring: bool) Progress {
        const session = &self.session.?;
        self.session_projection_pending = false;
        var identified: Progress = .{
            .state = if (restoring) .restoring else self.state,
            .more = switch (self.config.mode) {
                .create => false,
                .restore => true,
            },
        };
        identified.projections[0] = .{
            .kind = .session,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .session = session,
        };
        identified.projection_count = 1;
        return identified;
    }

    fn consumeControl(self: *Harness, input: Input, progress: Progress) !Progress {
        var result = progress;
        switch (input) {
            .shutdown => {
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                try self.denyPendingApproval(session);
                lifecycle.commitControl(session, .shutdown) catch |err| switch (err) {
                    error.AcceptedOperationUnsettled => {
                        self.setSettlingControl(.shutdown);
                        self.setState(.cancelling);
                        result.state = .cancelling;
                        result.more = true;
                        result.projections[0] = .{
                            .kind = .outcome,
                            .session_id = session.session_id,
                            .task_id = session.task_id,
                            .session = session,
                        };
                        result.projection_count = 1;
                        return result;
                    },
                    else => return err,
                };
                self.setState(.closed);
                result.state = .closed;
                result.committed = 1;
                result.projections[0] = .{
                    .kind = .closed,
                    .session_id = session.session_id,
                    .task_id = session.task_id,
                    .session = session,
                };
                result.projection_count = 1;
            },
            .cancel => {
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                try self.denyPendingApproval(session);
                lifecycle.commitControl(session, .cancel) catch |err| switch (err) {
                    error.AcceptedOperationUnsettled => {
                        self.setSettlingControl(.cancel);
                        self.setState(.cancelling);
                        result.state = .cancelling;
                        result.more = true;
                        result.projections[0] = .{
                            .kind = .outcome,
                            .session_id = session.session_id,
                            .task_id = session.task_id,
                            .session = session,
                        };
                        result.projection_count = 1;
                        return result;
                    },
                    else => return err,
                };
                self.setState(.cancelled);
                result.state = .cancelled;
                result.committed = 1;
                result.projections[0] = .{
                    .kind = .cancelled,
                    .session_id = session.session_id,
                    .task_id = session.task_id,
                    .session = session,
                };
                result.projection_count = 1;
            },
            else => return error.InvalidControlInput,
        }
        return result;
    }

    fn denyPendingApproval(self: *Harness, session: *session_store.Session) !void {
        try self.refreshApprovalRequired(session);
        const approval = self.approvalSnapshot() orelse return;
        _ = lifecycle.resolvePermission(
            host_runtime.executionHost(self.config.runtime),
            host_runtime.getAllocator(self.config.runtime),
            session,
            &self.core_state_buffer,
            approval,
            false,
            null,
            switch (self.config.mode) {
                .create => |create| create.bash_cancelled,
                .restore => null,
            },
            self.completionHook(),
        ) catch |err| {
            try self.refreshApprovalRequired(session);
            switch (err) {
                error.SessionNeedsModel => {},
                else => return err,
            }
        };
        try self.refreshApprovalRequired(session);
    }

    fn refreshApprovalRequired(self: *Harness, session: *session_store.Session) !void {
        self.setApproval(try lifecycle.pendingApprovalRequired(session));
    }

    fn continueSettlingControl(self: *Harness) !Progress {
        if (self.settlingControl() == null) return error.MissingSettlingControl;
        const session = if (self.session) |*value| value else return error.SessionUnavailable;
        _ = lifecycle.advanceRestored(
            host_runtime.executionHost(self.config.runtime),
            host_runtime.getAllocator(self.config.runtime),
            session,
            &self.core_state_buffer,
            self.runtimeConfig(),
            null,
        ) catch |err| switch (err) {
            error.SessionOperationPending => return .{ .state = .cancelling, .more = true },
            error.SessionNeedsModel,
            error.ToolCallDeferred,
            error.PatchExecutionDeferred,
            error.PatchApprovalRequired,
            error.BashPossiblyExecuted,
            => {},
            else => {
                if (!isModelFailure(err)) {
                    self.setState(.unavailable);
                    return err;
                }
            },
        };
        return self.finishSettlingControl(session, .{ .state = .cancelling }) catch |err| switch (err) {
            error.AcceptedOperationUnsettled => return .{ .state = .cancelling, .more = true },
            else => return err,
        };
    }

    fn finishSettlingControl(
        self: *Harness,
        session: *session_store.Session,
        initial: Progress,
    ) !Progress {
        const control = self.settlingControl() orelse return error.MissingSettlingControl;
        try lifecycle.commitControl(session, control);
        self.setSettlingControl(null);
        const terminal_state: State = if (control == .cancel) .cancelled else .closed;
        self.setState(terminal_state);
        var progress = initial;
        progress.state = terminal_state;
        progress.committed = 1;
        progress.projections[0] = .{
            .kind = if (control == .cancel) .cancelled else .closed,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .session = session,
        };
        progress.projection_count = 1;
        return progress;
    }

    fn classifyLifecycleError(self: *Harness, err: anyerror, progress: Progress) anyerror!Progress {
        var result = progress;
        if (err == error.CompletionOffered) result.dispatched = 1;
        if (err == error.MissingLedgerCoreState) {
            self.setState(.ready);
            result.state = .ready;
            return result;
        }
        switch (err) {
            error.StaleCompletion,
            error.FutureCompletionEpoch,
            error.ConflictingCompletionEvidence,
            error.CompletionEvidenceMissing,
            => {
                self.setState(progress.state);
                result.projections[0] = self.failureProjection();
                result.projection_count = 1;
                return result;
            },
            else => {},
        }
        if (isModelFailure(err)) {
            self.setState(.failed);
            result.state = .failed;
            result.projections[0] = self.failureProjection();
            result.projection_count = 1;
            return result;
        }
        const kind: ProjectionKind, const state: State = switch (err) {
            error.PermissionInputRequired, error.PatchApprovalRequired => .{ .approval_required, .waiting },
            error.BashPossiblyExecuted => .{ .indeterminate, .waiting },
            error.SessionNeedsModel,
            error.ToolCallDeferred,
            error.PatchExecutionDeferred,
            error.CompletionOffered,
            => .{ .outcome, .waiting },
            error.InjectedCrash => return err,
            else => {
                self.setState(.unavailable);
                result.state = .unavailable;
                result.projections[0] = self.failureProjection();
                result.projection_count = 1;
                return result;
            },
        };
        self.setState(state);
        result.state = state;
        const session = if (self.session) |*value| value else return error.SessionUnavailable;
        if (kind == .approval_required and self.approvalSnapshot() == null) {
            self.setApproval(try lifecycle.pendingApprovalRequired(session));
        }
        var projection: Projection = .{
            .kind = kind,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .session = session,
        };
        if (self.approvalSnapshot()) |approval| {
            projection.operation_id = approval.operation_id;
            projection.operation_generation = approval.operation_generation;
            projection.descriptor_digest = approval.descriptor_digest;
            projection.content_ref = approval.descriptor_ref;
            projection.owner_generation = &self.projection_generation;
            projection.generation = self.projection_generation;
        }
        result.projections[0] = projection;
        result.projection_count = 1;
        return result;
    }

    fn isModelFailure(err: anyerror) bool {
        return switch (err) {
            error.ModelResponseTruncated,
            error.ModelResponseAborted,
            error.ModelProviderFailed,
            error.MalformedModelResponse,
            error.EmptyModelResponse,
            error.MultipleModelTools,
            error.UnknownModelFailure,
            => true,
            else => false,
        };
    }

    fn failureProjection(self: *Harness) Projection {
        const session = &self.session.?;
        return .{
            .kind = .failure,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .session = session,
        };
    }

    fn approvalRequired(context: *anyopaque, approval: lifecycle.ApprovalRequired) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context));
        self.setApproval(approval);
    }

    fn adapterCompletionOffered(context: *anyopaque, evidence: completion_inbox.Envelope) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context));
        const completion: Completion = .{
            .kind = switch (evidence.kind) {
                .model => .model,
                .bash => .bash,
                .apply_patch => .apply_patch,
            },
            .session_id = evidence.session_id,
            .ownership_epoch = evidence.ownership_epoch,
            .agent_id = evidence.agent_id,
            .agent_generation = evidence.agent_generation,
            .operation_id = evidence.operation_id,
            .operation_generation = evidence.operation_generation,
            .attempt_id = evidence.attempt_id,
            .result_ref = evidence.result_ref,
            .result_digest = evidence.result_digest,
        };
        switch (self.offer(.{ .completion = completion })) {
            .accepted => {},
            .full => {}, // Durable Inbox evidence preserves a notification that loses live custody.
            else => return error.CompletionOfferRejected,
        }
    }

    fn completionHook(self: *Harness) lifecycle.CompletionHook {
        return .{ .context = self, .offered = adapterCompletionOffered };
    }

    fn runtimeConfig(self: *Harness) lifecycle.RuntimeConfig {
        const session = &self.session.?;
        return .{
            .workspace_path = session.workspacePath(),
            .fault = switch (self.config.mode) {
                .create => |create| create.fault,
                .restore => null,
            },
            .bash_policy = self.bashPolicy(),
            .bash_cancelled = switch (self.config.mode) {
                .create => |create| create.bash_cancelled,
                .restore => null,
            },
            .patch_policy = self.patchPolicy(),
            .approval_required_hook = self.approvalRequiredHook(),
            .completion_hook = self.completionHook(),
            .settle_only = self.settlingControl() != null,
        };
    }

    fn approvalRequiredHook(self: *Harness) lifecycle.ApprovalRequiredHook {
        return .{ .context = self, .required = approvalRequired };
    }

    fn classifyBash(context: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bash_tool.Decision {
        const self: *Harness = @ptrCast(@alignCast(context));
        return if (self.config.permission_mode == .bypass) .allow else .ask;
    }

    fn requestBashPermission(_: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bool {
        return error.PermissionInputRequired;
    }

    fn bashPolicy(self: *Harness) bash_tool.Policy {
        return .{ .context = self, .classify_fn = classifyBash, .ask_fn = requestBashPermission };
    }

    fn classifyPatch(context: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        const self: *Harness = @ptrCast(@alignCast(context));
        return if (self.config.permission_mode == .bypass) .allow else .ask;
    }

    fn requestPatchPermission(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        return error.PermissionInputRequired;
    }

    fn patchPolicy(self: *Harness) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classifyPatch, .ask_fn = requestPatchPermission };
    }

    fn accepts(self: *const Harness, input: Input) bool {
        return switch (input) {
            .task => self.state == .ready,
            .permission => self.state == .waiting,
            .completion => self.state == .restoring or self.state == .running or
                self.state == .waiting or self.state == .cancelling,
            .cancel => self.state != .finished and self.state != .cancelled and self.state != .cancelling,
            .shutdown => self.state != .cancelling,
        };
    }

    fn takePending(self: *Harness) ?Input {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn setState(self: *Harness, state: State) void {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        self.state = state;
    }

    fn approvalSnapshot(self: *Harness) ?lifecycle.ApprovalRequired {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        return self.awaiting_approval;
    }

    fn setApproval(self: *Harness, approval: ?lifecycle.ApprovalRequired) void {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        self.awaiting_approval = approval;
    }

    fn settlingControl(self: *Harness) ?lifecycle.Control {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        return self.settling_control;
    }

    fn setSettlingControl(self: *Harness, control: ?lifecycle.Control) void {
        self.ingress_lock.lockUncancelable(host_runtime.getIo(self.config.runtime));
        defer self.ingress_lock.unlock(host_runtime.getIo(self.config.runtime));
        self.settling_control = control;
    }

    pub fn close(self: *Harness) void {
        if (self.projection_generation != std.math.maxInt(u64)) self.projection_generation += 1;
        if (self.session) |*session| session.close();
        self.session = null;
        self.pending = null;
        self.setState(.closed);
        if (self.runtime_retained) {
            host_runtime.releaseHarness(self.config.runtime);
            self.runtime_retained = false;
        }
    }
};

fn openTestRuntime(tmp: *const std.testing.TmpDir) !*HostRuntime {
    return openTestRuntimeConfigured(tmp, .{});
}

fn openTestRuntimeConfigured(
    tmp: *const std.testing.TmpDir,
    config: host_store.Config,
) !*HostRuntime {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    return HostRuntime.open(
        std.testing.io,
        std.testing.allocator,
        path,
        .{ .storage = config },
    );
}

test "open retains no Activation Slot and offer transfers one bounded input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: model_operation.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:answer",
            .task = "task",
            .provider = fixture.provider(),
        } },
    });
    defer owner.close();
    try std.testing.expectError(error.HostRuntimeBusy, runtime.close());
    try std.testing.expectEqual(@as(usize, 0), runtime.occupiedActivationBytes());
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    try std.testing.expectEqual(OfferResult.full, owner.offer(.task));
}

test "restore withholds projections until the configured recovery quantum reaches safety" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: model_operation.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:answer",
            .task = "task",
            .provider = fixture.provider(),
        } },
    });
    const session = &created.session.?;
    const session_id = session.session_id;
    for (0..5) |index| {
        try session.storeBlob(session.ownerToken(), index + 1, "ledger fixture");
        _ = try session.commitSemantic(session.ownerToken(), &.{session_transition.taskAdmitted(.{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        }, index + 1, index + 1)}, null);
    }
    created.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .recovery_quantum = 2,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    const first = try restored.drive();
    try std.testing.expectEqual(State.restoring, first.state);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u8, 0), first.projection_count);
    const second = try restored.drive();
    try std.testing.expectEqual(State.restoring, second.state);
    try std.testing.expect(second.more);
    try std.testing.expectEqual(@as(u8, 0), second.projection_count);
    const safe = try restored.drive();
    try std.testing.expectEqual(State.restoring, safe.state);
    try std.testing.expect(safe.more);
    try std.testing.expectEqual(@as(u8, 1), safe.projection_count);
    try std.testing.expectEqual(ProjectionKind.session, safe.projections[0].kind);
    const ready = try restored.drive();
    try std.testing.expectEqual(State.ready, ready.state);
    try std.testing.expect(!ready.more);
    try std.testing.expectEqual(@as(u8, 0), ready.projection_count);
}

test "restore publishes Session identity before reconciling Completion evidence" {
    const IgnoreReplay = struct {
        fn apply(_: *anyopaque, _: session_transition.Fact) !void {}
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: model_operation.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:answer",
            .task = "task",
            .provider = fixture.provider(),
        } },
    });
    _ = try created.drive();
    try std.testing.expectEqual(OfferResult.accepted, created.offer(.task));
    const waiting = try created.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    var ignored: u8 = 0;
    const before = try created.session.?.inspectSemantic(
        created.session.?.ownerToken(),
        &ignored,
        IgnoreReplay.apply,
    );
    const session_id = created.session.?.session_id;
    created.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    const identified = try restored.drive();
    try std.testing.expectEqual(State.restoring, identified.state);
    try std.testing.expectEqual(@as(u8, 1), identified.projection_count);
    try std.testing.expectEqual(ProjectionKind.session, identified.projections[0].kind);
    const before_reconcile = try restored.session.?.inspectSemantic(
        restored.session.?.ownerToken(),
        &ignored,
        IgnoreReplay.apply,
    );
    try std.testing.expectEqual(before.last_sequence, before_reconcile.last_sequence);

    const reconciled = try restored.drive();
    try std.testing.expectEqual(State.finished, reconciled.state);
    const after_reconcile = try restored.session.?.inspectSemantic(
        restored.session.?.ownerToken(),
        &ignored,
        IgnoreReplay.apply,
    );
    try std.testing.expect(after_reconcile.last_sequence > before_reconcile.last_sequence);
}

test "failed Host Store recovery makes the live Harness unavailable" {
    const ReadFault = struct {
        armed: bool = false,

        fn reached(context: *anyopaque, boundary: host_store.FaultBoundary) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.armed and boundary == .before_transition_read) {
                return error.InjectedStorageFailure;
            }
        }

        fn hook(self: *@This()) host_store.FaultHook {
            return .{ .context = self, .reached = reached };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var read_fault: ReadFault = .{};
    const runtime = try openTestRuntimeConfigured(&tmp, .{ .fault = read_fault.hook() });
    defer runtime.close() catch unreachable;
    var fixture: model_operation.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:answer",
            .task = "task",
            .provider = fixture.provider(),
        } },
    });
    const session = &created.session.?;
    const session_id = session.session_id;
    const descriptor = session_transition.operationSubmitted(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .operation_id = 10,
        .generation = 1,
    }, 11, 12, .none);
    try session.storeBlob(session.ownerToken(), descriptor.reference(), "operation descriptor");
    _ = try session.commitSemantic(session.ownerToken(), &.{descriptor}, null);
    created.close();
    read_fault.armed = true;

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    try std.testing.expectError(error.InjectedStorageFailure, restored.drive());
    try std.testing.expectError(error.HarnessUnavailable, restored.drive());
}

test "shutdown denies Approval Required before closing" {
    const PermissionFacts = struct {
        approval_required: u8 = 0,
        undecided_authorization: u8 = 0,

        fn apply(context: *anyopaque, fact: session_transition.Fact) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (fact.kind()) {
                .approval_required => self.approval_required += 1,
                .authorization => if (fact.flags() == 0) {
                    self.undecided_authorization += 1;
                },
                else => {},
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf forbidden",
        .timeout_ms = 5000,
    });
    var fixture: model_operation.ToolFixture = .{
        .expected_task = "task",
        .tool_arguments = call,
        .final_answer = "done",
        .expected_tool_status = .denied,
    };
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:shutdown-approval",
            .task = "task",
            .provider = fixture.provider(),
        } },
    });
    _ = try owner.drive();
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    _ = try owner.drive();
    const waiting = try owner.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    try std.testing.expectEqual(ProjectionKind.approval_required, waiting.projections[0].kind);
    var facts: PermissionFacts = .{};
    _ = try owner.session.?.inspectSemantic(
        owner.session.?.ownerToken(),
        &facts,
        PermissionFacts.apply,
    );
    try std.testing.expectEqual(@as(u8, 1), facts.approval_required);
    try std.testing.expectEqual(@as(u8, 0), facts.undecided_authorization);
    const session_id = owner.session.?.session_id;
    owner.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    const identified = try restored.drive();
    try std.testing.expectEqual(State.restoring, identified.state);
    try std.testing.expectEqual(ProjectionKind.session, identified.projections[0].kind);
    try std.testing.expectEqual(OfferResult.accepted, restored.offer(.shutdown));
    const closed = try restored.drive();
    try std.testing.expectEqual(State.closed, closed.state);
    try std.testing.expectEqual(@as(u8, 1), closed.committed);
    try std.testing.expectEqual(ProjectionKind.closed, closed.projections[0].kind);
}

test "cancellation reconciles Completion evidence that lost live ingress custody" {
    const CancellingProvider = struct {
        owner: ?*Harness = null,
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestReader,
            response: model_operation.ResponseWriter,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [64]u8 = undefined;
            const encoded = try model_protocol.encodeText(
                &buffer,
                .complete,
                "done",
            );
            try response.append(encoded);
            try response.finish();
            const owner = self.owner orelse return error.MissingHarness;
            if (owner.offer(.cancel) != .accepted) return error.CancellationOfferRejected;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: CancellingProvider = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:cancellation-race",
            .task = "task",
            .provider = provider.provider(),
        } },
    });
    defer owner.close();
    provider.owner = &owner;
    _ = try owner.drive();
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    _ = try owner.drive();
    const cancelling = try owner.drive();
    try std.testing.expectEqual(State.cancelling, cancelling.state);
    const cancelled = try owner.drive();
    try std.testing.expectEqual(State.cancelled, cancelled.state);
    try std.testing.expectEqual(@as(u8, 1), cancelled.committed);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
}

test "known provider failure is one durable terminal Result" {
    const FailingProvider = struct {
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestReader,
            response: model_operation.ResponseWriter,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [64]u8 = undefined;
            const encoded = try model_protocol.encodeText(
                &buffer,
                .complete,
                "must not win",
            );
            try response.append(encoded);
            try response.finish();
            return error.TestProviderUnavailable;
        }
    };
    const ResultFacts = struct {
        count: u8 = 0,

        fn apply(context: *anyopaque, fact: session_transition.Fact) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (fact.kind() == .result and fact.recoveryClass() == .model) self.count += 1;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: FailingProvider = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:provider-failure",
            .task = "task",
            .provider = provider.provider(),
        } },
    });
    _ = try owner.drive();
    const session_id = owner.session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    const waiting = try owner.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    const failed = try owner.drive();
    try std.testing.expectEqual(State.failed, failed.state);
    try std.testing.expectEqual(ProjectionKind.failure, failed.projections[0].kind);
    var facts: ResultFacts = .{};
    _ = try owner.session.?.inspectSemantic(
        owner.session.?.ownerToken(),
        &facts,
        ResultFacts.apply,
    );
    try std.testing.expectEqual(@as(u8, 1), facts.count);
    owner.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .provider = provider.provider(),
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    try std.testing.expectEqual(State.failed, regenerated.state);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
}
