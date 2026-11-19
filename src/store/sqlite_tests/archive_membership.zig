const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const action_domain = @import("../domain/action.zig");
const archive_membership = @import("../domain/archive_membership.zig");
const c = sqlite.c;
const membership_state = archive_membership.stateSql("s");
const openRaw = shared_fixtures.openRaw;

// The format 84 archive state, read through session_archive. The migration must reproduce it exactly.
const format_84_state_sql = "CASE WHEN EXISTS(SELECT 1 FROM session_archive ar JOIN session_stop astop ON astop.command_key=ar.command_key " ++
    "LEFT JOIN turn aturn ON aturn.turn_id=astop.selected_turn_id WHERE ar.session_ref=session.session_ref AND NOT (" ++
    action_domain.stopCompletedSql("astop", "aturn", "NULL") ++ ")) THEN 'archiving' " ++
    "WHEN EXISTS(SELECT 1 FROM session_archive ar WHERE ar.session_ref=session.session_ref AND ar.command_key IS NOT NULL) THEN 'archived' ELSE 'active' END";

// Format 84 Sessions covering every archive state: active (never archived), restored (key NULL),
// archiving by an open turn, archiving by an unaccepted action, archived, and restored then re-archived.
// Copies of rhvzwc (which has no turns or actions) carry the first, second and last states.
const format_84_fixture_sql =
    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,created_seq,workspace_digest,workspace_key) " ++
    "SELECT 'act1v3',workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,10,workspace_digest,workspace_key FROM session WHERE session_ref='rhvzwc';" ++
    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,created_seq,workspace_digest,workspace_key) " ++
    "SELECT 'rest01',workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,11,workspace_digest,workspace_key FROM session WHERE session_ref='rhvzwc';" ++
    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,created_seq,workspace_digest,workspace_key) " ++
    "SELECT 'rearc1',workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode,revision,created_at,next_position,12,workspace_digest,workspace_key FROM session WHERE session_ref='rhvzwc';" ++
    "UPDATE turn SET outcome_code=NULL,outcome_content_id=NULL,outcome_position=NULL,outcome_at=NULL WHERE turn_id=1;" ++
    "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES" ++
    "('arch-turn',6,'d8mv7p',zeroblob(32),1,'',0,0,21),('arch-action',6,'brhkcj',zeroblob(32),1,'',0,0,20),('arch-rearc',6,'rearc1',zeroblob(32),1,'',0,0,22);" ++
    "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused,action_cutoff) VALUES" ++
    "('arch-turn','d8mv7p',1,NULL,0,1793781800,0,0),('arch-action','brhkcj',NULL,NULL,0,1793781800,0,2),('arch-rearc','rearc1',NULL,NULL,0,1793781800,0,0);" ++
    "INSERT INTO session_archive(session_ref,command_key) VALUES('d8mv7p','arch-turn'),('brhkcj','arch-action'),('rhvzwc','fixture-stop'),('rest01',NULL),('rearc1','arch-rearc');" ++
    "INSERT INTO session_archive_command(command_key,archived) VALUES('arch-turn',1),('arch-action',1),('arch-rearc',1);";

test "schema 85 archive membership migration keeps every Session's archive state and drops session_archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/archive.sqlite3", .{root});
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
    try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(raw, store_testing.baseline_rows);
    for (store_schema.migrations) |step| {
        if (step.from == 84) break;
        for (step.sqlite) |statement| try sqlite.exec(raw, statement);
    }
    try sqlite.exec(raw, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF;PRAGMA user_version=84");
    try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d}", .{store_schema.application_id}));
    const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','84'),('wire_version',?1),('store_selector',?2)");
    defer _ = c.sqlite3_finalize(meta);
    try sqlite.bindText(meta, 1, protocol.wire_version);
    try sqlite.bindText(meta, 2, root);
    try sqlite.expectDone(meta);
    try sqlite.exec(raw, format_84_fixture_sql);
    try sqlite.exec(raw, "CREATE TEMP TABLE before_states AS SELECT session_ref,(" ++ format_84_state_sql ++ ") AS archive_state FROM session");
    try std.testing.expectEqual(@as(u32, 6), try sqlite.pragmaInt(raw, "SELECT count(*) FROM before_states"));
    try std.testing.expectEqual(@as(u32, 6), try sqlite.pragmaInt(raw, "SELECT count(*) FROM before_states WHERE (session_ref='act1v3' AND archive_state='active') OR (session_ref='rest01' AND archive_state='active') OR (session_ref='brhkcj' AND archive_state='archiving') OR (session_ref='d8mv7p' AND archive_state='archiving') OR (session_ref='rhvzwc' AND archive_state='archived') OR (session_ref='rearc1' AND archive_state='archived')"));
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
    try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM sqlite_schema WHERE name='session_archive'"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='session_tab' AND tbl_name='session'"));
    try std.testing.expectEqual(@as(u32, 6), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session s JOIN before_states b ON b.session_ref=s.session_ref WHERE (" ++ membership_state ++ ")=b.archive_state"));
    try std.testing.expectEqual(@as(u32, 4), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session WHERE (session_ref='d8mv7p' AND archive_seq=21) OR (session_ref='brhkcj' AND archive_seq=20) OR (session_ref='rhvzwc' AND archive_seq=7) OR (session_ref='rearc1' AND archive_seq=22)"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session WHERE archive_seq IS NULL"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_foreign_key_check"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(raw, "UPDATE session SET archive_seq=999 WHERE session_ref='act1v3'"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(raw, "UPDATE session SET archive_seq=0 WHERE session_ref='act1v3'"));
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
}
