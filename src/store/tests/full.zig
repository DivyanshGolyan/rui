//! Full Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const session_report = @import("../../session_report.zig");
const session_report_read_domain = @import("../domain/session_report_read.zig");
const store_testing = @import("../testing.zig");
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingReportReply = shared_fixtures.TestingReportReply;
const TwinRounds = shared_fixtures.TwinRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingContent = shared_fixtures.testingContent;
const testingFullHistory = shared_fixtures.testingFullHistory;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "Full revisions own repeated content once and render semantic settings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("revision-owner-1", "", workspace, "model-a");
            initial.configuration.tools.state = .value;
            initial.configuration.tools = try .of(&.{"bash"});
            initial.configuration.permission_mode.state = .value;
            try initial.configuration.permission_mode.value.set("ask");
            initial.configuration.instructions = try testingContent(&tmp, "revision-owner-instructions", 1, 64 * 1024);
            const schema_a = "{}";
            initial.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a", schema_a);
            defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = try storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            var second: wire_request.ConfigureCommand = .{};
            try second.key.set("revision-owner-2");
            try second.session.set(created_session_0.slice());
            second.configuration.tools.state = .value;
            second.configuration.tools.count = 0;
            second.configuration.permission_mode.state = .value;
            try second.configuration.permission_mode.value.set("bypass");
            const schema_b = "{\"type\":\"object\"}";
            second.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-b", schema_b);
            defer second.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&second, .{}) == .accepted);

            var third: wire_request.ConfigureCommand = .{};
            try third.key.set("revision-owner-3");
            try third.session.set(created_session_0.slice());
            third.configuration.tools.state = .value;
            third.configuration.tools = try .of(&.{"bash"});
            third.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a-again", schema_a);
            defer third.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&third, .{}) == .accepted);

            var fourth: wire_request.ConfigureCommand = .{};
            try fourth.key.set("revision-owner-4");
            try fourth.session.set(created_session_0.slice());
            fourth.configuration.tools.state = .value;
            fourth.configuration.tools.count = 0;
            try std.testing.expect(try storage.configure(&fourth, .{}) == .accepted);

            var fifth: wire_request.ConfigureCommand = .{};
            try fifth.key.set("revision-owner-5");
            try fifth.session.set(created_session_0.slice());
            fifth.configuration.instructions = try testingBytesContent(&tmp, "revision-owner-instructions-schema-a", schema_a);
            defer fifth.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&fifth, .{}) == .accepted);

            const full = try testingSessionReportWithProfile(&storage, &tmp, created_session_0.slice(), 512 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const revisions = parsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
            try std.testing.expectEqual(@as(usize, 5), revisions.len);

            const first = revisions[0].object;
            const first_instructions = first.get("instructions").?.object;
            try std.testing.expectEqual(@as(usize, 64 * 1024), first_instructions.get("text").?.string.len);
            for (first_instructions.get("text").?.string) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
            try std.testing.expectEqualStrings(schema_a, first.get("output_schema").?.object.get("text").?.string);

            for (revisions[1..4]) |revision| {
                const owner = revision.object.get("instructions").?.object.get("owner").?.object;
                try std.testing.expectEqualStrings("1", owner.get("revision").?.string);
                try std.testing.expectEqualStrings("instructions", owner.get("field").?.string);
                try std.testing.expect(revision.object.get("tools_mask") == null);
                try std.testing.expectEqualStrings("bypass", revision.object.get("permission_mode").?.string);
            }
            const fifth_instruction_owner = revisions[4].object.get("instructions").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", fifth_instruction_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", fifth_instruction_owner.get("field").?.string);
            const third_schema_owner = revisions[2].object.get("output_schema").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", third_schema_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", third_schema_owner.get("field").?.string);
            const fourth_schema_owner = revisions[3].object.get("output_schema").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", fourth_schema_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", fourth_schema_owner.get("field").?.string);

            const expected_tools = [_][]const []const u8{
                &.{"bash"},
                &.{},
                &.{"bash"},
                &.{},
                &.{},
            };
            for (revisions, expected_tools) |revision, expected| {
                const tools = revision.object.get("tools").?.array.items;
                try std.testing.expectEqual(expected.len, tools.len);
                for (tools, expected) |actual, name| try std.testing.expectEqualStrings(name, actual.string);
            }
        }
    }.run);
}

test "Full attributes unbound Messages to the earliest covering stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "stop-merge-config");

            try submitTestMessage(&storage, &tmp, "stop-merge-message-1-file", "stop-merge-message-1", session.slice(), "one");
            var first_stop = try completeSessionStop("z-first-stop", session.slice());
            try std.testing.expect(storage.stopSession(&first_stop, .{}) == .accepted);
            var same_cutoff_stop = try completeSessionStop("a-second-stop", session.slice());
            try std.testing.expect(storage.stopSession(&same_cutoff_stop, .{}) == .accepted);

            try submitTestMessage(&storage, &tmp, "stop-merge-message-2-file", "stop-merge-message-2", session.slice(), "two");
            var later_stop = try completeSessionStop("m-third-stop", session.slice());
            try std.testing.expect(storage.stopSession(&later_stop, .{}) == .accepted);

            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const messages = parsed.value.object.get("full").?.object.get("messages").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), messages.len);
            try std.testing.expectEqualStrings("z-first-stop", messages[0].object.get("exclusion").?.object.get("command_key").?.string);
            try std.testing.expectEqualStrings("m-third-stop", messages[1].object.get("exclusion").?.object.get("command_key").?.string);
            const first_observation = (try store_testing.observeCommandForTesting(&storage, "stop-merge-message-1")).kind.message.?.queue.?.state.excluded;
            const second_observation = (try store_testing.observeCommandForTesting(&storage, "stop-merge-message-2")).kind.message.?.queue.?.state.excluded;
            try std.testing.expectEqualStrings("session_stopped", first_observation.code.slice());
            try std.testing.expectEqualStrings("session_stopped", second_observation.code.slice());
        }
    }.run);
}

/// A list whose statement fails at its first row's step.
const FailingList = struct {
    pub const S = rsql.Page(.{
        .arms = &.{.{ .on = .{ .index = "turn_session_latest" }, .alias = "t", .columns = "abs(-9223372036854775808+0*t.turn_id) AS failing" }},
        .Row = struct { turn_id: rsql.Positive, failing: u64 },
        .take = 256,
    });
    pub const failed = error.TurnReadFailed;
    pub const list = session_report.FullList.turns;
    pub const kept_rows = 0;

    /// Its statement fails before any row is visited.
    pub fn values(_: *reads_domain.ReadAccess, _: *const S.Row) error{}!session_report.FullRow {
        unreachable;
    }
};

fn expectListError(comptime L: type, comptime prefix: []const u8) !void {
    const message = comptime report_domain.listError(L).?;
    try std.testing.expectEqualStrings(prefix, message[0..@min(prefix.len, message.len)]);
}

test "a Full list declares its statement, list and values, and each group of hooks whole, and nothing else" {
    const Stray = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const list = FailingList.list;
        pub const kept_rows = 0;
        pub const values = FailingList.values;
        pub const chunk_limit = 4;
    };
    const Half = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const list = FailingList.list;
        pub const kept_rows = 0;
        pub const values = FailingList.values;
        pub const State = struct {};
    };
    const Hidden = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const list = FailingList.list;
        pub const kept_rows = 0;
        pub const values = FailingList.values;
        pub const State = struct {};
        fn check(_: *State, _: *const S.Row) error{}!void {}
    };
    const Missing = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const kept_rows = 0;
        pub const values = FailingList.values;
    };
    try std.testing.expect(comptime report_domain.listError(FailingList) == null);
    try expectListError(Stray, "a Full list declares only its statement, failed, list, kept_rows, values and its hooks, not chunk_limit: ");
    try expectListError(Half, "a Full list declares all of a group of hooks or none: check in ");
    // `@hasDecl` sees a private `check` only from its own file, so here
    // the group is incomplete; report.zig's own test covers a private hook.
    try expectListError(Hidden, "a Full list declares all of a group of hooks or none: check in ");
    try expectListError(Missing, "a Full list declares pub list: ");
}

test "Full history answers a list's first check before a later list's failed step in its round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Conversation's first read finds an assistant message without its
            // entry, and in the same round the list after it fails its step: main
            // checked the entries before it read any later list.
            for ([_]bool{ false, true }) |check| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "first-check-config");
                const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
                try answerTestTurn(&storage, &tmp, session.slice(), "first-check", &answer);
                if (check) try store_testing.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
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
                var reply: TestingReportReply = .{ .capture = &capture, .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 } };
                var watched: session_report_read_domain.Watched(*TestingReportReply) = .{ .visitor = &reply };
                try std.testing.expectError(
                    if (check) error.CorruptStore else error.TurnReadFailed,
                    report_domain.readRun(&a, .{ report_domain.Conversation, FailingList }, session.slice(), &watched),
                );
            }
        }
    }.run);
}

test "Full Conversation refuses an accepted assistant message without its entry" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "assistant-entry-config");
                const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
                try answerTestTurn(&storage, &tmp, session.slice(), "assistant-entry", &answer);
                if (fault) {
                    try store_testing.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
                    try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
                } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
            }
        }
    }.run);
}

test "Full history refuses content whose bytes no longer match their digest" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "digest-config");
                // Longer than one content window, so the digest spans windows.
                const text: [2100]u8 = @splat('d');
                try submitTestMessage(&storage, &tmp, "digest-message", "digest-message", session.slice(), &text);
                if (fault) {
                    try store_testing.zeroContent(&storage, "SELECT content_id FROM message_admission WHERE command_key='digest-message'");
                    try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
                } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
            }
        }
    }.run);
}

test "Full history takes a round per chunk" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "history-rounds-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "history-rounds", &answer);
            var rounds: u32 = 0;
            const content_before = storage.testing_content_work.content_rounds;
            std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), &rounds));
            // Every list fits one chunk, so the rounds are the reads' depth: one
            // for the revisions, whose one revision's empty instructions read no
            // content, then one per run of `renderFull`: Messages; Conversation,
            // Turns and Operations; calls; Actions; decisions, stops,
            // interruptions and results. A run's lists share a round because
            // every list but its last renders all its rows in the pass.
            try std.testing.expectEqual(@as(u32, 1 + 5), rounds);
            // The Message's and the answer's content are content rounds,
            // which differ by engine: on SQLite a `readRaw` window each.
            const content_rounds: u16 = switch (case.engine) {
                .sqlite, .mysql => 2,
            };
            try std.testing.expectEqual(content_rounds, storage.testing_content_work.content_rounds - content_before);
        }
    }.run);
}

test "Full revision queries bound the rows MySQL must drain after a streaming stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "revision-drain");
            for (2..9) |revision| {
                var key: [32]u8 = undefined;
                var change: wire_request.ConfigureCommand = .{};
                try change.key.set(try std.fmt.bufPrint(&key, "revision-drain-{d}", .{revision}));
                try change.session.set(session.slice());
                change.configuration.instructions = try testingBytesContent(&tmp, key[0..change.key.len], key[0..change.key.len]);
                try std.testing.expect(try storage.configure(&change, .{}) == .accepted);
            }
            const Rows = struct {
                count: usize = 0,
                valid: bool = true,
                after: report_domain.full_revisions.Args,
                decoded: report_domain.full_revisions.Row = undefined,

                pub fn visit(rows: *@This(), row: *const report_domain.full_revisions.Row) bool {
                    const next = report_domain.full_revisions.next(rows.after, row) orelse {
                        rows.valid = false;
                        return false;
                    };
                    rows.after = next;
                    rows.count += 1;
                    return true;
                }
            };
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            // Consume the SQL result, not just RevisionChunk's prefix: this
            // includes every row the MySQL server must compute and send even
            // when the renderer stops at the first owned nonempty content.
            // Test both the initial query and a seek after a streaming stop.
            for ([_]u64{ 0, 2 }) |after| {
                var rows: Rows = .{ .after = .{ .session = session.slice(), .revision = after } };
                a.readEach(report_domain.full_revisions, rows.after, 256 + 1, &rows);
                try a.run();
                try std.testing.expect(rows.valid);
                try std.testing.expectEqual(@as(usize, 3), rows.count);
            }
        }
    }.run);
}

test "Full revision owners pin both covering indexes in both dialects" {
    const full_revisions = report_domain.full_revisions;
    inline for (.{ "instructions", "output_schema" }) |field| {
        const index = "session_revision_" ++ field;
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, full_revisions.sql, "INDEXED BY " ++ index));
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, comptime full_revisions.mysql.prepared(), "FORCE INDEX (" ++ index ++ ")"));
        const own_instructions = "SELECT min(revision)*2 FROM session_revision INDEXED BY session_revision_instructions WHERE session_ref=?1 AND instructions_content_id=r." ++ field ++ "_content_id";
        const own_schema = "SELECT min(revision)*2+1 FROM session_revision INDEXED BY session_revision_output_schema WHERE session_ref=?1 AND output_schema_content_id=r." ++ field ++ "_content_id";
        try std.testing.expect(std.mem.indexOf(u8, full_revisions.sql, own_instructions) != null);
        try std.testing.expect(std.mem.indexOf(u8, full_revisions.sql, own_schema) != null);
    }
}

test "Full revisions show each content whole where it first occurs" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // `mixed`: new, older and repeated content, an output schema that is
            // none, the instructions or other content. `same`: one older content
            // throughout. `grown`: `mixed` with more than 512 distinct values.
            const Shape = enum { mixed, same, grown };
            const capacity = 1024;
            for ([_]Shape{ .mixed, .same, .grown }, [_]usize{ 70, 130, capacity * 2 }) |shape, revisions| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                // Content another Session admitted first is older than this
                // Session's.
                const other = try configureTestSessionAsk(&storage, "owners-other");
                const session = try configureTestSessionAsk(&storage, "owners-session");
                const texts = try std.testing.allocator.alloc([32]u8, 4 * capacity);
                defer std.testing.allocator.free(texts);
                const lengths = try std.testing.allocator.alloc(usize, 4 * capacity);
                defer std.testing.allocator.free(lengths);
                // Text 0 is the first revision's empty instructions.
                lengths[0] = 0;
                for (1..11) |index| {
                    lengths[index] = (try std.fmt.bufPrint(&texts[index], "{{\"title\":\"old {d}\"}}", .{index})).len;
                    var key: [48]u8 = undefined;
                    var reconfigure: wire_request.ConfigureCommand = .{};
                    try reconfigure.key.set(try std.fmt.bufPrint(&key, "owners-other-{d}", .{index}));
                    try reconfigure.session.set(other.slice());
                    reconfigure.configuration.instructions = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-other-i-{d}", .{index}), texts[index][0..lengths[index]]);
                    try std.testing.expect(try storage.configure(&reconfigure, .{}) == .accepted);
                }
                // Each revision's text, as an index into `texts` (`null`: none).
                const instructions = try std.testing.allocator.alloc(?usize, revisions + 1);
                defer std.testing.allocator.free(instructions);
                const output_schema = try std.testing.allocator.alloc(?usize, revisions + 1);
                defer std.testing.allocator.free(output_schema);
                instructions[1] = 0;
                output_schema[1] = null;
                var fresh: usize = 11;
                // The texts the Session holds.
                const held = try std.testing.allocator.alloc(bool, 4 * capacity);
                defer std.testing.allocator.free(held);
                @memset(held, false);
                held[0] = true;
                var distinct: usize = 1;
                for (2..revisions + 1) |revision| {
                    instructions[revision] = if (shape == .same) 1 else switch (revision % 5) {
                        // Older content, out of id order.
                        0 => 1 + (revision * 7) % 10,
                        // An earlier revision's instructions.
                        1 => instructions[revision - 3],
                        else => blk: {
                            lengths[fresh] = (try std.fmt.bufPrint(&texts[fresh], "{{\"title\":\"fresh {d}\"}}", .{revision})).len;
                            fresh += 1;
                            break :blk fresh - 1;
                        },
                    };
                    output_schema[revision] = if (shape == .same) null else switch (revision % 3) {
                        0 => null,
                        1 => instructions[revision],
                        else => 1 + (revision * 3) % 10,
                    };
                    for ([_]?usize{ instructions[revision], output_schema[revision] }) |text| if (text) |index| if (!held[index]) {
                        held[index] = true;
                        distinct += 1;
                    };
                    var key: [48]u8 = undefined;
                    var reconfigure: wire_request.ConfigureCommand = .{};
                    try reconfigure.key.set(try std.fmt.bufPrint(&key, "owners-revision-{d}", .{revision}));
                    try reconfigure.session.set(session.slice());
                    const i = instructions[revision].?;
                    reconfigure.configuration.instructions = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-i-{d}", .{revision}), texts[i][0..lengths[i]]);
                    if (output_schema[revision]) |o| {
                        reconfigure.configuration.output_schema = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-s-{d}", .{revision}), texts[o][0..lengths[o]]);
                    } else reconfigure.configuration.output_schema.state = .explicit_null;
                    try std.testing.expect(try storage.configure(&reconfigure, .{}) == .accepted);
                }
                try std.testing.expectEqual(shape == .grown, 2 * distinct > capacity);
                const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full);
                defer std.testing.allocator.free(full);
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
                defer parsed.deinit();
                const listed = parsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
                try std.testing.expectEqual(revisions, listed.len);
                // Each text's first occurrence, found by walking the revisions.
                const owners = try std.testing.allocator.alloc(?report_domain.ContentOwner, 4 * capacity);
                defer std.testing.allocator.free(owners);
                @memset(owners, null);
                for (listed, 1..) |row, revision| {
                    try std.testing.expectEqualStrings(try std.fmt.allocPrint(parsed.arena.allocator(), "{d}", .{revision}), row.object.get("revision").?.string);
                    for ([_]?usize{ instructions[revision], output_schema[revision] }, [_]session_report.RevisionField{ .instructions, .output_schema }) |text, field| {
                        const shown = row.object.get(@tagName(field)).?;
                        const index = text orelse {
                            try std.testing.expect(shown == .null);
                            continue;
                        };
                        const here: report_domain.ContentOwner = .{ .revision = revision, .field = field };
                        const owner = owners[index] orelse blk: {
                            owners[index] = here;
                            break :blk here;
                        };
                        if (owner.revision == here.revision and owner.field == here.field) {
                            try std.testing.expectEqualStrings(texts[index][0..lengths[index]], shown.object.get("text").?.string);
                        } else {
                            const reference = shown.object.get("owner").?.object;
                            try std.testing.expectEqualStrings(try std.fmt.allocPrint(parsed.arena.allocator(), "{d}", .{owner.revision}), reference.get("revision").?.string);
                            try std.testing.expectEqualStrings(@tagName(owner.field), reference.get("field").?.string);
                        }
                    }
                }
                // Owners are the Session's own: the other Session's revisions each
                // own their instructions, which this one's revisions also hold.
                const again = try testingSessionReportWithProfile(&storage, &tmp, other.slice(), 64 * 1024 * 1024, .full);
                defer std.testing.allocator.free(again);
                var reparsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, again, .{});
                defer reparsed.deinit();
                const others = reparsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
                try std.testing.expectEqual(@as(usize, 11), others.len);
                for (others[1..], 1..) |row, index| {
                    try std.testing.expectEqualStrings(texts[index][0..lengths[index]], row.object.get("instructions").?.object.get("text").?.string);
                }
            }
        }
    }.run);
}

test "Full Message projection work does not multiply Messages by stops, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const baseline = try measure(case, 32, 32);
            const more_messages = try measure(case, 128, 32);
            const more_stops = try measure(case, 32, 128);
            const both_larger = try measure(case, 128, 128);
            // The Messages' rounds grow with their chunks; stops add none
            // at either Message count.
            std.testing.expect(more_messages > baseline and more_stops == baseline and both_larger == more_messages) catch |err| {
                std.debug.print("rounds: {d} {d} {d} {d}\n", .{ baseline, more_messages, more_stops, both_larger });
                return err;
            };
        }

        fn measure(engine: *store_testing.Case, message_count: usize, stop_count: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "full-scale-config");
            for (1..message_count + 1) |index| {
                var key: [32]u8 = undefined;
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at,admission_position) " ++
                    "VALUES(?1,?2,?3,1,NULL,1,?4)", .{ index, session.slice(), try std.fmt.bufPrint(&key, "message-{d}", .{index}), 1000 + index });
            }
            const last_command = try store_testing.queryU64(&storage, "SELECT coalesce(max(command_seq),0) FROM core_command", .{});
            for (1..stop_count + 1) |index| {
                var key: [32]u8 = undefined;
                const command = try std.fmt.bufPrint(&key, "stop-{d}", .{index});
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
                    "VALUES(?1,3,?2,zeroblob(32),NULL,NULL,1,'accepted',0,0,?3)", .{ command, session.slice(), last_command + index });
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                    "VALUES(?1,?2,NULL,?3,?4,1)", .{ command, session.slice(), message_count, index });
            }
            const counter = TwinRounds.start(&storage);
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
            const taken = counter.taken();
            std.testing.allocator.free(full);
            return taken;
        }
    }.run);
}
