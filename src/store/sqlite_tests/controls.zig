//! Controls SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const AttemptBinding = store_core.AttemptBinding;
const ControlTracePhase = store_core.ControlTracePhase;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const SessionStopReply = command_domain.SessionStopReply;
const SettlementTracePhase = store_core.SettlementTracePhase;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeModelInterruption = tests.completeModelInterruption;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const expectContent = tests.expectContent;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleCallsForTestingWithFaults = tests.settleCallsForTestingWithFaults;
const testingStore = store_testing.testingSqliteStore;
const TestingStatements = shared_fixtures.TestingStatements;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;

test "controls wait behind an active model settlement transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "transaction-race-config");
    try submitTestMessage(
        &storage,
        &tmp,
        "transaction-race-message",
        "transaction-race-message",
        session.slice(),
        "execute",
    );
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "transaction-race-item",
        .name = "bash",
        .encoded_call_id = "transaction-race-call",
        .decoded_call_id = "transaction-race-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};

    const SettlementCheckpoint = enum(u8) { waiting, transaction_active, worker_finished };
    const Shared = struct {
        io: std.Io,
        order: std.atomic.Value(u64) = .init(0),
        checkpoint_ready: std.Io.Semaphore = .{},
        settlement_release: std.Io.Semaphore = .{},
        controls_requested: std.Io.Semaphore = .{},
        checkpoint: std.atomic.Value(SettlementCheckpoint) = .init(.waiting),
        transaction_active_order: std.atomic.Value(u64) = .init(0),
        settlement_complete_order: std.atomic.Value(u64) = .init(0),

        fn next(self: *@This()) u64 {
            return self.order.fetchAdd(1, .seq_cst) + 1;
        }

        fn settlementTrace(context: *anyopaque, phase: SettlementTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .transaction_active => {
                    self.transaction_active_order.store(self.next(), .seq_cst);
                    std.debug.assert(
                        self.checkpoint.cmpxchgStrong(
                            .waiting,
                            .transaction_active,
                            .acq_rel,
                            .acquire,
                        ) == null,
                    );
                    self.checkpoint_ready.post(self.io);
                    self.settlement_release.waitUncancelable(self.io);
                },
                .settlement_complete => self.settlement_complete_order.store(self.next(), .seq_cst),
                else => {},
            }
        }

        fn workerFinished(self: *@This()) void {
            if (self.checkpoint.swap(.worker_finished, .acq_rel) != .worker_finished) {
                self.checkpoint_ready.post(self.io);
            }
        }
    };
    const ControlProbe = struct {
        shared: *Shared,
        lock_acquired_order: std.atomic.Value(u64) = .init(0),

        fn mark(context: *anyopaque, phase: ControlTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .lock_requested => self.shared.controls_requested.post(self.shared.io),
                .lock_acquired => self.lock_acquired_order.store(self.shared.next(), .seq_cst),
                else => {},
            }
        }
    };
    const SettlementContext = struct {
        storage: *Store,
        tmp: *std.testing.TmpDir,
        binding: AttemptBinding,
        calls: []const TestingCall,
        shared: *Shared,
        failure_before_settlement: ?anyerror = null,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.shared.workerFinished();
            if (self.failure_before_settlement) |err| {
                self.result = err;
                return;
            }
            settleCallsForTestingWithFaults(
                self.storage,
                self.tmp,
                self.binding,
                "transaction-race-metadata",
                self.calls,
                .{ .settlement_trace = .{ .context = self.shared, .mark_fn = Shared.settlementTrace } },
                null,
            ) catch |err| {
                self.result = err;
            };
        }
    };
    const StopContext = struct {
        storage: *Store,
        command: *const protocol.SessionStopCommand,
        probe: ControlProbe,
        reply: ?SessionStopReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.stopSession(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };
    const InterruptContext = struct {
        storage: *Store,
        command: *const protocol.ModelInterruptionCommand,
        probe: ControlProbe,
        reply: ?ModelInterruptionReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.interruptModel(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };

    var early_shared: Shared = .{ .io = std.testing.io };
    var early: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &early_shared,
        .failure_before_settlement = error.InjectedSettlementCheckpointFailure,
    };
    const early_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&early});
    early_shared.checkpoint_ready.waitUncancelable(std.testing.io);
    early_thread.join();
    try std.testing.expectEqual(SettlementCheckpoint.worker_finished, early_shared.checkpoint.load(.acquire));
    try std.testing.expectEqual(error.InjectedSettlementCheckpointFailure, early.result.?);

    var shared: Shared = .{ .io = std.testing.io };
    var settlement_thread: ?std.Thread = null;
    var stop_thread: ?std.Thread = null;
    var interrupt_thread: ?std.Thread = null;
    var settlement_released = false;
    defer {
        if (!settlement_released) shared.settlement_release.post(std.testing.io);
        if (settlement_thread) |thread| thread.join();
        if (stop_thread) |thread| thread.join();
        if (interrupt_thread) |thread| thread.join();
    }
    var settlement: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &shared,
    };
    settlement_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&settlement});
    shared.checkpoint_ready.waitUncancelable(std.testing.io);
    if (shared.checkpoint.load(.acquire) == .worker_finished) {
        settlement_thread.?.join();
        settlement_thread = null;
        if (settlement.result) |err| return err;
        return error.SettlementCheckpointMissing;
    }
    try std.testing.expectEqual(SettlementCheckpoint.transaction_active, shared.checkpoint.load(.acquire));

    var stop = try completeSessionStop("transaction-race-stop", session.slice());
    var interrupt = try completeModelInterruption(
        "transaction-race-interrupt",
        session.slice(),
        binding,
    );
    var stop_context: StopContext = .{
        .storage = &storage,
        .command = &stop,
        .probe = .{ .shared = &shared },
    };
    var interrupt_context: InterruptContext = .{
        .storage = &storage,
        .command = &interrupt,
        .probe = .{ .shared = &shared },
    };
    stop_thread = try std.Thread.spawn(.{}, StopContext.run, .{&stop_context});
    interrupt_thread = try std.Thread.spawn(.{}, InterruptContext.run, .{&interrupt_context});
    shared.controls_requested.waitUncancelable(std.testing.io);
    shared.controls_requested.waitUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(!stop_context.finished.load(.seq_cst));
    try std.testing.expect(!interrupt_context.finished.load(.seq_cst));

    shared.settlement_release.post(std.testing.io);
    settlement_released = true;
    settlement_thread.?.join();
    settlement_thread = null;
    stop_thread.?.join();
    stop_thread = null;
    interrupt_thread.?.join();
    interrupt_thread = null;
    if (settlement.result) |err| return err;

    const settlement_complete_order = shared.settlement_complete_order.load(.seq_cst);
    try std.testing.expect(shared.transaction_active_order.load(.seq_cst) < settlement_complete_order);
    try std.testing.expect(settlement_complete_order < stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(settlement_complete_order < interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(c.SQLITE_TXN_NONE, c.sqlite3_txn_state(storage.sqliteDatabase(), "main"));

    const stop_reply = stop_context.reply.?;
    try std.testing.expect(stop_reply == .accepted);
    try std.testing.expectEqual(binding.turn_id, stop_reply.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, stop_reply.accepted.completion);
    const interrupt_reply = interrupt_context.reply.?;
    try std.testing.expect(interrupt_reply == .rejected);
    try std.testing.expectEqual(protocol.ModelInterruptionRejection.operation_resolved, interrupt_reply.rejected.code);

    const action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
    try expectContent(
        &storage,
        try storage.actionCallId(session.slice(), action_id),
        "transaction-race-call",
    );
    try expectContent(
        &storage,
        try storage.actionArguments(session.slice(), action_id),
        "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    );
}

test "a stop cancels its Actions in pages of one write each, in call order at dense positions" {
    // No Action, one, a page's edges and the next, two pages and one more.
    inline for (.{ 0, 1, 8, 9, 13, 14, 16, 17, 26, 27 }) |count| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "many-config");
        try submitTestMessage(&storage, &tmp, "many-input", "many-input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // With no Action, the model still runs, and the stop interrupts it.
        if (count != 0) {
            var texts: [count][4][96]u8 = undefined;
            var calls: [count]TestingCall = undefined;
            for (&calls, &texts, 0..) |*call, *text, index| {
                const id = try std.fmt.bufPrint(&text[0], "many-{d}", .{index});
                call.* = .{
                    .item_id = id,
                    .name = "bash",
                    .encoded_call_id = id,
                    .decoded_call_id = id,
                    .encoded_arguments = try std.fmt.bufPrint(&text[1], "{{\\\"description\\\":\\\"Run {d}\\\",\\\"cmd\\\":\\\"{d}\\\",\\\"timeout_ms\\\":null}}", .{ index, index }),
                    .decoded_arguments = try std.fmt.bufPrint(&text[2], "{{\"description\":\"Run {d}\",\"cmd\":\"{d}\",\"timeout_ms\":null}}", .{ index, index }),
                };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "many-calls", &calls);
        }
        try std.testing.expectEqual(@as(u64, count), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL AND attempt_ordinal=0", .{}));
        var stop = try completeSessionStop("many-stop", session.slice());
        var statements: TestingStatements = .{};
        statements.begin(storage.sqliteDatabase());
        const reply = storage.stopSession(&stop, .{});
        statements.end(storage.sqliteDatabase());
        try std.testing.expect(reply.accepted.completion == .completed);
        // BEGIN, the three reads of round 1, the command, the stop, the
        // Turn's close, the position advance and COMMIT; with no Action the
        // interruption; with Actions the text's lookup and insert, then a
        // page read and a write per `cancel_chunk` (13) Actions.
        const pages = (count + 12) / 13;
        // Closing the Turn also writes its owed ending.
        // The same commit also reads and clears its live frontier fact.
        const expected: u64 = if (count == 0) 13 else 14 + 2 * pages;
        try std.testing.expectEqual(expected, statements.count);
        try std.testing.expectEqual(@as(u64, count), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
        // Acceptance follows call order.
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN action_operation b " ++
            "ON b.parent_operation_id=a.parent_operation_id AND a.call_ordinal<b.call_ordinal WHERE a.acceptance_position>=b.acceptance_position", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code='cancelled'", .{}));
        try expectDenseSessionPositions(&storage, session.slice());
        try std.testing.expect(!storage.isFenced());
    }
}
