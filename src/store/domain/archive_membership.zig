//! The one owner of archive membership: `session.archive_seq`, the `command_seq` of the archive
//! request that archived a Session, NULL while it is live. Restore clears it.
//!
//! The three states are derived from that column and the archive request's stop:
//! `archive_seq IS NULL` is active; a key whose stop is not yet complete is archiving; otherwise archived.
//! No other file writes the column, and no other file restates the three-state rule.

const action_domain = @import("action.zig");
const rsql = @import("../rsql.zig");

/// Marks `head` archived by the archive request `seq` (a `core_command.command_seq`).
/// A Session archived again takes the newer request's key.
pub fn archive(r: anytype, head: rsql.SessionHead, seq: u64) void {
    r.write(mark_archived, .{ .session = head, .seq = seq });
}

/// Clears the archive membership of `head`; a live Session is left as it is.
pub fn restore(r: anytype, head: rsql.SessionHead) void {
    r.write(mark_live, .{ .session = head });
}

/// The SQL CASE that classifies the Session row aliased `alias` as 'active', 'archiving' or 'archived'.
pub fn stateSql(comptime alias: []const u8) []const u8 {
    return comptime "CASE WHEN " ++ alias ++ ".archive_seq IS NULL THEN 'active' " ++
        "WHEN EXISTS(SELECT 1 FROM core_command ac JOIN session_stop astop ON astop.command_key=ac.command_key " ++
        "LEFT JOIN turn aturn ON aturn.turn_id=astop.selected_turn_id " ++
        "WHERE ac.command_seq=" ++ alias ++ ".archive_seq AND NOT (" ++ action_domain.stopCompletedSql("astop", "aturn", "NULL") ++ ")) THEN 'archiving' " ++
        "ELSE 'archived' END";
}

/// The Archived predicate on the Session row aliased `alias`: a key whose three-state rule says 'archived'.
pub fn archivedSql(comptime alias: []const u8) []const u8 {
    return comptime alias ++ ".archive_seq IS NOT NULL AND (" ++ stateSql(alias) ++ ")='archived'";
}

/// Filters a Session list by archive state. `parameter` is the bound Filter name:
/// 'all' keeps every row, 'archived' keeps Archived rows, 'active' keeps active and archiving rows.
pub fn filterSql(comptime alias: []const u8, comptime parameter: []const u8) []const u8 {
    return comptime " AND (" ++ parameter ++ "='all' OR (" ++ archivedSql(alias) ++ ")=(" ++ parameter ++ "='archived'))";
}

/// Sessions that may be archiving, from the indexes that hold in-flight work: open turns (`outcome_code`
/// null, or `outcome_position` null with a code), and unaccepted Actions. A superset of the archiving
/// Sessions, so the caller still decides each one with `stateSql`.
/// Each candidate is one statement, so each can be planned on its own. `@in_index` states the rows of the
/// named partial index on both engines (rsql.zig).
pub const open_turn_candidates_sql = "SELECT t.session_ref FROM turn t @index(turn_one_active_per_session) WHERE @in_index(t, turn_one_active_per_session)";
pub const unpositioned_turn_candidates_sql = "SELECT u.session_ref FROM turn u @index(turn_unpositioned) WHERE @in_index(u, turn_unpositioned)";
pub const unaccepted_action_candidates_sql = "SELECT a.session_ref FROM action_operation a @index(action_operation_unaccepted) WHERE @in_index(a, action_operation_unaccepted)";
pub const archiving_candidates_sql = open_turn_candidates_sql ++ " UNION " ++ unpositioned_turn_candidates_sql ++ " UNION " ++ unaccepted_action_candidates_sql;

const mark_archived = rsql.Write(.{
    .sql = "UPDATE session SET archive_seq=?2 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, seq: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const mark_live = rsql.Write(.{
    .sql = "UPDATE session SET archive_seq=NULL WHERE session_ref=@session(?1) AND archive_seq IS NOT NULL",
    .Args = struct { session: rsql.SessionHead },
    .expect = .{ .at_most = 1 },
});
