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
const rsql = @import("../rsql.zig");
const Access = @import("../access.zig").Access;
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
    try store_core.begin(self);
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
    var configured: ?configuration_domain.Applied = null;
    if (code == null) if (command.configuration) |*configuration| {
        switch (try configuration_domain.applyConfigurationLocked(self, "", configuration, faults)) {
            .rejected => |rejection| code = std.meta.stringToEnum(protocol.MessageRejection, @tagName(rejection)).?,
            .accepted => |value| {
                session = value.session;
                configured = value;
            },
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
        try store_core.commit(self);
        return .{ .rejected = .{ .replayed = false, .code = rejection, .content = supplied_content } };
    }
    const text_id = try content_domain.importContent(self, &command.text, faults);
    const metadata = try content_domain.readContentMetadata(self, text_id);
    if (configured) |*applied| {
        try configuration_domain.insertConfiguredCommand(self, applied, command.key.slice(), .message, &digest, text_id, null, .{ .accepted = true });
    } else {
        try insertCommand(self, command.key.slice(), .message, session.slice(), &digest, text_id, null, .{ .accepted = true });
    }
    const admission_id = try insertMessageAdmission(
        self,
        session.slice(),
        command.key.slice(),
        text_id,
        if (command.sender) |*sender| sender.session.slice() else null,
    );
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.commit(self);
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

/// The Session a stop names, and the last Message admitted to it: the
/// stop excludes every Message up to that one.
const stop_target = rsql.Read(.{
    .sql = "SELECT session_ref,workspace_key,next_position,(SELECT coalesce(max(admission_id),0) FROM message_admission WHERE session_ref=?1) AS admission_cutoff " ++
        "FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session: rsql.SessionHead, admission_cutoff: u64 },
    .cardinality = .optional,
});

/// The Session's open Turn: its Operation, whether that still runs, how
/// many of its Actions a stop cancels (unresolved and never attempted),
/// and whether an attempted one is unresolved, which keeps the Turn open
/// until its Attempt settles.
const stop_turn = rsql.Read(.{
    .sql = "SELECT t.turn_id,t.operation_id,o.resolution_code IS NULL AS running," ++
        "(SELECT count(*) FROM action_operation a WHERE a.parent_operation_id=t.operation_id AND a.resolution_code IS NULL AND a.attempt_ordinal=0) AS cancellable," ++
        "EXISTS(SELECT 1 FROM action_operation a WHERE a.parent_operation_id=t.operation_id AND a.resolution_code IS NULL AND a.attempt_ordinal<>0) AS in_flight " ++
        "FROM turn t JOIN model_operation o ON o.operation_id=t.operation_id WHERE t.session_ref=?1 AND t.outcome_code IS NULL LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { turn_id: rsql.Positive, operation_id: rsql.Positive, running: bool, cancellable: u64, in_flight: bool },
    .cardinality = .optional,
});

/// The Actions of `operation_id` a stop cancels, in call order, from the
/// call `after` on.
const cancellable_actions = rsql.Read(.{
    .sql = "SELECT action_id,call_ordinal FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=0 " ++
        "AND call_ordinal>=?2 ORDER BY call_ordinal",
    .Args = struct { operation_id: u64, after: u64 },
    .Row = struct { action_id: rsql.Positive, call_ordinal: u64 },
    .cardinality = .each,
});

const insert_stop = rsql.Write(.{
    .sql = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) VALUES(?1,@session(?2),?3,?4,?5,@now)",
    .Args = struct { key: []const u8, session: rsql.SessionHead, selected_turn_id: ?u64, admission_cutoff: u64, position: u64 },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The most Actions one cancelling write names: its ids, then the
/// content, first position, Session and @now, fit SQLite's 17 parameters.
const cancel_chunk = 8;

/// `cancel_actions[n - 1]` cancels the `n` Actions it names, keyed from
/// Zig (an UPDATE that numbers its rows from the table it updates is not
/// portable): the k-th id named takes position `first_position + k - 1`.
const cancel_actions = blk: {
    var writes: [cancel_chunk]type = undefined;
    for (&writes, 1..) |*write, n| write.* = rsql.Write(.{
        .sql = cancelSql(n),
        .Args = CancelArgs(n),
        .expect = .{ .exact = .{ .rows = n, .otherwise = error.StopSelectionChanged } },
    });
    break :blk writes;
};

fn cancelSql(comptime n: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var offsets: []const u8 = "";
        var ids: []const u8 = "";
        for (0..n) |k| {
            offsets = offsets ++ std.fmt.comptimePrint(" WHEN ?{d} THEN {d}", .{ k + 4, k });
            ids = ids ++ (if (k == 0) "" else ",") ++ std.fmt.comptimePrint("?{d}", .{k + 4});
        }
        return "UPDATE action_operation SET resolution_code='cancelled',resolution_content_id=?1,acceptance_position=?2+CASE action_id" ++ offsets ++
            " END,resolved_at=@now WHERE action_id IN (" ++ ids ++ ") AND session_ref=@session(?3) AND resolution_code IS NULL AND attempt_ordinal=0";
    }
}

fn cancelField(comptime k: usize) []const u8 {
    @setEvalBranchQuota(10_000);
    return std.fmt.comptimePrint("action_{d}", .{k + 1});
}

fn CancelArgs(comptime n: usize) type {
    @setEvalBranchQuota(100_000);
    var names: [3 + n][]const u8 = undefined;
    var types: [3 + n]type = undefined;
    names[0..3].* = .{ "content_id", "first_position", "session" };
    types[0..3].* = .{ u64, u64, rsql.SessionHead };
    for (0..n) |k| {
        names[3 + k] = cancelField(k);
        types[3 + k] = u64;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Collects one `cancellable_actions` chunk.
const CancelChunk = struct {
    action_ids: [cancel_chunk]u64 = undefined,
    len: usize = 0,
    /// The call the next chunk starts from.
    next: u64 = 0,

    pub fn visit(chunk: *CancelChunk, row: *const cancellable_actions.Row) bool {
        chunk.action_ids[chunk.len] = row.action_id.get();
        chunk.len += 1;
        chunk.next = row.call_ordinal + 1;
        return chunk.len < cancel_chunk;
    }
};

/// A stop's saved selection, and whether the Turn it selected has closed.
const stop_selection = rsql.Read(.{
    .sql = "SELECT stop.selected_turn_id,stop.admission_cutoff,t.outcome_code IS NOT NULL AS turn_closed FROM session_stop stop " ++
        "LEFT JOIN turn t ON t.turn_id=stop.selected_turn_id WHERE stop.command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { selected_turn_id: ?rsql.Positive, admission_cutoff: u64, turn_closed: bool },
    .cardinality = .one,
});

/// The Operation a stop interrupted, if any.
const stop_interrupted = rsql.Read(.{
    .sql = "SELECT operation_id FROM model_operation WHERE interrupted_by_command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { operation_id: rsql.Positive },
    .cardinality = .optional,
});

fn stopObservation(row: *const stop_selection.Row) SessionStopObservation {
    const turn = row.selected_turn_id orelse return .{ .selection = .{ .admission_cutoff = row.admission_cutoff }, .completion = .completed };
    return .{
        .selection = .{ .selected_turn_id = turn.get(), .admission_cutoff = row.admission_cutoff },
        .completion = if (row.turn_closed) .completed else .pending,
    };
}

/// A stop's own interruption finding the Operation changed is the stop's
/// selection changing, as on main.
pub fn stopSession(a: anytype, command: *const protocol.SessionStopCommand, faults: Faults) !SessionStopReply {
    return stopRounds(a, command, faults) catch |err| switch (err) {
        error.InterruptionTargetChanged => error.StopSelectionChanged,
        else => err,
    };
}

/// Round 1 reads the saved answer, the Session with its admission cutoff,
/// and its open Turn with its Actions' counts. A replay reads the saved
/// selection in a round of its own. When Actions are cancelled, a second
/// round reads the cancellation text's row and the first chunk of them
/// (it depends on the Turn), and each further chunk of `cancel_chunk` is
/// one more round. The write round saves the command and the stop,
/// interrupts a running Operation, cancels the Actions, closes the Turn
/// unless an attempted Action keeps it open, and commits.
fn stopRounds(a: anytype, command: *const protocol.SessionStopCommand, faults: Faults) !SessionStopReply {
    const digest = command.semanticDigest();
    const key = command.key.slice();
    const session = command.session.slice();
    var saved: saved_command.Result = undefined;
    lookupCommand(a, key, &saved);
    var target: stop_target.Result = null;
    var turn: stop_turn.Result = null;
    if (protocol.validSessionId(session)) {
        a.read(stop_target, .{ .session = session }, &target);
        a.read(stop_turn, .{ .session = session }, &turn);
    }
    try a.run();
    switch (try classify(protocol.SessionStopRejection, &saved, .session_stop, session, &digest)) {
        .fresh => {},
        .conflict => {
            try a.abandon(.{});
            return .conflict;
        },
        .accepted => {
            var selection: stop_selection.Result = undefined;
            var interrupted: stop_interrupted.Result = undefined;
            a.read(stop_selection, .{ .key = key }, &selection);
            a.read(stop_interrupted, .{ .key = key }, &interrupted);
            try a.run();
            try a.abandon(.{});
            const observed = stopObservation(&selection);
            return .{ .accepted = .{
                .replayed = true,
                .selection = observed.selection,
                .completion = observed.completion,
                .interrupted_operation_id = if (interrupted) |row| row.operation_id.get() else null,
            } };
        },
        .rejected => |code| {
            try a.abandon(.{});
            return .{ .rejected = .{ .replayed = true, .code = code } };
        },
    }

    const rejection: ?protocol.SessionStopRejection = if (!protocol.validSessionId(session)) .invalid_session_reference else if (target == null) .unknown_session else null;
    if (rejection) |code| {
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try queueCommand(a, key, .session_stop, session, &digest, null, null, &answer);
        if (faults.before_commit) return error.InjectedCommitFailure;
        try a.commit();
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    const found = target.?;
    const head = found.session;
    const positions = try a.positions(head);
    const answer: StoredAnswer = .{ .accepted = true };
    try queueCommand(a, key, .session_stop, session, &digest, null, null, &answer);
    const selection = SessionStopSelection{ .selected_turn_id = if (turn) |open| open.turn_id.get() else null, .admission_cutoff = found.admission_cutoff };
    a.write(insert_stop, .{ .key = key, .session = head, .selected_turn_id = selection.selected_turn_id, .admission_cutoff = selection.admission_cutoff, .position = try positions.take(1) });
    var completion: protocol.SessionStopCompletion = .completed;
    var interrupted_operation_id: ?u64 = null;
    // The cancellation text's identity: its queued row reads the digest in
    // place until commit.
    var cancellation = content_domain.stop_cancellation;
    if (turn) |open| {
        if (open.running) {
            a.write(interrupt_operation, .{ .operation_id = open.operation_id.get(), .command_key = key, .session = head });
            interrupted_operation_id = open.operation_id.get();
        }
        if (open.cancellable != 0) try cancelActions(a, positions, head, &open, &cancellation, faults);
        // The stop now selects the Turn and has resolved every Action
        // never attempted, so the Turn is ready (`turn.stopped_turn`)
        // unless an attempted Action is unresolved.
        if (open.in_flight) completion = .pending else try turn_domain.queueClose(a, positions, open.turn_id.get(), .cancelled);
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
    return .{ .accepted = .{
        .replayed = false,
        .selection = selection,
        .completion = completion,
        .interrupted_operation_id = interrupted_operation_id,
    } };
}

/// Cancels the open Turn's `open.cancellable` Actions in call order, each
/// at the Session's next position, with the stop's cancellation text.
fn cancelActions(
    a: anytype,
    positions: anytype,
    head: rsql.SessionHead,
    open: *const stop_turn.Row,
    cancellation: *content_domain.Import,
    faults: Faults,
) !void {
    var chunk: CancelChunk = .{};
    content_domain.lookup(a, cancellation);
    a.readEach(cancellable_actions, .{ .operation_id = open.operation_id.get(), .after = 0 }, cancel_chunk, &chunk);
    try a.run();
    if (faults.content_import) return error.InjectedContentImportFailure;
    const content_id = try content_domain.importBytes(a, cancellation, content_domain.stop_cancellation_text);
    var cancelled: u64 = 0;
    while (true) {
        if (chunk.len != 0) switch (chunk.len) {
            inline 1...cancel_chunk => |n| {
                @setEvalBranchQuota(100_000);
                var args: CancelArgs(n) = undefined;
                args.content_id = content_id;
                args.first_position = try positions.take(n);
                args.session = head;
                inline for (0..n) |k| @field(args, cancelField(k)) = chunk.action_ids[k];
                a.write(cancel_actions[n - 1], args);
            },
            else => unreachable,
        };
        cancelled += chunk.len;
        if (chunk.len < cancel_chunk) break;
        chunk.len = 0;
        a.readEach(cancellable_actions, .{ .operation_id = open.operation_id.get(), .after = chunk.next }, cancel_chunk, &chunk);
        try a.run();
    }
    // Main checked that the cancelling UPDATE changed as many rows as it
    // counted.
    if (cancelled != open.cancellable) return error.StopSelectionChanged;
}

/// A Session a command names, as a round reads it: its head, and the
/// provider a Message's model check needs.
const target_session = rsql.Read(.{
    .sql = "SELECT session_ref,workspace_key,next_position,provider FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session: rsql.SessionHead, provider: protocol.Provider },
    .cardinality = .optional,
});

/// Queues reading the Session `session` names when it is a valid
/// reference; otherwise `destination` is null at once.
fn readTarget(a: anytype, session: []const u8, destination: *target_session.Result) void {
    destination.* = null;
    if (protocol.validSessionId(session)) a.read(target_session, .{ .session = session }, destination);
}

/// Whether a command's Turn, Operation or Action id can name a row.
fn validId(id: u64) bool {
    return id != 0 and id <= std.math.maxInt(i64);
}

/// The Operation an interruption names: its Turn and Session, whether it
/// is unresolved, and whether it is still its open Turn's Operation.
const interruption_operation = rsql.Read(.{
    .sql = "SELECT o.turn_id,o.session_ref,o.resolution_code IS NULL AS unresolved,EXISTS(SELECT 1 FROM turn t WHERE t.turn_id=o.turn_id " ++
        "AND t.session_ref=o.session_ref AND t.operation_id=o.operation_id AND t.outcome_code IS NULL) AS current FROM model_operation o WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { turn_id: rsql.Positive, session_ref: protocol.Bounded(protocol.max_session_bytes), unresolved: bool, current: bool },
    .cardinality = .optional,
});

/// Whether the Session has a Message that no Turn took and no Session
/// stop excludes, which an interrupted Turn leaves open to take.
const applicable_pending = rsql.Read(.{
    .sql = "SELECT EXISTS(SELECT 1 FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>coalesce((" ++
        session_stop_cutoff_sql ++ "),0)) AS pending",
    .Args = struct { session: []const u8 },
    .Row = struct { pending: bool },
    .cardinality = .one,
});

/// What an interruption names, saved with its command. Ids are text, as
/// a rejected command's may name no row.
const interruption_target = rsql.Read(.{
    .sql = "SELECT session_ref,turn_id,operation_id FROM model_interruption_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { session_ref: protocol.Bounded(protocol.max_session_bytes), turn_id: protocol.Bounded(20), operation_id: protocol.Bounded(20) },
    .cardinality = .one,
});

const save_interruption = rsql.Write(.{
    .sql = "INSERT INTO model_interruption_command(command_key,session_ref,turn_id,operation_id) VALUES(?1,?2,?3,?4)",
    .Args = struct { key: []const u8, session: []const u8, turn_id: []const u8, operation_id: []const u8 },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Interrupts the unresolved Operation `operation_id` of `session`'s
/// Session, for the command `command_key`.
const interrupt_operation = rsql.Write(.{
    .sql = "UPDATE model_operation SET retry_due_at_ms=NULL," ++ store_schema.resolutionIs("resolution_code", .interrupted) ++ ",interrupted_by_command_key=?2," ++
        model_settlement_domain.operation_resolved_now_sql ++ " WHERE operation_id=?1 AND session_ref=@session(?3) AND resolution_code IS NULL",
    .Args = struct { operation_id: u64, command_key: []const u8, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.InterruptionTargetChanged } },
});

fn modelInterruptionTarget(row: *const interruption_target.Row) error{CorruptStore}!ModelInterruptionTarget {
    var target: ModelInterruptionTarget = .{ .session = .{}, .turn_id = 0, .operation_id = 0 };
    target.session.set(row.session_ref.slice()) catch unreachable;
    target.turn_id = std.fmt.parseInt(u64, row.turn_id.slice(), 10) catch return error.CorruptStore;
    target.operation_id = std.fmt.parseInt(u64, row.operation_id.slice(), 10) catch return error.CorruptStore;
    return target;
}

fn interruptionRejection(
    command: *const protocol.ModelInterruptionCommand,
    target: target_session.Result,
    operation: interruption_operation.Result,
) ?protocol.ModelInterruptionRejection {
    if (!protocol.validSessionId(command.session.slice())) return .invalid_session_reference;
    if (!validId(command.turn_id) or !validId(command.operation_id)) return .invalid_target;
    if (target == null) return .unknown_session;
    const found = operation orelse return .unknown_operation;
    if (found.turn_id.get() != command.turn_id or !found.session_ref.eql(command.session.slice())) return .target_mismatch;
    if (!found.unresolved) return .operation_resolved;
    if (!found.current) return .target_mismatch;
    return null;
}

/// Round 1 reads the saved answer, the Session, the Operation with its
/// Turn, and whether a pending Message keeps the Turn open. A replay reads
/// the saved target in a round of its own. The decision is
/// `interruptionRejection`; the write round saves the command and its
/// target, interrupts the Operation and closes the Turn when nothing is
/// pending, then commits.
pub fn interruptModel(a: anytype, command: *const protocol.ModelInterruptionCommand, faults: Faults) !ModelInterruptionReply {
    const digest = command.semanticDigest();
    const session = command.session.slice();
    var saved: saved_command.Result = undefined;
    lookupCommand(a, command.key.slice(), &saved);
    var target: target_session.Result = null;
    var operation: interruption_operation.Result = null;
    var pending: applicable_pending.Result = .{ .pending = false };
    if (validId(command.turn_id) and validId(command.operation_id)) {
        readTarget(a, session, &target);
        if (protocol.validSessionId(session)) {
            a.read(interruption_operation, .{ .operation_id = command.operation_id }, &operation);
            a.read(applicable_pending, .{ .session = session }, &pending);
        }
    }
    try a.run();
    const replay = try classify(protocol.ModelInterruptionRejection, &saved, .model_interruption, session, &digest);
    if (replay != .fresh) {
        if (replay != .conflict) {
            var saved_target: interruption_target.Result = undefined;
            a.read(interruption_target, .{ .key = command.key.slice() }, &saved_target);
            try a.run();
            const named = try modelInterruptionTarget(&saved_target);
            if (!named.session.eql(session) or named.turn_id != command.turn_id or named.operation_id != command.operation_id) return error.CorruptStore;
        }
        try a.abandon(.{});
        return switch (replay) {
            .fresh => unreachable,
            .conflict => .conflict,
            .accepted => .{ .accepted = .{ .replayed = true } },
            .rejected => |code| .{ .rejected = .{ .replayed = true, .code = code } },
        };
    }

    const rejection = interruptionRejection(command, target, operation);
    var answer = StoredAnswer{ .accepted = rejection == null };
    if (rejection) |code| try answer.code.set(@tagName(code));
    try queueCommand(a, command.key.slice(), .model_interruption, session, &digest, null, null, &answer);
    var turn_buffer: [20]u8 = undefined;
    var operation_buffer: [20]u8 = undefined;
    a.write(save_interruption, .{
        .key = command.key.slice(),
        .session = session,
        .turn_id = try std.fmt.bufPrint(&turn_buffer, "{d}", .{command.turn_id}),
        .operation_id = try std.fmt.bufPrint(&operation_buffer, "{d}", .{command.operation_id}),
    });
    if (rejection == null) {
        const head = target.?.session;
        a.write(interrupt_operation, .{ .operation_id = command.operation_id, .command_key = command.key.slice(), .session = head });
        if (!pending.pending) try turn_domain.queueClose(a, try a.positions(head), command.turn_id, .cancelled);
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    const code = rejection orelse {
        if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
        return .{ .accepted = .{ .replayed = false } };
    };
    return .{ .rejected = .{ .replayed = false, .code = code } };
}

/// The Action a permission decision names, with its Turn.
const decision_action = rsql.Read(.{
    .sql = "SELECT a.session_ref,a.authorized,a.resolution_code IS NULL AS unresolved,t.outcome_code IS NULL AS turn_open,t.turn_id FROM action_operation a " ++
        "JOIN model_operation operation ON operation.operation_id=a.parent_operation_id JOIN turn t ON t.turn_id=operation.turn_id WHERE a.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = struct { session_ref: protocol.Bounded(protocol.max_session_bytes), authorized: bool, unresolved: bool, turn_open: bool, turn_id: rsql.Positive },
    .cardinality = .optional,
});

const save_decision = rsql.Write(.{
    .sql = "INSERT INTO permission_decision_command(command_key,action_id,decision) VALUES(?1,?2,?3)",
    .Args = struct { key: []const u8, action_id: []const u8, decision: protocol.PermissionDecision },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const allow_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET authorized=1,decided_at=@now WHERE action_id=?1 AND session_ref=@session(?2) AND authorized=0 AND resolution_code IS NULL",
    .Args = struct { action_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

const deny_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code='denied',resolution_content_id=?2,acceptance_position=?3,resolved_at=@now " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND resolution_code IS NULL",
    .Args = struct { action_id: u64, content_id: u64, position: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

/// A denied Action's result.
const denial_text = "Permission denied.";

/// `denial_text`'s identity, hashed when the Host is built.
const denial: content_domain.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(denial_text, false);
};

fn decisionRejection(
    command: *const protocol.PermissionDecisionCommand,
    target: target_session.Result,
    action: decision_action.Result,
) ?protocol.PermissionDecisionRejection {
    if (!protocol.validSessionId(command.session.slice())) return .invalid_session_reference;
    if (!validId(command.action_id)) return .invalid_target;
    if (target == null) return .unknown_session;
    const found = action orelse return .unknown_action;
    if (!found.session_ref.eql(command.session.slice())) return .target_mismatch;
    if (found.authorized or !found.unresolved or !found.turn_open) return .action_not_pending;
    return null;
}

/// Round 1 reads the saved answer, the Session, the Action with its Turn
/// and, for a denial, its result text's row. The decision is
/// `decisionRejection`; the write round saves the command and its target,
/// then authorizes or denies the Action, and commits.
pub fn decidePermission(a: anytype, command: *const protocol.PermissionDecisionCommand, faults: Faults) !PermissionDecisionReply {
    const digest = command.semanticDigest();
    const session = command.session.slice();
    var saved: saved_command.Result = undefined;
    lookupCommand(a, command.key.slice(), &saved);
    var target: target_session.Result = null;
    var action: decision_action.Result = null;
    var content = denial;
    if (validId(command.action_id)) {
        readTarget(a, session, &target);
        if (protocol.validSessionId(session)) a.read(decision_action, .{ .action_id = command.action_id }, &action);
    }
    if (command.decision == .deny) content_domain.lookup(a, &content);
    try a.run();
    switch (try classify(protocol.PermissionDecisionRejection, &saved, .permission_decision, session, &digest)) {
        .fresh => {},
        .conflict => {
            try a.abandon(.{});
            return .conflict;
        },
        .accepted => {
            try a.abandon(.{});
            return .{ .accepted = .{ .replayed = true } };
        },
        .rejected => |code| {
            try a.abandon(.{});
            return .{ .rejected = .{ .replayed = true, .code = code } };
        },
    }

    const rejection = decisionRejection(command, target, action);
    var answer = StoredAnswer{ .accepted = rejection == null };
    if (rejection) |code| try answer.code.set(@tagName(code));
    try queueCommand(a, command.key.slice(), .permission_decision, session, &digest, null, null, &answer);
    var action_buffer: [20]u8 = undefined;
    a.write(save_decision, .{ .key = command.key.slice(), .action_id = try std.fmt.bufPrint(&action_buffer, "{d}", .{command.action_id}), .decision = command.decision });
    if (rejection == null) {
        const head = target.?.session;
        switch (command.decision) {
            .allow_once => a.write(allow_action, .{ .action_id = command.action_id, .session = head }),
            .deny => {
                if (faults.content_import) return error.InjectedContentImportFailure;
                const positions = try a.positions(head);
                const content_id = try content_domain.importBytes(a, &content, denial_text);
                a.write(deny_action, .{ .action_id = command.action_id, .content_id = content_id, .position = try positions.take(1), .session = head });
                turn_domain.queueContinuation(a, action.?.turn_id.get(), head);
            },
        }
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
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
            "AND m.admission_id<=stopped.admission_cutoff ORDER BY stop_command.command_seq LIMIT 1) END " ++
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

/// A command's saved answer, by its key.
pub const saved_command = rsql.Read(.{
    .sql = "SELECT kind,target,input_digest,accepted,code,revision,created,primary_content_id FROM core_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct {
        kind: u8,
        target: protocol.Bounded(protocol.max_session_bytes),
        input_digest: [32]u8,
        accepted: bool,
        code: protocol.Bounded(protocol.max_code_bytes),
        revision: u64,
        created: bool,
        primary_content_id: ?rsql.Positive,
    },
    .cardinality = .optional,
});

/// Queues reading the saved answer of the command `key`; `classify`
/// follows its round.
pub fn lookupCommand(a: anytype, key: []const u8, destination: *saved_command.Result) void {
    a.read(saved_command, .{ .key = key }, destination);
}

/// Each command kind's stored code.
fn kindCode(kind: protocol.CommandKind) u8 {
    return switch (kind) {
        .configure => 1,
        .message => 2,
        .session_stop => 3,
        .model_interruption => 4,
        .permission_decision => 5,
    };
}

/// The answer a `lookupCommand` round found, or null.
fn savedAnswer(saved: *const saved_command.Result) error{CorruptStore}!?ExistingCommand {
    const row = if (saved.*) |*row| row else return null;
    // Copied by length, as an answer's value is compared whole.
    var target: protocol.Bounded(protocol.max_session_bytes) = .{};
    target.set(row.target.slice()) catch unreachable;
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    code.set(row.code.slice()) catch unreachable;
    return .{
        .kind = for (std.enums.values(protocol.CommandKind)) |candidate| {
            if (kindCode(candidate) == row.kind) break candidate;
        } else return error.CorruptStore,
        .target = target,
        .digest = row.input_digest,
        .accepted = row.accepted,
        .code = code,
        .revision = row.revision,
        .created = row.created,
        .primary_content_id = if (row.primary_content_id) |id| @intCast(id.get()) else null,
    };
}

/// Classifies a keyed command against the saved answer `lookupCommand`
/// read. Any saved answer is a replay, and its caller ends the
/// transaction without writing.
pub fn classify(
    comptime Rejection: type,
    saved: *const saved_command.Result,
    kind: protocol.CommandKind,
    target: []const u8,
    digest: *const [32]u8,
) error{CorruptStore}!Replay(Rejection) {
    const existing = try savedAnswer(saved) orelse return .fresh;
    if (existing.kind != kind or (!((kind == .configure or kind == .message) and target.len == 0) and !existing.target.eql(target)) or
        !std.mem.eql(u8, &existing.digest, digest)) return .conflict;
    if (existing.accepted) return .{ .accepted = existing };
    return .{ .rejected = std.meta.stringToEnum(Rejection, existing.code.slice()) orelse return error.CorruptStore };
}

/// `lookupCommand` and `classify` for unconverted code, inside the
/// transaction it opened, which any saved answer rolls back.
pub fn classifyReplay(
    self: *Store,
    comptime Rejection: type,
    kind: protocol.CommandKind,
    key: []const u8,
    target: []const u8,
    digest: *const [32]u8,
) !Replay(Rejection) {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var saved: saved_command.Result = undefined;
    lookupCommand(&a, key, &saved);
    try a.run();
    if (saved != null) try store_core.rollback(self);
    return classify(Rejection, &saved, kind, target, digest);
}

/// `lookupCommand` for unconverted code.
fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
    var a = Access(.read, error{}).within(self);
    defer a.deinit();
    var saved: saved_command.Result = undefined;
    lookupCommand(&a, key, &saved);
    try a.run();
    return savedAnswer(&saved);
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

const insert_command = rsql.Write(.{
    .sql = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
        "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
    .Args = struct {
        key: []const u8,
        kind: u8,
        target: []const u8,
        digest: *const [32]u8,
        primary_content_id: ?u64,
        secondary_content_id: ?u64,
        accepted: bool,
        code: []const u8,
        revision: u64,
        created: bool,
        command_seq: u64,
    },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues saving the command `key` with its `answer`, which, like `key`,
/// `target` and `digest`, must outlive the round.
pub fn queueCommand(
    a: anytype,
    key: []const u8,
    kind: protocol.CommandKind,
    target: []const u8,
    digest: *const [32]u8,
    primary_content_id: ?u64,
    secondary_content_id: ?u64,
    answer: *const StoredAnswer,
) !void {
    a.write(insert_command, .{
        .key = key,
        .kind = kindCode(kind),
        .target = target,
        .digest = digest,
        .primary_content_id = primary_content_id,
        .secondary_content_id = secondary_content_id,
        .accepted = answer.accepted,
        .code = answer.code.slice(),
        .revision = answer.revision,
        .created = answer.created,
        .command_seq = try a.identity(.command_seq),
    });
}

/// `queueCommand` for unconverted code, inside its transaction.
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
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    try queueCommand(&a, key, kind, target, digest, if (primary_content_id) |id| @intCast(id) else null, if (secondary_content_id) |id| @intCast(id) else null, &answer);
    try a.apply();
}

fn insertMessageAdmission(
    self: *Store,
    session_ref: []const u8,
    command_key: []const u8,
    content_id: i64,
    sender: ?[]const u8,
) !u64 {
    const admission_id = try store_core.takeIdentity(self, .admission_id);
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
