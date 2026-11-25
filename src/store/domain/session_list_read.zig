const connection = @import("../../connection.zig");
const std = @import("std");
const utf8_validation = @import("../../utf8_validation.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const change_ring = @import("../../change_ring.zig");
const model_capability = @import("../../model_capability.zig");
const provider_name = @import("../../provider_name.zig");
const provider_route = @import("../../provider_route.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const session_list = @import("../../session_list.zig");
const session_work = @import("../../session_work.zig");
const tool_name = @import("../../tool_name.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const saved_label = @import("../../saved_label.zig");
const workspace_path = @import("../../workspace_path.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const page_slots = @import("../page_slots.zig");
const command_domain = @import("command.zig");
const archive_membership = @import("archive_membership.zig");
const content_domain = @import("content.zig");
const content_parts = @import("content_parts.zig");
const configuration_domain = @import("configuration.zig");
const model_admission_domain = @import("model_admission.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const tool_set = @import("tool_set.zig");
const ReadAccess = reads_domain.ReadAccess;
const WorkRead = report_domain.WorkRead;
const SessionText = Bounded(session_id.max_reference_bytes);

pub fn Watched(comptime Visitor: type) type {
    return struct {
        visitor: Visitor,
        failed: bool = false,

        pub fn head(w: *@This()) !void {
            w.visitor.head() catch |err| {
                w.failed = true;
                return err;
            };
        }

        pub fn row(w: *@This(), values: *const session_list.Row) !void {
            w.visitor.row(values) catch |err| {
                w.failed = true;
                return err;
            };
        }

        pub fn archivedRow(w: *@This(), values: *const session_list.ArchivedRow) !void {
            w.visitor.archivedRow(values) catch |err| {
                w.failed = true;
                return err;
            };
        }

        pub fn tail(w: *@This(), values: session_list.Tail) !void {
            w.visitor.tail(values) catch |err| {
                w.failed = true;
                return err;
            };
        }
    };
}

pub const list_failures = .{
    .{ list_ceiling, error.SessionReadFailed },
    .{ list_page, error.SessionReadFailed },
    .{ live_active_page, error.SessionReadFailed },
    .{ live_turn_page, error.SessionReadFailed },
    .{ live_action_page, error.SessionReadFailed },
    .{ workspace_list_page, error.SessionReadFailed },
    .{ workspace_key, error.SessionReadFailed },
    .{ list_rows, error.SessionReadFailed },
    .{ changed_ancestors, error.SessionReadFailed },
    .{ descendant_work, error.SessionReadFailed },
} ++ report_domain.work_rows_failures;

fn runList(a: *ReadAccess) !void {
    return store_access.runNamed(a, list_failures, error.CorruptStore);
}

const list_ceiling = rsql.Read(.{
    .sql = "SELECT coalesce(max(created_seq),0) AS ceiling FROM session",
    .Args = struct {},
    .Row = struct { ceiling: u64 },
    .cardinality = .each,
});

const list_limit = session_list.session_list_page_size + 1;

const list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session WHERE created_seq>?1 AND created_seq<=?2" ++ archive_membership.filterSql("session", "?3") ++ " ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64, archive: session_archive.Filter },
    .Row = ListPage.Row,
    .cardinality = .each,
});

// The live tab is active Sessions (the column is NULL, one index range) plus archiving Sessions. An archiving
// Session is found by one candidate set, so each set is its own page statement: the candidate is the IN
// list, which MySQL can seek. A single UNION in the IN list makes MySQL scan session instead. Each statement
// is bounded by created_seq and LIMIT 9; mergeLive merges them in Zig by created_seq and keeps the first page.
fn livePageSql(comptime candidate: []const u8) []const u8 {
    return "SELECT s.created_seq,s.session_ref FROM session s WHERE s.session_ref IN (" ++ candidate ++ ") " ++
        "AND s.archive_seq IS NOT NULL AND s.created_seq>?1 AND s.created_seq<=?2 AND (" ++ archive_membership.stateSql("s") ++ ")='archiving' " ++
        "ORDER BY s.created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit});
}

pub const live_active_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session @index(session_tab) WHERE archive_seq IS NULL AND created_seq>?1 AND created_seq<=?2 ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64 },
    .Row = ListPage.Row,
    .cardinality = .each,
});

pub const live_turn_source = livePageSql(archive_membership.turn_candidates_sql);
pub const live_action_source = livePageSql(archive_membership.unaccepted_action_candidates_sql);

pub const live_turn_page = rsql.Read(.{
    .sql = live_turn_source,
    .Args = struct { after: u64, ceiling: u64 },
    .Row = ListPage.Row,
    .cardinality = .each,
});

pub const live_action_page = rsql.Read(.{
    .sql = live_action_source,
    .Args = struct { after: u64, ceiling: u64 },
    .Row = ListPage.Row,
    .cardinality = .each,
});

const workspace_list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session @index(session_workspace_list) " ++
        "WHERE workspace_digest=?3 AND workspace=?4 AND created_seq>?1 AND created_seq<=?2" ++ archive_membership.filterSql("session", "?5") ++ " ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64, digest: [32]u8, workspace: []const u8, archive: session_archive.Filter },
    .Row = ListPage.Row,
    .cardinality = .each,
});

const workspace_key = rsql.Read(.{
    .sql = "SELECT workspace_key FROM session WHERE workspace_digest=?1 AND workspace=?2 LIMIT 1",
    .Args = struct { digest: [32]u8, workspace: []const u8 },
    .Row = struct { workspace_key: rsql.Positive },
    .cardinality = .optional,
});

const LiveCandidates = struct {
    refs: [list_limit]change_ring.Id = undefined,
    seqs: [list_limit]u64 = undefined,
    count: usize = 0,
    failure: ?error{CorruptStore} = null,

    pub fn visit(self: *LiveCandidates, row: *const ListPage.Row) bool {
        if (self.count == list_limit) return false;
        const ref = row.session_ref.slice();
        if (ref.len != change_ring.id_bytes) {
            self.failure = error.CorruptStore;
            return false;
        }
        self.refs[self.count] = ref[0..change_ring.id_bytes].*;
        self.seqs[self.count] = row.created_seq.get();
        self.count += 1;
        return true;
    }
};

const LivePages = struct {
    active: LiveCandidates = .{},
    turn: LiveCandidates = .{},
    action: LiveCandidates = .{},
};

/// Merges the three live statements by created_seq and keeps the first page. Each statement holds its
/// first list_limit rows, so the first page of the union is complete. A Session can be in both archiving
/// candidate sets; created_seq is unique per Session, so its two rows are adjacent and the second is dropped.
/// `more` is exact: it is set only when a further distinct Session follows the page.
fn mergeLive(live: *const LivePages, page: *ListPage) !void {
    if (live.active.failure) |err| return err;
    if (live.turn.failure) |err| return err;
    if (live.action.failure) |err| return err;
    const lists = [_]*const LiveCandidates{ &live.active, &live.turn, &live.action };
    var cursor = [_]usize{ 0, 0, 0 };
    page.* = .{};
    while (true) {
        var chosen: ?usize = null;
        for (lists, 0..) |list, index| {
            if (cursor[index] == list.count) continue;
            if (chosen == null or list.seqs[cursor[index]] < lists[chosen.?].seqs[cursor[chosen.?]]) chosen = index;
        }
        const index = chosen orelse break;
        const seq = lists[index].seqs[cursor[index]];
        if (!(page.count > 0 and seq == page.last)) {
            if (page.count == session_list.session_list_page_size) {
                page.more = true;
                break;
            }
            page.refs[page.count] = lists[index].refs[cursor[index]];
            page.last = seq;
            page.count += 1;
        }
        cursor[index] += 1;
    }
}

const ListPage = struct {
    const Row = struct { created_seq: rsql.Positive, session_ref: SessionText };

    refs: [session_list.session_list_page_size]change_ring.Id = undefined,
    count: usize = 0,
    last: u64 = 0,
    more: bool = false,
    failure: ?error{CorruptStore} = null,

    pub fn visit(page: *ListPage, row: *const Row) bool {
        if (page.count == page.refs.len) {
            page.more = true;
            return false;
        }
        const ref = row.session_ref.slice();
        if (ref.len != change_ring.id_bytes) {
            page.failure = error.CorruptStore;
            return false;
        }
        page.refs[page.count] = ref[0..change_ring.id_bytes].*;
        page.last = row.created_seq.get();
        page.count += 1;
        return true;
    }
};

// Deadline changes are read facts, so they share the listing revision owner.
const retry_crossings = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key FROM model_operation o @index(model_operation_retry_due) " ++
        "JOIN turn t ON t.operation_id=o.operation_id AND t.outcome_code IS NULL " ++
        "JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o.resolution_code IS NULL AND o." ++ model_admission_domain.retry_allowance_open_sql ++
        " AND o.retry_due_at_ms>?1 AND o.retry_due_at_ms<=?2 LIMIT " ++ std.fmt.comptimePrint("{d}", .{change_ring.Touched.max + 1}),
    .Args = struct { after: u64, through: u64 },
    .Row = struct { session_ref: SessionText, workspace_key: rsql.Positive },
    .cardinality = .each,
});

const next_retry_crossing = rsql.Read(.{
    .sql = "SELECT o.retry_due_at_ms FROM model_operation o @index(model_operation_retry_due) " ++
        "JOIN turn t ON t.operation_id=o.operation_id AND t.outcome_code IS NULL " ++
        "WHERE o.resolution_code IS NULL AND o." ++ model_admission_domain.retry_allowance_open_sql ++
        " AND o.retry_due_at_ms>?1 " ++
        "ORDER BY o.retry_due_at_ms LIMIT 1",
    .Args = struct { after: u64 },
    .Row = struct { retry_due_at_ms: u64 },
    .cardinality = .optional,
});

pub const RetryCrossings = struct {
    touched: change_ring.Touched = .{},
    corrupt: bool = false,

    pub fn visit(self: *RetryCrossings, row: *const retry_crossings.Row) bool {
        const ref = row.session_ref.slice();
        if (ref.len != change_ring.id_bytes) {
            self.corrupt = true;
            return false;
        }
        if (self.touched.needsEntry(ref)) self.touched.add(.{ .session = ref[0..change_ring.id_bytes].*, .workspace = row.workspace_key.get() });
        return !self.touched.everything;
    }
};

pub fn retryCrossings(a: *ReadAccess, from: u64, now: u64, crossings: *RetryCrossings) !?u64 {
    var next: next_retry_crossing.Result = null;
    a.readEach(retry_crossings, .{ .after = @min(from, now), .through = @max(from, now) }, change_ring.Touched.max + 1, crossings);
    a.read(next_retry_crossing, .{ .after = now }, &next);
    try store_access.runAs(a, error.SessionReadFailed);
    if (crossings.corrupt) return error.CorruptStore;
    return if (next) |row| row.retry_due_at_ms else null;
}

// The Archived window: one statement per page, newest archive first. The page is the keyed range of
// session_tab, bounded by LIMIT N+1, so `more` is exact in the direction read. Each row joins its first
// Message once (report.zig's first_admission_join: the same rule as FirstCandidates) and names it as the
// live row does (report.zig's firstMessage). The prefix is that Message's first 512 bytes, raw, and only when it
// is inline Text; a parts-form first Message leaves it NULL and its line comes from the overview's parts read.
const archived_page_capacity = session_list.max_window_rows + 1;

const archived_columns = "session.archive_seq,session.session_ref,ostop.stopped_at,session.label," ++
    report_domain.first_pick_columns ++ "," ++
    "CASE WHEN first_content.private=0 AND first_content.form=0 THEN substr(@payload(first_content),1,512) END AS first_prefix";

const ArchivedWindowRow = struct {
    archive_seq: rsql.Positive,
    session_ref: SessionText,
    stopped_at: rsql.Positive,
    label: ?Bounded(tool_presentation.max_label_bytes),
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
    first_form: ?u8,
    first_prefix: ?rsql.Blob(session_list.max_first_prefix_bytes),
};

const archived_window_join = " FROM session @index(session_tab) LEFT JOIN core_command ocmd ON ocmd.command_seq=session.archive_seq " ++
    "LEFT JOIN session_stop ostop ON ostop.command_key=ocmd.command_key" ++ report_domain.first_admission_join ++
    report_domain.first_pick_content_join ++ " ";

/// The statement sources, with `@index` marks as written (the MySQL plan test renders them).
pub const archived_newest_source = "SELECT " ++ archived_columns ++ archived_window_join ++
    "WHERE session.archive_seq<?1 AND (" ++ archive_membership.stateSql("session") ++ ")='archived' " ++
    "ORDER BY session.archive_seq DESC LIMIT ?2";
pub const archived_oldest_source = "SELECT " ++ archived_columns ++ archived_window_join ++
    "WHERE session.archive_seq>?1 AND (" ++ archive_membership.stateSql("session") ++ ")='archived' " ++
    "ORDER BY session.archive_seq LIMIT ?2";

pub const archived_newest_page = rsql.Read(.{
    .sql = archived_newest_source,
    .Args = struct { below: u64, limit: u64 },
    .Row = ArchivedWindowRow,
    .cardinality = .each,
});

pub const archived_oldest_page = rsql.Read(.{
    .sql = archived_oldest_source,
    .Args = struct { above: u64, limit: u64 },
    .Row = ArchivedWindowRow,
    .cardinality = .each,
});

const ArchivedPage = struct {
    /// One row is over 1 KiB, so it decodes in place here and is copied into `rows`.
    decoded: ArchivedWindowRow = undefined,
    rows: [archived_page_capacity]ArchivedWindowRow = undefined,
    count: usize = 0,
    failure: ?error{CorruptStore} = null,

    pub fn visit(page: *ArchivedPage, row: *const ArchivedWindowRow) bool {
        if (page.count == page.rows.len or row.session_ref.slice().len != change_ring.id_bytes) {
            page.failure = error.CorruptStore;
            return false;
        }
        page.rows[page.count] = row.*;
        page.count += 1;
        return true;
    }

    /// Resets the small fields only: a whole-struct store would write all 37 KB of rows.
    fn reset(page: *ArchivedPage) void {
        page.count = 0;
        page.failure = null;
    }

    /// Settles a page read with one row beyond `size`: refuses a damaged read, keeps `size` rows and says whether
    /// the extra row was there.
    fn settle(page: *ArchivedPage, size: usize) error{CorruptStore}!bool {
        if (page.failure) |err| return err;
        const beyond = page.count > size;
        page.count = @min(page.count, size);
        return beyond;
    }

    fn held(page: *ArchivedPage) []ArchivedWindowRow {
        return page.rows[0..page.count];
    }

    /// The keys of the newest and the oldest held row, null when none is held.
    fn edges(page: *const ArchivedPage) struct { first: ?u64, last: ?u64 } {
        if (page.count == 0) return .{ .first = null, .last = null };
        return .{ .first = page.rows[0].archive_seq.get(), .last = page.rows[page.count - 1].archive_seq.get() };
    }
};

/// The raw leading bytes of an inline Text first Message, whole UTF-8 scalars only. A screen's line rule is the
/// screen's.
fn firstPrefix(blob: ?*const rsql.Blob(session_list.max_first_prefix_bytes)) ?[]const u8 {
    const bytes = utf8_validation.completePrefix((blob orelse return null).slice());
    return if (bytes.len == 0) null else bytes;
}

/// Reads one Archived window page in one round. `head` and `below` read newest first; `above` and `tail`
/// read oldest first from their key and are returned newest first.
fn readArchivedWindow(a: *ReadAccess, window: session_list.ArchivedWindow, generation: u64, page: *ArchivedPage, visitor: anytype) !void {
    page.reset();
    const cursor = window.cursor;
    const size: usize = window.rows;
    var more_above = false;
    var more_below = false;
    const newest_below: ?u64 = switch (cursor) {
        .head => std.math.maxInt(i64),
        .below => |key| key,
        .tail, .above => null,
    };
    const oldest_above: ?u64 = switch (cursor) {
        .tail => 0,
        .above => |key| key,
        .head, .below => null,
    };
    if (newest_below) |below| {
        a.readEach(archived_newest_page, .{ .below = below, .limit = size + 1 }, size + 1, page);
        try store_access.runAs(a, error.SessionReadFailed);
        more_below = try page.settle(size);
        more_above = std.meta.activeTag(cursor) == .below;
    } else if (oldest_above) |above| {
        a.readEach(archived_oldest_page, .{ .above = above, .limit = size + 1 }, size + 1, page);
        try store_access.runAs(a, error.SessionReadFailed);
        // The oldest-first read keeps the rows nearest the cursor; the extra row is further away.
        more_above = try page.settle(size);
        more_below = std.meta.activeTag(cursor) == .above;
        std.mem.reverse(ArchivedWindowRow, page.held());
    }
    try visitor.head();
    for (page.held()) |*row| {
        row.label = saved_label.labelWords(row.label);
        var values: session_list.ArchivedRow = .{
            .reference = row.session_ref.slice(),
            .archive_seq = row.archive_seq.get(),
            .stopped_at = row.stopped_at.get(),
            .label = if (row.label) |*label| label.slice() else null,
            .first = try report_domain.firstMessage(row, if (row.first_admission) |admission| admission.get() else 0),
            .first_prefix = firstPrefix(if (row.first_prefix) |*prefix| prefix else null),
        };
        try visitor.archivedRow(&values);
    }
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const since = (change_ring.Token{ .instance = a.store.instance, .generation = generation }).format(&token);
    try visitor.tail(.{ .window = .{
        .since = since,
        .first = page.edges().first,
        .last = page.edges().last,
        .more_above = more_above,
        .more_below = more_below,
    } });
}

/// The page buffers of one Session list read: an Archived window page is about 37 KB. The caller allocates
/// them before the Store queue runs the read, so the read's frame stays inside the Host stack budget, and a
/// failed allocation is an ordinary refusal that never reaches the held Store. The read resets each buffer
/// it uses, so the caller may hand them in unfilled.
pub const Scratch = struct {
    archived: ArchivedPage = .{},
    page: ListPage = .{},
    live: LivePages = .{},
    /// The changed seeds of a since-delta page, in ID order, found before its ancestor statements queue.
    changed: [change_ring.capacity]change_ring.Id = undefined,
    /// The settings rows of one page, read in its row round beside its work rows.
    list_rows: ListRows = .{},
    /// The work rows of one page, read in its row round beside its settings rows and decoded as they arrive.
    work_rows: report_domain.WorkRows = .{},
    /// The creator-subtree fold of one page: the descendant row being decoded, its WorkRead and the page's totals.
    subtree: SubtreeFold = .{},
};

pub fn readSessionList(a: *ReadAccess, request: *const session_list.ListSessions, scratch: *Scratch, visitor: anytype) !void {
    const self = a.store;
    const generation = self.commit_generation.load(.acquire);
    if (request.window) |window| return readArchivedWindow(a, window, generation, &scratch.archived, visitor);
    if (request.since) |since| {
        const through = if (request.changed) |changed| changed.through else generation;
        if (std.mem.eql(u8, &since.instance, &self.instance) and through <= generation and self.changes.covers(since.generation))
            return readChangedSessions(a, request, since.generation, through, scratch, visitor);
    }
    try readAllSessions(a, request, generation, scratch, visitor);
}

fn readAllSessions(a: *ReadAccess, request: *const session_list.ListSessions, generation: u64, scratch: *Scratch, visitor: anytype) !void {
    var maximum: reads_domain.First(list_ceiling.Row) = .{};
    if (request.after == 0) a.readEach(list_ceiling, .{}, 1, &maximum);
    const bound: u64 = if (request.after == 0) std.math.maxInt(i64) else request.ceiling;
    const page = &scratch.page;
    const live = &scratch.live;
    page.* = .{};
    live.* = .{};
    const live_tab = request.workspace == null and request.archive == .active;
    if (request.workspace) |*workspace|
        a.readEach(workspace_list_page, .{ .after = request.after, .ceiling = bound, .digest = store_core.workspaceDigest(workspace.slice()), .workspace = workspace.slice(), .archive = request.archive }, list_limit, page)
    else if (live_tab) {
        a.readEach(live_active_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.active);
        a.readEach(live_turn_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.turn);
        a.readEach(live_action_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.action);
    } else a.readEach(list_page, .{ .after = request.after, .ceiling = bound, .archive = request.archive }, list_limit, page);
    try store_access.runAs(a, error.SessionReadFailed);
    if (live_tab) try mergeLive(live, page);
    if (page.failure) |err| return err;
    const ceiling = if (request.after == 0) (maximum.row orelse return error.SessionReadFailed).ceiling else request.ceiling;
    try readRows(a, request, scratch, page.refs[0..page.count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const since = (change_ring.Token{ .instance = a.store.instance, .generation = generation }).format(&token);
    try visitor.tail(if (page.more)
        .{ .full = .{ .since = since, .after = page.last, .ceiling = ceiling } }
    else
        .{ .last = .{ .delta = .full, .since = since } });
}

// One statement walks the creator chains of up to session_list_page_size changed seeds. Each chain carries its own
// origin (the seed), so the cycle test asks each chain separately: a chain that reaches a root must not hide a
// cycle in a chain batched beside it. Same workspace and archive filters as descendant_work.
pub const changed_ancestors_source = "WITH RECURSIVE ancestors(origin,session_ref,creator_ref) AS (" ++
    "SELECT seed.session_ref,session.session_ref,session.creator_ref FROM session JOIN session seed ON seed.creator_ref=session.session_ref " ++
    "WHERE seed.session_ref IN (?1,?2,?3,?4,?5,?6,?7,?8) AND (?9 IS NULL OR session.workspace=?9)" ++ archive_membership.filterSql("session", "?10") ++
    " UNION SELECT child.origin,session.session_ref,session.creator_ref FROM session JOIN ancestors child ON child.creator_ref=session.session_ref " ++
    "WHERE (?9 IS NULL OR session.workspace=?9)" ++ archive_membership.filterSql("session", "?10") ++ ") " ++
    "SELECT seen.session_ref,NOT EXISTS (SELECT 1 FROM ancestors tail WHERE tail.origin=seen.origin AND (tail.creator_ref IS NULL OR NOT EXISTS " ++
    "(SELECT 1 FROM ancestors parent WHERE parent.origin=tail.origin AND parent.session_ref=tail.creator_ref))) AS cycle FROM ancestors seen";
const changed_ancestors = rsql.Read(.{
    .sql = changed_ancestors_source,
    .Args = struct {
        seed0: Bounded(change_ring.id_bytes),
        seed1: Bounded(change_ring.id_bytes),
        seed2: Bounded(change_ring.id_bytes),
        seed3: Bounded(change_ring.id_bytes),
        seed4: Bounded(change_ring.id_bytes),
        seed5: Bounded(change_ring.id_bytes),
        seed6: Bounded(change_ring.id_bytes),
        seed7: Bounded(change_ring.id_bytes),
        workspace: ?[]const u8,
        archive: session_archive.Filter,
    },
    .Row = struct { session_ref: SessionText, cycle: bool },
    .cardinality = .each,
    .compound = true,
});

/// Binds one batch of seeds by value, so no seed bytes outlive this call. Unused slots are empty and match no
/// Session.
fn changedAncestorArgs(seeds: []const change_ring.Id, workspace: ?[]const u8, archive: session_archive.Filter) !changed_ancestors.Args {
    const slots = try page_slots.refSlots(seeds);
    return .{
        .seed0 = slots[0],
        .seed1 = slots[1],
        .seed2 = slots[2],
        .seed3 = slots[3],
        .seed4 = slots[4],
        .seed5 = slots[5],
        .seed6 = slots[6],
        .seed7 = slots[7],
        .workspace = workspace,
        .archive = archive,
    };
}

const ChangedCandidates = struct {
    refs: [session_list.session_list_page_size + 1]change_ring.Id = undefined,
    count: usize = 0,
    after: ?*const change_ring.Id,
    failure: ?error{CorruptStore} = null,

    fn add(self: *ChangedCandidates, ref: *const change_ring.Id) void {
        if (self.after) |after| if (std.mem.order(u8, ref, after) != .gt) return;
        var at: usize = 0;
        while (at < self.count and std.mem.order(u8, &self.refs[at], ref) == .lt) : (at += 1) {}
        if (at < self.count and std.mem.eql(u8, &self.refs[at], ref)) return;
        if (at == self.refs.len) return;
        const end = @min(self.count, self.refs.len - 1);
        var move = end;
        while (move > at) : (move -= 1) self.refs[move] = self.refs[move - 1];
        self.refs[at] = ref.*;
        self.count = @min(self.count + 1, self.refs.len);
    }

    pub fn visit(self: *ChangedCandidates, row: *const changed_ancestors.Row) bool {
        const ref = row.session_ref.slice();
        if (ref.len != change_ring.id_bytes or row.cycle) {
            self.failure = error.CorruptStore;
            return false;
        }
        const id = ref[0..change_ring.id_bytes].*;
        self.add(&id);
        return true;
    }
};

fn readChangedSessions(a: *ReadAccess, request: *const session_list.ListSessions, since: u64, through: u64, scratch: *Scratch, visitor: anytype) !void {
    var workspace: ?u64 = null;
    if (request.workspace) |*scope| {
        var key: workspace_key.Result = undefined;
        a.read(workspace_key, .{ .digest = store_core.workspaceDigest(scope.slice()), .workspace = scope.slice() }, &key);
        try store_access.runAs(a, error.SessionReadFailed);
        workspace = if (key) |row| row.workspace_key.get() else 0;
    }
    const self = a.store;
    const after: ?*const change_ring.Id = if (request.changed) |*changed| &changed.after_reference else null;
    var candidates: ChangedCandidates = .{ .after = after };
    // Every changed seed is named first, then the seeds go in batches of session_list_page_size, one statement per
    // batch. All statements queue into one round, but on SQLite a statement repeated in one pass forces the next, so C
    // seeds take ceil(C/8) passes there (tests.pass_budgets pins the C <= 8 case). Each batch binds its seeds by value.
    const seeds = self.changes.changed(since, through, workspace, null, &scratch.changed);
    const scope: ?[]const u8 = if (request.workspace) |*workspace_scope| workspace_scope.slice() else null;
    var first: usize = 0;
    while (first < seeds.len) : (first += session_list.session_list_page_size) {
        const batch = seeds[first..@min(seeds.len, first + session_list.session_list_page_size)];
        for (batch) |*seed| candidates.add(seed);
        a.readEach(changed_ancestors, try changedAncestorArgs(batch, scope, request.archive), std.math.maxInt(u64), &candidates);
    }
    if (seeds.len != 0) try runList(a);
    if (candidates.failure) |err| return err;
    const changed = candidates.refs[0..candidates.count];
    const count = @min(changed.len, session_list.session_list_page_size);
    try readRows(a, request, scratch, changed[0..count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const next = (change_ring.Token{ .instance = self.instance, .generation = through }).format(&token);
    try visitor.tail(if (changed.len > count)
        .{ .changed = .{ .since = next, .through = through, .after_reference = &changed[count - 1] } }
    else
        .{ .last = .{ .delta = .changed, .since = next } });
}

/// The clock facts of the Session whose ref is the SQL expression `session`: its latest Turn's start and its approval
/// entry and exit times. The list row renders it over `session.session_ref` and the creator-subtree read over each
/// descendant's own ref.
fn clockColumnsSql(comptime session: []const u8) []const u8 {
    const latest_turn = "(SELECT turn_id FROM turn WHERE session_ref=" ++ session ++ " ORDER BY turn_id DESC LIMIT 1)";
    return "(SELECT COALESCE((SELECT e.recorded_at FROM conversation_entry e WHERE e.source_admission_id=t.first_admission_id AND e.entry_kind=1)," ++
        "CASE WHEN m.turn_id IS NULL AND (SELECT o.purpose FROM model_operation o WHERE o.turn_id=t.turn_id ORDER BY o.operation_id DESC LIMIT 1)=1 THEN m.admitted_at END) " ++
        "FROM turn t JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
        "WHERE t.turn_id=" ++ latest_turn ++ ") AS clock_started_at," ++
        "(SELECT max(o.resolved_at) FROM model_operation o JOIN turn t ON t.turn_id=o.turn_id " ++
        "WHERE t.turn_id=" ++ latest_turn ++ " " ++
        "AND EXISTS (SELECT 1 FROM action_operation a WHERE a.parent_operation_id=o.operation_id AND a.approval_position IS NOT NULL)) AS clock_approval_entered_at," ++
        "(SELECT max((SELECT max(COALESCE(a.decided_at,a.resolved_at)) FROM action_operation a " ++
        "WHERE a.parent_operation_id=o.operation_id AND a.approval_position IS NOT NULL)) FROM model_operation o " ++
        "WHERE o.turn_id=" ++ latest_turn ++ " " ++
        "AND NOT EXISTS (SELECT 1 FROM action_operation pending WHERE pending.parent_operation_id=o.operation_id " ++
        "AND pending.approval_position IS NOT NULL AND pending.authorized=0 AND pending.resolution_code IS NULL)) AS clock_approval_left_at";
}

/// The creator subtree of up to session_list_page_size page roots, every descendant with its own clock facts and
/// work columns, in one statement. Each descendant row carries its origin (the page root it descends from); root rows
/// are dropped, since the roots' work is the page's own work_rows read. The walk is unbounded and has no order: the fold
/// is a max and two counts, and a truncated walk would report wrong counts. Each row carries its root's creator, and a
/// row that is that creator flags a cycle: the root's creator is in its own subtree. Every creator cycle the walk can
/// reach runs through a root, and it shows on a non-root row, because a Session is never its own creator (schema CHECK).
/// The statement source, with `@index` marks as written (the plan tests render it).
pub const descendant_work_source = "WITH RECURSIVE descendants(origin,root_creator,session_ref,workspace_digest,workspace) AS (" ++
    "SELECT session.session_ref,session.creator_ref,session.session_ref,session.workspace_digest,session.workspace FROM session " ++
    "WHERE session.session_ref IN (?1,?2,?3,?4,?5,?6,?7,?8) AND (?9 IS NULL OR (session.workspace_digest=?10 AND session.workspace=?9))" ++ archive_membership.filterSql("session", "?11") ++
    " UNION SELECT parent.origin,parent.root_creator,session.session_ref,session.workspace_digest,session.workspace FROM session @index(session_creator) JOIN descendants parent " ++
    "ON session.creator_ref=parent.session_ref AND session.workspace_digest=parent.workspace_digest AND session.workspace=parent.workspace " ++
    "WHERE 1=1" ++ archive_membership.filterSql("session", "?11") ++ ") " ++
    "SELECT member.origin,work_session.session_ref,work_session.created_at," ++ clockColumnsSql("work_session.session_ref") ++
    ",(member.root_creator IS NOT NULL AND member.session_ref=member.root_creator) AS cycle," ++
    report_domain.work_columns ++ " " ++
    "FROM descendants member JOIN session work_session ON work_session.session_ref=member.session_ref " ++
    report_domain.work_joins ++ "WHERE member.session_ref<>member.origin";

pub const descendant_work = rsql.Read(.{
    .sql = descendant_work_source,
    .Args = struct {
        root0: Bounded(change_ring.id_bytes),
        root1: Bounded(change_ring.id_bytes),
        root2: Bounded(change_ring.id_bytes),
        root3: Bounded(change_ring.id_bytes),
        root4: Bounded(change_ring.id_bytes),
        root5: Bounded(change_ring.id_bytes),
        root6: Bounded(change_ring.id_bytes),
        root7: Bounded(change_ring.id_bytes),
        workspace: ?[]const u8,
        digest: ?[32]u8,
        archive: session_archive.Filter,
    },
    .Row = report_domain.WithWork(struct {
        origin: SessionText,
        session_ref: SessionText,
        created_at: rsql.Positive,
        clock_started_at: ?rsql.Positive,
        clock_approval_entered_at: ?rsql.Positive,
        clock_approval_left_at: ?rsql.Positive,
        cycle: bool,
    }),
    .cardinality = .each,
    .compound = true,
});

/// Binds a page's roots by value, so no root bytes outlive this call. Unused slots are empty and match no Session.
fn subtreeArgs(request: *const session_list.ListSessions, roots: []const change_ring.Id) !descendant_work.Args {
    const slots = try page_slots.refSlots(roots);
    return .{
        .root0 = slots[0],
        .root1 = slots[1],
        .root2 = slots[2],
        .root3 = slots[3],
        .root4 = slots[4],
        .root5 = slots[5],
        .root6 = slots[6],
        .root7 = slots[7],
        .workspace = if (request.workspace) |*scope| scope.slice() else null,
        .digest = if (request.workspace) |*scope| store_core.workspaceDigest(scope.slice()) else null,
        .archive = request.archive,
    };
}

const Rollup = struct {
    subtree_state_change_at: u64 = 0,
    descendant_count: u64 = 0,
    descendant_needs_you_count: u64 = 0,
};

/// Folds each creator descendant into its page root's Rollup as the subtree statement streams it: its row decodes
/// into `decoded`, its work replays through WorkRead.decode, and only the totals outlive the row. It lives in Scratch,
/// since the row is over 1 KiB. `roots` and `totals` are borrowed from readRows until the round runs.
const SubtreeFold = struct {
    decoded: descendant_work.Row = undefined,
    work: WorkRead = undefined,
    roots: []const change_ring.Id = &.{},
    totals: []Rollup = &.{},
    now_ms: u64 = 0,
    failure: ?error{ CorruptStore, ActionReadFailed } = null,

    pub fn visit(self: *SubtreeFold, row: *const descendant_work.Row) bool {
        self.fold(row) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }

    fn fold(self: *SubtreeFold, row: *const descendant_work.Row) error{ CorruptStore, ActionReadFailed }!void {
        if (row.origin.slice().len != change_ring.id_bytes or row.session_ref.slice().len != change_ring.id_bytes or row.cycle) return error.CorruptStore;
        var index: usize = 0;
        while (index < self.roots.len and !std.mem.eql(u8, row.origin.slice(), &self.roots[index])) : (index += 1) {}
        if (index == self.roots.len) return error.CorruptStore;
        // The ref is borrowed from `decoded`; the fold finishes before the next row overwrites it.
        self.work = .{ .session = row.session_ref.slice() };
        try self.work.decode(row);
        const work = try self.work.work(row.created_at.get(), self.now_ms);
        const total = &self.totals[index];
        total.subtree_state_change_at = @max(total.subtree_state_change_at, try stateChangeAt(.of(row), &self.work, work));
        total.descendant_count = std.math.add(u64, total.descendant_count, 1) catch return error.CorruptStore;
        if (session_work.standing(work.state) == .needs_you) total.descendant_needs_you_count = std.math.add(u64, total.descendant_needs_you_count, 1) catch return error.CorruptStore;
    }
};

const settings_columns = "session.session_ref,session.archive_seq,session.parent_ref,session.creator_ref,session.workspace,session.provider,session.model," ++ tool_set.namesSql("session.tool_set_id") ++ " AS tools,session.permission_mode,session.label,session.created_at,session.revision,session.next_position," ++
    archive_membership.stateSql("session") ++ " AS archive_state," ++
    "(SELECT pin_command.command_seq FROM session_pin pin JOIN core_command pin_command ON pin_command.command_key=pin.command_key WHERE pin.session_ref=session.session_ref) AS pin_order," ++
    "(" ++ report_domain.personMessageSql("session.session_ref") ++ ") AS from_person_at," ++
    "awaiting.action_id AS first_awaiting_action," ++ clockColumnsSql("session.session_ref") ++ ",";

const awaiting_join = " LEFT JOIN action_operation awaiting ON awaiting.action_id=(" ++ report_domain.firstApprovalSql("session.session_ref") ++ ") ";

/// The settings rows of up to session_list_page_size Sessions: one row per Session found, in no promised order, each
/// carrying its own ref. Unused slots are empty and match no Session. Its first Message and first awaiting approval
/// are correlated joins on each row's Session ref, so the statement queues in the page's row round. A Session with no
/// first Message keeps its row, with NULL first-Message columns. The IN list holds only bound refs (MySQL seeks the
/// session key for each; an IN list holding a UNION made it scan session, see livePageSql).
/// The statement source, with `@index` marks as written (the MySQL plan test renders it).
pub const list_rows_source = "SELECT " ++ settings_columns ++ report_domain.first_pick_columns ++ " FROM session" ++ report_domain.first_admission_join ++
    report_domain.first_pick_content_join ++ awaiting_join ++ " WHERE session.session_ref IN (?1,?2,?3,?4,?5,?6,?7,?8)";

pub const list_rows = rsql.Read(.{
    .sql = page_slots.statement(list_rows_source),
    .Args = page_slots.Args,
    .Row = ListRow,
    .cardinality = .each,
});

const ListRow = struct {
    session_ref: SessionText,
    archive_seq: ?rsql.Positive,
    parent_ref: ?Bounded(session_id.bytes),
    creator_ref: ?Bounded(session_id.bytes),
    workspace: Bounded(workspace_path.max_bytes),
    provider: connection.Name,
    model: Bounded(model_capability.max_model_bytes),
    tools: ?Bounded(tool_set.max_names_bytes),
    permission_mode: u8,
    label: ?Bounded(tool_presentation.max_label_bytes),
    created_at: rsql.Positive,
    revision: rsql.Positive,
    next_position: rsql.Positive,
    archive_state: session_archive.State,
    pin_order: ?rsql.Positive,
    from_person_at: ?rsql.Positive,
    first_awaiting_action: ?rsql.Positive,
    clock_started_at: ?rsql.Positive,
    clock_approval_entered_at: ?rsql.Positive,
    clock_approval_left_at: ?rsql.Positive,
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
    first_form: ?u8,
};

const ListScratch = struct {
    works: [session_list.session_list_page_size]WorkRead,
    shown: [session_list.session_list_page_size]ShownRow,
    rollups: [session_list.session_list_page_size]Rollup,
};

/// The settings rows of one page in one list_rows statement. Each row decodes into `decoded` (it is over 1 KiB) and is
/// copied into the slot its Session ref names; page_slots refuses an unknown, second or missing row.
const ListRows = struct {
    decoded: ListRow = undefined,
    rows: [session_list.session_list_page_size]ListRow = undefined,
    slots: page_slots.PageSlots(error{CorruptStore}) = .{},

    /// Queues the settings of `references`. An empty page queues nothing, so it adds no statement to the round.
    fn queue(rows: *ListRows, a: *ReadAccess, references: []const change_ring.Id) error{CorruptStore}!void {
        try rows.slots.bind(null, references);
        if (rows.slots.args()) |args| a.readEach(list_rows, args, std.math.maxInt(u64), rows);
    }

    pub fn visit(rows: *ListRows, row: *const ListRow) bool {
        return rows.slots.keep(rows.take(row));
    }

    fn take(rows: *ListRows, row: *const ListRow) error{CorruptStore}!void {
        rows.rows[try rows.slots.slotOf(row.session_ref.slice())] = row.*;
    }

    fn finish(rows: *const ListRows) error{CorruptStore}!void {
        return rows.slots.finish();
    }
};

/// Reads one page of rows in one round: the creator subtree of every row with its descendants' work, streamed into
/// the subtree fold, then the page's work rows and settings rows, one statement each over the page's refs. Each row is
/// matched to its Session by the ref it carries. Then the rows are shaped from the settings read.
noinline fn readRows(a: *ReadAccess, request: *const session_list.ListSessions, scratch: *Scratch, references: []const change_ring.Id, visitor: anytype) !void {
    const now_ms = try store_core.readUnixMilliseconds(a.store.io);
    try visitor.head();
    const list = a.store.reportScratch(ListScratch);
    const works = list.works[0..references.len];
    const now = std.math.cast(u64, now_ms) orelse return error.IntegerOutOfRange;
    const rollups = list.rollups[0..references.len];
    @memset(rollups, .{});
    // Only the small fields are set: `decoded` and `work` are each written before they are read, and assigning the
    // whole fold would put its 2 KiB row on this frame.
    const subtree = &scratch.subtree;
    subtree.roots = references;
    subtree.totals = rollups;
    subtree.now_ms = now;
    subtree.failure = null;
    if (references.len != 0) a.readEach(descendant_work, try subtreeArgs(request, references), std.math.maxInt(u64), subtree);
    for (references, works) |*reference, *work| work.* = .{ .session = reference };
    try scratch.work_rows.queue(a, works);
    try scratch.list_rows.queue(a, references);
    try runList(a);
    try scratch.work_rows.finish();
    if (subtree.failure) |err| return err;
    try scratch.list_rows.finish();
    const shown = &list.shown;
    for (references, works, shown[0..references.len]) |*reference, *work, *row| row.* = .{ .reference = reference, .work = work };
    try readRowSettings(a, shown[0..references.len], scratch.list_rows.rows[0..references.len], rollups, now, visitor);
}

const ShownRow = struct { reference: *const change_ring.Id, work: *const WorkRead };

/// Shapes each row from its settings read. No round runs here: every statement was queued and run before.
noinline fn readRowSettings(a: *ReadAccess, rows: []const ShownRow, settings: []ListRow, rollups: []const Rollup, now_ms: u64, visitor: anytype) !void {
    const read_version: change_ring.Token = .{ .instance = a.store.instance, .generation = a.store.commitGeneration() };
    for (settings[0..rows.len], 0..) |*row, index| {
        var sorted: [tool_name.max_tools][]const u8 = undefined;
        var values = try rowValues(rows, rollups, index, now_ms, row, &sorted);
        values.read_version = read_version;
        try visitor.row(&values);
    }
}

const ClockFacts = struct {
    created_at: u64,
    started_at: ?u64,
    approval_entered_at: ?u64,
    approval_left_at: ?u64,

    fn of(row: anytype) ClockFacts {
        return .{
            .created_at = row.created_at.get(),
            .started_at = if (row.clock_started_at) |value| value.get() else null,
            .approval_entered_at = if (row.clock_approval_entered_at) |value| value.get() else null,
            .approval_left_at = if (row.clock_approval_left_at) |value| value.get() else null,
        };
    }
};

fn stateChangeAt(facts: ClockFacts, read: *const WorkRead, work: @import("../../session_work.zig").Work) !u64 {
    const inputs = read.inputs;
    var clock = facts.created_at;
    if (inputs.latest) |latest| {
        clock = @max(clock, (facts.started_at orelse return error.CorruptStore));
        if (latest.terminal) |terminal| clock = @max(clock, terminal.at);
        if (latest.stopped_at) |stopped| clock = @max(clock, stopped);
        if (latest.terminal != null and work.state == .pending) clock = @max(clock, work.state.since());
    } else if (inputs.oldest_pending) |pending| clock = @max(clock, pending.at);
    if (inputs.excluded) |excluded| clock = @max(clock, excluded.stop_at);
    if (work.state == .working and (inputs.latest == null or inputs.latest.?.terminal != null)) {
        if (inputs.owed_since) |owed| clock = @max(clock, owed);
    }
    if (facts.approval_entered_at) |entered| clock = @max(clock, entered);
    if (facts.approval_left_at) |left| clock = @max(clock, left);
    return clock;
}

fn rowValues(rows: []const ShownRow, rollups: []const Rollup, index: usize, now_ms: u64, row: *ListRow, sorted: *[tool_name.max_tools][]const u8) !session_list.Row {
    if (index == rows.len or !std.mem.eql(u8, row.session_ref.slice(), rows[index].reference)) return error.CorruptStore;
    const names = try report_domain.sortedToolNames(if (row.tools) |*tools| tools.slice() else null, sorted);
    row.label = saved_label.labelWords(row.label);
    const work = try rows[index].work.work(row.created_at.get(), now_ms);
    // The settings join and the work row's first_action read one fact, the oldest approval awaiting a decision. Both
    // reads run in one round over one snapshot, so a disagreement means the Store is corrupt. U3 put both in one round;
    // the later PR that retires the staged machine can drop one of the two reads (Q2).
    if ((if (row.first_awaiting_action) |id| id.get() else null) != work.first_action) return error.CorruptStore;
    const permission_mode = try configuration_domain.permissionMode(row.permission_mode);
    const first_message = try report_domain.firstMessage(row, if (row.first_admission) |admission| admission.get() else 0);
    const clock = try stateChangeAt(.of(row), rows[index].work, work);
    return .{
        .archive_state = row.archive_state,
        .pin_order = if (row.pin_order) |rank| rank.get() else null,
        .reference = row.session_ref.slice(),
        .archive_seq = if (row.archive_seq) |key| key.get() else null,
        .parent = if (row.parent_ref) |*parent| parent.slice() else null,
        .creator = if (row.creator_ref) |*creator| creator.slice() else null,
        .workspace = row.workspace.slice(),
        .provider = row.provider,
        .model = row.model.slice(),
        .tools = names,
        .permission_mode = permission_mode,
        .label = if (row.label) |*label| label.slice() else null,
        .created_at = row.created_at.get(),
        .state_change_at = clock,
        .subtree_state_change_at = @max(clock, rollups[index].subtree_state_change_at),
        .descendant_count = rollups[index].descendant_count,
        .descendant_needs_you_count = rollups[index].descendant_needs_you_count,
        .revision = row.revision.get(),
        .end = row.next_position.get() - 1,
        .first_message = first_message,
        .work = work,
        .peers = .{ .from_person_at = if (row.from_person_at) |at| at.get() else null },
    };
}
