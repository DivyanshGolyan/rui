const std = @import("std");
const protocol = @import("../protocol.zig");
const wire_request = @import("../wire_request.zig");
const store_core = @import("Store.zig");
const Store = store_core.Store;
const testing = @import("testing.zig");
const fixtures = @import("tests.zig");
const action = @import("domain/action.zig");
const content_value = @import("../content_value.zig");

fn archiveCommand(key: []const u8, session: []const u8, archived: bool) !protocol.SessionArchiveCommand {
    var command: protocol.SessionArchiveCommand = .{ .archived = archived };
    try command.key.set(key);
    try command.session.set(session);
    return command;
}

fn expectState(storage: *Store, session: []const u8, expected: protocol.SessionArchiveState) !void {
    const observation = try storage.inspectSessionForTesting(session);
    try std.testing.expect(observation.found);
    try std.testing.expectEqual(expected, observation.archive_state);
}

const Bash = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    binding: action.ActionAttemptBinding,
};

fn runningBash(storage: *Store, tmp: *std.testing.TmpDir, key: []const u8) !Bash {
    const session = try fixtures.configureTestSessionWithMode(storage, key, "bypass");
    var message_key_buffer: [protocol.max_key_bytes]u8 = undefined;
    const message_key = try std.fmt.bufPrint(&message_key_buffer, "{s}-message", .{key});
    try testing.submitTestMessage(storage, tmp, message_key, message_key, session.slice(), "run Bash");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]fixtures.TestingCall{.{
        .item_id = "bash-item",
        .name = "bash",
        .encoded_call_id = "bash-call",
        .decoded_call_id = "bash-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};
    try fixtures.settleCallsForTesting(storage, tmp, model, key, &calls);
    return .{ .session = session, .binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding };
}

fn message(tmp: *std.testing.TmpDir, key: []const u8, session: []const u8) !wire_request.MessageCommand {
    const file = try tmp.dir.createFile(std.testing.io, key, .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "hello");
    return testing.completeMessage(key, session, file, "hello");
}

test "Session archive idle replay restore and message admission preserve organization" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "archive-idle-config");
            const before = try storage.inspectSessionForTesting(session.slice());
            var archive = try archiveCommand("archive-idle", session.slice(), true);
            const accepted = storage.archiveSession(&archive, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(!accepted.accepted.replayed and accepted.accepted.archived);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try expectState(&storage, session.slice(), .archived);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const after = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(before.revision, after.revision);
            try std.testing.expectEqualSlices(u8, before.instructions.digest[0..], after.instructions.digest[0..]);
            const archived_end = (try store_core.activityPageForTesting(&storage, .{ .session = session })).end;
            var restore = try archiveCommand("restore-idle", session.slice(), false);
            try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
            try std.testing.expect((try store_core.activityPageForTesting(&storage, .{ .session = session })).end > archived_end);
            try expectState(&storage, session.slice(), .active);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const replay = storage.archiveSession(&archive, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try expectState(&storage, session.slice(), .active);
            archive.archived = false;
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .conflict);
            archive = try archiveCommand("archive-again", session.slice(), true);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            var incoming = try message(&tmp, "archive-wake", session.slice());
            defer incoming.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{}) == .accepted);
            try expectState(&storage, session.slice(), .active);
            try std.testing.expect(storage.archiveSession(&archive, .{}).accepted.replayed);
            try expectState(&storage, session.slice(), .active);
            var newest = try archiveCommand("archive-after-message", session.slice(), true);
            try std.testing.expect(storage.archiveSession(&newest, .{}) == .accepted);
            try expectState(&storage, session.slice(), .archived);
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{}).accepted.replayed);
            try expectState(&storage, session.slice(), .archived);
        }
    }.run);
}

test "Session archive pending blocks person and peer work and completes after Action settlement" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const receiver = try runningBash(&storage, &tmp, "archive-receiver");
            var archive = try archiveCommand("archive-busy", receiver.session.slice(), true);
            const accepted = storage.archiveSession(&archive, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, accepted.accepted.completion);
            try expectState(&storage, receiver.session.slice(), .archiving);
            var restore = try archiveCommand("restore-busy", receiver.session.slice(), false);
            const refused = storage.archiveSession(&restore, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.SessionArchiveRejection.archive_pending, refused.rejected.code);
            var incoming = try message(&tmp, "archive-blocked", receiver.session.slice());
            defer incoming.removeTemporaryContent(std.testing.io) catch unreachable;
            const blocked = storage.submitMessageWithModel(&incoming, null, .{});
            try std.testing.expect(blocked == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.session_archiving, blocked.rejected.code);
            const sender = try runningBash(&storage, &tmp, "archive-sender");
            var input: action.ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, sender.binding, &input);
            var peer = try message(&tmp, "archive-peer-blocked", receiver.session.slice());
            defer peer.removeTemporaryContent(std.testing.io) catch unreachable;
            peer.sender = .{};
            try peer.sender.?.store.set(storage.selector.slice());
            try peer.sender.?.session.set(sender.session.slice());
            peer.sender_handle = input.sender_handle;
            const peer_blocked = storage.submitMessageWithModel(&peer, null, .{});
            try std.testing.expect(peer_blocked == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.session_archiving, peer_blocked.rejected.code);
            try std.testing.expectEqual(action.ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(receiver.binding, .cancelled, "Bash stopped.", .{})).outcome);
            try expectState(&storage, receiver.session.slice(), .archived);
            const replay = storage.archiveSession(&archive, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{}).rejected.replayed);
            var fresh = try message(&tmp, "archive-fresh", receiver.session.slice());
            defer fresh.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&fresh, null, .{}) == .accepted);
            try expectState(&storage, receiver.session.slice(), .active);
            try std.testing.expect(storage.archiveSession(&archive, .{}).accepted.replayed);
            try expectState(&storage, receiver.session.slice(), .active);
            try std.testing.expect(storage.archiveSession(&restore, .{}).rejected.replayed);
            const observed = try testing.observeCommandForTesting(&storage, archive.key.slice());
            try std.testing.expect(observed.kind.session_archive.?.archived);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, observed.kind.session_archive.?.completion);
        }
    }.run);
}

test "Session archive pending intent survives reopen and uncertain Action recovery" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const receiver = try runningBash(&storage, &tmp, "archive-recovery");
            var archive = try archiveCommand("archive-recovery-stop", receiver.session.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, storage.archiveSession(&archive, .{}).accepted.completion);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try expectState(&storage, receiver.session.slice(), .archiving);
            const replay = storage.archiveSession(&archive, .{});
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, replay.accepted.completion);
            try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
            try expectState(&storage, receiver.session.slice(), .archived);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const complete = storage.archiveSession(&archive, .{});
            try std.testing.expect(complete.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, complete.accepted.completion);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try expectState(&storage, receiver.session.slice(), .archived);
            var fresh = try message(&tmp, "archive-recovered-wake", receiver.session.slice());
            defer fresh.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&fresh, null, .{}) == .accepted);
            try expectState(&storage, receiver.session.slice(), .active);
            try std.testing.expect(storage.archiveSession(&archive, .{}).accepted.replayed);
            try expectState(&storage, receiver.session.slice(), .active);
        }
    }.run);
}

test "Session archive admission rollback retains intent and exact retry after reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "archive-rollback-config");
            var archive = try archiveCommand("archive-rollback", session.slice(), true);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            var incoming = try message(&tmp, "archive-rollback-wake", session.slice());
            defer incoming.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{ .before_commit = true }) == .infrastructure_failure);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try expectState(&storage, session.slice(), .archived);
            const absent = try testing.observeCommandForTesting(&storage, incoming.key.slice());
            try std.testing.expectEqual(protocol.CommandObservationStatus.absent, absent.status);
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{}) == .accepted);
            try expectState(&storage, session.slice(), .active);
            const replay = storage.submitMessageWithModel(&incoming, null, .{});
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expect(storage.archiveSession(&archive, .{}).accepted.replayed);
            try expectState(&storage, session.slice(), .active);
        }
    }.run);
}

test "Session archive gates core peer sends and restores only fresh delivered work" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const receiver = try runningBash(&storage, &tmp, "archive-core-receiver");
            var archive = try archiveCommand("archive-core", receiver.session.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, storage.archiveSession(&archive, .{}).accepted.completion);
            var workspace: [protocol.max_workspace_bytes]u8 = undefined;
            var config = try testing.completeConfiguration("archive-core-sender", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
            config.configuration.tools = try .of(&.{"message_agent"});
            const sender = (try storage.configure(&config, .{})).accepted.session;
            try testing.submitTestMessage(&storage, &tmp, "archive-core-input", "archive-core-message", sender.slice(), "send two messages");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var decoded_buffer: [96]u8 = undefined;
            const decoded = try std.fmt.bufPrint(&decoded_buffer, "{{\"id\":\"{s}\",\"text\":\"hello\"}}", .{receiver.session.slice()});
            var encoded_buffer: [128]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hello\\\"}}", .{receiver.session.slice()});
            const calls = [_]fixtures.TestingCall{
                .{ .item_id = "core-one", .name = "message_agent", .encoded_call_id = "core-one", .decoded_call_id = "core-one", .encoded_arguments = encoded, .decoded_arguments = decoded },
                .{ .item_id = "core-two", .name = "message_agent", .encoded_call_id = "core-two", .decoded_call_id = "core-two", .encoded_arguments = encoded, .decoded_arguments = decoded },
            };
            try fixtures.settleCallsForTesting(&storage, &tmp, model, "archive-core-calls", &calls);
            const blocked = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedBlockedCoreWork).action;
            try std.testing.expectEqual(@as(@import("domain/command.zig").AgentDelivery, .failed), try storage.deliverAgentMessage(blocked.binding, receiver.session.slice(), "blocked", .{}));
            try expectState(&storage, receiver.session.slice(), .archiving);
            try std.testing.expectEqual(action.ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(receiver.binding, .cancelled, "Bash stopped.", .{})).outcome);
            try expectState(&storage, receiver.session.slice(), .archived);
            const fresh = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedFreshCoreWork).action;
            try std.testing.expectEqual(@as(@import("domain/command.zig").AgentDelivery, .delivered), try storage.deliverAgentMessage(fresh.binding, receiver.session.slice(), "fresh", .{}));
            try expectState(&storage, receiver.session.slice(), .active);
            try std.testing.expect(storage.archiveSession(&archive, .{}).accepted.replayed);
            try expectState(&storage, receiver.session.slice(), .active);
        }
    }.run);
}

test "Session archive stops approvals without restoring excluded work" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try fixtures.configureTestSessionAsk(&storage, "archive-approval-config");
            try testing.submitTestMessage(&storage, &tmp, "archive-approval-input", "archive-approval-message", session.slice(), "ask to run Bash");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]fixtures.TestingCall{.{
                .item_id = "approval-item",
                .name = "bash",
                .encoded_call_id = "approval-call",
                .decoded_call_id = "approval-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
            }};
            try fixtures.settleCallsForTesting(&storage, &tmp, model, "archive-approval-calls", &calls);
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
            const action_id = try testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
            var archive = try archiveCommand("archive-approval", session.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&archive, .{}).accepted.completion);
            try expectState(&storage, session.slice(), .archived);
            var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action_id, .decision = .allow_once };
            try decision.key.set("archive-late-approval");
            const refused = storage.decidePermission(&decision, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.PermissionDecisionRejection.action_not_pending, refused.rejected.code);
            var restore = try archiveCommand("archive-approval-restore", session.slice(), false);
            try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expect(storage.decidePermission(&decision, .{}).rejected.replayed);
        }
    }.run);
}

const Family = struct {
    parent: protocol.Bounded(protocol.max_session_bytes),
    child: protocol.Bounded(protocol.max_session_bytes),
};

fn attachedFamily(storage: *Store, tmp: *std.testing.TmpDir) !Family {
    var workspace: [protocol.max_workspace_bytes]u8 = undefined;
    var create = try testing.completeConfiguration("archive-parent", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
    create.configuration.tools = try .of(&.{ "bash", "start_agent" });
    const parent = (try storage.configure(&create, .{})).accepted.session;
    try testing.submitTestMessage(storage, tmp, "archive-parent-input", "archive-parent-message", parent.slice(), "start child");
    const model = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    try fixtures.settleCallsForTesting(storage, tmp, model, "archive-start-child", &.{.{
        .item_id = "child-item",
        .name = "start_agent",
        .encoded_call_id = "child-call",
        .decoded_call_id = "child-call",
        .encoded_arguments = "{}",
        .decoded_arguments = "{}",
    }});
    const start = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedStartAgent).action;
    var spec = try fixtures.testingAgentSpec(&.{"bash"}, "bypass");
    try std.testing.expectEqual(@as(@import("domain/command.zig").AgentStart, .started), try storage.startAgent(start.binding, parent.slice(), "child task", true, &spec, null, .{}));
    const listing = try fixtures.TestingListing.read(storage, tmp, .{ .archive = .all });
    try std.testing.expectEqual(@as(usize, 2), listing.count);
    var child: protocol.Bounded(protocol.max_session_bytes) = .{};
    try child.set(&listing.references[1]);
    return .{ .parent = parent, .child = child };
}

fn drainChildStop(storage: *Store) !void {
    const stop = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedChildStop).stop;
    var owed: protocol.SessionStopCommand = .{ .key = stop.key };
    try owed.session.set(stop.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
}

fn finishAnswer(storage: *Store, tmp: *std.testing.TmpDir, binding: store_core.AttemptBinding) !void {
    try testing.settleItemsForTesting(storage, tmp, binding, &.{"{\"type\":\"message\",\"id\":\"child-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"child done\"}]}"}, "child done");
}

test "Session archive preserves child organization and suppresses owed endings" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const family = try attachedFamily(&storage, &tmp);
            const parent = family.parent;
            const child = family.child.slice();
            try expectState(&storage, child, .active);
            var archive = try archiveCommand("archive-parent-stop", parent.slice(), true);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try expectState(&storage, parent.slice(), .archived);
            try expectState(&storage, child, .active);
            const stop = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedChildStop).stop;
            var owed: protocol.SessionStopCommand = .{ .key = stop.key };
            try owed.session.set(stop.session.slice());
            try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
            try expectState(&storage, child, .active);
            try testing.answerTestTurn(&storage, &tmp, child, "archive-child-answer", &.{.{ .encoded = "child done", .decoded = "child done" }});
            const answer = try testing.observeCommandForTesting(&storage, "archive-child-answer-key");
            const turn_id = answer.kind.message.?.queue.?.state.completed.binding.turn_id;
            var restore = try archiveCommand("archive-parent-restore", parent.slice(), false);
            try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
            try storage.close();
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expect(try storage.deliverChildEnding(turn_id, .{}));
            try expectState(&storage, parent.slice(), .active);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(parent.slice())).pending_messages);
            try expectState(&storage, child, .active);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND parent_ref=?2", .{ child, parent.slice() }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        }
    }.run);
}

test "Session archive ending causality survives restored parents and ordinary child stops" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            const Ordering = enum { backlog, ordinary_stop_in_flight, close_before_owed_stop, fresh_after_restore };
            inline for (std.meta.tags(Ordering)) |ordering| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                const family = try attachedFamily(&storage, &tmp);
                var child_model: ?store_core.AttemptBinding = null;
                var child_action: ?action.ActionAttemptBinding = null;
                if (ordering != .fresh_after_restore) child_model = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                if (ordering == .backlog) try finishAnswer(&storage, &tmp, child_model.?);
                if (ordering == .ordinary_stop_in_flight) {
                    const calls = [_]fixtures.TestingCall{.{
                        .item_id = "causal-item",
                        .name = "bash",
                        .encoded_call_id = "causal-call",
                        .decoded_call_id = "causal-call",
                        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    }};
                    try fixtures.settleCallsForTesting(&storage, &tmp, child_model.?, "archive-causal-calls", &calls);
                    child_action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
                }
                var archive = try archiveCommand("archive-causal-parent", family.parent.slice(), true);
                try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                var restore = try archiveCommand("restore-causal-parent", family.parent.slice(), false);
                try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
                if (ordering == .ordinary_stop_in_flight) {
                    var stop = try fixtures.completeSessionStop("ordinary-child-stop", family.child.slice());
                    try std.testing.expectEqual(protocol.SessionStopCompletion.pending, storage.stopSession(&stop, .{}).accepted.completion);
                    try stop.key.set("repeated-child-stop");
                    try std.testing.expectEqual(protocol.SessionStopCompletion.pending, storage.stopSession(&stop, .{}).accepted.completion);
                    try std.testing.expect(!try storage.deliverChildEnding(child_model.?.turn_id, .{}));
                    try std.testing.expectEqual(action.ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(child_action.?, .cancelled, "Bash stopped.", .{})).outcome);
                } else if (ordering == .close_before_owed_stop) {
                    try finishAnswer(&storage, &tmp, child_model.?);
                    try std.testing.expect(!try storage.deliverChildEnding(child_model.?.turn_id, .{}));
                    try drainChildStop(&storage);
                } else {
                    try drainChildStop(&storage);
                    if (ordering == .fresh_after_restore) {
                        try testing.submitTestMessage(&storage, &tmp, "archive-fresh-child-input", "archive-fresh-child-message", family.child.slice(), "fresh work");
                        child_model = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                        try finishAnswer(&storage, &tmp, child_model.?);
                    }
                }
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                const delivered = try storage.deliverChildEnding(child_model.?.turn_id, .{});
                try std.testing.expectEqual(ordering != .close_before_owed_stop, delivered);
                const expected_pending: u64 = if (ordering == .fresh_after_restore) 1 else 0;
                try std.testing.expectEqual(expected_pending, (try storage.inspectSessionForTesting(family.parent.slice())).pending_messages);
                if (ordering != .close_before_owed_stop) {
                    const forward = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }) orelse return error.ExpectedEndingForward).forward;
                    try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
                    const page = try store_core.activityPageForTesting(&storage, .{ .session = family.parent, .kinds = .initOne(.turn_ended) });
                    var forwarded: usize = 0;
                    for (page.items[0..page.count]) |item| {
                        if (item.value.turn_ended.session.eql(family.child.slice())) forwarded += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 1), forwarded);
                }
                try expectState(&storage, family.child.slice(), .active);
                if (ordering != .fresh_after_restore) try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
            }
        }
    }.run);
}

test "Session pin archive admission clears immediately through pending stop and Message restore" {
    const pin = @import("pin_tests.zig");
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const receiver = try runningBash(&storage, &tmp, "pin-archive-busy");
            var request = try pin.command("pin-before-busy-archive", receiver.session.slice(), true);
            try std.testing.expect(storage.pinSession(&request, .{}) == .accepted);
            var archive = try archiveCommand("pin-busy-archive", receiver.session.slice(), true);
            const accepted = storage.archiveSession(&archive, .{});
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, accepted.accepted.completion);
            try std.testing.expectEqual(@as(?u64, null), try pin.order(&storage, &tmp, receiver.session.slice()));
            try request.key.set("pin-during-archive");
            try std.testing.expectEqual(protocol.SessionPinRejection.session_archiving, storage.pinSession(&request, .{}).rejected.code);
            request.pinned = false;
            try request.key.set("unpin-during-archive");
            try std.testing.expect(storage.pinSession(&request, .{}) == .accepted);
            _ = try storage.settleActionAttempt(receiver.binding, .cancelled, "Bash stopped.", .{});
            var incoming = try message(&tmp, "pin-message-restore", receiver.session.slice());
            defer incoming.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&incoming, null, .{}) == .accepted);
            try std.testing.expectEqual(@as(?u64, null), try pin.order(&storage, &tmp, receiver.session.slice()));
            request.pinned = true;
            try request.key.set("pin-after-message-restore");
            try std.testing.expect(storage.pinSession(&request, .{}) == .accepted);
        }
    }.run);
}

test "Session pin parent and child organization stays independent during attached stop forwarding" {
    const pin = @import("pin_tests.zig");
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const family = try attachedFamily(&storage, &tmp);
            var parent = try pin.command("pin-family-parent", family.parent.slice(), true);
            var child = try pin.command("pin-family-child", family.child.slice(), true);
            try std.testing.expect(storage.pinSession(&parent, .{}) == .accepted);
            try std.testing.expect(storage.pinSession(&child, .{}) == .accepted);
            const child_rank = (try pin.order(&storage, &tmp, family.child.slice())).?;
            var archive = try archiveCommand("pin-family-archive-parent", family.parent.slice(), true);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try drainChildStop(&storage);
            try std.testing.expectEqual(@as(?u64, null), try pin.order(&storage, &tmp, family.parent.slice()));
            try std.testing.expectEqual(child_rank, (try pin.order(&storage, &tmp, family.child.slice())).?);
            archive = try archiveCommand("pin-family-archive-child", family.child.slice(), true);
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(@as(?u64, null), try pin.order(&storage, &tmp, family.child.slice()));
            try std.testing.expect(storage.pinSession(&child, .{}).accepted.replayed);
            try std.testing.expectEqual(@as(?u64, null), try pin.order(&storage, &tmp, family.child.slice()));
        }
    }.run);
}

const session_list = @import("../session_list.zig");
const session_archive = @import("../session_archive.zig");

fn configureInWorkspace(storage: *Store, key: []const u8, workspace: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var command = try testing.completeConfiguration(key, "", workspace, "model-a");
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

/// Walks one list request page by page, following the full tail cursor until it ends.
const ListWalk = struct {
    refs: [256][6]u8 = undefined,
    count: usize = 0,
    after: u64 = 0,
    ceiling: u64 = 0,
    more: bool = false,

    pub fn head(_: *ListWalk) !void {}
    pub fn row(self: *ListWalk, value: *const session_list.Row) !void {
        try std.testing.expect(self.count < self.refs.len);
        try std.testing.expectEqual(@as(usize, 6), value.reference.len);
        self.refs[self.count] = value.reference[0..6].*;
        self.count += 1;
    }
    pub fn tail(self: *ListWalk, value: session_list.Tail) !void {
        switch (value) {
            .full => |full| {
                self.more = true;
                self.after = full.after;
                self.ceiling = full.ceiling;
            },
            .last => self.more = false,
            .changed => return error.TestUnexpectedResult,
            .window => return error.TestUnexpectedResult,
        }
    }
    pub fn archivedRow(_: *ListWalk, _: *const session_list.ArchivedRow) !void {
        return error.TestUnexpectedResult;
    }
};

fn walkAll(storage: *Store, archive: session_archive.Filter, workspace: ?[]const u8, out: *[256][6]u8) !usize {
    var request: session_list.ListSessions = .{ .archive = archive };
    if (workspace) |name| {
        var bounded: @TypeOf(request.workspace.?) = .{};
        try bounded.set(name);
        request.workspace = bounded;
    }
    var count: usize = 0;
    while (true) {
        var walk: ListWalk = .{};
        var pages: @import("domain/session_list_read.zig").Scratch = undefined;
        try storage.readSessionList(&request, &walk, &pages);
        for (walk.refs[0..walk.count]) |ref| {
            try std.testing.expect(count < out.len);
            out[count] = ref;
            count += 1;
        }
        if (!walk.more) return count;
        request.after = walk.after;
        request.ceiling = walk.ceiling;
    }
}

test "Session list membership and order equal the state reference for every filter and workspace" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const home = try testing.canonicalCwd(std.testing.io, &other_buffer);
            const other = std.fs.path.dirname(home) orelse home;

            // created_seq order is the order of creation; `expected` records it with each Session's workspace.
            var created: [64]protocol.Bounded(protocol.max_session_bytes) = undefined;
            var in_other: [64]bool = undefined;
            var created_count: usize = 0;
            const Add = struct {
                fn session(list: *[64]protocol.Bounded(protocol.max_session_bytes), flags: *[64]bool, n: *usize, ref: protocol.Bounded(protocol.max_session_bytes), other_flag: bool) void {
                    list[n.*] = ref;
                    flags[n.*] = other_flag;
                    n.* += 1;
                }
            };
            // Active Sessions in the canonical workspace and in the other workspace.
            for (0..10) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "walk-live-{d}", .{i});
                const ref = try testing.configureTestSession(&storage, key);
                Add.session(&created, &in_other, &created_count, ref, false);
            }
            for (0..2) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "walk-other-live-{d}", .{i});
                const ref = try configureInWorkspace(&storage, key, other);
                Add.session(&created, &in_other, &created_count, ref, true);
            }
            // Archiving by an open turn: a Message is admitted to a model attempt that never settles.
            {
                const ref = try testing.configureTestSession(&storage, "walk-turn-open");
                var message_key_buffer: [protocol.max_key_bytes]u8 = undefined;
                const message_key = try std.fmt.bufPrint(&message_key_buffer, "walk-turn-open-message", .{});
                try testing.submitTestMessage(&storage, &tmp, message_key, message_key, ref.slice(), "keep the turn open");
                _ = (try storage.admitNextModelAttempt(.{})).?;
                var archive = try archiveCommand("walk-turn-open-archive", ref.slice(), true);
                const accepted = storage.archiveSession(&archive, .{});
                try std.testing.expect(accepted == .accepted);
                // The stop's interrupt settles the open turn in the same commit, so no fixture reaches a pending
                // turn-only stop; this Session is archived. The pending turn-only state is not reproduced.
                try expectState(&storage, ref.slice(), .archived);
                Add.session(&created, &in_other, &created_count, ref, false);
            }
            // Archiving by an unaccepted Action: a running Bash Action (its turn is open too).
            {
                const bash = try runningBash(&storage, &tmp, "walk-action-open");
                var archive = try archiveCommand("walk-action-open-archive", bash.session.slice(), true);
                const accepted = storage.archiveSession(&archive, .{});
                try std.testing.expect(accepted == .accepted);
                try std.testing.expectEqual(protocol.SessionStopCompletion.pending, accepted.accepted.completion);
                try expectState(&storage, bash.session.slice(), .archiving);
                Add.session(&created, &in_other, &created_count, bash.session, false);
            }
            // Archived and restored Sessions, twelve archived so the Archived filter spans pages.
            for (0..12) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "walk-archived-{d}", .{i});
                const ref = try testing.configureTestSession(&storage, key);
                var archive_key_buffer: [32]u8 = undefined;
                var archive = try archiveCommand(try std.fmt.bufPrint(&archive_key_buffer, "walk-archive-{d}", .{i}), ref.slice(), true);
                try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                try expectState(&storage, ref.slice(), .archived);
                Add.session(&created, &in_other, &created_count, ref, false);
            }
            for (0..2) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "walk-restored-{d}", .{i});
                const ref = try testing.configureTestSession(&storage, key);
                var archive_key_buffer: [32]u8 = undefined;
                var archive = try archiveCommand(try std.fmt.bufPrint(&archive_key_buffer, "walk-restore-archive-{d}", .{i}), ref.slice(), true);
                try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                var restore_key_buffer: [32]u8 = undefined;
                var restore = try archiveCommand(try std.fmt.bufPrint(&restore_key_buffer, "walk-restore-{d}", .{i}), ref.slice(), false);
                try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
                try expectState(&storage, ref.slice(), .active);
                Add.session(&created, &in_other, &created_count, ref, false);
            }
            const filters = [_]session_archive.Filter{ .all, .active, .archived };
            const workspaces = [_]?[]const u8{ null, other };
            for (workspaces) |workspace| for (filters) |filter| {
                // Reference: creation order, restricted to the workspace, then classified by the Session's own state.
                var expected: [64][6]u8 = undefined;
                var expected_count: usize = 0;
                for (created[0..created_count], in_other[0..created_count]) |session, is_other| {
                    if (workspace != null and !is_other) continue;
                    const observation = try storage.inspectSessionForTesting(session.slice());
                    try std.testing.expect(observation.found);
                    const state: session_archive.State = switch (observation.archive_state) {
                        .active => .active,
                        .archiving => .archiving,
                        .archived => .archived,
                    };
                    if (!filter.includes(state)) continue;
                    expected[expected_count] = session.slice()[0..6].*;
                    expected_count += 1;
                }
                var actual: [256][6]u8 = undefined;
                const actual_count = try walkAll(&storage, filter, workspace, &actual);
                try std.testing.expectEqualSlices([6]u8, expected[0..expected_count], actual[0..actual_count]);
            };
        }
    }.run);
}

const WindowRow = struct { reference: [6]u8, key: u64, first: ?WindowFirst = null };

/// What the window carries of a row's first Message: its position, admission, content, and whether a line came inline.
const WindowFirst = struct {
    position: u64,
    admission: u64,
    content: content_value.Value,
    has_line: bool,
    line_buf: [@import("../session_line.zig").max_line_bytes]u8 = undefined,
    line_len: ?usize = null,
};

/// Records one Archived window page: its rows (newest first), and the page's tail.
const WindowVisitor = struct {
    rows: [session_list.archived_window_size]WindowRow = undefined,
    count: usize = 0,
    first: ?u64 = null,
    last: ?u64 = null,
    more_above: bool = false,
    more_below: bool = false,

    pub fn head(self: *WindowVisitor) !void {
        self.* = .{};
    }

    pub fn archivedRow(self: *WindowVisitor, archived: *const session_list.ArchivedRow) !void {
        if (self.count == self.rows.len or archived.reference.len != 6) return error.TooManyRows;
        const first: ?WindowFirst = if (archived.first) |first| blk: {
            var out: WindowFirst = .{ .position = first.position, .admission = first.admission, .content = first.content, .has_line = first.line != null };
            if (first.line) |line| {
                @memcpy(out.line_buf[0..line.len], line);
                out.line_len = line.len;
            }
            break :blk out;
        } else null;
        self.rows[self.count] = .{ .reference = archived.reference[0..6].*, .key = archived.archive_seq, .first = first };
        self.count += 1;
    }

    pub fn row(self: *WindowVisitor, values: *const session_list.Row) !void {
        _ = self;
        _ = values;
        return error.UnexpectedRow;
    }

    pub fn tail(self: *WindowVisitor, values: session_list.Tail) !void {
        const window = switch (values) {
            .window => |window| window,
            else => return error.UnexpectedTail,
        };
        self.first = window.first;
        self.last = window.last;
        self.more_above = window.more_above;
        self.more_below = window.more_below;
    }

    pub fn rowsSlice(self: *const WindowVisitor) []const WindowRow {
        return self.rows[0..self.count];
    }
};

fn readWindow(storage: *Store, cursor: session_list.ArchivedCursor, visitor: *WindowVisitor) !void {
    const request: protocol.ListSessions = .{ .archive = .archived, .window = cursor };
    var pages: @import("domain/session_list_read.zig").Scratch = undefined;
    try storage.readSessionList(&request, visitor, &pages);
}

test "Archived window carries the first Message's position, admission and content, and a line only when it is inline Text" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // A parts-form first Message: its line needs a parts read, so the window carries none.
            const parts = try testing.configureTestSession(&storage, "window-parts-first");
            try testing.submitTestMessageParts(&storage, &tmp, "window-parts-message", parts.slice(), &.{ .{ .bytes = "first" }, .{ .bytes = "second" } });
            // An inline-Text first Message: its line rides the window.
            const text = try testing.configureTestSession(&storage, "window-text-first");
            try testing.submitTestMessage(&storage, &tmp, "window-text-message", "window-text-message", text.slice(), "hello window");
            var parts_archive = try archiveCommand("window-parts-archive", parts.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&parts_archive, .{}).accepted.completion);
            var text_archive = try archiveCommand("window-text-archive", text.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&text_archive, .{}).accepted.completion);

            var page: WindowVisitor = .{};
            try readWindow(&storage, .head, &page);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            for (page.rowsSlice()) |row| {
                const first = row.first orelse return error.TestUnexpectedResult;
                try std.testing.expect(first.position != 0 and first.admission != 0);
                const is_parts = std.mem.eql(u8, &row.reference, parts.slice()[0..6]);
                switch (first.content) {
                    .parts => |value| {
                        try std.testing.expect(is_parts);
                        try std.testing.expect(value.identity.length != 0);
                        try std.testing.expectEqual(content_value.Owner{ .message = first.admission }, value.owner);
                    },
                    .text => |value| {
                        try std.testing.expect(!is_parts);
                        try std.testing.expectEqual(@as(u64, "hello window".len), value.length);
                    },
                }
                try std.testing.expectEqual(!is_parts, first.has_line);
            }
        }
    }.run);
}

test "Archived window pages walk every archived Session once, newest archive first, in both directions" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const archived_count = 43;
            var refs: [archived_count + 3][6]u8 = undefined;
            var key_buffer: [48]u8 = undefined;
            for (&refs, 0..) |*ref, index| {
                if (index == archived_count + 2) break;
                const key = try std.fmt.bufPrint(&key_buffer, "window-session-{d}", .{index});
                const session = try testing.configureTestSession(&storage, key);
                try std.testing.expectEqual(@as(usize, 6), session.slice().len);
                ref.* = session.slice()[0..6].*;
            }
            // Session 45 is archiving: an unaccepted Action keeps its stop incomplete.
            const pending = try runningBash(&storage, &tmp, "window-pending");
            refs[archived_count + 2] = pending.session.slice()[0..6].*;

            // Archive order, oldest first. Session 5 is restored and archived again, so it takes a newer key.
            var order: [archived_count][6]u8 = undefined;
            for (0..archived_count) |index| {
                const key = try std.fmt.bufPrint(&key_buffer, "window-archive-{d}", .{index});
                var archive = try archiveCommand(key, &refs[index], true);
                try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&archive, .{}).accepted.completion);
                order[index] = refs[index];
            }
            var restore = try archiveCommand("window-restore-5", &refs[5], false);
            try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
            var again = try archiveCommand("window-archive-5-again", &refs[5], true);
            try std.testing.expect(storage.archiveSession(&again, .{}) == .accepted);
            var moved: [archived_count][6]u8 = undefined;
            var moved_len: usize = 0;
            for (order) |ref| if (!std.mem.eql(u8, &ref, &refs[5])) {
                moved[moved_len] = ref;
                moved_len += 1;
            };
            moved[moved_len] = refs[5];
            moved_len += 1;
            try std.testing.expectEqual(archived_count, moved_len);
            var expected: [archived_count][6]u8 = undefined;
            for (0..archived_count) |index| expected[index] = moved[archived_count - 1 - index];

            var pending_archive = try archiveCommand("window-archive-pending", &refs[archived_count + 2], true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.pending, storage.archiveSession(&pending_archive, .{}).accepted.completion);

            // Newest first from the head, then down by the last key of each page.
            var seen: [archived_count]WindowRow = undefined;
            var seen_len: usize = 0;
            var page: WindowVisitor = .{};
            try readWindow(&storage, .head, &page);
            try std.testing.expectEqual(@as(usize, session_list.archived_window_size), page.count);
            try std.testing.expect(!page.more_above and page.more_below);
            while (true) {
                for (page.rowsSlice()) |row| {
                    seen[seen_len] = row;
                    seen_len += 1;
                }
                if (!page.more_below) break;
                const next = page.rowsSlice()[page.count - 1].key;
                try readWindow(&storage, .{ .below = next }, &page);
                try std.testing.expect(page.more_above);
            }
            try std.testing.expectEqual(archived_count, seen_len);
            for (expected, seen[0..seen_len]) |want, got| try std.testing.expectEqualSlices(u8, &want, &got.reference);
            for (seen[1..seen_len], seen[0 .. seen_len - 1]) |after, before| try std.testing.expect(after.key < before.key);

            // Oldest first from the tail, then upward by the newest key of each page. Blocks come out
            // oldest first, so they are reversed for display.
            var blocks: [4][session_list.archived_window_size]WindowRow = undefined;
            var block_lengths: [4]usize = .{ 0, 0, 0, 0 };
            var blocks_len: usize = 0;
            try readWindow(&storage, .tail, &page);
            try std.testing.expect(!page.more_below and page.more_above);
            while (true) {
                @memcpy(blocks[blocks_len][0..page.count], page.rowsSlice());
                block_lengths[blocks_len] = page.count;
                blocks_len += 1;
                if (!page.more_above) break;
                const newest = page.rowsSlice()[0].key;
                try readWindow(&storage, .{ .above = newest }, &page);
                try std.testing.expect(page.more_below);
            }
            var upward: [archived_count]WindowRow = undefined;
            var upward_len: usize = 0;
            var block = blocks_len;
            while (block > 0) {
                block -= 1;
                for (blocks[block][0..block_lengths[block]]) |row| {
                    upward[upward_len] = row;
                    upward_len += 1;
                }
            }
            try std.testing.expectEqual(archived_count, upward_len);
            for (expected, upward[0..upward_len]) |want, got| try std.testing.expectEqualSlices(u8, &want, &got.reference);

            // Restored and archived again: one row, at its newer key, first in the window.
            var appearances: usize = 0;
            for (seen[0..seen_len]) |row| if (std.mem.eql(u8, &row.reference, &refs[5])) {
                appearances += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), appearances);
            try std.testing.expectEqualSlices(u8, &refs[5], &seen[0].reference);

            // Live and archiving Sessions are absent from every page.
            for (seen[0..seen_len]) |row| {
                for (refs[archived_count..]) |ref| try std.testing.expect(!std.mem.eql(u8, &row.reference, &ref));
            }
        }
    }.run);
}

/// Collects the references of every page of one direction: the head walk (`below`) or the tail walk (`above`).
fn collectWindow(storage: *Store, from_head: bool, out: *[256][6]u8) !usize {
    var count: usize = 0;
    var page: WindowVisitor = .{};
    try readWindow(storage, if (from_head) .head else .tail, &page);
    while (true) {
        for (page.rowsSlice()) |row| {
            try std.testing.expect(count < out.len);
            out[count] = row.reference;
            count += 1;
        }
        if (from_head) {
            if (!page.more_below) return count;
            try readWindow(storage, .{ .below = page.rowsSlice()[page.count - 1].key }, &page);
        } else {
            if (!page.more_above) return count;
            try readWindow(storage, .{ .above = page.rowsSlice()[0].key }, &page);
        }
    }
}

/// The Archived window's union, from the head and from the tail, is the Archived membership of walkAll: the same
/// Sessions, each once.
fn expectWindowMatchesWalk(storage: *Store) !void {
    var expected: [256][6]u8 = undefined;
    const expected_count = try walkAll(storage, .archived, null, &expected);
    var head: [256][6]u8 = undefined;
    const head_count = try collectWindow(storage, true, &head);
    var tail: [256][6]u8 = undefined;
    const tail_count = try collectWindow(storage, false, &tail);
    try std.testing.expectEqual(expected_count, head_count);
    try std.testing.expectEqual(expected_count, tail_count);
    for (head[0..head_count], 0..) |ref, index| {
        for (head[0..index]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, &ref));
        try std.testing.expect(containsRef(expected[0..expected_count], ref));
    }
    for (expected[0..expected_count]) |ref| {
        try std.testing.expect(containsRef(head[0..head_count], ref));
        try std.testing.expect(containsRef(tail[0..tail_count], ref));
    }
}

fn containsRef(refs: []const [6]u8, ref: [6]u8) bool {
    for (refs) |candidate| if (std.mem.eql(u8, &candidate, &ref)) return true;
    return false;
}

/// A fresh Session archived now, named by `key`. Its reference is returned.
fn archiveFreshSession(storage: *Store, key: []const u8) ![6]u8 {
    var archive_key_buffer: [64]u8 = undefined;
    const session = try testing.configureTestSession(storage, key);
    var archive = try archiveCommand(try std.fmt.bufPrint(&archive_key_buffer, "archive-{s}", .{key}), session.slice(), true);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&archive, .{}).accepted.completion);
    return session.slice()[0..6].*;
}

test "Archived window equals the Archived membership over the archive's edge cases" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            // An empty Store: no rows, no keys, no page beyond it.
            var empty: WindowVisitor = .{};
            try readWindow(&storage, .head, &empty);
            try std.testing.expectEqual(@as(usize, 0), empty.count);
            try std.testing.expect(empty.first == null and empty.last == null and !empty.more_above and !empty.more_below);
            try expectWindowMatchesWalk(&storage);

            // Exactly one full page: 40 archived Sessions, no more below.
            var key_buffer: [48]u8 = undefined;
            for (0..session_list.archived_window_size) |index| {
                _ = try archiveFreshSession(&storage, try std.fmt.bufPrint(&key_buffer, "edge-forty-{d}", .{index}));
            }
            var exact: WindowVisitor = .{};
            try readWindow(&storage, .head, &exact);
            try std.testing.expectEqual(@as(usize, session_list.archived_window_size), exact.count);
            try std.testing.expect(!exact.more_above and !exact.more_below);
            try expectWindowMatchesWalk(&storage);

            // One more: 41 archived Sessions, the head page is full and the 41st is one page below.
            _ = try archiveFreshSession(&storage, "edge-forty-one");
            var head: WindowVisitor = .{};
            try readWindow(&storage, .head, &head);
            try std.testing.expectEqual(@as(usize, session_list.archived_window_size), head.count);
            try std.testing.expect(!head.more_above and head.more_below);
            try expectWindowMatchesWalk(&storage);

            // A Session with no Message: its first is absent, and it is still listed.
            const bare = try archiveFreshSession(&storage, "edge-bare");
            var bare_page: WindowVisitor = .{};
            try readWindow(&storage, .head, &bare_page);
            try std.testing.expectEqualSlices(u8, &bare, &bare_page.rowsSlice()[0].reference);
            try std.testing.expect(bare_page.rowsSlice()[0].first == null);
            try expectWindowMatchesWalk(&storage);

            // A pending admission before the first turn: the first Message is that admission, with its line.
            const pending = try testing.configureTestSession(&storage, "edge-pending-first-session");
            try testing.submitTestMessage(&storage, &tmp, "edge-pending-file", "edge-pending-message", pending.slice(), "pending first line");
            var pending_archive = try archiveCommand("edge-pending-archive", pending.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&pending_archive, .{}).accepted.completion);
            var pending_page: WindowVisitor = .{};
            try readWindow(&storage, .head, &pending_page);
            const pending_row = pending_page.rowsSlice()[0];
            try std.testing.expectEqualSlices(u8, pending.slice()[0..6], &pending_row.reference);
            const pending_first = pending_row.first orelse return error.TestUnexpectedResult;
            try std.testing.expect(pending_first.admission != 0 and pending_first.has_line);
            try std.testing.expectEqualStrings("pending first line", pending_first.line_buf[0..pending_first.line_len.?]);
            try expectWindowMatchesWalk(&storage);

            // A leading blank line: the first line is blank, so the Session is named by its reference, as the
            // client names it.
            const blank = try testing.configureTestSession(&storage, "edge-blank-session");
            try testing.submitTestMessage(&storage, &tmp, "edge-blank-file", "edge-blank-message", blank.slice(), "\nFix CI");
            var blank_archive = try archiveCommand("edge-blank-archive", blank.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&blank_archive, .{}).accepted.completion);
            var blank_page: WindowVisitor = .{};
            try readWindow(&storage, .head, &blank_page);
            const blank_row = blank_page.rowsSlice()[0];
            try std.testing.expectEqualSlices(u8, blank.slice()[0..6], &blank_row.reference);
            try std.testing.expect(!(blank_row.first orelse return error.TestUnexpectedResult).has_line);
            try expectWindowMatchesWalk(&storage);

            // A stale anchor: the newest Session is restored. Its key now names no Archived Session, so the page
            // above it is empty, its first and last are null, and the flag on the side it moved away from says a
            // page was there when the cursor was made. The client re-reads from head.
            var newest: WindowVisitor = .{};
            try readWindow(&storage, .head, &newest);
            const anchor = newest.rowsSlice()[0];
            var restore = try archiveCommand("edge-restore-anchor", &anchor.reference, false);
            try std.testing.expect(storage.archiveSession(&restore, .{}) == .accepted);
            var stale: WindowVisitor = .{};
            try readWindow(&storage, .{ .above = anchor.key }, &stale);
            try std.testing.expectEqual(@as(usize, 0), stale.count);
            try std.testing.expect(stale.first == null and stale.last == null and stale.more_below);
            // A Session restored and left live is in no window page.
            try expectWindowMatchesWalk(&storage);
            var after_restore: WindowVisitor = .{};
            try readWindow(&storage, .head, &after_restore);
            for (after_restore.rowsSlice()) |row| try std.testing.expect(!std.mem.eql(u8, &row.reference, &anchor.reference));
            // A private first Message is exposed as corrupt, as the live list exposes it (content_parts.publicValue
            // refuses private content, and inspection.md fences private exposed content): the page is refused, not
            // read with a line-less row. Last, because every later page reads the same row.
            const private = try testing.configureTestSession(&storage, "edge-private-session");
            try testing.submitTestMessage(&storage, &tmp, "edge-private-file", "edge-private-message", private.slice(), "private first line");
            try testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT m.content_id FROM message_admission m WHERE m.session_ref=?1 AND m.turn_id IS NULL)", .{private.slice()});
            var private_archive = try archiveCommand("edge-private-archive", private.slice(), true);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, storage.archiveSession(&private_archive, .{}).accepted.completion);
            var private_page: WindowVisitor = .{};
            try std.testing.expectError(error.CorruptStore, readWindow(&storage, .head, &private_page));
        }
    }.run);
}

// The MySQL plan tests read a statement's plan bound as the Store binds it (mysql_testing.plan) over a populated Store.
// A key that names no row plans as a const-table miss, which shows no access path at all, so `plan` refuses it. On
// tables of one or two rows MySQL's cost model prefers a scan or a hash join to any index, which says nothing about a
// Store of real size, so a plan test that ranks access paths across joins reads the plan over `PlanStore`.

/// A Store shaped like one at scale, where MySQL costs a keyed probe below a scan: a creator chain `chain_length`
/// Sessions deep whose every link has answered Turns, so most Turns are finished and positioned, and was archived and
/// restored, so every link has a Session stop, and running Bash Sessions: every eighth link starts one and archives
/// it, and the last link starts `live`, which stays active. A page of eight refs must be a small share of the Store's
/// Sessions, Turns and Actions, or MySQL rightly scans or hash-joins a table it would read most of. So `finished_bash`
/// Sessions each run a Bash Action to success and answer after it, as most Sessions at scale have: their Actions are
/// accepted and their Turns positioned, and the archiving candidates stay a small share too. `idle_sessions`
/// configure-only Sessions add Session rows cheaply. Statistics are refreshed after the writes.
const PlanStore = struct {
    const chain_length = 16;
    const answered_turns = 2;
    const finished_bash = 16;
    const idle_sessions = 96;
    /// The first Session of the creator chain and the last one, which descends from it through every link.
    root: protocol.Bounded(protocol.max_session_bytes),
    leaf: protocol.Bounded(protocol.max_session_bytes),
    /// The last running Bash Session, not archived: it has a Turn, an Operation and an Action in flight.
    live: protocol.Bounded(protocol.max_session_bytes),
    /// Every link of the creator chain, in creation order.
    chain: [chain_length]protocol.Bounded(protocol.max_session_bytes) = undefined,

    /// A full page of eight refs as the Store binds them: `live` and the last seven links of the creator chain.
    fn page(store: *const PlanStore) [8][]const u8 {
        var refs: [8][]const u8 = undefined;
        refs[0] = store.live.slice();
        for (refs[1..], 0..) |*ref, index| ref.* = store.chain[chain_length - 1 - index].slice();
        return refs;
    }

    fn populate(storage: *Store, tmp: *std.testing.TmpDir) !PlanStore {
        const root = try testing.configureTestSession(storage, "plan-chain-0");
        var result: PlanStore = .{ .root = root, .leaf = root, .live = undefined };
        inline for (1..chain_length + 1) |link| {
            const name = std.fmt.comptimePrint("plan-{d}", .{link});
            var command: wire_request.ConfigureCommand = .{};
            try command.key.set(name ++ "-chain");
            command.configuration = try fixtures.testingAgentSpec(&.{}, "ask");
            command.configuration.parent.state = .value;
            try command.configuration.parent.value.set(result.leaf.slice());
            const reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            result.leaf = reply.accepted.session;
            result.chain[link - 1] = result.leaf;
            inline for (0..answered_turns) |turn| {
                const answer = std.fmt.comptimePrint("{s}-answer-{d}", .{ name, turn });
                try testing.answerTestTurn(storage, tmp, result.leaf.slice(), answer, &.{.{ .encoded = "done", .decoded = "done" }});
            }
            // Archiving and restoring leaves a stop behind, as Session stops accumulate at scale.
            var archived = try archiveCommand(name ++ "-archived", result.leaf.slice(), true);
            try std.testing.expect(storage.archiveSession(&archived, .{}) == .accepted);
            var restored = try archiveCommand(name ++ "-restored", result.leaf.slice(), false);
            try std.testing.expect(storage.archiveSession(&restored, .{}) == .accepted);
            if (link % 8 == 1 or link == chain_length) {
                const bash = (try runningBash(storage, tmp, name ++ "-bash")).session;
                if (link == chain_length) result.live = bash else {
                    var archive = try archiveCommand(name ++ "-archive", bash.slice(), true);
                    try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                }
            }
        }
        inline for (0..finished_bash) |index| {
            @setEvalBranchQuota(100_000);
            const name = std.fmt.comptimePrint("plan-finished-{d}", .{index});
            const bash = try runningBash(storage, tmp, name);
            _ = try storage.settleActionAttempt(bash.binding, .succeeded, "Bash succeeded.", .{});
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try testing.settleAnswerTestTurn(storage, tmp, next, name ++ "-answer", &.{.{ .encoded = "done", .decoded = "done" }});
        }
        var key_buffer: [64]u8 = undefined;
        for (0..idle_sessions) |index| _ = try testing.configureTestSession(storage, try std.fmt.bufPrint(&key_buffer, "plan-idle-{d}", .{index}));
        try @import("mysql_testing.zig").analyzeTables(storage);
        return result;
    }
};

/// Fails unless the plan reads `name` (a table or alias, as MySQL names it) and every such read is keyed on `key`. The pending-Message probes
/// name message_admission_session_pending, a partial index MySQL states through a `_lead` column that a `session_ref=`
/// probe cannot seek, so rsql drops the `@index` hint on MySQL and the probe seeks the Session ref through another
/// index, walking that Session's Message history (#1979). Until #1979 lands, the plan tests hold the probe to a
/// Session-keyed seek rather than to the partial index.
fn expectKeyedOn(plan: []const u8, comptime name: []const u8, comptime key: []const u8) !void {
    var lines = std.mem.splitScalar(u8, plan, '\n');
    var seen = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " on " ++ name ++ " using ") == null) continue;
        seen = true;
        if (std.mem.indexOf(u8, line, "(" ++ key) == null) {
            std.debug.print("{s} is not keyed on {s}: {s}\n", .{ name, key, line });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen);
}

/// Fails on any scan of a table or a whole index, except of the aliases in `allowed` (a materialized CTE result).
fn expectNoScan(plan: []const u8, allowed: []const []const u8) !void {
    for ([_][]const u8{ "Table scan on ", "Index scan on ", "Covering index scan on " }) |scan| {
        var rest = plan;
        while (std.mem.indexOf(u8, rest, scan)) |at| {
            rest = rest[at + scan.len ..];
            const alias = rest[0 .. std.mem.indexOfAny(u8, rest, " \n") orelse rest.len];
            var listed = false;
            for (allowed) |name| listed = listed or std.mem.eql(u8, alias, name);
            if (!listed) {
                std.debug.print("unexpected scan: {s}{s}\n", .{ scan, alias });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// The changed-page ancestor batch is one statement for up to eight seeds; unused seed slots are empty, as the Store
// binds them. MySQL materializes the recursive CTE and scans that temporary result (`seen`, `tail`, `parent`,
// `child`); every session row is a keyed probe, so no scan grows with the Store.
test "MySQL plans the changed-page ancestor batch through the session key" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const session_list_read = @import("domain/session_list_read.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const store = try PlanStore.populate(&storage, &tmp);
            var buffer: [16384]u8 = undefined;
            const plan = try mysql_testing.plan(&storage, session_list_read.changed_ancestors_source, .{
                store.leaf.slice(),            "", "", "", "", "", "", "", @as(?[]const u8, null),
                session_archive.Filter.active,
            }, &buffer);
            errdefer std.debug.print("MySQL plan for the changed-page ancestor batch:\n{s}", .{plan});
            try expectNoScan(plan, &.{ "seen", "tail", "parent", "child" });
            try std.testing.expect(std.mem.indexOf(u8, plan, "PRIMARY") != null);
        }
    }.run);
}

// A page's settings rows and work rows are one statement each over eight Session refs, bound as the Store binds them.
// The IN list holds only bound refs: an IN list holding a UNION made MySQL scan session (see livePageSql). Every
// session row is read through its key, and every probe is keyed on a row's Session ref or its live Operation.
test "MySQL plans a page's settings rows through the Session key, with no base-table scan" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const session_list_read = @import("domain/session_list_read.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const store = try PlanStore.populate(&storage, &tmp);
            const refs = store.page();
            var buffer: [65536]u8 = undefined;
            const plan = try mysql_testing.plan(&storage, session_list_read.list_rows_source, .{ refs[0], refs[1], refs[2], refs[3], refs[4], refs[5], refs[6], refs[7] }, &buffer);
            errdefer std.debug.print("MySQL plan for the page's settings rows:\n{s}", .{plan});
            try expectNoScan(plan, &.{});
            try expectKeyedOn(plan, "session", "session_ref");
            try std.testing.expect(std.mem.indexOf(u8, plan, "turn_session_latest") != null);
        }
    }.run);
}

test "MySQL plans a page's work rows through the Session key and keyed probes" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const report_domain = @import("domain/report.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const store = try PlanStore.populate(&storage, &tmp);
            const refs = store.page();
            var buffer: [131072]u8 = undefined;
            const plan = try mysql_testing.plan(&storage, report_domain.work_rows_source, .{ refs[0], refs[1], refs[2], refs[3], refs[4], refs[5], refs[6], refs[7] }, &buffer);
            errdefer std.debug.print("MySQL plan for the page's work rows:\n{s}", .{plan});
            try expectNoScan(plan, &.{});
            try expectKeyedOn(plan, "work_session", "session_ref");
            try std.testing.expect(std.mem.indexOf(u8, plan, "turn_session_latest") != null);
            try expectKeyedOn(plan, "message_admission", "session_ref=");
            try std.testing.expect(std.mem.indexOf(u8, plan, "session_stop_exclusion") != null);
        }
    }.run);
}

// The creator subtree with its descendants' work is one statement for up to eight roots; unused root slots are empty.
// MySQL materializes the recursive CTE and scans that temporary result; every Session, Turn, Operation, Action and
// Message is a keyed probe.
test "MySQL plans the creator subtree's work through keyed probes" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const session_list_read = @import("domain/session_list_read.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const store = try PlanStore.populate(&storage, &tmp);
            var buffer: [131072]u8 = undefined;
            const plan = try mysql_testing.plan(&storage, session_list_read.descendant_work_source, .{
                store.root.slice(), "",                            "", "", "", "", "", "", @as(?[]const u8, null),
                @as(?[32]u8, null), session_archive.Filter.active,
            }, &buffer);
            errdefer std.debug.print("MySQL plan for the creator subtree's work:\n{s}", .{plan});
            try expectNoScan(plan, &.{ "member", "parent", "descendants" });
            for ([_][]const u8{ "session_creator", "turn_session_latest" }) |index|
                try std.testing.expect(std.mem.indexOf(u8, plan, index) != null);
            try expectKeyedOn(plan, "message_admission", "session_ref=");
        }
    }.run);
}

// Each archiving candidate and each archiving page is planned on MySQL, the pages with literal bounds, so the plan is
// the one the live list reads. A page must not scan session, and its candidate's index must be used. MySQL has no
// partial index: the marker states the `_lead` column.
test "MySQL plans each archiving candidate and page through its index" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const membership = @import("domain/archive_membership.zig");
            const session_list_read = @import("domain/session_list_read.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            _ = try PlanStore.populate(&storage, &tmp);
            const candidates = [_]struct { sql: []const u8, index: []const u8 }{
                .{ .sql = membership.turn_candidates_sql, .index = "turn_outcome_unpositioned" },
                .{ .sql = membership.unaccepted_action_candidates_sql, .index = "action_operation_unaccepted" },
            };
            inline for (candidates) |candidate| {
                var buffer: [16384]u8 = undefined;
                const plan = try mysql_testing.plan(&storage, candidate.sql, .{}, &buffer);
                errdefer std.debug.print("MySQL plan for {s}:\n{s}", .{ candidate.sql, plan });
                try expectNoScan(plan, &.{});
                try std.testing.expect(std.mem.indexOf(u8, plan, candidate.index) != null);
            }
            const window_pages = [_][]const u8{ session_list_read.archived_newest_source, session_list_read.archived_oldest_source };
            inline for (window_pages) |source| {
                var buffer: [16384]u8 = undefined;
                const plan = try mysql_testing.plan(&storage, source, .{@as(u64, 1000)}, &buffer);
                errdefer std.debug.print("MySQL plan for window page {s}:\n{s}", .{ source, plan });
                // No table is scanned: the page ranges over session_tab, and each row's first Message (report.zig's
                // first_admission_join, which the first-candidate read shares) is read through keyed probes of that
                // row's Session: its first Turn by turn_session_latest and its oldest pending Message (`u`) by the Session ref.
                // A first-candidate read keyed on one Session is read whole while MySQL optimizes and shows no probe,
                // so the page is where those probes are planned.
                try expectNoScan(plan, &.{});
                try std.testing.expect(std.mem.indexOf(u8, plan, "session_tab") != null);
                try std.testing.expect(std.mem.indexOf(u8, plan, "turn_session_latest") != null);
                try expectKeyedOn(plan, "u", "session_ref=");
            }
            const pages = [_]struct { source: []const u8, index: []const u8 }{
                .{ .source = session_list_read.live_turn_source, .index = "turn_outcome_unpositioned" },
                .{ .source = session_list_read.live_action_source, .index = "action_operation_unaccepted" },
            };
            inline for (pages) |page| {
                var buffer: [16384]u8 = undefined;
                const plan = try mysql_testing.plan(&storage, page.source, .{ @as(u64, 0), @as(u64, 1000) }, &buffer);
                errdefer std.debug.print("MySQL plan for page {s}:\n{s}", .{ page.source, plan });
                try std.testing.expect(std.mem.indexOf(u8, plan, "Table scan on s") == null);
                try std.testing.expect(std.mem.indexOf(u8, plan, page.index) != null);
            }
        }
    }.run);
}
