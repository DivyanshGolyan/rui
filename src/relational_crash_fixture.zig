const std = @import("std");
const store_module = @import("host_store.zig");

const turn: store_module.AdmitTurn = .{
    .session_id = 10,
    .turn_id = 20,
    .turn_ordinal = 1,
    .entry_id = 30,
    .content_id = 40,
    .expected_conversation_revision = 0,
    .workspace_path = "/workspace",
    .access_scope_digest = [_]u8{0x11} ** 32,
    .admission_digest = .{
        0xaa, 0xb0, 0x3f, 0xaa, 0xf5, 0x71, 0x2d, 0xea,
        0x73, 0xad, 0xc1, 0x38, 0x12, 0xf3, 0x2d, 0xd5,
        0xbe, 0xfb, 0x92, 0xb3, 0x5b, 0x95, 0x8c, 0xd7,
        0x86, 0x5e, 0x9c, 0xa2, 0xa3, 0x3c, 0xc4, 0xc4,
    },
    .user_text = "crash proof",
};

fn operationCommand() store_module.AdmitOperation {
    return .{
        .turn_id = 20,
        .operation_id = 50,
        .operation_ordinal = 1,
        .kind = .model,
        .descriptor_content_id = 41,
        .descriptor = "request",
        .descriptor_digest = store_module.semanticDigest(.operation, "request"),
    };
}

fn attemptCommand() store_module.AdmitAttempt {
    return .{
        .operation_id = 50,
        .attempt_id = 60,
        .attempt_ordinal = 1,
        .dispatch_content_id = 41,
        .dispatch_request = "request",
        .dispatch_digest = store_module.semanticDigest(.dispatch, "request"),
        .parameters_content_id = 42,
        .parameters = "fixture:model",
        .context_cutoff_revision = 1,
        .workspace_digest = store_module.semanticDigest(.workspace, "/workspace"),
        .external_idempotency_key = null,
    };
}

fn completionCommand() store_module.CompleteAndResolve {
    return .{
        .operation_id = 50,
        .attempt_id = 60,
        .completion_id = 70,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .completion_content_id = 43,
        .completion_content = "observed",
        .completion_digest = store_module.semanticDigest(.completion, "observed"),
        .resolution_kind = .success,
        .result_content_id = 44,
        .result_content = "accepted",
        .resolution_digest = store_module.semanticDigest(.resolution, "accepted"),
    };
}

fn recordCompletionCommand() store_module.RecordCompletion {
    return .{
        .operation_id = 50,
        .attempt_id = 60,
        .completion_id = 70,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .content_id = 43,
        .content = "observed",
        .completion_digest = store_module.semanticDigest(.completion, "observed"),
    };
}

fn finalCommand() store_module.CompleteTurn {
    return .{
        .turn_id = 20,
        .model_operation_id = 50,
        .attempt_id = 60,
        .completion_id = 70,
        .completion_content_id = 43,
        .final_entry_id = 31,
        .final_content_id = 44,
        .captured_output = "captured final",
        .final_answer = "final",
        .completion_digest = store_module.semanticDigest(.completion, "captured final"),
        .expected_conversation_revision = 1,
    };
}

fn lostFailureCommand() store_module.FailTurnWithoutCompletion {
    return .{
        .turn_id = 20,
        .operation_id = 50,
        .result_content_id = 45,
        .message = "lost model custody",
        .failure_code = 1,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    var store = try store_module.Store.open(args[1]);
    defer store.close();
    const mode = args[2];
    if (std.mem.eql(u8, mode, "turn-before")) return crashTurn(&store, .after_turn_row);
    if (std.mem.eql(u8, mode, "turn-after")) return crashTurn(&store, .after_turn_commit);
    if (std.mem.eql(u8, mode, "verify-empty")) {
        if (store.readSession(turn.session_id)) |_| return error.UnexpectedSession else |err| {
            if (err != error.SessionNotFound) return err;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "verify-turn")) {
        const session = try store.readSession(turn.session_id);
        if (session.active_turn_id != turn.turn_id) return error.MissingTurn;
        if (try store.admitTurn(turn) != .replay) return error.MissingTurnReplay;
        var conflicting = turn;
        conflicting.entry_id += 1;
        if (store.admitTurn(conflicting)) |_| return error.ConflictingReplayAccepted else |err| {
            if (err != error.TurnConflict) return err;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "seed-turn")) return seedTurn(&store);
    if (std.mem.eql(u8, mode, "operation-before")) return crashOperation(&store, .before_operation_commit);
    if (std.mem.eql(u8, mode, "operation-after")) return crashOperation(&store, .after_operation_commit);
    if (std.mem.eql(u8, mode, "verify-no-operation")) {
        var frontier: [2]store_module.OperationView = undefined;
        if (try store.readUnresolvedOperations(turn.turn_id, &frontier) != 0) return error.UnexpectedOperation;
        return;
    }
    if (std.mem.eql(u8, mode, "verify-operation")) {
        var frontier: [2]store_module.OperationView = undefined;
        if (try store.readUnresolvedOperations(turn.turn_id, &frontier) != 1 or
            frontier[0].operation_id != 50 or
            try store.nextAttemptOrdinalForOperation(50) != 1) return error.MissingOperation;
        if (try store.admitOperation(operationCommand()) != .replay) return error.MissingOperationReplay;
        return;
    }
    if (std.mem.eql(u8, mode, "seed-operation-only")) return seedOperationOnly(&store);
    if (std.mem.eql(u8, mode, "attempt-before")) return crashAttempt(&store, .before_attempt_commit);
    if (std.mem.eql(u8, mode, "attempt-after")) return crashAttempt(&store, .after_attempt_commit);
    if (std.mem.eql(u8, mode, "verify-no-attempt")) {
        if (try store.nextAttemptOrdinalForOperation(50) != 1) return error.UnexpectedAttempt;
        return;
    }
    if (std.mem.eql(u8, mode, "verify-attempt")) {
        if (store_module.classify(try store.loadDecisionSnapshot(20)) != .in_flight) {
            return error.MissingAttempt;
        }
        if (try store.admitAttempt(attemptCommand()) != .replay) return error.MissingAttemptReplay;
        var conflicting = attemptCommand();
        conflicting.parameters = "fixture:other";
        if (store.admitAttempt(conflicting)) |_| return error.ConflictingReplayAccepted else |err| {
            if (err != error.AttemptConflict) return err;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "seed-operation")) return seedOperation(&store);
    if (std.mem.eql(u8, mode, "completion-after")) return crashCompletion(&store);
    if (std.mem.eql(u8, mode, "verify-completion")) {
        const completion = (try store.readUnresolvedCompletion(50)) orelse
            return error.CompletionMissing;
        if (completion.completion_id != 70 or
            store_module.classify(try store.loadDecisionSnapshot(20)) != .runnable)
        {
            return error.CompletionNotRunnable;
        }
        if (try store.completeAndResolve(completionCommand()) != .admitted) {
            return error.CompletionResolutionMissing;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "resolution-before")) return crashResolution(&store, .after_completion_row);
    if (std.mem.eql(u8, mode, "resolution-after")) return crashResolution(&store, .after_resolution_commit);
    if (std.mem.eql(u8, mode, "verify-unresolved")) {
        var frontier: [2]store_module.OperationView = undefined;
        if (try store.readUnresolvedOperations(turn.turn_id, &frontier) != 1) return error.MissingUnresolvedOperation;
        return;
    }
    if (std.mem.eql(u8, mode, "verify-resolved")) {
        var frontier: [2]store_module.OperationView = undefined;
        if (try store.readUnresolvedOperations(turn.turn_id, &frontier) != 0) return error.ResolutionMissing;
        if (try store.completeAndResolve(completionCommand()) != .replay) return error.ResolutionReplayMissing;
        return;
    }
    if (std.mem.eql(u8, mode, "final-before")) return crashFinal(&store, .after_final_entry);
    if (std.mem.eql(u8, mode, "final-after")) return crashFinal(&store, .after_turn_outcome_commit);
    if (std.mem.eql(u8, mode, "verify-final-uncommitted")) {
        const record = try store.readTurn(turn.turn_id);
        if (record.outcome != null or try store.sessionConversationRevision(turn.session_id) != 1) {
            return error.SplitFinalTurn;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "verify-final")) {
        if ((try store.readTurn(turn.turn_id)).outcome != .completed) return error.FinalTurnMissing;
        if (try store.completeTurn(finalCommand()) != .replay) return error.FinalTurnReplayMissing;
        return;
    }
    if (std.mem.eql(u8, mode, "failure-before")) return crashFailure(&store, .after_failure_resolution);
    if (std.mem.eql(u8, mode, "failure-after")) return crashFailure(&store, .after_turn_settlement_commit);
    if (std.mem.eql(u8, mode, "verify-failure-uncommitted")) {
        if ((try store.readTurn(20)).outcome != null or
            store_module.classify(try store.loadDecisionSnapshot(20)) != .in_flight)
        {
            return error.SplitFailedTurn;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "verify-failure")) {
        if ((try store.readTurn(20)).outcome != .failed) return error.FailedTurnMissing;
        if (try store.failTurnWithoutCompletion(lostFailureCommand()) != .replay) {
            return error.FailedTurnReplayMissing;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "cancel-before")) return crashCancellation(&store, .before_turn_settlement_commit);
    if (std.mem.eql(u8, mode, "cancel-after")) return crashCancellation(&store, .after_turn_settlement_commit);
    if (std.mem.eql(u8, mode, "verify-cancel-uncommitted")) {
        if ((try store.readTurn(20)).outcome != null) return error.SplitCancellation;
        return;
    }
    if (std.mem.eql(u8, mode, "verify-cancelled")) {
        if ((try store.readTurn(20)).outcome != .cancelled) return error.CancellationMissing;
        if (try store.settleTurn(.{ .turn_id = 20, .outcome = .cancelled }) != .replay) {
            return error.CancellationReplayMissing;
        }
        return;
    }
    return error.UnknownMode;
}

const Crash = struct {
    target: store_module.CrashPoint,

    fn hook(self: *Crash) store_module.FaultHook {
        return .{ .context = self, .reach_fn = reach };
    }

    fn reach(context: *anyopaque, point: store_module.CrashPoint) anyerror!void {
        const self: *Crash = @ptrCast(@alignCast(context));
        if (point == self.target) std.process.exit(91);
    }
};

fn crashTurn(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.admitTurn(turn);
    return error.CrashPointNotReached;
}

fn seedTurn(store: *store_module.Store) !void {
    _ = try store.admitTurn(turn);
}

fn crashOperation(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.admitOperation(operationCommand());
    return error.CrashPointNotReached;
}

fn seedOperationOnly(store: *store_module.Store) !void {
    try seedTurn(store);
    _ = try store.admitOperation(operationCommand());
}

fn crashAttempt(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.admitAttempt(attemptCommand());
    return error.CrashPointNotReached;
}

fn seedOperation(store: *store_module.Store) !void {
    _ = try store.admitTurn(turn);
    _ = try store.admitOperation(operationCommand());
    _ = try store.admitAttempt(attemptCommand());
}

fn crashResolution(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.completeAndResolve(completionCommand());
    return error.CrashPointNotReached;
}

fn crashCompletion(store: *store_module.Store) !void {
    var crash: Crash = .{ .target = .after_completion_commit };
    store.setFaultHook(crash.hook());
    _ = try store.recordCompletion(recordCompletionCommand());
    return error.CrashPointNotReached;
}

fn crashFinal(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.completeTurn(finalCommand());
    return error.CrashPointNotReached;
}

fn crashFailure(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.failTurnWithoutCompletion(lostFailureCommand());
    return error.CrashPointNotReached;
}

fn crashCancellation(store: *store_module.Store, point: store_module.CrashPoint) !void {
    var crash: Crash = .{ .target = point };
    store.setFaultHook(crash.hook());
    _ = try store.settleTurn(.{ .turn_id = 20, .outcome = .cancelled });
    return error.CrashPointNotReached;
}
