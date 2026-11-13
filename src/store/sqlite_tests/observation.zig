//! Observation SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const report_domain = @import("../domain/report.zig");
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
            // Warm every statement before metering the actual observation.
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
