//! Model settlement SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const TestingSessionReport = tests.TestingSessionReport;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const expectContent = tests.expectContent;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleMessagesForTesting = tests.settleMessagesForTesting;
const testingContentReference = tests.testingContentReference;
const testingSessionReport = tests.testingSessionReport;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;

test "Core classifies trustworthy calls atomically without Action-shaped rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const allocated_session_0 = try configureTestSessionAsk(&storage, "mixed-config");
    try submitTestMessage(&storage, &tmp, "mixed-message", "mixed-message", allocated_session_0.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-3", .name = "bash", .encoded_call_id = "call-3", .decoded_call_id = "call-3", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "item-4", .name = "bash", .encoded_call_id = "call-4", .decoded_call_id = "call-4", .encoded_arguments = "{\\\"command\\\":\\\"wrong\\\"}", .decoded_arguments = "{\"command\":\"wrong\"}" },
        .{ .item_id = "item-5", .name = "edit", .encoded_call_id = "call-5", .decoded_call_id = "call-5", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-6", .name = &@as([300]u8, @splat('x')), .encoded_call_id = "call-6", .decoded_call_id = "call-6", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-7", .name = "bash", .encoded_call_id = "call-7", .decoded_call_id = "call-7", .encoded_arguments = "{\\\"description\\\":\\\"Run seventh command\\\",\\\"cmd\\\":\\\"seven\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run seventh command\",\"cmd\":\"seven\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mixed-metadata", &calls);

    try std.testing.expectEqual(@as(u64, 7), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
    try std.testing.expectEqual(@as(u64, 5), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code IS NOT NULL", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=4 AND rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=5 AND rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal WHERE tool_call.rejection_code IS NOT NULL", .{}));
    try expectDenseSessionPositions(&storage, allocated_session_0.slice());
    {
        const rejected_action = try sqlite.prepare(storage.sqliteDatabase(), "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,resolution_code) VALUES(999,?1,1,?2,1,1,0,NULL)");
        defer _ = c.sqlite3_finalize(rejected_action);
        try sqlite.bindU64(rejected_action, 1, binding.operation_id);
        try sqlite.bindText(rejected_action, 2, allocated_session_0.slice());
        try std.testing.expectError(error.StatementFailed, sqlite.expectDone(rejected_action));
    }
    var observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.action_count);
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    const first_action_id = first: {
        const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024, .full);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 2), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("0", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[1].call_ordinal);
        try std.testing.expectEqual(@as(usize, 5), report.value.rejected_calls.items.len);
        const rejected = report.value.rejected_calls.items[0];
        try std.testing.expectEqualStrings("1", rejected.call_ordinal);
        try std.testing.expectEqualStrings("unknown_tool", rejected.code);
        try std.testing.expect((try std.fmt.parseInt(u64, rejected.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("20", rejected.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Unknown tool: other."), .lower),
            rejected.result.sha256,
        );
        inline for (.{
            .{ rejected.name, "other" },
            .{ rejected.call_id, "call-2" },
            .{ rejected.arguments, "{}" },
        }) |expected| {
            var length_buffer: [20]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&length_buffer, "{d}", .{expected[1].len}), expected[0].bytes);
            const digest = protocol.contentDigest(expected[1]);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), expected[0].sha256);
        }
        var full = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
        defer full.deinit();
        const rejected_rows = full.value.object.get("rejected_calls").?.object.get("items").?.array.items;
        for (rejected_rows) |row| {
            const p = row.object.get("presentation").?.object;
            try std.testing.expect(p.get("description").? == .null);
            try std.testing.expect(p.get("publication_position").? == .null);
            try std.testing.expectEqualStrings(row.object.get("code").?.string, p.get("code").?.string);
        }
        const full_rejected = full.value.object.get("full").?.object.get("tool_calls").?.array.items[1].object;
        try std.testing.expectEqualStrings("other", full_rejected.get("name").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("{}", full_rejected.get("arguments").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("Unknown tool: other.", full_rejected.get("rejection_result").?.object.get("text").?.string);
        break :first try std.fmt.parseInt(u64, report.value.actions.unresolved[0].action, 10);
    };
    {
        const content_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=5", .{});
        const metadata = try testingContentReference(&storage, content_id);
        var reader: ContentReader = undefined;
        reader.open(try storage.openContent(metadata));
        defer reader.close();
        var result: [192]u8 = undefined;
        const count = try reader.read(0, &result);
        try std.testing.expect(std.mem.startsWith(u8, result[0..count], "Unknown tool: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…"));
        try std.testing.expect(std.mem.indexOf(u8, result[0..count], "name continues; Rui content digest") != null);
    }
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny.key.set("mixed-deny");
    try deny.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
    observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    {
        const report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.resolved.len);
        const resolved = report.value.actions.resolved[0];
        try std.testing.expectEqualStrings("0", resolved.call_ordinal);
        try std.testing.expectEqualStrings("denied", resolved.code);
        try std.testing.expect((try std.fmt.parseInt(u64, resolved.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("18", resolved.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Permission denied."), .lower),
            resolved.result.sha256,
        );
    }

    try storage.close();
    storage_open = false;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var database: [platform.max_database_path_bytes]u8 = undefined;
    var reopened: Store = undefined;
    try reopened.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    const recovered = try reopened.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), recovered.action_count);
    try std.testing.expectEqual(@as(u64, 5), recovered.rejected_call_count);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM action_operation WHERE action_id=(SELECT min(action_id) FROM action_operation) " ++
        "AND parent_operation_id=(SELECT min(parent_operation_id) FROM action_operation) " ++
        "AND call_ordinal=0 AND resolution_code='denied'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM permission_decision_command WHERE command_key='mixed-deny' " ++
        "AND action_id=CAST((SELECT min(action_id) FROM action_operation) AS TEXT)", .{}));
    try expectContent(&reopened, try reopened.actionCallId(allocated_session_0.slice(), first_action_id), "call-1");
    try expectContent(&reopened, try reopened.actionArguments(allocated_session_0.slice(), first_action_id), "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}");
    const recovered_bytes = try testingSessionReport(&reopened, &tmp, allocated_session_0.slice(), 1024 * 1024);
    defer std.testing.allocator.free(recovered_bytes);
    const recovered_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
    defer recovered_report.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered_report.value.actions.unresolved.len);
    try std.testing.expectEqualStrings("6", recovered_report.value.actions.unresolved[0].call_ordinal);
    try std.testing.expectEqual(@as(usize, 5), recovered_report.value.rejected_calls.items.len);
}

test "a Bash call the Operation did not offer is rejected and keeps its description" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("unoffered-config", "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{});
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    try submitTestMessage(&storage, &tmp, "unoffered-message", "unoffered-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "unoffered-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code='unknown_tool' AND description='Run'", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
}

test "an item id repeated in a later batch or the same batch fails the settlement" {
    inline for (.{ 65, 1 }) |repeat_at| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "repeat-item-config");
        try submitTestMessage(&storage, &tmp, "repeat-item-input", "repeat-item-key", session.slice(), "repeat");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // Item 65 is in the second batch: a check over one batch's ids
        // alone passes it, and only the read of the saved items finds it.
        try std.testing.expectError(error.InvalidProviderEnvelope, settleMessagesForTesting(&storage, &tmp, binding, 66, false, repeat_at));
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(0, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
        try settleMessagesForTesting(&storage, &tmp, binding, 66, false, null);
        try std.testing.expectEqual(66, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
        try expectDenseSessionPositions(&storage, session.slice());
    }
}

/// How many times a settlement read its saved item ids, then its content
/// identities, each in a narrow (sixteen digests) and a wide (64)
/// statement.
fn digestReadsForTesting(storage: *Store) [4]i64 {
    var reads: [4]i64 = @splat(0);
    for (storage.engine.sqlite.statements.slots) |slot| if (slot.statement) |statement| {
        const sql = std.mem.span(slot.sql.?);
        const kind: usize = if (std.mem.startsWith(u8, sql, "SELECT item_id_digest AS digest FROM model_output_item WHERE operation_id=?1"))
            0
        else if (std.mem.startsWith(u8, sql, "SELECT content_id,digest,byte_length,private FROM content WHERE digest IN ("))
            2
        else
            continue;
        const wide = std.mem.endsWith(u8, sql, "?65)") or std.mem.endsWith(u8, sql, "?64)");
        reads[kind + @intFromBool(wide)] += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_RUN, 0);
    };
    return reads;
}

test "a settlement batch holds 64 items, read narrow up to sixteen" {
    // One batch per 64 items, so a reply of 64 settles in two rounds; a
    // batch of at most sixteen ids binds main's narrow statement. Each
    // message imports its text and its bag, and the usage record one
    // more, so 64 items look up 129 identities: two wide statements of 64
    // while more than 48 are left, then one narrow; 16 items' 33 take
    // main's three narrow ones.
    inline for (.{
        .{ 1, .{ 1, 0, 1, 0 } },
        .{ 16, .{ 1, 0, 3, 0 } },
        .{ 17, .{ 0, 1, 3, 0 } },
        .{ 64, .{ 0, 1, 1, 2 } },
        .{ 65, .{ 1, 1, 2, 2 } },
        .{ 100, .{ 0, 2, 2, 3 } },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "batch-width-config");
        try submitTestMessage(&storage, &tmp, "batch-width-input", "batch-width-key", session.slice(), "width");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleMessagesForTesting(&storage, &tmp, binding, case[0], false, null);
        try std.testing.expectEqual([4]i64{ case[1][0], case[1][1], case[1][2], case[1][3] }, digestReadsForTesting(&storage));
        try std.testing.expectEqual(case[0], try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
    }
}

test "a full item batch followed by calls keeps every queued row's bound bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "full-batch-calls-config");
    try submitTestMessage(&storage, &tmp, "full-batch-calls-input", "full-batch-calls-key", session.slice(), "full");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // 64 function_call items fill the first item batch and no usage
    // record follows, so the next item batch is empty and the call batch
    // is collected before any round steps the last item's queued row.
    var item_ids: [64][16]u8 = undefined;
    var call_ids: [64][16]u8 = undefined;
    var calls: [64]TestingCall = undefined;
    for (&calls, &item_ids, &call_ids, 0..) |*call, *item_id, *call_id, index| {
        const id = try std.fmt.bufPrint(call_id, "call-{d}", .{index});
        call.* = .{
            .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
            .name = "bash",
            .encoded_call_id = id,
            .decoded_call_id = id,
            .encoded_arguments = "{\\\"description\\\":\\\"Run it\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"description\":\"Run it\",\"cmd\":\"true\",\"timeout_ms\":null}",
        };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "full-batch-calls", &calls);
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT item_id_digest) FROM model_output_item", .{}));
    const digest = protocol.contentDigest("item-63");
    const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM model_output_item WHERE item_ordinal=63 AND item_id_digest=?1");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindBlob(statement, 1, &digest);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(1, c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "a success settlement keeps main's answers for a missing Session or revision row" {
    inline for (.{
        .{ "DELETE FROM session_revision", error.StaleAttemptBinding, false },
        .{ "DELETE FROM session", error.CorruptStore, true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "missing-row-config");
        try submitTestMessage(&storage, &tmp, "missing-row-input", "missing-row-key", session.slice(), "missing");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), case[0]);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        // A missing revision row is a stale binding, as on main; a missing
        // Session row fences, as main's session facts read did, where an
        // inner join reported a stale binding that does not fence.
        try std.testing.expectError(case[1], settleMessagesForTesting(&storage, &tmp, binding, 1, false, null));
        try std.testing.expectEqual(case[2], storage.isFenced());
    }
}

test "a success settlement whose pending Messages read fails reports main's SessionStopReadFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "stop-read-config");
    try submitTestMessage(&storage, &tmp, "stop-read-input", "stop-read-key", session.slice(), "first");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A pending Message makes the count read the stop cutoff.
    try submitTestMessage(&storage, &tmp, "stop-read-second", "stop-read-second-key", session.slice(), "second");
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES('stop-read-stop',?1,NULL,0,1)", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try store_testing.failReadsOf(&storage, "session_stop");
    // Round 1 reads it with the Attempt; a step failure there was
    // `OperationReadFailed` before each read kept main's name.
    try std.testing.expectError(error.SessionStopReadFailed, settleMessagesForTesting(&storage, &tmp, binding, 1, false, null));
    try std.testing.expect(storage.isFenced());
}

test "64 calls with distinct unknown names fit one call batch's identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "unknown-calls-config");
    try submitTestMessage(&storage, &tmp, "unknown-calls-input", "unknown-calls-key", session.slice(), "unknown");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // Each call imports four identities: its name, call_id, arguments and
    // rejection text, 256 in all. The shared removed-result prelookup adds
    // one more identity, exercising the final lookup's padded window.
    var item_ids: [64][16]u8 = undefined;
    var call_ids: [64][16]u8 = undefined;
    var names: [64][16]u8 = undefined;
    var arguments: [64][32]u8 = undefined;
    var calls: [64]TestingCall = undefined;
    for (&calls, &item_ids, &call_ids, &names, &arguments, 0..) |*call, *item_id, *call_id, *name, *argument, index| {
        const id = try std.fmt.bufPrint(call_id, "call-{d}", .{index});
        const text = try std.fmt.bufPrint(argument, "{{}}{d}", .{index});
        call.* = .{
            .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
            .name = try std.fmt.bufPrint(name, "tool_{d}", .{index}),
            .encoded_call_id = id,
            .decoded_call_id = id,
            .encoded_arguments = text,
            .decoded_arguments = text,
        };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "unknown-calls", &calls);
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call WHERE rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT name_content_id) FROM model_tool_call", .{}));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT arguments_content_id) FROM model_tool_call", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "equal texts in many batches share one row, and entries keep item order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "same-text-config");
    try submitTestMessage(&storage, &tmp, "same-text-input", "same-text-key", session.slice(), "same");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A later batch's lookup runs after the earlier batch's inserts.
    try settleMessagesForTesting(&storage, &tmp, binding, 140, true, null);
    try std.testing.expectEqual(1, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT message_content_id) FROM model_output_item", .{}));
    try std.testing.expectEqual(140, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE entry_kind=3", .{}));
    try std.testing.expectEqual(0, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN model_output_item i " ++
        "ON i.operation_id=e.source_operation_id AND i.item_ordinal=e.source_item_ordinal WHERE e.session_position<>i.session_position", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "an item with more content than a batch holds settles through its own lookups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "wide-item-config");
    try submitTestMessage(&storage, &tmp, "wide-item-input", "wide-item-key", session.slice(), "wide");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // 300 distinct summary texts: more identities than one batch's 256.
    var reasoning_buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&reasoning_buffer);
    try writer.writeAll("{\"type\":\"reasoning\",\"id\":\"wide\",\"summary\":[");
    for (0..300) |index| try writer.print("{s}{{\"type\":\"summary_text\",\"text\":\"summary {d}\"}}", .{ if (index == 0) "" else ",", index });
    try writer.writeAll("],\"encrypted_content\":\"opaque\"}");
    const items = [_][]const u8{ writer.buffered(), "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}" };
    try settleItemsForTesting(&storage, &tmp, binding, &items, "done");
    try std.testing.expectEqual(300, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT text_content_id) FROM model_output_part WHERE part_kind=3", .{}));
    try std.testing.expectEqual(2, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}
