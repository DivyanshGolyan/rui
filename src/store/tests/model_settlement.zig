//! Model settlement Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
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
