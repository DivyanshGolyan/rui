const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const report_domain = @import("../domain/report.zig");
const public_parts = @import("../domain/public_parts.zig");
const store_testing = @import("../testing.zig");
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const namedStatementForTesting = tests.namedStatementForTesting;
const testingStore = store_testing.testingSqliteStore;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const TestingSteps = shared_fixtures.TestingSteps;

test "an observed pending Message whose work read fails answers the work reads' names" {
    inline for (.{
        .{ "SELECT t.turn_id,t.operation_id", error.TurnReadFailed },
        .{ "count(*) AS total", error.ActionReadFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "observe-names-config");
        try submitTestMessage(&storage, &tmp, "observe-names-input", "observe-names-message", session.slice(), "q");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        var fault: TestingStatementFault = .{ .sql = namedStatementForTesting(report_domain.pending_failures, case[1], case[0]) };
        fault.arm(storage.sqliteDatabase());
        defer fault.disarm(storage.sqliteDatabase());
        try std.testing.expectError(case[1], store_testing.observeCommandForTesting(&storage, "observe-names-message"));
        try std.testing.expect(fault.failed > 0);
    }
}

test "Message recovery observation seeks stay bounded as the Turn accumulates recovered Actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionWithMode(&storage, "bounded-recovery-config", "bypass");
    try submitTestMessage(&storage, &tmp, "bounded-recovery-input", "bounded-recovery", session.slice(), "run");
    var costs: [2]u64 = undefined;
    for (0..12) |i| {
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var prefix: [40]u8 = undefined;
        _ = try tests.recoverPairForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "bounded-recovery-{d}", .{i}));
        if (i == 2 or i == 11) {
            var out: store_core.Observed = undefined;
            try storage.observeCommand("bounded-recovery", null, &out);
            var meter: TestingSteps = .{};
            meter.begin(storage.sqliteDatabase());
            defer meter.end(storage.sqliteDatabase());
            try storage.observeCommand("bounded-recovery", null, &out);
            costs[if (i == 2) 0 else 1] = meter.steps;
            try std.testing.expectEqual(@as(u8, 4), out.full.observation.kind.message.?.recovery.count);
            try std.testing.expect(out.full.observation.kind.message.?.recovery.more);
        }
    }
    try std.testing.expectEqual(costs[0], costs[1]);
}

test "TPR-3 a saved tool label reads as one tidy line in a Message's recovered Actions" {
    const sqlite = @import("../sqlite.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionWithMode(&storage, "recovery-label-config", "bypass");
    try submitTestMessage(&storage, &tmp, "recovery-label-input", "recovery-label", session.slice(), "run");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    _ = try tests.recoverPairForTesting(&storage, &tmp, binding, "recovery-label");
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE model_tool_call SET description='  Run' || char(10) || 'first   command ' WHERE call_ordinal=0");
    var out: store_core.Observed = undefined;
    try storage.observeCommand("recovery-label", null, &out);
    const recovery = out.full.observation.kind.message.?.recovery;
    try std.testing.expectEqual(@as(u8, 2), recovery.count);
    for (recovery.calls[0..recovery.count]) |call| try std.testing.expectEqualStrings(
        if (call.call == 0) "Run first command" else "Run second command",
        call.description.?.slice(),
    );
}

test "SH-68 compound observations project identity and parts listing certifies content" {
    const sqlite = @import("../sqlite.zig");
    const cases = [_]struct { mutation: [:0]const u8, listing_error: ?anyerror = null }{
        .{
            .mutation = "UPDATE content SET digest=zeroblob(32) WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='observe-parts')",
            .listing_error = error.CorruptStore,
        },
        .{
            .mutation = "UPDATE content SET byte_length=byte_length+1 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='observe-parts')",
            .listing_error = error.ContentReadFailed,
        },
        .{
            .mutation = "UPDATE content_part SET part_content_id=(SELECT second.part_content_id FROM content_part second WHERE second.content_id=content_part.content_id AND second.ordinal=1) WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='observe-parts') AND ordinal=0",
            .listing_error = error.CorruptStore,
        },
        .{ .mutation = "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='observe-parts')" },
        .{ .mutation = "UPDATE content SET form=255 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='observe-parts')" },
        .{ .mutation = "UPDATE core_command SET primary_content_id=(SELECT min(part_content_id) FROM content_part) WHERE command_key='observe-parts'" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "observe-parts-config");
        try store_testing.submitTestMessageParts(&storage, &tmp, "observe-parts", session.slice(), &.{ .{ .bytes = "first" }, .{ .bytes = "second" } });
        const before = (try store_testing.observeCommandForTesting(&storage, "observe-parts")).kind.message.?;
        try std.testing.expect(before.content == .parts);
        try std.testing.expectEqualDeep(@import("../../content_value.zig").Owner{ .message = before.queue.?.admission_id }, before.content.parts.owner);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
        try sqlite.exec(storage.sqliteDatabase(), case.mutation);
        if (case.listing_error) |expected| {
            const observation = try store_testing.observeCommandForTesting(&storage, "observe-parts");
            try std.testing.expectEqual(.accepted, observation.status);
            const content = observation.kind.message.?.content;
            try std.testing.expect(content == .parts);
            try std.testing.expectEqualDeep(before.content.parts.owner, content.parts.owner);
            try std.testing.expect(!storage.isFenced());

            var reader = try public_parts.Reader.init(session, content.parts.owner);
            defer reader.deinit();
            try std.testing.expectError(expected, finishPartsCertification(&storage, &reader));
        } else {
            try std.testing.expectError(error.CorruptStore, store_testing.observeCommandForTesting(&storage, "observe-parts"));
        }
        try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "observe-parts"));
    }
}

fn finishPartsCertification(storage: *Store, reader: *public_parts.Reader) !void {
    while ((try storage.readPublicParts(reader)) == .pending) {}
}
