//! Action Attempts: admitting, dispatching, settling and recovering tool actions.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
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
/// Reads only `action_operation_executable`, so an Action waiting for
/// permission costs admission nothing.
pub const next_action_attempt_sql =
    "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms FROM action_operation action " ++
    "INDEXED BY action_operation_executable JOIN model_operation operation " ++
    "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
    "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
    "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
    "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
    "ORDER BY action.action_id LIMIT 1";

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

pub fn admitNextActionAttemptLocked(
    self: *Store,
    bash_timeout_ms: u64,
    faults: Faults,
) !?ActionAttemptAdmission {
    const select = try store_core.cached(self, next_action_attempt_sql);
    defer sqlite.resetCached(select);
    const step = c.sqlite3_step(select);
    if (step == c.SQLITE_DONE) return null;
    if (step != c.SQLITE_ROW) return error.ActionSelectionFailed;
    const action_id = c.sqlite3_column_int64(select, 0);
    const parent_operation_id = c.sqlite3_column_int64(select, 1);
    const turn_id = c.sqlite3_column_int64(select, 2);
    if (action_id <= 0 or parent_operation_id <= 0 or turn_id <= 0) return error.CorruptStore;
    const selected_timeout_ms = if (try sqlite.readNullablePositiveI64(select, 3)) |override|
        @as(u64, @intCast(override))
    else
        bash_timeout_ms;
    // The held Store mutex excludes every other writer, so the candidate
    // read outside the transaction is still current inside it.
    _ = c.sqlite3_reset(select);
    try store_core.execute(self, "BEGIN IMMEDIATE");
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(self.io, &random);
    const sender_handle = std.fmt.bytesToHex(random, .lower);
    const update = try store_core.cached(
        self,
        "UPDATE action_operation SET " ++ action_attempted_sql ++ ",attempt_at=unixepoch(),bash_timeout_ms=?2,sender_handle=?3 " ++
            "WHERE action_id=?1 AND authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0 RETURNING session_ref",
    );
    defer sqlite.resetCached(update);
    try sqlite.bindI64(update, 1, action_id);
    try sqlite.bindU64(update, 2, selected_timeout_ms);
    try sqlite.bindText(update, 3, &sender_handle);
    if (try store_core.stepTouching(self, update) != 1) return error.ActionSelectionChanged;
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try store_core.execute(self, "COMMIT");
    return .{ .permit = .{ .binding = .{
        .turn_id = @intCast(turn_id),
        .parent_operation_id = @intCast(parent_operation_id),
        .action_id = @intCast(action_id),
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

pub fn revokeActionSenderLocked(self: *Store, binding: ActionAttemptBinding) !void {
    const statement = try store_core.cached(self, "UPDATE action_operation SET sender_handle=NULL WHERE action_id=?1 AND parent_operation_id=?2 AND " ++ action_attempted_sql ++ " RETURNING session_ref");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.action_id);
    try sqlite.bindU64(statement, 2, binding.parent_operation_id);
    _ = try store_core.stepTouching(self, statement);
}

pub fn actionSupersededByStopLocked(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
    const statement = try store_core.cached(
        self,
        "SELECT (SELECT stop.command_key FROM session_stop stop JOIN core_command command ON command.command_key=stop.command_key " ++
            "WHERE stop.selected_turn_id=operation.turn_id ORDER BY command.command_seq LIMIT 1) " ++
            "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
            "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql,
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.action_id);
    try sqlite.bindU64(statement, 2, binding.parent_operation_id);
    const step = c.sqlite3_step(statement);
    if (step != c.SQLITE_ROW) return if (step == c.SQLITE_DONE) error.CorruptStore else error.ActionReadFailed;
    if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return null;
    var command_key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try sqlite.readText(statement, 0, &command_key);
    return .{ .command_key = command_key };
}

pub fn validateActionDispatchLocked(self: *Store, binding: ActionAttemptBinding) !void {
    const statement = try store_core.cached(
        self,
        "SELECT operation.turn_id,EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
            "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
            "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " " ++
            "AND action.resolution_code IS NULL",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.action_id);
    try sqlite.bindU64(statement, 2, binding.parent_operation_id);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
    if (step != c.SQLITE_ROW) return error.ActionReadFailed;
    if (c.sqlite3_column_int64(statement, 0) != binding.turn_id) return error.StaleActionAttemptBinding;
    if (c.sqlite3_column_int(statement, 1) != 0) return error.SupersededByControl;
}

pub fn settleActionAttemptLocked(
    self: *Store,
    binding: ActionAttemptBinding,
    code: ActionResolutionCode,
    result: []const u8,
    faults: Faults,
) !ActionSettlement {
    try store_core.execute(self, "BEGIN IMMEDIATE");
    const statement = try store_core.cached(
        self,
        "SELECT action.session_ref,operation.turn_id," ++
            "EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
            "FROM action_operation action JOIN model_operation operation " ++
            "ON operation.operation_id=action.parent_operation_id " ++
            "WHERE action.action_id=?1 AND action.parent_operation_id=?2 " ++
            "AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.action_id);
    try sqlite.bindU64(statement, 2, binding.parent_operation_id);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
    if (step != c.SQLITE_ROW) return error.ActionReadFailed;
    var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 0, &session_ref);
    if (c.sqlite3_column_int64(statement, 1) != binding.turn_id) return error.StaleActionAttemptBinding;
    const stopped = c.sqlite3_column_int(statement, 2);
    if (stopped != 0 and stopped != 1) return error.CorruptStore;
    const effective_code: ActionResolutionCode = if (stopped == 1) .cancelled else code;
    const effective_result = if (stopped == 1) "Cancelled by Session stop." else result;
    const content_id = try content_domain.importBytesContent(self, effective_result, false, faults.content_import);
    const position = try turn_domain.claimSessionPosition(self, session_ref.slice());
    const update = try store_core.cached(
        self,
        "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,sender_handle=NULL,resolved_at=unixepoch() " ++
            "WHERE action_id=?1 AND parent_operation_id=?5 AND " ++ action_attempted_sql ++ " AND resolution_code IS NULL",
    );
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, binding.action_id);
    try sqlite.bindText(update, 2, @tagName(effective_code));
    try sqlite.bindI64(update, 3, content_id);
    try sqlite.bindU64(update, 4, position);
    try sqlite.bindU64(update, 5, binding.parent_operation_id);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.StaleActionAttemptBinding;
    try turn_domain.completeStoppedTurnIfReady(self, binding.turn_id);
    try turn_domain.recordContinuation(self, binding.turn_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    return if (stopped == 1) .session_stop else .effect;
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
    try store_core.execute(self, "BEGIN IMMEDIATE");
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
    try turn_domain.recordContinuation(self, @intCast(turn_id));
    try store_core.execute(self, "COMMIT");
    return true;
}
