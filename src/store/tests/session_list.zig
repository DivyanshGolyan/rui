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
const RoundMeter = shared_fixtures.RoundMeter;
const TwinRounds = shared_fixtures.TwinRounds;
const round_budgets = shared_fixtures.round_budgets;
const pass_budgets = shared_fixtures.pass_budgets;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingIdLess = shared_fixtures.testingIdLess;
const testingListRow = shared_fixtures.testingListRow;
const testingSessionList = shared_fixtures.testingSessionList;
const testingSessionListReport = shared_fixtures.testingSessionListReport;
const testingSessionReport = shared_fixtures.testingSessionReport;

/// Counts the commit notices a Store sends its commit subscriber.
const CommitCounter = struct {
    count: usize = 0,
    fn notify(context: *anyopaque) void {
        const self: *CommitCounter = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

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
            var unrelated = try completeConfiguration("rejected-list", "", workspace, "model");
            unrelated.configuration.workspace.state = .omitted;
            try std.testing.expect(try storage.configure(&unrelated, .{}) == .rejected);
            const empty = try testingSessionList(&storage, &tmp, .{}, &used, 1);
            defer std.testing.allocator.free(empty);
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
            try std.testing.expectError(error.InvalidCursor, storage.readSessionList(&.{ .after = 2, .ceiling = 1 }, @as(*TestingListReply, undefined), @as(*session_list_read_domain.Scratch, undefined)));
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

test "SUI-58 host_retry_work_version" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "deadline-config");
            try submitTestMessage(&storage, &tmp, "deadline-input", "deadline-message", session.slice(), "retry");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expect(!(try storage.dispatchWork(false, .{ .free_credit = .none, .mcp_open = false })).retry_waiting);
            const Clock = struct {
                fn before(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    return .{ .nanoseconds = 31_000_000_000 };
                }
                fn after(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    return .{ .nanoseconds = 91_001_000_000 };
                }
                fn random(_: ?*anyopaque, bytes: []u8) void {
                    @memset(bytes, 0);
                }
            };
            var before = std.testing.io.vtable.*;
            before.now = Clock.before;
            before.random = Clock.random;
            var after = before;
            after.now = Clock.after;
            storage.io.vtable = &before;
            defer storage.io = std.testing.io;
            try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
            for ([_]@FieldType(@import("../domain/action.zig").Capacity, "free_credit"){ .none, .one }) |credit| {
                try std.testing.expect((try storage.dispatchWork(false, .{ .free_credit = credit, .mcp_open = false })).retry_waiting);
            }
            const due = try store_testing.queryU64(&storage, "SELECT retry_due_at_ms FROM model_operation WHERE resolution_code IS NULL", .{});
            try std.testing.expectEqual(@as(u64, 91_001), due);
            const full = try TestingListing.read(&storage, &tmp, .{});
            var before_row = try testingListRow(&storage, &tmp, session.slice());
            defer before_row.deinit();
            try std.testing.expectEqualStrings("retrying", before_row.get(&.{ "work", "state", "kind" }).string);
            var commits: CommitCounter = .{};
            var counted: store_core.CommitSubscriber = .{ .context = &commits, .notify = CommitCounter.notify };
            storage.commitSubscriber().store(&counted, .release);
            defer storage.commitSubscriber().store(null, .release);
            const baseline = try storage.publishRetryCrossings(31_000, due - 1);
            try std.testing.expectEqual(full.since.generation, baseline.generation);
            try std.testing.expectEqual(@as(?u64, due), baseline.next);
            storage.io.vtable = &after;
            try std.testing.expectEqual(@as(usize, 0), commits.count);
            const crossing = try storage.publishRetryCrossings(due - 1, due);
            try std.testing.expectEqual(@as(usize, 1), commits.count);
            try std.testing.expectEqual(baseline.generation + 1, crossing.generation);
            const delta = try TestingListing.read(&storage, &tmp, .{ .since = full.since });
            try std.testing.expectEqual(protocol.ListDelta.changed, delta.delta);
            try delta.expectReferences(&.{session.slice()[0..change_ring.id_bytes].*});
            var after_row = try testingListRow(&storage, &tmp, session.slice());
            defer after_row.deinit();
            try std.testing.expectEqualStrings("pending", after_row.get(&.{ "work", "state", "kind" }).string);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const activity = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(crossing.generation, activity.work.read_version.generation);
            try std.testing.expect(activity.work.work.state == .pending);
            try std.testing.expectEqual(@import("../../session_work.zig").Standing.queued, @import("../../session_work.zig").standing(activity.work.work.state, activity.work.work.actions.decide != null));
            const unchanged = try storage.publishRetryCrossings(due, due + 1);
            try std.testing.expectEqual(crossing.generation, unchanged.generation);
            storage.io.vtable = &before;
            const reversed = try storage.publishRetryCrossings(due + 1, due - 1);
            try std.testing.expectEqual(unchanged.generation + 1, reversed.generation);
            try std.testing.expectEqual(@as(?u64, due), reversed.next);
            const reverse_delta = try TestingListing.read(&storage, &tmp, .{ .since = delta.since });
            try reverse_delta.expectReferences(&.{session.slice()[0..change_ring.id_bytes].*});
            var reversed_row = try testingListRow(&storage, &tmp, session.slice());
            defer reversed_row.deinit();
            try std.testing.expectEqualStrings("retrying", reversed_row.get(&.{ "work", "state", "kind" }).string);
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

            const full = try TestingListing.read(&storage, &tmp, scope);
            try std.testing.expectEqual(protocol.ListDelta.full, full.delta);
            try std.testing.expectEqualSlices(u8, &storage.instance, &full.since.instance);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), full.since.generation);
            try std.testing.expect(storage.notModified(full.since));
            var since = scope;
            since.since = full.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});

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
            var stranger = since;
            stranger.since.?.instance[0] ^= 1;
            stranger.since.?.generation = pair.since.generation;
            try std.testing.expect(!storage.notModified(stranger.since.?));
            try std.testing.expectEqual(protocol.ListDelta.full, (try TestingListing.read(&storage, &tmp, stranger)).delta);

            _ = try Change.configure(&storage, &commands, &elsewhere, other);
            since.since = pair.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});
            try (try TestingListing.read(&storage, &tmp, .{ .since = pair.since })).expectReferences(&.{elsewhere});

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

            storage.changes.forget(storage.commit_generation.load(.acquire));
            _ = try Change.configure(&storage, &commands, &ids[0], workspace);
            for ([_]protocol.ListSessions{ since, first.next.? }) |request| {
                const restarted = try TestingListing.read(&storage, &tmp, request);
                try std.testing.expectEqual(protocol.ListDelta.full, restarted.delta);
                try std.testing.expectEqual(@as(usize, 8), restarted.count);
                try std.testing.expect(restarted.next.?.since == null and restarted.next.?.after != 0);
                try std.testing.expectEqual(storage.commit_generation.load(.acquire), restarted.since.generation);
            }
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
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const create = try completeConfiguration("rollback-create", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var creating: TestingConfiguring(struct {}) = .{ .storage = &storage, .session = "", .configuration = &create.configuration };
                try TestingScript(@TypeOf(creating)).run(&entry, &creating);
            }
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
                errdefer std.debug.print("dormant Session {d} (every write run twice: {}): {any}\n", .{ i, case.rerun, reply });
                try std.testing.expect(reply == .accepted);
                if (i == 99 or i == 999) {
                    _ = storage.commit_generation.fetchAdd(if (i == 99) 900 else 100000, .release);
                    const bytes = try testingSessionList(&storage, &tmp, .{}, &used, i + 1);
                    defer std.testing.allocator.free(bytes);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer parsed.deinit();
                    const page = parsed.value.object;
                    try std.testing.expectEqual(@as(usize, protocol.session_list_page_size), page.get("sessions").?.array.items.len);
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

test "a list row and an Activity page serve the oldest awaiting approval through decisions, stops and failures" {
    try store_testing.forEachEngine(struct {
        fn expect(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, first_action: ?u64) !void {
            var listed = try testingListRow(storage, tmp, session);
            defer listed.deinit();
            if (first_action) |action| {
                try std.testing.expectEqual(action, try listed.number(&.{ "work", "first_action" }));
            } else try std.testing.expect(listed.get(&.{ "work", "first_action" }) == .null);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session);
            var activity: protocol.ActivityFacts = undefined;
            try storage.activityPage(&request, &activity);
            try std.testing.expectEqual(first_action, activity.work.work.first_action);
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
            try expect(&storage, &tmp, session.slice(), null);

            const first = [_]TestingAnswerPart{.{ .encoded = "First answer\\nnot the preview", .decoded = "First answer\nnot the preview" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "last-line-first", &first);
            const first_position = try ended(&storage, session.slice());
            try expect(&storage, &tmp, session.slice(), null);

            const second = [_]TestingAnswerPart{.{ .encoded = "Later answer", .decoded = "Later answer" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "last-line-second", &second);
            const second_position = try ended(&storage, session.slice());
            try std.testing.expect(second_position > first_position);
            try expect(&storage, &tmp, session.slice(), null);

            try submitTestMessage(&storage, &tmp, "last-line-call-input", "last-line-call-key", session.slice(), "propose");
            const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try expect(&storage, &tmp, session.slice(), null);
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
            try expect(&storage, &tmp, session.slice(), oldest_action);

            var allow: protocol.PermissionDecisionCommand = .{ .action_id = oldest_action, .decision = .allow_once };
            try allow.key.set("last-line-allow-older");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), middle_action);

            const running = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            try std.testing.expectEqual(oldest_action, running.action_id);
            try expect(&storage, &tmp, session.slice(), middle_action);
            {
                var mixed = try testingListRow(&storage, &tmp, session.slice());
                defer mixed.deinit();
                try std.testing.expectEqualStrings("bash", mixed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(@as(u64, 1), try mixed.number(&.{ "work", "state", "running" }));
                try std.testing.expectEqual(@as(u64, 2), try mixed.number(&.{ "work", "state", "approvals" }));
            }

            var deny: protocol.PermissionDecisionCommand = .{ .action_id = middle_action, .decision = .deny };
            try deny.key.set("last-line-deny-middle");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), newest_action);

            allow.action_id = newest_action;
            try allow.key.set("last-line-allow-newest");
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), null);
            _ = try storage.settleActionAttempt(running, .succeeded, "Bash succeeded.", .{});
            var stop = try completeSessionStop("last-line-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expect(&storage, &tmp, session.slice(), null);

            try submitTestMessage(&storage, &tmp, "last-line-fail-input", "last-line-fail-key", session.slice(), "fail");
            const failing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(failing, .{ .rejected = .{ .code = "provider_quota", .diagnostic = "", .request_id = .{}, .report = .ofMessage("Not an answer") } }, .ordinary, .{});
            try expect(&storage, &tmp, session.slice(), null);

            const active = try configureTestSession(&storage, "last-line-active-config");
            try submitTestMessage(&storage, &tmp, "last-line-active-input", "last-line-active-key", active.slice(), "first turn");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try expect(&storage, &tmp, active.slice(), null);
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
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=1000", .{});
            {
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
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
                try std.testing.expectEqualStrings("working", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expect(listed.get(&.{ "work", "turn" }) != .null and listed.get(&.{ "work", "operation" }) != .null);
                try std.testing.expectEqual(@as(u64, 2000), try listed.number(&.{ "peers", "from_person_at" }));
                try std.testing.expectEqual(try listed.number(&.{"end"}), try store_testing.queryU64(&storage, "SELECT next_position-1 FROM session", .{}));
            }
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

test "SL-5: a list row's first Message, first approval are the owners' values, for every Session shape" {
    try store_testing.forEachEngine(struct {
        const Shape = enum { live_approval, stopped_approval, person_message, peer_message, bare };

        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(Shape)) |shape| try check(case, shape);
        }

        // The row must agree with the owners of each fact: readSessionReport for the first Message and the first
        // approval, and the activity page for the first approval. `expect_*` pins that each shape
        // reaches the fact it is named for, so a shape that reads nothing cannot pass by agreeing with nothing.
        fn check(case: *store_testing.Case, shape: Shape) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try setup(&storage, &tmp, shape);
            var listed = try testingListRow(&storage, &tmp, session.slice());
            defer listed.deinit();
            const report_bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(report_bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
            defer report.deinit();
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);

            const expect_first = shape != .bare;
            const expect_approval = shape == .live_approval;
            const report_first = report.value.object.get("first_message").?;
            const list_first = listed.get(&.{"first_message"});
            try std.testing.expectEqual(expect_first, report_first != .null);
            try expectSameFirst(list_first, report_first);

            const report_action = report.value.object.get("work").?.object.get("first_action").?;
            const list_action = listed.get(&.{ "work", "first_action" });
            try std.testing.expectEqual(expect_approval, report_action != .null);
            try expectSameText(list_action, report_action);
            const page_action: ?u64 = page.work.work.first_action;
            try std.testing.expectEqual(page_action, if (list_action == .null) null else try std.fmt.parseInt(u64, list_action.string, 10));
        }

        fn setup(storage: *Store, tmp: *std.testing.TmpDir, shape: Shape) !protocol.Bounded(protocol.max_session_bytes) {
            switch (shape) {
                .live_approval, .stopped_approval => {
                    // An approval awaiting a decision in a live Turn. Admission takes the oldest pending Message of any
                    // Session, so this shape's Message is the only one in its store.
                    const working = try configureTestSessionAsk(storage, "sl5-working");
                    try submitTestMessage(storage, tmp, "sl5-working-file", "sl5-working-message", working.slice(), "propose");
                    const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    const calls = [_]TestingCall{.{
                        .item_id = "sl5-awaiting",
                        .name = "bash",
                        .encoded_call_id = "sl5-awaiting",
                        .decoded_call_id = "sl5-awaiting",
                        .encoded_arguments = "{\\\"description\\\":\\\"Awaiting\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Awaiting\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    }};
                    try settleCallsForTesting(storage, tmp, proposing, "sl5-calls", &calls);
                    if (shape == .stopped_approval) {
                        var stop = try completeSessionStop("sl5-stop", working.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    }
                    return working;
                },
                .person_message => {
                    const person = try configureTestSession(storage, "sl5-person");
                    try submitTestMessage(storage, tmp, "sl5-person-file", "sl5-person-message", person.slice(), "from a person");
                    return person;
                },
                .peer_message => {
                    const peer = try configureTestSession(storage, "sl5-peer");
                    const receiver = try configureTestSession(storage, "sl5-receiver");
                    try submitTestMessage(storage, tmp, "sl5-peer-file", "sl5-peer-message", receiver.slice(), "from a peer");
                    try store_testing.exec(storage, "UPDATE message_admission SET source_kind=2,sender_session_ref=?1 WHERE session_ref=?2", .{ peer.slice(), receiver.slice() });
                    return receiver;
                },
                .bare => return configureTestSession(storage, "sl5-bare"),
            }
        }

        fn expectSameText(list: std.json.Value, report: std.json.Value) !void {
            if (report == .null) return std.testing.expect(list == .null);
            try std.testing.expectEqualStrings(report.string, list.string);
        }

        fn expectSameFirst(list: std.json.Value, report: std.json.Value) !void {
            if (report == .null) return std.testing.expect(list == .null);
            try std.testing.expect(list != .null);
            for ([_][]const u8{ "position", "admission", "admitted_at" }) |name|
                try expectSameText(list.object.get(name).?, report.object.get(name).?);
            const report_sender = report.object.get("sender") orelse .null;
            const list_sender = list.object.get("sender") orelse .null;
            if (report_sender == .null) return std.testing.expect(list_sender == .null);
            try std.testing.expect(list_sender != .null);
            try expectSameText(list_sender.object.get("session").?, report_sender.object.get("session").?);
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
    return readRoundsForTesting(&storage, &tmp, count);
}

/// The rounds one whole-list read takes over `storage`, which must hold `stopped` stopped Sessions for its row check.
fn readRoundsForTesting(storage: *Store, tmp: *std.testing.TmpDir, stopped: usize) !u32 {
    return readListRoundsForTesting(storage, tmp, stopped, &.{}, &.{});
}

/// The rounds of one whole-list read of the first page over `storage`, which must hold `stopped` stopped
/// Sessions for its row check. Each of `roots` must be on that page with `descendants` at its index as its
/// descendant_count.
fn readListRoundsForTesting(storage: *Store, tmp: *std.testing.TmpDir, stopped: usize, roots: []const []const u8, descendants: []const u64) !u32 {
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
    var reply: TestingListReply = .{ .capture = &capture };
    try session_list_read_domain.readSessionList(&a, &.{}, &scratch, &reply);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(report.length));
    defer std.testing.allocator.free(bytes);
    const read = try report.read(0, bytes);
    try std.testing.expectEqual(stopped, std.mem.count(u8, bytes[0..read], "\"kind\":\"stopped\""));
    if (roots.len != 0) {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..read], .{});
        defer parsed.deinit();
        for (roots, descendants) |reference, count| {
            var found = false;
            for (parsed.value.object.get("sessions").?.array.items) |row| {
                if (!std.mem.eql(u8, row.object.get("reference").?.string, reference)) continue;
                try std.testing.expectEqual(count, try std.fmt.parseInt(u64, row.object.get("descendant_count").?.string, 10));
                found = true;
            }
            try std.testing.expect(found);
        }
    }
    return rounds;
}

// Round budget over subtree size. A list page takes 2 rounds: membership, then the rows with their settings, their work
// and the whole creator subtree with its descendants' work in one statement, whatever the subtree's size or depth. The
// subtree's passes are SQLite's `a creator subtree adds no list read passes`. (Was 2 + about one round per 8-row subtree
// page: 16 children took 4 or 5 rounds.)
test "a list page takes two rounds however many descendants its roots have" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]usize{ 0, 1, 2, 7, 16, 40 }) |count| try expectSame(try children(case, count, false), try children(case, count, true));
            try expectSame(try chain(case, 16, false), try chain(case, 16, true));
            try expectSame(try twoRoots(case, 20, false), try twoRoots(case, 20, true));
        }

        fn expectSame(unlinked: u32, linked: u32) !void {
            try std.testing.expectEqual(@as(u32, 2), unlinked);
            try std.testing.expectEqual(@as(u32, 2), linked);
        }

        fn link(storage: *Store, linked: bool, creator: []const u8, child: []const u8) !void {
            if (linked) try store_testing.exec(storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ creator, child });
        }

        /// One root with `count` children, the root first on the page.
        fn children(case: *store_testing.Case, count: usize, linked: bool) !u32 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "descendant-rounds-root");
            var name: [48]u8 = undefined;
            for (0..count) |index| {
                const child = try configureTestSession(&storage, try std.fmt.bufPrint(&name, "descendant-rounds-{d}", .{index}));
                try link(&storage, linked, root.slice(), child.slice());
            }
            return readListRoundsForTesting(&storage, &tmp, 0, &.{root.slice()}, &.{if (linked) count else 0});
        }

        /// A chain of `depth` Sessions under one root, each created by the one before it.
        fn chain(case: *store_testing.Case, depth: usize, linked: bool) !u32 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "descendant-chain-root");
            var creator = root;
            var name: [48]u8 = undefined;
            for (0..depth) |index| {
                const child = try configureTestSession(&storage, try std.fmt.bufPrint(&name, "descendant-chain-{d}", .{index}));
                try link(&storage, linked, creator.slice(), child.slice());
                creator = child;
            }
            return readListRoundsForTesting(&storage, &tmp, 0, &.{root.slice()}, &.{if (linked) depth else 0});
        }

        /// Two roots on the page with `count` children each.
        fn twoRoots(case: *store_testing.Case, count: usize, linked: bool) !u32 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const left = try configureTestSession(&storage, "descendant-two-left");
            const right = try configureTestSession(&storage, "descendant-two-right");
            var name: [48]u8 = undefined;
            for (0..count * 2) |index| {
                const child = try configureTestSession(&storage, try std.fmt.bufPrint(&name, "descendant-two-{d}", .{index}));
                try link(&storage, linked, if (index % 2 == 0) left.slice() else right.slice(), child.slice());
            }
            const expected: u64 = if (linked) count else 0;
            return readListRoundsForTesting(&storage, &tmp, 0, &.{ left.slice(), right.slice() }, &.{ expected, expected });
        }
    }.run);
}

test "a list page's rows share their rounds, so eight rows take as many as one" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Work is one statement per Session, so a page of any size takes the membership round and the row round:
            // two rounds, down from seven (was 7, one per staged work stage).
            try std.testing.expectEqual(@as(u32, 2), try listRoundsForTesting(case, 1));
            try std.testing.expectEqual(@as(u32, 2), try listRoundsForTesting(case, protocol.session_list_page_size));
        }
    }.run);
}

test "SL-9: a list page matches each row's work and settings to its own Session, for every page size and order" {
    try store_testing.forEachEngine(struct {
        const page = protocol.session_list_page_size;
        // The work state each shape lists as, independent of the read under test.
        const kinds = [_][]const u8{ "idle", "finished", "stopped", "approval" };

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // Each Session has its own label and one of four work shapes, so a row shaped from another Session's
            // settings or work shows another label or state.
            var refs: [page]change_ring.Id = undefined;
            inline for (0..page) |index| {
                const shape: shared_fixtures.TestingWorkShape = @fromBackingInt(@intCast(index % kinds.len));
                const session = try shape.make(&storage, &tmp, std.fmt.comptimePrint("sl9-{d}", .{index}));
                refs[index] = session.slice()[0..change_ring.id_bytes].*;
                try store_testing.exec(&storage, "UPDATE session SET label=?1 WHERE session_ref=?2", .{ @as([]const u8, std.fmt.comptimePrint("sl9-{d}", .{index})), session.slice() });
            }
            // In ref order: both engines are expected to return an IN list's rows in key order [inferred], so a page in
            // reversed or interleaved ref order is one that a match by position would get wrong.
            var by_ref: [page]usize = undefined;
            for (&by_ref, 0..) |*slot, index| slot.* = index;
            std.mem.sort(usize, &by_ref, @as(*const [page]change_ring.Id, &refs), struct {
                fn less(ids: *const [page]change_ring.Id, left: usize, right: usize) bool {
                    return std.mem.order(u8, &ids[left], &ids[right]) == .lt;
                }
            }.less);
            for (1..page + 1) |count| for ([_]enum { reversed, interleaved }{ .reversed, .interleaved }) |order| {
                errdefer std.debug.print("SL-9 failed for {d} rows in {t} order\n", .{ count, order });
                var shown: [page]usize = undefined;
                for (shown[0..count], 0..) |*slot, at| slot.* = switch (order) {
                    .reversed => by_ref[count - 1 - at],
                    .interleaved => by_ref[if (at < (count + 1) / 2) 2 * at else 2 * (at - (count + 1) / 2) + 1],
                };
                try expectPage(&storage, &tmp, &refs, shown[0..count]);
            };
        }

        /// Lists exactly the Sessions `shown`, in that order (it sets their creation order inside a cursor window), and
        /// checks every row against its own Session.
        fn expectPage(storage: *Store, tmp: *std.testing.TmpDir, refs: *const [page]change_ring.Id, shown: []const usize) !void {
            // Creation order is unique, so every Session moves clear of the values it takes next first.
            for (refs, 0..) |*ref, index| try store_testing.exec(storage, "UPDATE session SET created_seq=?1 WHERE session_ref=?2", .{ @as(u64, 3000 + index), ref });
            for (shown, 0..) |index, at| try store_testing.exec(storage, "UPDATE session SET created_seq=?1 WHERE session_ref=?2", .{ @as(u64, 2001 + at), &refs[index] });
            var used = std.atomic.Value(u64).init(0);
            const bytes = try testingSessionList(storage, tmp, .{ .after = 2000, .ceiling = 2000 + shown.len }, &used, 9);
            defer std.testing.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            const rows = parsed.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(shown.len, rows.len);
            for (rows, shown) |row, index| {
                var label: [16]u8 = undefined;
                try std.testing.expectEqualStrings(&refs[index], row.object.get("reference").?.string);
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&label, "sl9-{d}", .{index}), row.object.get("label").?.string);
                try std.testing.expectEqualStrings(kinds[index % kinds.len], row.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            }
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
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO session(session_ref,workspace,provider,model,instructions_content_id,tool_set_id,permission_mode," ++
                "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
                "SELECT 100000+value,'/','codex','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
            const many = TwinRounds.start(&storage);
            _ = try configureTestSession(&storage, "creation-rounds-many");
            try std.testing.expectEqual(few_rounds, many.taken());
        }
    }.run);
}

test "a Workspace's changed page reads only its own Sessions, however many others changed, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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

// 65 and 130 changed Sessions need more than eight ancestor statements, so the read Access sends extra passes inside
// the one round; the round count must not change.
test "Session list changed page round budget is the same for 1, 9, 64, 65 and 130 changed Sessions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            for ([_]usize{ 1, 9, 64, 65, 130 }, 0..) |count, round| {
                const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
                for (0..count) |index| {
                    var key: [32]u8 = undefined;
                    _ = try configure(&storage, try std.fmt.bufPrint(&key, "changed-budget-{d}-{d}", .{ round, index }), "", workspace);
                }
                var meter: RoundMeter = .{ .storage = &storage };
                meter.start();
                const page = try TestingListing.read(&storage, &tmp, .{ .since = since });
                try meter.stop(.readChangedSessionList);
                try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
                try std.testing.expectEqual(count > protocol.session_list_page_size, page.next != null);
                const measured = meter.measured.get(.readChangedSessionList).?;
                try std.testing.expectEqual(round_budgets.get(.readChangedSessionList), measured.rounds);
                if (case.engine == .mysql) try std.testing.expectEqual(measured.shape.expected(), measured.shape.queries);
            }
        }

        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = try store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..change_ring.id_bytes].*;
        }
    }.run);
}

// SH-110 drives one Session, where reading a page's work and settings per row or per page both take two passes. Eight
// changed Sessions fill one page and one changed_ancestors batch, so per-row statements would cost SQLite a pass per
// repeat: the page keeps its pass budget only when work_rows and list_rows are one statement each.
test "SH-110 a changed page of eight changed Sessions takes its pass budget on every engine" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            for (0..protocol.session_list_page_size) |index| {
                var key: [32]u8 = undefined;
                var command = try completeConfiguration(try std.fmt.bufPrint(&key, "changed-passes-{d}", .{index}), "", workspace, "model");
                try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
            }
            var meter: RoundMeter = .{ .storage = &storage };
            meter.start();
            const page = try TestingListing.read(&storage, &tmp, .{ .since = since });
            try meter.stop(.readChangedSessionList);
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try std.testing.expect(page.next == null);
            try std.testing.expectEqual(protocol.session_list_page_size, page.count);
            const measured = meter.measured.get(.readChangedSessionList).?;
            try std.testing.expectEqual(round_budgets.get(.readChangedSessionList), measured.rounds);
            try std.testing.expectEqual(@as(u64, pass_budgets.get(.readChangedSessionList).?), measured.shape.access_passes);
            if (case.engine == .mysql) try std.testing.expectEqual(measured.shape.expected(), measured.shape.queries);
        }
    }.run);
}

// The changed page reads its rows through the same row round as the full page, so a changed root's whole creator
// subtree and its descendants' work cost no round beyond the budget.
test "Session list changed page round budget holds for a changed root with sixteen descendants" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const root = try configure(&storage, "changed-subtree-root", "", workspace);
            var name: [48]u8 = undefined;
            for (0..16) |index| {
                const child = try configure(&storage, try std.fmt.bufPrint(&name, "changed-subtree-{d}", .{index}), "", workspace);
                try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &root, &child });
            }
            const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            _ = try configure(&storage, "changed-subtree-root-again", &root, workspace);
            var used = std.atomic.Value(u64).init(0);
            var meter: RoundMeter = .{ .storage = &storage };
            meter.start();
            const bytes = try testingSessionList(&storage, &tmp, .{ .since = since }, &used, 1);
            defer std.testing.allocator.free(bytes);
            try meter.stop(.readChangedSessionList);
            try std.testing.expectEqual(round_budgets.get(.readChangedSessionList), meter.measured.get(.readChangedSessionList).?.rounds);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("changed", parsed.value.object.get("delta").?.string);
            const rows = parsed.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), rows.len);
            try std.testing.expectEqualStrings(&root, rows[0].object.get("reference").?.string);
            try std.testing.expectEqualStrings("16", rows[0].object.get("descendant_count").?.string);
        }

        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = try store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..change_ring.id_bytes].*;
        }
    }.run);
}

// A creator cycle under a page root's subtree is refused on the full page too, not only on the changed page: the
// subtree fold refuses a row whose chain shows the cycle.
test "Session list refuses a creator cycle under a page root" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const healthy = try configureTestSession(&storage, "page-cycle-healthy");
            const child = try configureTestSession(&storage, "page-cycle-child");
            const left = try configureTestSession(&storage, "page-cycle-left");
            const right = try configureTestSession(&storage, "page-cycle-right");
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ healthy.slice(), child.slice() });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ right.slice(), left.slice() });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ left.slice(), right.slice() });
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 6));
        }
    }.run);
}

test "Session list changed page refuses a creator cycle among batched seeds beside a healthy chain" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            const root = try configure(&storage, "cycle-root", workspace);
            const child = try configure(&storage, "cycle-child", workspace);
            const left = try configure(&storage, "cycle-left", workspace);
            const right = try configure(&storage, "cycle-right", workspace);
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &root, &child });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &right, &left });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &left, &right });
            var used = std.atomic.Value(u64).init(0);
            // The healthy chain (child, root) and the cycle (left, right) share one batch of seeds. The root's chain
            // ends, so one cycle test over every row would miss the cycle beside it.
            try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{ .since = since }, &used, 6));
        }

        fn configure(store: *Store, key: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, "", place, "model");
            const configured = try store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..change_ring.id_bytes].*;
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

        fn stopped(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }

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

test "SL-3: Session list dates meaningful work transitions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try execution(case);
            try permissions(case, false);
            try permissions(case, true);
            try owed(case, false);
            try owed(case, true);
            inline for (.{ .continuation, .failure, .stop }) |outcome| try compaction(case, outcome);
            try missingProjection(case);
        }

        fn expectClock(store: *Store, tmp: *std.testing.TmpDir, session: []const u8, expected: u64) !void {
            var row = try testingListRow(store, tmp, session);
            defer row.deinit();
            try std.testing.expectEqual(expected, try row.number(&.{"state_change_at"}));
        }

        fn execution(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: Store = undefined;
            try store_testing.testingStore(case, &store, &tmp, std.testing.io);
            defer store.close() catch unreachable;
            const session = try configureTestSession(&store, "sl3-execution-config");
            try store_testing.exec(&store, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{session.slice()});
            try expectClock(&store, &tmp, session.slice(), 100);
            try submitTestMessage(&store, &tmp, "sl3-first", "sl3-first-key", session.slice(), "first");
            try store_testing.exec(&store, "UPDATE message_admission SET admitted_at=120 WHERE command_key='sl3-first-key'", .{});
            try expectClock(&store, &tmp, session.slice(), 120);
            const first = (try store.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.exec(&store, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
            try expectClock(&store, &tmp, session.slice(), 150);
            try store.settleModelAttemptFailure(first, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
            try expectClock(&store, &tmp, session.slice(), 150);
            try store_testing.exec(&store, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1", .{first.operation_id});
            const retry = (try shared_fixtures.admitRetryForTesting(&store)).?.permit.binding;
            try expectClock(&store, &tmp, session.slice(), 150);
            try store_testing.settleItemsForTesting(&store, &tmp, retry, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
            try store_testing.exec(&store, "UPDATE turn SET outcome_at=200 WHERE session_ref=?1", .{session.slice()});
            try expectClock(&store, &tmp, session.slice(), 200);
            try submitTestMessage(&store, &tmp, "sl3-queued", "sl3-queued-key", session.slice(), "next");
            try store_testing.exec(&store, "UPDATE message_admission SET admitted_at=300 WHERE command_key='sl3-queued-key'", .{});
            try expectClock(&store, &tmp, session.slice(), 300);
            var stop = try completeSessionStop("sl3-stop", session.slice());
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
            try store_testing.exec(&store, "UPDATE session_stop SET stopped_at=350 WHERE command_key='sl3-stop'", .{});
            try expectClock(&store, &tmp, session.slice(), 350);
        }

        fn permissions(case: *store_testing.Case, deny_last: bool) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: Store = undefined;
            try store_testing.testingStore(case, &store, &tmp, std.testing.io);
            defer store.close() catch unreachable;
            const session = try configureTestSessionAsk(&store, "sl3-permission-config");
            try submitTestMessage(&store, &tmp, "sl3-permission-input", "sl3-permission-key", session.slice(), "propose");
            const model = (try store.admitNextModelAttempt(.{})).?.permit.binding;
            try shared_fixtures.settleTwoActionsForTesting(&store, &tmp, model, "sl3-permission-tools");
            try store_testing.exec(&store, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{session.slice()});
            try store_testing.exec(&store, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
            try store_testing.exec(&store, "UPDATE model_operation SET resolved_at=200 WHERE session_ref=?1 AND resolved_at IS NOT NULL", .{session.slice()});
            try expectClock(&store, &tmp, session.slice(), 200);
            const first = try store_testing.queryU64(&store, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            const second = try store_testing.queryU64(&store, "SELECT max(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = first, .decision = .allow_once };
            try allow.key.set("sl3-first-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(store.decidePermission(&allow, .{}) == .accepted);
            try store_testing.exec(&store, "UPDATE action_operation SET decided_at=300 WHERE action_id=?1", .{first});
            try expectClock(&store, &tmp, session.slice(), 200);
            allow.action_id = second;
            allow.decision = if (deny_last) .deny else .allow_once;
            try allow.key.set("sl3-second-decision");
            try std.testing.expect(store.decidePermission(&allow, .{}) == .accepted);
            if (deny_last) {
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&store, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND decided_at IS NULL AND resolution_code='denied'", .{second}));
                try store_testing.exec(&store, "UPDATE action_operation SET resolved_at=400 WHERE action_id=?1", .{second});
            } else {
                try store_testing.exec(&store, "UPDATE action_operation SET decided_at=400 WHERE action_id=?1", .{second});
            }
            try expectClock(&store, &tmp, session.slice(), 400);
            const action = (try store.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            _ = try store.settleActionAttempt(action, .succeeded, "done", .{});
            try store_testing.exec(&store, "UPDATE action_operation SET resolved_at=500 WHERE action_id=?1", .{first});
            try expectClock(&store, &tmp, session.slice(), 400);
        }

        fn owed(case: *store_testing.Case, finished: bool) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: Store = undefined;
            try store_testing.testingStore(case, &store, &tmp, std.testing.io);
            defer store.close() catch unreachable;
            const root = try configureTestSession(&store, "sl3-owed-root");
            if (finished) {
                const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                try answerTestTurn(&store, &tmp, root.slice(), "sl3-owed-answer", &answer);
                try store_testing.exec(&store, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{root.slice()});
                try store_testing.exec(&store, "UPDATE turn SET outcome_at=200 WHERE session_ref=?1", .{root.slice()});
            }
            try store_testing.exec(&store, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{root.slice()});
            const child = try configureTestSession(&store, "sl3-owed-child");
            try store_testing.exec(&store, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
            try submitTestMessage(&store, &tmp, "sl3-owed-input", "sl3-owed-key", child.slice(), "work");
            try store_testing.exec(&store, "UPDATE message_admission SET admitted_at=300 WHERE command_key='sl3-owed-key'", .{});
            try shared_fixtures.refreshFrontierForTesting(&store, child.slice());
            try expectClock(&store, &tmp, root.slice(), 300);
        }

        const CompactionOutcome = enum { continuation, failure, stop };

        fn compaction(case: *store_testing.Case, outcome: CompactionOutcome) !void {
            errdefer std.debug.print("SL-3 compaction {s} failed\n", .{@tagName(outcome)});
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: Store = undefined;
            try store_testing.testingStore(case, &store, &tmp, std.testing.io);
            defer store.close() catch unreachable;
            const session = try configureTestSession(&store, "sl3-compaction-config");
            var patch: @import("../../wire_request.zig").ConfigureCommand = .{};
            try patch.key.set("sl3-compaction-settings");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(try store.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&store, &tmp, "sl3-compact-first", "sl3-compact-first-key", session.slice(), "original");
            const first = (try store.admitNextModelAttempt(.{})).?.permit.binding;
            try store.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            try submitTestMessage(&store, &tmp, "sl3-compact-next", "sl3-compact-next-key", session.slice(), "pending");
            try store_testing.exec(&store, "UPDATE session SET created_at=100 WHERE session_ref=?1", .{session.slice()});
            try store_testing.exec(&store, "UPDATE conversation_entry SET recorded_at=150 WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
            try store_testing.exec(&store, "UPDATE turn SET outcome_at=200 WHERE session_ref=?1 AND outcome_at IS NOT NULL", .{session.slice()});
            try store_testing.exec(&store, "UPDATE message_admission SET admitted_at=300 WHERE command_key='sl3-compact-next-key'", .{});
            const compact = (try store.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(@import("../domain/historical.zig").ModelOperationKind.compaction, try store.modelOperationKind(compact));
            try expectClock(&store, &tmp, session.slice(), 300);
            switch (outcome) {
                .continuation => {
                    try store.settleModelAttemptFailure(compact, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
                    try expectClock(&store, &tmp, session.slice(), 300);
                    try store_testing.exec(&store, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1", .{compact.operation_id});
                    const retry = (try shared_fixtures.admitRetryForTesting(&store)).?.permit.binding;
                    try expectClock(&store, &tmp, session.slice(), 300);
                    try store_testing.settleCompactionForTesting(&store, &tmp, retry, &.{.compaction});
                    _ = (try store.admitNextModelAttempt(.{})).?.permit.binding;
                    try store_testing.exec(&store, "UPDATE conversation_entry SET recorded_at=400 WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key='sl3-compact-next-key')", .{});
                },
                .failure => {
                    try store.settleModelAttemptFailure(compact, .{ .uncorrelated = "bad_compaction" }, .ordinary, .{});
                    try store_testing.exec(&store, "UPDATE turn SET outcome_at=400 WHERE turn_id=?1", .{compact.turn_id});
                },
                .stop => {
                    var stop = try completeSessionStop("sl3-compact-stop", session.slice());
                    try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
                    try store_testing.exec(&store, "UPDATE session_stop SET stopped_at=400 WHERE command_key='sl3-compact-stop'", .{});
                    try store_testing.exec(&store, "UPDATE turn SET outcome_at=400 WHERE turn_id=?1 AND outcome_at IS NOT NULL", .{compact.turn_id});
                },
            }
            try expectClock(&store, &tmp, session.slice(), 400);
        }

        fn missingProjection(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: Store = undefined;
            try store_testing.testingStore(case, &store, &tmp, std.testing.io);
            defer store.close() catch unreachable;
            const session = try configureTestSession(&store, "sl3-missing-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&store, &tmp, session.slice(), "sl3-missing-first", &answer);
            try answerTestTurn(&store, &tmp, session.slice(), "sl3-missing-latest", &answer);
            try store_testing.exec(&store, "DELETE FROM conversation_entry WHERE source_admission_id=(SELECT first_admission_id FROM turn WHERE session_ref=?1 ORDER BY turn_id DESC LIMIT 1)", .{session.slice()});
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.CorruptStore, testingSessionList(&store, &tmp, .{}, &used, 5));
        }
    }.run);
}

test "SL-4: changed Session pages include eligible creator ancestors" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const Change = struct {
                fn configure(store: *Store, workspace_path: []const u8, session: []const u8, ordinal: usize) !change_ring.Id {
                    var buffer: [64]u8 = undefined;
                    const key = try std.fmt.bufPrint(&buffer, "sl4-config-{d}", .{ordinal});
                    var command = try completeConfiguration(key, session, workspace_path, "model-a");
                    command.configuration.label.state = .value;
                    try command.configuration.label.value.set(try std.fmt.bufPrint(&buffer, "label-{d}", .{ordinal}));
                    const result = try store.configure(&command, .{});
                    try std.testing.expect(result == .accepted);
                    return result.accepted.session.slice()[0..change_ring.id_bytes].*;
                }

                fn expectArchive(store: *Store, dir: *std.testing.TmpDir, list: protocol.ListSessions, id: *const change_ring.Id, state: []const u8) !void {
                    var used = std.atomic.Value(u64).init(0);
                    const bytes = try testingSessionList(store, dir, list, &used, 104);
                    defer std.testing.allocator.free(bytes);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer parsed.deinit();
                    for (parsed.value.object.get("sessions").?.array.items) |row| {
                        if (!std.mem.eql(u8, row.object.get("reference").?.string, id)) continue;
                        try std.testing.expectEqualStrings(state, row.object.get("archive_state").?.string);
                        return;
                    }
                    return error.TestUnexpectedResult;
                }
            };
            var ids: [14]change_ring.Id = undefined;
            for (&ids, 0..) |*id, index| id.* = try Change.configure(&storage, workspace, "", index);
            std.mem.sort(change_ring.Id, &ids, {}, testingIdLess);
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &ids[0], &ids[1] });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ &ids[1], &ids[13] });
            const before = try TestingListing.read(&storage, &tmp, .{});
            for (ids[2..12], 0..) |id, index| _ = try Change.configure(&storage, workspace, &id, 20 + index);
            _ = try Change.configure(&storage, workspace, &ids[13], 40);
            var request: protocol.ListSessions = .{ .since = before.since };
            const first = try TestingListing.read(&storage, &tmp, request);
            try std.testing.expectEqual(protocol.ListDelta.changed, first.delta);
            try first.expectReferences(ids[0..8]);
            try std.testing.expect(first.next != null);
            const second = try TestingListing.read(&storage, &tmp, first.next.?);
            const expected_tail = [_]change_ring.Id{ ids[8], ids[9], ids[10], ids[11], ids[13] };
            try second.expectReferences(&expected_tail);
            try std.testing.expect(second.next == null);
            try std.testing.expectEqual(first.since.generation, second.since.generation);

            var archive: protocol.SessionArchiveCommand = .{ .archived = true };
            try archive.key.set("sl4-archive");
            try archive.session.set(&ids[1]);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            request.since = second.since;
            const removed = try TestingListing.read(&storage, &tmp, request);
            try removed.expectReferences(&.{ ids[0], ids[1] });
            try Change.expectArchive(&storage, &tmp, request, &ids[1], "archived");
            _ = try Change.configure(&storage, workspace, &ids[13], 41);
            request.since = removed.since;
            const cut = try TestingListing.read(&storage, &tmp, request);
            try cut.expectReferences(&.{ids[13]});
            archive.archived = false;
            try archive.key.set("sl4-restore");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            request.since = cut.since;
            const restored = try TestingListing.read(&storage, &tmp, request);
            try restored.expectReferences(&.{ ids[0], ids[1] });
            try Change.expectArchive(&storage, &tmp, request, &ids[1], "active");
        }
    }.run);
}

test "SL-1: Session list rolls up eligible descendants beyond the page" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var config = try completeConfiguration("rollup-root", "", workspace, "model-a");
            config.configuration.tools = try .of(&.{ "bash", "start_agent" });
            const root = (try storage.configure(&config, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "rollup-message", "rollup-key", root.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var calls: [10]TestingCall = undefined;
            for (&calls, 0..) |*call, index| {
                const id = try std.fmt.allocPrint(arena.allocator(), "rollup-child-{d}", .{index});
                call.* = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, model, "rollup-calls", &calls);
            const Capture = struct {
                child: protocol.Bounded(protocol.session_id_bytes) = .{},
                fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.child.set(admission.session) catch unreachable;
                }
            };
            var first: Capture = .{};
            for (0..calls.len) |index| {
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                var spec = try shared_fixtures.testingAgentSpec(&.{ "bash", "start_agent" }, "ask");
                var capture: Capture = .{};
                try std.testing.expect(try storage.startAgent(action.binding, root.slice(), "child task", index == 0, &spec, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
                if (index == 0) first = capture;
            }
            const child_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND session_ref=?2", .{ child_model.turn_id, first.child.slice() }));
            try settleCallsForTesting(&storage, &tmp, child_model, "rollup-nested-call", &.{.{
                .item_id = "rollup-nested",
                .name = "start_agent",
                .encoded_call_id = "rollup-nested",
                .decoded_call_id = "rollup-nested",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const nested_action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            var nested_spec = try shared_fixtures.testingAgentSpec(&.{"bash"}, "ask");
            var nested: Capture = .{};
            try std.testing.expect(try storage.startAgent(nested_action.binding, first.child.slice(), "nested task", false, &nested_spec, .{ .context = &nested, .call = Capture.call }, .{}) == .started);
            var reached_nested = false;
            var before_question: protocol.SinceToken = undefined;
            for (0..20) |_| {
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const is_nested = try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND session_ref=?2", .{ next.turn_id, nested.child.slice() });
                if (is_nested == 1) {
                    before_question = (try TestingListing.read(&storage, &tmp, .{})).since;
                    try settleCallsForTesting(&storage, &tmp, next, "rollup-question", &.{.{
                        .item_id = "rollup-bash",
                        .name = "bash",
                        .encoded_call_id = "rollup-bash",
                        .decoded_call_id = "rollup-bash",
                        .encoded_arguments = "{\\\"description\\\":\\\"Review\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Review\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    }});
                    reached_nested = true;
                    break;
                }
                try store_testing.settleItemsForTesting(&storage, &tmp, next, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
            }
            try std.testing.expect(reached_nested);
            var affected = [_]change_ring.Id{
                root.slice()[0..change_ring.id_bytes].*,
                first.child.slice()[0..change_ring.id_bytes].*,
                nested.child.slice()[0..change_ring.id_bytes].*,
            };
            std.mem.sort(change_ring.Id, &affected, {}, testingIdLess);
            const delta = try TestingListing.read(&storage, &tmp, .{ .since = before_question });
            try std.testing.expectEqual(protocol.ListDelta.changed, delta.delta);
            try delta.expectReferences(&affected);
            try store_testing.exec(&storage, "UPDATE session SET created_at=100 WHERE created_at>0", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=110 WHERE admitted_at>0", .{});
            try store_testing.exec(&storage, "UPDATE conversation_entry SET recorded_at=CASE WHEN session_ref=?1 THEN 300 WHEN session_ref=?2 THEN 200 ELSE 150 END WHERE recorded_at>0", .{ nested.child.slice(), first.child.slice() });
            try store_testing.exec(&storage, "UPDATE turn SET outcome_at=CASE WHEN session_ref=?1 THEN 150 WHEN session_ref=?2 THEN 200 ELSE 180 END WHERE outcome_at IS NOT NULL", .{ root.slice(), first.child.slice() });
            try store_testing.exec(&storage, "UPDATE model_operation SET resolved_at=CASE WHEN session_ref=?1 THEN 400 ELSE 150 END WHERE resolved_at IS NOT NULL", .{nested.child.slice()});
            var root_row = try testingListRow(&storage, &tmp, root.slice());
            defer root_row.deinit();
            try std.testing.expectEqual(@as(u64, 11), try root_row.number(&.{"descendant_count"}));
            try std.testing.expectEqual(@as(u64, 1), try root_row.number(&.{"descendant_needs_you_count"}));
            try std.testing.expect((try root_row.number(&.{"subtree_state_change_at"})) >= (try root_row.number(&.{"state_change_at"})));
            try std.testing.expectEqual(@as(u64, 150), try root_row.number(&.{"state_change_at"}));
            try std.testing.expectEqual(@as(u64, 400), try root_row.number(&.{"subtree_state_change_at"}));
            var child_row = try testingListRow(&storage, &tmp, first.child.slice());
            defer child_row.deinit();
            try std.testing.expectEqual(@as(u64, 200), try child_row.number(&.{"state_change_at"}));
            try std.testing.expectEqual(@as(u64, 400), try child_row.number(&.{"subtree_state_change_at"}));
            try std.testing.expectEqual(@as(u64, 1), try child_row.number(&.{"descendant_count"}));
            try std.testing.expectEqual(@as(u64, 1), try child_row.number(&.{"descendant_needs_you_count"}));
            const first_page = try TestingListing.read(&storage, &tmp, .{});
            var used = std.atomic.Value(u64).init(0);
            const later_bytes = try testingSessionList(&storage, &tmp, first_page.next.?, &used, 78);
            defer std.testing.allocator.free(later_bytes);
            var later_page = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, later_bytes, .{});
            defer later_page.deinit();
            var leaf_found = false;
            for (later_page.value.object.get("sessions").?.array.items) |row| {
                if (!std.mem.eql(u8, row.object.get("reference").?.string, nested.child.slice())) continue;
                try std.testing.expectEqualStrings("400", row.object.get("state_change_at").?.string);
                try std.testing.expectEqualStrings("400", row.object.get("subtree_state_change_at").?.string);
                leaf_found = true;
            }
            try std.testing.expect(leaf_found);
            var samples: [5]u64 = undefined;
            for (&samples) |*sample| {
                var counter: store_testing.ReadWork = .{};
                try counter.begin(case, &storage);
                var measured = testingListRow(&storage, &tmp, root.slice()) catch |err| {
                    counter.cancel();
                    return err;
                };
                defer measured.deinit();
                sample.* = try counter.finish();
                try std.testing.expectEqual(@as(u64, 150), try measured.number(&.{"state_change_at"}));
                try std.testing.expectEqual(@as(u64, 400), try measured.number(&.{"subtree_state_change_at"}));
                try std.testing.expectEqual(@as(u64, 11), try measured.number(&.{"descendant_count"}));
                try std.testing.expectEqual(@as(u64, 1), try measured.number(&.{"descendant_needs_you_count"}));
                try std.testing.expect(sample.* > 0);
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            std.debug.print("list rollup three-level, eleven descendants ({s}, five warmed pages): min={d} median={d} max={d} {s}\n", .{ @tagName(case.engine), samples[0], samples[2], samples[4], switch (case.engine) {
                .sqlite => "SQLite VM steps",
                .mysql => "MySQL handler reads",
            } });

            // A second, idle chain isolates archive eligibility from the active work above.
            const filter_root = try configureTestSession(&storage, "rollup-filter-root");
            const filter_child = try configureTestSession(&storage, "rollup-filter-child");
            const filter_leaf = try configureTestSession(&storage, "rollup-filter-leaf");
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ filter_root.slice(), filter_child.slice() });
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ filter_child.slice(), filter_leaf.slice() });
            var archive: protocol.SessionArchiveCommand = .{ .session = filter_child, .archived = true };
            try archive.key.set("rollup-filter-archive");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try store_testing.exec(&storage, "UPDATE session SET created_at=CASE WHEN session_ref=?1 THEN 100 WHEN session_ref=?2 THEN 200 ELSE 300 END WHERE session_ref IN (?1,?2,?3)", .{ filter_root.slice(), filter_child.slice(), filter_leaf.slice() });
            try store_testing.exec(&storage, "UPDATE session_stop SET stopped_at=200 WHERE session_ref=?1", .{filter_child.slice()});
            const start = try store_testing.queryU64(&storage, "SELECT created_seq FROM session WHERE session_ref=?1", .{filter_root.slice()});
            const end = try store_testing.queryU64(&storage, "SELECT created_seq FROM session WHERE session_ref=?1", .{filter_leaf.slice()});
            const ids = [3][]const u8{ filter_root.slice(), filter_child.slice(), filter_leaf.slice() };
            var other_workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other_workspace = other_workspace_buffer[0..try tmp.dir.realPath(std.testing.io, &other_workspace_buffer)];
            const cases = [_]struct {
                filter: protocol.SessionArchiveFilter,
                scope: enum { any, matching, other } = .any,
                visible: [3]bool,
                own: [3]u64,
                subtree: [3]u64,
                descendants: [3]u64,
            }{
                .{ .filter = .active, .visible = .{ true, false, true }, .own = .{ 100, 0, 300 }, .subtree = .{ 100, 0, 300 }, .descendants = .{ 0, 0, 0 } },
                .{ .filter = .archived, .visible = .{ false, true, false }, .own = .{ 0, 200, 0 }, .subtree = .{ 0, 200, 0 }, .descendants = .{ 0, 0, 0 } },
                .{ .filter = .all, .visible = .{ true, true, true }, .own = .{ 100, 200, 300 }, .subtree = .{ 300, 300, 300 }, .descendants = .{ 2, 1, 0 } },
                .{ .filter = .all, .scope = .matching, .visible = .{ true, true, true }, .own = .{ 100, 200, 300 }, .subtree = .{ 300, 300, 300 }, .descendants = .{ 2, 1, 0 } },
                .{ .filter = .all, .scope = .other, .visible = .{ false, false, false }, .own = .{ 0, 0, 0 }, .subtree = .{ 0, 0, 0 }, .descendants = .{ 0, 0, 0 } },
            };
            for (cases) |filter_case| {
                var request: protocol.ListSessions = .{ .archive = filter_case.filter, .after = start - 1, .ceiling = end };
                if (filter_case.scope != .any) {
                    request.workspace = .{};
                    try request.workspace.?.set(if (filter_case.scope == .matching) workspace else other_workspace);
                }
                const bytes = try testingSessionList(&storage, &tmp, request, &used, 103);
                defer std.testing.allocator.free(bytes);
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer parsed.deinit();
                const rows = parsed.value.object.get("sessions").?.array.items;
                var row_index: usize = 0;
                for (ids, filter_case.visible, 0..) |id, visible, index| {
                    if (!visible) continue;
                    try std.testing.expect(row_index < rows.len);
                    const row = rows[row_index].object;
                    row_index += 1;
                    try std.testing.expectEqualStrings(id, row.get("reference").?.string);
                    try std.testing.expectEqual(filter_case.own[index], try std.fmt.parseInt(u64, row.get("state_change_at").?.string, 10));
                    try std.testing.expectEqual(filter_case.subtree[index], try std.fmt.parseInt(u64, row.get("subtree_state_change_at").?.string, 10));
                    try std.testing.expectEqual(filter_case.descendants[index], try std.fmt.parseInt(u64, row.get("descendant_count").?.string, 10));
                    try std.testing.expectEqual(@as(u64, 0), try std.fmt.parseInt(u64, row.get("descendant_needs_you_count").?.string, 10));
                }
                try std.testing.expectEqual(row_index, rows.len);
            }
        }
    }.run);
}

const session_work = @import("../../session_work.zig");

test "SL-6: a Session's one-statement work is its staged work, for every stage outcome" {
    try store_testing.forEachEngine(struct {
        const Shape = enum { idle, queued, live, awaiting, running, live_stopping, stopping_with_child, finished, finished_then_queued, stopped, stopped_then_queued, stopped_then_admitted, owed, resolved_plain, resolved_promoted_first, resolved_promoted_second, ended_with_approval };
        const now_ms: u64 = 4_000_000_000_000;

        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(Shape)) |shape| check(case, shape) catch |err| {
                std.debug.print("SL-6 shape {s}: {t}\n", .{ @tagName(shape), err });
                return err;
            };
        }

        // Each shape reaches the stage it is named for (`reached`), so a shape that reads nothing cannot pass by agreeing
        // with nothing. The expected kind is the owner's, the staged machine's answer for the same fixture.
        fn check(case: *store_testing.Case, shape: Shape) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try setup(&storage, &tmp, shape);
            const compared = try shared_fixtures.compareWorkForTesting(&storage, session.slice());
            try compared.status;
            const created_at = try store_testing.queryU64(&storage, "SELECT created_at FROM session WHERE session_ref=?1", .{session.slice()});
            const work = try compared.staged.work(created_at, now_ms);
            const one = try compared.one.work(created_at, now_ms);
            try std.testing.expectEqualDeep(work, one);
            try std.testing.expectEqual(expectedKind(shape), std.meta.activeTag(work.state));
            // The ended Turn's background Action still awaits its decision: the store holds it, and first_action names it.
            if (shape == .ended_with_approval) {
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL AND authorized=0 AND background_position IS NOT NULL", .{}));
                try std.testing.expect(compared.staged.inputs.first_action != null);
            }
            try std.testing.expect(reached(shape, &compared.staged));
        }

        fn expectedKind(shape: Shape) session_work.Kind {
            return switch (shape) {
                .idle => .idle,
                .owed => .working,
                // Every Action resolved: the continuation is due, so the Turn is pending.
                .resolved_plain, .resolved_promoted_first, .resolved_promoted_second => .pending,
                .queued, .finished_then_queued, .stopped_then_queued => .pending,
                .live => .working,
                .awaiting => .approval,
                .running => .bash,
                .live_stopping => .stopping,
                // An owed attached child keeps the stopped Turn working, as the staged machine derives it.
                .stopping_with_child => .working,
                .finished => .finished,
                .stopped => .stopped,
                .stopped_then_admitted => .working,
                // A background approval still awaiting its decision keeps the ended Turn's Session working. The Turn is
                // ended, so the state is the derived working, not approval: the approval is read through first_action only.
                .ended_with_approval => .working,
            };
        }

        fn reached(shape: Shape, staged: *const report_domain.WorkRead) bool {
            const turn = staged.inputs.latest;
            return switch (shape) {
                .idle => turn == null,
                .queued => staged.inputs.oldest_pending != null,
                .live => turn != null and turn.?.terminal == null and turn.?.actions.total == 0,
                .awaiting => staged.inputs.first_action != null and turn.?.actions.awaiting != 0,
                .running => turn.?.actions.oldest_running != null,
                .live_stopping => turn != null and turn.?.stopped_at != null,
                .stopping_with_child => turn != null and turn.?.stop_remaining,
                .finished => turn != null and turn.?.terminal != null,
                .finished_then_queued => staged.inputs.oldest_pending != null and turn != null,
                .stopped => staged.inputs.excluded != null,
                .stopped_then_queued => staged.inputs.oldest_pending != null,
                // The new Turn admitted the Message behind the stop, so nothing is pending or excluded.
                .stopped_then_admitted => turn != null and turn.?.terminal == null and staged.inputs.oldest_pending == null and staged.inputs.excluded == null,
                .ended_with_approval => turn != null and turn.?.terminal != null and staged.inputs.first_action != null,
                .owed => staged.inputs.owed_since != null,
                .resolved_plain, .resolved_promoted_first, .resolved_promoted_second => turn != null and turn.?.actions.total == 2 and turn.?.actions.latest_resolution_at != null,
            };
        }

        fn setup(storage: *Store, tmp: *std.testing.TmpDir, shape: Shape) !protocol.Bounded(protocol.max_session_bytes) {
            switch (shape) {
                .idle => return configureTestSession(storage, "sl6-idle"),
                .queued => {
                    const session = try configureTestSession(storage, "sl6-queued");
                    try submitTestMessage(storage, tmp, "sl6-queued-file", "sl6-queued-message", session.slice(), "queued");
                    return session;
                },
                .live => {
                    const session = try configureTestSessionAsk(storage, "sl6-live");
                    try submitTestMessage(storage, tmp, "sl6-live-file", "sl6-live-message", session.slice(), "propose");
                    _ = (try storage.admitNextModelAttempt(.{})).?;
                    return session;
                },
                .awaiting => return (try awaitingSession(storage, tmp, "sl6-awaiting")),
                .running => return shared_fixtures.TestingWorkShape.running.make(storage, tmp, "sl6-running"),
                .live_stopping => {
                    const session = try shared_fixtures.TestingWorkShape.running.make(storage, tmp, "sl6-stopping");
                    try stopForTesting(storage, session.slice(), "sl6-stopping-stop");
                    return session;
                },
                .stopping_with_child => {
                    // A stopped Turn whose attached child still owes work: the Turn's stop_remaining reads the child
                    // through firstChildSql, which must name the outer Session, not a shadowing `session` table.
                    const parent = try configureTestSessionAsk(storage, "sl6-parent");
                    try submitTestMessage(storage, tmp, "sl6-parent-file", "sl6-parent-message", parent.slice(), "propose");
                    _ = (try storage.admitNextModelAttempt(.{})).?;
                    const child = try configureTestSessionAsk(storage, "sl6-child");
                    try store_testing.exec(storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                    try submitTestMessage(storage, tmp, "sl6-child-file", "sl6-child-message", child.slice(), "work");
                    _ = (try storage.admitNextModelAttempt(.{})).?;
                    try stopForTesting(storage, parent.slice(), "sl6-parent-stop");
                    return parent;
                },
                .finished => return shared_fixtures.TestingWorkShape.finished.make(storage, tmp, "sl6-finished"),
                .finished_then_queued => {
                    const session = try shared_fixtures.TestingWorkShape.finished.make(storage, tmp, "sl6-finished-queued");
                    try submitTestMessage(storage, tmp, "sl6-finished-queued-file", "sl6-finished-queued-message", session.slice(), "queued after the end");
                    return session;
                },
                .stopped => return shared_fixtures.TestingWorkShape.stopped.make(storage, tmp, "sl6-stopped"),
                .stopped_then_queued => {
                    const session = try shared_fixtures.TestingWorkShape.stopped.make(storage, tmp, "sl6-stopped-queued");
                    try submitTestMessage(storage, tmp, "sl6-stopped-queued-file", "sl6-stopped-queued-message", session.slice(), "after the stop");
                    return session;
                },
                .resolved_plain, .resolved_promoted_first, .resolved_promoted_second => {
                    // Two Actions denied in one live Turn, the first at a later resolution time than the second, so the
                    // latest Resolution is by acceptance position, not by clock. A promoted Action's background result is
                    // the other probe of the union; each promotion picks which Action it is.
                    const session = try configureTestSessionAsk(storage, "sl6-resolved");
                    try submitTestMessage(storage, tmp, "sl6-resolved-file", "sl6-resolved-message", session.slice(), "propose");
                    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try shared_fixtures.settleTwoActionsForTesting(storage, tmp, binding, "sl6-resolved-calls");
                    const first = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation WHERE parent_operation_id=?1", .{binding.operation_id});
                    const last = try store_testing.queryU64(storage, "SELECT max(action_id) FROM action_operation WHERE parent_operation_id=?1", .{binding.operation_id});
                    const promoted: ?u64 = switch (shape) {
                        .resolved_promoted_first => first,
                        .resolved_promoted_second => last,
                        else => null,
                    };
                    if (promoted) |action_id| {
                        var command: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = action_id };
                        try command.key.set("sl6-resolved-promote");
                        try std.testing.expect(storage.backgroundAction(.{ .command = &command }, .{}) == .accepted);
                    }
                    for ([_]u64{ first, last }, [_]u64{ 900, 400 }, [_][]const u8{ "sl6-resolved-first", "sl6-resolved-last" }) |action, at, key| {
                        var deny: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .deny };
                        try deny.key.set(key);
                        try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
                        try store_testing.exec(storage, "UPDATE action_operation SET resolved_at=?1 WHERE action_id=?2", .{ at, action });
                    }
                    return session;
                },
                .stopped_then_admitted => {
                    const session = try shared_fixtures.TestingWorkShape.stopped.make(storage, tmp, "sl6-stopped-admitted");
                    try submitTestMessage(storage, tmp, "sl6-stopped-admitted-file", "sl6-stopped-admitted-message", session.slice(), "admitted after the stop");
                    _ = (try storage.admitNextModelAttempt(.{})).?;
                    return session;
                },
                .ended_with_approval => {
                    // Case 13: a bash Action awaits its decision, is promoted to background before the Turn ends, and the
                    // Turn then ends. Its approval is still open on an ended Turn, so only the cutoff stage's approval reads it.
                    const session = try configureTestSessionAsk(storage, "sl6-ended-approval");
                    try submitTestMessage(storage, tmp, "sl6-ended-approval-file", "sl6-ended-approval-message", session.slice(), "propose");
                    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCallsForTesting(storage, tmp, binding, "sl6-ended-approval-calls", &.{.{
                        .item_id = "sl6-ended-approval-item",
                        .name = "bash",
                        .encoded_call_id = "sl6-ended-approval-call",
                        .decoded_call_id = "sl6-ended-approval-call",
                        .encoded_arguments = "{\\\"description\\\":\\\"Review\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Review\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    }});
                    const action_id = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation WHERE parent_operation_id=?1", .{binding.operation_id});
                    var promotion: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = action_id };
                    try promotion.key.set("sl6-ended-approval-background");
                    try std.testing.expect(storage.backgroundAction(.{ .command = &promotion }, .{}) == .accepted);
                    // Promotion answers the call, so the model runs again; that continuation ends the Turn with a final
                    // answer. No Message is admitted, so nothing declines the approval and firstApprovalSql still names it.
                    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                    try store_testing.settleAnswerTestTurn(storage, tmp, continuation, "sl6-ended-approval-answer", &answer);
                    return session;
                },
                .owed => {
                    const session = try configureTestSession(storage, "sl6-owed");
                    try store_testing.exec(storage, "UPDATE session SET obligation_since=?1 WHERE session_ref=?2", .{ @as(u64, 1), session.slice() });
                    return session;
                },
            }
        }

        fn awaitingSession(storage: *Store, tmp: *std.testing.TmpDir, comptime name: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
            return shared_fixtures.TestingWorkShape.awaiting.make(storage, tmp, name);
        }

        fn stopForTesting(storage: *Store, session: []const u8, key: []const u8) !void {
            var stop = try completeSessionStop(key, session);
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        }
    }.run);
}

// SL-8. The expected rollup is the fold of each descendant's own list row, the U3 path (work_row and WorkRead.decode,
// tied to the staged machine by SL-6), never the subtree statement under test. The children span every work shape the
// list derives, including the stopped parent whose stop_remaining reads its attached child.
test "SL-8: a creator subtree's rollup is its descendants' own rows, for every work shape" {
    try store_testing.forEachEngine(struct {
        const Seen = struct { reference: change_ring.Id, state_change_at: u64, subtree_state_change_at: u64, descendants: u64, needs_you_descendants: u64, needs_you: bool };

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "sl8-root");
            var children: [12]protocol.Bounded(protocol.max_session_bytes) = undefined;
            var count: usize = 0;
            // Admission takes the next runnable Session in the whole Store, so each fixture that admits runs while no
            // other Session has runnable work, and the stopping Session with queued work comes last.
            children[count] = try running(&storage, &tmp, "sl8-running", false);
            count += 1;
            children[count] = try live(&storage, &tmp, "sl8-live");
            count += 1;
            children[count] = try shared_fixtures.TestingWorkShape.awaiting.make(&storage, &tmp, "sl8-awaiting");
            count += 1;
            children[count] = try retrying(&storage, &tmp, "sl8-retrying");
            count += 1;
            children[count] = try shared_fixtures.TestingWorkShape.finished.make(&storage, &tmp, "sl8-finished");
            count += 1;
            const stopped = try shared_fixtures.TestingWorkShape.stopped.make(&storage, &tmp, "sl8-stopped");
            children[count] = stopped;
            count += 1;
            children[count] = try shared_fixtures.TestingWorkShape.idle.make(&storage, &tmp, "sl8-idle");
            count += 1;
            const owed = try configureTestSession(&storage, "sl8-owed");
            try store_testing.exec(&storage, "UPDATE session SET obligation_since=?1 WHERE session_ref=?2", .{ @as(u64, 1), owed.slice() });
            children[count] = owed;
            count += 1;
            children[count] = try stoppingWithChild(&storage, &tmp);
            count += 1;
            children[count] = try running(&storage, &tmp, "sl8-stopping-queued", true);
            count += 1;
            for (children[0..count]) |*child| try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
            const grandchild = try configureTestSession(&storage, "sl8-grandchild");
            try store_testing.exec(&storage, "UPDATE session SET creator_ref=?1 WHERE session_ref=?2", .{ stopped.slice(), grandchild.slice() });

            var seen: [32]Seen = undefined;
            const rows = seen[0..try readAll(&storage, &tmp, &seen)];
            var descendants: [13][]const u8 = undefined;
            for (children[0..count], descendants[0..count]) |*child, *slot| slot.* = child.slice();
            descendants[count] = grandchild.slice();
            try expectRollup(rows, root.slice(), descendants[0 .. count + 1]);
            try expectRollup(rows, stopped.slice(), &.{grandchild.slice()});
            // The fixtures reach the groups the rollup counts: some descendant needs you and some does not.
            const root_row = find(rows, root.slice()).?;
            try std.testing.expect(root_row.needs_you_descendants != 0 and root_row.needs_you_descendants < root_row.descendants);
        }

        fn expectRollup(rows: []const Seen, reference: []const u8, descendants: []const []const u8) !void {
            const row = find(rows, reference) orelse return error.TestUnexpectedResult;
            var latest = row.state_change_at;
            var needs_you: u64 = 0;
            for (descendants) |descendant| {
                const own = find(rows, descendant) orelse return error.TestUnexpectedResult;
                latest = @max(latest, own.state_change_at);
                if (own.needs_you) needs_you += 1;
            }
            try std.testing.expectEqual(@as(u64, descendants.len), row.descendants);
            try std.testing.expectEqual(needs_you, row.needs_you_descendants);
            try std.testing.expectEqual(latest, row.subtree_state_change_at);
        }

        fn find(rows: []const Seen, reference: []const u8) ?*const Seen {
            for (rows) |*row| if (std.mem.eql(u8, &row.reference, reference)) return row;
            return null;
        }

        /// Every list page's rows, walked by the page cursor.
        fn readAll(storage: *Store, tmp: *std.testing.TmpDir, seen: []Seen) !usize {
            var request: protocol.ListSessions = .{};
            var total: usize = 0;
            while (true) {
                var used = std.atomic.Value(u64).init(0);
                const bytes = try testingSessionList(storage, tmp, request, &used, 8);
                defer std.testing.allocator.free(bytes);
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer parsed.deinit();
                const object = parsed.value.object;
                for (object.get("sessions").?.array.items) |item| {
                    const row = item.object;
                    seen[total] = .{
                        .reference = row.get("reference").?.string[0..change_ring.id_bytes].*,
                        .state_change_at = try number(row, "state_change_at"),
                        .subtree_state_change_at = try number(row, "subtree_state_change_at"),
                        .descendants = try number(row, "descendant_count"),
                        .needs_you_descendants = try number(row, "descendant_needs_you_count"),
                        // The row's own work asks for a decision: an approval, a Bash proposal with approvals pending, or any state with a decision served.
                        .needs_you = asksForDecision(row.get("work").?.object),
                    };
                    total += 1;
                }
                if (object.get("next").? != .object) return total;
                const next = object.get("next").?.object;
                request = .{ .after = try number(next, "after"), .ceiling = try number(next, "ceiling") };
            }
        }

        fn number(object: std.json.ObjectMap, name: []const u8) !u64 {
            return std.fmt.parseInt(u64, object.get(name).?.string, 10);
        }

        fn asksForDecision(work: std.json.ObjectMap) bool {
            if (work.get("actions").?.object.get("decide").? != .null) return true;
            const state = work.get("state").?.object;
            const kind = state.get("kind").?.string;
            if (std.mem.eql(u8, kind, "approval")) return true;
            return std.mem.eql(u8, kind, "bash") and !std.mem.eql(u8, state.get("approvals").?.string, "0");
        }

        /// An approval allowed once and admitted, so its Action runs in a live Turn; with `stop_queued`, the Session
        /// is then stopped and a Message queued behind the stop.
        fn running(storage: *Store, tmp: *std.testing.TmpDir, comptime name: []const u8, stop_queued: bool) !protocol.Bounded(protocol.max_session_bytes) {
            const session = try shared_fixtures.TestingWorkShape.awaiting.make(storage, tmp, name);
            const action = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
            try allow.key.set(name ++ "-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            _ = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?;
            if (stop_queued) {
                var stop = try completeSessionStop(name ++ "-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try submitTestMessage(storage, tmp, name ++ "-queued-file", name ++ "-queued", session.slice(), "after the stop");
            }
            return session;
        }

        fn live(storage: *Store, tmp: *std.testing.TmpDir, comptime name: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
            const session = try configureTestSessionAsk(storage, name);
            try submitTestMessage(storage, tmp, name ++ "-file", name ++ "-message", session.slice(), "propose");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            return session;
        }

        fn retrying(storage: *Store, tmp: *std.testing.TmpDir, comptime name: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
            const session = try configureTestSession(storage, name);
            try submitTestMessage(storage, tmp, name ++ "-file", name ++ "-message", session.slice(), "first");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(model, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
            return session;
        }

        /// SL-6's stopping_with_child: a stopped Turn whose attached child still owes work.
        fn stoppingWithChild(storage: *Store, tmp: *std.testing.TmpDir) !protocol.Bounded(protocol.max_session_bytes) {
            const parent = try live(storage, tmp, "sl8-parent");
            const child = try configureTestSessionAsk(storage, "sl8-attached");
            try store_testing.exec(storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
            try submitTestMessage(storage, tmp, "sl8-attached-file", "sl8-attached-message", child.slice(), "work");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            var stop = try completeSessionStop("sl8-parent-stop", parent.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            return parent;
        }
    }.run);
}
