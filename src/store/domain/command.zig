//! Commands a person or peer sends a Session (messages, Session stops, model
//! interruptions, permission decisions), their replay, and their observed results.

const std = @import("std");
const model_attempt = @import("model_attempt.zig");
const command_reply = @import("../../command_reply.zig");
const skills_domain = @import("skills.zig");
const turn_ending = @import("../../turn_ending.zig");
const message_admission = @import("../../message_admission.zig");
const workspace_path = @import("../../workspace_path.zig");
const outcome_code = @import("../../outcome_code.zig");
const content_string = @import("../../content_string.zig");
const tool_defs = @import("../../tool_record.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const cli_value = @import("../../cli_value.zig");
const mutation_answer = @import("../../mutation_answer.zig");
const configuration_admission = @import("../../configuration_admission.zig");
const provider_name = @import("../../provider_name.zig");
const provider_route = @import("../../provider_route.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const content_custody = @import("../../content_custody.zig");
const command_input = @import("../../command_input.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("action.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const sqlite = @import("../sqlite.zig");
const tool_set = @import("tool_set.zig");
const transition = @import("../transition.zig");
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

pub const AcceptedMessage = command_reply.AcceptedMessage;

pub const RejectedMessage = command_reply.RejectedMessage;

pub const MessageReply = command_reply.MessageReply;

pub const StoredAnswer = struct {
    accepted: bool,
    code: Bounded(outcome_code.max_bytes) = .{},
    revision: u64 = 0,
    created: bool = false,
};

pub const CommandObservation = command_reply.CommandObservation;

pub const SessionStopSelection = command_reply.SessionStopSelection;

pub const SessionStopObservation = command_reply.SessionStopObservation;

pub const ModelInterruptionTarget = command_reply.ModelInterruptionTarget;

pub const SessionStopReply = command_reply.SessionStopReply;

pub const ModelInterruptionReply = command_reply.ModelInterruptionReply;

pub const SessionArchiveReply = command_reply.SessionArchiveReply;

pub const PermissionDecisionReply = command_reply.PermissionDecisionReply;
pub const max_permission_decision_bytes = sqlite.maxEnumTagBytes(mutation_answer.PermissionDecision);

const MessageProjection = struct {
    admission_id: u64,
    command_key: Bounded(128),
    content_id: i64,
    state: union(enum) {
        pending,
        excluded: Bounded(128),
        applied: struct {
            binding: AttemptBinding,
            outcome_code: ?Bounded(outcome_code.max_bytes),
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
    .Row = struct { admission_id: rsql.Positive, session_ref: Bounded(session_id.max_reference_bytes), content_id: rsql.Positive, length: u64, digest: [32]u8 },
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

/// The one writer of a Message from another Session. Heads were read (or
/// created) by the caller in this transaction; admission never adds a round.
/// The caller then saves the skills its text bound
/// (`skills_domain.SavingBound`), a round each.
fn admitFromSession(
    a: anytype,
    sender: *const rsql.SessionHead,
    target: *const rsql.SessionHead,
    key: []const u8,
    content_id: u64,
    digest: *const [32]u8,
    configured: ?*const configuration_domain.Applied,
    answer: *const StoredAnswer,
) !u64 {
    try queueMessageCommand(a, target, key, content_id, digest, configured, answer);
    const admission_id = try a.identity(.admission_id);
    a.write(admit_sent_message, .{
        .admission_id = admission_id,
        .session = target.*,
        .key = key,
        .content_id = content_id,
        .position = try (try a.positions(target.*)).take(1),
        .sender = sender.*,
        .sender_position = try (try a.positions(sender.*)).take(1),
    });
    return admission_id;
}

fn queueMessageCommand(a: anytype, target: *const rsql.SessionHead, key: []const u8, content_id: u64, digest: *const [32]u8, configured: ?*const configuration_domain.Applied, answer: *const StoredAnswer) !void {
    if (configured) |applied| {
        try configuration_domain.queueConfiguredCommand(a, applied, key, .message, digest, content_id, null, answer);
    } else {
        try queueCommand(a, key, .message, &target.ref, digest, content_id, null, answer);
    }
}

fn sentDigest(comptime domain: []const u8, content_digest: *const [32]u8) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(domain);
    digest.update(content_digest);
    return digest.finalResult();
}

/// A peer's rejected Message, at its sender's next position.
const reject_sent = rsql.Write(.{
    .sql = "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,@session(?2),?3,@now)",
    .Args = struct { key: []const u8, sender: rsql.SessionHead, position: u64 },
    // A replay was classified first, so the key is free.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// What every Message reads in round 1, besides its Session or its
/// creation, and keeps until commit.
pub const MessageReads = struct {
    digest: [32]u8,
    saved: saved_command.Result = undefined,
    sender: message_sender.Result = null,
    /// The text's identity, and the row its lookup found.
    text: content_domain.Import,
    /// The skills the text's `/name` words bound, saved with the admission.
    bound: []const skills_domain.BoundSkill = &.{},
};

/// The handle a peer Message's sender claims, when its address names this
/// Store: only then can an Action of this Store hold it.
fn claimedHandle(command: *const content_custody.MessageCommand, selector: []const u8) ?[]const u8 {
    const handle = if (command.sender_handle) |*value| value else return null;
    const claimed = if (command.sender) |*value| value else return null;
    if (!claimed.store.eql(selector)) return null;
    return handle.slice();
}

/// Whether the Message's sender is what its handle proves: no sender and
/// no handle, or the Session of the Action `found` holds the handle.
fn senderValid(command: *const content_custody.MessageCommand, selector: []const u8, found: message_sender.Result) bool {
    if (command.sender_handle == null) return command.sender == null;
    if (claimedHandle(command, selector) == null) return false;
    const row = found orelse return false;
    return command.sender.?.session.eql(&row.session.ref);
}

fn readMessage(a: anytype, selector: []const u8, command: *const content_custody.MessageCommand, reads: *MessageReads) void {
    lookupCommand(a, command.key.slice(), &reads.saved);
    if (claimedHandle(command, selector)) |handle| a.read(message_sender, .{ .handle = handle }, &reads.sender);
}

/// A Message to an existing Session, or one that creates its Session.
/// Only an authenticated Action can acquire a sender position; an exact
/// replay needs no still-live handle.
///
/// Round `.facts` reads the saved answer and the sender's Action, with
/// the Session and the text's content row, or for a creation the rows its
/// configuration needs (`configuration.prepareConfiguration`). An accepted
/// replay reads its admission and text in `.replay`. A creation's
/// validation and application add their own rounds (`.model` to
/// `.loaded`, `configuration.validateStep`; `.creation` and `.catalog`,
/// `configuration.applyStep`), then the text's lookup is `.text`, which
/// also runs the creation's writes. A refusal with a diagnostic looks its
/// row up in `.failure`. An admitted Message saves the skills its text
/// bound, one `.skill` round each. The commit round saves the rest.
pub const SubmitMessage = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{.always},
        .replay = .{.branch},
        .model = .{.branch},
        .saved_tools = .{.branch},
        .saved_loaded = .{.branch},
        .loaded_source = .{.branch},
        .loaded = .{.branch},
        .creation = .{.paged},
        .catalog = .{.branch},
        .text = .{.branch},
        .failure = .{.branch},
        .skill = .{.paged},
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// Each is the caller's, which outlives the transition.
    pub const Input = struct {
        io: std.Io,
        served: provider_route.Routes,
        tools: *const store_core.HostTools,
        /// This Store's selector, which a peer sender's address names.
        selector: []const u8,
        command: *const content_custody.MessageCommand,
        committed: ?MessageCommitted,
        initial_skills: ?*const skills_domain.Initial,
        captured: ?*const skills_domain.MessageCapture,
        /// Where the answer goes, in the caller's frame: a step's result
        /// stays one word wide.
        reply: *MessageReply,
    };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{SessionUpdateFailed};
    pub const Declined = error{};

    input: Input,
    /// A plain Message's reads; a creation's are its configure reads'.
    plain: MessageReads = undefined,
    target: target_session.Result = null,
    /// A creation's configure reads, leased from the Store's scratch.
    creation: *configuration_domain.ConfigurationReads = undefined,
    sender_valid: bool = false,
    rejection: message_admission.Rejection = undefined,
    /// The command's answer, whose code its write reads in place.
    answer: StoredAnswer = undefined,
    /// The admitted Session, whose reference the command's write reads in
    /// place.
    head: rsql.SessionHead = undefined,
    /// What the rounds after the decision keep, as one path runs them: a
    /// replay's admission, a creation's saved tool selection, a refusal's
    /// diagnostic or the admitted Message's skills.
    later: union {
        replay: message_replay.Result,
        saved: tool_set.SavedSelection,
        failure: skills_domain.ImportingFailure,
        skills: skills_domain.SavingBound,
    } = undefined,
    /// The admission the commit saves, or 0 for a refusal.
    admission_id: u64 = 0,

    pub fn step(t: *SubmitMessage, r: *transition.Round(SubmitMessage), ran: ?rounds.At) !transition.Next(SubmitMessage) {
        const at = ran orelse return t.start(r);
        switch (at) {
            .facts => return t.decide(r),
            .replay => return t.replayed(),
            .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => {
                if (try t.validate(r, switch (at) {
                    inline .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => |tag| @field(configuration_domain.ValidationRound, @tagName(tag)),
                    else => unreachable,
                })) |next| return next;
                return t.applyValidated(r);
            },
            .creation => return t.apply(r, .creation),
            .catalog => return t.apply(r, .catalog),
            .text => {
                const applied = &t.creation.applied;
                t.head = applied.head;
                return t.admit(r, applied);
            },
            .failure => return t.rejectDiagnosed(r),
            .skill => return t.saveSkill(r),
        }
    }

    /// After `.failure`: the refusal, with its diagnostic's row.
    noinline fn rejectDiagnosed(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        return t.reject(r, try t.later.failure.import(r, r.faults()));
    }

    /// After `.skill`: the skill it looked up, then the next.
    noinline fn saveSkill(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        try t.later.skills.save(r, r.faults());
        return t.saveSkills(r);
    }

    fn reads(t: *SubmitMessage) *MessageReads {
        return if (t.input.command.configuration != null) &t.creation.message else &t.plain;
    }

    // The steps that run a round's work are noinline, so none sits under
    // another on the engine thread's chain.
    noinline fn start(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) transition.Next(SubmitMessage) {
        const command = t.input.command;
        if (command.configuration != null) {
            // Creation's configuration and Message facts have one address in
            // the Store's scratch until this transaction settles.
            t.creation = r.configurationReads();
            t.creation.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
        }
        const message = t.reads();
        message.* = .{ .digest = command.semanticDigest(), .text = content_domain.sealedIdentity(&command.text) };
        readMessage(r, t.input.selector, command, message);
        if (command.configuration) |*configuration| {
            configuration_domain.prepareConfiguration(r, t.input.tools.host_tool_set, "", configuration, t.creation);
        } else {
            readTarget(r, command.session.slice(), &t.target);
            content_domain.lookup(r, &message.text);
        }
        return .{ .round = .facts };
    }

    /// After `.facts`: a replay answers what was saved; a fresh Message
    /// is refused or goes on.
    noinline fn decide(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        const command = t.input.command;
        const message = t.reads();
        switch (try classify(message_admission.Rejection, &message.saved, .message, command.session.slice(), &message.digest)) {
            .fresh => {},
            .conflict => return t.done(.conflict),
            .rejected => |code| return t.done(.{ .rejected = .{ .replayed = true, .code = code, .content = .{ .length = command.text.length, .digest = command.text.digest } } }),
            .accepted => |existing| {
                _ = existing.primary_content_id orelse return error.CorruptStore;
                t.later = .{ .replay = undefined };
                r.read(message_replay, .{ .key = command.key.slice() }, &t.later.replay);
                return .{ .round = .replay };
            },
        }
        t.sender_valid = senderValid(command, t.input.selector, message.sender);
        if (command.configuration != null) return t.decideCreation(r);
        const session = command.session.slice();
        const target = t.target;
        const rejection: ?message_admission.Rejection = if (!session_id.valid(session))
            .invalid_session_reference
        else if (!t.sender_valid)
            .invalid_sender_handle
        else if (target == null)
            .unknown_session
        else if (target.?.archive_state == .archiving)
            .session_archiving
        else if (command.require_model and !configuration_domain.servesProviderOf(t.input.served, null, target.?.provider))
            .model_capability_unavailable
        else
            null;
        if (rejection) |code| return t.refuse(r, code, null);
        // The Host bound the text's `/name` words to skills, or found none.
        if (t.input.captured) |captured| switch (captured.*) {
            .failed => |failure| return t.refuse(r, failure.rejection(), failure.bytes),
            .bound => |bound| message.bound = bound,
        };
        if (target.?.archive_state == .archived) r.write(clear_archive, .{ .session = target.?.session });
        t.head = target.?.session;
        return t.admit(r, null);
    }

    /// After `.replay`: the saved admission, which must be the one the
    /// command saved.
    noinline fn replayed(t: *SubmitMessage) !transition.Next(SubmitMessage) {
        const command = t.input.command;
        const message = t.reads();
        const existing = switch (try classify(message_admission.Rejection, &message.saved, .message, command.session.slice(), &message.digest)) {
            .accepted => |existing| existing,
            else => unreachable,
        };
        const row = &t.later.replay;
        if (row.content_id.get() != existing.primary_content_id.? or !existing.target.eql(row.session_ref.slice())) return error.CorruptStore;
        return t.done(.{ .accepted = .{
            .replayed = true,
            .admission_id = row.admission_id.get(),
            .content = .{ .length = row.length, .digest = row.digest },
            .session = existing.target,
        } });
    }

    /// Answers `reply` without writing.
    fn done(t: *SubmitMessage, reply: MessageReply) transition.Next(SubmitMessage) {
        t.input.reply.* = reply;
        return .{ .done = {} };
    }

    /// A creating Message's own refusals, then its configuration's.
    fn decideCreation(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        const command = t.input.command;
        const creation = t.creation;
        const rejection: ?message_admission.Rejection = if (command.session.len != 0)
            .invalid_session_reference
        else if (!t.sender_valid)
            .invalid_sender_handle
        else if (command.require_model and !configuration_domain.servesProviderOf(t.input.served, &command.configuration.?, if (creation.inherits_parent and creation.parent_found.get()) creation.inherited.provider else null))
            .model_capability_unavailable
        else
            null;
        if (rejection) |code| return t.refuse(r, code, null);
        t.later = .{ .saved = undefined };
        // Validation's first step asks for the model's facts or refuses.
        return (try t.validate(r, null)).?;
    }

    /// What the creation's configuration steps read besides its rows.
    fn request(t: *SubmitMessage) configuration_domain.Request {
        return .{
            .io = t.input.io,
            .tools = t.input.tools,
            .served = t.input.served,
            .session = "",
            .configuration = &t.input.command.configuration.?,
            .initial_skills = t.input.initial_skills,
            .saved = &t.later.saved,
        };
    }

    /// Configuration's validation owns ordinary refusal precedence: no
    /// configuration, content or Session write exists when it refuses.
    /// Null once the configuration is valid.
    noinline fn validate(t: *SubmitMessage, r: *transition.Round(SubmitMessage), ran: ?configuration_domain.ValidationRound) !?transition.Next(SubmitMessage) {
        return switch (try configuration_domain.validateStep(r, &t.request(), t.creation, ran)) {
            .round => |round| .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .rejected => |code| try t.refuse(r, std.meta.stringToEnum(message_admission.Rejection, @tagName(code)).?, null),
            .ready => null,
        };
    }

    /// Once the configuration is valid: a skill the text could not bind
    /// refuses it, before any configuration, content or Session write.
    noinline fn applyValidated(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        // The Host bound the text's `/name` words to skills, or found none.
        if (t.input.captured) |captured| switch (captured.*) {
            .failed => |failure| return t.refuse(r, failure.rejection(), failure.bytes),
            .bound => |bound| t.creation.message.bound = bound,
        };
        return t.apply(r, null);
    }

    noinline fn apply(t: *SubmitMessage, r: *transition.Round(SubmitMessage), ran: ?configuration_domain.ApplyRound) !transition.Next(SubmitMessage) {
        switch (try configuration_domain.applyStep(r, &t.request(), r.faults(), t.creation, ran)) {
            .round => |round| return .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .accepted => {},
        }
        content_domain.lookup(r, &t.creation.message.text);
        return .{ .round = .text };
    }

    /// A refusal; one with a diagnostic looks its row up in `.failure`.
    fn refuse(t: *SubmitMessage, r: *transition.Round(SubmitMessage), code: message_admission.Rejection, diagnostic: ?[]const u8) !transition.Next(SubmitMessage) {
        t.rejection = code;
        const bytes = diagnostic orelse return t.reject(r, null);
        t.later = .{ .failure = .{ .bytes = bytes } };
        t.later.failure.lookup(r);
        return .{ .round = .failure };
    }

    /// Saves the refused Message; a peer's refusal takes its sender's next
    /// position.
    fn reject(t: *SubmitMessage, r: *transition.Round(SubmitMessage), outcome_id: ?u64) !transition.Next(SubmitMessage) {
        const command = t.input.command;
        const message = t.reads();
        t.answer = .{ .accepted = false };
        try t.answer.code.set(@tagName(t.rejection));
        try queueCommand(r, command.key.slice(), .message, command.session.slice(), &message.digest, outcome_id, null, &t.answer);
        if (command.sender != null and t.sender_valid) {
            const sender = message.sender.?.session;
            r.write(reject_sent, .{ .key = command.key.slice(), .sender = sender, .position = try (try r.positions(sender)).take(1) });
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// After the text's lookup round: imports the text and saves the
    /// command (with the Session revision `configured` wrote, when it
    /// created the Session) and the admission at `head`'s next position.
    noinline fn admit(
        t: *SubmitMessage,
        r: *transition.Round(SubmitMessage),
        configured: ?*const configuration_domain.Applied,
    ) !transition.Next(SubmitMessage) {
        const command = t.input.command;
        const message = t.reads();
        const text_id = try content_domain.importSealed(r, t.input.io, &command.text, &message.text, r.faults());
        t.answer = .{ .accepted = true };
        const admission_id = if (command.sender != null)
            try admitFromSession(r, &message.sender.?.session, &t.head, command.key.slice(), text_id, &message.digest, configured, &t.answer)
        else person: {
            try queueMessageCommand(r, &t.head, command.key.slice(), text_id, &message.digest, configured, &t.answer);
            const admission_id = try r.identity(.admission_id);
            r.write(admit_message, .{ .admission_id = admission_id, .session = t.head, .key = command.key.slice(), .content_id = text_id, .position = try (try r.positions(t.head)).take(1) });
            break :person admission_id;
        };
        t.later = .{ .skills = .{ .admission_id = admission_id, .bound = message.bound } };
        t.admission_id = admission_id;
        return t.saveSkills(r);
    }

    /// A `.skill` round for the next bound skill, or the commit once every
    /// one is saved.
    fn saveSkills(t: *SubmitMessage, r: *transition.Round(SubmitMessage)) !transition.Next(SubmitMessage) {
        if (t.later.skills.lookupNext(r)) return .{ .round = .skill };
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// Commit before announcing an admission: in a batch, once the batch
    /// commits (`Store.admitted`).
    pub fn announced(t: *const SubmitMessage) ?store_core.Announcement {
        if (t.admission_id == 0) return null;
        const callback = t.input.committed orelse return null;
        return .{ .message = .{ .callback = callback, .admission = .{
            .session = &t.head.ref,
            .admission_id = t.admission_id,
            .from_peer = t.input.command.sender != null,
        } } };
    }

    pub fn committed(t: *SubmitMessage) Result {
        const command = t.input.command;
        if (t.admission_id == 0) {
            t.input.reply.* = .{ .rejected = .{ .replayed = false, .code = t.rejection, .content = .{ .length = command.text.length, .digest = command.text.digest } } };
            return;
        }
        const message = t.reads();
        t.input.reply.* = .{
            .accepted = .{
                .replayed = false,
                .admission_id = t.admission_id,
                // The text's row was found or written under exactly this identity.
                .content = .{ .length = message.text.length, .digest = message.text.digest },
                .session = if (command.configuration != null) t.creation.applied.session else command.session,
            },
        };
    }
};

/// The skills a door's capture bound; none for no capture or a failed one.
fn boundOf(captured: ?*const skills_domain.MessageCapture) []const skills_domain.BoundSkill {
    const value = captured orelse return &.{};
    return switch (value.*) {
        .bound => |bound| bound,
        .failed => &.{},
    };
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
fn agentMessageKey(buffer: *[idempotency_key.max_bytes]u8, action_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/message_agent/{d}", .{action_id}) catch unreachable;
}

/// Runs a `message_agent` call as one core command (D24, D41): admits
/// `text` to the Session `target` names, from the call's own Session, and
/// resolves the call with what happened, in one transaction. A Message it
/// sends carries no client environment (D169).
///
/// Round `.facts` reads the call's Action, the saved answer of the call's
/// key, the receiving Session and the text's content row; `.outcome` reads
/// the call's result text's row. A delivered Message is admitted, then
/// saves the skills its text bound, one `.skill` round each, which also
/// runs the writes queued before it. The commit round resolves the call.
pub const DeliverAgentMessage = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .outcome = .{.always}, .skill = .{.paged} });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// `target`, `text` and what `captured` binds are the caller's, which
    /// outlive the transition.
    pub const Input = struct {
        binding: action_domain.ActionAttemptBinding,
        target: []const u8,
        text: []const u8,
        captured: ?*const skills_domain.MessageCapture,
    };
    pub const Result = AgentDelivery;
    pub const Ordinary = store_core.Ordinary.action_attempt;
    pub const Guards = store_core.Ordinary.action_attempt;
    pub const Declined = error{};

    input: Input,
    /// The command key, which its writes read in place.
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,
    key: []const u8 = &.{},
    facts: action_domain.core_facts.Result = undefined,
    saved: saved_command.Result = undefined,
    receiver: target_session.Result = null,
    message: content_domain.Import = undefined,
    /// The call's result, which its content write reads in place.
    result_buffer: [160]u8 = undefined,
    result: []const u8 = &.{},
    outcome: content_domain.Import = undefined,
    delivered: bool = false,
    skills: skills_domain.SavingBound = .{},

    pub fn step(t: *DeliverAgentMessage, r: *transition.Round(DeliverAgentMessage), ran: ?rounds.At) !transition.Next(DeliverAgentMessage) {
        const binding = t.input.binding;
        const at = ran orelse {
            t.key = agentMessageKey(&t.key_buffer, binding.action_id);
            const names: action_domain.CoreNames = .of();
            r.read(action_domain.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.facts);
            lookupCommand(r, t.key, &t.saved);
            readTarget(r, t.input.target, &t.receiver);
            t.message = .ofBytes(t.input.text, false);
            content_domain.lookup(r, &t.message);
            return .{ .round = .facts };
        };
        if (t.facts == null) return error.StaleActionAttemptBinding;
        switch (at) {
            .facts => return t.decide(r),
            .outcome => {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                if (!t.delivered) return t.resolve(r);
                const receiver = &t.receiver.?;
                if (receiver.archive_state == .archived) r.write(clear_archive, .{ .session = receiver.session });
                const text_id = try content_domain.importBytes(r, &t.message, t.input.text);
                const digest = sentDigest("rui/core/message_agent/v1", &content_string.digest(t.input.text));
                const admission_id = try admitFromSession(r, &t.facts.?.session, &receiver.session, t.key, text_id, &digest, null, &.{ .accepted = true });
                t.skills = .{ .admission_id = admission_id, .bound = boundOf(t.input.captured) };
                return t.saveSkills(r);
            },
            .skill => {
                try t.skills.save(r, r.faults());
                return t.saveSkills(r);
            },
        }
    }

    /// After `.facts`: a stopped call ends; any other is delivered, or
    /// fails with a result saying why nothing was sent.
    fn decide(t: *DeliverAgentMessage, r: *transition.Round(DeliverAgentMessage)) !transition.Next(DeliverAgentMessage) {
        if (t.facts.?.stopped) return .{ .done = .stopped };
        const target = t.input.target;
        // The Host bound the text's `/name` words to the receiver's skills.
        const unreadable: ?skills_domain.MessageFailure = if (t.input.captured) |value| switch (value.*) {
            .failed => |failure| failure,
            .bound => null,
        } else null;
        t.delivered = t.receiver != null and t.receiver.?.archive_state != .archiving and t.saved == null and unreadable == null;
        t.result = if (t.receiver == null)
            std.fmt.bufPrint(&t.result_buffer, "No Session {s} in this Store; nothing was sent.", .{target}) catch unreachable
        else if (t.receiver.?.archive_state == .archiving)
            "Rui could not send this Message: the Session is archiving. Nothing was sent."
        else if (t.saved != null)
            "Rui could not send this Message: its command key is already taken. Nothing was sent."
        else if (unreadable) |failure|
            std.fmt.bufPrint(&t.result_buffer, "{s} Nothing was sent.", .{failure.bytes[0..@min(failure.bytes.len, 120)]}) catch unreachable
        else
            std.fmt.bufPrint(&t.result_buffer, "Delivered to {s}.", .{target}) catch unreachable;
        t.outcome = .ofBytes(t.result, false);
        content_domain.lookup(r, &t.outcome);
        return .{ .round = .outcome };
    }

    /// A `.skill` round for the next bound skill, or the call's
    /// resolution once every one is saved.
    fn saveSkills(t: *DeliverAgentMessage, r: *transition.Round(DeliverAgentMessage)) !transition.Next(DeliverAgentMessage) {
        if (t.skills.lookupNext(r)) return .{ .round = .skill };
        return t.resolve(r);
    }

    fn resolve(t: *DeliverAgentMessage, r: *transition.Round(DeliverAgentMessage)) !transition.Next(DeliverAgentMessage) {
        const outcome_id = try content_domain.importBytes(r, &t.outcome, t.result);
        try action_domain.queueResolution(r, t.input.binding, t.facts.?.session, if (t.delivered) .succeeded else .failed, outcome_id);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const DeliverAgentMessage) Result {
        return if (t.delivered) .delivered else .failed;
    }
};

fn childEndingKey(buffer: *[idempotency_key.max_bytes]u8, turn_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/ending/{d}", .{turn_id}) catch unreachable;
}

/// The owed ending of `turn_id`: its child's Session, its parent, and how
/// its Turn ended, with the answer's digest when done or its bounded report.
const owed_ending_facts = rsql.Read(.{
    .sql = "SELECT child.session_ref,child.workspace_key,child.next_position,child.parent_ref AS parent,t.outcome_code,t.outcome_content_id,c.digest,CASE WHEN t.outcome_content_id IS NOT NULL AND t.outcome_code<>'completed' THEN @payload(c) ELSE NULL END AS report," ++
        action_domain.ending_stop_sql ++ " FROM session_forward e JOIN turn t ON t.turn_id=e.source_id " ++
        "JOIN session child ON child.session_ref=t.session_ref LEFT JOIN content c ON c.content_id=t.outcome_content_id WHERE e.source_id=?1 AND e.message_delivered=0",
    .Args = struct { turn_id: u64 },
    .Row = struct {
        child: rsql.SessionHead,
        parent: Bounded(session_id.bytes),
        outcome_code: Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        digest: ?[32]u8,
        report: ?Bounded(outcome_code.max_report_bytes),
        stopped: bool,
        quiet: bool,
    },
    .cardinality = .optional,
});

const settle_owed_ending = rsql.Write(.{
    .sql = "UPDATE session_forward SET message_delivered=1 WHERE source_id=?1 AND message_delivered=0",
    .Args = struct { turn_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// What the parent of a child that ended without an answer reads, as a
/// Message from the child (D161).
fn endingText(buffer: []u8, ending: turn_ending.TurnEnding, report: ?[]const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "[Rui: this agent's Turn ended without an answer: {s}.]{s}{s}", .{
        @tagName(ending),
        if (report != null) "\n" else "",
        report orelse "",
    }) catch unreachable;
}

/// Delivers the ending of an attached child's Turn `turn_id` to its parent
/// as a Message from the child (D39), which wakes the parent, and settles
/// what was owed, in one transaction. A done Turn's Message is its saved
/// answer itself, so nothing is copied; any other ending is a short line
/// naming it and the saved provider report, if any. An ending its parent's
/// own stop caused only settles (D139).
/// False when nothing was owed any more. Its `rui.core/` key is free:
/// clients cannot use one, and settling marks the row with the admission.
///
/// Round `.owed` reads what is owed. Unless the ending is quiet, `.parent`
/// reads the parent and the ending line's content row, and runs the
/// settling write. The Message is admitted, then saves the skills its text
/// bound, one `.skill` round each; the commit round runs the rest.
pub const DeliverChildEnding = struct {
    pub const rounds = transition.rounds(.{ .owed = .{.always}, .parent = .{.branch}, .skill = .{.paged} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .owed;
    /// What `captured` binds and `ending` are the caller's, which outlive
    /// the transition.
    pub const Input = struct { turn_id: u64, captured: ?*const skills_domain.MessageCapture, ending: *Ending };

    /// What is owed and the ending line, over 1 KiB together, so held in
    /// the caller's frame. `.parent`'s read reads the parent's reference in
    /// place, and the line's content write reads the line.
    pub const Ending = struct {
        owed: owed_ending_facts.Result,
        text_buffer: [96 + outcome_code.max_report_bytes]u8,
    };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    /// The command key, which its writes read in place.
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,
    key: []const u8 = &.{},
    outcome: TurnOutcome = undefined,
    text: []const u8 = &.{},
    receiver: target_session.Result = null,
    message: content_domain.Import = undefined,
    skills: skills_domain.SavingBound = .{},

    pub fn step(t: *DeliverChildEnding, r: *transition.Round(DeliverChildEnding), ran: ?rounds.At) !transition.Next(DeliverChildEnding) {
        const at = ran orelse {
            t.key = childEndingKey(&t.key_buffer, t.input.turn_id);
            r.read(owed_ending_facts, .{ .turn_id = t.input.turn_id }, &t.input.ending.owed);
            return .{ .round = .owed };
        };
        switch (at) {
            .owed => {
                const found = if (t.input.ending.owed) |*row| row else return .{ .done = false };
                // Even a quiet ending transfers an owed Message without a
                // Session-column write. Keep that transfer in the same owner.
                r.obligationsChanged(found.child);
                r.write(settle_owed_ending, .{ .turn_id = t.input.turn_id });
                if (found.quiet) return finish(r);
                t.outcome = try TurnOutcome.decode(found.outcome_code.slice(), if (found.outcome_content_id) |id| @intCast(id.get()) else null);
                t.text = endingText(&t.input.ending.text_buffer, t.outcome.ending(found.stopped), if (found.report) |*report| report.slice() else null);
                readTarget(r, found.parent.slice(), &t.receiver);
                t.message = .ofBytes(t.text, false);
                if (t.outcome != .completed) content_domain.lookup(r, &t.message);
                return .{ .round = .parent };
            },
            .parent => {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                const parent = if (t.receiver) |*row| row else return error.CorruptStore;
                if (parent.archive_state != .active) return finish(r);
                const found = &t.input.ending.owed.?;
                const content_id: u64, const content_digest: [32]u8 = switch (t.outcome) {
                    .completed => |answer| .{ @intCast(answer), found.digest orelse return error.CorruptStore },
                    else => .{ try content_domain.importBytes(r, &t.message, t.text), content_string.digest(t.text) },
                };
                const digest = sentDigest("rui/core/child_ending/v1", &content_digest);
                // An owed ending cannot be refused; unreadable skills leave it unbound.
                const admission_id = try admitFromSession(r, &found.child, &parent.session, t.key, content_id, &digest, null, &.{ .accepted = true });
                t.skills = .{ .admission_id = admission_id, .bound = boundOf(t.input.captured) };
            },
            .skill => try t.skills.save(r, r.faults()),
        }
        if (t.skills.lookupNext(r)) return .{ .round = .skill };
        return finish(r);
    }

    fn finish(r: *transition.Round(DeliverChildEnding)) !transition.Next(DeliverChildEnding) {
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const DeliverChildEnding) Result {
        return true;
    }
};

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
/// Runs a `start_agent` call as one core command (D24, D122): creates a
/// Session with the call's configuration in the caller's Workspace and with
/// its provider (D122, D221), as its child when `attached`, admits the task
/// to it from the caller, and resolves the call with what happened, in one
/// transaction. The spec may only narrow the caller's tools and permission
/// mode. The configuration is the caller's; its parent, Workspace and
/// provider are filled here.
///
/// Round `.facts` reads the call's Action, the saved answer of the call's
/// key and the rows the configuration needs (`configuration.prepareConfiguration`).
/// A start nothing refuses validates and applies the configuration in their
/// own rounds (`.model` to `.loaded`, `configuration.validateStep`;
/// `.creation` and `.catalog`, `configuration.applyStep`). `.outcome` reads
/// the call's result text's row, with the task's when the agent starts. A
/// started agent saves the skills its task bound, one `.skill` round each.
/// The commit round resolves the call.
pub const StartAgent = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{.always},
        .model = .{.branch},
        .saved_tools = .{.branch},
        .saved_loaded = .{.branch},
        .loaded_source = .{.branch},
        .loaded = .{.branch},
        .creation = .{.paged},
        .catalog = .{.branch},
        .outcome = .{.always},
        .skill = .{.paged},
    });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// Each is the caller's, which outlives the transition.
    pub const Input = struct {
        io: std.Io,
        served: provider_route.Routes,
        tools: *const store_core.HostTools,
        binding: action_domain.ActionAttemptBinding,
        caller: []const u8,
        task: []const u8,
        attached: bool,
        /// The agent's spec, which the start completes.
        configuration: *content_custody.Configuration,
        committed: ?MessageCommitted,
        initial_skills: ?*const skills_domain.Initial,
        captured: ?*const skills_domain.MessageCapture,
        /// Where the call's result text is written, in the caller's frame;
        /// the text's content write reads it in place.
        result_buffer: *[tool_defs.HostToolSet.max_refusal_message_bytes]u8,
    };
    pub const Result = AgentStart;
    pub const Ordinary = store_core.Ordinary.agent_start;
    pub const Guards = store_core.Ordinary.agent_start;
    pub const Declined = error{};

    input: Input,
    /// The command key, which its writes read in place.
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,
    key: []const u8 = &.{},
    facts: action_domain.core_facts.Result = undefined,
    /// The creation's configure reads, leased from the Store's scratch.
    creation: *configuration_domain.ConfigurationReads = undefined,
    /// The call's result, which its content write reads in place.
    result: []const u8 = &.{},
    /// The created Session's settings, once applied.
    applied: ?*const configuration_domain.Applied = null,
    message: content_domain.Import = undefined,
    outcome: content_domain.Import = undefined,
    rows: content_domain.Pair = .{ .first = null, .second = null },
    /// The task's answer, whose fields its command write reads in place.
    answer: StoredAnswer = undefined,
    /// What each round keeps, as one path runs them: the key's saved
    /// answer, the saved tool selection validation reads, then the task's
    /// skills.
    later: union {
        taken: saved_command.Result,
        saved: tool_set.SavedSelection,
        skills: skills_domain.SavingBound,
    } = undefined,
    /// The task's admission, or 0 when nothing started.
    admission_id: u64 = 0,

    pub fn step(t: *StartAgent, r: *transition.Round(StartAgent), ran: ?rounds.At) !transition.Next(StartAgent) {
        const at = ran orelse return t.start(r);
        switch (at) {
            .facts => return t.decide(r),
            .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => return t.validate(r, switch (at) {
                inline .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => |tag| @field(configuration_domain.ValidationRound, @tagName(tag)),
                else => unreachable,
            }),
            .creation => return t.apply(r, .creation),
            .catalog => return t.apply(r, .catalog),
            .outcome => return t.settle(r),
            .skill => return t.saveSkill(r),
        }
    }

    // The steps that run a round's work are noinline, so none sits under
    // another on the engine thread's chain.
    noinline fn start(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        const binding = t.input.binding;
        const configuration = t.input.configuration;
        t.key = std.fmt.bufPrint(&t.key_buffer, "rui.core/start_agent/{d}", .{binding.action_id}) catch unreachable;
        const names: action_domain.CoreNames = .of();
        r.read(action_domain.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.facts);
        t.later = .{ .taken = undefined };
        lookupCommand(r, t.key, &t.later.taken);
        configuration.parent.state = .value;
        try configuration.parent.value.set(t.input.caller);
        // Over 4.6 KB, so held where the Store owns it, as a configure does.
        t.creation = r.configurationReads();
        t.creation.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
        t.creation.attach_parent = t.input.attached;
        configuration_domain.prepareConfiguration(r, t.input.tools.host_tool_set, "", configuration, t.creation);
        return .{ .round = .facts };
    }

    /// After `.facts`: a stopped call ends; a refused one fails with a
    /// result saying why; any other validates its configuration.
    noinline fn decide(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        const found = if (t.facts) |*row| row else return error.StaleActionAttemptBinding;
        if (!std.mem.eql(u8, &found.session.ref, t.input.caller)) return error.CorruptStore;
        if (found.stopped) return .{ .done = .stopped };
        const creation = t.creation;
        if (!creation.parent_found.get()) return error.CorruptStore;
        const host_tool_set = t.input.tools.host_tool_set;
        const configuration = t.input.configuration;
        const buffer = t.input.result_buffer;
        if (t.later.taken != null) return t.fail(r, "Rui could not start the agent: its command key is already taken. Nothing was started.");
        if (try configuration_domain.inheritParent(host_tool_set, configuration, creation)) |code| {
            if (configuration_domain.missingToolMessage(host_tool_set, code, &configuration.tools)) |detail| {
                var writer = std.Io.Writer.fixed(buffer);
                try detail.write(&writer);
                try writer.print(" ({s}). Nothing was started.", .{@tagName(code)});
                return t.fail(r, writer.buffered());
            }
            if (creation.parent_failure) |failure| return t.fail(r, failure.text(buffer, "started"));
            return t.fail(r, std.fmt.bufPrint(buffer, "Rui could not start the agent ({s}). Nothing was started.", .{@tagName(code)}) catch unreachable);
        }
        // The Host bound the task's `/name` words to the new Session's skills.
        if (t.input.captured) |value| if (value.* == .failed)
            return t.fail(r, std.fmt.bufPrint(buffer, "{s} Nothing was started.", .{value.failed.bytes[0..@min(value.failed.bytes.len, 150)]}) catch unreachable);
        t.later = .{ .saved = undefined };
        return t.validate(r, null);
    }

    /// What the creation's configuration steps read besides its rows.
    fn request(t: *StartAgent) configuration_domain.Request {
        return .{
            .io = t.input.io,
            .tools = t.input.tools,
            .served = t.input.served,
            .session = "",
            .configuration = t.input.configuration,
            .initial_skills = t.input.initial_skills,
            .saved = &t.later.saved,
        };
    }

    /// Validation refuses the configuration, which fails the call, or
    /// readies it for application.
    noinline fn validate(t: *StartAgent, r: *transition.Round(StartAgent), ran: ?configuration_domain.ValidationRound) !transition.Next(StartAgent) {
        return switch (try configuration_domain.validateStep(r, &t.request(), t.creation, ran)) {
            .round => |round| .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .rejected => |code| t.fail(r, std.fmt.bufPrint(t.input.result_buffer, "Rui could not start the agent ({s}). Nothing was started.", .{@tagName(code)}) catch unreachable),
            .ready => t.apply(r, null),
        };
    }

    /// Applies the valid configuration; once the Session is created, looks
    /// up the task's and the result's rows.
    noinline fn apply(t: *StartAgent, r: *transition.Round(StartAgent), ran: ?configuration_domain.ApplyRound) !transition.Next(StartAgent) {
        const applied = switch (try configuration_domain.applyStep(r, &t.request(), r.faults(), t.creation, ran)) {
            .round => |round| return .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .accepted => |value| value,
        };
        t.applied = applied;
        t.result = std.fmt.bufPrint(t.input.result_buffer, "Started {s}.", .{applied.session.slice()}) catch unreachable;
        t.message = .ofBytes(t.input.task, false);
        t.outcome = .ofBytes(t.result, false);
        content_domain.lookupPair(r, &t.message, &t.outcome, &t.rows);
        return .{ .round = .outcome };
    }

    /// Fails the call with `result`, once `.outcome` looks its row up.
    fn fail(t: *StartAgent, r: *transition.Round(StartAgent), result: []const u8) transition.Next(StartAgent) {
        t.result = result;
        t.outcome = .ofBytes(result, false);
        content_domain.lookup(r, &t.outcome);
        return .{ .round = .outcome };
    }

    /// After `.outcome`: a started agent's task is admitted from the
    /// caller, then its skills are saved; a failed call is resolved.
    noinline fn settle(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        const applied = t.applied orelse {
            if (r.faults().content_import) return error.InjectedContentImportFailure;
            return t.resolve(r);
        };
        content_domain.foundPair(&t.rows, &t.message, &t.outcome);
        if (r.faults().content_import) return error.InjectedContentImportFailure;
        const task = t.input.task;
        const text_id = try content_domain.importBytes(r, &t.message, task);
        const digest = sentDigest("rui/core/start_agent/v1", &content_string.digest(task));
        t.answer = .{ .accepted = true, .revision = applied.revision, .created = true };
        t.admission_id = try admitFromSession(r, &t.facts.?.session, &applied.head, t.key, text_id, &digest, applied, &t.answer);
        t.later = .{ .skills = .{ .admission_id = t.admission_id, .bound = boundOf(t.input.captured) } };
        return t.saveSkills(r);
    }

    /// After `.skill`: the skill it looked up, then the next.
    noinline fn saveSkill(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        try t.later.skills.save(r, r.faults());
        return t.saveSkills(r);
    }

    /// A `.skill` round for the next bound skill, or the call's resolution
    /// once every one is saved.
    fn saveSkills(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        if (t.later.skills.lookupNext(r)) return .{ .round = .skill };
        return t.resolve(r);
    }

    /// Imports the result and resolves the call, then commits.
    fn resolve(t: *StartAgent, r: *transition.Round(StartAgent)) !transition.Next(StartAgent) {
        const outcome_id = try content_domain.importBytes(r, &t.outcome, t.result);
        try action_domain.queueResolution(r, t.input.binding, t.facts.?.session, if (t.applied != null) .succeeded else .failed, outcome_id);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// Commit before announcing the task's admission: in a batch, once
    /// the batch commits (`Store.admitted`).
    pub fn announced(t: *const StartAgent) ?store_core.Announcement {
        if (t.admission_id == 0) return null;
        const callback = t.input.committed orelse return null;
        return .{ .message = .{ .callback = callback, .admission = .{
            .session = &t.applied.?.head.ref,
            .admission_id = t.admission_id,
            .from_peer = true,
        } } };
    }

    pub fn committed(t: *const StartAgent) Result {
        return if (t.applied != null) .started else .failed;
    }
};

/// Applies a configure command in one transaction: creates a Session, or
/// updates one, or reloads its skills catalog, or saves why it refused.
/// A configuration that requires a model is refused when the Host does
/// not serve its Session's provider.
///
/// Round `.facts` reads the command's saved answer, the Session's saved
/// configuration and the content lookups its instructions and output
/// schema need (`configuration.prepareConfiguration`). A fresh
/// configuration validates and applies in their own rounds (`.model` to
/// `.loaded`, `configuration.validateStep`; `.creation` and `.catalog`,
/// `configuration.applyStep`): a creation reads whether each drawn
/// reference is taken after the replay check, so a replay draws none. A
/// skills reload reads the Session's catalog in `.skills`, then its bytes
/// one `.skills_window` each, appends a changed one in `.skills_append`
/// (`skills.Reloading`), and looks its result's row up in `.outcome`. A
/// refusal with a diagnostic looks its row up in `.failure`. The commit
/// round saves the Session, the command and its revision, and a creation
/// is announced once it commits.
pub const Configure = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{.always},
        .model = .{.branch},
        .saved_tools = .{.branch},
        .saved_loaded = .{.branch},
        .loaded_source = .{.branch},
        .loaded = .{.branch},
        .creation = .{.paged},
        .catalog = .{.branch},
        .skills = .{.branch},
        .skills_window = .{.raw},
        .skills_append = .{.branch},
        .outcome = .{.branch},
        .failure = .{.branch},
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// Each is the caller's, which outlives the transition.
    pub const Input = struct {
        io: std.Io,
        served: provider_route.Routes,
        tools: *const store_core.HostTools,
        command: *const content_custody.ConfigureCommand,
        preset: ?*const configuration_domain.PresetDecision,
        initial_skills: ?*const skills_domain.Initial,
        reload_capture: ?*const skills_domain.Capture,
        /// What a skills reload allocates from, in an arena this frees.
        allocator: std.mem.Allocator,
        committed: ?Store.CreationCommitted,
        /// Where the answer goes, in the caller's frame: a step's result
        /// stays one word wide.
        reply: *configuration_domain.ConfigureReply,
    };
    pub const Result = void;
    /// Running out of memory, the caller's for a reload or the engine's,
    /// rolls the write back cleanly and is the caller's to answer.
    pub const Ordinary = error{OutOfMemory};
    pub const Guards = error{SessionUpdateFailed};
    pub const Declined = error{};

    input: Input,
    /// The configure reads, leased from the Store's scratch, which also
    /// hold the command's digest and answer.
    reads: *configuration_domain.ConfigurationReads = undefined,
    /// The refusal the commit saves, if it saves one.
    rejection: ?configuration_admission.Rejection = null,
    /// A skills reload's result, once reloaded.
    reloaded: ?skills_domain.Result = null,
    /// The reload result's row.
    outcome: content_domain.Import = undefined,
    /// A reload's scratch, from the caller's allocator; `deinit` frees it.
    memory: ?std.heap.ArenaAllocator = null,
    /// A creation's parent refusal's diagnostic, which its content write
    /// reads in place.
    parent_text: [256]u8 = undefined,
    /// What the rounds after the decision keep, as one path runs them: the
    /// saved tool selection validation reads, a refusal's diagnostic, or
    /// the reload.
    later: union {
        saved: tool_set.SavedSelection,
        failure: skills_domain.ImportingFailure,
        reload: skills_domain.Reloading,
    } = undefined,

    pub fn step(t: *Configure, r: *transition.Round(Configure), ran: ?rounds.At) !transition.Next(Configure) {
        const at = ran orelse return t.start(r);
        switch (at) {
            .facts => return t.decide(r),
            .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => return t.validate(r, switch (at) {
                inline .model, .saved_tools, .saved_loaded, .loaded_source, .loaded => |tag| @field(configuration_domain.ValidationRound, @tagName(tag)),
                else => unreachable,
            }),
            .creation => return t.apply(r, .creation),
            .catalog => return t.apply(r, .catalog),
            .skills => return t.reload(r, .latest),
            .skills_window => return t.reload(r, .window),
            .skills_append => return t.reload(r, .append),
            .outcome => return t.settleReload(r),
            .failure => return t.rejectDiagnosed(r),
        }
    }

    // The steps that run a round's work are noinline, so none sits under
    // another on the engine thread's chain.
    noinline fn start(t: *Configure, r: *transition.Round(Configure)) transition.Next(Configure) {
        const command = t.input.command;
        // Over 4.6 KB, so held where the Store owns it.
        t.reads = r.configurationReads();
        t.reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
        lookupCommand(r, command.key.slice(), &t.reads.saved_command);
        configuration_domain.prepareConfiguration(r, t.input.tools.host_tool_set, command.session.slice(), &command.configuration, t.reads);
        return .{ .round = .facts };
    }

    /// After `.facts`: a replay answers what was saved; a fresh command is
    /// refused, reloads skills or validates its configuration.
    noinline fn decide(t: *Configure, r: *transition.Round(Configure)) !transition.Next(Configure) {
        const command = t.input.command;
        const reads = t.reads;
        const saved = &reads.saved_command;
        configuration_domain.configureDigest(command, t.input.preset, saved, &reads.command_digest);
        switch (try classify(configuration_admission.Rejection, saved, .configure, command.session.slice(), &reads.command_digest)) {
            .fresh => {},
            .conflict => return t.done(.conflict),
            .accepted => |existing| return t.done(.{ .accepted = .{
                .replayed = true,
                .revision = existing.revision,
                .created = existing.created,
                .skills = if (command.reload_skills) (if (existing.code.eql("skills_reloaded")) .reloaded else if (existing.code.eql("skills_unchanged")) .unchanged else return error.CorruptStore) else null,
                .session = existing.target,
            } }),
            .rejected => |code| return t.done(.{ .rejected = .{ .replayed = true, .code = code } }),
        }
        if (t.input.preset) |decision| if (decision.rejection) |code| switch (code) {
            inline else => |tag| return t.refuse(r, @field(configuration_admission.Rejection, @tagName(tag)), null),
        };
        if (command.require_model and !configuration_domain.servesProviderOf(t.input.served, &command.configuration, if (reads.found.get()) reads.next.provider else if (reads.inherits_parent and reads.parent_found.get()) reads.inherited.provider else null))
            return t.refuse(r, .model_capability_unavailable, null);
        if (command.reload_skills) return t.startReload(r);
        t.later = .{ .saved = undefined };
        return t.validate(r, null);
    }

    /// Answers `reply` without writing.
    fn done(t: *Configure, reply: configuration_domain.ConfigureReply) transition.Next(Configure) {
        t.input.reply.* = reply;
        return .{ .done = {} };
    }

    /// What the configuration steps read besides its rows.
    fn request(t: *Configure) configuration_domain.Request {
        return .{
            .io = t.input.io,
            .tools = t.input.tools,
            .served = t.input.served,
            .session = t.input.command.session.slice(),
            .configuration = &t.input.command.configuration,
            .initial_skills = t.input.initial_skills,
            .saved = &t.later.saved,
        };
    }

    /// Validation refuses the configuration or readies it for application.
    noinline fn validate(t: *Configure, r: *transition.Round(Configure), ran: ?configuration_domain.ValidationRound) !transition.Next(Configure) {
        return switch (try configuration_domain.validateStep(r, &t.request(), t.reads, ran)) {
            .round => |round| .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .rejected => |code| t.refuse(r, code, null),
            .ready => t.apply(r, null),
        };
    }

    /// Applies the valid configuration, then saves the command and its
    /// revision.
    noinline fn apply(t: *Configure, r: *transition.Round(Configure), ran: ?configuration_domain.ApplyRound) !transition.Next(Configure) {
        const applied = switch (try configuration_domain.applyStep(r, &t.request(), r.faults(), t.reads, ran)) {
            .round => |round| return .{ .round = switch (round) {
                inline else => |tag| @field(rounds.At, @tagName(tag)),
            } },
            .accepted => |value| value,
        };
        const command = t.input.command;
        const reads = t.reads;
        reads.command_answer = .{ .accepted = true, .revision = applied.revision, .created = command.session.len == 0 };
        try configuration_domain.queueConfiguredCommand(r, applied, command.key.slice(), .configure, &reads.command_digest, applied.instructions_id, applied.output_schema_id, &reads.command_answer);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// Native reload has its own atomic result and catalog settlement:
    /// after replay, a reload names an existing Session and nothing else,
    /// and carries a catalog the Host captured.
    noinline fn startReload(t: *Configure, r: *transition.Round(Configure)) !transition.Next(Configure) {
        const command = t.input.command;
        const reads = t.reads;
        if (configuration_domain.targetRejection(command.session.slice())) |code| return t.refuse(r, code, null);
        if (command.session.len == 0 or !reads.found.get()) return t.refuse(r, .unknown_session, null);
        var invalid = command.preset != null or command.require_model;
        inline for (@typeInfo(content_custody.Configuration).@"struct".field_names) |field| {
            if (@field(command.configuration, field).state != .omitted) invalid = true;
        }
        if (invalid) return t.refuse(r, .incomplete_initial_configuration, null);
        const captured = t.input.reload_capture orelse return t.refuse(r, .skills_unavailable, null);
        switch (captured.*) {
            .failed => |failure| return t.refuse(r, failure.configurationRejection(), failure.bytes),
            .invocation => return t.refuse(r, .skills_unavailable, null),
            .reload => |candidate| {
                t.memory = .init(t.input.allocator);
                const head: rsql.SessionHead = .{ .ref = command.session.slice()[0..session_id.bytes].*, .workspace_key = .of(reads.next.workspace_key), .next_position = .of(reads.next.next_position) };
                t.later = .{ .reload = .init(head, candidate, t.memory.?.allocator()) };
                return t.reload(r, null);
            },
        }
    }

    /// The reload's next round; once reloaded, its result's lookup.
    noinline fn reload(t: *Configure, r: *transition.Round(Configure), ran: ?skills_domain.ReloadRound) !transition.Next(Configure) {
        const result = switch (try t.later.reload.step(r, r.faults(), ran)) {
            .round => |round| return .{ .round = switch (round) {
                .latest => .skills,
                .window => .skills_window,
                .append => .skills_append,
            } },
            .reloaded => |value| value,
        };
        t.reloaded = result;
        t.outcome = .ofBytes(result.bytes, false);
        content_domain.lookup(r, &t.outcome);
        return .{ .round = .outcome };
    }

    /// After `.outcome`: saves the reload's result and command.
    noinline fn settleReload(t: *Configure, r: *transition.Round(Configure)) !transition.Next(Configure) {
        const command = t.input.command;
        const reads = t.reads;
        const result = t.reloaded.?;
        const outcome_id = try content_domain.importBytes(r, &t.outcome, result.bytes);
        const status = result.reload_status orelse return error.CorruptStore;
        reads.command_answer = .{ .accepted = true, .revision = reads.next.revision };
        try reads.command_answer.code.set(if (status == .unchanged) "skills_unchanged" else "skills_reloaded");
        try queueCommand(r, command.key.slice(), .configure, command.session.slice(), &reads.command_digest, outcome_id, null, &reads.command_answer);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// A refusal; one with a diagnostic, its own or a creation's parent's,
    /// looks its row up in `.failure`.
    fn refuse(t: *Configure, r: *transition.Round(Configure), code: configuration_admission.Rejection, diagnostic: ?[]const u8) !transition.Next(Configure) {
        t.rejection = code;
        const bytes = diagnostic orelse if (t.reads.parent_failure) |parent| parent.text(&t.parent_text, "created") else return t.reject(r, null);
        t.later = .{ .failure = .{ .bytes = bytes } };
        t.later.failure.lookup(r);
        return .{ .round = .failure };
    }

    /// After `.failure`: the refusal, with its diagnostic's row.
    noinline fn rejectDiagnosed(t: *Configure, r: *transition.Round(Configure)) !transition.Next(Configure) {
        return t.reject(r, try t.later.failure.import(r, r.faults()));
    }

    /// Saves the refused command.
    fn reject(t: *Configure, r: *transition.Round(Configure), outcome_id: ?u64) !transition.Next(Configure) {
        const command = t.input.command;
        const reads = t.reads;
        reads.command_answer = .{ .accepted = false };
        try reads.command_answer.code.set(@tagName(t.rejection.?));
        try queueCommand(r, command.key.slice(), .configure, command.session.slice(), &reads.command_digest, outcome_id, null, &reads.command_answer);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    /// Commit before announcing a creation: in a batch, once the batch
    /// commits (`Store.created`).
    pub fn announced(t: *const Configure) ?store_core.Announcement {
        if (t.rejection != null or t.reloaded != null or t.input.command.session.len != 0) return null;
        const callback = t.input.committed orelse return null;
        return .{ .creation = .{ .callback = callback, .session = t.reads.applied.session.slice() } };
    }

    pub fn committed(t: *const Configure) Result {
        const command = t.input.command;
        t.input.reply.* = if (t.rejection) |code|
            .{ .rejected = .{ .replayed = false, .code = code } }
        else if (t.reloaded) |result|
            .{ .accepted = .{ .replayed = false, .revision = t.reads.next.revision, .created = false, .session = command.session, .skills = result.reload_status } }
        else
            .{ .accepted = .{ .replayed = false, .revision = t.reads.applied.revision, .created = command.session.len == 0, .session = t.reads.applied.session } };
    }

    pub fn deinit(t: *Configure) void {
        const memory = if (t.memory) |*value| value else return;
        t.later.reload.deinit();
        memory.deinit();
    }
};

/// Resolves a core tool call and lets its Turn continue in one transaction.
/// A call whose Turn a stop selected is left to the stop. Round `.facts`
/// reads the call's Action and its result's content row; the commit round
/// resolves it.
pub const ResolveCoreCall = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// `result` is the caller's, which outlives the transition.
    pub const Input = struct { binding: action_domain.ActionAttemptBinding, code: action_domain.ActionResolutionCode, result: []const u8 };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.action_attempt;
    pub const Guards = store_core.Ordinary.action_attempt;
    pub const Declined = error{};

    input: Input,
    facts: action_domain.core_facts.Result = undefined,
    outcome: content_domain.Import = undefined,

    pub fn step(t: *ResolveCoreCall, r: *transition.Round(ResolveCoreCall), ran: ?rounds.At) !transition.Next(ResolveCoreCall) {
        const binding = t.input.binding;
        if (ran == null) {
            const names: action_domain.CoreNames = .of();
            r.read(action_domain.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.facts);
            t.outcome = .ofBytes(t.input.result, false);
            content_domain.lookup(r, &t.outcome);
            return .{ .round = .facts };
        }
        const found = t.facts orelse return error.StaleActionAttemptBinding;
        if (found.stopped) return .{ .done = false };
        if (r.faults().content_import) return error.InjectedContentImportFailure;
        const outcome_id = try content_domain.importBytes(r, &t.outcome, t.input.result);
        try action_domain.queueResolution(r, binding, found.session, t.input.code, outcome_id);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const ResolveCoreCall) Result {
        return true;
    }
};

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
        owed_cause: ?Bounded(session_id.bytes),
        owed_position: ?u64,

        /// Whether `key` is the key of the stop this Session owes now.
        fn owedUnder(row: *const @This(), key: []const u8) bool {
            const cause = row.owed_cause orelse return false;
            var buffer: [idempotency_key.max_bytes]u8 = undefined;
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
    .sql = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at,parent_caused) VALUES(?1,@session(?2),?3,?4,?5,@now,?6)",
    .Args = struct { key: []const u8, session: rsql.SessionHead, selected_turn_id: ?u64, admission_cutoff: u64, position: u64, parent_caused: bool },
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

/// A Session stop, the stop an attached child owes (D38), or an archive's
/// stop. Round `.facts` reads the saved answer, the Session with its
/// admission cutoff, and its open Turn with its Actions' counts. A replay
/// reads the saved selection and the Operation it interrupted in
/// `.replay`, and ends.
///
/// Otherwise the writes are queued in this order: the command, the stop,
/// the interruption of a running Operation, the cancelled Actions and the
/// Turn's close (unless an attempted Action keeps it open). When Actions
/// are cancelled, the cancellation text's row and the first page of up to
/// `cancel_chunk` Actions are read in `.cancel` (they depend on the Turn),
/// which also runs the command, stop and interruption writes queued
/// before it. Each further page is one more `.page` round, which runs the
/// previous page's write (the first one with the cancellation text's
/// insert, when the text is new). The last page's write and the Turn's
/// close run in the commit round, with the position advance. With no
/// Actions to cancel, every write runs at commit.
///
/// A stop's own interruption finding the Operation changed fails it, as
/// the stop's selection changing would.
pub const StopSession = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .replay = .{.branch}, .cancel = .{.branch}, .page = .{.paged} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Result = SessionStopReply;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ InterruptionTargetChanged, StopSelectionChanged };
    pub const Declined = error{};

    /// The stop a command asks for. Its key and Session are the caller's,
    /// which outlive the transition.
    pub const Input = struct {
        key: []const u8,
        session: []const u8,
        digest: [32]u8,
        /// An owed stop runs only while its obligation stands: a stop
        /// under another key, or a newer obligation, settled or replaced
        /// it. Clients cannot use `rui.core/` keys
        /// (`idempotency_key.reserved_prefix`), so the key is free while
        /// the obligation stands; an owed stop whose key is not the one
        /// owed now runs nothing and answers conflict.
        owed: bool = false,
        /// It also archives the Session.
        archive: bool = false,

        pub fn ofStop(command: *const command_input.SessionStopCommand, owed: bool) Input {
            return .{ .key = command.key.slice(), .session = command.session.slice(), .digest = command.semanticDigest(), .owed = owed };
        }

        pub fn ofArchive(command: *const command_input.SessionArchiveCommand) Input {
            return .{ .key = command.key.slice(), .session = command.session.slice(), .digest = command.semanticDigest(), .archive = true };
        }

        fn kind(input: *const Input) cli_value.CommandKind {
            return if (input.archive) .session_archive else .session_stop;
        }
    };

    input: Input,
    saved: saved_command.Result = undefined,
    target: stop_target.Result = null,
    turn: stop_turn.Result = null,
    archive_existing: archive_record.Result = null,
    archive_endings: archive_ending_count.Row = .{ .count = 0 },
    selection: stop_selection.Result = undefined,
    interrupted: stop_interrupted.Result = undefined,
    /// The command's write reads its code in place.
    answer: StoredAnswer = undefined,
    /// The cancellation text's identity: its queued row reads the digest
    /// in place until commit.
    cancellation: content_domain.Import = unattempted_stop_content,
    chunk: CancelChunk = .{},
    cancellation_id: u64 = 0,
    cancelled: u64 = 0,
    reply: SessionStopReply = undefined,
    trace: ?store_core.ControlTrace = null,

    pub fn step(t: *StopSession, r: *transition.Round(StopSession), ran: ?rounds.At) !transition.Next(StopSession) {
        const at = ran orelse {
            const session = t.input.session;
            lookupCommand(r, t.input.key, &t.saved);
            if (session_id.valid(session)) {
                r.read(stop_target, .{ .session = session }, &t.target);
                r.read(stop_turn, .{ .session = session }, &t.turn);
                if (t.input.archive) {
                    r.read(archive_record, .{ .session = session }, &t.archive_existing);
                    r.read(archive_ending_count, .{ .parent = session }, &t.archive_endings);
                }
            }
            return .{ .round = .facts };
        };
        switch (at) {
            .facts => return t.decide(r),
            .replay => {
                const observed = stopObservation(&t.selection);
                return .{ .done = .{ .accepted = .{
                    .replayed = true,
                    .selection = observed.selection,
                    .completion = observed.completion,
                    .interrupted_operation_id = if (t.interrupted) |row| row.operation_id.get() else null,
                } } };
            },
            .cancel => {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                t.cancellation_id = try content_domain.importBytes(r, &t.cancellation, unattempted_stop_text);
                return t.cancelPage(r);
            },
            .page => return t.cancelPage(r),
        }
    }

    fn decide(t: *StopSession, r: *transition.Round(StopSession)) !transition.Next(StopSession) {
        const key = t.input.key;
        const session = t.input.session;
        const kind = t.input.kind();
        if (t.input.owed and !(t.target != null and t.target.?.owedUnder(key) and t.saved == null)) return .{ .done = .conflict };
        switch (try classify(mutation_answer.SessionStopRejection, &t.saved, kind, session, &t.input.digest)) {
            .fresh => {},
            .conflict => return .{ .done = .conflict },
            .accepted => {
                r.read(stop_selection, .{ .key = key }, &t.selection);
                r.read(stop_interrupted, .{ .key = key }, &t.interrupted);
                return .{ .round = .replay };
            },
            .rejected => |code| return .{ .done = .{ .rejected = .{ .replayed = true, .code = code } } },
        }

        const rejection: ?mutation_answer.SessionStopRejection = if (!session_id.valid(session)) .invalid_session_reference else if (t.target == null) .unknown_session else null;
        if (rejection) |code| {
            t.answer = .{ .accepted = false };
            try t.answer.code.set(@tagName(code));
            try queueCommand(r, key, kind, session, &t.input.digest, null, null, &t.answer);
            if (r.faults().before_commit) return error.InjectedCommitFailure;
            t.reply = .{ .rejected = .{ .replayed = false, .code = code } };
            return .commit;
        }

        const found = &t.target.?;
        const head = &found.session;
        const positions = try r.positions(head.*);
        t.answer = .{ .accepted = true };
        try queueCommand(r, key, kind, session, &t.input.digest, null, null, &t.answer);
        const selection = SessionStopSelection{ .selected_turn_id = if (t.turn) |open| open.turn_id.get() else null, .admission_cutoff = found.admission_cutoff };
        const stop_position = try positions.take(1);
        r.write(insert_stop, .{ .key = key, .session = head.*, .selected_turn_id = selection.selected_turn_id, .admission_cutoff = selection.admission_cutoff, .position = stop_position, .parent_caused = found.owed_cause != null });
        if (t.input.archive) {
            r.write(insert_archive_command, .{ .key = key, .archived = true });
            if (t.archive_existing != null) r.write(update_archive, .{ .session = head.*, .key = key }) else r.write(insert_archive, .{ .session = head.*, .key = key });
            if (t.archive_endings.count != 0) r.writeCount(suppress_archive_endings, .{ .parent = &head.ref }, t.archive_endings.count);
        }
        // A stop settles any stop this Session owed, and its attached children
        // now owe theirs (D38).
        if (found.owed_cause != null) r.write(settle_owed_stop, .{ .session = &head.ref });
        turn_domain.queueOwedStops(r, &head.ref, stop_position, found.unowed_children);
        t.trace = r.faults().control_trace;
        t.reply = .{ .accepted = .{ .replayed = false, .selection = selection, .completion = .completed, .interrupted_operation_id = null } };
        if (t.turn) |open| {
            if (open.running) {
                interrupt_operation.queue(r, .{ .operation_id = open.operation_id.get(), .command_key = key, .session = head.* });
                t.reply.accepted.interrupted_operation_id = open.operation_id.get();
            }
            if (open.cancellable != 0) {
                content_domain.lookup(r, &t.cancellation);
                r.readEach(cancellable_actions, .{ .operation_id = open.operation_id.get(), .after = 0 }, cancel_chunk, &t.chunk);
                return .{ .round = .cancel };
            }
        }
        return t.finish(r);
    }

    /// After a round that read a page of the open Turn's cancellable
    /// Actions: cancels them in call order, each at the Session's next
    /// position, with the stop's cancellation text. A statement binds when
    /// it is queued, so `cancel_actions[n - 1]` runs once a round: the next
    /// page reads in the round that runs this page's write. The count says
    /// when the last page was read, so a multiple of `cancel_chunk` costs no
    /// empty round.
    fn cancelPage(t: *StopSession, r: *transition.Round(StopSession)) !transition.Next(StopSession) {
        const open = t.turn.?;
        const chunk = &t.chunk;
        if (chunk.len != 0) {
            switch (chunk.len) {
                inline 1...cancel_chunk => |n| {
                    @setEvalBranchQuota(100_000);
                    var args: CancelArgs(n) = undefined;
                    args.content_id = t.cancellation_id;
                    args.first_position = try (try r.positions(t.target.?.session)).take(n);
                    args.session = t.target.?.session;
                    inline for (0..n) |k| @field(args, cancelField(k)) = chunk.action_ids[k];
                    r.write(cancel_actions[n - 1], args);
                },
                else => unreachable,
            }
            t.cancelled += chunk.len;
            if (t.cancelled < open.cancellable and chunk.len == cancel_chunk) {
                chunk.len = 0;
                r.readEach(cancellable_actions, .{ .operation_id = open.operation_id.get(), .after = chunk.next }, cancel_chunk, chunk);
                return .{ .round = .page };
            }
        }
        // Main checked that the cancelling UPDATE changed as many rows as it
        // counted.
        if (t.cancelled != open.cancellable) return error.StopSelectionChanged;
        return t.finish(r);
    }

    /// The stop now selects the Turn and has resolved every Action never
    /// attempted, so the Turn is ready (`turn.stopped_turn`) unless an
    /// attempted Action is unresolved; then the commit.
    fn finish(t: *StopSession, r: *transition.Round(StopSession)) !transition.Next(StopSession) {
        if (t.turn) |open| {
            if (open.in_flight) t.reply.accepted.completion = .pending else try turn_domain.queueClose(r, try r.positions(t.target.?.session), open.turn_id.get(), .cancelled);
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const StopSession) Result {
        if (t.reply == .accepted) if (t.trace) |trace| trace.mark(.durable_acceptance);
        return t.reply;
    }
};

/// All unattempted runners use the same bytes today. Prove that before
/// sharing one content import and one cancellation batch, without another
/// read or a runner column. A runner that changes this must split the batch.
const unattempted_stop_text = blk: {
    const runners = @import("../../tool_record.zig").Runner;
    const text = runners.bash.beforeAdmissionStopText();
    for (.{ runners.bash, runners.mcp, runners.core }) |runner| {
        if (!std.mem.eql(u8, text, runner.beforeAdmissionStopText()))
            @compileError("unattempted cancellation batch requires one runner text");
    }
    break :blk text;
};

const unattempted_stop_content: content_domain.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(unattempted_stop_text, false);
};

const archive_ending_count = rsql.Read(.{
    .sql = "SELECT count(*) AS count FROM session_forward ending WHERE ending.target_ref=?1 AND ending.message_delivered=0 AND ending.suppress_message=0",
    .Args = struct { parent: []const u8 },
    .Row = struct { count: u64 },
    .cardinality = .one,
});

const suppress_archive_endings = rsql.Write(.{
    .sql = "UPDATE session_forward SET suppress_message=1 WHERE message_delivered=0 AND suppress_message=0 AND target_ref=?1",
    .Args = struct { parent: []const u8 },
    .expect = .{ .counted = .{ .otherwise = error.StopSelectionChanged } },
});

pub const archive_state_sql =
    "CASE WHEN EXISTS(SELECT 1 FROM session_archive ar JOIN session_stop astop ON astop.command_key=ar.command_key " ++
    "JOIN turn aturn ON aturn.turn_id=astop.selected_turn_id WHERE ar.session_ref=session.session_ref AND aturn.outcome_code IS NULL) THEN 'archiving' " ++
    "WHEN EXISTS(SELECT 1 FROM session_archive ar WHERE ar.session_ref=session.session_ref AND ar.command_key IS NOT NULL) THEN 'archived' ELSE 'active' END";

const insert_archive_command = rsql.Write(.{
    .sql = "INSERT INTO session_archive_command(command_key,archived) VALUES(?1,?2)",
    .Args = struct { key: []const u8, archived: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_archive = rsql.Write(.{
    .sql = "INSERT INTO session_archive(session_ref,command_key) VALUES(@session(?1),?2)",
    .Args = struct { session: rsql.SessionHead, key: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const clear_archive = rsql.Write(.{
    .sql = "UPDATE session_archive SET command_key=NULL WHERE session_ref=@session(?1) AND command_key IS NOT NULL",
    .Args = struct { session: rsql.SessionHead },
    .expect = .{ .at_most = 1 },
});

const archive_record = rsql.Read(.{
    .sql = "SELECT 1 AS present FROM session_archive WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { present: bool },
    .cardinality = .optional,
});

const update_archive = rsql.Write(.{
    .sql = "UPDATE session_archive SET command_key=?2 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, key: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const archive_request = rsql.Read(.{
    .sql = "SELECT archived FROM session_archive_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { archived: bool },
    .cardinality = .one,
});

/// Archives a Session through its stop (`StopSession`), or restores it.
/// A restore's round reads the saved answer and the Session; its commit
/// saves the command, clears the archive and advances the Session's
/// position.
pub const ArchiveSession = struct {
    pub const rounds = StopSession.rounds;
    pub const round_budget = StopSession.round_budget;
    pub const commit = StopSession.commit;
    pub const begin = StopSession.begin;
    pub const Input = struct { command: *const command_input.SessionArchiveCommand };
    pub const Result = SessionArchiveReply;
    pub const Ordinary = StopSession.Ordinary;
    pub const Guards = StopSession.Guards;
    pub const Declined = error{};

    input: Input,
    way: union(enum) { stop: StopSession, restore: Restore } = undefined,

    pub fn step(t: *ArchiveSession, r: *transition.Round(ArchiveSession), ran: ?rounds.At) !transition.Next(ArchiveSession) {
        const command = t.input.command;
        if (ran == null) t.way = if (command.archived) .{ .stop = .{ .input = .ofArchive(command) } } else .{ .restore = .{ .command = command } };
        switch (t.way) {
            .stop => |*stop| return switch (try stop.step(r, ran)) {
                .round => |at| .{ .round = at },
                .commit => .commit,
                .done => |reply| .{ .done = archiveReply(reply) },
            },
            .restore => |*restore| return restore.step(r, ran),
        }
    }

    pub fn committed(t: *const ArchiveSession) Result {
        return switch (t.way) {
            .stop => |*stop| archiveReply(stop.committed()),
            .restore => |*restore| restore.committed(),
        };
    }

    fn archiveReply(reply: SessionStopReply) SessionArchiveReply {
        return switch (reply) {
            .accepted => |accepted| .{ .accepted = .{
                .replayed = accepted.replayed,
                .archived = true,
                .completion = accepted.completion,
                .interrupted_operation_id = accepted.interrupted_operation_id,
            } },
            .rejected => |rejected| .{ .rejected = .{ .replayed = rejected.replayed, .code = switch (rejected.code) {
                .invalid_session_reference => .invalid_session_reference,
                .unknown_session => .unknown_session,
            } } },
            .conflict => .conflict,
            .infrastructure_failure => .infrastructure_failure,
        };
    }

    const Restore = struct {
        command: *const command_input.SessionArchiveCommand,
        digest: [32]u8 = undefined,
        saved: saved_command.Result = undefined,
        target: target_session.Result = null,
        /// The command's write reads its code in place.
        answer: StoredAnswer = undefined,
        rejection: ?mutation_answer.SessionArchiveRejection = null,

        fn step(t: *Restore, r: *transition.Round(ArchiveSession), ran: ?rounds.At) !transition.Next(ArchiveSession) {
            const key = t.command.key.slice();
            const session = t.command.session.slice();
            if (ran == null) {
                t.digest = t.command.semanticDigest();
                lookupCommand(r, key, &t.saved);
                readTarget(r, session, &t.target);
                return .{ .round = .facts };
            }
            switch (try classify(mutation_answer.SessionArchiveRejection, &t.saved, .session_archive, session, &t.digest)) {
                .fresh => {},
                .conflict => return .{ .done = .conflict },
                .accepted => return .{ .done = .{ .accepted = .{ .replayed = true, .archived = false, .completion = .completed } } },
                .rejected => |code| return .{ .done = .{ .rejected = .{ .replayed = true, .code = code } } },
            }
            t.rejection = if (!session_id.valid(session)) .invalid_session_reference else if (t.target == null) .unknown_session else if (t.target.?.archive_state == .archiving) .archive_pending else null;
            t.answer = .{ .accepted = t.rejection == null };
            if (t.rejection) |code| try t.answer.code.set(@tagName(code));
            try queueCommand(r, key, .session_archive, session, &t.digest, null, null, &t.answer);
            if (t.rejection == null) {
                r.write(insert_archive_command, .{ .key = key, .archived = false });
                const head = t.target.?.session;
                r.write(clear_archive, .{ .session = head });
                _ = try (try r.positions(head)).take(1);
            }
            if (r.faults().before_commit) return error.InjectedCommitFailure;
            return .commit;
        }

        fn committed(t: *const Restore) SessionArchiveReply {
            return if (t.rejection) |code| .{ .rejected = .{ .replayed = false, .code = code } } else .{ .accepted = .{ .replayed = false, .archived = false, .completion = .completed } };
        }
    };
};

/// A Session a command names, as a round reads it: its head, and the
/// provider a Message's model check needs.
const target_session = rsql.Read(.{
    .sql = "SELECT session_ref,workspace_key,next_position,provider," ++ archive_state_sql ++ " AS archive_state FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session: rsql.SessionHead, provider: provider_name.Provider, archive_state: session_archive.State },
    .cardinality = .optional,
});

/// Queues reading the Session `session` names when it is a valid
/// reference; otherwise `destination` is null at once.
fn readTarget(a: anytype, session: []const u8, destination: *target_session.Result) void {
    destination.* = null;
    if (session_id.valid(session)) a.read(target_session, .{ .session = session }, destination);
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
    .Row = struct { turn_id: rsql.Positive, session_ref: Bounded(session_id.max_reference_bytes), unresolved: bool, current: bool },
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
    .Row = struct { session_ref: Bounded(session_id.max_reference_bytes), turn_id: Bounded(20), operation_id: Bounded(20) },
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
const interrupt_operation = model_attempt.Write(.{
    .end = .resolution,
    .set = "retry_due_at_ms=NULL," ++ store_schema.resolutionIs("resolution_code", .interrupted) ++ ",interrupted_by_command_key=?2",
    .where = "operation_id=?1 AND session_ref=@session(?3) AND resolution_code IS NULL",
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
    command: *const command_input.ModelInterruptionCommand,
    target: target_session.Result,
    operation: interruption_operation.Result,
) ?mutation_answer.ModelInterruptionRejection {
    if (!session_id.valid(command.session.slice())) return .invalid_session_reference;
    if (!validId(command.turn_id) or !validId(command.operation_id)) return .invalid_target;
    if (target == null) return .unknown_session;
    const found = operation orelse return .unknown_operation;
    if (found.turn_id.get() != command.turn_id or !found.session_ref.eql(command.session.slice())) return .target_mismatch;
    if (!found.unresolved) return .operation_resolved;
    if (!found.current) return .target_mismatch;
    return null;
}

/// Round `.facts` reads the saved answer, the Session, the Operation with
/// its Turn, and whether a pending Message keeps the Turn open. A replay
/// reads the saved target in `.replay` and ends. The decision is
/// `interruptionRejection`; the commit round saves the command and its
/// target, interrupts the Operation and closes the Turn when nothing is
/// pending.
pub const InterruptModel = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .replay = .{.branch} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { command: *const command_input.ModelInterruptionCommand };
    pub const Result = ModelInterruptionReply;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{InterruptionTargetChanged};
    pub const Declined = error{};

    input: Input,
    digest: [32]u8 = undefined,
    saved: saved_command.Result = undefined,
    target: target_session.Result = null,
    operation: interruption_operation.Result = null,
    pending: applicable_pending.Result = .{ .pending = false },
    saved_target: interruption_target.Result = undefined,
    /// The command's writes read these in place.
    answer: StoredAnswer = undefined,
    turn_text: [20]u8 = undefined,
    operation_text: [20]u8 = undefined,
    reply: ModelInterruptionReply = undefined,
    trace: ?store_core.ControlTrace = null,

    pub fn step(t: *InterruptModel, r: *transition.Round(InterruptModel), ran: ?rounds.At) !transition.Next(InterruptModel) {
        const command = t.input.command;
        const session = command.session.slice();
        const at = ran orelse {
            t.digest = command.semanticDigest();
            lookupCommand(r, command.key.slice(), &t.saved);
            if (validId(command.turn_id) and validId(command.operation_id)) {
                readTarget(r, session, &t.target);
                if (session_id.valid(session)) {
                    r.read(interruption_operation, .{ .operation_id = command.operation_id }, &t.operation);
                    r.read(applicable_pending, .{ .session = session }, &t.pending);
                }
            }
            return .{ .round = .facts };
        };
        if (at == .replay) {
            const named = try modelInterruptionTarget(&t.saved_target);
            if (!named.session.eql(session) or named.turn_id != command.turn_id or named.operation_id != command.operation_id) return error.CorruptStore;
            return .{ .done = t.reply };
        }
        const replay = try classify(mutation_answer.ModelInterruptionRejection, &t.saved, .model_interruption, session, &t.digest);
        if (replay != .fresh) {
            t.reply = switch (replay) {
                .fresh => unreachable,
                .conflict => .conflict,
                .accepted => .{ .accepted = .{ .replayed = true } },
                .rejected => |code| .{ .rejected = .{ .replayed = true, .code = code } },
            };
            if (replay == .conflict) return .{ .done = t.reply };
            r.read(interruption_target, .{ .key = command.key.slice() }, &t.saved_target);
            return .{ .round = .replay };
        }

        const rejection = interruptionRejection(command, t.target, t.operation);
        t.answer = .{ .accepted = rejection == null };
        if (rejection) |code| try t.answer.code.set(@tagName(code));
        try queueCommand(r, command.key.slice(), .model_interruption, session, &t.digest, null, null, &t.answer);
        r.write(save_interruption, .{
            .key = command.key.slice(),
            .session = session,
            .turn_id = try std.fmt.bufPrint(&t.turn_text, "{d}", .{command.turn_id}),
            .operation_id = try std.fmt.bufPrint(&t.operation_text, "{d}", .{command.operation_id}),
        });
        if (rejection == null) {
            const head = t.target.?.session;
            interrupt_operation.queue(r, .{ .operation_id = command.operation_id, .command_key = command.key.slice(), .session = head });
            if (!t.pending.pending) try turn_domain.queueCloseOr(r, try r.positions(head), command.turn_id, .cancelled, error.InterruptionTargetChanged);
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        t.trace = r.faults().control_trace;
        t.reply = if (rejection) |code| .{ .rejected = .{ .replayed = false, .code = code } } else .{ .accepted = .{ .replayed = false } };
        return .commit;
    }

    pub fn committed(t: *const InterruptModel) Result {
        if (t.reply == .accepted) if (t.trace) |trace| trace.mark(.durable_acceptance);
        return t.reply;
    }
};

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
    .Args = struct { key: []const u8, action_id: []const u8, decision: mutation_answer.PermissionDecision },
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
    command: *const command_input.PermissionDecisionCommand,
    target: target_session.Result,
    action: decision_action.Result,
) ?mutation_answer.PermissionDecisionRejection {
    if (!session_id.valid(command.session.slice())) return .invalid_session_reference;
    if (!validId(command.action_id)) return .invalid_target;
    if (target == null) return .unknown_session;
    const found = action orelse return .unknown_action;
    if (!std.mem.eql(u8, &found.session.ref, command.session.slice()) and !found.forwarded) return .target_mismatch;
    if (found.authorized or !found.unresolved or !found.turn_open) return .action_not_pending;
    return null;
}

/// Round `.facts` reads the saved answer, the Session, the Action with its
/// Turn and, for a denial, its result text's row. The decision is
/// `decisionRejection`; the commit round saves the command and its target,
/// then authorizes or denies the Action.
pub const DecidePermission = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { command: *const command_input.PermissionDecisionCommand };
    pub const Result = PermissionDecisionReply;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    digest: [32]u8 = undefined,
    saved: saved_command.Result = undefined,
    target: target_session.Result = null,
    action: decision_action.Result = null,
    /// The denial's content row, which its import reads in place.
    content: content_domain.Import = denial,
    /// The command's writes read these in place.
    answer: StoredAnswer = undefined,
    action_text: [20]u8 = undefined,
    rejection: ?mutation_answer.PermissionDecisionRejection = null,
    trace: ?store_core.ControlTrace = null,

    pub fn step(t: *DecidePermission, r: *transition.Round(DecidePermission), ran: ?rounds.At) !transition.Next(DecidePermission) {
        const command = t.input.command;
        const session = command.session.slice();
        if (ran == null) {
            t.digest = command.semanticDigest();
            lookupCommand(r, command.key.slice(), &t.saved);
            if (validId(command.action_id)) {
                readTarget(r, session, &t.target);
                if (session_id.valid(session)) r.read(decision_action, .{ .action_id = command.action_id, .target = session }, &t.action);
            }
            if (command.decision == .deny) content_domain.lookup(r, &t.content);
            return .{ .round = .facts };
        }
        switch (try classify(mutation_answer.PermissionDecisionRejection, &t.saved, .permission_decision, session, &t.digest)) {
            .fresh => {},
            .conflict => return .{ .done = .conflict },
            .accepted => return .{ .done = .{ .accepted = .{ .replayed = true } } },
            .rejected => |code| return .{ .done = .{ .rejected = .{ .replayed = true, .code = code } } },
        }

        t.rejection = decisionRejection(command, t.target, t.action);
        t.answer = .{ .accepted = t.rejection == null };
        if (t.rejection) |code| try t.answer.code.set(@tagName(code));
        try queueCommand(r, command.key.slice(), .permission_decision, session, &t.digest, null, null, &t.answer);
        r.write(save_decision, .{ .key = command.key.slice(), .action_id = try std.fmt.bufPrint(&t.action_text, "{d}", .{command.action_id}), .decision = command.decision });
        if (t.rejection == null) {
            const found = t.action.?;
            const head = found.session;
            switch (command.decision) {
                .allow_once => r.write(allow_action, .{ .action_id = command.action_id, .session = head }),
                .deny => {
                    if (r.faults().content_import) return error.InjectedContentImportFailure;
                    const positions = try r.positions(head);
                    const content_id = try content_domain.importBytes(r, &t.content, denial_text);
                    r.write(deny_action, .{ .action_id = command.action_id, .content_id = content_id, .position = try positions.take(1), .session = head });
                    turn_domain.queueContinuation(r, found.turn_id.get(), head);
                },
            }
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        t.trace = r.faults().control_trace;
        return .commit;
    }

    pub fn committed(t: *const DecidePermission) Result {
        if (t.rejection) |code| return .{ .rejected = .{ .replayed = false, .code = code } };
        if (t.trace) |trace| trace.mark(.durable_acceptance);
        return .{ .accepted = .{ .replayed = false } };
    }
};

const ExistingCommand = struct {
    kind: cli_value.CommandKind,
    target: Bounded(session_id.max_reference_bytes),
    digest: [32]u8,
    accepted: bool,
    code: Bounded(outcome_code.max_bytes),
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
        target: Bounded(session_id.max_reference_bytes),
        input_digest: [32]u8,
        accepted: bool,
        code: Bounded(outcome_code.max_bytes),
        revision: u64,
        created: bool,
        primary_content_id: ?rsql.Positive,
    },
    .cardinality = .optional,
});

/// Queues reading the saved answer of the command `key`; `classify`
/// follows its round. noinline, like `queueCommand`, so each Held
/// body's frame stays its own whatever callers share the instance.
pub noinline fn lookupCommand(a: anytype, key: []const u8, destination: *saved_command.Result) void {
    a.read(saved_command, .{ .key = key }, destination);
}

/// Each command kind's stored code.
fn kindCode(kind: cli_value.CommandKind) u8 {
    return switch (kind) {
        .configure => 1,
        .message => 2,
        .session_stop => 3,
        .model_interruption => 4,
        .permission_decision => 5,
        .session_archive => 6,
    };
}

/// The answer a `lookupCommand` round found, or null.
fn savedAnswer(saved: *const saved_command.Result) error{CorruptStore}!?ExistingCommand {
    const row = if (saved.*) |*row| row else return null;
    return .{
        .kind = for (std.enums.values(cli_value.CommandKind)) |candidate| {
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
    kind: cli_value.CommandKind,
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
/// and `target`, must outlive the round; `digest` is copied. noinline:
/// its locals stay off configure's frame on the engine's deepest chain.
pub noinline fn queueCommand(
    a: anytype,
    key: []const u8,
    kind: cli_value.CommandKind,
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
        session_ref: Bounded(session_id.max_reference_bytes),
        content_id: rsql.Positive,
        admission_id: rsql.Positive,
        command_key: Bounded(128),
        turn_id: ?rsql.Positive,
        operation_id: ?rsql.Positive,
        attempt_ordinal: ?rsql.Positive,
        outcome_code: ?Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        excluding_stop: ?Bounded(128),
        input_length: u64,
        input_digest: [32]u8,
        answer_length: ?u64,
        answer_digest: ?[32]u8,
        created_at: rsql.Positive,
        admitted_at: rsql.Positive,
        has_recovery: bool,
    },
    .cardinality = .optional,
});

/// The Action and decision a permission decision saved.
const permission_target = rsql.Read(.{
    .sql = "SELECT action_id,decision FROM permission_decision_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { action_id: Bounded(20), decision: mutation_answer.PermissionDecision },
    .cardinality = .one,
});

/// Round 1 reads the saved command. Its kind picks what round 2 reads,
/// keyed on the command alone: a dependent round, one more network round
/// trip, run only for a kind that saved more than its answer. A queued or
/// processing Message's progress is its Session's work, which round 1
/// reads too while a Turn is active (`readMessageWork`).
pub fn observeCommand(a: anytype, key: []const u8, observation: *CommandObservation) !void {
    var saved: saved_command.Result = undefined;
    lookupCommand(a, key, &saved);
    // Most observed commands are Messages, so the command's round also
    // reads the Message it accepted: both are keyed by the command key.
    var message: message_observation.Result = undefined;
    a.read(message_observation, .{ .key = key }, &message);
    // A pending Message's progress is its Session's work, whose active
    // Turn is keyed by the command too.
    var work: report_domain.WorkRead = .{ .session = "" };
    work.queuePending(a, key);
    try store_access.runNamed(a, report_domain.pending_failures, error.StatementFailed);
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
            const row = message orelse return error.CorruptStore;
            const content_id = command.primary_content_id orelse return error.CorruptStore;
            if (!row.session_ref.eql(command.target.slice()) or row.content_id.get() != content_id) return error.CorruptStore;
            const queue = try messageQueue(&row);
            observation.kind.message = .{ .content = .{ .length = row.input_length, .digest = row.input_digest }, .queue = queue, .admitted_at = row.admitted_at.get() };
            if (row.has_recovery) try readRecovery(a, key, &observation.kind.message.?.recovery);
            switch (queue.state) {
                .queued, .processing => observation.kind.message.?.work = try readMessageWork(a, &work, command.target.slice(), row.created_at.get(), queue.state),
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
        .session_archive => {
            observation.kind = .{ .session_archive = null };
            if (!command.accepted) return;
            var request: archive_request.Row = undefined;
            a.read(archive_request, .{ .key = key }, &request);
            try a.run();
            var completion: mutation_answer.SessionStopCompletion = .completed;
            if (request.archived) {
                var selection: stop_selection.Row = undefined;
                a.read(stop_selection, .{ .key = key }, &selection);
                try a.run();
                completion = stopObservation(&selection).completion;
            }
            observation.kind.session_archive = .{ .archived = request.archived, .completion = completion };
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
            var code: Bounded(outcome_code.max_bytes) = .{};
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
/// Turn, or the work ahead of it in the queue. The observation's round
/// read an active Turn (`queuePending`); with none, the stop and queue
/// stages follow in their own rounds.
fn readMessageWork(a: *report_domain.ReadAccess, read: *report_domain.WorkRead, session_ref: []const u8, created_at: u64, state: AcceptedMessageQueue.State) !session_work.Work {
    read.session = session_ref;
    try read.advance();
    try report_domain.readWorks(a, read[0..1]);
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
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, call_ordinal: u64, resolved_at: rsql.Positive, description: ?Bounded(tool_presentation.max_description_bytes) },
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
    .compound = true,
    .sql = "SELECT t.outcome_code,t.outcome_content_id,EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
        "AND m.admission_id<=stopped.admission_cutoff) AS stopped,answer.byte_length AS answer_length,answer.digest AS answer_digest,answer.private AS outcome_private,0 AS direct " ++
        "FROM core_command command JOIN message_admission m ON m.command_key=command.command_key " ++
        "LEFT JOIN turn t ON t.turn_id=m.turn_id LEFT JOIN content answer ON answer.content_id=t.outcome_content_id " ++
        "WHERE command.command_key=?1 AND command.kind=2 AND command.accepted=1 UNION ALL " ++
        "SELECT NULL,command.primary_content_id,0,outcome.byte_length,outcome.digest,outcome.private,1 " ++
        "FROM core_command command LEFT JOIN content outcome ON outcome.content_id=command.primary_content_id " ++
        "WHERE command.command_key=?1 AND command.primary_content_id IS NOT NULL AND " ++
        "(command.accepted=0 OR (command.kind=1 AND command.code IN ('skills_reloaded','skills_unchanged')))",
    .Args = struct { key: []const u8 },
    .Row = struct {
        outcome_code: ?Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        stopped: bool,
        answer_length: ?u64,
        answer_digest: ?[32]u8,
        outcome_private: ?bool,
        direct: bool,
    },
    .cardinality = .optional,
});

/// One round: an ordinary command outcome, or the Message's eventual answer.
/// Captured skill refusals and idle reload acknowledgements are saved content;
/// retrieving them never rereads the filesystem or admits model work.
pub fn commandResult(a: anytype, key: []const u8) !ContentReference {
    var result: message_result.Result = null;
    a.read(message_result, .{ .key = key }, &result);
    // The Host's fence names this read, as on main.
    try store_access.runAs(a, error.ResultReadFailed);
    const row = result orelse return error.ResultNotFound;
    if (row.direct) {
        if (row.outcome_content_id == null or row.outcome_private != false) return error.CorruptStore;
        return .{ .length = row.answer_length orelse return error.CorruptStore, .digest = row.answer_digest orelse return error.CorruptStore };
    }
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
            var stop_key: Bounded(128) = .{};
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
