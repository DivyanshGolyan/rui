const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const openRaw = shared_fixtures.openRaw;

// Format 85 tool records that differ only in the read-only hint, plus a lone read-only record,
// all members of one tool set. Format 86 keeps one record per remaining identity.
pub const format_85_twins_sql =
    "INSERT INTO tool_record(tool_record_id,name,owner,server,read_only,description_content_id,input_schema_content_id) " ++
    "SELECT 900,'twin_tool','mcp','docs',0,description_content_id,input_schema_content_id FROM tool_record ORDER BY tool_record_id LIMIT 1;" ++
    "INSERT INTO tool_record(tool_record_id,name,owner,server,read_only,description_content_id,input_schema_content_id) " ++
    "SELECT 901,'twin_tool','mcp','docs',1,description_content_id,input_schema_content_id FROM tool_record ORDER BY tool_record_id LIMIT 1;" ++
    "INSERT INTO tool_record(tool_record_id,name,owner,server,read_only,description_content_id,input_schema_content_id) " ++
    "SELECT 902,'lone_read','mcp','docs',1,description_content_id,input_schema_content_id FROM tool_record ORDER BY tool_record_id LIMIT 1;";

test "schema 86 tool record migration merges records that differed only in the read-only hint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/hint.sqlite3", .{root});
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
    try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(raw, store_testing.baseline_rows);
    for (store_schema.migrations) |step| {
        if (step.from == 85) break;
        for (step.sqlite) |statement| try sqlite.exec(raw, statement);
    }
    try sqlite.exec(raw, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF;PRAGMA user_version=85");
    try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d}", .{store_schema.application_id}));
    const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','85'),('wire_version',?1),('store_selector',?2)");
    defer _ = c.sqlite3_finalize(meta);
    try sqlite.bindText(meta, 1, protocol.wire_version);
    try sqlite.bindText(meta, 2, root);
    try sqlite.expectDone(meta);
    try std.testing.expect(try sqlite.pragmaInt(raw, "SELECT count(*) FROM tool_record") > 0);
    try sqlite.exec(raw, format_85_twins_sql);
    try sqlite.exec(raw, "INSERT INTO tool_set(tool_set_id,digest,member_count) VALUES(9000,randomblob(32),3);" ++
        "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) VALUES(9000,0,900),(9000,1,901),(9000,2,902)");
    const records_before = try sqlite.pragmaInt(raw, "SELECT count(*) FROM tool_record");
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
    try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_table_info('tool_record') WHERE name='read_only'"));
    try std.testing.expectEqual(records_before - 1, try sqlite.pragmaInt(raw, "SELECT count(*) FROM tool_record"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM tool_record WHERE tool_record_id=901"));
    try std.testing.expectEqual(@as(u32, 3), try sqlite.pragmaInt(raw, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=9000 AND ((ordinal=0 AND tool_record_id=900) OR (ordinal=1 AND tool_record_id=900) OR (ordinal=2 AND tool_record_id=902))"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_foreign_key_check"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(raw, "INSERT INTO tool_record(tool_record_id,name,owner,server,description_content_id,input_schema_content_id) SELECT 903,name,owner,server,description_content_id,input_schema_content_id FROM tool_record WHERE tool_record_id=900"));
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
}
