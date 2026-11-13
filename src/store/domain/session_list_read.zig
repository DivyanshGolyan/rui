//! The session list as the Store reads it: a page of Sessions in scope,
//! each row's plain values (`session_list.Row`) handed to a visitor as its
//! read steps, then the page's tail. The Host writes the reply.

const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const change_ring = @import("../../change_ring.zig");
const model_capability = @import("../../model_capability.zig");
const provider_name = @import("../../provider_name.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const session_list = @import("../../session_list.zig");
const session_line = @import("../../session_line.zig");
const tool_name = @import("../../tool_name.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const workspace_path = @import("../../workspace_path.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const command_domain = @import("command.zig");
const configuration_domain = @import("configuration.zig");
const reads_domain = @import("reads.zig");
const report_domain = @import("report.zig");
const tool_set = @import("tool_set.zig");
const ReadAccess = reads_domain.ReadAccess;
const FirstCandidates = report_domain.FirstCandidates;
const WorkRead = report_domain.WorkRead;
const readWorks = report_domain.readWorks;
const SessionText = Bounded(session_id.max_reference_bytes);

/// Remembers whether `visitor` failed. Its failure is its own, such as
/// exhausted scratch, which is ordinary and does not fence the Store.
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

        pub fn tail(w: *@This(), values: session_list.Tail) !void {
            w.visitor.tail(values) catch |err| {
                w.failed = true;
                return err;
            };
        }
    };
}

/// The name main gave each list statement whose step fails, beside the
/// first-Message and work reads it shares with the Current report.
pub const list_failures = .{
    .{ list_ceiling, error.SessionReadFailed },
    .{ list_page, error.SessionReadFailed },
    .{ workspace_list_page, error.SessionReadFailed },
    .{ workspace_key, error.SessionReadFailed },
    .{ list_row, error.SessionReadFailed },
    .{ list_row_bare, error.SessionReadFailed },
} ++ report_domain.report_failures;

/// Ends a round of this file's reads, naming a failed step by
/// `list_failures`.
fn runList(a: *ReadAccess) !void {
    return store_access.runNamed(a, list_failures, error.CorruptStore);
}

/// Active includes a stop still completing. All avoids archive seeks;
/// otherwise compare whether the Session is completely archived.
fn archiveFilterSql(comptime parameter: []const u8) []const u8 {
    return " AND (" ++ parameter ++ "='all' OR ((" ++ command_domain.archive_state_sql ++ ")='archived')=(" ++ parameter ++ "='archived'))";
}

/// The newest Session's creation sequence, the ceiling of a list that
/// starts from the beginning.
const list_ceiling = rsql.Read(.{
    .sql = "SELECT coalesce(max(created_seq),0) AS ceiling FROM session",
    .Args = struct {},
    .Row = struct { ceiling: u64 },
    .cardinality = .each,
});

/// A page and one Session more, which says whether there are more: the
/// `LIMIT` of each page read and its `readEach` bound.
const list_limit = session_list.session_list_page_size + 1;

/// A full traversal's page of Sessions in creation order, with the one
/// after it. The index walks hidden candidates until nine pass the derived
/// archive filter; the result retains only those nine references.
const list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session WHERE created_seq>?1 AND created_seq<=?2" ++ archiveFilterSql("?3") ++ " ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64, archive: session_archive.Filter },
    .Row = ListPage.Row,
    .cardinality = .each,
});

/// `list_page` within one Workspace.
const workspace_list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session @index(session_workspace_list) " ++
        "WHERE workspace_digest=?3 AND workspace=?4 AND created_seq>?1 AND created_seq<=?2" ++ archiveFilterSql("?5") ++ " ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64, digest: [32]u8, workspace: []const u8, archive: session_archive.Filter },
    .Row = ListPage.Row,
    .cardinality = .each,
});

/// The change ring's key for a Workspace: the stored key of its
/// Sessions, or none while it has none.
const workspace_key = rsql.Read(.{
    .sql = "SELECT workspace_key FROM session WHERE workspace_digest=?1 AND workspace=?2 LIMIT 1",
    .Args = struct { digest: [32]u8, workspace: []const u8 },
    .Row = struct { workspace_key: rsql.Positive },
    .cardinality = .optional,
});

/// A page of a full traversal: its Sessions' references, up to a page,
/// and whether a Session follows them (`list_limit`).
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
        // The session table's CHECK (schema.zig) holds every stored
        // reference to `id_bytes`; main read any up to 128 bytes.
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

/// Reads one list page on `a` and hands it to `visitor`, whose `head()`,
/// `row(*const session_list.Row)` and `tail(session_list.Tail)` each
/// return an error union: the head once the page's Sessions are known,
/// each row as its read steps, in page order, then the tail. A visitor's
/// error stops the read and is its answer.
pub fn readSessionList(a: *ReadAccess, request: *const session_list.ListSessions, visitor: anytype) !void {
    const self = a.store;
    const generation = self.commit_generation.load(.acquire);
    // Changed rows answer while the hint still covers the token; a token
    // from another opening, or one too old, gets a full traversal.
    if (request.since) |since| {
        const through = if (request.changed) |changed| changed.through else generation;
        if (std.mem.eql(u8, &since.instance, &self.instance) and through <= generation and self.changes.covers(since.generation))
            return readChangedSessions(a, request, since.generation, through, visitor);
    }
    try readAllSessions(a, request, generation, visitor);
}

/// Every Session in scope, in creation order, eight per page. A full
/// traversal applies the archive filter before LIMIT, within the request's
/// scope, `after` and `ceiling`. A list from the beginning reads its ceiling
/// in the page's round: every
/// Session is at or below the newest, so the page needs no bound then.
fn readAllSessions(a: *ReadAccess, request: *const session_list.ListSessions, generation: u64, visitor: anytype) !void {
    // An aggregate has one row, stepped once, as main did.
    var maximum: reads_domain.First(list_ceiling.Row) = .{};
    if (request.after == 0) a.readEach(list_ceiling, .{}, 1, &maximum);
    const bound: u64 = if (request.after == 0) std.math.maxInt(i64) else request.ceiling;
    var page: ListPage = .{};
    if (request.workspace) |*workspace|
        a.readEach(workspace_list_page, .{ .after = request.after, .ceiling = bound, .digest = store_core.workspaceDigest(workspace.slice()), .workspace = workspace.slice(), .archive = request.archive }, list_limit, &page)
    else
        a.readEach(list_page, .{ .after = request.after, .ceiling = bound, .archive = request.archive }, list_limit, &page);
    try store_access.runAs(a, error.SessionReadFailed);
    if (page.failure) |err| return err;
    const ceiling = if (request.after == 0) (maximum.row orelse return error.SessionReadFailed).ceiling else request.ceiling;
    try readRows(a, page.refs[0..page.count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const since = (change_ring.Token{ .instance = a.store.instance, .generation = generation }).format(&token);
    try visitor.tail(if (page.more)
        .{ .full = .{ .since = since, .after = page.last, .ceiling = ceiling } }
    else
        .{ .last = .{ .delta = .full, .since = since } });
}

/// The Sessions in scope that the hint says changed in (since, through],
/// in ID order, eight per page: the Workspace's key, then one pass over
/// the ring in memory, then the shown rows. A Session it names may be
/// unchanged; one it omits did not change. The archive filter deliberately
/// does not apply: caches need transitions out of their visible set too.
/// Tokens are scope-unbound hints; a changed archive/workspace filter needs
/// a fresh full traversal, not reuse of the previous scope's token.
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
    var references: [session_list.session_list_page_size + 1]change_ring.Id = undefined;
    const changed = self.changes.changed(since, through, workspace, after, &references);
    const count = @min(changed.len, session_list.session_list_page_size);
    try readRows(a, changed[0..count], visitor);
    var token: [change_ring.Token.max_bytes]u8 = undefined;
    const next = (change_ring.Token{ .instance = self.instance, .generation = through }).format(&token);
    try visitor.tail(if (changed.len > count)
        .{ .changed = .{ .since = next, .through = through, .after_reference = &changed[count - 1] } }
    else
        .{ .last = .{ .delta = .changed, .since = next } });
}

const settings_columns = "session.session_ref,session.parent_ref,session.workspace,session.provider,session.model," ++ tool_set.namesSql("session.tool_set_id") ++ " AS tools,session.permission_mode,session.label,session.created_at,session.revision,session.next_position," ++
    command_domain.archive_state_sql ++ " AS archive_state," ++
    "(" ++ report_domain.person_message_sql ++ ") AS from_person_at," ++
    last_line_columns ++ ",";

const last_line_columns =
    "last_turn.outcome_position AS last_turn_position," ++
    "(SELECT substr(@payload(content),1,1024) FROM content WHERE content_id=last_turn.outcome_content_id " ++
    "AND private=0 AND last_turn.outcome_code='completed') AS last_answer," ++
    "awaiting.approval_position AS last_approval_position,awaiting_call.description AS last_approval_text";

/// Only the newest Turn can be active: this seek visits at most two Turns.
/// Work already selected the oldest pending approval: ?2 is its first_action,
/// including beside running Actions. Join that Action directly, without a
/// second owner of the selection or an additional page or content round.
const last_line_joins = " LEFT JOIN turn last_turn ON last_turn.turn_id=(SELECT turn_id FROM turn @index(turn_session_latest) " ++
    "WHERE session_ref=session.session_ref AND outcome_code IS NOT NULL ORDER BY turn_id DESC LIMIT 1) " ++
    "LEFT JOIN action_operation awaiting ON awaiting.action_id=?2 " ++
    "LEFT JOIN model_tool_call awaiting_call ON awaiting_call.operation_id=awaiting.parent_operation_id AND awaiting_call.call_ordinal=awaiting.call_ordinal ";

/// One list row: the Session's settings, its latest Message from no
/// Session, and its first Message, the admission ?3. A missing Message
/// or content finds no row. Its Row is over 1 KiB, so its visitor owns
/// it (`RowsRead`).
const list_row = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ report_domain.first_message_columns ++ " FROM session " ++
        "JOIN message_admission m ON m.admission_id=?3 AND m.session_ref=session.session_ref " ++ report_domain.first_content_join ++ last_line_joins ++ " WHERE session.session_ref=?1",
    .Args = struct { session: []const u8, first_action: ?u64, first: u64 },
    .Row = ListRow,
    .cardinality = .each,
});

/// `list_row` of a Session with no first Message.
const list_row_bare = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ "NULL AS first_admission,NULL AS first_position,NULL AS first_admitted_at,NULL AS first_sender," ++
        "NULL AS first_length,NULL AS first_digest,NULL AS first_private FROM session" ++ last_line_joins ++ " WHERE session.session_ref=?1",
    .Args = struct { session: []const u8, first_action: ?u64 },
    .Row = ListRow,
    .cardinality = .each,
});

const ListRow = struct {
    session_ref: SessionText,
    parent_ref: ?Bounded(session_id.bytes),
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
    from_person_at: ?rsql.Positive,
    last_turn_position: ?rsql.Positive,
    last_answer: ?rsql.Blob(1024),
    last_approval_position: ?rsql.Positive,
    last_approval_text: ?Bounded(tool_presentation.max_description_bytes),
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
};

/// The page head and its rows. Each row's first admission and work take
/// the rounds their reads depend on, shared by every row; the rows'
/// settings come last (`readRowSettings`), so the page holds one row's
/// text at a time and not eight.
noinline fn readRows(a: *ReadAccess, references: []const change_ring.Id, visitor: anytype) !void {
    const now_ms = try store_core.readUnixMilliseconds(a.store.io);
    try visitor.head();
    var firsts: [session_list.session_list_page_size]FirstCandidates = undefined;
    var works: [session_list.session_list_page_size]WorkRead = undefined;
    // Each row's reads queued together: a pass ends where a statement is
    // queued again, so the round takes one pass per row, not two.
    for (references, firsts[0..references.len], works[0..references.len]) |*reference, *first, *work| {
        first.queue(a, reference);
        work.* = .{ .session = reference };
        _ = work.queue(a);
    }
    try runList(a);
    for (works[0..references.len]) |*work| try work.advance();
    try readWorks(a, works[0..references.len]);
    var shown: [session_list.session_list_page_size]ShownRow = undefined;
    for (references, firsts[0..references.len], works[0..references.len], shown[0..references.len]) |*reference, *first, *work, *row|
        row.* = .{ .reference = reference, .first = first.admission(), .work = work };
    try readRowSettings(a, shown[0..references.len], std.math.cast(u64, now_ms) orelse return error.IntegerOutOfRange, visitor);
}

/// What a list row read before its settings.
const ShownRow = struct { reference: *const change_ring.Id, first: u64, work: *const WorkRead };

/// Reads each shown row's `list_row` in one round and visits it as it
/// steps. The row it decodes is in report scratch (`ListRow`).
noinline fn readRowSettings(a: *ReadAccess, rows: []const ShownRow, now_ms: u64, visitor: anytype) !void {
    var read: RowsRead(@TypeOf(visitor)) = .{ .read_version = .{ .instance = a.store.instance, .generation = a.store.commitGeneration() }, .decoded = a.store.reportScratch(ListRow), .rows = rows, .now_ms = now_ms, .visitor = visitor };
    for (rows) |row| {
        // Creation time only dates idle work, which has no Action. Its real
        // value is read with the settings; the approval selection needs none.
        const work = try row.work.work(0, now_ms);
        if (row.first == 0)
            a.readEach(list_row_bare, .{ .session = row.reference, .first_action = work.first_action }, 1, &read)
        else
            a.readEach(list_row, .{ .session = row.reference, .first_action = work.first_action, .first = row.first }, 1, &read);
    }
    const ran = runList(a);
    // A pass stops at a failed step, so a row that failed to be visited
    // did before any later row's step failed: its error is main's first.
    if (read.failure) |err| return err;
    try ran;
    if (read.shown != rows.len) return error.CorruptStore;
}

/// Hands each `list_row` to the visitor as it steps, in the page's order.
/// A row that is not the next shown Session's, or a missing one, is
/// `CorruptStore`; after a failure it visits nothing more.
fn RowsRead(comptime Visitor: type) type {
    return struct {
        read_version: change_ring.Token,
        decoded: *ListRow,
        rows: []const ShownRow,
        now_ms: u64,
        visitor: Visitor,
        shown: usize = 0,
        failure: ?(ErrorOf(rowValues) || ErrorOf(@typeInfo(Visitor).pointer.child.row)) = null,

        pub fn visit(read: *@This(), row: *const ListRow) bool {
            if (read.failure != null) return false;
            var sorted: [tool_name.max_tools][]const u8 = undefined;
            var last_text: Bounded(session_list.max_last_line_bytes) = undefined;
            var values = rowValues(read.rows, read.shown, read.now_ms, row, &sorted, &last_text) catch |err| {
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

/// The plain values of the shown row `index`, checked in main's order.
/// They borrow `row`, `sorted` and `last_text`.
fn rowValues(rows: []const ShownRow, index: usize, now_ms: u64, row: *const ListRow, sorted: *[tool_name.max_tools][]const u8, last_text: *Bounded(session_list.max_last_line_bytes)) !session_list.Row {
    if (index == rows.len or !std.mem.eql(u8, row.session_ref.slice(), rows[index].reference)) return error.CorruptStore;
    const names = try report_domain.sortedToolNames(if (row.tools) |*tools| tools.slice() else null, sorted);
    if (row.label) |*label| try configuration_domain.checkLabel(label.slice());
    const work = try rows[index].work.work(row.created_at.get(), now_ms);
    const permission_mode = try configuration_domain.permissionMode(row.permission_mode);
    const first_message = try report_domain.firstMessage(row, rows[index].first);
    return .{
        .archive_state = row.archive_state,
        .reference = row.session_ref.slice(),
        .parent = if (row.parent_ref) |*parent| parent.slice() else null,
        .workspace = row.workspace.slice(),
        .provider = row.provider,
        .model = row.model.slice(),
        .tools = names,
        .permission_mode = permission_mode,
        .label = if (row.label) |*label| label.slice() else null,
        .created_at = row.created_at.get(),
        .revision = row.revision.get(),
        .end = row.next_position.get() - 1,
        .first_message = first_message,
        .last_line = lastLine(row, last_text),
        .work = work,
        .peers = .{ .from_person_at = if (row.from_person_at) |at| at.get() else null },
    };
}

/// The newest thing the Session said to its person. A decision removes an
/// approval from the candidates, leaving the newest ended Turn again. Text
/// borrows the decoded row or `text`, only until this row's visitor returns.
fn lastLine(row: anytype, text: *Bounded(session_list.max_last_line_bytes)) ?session_list.LastLine {
    const ended = if (row.last_turn_position) |position| position.get() else 0;
    if (row.last_approval_position) |position| if (position.get() > ended) return .{
        .position = position.get(),
        .text = if (row.last_approval_text) |*line| line.slice() else null,
    };
    if (ended == 0) return null;
    var answer: ?[]const u8 = null;
    if (row.last_answer) |*prefix| {
        // The bounded byte prefix can end inside a UTF-8 code point. Drop
        // only that incomplete suffix before choosing a non-blank line.
        var bytes = prefix.slice();
        if (bytes.len != 0) {
            var start = bytes.len - 1;
            while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
            const width = std.unicode.utf8ByteSequenceLength(bytes[start]) catch 1;
            if (start + width > bytes.len) bytes = bytes[0..start];
        }
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

/// Activity snapshots and listings use the same last-line columns and
/// projection, under their existing read Access. No frontend reconstructs
/// this value from rendered or partially resident conversation text.
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

/// The canonical preview queued into an activity page's existing item round.
/// Its row stays in the caller's frame until that round has completed; no
/// standalone Access.run or second approval-selection rule is needed.
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
