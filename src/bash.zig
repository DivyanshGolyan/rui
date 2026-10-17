const std = @import("std");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const BashLifecycle = @import("BashLifecycle.zig");
const deadline = @import("deadline.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");

pub const excerpt_bytes: usize = 10_000;
pub const copy_window_bytes: usize = 16 * 1024;
const command_write_window_bytes: usize = 4096;
const fault_observation_delay_ms: u64 = 500;
pub const fault_gate_name = "bash-fault-gate";

const BashObservation = extern struct {
    kind: c_int,
    value: c_int,
};

extern fn rui_bash_observe(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_reap(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_pipe_queued_bytes(fd: c_int, bytes: *u64) c_int;
extern fn rui_bash_group_absent(pgid: c_int) c_int;

pub const LifecycleFault = enum {
    none,
    observe,
    reap,
    reap_watchdog,
    group_probe,
    tail_snapshot,
    signal,
    cleanup_watchdog,
};

pub const Faults = struct {
    preparation: bool = false,
    preparation_after_script: bool = false,
    spawn: bool = false,
    service: bool = false,
    capture_read: bool = false,
    capture_write: bool = false,
    seal: bool = false,
    cleanup: bool = false,
    lifecycle: LifecycleFault = .none,
    fault_gated: bool = false,
};

const Term = BashLifecycle.Term;
const CleanupFault = enum { none, persistent, gated };

const ServiceTime = union(enum) {
    live: std.Io,
    supplied: std.Io.Clock.Timestamp,

    fn observe(self: ServiceTime) std.Io.Clock.Timestamp {
        return switch (self) {
            .live => |io| .now(io, .awake),
            .supplied => |now| now,
        };
    }
};

fn faultGateActive(io: std.Io, scratch_path: []const u8) bool {
    var scratch = std.Io.Dir.cwd().openDir(io, scratch_path, .{}) catch return true;
    defer scratch.close(io);
    _ = scratch.statFile(io, fault_gate_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn decodeObservation(observation: BashObservation) Term {
    return switch (observation.kind) {
        1 => .{ .exited = @intCast(observation.value) },
        2 => .{ .signal = @intCast(observation.value) },
        else => .{ .unknown = @bitCast(observation.value) },
    };
}

test "native Bash observation agrees with reap for wide process exit values" {
    for ([_]struct { raw: c_int, expected: u8 }{
        .{ .raw = 2, .expected = 2 },
        .{ .raw = 257, .expected = 1 },
        .{ .raw = 512, .expected = 0 },
        .{ .raw = -1, .expected = 255 },
    }) |case| {
        const pid = std.c.fork();
        if (pid == 0) std.c._exit(case.raw);
        if (pid < 0) return error.TestForkFailed;
        var reaped = false;
        defer if (!reaped) {
            _ = std.c.waitpid(pid, null, 0);
        };

        var observed: BashObservation = undefined;
        var ready = false;
        for (0..1000) |_| {
            const result = rui_bash_observe(pid, &observed);
            try std.testing.expect(result >= 0);
            if (result == 1) {
                ready = true;
                break;
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(ready);
        try std.testing.expectEqual(Term{ .exited = case.expected }, decodeObservation(observed));

        var consumed: BashObservation = undefined;
        try std.testing.expectEqual(@as(c_int, 1), rui_bash_reap(pid, &consumed));
        reaped = true;
        try std.testing.expectEqual(Term{ .exited = case.expected }, decodeObservation(consumed));
    }
}

const OwnedFile = struct {
    io: std.Io,
    file: ?std.Io.File,
    name: protocol.Bounded(96),
    charged: u64 = 0,
    budget: ScratchBudget,
    published: bool = false,
    cleanup_fault: CleanupFault = .none,

    fn close(self: *OwnedFile) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    fn cleanup(self: *OwnedFile, scratch_path: []const u8) !void {
        self.close();
        if (self.published) return;
        if (self.cleanup_fault == .persistent or
            (self.cleanup_fault == .gated and faultGateActive(self.io, scratch_path)))
        {
            return error.InjectedBashCleanupFailure;
        }
        var scratch = try std.Io.Dir.cwd().openDir(self.io, scratch_path, .{});
        defer scratch.close(self.io);
        scratch.deleteFile(self.io, self.name.slice()) catch |err| switch (err) {
            // The owned descriptor is already closed, so an absent private
            // name establishes reclamation rather than a cleanup failure.
            error.FileNotFound => {},
            else => return err,
        };
        self.budget.release(self.charged);
        self.charged = 0;
        self.published = true;
    }
};

pub const Prepared = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    scratch_path: []const u8,
    bash_path: []const u8,
    timeout_ms: u64,
    faults: Faults,
    script: ?OwnedFile,
    stdout_capture: ?OwnedFile,
    stderr_capture: ?OwnedFile,

    pub fn cleanup(self: *Prepared) !void {
        return cleanupOwnedFiles(
            self.scratch_path,
            &self.script,
            &self.stdout_capture,
            &self.stderr_capture,
        );
    }

    pub fn takeCleanup(self: *Prepared) PreparedCleanup {
        const resources = PreparedCleanup{
            .scratch_path = self.scratch_path,
            .script = self.script,
            .stdout_capture = self.stdout_capture,
            .stderr_capture = self.stderr_capture,
        };
        self.script = null;
        self.stdout_capture = null;
        self.stderr_capture = null;
        return resources;
    }

    pub fn launch(self: *Prepared) !Execution {
        if (self.faults.spawn) return error.BashSpawnFailed;
        var script_path_buffer: [platform.max_scratch_path_bytes + 1 + 96]u8 = undefined;
        const script_path = try std.fmt.bufPrint(
            &script_path_buffer,
            "{s}/{s}",
            .{ self.scratch_path, self.script.?.name.slice() },
        );
        var empty_environment = std.process.Environ.Map.init(self.allocator);
        defer empty_environment.deinit();
        const started = std.Io.Clock.Timestamp.now(self.io, .awake);
        var child = std.process.spawn(self.io, .{
            .argv = &.{ self.bash_path, script_path },
            .cwd = .{ .path = self.workspace.slice() },
            .environ_map = &empty_environment,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch return error.BashSpawnFailed;
        const stdout_pipe = child.stdout.?;
        child.stdout = null;
        const stderr_pipe = child.stderr.?;
        child.stderr = null;
        const script = self.script.?;
        const stdout_capture = self.stdout_capture.?;
        const stderr_capture = self.stderr_capture.?;
        self.script = null;
        self.stdout_capture = null;
        self.stderr_capture = null;
        return .{
            .io = self.io,
            .lifecycle = .start(started, self.timeout_ms),
            .leader = child.id.?,
            .pgid = child.id.?,
            .pipes = .{ stdout_pipe, stderr_pipe },
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
            .script = script,
            .scratch_path = self.scratch_path,
            .started = started,
            .timeout_ms = self.timeout_ms,
            .faults = self.faults,
        };
    }
};

pub const PreparedCleanup = struct {
    scratch_path: []const u8,
    script: ?OwnedFile = null,
    stdout_capture: ?OwnedFile = null,
    stderr_capture: ?OwnedFile = null,

    pub fn cleanup(self: *PreparedCleanup) !void {
        return cleanupOwnedFiles(
            self.scratch_path,
            &self.script,
            &self.stdout_capture,
            &self.stderr_capture,
        );
    }

    /// Test/slow-check aid: no file in this cleanup remains unreclaimed.
    /// Partial success nulls reclaimed slots and retains the rest with
    /// their residual charges; only a complete pass satisfies this.
    pub fn isComplete(self: *const PreparedCleanup) bool {
        return self.script == null and self.stdout_capture == null and self.stderr_capture == null;
    }
};

pub const PreparationFailure = struct {
    cause: anyerror,
    cleanup: PreparedCleanup,
};

pub const PreparationStart = union(enum) {
    preparing: Preparation,
    failed: PreparationFailure,
};

pub const PreparationProgress = union(enum) {
    pending,
    prepared: Prepared,
    failed: PreparationFailure,
};

fn cleanupOwnedFiles(
    scratch_path: []const u8,
    script: *?OwnedFile,
    stdout_capture: *?OwnedFile,
    stderr_capture: *?OwnedFile,
) !void {
    var first_error: ?anyerror = null;
    for ([_]*?OwnedFile{ script, stdout_capture, stderr_capture }) |slot| {
        if (slot.*) |*file| {
            file.cleanup(scratch_path) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            slot.* = null;
        }
    }
    if (first_error) |err| return err;
}

/// Shell observations consumed at the service boundary. Production passes
/// `.live`; deterministic tests substitute explicit outcomes so deadline and
/// owner-state logic can be verified without elapsed time or syscalls.
const ObservationSource = union(enum) {
    live,
    none,
    observed: Term,
    failed,
};

pub const Execution = struct {
    io: std.Io,
    lifecycle: BashLifecycle,
    /// Direct child until its status is consumed by the reap.
    leader: ?std.process.Child.Id,
    /// Anchored original process group: the cancellation scope.
    pgid: std.process.Child.Id,
    /// Open while the matching lifecycle pipe is not closed.
    pipes: [2]?std.Io.File,
    stdout_capture: OwnedFile,
    stderr_capture: OwnedFile,
    script: OwnedFile,
    scratch_path: []const u8,
    started: std.Io.Clock.Timestamp,
    timeout_ms: u64,
    faults: Faults,
    read_fault_used: bool = false,
    service_fault_used: bool = false,
    output_reservation: ?output_retention.Pair = null,

    pub const TerminationAttempt = struct {
        attempted: bool,
        signal_failed: bool,
    };

    pub const TimeoutAction = struct {
        deadline_ns: u64,
        signal_failed: bool,
    };

    pub fn requestStop(self: *Execution, now: std.Io.Clock.Timestamp) TerminationAttempt {
        const signal = self.lifecycle.requestTermination(.stopped, now);
        self.sendSignal(signal);
        return .{ .attempted = signal != null, .signal_failed = self.lifecycle.signalFailed() };
    }

    pub fn requestInfrastructureShutdown(self: *Execution, now: std.Io.Clock.Timestamp) void {
        self.sendSignal(self.lifecycle.requestTermination(.infrastructure_shutdown, now));
    }

    pub fn applyDueDeadline(self: *Execution, now: std.Io.Clock.Timestamp) ?TimeoutAction {
        const expiry = self.lifecycle.expireDeadline(now) orelse return null;
        self.sendSignal(expiry.signal);
        return .{ .deadline_ns = @intCast(expiry.deadline.raw.nanoseconds), .signal_failed = self.lifecycle.signalFailed() };
    }

    pub const ServiceResult = struct {
        made_progress: bool,
        retired: bool,
        leader_observed_with_open_pipes: bool,
        timeout_action: ?TimeoutAction,
        fault: ?anyerror,
    };

    pub fn service(self: *Execution, window: []u8) ServiceResult {
        return self.serviceWithTime(window, .{ .live = self.io }, .live);
    }

    fn serviceAt(self: *Execution, window: []u8, now: std.Io.Clock.Timestamp, source: ObservationSource) ServiceResult {
        return self.serviceWithTime(window, .{ .supplied = now }, source);
    }

    fn serviceWithTime(self: *Execution, window: []u8, time: ServiceTime, source: ObservationSource) ServiceResult {
        std.debug.assert(window.len == copy_window_bytes);
        var now = time.observe();
        var fault: ?anyerror = null;
        if (self.faults.service and !self.service_fault_used) {
            self.service_fault_used = true;
            fault = error.InjectedBashServiceFailure;
            self.requestInfrastructureShutdown(now);
        }
        var made_progress = false;
        const timeout_action = self.applyDueDeadline(now);
        if (timeout_action != null) made_progress = true;
        const leader_observed = self.observeLeader(now, source) catch |err| observed: {
            fault = fault orelse err;
            self.requestInfrastructureShutdown(now);
            break :observed false;
        };
        made_progress = leader_observed or made_progress;
        made_progress = self.cutCapture(now, &fault) or made_progress;
        made_progress = self.servicePipe(.stdout, window, time, &now, &fault) or made_progress;
        made_progress = self.servicePipe(.stderr, window, time, &now, &fault) or made_progress;
        if (self.lifecycle.expireGrace(now)) |signal| {
            self.sendSignal(signal);
            made_progress = true;
        }
        made_progress = (self.reapLeader(now) catch |err| reaped: {
            fault = fault orelse err;
            break :reaped false;
        }) or made_progress;
        if (self.lifecycle.process == .checking_group) {
            const check = if (self.lifecycleFaultActive(.group_probe)) check: {
                fault = fault orelse error.InjectedBashGroupProbeFailure;
                break :check 0;
            } else if (self.lifecycleFaultActive(.cleanup_watchdog))
                0
            else
                rui_bash_group_absent(self.pgid);
            if (check == 1) {
                self.lifecycle.groupAbsent();
                made_progress = true;
            } else if (check < 0) {
                fault = fault orelse error.BashGroupProbeFailed;
            }
        }
        made_progress = self.cutCapture(now, &fault) or made_progress;
        if (self.lifecycle.process == .gone) {
            made_progress = self.servicePipe(.stdout, window, time, &now, &fault) or made_progress;
            made_progress = self.servicePipe(.stderr, window, time, &now, &fault) or made_progress;
        }
        return .{
            .made_progress = made_progress,
            .retired = self.retired(),
            .leader_observed_with_open_pipes = leader_observed and !self.lifecycle.pipesClosed(),
            .timeout_action = timeout_action,
            .fault = fault,
        };
    }

    pub fn deadlineNs(self: *const Execution) u64 {
        return @intCast(self.lifecycle.process.running.deadline.raw.nanoseconds);
    }

    pub fn retired(self: *const Execution) bool {
        return self.lifecycle.retired();
    }

    /// Test/slow-check aid: the process is gone and both pipes are closed.
    /// Capture and script cleanup may still remain outstanding; retirement
    /// never claims reclamation. Lets tests verify the precondition
    /// without tripping the reclaim assertion.
    pub fn checkRetired(self: *const Execution) !void {
        if (!self.retired()) return error.BashNotRetired;
    }

    pub fn reserveOutput(self: *Execution, retention: *output_retention.Queue) !bool {
        self.output_reservation = try retention.reservePair(
            self.stdout_capture.name.slice(),
            self.stdout_capture.charged,
            self.stderr_capture.name.slice(),
            self.stderr_capture.charged,
        );
        return self.output_reservation != null;
    }

    pub fn releaseOutputReservation(self: *Execution, retention: *output_retention.Queue) void {
        const pair = self.output_reservation orelse return;
        retention.releaseReservation(pair.stdout);
        retention.releaseReservation(pair.stderr);
        self.output_reservation = null;
    }

    pub fn outcome(self: *Execution, include_paths: bool) !Outcome {
        self.stdout_capture.file.?.sync(self.io) catch self.lifecycle.recordSealFailure();
        self.stderr_capture.file.?.sync(self.io) catch self.lifecycle.recordSealFailure();
        if (self.faults.seal) self.lifecycle.recordSealFailure();
        const code: store.ActionResolutionCode = switch (self.lifecycle.resolution()) {
            inline else => |resolution| @field(store.ActionResolutionCode, @tagName(resolution)),
        };
        var result: Outcome = .{ .code = code };
        var writer = std.Io.Writer.fixed(&result.content);
        try self.formatResult(&writer, code, include_paths);
        result.content_len = writer.buffered().len;
        return result;
    }

    pub fn reclaim(self: *Execution, retention: *output_retention.Queue) !void {
        std.debug.assert(self.retired());
        var first_error: ?anyerror = null;
        if (self.output_reservation != null) {
            // Reserved entries are protected from eviction. Relinquish the
            // producer aliases before publication makes the names reclaimable.
            self.stdout_capture.close();
            self.stderr_capture.close();
            self.publishReservedOutput(retention) catch |err| {
                first_error = err;
            };
        } else {
            self.stdout_capture.cleanup(self.scratch_path) catch |err| {
                first_error = err;
            };
            self.stderr_capture.cleanup(self.scratch_path) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        self.script.cleanup(self.scratch_path) catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
    }

    /// Publishes a reserved output pair after the producer aliases are
    /// relinquished. The boundary is executable: publishing with an open
    /// alias fails instead of making output evictable while the producer
    /// can still write. Production reclaim closes the aliases first, then
    /// calls this; tests exercise the boundary directly.
    pub fn publishReservedOutput(self: *Execution, retention: *output_retention.Queue) !void {
        const pair = self.output_reservation orelse return error.NoOutputReservation;
        if (self.stdout_capture.file != null or self.stderr_capture.file != null) {
            return error.ProducerAliasesOpen;
        }
        try retention.publishPair(pair);
        self.output_reservation = null;
        self.stdout_capture.published = true;
        self.stderr_capture.published = true;
    }

    fn sendSignal(self: *Execution, signal: ?BashLifecycle.Signal) void {
        switch (signal orelse return) {
            .terminate_group => self.signalGroup(.TERM),
            .kill_group => self.signalGroup(.KILL),
            .kill_group_and_leader => {
                self.signalGroup(.KILL);
                self.signalLeader(.KILL);
            },
        }
    }

    fn signalGroup(self: *Execution, signal_value: std.posix.SIG) void {
        if (self.faults.lifecycle == .signal) return self.lifecycle.recordSignal(.failed);
        std.posix.kill(-self.pgid, signal_value) catch |err| self.lifecycle.recordSignal(switch (err) {
            error.ProcessNotFound => .delivered,
            error.PermissionDenied => if (@import("builtin").os.tag == .macos) .group_permission_denied else .failed,
            else => .failed,
        });
    }

    fn signalLeader(self: *Execution, signal_value: std.posix.SIG) void {
        if (self.faults.lifecycle == .signal) return self.lifecycle.recordSignal(.failed);
        std.posix.kill(self.leader.?, signal_value) catch |err| self.lifecycle.recordSignal(switch (err) {
            error.ProcessNotFound => .delivered,
            else => .failed,
        });
    }

    fn capture(self: *Execution, stream: BashLifecycle.Stream) *OwnedFile {
        return switch (stream) {
            .stdout => &self.stdout_capture,
            .stderr => &self.stderr_capture,
        };
    }

    fn closeDescriptor(self: *Execution, stream: BashLifecycle.Stream) void {
        const slot = &self.pipes[@backingInt(stream)];
        if (slot.*) |file| file.close(self.io);
        slot.* = null;
    }

    fn endPipe(self: *Execution, stream: BashLifecycle.Stream, end: BashLifecycle.PipeEnd, now: std.Io.Clock.Timestamp) void {
        self.closeDescriptor(stream);
        self.sendSignal(self.lifecycle.endPipe(stream, end, now));
    }

    /// One bounded pipe operation's result, applied at the service-time
    /// observation taken after the potentially blocking operation.
    const PipeStep = union(enum) {
        idle,
        copied,
        drained: u64,
        ended: BashLifecycle.PipeEnd,
    };

    fn servicePipe(
        self: *Execution,
        stream: BashLifecycle.Stream,
        window: []u8,
        time: ServiceTime,
        now: *std.Io.Clock.Timestamp,
        fault: *?anyerror,
    ) bool {
        const step = self.readPipe(stream, window) catch |err| failed: {
            fault.* = fault.* orelse err;
            break :failed PipeStep{ .ended = .{ .failed = .read } };
        };
        now.* = time.observe();
        switch (step) {
            .idle => return false,
            .copied => return true,
            .drained => |bytes| {
                self.lifecycle.drainedTail(stream, bytes);
                return true;
            },
            .ended => |end| {
                self.endPipe(stream, end, now.*);
                return true;
            },
        }
    }

    fn readPipe(self: *Execution, stream: BashLifecycle.Stream, window: []u8) !PipeStep {
        const state = self.lifecycle.pipes[@backingInt(stream)];
        const descriptor_slot = self.pipes[@backingInt(stream)];
        // The descriptor is open exactly while the lifecycle pipe is not closed.
        std.debug.assert((state == .closed) == (descriptor_slot == null));
        if (state == .closed) return .idle;
        const pipe = descriptor_slot.?;
        const destination = self.capture(stream);
        if (state == .tail) return self.readTail(pipe, destination, state.tail, window);
        var descriptor = [_]std.posix.pollfd{.{
            .fd = pipe.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptor, 0) == 0) return .idle;
        const reserved: usize = @intCast(destination.budget.reserveUpTo(window.len));
        if (reserved == 0) {
            var probe: [1]u8 = undefined;
            const count = std.posix.read(pipe.handle, &probe) catch |err| {
                if (err == error.WouldBlock) return .idle;
                return .{ .ended = .{ .failed = .read } };
            };
            if (count == 0) return .{ .ended = .eof };
            return .{ .ended = .{ .failed = .exhausted } };
        }
        const count = std.posix.read(pipe.handle, window[0..reserved]) catch |err| {
            destination.budget.release(reserved);
            if (err == error.WouldBlock) return .idle;
            return .{ .ended = .{ .failed = .read } };
        };
        if (count < reserved) destination.budget.release(reserved - count);
        if (count == 0) return .{ .ended = .eof };
        if (self.faults.capture_read and !self.read_fault_used) {
            self.read_fault_used = true;
            destination.budget.release(count);
            return .{ .ended = .{ .failed = .read } };
        }
        destination.charged += count;
        if (self.faults.capture_write) return .{ .ended = .{ .failed = .write } };
        destination.file.?.writeStreamingAll(self.io, window[0..count]) catch {
            return .{ .ended = .{ .failed = .write } };
        };
        return .copied;
    }

    fn readTail(
        self: *Execution,
        pipe: std.Io.File,
        destination: *OwnedFile,
        remaining: u64,
        window: []u8,
    ) !PipeStep {
        if (remaining == 0) {
            var descriptor = [_]std.posix.pollfd{.{
                .fd = pipe.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            if (try std.posix.poll(&descriptor, 0) == 0) return .{ .ended = .incomplete };
            var probe: [1]u8 = undefined;
            const count = std.posix.read(pipe.handle, &probe) catch |err| {
                if (err == error.WouldBlock) return .{ .ended = .incomplete };
                return .{ .ended = .{ .failed = .read } };
            };
            return .{ .ended = if (count == 0) .eof else .incomplete };
        }
        const wanted: usize = @intCast(@min(remaining, window.len));
        const reserved: usize = @intCast(destination.budget.reserveUpTo(wanted));
        if (reserved == 0) return .{ .ended = .{ .failed = .exhausted } };
        const count = std.posix.read(pipe.handle, window[0..reserved]) catch |err| {
            destination.budget.release(reserved);
            if (err == error.WouldBlock) return .idle;
            return .{ .ended = .{ .failed = .read } };
        };
        if (count < reserved) destination.budget.release(reserved - count);
        if (count == 0) return .{ .ended = .{ .failed = .read } };
        destination.charged += count;
        destination.file.?.writeStreamingAll(self.io, window[0..count]) catch {
            return .{ .ended = .{ .failed = .write } };
        };
        return .{ .drained = count };
    }

    fn observeLeader(self: *Execution, now: std.Io.Clock.Timestamp, source: ObservationSource) !bool {
        if (!self.lifecycle.awaitsLeader()) return false;
        const term: Term = switch (source) {
            .none => return false,
            .observed => |term| term,
            .failed => return error.BashObserveFailed,
            .live => live: {
                if (self.lifecycleFaultActive(.observe) and
                    deadline.reached(now, deadline.after(self.started, fault_observation_delay_ms)))
                {
                    return error.InjectedBashObserveFailure;
                }
                var observation: BashObservation = undefined;
                const result = rui_bash_observe(self.leader.?, &observation);
                if (result < 0) return error.BashObserveFailed;
                if (result == 0) return false;
                break :live decodeObservation(observation);
            },
        };
        self.sendSignal(self.lifecycle.observeLeader(term, now));
        return true;
    }

    fn reapLeader(self: *Execution, now: std.Io.Clock.Timestamp) !bool {
        if (self.lifecycle.process != .reaping) return false;
        if (self.lifecycleFaultActive(.reap)) return error.InjectedBashReapFailure;
        var observation: BashObservation = undefined;
        const result = if (self.lifecycleFaultActive(.reap_watchdog))
            0
        else
            rui_bash_reap(self.leader.?, &observation);
        if (result == 0) {
            try self.lifecycle.reapPending(now);
            return false;
        }
        if (result < 0) return error.BashWaitFailed;
        self.leader = null;
        try self.lifecycle.reaped(decodeObservation(observation));
        return true;
    }

    fn lifecycleFaultActive(self: *const Execution, expected: LifecycleFault) bool {
        if (self.faults.lifecycle != expected) return false;
        if (!self.faults.fault_gated) return true;
        return faultGateActive(self.io, self.scratch_path);
    }

    fn cutCapture(self: *Execution, now: std.Io.Clock.Timestamp, fault: *?anyerror) bool {
        const cutoff = self.lifecycle.cutoff(now) orelse return false;
        for (std.enums.values(BashLifecycle.Stream)) |stream| {
            if (cutoff.snapshot[@backingInt(stream)]) self.beginTail(stream);
        }
        if (cutoff.unconfirmed) fault.* = fault.* orelse error.BashCleanupUnconfirmed;
        return cutoff.changed();
    }

    fn beginTail(self: *Execution, stream: BashLifecycle.Stream) void {
        const pipe = self.pipes[@backingInt(stream)].?;
        var queued: u64 = 0;
        const observed = self.faults.lifecycle != .tail_snapshot and
            rui_bash_pipe_queued_bytes(pipe.handle, &queued) >= 0;
        if (!observed) self.closeDescriptor(stream);
        self.lifecycle.beginTail(stream, if (observed) queued else null);
    }
    fn formatResult(
        self: *Execution,
        writer: *std.Io.Writer,
        code: store.ActionResolutionCode,
        include_paths: bool,
    ) !void {
        try writer.print("Bash {s}. ", .{@tagName(code)});
        switch (self.lifecycle.process.gone) {
            .exited => |exit_code| try writer.print("Exit code: {d}.\n", .{exit_code}),
            .signal => |signal_value| try writer.print("Signal: {d}.\n", .{signal_value}),
            .unknown => |status| try writer.print("Unknown process status: {d}.\n", .{status}),
        }
        if (code == .timed_out) {
            try writer.print(
                "Execution timed out after a {d} ms total budget from process start; output does not reset it. " ++
                    "No background handle is available. Partial effects may remain: inspect state before retrying. " ++
                    "For safe repeatable work, narrow the command or choose a longer timeout_ms. " ++
                    "A timed-out search does not establish absence.\n",
                .{self.timeout_ms},
            );
        }
        if (self.lifecycle.capture_failure != .none) {
            try writer.print("Capture failure: {s}; output may be incomplete.\n", .{@tagName(self.lifecycle.capture_failure)});
        } else if (self.lifecycle.captureIncomplete()) {
            try writer.writeAll("Capture may be incomplete because writers outlived process-group termination.\n");
        }
        if (self.lifecycle.signal_failure) try writer.writeAll("Process-group signaling reported a failure.\n");
        if (self.lifecycle.group_permission_denied) {
            try writer.writeAll("Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial.\n");
        }
        var tail: [excerpt_bytes]u8 = undefined;
        const stdout_length = try self.stdout_capture.file.?.length(self.io);
        const stderr_length = try self.stderr_capture.file.?.length(self.io);
        const stderr_base: usize = @intCast(@min(stderr_length, excerpt_bytes / 2));
        const stdout_take: usize = @intCast(@min(stdout_length, excerpt_bytes - stderr_base));
        const stderr_take = stderr_base + @as(usize, @intCast(@min(
            stderr_length - stderr_base,
            excerpt_bytes - stderr_base - stdout_take,
        )));
        if (stdout_take != 0) {
            const count = try self.stdout_capture.file.?.readPositionalAll(
                self.io,
                tail[0..stdout_take],
                stdout_length - stdout_take,
            );
            if (count != stdout_take) return error.ShortCaptureRead;
        }
        if (stderr_take != 0) {
            const count = try self.stderr_capture.file.?.readPositionalAll(
                self.io,
                tail[stdout_take .. stdout_take + stderr_take],
                stderr_length - stderr_take,
            );
            if (count != stderr_take) return error.ShortCaptureRead;
        }
        const stdout_bytes = tail[0..stdout_take];
        const stderr_bytes = tail[stdout_take .. stdout_take + stderr_take];
        const stderr_encoded_base = @min(validUtf8Length(stderr_bytes), excerpt_bytes / 2);
        const stdout_allowance = @min(validUtf8Length(stdout_bytes), excerpt_bytes - stderr_encoded_base);
        const stderr_allowance = stderr_encoded_base + @min(
            validUtf8Length(stderr_bytes) - stderr_encoded_base,
            excerpt_bytes - stderr_encoded_base - stdout_allowance,
        );
        try writer.writeAll("stdout tail:\n");
        const stdout_sanitized_omission = try appendValidUtf8Tail(writer, stdout_bytes, stdout_allowance);
        try writer.writeAll("\nstderr tail:\n");
        const stderr_sanitized_omission = try appendValidUtf8Tail(writer, stderr_bytes, stderr_allowance);
        if (stdout_length + stderr_length > stdout_take + stderr_take or
            stdout_sanitized_omission or stderr_sanitized_omission)
        {
            try writer.writeAll("\n[earlier output omitted]\n");
        }
        if (!include_paths) {
            try writer.writeAll("\nFull output was not retained.\n");
            return;
        }
        var stdout_path: [platform.max_scratch_path_bytes + 1 + 96]u8 = undefined;
        var stderr_path: [platform.max_scratch_path_bytes + 1 + 96]u8 = undefined;
        const stdout_value = try std.fmt.bufPrint(
            &stdout_path,
            "{s}/{s}",
            .{ self.scratch_path, self.stdout_capture.name.slice() },
        );
        const stderr_value = try std.fmt.bufPrint(
            &stderr_path,
            "{s}/{s}",
            .{ self.scratch_path, self.stderr_capture.name.slice() },
        );
        try writer.print("\nFull stdout: {s}\nFull stderr: {s}\n", .{ stdout_value, stderr_value });
    }
};

pub const Outcome = struct {
    code: store.ActionResolutionCode,
    content: [excerpt_bytes + 4096]u8 = undefined,
    content_len: usize = 0,

    pub fn text(self: *const Outcome) []const u8 {
        return self.content[0..self.content_len];
    }
};

pub const Preparation = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    scratch_path: []const u8,
    bash_path: []const u8,
    timeout_ms: u64,
    action_id: u64,
    attempt_ordinal: u64,
    faults: Faults,
    source: ContentSource,
    parser: tools.BashParser = .{},
    cleanup: PreparedCleanup,
    command_buffer: [command_write_window_bytes]u8 = undefined,
    command_length: usize = 0,

    pub fn advance(self: *Preparation) PreparationProgress {
        var writer = PreparationWriter{ .owner = self };
        const progress = self.parser.advance(&self.source, &writer, self.source.buffer.len) catch |err| {
            return self.fail(if (tools.isBashDescriptorError(err)) error.InvalidCanonicalBashDescriptor else err);
        };
        switch (progress) {
            .pending => return .pending,
            .invalid => return self.fail(error.InvalidCanonicalBashDescriptor),
            .complete => {},
        }
        self.flushCommand() catch |err| return self.fail(err);
        self.cleanup.script.?.file.?.sync(self.io) catch |err| return self.fail(err);
        const cleanup_fault = cleanupFault(self.faults);
        self.cleanup.stdout_capture = createOwnedFile(
            self.io,
            self.scratch_path,
            self.cleanup.script.?.budget,
            "bash-stdout",
            self.action_id,
            self.attempt_ordinal,
            cleanup_fault,
        ) catch |err| return self.fail(err);
        self.cleanup.stderr_capture = createOwnedFile(
            self.io,
            self.scratch_path,
            self.cleanup.script.?.budget,
            "bash-stderr",
            self.action_id,
            self.attempt_ordinal,
            cleanup_fault,
        ) catch |err| return self.fail(err);
        self.source.reader.close();
        const cleanup = self.takeCleanup();
        return .{ .prepared = .{
            .io = self.io,
            .allocator = self.allocator,
            .workspace = self.workspace,
            .scratch_path = self.scratch_path,
            .bash_path = self.bash_path,
            .timeout_ms = self.timeout_ms,
            .faults = self.faults,
            .script = cleanup.script,
            .stdout_capture = cleanup.stdout_capture,
            .stderr_capture = cleanup.stderr_capture,
        } };
    }

    pub fn cancel(self: *Preparation) PreparedCleanup {
        self.source.reader.close();
        return self.takeCleanup();
    }

    fn fail(self: *Preparation, cause: anyerror) PreparationProgress {
        self.source.reader.close();
        return .{ .failed = .{ .cause = cause, .cleanup = self.takeCleanup() } };
    }

    fn takeCleanup(self: *Preparation) PreparedCleanup {
        const cleanup = self.cleanup;
        self.cleanup = .{ .scratch_path = self.scratch_path };
        return cleanup;
    }

    fn flushCommand(self: *Preparation) !void {
        if (self.command_length == 0) return;
        const script = &self.cleanup.script.?;
        if (!script.budget.reserve(self.command_length)) return error.ScratchCapacityExhausted;
        script.charged += self.command_length;
        try script.file.?.writeStreamingAll(self.io, self.command_buffer[0..self.command_length]);
        self.command_length = 0;
    }
};

const PreparationWriter = struct {
    owner: *Preparation,

    pub fn writeAll(self: *PreparationWriter, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const count = @min(remaining.len, self.owner.command_buffer.len - self.owner.command_length);
            @memcpy(
                self.owner.command_buffer[self.owner.command_length..][0..count],
                remaining[0..count],
            );
            self.owner.command_length += count;
            remaining = remaining[count..];
            if (self.owner.command_length == self.owner.command_buffer.len) try self.owner.flushCommand();
        }
    }
};

pub fn startPreparation(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: store.ContentReader,
    arguments_length: u64,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    scratch_path: []const u8,
    bash_path: []const u8,
    timeout_ms: u64,
    budget: ScratchBudget,
    action_id: u64,
    attempt_ordinal: u64,
    faults: Faults,
) PreparationStart {
    var cleanup = PreparedCleanup{ .scratch_path = scratch_path };
    var owned_reader = reader;
    if (faults.preparation) {
        owned_reader.close();
        return .{ .failed = .{ .cause = error.BashPreparationFailed, .cleanup = cleanup } };
    }
    cleanup.script = createOwnedFile(
        io,
        scratch_path,
        budget,
        "bash-input",
        action_id,
        attempt_ordinal,
        cleanupFault(faults),
    ) catch |err| {
        owned_reader.close();
        return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    };
    if (faults.preparation_after_script) {
        owned_reader.close();
        return .{ .failed = .{ .cause = error.BashPreparationFailed, .cleanup = cleanup } };
    }
    return .{ .preparing = .{
        .io = io,
        .allocator = allocator,
        .workspace = workspace,
        .scratch_path = scratch_path,
        .bash_path = bash_path,
        .timeout_ms = timeout_ms,
        .action_id = action_id,
        .attempt_ordinal = attempt_ordinal,
        .faults = faults,
        .source = .{ .reader = owned_reader, .length = arguments_length },
        .cleanup = cleanup,
    } };
}

fn cleanupFault(faults: Faults) CleanupFault {
    return if (!faults.cleanup)
        .none
    else if (faults.fault_gated)
        .gated
    else
        .persistent;
}

fn createOwnedFile(
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    prefix: []const u8,
    action_id: u64,
    attempt_ordinal: u64,
    cleanup_fault: CleanupFault,
) !OwnedFile {
    var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
    defer scratch.close(io);
    var name: protocol.Bounded(96) = .{};
    var name_buffer: [96]u8 = undefined;
    try name.set(try std.fmt.bufPrint(&name_buffer, "{s}-{d}-{d}.tmp", .{ prefix, action_id, attempt_ordinal }));
    return .{
        .io = io,
        .file = try scratch.createFile(io, name.slice(), .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }),
        .name = name,
        .budget = budget,
        .cleanup_fault = cleanup_fault,
    };
}

fn runningWithDeadline(started: std.Io.Clock.Timestamp, timeout_ms: u64) Execution {
    return .{
        .io = std.testing.io,
        .lifecycle = .{
            .process = .{ .running = .{ .deadline = deadline.after(started, timeout_ms) } },
            .pipes = .{ .{ .closed = .eof }, .{ .closed = .eof } },
        },
        .leader = 1,
        .pgid = 1,
        .pipes = .{ null, null },
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .script = undefined,
        .scratch_path = "",
        .started = started,
        .timeout_ms = timeout_ms,
        // Signaling is faulted to a no-op so no real process is signaled.
        .faults = .{ .lifecycle = .signal },
    };
}

test "service acts on its service-time observation rather than an earlier one" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    const timeout_at = deadline.after(started, 20);
    // A pre-work observation is before the deadline: no timeout.
    const before = deadline.after(started, 1);
    var execution = runningWithDeadline(started, 20);
    try std.testing.expect(execution.applyDueDeadline(before) == null);
    try std.testing.expect(execution.lifecycle.process == .running);
    // The service-time observation is after the deadline: the real owner
    // requests termination through the production service path. No clock is
    // sampled and no syscall runs; both observations are explicit inputs.
    const after = deadline.after(started, 21);
    var window: [copy_window_bytes]u8 = undefined;
    const result = execution.serviceAt(&window, after, .none);
    const timeout = result.timeout_action orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(u64, @intCast(timeout_at.raw.nanoseconds)), timeout.deadline_ns);
    // The faulted TERM is reported with the timeout that sent it.
    try std.testing.expect(timeout.signal_failed);
    try std.testing.expect(result.fault == null);
    try std.testing.expect(result.made_progress);
    try std.testing.expect(!result.retired);
    try std.testing.expect(execution.lifecycle.process == .grace);
    try std.testing.expectEqual(BashLifecycle.StopReason.timed_out, execution.lifecycle.stop_reason);
    // Substituting the earlier observation performs no timeout.
    var stale = runningWithDeadline(started, 20);
    const idle = stale.serviceAt(&window, before, .none);
    try std.testing.expect(idle.timeout_action == null);
    try std.testing.expect(idle.fault == null);
    try std.testing.expect(stale.lifecycle.process == .running);
    // A failed observation is reported without a timeout, and the grace
    // deadlines derive from the supplied service-time observation.
    var unobservable = runningWithDeadline(started, 20);
    const failed = unobservable.serviceAt(&window, before, .failed);
    try std.testing.expect(failed.timeout_action == null);
    try std.testing.expect(failed.fault.? == error.BashObserveFailed);
    try std.testing.expectEqual(BashLifecycle.StopReason.infrastructure_shutdown, unobservable.lifecycle.stop_reason);
    const grace = unobservable.lifecycle.process.grace;
    try std.testing.expectEqual(
        before.raw.nanoseconds + BashLifecycle.termination_grace_ms * std.time.ns_per_ms,
        grace.kill_at.raw.nanoseconds,
    );
    try std.testing.expectEqual(
        before.raw.nanoseconds + BashLifecycle.cleanup_observation_ms * std.time.ns_per_ms,
        grace.cleanup_deadline.raw.nanoseconds,
    );
    // A later stop is acknowledged without a new TERM or deadlines.
    const stop = unobservable.requestStop(deadline.after(before, 50));
    try std.testing.expect(!stop.attempted);
    try std.testing.expectEqual(BashLifecycle.StopReason.infrastructure_shutdown, unobservable.lifecycle.stop_reason);
    try std.testing.expectEqual(grace.kill_at.raw.nanoseconds, unobservable.lifecycle.process.grace.kill_at.raw.nanoseconds);
    // An observed leader retires the running state without a deadline.
    var witnessed = runningWithDeadline(started, 20);
    const seen = witnessed.serviceAt(&window, before, .{ .observed = .{ .exited = 0 } });
    try std.testing.expect(seen.timeout_action == null);
    try std.testing.expect(seen.fault == null);
    try std.testing.expect(seen.made_progress);
    try std.testing.expect(witnessed.lifecycle.process == .grace);
    try std.testing.expectEqual(BashLifecycle.StopReason.none, witnessed.lifecycle.stop_reason);
}

test "cleanup deadline cuts off unresolved pipe custody exactly once" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    const cleanup_at = deadline.after(started, 100);
    const before = deadline.after(started, 99);
    const after = deadline.after(started, 101);
    const phases = [_]enum { grace, reaping, checking_group }{ .grace, .reaping, .checking_group };
    const observations = [_]struct { now: std.Io.Clock.Timestamp, cutoff: bool }{
        .{ .now = before, .cutoff = false },
        .{ .now = cleanup_at, .cutoff = true },
        .{ .now = after, .cutoff = true },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 0 };
    var old_sigpipe: std.posix.Sigaction = undefined;
    const ignore_sigpipe: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &ignore_sigpipe, &old_sigpipe);
    defer std.posix.sigaction(.PIPE, &old_sigpipe, null);

    for (phases) |phase| for (observations) |observation| {
        var stdout_fds: [2]std.c.fd_t = undefined;
        var stderr_fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&stdout_fds));
        var stdout_read_owned = true;
        errdefer {
            if (stdout_read_owned) _ = std.c.close(stdout_fds[0]);
        }
        defer _ = std.c.close(stdout_fds[1]);
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&stderr_fds));
        var stderr_read_owned = true;
        errdefer {
            if (stderr_read_owned) _ = std.c.close(stderr_fds[0]);
        }
        defer _ = std.c.close(stderr_fds[1]);
        var execution = Execution{
            .io = std.testing.io,
            .lifecycle = .{ .process = undefined },
            .leader = null,
            .pgid = 1,
            .pipes = .{
                .{ .handle = stdout_fds[0], .flags = .{ .nonblocking = false } },
                .{ .handle = stderr_fds[0], .flags = .{ .nonblocking = false } },
            },
            .stdout_capture = undefined,
            .stderr_capture = undefined,
            .script = undefined,
            .scratch_path = root,
            .started = started,
            .timeout_ms = 100,
            .faults = .{},
        };
        stdout_read_owned = false;
        stderr_read_owned = false;
        defer execution.closeDescriptor(.stdout);
        defer execution.closeDescriptor(.stderr);
        execution.stdout_capture = try createOwnedFile(std.testing.io, root, budget, "deadline-stdout", @backingInt(phase), @intFromBool(observation.cutoff), .none);
        defer execution.stdout_capture.cleanup(root) catch {};
        execution.stderr_capture = try createOwnedFile(std.testing.io, root, budget, "deadline-stderr", @backingInt(phase), @intFromBool(observation.cutoff), .none);
        defer execution.stderr_capture.cleanup(root) catch {};
        execution.script = try createOwnedFile(std.testing.io, root, budget, "deadline-script", @backingInt(phase), @intFromBool(observation.cutoff), .none);
        defer execution.script.cleanup(root) catch {};
        switch (phase) {
            .grace => {
                execution.leader = 1;
                execution.lifecycle.process = .{ .grace = .{
                    .kill_at = deadline.after(after, 1),
                    .cleanup_deadline = cleanup_at,
                    .observed = null,
                } };
            },
            .reaping => {
                execution.lifecycle.process = .{ .reaping = .{ .cleanup_deadline = cleanup_at, .observed = null } };
                // The reap gate suppresses the syscall, not reading its PID.
                execution.leader = 1;
                execution.faults.lifecycle = .reap_watchdog;
            },
            .checking_group => {
                execution.lifecycle.process = .{ .checking_group = .{
                    .term = .{ .exited = 0 },
                    .cleanup_deadline = cleanup_at,
                } };
                execution.faults.lifecycle = .cleanup_watchdog;
            },
        }
        var window: [copy_window_bytes]u8 = undefined;
        const result = execution.serviceAt(&window, observation.now, .none);
        try std.testing.expectEqual(observation.cutoff, execution.lifecycle.pipesClosed());
        try std.testing.expectEqual(observation.cutoff, execution.pipes[0] == null and execution.pipes[1] == null);
        try std.testing.expect(!result.retired);
        try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
        if (observation.cutoff) {
            try std.testing.expect(result.fault.? == error.BashCleanupUnconfirmed);
            try std.testing.expectEqual(@as(isize, -1), std.c.write(stdout_fds[1], "x", 1));
            try std.testing.expectEqual(std.c.E.PIPE, std.c.errno(-1));
            const repeated = execution.serviceAt(&window, after, .none);
            try std.testing.expect(!repeated.made_progress);
            try std.testing.expect(repeated.fault.? == error.BashCleanupUnconfirmed);
        } else {
            try std.testing.expect(result.fault == null);
            try std.testing.expectEqual(@as(isize, 1), std.c.write(stdout_fds[1], "x", 1));
        }
    };

    var gone_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&gone_fds));
    var gone_read_owned = true;
    errdefer {
        if (gone_read_owned) _ = std.c.close(gone_fds[0]);
    }
    defer _ = std.c.close(gone_fds[1]);
    var gone = Execution{
        .io = std.testing.io,
        .lifecycle = .{
            .process = .{ .gone = .{ .exited = 0 } },
            .pipes = .{ .reading, .{ .closed = .eof } },
        },
        .leader = null,
        .pgid = 1,
        .pipes = .{ .{ .handle = gone_fds[0], .flags = .{ .nonblocking = false } }, null },
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .script = undefined,
        .scratch_path = root,
        .started = started,
        .timeout_ms = 100,
        .faults = .{},
    };
    gone_read_owned = false;
    defer gone.closeDescriptor(.stdout);
    gone.stdout_capture = try createOwnedFile(std.testing.io, root, budget, "gone-stdout", 1, 1, .none);
    defer gone.stdout_capture.cleanup(root) catch {};
    gone.stderr_capture = try createOwnedFile(std.testing.io, root, budget, "gone-stderr", 1, 1, .none);
    defer gone.stderr_capture.cleanup(root) catch {};
    gone.script = try createOwnedFile(std.testing.io, root, budget, "gone-script", 1, 1, .none);
    defer gone.script.cleanup(root) catch {};
    var window: [copy_window_bytes]u8 = undefined;
    const gone_result = gone.serviceAt(&window, before, .none);
    try std.testing.expect(gone_result.fault == null);
    try std.testing.expect(gone_result.retired);
    const gone_repeated = gone.serviceAt(&window, after, .none);
    try std.testing.expect(!gone_repeated.made_progress);
    try std.testing.expect(gone_repeated.retired);

    gone.lifecycle.recordSignal(.failed);
    gone.lifecycle.recordSignal(.group_permission_denied);
    const result = try gone.outcome(false);
    const text = result.content[0..result.content_len];
    try std.testing.expect(std.mem.indexOf(u8, text, "Process-group signaling reported a failure.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "macOS group signaling returned EPERM") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "original process group was observed absent") != null);
}

test "cleanup ownership transfers consume their source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const baseline: u64 = 41;
    var used: std.atomic.Value(u64) = .init(baseline);
    const budget = ScratchBudget{ .used = &used, .limit = baseline + 6 };
    try std.testing.expect(budget.reserve(6));
    var prepared = Prepared{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .workspace = .{},
        .scratch_path = root,
        .bash_path = "/bin/bash",
        .timeout_ms = 1,
        .faults = .{},
        .script = try createOwnedFile(std.testing.io, root, budget, "script", 1, 1, .none),
        .stdout_capture = try createOwnedFile(std.testing.io, root, budget, "stdout", 1, 1, .none),
        .stderr_capture = try createOwnedFile(std.testing.io, root, budget, "stderr", 1, 1, .none),
    };
    prepared.script.?.charged = 1;
    prepared.stdout_capture.?.charged = 2;
    prepared.stderr_capture.?.charged = 3;

    var cleanup = prepared.takeCleanup();
    try std.testing.expect(prepared.script == null);
    try std.testing.expect(prepared.stdout_capture == null);
    try std.testing.expect(prepared.stderr_capture == null);
    try prepared.cleanup();
    try std.testing.expectEqual(baseline + 6, used.load(.acquire));

    try cleanup.cleanup();
    try std.testing.expect(cleanup.script == null);
    try std.testing.expect(cleanup.stdout_capture == null);
    try std.testing.expect(cleanup.stderr_capture == null);
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

test "prepared cleanup reclaims partially and retries through the same owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const baseline: u64 = 41;
    var used: std.atomic.Value(u64) = .init(baseline);
    const budget = ScratchBudget{ .used = &used, .limit = baseline + 6 };
    try std.testing.expect(budget.reserve(6));
    // Acquire each file before installing the aggregate guard: a later
    // acquisition failure must not leave earlier files unguarded. The
    // per-file guards live in this block so a successful break transfers
    // sole ownership into the aggregate cleanup owner.
    var cleanup: PreparedCleanup = blk: {
        var script = try createOwnedFile(std.testing.io, root, budget, "script", 1, 1, .none);
        errdefer script.cleanup(root) catch {};
        var stdout_capture = try createOwnedFile(std.testing.io, root, budget, "stdout", 1, 1, .persistent);
        errdefer stdout_capture.cleanup(root) catch {};
        var stderr_capture = try createOwnedFile(std.testing.io, root, budget, "stderr", 1, 1, .none);
        errdefer stderr_capture.cleanup(root) catch {};
        break :blk .{
            .scratch_path = root,
            .script = script,
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
        };
    };
    cleanup.script.?.charged = 1;
    cleanup.stdout_capture.?.charged = 2;
    cleanup.stderr_capture.?.charged = 3;
    var complete = false;
    errdefer if (!complete) {
        if (cleanup.stdout_capture) |*file| file.cleanup_fault = .none;
        cleanup.cleanup() catch {};
    };
    // One file fails while the others reclaim: only the residual charge
    // stays with the same owner. Bash removal failure does not retain the
    // same descriptor set as named-scratch failure: the failed descriptor
    // is already closed here.
    try std.testing.expectError(error.InjectedBashCleanupFailure, cleanup.cleanup());
    try std.testing.expect(cleanup.script == null);
    try std.testing.expect(cleanup.stdout_capture != null);
    try std.testing.expect(cleanup.stdout_capture.?.file == null);
    try std.testing.expect(cleanup.stderr_capture == null);
    try std.testing.expect(!cleanup.isComplete());
    try std.testing.expectEqual(baseline + 2, used.load(.acquire));
    // Retry through the same owner releases the residual exactly once.
    cleanup.stdout_capture.?.cleanup_fault = .none;
    try cleanup.cleanup();
    complete = true;
    try std.testing.expect(cleanup.isComplete());
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

test "an owned file closes its descriptor before reporting removal failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    try std.testing.expect(budget.reserve(2));
    var file = try createOwnedFile(std.testing.io, root, budget, "owned", 1, 1, .persistent);
    file.charged = 2;
    // The fault strikes after the descriptor closes: the handle is gone
    // while the charge and the pathname stay with the owner.
    try std.testing.expectError(error.InjectedBashCleanupFailure, file.cleanup(root));
    try std.testing.expect(file.file == null);
    try std.testing.expect(!file.published);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    // An absent private name establishes reclamation once the fault clears:
    // descriptor closure and pathname removal are distinct facts.
    file.cleanup_fault = .none;
    var scratch = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer scratch.close(std.testing.io);
    try scratch.deleteFile(std.testing.io, file.name.slice());
    try file.cleanup(root);
    try std.testing.expect(file.published);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "retired execution is independent of outstanding capture reclamation" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    var execution = Execution{
        .io = std.testing.io,
        .lifecycle = .{
            .process = .{ .gone = .{ .exited = 0 } },
            .pipes = .{ .{ .closed = .eof }, .{ .closed = .eof } },
        },
        .leader = null,
        .pgid = 1,
        .pipes = .{ null, null },
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .script = undefined,
        .scratch_path = "",
        .started = started,
        .timeout_ms = 100,
        .faults = .{},
    };
    // Gone with both pipes closed retires even though capture and script
    // cleanup remain outstanding.
    try std.testing.expect(execution.retired());
    try execution.checkRetired();
    // A closed capture cannot release custody while process/group cleanup is
    // still unconfirmed.
    execution.lifecycle.process = .{ .checking_group = .{
        .term = .{ .exited = 0 },
        .cleanup_deadline = started,
    } };
    try std.testing.expect(!execution.retired());
    try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
    // A running process is not retired regardless of closed pipes, and
    // delivery state never substitutes for this ownership fact.
    execution.lifecycle.process = .{ .running = .{ .deadline = started } };
    try std.testing.expect(!execution.retired());
    try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
}

test "output publication closes producer aliases before making output evictable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 6 };
    var entries: [2]output_retention.Entry = undefined;
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    try std.testing.expect(budget.reserve(6));
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    // Acquire each file before installing the execution guard: a later
    // acquisition failure must not leave earlier files unguarded.
    var execution: Execution = undefined;
    {
        var stdout_capture = try createOwnedFile(std.testing.io, root, budget, "stdout", 1, 1, .none);
        errdefer stdout_capture.cleanup(root) catch {};
        var stderr_capture = try createOwnedFile(std.testing.io, root, budget, "stderr", 1, 1, .none);
        errdefer stderr_capture.cleanup(root) catch {};
        var script = try createOwnedFile(std.testing.io, root, budget, "script", 1, 1, .none);
        errdefer script.cleanup(root) catch {};
        execution = .{
            .io = std.testing.io,
            .lifecycle = .{
                .process = .{ .gone = .{ .exited = 0 } },
                .pipes = .{ .{ .closed = .eof }, .{ .closed = .eof } },
            },
            .leader = null,
            .pgid = 1,
            .pipes = .{ null, null },
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
            .script = script,
            .scratch_path = root,
            .started = started,
            .timeout_ms = 100,
            .faults = .{},
        };
    }
    execution.stdout_capture.charged = 2;
    execution.stderr_capture.charged = 2;
    execution.script.charged = 2;
    var done = false;
    errdefer if (!done) {
        execution.releaseOutputReservation(&retention);
        execution.stdout_capture.cleanup(root) catch {};
        execution.stderr_capture.cleanup(root) catch {};
        execution.script.cleanup(root) catch {};
    };
    try execution.checkRetired();
    // Reserving output records entry charges without touching scratch bytes.
    try std.testing.expect(try execution.reserveOutput(&retention));
    try std.testing.expect(execution.output_reservation != null);
    try std.testing.expectEqual(@as(u64, 6), used.load(.acquire));
    // The ordering boundary is executable, not just a postcondition:
    // publishing with open producer aliases fails and retains the
    // reservation instead of making output evictable while writable.
    try std.testing.expectError(error.ProducerAliasesOpen, execution.publishReservedOutput(&retention));
    try std.testing.expect(execution.output_reservation != null);
    try std.testing.expect(!execution.stdout_capture.published);
    try std.testing.expect(!execution.stderr_capture.published);
    // The reservation holds both entries while the aliases are open.
    try std.testing.expectEqual(@as(usize, 2), retention.occupied());
    // Reclaim closes producer aliases first, then publishes: the names
    // become reclaimable only after the aliases close.
    try execution.reclaim(&retention);
    done = true;
    try std.testing.expect(execution.stdout_capture.file == null);
    try std.testing.expect(execution.stderr_capture.file == null);
    try std.testing.expect(execution.stdout_capture.published);
    try std.testing.expect(execution.stderr_capture.published);
    try std.testing.expectEqual(@as(u64, 4), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), retention.occupied());
    // The published output is evictable through the ordinary queue path.
    retention.cleanupAll();
    try std.testing.expectEqual(@as(usize, 0), retention.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

const ContentSource = struct {
    reader: store.ContentReader,
    length: u64,
    position: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [4096]u8 = undefined,

    pub fn peek(self: *ContentSource) !?u8 {
        if (self.position == self.length) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.length - self.position, self.buffer.len));
            self.buffer_length = try self.reader.read(self.position, self.buffer[0..wanted]);
            if (self.buffer_length != wanted) return error.ShortCanonicalRead;
        }
        return self.buffer[@intCast(self.position - self.buffer_start)];
    }

    pub fn take(self: *ContentSource) !u8 {
        const byte = try self.peek() orelse return error.InvalidDescriptorJson;
        self.position += 1;
        return byte;
    }

    pub fn space(self: *ContentSource) !void {
        while (try self.peek()) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => _ = try self.take(),
            else => return,
        };
    }

    pub fn expect(self: *ContentSource, byte: u8) !void {
        try self.space();
        if (try self.take() != byte) return error.InvalidDescriptorJson;
    }
};

const Utf8Unit = struct {
    source_length: usize,
    encoded_length: usize,
    valid: bool,
};

fn utf8Unit(bytes: []const u8, index: usize) Utf8Unit {
    const sequence_length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    };
    if (index + sequence_length > bytes.len) {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    }
    _ = std.unicode.utf8Decode(bytes[index .. index + sequence_length]) catch {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    };
    return .{ .source_length = sequence_length, .encoded_length = sequence_length, .valid = true };
}

fn validUtf8Length(bytes: []const u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const unit = utf8Unit(bytes, index);
        length += unit.encoded_length;
        index += unit.source_length;
    }
    return length;
}

fn appendValidUtf8Tail(writer: *std.Io.Writer, bytes: []const u8, allowance: usize) !bool {
    var encoded_length = validUtf8Length(bytes);
    var start: usize = 0;
    while (encoded_length > allowance) {
        const unit = utf8Unit(bytes, start);
        encoded_length -= unit.encoded_length;
        start += unit.source_length;
    }
    var index = start;
    while (index < bytes.len) {
        const unit = utf8Unit(bytes, index);
        if (unit.valid) {
            try writer.writeAll(bytes[index .. index + unit.source_length]);
        } else {
            try writer.writeAll("�");
        }
        index += unit.source_length;
    }
    return start != 0;
}

test "UTF-8 excerpt keeps the newest source and reports replacement expansion" {
    var source: [5000]u8 = @splat(0xff);
    source[source.len - 1] = '!';
    var output: [excerpt_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expect(try appendValidUtf8Tail(&writer, &source, excerpt_bytes));
    const written = writer.buffered();
    try std.testing.expect(written.len <= excerpt_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(written));
    try std.testing.expectEqual(@as(u8, '!'), written[written.len - 1]);
}

test "Bash descriptor decoding preserves authorized command bytes" {
    const Source = struct {
        bytes: []const u8,
        position: usize = 0,

        pub fn peek(self: *@This()) !?u8 {
            return if (self.position == self.bytes.len) null else self.bytes[self.position];
        }
        pub fn take(self: *@This()) !u8 {
            const byte = try self.peek() orelse return error.InvalidDescriptorJson;
            self.position += 1;
            return byte;
        }
        pub fn space(self: *@This()) !void {
            while (try self.peek()) |byte| switch (byte) {
                ' ', '\t', '\r', '\n' => self.position += 1,
                else => return,
            };
        }
        pub fn expect(self: *@This(), byte: u8) !void {
            try self.space();
            if (try self.take() != byte) return error.InvalidDescriptorJson;
        }
    };
    var source = Source{ .bytes = "{\"cmd\":\"false && \\u0074ouch marker\",\"description\":\"Check conditional marker creation\",\"timeout_ms\":null}" };
    var output_buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expect(try tools.writeBashCommand(&source, &writer));
    try std.testing.expectEqualStrings("false && touch marker", writer.buffered());

    var override = Source{ .bytes = "{\"timeout_ms\":17,\"description\":\"Print confirmation\",\"cmd\":\"echo ok\"}" };
    const inspected = (try tools.inspectBashArguments(&override)).?;
    try std.testing.expectEqual(@as(?u64, 17), inspected.timeout_ms);
    inline for (.{
        "{\"description\":\"Print output\",\"cmd\":\"echo\\u0000bad\",\"timeout_ms\":null}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\"}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":0}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":9223372036854775808}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":1.5}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",}",
    }) |invalid| {
        var invalid_source = Source{ .bytes = invalid };
        try std.testing.expect(!try tools.validBashArguments(&invalid_source));
    }
}
