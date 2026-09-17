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
    cleanup_fault: bool = false,

    fn close(self: *OwnedFile) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    fn cleanup(self: *OwnedFile, scratch_path: []const u8) !void {
        self.close();
        if (self.published) return;
        if (self.cleanup_fault) return error.InjectedBashCleanupFailure;
        var scratch = try std.Io.Dir.cwd().openDir(self.io, scratch_path, .{});
        defer scratch.close(self.io);
        try scratch.deleteFile(self.io, self.name.slice());
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
    script: OwnedFile,
    stdout_capture: OwnedFile,
    stderr_capture: OwnedFile,

    pub fn cleanup(self: *Prepared) !void {
        return cleanupOwnedFiles(
            self.scratch_path,
            &self.script,
            &self.stdout_capture,
            &self.stderr_capture,
        );
    }

    pub fn cleanupOwner(self: *const Prepared) PreparedCleanup {
        return .{
            .scratch_path = self.scratch_path,
            .script = self.script,
            .stdout_capture = self.stdout_capture,
            .stderr_capture = self.stderr_capture,
        };
    }

    pub fn launch(self: *Prepared) !Execution {
        if (self.faults.spawn) return error.BashSpawnFailed;
        var script_path_buffer: [platform.max_scratch_path_bytes + 1 + 96]u8 = undefined;
        const script_path = try std.fmt.bufPrint(
            &script_path_buffer,
            "{s}/{s}",
            .{ self.scratch_path, self.script.name.slice() },
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
        var execution = Execution{
            .io = self.io,
            .process = .{ .running = .{
                .anchor = .{ .child = child, .pgid = child.id.? },
                .deadline = undefined,
            } },
            .stdout_pipe = .{ .reading = stdout_pipe },
            .stderr_pipe = .{ .reading = stderr_pipe },
            .stdout_capture = self.stdout_capture,
            .stderr_capture = self.stderr_capture,
            .script = self.script,
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
        var first_error: ?anyerror = null;
        inline for (.{ &self.script, &self.stdout_capture, &self.stderr_capture }) |slot| {
            if (slot.*) |*file| file.cleanup(self.scratch_path) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| return err;
    }
};

pub const PreparationFailure = struct {
    cause: anyerror,
    cleanup: PreparedCleanup,
};

pub const PrepareResult = union(enum) {
    prepared: Prepared,
    failed: PreparationFailure,
};

fn cleanupOwnedFiles(
    scratch_path: []const u8,
    script: *OwnedFile,
    stdout_capture: *OwnedFile,
    stderr_capture: *OwnedFile,
) !void {
    var first_error: ?anyerror = null;
    script.cleanup(scratch_path) catch |err| {
        first_error = err;
    };
    stdout_capture.cleanup(scratch_path) catch |err| if (first_error == null) {
        first_error = err;
    };
    stderr_capture.cleanup(scratch_path) catch |err| if (first_error == null) {
        first_error = err;
    };
    if (first_error) |err| return err;
}

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

    pub fn requestStop(self: *Execution) void {
        self.requestTermination(.stopped);
    }

    pub fn requestInfrastructureShutdown(self: *Execution) void {
        self.requestTermination(.infrastructure_shutdown);
    }

    pub const ServiceResult = struct {
        made_progress: bool,
        complete: bool,
    };

    pub fn service(self: *Execution, window: []u8, shutdown: bool) !ServiceResult {
        std.debug.assert(window.len == copy_window_bytes);
        if (self.faults.service and !self.service_fault_used) {
            self.service_fault_used = true;
            return error.InjectedBashServiceFailure;
        }
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        var made_progress = false;
        if (shutdown) self.requestTermination(.infrastructure_shutdown);
        if (self.process == .running and timestampReached(now, self.process.running.deadline)) {
            self.requestTermination(.timed_out);
            made_progress = true;
        }
        made_progress = try self.observeLeader() or made_progress;
        if (self.process == .running and self.process.running.anchor.observed != null) {
            self.beginGrace(now);
            made_progress = true;
        }
        made_progress = try self.readPipe(&self.stdout_pipe, &self.stdout_capture, window) or made_progress;
        made_progress = try self.readPipe(&self.stderr_pipe, &self.stderr_capture, window) or made_progress;
        if (self.process == .grace and timestampReached(now, self.process.grace.kill_at)) {
            self.finishSignaling();
            made_progress = true;
        }
        made_progress = try self.reapLeader(now) or made_progress;
        if (self.process == .checking_group) {
            if (self.faults.lifecycle == .group_probe) return error.InjectedBashGroupProbeFailure;
            const check = if (self.faults.lifecycle == .cleanup_watchdog)
                0
            else
                rui_bash_group_absent(self.process.checking_group.pgid);
            if (check == 1) {
                const term = self.process.checking_group.term;
                self.process = .{ .gone = term };
                try self.beginCaptureTails();
                made_progress = true;
            } else if (check < 0) {
                return error.BashGroupProbeFailed;
            } else if (timestampReached(now, self.process.checking_group.cleanup_deadline)) {
                return error.BashCleanupUnconfirmed;
            }
        }
        if (self.process == .gone) {
            made_progress = try self.readPipe(&self.stdout_pipe, &self.stdout_capture, window) or made_progress;
            made_progress = try self.readPipe(&self.stderr_pipe, &self.stderr_capture, window) or made_progress;
        }
        return .{
            .made_progress = made_progress,
            .complete = self.process == .gone and pipeClosed(self.stdout_pipe) and pipeClosed(self.stderr_pipe),
        };
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

    pub fn releaseOutput(self: *Execution, retention: *output_retention.Queue) !void {
        self.stdout_capture.close();
        self.stderr_capture.close();
        if (self.output_reservation) |pair| {
            try retention.publishPair(pair);
            self.output_reservation = null;
            self.stdout_capture.published = true;
            self.stderr_capture.published = true;
            return;
        }
        try self.stdout_capture.cleanup(self.scratch_path);
        try self.stderr_capture.cleanup(self.scratch_path);
    }

    pub fn cleanup(self: *Execution) !void {
        var window: [copy_window_bytes]u8 = undefined;
        while (true) {
            const result = try self.service(&window, true);
            if (result.complete) break;
            _ = self.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        var first_error: ?anyerror = null;
        self.script.cleanup(self.scratch_path) catch |err| {
            first_error = err;
        };
        self.stdout_capture.cleanup(self.scratch_path) catch |err| if (first_error == null) {
            first_error = err;
        };
        self.stderr_capture.cleanup(self.scratch_path) catch |err| if (first_error == null) {
            first_error = err;
        };
        if (first_error) |err| return err;
    }

    fn requestTermination(self: *Execution, reason: StopReason) void {
        if (self.stop_reason == .none) self.stop_reason = reason;
        if (self.process == .running) self.beginGrace(std.Io.Clock.Timestamp.now(self.io, .awake));
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

    fn observeLeader(self: *Execution) !bool {
        if (self.faults.lifecycle == .observe) return error.InjectedBashObserveFailure;
        const anchor = switch (self.process) {
            .running => |*value| &value.anchor,
            .grace => |*value| &value.anchor,
            .reaping, .checking_group, .gone => return false,
        };
        if (anchor.observed != null) return false;
        var observation: BashObservation = undefined;
        const result = rui_bash_observe(anchor.child.id.?, &observation);
        if (result < 0) return error.BashObserveFailed;
        if (result == 0) return false;
        anchor.observed = decodeObservation(observation);
        return true;
    }

    fn reapLeader(self: *Execution, now: std.Io.Clock.Timestamp) !bool {
        if (self.process != .reaping) return false;
        if (self.faults.lifecycle == .reap) return error.InjectedBashReapFailure;
        var reaping = self.process.reaping;
        const child_id = reaping.owner.child.id.?;
        var observation: BashObservation = undefined;
        const result = if (self.faults.lifecycle == .reap_watchdog)
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
        if (reaping.owner.observed) |observed| {
            if (!std.meta.eql(observed, term)) return error.BashStatusChanged;
        }
        self.process = .{ .checking_group = .{
            .pgid = reaping.owner.pgid,
            .term = reaping.owner.observed orelse term,
            .cleanup_deadline = reaping.cleanup_deadline,
        } };
        return true;
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

pub fn prepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *store.ContentReader,
    arguments_length: u64,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    scratch_path: []const u8,
    bash_path: []const u8,
    timeout_ms: u64,
    budget: ScratchBudget,
    action_id: u64,
    attempt_ordinal: u64,
    faults: Faults,
) PrepareResult {
    var cleanup = PreparedCleanup{ .scratch_path = scratch_path };
    if (faults.preparation) {
        return .{ .failed = .{ .cause = error.BashPreparationFailed, .cleanup = cleanup } };
    }
    cleanup.script = createOwnedFile(
        io,
        scratch_path,
        budget,
        "bash-input",
        action_id,
        attempt_ordinal,
        faults.cleanup,
    ) catch |err| return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    if (faults.preparation_after_script) {
        return .{ .failed = .{ .cause = error.BashPreparationFailed, .cleanup = cleanup } };
    }
    var source = ContentSource{ .reader = reader, .length = arguments_length };
    var destination = CommandWriter{ .file = &cleanup.script.? };
    const valid = tools.writeBashCommand(&source, &destination) catch |err|
        return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    if (!valid) {
        return .{ .failed = .{ .cause = error.InvalidCanonicalBashDescriptor, .cleanup = cleanup } };
    }
    destination.finish() catch |err|
        return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    cleanup.script.?.file.?.sync(io) catch |err|
        return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    cleanup.stdout_capture = createOwnedFile(
        io,
        scratch_path,
        budget,
        "bash-stdout",
        action_id,
        attempt_ordinal,
        faults.cleanup,
    ) catch |err| return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    cleanup.stderr_capture = createOwnedFile(
        io,
        scratch_path,
        budget,
        "bash-stderr",
        action_id,
        attempt_ordinal,
        faults.cleanup,
    ) catch |err| return .{ .failed = .{ .cause = err, .cleanup = cleanup } };
    return .{ .prepared = .{
        .io = io,
        .allocator = allocator,
        .workspace = workspace,
        .scratch_path = scratch_path,
        .bash_path = bash_path,
        .timeout_ms = timeout_ms,
        .faults = faults,
        .script = cleanup.script.?,
        .stdout_capture = cleanup.stdout_capture.?,
        .stderr_capture = cleanup.stderr_capture.?,
    } };
}

fn createOwnedFile(
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    prefix: []const u8,
    action_id: u64,
    attempt_ordinal: u64,
    cleanup_fault: bool,
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

const CommandWriter = struct {
    file: *OwnedFile,
    buffer: [command_write_window_bytes]u8 = undefined,
    length: usize = 0,

    pub fn writeAll(self: *CommandWriter, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const count = @min(remaining.len, self.buffer.len - self.length);
            @memcpy(self.buffer[self.length .. self.length + count], remaining[0..count]);
            self.length += count;
            remaining = remaining[count..];
            if (self.length == self.buffer.len) try self.flush();
        }
    }

    pub fn finish(self: *CommandWriter) !void {
        try self.flush();
    }

    fn flush(self: *CommandWriter) !void {
        if (self.length == 0) return;
        if (!self.file.budget.reserve(self.length)) return error.ScratchCapacityExhausted;
        self.file.charged += self.length;
        try self.file.file.?.writeStreamingAll(self.file.io, self.buffer[0..self.length]);
        self.length = 0;
    }
};

const ContentSource = struct {
    reader: *store.ContentReader,
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
