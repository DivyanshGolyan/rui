//! Turn lifecycle: closing a Turn with its outcome, recording continuations,
//! and claiming Session positions.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const Access = store_access.Access;
const rsql = @import("../rsql.zig");
const model_admission_domain = @import("model_admission.zig");
const sqlite = @import("../sqlite.zig");
const c = sqlite.c;
const continues_without_input_sql = model_admission_domain.continues_without_input_sql;

/// How a Turn ended. `turn.outcome_code` saves `code()` and
/// `turn.outcome_content_id` saves `content()`: a completed Turn's answer,
/// or a failed one's report, the provider's own words for why. Readers
/// `decode` the saved pair once and switch on the result, so a new outcome
/// is handled at every reader.
pub const TurnOutcome = union(enum) {
    completed: i64,
    cancelled,
    /// The settling Attempt's report, when the provider sent one.
    retry_exhausted: ?i64,
    resource_exceeded: ?i64,
    /// A terminal model failure, saved under its own failure code.
    failed: Failed,

    const Failed = struct { code: []const u8, report: ?i64 };
    pub const Tag = std.meta.Tag(TurnOutcome);

    /// The saved code of every outcome but a failure, which saves its own.
    fn fixedCode(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .completed => "completed",
            .cancelled => "cancelled",
            .retry_exhausted => "retry_exhausted",
            .resource_exceeded => "ResourceExceeded",
            .failed => null,
        };
    }

    pub fn code(outcome: TurnOutcome) []const u8 {
        return fixedCode(outcome) orelse outcome.failed.code;
    }

    pub fn content(outcome: TurnOutcome) ?i64 {
        return switch (outcome) {
            .completed => |answer| answer,
            .retry_exhausted, .resource_exceeded => |report| report,
            .failed => |failed| failed.report,
            .cancelled => null,
        };
    }

    /// The inverse of `code()` and `content()`. A `failed` result borrows
    /// `saved`.
    pub fn decode(saved: []const u8, content_id: ?i64) error{CorruptStore}!TurnOutcome {
        if (saved.len == 0) return error.CorruptStore;
        const tag: Tag = for (std.enums.values(Tag)) |candidate| {
            if (fixedCode(candidate)) |fixed| if (std.mem.eql(u8, fixed, saved)) break candidate;
        } else .failed;
        return switch (tag) {
            .completed => .{ .completed = content_id orelse return error.CorruptStore },
            .retry_exhausted => .{ .retry_exhausted = content_id },
            .resource_exceeded => .{ .resource_exceeded = content_id },
            .failed => .{ .failed = .{ .code = saved, .report = content_id } },
            .cancelled => if (content_id == null) .cancelled else error.CorruptStore,
        };
    }
};

/// The open Turn's Session, when `operation_id` (if given) is its Operation.
const open_turn = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position FROM turn t JOIN session s ON s.session_ref=t.session_ref " ++
        "WHERE t.turn_id=?1 AND t.outcome_code IS NULL AND (?2 IS NULL OR t.operation_id=?2)",
    .Args = struct { turn_id: u64, operation_id: ?u64 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

/// A row exactly when a Session stop selected the open Turn and every
/// Action of its Operation is resolved, except `resolving_action_id`, which
/// the same transaction resolves.
pub const stopped_turn = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position FROM turn t JOIN session s ON s.session_ref=t.session_ref " ++
        "WHERE t.turn_id=?1 AND t.outcome_code IS NULL " ++
        "AND EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=t.turn_id) " ++
        "AND NOT EXISTS(SELECT 1 FROM action_operation action " ++
        "WHERE action.parent_operation_id=t.operation_id AND action.resolution_code IS NULL AND action.action_id<>?2)",
    .Args = struct { turn_id: u64, resolving_action_id: u64 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

const close_turn = rsql.Write(.{
    .sql = "UPDATE turn SET outcome_code=?2,outcome_content_id=?3,outcome_position=?4,outcome_at=@now " ++
        "WHERE turn_id=?1 AND session_ref=@session(?5) AND outcome_code IS NULL",
    .Args = struct { turn_id: u64, code: []const u8, content_id: ?u64, position: u64, session: rsql.SessionHead },
    // Its round read the Turn open, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const record_continuation = rsql.Write(.{
    .sql = "UPDATE turn SET continuation_operation_id=operation_id WHERE turn_id=?1 AND session_ref=@session(?2) AND outcome_code IS NULL " ++
        "AND @distinct(continuation_operation_id,operation_id) AND EXISTS(SELECT 1 FROM model_operation current " ++
        "WHERE current.operation_id=turn.operation_id AND " ++ continues_without_input_sql ++ ")",
    .Args = struct { turn_id: u64, session: rsql.SessionHead },
    .expect = .{ .at_most = 1 },
});

/// Queues ending the open Turn `turn_id` of `positions`' Session with
/// `outcome`, at the Session's next position.
pub fn queueClose(a: anytype, positions: *store_access.Positions, turn_id: u64, outcome: TurnOutcome) !void {
    const content_id = outcome.content();
    // A failure code spelling a fixed outcome would read back as that outcome.
    std.debug.assert(std.meta.activeTag(TurnOutcome.decode(outcome.code(), content_id) catch unreachable) == std.meta.activeTag(outcome));
    a.write(close_turn, .{
        .turn_id = turn_id,
        .code = outcome.code(),
        .content_id = if (content_id) |id| @intCast(id) else null,
        .position = try positions.take(1),
        .session = positions.head,
    });
}

/// After a `stopped_turn` round: cancels the Turn it found ready.
pub fn queueStopCompletion(a: anytype, ready: stopped_turn.Result, turn_id: u64) !void {
    const row = ready orelse return;
    try queueClose(a, try a.positions(row.session), turn_id, .cancelled);
}

/// Every writer that can let an active Turn continue without input queues
/// this in its transaction; tool continuation selection reads only the
/// stored fact. Admitting the Turn's next Operation retires it.
pub fn queueContinuation(a: anytype, turn_id: u64, session: rsql.SessionHead) void {
    a.write(record_continuation, .{ .turn_id = turn_id, .session = session });
}

/// `queueStopCompletion` for unconverted code, inside its transaction.
pub fn completeStoppedTurnIfReady(self: *Store, turn_id: u64) !void {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var ready: stopped_turn.Result = undefined;
    a.read(stopped_turn, .{ .turn_id = turn_id, .resolving_action_id = 0 }, &ready);
    try a.run();
    try queueStopCompletion(&a, ready, turn_id);
    try a.apply();
}

/// `queueContinuation` for unconverted code, inside its transaction.
pub fn recordContinuation(self: *Store, turn_id: u64) !void {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var open: open_turn.Result = undefined;
    a.read(open_turn, .{ .turn_id = turn_id, .operation_id = null }, &open);
    try a.run();
    const row = open orelse return;
    queueContinuation(&a, turn_id, row.session);
    try a.apply();
}

pub fn turnIsComplete(self: *Store, turn_id: u64) !bool {
    const statement = try store_core.cached(self, "SELECT outcome_code FROM turn WHERE turn_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, turn_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    return c.sqlite3_column_type(statement, 0) != c.SQLITE_NULL;
}

/// The Session's next position, or null when it does not exist: what page
/// cursors and existence checks need, without its 4.6 KB configuration.
pub fn sessionNextPosition(self: *Store, session_ref: []const u8) !?u64 {
    const statement = try store_core.cached(self, "SELECT next_position FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    const step_result = c.sqlite3_step(statement);
    if (step_result == c.SQLITE_DONE) return null;
    if (step_result != c.SQLITE_ROW) return error.SessionReadFailed;
    const next_position = c.sqlite3_column_int64(statement, 0);
    if (next_position <= 0) return error.CorruptStore;
    return @intCast(next_position);
}

/// The only code that advances `session.next_position`. Claims `count`
/// consecutive positions and returns the first. Called only inside the
/// owning write transaction; no separate frontier.
pub fn claimSessionPositions(self: *Store, session: []const u8, count: u64) !u64 {
    // Every activity row claims here, so every writer of one touches.
    try store_core.touch(self, session);
    if (count > std.math.maxInt(i64)) return error.SessionPositionExhausted;
    // A read then a write: UPDATE RETURNING would buffer its row in a
    // temporary b-tree on every claim.
    const select = try store_core.cached(self, "SELECT next_position FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(select);
    try sqlite.bindText(select, 1, session);
    if (c.sqlite3_step(select) != c.SQLITE_ROW) return error.SessionPositionExhausted;
    const position = try sqlite.readNullablePositiveI64(select, 0) orelse return error.CorruptStore;
    const claimed: i64 = @intCast(count);
    if (position > std.math.maxInt(i64) - claimed) return error.SessionPositionExhausted;
    const update = try store_core.cached(self, "UPDATE session SET next_position=?2 WHERE session_ref=?1 AND next_position=?3");
    defer sqlite.resetCached(update);
    try sqlite.bindText(update, 1, session);
    try sqlite.bindI64(update, 2, position + claimed);
    try sqlite.bindI64(update, 3, position);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.CorruptStore;
    return @intCast(position);
}

pub fn claimSessionPosition(self: *Store, session: []const u8) !u64 {
    return claimSessionPositions(self, session, 1);
}

/// Ends an open Turn, saving its outcome and the position that orders it
/// in Session activity together. `operation_id` names the Operation the
/// caller expects the Turn to own. Returns false when the Turn is already
/// closed or owned by another Operation. `queueClose` for unconverted code,
/// inside its transaction.
pub fn closeTurn(self: *Store, turn_id: u64, operation_id: ?u64, outcome: TurnOutcome) !bool {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var open: open_turn.Result = undefined;
    a.read(open_turn, .{ .turn_id = turn_id, .operation_id = operation_id }, &open);
    try a.run();
    const row = open orelse return false;
    try queueClose(&a, try a.positions(row.session), turn_id, outcome);
    try a.apply();
    return true;
}
