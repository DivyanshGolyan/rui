const model_capability = @import("model_capability.zig");
const provider_name = @import("provider_name.zig");
const cli_value = @import("cli_value.zig");
const mutation_answer = @import("mutation_answer.zig");
const session_archive = @import("session_archive.zig");
const session_list = @import("session_list.zig");
const session_work = @import("session_work.zig");
const tool_presentation = @import("tool_presentation.zig");

pub const Execution = struct {
    dispatch_fenced: bool,
    custody_occupied: usize,
    scratch_used_bytes: u64,
};

pub const Content = struct { length: u64, digest: [32]u8 };

pub const Current = struct {
    reference: []const u8,
    parent: ?[]const u8,
    workspace: []const u8,
    provider: provider_name.Provider,
    model: []const u8,
    compaction_trigger: u64,
    context_estimate: ?u64,
    output_reservation: u64,
    compaction_trigger_override: ?u64,
    output_reservation_override: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    reasoning_effort_override: ?model_capability.ReasoningEffort,
    revision: u64,
    tools: []const []const u8,
    loaded_tools: []const []const u8,
    permission_mode: cli_value.PermissionMode,
    instructions: Content,
    output_schema: ?Content,
    label: ?[]const u8,
    created_at: u64,
    archive_state: session_archive.State,
    pending_messages: u64,
    work: session_work.Work,
    latest_outcome: ?Outcome,
    peers: session_list.Peers,
    first_message: ?session_list.FirstMessage,
    selected_message: ?[]const u8,
    actions: u64,
    rejected_calls: u64,
};

pub const Outcome = struct { code: []const u8, content: ?Content };

pub const List = enum { recent_messages, unresolved_actions, resolved_actions, rejected_calls, actionable_permissions };

pub const Row = union(List) {
    recent_messages: Recent,
    unresolved_actions: Unresolved,
    resolved_actions: Resolved,
    rejected_calls: Rejected,
    actionable_permissions: Actionable,
};

pub const Recent = struct { turn: u64, message: []const u8, outcome: []const u8 };

pub const Authorization = enum { core, pending, bypass, allow_once };

pub const Unresolved = struct {
    action: u64,
    parent_operation: u64,
    call_ordinal: u64,
    tool: []const u8,
    permission_revision: u64,
    authorization: Authorization,
    call_id: Content,
    server: ?[]const u8,
    arguments: Content,
    presentation: tool_presentation.ToolPresentation,
};

pub const Resolved = struct {
    action: u64,
    parent_operation: u64,
    call_ordinal: u64,
    code: []const u8,
    acceptance_position: u64,
    result: @import("content_value.zig").Value,
    presentation: tool_presentation.ToolPresentation,
};

pub const Rejected = struct {
    parent_operation: u64,
    call_ordinal: u64,
    code: []const u8,
    acceptance_position: u64,
    result: Content,
    name: Content,
    call_id: Content,
    arguments: Content,
    presentation: tool_presentation.ToolPresentation,
};

pub const Actionable = struct { action: u64, permission_revision: u64 };

pub const FullList = enum {
    session_revisions,
    messages,
    conversation,
    turns,
    model_operations,
    tool_calls,
    actions,
    permission_decisions,
    session_stops,
    model_interruptions,
    tool_results,
};

pub const Text = struct { id: u64, length: u64, digest: [32]u8 };

/// A stored Message or Action value in the Full report: text is inlined, and a parts
/// value names the owner that addresses its parts.
pub const Stored = union(enum) { text: Text, parts: @import("content_value.zig").Value.Parts };

pub const RevisionField = enum { instructions, output_schema };

pub const Owner = struct { revision: u64, field: RevisionField };

pub const RevisionContent = struct { text: Text, owner: ?Owner };

pub const FullRow = union(enum) {
    revision: Revision,
    revision_contents: RevisionContents,
    message: Message,
    conversation: Conversation,
    turn: Turn,
    operation: Operation,
    call: Call,
    action: Action,
    decision: Decision,
    stop: Stop,
    interruption: Interruption,
    result: Result,
};

pub const Revision = struct {
    revision: u64,
    command_key: []const u8,
    workspace: []const u8,
    provider: provider_name.Provider,
    model: []const u8,
    compaction_trigger: ?u64,
    output_reservation: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    label: ?[]const u8,
    tools: []const []const u8,
    loaded_tools: []const []const u8,
    permission_mode: cli_value.PermissionMode,
};

pub const RevisionContents = struct { instructions: RevisionContent, output_schema: ?RevisionContent };

pub const Application = enum { applied, pending, excluded };

pub const Message = struct {
    admission: u64,
    command_key: []const u8,
    content: Stored,
    application: union(Application) {
        applied: struct { turn: u64, outcome: ?Outcome },
        pending,
        excluded: []const u8,
    },
};

pub const EntryKind = enum { message, settings, assistant, skill };

pub const Conversation = struct {
    ordinal: u64,
    position: u64,
    kind: EntryKind,
    turn: ?u64,
    source_admission: ?u64,
    source_revision: ?u64,
    source_catalog_position: ?u64,
    source_skill_position: ?u64,
    source_operation: ?u64,
    content: @import("content_value.zig").Value,
};

pub const Turn = struct {
    turn: u64,
    first_admission: u64,
    input_cutoff: u64,
    operation: u64,
    outcome: ?Outcome,
};

pub const Operation = struct {
    operation: u64,
    turn: u64,
    resolution: ?Resolution,
    interrupted_by: ?[]const u8,
    settings_revision: u64,
    offered_tools: []const []const u8,
    request_id: ?[]const u8,
    reasoning_effort: ?model_capability.ReasoningEffort,
};

pub const Resolution = struct { code: []const u8, content: ?Text };

pub const Call = struct {
    operation: u64,
    call_ordinal: u64,
    item_ordinal: u64,
    rejection: ?[]const u8,
    acceptance_position: ?u64,
    name: Text,
    call_id: Text,
    arguments: Text,
    rejection_result: ?Text,
};

pub const Permission = enum { denied, authorized, requested };

pub const max_action_resolution_bytes = "infrastructure_shutdown".len;

pub const Action = struct {
    action: u64,
    parent_operation: u64,
    call_ordinal: u64,
    permission_revision: u64,
    permission: Permission,
    resolution: ?[]const u8,
    result: ?Stored,
    acceptance_position: ?u64,
};

pub const Decision = struct {
    command_key: []const u8,
    action: []const u8,
    decision: mutation_answer.PermissionDecision,
    accepted: bool,
    code: []const u8,
};

pub const Stop = struct {
    command_key: []const u8,
    accepted: bool,
    code: []const u8,
    selected_turn: ?u64,
    admission_cutoff: ?u64,
};

pub const Interruption = struct {
    command_key: []const u8,
    accepted: bool,
    code: []const u8,
    turn: []const u8,
    operation: []const u8,
};

pub const Result = struct {
    operation: u64,
    call_ordinal: u64,
    acceptance_position: u64,
    call_id: Text,
    code: []const u8,
    result: Stored,
};
