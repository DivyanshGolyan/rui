const std = @import("std");
const utf8_validation = @import("../../utf8_validation.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const change_ring = @import("../../change_ring.zig");
const model_capability = @import("../../model_capability.zig");
const provider_name = @import("../../provider_name.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const session_list = @import("../../session_list.zig");
const session_line = @import("../../session_line.zig");
const session_work = @import("../../session_work.zig");
const tool_name = @import("../../tool_name.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const workspace_path = @import("../../workspace_path.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const command_domain = @import("command.zig");
const archive_membership = @import("archive_membership.zig");
const configuration_domain = @import("configuration.zig");
const model_admission_domain = @import("model_admission.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const tool_set = @import("tool_set.zig");
const ReadAccess = reads_domain.ReadAccess;
const FirstCandidates = report_domain.FirstCandidates;
const WorkRead = report_domain.WorkRead;
const readWorks = report_domain.readWorks;
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
    .{ list_row, error.SessionReadFailed },
    .{ list_row_bare, error.SessionReadFailed },
    .{ changed_ancestors, error.SessionReadFailed },
    .{ descendant_page, error.SessionReadFailed },
} ++ report_domain.report_failures;

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
fn mergeLive(live: *const LivePages) !ListPage {
    if (live.active.failure) |err| return err;
    if (live.turn.failure) |err| return err;
    if (live.action.failure) |err| return err;
    const lists = [_]*const LiveCandidates{ &live.active, &live.turn, &live.action };
    var cursor = [_]usize{ 0, 0, 0 };
    var page: ListPage = .{};
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
    return page;
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

// The Archived window: one statement per page, newest archive first. The inner page is the keyed range
// of session_tab, bounded by LIMIT N+1, so `more` is exact in the direction read. The outer statement
// decorates only those rows: the first Message's admission (the same rule as FirstCandidates: the
// first turn's first admission, or an earlier pending one) and its first line when that Message is
// inline Text. Parts-form first Messages leave the line NULL; their line needs a parts read. The line
// is read from the first 512 bytes, which keeps the row under the 1 KiB decode limit; a first line that
// begins after 512 bytes of blank lines reads as absent.
const archived_window_limit = session_list.archived_window_size + 1;

fn firstAdmissionSql(comptime alias: []const u8) []const u8 {
    return comptime "SELECT MIN(pm.admission_id) FROM message_admission pm WHERE pm.session_ref=" ++ alias ++ ".session_ref AND " ++
        "(pm.turn_id IS NULL OR pm.admission_id=(SELECT t.first_admission_id FROM turn t WHERE t.session_ref=" ++ alias ++ ".session_ref ORDER BY t.turn_id LIMIT 1))";
}

const archived_columns = "session.archive_seq,session.session_ref,ostop.stopped_at,session.label," ++
    "(" ++ firstAdmissionSql("session") ++ ") AS first_admission," ++
    "(SELECT substr(@payload(fc),1,512) FROM message_admission fm JOIN content fc ON fc.content_id=fm.content_id " ++
    "WHERE fm.admission_id=(" ++ firstAdmissionSql("session") ++ ") AND fc.private=0 AND fc.form=0) AS first_line";

const ArchivedWindowRow = struct {
    archive_seq: rsql.Positive,
    session_ref: SessionText,
    stopped_at: rsql.Positive,
    label: ?Bounded(tool_presentation.max_label_bytes),
    first_admission: ?rsql.Positive,
    first_line: ?rsql.Blob(512),
};

const archived_window_join = " FROM session @index(session_tab) LEFT JOIN core_command ocmd ON ocmd.command_seq=session.archive_seq " ++
    "LEFT JOIN session_stop ostop ON ostop.command_key=ocmd.command_key ";

pub const archived_newest_page = rsql.Read(.{
    .sql = "SELECT " ++ archived_columns ++ archived_window_join ++
        "WHERE session.archive_seq<?1 AND (" ++ archive_membership.stateSql("session") ++ ")='archived' " ++
        "ORDER BY session.archive_seq DESC LIMIT " ++ std.fmt.comptimePrint("{d}", .{archived_window_limit}),
    .Args = struct { below: u64 },
    .Row = ArchivedWindowRow,
    .cardinality = .each,
});

pub const archived_oldest_page = rsql.Read(.{
    .sql = "SELECT " ++ archived_columns ++ archived_window_join ++
        "WHERE session.archive_seq>?1 AND (" ++ archive_membership.stateSql("session") ++ ")='archived' " ++
        "ORDER BY session.archive_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{archived_window_limit}),
    .Args = struct { above: u64 },
    .Row = ArchivedWindowRow,
    .cardinality = .each,
});

const ArchivedPage = struct {
    rows: [archived_window_limit]ArchivedWindowRow = undefined,
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
};

/// The first display line of an inline first Message, the same rule as the Session row's last line.
fn archivedLine(prefix: ?*const rsql.Blob(512), text: *Bounded(session_list.max_last_line_bytes)) ?[]const u8 {
    const bytes = utf8_validation.completePrefix((prefix orelse return null).slice());
    var lines = std.mem.splitAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        const trimmed = session_line.firstLine(line);
        if (trimmed.len == 0) continue;
        text.* = session_line.cut(session_list.max_last_line_bytes, trimmed);
        return text.slice();
    }
    return null;
}

/// Reads one Archived window page in one round. `head` and `below` read newest first; `above` and `tail`
/// read oldest first from their key and are returned newest first.
fn readArchivedWindow(a: *ReadAccess, cursor: session_list.ArchivedCursor, generation: u64, visitor: anytype) !void {
    var page: ArchivedPage = .{};
    const size = session_list.archived_window_size;
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
        a.readEach(archived_newest_page, .{ .below = below }, archived_window_limit, &page);
        try store_access.runAs(a, error.SessionReadFailed);
        if (page.failure) |err| return err;
        more_below = page.count > size;
        more_above = std.meta.activeTag(cursor) == .below;
        page.count = @min(page.count, size);
    } else if (oldest_above) |above| {
        a.readEach(archived_oldest_page, .{ .above = above }, archived_window_limit, &page);
        try store_access.runAs(a, error.SessionReadFailed);
        if (page.failure) |err| return err;
        // The oldest-first read keeps the rows nearest the cursor; the extra row is further away.
        more_above = page.count > size;
        more_below = std.meta.activeTag(cursor) == .above;
        page.count = @min(page.count, size);
        std.mem.reverse(ArchivedWindowRow, page.rows[0..page.count]);
    }
    try visitor.head();
    var text: Bounded(session_list.max_last_line_bytes) = undefined;
    for (page.rows[0..page.count]) |*row| {
        if (row.label) |*label| try configuration_domain.checkLabel(label.slice());
        const first: ?session_list.ArchivedFirst = if (row.first_admission) |admission| .{
            .admission = admission.get(),
            .line = archivedLine(if (row.first_line) |*prefix| prefix else null, &text),
        } else null;
        var values: session_list.ArchivedRow = .{
            .reference = row.session_ref.slice(),
            .archive_seq = row.archive_seq.get(),
            .stopped_at = row.stopped_at.get(),
            .label = if (row.label) |*label| label.slice() else null,
            .first = first,
        };
        try visitor.archivedRow(&values);
    }
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const since = (change_ring.Token{ .instance = a.store.instance, .generation = generation }).format(&token);
    try visitor.tail(.{ .window = .{
        .since = since,
        .first = if (page.count != 0) page.rows[0].archive_seq.get() else null,
        .last = if (page.count != 0) page.rows[page.count - 1].archive_seq.get() else null,
        .more_above = more_above,
        .more_below = more_below,
    } });
}

pub fn readSessionList(a: *ReadAccess, request: *const session_list.ListSessions, visitor: anytype) !void {
    const self = a.store;
    const generation = self.commit_generation.load(.acquire);
    if (request.window) |cursor| return readArchivedWindow(a, cursor, generation, visitor);
    if (request.since) |since| {
        const through = if (request.changed) |changed| changed.through else generation;
        if (std.mem.eql(u8, &since.instance, &self.instance) and through <= generation and self.changes.covers(since.generation))
            return readChangedSessions(a, request, since.generation, through, visitor);
    }
    try readAllSessions(a, request, generation, visitor);
}

fn readAllSessions(a: *ReadAccess, request: *const session_list.ListSessions, generation: u64, visitor: anytype) !void {
    var maximum: reads_domain.First(list_ceiling.Row) = .{};
    if (request.after == 0) a.readEach(list_ceiling, .{}, 1, &maximum);
    const bound: u64 = if (request.after == 0) std.math.maxInt(i64) else request.ceiling;
    var page: ListPage = .{};
    var live: LivePages = .{};
    const live_tab = request.workspace == null and request.archive == .active;
    if (request.workspace) |*workspace|
        a.readEach(workspace_list_page, .{ .after = request.after, .ceiling = bound, .digest = store_core.workspaceDigest(workspace.slice()), .workspace = workspace.slice(), .archive = request.archive }, list_limit, &page)
    else if (live_tab) {
        a.readEach(live_active_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.active);
        a.readEach(live_turn_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.turn);
        a.readEach(live_action_page, .{ .after = request.after, .ceiling = bound }, list_limit, &live.action);
    } else a.readEach(list_page, .{ .after = request.after, .ceiling = bound, .archive = request.archive }, list_limit, &page);
    try store_access.runAs(a, error.SessionReadFailed);
    if (live_tab) page = try mergeLive(&live);
    if (page.failure) |err| return err;
    const ceiling = if (request.after == 0) (maximum.row orelse return error.SessionReadFailed).ceiling else request.ceiling;
    try readRows(a, request, page.refs[0..page.count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const since = (change_ring.Token{ .instance = a.store.instance, .generation = generation }).format(&token);
    try visitor.tail(if (page.more)
        .{ .full = .{ .since = since, .after = page.last, .ceiling = ceiling } }
    else
        .{ .last = .{ .delta = .full, .since = since } });
}

const changed_ancestors = rsql.Read(.{
    .sql = "WITH RECURSIVE ancestors(session_ref,creator_ref) AS (" ++
        "SELECT session.session_ref,session.creator_ref FROM session JOIN session seed ON seed.creator_ref=session.session_ref " ++
        "WHERE seed.session_ref=?1 AND (?2 IS NULL OR session.workspace=?2)" ++ archive_membership.filterSql("session", "?3") ++
        " UNION SELECT session.session_ref,session.creator_ref FROM session JOIN ancestors child ON child.creator_ref=session.session_ref " ++
        "WHERE (?2 IS NULL OR session.workspace=?2)" ++ archive_membership.filterSql("session", "?3") ++ ") " ++
        "SELECT session_ref,NOT EXISTS (SELECT 1 FROM ancestors tail WHERE tail.creator_ref IS NULL OR NOT EXISTS " ++
        "(SELECT 1 FROM ancestors parent WHERE parent.session_ref=tail.creator_ref)) AS cycle FROM ancestors",
    .Args = struct { seed: []const u8, workspace: ?[]const u8, archive: session_archive.Filter },
    .Row = struct { session_ref: SessionText, cycle: bool },
    .cardinality = .each,
    .compound = true,
});

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

fn readChangedSessions(a: *ReadAccess, request: *const session_list.ListSessions, since: u64, through: u64, visitor: anytype) !void {
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
    var seed_after: ?change_ring.Id = null;
    while (true) {
        var seeds: [session_list.session_list_page_size + 1]change_ring.Id = undefined;
        const found = self.changes.changed(since, through, workspace, if (seed_after) |*id| id else null, &seeds);
        const count = @min(found.len, session_list.session_list_page_size);
        for (found[0..count]) |*seed| {
            candidates.add(seed);
            a.readEach(changed_ancestors, .{
                .seed = seed,
                .workspace = if (request.workspace) |*scope| scope.slice() else null,
                .archive = request.archive,
            }, std.math.maxInt(u64), &candidates);
            try runList(a);
            if (candidates.failure) |err| return err;
        }
        if (found.len <= session_list.session_list_page_size) break;
        seed_after = found[count - 1];
    }
    const changed = candidates.refs[0..candidates.count];
    const count = @min(changed.len, session_list.session_list_page_size);
    try readRows(a, request, changed[0..count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const next = (change_ring.Token{ .instance = self.instance, .generation = through }).format(&token);
    try visitor.tail(if (changed.len > count)
        .{ .changed = .{ .since = next, .through = through, .after_reference = &changed[count - 1] } }
    else
        .{ .last = .{ .delta = .changed, .since = next } });
}

const clock_columns =
    "(SELECT COALESCE((SELECT e.recorded_at FROM conversation_entry e WHERE e.source_admission_id=t.first_admission_id AND e.entry_kind=1)," ++
    "CASE WHEN m.turn_id IS NULL AND (SELECT o.purpose FROM model_operation o WHERE o.turn_id=t.turn_id ORDER BY o.operation_id DESC LIMIT 1)=1 THEN m.admitted_at END) " ++
    "FROM turn t JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
    "WHERE t.turn_id=(SELECT turn_id FROM turn WHERE session_ref=session.session_ref ORDER BY turn_id DESC LIMIT 1)) AS clock_started_at," ++
    "(SELECT max(o.resolved_at) FROM model_operation o JOIN turn t ON t.turn_id=o.turn_id " ++
    "WHERE t.turn_id=(SELECT turn_id FROM turn WHERE session_ref=session.session_ref ORDER BY turn_id DESC LIMIT 1) " ++
    "AND EXISTS (SELECT 1 FROM action_operation a WHERE a.parent_operation_id=o.operation_id AND a.approval_position IS NOT NULL)) AS clock_approval_entered_at," ++
    "(SELECT max((SELECT max(COALESCE(a.decided_at,a.resolved_at)) FROM action_operation a " ++
    "WHERE a.parent_operation_id=o.operation_id AND a.approval_position IS NOT NULL)) FROM model_operation o " ++
    "WHERE o.turn_id=(SELECT turn_id FROM turn WHERE session_ref=session.session_ref ORDER BY turn_id DESC LIMIT 1) " ++
    "AND NOT EXISTS (SELECT 1 FROM action_operation pending WHERE pending.parent_operation_id=o.operation_id " ++
    "AND pending.approval_position IS NOT NULL AND pending.authorized=0 AND pending.resolution_code IS NULL)) AS clock_approval_left_at,";

const descendant_page = rsql.Read(.{
    .sql = "WITH RECURSIVE descendants(origin,session_ref,workspace_digest,workspace) AS (" ++
        "SELECT session.session_ref,session.session_ref,session.workspace_digest,session.workspace FROM session " ++
        "WHERE session.session_ref IN (?1,?2,?3,?4,?5,?6,?7,?8) AND (?9 IS NULL OR (session.workspace_digest=?10 AND session.workspace=?9))" ++ archive_membership.filterSql("session", "?11") ++
        " UNION SELECT parent.origin,session.session_ref,session.workspace_digest,session.workspace FROM session @index(session_creator) JOIN descendants parent " ++
        "ON session.creator_ref=parent.session_ref AND session.workspace_digest=parent.workspace_digest AND session.workspace=parent.workspace " ++
        "WHERE 1=1" ++ archive_membership.filterSql("session", "?11") ++ ") " ++
        "SELECT member.origin,session.session_ref,session.created_at," ++ clock_columns[0 .. clock_columns.len - 1] ++
        ",EXISTS(SELECT 1 FROM session root WHERE root.session_ref=member.origin AND root.creator_ref IN " ++
        "(SELECT cycle_member.session_ref FROM descendants cycle_member WHERE cycle_member.origin=member.origin)) AS cycle " ++
        "FROM session JOIN descendants member ON member.session_ref=session.session_ref " ++
        "WHERE member.origin>?12 OR (member.origin=?12 AND session.session_ref>?13) ORDER BY member.origin,session.session_ref LIMIT 9",
    .Args = struct {
        root0: Bounded(session_id.bytes),
        root1: Bounded(session_id.bytes),
        root2: Bounded(session_id.bytes),
        root3: Bounded(session_id.bytes),
        root4: Bounded(session_id.bytes),
        root5: Bounded(session_id.bytes),
        root6: Bounded(session_id.bytes),
        root7: Bounded(session_id.bytes),
        workspace: ?[]const u8,
        digest: ?[32]u8,
        archive: session_archive.Filter,
        after_origin: Bounded(session_id.bytes),
        after_member: Bounded(session_id.bytes),
    },
    .Row = struct {
        origin: SessionText,
        session_ref: SessionText,
        created_at: rsql.Positive,
        clock_started_at: ?rsql.Positive,
        clock_approval_entered_at: ?rsql.Positive,
        clock_approval_left_at: ?rsql.Positive,
        cycle: bool,
    },
    .cardinality = .each,
    .compound = true,
});

const Rollup = struct {
    subtree_state_change_at: u64 = 0,
    descendant_count: u64 = 0,
    descendant_needs_you_count: u64 = 0,
};

const DescendantPage = struct {
    rows: [session_list.session_list_page_size + 1]descendant_page.Row = undefined,
    count: usize = 0,
    failure: ?error{CorruptStore} = null,

    pub fn visit(self: *DescendantPage, row: *const descendant_page.Row) bool {
        if (self.count == self.rows.len or row.origin.slice().len != change_ring.id_bytes or row.session_ref.slice().len != change_ring.id_bytes or row.cycle) {
            self.failure = error.CorruptStore;
            return false;
        }
        self.rows[self.count] = row.*;
        self.count += 1;
        return true;
    }
};

fn readRollups(a: *ReadAccess, request: *const session_list.ListSessions, references: []const change_ring.Id, now_ms: u64, works: []WorkRead, totals: []Rollup) !void {
    @memset(totals, .{});
    if (references.len == 0) return;
    var roots: [session_list.session_list_page_size]Bounded(session_id.bytes) = @splat(.{});
    for (references, 0..) |*reference, index| roots[index].set(reference) catch return error.CorruptStore;
    var after_origin: ?change_ring.Id = null;
    var after_member: ?change_ring.Id = null;
    while (true) {
        var page: DescendantPage = .{};
        a.readEach(descendant_page, .{
            .root0 = roots[0],
            .root1 = roots[1],
            .root2 = roots[2],
            .root3 = roots[3],
            .root4 = roots[4],
            .root5 = roots[5],
            .root6 = roots[6],
            .root7 = roots[7],
            .workspace = if (request.workspace) |*scope| scope.slice() else null,
            .digest = if (request.workspace) |*scope| store_core.workspaceDigest(scope.slice()) else null,
            .archive = request.archive,
            .after_origin = if (after_origin) |*id| Bounded(session_id.bytes).from(id) catch return error.CorruptStore else .{},
            .after_member = if (after_member) |*id| Bounded(session_id.bytes).from(id) catch return error.CorruptStore else .{},
        }, session_list.session_list_page_size + 1, &page);
        try runList(a);
        if (page.failure) |err| return err;
        const count = @min(page.count, session_list.session_list_page_size);
        if (count == 0) break;
        var work_count: usize = 0;
        for (page.rows[0..count]) |*row| {
            if (std.mem.eql(u8, row.origin.slice(), row.session_ref.slice())) continue;
            const read = &works[work_count];
            read.* = .{ .session = row.session_ref.slice() };
            _ = read.queue(a);
            work_count += 1;
        }
        if (work_count != 0) {
            try runList(a);
            for (works[0..work_count]) |*read| try read.advance();
            try readWorks(a, works[0..work_count]);
        }
        var work_index: usize = 0;
        for (page.rows[0..count]) |*row| {
            if (std.mem.eql(u8, row.origin.slice(), row.session_ref.slice())) continue;
            var index: usize = 0;
            while (index < references.len and !std.mem.eql(u8, row.origin.slice(), &references[index])) : (index += 1) {}
            if (index == references.len) return error.CorruptStore;
            const total = &totals[index];
            const read = &works[work_index];
            work_index += 1;
            const work = try read.work(row.created_at.get(), now_ms);
            total.subtree_state_change_at = @max(total.subtree_state_change_at, try stateChangeAt(.of(row), read, work));
            total.descendant_count = std.math.add(u64, total.descendant_count, 1) catch return error.CorruptStore;
            if (session_work.group(work) == .needs_you) total.descendant_needs_you_count = std.math.add(u64, total.descendant_needs_you_count, 1) catch return error.CorruptStore;
        }
        if (page.count <= session_list.session_list_page_size) break;
        after_origin = page.rows[count - 1].origin.slice()[0..change_ring.id_bytes].*;
        after_member = page.rows[count - 1].session_ref.slice()[0..change_ring.id_bytes].*;
    }
}

const settings_columns = "session.session_ref,session.archive_seq,session.parent_ref,session.creator_ref,session.workspace,session.provider,session.model," ++ tool_set.namesSql("session.tool_set_id") ++ " AS tools,session.permission_mode,session.label,session.created_at,session.revision,session.next_position," ++
    archive_membership.stateSql("session") ++ " AS archive_state," ++
    "(SELECT pin_command.command_seq FROM session_pin pin JOIN core_command pin_command ON pin_command.command_key=pin.command_key WHERE pin.session_ref=session.session_ref) AS pin_order," ++
    "(" ++ report_domain.person_message_sql ++ ") AS from_person_at," ++
    last_line_columns ++ "," ++ clock_columns;

const last_line_columns =
    "last_turn.outcome_position AS last_turn_position," ++
    "(SELECT substr(@payload(content),1,1024) FROM content WHERE content_id=last_turn.outcome_content_id " ++
    "AND private=0 AND last_turn.outcome_code='completed') AS last_answer," ++
    "awaiting.approval_position AS last_approval_position,awaiting_call.description AS last_approval_text";

const last_line_joins = " LEFT JOIN turn last_turn ON last_turn.turn_id=(SELECT turn_id FROM turn @index(turn_session_latest) " ++
    "WHERE session_ref=session.session_ref AND outcome_code IS NOT NULL ORDER BY turn_id DESC LIMIT 1) " ++
    "LEFT JOIN action_operation awaiting ON awaiting.action_id=?2 " ++
    "LEFT JOIN model_tool_call awaiting_call ON awaiting_call.operation_id=awaiting.parent_operation_id AND awaiting_call.call_ordinal=awaiting.call_ordinal ";

const list_row = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ report_domain.first_message_columns ++ " FROM session " ++
        "JOIN message_admission m ON m.admission_id=?3 AND m.session_ref=session.session_ref " ++ report_domain.first_content_join ++ last_line_joins ++ " WHERE session.session_ref=?1",
    .Args = struct { session: []const u8, first_action: ?u64, first: u64 },
    .Row = ListRow,
    .cardinality = .each,
});

const list_row_bare = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ "NULL AS first_admission,NULL AS first_position,NULL AS first_admitted_at,NULL AS first_sender," ++
        "NULL AS first_length,NULL AS first_digest,NULL AS first_private,NULL AS first_form FROM session" ++ last_line_joins ++ " WHERE session.session_ref=?1",
    .Args = struct { session: []const u8, first_action: ?u64 },
    .Row = ListRow,
    .cardinality = .each,
});

const ListRow = struct {
    session_ref: SessionText,
    archive_seq: ?rsql.Positive,
    parent_ref: ?Bounded(session_id.bytes),
    creator_ref: ?Bounded(session_id.bytes),
    workspace: Bounded(workspace_path.max_bytes),
    provider: provider_name.Provider,
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
    last_turn_position: ?rsql.Positive,
    last_answer: ?rsql.Blob(1024),
    last_approval_position: ?rsql.Positive,
    last_approval_text: ?Bounded(tool_presentation.max_description_bytes),
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
    firsts: [session_list.session_list_page_size]FirstCandidates,
    works: [session_list.session_list_page_size]WorkRead,
    shown: [session_list.session_list_page_size]ShownRow,
    decoded: ListRow,
    rollups: [session_list.session_list_page_size]Rollup,
};

noinline fn readRows(a: *ReadAccess, request: *const session_list.ListSessions, references: []const change_ring.Id, visitor: anytype) !void {
    const now_ms = try store_core.readUnixMilliseconds(a.store.io);
    try visitor.head();
    const scratch = a.store.reportScratch(ListScratch);
    const firsts = &scratch.firsts;
    const works = &scratch.works;
    const now = std.math.cast(u64, now_ms) orelse return error.IntegerOutOfRange;
    try readRollups(a, request, references, now, works, scratch.rollups[0..references.len]);
    for (references, firsts[0..references.len], works[0..references.len]) |*reference, *first, *work| {
        first.queue(a, reference);
        work.* = .{ .session = reference };
        _ = work.queue(a);
    }
    try runList(a);
    for (works[0..references.len]) |*work| try work.advance();
    try readWorks(a, works[0..references.len]);
    const shown = &scratch.shown;
    for (references, firsts[0..references.len], works[0..references.len], shown[0..references.len]) |*reference, *first, *work, *row|
        row.* = .{ .reference = reference, .first = first.admission(), .work = work };
    try readRowSettings(a, shown[0..references.len], scratch.rollups[0..references.len], &scratch.decoded, now, visitor);
}

const ShownRow = struct { reference: *const change_ring.Id, first: u64, work: *const WorkRead };

noinline fn readRowSettings(a: *ReadAccess, rows: []const ShownRow, rollups: []const Rollup, decoded: *ListRow, now_ms: u64, visitor: anytype) !void {
    var read: RowsRead(@TypeOf(visitor)) = .{ .read_version = .{ .instance = a.store.instance, .generation = a.store.commitGeneration() }, .decoded = decoded, .rows = rows, .rollups = rollups, .now_ms = now_ms, .visitor = visitor };
    for (rows) |row| {
        const work = try row.work.work(0, now_ms);
        if (row.first == 0)
            a.readEach(list_row_bare, .{ .session = row.reference, .first_action = work.first_action }, 1, &read)
        else
            a.readEach(list_row, .{ .session = row.reference, .first_action = work.first_action, .first = row.first }, 1, &read);
    }
    const ran = runList(a);
    if (read.failure) |err| return err;
    try ran;
    if (read.shown != rows.len) return error.CorruptStore;
}

fn RowsRead(comptime Visitor: type) type {
    return struct {
        read_version: change_ring.Token,
        decoded: *ListRow,
        rows: []const ShownRow,
        rollups: []const Rollup,
        now_ms: u64,
        visitor: Visitor,
        shown: usize = 0,
        failure: ?(ErrorOf(rowValues) || ErrorOf(@typeInfo(Visitor).pointer.child.row)) = null,

        pub fn visit(read: *@This(), row: *const ListRow) bool {
            if (read.failure != null) return false;
            var sorted: [tool_name.max_tools][]const u8 = undefined;
            var last_text: Bounded(session_list.max_last_line_bytes) = undefined;
            var values = rowValues(read.rows, read.rollups, read.shown, read.now_ms, row, &sorted, &last_text) catch |err| {
                read.failure = err;
                return false;
            };
            values.read_version = read.read_version;
            read.visitor.row(&values) catch |err| {
                read.failure = err;
                return false;
            };
            read.shown += 1;
            return true;
        }
    };
}

const ErrorOf = @import("../../error_set.zig").Of;

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

fn rowValues(rows: []const ShownRow, rollups: []const Rollup, index: usize, now_ms: u64, row: *const ListRow, sorted: *[tool_name.max_tools][]const u8, last_text: *Bounded(session_list.max_last_line_bytes)) !session_list.Row {
    if (index == rows.len or !std.mem.eql(u8, row.session_ref.slice(), rows[index].reference)) return error.CorruptStore;
    const names = try report_domain.sortedToolNames(if (row.tools) |*tools| tools.slice() else null, sorted);
    if (row.label) |*label| try configuration_domain.checkLabel(label.slice());
    const work = try rows[index].work.work(row.created_at.get(), now_ms);
    const permission_mode = try configuration_domain.permissionMode(row.permission_mode);
    const first_message = try report_domain.firstMessage(row, rows[index].first);
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
        .last_line = lastLine(row, last_text),
        .work = work,
        .peers = .{ .from_person_at = if (row.from_person_at) |at| at.get() else null },
    };
}

fn lastLine(row: anytype, text: *Bounded(session_list.max_last_line_bytes)) ?session_list.LastLine {
    const ended = if (row.last_turn_position) |position| position.get() else 0;
    if (row.last_approval_position) |position| if (position.get() > ended) return .{
        .position = position.get(),
        .text = if (row.last_approval_text) |*line| line.slice() else null,
    };
    if (ended == 0) return null;
    var answer: ?[]const u8 = null;
    if (row.last_answer) |*prefix| {
        const bytes = utf8_validation.completePrefix(prefix.slice());
        var lines = std.mem.splitAny(u8, bytes, "\r\n");
        while (lines.next()) |line| {
            const trimmed = session_line.firstLine(line);
            if (trimmed.len == 0) continue;
            text.* = session_line.cut(session_list.max_last_line_bytes, trimmed);
            answer = text.slice();
            break;
        }
    }
    return .{ .position = ended, .text = answer };
}

const last_line = rsql.Read(.{
    .sql = "SELECT " ++ last_line_columns ++ " FROM session" ++ last_line_joins ++ " WHERE session.session_ref=?1",
    .Args = struct { session: []const u8, first_action: ?u64 },
    .Row = struct {
        last_turn_position: ?rsql.Positive,
        last_answer: ?rsql.Blob(1024),
        last_approval_position: ?rsql.Positive,
        last_approval_text: ?Bounded(tool_presentation.max_description_bytes),
    },
    .cardinality = .optional,
});

pub const last_line_failures = .{.{ last_line, error.SessionReadFailed }};

pub const LastLineRead = struct {
    row: last_line.Row = undefined,
    found: store_access.Found = undefined,

    pub fn queue(self: *LastLineRead, a: *ReadAccess, session: []const u8, first_action: ?u64) void {
        a.readInto(last_line, .{ .session = session, .first_action = first_action }, &self.row, &self.found);
    }

    pub fn finish(self: *const LastLineRead, out: *?session_list.SavedLastLine) !void {
        if (!self.found.get()) return error.CorruptStore;
        var text: Bounded(session_list.max_last_line_bytes) = undefined;
        out.* = if (lastLine(&self.row, &text)) |line| .{ .position = line.position, .text = if (line.text) |bytes| blk: {
            var owned: Bounded(session_list.max_last_line_bytes) = .{};
            try owned.set(bytes);
            break :blk owned;
        } else null } else null;
    }
};
