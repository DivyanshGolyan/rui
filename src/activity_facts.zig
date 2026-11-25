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
const tool_proposal = @import("tool_proposal.zig");
const skill_reference = @import("skill_reference.zig");
const hosted_action = @import("hosted_action.zig");

const ToolPresentation = tool_presentation.ToolPresentation;

/// A Session a row points at, owned by `tool_presentation` so a tool row and a peer row name one type.
pub const NamedPeer = tool_presentation.NamedPeer;

pub const Item = struct {
    position: u64,
    ordinal: u64 = 0,
    at: u64,
    value: Value,
    pub const Value = union(activity_read.Kind) { admission: Message, user: Message, assistant: Assistant, call: Call, tool_result: struct { content: content_value.Value, presentation: ToolPresentation }, hosted_call: Hosted, turn_ended: TurnEnded, stop: Stop, received: Message, approval_requested: ApprovalRequested, session_changed: SessionChanged, compacted: Compacted, model_call: ModelCall, instruction: Instruction, skill: Skill };
    pub const Kind = std.meta.Tag(Value);

    /// What a row's text is: the one owner of which of its contents a reader can open. A row with no text has `none`.
    pub const Body = union(enum) {
        none,
        value: content_value.Value,
        /// A tool call's text is its name, a newline, then its arguments.
        call: struct { name: activity_read.ProposalFieldReference, arguments: activity_read.ProposalFieldReference },
        /// A hosted call's text is its served targets, then its pattern, joined by newlines.
        hosted: HostedBody,
    };

    /// The exact strings of a hosted call in reading order: the field a reader names is an index into `refs()`.
    pub const HostedBody = struct {
        list: [HostedAction.Targets.max_served + 1]content_value.Reference = @splat(.{ .length = 0, .digest = @splat(0) }),
        len: u8 = 0,

        pub fn refs(self: *const HostedBody) []const content_value.Reference {
            return self.list[0..self.len];
        }
    };

    /// Exhaustive on purpose: a new row kind must say whether it has text.
    pub fn body(self: *const Item) Body {
        return switch (self.value) {
            .admission, .user, .received => |message| .{ .value = message.content },
            .assistant => |assistant| .{ .value = .{ .text = assistant.content } },
            .instruction => |instruction| .{ .value = .{ .text = instruction.content } },
            .skill => |skill| .{ .value = .{ .text = skill.content } },
            .call => |call| .{ .call = .{ .name = call.fields[@backingInt(tool_proposal.Field.name)], .arguments = call.fields[@backingInt(tool_proposal.Field.arguments)] } },
            .tool_result => |result| .{ .value = result.content },
            .turn_ended => |ended| if (ended.content) |reference| .{ .value = .{ .text = reference } } else .none,
            .hosted_call => |hosted| .{ .hosted = hosted.action.body() },
            .stop, .approval_requested, .session_changed, .compacted, .model_call => .none,
        };
    }
    pub const Message = struct { admission: u64, key: Bounded(idempotency_key.max_bytes), turn: ?u64, state: enum { queued, applied, excluded }, content: content_value.Value, admitted_at: u64, sender: ?NamedPeer = null, source_action: ?u64 = null };
    pub const Call = activity_read.ProposalMetadata;
    /// A hosted web search: the line a reader shows (derived from the action when it is read, never stored) and the
    /// action's facts, which the Store holds as exact strings.
    pub const Hosted = struct { presentation: ToolPresentation, action: HostedAction };
    pub const HostedAction = struct {
        kind: hosted_action.HostedAction,
        /// The first `Targets.max_served` of the targets, in provider order; `targets_total` says how many the Store holds.
        targets: Targets = .{},
        targets_total: u64 = 0,
        pattern: ?content_value.Reference = null,

        pub const Targets = struct {
            list: [max_served]content_value.Reference = @splat(.{ .length = 0, .digest = @splat(0) }),
            len: u8 = 0,
            pub const max_served = 8;

            pub fn served(self: *const Targets) []const content_value.Reference {
                return self.list[0..self.len];
            }

            pub fn append(self: *Targets, reference: content_value.Reference) error{TooManyTargets}!void {
                if (self.len == max_served) return error.TooManyTargets;
                self.list[self.len] = reference;
                self.len += 1;
            }
        };

        /// The target and pattern strings in reading order.
        pub fn body(self: *const HostedAction) HostedBody {
            var out: HostedBody = .{};
            for (self.targets.served()) |reference| {
                out.list[out.len] = reference;
                out.len += 1;
            }
            if (self.pattern) |reference| {
                out.list[out.len] = reference;
                out.len += 1;
            }
            return out;
        }
    };
    /// Model text, never parts.
    pub const Assistant = struct { content: content_value.Reference, final: bool = false };
    pub const TurnEnded = struct { session: Bounded(session_id.bytes), turn: u64, operation: u64, ending: turn_ending.TurnEnding, code: Bounded(outcome_code.max_bytes), content: ?content_value.Reference };
    pub const Stop = struct { key: Bounded(idempotency_key.max_bytes), turn: ?u64, cutoff: u64, completion: mutation_answer.SessionStopCompletion };
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
    /// Instruction text the model was given. `turn` and `revision` are both null exactly for the skill-catalog instruction,
    /// which no Turn and no authored revision owns. The text is public; a private value never becomes a row.
    pub const Instruction = struct { turn: ?u64, revision: ?u64, content: content_value.Reference };
    /// The complete raw SKILL.md the model was given with a Message. `ordinal` is the skill's position among that Message's skills.
    /// The text is public, at most 1 MiB; a private value never becomes a row.
    pub const Skill = struct { admission: u64, turn: u64, ordinal: u64, name: Bounded(skill_reference.max_name_bytes), content: content_value.Reference };
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

/// The position a page's queued aggregate (and call activity) is taken at: the last row of a
/// forward page that has more, otherwise the page's end. The Store and the client both use it.
pub fn queueCutoff(end: u64, forward: bool, more: bool, last: ?u64) u64 {
    return if (forward and more) last.? else end;
}

test "queueCutoff takes a forward page's aggregate at its last row only while more follows" {
    try std.testing.expectEqual(@as(u64, 7), queueCutoff(40, true, true, 7));
    try std.testing.expectEqual(@as(u64, 40), queueCutoff(40, true, false, 7));
    try std.testing.expectEqual(@as(u64, 40), queueCutoff(40, false, true, 7));
    try std.testing.expectEqual(@as(u64, 40), queueCutoff(40, false, false, null));
}

pub const PageWork = struct {
    creator: ?Bounded(session_id.bytes) = null,
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    work: session_work.Work = .{ .state = .{ .idle = .{ .since = 0 } } },
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
