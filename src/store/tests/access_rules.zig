//! Access rules Store conformance tests.
const std = @import("std");

test "the Store prepares only typed statements, its transaction control and test fixtures" {
    // Open text cannot reach SQLite beside `rsql`: the one prepare is
    // `cachedStatic`, called only by these three, and `cachedTyped` takes
    // only a type `rsql.Read` or `rsql.Write` made (`rsql.isStatement`).
    const source = @embedFile("../engine/Sqlite.zig");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "sqlite3_" ++ "prepare"));
    const callers = [_][]const u8{ "controlStatement", "cachedTyped", "fixtureStatement" };
    var calls = std.mem.splitSequence(u8, source, "cachedStatic" ++ "(self, ");
    var before = calls.first();
    var found: usize = 0;
    while (calls.next()) |rest| : (found += 1) {
        const name_start = std.mem.lastIndexOf(u8, before, "fn ").? + 3;
        const name = before[name_start .. name_start + std.mem.indexOfScalar(u8, before[name_start..], '(').?];
        var allowed = false;
        for (callers) |caller| allowed = allowed or std.mem.eql(u8, name, caller);
        if (!allowed) std.debug.print("cachedStatic called from {s}\n", .{name});
        try std.testing.expect(allowed);
        before = rest;
    }
    try std.testing.expectEqual(callers.len, found);
    // Opening's own text: engine settings, and one sweep held to
    // `rsql.portabilityError`.
    var execs = std.mem.splitSequence(u8, source, "sqlite.exec" ++ "(database.?, ");
    _ = execs.first();
    while (execs.next()) |rest| {
        const allowed = std.mem.startsWith(u8, rest, "\"PRAGMA ") or std.mem.startsWith(u8, rest, "cache_size") or
            std.mem.startsWith(u8, rest, "if (options.cache_spill) \"PRAGMA ") or std.mem.startsWith(u8, rest, "comptime portable(");
        try std.testing.expect(allowed);
    }
}

test "Store entry points queue and fence only through canonical access" {
    // Every entry point classifies its errors through `Entry`; a new path
    // cannot take a lock beside the Store's queue, read or set the fence
    // beside it, or enter without returning through a classifier.
    const sources = .{
        @embedFile("../Store.zig"),
        @embedFile("../access.zig"),
        @embedFile("../archive_tests.zig"),
        @embedFile("../engine.zig"),
        @embedFile("../engine/Sqlite.zig"),
        @embedFile("../engine/Mysql.zig"),
        @embedFile("../engine/mysql_content.zig"),
        @embedFile("../engine/mysql_open.zig"),
        @embedFile("../engine/mysql_refusal.zig"),
        @embedFile("../domain/action.zig"),
        @embedFile("../domain/forward.zig"),
        @embedFile("../domain/command.zig"),
        @embedFile("../domain/configuration.zig"),
        @embedFile("../domain/content.zig"),
        @embedFile("../domain/find_tools.zig"),
        @embedFile("../domain/historical.zig"),
        @embedFile("../domain/history_floor.zig"),
        @embedFile("../domain/model_admission.zig"),
        @embedFile("../domain/model_facts.zig"),
        @embedFile("../domain/model_attempt.zig"),
        @embedFile("../domain/model_settlement.zig"),
        @embedFile("../domain/operation_effort.zig"),
        @embedFile("../domain/reads.zig"),
        @embedFile("../domain/report.zig"),
        @embedFile("../domain/session_list_read.zig"),
        @embedFile("../domain/session_obligation.zig"),
        @embedFile("../domain/session_report_read.zig"),
        @embedFile("../domain/skills.zig"),
        @embedFile("../domain/tool_offer.zig"),
        @embedFile("../domain/tool_set.zig"),
        @embedFile("../domain/turn.zig"),
        @embedFile("../mysql_literal.zig"),
        @embedFile("../mysql_row.zig"),
        @embedFile("../rsql.zig"),
        @embedFile("../schema.zig"),
        @embedFile("../sqlite.zig"),
        @embedFile("../testing.zig"),
        @embedFile("../queue.zig"),
        @embedFile("../transition.zig"),
    };
    var locks: usize = 0;
    var fence_stores: usize = 0;
    var fence_loads: usize = 0;
    var entered: usize = 0;
    inline for (sources) |source| {
        locks += std.mem.count(u8, source, "mutex.lock" ++ "Uncancelable(");
        fence_stores += std.mem.count(u8, source, "fenced.store" ++ "(true");
        fence_loads += std.mem.count(u8, source, "fenced.load" ++ "(");
        const enter = "enter" ++ "(self, ";
        var entries = std.mem.splitSequence(u8, source, enter);
        _ = entries.next();
        while (entries.next()) |rest| : (entered += 1) {
            const body = rest[0 .. std.mem.indexOf(u8, rest, "\n    }\n") orelse rest.len];
            try std.testing.expect(std.mem.indexOf(u8, body, "entry.finish") != null);
        }
    }
    // The Store's queue: `release`, `closing`, `writeWaiting`, `take`, and its tests' `waitQueued`.
    try std.testing.expectEqual(@as(usize, 5), locks);
    try std.testing.expectEqual(@as(usize, 1), fence_stores);
    try std.testing.expectEqual(@as(usize, 1), fence_loads);
    try std.testing.expect(entered > 0);
}
