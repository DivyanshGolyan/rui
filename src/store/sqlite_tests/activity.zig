//! Activity SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const reads_domain = @import("../domain/reads.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingSessionReport = tests.testingSessionReport;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const TestingSteps = shared_fixtures.TestingSteps;
const busyStatements = shared_fixtures.busyStatements;

test "activity revalidation takes the same steps however long a Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");

    var steps: [2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM turn", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                "SELECT value,'h1st0r',printf('history-%d',value),1,3*value,value,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'h1st0r',value,value,value,'cancelled',3*value+1,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                "SELECT printf('stop-%d',value),'h1st0r',value,value,3*value+2,1 FROM sequence",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        const guard = try sqlite.prepare(storage.sqliteDatabase(), reads_domain.activity_sequence_guard.sql);
        defer _ = c.sqlite3_finalize(guard);
        try sqlite.bindText(guard, 1, "h1st0r");
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(guard));
        cost.* = c.sqlite3_stmt_status(guard, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "public proposal structural corruption fences the activity page" {
    const faults = [_][:0]const u8{
        "UPDATE content SET private=1,payload=zeroblob(byte_length) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
        "DELETE FROM model_tool_call WHERE call_ordinal=0",
        "UPDATE turn SET session_ref='f0re1g'",
        "UPDATE model_tool_call SET name_content_id=(SELECT call_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET digest=zeroblob(32) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "run tools");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "original", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "replacement", .name = "unknown", .encoded_call_id = "sibling", .decoded_call_id = "sibling", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        };
        try settleCallsForTesting(&storage, &tmp, binding, "output", &calls);
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const healthy = try store_core.activityPageForTesting(&storage, request);
        const call = for (healthy.items[0..healthy.count]) |item| {
            if (item.value == .call) break item.value.call;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(binding.operation_id, call.operation);
        try std.testing.expectEqual(binding.turn_id, call.turn);
        try std.testing.expectEqual(@as(u64, 0), call.call_ordinal);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("unknown"), &call.fields[0].digest);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), fault);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    }
}

test "public activity admission corruption fences page and content independently" {
    const faults = [_][:0]const u8{
        "UPDATE message_admission SET admission_position=NULL WHERE command_key='message'",
        "UPDATE core_command SET target='f0re1g' WHERE command_key='message'",
        "DELETE FROM conversation_entry WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key='message')",
    };
    for (faults) |fault| {
        for ([_]bool{ false, true }) |content_route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "input bytes");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const queued = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), queued.count);
            const item = queued.items[0];
            try std.testing.expectEqualStrings("message", item.value.admission.key.slice());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("input bytes"), &item.value.admission.content.digest);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            request.position = item.position - 1;
            const result: anyerror!void = if (content_route)
                if (storage.openActivityContent(&.{ .session = request.session, .position = item.position })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (store_core.activityPageForTesting(&storage, request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "the queued Messages cost the queue, not the history after a page's end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    // Messages 1..n wait at positions 2, 4, ...; a stop at 2n+1 excludes all
    // but the newest. A page ending at the first Message has one waiting,
    // as one ending after the stop does.
    var steps: [2][2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM message_admission; DELETE FROM session_stop", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT value,'qu3u3d',printf('queued-%d',value),1,2*value,1 FROM sequence; " ++
                "INSERT INTO session_stop(command_key,session_ref,admission_cutoff,position,stopped_at) VALUES('stop','qu3u3d',{0}-1,2*{0}+1,1)",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        const statement = try storage.engine.sqlite.cachedTyped(reads_domain.queued);
        for ([_]u64{ 2, 2 * history + 1 }, [_]u64{ 1, history }, cost) |end, newest, *probe| {
            _ = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var access: reads_domain.ReadAccess = .open(&entry);
            defer access.deinit();
            var waiting: reads_domain.QueuedMessages = .{};
            access.readEach(reads_domain.queued, .{ .session = "qu3u3d", .position = end }, std.math.maxInt(u64), &waiting);
            try access.run();
            try std.testing.expectEqual(protocol.Queued{ .count = 1, .oldest_position = 2 * newest, .newest_admission = newest, .newest_position = 2 * newest }, waiting.queued);
            probe.* = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "persisted tool label corruption fences every publication route" {
    const invalid = [_]struct { sql: []const u8, failure: anyerror = error.CorruptStore }{
        .{ .sql = "' '" },
        .{ .sql = "'Read' || char(10) || 'files'" },
        .{ .sql = "char(160)" },
        .{ .sql = "'Read' || char(8232) || 'files'" },
        // The typed row's Bounded text rejects malformed UTF-8 before
        // semantic validation; a typed decode failure is CorruptStore.
        .{ .sql = "CAST(X'80' AS TEXT)" },
    };
    for (invalid) |description| {
        for ([_]enum { current, full, live_activity, settled_activity, conversation }{ .current, .full, .live_activity, .settled_activity, .conversation }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "label-config");
            try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            request.direction = .backward;
            const healthy = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 2), healthy.call_activity.total);
            try std.testing.expectEqualStrings("Run first command", healthy.call_activity.entries[0].presentation.description.?.slice());
            if (route == .settled_activity or route == .conversation) {
                var stop = try completeSessionStop("label-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(@as(usize, 3), (try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })).count);
            }
            var sql: [256]u8 = undefined;
            try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE model_tool_call SET description={s} WHERE call_ordinal=0", .{description.sql}, 0));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            const result: anyerror!void = switch (route) {
                .current, .full => if (testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, if (route == .full) .full else .current)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .live_activity, .settled_activity => if (store_core.activityPageForTesting(&storage, request)) |_| {} else |err| err,
                .conversation => if (store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
            };
            try std.testing.expectError(description.failure, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "an Activity page costs the same steps after 32 or 10,000 earlier rows" {
    // Each Store holds `history` earlier units, a Message, its call item, the
    // call's rejection and its Turn's outcome, then the same Session tail: a
    // Message, twenty rejected calls and a stop. The opening's page and a
    // forward page from the tail's first row read only the tail. At least
    // 17 history units saturate every source's bounded lookahead, including
    // model_call rows at admissions, before comparing exact VM steps.
    var steps: [2][2]i64 = undefined;
    for ([_]usize{ 32, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "cost-config");
        // Foreign keys are off: each history Message names its Turn before
        // the Turn row exists, which an immediate key would refuse.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+4*(value-1) AS position,instructions_content_id AS content FROM sequence,session; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                "SELECT value,'{1s}',printf('history-%d',value),content,position,value,1 FROM history; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) " ++
                "SELECT value,value,'{1s}',1,value,position,0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref='{1s}'),0 FROM history; " ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                "SELECT value,0,'{1s}',position+1,3,1,zeroblob(32),0,content,0 FROM history; " ++
                "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                "SELECT value,'{1s}',0,0,content,content,content,zeroblob(120),'unknown_tool',content,position+2 FROM history; " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'{1s}',value,value,value,'completed',position+3,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+4*{0}; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        // The history rows bypass the Host's ids.
        try store_core.reloadIdentitiesForTesting(&storage);
        const tail = (try store_core.readSessionForTesting(&storage, session.slice())).?.next_position;
        try submitTestMessage(&storage, &tmp, "cost-input", "input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var identities: [20][24]u8 = undefined;
        var calls: [20]TestingCall = undefined;
        for (&calls, &identities, 0..) |*call, *identity, index| {
            const id = try std.fmt.bufPrint(identity, "cost-{d}", .{index});
            call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" };
        }
        try settleCallsForTesting(&storage, &tmp, binding, "cost-calls", &calls);
        var stop = try completeSessionStop("cost-stop", session.slice());
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);

        var opening: protocol.ActivityPage = .{ .direction = .backward };
        try opening.session.set(session.slice());
        cost[0] = try activityPageSteps(&storage, opening);
        const page = try store_core.activityPageForTesting(&storage, opening);
        try std.testing.expect(page.more);
        var forward: protocol.ActivityPage = .{ .end = page.end, .position = tail - 1 };
        try forward.session.set(session.slice());
        cost[1] = try activityPageSteps(&storage, forward);
        const later = try store_core.activityPageForTesting(&storage, forward);
        try std.testing.expect(later.more);
        try std.testing.expectEqual(tail, later.items[0].position);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a one-row page of a person's Messages costs the same steps after 10 or 10,000 received ones" {
    // Ctrl-P from the end passes over every Message another Session sent
    // to reach the person's first one, through their own index.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "recall-config");
        const peer = try configureTestSession(&storage, "recall-peer");
        try submitTestMessage(&storage, &tmp, "recall-first", "first", session.slice(), "first");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+value-1 AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
                "SELECT 1000+value,'{1s}',printf('received-%d',value),content,position,1,'{2s}',value FROM history; " ++
                "UPDATE session SET next_position=next_position+{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice(), peer.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].value == .admission and !page.more);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a forward one-row page of a person's Messages costs the same steps past 10 or 10,000 tool groups" {
    // Ctrl-N from the first Message steps to the second, with every tool
    // group completed between it and the third. The page lists no calls, so it reads no
    // call activity.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "forward-config");
        try submitTestMessage(&storage, &tmp, "forward-first", "first", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "forward-second", "second", session.slice(), "second");
        const first = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(admission_position) FROM message_admission", .{});
        // Foreign keys are off: each tool group names its Turn before the
        // Turn row exists. A cancelled Turn needs no answer content.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT 1000+value AS value,next_position+3*(value-1) AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) " ++
                "SELECT value,value,'{1s}',1,value,position,0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref='{1s}'),0 FROM history; " ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                "SELECT value,0,'{1s}',position,3,1,zeroblob(32),0,content,0 FROM history; " ++
                "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                "SELECT value,'{1s}',0,0,content,content,content,zeroblob(120),'unknown_tool',content,position+1 FROM history; " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'{1s}',value,value,value,'cancelled',position+2,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+3*{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        try submitTestMessage(&storage, &tmp, "forward-third", "third", session.slice(), "third");
        var request: protocol.ActivityPage = .{ .position = first, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].position > first and page.more);
        try std.testing.expectEqual(@as(u64, 0), page.call_activity.total);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a one-row page of a person's Messages costs the same steps past 100 or 10,000 waiting ones" {
    // Ctrl-P from the end reads the newest Message, with every other one
    // still waiting. The page is filtered, so it reads no queue footer.
    // Each Store holds more waiting Messages than a page source reads.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 100, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "waiting-config");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+value-1 AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT 1000+value,'{1s}',printf('waiting-%d',value),content,position,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        // Foreign keys are off: the waiting Messages have no commands.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        try submitTestMessage(&storage, &tmp, "waiting-newest", "newest", session.slice(), "newest");
        var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].value.admission.state == .queued and page.more);
        try std.testing.expectEqual(@as(u64, 0), page.queued.count);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

/// The VM steps every statement of the Store's connection takes to read one
/// Activity page.
fn activityPageSteps(storage: *Store, request: protocol.ActivityPage) !i64 {
    var statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
    while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each))
        _ = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 1);
    _ = try store_core.activityPageForTesting(storage, request);
    var total: i64 = 0;
    statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
    while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each))
        total += c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    return total;
}

test "activity judges every candidate Operation's tool outcomes, not only its kept calls" {
    // The page keeps three calls' presentations; the rule must still reach
    // the fourth call, by one read per Operation while there are at most
    // `max_operations`, 32, and by one read over them all past that.
    for ([_]enum { one_operation, many_operations }{ .one_operation, .many_operations }) |shape| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "outcome-config");
        try submitTestMessage(&storage, &tmp, "outcome-input", "input", session.slice(), "propose");
        switch (shape) {
            .one_operation => {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var calls: [4]TestingCall = undefined;
                var ids: [4][16]u8 = undefined;
                for (&calls, &ids, 0..) |*call, *id_buffer, index| {
                    const id = try std.fmt.bufPrint(id_buffer, "outcome-{d}", .{index});
                    call.* = .{
                        .item_id = id,
                        .name = "bash",
                        .encoded_call_id = id,
                        .decoded_call_id = id,
                        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    };
                }
                try settleCallsForTesting(&storage, &tmp, binding, "outcome-calls", &calls);
            },
            .many_operations => for (0..40) |index| {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var identity: [24]u8 = undefined;
                const id = try std.fmt.bufPrint(&identity, "ops-{d}", .{index});
                var prefix: [24]u8 = undefined;
                const calls = [_]TestingCall{.{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" }};
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "ops-calls-{d}", .{index}), &calls);
            },
        }
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
        try std.testing.expect(page.call_activity.total >= 4);
        // One call each, so as many candidate Operations as calls.
        if (shape == .many_operations) try std.testing.expect(page.call_activity.total > 32);
        // The last candidate call's item stops being a call item; no kept
        // presentation reads that call.
        try store_testing.sqlite_only.exec(&storage, "UPDATE model_output_item SET item_kind=1 WHERE (operation_id,item_ordinal)=" ++
            "(SELECT operation_id,item_ordinal FROM model_tool_call ORDER BY operation_id DESC,call_ordinal DESC LIMIT 1)", .{});
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
        try std.testing.expect(storage.isFenced());
    }
}

test "the tool outcome rule counts an Operation's calls against its call items" {
    // One call's item stops being a call item: every call left is valid
    // and as many as the call items, so only the count of calls differs.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "count-config");
    try submitTestMessage(&storage, &tmp, "count-input", "input", session.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "count-calls");
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_output_item SET item_kind=1 WHERE item_kind=3 AND item_ordinal=" ++
        "(SELECT item_ordinal FROM model_tool_call WHERE call_ordinal=1)", .{});
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
    try std.testing.expect(storage.isFenced());
}

test "the Current report fences an unauthorized Action proposed under bypass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "unauthorized-config");
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("unauthorized-mode");
    try update.session.set(session.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "unauthorized-input", "input", session.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "unauthorized-calls");
    // The CHECK pairs a grant with its decision, so the damage clears both.
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET authorized=0,decided_at=NULL WHERE call_ordinal=1", .{});
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
    try std.testing.expect(storage.isFenced());
}

test "a page of approval requests costs the same however many calls ran without asking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "approval-steps-config");
    try submitTestMessage(&storage, &tmp, "approval-steps-input", "approval-steps-input", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try tests.settleTwoActionsForTesting(&storage, &tmp, binding, "approval-steps-calls");
    var request: protocol.ActivityPage = .{ .kinds = .initOne(.approval_requested) };
    try request.session.set(session.slice());
    const Page = struct {
        fn steps(store: *Store, page_request: protocol.ActivityPage) !u64 {
            // The first read prepares the page's statements.
            _ = try store_core.activityPageForTesting(store, page_request);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            const page = try store_core.activityPageForTesting(store, page_request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            return counter.steps;
        }
        /// `copies` more of the Session's calls and Actions that never
        /// asked: copies of its own, without an approval position.
        fn addBypassed(store: *Store, ref: []const u8, comptime first: u64) !void {
            const sequence = std.fmt.comptimePrint("WITH RECURSIVE sequence(value) AS (VALUES({d}) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) ", .{ first, first + 999 });
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) " ++
                "SELECT operation_id+value*1000,item_ordinal,session_ref,session_position+value*10+1000000,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed " ++
                "FROM model_output_item CROSS JOIN sequence WHERE session_ref=?1 AND item_kind=3 AND operation_id<1000", .{ref});
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,decided_at) " ++
                "SELECT action_id+value*1000,parent_operation_id+value*1000,call_ordinal,session_ref,tool_kind,permission_revision,1,1 FROM action_operation CROSS JOIN sequence WHERE session_ref=?1 AND action_id<1000", .{ref});
        }
    };
    const few = try Page.steps(&storage, request);
    try Page.addBypassed(&storage, session.slice(), 1);
    const thousand = try Page.steps(&storage, request);
    try Page.addBypassed(&storage, session.slice(), 1001);
    try std.testing.expectEqual(@as(u64, 4002), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM action_operation", .{}));
    // A fixed cost: the seek past the bypassed rows is one step, whatever
    // their number.
    try std.testing.expect(thousand - few <= 1);
    try std.testing.expectEqual(thousand, try Page.steps(&storage, request));
}
