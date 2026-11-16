//! Conversation Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const named_scratch = @import("../../named_scratch.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const output_decode = @import("../../output_decode.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
const ContentReader = content_domain.ContentReader;
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const testing_absent_model_evidence = store_testing.testing_absent_model_evidence;
const TestingCall = shared_fixtures.TestingCall;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingContent = shared_fixtures.testingContent;

test "public conversation owner fixes end, filters settings and bounds content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("public-config", "", workspace, "model-a");
            // The 1 MiB Message must not start a compaction: this test reads pages.
            configuration.configuration.compaction_trigger.state = .value;
            try configuration.configuration.compaction_trigger.value.set("1000000000");
            const created_session_0_reply = try storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            var request = protocol.ConversationPage{};
            try request.session.set(created_session_0.slice());
            try std.testing.expectEqual(@as(usize, 0), (try store_core.publicConversationPageForTesting(&storage, request)).count);

            // A large first input and nineteen small ones expose both the item and
            // content bound; no answer is invented for queued, unapplied input.
            for (0..20) |index| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "public-{d}", .{index});
                var command: wire_request.MessageCommand = .{};
                try command.key.set(name);
                try command.session.set(created_session_0.slice());
                command.text = if (index == 19)
                    try testingBytesContent(&tmp, name, "é中")
                else
                    try testingContent(&tmp, name, 'x', if (index == 0) 1024 * 1024 else 3);
                try std.testing.expect(storage.submitMessageWithModel(&command, null, .{}) == .accepted);
                try command.removeTemporaryContent(std.testing.io);
            }
            try std.testing.expectEqual(@as(usize, 0), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            var instruction: wire_request.ConfigureCommand = .{};
            try instruction.key.set("public-instruction-before-selection");
            try instruction.session.set(created_session_0.slice());
            instruction.configuration.instructions = try testingContent(&tmp, "public-instruction-before", 's', 7);
            defer instruction.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&instruction, .{}) == .accepted);
            const active = (try storage.admitNextModelAttempt(.{})).?;
            const first = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 16), first.count);
            try std.testing.expect(first.more);
            try std.testing.expectEqual(@as(u64, 41), first.items[0].position);
            try std.testing.expectEqual(@as(u64, 26), first.items[15].position);
            for (first.items[0..first.count]) |item| try std.testing.expect(item.kind == .user);
            try std.testing.expectEqual(@as(u64, 5), first.items[0].content.length);
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, .{
                .session = request.session,
                .end = first.end,
                .before_position = first.items[15].position,
                .before_ordinal = 1,
            }));
            try std.testing.expect(!storage.isFenced());
            var unicode_reader: ContentReader = undefined;
            unicode_reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = 41 }));
            var lead: [1]u8 = undefined;
            var rest: [4]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 1), try unicode_reader.read(0, &lead));
            try std.testing.expectEqual(@as(usize, 4), try unicode_reader.read(1, &rest));
            try std.testing.expectEqual("é中"[0], lead[0]);
            try std.testing.expectEqualStrings("é中"[1..], &rest);
            unicode_reader.close();

            var later: wire_request.ConfigureCommand = .{};
            try later.key.set("public-instructions");
            try later.session.set(created_session_0.slice());
            later.configuration.instructions = try testingContent(&tmp, "public-private-settings", 'p', 16);
            defer later.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&later, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "after-page", "after-page-key", created_session_0.slice(), "later public input");
            try storage.settleModelAttemptFailure(active.permit.binding, .{ .uncorrelated = "fixture_failure" }, .ordinary, .{});
            _ = (try storage.admitNextModelAttempt(.{})).?;
            const fixed_first = try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session, .end = first.end });
            try std.testing.expectEqual(first.end, fixed_first.end);
            try std.testing.expectEqual(first.count, fixed_first.count);
            for (first.items[0..first.count], fixed_first.items[0..fixed_first.count]) |expected, actual| {
                try std.testing.expectEqual(expected.position, actual.position);
                try std.testing.expectEqual(expected.ordinal, actual.ordinal);
            }
            request.end = first.end;
            request.before_position = first.items[15].position;
            const older = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 4), older.count);
            try std.testing.expect(!older.more);
            try std.testing.expectEqual(@as(u64, 25), older.items[0].position);
            try std.testing.expectEqual(@as(u64, 22), older.items[3].position);
            try std.testing.expectEqual(@as(u64, 1024 * 1024), older.items[3].content.length);
            const fresh = try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session });
            try std.testing.expectEqual(@as(usize, 16), fresh.count);
            try std.testing.expect(fresh.items[0].position > first.end);
            try std.testing.expect(fresh.items[0].kind == .user);
            var read = protocol.ConversationContent{ .session = request.session, .position = older.items[3].position, .start = 1024 * 1024 - 2 };
            var reader: ContentReader = undefined;
            reader.open(try storage.openPublicConversationContent(&read));
            var tail: [2]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 2), try reader.read(read.start, &tail));
            try std.testing.expectEqualStrings("xx", &tail);
            reader.close();
            read.position = 42; // the applied instruction is not public content
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&read));
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = .{}, .position = 1 }));
            try std.testing.expectError(error.RangeOutOfBounds, storage.openPublicConversationContent(&.{ .session = request.session, .position = 22, .start = 1024 * 1024 + 1 }));
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, .{ .session = request.session, .end = first.end + 100, .before_position = 1 }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "private-only model output never becomes public conversation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "private-config");
            try submitTestMessage(&storage, &tmp, "private-input", "private-message", session.slice(), "hi");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Keep a successor queued: a terminal text Turn requires an answer, while
            // this intermediate accepted output contains only opaque continuation.
            try submitTestMessage(&storage, &tmp, "private-next", "private-next-message", session.slice(), "later");
            const bytes = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"private continuation\"}";
            const source = try tmp.dir.createFile(std.testing.io, "private-output", .{ .read = true });
            defer source.close(std.testing.io);
            try source.writeStreamingAll(std.testing.io, bytes);
            try source.sync(std.testing.io);
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used: std.atomic.Value(u64) = .init(0);
            var retained: ?named_scratch.Owner = null;
            var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "private-metadata", .{ .used = &used, .limit = 1024 }, false, &retained);
            defer metadata.deinit();
            _ = try output_decode.recordItemForTesting(&metadata, source, 0, bytes.len, 0, .assistant_response);
            try metadata.sealForRead();
            try storage.settleModelSuccess(binding, &.{
                .source = source,
                .source_length = bytes.len,
                .metadata = metadata.file,
                .item_count = 1,
                .call_count = 0,
                .answer_length = 0,
                .answer_digest = protocol.contentDigest(""),
                .response_id = .{},
                .model_evidence = testing_absent_model_evidence,
                .request_id = .{},
            }, .{});
            var request = protocol.ConversationPage{};
            try request.session.set(session.slice());
            const page = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            try std.testing.expect(page.items[0].kind == .user);
            try std.testing.expect(page.end > page.items[0].position);
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{
                .session = request.session,
                .position = page.end,
            }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "public tool-result cursor crosses a completed group boundary" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "group-config");
            try submitTestMessage(&storage, &tmp, "group-input", "group-message", session.slice(), "run tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var ids: [17][16]u8 = undefined;
            var names: [17][16]u8 = undefined;
            var calls: [17]TestingCall = undefined;
            for (&calls, 0..) |*call, index| {
                const id = try std.fmt.bufPrint(&ids[index], "item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&names[index], "call-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = call_id, .decoded_call_id = call_id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "group-metadata", &calls);
            var cursor = protocol.ConversationPage{};
            try cursor.session.set(session.slice());
            const newest = try store_core.publicConversationPageForTesting(&storage, cursor);
            try std.testing.expectEqual(@as(usize, 16), newest.count);
            try std.testing.expect(newest.more);
            for (newest.items[0..newest.count], 0..) |item, index| {
                try std.testing.expect(item.kind == .tool_result);
                try std.testing.expectEqual(newest.items[0].position, item.position);
                try std.testing.expectEqual(@as(u64, 17) - index, item.ordinal);
            }
            cursor.end = newest.end;
            cursor.before_position = newest.items[15].position;
            cursor.before_ordinal = 18; // No such completed call in this group.
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, cursor));
            try std.testing.expect(!storage.isFenced());
            cursor.before_ordinal = newest.items[15].ordinal;
            const older = try store_core.publicConversationPageForTesting(&storage, cursor);
            try std.testing.expectEqual(@as(usize, 2), older.count);
            try std.testing.expect(!older.more);
            try std.testing.expectEqual(@as(u64, 1), older.items[0].ordinal);
            try std.testing.expect(older.items[0].kind == .tool_result);
            try std.testing.expect(older.items[1].kind == .user);
            var reader: ContentReader = undefined;
            reader.open(try storage.openPublicConversationContent(&.{ .session = cursor.session, .position = older.items[0].position, .ordinal = 1 }));
            defer reader.close();
            var result: [64]u8 = undefined;
            const size = try reader.read(0, &result);
            try std.testing.expectEqualStrings("Unknown tool: unknown.", result[0..size]);
        }
    }.run);
}
