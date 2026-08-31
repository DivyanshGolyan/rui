const std = @import("std");
const binding = @import("binding.zig");
const bash_tool = @import("bash_tool.zig");
const core_state = @import("core_state.zig");
const completion_inbox = @import("completion_inbox.zig");
const conversation = @import("conversation.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const host_runtime = @import("host_runtime.zig");
const host_store = @import("host_store.zig");
const lifecycle = @import("lifecycle.zig");
const model_operation = @import("model_operation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

pub const HostRuntime = host_runtime.HostRuntime;
pub const HostRuntimeConfig = host_runtime.Config;
pub const FaultBoundary = lifecycle.FaultBoundary;
pub const FaultHook = lifecycle.FaultHook;
pub const default_recovery_quantum: u8 = 32;
pub const max_recovery_records: usize = session_transition.max_transitions +
    completion_inbox.max_records * (session_transition.max_transitions + 1);

pub const PermissionMode = lifecycle.PermissionMode;

pub const ModelBinding = struct {
    model: []const u8,
    provider: model_operation.Provider,
};

pub const Create = struct {
    workspace_path: []const u8,
    model_binding: ModelBinding,
    task: []const u8,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    fault: ?FaultHook = null,
};

pub const Restore = struct {
    session_id: u64,
    model_binding: ?ModelBinding = null,
    fault: ?FaultHook = null,
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

const RetainedConfig = struct {
    provider: ?model_operation.Provider,
    fault: ?FaultHook,
    bash_cancelled: ?*const std.atomic.Value(bool),
    permission_mode: PermissionMode,
    recovery_quantum: u8,
    created: bool,
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
    descriptor_digest: binding.Descriptor,
    allow: bool,
};

pub const Completion = completion_inbox.Envelope;
pub const CompletionKind = completion_inbox.EvidenceKind;

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
    descriptor_digest: ?binding.Descriptor = null,
    content_ref: u64 = 0,
    generation: u64 = 0,
    failure: model_protocol.Failure = .none,
    diagnostic_source: model_protocol.DiagnosticSource = .none,
    diagnostic_code: [model_protocol.max_failure_diagnostic_code_size]u8 = @splat(0),
    diagnostic_code_length: u8 = 0,

    pub fn setDiagnosticCode(self: *Projection, code: []const u8) void {
        std.debug.assert(code.len <= self.diagnostic_code.len);
        @memset(&self.diagnostic_code, 0);
        @memcpy(self.diagnostic_code[0..code.len], code);
        self.diagnostic_code_length = @intCast(code.len);
    }

    pub fn diagnosticCode(self: *const Projection) []const u8 {
        return self.diagnostic_code[0..self.diagnostic_code_length];
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

pub const Harness = opaque {
    pub fn residentOwnerBytes() usize {
        return @sizeOf(HarnessState);
    }

    pub fn open(config: Config) !*Harness {
        var lease = try host_runtime.Lease.acquire(config.runtime);
        errdefer lease.release();
        const owner = try lease.allocator.create(HarnessState);
        errdefer lease.allocator.destroy(owner);
        try owner.init(config, lease);
        return @ptrCast(owner);
    }

    pub fn offer(self: *Harness, input: Input) OfferResult {
        return harnessState(self).offer(input);
    }

    pub fn drive(self: *Harness) !Progress {
        return harnessState(self).drive();
    }

    pub fn openProjectionContent(
        self: *Harness,
        projection: Projection,
    ) !session_store.ContentView {
        const owner = harnessState(self);
        const session = if (owner.session) |*value| value else return error.StaleProjection;
        if (projection.generation != owner.projection_generation or projection.content_ref == 0 or
            projection.session_id != session.session_id)
        {
            return error.StaleProjection;
        }
        return session.viewDurableContent(projection.content_ref);
    }

    pub fn close(self: *Harness) void {
        const owner = harnessState(self);
        const allocator = owner.close();
        allocator.destroy(owner);
    }
};

const HarnessState = struct {
    config: RetainedConfig,
    lease: host_runtime.Lease,
    pending: ?Input = null,
    state: State,
    /// This allocation owns the file-capable transient state for exactly this
    /// live Harness. Session borrows the opaque pointer and cannot copy or
    /// destroy its resource.
    scratch: ?*session_store.TransientScratch = null,
    session: ?session_store.Session = null,
    session_projection_pending: bool = false,
    final_ref: u64 = 0,
    projection_generation: u64 = 0,
    awaiting_approval: ?lifecycle.ApprovalRequired = null,
    settling_control: ?lifecycle.Control = null,
    recovery_pending: bool = false,
    task_started: bool = false,
    closing: bool = false,
    ingress_lock: std.Io.Mutex = .init,
    drive_lock: std.Io.Mutex = .init,

    fn init(self: *HarnessState, config: Config, lease: host_runtime.Lease) !void {
        if (config.recovery_quantum == 0) return error.InvalidRecoveryQuantum;
        switch (config.mode) {
            .create => |create| {
                if (create.workspace_path.len == 0 or create.model_binding.model.len == 0 or
                    create.task.len == 0)
                {
                    return error.InvalidCreateRequest;
                }
            },
            .restore => |restore| {
                if (restore.session_id == 0) return error.InvalidSessionIdentity;
                if (restore.model_binding) |binding_value| {
                    const model = binding_value.model;
                    if (model.len == 0 or model.len > session_store.model_name_capacity or
                        !std.unicode.utf8ValidateSlice(model))
                    {
                        return error.InvalidRestoreModel;
                    }
                }
            },
        }
        self.* = .{
            .config = switch (config.mode) {
                .create => |create| .{
                    .provider = create.model_binding.provider,
                    .fault = create.fault,
                    .bash_cancelled = create.bash_cancelled,
                    .permission_mode = config.permission_mode,
                    .recovery_quantum = config.recovery_quantum,
                    .created = true,
                },
                .restore => |restore| .{
                    .provider = if (restore.model_binding) |binding_value| binding_value.provider else null,
                    .fault = restore.fault,
                    .bash_cancelled = null,
                    .permission_mode = config.permission_mode,
                    .recovery_quantum = config.recovery_quantum,
                    .created = false,
                },
            },
            .lease = lease,
            .state = switch (config.mode) {
                .create => .ready,
                .restore => .restoring,
            },
        };
        self.scratch = try session_store.allocateTransientScratch(lease.allocator);
        errdefer {
            if (self.session) |*session| session.close();
            self.session = null;
            if (self.scratch) |scratch| {
                session_store.destroyTransientScratch(lease.allocator, lease.io, scratch);
                self.scratch = null;
            }
        }
        switch (config.mode) {
            .create => |create| self.session = try lease.createSession(self.scratch.?, .{
                .workspace_path = create.workspace_path,
                .model = create.model_binding.model,
                .task = create.task,
            }),
            .restore => |restore| {
                var restored = try lease.restoreSession(self.scratch.?, restore.session_id);
                if (restore.model_binding) |binding_value| {
                    if (!std.mem.eql(u8, restored.modelName(), binding_value.model)) {
                        restored.close();
                        return error.RestoreModelMismatch;
                    }
                }
                self.session = restored;
                self.recovery_pending = true;
                const session = &self.session.?;
                if (try session.recoveryIsEmpty()) {
                    _ = try lease.recoverSemanticWindow(session, 1);
                    self.recovery_pending = false;
                    self.setState(.ready);
                }
            },
        }
        self.session_projection_pending = true;
    }

    fn offer(self: *HarnessState, input: Input) OfferResult {
        if (!self.ingress_lock.tryLock()) return .busy;
        defer self.ingress_lock.unlock(self.lease.io);
        if (self.state == .closed) return .closed;
        if (self.state == .unavailable) return .unavailable;
        if (self.pending != null) return .full;
        if (!self.accepts(input)) return .invalid;
        if (input == .permission) {
            const decision = input.permission;
            const expected = self.awaiting_approval orelse return .invalid;
            if (decision.operation_id != expected.operation_id or
                decision.operation_generation != expected.operation_generation or
                !binding.descriptorEql(decision.descriptor_digest, expected.descriptor_digest))
            {
                return .invalid;
            }
        }
        self.pending = input;
        return .accepted;
    }

    fn drive(self: *HarnessState) !Progress {
        if (!self.drive_lock.tryLock()) return error.HarnessBusy;
        defer self.drive_lock.unlock(self.lease.io);
        if (self.state == .unavailable) return error.HarnessUnavailable;
        if (self.projection_generation == std.math.maxInt(u64)) return error.ProjectionGenerationExhausted;
        self.projection_generation += 1;
        if (self.recovery_pending) {
            const session = &self.session.?;
            const recovery = self.lease.recoverSemanticWindow(
                session,
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
                    !binding.descriptorEql(decision.descriptor_digest, expected.descriptor_digest))
                {
                    return error.StalePermissionDecision;
                }
                const session = if (self.session) |*value| value else return error.SessionUnavailable;
                const provider = self.config.provider;
                self.setState(.running);
                self.final_ref = lifecycle.resolvePermission(
                    self.lease.execution,
                    self.lease.allocator,
                    session,
                    expected,
                    decision.allow,
                    provider,
                    self.config.bash_cancelled,
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
                    self.lease.execution,
                    session,
                    completion,
                    self.runtimeConfig(),
                ) catch |err| if (self.settlingControl() != null and switch (err) {
                    error.ToolCallDeferred,
                    error.SessionNeedsModel,
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
        if (self.config.created and !self.task_started) {
            const input = current_input orelse return .{ .state = .ready };
            progress.consumed = 1;
            if (input != .task) return self.consumeControl(input, progress);
            self.task_started = true;
            self.setState(.running);
            const session = if (self.session) |*value| value else return error.SessionUnavailable;
            self.final_ref = lifecycle.advanceCreated(
                self.lease.execution,
                session,
                self.runtimeConfig(),
                self.config.provider orelse return error.SessionNeedsModel,
            ) catch |err| return self.classifyLifecycleError(err, progress);
        } else {
            if (current_input) |input| {
                progress.consumed = 1;
                if (input == .shutdown or input == .cancel) {
                    return self.consumeControl(input, progress);
                }
                if (input == .task and self.state == .ready) {
                    const session = if (self.session) |*value| value else return error.SessionUnavailable;
                    self.setState(.running);
                    self.final_ref = lifecycle.advanceCreated(
                        self.lease.execution,
                        session,
                        self.runtimeConfig(),
                        self.config.provider orelse return error.SessionNeedsModel,
                    ) catch |err| return self.classifyLifecycleError(err, progress);
                    if (self.final_ref != 0) return self.finish(progress);
                    return error.CompletionExpected;
                }
                return error.InvalidResumeInput;
            }
            self.setState(.running);
            const session = if (self.session) |*value| value else return error.SessionUnavailable;
            self.final_ref = lifecycle.advanceRestored(
                self.lease.execution,
                self.lease.allocator,
                session,
                self.runtimeConfig(),
                self.config.provider,
            ) catch |err| return self.classifyLifecycleError(err, progress);
        }
        return self.finish(progress);
    }

    fn finish(self: *HarnessState, initial: Progress) !Progress {
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
        };
        progress.projections[1] = .{
            .kind = .final_answer,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .content_ref = final_ref,
            .generation = self.projection_generation,
        };
        progress.projections[2] = .{
            .kind = .outcome,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .content_ref = final_ref,
            .generation = self.projection_generation,
        };
        progress.projection_count = 3;
        return progress;
    }

    fn publishSessionIdentity(self: *HarnessState, restoring: bool) Progress {
        const session = &self.session.?;
        self.session_projection_pending = false;
        var identified: Progress = .{
            .state = if (restoring) .restoring else self.state,
            .more = !self.config.created,
        };
        identified.projections[0] = .{
            .kind = .session,
            .session_id = session.session_id,
            .task_id = session.task_id,
        };
        identified.projection_count = 1;
        return identified;
    }

    fn consumeControl(self: *HarnessState, input: Input, progress: Progress) !Progress {
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
                };
                result.projection_count = 1;
            },
            else => return error.InvalidControlInput,
        }
        return result;
    }

    fn denyPendingApproval(self: *HarnessState, session: *session_store.Session) !void {
        try self.refreshApprovalRequired(session);
        const approval = self.approvalSnapshot() orelse return;
        _ = lifecycle.resolvePermission(
            self.lease.execution,
            self.lease.allocator,
            session,
            approval,
            false,
            null,
            self.config.bash_cancelled,
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

    fn refreshApprovalRequired(self: *HarnessState, session: *session_store.Session) !void {
        self.setApproval(try lifecycle.pendingApprovalRequired(session));
    }

    fn continueSettlingControl(self: *HarnessState) !Progress {
        if (self.settlingControl() == null) return error.MissingSettlingControl;
        const session = if (self.session) |*value| value else return error.SessionUnavailable;
        _ = lifecycle.settleRestored(
            self.lease.execution,
            session,
            self.runtimeConfig(),
        ) catch |err| switch (err) {
            error.SessionOperationPending => return .{ .state = .cancelling, .more = true },
            error.SessionNeedsModel,
            error.ToolCallDeferred,
            error.PatchApprovalRequired,
            error.BashPossiblyExecuted,
            => {},
            else => {
                if (!isTerminalLifecycleFailure(err)) {
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
        self: *HarnessState,
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
        };
        progress.projection_count = 1;
        return progress;
    }

    fn classifyLifecycleError(self: *HarnessState, err: anyerror, progress: Progress) anyerror!Progress {
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
            error.CompletionAttemptEpochMismatch,
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
        if (isTerminalLifecycleFailure(err)) {
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
            error.CompletionOffered,
            => .{ .outcome, .waiting },
            error.InjectedCrash => return err,
            error.SemanticValidationWorkspaceBusy,
            error.PatchWorkspaceBusy,
            => {
                self.setState(progress.state);
                return err;
            },
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
        };
        if (self.approvalSnapshot()) |approval| {
            projection.operation_id = approval.operation_id;
            projection.operation_generation = approval.operation_generation;
            projection.descriptor_digest = approval.descriptor_digest;
            projection.content_ref = approval.descriptor_ref;
            projection.generation = self.projection_generation;
        }
        result.projections[0] = projection;
        result.projection_count = 1;
        return result;
    }

    fn isTerminalLifecycleFailure(err: anyerror) bool {
        return err == error.TerminalModelFailure or
            err == error.InteractionRequestLayerRequired;
    }

    fn failureProjection(self: *HarnessState) Projection {
        const session = &self.session.?;
        var response_ref: u64 = 0;
        const failure = failure: {
            const ledger = session.semanticView() catch break :failure .none;
            const encoded = ledger.last_core orelse break :failure .none;
            const state = core_state.decode(&encoded) catch break :failure .none;
            response_ref = state.response_ref;
            break :failure state.response_failure;
        };
        var projection: Projection = .{
            .kind = .failure,
            .session_id = session.session_id,
            .task_id = session.task_id,
            .failure = failure,
        };
        populateFailureDiagnostic(session, response_ref, &projection);
        return projection;
    }

    fn populateFailureDiagnostic(
        session: *session_store.Session,
        response_ref: u64,
        projection: *Projection,
    ) void {
        if (response_ref == 0) return;
        var reader = session.viewContent(response_ref) catch return;
        var bytes: [model_protocol.header_size + model_protocol.max_failure_diagnostic_code_size]u8 = undefined;
        if (reader.length() > bytes.len) return;
        const captured = reader.readWindow(0, &bytes) catch return;
        if (captured.len != reader.length()) return;
        const diagnostic = model_protocol.inspectFailureDiagnostic(captured) catch return;
        projection.diagnostic_source = diagnostic.source;
        projection.setDiagnosticCode(diagnostic.code);
    }

    fn approvalRequired(context: *anyopaque, approval: lifecycle.ApprovalRequired) anyerror!void {
        const self: *HarnessState = @ptrCast(@alignCast(context));
        self.setApproval(approval);
    }

    fn adapterCompletionOffered(context: *anyopaque, evidence: completion_inbox.Envelope) anyerror!void {
        const self: *HarnessState = @ptrCast(@alignCast(context));
        switch (self.offer(.{ .completion = evidence })) {
            .accepted => {},
            .full => {}, // Durable Inbox evidence preserves a notification that loses live custody.
            else => return error.CompletionOfferRejected,
        }
    }

    fn completionHook(self: *HarnessState) lifecycle.CompletionHook {
        return .{ .context = self, .offered = adapterCompletionOffered };
    }

    fn runtimeConfig(self: *HarnessState) lifecycle.RuntimeConfig {
        const session = &self.session.?;
        return .{
            .workspace_path = session.workspacePath(),
            .fault = self.config.fault,
            .permission_mode = self.config.permission_mode,
            .bash_cancelled = self.config.bash_cancelled,
            .approval_required_hook = self.approvalRequiredHook(),
            .completion_hook = self.completionHook(),
        };
    }

    fn approvalRequiredHook(self: *HarnessState) lifecycle.ApprovalRequiredHook {
        return .{ .context = self, .required = approvalRequired };
    }

    fn accepts(self: *const HarnessState, input: Input) bool {
        return switch (input) {
            .task => self.state == .ready,
            .permission => self.state == .waiting,
            .completion => self.state == .restoring or self.state == .running or
                self.state == .waiting or self.state == .cancelling,
            .cancel => self.state != .finished and self.state != .cancelled and self.state != .cancelling,
            .shutdown => self.state != .cancelling,
        };
    }

    fn takePending(self: *HarnessState) ?Input {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn setState(self: *HarnessState, state: State) void {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        self.state = state;
    }

    fn approvalSnapshot(self: *HarnessState) ?lifecycle.ApprovalRequired {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        return self.awaiting_approval;
    }

    fn setApproval(self: *HarnessState, approval: ?lifecycle.ApprovalRequired) void {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        self.awaiting_approval = approval;
    }

    fn settlingControl(self: *HarnessState) ?lifecycle.Control {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        return self.settling_control;
    }

    fn setSettlingControl(self: *HarnessState, control: ?lifecycle.Control) void {
        self.ingress_lock.lockUncancelable(self.lease.io);
        defer self.ingress_lock.unlock(self.lease.io);
        self.settling_control = control;
    }

    fn close(self: *HarnessState) std.mem.Allocator {
        self.drive_lock.lockUncancelable(self.lease.io);
        defer self.drive_lock.unlock(self.lease.io);
        self.ingress_lock.lockUncancelable(self.lease.io);
        std.debug.assert(!self.closing and self.lease.active);
        self.closing = true;
        if (self.projection_generation != std.math.maxInt(u64)) self.projection_generation += 1;
        self.state = .closed;
        self.pending = null;
        self.ingress_lock.unlock(self.lease.io);
        if (self.session) |*session| session.close();
        self.session = null;
        if (self.scratch) |scratch| {
            session_store.destroyTransientScratch(self.lease.allocator, self.lease.io, scratch);
            self.scratch = null;
        }
        const allocator = self.lease.allocator;
        self.lease.release();
        return allocator;
    }
};

fn harnessState(harness: *Harness) *HarnessState {
    return @ptrCast(@alignCast(harness));
}

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

test "Harness owner retains only live lifecycle state" {
    try std.testing.expectEqual(@as(usize, 8_032), Harness.residentOwnerBytes());
}

test "Harness close releases opaque transient scratch before retirement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    const owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:close-scratch", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    owner.close();
    try runtime.close();
}

test "open retains no Activation Slot and offer transfers one bounded input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    defer owner.close();
    try std.testing.expectError(error.HostRuntimeBusy, runtime.close());
    try std.testing.expectEqual(@as(usize, 0), runtime.occupiedActivationBytes());
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    try std.testing.expectEqual(OfferResult.full, owner.offer(.task));
}

test "one process owns one SQLite Host Runtime budget" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const runtime = try openTestRuntime(&first_tmp);
    defer runtime.close() catch unreachable;
    try std.testing.expectError(
        error.HostRuntimeAlreadyOpen,
        openTestRuntime(&second_tmp),
    );
}

test "Harness close consumes the owner and releases one Runtime lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    const owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    owner.close();
    try runtime.close();
}

test "active credit rejects a second Harness before scratch allocation or Session claim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    var first_fixture: deterministic_provider.Fixture = .{ .expected_task = "first", .final_answer = "done" };
    var second_fixture: deterministic_provider.Fixture = .{ .expected_task = "second", .final_answer = "done" };
    var first = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:first", .provider = first_fixture.provider() },
            .task = "first",
        } },
    });
    const session_id = harnessState(first).session.?.session_id;
    first.close();

    const blocker = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:second", .provider = second_fixture.provider() },
            .task = "second",
        } },
    });
    try std.testing.expectError(error.ActiveCapacityExhausted, Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    }));
    try std.testing.expectError(error.HostRuntimeBusy, runtime.close());
    blocker.close();

    // The rejected restore did not reach Session.openExisting/claimSession.
    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    try std.testing.expectEqual(@as(u64, 2), harnessState(restored).session.?.ownership_epoch);
    restored.close();
    try runtime.close();
}

test "concurrent Harness closure contends without sharing semantic workspace" {
    const Gate = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn reached(context: *anyopaque, boundary: FaultBoundary) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (boundary != .after_semantic_workspace_borrow) return;
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const DriveWorker = struct {
        fn run(owner: *Harness, progress: *?Progress, failure: *?anyerror) void {
            progress.* = owner.drive() catch |err| {
                failure.* = err;
                return;
            };
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const runtime = try HostRuntime.open(
        std.testing.io,
        std.testing.allocator,
        path,
        .{ .active_capacity = 2 },
    );
    var first_fixture: deterministic_provider.Fixture = .{
        .expected_task = "first",
        .final_answer = "first done",
    };
    var second_fixture: deterministic_provider.Fixture = .{
        .expected_task = "second",
        .final_answer = "second done",
    };
    var gate: Gate = .{};
    const first = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:first", .provider = first_fixture.provider() },
            .task = "first",
            .fault = .{ .context = &gate, .reached = Gate.reached },
        } },
    });
    const second = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:second", .provider = second_fixture.provider() },
            .task = "second",
        } },
    });
    defer {
        first.close();
        second.close();
        runtime.close() catch unreachable;
    }

    _ = try first.drive();
    _ = try second.drive();
    try std.testing.expectEqual(OfferResult.accepted, first.offer(.task));
    try std.testing.expectEqual(OfferResult.accepted, second.offer(.task));
    try std.testing.expectEqual(State.waiting, (try first.drive()).state);
    try std.testing.expectEqual(State.waiting, (try second.drive()).state);

    var first_progress: ?Progress = null;
    var first_failure: ?anyerror = null;
    const worker = try std.Thread.spawn(.{}, DriveWorker.run, .{
        first,
        &first_progress,
        &first_failure,
    });
    var worker_joined = false;
    defer if (!worker_joined) {
        gate.release.store(true, .release);
        worker.join();
    };
    while (!gate.entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, second.drive());
    gate.release.store(true, .release);
    worker.join();
    worker_joined = true;

    try std.testing.expect(first_failure == null);
    try std.testing.expectEqual(State.finished, first_progress.?.state);
    try std.testing.expectEqual(State.finished, (try second.drive()).state);
    try std.testing.expectEqual(@as(usize, 0), runtime.occupiedActivationBytes());
}

test "failed Harness construction returns its active credit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };

    try std.testing.expectError(error.InvalidRecoveryQuantum, Harness.open(.{
        .runtime = runtime,
        .recovery_quantum = 0,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:invalid", .provider = fixture.provider() },
            .task = "task",
        } },
    }));

    const owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:valid", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    try std.testing.expectError(error.ActiveCapacityExhausted, Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:over-admission", .provider = fixture.provider() },
            .task = "task",
        } },
    }));
    owner.close();
}

test "restore withholds projections until the configured recovery quantum reaches safety" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    const session = &harnessState(created).session.?;
    const session_id = session.session_id;
    for (0..5) |index| {
        try session.storeContent(index + 1, "ledger fixture");
        _ = try session.commitFacts(&.{session_transition.taskAdmitted(.{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        }, index + 1, index + 1)});
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    _ = try created.drive();
    try std.testing.expectEqual(OfferResult.accepted, created.offer(.task));
    const waiting = try created.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    const created_state = harnessState(created);
    const before = try created_state.session.?.semanticView();
    const session_id = created_state.session.?.session_id;
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
    const restored_state = harnessState(restored);
    const before_reconcile = try restored_state.session.?.semanticView();
    try std.testing.expectEqual(before.last_sequence, before_reconcile.last_sequence);

    const reconciled = try restored.drive();
    try std.testing.expectEqual(State.finished, reconciled.state);
    const after_reconcile = try restored_state.session.?.semanticView();
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
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "task",
        .final_answer = "done",
    };
    var created = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = "task",
        } },
    });
    const session = &harnessState(created).session.?;
    const session_id = session.session_id;
    const descriptor = session_transition.operationAdmitted(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .operation_id = 10,
        .generation = 1,
    }, 0, 11, .{ .model = binding.hash(binding.ModelDescriptor, "descriptor-12") });
    try session.storeContent(
        descriptor.operation_admitted.descriptor_ref,
        "operation descriptor",
    );
    _ = try session.commitFacts(&.{descriptor});
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf forbidden",
        .timeout_ms = 5000,
    });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = "task",
        .tool_arguments = call,
        .final_answer = "done",
        .expected_tool_status = .denied,
    };
    const session_id = initial: {
        var owner = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .create = .{
                .workspace_path = ".",
                .model_binding = .{ .model = "fixture:shutdown-approval", .provider = fixture.provider() },
                .task = "task",
            } },
        });
        defer owner.close();
        _ = try owner.drive();
        try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
        _ = try owner.drive();
        _ = try owner.drive();
        const waiting = try owner.drive();
        try std.testing.expectEqual(State.waiting, waiting.state);
        try std.testing.expectEqual(ProjectionKind.approval_required, waiting.projections[0].kind);
        const owner_state = harnessState(owner);
        const facts = try owner_state.session.?.semanticView();
        try std.testing.expect(facts.consequential.approval_required != null);
        try std.testing.expect(facts.consequential.authorization == null);
        break :initial owner_state.session.?.session_id;
    };

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
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [64]u8 = undefined;
            const encoded = try model_protocol.encodeText(
                &buffer,
                "done",
            );
            try response.append(encoded);
            const owner = self.owner orelse return error.MissingHarness;
            if (owner.offer(.cancel) != .accepted) return error.CancellationOfferRejected;
            return .candidate;
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
            .model_binding = .{ .model = "fixture:cancellation-race", .provider = provider.provider() },
            .task = "task",
        } },
    });
    defer owner.close();
    provider.owner = owner;
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
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [64]u8 = undefined;
            const encoded = try model_protocol.encodeText(
                &buffer,
                "must not win",
            );
            try response.append(encoded);
            return .{ .failure = .{ .failure = .provider_error } };
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
            .model_binding = .{ .model = "fixture:provider-failure", .provider = provider.provider() },
            .task = "task",
        } },
    });
    _ = try owner.drive();
    const owner_state = harnessState(owner);
    const session_id = owner_state.session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    const waiting = try owner.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    const failed = try owner.drive();
    try std.testing.expectEqual(State.failed, failed.state);
    try std.testing.expectEqual(ProjectionKind.failure, failed.projections[0].kind);
    const facts = try owner_state.session.?.semanticView();
    try std.testing.expect(facts.model.result != null);
    owner.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:provider-failure", .provider = provider.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    try std.testing.expectEqual(State.failed, regenerated.state);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
}

test "injected post-Completion interruption preserves exact bytes without redispatch" {
    const exact_arguments = "{ \"timeout_ms\" : 1000, \"command\" : \"true\" }";
    const ToolProvider = struct {
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [model_protocol.max_response_size]u8 = undefined;
            const encoded = try model_protocol.encodeTool(
                &buffer,
                "bash.v1",
                exact_arguments,
            );
            try response.append(encoded);
            return .candidate;
        }
    };
    const CrashAfterCapture = struct {
        armed: bool = true,

        fn reached(context: *anyopaque, boundary: FaultBoundary) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.armed and boundary == .after_completion_inbox) {
                self.armed = false;
                return error.InjectedCrash;
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: ToolProvider = .{};
    var crash: CrashAfterCapture = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:captured-tool-replay", .provider = provider.provider() },
            .task = "task",
            .fault = .{ .context = &crash, .reached = CrashAfterCapture.reached },
        } },
    });
    _ = try owner.drive();
    const session_id = harnessState(owner).session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    try std.testing.expectError(error.InjectedCrash, owner.drive());
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
    owner.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:captured-tool-replay", .provider = provider.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const reconciled = try restored.drive();
    try std.testing.expectEqual(State.waiting, reconciled.state);
    try std.testing.expectEqual(ProjectionKind.outcome, reconciled.projections[0].kind);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);

    const waiting = try restored.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    try std.testing.expectEqual(ProjectionKind.approval_required, waiting.projections[0].kind);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);

    const session = &harnessState(restored).session.?;
    const call_entry = try session.readEntry(session.activeLeafId());
    try std.testing.expectEqual(session_store.EntryKind.tool_call, call_entry.kind);
    var call_bytes: [
        conversation.call_header_size + model_contract.max_tool_key_size +
            model_contract.max_tool_arguments_envelope_size
    ]u8 = undefined;
    const encoded_call = try session.readContent(call_entry.content_ref, 0, &call_bytes);
    const call = try conversation.decodeToolCall(encoded_call);
    try std.testing.expectEqualStrings("bash.v1", call.key);
    try std.testing.expectEqualStrings(exact_arguments, call.arguments);
}

test "candidate seal validation failure publishes no Completion" {
    const MalformedProvider = struct {
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try response.append("not a model response");
            return .candidate;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: MalformedProvider = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:malformed-capture", .provider = provider.provider() },
            .task = "task",
        } },
    });
    defer owner.close();
    _ = try owner.drive();
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    const rejected = try owner.drive();
    try std.testing.expectEqual(State.unavailable, rejected.state);
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
    const Ignore = struct {
        fn apply(_: *anyopaque, _: completion_inbox.Envelope) !void {}
    };
    var context: u8 = 0;
    try std.testing.expectEqual(
        @as(u32, 0),
        try harnessState(owner).session.?.scanCompletionEvidence(&context, Ignore.apply),
    );
}

test "failure replacement seal storage error remains a Host failure" {
    const StorageFailureProvider = struct {
        session: ?*session_store.Session = null,
        response_ref: u64 = 0,
        restricted: bool = false,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            try model_protocol.writeText(response, "candidate that must be discarded");
            const provider_io: *model_operation.ProviderIo = @ptrCast(@alignCast(response.context));
            self.response_ref = provider_io.response_ref;

            const session = self.session orelse return error.MissingTestSession;
            session_store.closeTransientScratchForTest(session);
            try session.scratch_root.setPermissions(session.io, .fromMode(0o555));
            self.restricted = true;
            return .{ .failure = .{ .failure = .provider_error } };
        }

        fn restorePermissions(self: *@This()) !void {
            if (!self.restricted) return;
            const session = self.session orelse return error.MissingTestSession;
            try session.scratch_root.setPermissions(session.io, .fromMode(0o700));
            self.restricted = false;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: StorageFailureProvider = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:failure-seal-storage-error", .provider = provider.provider() },
            .task = "task",
        } },
    });
    defer owner.close();
    _ = try owner.drive();
    provider.session = &harnessState(owner).session.?;
    defer provider.restorePermissions() catch unreachable;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    const unavailable = try owner.drive();
    try provider.restorePermissions();

    try std.testing.expectEqual(State.unavailable, unavailable.state);
    try std.testing.expectEqual(@as(u8, 1), unavailable.projection_count);
    try std.testing.expectEqual(ProjectionKind.failure, unavailable.projections[0].kind);
    try std.testing.expectEqual(model_protocol.Failure.none, unavailable.projections[0].failure);
    const Ignore = struct {
        fn apply(_: *anyopaque, _: completion_inbox.Envelope) !void {}
    };
    var context: u8 = 0;
    const session = provider.session.?;
    try std.testing.expectEqual(
        @as(u32, 0),
        try session.scanCompletionEvidence(&context, Ignore.apply),
    );
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, session.readContent(provider.response_ref, 0, &bytes));
}

test "typed durable model failures share one failed Harness projection" {
    const Candidate = union(enum) {
        failure: model_protocol.Failure,
        unknown_tool,
    };
    const FailureProvider = struct {
        candidate: Candidate,
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [model_protocol.max_response_size]u8 = undefined;
            const encoded = switch (self.candidate) {
                .failure => |failure| return .{ .failure = .{ .failure = failure } },
                .unknown_tool => try model_protocol.encodeTool(
                    &buffer,
                    "fixture.unknown.v1",
                    "{}",
                ),
            };
            try response.append(encoded);
            return .candidate;
        }
    };
    const cases = [_]struct {
        candidate: Candidate,
        expected: model_protocol.Failure,
    }{
        .{ .candidate = .{ .failure = .truncated }, .expected = .truncated },
        .{ .candidate = .{ .failure = .aborted }, .expected = .aborted },
        .{ .candidate = .{ .failure = .provider_error }, .expected = .provider_error },
        .{ .candidate = .{ .failure = .malformed }, .expected = .malformed },
        .{ .candidate = .{ .failure = .empty }, .expected = .empty },
        .{ .candidate = .{ .failure = .multiple_outputs }, .expected = .multiple_outputs },
        .{ .candidate = .{ .failure = .oversized }, .expected = .oversized },
        .{ .candidate = .unknown_tool, .expected = .unknown_tool },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    for (cases) |case| {
        var provider: FailureProvider = .{ .candidate = case.candidate };
        var owner = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .create = .{
                .workspace_path = ".",
                .model_binding = .{ .model = "fixture:model-failure-classification", .provider = provider.provider() },
                .task = "task",
            } },
        });
        _ = try owner.drive();
        try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
        _ = try owner.drive();
        const failed = try owner.drive();
        try std.testing.expectEqual(State.failed, failed.state);
        try std.testing.expectEqual(@as(u8, 1), failed.projection_count);
        try std.testing.expectEqual(ProjectionKind.failure, failed.projections[0].kind);
        try std.testing.expectEqual(case.expected, failed.projections[0].failure);
        try std.testing.expectEqual(@as(u8, 1), provider.calls);

        const ledger = try harnessState(owner).session.?.semanticView();
        const state = try core_state.decode(&(ledger.last_core orelse return error.MissingLedgerCoreState));
        try std.testing.expectEqual(case.expected, state.response_failure);
        owner.close();
    }
}

test "built-in argument rejection becomes one durable terminal failure" {
    const ToolProvider = struct {
        key: []const u8,
        arguments: []const u8,
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [model_protocol.max_response_size]u8 = undefined;
            const encoded = try model_protocol.encodeTool(&buffer, self.key, self.arguments);
            try response.append(encoded);
            return .candidate;
        }
    };

    const allocator = std.testing.allocator;
    const bash_command = try allocator.alloc(u8, model_contract.max_bash_command_bytes + 2);
    defer allocator.free(bash_command);
    for (0..bash_command.len / "é".len) |index| {
        @memcpy(bash_command[index * "é".len ..][0.."é".len], "é");
    }
    const patch = try allocator.alloc(u8, model_contract.max_patch_input_bytes + 2);
    defer allocator.free(patch);
    for (0..patch.len / "é".len) |index| {
        @memcpy(patch[index * "é".len ..][0.."é".len], "é");
    }
    const bash_buffer = try allocator.alloc(u8, model_contract.max_tool_arguments_envelope_size);
    defer allocator.free(bash_buffer);
    const patch_buffer = try allocator.alloc(u8, model_contract.max_tool_arguments_envelope_size);
    defer allocator.free(patch_buffer);
    const nul_buffer = try allocator.alloc(u8, model_contract.max_tool_arguments_envelope_size);
    defer allocator.free(nul_buffer);
    const nul_command = [_]u8{ 't', 'r', 'u', 'e', 0 };
    const nul_arguments = try model_contract.encodeJson(nul_buffer, .{
        .command = nul_command[0..],
        .timeout_ms = bash_tool.max_timeout_ms,
    });
    try std.testing.expect(std.mem.indexOf(u8, nul_arguments, "\\u0000") != null);
    const cases = [_]struct { key: []const u8, arguments: []const u8 }{
        .{
            .key = model_contract.bash_key,
            .arguments = try model_contract.encodeJson(bash_buffer, .{
                .command = bash_command,
                .timeout_ms = bash_tool.max_timeout_ms,
            }),
        },
        .{
            .key = model_contract.apply_patch_key,
            .arguments = try model_contract.encodeJson(patch_buffer, .{ .patch = patch }),
        },
        .{
            .key = model_contract.bash_key,
            .arguments = nul_arguments,
        },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    for (cases, 0..) |case, index| {
        var provider: ToolProvider = .{ .key = case.key, .arguments = case.arguments };
        var owner = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .create = .{
                .workspace_path = ".",
                .model_binding = .{ .model = "fixture:built-in-byte-rejection", .provider = provider.provider() },
                .task = switch (index) {
                    0 => "reject oversized Bash bytes",
                    1 => "reject oversized patch bytes",
                    else => "reject a Bash NUL byte",
                },
            } },
        });
        _ = try owner.drive();
        const session_id = harnessState(owner).session.?.session_id;
        try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
        _ = try owner.drive();
        const failed = try owner.drive();
        try std.testing.expectEqual(State.failed, failed.state);
        const ledger = try harnessState(owner).session.?.semanticView();
        const state = try core_state.decode(&(ledger.last_core orelse return error.MissingLedgerCoreState));
        try std.testing.expectEqual(model_protocol.Failure.malformed, state.response_failure);
        try std.testing.expectEqual(@as(u64, 1), harnessState(owner).session.?.entryCount());
        owner.close();

        var restored = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .restore = .{ .session_id = session_id, .model_binding = .{
                .model = "fixture:built-in-byte-rejection",
                .provider = provider.provider(),
            } } },
        });
        _ = try restored.drive();
        const regenerated = try restored.drive();
        try std.testing.expectEqual(State.failed, regenerated.state);
        try std.testing.expectEqual(@as(u8, 1), provider.calls);
        restored.close();
    }
}

test "input request fails terminally until the durable interaction layer exists" {
    const InputProvider = struct {
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var buffer: [model_protocol.max_response_size]u8 = undefined;
            const encoded = try model_protocol.encodeInputText(&buffer, "Which migration should I use?");
            try response.append(encoded);
            return .candidate;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var provider: InputProvider = .{};
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:input-request", .provider = provider.provider() },
            .task = "task",
        } },
    });
    _ = try owner.drive();
    const owner_state = harnessState(owner);
    const session_id = owner_state.session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    const waiting = try owner.drive();
    try std.testing.expectEqual(State.waiting, waiting.state);
    const failed = try owner.drive();
    try std.testing.expectEqual(State.failed, failed.state);
    try std.testing.expectEqual(ProjectionKind.failure, failed.projections[0].kind);
    const ledger = try owner_state.session.?.semanticView();
    const durable_core = try core_state.decode(&(ledger.last_core orelse return error.MissingLedgerCoreState));
    try std.testing.expectEqual(core_state.TaskPhase.failed, durable_core.task_phase);
    try std.testing.expectEqual(model_protocol.Disposition.input_request, durable_core.response_disposition);
    try std.testing.expect(durable_core.response_ref != 0);
    try std.testing.expectEqual(core_state.ContentWindow{}, durable_core.response_text);
    try std.testing.expectEqual(core_state.ContentWindow{}, durable_core.response_tool_key);
    try std.testing.expectEqual(core_state.ContentWindow{}, durable_core.response_arguments);
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response_bytes = try owner_state.session.?.readContent(
        durable_core.response_ref,
        0,
        &response_buffer,
    );
    var response_validation: model_protocol.ValidationScratch = undefined;
    const decoded_response = try model_protocol.decode(&response_validation, response_bytes);
    try std.testing.expectEqual(model_protocol.Disposition.input_request, decoded_response.disposition);
    try std.testing.expectEqualStrings(
        "Which migration should I use?",
        response_bytes[decoded_response.text_offset..][0..decoded_response.text_length],
    );
    try std.testing.expectEqual(@as(u64, 1), owner_state.session.?.entryCount());
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
    owner.close();

    var restored = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:input-request", .provider = provider.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    try std.testing.expectEqual(State.failed, regenerated.state);
    try std.testing.expectEqual(@as(u64, 1), harnessState(restored).session.?.entryCount());
    try std.testing.expectEqual(@as(u8, 1), provider.calls);
}

const HistoryProvider = struct {
    calls: u8 = 0,
    command: []const u8,

    fn provider(self: *@This()) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request_value: model_operation.RequestCursor,
        candidate: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        var request = request_value;
        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (request.entryCount()) {
            1 => blk: {
                const task = (try request.next()) orelse return error.MissingTask;
                if (task != .user_text or task.user_text.content.length() != "run once".len) {
                    return error.UnexpectedTask;
                }
                var task_bytes: ["run once".len]u8 = undefined;
                _ = try task.user_text.content.readWindow(0, &task_bytes);
                if (!std.mem.eql(u8, &task_bytes, "run once")) return error.UnexpectedTask;
                if (try request.next() != null) return error.UnexpectedHistory;
                var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                const arguments = try model_contract.encodeJson(&arguments_buffer, .{
                    .command = self.command,
                    .timeout_ms = 5000,
                });
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    arguments,
                );
            },
            3 => blk: {
                _ = (try request.next()) orelse return error.MissingTask;
                const call = (try request.next()) orelse return error.MissingToolCall;
                if (call != .tool_call or !std.mem.eql(u8, call.tool_call.key(), model_contract.bash_key)) {
                    return error.UnexpectedToolCall;
                }
                const result_entry = (try request.next()) orelse return error.MissingToolResult;
                if (result_entry != .tool_result or result_entry.tool_result.is_error) {
                    return error.UnexpectedToolResult;
                }
                const expected_result = "status=success\nexit_code=0\n" ++
                    "stdout_base64=cmVwbGF5LXByb29m\nstderr_base64=";
                if (result_entry.tool_result.content.length() != expected_result.len) {
                    return error.UnexpectedToolResult;
                }
                var result_bytes: [expected_result.len]u8 = undefined;
                _ = try result_entry.tool_result.content.readWindow(0, &result_bytes);
                if (!std.mem.eql(u8, &result_bytes, expected_result)) return error.UnexpectedToolResult;
                if (try request.next() != null) return error.UnexpectedHistory;
                break :blk try model_protocol.encodeText(&encoded_buffer, "durable final");
            },
            else => return error.UnexpectedHistory,
        };
        try candidate.append(encoded);
        return .candidate;
    }
};

test "fresh Harness resumes after admitted Tool Result without replaying the tool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var command_buffer: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "printf x >> '.zig-cache/tmp/{s}/execution-count'; printf replay-proof",
        .{tmp.sub_path},
    );
    var first_provider: HistoryProvider = .{ .command = command };
    var owner = try Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:history-restart", .provider = first_provider.provider() },
            .task = "run once",
        } },
    });
    _ = try owner.drive();
    const session_id = harnessState(owner).session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    for (0..12) |_| {
        _ = try owner.drive();
        if (harnessState(owner).session.?.entryCount() == 3) break;
    }
    try std.testing.expectEqual(@as(u64, 3), harnessState(owner).session.?.entryCount());
    try std.testing.expectEqual(@as(u8, 1), first_provider.calls);
    var execution_count: [2]u8 = undefined;
    var count_file = try tmp.dir.openFile(std.testing.io, "execution-count", .{});
    defer count_file.close(std.testing.io);
    const count_length = try count_file.readPositionalAll(std.testing.io, &execution_count, 0);
    try std.testing.expectEqualStrings("x", execution_count[0..count_length]);
    owner.close();

    var fresh_provider: HistoryProvider = .{ .command = command };
    var restored = try Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:history-restart", .provider = fresh_provider.provider() },
        } },
    });
    var finished: Progress = undefined;
    for (0..12) |_| {
        finished = try restored.drive();
        if (finished.state == .finished) break;
    }
    try std.testing.expectEqual(State.finished, finished.state);
    try std.testing.expectEqual(@as(u8, 1), fresh_provider.calls);
    const unchanged_length = try count_file.readPositionalAll(std.testing.io, &execution_count, 0);
    try std.testing.expectEqualStrings("x", execution_count[0..unchanged_length]);
    restored.close();

    var final_restore = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer final_restore.close();
    _ = try final_restore.drive();
    const durable = try final_restore.drive();
    try std.testing.expectEqual(State.finished, durable.state);
}

test "recovered Tool Result returns before the next Provider dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var command_buffer: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "printf x >> '.zig-cache/tmp/{s}/recovery-execution-count'; printf replay-proof",
        .{tmp.sub_path},
    );
    var first_provider: HistoryProvider = .{ .command = command };
    var owner = try Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "fixture:tool-result-recovery", .provider = first_provider.provider() },
            .task = "run once",
        } },
    });
    _ = try owner.drive();
    const session_id = harnessState(owner).session.?.session_id;
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    _ = try owner.drive(); // Capture the model response.
    _ = try owner.drive(); // Admit it without executing the Tool.
    _ = try owner.drive(); // Capture the Tool Result, then lose its live notification.
    try std.testing.expectEqual(@as(u8, 1), first_provider.calls);
    owner.close();

    var execution_count: [2]u8 = undefined;
    var count_file = try tmp.dir.openFile(std.testing.io, "recovery-execution-count", .{});
    defer count_file.close(std.testing.io);
    const before_restore = try count_file.readPositionalAll(std.testing.io, &execution_count, 0);
    try std.testing.expectEqualStrings("x", execution_count[0..before_restore]);

    var fresh_provider: HistoryProvider = .{ .command = command };
    var restored = try Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:tool-result-recovery", .provider = fresh_provider.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();

    const reconciled = try restored.drive();
    try std.testing.expectEqual(State.waiting, reconciled.state);
    try std.testing.expectEqual(@as(u8, 0), fresh_provider.calls);
    try std.testing.expectEqual(@as(u64, 3), harnessState(restored).session.?.entryCount());

    const dispatched = try restored.drive();
    try std.testing.expectEqual(State.waiting, dispatched.state);
    try std.testing.expectEqual(@as(u8, 1), fresh_provider.calls);
    const unchanged = try count_file.readPositionalAll(std.testing.io, &execution_count, 0);
    try std.testing.expectEqualStrings("x", execution_count[0..unchanged]);

    const finished = try restored.drive();
    try std.testing.expectEqual(State.finished, finished.state);
}
