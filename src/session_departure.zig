//! Value policy for leaving the frontend. Facts describe completed effects;
//! they do not perform or stand in for restoration, cancellation or joins.
const std = @import("std");

pub const ReadPhase = enum { activity, history, details, inspection, permission };
pub const Mode = enum { active, handoff, final_exit };
pub const ReadEnd = union(enum) {
    absent,
    complete,
    cancelled: Progress,
    failed: struct { err: anyerror, progress: Progress },

    pub const Progress = struct { phase: ReadPhase, rendering: bool, output_owned: bool };

    pub fn preparationFailure(self: ReadEnd) bool {
        return self == .failed and self.failed.err != error.CanonicalStoreFailure and
            (self.failed.progress.phase == .history or self.failed.progress.phase == .details or self.failed.progress.phase == .inspection) and
            !self.failed.progress.rendering;
    }

    pub fn failure(self: ReadEnd, mode: Mode) ?anyerror {
        return switch (self) {
            .absent, .complete => null,
            .cancelled => |progress| if (mode == .active or mode == .handoff and progress.output_owned) error.Cancelled else null,
            .failed => |failed| if (mode != .final_exit and self.preparationFailure()) null else failed.err,
        };
    }
};

pub const Settled = struct {
    restored: anyerror!void,
    reader: ReadEnd,
    admission_error: ?anyerror,

    pub fn failure(self: Settled, mode: Mode, cause: ?anyerror) ?anyerror {
        self.restored catch |err| return err;
        const reader_error = self.reader.failure(mode);
        if (reader_error) |err| if (err == error.CanonicalStoreFailure) return err;
        if (self.admission_error) |err| if (err == error.CanonicalStoreFailure) return err;
        if (cause) |err| if (err != error.InteractiveInterrupted) return err;
        if (reader_error) |err| return err;
        if (mode == .final_exit) if (self.admission_error) |err| if (err != error.Cancelled) return err;
        return null;
    }
};

pub fn activeFailure(err: anyerror, signalled: bool) anyerror {
    return if (signalled and err == error.CommandHandoff) error.InteractiveInterrupted else err;
}

/// Sample interruption after quiescence, at the actual command boundary.
pub fn handoff(settled: Settled, signalled: bool) !void {
    if (settled.failure(.handoff, null)) |err| return err;
    if (signalled) return error.InteractiveInterrupted;
}

/// An interrupted successful command cannot re-enter raw mode. A substantive
/// command error remains primary even if the command also observed a signal.
pub fn commandReturn(result: anyerror!void, signalled: bool) !void {
    try result;
    if (signalled) return error.InteractiveInterrupted;
}

pub const Exit = struct {
    failure: ?anyerror,
    recovery_before_notice: bool,
};

/// Recovery identity remains Submission's authority. This only selects when
/// to render it: before an error/unresolved exit, or if the optional notice fails.
pub fn exit(settled: Settled, cause: ?anyerror, unresolved: bool) Exit {
    const failure = settled.failure(.final_exit, cause);
    return .{ .failure = failure, .recovery_before_notice = failure != null or unresolved };
}

test "departure settlement precedence and reader exit policies retain independent facts" {
    for ([_]Mode{ .active, .handoff, .final_exit }) |mode| {
        const settled: Settled = .{ .restored = error.TerminalRestoreFailed, .reader = .absent, .admission_error = error.CanonicalStoreFailure };
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(mode, error.InteractiveInterrupted).?);
        const restored: Settled = .{ .restored = {}, .reader = .absent, .admission_error = error.CanonicalStoreFailure };
        try std.testing.expectEqual(error.CanonicalStoreFailure, restored.failure(mode, error.InteractiveInterrupted).?);
    }
    for ([_]ReadPhase{ .history, .details }) |phase| {
        const preparation: ReadEnd = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = phase, .rendering = false, .output_owned = false } } };
        try std.testing.expect(preparation.failure(.active) == null);
        try std.testing.expect(preparation.failure(.handoff) == null);
        try std.testing.expectEqual(error.ConnectionResetByPeer, preparation.failure(.final_exit).?);
        var rendering = preparation;
        rendering.failed.progress.rendering = true;
        try std.testing.expectEqual(error.ConnectionResetByPeer, rendering.failure(.handoff).?);
    }
    for ([_]ReadPhase{ .activity, .permission, .history, .details }) |phase| {
        for ([_]bool{ false, true }) |output_owned| {
            const cancelled: ReadEnd = .{ .cancelled = .{ .phase = phase, .rendering = true, .output_owned = output_owned } };
            try std.testing.expectEqual(if (output_owned) @as(?anyerror, error.Cancelled) else null, cancelled.failure(.handoff));
            try std.testing.expect(cancelled.failure(.final_exit) == null);
        }
    }
}

test "departure signals at active cleanup and command boundaries cannot authorize continued input" {
    const clean: Settled = .{ .restored = {}, .reader = .complete, .admission_error = null };
    // Enumerate arrival cuts, not sleeps or fake signal handlers. Later samples
    // include earlier arrival; production supplies fresh atomic observations.
    for (0..4) |arrival| {
        const active = activeFailure(error.CommandHandoff, arrival == 0);
        try std.testing.expectEqual(if (arrival == 0) error.InteractiveInterrupted else error.CommandHandoff, active);
        const dispatch = handoff(clean, arrival <= 1);
        if (arrival <= 1) try std.testing.expectError(error.InteractiveInterrupted, dispatch) else try dispatch;
        const reentry = commandReturn({}, arrival <= 2);
        if (arrival <= 2) try std.testing.expectError(error.InteractiveInterrupted, reentry) else try reentry;
        const finished = exit(clean, error.InteractiveInterrupted, false);
        try std.testing.expect(finished.failure == null and !finished.recovery_before_notice);
    }
    for ([_]anyerror{ error.CanonicalStoreFailure, error.WriteFailed, error.InvalidObservation }) |err| {
        try std.testing.expectEqual(err, activeFailure(err, true));
        try std.testing.expectError(err, commandReturn(err, true));
        try std.testing.expectEqual(err, exit(clean, err, false).failure.?);
    }
}

test "departure joined fact matrix preserves precedence recovery and dispatch refusal" {
    const Row = struct {
        reader: ReadEnd,
        admission: ?anyerror = null,
        cause: ?anyerror = null,
        dispatch_error: ?anyerror = null,
        exit_error: ?anyerror = null,
    };
    const cases = [_]Row{
        .{ .reader = .absent },
        .{ .reader = .complete, .admission = error.Cancelled },
        .{ .reader = .absent, .admission = error.ConnectionResetByPeer, .exit_error = error.ConnectionResetByPeer },
        .{ .reader = .complete, .admission = error.CanonicalStoreFailure, .cause = error.WriteFailed, .dispatch_error = error.CanonicalStoreFailure, .exit_error = error.CanonicalStoreFailure },
        .{ .reader = .{ .failed = .{ .err = error.CanonicalStoreFailure, .progress = .{ .phase = .history, .rendering = false, .output_owned = false } } }, .dispatch_error = error.CanonicalStoreFailure, .exit_error = error.CanonicalStoreFailure },
        .{ .reader = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = .details, .rendering = false, .output_owned = false } } }, .exit_error = error.ConnectionResetByPeer },
        .{ .reader = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = .details, .rendering = true, .output_owned = false } } }, .cause = error.WriteFailed, .dispatch_error = error.ConnectionResetByPeer, .exit_error = error.WriteFailed },
        .{ .reader = .{ .cancelled = .{ .phase = .activity, .rendering = false, .output_owned = true } }, .dispatch_error = error.Cancelled },
        .{ .reader = .{ .cancelled = .{ .phase = .permission, .rendering = false, .output_owned = false } } },
    };
    for (cases) |row| {
        for ([_]?anyerror{ null, error.TerminalCleanupFailed, error.TerminalRestoreFailed }) |restore_error| {
            const facts: Settled = .{ .restored = if (restore_error) |err| err else {}, .reader = row.reader, .admission_error = row.admission };
            for ([_]bool{ false, true }) |signalled| {
                const expected: ?anyerror = if (restore_error != null) restore_error else if (row.dispatch_error != null) row.dispatch_error else if (signalled) error.InteractiveInterrupted else null;
                if (expected) |err| try std.testing.expectError(err, handoff(facts, signalled)) else try handoff(facts, signalled);
                for ([_]bool{ false, true }) |unresolved| {
                    const plan = exit(facts, row.cause, unresolved);
                    const expected_error: ?anyerror = if (restore_error != null) restore_error else row.exit_error;
                    try std.testing.expectEqual(expected_error, plan.failure);
                    try std.testing.expectEqual(expected_error != null or unresolved, plan.recovery_before_notice);
                }
            }
        }
    }
}
