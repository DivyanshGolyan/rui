//! Compaction Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelOperationKind = historical_domain.ModelOperationKind;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TestingHistoryCursor = shared_fixtures.TestingHistoryCursor;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;
const completeSessionStop = shared_fixtures.completeSessionStop;
const expectActivityOutcome = shared_fixtures.expectActivityOutcome;
const nextTestingItem = shared_fixtures.nextTestingItem;
const renderTestingEntry = shared_fixtures.renderTestingEntry;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const testSettings = shared_fixtures.testSettings;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingSessionReport = shared_fixtures.testingSessionReport;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "compaction pressure uses provider usage appended input and complete call result groups" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (0..3) |scenario| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("1");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{
                    .{ .item_id = "item-a", .name = "unknown", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                    .{ .item_id = "item-b", .name = "unknown", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                };
                try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &calls, .{}, if (scenario == 0)
                    "{\"input_tokens\":99999,\"output_tokens\":1,\"details\":{\"input_tokens\":0}}"
                else
                    "{\"input_tokens\":9,\"output_tokens\":1,\"details\":{\"input_tokens\":1000000}}");
                var appended: [5000]u8 = @splat('x');
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), if (scenario == 2) &appended else "later");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const purpose: ModelOperationKind = if (scenario == 1) .assistant_response else .compaction;
                try std.testing.expectEqual(purpose, try storage.modelOperationKind(next));
                {
                    var view: HistoricalView = undefined;
                    storage.openHistoricalView(next, &view);
                    defer view.close();
                    var cursor: TestingHistoryCursor = .{};
                    try std.testing.expect((try view.coverage()).anchor == null);
                    try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    for (0..2) |_| try std.testing.expectEqual(HistoricalEntryKind.provider_output, (try cursor.next(&view)).?.kind);
                    try std.testing.expectEqual(HistoricalEntryKind.tool_results, (try cursor.next(&view)).?.kind);
                    for ([_][]const u8{ "call-a", "call-b" }) |expected| {
                        const result = (try view.nextToolResult()).?;
                        var reader: HistoricalReader = undefined;
                        try view.openContent(result.call_id, &reader);
                        defer reader.close();
                        var bytes: [64]u8 = undefined;
                        const count = try reader.read(0, &bytes);
                        try std.testing.expectEqualStrings(expected, bytes[0..count]);
                    }
                    try std.testing.expect((try view.nextToolResult()) == null);
                    if (scenario == 1) try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    try std.testing.expect((try cursor.next(&view)) == null);
                }
                if (purpose == .compaction) {
                    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                    try settleCompactionForTesting(&storage, &tmp, next, &.{.compaction});
                    const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    var view: HistoricalView = undefined;
                    storage.openHistoricalView(successor, &view);
                    defer view.close();
                    var cursor: TestingHistoryCursor = .{};
                    const anchor = (try view.coverage()).anchor.?;
                    for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .tool_results }) |kind|
                        try std.testing.expectEqual(kind, (try cursor.next(&view)).?.kind);
                    while (try view.nextToolResult()) |_| {}
                    const base_entry = (try cursor.next(&view)).?;
                    try std.testing.expectEqual(anchor, base_entry.position);
                    try std.testing.expectEqual(HistoricalEntryKind.provider_output, base_entry.kind);
                    try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    try std.testing.expect((try cursor.next(&view)) == null);
                    if (scenario == 0) {
                        // Accepted suffix without usage must not revive the large
                        // pre-base usage on the next admission.
                        try settleCallsForTesting(&storage, &tmp, successor, "suffix-output", &calls);
                        try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "small suffix");
                        const after_base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(after_base));
                    }
                }
            }
        }
    }.run);
}

test "compaction overflow admits a new Operation without losing applied input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "compact-config");
            try submitTestMessage(&storage, &tmp, "compact-input", "input", session.slice(), "keep all input");
            const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const detail = "{\"reason\":\"ContextOverflow\",\"stage\":\"response\",\"byte_offset\":\"0\",\"output_index\":null}";
            var failure: ModelFailure = .{ .rejected = .{ .code = "context_overflow", .diagnostic = detail, .request_id = .{}, .report = "" } };
            try failure.rejected.request_id.set("compact-overflow-request");
            try storage.settleModelAttemptFailure(original, failure, .context_overflow, .{});
            const next = (try storage.admitNextModelAttempt(.{})) orelse return error.MissingCompaction;
            try std.testing.expect(next.permit.binding.operation_id != original.operation_id);
            try std.testing.expectEqual(original.turn_id, next.permit.binding.turn_id);
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next.permit.binding));
            var view: HistoricalView = undefined;
            storage.openHistoricalView(next.permit.binding, &view);
            defer view.close();
            try std.testing.expectEqual(ModelOperationKind.compaction, (try testSettings(&view)).operation);
            try std.testing.expect((try view.coverage()).anchor == null);
            const input = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
            try std.testing.expect((try nextTestingItem(&view, input.position)) == null);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
            defer std.testing.allocator.free(bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer report.deinit();
            const resolution = report.value.object.get("full").?.object.get("model_operations").?.array.items[0].object.get("resolution").?.object;
            try std.testing.expectEqualStrings("context_overflow", resolution.get("code").?.string);
            try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
            try std.testing.expectEqual(original.operation_id, try store_testing.queryU64(&storage, "SELECT operation_id FROM model_operation WHERE request_id='compact-overflow-request' AND resolution_code='context_overflow' AND last_failure_code='context_overflow'", .{}));
        }
    }.run);
}

test "compaction success retains host inputs and ordered anchor suffix across reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "compact-config");
            try submitTestMessage(&storage, &tmp, "compact-input", "input", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try submitTestMessage(&storage, &tmp, "compact-arrival", "arrival", session.slice(), "later");
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{.message}));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .function_call }));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .compaction }));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .web_search_call }));
            try std.testing.expect(!storage.isFenced());
            try settleCompactionForTesting(&storage, &tmp, compact, &.{ .reasoning, .compaction, .message });
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            try std.testing.expectEqual(@as(usize, 1), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).action_count);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            // Accepted compaction message items remain private, without a required
            // assistant Conversation entry, across every public inventory on reopen.
            try std.testing.expectEqual(@as(usize, 1), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = request.session });
            for (activity.items[0..activity.count]) |item| try std.testing.expect(item.value != .assistant);
            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            var parsed_report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer parsed_report.deinit();
            for (parsed_report.value.object.get("full").?.object.get("conversation").?.array.items) |entry|
                try std.testing.expect(!std.mem.eql(u8, "assistant", entry.object.get("kind").?.string));
            const compaction_message = try store_testing.queryU64(&storage, "SELECT session_position FROM model_output_item WHERE item_kind=2", .{});
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = compaction_message }));
            try std.testing.expect(!storage.isFenced());
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(compact.turn_id, successor.turn_id);
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
            {
                var view: HistoricalView = undefined;
                storage.openHistoricalView(successor, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_][]const u8{
                    "original",
                    "reasoning{\"id\":\"reasoning-0\",\"summary\":[],\"encrypted_content\":\"opaque\"}",
                    "compaction{\"id\":\"compaction-1\",\"encrypted_content\":\"opaque\"}",
                    "message{\"id\":\"message-2\"}|content.output_text=",
                    "later",
                }, 0..) |expected, index| {
                    const entry = (try cursor.next(&view)).?;
                    if (index == 2) try std.testing.expectEqual(anchor, entry.position);
                    var bytes: [512]u8 = undefined;
                    try std.testing.expectEqualStrings(expected, try renderTestingEntry(&view, entry, &bytes));
                }
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            // New applied input permits one new compaction; its unchanged successor
            // must terminalize irreducible overflow rather than loop.
            try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const second_base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, second_base, &.{.compaction});
            const exhausted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                storage.openHistoricalView(exhausted, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user }) |kind|
                    try std.testing.expectEqual(kind, (try cursor.next(&view)).?.kind);
                try std.testing.expectEqual(anchor, (try cursor.next(&view)).?.position);
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            try storage.settleModelAttemptFailure(exhausted, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            // Recovery eligibility changes the Turn outcome, never the failure fact.
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='context_overflow'", .{}));
            const observation = try store_testing.observeCommandForTesting(&storage, "input");
            try std.testing.expectEqualStrings("ResourceExceeded", observation.kind.message.?.queue.?.state.failed.code.slice());
        }
    }.run);
}

test "explicit compaction thresholds and frozen retry survive reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Representative reasoning models, plus unlisted bindings below.
            const supported_ids = [_][]const u8{ "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5" };
            for (supported_ids ++ [_][]const u8{ "model-a", "gpt-6-luna-alias" }) |model| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try completeConfiguration("config", "", workspace, model);
                // D111: the client supplies tokens even when it chooses 90%.
                const expected: ?u64 = model_capability.contextWindow(@import("../../model_catalog.zig").shipped, model) * product_defaults.compaction_trigger_percent / 100;
                var threshold: [20]u8 = undefined;
                try configure.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&threshold, "{d}", .{expected.?}));
                const created_session_0_reply = try storage.configure(&configure, .{});
                try std.testing.expect(created_session_0_reply == .accepted);
                const created_session_0 = created_session_0_reply.accepted.session;
                const initial = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(expected, initial.compaction_trigger);
                try std.testing.expectEqual(@as(u64, 0), initial.output_reservation);
                try std.testing.expect(initial.compaction_trigger_override == expected and initial.output_reservation_override == null);
                try submitTestMessage(&storage, &tmp, "one", "one", created_session_0.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("override");
                try patch.session.set(created_session_0.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("10");
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("8");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                const selected = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(@as(?u64, 10), selected.compaction_trigger_override);
                try std.testing.expectEqual(@as(?u64, 8), selected.output_reservation_override);
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
                try std.testing.expectEqual(first.operation_id, retry.operation_id);
                {
                    var view: HistoricalView = undefined;
                    storage.openHistoricalView(retry, &view);
                    defer view.close();
                    var frozen: HistoricalSettings = undefined;
                    try view.settings(&frozen);
                    try std.testing.expectEqual(expected, frozen.compaction_trigger);
                    try std.testing.expectEqual(@as(u64, 0), frozen.output_reservation);
                }
                try patch.key.set("inherit");
                patch.configuration.compaction_trigger.state = .explicit_null;
                patch.configuration.output_reservation.state = .explicit_null;
                const refused_clear = try storage.configure(&patch, .{});
                try std.testing.expect(refused_clear == .rejected);
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, refused_clear.rejected.code);
                try patch.key.set("explicit-threshold");
                patch.configuration.compaction_trigger = configure.configuration.compaction_trigger;
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                const reset = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(expected, reset.compaction_trigger);
                try std.testing.expectEqual(@as(u64, 0), reset.output_reservation);
                try std.testing.expect(reset.compaction_trigger_override == expected and reset.output_reservation_override == null);
                {
                    const report = try testingSessionReportWithProfile(&storage, &tmp, created_session_0.slice(), 1024 * 1024, .full);
                    defer std.testing.allocator.free(report);
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"output_reservation_override\":null") != null);
                    // D111: revision one records the client's explicit threshold.
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":null") == null);
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":\"10\",\"output_reservation\":\"8\"") != null);
                }
                try storage.settleModelAttemptFailure(retry, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compact));
                try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                // Overflow recovery compacts once; unchanged context cannot
                // authorize another compaction.
                try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try expectActivityOutcome(&storage, created_session_0.slice(), successor, .context_full, "ResourceExceeded");
            }
        }
    }.run);
}

/// The Current report's `context_estimate`, or null.
fn testingContextEstimate(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?u64 {
    const report = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(report);
    const key = "\"context_estimate\":";
    const at = (std.mem.indexOf(u8, report, key) orelse return error.TestUnexpectedResult) + key.len;
    if (std.mem.startsWith(u8, report[at..], "null,")) return null;
    const end = std.mem.indexOfScalarPos(u8, report, at + 1, '"') orelse return error.TestUnexpectedResult;
    return try std.fmt.parseInt(u64, report[at + 1 .. end], 10);
}

test "compaction exact threshold zero reservation and integer usage fallback" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_][]const u8{
                "{\"input_tokens\":999,\"output_tokens\":0}",
                "{\"input_tokens\":1000,\"output_tokens\":0}",
                "{\"input_tokens\":1000.5,\"output_tokens\":0}",
                "{\"input_tokens\":1000e0,\"output_tokens\":0}",
                "{\"input_tokens\":-1000,\"output_tokens\":0}",
                "{\"input_tokens\":0,\"output_tokens\":0}",
                "{\"input_tokens\":18446744073709551616,\"output_tokens\":0}",
                "{\"input_tokens\":1000000,\"output_tokens\":0}",
                "{\"input_tokens\":9223372036854775807,\"output_tokens\":0}",
                "{\"input_tokens\":9223372036854775807,\"output_tokens\":9223372036854775807}",
                "{\"input_tokens\":1000,\"input_tokens_details\":{\"cached_tokens\":600},\"output_tokens\":0}",
            }, 0..) |usage, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                // An unlisted model without an override compacts at the share of
                // the small window Rui assumes for it.
                if (index == 7) patch.configuration.compaction_trigger.state = .omitted;
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("0");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                // A Session's first call never compacts, so nothing is compared.
                try std.testing.expectEqual(@as(?u64, null), try testingContextEstimate(&storage, &tmp, session.slice()));
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "");
                try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &.{}, .{}, usage);
                if (index == 9) {
                    // The counts are stored as reported; their sum passes SQLite's
                    // signed range, and pressure saturates instead of wrapping.
                    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), try store_testing.queryU64(&storage, "SELECT usage_output_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                }
                if (index == 10) {
                    try std.testing.expectEqual(@as(u64, 400), try store_testing.queryU64(&storage, "SELECT usage_uncached_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                    try std.testing.expectEqual(@as(u64, 600), try store_testing.queryU64(&storage, "SELECT usage_cache_read_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                }
                // The Current report's estimate is the pressure the next admission
                // compares: at or past the trigger exactly when it compacts.
                const compacts = index == 1 or index >= 7;
                const estimate = (try testingContextEstimate(&storage, &tmp, session.slice())).?;
                const trigger: u64 = if (index == 7) model_capability.compactionPolicy("model-a", null, null).compaction_trigger else 1000;
                try std.testing.expectEqual(compacts, estimate >= trigger);
                if (index == 0) try std.testing.expectEqual(@as(u64, 999), estimate);
                if (index == 7) try std.testing.expectEqual(@as(u64, 1000000), estimate);
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(if (compacts) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
                // The call after a compaction answers whatever the pressure, so
                // nothing is compared while one runs.
                if (compacts) try std.testing.expectEqual(@as(?u64, null), try testingContextEstimate(&storage, &tmp, session.slice()));
            }
        }
    }.run);
}

test "an admission weighs uncovered bytes in its write, and admits the compaction they call for" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Usage leaves ten tokens of room under the trigger: the waiting
            // Message's bytes decide the purpose, four to a token.
            var seen = [_]bool{ false, false };
            const filler: [64]u8 = @splat('x');
            for ([_]usize{ 0, 32, 36, 39, 40, 41, 44, 64 }) |length| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("0");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), filler[0..length]);
                try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &.{}, .{}, "{\"input_tokens\":990,\"output_tokens\":0}");
                // The report reads the bytes and compares; admission reads
                // none and must agree at every count.
                const compacts = (try testingContextEstimate(&storage, &tmp, session.slice())).? >= 1000;
                seen[@intFromBool(compacts)] = true;
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(if (compacts) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
            }
            try std.testing.expect(seen[0] and seen[1]);
        }
    }.run);
}

test "compaction pressure anchors only usage of the selected replay recipe across model visits" {
    try store_testing.forEachEngine(struct {
        const Base = enum { none, compatible, incompatible };
        const usage = "{\"input_tokens\":1,\"output_tokens\":0}";

        fn model(storage: *Store, session: []const u8, key: []const u8, name: []const u8, trigger: []const u8) !void {
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set(key);
            try patch.session.set(session);
            patch.configuration.model.state = .value;
            try patch.configuration.model.value.set(name);
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set(trigger);
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("0");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
        }

        fn answer(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, saved_usage: bool) !void {
            const calls = [_]TestingCall{.{ .item_id = "small", .name = "unknown", .encoded_call_id = "small-call", .decoded_call_id = "small-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTestingWithFaults(storage, tmp, binding, "small-output", &calls, .{}, if (saved_usage) usage else null);
        }

        fn compact(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, key: []const u8, saved_usage: bool) !void {
            try submitTestMessage(storage, tmp, key, key, session, "compact this prefix");
            const overflowing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(overflowing));
            try storage.settleModelAttemptFailure(overflowing, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(base));
            try settleCompactionForTesting(storage, tmp, base, &.{.compaction});
            // This usage measures the newly selected base, unlike the usage of
            // the compaction request which produced it.
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try answer(storage, tmp, successor, saved_usage);
        }

        fn run(store_case: *store_testing.Case) !void {
            for ([_]Base{ .none, .compatible, .incompatible }) |base| {
                for ([_]bool{ false, true }) |returning| {
                    for ([_]bool{ false, true }) |saved_usage| {
                        errdefer std.debug.print("base={s}, returning={}, saved_usage={}\n", .{ @tagName(base), returning, saved_usage });
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        var storage: Store = undefined;
                        try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                        defer storage.close() catch unreachable;
                        const session = try configureTestSession(&storage, "config");
                        // First visit: start in B, then visit A once. Return:
                        // start in A, visit B, then switch back to A.
                        try model(&storage, session.slice(), "seed-model", if (returning) "model-a" else "model-b", "1000000");
                        try submitTestMessage(&storage, &tmp, "seed", "seed", session.slice(), "original");
                        const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        const prefix: [12000]u8 = @splat('x');
                        const calls = [_]TestingCall{.{ .item_id = "large", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = &prefix, .decoded_arguments = &prefix }};
                        try settleCallsForTestingWithFaults(&storage, &tmp, first, "large-output", &calls, .{}, if (saved_usage) usage else null);
                        if (returning and base != .none) try compact(&storage, &tmp, session.slice(), "a-base", saved_usage);
                        if (returning) {
                            try model(&storage, session.slice(), "visit-b", "model-b", "1000000");
                            try submitTestMessage(&storage, &tmp, "b", "b", session.slice(), "visit B");
                            const b = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(b));
                            try answer(&storage, &tmp, b, saved_usage);
                        }
                        if (base == .incompatible) try compact(&storage, &tmp, session.slice(), "b-base", saved_usage);
                        if (!returning and base == .compatible) {
                            try model(&storage, session.slice(), "first-a", "model-a", "1000000");
                            try compact(&storage, &tmp, session.slice(), "a-base", saved_usage);
                        }
                        try model(&storage, session.slice(), "requested-a", "model-a", "1000");
                        try submitTestMessage(&storage, &tmp, "next", "next", session.slice(), "next");
                        const compacts = base != .compatible and !(base == .none and returning and saved_usage);
                        // Both public readers of pressure must agree. In the
                        // A-base -> B-base -> A case, the restored large prefix
                        // cannot be hidden behind A's compact-recipe usage.
                        const estimate = (try testingContextEstimate(&storage, &tmp, session.slice())).?;
                        try std.testing.expectEqual(compacts, estimate >= 1000);
                        const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try std.testing.expectEqual(if (compacts) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
                        var view: HistoricalView = undefined;
                        storage.openHistoricalView(next, &view);
                        defer view.close();
                        try std.testing.expectEqual(base == .compatible, (try view.coverage()).anchor != null);
                    }
                }
            }
        }
    }.run);
}

test "compaction pressure uses the latest accepted output even without usage" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            for ([_]struct { usage: ?[]const u8, usable: bool }{
                .{ .usage = null, .usable = false },
                .{ .usage = "{\"total_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"total_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1}", .usable = false },
                .{ .usage = "{\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":null}", .usable = false },
                .{ .usage = "{\"input_tokens\":null,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":-1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":9223372036854775808}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1}", .usable = true },
                .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999}", .usable = false },
                .{ .usage = "{\"total_tokens\":1.5,\"input_tokens\":0,\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":2,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":2}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":null,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":null,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":null}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1.5,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_\\u0074okens\":2,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_\\u0074okens\":2}", .usable = false },
                .{ .usage = "{\"input_tokens\":99999,\"input_tokens\":99999,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":99999,\"output_tokens\":99999}", .usable = false },
                .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999,\"input_tokens\":null,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":99999,\"total_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":1},\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"details\":{\"input_tokens\":99999,\"output_tokens\":99999},\"output_tokens\":0}", .usable = true },
            }) |case| {
                for ([_]enum { host_input, provider_output, small }{ .host_input, .provider_output, .small }) |context| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try configureTestSession(&storage, "config");
                    var patch: wire_request.ConfigureCommand = .{};
                    try patch.key.set("heuristics");
                    try patch.session.set(session.slice());
                    patch.configuration.compaction_trigger.state = .value;
                    try patch.configuration.compaction_trigger.value.set("1000");
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                    const original: [4000]u8 = @splat('x');
                    try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), if (context == .host_input) &original else "small input");
                    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                    try settleCallsForTestingWithFaults(&storage, &tmp, first, "older-output", &calls, .{}, "{\"input_tokens\":1,\"output_tokens\":0}");
                    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "small suffix");
                    const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(second));
                    var latest_calls = calls;
                    if (context == .provider_output) {
                        latest_calls[0].encoded_arguments = &original;
                        latest_calls[0].decoded_arguments = &original;
                    }
                    try settleCallsForTestingWithFaults(&storage, &tmp, second, "latest-output", &latest_calls, .{}, case.usage);
                    try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "small suffix");
                    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expectEqual(if (case.usable or context == .small) ModelOperationKind.assistant_response else ModelOperationKind.compaction, try storage.modelOperationKind(next));
                }
            }
        }
    }.run);
}

test "compaction soft trigger freezes settings before selecting arrivals and instructions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "pending");
            const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(compact, &view);
            defer view.close();
            var frozen: HistoricalSettings = undefined;
            try view.settings(&frozen);
            try std.testing.expectEqual(ModelOperationKind.compaction, frozen.operation);
            try std.testing.expectEqual(@as(u64, 1), frozen.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 1), frozen.output_reservation);
            try std.testing.expect((try view.coverage()).anchor == null);
            const input = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
            try std.testing.expect((try nextTestingItem(&view, input.position)) == null);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            try patch.key.set("updated-heuristics");
            try patch.configuration.compaction_trigger.value.set("999");
            try patch.configuration.output_reservation.value.set("8");
            patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", "later instruction");
            defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), (try testSettings(&view)).compaction_trigger);
            try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "arrival");
            try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var later: HistoricalView = undefined;
            storage.openHistoricalView(successor, &later);
            defer later.close();
            var settings: HistoricalSettings = undefined;
            try later.settings(&settings);
            try std.testing.expectEqual(ModelOperationKind.assistant_response, settings.operation);
            try std.testing.expectEqual(@as(u64, 999), settings.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 8), settings.output_reservation);
            var cursor: TestingHistoryCursor = .{};
            const anchor = (try later.coverage()).anchor.?;
            for ([_]HistoricalEntryKind{ .user, .provider_output, .user, .user, .instruction }) |kind| {
                const entry = (try cursor.next(&later)).?;
                try std.testing.expectEqual(kind, entry.kind);
                if (kind == .provider_output) try std.testing.expectEqual(anchor, entry.position);
            }
            try std.testing.expect((try cursor.next(&later)) == null);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            const replay = try storage.configure(&patch, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            var omitted: wire_request.ConfigureCommand = .{};
            try omitted.key.set("omitted-heuristics");
            try omitted.session.set(session.slice());
            try std.testing.expect(try storage.configure(&omitted, .{}) == .accepted);
            const observed = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(@as(u64, 999), observed.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 8), observed.output_reservation);
            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(report);
            try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":\"999\",\"context_estimate\":\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, report, "\",\"output_reservation\":\"8\"") != null);
            for ([_][]const u8{ "0", "", "-1", "9223372036854775808", "+1", "1.5", "1_000", " 1", "١" }, 0..) |invalid, index| {
                var invalid_patch: wire_request.ConfigureCommand = .{};
                var key: [32]u8 = undefined;
                try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-heuristic-{d}", .{index}));
                try invalid_patch.session.set(session.slice());
                invalid_patch.configuration.compaction_trigger.state = .value;
                try invalid_patch.configuration.compaction_trigger.value.set(invalid);
                const rejected = try storage.configure(&invalid_patch, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, rejected.rejected.code);
                try std.testing.expectEqual(observed.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
                if (!std.mem.eql(u8, invalid, "0")) {
                    try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-reserve-{d}", .{index}));
                    invalid_patch.configuration.compaction_trigger.state = .omitted;
                    invalid_patch.configuration.output_reservation.state = .value;
                    try invalid_patch.configuration.output_reservation.value.set(invalid);
                    const reserve_rejected = try storage.configure(&invalid_patch, .{});
                    try std.testing.expect(reserve_rejected == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_output_reservation, reserve_rejected.rejected.code);
                    try std.testing.expectEqual(observed.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
                }
            }
        }
    }.run);
}

test "compaction failed and unresolved candidates preserve the accepted base" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{ .reasoning, .compaction, .message });
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
            const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(assistant, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const candidate = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                storage.openHistoricalView(candidate, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user }, 0..) |kind, index| {
                    const entry = (try cursor.next(&view)).?;
                    try std.testing.expectEqual(kind, entry.kind);
                    if (index == 2) try std.testing.expectEqual(anchor, entry.position);
                }
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, candidate, &.{}));
            try storage.settleModelAttemptFailure(candidate, .{ .uncorrelated = "bad_compaction" }, .ordinary, .{});
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "new turn");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            const anchor = (try view.coverage()).anchor.?;
            for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user, .user }, 0..) |kind, index| {
                const entry = (try cursor.next(&view)).?;
                try std.testing.expectEqual(kind, entry.kind);
                if (index == 2) try std.testing.expectEqual(anchor, entry.position);
            }
            try std.testing.expect((try cursor.next(&view)) == null);
        }
    }.run);
}

test "compaction selected newest base corruption fences rather than using an older base" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { payload, anchor, tail }{ .payload, .anchor, .tail }) |corruption| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
                const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(assistant, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const newest = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, newest, &.{ .compaction, .message });
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const newest_operation = try store_testing.queryU64(&storage, "SELECT max(operation_id) FROM model_output_item", .{});
                switch (corruption) {
                    .anchor => try store_testing.exec(&storage, "DELETE FROM model_output_item WHERE operation_id=?1 AND item_kind=4", .{newest_operation}),
                    .tail => try store_testing.exec(&storage, "DELETE FROM model_output_item WHERE operation_id=?1 AND item_kind=2", .{newest_operation}),
                    .payload => try store_testing.zeroContent(&storage, "SELECT extras_content_id FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4"),
                }
                var view: HistoricalView = undefined;
                storage.openHistoricalView(next, &view);
                defer view.close();
                if (corruption != .payload) {
                    try std.testing.expectError(error.CorruptStore, view.coverage());
                } else {
                    const anchor = (try view.coverage()).anchor.?;
                    const selected = (try nextTestingItem(&view, anchor - 1)).?;
                    try std.testing.expectEqual(anchor, selected.position);
                    var reader: HistoricalReader = undefined;
                    try view.openContent((try view.openOutput(selected.position)).bag.?, &reader);
                    defer reader.close();
                    var bytes: [4096]u8 = undefined;
                    try std.testing.expectError(error.CorruptStore, reader.read(0, &bytes));
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "compaction repeated overflow consumes fixed pending prefix without a proactive loop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |with_base| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (with_base) {
                    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                    const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    // A new bound input after the base makes another recovery necessary.
                    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "bound suffix");
                    try settleCompactionForTesting(&storage, &tmp, assistant, &.{.reasoning});
                    const suffix = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try storage.settleModelAttemptFailure(suffix, .{ .uncorrelated = "network" }, .ordinary, .{});
                } else {
                    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "network" }, .ordinary, .{});
                }
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "fixed pending prefix");
                const proactive = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(proactive));
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                try storage.settleModelAttemptFailure(proactive, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
                try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const recovery = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(recovery));
                try storage.settleModelAttemptFailure(recovery, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                const observation = try store_testing.observeCommandForTesting(&storage, "pending");
                try std.testing.expectEqualStrings("ResourceExceeded", observation.kind.message.?.queue.?.state.failed.code.slice());
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "compaction does not repeat a soft trigger after a failed assistant with unchanged source" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "network_failure" }, .ordinary, .{});
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "new pending input");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
        }
    }.run);
}

test "compaction missing usage estimates covered retained host input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]?[]const u8{
                null,
                "{\"total_tokens\":1.5}",
                "{\"input_tokens\":1}",
                "{\"input_tokens\":1,\"output_tokens\":1.5}",
                "{\"input_tokens\":1,\"input_tokens\":null,\"output_tokens\":0}",
                "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":1}",
            }) |usage| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                const original: [4000]u8 = @splat('x');
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), &original);
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
                const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                try settleCallsForTestingWithFaults(&storage, &tmp, successor, "usage", &calls, .{}, usage);
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "small suffix");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next));
            }
        }
    }.run);
}

test "compaction new Turn evaluates pressure independently of stopped overflow recovery" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |stop_compaction| {
                for ([_]bool{ false, true }) |pressure| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try configureTestSession(&storage, "config");
                    try submitTestMessage(&storage, &tmp, "original", "original", session.slice(), "retain original input");
                    const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    if (stop_compaction) {
                        const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compact));
                    }
                    var stop = try completeSessionStop("stop", session.slice());
                    const stopped = storage.stopSession(&stop, .{});
                    try std.testing.expect(stopped == .accepted);
                    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, stopped.accepted.completion);
                    try storage.close();
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

                    var patch: wire_request.ConfigureCommand = .{};
                    try patch.key.set("pressure");
                    try patch.session.set(session.slice());
                    patch.configuration.compaction_trigger.state = .value;
                    try patch.configuration.compaction_trigger.value.set(if (pressure) "1" else "1000000");
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                    try submitTestMessage(&storage, &tmp, "new", "new", session.slice(), "new work");
                    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expect(next.turn_id != original.turn_id);
                    try std.testing.expectEqual(if (pressure) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
                    try std.testing.expectEqual(@as(u64, if (pressure) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                }
            }
        }
    }.run);
}

test "compaction purpose admission fences a missing latest Turn Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "original input");
            const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            try store_testing.exec(&storage, "UPDATE turn SET operation_id=99999", .{});
            try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "new input");
            try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "each compaction that succeeds is one compacted row, with the entries its floor dropped" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("compacted-create", "", workspace, "model-a");
            const session = (try storage.configure(&create, .{})).accepted.session;
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.compacted) };
            try request.session.set(session.slice());
            // model-a's levels aim at 512,000, 128,000 and 32,000 bytes:
            // level 1 drops the 600 KB Message and keeps the first and last.
            const big = try std.testing.allocator.alloc(u8, 600_000);
            defer std.testing.allocator.free(big);
            @memset(big, 'b');
            try submitTestMessage(&storage, &tmp, "compacted-first", "compacted-first", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "compacted-big", "compacted-big", session.slice(), big);
            try submitTestMessage(&storage, &tmp, "compacted-last", "compacted-last", session.slice(), "last");
            const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const full = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(full, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            // An overflowed compaction has no row.
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            const room = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // A poll while the compaction runs reads a frozen end past its
            // admission; the row then takes a later position, so that
            // prefix never gains it and a poll from its end finds it.
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), frozen.count);
            try settleCompactionForTesting(&storage, &tmp, room, &.{.compaction});
            var reread = request;
            reread.end = frozen.end;
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, reread)).count);
            var follow = request;
            follow.position = frozen.end;
            const followed = try store_core.activityPageForTesting(&storage, follow);
            try std.testing.expectEqual(@as(usize, 1), followed.count);
            try std.testing.expectEqual(room.operation_id, followed.items[0].value.compacted.operation);
            // A later compaction without a floor drops nothing.
            try submitTestMessage(&storage, &tmp, "compacted-again", "compacted-again", session.slice(), "again");
            const again = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(again, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const plain = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, plain, &.{.compaction});
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            for (page.items[0..2], [_]u64{ room.operation_id, plain.operation_id }, [_]u64{ 1, 0 }) |item, operation, dropped| {
                try std.testing.expectEqual(protocol.ActivityItem.Compacted{ .operation = operation, .dropped = dropped }, item.value.compacted);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
            }
            try std.testing.expect(page.items[0].position < page.items[1].position);
        }
    }.run);
}
