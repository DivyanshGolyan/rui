//! The one owner of attached-tree obligations. A Session remains owed until
//! active/eligible work, unpublished forwarding, ending Message delivery and
//! recursively owed descendants have transferred to the recipient. Writers
//! reconcile this frontier inside their transaction; readers use its saved key.
const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const rsql = @import("../rsql.zig");

/// Includes obligations to this Session's feed/input, not just a live child
/// Turn: positioning a row and delivering its Message are independent duties.
pub const read = rsql.Read(.{
    .sql = "SELECT (SELECT obligation_since FROM session WHERE session_ref=?1) AS owed_since",
    .Args = struct { session: []const u8 },
    .Row = struct { owed_since: ?rsql.Positive },
    .cardinality = .each,
});

// MySQL's partial active-Turn key is functional, not session_ref itself.
// Match its expression as well as SQLite's ordinary partial-index predicate.
const facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,s.parent_ref,s.obligation_since AS saved_since," ++
        "(SELECT min(m.admitted_at) FROM turn t JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE t.session_ref=?1 AND t.outcome_code IS NULL AND (CASE WHEN t.outcome_code IS NULL THEN t.session_ref END)=?1) AS active_since," ++
        "(SELECT min(m.admitted_at) FROM message_admission m @index(message_admission_session_order) WHERE m.session_ref=?1 AND m.turn_id IS NULL AND m.admission_id>coalesce((SELECT admission_cutoff FROM session_stop WHERE session_ref=?1 ORDER BY admission_cutoff DESC LIMIT 1),0)) AS queued_since," ++
        "(SELECT min(m.admitted_at) FROM session_forward f @index(session_forward_feed) " ++
        "LEFT JOIN action_operation a ON f.kind=1 AND a.action_id=f.source_id LEFT JOIN model_operation op ON op.operation_id=a.parent_operation_id " ++
        "JOIN turn t ON t.turn_id=CASE WHEN f.kind=2 THEN f.source_id ELSE op.turn_id END JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
        "WHERE f.target_ref=?1 AND f.position IS NULL) AS publication_since," ++
        "(SELECT min(m.admitted_at) FROM session_forward f @index(session_forward_owed_message) JOIN turn t ON t.turn_id=f.source_id " ++
        "JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE f.target_ref=?1 AND f.message_delivered=0) AS message_since," ++
        "(SELECT obligation_since FROM session @index(session_obligation_parent) WHERE parent_ref=?1 AND obligation_since IS NOT NULL AND (CASE WHEN obligation_since IS NOT NULL THEN parent_ref END)=?1 ORDER BY obligation_since,session_ref LIMIT 1) AS child_since " ++
        "FROM session s WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        parent_ref: ?Bounded(session_id.bytes),
        saved_since: ?rsql.Positive,
        active_since: ?rsql.Positive,
        queued_since: ?rsql.Positive,
        publication_since: ?rsql.Positive,
        message_since: ?rsql.Positive,
        child_since: ?rsql.Positive,
    },
    .cardinality = .optional,
});

const update = rsql.Write(.{
    .sql = "UPDATE session SET obligation_since=?2 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, since: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Bottom-up, with one bounded row at a time, never a resident tree or a
/// finished-child scan. Every visited ancestor is also the same transaction's
/// change-ring hint, even when its earliest owed time did not change.
pub noinline fn reconcile(a: anytype, changed: []const rsql.SessionHead) @TypeOf(a.*).Error!void {
    for (changed) |head| {
        var current = head.ref;
        // Brent's cycle check uses constant space, without a depth limit or
        // another history/parent query. Only creation may attach a Session.
        var checkpoint = current;
        var distance: usize = 0;
        var power: usize = 1;
        while (true) {
            var row: facts.Result = undefined;
            a.read(facts, .{ .session = &current }, &row);
            try a.run();
            const found = if (row) |*value| value else return error.CorruptStore;
            a.obligationTouch(found.session);
            var since: ?u64 = null;
            inline for (.{ "active_since", "queued_since", "publication_since", "message_since", "child_since" }) |field| {
                if (@field(found, field)) |value| since = @min(since orelse value.get(), value.get());
            }
            const saved: ?u64 = if (found.saved_since) |value| value.get() else null;
            if (saved != since) {
                a.write(update, .{ .session = found.session, .since = since });
                // The parent sees the child's new frontier before its own read.
                try a.run();
            }
            const parent = found.parent_ref orelse break;
            current = parent.bytes;
            distance += 1;
            if (std.mem.eql(u8, &current, &checkpoint)) return error.CorruptStore;
            if (distance == power) {
                checkpoint = current;
                power *|= 2;
                distance = 0;
            }
        }
    }
}
