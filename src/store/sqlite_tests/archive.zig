//! Archive SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const store_testing = @import("../testing.zig");
const ActionSettlement = action_domain.ActionSettlement;
const canonicalCwd = store_testing.canonicalCwd;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingListing = tests.TestingListing;
const testingSessionList = tests.testingSessionList;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const attemptBashForTesting = shared_fixtures.attemptBashForTesting;

/// Archive transitions use the command boundary, never seeded projection rows.
const ArchiveReportTesting = struct {
    fn set(storage: *Store, key: []const u8, session: []const u8, archived: bool) !protocol.SessionStopCompletion {
        var command: protocol.SessionArchiveCommand = .{ .archived = archived };
        try command.key.set(key);
        try command.session.set(session);
        const reply = storage.archiveSession(&command, .{});
        try std.testing.expect(reply == .accepted);
        try std.testing.expectEqual(archived, reply.accepted.archived);
        return reply.accepted.completion;
    }

    fn expectListState(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions, session: []const u8, expected: protocol.SessionArchiveState) !void {
        var used = std.atomic.Value(u64).init(0);
        const bytes = try testingSessionList(storage, tmp, request, &used, 81);
        defer std.testing.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        const rows = parsed.value.object.get("sessions").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings(session, rows[0].object.get("reference").?.string);
        try std.testing.expectEqualStrings(@tagName(expected), rows[0].object.get("archive_state").?.string);
    }

    fn expectState(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, expected: protocol.SessionArchiveState) !void {
        const inspected = try storage.inspectSessionForTesting(session);
        try std.testing.expectEqual(expected, inspected.archive_state);
        for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
            const bytes = try testingSessionReportWithProfile(storage, tmp, session, 1024 * 1024, profile);
            defer std.testing.allocator.free(bytes);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(session, parsed.value.object.get("session").?.object.get("reference").?.string);
            try std.testing.expectEqualStrings(@tagName(expected), parsed.value.object.get("archive_state").?.string);
        }
        try expectListState(storage, tmp, .{ .archive = .all }, session, expected);
    }
};

test "archive reports expose idle state and ignore restored historical requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "archive-idle-session");
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .active);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, try ArchiveReportTesting.set(&storage, "archive-idle", session.slice(), true));
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .archived);
    const hidden = try TestingListing.read(&storage, &tmp, .{});
    try hidden.expectReferences(&.{});
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, try ArchiveReportTesting.set(&storage, "archive-idle-restore", session.slice(), false));
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .active);
    _ = try ArchiveReportTesting.set(&storage, "archive-idle-again", session.slice(), true);
    try submitTestMessage(&storage, &tmp, "archive-idle-message", "archive-idle-message", session.slice(), "restore by Message");
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .active);
    try std.testing.expect(!storage.isFenced());
}

test "archive reports retain pending stops and changed rows outside the full filter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "archive-pending-session");
    const action = try attemptBashForTesting(&storage, &tmp, session.slice());
    const before = try TestingListing.read(&storage, &tmp, .{});
    try std.testing.expectEqual(protocol.SessionStopCompletion.pending, try ArchiveReportTesting.set(&storage, "archive-pending", session.slice(), true));
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .archiving);
    try ArchiveReportTesting.expectListState(&storage, &tmp, .{}, session.slice(), .archiving);
    const archived_before = try TestingListing.read(&storage, &tmp, .{ .archive = .archived });
    try archived_before.expectReferences(&.{});
    const pending = try TestingListing.read(&storage, &tmp, .{ .since = before.since });
    try std.testing.expectEqual(protocol.ListDelta.changed, pending.delta);
    try pending.expectReferences(&.{session.slice()[0..protocol.session_id_bytes].*});
    try std.testing.expectEqual(ActionSettlement.session_stop, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
    try ArchiveReportTesting.expectState(&storage, &tmp, session.slice(), .archived);
    const active_delta: protocol.ListSessions = .{ .since = pending.since };
    const closed = try TestingListing.read(&storage, &tmp, active_delta);
    try std.testing.expectEqual(protocol.ListDelta.changed, closed.delta);
    try ArchiveReportTesting.expectListState(&storage, &tmp, active_delta, session.slice(), .archived);
    const active_after = try TestingListing.read(&storage, &tmp, .{});
    try active_after.expectReferences(&.{});
    try ArchiveReportTesting.expectListState(&storage, &tmp, .{ .archive = .archived }, session.slice(), .archived);
    const archived_after = try TestingListing.read(&storage, &tmp, .{ .archive = .archived });
    _ = try ArchiveReportTesting.set(&storage, "archive-pending-restore", session.slice(), false);
    const archived_delta: protocol.ListSessions = .{ .archive = .archived, .since = archived_after.since };
    const restored = try TestingListing.read(&storage, &tmp, archived_delta);
    try std.testing.expectEqual(protocol.ListDelta.changed, restored.delta);
    try ArchiveReportTesting.expectListState(&storage, &tmp, archived_delta, session.slice(), .active);
    try std.testing.expect(!storage.isFenced());
}

test "archive full list filtering precedes pagination and keeps the creation ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var references: [19]change_ring.Id = undefined;
    for (&references, 0..) |*reference, index| {
        var key: [40]u8 = undefined;
        const session = try configureTestSession(&storage, try std.fmt.bufPrint(&key, "archive-page-session-{d}", .{index}));
        reference.* = session.slice()[0..protocol.session_id_bytes].*;
        if (index < 10) _ = try ArchiveReportTesting.set(&storage, try std.fmt.bufPrint(&key, "archive-page-request-{d}", .{index}), reference, true);
    }
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var scope: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try scope.set(try canonicalCwd(std.testing.io, &workspace_buffer));
    for ([_]?protocol.Bounded(protocol.max_workspace_bytes){ null, scope }) |workspace| {
        for ([_]protocol.SessionArchiveFilter{ .active, .archived, .all }) |filter| {
            const expected: []const change_ring.Id = switch (filter) {
                .active => references[10..],
                .archived => references[0..10],
                .all => references[0..],
            };
            var request: protocol.ListSessions = .{ .workspace = workspace, .archive = filter };
            var offset: usize = 0;
            while (true) {
                const page = try TestingListing.read(&storage, &tmp, request);
                try std.testing.expectEqual(protocol.ListDelta.full, page.delta);
                const count = @min(protocol.session_list_page_size, expected.len - offset);
                try page.expectReferences(expected[offset..][0..count]);
                offset += count;
                if (offset == expected.len) {
                    try std.testing.expect(page.next == null);
                    break;
                }
                try std.testing.expect(page.next != null);
                request = page.next.?;
                // The generic test helper predates archive filters; clients
                // retain the invocation's filter across every continuation.
                request.archive = filter;
                try std.testing.expectEqual(@as(u64, references.len), request.ceiling);
            }
        }
    }
    const first = try TestingListing.read(&storage, &tmp, .{});
    var continued = first.next.?;
    try std.testing.expectEqual(@as(u64, references.len), continued.ceiling);
    _ = try configureTestSession(&storage, "archive-page-late");
    continued.archive = .active;
    const last = try TestingListing.read(&storage, &tmp, continued);
    try last.expectReferences(references[18..]);
    try std.testing.expect(last.next == null);
    try std.testing.expect(!storage.isFenced());
}
