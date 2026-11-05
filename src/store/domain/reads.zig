//! Public reads: Session inspection, conversation pages, activity, person
//! messages and proposals, and the content they open. Each entry point
//! runs its statements in one read Access (`ReadAccess`) under the Entry's
//! lock: a round reads what the next decision needs, and a later round
//! only what an earlier round's rows name.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const codec_abi = @import("../../codec_abi.zig");
const output_format = @import("../../output_format.zig");
const model_capability = @import("../../model_capability.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const turn_domain = @import("turn.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentLocation = content_domain.ContentLocation;
const ContentMetadata = content_domain.ContentMetadata;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const TurnOutcome = turn_domain.TurnOutcome;
const accepted_resolutions = store_schema.accepted_resolutions;
const content_metadata = content_domain.content_metadata;

/// The Access every entry point here reads through.
pub const ReadAccess = store_access.Access(.read, error{});

const SessionText = protocol.Bounded(protocol.max_session_bytes);

/// The rows of an `.each` read, up to `max`, kept in the caller's frame.
/// The visit that fills the last slot stops the read, so it steps at most
/// `max` rows, as the `LIMIT` of every page read here allows.
fn Collected(comptime Row: type, comptime max: usize) type {
    return struct {
        items: [max]Row = undefined,
        len: usize = 0,

        pub fn visit(rows: *@This(), row: *const Row) bool {
            rows.items[rows.len] = row.*;
            rows.len += 1;
            return rows.len < max;
        }

        fn slice(rows: *const @This()) []const Row {
            return rows.items[0..rows.len];
        }
    };
}

/// The first row of an `.each` read, which it steps once, as main did for
/// a text that does not rule out a second row (`rsql.Read.single_row`).
pub fn First(comptime Row: type) type {
    return struct {
        row: ?Row = null,

        pub fn visit(first: *@This(), row: *const Row) bool {
            first.row = row.*;
            return false;
        }
    };
}

/// The rows a per-row read stepped, kept by the visitor it hands them to,
/// so a read run through `readEach` keeps the meaning `.one` or
/// `.optional` gave it: a second row is `CorruptStore`, and is not stepped
/// for when the text rules one out (`rsql.Read.single_row`). A visitor
/// writes what it keeps into its caller's buffers, such as a page's items,
/// so a page's rows share their rounds without a row slot each.
pub const RowCount = struct {
    rows: u8 = 0,
    failure: ?error{CorruptStore} = null,

    /// Whether the read found its row, once its round ran.
    pub fn found(count: RowCount) error{CorruptStore}!bool {
        if (count.failure) |err| return err;
        return count.rows != 0;
    }
};

/// Queues `S` for `visitor`, which has a `count` and a `keep` of `S.Row`.
pub fn readRow(a: anytype, comptime S: type, args: S.Args, visitor: anytype) void {
    visitor.count = .{};
    a.readEach(S, args, if (S.single_row) 1 else 2, visitor);
}

/// `readRow` stepping one row only, as main did for these texts, which do
/// not rule out a second.
pub fn readFirst(a: anytype, comptime S: type, args: S.Args, visitor: anytype) void {
    visitor.count = .{};
    a.readEach(S, args, 1, visitor);
}

/// A per-row visitor's `visit`: counts the row, then keeps it. A second
/// row, or one `keep` refuses, stops the read and is its failure.
pub fn visitRow(visitor: anytype, row: anytype) bool {
    visitor.count.rows += 1;
    if (visitor.count.rows > 1) {
        visitor.count.failure = error.CorruptStore;
        return false;
    }
    visitor.keep(row) catch |err| {
        visitor.count.failure = err;
        return false;
    };
    return true;
}

/// The name main gave each statement here whose step fails, so a round of
/// many rows' reads answers as main did for the one that failed; any
/// other is `CorruptStore`. A Proposal's keeps `StatementFailed`, as
/// main's `proposal` let it through.
pub const read_failures = .{
    .{ missing_assistant_entry, error.ConversationReadFailed },
    .{ public_page, error.ConversationReadFailed },
    .{ activity_forward, error.ActivityReadFailed },
    .{ activity_backward, error.ActivityReadFailed },
    .{ public_entry, error.ConversationReadFailed },
    .{ public_tool_result, error.PublicContentReadFailed },
    .{ hosted_call, error.ActivityReadFailed },
    .{ activity_item, error.ActivityReadFailed },
    .{ answer_entry, error.ActivityReadFailed },
    .{ approval_request, error.ActivityReadFailed },
    .{ session_change, error.ActivityReadFailed },
    .{ compaction_row, error.ActivityReadFailed },
    .{ peer_label, error.SessionReadFailed },
    .{ proposal_row, error.StatementFailed },
    .{ call_activity, error.CallReadFailed },
    .{ call_outcomes, error.CallReadFailed },
    .{ operation_outcome, error.CallReadFailed },
    .{ queued, error.ActivityReadFailed },
} ++ report_domain.work_failures;

/// Ends a round of per-row reads, naming a failed step by `read_failures`.
fn runRows(a: *ReadAccess) !void {
    return store_access.runNamed(a, read_failures, error.CorruptStore);
}

const public_tool_groups_sql = "WITH tool_groups AS (SELECT op.operation_id,max(coalesce(tool_call.acceptance_position,action.acceptance_position)) AS position " ++
    "FROM model_operation op JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " GROUP BY op.operation_id " ++
    "HAVING count(*)=(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
    "AND count(coalesce(tool_call.acceptance_position,action.acceptance_position))=count(*) " ++
    "AND count(coalesce(tool_call.rejection_content_id,action.resolution_content_id))=count(*)), ";

/// An Activity source row `last`, a rejected call or a resolved Action of
/// `operation`, is where that Operation's tool group completes: every call
/// has its accepted result, one per call item, and none was accepted later.
/// It reads only that Operation's calls, so a seek by acceptance position
/// finds a group's results without grouping the Session's history.
fn toolGroupCompletesAtLast(comptime operation: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM model_operation op WHERE op.operation_id=" ++ operation ++ " AND op.session_ref=?1 AND " ++
        store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ ") " ++
        "AND (SELECT count(*) FROM model_tool_call c WHERE c.operation_id=" ++ operation ++ ")=" ++
        "(SELECT count(*) FROM model_output_item item WHERE item.operation_id=" ++ operation ++ " AND item.item_kind=3) " ++
        "AND NOT EXISTS(SELECT 1 FROM model_tool_call c LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal " ++
        "WHERE c.operation_id=" ++ operation ++ " AND (coalesce(c.acceptance_position,a.acceptance_position) IS NULL " ++
        "OR coalesce(c.rejection_content_id,a.resolution_content_id) IS NULL OR coalesce(c.acceptance_position,a.acceptance_position)>last.acceptance_position))";
}

/// Each Activity source, as (position, ordinal, kind, id) rows matching
/// `filter`, which names a source's position and ordinal through `range`,
/// and whose kind is in `kinds`, an SQL integer with bit `k` set for each
/// kind `k` it lists (`activityKinds`). Every source seeks an index on
/// (Session, position), so a filter on position reads only the rows it
/// keeps, and a source whose kinds are off reads nothing. A person's
/// Messages (kind 1) come from their own index while the page lists no
/// received ones (kind 11), and otherwise share one source with them, as
/// every unfiltered page reads Messages. The sources come in three groups,
/// each within the Store's four-term compound limit.
fn activitySources(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime order: []const u8) [4][]const u8 {
    const Kinds = struct {
        fn on(comptime kind: u5) []const u8 {
            return std.fmt.comptimePrint("({s}/{d})%2=1", .{ kinds, @as(u64, 1) << kind });
        }
        fn off(comptime kind: u5) []const u8 {
            return std.fmt.comptimePrint("({s}/{d})%2=0", .{ kinds, @as(u64, 1) << kind });
        }
    };
    const on = Kinds.on;
    return .{
        "SELECT admission_position AS position,0 AS ordinal,1 AS kind,admission_id AS id FROM message_admission @index(message_admission_person) " ++
            "WHERE session_ref=?1 AND sender_session_ref IS NULL AND " ++ on(1) ++ " AND " ++ Kinds.off(11) ++ " AND " ++ range("admission_position", "0") ++
            " UNION ALL SELECT admission_position,0,CASE WHEN sender_session_ref IS NULL THEN 1 ELSE 11 END,admission_id FROM message_admission @index(message_admission_position) " ++
            "WHERE session_ref=?1 AND " ++ on(11) ++ " AND (sender_session_ref IS NOT NULL OR " ++ on(1) ++ ") AND " ++ range("admission_position", "0") ++
            " UNION ALL SELECT session_position,0,CASE entry_kind WHEN 1 THEN 2 ELSE 3 END,source_admission_id FROM conversation_entry " ++
            "WHERE session_ref=?1 AND (entry_kind=1 AND " ++ on(2) ++ " OR entry_kind=3 AND " ++ on(3) ++ ") AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT session_position,0,4,NULL FROM model_output_item @index(model_output_call_history) " ++
            "WHERE session_ref=?1 AND item_kind=3 AND " ++ on(4) ++ " AND " ++ range("session_position", "0") ++ order,
        // A tool group's results sit at its last acceptance, one per call,
        // ordered by call. Each `last` names its acceptance index, as
        // `call_candidates_sql`.
        "SELECT last.acceptance_position AS position,tool_call.call_ordinal+1 AS ordinal,5 AS kind,NULL AS id FROM model_tool_call last @index(model_tool_call_acceptance) " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=last.operation_id WHERE last.session_ref=?1 AND " ++ on(5) ++ " AND " ++
            range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.operation_id") ++
            " UNION ALL SELECT last.acceptance_position,tool_call.call_ordinal+1,5,NULL FROM action_operation last @index(action_operation_acceptance) " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=last.parent_operation_id WHERE last.session_ref=?1 AND " ++ on(5) ++ " AND " ++
            range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.parent_operation_id") ++
            " UNION ALL SELECT outcome_position,0,6,turn_id FROM turn @index(turn_outcome_position) WHERE session_ref=?1 AND outcome_code IS NOT NULL AND " ++ on(6) ++ " AND " ++ range("outcome_position", "0") ++
            " UNION ALL SELECT position,0,7,NULL FROM session_stop @index(session_stop_position) WHERE session_ref=?1 AND " ++ on(7) ++ " AND " ++ range("position", "0") ++ order,
        "SELECT sender_position AS position,0 AS ordinal,8 AS kind,admission_id AS id FROM message_admission WHERE sender_session_ref=?1 AND " ++ on(8) ++ " AND " ++ range("sender_position", "0") ++
            " UNION ALL SELECT sender_position,0,9,NULL FROM sent_rejection WHERE sender_session_ref=?1 AND " ++ on(9) ++ " AND " ++ range("sender_position", "0") ++
            " UNION ALL SELECT session_position,0,10,NULL FROM model_output_item @index(model_output_hosted_history) " ++
            "WHERE session_ref=?1 AND item_kind=5 AND " ++ on(10) ++ " AND " ++ range("session_position", "0") ++
            // A call made while the Session asked for approval, at its
            // call's position: its Action was saved under an `ask` revision,
            // whatever was decided since.
            " UNION ALL SELECT approval_position,1,12,action_id FROM action_operation @index(action_operation_approval) " ++
            "WHERE session_ref=?1 AND approval_position IS NOT NULL AND " ++ on(12) ++ " AND " ++ range("approval_position", "1") ++ order,
        // Each setting a revision changed, at the position it was accepted.
        "SELECT position,ordinal,13 AS kind,revision AS id FROM session_change WHERE session_ref=?1 AND " ++ on(13) ++ " AND " ++ range("position", "ordinal") ++
            // Each compaction that succeeded, at its compaction item: a
            // position its settlement took, so no earlier prefix gains it (D217).
            " UNION ALL SELECT session_position,0,14,operation_id FROM model_output_item @index(model_output_compaction_history) " ++
            "WHERE session_ref=?1 AND item_kind=4 AND " ++ on(14) ++ " AND " ++ range("session_position", "0") ++ order,
    };
}

/// Every kind, for a read of one known row.
const all_activity_kinds = std.fmt.comptimePrint("{d}", .{(@as(u64, 1) << 15) - 2});

/// The kind codes the sources number, for each Activity kind.
fn activityKindCode(kind: protocol.ActivityItem.Kind) u5 {
    return switch (kind) {
        .admission => 1,
        .user => 2,
        .assistant => 3,
        .call => 4,
        .tool_result => 5,
        .turn_ended => 6,
        .stop => 7,
        .sent => 8,
        .send_failed => 9,
        .hosted_call => 10,
        .received => 11,
        .approval_requested => 12,
        .session_changed => 13,
        .compacted => 14,
    };
}

/// `kinds` as the sources' integer: bit `k` for each kind code `k`.
fn activityKinds(kinds: protocol.ActivityPage.Kinds) u64 {
    var bits: u64 = 0;
    var iterator = kinds.iterator();
    while (iterator.next()) |kind| bits |= @as(u64, 1) << activityKindCode(kind);
    return bits;
}

fn anyActivityPosition(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
    _ = ordinal;
    return position ++ " IS NOT NULL";
}

/// The Activity row at position ?3 and ordinal ?4 through end ?2: each
/// source seeks that one position. A second row is `CorruptStore`.
const activity_item = blk: {
    const sources = activitySources(anyActivityPosition, all_activity_kinds, "");
    break :blk rsql.Read(.{
        .sql = std.fmt.comptimePrint("WITH entries AS ({s}), completions AS ({s}), others AS ({s}), changes AS ({s}), " ++
            "activity AS (SELECT position,ordinal,kind,id FROM entries UNION ALL SELECT position,ordinal,kind,id FROM completions UNION ALL SELECT position,ordinal,kind,id FROM others " ++
            "UNION ALL SELECT position,ordinal,kind,id FROM changes) " ++
            "SELECT kind,id FROM activity WHERE position=?3 AND ordinal=?4 AND position<=?2", .{ sources[0], sources[1], sources[2], sources[3] }),
        .Args = struct { session: []const u8, end: u64, position: u64, ordinal: u64 },
        .Row = struct { kind: u8, id: ?rsql.Positive },
        .cardinality = .optional,
        .compound = true,
    });
};

/// One Activity page, at most 17 rows of the kinds ?5 (forward) or ?4
/// (backward) lists: forward, after cursor (?3, ?4) through end ?2;
/// backward, before cursor (?2, ?3), which is at or before the end. A
/// smaller page steps fewer of them. Each source group keeps its own first 17 rows, read
/// in order from its indexes, and the page takes the first 17 of those:
/// the cost follows the page, not the Session's history.
fn ActivityPage(comptime forward: bool) type {
    const Range = struct {
        fn after(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
            return position ++ ">=?3 AND " ++ position ++ "<=?2 AND (" ++ position ++ ">?3 OR " ++ ordinal ++ ">?4)";
        }
        fn before(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
            return position ++ "<=?2 AND (" ++ position ++ "<?2 OR " ++ ordinal ++ "<?3)";
        }
    };
    const order = if (forward) " ORDER BY 1,2 LIMIT 17" else " ORDER BY 1 DESC,2 DESC LIMIT 17";
    const sources = activitySources(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", order);
    return rsql.Read(.{
        .sql = std.fmt.comptimePrint("WITH entries AS ({s}), completions AS ({s}), others AS ({s}), changes AS ({s}) SELECT position,ordinal FROM entries " ++
            "UNION ALL SELECT position,ordinal FROM completions UNION ALL SELECT position,ordinal FROM others UNION ALL SELECT position,ordinal FROM changes{s}", .{ sources[0], sources[1], sources[2], sources[3], order }),
        .Args = if (forward) struct { session: []const u8, end: u64, position: u64, ordinal: u64, kinds: u64 } else struct { session: []const u8, position: u64, ordinal: u64, kinds: u64 },
        .Row = ActivityPageRow,
        .cardinality = .each,
        .compound = true,
    });
}
const activity_forward = ActivityPage(true);
const activity_backward = ActivityPage(false);

/// Nullable columns permit corruption detection; no writer may omit one.
/// Each partial index is empty in a sound Store, so every activity read
/// checks the whole Session in a few steps, however long its history.
pub const activity_sequence_guard = rsql.Read(.{
    .sql = "SELECT 1 AS found FROM message_admission @index(message_admission_unpositioned) WHERE session_ref=?1 AND admission_position IS NULL " ++
        "UNION ALL SELECT 1 FROM session_stop @index(session_stop_unpositioned) WHERE session_ref=?1 AND position IS NULL " ++
        "UNION ALL SELECT 1 FROM turn @index(turn_unpositioned) WHERE session_ref=?1 AND ((outcome_code IS NULL)!=(outcome_position IS NULL)) LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { found: bool },
    .cardinality = .optional,
    .compound = true,
});

/// See `readQueued`.
pub const queued = rsql.Read(.{
    .sql = "SELECT m.admission_id,m.admission_position," ++
        "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.source_admission_id=m.admission_id AND e.session_position<=?2) OR " ++
        "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=?1 AND s.admission_cutoff>=m.admission_id AND s.position<=?2) AS taken " ++
        "FROM message_admission m @index(message_admission_person) WHERE m.session_ref=?1 AND m.sender_session_ref IS NULL " ++
        "AND m.admission_position<=?2 ORDER BY m.admission_position DESC",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct { admission_id: rsql.Positive, admission_position: rsql.Positive, taken: bool },
    .cardinality = .each,
});

pub const PublicConversationItem = struct {
    position: u64,
    ordinal: u64, // Zero for User/Assistant; one-based call ordinal in a completed Tool Result group.
    kind: protocol.ConversationItemKind,
    content: ContentReference,
    presentation: ?protocol.ToolPresentation = null,
    admitted_at: ?u64 = null, // The Host wall-clock second a User item was admitted.
    sender: ?protocol.NamedPeer = null, // A User item's sending peer Session.
};

pub const PublicConversationPage = struct {
    pub const capacity = protocol.public_conversation_page_items;
    end: u64,
    items: [capacity]PublicConversationItem = undefined,
    count: usize = 0,
    more: bool = false,
};

pub const MessageObservation = struct {
    content: ContentReference,
    queue: ?AcceptedMessageQueue = null,
    // Present only while this admission can still advance. This is a fact
    // about its active dependency, not an instruction to a particular caller.
    progress: ?MessageProgress = null,
};

pub const MessageProgress = struct {
    status: protocol.MessageProgressStatus,
    action_id: ?u64 = null,
};

pub const AcceptedMessageQueue = struct {
    admission_id: u64,
    state: State,

    pub const State = union(enum) {
        queued,
        excluded: struct { code: protocol.Bounded(protocol.max_code_bytes) },
        processing: AttemptBinding,
        completed: struct {
            binding: AttemptBinding,
            answer: ContentReference,
        },
        cancelled: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(protocol.max_code_bytes),
        },
        failed: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(protocol.max_code_bytes),
        },
    };
};

pub const SessionObservation = struct {
    found: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: ?protocol.Provider = null,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    revision: u64 = 0,
    tools_mask: u8 = 0,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    compaction_trigger_override: ?u64 = null,
    output_reservation_override: ?u64 = null,
    reasoning_effort: ?protocol.ReasoningEffort = null,
    reasoning_effort_override: ?protocol.ReasoningEffort = null,
    permission_mode: protocol.Bounded(16) = .{},
    instructions: ContentReference = .{ .length = 0, .digest = @splat(0) },
    output_schema: ?ContentReference = null,
    pending_messages: u64 = 0,
    action_count: u64 = 0,
    rejected_call_count: u64 = 0,
};

/// A Session's next position: every page's end stays below it.
const next_position = rsql.Read(.{
    .sql = "SELECT next_position FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { next_position: rsql.Positive },
    .cardinality = .optional,
});

/// The Session's next position, or null for an unknown Session, in a round
/// of its own. A failed step is `SessionReadFailed`, main's name for it.
fn readNextPosition(a: *ReadAccess, session: []const u8) !?u64 {
    var row: next_position.Result = undefined;
    a.read(next_position, .{ .session = session }, &row);
    try store_access.runAs(a, error.SessionReadFailed);
    return if (row) |found| found.next_position.get() else null;
}

/// The public metadata of the content row `content_id`, in a round of its
/// own. A failed step is `CorruptStore`, main's answer for it.
fn readPublicMetadata(a: *ReadAccess, content_id: u64) !ContentMetadata {
    var row: content_metadata.Row = undefined;
    a.read(content_metadata, .{ .content_id = content_id }, &row);
    try store_access.runAs(a, error.CorruptStore);
    return content_domain.publicMetadata(&row);
}

/// Round 1 reads the saved Session; round 2 its instructions' and output
/// schema's metadata with the counts' first round (`report.SessionCounts`);
/// round 3 the counts' second round: the pending count after the latest
/// stop's cutoff, the tool outcome rule, and the Action and rejected-call
/// counts.
pub fn inspectSession(a: *ReadAccess, session_ref: []const u8, observation: *SessionObservation) !void {
    var current: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    var found: store_access.Found = undefined;
    configuration_domain.readSaved(a, session_ref, &current, &found);
    try a.run();
    if (!found.get()) {
        observation.* = .{};
        return;
    }
    try configuration_domain.checkSaved(&current);
    const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
    observation.* = .{
        .found = true,
        .revision = current.revision,
        .tools_mask = current.tools_mask,
        .compaction_trigger = policy.compaction_trigger,
        .output_reservation = policy.output_reservation,
        .compaction_trigger_override = current.compaction_trigger,
        .output_reservation_override = current.output_reservation,
        .reasoning_effort = configuration_domain.effectiveReasoningEffort(&current),
        .reasoning_effort_override = current.reasoning_effort,
    };
    try observation.session.set(session_ref);
    observation.workspace = current.workspace;
    observation.provider = current.provider;
    observation.model = current.model;
    try observation.permission_mode.set(if (current.permission_mode == 0) "ask" else "bypass");
    // `checkSaved` refused a missing or zero instructions id and a zero
    // output schema id. A negative id is `CorruptStore` here without a
    // read, where main read it and found no row unless one had that id.
    const instructions_id = current.instructions_id.?;
    if (instructions_id < 0 or (current.output_schema_id orelse 1) < 0) return error.CorruptStore;
    var instructions: content_metadata.Row = undefined;
    var output_schema: content_metadata.Row = undefined;
    var counts: report_domain.SessionCounts = .{ .session = session_ref };
    a.read(content_metadata, .{ .content_id = @intCast(instructions_id) }, &instructions);
    if (current.output_schema_id) |content_id| a.read(content_metadata, .{ .content_id = @intCast(content_id) }, &output_schema);
    counts.queue(a);
    try runCounts(a);
    observation.instructions = .{ .length = instructions.byte_length, .digest = instructions.digest };
    if (current.output_schema_id != null) observation.output_schema = .{ .length = output_schema.byte_length, .digest = output_schema.digest };
    counts.queuePending(a);
    try runCounts(a);
    const counted = try counts.judge();
    observation.pending_messages = counted.pending;
    observation.action_count = counted.actions;
    observation.rejected_call_count = counted.rejected;
}

/// Ends a round of `inspectSession`'s counts, naming a failed step as main
/// did; the content metadata's is `CorruptStore`, as main's.
fn runCounts(a: *ReadAccess) !void {
    return store_access.runNamed(a, report_domain.session_count_failures ++ report_domain.work_failures, error.CorruptStore);
}

/// One public Conversation page: at most 17 rows before cursor (?3, ?4)
/// through end ?2, newest first. Tool outcomes enter public Conversation
/// only when the entire group settles. Position is then its last
/// acceptance; call ordinal is the stable tie breaker. Private model
/// items/instructions never enter it.
const public_page = rsql.Read(.{
    .sql = public_tool_groups_sql ++
        "public AS (SELECT e.session_position AS position,0 AS ordinal,e.entry_kind AS kind,e.content_id " ++
        "FROM conversation_entry e WHERE e.session_ref=?1 AND e.entry_kind IN (1,3) AND e.session_position<=?2 " ++
        "UNION ALL SELECT tool_groups.position,tool_call.call_ordinal+1,4,coalesce(tool_call.rejection_content_id,action.resolution_content_id) " ++
        "FROM tool_groups JOIN model_tool_call tool_call ON tool_call.operation_id=tool_groups.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE tool_groups.position<=?2 " ++
        // A hosted call is public at its own item's position.
        "UNION ALL SELECT item.session_position,0,5,NULL FROM model_output_item item @index(model_output_hosted_history) WHERE item.session_ref=?1 AND item.item_kind=5 AND item.session_position<=?2) " ++
        "SELECT position,ordinal,kind,content_id FROM public WHERE (?3=0 OR position<?3 OR (position=?3 AND ordinal<?4)) " ++
        "ORDER BY position DESC,ordinal DESC LIMIT 17",
    .Args = struct { session: []const u8, end: u64, before_position: u64, before_ordinal: u64 },
    .Row = struct { position: u64, ordinal: u64, kind: u8, content_id: ?u64 },
    .cardinality = .each,
    .compound = true,
});

/// Round 1 reads the Session's next position. Round 2 reads the page's
/// rows into this frame, with the cursor's item: its hosted call and its
/// content row together at ordinal 0, where main read the content only
/// when no hosted call was there. The rows' own reads follow
/// (`readPublicRows`), each round shared by every row, and the cursor's
/// content metadata shares their first.
pub fn publicConversationPage(a: *ReadAccess, request: *const protocol.ConversationPage, page: *PublicConversationPage) !void {
    if (request.end > std.math.maxInt(i64) or request.before_position > std.math.maxInt(i64) or
        request.before_ordinal > std.math.maxInt(i64) or
        (request.end == 0 and request.before_position != 0) or
        (request.before_position == 0 and request.before_ordinal != 0) or
        (request.end != 0 and request.before_position > request.end)) return error.InvalidCursor;
    const session = request.session.slice();
    const next = try readNextPosition(a, session) orelse return error.SessionNotFound;
    const end = if (request.end == 0) next - 1 else request.end;
    if (request.end != 0 and (request.before_position > end or end >= next or
        end > std.math.maxInt(i64))) return error.InvalidCursor;
    page.* = .{ .end = end };
    // A cursor needs a nonzero end, so an empty Session has no rows and
    // no cursor to read.
    if (end == 0) return;
    var rows: Collected(public_page.Row, PublicConversationPage.capacity + 1) = .{};
    a.readEach(public_page, .{ .session = session, .end = end, .before_position = request.before_position, .before_ordinal = request.before_ordinal }, rows.items.len, &rows);
    // A cursor names an item: a hosted call, or an item with content.
    var hosted_cursor: protocol.ToolPresentation = undefined;
    var hosted: HostedRead = .{ .position = request.before_position, .presentation = &hosted_cursor };
    var cursor: PublicContentRead = .{ .position = request.before_position, .ordinal = request.before_ordinal };
    if (request.before_position != 0) {
        if (request.before_ordinal == 0) hosted.queue(a, session);
        cursor.queue(a, session);
    }
    try runRows(a);
    var content_cursor: ?*PublicContentRead = null;
    if (request.before_position != 0) cursor: {
        if (request.before_ordinal == 0) if (hosted.found()) |_| break :cursor else |err| switch (err) {
            error.ContentNotFound => {},
            else => return err,
        };
        cursor.found() catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
        cursor.queueMetadata(a);
        content_cursor = &cursor;
    }
    page.more = rows.len > page.items.len;
    const shown = rows.slice()[0..@min(rows.len, page.items.len)];
    for (shown, page.items[0..shown.len]) |row, *item| {
        // Do not filter damaged rows out of SQL: validate ordinary
        // producers and the exposed content before publishing metadata.
        if (row.position == 0) return error.CorruptStore;
        item.* = .{ .position = row.position, .ordinal = row.ordinal, .kind = switch (row.kind) {
            1 => .user,
            3 => .assistant,
            4 => .tool_result,
            5 => .hosted_call,
            else => return error.CorruptStore,
        }, .content = .{ .length = 0, .digest = protocol.contentDigest("") } };
        if (row.kind == 5) {
            if (row.ordinal != 0) return error.CorruptStore;
        } else if ((row.content_id orelse 0) == 0 or (row.kind == 4) != (row.ordinal > 0)) return error.CorruptStore;
    }
    page.count = shown.len;
    const upper = if (request.before_position == 0) end else @min(end, request.before_position - @intFromBool(request.before_ordinal == 0));
    try readPublicRows(a, session, shown, page.items[0..shown.len], if (page.more) page.items[page.count - 1].position else 0, upper, content_cursor);
}

/// One page row's own reads (`readPublicRows`).
const PublicRowRead = struct {
    reads: union(enum) { content: PublicContentRead, hosted: HostedRead },
    label: LabelRead = undefined,
    presentation: PresentationRead = undefined,
};

/// The page rows' own reads, each round shared by every row: round 1 each
/// row's content (`PublicContentRead`) or hosted call, with the page's
/// assistant check over `lower` through `upper` and the metadata `cursor`
/// queued; round 2 each content's metadata, its sender's label and its
/// call's presentation; round 3 each presentation's Proposal. Not
/// inlined, so its per-row state takes no slot in the page's frame.
noinline fn readPublicRows(a: *ReadAccess, session: []const u8, rows: []const public_page.Row, items: []PublicConversationItem, lower: u64, upper: u64, cursor: ?*PublicContentRead) !void {
    var reads: [PublicConversationPage.capacity]PublicRowRead = undefined;
    var missing: missing_assistant_entry.Result = null;
    if (lower <= upper) a.read(missing_assistant_entry, .{ .session = session, .lower = lower, .upper = upper }, &missing);
    for (items, reads[0..items.len]) |*item, *read| {
        if (item.kind == .hosted_call) {
            item.presentation = @as(protocol.ToolPresentation, undefined);
            read.* = .{ .reads = .{ .hosted = .{ .position = item.position, .presentation = &item.presentation.? } } };
            read.reads.hosted.queue(a, session);
        } else {
            read.* = .{ .reads = .{ .content = .{ .position = item.position, .ordinal = item.ordinal, .sender = &item.sender } } };
            read.reads.content.queue(a, session);
        }
    }
    if (items.len != 0 or lower <= upper or cursor != null) try runRows(a);
    if (cursor) |read| try read.takeMetadata();
    var contents = false;
    for (rows, items, reads[0..items.len]) |row, *item, *read| switch (read.reads) {
        .hosted => |*hosted| try hosted.found(),
        .content => |*content| {
            try content.found();
            const found = &content.content;
            if (@as(u64, @intCast(found.id)) != row.content_id.? or (row.kind == 1) != (found.admitted_at != null)) return error.CorruptStore;
            item.admitted_at = found.admitted_at;
            content.queueMetadata(a);
            contents = true;
            if (item.sender) |*sender| {
                read.label = .{ .peer = sender };
                read.label.queue(a);
            }
            if (found.tool_operation) |operation| {
                item.presentation = @as(protocol.ToolPresentation, undefined);
                read.presentation = .init(operation, item.ordinal - 1, item.position, &item.presentation.?);
                read.presentation.queue(a);
            }
        },
    };
    if (contents) try runRows(a);
    var proposals = false;
    for (items, reads[0..items.len]) |*item, *read| switch (read.reads) {
        .hosted => {},
        .content => |*content| {
            try content.takeMetadata();
            item.content = .{ .length = content.content.metadata.length, .digest = content.content.metadata.digest };
            if (item.sender != null) try read.label.found();
            if (content.content.tool_operation != null) {
                try read.presentation.checkCall();
                read.presentation.queueProposal(a);
                proposals = true;
            }
        },
    };
    if (proposals) {
        try runRows(a);
        for (reads[0..items.len]) |*read| if (read.reads == .content and read.reads.content.content.tool_operation != null) try read.presentation.finish();
    }
    if (missing != null) return error.CorruptStore;
}

pub fn openPublicConversationContent(a: *ReadAccess, request: *const protocol.ConversationContent) !ContentLocation {
    if (request.position == 0 or request.position > std.math.maxInt(i64) or
        request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
    const content = try publicConversationContent(a, request.session.slice(), request.position, request.ordinal);
    if (request.start > content.metadata.length) return error.RangeOutOfBounds;
    return .{ .store = a.store, .content_id = content.id, .reference = .{ .length = content.metadata.length, .digest = content.metadata.digest } };
}

// Accepted assistant messages require entries even when a damaged entry
// would disappear from an inventory rooted in conversation_entry. Inspect
// only the requested position interval through the existing history index.
// Compaction messages deliberately have no Conversation certificate.
/// A row exactly when the assistant entry at position ?2 is the answer of
/// a Turn that completed at or before end ?3: the message its causing
/// Operation selected, by `output_decode.AnswerSelection`'s rule over that
/// Operation's messages: the last `final_answer`, or with no phased
/// message the last one. Each message is an entry, so the item names it.
const answer_entry = blk: {
    const Phase = codec_abi.Phase;
    const final_answer = std.fmt.comptimePrint("{d}", .{@backingInt(Phase.final_answer)});
    const unphased = std.fmt.comptimePrint("{d}", .{@backingInt(Phase.unphased)});
    const message = std.fmt.comptimePrint("{d}", .{@backingInt(output_format.OutputItemKind.message)});
    break :blk rsql.Read(.{
        .sql = "SELECT 1 AS final FROM conversation_entry e JOIN turn t ON t.turn_id=e.turn_id " ++
            "JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
            "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind=3 AND t.session_ref=e.session_ref " ++
            "AND t.outcome_code='" ++ TurnOutcome.completed_code ++ "' AND t.outcome_position<=?3 AND e.source_operation_id=t.operation_id " ++
            "AND ((item.phase=" ++ final_answer ++ " AND NOT EXISTS(SELECT 1 FROM model_output_item later WHERE later.operation_id=item.operation_id " ++
            "AND later.item_ordinal>item.item_ordinal AND later.item_kind=" ++ message ++ " AND later.phase=" ++ final_answer ++ ")) " ++
            "OR (NOT EXISTS(SELECT 1 FROM model_output_item other WHERE other.operation_id=item.operation_id AND other.item_kind=" ++ message ++ " AND other.phase<>" ++ unphased ++ ") " ++
            "AND NOT EXISTS(SELECT 1 FROM model_output_item later WHERE later.operation_id=item.operation_id " ++
            "AND later.item_ordinal>item.item_ordinal AND later.item_kind=" ++ message ++ ")))",
        .Args = struct { session: []const u8, position: u64, end: u64 },
        .Row = struct { final: bool },
        .cardinality = .optional,
    });
};

pub const missing_assistant_entry = rsql.Read(.{
    .sql = "SELECT 1 AS missing FROM model_output_item item JOIN model_operation op ON op.operation_id=item.operation_id " ++
        "LEFT JOIN conversation_entry e ON e.session_ref=item.session_ref AND e.session_position=item.session_position " ++
        "WHERE item.session_ref=?1 AND item.session_position>=?2 AND item.session_position<=?3 AND item.item_kind=2 " ++
        "AND op.purpose=0 AND " ++ store_schema.oneOf("op.resolution_code", &accepted_resolutions) ++
        " AND CASE WHEN e.entry_kind=3 AND e.source_operation_id=item.operation_id AND e.source_item_ordinal=item.item_ordinal " ++
        "AND e.content_id=item.message_content_id AND e.turn_id=op.turn_id AND op.session_ref=item.session_ref " ++
        "AND item.attempt_ordinal=op.attempt_ordinal THEN 0 ELSE 1 END=1 LIMIT 1",
    .Args = struct { session: []const u8, lower: u64, upper: u64 },
    .Row = struct { missing: bool },
    .cardinality = .optional,
});

/// A read of Conversation entries `e`: `SELECT columns`, then a
/// `consistent` column (`publicEntryColumns`), `FROM conversation_entry e`
/// with the rows that make an entry public (`public_entry_joins`), then
/// `rest` (its WHERE and order).
pub fn publicEntryRead(comptime columns: []const u8, comptime also: []const u8, comptime rest: []const u8) []const u8 {
    return "SELECT " ++ columns ++ "," ++ publicEntryColumns(also) ++ " FROM conversation_entry e " ++ public_entry_joins ++ " " ++ rest;
}

/// The `consistent` column of an entry `e` joined by `public_entry_joins`.
/// An entry is consistent when `also` holds (an SQL condition and `OR`, or
/// empty), or when it is public: its content is, and its message or
/// assistant provenance agrees with it.
pub fn publicEntryColumns(comptime also: []const u8) []const u8 {
    return "CASE WHEN " ++ also ++ "(c.content_id IS NOT NULL AND c.private=0 AND t.session_ref=e.session_ref AND " ++
        "((e.entry_kind=1 AND m.session_ref=e.session_ref AND m.turn_id=e.turn_id AND m.content_id=e.content_id) OR " ++
        "(e.entry_kind=3 AND o.purpose=0 AND o.session_ref=e.session_ref AND o.turn_id=e.turn_id " ++
        "AND item.item_kind=2 AND item.message_content_id=e.content_id AND item.session_ref=e.session_ref " ++
        "AND item.session_position=e.session_position AND item.attempt_ordinal=o.attempt_ordinal " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ "))) THEN 1 ELSE 0 END AS consistent";
}

/// The rows that make an entry `e` public. LEFT JOINs, which keep damage
/// instead of hiding a missing row, under the aliases t, m, o, item and c,
/// which a read's columns and WHERE may also read.
pub const public_entry_joins = "LEFT JOIN turn t ON t.turn_id=e.turn_id " ++
    "LEFT JOIN message_admission m ON m.admission_id=e.source_admission_id " ++
    "LEFT JOIN model_operation o ON o.operation_id=e.source_operation_id " ++
    "LEFT JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
    "LEFT JOIN content c ON c.content_id=e.content_id";

/// An ordinary entry at a position, with the provenance that makes it
/// public. One indexed ordinary identity owns provenance for pages,
/// cursors and bytes.
const public_entry = rsql.Read(.{
    .sql = publicEntryRead("e.content_id,CASE WHEN e.entry_kind=1 THEN m.admitted_at END AS admitted_at," ++
        "CASE WHEN e.entry_kind=1 THEN m.sender_session_ref END AS sender,e.recorded_at", "", "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind IN(1,3)"),
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct { content_id: rsql.Positive, admitted_at: ?rsql.Positive, sender: ?SessionText, recorded_at: rsql.Positive, consistent: bool },
    .cardinality = .each,
});

/// The Tool Result of call ?3 at position ?2, with whether every call of
/// its group has public provenance and when the group completed.
const public_tool_result = rsql.Read(.{
    // Only an Operation with an acceptance at the position can complete
    // there. Each arm names its acceptance index, as `call_candidates_sql`.
    .sql = "WITH last AS (SELECT operation_id FROM model_tool_call @index(model_tool_call_acceptance) WHERE session_ref=?1 AND acceptance_position=?2 " ++
        "UNION ALL SELECT parent_operation_id FROM action_operation @index(action_operation_acceptance) WHERE session_ref=?1 AND acceptance_position=?2) " ++
        "SELECT coalesce(tool_call.rejection_content_id,action.resolution_content_id) AS content_id,NOT EXISTS(SELECT 1 FROM model_tool_call linked " ++
        "LEFT JOIN model_output_item item ON item.operation_id=linked.operation_id AND item.item_ordinal=linked.item_ordinal LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
        "LEFT JOIN content rejection ON rejection.content_id=linked.rejection_content_id " ++
        "LEFT JOIN action_operation a ON a.parent_operation_id=linked.operation_id AND a.call_ordinal=linked.call_ordinal " ++
        "LEFT JOIN content result ON result.content_id=a.resolution_content_id " ++
        "WHERE linked.operation_id=op.operation_id AND CASE WHEN item.item_kind=3 AND item.session_ref=op.session_ref AND t.session_ref=op.session_ref " ++
        "AND item.attempt_ordinal=op.attempt_ordinal AND " ++
        "((linked.rejection_code IS NOT NULL AND a.action_id IS NULL AND rejection.private=0) OR (linked.rejection_code IS NULL AND a.action_id IS NOT NULL AND a.session_ref=op.session_ref AND result.private=0)) THEN 0 ELSE 1 END=1) AS consistent,op.operation_id," ++
        // A rejected call is accepted when its Operation resolves; an
        // Action call when the Action does. The last acceptance is the
        // one at the greatest position: times order nothing.
        "(SELECT coalesce(a.resolved_at,op.resolved_at) FROM model_tool_call c LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal " ++
        "WHERE c.operation_id=op.operation_id ORDER BY coalesce(c.acceptance_position,a.acceptance_position) DESC LIMIT 1) AS at " ++
        "FROM last CROSS JOIN model_operation op ON op.operation_id=last.operation_id " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " AND tool_call.call_ordinal+1=?3 " ++
        "AND (SELECT max(coalesce(c.acceptance_position,a.acceptance_position)) FROM model_tool_call c " ++
        "LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id)=?2 " ++
        "AND (SELECT count(*) FROM model_tool_call c WHERE c.operation_id=op.operation_id)=" ++
        "(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
        "AND NOT EXISTS (SELECT 1 FROM model_tool_call c LEFT JOIN action_operation a " ++
        "ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id " ++
        "AND (coalesce(c.acceptance_position,a.acceptance_position) IS NULL OR coalesce(c.rejection_content_id,a.resolution_content_id) IS NULL))",
    .Args = struct { session: []const u8, position: u64, ordinal: u64 },
    .Row = struct { content_id: rsql.Positive, consistent: bool, operation_id: rsql.Positive, at: rsql.Positive },
    .cardinality = .each,
    .compound = true,
});

/// Public content at a Conversation position: an entry (ordinal 0) or a
/// Tool Result. `at` is when the entry was recorded, or, for a Tool Result,
/// when its group's last call was accepted.
pub const PublicContent = struct { id: i64, metadata: ContentMetadata, tool_operation: ?u64, admitted_at: ?u64, at: u64 };

// A cursor and a byte reader resolve the same public identity and exposed
// metadata. Neither may accept a private or absent canonical result.
/// Public content's reads, in rounds it may share with other rows. `queue`
/// the entry with its assistant check, or the Tool Result; after that
/// round, `found`, then `queueMetadata`, which also queues a Tool Result's
/// group outcome check (`ToolOutcomeCheck`);
/// after that round, `takeMetadata`, which judges that check first, as
/// main checked the group before it read the metadata.
const PublicContentRead = struct {
    position: u64,
    ordinal: u64,
    /// Where an entry's sender goes, for a caller that shows it.
    sender: ?*?protocol.NamedPeer = null,
    content: PublicContent = undefined,
    missing: missing_assistant_entry.Result = null,
    metadata: content_metadata.Row = undefined,
    outcome: ToolOutcomeCheck = .{},
    count: RowCount = .{},

    fn queue(read: *PublicContentRead, a: *ReadAccess, session: []const u8) void {
        read.missing = null;
        if (read.ordinal == 0) {
            a.read(missing_assistant_entry, .{ .session = session, .lower = read.position, .upper = read.position }, &read.missing);
            readRow(a, public_entry, .{ .session = session, .position = read.position }, read);
        } else readFirst(a, public_tool_result, .{ .session = session, .position = read.position, .ordinal = read.ordinal }, read);
    }

    pub fn visit(read: *PublicContentRead, row: anytype) bool {
        return visitRow(read, row);
    }

    fn keep(read: *PublicContentRead, row: anytype) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        if (@TypeOf(row.*) == public_entry.Row) {
            read.content = .{ .id = @intCast(row.content_id.get()), .metadata = undefined, .tool_operation = null, .admitted_at = if (row.admitted_at) |second| second.get() else null, .at = row.recorded_at.get() };
            if (read.sender) |sender| sender.* = if (row.sender) |session| .{ .session = session } else null;
        } else {
            read.content = .{ .id = @intCast(row.content_id.get()), .metadata = undefined, .tool_operation = row.operation_id.get(), .admitted_at = null, .at = row.at.get() };
        }
    }

    /// After the first round: none is `ContentNotFound`.
    fn found(read: *const PublicContentRead) !void {
        if (read.missing != null) return error.CorruptStore;
        if (!try read.count.found()) return error.ContentNotFound;
    }

    /// The outcome check first: a failure it records stops only its own
    /// read, so the metadata read still steps, and `takeMetadata` answers
    /// the check's failure before the metadata's.
    fn queueMetadata(read: *PublicContentRead, a: *ReadAccess) void {
        if (read.content.tool_operation) |operation| a.readEach(operation_outcome, .{ .operation = operation }, std.math.maxInt(u64), &read.outcome);
        a.read(content_metadata, .{ .content_id = @intCast(read.content.id) }, &read.metadata);
    }

    fn takeMetadata(read: *PublicContentRead) !void {
        if (read.content.tool_operation != null) try read.outcome.finish();
        read.content.metadata = try content_domain.publicMetadata(&read.metadata);
    }
};

/// `PublicContentRead` alone, in rounds of its own.
fn publicConversationContent(a: *ReadAccess, session: []const u8, position: u64, ordinal: u64) !PublicContent {
    var read: PublicContentRead = .{ .position = position, .ordinal = ordinal };
    read.queue(a, session);
    try runRows(a);
    try read.found();
    read.queueMetadata(a);
    try runRows(a);
    try read.takeMetadata();
    return read.content;
}

/// A call's line and outcome, with the item that proposed it.
const tool_presentation = rsql.Read(.{
    .sql = "SELECT tool_call.description,coalesce(tool_call.rejection_code,a.resolution_code) AS code,a.authorized,item.session_ref,item.session_position " ++
        "FROM model_tool_call tool_call LEFT JOIN action_operation a ON a.parent_operation_id=tool_call.operation_id AND a.call_ordinal=tool_call.call_ordinal " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE tool_call.operation_id=?1 AND tool_call.call_ordinal=?2",
    .Args = struct { operation: u64, ordinal: u64 },
    .Row = struct {
        description: ?protocol.Bounded(protocol.max_tool_description_bytes),
        code: ?protocol.ToolPresentation.Code,
        authorized: ?bool,
        session_ref: SessionText,
        session_position: rsql.Positive,
    },
    .cardinality = .each,
});

/// A call's presentation, in rounds it may share with other rows: `queue`
/// the call; after that round, `checkCall`, then `queueProposal`, the
/// Proposal of the item the call names; after that round, `finish`, which
/// judges the call's line and outcome, in main's order.
const PresentationRead = struct {
    operation: u64,
    ordinal: u64,
    out: *protocol.ToolPresentation,
    /// The call's item, whose Proposal the next round reads.
    session: SessionText = undefined,
    proposal: ProposalRead = undefined,
    code: ?protocol.ToolPresentation.Code = null,
    authorized: ?bool = null,
    count: RowCount = .{},

    fn init(operation: u64, ordinal: u64, publication_position: ?u64, out: *protocol.ToolPresentation) PresentationRead {
        out.* = .{ .description = null, .code = .unresolved, .publication_position = publication_position };
        return .{ .operation = operation, .ordinal = ordinal, .out = out };
    }

    fn queue(read: *PresentationRead, a: *ReadAccess) void {
        readRow(a, tool_presentation, .{ .operation = read.operation, .ordinal = read.ordinal }, read);
    }

    pub fn visit(read: *PresentationRead, row: *const tool_presentation.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *PresentationRead, row: *const tool_presentation.Row) error{CorruptStore}!void {
        read.out.description = row.description;
        read.code = row.code;
        read.authorized = row.authorized;
        read.session = row.session_ref;
        read.proposal = .{ .position = row.session_position.get() };
    }

    /// After the call's round: it reads `.one`, so none is `CorruptStore`.
    fn checkCall(read: *const PresentationRead) !void {
        if (!try read.count.found()) return error.CorruptStore;
    }

    fn queueProposal(read: *PresentationRead, a: *ReadAccess) void {
        readProposal(a, read.session.slice(), &read.proposal);
    }

    fn finish(read: *PresentationRead) !void {
        try read.proposal.found();
        read.out.* = try presentationOf(read.out.description, read.code, read.authorized, read.out.publication_position);
    }
};

/// A call's presentation from its line, its outcome's code, whether its
/// Action is authorized, and its group's publication, judged in main's
/// order: a line must be valid; without a code, a call is unresolved
/// once authorized and pending permission before; only a call whose tool
/// or arguments were refused may have no line.
pub fn presentationOf(
    description: ?protocol.Bounded(protocol.max_tool_description_bytes),
    code: ?protocol.ToolPresentation.Code,
    authorized: ?bool,
    publication_position: ?u64,
) error{CorruptStore}!protocol.ToolPresentation {
    var result: protocol.ToolPresentation = .{ .description = description, .code = .unresolved, .publication_position = publication_position };
    if (description) |line| if (!protocol.ToolPresentation.validDescription(line.slice())) return error.CorruptStore;
    if (code) |value| {
        result.code = value;
    } else if (!(authorized orelse false)) result.code = .pending_permission;
    if (description == null) switch (result.code) {
        .unknown_tool, .invalid_arguments => {},
        else => return error.CorruptStore,
    };
    return result;
}

/// `PresentationRead` alone, in rounds of its own.
fn toolPresentation(a: *ReadAccess, operation: u64, ordinal: u64, publication_position: ?u64) !protocol.ToolPresentation {
    var presentation: protocol.ToolPresentation = undefined;
    var read: PresentationRead = .init(operation, ordinal, publication_position, &presentation);
    read.queue(a);
    try runRows(a);
    try read.checkCall();
    read.queueProposal(a);
    try runRows(a);
    try read.finish();
    return presentation;
}

/// The hosted call at a position, with whether an accepted Operation
/// recorded it.
const hosted_call = rsql.Read(.{
    .sql = "SELECT item.description,item.call_failed,op.resolved_at," ++
        "op.session_ref=item.session_ref AND op.attempt_ordinal=item.attempt_ordinal AND op.purpose=0 AND " ++
        store_schema.oneOf("op.resolution_code", &accepted_resolutions) ++
        " AS consistent FROM model_output_item item @index(model_output_hosted_history) LEFT JOIN model_operation op ON op.operation_id=item.operation_id " ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=5",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        description: protocol.Bounded(protocol.max_tool_description_bytes),
        call_failed: bool,
        resolved_at: ?rsql.Positive,
        consistent: bool,
    },
    .cardinality = .each,
});

/// The hosted tool call at `position`, as an accepted Operation's output
/// recorded it, in a round it may share with other rows: its line and its
/// outcome go to `presentation`, and when its Operation resolved to `at`.
const HostedRead = struct {
    position: u64,
    presentation: *protocol.ToolPresentation,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *HostedRead, a: *ReadAccess, session: []const u8) void {
        readRow(a, hosted_call, .{ .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *HostedRead, row: *const hosted_call.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *HostedRead, row: *const hosted_call.Row) error{CorruptStore}!void {
        if (!row.consistent or !protocol.ToolPresentation.validDescription(row.description.slice())) return error.CorruptStore;
        read.presentation.* = .{ .description = row.description, .code = if (row.call_failed) .failed else .succeeded, .publication_position = read.position };
        read.at = (row.resolved_at orelse return error.CorruptStore).get();
    }

    /// After its round: none is `ContentNotFound`.
    fn found(read: *const HostedRead) !void {
        if (!try read.count.found()) return error.ContentNotFound;
    }
};

/// The Session columns an Activity page reads, its workspace into the
/// page itself. They are the columns main's Session facts read, so a
/// damaged one still fails the page.
const page_session = rsql.Read(.{
    .sql = "SELECT model,permission_mode,revision,next_position,compaction_trigger,output_reservation,reasoning_effort,created_at,provider,workspace " ++
        "FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        model: protocol.Bounded(protocol.max_model_bytes),
        permission_mode: u1,
        revision: rsql.Positive,
        next_position: rsql.Positive,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?protocol.ReasoningEffort,
        created_at: rsql.Positive,
        provider: protocol.Provider,
        workspace: *protocol.Bounded(protocol.max_workspace_bytes),
    },
    .cardinality = .optional,
});

/// Round 1 reads the Session and the sequence guard. Round 2 reads the
/// page's rows into this frame, with the cursor's item row; the cursor's
/// kind reads follow in rounds of their own (`readItems`). Then the rows'
/// items take the rounds their kinds need, each round shared by every
/// row, and the first of them also reads the assistant check, the call
/// activity and the queued Messages, which the page's last row bounds.
/// The work footer is a report read (`report.WorkRead`): its latest Turn
/// shares round 1 and its next stage round 2, and any later stage runs
/// after the page's rounds.
pub fn activityPage(a: *ReadAccess, request: *const protocol.ActivityPage, page: *protocol.ActivityFacts) !void {
    page.* = .{ .end = 0, .direction = request.direction, .work = .{ .workspace = .{ .len = 0 } } };
    const session_ref = request.session.slice();
    var session: page_session.Row = undefined;
    session.workspace = &page.work.workspace;
    var found: store_access.Found = undefined;
    var guard: activity_sequence_guard.Result = undefined;
    // The work footer's first two stages share the page's first two rounds.
    var work: report_domain.WorkRead = .{ .session = session_ref };
    a.readInto(page_session, .{ .session = session_ref }, &session, &found);
    a.read(activity_sequence_guard, .{ .session = session_ref }, &guard);
    _ = work.queue(a);
    try store_access.runNamed(a, .{.{ page_session, error.SessionReadFailed }} ++ report_domain.work_failures, error.CorruptStore);
    if (!found.get()) return error.SessionNotFound;
    try work.advance();
    if (session.compaction_trigger == @as(?u64, 0)) return error.CorruptStore;
    const next = session.next_position.get();
    const end = request.end orelse next - 1;
    if (end >= next or request.position > end) return error.InvalidCursor;
    if (guard != null) return error.CorruptStore;
    page.end = end;
    // The cursor as a bound on (position, ordinal): a whole position is
    // passed or kept by the largest ordinal, and a backward page with
    // no cursor starts after the end's last row.
    const forward = request.direction == .forward;
    const whole: u64 = std.math.maxInt(i64);
    const kinds = activityKinds(request.kinds);
    const limit: usize = request.limit;
    var rows: Collected(ActivityPageRow, page.items.len + 1) = .{};
    if (forward)
        a.readEach(activity_forward, .{ .session = session_ref, .end = end, .position = request.position, .ordinal = request.ordinal orelse whole, .kinds = kinds }, limit + 1, &rows)
    else
        a.readEach(activity_backward, .{ .session = session_ref, .position = if (request.position != 0) request.position else end, .ordinal = if (request.position == 0) whole else request.ordinal orelse 0, .kinds = kinds }, limit + 1, &rows);
    _ = work.queue(a);
    if (request.ordinal) |ordinal| {
        // The cursor's item, read into the first slot, which the page's
        // own first item replaces.
        readItems(1, a, session_ref, end, &.{.{ .position = request.position, .ordinal = ordinal }}, page.items[0..1], null, null) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    } else try runRows(a);
    try work.advance();
    page.count = @min(rows.len, limit);
    page.more = rows.len > limit;
    var at: [page.items.len]ItemAt = undefined;
    for (rows.slice()[0..page.count], at[0..page.count]) |row, *item| item.* = .{ .position = row.position.get(), .ordinal = row.ordinal };
    const boundary: ?ItemAt = if (page.more) at[page.count - 1] else null;
    const lower = if (forward) request.position + 1 else if (boundary) |item| item.position else 0;
    const upper = if (forward) (if (boundary) |item| item.position else end) else if (request.position == 0) end else @min(end, request.position - @intFromBool((request.ordinal orelse 0) == 0));
    const last = if (forward) boundary else null;
    const call_position = if (last) |item| item.position else end;
    var missing: missing_assistant_entry.Result = null;
    var calls: CallRows = .{ .activity = &page.call_activity, .args = .{ .session = session_ref, .position = call_position, .ordinal = if (last) |item| item.ordinal else null } };
    var waiting: QueuedMessages = .{};
    // Only a page that lists assistant rows could lose one to a damaged
    // entry; another may span much more history than it lists.
    if (lower <= upper and request.kinds.contains(.assistant)) a.read(missing_assistant_entry, .{ .session = session_ref, .lower = lower, .upper = upper }, &missing);
    // Both count what they read (`CallActivity.total`, `Queued.count`), so
    // neither has a smaller bound than every row its statement returns.
    // Only a page of every kind carries them: a filtered one, such as
    // Ctrl-P's one-row page of Messages, would scan later tool history and
    // the whole queue for footers it has no use for.
    if (request.kinds.eql(.full)) {
        a.readEach(call_activity, calls.args, std.math.maxInt(u64), &calls);
        a.readEach(queued, .{ .session = session_ref, .position = call_position }, std.math.maxInt(u64), &waiting);
    }
    try readItems(page.items.len, a, session_ref, end, at[0..page.count], page.items[0..page.count], &calls, null);
    if (missing != null) return error.CorruptStore;
    page.queued = waiting.queued;
    // Work as of this same read, so the footer, consent and first Action
    // always describe the page they arrive with.
    try report_domain.readWorks(a, (&work)[0..1]);
    page.work.work = .fromCore(try work.work(session.created_at.get(), std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange));
    page.work.revision = session.revision.get();
}

const ActivityPageRow = struct { position: rsql.Positive, ordinal: u64 };

/// An Activity item's place: its position and ordinal.
const ItemAt = struct { position: u64, ordinal: u64 };

// This projection shares the page's canonical capture, not Current's active
// Turn lifetime. It is staged until the frontend acknowledges that page.
/// The Operations whose tool group is still waiting, or completes after
/// (?2, ?3), with each group's position, and their calls after it, as the
/// CTE `candidates`. A group still waiting has an Action without its
/// result; one that completes after the page has an acceptance after it.
/// Only those Operations are grouped, not the Session's history. Each
/// acceptance read names its acceptance index: the Full results' indexes
/// hold the same rows, keyed by Operation first, and SQLite would walk
/// the Session's whole range of one of them.
const call_candidates_sql = "ops AS (SELECT parent_operation_id AS operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NULL " ++
    "UNION SELECT operation_id FROM model_tool_call @index(model_tool_call_acceptance) WHERE session_ref=?1 AND acceptance_position>=?2 " ++
    "UNION SELECT parent_operation_id FROM action_operation @index(action_operation_acceptance) WHERE session_ref=?1 AND acceptance_position>=?2), " ++
    "tool_groups AS (SELECT op.operation_id,max(coalesce(tool_call.acceptance_position,action.acceptance_position)) AS position " ++
    "FROM ops CROSS JOIN model_operation op ON op.operation_id=ops.operation_id JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " GROUP BY op.operation_id " ++
    "HAVING count(*)=(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
    "AND count(coalesce(tool_call.acceptance_position,action.acceptance_position))=count(*) " ++
    "AND count(coalesce(tool_call.rejection_content_id,action.resolution_content_id))=count(*)), " ++
    "candidates AS (SELECT op.operation_id,tool_call.call_ordinal,tool_groups.position FROM ops CROSS JOIN model_operation op ON op.operation_id=ops.operation_id " ++
    "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN tool_groups ON tool_groups.operation_id=op.operation_id WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " " ++
    "AND (tool_groups.position IS NULL OR tool_groups.position>?2 OR (tool_groups.position=?2 AND ?3 IS NOT NULL AND tool_call.call_ordinal+1>?3)))";

const CallArgs = struct { session: []const u8, position: u64, ordinal: ?u64 };
const CallRow = struct { operation_id: rsql.Positive, call_ordinal: u64, position: ?rsql.Positive };

/// The candidate calls, in Operation and call order, with each group's
/// position: main's text.
const call_activity = rsql.Read(.{
    .sql = "WITH " ++ call_candidates_sql ++ " SELECT operation_id,call_ordinal,position FROM candidates ORDER BY operation_id,call_ordinal",
    .Args = CallArgs,
    .Row = CallRow,
    .cardinality = .each,
    .compound = true,
});

/// The tool outcome rule (`ToolOutcome`) over the candidates' Operations,
/// for a page whose candidates span more than `CallRows.max_operations`.
const call_outcomes = ToolOutcome(call_candidates_sql ++ ", ", "SELECT DISTINCT operation_id," ++ expectedCallsSql("candidates.operation_id") ++ " FROM candidates", CallArgs, true);

/// A page's call activity, as main's walk read it while it stepped: every
/// call counted in `activity.total`, and the first three kept, whose
/// presentations the item rounds after it read (`queue`, `take`), each
/// with its group position as its publication. Main checked each
/// Operation's outcome facts as its first row arrived, and that their
/// publication was the group position; round 1 judges the same
/// Operations by the tool outcome rule before any presentation is taken:
/// each by itself (`operation_outcome`) while they are at most
/// `max_operations`, which `operations` holds, and else all of them in
/// one read (`call_outcomes`). One read repeats the candidates' search,
/// so it steps more than the reads one per Operation at every count
/// measured, and more than main (3 Operations: 14135 steps against
/// 13477 and main's 13722; 33: 30629 against 26131 and 27606); only the
/// frame bounds `max_operations`. Main's equality holds by the schema's
/// CHECKs, not the rule: a call has an acceptance exactly when it is
/// rejected (`model_tool_call`'s) or its Action resolved
/// (`action_operation`'s), and then has its rejection's or result's
/// content, so an Operation the rule passes is a group, at its largest
/// acceptance, exactly when every call has one, and its publication is
/// then that acceptance. It keeps no row, so its read steps every row the
/// statement returns: a count has no smaller bound.
const CallRows = struct {
    activity: *protocol.CallActivity,
    args: CallArgs,
    /// The candidates' first Operations, in order, and how many there
    /// are, up to one past what it holds.
    operations: [max_operations]u64 = undefined,
    operation_count: usize = 0,
    check: ToolOutcomeCheck = .{},
    presentations: [@typeInfo(@FieldType(protocol.CallActivity, "entries")).array.len]PresentationRead = undefined,

    const max_operations = 32;

    pub fn visit(rows: *CallRows, row: *const CallRow) bool {
        const operation = row.operation_id.get();
        const held = @min(rows.operation_count, max_operations);
        if (held == 0 or rows.operations[held - 1] != operation) {
            if (rows.operation_count < max_operations) rows.operations[rows.operation_count] = operation;
            if (rows.operation_count <= max_operations) rows.operation_count += 1;
        }
        const activity = rows.activity;
        activity.total += 1;
        if (activity.count < activity.entries.len) {
            const entry = &activity.entries[activity.count];
            entry.* = .{ .operation = operation, .ordinal = row.call_ordinal, .presentation = undefined };
            rows.presentations[activity.count] = .init(operation, row.call_ordinal, optionalPositive(row.position), &entry.presentation);
            activity.count += 1;
        }
        return true;
    }

    /// Queues round `round`'s reads: the rule and the kept calls in round
    /// 1, their Proposals in round 2. The caller queued the call read
    /// itself before round 0. True when it queued; with no call, there is
    /// nothing to judge.
    fn queue(rows: *CallRows, a: *ReadAccess, round: u8) bool {
        const kept = rows.presentations[0..rows.activity.count];
        switch (round) {
            1 => {
                if (rows.operation_count > max_operations)
                    a.readEach(call_outcomes, rows.args, std.math.maxInt(u64), &rows.check)
                else for (rows.operations[0..rows.operation_count]) |operation|
                    a.readEach(operation_outcome, .{ .operation = operation }, std.math.maxInt(u64), &rows.check);
                for (kept) |*presentation| presentation.queue(a);
            },
            2 => for (kept) |*presentation| presentation.queueProposal(a),
            else => return false,
        }
        return kept.len != 0;
    }

    /// Takes round `round`'s rows, once it ran.
    fn take(rows: *CallRows, round: u8) !void {
        const kept = rows.presentations[0..rows.activity.count];
        switch (round) {
            1 => {
                try rows.check.finish();
                for (kept) |*presentation| try presentation.checkCall();
            },
            2 => for (kept) |*presentation| try presentation.finish(),
            else => {},
        }
    }
};

/// The Messages a person or script sent that were admitted at or before
/// a position and not taken there (`queued`). Selection and a stop's
/// exclusion take admission-order prefixes, and Admission positions
/// follow admission order, so the walk seeks the position and goes down,
/// ending at the first one taken: it reads those waiting and one more.
/// Every Message at the position precedes its tool completions, so a
/// boundary's ordinal changes nothing. It keeps no row, only the count
/// and its ends.
pub const QueuedMessages = struct {
    queued: protocol.Queued = .{},

    pub fn visit(messages: *QueuedMessages, row: *const queued.Row) bool {
        if (row.taken) return false;
        if (messages.queued.count == 0) {
            messages.queued.newest_admission = row.admission_id.get();
            messages.queued.newest_position = row.admission_position.get();
        }
        messages.queued.count += 1;
        messages.queued.oldest_position = row.admission_position.get();
        return true;
    }
};

/// A Session's label as the Store holds it now.
const peer_label = rsql.Read(.{
    .sql = "SELECT label FROM session WHERE session_ref=?1",
    .Args = struct { session: SessionText },
    .Row = struct { label: ?protocol.Bounded(protocol.max_label_bytes) },
    .cardinality = .each,
});

/// An admitted Message of the Session, with whether it was applied or
/// excluded at end ?2 and whether its command and Turn agree with it.
const activity_message = rsql.Read(.{
    .sql = "SELECT m.command_key,m.turn_id,m.content_id," ++
        "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=m.session_ref AND e.source_admission_id=m.admission_id AND e.session_position<=?2) AS applied," ++
        "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=m.session_ref AND s.admission_cutoff>=m.admission_id AND s.position<=?2) AS excluded," ++
        "c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id " ++
        "AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
        "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))) AS consistent," ++
        "m.admitted_at,m.sender_session_ref FROM message_admission m " ++
        "LEFT JOIN core_command c ON c.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "WHERE m.session_ref=?1 AND m.admission_id=?3",
    .Args = struct { session: []const u8, end: u64, admission: u64 },
    .Row = struct {
        command_key: protocol.Bounded(protocol.max_key_bytes),
        turn_id: ?rsql.Positive,
        content_id: rsql.Positive,
        applied: bool,
        excluded: bool,
        consistent: bool,
        admitted_at: rsql.Positive,
        sender_session_ref: ?SessionText,
    },
    .cardinality = .each,
});

/// When the Operation of a call proposed in the Session resolved.
/// The call Action ?1 of Session ?2 waits on, dated by its Operation's
/// settlement, which saved the Action with the request for approval.
const approval_request = rsql.Read(.{
    .sql = "SELECT action.parent_operation_id AS operation,action.call_ordinal,op.resolved_at FROM action_operation action " ++
        "JOIN model_operation op ON op.operation_id=action.parent_operation_id AND op.session_ref=action.session_ref WHERE action.action_id=?1 AND action.session_ref=?2",
    .Args = struct { action: u64, session: []const u8 },
    .Row = struct { operation: rsql.Positive, call_ordinal: u64, resolved_at: rsql.Positive },
    .cardinality = .optional,
});

/// The setting Session ?1 changed at position ?2, ordinal ?3.
const session_change = rsql.Read(.{
    .sql = "SELECT revision,field,changed_at FROM session_change WHERE session_ref=?1 AND position=?2 AND ordinal=?3",
    .Args = struct { session: []const u8, position: u64, ordinal: u64 },
    .Row = struct { revision: rsql.Positive, field: protocol.SessionField, changed_at: rsql.Positive },
    .cardinality = .one,
});

/// Compaction Operation ?1 of Session ?2, which succeeded: what its floor
/// dropped, and when it was settled.
const compaction_row = rsql.Read(.{
    .sql = "SELECT coalesce(history_dropped,0) AS dropped,resolved_at FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND purpose=1 AND " ++
        store_schema.resolutionIs("resolution_code", .compacted),
    .Args = struct { operation: u64, session: []const u8 },
    .Row = struct { dropped: u64, resolved_at: rsql.Positive },
    .cardinality = .one,
});

const call_resolved = rsql.Read(.{
    .sql = "SELECT resolved_at FROM model_operation WHERE operation_id=?1 AND session_ref=?2",
    .Args = struct { operation: u64, session: []const u8 },
    .Row = struct { resolved_at: rsql.Positive },
    .cardinality = .one,
});

/// A Message the Session sent from position ?3, with whether its command
/// agrees with it.
const sent_message = rsql.Read(.{
    .sql = "SELECT m.session_ref,m.content_id,m.admitted_at,c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id AS consistent " ++
        "FROM message_admission m LEFT JOIN core_command c ON c.command_key=m.command_key WHERE m.admission_id=?1 AND m.sender_session_ref=?2 AND m.sender_position=?3",
    .Args = struct { admission: u64, session: []const u8, position: u64 },
    .Row = struct { session_ref: SessionText, content_id: rsql.Positive, admitted_at: rsql.Positive, consistent: bool },
    .cardinality = .each,
});

/// A send the Host refused at position ?2, with whether its command
/// agrees with it.
const send_failure = rsql.Read(.{
    .sql = "SELECT s.command_key,c.target,c.code,c.kind=2 AND c.accepted=0 AS consistent,s.rejected_at FROM sent_rejection s " ++
        "LEFT JOIN core_command c ON c.command_key=s.command_key WHERE s.sender_session_ref=?1 AND s.sender_position=?2",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        command_key: protocol.Bounded(protocol.max_key_bytes),
        target: SessionText,
        code: protocol.Bounded(protocol.max_code_bytes),
        consistent: bool,
        rejected_at: rsql.Positive,
    },
    .cardinality = .each,
});

/// A Turn's outcome at position ?2, with its causing Operation's, and
/// whether a Session stop selected the Turn.
const turn_outcome = rsql.Read(.{
    .sql = "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.session_ref=t.session_ref AND o.turn_id=t.turn_id " ++
        "AND o.resolution_code IS NOT NULL AS consistent,o.resolution_content_id,t.outcome_at," ++
        "EXISTS(SELECT 1 FROM session_stop stop @index(session_stop_turn) WHERE stop.selected_turn_id=t.turn_id) AS stopped " ++
        "FROM turn t LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
        "WHERE t.session_ref=?1 AND t.outcome_position=?2",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        turn_id: rsql.Positive,
        operation_id: rsql.Positive,
        outcome_code: protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        consistent: bool,
        resolution_content_id: ?rsql.Positive,
        outcome_at: rsql.Positive,
        stopped: bool,
    },
    .cardinality = .each,
});

/// A stop at position ?2, with whether its command and selected Turn
/// agree with it.
const session_stop = rsql.Read(.{
    .sql = "SELECT s.command_key,s.selected_turn_id,s.admission_cutoff,t.outcome_position," ++
        "c.kind=3 AND c.accepted=1 AND c.target=s.session_ref AND (s.selected_turn_id IS NULL OR t.session_ref=s.session_ref) AS consistent,s.stopped_at " ++
        "FROM session_stop s LEFT JOIN core_command c ON c.command_key=s.command_key LEFT JOIN turn t ON t.turn_id=s.selected_turn_id WHERE s.session_ref=?1 AND s.position=?2",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        command_key: protocol.Bounded(protocol.max_key_bytes),
        selected_turn_id: ?rsql.Positive,
        admission_cutoff: u64,
        outcome_position: ?rsql.Positive,
        consistent: bool,
        stopped_at: rsql.Positive,
    },
    .cardinality = .each,
});

/// A peer Session's label as the Store holds it now, so a rename shows on
/// every row that names it, read into `peer` in a round it may share with
/// other rows. A failed send can name a Session this Store never held,
/// which has no label.
const LabelRead = struct {
    peer: *protocol.NamedPeer,
    count: RowCount = .{},

    fn queue(read: *LabelRead, a: *ReadAccess) void {
        readRow(a, peer_label, .{ .session = read.peer.session }, read);
    }

    pub fn visit(read: *LabelRead, row: *const peer_label.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *LabelRead, row: *const peer_label.Row) error{CorruptStore}!void {
        if (row.label) |*label| {
            try configuration_domain.checkLabel(label.slice());
            read.peer.label = label.*;
        }
    }

    fn found(read: *const LabelRead) !void {
        _ = try read.count.found();
    }
};

/// An admitted Message (kinds 1 and 2), read into `message`; the content
/// it names is the next round's.
const MessageRead = struct {
    message: *protocol.ActivityItem.Message,
    content_id: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *MessageRead, a: *ReadAccess, session: []const u8, end: u64) void {
        readRow(a, activity_message, .{ .session = session, .end = end, .admission = read.message.admission }, read);
    }

    pub fn visit(read: *MessageRead, row: *const activity_message.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *MessageRead, row: *const activity_message.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        const message = read.message;
        message.key = row.command_key;
        message.turn = null;
        message.state = if (row.applied) .applied else if (row.excluded) .excluded else .queued;
        message.admitted_at = row.admitted_at.get();
        message.sender = if (row.sender_session_ref) |sender| .{ .session = sender } else null;
        if (row.applied) message.turn = (row.turn_id orelse return error.CorruptStore).get();
        read.content_id = row.content_id.get();
    }
};

/// A Message this Session sent (kind 8), read into `sent`.
const SentRead = struct {
    position: u64,
    sent: *protocol.ActivityItem.Sent,
    content_id: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *SentRead, a: *ReadAccess, session: []const u8) void {
        readRow(a, sent_message, .{ .admission = read.sent.admission, .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *SentRead, row: *const sent_message.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *SentRead, row: *const sent_message.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        read.sent.target = .{ .session = row.session_ref };
        read.sent.admitted_at = row.admitted_at.get();
        read.content_id = row.content_id.get();
    }
};

/// A send this Session's target refused (kind 9), read into `failed`.
const FailureRead = struct {
    position: u64,
    failed: *protocol.ActivityItem.SendFailed,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *FailureRead, a: *ReadAccess, session: []const u8) void {
        readRow(a, send_failure, .{ .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *FailureRead, row: *const send_failure.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *FailureRead, row: *const send_failure.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        read.failed.* = .{ .key = row.command_key, .target = .{ .session = row.target }, .code = row.code };
        read.at = row.rejected_at.get();
    }
};

/// A Turn's outcome (kind 6), with its Resolution's answer, read into
/// `outcome`; its content, if any, is the next round's.
const OutcomeRead = struct {
    position: u64,
    outcome: *protocol.ActivityItem.TurnEnded,
    content_id: ?u64 = null,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *OutcomeRead, a: *ReadAccess, session: []const u8) void {
        readFirst(a, turn_outcome, .{ .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *OutcomeRead, row: *const turn_outcome.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *OutcomeRead, row: *const turn_outcome.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        read.content_id = if (row.outcome_content_id) |id| id.get() else null;
        const outcome = try TurnOutcome.decode(row.outcome_code.slice(), if (read.content_id) |id| @intCast(id) else null);
        switch (outcome) {
            // A completed Turn answers with its causing Operation's Resolution.
            .completed => |answer| if (row.resolution_content_id == null or row.resolution_content_id.?.get() != answer) return error.CorruptStore,
            .cancelled, .retry_exhausted, .resource_exceeded, .failed => {},
        }
        read.outcome.* = .{ .turn = row.turn_id.get(), .operation = row.operation_id.get(), .ending = outcome.ending(row.stopped), .code = row.outcome_code, .content = null };
        read.at = row.outcome_at.get();
    }
};

/// A Session stop (kind 7) and whether its Turn has finished by `end`,
/// read into `stop`.
const StopRead = struct {
    position: u64,
    end: u64,
    stop: *protocol.ActivityItem.Stop,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *StopRead, a: *ReadAccess, session: []const u8) void {
        readFirst(a, session_stop, .{ .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *StopRead, row: *const session_stop.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *StopRead, row: *const session_stop.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        const turn: ?u64 = if (row.selected_turn_id) |id| id.get() else null;
        const outcome_position: ?u64 = if (row.outcome_position) |at| at.get() else null;
        read.stop.* = .{ .key = row.command_key, .turn = turn, .cutoff = row.admission_cutoff, .completion = if (turn == null or (outcome_position != null and outcome_position.? <= read.end)) .completed else .pending };
        read.at = row.stopped_at.get();
    }
};

/// One Activity item's reads, in rounds shared with the other items of its
/// page (`readItems`). Round 1 reads its row, with the assistant check of
/// an ordinal 0 position at or before `end`. Each later round reads only
/// what the one before named, per kind; `queue` queues the next round's
/// reads and `take` takes them once it ran, writing the item as its rows
/// arrive. The kinds main answered `CorruptStore` for a failed step of
/// answer it still (`read_failures`).
const ItemRead = struct {
    position: u64,
    ordinal: u64,
    item: *protocol.ActivityItem,
    /// The content the item exposes, once its metadata is read.
    content: ?struct { id: u64, value: *const protocol.ActivityItem.Content } = null,
    round: u8 = 0,
    done: bool = false,
    kind: u8 = 0,
    state: union {
        first: struct { missing: missing_assistant_entry.Result, row: activity_item.Result },
        message: struct { read: MessageRead, metadata: content_metadata.Row = undefined, label: LabelRead = undefined, entry: PublicContentRead },
        content: struct { read: PublicContentRead, presentation: PresentationRead = undefined, answer: answer_entry.Result = null },
        call: struct { proposal: ProposalRead, resolved: call_resolved.Row = undefined },
        hosted: HostedRead,
        sent: struct { read: SentRead, metadata: content_metadata.Row = undefined, label: LabelRead = undefined },
        failure: struct { read: FailureRead, label: LabelRead = undefined },
        outcome: struct { read: OutcomeRead, metadata: content_metadata.Row = undefined },
        stop: StopRead,
        approval: approval_request.Result,
        change: session_change.Row,
        compaction: compaction_row.Row,
    } = undefined,

    fn queue(read: *ItemRead, a: *ReadAccess, session: []const u8, end: u64) void {
        const item = read.item;
        if (read.round == 0) {
            read.state = .{ .first = .{ .missing = null, .row = undefined } };
            const first = &read.state.first;
            if (read.ordinal == 0 and read.position <= end) a.read(missing_assistant_entry, .{ .session = session, .lower = read.position, .upper = read.position }, &first.missing);
            a.read(activity_item, .{ .session = session, .end = end, .position = read.position, .ordinal = read.ordinal }, &first.row);
            return;
        }
        switch (read.kind) {
            1, 2, 11 => |kind| {
                const message = &read.state.message;
                if (read.round == 1) {
                    message.read.queue(a, session, end);
                    if (kind == 2) message.entry.queue(a, session);
                } else {
                    a.read(content_metadata, .{ .content_id = message.read.content_id }, &message.metadata);
                    if (message.read.message.sender) |*sender| {
                        message.label = .{ .peer = sender };
                        message.label.queue(a);
                    }
                    if (kind == 2) message.entry.queueMetadata(a);
                }
            },
            3, 5 => {
                const content = &read.state.content;
                switch (read.round) {
                    1 => content.read.queue(a, session),
                    2 => {
                        content.read.queueMetadata(a);
                        if (read.kind == 3) a.read(answer_entry, .{ .session = session, .position = read.position, .end = end }, &content.answer);
                        if (read.kind == 5) {
                            item.value = .{ .tool_result = undefined };
                            content.presentation = .init(content.read.content.tool_operation.?, read.ordinal - 1, read.position, &item.value.tool_result.presentation);
                            content.presentation.queue(a);
                        }
                    },
                    else => content.presentation.queueProposal(a),
                }
            },
            4 => {
                const call = &read.state.call;
                if (read.round == 1) readProposal(a, session, &call.proposal) else a.read(call_resolved, .{ .operation = item.value.call.operation, .session = session }, &call.resolved);
            },
            10 => read.state.hosted.queue(a, session),
            8 => {
                const sent = &read.state.sent;
                if (read.round == 1) sent.read.queue(a, session) else {
                    a.read(content_metadata, .{ .content_id = sent.read.content_id }, &sent.metadata);
                    sent.label = .{ .peer = &item.value.sent.target };
                    sent.label.queue(a);
                }
            },
            9 => {
                const failure = &read.state.failure;
                if (read.round == 1) failure.read.queue(a, session) else {
                    failure.label = .{ .peer = &item.value.send_failed.target };
                    failure.label.queue(a);
                }
            },
            6 => {
                const outcome = &read.state.outcome;
                if (read.round == 1) outcome.read.queue(a, session) else a.read(content_metadata, .{ .content_id = outcome.read.content_id.? }, &outcome.metadata);
            },
            7 => read.state.stop.queue(a, session),
            12 => a.read(approval_request, .{ .action = item.value.approval_requested.action, .session = session }, &read.state.approval),
            13 => a.read(session_change, .{ .session = session, .position = read.position, .ordinal = read.ordinal }, &read.state.change),
            14 => a.read(compaction_row, .{ .operation = item.value.compacted.operation, .session = session }, &read.state.compaction),
            else => unreachable,
        }
    }

    fn take(read: *ItemRead) !void {
        defer read.round += 1;
        const item = read.item;
        if (read.round == 0) return read.takeRow();
        switch (read.kind) {
            1, 2, 11 => |kind| {
                const message = &read.state.message;
                if (read.round == 1) {
                    if (!try message.read.count.found()) return error.CorruptStore;
                    // A source names a person's Message or a received one
                    // by its sender; the row read must agree.
                    if (kind != 2 and (kind == 11) != (message.read.message.sender != null)) return error.CorruptStore;
                    if (kind == 2) try message.entry.found();
                    return;
                }
                const content = try content_domain.publicMetadata(&message.metadata);
                message.read.message.content = .{ .length = content.length, .digest = content.digest };
                if (message.read.message.sender != null) try message.label.found();
                item.at = message.read.message.admitted_at;
                if (kind == 2) {
                    if (message.read.message.state != .applied) return error.CorruptStore;
                    try message.entry.takeMetadata();
                    if (message.entry.content.id != message.read.content_id) return error.CorruptStore;
                    item.at = message.entry.content.at;
                }
                read.exposes(message.read.content_id, &message.read.message.content);
            },
            3, 5 => {
                const content = &read.state.content;
                switch (read.round) {
                    1 => return content.read.found(),
                    2 => {
                        try content.read.takeMetadata();
                        const found = content.read.content;
                        item.at = found.at;
                        const value: protocol.ActivityItem.Content = .{ .length = found.metadata.length, .digest = found.metadata.digest };
                        if (read.kind == 3) {
                            item.value = .{ .assistant = .{ .content = value, .final = content.answer != null } };
                            read.exposes(@intCast(found.id), &item.value.assistant.content);
                            read.done = true;
                            return;
                        }
                        if (found.tool_operation == null) return error.CorruptStore;
                        item.value.tool_result.content = value;
                        read.exposes(@intCast(found.id), &item.value.tool_result.content);
                        return content.presentation.checkCall();
                    },
                    else => try content.presentation.finish(),
                }
            },
            4 => {
                const call = &read.state.call;
                if (read.round == 1) return call.proposal.found();
                item.at = call.resolved.resolved_at.get();
            },
            10 => {
                try read.state.hosted.found();
                item.at = read.state.hosted.at;
            },
            8 => {
                const sent = &read.state.sent;
                if (read.round == 1) {
                    if (!try sent.read.count.found()) return error.CorruptStore;
                    item.at = item.value.sent.admitted_at;
                    return;
                }
                const content = try content_domain.publicMetadata(&sent.metadata);
                item.value.sent.content = .{ .length = content.length, .digest = content.digest };
                try sent.label.found();
                read.exposes(sent.read.content_id, &item.value.sent.content);
            },
            9 => {
                const failure = &read.state.failure;
                if (read.round == 1) {
                    if (!try failure.read.count.found()) return error.CorruptStore;
                    item.at = failure.read.at;
                    return;
                }
                try failure.label.found();
            },
            6 => {
                const outcome = &read.state.outcome;
                if (read.round == 1) {
                    if (!try outcome.read.count.found()) return error.CorruptStore;
                    item.at = outcome.read.at;
                    if (outcome.read.content_id != null) return;
                } else {
                    const content = try content_domain.publicMetadata(&outcome.metadata);
                    item.value.turn_ended.content = .{ .length = content.length, .digest = content.digest };
                    read.exposes(outcome.read.content_id.?, &item.value.turn_ended.content.?);
                }
            },
            7 => {
                if (!try read.state.stop.count.found()) return error.CorruptStore;
                item.at = read.state.stop.at;
            },
            12 => {
                const row = read.state.approval orelse return error.CorruptStore;
                item.value.approval_requested.operation = row.operation.get();
                item.value.approval_requested.call_ordinal = row.call_ordinal;
                item.at = row.resolved_at.get();
            },
            13 => {
                const row = &read.state.change;
                if (row.revision.get() != item.value.session_changed.revision) return error.CorruptStore;
                item.value.session_changed.field = row.field;
                item.at = row.changed_at.get();
            },
            14 => {
                item.value.compacted.dropped = read.state.compaction.dropped;
                item.at = read.state.compaction.resolved_at.get();
            },
            else => unreachable,
        }
        read.done = true;
    }

    /// Round 1's row: the kind, and the state its reads need.
    fn takeRow(read: *ItemRead) !void {
        const first = read.state.first;
        if (first.missing != null) return error.CorruptStore;
        const row = first.row orelse return error.ContentNotFound;
        const item = read.item;
        item.* = .{ .position = read.position, .ordinal = read.ordinal, .at = undefined, .value = undefined };
        read.kind = row.kind;
        switch (row.kind) {
            1, 2, 11 => {
                const admission = (row.id orelse return error.CorruptStore).get();
                item.value = switch (row.kind) {
                    1 => .{ .admission = undefined },
                    11 => .{ .received = undefined },
                    else => .{ .user = undefined },
                };
                const message = switch (item.value) {
                    .admission, .received, .user => |*message| message,
                    else => unreachable,
                };
                message.admission = admission;
                read.state = .{ .message = .{ .read = .{ .message = message }, .entry = .{ .position = read.position, .ordinal = read.ordinal } } };
            },
            3, 5 => read.state = .{ .content = .{ .read = .{ .position = read.position, .ordinal = read.ordinal } } },
            4 => {
                item.value = .{ .call = undefined };
                read.state = .{ .call = .{ .proposal = .{ .position = read.position, .metadata = &item.value.call } } };
            },
            10 => {
                item.value = .{ .hosted_call = undefined };
                read.state = .{ .hosted = .{ .position = read.position, .presentation = &item.value.hosted_call } };
            },
            8 => {
                const admission = (row.id orelse return error.CorruptStore).get();
                item.value = .{ .sent = undefined };
                item.value.sent.admission = admission;
                read.state = .{ .sent = .{ .read = .{ .position = read.position, .sent = &item.value.sent } } };
            },
            9 => {
                item.value = .{ .send_failed = undefined };
                read.state = .{ .failure = .{ .read = .{ .position = read.position, .failed = &item.value.send_failed } } };
            },
            6 => {
                item.value = .{ .turn_ended = undefined };
                read.state = .{ .outcome = .{ .read = .{ .position = read.position, .outcome = &item.value.turn_ended } } };
            },
            7 => {
                item.value = .{ .stop = undefined };
                read.state = .{ .stop = .{ .position = read.position, .end = undefined, .stop = &item.value.stop } };
            },
            12 => {
                item.value = .{ .approval_requested = .{ .action = (row.id orelse return error.CorruptStore).get(), .operation = undefined, .call_ordinal = undefined } };
                read.state = .{ .approval = null };
            },
            13 => {
                item.value = .{ .session_changed = .{ .revision = (row.id orelse return error.CorruptStore).get(), .field = undefined } };
                read.state = .{ .change = undefined };
            },
            14 => {
                item.value = .{ .compacted = .{ .operation = (row.id orelse return error.CorruptStore).get(), .dropped = undefined } };
                read.state = .{ .compaction = undefined };
            },
            else => return error.CorruptStore,
        }
    }

    fn exposes(read: *ItemRead, id: u64, value: *const protocol.ActivityItem.Content) void {
        read.content = .{ .id = id, .value = value };
    }

    /// The content the item exposes, for a byte reader.
    fn located(read: *const ItemRead) ?Located {
        const content = read.content orelse return null;
        return .{ .id = @intCast(content.id), .metadata = .{ .length = content.value.length, .digest = content.value.digest, .private = false } };
    }
};

/// Content an Activity item exposes: its row and public metadata.
const Located = struct { id: i64, metadata: ContentMetadata };

/// Reads the items at `at` through `end` into `items`, each round shared
/// by every item (`ItemRead`), with an Activity page's call presentations
/// (`calls`) in the rounds after its call read. Round 1 also runs what the
/// caller queued before it. `max` bounds the items, so a lone item's read
/// keeps a page's state out of its frame; `located`, when given, receives
/// the content the first item exposes. Not inlined, so this state takes
/// no slot in its caller's frame.
noinline fn readItems(comptime max: usize, a: *ReadAccess, session: []const u8, end: u64, at: []const ItemAt, items: []protocol.ActivityItem, calls: ?*CallRows, located: ?*?Located) !void {
    var reads: [max]ItemRead = undefined;
    for (at, items, reads[0..at.len]) |place, *item, *read| read.* = .{ .position = place.position, .ordinal = place.ordinal, .item = item };
    var round: u8 = 0;
    while (true) : (round += 1) {
        // Every item not done queues a read in each round.
        var busy = round == 0;
        for (reads[0..at.len]) |*read| if (!read.done) {
            if (read.kind == 7) read.state.stop.end = end;
            read.queue(a, session, end);
            busy = true;
        };
        if (calls) |activity| if (activity.queue(a, round)) {
            busy = true;
        };
        if (!busy) break;
        try runRows(a);
        for (reads[0..at.len]) |*read| if (!read.done) try read.take();
        if (calls) |activity| try activity.take(round);
    }
    if (located) |first| first.* = reads[0].located();
}

/// Round 1 reads the sequence guard; the item's own reads follow
/// (`publicConversationContent`, `readItems`), which read the content's
/// metadata, so no read repeats it.
pub fn openActivityContent(a: *ReadAccess, request: *const protocol.ReadActivityContent) !ContentLocation {
    var guard: activity_sequence_guard.Result = undefined;
    a.read(activity_sequence_guard, .{ .session = request.session.slice() }, &guard);
    a.run() catch |err| return store_core.fence(a.store, if (err == error.StatementFailed) error.CorruptStore else err);
    if (guard != null) return store_core.fence(a.store, error.CorruptStore);
    // Only Tool Results have nonzero ordinals and content (an approval
    // request's ordinal 1 has none). Byte readers need their
    // canonical identity, not a second scan of the original arguments.
    const content: Located = if (request.ordinal != 0) located: {
        const found = publicConversationContent(a, request.session.slice(), request.position, request.ordinal) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(a.store, err),
        };
        break :located .{ .id = found.id, .metadata = found.metadata };
    } else located: {
        var item: protocol.ActivityItem = undefined;
        var located: ?Located = null;
        readItems(1, a, request.session.slice(), std.math.maxInt(i64), &.{.{ .position = request.position, .ordinal = 0 }}, (&item)[0..1], null, &located) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(a.store, err),
        };
        break :located located orelse return error.ContentNotFound;
    };
    return .{ .store = a.store, .content_id = content.id, .reference = .{ .length = content.metadata.length, .digest = content.metadata.digest } };
}

/// The public identity and saved line of a call or Tool Result. This uses
/// the same Proposal and presentation provenance checks as activity pages;
/// the result's group position is not the original call's position.
pub const ActivityTool = struct {
    name: protocol.ProposalFieldReference,
    presentation: protocol.ToolPresentation,
};

pub fn activityTool(a: *ReadAccess, request: *const protocol.ReadActivityContent) !ActivityTool {
    var metadata: protocol.ProposalMetadata = undefined;
    var presentation: protocol.ToolPresentation = undefined;
    const operation, const ordinal = if (request.ordinal == 0) call: {
        metadata = try proposal(a, request.session.slice(), request.position);
        break :call .{ metadata.operation, metadata.call_ordinal };
    } else result: {
        const content = try publicConversationContent(a, request.session.slice(), request.position, request.ordinal);
        break :result .{ content.tool_operation orelse return error.ContentNotFound, request.ordinal - 1 };
    };
    var read: PresentationRead = .init(operation, ordinal, null, &presentation);
    read.queue(a);
    try runRows(a);
    try read.checkCall();
    read.proposal.metadata = &metadata;
    read.queueProposal(a);
    try runRows(a);
    try read.finish();
    return .{ .name = metadata.fields[@backingInt(protocol.ProposalField.name)], .presentation = presentation };
}

/// The content columns of a Proposal's three fields, in ProposalField order.
const proposal_fields = [3][]const u8{ "name_content_id", "call_id_content_id", "arguments_content_id" };

/// A Proposal's columns over its item `item`, and the joins they read
/// (`proposal_joins`), which the tool outcome rule shares
/// (`ToolOutcome`). LEFT JOIN keeps missing or contradictory owners
/// visible as corruption.
const proposal_columns = "item.operation_id,op.turn_id,tool_call.call_ordinal,action.action_id,tool_call.rejection_code," ++
    "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id," ++
    "CASE WHEN op.session_ref=item.session_ref AND t.session_ref=item.session_ref AND " ++
    store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " AND op.attempt_ordinal=item.attempt_ordinal AND " ++
    "((tool_call.rejection_code IS NOT NULL AND action.action_id IS NULL AND tool_call.acceptance_position IS NOT NULL AND " ++
    "rejection.content_id IS NOT NULL AND rejection.private=0) OR " ++
    "(tool_call.rejection_code IS NULL AND action.action_id IS NOT NULL AND action.session_ref=item.session_ref)) " ++
    "THEN 1 ELSE 0 END AS consistent,tool_call.field_metadata," ++
    "field0.byte_length AS length0,field0.digest AS digest0,field0.private AS private0," ++
    "field1.byte_length AS length1,field1.digest AS digest1,field1.private AS private1," ++
    "field2.byte_length AS length2,field2.digest AS digest2,field2.private AS private2";

/// The joins `proposal_columns` reads, off the item `item`: its
/// Operation `op`, Turn `t`, call `tool_call`, the call's rejection,
/// Action `action` and fields.
const proposal_joins = "LEFT JOIN model_operation op ON op.operation_id=item.operation_id LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
    "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
    "LEFT JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "LEFT JOIN content field0 ON field0.content_id=tool_call." ++ proposal_fields[0] ++ " " ++
    "LEFT JOIN content field1 ON field1.content_id=tool_call." ++ proposal_fields[1] ++ " " ++
    "LEFT JOIN content field2 ON field2.content_id=tool_call." ++ proposal_fields[2] ++ " ";

// Every caller (Activity pages, Action reads, call outcomes, the report) shares one provenance check.
/// The Proposal at a Session position, with each field's content row.
pub const proposal_row = rsql.Read(.{
    .sql = "SELECT " ++ proposal_columns ++ " FROM model_output_item item " ++ proposal_joins ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=3",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        call_ordinal: u64,
        action_id: ?rsql.Positive,
        rejection_code: ?protocol.ProposalRejection,
        name_content_id: rsql.Positive,
        call_id_content_id: rsql.Positive,
        arguments_content_id: rsql.Positive,
        consistent: bool,
        /// Three admission-certified (little-endian length, SHA-256) pairs.
        field_metadata: [120]u8,
        length0: u64,
        digest0: [32]u8,
        private0: bool,
        length1: u64,
        digest1: [32]u8,
        private1: bool,
        length2: u64,
        digest2: [32]u8,
        private2: bool,
    },
    .cardinality = .each,
});

/// The Proposal at `position`, read in a round it may share with other
/// rows (`readProposal`), into `metadata` when the caller keeps it. Each field's content must be public and match the
/// metadata admission certified, so reference substitution is detectable
/// without reopening payloads.
pub const ProposalRead = struct {
    position: u64,
    metadata: ?*protocol.ProposalMetadata = null,
    count: RowCount = .{},

    pub fn visit(read: *ProposalRead, row: *const proposal_row.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *ProposalRead, row: *const proposal_row.Row) error{CorruptStore}!void {
        const fields = try certifiedFields(row);
        if (read.metadata) |metadata| metadata.* = .{
            .position = read.position,
            .operation = row.operation_id.get(),
            .turn = row.turn_id.get(),
            .call_ordinal = row.call_ordinal,
            .action = if (row.action_id) |action| action.get() else null,
            .rejection = row.rejection_code,
            .fields = fields,
        };
    }

    /// After its round: none is `ContentNotFound`, a second or damaged one
    /// `CorruptStore`.
    pub fn found(read: *const ProposalRead) error{ ContentNotFound, CorruptStore }!void {
        if (!try read.count.found()) return error.ContentNotFound;
    }
};

/// A Proposal's fields, once it is consistent and each field's content is
/// public and matches the metadata admission certified, so reference
/// substitution is detectable without reopening payloads.
fn certifiedFields(row: *const proposal_row.Row) error{CorruptStore}![3]protocol.ProposalFieldReference {
    if (!row.consistent) return error.CorruptStore;
    var fields: [3]protocol.ProposalFieldReference = undefined;
    inline for (0..3) |index| {
        const suffix = std.fmt.comptimePrint("{d}", .{index});
        const length: u64 = @field(row, "length" ++ suffix);
        const digest: [32]u8 = @field(row, "digest" ++ suffix);
        const certified = row.field_metadata[index * 40 ..][0..40];
        if (@field(row, "private" ++ suffix) or length != std.mem.readInt(u64, certified[0..8], .little) or
            !std.mem.eql(u8, &digest, certified[8..40])) return error.CorruptStore;
        fields[index] = .{ .length = length, .digest = digest };
    }
    return fields;
}

/// The tool outcome rule's read over the Operations a scope names, as
/// main's `readToolOutcomeFacts` checked each: one row per call of each
/// Operation, in Operation and call order, or one row with no call for an
/// Operation that has none (`ordinal` NULL). `scope` is the text of a CTE
/// that selects `operation_id` and `expected`, the count of the
/// Operation's call items, after the CTEs in `with`, if any.
/// The scope must not be flattened into the join, so `expected` is
/// counted once per Operation and not once per call: a scope selects
/// DISTINCT or groups. Each row joins its call's item and reads, off that
/// item, the Proposal that item's position names (`proposal_columns`):
/// the item is unique at its position, and the call at its item, so it is
/// the call's own Proposal, as main read it. `ToolOutcomeCheck` judges
/// the rows.
pub fn ToolOutcome(comptime with: []const u8, comptime scope: []const u8, comptime Args: type, comptime compound: bool) type {
    return rsql.Read(.{
        .sql = "WITH " ++ with ++ "scope AS (" ++ scope ++ ") " ++
            "SELECT scope.operation_id AS scope_operation,scope.expected,proposed.call_ordinal AS ordinal,item.item_kind," ++
            "tool_call.acceptance_position AS call_acceptance,rejection.content_id IS NOT NULL AS rejection_present," ++
            "action.resolution_code IS NOT NULL AS action_resolved,action.resolution_content_id IS NOT NULL AS action_content," ++
            "action.acceptance_position AS action_acceptance,result.content_id IS NOT NULL AS result_present," ++ proposal_columns ++ " " ++
            "FROM scope LEFT JOIN model_tool_call proposed ON proposed.operation_id=scope.operation_id " ++
            "LEFT JOIN model_output_item item ON item.operation_id=proposed.operation_id AND item.item_ordinal=proposed.item_ordinal " ++
            proposal_joins ++ "LEFT JOIN content result ON result.content_id=action.resolution_content_id " ++
            "ORDER BY scope.operation_id,proposed.call_ordinal",
        .Args = Args,
        .Row = ToolOutcomeRow,
        .cardinality = .each,
        .compound = compound,
    });
}

/// `expected` for a scope over the Operations `operation` names.
pub fn expectedCallsSql(comptime operation: []const u8) []const u8 {
    return "(SELECT count(*) FROM model_output_item expected WHERE expected.operation_id=" ++ operation ++ " AND expected.item_kind=3) AS expected";
}

/// A `ToolOutcome` row. Past `result_present` it is `proposal_row`'s,
/// each column NULL where a missing item, call or row leaves it so.
pub const ToolOutcomeRow = struct {
    scope_operation: rsql.Positive,
    expected: u64,
    ordinal: ?u64,
    item_kind: ?u64,
    call_acceptance: ?rsql.Positive,
    rejection_present: bool,
    action_resolved: bool,
    action_content: bool,
    action_acceptance: ?rsql.Positive,
    result_present: bool,
    operation_id: ?rsql.Positive,
    turn_id: ?rsql.Positive,
    call_ordinal: ?u64,
    action_id: ?rsql.Positive,
    rejection_code: ?protocol.ProposalRejection,
    name_content_id: ?rsql.Positive,
    call_id_content_id: ?rsql.Positive,
    arguments_content_id: ?rsql.Positive,
    consistent: bool,
    field_metadata: ?[120]u8,
    length0: ?u64,
    digest0: ?[32]u8,
    private0: ?bool,
    length1: ?u64,
    digest1: ?[32]u8,
    private1: ?bool,
    length2: ?u64,
    digest2: ?[32]u8,
    private2: ?bool,

    /// The call's Proposal as `proposal_row` reads it; a column it needs
    /// that is NULL is `CorruptStore`, as main's decode answered, and as
    /// its NULL source position did when the item was missing.
    fn proposal(row: *const ToolOutcomeRow) error{CorruptStore}!proposal_row.Row {
        var out: proposal_row.Row = undefined;
        inline for (@typeInfo(proposal_row.Row).@"struct".field_names) |name| {
            const Field = @FieldType(proposal_row.Row, name);
            const value = @field(row, name);
            @field(out, name) = if (@typeInfo(Field) == .optional or Field == @TypeOf(value)) value else value orelse return error.CorruptStore;
        }
        return out;
    }
};

/// The tool outcome rule, judging a `ToolOutcome` read's rows as they
/// step, in plain Zig, keeping one Operation's counts at a time. For each
/// Operation, as main's aggregate: it proposed calls; every call item has
/// a call; every call has its item, its three fields' contents, and is
/// either rejected with its rejection's content and acceptance and no
/// Action, or has an Action that is unresolved, with no result and no
/// acceptance, or resolved, with its result's content and acceptance.
/// Main also required a public Tool Result's group to be terminal, every
/// call rejected or resolved; `public_tool_result` only returns a group
/// whose every call has an acceptance and content, so in the same
/// snapshot no call the rule passes is unresolved, and no count is kept
/// for it. For each
/// call, as main's per-call Proposal read: its Proposal is consistent and
/// its fields certified (`certifiedFields`). Every failure is
/// `CorruptStore`, main's answer for each, so which one it meets first
/// changes nothing. Its counts are `u32`, so an Activity page's sixteen
/// item reads, each holding one, fit `readItems`' frame budget: more call
/// items than a `u32` counts is `CorruptStore`, and so is a call past the
/// count of call items, which main also refused once the count ended.
pub const ToolOutcomeCheck = struct {
    operation: u64 = 0,
    expected: u32 = 0,
    calls: u32 = 0,
    valid: u32 = 0,
    failed: bool = false,

    /// One check may judge several reads' rows, each after the other's,
    /// in Operation order; after a failure it takes no more.
    pub fn visit(check: *ToolOutcomeCheck, row: *const ToolOutcomeRow) bool {
        if (check.failed) return false;
        check.take(row) catch {
            check.failed = true;
            return false;
        };
        return true;
    }

    /// Counts `row`'s call, judging the Operation before it once its
    /// rows end.
    pub fn take(check: *ToolOutcomeCheck, row: *const ToolOutcomeRow) error{CorruptStore}!void {
        const operation = row.scope_operation.get();
        if (operation != check.operation) {
            try check.close();
            check.* = .{ .operation = operation, .expected = std.math.cast(u32, row.expected) orelse return error.CorruptStore };
        }
        if (row.ordinal == null) return;
        if (check.calls == check.expected) return error.CorruptStore;
        check.calls += 1;
        _ = try certifiedFields(&try row.proposal());
        const rejected = row.rejection_code != null and row.rejection_present and row.call_acceptance != null and row.action_id == null;
        const resolved = row.rejection_code == null and row.action_id != null and row.action_resolved and row.result_present and row.action_acceptance != null;
        const unresolved = row.rejection_code == null and row.action_id != null and !row.action_resolved and !row.action_content and row.action_acceptance == null;
        const fields = row.length0 != null and row.length1 != null and row.length2 != null;
        if (row.item_kind == 3 and fields and (rejected or resolved or unresolved)) check.valid += 1;
    }

    /// Judges the Operation whose rows ended.
    fn close(check: *ToolOutcomeCheck) error{CorruptStore}!void {
        if (check.operation == 0) return;
        if (check.expected == 0 or check.calls != check.expected or check.valid != check.expected) return error.CorruptStore;
        check.operation = 0;
    }

    /// After the read's round: the last Operation judged too.
    pub fn finish(check: *ToolOutcomeCheck) error{CorruptStore}!void {
        if (check.failed) return error.CorruptStore;
        try check.close();
    }
};

fn optionalPositive(value: ?rsql.Positive) ?u64 {
    return if (value) |positive| positive.get() else null;
}

/// One Operation: a public Tool Result's, or an Activity page's
/// candidates'.
const operation_outcome = ToolOutcome("", "SELECT DISTINCT ?1 AS operation_id," ++ expectedCallsSql("?1"), struct { operation: u64 }, false);

/// Queues reading the Proposal at `read.position`; `read.found` follows
/// its round.
pub fn readProposal(a: anytype, session: []const u8, read: *ProposalRead) void {
    readRow(a, proposal_row, .{ .session = session, .position = read.position }, read);
}

/// `readProposal` in a round of its own.
pub fn proposal(a: anytype, session: []const u8, position: u64) !protocol.ProposalMetadata {
    var metadata: protocol.ProposalMetadata = undefined;
    var read: ProposalRead = .{ .position = position, .metadata = &metadata };
    readProposal(a, session, &read);
    try a.run();
    try read.found();
    return metadata;
}
