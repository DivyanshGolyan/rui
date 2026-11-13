//! Model settlement Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const named_scratch = @import("../../named_scratch.zig");
const output_decode = @import("../../output_decode.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentReader = content_domain.ContentReader;
const HistoricalView = historical_domain.HistoricalView;
const ModelFailure = model_settlement_domain.ModelFailure;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const testing_absent_model_evidence = store_testing.testing_absent_model_evidence;
const RoundMeter = shared_fixtures.RoundMeter;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;
const TestingCall = shared_fixtures.TestingCall;
const TestingSessionReport = shared_fixtures.TestingSessionReport;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectActivityOutcome = shared_fixtures.expectActivityOutcome;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingSessionReport = shared_fixtures.testingSessionReport;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "response-stage model failures require their provenance" {
    // #511 lost request correlation and classification through defaulted
    // fields; a response-stage settlement must name every fact explicitly.
    inline for (.{ ModelFailure.Correlated, ModelFailure.Rejected }) |Stage| {
        inline for (@typeInfo(Stage).@"struct".field_attrs) |attrs| {
            try std.testing.expect(attrs.default_value_ptr == null);
        }
    }
    try std.testing.expect(@hasField(ModelFailure.Correlated, "request_id"));
    try std.testing.expect(@hasField(ModelFailure.Rejected, "request_id"));
    try std.testing.expect(@hasField(ModelFailure.Rejected, "diagnostic"));
    try std.testing.expect(@FieldType(ModelFailure.Rejected, "diagnostic") == []const u8);
}

test "a Bash call the Operation did not offer is rejected and keeps its description" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("unoffered-config", "", workspace, "model-a");
            command.configuration.tools.state = .value;
            command.configuration.tools = try .of(&.{});
            const reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const session = reply.accepted.session;
            try submitTestMessage(&storage, &tmp, "unoffered-message", "unoffered-message", session.slice(), "classify");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
            };
            try settleCallsForTesting(&storage, &tmp, binding, "unoffered-metadata", &calls);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code='unknown_tool' AND description='Run'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
        }
    }.run);
}

test "terminal call-result import and read failures preserve canonical authority" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var import_tmp = std.testing.tmpDir(.{});
            defer import_tmp.cleanup();
            var import_store: Store = undefined;
            try store_testing.testingStore(case, &import_store, &import_tmp, std.testing.io);
            defer import_store.close() catch unreachable;
            const allocated_session_0 = try configureTestSessionAsk(&import_store, "result-import-config");
            try submitTestMessage(&import_store, &import_tmp, "result-import-message", "result-import-message", allocated_session_0.slice(), "call");
            const import_binding = (try import_store.admitNextModelAttempt(.{})).?.permit.binding;
            const valid_call = [_]TestingCall{.{ .item_id = "import-item", .name = "bash", .encoded_call_id = "import-call", .decoded_call_id = "import-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&import_store, &import_tmp, import_binding, "result-import-metadata", &valid_call);
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&import_store, "SELECT action_id FROM action_operation", .{}) };
            try deny.key.set("result-import-deny");
            try deny.session.set(allocated_session_0.slice());
            try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, import_store.decidePermission(&deny, .{ .content_import = true }));
            try std.testing.expect(import_store.isFenced());
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&import_store, "SELECT count(*) FROM core_command WHERE command_key='result-import-deny'", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&import_store, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL", .{}));

            var read_tmp = std.testing.tmpDir(.{});
            defer read_tmp.cleanup();
            var read_store: Store = undefined;
            try store_testing.testingStore(case, &read_store, &read_tmp, std.testing.io);
            defer read_store.close() catch unreachable;
            const allocated_session_1 = try configureTestSession(&read_store, "result-read-config");
            try submitTestMessage(&read_store, &read_tmp, "result-read-message", "result-read-message", allocated_session_1.slice(), "call");
            const read_binding = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
            const rejected_call = [_]TestingCall{.{ .item_id = "read-item", .name = "unknown", .encoded_call_id = "read-call", .decoded_call_id = "read-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&read_store, &read_tmp, read_binding, "result-read-metadata", &rejected_call);
            const continuation = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.withoutForeignKeys(&read_store, "UPDATE model_tool_call SET rejection_content_id=9223372036854775807", .{});
            var view: HistoricalView = undefined;
            read_store.openHistoricalView(continuation, &view);
            defer view.close();
            var position: u64 = 0;
            while (true) {
                const entry = view.nextEntry(position) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                } orelse return error.MissingCorruptionFailure;
                position = entry.position;
            }
            try std.testing.expect(read_store.isFenced());
        }
    }.run);
}

test "call classification uses the proposing Operation frozen tool set" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "frozen-call-config");
            var remove_bash: wire_request.ConfigureCommand = .{};
            try remove_bash.key.set("frozen-call-no-tools");
            try remove_bash.session.set(session.slice());
            remove_bash.configuration.tools.state = .value;
            remove_bash.configuration.tools.count = 0;
            try std.testing.expect(try storage.configure(&remove_bash, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "frozen-call-message", "frozen-call-message", session.slice(), "classify");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var add_bash: wire_request.ConfigureCommand = .{};
            try add_bash.key.set("frozen-call-add-bash");
            try add_bash.session.set(session.slice());
            add_bash.configuration.tools.state = .value;
            add_bash.configuration.tools = try .of(&.{"bash"});
            try std.testing.expect(try storage.configure(&add_bash, .{}) == .accepted);
            const calls = [_]TestingCall{.{
                .item_id = "frozen-item",
                .name = "bash",
                .encoded_call_id = "frozen-call",
                .decoded_call_id = "frozen-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Print frozen marker\\\",\\\"cmd\\\":\\\"echo frozen\\\",\\\"timeout_ms\\\":null}",
                .decoded_arguments = "{\"description\":\"Print frozen marker\",\"cmd\":\"echo frozen\",\"timeout_ms\":null}",
            }};
            try settleCallsForTesting(&storage, &tmp, binding, "frozen-call-metadata", &calls);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool'", .{}));
        }
    }.run);
}

test "duplicate trustworthy call identity rolls back every imported consequence" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "duplicate-call-config");
            try submitTestMessage(&storage, &tmp, "duplicate-call-message", "duplicate-call-message", session.slice(), "duplicate");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "duplicate-item-1", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}" },
                .{ .item_id = "duplicate-item-2", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"description\\\":\\\"Run second command\\\",\\\"cmd\\\":\\\"two\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run second command\",\"cmd\":\"two\",\"timeout_ms\":null}" },
            };
            try std.testing.expectError(
                error.InvalidProviderEnvelope,
                settleCallsForTesting(&storage, &tmp, binding, "duplicate-call-metadata", &calls),
            );
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
        }
    }.run);
}

test "a call id repeated in a later call batch fails the settlement" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "repeat-call-config");
            try submitTestMessage(&storage, &tmp, "repeat-call-input", "repeat-call-key", session.slice(), "repeat");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var item_ids: [65][16]u8 = undefined;
            var call_ids: [65][16]u8 = undefined;
            var calls: [65]TestingCall = undefined;
            for (&calls, &item_ids, &call_ids, 0..) |*call, *item_id, *call_id, index| {
                const id = try std.fmt.bufPrint(call_id, "call-{d}", .{if (index == 64) 0 else index});
                call.* = .{
                    .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
                    .name = "bash",
                    .encoded_call_id = id,
                    .decoded_call_id = id,
                    .encoded_arguments = "{\\\"description\\\":\\\"Run it\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run it\",\"cmd\":\"true\",\"timeout_ms\":null}",
                };
            }
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCallsForTesting(&storage, &tmp, binding, "repeat-call", &calls));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(0, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
        }
    }.run);
}

/// A success output whose items can hold more content identities than a
/// settlement batch (`batch_identities`, 257), so the settlement cuts
/// them across batches, and what each item saves when settled whole, as
/// main's settlement saved it. The default is one reasoning item of 300
/// summary texts and the answer "done". In a reasoning item part 280
/// repeats part 3's text, one the first batch collected, and part 290
/// repeats part 285's, which it did not.
const OversizedItem = struct {
    const Item = union(enum) {
        /// Summary texts, `text(index)` each, every part's bag empty.
        reasoning: usize,
        /// output_text parts, each with a bag of its own (`"n":index`)
        /// and the text `messageText(index, blank)`.
        message: struct { parts: usize, blank: bool = false },
        /// A web search call that finds "Io" in ziglang.org: an action
        /// and a pattern record.
        find_in_page,
        /// A failed web search call: an action record alone.
        failed_search,
        /// The message "done", one part with an empty bag.
        done,
    };
    const parts = 300;
    const usage_json = "{\"input_tokens\":400,\"output_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":100}}";

    items: []const Item = &.{ .{ .reasoning = parts }, .done },
    /// The answer message's ordinal; its text is the answer unless
    /// `empty_answer`.
    answer: u64 = 1,
    empty_answer: bool = false,
    /// A usage record follows the items.
    usage: bool = false,
    bytes: [8][]u8 = undefined,
    built: usize = 0,

    fn text(index: usize, buffer: *[16]u8) []const u8 {
        const shown: usize = switch (index) {
            280 => 3,
            290 => 285,
            else => index,
        };
        return std.fmt.bufPrint(buffer, "summary {d}", .{shown}) catch unreachable;
    }

    fn messageText(index: usize, blank: bool, buffer: *[16]u8) []const u8 {
        if (blank) return " ";
        return std.fmt.bufPrint(buffer, "w{d} ", .{index}) catch unreachable;
    }

    fn build(output: *OversizedItem) !void {
        errdefer output.deinit();
        for (output.items, 0..) |item, ordinal| {
            var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer json.deinit();
            const writer = &json.writer;
            switch (item) {
                .reasoning => |count| {
                    try writer.print("{{\"type\":\"reasoning\",\"id\":\"item{d}\",\"summary\":[", .{ordinal});
                    for (0..count) |index| {
                        var buffer: [16]u8 = undefined;
                        try writer.print("{s}{{\"type\":\"summary_text\",\"text\":\"{s}\"}}", .{ if (index == 0) "" else ",", text(index, &buffer) });
                    }
                    try writer.writeAll("],\"encrypted_content\":\"opaque\"}");
                },
                .message => |message| {
                    try writer.print("{{\"type\":\"message\",\"id\":\"item{d}\",\"role\":\"assistant\",\"content\":[", .{ordinal});
                    for (0..message.parts) |index| {
                        var buffer: [16]u8 = undefined;
                        try writer.print("{s}{{\"type\":\"output_text\",\"text\":\"{s}\",\"n\":{d}}}", .{ if (index == 0) "" else ",", messageText(index, message.blank, &buffer), index });
                    }
                    try writer.writeAll("]}");
                },
                .find_in_page => try writer.print("{{\"type\":\"web_search_call\",\"id\":\"item{d}\",\"action\":{{\"type\":\"find_in_page\",\"url\":\"ziglang.org\",\"pattern\":\"Io\"}}}}", .{ordinal}),
                .failed_search => try writer.print("{{\"type\":\"web_search_call\",\"id\":\"item{d}\",\"status\":\"failed\",\"action\":{{\"type\":\"search\",\"query\":\"zig\"}}}}", .{ordinal}),
                .done => try writer.writeAll("{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"),
            }
            output.bytes[ordinal] = try json.toOwnedSlice();
            output.built += 1;
        }
    }

    fn deinit(output: *OversizedItem) void {
        for (output.bytes[0..output.built]) |bytes| std.testing.allocator.free(bytes);
        output.built = 0;
    }

    /// A message item's whole text: its parts' texts back to back.
    fn wholeText(item: Item, writer: *std.Io.Writer) !void {
        switch (item) {
            .message => |message| for (0..message.parts) |index| {
                var buffer: [16]u8 = undefined;
                try writer.writeAll(messageText(index, message.blank, &buffer));
            },
            .done => try writer.writeAll("done"),
            .reasoning, .find_in_page, .failed_search => unreachable,
        }
    }

    /// Settles the output, as `settleItemsForTesting` does, but first
    /// makes the source's copy of the first item's part `changed` differ
    /// from what its metadata recorded, when given.
    fn settle(output: *const OversizedItem, storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, changed: ?usize) !void {
        const source = try tmp.dir.createFile(std.testing.io, "oversized-output", .{ .read = true, .truncate = true });
        defer source.close(std.testing.io);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const root_length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "oversized-metadata", .{ .used = &used, .limit = 1 << 21 }, false, &retained);
        defer metadata.deinit();
        var offset: u64 = 0;
        for (output.bytes[0..output.built], 0..) |bytes, ordinal| {
            try source.writeStreamingAll(std.testing.io, bytes);
            try source.sync(std.testing.io);
            _ = try output_decode.recordItemForTesting(&metadata, source, offset, bytes.len, ordinal, .assistant_response);
            offset += bytes.len;
        }
        if (output.usage) {
            try source.writeStreamingAll(std.testing.io, usage_json);
            try source.sync(std.testing.io);
            try metadata.append(&.{
                .tag = .usage,
                .start = offset,
                .length = usage_json.len,
                .content_digest = protocol.contentDigest(usage_json),
                .usage = try output_decode.readUsageForTesting(std.testing.io, source, offset, usage_json.len),
            });
            offset += usage_json.len;
        }
        try metadata.sealForRead();
        if (changed) |index| {
            var buffer: [16]u8 = undefined;
            var needle: [24]u8 = undefined;
            const quoted = try std.fmt.bufPrint(&needle, "\"{s}\"", .{text(index, &buffer)});
            const at = std.mem.find(u8, output.bytes[0], quoted).?;
            // Same length, other bytes: only the digest check sees it.
            try source.writePositionalAll(std.testing.io, "#", at + 1);
            try source.sync(std.testing.io);
        }
        var answer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer answer.deinit();
        if (!output.empty_answer) try wholeText(output.items[output.answer], &answer.writer);
        try storage.settleModelSuccess(binding, &.{
            .source = source,
            .source_length = offset,
            .metadata = metadata.file,
            .item_count = output.built,
            .call_count = 0,
            .answer_item_ordinal = output.answer,
            .answer_length = answer.written().len,
            .answer_digest = protocol.contentDigest(answer.written()),
            .response_id = .{},
            .model_evidence = testing_absent_model_evidence,
            .request_id = .{},
        }, .{});
    }

    /// Checks every row the settlement saved for operation `operation`
    /// against what each item holds: each part's own text or text length
    /// and bag, each item's part count, text and description, the
    /// Conversation entries, the answer and the usage.
    fn expectSaved(output: *const OversizedItem, storage: *Store, operation: u64) !void {
        var part_rows: usize = 0;
        var messages: usize = 0;
        for (output.items, 0..) |item, ordinal| {
            switch (item) {
                .reasoning => |count| for (0..count) |index| {
                    var buffer: [16]u8 = undefined;
                    const own = text(index, &buffer);
                    try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_part p JOIN content c ON c.content_id=p.text_content_id JOIN content b ON b.content_id=p.extras_content_id " ++
                        "WHERE p.operation_id=?1 AND p.item_ordinal=?2 AND p.part_ordinal=?3 AND p.part_kind=3 AND p.text_length IS NULL AND c.digest=?4 AND c.byte_length=?5 AND c.private=1 AND b.byte_length=0 AND b.private=1", .{ operation, ordinal, index, store_testing.Blob{ .bytes = &protocol.contentDigest(own) }, own.len }));
                },
                .message => |message| for (0..message.parts) |index| {
                    var buffer: [16]u8 = undefined;
                    var bag_buffer: [16]u8 = undefined;
                    const bag = try std.fmt.bufPrint(&bag_buffer, "\"n\":{d}", .{index});
                    try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_part p JOIN content b ON b.content_id=p.extras_content_id " ++
                        "WHERE p.operation_id=?1 AND p.item_ordinal=?2 AND p.part_ordinal=?3 AND p.part_kind=1 AND p.text_length=?4 AND p.text_content_id IS NULL AND b.digest=?5 AND b.byte_length=?6 AND b.private=1", .{ operation, ordinal, index, messageText(index, message.blank, &buffer).len, store_testing.Blob{ .bytes = &protocol.contentDigest(bag) }, bag.len }));
                },
                .done => try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_part p JOIN content b ON b.content_id=p.extras_content_id " ++
                    "WHERE p.operation_id=?1 AND p.item_ordinal=?2 AND p.part_ordinal=0 AND p.part_kind=1 AND p.text_length=4 AND p.text_content_id IS NULL AND b.byte_length=0 AND b.private=1", .{ operation, ordinal })),
                .find_in_page, .failed_search => {},
            }
            const part_count: usize = switch (item) {
                .reasoning => |count| count,
                .message => |message| message.parts,
                .done => 1,
                .find_in_page, .failed_search => 0,
            };
            part_rows += part_count;
            switch (item) {
                .reasoning => try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_item i JOIN content b ON b.content_id=i.extras_content_id " ++
                    "WHERE i.operation_id=?1 AND i.item_ordinal=?2 AND i.part_count=?3 AND i.message_content_id IS NULL AND i.description IS NULL AND b.private=1", .{ operation, ordinal, part_count })),
                .find_in_page, .failed_search => try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_item i JOIN content b ON b.content_id=i.extras_content_id " ++
                    "WHERE i.operation_id=?1 AND i.item_ordinal=?2 AND i.part_count=0 AND i.message_content_id IS NULL AND i.description=?3 AND i.call_failed=?4 AND b.private=1", .{
                    operation,
                    ordinal,
                    if (item == .find_in_page) "Find “Io” in ziglang.org" else "Search “zig”",
                    @intFromBool(item == .failed_search),
                })),
                .message, .done => {
                    messages += 1;
                    var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer whole.deinit();
                    try wholeText(item, &whole.writer);
                    const digest = protocol.contentDigest(whole.written());
                    try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_item i JOIN content c ON c.content_id=i.message_content_id JOIN content b ON b.content_id=i.extras_content_id " ++
                        "WHERE i.operation_id=?1 AND i.item_ordinal=?2 AND i.part_count=?3 AND c.digest=?4 AND c.byte_length=?5 AND c.private=0 AND b.private=1", .{ operation, ordinal, part_count, store_testing.Blob{ .bytes = &digest }, whole.written().len }));
                    // The text streamed across the item's batches reads back whole.
                    var reader: ContentReader = undefined;
                    reader.open(try content_domain.openContentIdentity(storage, .{ .digest = digest, .length = whole.written().len }, false));
                    defer reader.close();
                    var saved: [4096]u8 = undefined;
                    var length: usize = 0;
                    while (length < whole.written().len) {
                        const read = try reader.read(length, saved[length..]);
                        if (read == 0) break;
                        length += read;
                    }
                    try std.testing.expectEqualStrings(whole.written(), saved[0..length]);
                },
            }
        }
        try std.testing.expectEqual(part_rows, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_part WHERE operation_id=?1", .{operation}));
        // Every item, at dense positions in output order.
        try std.testing.expectEqual(output.items.len, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_item WHERE operation_id=?1 AND " ++
            "session_position-item_ordinal=(SELECT min(session_position) FROM model_output_item WHERE operation_id=?1)", .{operation}));
        try std.testing.expectEqual(output.items.len, try store_testing.queryU64(storage, "SELECT count(*) FROM model_output_item WHERE operation_id=?1", .{operation}));
        // Each message is an entry of its own text at its own position.
        try std.testing.expectEqual(messages, try store_testing.queryU64(storage, "SELECT count(*) FROM conversation_entry e JOIN model_output_item i ON i.operation_id=e.source_operation_id AND i.item_ordinal=e.source_item_ordinal " ++
            "WHERE e.source_operation_id=?1 AND e.content_id=i.message_content_id AND e.session_position=i.session_position", .{operation}));
        try std.testing.expectEqual(messages, try store_testing.queryU64(storage, "SELECT count(*) FROM conversation_entry WHERE source_operation_id=?1", .{operation}));
        var answer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer answer.deinit();
        if (!output.empty_answer) try wholeText(output.items[output.answer], &answer.writer);
        try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_operation o JOIN content c ON c.content_id=o.resolution_content_id " ++
            "WHERE o.operation_id=?1 AND o.output_item_count=?2 AND c.digest=?3 AND c.byte_length=?4", .{ operation, output.items.len, store_testing.Blob{ .bytes = &protocol.contentDigest(answer.written()) }, answer.written().len }));
        if (output.usage) {
            try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND usage_uncached_tokens=300 AND usage_cache_read_tokens=100 AND usage_cache_write_tokens=0 AND usage_output_tokens=7", .{operation}));
        } else try std.testing.expectEqual(1, try store_testing.queryU64(storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND usage_output_tokens IS NULL", .{operation}));
        try std.testing.expect(!storage.isFenced());
    }
};

test "an item with more content than a batch holds saves each part's own text, and shares repeated ones" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "oversized-config");
            try submitTestMessage(&storage, &tmp, "oversized-input", "oversized-key", session.slice(), "wide");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var item: OversizedItem = .{};
            try item.build();
            defer item.deinit();
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const rounds = storage.testing_content_work.rounds;
            try item.settle(&storage, &tmp, binding, null);
            // The item's lookups ride its batches' rounds, not one round
            // per part.
            if (!case.rerun) try std.testing.expectEqual(4, storage.testing_content_work.rounds - rounds);
            const operation = binding.operation_id;
            for (0..OversizedItem.parts) |index| {
                var buffer: [16]u8 = undefined;
                const text = OversizedItem.text(index, &buffer);
                const digest = protocol.contentDigest(text);
                // Each part, in order, names a private row of its own text.
                try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_part p JOIN content c ON c.content_id=p.text_content_id " ++
                    "WHERE p.operation_id=?1 AND p.item_ordinal=0 AND p.part_ordinal=?2 AND p.part_kind=3 AND p.text_length IS NULL AND c.digest=?3 AND c.byte_length=?4 AND c.private=1", .{ operation, index, store_testing.Blob{ .bytes = &digest }, text.len }));
                var reader: ContentReader = undefined;
                reader.open(try content_domain.openContentIdentity(&storage, .{ .digest = digest, .length = text.len }, true));
                defer reader.close();
                var bytes: [16]u8 = undefined;
                try std.testing.expectEqualStrings(text, bytes[0..try reader.read(0, &bytes)]);
            }
            // Repeated texts share a row; every part's bag is one row.
            try std.testing.expectEqual(OversizedItem.parts - 2, try store_testing.queryU64(&storage, "SELECT count(DISTINCT text_content_id) FROM model_output_part WHERE operation_id=?1 AND item_ordinal=0", .{operation}));
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(DISTINCT extras_content_id) FROM model_output_part WHERE operation_id=?1 AND item_ordinal=0", .{operation}));
            try std.testing.expectEqual(OversizedItem.parts + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_part WHERE operation_id=?1", .{operation}));
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item i JOIN content c ON c.content_id=i.extras_content_id " ++
                "WHERE i.operation_id=?1 AND i.item_ordinal=0 AND i.part_count=?2 AND i.message_content_id IS NULL AND c.private=1", .{ operation, OversizedItem.parts }));
            try std.testing.expectEqual(2, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item WHERE operation_id=?1", .{operation}));
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN model_output_item i ON i.operation_id=e.source_operation_id AND i.item_ordinal=e.source_item_ordinal " ++
                "WHERE e.source_operation_id=?1 AND e.source_item_ordinal=1 AND i.session_position=e.session_position", .{operation}));
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code IS NOT NULL AND output_item_count=2", .{operation}));
            // 298 texts, the shared part bag, the item's bag, and the
            // answer's text and bags, as the settlement saved them on main.
            try std.testing.expectEqual(contents + 302, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "an item with more content than a batch holds saves nothing when a part after the batch's own fails" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "oversized-fail-config");
            try submitTestMessage(&storage, &tmp, "oversized-fail-input", "oversized-fail-key", session.slice(), "wide");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var item: OversizedItem = .{};
            try item.build();
            defer item.deinit();
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            // Part 295's text is past the 257 identities the first batch holds.
            try std.testing.expectError(error.OutputSourceChanged, item.settle(&storage, &tmp, binding, 295));
            try std.testing.expect(storage.isFenced());
            try std.testing.expectEqual(contents, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(0, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_part", .{}));
            try std.testing.expectEqual(0, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code IS NULL", .{binding.operation_id}));
        }
    }.run);
}

test "an item cut across settlement batches saves what the same output saves whole" {
    // Each output's rounds are the facts round, then one per batch after
    // the first, then the commit. A batch holds 257 identities: a part's
    // bag or summary text, an item's bag, a message's text, an empty
    // answer.
    const Case = struct { name: []const u8, output: OversizedItem, rounds: u16 };
    const cases = [_]Case{
        // 600 part bags, the item's bag and its text: cut after part 256,
        // then after part 513, then the rest to the item. Its text length
        // spans three batches.
        .{ .name = "an answer cut twice", .output = .{ .items = &.{.{ .message = .{ .parts = 600 } }}, .answer = 0 }, .rounds = 4 },
        .{ .name = "an empty answer cut twice", .output = .{ .items = &.{.{ .message = .{ .parts = 600, .blank = true } }}, .answer = 0, .empty_answer = true }, .rounds = 4 },
        // 255 part bags, the item's bag and its text fill the batch: only
        // the empty answer's identity does not fit, so the item is cut
        // after its last part.
        .{ .name = "an empty answer cut only for its empty text", .output = .{ .items = &.{.{ .message = .{ .parts = 255, .blank = true } }}, .answer = 0, .empty_answer = true }, .rounds = 3 },
        // A web search call alone, the reasoning item cut once, then a
        // failed search, the answer and the usage record.
        .{ .name = "web search calls around a later reasoning item, then usage", .output = .{ .items = &.{ .find_in_page, .{ .reasoning = OversizedItem.parts }, .failed_search, .done }, .answer = 3, .usage = true }, .rounds = 5 },
        // The empty part bag and 256 texts, twice, then the rest.
        .{ .name = "reasoning cut twice", .output = .{ .items = &.{ .{ .reasoning = 600 }, .done }, .answer = 1 }, .rounds = 5 },
        .{ .name = "a later answer cut once, then a web search call and usage", .output = .{ .items = &.{ .{ .reasoning = 5 }, .{ .message = .{ .parts = OversizedItem.parts } }, .find_in_page }, .answer = 1, .usage = true }, .rounds = 5 },
    };
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (cases) |entry| {
                errdefer std.debug.print("case: {s}\n", .{entry.name});
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "cut-config");
                try submitTestMessage(&storage, &tmp, "cut-input", "cut-key", session.slice(), "wide");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var output = entry.output;
                try output.build();
                defer output.deinit();
                const rounds = storage.testing_content_work.rounds;
                try output.settle(&storage, &tmp, binding, null);
                if (!case.rerun) try std.testing.expectEqual(entry.rounds, storage.testing_content_work.rounds - rounds);
                try output.expectSaved(&storage, binding.operation_id);
            }
        }
    }.run);
}

test "a success settlement sends its rows twenty statements a pass" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Only a batching engine sends passes, and a rerun repeats them.
            if (case.engine != .mysql or case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "settlement-pass-config");
            try submitTestMessage(&storage, &tmp, "settlement-pass-input", "settlement-pass-key", session.slice(), "passes");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const rounds = storage.testing_content_work.rounds;
            const before = RoundMeter.QueryShape.snapshot(&storage);
            // Sixteen messages: the facts round, then one round that writes
            // each message's text and bag rows, their bytes, its item and its
            // entry, resolves the Operation, closes its Turn and commits.
            try settleMessagesForTesting(&storage, &tmp, binding, 16, false, null);
            const shape = RoundMeter.QueryShape.snapshot(&storage).since(before);
            try std.testing.expectEqual(@as(u16, 2), storage.testing_content_work.rounds - rounds);
            // A settlement's queue holds twenty statements a pass, where a
            // write's holds twelve: the passes main sent for these rows.
            try std.testing.expectEqual(@as(u64, 7), shape.access_passes);
            try std.testing.expectEqual(shape.expected(), shape.queries);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "valid and rejected call populations grow independently" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const population = 128;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var valid_item_storage: [population][24]u8 = undefined;
            var valid_call_storage: [population][24]u8 = undefined;
            var rejected_item_storage: [population][24]u8 = undefined;
            var rejected_call_storage: [population][24]u8 = undefined;
            var valid_calls: [population]TestingCall = undefined;
            var rejected_calls: [population]TestingCall = undefined;
            for (0..population) |index| {
                const valid_item = try std.fmt.bufPrint(&valid_item_storage[index], "valid-item-{d}", .{index});
                const valid_call = try std.fmt.bufPrint(&valid_call_storage[index], "valid-call-{d}", .{index});
                valid_calls[index] = .{
                    .item_id = valid_item,
                    .name = "bash",
                    .encoded_call_id = valid_call,
                    .decoded_call_id = valid_call,
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                };
                const rejected_item = try std.fmt.bufPrint(&rejected_item_storage[index], "rejected-item-{d}", .{index});
                const rejected_call = try std.fmt.bufPrint(&rejected_call_storage[index], "rejected-call-{d}", .{index});
                rejected_calls[index] = .{
                    .item_id = rejected_item,
                    .name = "unknown",
                    .encoded_call_id = rejected_call,
                    .decoded_call_id = rejected_call,
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
            }

            const allocated_session_0 = try configureTestSession(&storage, "valid-growth-config");
            try submitTestMessage(&storage, &tmp, "valid-growth-message", "valid-growth-message", allocated_session_0.slice(), "valid");
            const valid_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, valid_binding, "valid-growth-metadata", &valid_calls);
            try std.testing.expectEqual(@as(u64, population), (try storage.inspectSessionForTesting(allocated_session_0.slice())).action_count);
            const valid_report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
            defer std.testing.allocator.free(valid_report_bytes);
            const valid_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, valid_report_bytes, .{ .ignore_unknown_fields = true });
            defer valid_report.deinit();
            try std.testing.expectEqual(@as(usize, population), valid_report.value.actions.unresolved.len);

            const allocated_session_1 = try configureTestSession(&storage, "rejected-growth-config");
            try submitTestMessage(&storage, &tmp, "rejected-growth-message", "rejected-growth-message", allocated_session_1.slice(), "rejected");
            const rejected_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, rejected_binding, "rejected-growth-metadata", &rejected_calls);
            const rejected = try storage.inspectSessionForTesting(allocated_session_1.slice());
            try std.testing.expectEqual(@as(u64, 0), rejected.action_count);
            try std.testing.expectEqual(@as(u64, population), rejected.rejected_call_count);
            const rejected_report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_1.slice(), 1024 * 1024);
            defer std.testing.allocator.free(rejected_report_bytes);
            const rejected_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, rejected_report_bytes, .{ .ignore_unknown_fields = true });
            defer rejected_report.deinit();
            try std.testing.expectEqual(@as(usize, population), rejected_report.value.rejected_calls.items.len);
        }
    }.run);
}

test "model rejection diagnostic is atomic Attempt-bound provenance not Turn output" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Fault = enum { stale, import, commit };
            for ([_]Fault{ .stale, .import, .commit }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                const detail = "{\"reason\":\"UnsupportedMessagePhase\",\"stage\":\"item\",\"byte_offset\":\"37\",\"output_index\":1}";
                const request_id = if (fault == .import) "" else "request-\"quoted\"\\path";
                var failure: ModelFailure = .{ .rejected = .{ .code = "unsupported_provider_output", .diagnostic = detail, .request_id = .{}, .report = "" } };
                try failure.rejected.request_id.set(request_id);
                var binding: AttemptBinding = undefined;
                var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
                var original_content: u64 = 0;
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    session = try configureTestSession(&storage, "diagnostic-config");
                    try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
                    binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    original_content = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                    var delivered = binding;
                    if (fault == .stale) delivered.attempt_ordinal += 1;
                    try std.testing.expectError(switch (fault) {
                        .stale => error.StaleAttemptBinding,
                        .import => error.InjectedContentImportFailure,
                        .commit => error.InjectedCommitFailure,
                    }, storage.settleModelAttemptFailure(delivered, failure, .ordinary, .{
                        .content_import = fault == .import,
                        .before_commit = fault == .commit,
                    }));
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    try std.testing.expectEqual(original_content, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code IS NOT NULL OR resolution_content_id IS NOT NULL OR request_id IS NOT NULL", .{}));
                    try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
                    defer std.testing.allocator.free(bytes);
                    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer report.deinit();
                    const full = report.value.object.get("full").?.object;
                    const operation = full.get("model_operations").?.array.items[0].object;
                    const resolution = operation.get("resolution").?.object;
                    try std.testing.expect(operation.contains("request_id"));
                    if (request_id.len == 0) {
                        try std.testing.expect(operation.get("request_id").? == .null);
                    } else {
                        try std.testing.expectEqualStrings(request_id, operation.get("request_id").?.string);
                    }
                    try std.testing.expectEqualStrings("unsupported_provider_output", resolution.get("code").?.string);
                    try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
                    try std.testing.expect(full.get("turns").?.array.items[0].object.get("outcome").?.object.get("content").? == .null);
                    try std.testing.expectEqual(@as(u64, if (request_id.len == 0) 0 else 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE request_id IS NOT NULL", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
                    try expectActivityOutcome(&storage, session.slice(), binding, .failed, "unsupported_provider_output");
                }
            }
        }
    }.run);
}

test "model rejection diagnostic cannot masquerade as assistant content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Route = enum { conversation, conversation_content, activity, activity_content };
            for ([_]Route{ .conversation, .conversation_content, .activity, .activity_content }) |route| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "diagnostic-config");
                try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .rejected = .{
                    .code = "unsupported_provider_output",
                    .diagnostic = "{\"reason\":\"UnsupportedMessagePhase\"}",
                    .request_id = .{},
                    .report = "",
                } }, .ordinary, .{});
                const healthy = try store_core.publicConversationPageForTesting(&storage, .{ .session = session });
                try std.testing.expectEqual(@as(usize, 1), healthy.count);
                try std.testing.expect(healthy.items[0].kind == .user);
                const position = try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{});
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id,recorded_at) " ++
                    "SELECT o.session_ref,2,s.next_position,3,o.turn_id,o.operation_id,0,o.resolution_content_id,1 " ++
                    "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref", .{});
                try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+1", .{});
                const result: anyerror!void = switch (route) {
                    .conversation => if (store_core.publicConversationPageForTesting(&storage, .{ .session = session })) |_| {} else |err| err,
                    .activity => if (store_core.activityPageForTesting(&storage, .{ .session = session })) |_| {} else |err| err,
                    .conversation_content => if (storage.openPublicConversationContent(&.{ .session = session, .position = position })) |value| blk: {
                        var reader: ContentReader = undefined;
                        reader.open(value);
                        reader.close();
                        break :blk {};
                    } else |err| err,
                    .activity_content => if (storage.openActivityContent(&.{ .session = session, .position = position })) |value| blk: {
                        var reader: ContentReader = undefined;
                        reader.open(value);
                        reader.close();
                        break :blk {};
                    } else |err| err,
                };
                try std.testing.expectError(error.CorruptStore, result);
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "a failed Turn's activity outcome references the provider's report" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-config");
            const report = "cyber_policy: This request has been flagged.";
            for ([_][]const u8{ report, "" }, 0..) |words, index| {
                var key: [16]u8 = undefined;
                const message = try std.fmt.bufPrint(&key, "report-{d}", .{index});
                try submitTestMessage(&storage, &tmp, message, message, session.slice(), "work");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_policy", .request_id = .{}, .report = words } }, .ordinary, .{});
                try expectActivityOutcome(&storage, session.slice(), binding, .provider_refused, "provider_policy");
                var request: protocol.ActivityPage = .{ .direction = .backward };
                try request.session.set(session.slice());
                const outcome = (try store_core.activityPageForTesting(&storage, request)).items[0].value.turn_ended;
                if (words.len == 0) {
                    // No words, no report: never an empty one.
                    try std.testing.expect(outcome.content == null);
                } else {
                    try std.testing.expectEqual(@as(u64, words.len), outcome.content.?.length);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(words), &outcome.content.?.digest);
                }
            }
        }
    }.run);
}

test "a failure whose report equals its new diagnostic saves one content row for both" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "same-words-config");
            try submitTestMessage(&storage, &tmp, "same-words-input", "same-words-message", session.slice(), "work");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const words = "provider_rejected: the same words twice";
            const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = "provider_rejected", .diagnostic = words, .request_id = .{}, .report = words } }, .ordinary, .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(before + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation o JOIN turn t ON t.operation_id=o.operation_id " ++
                "WHERE o.resolution_content_id IS NOT NULL AND o.resolution_content_id=t.outcome_content_id", .{}));
        }
    }.run);
}

test "retryable stream rejections retain only the settling Attempt diagnostic through reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const diagnostic = "{\"reason\":\"TemporaryProviderFailure\",\"stage\":\"event\",\"byte_offset\":\"6\",\"output_index\":null}";
            var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                session = try configureTestSession(&storage, "stream-retry-config");
                try submitTestMessage(&storage, &tmp, "stream-input", "stream-message", session.slice(), "retry");
                var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                for (1..5) |ordinal| {
                    try std.testing.expectEqual(@as(u64, ordinal), binding.attempt_ordinal);
                    var request_id: protocol.Bounded(256) = .{};
                    try request_id.set(if (ordinal == 4) "last-request" else "earlier-request");
                    try storage.settleModelAttemptFailure(binding, .{ .rejected = .{
                        .code = "provider_temporary_error",
                        .diagnostic = if (ordinal == 4) diagnostic else "earlier diagnostic",
                        .request_id = request_id,
                        .report = if (ordinal == 4) "server_is_overloaded: Try again later." else "earlier words",
                    } }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
                    if (ordinal < 4) {
                        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_content_id IS NOT NULL OR request_id IS NOT NULL", .{}));
                        try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL", .{});
                        binding = (try admitRetryForTesting(&storage)).?.permit.binding;
                    }
                }
            }
            var reopened: Store = undefined;
            try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
            defer reopened.close() catch unreachable;
            const bytes = try testingSessionReportWithProfile(&reopened, &tmp, session.slice(), 64 * 1024, .full);
            defer std.testing.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            const operation = parsed.value.object.get("full").?.object.get("model_operations").?.array.items[0].object;
            try std.testing.expectEqualStrings("last-request", operation.get("request_id").?.string);
            const resolution = operation.get("resolution").?.object;
            try std.testing.expectEqualStrings("retry_exhausted", resolution.get("code").?.string);
            try std.testing.expectEqualStrings(diagnostic, resolution.get("content").?.object.get("text").?.string);
            // The Turn keeps the settling Attempt's report, the provider's own words.
            const outcome = parsed.value.object.get("full").?.object.get("turns").?.array.items[0].object.get("outcome").?.object;
            try std.testing.expectEqualStrings("retry_exhausted", outcome.get("code").?.string);
            const words = "server_is_overloaded: Try again later.";
            const reference = outcome.get("content").?.object;
            try std.testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{words.len}), reference.get("bytes").?.string);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest(words), .lower), reference.get("sha256").?.string);
        }
    }.run);
}
