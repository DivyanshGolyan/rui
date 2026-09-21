const std = @import("std");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");

pub const excerpt_bytes: usize = 10_000;
pub const copy_window_bytes: usize = 16 * 1024;
const command_write_window_bytes: usize = 4096;
const termination_grace_ms: u64 = 100;
const cleanup_observation_ms: u64 = 5_000;
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

const CaptureFailure = enum { none, read, write, exhausted, seal };
const StopReason = enum { none, stopped, timed_out, infrastructure_shutdown, capture_failed };

const Term = union(enum) {
    exited: u8,
    signal: u8,
    unknown: u32,
};

const AnchoredChild = struct {
    child: std.process.Child,
    pgid: std.process.Child.Id,
    observed: ?Term = null,
};

const ReapOwner = struct {
    child: std.process.Child,
    pgid: std.process.Child.Id,
    observed: ?Term,
};

const Process = union(enum) {
    running: struct {
        anchor: AnchoredChild,
        deadline: std.Io.Clock.Timestamp,
    },
    grace: struct {
        anchor: AnchoredChild,
        kill_at: std.Io.Clock.Timestamp,
        cleanup_deadline: std.Io.Clock.Timestamp,
    },
    reaping: struct {
        owner: ReapOwner,
        cleanup_deadline: std.Io.Clock.Timestamp,
    },
    checking_group: struct {
        pgid: std.process.Child.Id,
        term: Term,
        cleanup_deadline: std.Io.Clock.Timestamp,
    },
    gone: Term,
};

const PipeClose = enum { eof, incomplete, failed };
const CleanupFault = enum { none, persistent, gated };

const Pipe = union(enum) {
    reading: std.Io.File,
    tail: struct {
        file: std.Io.File,
        remaining: u64,
    },
    closed: PipeClose,
};

fn addMilliseconds(timestamp: std.Io.Clock.Timestamp, milliseconds: u64) std.Io.Clock.Timestamp {
    return timestamp.addDuration(.{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    });
}

fn timestampReached(now: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp) bool {
    return now.raw.nanoseconds >= deadline.raw.nanoseconds;
}

fn pipeClosed(pipe: Pipe) bool {
    return pipe == .closed;
}

fn pipeIncomplete(pipe: Pipe) bool {
    return switch (pipe) {
        .closed => |reason| reason != .eof,
        else => true,
    };
}

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
        var execution = Execution{
            .io = self.io,
            .process = .{ .running = .{
                .anchor = .{ .child = child, .pgid = child.id.? },
                .deadline = undefined,
            } },
            .stdout_pipe = .{ .reading = stdout_pipe },
            .stderr_pipe = .{ .reading = stderr_pipe },
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
            .script = script,
            .scratch_path = self.scratch_path,
            .started = started,
            .faults = self.faults,
        };
        execution.process.running.deadline = execution.started.addDuration(.{
            .raw = .fromMilliseconds(@intCast(self.timeout_ms)),
            .clock = .awake,
        });
        return execution;
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
    process: Process,
    stdout_pipe: Pipe,
    stderr_pipe: Pipe,
    stdout_capture: OwnedFile,
    stderr_capture: OwnedFile,
    script: OwnedFile,
    scratch_path: []const u8,
    started: std.Io.Clock.Timestamp,
    faults: Faults,
    stop_reason: StopReason = .none,
    capture_failure: CaptureFailure = .none,
    signal_failure: bool = false,
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

    pub fn requestStop(self: *Execution) TerminationAttempt {
        const attempted = self.process == .running;
        self.requestTermination(.stopped);
        return .{ .attempted = attempted, .signal_failed = self.signal_failure };
    }

    pub fn requestInfrastructureShutdown(self: *Execution) void {
        self.requestTermination(.infrastructure_shutdown);
    }

    pub fn applyDueDeadline(self: *Execution, now: std.Io.Clock.Timestamp) ?TimeoutAction {
        if (self.process != .running or !timestampReached(now, self.process.running.deadline)) return null;
        const deadline_ns: u64 = @intCast(self.process.running.deadline.raw.nanoseconds);
        if (self.stop_reason == .none) self.stop_reason = .timed_out;
        self.beginGrace(now);
        return .{ .deadline_ns = deadline_ns, .signal_failed = self.signal_failure };
    }

    pub const ServiceResult = struct {
        made_progress: bool,
        retired: bool,
        leader_observed_with_open_pipes: bool,
        timeout_action: ?TimeoutAction,
        fault: ?anyerror,
    };

    pub fn service(self: *Execution, window: []u8) ServiceResult {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        return self.serviceAt(window, now, .live);
    }

    fn serviceAt(self: *Execution, window: []u8, now: std.Io.Clock.Timestamp, source: ObservationSource) ServiceResult {
        std.debug.assert(window.len == copy_window_bytes);
        var fault: ?anyerror = null;
        if (self.faults.service and !self.service_fault_used) {
            self.service_fault_used = true;
            fault = error.InjectedBashServiceFailure;
            self.requestTerminationAt(.infrastructure_shutdown, now);
        }
        var made_progress = false;
        const timeout_action = self.applyDueDeadline(now);
        if (timeout_action != null) made_progress = true;
        const leader_observed = self.observeLeader(now, source) catch |err| observed: {
            fault = fault orelse err;
            self.requestTerminationAt(.infrastructure_shutdown, now);
            break :observed false;
        };
        made_progress = leader_observed or made_progress;
        if (self.process == .running and self.process.running.anchor.observed != null) {
            self.beginGrace(now);
            made_progress = true;
        }
        made_progress = self.freezeCaptureIfRequired(now, &fault) or made_progress;
        made_progress = self.servicePipe(&self.stdout_pipe, &self.stdout_capture, window, &fault) or made_progress;
        made_progress = self.servicePipe(&self.stderr_pipe, &self.stderr_capture, window, &fault) or made_progress;
        if (self.process == .grace and timestampReached(now, self.process.grace.kill_at)) {
            self.finishSignaling();
            made_progress = true;
        }
        made_progress = (self.reapLeader(now) catch |err| reaped: {
            fault = fault orelse err;
            break :reaped false;
        }) or made_progress;
        if (self.process == .checking_group) {
            const check = if (self.lifecycleFaultActive(.group_probe)) check: {
                fault = fault orelse error.InjectedBashGroupProbeFailure;
                break :check 0;
            } else if (self.lifecycleFaultActive(.cleanup_watchdog))
                0
            else
                rui_bash_group_absent(self.process.checking_group.pgid);
            if (check == 1) {
                const term = self.process.checking_group.term;
                self.process = .{ .gone = term };
                made_progress = true;
            } else if (check < 0) {
                fault = fault orelse error.BashGroupProbeFailed;
            }
        }
        made_progress = self.freezeCaptureIfRequired(now, &fault) or made_progress;
        if (self.process == .gone) {
            made_progress = self.servicePipe(&self.stdout_pipe, &self.stdout_capture, window, &fault) or made_progress;
            made_progress = self.servicePipe(&self.stderr_pipe, &self.stderr_capture, window, &fault) or made_progress;
        }
        return .{
            .made_progress = made_progress,
            .retired = self.retired(),
            .leader_observed_with_open_pipes = leader_observed and
                (!pipeClosed(self.stdout_pipe) or !pipeClosed(self.stderr_pipe)),
            .timeout_action = timeout_action,
            .fault = fault,
        };
    }

    pub fn deadlineNs(self: *const Execution) u64 {
        return switch (self.process) {
            .running => |value| @intCast(value.deadline.raw.nanoseconds),
            else => unreachable,
        };
    }

    pub fn retired(self: *const Execution) bool {
        return self.process == .gone and pipeClosed(self.stdout_pipe) and pipeClosed(self.stderr_pipe);
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
        self.stdout_capture.file.?.sync(self.io) catch {
            self.capture_failure = .seal;
        };
        self.stderr_capture.file.?.sync(self.io) catch {
            self.capture_failure = .seal;
        };
        if (self.faults.seal) self.capture_failure = .seal;
        const code: store.ActionResolutionCode = switch (self.stop_reason) {
            .stopped => .cancelled,
            .timed_out => .timed_out,
            .infrastructure_shutdown => .infrastructure_shutdown,
            .capture_failed => .storage_failed,
            .none => if (self.capture_failure != .none)
                .storage_failed
            else switch (self.process.gone) {
                .exited => |exit_code| if (exit_code == 0) .succeeded else .failed,
                else => .failed,
            },
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
        if (self.output_reservation) |pair| {
            // Reserved entries are protected from eviction. Relinquish the
            // producer aliases before publication makes the names reclaimable.
            self.stdout_capture.close();
            self.stderr_capture.close();
            retention.publishPair(pair) catch |err| {
                first_error = err;
            };
            if (first_error == null) {
                self.output_reservation = null;
                self.stdout_capture.published = true;
                self.stderr_capture.published = true;
            }
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

    fn servicePipe(
        self: *Execution,
        pipe_slot: *Pipe,
        destination: *OwnedFile,
        window: []u8,
        fault: *?anyerror,
    ) bool {
        return self.readPipe(pipe_slot, destination, window) catch |err| {
            fault.* = fault.* orelse err;
            self.capture_failure = .read;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
            return true;
        };
    }

    fn requestTermination(self: *Execution, reason: StopReason) void {
        self.requestTerminationAt(reason, std.Io.Clock.Timestamp.now(self.io, .awake));
    }

    fn requestTerminationAt(self: *Execution, reason: StopReason, now: std.Io.Clock.Timestamp) void {
        if (self.stop_reason == .none) self.stop_reason = reason;
        if (self.process == .running) self.beginGrace(now);
    }

    fn beginGrace(self: *Execution, now: std.Io.Clock.Timestamp) void {
        const running = self.process.running;
        self.signalAnchored(&running.anchor, .TERM);
        self.process = .{ .grace = .{
            .anchor = running.anchor,
            .kill_at = addMilliseconds(now, termination_grace_ms),
            .cleanup_deadline = addMilliseconds(now, cleanup_observation_ms),
        } };
    }

    fn finishSignaling(self: *Execution) void {
        const grace = self.process.grace;
        self.signalAnchored(&grace.anchor, .KILL);
        if (grace.anchor.observed == null) self.signalPid(grace.anchor.child.id.?, .KILL);
        self.process = .{ .reaping = .{
            .owner = .{
                .child = grace.anchor.child,
                .pgid = grace.anchor.pgid,
                .observed = grace.anchor.observed,
            },
            .cleanup_deadline = grace.cleanup_deadline,
        } };
    }

    fn signalAnchored(self: *Execution, anchor: *const AnchoredChild, signal_value: std.posix.SIG) void {
        if (self.faults.lifecycle == .signal) {
            self.signal_failure = true;
            return;
        }
        std.posix.kill(-anchor.pgid, signal_value) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => self.signal_failure = true,
        };
    }

    fn signalPid(self: *Execution, child_id: std.process.Child.Id, signal_value: std.posix.SIG) void {
        if (self.faults.lifecycle == .signal) {
            self.signal_failure = true;
            return;
        }
        std.posix.kill(child_id, signal_value) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => self.signal_failure = true,
        };
    }

    fn readPipe(
        self: *Execution,
        pipe_slot: *Pipe,
        destination: *OwnedFile,
        window: []u8,
    ) !bool {
        if (pipe_slot.* == .closed) return false;
        if (pipe_slot.* == .tail) return self.readTail(pipe_slot, destination, window);
        const pipe = pipe_slot.reading;
        var descriptor = [_]std.posix.pollfd{.{
            .fd = pipe.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptor, 0) == 0) return false;
        const reserved: usize = @intCast(destination.budget.reserveUpTo(window.len));
        if (reserved == 0) {
            var probe: [1]u8 = undefined;
            const count = std.posix.read(pipe.handle, &probe) catch |err| {
                if (err == error.WouldBlock) return false;
                self.capture_failure = .read;
                self.requestTermination(.capture_failed);
                self.closePipe(pipe_slot, .failed);
                return true;
            };
            if (count == 0) {
                self.closePipe(pipe_slot, .eof);
                return true;
            }
            self.capture_failure = .exhausted;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
            return true;
        }
        const count = std.posix.read(pipe.handle, window[0..reserved]) catch |err| {
            destination.budget.release(reserved);
            if (err == error.WouldBlock) return false;
            self.capture_failure = .read;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
            return true;
        };
        if (count < reserved) destination.budget.release(reserved - count);
        if (count == 0) {
            self.closePipe(pipe_slot, .eof);
            return true;
        }
        if (self.faults.capture_read and !self.read_fault_used) {
            self.read_fault_used = true;
            destination.budget.release(count);
            self.capture_failure = .read;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
            return true;
        }
        destination.charged += count;
        if (self.faults.capture_write) {
            self.capture_failure = .write;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
            return true;
        }
        destination.file.?.writeStreamingAll(self.io, window[0..count]) catch {
            self.capture_failure = .write;
            self.requestTermination(.capture_failed);
            self.closePipe(pipe_slot, .failed);
        };
        return true;
    }

    fn observeLeader(self: *Execution, now: std.Io.Clock.Timestamp, source: ObservationSource) !bool {
        const anchor = switch (self.process) {
            .running => |*value| &value.anchor,
            .grace => |*value| &value.anchor,
            .reaping, .checking_group, .gone => return false,
        };
        if (anchor.observed != null) return false;
        switch (source) {
            .none => return false,
            .observed => |term| {
                anchor.observed = term;
                return true;
            },
            .failed => return error.BashObserveFailed,
            .live => {},
        }
        if (self.lifecycleFaultActive(.observe) and
            timestampReached(now, addMilliseconds(self.started, fault_observation_delay_ms)))
        {
            return error.InjectedBashObserveFailure;
        }
        var observation: BashObservation = undefined;
        const result = rui_bash_observe(anchor.child.id.?, &observation);
        if (result < 0) return error.BashObserveFailed;
        if (result == 0) return false;
        anchor.observed = decodeObservation(observation);
        return true;
    }

    fn reapLeader(self: *Execution, now: std.Io.Clock.Timestamp) !bool {
        if (self.process != .reaping) return false;
        if (self.lifecycleFaultActive(.reap)) return error.InjectedBashReapFailure;
        var reaping = self.process.reaping;
        const child_id = reaping.owner.child.id.?;
        var observation: BashObservation = undefined;
        const result = if (self.lifecycleFaultActive(.reap_watchdog))
            0
        else
            rui_bash_reap(child_id, &observation);
        if (result == 0) {
            if (timestampReached(now, reaping.cleanup_deadline)) return error.BashCleanupUnconfirmed;
            return false;
        }
        if (result < 0) return error.BashWaitFailed;
        reaping.owner.child.id = null;
        const term = decodeObservation(observation);
        self.process = .{ .checking_group = .{
            .pgid = reaping.owner.pgid,
            .term = reaping.owner.observed orelse term,
            .cleanup_deadline = reaping.cleanup_deadline,
        } };
        if (reaping.owner.observed) |observed| {
            if (!std.meta.eql(observed, term)) return error.BashStatusChanged;
        }
        return true;
    }

    fn lifecycleFaultActive(self: *const Execution, expected: LifecycleFault) bool {
        if (self.faults.lifecycle != expected) return false;
        if (!self.faults.fault_gated) return true;
        return faultGateActive(self.io, self.scratch_path);
    }

    fn freezeCaptureIfRequired(
        self: *Execution,
        now: std.Io.Clock.Timestamp,
        fault: *?anyerror,
    ) bool {
        const deadline_expired = switch (self.process) {
            .grace => |value| timestampReached(now, value.cleanup_deadline),
            .reaping => |value| timestampReached(now, value.cleanup_deadline),
            .checking_group => |value| timestampReached(now, value.cleanup_deadline),
            .running, .gone => false,
        };
        if (self.process != .gone and !deadline_expired) return false;
        const changed = self.stdout_pipe == .reading or self.stderr_pipe == .reading;
        self.beginCaptureTails() catch |err| {
            fault.* = fault.* orelse err;
        };
        if (deadline_expired and self.process != .gone) {
            fault.* = fault.* orelse error.BashCleanupUnconfirmed;
        }
        return changed;
    }

    fn beginCaptureTails(self: *Execution) !void {
        try self.beginCaptureTail(&self.stdout_pipe);
        try self.beginCaptureTail(&self.stderr_pipe);
    }

    fn beginCaptureTail(self: *Execution, pipe_slot: *Pipe) !void {
        if (pipe_slot.* != .reading) return;
        const pipe = pipe_slot.reading;
        var queued: u64 = 0;
        if (self.faults.lifecycle == .tail_snapshot or
            rui_bash_pipe_queued_bytes(pipe.handle, &queued) < 0)
        {
            self.closePipe(pipe_slot, .failed);
            self.capture_failure = .read;
            return;
        }
        pipe_slot.* = .{ .tail = .{ .file = pipe, .remaining = queued } };
    }

    fn readTail(
        self: *Execution,
        pipe_slot: *Pipe,
        destination: *OwnedFile,
        window: []u8,
    ) !bool {
        var tail = pipe_slot.tail;
        if (tail.remaining == 0) {
            var descriptor = [_]std.posix.pollfd{.{
                .fd = tail.file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            if (try std.posix.poll(&descriptor, 0) == 0) {
                self.closePipe(pipe_slot, .incomplete);
                return true;
            }
            var probe: [1]u8 = undefined;
            const count = std.posix.read(tail.file.handle, &probe) catch |err| {
                if (err == error.WouldBlock) {
                    self.closePipe(pipe_slot, .incomplete);
                    return true;
                }
                self.capture_failure = .read;
                self.closePipe(pipe_slot, .failed);
                return true;
            };
            self.closePipe(pipe_slot, if (count == 0) .eof else .incomplete);
            return true;
        }
        const wanted: usize = @intCast(@min(tail.remaining, window.len));
        const reserved: usize = @intCast(destination.budget.reserveUpTo(wanted));
        if (reserved == 0) {
            self.capture_failure = .exhausted;
            self.closePipe(pipe_slot, .failed);
            return true;
        }
        const count = std.posix.read(tail.file.handle, window[0..reserved]) catch |err| {
            destination.budget.release(reserved);
            if (err == error.WouldBlock) return false;
            self.capture_failure = .read;
            self.closePipe(pipe_slot, .failed);
            return true;
        };
        if (count < reserved) destination.budget.release(reserved - count);
        if (count == 0) {
            self.capture_failure = .read;
            self.closePipe(pipe_slot, .failed);
            return true;
        }
        destination.charged += count;
        destination.file.?.writeStreamingAll(self.io, window[0..count]) catch {
            self.capture_failure = .write;
            self.closePipe(pipe_slot, .failed);
            return true;
        };
        tail.remaining -= count;
        pipe_slot.* = .{ .tail = tail };
        return true;
    }

    fn closePipe(self: *Execution, pipe_slot: *Pipe, reason: PipeClose) void {
        switch (pipe_slot.*) {
            .reading => |pipe| pipe.close(self.io),
            .tail => |tail| tail.file.close(self.io),
            .closed => return,
        }
        pipe_slot.* = .{ .closed = reason };
    }

    fn formatResult(
        self: *Execution,
        writer: *std.Io.Writer,
        code: store.ActionResolutionCode,
        include_paths: bool,
    ) !void {
        try writer.print("Bash {s}. ", .{@tagName(code)});
        switch (self.process.gone) {
            .exited => |exit_code| try writer.print("Exit code: {d}.\n", .{exit_code}),
            .signal => |signal_value| try writer.print("Signal: {d}.\n", .{signal_value}),
            .unknown => |status| try writer.print("Unknown process status: {d}.\n", .{status}),
        }
        if (self.capture_failure != .none) {
            try writer.print("Capture failure: {s}; output may be incomplete.\n", .{@tagName(self.capture_failure)});
        } else if (pipeIncomplete(self.stdout_pipe) or pipeIncomplete(self.stderr_pipe)) {
            try writer.writeAll("Capture may be incomplete because writers outlived process-group termination.\n");
        }
        if (self.signal_failure) try writer.writeAll("Process-group signaling reported a failure.\n");
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

test "a due deadline starts termination from a later service-time observation" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    const deadline = started.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    var execution = Execution{
        .io = std.testing.io,
        .process = .{ .running = .{
            .anchor = .{
                .child = undefined,
                .pgid = 1,
            },
            .deadline = deadline,
        } },
        .stdout_pipe = .{ .closed = .eof },
        .stderr_pipe = .{ .closed = .eof },
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .script = undefined,
        .scratch_path = "",
        .started = started,
        .faults = .{ .lifecycle = .signal },
    };
    const before = started.addDuration(.{ .raw = .fromMilliseconds(99), .clock = .awake });
    try std.testing.expect(execution.applyDueDeadline(before) == null);
    try std.testing.expect(execution.process == .running);
    const after = started.addDuration(.{ .raw = .fromMilliseconds(101), .clock = .awake });
    const action = execution.applyDueDeadline(after).?;
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), action.deadline_ns);
    try std.testing.expect(action.signal_failed);
    try std.testing.expect(execution.process == .grace);
    try std.testing.expectEqual(StopReason.timed_out, execution.stop_reason);
}

fn runningWithDeadline(started: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp) Execution {
    return .{
        .io = std.testing.io,
        .process = .{ .running = .{
            .anchor = .{
                .child = undefined,
                .pgid = 1,
            },
            .deadline = deadline,
        } },
        .stdout_pipe = .{ .closed = .eof },
        .stderr_pipe = .{ .closed = .eof },
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .script = undefined,
        .scratch_path = "",
        .started = started,
        // Signaling is faulted to a no-op so no real process is signaled.
        .faults = .{ .lifecycle = .signal },
    };
}

test "service acts on its service-time observation rather than an earlier one" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    const deadline = started.addDuration(.{ .raw = .fromMilliseconds(20), .clock = .awake });
    // A pre-work observation is before the deadline: no timeout.
    const before = started.addDuration(.{ .raw = .fromMilliseconds(1), .clock = .awake });
    var execution = runningWithDeadline(started, deadline);
    try std.testing.expect(execution.applyDueDeadline(before) == null);
    try std.testing.expect(execution.process == .running);
    // The service-time observation is after the deadline: the real owner
    // requests termination through the production service path. No clock is
    // sampled and no syscall runs; both observations are explicit inputs.
    const after = started.addDuration(.{ .raw = .fromMilliseconds(21), .clock = .awake });
    var window: [copy_window_bytes]u8 = undefined;
    const result = execution.serviceAt(&window, after, .none);
    const timeout = result.timeout_action orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(u64, @intCast(deadline.raw.nanoseconds)), timeout.deadline_ns);
    try std.testing.expect(result.fault == null);
    try std.testing.expect(result.made_progress);
    try std.testing.expect(!result.retired);
    try std.testing.expect(execution.process == .grace);
    try std.testing.expectEqual(StopReason.timed_out, execution.stop_reason);
    // Substituting the earlier observation performs no timeout.
    var stale = runningWithDeadline(started, deadline);
    const idle = stale.serviceAt(&window, before, .none);
    try std.testing.expect(idle.timeout_action == null);
    try std.testing.expect(idle.fault == null);
    try std.testing.expect(stale.process == .running);
    // A failed observation is reported without a timeout, and the grace
    // deadlines derive from the supplied service-time observation.
    var unobservable = runningWithDeadline(started, deadline);
    const failed = unobservable.serviceAt(&window, before, .failed);
    try std.testing.expect(failed.timeout_action == null);
    try std.testing.expect(failed.fault.? == error.BashObserveFailed);
    try std.testing.expectEqual(StopReason.infrastructure_shutdown, unobservable.stop_reason);
    const grace = unobservable.process.grace;
    try std.testing.expectEqual(
        before.raw.nanoseconds + termination_grace_ms * std.time.ns_per_ms,
        grace.kill_at.raw.nanoseconds,
    );
    try std.testing.expectEqual(
        before.raw.nanoseconds + cleanup_observation_ms * std.time.ns_per_ms,
        grace.cleanup_deadline.raw.nanoseconds,
    );
    // An observed leader retires the running state without a deadline.
    var witnessed = runningWithDeadline(started, deadline);
    const seen = witnessed.serviceAt(&window, before, .{ .observed = .{ .exited = 0 } });
    try std.testing.expect(seen.timeout_action == null);
    try std.testing.expect(seen.fault == null);
    try std.testing.expect(witnessed.process == .grace);
}

test "cleanup ownership transfers consume their source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 6 };
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
    try std.testing.expectEqual(@as(u64, 6), used.load(.acquire));

    try cleanup.cleanup();
    try std.testing.expect(cleanup.script == null);
    try std.testing.expect(cleanup.stdout_capture == null);
    try std.testing.expect(cleanup.stderr_capture == null);
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
    var source = Source{ .bytes = "{\"cmd\":\"false && \\u0074ouch marker\",\"timeout_ms\":null}" };
    var output_buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expect(try tools.writeBashCommand(&source, &writer));
    try std.testing.expectEqualStrings("false && touch marker", writer.buffered());

    var override = Source{ .bytes = "{\"timeout_ms\":17,\"cmd\":\"echo ok\"}" };
    const inspected = (try tools.inspectBashArguments(&override)).?;
    try std.testing.expectEqual(@as(?u64, 17), inspected.timeout_ms);
    inline for (.{
        "{\"cmd\":\"echo\\u0000bad\",\"timeout_ms\":null}",
        "{\"cmd\":\"echo\"}",
        "{\"cmd\":\"echo\",\"timeout_ms\":0}",
        "{\"cmd\":\"echo\",\"timeout_ms\":9223372036854775808}",
        "{\"cmd\":\"echo\",\"timeout_ms\":1.5}",
        "{\"cmd\":\"echo\",}",
    }) |invalid| {
        var invalid_source = Source{ .bytes = invalid };
        try std.testing.expect(!try tools.validBashArguments(&invalid_source));
    }
}
