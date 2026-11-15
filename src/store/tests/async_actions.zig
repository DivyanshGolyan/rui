const std = @import("std");
const protocol = @import("../../protocol.zig");
const shared = @import("../tests.zig");
const testing = @import("../testing.zig");
const Store = @import("../Store.zig").Store;
const HistoricalView = @import("../domain/historical.zig").HistoricalView;
const Mode = enum { foreground, promoted };

fn propose(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, mode: Mode) !u64 {
    return proposeNamed(storage, tmp, session, mode, "bash");
}

fn proposeNamed(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, mode: Mode, name: []const u8) !u64 {
    var key_buffer: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "task-{s}", .{session});
    try testing.submitTestMessage(storage, tmp, "input", key, session, "Run the tool.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = "{\"description\":\"Held tool\",\"cmd\":\"true\"}";
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
    defer std.testing.allocator.free(encoded);
    try shared.settleCallsForTesting(storage, tmp, model, "calls", &.{.{
        .item_id = "call-item",
        .name = name,
        .encoded_call_id = "call-id",
        .decoded_call_id = "call-id",
        .encoded_arguments = encoded[1 .. encoded.len - 1],
        .decoded_arguments = arguments,
    }});
    const action = try testing.queryU64(storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
    if (mode == .promoted) try promote(storage, session, action);
    return action;
}

fn promote(storage: *Store, session: []const u8, action: u64) !void {
    var key: [64]u8 = undefined;
    var command = try controlCommand(session, try std.fmt.bufPrint(&key, "native-promote/{d}", .{action}), action);
    const free: usize = 2;
    const result = try storage.controlAction(.background, &command, capacity(2, &free), .{});
    try std.testing.expect(result == .accepted and result.accepted.selection.kind == .background);
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND background_position IS NOT NULL AND resolution_code IS NULL AND attempt_ordinal=0", .{action}));
            const receipt = try testing.queryU64(&storage, "SELECT background_content_id FROM action_operation WHERE action_id=?1", .{action});
            const continuation = (try storage.admitNextModelAttempt(.{})) orelse return error.BackgroundCallStillBlocks;
            try finishModel(&storage, &tmp, continuation.permit.binding);
            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })) orelse return error.CausalTurnKilledBackgroundAction;
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
            for ([_]Mode{.foreground}) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared.configureTestSessionWithMode(&storage, "configure", "bypass");
                const action = try propose(&storage, &tmp, session.slice(), mode);
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
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
            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            var free: usize = 0;
            var command = try controlCommand(session.slice(), "refused-promotion", action);
            const refused = try storage.controlAction(.background, &command, capacity(2, &free), .{});
            try std.testing.expect(refused == .rejected and refused.rejected.code == .background_unavailable);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND attempt_timeout_ms=30000 AND background_position IS NULL AND resolution_code IS NULL", .{action}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            free = 1;
            const refusal_replay = try storage.controlAction(.background, &command, capacity(2, &free), .{});
            try std.testing.expect(refusal_replay == .rejected and refusal_replay.rejected.replayed);
            try command.key.set("promote-existing-attempt");
            const accepted = try storage.controlAction(.background, &command, capacity(2, &free), .{});
            try std.testing.expect(accepted == .accepted and accepted.accepted.selection.kind == .background);
            const receipt_position = accepted.accepted.selection.position;
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND attempt_timeout_ms=30000 AND background_position=?2 AND resolution_code IS NULL", .{ action, receipt_position }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
            _ = try storage.settleActionAttempt(binding, .succeeded, "One invocation's final", .{});
            free = 0;
            const replay = try storage.controlAction(.background, &command, capacity(1, &free), .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(receipt_position, replay.accepted.selection.position);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND resolution_code='succeeded'", .{action}));
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
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const action = try testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
            try promote(&storage, session.slice(), action);
            const selected = (try storage.nextAction(.mcp, .{ .credit = .background, .mcp = true })).?;
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            const status = @import("../../action_read.zig");
            var result: status.Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &result);
            try std.testing.expect(result.state == .queued and result.final == null and result.background_position != null);
            try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = 1 }, &result));
            const other = try shared.configureTestSessionWithMode(&storage, "other", "bypass");
            try std.testing.expectError(error.ActionNotFound, storage.readAction(&.{ .session = other, .action_id = action }, &result));
            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
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
            const bg = "{\"description\":\"Background sibling\",\"cmd\":\"true\"}";
            const fg = "{\"description\":\"Foreground sibling\",\"cmd\":\"true\"}";
            const encoded_bg = try std.json.Stringify.valueAlloc(std.testing.allocator, bg, .{});
            defer std.testing.allocator.free(encoded_bg);
            const encoded_fg = try std.json.Stringify.valueAlloc(std.testing.allocator, fg, .{});
            defer std.testing.allocator.free(encoded_fg);
            try shared.settleCallsForTesting(&storage, &tmp, model, "siblings", &.{
                .{ .item_id = "bg-item", .name = "bash", .encoded_call_id = "bg-call", .decoded_call_id = "bg-call", .encoded_arguments = encoded_bg[1 .. encoded_bg.len - 1], .decoded_arguments = bg },
                .{ .item_id = "fg-item", .name = "bash", .encoded_call_id = "fg-call", .decoded_call_id = "fg-call", .encoded_arguments = encoded_fg[1 .. encoded_fg.len - 1], .decoded_arguments = fg },
            });
            const background = try testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1 AND call_ordinal=0", .{model.operation_id});
            try promote(&storage, session.slice(), background);
            const first = (try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})).?.permit.binding;
            const second = (try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})).?.permit.binding;
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            const tool = (try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})).?.permit.binding;
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
                _ = try propose(&storage, &tmp, session.slice(), .promoted);
                bindings[index] = (try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})).?.permit.binding;
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try finishModel(&storage, &tmp, continuation);
            }
            var stop = try shared.completeSessionStop("stop-root", root.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[0])) != null);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[3])) == null);
            for (1..3) |depth| {
                const work = (try storage.nextCoreWork(.{ .credit = .background, .mcp = false })) orelse return error.MissingOwedDescendantStop;
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
            for ([_]Mode{ .foreground, .promoted }) |mode| {
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
                const stopped = try storage.controlAction(.stop, &command, capacity(1, &free), .{});
                try std.testing.expect(stopped == .accepted and stopped.accepted.selection.kind == .stop);
                try std.testing.expect((try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})) == null);
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
                const replay = try storage.controlAction(.stop, &command, capacity(1, &free), .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(stopped.accepted.selection, replay.accepted.selection);
                try command.key.set("background-after-stop");
                const after = try storage.controlAction(.background, &command, capacity(1, &free), .{});
                try std.testing.expect(after == .accepted);
                try std.testing.expectEqual(if (mode == .promoted) receipt.? else status.final.?.resolution.position, after.accepted.selection.position);
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
            const action = try propose(&storage, &tmp, session.slice(), .promoted);
            const binding = (try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})).?.permit.binding;
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
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .credit = .background, .mcp = true }, 30_000, .{})) == null);
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

fn expectPermission(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, action: u64, present: bool) !void {
    const bytes = try shared.testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer decoded.deinit();
    const report = decoded.value.object;
    const pending = report.get("actions").?.object.get("unresolved").?.array.items;
    const permissions = report.get("actionable_permissions").?.array.items;
    try std.testing.expectEqual(@as(usize, if (present) 1 else 0), pending.len);
    try std.testing.expectEqual(@as(usize, if (present) 1 else 0), permissions.len);
    if (present) {
        try std.testing.expectEqual(action, try std.fmt.parseInt(u64, pending[0].object.get("action").?.string, 10));
        try std.testing.expectEqual(action, try std.fmt.parseInt(u64, permissions[0].object.get("action").?.string, 10));
    }
    const expected: ?u64 = if (present) action else null;
    const first = report.get("work").?.object.get("first_action").?;
    try std.testing.expectEqual(expected, if (first == .null) null else @as(?u64, try std.fmt.parseInt(u64, first.string, 10)));
    var request: protocol.ActivityPage = .{};
    try request.session.set(session);
    const page = try @import("../Store.zig").activityPageForTesting(storage, request);
    try std.testing.expectEqual(expected, page.work.work.first_action);
}

test "background permissions remain Session owned after continuation and terminal Turn" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]Mode{ .promoted, .foreground }) |mode| {
                for ([_]enum { allow, deny, stop }{ .allow, .deny, .stop }) |choice| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try shared.configureTestSessionWithMode(&storage, "configure", "ask");
                    const action = try propose(&storage, &tmp, session.slice(), mode);
                    if (mode == .foreground) {
                        const free: usize = 2;
                        var promotion = try controlCommand(session.slice(), "promote-awaiting", action);
                        try std.testing.expect((try storage.controlAction(.background, &promotion, capacity(2, &free), .{})) == .accepted);
                    }
                    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try expectPermission(&storage, &tmp, session.slice(), action, true);
                    try finishModel(&storage, &tmp, continuation);
                    try expectPermission(&storage, &tmp, session.slice(), action, true);
                    if (choice == .stop) {
                        var stop = try shared.completeSessionStop("stop-pending", session.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                        try expectPermission(&storage, &tmp, session.slice(), action, false);
                    } else {
                        var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = if (choice == .allow) .allow_once else .deny };
                        try decision.key.set("decide-old-turn");
                        try std.testing.expect(storage.decidePermission(&decision, .{}) == .accepted);
                        if (choice == .allow) {
                            const selected = (try storage.nextAction(.bash, .{ .credit = .background, .mcp = true })).?;
                            try std.testing.expectEqual(action, selected.action_id);
                            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
                            _ = try storage.settleActionAttempt(binding, .succeeded, "Approved after Turn ended", .{});
                        }
                        try expectPermission(&storage, &tmp, session.slice(), action, false);
                    }
                }
            }
        }
    }.run);
}

fn capacitySession(storage: *Store, key: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try testing.completeConfiguration(key, "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
    command.configuration.tools = try .of(&.{ "bash", "fetch_page", "find_tools" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    return (try storage.configure(&command, .{})).accepted.session;
}

test "Action selection filters custody eligibility before ordering across Bash MCP and core" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            inline for (.{ .bash, .mcp }) |runner| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var digests: [shared.membership_records.len][32]u8 = undefined;
                const host_tools = shared.membershipToolSet(&digests);
                var storage: Store = undefined;
                try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
                defer storage.close() catch unreachable;
                const background_session = try capacitySession(&storage, "background-session");
                const background = try proposeNamed(&storage, &tmp, background_session.slice(), .promoted, if (runner == .bash) "bash" else "fetch_page");
                try finishModel(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding);
                const foreground_session = try capacitySession(&storage, "foreground-session");
                const foreground = try proposeNamed(&storage, &tmp, foreground_session.slice(), .foreground, if (runner == .bash) "bash" else "fetch_page");
                const core_session = try capacitySession(&storage, "core-session");
                const core = try proposeNamed(&storage, &tmp, core_session.slice(), .foreground, "find_tools");
                for ([_]usize{ 1, 2, 0 }) |free| {
                    const available: @import("../../tool_execution.zig").Capacity = .fromFree(free, true);
                    const selected = try storage.nextAction(runner, available);
                    if (free == 0) try std.testing.expect(selected == null) else try std.testing.expectEqual(if (free == 1) foreground else background, selected.?.action_id);
                    const work = (try storage.nextCoreWork(available)).?;
                    if (runner == .mcp and free != 0) {
                        try std.testing.expectEqual(if (free == 1) foreground else background, work.mcp.action_id);
                    } else try std.testing.expectEqual(core, work.action.binding.action_id);
                    const hint = try storage.dispatchWork(false, available);
                    try std.testing.expect(hint.core);
                    try std.testing.expectEqual(runner == .bash and free != 0, hint.bash);
                    try std.testing.expectEqual(runner == .mcp and free != 0, hint.mcp);
                }
                const no_mcp: @import("../../tool_execution.zig").Capacity = .fromFree(2, false);
                try std.testing.expectEqual(core, (try storage.nextCoreWork(no_mcp)).?.action.binding.action_id);
                const core_input = (try storage.nextCoreWork(.fromFree(0, true))).?.action;
                try std.testing.expect(try storage.succeedCoreCall(core_input.binding, "Read", .{}));
                const blocked = try storage.dispatchWork(false, .fromFree(0, true));
                try std.testing.expect(!blocked.core and !blocked.bash and !blocked.mcp);
                const resumed = try storage.dispatchWork(false, .fromFree(2, true));
                try std.testing.expectEqual(runner == .bash, resumed.bash);
                try std.testing.expectEqual(runner == .mcp, resumed.mcp);
                try std.testing.expectEqual(@as(u64, 2), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id IN (?1,?2) AND attempt_ordinal=0 AND resolution_code IS NULL AND authorized=1", .{ background, foreground }));
            }
        }
    }.run);
}
