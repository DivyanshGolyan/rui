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
    try std.testing.expectEqual(protocol.contentDigest("three"), page.items[0].value.admission.content.text.digest);
    try std.testing.expectEqual(@as(u64, 5), page.items[0].value.admission.content.text.length);
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

test "a live list page whose active page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "WHERE archive_seq IS NULL AND created_seq>?1"), error.SessionReadFailed, .queued);
}

test "a live list page whose turn candidate page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "IN (SELECT t.session_ref FROM turn t"), error.SessionReadFailed, .queued);
}

test "a live list page whose action candidate page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "IN (SELECT a.session_ref FROM action_operation a"), error.SessionReadFailed, .queued);
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
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "SELECT session.session_ref,session.archive_seq,session.parent_ref"), error.SessionReadFailed, .queued);
}

test "a list page whose settings read fails reports SessionReadFailed before any row renders" {
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
    var fault: TestingStatementFault = .{ .sql = listStatementForTesting(error.SessionReadFailed, "SELECT session.session_ref,session.archive_seq,session.parent_ref") };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    // The settings rows are read in the page's first round, so a failed read there wins over a later row's render error.
    try std.testing.expectError(error.SessionReadFailed, testingSessionList(&storage, &tmp, .{}, &used, 5));
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
    var scratch: session_list_read_domain.Scratch = .{};
    var reply: session_list_reply.Reply(report_domain.SessionReportCapture) = .{ .capture = &capture };
    try session_list_read_domain.readSessionList(&a, &.{}, &scratch, &reply);
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
    try std.testing.expectEqual(7, rounds);
    // One term per round, measured after the settings rows and the creator-subtree page 1 joined the first WorkRead
    // round (was 1 + 1 + 8 + 6 + 6 + 4 + 2 + 2 + 6 over nine rounds).
    try std.testing.expectEqual(8 + 6 + 6 + 4 + 2 + 2 + 1, a.passes);
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
            var scratch: session_list_read_domain.Scratch = .{};
            var reply: session_list_reply.Reply(report_domain.SessionReportCapture) = .{ .capture = &capture };
            try session_list_read_domain.readSessionList(&a, &.{}, &scratch, &reply);
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

test "creating Message replay reads independently of Session history in SQLite steps" {
    const wire_request = @import("../../wire_request.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    const settings = try completeConfiguration("receipt-steps", "", workspace, "model-a");
    var message: wire_request.MessageCommand = .{ .configuration = settings.configuration };
    try message.key.set("receipt-steps");
    message.text = try tests.testingBytesContent(&tmp, "receipt-steps-input", "initial");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    var created_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
    const created = storage.submitMessageWithModelInto(&message, null, &created_receipt, .{});
    try std.testing.expect(created == .accepted);
    const session = created.accepted.session;
    const Counter = struct {
        fn steps(store: *Store, command: *const wire_request.MessageCommand) !u64 {
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            var replay_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            const replay = store.submitMessageWithModelInto(command, null, &replay_receipt, .{});
            counter.end(store.sqliteDatabase());
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            return counter.steps;
        }
    };
    _ = try Counter.steps(&storage, &message);
    const few = try Counter.steps(&storage, &message);
    for (0..64) |index| {
        var key: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "receipt-steps-history-{d}", .{index});
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), "history");
    }
    try std.testing.expect(few > 0);
    try std.testing.expectEqual(few, try Counter.steps(&storage, &message));
}

test "creating configuration receipt replay reads independently of Session history in SQLite steps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    var create = try completeConfiguration("configure-receipt-steps", "", workspace, "model-a");
    var created_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
    const created = try storage.configureInto(&create, &created_receipt, .{});
    try std.testing.expect(created == .accepted and created.accepted.configuration != null);
    const session = created.accepted.session;
    const Counter = struct {
        fn steps(store: *Store, command: *const @import("../../wire_request.zig").ConfigureCommand) !u64 {
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            var result_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            const result = store.configureInto(command, &result_receipt, .{});
            counter.end(store.sqliteDatabase());
            const replay = try result;
            try std.testing.expect(replay == .accepted and replay.accepted.replayed and replay.accepted.configuration != null);
            return counter.steps;
        }
    };
    _ = try Counter.steps(&storage, &create);
    const few = try Counter.steps(&storage, &create);
    for (0..64) |index| {
        var key: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "configure-receipt-steps-history-{d}", .{index});
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), "history");
    }
    for (0..64) |index| {
        var key: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "configure-receipt-steps-revision-{d}", .{index});
        var update = try completeConfiguration(name, session.slice(), workspace, if (index % 2 == 0) "model-b" else "model-a");
        try std.testing.expect((try storage.configure(&update, .{})) == .accepted);
    }
    try std.testing.expect(few > 0);
    try std.testing.expectEqual(few, try Counter.steps(&storage, &create));
}

test "creation receipt rejects stored tool names with empty comma segments" {
    const wire_request = @import("../../wire_request.zig");
    for ([_]bool{ false, true }) |as_message| {
        for ([_][]const u8{ ",bad", "bad,", "bad,,name", "bad,name" }) |invalid| for ([_]bool{ false, true }) |forged_count| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("comma-receipt", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"bash"});
            var message: wire_request.MessageCommand = .{ .configuration = create.configuration };
            try message.key.set("comma-receipt");
            message.text = try tests.testingBytesContent(&tmp, "comma-receipt-input", "initial");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            const session = if (as_message) blk: {
                const result = storage.submitMessageWithModelInto(&message, null, &receipt, .{});
                try std.testing.expect(result == .accepted);
                break :blk result.accepted.session;
            } else blk: {
                const result = try storage.configureInto(&create, &receipt, .{});
                try std.testing.expect(result == .accepted);
                break :blk result.accepted.session;
            };
            const record = try store_testing.sqlite_only.queryU64(&storage, "SELECT tool_record_id FROM tool_set_member WHERE tool_set_id=(SELECT tool_set_id FROM session_revision WHERE session_ref=?1 AND revision=1) AND ordinal=0", .{session.slice()});
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
            try store_testing.sqlite_only.exec(&storage, "UPDATE tool_record SET name=?1 WHERE tool_record_id=?2", .{ invalid, record });
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
            if (forged_count) {
                var apparent_count: u64 = 1;
                for (invalid) |byte| if (byte == ',') {
                    apparent_count += 1;
                };
                try store_testing.sqlite_only.exec(&storage, "UPDATE tool_set SET member_count=?1 WHERE tool_set_id=(SELECT tool_set_id FROM session_revision WHERE session_ref=?2 AND revision=1)", .{ apparent_count, session.slice() });
            }
            if (as_message) {
                try std.testing.expect(storage.submitMessageWithModelInto(&message, null, &receipt, .{}) == .infrastructure_failure);
            } else {
                try std.testing.expect((try storage.configureInto(&create, &receipt, .{})) == .infrastructure_failure);
            }
            try std.testing.expect(storage.isFenced());
        };
    }
}

test "creation receipt corruption work is bounded by ordinal range in SQLite steps" {
    const wire_request = @import("../../wire_request.zig");
    const Run = struct {
        fn steps(as_message: bool, replay: bool, extra: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("ordinal-seed", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"bash"});
            create.configuration.loaded_tools = try .of(&.{"bash"});
            var message: wire_request.MessageCommand = .{ .configuration = create.configuration };
            try message.key.set("ordinal-seed");
            message.text = try tests.testingBytesContent(&tmp, "ordinal-input", "initial");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            const session = if (as_message) blk: {
                const result = storage.submitMessageWithModelInto(&message, null, &receipt, .{});
                try std.testing.expect(result == .accepted);
                break :blk result.accepted.session;
            } else blk: {
                const result = try storage.configureInto(&create, &receipt, .{});
                try std.testing.expect(result == .accepted);
                break :blk result.accepted.session;
            };
            const set = try store_testing.queryU64(&storage, "SELECT tool_set_id FROM session_revision WHERE session_ref=?1 AND revision=1", .{session.slice()});
            const record = try store_testing.queryU64(&storage, "SELECT tool_record_id FROM tool_set_member WHERE tool_set_id=?1 AND ordinal=0", .{set});
            for (0..extra) |index| {
                try store_testing.exec(&storage, "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) VALUES(?1,?2,?3)", .{ set, @as(u64, @intCast(128 + index)), record });
            }
            if (!replay) {
                try create.key.set("ordinal-target");
                try message.key.set("ordinal-target");
            }
            var counter: TestingSteps = .{};
            counter.begin(storage.sqliteDatabase());
            const failed = if (as_message)
                storage.submitMessageWithModelInto(&message, null, &receipt, .{}) == .infrastructure_failure
            else
                (try storage.configureInto(&create, &receipt, .{})) == .infrastructure_failure;
            counter.end(storage.sqliteDatabase());
            try std.testing.expect(failed and storage.isFenced());
            return counter.steps;
        }
    };
    for ([_]bool{ false, true }) |as_message| {
        for ([_]bool{ false, true }) |replay| {
            const few = try Run.steps(as_message, replay, 1);
            const many = try Run.steps(as_message, replay, 1024);
            try std.testing.expect(few > 0);
            try std.testing.expectEqual(few, many);
        }
    }
}
