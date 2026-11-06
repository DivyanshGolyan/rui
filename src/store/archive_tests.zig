const std = @import("std");
const protocol = @import("../protocol.zig");
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
    return .{ .session = session, .binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding };
}

fn message(tmp: *std.testing.TmpDir, key: []const u8, session: []const u8) !protocol.MessageCommand {
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
            var input: action.BashExecutionInput = undefined;
            try storage.readBashExecutionInput(sender.binding, &input);
            var peer = try message(&tmp, "archive-peer-blocked", receiver.session.slice());
            defer peer.removeTemporaryContent(std.testing.io) catch unreachable;
            peer.sender = .{};
            try peer.sender.?.store.set(storage.selector.slice());
            try peer.sender.?.session.set(sender.session.slice());
            peer.sender_handle = input.sender_handle;
            const peer_blocked = storage.submitMessageWithModel(&peer, null, .{});
            try std.testing.expect(peer_blocked == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.session_archiving, peer_blocked.rejected.code);
            try std.testing.expectEqual(action.ActionSettlement.session_stop, try storage.settleActionAttempt(receiver.binding, .cancelled, "Bash stopped.", .{}));
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
            const sender = storage.configure(&config, .{}).accepted.session;
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
            const blocked = (try storage.nextCoreWork() orelse return error.ExpectedBlockedCoreWork).action;
            try std.testing.expectEqual(@as(@import("domain/command.zig").AgentDelivery, .failed), try storage.deliverAgentMessage(blocked.binding, receiver.session.slice(), "blocked", .{}));
            try expectState(&storage, receiver.session.slice(), .archiving);
            try std.testing.expectEqual(action.ActionSettlement.session_stop, try storage.settleActionAttempt(receiver.binding, .cancelled, "Bash stopped.", .{}));
            try expectState(&storage, receiver.session.slice(), .archived);
            const fresh = (try storage.nextCoreWork() orelse return error.ExpectedFreshCoreWork).action;
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
            try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
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
            try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
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
    const parent = storage.configure(&create, .{}).accepted.session;
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
    const start = (try storage.nextCoreWork() orelse return error.ExpectedStartAgent).action;
    var spec = try fixtures.testingAgentSpec(&.{"bash"}, "bypass");
    try std.testing.expectEqual(@as(@import("domain/command.zig").AgentStart, .started), try storage.startAgent(start.binding, parent.slice(), "child task", true, &spec, null, .{}));
    const listing = try fixtures.TestingListing.read(storage, tmp, .{ .archive = .all });
    try std.testing.expectEqual(@as(usize, 2), listing.count);
    var child: protocol.Bounded(protocol.max_session_bytes) = .{};
    try child.set(&listing.references[1]);
    return .{ .parent = parent, .child = child };
}

fn drainChildStop(storage: *Store) !void {
    const stop = (try storage.nextCoreWork() orelse return error.ExpectedChildStop).stop;
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
            const stop = (try storage.nextCoreWork() orelse return error.ExpectedChildStop).stop;
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
                    child_action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
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
                    try std.testing.expectEqual(action.ActionSettlement.session_stop, try storage.settleActionAttempt(child_action.?, .cancelled, "Bash stopped.", .{}));
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
                    const forward = (try storage.nextCoreWork() orelse return error.ExpectedEndingForward).forward;
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
