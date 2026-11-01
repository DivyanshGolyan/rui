//! Value policy for leaving the frontend. Facts describe completed effects;
//! they do not perform or stand in for restoration, cancellation or joins.
const std = @import("std");

pub const ReadPhase = enum { activity, history, details, inspection, permission, message, recall };
/// `inspection`: a pending inspection supersedes a silent read it cancelled.
pub const Mode = enum { active, inspection, final_exit };
pub const ReadEnd = union(enum) {
    absent,
    complete,
    cancelled: Progress,
    failed: struct { err: anyerror, progress: Progress },

    pub const Progress = struct { phase: ReadPhase, rendering: bool };

    pub fn preparationFailure(self: ReadEnd) bool {
        return self == .failed and self.failed.err != error.CanonicalStoreFailure and
            (self.failed.progress.phase == .history or self.failed.progress.phase == .details or self.failed.progress.phase == .inspection or self.failed.progress.phase == .message or self.failed.progress.phase == .recall) and
            !self.failed.progress.rendering;
    }

    pub fn failure(self: ReadEnd, mode: Mode) ?anyerror {
        return switch (self) {
            .absent, .complete => null,
            // Nothing a cancelled read produced has shown: it stands only
            // where no inspection superseded it.
            .cancelled => if (mode == .active) error.Cancelled else null,
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
    for ([_]Mode{ .active, .inspection, .final_exit }) |mode| {
        const settled: Settled = .{ .restored = error.TerminalRestoreFailed, .reader = .absent, .admission_error = error.CanonicalStoreFailure };
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(mode, error.InteractiveInterrupted).?);
        const restored: Settled = .{ .restored = {}, .reader = .absent, .admission_error = error.CanonicalStoreFailure };
        try std.testing.expectEqual(error.CanonicalStoreFailure, restored.failure(mode, error.InteractiveInterrupted).?);
    }
    for ([_]ReadPhase{ .history, .details }) |phase| {
        const preparation: ReadEnd = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = phase, .rendering = false } } };
        try std.testing.expect(preparation.failure(.active) == null);
        try std.testing.expect(preparation.failure(.inspection) == null);
        try std.testing.expectEqual(error.ConnectionResetByPeer, preparation.failure(.final_exit).?);
        var rendering = preparation;
        rendering.failed.progress.rendering = true;
        try std.testing.expectEqual(error.ConnectionResetByPeer, rendering.failure(.inspection).?);
    }
    for ([_]ReadPhase{ .activity, .permission, .history, .details }) |phase| {
        const cancelled: ReadEnd = .{ .cancelled = .{ .phase = phase, .rendering = true } };
        try std.testing.expectEqual(error.Cancelled, cancelled.failure(.active).?);
        try std.testing.expect(cancelled.failure(.inspection) == null);
        try std.testing.expect(cancelled.failure(.final_exit) == null);
    }
}

test "departure interruption alone leaves a clean exit and substantive errors primary" {
    const clean: Settled = .{ .restored = {}, .reader = .complete, .admission_error = null };
    const finished = exit(clean, error.InteractiveInterrupted, false);
    try std.testing.expect(finished.failure == null and !finished.recovery_before_notice);
    for ([_]anyerror{ error.CanonicalStoreFailure, error.WriteFailed, error.InvalidObservation }) |err| {
        try std.testing.expectEqual(err, exit(clean, err, false).failure.?);
    }
}

test "departure joined fact matrix preserves precedence and recovery" {
    const Row = struct {
        reader: ReadEnd,
        admission: ?anyerror = null,
        cause: ?anyerror = null,
        inspection_error: ?anyerror = null,
        exit_error: ?anyerror = null,
    };
    const cases = [_]Row{
        .{ .reader = .absent },
        .{ .reader = .complete, .admission = error.Cancelled },
        .{ .reader = .absent, .admission = error.ConnectionResetByPeer, .exit_error = error.ConnectionResetByPeer },
        .{ .reader = .complete, .admission = error.CanonicalStoreFailure, .cause = error.WriteFailed, .inspection_error = error.CanonicalStoreFailure, .exit_error = error.CanonicalStoreFailure },
        .{ .reader = .{ .failed = .{ .err = error.CanonicalStoreFailure, .progress = .{ .phase = .history, .rendering = false } } }, .inspection_error = error.CanonicalStoreFailure, .exit_error = error.CanonicalStoreFailure },
        .{ .reader = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = .details, .rendering = false } } }, .exit_error = error.ConnectionResetByPeer },
        .{ .reader = .{ .failed = .{ .err = error.ConnectionResetByPeer, .progress = .{ .phase = .details, .rendering = true } } }, .cause = error.WriteFailed, .inspection_error = error.ConnectionResetByPeer, .exit_error = error.WriteFailed },
        .{ .reader = .{ .cancelled = .{ .phase = .activity, .rendering = false } } },
        .{ .reader = .{ .cancelled = .{ .phase = .permission, .rendering = false } } },
    };
    for (cases) |row| {
        for ([_]?anyerror{ null, error.TerminalCleanupFailed, error.TerminalRestoreFailed }) |restore_error| {
            const facts: Settled = .{ .restored = if (restore_error) |err| err else {}, .reader = row.reader, .admission_error = row.admission };
            try std.testing.expectEqual(if (restore_error != null) restore_error else row.inspection_error, facts.failure(.inspection, null));
            for ([_]bool{ false, true }) |unresolved| {
                const plan = exit(facts, row.cause, unresolved);
                const expected_error: ?anyerror = if (restore_error != null) restore_error else row.exit_error;
                try std.testing.expectEqual(expected_error, plan.failure);
                try std.testing.expectEqual(expected_error != null or unresolved, plan.recovery_before_notice);
            }
        }
    }
}
