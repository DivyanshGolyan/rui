const std = @import("std");
const test_pause = @import("testing/pause.zig");
const cli_grammar = @import("cli_grammar.zig");
const serve_grammar = @import("serve_grammar.zig");
const core_tools = @import("core_tools.zig");
const TestObservation = @import("TestObservation.zig");
const HostDiagnostics = @import("HostDiagnostics.zig");
const trace_native = @import("posix");
const bash = @import("bash.zig");
const environment = @import("environment.zig");
const SessionEnvironments = @import("SessionEnvironments.zig");
const execution = @import("execution.zig");
const model_adapter = @import("model_adapter.zig");
const model_list = @import("model_list.zig");
const signal_stack = @import("signal_stack.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const product_defaults = @import("product_defaults.zig");
const provider = @import("provider.zig");
const providers_module = @import("providers.zig");
const turn_states_module = @import("turn_states.zig");
const protocol = @import("protocol.zig");
const settings_handoff = @import("host_settings_handoff.zig");
const wire_request = @import("wire_request.zig");
const retry_policy = @import("retry_policy.zig");
const store_module = @import("store.zig");
const session_report = @import("session_report.zig");
const stderr = @import("stderr.zig");
const host_drain = @import("host_drain.zig");
const host_settings = @import("host_settings.zig");
const child_exit_wake = @import("child_exit_wake.zig");
const server_mcp_relist = @import("server_mcp_relist.zig");

pub const default_bash_timeout_ms = @import("host_settings.zig").default_bash_timeout_ms;
pub const default_bash_path = @import("host_settings.zig").default_bash_path;
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const default_retention_entry_capacity = @import("retention_capacity.zig").entries;
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

pub const Hooks = struct {
    failures: std.EnumSet(Failure) = .empty,
    bash_lifecycle: bash.LifecycleFault = .none,
    pauses: std.EnumArray(std.meta.Tag(Pause), Hold) = .initFill(.{}),
    bash_reclaim_gate_path: ?[]const u8 = null,
    retry_recovery_gate_path: ?[]const u8 = null,
    retention_removal: bool = false,
    inspection_reply: Hold = .{},
    control_gate: ?ControlGate = null,
    suppress_first_control_hint: bool = false,
    phase_trace: bool = false,
    pause_fd: if (test_pause.enabled) ?c_int else void = if (test_pause.enabled) null else {},
    observation_fd: ?c_int = null,
    observation_state_fd: ?c_int = null,
    observation_plan: ?TestObservation.Plan = null,
    sqlite_diagnostics: bool = false,

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
        bash_arguments,
        bash_service,
        bash_capture_read,
        bash_capture_write,
        bash_seal,
        bash_cleanup,
        bash_fault_gated,
        report_unlink,
    };

    pub const Pause = union(enum) {
        action_launch: store_module.ActionAttemptBinding,
        model_launch: store_module.AttemptBinding,
        action_result: store_module.ActionAttemptBinding,
        model_result: store_module.AttemptBinding,
    };

    pub const Hold = struct {
        delay_ms: i64 = 0,
        gate_path: ?[]const u8 = null,
    };

    pub const ControlGate = struct { keys: []const u8, path: []const u8 };

    pub const StoreCommit = union(enum) {
        command,
        control: ?store_module.ControlTrace,
        attempt_admission,
        action_result,
        model_failure,
        model_output: ?store_module.SettlementTrace,
    };

    pub fn fromOptionName(comptime E: type, name: []const u8) ?E {
        var buffer: [64]u8 = undefined;
        if (name.len > buffer.len or std.mem.indexOfScalar(u8, name, '_') != null) return null;
        _ = std.mem.replace(u8, name, "-", "_", buffer[0..name.len]);
        return std.meta.stringToEnum(E, buffer[0..name.len]);
    }

    pub fn inject(self: *Hooks, name: []const u8) error{UnknownFault}!void {
        if (std.mem.startsWith(u8, name, "bash-")) {
            if (fromOptionName(bash.LifecycleFault, name["bash-".len..])) |lifecycle| if (lifecycle != .none) {
                self.bash_lifecycle = lifecycle;
                return;
            };
        }
        self.failures.insert(fromOptionName(Failure, name) orelse return error.UnknownFault);
    }
};

pub const Tuning = struct {
    /// A directory already admitted together with private frozen placement.
    admitted_directory: ?[]const u8 = null,
    /// Digest of the admitted settings frame, with `admitted_directory`.
    settings_digest: ?settings_handoff.Digest = null,
    home: ?[]const u8 = null,
    limits: Limits = .{},
    hooks: Hooks = .{},

    pub fn fromOptions(parsed: *const cli_grammar.Parsed) !Tuning {
        var tuning: Tuning = .{};
        const limits = &tuning.limits;
        const hooks = &tuning.hooks;
        if (try parsed.number(u64, "test-bash-scratch-limit-bytes")) |limit| limits.bash_scratch_limit_bytes = limit;
        limits.retention_entry_capacity = try parsed.number(usize, "test-retention-entry-capacity");
        if (parsed.has("test-retention-removal-failure")) hooks.retention_removal = true;
        for (parsed.all("fault")) |fault| try hooks.inject(fault);
        if (try parsed.number(i64, "test-provider-inactivity-seconds")) |seconds| limits.provider_inactivity_seconds = seconds;
        if (parsed.get("test-retry-waits-ms")) |waits| limits.retry_waits_ms = try parseRetryWaits(waits);
        if (try parsed.number(i64, "test-before-launch-delay-ms")) |delay| {
            hooks.pauses.getPtr(.action_launch).delay_ms = delay;
            hooks.pauses.getPtr(.model_launch).delay_ms = delay;
        }
        if (try parsed.number(i64, "test-before-result-delay-ms")) |delay| {
            hooks.pauses.getPtr(.action_result).delay_ms = delay;
            hooks.pauses.getPtr(.model_result).delay_ms = delay;
        }
        hooks.retry_recovery_gate_path = parsed.get("test-retry-recovery-gate-path");
        hooks.inspection_reply.gate_path = parsed.get("test-inspection-reply-gate-path");
        if (try parsed.number(i64, "test-inspection-reply-delay-ms")) |delay| hooks.inspection_reply.delay_ms = delay;
        limits.client_send_buffer_bytes = try parsed.number(u32, "test-client-send-buffer-bytes");
        if (parsed.has("test-phase-trace")) hooks.phase_trace = true;
        if (comptime test_pause.enabled) hooks.pause_fd = try parsed.number(c_int, "test-pause-fd");
        if (try parsed.number(c_int, "test-observation-fd")) |fd| {
            hooks.observation_fd = fd;
            hooks.phase_trace = true;
        }
        if (try parsed.number(c_int, "test-observation-state-fd")) |fd| hooks.observation_state_fd = fd;
        if (parsed.get("test-observation-plan")) |plan| hooks.observation_plan = std.meta.stringToEnum(TestObservation.Plan, plan) orelse
            return error.InvalidTestObservationPlan;
        hooks.bash_reclaim_gate_path = parsed.get("test-bash-cleanup-gate-path");
        const control_gate_keys = parsed.get("test-control-gate-keys");
        const control_gate_path = parsed.get("test-control-gate-path");
        if (parsed.has("test-suppress-first-control-hint")) hooks.suppress_first_control_hint = true;
        if (parsed.has("test-sqlite-diagnostics")) hooks.sqlite_diagnostics = true;
        if (parsed.has("test-sqlite-cache-spill-off")) limits.sqlite_cache_spill = false;
        if (try parsed.number(u32, "test-sqlite-cache-kib")) |kib| limits.sqlite_cache_kib = kib;
        if (try parsed.number(u64, "test-request-scratch-limit")) |limit| limits.request_scratch_limit_bytes = limit;
        if (try parsed.number(usize, "test-request-preparation-byte-allowance")) |allowance| limits.request_preparation_byte_allowance = allowance;
        if (try parsed.number(usize, "test-request-preparation-item-allowance")) |allowance| limits.request_preparation_item_allowance = allowance;
        if ((control_gate_keys == null) != (control_gate_path == null)) return error.IncompleteControlGate;
        if (control_gate_keys) |keys| hooks.control_gate = .{ .keys = keys, .path = control_gate_path.? };
        return tuning;
    }
};

fn parseRetryWaits(value: []const u8) !retry_policy.Waits {
    var waits: retry_policy.Waits = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&waits) |*wait| {
        const part = parts.next() orelse return error.InvalidRetryWaits;
        wait.* = std.fmt.parseInt(u64, part, 10) catch return error.InvalidRetryWaits;
    }
    if (parts.next() != null) return error.InvalidRetryWaits;
    retry_policy.validateWaits(waits, 0) catch return error.InvalidRetryWaits;
    return waits;
}

fn tuningFor(args: []const []const u8) !Tuning {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var refusal: cli_grammar.Refusal = undefined;
    const parsed = try serve_grammar.definition.parse(args, fixed.allocator(), &refusal);
    return Tuning.fromOptions(&parsed);
}

test "the hidden serve options narrow a Host" {
    const plain = try tuningFor(&.{});
    try std.testing.expectEqual(scratch_limit_bytes, plain.limits.bash_scratch_limit_bytes);
    try std.testing.expectEqual(@as(?usize, null), plain.limits.retention_entry_capacity);
    try std.testing.expect(!plain.hooks.phase_trace and plain.hooks.control_gate == null);

    try std.testing.expectEqual(@as(?usize, 2), (try tuningFor(&.{ "--test-retention-entry-capacity", "2" })).limits.retention_entry_capacity);
    try std.testing.expectError(error.InvalidOptionValue, tuningFor(&.{ "--test-retention-entry-capacity", "1" }));
    try std.testing.expectError(error.InvalidOptionValue, tuningFor(&.{ "--test-before-launch-delay-ms", "10001" }));
    try std.testing.expectError(error.InvalidOptionValue, tuningFor(&.{ "--test-provider-inactivity-seconds", "0" }));
    try std.testing.expectError(error.InvalidOptionValue, tuningFor(&.{ "--test-request-preparation-byte-allowance", "0" }));
    const held = try tuningFor(&.{ "--test-before-launch-delay-ms", "10000", "--test-before-result-delay-ms", "5" });
    try std.testing.expectEqual(@as(i64, 10_000), held.hooks.pauses.get(.action_launch).delay_ms);
    try std.testing.expectEqual(@as(i64, 10_000), held.hooks.pauses.get(.model_launch).delay_ms);
    try std.testing.expectEqual(@as(i64, 5), held.hooks.pauses.get(.action_result).delay_ms);
    try std.testing.expectEqual(@as(i64, 5), held.hooks.pauses.get(.model_result).delay_ms);
    try std.testing.expectError(error.InvalidRetryWaits, tuningFor(&.{ "--test-retry-waits-ms", "1,2" }));

    try std.testing.expectError(error.IncompleteControlGate, tuningFor(&.{ "--test-control-gate-keys", "k" }));
    try std.testing.expectError(error.IncompleteControlGate, tuningFor(&.{ "--test-control-gate-path", "/g" }));
    const gated = try tuningFor(&.{ "--test-control-gate-keys", "k", "--test-control-gate-path", "/g" });
    try std.testing.expectEqualStrings("/g", gated.hooks.control_gate.?.path);

    try std.testing.expect((try tuningFor(&.{ "--test-observation-fd", "3" })).hooks.phase_trace);
}

pub const HookProgress = struct {
    response_write_once_spent: bool = false,
    retry_recovery: enum { initial, held, released } = .initial,
};

pub const Phase = enum(u8) { open, fenced, ending, stopping };

pub const Lifecycle = struct {
    io: std.Io,
    /// Null only in tests that never stop the Host.
    lease: *platform.StoreLease,
    phase: std.atomic.Value(Phase) = .init(.open),
    controls_changed: std.atomic.Value(bool) = .init(false),
    /// The operator's hold on new Turns (host-pause). Read the hold in force
    /// through `turnsHeld`, never this flag alone.
    turns_paused: std.atomic.Value(bool) = .init(false),
    /// A draining pause's deadline on the awake clock; 0 means none. Written
    /// only by `askStop` under `launch_mutex`; it only ever moves earlier.
    drain_until_ns: std.atomic.Value(u64) = .init(0),
    dispatch_wake: std.Io.Event = .unset,
    intake_wake: ?std.posix.fd_t = null,
    launch_mutex: std.Io.Mutex = .init,
    /// Attached after readiness, when the Host's stderr may be /dev/null; launch_mutex guards writes.
    diagnostics: ?*HostDiagnostics = null,

    pub fn init(io: std.Io, lease: *platform.StoreLease, paused: bool, intake_wake: ?std.posix.fd_t) Lifecycle {
        return .{ .io = io, .lease = lease, .turns_paused = .init(paused), .intake_wake = intake_wake };
    }

    pub fn launchAllowed(self: *const Lifecycle) bool {
        return self.phase.load(.acquire) == .open;
    }

    pub fn stopping(self: *const Lifecycle) bool {
        return self.phase.load(.acquire) == .stopping;
    }

    pub fn executionEnding(self: *const Lifecycle) bool {
        return @backingInt(self.phase.load(.acquire)) >= @backingInt(Phase.ending);
    }

    pub fn advance(self: *Lifecycle, target: Phase) Phase {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        const previous = self.phase.load(.monotonic);
        if (@backingInt(target) > @backingInt(previous)) self.phase.store(target, .release);
        return previous;
    }

    /// Advances like `advance`, and records the reason when this call made the transition.
    pub fn fence(self: *Lifecycle, target: Phase, phase: []const u8, err: anyerror) Phase {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        const previous = self.phase.load(.monotonic);
        if (@backingInt(target) <= @backingInt(previous)) return previous;
        self.phase.store(target, .release);
        if (self.diagnostics) |writer| writer.recordAs(@tagName(target), phase, @errorName(err));
        return previous;
    }

    pub fn attachDiagnostics(self: *Lifecycle, writer: *HostDiagnostics) void {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        self.diagnostics = writer;
    }

    /// The hold on new Turns in force: the operator's hold or a drain.
    pub fn turnsHeld(self: *const Lifecycle) bool {
        return self.turns_paused.load(.acquire) or self.drain_until_ns.load(.acquire) != 0;
    }

    pub fn drainUntil(self: *const Lifecycle) ?u64 {
        const until = self.drain_until_ns.load(.acquire);
        return if (until == 0) null else until;
    }

    /// A plain stop. True when this call moved the Host to stopping.
    pub fn stopAsked(self: *Lifecycle) bool {
        return self.askStop(.immediate) == .stop_now;
    }

    /// The one door every stop enters: a plain stop, a signal, stdin closing
    /// and a draining pause. The stop record is written inside the lock, so
    /// its order matches the order of decisions.
    pub fn askStop(self: *Lifecycle, bound: host_drain.Bound) host_drain.Ask {
        const answer = blk: {
            self.launch_mutex.lockUncancelable(self.io);
            defer self.launch_mutex.unlock(self.io);
            const phase: host_drain.PhaseView = switch (self.phase.load(.monotonic)) {
                .open => .open,
                .fenced => .fenced,
                .ending => .ending,
                .stopping => .stopping,
            };
            const current = self.drainUntil();
            const answer = host_drain.ask(phase, current, bound, nowNs(self.io));
            switch (answer) {
                .already_stopping => {},
                .stop_now => {
                    self.phase.store(.stopping, .release);
                    self.recordStop(if (current == null) .asked else .superseded);
                },
                .drain => |drain| if (drain.changed) {
                    self.drain_until_ns.store(drain.until_ns, .release);
                    if (current == null) self.recordStop(.draining);
                },
            }
            break :blk answer;
        };
        if (answer == .drain and answer.drain.changed) self.dispatch_wake.set(self.io);
        return answer;
    }

    /// Ends a drain the execution owner judged over. False when a plain stop
    /// already ended the Host.
    pub fn finishDrain(self: *Lifecycle, outcome: host_drain.Outcome) bool {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        if (@backingInt(self.phase.load(.monotonic)) >= @backingInt(Phase.stopping)) return false;
        self.phase.store(.stopping, .release);
        self.recordStop(host_drain.Record.of(outcome));
        return true;
    }

    fn recordStop(self: *Lifecycle, record: host_drain.Record) void {
        self.lease.recordStop(record.text()) catch |err| stderr.print("rui: stop record not written: {s}\n", .{@errorName(err)});
    }

    pub fn withEffectLaunch(self: *Lifecycle, context: anytype, comptime launch: anytype) !void {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        if (!self.launchAllowed()) return error.HostDispatchSuppressed;
        try launch(context);
    }

    pub fn fenceDispatch(self: *Lifecycle, phase: []const u8, err: anyerror) void {
        if (self.fence(.stopping, phase, err) == .stopping) return;
        stderr.print("rui: dispatch fenced after {s} failure: {s}\nHost cannot safely continue; wait for shutdown before restarting this Store. Use saved request handles; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
        self.wakeListener();
    }

    pub fn retainDispatchFence(self: *Lifecycle, phase: []const u8, err: anyerror) void {
        _ = self.fence(.fenced, phase, err);
        stderr.print("rui: dispatch fenced after {s} failure: {s}\nNew work is blocked; retained cleanup is still owned. Inspect saved requests; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
    }

    pub fn wakeListener(self: *Lifecycle) void {
        if (self.intake_wake) |fd| _ = std.c.write(fd, "x", 1);
    }

    pub fn noteControlsChanged(self: *Lifecycle) void {
        self.controls_changed.store(true, .release);
    }

    pub fn takeControlsChanged(self: *Lifecycle) bool {
        return self.controls_changed.swap(false, .acq_rel);
    }

    pub fn controlsChangedPending(self: *const Lifecycle) bool {
        return self.controls_changed.load(.acquire);
    }

    pub fn setTurnsPaused(self: *Lifecycle, paused: bool) void {
        self.turns_paused.store(paused, .release);
    }

    pub fn wakeDispatch(self: *Lifecycle) void {
        self.dispatch_wake.set(self.io);
    }

    pub fn resetDispatchWake(self: *Lifecycle) void {
        self.dispatch_wake.reset();
    }

    pub fn dispatchWakeIsSet(self: *Lifecycle) bool {
        return self.dispatch_wake.isSet();
    }

    pub fn awaitDispatchWake(self: *Lifecycle, timeout_ms: u32) void {
        self.dispatch_wake.waitTimeout(self.io, .{ .duration = .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }) catch {};
    }

    pub fn childExitWake(self: *Lifecycle) child_exit_wake.Wake {
        return .{ .event = &self.dispatch_wake, .io = self.io };
    }

    pub fn connectDispatchWake(self: *Lifecycle, reactor: ?*provider.Reactor, store: *store_module.Store) void {
        if (reactor) |active| active.wake = &self.dispatch_wake;
        store.commitWake().store(&self.dispatch_wake, .release);
    }

    /// Runs `open`, which creates a descriptor that is not yet close-on-exec, with
    /// effect launches held off, so no child launched meanwhile inherits it.
    pub fn openUninherited(self: *Lifecycle, context: anytype, comptime open: anytype) @TypeOf(open(context)) {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        return open(context);
    }

    /// Runs `hand_off` with whether the Host is stopping, ordered against askStop:
    /// a stop asked before the lock is seen, and one asked after waits for the hand-off.
    pub fn handOff(self: *Lifecycle, context: anytype, comptime hand_off: anytype) @TypeOf(hand_off(context, false)) {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        return hand_off(context, self.stopping());
    }
};

/// The test probes and phase tracing of a served Host: injected faults and holds, the pause owner, the trace
/// sequence and the observation writer. Host reaches it through `probes`, which serveOpened (or TestParts.attach
/// in tests) sets before any Host method that reads it runs. Code outside Probes reads its plain fields only;
/// everything else goes through a method here.
pub const Probes = struct {
    hooks: Hooks = .{},
    pause_owner: if (test_pause.enabled) ?*test_pause.PauseController else void = if (test_pause.enabled) null else {},
    hook_progress: HookProgress = .{},
    trace_run_ns: u64 = 0,
    trace_sequence: u64 = 0,
    trace_lost: std.atomic.Value(bool) = .init(false),
    observation: ?TestObservation = null,
    control_hint_suppressed: std.atomic.Value(bool) = .init(false),
    last_unprocessed_completions: ?u64 = null,

    pub fn init(io: std.Io, hooks: Hooks) Probes {
        return .{ .hooks = hooks, .trace_run_ns = nowNs(io) };
    }

    pub fn attachPauseOwner(self: *Probes, owner: *test_pause.PauseController) void {
        if (comptime test_pause.enabled) self.pause_owner = owner;
    }

    /// Opens the observation writer that the harness's fds name, if it names one.
    pub fn openObservation(self: *Probes) !void {
        const fd = self.hooks.observation_fd orelse return;
        self.observation = try TestObservation.init(
            fd,
            self.hooks.observation_state_fd orelse return error.MissingTestObservationState,
            self.hooks.observation_plan orelse return error.MissingTestObservationPlan,
            self.trace_run_ns,
        );
    }

    pub fn closeObservation(self: *Probes) void {
        if (self.observation) |*writer| writer.close();
    }

    /// Arms `failure` at run time, for a commit or write that has not been reached yet.
    pub fn arm(self: *Probes, failure: Hooks.Failure) void {
        self.hooks.failures.insert(failure);
    }

    pub fn fails(self: *const Probes, failure: Hooks.Failure) bool {
        return self.hooks.failures.contains(failure);
    }

    pub fn contentFaults(self: *const Probes) wire_request.ContentFaults {
        return .{
            .acquire = self.fails(.content_acquire),
            .write = self.fails(.content_write),
            .seal = self.fails(.content_seal),
        };
    }

    pub fn storeFaults(self: *const Probes, commit: Hooks.StoreCommit) store_module.Faults {
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

    pub fn preparationFaults(self: *const Probes) model_adapter.PreparationFaults {
        return .{
            .first_step = self.fails(.request_first_step),
            .write = self.fails(.request_write),
            .seal = self.fails(.request_seal),
            .unlink = self.fails(.request_unlink),
        };
    }

    /// The transfer faults for the next provider request: a response write-once fault applies until a transfer has started.
    pub fn transferFaults(self: *const Probes) provider.Faults {
        const write_once_spent = self.hook_progress.response_write_once_spent;
        return .{
            .request_read = self.fails(.request_read),
            .response_acquire = self.fails(.response_acquire),
            .response_unlink = self.fails(.response_unlink),
            .response_write = self.fails(.response_write) or (self.fails(.response_write_once) and !write_once_spent),
        };
    }

    pub fn bashFaults(self: *const Probes) bash.Faults {
        return .{
            .preparation = self.fails(.bash_preparation),
            .preparation_after_captures = self.fails(.bash_preparation_after_captures),
            .spawn = self.fails(.bash_spawn),
            .arguments = self.fails(.bash_arguments),
            .service = self.fails(.bash_service),
            .capture_read = self.fails(.bash_capture_read),
            .capture_write = self.fails(.bash_capture_write),
            .seal = self.fails(.bash_seal),
            .cleanup = self.fails(.bash_cleanup),
            .lifecycle = self.hooks.bash_lifecycle,
            .fault_gated = self.fails(.bash_fault_gated),
        };
    }

    /// Records that the transfer whose faults were just read has started, which spends a response write-once fault.
    pub fn noteTransferStarted(self: *Probes) void {
        self.hook_progress.response_write_once_spent = self.fails(.response_write_once);
    }

    /// Begins a test observation for `phase`, or returns null when none is attached.
    pub fn beginObservation(self: *Probes, phase: []const u8, subject: ?[]const u8) ?TestObservation.Publication {
        const writer = if (self.observation) |*value| value else return null;
        return writer.begin(phase, subject);
    }

    /// Writes one completed trace line to stderr, with the run, the sequence and whether lines were lost.
    pub fn writeTrace(self: *Probes, trace: *protocol.DiagnosticBuffer, publication: *?TestObservation.Publication) void {
        if (!self.hooks.phase_trace) return;
        if (publication.*) |*value| value.record(trace.slice());
        if (!stderr.tryAcquire()) {
            self.trace_lost.store(true, .release);
            return;
        }
        defer stderr.release();
        self.trace_sequence += 1;
        const original = trace.slice();
        if (original.len == 0 or original[original.len - 1] != '}') {
            self.trace_lost.store(true, .release);
            return;
        }
        trace.len -= 1;
        trace.appendFmt(
            ",\"process\":\"{d}\",\"run\":\"{d}\",\"clock\":\"awake_ns\",\"sequence\":\"{d}\",\"trace_lost\":{s}}}\n",
            .{ trace_native.getpid(), self.trace_run_ns, self.trace_sequence, if (self.trace_lost.load(.acquire)) "true" else "false" },
        ) catch {
            self.trace_lost.store(true, .release);
            return;
        };
        if (!stderr.writeHeld(trace.slice())) self.trace_lost.store(true, .release);
    }

    /// Notes the completions still queued after a reactor pass; false when the count repeats the last pass.
    pub fn noteUnprocessedCompletions(self: *Probes, count: u64) bool {
        if (self.last_unprocessed_completions) |previous| {
            if (previous == count) return false;
        }
        self.last_unprocessed_completions = count;
        return true;
    }

    /// Whether this is the first control hint and the harness suppresses it; later hints are never suppressed.
    pub fn suppressFirstControlHint(self: *Probes) bool {
        return self.hooks.suppress_first_control_hint and !self.control_hint_suppressed.swap(true, .acq_rel);
    }

    /// Holds retry recovery at its gate, returning the gate path when this call took the hold.
    pub fn holdRetryRecovery(self: *Probes) ?[]const u8 {
        if (self.hook_progress.retry_recovery != .initial) return null;
        const path = self.hooks.retry_recovery_gate_path orelse return null;
        if (!testGateActive(path)) return null;
        self.hook_progress.retry_recovery = .held;
        return path;
    }

    /// Whether a held retry recovery still waits at its gate; once the gate is gone, the hold is released.
    pub fn releaseRetryRecovery(self: *Probes) bool {
        if (self.hook_progress.retry_recovery != .held) return false;
        if (testGateActive(self.hooks.retry_recovery_gate_path.?)) return true;
        self.hook_progress.retry_recovery = .released;
        return false;
    }

    /// Whether the bash cleanup gate is present; null when no cleanup gate is configured.
    pub fn bashReclaimGatePresent(self: *const Probes) ?bool {
        const path = self.hooks.bash_reclaim_gate_path orelse return null;
        return testGateActive(path);
    }

    /// The delay a test hold adds at `point`, 0 when none is configured.
    pub fn pauseDelayMs(self: *const Probes, point: Hooks.Pause) i64 {
        return self.hooks.pauses.get(point).delay_ms;
    }
};

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    lifecycle: *Lifecycle = undefined,
    /// Set by serveOpened, or by TestParts.attach in tests, before any Host method that reads probes runs.
    probes: *Probes = undefined,
    instance: protocol.InstanceId = undefined,
    limits: Limits = .{},
    providers: *const providers_module.Providers = &providers_module.none,
    catalog_url: ?[]const u8 = null,
    presets: []const core_tools.Preset = &.{},
    model_lists: ModelLists = .{},
    listings_requested: std.atomic.Value(bool) = .init(false),
    auth_worker: ?*AuthWorker = null,
    scratch_budget: ?provider.ScratchBudget = null,
    turn_states: turn_states_module.PerProvider = .{},
    history_memos: model_adapter.HistoryMemos = .{},
    bash_work: []BashWork = &.{},
    slot_changes: u64 = 0,
    bash_path: []const u8 = default_bash_path,
    bash_facts: environment.HostFacts = bash.default_facts,
    environments: ?*SessionEnvironments = null,
    bash_timeout_ms: u64 = default_bash_timeout_ms,
    background_after_ms: u64 = @import("host_settings.zig").default_background_after_ms,
    mcp_servers: @import("mcp/servers.zig").Servers = .{},
    /// The owner of MCP re-lists; null when no MCP server is configured.
    mcp_relist: ?*@import("server_mcp_relist.zig").Relist = null,
    retention: *output_retention.Queue = undefined,
    failed_response_store: ?std.Io.Dir = null,
    custody: execution.CustodyPool = .{ .records = &.{} },
    request_counter: std.atomic.Value(u64) = .init(0),
    intake_capacity: usize = product_defaults.intake_capacity,
    descriptor_soft_limit: ?usize = null,
    scratch_used: std.atomic.Value(u64) = .init(0),
    started_at: u64 = 0,
    /// The frozen settings frame a detached Host was started with; null for a foreground Host.
    settings_digest: ?settings_handoff.Digest = null,
};

pub const ModelLists = struct {
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    providers: *const providers_module.Providers = &providers_module.none,
    mutex: std.Io.Mutex = .init,
    live: std.EnumArray(protocol.Provider, model_list.List) = .initFill(.catalog),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, providers: *const providers_module.Providers) ModelLists {
        var lists: ModelLists = .{ .io = io, .allocator = allocator, .providers = providers };
        for (std.enums.values(protocol.Provider)) |name| {
            if (providers.liveList(name) != null) lists.live.set(name, .pending);
        }
        return lists;
    }

    pub fn deinit(self: *ModelLists) void {
        for (self.live.values) |list| switch (list) {
            .live => |ids| self.allocator.free(ids.bytes),
            .catalog, .pending, .catalog_fallback => {},
        };
        self.* = .{};
    }

    pub fn set(self: *ModelLists, name: protocol.Provider, list: model_list.List) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.live.get(name)) {
            .live => |ids| self.allocator.free(ids.bytes),
            else => {},
        }
        self.live.set(name, list);
    }

    pub fn publish(self: *ModelLists, name: protocol.Provider, body: anyerror![]const u8) void {
        const listing = self.providers.liveList(name).?.credential.listing().?;
        const list: model_list.List = if (keep(self.allocator, listing, body)) |bytes| .{ .live = .{ .bytes = bytes } } else |err| failed: {
            stderr.print("rui: {s} model list unavailable ({s}); the picker shows Rui's models\n", .{ name.shown(), @errorName(err) });
            break :failed .catalog_fallback;
        };
        self.set(name, list);
    }

    noinline fn keep(allocator: std.mem.Allocator, listing: providers_module.Listing, body: anyerror![]const u8) ![]const u8 {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const ids = try arena.allocator().create(model_list.IdBuffer);
        const parsed = try listing.parse(arena.allocator(), try body, ids);
        return allocator.dupe(u8, parsed.bytes);
    }

    pub fn render(self: *ModelLists, out: *std.Io.Writer, facts: []const @import("model_catalog.zig").Entry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var entries: [std.enums.values(protocol.Provider).len]model_list.Entry = undefined;
        var count: usize = 0;
        for (std.enums.values(protocol.Provider)) |name| {
            if (!self.providers.serves(name)) continue;
            entries[count] = .{ .provider = name, .list = self.live.get(name) };
            count += 1;
        }
        try model_list.writeProviders(out, facts, entries[0..count]);
    }
};

pub const AuthWorker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: State = .idle,
    credential: providers_module.Lease = undefined,
    work: providers_module.Work = undefined,
    stopping: bool = false,

    const Job = union(enum) { acquire: providers_module.Authentication, refresh: providers_module.Credential.Refresh };
    const State = union(enum) { idle, requested: Job, ready, in_use, refreshed: bool, failed: anyerror };
    const Result = union(enum) { ready: *const providers_module.Lease, refreshed: bool, failed: anyerror };

    pub fn idle(self: *AuthWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .idle;
    }

    pub fn request(self: *AuthWorker, source: providers_module.Authentication) void {
        self.requestJob(.{ .acquire = source });
    }

    pub fn requestRefresh(self: *AuthWorker, refresh: providers_module.Credential.Refresh) void {
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
                .acquire => |source| if (providers_module.acquire(source, self.io, &self.work, &self.credential)) |_| .ready else |err| .{ .failed = err },
                .refresh => |refresh| if (providers_module.refresh(refresh.source, self.io, refresh.generation)) |refreshed| .{ .refreshed = refreshed } else |err| .{ .failed = err },
            };
            self.mutex.lockUncancelable(self.io);
            self.state = answer;
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

pub const BashWork = union {
    execution: bash.Execution,
    prepared_cleanup: bash.PreparedCleanup,
};

/// The one ask for MCP lists from the Host: asks the re-list owner for `only` or every configured server, wakes the
/// dispatch loop when anything was asked, and returns how many were asked. `tools_reload` and `find_tools` reload both
/// call it, so neither path asks or wakes on its own.
pub fn askMcpLists(host: *Host, only: ?[]const u8, out: *[host_settings.max_mcp_servers]server_mcp_relist.Relist.Asked) usize {
    const count: usize = if (host.mcp_relist) |owner| owner.askAll(only, out) else 0;
    if (count != 0) host.lifecycle.wakeDispatch();
    return count;
}

pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

pub inline fn traceSubject(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    if (host.probes.hooks.phase_trace) writeSubjectTrace(host, phase, subject_kind, subject);
}

noinline fn writeSubjectTrace(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    var publication = host.probes.beginObservation(phase, subject);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"subject_kind\":", .{nowNs(host.io)}) catch return;
    trace.appendJsonString(subject_kind) catch return;
    trace.append(",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append("}") catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceCommandObservation(host: *Host, key: []const u8, phase: []const u8) void {
    if (host.probes.hooks.phase_trace) writeCommandObservationTrace(host, key, phase);
}

noinline fn writeCommandObservationTrace(host: *Host, key: []const u8, phase: []const u8) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.append(",\"command_key\":") catch return;
    trace.appendJsonString(key) catch return;
    trace.append("}") catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceRequest(host: *Host, phase: []const u8, request_number: u64, scratch_used_bytes: ?u64) void {
    if (host.probes.hooks.phase_trace) writeRequestTrace(host, phase, request_number, scratch_used_bytes);
}

noinline fn writeRequestTrace(host: *Host, phase: []const u8, request_number: u64, scratch_used_bytes: ?u64) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"subject_kind\":\"request_number\",\"subject\":\"{d}\"",
        .{ nowNs(host.io), request_number },
    ) catch return;
    if (scratch_used_bytes) |used|
        trace.appendFmt(",\"scratch_used_bytes\":\"{d}\"", .{used}) catch return;
    trace.append("}") catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub fn executionFacts(host: *Host) session_report.Execution {
    return .{
        .dispatch_fenced = !host.lifecycle.launchAllowed(),
        .custody_occupied = host.custody.held(),
        .scratch_used_bytes = host.scratch_used.load(.acquire),
    };
}

pub inline fn traceServiceBoundary(host: *Host, start_ns: u64, end_ns: u64, wait_ns: u64) void {
    if (host.probes.hooks.phase_trace) writeServiceBoundaryTrace(host, start_ns, end_ns, wait_ns);
}

noinline fn writeServiceBoundaryTrace(host: *Host, start_ns: u64, end_ns: u64, wait_ns: u64) void {
    var publication = host.probes.beginObservation("lifecycle_boundary", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_boundary\",\"at_ns\":\"{d}\",\"start_ns\":\"{d}\",\"wait_ns\":\"{d}\"}}",
        .{ end_ns, start_ns, wait_ns },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceLifecycleService(host: *Host, maximum_gap_ns: u64) void {
    if (host.probes.hooks.phase_trace) writeLifecycleServiceTrace(host, maximum_gap_ns);
}

noinline fn writeLifecycleServiceTrace(host: *Host, maximum_gap_ns: u64) void {
    var publication = host.probes.beginObservation("lifecycle_service_observation", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_service_observation\",\"at_ns\":\"{d}\",\"maximum_gap_ns\":\"{d}\",\"owner\":\"execution\"}}",
        .{ nowNs(host.io), maximum_gap_ns },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceOperation(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    if (host.probes.hooks.phase_trace) writeOperationTrace(host, phase, binding);
}

noinline fn writeOperationTrace(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host.io),
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn tracePreparationAdvance(
    host: *Host,
    phase: []const u8,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writePreparationAdvanceTrace(host, phase, stats, binding);
}

noinline fn writePreparationAdvanceTrace(
    host: *Host,
    phase: []const u8,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host.io), stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn tracePreparationAdvanceError(
    host: *Host,
    phase: []const u8,
    err: anyerror,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writePreparationAdvanceErrorTrace(host, phase, err, stats, binding);
}

noinline fn writePreparationAdvanceErrorTrace(
    host: *Host,
    phase: []const u8,
    err: anyerror,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"error\":", .{nowNs(host.io)}) catch return;
    trace.appendJsonString(@errorName(err)) catch return;
    trace.appendFmt(
        ",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceCompletionQueue(host: *Host, queued_after: usize, binding: store_module.AttemptBinding) void {
    if (host.probes.hooks.phase_trace) writeCompletionQueueTrace(host, queued_after, binding);
}

noinline fn writeCompletionQueueTrace(host: *Host, queued_after: usize, binding: store_module.AttemptBinding) void {
    var publication = host.probes.beginObservation("provider_completion_removed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"provider_completion_removed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host.io), queued_after, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceAction(host: *Host, phase: []const u8, binding: store_module.ActionAttemptBinding) void {
    if (host.probes.hooks.phase_trace) writeActionTrace(host, phase, binding);
}

noinline fn writeActionTrace(host: *Host, phase: []const u8, binding: store_module.ActionAttemptBinding) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        nowNs(host.io),
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceOperationControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.AttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writeOperationControlTrace(host, phase, command_key, binding);
}

noinline fn writeOperationControlTrace(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.AttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host.io)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceActionControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.ActionAttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writeActionControlTrace(host, phase, command_key, binding);
}

noinline fn writeActionControlTrace(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.ActionAttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host.io)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceActionControlOutcome(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    attempted: bool,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writeActionControlOutcomeTrace(host, phase, command_key, attempted, failed, binding);
}

noinline fn writeActionControlOutcomeTrace(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    attempted: bool,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host.io)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"attempted\":{s},\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        if (attempted) "true" else "false",
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceActionDeadline(
    host: *Host,
    phase: []const u8,
    deadline_ns: u64,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (host.probes.hooks.phase_trace) writeActionDeadlineTrace(host, phase, deadline_ns, failed, binding);
}

noinline fn writeActionDeadlineTrace(
    host: *Host,
    phase: []const u8,
    deadline_ns: u64,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    var publication = host.probes.beginObservation(phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"deadline_ns\":\"{d}\",\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\"}}", .{
        nowNs(host.io),
        deadline_ns,
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
    }) catch return;
    host.probes.writeTrace(&trace, &publication);
}

pub fn pause(host: *Host, point: Hooks.Pause) void {
    const delay_ms = host.probes.pauseDelayMs(point);
    if (delay_ms == 0) return;
    switch (point) {
        .action_launch => |binding| traceAction(host, "prepared_before_handoff", binding),
        .model_launch => |binding| traceOperation(host, "prepared_before_handoff", binding),
        .action_result => |binding| traceAction(host, "sealed_before_settlement", binding),
        .model_result => |binding| traceOperation(host, "sealed_before_settlement", binding),
    }
    host.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
}

/// Retry recovery that the test gate holds back: the recovery waits, traced once, while its gate is present.
pub fn retryRecovered(host: *Host) void {
    const path = host.probes.holdRetryRecovery() orelse return;
    traceSubject(host, "exhausted_retry_recovery_held", "path", path);
}

pub fn bashReclaimHeld(host: *Host, binding: store_module.ActionAttemptBinding, attempted: bool) bool {
    const present = host.probes.bashReclaimGatePresent() orelse return false;
    if (present) return true;
    if (!attempted) traceAction(host, "cleanup_release_observed", binding);
    return false;
}

pub fn testGateActive(path: []const u8) bool {
    // Presence gates may be FIFOs; opening must not wait for a writer during
    // the release/unlink race. No descriptor survives this synchronous probe.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return false;
    _ = std.c.close(fd);
    return true;
}

pub inline fn observeUnprocessedCompletions(host: *Host, reactor: *provider.Reactor) void {
    const count: u64 = reactor.finishedCount();
    if (!host.probes.noteUnprocessedCompletions(count)) return;
    if (host.probes.hooks.phase_trace) writeUnprocessedCompletionsTrace(host, count);
}

noinline fn writeUnprocessedCompletionsTrace(host: *Host, count: u64) void {
    var publication = host.probes.beginObservation("native_completions_unprocessed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.DiagnosticBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"native_completions_unprocessed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\"}}",
        .{ nowNs(host.io), count },
    ) catch return;
    host.probes.writeTrace(&trace, &publication);
}

fn appendOptionalUnsigned(
    trace: *protocol.DiagnosticBuffer,
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
    trace: *protocol.DiagnosticBuffer,
    name: []const u8,
    value: ?i64,
) !void {
    try trace.appendJsonString(name);
    try trace.append(":");
    if (value) |present| {
        try trace.appendFmt("{d}", .{present});
    } else try trace.append("null");
}

pub inline fn traceTransfer(host: *Host, transfer: *provider.Transfer, binding: store_module.AttemptBinding) void {
    if (host.providers.anySignIn() and host.probes.hooks.phase_trace) writeTransferTrace(host, transfer, binding);
}

noinline fn writeTransferTrace(host: *Host, transfer: *provider.Transfer, binding: store_module.AttemptBinding) void {
    var publication = host.probes.beginObservation("codex_transfer", null);
    defer if (publication) |*value| value.finish();
    const observation = transfer.protocolObservation();
    const correlation = transfer.requestId();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(correlation, &digest, .{});
    var trace: protocol.DiagnosticBuffer = .{};
    trace.appendFmt("{{\"rui_test_phase\":\"codex_transfer\",\"operation\":\"{d}\",\"new_connections\":{d},\"replays\":{d},\"correlation_present\":{s},\"correlation_sha256\":\"{x}\"}}", .{
        binding.operation_id,
        observation.new_connections,
        observation.replays,
        if (correlation.len != 0) "true" else "false",
        digest,
    }) catch unreachable;
    host.probes.writeTrace(&trace, &publication);
}

pub inline fn traceSqliteDiagnostic(host: *Host, subject: []const u8) void {
    if (host.probes.hooks.phase_trace and host.probes.hooks.sqlite_diagnostics) writeSqliteDiagnosticTrace(host, subject);
}

// Reads the Store before the trace buffer exists: the read can run queued Store
// writes on this thread, so the buffer must not share a frame with it.
noinline fn writeSqliteDiagnosticTrace(host: *Host, subject: []const u8) void {
    var publication = host.probes.beginObservation("sqlite_diagnostic", subject);
    defer if (publication) |*value| value.finish();
    switch (host.store.diagnostic()) {
        .sqlite => |*value| renderSqliteDiagnosticTrace(host, subject, value, &publication),
        .mysql => {},
    }
}

noinline fn renderSqliteDiagnosticTrace(host: *Host, subject: []const u8, value: *const @FieldType(store_module.Diagnostic, "sqlite"), publication: *?TestObservation.Publication) void {
    var trace: protocol.DiagnosticBuffer = .{};
    trace.append("{\"rui_test_phase\":\"sqlite_diagnostic\",\"at_ns\":\"") catch return;
    trace.appendFmt("{d}", .{nowNs(host.io)}) catch return;
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
    host.probes.writeTrace(&trace, publication);
}

pub const SettlementTrace = struct {
    host: *Host,
    binding: store_module.AttemptBinding,

    pub fn init(host: *Host, binding: store_module.AttemptBinding) SettlementTrace {
        return .{ .host = host, .binding = binding };
    }

    pub fn storeTrace(self: *SettlementTrace) ?store_module.SettlementTrace {
        if (!self.host.probes.hooks.phase_trace) return null;
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
}

test "inspection counts held custody, not an in-flight admission reservation" {
    var records: [2]execution.CustodyRecord = @splat(.{});
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .custody = execution.CustodyPool.initialize(&records),
    };
    var host_lifecycle = Lifecycle.init(host.io, undefined, false, null);
    host.lifecycle = &host_lifecycle;
    const cleanup = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
    _ = try host.custody.attach(cleanup, &permit);
    try host.custody.detach(cleanup);
    const probe = host.custody.reserve().?;
    try std.testing.expectEqual(@as(usize, 1), executionFacts(&host).custody_occupied);
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
        };
        var probes: Probes = .{ .hooks = .{ .phase_trace = true }, .observation = observation };
        host.probes = &probes;
        var host_lifecycle = Lifecycle.init(host.io, undefined, false, null);
        host.lifecycle = &host_lifecycle;
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
        try std.testing.expect(probes.trace_lost.load(.acquire));
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
        var host_lifecycle = Lifecycle.init(host.io, undefined, false, null);
        host.lifecycle = &host_lifecycle;
        try std.testing.expect(host.lifecycle.launchAllowed());
        _ = host.lifecycle.advance(phase);
        var calls: usize = 0;
        if (phase == .open) {
            try host.lifecycle.withEffectLaunch(&calls, Launch.run);
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectError(error.HostDispatchSuppressed, host.lifecycle.withEffectLaunch(&calls, Launch.run));
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
            var host_lifecycle = Lifecycle.init(host.io, undefined, false, null);
            host.lifecycle = &host_lifecycle;
            try std.testing.expectEqual(Phase.open, host.lifecycle.advance(start));
            try std.testing.expectEqual(start, host.lifecycle.advance(target));
            const later = if (@backingInt(target) > @backingInt(start)) target else start;
            try std.testing.expectEqual(later, host.lifecycle.phase.load(.acquire));
            try std.testing.expectEqual(later == .open, host.lifecycle.launchAllowed());
            try std.testing.expectEqual(later == .stopping, host.lifecycle.stopping());
            try std.testing.expectEqual(later == .ending or later == .stopping, host.lifecycle.executionEnding());
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
    var host_lifecycle = Lifecycle.init(host.io, undefined, false, null);
    host.lifecycle = &host_lifecycle;
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
    try std.testing.expectError(error.TestLaunchFailure, host.lifecycle.withEffectLaunch(&calls, Launch.fail));
    try host.lifecycle.withEffectLaunch(&calls, Launch.succeed);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "an asked stop leaves the stop record only when it is what stops the Host, and the next start removes it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store", .{root});
    for (std.enums.values(Phase)) |before| {
        errdefer std.debug.print("phase before the ask: {t}\n", .{before});
        var lease = try platform.StoreLease.acquire(io, path);
        defer lease.release();
        try lease.prepareForServing(false);
        try std.testing.expectEqual(platform.StoreLease.LastStop.unasked, platform.StoreLease.lastStop(io, path));
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
        var host_lifecycle = Lifecycle.init(host.io, &lease, false, null);
        host.lifecycle = &host_lifecycle;
        _ = host.lifecycle.advance(before);
        try std.testing.expectEqual(platform.StoreLease.LastStop.unasked, platform.StoreLease.lastStop(io, path));
        const stopped = before != .stopping;
        try std.testing.expectEqual(stopped, host.lifecycle.stopAsked());
        try std.testing.expect(host.lifecycle.stopping());
        try std.testing.expectEqual(if (stopped) platform.StoreLease.LastStop.asked else .unasked, platform.StoreLease.lastStop(io, path));
        try std.testing.expect(!host.lifecycle.stopAsked());
        try std.testing.expectEqual(if (stopped) platform.StoreLease.LastStop.asked else .unasked, platform.StoreLease.lastStop(io, path));
        try lease.prepareForServing(false);
        try std.testing.expectEqual(platform.StoreLease.LastStop.unasked, platform.StoreLease.lastStop(io, path));
    }
}

test "a draining stop holds new Turns, only tightens, and records how it ended" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store", .{root});
    const host_drain_test = @import("host_drain.zig");
    // How the drain ends: the execution owner's judgement, or a plain stop first.
    for ([_]?host_drain_test.Outcome{ .finished, .deadline, null }) |ending| {
        errdefer std.debug.print("ending: {?t}\n", .{ending});
        var lease = try platform.StoreLease.acquire(io, path);
        defer lease.release();
        try lease.prepareForServing(false);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
        var host_lifecycle = Lifecycle.init(host.io, &lease, false, null);
        host.lifecycle = &host_lifecycle;
        try std.testing.expect(!host.lifecycle.turnsHeld());
        const first = host.lifecycle.askStop(try .seconds(60));
        try std.testing.expect(first == .drain and first.drain.changed);
        try std.testing.expect(host.lifecycle.turnsHeld() and !host.lifecycle.stopping());
        try std.testing.expectEqual(host_drain_test.Record.draining, platform.StoreLease.stopRecord(io, path));
        // A longer repeat leaves the deadline; a shorter one brings it in.
        const longer = host.lifecycle.askStop(try .seconds(600));
        try std.testing.expectEqual(host_drain_test.Ask{ .drain = .{ .until_ns = first.drain.until_ns, .changed = false } }, longer);
        const shorter = host.lifecycle.askStop(try .seconds(1));
        try std.testing.expect(shorter == .drain and shorter.drain.changed and shorter.drain.until_ns < first.drain.until_ns);
        try std.testing.expectEqual(shorter.drain.until_ns, host.lifecycle.drainUntil().?);
        // The operator's release does not end a drain's hold.
        host.lifecycle.setTurnsPaused(false);
        try std.testing.expect(host.lifecycle.turnsHeld());
        if (ending) |outcome| {
            try std.testing.expect(host.lifecycle.finishDrain(outcome));
            try std.testing.expectEqual(host_drain_test.Record.of(outcome), platform.StoreLease.stopRecord(io, path));
            try std.testing.expect(!host.lifecycle.stopAsked());
        } else {
            try std.testing.expect(host.lifecycle.stopAsked());
            try std.testing.expectEqual(host_drain_test.Record.superseded, platform.StoreLease.stopRecord(io, path));
            try std.testing.expect(!host.lifecycle.finishDrain(.finished));
        }
        try std.testing.expect(host.lifecycle.stopping());
        try std.testing.expectEqual(host_drain_test.Ask.already_stopping, host.lifecycle.askStop(try .seconds(60)));
        try std.testing.expectEqual(platform.StoreLease.LastStop.asked, platform.StoreLease.lastStop(io, path));
    }
}

test "each provider's model list is published and rendered on its own" {
    const catalog = @import("model_catalog.zig");
    var served: providers_module.Providers = .{};
    served.table.set(.codex, .{ .endpoint = providers_module.endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    served.table.set(.openai, .{ .endpoint = providers_module.endpoint(.openai), .credential = .{ .key_file = .{ .key = "sk-test" } } });
    served.table.set(.chatgpt, .{ .endpoint = providers_module.endpoint(.chatgpt), .credential = .{ .chatgpt_plan = .{ .path = "/p" } } });
    var lists: ModelLists = .init(std.testing.io, std.testing.allocator, &served);
    defer lists.deinit();
    const facts: []const catalog.Entry = &.{.{ .id = "gpt-6-sol", .context_window = null, .efforts = .{}, .openai_listed = true }};
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"openai\",\"source\":\"pending\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"chatgpt\",\"source\":\"pending\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}]",
        out.buffered(),
    );
    lists.publish(.chatgpt, "{\"models\":[{\"slug\":\"gpt-6-terra\",\"visibility\":\"list\"},{\"slug\":\"secret\",\"visibility\":\"hide\"},{\"slug\":\"gpt-6-sol\",\"visibility\":\"list\"}]}");
    lists.publish(.openai, error.ListingRefused);
    out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"openai\",\"source\":\"catalog_fallback\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"chatgpt\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-terra\",\"known\":false},{\"id\":\"gpt-6-sol\",\"known\":true}]}]",
        out.buffered(),
    );
    lists.publish(.chatgpt, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    try std.testing.expect(lists.live.get(.chatgpt) == .catalog_fallback);
    lists.publish(.openai, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    lists.publish(.openai, "{\"data\":[{\"id\":\"gpt-6-mare\"}]}");
    try std.testing.expectEqualStrings("gpt-6-mare\n", lists.live.get(.openai).live.bytes);
    try std.testing.expect(lists.live.get(.codex) == .catalog);
}
