const std = @import("std");
const protocol = @import("../../protocol.zig");
const shared = @import("../tests.zig");
const testing = @import("../testing.zig");
const Store = @import("../Store.zig").Store;
const HistoricalView = @import("../domain/historical.zig").HistoricalView;
const Mode = enum { omitted, foreground, background };

fn propose(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, mode: Mode) !u64 {
    var key_buffer: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "task-{s}", .{session});
    try testing.submitTestMessage(storage, tmp, "input", key, session, "Run the tool.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = switch (mode) {
        .omitted => "{\"description\":\"Held tool\",\"cmd\":\"true\"}",
        .foreground => "{\"description\":\"Held tool\",\"cmd\":\"true\",\"rui_execution\":\"foreground\"}",
        .background => "{\"description\":\"Held tool\",\"cmd\":\"true\",\"rui_execution\":\"background\"}",
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
    defer std.testing.allocator.free(encoded);
    try shared.settleCallsForTesting(storage, tmp, model, "calls", &.{.{
        .item_id = "call-item",
        .name = "bash",
        .encoded_call_id = "call-id",
        .decoded_call_id = "call-id",
        .encoded_arguments = encoded[1 .. encoded.len - 1],
        .decoded_arguments = arguments,
    }});
    return testing.queryU64(storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
}

fn finishModel(storage: *Store, tmp: *std.testing.TmpDir, binding: @import("../Store.zig").AttemptBinding) !void {
    try testing.settleItemsForTesting(storage, tmp, binding, &.{"{\"type\":\"message\",\"id\":\"answer-item\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
}

test "background acceptance releases the original call before final and outlives its Turn" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND background_position IS NOT NULL AND resolution_code IS NULL AND attempt_ordinal=0", .{action}));
            const receipt = try testing.queryU64(&storage, "SELECT background_content_id FROM action_operation WHERE action_id=?1", .{action});
            const continuation = (try storage.admitNextModelAttempt(.{})) orelse return error.BackgroundCallStillBlocks;
            try finishModel(&storage, &tmp, continuation.permit.binding);
            const selected = (try storage.nextAction(.bash)) orelse return error.CausalTurnKilledBackgroundAction;
            try std.testing.expectEqual(action, selected.action_id);
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            _ = try storage.settleActionAttempt(binding, .succeeded, "Final tool data: /not-a-skill", .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission input JOIN action_operation action ON action.action_id=input.final_action_id WHERE input.final_action_id=?1 AND input.session_ref=action.session_ref AND input.content_id=action.resolution_content_id AND input.command_key IS NULL AND input.sender_session_ref IS NULL AND input.admission_position>action.acceptance_position", .{action}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_skill skill JOIN message_admission input ON input.admission_id=skill.admission_id WHERE input.final_action_id=?1", .{action}));
            try std.testing.expectEqual(receipt, try testing.queryU64(&storage, "SELECT background_content_id FROM action_operation WHERE action_id=?1", .{action}));
            var activity: protocol.ActivityPage = .{ .session = session, .kinds = .initOne(.admission) };
            const queued = try @import("../Store.zig").activityPageForTesting(&storage, activity);
            var queued_finals: usize = 0;
            for (queued.items[0..queued.count]) |item| {
                const message = item.value.admission;
                switch (message.source) {
                    .tool_final => |id| {
                        try std.testing.expectEqual(action, id);
                        try std.testing.expect(message.state == .queued and message.turn == null);
                        queued_finals += 1;
                    },
                    .person => |key| try std.testing.expect(std.mem.startsWith(u8, key.slice(), "task-")),
                    .peer => return error.UnexpectedPeer,
                }
            }
            try std.testing.expectEqual(@as(usize, 1), queued_finals);
            const following = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expect(following.turn_id != binding.turn_id);
            activity.kinds = .initOne(.user);
            const applied = try @import("../Store.zig").activityPageForTesting(&storage, activity);
            var applied_finals: usize = 0;
            for (applied.items[0..applied.count]) |item| {
                const message = item.value.user;
                if (message.source == .tool_final) {
                    try std.testing.expectEqual(action, message.source.tool_final);
                    try std.testing.expect(message.state == .applied and message.turn == following.turn_id);
                    applied_finals += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 1), applied_finals);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(following, &view);
            defer view.close();
            var position: u64 = 0;
            var finals: usize = 0;
            var receipts: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.source) |source| switch (source) {
                    .tool_final => |id| {
                        try std.testing.expectEqual(action, id);
                        finals += 1;
                    },
                    else => {},
                };
                if (entry.kind == .tool_results) while (try view.nextToolResult()) |result| {
                    try std.testing.expectEqual(@as(i64, @intCast(receipt)), result.output.content_id);
                    receipts += 1;
                };
            }
            try std.testing.expectEqual(@as(usize, 1), finals);
            try std.testing.expectEqual(@as(usize, 1), receipts);
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .failed, "Replacement", .{}));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
        }
    }.run);
}

test "foreground original calls remain blocked until their sole Resolution" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]Mode{ .omitted, .foreground }) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
                const action = try propose(&storage, &tmp, session.slice(), mode);
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                const selected = (try storage.nextAction(.bash)).?;
                const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
                _ = try storage.settleActionAttempt(binding, .succeeded, "Foreground result", .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
                try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
            }
        }
    }.run);
}

test "source stop suppresses late background final after fresh user work with runner-owned cancellation" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            const selected = (try storage.nextAction(.bash)).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try finishModel(&storage, &tmp, continuation);
            var stop = try shared.completeSessionStop("stop-source", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, accepted.accepted.completion);
            try testing.submitTestMessage(&storage, &tmp, "fresh", "fresh-user-work", session.slice(), "Fresh work.");
            const fresh = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try finishModel(&storage, &tmp, fresh);
            _ = try storage.settleActionAttempt(binding, .succeeded, "Late completed evidence", .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='cancelled' AND resolution_content_id IS NOT NULL", .{action}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const replay = storage.stopSession(&stop, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
        }
    }.run);
}

test "background final and source input commit atomically" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            const selected = (try storage.nextAction(.bash)).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            try std.testing.expectError(error.InjectedCommitFailure, storage.settleActionAttempt(binding, .succeeded, "Atomic final", .{ .before_commit = true }));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{action}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
            try storage.close();
            storage_open = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            storage_open = true;
            _ = try storage.settleActionAttempt(binding, .succeeded, "Atomic final", .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
        }
    }.run);
}

fn capacity(total: usize, free: *const usize) @import("../domain/action_control.zig").CapacityView {
    return .{ .total = total, .context = free, .freeFn = struct {
        fn read(context: *const anyopaque) usize {
            return @as(*const usize, @ptrCast(@alignCast(context))).*;
        }
    }.read };
}

fn controlCommand(session: []const u8, key: []const u8, action: u64) !@import("../../command_input.zig").ActionControlCommand {
    var command: @import("../../command_input.zig").ActionControlCommand = .{ .action_id = action };
    try command.session.set(session);
    try command.key.set(key);
    return command;
}

test "promotion refusal preserves the original attempted call and exact replay precedes current capacity" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .foreground);
            const selected = (try storage.nextAction(.bash)).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            var free: usize = 0;
            var command = try controlCommand(session.slice(), "refused-promotion", action);
            const refused = try storage.controlAction(.{ .owner = .background }, &command, capacity(2, &free), .{});
            try std.testing.expect(refused == .rejected and refused.rejected.code == .background_unavailable);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND attempt_timeout_ms=30000 AND background_position IS NULL AND resolution_code IS NULL", .{action}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            free = 1;
            const refusal_replay = try storage.controlAction(.{ .owner = .background }, &command, capacity(2, &free), .{});
            try std.testing.expect(refusal_replay == .rejected and refusal_replay.rejected.replayed);
            try command.key.set("promote-existing-attempt");
            const accepted = try storage.controlAction(.{ .owner = .background }, &command, capacity(2, &free), .{});
            try std.testing.expect(accepted == .accepted and accepted.accepted.selection.kind == .background);
            const receipt_position = accepted.accepted.selection.position;
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND attempt_timeout_ms=30000 AND background_position=?2 AND resolution_code IS NULL", .{ action, receipt_position }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
            _ = try storage.settleActionAttempt(binding, .succeeded, "One invocation's final", .{});
            free = 0;
            const replay = try storage.controlAction(.{ .owner = .background }, &command, capacity(1, &free), .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(receipt_position, replay.accepted.selection.position);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND resolution_code='succeeded'", .{action}));
        }
    }.run);
}

fn proposeStop(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, target: u64) !@import("../domain/action.zig").CoreActionInput {
    var configure: @import("../../wire_request.zig").ConfigureCommand = .{};
    try configure.key.set("enable-action-tools");
    try configure.session.set(session);
    configure.configuration.tools = try .of(&.{ "bash", "read_action", "stop_action" });
    try std.testing.expect(try storage.configure(&configure, .{}) == .accepted);
    try testing.submitTestMessage(storage, tmp, "stop-input", "stop-task", session, "Stop the earlier Action.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var bytes: [64]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&bytes, "{{\"action\":\"{d}\"}}", .{target});
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
    defer std.testing.allocator.free(encoded);
    try shared.settleCallsForTesting(storage, tmp, model, "stop-calls", &.{.{ .item_id = "stop-item", .name = "stop_action", .encoded_call_id = "stop-call", .decoded_call_id = "stop-call", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments }});
    const next = (try storage.nextCoreWorkForHost(false)).?;
    try std.testing.expect(next == .action and next.action.tool == .stop_action);
    return next.action;
}

test "stale core stop source cannot select its target after arguments were read" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const target = try propose(&storage, &tmp, session.slice(), .background);
            try finishModel(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding);
            const source = try proposeStop(&storage, &tmp, session.slice(), target);
            var arguments: [4096]u8 = undefined;
            try std.testing.expect((try storage.readCoreToolArguments(&source, &arguments)) != null);
            const free: usize = 1;
            var cancel = try controlCommand(session.slice(), "cancel-source-only", source.binding.action_id);
            try std.testing.expect((try storage.controlAction(.{ .owner = .stop }, &cancel, capacity(2, &free), .{})) == .accepted);
            var stale = try controlCommand(session.slice(), "rui.core/action-stop/stale-source", target);
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.controlAction(.{ .core_stop = source.binding }, &stale, capacity(2, &free), .{}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM action_control_command WHERE selected_action_id=?1 AND selection='stop'", .{target}));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL AND attempt_ordinal=0", .{target}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key='rui.core/action-stop/stale-source'", .{}));
        }
    }.run);
}

test "core stop target selection and originating Resolution commit together" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const target = try propose(&storage, &tmp, session.slice(), .background);
            try finishModel(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding);
            const source = try proposeStop(&storage, &tmp, session.slice(), target);
            const free: usize = 1;
            var command = try controlCommand(session.slice(), "rui.core/action-stop/atomic-source", target);
            const failed = try storage.controlAction(.{ .core_stop = source.binding }, &command, capacity(2, &free), .{ .before_commit = true });
            try std.testing.expect(failed == .infrastructure_failure);
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM action_control_command WHERE selected_action_id=?1", .{target}));
            try std.testing.expectEqual(@as(u64, 2), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id IN (?1,?2) AND resolution_code IS NULL", .{ target, source.binding.action_id }));
            try storage.close();
            storage_open = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            storage_open = true;
            const accepted = try storage.controlAction(.{ .core_stop = source.binding }, &command, capacity(2, &free), .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(@as(u64, 2), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id IN (?1,?2) AND resolution_code IS NOT NULL", .{ target, source.binding.action_id }));
            const replay = try storage.controlAction(.{ .core_stop = source.binding }, &command, capacity(2, &free), .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(accepted.accepted.selection.position, replay.accepted.selection.position);
        }
    }.run);
}

test "background MCP definite late success survives stop but never becomes a new input" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var digests: [shared.membership_records.len][32]u8 = undefined;
            const host_tools = shared.membershipToolSet(&digests);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
            defer storage.close() catch unreachable;
            var workspace: [protocol.max_workspace_bytes]u8 = undefined;
            var configure = try testing.completeConfiguration("configure", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
            configure.configuration.tools = try .of(&.{"fetch_page"});
            configure.configuration.permission_mode.state = .value;
            try configure.configuration.permission_mode.value.set("bypass");
            const session = (try storage.configure(&configure, .{})).accepted.session;
            try testing.submitTestMessage(&storage, &tmp, "input", "original", session.slice(), "Fetch once.");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try shared.settleCallsForTesting(&storage, &tmp, model, "calls", &.{.{
                .item_id = "call-item",
                .name = "fetch_page",
                .encoded_call_id = "fetch-id",
                .decoded_call_id = "fetch-id",
                .encoded_arguments = "{\\\"rui_execution\\\":\\\"background\\\"}",
                .decoded_arguments = "{\"rui_execution\":\"background\"}",
            }});
            const selected = (try storage.nextAction(.mcp)).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try finishModel(&storage, &tmp, continuation);
            var stop: protocol.SessionStopCommand = .{ .session = session };
            try stop.key.set("stop-source");
            const stopped = storage.stopSession(&stop, .{});
            try std.testing.expect(stopped == .accepted and stopped.accepted.completion == .pending);
            try testing.submitTestMessage(&storage, &tmp, "fresh", "fresh", session.slice(), "Independent work.");
            const fresh = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try finishModel(&storage, &tmp, fresh);
            try std.testing.expectEqual(@import("../domain/action.zig").ActionSettlement.session_stop, try storage.settleActionAttempt(binding, .succeeded, "Definite MCP adapter result.", .{}));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='succeeded' AND resolution_content_id IS NOT NULL", .{binding.action_id}));
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{binding.action_id}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            var result: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = binding.action_id }, &result);
            try std.testing.expect(result.stop_selected and result.final != null);
            try std.testing.expectEqualStrings("succeeded", result.final.?.resolution.code.slice());
            try std.testing.expectEqualStrings("Definite MCP adapter result.", result.final.?.window.text.slice());
            const replay = storage.stopSession(&stop, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.completion == .completed);
        }
    }.run);
}

test "Action read is own Session scoped and pages immutable final UTF8 without consuming it" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            const status = @import("../../action_read.zig");
            var result: status.Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &result);
            try std.testing.expect(result.state == .queued and result.final == null and result.background_position != null);
            try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = 1 }, &result));
            const other = try shared.configureTestSessionWithMode(&storage, "other", "bypass");
            try std.testing.expectError(error.ActionNotFound, storage.readAction(&.{ .session = other, .action_id = action }, &result));
            const selected = (try storage.nextAction(.bash)).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            const repeats = status.window_bytes / 3 + 3;
            const bytes = "a" ++ @as([3 * repeats]u8, @bitCast(@as([repeats][3]u8, @splat("雪".*))));
            _ = try storage.settleActionAttempt(binding, .succeeded, bytes, .{});
            try storage.readAction(&.{ .session = session, .action_id = action }, &result);
            const first = result.final.?;
            try std.testing.expect(first.window.more);
            try std.testing.expect(first.window.next <= status.window_bytes);
            try std.testing.expect(std.unicode.utf8ValidateSlice(first.window.text.slice()));
            try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = 2 }, &result));
            try storage.readAction(&.{ .session = session, .action_id = action, .offset = first.window.next }, &result);
            const second = result.final.?;
            try std.testing.expect(!second.window.more);
            try std.testing.expectEqualSlices(u8, bytes[first.window.next..], second.window.text.slice());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(bytes), &second.resolution.content.digest);
            try storage.readAction(&.{ .session = session, .action_id = action }, &result);
            try std.testing.expectEqualDeep(first, result.final.?);
        }
    }.run);
}

test "background final waits for complete sibling coverage and the frozen busy-model boundary" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            try testing.submitTestMessage(&storage, &tmp, "input", "task", session.slice(), "Run siblings.");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const bg = "{\"description\":\"Background sibling\",\"cmd\":\"true\",\"rui_execution\":\"background\"}";
            const fg = "{\"description\":\"Foreground sibling\",\"cmd\":\"true\"}";
            const encoded_bg = try std.json.Stringify.valueAlloc(std.testing.allocator, bg, .{});
            defer std.testing.allocator.free(encoded_bg);
            const encoded_fg = try std.json.Stringify.valueAlloc(std.testing.allocator, fg, .{});
            defer std.testing.allocator.free(encoded_fg);
            try shared.settleCallsForTesting(&storage, &tmp, model, "siblings", &.{
                .{ .item_id = "bg-item", .name = "bash", .encoded_call_id = "bg-call", .decoded_call_id = "bg-call", .encoded_arguments = encoded_bg[1 .. encoded_bg.len - 1], .decoded_arguments = bg },
                .{ .item_id = "fg-item", .name = "bash", .encoded_call_id = "fg-call", .decoded_call_id = "fg-call", .encoded_arguments = encoded_fg[1 .. encoded_fg.len - 1], .decoded_arguments = fg },
            });
            const first = (try storage.admitNextActionAttempt(30_000, .{})).?.permit.binding;
            const second = (try storage.admitNextActionAttempt(30_000, .{})).?.permit.binding;
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            _ = try storage.settleActionAttempt(first, .succeeded, "Background sibling final", .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1 AND turn_id IS NULL", .{first.action_id}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            _ = try storage.settleActionAttempt(second, .succeeded, "Foreground sibling final", .{});
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(continuation, &view);
            defer view.close();
            var position: u64 = 0;
            var calls: usize = 0;
            var finals: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.source) |source| if (source == .tool_final) {
                    try std.testing.expectEqual(first.action_id, source.tool_final);
                    finals += 1;
                };
                if (entry.kind == .tool_results) while (try view.nextToolResult()) |result| {
                    try std.testing.expectEqual(protocol.contentDigest(if (calls == 0) "bg-call" else "fg-call"), result.call_id.digest);
                    calls += 1;
                };
            }
            try std.testing.expectEqual(@as(usize, 2), calls);
            try std.testing.expectEqual(@as(usize, 1), finals);
            try finishModel(&storage, &tmp, continuation);
        }
    }.run);
}

test "a busy model request cannot acquire a later background final before its frozen successor" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            const tool = (try storage.admitNextActionAttempt(30_000, .{})).?.permit.binding;
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            _ = try storage.settleActionAttempt(tool, .succeeded, "Late during busy request", .{});
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            {
                var frozen: HistoricalView = undefined;
                storage.openHistoricalView(continuation, &frozen);
                defer frozen.close();
                var position: u64 = 0;
                while (try frozen.nextEntry(position)) |entry| {
                    position = entry.position;
                    if (entry.source) |source| try std.testing.expect(source != .tool_final);
                    if (entry.kind == .tool_results) while (try frozen.nextToolResult()) |_| {};
                }
            }
            try finishModel(&storage, &tmp, continuation);
            const following = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(following, &view);
            defer view.close();
            var position: u64 = 0;
            var finals: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.source) |source| if (source == .tool_final) {
                    try std.testing.expectEqual(action, source.tool_final);
                    finals += 1;
                };
                if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
            }
            try std.testing.expectEqual(@as(usize, 1), finals);
        }
    }.run);
}

test "Session stop reaches old background Actions through attached descendants but not standalone Sessions" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try shared.configureTestSessionWithMode(&storage, "root", "bypass");
            const standalone = try shared.configureTestSessionWithMode(&storage, "standalone", "bypass");
            var sessions: [4]@TypeOf(root) = .{ root, undefined, undefined, standalone };
            for (1..3) |depth| {
                var request: @import("../../wire_request.zig").ConfigureCommand = .{};
                var key: [32]u8 = undefined;
                try request.key.set(try std.fmt.bufPrint(&key, "attached-{d}", .{depth}));
                request.configuration = try shared.testingAgentSpec(&.{"bash"}, "bypass");
                request.configuration.parent.state = .value;
                try request.configuration.parent.value.set(sessions[depth - 1].slice());
                sessions[depth] = (try storage.configure(&request, .{})).accepted.session;
            }
            var bindings: [4]@import("../domain/action.zig").ActionAttemptBinding = undefined;
            for (sessions, 0..) |session, index| {
                _ = try propose(&storage, &tmp, session.slice(), .background);
                bindings[index] = (try storage.admitNextActionAttempt(30_000, .{})).?.permit.binding;
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try finishModel(&storage, &tmp, continuation);
            }
            var stop = try shared.completeSessionStop("stop-root", root.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[0])) != null);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[3])) == null);
            for (1..3) |depth| {
                const work = (try storage.nextCoreWorkForHost(false)) orelse return error.MissingOwedDescendantStop;
                try std.testing.expect(work == .stop);
                try std.testing.expectEqualStrings(sessions[depth].slice(), work.stop.session.slice());
                var owed: protocol.SessionStopCommand = .{ .key = work.stop.key, .session = sessions[depth] };
                try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
                try std.testing.expect((try storage.actionSupersededByStop(bindings[depth])) != null);
                try std.testing.expect((try storage.actionSupersededByStop(bindings[3])) == null);
            }
            for (bindings, 0..) |binding, index| {
                _ = try storage.settleActionAttempt(binding, .succeeded, "Final evidence", .{});
                try std.testing.expectEqual(@as(u64, if (index == 3) 1 else 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{binding.action_id}));
                try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ binding.action_id, if (index == 3) @as([]const u8, "succeeded") else "cancelled" }));
            }
        }
    }.run);
}

test "stopping an approval-waiting invocation never grants an Attempt or replaces background fulfillment" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]Mode{ .foreground, .background }) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared.configureTestSessionAsk(&storage, "configure");
                const action = try propose(&storage, &tmp, session.slice(), mode);
                var status: @import("../../action_read.zig").Read = undefined;
                try storage.readAction(&.{ .session = session, .action_id = action }, &status);
                try std.testing.expectEqual(@import("../../action_read.zig").State.waiting_approval, status.state);
                const receipt = status.background_position;
                var free: usize = 0;
                var command = try controlCommand(session.slice(), "stop-waiting", action);
                const stopped = try storage.controlAction(.{ .owner = .stop }, &command, capacity(1, &free), .{});
                try std.testing.expect(stopped == .accepted and stopped.accepted.selection.kind == .stop);
                try std.testing.expect((try storage.admitNextActionAttempt(30_000, .{})) == null);
                try storage.readAction(&.{ .session = session, .action_id = action }, &status);
                try std.testing.expectEqual(@import("../../action_read.zig").State.resolved, status.state);
                try std.testing.expect(status.stop_selected);
                try std.testing.expectEqual(receipt, status.background_position);
                try std.testing.expectEqualStrings("cancelled", status.final.?.resolution.code.slice());
                try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=0 AND authorized=0", .{action}));
                try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
                var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
                try allow.key.set("too-late-allow");
                const refused = storage.decidePermission(&allow, .{});
                try std.testing.expect(refused == .rejected and refused.rejected.code == .action_not_pending);
                const replay = try storage.controlAction(.{ .owner = .stop }, &command, capacity(1, &free), .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(stopped.accepted.selection, replay.accepted.selection);
                try command.key.set("background-after-stop");
                const after = try storage.controlAction(.{ .owner = .background }, &command, capacity(1, &free), .{});
                try std.testing.expect(after == .accepted);
                try std.testing.expectEqual(if (mode == .background) receipt.? else status.final.?.resolution.position, after.accepted.selection.position);
            }
        }
    }.run);
}

test "Host recovery retains background fulfillment and records uncertainty without another Attempt" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try propose(&storage, &tmp, session.slice(), .background);
            const binding = (try storage.admitNextActionAttempt(30_000, .{})).?.permit.binding;
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try finishModel(&storage, &tmp, continuation);
            var status: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &status);
            const receipt = status.background_position.?;
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            const active = @import("../domain/action.zig").ActiveOperationFilter.empty();
            try std.testing.expect(try storage.recoverOneUncertainAction(active));
            try std.testing.expect(!try storage.recoverOneUncertainAction(active));
            try std.testing.expect((try storage.admitNextActionAttempt(30_000, .{})) == null);
            try storage.readAction(&.{ .session = session, .action_id = action }, &status);
            try std.testing.expectEqual(receipt, status.background_position.?);
            try std.testing.expectEqualStrings("indeterminate", status.final.?.resolution.code.slice());
            try std.testing.expect(std.mem.indexOf(u8, status.final.?.window.text.slice(), "not replayed") != null);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND background_position=?2", .{ action, receipt }));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE final_action_id=?1", .{action}));
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .succeeded, "Cannot replace recovery evidence", .{}));
        }
    }.run);
}
