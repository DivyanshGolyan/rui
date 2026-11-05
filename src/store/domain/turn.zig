//! Turn lifecycle: closing a Turn with its outcome and recording
//! continuations.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const model_admission_domain = @import("model_admission.zig");
const continues_without_input_sql = model_admission_domain.continues_without_input_sql;
const forward_domain = @import("forward.zig");
const failure_class = @import("../../failure_class.zig");

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

    pub const completed_code = "completed";

    /// The saved code of every outcome but a failure, which saves its own.
    fn fixedCode(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .completed => completed_code,
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

    /// The ending the feed names. A cancelled Turn was `stopped` when a
    /// Session stop selected it, and otherwise interrupted by a Model
    /// Interruption.
    pub fn ending(outcome: TurnOutcome, stopped: bool) protocol.TurnEnding {
        return switch (outcome) {
            .completed => .done,
            .cancelled => if (stopped) .stopped else .interrupted,
            .retry_exhausted => .provider_unavailable,
            .resource_exceeded => .context_full,
            .failed => |failed| switch (failure_class.of(failed.code)) {
                .policy, .quota, .plan, .model, .sign_in, .api_key, .refused => .provider_refused,
                .unreachable_provider, .retries_exhausted => .provider_unavailable,
                .overflow => .context_full,
                .interrupted, .other => .failed,
            },
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

/// Ends an open Turn; `otherwise` is the guard's error when it is not
/// open. One text, so the statement differs only in what it reports.
fn CloseTurn(comptime otherwise: anyerror) type {
    return rsql.Write(.{
        .sql = "UPDATE turn SET outcome_code=?2,outcome_content_id=?3,outcome_position=?4,outcome_at=@now " ++
            "WHERE turn_id=?1 AND session_ref=@session(?5) AND outcome_code IS NULL",
        .Args = struct { turn_id: u64, code: []const u8, content_id: ?u64, position: u64, session: rsql.SessionHead },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = otherwise } },
    });
}

const record_continuation = rsql.Write(.{
    .sql = "UPDATE turn SET continuation_operation_id=operation_id WHERE turn_id=?1 AND session_ref=@session(?2) AND outcome_code IS NULL " ++
        "AND @distinct(continuation_operation_id,operation_id) AND EXISTS(SELECT 1 FROM model_operation current " ++
        "WHERE current.operation_id=turn.operation_id AND current.session_ref=turn.session_ref AND " ++ continues_without_input_sql ++ ")",
    .Args = struct { turn_id: u64, session: rsql.SessionHead },
    .expect = .{ .at_most = 1 },
});

/// Queues ending the open Turn `turn_id` of `positions`' Session with
/// `outcome`, at the Session's next position. Its round read the Turn
/// open, under the single writer, so a closed one is a corrupt Store.
pub fn queueClose(a: anytype, positions: *store_access.Positions, turn_id: u64, outcome: TurnOutcome) !void {
    return queueCloseOr(a, positions, turn_id, outcome, error.CorruptStore);
}

/// `queueClose`, reporting `otherwise` when the Turn is not open: a model
/// interruption's target changed, as on main.
pub fn queueCloseOr(a: anytype, positions: *store_access.Positions, turn_id: u64, outcome: TurnOutcome, comptime otherwise: anyerror) !void {
    const content_id = outcome.content();
    // A failure code spelling a fixed outcome would read back as that outcome.
    std.debug.assert(std.meta.activeTag(TurnOutcome.decode(outcome.code(), content_id) catch unreachable) == std.meta.activeTag(outcome));
    a.write(CloseTurn(otherwise), .{
        .turn_id = turn_id,
        .code = outcome.code(),
        .content_id = if (content_id) |id| @intCast(id) else null,
        .position = try positions.take(1),
        .session = positions.head,
    });
    a.write(owe_ending, .{ .turn_id = turn_id, .session = positions.head.ref[0..] });
    try forward_domain.queue(a, &positions.head.ref, &positions.head.ref, .ending, turn_id);
}

/// An attached child's Turn ending is owed to its parent as a Message
/// (D39), unless the child already owes a stop: its parent stopped, and
/// delivery would wake it again (D139). The Host delivers it
/// (`Store.nextCoreWork`).
const owe_ending = rsql.Write(.{
    .sql = "INSERT INTO session_ending_owed(turn_id,delivered) SELECT ?1,0 FROM session WHERE session_ref=?2 AND parent_ref IS NOT NULL " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop_owed WHERE child_ref=?2 AND settled=0)",
    .Args = struct { turn_id: u64, session: []const u8 },
    .expect = .{ .at_most = 1 },
});

/// How many attached children of the Session the parameter `parent` names
/// do not owe a stop yet: what `queueOwedStops` inserts.
pub fn unowedChildrenSql(comptime parent: []const u8) []const u8 {
    return "(SELECT count(*) FROM session child @index(session_parent) WHERE child.parent_ref=" ++ parent ++
        " AND NOT EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=child.session_ref AND owed.settled=0))";
}

const owe_child_stops = rsql.Write(.{
    .sql = "INSERT INTO session_stop_owed(child_ref,cause_ref,cause_position,settled) SELECT child.session_ref,?1,?2,0 FROM session child " ++
        "WHERE child.parent_ref=?1 AND NOT EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=child.session_ref AND owed.settled=0)",
    .Args = struct { parent: []const u8, position: u64 },
    .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
});

/// Queues the stop each of `parent`'s `unowed` attached children owes
/// (D38), because `parent` stopped or ran out of context at `position`.
/// The Host runs each as the child's own stop (`Store.nextCoreWork`).
pub fn queueOwedStops(a: anytype, parent: *const [protocol.session_id_bytes]u8, position: u64, unowed: u64) void {
    if (unowed != 0) a.writeCount(owe_child_stops, .{ .parent = parent, .position = position }, unowed);
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
