const std = @import("std");
const deadline = @import("deadline.zig");

const Self = @This();

pub const termination_grace_ms: u64 = 100;
pub const cleanup_observation_ms: u64 = 5_000;

pub const Timestamp = deadline.Timestamp;

pub const Term = union(enum) {
    exited: u8,
    signal: u8,
    unknown: u32,
};

pub const StopReason = enum { none, stopped, timed_out, infrastructure_shutdown, capture_failed };
pub const CaptureFailure = enum { none, read, write, exhausted, seal };
pub const PipeClose = enum { eof, incomplete, failed };

pub const Resolution = enum { succeeded, failed, cancelled, timed_out, infrastructure_shutdown, storage_failed };

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
    tail: u64,
    closed: PipeClose,
};

pub const Stream = enum(u1) { stdout, stderr };
pub const Pipes = std.enums.EnumArray(Stream, Pipe);

pub const PipeRead = union(enum) {
    empty,
    bytes: u64,
    end,
    failed: CaptureFailure,
};

pub const Expiry = struct {
    deadline: Timestamp,
    signal: Signal,
};

pub const Cutoff = struct {
    snapshot: std.enums.EnumSet(Stream),
    unconfirmed: bool,
};

process: Process,
pipes: Pipes = .initFill(.reading),
stop_reason: StopReason = .none,
capture_failure: CaptureFailure = .none,
signal_failure: bool = false,
group_permission_denied: bool = false,

pub fn start(started: Timestamp, timeout_ms: u64) Self {
    return .{ .process = .{ .running = .{ .deadline = deadline.after(started, timeout_ms) } } };
}

pub fn requestTermination(self: *Self, reason: StopReason, now: Timestamp) ?Signal {
    std.debug.assert(reason != .none);
    if (self.stop_reason == .none) self.stop_reason = reason;
    return self.beginGrace(now);
}

pub fn expireDeadline(self: *Self, now: Timestamp) ?Expiry {
    if (self.process != .running or !deadline.reached(now, self.process.running.deadline)) return null;
    const expired = self.process.running.deadline;
    if (self.stop_reason == .none) self.stop_reason = .timed_out;
    return .{ .deadline = expired, .signal = self.beginGrace(now).? };
}

pub fn awaitsLeader(self: *const Self) bool {
    return switch (self.process) {
        .running => |value| value.observed == null,
        .grace => |value| value.observed == null,
        .reaping, .checking_group, .gone => false,
    };
}

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
    const observed = self.process.running.observed;
    self.process = .{ .grace = .{
        .kill_at = deadline.after(now, termination_grace_ms),
        .cleanup_deadline = deadline.after(now, cleanup_observation_ms),
        .observed = observed,
    } };
    return .terminate_group;
}

pub fn expireGrace(self: *Self, now: Timestamp) ?Signal {
    if (self.process != .grace or !deadline.reached(now, self.process.grace.kill_at)) return null;
    return self.endGrace();
}

/// The grace exists so group members can act on TERM. Once the leader is
/// observed and nothing else is in its group, there is no one to wait for.
pub fn awaitsGroup(self: *const Self) bool {
    return self.process == .grace and self.process.grace.observed != null;
}

pub fn groupHoldsOnlyLeader(self: *Self) Signal {
    std.debug.assert(self.awaitsGroup());
    return self.endGrace();
}

fn endGrace(self: *Self) Signal {
    const grace = self.process.grace;
    self.process = .{ .reaping = .{
        .cleanup_deadline = grace.cleanup_deadline,
        .observed = grace.observed,
    } };
    return if (grace.observed == null) .kill_group_and_leader else .kill_group;
}

pub fn signalFailed(self: *const Self) bool {
    return self.signal_failure or self.group_permission_denied;
}

pub fn recordSignal(self: *Self, result: SignalResult) void {
    switch (result) {
        .delivered => {},
        .failed => self.signal_failure = true,
        .group_permission_denied => self.group_permission_denied = true,
    }
}

pub fn reapPending(self: *const Self, now: Timestamp) error{BashCleanupUnconfirmed}!void {
    std.debug.assert(self.process == .reaping);
    if (deadline.reached(now, self.process.reaping.cleanup_deadline)) return error.BashCleanupUnconfirmed;
}

pub fn reaped(self: *Self, term: Term) error{BashStatusChanged}!void {
    std.debug.assert(self.process == .reaping);
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
    std.debug.assert(self.process == .checking_group);
    const term = self.process.checking_group.term;
    self.process = .{ .gone = term };
}

pub fn cutoff(self: *const Self, now: Timestamp) ?Cutoff {
    const expired = switch (self.process) {
        .grace => |value| deadline.reached(now, value.cleanup_deadline),
        .reaping => |value| deadline.reached(now, value.cleanup_deadline),
        .checking_group => |value| deadline.reached(now, value.cleanup_deadline),
        .running, .gone => false,
    };
    if (self.process != .gone and !expired) return null;
    var snapshot: std.enums.EnumSet(Stream) = .empty;
    for (std.enums.values(Stream)) |stream| {
        if (self.pipes.get(stream) == .reading) snapshot.insert(stream);
    }
    return .{ .snapshot = snapshot, .unconfirmed = expired };
}

pub fn beginTail(self: *Self, stream: Stream, queued: ?u64) void {
    const pipe = self.pipes.getPtr(stream);
    std.debug.assert(pipe.* == .reading);
    if (queued) |bytes| {
        pipe.* = .{ .tail = bytes };
    } else {
        pipe.* = .{ .closed = .failed };
        self.capture_failure = .read;
    }
}

pub fn observePipe(self: *Self, stream: Stream, read: PipeRead, now: Timestamp) ?Signal {
    const pipe = self.pipes.getPtr(stream);
    switch (pipe.*) {
        .closed => unreachable,
        .reading => switch (read) {
            .empty, .bytes => {},
            .end => pipe.* = .{ .closed = .eof },
            .failed => |failure| {
                self.failPipe(pipe, failure);
                return self.requestTermination(.capture_failed, now);
            },
        },
        .tail => |owed| switch (read) {
            .empty => if (owed == 0) {
                pipe.* = .{ .closed = .incomplete };
            },
            .bytes => |bytes| if (owed == 0) {
                pipe.* = .{ .closed = .incomplete };
            } else {
                std.debug.assert(bytes != 0 and bytes <= owed);
                pipe.* = .{ .tail = owed - bytes };
            },
            .end => if (owed == 0) {
                pipe.* = .{ .closed = .eof };
            } else self.failPipe(pipe, .read),
            .failed => |failure| self.failPipe(pipe, failure),
        },
    }
    return null;
}

fn failPipe(self: *Self, pipe: *Pipe, failure: CaptureFailure) void {
    std.debug.assert(failure != .none);
    pipe.* = .{ .closed = .failed };
    self.capture_failure = failure;
}

pub fn recordSealFailure(self: *Self) void {
    self.capture_failure = .seal;
}

pub fn pipesClosed(self: *const Self) bool {
    return self.pipes.get(.stdout) == .closed and self.pipes.get(.stderr) == .closed;
}

pub fn retired(self: *const Self) bool {
    return self.process == .gone and self.pipesClosed();
}

pub fn captureIncomplete(self: *const Self) bool {
    for (self.pipes.values) |pipe| switch (pipe) {
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
    return deadline.after(std.Io.Timestamp.fromNanoseconds(0).withClock(.awake), milliseconds);
}

fn retire(self: *Self, term: Term, now: Timestamp) !void {
    if (self.awaitsLeader()) _ = self.observeLeader(term, now);
    _ = self.expireGrace(deadline.after(now, termination_grace_ms));
    try self.reaped(term);
    self.groupAbsent();
    for (std.enums.values(Stream)) |stream| {
        switch (self.pipes.get(stream)) {
            .closed => {},
            .reading => _ = self.observePipe(stream, .end, now),
            .tail => |owed| {
                if (owed != 0) _ = self.observePipe(stream, .{ .bytes = owed }, now);
                _ = self.observePipe(stream, .end, now);
            },
        }
    }
}

test "natural exit terminates the original group before reaping" {
    var lifecycle = Self.start(at(0), 1_000);
    try std.testing.expect(lifecycle.awaitsLeader());
    lifecycle.pipes = .initFill(.{ .closed = .eof });
    try std.testing.expect(!lifecycle.retired());
    lifecycle.pipes = .initFill(.reading);
    try std.testing.expectEqual(Signal.terminate_group, lifecycle.observeLeader(.{ .exited = 0 }, at(10)).?);
    try std.testing.expect(!lifecycle.awaitsLeader());
    try std.testing.expectEqual(StopReason.none, lifecycle.stop_reason);
    try std.testing.expect(lifecycle.expireGrace(at(109)) == null);
    try std.testing.expectEqual(Signal.kill_group, lifecycle.expireGrace(at(110)).?);
    try lifecycle.reaped(.{ .exited = 0 });
    try std.testing.expect(!lifecycle.retired());
    lifecycle.groupAbsent();
    try std.testing.expect(!lifecycle.retired());
    try std.testing.expect(lifecycle.observePipe(.stdout, .{ .bytes = 7 }, at(111)) == null);
    try std.testing.expect(lifecycle.observePipe(.stdout, .empty, at(111)) == null);
    try std.testing.expectEqual(Pipe.reading, lifecycle.pipes.get(.stdout));
    _ = lifecycle.observePipe(.stdout, .end, at(111));
    _ = lifecycle.observePipe(.stderr, .end, at(111));
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
    try std.testing.expect(lifecycle.expireDeadline(at(131)) == null);
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

test "a lone observed leader ends the grace at once, and only then" {
    const Entry = enum { exit_while_running, stop_then_exit, stop_unobserved, running };
    for (std.enums.values(Entry)) |entry| {
        var lifecycle = Self.start(at(0), 1_000);
        switch (entry) {
            .exit_while_running => _ = lifecycle.observeLeader(.{ .exited = 0 }, at(10)),
            .stop_then_exit => {
                _ = lifecycle.requestTermination(.stopped, at(10));
                try std.testing.expect(lifecycle.observeLeader(.{ .signal = 15 }, at(20)) == null);
            },
            .stop_unobserved => _ = lifecycle.requestTermination(.stopped, at(10)),
            .running => {},
        }
        const lone = entry == .exit_while_running or entry == .stop_then_exit;
        try std.testing.expectEqual(lone, lifecycle.awaitsGroup());
        if (!lone) continue;
        try std.testing.expectEqual(Signal.kill_group, lifecycle.groupHoldsOnlyLeader());
        try std.testing.expect(lifecycle.process == .reaping);
        try std.testing.expect(!lifecycle.awaitsGroup());
        try std.testing.expect(lifecycle.expireGrace(at(1_000)) == null);
        try std.testing.expectEqual(at(5_010).raw.nanoseconds, lifecycle.process.reaping.cleanup_deadline.raw.nanoseconds);
    }
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
        _ = lifecycle.observePipe(.stderr, .end, at(0));
        if (phase != .running) _ = lifecycle.requestTermination(.stopped, at(0));
        if (@backingInt(phase) >= @backingInt(Phase.reaping)) _ = lifecycle.expireGrace(at(100)).?;
        if (@backingInt(phase) >= @backingInt(Phase.checking_group)) try lifecycle.reaped(.{ .exited = 0 });
        if (phase == .gone) lifecycle.groupAbsent();

        const watchdog = now_ms >= 5_000 and phase != .running and phase != .gone;
        const result = lifecycle.cutoff(at(now_ms));
        if (phase == .gone or watchdog) {
            try std.testing.expectEqual(watchdog, result.?.unconfirmed);
            try std.testing.expect(result.?.snapshot.eql(.initOne(.stdout)));
            lifecycle.beginTail(.stdout, 2);
            try std.testing.expectEqual(@as(usize, 0), lifecycle.cutoff(at(now_ms)).?.snapshot.count());
        } else {
            try std.testing.expect(result == null);
        }
    };
}

test "a finite tail closes complete only on EOF after its owed bytes" {
    const Expected = union(enum) { owed: u64, closed: PipeClose };
    const cases = [_]struct { owed: u64, read: PipeRead, expected: Expected, failure: CaptureFailure = .none }{
        .{ .owed = 3, .read = .empty, .expected = .{ .owed = 3 } },
        .{ .owed = 3, .read = .{ .bytes = 2 }, .expected = .{ .owed = 1 } },
        .{ .owed = 3, .read = .{ .bytes = 3 }, .expected = .{ .owed = 0 } },
        .{ .owed = 3, .read = .end, .expected = .{ .closed = .failed }, .failure = .read },
        .{ .owed = 3, .read = .{ .failed = .exhausted }, .expected = .{ .closed = .failed }, .failure = .exhausted },
        .{ .owed = 0, .read = .empty, .expected = .{ .closed = .incomplete } },
        .{ .owed = 0, .read = .{ .bytes = 1 }, .expected = .{ .closed = .incomplete } },
        .{ .owed = 0, .read = .end, .expected = .{ .closed = .eof } },
        .{ .owed = 0, .read = .{ .failed = .read }, .expected = .{ .closed = .failed }, .failure = .read },
    };
    for (cases) |case| {
        var lifecycle = Self.start(at(0), 100);
        _ = lifecycle.observeLeader(.{ .exited = 0 }, at(0));
        _ = lifecycle.expireGrace(at(100)).?;
        try lifecycle.reaped(.{ .exited = 0 });
        lifecycle.groupAbsent();
        lifecycle.beginTail(.stdout, case.owed);
        try std.testing.expect(lifecycle.observePipe(.stdout, case.read, at(101)) == null);
        try std.testing.expectEqual(@as(Pipe, switch (case.expected) {
            .owed => |owed| .{ .tail = owed },
            .closed => |reason| .{ .closed = reason },
        }), lifecycle.pipes.get(.stdout));
        try std.testing.expectEqual(case.failure, lifecycle.capture_failure);
        try std.testing.expectEqual(StopReason.none, lifecycle.stop_reason);
    }

    var lifecycle = Self.start(at(0), 100);
    _ = lifecycle.observeLeader(.{ .exited = 0 }, at(0));
    _ = lifecycle.expireGrace(at(100)).?;
    try lifecycle.reaped(.{ .exited = 0 });
    lifecycle.groupAbsent();
    lifecycle.beginTail(.stdout, 3);
    lifecycle.beginTail(.stderr, 0);
    _ = lifecycle.observePipe(.stdout, .{ .bytes = 3 }, at(101));
    _ = lifecycle.observePipe(.stdout, .end, at(102));
    try std.testing.expect(lifecycle.captureIncomplete());
    _ = lifecycle.observePipe(.stderr, .empty, at(102));
    try std.testing.expect(lifecycle.retired());
    try std.testing.expect(lifecycle.captureIncomplete());
    try std.testing.expectEqual(Resolution.succeeded, lifecycle.resolution());
}

test "capture failure stops a running Attempt and saves storage failure" {
    for (std.enums.values(CaptureFailure)) |failure| {
        if (failure == .none or failure == .seal) continue;
        var lifecycle = Self.start(at(0), 100);
        try std.testing.expectEqual(Signal.terminate_group, lifecycle.observePipe(.stderr, .{ .failed = failure }, at(5)).?);
        try std.testing.expectEqual(StopReason.capture_failed, lifecycle.stop_reason);
        try std.testing.expectEqual(failure, lifecycle.capture_failure);
        try std.testing.expectEqual(at(105).raw.nanoseconds, lifecycle.process.grace.kill_at.raw.nanoseconds);
        try lifecycle.retire(.{ .exited = 0 }, at(6));
        try std.testing.expectEqual(Resolution.storage_failed, lifecycle.resolution());
    }

    var live = Self.start(at(0), 100);
    _ = live.observeLeader(.{ .exited = 0 }, at(1));
    try std.testing.expect(live.observePipe(.stdout, .{ .failed = .read }, at(2)) == null);
    try std.testing.expect(live.requestTermination(.stopped, at(3)) == null);
    try live.retire(.{ .exited = 0 }, at(4));
    try std.testing.expectEqual(Resolution.storage_failed, live.resolution());
}

test "finite-tail capture failure leaves the stop reason to a later request" {
    const Failure = enum { snapshot, tail_read };
    const Later = enum { none, stop, shutdown };
    for (std.enums.values(Failure)) |failure| for (std.enums.values(Later)) |later| {
        var lifecycle = Self.start(at(0), 100);
        _ = lifecycle.observeLeader(.{ .exited = 0 }, at(1));
        _ = lifecycle.expireGrace(at(101)).?;
        try lifecycle.reaped(.{ .exited = 0 });
        lifecycle.groupAbsent();
        lifecycle.beginTail(.stderr, 32 * 1024);
        switch (failure) {
            .snapshot => lifecycle.beginTail(.stdout, null),
            .tail_read => {
                lifecycle.beginTail(.stdout, 8);
                try std.testing.expect(lifecycle.observePipe(.stdout, .{ .failed = .write }, at(102)) == null);
            },
        }
        try std.testing.expectEqual(Pipe{ .closed = .failed }, lifecycle.pipes.get(.stdout));
        try std.testing.expectEqual(StopReason.none, lifecycle.stop_reason);
        switch (later) {
            .none => {},
            .stop => try std.testing.expect(lifecycle.requestTermination(.stopped, at(103)) == null),
            .shutdown => try std.testing.expect(lifecycle.requestTermination(.infrastructure_shutdown, at(103)) == null),
        }
        _ = lifecycle.observePipe(.stderr, .{ .bytes = 32 * 1024 }, at(104));
        _ = lifecycle.observePipe(.stderr, .end, at(104));
        try std.testing.expectEqual(@as(Resolution, switch (later) {
            .none => .storage_failed,
            .stop => .cancelled,
            .shutdown => .infrastructure_shutdown,
        }), lifecycle.resolution());
    };
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
