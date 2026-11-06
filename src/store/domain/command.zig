//! Commands a person or peer sends a Session (messages, Session stops, model
//! interruptions, permission decisions), their replay, and their observed results.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("action.zig");
const forward_domain = @import("forward.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const sqlite = @import("../sqlite.zig");
const tool_set = @import("tool_set.zig");
const turn_domain = @import("turn.zig");
const AcceptedMessageQueue = reads_domain.AcceptedMessageQueue;
const AttemptBinding = store_core.AttemptBinding;
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;
const MessageCommitted = Store.MessageCommitted;
const MessageObservation = reads_domain.MessageObservation;
const session_work = @import("../../session_work.zig");
const TurnOutcome = turn_domain.TurnOutcome;

pub const session_stop_cutoff_sql =
    "SELECT admission_cutoff FROM session_stop WHERE session_ref=?1 ORDER BY admission_cutoff DESC LIMIT 1";
pub const pending_message_count_sql =
    "SELECT count(*) AS pending FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2";

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
    target: protocol.Bounded(protocol.max_session_bytes) = .{},
    code: protocol.Bounded(protocol.max_code_bytes) = .{},
    kind: union(protocol.CommandKind) {
        configure: struct { revision: u64 = 0, created: bool = false },
        message: ?MessageObservation,
        session_stop: ?SessionStopObservation,
        model_interruption: ModelInterruptionTarget,
        permission_decision: struct { action_id: u64, decision: protocol.PermissionDecision },
    } = .{ .configure = .{} },

    /// The Host's one ordered Message-state rule. Clients consume this value.
    pub fn requestState(self: *const CommandObservation) ?protocol.MessageRequestState {
        if (self.kind != .message or self.status == .absent) return null;
        if (self.status == .rejected) return .rejected;
        const message = if (self.kind.message) |*value| value else return null;
        const queue = if (message.queue) |*value| value else return null;
        switch (queue.state) {
            .completed => return .completed,
            .failed => return .failed,
            .cancelled, .excluded => return .cancelled,
            else => {},
        }
        if (message.work) |*work| {
            if (work.state.progress() == .waiting_for_permission) return .waiting_for_permission;
        }
        return if (queue.state == .processing) .processing else .queued;
    }
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

/// The Session of the attempted, unresolved Action that holds
/// `sender_handle`, while no stop selected its Turn. The partial unique
/// index action_operation_sender_handle holds one row per handle, so
/// LIMIT 1 drops nothing.
const message_sender = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref WHERE action.sender_handle=?1 AND action.attempt_ordinal=1 AND action.resolution_code IS NULL " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) LIMIT 1",
    .Args = struct { handle: []const u8 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

/// A saved Message's admission and the identity of its text.
const message_replay = rsql.Read(.{
    .sql = "SELECT m.admission_id,m.session_ref,m.content_id,content.byte_length AS length,content.digest FROM message_admission m " ++
        "JOIN content ON content.content_id=m.content_id WHERE m.command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { admission_id: rsql.Positive, session_ref: protocol.Bounded(protocol.max_session_bytes), content_id: rsql.Positive, length: u64, digest: [32]u8 },
    .cardinality = .one,
});

/// A person's Message.
const admit_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) VALUES(?1,@session(?2),?3,?4,?5,@now)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
pub const admit_message_sql = admit_message.sql;

/// A peer's Message: the sender's own position orders the send among its
/// other facts.
const admit_sent_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, sender: rsql.SessionHead, sender_position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// A peer's rejected Message, at its sender's next position.
const reject_sent = rsql.Write(.{
    .sql = "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,@session(?2),?3,@now)",
    .Args = struct { key: []const u8, sender: rsql.SessionHead, position: u64 },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// What every Message reads in round 1, besides its Session or its
/// creation, and keeps until commit.
const MessageReads = struct {
    digest: [32]u8,
    saved: saved_command.Result = undefined,
    sender: message_sender.Result = null,
    /// The text's identity, and the row its lookup found.
    text: content_domain.Import,
};

/// The handle a peer Message's sender claims, when its address names this
/// Store: only then can an Action of this Store hold it.
fn claimedHandle(command: *const protocol.MessageCommand, selector: []const u8) ?[]const u8 {
    const handle = if (command.sender_handle) |*value| value else return null;
    const claimed = if (command.sender) |*value| value else return null;
    if (!claimed.store.eql(selector)) return null;
    return handle.slice();
}

/// Whether the Message's sender is what its handle proves: no sender and
/// no handle, or the Session of the Action `found` holds the handle.
fn senderValid(command: *const protocol.MessageCommand, selector: []const u8, found: message_sender.Result) bool {
    if (command.sender_handle == null) return command.sender == null;
    if (claimedHandle(command, selector) == null) return false;
    const row = found orelse return false;
    return command.sender.?.session.eql(&row.session.ref);
}

fn readMessage(a: anytype, selector: []const u8, command: *const protocol.MessageCommand, reads: *MessageReads) void {
    lookupCommand(a, command.key.slice(), &reads.saved);
    if (claimedHandle(command, selector)) |handle| a.read(message_sender, .{ .handle = handle }, &reads.sender);
}

/// A Message's answer when round 1 found it saved, or null for a fresh
/// one. An accepted replay reads its admission and text in a round of its
/// own.
fn replayMessage(a: anytype, command: *const protocol.MessageCommand, reads: *const MessageReads) !?MessageReply {
    switch (try classify(protocol.MessageRejection, &reads.saved, .message, command.session.slice(), &reads.digest)) {
        .fresh => return null,
        .conflict => {
            try a.abandon(.{});
            return .conflict;
        },
        .rejected => |code| {
            try a.abandon(.{});
            return .{ .rejected = .{ .replayed = true, .code = code, .content = .{ .length = command.text.length, .digest = command.text.digest } } };
        },
        .accepted => |existing| {
            const content_id = existing.primary_content_id orelse return error.CorruptStore;
            var row: message_replay.Result = undefined;
            a.read(message_replay, .{ .key = command.key.slice() }, &row);
            try a.run();
            if (row.content_id.get() != content_id or !existing.target.eql(row.session_ref.slice())) return error.CorruptStore;
            try a.abandon(.{});
            return .{ .accepted = .{
                .replayed = true,
                .admission_id = row.admission_id.get(),
                .content = .{ .length = row.length, .digest = row.digest },
                .session = existing.target,
            } };
        },
    }
}

/// Saves a rejected Message; a peer's rejection takes its sender's next
/// position. Then commits.
fn rejectMessage(
    a: anytype,
    command: *const protocol.MessageCommand,
    reads: *const MessageReads,
    sender_known: bool,
    code: protocol.MessageRejection,
    faults: Faults,
) !MessageReply {
    var answer = StoredAnswer{ .accepted = false };
    try answer.code.set(@tagName(code));
    try queueCommand(a, command.key.slice(), .message, command.session.slice(), &reads.digest, null, null, &answer);
    if (sender_known) {
        const sender = reads.sender.?.session;
        a.write(reject_sent, .{ .key = command.key.slice(), .sender = sender, .position = try (try a.positions(sender)).take(1) });
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return .{ .rejected = .{ .replayed = false, .code = code, .content = .{ .length = command.text.length, .digest = command.text.digest } } };
}

/// After the text's lookup round: imports the text and saves the command
/// (with the Session revision `configured` wrote, when it created the
/// Session) and the admission at `head`'s next position, then commits.
fn admitMessage(
    a: anytype,
    io: std.Io,
    command: *const protocol.MessageCommand,
    reads: *MessageReads,
    head: rsql.SessionHead,
    session: protocol.Bounded(protocol.max_session_bytes),
    configured: ?*const configuration_domain.Applied,
    committed: ?MessageCommitted,
    faults: Faults,
) !MessageReply {
    const text_id = try content_domain.importSealed(a, io, &command.text, &reads.text, faults);
    const answer: StoredAnswer = .{ .accepted = true };
    if (configured) |applied| {
        try configuration_domain.queueConfiguredCommand(a, applied, command.key.slice(), .message, &reads.digest, text_id, null, &answer);
    } else {
        try queueCommand(a, command.key.slice(), .message, session.slice(), &reads.digest, text_id, null, &answer);
    }
    const admission_id = try a.identity(.admission_id);
    const position = try (try a.positions(head)).take(1);
    if (command.sender != null) {
        const sender = reads.sender.?.session;
        a.write(admit_sent_message, .{
            .admission_id = admission_id,
            .session = head,
            .key = command.key.slice(),
            .content_id = text_id,
            .position = position,
            .sender = sender,
            .sender_position = try (try a.positions(sender)).take(1),
        });
    } else {
        a.write(admit_message, .{ .admission_id = admission_id, .session = head, .key = command.key.slice(), .content_id = text_id, .position = position });
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    if (committed) |callback| callback.call(callback.context, .{
        .session = session.slice(),
        .admission_id = admission_id,
        .from_peer = command.sender != null,
    });
    return .{
        .accepted = .{
            .replayed = false,
            .admission_id = admission_id,
            // The text's row was found or written under exactly this identity.
            .content = .{ .length = command.text.length, .digest = command.text.digest },
            .session = session,
        },
    };
}

/// A Message to an existing Session, or one that creates its Session.
/// Only an authenticated Action can acquire a sender position; an exact
/// replay needs no still-live handle.
pub fn submitMessage(
    a: anytype,
    io: std.Io,
    served: anytype,
    selector: []const u8,
    command: *const protocol.MessageCommand,
    committed: ?MessageCommitted,
    faults: Faults,
) !MessageReply {
    if (command.configuration != null) return submitCreating(a, io, served, selector, command, committed, faults);
    var reads: MessageReads = .{ .digest = command.semanticDigest(), .text = content_domain.sealedIdentity(&command.text) };
    return submitTo(a, io, served, selector, command, committed, faults, &reads);
}

/// Round 1 reads the saved answer, the sender's Action, the Session and
/// the text's content row. The decision is plain; the write round imports
/// the text and saves the command and the admission, then commits.
/// noinline: its reads stay out of the frame a creation's chain runs under.
noinline fn submitTo(
    a: anytype,
    io: std.Io,
    served: anytype,
    selector: []const u8,
    command: *const protocol.MessageCommand,
    committed: ?MessageCommitted,
    faults: Faults,
    reads: *MessageReads,
) !MessageReply {
    const session = command.session.slice();
    readMessage(a, selector, command, reads);
    var target: target_session.Result = null;
    readTarget(a, session, &target);
    content_domain.lookup(a, &reads.text);
    try a.run();
    if (try replayMessage(a, command, reads)) |reply| return reply;
    const sender_valid = senderValid(command, selector, reads.sender);
    const rejection: ?protocol.MessageRejection = if (!protocol.validSessionId(session))
        .invalid_session_reference
    else if (!sender_valid)
        .invalid_sender_handle
    else if (target == null)
        .unknown_session
    else if (command.require_model and !configuration_domain.servesProviderOf(served, null, target.?.provider))
        .model_capability_unavailable
    else
        null;
    if (rejection) |code| return rejectMessage(a, command, reads, command.sender != null and sender_valid, code, faults);
    return admitMessage(a, io, command, reads, target.?.session, command.session, null, committed, faults);
}

/// Round 1 reads the saved answer, the sender's Action and the content
/// rows the configuration needs. `configuration.applyConfiguration` adds
/// its own rounds (a created Session's reference, an output schema). The
/// text's lookup is a round of its own, as the lookup statement is in
/// round 1; that round also runs the creation's writes. Its configuration
/// reads, over 4.6 KB, are the Store's (`Store.configurationReads`), and
/// it is kept out of `submitMessage`'s frame, so the plain path holds none
/// of what a creation applies.
noinline fn submitCreating(
    a: anytype,
    io: std.Io,
    served: anytype,
    selector: []const u8,
    command: *const protocol.MessageCommand,
    committed: ?MessageCommitted,
    faults: Faults,
) !MessageReply {
    const configuration = &command.configuration.?;
    var reads: MessageReads = .{ .digest = command.semanticDigest(), .text = content_domain.sealedIdentity(&command.text) };
    // Over 4.6 KB, so held where the Store owns it, as a configure does.
    const creation = a.store.configurationReads();
    creation.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
    readMessage(a, selector, command, &reads);
    configuration_domain.prepareConfiguration(a, "", configuration, creation);
    try a.run();
    if (try replayMessage(a, command, &reads)) |reply| return reply;
    const sender_valid = senderValid(command, selector, reads.sender);
    var rejection: ?protocol.MessageRejection = if (command.session.len != 0)
        .invalid_session_reference
    else if (!sender_valid)
        .invalid_sender_handle
    else if (command.require_model and !configuration_domain.servesProviderOf(served, configuration, null))
        .model_capability_unavailable
    else
        null;
    if (rejection == null) switch (try configuration_domain.applyConfiguration(a, io, "", configuration, faults, creation)) {
        .rejected => |code| rejection = std.meta.stringToEnum(protocol.MessageRejection, @tagName(code)).?,
        .accepted => |applied| {
            content_domain.lookup(a, &reads.text);
            try a.run();
            return admitMessage(a, io, command, &reads, applied.head, applied.session, &applied, committed, faults);
        },
    };
    return rejectMessage(a, command, &reads, command.sender != null and sender_valid, rejection.?, faults);
}

/// What running a `message_agent` call did.
pub const AgentDelivery = enum {
    /// The Message was admitted to its Session and the call succeeded.
    delivered,
    /// Nothing was sent, and the call failed with a result saying why.
    failed,
    /// A stop selected the call's Turn, or its Session owes one, and the
    /// stop resolves the call.
    stopped,
};

/// The command key a `message_agent` call's Message is saved under. Keys a
/// person or script sends are theirs; a taken key fails the call.
fn agentMessageKey(buffer: *[protocol.max_key_bytes]u8, action_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/message_agent/{d}", .{action_id}) catch unreachable;
}

/// Runs a `message_agent` call as one core command (D24, D41): admits
/// `text` to the Session `target` names, from the call's own Session, and
/// resolves the call with what happened, in one transaction. A Message it
/// sends carries no client environment (D169).
pub fn deliverAgentMessage(
    a: anytype,
    binding: action_domain.ActionAttemptBinding,
    target: []const u8,
    text: []const u8,
    faults: Faults,
) !AgentDelivery {
    var key_buffer: [protocol.max_key_bytes]u8 = undefined;
    const key = agentMessageKey(&key_buffer, binding.action_id);
    var facts: action_domain.core_facts.Result = undefined;
    const names: action_domain.CoreNames = .of();
    a.read(action_domain.core_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools }, &facts);
    var saved: saved_command.Result = undefined;
    lookupCommand(a, key, &saved);
    var receiver: target_session.Result = null;
    readTarget(a, target, &receiver);
    var message: content_domain.Import = .ofBytes(text, false);
    content_domain.lookup(a, &message);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.stopped) {
        try a.abandon(.{});
        return .stopped;
    }
    var result_buffer: [160]u8 = undefined;
    const delivered = receiver != null and saved == null;
    const result = if (receiver == null)
        std.fmt.bufPrint(&result_buffer, "No Session {s} in this Store; nothing was sent.", .{target}) catch unreachable
    else if (saved != null)
        "Rui could not send this Message: its command key is already taken. Nothing was sent."
    else
        std.fmt.bufPrint(&result_buffer, "Delivered to {s}.", .{target}) catch unreachable;
    var outcome: content_domain.Import = .ofBytes(result, false);
    content_domain.lookup(a, &outcome);
    try a.run();

    if (faults.content_import) return error.InjectedContentImportFailure;
    if (delivered) {
        const head = receiver.?.session;
        const text_id = try content_domain.importBytes(a, &message, text);
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update("rui/core/message_agent/v1");
        digest.update(&protocol.contentDigest(text));
        try queueCommand(a, key, .message, target, &digest.finalResult(), text_id, null, &.{ .accepted = true });
        a.write(admit_sent_message, .{
            .admission_id = try a.identity(.admission_id),
            .session = head,
            .key = key,
            .content_id = text_id,
            .position = try (try a.positions(head)).take(1),
            .sender = found.session,
            .sender_position = try (try a.positions(found.session)).take(1),
        });
    }
    const outcome_id = try content_domain.importBytes(a, &outcome, result);
    try action_domain.queueCoreResolution(a, binding, found.session, if (delivered) .succeeded else .failed, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return if (delivered) .delivered else .failed;
}

fn childEndingKey(buffer: *[protocol.max_key_bytes]u8, turn_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/ending/{d}", .{turn_id}) catch unreachable;
}

/// The owed ending of `turn_id`: its child's Session, its parent, and how
/// its Turn ended, with the answer's digest when it is done.
const owed_ending_facts = rsql.Read(.{
    .sql = "SELECT child.session_ref,child.workspace_key,child.next_position,child.parent_ref AS parent,t.outcome_code,t.outcome_content_id,c.digest," ++
        action_domain.ending_stop_sql ++ " FROM session_ending_owed e JOIN turn t ON t.turn_id=e.turn_id " ++
        "JOIN session child ON child.session_ref=t.session_ref LEFT JOIN content c ON c.content_id=t.outcome_content_id WHERE e.turn_id=?1 AND e.delivered=0",
    .Args = struct { turn_id: u64 },
    .Row = struct {
        child: rsql.SessionHead,
        parent: protocol.Bounded(protocol.session_id_bytes),
        outcome_code: protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        digest: ?[32]u8,
        stopped: bool,
        quiet: bool,
    },
    .cardinality = .optional,
});

const settle_owed_ending = rsql.Write(.{
    .sql = "UPDATE session_ending_owed SET delivered=1 WHERE turn_id=?1 AND delivered=0",
    .Args = struct { turn_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// What the parent of a child that ended without an answer reads, as a
/// Message from the child (D161).
fn endingText(buffer: []u8, ending: protocol.TurnEnding) []const u8 {
    return std.fmt.bufPrint(buffer, "[Rui: this agent's Turn ended without an answer: {s}.]", .{@tagName(ending)}) catch unreachable;
}

/// Delivers the ending of an attached child's Turn `turn_id` to its parent
/// as a Message from the child (D39), which wakes the parent, and settles
/// what was owed, in one transaction. A done Turn's Message is its saved
/// answer itself, so nothing is copied; any other ending is a short line
/// naming it. An ending its parent's own stop caused only settles (D139).
/// False when nothing was owed any more. Its `rui.core/` key is free:
/// clients cannot use one, and settling marks the row with the admission.
pub fn deliverChildEnding(a: anytype, turn_id: u64, faults: Faults) !bool {
    var key_buffer: [protocol.max_key_bytes]u8 = undefined;
    const key = childEndingKey(&key_buffer, turn_id);
    var owed: owed_ending_facts.Result = undefined;
    a.read(owed_ending_facts, .{ .turn_id = turn_id }, &owed);
    try a.run();
    const found = owed orelse {
        try a.abandon(.{});
        return false;
    };
    a.write(settle_owed_ending, .{ .turn_id = turn_id });
    // The ending's feed row climbs the tree from here (D180): queued with
    // the owed Message, so a root Session's Turn end writes nothing more.
    try forward_domain.queue(a, &found.child.ref, &found.child.ref, .ending, turn_id);
    if (found.quiet) {
        if (faults.before_commit) return error.InjectedCommitFailure;
        try a.commit();
        return true;
    }
    const outcome = try TurnOutcome.decode(found.outcome_code.slice(), if (found.outcome_content_id) |id| @intCast(id.get()) else null);
    var text_buffer: [96]u8 = undefined;
    const text = endingText(&text_buffer, outcome.ending(found.stopped));
    var receiver: target_session.Result = null;
    readTarget(a, found.parent.slice(), &receiver);
    var message: content_domain.Import = .ofBytes(text, false);
    if (outcome != .completed) content_domain.lookup(a, &message);
    try a.run();
    if (faults.content_import) return error.InjectedContentImportFailure;
    const head = (receiver orelse return error.CorruptStore).session;
    const content_id: u64, const content_digest: [32]u8 = switch (outcome) {
        .completed => |answer| .{ @intCast(answer), found.digest orelse return error.CorruptStore },
        else => .{ try content_domain.importBytes(a, &message, text), protocol.contentDigest(text) },
    };
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update("rui/core/child_ending/v1");
    digest.update(&content_digest);
    try queueCommand(a, key, .message, found.parent.slice(), &digest.finalResult(), content_id, null, &.{ .accepted = true });
    a.write(admit_sent_message, .{
        .admission_id = try a.identity(.admission_id),
        .session = head,
        .key = key,
        .content_id = content_id,
        .position = try (try a.positions(head)).take(1),
        .sender = found.child,
        .sender_position = try (try a.positions(found.child)).take(1),
    });
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}

/// What running a `start_agent` call did.
pub const AgentStart = enum {
    /// The agent's Session was created with the task as its first Message,
    /// and the call succeeded.
    started,
    /// Nothing was started, and the call failed with a result saying why.
    failed,
    /// A stop selected the call's Turn, or its Session owes one, and the
    /// stop resolves the call.
    stopped,
};

/// The calling Session's settings a `start_agent` call inherits or may
/// only narrow. Its Workspace fills the creating Configuration in place.
const parent_settings = rsql.Read(.{
    .sql = "SELECT workspace,provider," ++ tool_set.maskSql("session.tool_set_id") ++ " AS tools_mask,permission_mode FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { workspace: *protocol.Bounded(protocol.max_workspace_bytes), provider: protocol.Provider, tools_mask: c_int, permission_mode: u8 },
    .cardinality = .optional,
});

/// Runs a `start_agent` call as one core command (D24, D122): creates a
/// Session with `configuration` in the caller's Workspace and with its
/// provider (D122, D221), as its child when `attached`, admits `task` to it
/// from the caller, and resolves the call with what happened, in one
/// transaction. The spec may only narrow the caller's tools and permission
/// mode. `configuration` is the caller's; its Workspace and provider are
/// filled here. `committed` runs once the task's admission commits.
pub fn startAgent(
    a: anytype,
    io: std.Io,
    binding: action_domain.ActionAttemptBinding,
    caller: []const u8,
    task: []const u8,
    attached: bool,
    configuration: *protocol.Configuration,
    committed: ?MessageCommitted,
    faults: Faults,
) !AgentStart {
    var key_buffer: [protocol.max_key_bytes]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "rui.core/start_agent/{d}", .{binding.action_id}) catch unreachable;
    var facts: action_domain.core_facts.Result = undefined;
    const names: action_domain.CoreNames = .of();
    a.read(action_domain.core_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools }, &facts);
    var saved: saved_command.Result = undefined;
    lookupCommand(a, key, &saved);
    configuration.workspace = .{ .state = .value, .value = .{ .len = 0 } };
    var parent: parent_settings.Row = .{ .workspace = &configuration.workspace.value, .provider = undefined, .tools_mask = undefined, .permission_mode = undefined };
    var parent_found: store_access.Found = .missing;
    a.readInto(parent_settings, .{ .session = caller }, &parent, &parent_found);
    // Over 4.6 KB, so held where the Store owns it, as a configure does.
    const creation = a.store.configurationReads();
    creation.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
    configuration_domain.prepareConfiguration(a, "", configuration, creation);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (!parent_found.get() or !std.mem.eql(u8, &found.session.ref, caller)) return error.CorruptStore;
    if (found.stopped) {
        try a.abandon(.{});
        return .stopped;
    }
    var result_buffer: [192]u8 = undefined;
    const refusal: ?[]const u8 = refusal: {
        if (saved != null) break :refusal "Rui could not start the agent: its command key is already taken. Nothing was started.";
        const allowed = try configuration_domain.toolSet(parent.tools_mask);
        const requested = configuration_domain.requestedTools(configuration) orelse
            break :refusal "spec.tools: only Rui's own tools can be narrowed to. Nothing was started.";
        var wider = requested.differenceWith(allowed).iterator();
        if (wider.next()) |tool| break :refusal std.fmt.bufPrint(&result_buffer, "spec.tools: {s} is not one of your tools. Nothing was started.", .{@tagName(tool)}) catch unreachable;
        if (try configuration_domain.permissionMode(parent.permission_mode) == .ask and !configuration.permission_mode.value.eql("ask"))
            break :refusal "spec.permissionMode: you ask before running commands, so your agents ask too. Nothing was started.";
        break :refusal null;
    };
    configuration.provider = .{ .state = .value, .value = .{ .len = 0 } };
    configuration.provider.value.set(@tagName(parent.provider)) catch unreachable;
    if (attached) creation.parent = found.session.ref;
    const application: ?configuration_domain.Application = if (refusal == null)
        try configuration_domain.applyConfiguration(a, io, "", configuration, faults, creation)
    else
        null;
    const applied: ?*const configuration_domain.Applied = if (application) |*decided| switch (decided.*) {
        .accepted => |*value| value,
        .rejected => null,
    } else null;
    const result = if (refusal) |text|
        text
    else if (applied) |value|
        std.fmt.bufPrint(&result_buffer, "Started {s}.", .{value.session.slice()}) catch unreachable
    else
        std.fmt.bufPrint(&result_buffer, "Rui could not start the agent ({s}). Nothing was started.", .{@tagName(application.?.rejected)}) catch unreachable;

    var message: content_domain.Import = .ofBytes(task, false);
    var outcome: content_domain.Import = .ofBytes(result, false);
    var rows: content_domain.Pair = .{ .first = null, .second = null };
    if (applied != null) content_domain.lookupPair(a, &message, &outcome, &rows) else content_domain.lookup(a, &outcome);
    try a.run();
    if (applied != null) content_domain.foundPair(&rows, &message, &outcome);

    if (faults.content_import) return error.InjectedContentImportFailure;
    var admission_id: u64 = 0;
    if (applied) |value| {
        const text_id = try content_domain.importBytes(a, &message, task);
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update("rui/core/start_agent/v1");
        digest.update(&protocol.contentDigest(task));
        const answer: StoredAnswer = .{ .accepted = true, .revision = value.revision, .created = true };
        try configuration_domain.queueConfiguredCommand(a, value, key, .message, &digest.finalResult(), text_id, null, &answer);
        admission_id = try a.identity(.admission_id);
        a.write(admit_sent_message, .{
            .admission_id = admission_id,
            .session = value.head,
            .key = key,
            .content_id = text_id,
            .position = try (try a.positions(value.head)).take(1),
            .sender = found.session,
            .sender_position = try (try a.positions(found.session)).take(1),
        });
    }
    const outcome_id = try content_domain.importBytes(a, &outcome, result);
    try action_domain.queueCoreResolution(a, binding, found.session, if (applied != null) .succeeded else .failed, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    const value = applied orelse return .failed;
    if (committed) |callback| callback.call(callback.context, .{ .session = value.session.slice(), .admission_id = admission_id, .from_peer = true });
    return .started;
}

/// Resolves a core tool call and lets its Turn continue in one transaction.
/// A call whose Turn a stop selected is left to the stop.
pub fn resolveCoreCall(a: anytype, binding: action_domain.ActionAttemptBinding, code: action_domain.ActionResolutionCode, result: []const u8, faults: Faults) !bool {
    var facts: action_domain.core_facts.Result = undefined;
    const names: action_domain.CoreNames = .of();
    a.read(action_domain.core_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools }, &facts);
    var outcome: content_domain.Import = .ofBytes(result, false);
    content_domain.lookup(a, &outcome);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.stopped) {
        try a.abandon(.{});
        return false;
    }
    if (faults.content_import) return error.InjectedContentImportFailure;
    const outcome_id = try content_domain.importBytes(a, &outcome, result);
    try action_domain.queueCoreResolution(a, binding, found.session, code, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}

/// The Session a stop names, and the last Message admitted to it: the
/// stop excludes every Message up to that one. Also the stop it owes, if
/// any: the cause and position its owed key names.
const stop_target = rsql.Read(.{
    .sql = "SELECT session_ref,workspace_key,next_position,(SELECT coalesce(max(admission_id),0) FROM message_admission WHERE session_ref=?1) AS admission_cutoff," ++
        turn_domain.unowedChildrenSql("?1") ++ " AS unowed_children," ++
        "(SELECT cause_ref FROM session_stop_owed WHERE child_ref=?1 AND settled=0) AS owed_cause,(SELECT cause_position FROM session_stop_owed WHERE child_ref=?1 AND settled=0) AS owed_position " ++
        "FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        admission_cutoff: u64,
        unowed_children: u64,
        owed_cause: ?protocol.Bounded(protocol.session_id_bytes),
        owed_position: ?u64,

        /// Whether `key` is the key of the stop this Session owes now.
        fn owedUnder(row: *const @This(), key: []const u8) bool {
            const cause = row.owed_cause orelse return false;
            var buffer: [protocol.max_key_bytes]u8 = undefined;
            const owed = action_domain.owedStopKey(&buffer, row.session.ref[0..], cause.slice(), row.owed_position.?) catch return false;
            return std.mem.eql(u8, owed, key);
        }
    },
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

const settle_owed_stop = rsql.Write(.{
    .sql = "UPDATE session_stop_owed SET settled=1 WHERE child_ref=?1 AND settled=0",
    .Args = struct { session: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The most Actions one cancelling write names: the largest count whose
/// ids, with the content, first position and Session before them and @now
/// after, fit 17 parameters: 3 + 13 + 1. The Store allows 65 since a
/// settlement batch holds 64 items (SQLITE_LIMIT_VARIABLE_NUMBER, as in
/// `Store.open`); this chunk keeps main's 13.
const cancel_chunk = 13;

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

/// Collects one `cancellable_actions` page, of at most one write's ids.
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
    return stopRounds(a, command, false, faults) catch |err| switch (err) {
        error.InterruptionTargetChanged => error.StopSelectionChanged,
        else => err,
    };
}

/// The stop an attached child owes (D38), under its owed key. Clients
/// cannot use `rui.core/` keys (`protocol.reserved_key_prefix`), so the
/// key is free while the obligation stands. Any stop settles what the
/// Session owes, and a newer obligation has another key: an owed stop
/// whose key is not the one owed now runs nothing and answers conflict.
pub fn stopOwedSession(a: anytype, command: *const protocol.SessionStopCommand, faults: Faults) !SessionStopReply {
    return stopRounds(a, command, true, faults) catch |err| switch (err) {
        error.InterruptionTargetChanged => error.StopSelectionChanged,
        else => err,
    };
}

/// Round 1 reads the saved answer, the Session with its admission cutoff,
/// and its open Turn with its Actions' counts. A replay reads the saved
/// selection and the Operation it interrupted in a round of its own.
///
/// Otherwise the writes are queued in this order: the command, the stop,
/// the interruption of a running Operation, the cancelled Actions and the
/// Turn's close (unless an attempted Action keeps it open). When Actions
/// are cancelled, the cancellation text's row and the first page of up to
/// `cancel_chunk` Actions are read in a second round (they depend on the
/// Turn), which also runs the command, stop and interruption writes queued
/// before it. Each further page is one more round, which runs the previous
/// page's write (the first one with the cancellation text's insert, when
/// the text is new). The last page's write and the Turn's close run in the
/// final round, at commit, with the position advance. With no Actions to
/// cancel, every write runs at commit.
fn stopRounds(a: anytype, command: *const protocol.SessionStopCommand, owed: bool, faults: Faults) !SessionStopReply {
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
    // An owed stop runs only while its obligation stands: a stop under
    // another key, or a newer obligation, settled or replaced it.
    if (owed and !(target != null and target.?.owedUnder(key) and saved == null)) {
        try a.abandon(.{});
        return .conflict;
    }
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
    const stop_position = try positions.take(1);
    a.write(insert_stop, .{ .key = key, .session = head, .selected_turn_id = selection.selected_turn_id, .admission_cutoff = selection.admission_cutoff, .position = stop_position });
    // A stop settles any stop this Session owed, and its attached children
    // now owe theirs (D38).
    if (found.owed_cause != null) a.write(settle_owed_stop, .{ .session = &head.ref });
    turn_domain.queueOwedStops(a, &head.ref, stop_position, found.unowed_children);
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
    // The count says when the last page was read, so a multiple of
    // `cancel_chunk` costs no empty round.
    while (chunk.len != 0) {
        switch (chunk.len) {
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
        }
        cancelled += chunk.len;
        if (cancelled >= open.cancellable or chunk.len < cancel_chunk) break;
        // A statement binds when it is queued, so `cancel_actions[n - 1]`
        // runs once a round: the next page reads in the round that runs
        // this page's write.
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
        if (!pending.pending) try turn_domain.queueCloseOr(a, try a.positions(head), command.turn_id, .cancelled, error.InterruptionTargetChanged);
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
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,a.authorized,a.resolution_code IS NULL AS unresolved,t.outcome_code IS NULL AS turn_open,t.turn_id," ++
        "EXISTS(SELECT 1 FROM session_forward f WHERE f.target_ref=?2 AND f.kind=1 AND f.source_id=a.action_id AND f.position IS NOT NULL) AS forwarded " ++
        "FROM action_operation a JOIN session s ON s.session_ref=a.session_ref " ++
        "JOIN model_operation operation ON operation.operation_id=a.parent_operation_id JOIN turn t ON t.turn_id=operation.turn_id WHERE a.action_id=?1",
    .Args = struct { action_id: u64, target: []const u8 },
    .Row = struct { session: rsql.SessionHead, authorized: bool, unresolved: bool, turn_open: bool, turn_id: rsql.Positive, forwarded: bool },
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
    if (!std.mem.eql(u8, &found.session.ref, command.session.slice()) and !found.forwarded) return .target_mismatch;
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
        if (protocol.validSessionId(session)) a.read(decision_action, .{ .action_id = command.action_id, .target = session }, &action);
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
        const head = action.?.session;
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
    return .{
        .kind = for (std.enums.values(protocol.CommandKind)) |candidate| {
            if (kindCode(candidate) == row.kind) break candidate;
        } else return error.CorruptStore,
        .target = row.target,
        .digest = row.input_digest,
        .accepted = row.accepted,
        .code = row.code,
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

/// The Messages of the Session ?1 that no Turn took, after the latest
/// stop's cutoff ?2 (`stop_cutoff`, 0 without a stop): main's count,
/// whose one row main stepped once.
pub const pending_messages = rsql.Read(.{
    .sql = pending_message_count_sql,
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = struct { pending: u64 },
    .cardinality = .each,
});

/// The Session's latest stop's admission cutoff, stepped once.
pub const stop_cutoff = rsql.Read(.{
    .sql = session_stop_cutoff_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { admission_cutoff: u64 },
    .cardinality = .each,
});

const insert_command = rsql.Write(.{
    .sql = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
        "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
    .Args = struct {
        key: []const u8,
        kind: u8,
        target: []const u8,
        digest: [32]u8,
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

/// Queues saving the command `key` with its `answer`, which, like `key`
/// and `target`, must outlive the round; `digest` is copied.
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
        .digest = digest.*,
        .primary_content_id = primary_content_id,
        .secondary_content_id = secondary_content_id,
        .accepted = answer.accepted,
        .code = answer.code.slice(),
        .revision = answer.revision,
        .created = answer.created,
        .command_seq = try a.identity(.command_seq),
    });
}

// The Session's Operations are admitted in Turn order. The bound Turn's
// first/current Operation range excludes both older and later Turns. The
// existing turn-history index makes its lower bound a single bounded seek.
const recovery_range_sql =
    "a.session_ref=m.session_ref AND a.resolution_code='indeterminate' " ++
    "AND a.parent_operation_id BETWEEN (SELECT first_operation.operation_id " ++
    "FROM model_operation first_operation @index(model_operation_turn_history) " ++
    "WHERE first_operation.turn_id=m.turn_id ORDER BY first_operation.operation_id LIMIT 1) AND t.operation_id";

/// An accepted Message's admission, the Turn that applied it, the stop
/// that excluded it while no Turn did, and the metadata of its text and
/// of its answer, with its Session's creation time for its progress.
const message_observation = rsql.Read(.{
    .sql = "SELECT m.session_ref,m.content_id,m.admission_id,m.command_key,m.turn_id,t.operation_id,o.attempt_ordinal," ++
        "t.outcome_code,t.outcome_content_id,CASE WHEN m.turn_id IS NULL THEN (" ++
        "SELECT stopped.command_key FROM session_stop stopped JOIN core_command stop_command " ++
        "ON stop_command.command_key=stopped.command_key WHERE stopped.session_ref=m.session_ref " ++
        "AND m.admission_id<=stopped.admission_cutoff ORDER BY stop_command.command_seq LIMIT 1) END AS excluding_stop," ++
        "input.byte_length AS input_length,input.digest AS input_digest,answer.byte_length AS answer_length,answer.digest AS answer_digest," ++
        "s.created_at,m.admitted_at,EXISTS(SELECT 1 FROM action_operation a @index(action_operation_indeterminate) WHERE " ++ recovery_range_sql ++ ") AS has_recovery " ++
        "FROM message_admission m JOIN content input ON input.content_id=m.content_id JOIN session s ON s.session_ref=m.session_ref " ++
        "LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
        "LEFT JOIN content answer ON answer.content_id=t.outcome_content_id " ++
        "WHERE m.command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct {
        session_ref: protocol.Bounded(protocol.max_session_bytes),
        content_id: rsql.Positive,
        admission_id: rsql.Positive,
        command_key: protocol.Bounded(128),
        turn_id: ?rsql.Positive,
        operation_id: ?rsql.Positive,
        attempt_ordinal: ?rsql.Positive,
        outcome_code: ?protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        excluding_stop: ?protocol.Bounded(128),
        input_length: u64,
        input_digest: [32]u8,
        answer_length: ?u64,
        answer_digest: ?[32]u8,
        created_at: rsql.Positive,
        admitted_at: rsql.Positive,
        has_recovery: bool,
    },
    .cardinality = .one,
});

/// The Action and decision a permission decision saved.
const permission_target = rsql.Read(.{
    .sql = "SELECT action_id,decision FROM permission_decision_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { action_id: protocol.Bounded(20), decision: protocol.PermissionDecision },
    .cardinality = .one,
});

/// Round 1 reads the saved command. Its kind picks what round 2 reads,
/// keyed on the command alone: a dependent round, one more network round
/// trip, run only for a kind that saved more than its answer. A queued or
/// processing Message's progress is its Session's work, read in the rounds
/// after (`readMessageWork`).
pub fn observeCommand(a: anytype, key: []const u8, observation: *CommandObservation) !void {
    var saved: saved_command.Result = undefined;
    lookupCommand(a, key, &saved);
    try a.run();
    const command = try savedAnswer(&saved) orelse {
        observation.* = .{ .status = .absent };
        return;
    };
    observation.* = .{
        .status = if (command.accepted) .accepted else .rejected,
        .target = command.target,
        .code = command.code,
    };
    switch (command.kind) {
        .configure => observation.kind = .{ .configure = .{ .revision = command.revision, .created = command.created } },
        .message => {
            observation.kind = .{ .message = null };
            if (!command.accepted) return;
            var row: message_observation.Row = undefined;
            a.read(message_observation, .{ .key = key }, &row);
            try a.run();
            const content_id = command.primary_content_id orelse return error.CorruptStore;
            if (!row.session_ref.eql(command.target.slice()) or row.content_id.get() != content_id) return error.CorruptStore;
            const queue = try messageQueue(&row);
            observation.kind.message = .{ .content = .{ .length = row.input_length, .digest = row.input_digest }, .queue = queue, .admitted_at = row.admitted_at.get() };
            if (row.has_recovery) try readRecovery(a, key, &observation.kind.message.?.recovery);
            switch (queue.state) {
                .queued, .processing => observation.kind.message.?.work = try readMessageWork(a, command.target.slice(), row.created_at.get(), queue.state),
                else => {},
            }
        },
        .session_stop => {
            observation.kind = .{ .session_stop = null };
            if (!command.accepted) return;
            var row: stop_selection.Row = undefined;
            a.read(stop_selection, .{ .key = key }, &row);
            try a.run();
            observation.kind.session_stop = stopObservation(&row);
        },
        .model_interruption => {
            var row: interruption_target.Row = undefined;
            a.read(interruption_target, .{ .key = key }, &row);
            try a.run();
            observation.kind = .{ .model_interruption = try modelInterruptionTarget(&row) };
        },
        .permission_decision => {
            var row: permission_target.Row = undefined;
            a.read(permission_target, .{ .key = key }, &row);
            try a.run();
            observation.kind = .{ .permission_decision = .{
                .action_id = std.fmt.parseInt(u64, row.action_id.slice(), 10) catch return error.CorruptStore,
                .decision = row.decision,
            } };
        },
    }
}

/// Where an accepted Message stands in its Session's queue.
fn messageQueue(row: *const message_observation.Row) !AcceptedMessageQueue {
    const projection = try projectMessage(row, if (row.excluding_stop) |*stop| stop.slice() else null);
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
                .completed => .{ .admission_id = projection.admission_id, .state = .{ .completed = .{
                    .binding = applied.binding,
                    .answer = .{
                        .length = row.answer_length orelse return error.CorruptStore,
                        .digest = row.answer_digest orelse return error.CorruptStore,
                    },
                } } },
                .cancelled => .{ .admission_id = projection.admission_id, .state = .{ .cancelled = .{ .binding = applied.binding, .code = outcome } } },
                .retry_exhausted, .resource_exceeded, .failed => .{ .admission_id = projection.admission_id, .state = .{ .failed = .{ .binding = applied.binding, .code = outcome } } },
            };
        },
    };
}

/// A pending Message's progress is its Session's work: its own active
/// Turn, or the work ahead of it in the queue. Its rounds follow the
/// observation's, whose row says whether the Message is pending.
fn readMessageWork(a: *report_domain.ReadAccess, session_ref: []const u8, created_at: u64, state: AcceptedMessageQueue.State) !session_work.Work {
    var read: report_domain.WorkRead = .{ .session = session_ref };
    try report_domain.readWorks(a, (&read)[0..1]);
    const work = try read.work(created_at, std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange);
    if (state == .processing and work.turn != state.processing.turn_id) return error.CorruptStore;
    return work;
}

/// Newest Actions first (Operation, then call), not recovery wall-clock
/// order: sibling Actions can resolve out of order. Only five indexed rows
/// are visited; the fifth proves `more`.
const recovery_actions = rsql.Read(.{
    .sql = "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.resolved_at,c.description " ++
        "FROM message_admission m JOIN turn t ON t.turn_id=m.turn_id " ++
        "JOIN action_operation a @index(action_operation_indeterminate) ON a.session_ref=m.session_ref " ++
        "JOIN model_tool_call c ON c.operation_id=a.parent_operation_id AND c.call_ordinal=a.call_ordinal " ++
        "WHERE m.command_key=?1 AND " ++ recovery_range_sql ++ " " ++
        "ORDER BY a.parent_operation_id DESC,a.call_ordinal DESC LIMIT 5",
    .Args = struct { key: []const u8 },
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, call_ordinal: u64, resolved_at: rsql.Positive, description: ?protocol.Bounded(protocol.max_tool_description_bytes) },
    .cardinality = .{ .at_most = 5 },
});

fn readRecovery(a: anytype, key: []const u8, out: *reads_domain.Recovery) !void {
    var actions: recovery_actions.Result = undefined;
    a.read(recovery_actions, .{ .key = key }, &actions);
    try a.run();
    if (actions.len == 0) return error.CorruptStore;
    out.count = @intCast(@min(actions.len, reads_domain.Recovery.capacity));
    out.more = actions.len > reads_domain.Recovery.capacity;
    for (actions.items[0..out.count], 0..) |row, i| {
        out.calls[i] = .{
            .action_id = row.action_id.get(),
            .operation_id = row.parent_operation_id.get(),
            .call = row.call_ordinal,
            .description = row.description,
            .at = row.resolved_at.get(),
        };
    }
}

/// An accepted Message's outcome, whether a stop excluded it, and its
/// answer's metadata.
const message_result = rsql.Read(.{
    .sql = "SELECT t.outcome_code,t.outcome_content_id,EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
        "AND m.admission_id<=stopped.admission_cutoff) AS stopped,answer.byte_length AS answer_length,answer.digest AS answer_digest " ++
        "FROM core_command command JOIN message_admission m ON m.command_key=command.command_key " ++
        "LEFT JOIN turn t ON t.turn_id=m.turn_id LEFT JOIN content answer ON answer.content_id=t.outcome_content_id " ++
        "WHERE command.command_key=?1 AND command.kind=2 AND command.accepted=1",
    .Args = struct { key: []const u8 },
    .Row = struct {
        outcome_code: ?protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        stopped: bool,
        answer_length: ?u64,
        answer_digest: ?[32]u8,
    },
    .cardinality = .optional,
});

/// One round: the Message's outcome with its answer's metadata.
pub fn commandResult(a: anytype, key: []const u8) !ContentReference {
    var result: message_result.Result = null;
    a.read(message_result, .{ .key = key }, &result);
    // The Host's fence names this read, as on main.
    try store_access.runAs(a, error.ResultReadFailed);
    const row = result orelse return error.ResultNotFound;
    const outcome = row.outcome_code orelse return if (row.stopped) error.ResultFailed else error.ResultNotReady;
    switch (try TurnOutcome.decode(outcome.slice(), if (row.outcome_content_id) |id| @intCast(id.get()) else null)) {
        .completed => return .{
            .length = row.answer_length orelse return error.CorruptStore,
            .digest = row.answer_digest orelse return error.CorruptStore,
        },
        .cancelled, .retry_exhausted, .resource_exceeded, .failed => return error.ResultFailed,
    }
}

/// Where a Message stands, from `row`'s admission_id, command_key,
/// content_id, turn_id, operation_id, attempt_ordinal, outcome_code and
/// outcome_content_id: applied by a Turn, excluded by the stop
/// `excluding_stop`, or pending.
pub fn projectMessage(row: anytype, excluding_stop: ?[]const u8) !MessageProjection {
    var projection: MessageProjection = .{
        .admission_id = row.admission_id.get(),
        .command_key = row.command_key,
        .content_id = @intCast(row.content_id.get()),
        .state = .pending,
    };
    const turn_id = row.turn_id orelse {
        if (row.operation_id != null or row.attempt_ordinal != null or row.outcome_code != null or row.outcome_content_id != null) return error.CorruptStore;
        if (excluding_stop) |key| {
            var stop_key: protocol.Bounded(128) = .{};
            try stop_key.set(key);
            projection.state = .{ .excluded = stop_key };
        }
        return projection;
    };
    if (excluding_stop != null) return error.CorruptStore;
    if (row.outcome_code) |code| if (code.len == 0) return error.CorruptStore;
    if (row.outcome_code == null and row.outcome_content_id != null) return error.CorruptStore;
    projection.state = .{ .applied = .{
        .binding = .{
            .turn_id = turn_id.get(),
            .operation_id = (row.operation_id orelse return error.CorruptStore).get(),
            .attempt_ordinal = (row.attempt_ordinal orelse return error.CorruptStore).get(),
        },
        .outcome_code = row.outcome_code,
        .outcome_content_id = if (row.outcome_content_id) |id| @intCast(id.get()) else null,
    } };
    return projection;
}
