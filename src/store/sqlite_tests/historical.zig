//! Historical SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const model_admission_domain = @import("../domain/model_admission.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const HistoricalEntry = historical_domain.HistoricalEntry;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalView = historical_domain.HistoricalView;
const OutputItemKind = historical_domain.OutputItemKind;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingAttempt = tests.TestingAttempt;
const TestingCall = tests.TestingCall;
const TestingHistoryCursor = tests.TestingHistoryCursor;
const namedStatementForTesting = tests.namedStatementForTesting;
const renderTestingEntry = tests.renderTestingEntry;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleCallsForTestingWithFaults = tests.settleCallsForTestingWithFaults;
const testSettings = tests.testSettings;
const testingSessionReport = tests.testingSessionReport;
const testingStore = store_testing.testingSqliteStore;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const runsOf = shared_fixtures.runsOf;
const statementWorkSince = shared_fixtures.statementWorkSince;

test "complete historical tool-result traversal scales with groups and calls" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(group_count: usize, calls_per_group: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "scale-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "scale-message-file",
                "scale-message",
                session.slice(),
                "scale",
            );
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [32]TestingCall = undefined;
            var item_ids: [32][32]u8 = undefined;
            var call_ids: [32][32]u8 = undefined;
            for (calls[0..calls_per_group], 0..) |*call, index| {
                const item_id = try std.fmt.bufPrint(&item_ids[index], "scale-item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&call_ids[index], "scale-call-{d}", .{index});
                call.* = .{
                    .item_id = item_id,
                    .name = "unknown",
                    .encoded_call_id = call_id,
                    .decoded_call_id = call_id,
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
            }
            for (0..group_count) |index| {
                var prefix_buffer: [64]u8 = undefined;
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    binding,
                    try std.fmt.bufPrint(&prefix_buffer, "scale-metadata-{d}", .{index}),
                    calls[0..calls_per_group],
                );
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var position: u64 = 0;
            var groups_seen: usize = 0;
            var results_seen: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.kind != .tool_results) continue;
                groups_seen += 1;
                while (try view.nextToolResult()) |_| {
                    results_seen += 1;
                }
            }
            try std.testing.expectEqual(group_count, groups_seen);
            try std.testing.expectEqual(group_count * calls_per_group, results_seen);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(4, 1);
    const more_groups = try Measure.run(16, 1);
    const call_baseline = try Measure.run(4, 8);
    const more_calls = try Measure.run(4, 32);
    try std.testing.expect(more_groups > baseline);
    try std.testing.expect(more_groups < baseline * 7);
    try std.testing.expect(more_calls > call_baseline);
    try std.testing.expect(more_calls < call_baseline * 8);
}

/// One bounded step through history in preparation order. Each served
/// entry moves `after` past it, a tool group is drained, and the end sets
/// `after` to the largest position.
fn testingHistoricalStep(view: *HistoricalView, after: *u64, bytes: *usize, items: *usize) !void {
    switch (try view.nextEntryStep(after.*, bytes, items)) {
        .pending => {},
        .ready => |served| if (served) |entry| {
            after.* = entry.position;
            if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
        } else {
            after.* = std.math.maxInt(u64);
        },
    }
}

test "historical preparation yields covered group populations under small allowances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&storage, "bounded-config");
    try submitTestMessage(&storage, &tmp, "bounded-input", "bounded-input", allocated_session_0.slice(), "tools");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var calls: [16]TestingCall = undefined;
    var ids: [16][32]u8 = undefined;
    const arguments: [3072]u8 = @splat('x');
    for (&calls, 0..) |*call, i| {
        const id = try std.fmt.bufPrint(&ids[i], "bounded-{d}", .{i});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = &arguments, .decoded_arguments = &arguments };
    }
    for (0..8) |i| {
        var prefix: [32]u8 = undefined;
        try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "bounded-{d}", .{i}), &calls);
        binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    }
    // An after-position covering every group must not drain discovery in one
    // call, and a view closed mid-discovery leaves checkpoints free.
    {
        var view: HistoricalView = undefined;
        storage.openHistoricalView(binding, &view);
        while (!try view.validateOutputsStep()) {}
        var bytes: usize = 7;
        var items: usize = 1;
        try std.testing.expect(try view.nextEntryStep(view.output_boundary, &bytes, &items) == .pending);
        _ = try configureTestSession(&storage, "yielded-checkpoint");
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        view.close();
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    var view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &view);
    defer view.close();
    while (!try view.validateOutputsStep()) {}
    var turns: usize = 0;
    var served: usize = 0;
    var after: u64 = 0;
    while (after != std.math.maxInt(u64)) {
        turns += 1;
        try std.testing.expect(turns < 200000);
        var bytes: usize = 127;
        var items: usize = 3;
        const before = after;
        try testingHistoricalStep(&view, &after, &bytes, &items);
        if (after != before) served += 1;
    }
    // One user input, 8 Operations each with its group of 16 calls, their
    // 8 result groups and the end, each served by its own step: a page of
    // the scan holds whole groups, so discovery yields none between them.
    try std.testing.expectEqual(@as(usize, 1 + 8 + 8 * calls.len + 8 + 1), served);
    try std.testing.expectEqual(served, turns);
    try std.testing.expect(!storage.isFenced());
}

test "large historical readers leave checkpoints free" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const text = try std.testing.allocator.alloc(u8, 1024 * 1024 + 37);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = @intCast('a' + index % 23);
    const session = try configureTestSession(&storage, "large-history-config");
    try submitTestMessage(&storage, &tmp, "large-history-input", "large-history-key", session.slice(), text);
    const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, source, "large-history-call", &.{.{
        .item_id = "large-item",
        .name = "unknown",
        .encoded_call_id = "large-call",
        .decoded_call_id = "large-call",
        .encoded_arguments = text,
        .decoded_arguments = text,
    }});
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    storage.openHistoricalView(continuation, &view);
    defer view.close();
    const entry = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, entry.kind);
    var reader: HistoricalReader = undefined;
    try view.openContent(entry.content.?, &reader);
    defer reader.close();
    reader.reader.allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < text.len) {
        const wanted = @min(buffer.len, text.len - offset);
        try std.testing.expectEqual(wanted, try reader.read(offset, &buffer));
        try std.testing.expectEqualSlices(u8, text[offset..][0..wanted], buffer[0..wanted]);
        if (offset == 0) {
            _ = try configureTestSession(&storage, "large-history-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
        offset += wanted;
    }
    try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &buffer));
    try std.testing.expect(!storage.isFenced());
}

test "historical preparation rejects missing extra and reordered sibling classifications incrementally" {
    for ([_]bool{ false, true }) |covered| {
        // `corrupts_bytes`: the fault breaks bytes replay reads, not rows.
        cases: for ([_]struct { sql: [:0]const u8, corrupts_bytes: bool = false }{
            .{ .sql = "UPDATE model_tool_call SET call_ordinal=99 WHERE call_ordinal=0; UPDATE model_tool_call SET call_ordinal=0 WHERE call_ordinal=1; UPDATE model_tool_call SET call_ordinal=1 WHERE call_ordinal=99" },
            .{ .sql = "DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "UPDATE model_output_item SET item_kind=1 WHERE item_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE item_ordinal=1; DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE operation_id IN (SELECT operation_id FROM model_tool_call); DELETE FROM model_tool_call" },
            .{ .sql = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1", .corrupts_bytes = true },
        }) |fault| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "sibling-config");
            try submitTestMessage(&storage, &tmp, "sibling-input", "sibling-input", session.slice(), "tools");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, source, "sibling-output", &calls);
            var next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (covered) {
                try storage.settleModelAttemptFailure(next, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault.sql);
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            while (!(view.validateOutputsStep() catch |err| {
                try std.testing.expectEqual(error.CorruptStore, err);
                try std.testing.expect(storage.isFenced());
                continue :cases;
            })) {}
            // Row faults fail while discovery walks the group, before any
            // entry is served. Corrupt call bytes fence when replay reads
            // the first call, whose digest no longer matches.
            const bytes_fault = fault.corrupts_bytes;
            var served: ?HistoricalEntry = null;
            while (true) {
                var bytes: usize = 1;
                var items: usize = 1;
                const progress = view.nextEntryStep(if (served) |entry| entry.position else 0, &bytes, &items) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    try std.testing.expect(!bytes_fault);
                    break;
                };
                if (!bytes_fault and view.tool_group_initialized) return error.MissingCorruptionFailure;
                switch (progress) {
                    .pending => {},
                    .ready => |entry| {
                        // The view never reaches its end, so no request seals.
                        if (!bytes_fault) return error.MissingCorruptionFailure;
                        served = entry.?.*;
                        if (served.?.kind == .user or served.?.kind == .operation) continue;
                        try std.testing.expectEqual(HistoricalEntryKind.provider_output, served.?.kind);
                        const output = try view.openOutput(served.?.position);
                        try std.testing.expectEqual(OutputItemKind.function_call, output.kind);
                        // The call's private bag holds its item ID.
                        var reader: HistoricalReader = undefined;
                        try view.openContent(output.bag.?, &reader);
                        defer reader.close();
                        var buffer: [4096]u8 = undefined;
                        try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(output.bag.?.length)]));
                        break;
                    },
                }
            }
            try std.testing.expect(storage.isFenced());
        }
    }
}

test "historical accepted output selection work excludes failed Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
                "attempt_ordinal,output_reservation,resolution_code,resolved_at,tool_set_id,context_window) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
                "1,0,'failed',1,current.tool_set_id,current.context_window FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            while (!try view.validateOutputsStep()) {}
            return measured.steps;
        }
    };
    const small = try Measure.run(8);
    const large = try Measure.run(1024);
    try std.testing.expect(large <= small + 100);
}

test "replay fences part damage that keeps every digest" {
    for ([_][:0]const u8{
        "DELETE FROM model_output_part WHERE part_ordinal=1",
        "UPDATE model_output_item SET part_count=part_count+1 WHERE item_kind=2",
        "UPDATE model_output_part SET part_array=2,part_kind=3,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0",
        // The text parts must cover the message text in order, exactly.
        "UPDATE model_output_part SET text_length=text_length+1 WHERE part_ordinal=0",
        "UPDATE model_output_part SET text_length=text_length-1 WHERE part_ordinal=1",
        // The text keeps its digest while its bytes change: the parts'
        // reads check it across both ranges.
        "UPDATE content SET payload=CAST('onetwx' AS BLOB) WHERE payload=CAST('onetwo' AS BLOB)",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "part-damage-config");
        const answer = [_]TestingAnswerPart{ .{ .encoded = "one", .decoded = "one" }, .{ .encoded = "two", .decoded = "two" } };
        try answerTestTurn(&storage, &tmp, session.slice(), "part-damage", &answer);
        try submitTestMessage(&storage, &tmp, "part-damage-next", "part-damage-next", session.slice(), "next");
        const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.sqliteDatabase(), fault);
        var view: HistoricalView = undefined;
        storage.openHistoricalView(next, &view);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        var bytes: [512]u8 = undefined;
        while (try cursor.next(&view)) |entry| {
            if (entry.kind != .provider_output) continue;
            try std.testing.expectError(error.CorruptStore, renderTestingEntry(&view, entry, &bytes));
            break;
        } else return error.MissingCorruptionFailure;
        try std.testing.expect(storage.isFenced());
    }
}

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "", workspace, "model-a");
    const created_session_0_reply = try storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    var admitted_attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted_attempt.permit.consume();

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    var view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &view);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "request_preparation_failed" }, .ordinary, .{}),
    );
}

test "historical accepted output completeness and provenance fence both read paths" {
    for ([_]enum { no_base, base, suffix, tied_base, tied_suffix }{ .no_base, .base, .suffix, .tied_base, .tied_suffix }) |scenario| {
        for ([_][:0]const u8{
            "DELETE FROM model_output_item WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=?1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=2",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0",
            "UPDATE model_output_item SET item_ordinal=8 WHERE operation_id=?1 AND item_ordinal=1",
            "UPDATE model_output_item SET session_ref='f0re1g' WHERE operation_id=?1",
            "UPDATE model_output_item SET attempt_ordinal=99 WHERE operation_id=?1",
            "UPDATE model_output_item SET session_position=session_position+1000 WHERE operation_id=?1",
        }) |sql| {
            for ([_]bool{ false, true }) |context_read| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testingStore(&storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                var output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var corrupt_id = output.operation_id;
                var tied_id: ?u64 = null;
                if (scenario != .no_base) {
                    try storage.settleModelAttemptFailure(output, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCompactionForTesting(&storage, &tmp, base, &.{ .reasoning, .compaction, .message });
                    corrupt_id = base.operation_id;
                    if (scenario == .tied_base) tied_id = base.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario == .tied_suffix) {
                    try submitTestMessage(&storage, &tmp, "between", "between", session.slice(), "between");
                    try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message });
                    tied_id = output.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario != .base) corrupt_id = output.operation_id;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
                try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message, .reasoning });
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (tied_id) |previous| {
                    const tie = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE model_operation SET admission_position=" ++
                        "(SELECT admission_position FROM model_operation WHERE operation_id=?1) WHERE operation_id=?2");
                    defer _ = c.sqlite3_finalize(tie);
                    try sqlite.bindU64(tie, 1, previous);
                    try sqlite.bindU64(tie, 2, output.operation_id);
                    try sqlite.expectDone(tie);
                }
                // Message entries now reference their exact raw items. Bypass
                // that FK only while injecting the intended missing-item fault.
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
                const mutation = try sqlite.prepare(storage.sqliteDatabase(), sql);
                defer _ = c.sqlite3_finalize(mutation);
                try sqlite.bindU64(mutation, 1, corrupt_id);
                try sqlite.expectDone(mutation);
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
                var view: HistoricalView = undefined;
                storage.openHistoricalView(next, &view);
                defer view.close();
                if (context_read) {
                    try std.testing.expectError(error.CorruptStore, view.coverage());
                } else {
                    try std.testing.expectError(error.CorruptStore, view.nextEntry(0));
                }
                try std.testing.expect(storage.isFenced());
                try std.testing.expectError(error.StoreFenced, testSettings(&view));
            }
        }
    }
}

test "historical context selection work excludes nonmatching Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, with_base: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (with_base) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, current, &.{ .reasoning, .compaction, .message });
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            // Isolate search work from payload work: failed assistant/compaction
            // Operations have no accepted output. Their population must not be
            // scanned inside one source/frontier/anchor selection step.
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1,current.tool_set_id,current.context_window FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);

            var view: HistoricalView = undefined;
            storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            while (!try view.validateOutputsStep()) {}
            try std.testing.expectEqual(with_base, (try view.coverage()).anchor != null);
            return measured.steps;
        }
    };
    for ([_]bool{ false, true }) |with_base| {
        const small = try Measure.run(8, with_base);
        const large = try Measure.run(1024, with_base);
        try std.testing.expect(large <= small + 100);
    }
}

test "a failed context read answers its reader's name and fences" {
    // The report's `admission_context` names a failed step CorruptStore,
    // as main named the estimate's. Admission reads the context with its
    // facts in selection's round, whose failed step is SessionReadFailed. The second
    // Message follows a Turn with usage under a trigger, so admission
    // weighs the context, and the report estimates it. The report names a
    // failed uncovered-byte read CorruptStore, after selecting the recipe;
    // admission counts the bytes in its guard write, whose failed step is
    // a write's StatementFailed.
    for ([_]struct { report: bool, bytes: bool }{
        .{ .report = false, .bytes = false },
        .{ .report = true, .bytes = false },
        .{ .report = false, .bytes = true },
        .{ .report = true, .bytes = true },
    }) |case| {
        const report = case.report;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "context-fold");
        var patch: wire_request.ConfigureCommand = .{};
        try patch.key.set("context-fold-trigger");
        try patch.session.set(session.slice());
        patch.configuration.compaction_trigger.state = .value;
        try patch.configuration.compaction_trigger.value.set("1000");
        try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "context-fold-one", "context-fold-one", session.slice(), "one");
        const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try submitTestMessage(&storage, &tmp, "context-fold-two", "context-fold-two", session.slice(), "two");
        try settleCallsForTestingWithFaults(&storage, &tmp, first, "context-fold-output", &.{}, .{}, "{\"input_tokens\":10,\"output_tokens\":0}");
        var fault: TestingStatementFault = .{ .sql = if (case.bytes and !report)
            model_admission_domain.within_pressure_sql
        else if (case.bytes)
            namedStatementForTesting(model_admission_domain.compaction_failures, null, " AS uncovered_bytes")
        else if (report)
            namedStatementForTesting(model_admission_domain.compaction_failures, null, "since AS (SELECT")
        else
            model_admission_domain.selected_context_sql };
        fault.arm(storage.sqliteDatabase());
        defer fault.disarm(storage.sqliteDatabase());
        if (report)
            try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024))
        else
            try std.testing.expectError(if (case.bytes) error.StatementFailed else error.SessionReadFailed, storage.admitNextModelAttempt(.{}));
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(storage.isFenced());
    }
}

test "Attempt checks keep main cost and prefix seals include one frontier reconciliation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const attempt = try TestingAttempt.admit(&storage, &tmp);
    // Main's statements and VM steps at 72db6de9 and again at 2e8e8353,
    // each on its warm second call: opening a view, recording a seal, the
    // Operation's kind, a dispatch handoff and a content lookup.
    // The set-based frontier projection and streamed hints add two statements
    // and 797 VM steps to the seal's five statements / 124 VM steps. This
    // bounded CPU work replaces client-side ancestor rounds; the seal keeps
    // main's two Access rounds. Unrelated statement limits stay unchanged.
    const main_work = [_][2]i64{ .{ 2, 24 }, .{ 7, 921 }, .{ 3, 32 }, .{ 2, 24 }, .{ 1, 14 } };
    for (0..2) |call| {
        var work: [main_work.len][2]i64 = undefined;
        _ = statementWorkSince(storage.sqliteDatabase());
        var view: HistoricalView = undefined;
        storage.openHistoricalView(attempt.binding, &view);
        defer view.close();
        work[0] = statementWorkSince(storage.sqliteDatabase());
        try view.recordPrefixSeal(&TestingAttempt.seal);
        work[1] = statementWorkSince(storage.sqliteDatabase());
        _ = try storage.modelOperationKind(attempt.binding);
        work[2] = statementWorkSince(storage.sqliteDatabase());
        try storage.withDispatchHandoff(attempt.binding, {}, TestingAttempt.handoff);
        work[3] = statementWorkSince(storage.sqliteDatabase());
        _ = try storage.openContent(attempt.content);
        work[4] = statementWorkSince(storage.sqliteDatabase());
        if (call == 0) continue;
        for (work, main_work) |measured, main| {
            try std.testing.expect(measured[0] <= main[0]);
            try std.testing.expect(measured[1] <= main[1]);
        }
    }
    // Rounds, where main took 2 for a view, a check or a handoff, 3 for
    // the Operation's kind, 5 for a seal and 1 for a content lookup: each
    // Attempt check is one read; a seal reads, then projects inline with COMMIT.
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    {
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        _ = try model_settlement_domain.attemptKind(&a, attempt.binding);
        try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    }
    {
        var seal: historical_domain.RecordSeal = .{ .input = .{ .binding = attempt.binding, .seal = &TestingAttempt.seal } };
        const before = storage.testing_content_work.rounds;
        try transition.run(&entry, historical_domain.RecordSeal, &seal, .{});
        try std.testing.expectEqual(2, storage.testing_content_work.rounds - before);
    }
    {
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        _ = try content_domain.contentIdOf(&a, attempt.content, false);
        try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    }
}

test "a prefix seal on a full disk answers CanonicalStorageFull and fences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const attempt = try TestingAttempt.admit(&storage, &tmp);
    var view: HistoricalView = undefined;
    storage.openHistoricalView(attempt.binding, &view);
    defer view.close();
    // The seal rewrites a few bytes of one Session row in place, which a
    // capped file still holds, so a trigger grows the file as it writes.
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TABLE ballast(b BLOB)");
    const page_count = try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0));
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TEMP TRIGGER seal_grows AFTER UPDATE OF prefix_seal ON main.session BEGIN INSERT INTO main.ballast VALUES(zeroblob(65536)); END");
    try std.testing.expectError(error.CanonicalStorageFull, view.recordPrefixSeal(&TestingAttempt.seal));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    try std.testing.expect(storage.isFenced());
}

test "a prefix seal reads its Attempt inside the transaction it writes in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const attempt = try TestingAttempt.admit(&storage, &tmp);
    var view: HistoricalView = undefined;
    storage.openHistoricalView(attempt.binding, &view);
    defer view.close();
    try storage.settleModelAttemptFailure(attempt.binding, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
    const database = storage.sqliteDatabase();
    const begins = runsOf(database, "BEGIN IMMEDIATE");
    const rollbacks = runsOf(database, "ROLLBACK");
    // The read that finds the Attempt settled runs after BEGIN, and the
    // seal's ROLLBACK ends the transaction it opened.
    try std.testing.expectError(error.StaleAttemptBinding, view.recordPrefixSeal(&TestingAttempt.seal));
    try std.testing.expectEqual(begins + 1, runsOf(database, "BEGIN IMMEDIATE"));
    try std.testing.expectEqual(rollbacks + 1, runsOf(database, "ROLLBACK"));
    try std.testing.expect(!storage.isFenced());
}
