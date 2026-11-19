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
