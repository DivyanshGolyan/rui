//! Action Attempts: admitting, dispatching, settling and recovering tool actions.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const protocol = @import("../../protocol.zig");
const tool_catalog = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");
const reads_domain = @import("reads.zig");
const sqlite = @import("../sqlite.zig");
const store_access = @import("../access.zig");
const turn_domain = @import("turn.zig");
const forward_domain = @import("forward.zig");
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;

/// Matches the ordinal the Store issues an Action Attempt, so statements
/// compare it as a literal rather than a bound value.
const action_attempted_sql = std.fmt.comptimePrint("attempt_ordinal={d}", .{attempt.action_attempt_ordinal});

/// Whether the Action `action` carries out a call whose name's digest
/// passes `test_sql`. Derived from the call, never stored (D46).
fn callNameSql(comptime test_sql: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM model_tool_call tool_call JOIN content call_name ON call_name.content_id=tool_call.name_content_id " ++
        "WHERE tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal AND call_name.digest" ++ test_sql ++ ")";
}

/// Whether the Action `action` carries out a call the core runs (D24): its
/// call names a core tool, whose names' digests `first` and the three parameters
/// after it bind, in `CoreNames` order.
fn coreCallSql(comptime first: u8) []const u8 {
    return callNameSql(std.fmt.comptimePrint(" IN(?{d},?{d},?{d},?{d},?{d})", .{ first, first + 1, first + 2, first + 3, first + 4 }));
}

/// The digests of the core tools' names, which `coreCallSql` binds.
pub const CoreNames = struct {
    message_agent: [32]u8,
    read_transcript: [32]u8,
    start_agent: [32]u8,
    find_tools: [32]u8,
    skill: [32]u8,

    pub fn of() CoreNames {
        return .{
            .message_agent = protocol.contentDigest(tool_catalog.message_agent_record.name),
            .read_transcript = protocol.contentDigest(tool_catalog.read_transcript_record.name),
            .start_agent = protocol.contentDigest(tool_catalog.start_agent_record.name),
            .find_tools = protocol.contentDigest(tool_catalog.find_tools_record.name),
            .skill = protocol.contentDigest(tool_catalog.skill_record.name),
        };
    }
};

/// Whether the Action's call belongs to MCP in its Operation's frozen offer,
/// never the current catalog. The call is point-seeked by parent and ordinal;
/// accepted tool names fit the inline content payload and compare exactly.
pub fn mcpCallSql(comptime action_alias: []const u8, comptime operation_alias: []const u8) []const u8 {
    return "EXISTS(" ++ mcpCallSelectSql(action_alias, operation_alias, "1") ++ ")";
}

/// The frozen MCP server for an Action, or SQL NULL for a built-in call.
pub fn mcpServerSql(comptime action_alias: []const u8, comptime operation_alias: []const u8) []const u8 {
    return "(" ++ mcpCallSelectSql(action_alias, operation_alias, "tool.server") ++ ")";
}

fn mcpCallSelectSql(comptime action_alias: []const u8, comptime operation_alias: []const u8, comptime selected: []const u8) []const u8 {
    return "SELECT " ++ selected ++ " FROM model_tool_call tool_call " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "JOIN session_revision revision ON revision.session_ref=" ++ operation_alias ++ ".session_ref AND revision.revision=" ++ operation_alias ++ ".settings_revision " ++
        "JOIN tool_set_member member ON member.tool_set_id=coalesce(revision.loaded_tool_set_id,revision.tool_set_id) " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE tool_call.operation_id=" ++ action_alias ++ ".parent_operation_id AND tool_call.call_ordinal=" ++ action_alias ++ ".call_ordinal " ++
        "AND @bytes(tool.name)=@payload(name) AND tool.owner='mcp'";
}

/// Calls that must never enter Bash's Attempt path.
fn nonBashCallSql(comptime first: u8) []const u8 {
    return "(" ++ coreCallSql(first) ++ " OR " ++ mcpCallSql("action", "operation") ++ ")";
}

/// The next Action ready for an Attempt, with its Session. Reads only
/// `action_operation_executable`, so an Action waiting for permission costs
/// admission nothing.
const next_action_attempt = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms,s.session_ref,s.workspace_key,s.next_position " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) AND NOT " ++ nonBashCallSql(1) ++ " " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = struct { message_agent_name: [32]u8, read_transcript_name: [32]u8, start_agent_name: [32]u8, find_tools_name: [32]u8, skill_name: [32]u8 },
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, bash_timeout_override_ms: ?rsql.Positive, session: rsql.SessionHead },
    .cardinality = .optional,
});
pub const next_action_attempt_sql = next_action_attempt.sql;

/// The next core tool call ready to run (D24), as `next_action_attempt`
/// finds Bash's: decided, never attempted, of an open Turn no stop selected.
const next_core_action = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref AS session," ++ "CASE WHEN " ++ callNameSql("=?1") ++ " THEN 'message_agent' WHEN " ++ callNameSql("=?2") ++ " THEN 'read_transcript' WHEN " ++ callNameSql("=?3") ++ " THEN 'start_agent' WHEN " ++ callNameSql("=?4") ++ " THEN 'find_tools' ELSE 'skill' END AS tool " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) AND " ++ coreCallSql(1) ++ " " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = struct { message_agent_name: [32]u8, read_transcript_name: [32]u8, start_agent_name: [32]u8, find_tools_name: [32]u8, skill_name: [32]u8 },
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, session: protocol.Bounded(protocol.max_session_bytes), tool: CoreTool },
    .cardinality = .optional,
});

/// A core tool call to run: which Action it is, which tool it calls, its
/// Session, and its arguments' content.
pub const CoreTool = enum { message_agent, read_transcript, start_agent, find_tools, skill };

pub const CoreActionInput = struct {
    binding: ActionAttemptBinding,
    tool: CoreTool,
    session: protocol.Bounded(protocol.max_session_bytes),
    arguments: ContentReference,
};

/// The next core tool call to run, or null. It writes nothing: the core
/// command that runs it resolves it in one transaction, so a call read
/// here and never run is simply read again.
/// A stop an attached child owes (D38), as the Host runs it: the child's
/// own Session stop under a key its cause names, so a stop read here and
/// never run is run again under the same key.
pub const OwedStop = struct {
    session: protocol.Bounded(protocol.session_id_bytes),
    key: protocol.Bounded(protocol.max_key_bytes),
};

/// An attached child's Turn ending its parent is owed as a Message (D39),
/// as `Store.deliverChildEnding` delivers it: the child's saved answer
/// itself when it is done. `quiet` when the child's parent stopping ended
/// it, which delivers nothing (D139) and only settles the row.
pub const OwedEnding = struct {
    turn_id: u64,
    child: protocol.Bounded(protocol.session_id_bytes),
    ending: protocol.TurnEnding,
    answer: ?ContentReference,
    quiet: bool,
};

/// The core's next piece of work: a stop a child owes comes first, so
/// none of its calls runs after its parent stopped, then an ending a
/// parent is owed, then one ancestor feed hop, before core tool calls.
pub const CoreWork = union(enum) {
    stop: OwedStop,
    ending: OwedEnding,
    forward: u64,
    action: CoreActionInput,
    mcp: McpAction,
};

/// A stopped Turn keeps the causal stop fact even when an ordinary stop
/// discharges its parent's obligation. Archive suppression belongs to the
/// ending record, so restoring the parent never replays old work.
pub const ending_stop_sql = "EXISTS(SELECT 1 FROM session_stop st WHERE st.selected_turn_id=e.turn_id) AS stopped," ++
    "(e.suppress_message=1 OR EXISTS(SELECT 1 FROM session_stop st WHERE st.selected_turn_id=e.turn_id AND st.parent_caused=1)) AS quiet";

/// The oldest owed ending.
const owed_ending = rsql.Read(.{
    .sql = "SELECT e.turn_id,t.session_ref,t.outcome_code,t.outcome_content_id,c.byte_length,c.digest," ++ ending_stop_sql ++ " " ++
        "FROM session_ending_owed e @index(session_ending_open) JOIN turn t ON t.turn_id=e.turn_id LEFT JOIN content c ON c.content_id=t.outcome_content_id " ++
        "WHERE e.delivered=0 ORDER BY e.turn_id LIMIT 1",
    .Args = struct {},
    .Row = struct {
        turn_id: rsql.Positive,
        session_ref: protocol.Bounded(protocol.session_id_bytes),
        outcome_code: protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        stopped: bool,
        quiet: bool,
    },
    .cardinality = .optional,
});

const owed_stop = rsql.Read(.{
    .sql = "SELECT child_ref,cause_ref,cause_position FROM session_stop_owed WHERE settled=0 ORDER BY child_ref LIMIT 1",
    .Args = struct {},
    .Row = struct { child_ref: protocol.Bounded(protocol.session_id_bytes), cause_ref: protocol.Bounded(protocol.session_id_bytes), cause_position: u64 },
    .cardinality = .optional,
});

/// The key an owed stop runs under: the child, and the stop or context
/// full ending of its parent that owes it, so a newer obligation of the
/// same child has another key.
pub fn owedStopKey(buffer: []u8, child: []const u8, cause: []const u8, position: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/stop/{s}/{s}/{d}", .{ child, cause, position });
}

pub fn nextCoreWork(a: anytype, include_mcp: bool) !?CoreWork {
    var stop: owed_stop.Result = undefined;
    var next: next_core_action.Result = undefined;
    var mcp: next_mcp_action.Result = null;
    const names: CoreNames = .of();
    var ending: owed_ending.Result = undefined;
    var forward: forward_domain.next.Result = undefined;
    a.read(owed_stop, .{}, &stop);
    if (include_mcp) a.read(next_mcp_action, .{}, &mcp);
    a.read(owed_ending, .{}, &ending);
    a.read(forward_domain.next, .{}, &forward);
    a.read(next_core_action, .{ .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools, .skill_name = names.skill }, &next);
    try a.run();
    if (stop) |owed| {
        var work: OwedStop = .{ .session = owed.child_ref, .key = .{} };
        var buffer: [protocol.max_key_bytes]u8 = undefined;
        try work.key.set(try owedStopKey(&buffer, owed.child_ref.slice(), owed.cause_ref.slice(), owed.cause_position));
        return .{ .stop = work };
    }
    if (ending) |owed| {
        const outcome = try turn_domain.TurnOutcome.decode(owed.outcome_code.slice(), if (owed.outcome_content_id) |id| @intCast(id.get()) else null);
        return .{ .ending = .{
            .turn_id = owed.turn_id.get(),
            .child = owed.session_ref,
            .ending = outcome.ending(owed.stopped),
            .answer = if (outcome == .completed) .{ .length = owed.byte_length orelse return error.CorruptStore, .digest = owed.digest orelse return error.CorruptStore } else null,
            .quiet = owed.quiet,
        } };
    }
    if (forward) |owed| return .{ .forward = owed.forward_id.get() };
    // After owed stops and endings, service both slot-free runners in Action order.
    if (mcp) |call| {
        if (next == null or call.action_id.get() < next.?.action_id.get())
            return .{ .mcp = .{ .action_id = call.action_id.get(), .server = call.server } };
    }
    const found = next orelse return null;
    return .{ .action = .{
        .binding = .{ .turn_id = found.turn_id.get(), .parent_operation_id = found.parent_operation_id.get(), .action_id = found.action_id.get() },
        .tool = found.tool,
        .session = found.session,
        .arguments = try actionContent(a, found.session.slice(), found.action_id.get(), .arguments),
    } };
}

const attempt_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET " ++ action_attempted_sql ++ ",attempt_at=@now,bash_timeout_ms=?2,sender_handle=?3 " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0",
    .Args = struct { action_id: u64, timeout_ms: u64, sender_handle: []const u8, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

pub const ActionAttemptBinding = attempt.ActionAttemptBinding;

pub const SupersedingControl = struct {
    command_key: protocol.Bounded(protocol.max_key_bytes),
};

pub const ActionAttemptAdmission = struct {
    permit: ActionDispatchPermit,
};

pub const ActionResolutionCode = enum {
    cancelled,
    succeeded,
    failed,
    timed_out,
    indeterminate,
    storage_failed,
    spawn_failed,
    infrastructure_shutdown,
};

pub const max_action_resolution_code_bytes = sqlite.maxEnumTagBytes(ActionResolutionCode);

pub const ActionSettlement = enum { effect, session_stop };

pub const ActionDispatchPermit = attempt.ActionDispatchPermit;

/// What a Bash execution reads from its Attempt.
pub const BashExecutionInput = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    sender_handle: protocol.Bounded(32),
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    arguments: ContentReference,
    timeout_ms: u64,
};

pub const McpExecutionInput = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    parent: ?protocol.Bounded(protocol.max_session_bytes),
    root: protocol.Bounded(protocol.max_session_bytes),
    name: protocol.Bounded(protocol.max_tool_name_bytes),
    server: protocol.Bounded(tool_catalog.max_server_bytes),
    input_schema: ContentReference,
    sender_handle: protocol.Bounded(32),
    arguments: ContentReference,
    timeout_ms: u64,
};

pub const ActiveOperationFilter = struct {
    context: *const anyopaque,
    containsFn: *const fn (*const anyopaque, u64) bool,
    maximum_exclusions: usize,

    pub fn contains(self: ActiveOperationFilter, operation_id: u64) bool {
        return self.containsFn(self.context, operation_id);
    }

    pub fn empty() ActiveOperationFilter {
        return .{
            .context = &empty_active_context,
            .containsFn = containsNoActiveOperation,
            .maximum_exclusions = 0,
        };
    }
};

pub const empty_active_context: u8 = 0;

fn containsNoActiveOperation(_: *const anyopaque, _: u64) bool {
    return false;
}

/// The Session position of the call the Action `action_id` of `session`
/// carries out.
const action_call_position = rsql.Read(.{
    .sql = "SELECT item.session_position AS position FROM action_operation action JOIN model_tool_call tool_call " ++
        "ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE action.action_id=?1 AND action.session_ref=?2",
    .Args = struct { action_id: u64, session: []const u8 },
    .Row = struct { position: rsql.Positive },
    .cardinality = .optional,
});

/// A field of the Proposal the Action carries out, checked as every
/// Proposal read checks it. Round 2 depends on round 1's position.
pub fn actionContent(a: anytype, session_ref: []const u8, action_id: u64, field: protocol.ProposalField) !ContentReference {
    var found: action_call_position.Result = undefined;
    a.read(action_call_position, .{ .action_id = action_id, .session = session_ref }, &found);
    try a.run();
    const position = (found orelse return error.ActionNotFound).position.get();
    const reference = (try reads_domain.proposal(a, session_ref, position)).fields[@backingInt(field)];
    return .{ .length = reference.length, .digest = reference.digest };
}

/// The read Access `candidate` finds the next Action outside any
/// transaction, so a poll that finds none costs one statement. The Store
/// runs no other entry point meanwhile, so the candidate is still
/// current when the write Access `a` attempts it.
pub fn admitNextActionAttempt(
    candidate: anytype,
    a: anytype,
    io: std.Io,
    bash_timeout_ms: u64,
    faults: Faults,
) !?ActionAttemptAdmission {
    var next: next_action_attempt.Result = undefined;
    const names: CoreNames = .of();
    candidate.read(next_action_attempt, .{ .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools, .skill_name = names.skill }, &next);
    try candidate.run();
    const found = next orelse return null;
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    const sender_handle = std.fmt.bytesToHex(random, .lower);
    a.write(attempt_action, .{
        .action_id = found.action_id.get(),
        .timeout_ms = if (found.bash_timeout_override_ms) |override| override.get() else bash_timeout_ms,
        .sender_handle = &sender_handle,
        .session = found.session,
    });
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try a.commit();
    return .{ .permit = .{ .binding = .{
        .turn_id = found.turn_id.get(),
        .parent_operation_id = found.parent_operation_id.get(),
        .action_id = found.action_id.get(),
    } } };
}

/// The unresolved Attempt `binding` names, with its revision and its call,
/// or none: the binding is stale. Its text columns decode in place into
/// the caller's input, through the Row's pointers.
const bash_input = rsql.Read(.{
    .sql = "SELECT item.session_position AS position,revision.workspace,action.session_ref AS session,action.sender_handle," ++
        "action.bash_timeout_ms AS timeout_ms FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session_revision revision ON revision.session_ref=action.session_ref AND revision.revision=action.permission_revision " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action." ++ action_attempted_sql ++
        " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
    .Row = struct {
        position: ?rsql.Positive,
        workspace: *protocol.Bounded(protocol.max_workspace_bytes),
        session: *protocol.Bounded(protocol.max_session_bytes),
        sender_handle: *protocol.Bounded(32),
        timeout_ms: rsql.Positive,
    },
    .cardinality = .optional,
});

/// Round 1 reads the Attempt into `out`, as main's one SELECT did, so a
/// missing, unattempted, resolved or rebound Attempt, or one without its
/// revision or call, is `StaleActionAttemptBinding`. Round 2, which needs
/// the call's position, checks the Proposal and takes the arguments' content
/// from it. `out` is valid only when this returns without error.
pub fn readBashExecutionInput(a: anytype, binding: ActionAttemptBinding, out: *BashExecutionInput) !void {
    var row: bash_input.Row = .{ .position = null, .workspace = &out.workspace, .session = &out.session, .sender_handle = &out.sender_handle, .timeout_ms = undefined };
    var found: store_access.Found = undefined;
    a.readInto(bash_input, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }, &row, &found);
    try a.run();
    if (!found.get()) return error.StaleActionAttemptBinding;
    const position = (row.position orelse return error.CorruptStore).get();
    const reference = (try reads_domain.proposal(a, out.session.slice(), position)).fields[@backingInt(protocol.ProposalField.arguments)];
    out.arguments = .{ .length = reference.length, .digest = reference.digest };
    out.timeout_ms = row.timeout_ms.get();
}

/// The core tool call `binding` names while it waits to run: its Session
/// and whether a stop selected its Turn, or its Session owes one (D38),
/// which runs first and resolves the call.
pub const core_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position," ++
        "(EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
        "OR EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=s.session_ref AND owed.settled=0)) AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 " ++
        "AND action.authorized=1 AND action.attempt_ordinal=0 AND action.resolution_code IS NULL AND " ++ coreCallSql(4),
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64, message_agent_name: [32]u8, read_transcript_name: [32]u8, start_agent_name: [32]u8, find_tools_name: [32]u8, skill_name: [32]u8 },
    .Row = struct { session: rsql.SessionHead, stopped: bool },
    .cardinality = .optional,
});

const resolve_core_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,resolved_at=@now " ++
        "WHERE action_id=?1 AND parent_operation_id=?5 AND session_ref=@session(?6) AND attempt_ordinal=0 AND resolution_code IS NULL",
    .Args = struct { action_id: u64, code: ActionResolutionCode, content_id: u64, position: u64, parent_operation_id: u64, session: rsql.SessionHead },
    // Its round read the call, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Resolves an unattempted core or MCP call `binding` names, at its
/// Session's next position, and lets its Turn continue.
pub fn queueCoreResolution(a: anytype, binding: ActionAttemptBinding, session: rsql.SessionHead, code: ActionResolutionCode, content_id: u64) !void {
    a.write(resolve_core_action, .{
        .action_id = binding.action_id,
        .code = code,
        .content_id = content_id,
        .position = try (try a.positions(session)).take(1),
        .parent_operation_id = binding.parent_operation_id,
        .session = session,
    });
    turn_domain.queueContinuation(a, binding.turn_id, session);
}

/// The Session of the Attempt `binding` names, while it is attempted.
const attempt_session = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position FROM action_operation action JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

const revoke_sender = rsql.Write(.{
    .sql = "UPDATE action_operation SET sender_handle=NULL WHERE action_id=?1 AND parent_operation_id=?2 AND session_ref=@session(?3) AND " ++ action_attempted_sql,
    .Args = struct { action_id: u64, parent_operation_id: u64, session: rsql.SessionHead },
    // Its round read the Attempt, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Clears the Attempt's sender handle, when `binding` names an attempted
/// Action; otherwise changes nothing. On a `.single` Access: the read and
/// the one UPDATE, as main's UPDATE and its touch's Workspace read were,
/// and no transaction.
pub fn revokeActionSender(a: anytype, binding: ActionAttemptBinding) !void {
    var found: attempt_session.Result = undefined;
    a.read(attempt_session, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &found);
    try a.run();
    const row = found orelse return a.abandon(.{});
    a.write(revoke_sender, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .session = row.session });
    try a.commit();
}

/// The first Session stop, in command order, that selected the Turn of the
/// attempted Action `binding` names, or null.
const superseding_stop = rsql.Read(.{
    .sql = "SELECT (SELECT stop.command_key FROM session_stop stop JOIN core_command command ON command.command_key=stop.command_key " ++
        "WHERE stop.selected_turn_id=operation.turn_id ORDER BY command.command_seq LIMIT 1) AS command_key " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { command_key: ?protocol.Bounded(protocol.max_key_bytes) },
    .cardinality = .one,
});

pub fn actionSupersededByStop(a: anytype, binding: ActionAttemptBinding) !?SupersedingControl {
    var stop: superseding_stop.Result = undefined;
    a.read(superseding_stop, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &stop);
    try a.run();
    return .{ .command_key = stop.command_key orelse return null };
}

/// The unresolved Attempt `binding` names: its Turn, and whether a Session
/// stop selected that Turn.
const dispatch_facts = rsql.Read(.{
    .sql = "SELECT operation.turn_id,EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { turn_id: rsql.Positive, stopped: bool },
    .cardinality = .optional,
});

pub fn validateActionDispatch(a: anytype, binding: ActionAttemptBinding) !void {
    var facts: dispatch_facts.Result = undefined;
    a.read(dispatch_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &facts);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.turn_id.get() != binding.turn_id) return error.StaleActionAttemptBinding;
    if (found.stopped) return error.SupersededByControl;
}

/// What settling the Attempt `binding` names depends on: its Session, its
/// Turn, and whether a Session stop selected that Turn.
const settle_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,operation.turn_id," ++
        mcpCallSql("action", "operation") ++ " AS mcp," ++
        "EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive, mcp: bool, stopped: bool },
    .cardinality = .optional,
});

const resolve_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,sender_handle=NULL,resolved_at=@now " ++
        "WHERE action_id=?1 AND parent_operation_id=?5 AND session_ref=@session(?6) AND " ++ action_attempted_sql ++ " AND resolution_code IS NULL",
    .Args = struct { action_id: u64, code: ActionResolutionCode, content_id: u64, position: u64, parent_operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleActionAttemptBinding } },
});

/// Round 1 reads the binding's facts. Round 2 looks up the content the
/// Action settles with: its result, or, when a stop selected the Turn, the
/// cancellation text, together with whether the Turn is ready to close. So
/// a stop never hashes a result it discards, and the common path runs the
/// two reads main did. The write round resolves the Action, closes a
/// stopped Turn its last Action leaves ready, and records a continuation,
/// then commits.
pub fn settleActionAttempt(
    a: anytype,
    binding: ActionAttemptBinding,
    code: ActionResolutionCode,
    result: []const u8,
    faults: Faults,
) !ActionSettlement {
    var facts: settle_facts.Result = undefined;
    a.read(settle_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &facts);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.turn_id.get() != binding.turn_id) return error.StaleActionAttemptBinding;

    // A stop that selected the Turn cancels whatever the Action did.
    const settled: struct { code: ActionResolutionCode, text: []const u8 } =
        if (found.stopped) .{ .code = .cancelled, .text = if (found.mcp) (if (code == .cancelled) result else if (code == .spawn_failed) mcp_stop_not_sent_text else mcp_stop_unknown_text) else content_domain.stop_cancellation_text } else .{ .code = code, .text = result };
    var content: content_domain.Import = .ofBytes(settled.text, false);
    var completion: turn_domain.stopped_turn.Result = null;
    content_domain.lookup(a, &content);
    if (found.stopped) a.read(turn_domain.stopped_turn, .{ .turn_id = binding.turn_id, .resolving_action_id = binding.action_id }, &completion);
    try a.run();

    if (faults.content_import) return error.InjectedContentImportFailure;
    const positions = try a.positions(found.session);
    const content_id = try content_domain.importBytes(a, &content, settled.text);
    a.write(resolve_action, .{
        .action_id = binding.action_id,
        .code = settled.code,
        .content_id = content_id,
        .position = try positions.take(1),
        .parent_operation_id = binding.parent_operation_id,
        .session = found.session,
    });
    try turn_domain.queueStopCompletion(a, completion, binding.turn_id);
    turn_domain.queueContinuation(a, binding.turn_id, found.session);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return if (found.stopped) .session_stop else .effect;
}

/// Unresolved Attempts in id order.
const uncertain_actions = rsql.Read(.{
    .sql = "SELECT action_id FROM action_operation @index(action_operation_unresolved_attempt) " ++
        "WHERE resolution_code IS NULL AND " ++ action_attempted_sql ++ " ORDER BY action_id",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive },
    .cardinality = .each,
});

/// The Session and Turn of the Attempt `action_id`, while it is unresolved.
const uncertain_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,operation.turn_id," ++ mcpCallSql("action", "operation") ++ " AS mcp FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.resolution_code IS NULL AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive, mcp: bool },
    .cardinality = .optional,
});

const resolve_uncertain = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code='indeterminate',resolution_content_id=?2,acceptance_position=?3,resolved_at=@now " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND resolution_code IS NULL AND " ++ action_attempted_sql,
    .Args = struct { action_id: u64, content_id: u64, position: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

pub const mcp_stop_not_sent_text = "Cancelled by Session stop. Failed, not run: the MCP request was not sent.";
pub const mcp_stop_unknown_text = "Cancelled by Session stop. Outcome unknown: the MCP request was sent; it may still be running.";
pub const mcp_indeterminate_text = "Outcome unknown: the Host stopped while this MCP call was running; it was not retried.";

const indeterminate_text = "Bash outcome is indeterminate after Host recovery; the command was not replayed.";

/// `indeterminate_text`'s identity, hashed when the Host is built.
const indeterminate: content_domain.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(indeterminate_text, false);
};

const mcp_indeterminate: content_domain.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(mcp_indeterminate_text, false);
};

/// Picks the first scanned Attempt no execution slot holds.
const UncertainChoice = struct {
    active: ActiveOperationFilter,
    chosen: ?u64 = null,

    pub fn visit(choice: *UncertainChoice, row: *const uncertain_actions.Row) bool {
        if (choice.active.contains(row.action_id.get())) return true;
        choice.chosen = row.action_id.get();
        return false;
    }
};

/// Resolves one Attempt no slot holds as indeterminate. The read Access
/// `candidate` scans outside any transaction, so a pass that finds none
/// costs one statement; the scan stops at the first Attempt `active` does
/// not hold, after at most one more than it can exclude. The write
/// Access `a` reads the Attempt's facts, then whether its stopped Turn is
/// ready, which needs the Turn, then resolves it and commits.
pub fn recoverOneUncertainAction(candidate: anytype, a: anytype, active: ActiveOperationFilter) !bool {
    var choice: UncertainChoice = .{ .active = active };
    candidate.readEach(uncertain_actions, .{}, try std.math.add(u64, active.maximum_exclusions, 1), &choice);
    try candidate.run();
    const action_id = choice.chosen orelse return false;

    var facts: uncertain_facts.Result = undefined;
    var content: content_domain.Import = undefined;
    a.read(uncertain_facts, .{ .action_id = action_id }, &facts);
    try a.run();
    const found = facts orelse return error.ActionSelectionChanged;
    const text = if (found.mcp) mcp_indeterminate_text else indeterminate_text;
    content = if (found.mcp) mcp_indeterminate else indeterminate;
    content_domain.lookup(a, &content);
    const turn_id = found.turn_id.get();
    var completion: turn_domain.stopped_turn.Result = undefined;
    a.read(turn_domain.stopped_turn, .{ .turn_id = turn_id, .resolving_action_id = action_id }, &completion);
    try a.run();

    const positions = try a.positions(found.session);
    const content_id = try content_domain.importBytes(a, &content, text);
    a.write(resolve_uncertain, .{ .action_id = action_id, .content_id = content_id, .position = try positions.take(1), .session = found.session });
    try turn_domain.queueStopCompletion(a, completion, turn_id);
    turn_domain.queueContinuation(a, turn_id, found.session);
    try a.commit();
    return true;
}

const mcp_serial_sql = "NOT EXISTS(SELECT 1 FROM action_operation earlier JOIN model_operation earlier_operation ON earlier_operation.operation_id=earlier.parent_operation_id " ++
    "WHERE earlier.session_ref=action.session_ref AND earlier.resolution_code IS NULL " ++
    "AND (earlier.action_id<action.action_id OR earlier.attempt_ordinal>0) AND " ++ mcpCallSql("earlier", "earlier_operation") ++ ")";

const mcp_facts_sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref,s.workspace_key,s.next_position " ++
    "FROM action_operation action @index(action_operation_executable) " ++
    "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
    "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
    "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
    "AND active.outcome_code IS NULL AND NOT EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=s.session_ref AND owed.settled=0) " ++
    "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) AND " ++ mcpCallSql("action", "operation") ++ " AND " ++ mcp_serial_sql;
const McpFacts = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, session: rsql.SessionHead };
// Start with open Turns' frozen MCP offers, not executable Actions. Bash-only
// offers never open their call ranges; candidate calls seek their Action by
// parent and ordinal. CROSS JOIN keeps that bound before the Action lookup.
const next_mcp_action = rsql.Read(.{
    .sql = "SELECT action.action_id,tool.server " ++
        "FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN session_revision revision ON revision.session_ref=operation.session_ref AND revision.revision=operation.settings_revision " ++
        "CROSS JOIN tool_set_member member ON member.tool_set_id=coalesce(revision.loaded_tool_set_id,revision.tool_set_id) " ++
        "CROSS JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id AND tool.owner='mcp' " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "CROSS JOIN content name ON name.content_id=tool_call.name_content_id AND @payload(name)=@bytes(tool.name) " ++
        "CROSS JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE active.outcome_code IS NULL AND action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=s.session_ref AND owed.settled=0) " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
        "AND " ++ mcp_serial_sql ++ " ORDER BY action.action_id LIMIT 1",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive, server: protocol.Bounded(tool_catalog.max_server_bytes) },
    .cardinality = .optional,
});
pub const next_mcp_action_sql = next_mcp_action.sql;
pub const McpAction = struct { action_id: u64, server: protocol.Bounded(tool_catalog.max_server_bytes) };
pub fn nextMcpAction(a: anytype) !?McpAction {
    var row: next_mcp_action.Result = undefined;
    a.read(next_mcp_action, .{}, &row);
    try a.run();
    const found = row orelse return null;
    return .{ .action_id = found.action_id.get(), .server = found.server };
}
const mcp_facts = rsql.Read(.{
    .sql = mcp_facts_sql ++ " AND action.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = McpFacts,
    .cardinality = .optional,
});
pub fn resolveMcpAction(a: anytype, action_id: u64, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
    var facts: mcp_facts.Result = undefined;
    var content: content_domain.Import = .ofBytes(text, false);
    a.read(mcp_facts, .{ .action_id = action_id }, &facts);
    content_domain.lookup(a, &content);
    try a.run();
    const found = facts orelse {
        // A stop or permission decision may win after selection. No effect
        // was dispatched, so there is nothing left for this Host to resolve.
        try a.commit();
        return;
    };
    if (faults.content_import) return error.InjectedContentImportFailure;
    const content_id = try content_domain.importBytes(a, &content, text);
    try queueCoreResolution(a, .{ .action_id = action_id, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() }, found.session, code, content_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
}

/// Admission commits the attempt and sender before any network effect.
pub fn admitMcpActionAttempt(a: anytype, io: std.Io, action_id: u64, timeout_ms: u64, faults: Faults) !?ActionAttemptBinding {
    var facts: mcp_facts.Result = undefined;
    a.read(mcp_facts, .{ .action_id = action_id }, &facts);
    try a.run();
    const found = facts orelse {
        try a.commit();
        return null;
    };
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    const sender = std.fmt.bytesToHex(random, .lower);
    a.write(attempt_mcp, .{ .action_id = action_id, .sender = &sender, .session = found.session, .timeout_ms = timeout_ms });
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try a.commit();
    return .{ .action_id = action_id, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() };
}
// The column records the timeout this attempt runs under, including MCP.
// The Host resolves it from the server configuration before admission.
const attempt_mcp = rsql.Write(.{
    .sql = "UPDATE action_operation SET " ++ action_attempted_sql ++ ",attempt_at=@now,bash_timeout_ms=?4,sender_handle=?2 WHERE action_id=?1 AND session_ref=@session(?3) AND attempt_ordinal=0 AND resolution_code IS NULL",
    .Args = struct { action_id: u64, sender: []const u8, session: rsql.SessionHead, timeout_ms: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});
const mcp_input = rsql.Read(.{
    .sql = "SELECT item.session_position AS position,action.session_ref AS session,action.sender_handle,@payload(name) AS name,tool.server,schema_content.digest,schema_content.byte_length AS length,action.bash_timeout_ms AS timeout_ms FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "JOIN session_revision revision ON revision.session_ref=operation.session_ref AND revision.revision=operation.settings_revision " ++
        "JOIN tool_set_member member ON member.tool_set_id=coalesce(revision.loaded_tool_set_id,revision.tool_set_id) " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id AND @bytes(tool.name)=@payload(name) AND tool.owner='mcp' " ++
        "JOIN content schema_content ON schema_content.content_id=tool.input_schema_content_id " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action." ++ action_attempted_sql ++
        " AND action.resolution_code IS NULL AND " ++ mcpCallSql("action", "operation"),
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
    .Row = struct { position: ?rsql.Positive, session: *protocol.Bounded(protocol.max_session_bytes), sender_handle: *protocol.Bounded(32), name: *protocol.Bounded(protocol.max_tool_name_bytes), server: *protocol.Bounded(tool_catalog.max_server_bytes), digest: [32]u8, length: u64, timeout_ms: rsql.Positive },
    .cardinality = .optional,
});
test "MCP execution input uses each engine's tool-name content layout" {
    const mysql = comptime mcp_input.mysql.prepared();
    // A tool name fits one content chunk. Both its projection and catalog
    // comparison must use that chunk on MySQL, not SQLite's payload column.
    const name_bytes = "coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=name.content_id AND content_chunk.chunk_index=0),X'')";
    try std.testing.expect(std.mem.indexOf(u8, mcp_input.sql, "name.payload AS name") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_input.sql, "CAST(tool.name AS BLOB)=name.payload") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, mysql, "name.payload"));
    try std.testing.expect(std.mem.indexOf(u8, mysql, name_bytes ++ " AS name") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql, "CAST(tool.name AS BINARY)=" ++ name_bytes) != null);
}

const session_parent = rsql.Read(.{
    .sql = "SELECT parent_ref AS parent FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { parent: ?protocol.Bounded(protocol.max_session_bytes) },
    .cardinality = .optional,
});
pub fn readMcpExecutionInput(a: anytype, binding: ActionAttemptBinding, out: *McpExecutionInput) !void {
    var row: mcp_input.Row = .{ .position = null, .session = &out.session, .sender_handle = &out.sender_handle, .name = &out.name, .server = &out.server, .digest = undefined, .length = undefined, .timeout_ms = undefined };
    var found: store_access.Found = undefined;
    a.readInto(mcp_input, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }, &row, &found);
    try a.run();
    if (!found.get()) return error.StaleActionAttemptBinding;
    out.input_schema = .{ .length = row.length, .digest = row.digest };
    out.timeout_ms = row.timeout_ms.get();
    const position = (row.position orelse return error.CorruptStore).get();
    const reference = (try reads_domain.proposal(a, out.session.slice(), position)).fields[@backingInt(protocol.ProposalField.arguments)];
    out.arguments = .{ .length = reference.length, .digest = reference.digest };
    out.root = out.session;
    out.parent = null;
    var first = true;
    while (true) {
        var ancestry: session_parent.Result = undefined;
        a.read(session_parent, .{ .session = out.root.slice() }, &ancestry);
        try a.run();
        const parent = (ancestry orelse return error.CorruptStore).parent;
        if (first) out.parent = parent;
        first = false;
        out.root = parent orelse break;
    }
}
