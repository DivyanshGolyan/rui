const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const content_domain = @import("../domain/content.zig");
const content_value = @import("../../content_value.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const TestingPage = store_testing.TestingPage;
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
            const expected_input: content_value.Value = .{ .text = .{ .length = message.text.length, .digest = message.text.digest } };
            var first: AcceptedMessage = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const reply = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(reply == .accepted);
                first = reply.accepted;
                try std.testing.expectEqualDeep(expected_input, first.content);
                try std.testing.expect(protocol.validSessionId(first.session.slice()));
                const observed = try store_testing.observeCommandForTesting(&storage, "start");
                try std.testing.expect(observed.target.eql(first.session.slice()));
                try std.testing.expectEqual(first.admission_id, observed.kind.message.?.queue.?.admission_id);
                try std.testing.expectEqualDeep(expected_input, observed.kind.message.?.content);
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
                try std.testing.expectEqualDeep(expected_input, replay.content);
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
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
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
            var anonymous = try Send.make(tmp.dir, storage.storeId(), "peer-send-anonymous", allocated_session_1.slice(), null, "look at this\nsecond line");
            defer anonymous.removeTemporaryContent(std.testing.io) catch unreachable;
            try anonymous.key.set("peer-send");
            try std.testing.expect(storage.submitMessageWithModel(&anonymous, null, .{}) == .conflict);

            var refused = try Send.make(tmp.dir, storage.storeId(), "peer-refused", "absent", sender, "lost");
            refused.sender_handle = handle;
            defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, storage.submitMessageWithModel(&refused, commits.callback(), .{}).rejected.code);
            try std.testing.expectEqual(@as(usize, 1), commits.count);

            var forged = try Send.make(tmp.dir, storage.storeId(), "peer-forged", allocated_session_1.slice(), "f0rged", "forged");
            defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&forged, null, .{}).rejected.code);
            const forged_replay = storage.submitMessageWithModel(&forged, null, .{});
            try std.testing.expect(forged_replay.rejected.replayed and forged_replay.rejected.code == .invalid_sender_handle);
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
            for ([_]struct { key: []const u8, from: []const u8 }{
                .{ .key = "peer-empty-forged", .from = "f0rged" },
                .{ .key = "peer-empty-known", .from = sender },
            }) |case| {
                var empty = try Send.make(tmp.dir, storage.storeId(), case.key, "", case.from, "nowhere");
                if (std.mem.eql(u8, case.from, sender)) empty.sender_handle = handle;
                defer empty.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expectEqual(protocol.MessageRejection.invalid_session_reference, storage.submitMessageWithModel(&empty, null, .{}).rejected.code);
            }
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection", .{}));
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(allocated_session_1.slice())).pending_messages);

            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try session.set(allocated_session_1.slice());
            const received = try store_core.activityPageForTesting(&storage, .{ .session = session });
            try std.testing.expectEqual(@as(usize, 1), received.count);
            const peer = received.items[0].value.received.sender.?;
            try std.testing.expectEqualStrings(sender, peer.session.slice());
            {
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
            try std.testing.expectEqual(out.admitted_at, own.items[0].at);
            try std.testing.expectEqual(received.items[0].at, own.items[0].at);
            for (own.items[1..3]) |failure| try std.testing.expectEqual(200 + failure.position, failure.at);
            try std.testing.expectEqualStrings(allocated_session_1.slice(), out.target.session.slice());
            const failed = own.items[1].value.send_failed;
            try std.testing.expectEqualStrings("absent", failed.target.?.session.slice());
            try std.testing.expectEqualStrings("unknown_session", failed.code.slice());
            try std.testing.expect(own.items[0].position < own.items[1].position);
            {
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
            var reader: ContentReader = undefined;
            reader.open(try storage.openActivityContent(&.{ .session = session, .position = own.items[0].position }));
            reader.close();

            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            var view: TestingPage = undefined;
            view.open(&storage, try admitted.permit.consume());
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
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
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
            const malformed = [_][]const u8{ "", "short", "k7m2qi", "K7m2qx", "k7\x00mqx", "雪雪", "1234567" };
            const invalid_count = malformed.len + protocol.max_session_bytes + 1;
            var times: [invalid_count + 3]u64 = undefined;
            times[0] = item.at;
            const wide: [protocol.max_session_bytes]u8 = @splat('X');
            for (0..invalid_count) |index| {
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

test "ADM-29 Message replay fences when stored content disagrees with the accepted input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { form, private, digest }{ .form, .private, .digest };
            for (corruptions) |corruption| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "replay-content-config");
                var message: wire_request.MessageCommand = .{};
                try message.key.set("replay-content");
                try message.session.set(session.slice());
                message.text = try testingBytesContent(&tmp, "replay-content", "accepted input");
                defer message.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
                try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}).accepted.replayed);

                const content_id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{message.key.slice()});
                switch (corruption) {
                    .form => try store_testing.exec(&storage, "UPDATE content SET form=1 WHERE content_id=?1", .{content_id}),
                    .private => try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=?1", .{content_id}),
                    .digest => try store_testing.exec(&storage, "UPDATE content SET digest=?1 WHERE content_id=?2", .{
                        store_testing.Blob{ .bytes = &protocol.contentDigest("different input") },
                        content_id,
                    }),
                }
                try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .infrastructure_failure);
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "ADM-30 accepted Message observation leaves manifest certification to the parts list" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "observe-damaged-parts-config");
            const key = "observe-damaged-parts";
            try store_testing.submitTestMessageParts(&storage, &tmp, key, session.slice(), &.{ .{ .bytes = "first" }, .{ .bytes = "second" } });
            const before = try store_testing.observeCommandForTesting(&storage, key);
            const content_id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{key});
            try store_testing.exec(&storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=1", .{content_id});

            const after = try store_testing.observeCommandForTesting(&storage, key);
            try std.testing.expectEqual(.accepted, after.status);
            const input = after.kind.message.?.content;
            try std.testing.expectEqualDeep(before.kind.message.?.content, input);
            try std.testing.expect(input == .parts);
            try std.testing.expect(!storage.isFenced());

            var reader = try @import("../domain/public_parts.zig").Reader.init(session, input.parts.owner);
            defer reader.deinit();
            while (true) {
                const progress = storage.readPublicParts(&reader) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                };
                try std.testing.expect(progress == .pending);
            }
            try std.testing.expect(storage.isFenced());
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

test "INS-12 every public reader projects parts with their owner" {
    // Also: a compound Message retains ordered input across replay and saved refusal.
    // Keep the exercised owner set in sync with schema annotations.
    comptime {
        const expected = [_][]const u8{
            "core_command.primary_content_id",
            "message_admission.content_id",
            "conversation_entry.content_id",
            "action_operation.resolution_content_id",
            "action_operation.background_content_id",
        };
        var count: usize = 0;
        for (@import("../schema.zig").tables) |table| for (table.columns) |column| {
            if (column.holds != .value) continue;
            const name = table.name ++ "." ++ column.name;
            var covered = false;
            for (expected) |candidate| covered = covered or std.mem.eql(u8, name, candidate);
            if (!covered) @compileError("add compound reader coverage for " ++ name);
            count += 1;
        };
        if (count != expected.len) @compileError("compound reader coverage and value columns disagree");
    }
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try projections(case);
            try ownerless(case, .assistant);
            try ownerless(case, .rejection);
        }

        fn projections(case: *store_testing.Case) !void {
            const Capture = @import("../../InputCapture.zig");
            const custody = @import("../../content_custody.zig");
            const compound = @import("../domain/content_parts.zig");
            const access = @import("../access.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "parts-message-config");
            var used: std.atomic.Value(u64) = .init(0);
            var capture: Capture = undefined;
            const spool = try tmp.dir.createFile(std.testing.io, "parts-message-spool", .{ .read = true });
            const index = try tmp.dir.createFile(std.testing.io, "parts-message-index", .{ .read = true });
            try tmp.dir.deleteFile(std.testing.io, "parts-message-spool");
            try tmp.dir.deleteFile(std.testing.io, "parts-message-index");
            capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 10000 });
            defer capture.close();
            const image = @embedFile("../../testing/fixtures/input-baseline.jpg");
            for ([_][]const u8{ "before", image, "after" }, 0..) |bytes, ordinal| {
                try capture.begin(if (ordinal == 1) .{ .image = .{ .assertion = .jpeg } } else .text, bytes.len);
                var allowance = bytes.len;
                while (allowance != 0) {
                    const start = bytes.len - allowance;
                    var available = allowance;
                    const taken = try capture.append(bytes[start..], &available, false);
                    allowance -= taken;
                }
                try capture.end();
            }
            const loan = try capture.seal();
            const manifest = (try (compound.Source{ .captured = loan }).reference()).parts;
            var command: custody.MessageCommand = .{};
            try command.key.set("compound-message");
            try command.session.set(session.slice());
            const accepted = try storage.submitMessageParts(&command, loan, null, .{});
            try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
            const admission = accepted.accepted.admission_id;
            const parts_value: content_value.Value = .{ .parts = .{ .identity = manifest, .owner = .{ .message = admission } } };
            try std.testing.expectEqualDeep(parts_value, accepted.accepted.content);
            const replay = (try storage.submitMessageParts(&command, loan, null, .{})).accepted;
            try std.testing.expect(replay.replayed);
            try std.testing.expectEqual(admission, replay.admission_id);
            try std.testing.expectEqualDeep(parts_value, replay.content);
            const id = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key=?1", .{command.key.slice()});
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT form FROM content WHERE content_id=?1", .{id}));
            try std.testing.expectError(error.ContentIsParts, storage.openContent(accepted.accepted.content.identity()));
            const observed = try store_testing.observeCommandForTesting(&storage, command.key.slice());
            try std.testing.expectEqual(.accepted, observed.status);
            try std.testing.expectEqual(admission, observed.kind.message.?.queue.?.admission_id);
            try std.testing.expectEqualDeep(parts_value, observed.kind.message.?.content);
            try std.testing.expect(!storage.isFenced());
            var owner_buffer: [20]u8 = undefined;
            for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
                const report = try shared_fixtures.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
                defer std.testing.allocator.free(report);
                try expectPartsOwner(report, "message", admission);
            }
            {
                const page = try store_core.activityPageForTesting(&storage, .{ .session = session });
                var shown: usize = 0;
                for (page.items[0..page.count]) |item| if (item.value == .admission) {
                    try std.testing.expectEqualDeep(parts_value, item.value.admission.content);
                    shown += 1;
                };
                try std.testing.expectEqual(@as(usize, 1), shown);
                try std.testing.expectEqualDeep(@as(?content_value.Value, parts_value), page.queued.newest_content);
            }
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                const page = try store_core.publicConversationPageForTesting(&storage, .{ .session = session });
                try std.testing.expectEqualDeep(parts_value, page.items[0].content);
                try std.testing.expectError(error.ContentIsParts, storage.openPublicConversationContent(&.{ .session = session, .position = page.items[0].position, .ordinal = 0 }));
            }
            var historical: store_testing.TestingPage = undefined;
            historical.open(&storage, binding);
            defer historical.close();
            var frozen: @import("../domain/historical.zig").HistoricalSettings = undefined;
            try historical.settings(&frozen);
            try std.testing.expect(historical.page.compound_inputs);
            const message_entry = (try historical.nextEntry(0)).?;
            try std.testing.expect(message_entry.content == null);
            try historical.page.openMessage(message_entry.input.?);
            for ([_][]const u8{ "before", image, "after" }, 0..) |expected, ordinal| {
                const part = (try historical.nextMessagePart()).?;
                try std.testing.expect((part.kind == .image) == (ordinal == 1));
                var part_reader: store_testing.TestingReader = undefined;
                try historical.openContent(part.content, &part_reader);
                defer part_reader.close();
                var bytes: [image.len]u8 = undefined;
                const length = try part_reader.read(0, &bytes);
                try std.testing.expectEqualSlices(u8, expected, bytes[0..length]);
            }
            try std.testing.expect((try historical.nextMessagePart()) == null);
            try std.testing.expect(!storage.isFenced());
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var reader: access.Access(.read, error{}) = .open(&entry);
                defer reader.deinit();
                var cursor: compound.Cursor = undefined;
                cursor.init(.{ .content_id = id, .reference = .{ .parts = manifest } });
                for (0..3) |ordinal| try std.testing.expectEqual(@as(u32, @intCast(ordinal)), (try entry.finish(error{}, cursor.next(&reader))).?.ordinal);
                try std.testing.expect((try entry.finish(error{}, cursor.next(&reader))) == null);
            }
            try command.key.set("compound-refused");
            try command.session.set("000000");
            const rejected = try storage.submitMessageParts(&command, loan, null, .{});
            try std.testing.expect(rejected == .rejected and !rejected.rejected.replayed);
            try std.testing.expectEqual(.parts, rejected.rejected.form);
            try std.testing.expectEqualDeep(manifest, rejected.rejected.content);
            try std.testing.expectEqual(id, try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key=?1", .{command.key.slice()}));
            const refused_replay = (try storage.submitMessageParts(&command, loan, null, .{})).rejected;
            try std.testing.expect(refused_replay.replayed);
            try std.testing.expectEqual(.parts, refused_replay.form);
            try std.testing.expectEqualDeep(manifest, refused_replay.content);
            // Both admission and conversation retain the same compound value.
            try std.testing.expectEqual(id, try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key='compound-message'", .{}));
            try std.testing.expectEqual(id, try store_testing.queryU64(&storage, "SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1", .{session.slice()}));
            {
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.parsed.deinit();
                const content = listed.row.object.get("first_message").?.object.get("content").?.object;
                try std.testing.expectEqualStrings("parts", content.get("type").?.string);
                try std.testing.expect(std.mem.eql(u8, content.get("owner").?.object.get("message").?.string, try std.fmt.bufPrint(&owner_buffer, "{d}", .{admission})));
                const page = try store_core.activityPageForTesting(&storage, .{ .session = session });
                var shown: usize = 0;
                for (page.items[0..page.count]) |item| switch (item.value) {
                    .admission, .user => |message| {
                        try std.testing.expectEqualDeep(parts_value, message.content);
                        try std.testing.expectError(error.ContentIsParts, storage.openActivityContent(&.{ .session = session, .position = item.position, .ordinal = 0 }));
                        shown += 1;
                    },
                    else => {},
                };
                try std.testing.expectEqual(@as(usize, 2), shown);
            }

            // Exercise each Action value column in a session whose Message is text.
            const action_session = try shared_fixtures.configureTestSessionAsk(&storage, "compound-action-config");
            try submitTestMessage(&storage, &tmp, "compound-action-input", "compound-action-message", action_session.slice(), "run actions");
            const action_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, action_model, "compound-action-calls");
            const background_action = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{action_session.slice()});
            const resolved_action = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation WHERE session_ref=?1", .{action_session.slice()});
            var allow: protocol.PermissionDecisionCommand = .{ .session = action_session, .action_id = background_action, .decision = .allow_once };
            try allow.key.set("compound-action-allow");
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            var background: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = background_action };
            try background.session.set(action_session.slice());
            try background.key.set("compound-action-background");
            try std.testing.expect(storage.backgroundAction(.{ .command = &background }, .{}) == .accepted);
            var deny: protocol.PermissionDecisionCommand = .{ .session = action_session, .action_id = resolved_action, .decision = .deny };
            try deny.key.set("compound-action-deny");
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            const old_result = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{resolved_action});
            try store_testing.exec(&storage, "UPDATE action_operation SET resolution_content_id=?1 WHERE action_id=?2", .{ id, resolved_action });
            var result: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = action_session, .action_id = resolved_action }, &result);
            try std.testing.expectEqualDeep(content_value.Value{ .parts = .{ .identity = manifest, .owner = .{ .action = resolved_action } } }, result.status.resolved_parts.content);
            for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
                const report = try shared_fixtures.testingSessionReportWithProfile(&storage, &tmp, action_session.slice(), 1024 * 1024, profile);
                defer std.testing.allocator.free(report);
                try expectPartsOwner(report, "action", resolved_action);
            }
            try store_testing.exec(&storage, "UPDATE action_operation SET resolution_content_id=?1 WHERE action_id=?2", .{ old_result, resolved_action });
            try store_testing.exec(&storage, "UPDATE action_operation SET background_content_id=?1 WHERE action_id=?2", .{ id, background_action });
            try std.testing.expect(!storage.isFenced());
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var action_history: store_testing.TestingPage = undefined;
            action_history.open(&storage, continuation);
            defer action_history.close();
            var position: u64 = 0;
            while (try action_history.nextEntry(position)) |item| {
                position = item.position;
                if (item.kind == .tool_results) break;
            }
            const compound_result = (try action_history.nextToolResult()).?;
            try std.testing.expect(compound_result.input != null);
            try std.testing.expect(compound_result.output == null);
            try std.testing.expect(!storage.isFenced());

            // One captured Text has the same identity and replay as the scalar path.
            const single_session = try configureTestSession(&storage, "single-text-config");
            const single_text = "one ordinary text";
            const single_file = try tmp.dir.createFile(std.testing.io, "single-text-message", .{ .read = true });
            try single_file.writeStreamingAll(std.testing.io, single_text);
            try single_file.sync(std.testing.io);
            var scalar = try completeMessage("single-text-key", single_session.slice(), single_file, single_text);
            defer scalar.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&scalar, null, .{}) == .accepted);
            var single_capture: Capture = undefined;
            const single_spool = try tmp.dir.createFile(std.testing.io, "single-text-spool", .{ .read = true });
            const single_index = try tmp.dir.createFile(std.testing.io, "single-text-index", .{ .read = true });
            try tmp.dir.deleteFile(std.testing.io, "single-text-spool");
            try tmp.dir.deleteFile(std.testing.io, "single-text-index");
            single_capture.init(std.testing.io, single_spool, single_index, .{ .used = &used, .limit = 1000000 });
            defer single_capture.close();
            try single_capture.begin(.text, single_text.len);
            var single_allowance: usize = single_text.len;
            _ = try single_capture.append(single_text, &single_allowance, false);
            try single_capture.end();
            const single_loan = try single_capture.seal();
            const single_reference = try (compound.Source{ .captured = single_loan }).reference();
            try std.testing.expect(single_reference == .bytes);
            try std.testing.expectEqual(scalar.semanticDigest(), scalar.semanticDigestForInput(single_reference));
            const replayed_single = try storage.submitMessageParts(&scalar, single_loan, null, .{});
            try std.testing.expect(replayed_single == .accepted and replayed_single.accepted.replayed);
            const single_value: content_value.Value = .{ .text = .{ .length = single_text.len, .digest = protocol.contentDigest(single_text) } };
            try std.testing.expectEqualDeep(single_value, replayed_single.accepted.content);
            const single_id = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key='single-text-key'", .{});
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT form FROM content WHERE content_id=?1", .{single_id}));

            // The Store shares the value across Sessions, while each admission owns its own read.
            const second_session = try configureTestSession(&storage, "deduplicated-parts-config");
            try command.key.set("deduplicated-parts-message");
            try command.session.set(second_session.slice());
            const second = try storage.submitMessageParts(&command, loan, null, .{});
            try std.testing.expect(second == .accepted and !second.accepted.replayed);
            try std.testing.expectEqual(id, try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{command.key.slice()}));
            const second_admission = second.accepted.admission_id;
            try std.testing.expect(admission != second_admission);
            const owners = [_]content_value.Owner{ .{ .message = admission }, .{ .message = second_admission } };
            const second_parts_value: content_value.Value = .{ .parts = .{ .identity = manifest, .owner = owners[1] } };
            try std.testing.expectEqualDeep(second_parts_value, second.accepted.content);
            const second_observed = try store_testing.observeCommandForTesting(&storage, command.key.slice());
            try std.testing.expectEqual(second_admission, second_observed.kind.message.?.queue.?.admission_id);
            try std.testing.expectEqualDeep(second_parts_value, second_observed.kind.message.?.content);
            for ([_]@TypeOf(session){ session, second_session }, owners, 0..) |receiving, owner, index_in_pair| {
                const page = try store_core.activityPageForTesting(&storage, .{ .session = receiving });
                const expected: content_value.Value = .{ .parts = .{ .identity = manifest, .owner = owner } };
                var admissions: usize = 0;
                for (page.items[0..page.count]) |item| {
                    if (item.value != .admission) continue;
                    try std.testing.expectEqualDeep(expected, item.value.admission.content);
                    admissions += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), admissions);
                var reader: ContentReader = undefined;
                reader.open(try storage.openPublicPart(receiving.slice(), owner, 0, 0));
                defer reader.close();
                var bytes: [16]u8 = undefined;
                const length = try reader.read(0, &bytes);
                try std.testing.expectEqualStrings("before", bytes[0..length]);
                try std.testing.expectError(error.ContentNotFound, storage.openPublicPart(receiving.slice(), owners[1 - index_in_pair], 0, 0));
                try std.testing.expectError(error.ContentNotFound, storage.openPublicPart(single_session.slice(), owner, 0, 0));
            }
            try std.testing.expect(!storage.isFenced());

            try store_testing.exec(&storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=1", .{id});
            const observed_refusal = try store_testing.observeCommandForTesting(&storage, "compound-refused");
            try std.testing.expectEqual(.rejected, observed_refusal.status);
            try std.testing.expect(observed_refusal.code.eql(@tagName(rejected.rejected.code)));
            try std.testing.expect(observed_refusal.kind == .message and observed_refusal.kind.message == null);
            try std.testing.expect(!storage.isFenced());

            // A background notice has no owner, so a parts value there is damage, and it fences.
            try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, .{ .session = action_session }));
            try std.testing.expect(storage.isFenced());
        }

        fn ownerless(case: *store_testing.Case, source: enum { assistant, rejection }) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "ownerless-parts-config");
            try store_testing.submitTestMessageParts(&storage, &tmp, "ownerless-parts-message", session.slice(), &.{
                .{ .bytes = "look" },
                .{ .bytes = @embedFile("../../testing/fixtures/input-baseline.jpg"), .kind = .{ .image = .{ .assertion = .jpeg } } },
            });
            const content = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key='ownerless-parts-message'", .{});
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            switch (source) {
                .assistant => {
                    try store_testing.settleItemsForTesting(&storage, &tmp, binding, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
                },
                .rejection => {
                    try shared_fixtures.settleCallsForTesting(&storage, &tmp, binding, "rejected-call", &.{.{
                        .item_id = "rejected-item",
                        .name = "unknown_tool",
                        .encoded_call_id = "rejected-call",
                        .decoded_call_id = "rejected-call",
                        .encoded_arguments = "{}",
                        .decoded_arguments = "{}",
                    }});
                },
            }
            const activity_read = @import("../../activity_read.zig");
            const kind: activity_read.Kind = switch (source) {
                .assistant => .assistant,
                .rejection => .tool_result,
            };
            const request: activity_read.ActivityPage = .{ .session = session, .kinds = .initOne(kind) };
            {
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 1), page.count);
                try std.testing.expectEqual(kind, std.meta.activeTag(page.items[0].value));
            }
            switch (source) {
                .assistant => {
                    // Keep the assistant entry and its source item linked so the projection sees the parts form.
                    try store_testing.exec(&storage, "UPDATE model_output_item SET message_content_id=?1 WHERE operation_id=?2 AND item_kind=2", .{ content, binding.operation_id });
                    try store_testing.exec(&storage, "UPDATE conversation_entry SET content_id=?1 WHERE source_operation_id=?2 AND entry_kind=3", .{ content, binding.operation_id });
                },
                .rejection => try store_testing.exec(&storage, "UPDATE model_tool_call SET rejection_content_id=?1 WHERE operation_id=?2 AND call_ordinal=0", .{ content, binding.operation_id }),
            }
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "background Action publication replay fences on compound content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try shared_fixtures.configureTestSessionAsk(&storage, "compound-publication-config");
            try submitTestMessage(&storage, &tmp, "compound-publication-input", "compound-publication-message", session.slice(), "run actions");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "compound-publication-calls");
            const action_id = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
            var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action_id, .decision = .allow_once };
            try allow.key.set("compound-publication-allow");
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            var background: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = action_id };
            try background.session.set(session.slice());
            try background.key.set("compound-publication-background");
            try std.testing.expect(storage.backgroundAction(.{ .command = &background }, .{}) == .accepted);

            const parts_session = try configureTestSession(&storage, "compound-publication-parts-config");
            const parts_key = "compound-publication-parts-message";
            try store_testing.submitTestMessageParts(&storage, &tmp, parts_key, parts_session.slice(), &.{
                .{ .bytes = "look" },
                .{ .bytes = @embedFile("../../testing/fixtures/input-baseline.jpg"), .kind = .{ .image = .{ .assertion = .jpeg } } },
            });
            const content_id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{parts_key});

            const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, binding, &input);
            const handle = input.sender_handle.slice();
            const key = "compound-guard";
            const payload = "ordinary text";
            const first = try storage.publishActionValue(handle, key, payload);
            try std.testing.expect(first == .accepted and first.accepted.action_id == action_id and first.accepted.admission_id != null);
            const replay = try storage.publishActionValue(handle, key, payload);
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try store_testing.exec(&storage, "UPDATE action_value SET content_id=?1 WHERE action_id=?2 AND publication_key=?3", .{ content_id, action_id, key });
            try std.testing.expectError(error.CorruptStore, storage.publishActionValue(handle, key, payload));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

/// The report names a parts value owned by `kind` `id`.
fn expectPartsOwner(report: []const u8, comptime kind: []const u8, id: u64) !void {
    var buffer: [64]u8 = undefined;
    const owner = try std.fmt.bufPrint(&buffer, "\"owner\":{{\"" ++ kind ++ "\":\"{d}\"}}", .{id});
    if (std.mem.indexOf(u8, report, owner) == null) {
        std.debug.print("missing {s} in {s}\n", .{ owner, report });
        return error.TestUnexpectedResult;
    }
}

test "creating captured Messages reuse matching configuration content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Capture = @import("../../InputCapture.zig");
            const custody = @import("../../content_custody.zig");
            for ([_]bool{ false, true }) |compound| {
                for ([_]enum { instructions, output_schema, default_instructions }{ .instructions, .output_schema, .default_instructions }) |field| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    const settings = try completeConfiguration("matching-config", "", workspace, "model-a");
                    var message: custody.MessageCommand = .{ .configuration = settings.configuration };
                    try message.key.set("matching-message");
                    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
                    const text = if (field == .default_instructions) "" else "{\"type\":\"object\",\"title\":\"matching input\"}";
                    switch (field) {
                        .instructions => message.configuration.?.instructions = try testingBytesContent(&tmp, "instructions", text),
                        .output_schema => message.configuration.?.output_schema = try testingBytesContent(&tmp, "output-schema", text),
                        .default_instructions => {},
                    }
                    var used: std.atomic.Value(u64) = .init(0);
                    var capture: Capture = undefined;
                    const spool = try tmp.dir.createFile(std.testing.io, "spool", .{ .read = true });
                    const index = try tmp.dir.createFile(std.testing.io, "index", .{ .read = true });
                    try tmp.dir.deleteFile(std.testing.io, "spool");
                    try tmp.dir.deleteFile(std.testing.io, "index");
                    capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 100000 });
                    defer capture.close();
                    try capture.begin(.text, text.len);
                    var allowance: usize = text.len;
                    _ = try capture.append(text, &allowance, false);
                    try capture.end();
                    if (compound) {
                        const image = @embedFile("../../testing/fixtures/input-baseline.jpg");
                        try capture.begin(.{ .image = .{ .assertion = .jpeg } }, image.len);
                        var available: usize = image.len;
                        _ = try capture.append(image, &available, false);
                        try capture.end();
                    }
                    const loan = try capture.seal();
                    const reply = try storage.submitMessageParts(&message, loan, null, .{});
                    try std.testing.expect(reply == .accepted and !reply.accepted.replayed);
                    try std.testing.expect(!storage.isFenced());
                    try std.testing.expect((try storage.submitMessageParts(&message, loan, null, .{})).accepted.replayed);
                    const saved = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key='matching-message'", .{});
                    const input = if (compound) try store_testing.queryU64(&storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=0", .{saved}) else saved;
                    const configured = if (field == .output_schema)
                        try store_testing.queryU64(&storage, "SELECT output_schema_content_id FROM session WHERE session_ref=?1", .{reply.accepted.session.slice()})
                    else
                        try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{reply.accepted.session.slice()});
                    try std.testing.expectEqual(input, configured);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE digest=?1 AND byte_length=?2 AND private=0", .{ store_testing.Blob{ .bytes = &protocol.contentDigest(text) }, text.len }));
                }
            }
        }
    }.run);
}
