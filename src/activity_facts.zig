const std = @import("std");
const session_list = @import("session_list.zig");
const Bounded = @import("bounded.zig").Bounded;
const activity_read = @import("activity_read.zig");
const change_ring = @import("change_ring.zig");
const idempotency_key = @import("idempotency_key.zig");
const mutation_answer = @import("mutation_answer.zig");
const outcome_code = @import("outcome_code.zig");
const session_id = @import("session_id.zig");
const session_settings = @import("session_settings.zig");
const session_work = @import("session_work.zig");
const tool_presentation = @import("tool_presentation.zig");
const turn_ending = @import("turn_ending.zig");
const workspace_path = @import("workspace_path.zig");
const model_capability = @import("model_capability.zig");
const content_value = @import("content_value.zig");

const ToolPresentation = tool_presentation.ToolPresentation;

pub const NamedPeer = struct {
    session: Bounded(session_id.max_reference_bytes),
    label: Bounded(tool_presentation.max_label_bytes) = .{},

    pub fn name(self: *const NamedPeer) []const u8 {
        return if (self.label.len == 0) self.session.slice() else self.label.slice();
    }
};

pub const Item = struct {
    position: u64,
    ordinal: u64 = 0,
    at: u64,
    value: Value,
    pub const Value = union(activity_read.Kind) { admission: Message, user: Message, assistant: Assistant, call: Call, tool_result: struct { content: content_value.Value, presentation: ToolPresentation }, hosted_call: ToolPresentation, turn_ended: TurnEnded, stop: Stop, sent: Sent, send_failed: SendFailed, received: Message, approval_requested: ApprovalRequested, session_changed: SessionChanged, compacted: Compacted, model_call: ModelCall };
    pub const Kind = std.meta.Tag(Value);
    pub const Message = struct { admission: u64, key: Bounded(idempotency_key.max_bytes), turn: ?u64, state: enum { queued, applied, excluded }, content: content_value.Value, admitted_at: u64, sender: ?NamedPeer = null, source_action: ?u64 = null };
    pub const Call = activity_read.ProposalMetadata;
    /// Model text, never parts.
    pub const Assistant = struct { content: content_value.Reference, final: bool = false };
    pub const TurnEnded = struct { session: Bounded(session_id.bytes), turn: u64, operation: u64, ending: turn_ending.TurnEnding, code: Bounded(outcome_code.max_bytes), content: ?content_value.Reference };
    pub const Stop = struct { key: Bounded(idempotency_key.max_bytes), turn: ?u64, cutoff: u64, completion: mutation_answer.SessionStopCompletion };
    pub const Sent = struct { admission: u64, target: NamedPeer, content: content_value.Value, admitted_at: u64 };
    pub const SendFailed = struct {
        key: Bounded(idempotency_key.max_bytes),
        target: ?NamedPeer,
        code: Bounded(outcome_code.max_bytes),
    };
    pub const ApprovalRequested = struct {
        session: Bounded(session_id.bytes),
        action: u64,
        operation: u64,
        call_ordinal: u64,
        description: ?activity_read.CallText.Description = null,
        tool: ?activity_read.CallText.Tool = null,
        server: ?activity_read.CallText.Server = null,
    };
    pub const SessionChanged = struct { revision: u64, field: session_settings.SessionField, provider_text: ?Bounded(outcome_code.max_report_bytes) = null };
    pub const Compacted = struct { operation: u64, dropped: u64 };
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

pub const Queued = struct {
    count: u64 = 0,
    oldest_position: u64 = 0,
    newest_admission: u64 = 0,
    newest_position: u64 = 0,
    /// The newest queued Message's value, for its first-line hint; null when none is queued.
    newest_content: ?content_value.Value = null,
};

pub const PageWork = struct {
    creator: ?Bounded(session_id.bytes) = null,
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    work: session_work.Work = .{ .state = .{ .idle = .{ .since = 0 } } },
    last_line: ?session_list.SavedLastLine = null,
    revision: u64 = 0,
    workspace: Bounded(workspace_path.max_bytes) = .{},
};

pub const Page = struct {
    token: ?change_ring.SessionToken = null,
    not_modified: bool = false,
    end: u64,
    direction: @FieldType(activity_read.ActivityPage, "direction") = .forward,
    items: [activity_read.ActivityPage.items]Item = undefined,
    count: usize = 0,
    more: bool = false,
    call_activity: CallActivity = .{},
    queued: Queued = .{},
    work: PageWork = .{},
};

pub const Search = struct {
    items: [activity_read.ActivityPage.items]Match = undefined,
    count: usize = 0,
    next: ?Cursor = null,

    pub const Hit = struct {
        snippet: Bounded(160) = .{},
        offset: usize,
        length: usize,
        /// The Text part the hit lies in, for an entry whose value has parts.
        part: ?u32 = null,
    };
    pub const Cursor = struct { position: u64, ordinal: u64 };
    pub const Match = struct {
        position: u64,
        ordinal: u64,
        kind: activity_read.Kind,
        hits: [3]Hit = undefined,
        count: usize = 0,
    };
};
