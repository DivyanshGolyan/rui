const std = @import("std");
const replay_recipe = @import("../../replay_recipe.zig");
const attempt = @import("../../attempt.zig");
const outcome_code = @import("../../outcome_code.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const provider_name = @import("../../provider_name.zig");
const model_catalog = @import("../../model_catalog.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const output_format = @import("../../output_format.zig");
const retry_policy = @import("../../retry_policy.zig");
const turn_policy = @import("../../turn_policy.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const rsql = @import("../rsql.zig");
const tool_fulfillment = @import("tool_fulfillment.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const action_domain = @import("action.zig");
const configuration_domain = @import("configuration.zig");
const operation_effort = @import("operation_effort.zig");
const historical_domain = @import("historical.zig");
const history_floor_domain = @import("history_floor.zig");
const model_settlement_domain = @import("model_settlement.zig");
const model_facts_domain = @import("model_facts.zig");
const model_attempt = @import("model_attempt.zig");
const reads_domain = @import("reads.zig");
const tool_offer = @import("tool_offer.zig");
const store_schema = @import("../schema.zig");
const turn_domain = @import("turn.zig");
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptBinding = store_core.AttemptBinding;
const Faults = store_core.Faults;
const ModelOperationKind = historical_domain.ModelOperationKind;
const SessionFacts = configuration_domain.SessionFacts;
const accepted_resolutions = store_schema.accepted_resolutions;

pub const ModelAdmissionKind = enum { message, open_turn_message, tool_continuation };
const complete_tool_results_sql =
    store_schema.resolutionIs("current.resolution_code", .tool_proposals) ++ " AND EXISTS(" ++
    " SELECT 1 FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3" ++
    ") AND (SELECT count(*) FROM model_tool_call tool_call WHERE tool_call.operation_id=current.operation_id AND tool_call.session_ref=current.session_ref)=(" ++
    " SELECT count(*) FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3" ++
    ") AND NOT EXISTS(" ++
    " SELECT 1 FROM model_output_item item LEFT JOIN model_tool_call tool_call " ++
    " ON tool_call.operation_id=item.operation_id AND tool_call.session_ref=item.session_ref AND tool_call.item_ordinal=item.item_ordinal " ++
    " LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id " ++
    " AND action.session_ref=tool_call.session_ref AND action.call_ordinal=tool_call.call_ordinal" ++
    " WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3 " ++
    "AND tool_call.rejection_code IS NULL AND " ++ tool_fulfillment.actionPositionSql("action") ++ " IS NULL" ++
    ")";
const continues_with_input_sql =
    "(" ++ store_schema.oneOf("current.resolution_code", &turn_policy.continues_with_input) ++ " OR (" ++ complete_tool_results_sql ++ "))";
pub const continues_without_input_sql =
    "(" ++ store_schema.oneOf("current.resolution_code", &turn_policy.continues_without_input) ++ " OR (" ++ complete_tool_results_sql ++ "))";
fn queuedInputSql(comptime message: []const u8) []const u8 {
    return message ++ ".turn_id IS NULL AND NOT " ++ action_domain.stoppedSql(message ++ ".session_ref", message ++ ".admission_id<=source_stop.admission_cutoff");
}
const queued_input_sql = queuedInputSql("m");
const open_turn_takes_input_sql =
    "EXISTS(" ++
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id AND current.session_ref=active.session_ref " ++
    " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    " AND " ++ continues_with_input_sql ++
    ")";
const runnable_eligibility_sql =
    queued_input_sql ++ " AND (NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") OR " ++ open_turn_takes_input_sql ++ ")";
const Selection = struct {
    session: rsql.SessionHead,
    first_admission: rsql.Positive,
    cutoff: rsql.Positive,
    selected: u64,
    skills: u64,
    turn_id: ?rsql.Positive,
};

fn runnableCandidateSql(comptime eligibility: []const u8) []const u8 {
    return "SELECT m.session_ref FROM message_admission m @index(message_admission_pending) WHERE " ++
        "@served((SELECT provider FROM session WHERE session_ref=m.session_ref))" ++ " AND " ++ eligibility ++
        " ORDER BY m.admission_id LIMIT 1";
}

fn RunnableSelection(comptime eligibility: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH candidate AS (" ++ runnableCandidateSql(eligibility) ++ ") " ++
            "SELECT " ++ rsql.session_head_columns ++ ",min(m.admission_id) AS first_admission,max(m.admission_id) AS cutoff,count(*) AS selected," ++
            "coalesce(sum((SELECT count(*) FROM message_skill k WHERE k.admission_id=m.admission_id)),0) AS skills," ++
            "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
            "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
            "AND " ++ continues_with_input_sql ++ ") AS turn_id " ++
            "FROM candidate chosen JOIN message_admission m @index(message_admission_session_order) " ++
            "ON m.session_ref=chosen.session_ref JOIN session s ON s.session_ref=m.session_ref " ++
            "WHERE " ++ runnable_eligibility_sql ++
            " GROUP BY m.session_ref",
        .Args = struct {},
        .Row = Selection,
        .cardinality = .optional,
    });
}
const runnable_selection = RunnableSelection(runnable_eligibility_sql);
const open_turn_selection = RunnableSelection(queued_input_sql ++ " AND " ++ open_turn_takes_input_sql);
pub const runnable_selection_sql = runnable_selection.sql;

pub const tool_continuation_selection = rsql.Read(.{
    .sql = "SELECT " ++ rsql.session_head_columns ++ ",active.first_admission_id AS first_admission,active.input_cutoff AS cutoff,0 AS selected,0 AS skills,active.turn_id " ++
        "FROM turn active @index(turn_tool_continuation) JOIN session s ON s.session_ref=active.session_ref " ++
        "WHERE active.outcome_code IS NULL AND active.continuation_operation_id=active.operation_id AND " ++ "@served(s.provider)" ++
        " AND NOT " ++ action_domain.stoppedSql("active.session_ref", "source_stop.selected_turn_id=active.turn_id") ++
        " AND NOT EXISTS(SELECT 1 FROM message_admission m " ++
        "WHERE m.session_ref=active.session_ref AND " ++ queued_input_sql ++
        ") ORDER BY active.operation_id LIMIT 1",
    .Args = struct {},
    .Row = Selection,
    .cardinality = .optional,
});

pub const retry_allowance_open_sql = std.fmt.comptimePrint("attempt_ordinal<{d}", .{retry_policy.maximum_attempts});
pub const retry_exhausted_sql = std.fmt.comptimePrint("resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal={d}", .{retry_policy.maximum_attempts});
pub const retry_admission_page_rows = product_defaults.active_capacity + 1;
const retry_admission_select_text = std.fmt.comptimePrint(
    "SELECT o.turn_id,o.operation_id,o.attempt_ordinal,o.retry_due_at_ms," ++ rsql.session_head_columns ++ " " ++
        "FROM model_operation o @index(model_operation_retry_due) JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o.resolution_code IS NULL AND o." ++ retry_allowance_open_sql ++ " " ++
        "AND o.retry_due_at_ms<=?1 AND o.operation_id>?2 AND " ++ "@served(s.provider)" ++
        " ORDER BY o.operation_id LIMIT {d}",
    .{retry_admission_page_rows},
);
pub const DispatchPermit = attempt.DispatchPermit;

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
    request_started: bool = false,
};

const latest_turn = rsql.Read(.{
    .sql = "SELECT current.purpose,current.resolution_code,current.operation_id,latest.outcome_code IS NULL AS active,latest.first_admission_id,r.model " ++
        "FROM turn latest @index(turn_session_latest) LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "LEFT JOIN session_revision r ON r.session_ref=current.session_ref AND r.revision=current.settings_revision " ++
        "WHERE latest.session_ref=?1 ORDER BY latest.turn_id DESC LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        purpose: u1,
        resolution_code: ?Bounded(outcome_code.max_bytes),
        operation_id: rsql.Positive,
        active: bool,
        first_admission_id: rsql.Positive,
        model: Bounded(model_capability.max_model_bytes),
    },
    .cardinality = .optional,
});

const first_runnable = rsql.Read(.{
    .sql = "SELECT coalesce(min(m.admission_id),0) AS first FROM message_admission m WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { first: u64 },
    .cardinality = .one,
});

pub const compaction_failures = .{
    .{ latest_turn, error.CorruptStore },
    .{ first_runnable, error.CorruptStore },
    .{ admission_context, error.CorruptStore },
    .{ context_bytes, error.CorruptStore },
};

pub const CompactionRead = struct {
    session: []const u8,
    boundary: u64,
    provider: provider_name.Provider,
    model: []const u8,
    facts: turn_policy.CompactionFacts,
    stage: enum { latest, first, bytes, done } = .latest,
    latest: latest_turn.Result = undefined,
    first: first_runnable.Result = undefined,
    context: admission_context.Result = undefined,
    bytes_args: context_bytes.Args = undefined,
    bytes: context_bytes.Result = undefined,

    pub fn init(session: []const u8, boundary: u64, provider: provider_name.Provider, model: []const u8, policy: model_capability.CompactionPolicy) CompactionRead {
        return .{ .session = session, .boundary = boundary, .provider = provider, .model = model, .facts = .{
            .trigger = policy.compaction_trigger,
            .context_changed = false,
            .usage_tokens = null,
            .uncovered_bytes = 0,
            .builtin_instruction_bytes = model_catalog.builtinInstructions(model).bytes().len,
            .output_reservation = policy.output_reservation,
        } };
    }

    pub fn queue(read: *CompactionRead, a: anytype) bool {
        switch (read.stage) {
            .latest => {
                a.read(latest_turn, .{ .session = read.session }, &read.latest);
                a.read(admission_context, .{ .session = read.session, .boundary = read.boundary, .provider = read.provider, .model = read.model }, &read.context);
            },
            .first => a.read(first_runnable, .{ .session = read.session }, &read.first),
            .bytes => a.read(context_bytes, read.bytes_args, &read.bytes),
            .done => return false,
        }
        return true;
    }

    pub fn advance(read: *CompactionRead) !void {
        read.stage = switch (read.stage) {
            .latest => stage: {
                const latest = read.latest orelse break :stage .done;
                if (asksNextInput(latest.purpose == 1, latest.active)) break :stage .first;
                break :stage try read.weigh(null);
            },
            .first => try read.weigh(read.first.first),
            .bytes => stage: {
                read.facts.uncovered_bytes = read.bytes.uncovered_bytes;
                break :stage .done;
            },
            .done => .done,
        };
    }

    fn weigh(read: *CompactionRead, next_first: ?u64) !@TypeOf(read.stage) {
        const latest = read.latest.?;
        const resolution: []const u8 = if (latest.resolution_code) |*code| code.slice() else "";
        read.facts.previous = previousTurn(latest.purpose == 1, resolution, latest.active, latest.first_admission_id.get(), next_first, output_format.OutputItemKind.compaction.replayableTo(latest.model.slice(), read.model, .selected_base));
        if (turn_policy.forcedPurpose(read.facts.previous, read.facts.trigger) != null) return .done;
        const context = if (read.context) |*row| row else return error.CorruptStore;
        read.bytes_args = try takeContext(&read.facts, context, read.model, read.session) orelse return .done;
        return .bytes;
    }
};

fn asksNextInput(compaction: bool, active: bool) bool {
    return compaction and !active;
}

fn previousTurn(compaction: bool, resolution: []const u8, active: bool, latest_first: u64, next_first: ?u64, same_model: bool) turn_policy.Previous {
    return .{
        .purpose = if (compaction and same_model) .compaction else .assistant_response,
        .context_overflow = same_model and turn_policy.Resolution.parse(resolution) == .context_overflow,
        .turn_active = active,
        .same_input_prefix = same_model and asksNextInput(compaction, active) and next_first.? == latest_first,
    };
}

fn currentRecipe(context: anytype, model: []const u8) error{CorruptStore}!replay_recipe.Recipe {
    return replay_recipe.Recipe.select(model, if (context.base_position) |position| .{
        .position = position.get(),
        .floor = if (context.base_floor) |floor| floor.get() else 0,
        .model = (context.base_model orelse return error.CorruptStore).slice(),
    } else null, 0);
}

fn takeContext(compaction: *turn_policy.CompactionFacts, context: anytype, model: []const u8, session: []const u8) !?context_bytes.Args {
    const recipe = try currentRecipe(context, model);
    compaction.context_changed = recipe.frontier == 0 or context.changed;
    if (!compaction.context_changed) return null;
    var coverage: context_bytes.Args = .{ .session = session, .covered = 0, .frontier = recipe.frontier, .results = recipe.frontier };
    if (context.uncached) |uncached| {
        const measured = replay_recipe.Recipe.select(model, if (context.usage_base_position) |position| .{
            .position = position.get(),
            .floor = if (context.usage_base_floor) |floor| floor.get() else 0,
            .model = (context.usage_base_model orelse return error.CorruptStore).slice(),
        } else null, if (context.usage_floor) |floor| floor.get() else 0);
        const counts: output_format.Usage = .{
            .uncached = uncached,
            .cache_read = context.cache_read orelse return error.CorruptStore,
            .cache_write = context.cache_write orelse return error.CorruptStore,
            .output = context.output orelse return error.CorruptStore,
        };
        const position = context.usage_position orelse return error.CorruptStore;
        const admission = context.result_admission orelse return error.CorruptStore;
        if (recipe.measuredBy(measured)) {
            compaction.usage_tokens = counts.pressure();
            coverage.covered = position.get();
            coverage.results = admission.get();
        }
    }
    return coverage;
}

fn latestUsageSql(comptime session: []const u8, comptime provider: []const u8, comptime model: []const u8) []const u8 {
    return "SELECT o.history_floor AS usage_floor,o.usage_uncached_tokens AS uncached,o.usage_cache_read_tokens AS cache_read,o.usage_cache_write_tokens AS cache_write," ++
        "o.usage_output_tokens AS output,coalesce((SELECT max(i.session_position) FROM model_output_item i WHERE i.operation_id=o.operation_id),o.admission_position) AS usage_position," ++
        "o.admission_position AS result_admission " ++
        "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=" ++ session ++ " AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " " ++
        "AND r.provider=" ++ provider ++ " AND r.model=" ++ model ++ " ORDER BY o.admission_position DESC LIMIT 1";
}

fn uncoveredBytesSql(comptime session: []const u8, comptime usage_position: []const u8, comptime frontier: []const u8, comptime result_admission: []const u8) []const u8 {
    const later = "max(" ++ usage_position ++ "," ++ frontier ++ ")";
    const terms = .{
        "(SELECT coalesce(sum(c.byte_length),0) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
            "WHERE e.session_ref=" ++ session ++ " AND e.entry_kind IN (1,2,4) AND e.session_position>" ++ usage_position ++ ")",
        "(SELECT coalesce(sum(" ++ history_floor_domain.item_bytes_sql ++ "),0) FROM model_output_item i " ++
            "WHERE i.session_ref=" ++ session ++ " AND i.session_position>=max(" ++ usage_position ++ "+1,coalesce((SELECT max(anchor.session_position) " ++
            "FROM model_operation b @index(model_operation_compaction_bases) JOIN model_output_item anchor ON anchor.operation_id=b.operation_id AND anchor.session_ref=b.session_ref " ++
            "WHERE b.session_ref=" ++ session ++ " AND b.purpose=1 AND " ++ store_schema.resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=" ++ frontier ++ " AND anchor.item_kind=4),0)))",
        "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o @index(model_operation_context_history) " ++
            "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=o.operation_id AND tool_call.session_ref=o.session_ref " ++
            "JOIN content c ON c.content_id=tool_call.rejection_content_id WHERE o.session_ref=" ++ session ++ " AND o.admission_position>=" ++ result_admission ++ " " ++
            "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " AND tool_call.acceptance_position>" ++ later ++ ")",
        "((SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.background_content_id " ++
            "WHERE a.session_ref=" ++ session ++ " AND a.background_position>" ++ later ++ ") + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id " ++
            "WHERE a.session_ref=" ++ session ++ " AND a.background_position IS NULL AND a.acceptance_position>" ++ later ++ "))",
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN content c ON c.content_id=m.content_id " ++
            "WHERE m.session_ref=" ++ session ++ " AND " ++ runnable_eligibility_sql ++ ")",
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN message_skill k ON k.admission_id=m.admission_id " ++
            "JOIN content c ON c.content_id=k.content_id WHERE m.session_ref=" ++ session ++ " AND " ++ runnable_eligibility_sql ++ ")",
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
            "WHERE r.session_ref=" ++ session ++ " AND r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),1) " ++
            "AND r.instructions_updated=1)",
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
            "WHERE r.session_ref=" ++ session ++ " AND r.revision=1 AND " ++ usage_position ++ "=0)",
    };
    return "((" ++ terms[0] ++ " + " ++ terms[1] ++ ") + (" ++ terms[2] ++ " + " ++ terms[3] ++ ")) + ((" ++ terms[4] ++ " + " ++ terms[5] ++ ") + (" ++ terms[6] ++ " + " ++ terms[7] ++ "))";
}

fn baseCteSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "base AS (SELECT candidate.operation_id,candidate.admission_position,candidate.history_floor,candidate.session_ref,candidate.settings_revision FROM context_session context JOIN model_operation candidate ON candidate.operation_id=" ++
        historical_domain.newestBaseSql(session, boundary) ++ ")";
}

fn changedSinceBaseSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "NOT EXISTS(SELECT 1 FROM base " ++
        "WHERE NOT EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=" ++ session ++ " " ++
        "AND e.entry_kind IN (1,2,4) AND e.session_position>base.admission_position AND e.session_position<" ++ boundary ++ ") " ++
        "AND NOT EXISTS(SELECT 1 FROM model_output_item item @index(model_output_history) " ++
        "CROSS JOIN model_operation suffix ON suffix.operation_id=item.operation_id " ++
        "WHERE item.session_ref=" ++ session ++ " AND suffix.session_ref=" ++ session ++ " AND suffix.purpose=0 " ++
        "AND item.session_position>base.admission_position AND item.session_position<" ++ boundary ++ "))";
}

const base_columns_sql = "base.admission_position AS base_position," ++
    "base.history_floor AS base_floor,base_revision.model AS base_model";
const base_revision_join_sql = " LEFT JOIN session_revision base_revision ON base_revision.session_ref=base.session_ref AND base_revision.revision=base.settings_revision ";

pub const context_changed = rsql.Read(.{
    .sql = "WITH context_session AS (SELECT ?1 AS session_ref,?2 AS boundary)," ++ baseCteSql("context.session_ref", "context.boundary") ++ ",since AS (SELECT " ++ changedSinceBaseSql("context.session_ref", "context.boundary") ++ " AS changed FROM context_session context) SELECT since.changed," ++ base_columns_sql ++
        ",(SELECT r.model FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=?1 AND o.admission_position=?2) AS model FROM since LEFT JOIN base ON 1" ++ base_revision_join_sql,
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct {
        changed: bool,
        base_position: ?rsql.Positive,
        base_floor: ?rsql.Positive,
        base_model: ?Bounded(model_capability.max_model_bytes),
        model: Bounded(model_capability.max_model_bytes),
    },
    .cardinality = .one,
});

pub fn contextChanged(context: *const context_changed.Row) error{CorruptStore}!bool {
    return (try currentRecipe(context, context.model.slice())).frontier == 0 or context.changed;
}

const disagreeing_continuation = rsql.Read(.{
    .sql = "SELECT 1 AS disagrees FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
        "WHERE active.outcome_code IS NULL AND @same(active.continuation_operation_id,active.operation_id)<>" ++
        "(CASE WHEN " ++ continues_without_input_sql ++ " THEN 1 ELSE 0 END) LIMIT 1",
    .Args = struct {},
    .Row = struct { disagrees: u64 },
    .cardinality = .optional,
});

fn appliedFrontierSql(comptime session: []const u8) []const u8 {
    return "coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),1)";
}

fn lastOrdinalSql(comptime session: []const u8) []const u8 {
    return "coalesce((SELECT max(e.entry_ordinal) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),0)";
}

fn pendingInstructionsSql(comptime session: []const u8, comptime revision: []const u8) []const u8 {
    return "r.session_ref=" ++ session ++ " AND r.revision>" ++ appliedFrontierSql(session) ++ " AND r.revision<=" ++ revision ++ " AND r.instructions_updated=1";
}

fn factsColumnsSql(comptime session: []const u8) []const u8 {
    return "s.revision,s.provider,s.model,s.compaction_trigger,s.output_reservation," ++ configuration_domain.reasoningEffortOverrideSql("s") ++ " AS reasoning_effort," ++
        configuration_domain.previousReasoningEffortSql("s") ++ " AS previous_reasoning_effort," ++
        "s.tool_set_id,s.loaded_tool_set_id," ++ tool_offer.stale_sql ++ " AS offer_stale," ++
        "latest.turn_id AS latest_turn,latest.outcome_code IS NULL AS latest_active,latest.first_admission_id AS latest_first," ++
        "current.operation_id AS latest_operation,current.purpose AS latest_compaction,current.resolution_code AS latest_resolution,latest_revision.model AS latest_model," ++
        "(SELECT count(*) FROM session_revision r WHERE " ++ pendingInstructionsSql(session, "s.revision") ++ ") AS instructions";
}

fn factsJoinsSql(comptime session: []const u8) []const u8 {
    return " LEFT JOIN turn latest ON latest.turn_id=(SELECT t.turn_id FROM turn t @index(turn_session_latest) " ++
        "WHERE t.session_ref=" ++ session ++ " ORDER BY t.turn_id DESC LIMIT 1) " ++
        "LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "LEFT JOIN session_revision latest_revision ON latest_revision.session_ref=current.session_ref AND latest_revision.revision=current.settings_revision";
}

fn contextCtesSql(comptime scope: []const u8) []const u8 {
    const session = "context.session_ref";
    const boundary = "context.boundary";
    return "context_session AS (" ++ scope ++ ")," ++ baseCteSql(session, boundary) ++ ",since AS (SELECT " ++ changedSinceBaseSql(session, boundary) ++ " AS changed FROM context_session context),latest_usage AS (" ++ latestUsageSql("(SELECT session_ref FROM context_session)", "(SELECT provider FROM context_session)", "(SELECT model FROM context_session)") ++ ")," ++
        "measured AS (SELECT since.changed," ++ base_columns_sql ++
        ",saved.uncached,saved.cache_read,saved.cache_write,saved.output,saved.usage_position,saved.result_admission,saved.usage_floor," ++
        "usage_base.admission_position AS usage_base_position," ++
        "usage_base.history_floor AS usage_base_floor,usage_revision.model AS usage_base_model " ++
        "FROM context_session context CROSS JOIN since LEFT JOIN base ON 1" ++ base_revision_join_sql ++
        "LEFT JOIN latest_usage saved ON 1 LEFT JOIN model_operation usage_base ON usage_base.operation_id=" ++
        historical_domain.newestBaseSql(session, "saved.result_admission") ++
        " LEFT JOIN session_revision usage_revision ON usage_revision.session_ref=usage_base.session_ref AND usage_revision.revision=usage_base.settings_revision)";
}

const context_columns_sql = "measured.changed,measured.base_position,measured.base_floor,measured.base_model," ++
    "measured.uncached,measured.cache_read,measured.cache_write,measured.output,measured.usage_position,measured.result_admission," ++
    "measured.usage_floor,measured.usage_base_position,measured.usage_base_floor,measured.usage_base_model";

const ContextRow = struct {
    model: ?Bounded(model_capability.max_model_bytes),
    changed: bool,
    base_position: ?rsql.Positive,
    base_floor: ?rsql.Positive,
    base_model: ?Bounded(model_capability.max_model_bytes),
    uncached: ?u64,
    cache_read: ?u64,
    cache_write: ?u64,
    output: ?u64,
    usage_position: ?rsql.Positive,
    result_admission: ?rsql.Positive,
    usage_floor: ?rsql.Positive,
    usage_base_position: ?rsql.Positive,
    usage_base_floor: ?rsql.Positive,
    usage_base_model: ?Bounded(model_capability.max_model_bytes),
};

const admission_context = rsql.Read(.{
    .sql = "WITH " ++ contextCtesSql("SELECT ?1 AS session_ref,?2 AS boundary,?3 AS provider,?4 AS model WHERE EXISTS(SELECT 1 FROM turn latest @index(turn_session_latest) WHERE latest.session_ref=?1)") ++ " SELECT ?4 AS model," ++ context_columns_sql ++ " FROM measured",
    .Args = struct { session: []const u8, boundary: u64, provider: provider_name.Provider, model: []const u8 },
    .Row = ContextRow,
    .cardinality = .optional,
});

const SelectedRow = struct {
    session: rsql.SessionHead,
    revision: rsql.Positive,
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes),
    compaction_trigger: ?rsql.Positive,
    output_reservation: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    previous_reasoning_effort: ?model_capability.ReasoningEffort,
    tool_set_id: rsql.Positive,
    loaded_tool_set_id: ?rsql.Positive,
    offer_stale: bool,
    latest_turn: ?rsql.Positive,
    latest_active: bool,
    latest_first: ?rsql.Positive,
    latest_operation: ?rsql.Positive,
    latest_compaction: ?bool,
    latest_resolution: ?Bounded(outcome_code.max_bytes),
    latest_model: ?Bounded(model_capability.max_model_bytes),
    instructions: u64,
    changed: bool,
    base_position: ?rsql.Positive,
    base_floor: ?rsql.Positive,
    base_model: ?Bounded(model_capability.max_model_bytes),
    uncached: ?u64,
    cache_read: ?u64,
    cache_write: ?u64,
    output: ?u64,
    usage_position: ?rsql.Positive,
    result_admission: ?rsql.Positive,
    usage_floor: ?rsql.Positive,
    usage_base_position: ?rsql.Positive,
    usage_base_floor: ?rsql.Positive,
    usage_base_model: ?Bounded(model_capability.max_model_bytes),
};

fn SelectedContext(comptime candidate_sql: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH admission_selection AS (" ++ candidate_sql ++ ")," ++
            contextCtesSql("SELECT s.session_ref,s.next_position AS boundary,s.provider,s.model FROM session s JOIN admission_selection chosen ON chosen.session_ref=s.session_ref") ++
            " SELECT " ++ rsql.session_head_columns ++ "," ++ factsColumnsSql("context.session_ref") ++ "," ++ context_columns_sql ++
            " FROM context_session context CROSS JOIN measured JOIN session s ON s.session_ref=context.session_ref" ++ factsJoinsSql("context.session_ref"),
        .Args = struct {},
        .Row = SelectedRow,
        .cardinality = .optional,
    });
}
const selected_context = SelectedContext(runnableCandidateSql(runnable_eligibility_sql));
pub const selected_context_sql = selected_context.sql;
const open_turn_context = SelectedContext(runnableCandidateSql(queued_input_sql ++ " AND " ++ open_turn_takes_input_sql));
const tool_continuation_context = SelectedContext(tool_continuation_selection.made_from.sql);

const context_bytes = rsql.Read(.{
    .sql = "SELECT " ++ uncoveredBytesSql("?1", "?2", "?3", "?4") ++ " AS uncovered_bytes",
    .Args = struct { session: []const u8, covered: u64, frontier: u64, results: u64 },
    .Row = struct { uncovered_bytes: u64 },
    .cardinality = .one,
});

pub const Pressure = enum { weighed, over };

const within_pressure = rsql.Write(.{
    .sql = "UPDATE session SET next_position=next_position WHERE session_ref=@session(?1) AND " ++
        uncoveredBytesSql("session.session_ref", "?2", "?3", "?4") ++ "<?5",
    .Args = struct { session: rsql.SessionHead, covered: u64, frontier: u64, results: u64, limit: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CompactionDue } },
});

pub const within_pressure_sql = within_pressure.sql;

const insert_turn = rsql.Write(.{
    .sql = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,NULL,NULL)",
    .Args = struct { turn_id: u64, session: rsql.SessionHead, first_admission: u64, cutoff: u64, operation_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const continue_turn = rsql.Write(.{
    .sql = "UPDATE turn SET input_cutoff=?2,operation_id=?3 WHERE turn_id=?1 AND session_ref=@session(?4) AND outcome_code IS NULL",
    .Args = struct { turn_id: u64, cutoff: u64, operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SelectionChanged } },
});

const bind_messages = rsql.Write(.{
    .sql = "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND admission_id<=?3 AND " ++ queuedInputSql("message_admission"),
    .Args = struct { turn_id: u64, session: rsql.SessionHead, cutoff: u64 },
    .expect = .{ .counted = .{ .otherwise = error.SelectionChanged } },
});

const entry_columns = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id," ++
    "source_revision,source_operation_id,content_id,recorded_at) ";

fn selectedBeforeSql(comptime ahead: []const u8) []const u8 {
    return "prior.session_ref=" ++ ahead ++ ".session_ref AND prior.turn_id=?2 AND prior.admission_id>=?4 AND prior.admission_id<" ++ ahead ++ ".admission_id";
}

const project_messages = rsql.Write(.{
    .sql = entry_columns ++ "SELECT m.session_ref," ++ lastOrdinalSql("@session(?1)") ++ "+row_number() OVER (ORDER BY m.admission_id)+" ++ prior_skills_sql ++ "," ++
        "?3+row_number() OVER (ORDER BY m.admission_id)-1+" ++ prior_skills_sql ++ ",1,?2,m.admission_id,NULL,NULL,m.content_id,@now " ++
        "FROM message_admission m WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?4 ORDER BY m.admission_id",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, position_base: u64, first_admission: u64 },
    .expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } },
});
const prior_skills_sql = "(SELECT count(*) FROM message_admission prior JOIN message_skill k ON k.admission_id=prior.admission_id WHERE " ++ selectedBeforeSql("m") ++ ")";

const project_skills = rsql.Write(.{
    .sql = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_skill_admission_id,source_skill_position,content_id,recorded_at) " ++
        "SELECT owner.session_ref,owner.entry_ordinal+k.position,owner.session_position+k.position,4,?2,k.admission_id,k.position,k.content_id,@now " ++
        "FROM message_admission m JOIN conversation_entry owner ON owner.session_ref=m.session_ref AND owner.source_admission_id=m.admission_id JOIN message_skill k ON k.admission_id=m.admission_id " ++
        "WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?3 ORDER BY m.admission_id,k.position",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, first_admission: u64 },
    .expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } },
});

const project_instructions = rsql.Write(.{
    .sql = entry_columns ++ "SELECT r.session_ref," ++ lastOrdinalSql("@session(?1)") ++ "+row_number() OVER (ORDER BY r.revision)," ++
        "?3+row_number() OVER (ORDER BY r.revision)-1,2,?2,NULL,r.revision,NULL,r.instructions_content_id,@now " ++
        "FROM session_revision r WHERE " ++ pendingInstructionsSql("@session(?1)", "?4") ++ " ORDER BY r.revision",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, position_base: u64, revision: u64 },
    .expect = .{ .counted = .{ .otherwise = error.InstructionSelectionFailed } },
});

const insert_operation = rsql.Write(.{
    .sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
        "admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,history_floor,history_level,history_dropped,attempt_ordinal,retry_due_at_ms,attempt_at,tool_set_id,context_window,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override) " ++
        "SELECT ?1,?2,selected_revision.session_ref,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,1,0,@now,?17," ++
        model_facts_domain.contextWindowSql("?14", "?15", "?16") ++ "," ++
        configuration_domain.effortChoiceRevisionSql("selected_revision") ++ "," ++ operation_effort.previousSql("selected_revision.session_ref", "?6", "selected_revision.model") ++ "," ++
        "selected_session.codec='openai-responses/2' AND ?10 IS NOT NULL AND NOT @same(?10," ++ historical_domain.effortBeforeSql("selected_revision.session_ref", "?6", "selected_revision.model", "?11", "?10") ++ ")," ++ operation_effort.previousOverrideSql("selected_revision.session_ref", "?6", "selected_revision.model") ++ " " ++
        "FROM session_revision selected_revision JOIN session selected_session ON selected_session.session_ref=selected_revision.session_ref WHERE selected_revision.session_ref=@session(?3) AND selected_revision.revision=?4",
    .Args = struct {
        operation_id: u64,
        turn_id: u64,
        session: rsql.SessionHead,
        revision: u64,
        cutoff: u64,
        position: u64,
        compaction: bool,
        compaction_trigger: ?u64,
        output_reservation: u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        history_floor: ?u64,
        history_level: ?u8,
        history_dropped: ?u64,
        model: []const u8,
        shipped_context_window: u64,
        unlisted_context_window: u64,
        tool_set_id: u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

fn queueSelection(reader: anytype, kind: ModelAdmissionKind, found: *runnable_selection.Result) void {
    switch (kind) {
        .message => reader.read(runnable_selection, .{}, found),
        .open_turn_message => reader.read(open_turn_selection, .{}, found),
        .tool_continuation => reader.read(tool_continuation_selection, .{}, found),
    }
}

fn queueSelectedContext(reader: anytype, kind: ModelAdmissionKind, row: *SelectedRow, found: *store_access.Found) void {
    switch (kind) {
        .message => reader.readInto(selected_context, .{}, row, found),
        .open_turn_message => reader.readInto(open_turn_context, .{}, row, found),
        .tool_continuation => reader.readInto(tool_continuation_context, .{}, row, found),
    }
}

const IdleChecks = struct {
    disagreeing: disagreeing_continuation.Result = undefined,
    blocked: reads_domain.First(blocked_operation.Row) = .{},

    fn queue(checks: *IdleChecks, reader: anytype) void {
        reader.read(disagreeing_continuation, .{}, &checks.disagreeing);
        reader.readEach(blocked_operation, .{}, 1, &checks.blocked);
    }

    fn settled(checks: *const IdleChecks) error{CorruptStore}!bool {
        if (checks.disagreeing != null) return error.CorruptStore;
        return checks.blocked.row == null;
    }
};

pub const CheckIdle = struct {
    pub const rounds = transition.rounds(.{
        .idle = .{ .always, error.TurnReadFailed, .{.{ blocked_operation, error.CallReadFailed }} },
        .blocked_calls = .{ .branch, error.CallReadFailed },
    });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .none;
    pub const begin: ?rounds.At = null;
    pub const Input = struct {};
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.none;

    input: Input = .{},
    checks: IdleChecks = .{},
    outcomes: reads_domain.ToolOutcomeCheck = .{},

    pub fn step(t: *CheckIdle, r: *transition.Round(CheckIdle), ran: ?rounds.At) !transition.Next(CheckIdle) {
        const at = ran orelse {
            t.checks.queue(r);
            return .{ .round = .idle };
        };
        switch (at) {
            .idle => {
                if (try t.checks.settled()) return .{ .done = {} };
                queueBlockedToolCalls(r, &t.outcomes);
                return .{ .round = .blocked_calls };
            },
            .blocked_calls => {
                try t.outcomes.finish();
                return .{ .done = {} };
            },
        }
    }
};

pub const AdmitModel = struct {
    pub const rounds = transition.rounds(.{
        .select = .{ .always, error.RunnableSelectionFailed, .{
            .{ selected_context, error.SessionReadFailed },
            .{ open_turn_context, error.SessionReadFailed },
            .{ tool_continuation_context, error.SessionReadFailed },
        } },
        .floor_facts = .{ .branch, error.CorruptStore },
        .floor_page = .{ .paged, error.CorruptStore },
        .dropped = .{ .branch, error.CorruptStore },
        .inherited = .{ .branch, error.CorruptStore },
        .offer_project = .{.branch},
        .offer_lookup = .{.branch},
        .offer_intern = .{.branch},
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .floor_facts;
    pub const Input = struct {
        kind: ModelAdmissionKind,
        pressure: Pressure,
        faults: Faults,
        start: ?Starting,
        scratch: *Scratch,
    };
    pub const Result = ?AttemptAdmission;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ SelectionChanged, ProjectionFailed, InstructionSelectionFailed, CompactionDue };
    pub const Declined = error{};

    pub const Starting = struct { start: historical_domain.Start, selector: *const @FieldType(Store, "selector") };

    pub const Scratch = struct {
        model: @FieldType(SelectedRow, "model"),
        request: historical_domain.SettingsRead,
        read: union(enum) {
            facts: SelectedRow,
            floor: history_floor_domain.FloorSearch,
            inherited: history_floor_domain.InheritedFloor,
            offer: tool_offer.Freeze,
        },
    };

    input: Input,
    found: runnable_selection.Result = undefined,
    facts_found: store_access.Found = undefined,
    admitting: Admitting = undefined,
    dropped: history_floor_domain.DroppedEntries = .{},
    room: ?history_floor_domain.Choice = null,
    floor: ?u64 = null,
    offer: u64 = 0,
    binding: AttemptBinding = undefined,
    opened: bool = false,

    const Admitting = struct {
        session: rsql.SessionHead,
        revision: u64,
        policy: model_capability.CompactionPolicy,
        reasoning_effort: ?model_capability.ReasoningEffort,
        shipped_context_window: u64,
        instructions: u64,
        tool_set_id: u64,
        loaded_tool_set_id: ?u64,
        offer_stale: bool,
        compaction: bool,
        weighed: ?within_pressure.Args,
    };

    pub fn step(t: *AdmitModel, r: *transition.Round(AdmitModel), ran: ?rounds.At) !transition.Next(AdmitModel) {
        const at = ran orelse {
            t.input.scratch.read = .{ .facts = undefined };
            queueSelection(r, t.input.kind, &t.found);
            queueSelectedContext(r, t.input.kind, &t.input.scratch.read.facts, &t.facts_found);
            return .{ .round = .select };
        };
        switch (at) {
            .select => return t.decide(r),
            .floor_facts, .floor_page => {
                const search = &t.input.scratch.read.floor;
                if (search.next(r)) return .{ .round = .floor_page };
                const room = search.room() orelse return error.CorruptStore;
                t.room = room.choice;
                t.floor = room.choice.floor;
                t.dropped.queue(r, search.operation, room);
                return .{ .round = .dropped };
            },
            .dropped => return t.freeze(r),
            .inherited => {
                t.floor = t.input.scratch.read.inherited.floor(t.input.scratch.model.slice());
                return t.freeze(r);
            },
            .offer_project => {
                try t.input.scratch.read.offer.intern(r);
                return .{ .round = .offer_lookup };
            },
            .offer_lookup => {
                const offer = &t.input.scratch.read.offer;
                t.offer = try offer.set(r);
                if (offer.interning.inserted) return .{ .round = .offer_intern };
                return t.queueAdmission(r);
            },
            .offer_intern => return t.queueAdmission(r),
        }
    }

    fn decide(t: *AdmitModel, r: *transition.Round(AdmitModel)) !transition.Next(AdmitModel) {
        const selection = &(t.found orelse return .{ .done = null });
        if (selection.cutoff.get() < selection.first_admission.get()) return error.CorruptStore;
        const session_ref: []const u8 = &selection.session.ref;
        const first_admission = selection.first_admission.get();
        if (!t.facts_found.get()) return error.CorruptStore;
        const facts = &t.input.scratch.read.facts;
        t.input.scratch.model = facts.model;
        if (facts.session.next_position != selection.session.next_position) return error.SelectionChanged;
        const policy = model_capability.compactionPolicy(facts.model.slice(), if (facts.compaction_trigger) |trigger| trigger.get() else null, facts.output_reservation);
        var compaction: turn_policy.CompactionFacts = .{
            .trigger = policy.compaction_trigger,
            .context_changed = false,
            .usage_tokens = null,
            .uncovered_bytes = 0,
            .builtin_instruction_bytes = model_catalog.builtinInstructions(facts.model.slice()).bytes().len,
            .output_reservation = policy.output_reservation,
        };
        if (facts.latest_turn != null) {
            if (facts.latest_operation == null) return error.CorruptStore;
            const latest_first = facts.latest_first orelse return error.CorruptStore;
            const resolution: []const u8 = if (facts.latest_resolution) |*code| code.slice() else "";
            compaction.previous = previousTurn(facts.latest_compaction orelse return error.CorruptStore, resolution, facts.latest_active, latest_first.get(), first_admission, output_format.OutputItemKind.compaction.replayableTo((facts.latest_model orelse return error.CorruptStore).slice(), facts.model.slice(), .selected_base));
        }
        var purpose = turn_policy.nextPurpose(compaction);
        var weighed: ?within_pressure.Args = null;
        if (try takeContext(&compaction, facts, facts.model.slice(), session_ref)) |coverage| {
            purpose = turn_policy.nextPurpose(compaction);
            if (purpose != .compaction) if (turn_policy.compactingBytes(compaction)) |limit| switch (t.input.pressure) {
                .over => purpose = .compaction,
                .weighed => weighed = .{
                    .session = facts.session,
                    .covered = coverage.covered,
                    .frontier = coverage.frontier,
                    .results = coverage.results,
                    .limit = @min(limit, std.math.maxInt(i64)),
                },
            };
        }
        const deepens = if (compaction.previous) |previous|
            purpose == .compaction and previous.purpose == .compaction and previous.context_overflow and previous.turn_active
        else
            false;
        const latest: u64 = if (deepens) (facts.latest_operation orelse return error.CorruptStore).get() else 0;
        t.admitting = .{
            .session = facts.session,
            .revision = facts.revision.get(),
            .policy = policy,
            .reasoning_effort = configuration_domain.effectiveReasoningEffort(facts),
            .shipped_context_window = model_capability.contextWindow(model_catalog.shipped, facts.model.slice()),
            .instructions = if (purpose == .compaction) 0 else facts.instructions,
            .tool_set_id = facts.tool_set_id.get(),
            .loaded_tool_set_id = if (facts.loaded_tool_set_id) |id| id.get() else null,
            .offer_stale = facts.offer_stale,
            .compaction = purpose == .compaction,
            .weighed = weighed,
        };
        if (deepens) {
            t.input.scratch.read = .{ .floor = .{ .operation = latest } };
            t.input.scratch.read.floor.start(r);
            return .{ .round = .floor_facts };
        }
        if (purpose == .compaction) {
            t.input.scratch.read = .{ .inherited = .{} };
            t.input.scratch.read.inherited.queue(r, session_ref, selection.session.next_position.get());
            return .{ .round = .inherited };
        }
        return t.freeze(r);
    }

    fn freeze(t: *AdmitModel, r: *transition.Round(AdmitModel)) !transition.Next(AdmitModel) {
        const admitting = &t.admitting;
        if (tool_offer.Freeze.unchanged(admitting.tool_set_id, admitting.loaded_tool_set_id, admitting.offer_stale)) |offer| {
            t.offer = offer;
            return t.queueAdmission(r);
        }
        t.input.scratch.read = .{ .offer = .{} };
        t.input.scratch.read.offer.project(r, admitting.tool_set_id, admitting.loaded_tool_set_id);
        return .{ .round = .offer_project };
    }

    fn queueAdmission(t: *AdmitModel, r: *transition.Round(AdmitModel)) !transition.Next(AdmitModel) {
        const selection = &t.found.?;
        const admitting = &t.admitting;
        const first_admission = selection.first_admission.get();
        const selected: u64 = if (admitting.compaction) 0 else selection.selected;
        if (admitting.weighed) |args| r.write(within_pressure, args);
        const turn_id = if (selection.turn_id) |existing| existing.get() else try r.identity(.turn_id);
        const operation_id = try r.identity(.operation_id);
        const cutoff = selection.cutoff.get();
        if (selection.turn_id == null) {
            r.write(insert_turn, .{ .turn_id = turn_id, .session = admitting.session, .first_admission = first_admission, .cutoff = cutoff, .operation_id = operation_id });
        } else {
            r.write(continue_turn, .{ .turn_id = turn_id, .cutoff = cutoff, .operation_id = operation_id, .session = admitting.session });
        }
        const positions = try r.positions(admitting.session);
        if (selected != 0) {
            const inputs = selected + selection.skills;
            r.writeCount(bind_messages, .{ .turn_id = turn_id, .session = admitting.session, .cutoff = cutoff }, selected);
            r.writeCount(project_messages, .{
                .session = admitting.session,
                .turn_id = turn_id,
                .position_base = try positions.take(inputs),
                .first_admission = first_admission,
            }, selected);
            if (selection.skills != 0) r.writeCount(project_skills, .{ .session = admitting.session, .turn_id = turn_id, .first_admission = first_admission }, selection.skills);
        }
        if (admitting.instructions != 0) {
            r.writeCount(project_instructions, .{
                .session = admitting.session,
                .turn_id = turn_id,
                .position_base = try positions.take(admitting.instructions),
                .revision = admitting.revision,
            }, admitting.instructions);
        }
        const position = try positions.take(1);
        r.write(insert_operation, .{
            .operation_id = operation_id,
            .turn_id = turn_id,
            .session = admitting.session,
            .revision = admitting.revision,
            .cutoff = cutoff,
            .position = position,
            .compaction = admitting.compaction,
            .compaction_trigger = admitting.policy.compaction_trigger,
            .output_reservation = admitting.policy.output_reservation,
            .reasoning_effort = admitting.reasoning_effort,
            .history_floor = t.floor,
            .history_level = if (t.room) |choice| choice.level else null,
            .history_dropped = if (t.room != null) t.dropped.dropped() else null,
            .model = t.input.scratch.model.slice(),
            .shipped_context_window = admitting.shipped_context_window,
            .unlisted_context_window = @import("../../product_defaults.zig").unlisted_context_window,
            .tool_set_id = t.offer,
        });
        if (t.input.faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        t.binding = .{ .turn_id = turn_id, .operation_id = operation_id, .attempt_ordinal = 1 };
        if (t.input.start) |starting| if (starting.start.open(t.binding)) {
            t.opened = true;
            const request = &t.input.scratch.request;
            request.* = .init(starting.start.view, starting.start.settings, starting.selector);
            request.readAhead(starting.start, &admitting.session.ref, position);
        };
        return .commit;
    }

    pub fn follow(t: *AdmitModel) ?*historical_domain.SettingsRead {
        return if (t.opened) &t.input.scratch.request else null;
    }

    pub fn committed(t: *const AdmitModel) Result {
        const started = t.opened and t.input.start.?.start.view.read != null;
        if (t.opened and !started) t.input.start.?.start.view.close();
        return .{ .permit = .{ .binding = t.binding }, .request_started = started };
    }

    pub fn failed(t: *AdmitModel) void {
        if (t.opened) t.input.start.?.start.view.close();
    }
};

pub const DispatchWork = struct {
    core: bool,
    mcp: bool,
    bash: bool,
    message: bool,
    tool_continuation: bool,
    retry: bool,

    pub const unknown: DispatchWork = .{ .core = true, .mcp = true, .bash = true, .message = true, .tool_continuation = true, .retry = true };
};

pub const DispatchSurvey = struct {
    actions: action_domain.WorkProbe = .{},
    message: runnable_selection.Result = undefined,
    continuation: runnable_selection.Result = undefined,
    idle: IdleChecks = .{},
    retry: retrying_attempt.Result = undefined,

    pub const named = .{.{ blocked_operation, error.CallReadFailed }};

    pub fn queue(survey: *DispatchSurvey, reader: anytype, paused: bool, capacity: action_domain.Capacity) void {
        survey.actions.queue(reader, capacity);
        queueSelection(reader, if (paused) .open_turn_message else .message, &survey.message);
        queueSelection(reader, .tool_continuation, &survey.continuation);
        survey.idle.queue(reader);
        reader.read(retrying_attempt, .{}, &survey.retry);
    }

    fn unsettled(survey: *const DispatchSurvey) error{CorruptStore}!bool {
        if (survey.message != null and survey.continuation != null) return false;
        return !try survey.idle.settled();
    }

    pub fn work(survey: *const DispatchSurvey) error{CorruptStore}!?DispatchWork {
        if (try survey.unsettled()) return null;
        return survey.found();
    }

    fn found(survey: *const DispatchSurvey) DispatchWork {
        return .{
            .core = survey.actions.core(),
            .mcp = survey.actions.mcp(),
            .bash = survey.actions.bash(),
            .message = survey.message != null,
            .tool_continuation = survey.continuation != null,
            .retry = survey.retry != null,
        };
    }
};

pub fn dispatchWork(reader: anytype, paused: bool, capacity: action_domain.Capacity) !DispatchWork {
    var survey: DispatchSurvey = .{};
    survey.queue(reader, paused, capacity);
    try store_access.runNamed(reader, DispatchSurvey.named, error.TurnReadFailed);
    if (try survey.unsettled()) try validateBlockedToolCalls(reader);
    return survey.found();
}

const retrying_attempt = rsql.Read(.{
    .sql = "SELECT 1 AS retrying FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
        "WHERE active.outcome_code IS NULL AND current.resolution_code IS NULL AND current.retry_due_at_ms IS NOT NULL LIMIT 1",
    .Args = struct {},
    .Row = struct { retrying: u64 },
    .cardinality = .optional,
});

const due_retries = rsql.Read(.{
    .sql = retry_admission_select_text,
    .Args = struct { now_ms: u64, after: u64 },
    .Row = struct { turn_id: rsql.Positive, operation_id: rsql.Positive, attempt_ordinal: rsql.Positive, retry_due_at_ms: u64, session: rsql.SessionHead },
    .cardinality = .each,
});

const next_scheduled_retry = rsql.Read(.{
    .sql = "SELECT o.retry_due_at_ms FROM model_operation o @index(model_operation_retry_due) JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o.resolution_code IS NULL AND o." ++ retry_allowance_open_sql ++ " " ++
        "AND o.retry_due_at_ms>?1 AND " ++ "@served(s.provider)" ++
        " ORDER BY o.retry_due_at_ms LIMIT 1",
    .Args = struct { now_ms: u64 },
    .Row = struct { retry_due_at_ms: u64 },
    .cardinality = .optional,
});

pub const retry_admission_select_sql = due_retries.sql;

const retry_attempt = rsql.Write(.{
    .sql = "UPDATE model_operation SET " ++ model_attempt.replacement_sql ++ ",attempt_ordinal=?2,retry_due_at_ms=0,attempt_at=@now,retry_scheduled_at=NULL " ++
        "WHERE operation_id=?1 AND session_ref=@session(?6) AND turn_id=?3 AND resolution_code IS NULL " ++
        "AND attempt_ordinal=?4 AND " ++ retry_allowance_open_sql ++ " AND retry_due_at_ms<=?5",
    .Args = struct { operation_id: u64, replacement: u64, turn_id: u64, attempt_ordinal: u64, now_ms: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.RetryNoLongerDue } },
});

const RetryChoice = struct {
    active: ActiveOperationFilter,
    now_ms: u64,
    scanned: u64 = 0,
    page_rows: u64 = 0,
    after: u64 = 0,
    chosen: ?due_retries.Row = null,
    corrupt: bool = false,

    pub fn visit(choice: *RetryChoice, row: *const due_retries.Row) bool {
        if (row.attempt_ordinal.get() >= retry_policy.maximum_attempts or row.retry_due_at_ms > choice.now_ms) {
            choice.corrupt = true;
            return false;
        }
        choice.scanned += 1;
        choice.page_rows += 1;
        choice.after = row.operation_id.get();
        if (choice.active.contains(row.operation_id.get())) return true;
        choice.chosen = row.*;
        return false;
    }
};

pub const AdmitRetry = struct {
    pub const rounds = transition.rounds(.{
        .first_page = .{ .always, error.RetrySelectionFailed },
        .next_page = .{ .paged, error.RetrySelectionFailed },
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { io: std.Io, active: ActiveOperationFilter, scheduled: ?*?u64 };
    pub const Result = ?AttemptAdmission;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Declined = error{RetryNoLongerDue};
    pub const Guards = Declined;

    input: Input,
    limit: u64 = 0,
    choice: RetryChoice = undefined,
    next_scheduled: next_scheduled_retry.Result = null,

    pub fn step(t: *AdmitRetry, r: *transition.Round(AdmitRetry), ran: ?rounds.At) !transition.Next(AdmitRetry) {
        const page = ran orelse {
            const now_ms = std.math.cast(u64, try store_core.readUnixMilliseconds(t.input.io)) orelse return error.IntegerOutOfRange;
            t.limit = try std.math.add(u64, t.input.active.maximum_exclusions, 1);
            t.choice = .{ .active = t.input.active, .now_ms = now_ms };
            t.queuePage(r);
            if (t.input.scheduled != null) r.read(next_scheduled_retry, .{ .now_ms = now_ms }, &t.next_scheduled);
            return .{ .round = .first_page };
        };
        if (page == .first_page) if (t.input.scheduled) |out| {
            out.* = if (t.next_scheduled) |row| row.retry_due_at_ms else null;
        };
        if (t.choice.corrupt) return error.CorruptStore;
        if (t.choice.chosen == null and t.choice.scanned < t.limit and t.choice.page_rows >= retry_admission_page_rows) {
            t.queuePage(r);
            return .{ .round = .next_page };
        }
        const chosen = t.choice.chosen orelse return .{ .done = null };
        r.write(retry_attempt, .{
            .operation_id = chosen.operation_id.get(),
            .replacement = chosen.attempt_ordinal.get() + 1,
            .turn_id = chosen.turn_id.get(),
            .attempt_ordinal = chosen.attempt_ordinal.get(),
            .now_ms = t.choice.now_ms,
            .session = chosen.session,
        });
        if (r.faults().attempt_before_commit) return error.InjectedAttemptCommitFailure;
        return .commit;
    }

    fn queuePage(t: *AdmitRetry, r: *transition.Round(AdmitRetry)) void {
        t.choice.page_rows = 0;
        r.readEach(due_retries, .{ .now_ms = t.choice.now_ms, .after = t.choice.after }, t.limit - t.choice.scanned, &t.choice);
    }

    pub fn committed(t: *const AdmitRetry) Result {
        const chosen = t.choice.chosen.?;
        return .{ .permit = .{ .binding = .{
            .turn_id = chosen.turn_id.get(),
            .operation_id = chosen.operation_id.get(),
            .attempt_ordinal = chosen.attempt_ordinal.get() + 1,
        } } };
    }

    pub fn declined(_: *const AdmitRetry, _: Declined) Result {
        return null;
    }
};

const blocked_operations_sql = "FROM turn active JOIN model_operation operation ON operation.operation_id=active.operation_id " ++
    "WHERE active.outcome_code IS NULL AND " ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals);

const blocked_operation = rsql.Read(.{
    .sql = "SELECT operation.operation_id " ++ blocked_operations_sql,
    .Args = struct {},
    .Row = struct { operation_id: rsql.Positive },
    .cardinality = .each,
});

const blocked_tool_calls = reads_domain.ToolOutcome("", "SELECT DISTINCT operation.operation_id," ++
    reads_domain.expectedCallsSql("operation.operation_id") ++ " " ++ blocked_operations_sql, struct {}, false);

pub const idle_statements = .{ disagreeing_continuation, blocked_operation, blocked_tool_calls };

fn validateBlockedToolCalls(reader: anytype) !void {
    var check: reads_domain.ToolOutcomeCheck = .{};
    queueBlockedToolCalls(reader, &check);
    try store_access.runAs(reader, error.CallReadFailed);
    try check.finish();
}

fn queueBlockedToolCalls(reader: anytype, check: *reads_domain.ToolOutcomeCheck) void {
    reader.readEach(blocked_tool_calls, .{}, std.math.maxInt(u64), check);
}
