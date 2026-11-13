//! Migration SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const configureTestSession = store_testing.configureTestSession;
const schema_version = store_schema.schema_version;
const testingBytesContent = tests.testingBytesContent;
const createMaximumCanonicalStore = shared_fixtures.createMaximumCanonicalStore;
const freshStoreWithExpectedRows = shared_fixtures.freshStoreWithExpectedRows;
const openRaw = shared_fixtures.openRaw;
const storeId = shared_fixtures.storeId;
const writeRows = shared_fixtures.writeRows;

test "a Store at the migration baseline with its rows takes every migration at open and reads as a fresh Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var migrated_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const migrated = try std.fmt.bufPrint(&migrated_buffer, "{s}/migrated.sqlite3", .{root});
    var fresh_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&fresh_buffer, "{s}/fresh.sqlite3", .{root});
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, store_schema.migration_baseline }));
        const meta = try sqlite.prepare(raw, std.fmt.comptimePrint("INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','{d}')", .{store_schema.migration_baseline}));
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, protocol.wire_version);
        try sqlite.bindText(meta, 2, root);
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(raw, store_testing.baseline_rows);
    }
    var storage: Store = undefined;
    storage.open(std.testing.io, migrated, root) catch |err| {
        std.debug.print("the Store at the migration baseline did not open: {s}\n", .{@errorName(err)});
        return err;
    };
    try storage.close();
    try freshStoreWithExpectedRows(fresh, root);

    var migrated_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer migrated_rows.deinit();
    var fresh_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fresh_rows.deinit();
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try writeRows(raw, &migrated_rows.writer);
    }
    // Format 54 draws each migrated Store its own id.
    try std.testing.expect(!std.mem.eql(u8, &try storeId(migrated), &try storeId(fresh)));
    {
        const raw = try openRaw(fresh);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &fresh_rows.writer);
    }
    try std.testing.expect(migrated_rows.written().len > 1000);
    try std.testing.expectEqualStrings(fresh_rows.written(), migrated_rows.written());
}

test "schema 74 migration deletes a populated Store's wire label, whatever it reads, and preserves its rows" {
    // Format 73 Stores saved wire 16; an unknown label migrates the same way.
    for ([_][]const u8{ "16", "unknown-label" }) |label| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/format-73.sqlite3", .{root});
        const previous: u32 = 73;
        {
            const raw = try openRaw(path);
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
            try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
            try sqlite.exec(raw, store_testing.baseline_rows);
            inline for (store_schema.migrations) |step| if (step.from < previous) {
                inline for (step.sqlite) |sql| try sqlite.exec(raw, sql);
            };
            const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','73')");
            defer _ = c.sqlite3_finalize(meta);
            try sqlite.bindText(meta, 1, label);
            try sqlite.bindText(meta, 2, root);
            try sqlite.expectDone(meta);
            try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, previous }));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        }
        const original_id = try storeId(path);
        // The first open migrates; the second opens the current format with no label.
        for (0..2) |_| {
            var storage: Store = undefined;
            try storage.open(std.testing.io, path, root);
            defer storage.close() catch unreachable;
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='format' AND meta_value=?1", .{std.fmt.comptimePrint("{d}", .{store_schema.schema_version})}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref='d8mv7p'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        }
        try std.testing.expectEqualStrings(&original_id, &try storeId(path));
    }
}

test "schema 72 migration opens a populated wire 15 Store and preserves its rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/wire-15.sqlite3", .{root});
    const previous: u32 = 71;
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        inline for (store_schema.migrations) |step| if (step.from < previous) {
            inline for (step.sqlite) |sql| try sqlite.exec(raw, sql);
        };
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','15'),('store_selector',?1),('format','71')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, previous }));
    }
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='format' AND meta_value=?1", .{std.fmt.comptimePrint("{d}", .{store_schema.schema_version})}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref='d8mv7p'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
}

test "schema 71 migration opens a populated wire 14 Store and preserves its rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/wire-14.sqlite3", .{root});
    const previous: u32 = 70;
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        inline for (store_schema.migrations) |step| if (step.from < previous) {
            inline for (step.sqlite) |sql| try sqlite.exec(raw, sql);
        };
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','14'),('store_selector',?1),('format','70')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, previous }));
    }
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='format' AND meta_value=?1", .{std.fmt.comptimePrint("{d}", .{store_schema.schema_version})}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref='d8mv7p'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
}

test "schema 70 migration opens a populated wire 13 Store and preserves its rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/wire-13.sqlite3", .{root});
    const previous: u32 = 69;
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        inline for (store_schema.migrations) |step| if (step.from < previous) {
            inline for (step.sqlite) |sql| try sqlite.exec(raw, sql);
        };
        try sqlite.exec(raw, "UPDATE session SET parent_ref='d8mv7p' WHERE session_ref='brhkcj'");
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','13'),('store_selector',?1),('format','69')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, previous }));
    }
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='format' AND meta_value=?1", .{std.fmt.comptimePrint("{d}", .{store_schema.schema_version})}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref='d8mv7p'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        try tests.expectWireMigrationFacts(&storage, &tmp);
    }
}

test "schema 66 migration freezes actual effort emission and prior admitted fallback" {
    for (std.enums.values(store_testing.EffortMigrationChoice)) |choice| for ([_]bool{ false, true }) |legacy_codec| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/effort-65.sqlite3", .{root});
        // These cases exercise the schema 65 -> 66 effort migration.
        const previous: u32 = 65;
        {
            const raw = try openRaw(path);
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
            try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
            try sqlite.exec(raw, store_testing.baseline_rows);
            inline for (store_schema.migrations) |step| if (step.from < previous) {
                inline for (step.sqlite) |sql| try sqlite.exec(raw, sql);
            };
            try sqlite.exec(raw, store_testing.operation_effort_migration_seed);
            try sqlite.exec(raw, choice.sql());
            if (legacy_codec) try sqlite.exec(raw, "UPDATE session SET codec='openai-responses/1' WHERE session_ref='d8mv7p'");
            try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, previous }));
            const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','12'),('store_selector',?1),('format',?2)");
            defer _ = c.sqlite3_finalize(meta);
            try sqlite.bindText(meta, 1, root);
            try sqlite.bindText(meta, 2, std.fmt.comptimePrint("{d}", .{previous}));
            try sqlite.expectDone(meta);
        }
        // Actual current emission differs from the previous Operation's value
        // comparison after a base. Both facts must survive migration/reopen.
        for (0..2) |_| {
            var storage: Store = undefined;
            try storage.open(std.testing.io, path, root);
            defer storage.close() catch unreachable;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=1 AND reasoning_effort='low' AND previous_reasoning_effort IS NULL AND effort_source_revision=1 AND effort_update=0 AND previous_effort_override IS NULL", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=99 AND previous_effort_override IS NULL AND previous_reasoning_effort='low' AND effort_source_revision=2 AND effort_update=?1", .{@intFromBool(!legacy_codec)}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=100 AND previous_reasoning_effort='high' AND effort_source_revision=2 AND effort_update=0", .{}));
            const emitted = !legacy_codec and choice != .back_to_top;
            const source: u64 = if (choice == .retained) 2 else 3;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=101 AND previous_reasoning_effort='high' AND effort_source_revision=?1 AND effort_update=?2 AND resolution_code IS NULL", .{ source, @intFromBool(emitted) }));
            if (choice == .legacy_new_choice) {
                if (try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE field='reasoning_effort_refused'", .{}) == 0) {
                    // The newer legacy raw choice already existed when this
                    // earlier source was refused. Source identity is immutable.
                    try store_testing.exec(&storage, "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at,provider_text,refused_operation_id) VALUES('d8mv7p',30,0,2,'reasoning_effort_refused',1793781802,'refused',99)", .{});
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s WHERE session_ref='d8mv7p' AND " ++ configuration_domain.reasoningEffortOverrideSql("s") ++ "='xhigh'", .{}));
                try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT effort_source_revision FROM session_revision WHERE session_ref='d8mv7p' AND revision=3", .{}));
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        }
    };
}

test "the previous Store format preserves change rows and admits bounded effort refusal text after migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/previous.sqlite3", .{root});
    // Exercise the schema 65 -> 66 effort migration before later steps.
    const previous: u32 = 65;
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format',?3)");
        defer _ = c.sqlite3_finalize(meta);
        // The base format uses released wire 12; exercise its forward update too.
        try sqlite.bindText(meta, 1, "12");
        try sqlite.bindText(meta, 2, root);
        try sqlite.bindText(meta, 3, std.fmt.comptimePrint("{d}", .{previous}));
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        inline for (store_schema.migrations) |step| if (step.from < previous) {
            inline for (step.sqlite) |sql| try sqlite.exec(raw, sql ++ ";");
        };
        // Populate the exact old shape before the format-66 step rebuilds it.
        try sqlite.exec(raw, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES('effort-migration',1,'d8mv7p',zeroblob(32),1,'',2,0,100)");
        try sqlite.exec(raw, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) " ++
            "SELECT session_ref,2,'effort-migration',workspace,provider,model,instructions_content_id,0,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,'high',label FROM session_revision WHERE session_ref='d8mv7p' AND revision=1");
        try sqlite.exec(raw, "UPDATE session SET codec='openai-responses/2',revision=2,reasoning_effort='high',next_position=9 WHERE session_ref='d8mv7p'");
        try sqlite.exec(raw, "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) VALUES('d8mv7p',6,0,2,'reasoning_effort',1793781800)");
        try sqlite.exec(raw, "UPDATE model_operation SET reasoning_effort='low' WHERE operation_id=1");
        try sqlite.exec(raw, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,reasoning_effort,attempt_ordinal,retry_due_at_ms,attempt_at,tool_set_id) VALUES(99,1,'d8mv7p',2,1,7,0,'high',1,0,1793781800,4)");
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d};UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{ store_schema.application_id, previous, previous }));
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    try storage.close();
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM session_change WHERE session_ref='d8mv7p' AND position=6 AND ordinal=0 AND revision=2 AND field='reasoning_effort' AND changed_at=1793781800 AND provider_text IS NULL", .{}));
        const insert = try sqlite.prepare(raw, "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at,provider_text,refused_operation_id) VALUES('d8mv7p',8,0,2,'reasoning_effort_refused',1793781801,?1,99)");
        defer _ = c.sqlite3_finalize(insert);
        const maximum = @import("../../outcome_code.zig").max_report_bytes;
        try sqlite.bindText(insert, 1, &@as([maximum + 1]u8, @splat('x')));
        try std.testing.expectEqual(c.SQLITE_CONSTRAINT, c.sqlite3_step(insert));
        try std.testing.expectEqual(c.SQLITE_CONSTRAINT_CHECK, c.sqlite3_extended_errcode(raw));
        _ = c.sqlite3_reset(insert);
        try sqlite.bindText(insert, 1, "unsupported_value: high is not supported");
        try sqlite.expectDone(insert);
        try std.testing.expectEqual(@as(u64, 2), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM session_change WHERE session_ref='d8mv7p'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    var request: protocol.ActivityPage = .{ .kinds = .initOne(.session_changed) };
    try request.session.set("d8mv7p");
    const page = try store_core.activityPageForTesting(&storage, request);
    try std.testing.expectEqual(@as(usize, 2), page.count);
    try std.testing.expectEqual(protocol.SessionField.reasoning_effort_refused, page.items[1].value.session_changed.field);
    try std.testing.expectEqualStrings("unsupported_value: high is not supported", page.items[1].value.session_changed.provider_text.?.slice());
}

test "schema 57 refusal rows migrate to wire 10 without changing command identity or sender positions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    const Legacy = struct {
        const cases = [_]struct { key: []const u8, target: []const u8, code: protocol.MessageRejection }{
            .{ .key = "legacy-empty-addressed", .target = "", .code = .invalid_session_reference },
            .{ .key = "legacy-invalid-addressed", .target = &@as([protocol.max_session_bytes]u8, @splat('A')), .code = .invalid_session_reference },
            .{ .key = "legacy-unknown-addressed", .target = "absent", .code = .unknown_session },
        };

        fn expectSaved(database: *c.sqlite3, commands: []const wire_request.MessageCommand) !void {
            for (commands, cases, 0..) |*command, case, index| {
                const digest = command.semanticDigest();
                try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(database, "SELECT count(*) FROM core_command c JOIN sent_rejection s ON s.command_key=c.command_key " ++
                    "WHERE c.command_key=?1 AND c.kind=2 AND c.target=?2 AND c.input_digest=?3 " ++
                    "AND c.accepted=0 AND c.code=?4 AND c.command_seq=?5 AND c.revision=0 AND c.created=0 " ++
                    "AND c.primary_content_id IS NULL AND c.secondary_content_id IS NULL " ++
                    "AND s.sender_session_ref='brhkcj' AND s.sender_position=?6 AND s.rejected_at=?7", .{ case.key, case.target, store_testing.Blob{ .bytes = &digest }, @tagName(case.code), 1000 + index, 6 + index, 1793781800 + index }));
            }
            try std.testing.expectEqual(@as(u64, 3), try store_testing.sqliteQueryU64(database, "SELECT count(*) FROM sent_rejection", .{}));
            try std.testing.expectEqual(@as(u64, 12), try store_testing.sqliteQueryU64(database, "SELECT count(*) FROM core_command", .{}));
            try std.testing.expectEqual(@as(u64, 9), try store_testing.sqliteQueryU64(database, "SELECT next_position FROM session WHERE session_ref='brhkcj'", .{}));
        }
    };
    var payload: wire_request.MessageCommand = .{ .text = try testingBytesContent(&tmp, "legacy-refused-body", "a saved rejected Message") };
    defer payload.removeTemporaryContent(std.testing.io) catch unreachable;
    const commands = try arena.alloc(wire_request.MessageCommand, Legacy.cases.len);
    for (commands, Legacy.cases) |*command, case| {
        command.* = .{ .text = payload.text, .sender = .{}, .sender_handle = .{} };
        try command.key.set(case.key);
        try command.session.set(case.target);
        try command.sender.?.store.set(root);
        try command.sender.?.session.set("brhkcj");
        // A historical refusal outlives its live sender handle. Its saved
        // digest is the production request identity, not a normalized target.
        try command.sender_handle.?.set("00112233445566778899aabbccddeeff");
    }
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 57) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=57;PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF", .{store_schema.application_id}));
        try store_testing.sqliteExec(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','9'),('store_selector',?1),('format','57')", .{root});
        // These are historical addressed rejections, including an empty
        // address. None asserts that creation was requested or refused.
        for (commands, Legacy.cases, 0..) |*command, case, index| {
            const digest = command.semanticDigest();
            try store_testing.sqliteExec(raw, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,2,?2,?3,0,?4,0,0,?5)", .{ case.key, case.target, store_testing.Blob{ .bytes = &digest }, @tagName(case.code), 1000 + index });
            try store_testing.sqliteExec(raw, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,'brhkcj',?2,?3)", .{ case.key, 6 + index, 1793781800 + index });
        }
        try sqlite.exec(raw, "UPDATE session SET next_position=9 WHERE session_ref='brhkcj'");
        try Legacy.expectSaved(raw, commands);
        try std.testing.expectEqual(@as(u32, 57), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version' AND meta_value='9'", .{}));
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_foreign_key_check"));
    }
    // Both the migrating open and a subsequent current-format open use the
    // production owner, including canonical schema and foreign-key checks.
    var sender: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sender.set("brhkcj");
    const facts = try arena.create(protocol.ActivityFacts);
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u64, store_schema.schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
        try Legacy.expectSaved(storage.sqliteDatabase(), commands);
        inline for (.{ .forward, .backward }) |direction| {
            const request: protocol.ActivityPage = .{ .session = sender, .direction = direction, .kinds = .initOne(.send_failed) };
            try storage.activityPage(&request, facts);
            try std.testing.expectEqual(@as(usize, Legacy.cases.len), facts.count);
            try std.testing.expect(!facts.more);
            for (facts.items[0..facts.count], 0..) |item, ordinal| {
                const index = if (direction == .forward) ordinal else Legacy.cases.len - ordinal - 1;
                const failed = item.value.send_failed;
                try std.testing.expectEqual(@as(u64, 6 + index), item.position);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                try std.testing.expectEqual(@as(u64, 1793781800 + index), item.at);
                try std.testing.expectEqualStrings(Legacy.cases[index].key, failed.key.slice());
                try std.testing.expectEqualStrings(@tagName(Legacy.cases[index].code), failed.code.slice());
                if (index < 2) {
                    try std.testing.expect(failed.target == null);
                } else {
                    try std.testing.expectEqualStrings("absent", failed.target.?.session.slice());
                    try std.testing.expectEqual(@as(usize, 0), failed.target.?.label.len);
                }
            }
        }
        for (commands, Legacy.cases) |*command, case| {
            const replay = storage.submitMessageWithModel(command, null, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(case.code, replay.rejected.code);
        }
        try Legacy.expectSaved(storage.sqliteDatabase(), commands);
    }
}

test "schema 53 moves forward with loaded tools defaulting to NULL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 53) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=53", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','53')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, protocol.wire_version);
        try sqlite.bindText(meta, 2, root);
        try sqlite.expectDone(meta);
        // Saved pre-T4a identities survive migration and must replay, not
        // conflict. These golden digests use the old algorithm's bytes.
        try sqlite.exec(raw, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES" ++
            "('legacy-configure',1,'',X'e983bd4a7dce4a1ec777d065815928f654ac824dc57a57b397b8f78e7a4ede3a',0,'incomplete_initial_configuration',0,0,1000)," ++
            "('legacy-create-message',2,'',X'29da99db4ed9dcdf55128d1f956d9551106135b126ec23d2e97cc768618b8127',0,'incomplete_initial_configuration',0,0,1001)");
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
    inline for (.{ "session", "session_revision" }) |table| {
        try std.testing.expect((try store_testing.queryU64(&storage, "SELECT count(*) FROM " ++ table, .{})) > 0);
        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM " ++ table ++ " WHERE loaded_tool_set_id IS NOT NULL", .{}));
    }
    var configure: wire_request.ConfigureCommand = .{};
    try configure.key.set("legacy-configure");
    const configure_replay = try storage.configure(&configure, .{});
    try std.testing.expect(configure_replay == .rejected);
    try std.testing.expect(configure_replay.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, configure_replay.rejected.code);
    var message: wire_request.MessageCommand = .{ .configuration = .{} };
    try message.key.set("legacy-create-message");
    message.text = try testingBytesContent(&tmp, "legacy-message", "go");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    const message_replay = storage.submitMessageWithModel(&message, null, .{});
    try std.testing.expect(message_replay == .rejected);
    try std.testing.expect(message_replay.rejected.replayed);
    try std.testing.expectEqual(protocol.MessageRejection.incomplete_initial_configuration, message_replay.rejected.code);
    const violations = try sqlite.prepare(storage.sqliteDatabase(), "PRAGMA foreign_key_check");
    defer _ = c.sqlite3_finalize(violations);
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(violations));
}

test "a migration whose step fails leaves its backup and the original Store readable, and replaces an earlier backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    const backup_name = "store.backup";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = backup_name, .data = "earlier" });
    // Names that only begin like the copy's are someone else's.
    for ([_][]const u8{ "store.sqlite3.kept", "store.backup.saved", "store.backup-old" }) |kept| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = kept, .data = "kept" });
    }
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectError(error.MigrationBrokeForeignKey, store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session"}, .mysql = &.{} }}, null));
    }
    for ([_][]const u8{ "store.sqlite3.kept", "store.backup.saved", "store.backup-old" }) |kept| {
        var kept_buffer: [8]u8 = undefined;
        try std.testing.expectEqualStrings("kept", try tmp.dir.readFile(std.testing.io, kept, &kept_buffer));
    }
    var backup_path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const backup_path = try std.fmt.bufPrint(&backup_path_buffer, "{s}/" ++ backup_name, .{store.root});
    for ([_][]const u8{ store.path, backup_path }) |path| {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session_revision"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_integrity_check WHERE integrity_check='ok'"));
    }
    // A backup that cannot be written refuses the Store before any step runs.
    try tmp.dir.deleteFile(std.testing.io, backup_name);
    try tmp.dir.createDir(std.testing.io, backup_name, .default_dir);
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectError(error.MigrationBackupFailed, store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session_revision"}, .mysql = &.{} }}, null));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session_revision"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "PRAGMA foreign_keys"));
    }
    try std.testing.expect((try tmp.dir.statFile(std.testing.io, backup_name, .{})).kind == .directory);
}

test "a Store at the maximum path backs itself up before a migration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}{s}", .{ store_path, platform.database_suffix });
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), database.len);
    {
        var storage: Store = undefined;
        try storage.open(io, database, store_path);
        defer storage.close() catch unreachable;
        _ = try configureTestSession(&storage, "migration-session");
    }
    const raw = try openRaw(database);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, "UPDATE store_meta SET meta_value='7' WHERE meta_key='format';PRAGMA user_version=7");
    try std.testing.expectError(error.MigrationBrokeForeignKey, store_schema.migrate(io, raw, store_path, 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session"}, .mysql = &.{} }}, null));
    var backup_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const backup = try std.fmt.bufPrint(&backup_buffer, "{s}/rui.backup", .{store_path});
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, backup, .{})).size > 0);
}

/// `object`'s CREATE text in the current schema.
fn objectSql(comptime name: []const u8) [:0]const u8 {
    comptime {
        for (store_schema.objects(.sqlite)) |object| if (std.mem.eql(u8, object.name, name)) {
            const terminated = object.sql ++ "\x00";
            return terminated[0..object.sql.len :0];
        };
        @compileError("no schema object " ++ name);
    }
}

/// A current Store whose store_meta format reads `from`, with one Session.
fn storeAtFormat(tmp: *std.testing.TmpDir, path_buffer: []u8, root_buffer: []u8, comptime from: u32) !struct { path: []const u8, root: []const u8 } {
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, root_buffer)];
    const path = try std.fmt.bufPrint(path_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    _ = try configureTestSession(&storage, "migration-session");
    try storage.close();
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format';PRAGMA user_version={d}", .{ from, from }));
    return .{ .path = path, .root = root };
}

test "a migration that rebuilds a referenced table from the schema's text keeps its rows and references, and the Store opens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    const rebuild = comptime blk: {
        var statements: []const [:0]const u8 = &.{ "ALTER TABLE session RENAME TO session_old", objectSql("session"), "INSERT INTO session SELECT * FROM session_old", "DROP TABLE session_old" };
        for (store_schema.indexes) |index| if (std.mem.eql(u8, index.table, "session")) {
            statements = statements ++ .{objectSql(index.name)};
        };
        break :blk statements;
    };
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = rebuild, .mysql = &.{} }}, null);
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, store.path, store.root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
}

test "a migration that leaves other text than bootstrap's, or a broken reference, or runs on another format, commits nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    // SQLite splices an added column into the table's text, so the column
    // bootstrap would write in place reads differently.
    const added = "ALTER TABLE session ADD COLUMN migration_probe INTEGER";
    const Case = struct { from: u32, statements: []const [:0]const u8, refusal: anyerror };
    const cases = [_]Case{
        .{ .from = 7, .statements = &.{added}, .refusal = error.WrongStoreSchema },
        .{ .from = 7, .statements = &.{"DELETE FROM session"}, .refusal = error.MigrationBrokeForeignKey },
        .{ .from = 6, .statements = &.{}, .refusal = error.WrongStoreVersion },
    };
    const raw = try openRaw(store.path);
    defer _ = c.sqlite3_close(raw);
    for (cases) |case| {
        try std.testing.expectError(case.refusal, store_schema.migrate(std.testing.io, raw, store.root, case.from, &.{.{ .from = case.from, .sqlite = case.statements, .mysql = &.{} }}, null));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session"));
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_table_info('session') WHERE name='migration_probe'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "PRAGMA foreign_keys"));
    }
}

test "schema 55 migrates recovery index and wire 8 together to the current schema and wire" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 55) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM sqlite_schema WHERE name='action_operation_indeterminate'", .{}));
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=55", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','8'),('store_selector',?1),('format','55')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='action_operation_indeterminate'", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
}

test "schema 54 gains empty model catalog tables at 55 without changing its rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 54) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqliteQueryU64(raw, "SELECT count(*) FROM sqlite_schema WHERE name IN ('model_fact','model_catalog_source')", .{}));
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=54", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','54')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, protocol.wire_version);
        try sqlite.bindText(meta, 2, root);
        try sqlite.expectDone(meta);
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
    try std.testing.expect((try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{})) > 0);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_fact", .{}));
    try std.testing.expect(try storage.readModelCatalogSource() == null);
}
