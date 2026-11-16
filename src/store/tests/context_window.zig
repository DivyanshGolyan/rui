//! Context window Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const HistoricalView = historical_domain.HistoricalView;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingHistoryCursor = shared_fixtures.TestingHistoryCursor;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;
const expectActivityOutcome = shared_fixtures.expectActivityOutcome;
const openCheckedView = shared_fixtures.openCheckedView;
const renderTestingEntry = shared_fixtures.renderTestingEntry;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;

/// One model's selected facts; the caller controls chronology, not a live provider.
fn saveFrozenContextWindow(storage: *Store, model: []const u8, window: ?u32) !void {
    try storage.saveModelFacts(&.{.{ .id = model, .context_window = window, .efforts = .{}, .openai_listed = true }}, null);
}

fn expectFrozenContextWindow(storage: *Store, binding: AttemptBinding, expected: u64) !void {
    try std.testing.expectEqual(expected, try store_testing.queryU64(storage, "SELECT context_window FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
}

test "frozen context window selects the whole saved-or-shipped domain and survives retry reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Variant = enum { shipped, unknown, saved, only, missing, empty, null_window, zero, maximum };
            inline for (std.enums.values(Variant)) |variant| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const model = if (variant == .unknown or variant == .only) "d238-only" else "gpt-6.1-sol";
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const create = try completeConfiguration("window-config", "", try canonicalCwd(std.testing.io, &workspace_buffer), model);
                const session = (try storage.configure(&create, .{})).accepted.session;
                const expected: u64 = switch (variant) {
                    .shipped, .unknown => model_capability.contextWindow(@import("../../model_catalog.zig").shipped, model),
                    .saved, .only => 321,
                    .missing, .empty, .null_window => product_defaults.unlisted_context_window,
                    .zero => 0,
                    .maximum => std.math.maxInt(u32),
                };
                switch (variant) {
                    .shipped, .unknown => {},
                    .missing => try saveFrozenContextWindow(&storage, "unrelated", 321),
                    .empty => try storage.saveModelFacts(&.{}, null),
                    .null_window => try saveFrozenContextWindow(&storage, model, null),
                    else => try saveFrozenContextWindow(&storage, model, @intCast(expected)),
                }
                try submitTestMessage(&storage, &tmp, "window-one", "window-one", session.slice(), "first");
                const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                try expectFrozenContextWindow(&storage, first, expected);
                try saveFrozenContextWindow(&storage, model, 500);
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
                try std.testing.expectEqual(first.operation_id, retry.operation_id);
                try expectFrozenContextWindow(&storage, retry, expected);
                try settleMessagesForTesting(&storage, &tmp, retry, 1, false, null);
                try submitTestMessage(&storage, &tmp, "window-next", "window-next", session.slice(), "next");
                const next = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                try expectFrozenContextWindow(&storage, next, 500);
            }
        }
    }.run);
}

test "frozen context window rides every model admission kind without another round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "window-kinds");
            try saveFrozenContextWindow(&storage, "model-a", 1000);
            try submitTestMessage(&storage, &tmp, "window-first", "window-first", session.slice(), "first");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try expectFrozenContextWindow(&storage, first, 1000);
            try submitTestMessage(&storage, &tmp, "window-second", "window-second", session.slice(), "second");
            try settleMessagesForTesting(&storage, &tmp, first, 1, false, null);
            try saveFrozenContextWindow(&storage, "model-a", 2000);
            const joined = (try storage.admitModelAttempt(.open_turn_message, .{})).?.permit.binding;
            try expectFrozenContextWindow(&storage, joined, 2000);
            try settleCallsForTesting(&storage, &tmp, joined, "window-call", &.{.{
                .item_id = "unknown-item",
                .name = "unknown_tool",
                .encoded_call_id = "unknown-call",
                .decoded_call_id = "unknown-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            try saveFrozenContextWindow(&storage, "model-b", 3000);
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("window-model-switch");
            patch.session = session;
            patch.configuration.model.state = .value;
            try patch.configuration.model.value.set("model-b");
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            const continuation = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try expectFrozenContextWindow(&storage, continuation, 3000);
            try expectFrozenContextWindow(&storage, first, 1000);
            try expectFrozenContextWindow(&storage, joined, 2000);
        }
    }.run);
}

/// A compact history with independently chosen byte sizes: at window=100 the
/// three targets (400,100,25) retain first+[120,30,10], first+[30,10], first+[10].
fn frozenWindowHistory(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !void {
    try submitTestMessage(storage, tmp, "window-first", "window-first", session, "first");
    inline for (.{ .{ "window-big", 600, 'b' }, .{ "window-middle", 120, 'm' }, .{ "window-small", 30, 's' }, .{ "window-last", 10, 'n' } }) |item| {
        const text: [item[1]]u8 = @splat(item[2]);
        try submitTestMessage(storage, tmp, item[0], item[0], session, &text);
    }
}

fn expectFrozenFloor(storage: *Store, binding: AttemptBinding, level: u64, oldest: []const u8, dropped: u64) !void {
    const position = try store_testing.queryU64(storage, "SELECT entry.session_position FROM conversation_entry entry JOIN message_admission msg ON msg.admission_id=entry.source_admission_id WHERE msg.command_key=?1 AND entry.entry_kind=1", .{oldest});
    try std.testing.expectEqual(position - 1, try store_testing.queryU64(storage, "SELECT history_floor FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
    try std.testing.expectEqual(level, try store_testing.queryU64(storage, "SELECT history_level FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
    try std.testing.expectEqual(dropped, try store_testing.queryU64(storage, "SELECT history_dropped FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
    var view: HistoricalView = undefined;
    try openCheckedView(storage, binding, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    const first = (try cursor.next(&view)).?;
    var bytes: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("first", try renderTestingEntry(&view, first, &bytes));
    const sizes = [_]usize{ 120, 30, 10 };
    const letters = [_]u8{ 'm', 's', 'n' };
    const start: usize = if (std.mem.eql(u8, oldest, "window-middle")) 0 else if (std.mem.eql(u8, oldest, "window-small")) 1 else 2;
    for (sizes[start..], letters[start..]) |size, letter| {
        const entry = (try cursor.next(&view)).?;
        const text = try renderTestingEntry(&view, entry, &bytes);
        try std.testing.expectEqual(size, text.len);
        for (text) |byte| try std.testing.expectEqual(letter, byte);
    }
    try std.testing.expect((try cursor.next(&view)) == null);
}

test "frozen context window refresh before settlement and successor admission cannot change escalation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Both directions, plus a frozen exhausted walk that a live read
            // would incorrectly turn into another compaction.
            for ([_]u32{ 100, 1000, 100000 }) |original| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "window-refresh");
                try frozenWindowHistory(&storage, &tmp, session.slice());
                const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(assistant, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                try saveFrozenContextWindow(&storage, "model-a", original);
                const full = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try expectFrozenContextWindow(&storage, full, original);
                try saveFrozenContextWindow(&storage, "model-a", if (original == 100) 100000 else 100);
                try storage.settleModelAttemptFailure(full, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                try saveFrozenContextWindow(&storage, "model-a", if (original == 100) 200000 else 200);
                // Restart with a settled overflow and a different catalog.
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const next = try storage.admitNextModelAttempt(.{});
                try std.testing.expectEqual(original != 100000, next != null);
                if (original == 100000) {
                    try expectActivityOutcome(&storage, session.slice(), full, .context_full, "ResourceExceeded");
                } else {
                    const deeper = next.?.permit.binding;
                    try expectFrozenFloor(&storage, deeper, if (original == 100) 1 else 3, "window-middle", 1);
                    try expectFrozenContextWindow(&storage, deeper, if (original == 100) 200000 else 200);
                    try expectFrozenContextWindow(&storage, full, original);
                }
            }
        }
    }.run);
}

test "frozen context window covers all levels reservation exhaustion and inherited floors" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]u64{ 0, 100, 200 }) |reservation| {
                for ([_]bool{ false, true }) |accept_base| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    var create = try completeConfiguration("window-levels", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                    create.configuration.output_reservation.state = .value;
                    var count: [20]u8 = undefined;
                    try create.configuration.output_reservation.value.set(try std.fmt.bufPrint(&count, "{d}", .{reservation}));
                    const session = (try storage.configure(&create, .{})).accepted.session;
                    try frozenWindowHistory(&storage, &tmp, session.slice());
                    var previous = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try storage.settleModelAttemptFailure(previous, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                    try saveFrozenContextWindow(&storage, "model-a", 100);
                    previous = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    const count_levels: usize = if (reservation == 0) 3 else 1;
                    for (0..count_levels) |index| {
                        try storage.settleModelAttemptFailure(previous, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                        const deeper = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        const oldest = if (reservation != 0 or index == 2) "window-last" else if (index == 1) "window-small" else "window-middle";
                        try expectFrozenFloor(&storage, deeper, index + 1, oldest, if (reservation != 0) 3 else 1);
                        previous = deeper;
                    }
                    if (!accept_base) {
                        try storage.settleModelAttemptFailure(previous, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                        try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                        try expectActivityOutcome(&storage, session.slice(), previous, .context_full, "ResourceExceeded");
                        continue;
                    }
                    // A successful base transfers its floor to the assistant's recipe.
                    try settleCompactionForTesting(&storage, &tmp, previous, &.{.compaction});
                    const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try expectFrozenContextWindow(&storage, successor, 100);
                    {
                        var view: HistoricalView = undefined;
                        try openCheckedView(&storage, successor, &view);
                        defer view.close();
                        const coverage = try view.coverage();
                        try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT history_floor FROM model_operation WHERE operation_id=?1", .{previous.operation_id}), coverage.floor.position);
                        try std.testing.expect(!coverage.floor.own);
                    }
                    try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "context_overflow" }, .context_overflow, .{});
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                    // A new model must not inherit the old model's base or floor.
                    try saveFrozenContextWindow(&storage, "model-b", 700);
                    var patch: wire_request.ConfigureCommand = .{};
                    try patch.key.set("window-base-switch");
                    patch.session = session;
                    patch.configuration.model.state = .value;
                    try patch.configuration.model.value.set("model-b");
                    patch.configuration.compaction_trigger.state = .value;
                    try patch.configuration.compaction_trigger.value.set("700");
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                    try submitTestMessage(&storage, &tmp, "window-new-model", "window-new-model", session.slice(), "new");
                    const switched = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try expectFrozenContextWindow(&storage, switched, 700);
                    var view: HistoricalView = undefined;
                    try openCheckedView(&storage, switched, &view);
                    defer view.close();
                    const coverage = try view.coverage();
                    try std.testing.expectEqual(@as(u64, 0), coverage.floor.position);
                    try std.testing.expect(coverage.anchor == null);
                }
            }
        }
    }.run);
}
