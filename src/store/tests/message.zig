//! Message Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const HistoricalView = historical_domain.HistoricalView;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCommits = shared_fixtures.TestingCommits;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingListRow = shared_fixtures.testingListRow;

test "a creating Message with require_model creates nothing without a model" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("composer", "", workspace, "model-a");
            var message: wire_request.MessageCommand = .{ .configuration = settings.configuration, .require_model = true };
            try message.key.set("composer");
            message.text = try testingBytesContent(&tmp, "composer-message", "start here");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;

            storage.served = protocol.routesAll(.unserved);
            const refused = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expectEqual(protocol.MessageRejection.model_capability_unavailable, refused.rejected.code);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            // The saved refusal replays even once a model is available, and the
            // same key without the condition is a different request.
            storage.served = protocol.routesAll(.endpoint);
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}).rejected.replayed);
            var unconditional = message;
            unconditional.require_model = false;
            try std.testing.expect(storage.submitMessageWithModel(&unconditional, null, .{}) == .conflict);

            var accepted = message;
            try accepted.key.set("composer-ready");
            const reply = storage.submitMessageWithModel(&accepted, null, .{});
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "initial Message atomically allocates its Session and replays its original admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("start", "", workspace, "model-a");
            var message: wire_request.MessageCommand = .{ .configuration = settings.configuration };
            try message.key.set("start");
            message.text = try testingBytesContent(&tmp, "initial-message", "assignment\x00雪\n\n");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var first: AcceptedMessage = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const reply = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(reply == .accepted);
                first = reply.accepted;
                try std.testing.expect(protocol.validSessionId(first.session.slice()));
                const observed = try store_testing.observeCommandForTesting(&storage, "start");
                try std.testing.expect(observed.target.eql(first.session.slice()));
                try std.testing.expectEqual(first.admission_id, observed.kind.message.?.queue.?.admission_id);
                try std.testing.expectError(error.ResultNotReady, storage.commandResult("start"));
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(first.session.slice())).pending_messages);
                var changed = message;
                changed.configuration.?.model.value = .{};
                try changed.configuration.?.model.value.set("model-b");
                try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                var refused = message;
                try refused.key.set("invalid-initial-settings");
                refused.configuration.?.workspace.value = .{};
                const rejected = storage.submitMessageWithModel(&refused, null, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.MessageRejection.invalid_workspace, rejected.rejected.code);
                try std.testing.expect(storage.submitMessageWithModel(&refused, null, .{}).rejected.replayed);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const replay = storage.submitMessageWithModel(&message, null, .{}).accepted;
                try std.testing.expect(replay.replayed);
                try std.testing.expectEqual(first.admission_id, replay.admission_id);
                try std.testing.expectEqualStrings(first.session.slice(), replay.session.slice());
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
                var failed = message;
                try failed.key.set("failed-start-commit");
                try std.testing.expect(storage.submitMessageWithModel(&failed, null, .{ .before_commit = true }) == .infrastructure_failure);
                try storage.close();
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                try std.testing.expectEqual(.absent, (try store_testing.observeCommandForTesting(&storage, "failed-start-commit")).status);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            }
        }
    }.run);
}

test "message rejections replay before current Session checks without retained input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Fix entropy so a real allocation makes the formerly unknown target live.
            // Replay must still return the original rejection, not re-run admission.
            const Entropy = struct {
                fn random(_: ?*anyopaque, bytes: []u8) std.Io.RandomSecureError!void {
                    @memset(bytes, 0);
                }
            };
            var vtable = std.testing.io.vtable.*;
            vtable.randomSecure = Entropy.random;
            var io = std.testing.io;
            io.vtable = &vtable;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, io);
            defer storage.close() catch unreachable;

            const text = "rejected input";
            const file = try tmp.dir.createFile(std.testing.io, "rejected-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("rejected-message", "000000", file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            const rejected = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, rejected.rejected.code);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure-later", "", workspace, "model-a");
            const configured = try storage.configure(&configuration, .{});
            try std.testing.expect(configured == .accepted);
            try std.testing.expectEqualStrings(message.session.slice(), configured.accepted.session.slice());
            const replay = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, replay.rejected.code);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &replay.rejected.content.digest);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(configured.accepted.session.slice())).pending_messages);

            const observed = try store_testing.observeCommandForTesting(&storage, "rejected-message");
            try std.testing.expect(observed.status == .rejected);
            try std.testing.expect(observed.kind.message == null);
        }
    }.run);
}

test "a peer sender is resolved from its Action handle and exact replays survive revocation" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const sender_id = try configureTestSession(&storage, "configure-sender");
            const sender = sender_id.slice();
            // Pages retain the complete allocated identity, not a display alias.
            _ = try configureTestSession(&storage, "configure-neighbour");
            const allocated_session_1 = try configureTestSession(&storage, "configure-receiver");
            var tools: wire_request.ConfigureCommand = .{};
            try tools.key.set("sender-tools");
            try tools.session.set(sender);
            tools.configuration.tools = try .of(&.{"bash"});
            tools.configuration.permission_mode.state = .value;
            try tools.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "sender-seed", "sender-seed", sender, "send a report");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "sender-calls");
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            const handle = input.sender_handle;
            var own_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
            try own_ref.set(sender);
            const sender_end = (try store_core.activityPageForTesting(&storage, .{ .session = own_ref })).end;
            const Send = struct {
                fn make(dir: std.Io.Dir, store_id: []const u8, key: []const u8, target: []const u8, from: ?[]const u8, text: []const u8) !wire_request.MessageCommand {
                    const file = try dir.createFile(std.testing.io, key, .{ .read = true });
                    try file.writeStreamingAll(std.testing.io, text);
                    try file.sync(std.testing.io);
                    var command = try completeMessage(key, target, file, text);
                    if (from) |ref| {
                        command.sender = .{};
                        try command.sender.?.store.set(store_id);
                        try command.sender.?.session.set(ref);
                    }
                    return command;
                }
            };

            var sent = try Send.make(tmp.dir, storage.storeId(), "peer-send", allocated_session_1.slice(), sender, "look at this\nsecond line");
            sent.sender_handle = handle;
            defer sent.removeTemporaryContent(std.testing.io) catch unreachable;
            var commits: TestingCommits = .{};
            const accepted = storage.submitMessageWithModel(&sent, commits.callback(), .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(storage.submitMessageWithModel(&sent, commits.callback(), .{}).accepted.replayed);
            try std.testing.expectEqual(@as(usize, 1), commits.count);
            try std.testing.expect(commits.calls[0].from_peer);
            try std.testing.expectEqual(accepted.accepted.admission_id, commits.calls[0].admission_id);
            // The sender is part of the request: the same key without it conflicts.
            var anonymous = try Send.make(tmp.dir, storage.storeId(), "peer-send-anonymous", allocated_session_1.slice(), null, "look at this\nsecond line");
            defer anonymous.removeTemporaryContent(std.testing.io) catch unreachable;
            try anonymous.key.set("peer-send");
            try std.testing.expect(storage.submitMessageWithModel(&anonymous, null, .{}) == .conflict);

            var refused = try Send.make(tmp.dir, storage.storeId(), "peer-refused", "absent", sender, "lost");
            refused.sender_handle = handle;
            defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, storage.submitMessageWithModel(&refused, commits.callback(), .{}).rejected.code);
            // A rejected Message installs nothing.
            try std.testing.expectEqual(@as(usize, 1), commits.count);

            var forged = try Send.make(tmp.dir, storage.storeId(), "peer-forged", allocated_session_1.slice(), "f0rged", "forged");
            defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&forged, null, .{}).rejected.code);
            const forged_replay = storage.submitMessageWithModel(&forged, null, .{});
            try std.testing.expect(forged_replay.rejected.replayed and forged_replay.rejected.code == .invalid_sender_handle);
            // Every invalid binding must leave both receiver admission and the
            // falsely claimed sender's Activity untouched.
            for (0..5) |variant| {
                var invalid = sent;
                var key_buffer: [32]u8 = undefined;
                try invalid.key.set(try std.fmt.bufPrint(&key_buffer, "invalid-binding-{d}", .{variant}));
                switch (variant) {
                    0 => invalid.sender_handle = null,
                    1 => try invalid.sender_handle.?.set(""),
                    2 => try invalid.sender_handle.?.set("00000000000000000000000000000000"),
                    3 => try invalid.sender.?.session.set(allocated_session_1.slice()),
                    4 => invalid.sender = null,
                    else => unreachable,
                }
                try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&invalid, null, .{}).rejected.code);
            }
            var changed_handle = sent;
            changed_handle.sender_handle = null;
            try std.testing.expect(storage.submitMessageWithModel(&changed_handle, null, .{}) == .conflict);
            // An invalid target is refused first, whichever sender: an unknown one
            // claims no sequence position, and the Store stays open.
            for ([_]struct { key: []const u8, from: []const u8 }{
                .{ .key = "peer-empty-forged", .from = "f0rged" },
                .{ .key = "peer-empty-known", .from = sender },
            }) |case| {
                var empty = try Send.make(tmp.dir, storage.storeId(), case.key, "", case.from, "nowhere");
                if (std.mem.eql(u8, case.from, sender)) empty.sender_handle = handle;
                defer empty.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expectEqual(protocol.MessageRejection.invalid_session_reference, storage.submitMessageWithModel(&empty, null, .{}).rejected.code);
            }
            // An unknown sender has no sequence: only the known sender's refusals are kept.
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection", .{}));
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(allocated_session_1.slice())).pending_messages);

            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try session.set(allocated_session_1.slice());
            const received = try store_core.activityPageForTesting(&storage, .{ .session = session });
            try std.testing.expectEqual(@as(usize, 1), received.count);
            const peer = received.items[0].value.received.sender.?;
            try std.testing.expectEqualStrings(sender, peer.session.slice());
            {
                // The receiver's row names that peer as its starter; no person has
                // messaged it.
                var listed = try testingListRow(&storage, &tmp, allocated_session_1.slice());
                defer listed.deinit();
                try std.testing.expectEqualStrings(sender, listed.get(&.{ "first_message", "sender", "session" }).string);
                try std.testing.expect(listed.get(&.{ "peers", "from_person_at" }) == .null);
            }

            try session.set(sender);
            try store_testing.exec(&storage, "UPDATE sent_rejection SET rejected_at=200+sender_position", .{});
            const own = try store_core.activityPageForTesting(&storage, .{ .session = session, .position = sender_end });
            try std.testing.expectEqual(@as(usize, 3), own.count);
            try std.testing.expectEqualStrings("invalid_session_reference", own.items[2].value.send_failed.code.slice());
            try std.testing.expect(own.items[2].value.send_failed.target == null);
            const out = own.items[0].value.sent;
            try std.testing.expectEqual(accepted.accepted.admission_id, out.admission);
            // One Message's two rows share its admission time; a refused send is
            // dated by its refusal.
            try std.testing.expectEqual(out.admitted_at, own.items[0].at);
            try std.testing.expectEqual(received.items[0].at, own.items[0].at);
            for (own.items[1..3]) |failure| try std.testing.expectEqual(200 + failure.position, failure.at);
            try std.testing.expectEqualStrings(allocated_session_1.slice(), out.target.session.slice());
            const failed = own.items[1].value.send_failed;
            try std.testing.expectEqualStrings("absent", failed.target.?.session.slice());
            try std.testing.expectEqualStrings("unknown_session", failed.code.slice());
            try std.testing.expect(own.items[0].position < own.items[1].position);
            {
                // Each peer row names the peer by its label as it is now; a peer
                // without one, or one the Store never held, has none.
                try std.testing.expectEqual(@as(usize, 0), out.target.label.len);
                try std.testing.expectEqual(@as(usize, 0), failed.target.?.label.len);
                try store_testing.exec(&storage, "UPDATE session SET label='Review the WAL' WHERE session_ref=?1", .{allocated_session_1.slice()});
                const renamed = try store_core.activityPageForTesting(&storage, .{ .session = session, .position = sender_end });
                try std.testing.expectEqualStrings("Review the WAL", renamed.items[0].value.sent.target.label.slice());
                try std.testing.expectEqual(@as(usize, 0), renamed.items[1].value.send_failed.target.?.label.len);
                try store_testing.exec(&storage, "UPDATE session SET label='Lead' WHERE session_ref=?1", .{sender});
                var receiver: protocol.Bounded(protocol.max_session_bytes) = .{};
                try receiver.set(allocated_session_1.slice());
                const named = try store_core.activityPageForTesting(&storage, .{ .session = receiver });
                try std.testing.expectEqualStrings("Lead", named.items[0].value.received.sender.?.label.slice());
            }
            try storage.revokeActionSender(action);
            try std.testing.expect(storage.submitMessageWithModel(&sent, null, .{}).accepted.replayed);
            var stale = sent;
            try stale.key.set("stale-handle");
            try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&stale, null, .{}).rejected.code);
            // The sent row's bytes are the Message's, read through the sender.
            var reader: ContentReader = undefined;
            reader.open(try storage.openActivityContent(&.{ .session = session, .position = own.items[0].position }));
            reader.close();

            // The model's historical view carries the recorded sender, not text.
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(try admitted.permit.consume(), &view);
            defer view.close();
            const entry = (try view.nextEntry(0)).?;
            try std.testing.expect(entry.kind == .user);
            try std.testing.expectEqualStrings(sender, entry.sender.?.slice());
        }
    }.run);
}

test "refused peer creation activity keeps invalid targets absent" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("creation-refusal-sender", "", workspace, "model-a");
            configuration.configuration.tools = try .of(&.{"bash"});
            const configured = try storage.configure(&configuration, .{});
            try std.testing.expect(configured == .accepted);
            const sender = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "creation-refusal-seed", "creation-refusal-seed", sender.slice(), "start another Session");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "creation-refusal-calls");
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            const before = try store_core.activityPageForTesting(&storage, .{ .session = sender });

            const text = "work that must not be admitted";
            const file = try tmp.dir.createFile(std.testing.io, "creation-refusal-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("creation-refusal-message", "", file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var creation = try completeConfiguration("unused-creation-key", "", workspace, "gpt-6.1-sol");
            creation.configuration.reasoning_effort.state = .value;
            try creation.configuration.reasoning_effort.value.set("none");
            message.configuration = creation.configuration;
            message.sender = .{};
            try message.sender.?.store.set(storage.storeId());
            message.sender.?.session = sender;
            message.sender_handle = input.sender_handle;
            var commits: TestingCommits = .{};
            const refused = storage.submitMessageWithModel(&message, commits.callback(), .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expect(!refused.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.unsupported_reasoning_effort, refused.rejected.code);
            const replay = storage.submitMessageWithModel(&message, commits.callback(), .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(refused.rejected.code, replay.rejected.code);
            try std.testing.expectEqualSlices(u8, &refused.rejected.content.digest, &replay.rejected.content.digest);
            try std.testing.expectEqual(@as(usize, 0), commits.count);

            // A refusal records its answer and one sender position, not a child,
            // configuration revision or first-Message admission.
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1 AND target='' AND kind=2 AND accepted=0 AND code='unsupported_reasoning_effort'", .{message.key.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection WHERE command_key=?1 AND sender_session_ref=?2", .{ message.key.slice(), sender.slice() }));
            const observed = try store_testing.observeCommandForTesting(&storage, message.key.slice());
            try std.testing.expect(observed.status == .rejected);
            try std.testing.expect(observed.kind.message == null);

            const page = try store_core.activityPageForTesting(&storage, .{ .session = sender, .position = before.end });
            try std.testing.expectEqual(before.end + 1, page.end);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            try std.testing.expect(page.items[0].value == .send_failed);
            const item = page.items[0];
            try std.testing.expectEqual(before.end + 1, item.position);
            try std.testing.expectEqual(@as(u64, 0), item.ordinal);
            try std.testing.expectEqual(page.items[0].at, item.at);
            try std.testing.expectEqualStrings(message.key.slice(), item.value.send_failed.key.slice());
            try std.testing.expectEqualStrings("unsupported_reasoning_effort", item.value.send_failed.code.slice());
            try std.testing.expect(item.value.send_failed.target == null);

            const PageRead = struct {
                const Page = struct {
                    facts: protocol.ActivityFacts,
                    request: protocol.ActivityPage,

                    fn continuation(self: *const @This()) ?protocol.ActivityPage {
                        if (!self.facts.more) return null;
                        const last = self.facts.items[self.facts.count - 1];
                        var next = self.request;
                        next.end = self.facts.end;
                        next.position = last.position;
                        next.ordinal = last.ordinal;
                        return next;
                    }
                };

                fn read(store: *Store, session: protocol.Bounded(protocol.max_session_bytes), cursor: protocol.ActivityPage) !Page {
                    var request = cursor;
                    request.session = session;
                    return .{ .facts = try store_core.activityPageForTesting(store, request), .request = request };
                }
            };
            // These spellings are independent invalid examples, including
            // six-byte strings that fail grammar rather than merely width.
            const malformed = [_][]const u8{ "", "short", "k7m2qi", "K7m2qx", "k7\x00mqx", "雪雪", "1234567" };
            const invalid_count = malformed.len + protocol.max_session_bytes + 1;
            var times: [invalid_count + 3]u64 = undefined;
            times[0] = item.at;
            const wide: [protocol.max_session_bytes]u8 = @splat('X');
            for (0..invalid_count) |index| {
                // Every supported width 0..128 is covered; uppercase X is
                // independently invalid even at the otherwise valid width 6.
                const attempted = if (index < malformed.len) malformed[index] else wide[0 .. index - malformed.len];
                var invalid = message;
                invalid.configuration = null;
                try invalid.session.set(attempted);
                var key: [40]u8 = undefined;
                try invalid.key.set(try std.fmt.bufPrint(&key, "refused-address-{d}", .{index}));
                const digest = invalid.semanticDigest();
                const answer = storage.submitMessageWithModel(&invalid, commits.callback(), .{});
                try std.testing.expect(answer == .rejected);
                try std.testing.expect(!answer.rejected.replayed);
                try std.testing.expectEqual(protocol.MessageRejection.invalid_session_reference, answer.rejected.code);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1 AND target=?2 AND input_digest=?3 AND kind=2 AND accepted=0 AND code='invalid_session_reference' AND created=0 AND revision=0", .{ invalid.key.slice(), attempted, store_testing.Blob{ .bytes = &digest } }));
                const position = before.end + 1 + index;
                const result = try PageRead.read(&storage, sender, .{ .position = position });
                try std.testing.expectEqual(position + 1, result.facts.end);
                try std.testing.expectEqual(@as(usize, 1), result.facts.count);
                const failure = result.facts.items[0];
                try std.testing.expectEqual(position + 1, failure.position);
                try std.testing.expectEqual(@as(u64, 0), failure.ordinal);
                try std.testing.expect(failure.at > 0);
                try std.testing.expectEqualStrings(invalid.key.slice(), failure.value.send_failed.key.slice());
                try std.testing.expectEqualStrings("invalid_session_reference", failure.value.send_failed.code.slice());
                try std.testing.expect(failure.value.send_failed.target == null);
                times[index + 1] = failure.at;
            }
            try std.testing.expectEqual(@as(usize, 0), commits.count);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));

            var unknown = message;
            unknown.configuration = null;
            try unknown.key.set("refused-canonical-unknown");
            try unknown.session.set("absent");
            const unknown_answer = storage.submitMessageWithModel(&unknown, commits.callback(), .{});
            try std.testing.expect(unknown_answer == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, unknown_answer.rejected.code);
            const unknown_page = try PageRead.read(&storage, sender, .{ .position = before.end + 1 + invalid_count });
            try std.testing.expectEqual(@as(usize, 1), unknown_page.facts.count);
            const unknown_failure = unknown_page.facts.items[0];
            try std.testing.expectEqualStrings(unknown.key.slice(), unknown_failure.value.send_failed.key.slice());
            try std.testing.expectEqualStrings("unknown_session", unknown_failure.value.send_failed.code.slice());
            try std.testing.expectEqualStrings("absent", unknown_failure.value.send_failed.target.?.session.slice());
            try std.testing.expectEqual(@as(usize, 0), unknown_failure.value.send_failed.target.?.label.len);
            times[invalid_count + 1] = unknown_failure.at;

            var accepted = message;
            try accepted.key.set("accepted-peer-creation");
            try accepted.configuration.?.reasoning_effort.value.set("low");
            const admitted = storage.submitMessageWithModel(&accepted, commits.callback(), .{});
            try std.testing.expect(admitted == .accepted);
            try std.testing.expect(protocol.validSessionId(admitted.accepted.session.slice()));
            try std.testing.expect(!admitted.accepted.session.eql(sender.slice()));
            try std.testing.expectEqual(@as(usize, 1), commits.count);
            try std.testing.expect(commits.calls[0].from_peer);
            const sent_page = try PageRead.read(&storage, sender, .{ .position = unknown_page.facts.end });
            try std.testing.expectEqual(@as(usize, 1), sent_page.facts.count);
            const sent = sent_page.facts.items[0];
            try std.testing.expectEqualStrings(admitted.accepted.session.slice(), sent.value.sent.target.session.slice());
            try std.testing.expectEqual(admitted.accepted.admission_id, sent.value.sent.admission);
            times[invalid_count + 2] = sent.at;
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));

            const end = sent_page.facts.end;
            try storage.revokeActionSender(action);
            const revoked_replay = storage.submitMessageWithModel(&message, commits.callback(), .{});
            try std.testing.expect(revoked_replay == .rejected);
            try std.testing.expect(revoked_replay.rejected.replayed);
            try std.testing.expectEqual(refused.rejected.code, revoked_replay.rejected.code);
            try std.testing.expectEqualSlices(u8, &refused.rejected.content.digest, &revoked_replay.rejected.content.digest);
            var changed = message;
            try changed.configuration.?.reasoning_effort.value.set("low");
            try std.testing.expect(storage.submitMessageWithModel(&changed, commits.callback(), .{}) == .conflict);
            const original_digest = message.semanticDigest();
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1 AND target='' AND input_digest=?2 AND kind=2 AND accepted=0 AND code='unsupported_reasoning_effort' AND created=0 AND revision=0", .{ message.key.slice(), store_testing.Blob{ .bytes = &original_digest } }));
            try std.testing.expectEqual(@as(u64, invalid_count + 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection", .{}));
            const unchanged = try PageRead.read(&storage, sender, .{ .position = end });
            try std.testing.expectEqual(end, unchanged.facts.end);
            try std.testing.expectEqual(@as(usize, 0), unchanged.facts.count);
            try std.testing.expectEqual(@as(usize, 1), commits.count);

            const filtered = try PageRead.read(&storage, sender, .{ .end = end, .position = before.end, .kinds = .initMany(&.{.send_failed}), .limit = 1 });
            try std.testing.expectEqual(end, filtered.facts.end);
            try std.testing.expectEqual(@as(usize, 1), filtered.facts.count);
            try std.testing.expectEqualStrings(message.key.slice(), filtered.facts.items[0].value.send_failed.key.slice());
            try std.testing.expect(filtered.facts.items[0].value.send_failed.target == null);
            try std.testing.expect(filtered.continuation() != null);
            const filtered_last = try PageRead.read(&storage, sender, .{ .end = end, .position = end - 2, .kinds = .initMany(&.{.send_failed}), .limit = 1 });
            try std.testing.expectEqual(@as(usize, 1), filtered_last.facts.count);
            try std.testing.expectEqualStrings(unknown.key.slice(), filtered_last.facts.items[0].value.send_failed.key.slice());
            try std.testing.expectEqualStrings("absent", filtered_last.facts.items[0].value.send_failed.target.?.session.slice());
            try std.testing.expect(!filtered_last.facts.more);

            // Fixed-end pagination must retain every refusal between the
            // sender's older work and the accepted creation, in both directions.
            for ([_]@FieldType(protocol.ActivityPage, "direction"){ .forward, .backward }) |direction| {
                var cursor: protocol.ActivityPage = .{ .end = end, .position = if (direction == .forward) before.end else 0, .direction = direction };
                var seen: usize = 0;
                while (seen < times.len) {
                    cursor.limit = @intCast(@min(3, times.len - seen));
                    const traversal = try PageRead.read(&storage, sender, cursor);
                    try std.testing.expectEqual(end, traversal.facts.end);
                    try std.testing.expectEqual(@as(usize, cursor.limit), traversal.facts.count);
                    for (traversal.facts.items[0..traversal.facts.count], 0..) |entry, offset| {
                        const index = if (direction == .forward) seen + offset else times.len - 1 - seen - offset;
                        try std.testing.expectEqual(before.end + 1 + index, entry.position);
                        try std.testing.expectEqual(@as(u64, 0), entry.ordinal);
                        try std.testing.expectEqual(times[index], entry.at);
                        if (index == times.len - 1) {
                            try std.testing.expectEqualStrings(admitted.accepted.session.slice(), entry.value.sent.target.session.slice());
                        } else if (index == times.len - 2) {
                            try std.testing.expectEqualStrings(unknown.key.slice(), entry.value.send_failed.key.slice());
                            try std.testing.expectEqualStrings("unknown_session", entry.value.send_failed.code.slice());
                            try std.testing.expectEqualStrings("absent", entry.value.send_failed.target.?.session.slice());
                        } else {
                            var key: [40]u8 = undefined;
                            const expected_key = if (index == 0) message.key.slice() else try std.fmt.bufPrint(&key, "refused-address-{d}", .{index - 1});
                            try std.testing.expectEqualStrings(expected_key, entry.value.send_failed.key.slice());
                            try std.testing.expectEqualStrings(if (index == 0) "unsupported_reasoning_effort" else "invalid_session_reference", entry.value.send_failed.code.slice());
                            try std.testing.expect(entry.value.send_failed.target == null);
                        }
                    }
                    seen += traversal.facts.count;
                    if (seen < times.len) cursor = traversal.continuation().?;
                }
                try std.testing.expectEqual(times.len, seen);
            }
        }
    }.run);
}

test "message observation validates accepted admission references independently" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { session, content }{ .session, .content };
            for (corruptions) |corruption| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;

                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var primary_configuration = try completeConfiguration(
                    "reference-primary-configure",
                    "",
                    workspace,
                    "model-a",
                );
                const created_session_0_reply = try storage.configure(&primary_configuration, .{});
                try std.testing.expect(created_session_0_reply == .accepted);
                const created_session_0 = created_session_0_reply.accepted.session;
                var other_configuration = try completeConfiguration(
                    "reference-other-configure",
                    "",
                    workspace,
                    "model-a",
                );
                const other_reply = try storage.configure(&other_configuration, .{});
                try std.testing.expect(other_reply == .accepted);
                const other_session = other_reply.accepted.session;

                const primary_file = try tmp.dir.createFile(std.testing.io, "reference-primary-message", .{ .read = true });
                try primary_file.writeStreamingAll(std.testing.io, "primary input");
                try primary_file.sync(std.testing.io);
                var primary_message = try completeMessage(
                    "reference-primary-message",
                    created_session_0.slice(),
                    primary_file,
                    "primary input",
                );
                defer primary_message.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&primary_message, null, .{}) == .accepted);

                const other_file = try tmp.dir.createFile(std.testing.io, "reference-other-message", .{ .read = true });
                try other_file.writeStreamingAll(std.testing.io, "other input");
                try other_file.sync(std.testing.io);
                var other_message = try completeMessage(
                    "reference-other-message",
                    other_session.slice(),
                    other_file,
                    "other input",
                );
                defer other_message.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&other_message, null, .{}) == .accepted);

                switch (corruption) {
                    .session => try store_testing.exec(&storage, "UPDATE message_admission SET session_ref=?1 " ++
                        "WHERE command_key='reference-primary-message'", .{other_session.slice()}),
                    .content => try store_testing.exec(&storage, "UPDATE message_admission SET content_id=?1 " ++
                        "WHERE command_key='reference-primary-message'", .{try store_testing.queryU64(
                        &storage,
                        "SELECT content_id FROM message_admission WHERE command_key='reference-other-message'",
                        .{},
                    )}),
                }
                try std.testing.expectError(
                    error.CorruptStore,
                    store_testing.observeCommandForTesting(&storage, "reference-primary-message"),
                );
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "message observation rejects an answer attached to processing durable facts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration(
                "corrupt-observation-configure",
                "",
                workspace,
                "model-a",
            );
            const created_session_0_reply = try storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            const file = try tmp.dir.createFile(std.testing.io, "corrupt-observation-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "input");
            try file.sync(std.testing.io);
            var message = try completeMessage(
                "corrupt-observation-message",
                created_session_0.slice(),
                file,
                "input",
            );
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try store_testing.exec(&storage, "UPDATE turn SET outcome_content_id=(" ++
                "SELECT content_id FROM message_admission WHERE command_key='corrupt-observation-message')", .{});

            try std.testing.expectError(
                error.CorruptStore,
                store_testing.observeCommandForTesting(&storage, "corrupt-observation-message"),
            );
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "message conflicts and failed commits cannot create another admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure", "", workspace, "model-a");
            const created_session_0_reply = try storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            const text = "one admission";
            const file = try tmp.dir.createFile(std.testing.io, "message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("message", created_session_0.slice(), file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var commits: TestingCommits = .{};
            try std.testing.expect(storage.submitMessageWithModel(&message, commits.callback(), .{ .before_commit = true }) == .infrastructure_failure);
            // A Message that did not commit installs nothing.
            try std.testing.expectEqual(@as(usize, 0), commits.count);
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "message")).status == .absent);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            const accepted = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(accepted == .accepted);

            var retargeted = message;
            retargeted.text.file = null;
            try retargeted.session.set("0ther0");
            try std.testing.expect(storage.submitMessageWithModel(&retargeted, null, .{}) == .conflict);
            var changed = message;
            changed.text.file = null;
            changed.text.length += 1;
            try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
            var changed_kind = try completeConfiguration("message", created_session_0.slice(), workspace, "model-a");
            try std.testing.expect(try storage.configure(&changed_kind, .{}) == .conflict);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            try storage.close();
        }
    }.run);
}

test "failed message import rolls back content command and admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure", "", workspace, "model-a");
            const created_session_0_reply = try storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            const text = "larger than an empty import";
            const file = try tmp.dir.createFile(std.testing.io, "import-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("message-import", created_session_0.slice(), file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{ .content_import = true }) == .infrastructure_failure);
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "message-import")).status == .absent);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        }
    }.run);
}
