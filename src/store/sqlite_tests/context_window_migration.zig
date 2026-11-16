//! Context window migration SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const openRaw = shared_fixtures.openRaw;

test "frozen context window schema 69 migration pins legacy policy and rolls back failed backfill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/legacy.sqlite3", .{root});
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
    try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(raw, store_testing.baseline_rows);
    for (store_schema.migrations) |step| {
        if (step.from == 68) break;
        for (step.sqlite) |statement| try sqlite.exec(raw, statement);
    }
    try sqlite.exec(raw, @embedFile("../migration_window_rows.sql"));
    try sqlite.exec(raw, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF;PRAGMA user_version=68");
    try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d}", .{store_schema.application_id}));
    const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','68'),('wire_version',?1),('store_selector',?2)");
    defer _ = c.sqlite3_finalize(meta);
    try sqlite.bindText(meta, 1, protocol.wire_version);
    try sqlite.bindText(meta, 2, root);
    try sqlite.expectDone(meta);
    const step = store_schema.migrations[68 - store_schema.migration_baseline];
    // Fail after the complete rebuild/backfill, at its new bounded CHECK.
    const bad = step.sqlite[0..step.sqlite.len].* ++ [_][:0]const u8{"UPDATE model_operation SET context_window=-1"};
    try std.testing.expectError(error.SqliteExecFailed, store_schema.migrate(std.testing.io, raw, root, 68, &.{.{ .from = 68, .sqlite = &bad, .mysql = &.{} }}, null));
    try std.testing.expectEqual(@as(u32, 68), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_table_info('model_operation') WHERE name='context_window'"));
    try std.testing.expectEqual(@as(u32, 4), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation"));
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
    try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE operation_id IN (1,3) AND context_window=1050000"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE operation_id IN (2,4) AND context_window=128000"));
    try std.testing.expectEqual(@as(u32, 4), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE (operation_id=1 AND tool_set_id=4) OR (operation_id IN (2,3,4) AND tool_set_id=2)"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE operation_id=4 AND reasoning_effort='high' AND effort_source_revision=1 AND previous_reasoning_effort='low' AND effort_update=1 AND previous_effort_override='medium'"));
    try std.testing.expectEqual(@as(u32, 4), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE (operation_id=1 AND latency_ms=13 AND first_event_ms=4) OR (operation_id=4 AND latency_ms=29 AND first_event_ms=7) OR (operation_id IN (2,3) AND latency_ms IS NULL AND first_event_ms IS NULL)"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE operation_id=3 AND resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at=1"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM model_operation WHERE operation_id=4 AND resolution_code='context_overflow' AND history_floor=3 AND history_level=2 AND history_dropped=4 AND output_reservation=8"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_table_info('model_operation') WHERE name='context_window' AND \"notnull\"=1 AND dflt_value IS NULL"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(raw, "UPDATE model_operation SET context_window=4294967296 WHERE operation_id=1"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(raw, "UPDATE model_operation SET context_window=NULL WHERE operation_id=1"));
    try store_schema.openExisting(std.testing.io, raw, root, null, null);
}
