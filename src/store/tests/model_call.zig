//! Model call Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const named_scratch = @import("../../named_scratch.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const output_decode = @import("../../output_decode.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;

test "model_call derives frozen model and usage from the resolved Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "model-call-config");
            try submitTestMessage(&storage, &tmp, "model-call-input", "model-call-input", session.slice(), "input");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const admission = try store_testing.queryU64(&storage, "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{binding.operation_id});
            var request: protocol.ActivityPage = .{ .session = session, .kinds = .initOne(.model_call) };
            const unresolved = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), unresolved.count);
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("model-call-change-model");
            patch.session = session;
            patch.configuration.model.state = .value;
            try patch.configuration.model.value.set("model-b");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            // A later revision must not change which revision names this call.
            try submitTestMessage(&storage, &tmp, "model-call-followup", "model-call-followup", session.slice(), "next");
            // Real adapter certification supplies model evidence and normalized usage.
            const response_bytes = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n\n" ++
                "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"model\":\"served-model\",\"output\":[],\"usage\":{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":40},\"output_tokens\":7}}}\n\n";
            const source = try tmp.dir.createFile(std.testing.io, "model-call-response", .{ .read = true });
            defer source.close(std.testing.io);
            try source.writeStreamingAll(std.testing.io, response_bytes);
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used: std.atomic.Value(u64) = .init(0);
            var retained: ?named_scratch.Owner = null;
            var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "model-call-metadata", .{ .used = &used, .limit = 1 << 20 }, false, &retained);
            defer metadata.deinit();
            var event_data: output_decode.EventData = undefined;
            try event_data.init(std.testing.io, root[0..root_length], "model-call-event-data", .{ .used = &used, .limit = 1 << 20 }, false, &retained);
            defer event_data.deinit();
            var interpreted: output_decode.Interpretation = undefined;
            output_decode.interpret(output_decode.testingInterpret(), .@"openai-responses/1", std.testing.io, source, response_bytes.len, &metadata, &event_data, .assistant_response, .{ .openai = "header-model" }, output_decode.testingProviderFailure(), &interpreted);
            try std.testing.expect(interpreted == .accepted);
            const accepted = &interpreted.accepted;
            const validated = &accepted.output;
            var timings: @import("../../model_timing.zig").Values = .{ .latency_ms = 23, .first_event_ms = 5 };
            storage.modelTimingSource().* = store_testing.timingSource(&timings);
            try storage.settleModelSuccess(binding, &.{
                .source = validated.source,
                .source_length = validated.source_length,
                .metadata = metadata.file,
                .item_count = validated.item_count,
                .call_count = validated.call_count,
                .answer_item_ordinal = validated.answer_item_ordinal,
                .answer_length = validated.answer_length,
                .answer_digest = validated.answer_digest,
                .response_id = validated.evidence.response_id,
                .model_evidence = accepted.model_evidence,
                .request_id = .{},
            }, .{});
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            const item = page.items[0];
            try std.testing.expectEqual(admission, item.position);
            try std.testing.expectEqual(@as(u64, 0), item.ordinal);
            const call = item.value.model_call;
            try std.testing.expectEqualStrings("model-a", call.model.slice());
            try std.testing.expectEqualStrings("served-model", call.served_model.?.slice());
            try std.testing.expectEqual(@as(?u64, 100), call.input_tokens);
            try std.testing.expectEqual(@as(?u64, 40), call.cached_tokens);
            try std.testing.expectEqual(@as(?u64, 7), call.output_tokens);
            try std.testing.expectEqual(@as(?u64, 23), call.latency_ms);
            try std.testing.expectEqual(@as(?u64, 5), call.first_event_ms);
            try std.testing.expectEqual(@as(u64, 1), call.attempts);
            try std.testing.expectEqualStrings("answer", call.status.slice());
            // D219 places this newly resolved row at the earlier admission,
            // including on an end captured while the Operation was unresolved.
            request.end = unresolved.end;
            try std.testing.expectEqual(@as(usize, 1), (try store_core.activityPageForTesting(&storage, request)).count);
        }
    }.run);
}

test "model_call retry emits one row with final timings and no-event resolution stays nullable" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "model-call-retry-config");
            try submitTestMessage(&storage, &tmp, "model-call-retry-input", "model-call-retry-input", session.slice(), "retry");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const admission = try store_testing.queryU64(&storage, "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{first.operation_id});
            const request: protocol.ActivityPage = .{ .session = session, .kinds = .initOne(.model_call) };
            try store_testing.settleModelFailureWithTimings(&storage, first, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{ .latency_ms = 999, .first_event_ms = 111 }, .{});
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1", .{first.operation_id});
            const final = (try admitRetryForTesting(&storage)).?.permit.binding;
            try std.testing.expectEqual(first.operation_id, final.operation_id);
            try std.testing.expectEqual(@as(u64, 2), final.attempt_ordinal);
            try store_testing.settleModelFailureWithTimings(&storage, final, .{ .uncorrelated = "provider_final" }, .ordinary, .{ .latency_ms = 37, .first_event_ms = 7 }, .{});
            // Check the durable public read after reopen, not just an in-memory projection.
            try storage.close();
            storage_open = false;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            storage_open = true;
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            try std.testing.expectEqual(admission, page.items[0].position);
            try std.testing.expectEqual(@as(u64, 0), page.items[0].ordinal);
            const call = page.items[0].value.model_call;
            try std.testing.expectEqualStrings("model-a", call.model.slice());
            try std.testing.expectEqualStrings("provider_final", call.status.slice());
            try std.testing.expectEqual(@as(u64, 2), call.attempts);
            try std.testing.expectEqual(@as(?u64, 37), call.latency_ms);
            try std.testing.expectEqual(@as(?u64, 7), call.first_event_ms);
            try std.testing.expect(call.input_tokens == null and call.output_tokens == null and call.cached_tokens == null and call.served_model == null);

            try submitTestMessage(&storage, &tmp, "model-call-no-event", "model-call-no-event", session.slice(), "no response");
            const silent = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.settleModelFailureWithTimings(&storage, silent, .{ .uncorrelated = "provider_transport_failure" }, .ordinary, .{ .latency_ms = 19 }, .{});
            var next = request;
            next.position = page.items[0].position;
            next.ordinal = page.items[0].ordinal;
            const second = try store_core.activityPageForTesting(&storage, next);
            try std.testing.expectEqual(@as(usize, 1), second.count);
            try std.testing.expectEqual(@as(u64, 1), second.items[0].value.model_call.attempts);
            try std.testing.expectEqual(@as(?u64, 19), second.items[0].value.model_call.latency_ms);
            try std.testing.expectEqual(@as(?u64, null), second.items[0].value.model_call.first_event_ms);
            const all = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), all.count);
            var reverse = request;
            reverse.direction = .backward;
            reverse.limit = 1;
            const last = try store_core.activityPageForTesting(&storage, reverse);
            try std.testing.expectEqual(@as(usize, 1), last.count);
            try std.testing.expect(last.more);
            try std.testing.expectEqual(second.items[0].position, last.items[0].position);
        }
    }.run);
}
