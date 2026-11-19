const std = @import("std");

/// The store_owner row as a Host reads it: the epoch of the Host that opened the Store and the commit sequence
/// the Store has saved.
pub const Owner = struct { epoch: u64, commit_seq: u64 };

/// What a connection failure means to the lost-commit decisions. Every other failure is `other`.
pub const Failure = enum { connection_lost, commit_outcome_unknown, ownership_lost, other };

/// The two failures a lost connection can be; the shell maps each to its error.
pub const Lost = enum { connection_lost, commit_outcome_unknown };
pub const LostDecision = struct { failure: Lost, rerunnable: bool };

/// A connection was lost. While a COMMIT was in flight its outcome is unknown; the batch may run again only when armed.
pub fn lost(committing: bool, armed: bool) LostDecision {
    return .{ .failure = if (committing) .commit_outcome_unknown else .connection_lost, .rerunnable = armed };
}

pub const Settled = enum { saved, not_saved, ownership_lost };

/// The owner row was read on a new connection after a lost COMMIT. Another epoch is no longer ours; one commit
/// ahead of ours is the lost COMMIT, saved; the same sequence is not saved; anything else is no longer ours.
pub fn settle(ours: Owner, theirs: Owner) Settled {
    if (theirs.epoch != ours.epoch) return .ownership_lost;
    if (theirs.commit_seq == ours.commit_seq + 1) return .saved;
    if (theirs.commit_seq == ours.commit_seq) return .not_saved;
    return .ownership_lost;
}

/// The state a lost batch's rerun decision reads.
pub const Facts = struct { armed: bool, rerunnable: bool, login: bool, failure: ?Failure };

/// A lost connection defers the fence to the rerun's answer: armed, rerunnable, with a login to reconnect with, and
/// lost as a connection, not as an unknown COMMIT or a fence.
pub fn defers(f: Facts) bool {
    return f.armed and f.rerunnable and f.login and f.failure == .connection_lost;
}

pub const Recover = enum { no, reconnect, rerun };

/// The first half of recovery: may the batch run again at all, and must a connection be replaced before it does?
/// A connection already replaced by a lost COMMIT needs no second one.
pub fn recover(f: Facts, replaced: bool) Recover {
    if (!f.rerunnable or !f.login or f.failure != .connection_lost) return .no;
    return if (replaced) .rerun else .reconnect;
}

/// The second half, after a reconnect read the owner row: only an unchanged owner lets the batch run again.
pub fn rerunAfter(ours: Owner, theirs: Owner) bool {
    return theirs.epoch == ours.epoch and theirs.commit_seq == ours.commit_seq;
}

// Expected values are transcribed from src/store/engine/Mysql.zig (lost, settleLostCommit, defersFence, recover)
// before its shell used this core. None is computed from the functions under test.

test "SH-100 a lost COMMIT is saved, not saved or no longer ours by the owner row alone" {
    // Mysql.lost: committing picks the failure, armed picks rerunnable.
    for ([_]bool{ false, true }) |committing| {
        for ([_]bool{ false, true }) |armed| {
            const got = lost(committing, armed);
            try std.testing.expectEqual(if (committing) Lost.commit_outcome_unknown else Lost.connection_lost, got.failure);
            try std.testing.expectEqual(armed, got.rerunnable);
        }
    }

    // Mysql.settleLostCommit, for every ours and every owner row one epoch below to two above and one sequence
    // below to two above it. Rows are the epoch offset -1, 0, 1, 2; columns the commit_seq offset -1, 0, 1, 2.
    // Another epoch is ownership_lost; the same epoch is saved one commit ahead, not saved at the same sequence.
    const other_epoch: [4]Settled = @splat(.ownership_lost);
    const same_epoch = [4]Settled{ .ownership_lost, .not_saved, .saved, .ownership_lost };
    const expected = [4][4]Settled{ other_epoch, same_epoch, other_epoch, other_epoch };
    var tally: [3]usize = @splat(0);
    for (0..4) |ours_epoch| {
        for (0..4) |ours_seq| {
            const ours: Owner = .{ .epoch = 4 + ours_epoch, .commit_seq = 8 + ours_seq };
            for (0..4) |epoch_offset| {
                for (0..4) |seq_offset| {
                    const theirs: Owner = .{ .epoch = ours.epoch + epoch_offset - 1, .commit_seq = ours.commit_seq + seq_offset - 1 };
                    const got = settle(ours, theirs);
                    try std.testing.expectEqual(expected[epoch_offset][seq_offset], got);
                    tally[@backingInt(got)] += 1;
                }
            }
        }
    }
    // Per ours: one saved, one not saved, fourteen ownership lost.
    try std.testing.expectEqual(@as(usize, 16), tally[@backingInt(Settled.saved)]);
    try std.testing.expectEqual(@as(usize, 16), tally[@backingInt(Settled.not_saved)]);
    try std.testing.expectEqual(@as(usize, 224), tally[@backingInt(Settled.ownership_lost)]);
    // A commit_seq of the maximum is not in the table: Mysql.settleLostCommit adds one to it, which has no defined result.
}

test "SH-101 a lost batch runs again only while unsaved and still ours, and once" {
    const failures = [_]?Failure{ null, .connection_lost, .commit_outcome_unknown, .ownership_lost, .other };
    const ours: Owner = .{ .epoch = 5, .commit_seq = 9 };

    // Full product of Facts and replaced. Mysql.defersFence: armed, rerunnable, login, connection_lost.
    // Mysql.recover: not rerunnable, no login or another failure answers no; replaced answers rerun; else reconnect.
    var deferred: usize = 0;
    var runs_again: usize = 0;
    for ([_]bool{ false, true }) |armed| {
        for ([_]bool{ false, true }) |rerunnable| {
            for ([_]bool{ false, true }) |login| {
                for (failures) |failure| {
                    for ([_]bool{ false, true }) |replaced| {
                        const facts: Facts = .{ .armed = armed, .rerunnable = rerunnable, .login = login, .failure = failure };
                        const want_defer = armed and rerunnable and login and failure == .connection_lost;
                        try std.testing.expectEqual(want_defer, defers(facts));
                        if (want_defer) deferred += 1;

                        const want: Recover = if (!rerunnable or !login or failure != .connection_lost) .no else if (replaced) .rerun else .reconnect;
                        try std.testing.expectEqual(want, recover(facts, replaced));

                        // Owner comparison on the reconnect path: a batch runs again only when the owner row is unchanged.
                        for (0..4) |epoch_offset| {
                            for (0..4) |seq_offset| {
                                const theirs: Owner = .{ .epoch = 4 + epoch_offset, .commit_seq = 8 + seq_offset };
                                const same = theirs.epoch == ours.epoch and theirs.commit_seq == ours.commit_seq;
                                const want_runs = switch (want) {
                                    .no => false,
                                    .rerun => true,
                                    .reconnect => same,
                                };
                                const got = switch (recover(facts, replaced)) {
                                    .no => false,
                                    .rerun => true,
                                    .reconnect => rerunAfter(ours, theirs),
                                };
                                try std.testing.expectEqual(want_runs, got);
                                if (got) runs_again += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    // defers holds for armed in both values, with rerunnable, login and connection_lost: 2 of the 80 cases (replaced
    // does not change it). Runs again: 2 reconnect cases (armed, not replaced) each with the one owner row equal to
    // ours, and 2 rerun cases (replaced) each with all 16 owner rows answering yes: 2 * 1 + 2 * 16 = 34.
    try std.testing.expectEqual(@as(usize, 2), deferred);
    try std.testing.expectEqual(@as(usize, 34), runs_again);

    // Two losses: arm, lose before COMMIT, disarm (the Queue disarms before it asks recover), recover, lose again.
    const first = lost(false, true);
    try std.testing.expectEqual(Lost.connection_lost, first.failure);
    try std.testing.expect(first.rerunnable);
    var facts: Facts = .{ .armed = false, .rerunnable = first.rerunnable, .login = true, .failure = .connection_lost };
    try std.testing.expect(!defers(facts));
    try std.testing.expectEqual(Recover.reconnect, recover(facts, false));
    try std.testing.expect(rerunAfter(ours, ours));

    // The rerun is lost while disarmed: lost answers not rerunnable, so recover answers no.
    const second = lost(false, false);
    facts = .{ .armed = false, .rerunnable = second.rerunnable, .login = true, .failure = .connection_lost };
    try std.testing.expect(!second.rerunnable);
    try std.testing.expectEqual(Recover.no, recover(facts, false));
    try std.testing.expectEqual(Recover.no, recover(facts, true));
}
