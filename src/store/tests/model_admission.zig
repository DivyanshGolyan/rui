//! Model admission Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const historical_domain = @import("../domain/historical.zig");
const model_admission_domain = @import("../domain/model_admission.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const store_testing = @import("../testing.zig");
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptBinding = store_core.AttemptBinding;
const Faults = store_core.Faults;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelOperationKind = historical_domain.ModelOperationKind;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TestingHistoryCursor = shared_fixtures.TestingHistoryCursor;
const TwinRounds = shared_fixtures.TwinRounds;
const ViewRounds = shared_fixtures.ViewRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const denyForTesting = shared_fixtures.denyForTesting;
const failed_purpose_operations_sql = shared_fixtures.failed_purpose_operations_sql;
const renderTestingEntry = shared_fixtures.renderTestingEntry;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingBytesContent = shared_fixtures.testingBytesContent;

test "a quota reset is read from a saved record and never fences" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            for ([_]struct { code: []const u8, diagnostic: ?[]const u8, resets_at: ?u64 }{
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":null}", .resets_at = null },
                .{ .code = "provider_plan", .diagnostic = "{\"refusal\":\"plan\",\"resets_at\":42}", .resets_at = 42 },
                // A missing, corrupt or mismatched record gives no time.
                .{ .code = "provider_quota", .diagnostic = null, .resets_at = null },
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":4x}", .resets_at = null },
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"plan\",\"resets_at\":42}", .resets_at = null },
                // Only a quota code reads one.
                .{ .code = "provider_http_403", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":42}", .resets_at = null },
            }, 0..) |case, index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "quota-{d}", .{index});
                var message_buffer: [32]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, "quota-message-{d}", .{index});
                const session = try configureTestSession(&storage, key);
                try submitTestMessage(&storage, &tmp, message, message, session.slice(), "q");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const failure: ModelFailure = if (case.diagnostic) |detail| .{ .rejected = .{ .code = case.code, .diagnostic = detail, .request_id = .{}, .report = "" } } else .{ .uncorrelated = case.code };
                try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const failed = (try store_core.activityPageForTesting(&storage, request)).work.work.state.failed;
                try std.testing.expectEqualStrings(case.code, failed.code.slice());
                try std.testing.expectEqual(case.resets_at, failed.resets_at);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "kind-specific admission selects a tool continuation despite fresh input and rolls back atomically" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_0 = try configureTestSessionAsk(&storage, "peer-config");
            const allocated_session_1 = try configureTestSessionAsk(&storage, "fresh-config");
            try submitTestMessage(&storage, &tmp, "peer-input", "peer-input", allocated_session_0.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, first, "peer-output", &calls);
            try submitTestMessage(&storage, &tmp, "fresh-input", "fresh-input", allocated_session_1.slice(), "competing input");

            try std.testing.expectError(error.InjectedAttemptCommitFailure, storage.admitModelAttempt(.tool_continuation, .{ .attempt_before_commit = true }));
            // A failed admission commit fences; recovery is a fresh Store open.
            try std.testing.expectError(error.StoreFenced, storage.admitModelAttempt(.tool_continuation, .{}));
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try std.testing.expectEqual(first.turn_id, continued.turn_id);
            try std.testing.expectEqual(first.operation_id + 1, continued.operation_id);
            try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            const fresh = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expect(fresh.turn_id != first.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
        }
    }.run);
}

test "tool continuation selection leaves a ready Turn with queued input to message selection" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            const queued_session = try configureTestSessionAsk(&storage, "queued-config");
            const ready_session = try configureTestSessionAsk(&storage, "ready-config");
            try submitTestMessage(&storage, &tmp, "queued-start", "queued-start", queued_session.slice(), "start");
            const queued = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, queued, "queued-output", &calls);
            try submitTestMessage(&storage, &tmp, "ready-start", "ready-start", ready_session.slice(), "start");
            const ready = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, ready, "ready-output", &calls);
            try submitTestMessage(&storage, &tmp, "queued-input", "queued-input", queued_session.slice(), "more");

            const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try std.testing.expectEqual(ready.turn_id, continued.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            const joined = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expectEqual(queued.turn_id, joined.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
        }
    }.run);
}

test "each transition that lets a Turn continue without input makes it selectable" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const Path = enum { rejected, denied, settled, indeterminate, overflow };
            for (std.enums.values(Path)) |path| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "continue-{s}", .{@tagName(path)});
                var config_buffer: [40]u8 = undefined;
                const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
                const session = if (path == .overflow) try configureTestSession(&storage, config) else try configureTestSessionAsk(&storage, config);
                try submitTestMessage(&storage, &tmp, name, name, session.slice(), "start");
                const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                switch (path) {
                    .rejected => {
                        const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                        try settleCallsForTesting(&storage, &tmp, first, config, &calls);
                    },
                    .denied, .settled, .indeterminate => {
                        try settleTwoActionsForTesting(&storage, &tmp, first, config);
                        const last_action = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
                        var key_buffer: [48]u8 = undefined;
                        try denyForTesting(&storage, session.slice(), try std.fmt.bufPrint(&key_buffer, "{s}-deny-first", .{name}), last_action - 1);
                        try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                        switch (path) {
                            .denied => try denyForTesting(&storage, session.slice(), try std.fmt.bufPrint(&key_buffer, "{s}-deny-last", .{name}), last_action),
                            else => {
                                var allow: protocol.PermissionDecisionCommand = .{ .action_id = last_action, .decision = .allow_once };
                                try allow.key.set(try std.fmt.bufPrint(&key_buffer, "{s}-allow", .{name}));
                                try allow.session.set(session.slice());
                                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                                const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
                                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                                if (path == .settled) {
                                    try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
                                } else {
                                    try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                                }
                            },
                        }
                    },
                    .overflow => try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{}),
                }
                const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
                try std.testing.expectEqual(first.turn_id, continued.turn_id);
                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a Turn whose continuation was never recorded fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "unrecorded-config");
            try submitTestMessage(&storage, &tmp, "unrecorded", "unrecorded", session.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, first, "unrecorded-metadata", &calls);
            try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=NULL", .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "a continuation recorded for a Turn waiting on its tool results fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "premature-config");
            try submitTestMessage(&storage, &tmp, "premature", "premature", session.slice(), "propose");
            const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "premature-config");
            try submitTestMessage(&storage, &tmp, "premature-input", "premature-input", session.slice(), "more");
            try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=operation_id", .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "production turn preserves skipped continuation preference through actual Store admissions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const turn = @import("../../execution_turn.zig");
            // Real canonical admissions and outcomes; no native effect is launched.
            // The test controls only available preparation and execution capacity.
            const Context = struct {
                storage: *Store,
                preparation_open: bool = true,
                /// Counts each preparation slot opening or closing, as setSlot does.
                slot_changes: u64 = 0,
                observed_open: bool = true,
                model: ?AttemptBinding = null,
                action: ?ActionAttemptBinding = null,
                failure: ?anyerror = null,
                faults: Faults = .{},

                pub fn now(_: *@This()) std.Io.Clock.Timestamp {
                    return .now(std.testing.io, .awake);
                }
                pub fn noteLifecycleOpportunity(_: *@This()) void {}
                pub fn consumeControlHint(_: *@This()) bool {
                    return false;
                }
                pub fn commitGeneration(self: *@This()) u64 {
                    return self.storage.commitGeneration();
                }
                pub fn controlGeneration(self: *@This()) u64 {
                    return self.storage.controlGeneration();
                }
                pub fn slotChanges(self: *@This()) u64 {
                    if (self.observed_open != self.preparation_open) self.slot_changes += 1;
                    self.observed_open = self.preparation_open;
                    return self.slot_changes;
                }
                pub fn reconcileControls(_: *@This()) void {}
                pub fn advanceBashPreparation(_: *@This()) bool {
                    return false;
                }
                pub fn advanceLiveBash(_: *@This()) bool {
                    return false;
                }
                pub fn advanceRetainedCleanup(_: *@This(), _: std.Io.Clock.Timestamp, _: *std.Io.Clock.Timestamp) bool {
                    return false;
                }
                pub fn dispatchFenced(self: *@This()) bool {
                    return self.storage.isFenced();
                }
                pub fn freeSlots(_: *@This()) usize {
                    return 1;
                }
                pub fn providerConfigured(_: *@This()) bool {
                    return true;
                }
                pub fn bashPreparationOpen(_: *@This()) bool {
                    return true;
                }
                pub fn modelPreparationOpen(self: *@This()) bool {
                    return self.preparation_open;
                }
                pub fn recoverUncertainAction(_: *@This()) error{Fence}!bool {
                    return false;
                }
                pub fn recoverExhaustedRetry(_: *@This()) error{Fence}!bool {
                    return false;
                }
                pub fn runCoreAction(_: *@This()) turn.Admission {
                    return .no_work;
                }
                pub fn admitBash(self: *@This()) turn.Admission {
                    var admission = (self.storage.admitNextActionAttempt(1000, self.faults) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.action = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                pub fn scanWork(self: *@This(), paused: bool) error{Fence}!turn.Work {
                    const found = self.storage.dispatchWork(paused) catch |err| {
                        self.failure = err;
                        return error.Fence;
                    };
                    return .{ .core = found.core, .mcp = found.mcp, .bash = found.bash, .message = found.message, .tool_continuation = found.tool_continuation, .retry = found.retry };
                }
                pub fn scheduledRetry(_: *const @This()) turn.ScheduledRetry {
                    return .unknown;
                }
                pub fn unixMilliseconds(_: *const @This()) ?u64 {
                    return null;
                }

                pub fn admitRetry(self: *@This()) turn.Admission {
                    var admission = (self.storage.tryAdmitNextModelRetry(.empty(), self.faults, null) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.model = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                fn admit(self: *@This(), kind: ModelAdmissionKind) turn.Admission {
                    var admission = (self.storage.admitModelAttempt(kind, self.faults) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.model = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                pub fn turnsPaused(_: *@This()) bool {
                    return false;
                }
                pub fn admitNewModel(self: *@This(), paused: bool) turn.Admission {
                    return self.admit(if (paused) .open_turn_message else .message);
                }
                pub fn admitToolContinuation(self: *@This()) turn.Admission {
                    return self.admit(.tool_continuation);
                }
                pub fn hasTransport(_: *@This()) bool {
                    return false;
                }
                pub fn hasBash(_: *@This()) bool {
                    return false;
                }
                pub fn driveTransport(_: *@This()) error{Fence}!void {}
                pub fn serviceOneCompletion(_: *@This()) bool {
                    return false;
                }
                pub fn modelPreparationAllowance(_: *@This()) turn.Allowance {
                    return .{ .bytes = 1, .items = 1 };
                }
                pub fn advanceModelPreparation(_: *@This(), _: usize, _: usize) bool {
                    return false;
                }
            };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_0 = try configureTestSession(&storage, "peer-config");
            const allocated_session_1 = try configureTestSession(&storage, "sender-config");
            const allocated_session_2 = try configureTestSession(&storage, "fresh-config");
            try submitTestMessage(&storage, &tmp, "peer-message", "peer-message", allocated_session_0.slice(), "start");
            const peer = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const unknown = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, peer, "peer-result", &unknown);
            try submitTestMessage(&storage, &tmp, "sender-message", "sender-message", allocated_session_1.slice(), "send");
            try submitTestMessage(&storage, &tmp, "fresh-message", "fresh-message", allocated_session_2.slice(), "compete");
            var state: turn.State = .{};
            var context = Context{ .storage = &storage, .faults = .{ .attempt_before_commit = true } };
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(error.InjectedAttemptCommitFailure, context.failure.?);
            try std.testing.expect(context.model == null and context.action == null);
            try std.testing.expect(storage.isFenced());
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            context.faults = .{};
            context.failure = null;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            const sender = context.model.?;
            try std.testing.expect(sender.turn_id != peer.turn_id);
            const bash_calls = [_]TestingCall{.{ .item_id = "bash-item", .name = "bash", .encoded_call_id = "bash-call", .decoded_call_id = "bash-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&storage, &tmp, sender, "sender-result", &bash_calls);
            context.model = null;
            context.preparation_open = false;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            try std.testing.expectEqual(sender.operation_id, context.action.?.parent_operation_id);
            _ = try storage.settleActionAttempt(context.action.?, .succeeded, "sent", .{});
            context.preparation_open = true;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            // A circular cursor reset by the Bash winner, or the old combined
            // fresh-input-first Store selector, admits fresh work here instead.
            try std.testing.expectEqual(peer.turn_id, context.model.?.turn_id);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "fresh-message")).kind.message.?.queue.?.state == .queued);

            // Keep fresh Messages available while actual retries, Bash and tool-only
            // continuations repeatedly commit. The fixture makes retry clocks due;
            // the production turn and Store still own eligibility and admission.
            var sustained_tmp = std.testing.tmpDir(.{});
            defer sustained_tmp.cleanup();
            var sustained: Store = undefined;
            try store_testing.testingStore(case, &sustained, &sustained_tmp, std.testing.io);
            defer sustained.close() catch unreachable;
            var bindings: [3]AttemptBinding = undefined;
            for ([_][]const u8{ "continuing", "retrying", "sending" }, 0..) |reference, index| {
                var config_key_buffer: [64]u8 = undefined;
                const config_key = try std.fmt.bufPrint(&config_key_buffer, "{s}-config", .{reference});
                const session = try configureTestSession(&sustained, config_key);
                try submitTestMessage(&sustained, &sustained_tmp, reference, reference, session.slice(), "start");
                bindings[index] = (try sustained.admitModelAttempt(.message, .{})).?.permit.binding;
            }
            try settleCallsForTesting(&sustained, &sustained_tmp, bindings[0], "continued-result", &unknown);
            try sustained.settleModelAttemptFailure(bindings[1], .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
            try settleCallsForTesting(&sustained, &sustained_tmp, bindings[2], "sending-result", &bash_calls);
            const allocated_session_3 = try configureTestSession(&sustained, "fresh-loop-config");
            var progress = [_]usize{ 0, 0, 0, 0 }; // Bash, retry, fresh Message, continuation.
            var sustained_state: turn.State = .{};
            var sustained_context = Context{ .storage = &sustained };
            var fresh_number: usize = 0;
            for (0..32) |iteration| {
                // Replenish independently before every selection, never only after
                // the competing candidate has won.
                var key_buffer: [64]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "fresh-loop-{d}", .{fresh_number});
                fresh_number += 1;
                try submitTestMessage(&sustained, &sustained_tmp, key, key, allocated_session_3.slice(), "more input");
                try store_testing.exec(&sustained, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms>0 AND resolution_code IS NULL", .{});
                sustained_context.model = null;
                sustained_context.action = null;
                // The timer edge is fixture-owned; it grants no Attempt authority.
                sustained_state.last_retry_poll = null;
                _ = turn.run(&sustained_state, &sustained_context);
                try std.testing.expectEqual(@as(?anyerror, null), sustained_context.failure);
                if (sustained_context.action) |action| {
                    progress[0] += 1;
                    _ = try sustained.settleActionAttempt(action, .succeeded, "sent", .{});
                } else if (sustained_context.model) |model| {
                    if (model.operation_id == bindings[1].operation_id) {
                        progress[1] += 1;
                        try std.testing.expect(model.attempt_ordinal > 1);
                        try sustained.settleModelAttemptFailure(model, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
                    } else if (model.turn_id == bindings[0].turn_id or model.turn_id == bindings[2].turn_id) {
                        progress[3] += 1;
                        var name_buffer: [64]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buffer, "continuation-{d}", .{iteration});
                        try settleCallsForTesting(&sustained, &sustained_tmp, model, name, if (model.turn_id == bindings[0].turn_id) &unknown else &bash_calls);
                    } else {
                        progress[2] += 1;
                        try sustained.settleModelAttemptFailure(model, .{ .uncorrelated = "completed-fixture" }, .ordinary, .{});
                    }
                } else return error.NoProgressUnderSustainedInput;
            }
            try std.testing.expect(progress[0] >= 2 and progress[2] >= 2 and progress[3] >= 2);
            try std.testing.expectEqual(@as(usize, 3), progress[1]);
        }
    }.run);
}

test "runnable discovery fences structurally incomplete current tool calls" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { action, call }{ .action, .call };
            for (corruptions, 0..) |corruption, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const configs = [_][]const u8{ "discovery-action-config", "discovery-call-config" };
                const messages = [_][]const u8{ "discovery-action-message", "discovery-call-message" };
                const files = [_][]const u8{ "discovery-action-file", "discovery-call-file" };
                const metadata = [_][]const u8{ "discovery-action-metadata", "discovery-call-metadata" };
                const session = try configureTestSession(&storage, configs[index]);
                const session_ref = session.slice();
                try submitTestMessage(&storage, &tmp, files[index], messages[index], session_ref, "call");
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{.{
                    .item_id = "discovery-item",
                    .name = "bash",
                    .encoded_call_id = "discovery-call",
                    .decoded_call_id = "discovery-call",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                }};
                try settleCallsForTesting(&storage, &tmp, source, metadata[index], &calls);
                try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation", .{});
                if (corruption == .call) try store_testing.withoutForeignKeys(&storage, "DELETE FROM model_tool_call", .{});
                try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

/// The dispatch loop's work read against the owners it speaks for: each
/// call reads the hint, runs the owner, and expects the same answer.
const WorkParity = struct {
    /// The slot-free runners. Reads only, so any state can call it.
    fn core(storage: *Store) !void {
        const work = try storage.dispatchWork(false);
        try std.testing.expectEqual((try storage.nextCoreWorkForHost(false)) != null, work.core);
        try std.testing.expectEqual((try storage.nextCoreWork()) != null, work.core or work.mcp);
    }

    fn model(storage: *Store, kind: ModelAdmissionKind) !?AttemptBinding {
        try core(storage);
        const work = try storage.dispatchWork(kind == .open_turn_message);
        const admission = try storage.admitModelAttempt(kind, .{});
        try std.testing.expectEqual(admission != null, if (kind == .tool_continuation) work.tool_continuation else work.message);
        return if (admission) |found| found.permit.binding else null;
    }

    fn bash(storage: *Store) !?ActionAttemptBinding {
        try core(storage);
        const work = try storage.dispatchWork(false);
        const admission = try storage.admitNextActionAttempt(300_000, .{});
        try std.testing.expectEqual(admission != null, work.bash);
        return if (admission) |found| found.permit.binding else null;
    }

    /// Every owner at once, for a state where none has work.
    fn idle(storage: *Store) !void {
        for (std.enums.values(ModelAdmissionKind)) |kind| try std.testing.expect((try model(storage, kind)) == null);
        try std.testing.expect((try bash(storage)) == null);
    }
};

test "the dispatch work read answers as each admission owner does, in every state a Turn passes through" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try WorkParity.idle(&storage);
            try std.testing.expect(!(try storage.dispatchWork(false)).retry);

            // Waiting input: a new Turn takes it unless new Turns are held.
            const session = try configureTestSessionAsk(&storage, "parity-config");
            try submitTestMessage(&storage, &tmp, "parity-start", "parity-start", session.slice(), "start");
            try std.testing.expect((try WorkParity.model(&storage, .open_turn_message)) == null);
            try std.testing.expect((try WorkParity.model(&storage, .tool_continuation)) == null);
            const first = (try WorkParity.model(&storage, .message)).?;
            try WorkParity.idle(&storage);
            // Its running Attempt is what a retry scan would read; once it
            // resolves, neither scan has a row.
            try std.testing.expect((try storage.dispatchWork(false)).retry);

            // Two Bash calls wait on a person: a blocked Operation, no work.
            try settleTwoActionsForTesting(&storage, &tmp, first, "parity-config");
            try WorkParity.idle(&storage);
            try std.testing.expect(!(try storage.dispatchWork(false)).retry);
            try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()));
            var scheduled: ?u64 = 0;
            try std.testing.expect((try storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, &scheduled)) == null);
            try std.testing.expectEqual(@as(?u64, null), scheduled);
            // Input that arrives now joins the open Turn, held or not, once it continues.
            try submitTestMessage(&storage, &tmp, "parity-more", "parity-more", session.slice(), "more");
            const last_action = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
            try denyForTesting(&storage, session.slice(), "parity-deny", last_action - 1);
            try WorkParity.idle(&storage);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = last_action, .decision = .allow_once };
            try allow.key.set("parity-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            // An authorized Bash Action is Bash work alone.
            try std.testing.expect((try WorkParity.model(&storage, .tool_continuation)) == null);
            const action = (try WorkParity.bash(&storage)).?;
            try WorkParity.idle(&storage);
            try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
            // Its last result lets the Turn go on; the queued input makes that a message admission.
            try std.testing.expect((try WorkParity.bash(&storage)) == null);
            try std.testing.expect((try WorkParity.model(&storage, .tool_continuation)) == null);
            const joined = (try WorkParity.model(&storage, .open_turn_message)).?;
            try std.testing.expectEqual(first.turn_id, joined.turn_id);
            try WorkParity.idle(&storage);

            // A rejected call continues its Turn with no input.
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, joined, "parity-rejected", &calls);
            try std.testing.expect((try WorkParity.model(&storage, .message)) == null);
            try std.testing.expect((try WorkParity.model(&storage, .open_turn_message)) == null);
            const continued = (try WorkParity.model(&storage, .tool_continuation)).?;
            try std.testing.expectEqual(first.turn_id, continued.turn_id);
            try WorkParity.idle(&storage);

            // A core tool call is slot-free work, never Bash work.
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var command = try completeConfiguration("parity-agent", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            command.configuration.tools.state = .value;
            command.configuration.tools = try .of(&.{"message_agent"});
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const caller = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "parity-agent-task", "parity-agent-task", caller.slice(), "ask");
            const asking = (try WorkParity.model(&storage, .message)).?;
            const agent_calls = [_]TestingCall{.{ .item_id = "agent-item", .name = "message_agent", .encoded_call_id = "agent-call", .decoded_call_id = "agent-call", .encoded_arguments = "{\\\"id\\\":\\\"zzzzzz\\\",\\\"text\\\":\\\"hi\\\"}", .decoded_arguments = "{\"id\":\"zzzzzz\",\"text\":\"hi\"}" }};
            try settleCallsForTesting(&storage, &tmp, asking, "parity-agent-calls", &agent_calls);
            try std.testing.expect((try storage.dispatchWork(false)).core);
            try WorkParity.idle(&storage);
            const call = (try storage.nextCoreWork()).?.action;
            try std.testing.expectEqual(command_domain.AgentDelivery.failed, try storage.deliverAgentMessage(call.binding, "zzzzzz", "hi", .{}));
            try std.testing.expect(!(try storage.dispatchWork(false)).core);
            _ = (try WorkParity.model(&storage, .tool_continuation)).?;
            try WorkParity.idle(&storage);

            // A stop above an attached child with a Turn leaves that child's stop owed.
            const child = try configureTestSession(&storage, "parity-child");
            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ caller.slice(), child.slice() });
            try submitTestMessage(&storage, &tmp, "parity-child-task", "parity-child-task", child.slice(), "work");
            _ = (try WorkParity.model(&storage, .message)).?;
            var stop = try completeSessionStop("parity-stop", caller.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expect((try storage.dispatchWork(false)).core);
            try WorkParity.core(&storage);
        }
    }.run);
}

test "the dispatch work read fences a Store whose blocked Operations are malformed, as an empty admission does" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Malformed = enum { unrecorded, premature };
            for (std.enums.values(Malformed)) |malformed| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "malformed-config");
                try submitTestMessage(&storage, &tmp, "malformed", "malformed", session.slice(), "start");
                const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                switch (malformed) {
                    .unrecorded => {
                        const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                        try settleCallsForTesting(&storage, &tmp, first, "malformed-metadata", &calls);
                        try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=NULL", .{});
                    },
                    .premature => {
                        try settleTwoActionsForTesting(&storage, &tmp, first, "malformed-config");
                        try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=operation_id", .{});
                    },
                }
                try std.testing.expect(!storage.isFenced());
                try std.testing.expectError(error.CorruptStore, storage.dispatchWork(false));
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "an admission that selects nothing fences a Store whose blocked Operations are malformed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Malformed = enum { unrecorded, premature };
            for (std.enums.values(Malformed)) |malformed| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "malformed-admission");
                try submitTestMessage(&storage, &tmp, "malformed", "malformed", session.slice(), "start");
                const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                switch (malformed) {
                    .unrecorded => {
                        const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                        try settleCallsForTesting(&storage, &tmp, first, "malformed-metadata", &calls);
                        try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=NULL", .{});
                    },
                    .premature => {
                        try settleTwoActionsForTesting(&storage, &tmp, first, "malformed-admission");
                        try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=operation_id", .{});
                    },
                }
                try std.testing.expect(!storage.isFenced());
                // No Message waits, so the admission selects nothing.
                try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.message, .{}));
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "an admission that selects nothing fences a Store whose blocked Operation's calls fail the tool outcome rule" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "outcome-admission");
            try submitTestMessage(&storage, &tmp, "outcome", "outcome", session.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, first, "outcome-admission");
            // The calls lose their output items: the Turn still agrees it
            // waits, so only the calls' own round finds the damage.
            try store_testing.exec(&storage, "UPDATE model_output_item SET item_kind=1 WHERE item_kind=3", .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.message, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "an admission that selects nothing reads a blocked Operation's calls in a round of their own" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // Selection, then the idle checks.
            var rounds = storage.testing_content_work.rounds;
            try std.testing.expect(try storage.admitModelAttempt(.message, .{}) == null);
            if (!case.rerun) try std.testing.expectEqual(rounds + 2, storage.testing_content_work.rounds);
            const session = try configureTestSessionAsk(&storage, "blocked-admission");
            try submitTestMessage(&storage, &tmp, "blocked", "blocked", session.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, first, "blocked-admission");
            // Its asked calls block the Operation: their outcomes take a third round.
            rounds = storage.testing_content_work.rounds;
            try std.testing.expect(try storage.admitModelAttempt(.message, .{}) == null);
            if (!case.rerun) try std.testing.expectEqual(rounds + 3, storage.testing_content_work.rounds);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "an admission's commit reads the request's settings where its message carries reads, as their own round does" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            {
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "one");
                var view: HistoricalView = undefined;
                var settings: HistoricalSettings = undefined;
                const admitted = (try storage.admitModelAttemptInto(.message, .{}, .{ .view = &view, .settings = &settings })).?;
                const binding = admitted.permit.binding;
                // A lone write's COMMIT rides its message only on MySQL.
                if (!case.rerun) try std.testing.expectEqual(case.engine == .mysql, admitted.request_started);
                if (!admitted.request_started) storage.openHistoricalView(binding, &view);
                defer view.close();
                const before = storage.testing_content_work.rounds;
                try view.settings(&settings);
                try std.testing.expectEqual(before + @intFromBool(!admitted.request_started), storage.testing_content_work.rounds);
                // The settings a round of their own reads.
                var plain_view: HistoricalView = undefined;
                var plain: HistoricalSettings = undefined;
                storage.openHistoricalView(binding, &plain_view);
                defer plain_view.close();
                try plain_view.settings(&plain);
                inline for (.{ "operation", "compaction_trigger", "output_reservation", "reasoning_effort", "starting_effort", "codec", "provider", "session_affinity", "tool_count" }) |field|
                    try std.testing.expectEqual(@field(plain, field), @field(settings, field));
                inline for (.{ "model", "workspace", "store", "session" }) |field|
                    try std.testing.expectEqualStrings(@field(plain, field).slice(), @field(settings, field).slice());
                try std.testing.expectEqual(plain.baseline_instructions.content_id, settings.baseline_instructions.content_id);
                try std.testing.expectEqual(plain.baseline_instructions.length, settings.baseline_instructions.length);
                try std.testing.expectEqual(plain_view.output_boundary, view.output_boundary);
                try std.testing.expectEqual(plain_view.output_frontier, view.output_frontier);
                try std.testing.expectEqual(plain_view.tool_set_id, view.tool_set_id);
            }
        }
    }.run);
}

test "an admission's commit reads the first history round from where its caller remembers the Session resuming, and a stale memory costs only that round" {
    try store_testing.forEachEngine(struct {
        const Variant = enum { right, no_memory, other_position, other_cursor, other_base, other_tools };

        /// What a caller remembers of the one Session these cases drive.
        const Memory = struct {
            session: []const u8,
            resume_from: ?historical_domain.Resume,

            fn of(context: *anyopaque, session: []const u8) ?historical_domain.Resume {
                const memory: *const Memory = @ptrCast(@alignCast(context));
                return if (std.mem.eql(u8, memory.session, session)) memory.resume_from else null;
            }
        };

        /// The entries after `after` and every tool of the set, as a
        /// request that resumes its tool groups at `cursor` reads them.
        fn walk(view: *HistoricalView, after: u64, cursor: u64, buffer: []u8) ![]const u8 {
            while (!try view.validateOutputsStep()) {}
            _ = try view.coverage();
            view.expectTools(.all);
            if (after != 0) view.resumeToolGroups(cursor);
            var out = std.Io.Writer.fixed(buffer);
            var rendered: [16 * 1024]u8 = undefined;
            var position: TestingHistoryCursor = .{ .position = after };
            while (try position.next(view)) |entry| try out.print("{d}:{s};", .{ entry.position, try renderTestingEntry(view, entry, &rendered) });
            var tool: historical_domain.HistoricalTool = .{};
            while (try view.nextTool(&tool)) try out.print("tool {s};", .{tool.name.slice()});
            return out.buffered();
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "ahead-config");
            try submitTestMessage(&storage, &tmp, "ahead-0", "ahead-0", session.slice(), "question");
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"};
            var names: [std.enums.values(Variant).len][32]u8 = undefined;
            for (std.enums.values(Variant), &names) |variant, *name| {
                // What the last request's view ended with, as a caller keeps it.
                var last: HistoricalView = undefined;
                var last_settings: HistoricalSettings = undefined;
                storage.openHistoricalView(binding, &last);
                try last.settings(&last_settings);
                var scratch: [8 * 1024]u8 = undefined;
                _ = try walk(&last, 0, 0, &scratch);
                var end: u64 = 0;
                while (try last.nextEntry(end)) |entry| end = entry.position;
                const right: historical_domain.Resume = .{
                    .after_position = end,
                    .group_cursor = last.toolGroupCursor(),
                    .keys = last.resumeKeys(),
                    .tool_set = last.currentDeclaration().tool_set_id,
                    .tools = .all,
                };
                last.close();
                try std.testing.expect(end != 0);

                try settleItemsForTesting(&storage, &tmp, binding, &items, "answer");
                const key = try std.fmt.bufPrint(name, "ahead-{t}", .{variant});
                try submitTestMessage(&storage, &tmp, key, key, session.slice(), "follow-up");
                var remembered = right;
                switch (variant) {
                    .right, .no_memory, .other_position => {},
                    .other_cursor => remembered.group_cursor += 1,
                    .other_base => remembered.keys.base += 1,
                    .other_tools => remembered.tool_set += 1,
                }
                var memory: Memory = .{ .session = session.slice(), .resume_from = if (variant == .no_memory) null else remembered };
                var view: HistoricalView = undefined;
                var settings: HistoricalSettings = undefined;
                const admitted = (try storage.admitModelAttemptInto(.message, .{}, .{
                    .view = &view,
                    .settings = &settings,
                    .remembered = .{ .context = &memory, .of = Memory.of },
                })).?;
                binding = admitted.permit.binding;
                if (!case.rerun) try std.testing.expectEqual(case.engine == .mysql, admitted.request_started);
                if (!admitted.request_started) storage.openHistoricalView(binding, &view);
                defer view.close();
                // The request reads on from where its caller's memo ended,
                // or, its memo lost, from the start.
                const after = if (variant == .other_position) 0 else right.after_position;
                const rounds = ViewRounds.start(&storage);
                try view.settings(&settings);
                var buffer: [8 * 1024]u8 = undefined;
                const read = try walk(&view, after, right.group_cursor, &buffer);
                // Only the round read from where the request does read, by
                // the keys its own boundary gives, is its own.
                const ahead: u16 = if (!admitted.request_started) 2 else if (variant == .right) 0 else 1;
                try std.testing.expectEqual(ahead, rounds.taken().rounds);

                var plain_view: HistoricalView = undefined;
                var plain_settings: HistoricalSettings = undefined;
                storage.openHistoricalView(binding, &plain_view);
                defer plain_view.close();
                try plain_view.settings(&plain_settings);
                var plain_buffer: [8 * 1024]u8 = undefined;
                try std.testing.expectEqualStrings(try walk(&plain_view, after, right.group_cursor, &plain_buffer), read);
                try std.testing.expect(std.mem.indexOf(u8, read, "follow-up") != null);
                try std.testing.expect(std.mem.indexOf(u8, read, "tool ") != null);
                try std.testing.expectEqual(plain_view.toolGroupCursor(), view.toolGroupCursor());
            }
        }
    }.run);
}

test "model admission skips Sessions of a provider the Host does not serve" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("unserved", "", workspace, "model-a");
            var message: wire_request.MessageCommand = .{ .configuration = settings.configuration };
            try message.key.set("unserved");
            message.text = try testingBytesContent(&tmp, "unserved-message", "wait for a Host that serves me");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            {
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = protocol.routesAll(.unserved) });
                defer storage.close() catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
                try std.testing.expect(try storage.admitNextModelAttempt(.{}) == null);
            }
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = protocol.routesAll(.endpoint) });
            defer storage.close() catch unreachable;
            try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
        }
    }.run);
}

test "tool continuation selection never visits a Turn waiting for its tool results, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var rounds: [2]u16 = undefined;
            for (&rounds, 0..) |*cost, pass| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "waiting-{d}", .{pass});
                var config_buffer: [40]u8 = undefined;
                const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
                const session = try configureTestSessionAsk(&storage, config);
                try submitTestMessage(&storage, &tmp, name, name, session.slice(), "propose");
                const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, config);
                const counter = TwinRounds.start(&storage);
                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                cost.* = counter.taken();
            }
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code IS NULL", .{}));
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }
    }.run);
}

test "model admission work excludes failed historical Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |overflow| {
                const small = try Measure.run(case, 8, overflow);
                const large = try Measure.run(case, 1024, overflow);
                try std.testing.expectEqual(small, large);
            }
        }

        const Measure = struct {
            fn run(engine: *store_testing.Case, population: usize, overflow: bool) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
                const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                // Keep the actual current Operation newer than all injected history.
                try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001", .{});
                try store_testing.exec(&storage, failed_purpose_operations_sql, .{ population, current.operation_id });
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (overflow) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (overflow) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                return taken;
            }
        };
    }.run);
}

test "model admission work excludes accepted compaction base history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var bounded = true;
            for ([_]Measure.Suffix{ .unchanged, .low, .high, .missing }) |suffix| {
                const small = try Measure.run(case, 8, suffix);
                const large = try Measure.run(case, 128, suffix);
                bounded = bounded and large == small;
            }
            try std.testing.expect(bounded);
        }

        const Measure = struct {
            const Suffix = enum { unchanged, low, high, missing };

            fn run(engine: *store_testing.Case, population: usize, suffix: Suffix) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
                var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                for (0..population) |index| {
                    try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(base));
                    try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                    current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    if (index + 1 != population) {
                        // Provider-only suffix allows the next overflow recovery
                        // without accumulating retained host input.
                        const call = TestingCall{ .item_id = "old-item", .name = "unknown", .encoded_call_id = "old-call", .decoded_call_id = "old-call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                        try settleCallsForTestingWithFaults(&storage, &tmp, current, "old-output", &.{call}, .{}, null);
                        current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    }
                }
                if (suffix == .unchanged) {
                    try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "network" }, .ordinary, .{});
                } else {
                    const call = TestingCall{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                    try settleCallsForTestingWithFaults(&storage, &tmp, current, "output", &.{call}, .{}, switch (suffix) {
                        .low => "{\"input_tokens\":1,\"output_tokens\":0}",
                        .high => "{\"input_tokens\":1000,\"output_tokens\":0}",
                        .missing => null,
                        .unchanged => unreachable,
                    });
                }
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("policy");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (suffix == .high) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (suffix == .high) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                return taken;
            }
        };
    }.run);
}

test "model admission work excludes usage-covered accepted tool and instruction history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var bounded = true;
            for ([_]Measure.Population{ .rejection, .action, .instruction }) |kind| {
                for ([_]bool{ false, true }) |compact| {
                    const small = try Measure.run(case, 8, kind, compact);
                    const large = try Measure.run(case, 128, kind, compact);
                    bounded = bounded and large == small;
                }
            }
            try std.testing.expect(bounded);
        }

        const Measure = struct {
            const Population = enum { rejection, action, instruction };

            fn run(engine: *store_testing.Case, population: usize, kind: Population, compact: bool) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                if (kind == .action) {
                    var tools: wire_request.ConfigureCommand = .{};
                    try tools.key.set("tools");
                    try tools.session.set(session.slice());
                    tools.configuration.tools.state = .value;
                    try tools.configuration.tools.append("bash");
                    tools.configuration.permission_mode.state = .value;
                    try tools.configuration.permission_mode.value.set("bypass");
                    try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
                }
                const call = TestingCall{ .item_id = "item", .name = if (kind == .action) "bash" else "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = if (kind == .action) "{\\\"description\\\":\\\"Run no-op\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}" else "{}", .decoded_arguments = if (kind == .action) "{\"description\":\"Run no-op\",\"cmd\":\"true\",\"timeout_ms\":null}" else "{}" };
                const instructions: [400]u8 = @splat('x');
                for (0..population + 1) |index| {
                    var key: [64]u8 = undefined;
                    if (kind == .instruction) {
                        var patch: wire_request.ConfigureCommand = .{};
                        try patch.key.set(try std.fmt.bufPrint(&key, "instructions-{d}", .{index}));
                        try patch.session.set(session.slice());
                        patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", &instructions);
                        defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                        try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                    }
                    const message_key = try std.fmt.bufPrint(&key, "message-{d}", .{index});
                    try submitTestMessage(&storage, &tmp, "input", message_key, session.slice(), "old input");
                    const binding = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureInput).permit.binding;
                    if (kind == .instruction and index != population) {
                        // Isolate revision history from accepted-output population.
                        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                    } else {
                        try settleCallsForTestingWithFaults(&storage, &tmp, binding, "output", &.{call}, .{}, if (index == population) (if (compact) (if (kind == .instruction) "{\"input_tokens\":99900,\"output_tokens\":0}" else "{\"input_tokens\":99999,\"output_tokens\":0}") else "{\"input_tokens\":1,\"output_tokens\":0}") else null);
                    }
                    if (kind == .action) {
                        const action = (try storage.admitNextActionAttempt(1000, .{}) orelse return error.MissingPressureAction).permit.binding;
                        _ = try storage.settleActionAttempt(action, .succeeded, "result", .{});
                        // Measure the actual tool successor: the producer's result
                        // is after its usage/output and must remain in pressure.
                        if (index != population) {
                            const continuation = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureContinuation).permit.binding;
                            try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                        }
                    }
                }
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("policy");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("100000");
                if (kind == .instruction) {
                    // Same-text updates are new input, not content deduplication.
                    patch.configuration.instructions = try testingBytesContent(&tmp, "pending-instruction", &instructions);
                }
                defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                if (kind == .instruction) {
                    var clear: wire_request.ConfigureCommand = .{};
                    try clear.key.set("clear");
                    try clear.session.set(session.slice());
                    clear.configuration.instructions = try testingBytesContent(&tmp, "clear-instruction", "");
                    defer clear.removeTemporaryContent(std.testing.io) catch unreachable;
                    try std.testing.expect(try storage.configure(&clear, .{}) == .accepted);
                }
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                if (kind == .instruction) try std.testing.expectEqual(@as(u64, @intCast(population + 1 + @as(usize, if (compact) 0 else 2))), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_revision IS NOT NULL", .{}));
                return taken;
            }
        };
    }.run);
}
