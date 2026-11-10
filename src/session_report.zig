//! A Session report's Current facts as plain values: what the Store reads
//! (`store/domain/session_report_read.zig`) and the Host writes
//! (`session_report_reply.zig`). Their slices borrow the Store's read and
//! are valid only during the visitor call that receives them.
const model_capability = @import("model_capability.zig");
const provider_name = @import("provider_name.zig");
const cli_value = @import("cli_value.zig");
const session_archive = @import("session_archive.zig");
const session_list = @import("session_list.zig");
const session_work = @import("session_work.zig");
const tool_presentation = @import("tool_presentation.zig");

/// Execution counters the Host supplies; the Store reads none of them.
pub const Execution = struct {
    dispatch_fenced: bool,
    custody_occupied: usize,
    scratch_used_bytes: u64,
};

/// Content's length and SHA-256.
pub const Content = struct { length: u64, digest: [32]u8 };

/// A saved Session's settings and Current facts, before its lists.
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
    /// Valid, distinct tool names in name order.
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
    /// The selected Message's key.
    selected_message: ?[]const u8,
    /// The active Turn's Actions and rejected calls.
    actions: u64,
    rejected_calls: u64,
};

/// The latest Turn's outcome code and content.
pub const Outcome = struct { code: []const u8, content: ?Content };

/// The Current lists, in report order.
pub const List = enum { recent_messages, unresolved_actions, resolved_actions, rejected_calls, actionable_permissions };

/// One row of a Current list.
pub const Row = union(List) {
    recent_messages: Recent,
    unresolved_actions: Unresolved,
    resolved_actions: Resolved,
    rejected_calls: Rejected,
    actionable_permissions: Actionable,
};

/// A Message of a terminal Turn.
pub const Recent = struct { turn: u64, message: []const u8, outcome: []const u8 };

pub const Authorization = enum { core, pending, bypass, allow_once };

/// An unresolved Action of the active Turn's current Operation.
pub const Unresolved = struct {
    action: u64,
    parent_operation: u64,
    call_ordinal: u64,
    /// A built-in tool's name, or an MCP tool's (`tool_name.valid`).
    tool: []const u8,
    permission_revision: u64,
    authorization: Authorization,
    call_id: Content,
    /// An MCP call's frozen server (`tool_name.valid`); null for a
    /// built-in call.
    server: ?[]const u8,
    arguments: Content,
    presentation: tool_presentation.ToolPresentation,
};

/// A resolved Action of the active Turn.
pub const Resolved = struct {
    action: u64,
    parent_operation: u64,
    call_ordinal: u64,
    code: []const u8,
    acceptance_position: u64,
    result: Content,
    presentation: tool_presentation.ToolPresentation,
};

/// A rejected call of the active Turn.
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

/// An Action of the active Turn's current Operation awaiting permission.
pub const Actionable = struct { action: u64, permission_revision: u64 };
