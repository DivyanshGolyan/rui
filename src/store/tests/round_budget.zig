const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const tool_set_domain = @import("../domain/tool_set.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const reads_domain = @import("../domain/reads.zig");
const store_testing = @import("../testing.zig");
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalSettings = historical_domain.HistoricalSettings;
const TestingPage = store_testing.TestingPage;
const ModelOperationKind = historical_domain.ModelOperationKind;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const skills_fixture_domain = @import("../domain/skills.zig");
const EntryPoint = shared_fixtures.EntryPoint;
const RoundMeter = shared_fixtures.RoundMeter;
const TestingCall = shared_fixtures.TestingCall;
const ViewRounds = shared_fixtures.ViewRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectContent = shared_fixtures.expectContent;
const nextTestingItem = shared_fixtures.nextTestingItem;
const round_budgets = shared_fixtures.round_budgets;
const pass_budgets = shared_fixtures.pass_budgets;
const keepsPassBudget = shared_fixtures.keepsPassBudget;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionList = shared_fixtures.testingSessionList;
const testingSessionReport = shared_fixtures.testingSessionReport;

const entering_fixtures = [_][]const u8{ "prefixSealForTesting", "readSessionForTesting", "readToolDigestsForTesting" };
// Budgets measured inside another entry point's round: an Archived window or a changed page is a readSessionList request, so it
// enters the Store through readSessionList and has no Store function of its own.
const dispatched_points = [_]EntryPoint{ .readArchivedWindow, .readChangedSessionList };

test "every function that enters the Store has a round budget" {
    const sources = .{
        @embedFile("../Store.zig"),
        @embedFile("../access.zig"),
        @embedFile("../archive_tests.zig"),
        @embedFile("../pin_tests.zig"),
        @embedFile("../creator_tests.zig"),
        @embedFile("../engine.zig"),
        @embedFile("../engine/Sqlite.zig"),
        @embedFile("../engine/Mysql.zig"),
        @embedFile("../engine/mysql_commit.zig"),
        @embedFile("../engine/mysql_content.zig"),
        @embedFile("../engine/mysql_open.zig"),
        @embedFile("../engine/mysql_refusal.zig"),
        @embedFile("../domain/action.zig"),
        @embedFile("../domain/action_control.zig"),
        @embedFile("../domain/action_stop.zig"),
        @embedFile("../domain/action_read.zig"),
        @embedFile("../domain/action_value.zig"),
        @embedFile("../domain/archive_membership.zig"),
        @embedFile("../domain/forward.zig"),
        @embedFile("../domain/command.zig"),
        @embedFile("../domain/configuration.zig"),
        @embedFile("../domain/content.zig"),
        @embedFile("../domain/content_parts.zig"),
        @embedFile("../domain/public_parts.zig"),
        @embedFile("../domain/find_tools.zig"),
        @embedFile("../domain/historical.zig"),
        @embedFile("../domain/history_floor.zig"),
        @embedFile("../domain/model_admission.zig"),
        @embedFile("../domain/model_facts.zig"),
        @embedFile("../domain/model_attempt.zig"),
        @embedFile("../domain/model_settlement.zig"),
        @embedFile("../domain/operation_effort.zig"),
        @embedFile("../domain/replay_wire.zig"),
        @embedFile("../domain/reads.zig"),
        @embedFile("../domain/report.zig"),
        @embedFile("../domain/session_list_read.zig"),
        @embedFile("../domain/session_obligation.zig"),
        @embedFile("../domain/session_report_read.zig"),
        @embedFile("../domain/skills.zig"),
        @embedFile("../domain/sourced_input.zig"),
        @embedFile("../domain/tool_fulfillment.zig"),
        @embedFile("../domain/tool_offer.zig"),
        @embedFile("../domain/tool_set.zig"),
        @embedFile("../domain/turn.zig"),
        @embedFile("../mysql_literal.zig"),
        @embedFile("../mysql_row.zig"),
        @embedFile("../rsql.zig"),
        @embedFile("../rsql_table.zig"),
        @embedFile("../schema.zig"),
        @embedFile("../sqlite.zig"),
        @embedFile("../testing.zig"),
        @embedFile("../column_rules.zig"),
        @embedFile("../command_replay.zig"),
        @embedFile("../page_slots.zig"),
        @embedFile("../pass_plan.zig"),
        @embedFile("../queue.zig"),
        @embedFile("../round_order.zig"),
        @embedFile("../write_batch.zig"),
        @embedFile("../transition.zig"),
    };
    var found: std.EnumSet(EntryPoint) = .empty;
    var fixtures: [entering_fixtures.len]bool = @splat(false);
    const runner = sources[sources.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, runner, "pub fn apply" ++ "(self: *Store") != null);
    inline for (sources) |source| inline for (.{ "enter", "transition.apply" }) |callee| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, callee ++ "(")) |index| : (at = index + 1) {
            if (index > 0 and (std.ascii.isAlphanumeric(source[index - 1]) or source[index - 1] == '_')) continue;
            if (std.mem.endsWith(u8, source[0..index], "fn ")) continue;
            if (!std.mem.startsWith(u8, source[index..], callee ++ "(self, ")) {
                std.debug.print("an {s} call takes another first argument: {s}\n", .{ callee, source[index..][0..@min(40, source.len - index)] });
                return error.EnterWithoutSelf;
            }
            const before = source[0..index];
            const fn_at = @max(std.mem.lastIndexOf(u8, before, " fn ") orelse 0, std.mem.lastIndexOf(u8, before, "\nfn ") orelse 0) + " fn ".len;
            var end = fn_at;
            while (std.ascii.isAlphanumeric(source[end]) or source[end] == '_') end += 1;
            if (source.ptr == runner.ptr and std.mem.eql(u8, source[fn_at..end], "apply")) continue;
            const held = std.mem.endsWith(u8, source[fn_at..end], "Held");
            const name = if (held) source[fn_at .. end - "Held".len] else source[fn_at..end];
            if (!held and !std.mem.endsWith(u8, name, "ForTesting")) {
                std.debug.print("{s} enters the Store outside the queue; give it a body named {s}Held\n", .{ name, name });
                return error.EnterOutsideQueue;
            }
            if (std.mem.endsWith(u8, name, "ForTesting")) {
                const listed = for (entering_fixtures, 0..) |fixture, position| {
                    if (std.mem.eql(u8, fixture, name)) break position;
                } else {
                    std.debug.print("{s} enters the Store but is not in entering_fixtures\n", .{name});
                    return error.UnlistedFixture;
                };
                try std.testing.expect(!fixtures[listed]);
                fixtures[listed] = true;
                continue;
            }
            const point = std.meta.stringToEnum(EntryPoint, name) orelse {
                std.debug.print("{s} enters the Store but has no round budget\n", .{name});
                return error.EntryPointWithoutBudget;
            };
            try std.testing.expect(!found.contains(point));
            found.insert(point);
        }
    };
    for (dispatched_points) |point| {
        try std.testing.expect(!found.contains(point));
        found.insert(point);
    }
    try std.testing.expectEqual(std.enums.values(EntryPoint).len, found.count());
    for (fixtures) |seen| try std.testing.expect(seen);
}

test "MySQL round shape subtracts the entry baseline from every component" {
    const Shape = RoundMeter.QueryShape;
    const before: Shape = .{ .queries = 100, .access_passes = 10, .identity_passes = 4, .content_queries = 7, .controls = 12, .prefix_only = 3 };
    const after: Shape = .{ .queries = 109, .access_passes = 12, .identity_passes = 5, .content_queries = 10, .controls = 14, .prefix_only = 4 };
    const delta = after.since(before);
    try std.testing.expectEqual(@as(u64, 2), delta.access_passes);
    try std.testing.expectEqual(@as(u64, 1), delta.identity_passes);
    try std.testing.expectEqual(@as(u64, 3), delta.content_queries);
    try std.testing.expectEqual(@as(u64, 2), delta.controls);
    try std.testing.expectEqual(@as(u64, 1), delta.prefix_only);
    try std.testing.expectEqual(@as(u64, 9), delta.queries);
    try std.testing.expectEqual(delta.expected(), delta.queries);
}

// SH-110's pass check, over its whole domain: a pinned point keeps its budget at exactly its passes, one more or one fewer
// fails it, and an unpinned point is not checked.
test "SH-110 a pass budget holds only at its exact passes, and pins every Session list entry point" {
    for ([_]EntryPoint{ .readSessionList, .readArchivedWindow, .readChangedSessionList }) |point| {
        const budget = pass_budgets.get(point) orelse return error.ListPointUnpinned;
        try std.testing.expect(keepsPassBudget(point, .{ .access_passes = budget }));
        try std.testing.expect(!keepsPassBudget(point, .{ .access_passes = budget + 1 }));
        try std.testing.expect(!keepsPassBudget(point, .{ .access_passes = budget - 1 }));
    }
    try std.testing.expect(pass_budgets.get(.configure) == null);
    try std.testing.expect(keepsPassBudget(.configure, .{ .access_passes = 99 }));
}

test "creating configuration with a receipt keeps the configure round budget" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const create = try completeConfiguration("budget-create-receipt", "", workspace, "model-a");
            var receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            var meter: RoundMeter = .{ .storage = &storage };
            meter.start();
            const reply = try storage.configureInto(&create, &receipt, .{});
            try meter.stop(.configure);
            try std.testing.expect(reply == .accepted and reply.accepted.configuration != null);
            const measured = meter.measured.get(.configure).?;
            try std.testing.expectEqual(round_budgets.get(.configure), measured.rounds);
            if (case.engine == .mysql) try std.testing.expectEqual(measured.shape.expected(), measured.shape.queries);
        }
    }.run);
}

test "creating Message with a receipt keeps the no-output creation rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("budget-message-settings", "", workspace, "model-a");
            var message: wire_request.MessageCommand = .{ .configuration = settings.configuration };
            message.text = try shared_fixtures.testingBytesContent(&tmp, "budget-message-input", "initial");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try message.key.set("budget-message-warmup");
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
            var meter: RoundMeter = .{ .storage = &storage };
            try message.key.set("budget-message-no-receipt");
            meter.start();
            const without = storage.submitMessageWithModel(&message, null, .{});
            try meter.stop(.submitMessageWithModel);
            try std.testing.expect(without == .accepted and without.accepted.configuration == null);
            const baseline = meter.measured.get(.submitMessageWithModel).?;
            var receipt: @import("../../creation_receipt.zig").Configuration = undefined;
            try message.key.set("budget-message-with-receipt");
            var receipt_meter: RoundMeter = .{ .storage = &storage };
            receipt_meter.start();
            const with = storage.submitMessageWithModelInto(&message, null, &receipt, .{});
            try receipt_meter.stop(.submitMessageWithModel);
            try std.testing.expect(with == .accepted and with.accepted.configuration != null);
            const measured = receipt_meter.measured.get(.submitMessageWithModel).?;
            try std.testing.expectEqual(baseline.rounds, measured.rounds);
            try std.testing.expectEqual(baseline.content_rounds, measured.content_rounds);
            if (case.engine == .mysql) try std.testing.expectEqual(measured.shape.expected(), measured.shape.queries);
        }
    }.run);
}
