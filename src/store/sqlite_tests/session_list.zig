//! Session list SQLite mechanism tests.

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
    // Above the Host's next created_seq, which these rows bypass.
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
        "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
        "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
        "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
    // Changing foreign_keys expires prepared statements: prepare them again.
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

        /// Steps for the page, which names only `watched`.
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
    const watched = try Page.configure(&storage, "scoped-watched", "", workspace);
    var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
    try request.workspace.?.set(workspace);
    _ = try Page.configure(&storage, "scoped-watched-again", &watched, workspace);
    const alone = try Page.steps(&storage, &tmp, request, &watched);
    // The rest of the ring: a distinct Session in another Workspace per
    // entry, each changed after the token.
    for (1..change_ring.capacity) |index| {
        var key: [32]u8 = undefined;
        _ = try Page.configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
    }
    try std.testing.expect(storage.changes.covers(request.since.?.generation));
    try std.testing.expectEqual(alone, try Page.steps(&storage, &tmp, request, &watched));
}

test "a list row reads the same steps however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // One Session, measured at two lengths of the same shape: answered
    // Turns, each followed by a queued Message a stop excluded, then a last
    // answered Turn. Alone in the Store, its index probes have the same
    // neighbours both times.
    const Round = struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }
    };
    // The Session is the list's only row, so the page's steps are its row's.
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

/// The position of the person's Message next to `request`'s cursor, on a
/// one-row page of `admission` rows, or null.
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
    // Another Session sent the newest one: it is a received row, not the
    // person's, and every step passes over it.
    try submitTestMessage(&storage, &tmp, "from-peer", "from-peer", session.slice(), "peer");
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000 WHERE command_key='from-peer'", .{peer.slice()});
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
    // Older from each one, then newer back: each step names its neighbour.
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
    // A later Message waits beyond the end it was read at.
    request.end = null;
    request.position = positions[2];
    try std.testing.expect((try personStep(&storage, request)).? > positions[2]);
    // The peer's Message is the page's received row.
    var received: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.received) };
    try received.session.set(session.slice());
    const peers = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(peers.count == 1 and peers.items[0].value == .received);
    try std.testing.expectEqualStrings(peer.slice(), peers.items[0].value.received.sender.?.session.slice());
    // Both kinds read the one admission source, each row once, by its sender.
    received.kinds = .initMany(&.{ .admission, .received });
    const both = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(both.count == 5 and !both.more);
    var counts: [2]usize = .{ 0, 0 };
    for (both.items[0..both.count]) |item| counts[@intFromBool(item.value == .received)] += 1;
    try std.testing.expectEqual([2]usize{ 4, 1 }, counts);
    // A cursor may name the received row; an admission page steps past it.
    received.kinds = .initOne(.admission);
    received.end = both.end;
    received.position = peers.items[0].position;
    received.ordinal = peers.items[0].ordinal;
    const before = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(before.count > 0 and before.items[0].position < peers.items[0].position);
    try std.testing.expect(!storage.isFenced());
}

/// The rendered text of the one statement `session_list_read.list_failures`
/// names `failed` whose text holds `fragment`.
fn listStatementForTesting(comptime failed: anyerror, comptime fragment: []const u8) [:0]const u8 {
    return namedStatementForTesting(session_list_read_domain.list_failures, failed, fragment);
}

/// Fails the statement whose text is `sql` as a one-row list page reads
/// it, and expects `expected`: main's name for that read's failed step.
fn expectListStepFailure(sql: [:0]const u8, expected: anyerror) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // A queued Message: the work reads its latest Turn, then the queue.
    const session = try configureTestSession(&storage, "list-names-config");
    try submitTestMessage(&storage, &tmp, "list-names-input", "list-names-message", session.slice(), "q");
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = sql };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    try std.testing.expectError(expected, testingSessionList(&storage, &tmp, .{}, &used, 5));
    try std.testing.expect(fault.failed > 0);
    try std.testing.expect(storage.isFenced());
}

test "a list page whose page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "FROM session WHERE created_seq>?1"), error.SessionReadFailed);
}

test "a list row whose latest Turn read fails answers main's TurnReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.TurnReadFailed, "SELECT t.turn_id,t.operation_id"), error.TurnReadFailed);
}

test "a list row whose queue read fails answers main's MessageAdmissionReadFailed" {
    try expectListStepFailure(listStatementForTesting(error.MessageAdmissionReadFailed, "admission_id>?2"), error.MessageAdmissionReadFailed);
}

test "a list row whose settings read fails answers SessionReadFailed" {
    // Main named a failed settings step so, and a failed first Message
    // step CorruptStore; this one read holds both.
    try expectListStepFailure(listStatementForTesting(error.SessionReadFailed, "JOIN message_admission m"), error.SessionReadFailed);
}

test "a list row that fails to render reports its error before a later row's failed step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // The first row has no Message and a label no Session may hold; the
    // second has a first Message, so its settings step is `list_row`'s.
    const first = try configureTestSession(&storage, "render-order-first");
    const second = try configureTestSession(&storage, "render-order-second");
    try submitTestMessage(&storage, &tmp, "render-order-input", "render-order-message", second.slice(), "q");
    var update: [160]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&update, "UPDATE session SET label='two'||char(10)||'lines' WHERE session_ref='{s}'", .{first.slice()}, 0));
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = listStatementForTesting(error.SessionReadFailed, "JOIN message_admission m") };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    // Main read and rendered the first row before the second's step.
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
    // The first Turn still names the admission, whose content is gone, so
    // the row's settings read finds no row.
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
    var reply: session_list_reply.Reply(report_domain.SessionReportCapture) = .{ .capture = &capture };
    try session_list_read_domain.readSessionList(&a, &.{}, &reply);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    var bytes: [8192]u8 = undefined;
    const read = try report.read(0, bytes[0..@intCast(@min(report.length, bytes.len))]);
    for ([_][]const u8{ "\"kind\":\"idle\"", "\"kind\":\"finished\"", "\"kind\":\"stopped\"", "\"kind\":\"approval\"" }) |kind|
        std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes[0..read], kind)) catch |err| {
            std.debug.print("{s}\n", .{bytes[0..read]});
            return err;
        };
    // The stopped rows' eight: page, latest/first Message, cutoff, queue,
    // excluded Message, stop, saved frontier, settings. Awaiting rows end
    // after their Actions; other settled rows reach the frontier sooner.
    try std.testing.expectEqual(8, rounds);
    // A pass ends where a round queues a statement again, so a round takes
    // as many as its most repeated statement's rows: 1 for the page, 8 for
    // the rows' first reads, 6 cutoffs, 6 queue seeks, then 4 frontier/excluded
    // seeks, 2 stops, 2 remaining frontier seeks, and 6 settings reads.
    try std.testing.expectEqual(1 + 8 + 6 + 6 + 4 + 2 + 2 + 6, a.passes);
}
