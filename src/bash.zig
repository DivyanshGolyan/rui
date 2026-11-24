const std = @import("std");
const attempt = @import("attempt.zig");
const named_scratch = @import("named_scratch.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const pages = @import("os/pages.zig");
const system_path = @import("os/system_path.zig");
const environment = @import("environment.zig");
const protocol = @import("protocol.zig");
const BashLifecycle = @import("BashLifecycle.zig");
const deadline = @import("deadline.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");
const test_poll = @import("test_poll");
const bash_service = @import("testing/bash_service.zig");

pub const excerpt_bytes: usize = 20_000;
pub const copy_window_bytes: usize = 16 * 1024;
const fault_observation_delay_ms: u64 = 500;
pub const fault_gate_name = "bash-fault-gate";

pub fn readHostFacts(io: std.Io, allocator: std.mem.Allocator, home: ?[]const u8) !environment.HostFacts {
    const mapped = try pages.Mapped(struct {
        system: system_path.Buffer,
        path: [system_path.max_bytes]u8,
    }).map();
    defer mapped.unmap();
    const buffers = mapped.value;
    const executable = try @import("self_executable.zig").path(io);
    const directory = if (std.fs.path.dirname(executable)) |value| try allocator.dupe(u8, value) else null;
    errdefer if (directory) |value| allocator.free(value);
    const system = try allocator.dupe(u8, try system_path.read(io, &buffers.system, &buffers.path));
    errdefer allocator.free(system);
    const absolute_home = if (home) |value| if (std.fs.path.isAbsolute(value)) try allocator.dupe(u8, value) else null else null;
    return .{ .executable_dir = directory, .system_path = system, .home = absolute_home };
}

pub fn freeHostFacts(allocator: std.mem.Allocator, facts: environment.HostFacts) void {
    if (facts.executable_dir) |value| allocator.free(value);
    allocator.free(facts.system_path);
    if (facts.home) |value| allocator.free(value);
}

pub const default_facts: environment.HostFacts = .{ .executable_dir = null, .system_path = system_path.fixed, .home = null };

const fault_padding_bytes = 4 << 20;

fn padArguments(arena: std.mem.Allocator, block: environment.Block) !environment.Block {
    const padding = try arena.allocSentinel(u8, "RUI_FAULT_PADDING=".len + fault_padding_bytes, 0);
    @memcpy(padding[0.."RUI_FAULT_PADDING=".len], "RUI_FAULT_PADDING=");
    @memset(padding["RUI_FAULT_PADDING=".len..], 'x');
    const padded = try arena.allocSentinel(?[*:0]const u8, block.len + 1, null);
    @memcpy(padded[0..block.len], block);
    padded[block.len] = padding.ptr;
    return padded;
}

pub const ArgumentSizes = struct { command: usize = 0, environment: usize = 0, variables: usize = 0 };

fn blockBytes(block: []const ?[*:0]const u8) usize {
    var total: usize = 0;
    for (block) |entry| total += std.mem.len(entry.?) + 1;
    return total;
}

pub const arguments_message_bytes = 320;

pub fn argumentsTooLargeMessage(buffer: *[arguments_message_bytes]u8, sizes: ArgumentSizes) []const u8 {
    return std.fmt.bufPrint(buffer, "Bash was not started: the system refused its arguments as too large. The command is {d} bytes; the environment is {d} bytes in {d} variables. Put long content in stdin or a file, or send from a shell with a smaller environment.", .{ sizes.command, sizes.environment, sizes.variables }) catch unreachable;
}

const BashObservation = extern struct {
    kind: c_int,
    value: c_int,
};

extern fn rui_bash_observe(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_reap(pid: c_int, observation: *BashObservation) c_int;
extern fn rui_bash_pipe_queued_bytes(fd: c_int, bytes: *u64) c_int;
extern fn rui_bash_group_absent(pgid: c_int) c_int;
extern fn rui_bash_group_holds_only(pgid: c_int, leader: c_int) c_int;
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
    arguments: bool = false,
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

    /// A capture is sealed when the file holds every byte charged to it. Scratch
    /// never outlives the Host, so sealing checks length and never syncs: a sync
    /// adds no durability and stalls every agent on the execution loop.
    fn sealed(self: *const OwnedFile, io: std.Io) bool {
        const length = self.file.?.length(io) catch return false;
        return length == self.charged;
    }

    fn injectedCleanupFault(self: *const OwnedFile, scratch: Scratch) bool {
        return self.cleanup_fault == .persistent or
            (self.cleanup_fault == .gated and faultGateActive(scratch.io, scratch.path));
    }

    fn cleanup(self: *OwnedFile, scratch: Scratch) !void {
        const io = scratch.io;
        if (self.unlinked) {
            if (self.published) return;
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
            error.FileNotFound => {},
            else => return err,
        };
        scratch.budget.release(self.charged);
        self.charged = 0;
        self.published = true;
    }
};

const CaptureAdoption = struct {
    capture: *OwnedFile,
    scratch: Scratch,
    queue: *output_retention.Queue,

    fn adopt(context: *anyopaque) ?output_retention.Spill {
        const self: *CaptureAdoption = @ptrCast(@alignCast(context));
        if (self.capture.injectedCleanupFault(self.scratch)) return null;
        self.capture.close(self.scratch.io);
        const spill = output_retention.Spill.adopt(self.queue, self.capture.name.slice(), self.capture.charged) orelse return null;
        self.capture.charged = 0;
        self.capture.published = true;
        return spill;
    }
};

pub const Prepared = struct {
    scratch: Scratch,
    allocator: std.mem.Allocator,
    session: protocol.Bounded(protocol.max_session_bytes),
    sender_handle: protocol.Bounded(32) = .{},
    store_selector: []const u8,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    bash_path: []const u8,
    timeout_ms: u64,
    faults: Faults,
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

    pub fn launch(self: *Prepared, facts: environment.HostFacts, base: ?environment.Value, runtime_dir: ?[]const u8, refused: *ArgumentSizes) !Execution {
        if (self.faults.spawn) return error.BashSpawnFailed;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const identity: environment.Identity = .{ .address = self.session.slice(), .store = self.store_selector, .sender_handle = self.sender_handle.slice(), .runtime_dir = runtime_dir };
        var environment_block = environment.childBlock(arena, base, facts, identity) catch return error.BashSpawnFailed;
        if (self.faults.arguments) environment_block = padArguments(arena, environment_block) catch return error.BashSpawnFailed;
        const path = arena.dupeSentinel(u8, self.bash_path, 0) catch return error.BashSpawnFailed;
        const cwd = arena.dupeSentinel(u8, self.workspace.slice(), 0) catch return error.BashSpawnFailed;
        const argv = [_:null]?[*:0]const u8{ path, "-c", self.command.?.ptr, "bash" };
        var pid: std.c.pid_t = undefined;
        var stdout_fd: c_int = undefined;
        var stderr_fd: c_int = undefined;
        const started = std.Io.Clock.Timestamp.now(self.scratch.io, .awake);
        switch (rui_bash_spawn(path, &argv, environment_block.ptr, cwd, &pid, &stdout_fd, &stderr_fd, if (self.stdin_capture) |input| input.readonly.?.handle else -1)) {
            0 => {},
            @backingInt(std.posix.E.@"2BIG") => {
                refused.* = .{ .command = self.command.?.len, .environment = blockBytes(environment_block), .variables = environment_block.len };
                return error.BashArgumentsTooLarge;
            },
            else => return error.BashSpawnFailed,
        }
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

const ObservationSource = union(enum) {
    live,
    none,
    observed: Term,
    failed,
};

pub const Execution = struct {
    lifecycle: BashLifecycle,
    leader: ?std.process.Child.Id,
    pgid: std.process.Child.Id,
    pipes: std.enums.EnumArray(BashLifecycle.Stream, ?std.Io.File),
    stdout_capture: OwnedFile,
    stderr_capture: OwnedFile,
    started: std.Io.Clock.Timestamp,
    timeout_ms: u64,
    faults: Faults,
    read_fault_used: bool = false,
    service_fault_used: bool = false,
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

    pub fn checkRetired(self: *const Execution) !void {
        if (!self.retired()) return error.BashNotRetired;
    }

    pub fn resultCode(self: *Execution, scratch: Scratch) store.ActionResolutionCode {
        if (!self.stdout_capture.sealed(scratch.io)) self.lifecycle.recordSealFailure();
        if (!self.stderr_capture.sealed(scratch.io)) self.lifecycle.recordSealFailure();
        if (self.faults.seal) self.lifecycle.recordSealFailure();
        return switch (self.lifecycle.resolution()) {
            inline else => |resolution| @field(store.ActionResolutionCode, @tagName(resolution)),
        };
    }

    /// Build the shared result from the two finished capture files. Adoption
    /// transfers an already charged file only after its excerpt was cut.
    pub fn writeResult(self: *Execution, scratch: Scratch, queue: *output_retention.Queue, result: anytype) !store.ActionResolutionCode {
        const code = self.resultCode(scratch);
        var header_buffer: [4096]u8 = undefined;
        var header = std.Io.Writer.fixed(&header_buffer);
        try self.writeHeader(&header, code);
        try result.frame(header.buffered());
        var captures = [_]CaptureAdoption{
            .{ .capture = &self.stdout_capture, .scratch = scratch, .queue = queue },
            .{ .capture = &self.stderr_capture, .scratch = scratch, .queue = queue },
        };
        try result.files(&.{
            .{ .label = "stdout", .section = "stdout:\n", .file = self.stdout_capture.file.?, .length = try self.stdout_capture.file.?.length(scratch.io), .context = &captures[0], .adopt = CaptureAdoption.adopt },
            .{ .label = "stderr", .section = "stderr:\n", .file = self.stderr_capture.file.?, .length = try self.stderr_capture.file.?.length(scratch.io), .context = &captures[1], .adopt = CaptureAdoption.adopt },
        });
        return code;
    }

    pub fn reclaim(self: *Execution, scratch: Scratch, retention: *output_retention.Queue) !void {
        std.debug.assert(self.retired());
        var first_error: ?anyerror = null;
        cleanupOwnedFiles(scratch, &.{&self.stdin_capture}) catch |err| {
            first_error = err;
        };
        _ = retention;
        self.stdout_capture.cleanup(scratch) catch |err| {
            first_error = first_error orelse err;
        };
        self.stderr_capture.cleanup(scratch) catch |err| if (first_error == null) {
            first_error = err;
        };
        if (first_error) |err| return err;
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
        now.* = time.observe();
        const signal = self.lifecycle.observePipe(stream, read, now.*);
        self.releaseClosedDescriptor(scratch.io, stream);
        self.sendSignal(signal);
        return read != .empty or !std.meta.eql(before, self.lifecycle.pipes.get(stream));
    }

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
        if (!(state == .tail and wanted != 0) and try std.posix.poll(&descriptor, 0) == 0) return .empty;
        const reserved: usize = if (wanted == 0) 0 else @intCast(scratch.budget.allocateUpTo(wanted));
        if (reserved == 0) {
            var probe: [1]u8 = undefined;
            const count = std.posix.read(pipe.handle, &probe) catch |err| {
                if (err == error.WouldBlock) return .empty;
                return .{ .failed = .read };
            };
            if (count == 0) return .end;
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
        // Only a live observation has a real group behind it. A probe that
        // cannot list the group keeps the grace.
        if (source == .live and self.lifecycle.awaitsGroup() and rui_bash_group_holds_only(self.pgid, self.leader.?) == 1) {
            self.sendSignal(self.lifecycle.groupHoldsOnlyLeader());
        }
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
    pub fn writeHeader(self: *const Execution, writer: *std.Io.Writer, code: store.ActionResolutionCode) !void {
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
    }
};

const TestOutcome = struct {
    code: store.ActionResolutionCode,
    content: [excerpt_bytes + 4096]u8 = undefined,
    content_len: usize = 0,

    fn text(self: *const TestOutcome) []const u8 {
        return self.content[0..self.content_len];
    }
};

fn testOutcome(execution: *Execution, scratch: Scratch, queue: *output_retention.Queue, out: *TestOutcome, comptime Host: type, comptime Parts: type, comptime Result: type) !void {
    // Exercise the unavailable-retention path without transferring either
    // capture; Bash's real profile always offers retention.
    var no_entries: [0]output_retention.Entry = .{};
    var unavailable = output_retention.Queue.initialize(scratch.io, scratch.path, queue.budget, &no_entries);
    var host: Host = .{ .io = scratch.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &unavailable };
    var host_parts: Parts = undefined;
    host_parts.attach(&host, null);
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = excerpt_bytes, .retain = true });
    defer result.destroy();
    out.code = try execution.writeResult(scratch, &unavailable, result);
    const finished = result.finish();
    if (finished != .value or finished.value != .text) return error.UnexpectedTestResult;
    const text = finished.value.text;
    @memcpy(out.content[0..text.len], text);
    out.content_len = text.len;
}

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
    input_window: [copy_window_bytes]u8 = undefined,

    pub fn start(
        self: *Preparation,
        scratch: Scratch,
        allocator: std.mem.Allocator,
        arguments: store.ContentLocation,
        input: *const store.ActionExecutionInput,
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
            .workspace = input.runner.bash.workspace,
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
        .faults = .{ .lifecycle = .signal },
    };
}

test "the group probe sees a lone exited leader and any member it left behind" {
    const Probe = struct {
        extern "c" fn pause() c_int;

        leader: c_int,
        observation: BashObservation = undefined,

        fn exited(self: *@This()) !bool {
            const result = rui_bash_observe(self.leader, &self.observation);
            try std.testing.expect(result >= 0);
            return result == 1;
        }

        fn alone(self: *@This()) !bool {
            const result = rui_bash_group_holds_only(self.leader, self.leader);
            try std.testing.expect(result >= 0);
            return result == 1;
        }
    };
    const Shape = enum { lone, member };
    for (std.enums.values(Shape)) |shape| {
        const leader = std.c.fork();
        if (leader < 0) return error.TestForkFailed;
        if (leader == 0) {
            _ = std.c.setpgid(0, 0);
            if (shape == .member and std.c.fork() == 0) while (true) {
                _ = Probe.pause();
            };
            std.c._exit(0);
        }
        _ = std.c.setpgid(leader, leader);
        var reaped = false;
        defer if (!reaped) {
            _ = @import("os/process.zig").signalGroup(leader, .KILL);
            _ = std.c.waitpid(leader, null, 0);
        };
        var probe: Probe = .{ .leader = leader };
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromMilliseconds(1500)), &probe, Probe.exited);
        if (shape == .member) {
            try std.testing.expectEqual(@as(c_int, 0), rui_bash_group_holds_only(leader, leader));
            _ = @import("os/process.zig").signalGroup(leader, .KILL);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromMilliseconds(5000)), &probe, Probe.alone);
        }
        try std.testing.expectEqual(@as(c_int, 1), rui_bash_group_holds_only(leader, leader));
        try std.testing.expectEqual(@as(c_int, 1), rui_bash_reap(leader, &probe.observation));
        reaped = true;
    }
}

test "service acts on its service-time observation rather than an earlier one" {
    const started = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    const timeout_at = deadline.after(started, 20);
    const before = deadline.after(started, 1);
    var execution = runningWithDeadline(started, 20);
    const scratch: Scratch = .{ .io = std.testing.io, .path = "", .budget = undefined };
    try std.testing.expect(execution.applyDueDeadline(before) == null);
    try std.testing.expect(execution.lifecycle.process == .running);
    const after = deadline.after(started, 21);
    var window: [copy_window_bytes]u8 = undefined;
    const result = execution.serviceAt(scratch, &window, after, .none);
    const timeout = result.timeout_action orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(u64, @intCast(timeout_at.raw.nanoseconds)), timeout.deadline_ns);
    try std.testing.expect(timeout.signal_failed);
    try std.testing.expect(result.fault == null);
    try std.testing.expect(result.made_progress);
    try std.testing.expect(!result.retired);
    try std.testing.expect(execution.lifecycle.process == .grace);
    try std.testing.expectEqual(BashLifecycle.StopReason.timed_out, execution.lifecycle.stop_reason);
    var stale = runningWithDeadline(started, 20);
    const idle = stale.serviceAt(scratch, &window, before, .none);
    try std.testing.expect(idle.timeout_action == null);
    try std.testing.expect(idle.fault == null);
    try std.testing.expect(stale.lifecycle.process == .running);
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
    const stop = unobservable.requestStop(deadline.after(before, 50));
    try std.testing.expect(!stop.attempted);
    try std.testing.expectEqual(BashLifecycle.StopReason.infrastructure_shutdown, unobservable.lifecycle.stop_reason);
    try std.testing.expectEqual(grace.kill_at.raw.nanoseconds, unobservable.lifecycle.process.grace.kill_at.raw.nanoseconds);
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

    gone.lifecycle.recordSignal(.group_permission_denied);
    var quiet: TestOutcome = undefined;
    quiet.code = gone.resultCode(scratch);
    var quiet_writer = std.Io.Writer.fixed(&quiet.content);
    try gone.writeHeader(&quiet_writer, quiet.code);
    quiet.content_len = quiet_writer.buffered().len;
    try std.testing.expectEqualStrings("Bash succeeded. Exit code: 0.\nCapture may be incomplete because writers outlived process-group termination.\n", quiet.text());
    gone.lifecycle.recordSignal(.failed);
    var warned: TestOutcome = undefined;
    warned.code = gone.resultCode(scratch);
    var warned_writer = std.Io.Writer.fixed(&warned.content);
    try gone.writeHeader(&warned_writer, warned.code);
    warned.content_len = warned_writer.buffered().len;
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
    try std.testing.expectError(error.InjectedBashCleanupFailure, cleanup.cleanup(scratch));
    try std.testing.expect(cleanup.stdout_capture != null);
    try std.testing.expect(cleanup.stdout_capture.?.file == null);
    try std.testing.expect(cleanup.stderr_capture == null);
    try std.testing.expect(!cleanup.isComplete());
    try std.testing.expectEqual(baseline + 2, used.load(.acquire));
    cleanup.stdout_capture.?.cleanup_fault = .none;
    try cleanup.cleanup(scratch);
    complete = true;
    try std.testing.expect(cleanup.isComplete());
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

fn launchForTest(root: []const u8, budget: ScratchBudget, retention: *output_retention.Queue, ordinal: u64, command: []const u8, out: *TestOutcome, comptime Host: type, comptime Parts: type, comptime Result: type) !void {
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
    var refused: ArgumentSizes = .{};
    var execution = try prepared.launch(default_facts, null, null, &refused);
    var window: [copy_window_bytes]u8 = undefined;
    const service = .{ .execution = &execution, .scratch = scratch, .window = &window };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(30)), service, bash_service.retired);
    try testOutcome(&execution, scratch, retention, out, Host, Parts, Result);
    try execution.reclaim(scratch, retention);
}

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

test "MySQL Bash preserves a short runtime alias with an overlong canonical target" {
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const long_name: [platform.max_launch_socket_path_bytes + 1]u8 = @splat('d');
    try tmp.dir.createDir(io, &long_name, .fromMode(0o700));
    try tmp.dir.symLink(io, &long_name, "runtime", .{ .is_directory = true });
    var runtime_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const runtime = (try tmp.address("runtime", &runtime_buffer)).path;
    var socket_buffer: [platform.max_launch_socket_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buffer, "{s}/rui.sock", .{runtime});
    const address = try std.Io.net.UnixAddress.init(socket);
    var lease: platform.StoreLease = undefined;
    try lease.acquireMysql(io, runtime, socket);
    defer lease.release();
    try lease.prepareForServing(false);
    const canonical_runtime = std.fs.path.dirname(lease.paths.scratch.slice()).?;
    try std.testing.expect(canonical_runtime.len > platform.max_launch_socket_path_bytes);
    const store_id = "0123456789abcdef0123456789abcdef";
    try std.testing.expectError(error.NoSpaceLeft, platform.mysqlClientPaths(io, store_id, canonical_runtime));
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 << 20 };
    const scratch: Scratch = .{ .io = io, .path = lease.paths.scratch.slice(), .budget = budget };
    var entries: [8]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(io, scratch.path, budget, &entries);
    defer retention.cleanupAll();
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(runtime);
    for ([_]struct { selector: []const u8, hint: ?[]const u8 }{
        .{ .selector = store_id, .hint = lease.paths.runtimeHint() },
        .{ .selector = runtime, .hint = lease.paths.runtimeHint() },
        .{ .selector = store_id, .hint = null },
    }, 0..) |case, index| {
        var prepared = Prepared{
            .scratch = scratch,
            .allocator = std.testing.allocator,
            .session = .{},
            .store_selector = case.selector,
            .workspace = workspace,
            .bash_path = "/bin/bash",
            .timeout_ms = 10_000,
            .faults = .{},
            .command = try std.testing.allocator.dupeSentinel(u8, "printf '%s' \"$RUI_RUNTIME_DIR\"", 0),
            .stdout_capture = null,
            .stderr_capture = null,
        };
        defer prepared.cleanup() catch @panic("Bash preparation cleanup failed");
        prepared.stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", index + 1, 1, .none);
        prepared.stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", index + 1, 1, .none);
        var refused: ArgumentSizes = .{};
        var execution = try prepared.launch(default_facts, null, case.hint, &refused);
        var window: [copy_window_bytes]u8 = undefined;
        const service = .{ .execution = &execution, .scratch = scratch, .window = &window };
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(30)), service, bash_service.retired);
        defer execution.reclaim(scratch, &retention) catch @panic("Bash execution cleanup failed");
        var output: TestOutcome = undefined;
        try testOutcome(&execution, scratch, &retention, &output, @import("server_host.zig").Host, @import("server_host_testing.zig").TestParts, @import("tool_result.zig").Result);
        try std.testing.expectEqual(store.ActionResolutionCode.succeeded, output.code);
        var child_runtime_buffer: [protocol.max_store_bytes]u8 = undefined;
        const length = try execution.stdout_capture.file.?.readPositionalAll(io, &child_runtime_buffer, 0);
        const child_runtime = child_runtime_buffer[0..length];
        try std.testing.expectEqualStrings(case.hint orelse "", child_runtime);
        if (case.hint == null) continue;
        const paths = try platform.mysqlClientPaths(io, store_id, child_runtime);
        try std.testing.expectEqualStrings(lease.paths.socket.slice(), paths.socket.slice());
        const peer = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).connect(io);
        defer peer.close(io);
    }
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
    var inherited_buffer: [512]u8 = undefined;
    const inherited = try inheritableDevNull(&inherited_buffer);
    var expected_buffer: [600]u8 = undefined;
    const expected_descriptors = try std.fmt.bufPrint(&expected_buffer, "begin\n{s}checked\n", .{inherited});
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
        .{ "echo begin; for f in /dev/fd/*; do n=${f##*/}; [ \"$n\" -gt 2 ] && [ \"$f\" -ef /dev/null ] && echo leaked-$n; done | sort -t- -k2,2n; echo checked", succeeded, expected_descriptors },
    }, 1..) |case, ordinal| {
        var result: TestOutcome = undefined;
        try launchForTest(root, budget, &retention, ordinal, case[0], &result, @import("server_host.zig").Host, @import("server_host_testing.zig").TestParts, @import("tool_result.zig").Result);
        const text = result.text();
        if (std.mem.indexOf(u8, text, case[1]) == null or std.mem.indexOf(u8, text, case[2]) == null) {
            std.debug.print("expected {s} and {s}; got:\n{s}\n", .{ case[1], case[2], text });
            return error.TestUnexpectedResult;
        }
        if (case[2].len != 0) std.debug.print("inheritable /dev/null before launch, matched exactly by Bash:\n{s}(end)\n", .{inherited});
    }
}

test "launched Bash leads its own session, so no terminal can reach its prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 << 20 };
    var entries: [8]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    var result: TestOutcome = undefined;
    try launchForTest(root, budget, &retention, 1, "python3 -c 'import os; print(\"own-session\" if os.getsid(0) == os.getppid() else \"shared\")'; exec 3</dev/tty || echo no-terminal", &result, @import("server_host.zig").Host, @import("server_host_testing.zig").TestParts, @import("tool_result.zig").Result);
    const text = result.text();
    if (std.mem.indexOf(u8, text, "own-session\nno-terminal\n") == null) {
        std.debug.print("expected own-session and no-terminal; got:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

test "an argument list the OS refuses reports the command and environment sizes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = .{ .used = &used, .limit = 1 << 20 } };
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(root);
    var prepared = Prepared{
        .scratch = scratch,
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = "/s",
        .workspace = workspace,
        .bash_path = "/bin/bash",
        .timeout_ms = 10_000,
        .faults = .{ .arguments = true },
        .command = try std.testing.allocator.dupeSentinel(u8, "true", 0),
        .stdout_capture = null,
        .stderr_capture = null,
    };
    defer prepared.cleanup() catch {};
    try prepared.session.set("k7m2qx");
    prepared.stdout_capture = try createOwnedFile(scratch, .@"bash-stdout", 1, 1, .none);
    prepared.stderr_capture = try createOwnedFile(scratch, .@"bash-stderr", 1, 1, .none);
    var refused: ArgumentSizes = .{};
    try std.testing.expectError(error.BashArgumentsTooLarge, prepared.launch(default_facts, null, null, &refused));
    const environment_bytes = "PATH=".len + system_path.fixed.len + 1 + "RUI_ADDRESS=k7m2qx".len + 1 + "RUI_STORE=/s".len + 1 + "RUI_FAULT_PADDING=".len + fault_padding_bytes + 1;
    try std.testing.expectEqual(ArgumentSizes{ .command = 4, .environment = environment_bytes, .variables = 4 }, refused);
    var message: [arguments_message_bytes]u8 = undefined;
    const expected = try std.fmt.allocPrint(std.testing.allocator, "Bash was not started: the system refused its arguments as too large. The command is 4 bytes; the environment is {d} bytes in 4 variables. Put long content in stdin or a file, or send from a shell with a smaller environment.", .{environment_bytes});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, argumentsTooLargeMessage(&message, refused));
    const widest: ArgumentSizes = .{ .command = std.math.maxInt(usize), .environment = std.math.maxInt(usize), .variables = std.math.maxInt(usize) };
    try std.testing.expect(argumentsTooLargeMessage(&message, widest).len <= arguments_message_bytes);
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
    try std.testing.expectError(error.InjectedBashCleanupFailure, file.cleanup(scratch));
    try std.testing.expect(file.file == null);
    try std.testing.expect(!file.published);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    file.cleanup_fault = .none;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer directory.close(std.testing.io);
    try directory.deleteFile(std.testing.io, file.name.slice());
    try file.cleanup(scratch);
    try std.testing.expect(file.published);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "a capture is sealed exactly when its file holds the bytes charged to it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 64 };
    const scratch: Scratch = .{ .io = std.testing.io, .path = root, .budget = budget };
    const Case = struct { written: []const u8, charged: u64, sealed: bool };
    for ([_]Case{
        .{ .written = "", .charged = 0, .sealed = true },
        .{ .written = "abc", .charged = 3, .sealed = true },
        .{ .written = "ab", .charged = 3, .sealed = false },
        .{ .written = "abcd", .charged = 3, .sealed = false },
    }, 1..) |case, ordinal| {
        var file = try createOwnedFile(scratch, .@"bash-stdout", ordinal, 1, .none);
        defer file.cleanup(scratch) catch {};
        try file.file.?.writeStreamingAll(std.testing.io, case.written);
        file.charged = case.charged;
        try std.testing.expect(budget.charge(case.charged));
        try std.testing.expectEqual(case.sealed, file.sealed(std.testing.io));
    }
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
    try std.testing.expect(execution.retired());
    try execution.checkRetired();
    execution.lifecycle.process = .{ .checking_group = .{
        .term = .{ .exited = 0 },
        .cleanup_deadline = started,
    } };
    try std.testing.expect(!execution.retired());
    try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
    execution.lifecycle.process = .{ .running = .{ .deadline = started } };
    try std.testing.expect(!execution.retired());
    try std.testing.expectError(error.BashNotRetired, execution.checkRetired());
}

pub const ContentSource = struct {
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

test "Bash excerpts preserve heads tails UTF-8 boundaries and newline cuts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 << 20 };
    var entries: [16]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    const head = @as([9999]u8, @splat('a'));
    const tail = @as([10000]u8, @splat('a'));
    const replacements = @as([4998]u8, @bitCast(@as([1666][3]u8, @splat("�".*))));
    for ([_]struct { []const u8, []const u8 }{
        .{ "true", "Bash succeeded. Exit code: 0.\n" },
        .{ "printf out", "Bash succeeded. Exit code: 0.\nstdout:\nout" },
        .{ "printf err >&2; exit 3", "Bash failed. Exit code: 3.\nstderr:\nerr" },
        .{ "printf o; printf e >&2", "Bash succeeded. Exit code: 0.\nstdout:\no\nstderr:\ne" },
        .{ "printf z; head -c 20001 /dev/zero | tr '\\0' a", "Bash succeeded. Exit code: 0.\nstdout:\nz" ++ head ++ "\n[2 bytes left out]\n" ++ tail ++ "\nFull output was not retained.\n" },
        .{ "head -c 20000 /dev/zero | tr '\\0' a", "Bash succeeded. Exit code: 0.\nstdout:\n" ++ @as([20000]u8, @splat('a')) },
        .{ "printf HEAD; head -c 49992 /dev/zero | tr '\\0' a; printf TAIL", "Bash succeeded. Exit code: 0.\nstdout:\nHEAD" ++ @as([9996]u8, @splat('a')) ++ "\n[30000 bytes left out]\n" ++ @as([9996]u8, @splat('a')) ++ "TAIL\nFull output was not retained.\n" },
        .{ "printf HEAD >&2; head -c 49992 /dev/zero | tr '\\0' a >&2; printf TAIL >&2", "Bash succeeded. Exit code: 0.\nstderr:\nHEAD" ++ @as([9996]u8, @splat('a')) ++ "\n[30000 bytes left out]\n" ++ @as([9996]u8, @splat('a')) ++ "TAIL\nFull output was not retained.\n" },
        .{ "printf OUT; head -c 19993 /dev/zero | tr '\\0' a; printf LAST; printf ERR >&2; head -c 19993 /dev/zero | tr '\\0' b >&2; printf DONE >&2", "Bash succeeded. Exit code: 0.\nstdout:\nOUT" ++ @as([4997]u8, @splat('a')) ++ "\n[10000 bytes left out]\n" ++ @as([4996]u8, @splat('a')) ++ "LAST\nstderr:\nERR" ++ @as([4997]u8, @splat('b')) ++ "\n[10000 bytes left out]\n" ++ @as([4996]u8, @splat('b')) ++ "DONE\nFull output was not retained.\n" },
        .{ "head -c 9999 /dev/zero | tr '\\0' a; printf '€'; head -c 10000 /dev/zero | tr '\\0' b; printf '€'; head -c 9999 /dev/zero | tr '\\0' c", "Bash succeeded. Exit code: 0.\nstdout:\n" ++ @as([9999]u8, @splat('a')) ++ "\n[10006 bytes left out]\n" ++ @as([9999]u8, @splat('c')) ++ "\nFull output was not retained.\n" },
        .{ "head -c 9900 /dev/zero | tr '\\0' a; printf '\\n'; head -c 30199 /dev/zero | tr '\\0' b; printf '\\n'; head -c 9899 /dev/zero | tr '\\0' c", "Bash succeeded. Exit code: 0.\nstdout:\n" ++ @as([9900]u8, @splat('a')) ++ "\n[30200 bytes left out]\n" ++ @as([9899]u8, @splat('c')) ++ "\nFull output was not retained.\n" },
        .{ "head -c 50000 /dev/zero | tr '\\0' a; head -c 4000 /dev/zero | tr '\\0' '\\377' >&2", "Bash succeeded. Exit code: 0.\nstdout:\n" ++ @as([5000]u8, @splat('a')) ++ "\n[40000 bytes left out]\n" ++ @as([5000]u8, @splat('a')) ++ "\nstderr:\n" ++ replacements ++ "\n[668 bytes left out]\n" ++ replacements ++ "\nFull output was not retained.\n" },
    }, 100..) |case, ordinal| {
        var result: TestOutcome = undefined;
        try launchForTest(root, budget, &retention, ordinal, case[0], &result, @import("server_host.zig").Host, @import("server_host_testing.zig").TestParts, @import("tool_result.zig").Result);
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
    var defaulted = Source{ .bytes = "{\"description\":\"Print output\",\"cmd\":\"echo\"}" };
    try std.testing.expectEqual(@as(?u64, null), (try tools.inspectBashArguments(&defaulted)).?.timeout_ms);
    inline for (.{
        "{\"description\":\"Print output\",\"cmd\":\"echo\\u0000bad\",\"timeout_ms\":null}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":0}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":9223372036854775808}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",\"timeout_ms\":1.5}",
        "{\"description\":\"Print output\",\"cmd\":\"echo\",}",
    }) |invalid| {
        var invalid_source = Source{ .bytes = invalid };
        try std.testing.expect(!try tools.validBashArguments(&invalid_source));
    }
}

test "Host facts carry this executable's directory, the system PATH and an absolute HOME" {
    const executable = try @import("self_executable.zig").path(std.testing.io);
    const facts = try readHostFacts(std.testing.io, std.testing.allocator, "/home/peer");
    defer freeHostFacts(std.testing.allocator, facts);
    try std.testing.expectEqualStrings(std.fs.path.dirname(executable).?, facts.executable_dir.?);
    const scratch = try std.testing.allocator.create(system_path.Buffer);
    defer std.testing.allocator.destroy(scratch);
    var system: [system_path.max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(try system_path.read(std.testing.io, scratch, &system), facts.system_path);
    try std.testing.expectEqualStrings("/home/peer", facts.home.?);
    const relative = try readHostFacts(std.testing.io, std.testing.allocator, "relative");
    defer freeHostFacts(std.testing.allocator, relative);
    try std.testing.expectEqual(null, relative.home);
}

test "yielded Bash preparation leaves checkpoints free while retaining its descriptor" {
    const Store = store.Store;
    const testingStore = store.testing.testingSqliteStore;
    const configureTestSession = store.testing.configureTestSession;
    const testingPublicProjection = store.testingPublicProjection;
    const ActionExecutionInput = store.ActionExecutionInput;
    const c = store.testingSqlite.c;
    const bash = @import("bash.zig");
    for ([_]usize{ 0, 1024 * 1024 }) |padding_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var database: Store = undefined;
        try testingStore(&database, &tmp, std.testing.io);
        defer database.close() catch unreachable;
        const command = "printf " ++ @as([16384]u8, @splat('x'));
        const padding = try std.testing.allocator.alloc(u8, padding_length);
        defer std.testing.allocator.free(padding);
        @memset(padding, ' ');
        const descriptor = try std.testing.allocator.print("{{\"cmd\":\"{s}\",{s}\"timeout_ms\":null,\"description\":\"Print marker\"}}", .{ command, padding });
        defer std.testing.allocator.free(descriptor);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, descriptor, .{});
        defer std.testing.allocator.free(encoded);
        const request = try testingPublicProjection(&database, &tmp, &.{.{
            .encoded = encoded[1 .. encoded.len - 1],
            .decoded = descriptor,
        }});
        var input: ActionExecutionInput = .{
            .binding = .{ .action_id = 11, .parent_operation_id = 1, .turn_id = 1 },
            .session = request.session,
            .sender_handle = .{},
            .runner = .{ .bash = .{ .workspace = .{} } },
            .arguments = .{ .length = descriptor.len, .digest = undefined },
            .timeout_ms = 1000,
        };
        try input.runner.bash.workspace.set(database.selector.slice());
        var used: std.atomic.Value(u64) = .init(0);
        const scratch: bash.Scratch = .{ .io = std.testing.io, .path = database.selector.slice(), .budget = .{ .used = &used, .limit = 4096 } };
        var preparation: bash.Preparation = undefined;
        if (preparation.start(scratch, std.testing.allocator, try database.openPublicConversationContent(&request), &input, database.selector.slice(), "/bin/bash", 11, .{})) |initial| {
            var failure = initial;
            try failure.cleanup.cleanup(scratch);
            return failure.cause;
        }
        var owned = true;
        defer if (owned) {
            var cleanup = preparation.cancel();
            cleanup.cleanup(scratch) catch unreachable;
        };
        var prepared: bash.Prepared = undefined;
        try std.testing.expect(preparation.advance(&prepared) == .pending);
        _ = try configureTestSession(&database, "bash-checkpoint");
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(database.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        while (true) {
            var progress = preparation.advance(&prepared);
            switch (progress) {
                .pending => {},
                .prepared => {
                    owned = false;
                    defer prepared.cleanup() catch unreachable;
                    try std.testing.expectEqualStrings(command, prepared.command.?);
                    break;
                },
                .failed => |*failure| {
                    owned = false;
                    try failure.cleanup.cleanup(scratch);
                    return failure.cause;
                },
            }
        }
        try std.testing.expectEqual(@as(u64, 0), used.load(.monotonic));
    }
}

test "Bash capture reclaims MCP output from the same scratch budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const length = comptime @import("tool_record.zig").Runner.mcp.resultProfile(true).excerpt_bytes + 1;
    const budget: ScratchBudget = .{ .used = &used, .limit = length };
    var entries: [4]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    const text: [length]u8 = @splat('x');
    var spill = output_retention.Spill.open(&retention, "mcp-output-1-1.tmp") orelse return error.TestUnexpectedResult;
    spill.write(&text);
    try std.testing.expect(spill.alive());
    spill.close();
    spill.keep();
    try std.testing.expectEqual(@as(u64, length), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), retention.occupied());
    var result: TestOutcome = undefined;
    try launchForTest(root, retention.sharedBudget(), &retention, 2, "printf bash", &result, @import("server_host.zig").Host, @import("server_host_testing.zig").TestParts, @import("tool_result.zig").Result);
    try std.testing.expectEqual(store.ActionResolutionCode.succeeded, result.code);
    try std.testing.expectEqualStrings("Bash succeeded. Exit code: 0.\nstdout:\nbash", result.text());
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "mcp-output-1-1.tmp", .{}));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), retention.occupied());
}

test {
    _ = @import("bash_result_legacy_test.zig");
}
