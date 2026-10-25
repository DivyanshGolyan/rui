const std = @import("std");
const bash = @import("bash.zig");
const execution = @import("execution.zig");
const execution_turn = @import("execution_turn.zig");
const failed_responses = @import("failed_responses.zig");
const model_adapter = @import("model_adapter.zig");
const named_scratch = @import("named_scratch.zig");
const output_format = @import("output_format.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const retry_policy = @import("retry_policy.zig");
const store_module = @import("store.zig");
const stderr = @import("stderr.zig");
const server_host = @import("server_host.zig");
const signal_stack = @import("signal_stack.zig");
const Host = server_host.Host;
const AuthWorker = server_host.AuthWorker;
const Limits = server_host.Limits;
const Faults = server_host.Faults;
const SettlementTrace = server_host.SettlementTrace;
const default_bash_path = server_host.default_bash_path;
const fenceDispatch = server_host.fenceDispatch;
const retainDispatchFence = server_host.retainDispatchFence;
const beginTestObservation = server_host.beginTestObservation;
const writeTestTrace = server_host.writeTestTrace;
const traceSubject = server_host.traceSubject;
const traceServiceBoundary = server_host.traceServiceBoundary;
const traceLifecycleService = server_host.traceLifecycleService;
const traceOperation = server_host.traceOperation;
const tracePreparationAdvance = server_host.tracePreparationAdvance;
const tracePreparationAdvanceError = server_host.tracePreparationAdvanceError;
const traceCompletionQueue = server_host.traceCompletionQueue;
const traceAction = server_host.traceAction;
const traceOperationControl = server_host.traceOperationControl;
const traceActionControl = server_host.traceActionControl;
const traceActionControlOutcome = server_host.traceActionControlOutcome;
const traceActionDeadline = server_host.traceActionDeadline;
const testTransition = server_host.testTransition;
const waitAtTestGate = server_host.waitAtTestGate;
const testGateActive = server_host.testGateActive;
const observeUnprocessedCompletions = server_host.observeUnprocessedCompletions;

const AttemptOwner = struct {
    token: execution.CustodyToken = undefined,
    binding: store_module.AttemptBinding = undefined,
};

const ProviderSlot = struct {
    owner: AttemptOwner,
    /// Where a managed transfer delivers its Turn's routing value, with the
    /// epoch selected at launch.
    turn_state: ?model_adapter.TurnStates.Capture = null,
    /// The leased credential generation a managed transfer presented.
    credential_generation: ?u64 = null,
    transfer: provider.Transfer = undefined,
};

const NamedScratchSlot = struct {
    token: execution.CustodyToken,
    owner: named_scratch.Owner,
};

const BashSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    execution: bash.Execution,
    stop_accepted: bool = false,
    delivery: union(enum) {
        open,
        closed: struct {
            reclaim_at: std.Io.Clock.Timestamp,
            reclaim_failed: bool = false,
        },
    } = .open,
};

const BashPreparedCleanupSlot = struct {
    token: execution.CustodyToken,
    cleanup: bash.PreparedCleanup,
};

const BashPreparingSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
};

const ModelPreparingSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
};

const ModelAuthenticatingSlot = struct {
    owner: ModelPreparingSlot,
    request: provider.PreparedRequest,
    /// The shared worker accepted this slot's lease job.
    requested: bool = false,
    cancelled: bool = false,
};

/// A managed Attempt answered 401 whose Operation durably claimed its one
/// forced refresh. The Attempt stays uncertain until the refresh settles it.
const ModelRefreshingSlot = struct {
    owner: AttemptOwner,
    rejected_generation: u64,
    request_id: protocol.Bounded(256),
    requested: bool = false,
    cancelled: bool = false,
};

pub const ExecutionSlot = union(enum) {
    free,
    model_preparing: ModelPreparingSlot,
    model_authenticating: ModelAuthenticatingSlot,
    model_refreshing: ModelRefreshingSlot,
    provider: ProviderSlot,
    bash_preparing: BashPreparingSlot,
    bash: BashSlot,
    bash_prepared_cleanup: BashPreparedCleanupSlot,
    named_scratch: NamedScratchSlot,
};

/// Execution-owned consistency checks beside ExecutionSlot. Each inspects
/// current slot and custody facts without mutating them. The legal
/// checkpoint is after a complete admission, preparation, completion, or
/// cleanup transition on the execution owner, when no admission
/// temporaries are outstanding. Payloads match by custody token, never by
/// array index. Aggregate reconciliation runs only here, not midway
/// through beginAdmittedAttempt or launchPreparedRequest where partially
/// established local ownership is legitimate.
fn slotToken(slot: *const ExecutionSlot) ?execution.CustodyToken {
    return switch (slot.*) {
        .free => null,
        .model_preparing => |*active| active.token,
        .model_authenticating => |*active| active.owner.token,
        .model_refreshing => |*active| active.owner.token,
        .provider => |*active| active.owner.token,
        .bash_preparing => |*active| active.token,
        .bash => |*active| active.token,
        .bash_prepared_cleanup => |*retained| retained.token,
        .named_scratch => |*retained| retained.token,
    };
}

fn checkSlotCustodyAgreement(slots: []const ExecutionSlot, custody: *execution.CustodyPool) !void {
    var represented: usize = 0;
    for (slots, 0..) |*slot, i| {
        switch (slot.*) {
            .free => {},
            .model_preparing => |*active| try custody.checkAttachedModel(active.token, active.binding),
            .model_authenticating => |*active| try custody.checkAttachedModel(active.owner.token, active.owner.binding),
            .model_refreshing => |*active| try custody.checkAttachedModel(active.owner.token, active.owner.binding),
            .provider => |*active| try custody.checkAttachedModel(active.owner.token, active.owner.binding),
            .bash_preparing => |*active| try custody.checkAttachedAction(active.token, active.binding),
            // Delivery closure detaches custody while the .bash payload is
            // retained for reclamation: open delivery requires attachment,
            // closed delivery requires detachment plus the retained typed
            // identity. Token-only retained owners (prepared cleanup,
            // named scratch) keep the token-only detached check.
            .bash => |*active| switch (active.delivery) {
                .open => try custody.checkAttachedAction(active.token, active.binding),
                .closed => try custody.checkDetachedAction(active.token, active.binding),
            },
            .bash_prepared_cleanup => |*retained| try custody.checkDetached(retained.token),
            .named_scratch => |*retained| try custody.checkDetached(retained.token),
        }
        const token = slotToken(slot) orelse continue;
        represented += 1;
        for (slots[i + 1 ..]) |*later| {
            const other = slotToken(later) orelse continue;
            if (other.index == token.index and other.generation == token.generation) return error.DuplicateExecutionToken;
        }
    }
    // Reverse reconciliation: every occupied custody record must have its
    // owning slot in the checked population. A missing payload with live
    // custody is capacity that can neither progress nor clean up.
    if (represented != custody.occupied()) return error.OrphanedExecutionCustody;
}

/// Execution-owned preparation correspondence. The live preparations stay
/// in their final storage under the existing single-owner discipline; this
/// establishes that the preparing slots belong to those live objects, not
/// merely that the counts agree. A null preparation must have no matching
/// slot. For Bash only the facts its preparation owns (action identity)
/// are compared; no second stored identity is introduced.
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
            bash_slot = active.binding;
        },
        else => {},
    };
    if (model_preparation) |preparation| {
        const binding = model_slot orelse return error.PreparationOwnershipMismatch;
        try preparation.checkIntegrity(binding);
    } else if (model_slot != null) {
        return error.PreparationOwnershipMismatch;
    }
    if (bash_preparation) |preparation| {
        const slot_binding = bash_slot orelse return error.PreparationOwnershipMismatch;
        if (preparation.action_id != slot_binding.action_id or
            preparation.attempt_ordinal != slot_binding.attempt_ordinal)
        {
            return error.PreparationOwnershipMismatch;
        }
    } else if (bash_slot != null) {
        return error.PreparationOwnershipMismatch;
    }
}

const AdmissionProgress = enum { no_work, retry_later, admitted };

const LifecycleMeasurement = struct {
    last_service_at: ?std.Io.Clock.Timestamp = null,
    next_trace_at: ?std.Io.Clock.Timestamp = null,
    maximum_gap_ns: u64 = 0,
    wait_since_service_ns: u64 = 0,
};

const lifecycle_trace_interval_ms = 100;

/// The execution thread's large scratch, in fresh pages: each buffer becomes
/// resident only when its work first runs. On the stack, ReleaseSafe would
/// fill them all at startup. Never assign the whole struct.
const Workspace = struct {
    model_preparation: model_adapter.Preparation,
    bash_window: [bash.copy_window_bytes]u8,
    capture_buffers: provider.CaptureWriter.Buffers,
};

pub fn executionMain(host: *Host) void {
    var auth_worker = AuthWorker{ .io = host.io, .authentication = host.authentication orelse undefined };
    const auth_thread: ?std.Thread = if (host.authentication != null)
        signal_stack.spawn(.{}, AuthWorker.run, .{&auth_worker}) catch |err| {
            fenceDispatch(host, "authentication worker initialization", err);
            return;
        }
    else
        null;
    if (auth_thread != null) host.auth_worker = &auth_worker;
    defer if (auth_thread) |thread| {
        host.auth_worker = null;
        auth_worker.stop(thread);
    };
    // Zero bytes are a free slot and an empty Turn entry, so fresh pages
    // need no initializing pass and an idle slot never becomes resident.
    const slots = mapZeroed(ExecutionSlot, host.custody.records.len) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    defer unmapZeroed(slots);
    const turn_states = mapZeroed(model_adapter.TurnStates.Entry, slots.len) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    host.turn_states = .{ .entries = turn_states };
    defer {
        host.turn_states = .{};
        unmapZeroed(turn_states);
    }
    const workspace = mapZeroed(Workspace, 1) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    defer unmapZeroed(workspace);
    var capture_writer = provider.CaptureWriter{
        .io = host.io,
        .buffers = &workspace[0].capture_buffers,
        .test_gate_path = host.faults.response_capture_gate_path,
        .test_gate_min_written_bytes = host.faults.response_capture_gate_min_written_bytes,
        .test_observation = host.test_observation,
    };
    const capture_thread: ?std.Thread = if (host.provider_endpoint != null)
        signal_stack.spawn(.{}, provider.CaptureWriter.run, .{&capture_writer}) catch |err| {
            fenceDispatch(host, "capture writer initialization", err);
            return;
        }
    else
        null;
    if (capture_thread != null) host.capture_writer = &capture_writer;
    defer if (capture_thread) |thread| {
        host.capture_writer = null;
        capture_writer.stop(thread);
    };
    var reactor: ?provider.Reactor = if (host.provider_endpoint != null)
        provider.Reactor.init(slots.len) catch |err| {
            fenceDispatch(host, "transport reactor initialization", err);
            return;
        }
    else
        null;
    defer if (reactor) |*active| active.deinit();
    var bash_preparation: ?bash.Preparation = null;
    const model_preparation = &workspace[0].model_preparation;
    defer shutdownExecution(
        host,
        if (reactor) |*active| active else null,
        slots,
        &bash_preparation,
        model_preparation,
    );

    var turn_state = execution_turn.State{ .capacity_was_full = slots.len == 0 };
    var measurement: LifecycleMeasurement = .{};
    var next_receive_slot: usize = 0;
    while (!host.execution_shutdown.load(.acquire) and !host.effect_shutdown.load(.acquire)) {
        var native = NativeTurn{
            .host = host,
            .reactor = if (reactor) |*active| active else null,
            .slots = slots,
            .next_receive_slot = &next_receive_slot,
            .bash_preparation = &bash_preparation,
            .model_preparation = model_preparation,
            .bash_window = &workspace[0].bash_window,
            .measurement = &measurement,
            .fenced = false,
        };
        switch (execution_turn.run(&turn_state, &native)) {
            .continue_immediately => {},
            .wait => |kind| {
                const wait_started = std.Io.Clock.Timestamp.now(host.io, .awake);
                switch (kind) {
                    .transport => reactor.?.wait(25) catch |err| {
                        fenceDispatch(host, "transport wait", err);
                        break;
                    },
                    .bash => _ = host.io.sleep(.fromMilliseconds(25), .awake) catch {},
                    .idle => _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {},
                }
                const wait_finished = std.Io.Clock.Timestamp.now(host.io, .awake);
                measurement.wait_since_service_ns += @intCast(wait_started.durationTo(wait_finished).raw.nanoseconds);
            },
            .terminate => break,
        }
        if (native.fenced) break;
    }
    const stopped_at = std.Io.Clock.Timestamp.now(host.io, .awake);
    if (measurement.last_service_at) |last| {
        traceServiceBoundary(
            host,
            @intCast(last.raw.nanoseconds),
            @intCast(stopped_at.raw.nanoseconds),
            measurement.wait_since_service_ns,
        );
        measurement.maximum_gap_ns = @max(
            measurement.maximum_gap_ns,
            @as(u64, @intCast(last.durationTo(stopped_at).raw.nanoseconds)),
        );
    }
    traceLifecycleService(host, measurement.maximum_gap_ns);
}

const NativeTurn = struct {
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    next_receive_slot: *usize,
    bash_preparation: *?bash.Preparation,
    model_preparation: *model_adapter.Preparation,
    bash_window: []u8,
    measurement: *LifecycleMeasurement,
    fenced: bool,

    pub fn now(self: *NativeTurn) std.Io.Clock.Timestamp {
        return std.Io.Clock.Timestamp.now(self.host.io, .awake);
    }

    pub fn noteLifecycleOpportunity(self: *NativeTurn) void {
        const observed = self.now();
        if (self.measurement.last_service_at) |last| {
            traceServiceBoundary(
                self.host,
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
            traceLifecycleService(self.host, self.measurement.maximum_gap_ns);
            self.measurement.next_trace_at = observed.addDuration(.{
                .raw = .fromMilliseconds(lifecycle_trace_interval_ms),
                .clock = .awake,
            });
        }
    }

    pub fn consumeControlHint(self: *NativeTurn) bool {
        return self.host.controls_changed.swap(false, .acq_rel);
    }

    pub fn commitGeneration(self: *const NativeTurn) u64 {
        return self.host.store.commitGeneration();
    }

    pub fn reconcileControls(self: *NativeTurn) void {
        cancelSupersededTransfers(
            self.host,
            self.reactor,
            self.slots,
            self.model_preparation,
        );
        stopSupersededBash(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceBashPreparation(self: *NativeTurn) bool {
        return callAdvanceBashPreparation(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceLiveBash(self: *NativeTurn) bool {
        return advanceBash(self.host, self.slots, self.bash_window);
    }

    pub fn advanceRetainedCleanup(self: *NativeTurn, observed: std.Io.Clock.Timestamp, retry_at: *std.Io.Clock.Timestamp) bool {
        return callAdvanceRetainedCleanup(self.host, self.slots, observed, retry_at);
    }

    pub fn dispatchFenced(self: *const NativeTurn) bool {
        return self.host.dispatch_fenced.load(.acquire);
    }

    pub fn providerConfigured(self: *const NativeTurn) bool {
        return self.host.provider_endpoint != null;
    }

    pub fn freeSlots(self: *const NativeTurn) usize {
        return countFreeSlots(self.slots);
    }

    pub fn bashPreparationOpen(self: *const NativeTurn) bool {
        return self.bash_preparation.* == null;
    }

    pub fn modelPreparationOpen(self: *const NativeTurn) bool {
        for (self.slots) |slot| switch (slot) {
            .model_preparing, .model_authenticating => return false,
            else => {},
        };
        return true;
    }

    pub fn hasTransport(self: *const NativeTurn) bool {
        return slotsHaveTransport(self.slots);
    }

    pub fn hasBash(self: *const NativeTurn) bool {
        return slotsHaveBash(self.slots);
    }

    pub fn recoverUncertainAction(self: *NativeTurn) error{Fence}!bool {
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_actions = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeActionContains,
            .maximum_exclusions = self.slots.len,
        };
        return self.host.store.recoverOneUncertainAction(active_actions) catch |err| {
            fenceDispatch(self.host, "uncertain Bash recovery", err);
            self.fenced = true;
            return error.Fence;
        };
    }

    pub fn recoverExhaustedRetry(self: *NativeTurn) error{Fence}!bool {
        if (self.host.test_retry_recovery == .held) {
            if (testGateActive(self.host, self.host.faults.retry_recovery_gate_path.?)) return false;
            self.host.test_retry_recovery = .released;
        }
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        const recovered = self.host.store.recoverOneExhaustedModelAttempt(active_filter) catch |err| {
            fenceDispatch(self.host, "exhausted retry recovery", err);
            self.fenced = true;
            return error.Fence;
        };
        // Hold only later recovery calls, never admission or the execution
        // turn. One real call first preserves the full-drain counterexample.
        if (recovered and self.host.test_retry_recovery == .initial) {
            if (self.host.faults.retry_recovery_gate_path) |path| {
                if (testGateActive(self.host, path)) {
                    self.host.test_retry_recovery = .held;
                    traceSubject(self.host, "exhausted_retry_recovery_held", "path", path);
                }
            }
        }
        return recovered;
    }

    fn firstFreeSlot(self: *NativeTurn) ?*ExecutionSlot {
        for (self.slots) |*slot| {
            if (slotIsFree(slot)) return slot;
        }
        return null;
    }

    pub fn admitBash(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitBashAttempt(self.host, slot, self.bash_preparation)) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn admitRetry(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        return switch (admitRetryAttempt(
            self.host,
            slot,
            active_filter,
            self.model_preparation,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn admitNewModel(self: *NativeTurn) execution_turn.Admission {
        return self.admitModel(.message);
    }

    pub fn admitToolContinuation(self: *NativeTurn) execution_turn.Admission {
        return self.admitModel(.tool_continuation);
    }

    fn admitModel(self: *NativeTurn, kind: store_module.ModelAdmissionKind) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitNewAttempt(
            self.host,
            slot,
            kind,
            self.model_preparation,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn driveTransport(self: *NativeTurn) error{Fence}!void {
        self.reactor.?.drive(0) catch |err| {
            fenceDispatch(self.host, "transport reactor", err);
            self.fenced = true;
            return error.Fence;
        };
        observeUnprocessedCompletions(self.host, self.reactor.?);
    }

    pub fn serviceOneCompletion(self: *NativeTurn) bool {
        return callServiceOneCompletion(self.host, self.reactor, self.slots, self.next_receive_slot);
    }

    pub fn modelPreparationAllowance(self: *const NativeTurn) execution_turn.Allowance {
        return .{
            .bytes = self.host.limits.request_preparation_byte_allowance,
            .items = self.host.limits.request_preparation_item_allowance,
        };
    }

    pub fn advanceModelPreparation(self: *NativeTurn, byte_allowance: usize, item_allowance: usize) bool {
        return callAdvanceModelPreparation(
            self.host,
            self.reactor,
            self.slots,
            self.model_preparation,
            byte_allowance,
            item_allowance,
        );
    }
};

const callServiceOneCompletion = serviceOneCompletion;
const callAdvanceBashPreparation = advanceBashPreparation;
const callAdvanceModelPreparation = advanceModelPreparation;
const callAdvanceRetainedCleanup = advanceRetainedCleanup;
const slotsHaveTransport = hasTransport;
const slotsHaveBash = hasBash;

fn serviceOneCompletion(host: *Host, reactor: ?*provider.Reactor, slots: []ExecutionSlot, next_receive_slot: *usize) bool {
    const active_reactor = reactor orelse return false;
    for (slots) |*slot| switch (slot.*) {
        .provider => if (advanceModelFinalization(host, slot, host.faults.response_seal)) return true,
        else => {},
    };
    const active_transfers = ActiveSlots{ .slots = slots };
    const completed = active_reactor.nextCompletion(.{
        .context = &active_transfers,
        .find_fn = findActiveTransfer,
    }) catch |err| {
        fenceDispatch(host, "transport completion", err);
        return false;
    };
    if (completed) return true;
    return advanceOneTransfer(host, active_reactor, slots, next_receive_slot);
}

fn advanceOneTransfer(host: *Host, reactor: anytype, slots: []ExecutionSlot, next_receive_slot: *usize) bool {
    // This thread is the sole producer. Freeze readiness for the scan so a
    // worker drain cannot let a later slot bypass an earlier paused one.
    const resume_allowed = host.capture_writer.?.hasRoom();
    for (0..slots.len) |offset| {
        const index = (next_receive_slot.* + offset) % slots.len;
        const slot = &slots[index];
        switch (slot.*) {
            .provider => |*active| {
                const progress = reactor.advance(&active.transfer, resume_allowed, &host.faults.response_write_on_resume) catch |err| {
                    fenceDispatch(host, "transport advance", err);
                    return false;
                };
                switch (progress) {
                    .progressed, .resume_capture_failure => {
                        next_receive_slot.* = (index + 1) % slots.len;
                        if (progress == .resume_capture_failure)
                            traceSubject(host, "transport_resume_capture_failure", "cause", "local_capture");
                        return true;
                    },
                    .not_ready => {},
                }
            },
            else => {},
        }
    }
    return false;
}

test "receive advancement serves paused siblings across recurring queue pressure" {
    const RecordingReactor = struct {
        slots: []ExecutionSlot,
        writer: *provider.CaptureWriter,
        selected: ?usize = null,
        drain_during_scan: bool = false,

        fn advance(self: *@This(), transfer: *provider.Transfer, resume_allowed: bool, _: *bool) error{}!provider.Reactor.Advance {
            // A worker may release space just after a paused candidate was
            // examined. That must not let a later candidate bypass it.
            if (self.drain_during_scan) {
                self.writer.count = 0;
                self.drain_during_scan = false;
            }
            if (!resume_allowed) return .not_ready;
            for (self.slots, 0..) |*slot, index| {
                if (slot.* == .provider and &slot.provider.transfer == transfer) {
                    self.selected = index;
                    self.writer.count = 16;
                    return .progressed;
                }
            }
            unreachable;
        }
    };
    var buffers: provider.CaptureWriter.Buffers = undefined;
    var writer = provider.CaptureWriter{ .io = std.testing.io, .buffers = &buffers };
    var host: Host = undefined;
    host.capture_writer = &writer;
    host.faults = .{};
    var slots = [_]ExecutionSlot{ .{ .provider = .{ .owner = .{} } }, .free, .{ .provider = .{ .owner = .{} } } };
    var reactor = RecordingReactor{ .slots = &slots, .writer = &writer };
    var next: usize = 0;
    for ([_]usize{ 0, 2, 0, 2 }) |expected| {
        writer.count = 0;
        try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
        try std.testing.expectEqual(expected, reactor.selected.?);
    }
    next = 2;
    reactor.selected = null;
    reactor.drain_during_scan = true;
    try std.testing.expectEqual(false, advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(?usize, null), reactor.selected);
    try std.testing.expectEqual(@as(usize, 2), next);
    try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(usize, 2), reactor.selected.?);
    slots[2] = .free;
    writer.count = 0;
    try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(usize, 0), reactor.selected.?);
    try std.testing.expect(!advanceOneTransfer(&host, &reactor, &.{}, &next));
}

fn advanceModelFinalization(host: *Host, slot: *ExecutionSlot, fail_seal: bool) bool {
    const active = &slot.provider;
    switch (active.transfer.advanceFinalization(fail_seal)) {
        .pending => return false,
        .discarded => {
            const token = active.owner.token;
            active.transfer.deinit();
            finishCustodyNow(host, slot, token);
        },
        .ready => |finished| completeTransfer(host, slot, finished),
    }
    return true;
}

fn cancelSupersededTransfers(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
) void {
    for (slots) |*slot| switch (slot.*) {
        .model_preparing => |active| {
            const superseded = host.store.operationSupersededByControl(active.binding) catch |err| {
                fenceDispatch(host, "preparation control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
            preparation.cancel();
            finishCustodyNow(host, slot, active.token);
        },
        .model_authenticating => |*active| {
            if (active.cancelled) continue;
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "authentication control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.cancelled = true;
            }
        },
        .model_refreshing => |*active| {
            if (active.cancelled) continue;
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "refresh control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.cancelled = true;
            }
        },
        .provider => |*active| {
            if (active.transfer.isDiscarded()) continue;
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            const owner = active.owner;
            traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), owner.binding);
            reactor.?.discard(&active.transfer);
            _ = advanceModelFinalization(host, slot, false);
        },
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
}

/// Returns `count` items in fresh anonymous pages: every byte is zero and no
/// page is resident until first written. Allocator.alloc promises neither,
/// because ReleaseSafe fills new memory with 0xAA and an init loop writes
/// every page, so callers whose empty state is all zero bytes use this.
fn mapZeroed(comptime T: type, count: usize) ![]T {
    if (count == 0) return &.{};
    const bytes = try std.posix.mmap(
        null,
        try std.math.mul(usize, @sizeOf(T), count),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..count];
}

fn unmapZeroed(items: anytype) void {
    if (items.len == 0) return;
    std.posix.munmap(@alignCast(std.mem.sliceAsBytes(items)));
}

test "zeroed pages are free slots and empty Turn entries" {
    const slots = try mapZeroed(ExecutionSlot, 3);
    defer unmapZeroed(slots);
    for (slots) |*slot| try std.testing.expect(slotIsFree(slot));
    try std.testing.expectEqual(slots.len, countFreeSlots(slots));
    const entries = try mapZeroed(model_adapter.TurnStates.Entry, 2);
    defer unmapZeroed(entries);
    for (entries) |entry| {
        try std.testing.expectEqual(@as(?u64, null), entry.turn_id);
        try std.testing.expectEqualStrings("", entry.value.slice());
        try std.testing.expectEqual(@as(u64, 0), entry.used);
    }
    var states: model_adapter.TurnStates = .{ .entries = entries };
    try std.testing.expectEqualStrings("", states.replay(7, @splat(1)).value);
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
};

fn activeOperationContains(context: *const anyopaque, operation_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |slot| switch (slot) {
        .provider => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_preparing => |value| if (value.binding.operation_id == operation_id) return true,
        .model_authenticating => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_refreshing => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
    return false;
}

fn activeActionContains(context: *const anyopaque, action_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |slot| switch (slot) {
        .bash_preparing => |value| if (value.binding.action_id == action_id) return true,
        .bash => |value| if (value.binding.action_id == action_id) return true,
        else => {},
    };
    return false;
}

fn advanceBash(host: *Host, slots: []ExecutionSlot, window: []u8) bool {
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash => |*active| {
            const was_running = active.execution.lifecycle.process == .running;
            const service = active.execution.service(window);
            if (was_running and active.execution.lifecycle.process != .running) {
                host.store.revokeActionSender(active.binding) catch |err| {
                    _ = failBash(host, active, "Bash sender retirement", err);
                };
            }
            made_progress = made_progress or service.made_progress;
            if (service.timeout_action) |action| {
                traceActionDeadline(host, "bash_deadline_serviced", action.deadline_ns, action.signal_failed, active.binding);
            }
            if (service.leader_observed_with_open_pipes) {
                traceAction(host, "bash_leader_observed_with_open_pipes", active.binding);
                if (host.faults.bash_observed_exit_gate_path) |path| waitAtTestGate(host, path);
            }
            if (service.fault) |err| {
                made_progress = failBash(host, active, "Bash process service", err) or made_progress;
            }
            if (active.delivery == .open and service.retired) {
                completeBash(host, active);
                made_progress = true;
            }
            if (active.delivery == .closed and service.retired) {
                const closed = &active.delivery.closed;
                const now = std.Io.Clock.Timestamp.now(host.io, .awake);
                if (now.raw.nanoseconds >= closed.reclaim_at.raw.nanoseconds) {
                    made_progress = reclaimBash(host, slot, now) or made_progress;
                }
            }
        },
        else => {},
    };
    return made_progress;
}

fn admitBashAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    preparation: *?bash.Preparation,
) AdmissionProgress {
    std.debug.assert(preparation.* == null);
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitNextActionAttempt(host.bash_timeout_ms, .{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Bash Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    const action_binding = host.custody.attachAction(token, &admission.permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Bash custody attachment", err);
        return .admitted;
    };
    testTransition(host, .action_attempt_admitted, action_binding);
    const input = host.store.readBashExecutionInput(action_binding) catch |err| {
        settleActionFailure(host, token, action_binding, .storage_failed, "Bash input could not be read.");
        finishCustodyNow(host, slot, token);
        if (host.store.isFenced()) fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const arguments = host.store.openContent(input.arguments) catch |err| {
        settleActionFailure(host, token, action_binding, .storage_failed, "Bash input could not be opened.");
        finishCustodyNow(host, slot, token);
        fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const bash_budget = host.retention.sharedBudget().narrowed(host.limits.bash_scratch_limit_bytes);
    const started = bash.startPreparation(
        host.io,
        host.allocator,
        arguments,
        input.arguments.length,
        input.session,
        host.lease.paths.store.slice(),
        input.workspace,
        host.lease.paths.scratch.slice(),
        host.bash_path,
        input.timeout_ms,
        bash_budget,
        action_binding.action_id,
        action_binding.attempt_ordinal,
        .{
            .preparation = host.faults.bash_preparation,
            .preparation_after_captures = host.faults.bash_preparation_after_captures,
            .spawn = host.faults.bash_spawn,
            .service = host.faults.bash_service,
            .capture_read = host.faults.bash_capture_read,
            .capture_write = host.faults.bash_capture_write,
            .seal = host.faults.bash_seal,
            .cleanup = host.faults.bash_cleanup,
            .lifecycle = host.faults.bash_lifecycle_fault,
            .fault_gated = host.faults.bash_fault_gated,
        },
    );
    switch (started) {
        .preparing => |value| {
            preparation.* = value;
            preparation.*.?.sender_handle = input.sender_handle;
            slot.* = .{ .bash_preparing = .{
                .token = token,
                .binding = action_binding,
            } };
        },
        .failed => |value| {
            var failure = value;
            finishBashPreparationFailure(host, slot, token, action_binding, &failure);
        },
    }
    return .admitted;
}

fn advanceBashPreparation(
    host: *Host,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
) bool {
    const active_preparation = if (preparation.*) |*value| value else return false;
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .bash_preparing => break candidate,
        else => {},
    } else unreachable;
    const preparing = slot.bash_preparing;
    if (!host.launchAllowed()) {
        const cleanup = active_preparation.cancel();
        preparation.* = null;
        discardBashResources(host, slot, preparing.token, cleanup);
        return true;
    }
    switch (active_preparation.advance()) {
        .pending => return true,
        .failed => |value| {
            var failure = value;
            preparation.* = null;
            finishBashPreparationFailure(
                host,
                slot,
                preparing.token,
                preparing.binding,
                &failure,
            );
        },
        .prepared => |value| {
            var prepared = value;
            preparation.* = null;
            launchPreparedBash(host, slot, preparing.token, preparing.binding, &prepared);
        },
    }
    return true;
}

fn finishBashPreparationFailure(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    failure: *bash.PreparationFailure,
) void {
    const canonical_failure = failure.cause == error.InvalidCanonicalBashDescriptor or
        failure.cause == error.ShortCanonicalRead;
    if (failure.cause == error.BashCommandTooLong) {
        settleActionFailure(host, token, binding, .spawn_failed, std.fmt.comptimePrint(
            "Bash was not started: the decoded command exceeds {d} bytes. Split long content across several smaller commands.",
            .{bash.max_command_bytes},
        ));
    } else if (failure.cause == error.BashStdinTooLong) {
        settleActionFailure(host, token, binding, .spawn_failed, std.fmt.comptimePrint(
            "Bash was not started: decoded stdin exceeds {d} bytes. Split the input across smaller calls or read an existing file.",
            .{bash.max_stdin_bytes},
        ));
    } else if (!canonical_failure) {
        settleActionFailure(host, token, binding, .storage_failed, "Bash preparation failed.");
    }
    failure.cleanup.cleanup() catch |cleanup_err| {
        retainBashPreparedCleanup(host, slot, token, failure.cleanup, cleanup_err);
        return;
    };
    finishCustodyNow(host, slot, token);
    if (canonical_failure or host.store.isFenced()) {
        fenceDispatch(host, "Bash canonical preparation", failure.cause);
    }
}

// Discarding an unlaunched effect changes only local custody. In particular,
// infrastructure suppression is not a user stop or a saved Action result.
fn discardBashResources(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    resources: bash.PreparedCleanup,
) void {
    var cleanup = resources;
    cleanup.cleanup() catch |err| {
        retainBashPreparedCleanup(host, slot, token, cleanup, err);
        return;
    };
    finishCustodyNow(host, slot, token);
}

fn launchPreparedBash(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    action_binding: store_module.ActionAttemptBinding,
    prepared: *bash.Prepared,
) void {
    testTransition(host, .prepared_before_handoff, action_binding);
    if (host.faults.before_launch_delay_ms != 0) {
        traceAction(host, "prepared_before_handoff", action_binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    if (!host.launchAllowed()) {
        discardBashResources(host, slot, token, prepared.takeCleanup());
        return;
    }
    host.custody.consumeActionLaunchAuthority(token, action_binding) catch |err| {
        discardBashResources(host, slot, token, prepared.takeCleanup());
        fenceDispatch(host, "Bash launch authority", err);
        return;
    };
    var launched: ?bash.Execution = null;
    host.store.withActionDispatchHandoff(action_binding, .{
        .host = host,
        .prepared = prepared,
        .launched = &launched,
    }, struct {
        fn handoff(context: anytype) !void {
            try context.host.withEffectLaunch(context, launch);
        }

        fn launch(context: anytype) !void {
            context.launched.* = try context.prepared.launch(context.host.bash_environment);
        }
    }.handoff) catch |err| {
        if (err == error.SupersededByControl) {
            settleActionFailure(host, token, action_binding, .cancelled, "Bash was stopped before launch.");
        } else if (err == error.BashSpawnFailed) {
            settleActionFailure(host, token, action_binding, .spawn_failed, "Bash process creation failed.");
        } else if (err != error.HostDispatchSuppressed) {
            fenceDispatch(host, "Bash dispatch handoff", err);
        }
        discardBashResources(host, slot, token, prepared.takeCleanup());
        return;
    };
    slot.* = .{ .bash = .{
        .token = token,
        .binding = action_binding,
        .execution = launched.?,
    } };
    traceAction(host, "bash_handoff_committed", action_binding);
    const deadline_ns = slot.bash.execution.deadlineNs();
    traceActionDeadline(host, "bash_deadline_established", deadline_ns, false, action_binding);
}

fn stopSupersededBash(
    host: *Host,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
) void {
    for (slots) |*slot| switch (slot.*) {
        .bash_preparing => |active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "Bash stop reconciliation", err);
                return;
            };
            const control = stopped orelse continue;
            traceActionControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
            var cleanup = preparation.*.?.cancel();
            preparation.* = null;
            settleActionFailure(host, active.token, active.binding, .cancelled, "Bash was stopped before launch.");
            cleanup.cleanup() catch |cleanup_err| {
                retainBashPreparedCleanup(host, slot, active.token, cleanup, cleanup_err);
                continue;
            };
            finishCustodyNow(host, slot, active.token);
        },
        .bash => |*active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "Bash stop reconciliation", err);
                return;
            };
            if (stopped) |control| {
                if (!active.stop_accepted) {
                    active.stop_accepted = true;
                    traceActionControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
                    const action = active.execution.requestStop(.now(host.io, .awake));
                    host.store.revokeActionSender(active.binding) catch |err| {
                        _ = failBash(host, active, "Bash sender retirement", err);
                    };
                    traceActionControlOutcome(
                        host,
                        "lifecycle_action_attempted",
                        control.command_key.slice(),
                        action.attempted,
                        action.signal_failed,
                        active.binding,
                    );
                }
            }
        },
        else => {},
    };
}

fn completeBash(host: *Host, active: *BashSlot) void {
    const token = active.token;
    const binding = active.binding;
    const include_paths = active.execution.reserveOutput(host.retention) catch |err| {
        _ = failBash(host, active, "Bash output reservation", err);
        return;
    };
    const outcome = active.execution.outcome(include_paths) catch |err| {
        active.execution.releaseOutputReservation(host.retention);
        _ = failBash(host, active, "Bash outcome materialization", err);
        return;
    };
    if (host.faults.before_result_delay_ms != 0) {
        traceAction(host, "sealed_before_settlement", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_result_delay_ms), .awake) catch {};
    }
    testTransition(host, .action_result_ready, binding);
    if (host.custody.claimTerminalDelivery(token)) {
        const settlement = host.store.settleActionAttempt(binding, outcome.code, outcome.text(), .{
            .content_import = host.faults.content_import,
            .before_commit = host.faults.result_before_commit,
        }) catch |err| {
            active.execution.releaseOutputReservation(host.retention);
            _ = failBash(host, active, "Bash result settlement", err);
            return;
        };
        testTransition(host, .action_result_committed, binding);
        if (settlement == .session_stop) active.execution.releaseOutputReservation(host.retention);
    } else active.execution.releaseOutputReservation(host.retention);
    closeBashDelivery(host, active);
}

fn failBash(host: *Host, active: *BashSlot, phase: []const u8, err: anyerror) bool {
    var closed = false;
    if (active.delivery == .open) {
        active.execution.releaseOutputReservation(host.retention);
        closeBashDelivery(host, active);
        closed = true;
    }
    fenceDispatch(host, phase, err);
    return closed;
}

fn closeBashDelivery(host: *Host, active: *BashSlot) void {
    std.debug.assert(active.delivery == .open);
    host.custody.detach(active.token) catch unreachable;
    traceAction(host, "cleanup_started", active.binding);
    active.delivery = .{ .closed = .{ .reclaim_at = .now(host.io, .awake) } };
}

fn reclaimBash(host: *Host, slot: *ExecutionSlot, now: std.Io.Clock.Timestamp) bool {
    const active = &slot.bash;
    if (host.faults.bash_cleanup_gate_path) |path| {
        if (testGateActive(host, path)) {
            active.delivery.closed.reclaim_at = now.addDuration(.{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            });
            return false;
        }
        // A released gate is one owner transition, not reclamation retry history.
        // reclaim_failed already remembers whether this owner attempted reclaim.
        if (!active.delivery.closed.reclaim_failed)
            traceAction(host, "cleanup_release_observed", active.binding);
    }
    active.execution.reclaim(host.retention) catch |err| {
        const first_failure = !active.delivery.closed.reclaim_failed;
        active.delivery.closed.reclaim_failed = true;
        active.delivery.closed.reclaim_at = now.addDuration(.{
            .raw = .fromMilliseconds(100),
            .clock = .awake,
        });
        if (first_failure) retainDispatchFence(host, "Bash resource reclamation", err);
        return first_failure;
    };
    const token = active.token;
    const binding = active.binding;
    host.custody.cleanupComplete(token) catch unreachable;
    slot.* = .free;
    traceAction(host, "cleanup_completed", binding);
    return true;
}

fn retainBashPreparedCleanup(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    cleanup: bash.PreparedCleanup,
    err: anyerror,
) void {
    host.custody.detach(token) catch unreachable;
    slot.* = .{ .bash_prepared_cleanup = .{
        .token = token,
        .cleanup = cleanup,
    } };
    retainDispatchFence(host, "Bash preparation cleanup", err);
}

fn settleActionFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    code: store_module.ActionResolutionCode,
    result: []const u8,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    _ = host.store.settleActionAttempt(binding, code, result, .{
        .content_import = host.faults.content_import,
        .before_commit = host.faults.result_before_commit,
    }) catch |err| {
        fenceDispatch(host, "Bash failure settlement", err);
        return;
    };
}

fn findActiveTransfer(
    context: *const anyopaque,
    handle: provider.TransportHandleIdentity,
) ?*provider.Transfer {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |*slot| {
        switch (slot.*) {
            .provider => |*value| if (value.transfer.matchesHandle(handle)) return &value.transfer,
            else => {},
        }
    }
    return null;
}

fn admitNewAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    kind: store_module.ModelAdmissionKind,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitModelAttempt(kind, .{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation);
}

fn admitRetryAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    active: store_module.ActiveOperationFilter,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.tryAdmitNextModelRetry(
        active,
        .{ .attempt_before_commit = host.faults.attempt_before_commit },
    ) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "retry Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation);
}

fn beginAdmittedAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: *store_module.DispatchPermit,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    std.debug.assert(slot.* == .free);
    const binding = host.custody.attach(token, permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "custody attachment", err);
        return .admitted;
    };
    slot.* = .{ .model_preparing = .{ .token = token, .binding = binding } };
    const view = host.store.openHistoricalView(binding) catch |err| {
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, slot, token);
            return .admitted;
        }
        fenceDispatch(host, "historical view", err);
        finishCustodyNow(host, slot, token);
        return .admitted;
    };
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.limits.request_scratch_limit_bytes,
    );
    var retained_scratch: ?named_scratch.Owner = null;
    preparation.init(
        host.io,
        view,
        host.lease.paths.scratch.slice(),
        request_budget,
        .{
            .managed_route = host.authentication != null,
            .first_step = host.faults.request_first_step,
            .write = host.faults.request_write,
            .seal = host.faults.request_seal,
            .unlink = host.faults.request_unlink,
        },
        &retained_scratch,
    ) catch |err| {
        finishModelPreparationFailure(host, slot, slot.model_preparing, err, retained_scratch);
        return .admitted;
    };
    traceOperation(host, "preparation_started", binding);
    return .admitted;
}

fn advanceModelPreparation(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
    byte_allowance: usize,
    item_allowance: usize,
) bool {
    if (host.auth_worker) |worker| {
        if (advanceCredentialWork(host, reactor.?, slots, worker)) return true;
        for (slots) |*slot| if (slot.* == .model_authenticating) return false;
    }
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .model_preparing => break candidate,
        else => {},
    } else return false;
    const owner = slot.model_preparing;
    if (execution.modelDecision(.{ .preparing = .{ .launch_allowed = host.launchAllowed() } }) == .abandon) {
        preparation.cancel();
        // Infrastructure fencing does not invent a user stop or a Resolution.
        finishCustodyNow(host, slot, owner.token);
        return true;
    }
    traceOperation(host, "preparation_advance_started", owner.binding);
    const progress = preparation.advance(byte_allowance, item_allowance);
    const stats = preparation.advanceStats();
    switch (progress) {
        .pending => {
            tracePreparationAdvance(host, "preparation_advance_completed", stats, owner.binding);
            if (host.faults.request_preparation_advance_delay_ms != 0) {
                _ = host.io.sleep(.fromMilliseconds(host.faults.request_preparation_advance_delay_ms), .awake) catch {};
            }
        },
        .failed => |err| {
            tracePreparationAdvanceError(host, "preparation_advance_failed", err, stats, owner.binding);
            preparation.cancel();
            finishModelPreparationFailure(host, slot, owner, err, null);
        },
        .prepared => |value| {
            tracePreparationAdvance(host, "preparation_advance_completed", stats, owner.binding);
            traceOperation(host, "preparation_completed", owner.binding);
            var request = value;
            switch (execution.modelDecision(.{ .prepared = .{ .authentication_required = host.auth_worker != null } })) {
                .authenticate => {
                    slot.* = .{ .model_authenticating = .{ .owner = owner, .request = request } };
                    _ = advanceCredentialWork(host, reactor.?, slots, host.auth_worker.?);
                },
                .launch => launchPreparedRequest(host, reactor.?, slot, owner, &request, null),
                else => unreachable,
            }
        },
    }
    return true;
}

/// The one worker serves one job at a time: first the slot whose job it
/// holds, then, once idle, the next waiting lease or refresh job.
fn advanceCredentialWork(host: *Host, reactor: *provider.Reactor, slots: []ExecutionSlot, worker: *AuthWorker) bool {
    for (slots) |*slot| switch (slot.*) {
        .model_authenticating => |*active| if (active.requested) return advanceAuthentication(host, reactor, slot),
        .model_refreshing => |*active| if (active.requested) return advanceRefresh(host, slot),
        else => {},
    };
    if (!worker.idle()) return false;
    for (slots) |*slot| switch (slot.*) {
        .model_authenticating => |*active| {
            if (active.cancelled) {
                active.request.deinit();
                finishCustodyNow(host, slot, active.owner.token);
            } else {
                active.requested = true;
                worker.request();
            }
            return true;
        },
        .model_refreshing => |*active| {
            if (active.cancelled) {
                finishCustodyNow(host, slot, active.owner.token);
            } else {
                active.requested = true;
                worker.requestRefresh(active.rejected_generation);
            }
            return true;
        },
        else => {},
    };
    return false;
}

/// Settles the claimed Attempt from its refresh: a committed refresh grants
/// the immediate replacement, an advanced generation fails as answered, and
/// a refresh failure keeps its own authentication code. A stop discards it.
fn advanceRefresh(host: *Host, slot: *ExecutionSlot) bool {
    const result = host.auth_worker.?.take() orelse return false;
    const active = slot.model_refreshing;
    if (!active.cancelled) {
        const rejected: store_module.ModelFailure = .{ .correlated = .{ .code = "provider_http_401", .request_id = active.request_id } };
        switch (result) {
            .refreshed => |refreshed| settleFailure(host, active.owner.token, active.owner.binding, rejected, if (refreshed) .refreshed else .ordinary),
            .failed => |err| settleUnansweredFailure(host, active.owner.token, active.owner.binding, model_adapter.authenticationFailureCode(err), .ordinary),
            .ready => unreachable,
        }
    }
    finishCustodyNow(host, slot, active.owner.token);
    return true;
}

/// Durably claims the Operation's one forced refresh for a managed 401.
/// Returns false when the claim is unavailable and the answer settles as
/// before; otherwise this owner has disposed the transfer.
fn beginForcedRefresh(host: *Host, slot: *ExecutionSlot, answered: *const AnsweredAttempt, rejected_generation: u64) bool {
    const owner = answered.owner;
    const claimed = host.store.claimModelAuthRefresh(owner.binding) catch |err| {
        if (err != error.SupersededByControl) fenceDispatch(host, "credential refresh claim", err);
        slot.provider.transfer.deinit();
        finishCustodyNow(host, slot, owner.token);
        return true;
    };
    if (!claimed) return false;
    slot.provider.transfer.deinit();
    slot.* = .{ .model_refreshing = .{
        .owner = owner,
        .rejected_generation = rejected_generation,
        .request_id = answered.request_id,
    } };
    return true;
}

fn advanceAuthentication(host: *Host, reactor: *provider.Reactor, slot: *ExecutionSlot) bool {
    const worker = host.auth_worker.?;
    const result = worker.take();
    const active = &slot.model_authenticating;
    const decision = execution.modelDecision(.{ .authenticating = .{
        .cancelled = active.cancelled,
        .launch_allowed = host.launchAllowed(),
        .result = if (result) |value| (if (value == .ready) .ready else .failed) else .pending,
    } });
    if (decision == .wait) return false;
    defer if (result.? == .ready) worker.finish();
    const owner = active.owner;
    var request = active.request;
    switch (decision) {
        .launch => launchPreparedRequest(host, reactor, slot, owner, &request, result.?.ready),
        .abandon, .settle_authentication_failure => {
            request.deinit();
            if (decision == .settle_authentication_failure)
                settleUnansweredFailure(host, owner.token, owner.binding, model_adapter.authenticationFailureCode(result.?.failed), .ordinary);
            finishCustodyNow(host, slot, owner.token);
        },
        else => unreachable,
    }
    return true;
}

fn finishModelPreparationFailure(
    host: *Host,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    err: anyerror,
    retained_scratch: ?named_scratch.Owner,
) void {
    switch (execution.modelDecision(.{ .preparation_failed = .{
        .retained_scratch = retained_scratch != null,
        .canonical_fenced = retained_scratch == null and host.store.isFenced(),
        .superseded = err == error.SupersededByControl,
    } })) {
        .retain_cleanup => {
            host.custody.detach(owner.token) catch unreachable;
            slot.* = .{ .named_scratch = .{ .token = owner.token, .owner = retained_scratch.? } };
            retainDispatchFence(host, "request scratch unlink", err);
            return;
        },
        .fence => fenceDispatch(host, "canonical request read", err),
        .settle_preparation_failure => settleUnansweredFailure(host, owner.token, owner.binding, model_adapter.preparationFailureCode(err), .ordinary),
        .abandon => {},
        else => unreachable,
    }
    finishCustodyNow(host, slot, owner.token);
}

fn launchPreparedRequest(
    host: *Host,
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    request: *provider.PreparedRequest,
    credential: ?*const model_adapter.Credential,
) void {
    const token = owner.token;
    const binding = owner.binding;
    if (!host.launchAllowed()) {
        request.deinit();
        finishCustodyNow(host, slot, token);
        return;
    }
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.limits.request_scratch_limit_bytes,
    );
    var retained_response: ?named_scratch.Owner = null;
    if (host.faults.provider_prepare) {
        request.deinit();
        settleUnansweredFailure(host, token, binding, "provider_transport_failure", failureClass(host, .temporary, null, null));
        finishCustodyNow(host, slot, token);
        return;
    }
    var headers: model_adapter.Headers = .{};
    defer headers.deinit();
    var turn_state: ?model_adapter.TurnStates.Capture = null;
    if (credential) |value| {
        const account = model_adapter.TurnStates.owner(&value.record);
        const replay = host.turn_states.replay(binding.turn_id, account);
        turn_state = .{ .states = &host.turn_states, .turn_id = binding.turn_id, .epoch = replay.epoch };
        headers.init(host.provider_endpoint.?, host.provider_ca_file, host.authentication.?, value, request.session_affinity, replay.value) catch |err| {
            request.deinit();
            fenceDispatch(host, "provider preparation", err);
            finishCustodyNow(host, slot, token);
            return;
        };
    }
    // Transfer.start gives curl pointers into the Transfer, so construct it in
    // its final slot and keep that union arm active through removal and deinit.
    slot.* = .{ .provider = .{
        .owner = .{ .token = token, .binding = binding },
        .turn_state = turn_state,
        .credential_generation = if (credential) |value| value.record.generation else null,
        .transfer = undefined,
    } };
    const active = &slot.provider;
    active.transfer.start(host.provider_endpoint.?, request.*, binding, .{
        .ca_file = host.provider_ca_file,
        .extra_headers = headers.slice(),
        .observation_names = model_adapter.observation_names,
        .turn_state = if (active.turn_state) |*capture| capture.sink() else null,
        .inactivity_seconds = @intCast(host.limits.provider_inactivity_seconds),
        .request_read_fault = host.faults.request_read,
        .response_acquire_fault = host.faults.response_acquire,
        .response_unlink_fault = host.faults.response_unlink,
        .response_write_fault = host.faults.response_write,
        .completion_identity_fault = host.faults.completion_identity_fault,
    }, host.capture_writer.?, host.lease.paths.scratch.slice(), request_budget, &retained_response) catch |err| {
        request.deinit();
        if (retained_response) |retained| {
            host.custody.detach(token) catch unreachable;
            slot.* = .{ .named_scratch = .{
                .token = token,
                .owner = retained,
            } };
            retainDispatchFence(host, "response scratch unlink", err);
            return;
        }
        stderr.print("rui: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleUnansweredFailure(host, token, binding, "response_capture_failed", .ordinary);
        } else {
            fenceDispatch(host, "provider preparation", err);
        }
        finishCustodyNow(host, slot, token);
        return;
    };
    if (host.faults.before_launch_delay_ms != 0) {
        traceOperation(host, "prepared_before_handoff", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    host.custody.consumeLaunchAuthority(token, binding) catch |err| {
        active.transfer.deinit();
        stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, slot, token);
        return;
    };
    host.store.withDispatchHandoff(
        binding,
        .{ .host = host, .reactor = reactor, .transfer = &active.transfer },
        struct {
            fn handoff(context: anytype) !void {
                try context.host.withEffectLaunch(context, launch);
            }

            fn launch(context: anytype) !void {
                try context.reactor.add(context.transfer);
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
                traceOperation(host, "canonical_handoff_superseded", binding);
            },
            .fence => {
                stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
                fenceDispatch(host, "dispatch handoff", err);
            },
            else => unreachable,
        }
        finishCustodyNow(host, slot, token);
        return;
    };
    traceOperation(host, "transport_handoff_committed", binding);
}

fn completeTransfer(
    host: *Host,
    slot: *ExecutionSlot,
    completion: provider.Completion,
) void {
    const active = &slot.provider;
    const owner = active.owner;
    traceCompletionQueue(host, completion.queued_after, owner.binding);
    defer traceOperation(host, "provider_completion_serviced", owner.binding);
    if (host.authentication != null and host.faults.test_phase_trace) {
        var publication = beginTestObservation(host, "codex_transfer", null);
        defer if (publication) |*value| value.finish();
        const observation = active.transfer.protocolObservation();
        const correlation = active.transfer.requestId();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(correlation, &digest, .{});
        var trace: protocol.ResponseBuffer = .{};
        trace.appendFmt("{{\"rui_test_phase\":\"codex_transfer\",\"operation\":\"{d}\",\"http_version\":{d},\"connection_id\":{d},\"new_connections\":{d},\"correlation_present\":{s},\"correlation_sha256\":\"{x}\",\"alpn\":\"unavailable\"}}", .{
            owner.binding.operation_id,
            observation.http_version,
            observation.connection_id,
            observation.new_connections,
            if (correlation.len != 0) "true" else "false",
            digest,
        }) catch unreachable;
        writeTestTrace(host, &trace, &publication);
    }
    var error_response: execution.ErrorResponse = .ordinary;
    var answered_response: ?provider.ResponseCapture = null;
    var http_status: ?u16 = null;
    switch (completion.outcome) {
        .transport_finished => |evidence| {
            http_status = evidence.http_status;
            if (evidence.disposition.answered()) {
                // The transport has sealed this HTTP answer. Interpretation
                // borrows it; this owner still disposes it before settlement.
                answered_response = active.transfer.takeResponse();
                const response = &answered_response.?;
                error_response = model_adapter.interpretErrorResponse(host.io, response.file, response.length, evidence.http_status);
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
        retainFailedResponse(host, .{ .file = response.file, .length = response.length, .transfer = .complete }, .{
            .binding = owner.binding,
            .code = decision.fail.codeText(&code_buffer),
            .diagnostic = diagnostic,
            .http_status = http_status,
            .request_id = active.transfer.requestId(),
        });
        response.deinit();
    }
    switch (decision) {
        .interpret_output => {
            switch (completeSuccessfulTransfer(host, active, http_status.?)) {
                .cleanup => finishCustodyNow(host, slot, owner.token),
                .named_scratch => |scratch| {
                    host.custody.detach(owner.token) catch unreachable;
                    slot.* = .{ .named_scratch = .{
                        .token = owner.token,
                        .owner = scratch,
                    } };
                },
            }
            return;
        },
        .fence_request_source => fenceDispatch(host, "request scratch read", error.RequestScratchReadFailed),
        .fail => |failure| {
            const code = failure.codeText(&code_buffer);
            const disposition = failureClass(host, failure.kind, failure.retry_after_ms, failure.retry_after_deadline_ms);
            if (failure.answered) {
                const answered: AnsweredAttempt = .init(host, owner, &active.transfer);
                if (execution.rejectsCredential(failure)) if (active.credential_generation) |generation| {
                    if (beginForcedRefresh(host, slot, &answered, generation)) return;
                };
                if (diagnostic) |detail| {
                    answered.reject(code, detail, disposition);
                } else {
                    answered.fail(code, disposition);
                }
            } else {
                // The writer has drained, so the unsealed capture holds every
                // byte accepted before the transfer or capture failed.
                const response = &active.transfer.response;
                if (response.length != 0) retainFailedResponse(host, .{
                    .file = response.file,
                    .length = response.length,
                    .transfer = if (completion.outcome == .response_capture_failed) .capture_failed else .interrupted,
                }, .{ .binding = owner.binding, .code = code, .request_id = active.transfer.requestId() });
                settleUnansweredFailure(host, owner.token, owner.binding, code, disposition);
            }
        },
    }
    active.transfer.deinit();
    finishCustodyNow(host, slot, owner.token);
}

fn failureClass(
    host: *const Host,
    kind: execution.FailureKind,
    retry_after_ms: ?u64,
    retry_after_deadline_ms: ?i64,
) store_module.ModelFailureClass {
    return switch (kind) {
        .permanent => .ordinary,
        .context_overflow => .context_overflow,
        .temporary => .{ .retryable = .{
            .waits_ms = host.limits.retry_waits_ms,
            .retry_after_ms = retry_after_ms,
            .retry_after_deadline_ms = retry_after_deadline_ms,
        } },
    };
}

const SuccessfulCompletion = union(enum) {
    cleanup,
    named_scratch: named_scratch.Owner,
};

fn completeSuccessfulTransfer(host: *Host, active: *ProviderSlot, http_status: u16) SuccessfulCompletion {
    const owner = active.owner;
    const structured_output = active.transfer.hasStructuredOutput();
    const answered: AnsweredAttempt = .init(host, owner, &active.transfer);
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(active.transfer.observedModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(active.transfer.observedAlternateModel()) catch unreachable;
    var response = active.transfer.takeResponse();
    active.transfer.deinit();
    defer response.deinit();
    const rejected: failed_responses.Source = .{ .file = response.file, .length = response.length, .transfer = .complete };
    if (model_adapter.outputSchemaRejection(structured_output, response.length)) |rejection| {
        var detail: [512]u8 = undefined;
        const diagnostic = rejection.format(&detail);
        retainFailedResponse(host, rejected, answered.retention(rejection.code, diagnostic, http_status));
        answered.reject(rejection.code, diagnostic, .ordinary);
        return .cleanup;
    }

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = named_scratch.NumericName.@"response-metadata".format(
        &metadata_name_buffer,
        owner.binding.operation_id,
        owner.binding.attempt_ordinal,
    ) catch unreachable;
    var retained_metadata: ?named_scratch.Owner = null;
    const metadata_budget = host.retention.sharedBudget().narrowed(host.limits.request_scratch_limit_bytes);
    var metadata = output_format.OutputMetadataWriter.init(
        host.io,
        host.lease.paths.scratch.slice(),
        metadata_name,
        metadata_budget,
        host.faults.response_metadata_unlink,
        &retained_metadata,
    ) catch |err| {
        if (retained_metadata) |retained| {
            retainDispatchFence(host, "response metadata unlink", err);
            return .{ .named_scratch = retained };
        }
        stderr.print("rui: response metadata acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        retainFailedResponse(host, rejected, answered.retention("response_metadata_exhausted", null, http_status));
        answered.fail("response_metadata_exhausted", .ordinary);
        return .cleanup;
    };
    defer metadata.deinit();
    // Transport already unlinked this canonical name and released request/
    // easy ownership. Reuse the response namespace for decoded SSE scratch;
    // the original sealed capture remains separate diagnostic evidence.
    var data_name_buffer: [96]u8 = undefined;
    const data_name = named_scratch.NumericName.response.format(&data_name_buffer, owner.binding.operation_id, owner.binding.attempt_ordinal) catch unreachable;
    var retained_data: ?named_scratch.Owner = null;
    var event_data = model_adapter.Output.EventData.init(host.io, host.lease.paths.scratch.slice(), data_name, metadata_budget, false, &retained_data) catch |err| {
        if (retained_data) |retained| {
            retainDispatchFence(host, "response data unlink", err);
            return .{ .named_scratch = retained };
        }
        stderr.print("rui: response data acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        retainFailedResponse(host, rejected, answered.retention("response_data_exhausted", null, http_status));
        answered.fail("response_data_exhausted", .ordinary);
        return .cleanup;
    };
    defer event_data.deinit();
    traceOperation(host, "validation_started", owner.binding);
    const operation = host.store.modelOperationKind(owner.binding) catch |err| {
        if (err != error.SupersededByControl) fenceDispatch(host, "model operation purpose", err);
        return .cleanup;
    };
    const accepted = switch (model_adapter.interpretOutput(host.io, response.file, response.length, &metadata, &event_data, operation, .{
        .openai = openai_model.slice(),
        .alternate = x_openai_model.slice(),
    }, .{
        .metadata = host.faults.response_metadata,
    })) {
        .accepted => |value| value,
        .rejected => |rejection| {
            traceOperation(host, "validation_failed", owner.binding);
            stderr.print("rui: provider output rejected for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(rejection.reason) });
            var detail: [512]u8 = undefined;
            const diagnostic = rejection.format(&detail);
            retainFailedResponse(host, rejected, answered.retention(rejection.code, diagnostic, http_status));
            answered.reject(rejection.code, diagnostic, failureClass(host, rejection.kind, null, null));
            return .cleanup;
        },
    };
    const validated = accepted.output;
    traceOperation(host, "validation_completed", owner.binding);
    if (host.faults.before_result_delay_ms != 0 or host.faults.model_result_gate_path != null) {
        traceOperation(host, "sealed_before_settlement", owner.binding);
        if (host.faults.model_result_gate_path) |path| waitAtTestGate(host, path);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_result_delay_ms), .awake) catch {};
    }
    if (!host.custody.claimTerminalDelivery(owner.token)) return .cleanup;
    var settlement_trace = SettlementTrace.init(host, owner.binding);
    host.store.settleModelSuccess(owner.binding, &.{
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
    }, .{
        .output_read = host.faults.response_read,
        .output_import = host.faults.response_import,
        .output_commit = host.faults.response_commit,
        .settlement_trace = settlement_trace.storeTrace(),
    }) catch |err| {
        if (err == error.SupersededByControl) {
            traceOperation(host, "model_settlement_superseded", owner.binding);
        } else if (err == error.InvalidProviderEnvelope) {
            const rejection: model_adapter.Output.Rejection = .{ .stage = .response, .byte_offset = response.length };
            var detail: [512]u8 = undefined;
            const diagnostic = rejection.format(err, &detail);
            retainFailedResponse(host, rejected, answered.retention("contradictory_provider_output", diagnostic, http_status));
            host.store.settleModelAttemptFailure(owner.binding, answered.rejection(
                "contradictory_provider_output",
                diagnostic,
            ), .ordinary, .{
                .before_commit = host.faults.result_before_commit,
            }) catch |failure_err| if (failure_err != error.SupersededByControl)
                fenceDispatch(host, "model envelope rejection save", failure_err);
        } else {
            fenceDispatch(host, "model output import", err);
        }
        return .cleanup;
    };
    traceOperation(host, "model_settlement_committed", owner.binding);
    return .cleanup;
}

fn advanceRetainedCleanup(
    host: *Host,
    slots: []ExecutionSlot,
    now: std.Io.Clock.Timestamp,
    retry_at: *std.Io.Clock.Timestamp,
) bool {
    if (now.raw.nanoseconds < retry_at.raw.nanoseconds) return false;
    retry_at.* = now.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash_prepared_cleanup => |*retained| {
            retained.cleanup.cleanup() catch continue;
            host.custody.cleanupComplete(retained.token) catch unreachable;
            slot.* = .free;
            made_progress = true;
        },
        .named_scratch => |*retained| {
            _ = retained.owner.reclaim(host.lease.paths.scratch.slice()) catch continue;
            host.custody.cleanupComplete(retained.token) catch unreachable;
            slot.* = .free;
            made_progress = true;
        },
        else => {},
    };
    return made_progress;
}

fn shutdownExecution(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
    model_preparation: *model_adapter.Preparation,
) void {
    // Initiate every effect's shutdown before waiting for any retirement.
    // Discarded transfers retain their pointer-stable capture storage until
    // the writer drains; that wait must not delay Bash signals or cleanup.
    for (slots) |*slot| switch (slot.*) {
        .free => {},
        .model_preparing => |active| {
            model_preparation.cancel();
            finishCustodyNow(host, slot, active.token);
        },
        .model_authenticating => |*active| {
            active.request.deinit();
            finishCustodyNow(host, slot, active.owner.token);
        },
        // Shutdown saves no failure: the claimed Attempt stays uncertain
        // and its spent claim forbids another refresh after restart.
        .model_refreshing => |active| finishCustodyNow(host, slot, active.owner.token),
        .bash_preparing => |active| {
            const cleanup = preparation.*.?.cancel();
            preparation.* = null;
            discardBashResources(host, slot, active.token, cleanup);
        },
        .bash => |*active| active.execution.requestInfrastructureShutdown(.now(host.io, .awake)),
        .bash_prepared_cleanup, .named_scratch => {},
        .provider => |*active| reactor.?.discard(&active.transfer),
    };
    var bash_window: [bash.copy_window_bytes]u8 = undefined;
    var retained_cleanup_at = std.Io.Clock.Timestamp.now(host.io, .awake);
    while (hasOwnedSlots(slots)) {
        var made_progress = false;
        for (slots) |*slot| switch (slot.*) {
            .provider => {
                // Shutdown discards transport evidence rather than invoking
                // ordinary model completion or saving a semantic failure.
                if (advanceModelFinalization(host, slot, false)) made_progress = true;
            },
            else => {},
        };
        made_progress = advanceBash(host, slots, &bash_window) or made_progress;
        const now = std.Io.Clock.Timestamp.now(host.io, .awake);
        made_progress = advanceRetainedCleanup(host, slots, now, &retained_cleanup_at) or made_progress;
        if (!made_progress) _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {};
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

/// An Attempt the provider answered with an HTTP status. Its failures carry
/// the provider's own correlation, so no answered path records a code alone.
const AnsweredAttempt = struct {
    host: *Host,
    owner: AttemptOwner,
    request_id: protocol.Bounded(256),

    fn init(host: *Host, owner: AttemptOwner, transfer: *const provider.Transfer) AnsweredAttempt {
        var request_id: protocol.Bounded(256) = .{};
        request_id.set(transfer.requestId()) catch unreachable;
        return .{ .host = host, .owner = owner, .request_id = request_id };
    }

    fn fail(self: *const AnsweredAttempt, code: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.host, self.owner.token, self.owner.binding, .{ .correlated = .{
            .code = code,
            .request_id = self.request_id,
        } }, disposition);
    }

    fn reject(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.host, self.owner.token, self.owner.binding, self.rejection(code, diagnostic), disposition);
    }

    /// For a settlement whose terminal delivery is already claimed.
    fn rejection(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8) store_module.ModelFailure {
        return .{ .rejected = .{ .code = code, .diagnostic = diagnostic, .request_id = self.request_id } };
    }

    /// The same failure facts for its optional failed-response record.
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

/// Best effort, before the owner settles and disposes the capture it just
/// classified: retains those same bytes as a private local record. Faults
/// are reported once and never change settlement, custody or cleanup. The
/// directory and record file are this serial execution transition's only
/// descriptors, within `descriptor_capacity`'s serial excess.
fn retainFailedResponse(host: *Host, source: failed_responses.Source, failure: failed_responses.Failure) void {
    if (source.length == 0) return;
    const store_dir = host.failed_response_store orelse return;
    const status = status: {
        var dir = failed_responses.open(host.io, store_dir) catch |err| break :status err;
        defer dir.close(host.io);
        const retained = failed_responses.retain(host.io, dir, .{}, source, failure) catch |err| break :status err;
        break :status retained.omission orelse return;
    };
    stderr.print("rui: failed response for operation {d} attempt {d} not retained ({s}); its saved failure is unchanged\n", .{
        failure.binding.operation_id, failure.binding.attempt_ordinal, @errorName(status),
    });
}

/// A failure with no provider answer to correlate. Answered paths settle
/// through `AnsweredAttempt` instead.
fn settleUnansweredFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    code: []const u8,
    disposition: store_module.ModelFailureClass,
) void {
    settleFailure(host, token, binding, .{ .uncorrelated = code }, disposition);
}

fn settleFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    failure: store_module.ModelFailure,
    disposition: store_module.ModelFailureClass,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    host.store.settleModelAttemptFailure(binding, failure, disposition, .{
        .before_commit = host.faults.result_before_commit,
    }) catch |err| if (err != error.SupersededByControl)
        fenceDispatch(host, "model failure save", err);
}

fn finishCustodyNow(host: *Host, slot: *ExecutionSlot, token: execution.CustodyToken) void {
    // Capture checked identity while attached, but observe only after callers
    // have retired resources and this owner has released custody and the slot.
    const model_binding = if (host.faults.test_phase_trace)
        host.custody.binding(token) catch null
    else
        null;
    const action_binding = if (host.faults.test_phase_trace and model_binding == null)
        host.custody.actionBinding(token) catch unreachable
    else
        null;
    host.custody.detach(token) catch unreachable;
    host.custody.cleanupComplete(token) catch unreachable;
    slot.* = .free;
    if (model_binding) |binding| traceOperation(host, "cleanup_completed", binding);
    if (action_binding) |binding| traceAction(host, "cleanup_completed", binding);
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
    try credentials.install(path, &record, null);

    var worker = AuthWorker{ .io = io, .authentication = .{ .path = path } };
    try credentials.leaseInto(path, &worker.credential);
    worker.state = .ready;
    defer if (worker.state == .ready or worker.state == .in_use) worker.credential.release();
    const borrowed = worker.take().?.ready;
    try std.testing.expect(borrowed == &worker.credential);
    try std.testing.expect(worker.take() == null);
    try std.testing.expectEqualStrings("test-refresh", borrowed.record.refresh_token.slice());
    worker.finish();
    try std.testing.expect(worker.state == .idle);
    worker.request();
    try std.testing.expect(worker.state == .requested);
    // The released lock can be acquired again for the next generation.
    var next: credentials.Lease = undefined;
    try credentials.leaseInto(path, &next);
    next.release();

    // Exercise the production model owner after cancellation, both before
    // the worker publishes and with either actual result. No Store or reactor
    // may be touched; the request and credential lease remain native owners.
    for ([_]bool{ false, true }) |ready| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
            .auth_worker = &worker,
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 7,
            .operation_id = 19,
            .attempt_ordinal = 3,
        } };
        const binding = try host.custody.attach(token, &permit);
        const output = try tmp.dir.createFile(io, "request", .{});
        try output.writeStreamingAll(io, "body");
        output.close(io);
        const input = try tmp.dir.openFile(io, "request", .{});
        try tmp.dir.deleteFile(io, "request");
        host.scratch_used.store(4, .release);
        var slot = ExecutionSlot{ .model_authenticating = .{
            .owner = .{ .token = token, .binding = binding },
            .cancelled = true,
            .request = .{
                .io = io,
                .file = input,
                .length = 4,
                .charged = 4,
                .budget = .{ .used = &host.scratch_used, .limit = 4 },
                .structured_output = false,
                .session_affinity = @splat(0),
            },
        } };
        defer if (slot == .model_authenticating) slot.model_authenticating.request.deinit();
        var reactor: provider.Reactor = undefined;
        worker.state = .requested;
        try std.testing.expect(!advanceAuthentication(&host, &reactor, &slot));
        try std.testing.expect(slot == .model_authenticating);
        try std.testing.expectEqual(@as(u64, 4), host.scratch_used.load(.acquire));
        try std.testing.expect(host.custody.reserve() == null);
        if (ready) {
            try credentials.leaseInto(path, &worker.credential);
            worker.state = .ready;
        } else {
            worker.failure = error.AuthenticationFailed;
            worker.state = .failed;
        }
        try std.testing.expect(advanceAuthentication(&host, &reactor, &slot));
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        try std.testing.expect(worker.state == .idle);
        const reused = host.custody.reserve().?;
        try std.testing.expect(reused.generation != token.generation);
        try std.testing.expect(!host.custody.claimTerminalDelivery(token));
        try host.custody.releaseUnused(reused);
    }
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
                // Observe the real descriptor while close still owns it,
                // including a close that suspends before retiring the handle.
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
    try provider.initialize();
    defer provider.deinitialize();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var vtable = std.testing.io.vtable.*;
    vtable.fileClose = Boundary.close;
    vtable.now = Boundary.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    for (0..3) |kind| {
        var used: std.atomic.Value(u64) = .init(17);
        const budget = protocol.ScratchBudget{ .used = &used, .limit = 4096 };
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{ .test_phase_trace = true },
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 3,
            .operation_id = 7,
            .attempt_ordinal = 2,
        } };
        const binding = try host.custody.attach(token, &permit);
        // Delivery already claimed: this owner regression exercises physical
        // retirement without fabricating a Store settlement. Dispatch integration
        // separately verifies the durable HTTP overflow/failure meanings.
        try std.testing.expect(host.custody.claimTerminalDelivery(token));
        var slot: ExecutionSlot = .{ .provider = .{ .owner = .{ .token = token, .binding = binding } } };
        Boundary.slot = &slot;
        Boundary.custody = &host.custody;
        Boundary.used = &used;
        Boundary.response_fd = -1;
        Boundary.closes = 0;
        Boundary.retirement_observed = false;
        const request_file = try tmp.dir.createFile(io, "request", .{ .read = true });
        try request_file.writeStreamingAll(io, "{}");
        try std.testing.expect(budget.charge(2));
        var buffers: provider.CaptureWriter.Buffers = undefined;
        var writer = provider.CaptureWriter{ .io = io, .buffers = &buffers };
        var retained: ?named_scratch.Owner = null;
        try slot.provider.transfer.start("http://127.0.0.1:1/responses", .{
            .io = io,
            .file = request_file,
            .length = 2,
            .charged = 2,
            .budget = budget,
            .structured_output = false,
            .session_affinity = @splat(0),
        }, binding, .{}, &writer, root, budget, &retained);
        errdefer if (slot == .provider) slot.provider.transfer.deinit();
        const body = if (kind == 2) "{\"error\":{\"code\":\"invalid_api_key\"}}" else "{\"error\":{\"code\":\"context_length_exceeded\"}}";
        const response = &slot.provider.transfer.response;
        try response.file.writeStreamingAll(io, body);
        try std.testing.expect(budget.charge(body.len));
        response.charged = body.len;
        response.length = body.len;
        try response.seal(false);
        Boundary.response_fd = response.file.handle;
        if (kind == 1) {
            // A short sealed read is a real classifier error, not malformed
            // JSON's negative-overflow result.
            response.length += 1;
            try std.testing.expectError(error.ShortSealedRead, model_adapter.Output.contextOverflow(io, response.file, response.length, 400));
        }
        completeTransfer(&host, &slot, .{
            .outcome = .{ .transport_finished = .{ .disposition = .permanent_http, .http_status = 400 } },
            .queued_after = 0,
        });
        try std.testing.expect(Boundary.retirement_observed);
        try std.testing.expectEqual(@as(usize, 1), Boundary.closes);
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
        try std.testing.expect(slot == .free);
        try std.testing.expect(host.custody.reserve() != null);
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
                self.custody.checkDetached(self.token) catch unreachable;
                self.release_expected = false;
                self.releases += 1;
                return clock.now(std.testing.io);
            }
            // The completion timestamp is constructed before either native
            // publication or optional stderr. Inspect actual owner facts here.
            std.debug.assert(self.slot.* == .free);
            self.custody.checkFree(self.token) catch unreachable;
            checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(self.slot))[0..1], self.custody) catch unreachable;
            self.observed = true;
            return clock.now(std.testing.io);
        }
    };
    var boundary: Boundary = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Boundary.now;
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = .{ .userdata = &boundary, .vtable = &vtable },
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{ .test_phase_trace = true },
        .custody = execution.CustodyPool.initialize(&records),
    };
    var slot: ExecutionSlot = .free;
    boundary.slot = &slot;
    boundary.custody = &host.custody;
    // Both typed owners and admission-local Action custody before an
    // execution payload is installed share this boundary.
    for (0..3) |kind| {
        const token = host.custody.reserve().?;
        boundary.token = token;
        boundary.observed = false;
        if (kind == 0) {
            var permit = store_module.DispatchPermit{ .binding = .{
                .turn_id = 3,
                .operation_id = 7,
                .attempt_ordinal = 2,
            } };
            const binding = try host.custody.attach(token, &permit);
            slot = .{ .model_preparing = .{ .token = token, .binding = binding } };
            finishCustodyNow(&host, &slot, token);
        } else {
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 3,
                .parent_operation_id = 7,
                .action_id = 11,
                .attempt_ordinal = 2,
            } };
            const binding = try host.custody.attachAction(token, &permit);
            if (kind == 2) slot = .{ .bash_preparing = .{ .token = token, .binding = binding } };
            finishCustodyNow(&host, &slot, token);
        }
        try std.testing.expect(boundary.observed);
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    }

    // Exercise the distinct delayed Bash owner with real process/pipe
    // retirement and charged capture resources, not a model stand-in.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root});
    var storage = try store_module.Store.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    const arguments = "{\"description\":\"Print test marker\",\"cmd\":\"printf x\",\"timeout_ms\":1000}";
    const content = try store_module.testingPublicProjection(&storage, &tmp, &.{.{
        .encoded = "{\\\"description\\\":\\\"Print test marker\\\",\\\"cmd\\\":\\\"printf x\\\",\\\"timeout_ms\\\":1000}",
        .decoded = arguments,
    }});
    const reader = try storage.openPublicConversationContent(content);
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(root);
    var used: std.atomic.Value(u64) = .init(0);
    const budget = protocol.ScratchBudget{ .used = &used, .limit = 4096 };
    var entries: [2]output_retention.Entry = undefined;
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    host.retention = &retention;
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set("k7m2qx");
    var preparation = switch (bash.startPreparation(std.testing.io, std.testing.allocator, reader, arguments.len, session, root, workspace, root, default_bash_path, 1000, budget, 11, 2, .{})) {
        .preparing => |value| value,
        .failed => |initial| {
            var failure = initial;
            try failure.cleanup.cleanup();
            return failure.cause;
        },
    };
    var preparation_owned = true;
    defer if (preparation_owned) {
        var cleanup = preparation.cancel();
        cleanup.cleanup() catch unreachable;
    };
    var prepared = while (true) {
        switch (preparation.advance()) {
            .pending => {},
            .prepared => |value| {
                preparation_owned = false;
                break value;
            },
            .failed => |initial| {
                preparation_owned = false;
                var failure = initial;
                try failure.cleanup.cleanup();
                return failure.cause;
            },
        }
    };
    defer prepared.cleanup() catch unreachable;
    const token = host.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 3,
        .parent_operation_id = 7,
        .action_id = 11,
        .attempt_ordinal = 2,
    } };
    const binding = try host.custody.attachAction(token, &permit);
    try host.custody.detach(token);
    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{
        .raw = .fromSeconds(5),
        .clock = .awake,
    });
    slot = .{ .bash = .{ .token = token, .binding = binding, .execution = try prepared.launch(&bash.empty_environment), .delivery = .{ .closed = .{ .reclaim_at = deadline } } } };
    var window: [bash.copy_window_bytes]u8 = undefined;
    defer if (slot == .bash) {
        slot.bash.execution.requestInfrastructureShutdown(.now(std.testing.io, .awake));
        const cleanup_deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{
            .raw = .fromSeconds(5),
            .clock = .awake,
        });
        while (!slot.bash.execution.retired()) {
            std.debug.assert(std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds < cleanup_deadline.raw.nanoseconds);
            _ = slot.bash.execution.service(&window);
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        slot.bash.execution.reclaim(&retention) catch unreachable;
    };
    while (!slot.bash.execution.retired()) {
        try std.testing.expect(std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds < deadline.raw.nanoseconds);
        const progress = slot.bash.execution.service(&window);
        try std.testing.expect(progress.fault == null);
        if (!progress.made_progress) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try slot.bash.execution.checkRetired();
    try std.testing.expectEqual(store_module.ActionResolutionCode.succeeded, (try slot.bash.execution.outcome(false)).code);
    // One captured stdout byte remains owned.
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    boundary.token = token;
    boundary.observed = false;
    var gate_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    host.faults.bash_cleanup_gate_path = try std.fmt.bufPrint(&gate_path_buffer, "{s}/released-gate", .{root});
    // A released gate grants one reclamation transition, even if removal
    // fails repeatedly. The same charged capture and custody survive retry.
    slot.bash.execution.stdout_capture.cleanup_fault = .persistent;
    boundary.release_expected = true;
    try std.testing.expect(reclaimBash(&host, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expect(!boundary.observed);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(&slot))[0..1], &host.custody);
    try std.testing.expect(!reclaimBash(&host, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try host.custody.checkDetachedAction(token, binding);
    slot.bash.execution.stdout_capture.cleanup_fault = .none;
    try std.testing.expect(reclaimBash(&host, &slot, deadline));
    try std.testing.expect(boundary.observed);
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
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
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attach(token, &permit);
    const owner = ModelPreparingSlot{ .token = token, .binding = binding };
    var slots = [_]ExecutionSlot{.{ .model_preparing = owner }};
    finishModelPreparationFailure(
        &host,
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
    try std.testing.expect(host.dispatch_fenced.load(.acquire));
    try host.custody.checkDetachedModel(token, binding);

    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = now;
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, now, &retry_at));
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-owner.tmp", .{});

    var preparation: ?bash.Preparation = null;
    const Shutdown = struct {
        fn run(
            test_host: *Host,
            test_slots: []ExecutionSlot,
            test_preparation: *?bash.Preparation,
        ) void {
            var model_preparation: model_adapter.Preparation = undefined;
            shutdownExecution(
                test_host,
                null,
                test_slots,
                test_preparation,
                &model_preparation,
            );
        }
    };
    const shutdown = try std.Thread.spawn(
        .{},
        Shutdown.run,
        .{ &host, slots[0..], &preparation },
    );
    removal_gate.store(false, .release);
    shutdown.join();

    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-owner.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, now, &retry_at));
}

test "execution slots agree with custody across the complete population" {
    var records: [2]execution.CustodyRecord = undefined;
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
        .attempt_ordinal = 1,
    } };
    const action_token = custody.reserve().?;
    const action_binding = try custody.attachAction(action_token, &action_permit);

    var slots = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .{ .bash = .{
            .token = action_token,
            .binding = action_binding,
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody);

    // A foreign binding in one payload is rejected while the other still agrees.
    slots[0] = .{ .provider = .{ .owner = .{
        .token = model_token,
        .binding = .{ .turn_id = 9, .operation_id = 9, .attempt_ordinal = 9 },
    } } };
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody));
    slots[0] = .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } };
    try checkSlotCustodyAgreement(&slots, &custody);

    // An occupied custody record with no owning slot is orphaned capacity:
    // attached or detached, it must fail the whole-execution check.
    var orphan = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .free,
    };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody));
    try custody.detach(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody));
    var empty = [_]ExecutionSlot{ .free, .free };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.cleanupComplete(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.detach(model_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.cleanupComplete(model_token);
    try checkSlotCustodyAgreement(&empty, &custody);

    // Two payloads on one token collide instead of sharing it.
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
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&shared, &custody));

    // A stale payload after reuse leaves the new owner unchanged.
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
    try std.testing.expectError(error.StaleCustody, checkSlotCustodyAgreement(&stale, &custody));
    // The complete population names the current owner: no orphan remains.
    var current = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = reused, .binding = reused_binding } } },
    };
    try checkSlotCustodyAgreement(&current, &custody);
    try custody.detach(reused);
    try custody.cleanupComplete(reused);
}

test "no-work admission restores only its temporary custody reservation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    var storage = try store_module.Store.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;

    // Every call has genuinely free capacity and a real Store with no eligible
    // work. A represented sibling must survive release of the new reservation.
    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var records: [3]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
                .faults = .{},
                .custody = execution.CustodyPool.initialize(&records),
            };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) host.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try host.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                host.custody.detach(token) catch unreachable;
                host.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var bash_preparation: ?bash.Preparation = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&host, &slots[0], &bash_preparation),
                .retry => admitRetryAttempt(&host, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation),
                .message => admitNewAttempt(&host, &slots[0], .message, &model_preparation),
                .tool_continuation => admitNewAttempt(&host, &slots[0], .tool_continuation, &model_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.no_work, progress);
            try std.testing.expect(slots[0] == .free);
            try std.testing.expect(bash_preparation == null);
            try std.testing.expect(!host.dispatch_fenced.load(.acquire));
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);
            try std.testing.expect(!(try storage.inspectSession("direct/no-work")).found);

            // Restored accounting must mean immediately reusable capacity,
            // not just a corrected counter or accidental sibling release.
            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = host.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(host.custody.reserve() == null);
            for (reused[0..free]) |token| try host.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);
        }
    }
}

test "failed admission releases its reservation and fences the Store and dispatch" {
    // Message admission fails its real commit; every other admission meets the
    // Store that failure fenced. Each catch must release the new reservation.
    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var root_buffer: [protocol.max_store_bytes]u8 = undefined;
            const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
            var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
            const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
            var storage = try store_module.Store.open(std.testing.io, database, root);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
            defer directory.close(std.testing.io);
            const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
            var command: protocol.ConfigureCommand = .{};
            try command.key.set("failed-admission-config");
            command.configuration.workspace.state = .value;
            try command.configuration.workspace.value.set(workspace);
            command.configuration.provider.state = .value;
            try command.configuration.provider.value.set("codex");
            command.configuration.model.state = .value;
            try command.configuration.model.value.set("model-a");
            const configured = storage.configure(&command, true, .{});
            try std.testing.expect(configured == .accepted);
            const file = try tmp.dir.createFile(std.testing.io, "failed-admission-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "hello");
            try file.sync(std.testing.io);
            var message: protocol.MessageCommand = .{};
            try message.key.set("failed-admission-key");
            message.session = configured.accepted.session;
            message.text = .{
                .state = .value,
                .file = file,
                .length = 5,
                .digest = protocol.contentDigest("hello"),
            };
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
            if (kind != .message) {
                try std.testing.expectError(
                    error.InjectedAttemptCommitFailure,
                    storage.admitModelAttempt(.message, .{ .attempt_before_commit = true }),
                );
                try std.testing.expect(storage.isFenced());
            }

            var records: [3]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
                .faults = .{ .attempt_before_commit = kind == .message },
                .custody = execution.CustodyPool.initialize(&records),
            };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) host.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try host.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                host.custody.detach(token) catch unreachable;
                host.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var bash_preparation: ?bash.Preparation = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&host, &slots[0], &bash_preparation),
                .retry => admitRetryAttempt(&host, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation),
                .message => admitNewAttempt(&host, &slots[0], .message, &model_preparation),
                .tool_continuation => admitNewAttempt(&host, &slots[0], .tool_continuation, &model_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.retry_later, progress);
            try std.testing.expect(storage.isFenced());
            try std.testing.expect(host.dispatch_fenced.load(.acquire));
            try std.testing.expect(slots[0] == .free);
            try std.testing.expect(bash_preparation == null);
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);

            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = host.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(host.custody.reserve() == null);
            for (reused[0..free]) |token| try host.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, host.custody.occupied());
        }
    }
}

test "closed Bash delivery retains its payload with detached custody" {
    var records: [2]execution.CustodyRecord = undefined;
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
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 2,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attachAction(token, &permit);
    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .token = token,
            .binding = binding,
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &host.custody);

    // The real delivery-close transition detaches custody while retaining
    // the .bash payload for reclamation: the checker must accept it.
    closeBashDelivery(&host, &slots[0].bash);
    try std.testing.expect(slots[0].bash.delivery == .closed);
    try host.custody.checkDetachedAction(token, binding);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    // The flagged failed-reclamation state is accepted by the checker. This
    // covers the flag value only: no failing reclaimer runs here and no Bash
    // resources are retained through retry.
    slots[0].bash.delivery.closed.reclaim_failed = true;
    try checkSlotCustodyAgreement(&slots, &host.custody);

    // Closed delivery with still-attached custody is the invalid shape:
    // it must fail rather than pass as a retained payload.
    const second = host.custody.reserve().?;
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 4,
        .parent_operation_id = 4,
        .action_id = 5,
        .attempt_ordinal = 1,
    } };
    const second_binding = try host.custody.attachAction(second, &second_permit);
    const bad = [_]ExecutionSlot{
        .{ .bash = .{
            .token = second,
            .binding = second_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{
                .reclaim_at = std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            } },
        } },
        .free,
    };
    // Complete population: the first slot's detached token plus the bad
    // slot's attached token account for both occupied records, so the
    // failure below is the custody-state mismatch, not an orphan.
    var both = [_]ExecutionSlot{ slots[0], bad[0] };
    try std.testing.expectError(error.InvalidCustodyTransition, checkSlotCustodyAgreement(&both, &host.custody));
    try host.custody.detach(second);
    try host.custody.cleanupComplete(second);
    try host.custody.cleanupComplete(token);
    slots[0] = .free;
    try checkSlotCustodyAgreement(&slots, &host.custody);
}

test "closed Bash payloads keep their typed binding identity" {
    var records: [2]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);

    var first_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_token = custody.reserve().?;
    const first_binding = try custody.attachAction(first_token, &first_permit);
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 2,
        .parent_operation_id = 2,
        .action_id = 2,
        .attempt_ordinal = 1,
    } };
    const second_token = custody.reserve().?;
    const second_binding = try custody.attachAction(second_token, &second_permit);
    try custody.detach(first_token);
    try custody.detach(second_token);

    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .token = first_token,
            .binding = first_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{ .reclaim_at = now } },
        } },
        .{ .bash = .{
            .token = second_token,
            .binding = second_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{ .reclaim_at = now } },
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody);

    slots[0].bash.token = second_token;
    slots[1].bash.token = first_token;
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody));
    slots[0].bash.token = first_token;
    slots[1].bash.token = second_token;
    try checkSlotCustodyAgreement(&slots, &custody);
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
    var storage = try store_module.Store.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
    var command: protocol.ConfigureCommand = .{};
    try command.key.set("prep-belong-config");
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set("model-a");
    const configured = storage.configure(&command, true, .{});
    try std.testing.expect(configured == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "prep-belong-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "hello");
    try file.sync(std.testing.io);
    var message: protocol.MessageCommand = .{};
    try message.key.set("prep-belong-key");
    message.session = configured.accepted.session;
    message.text = .{
        .state = .value,
        .file = file,
        .length = 5,
        .digest = protocol.contentDigest("hello"),
    };
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding_a = try admitted.permit.consume();

    // A live preparation for Attempt A, held in final storage under test
    // ownership with a guard beside the acquisition.
    const view = try storage.openHistoricalView(binding_a);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: model_adapter.Preparation = undefined;
    try preparation.init(std.testing.io, view, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    var preparation_active = true;
    defer if (preparation_active) preparation.cancel();

    var records: [1]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);
    // A valid slot/custody binding for a different Attempt B: internally
    // consistent, but it does not belong to the live preparation.
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
    try checkSlotCustodyAgreement(&mismatched, &custody);
    try std.testing.expectError(error.PreparationBindingMismatch, checkSharedPreparation(&mismatched, &preparation, null));

    // The slot naming Attempt A belongs together with the live preparation.
    var matched = [_]ExecutionSlot{
        .{ .model_preparing = .{ .token = token, .binding = binding_a } },
    };
    // Re-anchor custody to A so each layer agrees before composing them.
    try custody.detach(token);
    try custody.cleanupComplete(token);
    const retoken = custody.reserve().?;
    var permit_a = store_module.DispatchPermit{ .binding = binding_a };
    const attached_a = try custody.attach(retoken, &permit_a);
    matched[0] = .{ .model_preparing = .{ .token = retoken, .binding = attached_a } };
    try checkSlotCustodyAgreement(&matched, &custody);
    try checkSharedPreparation(&matched, &preparation, null);

    // No live preparation with a preparing slot, and vice versa.
    var empty = [_]ExecutionSlot{.free};
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&empty, &preparation, null));
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&matched, null, null));
    try checkSharedPreparation(&empty, null, null);

    // Bash correspondence uses only the facts its preparation owns.
    var bash_preparation = bash.Preparation{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = root,
        .workspace = .{},
        .scratch_path = root,
        .bash_path = default_bash_path,
        .timeout_ms = 1,
        .action_id = 7,
        .attempt_ordinal = 1,
        .faults = .{},
        .source = undefined,
        .cleanup = .{ .scratch_path = root },
    };
    var bash_matched = [_]ExecutionSlot{
        .{ .bash_preparing = .{ .token = retoken, .binding = .{
            .turn_id = 1,
            .parent_operation_id = 1,
            .action_id = 7,
            .attempt_ordinal = 1,
        } } },
    };
    // Note: retoken is model-attached above, so slot/custody agreement is
    // not asserted for this slice; only preparation correspondence is.
    try checkSharedPreparation(&bash_matched, null, &bash_preparation);
    bash_matched[0].bash_preparing.binding.action_id = 8;
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
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attach(token, &permit);
    try std.testing.expectEqual(@as(u64, 1), binding.operation_id);
    try host.custody.detach(token);
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

    // Removal blocked: the actual release caller retains the slot, the
    // detached custody, the reservation, and the pathname. No admission
    // can reuse that capacity.
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = start;
    var reclaimed = false;
    errdefer if (!reclaimed) {
        removal_gate.store(false, .release);
        var retry = retry_at;
        _ = advanceRetainedCleanup(&host, &slots, retry, &retry);
    };
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, start, &retry_at));
    try host.custody.checkDetached(token);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    try checkSharedPreparation(&slots, null, null);
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    try std.testing.expectEqual(@as(usize, 0), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-direct.tmp", .{});

    // The same instant is too early for the low-frequency retry.
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, start, &retry_at));

    // After the fault clears, the same production path reclaims the owner
    // before completing custody, and the slot becomes reusable.
    removal_gate.store(false, .release);
    try std.testing.expect(advanceRetainedCleanup(&host, &slots, retry_at, &retry_at));
    reclaimed = true;
    try host.custody.checkFree(token);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(usize, 1), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-direct.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, retry_at, &retry_at));
}

test "provider metadata uses shared scratch reclamation without widening its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const root_budget = protocol.ScratchBudget{ .used = &used, .limit = 104 };
    var entries: [2]output_retention.Entry = undefined;
    var retention = output_retention.Queue.initialize(std.testing.io, root, root_budget, &entries);
    defer retention.cleanupAll();

    var stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{ .read = true });
    var stderr_file = try tmp.dir.createFile(std.testing.io, "stderr", .{ .read = true });
    try std.testing.expect(root_budget.charge(2));
    const pair = (try retention.reservePair("stdout", 1, "stderr", 1)).?;
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
        metadata.append(.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), retention.occupied());

    stdout.close(std.testing.io);
    stderr_file.close(std.testing.io);
    try retention.publishPair(pair);
    try metadata.append(.{ .tag = .usage, .start = 0, .length = 0 });
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
        limited.append(.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "Host fences dispose admitted preparation without touching canonical state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined, // The suppression path must not query or settle.
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try host.custody.attach(token, &permit);
        var preparation: model_adapter.Preparation = undefined;
        var retained: ?named_scratch.Owner = null;
        try preparation.init(
            std.testing.io,
            .{ .store = undefined, .binding = binding },
            root,
            .{ .used = &host.scratch_used, .limit = 1024 },
            .{},
            &retained,
        );
        // Real file aliases and a real reservation are owned before fencing.
        try preparation.writer.write("partial request");
        var slots = [_]ExecutionSlot{.{ .model_preparing = .{
            .token = token,
            .binding = binding,
        } }};
        @field(host, flag).store(true, .release);
        try std.testing.expect(advanceModelPreparation(
            &host,
            null,
            &slots,
            &preparation,
            host.limits.request_preparation_byte_allowance,
            host.limits.request_preparation_item_allowance,
        ));
        try std.testing.expect(!preparation.active and !preparation.view.active);
        try std.testing.expect(slots[0] == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    }
}

test "Host fences dispose a sealed request before native transfer construction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try host.custody.attach(token, &permit);
        const writer = try tmp.dir.createFile(std.testing.io, "sealed", .{});
        try writer.writeStreamingAll(std.testing.io, "{}");
        writer.close(std.testing.io);
        const reader = try tmp.dir.openFile(std.testing.io, "sealed", .{});
        try tmp.dir.deleteFile(std.testing.io, "sealed");
        host.scratch_used.store(2, .release);
        var request = provider.PreparedRequest{
            .io = std.testing.io,
            .file = reader,
            .length = 2,
            .charged = 2,
            .budget = .{ .used = &host.scratch_used, .limit = 2 },
            .structured_output = false,
            .session_affinity = @splat(0),
        };
        const owner = ModelPreparingSlot{ .token = token, .binding = binding };
        var slot = ExecutionSlot{ .model_preparing = owner };
        var reactor: provider.Reactor = undefined; // Must never be accessed.
        @field(host, flag).store(true, .release);
        launchPreparedRequest(&host, &reactor, &slot, owner, &request, null);
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
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
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        for ([_]bool{ false, true }) |fail_cleanup| {
            var records: [1]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = &lease,
                .store = undefined, // No canonical query, cancellation, or result.
                .faults = .{},
                .custody = execution.CustodyPool.initialize(&records),
            };
            const token = host.custody.reserve().?;
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 1,
                .parent_operation_id = 1,
                .action_id = 1,
                .attempt_ordinal = 1,
            } };
            const binding = try host.custody.attachAction(token, &permit);
            const file = try tmp.dir.createFile(std.testing.io, "suppressed-bash", .{});
            try file.writeStreamingAll(std.testing.io, "output\n");
            var name: protocol.Bounded(96) = .{};
            try name.set("suppressed-bash");
            host.scratch_used.store(7, .release);
            if (fail_cleanup) {
                const gate = try tmp.dir.createFile(std.testing.io, bash.fault_gate_name, .{});
                gate.close(std.testing.io);
            }
            var prepared = bash.Prepared{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .session = .{},
                .store_selector = "",
                .workspace = .{},
                .scratch_path = root,
                .bash_path = undefined, // Native construction must not run.
                .timeout_ms = 1,
                .faults = .{},
                .command = try std.testing.allocator.dupeSentinel(u8, "exit 0", 0),
                .stdout_capture = .{
                    .io = std.testing.io,
                    .file = file,
                    .name = name,
                    .charged = 7,
                    .budget = .{ .used = &host.scratch_used, .limit = 7 },
                    .cleanup_fault = if (fail_cleanup) .gated else .none,
                },
                .stderr_capture = null,
            };
            var slots = [_]ExecutionSlot{.{ .bash_preparing = .{
                .token = token,
                .binding = binding,
            } }};
            @field(host, flag).store(true, .release);
            launchPreparedBash(&host, &slots[0], token, binding, &prepared);
            try std.testing.expect(prepared.stdout_capture == null);
            try std.testing.expect(prepared.command == null);
            // A retained cleanup fence must not become an effect shutdown.
            try std.testing.expectEqual(std.mem.eql(u8, flag, "effect_shutdown"), host.effect_shutdown.load(.acquire));
            if (fail_cleanup) {
                try std.testing.expect(slots[0] == .bash_prepared_cleanup);
                try std.testing.expect(slots[0].bash_prepared_cleanup.cleanup.stdout_capture.?.file == null);
                try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
                try std.testing.expectEqual(@as(u64, 7), host.scratch_used.load(.acquire));
                try tmp.dir.deleteFile(std.testing.io, bash.fault_gate_name);
                const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
                var retry_at = now;
                try std.testing.expect(advanceRetainedCleanup(&host, &slots, now, &retry_at));
            }
            try std.testing.expect(slots[0] == .free);
            try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "suppressed-bash", .{}));
        }
    }
}
