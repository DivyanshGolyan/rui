//! Controls Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const HistoricalView = historical_domain.HistoricalView;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;
const completeModelInterruption = shared_fixtures.completeModelInterruption;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectActivityOutcome = shared_fixtures.expectActivityOutcome;
const openCheckedView = shared_fixtures.openCheckedView;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "a control marks its durable acceptance while it holds the Store, only when it commits an acceptance" {
    try store_testing.forEachEngine(struct {
        const Phases = struct {
            marks: [8]store_core.ControlTracePhase = undefined,
            len: usize = 0,

            fn mark(context: *anyopaque, phase: store_core.ControlTracePhase) void {
                const phases: *Phases = @ptrCast(@alignCast(context));
                phases.marks[phases.len] = phase;
                phases.len += 1;
            }

            fn faults(phases: *Phases) store_core.Faults {
                phases.len = 0;
                return .{ .control_trace = .{ .context = phases, .mark_fn = mark } };
            }

            /// The last run of the entry point; a run before it, which a
            /// network Store may repeat, marks no acceptance.
            fn expect(phases: *const Phases, durable: bool) !void {
                const accepted = [_]store_core.ControlTracePhase{ .lock_acquired, .durable_acceptance, .store_complete };
                const other = [_]store_core.ControlTracePhase{ .lock_acquired, .store_complete };
                const last: []const store_core.ControlTracePhase = if (durable) &accepted else &other;
                const marks = phases.marks[0..phases.len];
                try std.testing.expectEqual(store_core.ControlTracePhase.lock_requested, marks[0]);
                try std.testing.expect(marks.len >= last.len + 1);
                try std.testing.expectEqualSlices(store_core.ControlTracePhase, last, marks[marks.len - last.len ..]);
                try std.testing.expectEqual(@intFromBool(durable), std.mem.count(store_core.ControlTracePhase, marks, &.{.durable_acceptance}));
            }
        };

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var phases: Phases = .{};
            const session = try configureTestSessionAsk(&storage, "durable-config");
            try submitTestMessage(&storage, &tmp, "durable-input", "durable-message", session.slice(), "propose");
            const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "durable", .name = "bash", .encoded_call_id = "durable", .decoded_call_id = "durable", .encoded_arguments = "{\\\"description\\\":\\\"Durable\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Durable\",\"cmd\":\"true\",\"timeout_ms\":null}" },
            };
            try settleCallsForTesting(&storage, &tmp, proposing, "durable-calls", &calls);
            const action = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE session_ref=?1", .{session.slice()});

            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
            try allow.key.set("durable-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, phases.faults()) == .accepted);
            try phases.expect(true);
            try std.testing.expect(storage.decidePermission(&allow, phases.faults()).accepted.replayed);
            try phases.expect(false);

            var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = proposing.turn_id, .operation_id = proposing.operation_id };
            try interrupt.key.set("durable-interrupt");
            try interrupt.session.set(session.slice());
            try std.testing.expect(storage.interruptModel(&interrupt, phases.faults()) == .rejected);
            try phases.expect(false);

            var stop = try completeSessionStop("durable-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, phases.faults()) == .accepted);
            try phases.expect(true);
            try std.testing.expect(storage.stopSession(&stop, phases.faults()).accepted.replayed);
            try phases.expect(false);

            var archive: protocol.SessionArchiveCommand = .{ .archived = true };
            try archive.key.set("durable-archive");
            try archive.session.set(session.slice());
            try std.testing.expect(storage.archiveSession(&archive, phases.faults()).accepted.archived);
            try phases.expect(true);
            var restore: protocol.SessionArchiveCommand = .{ .archived = false };
            try restore.key.set("durable-restore");
            try restore.session.set(session.slice());
            try std.testing.expect(!storage.archiveSession(&restore, phases.faults()).accepted.archived);
            try phases.expect(false);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a model interruption's replay names the target it saved, or the Store is corrupt" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
            try interrupt.key.set("saved-target-interrupt");
            try interrupt.session.set("k7m2qx");
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.unknown_session, storage.interruptModel(&interrupt, .{}).rejected.code);
            try std.testing.expect(storage.interruptModel(&interrupt, .{}).rejected.replayed);
            try store_testing.exec(&storage, "UPDATE model_interruption_command SET operation_id='2' WHERE command_key='saved-target-interrupt'", .{});
            try std.testing.expectEqual(ModelInterruptionReply.infrastructure_failure, storage.interruptModel(&interrupt, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "Session stop freezes its selection and excludes only the admitted prefix" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-stop");
            try submitTestMessage(&storage, &tmp, "stop-a", "message-a", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?;
            const binding = first.permit.binding;

            var stop = try completeSessionStop("stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(!accepted.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expectEqual(binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
            try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(binding.operation_id, accepted.accepted.interrupted_operation_id.?);
            var view: HistoricalView = undefined;
            try std.testing.expectError(error.SupersededByControl, openCheckedView(&storage, binding, &view));

            const cancelled = (try store_testing.observeCommandForTesting(&storage, "message-a")).kind.message.?.queue.?;
            const cancellation = switch (cancelled.state) {
                .cancelled => |value| value,
                else => return error.ExpectedCancelledObservation,
            };
            try std.testing.expectEqual(binding.turn_id, cancellation.binding.turn_id);
            try std.testing.expectEqualStrings("cancelled", cancellation.code.slice());
            const active_report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(active_report);
            var active_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, active_report, .{});
            defer active_json.deinit();
            const active_message = active_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("applied", active_message.get("application").?.string);
            try std.testing.expect(active_message.get("exclusion").? == .null);

            var after_stop = try completeModelInterruption("interrupt-after-stop", session.slice(), binding);
            const rejected_interrupt = storage.interruptModel(&after_stop, .{});
            try std.testing.expect(rejected_interrupt == .rejected);
            try std.testing.expectEqual(
                protocol.ModelInterruptionRejection.operation_resolved,
                rejected_interrupt.rejected.code,
            );

            try submitTestMessage(&storage, &tmp, "stop-b", "message-b", session.slice(), "later");
            const replay = storage.stopSession(&stop, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
            try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "message-b")).kind.message.?.queue.?.state == .queued);
            const later = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expect(later.permit.binding.turn_id != binding.turn_id);
        }
    }.run);
}

test "later idle stop does not reclassify a completed Message" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "completed-stop-config");
            try submitTestMessage(&storage, &tmp, "completed-stop-file", "completed-stop-message", session.slice(), "answer");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code='answer',attempt_at=NULL,resolved_at=1," ++
                "resolution_content_id=(SELECT content_id FROM message_admission WHERE command_key='completed-stop-message')", .{});
            try store_testing.exec(&storage, "UPDATE turn SET outcome_code='completed',outcome_at=1,outcome_content_id=(SELECT content_id FROM message_admission " ++
                "WHERE command_key='completed-stop-message'),outcome_position=(SELECT next_position FROM session WHERE session_ref=?1) WHERE session_ref=?1", .{session.slice()});
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+1 WHERE session_ref=?1", .{session.slice()});
            var stop = try completeSessionStop("completed-stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(accepted.accepted.selection.selected_turn_id == null);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "completed-stop-message")).kind.message.?.queue.?.state == .completed);

            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer parsed.deinit();
            const message = parsed.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("applied", message.get("application").?.string);
            try std.testing.expect(message.get("exclusion").? == .null);
            try std.testing.expect(message.get("outcome").?.object.get("content").?.object.get("text") == null);
        }
    }.run);
}

test "idle Session stop excludes queued work but not later admissions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-idle-stop");
            try submitTestMessage(&storage, &tmp, "idle-stop-a", "idle-message-a", session.slice(), "before");
            var stop = try completeSessionStop("idle-stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(!accepted.accepted.replayed);
            try std.testing.expectEqual(@as(?u64, null), accepted.accepted.selection.selected_turn_id);
            try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expectEqual(@as(?u64, null), accepted.accepted.interrupted_operation_id);
            const excluded = (try store_testing.observeCommandForTesting(&storage, "idle-message-a")).kind.message.?.queue.?;
            try std.testing.expect(excluded.state == .excluded);
            try std.testing.expectEqualStrings("session_stopped", excluded.state.excluded.code.slice());
            const excluded_report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(excluded_report);
            var excluded_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, excluded_report, .{});
            defer excluded_json.deinit();
            const excluded_message = excluded_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("excluded", excluded_message.get("application").?.string);
            try std.testing.expectEqualStrings("idle-stop", excluded_message.get("exclusion").?.object.get("command_key").?.string);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

            try submitTestMessage(&storage, &tmp, "idle-stop-b", "idle-message-b", session.slice(), "after");
            const later = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(@as(u64, 1), later.permit.binding.turn_id);

            // Replay before and after a real database reopen while newer work is live.
            for (0..2) |pass| {
                if (pass == 1) {
                    try storage.close();
                    storage_open = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    storage_open = true;
                }
                const replay = storage.stopSession(&stop, .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(accepted.accepted.selection, replay.accepted.selection);
                try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
                try std.testing.expectEqual(@as(?u64, null), replay.accepted.interrupted_operation_id);
                const newer = (try store_testing.observeCommandForTesting(&storage, "idle-message-b")).kind.message.?.queue.?.state;
                try std.testing.expect(newer == .processing);
                try std.testing.expectEqual(later.permit.binding, newer.processing);
                const original = (try store_testing.observeCommandForTesting(&storage, "idle-message-a")).kind.message.?.queue.?.state;
                try std.testing.expect(original == .excluded);
                try std.testing.expectEqualStrings("session_stopped", original.excluded.code.slice());
            }
            var fresh = try completeSessionStop("idle-stop-newer", session.slice());
            const stopped = storage.stopSession(&fresh, .{});
            try std.testing.expect(stopped == .accepted and !stopped.accepted.replayed);
            try std.testing.expectEqual(later.permit.binding.turn_id, stopped.accepted.selection.selected_turn_id.?);
            try std.testing.expectEqual(@as(u64, 2), stopped.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(later.permit.binding.operation_id, stopped.accepted.interrupted_operation_id.?);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "idle-message-b")).kind.message.?.queue.?.state == .cancelled);
        }
    }.run);
}

test "exact model interruption continues only with applicable pending input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-interrupt");
            try submitTestMessage(&storage, &tmp, "interrupt-a", "interrupt-message-a", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?;
            const binding = first.permit.binding;
            try submitTestMessage(&storage, &tmp, "interrupt-b", "interrupt-message-b", session.slice(), "second");

            var interrupt = try completeModelInterruption("interrupt", session.slice(), binding);
            const accepted = storage.interruptModel(&interrupt, .{});
            try std.testing.expect(accepted == .accepted);
            var view: HistoricalView = undefined;
            try std.testing.expectError(error.SupersededByControl, openCheckedView(&storage, binding, &view));
            const successor = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(binding.turn_id, successor.permit.binding.turn_id);
            try std.testing.expect(successor.permit.binding.operation_id != binding.operation_id);

            const observation = try store_testing.observeCommandForTesting(&storage, "interrupt");
            try std.testing.expectEqual(binding.turn_id, observation.kind.model_interruption.turn_id);
            try std.testing.expectEqual(binding.operation_id, observation.kind.model_interruption.operation_id);

            try std.testing.expectError(
                error.SupersededByControl,
                storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "late_old_failure" }, .ordinary, .{}),
            );
            const successor_observation = (try store_testing.observeCommandForTesting(&storage, "interrupt-message-b")).kind.message.?.queue.?;
            const observed_successor = switch (successor_observation.state) {
                .processing => |value| value,
                else => return error.ExpectedProcessingObservation,
            };
            try std.testing.expectEqual(successor.permit.binding, observed_successor);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='interrupted' " ++
                "AND interrupted_by_command_key='interrupt'", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL", .{}));
            const replay = storage.interruptModel(&interrupt, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try storage.settleModelAttemptFailure(successor.permit.binding, .{ .uncorrelated = "successor_failure" }, .ordinary, .{});
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='successor_failure'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='late_old_failure'", .{}));
        }
    }.run);
}

test "exact model interruption rejects stale targets and replays before applicability" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-rejected-interrupt");
            var early: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
            try early.key.set("early-interrupt");
            try early.session.set(session.slice());
            const rejected = storage.interruptModel(&early, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.unknown_operation, rejected.rejected.code);

            try submitTestMessage(&storage, &tmp, "rejected-interrupt-a", "rejected-interrupt-message", session.slice(), "first");
            const admitted = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(@as(u64, 1), admitted.permit.binding.operation_id);
            const replay = storage.interruptModel(&early, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.unknown_operation, replay.rejected.code);

            early.operation_id = 2;
            try std.testing.expect(storage.interruptModel(&early, .{}) == .conflict);

            var exact = try completeModelInterruption("exact-interrupt", session.slice(), admitted.permit.binding);
            try std.testing.expect(storage.interruptModel(&exact, .{}) == .accepted);
            try std.testing.expect(
                (try store_testing.observeCommandForTesting(&storage, "rejected-interrupt-message")).kind.message.?.queue.?.state == .cancelled,
            );
            try std.testing.expectError(
                error.SupersededByControl,
                storage.settleModelAttemptFailure(admitted.permit.binding, .{ .uncorrelated = "late_failure" }, .ordinary, .{}),
            );

            var after = try completeModelInterruption("after-interrupt", session.slice(), admitted.permit.binding);
            const resolved = storage.interruptModel(&after, .{});
            try std.testing.expect(resolved == .rejected);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.operation_resolved, resolved.rejected.code);
        }
    }.run);
}

test "controls remove scheduled retries and replay without cancelling newer work after reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Control = enum { none, stop, interruption };
            for ([_]Control{ .none, .stop, .interruption }) |control| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var storage_open = true;
                defer if (storage_open) storage.close() catch unreachable;

                const session = try configureTestSession(&storage, "retry-config");
                try submitTestMessage(&storage, &tmp, "retry-first", "retry-message", session.slice(), "first");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "temporary" }, .{ .retryable = .{
                    .waits_ms = .{ 60_000, 60_000, 60_000 },
                } }, .{});
                // Make the saved retry due without depending on wall-clock scheduling.
                try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});

                if (control == .none) {
                    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
                    try std.testing.expectEqual(binding.turn_id, retry.turn_id);
                    try std.testing.expectEqual(binding.operation_id, retry.operation_id);
                    try std.testing.expectEqual(@as(u64, 2), retry.attempt_ordinal);
                    continue;
                }
                const is_stop = control == .stop;
                var stop = try completeSessionStop("retry-control", session.slice());
                var interrupt = try completeModelInterruption("retry-control", session.slice(), binding);
                if (is_stop) {
                    const accepted = storage.stopSession(&stop, .{});
                    try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
                } else {
                    const accepted = storage.interruptModel(&interrupt, .{});
                    try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
                }
                try std.testing.expect((try admitRetryForTesting(&storage)) == null);
                try expectActivityOutcome(&storage, session.slice(), binding, if (is_stop) .stopped else .interrupted, "cancelled");

                try submitTestMessage(&storage, &tmp, "retry-newer", "retry-newer-message", session.slice(), "newer");
                const newer_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expect(newer_binding.turn_id != binding.turn_id);
                for (0..2) |pass| {
                    if (pass == 1) {
                        try storage.close();
                        storage_open = false;
                        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                        storage_open = true;
                    }
                    if (is_stop) {
                        const replay = storage.stopSession(&stop, .{});
                        try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                        try std.testing.expectEqual(binding.turn_id, replay.accepted.selection.selected_turn_id.?);
                        try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
                        try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
                        try std.testing.expectEqual(binding.operation_id, replay.accepted.interrupted_operation_id.?);
                    } else {
                        const replay = storage.interruptModel(&interrupt, .{});
                        try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                        const target = (try store_testing.observeCommandForTesting(&storage, "retry-control")).kind.model_interruption;
                        try std.testing.expectEqualStrings(session.slice(), target.session.slice());
                        try std.testing.expectEqual(binding.turn_id, target.turn_id);
                        try std.testing.expectEqual(binding.operation_id, target.operation_id);
                    }
                    const original = (try store_testing.observeCommandForTesting(&storage, "retry-message")).kind.message.?.queue.?.state;
                    try std.testing.expect(original == .cancelled);
                    try std.testing.expectEqual(binding, original.cancelled.binding);
                    const newer = (try store_testing.observeCommandForTesting(&storage, "retry-newer-message")).kind.message.?.queue.?.state;
                    try std.testing.expect(newer == .processing);
                    try std.testing.expectEqual(newer_binding, newer.processing);
                }
            }
        }
    }.run);
}

test "accepted stop remains discoverable without a control hint" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "hintless-config");
            try submitTestMessage(&storage, &tmp, "hintless-file", "hintless-message", session.slice(), "work");
            // The control generation moves only for a control, which is
            // what lets the dispatch loop find a stop whose hint was lost.
            const before = storage.controlGeneration();
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            const binding = try admitted.permit.consume();
            try std.testing.expect((try storage.operationSupersededByControl(binding)) == null);
            try std.testing.expectEqual(before, storage.controlGeneration());

            var stop = try completeSessionStop("hintless-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expect(storage.controlGeneration() != before);
            const control = (try storage.operationSupersededByControl(binding)).?;
            try std.testing.expectEqualStrings("hintless-stop", control.command_key.slice());
        }
    }.run);
}

test "dispatch handoff refuses a stopped Attempt without invoking the launch callback" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "handoff-config");
            try submitTestMessage(&storage, &tmp, "handoff-file", "handoff-message", session.slice(), "work");
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            const binding = try admitted.permit.consume();

            const Launch = struct {
                fn run(calls: *usize) !void {
                    calls.* += 1;
                }
            };
            var calls: usize = 0;
            try storage.withDispatchHandoff(binding, &calls, Launch.run);
            try std.testing.expectEqual(@as(usize, 1), calls);

            var stop = try completeSessionStop("handoff-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectError(error.SupersededByControl, storage.withDispatchHandoff(binding, &calls, Launch.run));
            try std.testing.expectEqual(@as(usize, 1), calls);
        }
    }.run);
}

test "failed control commit saves no answer after reopening" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            const session = try configureTestSession(&storage, "configure-control-rollback");
            var stop = try completeSessionStop("rollback-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{ .before_commit = true }) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "rollback-stop")).status == .absent);
        }
    }.run);
}
