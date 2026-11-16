//! Obligation SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const denyForTesting = tests.denyForTesting;
const expectOneWork = tests.expectOneWork;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingStore = store_testing.testingSqliteStore;
const statementWorkSince = shared_fixtures.statementWorkSince;

const DescendantHistory = enum { settled, queued, active };

fn expectDescendantHistoryCost(kind: DescendantHistory) !void {
    var costs: [2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &costs) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const root = try configureTestSession(&storage, "descendant-cost-root");
        const child = try configureTestSession(&storage, "descendant-cost-child");
        try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
        // Excluded admissions deliberately remain unbound, just as model
        // admission leaves them. A later eligible admission must seek past
        // this history, rather than visit each row and reject it by cutoff.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const seed = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT value,'{1s}',printf('excluded-%d',value),1,value+1,1 FROM sequence; " ++
                "INSERT INTO session_stop(command_key,session_ref,admission_cutoff,position,stopped_at) VALUES('history-stop','{1s}',{0},{0}+2,1); " ++
                "UPDATE session SET next_position={0}+3 WHERE session_ref='{1s}'",
            .{ history, child.slice() },
            0,
        );
        defer std.testing.allocator.free(seed);
        try sqlite.exec(storage.sqliteDatabase(), seed);
        // Reopen before canonical admission: its identity survey must see
        // the fixture's historical IDs and the normal foreign-key setting.
        try storage.close();
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var expected_since: ?u64 = null;
        if (kind != .settled) {
            try submitTestMessage(&storage, &tmp, "descendant-eligible-file", "descendant-eligible", child.slice(), "live work");
            try submitTestMessage(&storage, &tmp, "descendant-later-file", "descendant-later", child.slice(), "later input");
            // ID order is not time order. Preserve the original minimum over
            // eligible admissions even when a later admission's clock went back.
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=17 WHERE command_key='descendant-eligible'", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=9 WHERE command_key='descendant-later'", .{});
            expected_since = if (kind == .active) 17 else 9;
            if (kind == .active) try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
            try tests.refreshFrontierForTesting(&storage, child.slice());
        }
        for (0..2) |pass| {
            _ = statementWorkSince(storage.sqliteDatabase());
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            var works = [_]report_domain.WorkRead{.{ .session = root.slice() }};
            try report_domain.readWorks(&a, &works);
            try std.testing.expectEqual(expected_since, works[0].inputs.owed_since);
            const work = try works[0].work(1, 1);
            try std.testing.expectEqualStrings(if (kind == .settled) "idle" else "working", @tagName(work.state));
            if (pass == 0) continue;
            var statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
            var measured = false;
            while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each)) {
                if (!std.mem.startsWith(u8, std.mem.span(c.sqlite3_sql(each)), "SELECT (SELECT obligation_since FROM session WHERE session_ref=")) continue;
                try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_RUN, 0));
                cost.* = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 0);
                measured = true;
            }
            try std.testing.expect(measured);
        }
    }
    std.debug.print("descendant {s}: excluded=10 {d} VM steps; excluded=10000 {d} VM steps\n", .{ @tagName(kind), costs[0], costs[1] });
    try std.testing.expectEqual(costs[0], costs[1]);
}

test "descendant work cost is flat in excluded history with no live work" {
    try expectDescendantHistoryCost(.settled);
}

test "descendant work cost is flat in excluded history with eligible queued Messages" {
    try expectDescendantHistoryCost(.queued);
}

test "descendant work cost is flat in excluded history with active Turns" {
    try expectDescendantHistoryCost(.active);
}

test "obligation frontier read cost is flat in finished children" {
    var costs: [2]i32 = undefined;
    var writer_costs: [2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &costs, &writer_costs) |history, *cost, *writer_cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const root = try configureTestSession(&storage, "finished-frontier-root");
        // Native VM fixture: terminal children have no owed rows or input.
        // As in the other cost fixtures, unrelated FK contents are omitted.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const seed = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key,parent_ref) " ++
                "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,2,1,value+100,zeroblob(32),1,'{1s}' FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_at,outcome_position,outcome_content_id) " ++
                "SELECT value,printf('%06d',value),value,value,1,'completed',1,1,1 FROM sequence",
            .{ history, root.slice() },
            0,
        );
        defer std.testing.allocator.free(seed);
        try sqlite.exec(storage.sqliteDatabase(), seed);
        // Also drive the write owner against the large finished population.
        _ = statementWorkSince(storage.sqliteDatabase());
        try tests.refreshFrontierForTesting(&storage, root.slice());
        var statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
        var writer_measured = false;
        while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each)) {
            if (!std.mem.startsWith(u8, std.mem.span(c.sqlite3_sql(each)), "UPDATE session SET obligation_since=")) continue;
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_RUN, 0));
            writer_cost.* = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 0);
            writer_measured = true;
        }
        try std.testing.expect(writer_measured);
        for (0..2) |pass| {
            _ = statementWorkSince(storage.sqliteDatabase());
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            var work = [_]report_domain.WorkRead{.{ .session = root.slice() }};
            try report_domain.readWorks(&a, &work);
            try std.testing.expect(work[0].inputs.owed_since == null);
            try std.testing.expect((try work[0].work(1, 1)).state == .idle);
            if (pass == 0) continue;
            statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
            var measured = false;
            while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each)) {
                if (!std.mem.startsWith(u8, std.mem.span(c.sqlite3_sql(each)), "SELECT (SELECT obligation_since FROM session WHERE session_ref=")) continue;
                try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_RUN, 0));
                cost.* = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 0);
                measured = true;
            }
            try std.testing.expect(measured);
        }
    }
    std.debug.print("obligation finished children: 10={d} VM steps; 10000={d} VM steps\n", .{ costs[0], costs[1] });
    try std.testing.expectEqual(costs[0], costs[1]);
    std.debug.print("obligation owner finished children: 10={d} VM steps; 10000={d} VM steps\n", .{ writer_costs[0], writer_costs[1] });
    try std.testing.expectEqual(writer_costs[0], writer_costs[1]);
}

test "Session work dates a tool group by its last acceptance, even when the clock stepped back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Ask: denying one Action leaves the other awaiting, so the Session
    // awaits approval from that denial, though the clock read earlier than
    // at the proposal.
    const ask = try configureTestSessionAsk(&storage, "stepped-ask");
    try submitTestMessage(&storage, &tmp, "stepped-ask-input", "stepped-ask-input", ask.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-ask-calls");
    const first = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
    try denyForTesting(&storage, ask.slice(), "stepped-deny-first", first);
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET resolved_at=300;UPDATE action_operation SET resolved_at=100 WHERE resolution_code IS NOT NULL", .{});
    try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, ask.slice(), "approval"));
    // Denying the other settles the group: pending from the later denial,
    // whose clock read earlier still.
    try denyForTesting(&storage, ask.slice(), "stepped-deny-second", try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{}));
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET resolved_at=" ++
        "CASE WHEN acceptance_position=(SELECT max(acceptance_position) FROM action_operation) THEN 50 ELSE 100 END", .{});
    try std.testing.expectEqual(@as(u64, 50), try expectOneWork(&storage, &tmp, ask.slice(), "pending"));

    // Bypass: both Actions are authorized with the proposal. Once one has
    // run, the other waits for a slot from that run's resolution, not from
    // its own authorization, whatever the clock read.
    const bypass = try configureTestSessionAsk(&storage, "stepped-bypass");
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("stepped-bypass-mode");
    try update.session.set(bypass.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stepped-bypass-input", "stepped-bypass-input", bypass.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-bypass-calls");
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
    var sql: [256]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE model_operation SET resolved_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET decided_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET resolved_at=70 WHERE session_ref='{0s}' AND resolution_code IS NOT NULL", .{bypass.slice()}, 0));
    try std.testing.expectEqual(@as(u64, 70), try expectOneWork(&storage, &tmp, bypass.slice(), "pending"));
    try std.testing.expect(!storage.isFenced());
}
