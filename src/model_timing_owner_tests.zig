//! Live model-attempt timing conformance, isolated from Host dispatch so its
//! multi-engine checks depend only on custody, transport and the Store.
const std = @import("std");
const execution = @import("execution.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");

test "model resolution owner captures timings for success failure interruption stop and archive" {
    const fixture = store_module.testing;
    const Clock = struct {
        const Observation = enum { prelaunch, launched, response, during_capture, after_capture };
        var milliseconds: i64 = 100;
        var on_cutoff: ?*provider.Transfer = null;
        var callbacks: usize = 0;

        // Inject the transport callback at the read boundary, without a
        // scheduler or sleeps. Return the cutoff sampled before preemption.
        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (clock != .awake) return std.testing.io.vtable.now(userdata, clock);
            const cutoff = std.Io.Timestamp.fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms);
            if (on_cutoff) |transfer| {
                on_cutoff = null;
                respond(transfer);
            }
            return cutoff;
        }

        fn respond(transfer: *provider.Transfer) void {
            milliseconds = 128;
            callbacks += 1;
            _ = transfer.reactor.observe(&transfer.stream, .{ .head = .{ .kind = .interim, .status = 100, .fields = &.{} } });
        }

        const Capture = struct {
            source: @import("model_timing.zig").Source,
            transfer: *provider.Transfer,
            observation: Observation,
            reads: usize = 0,

            fn read(raw: *anyopaque, operation: u64, io: std.Io) @import("model_timing.zig").Values {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.reads += 1;
                if (self.reads == 1 and self.observation == .during_capture) on_cutoff = self.transfer;
                const captured = self.source.snapshot(operation, io);
                if (self.reads == 1 and self.observation == .after_capture) respond(self.transfer);
                return captured;
            }
        };
    };
    try fixture.forEachEngine(struct {
        fn run(case: *fixture.Case) !void {
            const Phase = enum { live, backoff_attached, backoff_retired, replacement_prelaunch };
            const Outcome = enum { success, failure, interruption, stop, archive };
            const Observation = Clock.Observation;
            var vtable = std.testing.io.vtable.*;
            vtable.now = Clock.now;
            var io = std.testing.io;
            io.vtable = &vtable;
            for (std.enums.values(Phase)) |phase| for (std.enums.values(Outcome)) |outcome| for (std.enums.values(Observation)) |observation| {
                if ((phase == .backoff_attached or phase == .backoff_retired) and (outcome == .success or outcome == .failure)) continue;
                if (phase != .live and (observation == .during_capture or observation == .after_capture)) continue;
                // Completed transfers are retired before settlement; controls
                // alone retain a live callback source while resolving.
                if ((observation == .during_capture or observation == .after_capture) and (outcome == .success or outcome == .failure)) continue;
                Clock.milliseconds = 100;
                Clock.on_cutoff = null;
                Clock.callbacks = 0;
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: store_module.Store = undefined;
                try fixture.testingStore(case, &storage, &tmp, io);
                var storage_open = true;
                defer if (storage_open) storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configuration = try fixture.completeConfiguration("timing-owner-create", "", try fixture.canonicalCwd(io, &workspace), "model-a");
                const session = (try storage.configure(&configuration, .{})).accepted.session;
                try fixture.submitTestMessage(&storage, &tmp, "timing-owner-input", "timing-owner-input", session.slice(), "input");
                var admitted = (try storage.admitNextModelAttempt(.{})).?;
                var records: [1]execution.CustodyRecord = @splat(.{});
                var custody = execution.CustodyPool.initialize(&records);
                storage.modelTimingSource().* = custody.timingSource();
                defer if (storage_open) {
                    storage.modelTimingSource().* = .{};
                };
                var token = custody.reserve().?;
                var binding = try custody.attach(token, &admitted.permit);
                var attached = true;
                var used: std.atomic.Value(u64) = .init(0);
                var reactor: provider.Reactor = undefined;
                try reactor.init(std.testing.allocator, io, .{
                    .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null }),
                    .capacity = 1,
                    .inactivity_seconds = 1,
                    .scratch_path = "/nonexistent",
                    .budget = .{ .used = &used, .limit = 0 },
                });
                defer reactor.deinit();
                var transfer: provider.Transfer = undefined;
                transfer.stream = .idle;
                transfer.reactor = &reactor;
                transfer.timing = try custody.modelTiming(token);
                transfer.headers = .{};
                transfer.credential = null;
                var sink: [1]u8 = undefined;
                try reactor.client.prepare(&transfer.stream, .{
                    .endpoint = reactor.endpoints.get(.codex).?,
                    .fields = &.{},
                    .body = .{ .bytes = "" },
                    .sink = .{ .buffer = &sink },
                });
                var stream_open = true;
                defer if (stream_open) {
                    reactor.client.cancel(&transfer.stream);
                    transfer.stream.deinit();
                };
                if (observation != .prelaunch) {
                    reactor.launch(&transfer);
                    if (observation == .response) {
                        Clock.milliseconds = 105;
                        _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = if (phase == .live) .interim else .final, .status = if (phase == .live) 100 else 503, .fields = &.{} } });
                    }
                }
                var capture: Clock.Capture = .{ .source = custody.timingSource(), .transfer = &transfer, .observation = observation };
                storage.modelTimingSource().* = .{ .context = &capture, .read = Clock.Capture.read };
                Clock.milliseconds = 123;
                if (phase != .live) {
                    const retry_before = storage.testing_content_work.rounds;
                    try storage.settleModelAttemptFailure(binding, if (observation == .response)
                        .{ .correlated = .{ .code = "provider_temporary_http_503", .request_id = .{}, .report = "" } }
                    else
                        .{ .uncorrelated = "provider_transport_failure" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
                    if (!case.rerun) try std.testing.expectEqual(@as(u32, 2), storage.testing_content_work.rounds - retry_before);
                    if (phase != .backoff_attached) {
                        reactor.client.cancel(&transfer.stream);
                        transfer.stream.deinit();
                        stream_open = false;
                        transfer = undefined;
                        try custody.detach(token);
                        try custody.cleanupComplete(token);
                        attached = false;
                        // Destroy even the retired slot's bytes: neither custody
                        // nor the Store's live-source registration can retain them.
                        const retired = custody.reserve().?;
                        try custody.releaseUnused(retired);
                        try storage.close();
                        storage_open = false;
                        try fixture.testingStore(case, &storage, &tmp, io);
                        storage_open = true;
                    }
                    // Even an old live source now reports 400 ms: backoff
                    // must keep the 23-ms pair frozen by schedule_retry.
                    Clock.milliseconds = 500;
                    if (phase == .replacement_prelaunch) {
                        try fixture.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1", .{binding.operation_id});
                        admitted = (try storage.tryAdmitNextModelRetry(.empty(), .{}, null)).?;
                        token = custody.reserve().?;
                        binding = try custody.attach(token, &admitted.permit);
                        attached = true;
                        // Admission, not the next resolution, must clear the
                        // previous attempt's saved pair before any new launch.
                        try std.testing.expectEqual(@as(u64, 1), try fixture.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND latency_ms IS NULL AND first_event_ms IS NULL", .{binding.operation_id}));
                        transfer.stream = .idle;
                        transfer.reactor = &reactor;
                        transfer.timing = try custody.modelTiming(token);
                        transfer.headers = .{};
                        transfer.credential = null;
                        try reactor.client.prepare(&transfer.stream, .{
                            .endpoint = reactor.endpoints.get(.codex).?,
                            .fields = &.{},
                            .body = .{ .bytes = "" },
                            .sink = .{ .buffer = &sink },
                        });
                        stream_open = true;
                        capture = .{ .source = custody.timingSource(), .transfer = &transfer, .observation = .prelaunch };
                        storage.modelTimingSource().* = .{ .context = &capture, .read = Clock.Capture.read };
                    }
                }
                // Completion retires the Transfer before interpretation; controls
                // retire it after their immutable transaction commits.
                if (outcome == .success or outcome == .failure) {
                    reactor.client.cancel(&transfer.stream);
                    transfer.stream.deinit();
                    stream_open = false;
                    transfer = undefined;
                }
                const before = storage.testing_content_work.rounds;
                switch (outcome) {
                    .success => try fixture.settleItemsForTesting(&storage, &tmp, binding, &.{"{\"type\":\"message\",\"id\":\"timing-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}"}, "ok"),
                    .failure => try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_final" }, .ordinary, .{}),
                    .interruption => {
                        var command: protocol.ModelInterruptionCommand = .{ .session = session, .turn_id = binding.turn_id, .operation_id = binding.operation_id };
                        try command.key.set("timing-owner-interrupt");
                        try std.testing.expect(storage.interruptModel(&command, .{}) == .accepted);
                    },
                    .stop => {
                        var command: protocol.SessionStopCommand = .{ .session = session };
                        try command.key.set("timing-owner-stop");
                        try std.testing.expect(storage.stopSession(&command, .{}) == .accepted);
                    },
                    .archive => {
                        var command: protocol.SessionArchiveCommand = .{ .session = session };
                        try command.key.set("timing-owner-archive");
                        try std.testing.expect(storage.archiveSession(&command, .{}) == .accepted);
                    },
                }
                // Existing owner budgets: capturing metrics adds no Store round.
                if (!case.rerun) try std.testing.expectEqual(@as(u32, 2), storage.testing_content_work.rounds - before);
                const request: protocol.ActivityPage = .{ .session = session, .kinds = .initOne(.model_call) };
                const page = try std.testing.allocator.create(protocol.ActivityFacts);
                defer std.testing.allocator.destroy(page);
                try storage.activityPage(&request, page);
                try std.testing.expectEqual(@as(usize, 1), page.count);
                const call = page.items[0].value.model_call;
                const raced = observation == .during_capture or observation == .after_capture;
                // A forced MySQL transaction rerun captures again after the
                // single callback; its later coherent pair must keep the event.
                const recaptured = raced and case.rerun;
                try std.testing.expectEqual(if (phase == .replacement_prelaunch or observation == .prelaunch) @as(?u64, null) else if (recaptured) @as(u64, 28) else 23, call.latency_ms);
                try std.testing.expectEqual(if (phase == .replacement_prelaunch) @as(?u64, null) else if (observation == .response) @as(?u64, 5) else if (recaptured) @as(?u64, 28) else null, call.first_event_ms);
                try std.testing.expectEqual(@as(u64, if (phase == .replacement_prelaunch) 2 else 1), call.attempts);
                if (call.first_event_ms) |first| try std.testing.expect(first <= (call.latency_ms orelse return error.MissingSend));
                try std.testing.expectEqual(@as(usize, if (raced) 1 else 0), Clock.callbacks);
                try std.testing.expectEqual(@as(usize, if (case.rerun) 2 else 1) * @as(usize, if (phase == .backoff_attached) 2 else 1), capture.reads);
                if (raced) try std.testing.expectEqual(@as(?u64, 28), transfer.timing.?.firstEventMs());
                const expected_status = switch (outcome) {
                    .success => "answer",
                    .failure => "provider_final",
                    else => "interrupted",
                };
                try std.testing.expectEqualStrings(expected_status, call.status.slice());
                if (stream_open) {
                    reactor.client.cancel(&transfer.stream);
                    transfer.stream.deinit();
                    stream_open = false;
                    transfer = undefined;
                }
                if (attached) {
                    try custody.detach(token);
                    try custody.cleanupComplete(token);
                }
                try std.testing.expectEqualDeep(@import("model_timing.zig").Values{}, custody.timingSource().snapshot(binding.operation_id, io));
                const reused = custody.reserve().?;
                try custody.releaseUnused(reused);
                Clock.milliseconds = 999;
                try storage.activityPage(&request, page);
                try std.testing.expectEqualDeep(call, page.items[0].value.model_call);
            };
        }
    }.run);
}
