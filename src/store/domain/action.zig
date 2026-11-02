//! Action Attempts: admitting, dispatching, settling and recovering tool actions.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const content_domain = @import("content.zig");
const reads_domain = @import("reads.zig");
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;
const Ordinary = store_core.Ordinary;

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
        "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
        "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, bash_timeout_override_ms: ?rsql.Positive, session: rsql.SessionHead },
    .cardinality = .optional,
});
pub const next_action_attempt_sql = next_action_attempt.sql;

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

pub fn actionContent(self: *Store, session_ref: []const u8, action_id: u64, comptime column: []const u8) !ContentReference {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    if (action_id == 0 or action_id > std.math.maxInt(i64)) return error.ActionNotFound;
    return entry.finish(Ordinary.action, actionContentLocked(self, session_ref, action_id, column));
}

fn actionContentLocked(self: *Store, session_ref: []const u8, action_id: u64, comptime column: []const u8) !ContentReference {
    const statement = try store_core.cached(
        self,
        "SELECT tool_call." ++ column ++ ",item.session_position FROM action_operation action JOIN model_tool_call tool_call " ++
            "ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
            "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
            "WHERE action.action_id=?1 AND action.session_ref=?2",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, action_id);
    try sqlite.bindText(statement, 2, session_ref);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => return error.ActionNotFound,
        c.SQLITE_ROW => {},
        else => return error.ActionReadFailed,
    }
    const content_id = c.sqlite3_column_int64(statement, 0);
    if (content_id <= 0) return error.CorruptStore;
    const position = try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
    _ = try reads_domain.proposalLocked(self, session_ref, @intCast(position));
    const metadata = try content_domain.readPublicContentMetadata(self, content_id);
    return .{ .length = metadata.length, .digest = metadata.digest };
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

pub fn readBashExecutionInputLocked(self: *Store, binding: ActionAttemptBinding, out: *BashExecutionInput) !void {
    const statement = try store_core.cached(
        self,
        "SELECT revision.workspace,tool_call.arguments_content_id,action.bash_timeout_ms,operation.turn_id,action.session_ref,action.sender_handle " ++
            "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
            "JOIN session_revision revision ON revision.session_ref=action.session_ref AND revision.revision=action.permission_revision " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
            "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " " ++
            "AND action.resolution_code IS NULL",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.action_id);
    try sqlite.bindU64(statement, 2, binding.parent_operation_id);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
    if (step != c.SQLITE_ROW) return error.ActionReadFailed;
    if (c.sqlite3_column_int64(statement, 3) != binding.turn_id) return error.StaleActionAttemptBinding;
    try sqlite.readText(statement, 0, &out.workspace);
    const content_id = c.sqlite3_column_int64(statement, 1);
    const timeout_ms = c.sqlite3_column_int64(statement, 2);
    if (content_id <= 0 or timeout_ms <= 0) return error.CorruptStore;
    try sqlite.readText(statement, 4, &out.session);
    try sqlite.readText(statement, 5, &out.sender_handle);
    out.arguments = try actionContentLocked(self, out.session.slice(), binding.action_id, "arguments_content_id");
    out.timeout_ms = @intCast(timeout_ms);
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
/// Action; otherwise changes nothing.
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

pub fn recoverOneUncertainActionLocked(self: *Store, active: ActiveOperationFilter) !bool {
    const limit = try std.math.add(usize, active.maximum_exclusions, 1);
    var selected: ?u64 = null;
    {
        const select = try store_core.cached(
            self,
            "SELECT action_id,parent_operation_id FROM action_operation INDEXED BY action_operation_unresolved_attempt " ++
                "WHERE resolution_code IS NULL AND attempt_ordinal=1 ORDER BY action_id",
        );
        defer sqlite.resetCached(select);
        var scanned: usize = 0;
        while (scanned < limit) : (scanned += 1) switch (c.sqlite3_step(select)) {
            c.SQLITE_ROW => {
                const action_id = c.sqlite3_column_int64(select, 0);
                const operation_id = c.sqlite3_column_int64(select, 1);
                if (action_id <= 0 or operation_id <= 0) return error.CorruptStore;
                if (!active.contains(@intCast(action_id))) {
                    selected = @intCast(action_id);
                    break;
                }
            },
            c.SQLITE_DONE => break,
            else => return error.ActionReadFailed,
        };
    }
    const action_id = selected orelse return false;
    try store_core.begin(self);
    const action = try store_core.cached(self, "SELECT session_ref FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL AND attempt_ordinal=1");
    defer sqlite.resetCached(action);
    try sqlite.bindU64(action, 1, action_id);
    if (c.sqlite3_step(action) != c.SQLITE_ROW) return error.ActionSelectionChanged;
    var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(action, 0, &session_ref);
    const content_id = try content_domain.importBytesContent(
        self,
        "Bash outcome is indeterminate after Host recovery; the command was not replayed.",
        false,
        false,
    );
    const position = try turn_domain.claimSessionPosition(self, session_ref.slice());
    const update = try store_core.cached(
        self,
        "UPDATE action_operation SET resolution_code='indeterminate',resolution_content_id=?2,acceptance_position=?3,resolved_at=unixepoch() " ++
            "WHERE action_id=?1 AND resolution_code IS NULL AND attempt_ordinal=1",
    );
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, action_id);
    try sqlite.bindI64(update, 2, content_id);
    try sqlite.bindU64(update, 3, position);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
    const turn_statement = try store_core.cached(
        self,
        "SELECT operation.turn_id FROM action_operation action JOIN model_operation operation " ++
            "ON operation.operation_id=action.parent_operation_id WHERE action.action_id=?1",
    );
    defer sqlite.resetCached(turn_statement);
    try sqlite.bindU64(turn_statement, 1, action_id);
    if (c.sqlite3_step(turn_statement) != c.SQLITE_ROW) return error.CorruptStore;
    const turn_id = c.sqlite3_column_int64(turn_statement, 0);
    if (turn_id <= 0) return error.CorruptStore;
    try turn_domain.completeStoppedTurnIfReady(self, @intCast(turn_id));
    try turn_domain.recordContinuation(self, @intCast(turn_id), session_ref.slice());
    try store_core.commit(self);
    return true;
}
