//! Skills migration SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const testingBytesContent = tests.testingBytesContent;
const testingContentReference = tests.testingContentReference;
const freshStoreWithExpectedRows = shared_fixtures.freshStoreWithExpectedRows;
const openRaw = shared_fixtures.openRaw;
const writeRows = shared_fixtures.writeRows;

test "skills schema 56 wire 9 upgrades populated rows to the current Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var migrated_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const migrated = try std.fmt.bufPrint(&migrated_buffer, "{s}/skills-56.sqlite3", .{root});
    var fresh_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&fresh_buffer, "{s}/skills-fresh.sqlite3", .{root});
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 56) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        // Deliberately old metadata, not protocol.wire_version: omitting
        // the new wire UPDATE must fail the production open below.
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=56", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','9'),('store_selector',?1),('format','56')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
        try std.testing.expectEqual(@as(u32, 56), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version' AND meta_value='9'", .{}));
        try std.testing.expectEqual(@as(u64, 3), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM conversation_entry", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM sqlite_schema WHERE name='session_skill_catalog'", .{}));
    }
    {
        var storage: Store = undefined;
        try storage.open(std.testing.io, migrated, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, store_schema.schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
        try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_catalog_position IS NULL AND turn_id IS NOT NULL", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        // The old assistant answer is still ordinary public content, byte
        // for byte, accessible through the same production content reader.
        const reference = try testingContentReference(&storage, 5);
        var reader: ContentReader = undefined;
        reader.open(try storage.openContent(reference));
        defer reader.close();
        var answer: ["hello\nworld".len]u8 = undefined;
        try std.testing.expectEqual(answer.len, try reader.read(0, &answer));
        try std.testing.expectEqualStrings("hello\nworld", &answer);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const skills = try storage.readSkills(arena.allocator(), "d8mv7p");
        try std.testing.expectEqual(@as(usize, 0), skills.catalog.entries.len);
    }
    // The pinned expected rows are independent of the forward migration.
    // Compare every durable row (including new NULL provenance fields),
    // not just the populated table counts or a schema assembled as current.
    try freshStoreWithExpectedRows(fresh, root);
    var migrated_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer migrated_rows.deinit();
    var fresh_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fresh_rows.deinit();
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &migrated_rows.writer);
    }
    {
        const raw = try openRaw(fresh);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &fresh_rows.writer);
    }
    try std.testing.expect(migrated_rows.written().len > 1000);
    try std.testing.expectEqualStrings(fresh_rows.written(), migrated_rows.written());
}

test "skills schema 58 wire 10 upgrades populated archive and refusal rows to the current Store" {
    const Extra = struct {
        fn seed(raw: *c.sqlite3, archive: *const protocol.SessionArchiveCommand, refused: *const wire_request.MessageCommand) !void {
            const archive_digest = archive.semanticDigest();
            const refusal_digest = refused.semanticDigest();
            try store_testing.sqliteExec(raw, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,6,'rhvzwc',?2,1,'',0,0,1000)", .{ archive.key.slice(), store_testing.Blob{ .bytes = &archive_digest } });
            try store_testing.sqliteExec(raw, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES(?1,'rhvzwc',NULL,2,0,1793781800,0)", .{archive.key.slice()});
            try store_testing.sqliteExec(raw, "INSERT INTO session_archive(session_ref,command_key) VALUES('rhvzwc',?1)", .{archive.key.slice()});
            try store_testing.sqliteExec(raw, "INSERT INTO session_archive_command(command_key,archived) VALUES(?1,1)", .{archive.key.slice()});
            try sqlite.exec(raw, "UPDATE session SET next_position=3 WHERE session_ref='rhvzwc'");
            try store_testing.sqliteExec(raw, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,2,'absent',?2,0,'unknown_session',0,0,1001)", .{ refused.key.slice(), store_testing.Blob{ .bytes = &refusal_digest } });
            try store_testing.sqliteExec(raw, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,'brhkcj',6,1793781801)", .{refused.key.slice()});
            try sqlite.exec(raw, "UPDATE session SET next_position=7 WHERE session_ref='brhkcj'");
        }

        fn expectSaved(raw: *c.sqlite3, archive: *const protocol.SessionArchiveCommand, refused: *const wire_request.MessageCommand) !void {
            const archive_digest = archive.semanticDigest();
            const refusal_digest = refused.semanticDigest();
            try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM session_archive a JOIN session_stop s ON s.command_key=a.command_key JOIN session_archive_command requested ON requested.command_key=a.command_key JOIN core_command c ON c.command_key=a.command_key WHERE a.session_ref='rhvzwc' AND c.command_key=?1 AND c.kind=6 AND c.target='rhvzwc' AND c.input_digest=?2 AND c.accepted=1 AND c.command_seq=1000 AND requested.archived=1 AND s.session_ref='rhvzwc' AND s.position=2 AND s.admission_cutoff=0 AND s.stopped_at=1793781800 AND s.parent_caused=0", .{ archive.key.slice(), store_testing.Blob{ .bytes = &archive_digest } }));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM core_command c JOIN sent_rejection r ON r.command_key=c.command_key WHERE c.command_key=?1 AND c.kind=2 AND c.target='absent' AND c.input_digest=?2 AND c.accepted=0 AND c.code='unknown_session' AND c.command_seq=1001 AND c.primary_content_id IS NULL AND r.sender_session_ref='brhkcj' AND r.sender_position=6 AND r.rejected_at=1793781801", .{ refused.key.slice(), store_testing.Blob{ .bytes = &refusal_digest } }));
            try std.testing.expectEqual(@as(u64, 3), try store_testing.sqliteQueryU64(raw, "SELECT next_position FROM session WHERE session_ref='rhvzwc'", .{}));
            try std.testing.expectEqual(@as(u64, 7), try store_testing.sqliteQueryU64(raw, "SELECT next_position FROM session WHERE session_ref='brhkcj'", .{}));
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var migrated_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const migrated = try std.fmt.bufPrint(&migrated_buffer, "{s}/skills-58.sqlite3", .{root});
    var fresh_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&fresh_buffer, "{s}/skills-58-fresh.sqlite3", .{root});
    var archive: protocol.SessionArchiveCommand = .{};
    try archive.key.set("skills-58-archive");
    try archive.session.set("rhvzwc");
    var refused: wire_request.MessageCommand = .{ .text = try testingBytesContent(&tmp, "skills-58-refused-body", "old wire 10 refused peer message"), .sender = .{}, .sender_handle = .{} };
    defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
    try refused.key.set("skills-58-refusal");
    try refused.session.set("absent");
    try refused.sender.?.store.set(root);
    try refused.sender.?.session.set("brhkcj");
    try refused.sender_handle.?.set("00112233445566778899aabbccddeeff");
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 58) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        // Deliberately old metadata, not protocol.wire_version: omitting
        // the new wire UPDATE must fail the production open below.
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=58", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','10'),('store_selector',?1),('format','58')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
        try Extra.seed(raw, &archive, &refused);
        try Extra.expectSaved(raw, &archive, &refused);
        try std.testing.expectEqual(@as(u32, 58), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version' AND meta_value='10'", .{}));
        try std.testing.expectEqual(@as(u64, 3), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM conversation_entry", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM sqlite_schema WHERE name='session_skill_catalog'", .{}));
    }
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, migrated, root);
        defer storage.close() catch unreachable;
        try Extra.expectSaved(storage.sqliteDatabase(), &archive, &refused);
        const archive_replay = storage.archiveSession(&archive, .{});
        try std.testing.expect(archive_replay == .accepted and archive_replay.accepted.replayed and archive_replay.accepted.archived);
        const refusal_replay = storage.submitMessageWithModel(&refused, null, .{});
        try std.testing.expect(refusal_replay == .rejected and refusal_replay.rejected.replayed);
        try std.testing.expectEqual(protocol.MessageRejection.unknown_session, refusal_replay.rejected.code);
        try Extra.expectSaved(storage.sqliteDatabase(), &archive, &refused);
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, store_schema.schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
        try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_catalog_position IS NULL AND turn_id IS NOT NULL", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        // The old assistant answer is still ordinary public content, byte
        // for byte, accessible through the same production content reader.
        const reference = try testingContentReference(&storage, 5);
        var reader: ContentReader = undefined;
        reader.open(try storage.openContent(reference));
        defer reader.close();
        var answer: ["hello\nworld".len]u8 = undefined;
        try std.testing.expectEqual(answer.len, try reader.read(0, &answer));
        try std.testing.expectEqualStrings("hello\nworld", &answer);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const skills = try storage.readSkills(arena.allocator(), "d8mv7p");
        try std.testing.expectEqual(@as(usize, 0), skills.catalog.entries.len);
    }
    // The pinned expected rows are independent of the forward migration.
    // Compare every durable row (including new NULL provenance fields),
    // not just the populated table counts or a schema assembled as current.
    try freshStoreWithExpectedRows(fresh, root);
    {
        const raw = try openRaw(fresh);
        defer _ = c.sqlite3_close(raw);
        try Extra.seed(raw, &archive, &refused);
    }
    var migrated_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer migrated_rows.deinit();
    var fresh_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fresh_rows.deinit();
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &migrated_rows.writer);
    }
    {
        const raw = try openRaw(fresh);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &fresh_rows.writer);
    }
    try std.testing.expect(migrated_rows.written().len > 1000);
    try std.testing.expectEqualStrings(fresh_rows.written(), migrated_rows.written());
}
