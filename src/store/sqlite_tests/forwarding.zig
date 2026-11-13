//! Forwarding SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const testingStore = store_testing.testingSqliteStore;
const TestingSteps = shared_fixtures.TestingSteps;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;
const expectOnlyForwardsThenIdle = shared_fixtures.expectOnlyForwardsThenIdle;

test "K4 ancestor approvals preserve origin and require delivered authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const root = try configureTestSession(&storage, "k4-root");
    const parent = try configureTestSession(&storage, "k4-parent");
    const child = try configureTestSessionAsk(&storage, "k4-child");
    const stranger = try configureTestSession(&storage, "k4-stranger");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), parent.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "k4-input", "k4-input", child.slice(), "propose");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try tests.settleTwoActionsForTesting(&storage, &tmp, model, "k4-calls");
    const own = try store_core.activityPageForTesting(&storage, .{ .session = child, .kinds = .initOne(.approval_requested) });
    try std.testing.expectEqual(@as(usize, 2), own.count);
    const action = own.items[0].value.approval_requested.action;
    for ([_][]const u8{ root.slice(), stranger.slice() }, 0..) |target, i| {
        var denied: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
        try denied.key.set(if (i == 0) "k4-undelivered" else "k4-unrelated");
        try denied.session.set(target);
        const reply = storage.decidePermission(&denied, .{});
        try std.testing.expect(reply == .rejected);
        try std.testing.expectEqual(protocol.PermissionDecisionRejection.target_mismatch, reply.rejected.code);
    }
    try expectOnlyForwardsThenIdle(&storage);
    for ([_]@TypeOf(root){ child, parent, root }) |session| {
        const page = try store_core.activityPageForTesting(&storage, .{ .session = session, .kinds = .initOne(.approval_requested) });
        try std.testing.expectEqual(own.count, page.count);
        for (page.items[0..page.count], own.items[0..own.count]) |actual, expected| {
            try std.testing.expectEqualDeep(expected.value.approval_requested, actual.value.approval_requested);
            try std.testing.expectEqualStrings(child.slice(), actual.value.approval_requested.session.slice());
        }
    }
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
    try allow.key.set("k4-allow");
    try allow.session.set(root.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const replay = storage.decidePermission(&allow, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT authorized FROM action_operation WHERE action_id=?1 AND session_ref=?2", .{ action, child.slice() }));
}

test "K4 ancestor denial positions results in child and continues child turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const root = try configureTestSession(&storage, "k4-root");
    const parent = try configureTestSession(&storage, "k4-parent");
    const child = try configureTestSessionAsk(&storage, "k4-child");
    const stranger = try configureTestSession(&storage, "k4-stranger");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), parent.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "k4-input", "k4-input", child.slice(), "propose");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try tests.settleTwoActionsForTesting(&storage, &tmp, model, "k4-calls");
    const own = try store_core.activityPageForTesting(&storage, .{ .session = child, .kinds = .initOne(.approval_requested) });
    try std.testing.expectEqual(@as(usize, 2), own.count);
    const action = own.items[0].value.approval_requested.action;
    for ([_][]const u8{ root.slice(), stranger.slice() }, 0..) |target, i| {
        var denied: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .deny };
        try denied.key.set(if (i == 0) "k4-undelivered" else "k4-unrelated");
        try denied.session.set(target);
        const reply = storage.decidePermission(&denied, .{});
        try std.testing.expect(reply == .rejected);
        try std.testing.expectEqual(protocol.PermissionDecisionRejection.target_mismatch, reply.rejected.code);
    }
    try expectOnlyForwardsThenIdle(&storage);
    for ([_]@TypeOf(root){ child, parent, root }) |session| {
        const page = try store_core.activityPageForTesting(&storage, .{ .session = session, .kinds = .initOne(.approval_requested) });
        try std.testing.expectEqual(own.count, page.count);
        for (page.items[0..page.count], own.items[0..own.count]) |actual, expected| {
            try std.testing.expectEqualDeep(expected.value.approval_requested, actual.value.approval_requested);
            try std.testing.expectEqualStrings(child.slice(), actual.value.approval_requested.session.slice());
        }
    }
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .deny };
    try allow.key.set("k4-allow");
    try allow.session.set(root.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const replay = storage.decidePermission(&allow, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    const target_statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT target FROM core_command WHERE command_key='k4-allow'");
    defer _ = c.sqlite3_finalize(target_statement);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(target_statement));
    var target: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(target_statement, 0, &target);
    try std.testing.expectEqualStrings(root.slice(), target.slice());
    const second = own.items[1].value.approval_requested.action;
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = second, .decision = .deny };
    try deny.key.set("k4-deny-second");
    try deny.session.set(parent.slice());
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE session_ref=?1 AND resolution_code='denied' AND acceptance_position IS NOT NULL", .{child.slice()}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE session_ref=?1", .{root.slice()}));
    try expectDenseSessionPositions(&storage, child.slice());
    try expectDenseSessionPositions(&storage, parent.slice());
    try expectDenseSessionPositions(&storage, root.slice());
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(model.turn_id, continuation.turn_id);
    try std.testing.expectEqual(model.operation_id + 1, continuation.operation_id);
}

test "K4 ending hops rollback reopen once and never backfill frozen feeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const root = try configureTestSession(&storage, "k4-ending-root");
    const parent = try configureTestSession(&storage, "k4-ending-parent");
    const child = try configureTestSession(&storage, "k4-ending-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), parent.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "k4-ending-input", "k4-ending-input", child.slice(), "answer");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const item = "{\"type\":\"message\",\"id\":\"k4-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"preserved answer\"}]}";
    try settleItemsForTesting(&storage, &tmp, model, &.{item}, "preserved answer");
    const own = try store_core.activityPageForTesting(&storage, .{ .session = child, .kinds = .initOne(.turn_ended) });
    try std.testing.expectEqual(@as(usize, 1), own.count);
    const frozen = try store_core.activityPageForTesting(&storage, .{ .session = root, .kinds = .initOne(.turn_ended) });
    try std.testing.expectEqual(@as(usize, 0), frozen.count);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    const first = (try storage.nextCoreWork()).?.forward;
    try std.testing.expect(try storage.deliverSessionForward(first, .{}));
    const second = (try storage.nextCoreWork()).?.forward;
    try std.testing.expectError(error.InjectedCommitFailure, storage.deliverSessionForward(second, .{ .before_commit = true }));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try std.testing.expectEqual(second, (try storage.nextCoreWork()).?.forward);
    try std.testing.expect(!try storage.deliverSessionForward(first, .{}));
    try std.testing.expect(try storage.deliverSessionForward(second, .{}));
    try std.testing.expect(!try storage.deliverSessionForward(second, .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);
    const prefix = try store_core.activityPageForTesting(&storage, .{ .session = root, .end = frozen.end, .kinds = .initOne(.turn_ended) });
    try std.testing.expectEqual(@as(usize, 0), prefix.count);
    for ([_]@TypeOf(root){ parent, root }) |session| {
        const page = try store_core.activityPageForTesting(&storage, .{ .session = session, .kinds = .initOne(.turn_ended) });
        try std.testing.expectEqual(@as(usize, 1), page.count);
        try std.testing.expectEqualDeep(own.items[0].value.turn_ended, page.items[0].value.turn_ended);
        try std.testing.expectEqualStrings(child.slice(), page.items[0].value.turn_ended.session.slice());
        const location = try storage.openActivityContent(&.{ .session = session, .position = page.items[0].position });
        var reader: ContentReader = undefined;
        reader.open(location);
        defer reader.close();
        var bytes: [64]u8 = undefined;
        const count = try reader.read(0, &bytes);
        try std.testing.expectEqualStrings("preserved answer", bytes[0..count]);
        var search: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.turn_ended) };
        try search.query.set("preserved answer");
        const found = try std.testing.allocator.create(protocol.ActivitySearchFacts);
        defer std.testing.allocator.destroy(found);
        try storage.searchActivity(&search, found);
        try std.testing.expectEqual(@as(usize, 1), found.count);
        try std.testing.expectEqual(page.items[0].position, found.items[0].position);
        try std.testing.expectEqual(page.items[0].ordinal, found.items[0].ordinal);
        try expectDenseSessionPositions(&storage, session.slice());
    }
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_forward WHERE kind=2 AND position IS NOT NULL", .{}));
}

test "K4 forwarded approval hydration steps exclude prior forward history" {
    const Measure = struct {
        fn run(history: u64) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const parent = try configureTestSession(&storage, "k4-cost-parent");
            const child = try configureTestSessionAsk(&storage, "k4-cost-child");
            try submitTestMessage(&storage, &tmp, "k4-cost-input", "k4-cost-input", child.slice(), "propose");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try tests.settleTwoActionsForTesting(&storage, &tmp, model, "k4-cost-calls");
            const start = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{parent.slice()});
            const child_start = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{child.slice()});
            const sequence = "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<?1) ";
            // Copy a complete canonical call group, retaining its content and
            // permission revision but assigning distinct operation identities
            // and child positions. Every forward has a genuine ask Action.
            try store_testing.sqlite_only.exec(&storage, sequence ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,output_item_count,tool_set_id,context_window) " ++
                "SELECT value+1000000,turn_id,session_ref,settings_revision,input_cutoff,?3+3*(value-1),output_reservation,attempt_ordinal,resolution_code,resolved_at,1,tool_set_id,context_window FROM model_operation CROSS JOIN sequence WHERE operation_id=?2", .{ history, model.operation_id, child_start });
            try store_testing.sqlite_only.exec(&storage, sequence ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                "SELECT value+1000000,0,session_ref,?3+3*(value-1)+1,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count FROM model_output_item CROSS JOIN sequence WHERE operation_id=?2 AND item_ordinal=0", .{ history, model.operation_id, child_start });
            try store_testing.sqlite_only.exec(&storage, sequence ++
                "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,action_kind) " ++
                "SELECT value+1000000,session_ref,0,0,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,action_kind FROM model_tool_call CROSS JOIN sequence WHERE operation_id=?2 AND call_ordinal=0", .{ history, model.operation_id });
            try store_testing.sqlite_only.exec(&storage, sequence ++
                "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,approval_position) " ++
                "SELECT value+1000000,value+1000000,0,session_ref,tool_kind,permission_revision,0,?3+3*(value-1)+2 FROM action_operation CROSS JOIN sequence WHERE parent_operation_id=?2 AND call_ordinal=0", .{ history, model.operation_id, child_start });
            try store_testing.sqlite_only.exec(&storage, sequence ++
                "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at) SELECT value,?2,?3,1,value+1000000,?4+value-1,0,1 FROM sequence", .{ history, parent.slice(), child.slice(), start });
            try store_testing.sqlite_only.exec(&storage, "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at) SELECT ?1+call_ordinal+1,?2,session_ref,1,action_id,?3+?1+call_ordinal,0,1 FROM action_operation WHERE parent_operation_id=?4", .{ history, parent.slice(), start, model.operation_id });
            try store_testing.sqlite_only.exec(&storage, "UPDATE session SET next_position=next_position+?1+2 WHERE session_ref=?2", .{ history, parent.slice() });
            try store_testing.sqlite_only.exec(&storage, "UPDATE session SET next_position=next_position+3*?1 WHERE session_ref=?2", .{ history, child.slice() });
            // Observe all synthesized forwards through the production feed
            // before measuring a bounded one-row tail page.
            var verify: protocol.ActivityPage = .{ .session = parent, .kinds = .initOne(.approval_requested) };
            var seen: usize = 0;
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, verify);
                for (page.items[0..page.count]) |row| try std.testing.expectEqualStrings(child.slice(), row.value.approval_requested.session.slice());
                seen += page.count;
                if (!page.more) break;
                const last = page.items[page.count - 1];
                verify.end = page.end;
                verify.position = last.position;
                verify.ordinal = last.ordinal;
            }
            try std.testing.expectEqual(history + 2, seen);
            const request: protocol.ActivityPage = .{ .session = parent, .direction = .backward, .kinds = .initOne(.approval_requested), .limit = 1 };
            _ = try store_core.activityPageForTesting(&storage, request);
            var counter: TestingSteps = .{};
            counter.begin(storage.sqliteDatabase());
            defer counter.end(storage.sqliteDatabase());
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            try std.testing.expectEqualStrings(child.slice(), page.items[0].value.approval_requested.session.slice());
            return counter.steps;
        }
    };
    // Both populations fill the source query's fixed 17-candidate window.
    const small = try Measure.run(32);
    const large = try Measure.run(10_000);
    try std.testing.expect(large <= small + 100);
}

test "K4 malformed delivered approval forwards fence page cursor and direct hydration" {
    // Every route starts with a fresh Store: fencing is sticky by design.
    for (0..3) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const parent = try configureTestSession(&storage, "k4-corrupt-parent");
        const child = try configureTestSessionAsk(&storage, "k4-corrupt-child");
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
        var bypass = try store_testing.completeConfiguration("k4-corrupt-bypass", child.slice(), workspace, "model-a");
        bypass.configuration.permission_mode.state = .value;
        try bypass.configuration.permission_mode.value.set("bypass");
        try std.testing.expect(try storage.configure(&bypass, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "k4-corrupt-input", "k4-corrupt-input", child.slice(), "propose");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try tests.settleTwoActionsForTesting(&storage, &tmp, model, "k4-corrupt-calls");
        const action = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{child.slice()});
        // An auto-authorized call never requested approval. A forged delivered
        // forward cannot turn it into an approval fact on any read route.
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND authorized=1 AND approval_position IS NULL", .{action}));
        const position = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{parent.slice()});
        try store_testing.sqlite_only.exec(&storage, "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at) VALUES(1,?1,?2,1,?3,?4,0,1)", .{ parent.slice(), child.slice(), action, position });
        try store_testing.sqlite_only.exec(&storage, "UPDATE session SET next_position=next_position+1 WHERE session_ref=?1", .{parent.slice()});
        const result: anyerror!void = switch (route) {
            0 => if (store_core.activityPageForTesting(&storage, .{ .session = parent, .kinds = .initOne(.approval_requested) })) |_| {} else |err| err,
            1 => if (store_core.activityPageForTesting(&storage, .{ .session = parent, .position = position, .ordinal = 0 })) |_| {} else |err| err,
            else => if (storage.openActivityContent(&.{ .session = parent, .position = position, .ordinal = 0 })) |_| {} else |err| err,
        };
        try std.testing.expectError(error.CorruptStore, result);
        try std.testing.expect(storage.isFenced());
    }
}
