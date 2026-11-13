//! What an activity page and an activity search read, as plain values: the
//! Store fills them and the Host writes them (`activity_reply.zig`).
const std = @import("std");
const session_list = @import("session_list.zig");
const Bounded = @import("bounded.zig").Bounded;
const activity_read = @import("activity_read.zig");
const change_ring = @import("change_ring.zig");
const idempotency_key = @import("idempotency_key.zig");
const mutation_answer = @import("mutation_answer.zig");
const outcome_code = @import("outcome_code.zig");
const session_field = @import("session_field.zig");
const session_id = @import("session_id.zig");
const session_work = @import("session_work.zig");
const tool_presentation = @import("tool_presentation.zig");
const turn_ending = @import("turn_ending.zig");
const workspace_path = @import("workspace_path.zig");
const model_capability = @import("model_capability.zig");

const ToolPresentation = tool_presentation.ToolPresentation;

/// A peer as a Message row names it: with its label as the Store holds it
/// when read, empty when the Session has none. Only rows a reader shows
/// carry it; listings keep the bare `Peer`.
pub const NamedPeer = struct {
    session: Bounded(session_id.max_reference_bytes),
    label: Bounded(tool_presentation.max_label_bytes) = .{},

    /// What a reader calls it: its label, or its ID when it has none.
    pub fn name(self: *const NamedPeer) []const u8 {
        return if (self.label.len == 0) self.session.slice() else self.label.slice();
    }
};

pub const Item = struct {
    position: u64,
    ordinal: u64 = 0,
    /// The Host Unix second the row's owning fact committed.
    at: u64,
    value: Value,
    /// `admission` is a Message a person or script sent; `received` one
    /// another Session sent, which always names it as `sender`.
    pub const Value = union(activity_read.Kind) { admission: Message, user: Message, assistant: Assistant, call: Call, tool_result: struct { content: Content, presentation: ToolPresentation }, hosted_call: ToolPresentation, turn_ended: TurnEnded, stop: Stop, sent: Sent, send_failed: SendFailed, received: Message, approval_requested: ApprovalRequested, session_changed: SessionChanged, compacted: Compacted, model_call: ModelCall };
    pub const Kind = std.meta.Tag(Value);
    pub const Content = struct { length: u64, digest: [32]u8 };
    // `admitted_at` is the Host wall-clock second the Message was admitted.
    // A null `sender` means a human or script sent the Message.
    pub const Message = struct { admission: u64, key: Bounded(idempotency_key.max_bytes), turn: ?u64, state: enum { queued, applied, excluded }, content: Content, admitted_at: u64, sender: ?NamedPeer = null };
    pub const Call = activity_read.ProposalMetadata;
    /// `final` marks the Turn's answer: the assistant row a `done` Turn
    /// ended with, once its `turn_ended` row is within the page's end.
    pub const Assistant = struct { content: Content, final: bool = false };
    /// `code` is the saved code the ending was judged from; `content` a
    /// done Turn's answer or a failed one's report.
    pub const TurnEnded = struct { session: Bounded(session_id.bytes), turn: u64, operation: u64, ending: turn_ending.TurnEnding, code: Bounded(outcome_code.max_bytes), content: ?Content };
    pub const Stop = struct { key: Bounded(idempotency_key.max_bytes), turn: ?u64, cutoff: u64, completion: mutation_answer.SessionStopCompletion };
    /// A Message this Session sent: admitted to `target`, or rejected there.
    pub const Sent = struct { admission: u64, target: NamedPeer, content: Content, admitted_at: u64 };
    pub const SendFailed = struct {
        key: Bounded(idempotency_key.max_bytes),
        /// No canonical attempted reference, not evidence of creation intent.
        /// A canonical but unknown Session still has a target.
        target: ?NamedPeer,
        code: Bounded(outcome_code.max_bytes),
    };
    /// A call that waits on a person's decision because the Session asked
    /// for approval when it was made: `action` is the id a
    /// `permission_decision` names. The row follows its call at ordinal 1.
    pub const ApprovalRequested = struct {
        session: Bounded(session_id.bytes),
        action: u64,
        operation: u64,
        call_ordinal: u64,
        description: ?activity_read.CallText.Description = null,
        tool: ?activity_read.CallText.Tool = null,
        server: ?activity_read.CallText.Server = null,
    };
    /// A setting a revision changed, or its later effort refusal. Ordinary
    /// rows share the revision's position; a refusal has its settlement
    /// position and the provider's bounded report, without a new revision.
    pub const SessionChanged = struct { revision: u64, field: session_field.SessionField, provider_text: ?Bounded(outcome_code.max_report_bytes) = null };
    /// A compaction that succeeded, at its admission: `dropped` is how many
    /// conversation entries it left out to make room, zero for none (D217).
    pub const Compacted = struct { operation: u64, dropped: u64 };
    /// A resolved model Operation at its admission position (D219).
    /// Timings describe the FINAL attempt, not the entire retry sequence.
    pub const ModelCall = struct {
        model: Bounded(model_capability.max_model_bytes),
        served_model: ?Bounded(model_capability.max_model_bytes),
        input_tokens: ?u64,
        output_tokens: ?u64,
        cached_tokens: ?u64,
        latency_ms: ?u64,
        first_event_ms: ?u64,
        status: Bounded(outcome_code.max_bytes),
        attempts: u64,
    };
};

pub const CallActivity = struct {
    pub const Entry = struct { operation: u64, ordinal: u64, presentation: ToolPresentation };
    entries: [3]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,
};

/// The Messages a person or script sent that a Session admitted and had not
/// taken at a page's boundary: not applied, and not excluded by a stop. A
/// stop and an input boundary both take an admission-order prefix, so they
/// are the newest such admissions. Zero when none waits.
pub const Queued = struct {
    count: u64 = 0,
    /// The oldest one's Admission position.
    oldest_position: u64 = 0,
    /// The newest one's admission ID and Admission position.
    newest_admission: u64 = 0,
    newest_position: u64 = 0,
};

/// The Session's work as of its page's own Store read: what the live footer,
/// consent and first Action show with that page, beside the revision and
/// Workspace a permission prompt shows.
pub const PageWork = struct {
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    work: session_work.Work = .{ .state = .{ .idle = .{ .since = 0 } } },
    /// From the same live read as work, even when history has a pinned end.
    last_line: ?session_list.SavedLastLine = null,
    revision: u64 = 0,
    workspace: Bounded(workspace_path.max_bytes) = .{},
};

/// One activity page, or the token of an unchanged one.
pub const Page = struct {
    token: ?change_ring.SessionToken = null,
    not_modified: bool = false,
    end: u64,
    direction: @FieldType(activity_read.ActivityPage, "direction") = .forward,
    items: [activity_read.ActivityPage.items]Item = undefined,
    count: usize = 0,
    more: bool = false,
    call_activity: CallActivity = .{},
    /// At the same boundary as `call_activity`.
    queued: Queued = .{},
    work: PageWork = .{},
};

/// One page of search hits, newest first.
pub const Search = struct {
    items: [activity_read.ActivityPage.items]Match = undefined,
    count: usize = 0,
    next: ?Cursor = null,

    pub const Hit = struct {
        snippet: Bounded(160) = .{},
        offset: usize,
        length: usize,
    };
    pub const Cursor = struct { position: u64, ordinal: u64 };
    /// One row with up to three hits.
    pub const Match = struct {
        position: u64,
        ordinal: u64,
        kind: activity_read.Kind,
        hits: [3]Hit = undefined,
        count: usize = 0,
    };
};
