const connection = @import("../../connection.zig");
const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const history_floor_domain = @import("../domain/history_floor.zig");
const store_testing = @import("../testing.zig");
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testingStore = store_testing.testingSqliteStore;
const TestingSteps = shared_fixtures.TestingSteps;

const TestingFloorWalk = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{ .always, error.CorruptStore },
        .page = .{ .paged, error.CorruptStore },
    });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .none;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { operation: u64, entry: *const store_core.Entry };
    pub const Result = ?history_floor_domain.Room;
    pub const Ordinary = store_core.Ordinary.none;

    input: Input,
    search: history_floor_domain.FloorSearch = undefined,

    pub fn step(t: *TestingFloorWalk, r: *transition.Round(TestingFloorWalk), ran: ?rounds.At) !transition.Next(TestingFloorWalk) {
        if (ran == null) {
            t.search = .{ .operation = t.input.operation, .entry = t.input.entry };
            t.search.start(r);
            return .{ .round = .facts };
        }
        if (try t.search.next(r)) return .{ .round = .page };
        return .{ .done = t.search.room() };
    }

    fn deeper(store: *Store, operation: u64) !?history_floor_domain.Room {
        const mapped = try @import("../../os/pages.zig").Mapped(history_floor_domain.Preparation).map();
        defer mapped.unmap();
        mapped.value.init(operation);
        defer mapped.value.deinit();
        while (!try store.advanceHistoryFloor(mapped.value)) {}
        return mapped.value.prepared.?.room;
    }
};

test "a compaction's floor counts the output bytes a request sends, and none its base covers" {
    const answer = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(answer);
    @memset(answer, 'a');
    const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"message\",\"id\":\"a1\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}", .{answer});
    defer std.testing.allocator.free(item);
    for ([_]bool{ false, true }) |covered| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try tests.configureTestSessionAsk(&storage, "floor-bytes-config");
        try submitTestMessage(&storage, &tmp, "floor-bytes-first", "floor-bytes-first", session.slice(), "first");
        const answered = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, answered, &.{item}, answer);
        if (covered) {
            try submitTestMessage(&storage, &tmp, "floor-bytes-covered", "floor-bytes-covered", session.slice(), "c");
            const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
        }
        try submitTestMessage(&storage, &tmp, "floor-bytes-small", "floor-bytes-small", session.slice(), "small");
        const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const room = try TestingFloorWalk.deeper(&storage, compaction.operation_id);
        if (covered) {
            try std.testing.expect(room == null);
        } else {
            const position = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{answered.operation_id});
            try std.testing.expectEqual(@as(u8, 2), room.?.choice.level);
            try std.testing.expect(room.?.choice.floor >= position);
        }
    }
}

test "a compaction's floor walk reads past its first page to the level that drops least" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-pages-config");
    const text = try std.testing.allocator.alloc(u8, 30_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'p');
    try submitTestMessage(&storage, &tmp, "floor-pages-first", "floor-pages-first", session.slice(), "first");
    var key: [32]u8 = undefined;
    for (0..20) |index| {
        const name = try std.fmt.bufPrint(&key, "floor-pages-{d}", .{index});
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), text);
    }
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const room = (try TestingFloorWalk.deeper(&storage, compaction.operation_id)).?;
    try std.testing.expectEqual(@as(u8, 1), room.choice.level);
}

test "a compaction's floor read costs the same however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-steps-config");
    const text = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try submitTestMessage(&storage, &tmp, "floor-steps-first", "floor-steps-first", session.slice(), "first");
    try submitTestMessage(&storage, &tmp, "floor-steps-big", "floor-steps-big", session.slice(), text);
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const Walk = struct {
        fn steps(store: *Store, operation: u64) !u64 {
            _ = try deeper(store, operation);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            try std.testing.expect(try deeper(store, operation) != null);
            return counter.steps;
        }
        fn deeper(store: *Store, operation: u64) !?history_floor_domain.Room {
            return TestingFloorWalk.deeper(store, operation);
        }
        fn addOlder(store: *Store, ref: []const u8, comptime first: u64) !void {
            const sequence = std.fmt.comptimePrint("WITH RECURSIVE sequence(value) AS (VALUES({d}) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) ", .{ first, first + 999 });
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_kind,source_revision,source_operation_id,content_id,recorded_at) " ++
                "SELECT session_ref,entry_ordinal+value*10,session_position-value-1,entry_kind,turn_id,source_admission_id+value*10,source_kind,NULL,NULL,content_id,recorded_at " ++
                "FROM conversation_entry CROSS JOIN sequence WHERE session_ref=?1 AND entry_ordinal=2", .{ref});
        }
    };
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE conversation_entry SET session_position=session_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE model_operation SET admission_position=admission_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE session SET next_position=next_position+3000 WHERE session_ref=?1", .{session.slice()});
    try Walk.addOlder(&storage, session.slice(), 1);
    const thousand = try Walk.steps(&storage, compaction.operation_id);
    try Walk.addOlder(&storage, session.slice(), 1001);
    try std.testing.expectEqual(@as(u64, 2002), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM conversation_entry", .{}));
    try std.testing.expectEqual(thousand, try Walk.steps(&storage, compaction.operation_id));
}

test "a compaction's floor weighs compound Message parts and skills as one whole unit" {
    const skills = @import("../domain/skills.zig");
    const protocol = @import("../../protocol.zig");
    for ([_]bool{ false, true }) |skill_heavy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try tests.configureTestSessionAsk(&storage, "compound-floor-config");
        const large = try std.testing.allocator.alloc(u8, 200_000);
        defer std.testing.allocator.free(large);
        @memset(large, 'p');
        const png = @embedFile("../../codecs/fixtures/image-input/pixel.png");
        const first_body = "protected first Message skill";
        const newest_body = "protected newest Message skill";
        const first_skills: skills.MessageCapture = .{ .bound = &.{.{ .name = "first", .bytes = first_body }} };
        const middle_skills: skills.MessageCapture = .{ .bound = &.{.{ .name = "middle", .bytes = if (skill_heavy) large else "middle skill" }} };
        const newest_skills: skills.MessageCapture = .{ .bound = &.{.{ .name = "newest", .bytes = newest_body }} };
        try store_testing.submitTestMessagePartsWithSkills(&storage, &tmp, "compound-floor-first", session.slice(), &.{
            .{ .bytes = "first" },
            .{ .bytes = png, .kind = .{ .image = .{} } },
        }, &first_skills);
        try store_testing.submitTestMessagePartsWithSkills(&storage, &tmp, "compound-floor-large", session.slice(), &.{
            .{ .bytes = if (skill_heavy) "small" else large },
            .{ .bytes = png, .kind = .{ .image = .{} } },
        }, &middle_skills);
        try store_testing.submitTestMessagePartsWithSkills(&storage, &tmp, "compound-floor-newest", session.slice(), &.{
            .{ .bytes = "newest" },
            .{ .bytes = png, .kind = .{ .image = .{} } },
        }, &newest_skills);
        const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const first = try store_testing.queryU64(&storage, "SELECT min(session_position) FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
        const newest = try store_testing.queryU64(&storage, "SELECT max(session_position) FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1", .{session.slice()});
        try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const candidate = try TestingFloorWalk.deeper(&storage, compaction.operation_id);
        try std.testing.expect(candidate != null);
        const room = candidate.?;
        try std.testing.expectEqual(@as(u8, 2), room.choice.level);
        try std.testing.expectEqual(newest - 1, room.choice.floor);
        // Let the production settlement owner apply the floor, then inspect the
        // next frozen view rather than installing a fixture floor through SQL.
        try storage.settleModelAttemptFailure(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const retry = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var view: store_testing.TestingPage = undefined;
        view.open(&storage, retry);
        defer view.close();
        const coverage = try view.coverage();
        try std.testing.expectEqual(room.choice.floor, coverage.floor.position);
        var after: u64 = 0;
        var messages: usize = 0;
        var bodies: usize = 0;
        while (try view.nextEntry(after)) |entry| {
            after = entry.position;
            switch (entry.kind) {
                .user => {
                    try std.testing.expect(messages < 2);
                    try std.testing.expectEqual(if (messages == 0) first else newest, entry.position);
                    try view.page.openMessage(entry.input.?);
                    var parts: usize = 0;
                    while (try view.nextMessagePart()) |_| parts += 1;
                    try std.testing.expectEqual(@as(usize, 2), parts);
                    messages += 1;
                },
                .skill => {
                    try std.testing.expect(bodies < 2);
                    const body = if (bodies == 0) first_body else newest_body;
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(body), &entry.content.?.digest);
                    bodies += 1;
                },
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 2), messages);
        try std.testing.expectEqual(@as(usize, 2), bodies);
        try std.testing.expect(!storage.isFenced());
    }
}

test "floor preparation yields between manifest reads and accepts its frozen prefix through later appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-yield-config");
    try submitTestMessage(&storage, &tmp, "floor-yield-first", "floor-yield-first", session.slice(), "first");
    const text: [4000]u8 = @splat('x');
    const middle: [65]store_testing.MessagePart = @splat(.{ .bytes = &text });
    const newest: [65]store_testing.MessagePart = @splat(.{ .bytes = "newest" });
    try store_testing.submitTestMessageParts(&storage, &tmp, "floor-yield-middle", session.slice(), &middle);
    try store_testing.submitTestMessageParts(&storage, &tmp, "floor-yield-newest", session.slice(), &newest);
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(!try storage.settleModelAttemptFailurePrepared(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{}, null));
    const expected = (try TestingFloorWalk.deeper(&storage, compaction.operation_id)).?;
    const mapped = try @import("../../os/pages.zig").Mapped(history_floor_domain.Preparation).map();
    defer mapped.unmap();
    const preparation = mapped.value;
    preparation.init(compaction.operation_id);
    defer preparation.deinit();
    var cancelled_steps: usize = 0;
    while (preparation.cursor == null) : (cancelled_steps += 1) {
        try std.testing.expect(cancelled_steps < 16);
        try std.testing.expect(!try storage.advanceHistoryFloor(preparation));
    }
    preparation.deinit();
    try std.testing.expect(preparation.cursor == null);
    preparation.init(compaction.operation_id);
    var step: usize = 0;
    var certified: usize = 0;
    var key: [64]u8 = undefined;
    while (!preparation.ready) : (step += 1) {
        try std.testing.expect(step < 256);
        const before = tests.ViewRounds.start(&storage);
        const had_weight = preparation.search.weight != null;
        _ = try storage.advanceHistoryFloor(preparation);
        const taken = before.taken();
        try std.testing.expect(taken.rounds + taken.content_rounds <= 1);
        if (!had_weight and preparation.search.weight != null) certified += 1;
        const name = try std.fmt.bufPrint(&key, "floor-yield-later-{d}", .{step});
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), "later");
    }
    try std.testing.expect(step > 8);
    try std.testing.expect(certified >= 2);
    try std.testing.expect(preparation.cursor == null);
    const prepared = &preparation.prepared.?;
    try std.testing.expectEqualDeep(expected, prepared.room.?);
    var stale = prepared.*;
    stale.facts.context_window += 1;
    try std.testing.expect(!try storage.settleModelAttemptFailurePrepared(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{}, &stale));
    try std.testing.expect(try storage.settleModelAttemptFailurePrepared(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{}, prepared));
    const retry = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: store_testing.TestingPage = undefined;
    view.open(&storage, retry);
    defer view.close();
    try std.testing.expectEqual(expected.choice.floor, (try view.coverage()).floor.position);
    try std.testing.expect(!storage.isFenced());
}

fn expectMalformedPressurePreparationForTesting(storage: *Store, session: []const u8) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: @import("../access.zig").Access(.read, error{}) = .open(&entry);
    defer access.deinit();
    const admission = @import("../domain/model_admission.zig");
    var read = admission.CompactionRead.init(session, std.math.maxInt(i64), connection.Name.parse("codex").?, .@"openai-responses/2", "model-a", @import("../../model_capability.zig").compactionPolicy("model-a", true, 1000, 0));
    while (read.queue(&access)) {
        try @import("../access.zig").runAs(&access, error.CorruptStore);
        read.advance(&access) catch |err| {
            if (err != error.PartsPressureRequired) return err;
            return;
        };
    }
    return error.TestExpectedError;
}

test "canonical compound pressure classifies invalid forms alone and beside valid parts before admission or report" {
    const sqlite = @import("../sqlite.zig");
    for ([_]i64{ 2, -1 }) |tag| {
        for ([_]bool{ false, true }) |mixed| {
            for ([_]bool{ false, true }) |report| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testingStore(&storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try tests.configureTestSessionAsk(&storage, "invalid-form-pressure-config");
                try submitTestMessage(&storage, &tmp, "invalid-form-pressure-seed", "invalid-form-pressure-seed", session.slice(), "seed");
                const seed = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleItemsForTesting(&storage, &tmp, seed, &.{"{\"type\":\"message\",\"id\":\"seed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}"}, "ok");
                const image = &.{store_testing.MessagePart{ .bytes = @embedFile("../../codecs/fixtures/image-input/pixel.png"), .kind = .{ .image = .{} } }};
                try store_testing.submitTestMessageParts(&storage, &tmp, "invalid-form-pressure-damaged", session.slice(), image);
                if (mixed) try store_testing.submitTestMessageParts(&storage, &tmp, "invalid-form-pressure-valid", session.slice(), &.{
                    .{ .bytes = "valid Text" },
                    .{ .bytes = @embedFile("../../codecs/fixtures/image-input/pixel.png"), .kind = .{ .image = .{} } },
                });
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
                try store_testing.sqlite_only.exec(&storage, "UPDATE content SET form=?1 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='invalid-form-pressure-damaged')", .{tag});
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
                if (report) {
                    // Assert the pressure owner requests canonical classification,
                    // independently of report projection's own corruption checks.
                    try expectMalformedPressurePreparationForTesting(&storage, session.slice());
                    try std.testing.expectError(error.CorruptStore, tests.testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
                } else {
                    try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.message, .{}));
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }
}

test "a floor rejects unknown Message content forms instead of dropping their unverified bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-form-config");
    try submitTestMessage(&storage, &tmp, "floor-form-first", "floor-form-first", session.slice(), "first");
    const large = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(large);
    @memset(large, 'f');
    try submitTestMessage(&storage, &tmp, "floor-form-large", "floor-form-large", session.slice(), large);
    try submitTestMessage(&storage, &tmp, "floor-form-newest", "floor-form-newest", session.slice(), "newest");
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try TestingFloorWalk.deeper(&storage, compaction.operation_id) != null);
    try std.testing.expect(!storage.isFenced());
    const sqlite = @import("../sqlite.zig");
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
    try store_testing.sqlite_only.exec(&storage, "UPDATE content SET form=2 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='floor-form-large')", .{});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
    try std.testing.expectError(error.CorruptStore, storage.settleModelAttemptFailure(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{}));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND history_floor IS NULL AND history_level IS NULL AND resolution_code IS NULL", .{compaction.operation_id}));
}

test "a compaction's floor weighs compound Action Resolutions as a whole Tool Result group" {
    const large = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(large);
    @memset(large, 'r');
    for ([_]usize{ 1, 16, 17 }) |count| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try tests.configureTestSessionWithMode(&storage, "result-floor-config", "bypass");
        try submitTestMessage(&storage, &tmp, "result-floor-first", "result-floor-first", session.slice(), "first");
        const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var names: [17][24]u8 = undefined;
        var calls: [17]tests.TestingCall = undefined;
        for (calls[0..count], names[0..count], 0..) |*call, *name, index| {
            const id = try std.fmt.bufPrint(name, "result-call-{d}", .{index});
            call.* = .{
                .item_id = id,
                .name = "bash",
                .encoded_call_id = id,
                .decoded_call_id = id,
                .encoded_arguments = "{\\\"cmd\\\":\\\"one\\\",\\\"description\\\":\\\"Run command\\\"}",
                .decoded_arguments = "{\"cmd\":\"one\",\"description\":\"Run command\"}",
            };
        }
        try tests.settleCallsForTesting(&storage, &tmp, first, "result-floor-output", calls[0..count]);
        for (0..count) |index| {
            const selected = (try storage.nextAction(.bash, .fromFree(1, true))).?;
            const action = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            try store_testing.settleTestActionParts(&storage, &tmp, action, &.{
                .{ .bytes = if (index + 1 == count) large else "small" },
                .{ .bytes = @embedFile("../../codecs/fixtures/image-input/pixel.png"), .kind = .{ .image = .{} } },
            });
        }
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, continuation, &.{
            "{\"type\":\"message\",\"id\":\"floor-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}",
        }, "done");
        try submitTestMessage(&storage, &tmp, "result-floor-newest", "result-floor-newest", session.slice(), "newest");
        const newest = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(newest, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const candidate = try TestingFloorWalk.deeper(&storage, compaction.operation_id);
        if (candidate == null) std.debug.print("compound Action Resolution floor missing candidate at count {d}\n", .{count});
        try std.testing.expect(candidate != null);
        const room = candidate.?;
        try std.testing.expectEqual(@as(u8, 2), room.choice.level);
        const continuation_position = try store_testing.queryU64(&storage, "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{continuation.operation_id});
        try std.testing.expectEqual(continuation_position - 1, room.choice.floor);
        try storage.settleModelAttemptFailure(compaction, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const retry = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var view: store_testing.TestingPage = undefined;
        view.open(&storage, retry);
        defer view.close();
        try std.testing.expectEqual(room.choice.floor, (try view.coverage()).floor.position);
        var after: u64 = 0;
        var messages: usize = 0;
        var outputs: usize = 0;
        while (try view.nextEntry(after)) |entry| {
            after = entry.position;
            switch (entry.kind) {
                .user => messages += 1,
                .provider_output => outputs += 1,
                .instruction, .operation => {},
                .tool_results, .skill => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expectEqual(@as(usize, 2), messages);
        try std.testing.expectEqual(@as(usize, 1), outputs);
    }
}
