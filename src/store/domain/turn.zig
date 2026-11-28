const std = @import("std");
const turn_ending = @import("../../turn_ending.zig");
const session_id = @import("../../session_id.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const model_admission_domain = @import("model_admission.zig");
const continues_without_input_sql = model_admission_domain.continues_without_input_sql;
const failure_class = @import("../../failure_class.zig");
const failure_report = @import("../../failure_report.zig");
const Bounded = @import("../../bounded.zig").Bounded;

/// How a Turn ended. A completed Turn saved its answer as content; a Turn that ended in a provider failure saved the provider's
/// words as its Report (see `report_columns`), never as content.
pub const TurnOutcome = union(enum) {
    completed: i64,
    cancelled,
    retry_exhausted,
    resource_exceeded,
    /// The provider's failure code.
    failed: []const u8,
    pub const Tag = std.meta.Tag(TurnOutcome);

    pub const completed_code = "completed";

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
        return fixedCode(outcome) orelse outcome.failed;
    }

    /// The answer a completed Turn saved.
    pub fn content(outcome: TurnOutcome) ?i64 {
        return switch (outcome) {
            .completed => |answer| answer,
            .cancelled, .retry_exhausted, .resource_exceeded, .failed => null,
        };
    }

    /// Whether this ending carries the provider's words.
    pub fn reports(outcome: TurnOutcome) bool {
        return switch (outcome) {
            .retry_exhausted, .resource_exceeded, .failed => true,
            .completed, .cancelled => false,
        };
    }

    pub fn ending(outcome: TurnOutcome, stopped: bool) turn_ending.TurnEnding {
        return switch (outcome) {
            .completed => .done,
            .cancelled => if (stopped) .stopped else .interrupted,
            .retry_exhausted => .provider_unavailable,
            .resource_exceeded => .context_full,
            .failed => |failed| switch (failure_class.of(failed)) {
                .quota => .out_of_quota,
                .policy, .plan, .model, .sign_in, .api_key, .refused => .provider_refused,
                .unreachable_provider, .retries_exhausted => .provider_unavailable,
                .overflow => .context_full,
                .interrupted, .other => .failed,
            },
        };
    }

    pub fn decode(saved: []const u8, content_id: ?i64) error{CorruptStore}!TurnOutcome {
        if (saved.len == 0) return error.CorruptStore;
        const tag: Tag = for (std.enums.values(Tag)) |candidate| {
            if (fixedCode(candidate)) |fixed| if (std.mem.eql(u8, fixed, saved)) break candidate;
        } else .failed;
        if (tag != .completed and content_id != null) return error.CorruptStore;
        return switch (tag) {
            .completed => .{ .completed = content_id orelse return error.CorruptStore },
            .retry_exhausted => .retry_exhausted,
            .resource_exceeded => .resource_exceeded,
            .failed => .{ .failed = saved },
            .cancelled => .cancelled,
        };
    }

    /// The Report a Turn row saved, which is empty exactly when the ending carries no provider words.
    pub fn decodeReport(outcome: TurnOutcome, saved: *const SavedReport) error{CorruptStore}!failure_report.Report {
        const report = failure_report.Report.restore(
            if (saved.code) |*part| part.slice() else null,
            saved.code_cut,
            if (saved.message) |*part| part.slice() else null,
            saved.message_cut,
        ) catch return error.CorruptStore;
        if (!outcome.reports() and !report.isEmpty()) return error.CorruptStore;
        return report;
    }
};

/// The columns a Turn's saved Report is read from, in the order of `SavedReport`'s fields.
pub const report_columns = "t.outcome_report_code,t.outcome_report_message,t.outcome_report_code_cut,t.outcome_report_message_cut";

/// A Turn row's Report columns as a Row carries them.
pub const SavedReport = struct {
    code: ?Bounded(failure_report.max_part_bytes),
    message: ?Bounded(failure_report.max_stored_bytes),
    code_cut: bool,
    message_cut: bool,
};

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

fn CloseTurn(comptime otherwise: anyerror) type {
    return rsql.Write(.{
        .sql = "UPDATE turn SET outcome_code=?2,outcome_content_id=?3,outcome_position=?4,outcome_at=@now," ++
            "outcome_report_code=?6,outcome_report_message=?7,outcome_report_code_cut=?8,outcome_report_message_cut=?9 " ++
            "WHERE turn_id=?1 AND session_ref=@session(?5) AND outcome_code IS NULL",
        .Args = struct {
            turn_id: u64,
            code: []const u8,
            content_id: ?u64,
            position: u64,
            session: rsql.SessionHead,
            report_code: ?[]const u8,
            report_message: ?[]const u8,
            report_code_cut: bool,
            report_message_cut: bool,
        },
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

pub fn queueClose(a: anytype, positions: *store_access.Positions, turn_id: u64, outcome: TurnOutcome) !void {
    return queueCloseOr(a, positions, turn_id, outcome, &failure_report.Report.empty, error.CorruptStore);
}

/// Close a Turn with how it ended. `report` is the provider's words: queued statements read it in place, so the caller's frame keeps it.
pub fn queueCloseOr(a: anytype, positions: *store_access.Positions, turn_id: u64, outcome: TurnOutcome, report: *const failure_report.Report, comptime otherwise: anyerror) !void {
    const content_id = outcome.content();
    std.debug.assert(std.meta.activeTag(TurnOutcome.decode(outcome.code(), content_id) catch unreachable) == std.meta.activeTag(outcome));
    std.debug.assert(outcome.reports() or report.isEmpty());
    a.write(CloseTurn(otherwise), .{
        .turn_id = turn_id,
        .code = outcome.code(),
        .content_id = if (content_id) |id| @intCast(id) else null,
        .position = try positions.take(1),
        .session = positions.head,
        .report_code = if (report.code.text.len == 0) null else report.code.text.slice(),
        .report_message = if (report.message.text.len == 0) null else report.message.text.slice(),
        .report_code_cut = report.code.cut,
        .report_message_cut = report.message.cut,
    });
    try @import("forward.zig").queue(a, &positions.head.ref, &positions.head.ref, .ending, turn_id);
}

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

pub fn queueOwedStops(a: anytype, parent: *const [session_id.bytes]u8, position: u64, unowed: u64) void {
    if (unowed != 0) a.writeCount(owe_child_stops, .{ .parent = parent, .position = position }, unowed);
}

pub fn queueStopCompletion(a: anytype, ready: stopped_turn.Result, turn_id: u64) !void {
    const row = ready orelse return;
    try queueClose(a, try a.positions(row.session), turn_id, .cancelled);
}

pub fn queueContinuation(a: anytype, turn_id: u64, session: rsql.SessionHead) void {
    a.write(record_continuation, .{ .turn_id = turn_id, .session = session });
}
