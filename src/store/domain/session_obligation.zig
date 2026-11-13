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

// UNION (not UNION ALL) bounds a corrupt cycle by its distinct saved keys.
// A path without a root projects zero, which the existing positive-time CHECK
// rejects before COMMIT; missing/cyclic ancestry is never silently accepted.
const path_sql = "WITH RECURSIVE obligation_walk(origin_ref,session_ref,parent_ref) AS (" ++
    "SELECT session_ref,session_ref,parent_ref FROM session WHERE session_ref IN (?1,?2,?3,?4) UNION " ++
    "SELECT p.origin_ref,s.session_ref,s.parent_ref FROM session s JOIN obligation_walk p ON s.session_ref=p.parent_ref)," ++
    "obligation_path(session_ref,parent_ref) AS (SELECT DISTINCT session_ref,parent_ref FROM obligation_walk) ";
const projection_sql = path_sql[0 .. path_sql.len - 1] ++ "," ++
    "obligation_inputs(session_ref,since) AS (" ++
    // Match MySQL's functional active-Turn index, as well as SQLite's predicate.
    "SELECT p.session_ref,(SELECT admitted_at FROM message_admission WHERE admission_id=(SELECT t.first_admission_id FROM turn t WHERE t.session_ref=p.session_ref AND t.outcome_code IS NULL AND (CASE WHEN t.outcome_code IS NULL THEN t.session_ref END)=p.session_ref)) FROM obligation_path p UNION " ++
    "SELECT p.session_ref,(SELECT min(m.admitted_at) FROM message_admission m @index(message_admission_session_order) WHERE m.session_ref=p.session_ref AND m.turn_id IS NULL AND m.admission_id>coalesce((SELECT admission_cutoff FROM session_stop WHERE session_ref=p.session_ref ORDER BY admission_cutoff DESC LIMIT 1),0)) FROM obligation_path p),obligation_publications(session_ref,since) AS (" ++
    "SELECT p.session_ref,(SELECT min(m.admitted_at) FROM session_forward f @index(session_forward_feed) LEFT JOIN action_operation a ON f.kind=1 AND a.action_id=f.source_id LEFT JOIN model_operation op ON op.operation_id=a.parent_operation_id JOIN turn t ON t.turn_id=CASE WHEN f.kind=2 THEN f.source_id ELSE op.turn_id END JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE f.target_ref=p.session_ref AND f.position IS NULL) FROM obligation_path p UNION " ++
    "SELECT p.session_ref,(SELECT min(m.admitted_at) FROM session_forward f @index(session_forward_owed_message) JOIN turn t ON t.turn_id=f.source_id JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE f.target_ref=p.session_ref AND f.message_delivered=0) FROM obligation_path p),obligation_seeds(session_ref,since) AS (SELECT session_ref,since FROM obligation_inputs UNION SELECT session_ref,since FROM obligation_publications UNION " ++
    // Only unaffected children contribute saved values: every path member is
    // recomputed from canonical own duties, not a stale descendant frontier.
    "SELECT p.session_ref,(SELECT obligation_since FROM session @index(session_obligation_parent) WHERE parent_ref=p.session_ref AND obligation_since IS NOT NULL AND (CASE WHEN obligation_since IS NOT NULL THEN parent_ref END)=p.session_ref AND session_ref NOT IN (SELECT session_ref FROM obligation_path) ORDER BY obligation_since,session_ref LIMIT 1) FROM obligation_path p)," ++
    "obligation_owed(session_ref,since) AS (SELECT session_ref,since FROM obligation_seeds WHERE since IS NOT NULL UNION " ++
    "SELECT p.parent_ref,o.since FROM obligation_owed o JOIN obligation_path p ON p.session_ref=o.session_ref WHERE p.parent_ref IS NOT NULL) " ++
    "SELECT s.session_ref,s.obligation_since AS saved_since,CASE WHEN NOT EXISTS(SELECT origin_ref FROM obligation_walk GROUP BY origin_ref HAVING sum(CASE WHEN parent_ref IS NULL THEN 1 ELSE 0 END)=0) THEN (SELECT min(o.since) FROM obligation_owed o WHERE o.session_ref=s.session_ref) ELSE 0 END AS owed_since " ++
    "FROM session s JOIN obligation_path p ON p.session_ref=s.session_ref";
const Ref = Bounded(session_id.bytes);
const Args = struct { one: Ref, two: Ref, three: Ref, four: Ref };
const update = rsql.ObligationProjection(.{ .sql = projection_sql, .Args = Args });
const ancestors = rsql.Read(.{
    .sql = path_sql ++ "SELECT s.session_ref,s.workspace_key,s.next_position FROM session s JOIN obligation_path p ON p.session_ref=s.session_ref",
    .Args = Args,
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .each,
    .compound = true,
});

/// Queue, never run: the derived update and streamed change-ring hints precede
/// the existing inline COMMIT. Both engines execute this same owner and SQL.
pub fn reconcile(a: anytype, changed: []const rsql.SessionHead) void {
    std.debug.assert(changed.len > 0 and changed.len <= 4);
    var args: Args = undefined;
    inline for (.{ "one", "two", "three", "four" }, 0..) |field, index| {
        @field(args, field) = .{ .bytes = changed[@min(index, changed.len - 1)].ref, .len = session_id.bytes };
    }
    a.write(update, args);
    a.readEach(ancestors, args, std.math.maxInt(u64), a);
}

pub fn hint(a: anytype, row: *const ancestors.Row) bool {
    a.obligationTouch(row.session);
    return true;
}
