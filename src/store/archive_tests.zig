const std = @import("std");
const protocol = @import("../protocol.zig");
const wire_request = @import("../wire_request.zig");
const store_core = @import("Store.zig");
const Store = store_core.Store;
const testing = @import("testing.zig");
const fixtures = @import("tests.zig");
const action = @import("domain/action.zig");

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
        try storage.readSessionList(&request, &walk);
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

const WindowRow = struct { reference: [6]u8, key: u64 };

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
        self.rows[self.count] = .{ .reference = archived.reference[0..6].*, .key = archived.archive_seq };
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
    try storage.readSessionList(&request, visitor);
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

// Each archiving candidate and each archiving page is planned on MySQL. The pages are planned with literal
// bounds, so the plan is the one the live list reads. A page must not scan session, and its candidate's index
// must be used. MySQL has no partial index: the marker states the `_lead` column. Runs only when MySQL is
// live (forEachEngine skips it otherwise).
fn bindLiterals(comptime sql: []const u8, comptime values: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest: []const u8 = sql;
        for (values) |value| {
            const at = std.mem.indexOfScalar(u8, rest, '?') orelse @compileError("bindLiterals: missing parameter");
            out = out ++ rest[0..at] ++ value;
            rest = rest[at + 1 ..];
        }
        return out ++ rest;
    }
}

test "MySQL plans each archiving candidate and page through its index" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            if (case.engine != .mysql) return;
            const rsql = @import("rsql.zig");
            const membership = @import("domain/archive_membership.zig");
            const session_list_read = @import("domain/session_list_read.zig");
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const candidates = [_]struct { sql: []const u8, mysql: []const u8, index: []const u8 }{
                .{ .sql = membership.turn_candidates_sql, .mysql = comptime rsql.sentTemplate(membership.turn_candidates_sql).prepared(), .index = "turn_outcome_unpositioned" },
                .{ .sql = membership.unaccepted_action_candidates_sql, .mysql = comptime rsql.sentTemplate(membership.unaccepted_action_candidates_sql).prepared(), .index = "action_operation_unaccepted" },
            };
            for (candidates) |candidate| {
                var buffer: [16384]u8 = undefined;
                const plan = try mysql_testing.planText(&storage, candidate.mysql, &buffer);
                errdefer std.debug.print("MySQL plan for {s}:\n{s}", .{ candidate.sql, plan });
                try std.testing.expect(std.mem.indexOf(u8, plan, "Table scan") == null);
                try std.testing.expect(std.mem.indexOf(u8, plan, candidate.index) != null);
            }
            const pages = [_]struct { source: []const u8, index: []const u8 }{
                .{ .source = session_list_read.live_turn_source, .index = "turn_outcome_unpositioned" },
                .{ .source = session_list_read.live_action_source, .index = "action_operation_unaccepted" },
            };
            inline for (pages) |page| {
                const literal = comptime bindLiterals(rsql.sentTemplate(page.source).prepared(), &.{ "0", "1000" });
                var buffer: [16384]u8 = undefined;
                const plan = try mysql_testing.planText(&storage, literal, &buffer);
                errdefer std.debug.print("MySQL plan for page {s}:\n{s}", .{ page.source, plan });
                try std.testing.expect(std.mem.indexOf(u8, plan, "Table scan on s") == null);
                try std.testing.expect(std.mem.indexOf(u8, plan, page.index) != null);
            }
        }
    }.run);
}
