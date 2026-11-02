//! Public reads: Session inspection, conversation pages, activity, person
//! messages and proposals, and the content they open.

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
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const AttemptBinding = store_core.AttemptBinding;
const ContentLocation = content_domain.ContentLocation;
const ContentMetadata = content_domain.ContentMetadata;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const SessionReportCapture = report_domain.SessionReportCapture;
const TurnOutcome = turn_domain.TurnOutcome;
const accepted_resolutions = store_schema.accepted_resolutions;

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
        "SELECT admission_position AS position,0 AS ordinal,1 AS kind,admission_id AS id FROM message_admission INDEXED BY message_admission_position " ++
            "WHERE session_ref=?1 AND " ++ range("admission_position", "0") ++
            " UNION ALL SELECT session_position,0,CASE entry_kind WHEN 1 THEN 2 ELSE 3 END,source_admission_id FROM conversation_entry " ++
            "WHERE session_ref=?1 AND entry_kind IN (1,3) AND " ++ range("session_position", "0") ++
            " UNION ALL SELECT session_position,0,4,NULL FROM model_output_item INDEXED BY model_output_call_history " ++
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
            " UNION ALL SELECT outcome_position,0,6,turn_id FROM turn INDEXED BY turn_outcome_position WHERE session_ref=?1 AND outcome_code IS NOT NULL AND " ++ range("outcome_position", "0") ++
            " UNION ALL SELECT position,0,7,NULL FROM session_stop INDEXED BY session_stop_position WHERE session_ref=?1 AND " ++ range("position", "0") ++ order,
        "SELECT sender_position AS position,0 AS ordinal,9 AS kind,NULL AS id FROM sent_rejection WHERE sender_session_ref=?1 AND " ++ range("sender_position", "0") ++
            " UNION ALL SELECT session_position,0,10,NULL FROM model_output_item INDEXED BY model_output_hosted_history " ++
            "WHERE session_ref=?1 AND item_kind=5 AND " ++ range("session_position", "0") ++ order,
    };
}

fn anyActivityPosition(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
    _ = ordinal;
    return position ++ " IS NOT NULL";
}

/// The Activity row at position ?3 and ordinal ?4 through end ?2: each
/// source seeks that one position.
const activity_item_sql = blk: {
    const sources = activitySources(anyActivityPosition, "");
    break :blk std.fmt.comptimePrint("WITH entries AS ({s}), completions AS ({s}), " ++
        "activity AS (SELECT * FROM entries UNION ALL SELECT * FROM completions UNION ALL {s}) " ++
        "SELECT kind,id FROM activity WHERE position=?3 AND ordinal=?4 AND position<=?2", .{ sources[0], sources[1], sources[2] });
};

/// One Activity page, at most 17 rows past cursor (?3, ?4) through end ?2,
/// in `forward` order. Each source group keeps its own first 17 rows, read
/// in order from its indexes, and the page takes the first 17 of those:
/// the cost follows the page, not the Session's history.
fn activityPageSql(comptime forward: bool) [:0]const u8 {
    const Range = struct {
        fn after(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
            return position ++ ">=?3 AND " ++ position ++ "<=?2 AND (" ++ position ++ ">?3 OR " ++ ordinal ++ ">?4)";
        }
        fn before(comptime position: []const u8, comptime ordinal: []const u8) []const u8 {
            return position ++ "<=?3 AND (" ++ position ++ "<?3 OR " ++ ordinal ++ "<?4)";
        }
    };
    const order = if (forward) " ORDER BY 1,2 LIMIT 17" else " ORDER BY 1 DESC,2 DESC LIMIT 17";
    const sources = activitySources(if (forward) Range.after else Range.before, order);
    return std.fmt.comptimePrint("SELECT position,ordinal FROM ({s}) UNION ALL SELECT position,ordinal FROM ({s}) " ++
        "UNION ALL SELECT position,ordinal FROM ({s}){s}", .{ sources[0], sources[1], sources[2], order });
}
/// Nullable columns permit corruption detection; no writer may omit one.
/// Each partial index is empty in a sound Store, so every activity read
/// checks the whole Session in a few steps, however long its history.
pub const activity_sequence_guard_sql = "SELECT 1 FROM message_admission INDEXED BY message_admission_unpositioned WHERE session_ref=?1 AND admission_position IS NULL " ++
    "UNION ALL SELECT 1 FROM session_stop INDEXED BY session_stop_unpositioned WHERE session_ref=?1 AND position IS NULL " ++
    "UNION ALL SELECT 1 FROM turn INDEXED BY turn_unpositioned WHERE session_ref=?1 AND ((outcome_code IS NULL)!=(outcome_position IS NULL)) LIMIT 1";
/// See `Store.readQueuedLocked`.
pub const queued_sql = "SELECT m.admission_id,m.admission_position," ++
    "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.source_admission_id=m.admission_id AND e.session_position<=?2) OR " ++
    "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=?1 AND s.admission_cutoff>=m.admission_id AND s.position<=?2) " ++
    "FROM message_admission m INDEXED BY message_admission_person WHERE m.session_ref=?1 AND m.sender_session_ref IS NULL " ++
    "AND m.admission_position<=?2 ORDER BY m.admission_position DESC";

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

pub fn inspectSessionLocked(self: *Store, session_ref: []const u8, observation: *SessionObservation) !void {
    var current: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    if (!try configuration_domain.readSession(self, session_ref, &current)) {
        observation.* = .{};
        return;
    }
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
    if (current.instructions_id) |content_id| {
        const metadata = try content_domain.readContentMetadata(self, content_id);
        observation.instructions = .{ .length = metadata.length, .digest = metadata.digest };
    }
    if (current.output_schema_id) |content_id| {
        const metadata = try content_domain.readContentMetadata(self, content_id);
        observation.output_schema = .{ .length = metadata.length, .digest = metadata.digest };
    }
    observation.pending_messages = try command_domain.countPendingMessages(self, session_ref);
    try report_domain.validateActiveTurnToolCalls(self, session_ref);
    observation.action_count = try report_domain.countActions(self, session_ref);
    observation.rejected_call_count = try report_domain.countRejectedCalls(self, session_ref);
}

pub fn publicConversationPageLocked(self: *Store, request: *const protocol.ConversationPage, page: *PublicConversationPage) !void {
    if (request.end > std.math.maxInt(i64) or request.before_position > std.math.maxInt(i64) or
        request.before_ordinal > std.math.maxInt(i64) or
        (request.end == 0 and request.before_position != 0) or
        (request.before_position == 0 and request.before_ordinal != 0) or
        (request.end != 0 and request.before_position > request.end)) return error.InvalidCursor;
    const next_position = (try turn_domain.sessionNextPosition(self, request.session.slice())) orelse return error.SessionNotFound;
    const end = if (request.end == 0) next_position - 1 else request.end;
    if (request.end != 0 and (request.before_position > end or end >= next_position or
        end > std.math.maxInt(i64))) return error.InvalidCursor;
    if (request.before_position != 0) cursor: {
        // A cursor names an item: a hosted call, or an item with content.
        if (request.before_ordinal == 0) if (hostedCallLocked(self, request.session.slice(), request.before_position)) |_| break :cursor else |err| switch (err) {
            error.ContentNotFound => {},
            else => return err,
        };
        _ = publicConversationContentLocked(self, request.session.slice(), request.before_position, request.before_ordinal) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.* = .{ .end = end };
    if (end == 0) return;
    // Tool outcomes enter public Conversation only when the entire group
    // settles. Position is then its last acceptance; call ordinal is the
    // stable tie breaker. Private model items/instructions never enter it.
    const statement = try store_core.cached(self, public_tool_groups_sql ++
        "public AS (SELECT e.session_position AS position,0 AS ordinal,e.entry_kind AS kind,e.content_id " ++
        "FROM conversation_entry e WHERE e.session_ref=?1 AND e.entry_kind IN (1,3) AND e.session_position<=?2 " ++
        "UNION ALL SELECT tool_groups.position,tool_call.call_ordinal+1,4,coalesce(tool_call.rejection_content_id,action.resolution_content_id) " ++
        "FROM tool_groups JOIN model_tool_call tool_call ON tool_call.operation_id=tool_groups.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE tool_groups.position<=?2 " ++
        // A hosted call is public at its own item's position.
        "UNION ALL SELECT item.session_position,0,5,NULL FROM model_output_item item INDEXED BY model_output_hosted_history WHERE item.session_ref=?1 AND item.item_kind=5 AND item.session_position<=?2) " ++
        "SELECT position,ordinal,kind,content_id FROM public WHERE (?3=0 OR position<?3 OR (position=?3 AND ordinal<?4)) " ++
        "ORDER BY position DESC,ordinal DESC LIMIT 17");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, request.session.slice());
    try sqlite.bindU64(statement, 2, end);
    try sqlite.bindU64(statement, 3, request.before_position);
    try sqlite.bindU64(statement, 4, request.before_ordinal);
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) break;
        if (result != c.SQLITE_ROW) return error.ConversationReadFailed;
        if (page.count == page.items.len) {
            page.more = true;
            break;
        }
        const position = c.sqlite3_column_int64(statement, 0);
        const ordinal = c.sqlite3_column_int64(statement, 1);
        const kind = c.sqlite3_column_int(statement, 2);
        if (kind == 5) {
            if (position <= 0 or ordinal != 0) return error.CorruptStore;
            const call = try hostedCallLocked(self, request.session.slice(), @intCast(position));
            page.items[page.count] = .{ .position = @intCast(position), .ordinal = 0, .kind = .hosted_call, .content = .{ .length = 0, .digest = protocol.contentDigest("") }, .presentation = call.presentation };
            page.count += 1;
            continue;
        }
        const content_id = c.sqlite3_column_int64(statement, 3);
        if (position <= 0 or ordinal < 0 or content_id <= 0 or
            (kind != 1 and kind != 3 and kind != 4) or
            (kind == 4) != (ordinal > 0)) return error.CorruptStore;
        // Do not filter damaged rows out of SQL: validate ordinary
        // producers and the exposed content before publishing metadata.
        const resolved = try publicConversationContentLocked(self, request.session.slice(), @intCast(position), @intCast(ordinal));
        if (resolved.id != content_id or (kind == 1) != (resolved.admitted_at != null)) return error.CorruptStore;
        const metadata = resolved.metadata;
        page.items[page.count] = .{ .position = @intCast(position), .ordinal = @intCast(ordinal), .kind = switch (kind) {
            1 => .user,
            3 => .assistant,
            4 => .tool_result,
            else => unreachable,
        }, .content = .{ .length = metadata.length, .digest = metadata.digest }, .admitted_at = resolved.admitted_at, .sender = if (resolved.sender) |sender| try peerNamed(self, sender) else null, .presentation = if (resolved.tool_operation) |operation| try toolPresentationLocked(self, operation, @intCast(ordinal - 1), @intCast(position)) else null };
        page.count += 1;
    }
    const upper = if (request.before_position == 0) end else @min(end, request.before_position - @intFromBool(request.before_ordinal == 0));
    try validateAssistantEntries(self, request.session.slice(), if (page.more) page.items[page.count - 1].position else 0, upper);
}

pub fn openPublicConversationContentLocked(self: *Store, request: *const protocol.ConversationContent) !ContentLocation {
    if (request.position == 0 or request.position > std.math.maxInt(i64) or
        request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
    const content = try publicConversationContentLocked(self, request.session.slice(), request.position, request.ordinal);
    if (request.start > content.metadata.length) return error.RangeOutOfBounds;
    return .{ .store = self, .content_id = content.id, .reference = .{ .length = content.metadata.length, .digest = content.metadata.digest } };
}

// Accepted assistant messages require entries even when a damaged entry
// would disappear from an inventory rooted in conversation_entry. Inspect
// only the requested position interval through the existing history index.
// Compaction messages deliberately have no Conversation certificate.
pub fn validateAssistantEntries(self: *Store, session: []const u8, lower: u64, upper: u64) !void {
    if (lower > upper) return;
    const statement = try store_core.cached(self, "SELECT 1 FROM model_output_item item JOIN model_operation op ON op.operation_id=item.operation_id " ++
        "LEFT JOIN conversation_entry e ON e.session_ref=item.session_ref AND e.session_position=item.session_position " ++
        "WHERE item.session_ref=?1 AND item.session_position BETWEEN ?2 AND ?3 AND item.item_kind=2 " ++
        "AND op.purpose=0 AND " ++ store_schema.oneOf("op.resolution_code", &accepted_resolutions) ++
        " AND CASE WHEN e.entry_kind=3 AND e.source_operation_id=item.operation_id AND e.source_item_ordinal=item.item_ordinal " ++
        "AND e.content_id=item.message_content_id AND e.turn_id=op.turn_id AND op.session_ref=item.session_ref " ++
        "AND item.attempt_ordinal=op.attempt_ordinal THEN 0 ELSE 1 END=1 LIMIT 1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, lower);
    try sqlite.bindU64(statement, 3, upper);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => return error.CorruptStore,
        else => return error.ConversationReadFailed,
    }
}

// A cursor and a byte reader resolve the same public identity and exposed
// metadata. Neither may accept a private or absent canonical result.
/// `at` is when the entry was recorded, or, for a Tool Result, when its
/// group's last call was accepted.
pub fn publicConversationContentLocked(self: *Store, session: []const u8, position: u64, ordinal: u64) !struct { id: i64, metadata: ContentMetadata, tool_operation: ?u64, admitted_at: ?u64, sender: ?protocol.Bounded(protocol.max_session_bytes) = null, at: u64 } {
    if (ordinal == 0) try validateAssistantEntries(self, session, position, position);
    // One indexed ordinary identity owns provenance for pages, cursors and
    // bytes. LEFT JOIN retains damage instead of hiding dependencies.
    const statement = if (ordinal == 0) try store_core.cached(
        self,
        "SELECT e.content_id,CASE WHEN c.content_id IS NOT NULL AND c.private=0 AND t.session_ref=e.session_ref AND " ++
            "((e.entry_kind=1 AND m.session_ref=e.session_ref AND m.turn_id=e.turn_id AND m.content_id=e.content_id) OR " ++
            "(e.entry_kind=3 AND o.purpose=0 AND o.session_ref=e.session_ref AND o.turn_id=e.turn_id " ++
            "AND item.item_kind=2 AND item.message_content_id=e.content_id AND item.session_ref=e.session_ref " ++
            "AND item.session_position=e.session_position AND item.attempt_ordinal=o.attempt_ordinal " ++
            "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ ")) THEN 1 ELSE 0 END," ++
            "CASE WHEN e.entry_kind=1 THEN m.admitted_at END,CASE WHEN e.entry_kind=1 THEN m.sender_session_ref END,e.recorded_at FROM conversation_entry e LEFT JOIN turn t ON t.turn_id=e.turn_id " ++
            "LEFT JOIN message_admission m ON m.admission_id=e.source_admission_id " ++
            "LEFT JOIN model_operation o ON o.operation_id=e.source_operation_id " ++
            "LEFT JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
            "LEFT JOIN content c ON c.content_id=e.content_id " ++
            "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind IN(1,3)",
    ) else try store_core.cached(
        self,
        "SELECT coalesce(tool_call.rejection_content_id,action.resolution_content_id),NOT EXISTS(SELECT 1 FROM model_tool_call linked " ++
            "LEFT JOIN model_output_item item ON item.operation_id=linked.operation_id AND item.item_ordinal=linked.item_ordinal LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
            "LEFT JOIN content rejection ON rejection.content_id=linked.rejection_content_id " ++
            "LEFT JOIN action_operation a ON a.parent_operation_id=linked.operation_id AND a.call_ordinal=linked.call_ordinal " ++
            "LEFT JOIN content result ON result.content_id=a.resolution_content_id " ++
            "WHERE linked.operation_id=op.operation_id AND CASE WHEN item.item_kind=3 AND item.session_ref=op.session_ref AND t.session_ref=op.session_ref " ++
            "AND item.attempt_ordinal=op.attempt_ordinal AND " ++
            "((linked.rejection_code IS NOT NULL AND a.action_id IS NULL AND rejection.private=0) OR (linked.rejection_code IS NULL AND a.action_id IS NOT NULL AND a.session_ref=op.session_ref AND result.private=0)) THEN 0 ELSE 1 END=1),op.operation_id,tool_call.call_ordinal," ++
            // A rejected call is accepted when its Operation resolves; an
            // Action call when the Action does. The last acceptance is the
            // one at the greatest position: times order nothing.
            "(SELECT coalesce(a.resolved_at,op.resolved_at) FROM model_tool_call c LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal " ++
            "WHERE c.operation_id=op.operation_id ORDER BY coalesce(c.acceptance_position,a.acceptance_position) DESC LIMIT 1) " ++
            // Only an Operation with an acceptance at the position can
            // complete there.
            "FROM (SELECT operation_id FROM model_tool_call WHERE session_ref=?1 AND acceptance_position=?2 " ++
            "UNION ALL SELECT parent_operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position=?2) last " ++
            "CROSS JOIN model_operation op ON op.operation_id=last.operation_id " ++
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
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, position);
    if (ordinal != 0) try sqlite.bindU64(statement, 3, ordinal);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return error.ContentNotFound,
        else => return if (ordinal == 0) error.ConversationReadFailed else error.PublicContentReadFailed,
    }
    if (c.sqlite3_column_int(statement, 1) != 1) return error.CorruptStore;
    const content_id = c.sqlite3_column_int64(statement, 0);
    if (content_id <= 0) return error.CorruptStore;
    const operation: ?u64 = if (ordinal == 0) null else @intCast(try sqlite.readNullablePositiveI64(statement, 2) orelse return error.CorruptStore);
    if (operation) |op| _ = try report_domain.readToolOutcomeFacts(self, op, true);
    const admitted_at: ?u64 = if (ordinal == 0) if (try sqlite.readNullablePositiveI64(statement, 2)) |second| @intCast(second) else null else null;
    var sender: ?protocol.Bounded(protocol.max_session_bytes) = null;
    if (ordinal == 0 and c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL) {
        sender = .{};
        try sqlite.readText(statement, 3, &sender.?);
    }
    const at: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 4) orelse return error.CorruptStore);
    return .{ .id = content_id, .metadata = try content_domain.readPublicContentMetadata(self, content_id), .tool_operation = operation, .admitted_at = admitted_at, .sender = sender, .at = at };
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

fn toolPresentationLocked(self: *Store, operation: u64, ordinal: u64, publication_position: ?u64) !protocol.ToolPresentation {
    const statement = try store_core.cached(self, "SELECT tool_call.description,coalesce(tool_call.rejection_code,a.resolution_code),a.authorized,item.session_ref,item.session_position FROM model_tool_call tool_call LEFT JOIN action_operation a ON a.parent_operation_id=tool_call.operation_id AND a.call_ordinal=tool_call.call_ordinal LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal WHERE tool_call.operation_id=?1 AND tool_call.call_ordinal=?2");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation);
    try sqlite.bindU64(statement, 2, ordinal);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 3, &session);
    const position = try sqlite.readNullablePositiveI64(statement, 4) orelse return error.CorruptStore;
    _ = try proposalLocked(self, session.slice(), @intCast(position));
    var result: protocol.ToolPresentation = .{ .description = null, .code = .unresolved, .publication_position = publication_position };
    if (c.sqlite3_column_type(statement, 0) != c.SQLITE_NULL) {
        var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
        try sqlite.readText(statement, 0, &description);
        if (!protocol.ToolPresentation.validDescription(description.slice())) return error.CorruptStore;
        result.description = description;
    }
    if (c.sqlite3_column_type(statement, 1) != c.SQLITE_NULL) {
        var code: protocol.Bounded(32) = .{};
        try sqlite.readText(statement, 1, &code);
        result.code = std.meta.stringToEnum(protocol.ToolPresentation.Code, code.slice()) orelse return error.CorruptStore;
    } else if (c.sqlite3_column_int(statement, 2) == 0) result.code = .pending_permission;
    if (result.description == null) switch (result.code) {
        .unknown_tool, .invalid_arguments => {},
        else => return error.CorruptStore,
    };
    return result;
}

/// The hosted tool call at `position`, as an accepted Operation's output
/// recorded it: its line, its outcome and when its Operation resolved.
pub fn hostedCallLocked(self: *Store, session: []const u8, position: u64) !struct { presentation: protocol.ToolPresentation, at: u64 } {
    const statement = try store_core.cached(self, "SELECT item.description,item.call_failed,op.resolved_at," ++
        "op.session_ref=item.session_ref AND op.attempt_ordinal=item.attempt_ordinal AND op.purpose=0 AND " ++
        store_schema.oneOf("op.resolution_code", &accepted_resolutions) ++
        " FROM model_output_item item INDEXED BY model_output_hosted_history LEFT JOIN model_operation op ON op.operation_id=item.operation_id " ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=5");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, position);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return error.ContentNotFound,
        else => return error.ActivityReadFailed,
    }
    if (c.sqlite3_column_int(statement, 3) != 1) return error.CorruptStore;
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try sqlite.readText(statement, 0, &description);
    if (!protocol.ToolPresentation.validDescription(description.slice())) return error.CorruptStore;
    return .{
        .presentation = .{ .description = description, .code = if (c.sqlite3_column_int(statement, 1) != 0) .failed else .succeeded, .publication_position = position },
        .at = @intCast(try sqlite.readNullablePositiveI64(statement, 2) orelse return error.CorruptStore),
    };
}

pub fn appendToolPresentation(self: *Store, operation: u64, ordinal: u64, publication_position: ?u64, capture: *SessionReportCapture) !void {
    const presentation = try toolPresentationLocked(self, operation, ordinal, publication_position);
    var buffer: [protocol.ToolPresentation.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try presentation.writeJson(&writer);
    try capture.append(",\"presentation\":");
    try capture.append(writer.buffered());
}

pub fn activityPageLocked(self: *Store, request: *const protocol.ActivityPage, page: *protocol.ActivityFacts) !void {
    page.* = .{ .end = 0, .direction = request.direction, .work = .{ .workspace = .{ .len = 0 } } };
    const session = (try configuration_domain.readSessionFacts(self, request.session.slice(), &page.work.workspace)) orelse return error.SessionNotFound;
    const end = request.end orelse session.next_position - 1;
    if (end >= session.next_position or request.position > end) return error.InvalidCursor;
    try validateActivitySequence(self, request.session.slice());
    if (request.ordinal) |ordinal| {
        _ = activityItemLocked(self, request.session.slice(), end, request.position, ordinal) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.end = end;
    // The cursor as a bound on (position, ordinal): a whole position is
    // passed or kept by the largest ordinal, and a backward page with
    // no cursor starts after the end's last row.
    const forward = request.direction == .forward;
    const statement = if (forward) try store_core.cached(self, comptime activityPageSql(true)) else try store_core.cached(self, comptime activityPageSql(false));
    defer sqlite.resetCached(statement);
    const whole: u64 = std.math.maxInt(i64);
    try sqlite.bindText(statement, 1, request.session.slice());
    try sqlite.bindU64(statement, 2, end);
    try sqlite.bindU64(statement, 3, if (forward or request.position != 0) request.position else end);
    try sqlite.bindU64(statement, 4, if (forward) request.ordinal orelse whole else if (request.position == 0) whole else request.ordinal orelse 0);
    page.read_through = try readThroughLocked(self, request.session.slice());
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) break;
        if (result != c.SQLITE_ROW) return error.ActivityReadFailed;
        const position = try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore;
        if (page.count == page.items.len) {
            page.more = true;
            // The row after a backward page's oldest says whether the
            // unseen rows reach past it.
            page.beyond_unseen = !forward and if (page.read_through) |read| @as(u64, @intCast(position)) > read else true;
            break;
        }
        const ordinal = c.sqlite3_column_int64(statement, 1);
        if (ordinal < 0) return error.CorruptStore;
        page.items[page.count] = (try activityItemLocked(self, request.session.slice(), end, @intCast(position), @intCast(ordinal))).item;
        page.count += 1;
    }
    const boundary = if (page.more) &page.items[page.count - 1] else null;
    const lower = if (request.direction == .forward) request.position + 1 else if (boundary) |item| item.position else 0;
    const upper = if (request.direction == .forward) (if (boundary) |item| item.position else end) else if (request.position == 0) end else @min(end, request.position - @intFromBool((request.ordinal orelse 0) == 0));
    try validateAssistantEntries(self, request.session.slice(), lower, upper);
    const last = if (request.direction == .forward) boundary else null;
    page.call_activity = try readCallActivityLocked(self, request.session.slice(), if (last) |item| item.position else end, if (last) |item| item.ordinal else null);
    page.queued = try readQueuedLocked(self, request.session.slice(), if (last) |item| item.position else end);
    // Work as of this same read, so the footer, consent and first Action
    // always describe the page they arrive with.
    const work = (try report_domain.readWorkLocked(self, request.session.slice(), session.created_at, try store_core.readUnixMilliseconds(self.io))).work;
    page.work.work = .fromCore(work);
    page.work.revision = session.revision;
}

fn readThroughLocked(self: *Store, session: []const u8) !?u64 {
    const statement = try store_core.cached(self, "SELECT read_through FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SessionReadFailed;
    return if (try sqlite.readNullablePositiveI64(statement, 0)) |position| @intCast(position) else null;
}

pub fn markReadLocked(self: *Store, request: *const protocol.MarkRead) !void {
    const session = request.session.slice();
    const statement = try store_core.cached(self, "UPDATE session SET read_through=?2 WHERE session_ref=?1 AND ?2<next_position AND (read_through IS NULL OR read_through<?2)");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, request.position);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) == 1) return;
    const next_position = (try turn_domain.sessionNextPosition(self, session)) orelse return error.SessionNotFound;
    if (request.position >= next_position) return error.PositionNotReached;
}

pub fn personMessageLocked(self: *Store, request: *const protocol.ReadPersonMessage) !protocol.PersonMessage {
    const next_position = (try turn_domain.sessionNextPosition(self, request.session.slice())) orelse return error.SessionNotFound;
    const end = request.end orelse next_position - 1;
    if (end >= next_position or request.position > end) return error.InvalidCursor;
    const select = "SELECT admission_position,content_id FROM message_admission INDEXED BY message_admission_person " ++
        "WHERE session_ref=?1 AND sender_session_ref IS NULL AND admission_position>?2 AND admission_position<?3 ORDER BY admission_position";
    const backward = request.direction == .backward;
    const statement = if (backward) try store_core.cached(self, select ++ " DESC LIMIT 1") else try store_core.cached(self, select ++ " LIMIT 1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, request.session.slice());
    try sqlite.bindU64(statement, 2, if (backward) 0 else request.position);
    try sqlite.bindU64(statement, 3, if (backward and request.position != 0) request.position else end + 1);
    var reply: protocol.PersonMessage = .{ .end = end };
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => return reply,
        c.SQLITE_ROW => {},
        else => return error.ActivityReadFailed,
    }
    const position: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore);
    const metadata = try content_domain.readPublicContentMetadata(self, try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore);
    reply.message = .{ .position = position, .content = .{ .length = metadata.length, .digest = metadata.digest } };
    return reply;
}

// This projection shares the page's canonical capture, not Current's active
// Turn lifetime. It is staged until the frontend acknowledges that page.
fn readCallActivityLocked(self: *Store, session: []const u8, position: u64, ordinal: ?u64) !protocol.CallActivity {
    // A group still waiting has an Action without its result; one that
    // completes after the page has an acceptance after it. Only those
    // Operations are grouped, not the Session's history.
    const statement = try store_core.cached(self, "WITH ops AS (SELECT parent_operation_id AS operation_id FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NULL " ++
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
        "SELECT operation_id,call_ordinal,position FROM candidates ORDER BY operation_id,call_ordinal");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, position);
    try sqlite.bindNullableU64(statement, 3, ordinal);
    var result: protocol.CallActivity = .{};
    var last_operation: u64 = 0;
    var publication: ?u64 = null;
    while (true) {
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) break;
        if (step != c.SQLITE_ROW) return error.CallReadFailed;
        const operation: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore);
        const call_ordinal = c.sqlite3_column_int64(statement, 1);
        if (c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL or call_ordinal < 0) return error.CorruptStore;
        if (last_operation != operation) {
            publication = (try report_domain.readToolOutcomeFacts(self, operation, false)).position;
            const projected = try sqlite.readNullablePositiveI64(statement, 2);
            if (publication != (if (projected) |p| @as(u64, @intCast(p)) else null)) return error.CorruptStore;
            last_operation = operation;
        }
        result.total = try std.math.add(u64, result.total, 1);
        if (result.count == result.entries.len) continue;
        result.entries[result.count] = .{ .operation = operation, .ordinal = @intCast(call_ordinal), .presentation = try toolPresentationLocked(self, operation, @intCast(call_ordinal), publication) };
        result.count += 1;
    }
    return result;
}

/// The Messages a person or script sent that were admitted at or before
/// `position` and not taken there. Selection and a stop's exclusion take
/// admission-order prefixes, and Admission positions follow admission
/// order, so the walk seeks `position` and goes down, ending at the first
/// one taken: it reads those waiting and one more. Every Message at
/// `position` precedes its tool completions, so a boundary's ordinal
/// changes nothing.
pub fn readQueuedLocked(self: *Store, session: []const u8, position: u64) !protocol.Queued {
    const statement = try store_core.cached(self, queued_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, position);
    var queued: protocol.Queued = .{};
    while (true) {
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) break;
        if (step != c.SQLITE_ROW) return error.ActivityReadFailed;
        if (c.sqlite3_column_int(statement, 2) == 1) break;
        const admission: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore);
        const admitted: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore);
        if (queued.count == 0) {
            queued.newest_admission = admission;
            queued.newest_position = admitted;
        }
        queued.count += 1;
        queued.oldest_position = admitted;
    }
    return queued;
}

fn validateActivitySequence(self: *Store, session: []const u8) !void {
    const guard = try store_core.cached(self, activity_sequence_guard_sql);
    defer sqlite.resetCached(guard);
    try sqlite.bindText(guard, 1, session);
    if (c.sqlite3_step(guard) != c.SQLITE_DONE) return error.CorruptStore;
}

fn activityMessageLocked(self: *Store, session: []const u8, end: u64, admission: u64) !struct { message: protocol.ActivityItem.Message, content_id: i64 } {
    const statement = try store_core.cached(self, "SELECT m.command_key,m.turn_id,m.content_id," ++
        "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=m.session_ref AND e.source_admission_id=m.admission_id AND e.session_position<=?2)," ++
        "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=m.session_ref AND s.admission_cutoff>=m.admission_id AND s.position<=?2)," ++
        "c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id " ++
        "AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
        "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))),m.admitted_at,m.sender_session_ref FROM message_admission m " ++
        "LEFT JOIN core_command c ON c.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "WHERE m.session_ref=?1 AND m.admission_id=?3");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, end);
    try sqlite.bindU64(statement, 3, admission);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_int(statement, 5) != 1) return error.CorruptStore;
    const applied = c.sqlite3_column_int(statement, 3) == 1;
    const content_id = try sqlite.readNullablePositiveI64(statement, 2) orelse return error.CorruptStore;
    const metadata = try content_domain.readPublicContentMetadata(self, content_id);
    var message: protocol.ActivityItem.Message = .{ .admission = admission, .key = .{}, .turn = null, .state = if (applied) .applied else if (c.sqlite3_column_int(statement, 4) == 1) .excluded else .queued, .content = .{ .length = metadata.length, .digest = metadata.digest }, .admitted_at = @intCast(try sqlite.readNullablePositiveI64(statement, 6) orelse return error.CorruptStore) };
    try sqlite.readText(statement, 0, &message.key);
    if (applied) message.turn = @intCast(try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore);
    message.sender = if (try readPeer(statement, 7)) |sender| try peerNamed(self, sender.session) else null;
    return .{ .message = message, .content_id = content_id };
}

pub fn readPeer(statement: *c.sqlite3_stmt, column: c_int) !?protocol.Peer {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) return null;
    var sender: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, column, &sender);
    return .{ .session = sender };
}

/// A peer Session with its label as the Store holds it now, so a rename
/// shows on every row that names it. One indexed lookup per peer row.
pub fn peerNamed(self: *Store, session: protocol.Bounded(protocol.max_session_bytes)) !protocol.NamedPeer {
    const statement = try store_core.cached(self, "SELECT label FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session.slice());
    var peer: protocol.NamedPeer = .{ .session = session };
    switch (c.sqlite3_step(statement)) {
        // A failed send can name a Session this Store never held.
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => if (try sqlite.readNullableLabel(statement, 0)) |label| {
            peer.label = label;
        },
        else => return error.CorruptStore,
    }
    return peer;
}

const ActivityIdentity = struct { item: protocol.ActivityItem, content_id: ?i64 = null };

fn activityItemLocked(self: *Store, session: []const u8, end: u64, position: u64, ordinal: u64) !ActivityIdentity {
    if (ordinal == 0 and position <= end) try validateAssistantEntries(self, session, position, position);
    const statement = try store_core.cached(self, activity_item_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, end);
    try sqlite.bindU64(statement, 3, position);
    try sqlite.bindU64(statement, 4, ordinal);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.ContentNotFound;
    if (step != c.SQLITE_ROW) return error.ActivityReadFailed;
    // Each kind reads `at` from the row that owns its fact.
    var result: ActivityIdentity = .{ .item = .{ .position = position, .ordinal = ordinal, .at = undefined, .value = undefined } };
    switch (c.sqlite3_column_int(statement, 0)) {
        1, 2 => |kind| {
            const admission = try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
            const owned = try activityMessageLocked(self, session, end, @intCast(admission));
            const message = owned.message;
            if (kind == 2 and message.state != .applied) return error.CorruptStore;
            result.item.value = if (kind == 1) .{ .admission = message } else .{ .user = message };
            result.content_id = owned.content_id;
            result.item.at = message.admitted_at;
            if (kind == 2) {
                const entry = try publicConversationContentLocked(self, session, position, ordinal);
                if (entry.id != result.content_id.?) return error.CorruptStore;
                result.item.at = entry.at;
            }
        },
        3, 5 => |kind| {
            const content = try publicConversationContentLocked(self, session, position, ordinal);
            result.item.at = content.at;
            result.item.value = if (kind == 3) .{ .assistant = .{ .length = content.metadata.length, .digest = content.metadata.digest } } else .{ .tool_result = .{ .content = .{ .length = content.metadata.length, .digest = content.metadata.digest }, .presentation = try toolPresentationLocked(self, content.tool_operation orelse return error.CorruptStore, ordinal - 1, position) } };
            result.content_id = content.id;
        },
        4 => {
            const call = (try proposalLocked(self, session, position)).metadata;
            result.item.value = .{ .call = call };
            const select = try store_core.cached(self, "SELECT resolved_at FROM model_operation WHERE operation_id=?1 AND session_ref=?2");
            defer sqlite.resetCached(select);
            try sqlite.bindU64(select, 1, call.operation);
            try sqlite.bindText(select, 2, session);
            if (c.sqlite3_step(select) != c.SQLITE_ROW) return error.CorruptStore;
            result.item.at = @intCast(try sqlite.readNullablePositiveI64(select, 0) orelse return error.CorruptStore);
        },
        10 => {
            const call = try hostedCallLocked(self, session, position);
            result.item.value = .{ .hosted_call = call.presentation };
            result.item.at = call.at;
        },
        8 => {
            const admission = try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
            const select = try store_core.cached(self, "SELECT m.session_ref,m.content_id,m.admitted_at,c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id " ++
                "FROM message_admission m LEFT JOIN core_command c ON c.command_key=m.command_key WHERE m.admission_id=?1 AND m.sender_session_ref=?2 AND m.sender_position=?3");
            defer sqlite.resetCached(select);
            try sqlite.bindI64(select, 1, admission);
            try sqlite.bindText(select, 2, session);
            try sqlite.bindU64(select, 3, position);
            if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 3) != 1) return error.CorruptStore;
            var target: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(select, 0, &target);
            const content_id = try sqlite.readNullablePositiveI64(select, 1) orelse return error.CorruptStore;
            const metadata = try content_domain.readPublicContentMetadata(self, content_id);
            result.item.value = .{ .sent = .{
                .admission = @intCast(admission),
                .target = try peerNamed(self, target),
                .content = .{ .length = metadata.length, .digest = metadata.digest },
                .admitted_at = @intCast(try sqlite.readNullablePositiveI64(select, 2) orelse return error.CorruptStore),
            } };
            result.item.at = result.item.value.sent.admitted_at;
            result.content_id = content_id;
        },
        9 => {
            const select = try store_core.cached(self, "SELECT s.command_key,c.target,c.code,c.kind=2 AND c.accepted=0,s.rejected_at FROM sent_rejection s " ++
                "LEFT JOIN core_command c ON c.command_key=s.command_key WHERE s.sender_session_ref=?1 AND s.sender_position=?2");
            defer sqlite.resetCached(select);
            try sqlite.bindText(select, 1, session);
            try sqlite.bindU64(select, 2, position);
            if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 3) != 1) return error.CorruptStore;
            var failed: protocol.ActivityItem.SendFailed = .{ .key = .{}, .target = undefined, .code = .{} };
            try sqlite.readText(select, 0, &failed.key);
            var target: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(select, 1, &target);
            failed.target = try peerNamed(self, target);
            try sqlite.readText(select, 2, &failed.code);
            result.item.value = .{ .send_failed = failed };
            result.item.at = @intCast(try sqlite.readNullablePositiveI64(select, 4) orelse return error.CorruptStore);
        },
        6 => {
            const select = try store_core.cached(self, "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.session_ref=t.session_ref AND o.turn_id=t.turn_id " ++
                "AND o.resolution_code IS NOT NULL,o.resolution_content_id,t.outcome_at FROM turn t LEFT JOIN model_operation o ON o.operation_id=t.operation_id WHERE t.session_ref=?1 AND t.outcome_position=?2");
            defer sqlite.resetCached(select);
            try sqlite.bindText(select, 1, session);
            try sqlite.bindU64(select, 2, position);
            if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 4) != 1) return error.CorruptStore;
            var outcome: protocol.ActivityItem.Outcome = .{ .turn = @intCast(try sqlite.readNullablePositiveI64(select, 0) orelse return error.CorruptStore), .operation = @intCast(try sqlite.readNullablePositiveI64(select, 1) orelse return error.CorruptStore), .code = .{}, .content = null };
            try sqlite.readText(select, 2, &outcome.code);
            result.content_id = try sqlite.readNullablePositiveI64(select, 3);
            switch (try TurnOutcome.decode(outcome.code.slice(), result.content_id)) {
                // A completed Turn answers with its causing Operation's Resolution.
                .completed => |content_id| if (try sqlite.readNullablePositiveI64(select, 5) != content_id) return error.CorruptStore,
                .cancelled, .retry_exhausted, .resource_exceeded, .failed => {},
            }
            if (result.content_id) |id| {
                const content = try content_domain.readPublicContentMetadata(self, id);
                outcome.content = .{ .length = content.length, .digest = content.digest };
            }
            result.item.value = .{ .outcome = outcome };
            result.item.at = @intCast(try sqlite.readNullablePositiveI64(select, 6) orelse return error.CorruptStore);
        },
        7 => {
            const select = try store_core.cached(self, "SELECT s.command_key,s.selected_turn_id,s.admission_cutoff,t.outcome_position," ++
                "c.kind=3 AND c.accepted=1 AND c.target=s.session_ref AND (s.selected_turn_id IS NULL OR t.session_ref=s.session_ref),s.stopped_at " ++
                "FROM session_stop s LEFT JOIN core_command c ON c.command_key=s.command_key LEFT JOIN turn t ON t.turn_id=s.selected_turn_id WHERE s.session_ref=?1 AND s.position=?2");
            defer sqlite.resetCached(select);
            try sqlite.bindText(select, 1, session);
            try sqlite.bindU64(select, 2, position);
            if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 4) != 1 or c.sqlite3_column_int64(select, 2) < 0) return error.CorruptStore;
            const turn = try sqlite.readNullablePositiveI64(select, 1);
            const outcome_position = try sqlite.readNullablePositiveI64(select, 3);
            var stop: protocol.ActivityItem.Stop = .{ .key = .{}, .turn = if (turn) |id| @intCast(id) else null, .cutoff = @intCast(c.sqlite3_column_int64(select, 2)), .completion = if (turn == null or (outcome_position != null and outcome_position.? <= end)) .completed else .pending };
            try sqlite.readText(select, 0, &stop.key);
            result.item.value = .{ .stop = stop };
            result.item.at = @intCast(try sqlite.readNullablePositiveI64(select, 5) orelse return error.CorruptStore);
        },
        else => return error.CorruptStore,
    }
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptStore;
    return result;
}

pub fn openActivityContentLocked(self: *Store, request: *const protocol.ReadActivityContent) !ContentLocation {
    validateActivitySequence(self, request.session.slice()) catch |err| return store_core.fence(self, err);
    // Only Tool Results have nonzero ordinals. Byte readers need their
    // canonical identity, not a second scan of the original arguments.
    const id = if (request.ordinal != 0) id: {
        const content = publicConversationContentLocked(self, request.session.slice(), request.position, request.ordinal) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(self, err),
        };
        break :id content.id;
    } else id: {
        const identity = activityItemLocked(self, request.session.slice(), std.math.maxInt(i64), request.position, request.ordinal) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return store_core.fence(self, err),
        };
        break :id identity.content_id orelse return error.ContentNotFound;
    };
    const content = content_domain.readPublicContentMetadata(self, id) catch |err| return store_core.fence(self, err);
    return .{ .store = self, .content_id = id, .reference = .{ .length = content.length, .digest = content.digest } };
}

pub fn proposalPageLocked(self: *Store, request: *const protocol.ProposalPage, page: *ProposalPage) !void {
    const next_position = (try turn_domain.sessionNextPosition(self, request.session.slice())) orelse return error.SessionNotFound;
    const end = request.end orelse next_position - 1;
    if (end >= next_position) return error.InvalidCursor;
    if (request.after != 0) {
        _ = proposalLocked(self, request.session.slice(), request.after) catch |err| switch (err) {
            error.ContentNotFound => return error.InvalidCursor,
            else => return err,
        };
    }
    page.* = .{ .end = end };
    // The immutable accepted item owns discovery, including rejected calls.
    // Do not filter on live Actions, permissions or Turn state.
    const statement = try store_core.cached(self, "SELECT session_position FROM model_output_item " ++
        "WHERE session_ref=?1 AND session_position>?2 AND session_position<=?3 AND item_kind=3 " ++
        "ORDER BY session_position LIMIT 17");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, request.session.slice());
    try sqlite.bindU64(statement, 2, request.after);
    try sqlite.bindU64(statement, 3, end);
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) break;
        if (result != c.SQLITE_ROW) return error.ProposalReadFailed;
        if (page.count == page.items.len) {
            page.more = true;
            break;
        }
        const position = try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore;
        page.items[page.count] = (try proposalLocked(self, request.session.slice(), @intCast(position))).metadata;
        page.count += 1;
    }
}

const ProposalIdentity = struct { metadata: protocol.ProposalMetadata, content_ids: [3]i64 };

// The page, continuation cursor and byte route share one provenance check.
// LEFT JOIN keeps missing/contradictory owners visible as corruption.
pub fn proposalLocked(self: *Store, session: []const u8, position: u64) !ProposalIdentity {
    const statement = try store_core.cached(self, "SELECT item.operation_id,op.turn_id,tool_call.call_ordinal,action.action_id,tool_call.rejection_code," ++
        "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id," ++
        "CASE WHEN op.session_ref=item.session_ref AND t.session_ref=item.session_ref AND " ++
        store_schema.resolutionIs("op.resolution_code", .tool_proposals) ++ " AND op.attempt_ordinal=item.attempt_ordinal AND " ++
        "((tool_call.rejection_code IS NOT NULL AND action.action_id IS NULL AND tool_call.acceptance_position IS NOT NULL AND " ++
        "rejection.content_id IS NOT NULL AND rejection.private=0) OR " ++
        "(tool_call.rejection_code IS NULL AND action.action_id IS NOT NULL AND action.session_ref=item.session_ref)) " ++
        "THEN 1 ELSE 0 END,tool_call.field_metadata FROM model_output_item item " ++
        "LEFT JOIN model_operation op ON op.operation_id=item.operation_id LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
        "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
        "LEFT JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=3");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.bindU64(statement, 2, position);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return error.ContentNotFound,
        else => return error.ProposalReadFailed,
    }
    if (c.sqlite3_column_int(statement, 8) != 1) return error.CorruptStore;
    const ordinal = c.sqlite3_column_int64(statement, 2);
    if (ordinal < 0 or c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return error.CorruptStore;
    var result: ProposalIdentity = .{ .metadata = .{
        .position = position,
        .operation = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
        .turn = @intCast(try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore),
        .call_ordinal = @intCast(ordinal),
        .action = if (try sqlite.readNullablePositiveI64(statement, 3)) |action| @intCast(action) else null,
        .rejection = null,
        .fields = undefined,
    }, .content_ids = undefined };
    if (c.sqlite3_column_type(statement, 4) != c.SQLITE_NULL) {
        var code: protocol.Bounded(32) = .{};
        try sqlite.readText(statement, 4, &code);
        result.metadata.rejection = std.meta.stringToEnum(protocol.ProposalRejection, code.slice()) orelse return error.CorruptStore;
    }
    // Three admission-certified (little-endian length, SHA-256) pairs.
    // Reference substitution is detectable without reopening payloads.
    if (c.sqlite3_column_bytes(statement, 9) != 120) return error.CorruptStore;
    const certified: [*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, 9) orelse return error.CorruptStore);
    for (&result.content_ids, &result.metadata.fields, 0..) |*id, *field, index| {
        id.* = try sqlite.readNullablePositiveI64(statement, @intCast(5 + index)) orelse return error.CorruptStore;
        const metadata = try content_domain.readPublicContentMetadata(self, id.*);
        if (metadata.length != std.mem.readInt(u64, certified[index * 40 ..][0..8], .little) or
            !std.mem.eql(u8, &metadata.digest, certified[index * 40 + 8 ..][0..32])) return error.CorruptStore;
        field.* = .{ .length = metadata.length, .digest = metadata.digest };
    }
    return result;
}

pub fn openProposalFieldLocked(self: *Store, request: *const protocol.ReadProposalField) !ContentLocation {
    const identity = proposalLocked(self, request.session.slice(), request.position) catch |err| switch (err) {
        error.ContentNotFound => return err,
        else => return store_core.fence(self, err),
    };
    const index = @backingInt(request.field);
    const field = identity.metadata.fields[index];
    return .{ .store = self, .content_id = identity.content_ids[index], .reference = .{ .length = field.length, .digest = field.digest } };
}
