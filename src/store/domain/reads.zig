const connection = @import("../../connection.zig");
const std = @import("std");
const tool_fulfillment = @import("tool_fulfillment.zig");
const command_reply = @import("../../command_reply.zig");
const word_search = @import("../../word_search.zig");
const pages = @import("../../os/pages.zig");
const activity_facts = @import("../../activity_facts.zig");
const content_value = @import("../../content_value.zig");
const conversation_read = @import("../../conversation_read.zig");
const activity_read = @import("../../activity_read.zig");
const session_settings = @import("../../session_settings.zig");
const tool_proposal = @import("../../tool_proposal.zig");
const workspace_path = @import("../../workspace_path.zig");
const outcome_code = @import("../../outcome_code.zig");
const content_string = @import("../../content_string.zig");
const action_domain = @import("action.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const provider_name = @import("../../provider_name.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const session_work = @import("../../session_work.zig");
const codec_abi = @import("../../codec_abi.zig");
const output_format = @import("../../output_format.zig");
const model_capability = @import("../../model_capability.zig");
const codecs = @import("../../codecs.zig");
const model_evidence = @import("../../model_evidence.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const content_parts = @import("content_parts.zig");
const sourced_input = @import("sourced_input.zig");
const skills_domain = @import("skills.zig");
const report_domain = @import("report.zig");
const session_list_domain = @import("session_list_read.zig");
const store_schema = @import("../schema.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const turn_domain = @import("turn.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentLocation = content_domain.ContentLocation;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const TurnOutcome = turn_domain.TurnOutcome;
const accepted_resolutions = store_schema.accepted_resolutions;
const content_metadata = content_domain.content_metadata;

pub const ReadAccess = store_access.Access(.read, error{});

const SessionText = Bounded(session_id.max_reference_bytes);

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

pub fn First(comptime Row: type) type {
    return struct {
        row: ?Row = null,

        pub fn visit(first: *@This(), row: *const Row) bool {
            first.row = row.*;
            return false;
        }
    };
}

pub const RowCount = struct {
    rows: u8 = 0,
    failure: ?error{CorruptStore} = null,

    pub fn found(count: RowCount) error{CorruptStore}!bool {
        if (count.failure) |err| return err;
        return count.rows != 0;
    }
};

pub fn readRow(a: anytype, comptime S: type, args: S.Args, visitor: anytype) void {
    visitor.count = .{};
    a.readEach(S, args, if (S.single_row) 1 else 2, visitor);
}

pub fn readFirst(a: anytype, comptime S: type, args: S.Args, visitor: anytype) void {
    visitor.count = .{};
    a.readEach(S, args, 1, visitor);
}

pub fn visitRow(visitor: anytype, row: anytype) bool {
    return countRow(&visitor.count, visitor, row);
}

pub fn countRow(count: *RowCount, visitor: anytype, row: anytype) bool {
    count.rows += 1;
    if (count.rows > 1) {
        count.failure = error.CorruptStore;
        return false;
    }
    visitor.keep(row) catch |err| {
        count.failure = err;
        return false;
    };
    return true;
}

pub const read_failures = .{
    .{ missing_assistant_entry, error.ConversationReadFailed },
    .{ public_page, error.ConversationReadFailed },
    .{ activity_forward, error.ActivityReadFailed },
    .{ activity_backward, error.ActivityReadFailed },
    .{ public_entry, error.ConversationReadFailed },
    .{ activity_entry, error.ActivityReadFailed },
    .{ public_tool_result, error.PublicContentReadFailed },
    .{ hosted_call, error.ActivityReadFailed },
    .{ activity_item, error.ActivityReadFailed },
    .{ answer_entry, error.ActivityReadFailed },
    .{ approval_request, error.ActivityReadFailed },
    .{ session_change, error.ActivityReadFailed },
    .{ compaction_row, error.ActivityReadFailed },
    .{ model_call_row, error.ActivityReadFailed },
    .{ peer_label, error.SessionReadFailed },
    .{ proposal_row, error.StatementFailed },
    .{ call_activity, error.CallReadFailed },
    .{ call_outcomes, error.CallReadFailed },
    .{ operation_outcome, error.CallReadFailed },
    .{ queued, error.ActivityReadFailed },
} ++ report_domain.work_failures;

fn runRows(a: *ReadAccess) !void {
    return store_access.runNamed(a, read_failures, error.CorruptStore);
}

const public_tool_groups_sql = "WITH tool_groups AS (SELECT op.operation_id,max(" ++ tool_fulfillment.positionSql("tool_call", "action") ++ ") AS position " ++
    "FROM model_operation op JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " GROUP BY op.operation_id " ++
    "HAVING count(*)=(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
    "AND count(" ++ tool_fulfillment.positionSql("tool_call", "action") ++ ")=count(*) " ++
    "AND count(" ++ tool_fulfillment.contentSql("tool_call", "action") ++ ")=count(*)), ";

fn toolGroupCompletesAtLast(comptime operation: []const u8, comptime position: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM model_operation op WHERE op.operation_id=" ++ operation ++ " AND op.session_ref=?1 AND " ++
        store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ ") " ++
        "AND (SELECT count(*) FROM model_tool_call c WHERE c.operation_id=" ++ operation ++ ")=" ++
        "(SELECT count(*) FROM model_output_item item WHERE item.operation_id=" ++ operation ++ " AND item.item_kind=3) " ++
        "AND NOT EXISTS(SELECT 1 FROM model_tool_call c LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal " ++
        "WHERE c.operation_id=" ++ operation ++ " AND (" ++ tool_fulfillment.positionSql("c", "a") ++ " IS NULL " ++
        "OR " ++ tool_fulfillment.contentSql("c", "a") ++ " IS NULL OR " ++ tool_fulfillment.positionSql("c", "a") ++ ">" ++ position ++ "))";
}

fn activityToolSources(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime order: []const u8) []const u8 {
    const enabled = "(" ++ kinds ++ "/32)%2=1";
    return "SELECT last.acceptance_position AS position,tool_call.call_ordinal+1 AS ordinal,5 AS kind FROM model_tool_call last @index(model_tool_call_acceptance) " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=last.operation_id WHERE last.session_ref=?1 AND " ++ enabled ++ " AND " ++
        range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.operation_id", "last.acceptance_position") ++
        " UNION ALL SELECT last.acceptance_position,tool_call.call_ordinal+1,5 FROM action_operation last @index(action_operation_acceptance) " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=last.parent_operation_id WHERE last.session_ref=?1 AND last.background_position IS NULL AND " ++ enabled ++ " AND " ++
        range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.parent_operation_id", "last.acceptance_position") ++
        " UNION ALL SELECT last.background_position,tool_call.call_ordinal+1,5 FROM action_operation last @index(action_operation_background) " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=last.parent_operation_id WHERE last.session_ref=?1 AND last.background_position IS NOT NULL AND " ++ enabled ++ " AND " ++
        range("last.background_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.parent_operation_id", "last.background_position") ++ order;
}

fn visibleEntrySql(comptime entry: []const u8) []const u8 {
    return "NOT EXISTS(SELECT 1 FROM message_admission hidden WHERE hidden.admission_id=" ++ entry ++ ".source_admission_id AND hidden.source_kind=4)";
}

/// One CTE arm per source kind. SQLite allows 4 terms in a compound SELECT, so Action values (kind 4) sit in their own CTE beside the other inputs.
fn activityVisibleInputs(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime users: bool, comptime sources: []const u8) []const u8 {
    comptime var sql: []const u8 = "";
    inline for (sources, 0..) |source, index| {
        const kind = std.fmt.comptimePrint("{d}", .{source});
        if (index != 0) sql = sql ++ " UNION ALL ";
        if (users) {
            sql = sql ++ "SELECT e.session_position AS position,0 AS ordinal,2 AS kind,e.source_admission_id AS id FROM conversation_entry e @index(conversation_entry_activity_user) " ++
                "WHERE e.session_ref=?1 AND e.entry_kind=1 AND e.source_kind=" ++ kind ++ " AND (" ++ kinds ++ "/4)%2=1 AND " ++ range("e.session_position", "0");
        } else {
            sql = sql ++ "SELECT admission_position AS position,0 AS ordinal," ++ (if (source == 1) "1" else "11") ++ " AS kind,admission_id AS id FROM message_admission @index(message_admission_activity) " ++
                "WHERE session_ref=?1 AND source_kind=" ++ kind ++ " AND (" ++ kinds ++ (if (source == 1) "/2" else "/2048") ++ ")%2=1 AND " ++ range("admission_position", "0");
        }
    }
    return sql;
}

const input_kinds: []const u8 = &.{ 1, 2, 3, 5 };

/// Published Action values (source kind 4): the same Activity rows as finals, in their own CTE.
/// `order` bounds the two arms to one page, like the other grouped sources, so a long history of values stays one index walk.
fn activityValueInputs(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime order: []const u8) []const u8 {
    return activityVisibleInputs(range, kinds, false, &.{4}) ++ " UNION ALL " ++ activityVisibleInputs(range, kinds, true, &.{4}) ++ order;
}

fn kindOn(comptime kinds: []const u8, comptime kind: u5) []const u8 {
    return std.fmt.comptimePrint("({s}/{d})%2=1", .{ kinds, @as(u64, 1) << kind });
}

/// The entries delivered to a Turn that no other source owns: the model's text (kind 3) and the instruction text it was given (kind 2).
/// SQLite allows 4 terms in a compound SELECT, so the pair sits in its own CTE beside the other inputs.
fn activityDeliveredEntries(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime order: []const u8) []const u8 {
    return "SELECT e.session_position AS position,0 AS ordinal,3 AS kind,e.source_admission_id AS id FROM conversation_entry e @index(conversation_entry_activity_assistant) " ++
        "WHERE e.session_ref=?1 AND e.entry_kind=3 AND " ++ kindOn(kinds, 3) ++ " AND " ++ range("e.session_position", "0") ++
        " UNION ALL SELECT e.session_position,0,16,NULL FROM conversation_entry e @index(conversation_entry_activity_assistant) " ++
        "WHERE e.session_ref=?1 AND e.entry_kind=2 AND " ++ kindOn(kinds, 16) ++ " AND " ++ range("e.session_position", "0") ++ order;
}

fn activitySources(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime kinds: []const u8, comptime order: []const u8) [4][]const u8 {
    const on = struct {
        fn of(comptime kind: u5) []const u8 {
            return kindOn(kinds, kind);
        }
    }.of;
    return .{
        "SELECT position,ordinal,kind,id FROM visible_admissions UNION ALL SELECT position,ordinal,kind,id FROM visible_users" ++
            " UNION ALL SELECT position,ordinal,kind,id FROM delivered_entries" ++
            " UNION ALL SELECT session_position,0,4,NULL FROM model_output_item @index(model_output_call_history) " ++
            "WHERE session_ref=?1 AND item_kind=3 AND " ++ on(4) ++ " AND " ++ range("session_position", "0") ++ order,
        "SELECT position,ordinal,kind,NULL AS id FROM tool_completions UNION ALL SELECT position,ordinal,kind,id FROM visible_values" ++
            " UNION ALL SELECT outcome_position,0,6,turn_id FROM turn @index(turn_outcome_position) WHERE session_ref=?1 AND outcome_code IS NOT NULL AND " ++ on(6) ++ " AND " ++ range("outcome_position", "0") ++
            " UNION ALL SELECT position,0,7,NULL FROM session_stop @index(session_stop_position) WHERE session_ref=?1 AND " ++ on(7) ++ " AND " ++ range("position", "0") ++ order,
        "SELECT session_position AS position,0 AS ordinal,10 AS kind,NULL AS id FROM model_output_item @index(model_output_hosted_history) " ++
            "WHERE session_ref=?1 AND item_kind=5 AND " ++ on(10) ++ " AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT approval_position,1,12,action_id FROM action_operation @index(action_operation_approval) " ++
            "WHERE session_ref=?1 AND approval_position IS NOT NULL AND " ++ on(12) ++ " AND " ++ range("approval_position", "1") ++ order,
        "SELECT position,ordinal,13 AS kind,revision AS id FROM session_change WHERE session_ref=?1 AND " ++ on(13) ++ " AND " ++ range("position", "ordinal") ++
            " UNION ALL SELECT session_position,0,14,operation_id FROM model_output_item @index(model_output_compaction_history) " ++
            "WHERE session_ref=?1 AND item_kind=4 AND " ++ on(14) ++ " AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT position,0,CASE kind WHEN 1 THEN 12 ELSE 6 END,source_id FROM session_forward @index(session_forward_feed) " ++
            "WHERE target_ref=?1 AND position IS NOT NULL AND (kind=1 AND " ++ on(12) ++ " OR kind=2 AND " ++ on(6) ++ ") AND " ++ range("position", "0") ++
            " UNION ALL SELECT admission_position,0,15,operation_id FROM model_operation @index(model_operation_admission) " ++
            "WHERE session_ref=?1 AND resolution_code IS NOT NULL AND " ++ on(15) ++ " AND " ++ range("admission_position", "0") ++ order,
    };
}

/// Every kind bit. Codes 8 and 9 belonged to the deleted `sent` and `send_failed` kinds; no row carries them, so their bits select nothing.
const all_activity_kinds = std.fmt.comptimePrint("{d}", .{(@as(u64, 1) << 17) - 2});

fn activityKindCode(kind: activity_facts.Item.Kind) u5 {
    return switch (kind) {
        .admission => 1,
        .user => 2,
        .assistant => 3,
        .call => 4,
        .tool_result => 5,
        .turn_ended => 6,
        .stop => 7,
        .hosted_call => 10,
        .received => 11,
        .approval_requested => 12,
        .session_changed => 13,
        .compacted => 14,
        .model_call => 15,
        .instruction => 16,
    };
}

fn activityKinds(kinds: activity_read.ActivityPage.Kinds) u64 {
    var bits: u64 = 0;
    var iterator = kinds.iterator();
    while (iterator.next()) |kind| bits |= @as(u64, 1) << activityKindCode(kind);
    return bits;
}

fn anyActivityPosition(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
    _ = ordinal;
    return position ++ " IS NOT NULL";
}

const activity_item = blk: {
    const sources = activitySources(anyActivityPosition, all_activity_kinds, "");
    break :blk rsql.Read(.{
        .sql = std.fmt.comptimePrint("WITH tool_completions AS ({s}), visible_admissions AS ({s}), visible_values AS ({s}), visible_users AS ({s}), delivered_entries AS ({s}), entries AS ({s}), completions AS ({s}), others AS ({s}), changes AS ({s}), " ++
            "activity AS (SELECT position,ordinal,kind,id FROM entries UNION ALL SELECT position,ordinal,kind,id FROM completions UNION ALL SELECT position,ordinal,kind,id FROM others " ++
            "UNION ALL SELECT position,ordinal,kind,id FROM changes) " ++
            "SELECT kind,id FROM activity WHERE position=?3 AND ordinal=?4 AND position<=?2", .{ activityToolSources(anyActivityPosition, all_activity_kinds, ""), activityVisibleInputs(anyActivityPosition, all_activity_kinds, false, input_kinds), activityValueInputs(anyActivityPosition, all_activity_kinds, ""), activityVisibleInputs(anyActivityPosition, all_activity_kinds, true, input_kinds), activityDeliveredEntries(anyActivityPosition, all_activity_kinds, ""), sources[0], sources[1], sources[2], sources[3] }),
        .Args = struct { session: []const u8, end: u64, position: u64, ordinal: u64 },
        .Row = struct { kind: u8, id: ?rsql.Positive },
        .cardinality = .optional,
        .compound = true,
    });
};

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
        .sql = std.fmt.comptimePrint("WITH tool_completions AS ({s}), visible_admissions AS ({s}), visible_values AS ({s}), visible_users AS ({s}), delivered_entries AS ({s}), entries AS ({s}), completions AS ({s}), others AS ({s}), changes AS ({s}) SELECT position,ordinal FROM entries " ++
            "UNION ALL SELECT position,ordinal FROM completions UNION ALL SELECT position,ordinal FROM others UNION ALL SELECT position,ordinal FROM changes{s}", .{ activityToolSources(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", order), activityVisibleInputs(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", false, input_kinds), activityValueInputs(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", order), activityVisibleInputs(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", true, input_kinds), activityDeliveredEntries(if (forward) Range.after else Range.before, if (forward) "?5" else "?4", order), sources[0], sources[1], sources[2], sources[3], order }),
        .Args = if (forward) struct { session: []const u8, end: u64, position: u64, ordinal: u64, kinds: u64 } else struct { session: []const u8, position: u64, ordinal: u64, kinds: u64 },
        .Row = ActivityPageRow,
        .cardinality = .each,
        .compound = true,
    });
}
const activity_forward = ActivityPage(true);
const activity_backward = ActivityPage(false);

pub const activity_sequence_guard = rsql.Read(.{
    .sql = "SELECT 1 AS found FROM message_admission @index(message_admission_unpositioned) WHERE session_ref=?1 AND admission_position IS NULL " ++
        "UNION ALL SELECT 1 FROM session_stop @index(session_stop_unpositioned) WHERE session_ref=?1 AND position IS NULL " ++
        "UNION ALL SELECT 1 FROM turn @index(turn_unpositioned) WHERE session_ref=?1 AND ((outcome_code IS NULL)!=(outcome_position IS NULL)) LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { found: bool },
    .cardinality = .optional,
    .compound = true,
});

pub const queued = rsql.Read(.{
    .sql = "SELECT m.admission_id,m.admission_position," ++
        "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.source_admission_id=m.admission_id AND e.session_position<=?2) OR " ++
        "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=?1 AND s.admission_cutoff>=m.admission_id AND s.position<=?2) AS taken," ++
        "c.byte_length,c.digest,c.private,c.form " ++
        "FROM message_admission m @index(message_admission_person) LEFT JOIN content c ON c.content_id=m.content_id WHERE m.session_ref=?1 AND " ++ sourced_input.personSql("m") ++ " " ++
        "AND m.admission_position<=?2 ORDER BY m.admission_position DESC",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct { admission_id: rsql.Positive, admission_position: rsql.Positive, taken: bool, byte_length: ?u64, digest: ?[32]u8, private: ?bool, form: ?u8 },
    .cardinality = .each,
});

pub const PublicConversationItem = command_reply.PublicConversationItem;

pub const PublicConversationPage = command_reply.PublicConversationPage;

pub const MessageObservation = command_reply.MessageObservation;

pub const Recovery = command_reply.Recovery;

pub const UnknownOutcome = command_reply.UnknownOutcome;

pub const AcceptedMessageQueue = command_reply.AcceptedMessageQueue;

pub const SessionObservation = struct {
    found: bool = false,
    archive_state: session_archive.State = .active,
    session: Bounded(session_id.max_reference_bytes) = .{},
    workspace: Bounded(workspace_path.max_bytes) = .{},
    provider: ?connection.Name = null,
    model: Bounded(model_capability.max_model_bytes) = .{},
    revision: u64 = 0,
    tool_set_id: u64 = 0,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    compaction_trigger_override: ?u64 = null,
    output_reservation_override: ?u64 = null,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    reasoning_effort_override: ?model_capability.ReasoningEffort = null,
    permission_mode: Bounded(16) = .{},
    instructions: ContentReference = .{ .length = 0, .digest = @splat(0) },
    output_schema: ?ContentReference = null,
    pending_messages: u64 = 0,
    action_count: u64 = 0,
    rejected_call_count: u64 = 0,
};

const next_position = rsql.Read(.{
    .sql = "SELECT next_position FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { next_position: rsql.Positive },
    .cardinality = .optional,
});

fn readNextPosition(a: *ReadAccess, session: []const u8) !?u64 {
    var row: next_position.Result = undefined;
    a.read(next_position, .{ .session = session }, &row);
    try store_access.runAs(a, error.SessionReadFailed);
    return if (row) |found| found.next_position.get() else null;
}

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
    const policy = model_capability.compactionPolicy(current.model.slice(), codecs.compacts(current.codec), current.compaction_trigger, current.output_reservation);
    observation.* = .{
        .found = true,
        .revision = current.revision,
        .tool_set_id = current.tool_set_id,
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
    const instructions_id = current.instructions_id.?;
    if (instructions_id < 0 or (current.output_schema_id orelse 1) < 0) return error.CorruptStore;
    var instructions: content_metadata.Row = undefined;
    var output_schema: content_metadata.Row = undefined;
    var counts: report_domain.SessionCounts = .{ .session = session_ref };
    var archive: report_domain.archive_state.Result = undefined;
    a.read(report_domain.archive_state, .{ .session = session_ref }, &archive);
    a.read(content_metadata, .{ .content_id = @intCast(instructions_id) }, &instructions);
    if (current.output_schema_id) |content_id| a.read(content_metadata, .{ .content_id = @intCast(content_id) }, &output_schema);
    counts.queue(a);
    try runCounts(a);
    observation.archive_state = if (archive) |row| row.archive_state else .active;
    observation.instructions = .{ .length = instructions.byte_length, .digest = instructions.digest };
    if (current.output_schema_id != null) observation.output_schema = .{ .length = output_schema.byte_length, .digest = output_schema.digest };
    counts.queuePending(a);
    try runCounts(a);
    const counted = try counts.judge();
    observation.pending_messages = counted.pending;
    observation.action_count = counted.actions;
    observation.rejected_call_count = counted.rejected;
}

fn runCounts(a: *ReadAccess) !void {
    return store_access.runNamed(a, report_domain.session_count_failures ++ report_domain.work_failures, error.CorruptStore);
}

const public_page = rsql.Read(.{
    .sql = public_tool_groups_sql ++
        "public AS (SELECT e.session_position AS position,0 AS ordinal,e.entry_kind AS kind,e.content_id " ++
        "FROM conversation_entry e WHERE e.session_ref=?1 AND e.entry_kind IN (1,3) AND " ++ visibleEntrySql("e") ++ " AND e.session_position<=?2 " ++
        "UNION ALL SELECT tool_groups.position,tool_call.call_ordinal+1,4," ++ tool_fulfillment.contentSql("tool_call", "action") ++ " " ++
        "FROM tool_groups JOIN model_tool_call tool_call ON tool_call.operation_id=tool_groups.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE tool_groups.position<=?2 " ++
        "UNION ALL SELECT item.session_position,0,5,NULL FROM model_output_item item @index(model_output_hosted_history) WHERE item.session_ref=?1 AND item.item_kind=5 AND item.session_position<=?2) " ++
        "SELECT position,ordinal,kind,content_id FROM public WHERE (?3=0 OR position<?3 OR (position=?3 AND ordinal<?4)) " ++
        "ORDER BY position DESC,ordinal DESC LIMIT 17",
    .Args = struct { session: []const u8, end: u64, before_position: u64, before_ordinal: u64 },
    .Row = struct { position: u64, ordinal: u64, kind: u8, content_id: ?u64 },
    .cardinality = .each,
    .compound = true,
});

pub fn publicConversationPage(a: *ReadAccess, request: *const conversation_read.ConversationPage, page: *PublicConversationPage, reads: *[PublicConversationPage.capacity]PublicRowRead) !void {
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
    if (end == 0) return;
    var rows: Collected(public_page.Row, PublicConversationPage.capacity + 1) = .{};
    a.readEach(public_page, .{ .session = session, .end = end, .before_position = request.before_position, .before_ordinal = request.before_ordinal }, rows.items.len, &rows);
    var hosted_cursor: tool_presentation.ToolPresentation = undefined;
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
        if (row.position == 0) return error.CorruptStore;
        item.* = .{ .position = row.position, .ordinal = row.ordinal, .kind = switch (row.kind) {
            1 => .user,
            3 => .assistant,
            4 => .tool_result,
            5 => .hosted_call,
            else => return error.CorruptStore,
        }, .content = .{ .text = .{ .length = 0, .digest = content_string.digest("") } } };
        if (row.kind == 5) {
            if (row.ordinal != 0) return error.CorruptStore;
        } else if ((row.content_id orelse 0) == 0 or (row.kind == 4) != (row.ordinal > 0)) return error.CorruptStore;
    }
    page.count = shown.len;
    const upper = if (request.before_position == 0) end else @min(end, request.before_position - @intFromBool(request.before_ordinal == 0));
    try readPublicRows(a, reads[0..shown.len], session, shown, page.items[0..shown.len], if (page.more) page.items[page.count - 1].position else 0, upper, content_cursor);
}

pub const PublicRowRead = struct {
    reads: union(enum) { content: PublicContentRead, hosted: HostedRead },
    label: LabelRead = undefined,
    presentation: PresentationRead = undefined,
};

// The row reads are about 8 KiB, so the caller provides them before the Store is entered.
noinline fn readPublicRows(a: *ReadAccess, reads: []PublicRowRead, session: []const u8, rows: []const public_page.Row, items: []PublicConversationItem, lower: u64, upper: u64, cursor: ?*PublicContentRead) !void {
    var missing: missing_assistant_entry.Result = null;
    if (lower <= upper) a.read(missing_assistant_entry, .{ .session = session, .lower = lower, .upper = upper }, &missing);
    for (items, reads[0..items.len]) |*item, *read| {
        if (item.kind == .hosted_call) {
            item.presentation = @as(tool_presentation.ToolPresentation, undefined);
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
            item.source_action = found.source_action;
            content.queueMetadata(a);
            contents = true;
            if (item.sender) |*sender| {
                read.label = .{ .peer = sender };
                read.label.queue(a);
            }
            if (found.tool_operation) |operation| {
                item.presentation = @as(tool_presentation.ToolPresentation, undefined);
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
            item.content = content.content.value;
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

pub fn openPublicConversationContent(a: *ReadAccess, request: *const conversation_read.ConversationContent) !ContentLocation {
    if (request.position == 0 or request.position > std.math.maxInt(i64) or
        request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
    const content = try publicConversationContent(a, request.session.slice(), request.position, request.ordinal);
    const reference = switch (content.value) {
        .text => |reference| reference,
        .parts => return error.ContentIsParts,
    };
    if (request.start > reference.length) return error.RangeOutOfBounds;
    return .{ .store = a.store, .content_id = content.id, .reference = reference };
}

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

pub fn publicEntryRead(comptime columns: []const u8, comptime also: []const u8, comptime rest: []const u8) []const u8 {
    return "SELECT " ++ columns ++ "," ++ publicEntryColumns(also) ++ " FROM conversation_entry e @index(conversation_entry_history) " ++ public_entry_joins ++ " " ++ rest;
}

pub fn publicEntryColumns(comptime also: []const u8) []const u8 {
    return "CASE WHEN " ++ also ++ "(c.content_id IS NOT NULL AND c.private=0 AND t.session_ref=e.session_ref AND " ++
        "((e.entry_kind=1 AND m.session_ref=e.session_ref AND m.turn_id=e.turn_id AND m.content_id=e.content_id AND " ++ sourced_input.actionConsistentSql("m") ++ ") OR " ++
        "(e.entry_kind=3 AND o.purpose=0 AND o.session_ref=e.session_ref AND o.turn_id=e.turn_id " ++
        "AND item.item_kind=2 AND item.message_content_id=e.content_id AND item.session_ref=e.session_ref " ++
        "AND item.session_position=e.session_position AND item.attempt_ordinal=o.attempt_ordinal " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ "))) THEN 1 ELSE 0 END AS consistent";
}

pub const public_entry_joins = "LEFT JOIN turn t ON t.turn_id=e.turn_id " ++
    "LEFT JOIN message_admission m ON m.admission_id=e.source_admission_id " ++
    "LEFT JOIN model_operation o ON o.operation_id=e.source_operation_id " ++
    "LEFT JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
    "LEFT JOIN content c ON c.content_id=e.content_id";

/// An instruction entry's text is public and equals what its source saved: an authored revision's `instructions_content_id`, or the Skill catalog's instruction.
const instruction_entry_consistent = "(e.entry_kind=2 AND c.content_id IS NOT NULL AND c.private=0 AND ((e.source_catalog_position IS NULL AND e.turn_id IS NOT NULL AND t.session_ref=e.session_ref AND " ++
    "EXISTS(SELECT 1 FROM session_revision r WHERE r.session_ref=e.session_ref AND r.revision=e.source_revision AND r.instructions_content_id=e.content_id)) OR " ++ skills_domain.instructionConsistentSql("e") ++ ")) OR ";

/// The Conversation entry a position holds. The public Conversation hides Action values (source kind 4) and instruction entries (kind 2); the Activity feed keeps them.
fn entryRead(comptime hide_values: bool) type {
    return rsql.Read(.{
        .sql = publicEntryRead("e.content_id,e.turn_id,e.source_revision,CASE WHEN e.entry_kind=1 THEN m.admitted_at END AS admitted_at," ++
            "CASE WHEN e.entry_kind=1 THEN m.sender_session_ref END AS sender," ++
            "CASE WHEN e.entry_kind=1 THEN " ++ sourced_input.actionIdSql("m") ++ " END AS source_action," ++
            "CASE WHEN e.entry_kind=1 THEN e.source_admission_id END AS admission,e.recorded_at", if (hide_values) "" else instruction_entry_consistent, "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind IN(" ++ (if (hide_values) "1,3" else "1,2,3") ++ ")" ++
            (if (hide_values) " AND " ++ visibleEntrySql("e") else "")),
        .Args = struct { session: []const u8, position: u64 },
        .Row = struct { content_id: rsql.Positive, turn_id: ?rsql.Positive, source_revision: ?rsql.Positive, admitted_at: ?rsql.Positive, sender: ?SessionText, source_action: ?rsql.Positive, admission: ?rsql.Positive, recorded_at: rsql.Positive, consistent: bool },
        .cardinality = .each,
    });
}

const public_entry = entryRead(true);
const activity_entry = entryRead(false);

/// The Action whose saved Resolution a tool result row shows: the owner of a parts result.
/// A rejection or a background notice has none.
fn resolutionActionSql(comptime call: []const u8, comptime action: []const u8) []const u8 {
    return "CASE WHEN " ++ call ++ ".rejection_content_id IS NULL AND " ++ action ++ ".background_content_id IS NULL THEN " ++ action ++ ".action_id END";
}

const public_tool_result = rsql.Read(.{
    .sql = "WITH last AS (SELECT operation_id FROM model_tool_call @index(model_tool_call_acceptance) WHERE session_ref=?1 AND acceptance_position=?2 " ++
        "UNION ALL SELECT parent_operation_id FROM action_operation @index(action_operation_acceptance) WHERE session_ref=?1 AND acceptance_position=?2 AND background_position IS NULL UNION ALL SELECT parent_operation_id FROM action_operation @index(action_operation_background) WHERE session_ref=?1 AND background_position=?2) " ++
        "SELECT " ++ tool_fulfillment.contentSql("tool_call", "action") ++ " AS content_id,NOT EXISTS(SELECT 1 FROM model_tool_call linked " ++
        "LEFT JOIN model_output_item item ON item.operation_id=linked.operation_id AND item.item_ordinal=linked.item_ordinal LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
        "LEFT JOIN content rejection ON rejection.content_id=linked.rejection_content_id " ++
        "LEFT JOIN action_operation a ON a.parent_operation_id=linked.operation_id AND a.call_ordinal=linked.call_ordinal " ++
        "LEFT JOIN content result ON result.content_id=" ++ tool_fulfillment.actionContentSql("a") ++ " " ++
        "WHERE linked.operation_id=op.operation_id AND CASE WHEN item.item_kind=3 AND item.session_ref=op.session_ref AND t.session_ref=op.session_ref " ++
        "AND item.attempt_ordinal=op.attempt_ordinal AND " ++
        "((linked.rejection_code IS NOT NULL AND a.action_id IS NULL AND rejection.private=0) OR (linked.rejection_code IS NULL AND a.action_id IS NOT NULL AND a.session_ref=op.session_ref AND result.private=0)) THEN 0 ELSE 1 END=1) AS consistent,op.operation_id," ++
        "(SELECT " ++ tool_fulfillment.timeSql("a", "op") ++ " FROM model_tool_call c LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal " ++
        "WHERE c.operation_id=op.operation_id ORDER BY " ++ tool_fulfillment.positionSql("c", "a") ++ " DESC LIMIT 1) AS at," ++
        resolutionActionSql("tool_call", "action") ++ " AS resolution_action " ++
        "FROM last CROSS JOIN model_operation op ON op.operation_id=last.operation_id " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " AND tool_call.call_ordinal+1=?3 " ++
        "AND (SELECT max(" ++ tool_fulfillment.positionSql("c", "a") ++ ") FROM model_tool_call c " ++
        "LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id)=?2 " ++
        "AND (SELECT count(*) FROM model_tool_call c WHERE c.operation_id=op.operation_id)=" ++
        "(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
        "AND NOT EXISTS (SELECT 1 FROM model_tool_call c LEFT JOIN action_operation a " ++
        "ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id " ++
        "AND (" ++ tool_fulfillment.positionSql("c", "a") ++ " IS NULL OR " ++ tool_fulfillment.contentSql("c", "a") ++ " IS NULL))",
    .Args = struct { session: []const u8, position: u64, ordinal: u64 },
    .Row = struct { content_id: rsql.Positive, consistent: bool, operation_id: rsql.Positive, at: rsql.Positive, resolution_action: ?rsql.Positive },
    .cardinality = .each,
    .compound = true,
});

/// `owner` is the Message admission or the resolved Action that may hold a parts value; null for model text.
pub const PublicContent = struct { id: i64, value: content_value.Value, tool_operation: ?u64, admitted_at: ?u64, at: u64, source_action: ?u64 = null, owner: ?content_value.Owner = null, turn: ?u64 = null, revision: ?u64 = null };

const PublicContentRead = struct {
    position: u64,
    ordinal: u64,
    sender: ?*?activity_facts.NamedPeer = null,
    content: PublicContent = undefined,
    missing: missing_assistant_entry.Result = null,
    metadata: content_metadata.Row = undefined,
    outcome: ToolOutcomeCheck = .{},
    count: RowCount = .{},
    /// The Activity feed keeps Action values; the public Conversation hides them.
    values: bool = false,

    fn queue(read: *PublicContentRead, a: *ReadAccess, session: []const u8) void {
        read.missing = null;
        if (read.ordinal == 0) {
            a.read(missing_assistant_entry, .{ .session = session, .lower = read.position, .upper = read.position }, &read.missing);
            if (read.values) readRow(a, activity_entry, .{ .session = session, .position = read.position }, read) else readRow(a, public_entry, .{ .session = session, .position = read.position }, read);
        } else readFirst(a, public_tool_result, .{ .session = session, .position = read.position, .ordinal = read.ordinal }, read);
    }

    pub fn visit(read: *PublicContentRead, row: anytype) bool {
        return visitRow(read, row);
    }

    fn keep(read: *PublicContentRead, row: anytype) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        if (@TypeOf(row.*) == public_entry.Row or @TypeOf(row.*) == activity_entry.Row) {
            read.content = .{ .id = @intCast(row.content_id.get()), .value = undefined, .tool_operation = null, .admitted_at = if (row.admitted_at) |second| second.get() else null, .at = row.recorded_at.get(), .source_action = if (row.source_action) |action| action.get() else null, .owner = if (row.admission) |admission| .{ .message = admission.get() } else null, .turn = if (row.turn_id) |turn| turn.get() else null, .revision = if (row.source_revision) |revision| revision.get() else null };
            if (read.sender) |sender| sender.* = if (row.sender) |session| .{ .session = session } else null;
        } else {
            read.content = .{ .id = @intCast(row.content_id.get()), .value = undefined, .tool_operation = row.operation_id.get(), .admitted_at = null, .at = row.at.get(), .owner = if (row.resolution_action) |action| .{ .action = action.get() } else null };
        }
    }

    fn found(read: *const PublicContentRead) !void {
        if (read.missing != null) return error.CorruptStore;
        if (!try read.count.found()) return error.ContentNotFound;
    }

    fn queueMetadata(read: *PublicContentRead, a: *ReadAccess) void {
        if (read.content.tool_operation) |operation| a.readEach(operation_outcome, .{ .operation = operation }, std.math.maxInt(u64), &read.outcome);
        a.read(content_metadata, .{ .content_id = @intCast(read.content.id) }, &read.metadata);
    }

    fn takeMetadata(read: *PublicContentRead) !void {
        if (read.content.tool_operation != null) try read.outcome.finish();
        read.content.value = try content_parts.publicValue(&read.metadata, read.content.owner);
    }
};

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

const stored_presentation = rsql.Read(.{
    .sql = "SELECT tool_call.description," ++ tool_fulfillment.codeSql("tool_call", "a") ++ " AS code,a.authorized,item.session_ref,item.session_position," ++ outcome_columns ++ " " ++
        "FROM model_tool_call tool_call LEFT JOIN action_operation a ON a.parent_operation_id=tool_call.operation_id AND a.call_ordinal=tool_call.call_ordinal " ++
        outcome_join ++ " " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE tool_call.operation_id=?1 AND tool_call.call_ordinal=?2",
    .Args = struct { operation: u64, ordinal: u64 },
    .Row = struct {
        description: ?Bounded(tool_presentation.max_description_bytes),
        code: ?tool_presentation.ToolPresentation.Code,
        authorized: ?bool,
        session_ref: SessionText,
        session_position: rsql.Positive,
        outcome_text: ?Bounded(tool_presentation.max_description_bytes),
        outcome_link_at: ?u64,
        outcome_link_session: ?SessionText,
        outcome_label: ?Bounded(tool_presentation.max_label_bytes),
        outcome_completion: ?u8,
    },
    .cardinality = .each,
});

/// The columns and join that bring a resolved call's outcome line to a read, with the label of the Session it names.
/// Every read that builds a presentation selects these from the action as `a`, so the outcome has one reader.
pub const outcome_columns = "a.outcome_text,a.outcome_link_at,a.outcome_link_session,outcome_session.label AS outcome_label,a.outcome_completion";
pub const outcome_join = "LEFT JOIN session outcome_session ON outcome_session.session_ref=a.outcome_link_session";

/// What `outcome_columns` read, kept together until `presentationOf` turns it into a Line.
pub const StoredOutcome = struct {
    text: ?Bounded(tool_presentation.max_description_bytes) = null,
    link_at: ?u64 = null,
    link_session: ?SessionText = null,
    label: ?Bounded(tool_presentation.max_label_bytes) = null,
    completion: ?u8 = null,

    fn line(self: *const StoredOutcome) error{CorruptStore}!?tool_presentation.Line {
        const text = self.text orelse return null;
        const session = self.link_session orelse {
            if (self.link_at != null) return error.CorruptStore;
            return tool_presentation.Line.plain(text.slice()) catch return error.CorruptStore;
        };
        const at = std.math.cast(usize, self.link_at orelse return error.CorruptStore) orelse return error.CorruptStore;
        if (at > text.len) return error.CorruptStore;
        var peer: tool_presentation.NamedPeer = .{ .session = session };
        if (self.label) |label| peer.label = label;
        return tool_presentation.Line.fromParts(text.slice()[0..at], peer, text.slice()[at..]) catch return error.CorruptStore;
    }
};

const PresentationRead = struct {
    operation: u64,
    ordinal: u64,
    out: *tool_presentation.ToolPresentation,
    session: SessionText = undefined,
    proposal: ProposalRead = undefined,
    description: ?Bounded(tool_presentation.max_description_bytes) = null,
    outcome: StoredOutcome = .{},
    code: ?tool_presentation.ToolPresentation.Code = null,
    authorized: ?bool = null,
    count: RowCount = .{},

    fn init(operation: u64, ordinal: u64, publication_position: ?u64, out: *tool_presentation.ToolPresentation) PresentationRead {
        out.* = .{ .line = null, .code = .unresolved, .sign = .active, .publication_position = publication_position };
        return .{ .operation = operation, .ordinal = ordinal, .out = out };
    }

    fn queue(read: *PresentationRead, a: *ReadAccess) void {
        readRow(a, stored_presentation, .{ .operation = read.operation, .ordinal = read.ordinal }, read);
    }

    pub fn visit(read: *PresentationRead, row: *const stored_presentation.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *PresentationRead, row: *const stored_presentation.Row) error{CorruptStore}!void {
        read.description = row.description;
        read.outcome = .{ .text = row.outcome_text, .link_at = row.outcome_link_at, .link_session = row.outcome_link_session, .label = row.outcome_label, .completion = row.outcome_completion };
        read.code = row.code;
        read.authorized = row.authorized;
        read.session = row.session_ref;
        read.proposal = .{ .position = row.session_position.get() };
    }

    fn checkCall(read: *const PresentationRead) !void {
        if (!try read.count.found()) return error.CorruptStore;
    }

    fn queueProposal(read: *PresentationRead, a: *ReadAccess) void {
        readProposal(a, read.session.slice(), &read.proposal);
    }

    fn finish(read: *PresentationRead) !void {
        try read.proposal.found();
        read.out.* = try presentationOf(read.description, read.outcome, read.code, read.authorized, read.out.publication_position);
    }
};

/// The one place a saved description, a derived code and an authorization become a presentation.
/// A resolved call that recorded an outcome line shows it, finished as that outcome chose; every other row shows its call line, plain, as `done`.
pub fn presentationOf(
    description: ?Bounded(tool_presentation.max_description_bytes),
    outcome: StoredOutcome,
    code: ?tool_presentation.ToolPresentation.Code,
    authorized: ?bool,
    publication_position: ?u64,
) error{CorruptStore}!tool_presentation.ToolPresentation {
    const derived: tool_presentation.ToolPresentation.Code = code orelse if (authorized orelse false) .unresolved else .pending_permission;
    if (try outcome.line()) |shown| return tool_presentation.ToolPresentation.of(shown, derived, std.enums.fromInt(tool_presentation.Completion, outcome.completion orelse return error.CorruptStore) orelse return error.CorruptStore, publication_position);
    const line: ?tool_presentation.Line = if (description) |words| tool_presentation.Line.plain(words.slice()) catch return error.CorruptStore else null;
    return tool_presentation.ToolPresentation.of(line, derived, .done, publication_position);
}

const hosted_call = rsql.Read(.{
    .sql = "SELECT item.description,item.call_failed,op.resolved_at," ++
        "op.session_ref=item.session_ref AND op.attempt_ordinal=item.attempt_ordinal AND op.purpose=0 AND " ++
        store_schema.oneOf("op.resolution_code", &accepted_resolutions) ++
        " AS consistent FROM model_output_item item @index(model_output_hosted_history) LEFT JOIN model_operation op ON op.operation_id=item.operation_id " ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=5",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        description: Bounded(tool_presentation.max_description_bytes),
        call_failed: bool,
        resolved_at: ?rsql.Positive,
        consistent: bool,
    },
    .cardinality = .each,
});

const HostedRead = struct {
    position: u64,
    presentation: *tool_presentation.ToolPresentation,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *HostedRead, a: *ReadAccess, session: []const u8) void {
        readRow(a, hosted_call, .{ .session = session, .position = read.position }, read);
    }

    pub fn visit(read: *HostedRead, row: *const hosted_call.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *HostedRead, row: *const hosted_call.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        read.presentation.* = try presentationOf(row.description, .{}, if (row.call_failed) .failed else .succeeded, null, read.position);
        read.at = (row.resolved_at orelse return error.CorruptStore).get();
    }

    fn found(read: *const HostedRead) !void {
        if (!try read.count.found()) return error.ContentNotFound;
    }
};

const page_session = rsql.Read(.{
    .sql = "SELECT model,permission_mode,revision,next_position,compaction_trigger,output_reservation,reasoning_effort,created_at,provider,workspace,creator_ref " ++
        "FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        model: Bounded(model_capability.max_model_bytes),
        permission_mode: u1,
        revision: rsql.Positive,
        next_position: rsql.Positive,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        created_at: rsql.Positive,
        provider: connection.Name,
        workspace: *Bounded(workspace_path.max_bytes),
        creator_ref: ?Bounded(session_id.bytes),
    },
    .cardinality = .optional,
});

pub noinline fn activityPage(a: *ReadAccess, request: *const activity_read.ActivityPage, page: *activity_facts.Page) !void {
    page.* = .{ .end = 0, .direction = request.direction, .work = .{ .workspace = .{ .len = 0 } } };
    const session_ref = request.session.slice();
    var session: page_session.Row = undefined;
    session.workspace = &page.work.workspace;
    var found: store_access.Found = undefined;
    var guard: activity_sequence_guard.Result = undefined;
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
        readItems(1, a, session_ref, end, &.{.{ .position = request.position, .ordinal = ordinal }}, page.items[0..1], null, null) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    } else try runRows(a);
    try work.advance();
    try report_domain.readWorks(a, (&work)[0..1]);
    page.work.work = try work.work(session.created_at.get(), std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange);
    page.count = @min(rows.len, limit);
    page.more = rows.len > limit;
    var at: [page.items.len]ItemAt = undefined;
    for (rows.slice()[0..page.count], at[0..page.count]) |row, *item| item.* = .{ .position = row.position.get(), .ordinal = row.ordinal };
    const boundary: ?ItemAt = if (page.more) at[page.count - 1] else null;
    const lower = if (forward) request.position + 1 else if (boundary) |item| item.position else 0;
    const upper = if (forward) (if (boundary) |item| item.position else end) else if (request.position == 0) end else @min(end, request.position - @intFromBool((request.ordinal orelse 0) == 0));
    const last = if (forward) boundary else null;
    const call_position = activity_facts.queueCutoff(end, forward, page.more, if (last) |item| item.position else null);
    var missing: missing_assistant_entry.Result = null;
    var calls: CallRows = .{ .activity = &page.call_activity, .args = .{ .session = session_ref, .position = call_position, .ordinal = if (last) |item| item.ordinal else null } };
    var waiting: QueuedMessages = .{};
    if (lower <= upper and request.kinds.contains(.assistant)) a.read(missing_assistant_entry, .{ .session = session_ref, .lower = lower, .upper = upper }, &missing);
    if (request.kinds.eql(.full)) {
        a.readEach(call_activity, calls.args, std.math.maxInt(u64), &calls);
        a.readEach(queued, .{ .session = session_ref, .position = call_position }, std.math.maxInt(u64), &waiting);
    }
    try readItems(page.items.len, a, session_ref, end, at[0..page.count], page.items[0..page.count], &calls, null);
    if (missing != null) return error.CorruptStore;
    page.queued = waiting.queued;
    if (waiting.queued.count != 0) page.queued.newest_content = try content_parts.publicValue(&(waiting.newest orelse return error.CorruptStore), .{ .message = waiting.queued.newest_admission });
    page.work.read_version = .{ .instance = a.store.instance, .generation = a.store.commitGeneration() };
    page.work.revision = session.revision.get();
    page.work.creator = session.creator_ref;
}

pub const activity_search_budget = 8 * 1024 * 1024;

const SearchScratch = struct {
    window: [content_domain.ContentReader.content_window_bytes]u8 = undefined,
    matcher: word_search.Matcher = undefined,
    /// The hits of the current entry, from one text value or from each of its Text parts in order.
    hits: [3]activity_facts.Search.Hit = undefined,
    hit_count: usize = 0,
    cursor: content_parts.Cursor = undefined,
    item: activity_facts.Item = undefined,
    workspace: Bounded(workspace_path.max_bytes) = undefined,
};

pub fn searchActivity(a: *ReadAccess, request: *const activity_read.ActivitySearch, out: *activity_facts.Search) !void {
    out.count = 0;
    out.next = null;
    const mapped = try pages.Mapped(SearchScratch).map();
    defer mapped.unmap();
    const scratch = mapped.value;
    const session_ref = request.session.slice();
    var session: page_session.Row = undefined;
    session.workspace = &scratch.workspace;
    var found: store_access.Found = undefined;
    var guard: activity_sequence_guard.Result = undefined;
    a.readInto(page_session, .{ .session = session_ref }, &session, &found);
    a.read(activity_sequence_guard, .{ .session = session_ref }, &guard);
    try store_access.runNamed(a, .{.{ page_session, error.SessionReadFailed }}, error.CorruptStore);
    if (!found.get()) return error.SessionNotFound;
    if (guard != null or session.compaction_trigger == @as(?u64, 0)) return error.CorruptStore;
    const end = session.next_position.get() - 1;
    if ((request.before_position orelse 0) > end) return error.InvalidCursor;
    if (request.before_ordinal) |ordinal| {
        readItems(1, a, session_ref, end, &.{.{ .position = request.before_position.?, .ordinal = ordinal }}, (&scratch.item)[0..1], null, null) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    var position = request.before_position orelse end;
    var ordinal = request.before_ordinal orelse if (request.before_position == null) @as(u64, std.math.maxInt(i64)) else 0;
    const text_kinds = activityKinds(.initMany(&.{ .admission, .user, .assistant, .call, .tool_result, .turn_ended, .received }));
    const kinds = activityKinds(request.kinds) & text_kinds;
    var budget: usize = activity_search_budget;
    var lower: u64 = 0;
    scan: while (true) {
        var rows: Collected(ActivityPageRow, 17) = .{};
        a.readEach(activity_backward, .{ .session = session_ref, .position = position, .ordinal = ordinal, .kinds = kinds }, 17, &rows);
        try runRows(a);
        const count = @min(rows.len, 16);
        for (rows.slice()[0..count], 0..) |row, index| {
            const at: ItemAt = .{ .position = row.position.get(), .ordinal = row.ordinal };
            var located: ?Located = null;
            try readItems(1, a, session_ref, end, &.{at}, (&scratch.item)[0..1], null, &located);
            scratch.hit_count = 0;
            scratch.matcher.init(request.query.slice());
            if (scratch.item.body() == .call) {
                const call = scratch.item.body().call;
                try searchField(a, scratch, call.name, &budget);
                if (budget != 0) {
                    scratch.matcher.feed("\n");
                    try searchField(a, scratch, call.arguments, &budget);
                }
                collectHits(scratch, null);
            } else if (located) |content| switch (content.value) {
                .text => |reference| {
                    try searchContent(a, scratch, .{ .store = a.store, .content_id = content.id, .reference = reference }, &budget);
                    collectHits(scratch, null);
                },
                .parts => |value| {
                    // The manifest is read before any part, so a value whose manifest does not
                    // fit the remaining budget waits for the continuation, which starts after
                    // the last entry scanned. A first entry always fits the whole budget.
                    if (value.identity.length > budget) {
                        lower = position;
                        out.next = .{ .position = position, .ordinal = ordinal };
                        break :scan;
                    }
                    budget -= @intCast(value.identity.length);
                    try searchParts(a, scratch, request.query.slice(), .{ .content_id = @intCast(content.id), .reference = .{ .parts = value.identity } }, &budget);
                },
            };
            if (scratch.hit_count != 0) {
                const item = &out.items[out.count];
                item.position = at.position;
                item.ordinal = at.ordinal;
                item.kind = std.meta.stringToEnum(activity_facts.Item.Kind, @tagName(scratch.item.value)).?;
                item.count = scratch.hit_count;
                @memcpy(item.hits[0..item.count], scratch.hits[0..item.count]);
                out.count += 1;
            }
            position = at.position;
            ordinal = at.ordinal;
            if (budget == 0 or out.count == request.limit) {
                lower = position;
                if (index + 1 < rows.len) out.next = .{ .position = position, .ordinal = ordinal };
                break :scan;
            }
        }
        if (rows.len <= 16) break;
    }
    if (request.kinds.contains(.assistant)) {
        var missing: missing_assistant_entry.Result = null;
        const upper = if (request.before_position) |before| before - @intFromBool((request.before_ordinal orelse 0) == 0) else end;
        if (lower <= upper) {
            a.read(missing_assistant_entry, .{ .session = session_ref, .lower = lower, .upper = upper }, &missing);
            try runRows(a);
            if (missing != null) return error.CorruptStore;
        }
    }
}

fn searchField(a: *ReadAccess, scratch: *SearchScratch, field: activity_read.ProposalFieldReference, budget: *usize) !void {
    const reference: ContentReference = .{ .length = field.length, .digest = field.digest };
    const id = content_domain.contentIdOf(a, reference, false) catch |err| switch (err) {
        error.ContentIsParts => return error.CorruptStore,
        else => return err,
    };
    try searchContent(a, scratch, .{ .store = a.store, .content_id = id, .reference = reference }, budget);
}

fn collectHits(scratch: *SearchScratch, part: ?u32) void {
    scratch.matcher.finish();
    for (scratch.matcher.hits[0..scratch.matcher.count]) |*hit| {
        if (scratch.hit_count == scratch.hits.len) return;
        scratch.hits[scratch.hit_count] = .{ .snippet = hit.snippet, .offset = hit.offset, .length = hit.length, .part = part };
        scratch.hit_count += 1;
    }
}

/// Searches each Text part of a parts value on its own, so no match spans two parts;
/// hits name their part. The cursor certifies the manifest before the first part.
fn searchParts(a: *ReadAccess, scratch: *SearchScratch, query: []const u8, value: content_domain.Value, budget: *usize) !void {
    scratch.cursor.init(value);
    while (try scratch.cursor.next(a)) |part| {
        if (part.kind != .text) continue;
        if (budget.* == 0 or scratch.hit_count == scratch.hits.len) return;
        scratch.matcher.init(query);
        try searchContent(a, scratch, .{ .store = a.store, .content_id = @intCast(part.content_id), .reference = part.reference }, budget);
        collectHits(scratch, part.ordinal);
    }
}

fn searchContent(a: *ReadAccess, scratch: *SearchScratch, location: ContentLocation, budget: *usize) !void {
    var reader: content_domain.ContentReader = undefined;
    reader.open(location);
    defer reader.close();
    var offset: u64 = 0;
    while (offset < location.reference.length and budget.* != 0) {
        const count = try reader.readWithAccess(a, offset, scratch.window[0..@min(scratch.window.len, budget.*)]);
        scratch.matcher.feed(scratch.window[0..count]);
        offset += count;
        budget.* -= count;
    }
}

const ActivityPageRow = struct { position: rsql.Positive, ordinal: u64 };

const ItemAt = struct { position: u64, ordinal: u64 };

const call_candidates_sql = "ops AS (SELECT parent_operation_id AS operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NULL AND background_position IS NULL " ++
    "UNION SELECT operation_id FROM model_tool_call @index(model_tool_call_acceptance) WHERE session_ref=?1 AND acceptance_position>=?2 " ++
    "UNION SELECT parent_operation_id FROM action_operation @index(action_operation_acceptance) WHERE session_ref=?1 AND acceptance_position>=?2 AND background_position IS NULL UNION SELECT parent_operation_id FROM action_operation @index(action_operation_background) WHERE session_ref=?1 AND background_position>=?2), " ++
    "tool_groups AS (SELECT op.operation_id,max(" ++ tool_fulfillment.positionSql("tool_call", "action") ++ ") AS position " ++
    "FROM ops CROSS JOIN model_operation op ON op.operation_id=ops.operation_id JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " GROUP BY op.operation_id " ++
    "HAVING count(*)=(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
    "AND count(" ++ tool_fulfillment.positionSql("tool_call", "action") ++ ")=count(*) " ++
    "AND count(" ++ tool_fulfillment.contentSql("tool_call", "action") ++ ")=count(*)), " ++
    "candidates AS (SELECT op.operation_id,tool_call.call_ordinal,tool_groups.position FROM ops CROSS JOIN model_operation op ON op.operation_id=ops.operation_id " ++
    "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=op.operation_id " ++
    "LEFT JOIN tool_groups ON tool_groups.operation_id=op.operation_id WHERE op.session_ref=?1 AND " ++ store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " " ++
    "AND (tool_groups.position IS NULL OR tool_groups.position>?2 OR (tool_groups.position=?2 AND ?3 IS NOT NULL AND tool_call.call_ordinal+1>?3)))";

const CallArgs = struct { session: []const u8, position: u64, ordinal: ?u64 };
const CallRow = struct { operation_id: rsql.Positive, call_ordinal: u64, position: ?rsql.Positive };

const call_activity = rsql.Read(.{
    .sql = "WITH " ++ call_candidates_sql ++ " SELECT operation_id,call_ordinal,position FROM candidates ORDER BY operation_id,call_ordinal",
    .Args = CallArgs,
    .Row = CallRow,
    .cardinality = .each,
    .compound = true,
});

const call_outcomes = ToolOutcome(call_candidates_sql ++ ", ", "SELECT DISTINCT operation_id," ++ expectedCallsSql("candidates.operation_id") ++ " FROM candidates", CallArgs, true);

const CallRows = struct {
    activity: *activity_facts.CallActivity,
    args: CallArgs,
    operations: [max_operations]u64 = undefined,
    operation_count: usize = 0,
    check: ToolOutcomeCheck = .{},
    presentations: [@typeInfo(@FieldType(activity_facts.CallActivity, "entries")).array.len]PresentationRead = undefined,

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

pub const QueuedMessages = struct {
    queued: activity_facts.Queued = .{},
    newest: ?content_metadata.Row = null,

    pub fn visit(messages: *QueuedMessages, row: *const queued.Row) bool {
        if (row.taken) return false;
        if (messages.queued.count == 0) {
            messages.queued.newest_admission = row.admission_id.get();
            messages.queued.newest_position = row.admission_position.get();
            messages.newest = if (row.byte_length != null and row.digest != null and row.private != null and row.form != null)
                .{ .byte_length = row.byte_length.?, .digest = row.digest.?, .private = row.private.?, .form = row.form.? }
            else
                null;
        }
        messages.queued.count += 1;
        messages.queued.oldest_position = row.admission_position.get();
        return true;
    }
};

const peer_label = rsql.Read(.{
    .sql = "SELECT label FROM session WHERE session_ref=?1",
    .Args = struct { session: SessionText },
    .Row = struct { label: ?Bounded(tool_presentation.max_label_bytes) },
    .cardinality = .each,
});

const activity_message = rsql.Read(.{
    .sql = "SELECT m.command_key,m.turn_id,m.content_id," ++
        "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=m.session_ref AND e.source_admission_id=m.admission_id AND e.session_position<=?2) AS applied," ++
        "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=m.session_ref AND s.admission_cutoff>=m.admission_id AND s.position<=?2) AS excluded," ++
        sourced_input.consistentSql("m", "c") ++ " " ++
        "AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
        "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))) AS consistent," ++
        "m.admitted_at,m.sender_session_ref," ++ sourced_input.actionIdSql("m") ++ " AS source_action_id FROM message_admission m " ++
        "LEFT JOIN core_command c ON c.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "WHERE m.session_ref=?1 AND m.admission_id=?3",
    .Args = struct { session: []const u8, end: u64, admission: u64 },
    .Row = struct {
        command_key: Bounded(idempotency_key.max_bytes),
        turn_id: ?rsql.Positive,
        content_id: rsql.Positive,
        applied: bool,
        excluded: bool,
        consistent: bool,
        admitted_at: rsql.Positive,
        sender_session_ref: ?SessionText,
        source_action_id: ?rsql.Positive,
    },
    .cardinality = .each,
});

const approval_request = rsql.Read(.{
    .sql = "SELECT action.session_ref,action.parent_operation_id AS operation,action.call_ordinal,op.resolved_at,item.session_position FROM action_operation action " ++
        "JOIN model_tool_call c ON c.operation_id=action.parent_operation_id AND c.call_ordinal=action.call_ordinal " ++
        "JOIN model_output_item item ON item.operation_id=c.operation_id AND item.item_ordinal=c.item_ordinal " ++
        "JOIN model_operation op ON op.operation_id=action.parent_operation_id AND op.session_ref=action.session_ref WHERE action.action_id=?1 AND action.approval_position IS NOT NULL AND (action.session_ref=?2 OR EXISTS(SELECT 1 FROM session_forward f WHERE f.target_ref=?2 AND f.kind=1 AND f.source_id=action.action_id AND f.child_ref=action.session_ref AND f.position IS NOT NULL))",
    .Args = struct { action: u64, session: []const u8 },
    .Row = struct { session_ref: SessionText, operation: rsql.Positive, call_ordinal: u64, resolved_at: rsql.Positive, session_position: rsql.Positive },
    .cardinality = .optional,
});

const session_change = rsql.Read(.{
    .sql = "SELECT revision,field,changed_at,provider_text FROM session_change WHERE session_ref=?1 AND position=?2 AND ordinal=?3",
    .Args = struct { session: []const u8, position: u64, ordinal: u64 },
    .Row = struct { revision: rsql.Positive, field: session_settings.SessionField, changed_at: rsql.Positive, provider_text: *?Bounded(outcome_code.max_report_bytes) },
    .cardinality = .optional,
});

const compaction_row = rsql.Read(.{
    .sql = "SELECT coalesce(history_dropped,0) AS dropped,resolved_at FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND purpose=1 AND " ++
        store_schema.resolutionIs("resolution_code", .compacted),
    .Args = struct { operation: u64, session: []const u8 },
    .Row = struct { dropped: u64, resolved_at: rsql.Positive },
    .cardinality = .one,
});

const model_call_row = rsql.Read(.{
    .sql = "SELECT revision.model,o.model_evidence,o.usage_uncached_tokens AS uncached,o.usage_cache_read_tokens AS cached," ++
        "o.usage_cache_write_tokens AS cache_write,o.usage_output_tokens AS output,o.latency_ms,o.first_event_ms," ++
        "o.resolution_code AS status,o.attempt_ordinal AS attempts,o.resolved_at " ++
        "FROM model_operation o JOIN session_revision revision ON revision.session_ref=o.session_ref AND revision.revision=o.settings_revision " ++
        "WHERE o.operation_id=?1 AND o.session_ref=?2 AND o.resolution_code IS NOT NULL",
    .Args = struct { operation: u64, session: []const u8 },
    .Row = struct {
        model: Bounded(model_capability.max_model_bytes),
        model_evidence: ?rsql.Blob(model_evidence.max_bytes),
        uncached: ?u64,
        cached: ?u64,
        cache_write: ?u64,
        output: ?u64,
        latency_ms: ?u64,
        first_event_ms: ?u64,
        status: Bounded(outcome_code.max_bytes),
        attempts: rsql.Positive,
        resolved_at: rsql.Positive,
    },
    .cardinality = .each,
});

const ModelCallRead = struct {
    operation: u64,
    item: *activity_facts.Item,
    decoded: *model_call_row.Row = undefined,
    count: RowCount = .{},

    pub fn visit(read: *ModelCallRead, row: *const model_call_row.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *ModelCallRead, row: *const model_call_row.Row) error{CorruptStore}!void {
        const item = read.item;
        item.at = row.resolved_at.get();
        item.value = .{ .model_call = .{
            .model = row.model,
            .served_model = model_evidence.servedModel(if (row.model_evidence) |*evidence| evidence.slice() else null) catch return error.CorruptStore,
            .input_tokens = if (row.uncached) |uncached| uncached +| (row.cached orelse return error.CorruptStore) +| (row.cache_write orelse return error.CorruptStore) else null,
            .output_tokens = row.output,
            .cached_tokens = row.cached,
            .latency_ms = row.latency_ms,
            .first_event_ms = row.first_event_ms,
            .status = row.status,
            .attempts = row.attempts.get(),
        } };
    }
};

const call_details = rsql.Read(.{
    .sql = "SELECT op.resolved_at,c.description,CASE WHEN name.byte_length<=" ++ std.fmt.comptimePrint("{d}", .{activity_read.CallText.max_tool_bytes}) ++ " THEN @payload(name) END AS tool," ++
        action_domain.mcpServerForNameSql("op", "c.name_content_id") ++ " AS server FROM model_operation op " ++
        "JOIN model_tool_call c ON c.operation_id=op.operation_id JOIN content name ON name.content_id=c.name_content_id " ++
        "WHERE op.operation_id=?1 AND op.session_ref=?2 AND c.call_ordinal=?3",
    .Args = struct { operation: u64, session: []const u8, ordinal: u64 },
    .Row = struct { resolved_at: rsql.Positive, description: *?activity_read.CallText.Description, tool: *?activity_read.CallText.Tool, server: *?activity_read.CallText.Server },
    .cardinality = .optional,
});

fn checkCallDetails(details: *const call_details.Row, metadata: *const activity_read.ProposalMetadata) error{CorruptStore}!void {
    const field = metadata.fields[@backingInt(tool_proposal.Field.name)];
    if (details.tool.*) |*tool| {
        if (tool.slice().len != field.length or !std.mem.eql(u8, &content_string.digest(tool.slice()), &field.digest)) return error.CorruptStore;
    } else if (field.length <= activity_read.CallText.max_tool_bytes) return error.CorruptStore;
}

const turn_outcome = rsql.Read(.{
    .sql = "SELECT t.session_ref,t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.session_ref=t.session_ref AND o.turn_id=t.turn_id " ++
        "AND o.resolution_code IS NOT NULL AS consistent,o.resolution_content_id,t.outcome_at," ++
        "EXISTS(SELECT 1 FROM session_stop stop @index(session_stop_turn) WHERE stop.selected_turn_id=t.turn_id) AS stopped " ++
        "FROM turn t LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
        "WHERE t.turn_id=?3 AND ((t.session_ref=?1 AND t.outcome_position=?2) OR EXISTS(SELECT 1 FROM session_forward f @index(session_forward_feed) WHERE f.target_ref=?1 AND f.position=?2 AND f.kind=2 AND f.source_id=t.turn_id AND f.child_ref=t.session_ref))",
    .Args = struct { session: []const u8, position: u64, turn: u64 },
    .Row = struct {
        session_ref: SessionText,
        turn_id: rsql.Positive,
        operation_id: rsql.Positive,
        outcome_code: Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        consistent: bool,
        resolution_content_id: ?rsql.Positive,
        outcome_at: rsql.Positive,
        stopped: bool,
    },
    .cardinality = .each,
});

const session_stop = rsql.Read(.{
    .sql = "SELECT s.command_key,s.selected_turn_id,s.admission_cutoff," ++ action_domain.stopCompletedSql("s", "t", "?3") ++ " AS completed," ++
        "(c.kind=3 OR (c.kind=6 AND EXISTS(SELECT 1 FROM session_archive_command archived WHERE archived.command_key=c.command_key AND archived.archived=1))) " ++
        "AND c.accepted=1 AND c.target=s.session_ref AND (s.selected_turn_id IS NULL OR t.session_ref=s.session_ref) AS consistent,s.stopped_at " ++
        "FROM session_stop s LEFT JOIN core_command c ON c.command_key=s.command_key LEFT JOIN turn t ON t.turn_id=s.selected_turn_id WHERE s.session_ref=?1 AND s.position=?2",
    .Args = struct { session: []const u8, position: u64, end: u64 },
    .Row = struct {
        command_key: Bounded(idempotency_key.max_bytes),
        selected_turn_id: ?rsql.Positive,
        admission_cutoff: u64,
        completed: bool,
        consistent: bool,
        stopped_at: rsql.Positive,
    },
    .cardinality = .each,
});

const LabelRead = struct {
    peer: *activity_facts.NamedPeer,
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

const MessageRead = struct {
    message: *activity_facts.Item.Message,
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
        message.source_action = if (row.source_action_id) |action| action.get() else null;
        if (row.applied) message.turn = (row.turn_id orelse return error.CorruptStore).get();
        read.content_id = row.content_id.get();
    }
};

const OutcomeRead = struct {
    position: u64,
    turn: u64,
    outcome: *activity_facts.Item.TurnEnded,
    content_id: ?u64 = null,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *OutcomeRead, a: *ReadAccess, session: []const u8) void {
        readFirst(a, turn_outcome, .{ .session = session, .position = read.position, .turn = read.turn }, read);
    }

    pub fn visit(read: *OutcomeRead, row: *const turn_outcome.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *OutcomeRead, row: *const turn_outcome.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        read.content_id = if (row.outcome_content_id) |id| id.get() else null;
        const outcome = try TurnOutcome.decode(row.outcome_code.slice(), if (read.content_id) |id| @intCast(id) else null);
        switch (outcome) {
            .completed => |answer| if (row.resolution_content_id == null or row.resolution_content_id.?.get() != answer) return error.CorruptStore,
            .cancelled, .retry_exhausted, .resource_exceeded, .failed => {},
        }
        read.outcome.* = .{ .session = .{}, .turn = row.turn_id.get(), .operation = row.operation_id.get(), .ending = outcome.ending(row.stopped), .code = row.outcome_code, .content = null };
        read.outcome.session.set(row.session_ref.slice()) catch return error.CorruptStore;
        read.at = row.outcome_at.get();
    }
};

const StopRead = struct {
    position: u64,
    end: u64,
    stop: *activity_facts.Item.Stop,
    at: u64 = 0,
    count: RowCount = .{},

    fn queue(read: *StopRead, a: *ReadAccess, session: []const u8) void {
        readFirst(a, session_stop, .{ .session = session, .position = read.position, .end = read.end }, read);
    }

    pub fn visit(read: *StopRead, row: *const session_stop.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *StopRead, row: *const session_stop.Row) error{CorruptStore}!void {
        if (!row.consistent) return error.CorruptStore;
        const turn: ?u64 = if (row.selected_turn_id) |id| id.get() else null;
        read.stop.* = .{ .key = row.command_key, .turn = turn, .cutoff = row.admission_cutoff, .completion = if (row.completed) .completed else .pending };
        read.at = row.stopped_at.get();
    }
};

const ItemRead = struct {
    position: u64,
    ordinal: u64,
    item: *activity_facts.Item,
    content: ?struct { id: u64, value: content_value.Value } = null,
    round: u8 = 0,
    done: bool = false,
    kind: u8 = 0,
    state: union {
        first: struct { missing: missing_assistant_entry.Result, row: activity_item.Result },
        message: struct { read: MessageRead, metadata: content_metadata.Row = undefined, label: LabelRead = undefined, entry: PublicContentRead },
        content: struct { read: PublicContentRead, presentation: PresentationRead = undefined, answer: answer_entry.Result = null },
        call: struct { proposal: ProposalRead, resolved: call_details.Row = undefined, found: store_access.Found = undefined },
        hosted: HostedRead,
        outcome: struct { read: OutcomeRead, metadata: content_metadata.Row = undefined },
        stop: StopRead,
        approval: struct { row: approval_request.Result = null, metadata: activity_read.ProposalMetadata = undefined, proposal: ProposalRead = undefined, details: call_details.Row = undefined, found: store_access.Found = undefined },
        change: struct { row: session_change.Row = undefined, found: store_access.Found = undefined },
        compaction: compaction_row.Row,
        model_call: ModelCallRead,
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
            3, 5, 16 => {
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
                if (read.round == 1) readProposal(a, session, &call.proposal) else {
                    call.resolved.description = &item.value.call.description;
                    call.resolved.tool = &item.value.call.tool;
                    call.resolved.server = &item.value.call.server;
                    a.readInto(call_details, .{ .operation = item.value.call.operation, .session = session, .ordinal = item.value.call.call_ordinal }, &call.resolved, &call.found);
                }
            },
            10 => read.state.hosted.queue(a, session),
            6 => {
                const outcome = &read.state.outcome;
                if (read.round == 1) outcome.read.queue(a, session) else a.read(content_metadata, .{ .content_id = outcome.read.content_id.? }, &outcome.metadata);
            },
            7 => read.state.stop.queue(a, session),
            12 => {
                const approval = &read.state.approval;
                if (read.round == 1) a.read(approval_request, .{ .action = item.value.approval_requested.action, .session = session }, &approval.row) else if (read.round == 2) readProposal(a, item.value.approval_requested.session.slice(), &approval.proposal) else {
                    const request = &item.value.approval_requested;
                    approval.details.description = &request.description;
                    approval.details.tool = &request.tool;
                    approval.details.server = &request.server;
                    a.readInto(call_details, .{ .operation = request.operation, .session = request.session.slice(), .ordinal = request.call_ordinal }, &approval.details, &approval.found);
                }
            },
            13 => {
                const change = &read.state.change;
                change.row.provider_text = &item.value.session_changed.provider_text;
                a.readInto(session_change, .{ .session = session, .position = read.position, .ordinal = read.ordinal }, &change.row, &change.found);
            },
            14 => a.read(compaction_row, .{ .operation = item.value.compacted.operation, .session = session }, &read.state.compaction),
            15 => {
                const call = &read.state.model_call;
                call.decoded = &a.store.reportScratch(ActivityItemReads).model_call;
                readRow(a, model_call_row, .{ .operation = call.operation, .session = session }, call);
            },
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
                    if (kind != 2 and (kind == 11) != (message.read.message.sender != null or message.read.message.source_action != null)) return error.CorruptStore;
                    if (kind == 2) try message.entry.found();
                    return;
                }
                message.read.message.content = try content_parts.publicValue(&message.metadata, .{ .message = message.read.message.admission });
                if (message.read.message.sender != null) try message.label.found();
                item.at = message.read.message.admitted_at;
                if (kind == 2) {
                    if (message.read.message.state != .applied) return error.CorruptStore;
                    try message.entry.takeMetadata();
                    if (message.entry.content.id != message.read.content_id) return error.CorruptStore;
                    item.at = message.entry.content.at;
                }
                read.exposes(message.read.content_id, message.read.message.content);
            },
            3, 5, 16 => {
                const content = &read.state.content;
                switch (read.round) {
                    1 => return content.read.found(),
                    2 => {
                        try content.read.takeMetadata();
                        const found = content.read.content;
                        item.at = found.at;
                        if (read.kind == 3) {
                            // An assistant entry has no owner, so its projection is text or fenced.
                            item.value = .{ .assistant = .{ .content = found.value.text, .final = content.answer != null } };
                            read.exposes(@intCast(found.id), found.value);
                            read.done = true;
                            return;
                        }
                        if (read.kind == 16) {
                            // Instruction text has no owner, so its projection is text or fenced.
                            item.value = .{ .instruction = .{ .turn = found.turn, .revision = found.revision, .content = switch (found.value) {
                                .text => |reference| reference,
                                .parts => return error.CorruptStore,
                            } } };
                            read.exposes(@intCast(found.id), found.value);
                            read.done = true;
                            return;
                        }
                        if (found.tool_operation == null) return error.CorruptStore;
                        item.value.tool_result.content = found.value;
                        read.exposes(@intCast(found.id), found.value);
                        return content.presentation.checkCall();
                    },
                    else => try content.presentation.finish(),
                }
            },
            4 => {
                const call = &read.state.call;
                if (read.round == 1) {
                    try call.proposal.found();
                    read.exposes(call.proposal.arguments_content_id, .{ .text = call.proposal.arguments });
                    return;
                }
                if (!call.found.get()) return error.CorruptStore;
                try checkCallDetails(&call.resolved, &item.value.call);
                item.at = call.resolved.resolved_at.get();
            },
            10 => {
                try read.state.hosted.found();
                item.at = read.state.hosted.at;
            },
            6 => {
                const outcome = &read.state.outcome;
                if (read.round == 1) {
                    if (!try outcome.read.count.found()) return error.CorruptStore;
                    item.at = outcome.read.at;
                    if (outcome.read.content_id != null) return;
                } else {
                    // An outcome has no owner, so its projection is text or fenced.
                    const content = try content_parts.publicValue(&outcome.metadata, null);
                    item.value.turn_ended.content = content.text;
                    read.exposes(outcome.read.content_id.?, content);
                }
            },
            7 => {
                if (!try read.state.stop.count.found()) return error.CorruptStore;
                item.at = read.state.stop.at;
            },
            12 => {
                const approval = &read.state.approval;
                const row = approval.row orelse return error.CorruptStore;
                const request = &item.value.approval_requested;
                if (read.round == 1) {
                    request.session.set(row.session_ref.slice()) catch return error.CorruptStore;
                    request.operation = row.operation.get();
                    request.call_ordinal = row.call_ordinal;
                    item.at = row.resolved_at.get();
                    approval.proposal = .{ .position = row.session_position.get(), .metadata = &approval.metadata };
                    return;
                }
                if (read.round == 2) {
                    try approval.proposal.found();
                    if (approval.metadata.action != request.action or approval.metadata.operation != request.operation or approval.metadata.call_ordinal != request.call_ordinal) return error.CorruptStore;
                    read.exposes(approval.proposal.arguments_content_id, .{ .text = approval.proposal.arguments });
                    return;
                }
                if (!approval.found.get()) return error.CorruptStore;
                try checkCallDetails(&approval.details, &approval.metadata);
            },
            13 => {
                const change = &read.state.change;
                if (!change.found.get()) return error.CorruptStore;
                const row = &change.row;
                if (row.revision.get() != item.value.session_changed.revision) return error.CorruptStore;
                item.value.session_changed.field = row.field;
                item.at = row.changed_at.get();
            },
            14 => {
                item.value.compacted.dropped = read.state.compaction.dropped;
                item.at = read.state.compaction.resolved_at.get();
            },
            15 => if (!try read.state.model_call.count.found()) return error.CorruptStore,
            else => unreachable,
        }
        read.done = true;
    }

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
                read.state = .{ .message = .{ .read = .{ .message = message }, .entry = .{ .position = read.position, .ordinal = read.ordinal, .values = true } } };
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
            6 => {
                item.value = .{ .turn_ended = undefined };
                read.state = .{ .outcome = .{ .read = .{ .position = read.position, .turn = (row.id orelse return error.CorruptStore).get(), .outcome = &item.value.turn_ended } } };
            },
            7 => {
                item.value = .{ .stop = undefined };
                read.state = .{ .stop = .{ .position = read.position, .end = undefined, .stop = &item.value.stop } };
            },
            12 => {
                item.value = .{ .approval_requested = .{ .session = undefined, .action = (row.id orelse return error.CorruptStore).get(), .operation = undefined, .call_ordinal = undefined } };
                read.state = .{ .approval = .{} };
            },
            13 => {
                item.value = .{ .session_changed = .{ .revision = (row.id orelse return error.CorruptStore).get(), .field = undefined } };
                read.state = .{ .change = undefined };
            },
            14 => {
                item.value = .{ .compacted = .{ .operation = (row.id orelse return error.CorruptStore).get(), .dropped = undefined } };
                read.state = .{ .compaction = undefined };
            },
            15 => read.state = .{ .model_call = .{ .operation = (row.id orelse return error.CorruptStore).get(), .item = item } },
            16 => read.state = .{ .content = .{ .read = .{ .position = read.position, .ordinal = read.ordinal, .values = true } } },
            else => return error.CorruptStore,
        }
    }

    fn exposes(read: *ItemRead, id: u64, value: content_value.Value) void {
        read.content = .{ .id = id, .value = value };
    }

    fn located(read: *const ItemRead) ?Located {
        const content = read.content orelse return null;
        return .{ .id = @intCast(content.id), .value = content.value };
    }
};

const Located = struct { id: i64, value: content_value.Value };

const ActivityItemReads = struct {
    items: [activity_read.ActivityPage.items]ItemRead = undefined,
    model_call: model_call_row.Row = undefined,
};

noinline fn readItems(comptime max: usize, a: *ReadAccess, session: []const u8, end: u64, at: []const ItemAt, items: []activity_facts.Item, calls: ?*CallRows, located: ?*?Located) !void {
    std.debug.assert(at.len <= max and max <= activity_read.ActivityPage.items);
    const reads = &a.store.reportScratch(ActivityItemReads).items;
    for (at, items, reads[0..at.len]) |place, *item, *read| read.* = .{ .position = place.position, .ordinal = place.ordinal, .item = item };
    var round: u8 = 0;
    while (true) : (round += 1) {
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

pub fn openActivityContent(a: *ReadAccess, request: *const activity_read.ReadActivityContent) !ContentLocation {
    var guard: activity_sequence_guard.Result = undefined;
    a.read(activity_sequence_guard, .{ .session = request.session.slice() }, &guard);
    a.run() catch |err| return store_core.fence(a.store, if (err == error.StatementFailed) error.CorruptStore else err);
    if (guard != null) return store_core.fence(a.store, error.CorruptStore);
    var item: activity_facts.Item = undefined;
    var located: ?Located = null;
    readItems(1, a, request.session.slice(), std.math.maxInt(i64), &.{.{ .position = request.position, .ordinal = request.ordinal }}, (&item)[0..1], null, &located) catch |err| switch (err) {
        error.ContentNotFound => return err,
        else => return store_core.fence(a.store, err),
    };
    const content = located orelse return error.ContentNotFound;
    return .{ .store = a.store, .content_id = content.id, .reference = switch (content.value) {
        .text => |reference| reference,
        .parts => return error.ContentIsParts,
    } };
}

pub const ActivityTool = struct {
    name: activity_read.ProposalFieldReference,
    presentation: tool_presentation.ToolPresentation,
};

pub noinline fn activityTool(a: *ReadAccess, request: *const activity_read.ReadActivityContent) !ActivityTool {
    var metadata: activity_read.ProposalMetadata = undefined;
    var presentation: tool_presentation.ToolPresentation = undefined;
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
    return .{ .name = metadata.fields[@backingInt(tool_proposal.Field.name)], .presentation = presentation };
}

const proposal_fields = [3][]const u8{ "name_content_id", "call_id_content_id", "arguments_content_id" };

pub const proposal_columns = "item.operation_id,op.turn_id,tool_call.call_ordinal,action.action_id,tool_call.rejection_code," ++
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

pub const proposal_joins = "LEFT JOIN model_operation op ON op.operation_id=item.operation_id LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
    "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
    "LEFT JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
    "LEFT JOIN content field0 ON field0.content_id=tool_call." ++ proposal_fields[0] ++ " " ++
    "LEFT JOIN content field1 ON field1.content_id=tool_call." ++ proposal_fields[1] ++ " " ++
    "LEFT JOIN content field2 ON field2.content_id=tool_call." ++ proposal_fields[2] ++ " ";

pub const proposal_row = rsql.Read(.{
    .sql = "SELECT " ++ proposal_columns ++ " FROM model_output_item item " ++ proposal_joins ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=3",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct {
        operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        call_ordinal: u64,
        action_id: ?rsql.Positive,
        rejection_code: ?tool_proposal.Rejection,
        name_content_id: rsql.Positive,
        call_id_content_id: rsql.Positive,
        arguments_content_id: rsql.Positive,
        consistent: bool,
        field_metadata: activity_read.FieldCertificate.Bytes,
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

pub const ProposalRead = struct {
    position: u64,
    metadata: ?*activity_read.ProposalMetadata = null,
    count: RowCount = .{},
    arguments_content_id: u64 = 0,
    arguments: content_value.Reference = undefined,

    pub fn visit(read: *ProposalRead, row: *const proposal_row.Row) bool {
        return visitRow(read, row);
    }

    fn keep(read: *ProposalRead, row: *const proposal_row.Row) error{CorruptStore}!void {
        const fields = try certifiedFields(row);
        read.arguments_content_id = row.arguments_content_id.get();
        read.arguments = .{ .length = fields[2].length, .digest = fields[2].digest };
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

    pub fn found(read: *const ProposalRead) error{ ContentNotFound, CorruptStore }!void {
        if (!try read.count.found()) return error.ContentNotFound;
    }
};

fn certifiedFields(row: *const proposal_row.Row) error{CorruptStore}![3]activity_read.ProposalFieldReference {
    if (!row.consistent) return error.CorruptStore;
    var fields: [3]activity_read.ProposalFieldReference = undefined;
    inline for (0..3) |index| {
        const suffix = std.fmt.comptimePrint("{d}", .{index});
        const length: u64 = @field(row, "length" ++ suffix);
        const digest: [32]u8 = @field(row, "digest" ++ suffix);
        const certified = activity_read.FieldCertificate.read(&row.field_metadata, index);
        if (@field(row, "private" ++ suffix) or length != certified.length or
            !std.mem.eql(u8, &digest, &certified.digest)) return error.CorruptStore;
        fields[index] = .{ .length = length, .digest = digest };
    }
    return fields;
}

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

pub fn expectedCallsSql(comptime operation: []const u8) []const u8 {
    return "(SELECT count(*) FROM model_output_item expected WHERE expected.operation_id=" ++ operation ++ " AND expected.item_kind=3) AS expected";
}

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
    rejection_code: ?tool_proposal.Rejection,
    name_content_id: ?rsql.Positive,
    call_id_content_id: ?rsql.Positive,
    arguments_content_id: ?rsql.Positive,
    consistent: bool,
    field_metadata: ?activity_read.FieldCertificate.Bytes,
    length0: ?u64,
    digest0: ?[32]u8,
    private0: ?bool,
    length1: ?u64,
    digest1: ?[32]u8,
    private1: ?bool,
    length2: ?u64,
    digest2: ?[32]u8,
    private2: ?bool,
};

fn proposalOf(row: anytype) error{CorruptStore}!proposal_row.Row {
    var out: proposal_row.Row = undefined;
    inline for (@typeInfo(proposal_row.Row).@"struct".field_names) |name| {
        const Field = @FieldType(proposal_row.Row, name);
        const value = @field(row, name);
        @field(out, name) = if (@typeInfo(Field) == .optional or Field == @TypeOf(value)) value else value orelse return error.CorruptStore;
    }
    return out;
}

pub fn certifyCall(row: anytype) error{CorruptStore}!void {
    _ = try certifiedFields(&try proposalOf(row));
}

pub const ToolOutcomeCheck = struct {
    operation: u64 = 0,
    expected: u32 = 0,
    calls: u32 = 0,
    valid: u32 = 0,
    failed: bool = false,

    pub fn visit(check: *ToolOutcomeCheck, row: *const ToolOutcomeRow) bool {
        if (check.failed) return false;
        check.take(row) catch {
            check.failed = true;
            return false;
        };
        return true;
    }

    pub fn take(check: *ToolOutcomeCheck, row: *const ToolOutcomeRow) error{CorruptStore}!void {
        const operation = row.scope_operation.get();
        if (operation != check.operation) {
            try check.close();
            check.* = .{ .operation = operation, .expected = std.math.cast(u32, row.expected) orelse return error.CorruptStore };
        }
        if (row.ordinal == null) return;
        if (check.calls == check.expected) return error.CorruptStore;
        check.calls += 1;
        try certifyCall(row);
        const rejected = row.rejection_code != null and row.rejection_present and row.call_acceptance != null and row.action_id == null;
        const resolved = row.rejection_code == null and row.action_id != null and row.action_resolved and row.result_present and row.action_acceptance != null;
        const unresolved = row.rejection_code == null and row.action_id != null and !row.action_resolved and !row.action_content and row.action_acceptance == null;
        const fields = row.length0 != null and row.length1 != null and row.length2 != null;
        if (row.item_kind == 3 and fields and (rejected or resolved or unresolved)) check.valid += 1;
    }

    fn close(check: *ToolOutcomeCheck) error{CorruptStore}!void {
        if (check.operation == 0) return;
        if (check.expected == 0 or check.calls != check.expected or check.valid != check.expected) return error.CorruptStore;
        check.operation = 0;
    }

    pub fn finish(check: *ToolOutcomeCheck) error{CorruptStore}!void {
        if (check.failed) return error.CorruptStore;
        try check.close();
    }
};

fn optionalPositive(value: ?rsql.Positive) ?u64 {
    return if (value) |positive| positive.get() else null;
}

const operation_outcome = ToolOutcome("", "SELECT DISTINCT ?1 AS operation_id," ++ expectedCallsSql("?1"), struct { operation: u64 }, false);

pub fn readProposal(a: anytype, session: []const u8, read: *ProposalRead) void {
    readRow(a, proposal_row, .{ .session = session, .position = read.position }, read);
}

pub fn proposal(a: anytype, session: []const u8, position: u64) !activity_read.ProposalMetadata {
    var metadata: activity_read.ProposalMetadata = undefined;
    var read: ProposalRead = .{ .position = position, .metadata = &metadata };
    readProposal(a, session, &read);
    try a.run();
    try read.found();
    return metadata;
}
