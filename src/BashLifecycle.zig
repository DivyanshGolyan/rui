//! Value transitions for one launched Bash Attempt.
//!
//! The lifecycle owns process phases, pipe terminal reasons, the stop
//! reason, signaling facts and the resolution they imply. It performs no
//! syscalls and reads no clock: callers supply each service-time
//! observation and native result, then perform any returned `Signal`.
//! `bash.Execution` holds the child, process group and descriptors and keeps
//! them aligned with these transitions. See ARCHITECTURE.md, "Bash lifecycle
//! and capture".
const std = @import("std");

const Self = @This();

pub const termination_grace_ms: u64 = 100;
pub const cleanup_observation_ms: u64 = 5_000;

pub const Timestamp = std.Io.Clock.Timestamp;

pub const Term = union(enum) {
    exited: u8,
    signal: u8,
    unknown: u32,
};

pub const StopReason = enum { none, stopped, timed_out, infrastructure_shutdown, capture_failed };
pub const CaptureFailure = enum { none, read, write, exhausted, seal };
pub const PipeClose = enum { eof, incomplete, failed };

/// Saved meaning of a retired execution. Tags match
/// `store.ActionResolutionCode`, which the owner maps by name.
pub const Resolution = enum { succeeded, failed, cancelled, timed_out, infrastructure_shutdown, storage_failed };

/// Signals the owner must send after a transition. Every entry into grace
/// terminates the anchored original group; grace expiry kills that group,
/// and also the direct child while its exit remains unobserved.
pub const Signal = enum { terminate_group, kill_group, kill_group_and_leader };

pub const SignalResult = enum { delivered, failed, group_permission_denied };

pub const Process = union(enum) {
    running: struct {
        deadline: Timestamp,
        observed: ?Term = null,
    },
    grace: struct {
        kill_at: Timestamp,
        cleanup_deadline: Timestamp,
        observed: ?Term,
    },
    reaping: struct {
        cleanup_deadline: Timestamp,
        observed: ?Term,
    },
    checking_group: struct {
        term: Term,
        cleanup_deadline: Timestamp,
    },
    gone: Term,
};

pub const Pipe = union(enum) {
    reading,
    /// Finite tail snapshotted at capture cutoff: bytes still owed.
    tail: u64,
    closed: PipeClose,
};

pub const Stream = enum(u1) { stdout, stderr };

pub const PipeEnd = union(enum) {
    eof,
    incomplete,
    failed: CaptureFailure,
};

pub const Expiry = struct {
    deadline: Timestamp,
    signal: Signal,
};

pub const Cutoff = struct {
    /// Pipes still reading at cutoff; each needs a queued-byte snapshot.
    snapshot: [2]bool,
    /// The cleanup watchdog expired before original-group absence.
    unconfirmed: bool,

    pub fn changed(self: Cutoff) bool {
        return self.snapshot[0] or self.snapshot[1];
    }
};

process: Process,
pipes: [2]Pipe = .{ .reading, .reading },
stop_reason: StopReason = .none,
capture_failure: CaptureFailure = .none,
signal_failure: bool = false,
group_permission_denied: bool = false,

pub fn start(started: Timestamp, timeout_ms: u64) Self {
    return .{ .process = .{ .running = .{ .deadline = addMilliseconds(started, timeout_ms) } } };
}

pub fn addMilliseconds(timestamp: Timestamp, milliseconds: u64) Timestamp {
    return timestamp.addDuration(.{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    });
}

pub fn reached(now: Timestamp, deadline: Timestamp) bool {
    return now.raw.nanoseconds >= deadline.raw.nanoseconds;
}

/// Records why termination began. The first reason and the first grace
/// deadlines stand; repeated requests extend neither.
pub fn requestTermination(self: *Self, reason: StopReason, now: Timestamp) ?Signal {
    std.debug.assert(reason != .none);
    if (self.stop_reason == .none) self.stop_reason = reason;
    return self.beginGrace(now);
}

/// Starts termination when the total budget elapsed by `now`.
pub fn expireDeadline(self: *Self, now: Timestamp) ?Expiry {
    if (self.process != .running or !reached(now, self.process.running.deadline)) return null;
    const deadline = self.process.running.deadline;
    if (self.stop_reason == .none) self.stop_reason = .timed_out;
    return .{ .deadline = deadline, .signal = self.beginGrace(now).? };
}

/// True while the direct child's terminal status is still unobserved.
pub fn awaitsLeader(self: *const Self) bool {
    return switch (self.process) {
        .running => |value| value.observed == null,
        .grace => |value| value.observed == null,
        .reaping, .checking_group, .gone => false,
    };
}

/// Records a non-consuming child observation. Natural leader exit still
/// retires the original group, so a running process enters grace.
pub fn observeLeader(self: *Self, term: Term, now: Timestamp) ?Signal {
    std.debug.assert(self.awaitsLeader());
    switch (self.process) {
        .running => |*value| value.observed = term,
        .grace => |*value| value.observed = term,
        else => unreachable,
    }
    return self.beginGrace(now);
}

fn beginGrace(self: *Self, now: Timestamp) ?Signal {
    if (self.process != .running) return null;
    // Copy before assigning: the new union is constructed in place.
    const observed = self.process.running.observed;
    self.process = .{ .grace = .{
        .kill_at = addMilliseconds(now, termination_grace_ms),
        .cleanup_deadline = addMilliseconds(now, cleanup_observation_ms),
        .observed = observed,
    } };
    return .terminate_group;
}

pub fn expireGrace(self: *Self, now: Timestamp) ?Signal {
    if (self.process != .grace or !reached(now, self.process.grace.kill_at)) return null;
    const grace = self.process.grace;
    self.process = .{ .reaping = .{
        .cleanup_deadline = grace.cleanup_deadline,
        .observed = grace.observed,
    } };
    return if (grace.observed == null) .kill_group_and_leader else .kill_group;
}

pub fn recordSignal(self: *Self, result: SignalResult) void {
    switch (result) {
        .delivered => {},
        .failed => self.signal_failure = true,
        .group_permission_denied => self.group_permission_denied = true,
    }
}

/// The reap found no exited child. Unconfirmed after the watchdog.
pub fn reapPending(self: *const Self, now: Timestamp) error{BashCleanupUnconfirmed}!void {
    if (reached(now, self.process.reaping.cleanup_deadline)) return error.BashCleanupUnconfirmed;
}

/// Consumes the direct child's status. An earlier observation remains the
/// recorded status; disagreement is reported after the reap is retired.
pub fn reaped(self: *Self, term: Term) error{BashStatusChanged}!void {
    const reaping = self.process.reaping;
    self.process = .{ .checking_group = .{
        .term = reaping.observed orelse term,
        .cleanup_deadline = reaping.cleanup_deadline,
    } };
    if (reaping.observed) |observed| {
        if (!std.meta.eql(observed, term)) return error.BashStatusChanged;
    }
}

pub fn groupAbsent(self: *Self) void {
    const term = self.process.checking_group.term;
    self.process = .{ .gone = term };
}

/// Capture cutoff: after original-group absence, or when the cleanup
/// watchdog expires first, every reading pipe drains one finite tail.
pub fn cutoff(self: *const Self, now: Timestamp) ?Cutoff {
    const expired = switch (self.process) {
        .grace => |value| reached(now, value.cleanup_deadline),
        .reaping => |value| reached(now, value.cleanup_deadline),
        .checking_group => |value| reached(now, value.cleanup_deadline),
        .running, .gone => false,
    };
    if (self.process != .gone and !expired) return null;
    return .{
        .snapshot = .{ self.pipes[0] == .reading, self.pipes[1] == .reading },
        .unconfirmed = expired,
    };
}

/// Starts a finite tail of `queued` bytes, or ends capture when the queued
/// size cannot be observed.
pub fn beginTail(self: *Self, stream: Stream, queued: ?u64, now: Timestamp) ?Signal {
    std.debug.assert(self.pipes[@backingInt(stream)] == .reading);
    if (queued) |bytes| {
        self.pipes[@backingInt(stream)] = .{ .tail = bytes };
        return null;
    }
    return self.endPipe(stream, .{ .failed = .read }, now);
}

pub fn drainedTail(self: *Self, stream: Stream, bytes: u64) void {
    const pipe = &self.pipes[@backingInt(stream)];
    std.debug.assert(bytes != 0 and bytes <= pipe.tail);
    pipe.tail -= bytes;
}

/// Records a pipe's terminal reason. A capture failure stops the Attempt:
/// output can no longer be complete.
pub fn endPipe(self: *Self, stream: Stream, end: PipeEnd, now: Timestamp) ?Signal {
    const pipe = &self.pipes[@backingInt(stream)];
    std.debug.assert(pipe.* != .closed);
    switch (end) {
        .eof => pipe.* = .{ .closed = .eof },
        .incomplete => pipe.* = .{ .closed = .incomplete },
        .failed => |failure| {
            std.debug.assert(failure != .none);
            pipe.* = .{ .closed = .failed };
            self.capture_failure = failure;
            return self.requestTermination(.capture_failed, now);
        },
    }
    return null;
}

/// Sealing failure is discovered after retirement and only affects meaning.
pub fn recordSealFailure(self: *Self) void {
    self.capture_failure = .seal;
}

pub fn pipesClosed(self: *const Self) bool {
    return self.pipes[0] == .closed and self.pipes[1] == .closed;
}

pub fn retired(self: *const Self) bool {
    return self.process == .gone and self.pipesClosed();
}

/// Writers outlived group termination: a pipe closed without EOF.
pub fn captureIncomplete(self: *const Self) bool {
    for (self.pipes) |pipe| switch (pipe) {
        .closed => |reason| if (reason != .eof) return true,
        else => return true,
    };
    return false;
}

pub fn resolution(self: *const Self) Resolution {
    std.debug.assert(self.retired());
    return switch (self.stop_reason) {
        .stopped => .cancelled,
        .timed_out => .timed_out,
        .infrastructure_shutdown => .infrastructure_shutdown,
        .capture_failed => .storage_failed,
        .none => if (self.capture_failure != .none)
            .storage_failed
        else switch (self.process.gone) {
            .exited => |code| if (code == 0) .succeeded else .failed,
            else => .failed,
        },
    };
}

fn at(milliseconds: u64) Timestamp {
    return addMilliseconds(std.Io.Timestamp.fromNanoseconds(0).withClock(.awake), milliseconds);
}

fn retire(self: *Self, term: Term, now: Timestamp) !void {
    if (self.awaitsLeader()) _ = self.observeLeader(term, now);
    _ = self.expireGrace(addMilliseconds(now, termination_grace_ms));
    try self.reaped(term);
    self.groupAbsent();
    for (std.enums.values(Stream)) |stream| {
        if (self.pipes[@backingInt(stream)] != .closed) _ = self.endPipe(stream, .eof, now);
    }
}

test "natural exit terminates the original group before reaping" {
    var lifecycle = Self.start(at(0), 1_000);
    try std.testing.expect(lifecycle.awaitsLeader());
    // Closed pipes never substitute for process retirement.
    lifecycle.pipes = .{ .{ .closed = .eof }, .{ .closed = .eof } };
    try std.testing.expect(!lifecycle.retired());
    lifecycle.pipes = .{ .reading, .reading };
    try std.testing.expectEqual(Signal.terminate_group, lifecycle.observeLeader(.{ .exited = 0 }, at(10)).?);
    try std.testing.expect(!lifecycle.awaitsLeader());
    try std.testing.expectEqual(StopReason.none, lifecycle.stop_reason);
    try std.testing.expect(lifecycle.expireGrace(at(109)) == null);
    // The observed child is not signaled individually.
    try std.testing.expectEqual(Signal.kill_group, lifecycle.expireGrace(at(110)).?);
    try lifecycle.reaped(.{ .exited = 0 });
    try std.testing.expect(!lifecycle.retired());
    lifecycle.groupAbsent();
    try std.testing.expect(!lifecycle.retired());
    _ = lifecycle.endPipe(.stdout, .eof, at(111));
    _ = lifecycle.endPipe(.stderr, .eof, at(111));
    try std.testing.expect(lifecycle.retired());
    try std.testing.expect(!lifecycle.captureIncomplete());
    try std.testing.expectEqual(Resolution.succeeded, lifecycle.resolution());
}

test "deadline expiry fixes grace from the service-time observation" {
    var lifecycle = Self.start(at(0), 100);
    try std.testing.expect(lifecycle.expireDeadline(at(99)) == null);
    try std.testing.expect(lifecycle.process == .running);
    const expiry = lifecycle.expireDeadline(at(130)).?;
    try std.testing.expectEqual(at(100).raw.nanoseconds, expiry.deadline.raw.nanoseconds);
    try std.testing.expectEqual(Signal.terminate_group, expiry.signal);
    try std.testing.expectEqual(StopReason.timed_out, lifecycle.stop_reason);
    try std.testing.expectEqual(at(230).raw.nanoseconds, lifecycle.process.grace.kill_at.raw.nanoseconds);
    try std.testing.expectEqual(at(5_130).raw.nanoseconds, lifecycle.process.grace.cleanup_deadline.raw.nanoseconds);
    // Expiry happens once.
    try std.testing.expect(lifecycle.expireDeadline(at(131)) == null);
    // The unobserved leader is killed individually as well as its group.
    try std.testing.expectEqual(Signal.kill_group_and_leader, lifecycle.expireGrace(at(230)).?);
}

test "the first termination fixes reason and deadlines" {
    var lifecycle = Self.start(at(0), 100);
    try std.testing.expectEqual(Signal.terminate_group, lifecycle.requestTermination(.infrastructure_shutdown, at(1)).?);
    const grace = lifecycle.process.grace;
    for ([_]StopReason{ .stopped, .timed_out, .capture_failed, .infrastructure_shutdown }) |reason| {
        try std.testing.expect(lifecycle.requestTermination(reason, at(50)) == null);
    }
    try std.testing.expect(lifecycle.expireDeadline(at(200)) == null);
    try std.testing.expectEqual(StopReason.infrastructure_shutdown, lifecycle.stop_reason);
    try std.testing.expectEqual(grace.kill_at.raw.nanoseconds, lifecycle.process.grace.kill_at.raw.nanoseconds);
    try std.testing.expectEqual(grace.cleanup_deadline.raw.nanoseconds, lifecycle.process.grace.cleanup_deadline.raw.nanoseconds);
    // An observation during grace changes only the leader-kill decision.
    try std.testing.expect(lifecycle.observeLeader(.{ .signal = 15 }, at(60)) == null);
    try std.testing.expectEqual(Signal.kill_group, lifecycle.expireGrace(at(101)).?);
}

test "a later reap disagreeing with the observation keeps the observed status" {
    var lifecycle = Self.start(at(0), 100);
    _ = lifecycle.observeLeader(.{ .exited = 3 }, at(1));
    _ = lifecycle.expireGrace(at(101)).?;
    try std.testing.expectError(error.BashStatusChanged, lifecycle.reaped(.{ .exited = 4 }));
    try std.testing.expectEqual(Term{ .exited = 3 }, lifecycle.process.checking_group.term);

    var unobserved = Self.start(at(0), 100);
    _ = unobserved.requestTermination(.stopped, at(1));
    _ = unobserved.expireGrace(at(101)).?;
    try unobserved.reaped(.{ .signal = 9 });
    try std.testing.expectEqual(Term{ .signal = 9 }, unobserved.process.checking_group.term);
}

test "reaping is unconfirmed only from the cleanup watchdog" {
    var lifecycle = Self.start(at(0), 100);
    _ = lifecycle.requestTermination(.stopped, at(0));
    _ = lifecycle.expireGrace(at(100)).?;
    try lifecycle.reapPending(at(4_999));
    try std.testing.expectError(error.BashCleanupUnconfirmed, lifecycle.reapPending(at(5_000)));
}

test "capture cutoff waits for group absence or the cleanup watchdog" {
    const Phase = enum { running, grace, reaping, checking_group, gone };
    for (std.enums.values(Phase)) |phase| for ([_]u64{ 4_999, 5_000, 5_001 }) |now_ms| {
        var lifecycle = Self.start(at(0), 10_000);
        _ = lifecycle.endPipe(.stderr, .eof, at(0));
        if (phase != .running) _ = lifecycle.requestTermination(.stopped, at(0));
        if (@backingInt(phase) >= @backingInt(Phase.reaping)) _ = lifecycle.expireGrace(at(100)).?;
        if (@backingInt(phase) >= @backingInt(Phase.checking_group)) try lifecycle.reaped(.{ .exited = 0 });
        if (phase == .gone) lifecycle.groupAbsent();

        const watchdog = now_ms >= 5_000 and phase != .running and phase != .gone;
        const result = lifecycle.cutoff(at(now_ms));
        if (phase == .gone or watchdog) {
            try std.testing.expectEqual(watchdog, result.?.unconfirmed);
            try std.testing.expectEqual([2]bool{ true, false }, result.?.snapshot);
            try std.testing.expect(lifecycle.beginTail(.stdout, 2, at(now_ms)) == null);
            // A tail is never snapshotted twice.
            try std.testing.expect(!lifecycle.cutoff(at(now_ms)).?.changed());
        } else {
            try std.testing.expect(result == null);
        }
    };
}

test "a finite tail closes complete only on EOF" {
    var lifecycle = Self.start(at(0), 100);
    _ = lifecycle.observeLeader(.{ .exited = 0 }, at(0));
    _ = lifecycle.expireGrace(at(100)).?;
    try lifecycle.reaped(.{ .exited = 0 });
    lifecycle.groupAbsent();
    _ = lifecycle.beginTail(.stdout, 3, at(101));
    _ = lifecycle.beginTail(.stderr, 0, at(101));
    lifecycle.drainedTail(.stdout, 2);
    lifecycle.drainedTail(.stdout, 1);
    try std.testing.expectEqual(Pipe{ .tail = 0 }, lifecycle.pipes[0]);
    _ = lifecycle.endPipe(.stdout, .eof, at(102));
    try std.testing.expectEqual(Pipe{ .closed = .eof }, lifecycle.pipes[0]);
    // An open tail is not yet complete capture.
    try std.testing.expect(lifecycle.captureIncomplete());
    _ = lifecycle.endPipe(.stderr, .incomplete, at(102));
    try std.testing.expect(lifecycle.retired());
    try std.testing.expect(lifecycle.captureIncomplete());
    // Incomplete capture from an escaped writer does not change meaning.
    try std.testing.expectEqual(Resolution.succeeded, lifecycle.resolution());
}

test "capture failure stops a running Attempt and saves storage failure" {
    for (std.enums.values(CaptureFailure)) |failure| {
        if (failure == .none or failure == .seal) continue;
        var lifecycle = Self.start(at(0), 100);
        try std.testing.expectEqual(Signal.terminate_group, lifecycle.endPipe(.stderr, .{ .failed = failure }, at(5)).?);
        try std.testing.expectEqual(StopReason.capture_failed, lifecycle.stop_reason);
        try std.testing.expectEqual(failure, lifecycle.capture_failure);
        try std.testing.expectEqual(at(105).raw.nanoseconds, lifecycle.process.grace.kill_at.raw.nanoseconds);
        try lifecycle.retire(.{ .exited = 0 }, at(6));
        try std.testing.expectEqual(Resolution.storage_failed, lifecycle.resolution());
    }

    // An unobservable tail size fails capture without restarting grace.
    var lifecycle = Self.start(at(0), 100);
    _ = lifecycle.requestTermination(.timed_out, at(0));
    _ = lifecycle.expireGrace(at(100)).?;
    try std.testing.expect(lifecycle.beginTail(.stdout, null, at(5_000)) == null);
    try std.testing.expectEqual(Pipe{ .closed = .failed }, lifecycle.pipes[0]);
    try std.testing.expectEqual(CaptureFailure.read, lifecycle.capture_failure);
    try std.testing.expectEqual(StopReason.timed_out, lifecycle.stop_reason);
}

test "resolution follows the first stop reason, then capture, then exit status" {
    const cases = [_]struct { reason: ?StopReason, failure: CaptureFailure, term: Term, expected: Resolution }{
        .{ .reason = null, .failure = .none, .term = .{ .exited = 0 }, .expected = .succeeded },
        .{ .reason = null, .failure = .none, .term = .{ .exited = 1 }, .expected = .failed },
        .{ .reason = null, .failure = .none, .term = .{ .signal = 9 }, .expected = .failed },
        .{ .reason = null, .failure = .none, .term = .{ .unknown = 0 }, .expected = .failed },
        .{ .reason = null, .failure = .seal, .term = .{ .exited = 0 }, .expected = .storage_failed },
        .{ .reason = .stopped, .failure = .seal, .term = .{ .exited = 0 }, .expected = .cancelled },
        .{ .reason = .timed_out, .failure = .seal, .term = .{ .exited = 0 }, .expected = .timed_out },
        .{ .reason = .infrastructure_shutdown, .failure = .none, .term = .{ .exited = 0 }, .expected = .infrastructure_shutdown },
        .{ .reason = .capture_failed, .failure = .none, .term = .{ .exited = 0 }, .expected = .storage_failed },
    };
    for (cases) |case| {
        var lifecycle = Self.start(at(0), 100);
        if (case.reason) |reason| _ = lifecycle.requestTermination(reason, at(1));
        try lifecycle.retire(case.term, at(2));
        if (case.failure == .seal) lifecycle.recordSealFailure();
        try std.testing.expectEqual(case.expected, lifecycle.resolution());
    }
}

test "signal results are independent facts" {
    var lifecycle = Self.start(at(0), 100);
    lifecycle.recordSignal(.delivered);
    try std.testing.expect(!lifecycle.signal_failure and !lifecycle.group_permission_denied);
    lifecycle.recordSignal(.group_permission_denied);
    try std.testing.expect(!lifecycle.signal_failure and lifecycle.group_permission_denied);
    lifecycle.recordSignal(.failed);
    lifecycle.recordSignal(.delivered);
    try std.testing.expect(lifecycle.signal_failure and lifecycle.group_permission_denied);
}
