const std = @import("std");
const TestObservation = @import("TestObservation.zig");
const trace_native = @import("posix");
const bash = @import("bash.zig");
const execution = @import("execution.zig");
const model_adapter = @import("model_adapter.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const product_defaults = @import("product_defaults.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const retry_policy = @import("retry_policy.zig");
const store_module = @import("store.zig");
const stderr = @import("stderr.zig");

pub const default_bash_timeout_ms: u64 = 5 * 60 * 1000;
pub const default_bash_path = "/bin/bash";
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const default_retention_entry_capacity =
    output_retention.orchestration_bytes / @sizeOf(output_retention.Entry);
/// Real operating limits. Tests may narrow them; production uses the defaults.
pub const Limits = struct {
    request_scratch_limit_bytes: u64 = scratch_limit_bytes,
    request_preparation_byte_allowance: usize = model_adapter.preparation_byte_allowance,
    request_preparation_item_allowance: usize = model_adapter.preparation_item_allowance,
    bash_scratch_limit_bytes: u64 = scratch_limit_bytes,
    retention_entry_capacity: ?usize = null,
    provider_inactivity_seconds: i64 = 5 * 60,
    retry_waits_ms: retry_policy.Waits = retry_policy.default_waits_ms,
    client_send_buffer_bytes: ?u32 = null,
    sqlite_cache_spill: bool = true,
    sqlite_cache_kib: u32 = (store_module.OpenOptions{}).cache_kib,
};

/// Test hooks: injected failures, holds and observation, set only by the
/// hidden `host serve` test options and empty in production. Work consults
/// them at named points, and the owner views below say which failures reach
/// which owner, so no work site copies them field by field.
pub const Hooks = struct {
    failures: std.EnumSet(Failure) = .empty,
    bash_lifecycle: bash.LifecycleFault = .none,
    pauses: std.EnumArray(std.meta.Tag(Pause), Hold) = .initFill(.{}),
    transition: ?TransitionGate = null,
    /// Presence gates: the owner waits while the path exists.
    bash_reclaim_gate_path: ?[]const u8 = null,
    retry_recovery_gate_path: ?[]const u8 = null,
    /// Fails the Output Retention queue's removals.
    retention_removal: bool = false,
    inspection_reply: Hold = .{},
    control_gate: ?ControlGate = null,
    suppress_first_control_hint: bool = false,
    phase_trace: bool = false,
    observation_fd: ?c_int = null,
    observation_state_fd: ?c_int = null,
    observation_plan: ?TestObservation.Plan = null,
    sqlite_diagnostics: bool = false,

    /// Spelled with hyphens by `--fault`.
    pub const Failure = enum {
        content_acquire,
        content_write,
        content_seal,
        content_read,
        content_import,
        before_commit,
        startup_cleanup,
        shutdown_after_accept,
        attempt_before_commit,
        result_before_commit,
        request_first_step,
        request_write,
        request_seal,
        request_scratch_acquire,
        request_read,
        request_unlink,
        provider_prepare,
        response_acquire,
        response_unlink,
        response_write,
        /// Fails the next launched Transfer's response writes, then disarms.
        response_write_once,
        response_seal,
        response_metadata,
        response_metadata_unlink,
        response_read,
        response_import,
        response_commit,
        bash_preparation,
        bash_preparation_after_captures,
        bash_spawn,
        bash_service,
        bash_capture_read,
        bash_capture_write,
        bash_seal,
        bash_cleanup,
        /// Bash faults strike only while the scratch fault gate exists.
        bash_fault_gated,
        report_unlink,
    };

    /// Where a test may hold an owner for a delay, at a gate, or both. A
    /// held launch or result is traced for the Attempt it holds.
    pub const Pause = union(enum) {
        action_launch: store_module.ActionAttemptBinding,
        model_launch: store_module.AttemptBinding,
        action_result: store_module.ActionAttemptBinding,
        model_result: store_module.AttemptBinding,
        preparation_advanced,
        bash_exit_observed,
        /// Shutdown signalled every effect; Bash grace has not been serviced.
        shutdown_signalled,
    };

    pub const Hold = struct {
        delay_ms: i64 = 0,
        gate_path: ?[]const u8 = null,
    };

    pub const Transition = enum {
        action_attempt_admitted,
        prepared_before_handoff,
        action_result_ready,
        action_result_committed,
    };

    /// Traces one Action transition and holds it at the gate.
    pub const TransitionGate = struct { transition: Transition, path: []const u8 };

    /// Holds the listed control command keys once they hold the Store.
    pub const ControlGate = struct { keys: []const u8, path: []const u8 };

    /// The Store commits a Host makes, each reached by its own failures.
    pub const StoreCommit = union(enum) {
        command,
        control: ?store_module.ControlTrace,
        attempt_admission,
        action_result,
        model_failure,
        model_output: ?store_module.SettlementTrace,
    };

    pub fn fails(self: *const Hooks, failure: Failure) bool {
        return self.failures.contains(failure);
    }

    /// The tag of `E` that test options spell with hyphens for underscores.
    pub fn fromOptionName(comptime E: type, name: []const u8) ?E {
        var buffer: [64]u8 = undefined;
        if (name.len > buffer.len or std.mem.indexOfScalar(u8, name, '_') != null) return null;
        _ = std.mem.replace(u8, name, "-", "_", buffer[0..name.len]);
        return std.meta.stringToEnum(E, buffer[0..name.len]);
    }

    /// Adds one `--fault` name: a Failure or a Bash lifecycle fault.
    pub fn inject(self: *Hooks, name: []const u8) error{UnknownFault}!void {
        if (std.mem.startsWith(u8, name, "bash-")) {
            if (fromOptionName(bash.LifecycleFault, name["bash-".len..])) |lifecycle| if (lifecycle != .none) {
                self.bash_lifecycle = lifecycle;
                return;
            };
        }
        self.failures.insert(fromOptionName(Failure, name) orelse return error.UnknownFault);
    }

    pub fn contentFaults(self: *const Hooks) protocol.ContentFaults {
        return .{
            .acquire = self.fails(.content_acquire),
            .write = self.fails(.content_write),
            .seal = self.fails(.content_seal),
        };
    }

    pub fn storeFaults(self: *const Hooks, commit: StoreCommit) store_module.Faults {
        return switch (commit) {
            .command => .{
                .content_read = self.fails(.content_read),
                .content_import = self.fails(.content_import),
                .before_commit = self.fails(.before_commit),
            },
            .control => |trace| .{ .before_commit = self.fails(.before_commit), .control_trace = trace },
            .attempt_admission => .{ .attempt_before_commit = self.fails(.attempt_before_commit) },
            .action_result => .{
                .content_import = self.fails(.content_import),
                .before_commit = self.fails(.result_before_commit),
            },
            .model_failure => .{ .before_commit = self.fails(.result_before_commit) },
            .model_output => |trace| .{
                .output_read = self.fails(.response_read),
                .output_import = self.fails(.response_import),
                .output_commit = self.fails(.response_commit),
                .settlement_trace = trace,
            },
        };
    }

    pub fn preparationFaults(self: *const Hooks) model_adapter.PreparationFaults {
        return .{
            .first_step = self.fails(.request_first_step),
            .write = self.fails(.request_write),
            .seal = self.fails(.request_seal),
            .unlink = self.fails(.request_unlink),
        };
    }

    /// `write_once_spent`: an earlier Transfer started with the one-shot
    /// response write failure, which the execution owner records.
    pub fn transferFaults(self: *const Hooks, write_once_spent: bool) provider.Faults {
        return .{
            .request_read = self.fails(.request_read),
            .response_acquire = self.fails(.response_acquire),
            .response_unlink = self.fails(.response_unlink),
            .response_write = self.fails(.response_write) or (self.fails(.response_write_once) and !write_once_spent),
        };
    }

    pub fn bashFaults(self: *const Hooks) bash.Faults {
        return .{
            .preparation = self.fails(.bash_preparation),
            .preparation_after_captures = self.fails(.bash_preparation_after_captures),
            .spawn = self.fails(.bash_spawn),
            .service = self.fails(.bash_service),
            .capture_read = self.fails(.bash_capture_read),
            .capture_write = self.fails(.bash_capture_write),
            .seal = self.fails(.bash_seal),
            .cleanup = self.fails(.bash_cleanup),
            .lifecycle = self.bash_lifecycle,
            .fault_gated = self.fails(.bash_fault_gated),
        };
    }
};

/// The execution owner's progress through the fixed Hooks, so Hooks stay
/// read-only for every thread once the Host starts.
pub const HookProgress = struct {
    /// A Transfer started with the one-shot response write failure.
    response_write_once_spent: bool = false,
    retry_recovery: enum { initial, held, released } = .initial,
};

/// How far a Host has shut down. It only moves forward, under the launch
/// gate, through `Host.advance`. `fenced` blocks new effect launches while
/// owned work, retained cleanup and intake continue. `draining` is Host
/// teardown after intake has returned: execution winds down, and a failure
/// found while it does is still reported. `stopping` stops effects: it
/// retires unhanded requests, closes the listener and winds execution down.
pub const Phase = enum(u8) { open, fenced, draining, stopping };

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    instance: protocol.InstanceId = undefined,
    hooks: Hooks = .{},
    limits: Limits = .{},
    provider_endpoint: ?[]const u8 = null,
    provider_ca_file: ?[]const u8 = null,
    authentication: ?model_adapter.Authentication = null,
    auth_worker: ?*AuthWorker = null,
    /// The scratch account every request and response of this Host
    /// charges; set by the execution owner when a provider is configured.
    scratch_budget: ?provider.ScratchBudget = null,
    /// Execution-thread-owned Codex sticky routing; in memory only.
    turn_states: model_adapter.TurnStates = .{},
    /// Execution-thread-owned history memos: an index preallocated at
    /// start, with span bytes in scratch files deleted at stop.
    history_memos: model_adapter.HistoryMemos = .{},
    /// Execution-thread-owned progress through the fixed hooks.
    hook_progress: HookProgress = .{},
    /// Execution-thread-owned, one per custody record and zero-mapped.
    bash_work: []BashWork = &.{},
    /// Execution-thread-owned count of execution slot writes; it moves on
    /// every slot change and nothing else.
    slot_changes: u64 = 0,
    bash_path: []const u8 = default_bash_path,
    bash_environment: *const std.process.Environ.Map = &bash.empty_environment,
    bash_timeout_ms: u64 = default_bash_timeout_ms,
    retention: *output_retention.Queue = undefined,
    /// The Store directory for optional failed-response records; null in
    /// owner tests that have no lease.
    failed_response_store: ?std.Io.Dir = null,
    custody: execution.CustodyPool = .{ .records = &.{} },
    phase: std.atomic.Value(Phase) = .init(.open),
    controls_changed: std.atomic.Value(bool) = .init(false),
    control_hint_suppressed: std.atomic.Value(bool) = .init(false),
    request_counter: std.atomic.Value(u64) = .init(0),
    intake_wake: ?std.posix.fd_t = null,
    intake_capacity: usize = product_defaults.intake_capacity,
    descriptor_soft_limit: ?usize = null,
    scratch_used: std.atomic.Value(u64) = .init(0),
    launch_mutex: std.Io.Mutex = .init,
    trace_run_ns: u64 = 0,
    trace_sequence: u64 = 0,
    trace_lost: std.atomic.Value(bool) = .init(false),
    test_observation: ?*TestObservation = null,
    last_unprocessed_completions: ?u64 = null,

    // Canonical permission belongs to Store; process-local permission belongs
    // to Host. The Store handoff must enter this gate, in that lock order, for
    // every effect. A preflight observation alone cannot authorize a launch.
    pub fn launchAllowed(self: *const Host) bool {
        return self.phase.load(.acquire) == .open;
    }

    pub fn stopping(self: *const Host) bool {
        return self.phase.load(.acquire) == .stopping;
    }

    pub fn executionEnding(self: *const Host) bool {
        return @backingInt(self.phase.load(.acquire)) >= @backingInt(Phase.draining);
    }

    /// Moves the Host forward to `target`, never back, and returns the
    /// phase it was in.
    pub fn advance(self: *Host, target: Phase) Phase {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        const previous = self.phase.load(.monotonic);
        if (@backingInt(target) > @backingInt(previous)) self.phase.store(target, .release);
        return previous;
    }

    pub fn withEffectLaunch(self: *Host, context: anytype, comptime launch: anytype) !void {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        if (!self.launchAllowed()) return error.HostDispatchSuppressed;
        try launch(context);
    }
};

// One Host-wide authentication I/O job: a launch lease, or one forced
// refresh after a model 401. Canonical custody remains in the execution slot
// while file locks, refresh TLS and persistence run here.
pub const AuthWorker = struct {
    io: std.Io,
    authentication: model_adapter.Authentication,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: enum { idle, requested, ready, in_use, refreshed, failed } = .idle,
    // Only .ready/.in_use own this final storage. The execution thread borrows
    // it through launch; the worker never publishes a value copy of the lease.
    credential: model_adapter.Credential = undefined,
    failure: ?anyerror = null,
    /// Set with .requested for a forced refresh at this rejected generation.
    refresh_generation: ?u64 = null,
    refresh_result: bool = false,
    stopping: bool = false,

    const Result = union(enum) { ready: *const model_adapter.Credential, refreshed: bool, failed: anyerror };

    /// Only the execution thread requests and takes, so an idle worker stays
    /// idle until that thread's next request.
    pub fn idle(self: *AuthWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .idle;
    }

    pub fn request(self: *AuthWorker) void {
        self.requestJob(null);
    }

    pub fn requestRefresh(self: *AuthWorker, generation: u64) void {
        self.requestJob(generation);
    }

    fn requestJob(self: *AuthWorker, refresh_generation: ?u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.state == .idle);
        self.refresh_generation = refresh_generation;
        self.state = .requested;
        self.condition.broadcast(self.io);
    }

    pub fn take(self: *AuthWorker) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return switch (self.state) {
            .idle, .requested, .in_use => null,
            .ready => result: {
                self.state = .in_use;
                break :result .{ .ready = &self.credential };
            },
            .refreshed => result: {
                self.state = .idle;
                break :result .{ .refreshed = self.refresh_result };
            },
            .failed => result: {
                const err = self.failure.?;
                self.failure = null;
                self.state = .idle;
                break :result .{ .failed = err };
            },
        };
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
            const refresh_generation = self.refresh_generation;
            self.refresh_generation = null;
            self.mutex.unlock(self.io);
            const refreshed: ?bool = if (refresh_generation) |generation|
                model_adapter.forceCredentialRefresh(self.io, self.authentication, generation) catch |err| {
                    self.publishFailure(err);
                    continue;
                }
            else refreshed: {
                model_adapter.acquireCredentialInto(self.io, self.authentication, &self.credential) catch |err| {
                    self.publishFailure(err);
                    continue;
                };
                break :refreshed null;
            };
            self.mutex.lockUncancelable(self.io);
            if (refreshed) |value| {
                self.refresh_result = value;
                self.state = .refreshed;
            } else self.state = .ready;
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }

    fn publishFailure(self: *AuthWorker, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failure = err;
        self.state = .failed;
        self.condition.broadcast(self.io);
    }
};

/// The Bash state too large for an execution slot, kept in its custody
/// record's entry of `Host.bash_work`: only records that ever held Bash make
/// theirs resident, and a slot stays sized for model work. The slot's arm
/// says which field is live.
pub const BashWork = union {
    execution: bash.Execution,
    prepared_cleanup: bash.PreparedCleanup,
};

/// Returns `count` items in fresh anonymous pages: every byte is zero and no
/// page is resident until first written. Allocator.alloc promises neither,
/// because ReleaseSafe fills new memory with 0xAA and an init loop writes
/// every page, so callers whose empty state is all zero bytes use this.
pub fn mapZeroed(comptime T: type, count: usize) ![]T {
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

pub fn unmapZeroed(items: anytype) void {
    if (items.len == 0) return;
    std.posix.munmap(@alignCast(std.mem.sliceAsBytes(items)));
}

pub fn fenceDispatch(host: *Host, phase: []const u8, err: anyerror) void {
    if (host.advance(.stopping) == .stopping) return;
    stderr.print("rui: dispatch fenced after {s} failure: {s}\nHost cannot safely continue; wait for shutdown before restarting this Store. Use saved request handles; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
    wakeListener(host);
}

pub fn wakeListener(host: *Host) void {
    // Coalesced hints: a full nonblocking socket is already readable.
    if (host.intake_wake) |fd| _ = std.c.write(fd, "x", 1);
}

pub fn retainDispatchFence(host: *Host, phase: []const u8, err: anyerror) void {
    _ = host.advance(.fenced);
    stderr.print("rui: dispatch fenced after {s} failure: {s}\nNew work is blocked; retained cleanup is still owned. Inspect saved requests; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
}

pub fn nowNs(host: *Host) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds);
}

pub fn beginTestObservation(host: *Host, phase: []const u8, subject: ?[]const u8) ?TestObservation.Publication {
    const writer = host.test_observation orelse return null;
    return writer.begin(phase, subject);
}

pub fn writeTestTrace(host: *Host, trace: *protocol.ResponseBuffer, publication: *?TestObservation.Publication) void {
    if (!host.hooks.phase_trace) return;
    if (publication.*) |*value| value.record(trace.slice());
    if (!stderr.tryAcquire()) {
        host.trace_lost.store(true, .release);
        return;
    }
    defer stderr.release();
    host.trace_sequence += 1;
    const original = trace.slice();
    if (original.len == 0 or original[original.len - 1] != '}') {
        host.trace_lost.store(true, .release);
        return;
    }
    var complete: protocol.ResponseBuffer = .{};
    complete.append(original[0 .. original.len - 1]) catch {
        host.trace_lost.store(true, .release);
        return;
    };
    complete.appendFmt(
        ",\"process\":\"{d}\",\"run\":\"{d}\",\"clock\":\"awake_ns\",\"sequence\":\"{d}\",\"trace_lost\":{s}}}\n",
        .{ trace_native.getpid(), host.trace_run_ns, host.trace_sequence, if (host.trace_lost.load(.acquire)) "true" else "false" },
    ) catch {
        host.trace_lost.store(true, .release);
        return;
    };
    if (!stderr.writeHeld(complete.slice())) host.trace_lost.store(true, .release);
}

pub fn traceSubject(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, subject);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"subject_kind\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(subject_kind) catch return;
    trace.append(",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceRequest(host: *Host, phase: []const u8, request_number: u64, scratch_used_bytes: ?u64) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"subject_kind\":\"request_number\",\"subject\":\"{d}\"",
        .{ nowNs(host), request_number },
    ) catch return;
    if (scratch_used_bytes) |used|
        trace.appendFmt(",\"scratch_used_bytes\":\"{d}\"", .{used}) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
}

/// Local execution facts for inspection, read from another thread than the
/// execution owner's.
pub fn executionFacts(host: *Host) store_module.SessionReportExecution {
    return .{
        .dispatch_fenced = !host.launchAllowed(),
        .custody_occupied = host.custody.held(),
        .scratch_used_bytes = host.scratch_used.load(.acquire),
    };
}

pub fn traceServiceBoundary(host: *Host, start_ns: u64, end_ns: u64, wait_ns: u64) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, "lifecycle_boundary", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_boundary\",\"at_ns\":\"{d}\",\"start_ns\":\"{d}\",\"wait_ns\":\"{d}\"}}",
        .{ end_ns, start_ns, wait_ns },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceLifecycleService(host: *Host, maximum_gap_ns: u64) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, "lifecycle_service_observation", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_service_observation\",\"at_ns\":\"{d}\",\"maximum_gap_ns\":\"{d}\",\"owner\":\"execution\"}}",
        .{ nowNs(host), maximum_gap_ns },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceOperation(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn tracePreparationAdvance(
    host: *Host,
    phase: []const u8,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn tracePreparationAdvanceError(
    host: *Host,
    phase: []const u8,
    err: anyerror,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"error\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(@errorName(err)) catch return;
    trace.appendFmt(
        ",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceCompletionQueue(host: *Host, queued_after: usize, binding: store_module.AttemptBinding) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, "provider_completion_removed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"provider_completion_removed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), queued_after, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceAction(host: *Host, phase: []const u8, binding: store_module.ActionAttemptBinding) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceOperationControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.AttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceActionControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceActionControlOutcome(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    attempted: bool,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"attempted\":{s},\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        if (attempted) "true" else "false",
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceActionDeadline(
    host: *Host,
    phase: []const u8,
    deadline_ns: u64,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"deadline_ns\":\"{d}\",\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        nowNs(host),
        deadline_ns,
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

pub fn testTransition(host: *Host, transition: Hooks.Transition, binding: store_module.ActionAttemptBinding) void {
    const gate = host.hooks.transition orelse return;
    if (gate.transition != transition) return;
    traceAction(host, @tagName(transition), binding);
    waitAtTestGate(host, gate.path);
}

/// Holds the calling owner at `point` for the test's delay and gate, if any.
pub fn pause(host: *Host, point: Hooks.Pause) void {
    const hold = host.hooks.pauses.get(point);
    if (hold.delay_ms == 0 and hold.gate_path == null) return;
    switch (point) {
        .action_launch => |binding| traceAction(host, "prepared_before_handoff", binding),
        .model_launch => |binding| traceOperation(host, "prepared_before_handoff", binding),
        .action_result => |binding| traceAction(host, "sealed_before_settlement", binding),
        .model_result => |binding| traceOperation(host, "sealed_before_settlement", binding),
        .preparation_advanced, .bash_exit_observed, .shutdown_signalled => {},
    }
    if (hold.gate_path) |path| waitAtTestGate(host, path);
    if (hold.delay_ms != 0) host.io.sleep(.fromMilliseconds(hold.delay_ms), .awake) catch {};
}

/// The retry recovery gate lets one exhausted-retry recovery run, then holds
/// later recoveries while the gate exists, never admission or the execution
/// turn. One real call first preserves the full-drain counterexample.
pub fn retryRecoveryHeld(host: *Host) bool {
    if (host.hook_progress.retry_recovery != .held) return false;
    if (testGateActive(host, host.hooks.retry_recovery_gate_path.?)) return true;
    host.hook_progress.retry_recovery = .released;
    return false;
}

pub fn retryRecovered(host: *Host) void {
    if (host.hook_progress.retry_recovery != .initial) return;
    const path = host.hooks.retry_recovery_gate_path orelse return;
    if (!testGateActive(host, path)) return;
    host.hook_progress.retry_recovery = .held;
    traceSubject(host, "exhausted_retry_recovery_held", "path", path);
}

/// The Bash reclaim gate holds closed Bash custody while the path exists.
/// Its release is one owner transition, traced once, not reclamation retry
/// history: `attempted` says whether this owner already tried to reclaim.
pub fn bashReclaimHeld(host: *Host, binding: store_module.ActionAttemptBinding, attempted: bool) bool {
    const path = host.hooks.bash_reclaim_gate_path orelse return false;
    if (testGateActive(host, path)) return true;
    if (!attempted) traceAction(host, "cleanup_release_observed", binding);
    return false;
}

pub fn waitAtTestGate(host: *Host, path: []const u8) void {
    // Release is a byte or persistent EOF after unlink/sole-writer close.
    // macOS does not broadcast EOF to all already-blocked FIFO reads. Keep
    // reads nonblocking so every waiter observes the shared release fact,
    // including an opener that resolved the name before it was unlinked.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return;
    var gate: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer gate.close(host.io);
    var release: [1]u8 = undefined;
    var waiting_traced = false;
    while (true) {
        _ = std.posix.read(fd, &release) catch |err| switch (err) {
            error.WouldBlock => {
                if (!waiting_traced) {
                    traceSubject(host, "test_gate_waiting", "path", path);
                    waiting_traced = true;
                }
                std.Io.sleep(host.io, .fromMilliseconds(10), .awake) catch return;
                continue;
            },
            else => return,
        };
        return;
    }
}

pub fn testGateActive(host: *Host, path: []const u8) bool {
    _ = host;
    // Presence gates may be FIFOs; opening must not wait for a writer during
    // the release/unlink race. No descriptor survives this synchronous probe.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return false;
    _ = std.c.close(fd);
    return true;
}

pub fn observeUnprocessedCompletions(host: *Host, reactor: *provider.Reactor) void {
    const count: u64 = reactor.finishedCount();
    if (host.last_unprocessed_completions) |previous| {
        if (previous == count) return;
    }
    host.last_unprocessed_completions = count;
    if (!host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, "native_completions_unprocessed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"native_completions_unprocessed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\"}}",
        .{ nowNs(host), count },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn appendOptionalUnsigned(
    trace: *protocol.ResponseBuffer,
    name: []const u8,
    value: ?u64,
) !void {
    try trace.appendJsonString(name);
    try trace.append(":");
    if (value) |present| {
        try trace.appendFmt("{d}", .{present});
    } else try trace.append("null");
}

fn appendOptionalSigned(
    trace: *protocol.ResponseBuffer,
    name: []const u8,
    value: ?i64,
) !void {
    try trace.appendJsonString(name);
    try trace.append(":");
    if (value) |present| {
        try trace.appendFmt("{d}", .{present});
    } else try trace.append("null");
}

/// A managed Transfer's connection reuse and request correlation, for tests.
pub fn traceCodexTransfer(host: *Host, transfer: *provider.Transfer, binding: store_module.AttemptBinding) void {
    if (host.authentication == null or !host.hooks.phase_trace) return;
    var publication = beginTestObservation(host, "codex_transfer", null);
    defer if (publication) |*value| value.finish();
    const observation = transfer.protocolObservation();
    const correlation = transfer.requestId();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(correlation, &digest, .{});
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt("{{\"rui_test_phase\":\"codex_transfer\",\"operation\":\"{d}\",\"new_connections\":{d},\"replays\":{d},\"correlation_present\":{s},\"correlation_sha256\":\"{x}\"}}", .{
        binding.operation_id,
        observation.new_connections,
        observation.replays,
        if (correlation.len != 0) "true" else "false",
        digest,
    }) catch unreachable;
    writeTestTrace(host, &trace, &publication);
}

pub fn traceSqliteDiagnostic(host: *Host, subject: []const u8) void {
    if (!host.hooks.phase_trace or !host.hooks.sqlite_diagnostics) return;
    var publication = beginTestObservation(host, "sqlite_diagnostic", subject);
    defer if (publication) |*value| value.finish();
    const value = host.store.sqliteDiagnostic();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":\"sqlite_diagnostic\",\"at_ns\":\"") catch return;
    trace.appendFmt("{d}", .{nowNs(host)}) catch return;
    trace.append("\",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append(",\"process_memory_scope\":\"SQLite process-global allocator; one Store per Host\",") catch return;
    appendOptionalUnsigned(&trace, "process_memory_current_bytes", value.process_memory_current_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "process_memory_highwater_bytes", value.process_memory_highwater_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "cache_used_bytes", value.cache_used_bytes) catch return;
    trace.append(",\"cache_used_scope\":\"connection-current approximate pager bytes\",") catch return;
    appendOptionalUnsigned(&trace, "cache_spills", value.cache_spills) catch return;
    trace.append(",\"cache_spills_scope\":\"connection cumulative mid-transaction spills\",") catch return;
    appendOptionalUnsigned(&trace, "hard_heap_limit_bytes", value.hard_heap_limit_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "page_size_bytes", value.page_size_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "cache_size_setting", value.cache_size_setting) catch return;
    trace.append(",\"cache_size_setting_scope\":\"raw PRAGMA cache_size; negative magnitude is suggested KiB, positive value is suggested pages\",") catch return;
    appendOptionalSigned(&trace, "cache_spill_threshold", value.cache_spill_threshold) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "mmap_size_bytes", value.mmap_size_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "synchronous", value.synchronous) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "temp_store", value.temp_store) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "busy_timeout_ms", value.busy_timeout_ms) catch return;
    trace.append(",\"journal_mode\":") catch return;
    if (value.journal_mode) |mode| {
        trace.appendJsonString(mode.slice()) catch return;
    } else trace.append("null") catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
}

pub const SettlementTrace = struct {
    host: *Host,
    binding: store_module.AttemptBinding,

    pub fn init(host: *Host, binding: store_module.AttemptBinding) SettlementTrace {
        return .{ .host = host, .binding = binding };
    }

    pub fn storeTrace(self: *SettlementTrace) ?store_module.SettlementTrace {
        if (!self.host.hooks.phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.SettlementTracePhase) void {
        const self: *SettlementTrace = @ptrCast(@alignCast(context));
        traceOperation(self.host, switch (phase) {
            .lock_requested => "settlement_lock_requested",
            .lock_acquired => "settlement_lock_acquired",
            .transaction_active => "settlement_transaction_active",
            .settlement_complete => "settlement_complete",
        }, self.binding);
    }
};

test "every --fault name reaches its own hook and nothing else" {
    for (std.enums.values(Hooks.Failure)) |failure| {
        var buffer: [64]u8 = undefined;
        const name = buffer[0..@tagName(failure).len];
        _ = std.mem.replace(u8, @tagName(failure), "_", "-", name);
        var hooks: Hooks = .{};
        try hooks.inject(name);
        try std.testing.expect(hooks.failures.eql(.initOne(failure)));
        try std.testing.expectEqual(bash.LifecycleFault.none, hooks.bash_lifecycle);
    }
    const lifecycles = [_]struct { []const u8, bash.LifecycleFault }{
        .{ "bash-observe", .observe },
        .{ "bash-reap", .reap },
        .{ "bash-reap-watchdog", .reap_watchdog },
        .{ "bash-group-probe", .group_probe },
        .{ "bash-tail-snapshot", .tail_snapshot },
        .{ "bash-signal", .signal },
        .{ "bash-cleanup-watchdog", .cleanup_watchdog },
    };
    for (lifecycles) |case| {
        var hooks: Hooks = .{};
        try hooks.inject(case[0]);
        try std.testing.expectEqual(case[1], hooks.bash_lifecycle);
        try std.testing.expect(hooks.failures.eql(.empty));
    }
    var hooks: Hooks = .{};
    for ([_][]const u8{ "bash-none", "none", "retention-removal", "content_acquire", "content-acquire-", "" }) |name|
        try std.testing.expectError(error.UnknownFault, hooks.inject(name));
    try std.testing.expectEqual(Hooks.Transition.action_result_committed, Hooks.fromOptionName(Hooks.Transition, "action-result-committed").?);
}

test "inspection counts held custody, not an in-flight admission reservation" {
    // The execution owner reserves before each admission probe and releases
    // when nothing is runnable. Inspection reads from another thread, so it
    // must not report that probe as a second custody beside gated cleanup.
    var records: [2]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .custody = execution.CustodyPool.initialize(&records),
    };
    const cleanup = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
    _ = try host.custody.attach(cleanup, &permit);
    try host.custody.detach(cleanup);
    const probe = host.custody.reserve().?;
    try std.testing.expectEqual(@as(usize, 1), executionFacts(&host).custody_occupied);
    // The reservation still blocks reuse and stays visible to reconciliation.
    try std.testing.expectEqual(@as(usize, 2), host.custody.occupied());
    try std.testing.expect(host.custody.reserve() == null);
    try host.custody.releaseUnused(probe);
    try std.testing.expectEqual(@as(usize, 1), executionFacts(&host).custody_occupied);
    try host.custody.cleanupComplete(cleanup);
    try std.testing.expectEqual(@as(usize, 0), executionFacts(&host).custody_occupied);
}

test "required Bash observations publish while optional stderr custody is held" {
    const native = @import("posix");
    inline for (.{ TestObservation.Plan.bash_cleanup, TestObservation.Plan.bash_pipes }) |plan| {
        var descriptors: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
        defer _ = native.close(descriptors[0]);
        for (descriptors) |fd| {
            try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
        }
        const backing = native.tmpfile() orelse return error.TestUnexpectedResult;
        defer _ = native.fclose(backing);
        try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(native.fileno(backing), TestObservation.state_bytes));
        var observation = try TestObservation.init(descriptors[1], native.dup(native.fileno(backing)), plan, 37);
        defer observation.close();
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .hooks = .{ .phase_trace = true },
            .test_observation = &observation,
        };
        try std.testing.expect(stderr.tryAcquire());
        defer stderr.release();
        var count: u64 = 0;
        inline for (.{ "cleanup_started", "cleanup_release_observed", "cleanup_completed", "inspection_captured", "bash_leader_observed_with_open_pipes", "control_store_complete" }) |phase| {
            if (std.mem.eql(u8, phase, "inspection_captured") or std.mem.eql(u8, phase, "control_store_complete")) {
                traceSubject(&host, phase, "command_key", "required");
            } else {
                traceAction(&host, phase, .{ .turn_id = 1, .parent_operation_id = 2, .action_id = 3 });
            }
            const selected = if (plan == .bash_cleanup)
                std.mem.startsWith(u8, phase, "cleanup_") or std.mem.eql(u8, phase, "inspection_captured")
            else
                std.mem.eql(u8, phase, "bash_leader_observed_with_open_pipes") or std.mem.eql(u8, phase, "control_store_complete");
            var bytes: [TestObservation.record_bytes]u8 = undefined;
            const length = native.read(descriptors[0], &bytes, bytes.len);
            if (selected) {
                count += 1;
                try std.testing.expect(length >= 28);
                const frame = bytes[0..@intCast(length)];
                try std.testing.expectEqual(@as(u8, 0), frame[3]);
                try std.testing.expectEqual(count, std.mem.readInt(u64, frame[4..12], .little));
                try std.testing.expect(std.mem.indexOf(u8, frame, phase) != null);
            } else {
                try std.testing.expectEqual(@as(isize, -1), length);
            }
            try std.testing.expectEqual(count * 2, observation.shared.state.load(.acquire));
            try std.testing.expectEqual(@as(u64, 0), observation.shared.active.load(.acquire));
        }
        try std.testing.expect(host.trace_lost.load(.acquire));
    }
}

test "effect launch gate rechecks every Host phase" {
    const Launch = struct {
        fn run(calls: *usize) !void {
            calls.* += 1;
        }
    };
    for (std.enums.values(Phase)) |phase| {
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
        };
        // The preflight result is deliberately stale before the real gate.
        try std.testing.expect(host.launchAllowed());
        _ = host.advance(phase);
        var calls: usize = 0;
        if (phase == .open) {
            try host.withEffectLaunch(&calls, Launch.run);
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectError(error.HostDispatchSuppressed, host.withEffectLaunch(&calls, Launch.run));
            try std.testing.expectEqual(@as(usize, 0), calls);
        }
    }
}

test "Host phases only move forward" {
    for (std.enums.values(Phase)) |start| {
        for (std.enums.values(Phase)) |target| {
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = undefined,
            };
            try std.testing.expectEqual(Phase.open, host.advance(start));
            try std.testing.expectEqual(start, host.advance(target));
            const later = if (@backingInt(target) > @backingInt(start)) target else start;
            try std.testing.expectEqual(later, host.phase.load(.acquire));
            try std.testing.expectEqual(later == .open, host.launchAllowed());
            try std.testing.expectEqual(later == .stopping, host.stopping());
            try std.testing.expectEqual(later == .draining or later == .stopping, host.executionEnding());
        }
    }
}

test "effect launch gate releases its mutex after native failure" {
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
    };
    const Launch = struct {
        fn fail(calls: *usize) !void {
            calls.* += 1;
            return error.TestLaunchFailure;
        }

        fn succeed(calls: *usize) !void {
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    try std.testing.expectError(error.TestLaunchFailure, host.withEffectLaunch(&calls, Launch.fail));
    try host.withEffectLaunch(&calls, Launch.succeed);
    try std.testing.expectEqual(@as(usize, 2), calls);
}
