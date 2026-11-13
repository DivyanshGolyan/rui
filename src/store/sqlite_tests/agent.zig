//! Agent SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeSessionStop = tests.completeSessionStop;
const expectContent = tests.expectContent;
const settleCallsForTesting = tests.settleCallsForTesting;
const testingContentReference = tests.testingContentReference;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;
const expectOnlyForwardsThenIdle = shared_fixtures.expectOnlyForwardsThenIdle;

/// A Session that offers only `message_agent`, under an `ask` revision, so
/// a core call that needed a person would wait.
fn configureMessagingSession(storage: *Store, key: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try store_testing.completeConfiguration(key, "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{"message_agent"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

test "a message_agent call runs as one core command: the Message is admitted from its Session and the call resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "agent-caller");
    const receiver = try configureTestSession(&storage, "agent-receiver");
    try submitTestMessage(&storage, &tmp, "agent-task", "agent-task", caller.slice(), "ask the receiver");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"report back\"}}", .{receiver.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"report back\\\"}}", .{receiver.slice()});
    const calls = [_]TestingCall{
        .{ .item_id = "agent-item", .name = "message_agent", .encoded_call_id = "agent-call", .decoded_call_id = "agent-call", .encoded_arguments = encoded, .decoded_arguments = arguments },
        .{ .item_id = "agent-missing-item", .name = "message_agent", .encoded_call_id = "agent-missing", .decoded_call_id = "agent-missing", .encoded_arguments = "{\\\"id\\\":\\\"zzzzzz\\\",\\\"text\\\":\\\"hi\\\"}", .decoded_arguments = "{\"id\":\"zzzzzz\",\"text\":\"hi\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "agent-metadata", &calls);

    // Both calls are decided at once under `ask`, described by the core,
    // and never reach the Bash runner.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND approval_position IS NULL", .{}));
    var line_buffer: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "Message {s}", .{receiver.slice()});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE description=?1", .{line}));
    try std.testing.expect(try storage.admitNextActionAttempt(300_000, .{}) == null);

    const first = (try storage.nextCoreWork()).?.action;
    try std.testing.expectEqualStrings(caller.slice(), first.session.slice());
    // The Host bound a skill of the receiver's; it is saved after the Message.
    const bound: @import("../domain/skills.zig").MessageCapture = .{ .bound = &.{.{ .name = "demo", .bytes = "demo body" }} };
    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessageBound(first.binding, receiver.slice(), "report back", &bound, .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_skill k JOIN message_admission m ON m.admission_id=k.admission_id WHERE m.session_ref=?1 AND k.position=1 AND k.name='demo'", .{receiver.slice()}));
    const second = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(second.binding.action_id != first.binding.action_id);
    try std.testing.expectEqual(command_domain.AgentDelivery.failed, try storage.deliverAgentMessage(second.binding, "zzzzzz", "hi", .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);
    // A resolved call is not run again.
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.deliverAgentMessage(first.binding, receiver.slice(), "report back", .{}));

    // The receiver holds one Message from the caller, waiting for a Turn.
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2 AND turn_id IS NULL", .{ receiver.slice(), caller.slice() }));
    const text_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{receiver.slice()});
    try expectContent(&storage, try testingContentReference(&storage, text_id), "report back");
    // Each call resolved with what happened, and the caller's Turn can continue.
    var delivered_buffer: [32]u8 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ "succeeded", try std.fmt.bufPrint(&delivered_buffer, "Delivered to {s}.", .{receiver.slice()}) },
        .{ "failed", "No Session zzzzzz in this Store; nothing was sent." },
    }) |case| {
        const result_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE resolution_code=?1", .{case[0]});
        try expectContent(&storage, try testingContentReference(&storage, result_id), case[1]);
    }
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code IS NULL AND continuation_operation_id=operation_id", .{caller.slice()}));
    try expectDenseSessionPositions(&storage, caller.slice());
    try expectDenseSessionPositions(&storage, receiver.slice());
}

test "a message_agent call of the longest escaped text is read back past one content window and delivered whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "long-caller");
    const receiver = try configureTestSession(&storage, "long-receiver");
    try submitTestMessage(&storage, &tmp, "long-task", "long-task", caller.slice(), "send it all");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const gpa = std.testing.allocator;
    // Every byte of the text is a quote, so the arguments hold twice the
    // text and are read in more than one window.
    const text = try gpa.alloc(u8, tool_defs.core_tools.message_agent_max_text_bytes);
    defer gpa.free(text);
    @memset(text, '"');
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try decoded.print(gpa, "{{\"id\":\"{s}\",\"text\":\"", .{receiver.slice()});
    try encoded.print(gpa, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"", .{receiver.slice()});
    for (text) |_| {
        try decoded.appendSlice(gpa, "\\\"");
        try encoded.appendSlice(gpa, "\\\\\\\"");
    }
    try decoded.appendSlice(gpa, "\"}");
    try encoded.appendSlice(gpa, "\\\"}");
    try std.testing.expect(decoded.items.len > content_domain.ContentReader.content_window_bytes);
    const calls = [_]TestingCall{.{ .item_id = "long-item", .name = "message_agent", .encoded_call_id = "long-call", .decoded_call_id = "long-call", .encoded_arguments = encoded.items, .decoded_arguments = decoded.items }};
    try settleCallsForTesting(&storage, &tmp, model, "long-metadata", &calls);

    const input = (try storage.nextCoreWork()).?.action;
    const bytes = try gpa.alloc(u8, @intCast(input.arguments.length));
    defer gpa.free(bytes);
    try storage.readCoreArguments(&input, bytes);
    try std.testing.expectEqualStrings(decoded.items, bytes);
    var source: tool_defs.core_tools.SliceSource = .{ .bytes = bytes };
    const Text = struct {
        list: std.ArrayList(u8) = .empty,

        pub fn writeAll(self: *@This(), part: []const u8) !void {
            try self.list.appendSlice(std.testing.allocator, part);
        }
    };
    var read_text: Text = .{};
    defer read_text.list.deinit(gpa);
    const check = try tool_defs.core_tools.checkMessageAgent(&source, &read_text);
    try std.testing.expect(check == .accepted);
    try std.testing.expectEqualStrings(text, read_text.list.items);
    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(input.binding, check.accepted.id.slice(), read_text.list.items, .{}));
    const text_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{receiver.slice()});
    var reader: content_domain.ContentReader = undefined;
    reader.open(try storage.openContent(try testingContentReference(&storage, text_id)));
    defer reader.close();
    const delivered = try gpa.alloc(u8, text.len + 1);
    defer gpa.free(delivered);
    var count: usize = 0;
    while (true) {
        const read = try reader.read(count, delivered[count..@min(delivered.len, count + content_domain.ContentReader.content_window_bytes)]);
        if (read == 0) break;
        count += read;
    }
    try std.testing.expectEqualStrings(text, delivered[0..count]);
}

test "a stop or a context full ending stops every attached child below it, each as its own stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // parent -> child -> grandchild are attached; standalone has no parent.
    const parent = try configureTestSession(&storage, "tree-parent");
    const child = try configureTestSession(&storage, "tree-child");
    const grandchild = try configureTestSession(&storage, "tree-grandchild");
    const standalone = try configureTestSession(&storage, "tree-standalone");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
    try submitTestMessage(&storage, &tmp, "tree-child-task", "tree-child-task", child.slice(), "work");
    try std.testing.expect(try storage.nextCoreWork() == null);

    var stop = try completeSessionStop("tree-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    // The child owes a stop keyed by its cause; nothing else does yet.
    const owed = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(child.slice(), owed.session.slice());
    const stop_position = try store_testing.sqlite_only.queryU64(&storage, "SELECT position FROM session_stop WHERE command_key='tree-stop'", .{});
    var key_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buffer, "rui.core/stop/{s}/{s}/{d}", .{ child.slice(), parent.slice(), stop_position }), owed.key.slice());
    // A replayed parent stop owes nothing again.
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE settled=0", .{}));

    // The child's stop is an ordinary stop: it excludes the child's queued
    // task, settles what it owed and passes the stop down.
    var child_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
    try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
    const next = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(grandchild.slice(), next.session.slice());
    var grandchild_stop = try completeSessionStop(next.key.slice(), next.session.slice());
    try std.testing.expect(storage.stopOwedSession(&grandchild_stop, .{}) == .accepted);
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{standalone.slice()}));
    try std.testing.expect(try storage.admitNextModelAttempt(.{}) == null);
    try expectDenseSessionPositions(&storage, child.slice());
    try expectDenseSessionPositions(&storage, grandchild.slice());

    // A Turn that ends out of context stops the children too.
    try submitTestMessage(&storage, &tmp, "tree-parent-task", "tree-parent-task", parent.slice(), "too long");
    const attempt = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(attempt, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
    // The overflow compacts first; the compaction overflowing too, with
    // nothing to drop, ends the Turn out of context.
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(compaction, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='ResourceExceeded'", .{parent.slice()}));
    const full = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(child.slice(), full.session.slice());
    const close_position = try store_testing.sqlite_only.queryU64(&storage, "SELECT outcome_position FROM turn WHERE session_ref=?1", .{parent.slice()});
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buffer, "rui.core/stop/{s}/{s}/{d}", .{ child.slice(), parent.slice(), close_position }), full.key.slice());
    try expectDenseSessionPositions(&storage, parent.slice());
}

test "child endings deliver once with their answer and sender; standalone endings owe nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const parent = try configureTestSession(&storage, "ending-parent");
    const child = try configureTestSession(&storage, "ending-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "ending-task", "ending-task", child.slice(), "answer");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const item = "{\"type\":\"message\",\"id\":\"ending-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}";
    try settleItemsForTesting(&storage, &tmp, model, &.{item}, "hello");
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expectEqual(.done, ending.ending);
    try std.testing.expect(!ending.quiet);
    try expectContent(&storage, ending.answer.?, "hello");
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expect(!try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2", .{ parent.slice(), child.slice() }));
    // The Message is the saved answer itself, not a copy.
    try std.testing.expectEqual(
        try store_testing.sqlite_only.queryU64(&storage, "SELECT outcome_content_id FROM turn WHERE turn_id=?1", .{ending.turn_id}),
        try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{parent.slice()}),
    );
    try expectOnlyForwardsThenIdle(&storage);
    // A standalone Turn has no parent to notify.
    const solo = try configureTestSession(&storage, "ending-solo");
    try submitTestMessage(&storage, &tmp, "solo-task", "solo-task", solo.slice(), "answer");
    while (try storage.admitNextModelAttempt(.{})) |attempt| {
        try settleItemsForTesting(&storage, &tmp, attempt.permit.binding, &.{item}, "hello");
    }
    try expectOnlyForwardsThenIdle(&storage);
}

test "a child settles two parent stop obligations in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const parent = try configureTestSession(&storage, "repeat-stop-parent");
    const child = try configureTestSession(&storage, "repeat-stop-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });

    for ([_][]const u8{ "repeat-stop-first", "repeat-stop-second" }, 0..) |key, index| {
        if (index != 0) {
            try submitTestMessage(&storage, &tmp, "repeat-stop-message", "repeat-stop-message", parent.slice(), "work again");
        }
        var stop = try completeSessionStop(key, parent.slice());
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        // Replaying the cause must not add another open obligation.
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=0", .{child.slice()}));
        try std.testing.expectEqual(@as(u64, index), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=1", .{child.slice()}));

        const owed = (try storage.nextCoreWork()).?.stop;
        try std.testing.expectEqualStrings(child.slice(), owed.session.slice());
        var owed_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
        try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=0", .{child.slice()}));
        try std.testing.expectEqual(@as(u64, index + 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=1", .{child.slice()}));
        try std.testing.expect(try storage.nextCoreWork() == null);
    }
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1", .{child.slice()}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
    try std.testing.expect(!storage.isFenced());
}

test "a client stopped child delivers a nonquiet stopped ending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const parent = try configureTestSession(&storage, "client-ending-parent");
    const child = try configureTestSession(&storage, "client-ending-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "client-ending-task", "client-ending-task", child.slice(), "work");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var stop = try completeSessionStop("client-ending-stop", child.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expectEqual(.stopped, ending.ending);
    try std.testing.expect(!ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2", .{ parent.slice(), child.slice() }));
}

test "a child's core call selected before its parent stopped runs only after the stop it owes, which cancels it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const parent = try configureTestSession(&storage, "priority-parent");
    const child = try configureMessagingSession(&storage, "priority-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "priority-task", "priority-task", child.slice(), "message your parent");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"late\"}}", .{parent.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"late\\\"}}", .{parent.slice()});
    const calls = [_]TestingCall{.{ .item_id = "priority-item", .name = "message_agent", .encoded_call_id = "priority-call", .decoded_call_id = "priority-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "priority-metadata", &calls);
    const selected = (try storage.nextCoreWork()).?.action;

    var stop = try completeSessionStop("priority-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(command_domain.AgentDelivery.stopped, try storage.deliverAgentMessage(selected.binding, parent.slice(), "late", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
    const owed = (try storage.nextCoreWork()).?.stop;
    var owed_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
    try expectOnlyForwardsThenIdle(&storage);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
}

test "a child's start_agent call selected before its parent stopped is left to the stop it owes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    const parent = try configureTestSession(&storage, "start-priority-parent");
    var create = try store_testing.completeConfiguration("start-priority-child", "", workspace, "model-a");
    create.configuration.tools = try .of(&.{"start_agent"});
    const child = (try storage.configure(&create, .{})).accepted.session;
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "start-priority-task", "start-priority-task", child.slice(), "start a grandchild");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"model-a\",\"effort\":null,\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\"}}";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), arguments, .{});
    const calls = [_]TestingCall{.{ .item_id = "start-priority-item", .name = "start_agent", .encoded_call_id = "start-priority-call", .decoded_call_id = "start-priority-call", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "start-priority-metadata", &calls);
    const selected = (try storage.nextCoreWork()).?.action;

    var stop = try completeSessionStop("start-priority-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    const core_tools = @import("../../core_tools.zig");
    const start = try arena.allocator().create(core_tools.StartAgent);
    try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
    try std.testing.expectEqual(command_domain.AgentStart.stopped, try storage.startAgent(selected.binding, child.slice(), start.task, start.attached, &start.configuration, null, .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NOT NULL", .{selected.binding.action_id}));
}

test "an owed stop a client's stop already settled, or a newer one replaced, runs nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const parent = try configureTestSession(&storage, "stale-parent");
    const child = try configureTestSession(&storage, "stale-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    var stop = try completeSessionStop("stale-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    const selected = (try storage.nextCoreWork()).?.stop;

    // A client stops the child under its own key, then sends it a Message.
    var client = try completeSessionStop("stale-client-stop", child.slice());
    try std.testing.expect(storage.stopSession(&client, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stale-after", "stale-after", child.slice(), "after the stop");
    var stale = try completeSessionStop(selected.key.slice(), selected.session.slice());
    try std.testing.expect(storage.stopOwedSession(&stale, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
    try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);

    // A newer obligation is not consumed by the stale key, only by its own.
    var again = try completeSessionStop("stale-stop-again", parent.slice());
    try std.testing.expect(storage.stopSession(&again, .{}) == .accepted);
    const newer = (try storage.nextCoreWork()).?.stop;
    try std.testing.expect(!std.mem.eql(u8, newer.key.slice(), selected.key.slice()));
    try std.testing.expect(storage.stopOwedSession(&stale, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE settled=0", .{}));
    var owed = try completeSessionStop(newer.key.slice(), newer.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try expectOnlyForwardsThenIdle(&storage);
    try std.testing.expect(!storage.isFenced());
}

test "a stop that selects a message_agent call's Turn cancels it before it runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "stopped-caller");
    try submitTestMessage(&storage, &tmp, "stopped-task", "stopped-task", caller.slice(), "message yourself");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"later\"}}", .{caller.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"later\\\"}}", .{caller.slice()});
    const calls = [_]TestingCall{.{ .item_id = "stopped-item", .name = "message_agent", .encoded_call_id = "stopped-call", .decoded_call_id = "stopped-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "stopped-metadata", &calls);
    const pending = (try storage.nextCoreWork()).?.action;
    var stop = try completeSessionStop("stopped-stop", caller.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.deliverAgentMessage(pending.binding, caller.slice(), "later", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{caller.slice()}));
}

test "a start_agent call creates its agent where its caller works, with the task from the caller, and may only narrow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try store_testing.completeConfiguration("starting-caller", "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{ "message_agent", "start_agent" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const caller = (try storage.configure(&command, .{})).accepted.session;
    try submitTestMessage(&storage, &tmp, "start-task", "start-task", caller.slice(), "split the work");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "attached-item", .name = "start_agent", .encoded_call_id = "attached", .decoded_call_id = "attached", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "standalone-item", .name = "start_agent", .encoded_call_id = "standalone", .decoded_call_id = "standalone", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "wider-item", .name = "start_agent", .encoded_call_id = "wider", .decoded_call_id = "wider", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "bypass-item", .name = "start_agent", .encoded_call_id = "bypass", .decoded_call_id = "bypass", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "start-metadata", &calls);
    // Decided at once under `ask`, and never a Bash Attempt.
    try std.testing.expectEqual(@as(u64, 4), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND approval_position IS NULL", .{}));
    try std.testing.expect(try storage.admitNextActionAttempt(300_000, .{}) == null);

    const attached = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(attached.tool == .start_agent);
    var spec = try tests.testingAgentSpec(&.{"message_agent"}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.started, try storage.startAgent(attached.binding, caller.slice(), "read the tests", true, &spec, null, .{}));
    const standalone = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.started, try storage.startAgent(standalone.binding, caller.slice(), "read the docs", false, &spec, null, .{}));
    const wider = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{"bash"}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.failed, try storage.startAgent(wider.binding, caller.slice(), "run things", true, &spec, null, .{}));
    const bypass = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{"message_agent"}, "bypass");
    try std.testing.expectEqual(command_domain.AgentStart.failed, try storage.startAgent(bypass.binding, caller.slice(), "run freely", true, &spec, null, .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);

    // Two agents, both in the caller's Workspace with its provider (D122,
    // D221); only the attached one is its child.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref<>?1 AND workspace=?2 AND provider=(SELECT provider FROM session WHERE session_ref=?1)", .{ caller.slice(), workspace }));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{caller.slice()}));
    // Public list and both report profiles expose only the attached agent's
    // parent; the standalone agent and its caller have none.
    {
        var used = std.atomic.Value(u64).init(0);
        const bytes = try tests.testingSessionList(&storage, &tmp, .{}, &used, 77);
        defer std.testing.allocator.free(bytes);
        const listed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer listed.deinit();
        const rows = listed.value.object.get("sessions").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), rows.len);
        var children: usize = 0;
        for (rows) |row| {
            const reference = row.object.get("reference").?.string;
            const first = row.object.get("first_message").?;
            const attached_child = !std.mem.eql(u8, reference, caller.slice()) and
                std.mem.eql(u8, first.object.get("content").?.object.get("bytes").?.string, "14");
            const parent = row.object.get("parent").?;
            if (attached_child) {
                try std.testing.expect(parent == .string);
                try std.testing.expectEqualStrings(caller.slice(), parent.string);
                children += 1;
            } else try std.testing.expect(parent == .null);
            for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
                const report = try testingSessionReportWithProfile(&storage, &tmp, reference, 1024 * 1024, profile);
                defer std.testing.allocator.free(report);
                const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
                defer parsed.deinit();
                const reported_parent = parsed.value.object.get("session").?.object.get("parent").?;
                if (attached_child) {
                    try std.testing.expect(reported_parent == .string);
                    try std.testing.expectEqualStrings(caller.slice(), reported_parent.string);
                } else try std.testing.expect(reported_parent == .null);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), children);
    }
    // Each task is its agent's first Message, from the caller, under the
    // call's own command key.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE sender_session_ref=?1 AND admission_position=1 AND command_key LIKE 'rui.core/start_agent/%'", .{caller.slice()}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN session s ON s.session_ref=m.session_ref JOIN content c ON c.content_id=m.content_id WHERE s.parent_ref=?1 AND c.byte_length=14", .{caller.slice()}));
    // The refusals name the field and start nothing.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='failed'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'Started %'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'spec.tools: bash is not one of your tools.%'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'spec.permissionMode:%'", .{}));
}
