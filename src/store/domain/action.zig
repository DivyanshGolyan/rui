//! Action Attempts: admitting, dispatching, settling and recovering tool actions.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");
const reads_domain = @import("reads.zig");
const sqlite = @import("../sqlite.zig");
const store_access = @import("../access.zig");
const turn_domain = @import("turn.zig");
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;

/// Matches the ordinal the Store issues an Action Attempt, so statements
/// compare it as a literal rather than a bound value.
const action_attempted_sql = std.fmt.comptimePrint("attempt_ordinal={d}", .{attempt.action_attempt_ordinal});
/// The next Action ready for an Attempt, with its Session. Reads only
/// `action_operation_executable`, so an Action waiting for permission costs
/// admission nothing.
const next_action_attempt = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms,s.session_ref,s.workspace_key,s.next_position " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.tool_kind=1 AND action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, bash_timeout_override_ms: ?rsql.Positive, session: rsql.SessionHead },
    .cardinality = .optional,
});
pub const next_action_attempt_sql = next_action_attempt.sql;

/// The next core tool call ready to run (D24), as `next_action_attempt`
/// finds Bash's: decided, never attempted, of an open Turn no stop selected.
const next_core_action = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref AS session " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.tool_kind=2 AND action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, session: protocol.Bounded(protocol.max_session_bytes) },
    .cardinality = .optional,
});

/// A core tool call to run: which Action it is, its Session, and its
/// arguments' content.
pub const CoreActionInput = struct {
    binding: ActionAttemptBinding,
    session: protocol.Bounded(protocol.max_session_bytes),
    arguments: ContentReference,
};

/// The next core tool call to run, or null. It writes nothing: the core
/// command that runs it resolves it in one transaction, so a call read
/// here and never run is simply read again.
pub fn nextCoreAction(a: anytype) !?CoreActionInput {
    var next: next_core_action.Result = undefined;
    a.read(next_core_action, .{}, &next);
    try a.run();
    const found = next orelse return null;
    return .{
        .binding = .{ .turn_id = found.turn_id.get(), .parent_operation_id = found.parent_operation_id.get(), .action_id = found.action_id.get() },
        .session = found.session,
        .arguments = try actionContent(a, found.session.slice(), found.action_id.get(), .arguments),
    };
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
/// transaction, so a poll that finds none costs one statement. The held
/// Store mutex excludes every other writer, so the candidate is still
/// current when the write Access `a` attempts it.
pub fn admitNextActionAttempt(
    candidate: anytype,
    a: anytype,
    io: std.Io,
    bash_timeout_ms: u64,
    faults: Faults,
) !?ActionAttemptAdmission {
    var next: next_action_attempt.Result = undefined;
    candidate.read(next_action_attempt, .{}, &next);
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
/// and whether a stop selected its Turn.
pub const core_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position," ++
        "EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action.tool_kind=2 " ++
        "AND action.authorized=1 AND action.attempt_ordinal=0 AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
    .Row = struct { session: rsql.SessionHead, stopped: bool },
    .cardinality = .optional,
});

const resolve_core_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,resolved_at=@now " ++
        "WHERE action_id=?1 AND parent_operation_id=?5 AND session_ref=@session(?6) AND tool_kind=2 AND attempt_ordinal=0 AND resolution_code IS NULL",
    .Args = struct { action_id: u64, code: ActionResolutionCode, content_id: u64, position: u64, parent_operation_id: u64, session: rsql.SessionHead },
    // Its round read the call, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Resolves the core tool call `binding` names with its result, at its
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
        "EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive, stopped: bool },
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
        if (found.stopped) .{ .code = .cancelled, .text = content_domain.stop_cancellation_text } else .{ .code = code, .text = result };
    var content: content_domain.Import = if (found.stopped) content_domain.stop_cancellation else .ofBytes(result, false);
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
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,operation.turn_id FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.resolution_code IS NULL AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive },
    .cardinality = .optional,
});

const resolve_uncertain = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code='indeterminate',resolution_content_id=?2,acceptance_position=?3,resolved_at=@now " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND resolution_code IS NULL AND " ++ action_attempted_sql,
    .Args = struct { action_id: u64, content_id: u64, position: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

const indeterminate_text = "Bash outcome is indeterminate after Host recovery; the command was not replayed.";

/// `indeterminate_text`'s identity, hashed when the Host is built.
const indeterminate: content_domain.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(indeterminate_text, false);
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
    var content = indeterminate;
    a.read(uncertain_facts, .{ .action_id = action_id }, &facts);
    content_domain.lookup(a, &content);
    try a.run();
    const found = facts orelse return error.ActionSelectionChanged;
    const turn_id = found.turn_id.get();
    var completion: turn_domain.stopped_turn.Result = undefined;
    a.read(turn_domain.stopped_turn, .{ .turn_id = turn_id, .resolving_action_id = action_id }, &completion);
    try a.run();

    const positions = try a.positions(found.session);
    const content_id = try content_domain.importBytes(a, &content, indeterminate_text);
    a.write(resolve_uncertain, .{ .action_id = action_id, .content_id = content_id, .position = try positions.take(1), .session = found.session });
    try turn_domain.queueStopCompletion(a, completion, turn_id);
    turn_domain.queueContinuation(a, turn_id, found.session);
    try a.commit();
    return true;
}
