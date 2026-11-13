//! Obligation Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const store_testing = @import("../testing.zig");
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingListing = shared_fixtures.TestingListing;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectOneWork = shared_fixtures.expectOneWork;
const refreshFrontierForTesting = shared_fixtures.refreshFrontierForTesting;
const refreshFrontiersForTesting = shared_fixtures.refreshFrontiersForTesting;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingIdLess = shared_fixtures.testingIdLess;
const testingListRow = shared_fixtures.testingListRow;

test "obligation projection recomputes a dirty forest together in either head order" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |reverse| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const root = try configureTestSession(&storage, "forest-root");
                const left = try configureTestSession(&storage, "forest-left");
                const right = try configureTestSession(&storage, "forest-right");
                const separate = try configureTestSession(&storage, "forest-separate");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref IN (?2,?3)", .{ root.slice(), left.slice(), right.slice() });
                try submitTestMessage(&storage, &tmp, "forest-left", "forest-left-task", left.slice(), "left");
                try submitTestMessage(&storage, &tmp, "forest-right", "forest-right-task", right.slice(), "right");
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 100), left.slice() });
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 50), right.slice() });
                try refreshFrontiersForTesting(&storage, &.{ left.slice(), right.slice() });
                // Both dirty descendants retain older saved keys. Reusing either
                // key while projecting their common ancestor gives the wrong min.
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 300), left.slice() });
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 200), right.slice() });
                const before = storage.testing_content_work.rounds;
                if (reverse) {
                    try refreshFrontiersForTesting(&storage, &.{ separate.slice(), root.slice(), right.slice(), left.slice() });
                } else {
                    try refreshFrontiersForTesting(&storage, &.{ left.slice(), right.slice(), root.slice(), separate.slice() });
                }
                if (!case.rerun) try std.testing.expectEqual(@as(u32, 2), storage.testing_content_work.rounds - before);
                try std.testing.expectEqual(@as(u64, 200), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{root.slice()}));
                try std.testing.expectEqual(@as(u64, 300), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{left.slice()}));
                try std.testing.expectEqual(@as(u64, 200), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{right.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND obligation_since IS NOT NULL", .{separate.slice()}));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "obligation projection rejects a cyclic component even alongside a rooted component" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |three_node| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const root = try configureTestSession(&storage, "cycle-root");
                const left = try configureTestSession(&storage, "cycle-left");
                const right = try configureTestSession(&storage, "cycle-right");
                const extra = try configureTestSession(&storage, "cycle-extra");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ right.slice(), left.slice() });
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ if (three_node) extra.slice() else left.slice(), right.slice() });
                if (three_node) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ left.slice(), extra.slice() });
                if (refreshFrontiersForTesting(&storage, &.{ root.slice(), left.slice() })) |_| {
                    return error.TestUnexpectedResult;
                } else |_| {}
                try std.testing.expect(storage.isFenced());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE obligation_since IS NOT NULL", .{}));
            }
        }
    }.run);
}

test "Session work includes only attached descendants with unfinished work" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Descendant = enum { absent, working, approval, grandchild, finished, standalone, queued, excluded };
            inline for (std.enums.values(Descendant)) |descendant| {
                for ([_]bool{ false, true }) |root_finished| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const root = try configureTestSession(&storage, "tree-root");
                    _ = try expectOneWork(&storage, &tmp, root.slice(), "idle");
                    if (root_finished) {
                        const answer = [_]TestingAnswerPart{.{ .encoded = "root done", .decoded = "root done" }};
                        try answerTestTurn(&storage, &tmp, root.slice(), "tree-root-answer", &answer);
                    }
                    if (descendant != .absent) {
                        const child = try configureTestSessionAsk(&storage, "tree-child");
                        if (descendant != .standalone) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
                        const target = if (descendant == .grandchild) grandchild: {
                            const grandchild = try configureTestSession(&storage, "tree-grandchild");
                            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
                            break :grandchild grandchild;
                        } else child;
                        if (descendant == .finished) {
                            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                            try answerTestTurn(&storage, &tmp, target.slice(), "tree-answer", &answer);
                        } else {
                            try submitTestMessage(&storage, &tmp, "tree-task", "tree-message", target.slice(), "work");
                            if (descendant == .excluded) {
                                var stop = try completeSessionStop("tree-stop", target.slice());
                                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                            } else if (descendant != .queued) {
                                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                                if (descendant == .approval) try settleTwoActionsForTesting(&storage, &tmp, model, "tree-actions");
                            }
                        }
                    }
                    const busy = switch (descendant) {
                        .working, .approval, .grandchild, .queued, .finished => true,
                        .absent, .standalone, .excluded => false,
                    };
                    _ = try expectOneWork(&storage, &tmp, root.slice(), if (busy) "working" else if (root_finished) "finished" else "idle");
                    try std.testing.expect(!storage.isFenced());
                }
            }
        }
    }.run);
}

test "descendant changes invalidate ancestor tokens without invalidating standalone starters" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Shape = enum { child, grandchild, standalone };
            inline for (std.enums.values(Shape)) |shape| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("invalidate-root", "", workspace, "model-a");
                create.configuration.tools = try .of(&.{"start_agent"});
                const root = (try storage.configure(&create, .{})).accepted.session;
                const child = if (shape == .standalone) standalone: {
                    // A real standalone start retains its starter in the first
                    // Message, but deliberately saves no parent attachment.
                    try submitTestMessage(&storage, &tmp, "starter-file", "starter-message", root.slice(), "start independently");
                    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCallsForTesting(&storage, &tmp, model, "starter-call", &.{.{
                        .item_id = "starter-item",
                        .name = "start_agent",
                        .encoded_call_id = "starter-call",
                        .decoded_call_id = "starter-call",
                        .encoded_arguments = "{}",
                        .decoded_arguments = "{}",
                    }});
                    const action = (try storage.nextCoreWork()).?.action;
                    var spec = try testingAgentSpec(&.{}, "ask");
                    try std.testing.expect(try storage.startAgent(action.binding, root.slice(), "independent work", false, &spec, null, .{}) == .started);
                    const sessions = try TestingListing.read(&storage, &tmp, .{});
                    try std.testing.expectEqual(@as(usize, 2), sessions.count);
                    var agent: protocol.Bounded(protocol.max_session_bytes) = .{};
                    for (sessions.references[0..sessions.count]) |*ref| {
                        if (!std.mem.eql(u8, ref, root.slice())) try agent.set(ref);
                    }
                    var child_stop = try completeSessionStop("starter-child-stop", agent.slice());
                    try std.testing.expect(storage.stopSession(&child_stop, .{}) == .accepted);
                    var root_stop = try completeSessionStop("starter-root-stop", root.slice());
                    try std.testing.expect(storage.stopSession(&root_stop, .{}) == .accepted);
                    break :standalone agent;
                } else try configureTestSession(&storage, "invalidate-child");
                const unrelated = try configureTestSession(&storage, "invalidate-unrelated");
                if (shape != .standalone) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
                const target = if (shape == .grandchild) grandchild: {
                    const grandchild = try configureTestSession(&storage, "invalidate-grandchild");
                    try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
                    break :grandchild grandchild;
                } else child;
                var request: protocol.ActivityPage = .{};
                try request.session.set(root.slice());
                var page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&request, &page);
                var token = page.token.?;
                var listing = try TestingListing.read(&storage, &tmp, .{});
                var observed: store_core.Observed = undefined;
                try storage.observeCommand("invalidate-root", null, &observed);
                var observation_token = observed.full.token.?;
                var unrelated_request: protocol.ActivityPage = .{};
                try unrelated_request.session.set(unrelated.slice());
                var unrelated_page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&unrelated_request, &unrelated_page);
                unrelated_request.since = unrelated_page.token.?;
                unrelated_request.position = unrelated_page.end;

                // Admission/stop only: no ending or forwarded event can touch
                // root incidentally. A second admission leaves the earliest
                // frontier time unchanged but still invalidates every ancestor.
                for (0..3) |phase| {
                    const queued = phase != 2;
                    request.position = page.end;
                    request.since = token;
                    if (queued) {
                        try submitTestMessage(&storage, &tmp, if (phase == 0) "invalidate-file" else "invalidate-more-file", if (phase == 0) "invalidate-message" else "invalidate-more", target.slice(), "queued");
                    } else {
                        var stop = try completeSessionStop("invalidate-stop", target.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    }
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1", .{target.slice()}));
                    try storage.activityPage(&request, &page);
                    try std.testing.expectEqual(shape == .standalone, page.not_modified);
                    const kind = if (shape == .standalone) "stopped" else if (queued) "working" else "idle";
                    if (!page.not_modified) try std.testing.expectEqualStrings(kind, @tagName(page.work.work.state));
                    token = page.token.?;
                    try storage.observeCommand("invalidate-root", observation_token, &observed);
                    try std.testing.expectEqual(shape == .standalone, observed == .not_modified);
                    observation_token = if (observed == .full) observed.full.token.? else observed.not_modified;
                    const changed = try TestingListing.read(&storage, &tmp, .{ .since = listing.since });
                    try std.testing.expectEqual(protocol.ListDelta.changed, changed.delta);
                    var expected: [3]change_ring.Id = undefined;
                    var count: usize = 0;
                    expected[count] = target.slice()[0..protocol.session_id_bytes].*;
                    count += 1;
                    if (shape != .standalone) {
                        expected[count] = root.slice()[0..protocol.session_id_bytes].*;
                        count += 1;
                    }
                    if (shape == .grandchild) {
                        expected[count] = child.slice()[0..protocol.session_id_bytes].*;
                        count += 1;
                    }
                    std.mem.sort(change_ring.Id, expected[0..count], {}, testingIdLess);
                    try changed.expectReferences(expected[0..count]);
                    listing = changed;
                    // Current never short-circuits, and must agree with the
                    // refreshed Activity footer even when no own row changed.
                    _ = try expectOneWork(&storage, &tmp, root.slice(), kind);
                    var row = try testingListRow(&storage, &tmp, root.slice());
                    defer row.deinit();
                    try std.testing.expectEqualStrings(kind, row.get(&.{ "work", "state", "kind" }).string);
                    try storage.activityPage(&unrelated_request, &unrelated_page);
                    try std.testing.expect(unrelated_page.not_modified);
                    try std.testing.expect(!storage.isFenced());
                }
            }
        }
    }.run);
}

test "obligation frontier spans ending feed and Message transfers in either order" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            const Ending = enum { normal, quiet, stopped };
            inline for (std.enums.values(Ending)) |ending| {
                for ([_]bool{ false, true }) |multi_hop| {
                    for ([_]bool{ false, true }) |message_first| {
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        var storage: Store = undefined;
                        try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                        var opened = true;
                        defer if (opened) storage.close() catch unreachable;
                        const root = try configureTestSession(&storage, "owed-root");
                        try answerTestTurn(&storage, &tmp, root.slice(), "owed-root-answer", &.{.{ .encoded = "root done", .decoded = "root done" }});
                        const parent = if (multi_hop) middle: {
                            const middle = try configureTestSession(&storage, "owed-middle");
                            try answerTestTurn(&storage, &tmp, middle.slice(), "owed-middle-answer", &.{.{ .encoded = "middle done", .decoded = "middle done" }});
                            // Seed topology, not owed rows: all obligations below
                            // are driven by production admission and delivery.
                            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), middle.slice() });
                            break :middle middle;
                        } else root;
                        const child = try configureTestSession(&storage, "owed-child");
                        try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                        const baseline = try store_core.activityPageForTesting(&storage, .{ .session = root });
                        const own_turn = baseline.work.work.turn.?;
                        try submitTestMessage(&storage, &tmp, "owed-task", "owed-message", child.slice(), "answer");
                        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                        if (ending == .normal) {
                            try settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"child done\"}]}"}, "child done");
                        } else {
                            var stop = try completeSessionStop("owed-stop", if (ending == .quiet) parent.slice() else child.slice());
                            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                            if (ending == .quiet) {
                                const owed = (try storage.nextCoreWork()).?.stop;
                                var child_stop: protocol.SessionStopCommand = .{ .key = owed.key, .session = child };
                                try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
                            }
                        }
                        // The exact missed observation: no child rows have landed,
                        // its own Turn is finished, yet the server owns owed work.
                        const between = try store_core.activityPageForTesting(&storage, .{ .session = root, .position = baseline.end, .kinds = if (ending == .quiet) .initOne(.turn_ended) else .full });
                        try std.testing.expectEqual(@as(usize, 0), between.count);
                        try std.testing.expect(between.work.work.state == .working);
                        try std.testing.expectEqual(own_turn, between.work.work.turn.?);
                        try store_testing.stageObligationUpgrade(&storage);
                        try storage.close();
                        opened = false;
                        try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                        opened = true;
                        _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                        if (message_first) {
                            try std.testing.expect(try storage.deliverChildEnding(model.turn_id, .{}));
                            try std.testing.expect(!try storage.deliverChildEnding(model.turn_id, .{}));
                        }
                        for (0..@as(usize, if (multi_hop) 2 else 1)) |_| {
                            const expected = if (message_first and ending != .quiet and !multi_hop) "pending" else "working";
                            _ = try expectOneWork(&storage, &tmp, root.slice(), expected);
                            const forward = try store_testing.queryU64(&storage, "SELECT forward_id FROM session_forward WHERE source_id=?1 AND kind=2 AND position IS NULL ORDER BY forward_id LIMIT 1", .{model.turn_id});
                            try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
                            try std.testing.expect(!try storage.deliverSessionForward(forward, .{}));
                        }
                        const landed = try store_core.activityPageForTesting(&storage, .{ .session = root, .position = baseline.end, .kinds = .initOne(.turn_ended) });
                        try std.testing.expectEqual(@as(usize, 1), landed.count);
                        try std.testing.expectEqualStrings(child.slice(), landed.items[0].value.turn_ended.session.slice());
                        if (!message_first) {
                            // A positioned ending is not completion of its owed
                            // Message, including when the Message will be quiet.
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            // Backfill must also retain a Message-only duty after
                            // every forwarded ending has already been positioned.
                            try store_testing.stageObligationUpgrade(&storage);
                            try storage.close();
                            opened = false;
                            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                            opened = true;
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            try std.testing.expect(try storage.deliverChildEnding(model.turn_id, .{}));
                        }
                        if (ending == .quiet) {
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "finished");
                            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE obligation_since IS NOT NULL", .{}));
                        } else {
                            _ = try expectOneWork(&storage, &tmp, root.slice(), if (multi_hop) "working" else "pending");
                            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND session_ref=?2 AND outcome_code IS NULL", .{ next.turn_id, parent.slice() }));
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            const working = try store_core.activityPageForTesting(&storage, .{ .session = root });
                            if (multi_hop) try std.testing.expectEqual(own_turn, working.work.work.turn.?) else try std.testing.expect(own_turn != working.work.work.turn.?);
                        }
                        try std.testing.expect(!storage.isFenced());
                    }
                }
            }
        }
    }.run);
}

test "obligation frontier preserves eligible admission times when clocks step backward" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "seed-root");
            const child = try configureTestSession(&storage, "seed-child");
            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
            try submitTestMessage(&storage, &tmp, "seed-first-file", "seed-first", child.slice(), "first");
            try submitTestMessage(&storage, &tmp, "seed-later-file", "seed-later", child.slice(), "later");
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=17 WHERE command_key='seed-first'", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=9 WHERE command_key='seed-later'", .{});
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 9);
            var stop = try completeSessionStop("seed-stop", child.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expectSeed(&storage, root.slice(), null);
            try submitTestMessage(&storage, &tmp, "seed-after-file", "seed-after", child.slice(), "after stop");
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=23 WHERE command_key='seed-after'", .{});
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 23);
            try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 23);
        }

        fn expectSeed(storage: *Store, root: []const u8, expected: ?u64) !void {
            const entry = try store_core.enter(storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            var works = [_]report_domain.WorkRead{.{ .session = root }};
            try report_domain.readWorks(&a, &works);
            try std.testing.expectEqual(expected, works[0].inputs.owed_since);
        }
    }.run);
}

test "new attachments invalidate saved ancestors and deep trees forget ring coverage" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "attach-root");
            const unrelated = try configureTestSession(&storage, "attach-unrelated");
            var parent = root;
            for (0..5) |depth| {
                var request: protocol.ActivityPage = .{};
                try request.session.set(root.slice());
                var page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&request, &page);
                const before = page.token.?;
                const listing = try TestingListing.read(&storage, &tmp, .{});
                var key: [32]u8 = undefined;
                var command: wire_request.ConfigureCommand = .{};
                try command.key.set(try std.fmt.bufPrint(&key, "attach-{d}", .{depth}));
                command.configuration = try testingAgentSpec(&.{}, "ask");
                command.configuration.parent.state = .value;
                try command.configuration.parent.value.set(parent.slice());
                parent = (try storage.configure(&command, .{})).accepted.session;
                request.position = page.end;
                request.since = before;
                try storage.activityPage(&request, &page);
                try std.testing.expect(!page.not_modified);
                try std.testing.expect(page.work.work.state == .idle);
                const changed = try TestingListing.read(&storage, &tmp, .{ .since = listing.since });
                if (depth < 3) {
                    try std.testing.expectEqual(protocol.ListDelta.changed, changed.delta);
                    try std.testing.expectEqual(depth + 2, changed.count);
                    for (changed.references[0..changed.count]) |ref| try std.testing.expect(!std.mem.eql(u8, &ref, unrelated.slice()));
                } else {
                    // Five distinct Sessions cannot fit Touched: forget, do
                    // not silently truncate the chain before its root.
                    try std.testing.expectEqual(protocol.ListDelta.full, changed.delta);
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "a stop that selected no Turn decides work only through the input it excluded" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "no-turn-stop-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "no-turn-stop-answer", &answer);

            // A stop with nothing to stop leaves the Session finished.
            var idle_stop = try completeSessionStop("no-turn-stop-idle", session.slice());
            try std.testing.expect(storage.stopSession(&idle_stop, .{}) == .accepted);
            _ = try expectOneWork(&storage, &tmp, session.slice(), "finished");

            // A stop that excluded queued input stops the Session from that stop,
            // and later no-op stops change nothing.
            try submitTestMessage(&storage, &tmp, "no-turn-stop-file", "no-turn-stop-queued", session.slice(), "queued");
            var effective = try completeSessionStop("no-turn-stop-effective", session.slice());
            try std.testing.expect(storage.stopSession(&effective, .{}) == .accepted);
            const stopped_at = try store_testing.queryU64(&storage, "SELECT stopped_at FROM session_stop WHERE command_key='no-turn-stop-effective'", .{});
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));
            var later = try completeSessionStop("no-turn-stop-later", session.slice());
            try std.testing.expect(storage.stopSession(&later, .{}) == .accepted);
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));

            // New input after the stop starts a Turn whose state is the Session's.
            try submitTestMessage(&storage, &tmp, "no-turn-stop-next-file", "no-turn-stop-next", session.slice(), "next");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            _ = try expectOneWork(&storage, &tmp, session.slice(), "working");
        }
    }.run);
}
