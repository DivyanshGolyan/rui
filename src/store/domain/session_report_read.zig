//! A Session report as the Store reads it: the saved Session and its
//! Current facts as plain values (`session_report.Current`), then each
//! Current list row by row (`session_report.Row`), handed to a visitor.
//! The Host writes the reply. The Full profile's history follows, as
//! plain values too (`report.readFull`).

const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const built_in_tool = @import("../../built_in_tool.zig");
const cli_value = @import("../../cli_value.zig");
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const model_capability = @import("../../model_capability.zig");
const outcome_code = @import("../../outcome_code.zig");
const session_report = @import("../../session_report.zig");
const tool_name = @import("../../tool_name.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const tool_defs = @import("../../tool_record.zig");
const turn_policy = @import("../../turn_policy.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const action_domain = @import("action.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const model_admission_domain = @import("model_admission.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const tool_set = @import("tool_set.zig");
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const ReadAccess = reads_domain.ReadAccess;
const FirstCandidates = report_domain.FirstCandidates;
const SessionCounts = report_domain.SessionCounts;
const WorkRead = report_domain.WorkRead;
const archive_state = report_domain.archive_state;
const Code = Bounded(outcome_code.max_bytes);

/// Remembers whether `visitor` failed. Its failure is its own, such as
/// exhausted scratch, which is ordinary and does not fence the Store.
pub fn Watched(comptime Visitor: type) type {
    return struct {
        visitor: Visitor,
        failed: bool = false,

        const Child = @typeInfo(Visitor).pointer.child;

        pub fn Result(comptime method: []const u8) type {
            return @typeInfo(@TypeOf(@field(Child, method))).@"fn".return_type.?;
        }

        pub fn call(w: *@This(), comptime method: []const u8, args: anytype) Result(method) {
            return @call(.auto, @field(Child, method), .{w.visitor} ++ args) catch |err| {
                w.failed = true;
                return err;
            };
        }
    };
}

/// Reads the report of `session_ref` on `a` and hands it to `watched`'s
/// visitor, whose methods each return an error union:
///
/// - `missing(profile)` once, for a Session that is not saved, and nothing
///   more;
/// - else `current(profile, *const session_report.Current)`, then, for
///   each `session_report.List` in order, `open(list)` and its rows,
///   `row(*const session_report.Row)`, as they step; then `end()`;
/// - for the Full profile, its history (`report.readFull`): `fullOpen`,
///   `fullRow` and `fullEnd`;
/// - then `tail()`.
///
/// All under one Entry, so one snapshot. A visitor's error stops the read
/// and is its answer.
pub fn readSessionReport(a: *ReadAccess, session_ref: []const u8, profile: cli_value.ReportProfile, watched: anytype) !void {
    if (!try readHead(a, session_ref, profile, watched)) return;
    if (profile == .full) try report_domain.readFull(a, session_ref, watched);
    try watched.call("tail", .{});
}

/// A report's head, whose rounds tests count: round 1 reads the saved
/// Session, and a missing one ends the report there; the Current facts
/// and lists follow (`readCurrent`). Not inlined: the saved Session lives
/// in its frame, which returns before any history content is read.
pub noinline fn readHead(a: *ReadAccess, session_ref: []const u8, profile: cli_value.ReportProfile, watched: anytype) !bool {
    var current: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    var found: store_access.Found = undefined;
    configuration_domain.readSaved(a, session_ref, &current, &found);
    try a.run();
    if (!found.get()) {
        try watched.call("missing", .{profile});
        return false;
    }
    try configuration_domain.checkSaved(&current);
    try readCurrent(a, session_ref, profile, &current, watched);
    return true;
}

/// The Message the active Turn started from: an active Turn owns the
/// selection even if a successor is queued.
const selected_active = rsql.Read(.{
    .sql = "SELECT m.command_key FROM turn t @index(turn_one_active_per_session) JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NULL",
    .Args = struct { session: []const u8 },
    .Row = SelectedRow,
    .cardinality = .each,
});

const SelectedRow = struct { command_key: Bounded(idempotency_key.max_bytes) };

/// Without an active Turn, the oldest Message queued after the latest
/// stop's cutoff ?2.
const selected_queued = rsql.Read(.{
    .sql = "SELECT command_key FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = SelectedRow,
    .cardinality = .each,
});

/// The ten newest Messages of terminal Turns. CROSS JOIN fixes the
/// indexed order, Turns newest first and then their admissions, so LIMIT
/// stops after ten Messages, even when older history or other Sessions
/// grow.
const recent_messages = rsql.Read(.{
    .sql = "SELECT t.turn_id,m.command_key,t.outcome_code FROM turn t @index(turn_session_latest) " ++
        "CROSS JOIN message_admission m @index(message_admission_session_order) " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NOT NULL AND m.session_ref=t.session_ref AND m.turn_id=t.turn_id " ++
        "ORDER BY t.turn_id DESC,m.admission_id DESC LIMIT 10",
    .Args = struct { session: []const u8 },
    .Row = struct { turn_id: rsql.Positive, command_key: Bounded(idempotency_key.max_bytes), outcome_code: Code },
    .cardinality = .each,
});

/// The active Turn's current Operation's unresolved Actions, with each
/// call's line for its presentation.
const unresolved_actions = rsql.Read(.{
    .sql = "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.permission_revision,a.authorized,revision.permission_mode,@payload(call_name) AS tool_name," ++
        "call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest,arguments.byte_length AS arguments_length,arguments.digest AS arguments_digest," ++
        "call_name.digest AS name_digest," ++ action_domain.mcpServerSql("a", "operation") ++ " AS server,tool_call.description FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN action_operation a ON a.parent_operation_id=active.operation_id " ++
        "CROSS JOIN model_operation operation ON operation.operation_id=a.parent_operation_id " ++
        "CROSS JOIN session_revision revision ON revision.session_ref=a.session_ref AND revision.revision=a.permission_revision " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
        "CROSS JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "CROSS JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "CROSS JOIN content call_name ON call_name.content_id=tool_call.name_content_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NULL ORDER BY a.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        permission_revision: rsql.Positive,
        authorized: bool,
        permission_mode: u1,
        tool_name: Bounded(tool_defs.max_name_bytes),
        call_id_length: u64,
        call_id_digest: [32]u8,
        arguments_length: u64,
        arguments_digest: [32]u8,
        name_digest: [32]u8,
        server: ?Bounded(64),
        description: ?Description,
    },
    .cardinality = .each,
});

const Description = Bounded(tool_presentation.max_description_bytes);

/// The CTE `publications`: each active Operation's tool group
/// publication, as main's outcome facts gave it, its largest acceptance
/// when every call has one and none otherwise. Grouped once per
/// Operation, so a list joins it per row without rescanning the
/// Operation's calls. The rule over `active_tool_calls` proved every
/// call of each listed Operation valid in an earlier round of this
/// Access, under the Entry that excludes every writer, so its Operation
/// has as many calls as call items. By the schema's CHECKs a call has an
/// acceptance exactly when it is rejected (`model_tool_call`'s) or its
/// Action resolved (`action_operation`'s), main's terminal calls, so this
/// counts what main counted.
const publications_sql = "WITH publications AS (SELECT operation.operation_id," ++
    "CASE WHEN count(*)=count(coalesce(sibling.acceptance_position,sibling_action.acceptance_position)) " ++
    "THEN max(coalesce(sibling.acceptance_position,sibling_action.acceptance_position)) END AS publication " ++
    "FROM turn active @index(turn_one_active_per_session) " ++
    "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
    "CROSS JOIN model_tool_call sibling ON sibling.operation_id=operation.operation_id " ++
    "LEFT JOIN action_operation sibling_action ON sibling_action.parent_operation_id=sibling.operation_id AND sibling_action.call_ordinal=sibling.call_ordinal " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL GROUP BY operation.operation_id) ";

/// The active Turn's resolved Actions, with each call's line and its
/// group's publication for its presentation. An Action's call is its
/// foreign key.
const resolved_actions = rsql.Read(.{
    .sql = publications_sql ++ "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.resolution_code,a.acceptance_position," ++
        "result.byte_length AS result_length,result.digest AS result_digest,tool_call.description,publications.publication " ++
        "FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN action_operation a ON a.parent_operation_id=operation.operation_id " ++
        "CROSS JOIN content result ON result.content_id=a.resolution_content_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
        "LEFT JOIN publications ON publications.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NOT NULL ORDER BY a.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        resolution_code: Bounded(32),
        acceptance_position: rsql.Positive,
        result_length: u64,
        result_digest: [32]u8,
        description: ?Description,
        publication: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// The active Turn's rejected calls, with each one's line and its group's
/// publication for its presentation.
const rejected_calls = rsql.Read(.{
    .sql = publications_sql ++ "SELECT tool_call.operation_id,tool_call.call_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
        "rejection.byte_length AS rejection_length,rejection.digest AS rejection_digest,name.byte_length AS name_length,name.digest AS name_digest," ++
        "call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest,arguments.byte_length AS arguments_length,arguments.digest AS arguments_digest," ++
        "tool_call.description,publications.publication " ++
        "FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "CROSS JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "CROSS JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "CROSS JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "CROSS JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
        "LEFT JOIN publications ON publications.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL " ++
        "ORDER BY tool_call.operation_id,tool_call.call_ordinal",
    .Args = struct { session: []const u8 },
    .Row = struct {
        operation_id: rsql.Positive,
        call_ordinal: u64,
        rejection_code: Bounded(32),
        acceptance_position: rsql.Positive,
        rejection_length: u64,
        rejection_digest: [32]u8,
        name_length: u64,
        name_digest: [32]u8,
        call_id_length: u64,
        call_id_digest: [32]u8,
        arguments_length: u64,
        arguments_digest: [32]u8,
        description: ?Description,
        publication: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// The active Turn's current Operation's Actions awaiting permission.
const actionable_permissions = rsql.Read(.{
    .sql = "SELECT action.action_id,action.permission_revision FROM turn active @index(turn_one_active_per_session) " ++
        "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL " ++
        "AND action.resolution_code IS NULL AND action.authorized=0 ORDER BY action.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct { action_id: rsql.Positive, permission_revision: rsql.Positive },
    .cardinality = .each,
});

/// The names main gave the Current report's failed steps; any other is
/// `CorruptStore`, main's answer for content metadata. A presentation's
/// reads, which main named apart, are its list's own columns now, so
/// they take its list's name.
pub const current_failures = .{
    .{ archive_state, error.SessionReadFailed },
    .{ selected_active, error.TurnReadFailed },
    .{ selected_queued, error.MessageAdmissionReadFailed },
    .{ recent_messages, error.TurnReadFailed },
    .{ unresolved_actions, error.ActionReadFailed },
    .{ resolved_actions, error.ActionReadFailed },
    .{ rejected_calls, error.CallReadFailed },
    .{ actionable_permissions, error.ActionReadFailed },
} ++ report_domain.session_count_failures ++ model_admission_domain.compaction_failures ++ report_domain.report_failures;

/// Ends a round of the Current report, naming a failed step by
/// `current_failures`.
fn runCurrent(a: *ReadAccess) !void {
    return store_access.runNamed(a, current_failures, error.CorruptStore);
}

/// What the Current report reads before its lists.
const CurrentFacts = struct {
    archive: archive_state.Result = null,
    instructions: content_domain.content_metadata.Row = undefined,
    output_schema: content_domain.content_metadata.Row = undefined,
    counts: SessionCounts,
    compaction: model_admission_domain.CompactionRead,
    work: WorkRead,
    person: report_domain.person_message.Result = null,
    first: FirstCandidates = .{},
    first_row: report_domain.first_message.Result = null,
    active: reads_domain.First(SelectedRow) = .{},
    queued: reads_domain.First(SelectedRow) = .{},
    outcome: content_domain.content_metadata.Row = undefined,
    /// In the Store's scratch (`Store.reportScratch`): over 4 KiB.
    tools: *ToolNames,
    tools_found: store_access.Found = undefined,
};

/// The saved and loaded tool sets' names (`set_names`) and each sorted
/// (`report.sortedToolNames`), which the Current values borrow.
const ToolNames = struct {
    row: set_names.Row,
    tools: [tool_defs.max_tools][]const u8,
    loaded: [tool_defs.max_tools][]const u8,
};

/// The names of the tool set ?1, joined (`tool_set.namesSql`).
const set_names = rsql.Read(.{
    .sql = "SELECT " ++ tool_set.namesSql("s.tool_set_id") ++ " AS names," ++ tool_set.namesSql("?2") ++ " AS loaded_names FROM tool_set s WHERE s.tool_set_id=?1",
    .Args = struct { set: u64, loaded: u64 },
    .Row = struct { names: ?Bounded(tool_set.max_names_bytes), loaded_names: ?Bounded(tool_set.max_names_bytes) },
    .cardinality = .optional,
});

/// The Current report after its saved Session, in the rounds its reads'
/// dependencies take. Round 2: the instructions' and output schema's
/// metadata, the counts' first round (`SessionCounts`), the latest Turn
/// for `context_estimate` (`CompactionRead`), the work's latest Turn, the
/// latest Message from no Session, both first-Message seeks and the
/// active Turn's Message. Round 3: the counts' second round, the queued Message
/// when no Turn is active, the work's second stage, the first Message's
/// row, the latest outcome's content metadata and the compaction facts'
/// next stage. The work's and compaction facts' later stages share the
/// rounds after it. The facts are checked, then visited; then each list,
/// in a round of its own; the active Turn's lists only when it counts an
/// Action or rejected call to list. Not inlined, so its reads take no slot
/// in the Full profile's frames.
noinline fn readCurrent(a: *ReadAccess, session_ref: []const u8, profile: cli_value.ReportProfile, current: *const CurrentConfiguration, watched: anytype) !void {
    const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
    var facts: CurrentFacts = .{
        .counts = .{ .session = session_ref },
        .compaction = .init(session_ref, current.next_position, current.provider, current.model.slice(), policy),
        .work = .{ .session = session_ref },
        .tools = a.store.reportScratch(ToolNames),
    };
    // `checkSaved` refused a missing or zero instructions id and a zero
    // output schema id. A negative id is `CorruptStore` without a read,
    // where main read it and found no row unless one had that id.
    const instructions_id = current.instructions_id.?;
    if (instructions_id < 0 or (current.output_schema_id orelse 1) < 0) return error.CorruptStore;
    const metadata = content_domain.content_metadata;
    a.read(metadata, .{ .content_id = @intCast(instructions_id) }, &facts.instructions);
    if (current.output_schema_id) |content_id| a.read(metadata, .{ .content_id = @intCast(content_id) }, &facts.output_schema);
    a.read(archive_state, .{ .session = session_ref }, &facts.archive);
    facts.counts.queue(a);
    _ = facts.compaction.queue(a);
    _ = facts.work.queue(a);
    a.read(report_domain.person_message, .{ .session = session_ref }, &facts.person);
    a.readInto(set_names, .{ .set = current.tool_set_id, .loaded = current.loaded_tool_set_id orelse current.tool_set_id }, &facts.tools.row, &facts.tools_found);
    facts.first.queue(a, session_ref);
    a.readEach(selected_active, .{ .session = session_ref }, 1, &facts.active);
    try runCurrent(a);
    try facts.compaction.advance();
    try facts.work.advance();

    facts.counts.queuePending(a);
    if (facts.active.row == null) a.readEach(selected_queued, .{ .session = session_ref, .cutoff = facts.counts.stopCutoff() }, 1, &facts.queued);
    const admission = facts.first.admission();
    if (admission != 0) a.read(report_domain.first_message, .{ .session = session_ref, .first = admission }, &facts.first_row);
    // The work's latest Turn is read, so its outcome is known.
    const outcome = facts.work.outcome();
    if (outcome) |found| if (found.content_id) |content_id| a.read(metadata, .{ .content_id = content_id }, &facts.outcome);
    var work_more = facts.work.queue(a);
    var compaction_more = facts.compaction.queue(a);
    while (true) {
        try runCurrent(a);
        if (work_more) try facts.work.advance();
        if (compaction_more) try facts.compaction.advance();
        work_more = facts.work.queue(a);
        compaction_more = facts.compaction.queue(a);
        if (!work_more and !compaction_more) break;
    }
    const counted = try facts.counts.judge();
    if (admission != 0 and facts.first_row == null) return error.CorruptStore;

    if (!facts.tools_found.get()) return error.CorruptStore;
    const names = facts.tools;
    const tools = try report_domain.sortedToolNames(if (names.row.names) |*joined| joined.slice() else null, &names.tools);
    const loaded_tools = try report_domain.sortedToolNames(if (names.row.loaded_names) |*joined| joined.slice() else null, &names.loaded);
    const permission_mode = try configuration_domain.permissionMode(current.permission_mode);
    const now_ms = std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange;
    const work = try facts.work.work(current.created_at, now_ms);
    const first_message = if (facts.first_row) |*found| try report_domain.firstMessage(found, admission) else null;
    const selected = if (facts.active.row) |*row| row else if (facts.queued.row) |*row| row else null;
    const values: session_report.Current = .{
        .reference = session_ref,
        .parent = if (current.parent_ref) |*parent| parent.slice() else null,
        .workspace = current.workspace.slice(),
        .provider = current.provider,
        .model = current.model.slice(),
        .compaction_trigger = policy.compaction_trigger,
        .context_estimate = if (turn_policy.comparedPressure(facts.compaction.facts)) |value| @min(value, std.math.maxInt(i64)) else null,
        .output_reservation = policy.output_reservation,
        .compaction_trigger_override = current.compaction_trigger,
        .output_reservation_override = current.output_reservation,
        .reasoning_effort = configuration_domain.effectiveReasoningEffort(current),
        .reasoning_effort_override = current.reasoning_effort,
        .revision = current.revision,
        .tools = tools,
        .loaded_tools = loaded_tools,
        .permission_mode = permission_mode,
        .instructions = .{ .length = facts.instructions.byte_length, .digest = facts.instructions.digest },
        .output_schema = if (current.output_schema_id != null) .{ .length = facts.output_schema.byte_length, .digest = facts.output_schema.digest } else null,
        .label = if (current.label) |*label| label.slice() else null,
        .created_at = current.created_at,
        .archive_state = if (facts.archive) |row| row.archive_state else .active,
        .pending_messages = counted.pending,
        .work = work,
        .latest_outcome = if (outcome) |found| .{
            .code = found.code,
            .content = if (found.content_id != null) .{ .length = facts.outcome.byte_length, .digest = facts.outcome.digest } else null,
        } else null,
        .peers = .{ .from_person_at = if (facts.person) |found| found.admitted_at.get() else null },
        .first_message = first_message,
        .selected_message = if (selected) |row| row.command_key.slice() else null,
        .actions = counted.actions,
        .rejected_calls = counted.rejected,
    };
    try watched.call("current", .{ profile, &values });
    const all = std.math.maxInt(u64);
    try readList(a, .recent_messages, recent_messages, .{ .session = session_ref }, 10, true, recentRow, watched);
    try readList(a, .unresolved_actions, unresolved_actions, .{ .session = session_ref }, all, counted.actions != 0, unresolvedRow, watched);
    try readList(a, .resolved_actions, resolved_actions, .{ .session = session_ref }, all, counted.actions != 0, resolvedRow, watched);
    try readList(a, .rejected_calls, rejected_calls, .{ .session = session_ref }, all, counted.rejected != 0, rejectedRow, watched);
    try readList(a, .actionable_permissions, actionable_permissions, .{ .session = session_ref }, all, counted.actions != 0, actionableRow, watched);
    try watched.call("end", .{});
}

/// One list of the Current report: opened, then, when `read`, its rows in
/// a round of their own, each checked (`values`) and visited as it steps,
/// so it keeps no row: `limit` bounds only a list whose text does. A row
/// that failed did before any later row's step failed, so its error is
/// main's first.
fn readList(
    a: *ReadAccess,
    comptime list: session_report.List,
    comptime S: type,
    args: S.Args,
    limit: u64,
    read: bool,
    comptime values: fn (*const S.Row) ValuesError!session_report.Row,
    watched: anytype,
) !void {
    try watched.call("open", .{list});
    if (!read) return;
    var rows: ListRead(S.Row, values, @TypeOf(watched)) = .{ .watched = watched };
    a.readEach(S, args, limit, &rows);
    const ran = runCurrent(a);
    if (rows.failure) |err| return err;
    try ran;
}

/// What a list row's values fail with: a stored fact main would not have
/// written.
const ValuesError = error{CorruptStore};

/// Checks each row and visits its values, in step order; after a failure
/// it visits nothing more.
fn ListRead(comptime Row: type, comptime values: anytype, comptime Watcher: type) type {
    const VisitError = @typeInfo(@typeInfo(Watcher).pointer.child.Result("row")).error_union.error_set;
    return struct {
        watched: Watcher,
        failure: ?(ValuesError || VisitError) = null,

        pub fn visit(read: *@This(), row: *const Row) bool {
            read.visitOne(row) catch |err| {
                read.failure = err;
                return false;
            };
            return true;
        }

        fn visitOne(read: *@This(), row: *const Row) (ValuesError || VisitError)!void {
            const value = try values(row);
            try read.watched.call("row", .{&value});
        }
    };
}

fn recentRow(row: *const recent_messages.Row) ValuesError!session_report.Row {
    return .{ .recent_messages = .{ .turn = row.turn_id.get(), .message = row.command_key.slice(), .outcome = row.outcome_code.slice() } };
}

fn unresolvedRow(row: *const unresolved_actions.Row) ValuesError!session_report.Row {
    // The insert authorizes every Action proposed under `bypass`.
    if (row.permission_mode == 1 and !row.authorized) return error.CorruptStore;
    const built_in = actionTool(&row.name_digest);
    const server: ?[]const u8 = if (row.server) |*server| server.slice() else null;
    if (server) |name| {
        if (!tool_name.valid(name) or built_in != null) return error.CorruptStore;
    }
    // A non-built-in Action must name an MCP member of its frozen offer.
    // Built-in checks remain strict; provider tools never create Actions.
    const mcp = server != null;
    const name = if (mcp) row.tool_name.slice() else @tagName(built_in orelse return error.CorruptStore);
    if (mcp and !tool_name.valid(name)) return error.CorruptStore;
    const core = !mcp and tool_defs.Runner.of(tool_defs.record(built_in.?)) == .core;
    // Settlement authorizes a core call at once, with no decision.
    if (core and !row.authorized) return error.CorruptStore;
    return .{
        .unresolved_actions = .{
            .action = row.action_id.get(),
            .parent_operation = row.parent_operation_id.get(),
            .call_ordinal = row.call_ordinal,
            .tool = name,
            .permission_revision = row.permission_revision.get(),
            .authorization = if (core) .core else if (!row.authorized) .pending else if (row.permission_mode == 1) .bypass else .allow_once,
            .call_id = .{ .length = row.call_id_length, .digest = row.call_id_digest },
            .server = server,
            .arguments = .{ .length = row.arguments_length, .digest = row.arguments_digest },
            // Unresolved, and not rejected: the rule proved a call with an
            // Action has no rejection, so main's code, either one's, is none.
            .presentation = try reads_domain.presentationOf(row.description, null, row.authorized, null),
        },
    };
}

/// The built-in tool whose name has `digest`, among those an Action runs.
fn actionTool(digest: *const [32]u8) ?built_in_tool.BuiltInTool {
    for (std.enums.values(built_in_tool.BuiltInTool)) |tool| {
        const owned = tool_defs.record(tool);
        if (owned.owner == .rui and std.mem.eql(u8, digest, &content_string.digest(owned.name))) return tool;
    }
    return null;
}

fn resolvedRow(row: *const resolved_actions.Row) ValuesError!session_report.Row {
    return .{
        .resolved_actions = .{
            .action = row.action_id.get(),
            .parent_operation = row.parent_operation_id.get(),
            .call_ordinal = row.call_ordinal,
            .code = row.resolution_code.slice(),
            .acceptance_position = row.acceptance_position.get(),
            .result = .{ .length = row.result_length, .digest = row.result_digest },
            // Main's code was the rejection's, else the resolution's; the rule
            // proved a call with an Action has no rejection. A code decides the
            // outcome, so whether the Action was authorized is not weighed.
            .presentation = try reads_domain.presentationOf(row.description, try presentedCode(row.resolution_code.slice()), null, optional(row.publication)),
        },
    };
}

fn rejectedRow(row: *const rejected_calls.Row) ValuesError!session_report.Row {
    return .{
        .rejected_calls = .{
            .parent_operation = row.operation_id.get(),
            .call_ordinal = row.call_ordinal,
            .code = row.rejection_code.slice(),
            .acceptance_position = row.acceptance_position.get(),
            .result = .{ .length = row.rejection_length, .digest = row.rejection_digest },
            .name = .{ .length = row.name_length, .digest = row.name_digest },
            .call_id = .{ .length = row.call_id_length, .digest = row.call_id_digest },
            .arguments = .{ .length = row.arguments_length, .digest = row.arguments_digest },
            // A code decides the outcome, so no authorization is weighed.
            .presentation = try reads_domain.presentationOf(row.description, try presentedCode(row.rejection_code.slice()), null, optional(row.publication)),
        },
    };
}

fn actionableRow(row: *const actionable_permissions.Row) ValuesError!session_report.Row {
    return .{ .actionable_permissions = .{ .action = row.action_id.get(), .permission_revision = row.permission_revision.get() } };
}

/// A stored outcome code as a presentation's: one it does not name is
/// `CorruptStore`, as main's decode answered.
fn presentedCode(code: []const u8) error{CorruptStore}!tool_presentation.ToolPresentation.Code {
    return std.meta.stringToEnum(tool_presentation.ToolPresentation.Code, code) orelse error.CorruptStore;
}

fn optional(value: ?rsql.Positive) ?u64 {
    return if (value) |positive| positive.get() else null;
}
