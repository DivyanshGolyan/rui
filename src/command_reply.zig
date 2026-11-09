//! The values the Store answers a command or read with, as the Host's
//! replies render them. They hold no Store state, so the replies' renderers
//! and their tests need no Store.
const std = @import("std");
const protocol = @import("protocol.zig");
const tool_presentation = @import("tool_presentation.zig");
const session_id = @import("session_id.zig");
const Bounded = @import("bounded.zig").Bounded;
const cli_value = @import("cli_value.zig");
const mutation_answer = @import("mutation_answer.zig");
const session_work = @import("session_work.zig");
const change_ring = @import("change_ring.zig");
const AttemptBinding = @import("attempt.zig").AttemptBinding;

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

pub const AcceptedConfiguration = struct {
    replayed: bool,
    revision: u64 = 0,
    created: bool = false,
    skills: ?mutation_answer.SkillsReloadStatus = null,
    session: Bounded(session_id.max_reference_bytes) = .{},
};

pub const RejectedConfiguration = struct {
    replayed: bool,
    code: protocol.ConfigurationRejection,
};

pub const ConfigureReply = union(enum) {
    accepted: AcceptedConfiguration,
    rejected: RejectedConfiguration,
    conflict,
    infrastructure_failure,
};

pub const AcceptedMessage = struct {
    replayed: bool,
    admission_id: u64,
    content: ContentReference,
    session: Bounded(session_id.max_reference_bytes),
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

pub const CommandObservation = struct {
    status: protocol.CommandObservationStatus,
    target: Bounded(session_id.max_reference_bytes) = .{},
    code: Bounded(protocol.max_code_bytes) = .{},
    kind: union(cli_value.CommandKind) {
        configure: struct { revision: u64 = 0, created: bool = false },
        message: ?MessageObservation,
        session_stop: ?SessionStopObservation,
        session_archive: ?mutation_answer.SessionArchiveObservation,
        model_interruption: ModelInterruptionTarget,
        permission_decision: struct { action_id: u64, decision: mutation_answer.PermissionDecision },
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
    completion: mutation_answer.SessionStopCompletion,
};

pub const ModelInterruptionTarget = struct {
    session: Bounded(session_id.max_reference_bytes),
    turn_id: u64,
    operation_id: u64,
};

pub const SessionStopReply = union(enum) {
    accepted: struct {
        replayed: bool,
        selection: SessionStopSelection,
        completion: mutation_answer.SessionStopCompletion,
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

pub const SessionArchiveReply = union(enum) {
    accepted: struct {
        replayed: bool,
        archived: bool,
        completion: mutation_answer.SessionStopCompletion,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: protocol.SessionArchiveRejection },
    conflict,
    infrastructure_failure,
};

pub const PermissionDecisionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: protocol.PermissionDecisionRejection },
    conflict,
    infrastructure_failure,
};

pub const PublicConversationItem = struct {
    position: u64,
    ordinal: u64, // Zero for User/Assistant; one-based call ordinal in a completed Tool Result group.
    kind: protocol.ConversationItemKind,
    content: ContentReference,
    presentation: ?tool_presentation.ToolPresentation = null,
    admitted_at: ?u64 = null, // The Host wall-clock second a User item was admitted.
    sender: ?protocol.NamedPeer = null, // A User item's sending peer Session.
};

pub const PublicConversationPage = struct {
    pub const capacity = protocol.public_conversation_page_items;
    end: u64,
    items: [capacity]PublicConversationItem = undefined,
    count: usize = 0,
    more: bool = false,
};

pub const MessageObservation = struct {
    content: ContentReference,
    queue: ?AcceptedMessageQueue = null,
    admitted_at: u64 = 0,
    /// The Session's complete work, only while this admission can advance.
    work: ?session_work.Work = null,
    recovery: Recovery = .{},
};

pub const Recovery = struct {
    pub const capacity = protocol.message_recovery_limit;
    calls: [capacity]UnknownOutcome = undefined,
    count: u8 = 0,
    more: bool = false,
};

pub const UnknownOutcome = protocol.MessageUnknownOutcome;

pub const AcceptedMessageQueue = struct {
    admission_id: u64,
    state: State,

    pub const State = union(enum) {
        queued,
        excluded: struct { code: Bounded(protocol.max_code_bytes) },
        processing: AttemptBinding,
        completed: struct {
            binding: AttemptBinding,
            answer: ContentReference,
        },
        cancelled: struct {
            binding: AttemptBinding,
            code: Bounded(protocol.max_code_bytes),
        },
        failed: struct {
            binding: AttemptBinding,
            code: Bounded(protocol.max_code_bytes),
        },
    };
};

/// A repeat read owns only its token; a full read is filled in the caller's
/// storage rather than copied through Store/worker frames.
pub const Observed = union(enum) {
    not_modified: change_ring.SessionToken,
    full: struct {
        token: ?change_ring.SessionToken,
        observation: CommandObservation = undefined,
    },
};
