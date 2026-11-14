//! Session list Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const session_list_read_domain = @import("../domain/session_list_read.zig");
const store_testing = @import("../testing.zig");
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TestingConfiguring = shared_fixtures.TestingConfiguring;
const TestingListReply = shared_fixtures.TestingListReply;
const TestingListing = shared_fixtures.TestingListing;
const TestingScript = shared_fixtures.TestingScript;
const TwinRounds = shared_fixtures.TwinRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingIdLess = shared_fixtures.testingIdLess;
const testingListRow = shared_fixtures.testingListRow;
const testingSessionList = shared_fixtures.testingSessionList;
const testingSessionListReport = shared_fixtures.testingSessionListReport;
const testingSessionReport = shared_fixtures.testingSessionReport;

test "Session list pages accepted creation order with exact workspace and fixed high water" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var long_path: [3 * 241]u8 = undefined;
            @memset(&long_path, 'w');
            long_path[240] = '/';
            long_path[481] = '/';
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, &long_path, .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            var used = std.atomic.Value(u64).init(0);
            // Not configuration: request captures must never create list entries.
            var unrelated = try completeConfiguration("rejected-list", "", workspace, "model");
            unrelated.configuration.workspace.state = .omitted;
            try std.testing.expect(try storage.configure(&unrelated, .{}) == .rejected);
            const empty = try testingSessionList(&storage, &tmp, .{}, &used, 1);
            defer std.testing.allocator.free(empty);
            // A full listing's token is this opening's current generation.
            var token: [protocol.SinceToken.max_bytes]u8 = undefined;
            const since = (protocol.SinceToken{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) }).format(&token);
            var expected_empty: [256]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_empty, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[],\"delta\":\"full\",\"since\":\"{s}\",\"next\":null}}", .{since}), empty);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

            var ids: [10]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&ids, 0..) |*id, index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "list-config-{d}", .{index});
                var config = try completeConfiguration(key, "", workspace, "model\nwith-control");
                if (index == 3) try config.configuration.workspace.value.set(other);
                const configured = try storage.configure(&config, .{});
                try std.testing.expect(configured == .accepted);
                id.* = configured.accepted.session;
                if (index == 8) {
                    var exactly_eight = protocol.ListSessions{};
                    exactly_eight.workspace = .{};
                    try exactly_eight.workspace.?.set(workspace);
                    const boundary = try testingSessionList(&storage, &tmp, exactly_eight, &used, 99);
                    defer std.testing.allocator.free(boundary);
                    var parsed_boundary = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, boundary, .{});
                    defer parsed_boundary.deinit();
                    try std.testing.expectEqual(@as(usize, 8), parsed_boundary.value.object.get("sessions").?.array.items.len);
                    try std.testing.expect(parsed_boundary.value.object.get("next").? == .null);
                }
            }
            var request = protocol.ListSessions{};
            try std.testing.expectError(error.InvalidCursor, storage.readSessionList(&.{ .after = 2, .ceiling = 1 }, @as(*TestingListReply, undefined)));
            request.workspace = .{};
            try request.workspace.?.set(workspace);
            const first = try testingSessionList(&storage, &tmp, request, &used, 2);
            defer std.testing.allocator.free(first);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first, .{});
            defer parsed.deinit();
            const sessions = parsed.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 8), sessions.len);
            const expected = [_][]const u8{ ids[0].slice(), ids[1].slice(), ids[2].slice(), ids[4].slice(), ids[5].slice(), ids[6].slice(), ids[7].slice(), ids[8].slice() };
            for (sessions, expected) |item, name| {
                try std.testing.expectEqualStrings(name, item.object.get("reference").?.string);
                try std.testing.expectEqualStrings(workspace, item.object.get("workspace").?.string);
                try std.testing.expectEqualStrings("model\nwith-control", item.object.get("model").?.string);
            }
            const next = parsed.value.object.get("next").?.object;
            request.after = try std.fmt.parseInt(u64, next.get("after").?.string, 10);
            request.ceiling = try std.fmt.parseInt(u64, next.get("ceiling").?.string, 10);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            var later = try completeConfiguration("list-later", "", workspace, "different");
            try std.testing.expect(try storage.configure(&later, .{}) == .accepted);
            const second = try testingSessionList(&storage, &tmp, request, &used, 3);
            defer std.testing.allocator.free(second);
            var final = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second, .{});
            defer final.deinit();
            try std.testing.expectEqualStrings(ids[9].slice(), final.value.object.get("sessions").?.array.items[0].object.get("reference").?.string);
            try std.testing.expectEqual(@as(usize, 1), final.value.object.get("sessions").?.array.items.len);
            try std.testing.expect(final.value.object.get("next").? == .null);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            var exact = protocol.ListSessions{};
            exact.workspace = .{};
            try exact.workspace.?.set(other);
            const filtered = try testingSessionList(&storage, &tmp, exact, &used, 4);
            defer std.testing.allocator.free(filtered);
            var filtered_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, filtered, .{});
            defer filtered_json.deinit();
            const one = filtered_json.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), one.len);
            try std.testing.expectEqualStrings(ids[3].slice(), one[0].object.get("reference").?.string);
            try std.testing.expectEqualStrings(other, one[0].object.get("workspace").?.string);
            var scratch_path: [protocol.max_store_bytes]u8 = undefined;
            const scratch_length = try tmp.dir.realPath(std.testing.io, &scratch_path);
            // Hold a captured page while a new configuration commits: delivery owns
            // scratch, not a SQLite cursor, transaction or Store entry.
            var held = try testingSessionListReport(&storage, &.{}, scratch_path[0..scratch_length], .{ .used = &used, .limit = 1024 * 1024 }, 5);
            try std.testing.expect(used.load(.acquire) > 0);
            var concurrent = try completeConfiguration("list-concurrent", "", workspace, "model");
            try std.testing.expect(try storage.configure(&concurrent, .{}) == .accepted);
            held.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expectError(error.ReportScratchExhausted, testingSessionListReport(&storage, &.{}, scratch_path[0..scratch_length], .{ .used = &used, .limit = 16 }, 6));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a since listing answers only the Sessions changed since its token, or everything" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            var commands: u64 = 0;
            const Change = struct {
                /// Creates a Session, or relabels one: a new revision each time.
                fn configure(store: *Store, count: *u64, session: []const u8, place: []const u8) !change_ring.Id {
                    count.* += 1;
                    var key: [32]u8 = undefined;
                    var command = try completeConfiguration(try std.fmt.bufPrint(&key, "since-{d}", .{count.*}), session, place, "model");
                    command.configuration.label.state = .value;
                    try command.configuration.label.value.set(try std.fmt.bufPrint(&key, "Label {d}", .{count.*}));
                    const configured = try store.configure(&command, .{});
                    try std.testing.expect(configured == .accepted);
                    return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
                }
            };
            var ids: [12]change_ring.Id = undefined;
            for (&ids) |*id| id.* = try Change.configure(&storage, &commands, "", workspace);
            const elsewhere = try Change.configure(&storage, &commands, "", other);
            var scope: protocol.ListSessions = .{ .workspace = .{} };
            try scope.workspace.?.set(workspace);

            // A full listing's token is the generation it read under.
            const full = try TestingListing.read(&storage, &tmp, scope);
            try std.testing.expectEqual(protocol.ListDelta.full, full.delta);
            try std.testing.expectEqualSlices(u8, &storage.instance, &full.since.instance);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), full.since.generation);
            try std.testing.expect(storage.notModified(full.since));
            var since = scope;
            since.since = full.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});

            // Only what changed, read fresh, in ID order; the token moves to now.
            const changed_pair = [_]change_ring.Id{ ids[3], ids[10] };
            _ = try Change.configure(&storage, &commands, &ids[10], workspace);
            _ = try Change.configure(&storage, &commands, &ids[3], workspace);
            try std.testing.expect(!storage.notModified(full.since));
            var sorted_pair = changed_pair;
            std.mem.sort(change_ring.Id, &sorted_pair, {}, testingIdLess);
            const pair = try TestingListing.read(&storage, &tmp, since);
            try std.testing.expectEqual(protocol.ListDelta.changed, pair.delta);
            try pair.expectReferences(&sorted_pair);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), pair.since.generation);
            try std.testing.expect(storage.notModified(pair.since));
            // Another opening's token, even at this generation, gets everything.
            var stranger = since;
            stranger.since.?.instance[0] ^= 1;
            stranger.since.?.generation = pair.since.generation;
            try std.testing.expect(!storage.notModified(stranger.since.?));
            try std.testing.expectEqual(protocol.ListDelta.full, (try TestingListing.read(&storage, &tmp, stranger)).delta);

            // The request's Workspace scopes the changes.
            _ = try Change.configure(&storage, &commands, &elsewhere, other);
            since.since = pair.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});
            try (try TestingListing.read(&storage, &tmp, .{ .since = pair.since })).expectReferences(&.{elsewhere});

            // Eight per page; a continuation answers through the first page's
            // generation, so a commit between pages waits for the next token.
            since.since = (try TestingListing.read(&storage, &tmp, since)).since;
            for (ids) |id| _ = try Change.configure(&storage, &commands, &id, workspace);
            var all = ids;
            std.mem.sort(change_ring.Id, &all, {}, testingIdLess);
            const first = try TestingListing.read(&storage, &tmp, since);
            try first.expectReferences(all[0..8]);
            try std.testing.expectEqual(first.since.generation, first.next.?.changed.?.through);
            _ = try Change.configure(&storage, &commands, &all[0], workspace);
            const rest = try TestingListing.read(&storage, &tmp, first.next.?);
            try std.testing.expectEqual(protocol.ListDelta.changed, rest.delta);
            try rest.expectReferences(all[8..]);
            try std.testing.expect(rest.next == null);
            try std.testing.expectEqual(first.since.generation, rest.since.generation);
            try std.testing.expect(storage.commitGeneration() > first.next.?.changed.?.through);
            since.since = rest.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{all[0]});

            // Once the hint forgets a change after the token, the answer is the
            // ordinary traversal, and so is a changed continuation that was
            // overtaken.
            storage.changes.forget(storage.commit_generation.load(.acquire));
            _ = try Change.configure(&storage, &commands, &ids[0], workspace);
            for ([_]protocol.ListSessions{ since, first.next.? }) |request| {
                const restarted = try TestingListing.read(&storage, &tmp, request);
                try std.testing.expectEqual(protocol.ListDelta.full, restarted.delta);
                try std.testing.expectEqual(@as(usize, 8), restarted.count);
                try std.testing.expect(restarted.next.?.since == null and restarted.next.?.after != 0);
                try std.testing.expectEqual(storage.commit_generation.load(.acquire), restarted.since.generation);
            }
            // A fenced Store never answers unchanged, so the read reports the failure.
            const now: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            try std.testing.expect(storage.notModified(now));
            try std.testing.expectEqual(error.SqliteExecFailed, store_core.fence(&storage, error.SqliteExecFailed));
            try std.testing.expect(!storage.notModified(now));
        }
    }.run);
}

test "a Session creation that rolls back never reaches a since listing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "rollback-config");
            const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            {
                // The creation's write round runs, then its transaction rolls back.
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const create = try completeConfiguration("rollback-create", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var creating: TestingConfiguring(struct {}) = .{ .storage = &storage, .session = "", .configuration = &create.configuration };
                try TestingScript(@TypeOf(creating)).run(&entry, &creating);
            }
            // The rolled-back insert still moved the commit counter. The hint
            // forgot instead of naming a Session that does not exist.
            try std.testing.expect(!storage.notModified(since));
            const listed = try TestingListing.read(&storage, &tmp, .{ .since = since });
            try std.testing.expectEqual(protocol.ListDelta.full, listed.delta);
            try listed.expectReferences(&.{session.slice()[0..protocol.session_id_bytes].*});
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Session list capture and cursor storage stay page bounded as dormant Sessions grow" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var used = std.atomic.Value(u64).init(0);
            var first_fixed_length: usize = 0;
            for (0..1000) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "dormant-key-{d}", .{i});
                var config = try completeConfiguration(key, "", workspace, "model");
                const reply = try storage.configure(&config, .{});
                // 1,000 creations share these lines: name the one that failed.
                errdefer std.debug.print("dormant Session {d} (every write run twice: {}): {any}\n", .{ i, case.rerun, reply });
                try std.testing.expect(reply == .accepted);
                if (i == 99 or i == 999) {
                    // The change hint counts writes, not Sessions (and can
                    // include rolled-back writes). Cross a wider token boundary
                    // independently of the population's 100 -> 1000 boundary.
                    _ = storage.commit_generation.fetchAdd(if (i == 99) 900 else 100000, .release);
                    const bytes = try testingSessionList(&storage, &tmp, .{}, &used, i + 1);
                    defer std.testing.allocator.free(bytes);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer parsed.deinit();
                    const page = parsed.value.object;
                    try std.testing.expectEqual(@as(usize, protocol.session_list_page_size), page.get("sessions").?.array.items.len);
                    // The same first page and continuation remain byte bounded;
                    // only the opaque tokens and ceiling may change their widths.
                    var variable_bytes = page.get("since").?.string.len + page.get("next").?.object.get("ceiling").?.string.len;
                    for (page.get("sessions").?.array.items) |row| variable_bytes += row.object.get("read_version").?.string.len;
                    const fixed_bytes = bytes.len - variable_bytes;
                    if (i == 99) first_fixed_length = fixed_bytes else try std.testing.expectEqual(first_fixed_length, fixed_bytes);
                    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
                }
            }
        }
    }.run);
}

test "last line follows ended Turns and pending approvals with bounded public text" {
    try store_testing.forEachEngine(struct {
        fn expect(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, position: ?u64, text: ?[]const u8, first_action: ?u64) !void {
            var listed = try testingListRow(storage, tmp, session);
            defer listed.deinit();
            if (first_action) |action| {
                try std.testing.expectEqual(action, try listed.number(&.{ "work", "first_action" }));
            } else try std.testing.expect(listed.get(&.{ "work", "first_action" }) == .null);
            if (position) |at| {
                try std.testing.expectEqual(at, try listed.number(&.{ "last_line", "position" }));
                const shown = listed.get(&.{ "last_line", "text" });
                if (text) |line| {
                    try std.testing.expectEqualStrings(line, shown.string);
                    try std.testing.expect(shown.string.len <= 200);
                    try std.testing.expect(std.unicode.utf8ValidateSlice(shown.string));
                } else try std.testing.expect(shown == .null);
            } else try std.testing.expect(listed.get(&.{"last_line"}) == .null);
            // The activity snapshot consumed by the open row must carry
            // exactly the listing's canonical preview, not a chat excerpt.
            var request: protocol.ActivityPage = .{};
            try request.session.set(session);
            var activity: protocol.ActivityFacts = undefined;
            try storage.activityPage(&request, &activity);
            try std.testing.expectEqual(first_action, activity.work.work.first_action);
            if (position) |at| {
                const line = activity.work.last_line orelse return error.TestExpectedEqual;
                try std.testing.expectEqual(at, line.position);
                if (text) |expected| try std.testing.expectEqualStrings(expected, line.text.?.slice()) else try std.testing.expect(line.text == null);
            } else try std.testing.expect(activity.work.last_line == null);
            if (position) |at| if (at > 1) {
                // Work is live even when historical rows are pinned to an
                // older end. Its canonical preview must travel with it.
                request.end = 1;
                try storage.activityPage(&request, &activity);
                try std.testing.expectEqual(@as(u64, 1), activity.end);
                try std.testing.expectEqualDeep(protocol.SinceToken{ .instance = storage.instance, .generation = storage.commitGeneration() }, activity.work.read_version);
                try std.testing.expectEqual(at, activity.work.last_line.?.position);
            };
        }

        fn ended(storage: *Store, session: []const u8) !u64 {
            return store_testing.queryU64(storage, "SELECT max(outcome_position) FROM turn WHERE session_ref=?1", .{session});
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "last-line-config");
            try expect(&storage, &tmp, session.slice(), null, null, null);

            const first = [_]TestingAnswerPart{.{ .encoded = "First answer\\nnot the preview", .decoded = "First answer\nnot the preview" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "last-line-first", &first);
            const first_position = try ended(&storage, session.slice());
            try expect(&storage, &tmp, session.slice(), first_position, "First answer", null);

            const second = [_]TestingAnswerPart{.{ .encoded = "Later answer", .decoded = "Later answer" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "last-line-second", &second);
            const second_position = try ended(&storage, session.slice());
            try std.testing.expect(second_position > first_position);
            try expect(&storage, &tmp, session.slice(), second_position, "Later answer", null);

            // While another Turn runs, keep the ended Turn, not its partial output.
            try submitTestMessage(&storage, &tmp, "last-line-call-input", "last-line-call-key", session.slice(), "propose");
            const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try expect(&storage, &tmp, session.slice(), second_position, "Later answer", null);
            const calls = [_]TestingCall{
                .{ .item_id = "older", .name = "bash", .encoded_call_id = "older", .decoded_call_id = "older", .encoded_arguments = "{\\\"description\\\":\\\"Older approval\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Older approval\",\"cmd\":\"true\",\"timeout_ms\":null}" },
                .{ .item_id = "newer", .name = "bash", .encoded_call_id = "newer", .decoded_call_id = "newer", .encoded_arguments = "{\\\"description\\\":\\\"Newer approval\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Newer approval\",\"cmd\":\"true\",\"timeout_ms\":null}" },
                .{ .item_id = "newest", .name = "bash", .encoded_call_id = "newest", .decoded_call_id = "newest", .encoded_arguments = "{\\\"description\\\":\\\"Newest approval\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Newest approval\",\"cmd\":\"true\",\"timeout_ms\":null}" },
            };
            try settleCallsForTesting(&storage, &tmp, proposing, "last-line-calls", &calls);
            const oldest_position = try store_testing.queryU64(&storage, "SELECT min(approval_position) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            const middle_position = try store_testing.queryU64(&storage, "SELECT approval_position FROM action_operation WHERE session_ref=?1 AND call_ordinal=1", .{session.slice()});
            const newest_position = try store_testing.queryU64(&storage, "SELECT max(approval_position) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            const oldest_action = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            const middle_action = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE session_ref=?1 AND call_ordinal=1", .{session.slice()});
            const newest_action = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            try std.testing.expect(oldest_position > second_position and middle_position > oldest_position and newest_position > middle_position);
            try expect(&storage, &tmp, session.slice(), oldest_position, "Older approval", oldest_action);

            var allow: protocol.PermissionDecisionCommand = .{ .action_id = oldest_action, .decision = .allow_once };
            try allow.key.set("last-line-allow-older");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), middle_position, "Newer approval", middle_action);

            // first_action still owns the line when work is Bash, not approval:
            // the allowed Action runs beside two still-awaiting decisions.
            const running = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            try std.testing.expectEqual(oldest_action, running.action_id);
            try expect(&storage, &tmp, session.slice(), middle_position, "Newer approval", middle_action);
            {
                var mixed = try testingListRow(&storage, &tmp, session.slice());
                defer mixed.deinit();
                try std.testing.expectEqualStrings("bash", mixed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(@as(u64, 1), try mixed.number(&.{ "work", "state", "running" }));
                try std.testing.expectEqual(@as(u64, 2), try mixed.number(&.{ "work", "state", "approvals" }));
            }

            // Denying the oldest awaiting Action advances to its sibling,
            // even while the first allowed Action remains running.
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = middle_action, .decision = .deny };
            try deny.key.set("last-line-deny-middle");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), newest_position, "Newest approval", newest_action);

            // An allowed but unstarted Action is no longer a pending approval.
            allow.action_id = newest_action;
            try allow.key.set("last-line-allow-newest");
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), second_position, "Later answer", null);
            _ = try storage.settleActionAttempt(running, .succeeded, "Bash succeeded.", .{});
            var stop = try completeSessionStop("last-line-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), try ended(&storage, session.slice()), null, null);

            try submitTestMessage(&storage, &tmp, "last-line-fail-input", "last-line-fail-key", session.slice(), "fail");
            const failing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(failing, .{ .rejected = .{ .code = "provider_quota", .diagnostic = "", .request_id = .{}, .report = "Not an answer" } }, .ordinary, .{});
            try expect(&storage, &tmp, session.slice(), try ended(&storage, session.slice()), null, null);

            // Independent expected lines cover CR/LF, blank-led multiline,
            // exact byte bounds, code-point cuts and the 1 KiB read boundary.
            inline for (.{
                .{ "blank", "\\r\\n \\t\\n  useful line \\r\\nignored", "\r\n \t\n  useful line \r\nignored", @as(?[]const u8, "useful line") },
                .{ "long", "\\n" ++ @as([1200]u8, @bitCast(@as([600][2]u8, @splat("é".*)))) ++ "\\nignored", "\n" ++ @as([1200]u8, @bitCast(@as([600][2]u8, @splat("é".*)))) ++ "\nignored", @as(?[]const u8, @as([196]u8, @bitCast(@as([98][2]u8, @splat("é".*)))) ++ "…") },
                .{ "exact", &@as([200]u8, @splat('x')), &@as([200]u8, @splat('x')), @as(?[]const u8, &@as([200]u8, @splat('x'))) },
                .{ "empty", " \\t\\n\\r\\n", " \t\n\r\n", @as(?[]const u8, null) },
                .{ "prefix", @as([1024]u8, @splat(' ')) ++ "not read", @as([1024]u8, @splat(' ')) ++ "not read", @as(?[]const u8, null) },
                .{ "split", @as([1021]u8, @splat(' ')) ++ "x€", @as([1021]u8, @splat(' ')) ++ "x€", @as(?[]const u8, "x") },
            }) |answer| {
                const parts = [_]TestingAnswerPart{.{ .encoded = answer[1], .decoded = answer[2] }};
                try answerTestTurn(&storage, &tmp, session.slice(), "last-line-" ++ answer[0], &parts);
                try expect(&storage, &tmp, session.slice(), try ended(&storage, session.slice()), answer[3], null);
            }

            const private = [_]TestingAnswerPart{.{ .encoded = "Do not disclose", .decoded = "Do not disclose" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "last-line-private", &private);
            const private_position = try ended(&storage, session.slice());
            // Public output cannot normally name private content; substitute
            // it at the read boundary to prove the preview never discloses it.
            try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT outcome_content_id FROM turn WHERE session_ref=?1 AND outcome_position=?2)", .{ session.slice(), private_position });
            try expect(&storage, &tmp, session.slice(), private_position, null, null);

            const active = try configureTestSession(&storage, "last-line-active-config");
            try submitTestMessage(&storage, &tmp, "last-line-active-input", "last-line-active-key", active.slice(), "first turn");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try expect(&storage, &tmp, active.slice(), null, null, null);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a list row carries its Session's Label, times, first Message, work and peers" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("row-create", "", workspace, "model-a");
            create.configuration.label.state = .value;
            try create.configuration.label.value.set("Review PR 412");
            const session = (try storage.configure(&create, .{})).accepted.session;
            const created_at = try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{});
            {
                // Configured, never messaged: idle since its creation.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expect(listed.get(&.{"parent"}) == .null);
                try std.testing.expectEqualStrings("Review PR 412", listed.get(&.{"label"}).string);
                try std.testing.expectEqual(created_at, try listed.number(&.{"created_at"}));
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{"revision"}));
                try std.testing.expectEqual(@as(u64, 0), try listed.number(&.{"end"}));
                try std.testing.expect(listed.get(&.{"first_message"}) == .null);
                try std.testing.expectEqualStrings("idle", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(created_at, try listed.number(&.{ "work", "state", "since" }));
                try std.testing.expect(listed.get(&.{ "peers", "from_person_at" }) == .null);
            }
            try submitTestMessage(&storage, &tmp, "row-first", "row-first", session.slice(), "hello");
            // Distinct times show which Message each fact names.
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=1000", .{});
            {
                // Queued: the first Message is unbound, and a person sent it.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{"end"}));
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{ "first_message", "position" }));
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
                try std.testing.expect(listed.get(&.{ "first_message", "sender" }) == .null);
                try std.testing.expectEqualStrings("5", listed.get(&.{ "first_message", "content", "bytes" }).string);
                const digest = std.fmt.bytesToHex(protocol.contentDigest("hello"), .lower);
                try std.testing.expectEqualStrings(&digest, listed.get(&.{ "first_message", "content", "sha256" }).string);
                try std.testing.expectEqualStrings("pending", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "peers", "from_person_at" }));
            }
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try submitTestMessage(&storage, &tmp, "row-second", "row-second", session.slice(), "and then");
            const newest_admission = try store_testing.queryU64(&storage, "SELECT max(admission_id) FROM message_admission", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=2000 WHERE admission_id=?1", .{newest_admission});
            {
                // The first Message is now its Turn's; the latest person's Message is
                // the queued second one.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
                try std.testing.expectEqualStrings("working", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expect(listed.get(&.{ "work", "turn" }) != .null and listed.get(&.{ "work", "operation" }) != .null);
                try std.testing.expectEqual(@as(u64, 2000), try listed.number(&.{ "peers", "from_person_at" }));
                try std.testing.expectEqual(try listed.number(&.{"end"}), try store_testing.queryU64(&storage, "SELECT next_position-1 FROM session", .{}));
            }
            // Current reports the same creation time and peer fact.
            const current = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(current);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
            defer report.deinit();
            try std.testing.expectEqual(created_at, try std.fmt.parseInt(u64, report.value.object.get("session").?.object.get("created_at").?.string, 10));
            try std.testing.expectEqualStrings("2000", report.value.object.get("peers").?.object.get("from_person_at").?.string);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a page lists only the kinds it asks for, up to its limit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "kinds-config");
            for ([_][]const u8{ "one", "two", "three" }) |text| try submitTestMessage(&storage, &tmp, text, text, session.slice(), text);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const all = try store_core.activityPageForTesting(&storage, request);
            // Three admissions, and a User row for each the attempt took.
            var user_rows: usize = 0;
            for (all.items[0..all.count]) |item| user_rows += @intFromBool(item.value == .user);
            try std.testing.expect(user_rows > 0 and all.count == 3 + user_rows and !all.more);
            request.kinds = .initOne(.user);
            const users = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(users.count == user_rows and !users.more);
            for (users.items[0..users.count]) |item| try std.testing.expect(item.value == .user);
            request.kinds = .initMany(&.{ .admission, .user });
            request.limit = 2;
            const two = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(two.count == 2 and two.more);
            try std.testing.expectEqual(all.items[0].position, two.items[0].position);
            try std.testing.expectEqual(all.items[1].position, two.items[1].position);
            request.limit = 0;
            try std.testing.expectError(error.InvalidCursor, store_core.activityPageForTesting(&storage, request));
            request.limit = 1;
            request.kinds = .empty;
            try std.testing.expectError(error.InvalidCursor, store_core.activityPageForTesting(&storage, request));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// The rounds one list page takes over a Store of `count` Sessions, each
/// whose work reads its deepest stages: an answered Turn, then a queued
/// Message a stop excluded.
fn listRoundsForTesting(case: *store_testing.Case, count: usize) !u32 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    inline for (0..protocol.session_list_page_size) |index| if (index < count) {
        const name = std.fmt.comptimePrint("list-rounds-{d}", .{index});
        const session = try configureTestSession(&storage, name);
        try answerTestTurn(&storage, &tmp, session.slice(), name ++ "-answer", &answer);
        try submitTestMessage(&storage, &tmp, name ++ "-queued-file", name ++ "-queued", session.slice(), "excluded");
        var stop = try completeSessionStop(name ++ "-stop", session.slice());
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    };
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
    var reply: TestingListReply = .{ .capture = &capture };
    try session_list_read_domain.readSessionList(&a, &.{}, &reply);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    var bytes: [8192]u8 = undefined;
    const read = try report.read(0, bytes[0..@intCast(@min(report.length, bytes.len))]);
    // Every shown row's work went through its stop.
    try std.testing.expectEqual(count, std.mem.count(u8, bytes[0..read], "\"kind\":\"stopped\""));
    return rounds;
}

test "a list page's rows share their rounds, so eight rows take as many as one" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // The page; its rows' latest Turns and first-Message seeks; then the
            // stop cutoff, the queue after it, the excluded Message and its stop;
            // then the rows themselves.
            try std.testing.expectEqual(@as(u32, 8), try listRoundsForTesting(case, 1));
            try std.testing.expectEqual(@as(u32, 8), try listRoundsForTesting(case, protocol.session_list_page_size));
        }
    }.run);
}

test "a list row's failed Actions read answers main's ActionReadFailed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "list-actions-config");
            try submitTestMessage(&storage, &tmp, "list-actions-input", "list-actions-message", session.slice(), "call");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const call = [_]TestingCall{.{ .item_id = "list-actions-item", .name = "bash", .encoded_call_id = "list-actions-call", .decoded_call_id = "list-actions-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&storage, &tmp, binding, "list-actions-output", &call);
            try store_testing.failReadsOf(&storage, "action_operation");
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ActionReadFailed, testingSessionList(&storage, &tmp, .{}, &used, 5));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "creating a Session takes the same work however many Sessions exist, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const few = TwinRounds.start(&storage);
            _ = try configureTestSession(&storage, "creation-rounds-few");
            const few_rounds = few.taken();
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
                "SELECT 100000+value,'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
            const many = TwinRounds.start(&storage);
            _ = try configureTestSession(&storage, "creation-rounds-many");
            try std.testing.expectEqual(few_rounds, many.taken());
        }
    }.run);
}

test "a Workspace's changed page reads only its own Sessions, however many others changed, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // A rerun repeats the rounds this counts.
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            const watched = try configure(&storage, "scoped-watched", "", workspace);
            var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
            try request.workspace.?.set(workspace);
            _ = try configure(&storage, "scoped-watched-again", &watched, workspace);
            const alone = try rounds(&storage, &tmp, request, &watched);
            for (1..change_ring.capacity) |index| {
                var key: [32]u8 = undefined;
                _ = try configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
            }
            try std.testing.expect(storage.changes.covers(request.since.?.generation));
            try std.testing.expectEqual(alone, try rounds(&storage, &tmp, request, &watched));
        }

        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = try store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
        }

        fn rounds(store: *Store, dir: *std.testing.TmpDir, request: protocol.ListSessions, watched: *const change_ring.Id) !u16 {
            const counter = TwinRounds.start(store);
            const page = try TestingListing.read(store, dir, request);
            const taken = counter.taken();
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try page.expectReferences(&.{watched.*});
            try std.testing.expect(page.next == null);
            return taken;
        }
    }.run);
}

test "a list row reads the same steps however long its Session's history, in rounds" {
    try store_testing.forEachEngine(struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "row-rounds");
            try stopped(&storage, &tmp, session.slice(), "row-rounds-0");
            try answerTestTurn(&storage, &tmp, session.slice(), "row-rounds-short", &answer);
            const short = try rowRounds(&storage, &tmp, session.slice());
            inline for (1..33) |turn| try stopped(&storage, &tmp, session.slice(), std.fmt.comptimePrint("row-rounds-{d}", .{turn}));
            try answerTestTurn(&storage, &tmp, session.slice(), "row-rounds-long", &answer);
            try std.testing.expect(short > 0);
            try std.testing.expectEqual(short, try rowRounds(&storage, &tmp, session.slice()));
        }

        /// An answered Turn, then a queued Message a stop excluded.
        fn stopped(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }

        /// The Session is the list's only row, so the page's rounds are its row's.
        fn rowRounds(store: *Store, dir: *std.testing.TmpDir, session: []const u8) !u16 {
            var used = std.atomic.Value(u64).init(0);
            const counter = TwinRounds.start(store);
            std.testing.allocator.free(try testingSessionList(store, dir, .{}, &used, 79));
            const taken = counter.taken();
            var listed = try testingListRow(store, dir, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings("finished", listed.get(&.{ "work", "state", "kind" }).string);
            return taken;
        }
    }.run);
}
