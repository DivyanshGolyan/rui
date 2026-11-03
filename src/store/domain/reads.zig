//! Public reads: Session inspection, conversation pages, activity, person
//! messages and proposals, and the content they open. Each entry point
//! runs its statements in one read Access (`ReadAccess`) under the Entry's
//! lock: a round reads what the next decision needs, and a later round
//! only what an earlier round's rows name.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const model_capability = @import("../../model_capability.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("command.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentLocation = content_domain.ContentLocation;
const ContentMetadata = content_domain.ContentMetadata;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const SessionReportCapture = report_domain.SessionReportCapture;
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
/// `filter`, which names a source's position and ordinal through `range`.
/// Every source seeks an index on (Session, position), so a filter on
/// position reads only the rows it keeps. The sources come in three groups,
/// each within the Store's four-term compound limit.
fn activitySources(comptime range: fn (comptime []const u8, comptime []const u8) []const u8, comptime order: []const u8) [3][]const u8 {
    return .{
        "SELECT admission_position AS position,0 AS ordinal,1 AS kind,admission_id AS id FROM message_admission @index(message_admission_position) " ++
            "WHERE session_ref=?1 AND " ++ range("admission_position", "0") ++
            " UNION ALL SELECT session_position,0,CASE entry_kind WHEN 1 THEN 2 ELSE 3 END,source_admission_id FROM conversation_entry " ++
            "WHERE session_ref=?1 AND entry_kind IN (1,3) AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT session_position,0,4,NULL FROM model_output_item @index(model_output_call_history) " ++
            "WHERE session_ref=?1 AND item_kind=3 AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT sender_position,0,8,admission_id FROM message_admission WHERE sender_session_ref=?1 AND " ++ range("sender_position", "0") ++ order,
        // A tool group's results sit at its last acceptance, one per call,
        // ordered by call.
        "SELECT last.acceptance_position AS position,tool_call.call_ordinal+1 AS ordinal,5 AS kind,NULL AS id FROM model_tool_call last " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=last.operation_id WHERE last.session_ref=?1 AND " ++
            range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.operation_id") ++
            " UNION ALL SELECT last.acceptance_position,tool_call.call_ordinal+1,5,NULL FROM action_operation last " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=last.parent_operation_id WHERE last.session_ref=?1 AND " ++
            range("last.acceptance_position", "tool_call.call_ordinal+1") ++ " AND " ++ toolGroupCompletesAtLast("last.parent_operation_id") ++
            " UNION ALL SELECT outcome_position,0,6,turn_id FROM turn @index(turn_outcome_position) WHERE session_ref=?1 AND outcome_code IS NOT NULL AND " ++ range("outcome_position", "0") ++
            " UNION ALL SELECT position,0,7,NULL FROM session_stop @index(session_stop_position) WHERE session_ref=?1 AND " ++ range("position", "0") ++ order,
        "SELECT sender_position AS position,0 AS ordinal,9 AS kind,NULL AS id FROM sent_rejection WHERE sender_session_ref=?1 AND " ++ range("sender_position", "0") ++
            " UNION ALL SELECT session_position,0,10,NULL FROM model_output_item @index(model_output_hosted_history) " ++
            "WHERE session_ref=?1 AND item_kind=5 AND " ++ range("session_position", "0") ++ order,
    };
}

fn anyActivityPosition(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
    _ = ordinal;
    return position ++ " IS NOT NULL";
}

/// The Activity row at position ?3 and ordinal ?4 through end ?2: each
/// source seeks that one position. A second row is `CorruptStore`.
const activity_item = blk: {
    const sources = activitySources(anyActivityPosition, "");
    break :blk rsql.Read(.{
        .sql = std.fmt.comptimePrint("WITH entries AS ({s}), completions AS ({s}), " ++
            "activity AS (SELECT position,ordinal,kind,id FROM entries UNION ALL SELECT position,ordinal,kind,id FROM completions UNION ALL {s}) " ++
            "SELECT kind,id FROM activity WHERE position=?3 AND ordinal=?4 AND position<=?2", .{ sources[0], sources[1], sources[2] }),
        .Args = struct { session: []const u8, end: u64, position: u64, ordinal: u64 },
        .Row = struct { kind: u8, id: ?rsql.Positive },
        .cardinality = .optional,
        .compound = true,
    });
};

/// One Activity page, at most 17 rows: forward, after cursor (?3, ?4)
/// through end ?2; backward, before cursor (?2, ?3), which is at or before
/// the end. Each source group keeps its own first 17 rows, read
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
    const sources = activitySources(if (forward) Range.after else Range.before, order);
    return rsql.Read(.{
        .sql = std.fmt.comptimePrint("WITH entries AS ({s}), completions AS ({s}), others AS ({s}) SELECT position,ordinal FROM entries " ++
            "UNION ALL SELECT position,ordinal FROM completions UNION ALL SELECT position,ordinal FROM others{s}", .{ sources[0], sources[1], sources[2], order }),
        .Args = if (forward) struct { session: []const u8, end: u64, position: u64, ordinal: u64 } else struct { session: []const u8, position: u64, ordinal: u64 },
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

pub const ProposalPage = struct {
    end: u64,
    items: [protocol.proposal_page_items]protocol.ProposalMetadata = undefined,
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
    a.run() catch |err| return if (err == error.StatementFailed) error.SessionReadFailed else err;
    return if (row) |found| found.next_position.get() else null;
}

/// The public metadata of the content row `content_id`, in a round of its
/// own. A failed step is `CorruptStore`, main's answer for it.
fn readPublicMetadata(a: *ReadAccess, content_id: u64) !ContentMetadata {
    var row: content_metadata.Row = undefined;
    a.read(content_metadata, .{ .content_id = content_id }, &row);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    return content_domain.publicMetadata(&row);
}

/// Round 1 reads the saved Session; round 2 its instructions' and output
/// schema's metadata. The pending, Action and rejected call counts are
/// command and report reads, converted with those files.
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
    a.read(content_metadata, .{ .content_id = @intCast(instructions_id) }, &instructions);
    if (current.output_schema_id) |content_id| a.read(content_metadata, .{ .content_id = @intCast(content_id) }, &output_schema);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    observation.instructions = .{ .length = instructions.byte_length, .digest = instructions.digest };
    if (current.output_schema_id != null) observation.output_schema = .{ .length = output_schema.byte_length, .digest = output_schema.digest };
    observation.pending_messages = try command_domain.countPendingMessages(a.store, session_ref);
    try report_domain.validateActiveTurnToolCalls(a.store, session_ref);
    observation.action_count = try report_domain.countActions(a.store, session_ref);
    observation.rejected_call_count = try report_domain.countRejectedCalls(a.store, session_ref);
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

/// Round 1 reads the Session's next position, then the cursor's item is
/// resolved (`hostedCall`, `publicConversationContent`), then one round
/// reads the page's rows into this frame, and each row's own reads follow
/// in rounds of their own. Every later round depends on a row an earlier
/// one read.
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
    if (request.before_position != 0) cursor: {
        // A cursor names an item: a hosted call, or an item with content.
        if (request.before_ordinal == 0) if (hostedCall(a, session, request.before_position)) |_| break :cursor else |err| switch (err) {
            error.ContentNotFound => {},
            else => return err,
        };
        _ = publicConversationContent(a, session, request.before_position, request.before_ordinal) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.* = .{ .end = end };
    if (end == 0) return;
    var rows: Collected(public_page.Row, PublicConversationPage.capacity + 1) = .{};
    a.readEach(public_page, .{ .session = session, .end = end, .before_position = request.before_position, .before_ordinal = request.before_ordinal }, rows.items.len, &rows);
    a.run() catch |err| return if (err == error.StatementFailed) error.ConversationReadFailed else err;
    page.more = rows.len > page.items.len;
    for (rows.slice()[0..@min(rows.len, page.items.len)]) |row| {
        if (row.kind == 5) {
            if (row.position == 0 or row.ordinal != 0) return error.CorruptStore;
            const call = try hostedCall(a, session, row.position);
            page.items[page.count] = .{ .position = row.position, .ordinal = 0, .kind = .hosted_call, .content = .{ .length = 0, .digest = protocol.contentDigest("") }, .presentation = call.presentation };
            page.count += 1;
            continue;
        }
        const content_id = row.content_id orelse 0;
        if (row.position == 0 or content_id == 0 or
            (row.kind != 1 and row.kind != 3 and row.kind != 4) or
            (row.kind == 4) != (row.ordinal > 0)) return error.CorruptStore;
        // Do not filter damaged rows out of SQL: validate ordinary
        // producers and the exposed content before publishing metadata.
        const resolved = try publicConversationContent(a, session, row.position, row.ordinal);
        if (@as(u64, @intCast(resolved.id)) != content_id or (row.kind == 1) != (resolved.admitted_at != null)) return error.CorruptStore;
        const metadata = resolved.metadata;
        page.items[page.count] = .{ .position = row.position, .ordinal = row.ordinal, .kind = switch (row.kind) {
            1 => .user,
            3 => .assistant,
            4 => .tool_result,
            else => unreachable,
        }, .content = .{ .length = metadata.length, .digest = metadata.digest }, .admitted_at = resolved.admitted_at, .sender = if (resolved.sender) |sender| try peerNamed(a, sender) else null, .presentation = if (resolved.tool_operation) |operation| try toolPresentation(a, operation, row.ordinal - 1, row.position) else null };
        page.count += 1;
    }
    const upper = if (request.before_position == 0) end else @min(end, request.before_position - @intFromBool(request.before_ordinal == 0));
    try checkAssistantEntries(a, session, if (page.more) page.items[page.count - 1].position else 0, upper);
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
const missing_assistant_entry = rsql.Read(.{
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

/// Checks the positions `lower` through `upper` in a round of its own. A
/// failed step is `ConversationReadFailed`, main's name for it.
fn checkAssistantEntries(a: *ReadAccess, session: []const u8, lower: u64, upper: u64) !void {
    if (lower > upper) return;
    var missing: missing_assistant_entry.Result = undefined;
    a.read(missing_assistant_entry, .{ .session = session, .lower = lower, .upper = upper }, &missing);
    a.run() catch |err| return if (err == error.StatementFailed) error.ConversationReadFailed else err;
    if (missing != null) return error.CorruptStore;
}

/// `checkAssistantEntries` for unconverted code (`report.zig`). Not inlined, so its
/// Access takes no slot in the report's frame.
pub noinline fn validateAssistantEntries(self: *Store, session: []const u8, lower: u64, upper: u64) !void {
    var a = ReadAccess.within(self);
    defer a.deinit();
    return checkAssistantEntries(&a, session, lower, upper);
}

/// An ordinary entry at a position, with the provenance that makes it
/// public. One indexed ordinary identity owns provenance for pages,
/// cursors and bytes. LEFT JOIN retains damage instead of hiding
/// dependencies.
const public_entry = rsql.Read(.{
    .sql = "SELECT e.content_id,CASE WHEN c.content_id IS NOT NULL AND c.private=0 AND t.session_ref=e.session_ref AND " ++
        "((e.entry_kind=1 AND m.session_ref=e.session_ref AND m.turn_id=e.turn_id AND m.content_id=e.content_id) OR " ++
        "(e.entry_kind=3 AND o.purpose=0 AND o.session_ref=e.session_ref AND o.turn_id=e.turn_id " ++
        "AND item.item_kind=2 AND item.message_content_id=e.content_id AND item.session_ref=e.session_ref " ++
        "AND item.session_position=e.session_position AND item.attempt_ordinal=o.attempt_ordinal " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ ")) THEN 1 ELSE 0 END AS consistent," ++
        "CASE WHEN e.entry_kind=1 THEN m.admitted_at END AS admitted_at,CASE WHEN e.entry_kind=1 THEN m.sender_session_ref END AS sender,e.recorded_at " ++
        "FROM conversation_entry e LEFT JOIN turn t ON t.turn_id=e.turn_id " ++
        "LEFT JOIN message_admission m ON m.admission_id=e.source_admission_id " ++
        "LEFT JOIN model_operation o ON o.operation_id=e.source_operation_id " ++
        "LEFT JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
        "LEFT JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind IN(1,3)",
    .Args = struct { session: []const u8, position: u64 },
    .Row = struct { content_id: rsql.Positive, consistent: bool, admitted_at: ?rsql.Positive, sender: ?SessionText, recorded_at: rsql.Positive },
    .cardinality = .optional,
});

/// The Tool Result of call ?3 at position ?2, with whether every call of
/// its group has public provenance and when the group completed.
const public_tool_result = rsql.Read(.{
    // Only an Operation with an acceptance at the position can complete
    // there.
    .sql = "WITH last AS (SELECT operation_id FROM model_tool_call WHERE session_ref=?1 AND acceptance_position=?2 " ++
        "UNION ALL SELECT parent_operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position=?2) " ++
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
pub const PublicContent = struct { id: i64, metadata: ContentMetadata, tool_operation: ?u64, admitted_at: ?u64, sender: ?SessionText = null, at: u64 };

// A cursor and a byte reader resolve the same public identity and exposed
// metadata. Neither may accept a private or absent canonical result.
/// An entry's round reads its assistant check and its row together; a
/// Tool Result's reads its row, then its group's outcome facts (a report
/// read). The metadata of the content found is the last round. A failed
/// step is main's name: `ConversationReadFailed` for an entry,
/// `PublicContentReadFailed` for a Tool Result, `CorruptStore` for the
/// metadata.
fn publicConversationContent(a: *ReadAccess, session: []const u8, position: u64, ordinal: u64) !PublicContent {
    var content: PublicContent = undefined;
    if (ordinal == 0) {
        var missing: missing_assistant_entry.Result = undefined;
        var row: public_entry.Result = undefined;
        a.read(missing_assistant_entry, .{ .session = session, .lower = position, .upper = position }, &missing);
        a.read(public_entry, .{ .session = session, .position = position }, &row);
        a.run() catch |err| return if (err == error.StatementFailed) error.ConversationReadFailed else err;
        if (missing != null) return error.CorruptStore;
        const entry = row orelse return error.ContentNotFound;
        if (!entry.consistent) return error.CorruptStore;
        content = .{ .id = @intCast(entry.content_id.get()), .metadata = undefined, .tool_operation = null, .admitted_at = if (entry.admitted_at) |second| second.get() else null, .sender = entry.sender, .at = entry.recorded_at.get() };
    } else {
        var first: First(public_tool_result.Row) = .{};
        a.readEach(public_tool_result, .{ .session = session, .position = position, .ordinal = ordinal }, 1, &first);
        a.run() catch |err| return if (err == error.StatementFailed) error.PublicContentReadFailed else err;
        const result = first.row orelse return error.ContentNotFound;
        if (!result.consistent) return error.CorruptStore;
        _ = try report_domain.readToolOutcomeFacts(a.store, result.operation_id.get(), true);
        content = .{ .id = @intCast(result.content_id.get()), .metadata = undefined, .tool_operation = result.operation_id.get(), .admitted_at = null, .at = result.at.get() };
    }
    content.metadata = try readPublicMetadata(a, @intCast(content.id));
    return content;
}

/// `publicConversationContent` for unconverted code (`report.zig`). Not inlined, so its
/// Access takes no slot in the report's frame.
pub noinline fn publicConversationContentLocked(self: *Store, session: []const u8, position: u64, ordinal: u64) !PublicContent {
    var a = ReadAccess.within(self);
    defer a.deinit();
    return publicConversationContent(&a, session, position, ordinal);
}

/// One content value read in order under the Store lock, a window at a
/// time. Declared with a literal of its Store and length, which leaves
/// the reader and this window unwritten, then `reader.open`ed;
/// `= undefined` would fill the window with 0xAA.
pub const ContentSource = struct {
    store: *Store,
    reader: ContentReader = undefined,
    position: u64 = 0,
    end: u64,
    window: [2048]u8 = undefined,
    used: usize = 0,
    count: usize = 0,

    /// Reads under the held lock, checking the digest at the end as
    /// every content reader does; the caller's Entry fences on error.
    fn read(source: *ContentSource, start: u64, destination: []u8) !void {
        try content_domain.readOwnedContentLocked(source.store, &source.reader, start, destination);
        if (!source.reader.absorb(start, destination)) return error.CorruptStore;
    }

    /// The next window of bytes, consumed whole; null at the end.
    pub fn nextWindow(source: *ContentSource) !?[]const u8 {
        std.debug.assert(source.used == source.count);
        const wanted: usize = @intCast(@min(source.window.len, source.end - source.position));
        if (wanted == 0) return null;
        try source.read(source.position, source.window[0..wanted]);
        source.position += wanted;
        return source.window[0..wanted];
    }

    pub fn peek(source: *@This()) !?u8 {
        if (source.used == source.count) {
            const wanted: usize = @intCast(@min(source.window.len, source.end - source.position));
            try source.read(source.position, source.window[0..wanted]);
            source.count = wanted;
            source.used = 0;
            if (source.count == 0) return null;
        }
        return source.window[source.used];
    }

    pub fn take(source: *@This()) !u8 {
        const byte = try source.peek() orelse return error.UnexpectedEof;
        source.used += 1;
        source.position += 1;
        return byte;
    }

    pub fn next(source: *@This()) !?u8 {
        return if (try source.peek() != null) try source.take() else null;
    }

    pub fn offset(source: *@This()) u64 {
        return source.position;
    }

    pub fn setRange(source: *@This(), start: u64, length: u64) !void {
        const end = try std.math.add(u64, start, length);
        if (end > source.reader.reference.length) return error.CorruptStore;
        source.position = start;
        source.end = end;
        source.used = 0;
        source.count = 0;
    }

    pub fn space(source: *@This()) !void {
        while (try source.peek()) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => _ = try source.take(),
            else => return,
        };
    }

    pub fn expect(source: *@This(), expected: u8) !void {
        try source.space();
        if (try source.take() != expected) return error.CorruptStore;
    }

    pub fn expectEnd(source: *@This()) !void {
        try source.space();
        if (try source.peek() != null) return error.CorruptStore;
    }
};

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
    .cardinality = .one,
});

/// Round 1 reads the call; round 2 the Proposal of the item it names. A
/// failed step of the call's read is `CorruptStore`, main's answer for it.
fn toolPresentation(a: *ReadAccess, operation: u64, ordinal: u64, publication_position: ?u64) !protocol.ToolPresentation {
    var row: tool_presentation.Row = undefined;
    a.read(tool_presentation, .{ .operation = operation, .ordinal = ordinal }, &row);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    _ = try proposal(a, row.session_ref.slice(), row.session_position.get());
    var result: protocol.ToolPresentation = .{ .description = null, .code = .unresolved, .publication_position = publication_position };
    if (row.description) |description| {
        if (!protocol.ToolPresentation.validDescription(description.slice())) return error.CorruptStore;
        result.description = description;
    }
    if (row.code) |code| {
        result.code = code;
    } else if (!(row.authorized orelse false)) result.code = .pending_permission;
    if (result.description == null) switch (result.code) {
        .unknown_tool, .invalid_arguments => {},
        else => return error.CorruptStore,
    };
    return result;
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
    .cardinality = .optional,
});

/// The hosted tool call at `position`, as an accepted Operation's output
/// recorded it: its line, its outcome and when its Operation resolved. A
/// round of its own; a failed step is `ActivityReadFailed`, main's name.
fn hostedCall(a: *ReadAccess, session: []const u8, position: u64) !struct { presentation: protocol.ToolPresentation, at: u64 } {
    var found: hosted_call.Result = undefined;
    a.read(hosted_call, .{ .session = session, .position = position }, &found);
    a.run() catch |err| return if (err == error.StatementFailed) error.ActivityReadFailed else err;
    const row = found orelse return error.ContentNotFound;
    if (!row.consistent or !protocol.ToolPresentation.validDescription(row.description.slice())) return error.CorruptStore;
    return .{
        .presentation = .{ .description = row.description, .code = if (row.call_failed) .failed else .succeeded, .publication_position = position },
        .at = (row.resolved_at orelse return error.CorruptStore).get(),
    };
}

/// `toolPresentation` for unconverted code (`report.zig`). Not inlined, so its
/// Access takes no slot in the report's frame.
pub noinline fn appendToolPresentation(self: *Store, operation: u64, ordinal: u64, publication_position: ?u64, capture: *SessionReportCapture) !void {
    var a = ReadAccess.within(self);
    defer a.deinit();
    const presentation = try toolPresentation(&a, operation, ordinal, publication_position);
    var buffer: [protocol.ToolPresentation.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try presentation.writeJson(&writer);
    try capture.append(",\"presentation\":");
    try capture.append(writer.buffered());
}

/// The Session columns an Activity page reads, its workspace into the
/// page itself. They are the columns main's Session facts read, so a
/// damaged one still fails the page, and how far a person read.
const page_session = rsql.Read(.{
    .sql = "SELECT model,permission_mode,revision,next_position,compaction_trigger,output_reservation,reasoning_effort,created_at,provider,workspace,read_through " ++
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
        read_through: ?rsql.Positive,
    },
    .cardinality = .optional,
});

/// Round 1 reads the Session and the sequence guard; the cursor's item
/// follows (`activityItem`); then one round reads the page's rows into
/// this frame, and each row's item follows in rounds of its own; then one
/// round reads the assistant check, the call activity and the queued
/// Messages, which the page's last row bounds. Call activity past 16
/// Operations and the work footer (a report read) take more.
pub fn activityPage(a: *ReadAccess, request: *const protocol.ActivityPage, page: *protocol.ActivityFacts) !void {
    page.* = .{ .end = 0, .direction = request.direction, .work = .{ .workspace = .{ .len = 0 } } };
    const session_ref = request.session.slice();
    var session: page_session.Row = undefined;
    session.workspace = &page.work.workspace;
    var found: store_access.Found = undefined;
    var guard: activity_sequence_guard.Result = undefined;
    a.readInto(page_session, .{ .session = session_ref }, &session, &found);
    a.read(activity_sequence_guard, .{ .session = session_ref }, &guard);
    a.run() catch |err| return if (err == error.StatementFailed) (if (a.failedOn(page_session)) error.SessionReadFailed else error.CorruptStore) else err;
    if (!found.get()) return error.SessionNotFound;
    if (session.compaction_trigger == @as(?u64, 0)) return error.CorruptStore;
    const next = session.next_position.get();
    const end = request.end orelse next - 1;
    if (end >= next or request.position > end) return error.InvalidCursor;
    if (guard != null) return error.CorruptStore;
    if (request.ordinal) |ordinal| {
        _ = activityItem(a, session_ref, end, request.position, ordinal) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.end = end;
    page.read_through = if (session.read_through) |position| position.get() else null;
    // The cursor as a bound on (position, ordinal): a whole position is
    // passed or kept by the largest ordinal, and a backward page with
    // no cursor starts after the end's last row.
    const forward = request.direction == .forward;
    const whole: u64 = std.math.maxInt(i64);
    var rows: Collected(ActivityPageRow, page.items.len + 1) = .{};
    if (forward)
        a.readEach(activity_forward, .{ .session = session_ref, .end = end, .position = request.position, .ordinal = request.ordinal orelse whole }, rows.items.len, &rows)
    else
        a.readEach(activity_backward, .{ .session = session_ref, .position = if (request.position != 0) request.position else end, .ordinal = if (request.position == 0) whole else request.ordinal orelse 0 }, rows.items.len, &rows);
    a.run() catch |err| return if (err == error.StatementFailed) error.ActivityReadFailed else err;
    for (rows.slice()) |row| {
        const position = row.position.get();
        if (page.count == page.items.len) {
            page.more = true;
            // The row after a backward page's oldest says whether the
            // unseen rows reach past it.
            page.beyond_unseen = !forward and if (page.read_through) |read| position > read else true;
            break;
        }
        page.items[page.count] = (try activityItem(a, session_ref, end, position, row.ordinal)).item;
        page.count += 1;
    }
    const boundary = if (page.more) &page.items[page.count - 1] else null;
    const lower = if (forward) request.position + 1 else if (boundary) |item| item.position else 0;
    const upper = if (forward) (if (boundary) |item| item.position else end) else if (request.position == 0) end else @min(end, request.position - @intFromBool((request.ordinal orelse 0) == 0));
    const last = if (forward) boundary else null;
    const call_position = if (last) |item| item.position else end;
    const call_ordinal = if (last) |item| item.ordinal else null;
    var missing: missing_assistant_entry.Result = null;
    var calls: CallRows = .{};
    var waiting: QueuedMessages = .{};
    if (lower <= upper) a.read(missing_assistant_entry, .{ .session = session_ref, .lower = lower, .upper = upper }, &missing);
    a.readEach(call_activity, .{ .session = session_ref, .position = call_position, .ordinal = call_ordinal }, std.math.maxInt(u64), &calls);
    a.readEach(queued, .{ .session = session_ref, .position = call_position }, std.math.maxInt(u64), &waiting);
    a.run() catch |err| return if (err == error.StatementFailed)
        (if (a.failedOn(missing_assistant_entry)) error.ConversationReadFailed else if (a.failedOn(queued)) error.ActivityReadFailed else error.CallReadFailed)
    else
        err;
    if (missing != null) return error.CorruptStore;
    page.call_activity = try callActivity(a, &calls, .{ .session = session_ref, .position = call_position, .ordinal = call_ordinal, .after = 0 });
    page.queued = waiting.queued;
    // Work as of this same read, so the footer, consent and first Action
    // always describe the page they arrive with.
    const work = (try report_domain.readWorkLocked(a.store, session_ref, session.created_at.get(), try store_core.readUnixMilliseconds(a.store.io))).work;
    page.work.work = .fromCore(work);
    page.work.revision = session.revision.get();
}

const ActivityPageRow = struct { position: rsql.Positive, ordinal: u64 };

/// Main's one guarded UPDATE: how far a person read moves only forward,
/// and stays below the Session's next position. No Session list row shows
/// `read_through` (`schema` marks it unlisted), so the write touches no
/// Session and names it by its reference alone.
const advance_read_through = rsql.Write(.{
    .sql = "UPDATE session SET read_through=?2 WHERE session_ref=@session(?1) AND ?2<next_position AND (read_through IS NULL OR read_through<?2)",
    .Args = struct { session: rsql.SessionRef, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ReadThroughKept } },
});

/// Round 1 is the guarded write, which commits itself. Only when it
/// changes no row does a read round ask why, as main did: an unknown
/// Session, a position not reached, or one already read, which is no
/// error. A failed read is `SessionReadFailed`, main's name for it.
pub fn markRead(entry: *const store_core.Entry, request: *const protocol.MarkRead) !void {
    // Main's bind refused a position past maxInt(i64), which fences.
    if (request.position > std.math.maxInt(i64)) return error.IntegerOutOfRange;
    const session = request.session.slice();
    const Ref = @FieldType(rsql.SessionRef, "ref");
    // The schema's check holds every session_ref to this length, so a
    // text of any other names no Session.
    if (session.len != @sizeOf(Ref)) return error.SessionNotFound;
    kept: {
        var a: store_access.Access(.single, error{ReadThroughKept}) = .open(entry);
        defer a.deinit();
        a.write(advance_read_through, .{ .session = .{ .ref = session[0..@sizeOf(Ref)].* }, .position = request.position });
        a.commit() catch |err| switch (err) {
            error.ReadThroughKept => break :kept,
            else => |failed| return failed,
        };
        return;
    }
    var a: ReadAccess = .open(entry);
    defer a.deinit();
    const next = try readNextPosition(&a, session) orelse return error.SessionNotFound;
    if (request.position >= next) return error.PositionNotReached;
}

const PersonMessageArgs = struct { session: []const u8, after: u64, before: u64 };
const PersonMessageRow = struct { admission_position: rsql.Positive, content_id: rsql.Positive };

/// The Message with no Session sender nearest a bound, in `backward` or
/// forward order: one seek in the index of those Messages.
fn PersonMessage(comptime backward: bool) type {
    return rsql.Read(.{
        .sql = "SELECT admission_position,content_id FROM message_admission @index(message_admission_person) " ++
            "WHERE session_ref=?1 AND sender_session_ref IS NULL AND admission_position>?2 AND admission_position<?3 ORDER BY admission_position" ++
            (if (backward) " DESC LIMIT 1" else " LIMIT 1"),
        .Args = PersonMessageArgs,
        .Row = PersonMessageRow,
        .cardinality = .optional,
    });
}
const person_backward = PersonMessage(true);
const person_forward = PersonMessage(false);

/// Round 1 reads the Session's next position, round 2 the Message, round
/// 3 its content's metadata. A failed step of the Message's read is
/// `ActivityReadFailed`, main's name.
pub fn personMessage(a: *ReadAccess, request: *const protocol.ReadPersonMessage) !protocol.PersonMessage {
    const session = request.session.slice();
    const next = try readNextPosition(a, session) orelse return error.SessionNotFound;
    const end = request.end orelse next - 1;
    if (end >= next or request.position > end) return error.InvalidCursor;
    const backward = request.direction == .backward;
    const bound: PersonMessageArgs = .{
        .session = session,
        .after = if (backward) 0 else request.position,
        .before = if (backward and request.position != 0) request.position else end + 1,
    };
    var found: ?PersonMessageRow = undefined;
    if (backward) a.read(person_backward, bound, &found) else a.read(person_forward, bound, &found);
    a.run() catch |err| return if (err == error.StatementFailed) error.ActivityReadFailed else err;
    var reply: protocol.PersonMessage = .{ .end = end };
    const row = found orelse return reply;
    const metadata = try readPublicMetadata(a, row.content_id.get());
    reply.message = .{ .position = row.admission_position.get(), .content = .{ .length = metadata.length, .digest = metadata.digest } };
    return reply;
}

const CallRow = struct { operation_id: rsql.Positive, call_ordinal: u64, position: ?rsql.Positive };
const CallArgs = struct { session: []const u8, position: u64, ordinal: ?u64, after: u64 };

// This projection shares the page's canonical capture, not Current's active
// Turn lifetime. It is staged until the frontend acknowledges that page.
/// The calls of every Operation whose tool group is still waiting, or
/// completes after (?2, ?3), in Operation and call order, with each
/// group's position. A group still waiting has an Action without its
/// result; one that completes after the page has an acceptance after it.
/// Only those Operations are grouped, not the Session's history. A
/// `resumed` read takes only Operations after ?4.
fn CallActivity(comptime resumed: bool) type {
    return rsql.Read(.{
        .sql = "WITH ops AS (SELECT parent_operation_id AS operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NULL " ++
            "UNION SELECT operation_id FROM model_tool_call WHERE session_ref=?1 AND acceptance_position>=?2 " ++
            "UNION SELECT parent_operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position>=?2), " ++
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
            "AND (tool_groups.position IS NULL OR tool_groups.position>?2 OR (tool_groups.position=?2 AND ?3 IS NOT NULL AND tool_call.call_ordinal+1>?3))) " ++
            "SELECT operation_id,call_ordinal,position FROM candidates " ++ (if (resumed) "WHERE operation_id>?4 " else "") ++ "ORDER BY operation_id,call_ordinal",
        .Args = if (resumed) CallArgs else struct { session: []const u8, position: u64, ordinal: ?u64 },
        .Row = CallRow,
        .cardinality = .each,
        .compound = true,
    });
}
const call_activity = CallActivity(false);
const call_activity_after = CallActivity(true);

/// What a call activity read keeps: every call counted, the first three,
/// and up to 16 Operations' projected group positions, which the caller
/// checks against each Operation's outcome facts between rounds. A row
/// that names a 17th Operation stops the read, and the next round resumes
/// at it (`call_activity_after`).
const CallRows = struct {
    const max_operations = 16;
    operations: [max_operations]struct { id: u64, projected: ?u64 } = undefined,
    operation_count: usize = 0,
    full: bool = false,
    total: u64 = 0,
    entries: [@typeInfo(@FieldType(protocol.CallActivity, "entries")).array.len]struct { operation: u64, ordinal: u64 } = undefined,
    entry_count: usize = 0,

    pub fn visit(rows: *CallRows, row: *const CallRow) bool {
        const operation = row.operation_id.get();
        if (rows.operation_count == 0 or rows.operations[rows.operation_count - 1].id != operation) {
            if (rows.operation_count == max_operations) {
                rows.full = true;
                return false;
            }
            rows.operations[rows.operation_count] = .{ .id = operation, .projected = if (row.position) |position| position.get() else null };
            rows.operation_count += 1;
        }
        rows.total += 1;
        if (rows.entry_count < rows.entries.len) {
            rows.entries[rows.entry_count] = .{ .operation = operation, .ordinal = row.call_ordinal };
            rows.entry_count += 1;
        }
        return true;
    }
};

/// Checks each Operation a call activity round kept against its outcome
/// facts (a report read), and reads the first calls' presentations, then
/// resumes a read that stopped at its 17th Operation. A failed step of a
/// resumed read is `CallReadFailed`, main's name.
fn callActivity(a: *ReadAccess, rows: *CallRows, resume_from: CallArgs) !protocol.CallActivity {
    var result: protocol.CallActivity = .{};
    var args = resume_from;
    while (true) {
        for (rows.operations[0..rows.operation_count]) |operation| {
            const publication = (try report_domain.readToolOutcomeFacts(a.store, operation.id, false)).position;
            if (publication != operation.projected) return error.CorruptStore;
            for (rows.entries[result.count..rows.entry_count]) |entry| {
                if (entry.operation != operation.id) break;
                result.entries[result.count] = .{ .operation = entry.operation, .ordinal = entry.ordinal, .presentation = try toolPresentation(a, entry.operation, entry.ordinal, publication) };
                result.count += 1;
            }
        }
        if (!rows.full) break;
        args.after = rows.operations[rows.operation_count - 1].id;
        rows.operation_count = 0;
        rows.full = false;
        a.readEach(call_activity_after, args, std.math.maxInt(u64), rows);
        a.run() catch |err| return if (err == error.StatementFailed) error.CallReadFailed else err;
    }
    result.total = rows.total;
    return result;
}

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
    .cardinality = .optional,
});

/// A peer Session with its label as the Store holds it now, so a rename
/// shows on every row that names it. One indexed lookup per peer row, in
/// a round of its own; a failed step is `SessionReadFailed`, main's name.
fn peerNamed(a: *ReadAccess, session: SessionText) !protocol.NamedPeer {
    var found: peer_label.Result = undefined;
    a.read(peer_label, .{ .session = session }, &found);
    a.run() catch |err| return if (err == error.StatementFailed) error.SessionReadFailed else err;
    return namedPeer(session, found);
}

/// The peer a `peer_label` read found: a failed send can name a Session
/// this Store never held, which has no label.
fn namedPeer(session: SessionText, found: peer_label.Result) !protocol.NamedPeer {
    var peer: protocol.NamedPeer = .{ .session = session };
    if (found) |row| if (row.label) |label| {
        if (!protocol.validLabel(label.slice())) return error.CorruptStore;
        peer.label = label;
    };
    return peer;
}

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
    .cardinality = .one,
});

/// Content an Activity item exposes: its row and public metadata.
const Located = struct { id: i64, metadata: ContentMetadata };

/// Round 1 reads the Message; round 2 its content's metadata and its
/// sender's label. A failed step is main's name: `CorruptStore` for the
/// Message and the metadata, `SessionReadFailed` for the label.
fn activityMessage(a: *ReadAccess, session: []const u8, end: u64, admission: u64) !struct { message: protocol.ActivityItem.Message, content: Located } {
    var row: activity_message.Row = undefined;
    a.read(activity_message, .{ .session = session, .end = end, .admission = admission }, &row);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    if (!row.consistent) return error.CorruptStore;
    var metadata: content_metadata.Row = undefined;
    var label: peer_label.Result = undefined;
    a.read(content_metadata, .{ .content_id = row.content_id.get() }, &metadata);
    if (row.sender_session_ref) |sender| a.read(peer_label, .{ .session = sender }, &label);
    a.run() catch |err| return if (err == error.StatementFailed) (if (a.failedOn(peer_label)) error.SessionReadFailed else error.CorruptStore) else err;
    const content = try content_domain.publicMetadata(&metadata);
    var message: protocol.ActivityItem.Message = .{
        .admission = admission,
        .key = row.command_key,
        .turn = null,
        .state = if (row.applied) .applied else if (row.excluded) .excluded else .queued,
        .content = .{ .length = content.length, .digest = content.digest },
        .admitted_at = row.admitted_at.get(),
    };
    if (row.applied) message.turn = (row.turn_id orelse return error.CorruptStore).get();
    message.sender = if (row.sender_session_ref) |sender| try namedPeer(sender, label) else null;
    return .{ .message = message, .content = .{ .id = @intCast(row.content_id.get()), .metadata = content } };
}

pub fn readPeer(statement: *sqlite.c.sqlite3_stmt, column: c_int) !?protocol.Peer {
    if (sqlite.c.sqlite3_column_type(statement, column) == sqlite.c.SQLITE_NULL) return null;
    var sender: SessionText = .{};
    try sqlite.readText(statement, column, &sender);
    return .{ .session = sender };
}

const ActivityIdentity = struct { item: protocol.ActivityItem, content: ?Located = null };

/// When the Operation of a call proposed in the Session resolved.
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
    .cardinality = .one,
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
    .cardinality = .one,
});

/// A Turn's outcome at position ?2, with its causing Operation's.
const turn_outcome = rsql.Read(.{
    .sql = "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.session_ref=t.session_ref AND o.turn_id=t.turn_id " ++
        "AND o.resolution_code IS NOT NULL AS consistent,o.resolution_content_id,t.outcome_at FROM turn t LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
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

/// The Activity item at (`position`, `ordinal`) through `end`. Round 1
/// reads its row, with the assistant check of an ordinal 0 position at or
/// before `end`; its kind's own reads follow, each round reading only
/// what the one before named. A failed step is main's name for the read:
/// `ConversationReadFailed` for the assistant check, `ActivityReadFailed`
/// for the row, and per kind as each helper says; the kind reads main
/// answered `CorruptStore` for answer it still.
fn activityItem(a: *ReadAccess, session: []const u8, end: u64, position: u64, ordinal: u64) !ActivityIdentity {
    var missing: missing_assistant_entry.Result = null;
    var found: activity_item.Result = undefined;
    if (ordinal == 0 and position <= end) a.read(missing_assistant_entry, .{ .session = session, .lower = position, .upper = position }, &missing);
    a.read(activity_item, .{ .session = session, .end = end, .position = position, .ordinal = ordinal }, &found);
    a.run() catch |err| return if (err == error.StatementFailed) (if (a.failedOn(missing_assistant_entry)) error.ConversationReadFailed else error.ActivityReadFailed) else err;
    if (missing != null) return error.CorruptStore;
    const row = found orelse return error.ContentNotFound;
    // Each kind reads `at` from the row that owns its fact.
    var result: ActivityIdentity = .{ .item = .{ .position = position, .ordinal = ordinal, .at = undefined, .value = undefined } };
    switch (row.kind) {
        1, 2 => |kind| {
            const admission = row.id orelse return error.CorruptStore;
            const owned = try activityMessage(a, session, end, admission.get());
            const message = owned.message;
            if (kind == 2 and message.state != .applied) return error.CorruptStore;
            result.item.value = if (kind == 1) .{ .admission = message } else .{ .user = message };
            result.content = owned.content;
            result.item.at = message.admitted_at;
            if (kind == 2) {
                const entry = try publicConversationContent(a, session, position, ordinal);
                if (entry.id != owned.content.id) return error.CorruptStore;
                result.item.at = entry.at;
            }
        },
        3, 5 => |kind| {
            const content = try publicConversationContent(a, session, position, ordinal);
            result.item.at = content.at;
            result.item.value = if (kind == 3) .{ .assistant = .{ .length = content.metadata.length, .digest = content.metadata.digest } } else .{ .tool_result = .{ .content = .{ .length = content.metadata.length, .digest = content.metadata.digest }, .presentation = try toolPresentation(a, content.tool_operation orelse return error.CorruptStore, ordinal - 1, position) } };
            result.content = .{ .id = content.id, .metadata = content.metadata };
        },
        4 => {
            const call = (try proposal(a, session, position)).metadata;
            result.item.value = .{ .call = call };
            var resolved: call_resolved.Row = undefined;
            a.read(call_resolved, .{ .operation = call.operation, .session = session }, &resolved);
            a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
            result.item.at = resolved.resolved_at.get();
        },
        10 => {
            const call = try hostedCall(a, session, position);
            result.item.value = .{ .hosted_call = call.presentation };
            result.item.at = call.at;
        },
        8 => try sentItem(a, session, position, &row, &result),
        9 => try sendFailureItem(a, session, position, &result),
        6 => try outcomeItem(a, session, position, &result),
        7 => try stopItem(a, session, end, position, &result),
        else => return error.CorruptStore,
    }
    return result;
}

/// A Message this Session sent (kind 8): its admission, then its content
/// and its target's label.
/// Its own function, so its rows take no slot in `activityItem`'s frame.
noinline fn sentItem(a: *ReadAccess, session: []const u8, position: u64, row: *const activity_item.Row, result: *ActivityIdentity) !void {
    const admission = row.id orelse return error.CorruptStore;
    var sent: sent_message.Row = undefined;
    a.read(sent_message, .{ .admission = admission.get(), .session = session, .position = position }, &sent);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    if (!sent.consistent) return error.CorruptStore;
    var metadata: content_metadata.Row = undefined;
    var label: peer_label.Result = undefined;
    a.read(content_metadata, .{ .content_id = sent.content_id.get() }, &metadata);
    a.read(peer_label, .{ .session = sent.session_ref }, &label);
    a.run() catch |err| return if (err == error.StatementFailed) (if (a.failedOn(peer_label)) error.SessionReadFailed else error.CorruptStore) else err;
    const content = try content_domain.publicMetadata(&metadata);
    result.item.value = .{ .sent = .{
        .admission = admission.get(),
        .target = try namedPeer(sent.session_ref, label),
        .content = .{ .length = content.length, .digest = content.digest },
        .admitted_at = sent.admitted_at.get(),
    } };
    result.item.at = sent.admitted_at.get();
    result.content = .{ .id = @intCast(sent.content_id.get()), .metadata = content };
}

/// A send this Session's target refused (kind 9).
/// Its own function, so its rows take no slot in `activityItem`'s frame.
noinline fn sendFailureItem(a: *ReadAccess, session: []const u8, position: u64, result: *ActivityIdentity) !void {
    var failure: send_failure.Row = undefined;
    a.read(send_failure, .{ .session = session, .position = position }, &failure);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    if (!failure.consistent) return error.CorruptStore;
    result.item.value = .{ .send_failed = .{ .key = failure.command_key, .target = try peerNamed(a, failure.target), .code = failure.code } };
    result.item.at = failure.rejected_at.get();
}

/// A Turn's outcome (kind 6), with its Resolution's answer.
/// Its own function, so its rows take no slot in `activityItem`'s frame.
noinline fn outcomeItem(a: *ReadAccess, session: []const u8, position: u64, result: *ActivityIdentity) !void {
    var first: First(turn_outcome.Row) = .{};
    a.readEach(turn_outcome, .{ .session = session, .position = position }, 1, &first);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    const turn = first.row orelse return error.CorruptStore;
    if (!turn.consistent) return error.CorruptStore;
    var outcome: protocol.ActivityItem.Outcome = .{ .turn = turn.turn_id.get(), .operation = turn.operation_id.get(), .code = turn.outcome_code, .content = null };
    const content_id: ?i64 = if (turn.outcome_content_id) |id| @intCast(id.get()) else null;
    switch (try TurnOutcome.decode(outcome.code.slice(), content_id)) {
        // A completed Turn answers with its causing Operation's Resolution.
        .completed => |answer| if (turn.resolution_content_id == null or turn.resolution_content_id.?.get() != answer) return error.CorruptStore,
        .cancelled, .retry_exhausted, .resource_exceeded, .failed => {},
    }
    if (turn.outcome_content_id) |id| {
        const content = try readPublicMetadata(a, id.get());
        outcome.content = .{ .length = content.length, .digest = content.digest };
        result.content = .{ .id = @intCast(id.get()), .metadata = content };
    }
    result.item.value = .{ .outcome = outcome };
    result.item.at = turn.outcome_at.get();
}

/// A Session stop (kind 7) and whether its Turn has finished by `end`.
/// Its own function, so its rows take no slot in `activityItem`'s frame.
noinline fn stopItem(a: *ReadAccess, session: []const u8, end: u64, position: u64, result: *ActivityIdentity) !void {
    var first: First(session_stop.Row) = .{};
    a.readEach(session_stop, .{ .session = session, .position = position }, 1, &first);
    a.run() catch |err| return if (err == error.StatementFailed) error.CorruptStore else err;
    const stop_row = first.row orelse return error.CorruptStore;
    if (!stop_row.consistent) return error.CorruptStore;
    const turn: ?u64 = if (stop_row.selected_turn_id) |id| id.get() else null;
    const outcome_position: ?u64 = if (stop_row.outcome_position) |at| at.get() else null;
    result.item.value = .{ .stop = .{ .key = stop_row.command_key, .turn = turn, .cutoff = stop_row.admission_cutoff, .completion = if (turn == null or (outcome_position != null and outcome_position.? <= end)) .completed else .pending } };
    result.item.at = stop_row.stopped_at.get();
}

/// Round 1 reads the sequence guard; the item's own reads follow
/// (`publicConversationContent`, `activityItem`), which read the content's
/// metadata, so no read repeats it.
pub fn openActivityContent(a: *ReadAccess, request: *const protocol.ReadActivityContent) !ContentLocation {
    var guard: activity_sequence_guard.Result = undefined;
    a.read(activity_sequence_guard, .{ .session = request.session.slice() }, &guard);
    a.run() catch |err| return store_core.fence(a.store, if (err == error.StatementFailed) error.CorruptStore else err);
    if (guard != null) return store_core.fence(a.store, error.CorruptStore);
    // Only Tool Results have nonzero ordinals. Byte readers need their
    // canonical identity, not a second scan of the original arguments.
    const content: Located = if (request.ordinal != 0) located: {
        const found = publicConversationContent(a, request.session.slice(), request.position, request.ordinal) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(a.store, err),
        };
        break :located .{ .id = found.id, .metadata = found.metadata };
    } else located: {
        const identity = activityItem(a, request.session.slice(), std.math.maxInt(i64), request.position, request.ordinal) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(a.store, err),
        };
        break :located identity.content orelse return error.ContentNotFound;
    };
    return .{ .store = a.store, .content_id = content.id, .reference = .{ .length = content.metadata.length, .digest = content.metadata.digest } };
}

/// The positions of a Session's proposed calls after ?2 through ?3: the
/// immutable accepted item owns discovery, including rejected calls. Do
/// not filter on live Actions, permissions or Turn state.
const proposal_positions = rsql.Read(.{
    .sql = "SELECT session_position FROM model_output_item " ++
        "WHERE session_ref=?1 AND session_position>?2 AND session_position<=?3 AND item_kind=3 " ++
        "ORDER BY session_position LIMIT 17",
    .Args = struct { session: []const u8, after: u64, end: u64 },
    .Row = struct { session_position: rsql.Positive },
    .cardinality = .each,
});

/// Round 1 reads the Session's next position, then the cursor's Proposal,
/// then one round reads the page's positions into this frame, and each
/// Proposal follows in a round of its own. A failed step of the positions
/// read is `ProposalReadFailed`, main's name.
pub fn proposalPage(a: *ReadAccess, request: *const protocol.ProposalPage, page: *ProposalPage) !void {
    const session = request.session.slice();
    const next = try readNextPosition(a, session) orelse return error.SessionNotFound;
    const end = request.end orelse next - 1;
    if (end >= next) return error.InvalidCursor;
    if (request.after != 0) {
        _ = proposal(a, session, request.after) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.* = .{ .end = end };
    var rows: Collected(proposal_positions.Row, protocol.proposal_page_items + 1) = .{};
    a.readEach(proposal_positions, .{ .session = session, .after = request.after, .end = end }, rows.items.len, &rows);
    a.run() catch |err| return if (err == error.StatementFailed) error.ProposalReadFailed else err;
    page.more = rows.len > page.items.len;
    for (rows.slice()[0..@min(rows.len, page.items.len)]) |row| {
        page.items[page.count] = (try proposal(a, session, row.session_position.get())).metadata;
        page.count += 1;
    }
}

pub const ProposalIdentity = struct { metadata: protocol.ProposalMetadata, content_ids: [3]i64 };

/// The content columns of a Proposal's three fields, in ProposalField order.
const proposal_fields = [3][]const u8{ "name_content_id", "call_id_content_id", "arguments_content_id" };

// The page, continuation cursor and byte route share one provenance check.
// LEFT JOIN keeps missing/contradictory owners visible as corruption.
/// The Proposal at a Session position, with each field's content row.
pub const proposal_row = rsql.Read(.{
    .sql = "SELECT item.operation_id,op.turn_id,tool_call.call_ordinal,action.action_id,tool_call.rejection_code," ++
        "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id," ++
        "CASE WHEN op.session_ref=item.session_ref AND t.session_ref=item.session_ref AND " ++
        store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " AND op.attempt_ordinal=item.attempt_ordinal AND " ++
        "((tool_call.rejection_code IS NOT NULL AND action.action_id IS NULL AND tool_call.acceptance_position IS NOT NULL AND " ++
        "rejection.content_id IS NOT NULL AND rejection.private=0) OR " ++
        "(tool_call.rejection_code IS NULL AND action.action_id IS NOT NULL AND action.session_ref=item.session_ref)) " ++
        "THEN 1 ELSE 0 END AS consistent,tool_call.field_metadata," ++
        "field0.byte_length AS length0,field0.digest AS digest0,field0.private AS private0," ++
        "field1.byte_length AS length1,field1.digest AS digest1,field1.private AS private1," ++
        "field2.byte_length AS length2,field2.digest AS digest2,field2.private AS private2 FROM model_output_item item " ++
        "LEFT JOIN model_operation op ON op.operation_id=item.operation_id LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
        "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
        "LEFT JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "LEFT JOIN content field0 ON field0.content_id=tool_call." ++ proposal_fields[0] ++ " " ++
        "LEFT JOIN content field1 ON field1.content_id=tool_call." ++ proposal_fields[1] ++ " " ++
        "LEFT JOIN content field2 ON field2.content_id=tool_call." ++ proposal_fields[2] ++ " " ++
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
    .cardinality = .optional,
});

/// Queues reading the Proposal at `position`; `proposalIdentity` follows
/// its round.
pub fn readProposal(a: anytype, session: []const u8, position: u64, destination: *proposal_row.Result) void {
    a.read(proposal_row, .{ .session = session, .position = position }, destination);
}

/// The identity of the Proposal a `readProposal` round found at `position`.
/// Each field's content must be public and match the metadata admission
/// certified, so reference substitution is detectable without reopening
/// payloads.
pub fn proposalIdentity(found: proposal_row.Result, position: u64) error{ ContentNotFound, CorruptStore }!ProposalIdentity {
    const row = found orelse return error.ContentNotFound;
    if (!row.consistent) return error.CorruptStore;
    var result: ProposalIdentity = .{ .metadata = .{
        .position = position,
        .operation = row.operation_id.get(),
        .turn = row.turn_id.get(),
        .call_ordinal = row.call_ordinal,
        .action = if (row.action_id) |action| action.get() else null,
        .rejection = row.rejection_code,
        .fields = undefined,
    }, .content_ids = undefined };
    inline for (proposal_fields, 0..) |column, index| {
        const suffix = std.fmt.comptimePrint("{d}", .{index});
        const length: u64 = @field(row, "length" ++ suffix);
        const digest: [32]u8 = @field(row, "digest" ++ suffix);
        const certified = row.field_metadata[index * 40 ..][0..40];
        if (@field(row, "private" ++ suffix) or length != std.mem.readInt(u64, certified[0..8], .little) or
            !std.mem.eql(u8, &digest, certified[8..40])) return error.CorruptStore;
        result.content_ids[index] = @intCast(@field(row, column).get());
        result.metadata.fields[index] = .{ .length = length, .digest = digest };
    }
    return result;
}

/// `readProposal` and `proposalIdentity` in a round of their own.
pub fn proposal(a: anytype, session: []const u8, position: u64) !ProposalIdentity {
    var found: proposal_row.Result = undefined;
    readProposal(a, session, position, &found);
    try a.run();
    return proposalIdentity(found, position);
}

/// `proposal` for unconverted code (`report.zig`). Not inlined, so its
/// Access takes no slot in the report's frame.
pub noinline fn proposalLocked(self: *Store, session: []const u8, position: u64) !ProposalIdentity {
    var a = ReadAccess.within(self);
    defer a.deinit();
    return proposal(&a, session, position);
}

pub fn openProposalField(a: *ReadAccess, request: *const protocol.ReadProposalField) !ContentLocation {
    const identity = proposal(a, request.session.slice(), request.position) catch |err| switch (err) {
        error.ContentNotFound => return err,
        else => return store_core.fence(a.store, err),
    };
    const index = @backingInt(request.field);
    const field = identity.metadata.fields[index];
    return .{ .store = a.store, .content_id = identity.content_ids[index], .reference = .{ .length = field.length, .digest = field.digest } };
}
