//! Commands a person or peer sends a Session (messages, Session stops, model
//! interruptions, permission decisions), their replay, and their observed results.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const AcceptedMessageQueue = reads_domain.AcceptedMessageQueue;
const AttemptBinding = store_core.AttemptBinding;
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;
const MessageCommitted = Store.MessageCommitted;
const MessageObservation = reads_domain.MessageObservation;
const MessageProgress = reads_domain.MessageProgress;
const TurnOutcome = turn_domain.TurnOutcome;
const operation_resolved_at_sql = model_settlement_domain.operation_resolved_at_sql;

pub const session_stop_cutoff_sql =
    "SELECT admission_cutoff FROM session_stop WHERE session_ref=?1 ORDER BY admission_cutoff DESC LIMIT 1";
pub const pending_message_count_sql =
    "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2";

pub const AcceptedMessage = struct {
    replayed: bool,
    admission_id: u64,
    content: ContentReference,
    session: protocol.Bounded(protocol.max_session_bytes),
};

pub const RejectedMessage = struct {
    replayed: bool,
    code: protocol.MessageRejection,
    content: ContentReference,
};

pub const MessageReply = union(enum) {
    accepted: AcceptedMessage,
    rejected: RejectedMessage,
    conflict,
    infrastructure_failure,
};

pub const StoredAnswer = struct {
    accepted: bool,
    code: protocol.Bounded(protocol.max_code_bytes) = .{},
    revision: u64 = 0,
    created: bool = false,
};

pub const CommandObservation = struct {
    status: protocol.CommandObservationStatus,
    kind: protocol.CommandKind = .configure,
    target: protocol.Bounded(protocol.max_session_bytes) = .{},
    code: protocol.Bounded(protocol.max_code_bytes) = .{},
    revision: u64 = 0,
    created: bool = false,
    message: ?MessageObservation = null,
    session_stop: ?SessionStopObservation = null,
    model_interruption: ?ModelInterruptionTarget = null,
    permission_action_id: ?u64 = null,
    permission_decision: ?protocol.PermissionDecision = null,
};

pub const SessionStopSelection = struct {
    selected_turn_id: ?u64 = null,
    admission_cutoff: u64,
};

pub const SessionStopObservation = struct {
    selection: SessionStopSelection,
    completion: protocol.SessionStopCompletion,
};

pub const ModelInterruptionTarget = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    turn_id: u64,
    operation_id: u64,
};

pub const SessionStopReply = union(enum) {
    accepted: struct {
        replayed: bool,
        selection: SessionStopSelection,
        completion: protocol.SessionStopCompletion,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: protocol.SessionStopRejection },
    conflict,
    infrastructure_failure,
};

pub const ModelInterruptionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: protocol.ModelInterruptionRejection },
    conflict,
    infrastructure_failure,
};

pub const PermissionDecisionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: protocol.PermissionDecisionRejection },
    conflict,
    infrastructure_failure,
};
pub const max_permission_decision_bytes = sqlite.maxEnumTagBytes(protocol.PermissionDecision);

const MessageProjection = struct {
    admission_id: u64,
    command_key: protocol.Bounded(128),
    session: protocol.Bounded(protocol.max_session_bytes),
    content_id: i64,
    state: union(enum) {
        pending,
        excluded: protocol.Bounded(128),
        applied: struct {
            binding: AttemptBinding,
            outcome_code: ?protocol.Bounded(protocol.max_code_bytes),
            outcome_content_id: ?i64,
        },
    },
};

pub fn submitMessageLocked(
    self: *Store,
    request: *const protocol.MessageCommand,
    committed: ?MessageCommitted,
    faults: Faults,
) !MessageReply {
    const command = request;
    // Only the Session changes: a creating Message answers with the one it created.
    var session = request.session;
    try store_core.execute(self, "BEGIN IMMEDIATE");
    const digest = command.semanticDigest();
    const supplied_content = ContentReference{
        .length = command.text.length,
        .digest = command.text.digest,
    };
    switch (try classifyReplay(self, protocol.MessageRejection, .message, command.key.slice(), session.slice(), &digest)) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => |existing| {
            const content_id = existing.primary_content_id orelse return error.CorruptStore;
            const metadata = try content_domain.readContentMetadata(self, content_id);
            const admission_id = try readMessageAdmission(
                self,
                command.key.slice(),
                existing.target.slice(),
                content_id,
            );
            return .{ .accepted = .{
                .replayed = true,
                .admission_id = admission_id,
                .content = .{ .length = metadata.length, .digest = metadata.digest },
                .session = existing.target,
            } };
        },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code, .content = supplied_content } },
    }
    // Only an authenticated Action can acquire a sender position.
    // A committed exact replay above needs no still-live launch handle.
    const sender_valid = try messageSenderMatchesLocked(self, command);
    const sender_known = command.sender != null and sender_valid;
    const creating = command.configuration != null;
    var code: ?protocol.MessageRejection = if (creating and session.len != 0 or
        !creating and !protocol.validSessionId(session.slice()))
        .invalid_session_reference
    else if (!sender_valid)
        .invalid_sender_handle
    else if (!creating and try turn_domain.sessionNextPosition(self, session.slice()) == null)
        .unknown_session
    else if (command.require_model and !try configuration_domain.servesProvider(self, if (command.configuration) |*value| value else null, session.slice()))
        .model_capability_unavailable
    else
        null;
    if (code == null) if (command.configuration) |*configuration| {
        switch (try configuration_domain.applyConfiguration(self, command.key.slice(), "", configuration, faults)) {
            .rejected => |rejection| code = std.meta.stringToEnum(protocol.MessageRejection, @tagName(rejection)).?,
            .accepted => |value| session = value.session,
        }
    };
    if (code) |rejection| {
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(rejection));
        try insertCommand(
            self,
            command.key.slice(),
            .message,
            session.slice(),
            &digest,
            null,
            null,
            answer,
        );
        if (sender_known) if (command.sender) |*sender| {
            const statement = try store_core.cached(self, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,?2,?3,unixepoch())");
            defer sqlite.resetCached(statement);
            try sqlite.bindText(statement, 1, command.key.slice());
            try sqlite.bindText(statement, 2, sender.session.slice());
            try sqlite.bindU64(statement, 3, try turn_domain.claimSessionPosition(self, sender.session.slice()));
            try sqlite.expectDone(statement);
        };
        if (faults.before_commit) return error.InjectedCommitFailure;
        try store_core.execute(self, "COMMIT");
        return .{ .rejected = .{ .replayed = false, .code = rejection, .content = supplied_content } };
    }
    const text_id = try content_domain.importContent(self, &command.text, faults);
    const metadata = try content_domain.readContentMetadata(self, text_id);
    try insertCommand(
        self,
        command.key.slice(),
        .message,
        session.slice(),
        &digest,
        text_id,
        null,
        .{ .accepted = true },
    );
    const admission_id = try insertMessageAdmission(
        self,
        session.slice(),
        command.key.slice(),
        text_id,
        if (command.sender) |*sender| sender.session.slice() else null,
    );
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    if (committed) |callback| callback.call(callback.context, .{
        .session = session.slice(),
        .admission_id = admission_id,
        .from_peer = command.sender != null,
    });
    return .{ .accepted = .{
        .replayed = false,
        .admission_id = admission_id,
        .content = .{ .length = metadata.length, .digest = metadata.digest },
        .session = session,
    } };
}

fn messageSenderMatchesLocked(self: *Store, command: *const protocol.MessageCommand) !bool {
    const handle = command.sender_handle orelse return command.sender == null;
    const claimed = if (command.sender) |*sender| sender else return false;
    if (!claimed.store.eql(self.selector.slice())) return false;
    const statement = try store_core.cached(self, "SELECT action.session_ref FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "WHERE action.sender_handle=?1 AND action.attempt_ordinal=1 AND action.resolution_code IS NULL " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id)");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, handle.slice());
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return false;
    if (step != c.SQLITE_ROW) return error.ActionReadFailed;
    var sender: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 0, &sender);
    return sender.eql(claimed.session.slice());
}

pub fn stopSessionLocked(
    self: *Store,
    command: *const protocol.SessionStopCommand,
    faults: Faults,
) !SessionStopReply {
    try store_core.execute(self, "BEGIN IMMEDIATE");
    const digest = command.semanticDigest();
    switch (try classifyReplay(self, protocol.SessionStopRejection, .session_stop, command.key.slice(), command.session.slice(), &digest)) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => {
            const selection = try readSessionStopSelection(self, command.key.slice());
            return .{ .accepted = .{
                .replayed = true,
                .selection = selection,
                .completion = try sessionStopCompletion(self, selection),
                .interrupted_operation_id = try readInterruptedOperation(self, command.key.slice()),
            } };
        },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
    }

    if (!protocol.validSessionId(command.session.slice())) {
        return saveSessionStopRejection(self, command, &digest, .invalid_session_reference, faults);
    }
    if (try turn_domain.sessionNextPosition(self, command.session.slice()) == null) {
        return saveSessionStopRejection(self, command, &digest, .unknown_session, faults);
    }

    const cutoff_statement = try store_core.cached(
        self,
        "SELECT coalesce(max(admission_id),0) FROM message_admission WHERE session_ref=?1",
    );
    defer sqlite.resetCached(cutoff_statement);
    try sqlite.bindText(cutoff_statement, 1, command.session.slice());
    if (c.sqlite3_step(cutoff_statement) != c.SQLITE_ROW) return error.StopSelectionFailed;
    const cutoff_value = c.sqlite3_column_int64(cutoff_statement, 0);
    if (cutoff_value < 0) return error.CorruptStore;

    const active_statement = try store_core.cached(
        self,
        "SELECT t.turn_id,t.operation_id,o.resolution_code FROM turn t " ++
            "JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE t.session_ref=?1 AND t.outcome_code IS NULL",
    );
    defer sqlite.resetCached(active_statement);
    try sqlite.bindText(active_statement, 1, command.session.slice());
    const active_result = c.sqlite3_step(active_statement);
    var selected_turn_id: ?u64 = null;
    var current_operation_id: ?u64 = null;
    var operation_unresolved = false;
    if (active_result == c.SQLITE_ROW) {
        const turn_value = c.sqlite3_column_int64(active_statement, 0);
        const operation_value = c.sqlite3_column_int64(active_statement, 1);
        if (turn_value <= 0 or operation_value <= 0) return error.CorruptStore;
        selected_turn_id = @intCast(turn_value);
        current_operation_id = @intCast(operation_value);
        operation_unresolved = c.sqlite3_column_type(active_statement, 2) == c.SQLITE_NULL;
    } else if (active_result != c.SQLITE_DONE) return error.StopSelectionFailed;

    try insertCommand(
        self,
        command.key.slice(),
        .session_stop,
        command.session.slice(),
        &digest,
        null,
        null,
        .{ .accepted = true },
    );
    {
        const position = try turn_domain.claimSessionPosition(self, command.session.slice());
        const insert = try store_core.cached(
            self,
            "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) VALUES(?1,?2,?3,?4,?5,unixepoch())",
        );
        defer sqlite.resetCached(insert);
        try sqlite.bindText(insert, 1, command.key.slice());
        try sqlite.bindText(insert, 2, command.session.slice());
        try sqlite.bindNullableU64(insert, 3, selected_turn_id);
        try sqlite.bindI64(insert, 4, cutoff_value);
        try sqlite.bindU64(insert, 5, position);
        try sqlite.expectDone(insert);
    }
    var interrupted_operation_id: ?u64 = null;
    if (selected_turn_id) |turn_id| {
        if (operation_unresolved) {
            interruptOperation(self, current_operation_id.?, command.key.slice()) catch |err| {
                return switch (err) {
                    error.InterruptionTargetChanged => error.StopSelectionChanged,
                    else => err,
                };
            };
            interrupted_operation_id = current_operation_id;
        }
        const unresolved_actions = try store_core.cached(
            self,
            "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 " ++
                "AND resolution_code IS NULL AND attempt_ordinal=0",
        );
        defer sqlite.resetCached(unresolved_actions);
        try sqlite.bindU64(unresolved_actions, 1, current_operation_id.?);
        if (c.sqlite3_step(unresolved_actions) != c.SQLITE_ROW) return error.ActionReadFailed;
        const unresolved_count = c.sqlite3_column_int64(unresolved_actions, 0);
        if (unresolved_count < 0) return error.CorruptStore;
        if (unresolved_count != 0) {
            const cancellation_content_id = try content_domain.importBytesContent(self, "Cancelled by Session stop.", false, faults.content_import);
            const first_position = try turn_domain.claimSessionPositions(self, command.session.slice(), @intCast(unresolved_count));
            const cancel_actions = try store_core.cached(
                self,
                "WITH cancelled(action_id,acceptance_position) AS MATERIALIZED (" ++
                    "SELECT action_id,?3+row_number() OVER (ORDER BY call_ordinal)-1 FROM action_operation " ++
                    "WHERE parent_operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=0) " ++
                    "UPDATE action_operation SET resolution_code='cancelled',resolution_content_id=?2,resolved_at=unixepoch()," ++
                    "acceptance_position=(SELECT acceptance_position FROM cancelled WHERE cancelled.action_id=action_operation.action_id) " ++
                    "WHERE action_id IN (SELECT action_id FROM cancelled)",
            );
            defer sqlite.resetCached(cancel_actions);
            try sqlite.bindU64(cancel_actions, 1, current_operation_id.?);
            try sqlite.bindI64(cancel_actions, 2, cancellation_content_id);
            try sqlite.bindU64(cancel_actions, 3, first_position);
            try sqlite.expectDone(cancel_actions);
            if (c.sqlite3_changes(self.database) != unresolved_count) return error.StopSelectionChanged;
        }
        try turn_domain.completeStoppedTurnIfReady(self, turn_id);
    }
    const selection = SessionStopSelection{
        .selected_turn_id = selected_turn_id,
        .admission_cutoff = @intCast(cutoff_value),
    };
    const completion = try sessionStopCompletion(self, selection);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
    return .{ .accepted = .{
        .replayed = false,
        .selection = selection,
        .completion = completion,
        .interrupted_operation_id = interrupted_operation_id,
    } };
}

fn saveSessionStopRejection(
    self: *Store,
    command: *const protocol.SessionStopCommand,
    digest: *const [32]u8,
    code: protocol.SessionStopRejection,
    faults: Faults,
) !SessionStopReply {
    var answer = StoredAnswer{ .accepted = false };
    try answer.code.set(@tagName(code));
    try insertCommand(
        self,
        command.key.slice(),
        .session_stop,
        command.session.slice(),
        digest,
        null,
        null,
        answer,
    );
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    return .{ .rejected = .{ .replayed = false, .code = code } };
}

pub fn interruptModelLocked(
    self: *Store,
    command: *const protocol.ModelInterruptionCommand,
    faults: Faults,
) !ModelInterruptionReply {
    try store_core.execute(self, "BEGIN IMMEDIATE");
    const digest = command.semanticDigest();
    const replay = try classifyReplay(self, protocol.ModelInterruptionRejection, .model_interruption, command.key.slice(), command.session.slice(), &digest);
    if (replay == .accepted or replay == .rejected) {
        const saved_target = try readModelInterruptionTarget(self, command.key.slice());
        if (!saved_target.session.eql(command.session.slice()) or
            saved_target.turn_id != command.turn_id or
            saved_target.operation_id != command.operation_id) return error.CorruptStore;
    }
    switch (replay) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => return .{ .accepted = .{ .replayed = true } },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
    }

    var rejection: ?protocol.ModelInterruptionRejection = null;
    if (!protocol.validSessionId(command.session.slice())) {
        rejection = .invalid_session_reference;
    } else if (command.turn_id == 0 or command.operation_id == 0 or
        command.turn_id > std.math.maxInt(i64) or command.operation_id > std.math.maxInt(i64))
    {
        rejection = .invalid_target;
    } else if (try turn_domain.sessionNextPosition(self, command.session.slice()) == null) {
        rejection = .unknown_session;
    }

    if (rejection == null) {
        const operation = try store_core.cached(
            self,
            "SELECT turn_id,session_ref,resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer sqlite.resetCached(operation);
        try sqlite.bindU64(operation, 1, command.operation_id);
        const result = c.sqlite3_step(operation);
        if (result == c.SQLITE_DONE) {
            rejection = .unknown_operation;
        } else if (result != c.SQLITE_ROW) {
            return error.InterruptionTargetReadFailed;
        } else {
            const turn_value = c.sqlite3_column_int64(operation, 0);
            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(operation, 1, &session);
            if (turn_value <= 0 or @as(u64, @intCast(turn_value)) != command.turn_id or
                !session.eql(command.session.slice()))
            {
                rejection = .target_mismatch;
            } else if (c.sqlite3_column_type(operation, 2) != c.SQLITE_NULL) {
                rejection = .operation_resolved;
            }
        }
    }

    if (rejection) |code| {
        return saveModelInterruptionAnswer(self, command, &digest, false, @tagName(code), faults);
    }
    try store_core.touch(self, command.session.slice());

    const current_turn = try store_core.cached(
        self,
        "SELECT 1 FROM turn WHERE turn_id=?1 AND session_ref=?2 AND operation_id=?3 AND outcome_code IS NULL",
    );
    defer sqlite.resetCached(current_turn);
    try sqlite.bindU64(current_turn, 1, command.turn_id);
    try sqlite.bindText(current_turn, 2, command.session.slice());
    try sqlite.bindU64(current_turn, 3, command.operation_id);
    const current_result = c.sqlite3_step(current_turn);
    if (current_result == c.SQLITE_DONE) {
        return saveModelInterruptionAnswer(
            self,
            command,
            &digest,
            false,
            @tagName(protocol.ModelInterruptionRejection.target_mismatch),
            faults,
        );
    }
    if (current_result != c.SQLITE_ROW) return error.InterruptionTargetReadFailed;

    try insertModelInterruptionCommand(self, command, &digest, .{ .accepted = true });
    try interruptOperation(self, command.operation_id, command.key.slice());
    if (!try hasApplicablePendingMessage(self, command.session.slice())) {
        if (!try turn_domain.closeTurn(self, command.turn_id, command.operation_id, .cancelled)) return error.InterruptionTargetChanged;
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
    return .{ .accepted = .{ .replayed = false } };
}

// The caller owns the Store lock and transaction, including the causing command.
fn interruptOperation(self: *Store, operation_id: u64, command_key: []const u8) !void {
    const update = try store_core.cached(
        self,
        "UPDATE model_operation SET retry_due_at_ms=NULL," ++ store_schema.resolutionIs("resolution_code", .interrupted) ++ "," ++
            "interrupted_by_command_key=?2," ++ operation_resolved_at_sql ++ " WHERE operation_id=?1 AND resolution_code IS NULL",
    );
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, operation_id);
    try sqlite.bindText(update, 2, command_key);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.InterruptionTargetChanged;
}

fn saveModelInterruptionAnswer(
    self: *Store,
    command: *const protocol.ModelInterruptionCommand,
    digest: *const [32]u8,
    accepted: bool,
    code: []const u8,
    faults: Faults,
) !ModelInterruptionReply {
    var answer = StoredAnswer{ .accepted = accepted };
    try answer.code.set(code);
    try insertModelInterruptionCommand(self, command, digest, answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    if (accepted) return .{ .accepted = .{ .replayed = false } };
    return .{ .rejected = .{
        .replayed = false,
        .code = std.meta.stringToEnum(protocol.ModelInterruptionRejection, code) orelse unreachable,
    } };
}

fn insertModelInterruptionCommand(
    self: *Store,
    command: *const protocol.ModelInterruptionCommand,
    digest: *const [32]u8,
    answer: StoredAnswer,
) !void {
    try insertCommand(
        self,
        command.key.slice(),
        .model_interruption,
        command.session.slice(),
        digest,
        null,
        null,
        answer,
    );
    var turn_buffer: [20]u8 = undefined;
    const turn = try std.fmt.bufPrint(&turn_buffer, "{d}", .{command.turn_id});
    var operation_buffer: [20]u8 = undefined;
    const operation = try std.fmt.bufPrint(&operation_buffer, "{d}", .{command.operation_id});
    const insert = try store_core.cached(
        self,
        "INSERT INTO model_interruption_command(command_key,session_ref,turn_id,operation_id) VALUES(?1,?2,?3,?4)",
    );
    defer sqlite.resetCached(insert);
    try sqlite.bindText(insert, 1, command.key.slice());
    try sqlite.bindText(insert, 2, command.session.slice());
    try sqlite.bindText(insert, 3, turn);
    try sqlite.bindText(insert, 4, operation);
    try sqlite.expectDone(insert);
}

pub fn decidePermissionLocked(
    self: *Store,
    command: *const protocol.PermissionDecisionCommand,
    faults: Faults,
) !PermissionDecisionReply {
    try store_core.execute(self, "BEGIN IMMEDIATE");
    const digest = command.semanticDigest();
    switch (try classifyReplay(self, protocol.PermissionDecisionRejection, .permission_decision, command.key.slice(), command.session.slice(), &digest)) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => return .{ .accepted = .{ .replayed = true } },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
    }
    var rejection: ?protocol.PermissionDecisionRejection = null;
    var turn_id: ?u64 = null;
    if (!protocol.validSessionId(command.session.slice())) rejection = .invalid_session_reference else if (command.action_id == 0 or
        command.action_id > std.math.maxInt(i64)) rejection = .invalid_target else if (try turn_domain.sessionNextPosition(self, command.session.slice()) == null) rejection = .unknown_session;
    if (rejection == null) {
        const action = try store_core.cached(
            self,
            "SELECT a.session_ref,a.authorized,a.resolution_code,t.outcome_code,t.turn_id FROM action_operation a " ++
                "JOIN model_operation operation ON operation.operation_id=a.parent_operation_id " ++
                "JOIN turn t ON t.turn_id=operation.turn_id WHERE a.action_id=?1",
        );
        defer sqlite.resetCached(action);
        try sqlite.bindU64(action, 1, command.action_id);
        const row = c.sqlite3_step(action);
        if (row == c.SQLITE_DONE) rejection = .unknown_action else if (row != c.SQLITE_ROW) return error.ActionReadFailed else {
            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(action, 0, &session);
            if (!session.eql(command.session.slice())) rejection = .target_mismatch else if (c.sqlite3_column_int(action, 1) != 0 or
                c.sqlite3_column_type(action, 2) != c.SQLITE_NULL or
                c.sqlite3_column_type(action, 3) != c.SQLITE_NULL) rejection = .action_not_pending;
            turn_id = @intCast(try sqlite.readNullablePositiveI64(action, 4) orelse return error.CorruptStore);
        }
    }
    var answer = StoredAnswer{ .accepted = rejection == null };
    if (rejection) |code| try answer.code.set(@tagName(code));
    try insertCommand(self, command.key.slice(), .permission_decision, command.session.slice(), &digest, null, null, answer);
    var action_buffer: [20]u8 = undefined;
    const action_text = try std.fmt.bufPrint(&action_buffer, "{d}", .{command.action_id});
    const save = try store_core.cached(self, "INSERT INTO permission_decision_command(command_key,action_id,decision) VALUES(?1,?2,?3)");
    defer sqlite.resetCached(save);
    try sqlite.bindText(save, 1, command.key.slice());
    try sqlite.bindText(save, 2, action_text);
    try sqlite.bindText(save, 3, @tagName(command.decision));
    try sqlite.expectDone(save);
    if (rejection == null) {
        try store_core.touch(self, command.session.slice());
        switch (command.decision) {
            .allow_once => {
                const update = try store_core.cached(self, "UPDATE action_operation SET authorized=1,decided_at=unixepoch() WHERE action_id=?1 AND authorized=0 AND resolution_code IS NULL");
                defer sqlite.resetCached(update);
                try sqlite.bindU64(update, 1, command.action_id);
                try sqlite.expectDone(update);
                if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
            },
            .deny => {
                const result_content_id = try content_domain.importBytesContent(self, "Permission denied.", false, faults.content_import);
                const position = try turn_domain.claimSessionPosition(self, command.session.slice());
                const update = try store_core.cached(
                    self,
                    "UPDATE action_operation SET resolution_code='denied',resolution_content_id=?2,acceptance_position=?3,resolved_at=unixepoch() " ++
                        "WHERE action_id=?1 AND resolution_code IS NULL",
                );
                defer sqlite.resetCached(update);
                try sqlite.bindU64(update, 1, command.action_id);
                try sqlite.bindI64(update, 2, result_content_id);
                try sqlite.bindU64(update, 3, position);
                try sqlite.expectDone(update);
                if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
                try turn_domain.recordContinuation(self, turn_id.?);
            },
        }
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    if (rejection) |code| return .{ .rejected = .{ .replayed = false, .code = code } };
    if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
    return .{ .accepted = .{ .replayed = false } };
}

pub fn observeCommandLocked(self: *Store, key: []const u8) !CommandObservation {
    const existing = try readExistingCommand(self, key);
    const command = existing orelse return .{ .status = .absent };
    var observation = CommandObservation{
        .status = if (command.accepted) .accepted else .rejected,
        .kind = command.kind,
        .revision = command.revision,
        .created = command.created,
    };
    observation.target = command.target;
    observation.code = command.code;
    if (command.kind == .message and command.accepted) {
        const content_id = command.primary_content_id orelse
            return error.CorruptStore;
        const metadata = try content_domain.readContentMetadata(self, content_id);
        observation.message = .{
            .content = .{ .length = metadata.length, .digest = metadata.digest },
            .queue = try readMessageQueue(
                self,
                key,
                command.target.slice(),
                content_id,
                command.accepted,
            ),
        };
        const queue = observation.message.?.queue orelse return error.CorruptStore;
        switch (queue.state) {
            .queued, .processing => {
                observation.message.?.progress = try readMessageProgress(self, command.target.slice(), queue.state);
            },
            else => {},
        }
    } else if (command.kind == .session_stop and command.accepted) {
        const selection = try readSessionStopSelection(self, key);
        observation.session_stop = .{
            .selection = selection,
            .completion = try sessionStopCompletion(self, selection),
        };
    } else if (command.kind == .model_interruption) {
        observation.model_interruption = try readModelInterruptionTarget(self, key);
    } else if (command.kind == .permission_decision) {
        const target = try readPermissionTarget(self, key);
        observation.permission_action_id = target.action_id;
        observation.permission_decision = target.decision;
    }
    return observation;
}

fn readMessageQueue(
    self: *Store,
    command_key: []const u8,
    session_ref: []const u8,
    content_id: i64,
    accepted: bool,
) !?AcceptedMessageQueue {
    const statement = try store_core.cached(
        self,
        "SELECT m.session_ref,m.content_id,m.admission_id,m.command_key,m.turn_id,t.operation_id,o.attempt_ordinal," ++
            "t.outcome_code,t.outcome_content_id,CASE WHEN m.turn_id IS NULL THEN (" ++
            "SELECT stopped.command_key FROM session_stop stopped JOIN core_command stop_command " ++
            "ON stop_command.command_key=stopped.command_key WHERE stopped.session_ref=m.session_ref " ++
            "AND m.admission_id<=stopped.admission_cutoff ORDER BY stop_command.rowid LIMIT 1) END " ++
            "FROM message_admission m " ++
            "LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
            "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE m.command_key=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return if (accepted) error.CorruptStore else null;
    if (step != c.SQLITE_ROW) return error.CorruptStore;
    if (!accepted) return error.CorruptStore;
    var stop_key: protocol.Bounded(128) = .{};
    const excluding_stop = if (c.sqlite3_column_type(statement, 9) == c.SQLITE_NULL)
        null
    else blk: {
        try sqlite.readText(statement, 9, &stop_key);
        break :blk stop_key.slice();
    };
    const projection = try readMessageProjectionRow(statement, excluding_stop);
    if (!projection.session.eql(session_ref) or projection.content_id != content_id or
        !projection.command_key.eql(command_key)) return error.CorruptStore;
    return switch (projection.state) {
        .pending => .{ .admission_id = projection.admission_id, .state = .queued },
        .excluded => blk: {
            var code: protocol.Bounded(protocol.max_code_bytes) = .{};
            try code.set("session_stopped");
            break :blk .{ .admission_id = projection.admission_id, .state = .{ .excluded = .{ .code = code } } };
        },
        .applied => |applied| blk: {
            const outcome = applied.outcome_code orelse
                break :blk .{ .admission_id = projection.admission_id, .state = .{ .processing = applied.binding } };
            break :blk switch (try TurnOutcome.decode(outcome.slice(), applied.outcome_content_id)) {
                .completed => |answer_id| completed: {
                    const answer = try content_domain.readContentMetadata(self, answer_id);
                    break :completed .{ .admission_id = projection.admission_id, .state = .{ .completed = .{
                        .binding = applied.binding,
                        .answer = .{ .length = answer.length, .digest = answer.digest },
                    } } };
                },
                .cancelled => .{ .admission_id = projection.admission_id, .state = .{ .cancelled = .{ .binding = applied.binding, .code = outcome } } },
                .retry_exhausted, .resource_exceeded, .failed => .{ .admission_id = projection.admission_id, .state = .{ .failed = .{ .binding = applied.binding, .code = outcome } } },
            };
        },
    };
}

/// A pending Message's progress is its Session's work: its own active
/// Turn, or the work ahead of it in the queue.
fn readMessageProgress(self: *Store, session_ref: []const u8, state: AcceptedMessageQueue.State) !MessageProgress {
    const session = (try configuration_domain.readSessionFacts(self, session_ref, null)) orelse return error.CorruptStore;
    const work = (try report_domain.readWorkLocked(self, session_ref, session.created_at, try store_core.readUnixMilliseconds(self.io))).work;
    if (state == .processing and work.turn != state.processing.turn_id) return error.CorruptStore;
    return .{ .status = work.state.progress() orelse return error.CorruptStore, .action_id = work.first_action };
}

pub fn commandResultLocked(self: *Store, key: []const u8) !ContentReference {
    const statement = try store_core.cached(
        self,
        "SELECT t.outcome_code,t.outcome_content_id,EXISTS(" ++
            "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
            "AND m.admission_id<=stopped.admission_cutoff) FROM core_command command " ++
            "JOIN message_admission m ON m.command_key=command.command_key " ++
            "LEFT JOIN turn t ON t.turn_id=m.turn_id WHERE command.command_key=?1 AND command.kind=2 AND command.accepted=1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, key);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.ResultNotFound;
    if (step != c.SQLITE_ROW) return error.ResultReadFailed;
    if (c.sqlite3_column_int(statement, 2) != 0 and c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) {
        return error.ResultFailed;
    }
    if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return error.ResultNotReady;
    var outcome: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 0, &outcome);
    switch (try TurnOutcome.decode(outcome.slice(), try sqlite.readNullablePositiveI64(statement, 1))) {
        .completed => |content_id| {
            const metadata = try content_domain.readContentMetadata(self, content_id);
            return .{ .length = metadata.length, .digest = metadata.digest };
        },
        .cancelled, .retry_exhausted, .resource_exceeded, .failed => return error.ResultFailed,
    }
}

const ExistingCommand = struct {
    kind: protocol.CommandKind,
    target: protocol.Bounded(protocol.max_session_bytes),
    digest: [32]u8,
    accepted: bool,
    code: protocol.Bounded(protocol.max_code_bytes),
    revision: u64,
    created: bool,
    primary_content_id: ?i64,
};

fn Replay(comptime Rejection: type) type {
    return union(enum) {
        /// No saved command; the caller's transaction stays open.
        fresh,
        conflict,
        accepted: ExistingCommand,
        rejected: Rejection,
    };
}

/// Classifies a keyed command against its saved answer. Any saved answer
/// ends the caller's transaction before it returns.
pub fn classifyReplay(
    self: *Store,
    comptime Rejection: type,
    kind: protocol.CommandKind,
    key: []const u8,
    target: []const u8,
    digest: *const [32]u8,
) !Replay(Rejection) {
    const existing = try readExistingCommand(self, key) orelse return .fresh;
    try store_core.rollback(self);
    if (existing.kind != kind or (!((kind == .configure or kind == .message) and target.len == 0) and !existing.target.eql(target)) or
        !std.mem.eql(u8, &existing.digest, digest)) return .conflict;
    if (existing.accepted) return .{ .accepted = existing };
    return .{ .rejected = std.meta.stringToEnum(Rejection, existing.code.slice()) orelse
        return error.CorruptStore };
}

fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
    const statement = try store_core.cached(self, "SELECT kind,target,input_digest,accepted,code,revision,created,primary_content_id FROM core_command WHERE command_key=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, key);
    const step_result = c.sqlite3_step(statement);
    if (step_result == c.SQLITE_DONE) return null;
    if (step_result != c.SQLITE_ROW) return error.CommandReadFailed;
    const kind_value = c.sqlite3_column_int(statement, 0);
    const kind: protocol.CommandKind = switch (kind_value) {
        1 => .configure,
        2 => .message,
        3 => .session_stop,
        4 => .model_interruption,
        5 => .permission_decision,
        else => return error.CorruptStore,
    };
    var target: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 1, &target);
    const digest = try sqlite.readDigest(statement, 2);
    const accepted_value = c.sqlite3_column_int(statement, 3);
    if (accepted_value != 0 and accepted_value != 1) return error.CorruptStore;
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 4, &code);
    const revision_value = c.sqlite3_column_int64(statement, 5);
    if (revision_value < 0) return error.CorruptStore;
    const created_value = c.sqlite3_column_int(statement, 6);
    if (created_value != 0 and created_value != 1) return error.CorruptStore;
    const primary_content_id = sqlite.readNullablePositiveI64(statement, 7) catch return error.CorruptStore;
    return .{
        .kind = kind,
        .target = target,
        .digest = digest,
        .accepted = accepted_value == 1,
        .code = code,
        .revision = @intCast(revision_value),
        .created = created_value == 1,
        .primary_content_id = primary_content_id,
    };
}

fn readMessageAdmission(
    self: *Store,
    command_key: []const u8,
    session_ref: []const u8,
    content_id: i64,
) !u64 {
    const statement = try store_core.cached(self, "SELECT admission_id,session_ref,content_id FROM message_admission WHERE command_key=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const admission_id = c.sqlite3_column_int64(statement, 0);
    var stored_session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 1, &stored_session);
    if (admission_id <= 0 or
        !stored_session.eql(session_ref) or
        c.sqlite3_column_int64(statement, 2) != content_id)
    {
        return error.CorruptStore;
    }
    return @intCast(admission_id);
}

pub fn countPendingMessages(self: *Store, session_ref: []const u8) !u64 {
    const cutoff = try latestSessionStopCutoff(self, session_ref);
    const statement = try store_core.cached(self, pending_message_count_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    try sqlite.bindU64(statement, 2, cutoff);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.MessageAdmissionReadFailed;
    const count = c.sqlite3_column_int64(statement, 0);
    if (count < 0) return error.CorruptStore;
    return @intCast(count);
}

fn hasApplicablePendingMessage(self: *Store, session_ref: []const u8) !bool {
    const cutoff = try latestSessionStopCutoff(self, session_ref);
    const statement = try store_core.cached(
        self,
        "SELECT 1 FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 LIMIT 1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    try sqlite.bindU64(statement, 2, cutoff);
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.MessageAdmissionReadFailed,
    };
}

pub fn latestSessionStopCutoff(self: *Store, session_ref: []const u8) !u64 {
    const statement = try store_core.cached(self, session_stop_cutoff_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => 0,
        c.SQLITE_ROW => blk: {
            const cutoff = c.sqlite3_column_int64(statement, 0);
            if (cutoff < 0) return error.CorruptStore;
            break :blk @intCast(cutoff);
        },
        else => error.SessionStopReadFailed,
    };
}

fn readSessionStopSelection(self: *Store, command_key: []const u8) !SessionStopSelection {
    const statement = try store_core.cached(
        self,
        "SELECT selected_turn_id,admission_cutoff FROM session_stop WHERE command_key=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const cutoff = c.sqlite3_column_int64(statement, 1);
    if (cutoff < 0) return error.CorruptStore;
    return .{
        .selected_turn_id = if (try sqlite.readNullablePositiveI64(statement, 0)) |value| @intCast(value) else null,
        .admission_cutoff = @intCast(cutoff),
    };
}

fn readInterruptedOperation(self: *Store, command_key: []const u8) !?u64 {
    const statement = try store_core.cached(
        self,
        "SELECT operation_id FROM model_operation WHERE interrupted_by_command_key=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return null;
    if (result != c.SQLITE_ROW) return error.CorruptStore;
    const operation_id = c.sqlite3_column_int64(statement, 0);
    if (operation_id <= 0 or c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptStore;
    return @intCast(operation_id);
}

fn readModelInterruptionTarget(self: *Store, command_key: []const u8) !ModelInterruptionTarget {
    const statement = try store_core.cached(
        self,
        "SELECT session_ref,turn_id,operation_id FROM model_interruption_command WHERE command_key=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    var target = ModelInterruptionTarget{
        .session = .{},
        .turn_id = 0,
        .operation_id = 0,
    };
    try sqlite.readText(statement, 0, &target.session);
    var turn_text: protocol.Bounded(20) = .{};
    try sqlite.readText(statement, 1, &turn_text);
    var operation_text: protocol.Bounded(20) = .{};
    try sqlite.readText(statement, 2, &operation_text);
    target.turn_id = std.fmt.parseInt(u64, turn_text.slice(), 10) catch return error.CorruptStore;
    target.operation_id = std.fmt.parseInt(u64, operation_text.slice(), 10) catch return error.CorruptStore;
    return target;
}

const PermissionTarget = struct {
    action_id: u64,
    decision: protocol.PermissionDecision,
};

fn readPermissionTarget(self: *Store, command_key: []const u8) !PermissionTarget {
    const statement = try store_core.cached(self, "SELECT action_id,decision FROM permission_decision_command WHERE command_key=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, command_key);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    var value: protocol.Bounded(20) = .{};
    try sqlite.readText(statement, 0, &value);
    var decision: protocol.Bounded(16) = .{};
    try sqlite.readText(statement, 1, &decision);
    return .{
        .action_id = std.fmt.parseInt(u64, value.slice(), 10) catch return error.CorruptStore,
        .decision = std.meta.stringToEnum(protocol.PermissionDecision, decision.slice()) orelse
            return error.CorruptStore,
    };
}

fn sessionStopCompletion(self: *Store, selection: SessionStopSelection) !protocol.SessionStopCompletion {
    const turn_id = selection.selected_turn_id orelse return .completed;
    return if (try turn_domain.turnIsComplete(self, turn_id)) .completed else .pending;
}

pub fn insertCommand(
    self: *Store,
    key: []const u8,
    kind: protocol.CommandKind,
    target: []const u8,
    digest: *const [32]u8,
    primary_content_id: ?i64,
    secondary_content_id: ?i64,
    answer: StoredAnswer,
) !void {
    const statement = try store_core.cached(self, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, key);
    const kind_value: i64 = switch (kind) {
        .configure => 1,
        .message => 2,
        .session_stop => 3,
        .model_interruption => 4,
        .permission_decision => 5,
    };
    try sqlite.bindI64(statement, 2, kind_value);
    try sqlite.bindText(statement, 3, target);
    try sqlite.bindBlob(statement, 4, digest);
    try sqlite.bindNullableI64(statement, 5, primary_content_id);
    try sqlite.bindNullableI64(statement, 6, secondary_content_id);
    const accepted_value: i64 = if (answer.accepted) 1 else 0;
    try sqlite.bindI64(statement, 7, accepted_value);
    try sqlite.bindText(statement, 8, answer.code.slice());
    try sqlite.bindU64(statement, 9, answer.revision);
    const created_value: i64 = if (answer.created) 1 else 0;
    try sqlite.bindI64(statement, 10, created_value);
    try sqlite.expectDone(statement);
}

fn insertMessageAdmission(
    self: *Store,
    session_ref: []const u8,
    command_key: []const u8,
    content_id: i64,
    sender: ?[]const u8,
) !u64 {
    const latest = try store_core.cached(self, "SELECT admission_id FROM message_admission ORDER BY admission_id DESC LIMIT 1");
    defer sqlite.resetCached(latest);
    const latest_result = c.sqlite3_step(latest);
    const admission_id: u64 = if (latest_result == c.SQLITE_DONE)
        1
    else if (latest_result == c.SQLITE_ROW) blk: {
        const prior = c.sqlite3_column_int64(latest, 0);
        if (prior <= 0 or prior == std.math.maxInt(i64)) {
            return error.MessageAdmissionIdentityExhausted;
        }
        break :blk @intCast(prior + 1);
    } else return error.MessageAdmissionReadFailed;
    const position = try turn_domain.claimSessionPosition(self, session_ref);
    // The sender's own sequence orders the send among its other facts.
    const sender_position: ?u64 = if (sender) |ref| try turn_domain.claimSessionPosition(self, ref) else null;
    const statement = try store_core.cached(self, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) VALUES(?1,?2,?3,?4,?5,unixepoch(),?6,?7)");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, admission_id);
    try sqlite.bindText(statement, 2, session_ref);
    try sqlite.bindText(statement, 3, command_key);
    try sqlite.bindI64(statement, 4, content_id);
    try sqlite.bindU64(statement, 5, position);
    if (sender) |ref| try sqlite.bindText(statement, 6, ref) else try sqlite.bindNullableI64(statement, 6, null);
    try sqlite.bindNullableU64(statement, 7, sender_position);
    try sqlite.expectDone(statement);
    return admission_id;
}

pub fn readMessageProjectionRow(statement: *c.sqlite3_stmt, excluding_stop: ?[]const u8) !MessageProjection {
    var projection: MessageProjection = undefined;
    try sqlite.readText(statement, 0, &projection.session);
    projection.content_id = c.sqlite3_column_int64(statement, 1);
    const admission_id = c.sqlite3_column_int64(statement, 2);
    try sqlite.readText(statement, 3, &projection.command_key);
    if (projection.content_id <= 0 or admission_id <= 0) return error.CorruptStore;
    projection.admission_id = @intCast(admission_id);
    const turn_id = try sqlite.readNullablePositiveI64(statement, 4);
    if (turn_id == null) {
        if (c.sqlite3_column_type(statement, 5) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 6) != c.SQLITE_NULL or
            c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 8) != c.SQLITE_NULL) return error.CorruptStore;
        if (excluding_stop) |key| {
            var stop_key: protocol.Bounded(128) = .{};
            try stop_key.set(key);
            projection.state = .{ .excluded = stop_key };
        } else {
            projection.state = .pending;
        }
        return projection;
    }
    if (excluding_stop != null) return error.CorruptStore;
    const operation_id = try sqlite.readNullablePositiveI64(statement, 5) orelse return error.CorruptStore;
    const attempt_ordinal = try sqlite.readNullablePositiveI64(statement, 6) orelse return error.CorruptStore;
    var outcome_code: ?protocol.Bounded(protocol.max_code_bytes) = null;
    if (c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL) {
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(statement, 7, &code);
        if (code.len == 0) return error.CorruptStore;
        outcome_code = code;
    }
    const outcome_content_id = try sqlite.readNullablePositiveI64(statement, 8);
    if (outcome_code == null and outcome_content_id != null) return error.CorruptStore;
    projection.state = .{ .applied = .{
        .binding = .{ .turn_id = @intCast(turn_id.?), .operation_id = @intCast(operation_id), .attempt_ordinal = @intCast(attempt_ordinal) },
        .outcome_code = outcome_code,
        .outcome_content_id = outcome_content_id,
    } };
    return projection;
}
