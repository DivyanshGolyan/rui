const std = @import("std");
const attempt = @import("attempt.zig");
const named_scratch = @import("named_scratch.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const BashLifecycle = @import("BashLifecycle.zig");
const deadline = @import("deadline.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");
const test_poll = @import("test_poll");
const bash_service = @import("testing/bash_service.zig");

pub const excerpt_bytes: usize = 10_000;
pub const copy_window_bytes: usize = 16 * 1024;
const fault_observation_delay_ms: u64 = 500;
pub const fault_gate_name = "bash-fault-gate";

/// Bash receives only this Host-owned environment: the running executable's
/// directory first on PATH, so ordinary `rui` is this exact build, and the
/// Host's absolute HOME. Nothing else from the Host environment, including
/// provider settings or credentials, reaches the child.
pub fn environment(io: std.Io, allocator: std.mem.Allocator, home: ?[]const u8) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(io, &executable_buffer)];
    var path_buffer: [std.fs.max_path_bytes + system_path.len + 1]u8 = undefined;
    try result.put("PATH", try searchPath(&path_buffer, std.fs.path.dirname(executable)));
    if (home) |value| if (std.fs.path.isAbsolute(value)) try result.put("HOME", value);
    return result;
}

/// For owners that never launch Bash (tests); reading it allocates nothing.
pub const empty_environment: std.process.Environ.Map = .{ .array_hash_map = .empty, .allocator = std.heap.page_allocator };

/// One tool process's environment: the shared Host map, unchanged, plus
/// the bare RUI_ADDRESS, canonical RUI_STORE and Host-issued RUI_SENDER_HANDLE.
/// The caller deinitializes the owned map.
pub fn toolEnvironment(allocator: std.mem.Allocator, shared: *const std.process.Environ.Map, store_selector: []const u8, session: []const u8, sender_handle: []const u8) !std.process.Environ.Map {
    var result = try shared.clone(allocator);
    errdefer result.deinit();
    try result.put("RUI_ADDRESS", session);
    try result.put("RUI_STORE", store_selector);
    if (sender_handle.len != 0) try result.put("RUI_SENDER_HANDLE", sender_handle);
    return result;
}

const system_path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// A directory containing ':' cannot be one PATH entry; the child then finds
/// only system commands rather than a split directory.
fn searchPath(buffer: []u8, directory: ?[]const u8) ![]const u8 {
    const value = directory orelse return system_path;
    if (std.mem.indexOfScalar(u8, value, ':') != null) return system_path;
    return std.fmt.bufPrint(buffer, "{s}:" ++ system_path, .{value});
}

const BashObservation = extern struct {
    kind: c_int,
    value: c_int,
};

extern fn rui_bash_observe(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_reap(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_pipe_queued_bytes(fd: c_int, bytes: *u64) c_int;
extern fn rui_bash_group_absent(pgid: c_int) c_int;
extern fn rui_bash_spawn(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
    pid: *std.c.pid_t,
    stdout_read: *c_int,
    stderr_read: *c_int,
    stdin_read: c_int,
) c_int;

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
    preparation_after_captures: bool = false,
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

        const Observation = struct {
            pid: c_int,
            value: BashObservation = undefined,

            fn ready(self: *@This()) !bool {
                const result = rui_bash_observe(self.pid, &self.value);
                try std.testing.expect(result >= 0);
                return result == 1;
            }
        };
        var observed: Observation = .{ .pid = pid };
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromMilliseconds(1500)), &observed, Observation.ready);
        try std.testing.expectEqual(Term{ .exited = case.expected }, decodeObservation(observed.value));

        var consumed: BashObservation = undefined;
        try std.testing.expectEqual(@as(c_int, 1), rui_bash_reap(pid, &consumed));
        reaped = true;
        try std.testing.expectEqual(Term{ .exited = case.expected }, decodeObservation(consumed));
    }
}

/// What every Bash capture of one Host shares: its io, its scratch
/// directory, and its Bash view of the scratch account. Captures sit in
/// execution slots, so they keep none of it and their owner passes it in.
pub const Scratch = struct {
    io: std.Io,
    path: []const u8,
    budget: ScratchBudget,
};

const OwnedFile = struct {
    file: ?std.Io.File,
    readonly: ?std.Io.File = null,
    unlinked: bool = false,
    name: protocol.Bounded(96),
    charged: u64 = 0,
    published: bool = false,
    cleanup_fault: CleanupFault = .none,

    fn close(self: *OwnedFile, io: std.Io) void {
        if (self.readonly) |file| file.close(io);
        self.readonly = null;
        if (self.file) |file| file.close(io);
        self.file = null;
    }

    fn injectedCleanupFault(self: *const OwnedFile, scratch: Scratch) bool {
        return self.cleanup_fault == .persistent or
            (self.cleanup_fault == .gated and faultGateActive(scratch.io, scratch.path));
    }

    fn cleanup(self: *OwnedFile, scratch: Scratch) !void {
        const io = scratch.io;
        if (self.unlinked) {
            if (self.published) return;
            // Reclaim bytes even if a descendant escaped the owned process
            // group holding fd 0. Keep the charge and writer if this fails.
            try self.file.?.setLength(io, 0);
            self.close(io);
            scratch.budget.release(self.charged);
            self.charged = 0;
            self.published = true;
            return;
        }
        self.close(io);
        if (self.published) return;
        if (self.injectedCleanupFault(scratch)) return error.InjectedBashCleanupFailure;
        var directory = try std.Io.Dir.cwd().openDir(io, scratch.path, .{});
        defer directory.close(io);
        directory.deleteFile(io, self.name.slice()) catch |err| switch (err) {
            // The owned descriptor is already closed, so an absent private
            // name establishes reclamation rather than a cleanup failure.
            error.FileNotFound => {},
            else => return err,
        };
        scratch.budget.release(self.charged);
        self.charged = 0;
        self.published = true;
    }
};

pub const Prepared = struct {
    scratch: Scratch,
    allocator: std.mem.Allocator,
    // The Session whose Action this is, in the Host's Store (borrowed).
    session: protocol.Bounded(protocol.max_session_bytes),
    sender_handle: protocol.Bounded(32) = .{},
    store_selector: []const u8,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    bash_path: []const u8,
    timeout_ms: u64,
    faults: Faults,
    /// Decoded command, owned through `allocator` until launch or cleanup,
    /// at most tools.bash_max_command_bytes.
    command: ?[:0]u8,
    stdin_capture: ?OwnedFile = null,
    stdout_capture: ?OwnedFile,
    stderr_capture: ?OwnedFile,

    pub fn cleanup(self: *Prepared) !void {
        self.releaseCommand();
        return cleanupOwnedFiles(self.scratch, &.{ &self.stdout_capture, &self.stderr_capture, &self.stdin_capture });
    }

    pub fn takeCleanup(self: *Prepared) PreparedCleanup {
        self.releaseCommand();
        const resources = PreparedCleanup{
            .stdout_capture = self.stdout_capture,
            .stderr_capture = self.stderr_capture,
            .stdin_capture = self.stdin_capture,
        };
        self.stdout_capture = null;
        self.stderr_capture = null;
        self.stdin_capture = null;
        return resources;
    }

    fn releaseCommand(self: *Prepared) void {
        if (self.command) |command| self.allocator.free(command);
        self.command = null;
    }

    /// `bash -c` lets Bash replace itself with an eligible final command;
    /// `$0` is `bash`, so diagnostics read `bash: line N:`. The native spawn
    /// resets the child's signal mask and dispositions and opens its own
    /// /dev/null stdin unless an unlinked read-only input was supplied.
    pub fn launch(self: *Prepared, shared_environment: *const std.process.Environ.Map) !Execution {
        if (self.faults.spawn) return error.BashSpawnFailed;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var child_environment = toolEnvironment(arena, shared_environment, self.store_selector, self.session.slice(), self.sender_handle.slice()) catch return error.BashSpawnFailed;
        const environment_block = child_environment.createPosixBlock(arena, .{ .zig_progress_fd = -1 }) catch return error.BashSpawnFailed;
        const path = arena.dupeSentinel(u8, self.bash_path, 0) catch return error.BashSpawnFailed;
        const cwd = arena.dupeSentinel(u8, self.workspace.slice(), 0) catch return error.BashSpawnFailed;
        const argv = [_:null]?[*:0]const u8{ path, "-c", self.command.?.ptr, "bash" };
        var pid: std.c.pid_t = undefined;
        var stdout_fd: c_int = undefined;
        var stderr_fd: c_int = undefined;
        const started = std.Io.Clock.Timestamp.now(self.scratch.io, .awake);
        if (rui_bash_spawn(path, &argv, environment_block.slice.ptr, cwd, &pid, &stdout_fd, &stderr_fd, if (self.stdin_capture) |input| input.readonly.?.handle else -1) != 0) return error.BashSpawnFailed;
        if (self.stdin_capture) |*input| {
            input.readonly.?.close(self.scratch.io);
            input.readonly = null;
        }
        self.releaseCommand();
        const stdout_capture = self.stdout_capture.?;
        const stderr_capture = self.stderr_capture.?;
        const stdin_capture = self.stdin_capture;
        self.stdout_capture = null;
        self.stderr_capture = null;
        self.stdin_capture = null;
        return .{
            .lifecycle = .start(started, self.timeout_ms),
            .leader = pid,
            .pgid = pid,
            .pipes = .init(.{
                .stdout = .{ .handle = stdout_fd, .flags = .{ .nonblocking = false } },
                .stderr = .{ .handle = stderr_fd, .flags = .{ .nonblocking = false } },
            }),
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
            .started = started,
            .timeout_ms = self.timeout_ms,
            .faults = self.faults,
            .stdin_capture = stdin_capture,
        };
    }
};

pub const PreparedCleanup = struct {
    stdout_capture: ?OwnedFile = null,
    stderr_capture: ?OwnedFile = null,
    stdin_capture: ?OwnedFile = null,

    pub fn cleanup(self: *PreparedCleanup, scratch: Scratch) !void {
        return cleanupOwnedFiles(scratch, &.{ &self.stdout_capture, &self.stderr_capture, &self.stdin_capture });
    }

    /// Test/slow-check aid: no file in this cleanup remains unreclaimed.
    /// Partial success nulls reclaimed slots and retains the rest with
    /// their residual charges; only a complete pass satisfies this.
    pub fn isComplete(self: *const PreparedCleanup) bool {
        return self.stdout_capture == null and self.stderr_capture == null and self.stdin_capture == null;
    }
};

pub const PreparationFailure = struct {
    cause: anyerror,
    cleanup: PreparedCleanup,
};

fn cleanupOwnedFiles(
    scratch: Scratch,
    slots: []const *?OwnedFile,
) !void {
    var first_error: ?anyerror = null;
    for (slots) |slot| {
        if (slot.*) |*file| {
            file.cleanup(scratch) catch |err| {
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

/// A running or retired Bash process. It sits in an execution slot, so it
/// keeps no Scratch; its owner passes the Host's to each call that needs it.
pub const Execution = struct {
    lifecycle: BashLifecycle,
    /// Direct child until its status is consumed by the reap.
    leader: ?std.process.Child.Id,
    /// Anchored original process group: the cancellation scope.
    pgid: std.process.Child.Id,
    /// Open while the matching lifecycle pipe is not closed.
    pipes: std.enums.EnumArray(BashLifecycle.Stream, ?std.Io.File),
    stdout_capture: OwnedFile,
    stderr_capture: OwnedFile,
    started: std.Io.Clock.Timestamp,
    timeout_ms: u64,
    faults: Faults,
    read_fault_used: bool = false,
    service_fault_used: bool = false,
    output_reservation: ?output_retention.Pair = null,
    stdin_capture: ?OwnedFile = null,

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

    pub fn service(self: *Execution, scratch: Scratch, window: []u8) ServiceResult {
        return self.serviceWithTime(scratch, window, .{ .live = scratch.io }, .live);
    }

    fn serviceAt(self: *Execution, scratch: Scratch, window: []u8, now: std.Io.Clock.Timestamp, source: ObservationSource) ServiceResult {
        return self.serviceWithTime(scratch, window, .{ .supplied = now }, source);
    }

    fn serviceWithTime(self: *Execution, scratch: Scratch, window: []u8, time: ServiceTime, source: ObservationSource) ServiceResult {
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
        const leader_observed = self.observeLeader(scratch, now, source) catch |err| observed: {
            fault = fault orelse err;
            self.requestInfrastructureShutdown(now);
            break :observed false;
        };
        made_progress = leader_observed or made_progress;
        made_progress = self.cutCapture(scratch.io, now, &fault) or made_progress;
        made_progress = self.servicePipe(scratch, .stdout, window, time, &now, &fault) or made_progress;
        made_progress = self.servicePipe(scratch, .stderr, window, time, &now, &fault) or made_progress;
        if (self.lifecycle.expireGrace(now)) |signal| {
            self.sendSignal(signal);
            made_progress = true;
        }
        made_progress = (self.reapLeader(scratch, now) catch |err| reaped: {
            fault = fault orelse err;
            break :reaped false;
        }) or made_progress;
        if (self.lifecycle.process == .checking_group) {
            const check = if (self.lifecycleFaultActive(scratch, .group_probe)) check: {
                fault = fault orelse error.InjectedBashGroupProbeFailure;
                break :check 0;
            } else if (self.lifecycleFaultActive(scratch, .cleanup_watchdog))
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
        made_progress = self.cutCapture(scratch.io, now, &fault) or made_progress;
        if (self.lifecycle.process == .gone) {
            made_progress = self.servicePipe(scratch, .stdout, window, time, &now, &fault) or made_progress;
            made_progress = self.servicePipe(scratch, .stderr, window, time, &now, &fault) or made_progress;
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
    /// Capture cleanup may still remain outstanding; retirement
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

    pub fn outcome(self: *Execution, scratch: Scratch, include_paths: bool, out: *Outcome) !void {
        self.stdout_capture.file.?.sync(scratch.io) catch self.lifecycle.recordSealFailure();
        self.stderr_capture.file.?.sync(scratch.io) catch self.lifecycle.recordSealFailure();
        if (self.faults.seal) self.lifecycle.recordSealFailure();
        const code: store.ActionResolutionCode = switch (self.lifecycle.resolution()) {
            inline else => |resolution| @field(store.ActionResolutionCode, @tagName(resolution)),
        };
        out.* = .{ .code = code };
        var writer = std.Io.Writer.fixed(&out.content);
        try self.formatResult(scratch, &writer, code, include_paths, &out.tail);
        out.content_len = writer.buffered().len;
    }

    pub fn reclaim(self: *Execution, scratch: Scratch, retention: *output_retention.Queue) !void {
        std.debug.assert(self.retired());
        var first_error: ?anyerror = null;
        cleanupOwnedFiles(scratch, &.{&self.stdin_capture}) catch |err| {
            first_error = err;
        };
        if (self.output_reservation != null) {
            // Reserved entries are protected from eviction. Relinquish the
            // producer aliases before publication makes the names reclaimable.
            self.stdout_capture.close(scratch.io);
            self.stderr_capture.close(scratch.io);
            if (self.stdout_capture.injectedCleanupFault(scratch)) {
                first_error = first_error orelse error.InjectedBashCleanupFailure;
            } else self.publishReservedOutput(retention) catch |err| {
                first_error = first_error orelse err;
            };
        } else {
            self.stdout_capture.cleanup(scratch) catch |err| {
                first_error = first_error orelse err;
            };
            self.stderr_capture.cleanup(scratch) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
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
        switch (@import("os/process.zig").signalGroup(self.pgid, signal_value)) {
            .sent => {},
            .absent => self.lifecycle.recordSignal(.delivered),
            .zombie_group_denied => self.lifecycle.recordSignal(.group_permission_denied),
            .failed => self.lifecycle.recordSignal(.failed),
        }
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

    /// Closes the descriptor once the lifecycle closes its pipe. The
    /// descriptor is open exactly while the lifecycle pipe is not closed.
    fn releaseClosedDescriptor(self: *Execution, io: std.Io, stream: BashLifecycle.Stream) void {
        if (self.lifecycle.pipes.get(stream) != .closed) return;
        const slot = self.pipes.getPtr(stream);
        if (slot.*) |file| file.close(io);
        slot.* = null;
    }

    fn servicePipe(
        self: *Execution,
        scratch: Scratch,
        stream: BashLifecycle.Stream,
        window: []u8,
        time: ServiceTime,
        now: *std.Io.Clock.Timestamp,
        fault: *?anyerror,
    ) bool {
        const before = self.lifecycle.pipes.get(stream);
        std.debug.assert((before == .closed) == (self.pipes.get(stream) == null));
        if (before == .closed) {
            now.* = time.observe();
            return false;
        }
        const read = self.readPipe(scratch, stream, window) catch |err| failed: {
            fault.* = fault.* orelse err;
            break :failed BashLifecycle.PipeRead{ .failed = .read };
        };
        // Apply the read at an observation taken after the potentially
        // blocking pipe operation.
        now.* = time.observe();
        const signal = self.lifecycle.observePipe(stream, read, now.*);
        // Close a failed pipe before signaling its writers.
        self.releaseClosedDescriptor(scratch.io, stream);
        self.sendSignal(signal);
        return read != .empty or !std.meta.eql(before, self.lifecycle.pipes.get(stream));
    }

    /// One bounded, non-blocking read. A tail never reads past the bytes it
    /// owes; with nothing owed, a one-byte probe distinguishes EOF from a
    /// writer that still holds the pipe. Probe bytes are never retained.
    fn readPipe(self: *Execution, scratch: Scratch, stream: BashLifecycle.Stream, window: []u8) !BashLifecycle.PipeRead {
        const state = self.lifecycle.pipes.get(stream);
        const pipe = self.pipes.get(stream).?;
        const destination = self.capture(stream);
        const wanted: usize = switch (state) {
            .reading => window.len,
            .tail => |owed| @intCast(@min(owed, window.len)),
            .closed => unreachable,
        };
        var descriptor = [_]std.posix.pollfd{.{
            .fd = pipe.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // A tail that still owes bytes has them queued, so it reads directly.
        if (!(state == .tail and wanted != 0) and try std.posix.poll(&descriptor, 0) == 0) return .empty;
        const reserved: usize = if (wanted == 0) 0 else @intCast(scratch.budget.allocateUpTo(wanted));
        if (reserved == 0) {
            var probe: [1]u8 = undefined;
            const count = std.posix.read(pipe.handle, &probe) catch |err| {
                if (err == error.WouldBlock) return .empty;
                return .{ .failed = .read };
            };
            if (count == 0) return .end;
            // Output that capture wanted but the scratch budget cannot hold.
            if (wanted != 0) return .{ .failed = .exhausted };
            return .{ .bytes = count };
        }
        const count = std.posix.read(pipe.handle, window[0..reserved]) catch |err| {
            scratch.budget.release(reserved);
            if (err == error.WouldBlock) return .empty;
            return .{ .failed = .read };
        };
        if (count < reserved) scratch.budget.release(reserved - count);
        if (count == 0) return .end;
        if (state == .reading and self.faults.capture_read and !self.read_fault_used) {
            self.read_fault_used = true;
            scratch.budget.release(count);
            return .{ .failed = .read };
        }
        destination.charged += count;
        if (state == .reading and self.faults.capture_write) return .{ .failed = .write };
        destination.file.?.writeStreamingAll(scratch.io, window[0..count]) catch {
            return .{ .failed = .write };
        };
        return .{ .bytes = count };
    }

    fn observeLeader(self: *Execution, scratch: Scratch, now: std.Io.Clock.Timestamp, source: ObservationSource) !bool {
        if (!self.lifecycle.awaitsLeader()) return false;
        const term: Term = switch (source) {
            .none => return false,
            .observed => |term| term,
            .failed => return error.BashObserveFailed,
            .live => live: {
                if (self.lifecycleFaultActive(scratch, .observe) and
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

    fn reapLeader(self: *Execution, scratch: Scratch, now: std.Io.Clock.Timestamp) !bool {
        if (self.lifecycle.process != .reaping) return false;
        if (self.lifecycleFaultActive(scratch, .reap)) return error.InjectedBashReapFailure;
        var observation: BashObservation = undefined;
        const result = if (self.lifecycleFaultActive(scratch, .reap_watchdog))
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

    fn lifecycleFaultActive(self: *const Execution, scratch: Scratch, expected: LifecycleFault) bool {
        if (self.faults.lifecycle != expected) return false;
        if (!self.faults.fault_gated) return true;
        return faultGateActive(scratch.io, scratch.path);
    }

    fn cutCapture(self: *Execution, io: std.Io, now: std.Io.Clock.Timestamp, fault: *?anyerror) bool {
        const cutoff = self.lifecycle.cutoff(now) orelse return false;
        var snapshots = cutoff.snapshot.iterator();
        while (snapshots.next()) |stream| self.beginTail(io, stream);
        if (cutoff.unconfirmed) fault.* = fault.* orelse error.BashCleanupUnconfirmed;
        return cutoff.snapshot.count() != 0;
    }

    fn beginTail(self: *Execution, io: std.Io, stream: BashLifecycle.Stream) void {
        const pipe = self.pipes.get(stream).?;
        var queued: u64 = 0;
        const observed = self.faults.lifecycle != .tail_snapshot and
            rui_bash_pipe_queued_bytes(pipe.handle, &queued) >= 0;
        self.lifecycle.beginTail(stream, if (observed) queued else null);
        self.releaseClosedDescriptor(io, stream);
    }
    fn formatResult(
        self: *Execution,
        scratch: Scratch,
        writer: *std.Io.Writer,
        code: store.ActionResolutionCode,
        include_paths: bool,
        tail: *[excerpt_bytes]u8,
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
        // A result exists only after the reap and an ESRCH absence probe
        // confirmed retirement; a probe EPERM keeps the group present until the
        // cleanup watchdog fences instead. macOS group-signal EPERM (an exited,
        // unreaped leader) therefore needs no qualification here and stays a
        // lifecycle fact only. Other signal failures remain visible.
        if (self.lifecycle.signal_failure) try writer.writeAll("Process-group signaling reported a failure.\n");
        const stdout_length = try self.stdout_capture.file.?.length(scratch.io);
        const stderr_length = try self.stderr_capture.file.?.length(scratch.io);
        const stderr_base: usize = @intCast(@min(stderr_length, excerpt_bytes / 2));
        const stdout_take: usize = @intCast(@min(stdout_length, excerpt_bytes - stderr_base));
        const stderr_take = stderr_base + @as(usize, @intCast(@min(
            stderr_length - stderr_base,
            excerpt_bytes - stderr_base - stdout_take,
        )));
        if (stdout_take != 0) {
            const count = try self.stdout_capture.file.?.readPositionalAll(
                scratch.io,
                tail[0..stdout_take],
                stdout_length - stdout_take,
            );
            if (count != stdout_take) return error.ShortCaptureRead;
        }
        if (stderr_take != 0) {
            const count = try self.stderr_capture.file.?.readPositionalAll(
                scratch.io,
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
        // An empty stream has no section. A full-output pointer appears only
        // for a stream whose tail omits earlier bytes.
        var stdout_omitted = stdout_length > stdout_take;
        if (stdout_take != 0) {
            try writer.writeAll("stdout tail:\n");
            stdout_omitted = try appendValidUtf8Tail(writer, stdout_bytes, stdout_allowance) or stdout_omitted;
        }
        var stderr_omitted = stderr_length > stderr_take;
        if (stderr_take != 0) {
            try writer.writeAll(if (stdout_take != 0) "\nstderr tail:\n" else "stderr tail:\n");
            stderr_omitted = try appendValidUtf8Tail(writer, stderr_bytes, stderr_allowance) or stderr_omitted;
        }
        if (!stdout_omitted and !stderr_omitted) return;
        try writer.writeAll("\n[earlier output omitted]\n");
        if (!include_paths) {
            try writer.writeAll("\nFull output was not retained.\n");
            return;
        }
        try writer.writeByte('\n');
        if (stdout_omitted) try writer.print("Full stdout: {s}/{s}\n", .{ scratch.path, self.stdout_capture.name.slice() });
        if (stderr_omitted) try writer.print("Full stderr: {s}/{s}\n", .{ scratch.path, self.stderr_capture.name.slice() });
    }
};

pub const Outcome = struct {
    code: store.ActionResolutionCode,
    content: [excerpt_bytes + 4096]u8 = undefined,
    content_len: usize = 0,
    /// The output tails the result quotes, read before they are encoded.
    tail: [excerpt_bytes]u8 = undefined,

    pub fn text(self: *const Outcome) []const u8 {
        return self.content[0..self.content_len];
    }
};

pub const Preparation = struct {
    scratch: Scratch,
    allocator: std.mem.Allocator,
    session: protocol.Bounded(protocol.max_session_bytes),
    sender_handle: protocol.Bounded(32) = .{},
    store_selector: []const u8,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    bash_path: []const u8,
    timeout_ms: u64,
    action_id: u64,
    faults: Faults,
    source: ContentSource,
    parser: tools.BashParser = .{},
    cleanup: PreparedCleanup = .{},
    command: std.ArrayList(u8) = .empty,
    /// Decoded stdin staged between parser steps.
    input_window: [copy_window_bytes]u8 = undefined,

    /// Builds the preparation in place, opens its arguments reader in place
    /// and creates both output captures. On failure nothing is live except
    /// the returned cleanup.
    pub fn start(
        self: *Preparation,
        scratch: Scratch,
        allocator: std.mem.Allocator,
        arguments: store.ContentLocation,
        input: *const store.BashExecutionInput,
        store_selector: []const u8,
        bash_path: []const u8,
        action_id: u64,
        faults: Faults,
    ) ?PreparationFailure {
        self.* = .{
            .scratch = scratch,
            .allocator = allocator,
            .session = input.session,
            .sender_handle = input.sender_handle,
            .store_selector = store_selector,
            .workspace = input.workspace,
            .bash_path = bash_path,
            .timeout_ms = input.timeout_ms,
            .action_id = action_id,
            .faults = faults,
            .source = .{ .length = input.arguments.length },
        };
        self.source.reader.open(arguments);
        if (faults.preparation) return self.fail(error.BashPreparationFailed);
        for ([_]struct { *?OwnedFile, named_scratch.NumericName }{
            .{ &self.cleanup.stdout_capture, .@"bash-stdout" },
            .{ &self.cleanup.stderr_capture, .@"bash-stderr" },
        }) |capture| {
            capture[0].* = createOwnedFile(scratch, capture[1], action_id, attempt.action_attempt_ordinal, cleanupFault(faults)) catch |err| return self.fail(err);
        }
        if (faults.preparation_after_captures) return self.fail(error.BashPreparationFailed);
        return null;
    }

    pub const Progress = union(enum) { pending, prepared, failed: PreparationFailure };

    /// On `.prepared`, `out` holds the launch inputs and this preparation is
    /// spent.
    pub fn advance(self: *Preparation, out: *Prepared) Progress {
        var writer = PreparationWriter{ .owner = self };
        var input = PreparationInputWriter{ .owner = self };
        const progress = self.parser.advance(&self.source, &writer, &input, self.source.buffer.len) catch |err| {
            return .{ .failed = self.fail(if (tools.isBashDescriptorError(err)) error.InvalidCanonicalBashDescriptor else err) };
        };
        input.flush() catch |err| return .{ .failed = self.fail(err) };
        switch (progress) {
            .pending => return .pending,
            .invalid => return .{ .failed = self.fail(error.InvalidCanonicalBashDescriptor) },
            .complete => {},
        }
        if (self.parser.result.stdin_present) self.ensureInput() catch |err| return .{ .failed = self.fail(err) };
        const command = self.command.toOwnedSliceSentinel(self.allocator, 0) catch |err| return .{ .failed = self.fail(err) };
        self.source.reader.close();
        const cleanup = self.takeCleanup();
        out.* = .{
            .scratch = self.scratch,
            .allocator = self.allocator,
            .session = self.session,
            .sender_handle = self.sender_handle,
            .store_selector = self.store_selector,
            .workspace = self.workspace,
            .bash_path = self.bash_path,
            .timeout_ms = self.timeout_ms,
            .faults = self.faults,
            .command = command,
            .stdin_capture = cleanup.stdin_capture,
            .stdout_capture = cleanup.stdout_capture,
            .stderr_capture = cleanup.stderr_capture,
        };
        return .prepared;
    }

    pub fn cancel(self: *Preparation) PreparedCleanup {
        self.source.reader.close();
        return self.takeCleanup();
    }

    fn fail(self: *Preparation, cause: anyerror) PreparationFailure {
        self.source.reader.close();
        return .{ .cause = cause, .cleanup = self.takeCleanup() };
    }

    fn takeCleanup(self: *Preparation) PreparedCleanup {
        self.command.deinit(self.allocator);
        self.command = .empty;
        const cleanup = self.cleanup;
        self.cleanup = .{};
        return cleanup;
    }

    fn ensureInput(self: *Preparation) !void {
        if (self.cleanup.stdin_capture != null) return;
        self.cleanup.stdin_capture = try createOwnedFile(self.scratch, .@"bash-stdin", self.action_id, attempt.action_attempt_ordinal, .none);
        const input = &self.cleanup.stdin_capture.?;
        const io = self.scratch.io;
        var directory = try std.Io.Dir.cwd().openDir(io, self.scratch.path, .{});
        defer directory.close(io);
        input.readonly = try directory.openFile(io, input.name.slice(), .{});
        try directory.deleteFile(io, input.name.slice());
        input.unlinked = true;
    }
};

const PreparationWriter = struct {
    owner: *Preparation,

    pub fn writeAll(self: *PreparationWriter, bytes: []const u8) !void {
        const command = &self.owner.command;
        if (bytes.len > tools.bash_max_command_bytes - command.items.len) return error.BashCommandTooLong;
        try command.appendSlice(self.owner.allocator, bytes);
    }
};

const PreparationInputWriter = struct {
    owner: *Preparation,
    used: usize = 0,

    pub fn writeAll(self: *PreparationInputWriter, bytes: []const u8) !void {
        try self.owner.ensureInput();
        const length = self.owner.cleanup.stdin_capture.?.charged + self.used;
        if (bytes.len > tools.bash_max_stdin_bytes - length) return error.BashStdinTooLong;
        const window = &self.owner.input_window;
        if (bytes.len > window.len - self.used) try self.flush();
        @memcpy(window[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    fn flush(self: *PreparationInputWriter) !void {
        if (self.used == 0) return;
        const input = &self.owner.cleanup.stdin_capture.?;
        if (!self.owner.scratch.budget.allocate(self.used)) return error.ScratchCapacityExhausted;
        const offset = input.charged;
        input.charged += self.used;
        // Positional writes leave the independent read-only fd at offset zero.
        // A failed write retains its whole reservation until reclamation.
        try input.file.?.writePositionalAll(self.owner.scratch.io, self.owner.input_window[0..self.used], offset);
        self.used = 0;
    }
};

fn cleanupFault(faults: Faults) CleanupFault {
    return if (!faults.cleanup)
        .none
    else if (faults.fault_gated)
        .gated
    else
        .persistent;
}

fn createOwnedFile(
    scratch: Scratch,
    kind: named_scratch.NumericName,
    action_id: u64,
    attempt_ordinal: u64,
    cleanup_fault: CleanupFault,
) !OwnedFile {
    const io = scratch.io;
    var directory = try std.Io.Dir.cwd().openDir(io, scratch.path, .{});
    defer directory.close(io);
    var name: protocol.Bounded(96) = .{};
    var name_buffer: [96]u8 = undefined;
    try name.set(try kind.format(&name_buffer, action_id, attempt_ordinal));
    return .{
        .file = try directory.createFile(io, name.slice(), .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }),
        .name = name,
        .cleanup_fault = cleanup_fault,
    };
}

fn runningWithDeadline(started: std.Io.Clock.Timestamp, timeout_ms: u64) Execution {
    return .{
        .lifecycle = .{
            .process = .{ .running = .{ .deadline = deadline.after(started, timeout_ms) } },
            .pipes = .initFill(.{ .closed = .eof }),
        },
        .leader = 1,
        .pgid = 1,
        .pipes = .initFill(null),
        .stdout_capture = undefined,
        .stderr_capture = undefined,
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
    const scratch: Scratch = .{ .io = std.testing.io, .path = "", .budget = undefined };
    try std.testing.expect(execution.applyDueDeadline(before) == null);
    try std.testing.expect(execution.lifecycle.process == .running);
    // The service-time observation is after the deadline: the real owner
    // requests termination through the production service path. No clock is
    // sampled and no syscall runs; both observations are explicit inputs.
    const after = deadline.after(started, 21);
    var window: [copy_window_bytes]u8 = undefined;
    const result = execution.serviceAt(scratch, &window, after, .none);
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
    const idle = stale.serviceAt(scratch, &window, before, .none);
    try std.testing.expect(idle.timeout_action == null);
    try std.testing.expect(idle.fault == null);
    try std.testing.expect(stale.lifecycle.process == .running);
    // A failed observation is reported without a timeout, and the grace
    // deadlines derive from the supplied service-time observation.
    var unobservable = runningWithDeadline(started, 20);
    const failed = unobservable.serviceAt(scratch, &window, before, .failed);
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
    const seen = witnessed.serviceAt(scratch, &window, before, .{ .observed = .{ .exited = 0 } });
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
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
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
            .lifecycle = .{ .process = undefined },
            .leader = null,
            .pgid = 1,
            .pipes = .init(.{
                .stdout = .{ .handle = stdout_fds[0], .flags = .{ .nonblocking = false } },
                .stderr = .{ .handle = stderr_fds[0], .flags = .{ .nonblocking = false } },
            }),
            .stdout_capture = undefined,
            .stderr_capture = undefined,
            .started = started,
            .timeout_ms = 100,
            .faults = .{},
        };
        stdout_read_owned = false;
        stderr_read_owned = false;
        defer for (execution.pipes.values) |pipe| if (pipe) |file| file.close(std.testing.io);
        execution.stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", @backingInt(phase), @intFromBool(observation.cutoff), .none);
        defer execution.stdout_capture.cleanup(scratch) catch {};
        execution.stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", @backingInt(phase), @intFromBool(observation.cutoff), .none);
        defer execution.stderr_capture.cleanup(scratch) catch {};
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
        const result = execution.serviceAt(scratch, &window, observation.now, .none);
        try std.testing.expectEqual(observation.cutoff, execution.lifecycle.pipesClosed());
        try std.testing.expectEqual(observation.cutoff, execution.pipes.get(.stdout) == null and execution.pipes.get(.stderr) == null);
        try std.testing.expect(!result.retired);
        try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
        if (observation.cutoff) {
            try std.testing.expect(result.fault.? == error.BashCleanupUnconfirmed);
            try std.testing.expectEqual(@as(isize, -1), std.c.write(stdout_fds[1], "x", 1));
            try std.testing.expectEqual(std.c.E.PIPE, std.c.errno(-1));
            const repeated = execution.serviceAt(scratch, &window, after, .none);
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
        .lifecycle = .{
            .process = .{ .gone = .{ .exited = 0 } },
            .pipes = .init(.{ .stdout = .reading, .stderr = .{ .closed = .eof } }),
        },
        .leader = null,
        .pgid = 1,
        .pipes = .init(.{ .stdout = .{ .handle = gone_fds[0], .flags = .{ .nonblocking = false } }, .stderr = null }),
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .started = started,
        .timeout_ms = 100,
        .faults = .{},
    };
    gone_read_owned = false;
    defer if (gone.pipes.get(.stdout)) |file| file.close(std.testing.io);
    gone.stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .none);
    defer gone.stdout_capture.cleanup(scratch) catch {};
    gone.stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", 1, 1, .none);
    defer gone.stderr_capture.cleanup(scratch) catch {};
    var window: [copy_window_bytes]u8 = undefined;
    const gone_result = gone.serviceAt(scratch, &window, before, .none);
    try std.testing.expect(gone_result.fault == null);
    try std.testing.expect(gone_result.retired);
    const gone_repeated = gone.serviceAt(scratch, &window, after, .none);
    try std.testing.expect(!gone_repeated.made_progress);
    try std.testing.expect(gone_repeated.retired);

    // Group-signal EPERM after confirmed retirement had no live targets: the
    // result stays the plain outcome. Empty streams have no sections.
    gone.lifecycle.recordSignal(.group_permission_denied);
    var quiet: Outcome = undefined;
    try gone.outcome(scratch, false, &quiet);
    // The fixture keeps a writer open, so incomplete capture is genuine.
    try std.testing.expectEqualStrings("Bash succeeded. Exit code: 0.\nCapture may be incomplete because writers outlived process-group termination.\n", quiet.text());
    // Any other signaling failure stays visible next to it.
    gone.lifecycle.recordSignal(.failed);
    var warned: Outcome = undefined;
    try gone.outcome(scratch, false, &warned);
    try std.testing.expectEqualStrings("Bash succeeded. Exit code: 0.\nCapture may be incomplete because writers outlived process-group termination.\nProcess-group signaling reported a failure.\n", warned.text());
}

test "cleanup ownership transfers consume their source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const baseline: u64 = 41;
    var used: std.atomic.Value(u64) = .init(baseline);
    const budget = ScratchBudget{ .used = &used, .limit = baseline + 5 };
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    try std.testing.expect(budget.charge(5));
    var prepared = Prepared{
        .scratch = scratch,
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = root,
        .workspace = .{},
        .bash_path = "/bin/bash",
        .timeout_ms = 1,
        .faults = .{},
        .command = try std.testing.allocator.dupeSentinel(u8, "true", 0),
        .stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .none),
        .stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", 1, 1, .none),
    };
    prepared.stdout_capture.?.charged = 2;
    prepared.stderr_capture.?.charged = 3;

    var cleanup = prepared.takeCleanup();
    try std.testing.expect(prepared.command == null);
    try std.testing.expect(prepared.stdout_capture == null);
    try std.testing.expect(prepared.stderr_capture == null);
    try prepared.cleanup();
    try std.testing.expectEqual(baseline + 5, used.load(.acquire));

    try cleanup.cleanup(scratch);
    try std.testing.expect(cleanup.stdout_capture == null);
    try std.testing.expect(cleanup.stderr_capture == null);
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

test "Bash input reclamation truncates escaped readers before releasing scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 45 };
    const scratch: Scratch = .{ .io = io, .path = root, .budget = budget };
    var input = try createOwnedFile(scratch, .@"bash-stdin", 1, 1, .none);
    defer input.cleanup(scratch) catch {};
    const escaped = try tmp.dir.openFile(io, input.name.slice(), .{});
    defer escaped.close(io);
    try tmp.dir.deleteFile(io, input.name.slice());
    input.unlinked = true;
    try std.testing.expect(budget.allocate(4));
    input.charged = 4;
    try input.file.?.writePositionalAll(io, "data", 0);
    try std.testing.expectEqual(@as(u64, 45), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4), try escaped.length(io));
    try input.cleanup(scratch);
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), try escaped.length(io));
    try input.cleanup(scratch);
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
}

test "prepared cleanup reclaims partially and retries through the same owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const baseline: u64 = 41;
    var used: std.atomic.Value(u64) = .init(baseline);
    const budget = ScratchBudget{ .used = &used, .limit = baseline + 5 };
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    try std.testing.expect(budget.charge(5));
    // Acquire each file before installing the aggregate guard: a later
    // acquisition failure must not leave earlier files unguarded. The
    // per-file guards live in this block so a successful break transfers
    // sole ownership into the aggregate cleanup owner.
    var cleanup: PreparedCleanup = blk: {
        var stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .persistent);
        errdefer stdout_capture.cleanup(scratch) catch {};
        var stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", 1, 1, .none);
        errdefer stderr_capture.cleanup(scratch) catch {};
        break :blk .{
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
        };
    };
    cleanup.stdout_capture.?.charged = 2;
    cleanup.stderr_capture.?.charged = 3;
    var complete = false;
    errdefer if (!complete) {
        if (cleanup.stdout_capture) |*file| file.cleanup_fault = .none;
        cleanup.cleanup(scratch) catch {};
    };
    // One file fails while the others reclaim: only the residual charge
    // stays with the same owner. Bash removal failure does not retain the
    // same descriptor set as named-scratch failure: the failed descriptor
    // is already closed here.
    try std.testing.expectError(error.InjectedBashCleanupFailure, cleanup.cleanup(scratch));
    try std.testing.expect(cleanup.stdout_capture != null);
    try std.testing.expect(cleanup.stdout_capture.?.file == null);
    try std.testing.expect(cleanup.stderr_capture == null);
    try std.testing.expect(!cleanup.isComplete());
    try std.testing.expectEqual(baseline + 2, used.load(.acquire));
    // Retry through the same owner releases the residual exactly once.
    cleanup.stdout_capture.?.cleanup_fault = .none;
    try cleanup.cleanup(scratch);
    complete = true;
    try std.testing.expect(cleanup.isComplete());
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

fn launchForTest(root: []const u8, budget: ScratchBudget, retention: *output_retention.Queue, ordinal: u64, command: []const u8, out: *Outcome) !void {
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(root);
    var prepared = Prepared{
        .scratch = scratch,
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = root,
        .workspace = workspace,
        .bash_path = "/bin/bash",
        .timeout_ms = 10_000,
        .faults = .{},
        .command = try std.testing.allocator.dupeSentinel(u8, command, 0),
        .stdout_capture = null,
        .stderr_capture = null,
    };
    defer prepared.cleanup() catch {};
    prepared.stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", ordinal, 1, .none);
    prepared.stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", ordinal, 1, .none);
    var execution = try prepared.launch(&empty_environment);
    var window: [copy_window_bytes]u8 = undefined;
    const service = .{ .execution = &execution, .scratch = scratch, .window = &window };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(30)), service, bash_service.retired);
    try execution.outcome(scratch, false, out);
    try execution.reclaim(scratch, retention);
}

/// Lists, as `leaked-N` lines, the /dev/null descriptors this process would
/// pass to any child because they lack close-on-exec.
fn inheritableDevNull(buffer: []u8) ![]const u8 {
    const null_file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{});
    defer null_file.close(std.testing.io);
    const target = (try null_file.stat(std.testing.io)).inode;
    var writer: std.Io.Writer = .fixed(buffer);
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) {
        const flags = std.c.fcntl(fd, std.c.F.GETFD);
        if (flags < 0 or flags & std.c.FD_CLOEXEC != 0) continue;
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        const stat = file.stat(std.testing.io) catch continue;
        if (stat.kind == .character_device and stat.inode == target) try writer.print("leaked-{d}\n", .{fd});
    }
    return writer.buffered();
}

test "launched Bash starts with default signal actions, an empty mask and no /dev/null added by launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 << 20 };
    var entries: [8]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    // Descriptors the Host itself inherited without close-on-exec still reach
    // Bash. Launch must add none: Bash sees exactly the set held before any
    // launch, so a /dev/null cached by the spawn path appears as an extra.
    var inherited_buffer: [512]u8 = undefined;
    const inherited = try inheritableDevNull(&inherited_buffer);
    // The child's listing is bracketed by its own markers, so notices or
    // headers the result adds around stdout cannot change what is compared.
    var expected_buffer: [600]u8 = undefined;
    const expected_descriptors = try std.fmt.bufPrint(&expected_buffer, "begin\n{s}checked\n", .{inherited});
    // The Host may inherit an ignored SIGHUP (nohup) and its spawning thread
    // may block signals; neither may reach the tool.
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous_hangup: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, &ignore, &previous_hangup);
    defer std.posix.sigaction(.HUP, &previous_hangup, null);
    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .USR2);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
    const succeeded = "Bash succeeded. Exit code: 0.\n";
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "kill -HUP $$; echo survived", std.fmt.comptimePrint("Signal: {d}.", .{@backingInt(std.posix.SIG.HUP)}), "" },
        .{ "kill -USR2 $$; echo survived", std.fmt.comptimePrint("Signal: {d}.", .{@backingInt(std.posix.SIG.USR2)}), "" },
        // fds 0-2 are the tool's own; any later /dev/null was inherited.
        .{ "echo begin; for f in /dev/fd/*; do n=${f##*/}; [ \"$n\" -gt 2 ] && [ \"$f\" -ef /dev/null ] && echo leaked-$n; done | sort -t- -k2,2n; echo checked", succeeded, expected_descriptors },
    }, 1..) |case, ordinal| {
        var result: Outcome = undefined;
        try launchForTest(root, budget, &retention, ordinal, case[0], &result);
        const text = result.text();
        if (std.mem.indexOf(u8, text, case[1]) == null or std.mem.indexOf(u8, text, case[2]) == null) {
            std.debug.print("expected {s} and {s}; got:\n{s}\n", .{ case[1], case[2], text });
            return error.TestUnexpectedResult;
        }
        // Each platform's log records the parent baseline beside the child's set.
        if (case[2].len != 0) std.debug.print("inheritable /dev/null before launch, matched exactly by Bash:\n{s}(end)\n", .{inherited});
    }
}

test "an owned file closes its descriptor before reporting removal failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    try std.testing.expect(budget.charge(2));
    var file = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .persistent);
    file.charged = 2;
    // The fault strikes after the descriptor closes: the handle is gone
    // while the charge and the pathname stay with the owner.
    try std.testing.expectError(error.InjectedBashCleanupFailure, file.cleanup(scratch));
    try std.testing.expect(file.file == null);
    try std.testing.expect(!file.published);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    // An absent private name establishes reclamation once the fault clears:
    // descriptor closure and pathname removal are distinct facts.
    file.cleanup_fault = .none;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer directory.close(std.testing.io);
    try directory.deleteFile(std.testing.io, file.name.slice());
    try file.cleanup(scratch);
    try std.testing.expect(file.published);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "retired execution is independent of outstanding capture reclamation" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    var execution = Execution{
        .lifecycle = .{
            .process = .{ .gone = .{ .exited = 0 } },
            .pipes = .initFill(.{ .closed = .eof }),
        },
        .leader = null,
        .pgid = 1,
        .pipes = .initFill(null),
        .stdout_capture = undefined,
        .stderr_capture = undefined,
        .started = started,
        .timeout_ms = 100,
        .faults = .{},
    };
    // Gone with both pipes closed retires even though capture cleanup
    // remains outstanding.
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
    const budget = ScratchBudget{ .used = &used, .limit = 4 };
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    var entries: [2]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    try std.testing.expect(budget.charge(4));
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    // Acquire each file before installing the execution guard: a later
    // acquisition failure must not leave earlier files unguarded.
    var execution: Execution = undefined;
    {
        var stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .none);
        errdefer stdout_capture.cleanup(scratch) catch {};
        var stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", 1, 1, .none);
        errdefer stderr_capture.cleanup(scratch) catch {};
        execution = .{
            .lifecycle = .{
                .process = .{ .gone = .{ .exited = 0 } },
                .pipes = .initFill(.{ .closed = .eof }),
            },
            .leader = null,
            .pgid = 1,
            .pipes = .initFill(null),
            .stdout_capture = stdout_capture,
            .stderr_capture = stderr_capture,
            .started = started,
            .timeout_ms = 100,
            .faults = .{},
        };
    }
    execution.stdout_capture.charged = 2;
    execution.stderr_capture.charged = 2;
    var done = false;
    errdefer if (!done) {
        execution.releaseOutputReservation(&retention);
        execution.stdout_capture.cleanup(scratch) catch {};
        execution.stderr_capture.cleanup(scratch) catch {};
    };
    try execution.checkRetired();
    // Reserving output records entry charges without touching scratch bytes.
    try std.testing.expect(try execution.reserveOutput(&retention));
    try std.testing.expect(execution.output_reservation != null);
    try std.testing.expectEqual(@as(u64, 4), used.load(.acquire));
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
    try execution.reclaim(scratch, &retention);
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
    reader: store.ContentReader = undefined,
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

test "results show only nonempty stream sections and mark truncation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 << 20 };
    var entries: [16]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    // Full-output paths for truncated streams are covered natively by the
    // Bash and owner integrations, where retention names real files.
    const a = @as([excerpt_bytes]u8, @splat('a'));
    for ([_]struct { []const u8, []const u8 }{
        .{ "true", "Bash succeeded. Exit code: 0.\n" },
        .{ "printf out", "Bash succeeded. Exit code: 0.\nstdout tail:\nout" },
        .{ "printf err >&2; exit 3", "Bash failed. Exit code: 3.\nstderr tail:\nerr" },
        .{ "printf o; printf e >&2", "Bash succeeded. Exit code: 0.\nstdout tail:\no\nstderr tail:\ne" },
        .{ "printf z; head -c 10001 /dev/zero | tr '\\0' a", "Bash succeeded. Exit code: 0.\nstdout tail:\n" ++ a ++ "\n[earlier output omitted]\n\nFull output was not retained.\n" },
    }, 100..) |case, ordinal| {
        var result: Outcome = undefined;
        try launchForTest(root, budget, &retention, ordinal, case[0], &result);
        try std.testing.expectEqualStrings(case[1], result.text());
    }
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

test "Bash environment carries only this executable's PATH and an absolute HOME" {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(std.testing.io, &executable_buffer)];
    const directory = std.fs.path.dirname(executable).?;
    var with_home = try environment(std.testing.io, std.testing.allocator, "/home/peer");
    defer with_home.deinit();
    try std.testing.expectEqual(@as(usize, 2), with_home.count());
    const path = with_home.get("PATH").?;
    try std.testing.expect(std.mem.startsWith(u8, path, directory));
    try std.testing.expectEqualStrings(":" ++ system_path, path[directory.len..]);
    try std.testing.expectEqualStrings("/home/peer", with_home.get("HOME").?);
    var relative_home = try environment(std.testing.io, std.testing.allocator, "relative");
    defer relative_home.deinit();
    try std.testing.expectEqual(@as(usize, 1), relative_home.count());
    // Each tool process adds its own Session's address; the shared map stays as it was.
    var tool = try toolEnvironment(std.testing.allocator, &with_home, "/store \"q\"", "k7m2qx", "test-action-handle");
    defer tool.deinit();
    try std.testing.expectEqual(@as(usize, 5), tool.count());
    try std.testing.expectEqualStrings("k7m2qx", tool.get("RUI_ADDRESS").?);
    try std.testing.expectEqualStrings("/store \"q\"", tool.get("RUI_STORE").?);
    try std.testing.expectEqualStrings("test-action-handle", tool.get("RUI_SENDER_HANDLE").?);
    try std.testing.expectEqualStrings("/home/peer", tool.get("HOME").?);
    try std.testing.expectEqual(@as(usize, 2), with_home.count());
    try std.testing.expect(with_home.get("RUI_ADDRESS") == null);
    try std.testing.expect(with_home.get("RUI_SENDER_HANDLE") == null);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(system_path, try searchPath(&buffer, "/opt/a:b/bin"));
    try std.testing.expectEqualStrings("/opt/rui/bin:" ++ system_path, try searchPath(&buffer, "/opt/rui/bin"));
}
