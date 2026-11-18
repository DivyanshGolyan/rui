const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const session_list_read_domain = @import("../domain/session_list_read.zig");
const session_list_reply = @import("../../session_list_reply.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingListing = tests.TestingListing;
const TestingWorkShape = tests.TestingWorkShape;
const completeSessionStop = tests.completeSessionStop;
const namedStatementForTesting = tests.namedStatementForTesting;
const testingListRow = tests.testingListRow;
const testingSessionList = tests.testingSessionList;
const touchForTesting = tests.touchForTesting;
const testingStore = store_testing.testingSqliteStore;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const TestingSteps = shared_fixtures.TestingSteps;

test "creating a Session takes the same work however many Sessions exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Creation = struct {
        fn steps(store: *Store, key: []const u8) !u64 {
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            _ = try configureTestSession(store, key);
            return counter.steps;
        }
    };
    _ = try configureTestSession(&storage, "creation-steps-prepare");
    const few = try Creation.steps(&storage, "creation-steps-few");
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
        "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
        "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
        "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
    _ = try configureTestSession(&storage, "creation-steps-prepare-again");
    try std.testing.expectEqual(few, try Creation.steps(&storage, "creation-steps-many"));
}

test "a Workspace's changed page reads only its own Sessions, however many others changed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
    defer nested.close(std.testing.io);
    var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
    const Page = struct {
        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = try store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
        }

        fn steps(store: *Store, dir: *std.testing.TmpDir, request: protocol.ListSessions, watched: *const change_ring.Id) !u64 {
            _ = try TestingListing.read(store, dir, request);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            const page = try TestingListing.read(store, dir, request);
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try page.expectReferences(&.{watched.*});
            try std.testing.expect(page.next == null);
            return counter.steps;
        }
    };
    // Keep the workspace index boundary present in both measurements. Otherwise
    // adding the first larger digest can change the final index-iteration step.
    var boundary_index: usize = 0;
    while (true) : (boundary_index += 1) {
        var name: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "workspace-boundary-{d}", .{boundary_index});
        var boundary = try tmp.dir.createDirPathOpen(std.testing.io, path, .{});
        var boundary_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const boundary_path = boundary_buffer[0..try boundary.realPath(std.testing.io, &boundary_buffer)];
        boundary.close(std.testing.io);
        const boundary_digest = store_core.workspaceDigest(boundary_path);
        const watched_digest = store_core.workspaceDigest(workspace);
        if (std.mem.order(u8, &boundary_digest, &watched_digest) != .gt) continue;
        _ = try Page.configure(&storage, "scoped-boundary", "", boundary_path);
        break;
    }
    const watched = try Page.configure(&storage, "scoped-watched", "", workspace);
    var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
    try request.workspace.?.set(workspace);
    _ = try Page.configure(&storage, "scoped-watched-again", &watched, workspace);
    const alone = try Page.steps(&storage, &tmp, request, &watched);
    for (1..change_ring.capacity) |index| {
        var key: [32]u8 = undefined;
        _ = try Page.configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
    }
    try std.testing.expect(storage.changes.covers(request.since.?.generation));
    try std.testing.expectEqual(alone, try Page.steps(&storage, &tmp, request, &watched));
}

test "SL-2: a fixed creator subtree skips unrelated Sessions in its Workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    _ = try configureTestSession(&storage, "creator-cost-sentinel");
    const root = try configureTestSession(&storage, "creator-cost-root");
    const child = try configureTestSession(&storage, "creator-cost-child");
    const grandchild = try configureTestSession(&storage, "creator-cost-grandchild");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
    const request: protocol.ListSessions = .{ .after = 1, .ceiling = 4 };
    const Facts = struct { own: u64, subtree: u64, descendants: u64, needs_you: u64 };
    const Measure = struct {
        fn run(store: *Store, dir: *std.testing.TmpDir, list: protocol.ListSessions, ids: [3][]const u8) !struct { steps: u64, facts: [3]Facts } {
            var used = std.atomic.Value(u64).init(0);
            std.testing.allocator.free(try testingSessionList(store, dir, list, &used, 101));
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            const bytes = testingSessionList(store, dir, list, &used, 102) catch |err| {
                counter.end(store.sqliteDatabase());
                return err;
            };
            counter.end(store.sqliteDatabase());
            defer std.testing.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            const rows = parsed.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 3), rows.len);
            var facts: [3]Facts = undefined;
            for (rows, ids, &facts, 0..) |row, id, *fact, index| {
                try std.testing.expectEqualStrings(id, row.object.get("reference").?.string);
                fact.* = .{
                    .own = try std.fmt.parseInt(u64, row.object.get("state_change_at").?.string, 10),
                    .subtree = try std.fmt.parseInt(u64, row.object.get("subtree_state_change_at").?.string, 10),
                    .descendants = try std.fmt.parseInt(u64, row.object.get("descendant_count").?.string, 10),
                    .needs_you = try std.fmt.parseInt(u64, row.object.get("descendant_needs_you_count").?.string, 10),
                };
                try std.testing.expect(fact.own > 0 and fact.subtree >= fact.own);
                try std.testing.expectEqual(@as(u64, 2 - index), fact.descendants);
                try std.testing.expectEqual(@as(u64, 0), fact.needs_you);
            }
            return .{ .steps = counter.steps, .facts = facts };
        }
    };
    const ids = [3][]const u8{ root.slice(), child.slice(), grandchild.slice() };
    const before = try Measure.run(&storage, &tmp, request, ids);
    for (0..128) |index| {
        var key: [48]u8 = undefined;
        _ = try configureTestSession(&storage, try std.fmt.bufPrint(&key, "creator-cost-peer-{d}", .{index}));
    }
    const after = try Measure.run(&storage, &tmp, request, ids);
    try std.testing.expectEqualDeep(before.facts, after.facts);
    std.debug.print("fixed creator subtree SQLite VM steps: before={d} after={d} peers=128\n", .{ before.steps, after.steps });
    try std.testing.expect(after.steps <= before.steps + 100);
}

test "a list row reads the same steps however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Round = struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }
    };
    const Counter = struct {
        fn rowSteps(store: *Store, dir: *std.testing.TmpDir, session: []const u8) !u64 {
            var used = std.atomic.Value(u64).init(0);
            std.testing.allocator.free(try testingSessionList(store, dir, .{}, &used, 78));
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            const bytes = testingSessionList(store, dir, .{}, &used, 79);
            counter.end(store.sqliteDatabase());
            std.testing.allocator.free(try bytes);
            var listed = try testingListRow(store, dir, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings("finished", listed.get(&.{ "work", "state", "kind" }).string);
            try std.testing.expect(listed.get(&.{"first_message"}) != .null);
            return counter.steps;
        }
    };
    const session = try configureTestSession(&storage, "row-steps");
    try Round.run(&storage, &tmp, session.slice(), "row-steps-0");
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-short", &Round.answer);
    const short = try Counter.rowSteps(&storage, &tmp, session.slice());
    inline for (1..33) |round| try Round.run(&storage, &tmp, session.slice(), std.fmt.comptimePrint("row-steps-{d}", .{round}));
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-long", &Round.answer);
    try std.testing.expect(short > 0);
    try std.testing.expectEqual(short, try Counter.rowSteps(&storage, &tmp, session.slice()));
}

fn personStep(storage: *Store, request: protocol.ActivityPage) !?u64 {
    const page = try store_core.activityPageForTesting(storage, request);
    if (page.count == 0) return null;
    try std.testing.expect(page.count == 1 and page.items[0].value == .admission);
    return page.items[0].position;
}

test "a person's Message next to a position is a one-row page of admission rows, at a fixed end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "person-config");
    const peer = try configureTestSession(&storage, "person-peer");
    var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
    try request.session.set(session.slice());
    try std.testing.expectEqual(@as(?u64, null), try personStep(&storage, request));
    for ([_][]const u8{ "one", "two", "three" }) |text| try submitTestMessage(&storage, &tmp, text, text, session.slice(), text);
    try submitTestMessage(&storage, &tmp, "from-peer", "from-peer", session.slice(), "peer");
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000,source_kind=2 WHERE command_key='from-peer'", .{peer.slice()});
        try touchForTesting(&storage, session.slice());
        try touchForTesting(&storage, peer.slice());
    }
    var positions: [3]u64 = undefined;
    inline for (0..3) |index| positions[index] = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), std.fmt.comptimePrint("SELECT admission_position FROM message_admission WHERE sender_session_ref IS NULL ORDER BY admission_id LIMIT 1 OFFSET {d}", .{index}), .{});
    const page = try store_core.activityPageForTesting(&storage, request);
    try std.testing.expect(page.more);
    try std.testing.expectEqual(positions[2], page.items[0].position);
    try std.testing.expectEqual(protocol.contentDigest("three"), page.items[0].value.admission.content.digest);
    try std.testing.expectEqual(@as(u64, 5), page.items[0].value.admission.content.length);
    request.end = page.end;
    for ([_]?u64{ positions[1], positions[0], null }, [_]u64{ positions[2], positions[1], positions[0] }) |expected, from| {
        request.position = from;
        try std.testing.expectEqual(expected, try personStep(&storage, request));
    }
    request.direction = .forward;
    try submitTestMessage(&storage, &tmp, "four", "four", session.slice(), "four");
    for ([_]?u64{ positions[1], positions[2], null }, positions) |expected, from| {
        request.position = from;
        try std.testing.expectEqual(expected, try personStep(&storage, request));
    }
    request.end = null;
    request.position = positions[2];
    try std.testing.expect((try personStep(&storage, request)).? > positions[2]);
    var received: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.received) };
    try received.session.set(session.slice());
    const peers = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(peers.count == 1 and peers.items[0].value == .received);
    try std.testing.expectEqualStrings(peer.slice(), peers.items[0].value.received.sender.?.session.slice());
    received.kinds = .initMany(&.{ .admission, .received });
    const both = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(both.count == 5 and !both.more);
    var counts: [2]usize = .{ 0, 0 };
    for (both.items[0..both.count]) |item| counts[@intFromBool(item.value == .received)] += 1;
    try std.testing.expectEqual([2]usize{ 4, 1 }, counts);
    received.kinds = .initOne(.admission);
    received.end = both.end;
    received.position = peers.items[0].position;
    received.ordinal = peers.items[0].ordinal;
    const before = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(before.count > 0 and before.items[0].position < peers.items[0].position);
    try std.testing.expect(!storage.isFenced());
}

fn listStatementForTesting(comptime failed: anyerror, comptime fragment: []const u8) [:0]const u8 {
    return namedStatementForTesting(session_list_read_domain.list_failures, failed, fragment);
}

fn expectListStepFailure(sql: [:0]const u8, expected: anyerror, comptime work: enum { queued, awaiting }) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    switch (work) {
        .queued => {
            const session = try configureTestSession(&storage, "list-names-config");
            try submitTestMessage(&storage, &tmp, "list-names-input", "list-names-message", session.slice(), "q");
        },
        .awaiting => _ = try TestingWorkShape.awaiting.make(&storage, &tmp, "list-names-awaiting"),
    }
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = sql };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    try std.testing.expectError(expected, testingSessionList(&storage, &tmp, .{}, &used, 5));
    try std.testing.expect(fault.failed > 0);
    try std.testing.expect(storage.isFenced());
}

test "a list page whose page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "FROM session WHERE created_seq>?1"), error.SessionReadFailed, .queued);
}

test "a list row whose Action statement fails answers ActionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.ActionReadFailed, "FROM action_operation a LEFT JOIN session_revision"), error.ActionReadFailed, .awaiting);
}

test "a list row whose latest Turn read fails answers main's TurnReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.TurnReadFailed, "SELECT t.turn_id,t.operation_id"), error.TurnReadFailed, .queued);
}

test "a list row whose queue read fails answers main's MessageAdmissionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.MessageAdmissionReadFailed, "admission_id>?2"), error.MessageAdmissionReadFailed, .queued);
}

test "a list row whose settings read fails answers SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "JOIN message_admission m ON m.admission_id=?3 AND m.session_ref=session.session_ref"), error.SessionReadFailed, .queued);
}

test "a list row that fails to render reports its error before a later row's failed step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const first = try configureTestSession(&storage, "render-order-first");
    const second = try configureTestSession(&storage, "render-order-second");
    try submitTestMessage(&storage, &tmp, "render-order-input", "render-order-message", second.slice(), "q");
    var update: [160]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&update, "UPDATE session SET label='two'||char(10)||'lines' WHERE session_ref='{s}'", .{first.slice()}, 0));
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = listStatementForTesting(error.SessionReadFailed, "JOIN message_admission m ON m.admission_id=?3 AND m.session_ref=session.session_ref") };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 5));
    try std.testing.expect(fault.failed > 0);
}

test "a list row whose first Message is missing is CorruptStore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "missing-first-config");
    try submitTestMessage(&storage, &tmp, "missing-first-input", "missing-first-message", session.slice(), "q");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "DELETE FROM content WHERE content_id IN (SELECT content_id FROM message_admission WHERE session_ref=?1)", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    var used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 5));
}

test "a list row rejects a latest Turn missing its execution entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "clock-missing-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    try answerTestTurn(&storage, &tmp, session.slice(), "clock-missing-first", &answer);
    try answerTestTurn(&storage, &tmp, session.slice(), "clock-missing-latest", &answer);
    try store_testing.sqlite_only.exec(&storage, "DELETE FROM conversation_entry WHERE source_admission_id=(SELECT first_admission_id FROM turn WHERE session_ref=?1 ORDER BY turn_id DESC LIMIT 1)", .{session.slice()});
    var used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 5));
}

test "list clock includes queued input after a finished Turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "clock-queue-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    try answerTestTurn(&storage, &tmp, session.slice(), "clock-queue-done", &answer);
    try submitTestMessage(&storage, &tmp, "clock-queue-input", "clock-queue-key", session.slice(), "next");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.exec(&storage, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
    try store_testing.sqlite_only.exec(&storage, "UPDATE turn SET outcome_at=200 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET admitted_at=300 WHERE command_key='clock-queue-key'", .{});
    var listed = try testingListRow(&storage, &tmp, session.slice());
    defer listed.deinit();
    try std.testing.expectEqualStrings("pending", listed.get(&.{ "work", "state", "kind" }).string);
    try std.testing.expectEqual(@as(u64, 300), try listed.number(&.{"state_change_at"}));
}

test "list clock records the last permission at a distinct durable time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "clock-controlled-config");
    try submitTestMessage(&storage, &tmp, "clock-controlled-input", "clock-controlled-message", session.slice(), "propose");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try tests.settleTwoActionsForTesting(&storage, &tmp, model, "clock-controlled-tools");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.exec(&storage, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET resolved_at=200 WHERE session_ref=?1 AND resolved_at IS NOT NULL", .{session.slice()});
    const first = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
    const second = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = first, .decision = .allow_once };
    try allow.key.set("clock-controlled-first");
    try allow.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET decided_at=300 WHERE action_id=?1", .{first});
    var partial = try testingListRow(&storage, &tmp, session.slice());
    defer partial.deinit();
    try std.testing.expectEqual(@as(u64, 200), try partial.number(&.{"state_change_at"}));
    allow.action_id = second;
    try allow.key.set("clock-controlled-second");
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET decided_at=400 WHERE action_id=?1", .{second});
    var completed = try testingListRow(&storage, &tmp, session.slice());
    defer completed.deinit();
    try std.testing.expectEqual(@as(u64, 400), try completed.number(&.{"state_change_at"}));
}

test "a list page of mixed work takes its deepest row's rounds, and a pass per row a statement repeats for" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    inline for (0..protocol.session_list_page_size) |index| {
        const shape: TestingWorkShape = @fromBackingInt(@intCast(index % 4));
        _ = try shape.make(&storage, &tmp, std.fmt.comptimePrint("mixed-rounds-{d}", .{index}));
    }
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
    try capture.create(root[0..length], 1, false);
    defer capture.deinit();
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: reads_domain.ReadAccess = .open(&entry);
    defer a.deinit();
    const before = storage.testing_content_work.rounds;
    var reply: session_list_reply.Reply(report_domain.SessionReportCapture) = .{ .capture = &capture };
    try session_list_read_domain.readSessionList(&a, &.{}, &reply);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    var bytes: [8192]u8 = undefined;
    const read = try report.read(0, bytes[0..@intCast(@min(report.length, bytes.len))]);
    for ([_][]const u8{ "\"state\":{\"kind\":\"idle\"", "\"state\":{\"kind\":\"finished\"", "\"state\":{\"kind\":\"stopped\"", "\"state\":{\"kind\":\"approval\"" }) |kind|
        std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes[0..read], kind)) catch |err| {
            std.debug.print("{s}\n", .{bytes[0..read]});
            return err;
        };
    try std.testing.expectEqual(9, rounds);
    try std.testing.expectEqual(1 + 1 + 8 + 6 + 6 + 4 + 2 + 2 + 6, a.passes);
}

test "a stopping Turn with queued work adds no list read rounds or passes" {
    const Costs = struct {
        fn read(storage: *Store, tmp: *std.testing.TmpDir) !struct { rounds: u32, passes: usize } {
            var root: [protocol.max_store_bytes]u8 = undefined;
            const length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
            try capture.create(root[0..length], 1, false);
            defer capture.deinit();
            const entry = try store_core.enter(storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            const before = storage.testing_content_work.rounds;
            var reply: session_list_reply.Reply(report_domain.SessionReportCapture) = .{ .capture = &capture };
            try session_list_read_domain.readSessionList(&a, &.{}, &reply);
            return .{ .rounds = storage.testing_content_work.rounds - before, .passes = a.passes };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try TestingWorkShape.awaiting.make(&storage, &tmp, "stopping-list-cost");
    const action = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
    var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
    try allow.key.set("stopping-list-allow");
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    _ = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?;
    const running = try Costs.read(&storage, &tmp);
    var stop = try completeSessionStop("stopping-list-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stopping-list-file", "stopping-list-queued", session.slice(), "new work");
    const stopping = try Costs.read(&storage, &tmp);
    try std.testing.expectEqual(running.rounds, stopping.rounds);
    try std.testing.expectEqual(running.passes, stopping.passes);
    const request: protocol.ActivityPage = .{ .session = session };
    const work = (try store_core.activityPageForTesting(&storage, request)).work.work;
    try std.testing.expect(work.state == .stopping and work.actions.stop);
}
