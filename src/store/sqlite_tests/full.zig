//! Full SQLite mechanism tests.
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const report_domain = @import("../domain/report.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeModelInterruption = tests.completeModelInterruption;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const denyForTesting = tests.denyForTesting;
const settleCallsForTesting = tests.settleCallsForTesting;
const testingBytesContent = tests.testingBytesContent;
const testingFullHistory = tests.testingFullHistory;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;

test "Full Message projection work does not multiply Messages by stops" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(message_count: usize, stop_count: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "full-scale-config");
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");

            for (1..message_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at,admission_position) " ++
                        "VALUES({0},'{1s}','message-{0}',1,NULL,1,{2})",
                    .{ index, session.slice(), 1000 + index },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.sqliteDatabase(), insert);
            }
            for (1..stop_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
                        "VALUES('stop-{0}',3,'{2s}',zeroblob(32),NULL,NULL,1,'accepted',0,0,(SELECT coalesce(max(command_seq),0)+1 FROM core_command));" ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                        "VALUES('stop-{0}','{2s}',NULL,{1},{0},1)",
                    .{ index, message_count, session.slice() },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.sqliteDatabase(), insert);
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(32, 32);
    const more_messages = try Measure.run(128, 32);
    const more_stops = try Measure.run(32, 128);
    const both_larger = try Measure.run(128, 128);
    try std.testing.expect(more_messages > baseline);
    try std.testing.expect(more_stops > baseline);
    try std.testing.expect(both_larger > more_messages);
    try std.testing.expect(both_larger > more_stops);
    try std.testing.expect(both_larger * 2 < (more_messages + more_stops) * 3);
}

/// How many times `S` ran since the last call for it.
fn testingRuns(storage: *Store, comptime S: type) i64 {
    const statement = storage.engine.sqlite.statements.find(S.sql.ptr) orelse return 0;
    return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_RUN, 1);
}

/// How many VM steps `S` took since the last call for it.
fn testingSteps(storage: *Store, comptime S: type) i64 {
    const statement = storage.engine.sqlite.statements.find(S.sql.ptr) orelse return 0;
    return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
}

test "Full interruptions seek their Session's commands, within 90% of main's steps" {
    // Main's interruption statement stepped 6612, 22540 and 90124 times on
    // these Sessions (origin/main 2e8e8353, the same rejected commands),
    // scanning every interruption and sorting the Session's. Each chunk
    // here seeks `core_command_target_order` from where the one before
    // stopped; a chunk that scanned and sorted again took 8 times main's
    // steps at 4096. Its interruption row is a LEFT JOIN (`rsql.Page`),
    // about 4 steps a row more than the CROSS JOIN before it.
    const main_steps = [_]i64{ 6612, 22540, 90124 };
    for ([_]usize{ 300, 1024, 4096 }, main_steps) |count, main| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "interruptions-scale-config");
        for (0..count) |index| {
            var key: [32]u8 = undefined;
            var command: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
            try command.key.set(try std.fmt.bufPrint(&key, "i-{d}", .{index}));
            try command.session.set(session.slice());
            try std.testing.expect(storage.interruptModel(&command, .{}) == .rejected);
        }
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full));
        _ = testingSteps(&storage, report_domain.full_interruptions);
        _ = testingRuns(&storage, report_domain.full_interruptions);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        const steps = testingSteps(&storage, report_domain.full_interruptions);
        // 5747, 19565 and 78305 steps when this was written.
        if (steps * 10 > main * 9) std.debug.print("{d} interruptions: {d} steps, main {d}\n", .{ count, steps, main });
        try std.testing.expect(steps * 10 <= main * 9);
        // One statement per 256 rows.
        try std.testing.expectEqual(@as(i64, @intCast((count - 1) / 256 + 1)), testingRuns(&storage, report_domain.full_interruptions));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const listed = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
        try std.testing.expectEqual(count, listed.len);
        for (listed, 0..) |row, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "i-{d}", .{index}), row.object.get("command_key").?.string);
        }
    }
}

/// The SQLite plan line a Page arm's first SEARCH must be, from what it
/// walks: e.g. `SEARCH tool_call USING INDEX model_tool_call_session_order
/// (session_ref=? AND (operation_id,call_ordinal)>(?,?))`, with `COVERING`
/// before `INDEX` when `covering`.
fn keysetPlanLine(comptime arm: rsql.Walk.Arm, comptime covering: bool) []const u8 {
    comptime {
        var text: []const u8 = "SEARCH " ++ arm.alias ++ " USING " ++ (if (arm.index) |index| (if (covering) "COVERING " else "") ++ "INDEX " ++ index else "PRIMARY KEY") ++ " (";
        for (arm.prefix) |column| text = text ++ column ++ "=? AND ";
        if (arm.key.len == 1) return text ++ arm.key[0] ++ ">?)";
        var columns: []const u8 = "";
        var parameters: []const u8 = "";
        for (arm.key, 0..) |column, k| {
            columns = columns ++ (if (k == 0) "" else ",") ++ column;
            parameters = parameters ++ (if (k == 0) "" else ",") ++ "?";
        }
        return text ++ "(" ++ columns ++ ")>(" ++ parameters ++ "))";
    }
}

/// Fails unless `S`'s plan starts each arm, outside its subqueries, with
/// exactly the SEARCH its walk derives (`keysetPlanLine`), merges a
/// compound's arms without a sort, and has no SCAN and no temporary
/// B-tree anywhere, subqueries included.
fn expectKeysetPlan(storage: *Store, comptime S: type) !void {
    const walk = S.page_walk;
    const text = "EXPLAIN QUERY PLAN " ++ S.sql;
    var statement: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.sqliteDatabase(), text.ptr, @intCast(text.len), &statement, null));
    defer _ = c.sqlite3_finalize(statement);
    var subqueries: [64]c_int = undefined;
    var subquery_count: usize = 0;
    var searched: [64]c_int = undefined;
    var arm: usize = 0;
    var merged = false;
    var plan: [4096]u8 = undefined;
    var plan_length: usize = 0;
    const sound = while (c.sqlite3_step(statement) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(statement, 0);
        const parent = c.sqlite3_column_int(statement, 1);
        const detail = std.mem.span(c.sqlite3_column_text(statement, 3));
        if (std.fmt.bufPrint(plan[plan_length..], "  {d} {d} {s}\n", .{ id, parent, detail })) |line| plan_length += line.len else |_| {}
        if (std.mem.indexOf(u8, detail, "TEMP B-TREE") != null or std.mem.startsWith(u8, detail, "SCAN ")) break false;
        if (std.mem.eql(u8, detail, "MERGE (UNION ALL)")) merged = true;
        if (std.mem.indexOf(u8, detail, "SUBQUERY") != null or std.mem.indexOfScalar(c_int, subqueries[0..subquery_count], parent) != null) {
            subqueries[subquery_count] = id;
            subquery_count += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, detail, "SEARCH ")) continue;
        if (std.mem.indexOfScalar(c_int, searched[0..arm], parent) != null) continue;
        if (arm == walk.arms.len) break false;
        const matched = inline for (walk.arms, 0..) |path, i| {
            if (i == arm) break std.mem.eql(u8, detail, comptime keysetPlanLine(path, false)) or std.mem.eql(u8, detail, comptime keysetPlanLine(path, true));
        } else false;
        if (!matched) break false;
        searched[arm] = parent;
        arm += 1;
    } else arm == walk.arms.len and (walk.arms.len == 1 or merged);
    if (sound) return;
    std.debug.print("{s}\n{s}", .{ S.sql, plan[0..plan_length] });
    inline for (walk.arms) |path| std.debug.print("expected: {s}\n", .{comptime keysetPlanLine(path, false)});
    return error.TestUnexpectedResult;
}

test "every Full list walks its own index from the keyset: a chunk seeks, and sorts nothing" {
    // Each list's Page names the index each arm walks on its own table,
    // and the plan's first SEARCH of each arm must be exactly that
    // index's range from the keyset. A chunk that sorted (P2 #2), started
    // on another table (P2 #1) or searched a parent's rows (P2 #3) read
    // again rows the chunks before it read: one Operation's 4096 rejected
    // calls took 89777216 steps.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    inline for (report_domain.full_pages) |S| try expectKeysetPlan(&storage, S);
}

/// Codex's mixed history at `count`: one Operation with `count` calls,
/// Bash and unknown in turn, every Bash call's Action denied (last first,
/// so acceptance order is not call order), then `count` answered Turns
/// with no call; and another Session's `count` rejected calls. Returns
/// each Full statement's steps for the second of two reports.
fn mixedHistorySteps(count: usize) ![report_domain.full_pages.len]i64 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"mixed-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"};
    const other = try configureTestSessionAsk(&storage, "mixed-other-config");
    const session = try configureTestSessionAsk(&storage, "mixed-config");
    for ([_][]const u8{ other.slice(), session.slice() }, [_]bool{ false, true }) |target, mine| {
        try submitTestMessage(&storage, &tmp, if (mine) "mixed-input" else "mixed-other-input", if (mine) "mixed-key" else "mixed-other-key", target, "many calls");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = try arena.allocator().alloc(TestingCall, count);
        for (calls, 0..) |*call, index| {
            const bash = mine and index % 2 == 0;
            const id = try std.fmt.allocPrint(arena.allocator(), "{s}-{d}", .{ if (mine) "mixed" else "other", index });
            call.* = .{
                .item_id = id,
                .name = if (bash) "bash" else "unknown",
                .encoded_call_id = id,
                .decoded_call_id = id,
                .encoded_arguments = if (bash) "{\\\"description\\\":\\\"List files\\\",\\\"cmd\\\":\\\"ls\\\",\\\"timeout_ms\\\":null}" else "{}",
                .decoded_arguments = if (bash) "{\"description\":\"List files\",\"cmd\":\"ls\",\"timeout_ms\":null}" else "{}",
            };
        }
        try settleCallsForTesting(&storage, &tmp, binding, if (mine) "mixed" else "mixed-other", calls);
        if (!mine) {
            const answered = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, answered, &items, "Done.");
            continue;
        }
        const last = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
        for (0..count / 2) |step| {
            var key: [32]u8 = undefined;
            try denyForTesting(&storage, target, try std.fmt.bufPrint(&key, "mixed-deny-{d}", .{step}), last - step);
        }
        const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, continued, &items, "Done.");
        for (0..count) |index| {
            var name: [32]u8 = undefined;
            var key: [32]u8 = undefined;
            try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&name, "mixed-in-{d}", .{index}), try std.fmt.bufPrint(&key, "mixed-turn-{d}", .{index}), target, "input");
            const turn = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, turn, &items, "Done.");
        }
    }
    std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full));
    inline for (report_domain.full_pages) |S| _ = testingSteps(&storage, S);
    const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full);
    defer std.testing.allocator.free(full);
    var steps: [report_domain.full_pages.len]i64 = undefined;
    inline for (report_domain.full_pages, 0..) |S, i| steps[i] = testingSteps(&storage, S);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
    defer parsed.deinit();
    const lists = parsed.value.object.get("full").?.object;
    try std.testing.expectEqual(count, lists.get("tool_calls").?.array.items.len);
    try std.testing.expectEqual(count, lists.get("tool_results").?.array.items.len);
    try std.testing.expectEqual(count / 2, lists.get("actions").?.array.items.len);
    try std.testing.expectEqual(count + 2, lists.get("model_operations").?.array.items.len);
    return steps;
}

test "Full lists grow linearly on a mixed history" {
    // Pins growth, not counts: each Full statement's steps at 4N are at
    // most 4.5 times those at N. A statement whose chunks reopened a walk
    // of the call-free Operations after the current one grew 10 and 12
    // times (a9a0f7eb's calls, 15413 to 160133 steps, and results, 23494
    // to 290902). Fitted as aN^2+bN, those would grow 8.4 and 10.4 times
    // from 64 to 256.
    const small = try mixedHistorySteps(64);
    const large = try mixedHistorySteps(256);
    var linear = true;
    inline for (report_domain.full_pages, small, large) |S, at_n, at_4n| {
        if (at_4n * 2 > at_n * 9) {
            std.debug.print("{d} steps at N, {d} at 4N: {s}\n", .{ at_n, at_4n, S.sql });
            linear = false;
        }
    }
    try std.testing.expect(linear);
}

test "Full calls and results of one Operation take a seek per chunk, within twice main's steps" {
    // One Operation's 4096 rejected calls: main's two statements stepped
    // 249888 times (origin/main 2e8e8353), and read each content's
    // metadata apart, 245810 more; these read it in their rows. A chunk
    // that searched the Operation's calls again took 89777216 steps for
    // the report.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "one-operation-config");
    try submitTestMessage(&storage, &tmp, "one-operation-input", "one-operation-key", session.slice(), "many calls");
    const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const count = 4096;
    const calls = try std.testing.allocator.alloc(TestingCall, count);
    defer std.testing.allocator.free(calls);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (calls, 0..) |*call, index| {
        const id = try std.fmt.allocPrint(arena.allocator(), "one-{d}", .{index});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "one-operation", calls);
    std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full));
    _ = testingSteps(&storage, report_domain.full_calls);
    _ = testingSteps(&storage, report_domain.full_results);
    const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full);
    defer std.testing.allocator.free(full);
    const steps = testingSteps(&storage, report_domain.full_calls) + testingSteps(&storage, report_domain.full_results);
    // 480136 when this was written.
    try std.testing.expect(steps <= 2 * 249888);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
    defer parsed.deinit();
    for ([_][]const u8{ "tool_calls", "tool_results" }) |name| {
        const listed = parsed.value.object.get("full").?.object.get(name).?.array.items;
        try std.testing.expectEqual(@as(usize, count), listed.len);
        for (listed, 0..) |row, index| {
            var ordinal: [16]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&ordinal, "{d}", .{index}), row.object.get("call_ordinal").?.string);
        }
    }
}

test "a Full list takes a statement per 256 rows, and lists each row once in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "chunked-stops-config");
    // An interrupted Operation: the interruptions list follows the stops
    // in their run, and renders only once the stops finished.
    try submitTestMessage(&storage, &tmp, "chunked-interrupt", "chunked-interrupt", session.slice(), "interrupt me");
    const interrupted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var interrupt = try completeModelInterruption("chunked-interrupt-command", session.slice(), interrupted);
    try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
    if (try storage.admitNextModelAttempt(.{})) |successor| {
        const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}"};
        try settleItemsForTesting(&storage, &tmp, successor.permit.binding, &items, "ok");
    }
    for ([_]usize{ 256, 257, 513 }) |rows| {
        while (try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM core_command WHERE kind=3", .{}) < rows) {
            var key: [32]u8 = undefined;
            var stop = try completeSessionStop(try std.fmt.bufPrint(&key, "chunked-stop-{d:0>4}", .{try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM core_command WHERE kind=3", .{})}), session.slice());
            // An idle Session accepts each stop.
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        }
        _ = testingRuns(&storage, report_domain.full_stops);
        _ = testingRuns(&storage, report_domain.full_interruptions);
        _ = testingRuns(&storage, report_domain.full_results);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        // 256 rows and the 257th row's absence fit one statement; a 257th
        // row takes a second, and a 513th a third. The interruptions, read
        // ahead beside the stops' first chunk only, are read again once
        // the stops finish; the results, read ahead and found empty, are
        // not.
        const chunks: i64 = @intCast((rows + 255) / 256);
        try std.testing.expectEqual(chunks, testingRuns(&storage, report_domain.full_stops));
        try std.testing.expectEqual(@min(chunks, 2), testingRuns(&storage, report_domain.full_interruptions));
        try std.testing.expectEqual(@as(i64, 1), testingRuns(&storage, report_domain.full_results));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const stops = parsed.value.object.get("full").?.object.get("session_stops").?.array.items;
        try std.testing.expectEqual(rows, stops.len);
        for (stops, 0..) |stop, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "chunked-stop-{d:0>4}", .{index}), stop.object.get("command_key").?.string);
        }
        const interruptions = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), interruptions.len);
        try std.testing.expectEqualStrings("chunked-interrupt-command", interruptions[0].object.get("command_key").?.string);
    }
    try std.testing.expect(!storage.isFenced());
}

test "Full revisions read no statement past a last revision that shows content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "last-revision-config");
    var reconfigure: wire_request.ConfigureCommand = .{};
    try reconfigure.key.set("last-revision");
    try reconfigure.session.set(session.slice());
    reconfigure.configuration.instructions = try testingBytesContent(&tmp, "last-revision-instructions", "Be brief.");
    try std.testing.expect(try storage.configure(&reconfigure, .{}) == .accepted);
    _ = testingRuns(&storage, report_domain.full_revisions);
    std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), null));
    // The chunk stops after the second revision to stream its
    // instructions; its row's `newest` says no revision follows.
    try std.testing.expectEqual(@as(i64, 1), testingRuns(&storage, report_domain.full_revisions));
}

test "a Full list keeps the rows whose content it shows whole for after their chunk, in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "chunked-messages-config");
    // Each Message's text is longer than one content window. Two chunks'
    // kept rows take two statements, the second finding no row after its
    // last; one more row takes a third.
    const pending = report_domain.Messages.kept_rows;
    var text: [2100]u8 = undefined;
    var count: usize = 0;
    for ([_]usize{ 2 * pending, 2 * pending + 1 }, [_]i64{ 2, 3 }) |rows, statements| {
        while (count < rows) : (count += 1) {
            var name: [32]u8 = undefined;
            var key: [32]u8 = undefined;
            @memset(&text, @intCast('a' + count));
            try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&name, "chunked-message-{d}", .{count}), try std.fmt.bufPrint(&key, "chunked-message-{d}", .{count}), session.slice(), &text);
        }
        _ = testingRuns(&storage, report_domain.full_messages);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        try std.testing.expectEqual(statements, testingRuns(&storage, report_domain.full_messages));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const messages = parsed.value.object.get("full").?.object.get("messages").?.array.items;
        try std.testing.expectEqual(rows, messages.len);
        for (messages, 0..) |message, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "chunked-message-{d}", .{index}), message.object.get("command_key").?.string);
            @memset(&text, @intCast('a' + index));
            try std.testing.expectEqualStrings(&text, message.object.get("content").?.object.get("text").?.string);
        }
    }
}

test "Full Messages refuse a position that leaves one out or lists one before an earlier admission" {
    const faults = [_][:0]const u8{
        "UPDATE message_admission SET admission_position=NULL WHERE command_key='ordered-message-1'",
        "UPDATE message_admission SET admission_position=1000000 WHERE command_key='ordered-message-0'",
        // A repeated position: the keyset does not grow.
        "UPDATE message_admission SET admission_position=(SELECT admission_position FROM message_admission WHERE command_key='ordered-message-0') WHERE command_key='ordered-message-1'",
    };
    for ([_]?[:0]const u8{null} ++ faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "ordered-messages-config");
        try submitTestMessage(&storage, &tmp, "ordered-message-0", "ordered-message-0", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "ordered-message-1", "ordered-message-1", session.slice(), "second");
        if (fault) |sql| {
            try sqlite.exec(storage.sqliteDatabase(), sql);
            try std.testing.expectError(error.CorruptStore, testingFullHistory(&storage, &tmp, session.slice(), null));
        } else std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}

test "Full history refuses a decision or interruption command without its row, or one naming another Session" {
    // Main joined each row to its command and skipped a command without
    // one; the Page walks the commands and LEFT JOINs the row.
    const faults = [_][:0]const u8{
        "DELETE FROM permission_decision_command WHERE command_key='missing-row-decision'",
        "DELETE FROM model_interruption_command WHERE command_key='missing-row-interruption'",
        "UPDATE model_interruption_command SET session_ref='elsewhere' WHERE command_key='missing-row-interruption'",
    };
    for ([_]?[:0]const u8{null} ++ faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "missing-row-config");
        var decision: protocol.PermissionDecisionCommand = .{ .action_id = 999999, .decision = .deny };
        try decision.key.set("missing-row-decision");
        try decision.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&decision, .{}) == .rejected);
        var interruption: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
        try interruption.key.set("missing-row-interruption");
        try interruption.session.set(session.slice());
        try std.testing.expect(storage.interruptModel(&interruption, .{}) == .rejected);
        if (fault) |sql| {
            try sqlite.exec(storage.sqliteDatabase(), sql);
            try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
        } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
    }
}

test "Full history reads a payload's declared bytes: a short one fails, a longer one shows its prefix, as on main" {
    // `content`'s CHECK keeps payload and byte_length equal; the test
    // turns it off to store a payload of the wrong length.
    for ([_][]const u8{ "", "short", "longer" }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "payload-config");
        try submitTestMessage(&storage, &tmp, "payload-message", "payload-message", session.slice(), "payload");
        const id = "(SELECT content_id FROM message_admission WHERE command_key='payload-message')";
        if (std.mem.eql(u8, case, "short")) {
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('pay' AS BLOB) WHERE content_id=" ++ id ++ "; PRAGMA ignore_check_constraints=OFF");
            try std.testing.expectError(error.ContentReadFailed, testingFullHistory(&storage, &tmp, session.slice(), null));
            continue;
        }
        if (std.mem.eql(u8, case, "longer")) try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('payload and more' AS BLOB) WHERE content_id=" ++ id ++ "; PRAGMA ignore_check_constraints=OFF");
        const full = try testingFullHistory(&storage, &tmp, session.slice(), null);
        defer std.testing.allocator.free(full);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const message = parsed.value.object.get("full").?.object.get("messages").?.array.items[0];
        try std.testing.expectEqualStrings("payload", message.object.get("content").?.object.get("text").?.string);
    }
}

test "Full history answers a later row's failure before a kept row's content, where main read the content first" {
    // The first Message shows its content whole, so its chunk keeps it;
    // the second is listed ahead of an earlier admission, which its row
    // check refuses in the pass, before the first's short payload is read.
    for ([_]bool{ false, true }) |later_fails| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "double-fault-config");
        try submitTestMessage(&storage, &tmp, "double-fault-0", "double-fault-0", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "double-fault-1", "double-fault-1", session.slice(), "second");
        try submitTestMessage(&storage, &tmp, "double-fault-2", "double-fault-2", session.slice(), "third");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('fi' AS BLOB) " ++
            "WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='double-fault-0'); PRAGMA ignore_check_constraints=OFF");
        if (later_fails) {
            // The third is listed between the first and the second.
            try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET admission_position=(SELECT admission_position FROM message_admission WHERE command_key='double-fault-0') " ++
                "WHERE command_key='double-fault-2'; UPDATE message_admission SET admission_position=admission_position+10 WHERE command_key='double-fault-1'", .{});
            try std.testing.expectError(error.CorruptStore, testingFullHistory(&storage, &tmp, session.slice(), null));
        } else try std.testing.expectError(error.ContentReadFailed, testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}

test "Full history's step faults keep main's names, and its content and stop reads take their list's" {
    // Main read the Messages' stops in a statement of their own
    // (SessionStopReadFailed) and every content's metadata apart
    // (CorruptStore); each is a column of its list's statement now. The
    // Current facts read both tables first, so only the history alone
    // reaches them. A decision's and an interruption's row is read by
    // its command's key, so the Session holds one rejected command of
    // each.
    inline for (.{
        .{ "session_stop", error.MessageReadFailed, false },
        .{ "content", error.SessionReadFailed, false },
        .{ "permission_decision_command", error.PermissionReadFailed, true },
        .{ "model_interruption_command", error.InterruptionReadFailed, true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "history-faults-config");
        // A Message no Turn took, so its stop is looked for.
        try submitTestMessage(&storage, &tmp, "history-faults-message", "history-faults-message", session.slice(), "queued");
        var decision: protocol.PermissionDecisionCommand = .{ .action_id = 999999, .decision = .deny };
        try decision.key.set("history-faults-decision");
        try decision.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&decision, .{}) == .rejected);
        var interruption: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
        try interruption.key.set("history-faults-interruption");
        try interruption.session.set(session.slice());
        try std.testing.expect(storage.interruptModel(&interruption, .{}) == .rejected);
        try store_testing.failReadsOf(&storage, case[0]);
        if (case[2]) {
            try std.testing.expectError(case[1], testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
        } else try std.testing.expectError(case[1], testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}
