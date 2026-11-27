const std = @import("std");
const session_archive = @import("session_archive.zig");
const session_class = @import("session_class.zig");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const attention = @import("attention.zig");
const change_ring = @import("change_ring.zig");
const failure_class = @import("failure_class.zig");
const state_marks = @import("marks.zig");
const say_text = @import("testing/say_text.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const model_picker = @import("model_picker.zig");
const model_picker_view = @import("model_picker_view.zig");
const overview_style = @import("overview_style.zig");
const provider_name = @import("provider_name.zig");
const connection = @import("connection.zig");
const connection_names = @import("connection_names.zig");
const provider_route = @import("provider_route.zig");
const session_list = @import("session_list.zig");
const session_work = @import("session_work.zig");
const session_upgrade = @import("session_upgrade.zig");
const upgrade_status = @import("upgrade_status.zig");
const submission = @import("submission_state.zig");
const TerminalText = @import("TerminalText.zig");
const work_line = @import("work_line.zig");
const utf8_validation = @import("utf8_validation.zig");
const content_value = @import("content_value.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

const Allocator = std.mem.Allocator;
pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;
pub const Token = change_ring.Token;
pub const ArchiveState = session_archive.State;
pub const ArchiveFilter = session_archive.Filter;

pub const Reference = change_ring.Id;

pub const max_label_bytes = @import("tool_presentation.zig").max_label_bytes;

pub const max_page_rows = 8;

pub const max_first_line_reads = 8;

pub const max_line_bytes = session_line.max_line_bytes;

pub const max_line_read_bytes = max_line_bytes + 1;

pub const max_requests = 8;

pub const list_interval_ms = 1000;

pub const spin_interval_ms = 200;

pub const mark_column = 1;
pub const text_column = 3;

pub const max_handle_bytes = 36;
pub const max_configure_intent_bytes = 1024;
const configure_departure_prefix = "rui: Configure for {s} in Store ";
const configure_departure_suffix = " is not confirmed: {s}. Original: ~/.config/rui/requests/{s}.json. Recovery with rui request recover {s} may apply this older setting.\n";
pub const max_departure_entry_bytes = @max(512, configure_departure_prefix.len + configure_departure_suffix.len + @sizeOf(Reference) + TerminalText.max_bytes_per_byte * @import("store_path.zig").max_bytes + max_configure_intent_bytes + 2 * @max(max_handle_bytes, session_work.max_code_bytes));
pub const max_departure_bytes = @as(usize, max_requests) * max_departure_entry_bytes;

pub const Selection = union(enum) { none, new_session, sessions, archived, session: Reference, settings };
pub const Mark = state_marks.Mark;
pub const Colour = overview_style.Colour;
pub const Background = overview_style.Background;

pub const Rule = struct {
    colour: Colour,
    word: ?[]const u8 = null,

    says: bool = false,

    spins: bool = false,

    /// The word an active row shows in its age column when it holds still.
    held: ?[]const u8 = null,

    cause: bool = false,
};

pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .colour = .normal, .word = "idle" },
    .pending = .{ .colour = .quiet },
    .working = .{ .colour = .ink, .spins = true, .held = "working" },
    .retrying = .{ .colour = .ink, .says = true, .held = "retrying" },
    .bash = .{ .colour = .ink, .says = true, .spins = true, .held = "working" },
    .approval = .{ .colour = .attention },
    .stopping = .{ .colour = .ink, .says = true, .held = "stopping" },
    .finished = .{ .colour = .mark, .word = "finished" },
    .failed = .{ .colour = .failure, .word = "failed", .cause = true },
    .stopped = .{ .colour = .normal, .word = "stopped" },
});

comptime {
    for (std.enums.values(Kind)) |kind| {
        const rule = rules.get(kind);
        if ((kind.sign() == .active) != (rule.held != null)) @compileError("an active row's rule must name its held word, and only active rules may");
    }
}

pub const marks = state_marks.marks;

pub const spinner = state_marks.spinner;

pub const Action = enum {
    previous,
    next,
    select_previous,
    select_next,
    previous_session,
    next_session,
    first,
    last,
    clear,
    exit,
    stop,
    archive,
    open_session,
    collapse_tree,
    expand_tree,
    next_question,
};

pub const keys: keymap.Keymap(Action) = .init(.{
    .escape = .clear,
    .ctrl_g = .clear,
    .ctrl_c = .exit,
    .ctrl_d = .exit,
    .ctrl_n = null,
    .ctrl_o = null,
    .ctrl_p = null,
    .ctrl_r = null,
    .ctrl_x = .stop,
    .alt_a = .archive,
    .alt_question = .next_question,
    .alt_up = .previous_session,
    .alt_down = .next_session,
    .up = .previous,
    .down = .next,
    .left = null,
    .right = .open_session,
    // Focus order's keys, which `app_input.keys` takes first.
    .tab = null,
    .shift_tab = null,
    .shift_up = .select_previous,
    .shift_down = .select_next,
    .alt_left = .collapse_tree,
    .alt_right = .expand_tree,
    .page_up = null,
    .page_down = null,
    .home = .first,
    .end = .last,
    .ctrl_end = null,
});

test "keys list covers both screens without unbound or duplicate keys" {
    try std.testing.expectEqual(@as(?keymap.ListError, null), keymap.listError(.{ keys, @import("session_keys.zig").keys, @import("app_input.zig").keys }));
}

pub const Input = union(enum) { action: Action, enter, left, ignored };

pub const InputDelivery = struct {
    key: Input,
    under: bool = false,
    pasted: bool = false,
    wide: bool = false,
    list_origin: bool = true,
    at_ms: ?u64 = null,
};

pub const Delta = enum {
    not_modified,
    changed,
    full,

    pub fn of(delta: anytype) Delta {
        return switch (delta) {
            .not_modified => .not_modified,
            .changed => .changed,
            .full => .full,
            // The roster never requests a window, and protocol_reply refuses a window reply before it gets here.
            .window => unreachable,
        };
    }
};

pub const First = struct {
    position: u64,
    admission: u64,

    sender: ?Reference,
    /// The Message's value, whose first display line names an unlabelled Session. An Archived window row
    /// carries it too: a parts-form row with no inline line reads its line through this value.
    content: ?content_value.Value,
    /// The raw leading bytes of an Archived window row's inline Text first Message; null otherwise.
    line: ?[]const u8 = null,
};

pub const Listed = struct {
    reference: Reference,
    creator: ?Reference = null,
    read_version: Token = .{ .instance = @splat(0), .generation = 0 },
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,
    /// The Host's Archived key; null while active.
    archive_seq: ?u64 = null,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    created_at: u64 = 0,
    state_change_at: u64,
    subtree_state_change_at: u64,
    descendant_count: u64,
    descendant_needs_you_count: u64,
    workspace: []const u8,
    provider: Provider,
    model: []const u8 = "",
    label: ?[]const u8 = null,
    state: WorkState,

    turn: ?u64 = null,

    first_action: ?u64 = null,
    actions: session_work.Actions = .{},
    first: ?First = null,

    from_person_at: ?u64 = null,

    pub fn of(row: anytype) Listed {
        return .{
            .reference = referenceOf(row.reference.slice()),
            .creator = if (row.creator) |*creator| referenceOf(creator.slice()) else null,
            .read_version = row.read_version,
            .operation = row.work.operation,
            .archive_state = row.archive_state,
            .archive_seq = row.archive_seq,
            .pin_order = row.pin_order,
            .created_at = row.created_at,
            .state_change_at = row.state_change_at,
            .subtree_state_change_at = row.subtree_state_change_at,
            .descendant_count = row.descendant_count,
            .descendant_needs_you_count = row.descendant_needs_you_count,
            .workspace = row.workspace.slice(),
            .provider = row.provider,
            .model = row.model.slice(),
            .label = if (row.label) |*text| text.slice() else null,
            .state = row.work.state,
            .turn = row.work.turn,
            .first_action = row.work.first_action,
            .actions = row.work.actions,
            .first = if (row.first_message) |*message| .{
                .position = message.position,
                .admission = message.admission,
                .sender = if (message.sender) |*sender| referenceOf(sender.session.slice()) else null,
                .content = message.content,
            } else null,
            .from_person_at = row.peers.from_person_at,
        };
    }

    fn referenceOf(bytes: []const u8) Reference {
        std.debug.assert(bytes.len == change_ring.id_bytes);
        return bytes[0..change_ring.id_bytes].*;
    }

    /// An Archived window row, as the slim wire row gives it.
    pub fn archived(row: anytype) Listed {
        return .{
            .reference = referenceOf(row.reference.slice()),
            .archive_state = .archived,
            .archive_seq = row.archive_seq,
            .label = if (row.label) |*text| text.slice() else null,
            .workspace = "",
            .provider = pn(.codex),
            .state = .{ .stopped = .{ .since = row.stopped_at, .cause = .stop } },
            .state_change_at = 0,
            .subtree_state_change_at = 0,
            .descendant_count = 0,
            .descendant_needs_you_count = 0,
            .first = if (row.first) |*first| .{
                .position = first.position,
                .admission = first.admission,
                .sender = if (first.sender) |*sender| referenceOf(sender.session.slice()) else null,
                .content = first.content,
                .line = if (row.first_prefix) |*prefix| prefix.slice() else null,
            } else null,
        };
    }
};

/// One Archived window page as the overview reads it: rows newest archive first, and the page's edge keys.
pub const ArchivedPage = struct {
    since: Token,
    rows: []const Listed,
    first: ?u64,
    last: ?u64,
    more_above: bool,
    more_below: bool,

    pub fn of(page: anytype, buffer: []Listed) ArchivedPage {
        for (page.rows[0..page.count], buffer[0..page.count]) |*row, *listed| listed.* = Listed.archived(row);
        return .{ .since = page.since, .rows = buffer[0..page.count], .first = page.first, .last = page.last, .more_above = page.more_above, .more_below = page.more_below };
    }
};

pub const Answer = struct { delta: Delta, since: Token };

pub const Page = struct {
    rows: []const Listed,

    restarts: bool = false,

    answer: ?Answer,

    /// `since_walk` is true when the walk began with a since token. Such a walk that the Host answers in full ends
    /// on that page: its archived pages are never read, and the overview walks the live roster afresh.
    pub fn of(traversal: anytype, page: anytype, buffer: *[max_page_rows]Listed, since_walk: bool) Page {
        for (page.rows[0..page.count], buffer[0..page.count]) |*row, *listed| listed.* = .of(row);
        const restarts = traversal.restarts(page);
        const more = traversal.advance(page) and !(since_walk and page.delta == .full);
        return .{
            .rows = buffer[0..page.count],
            .restarts = restarts,
            .answer = if (more) null else .{ .delta = .of(traversal.delta), .since = traversal.since.? },
        };
    }
};

pub const ListReply = union(enum) { page: Page, failed };

pub const FirstLine = struct {
    reference: Reference,
    admission: u64,

    line: ?[]const u8,

    unanswered: bool = false,
};

pub const mib = 1024 * 1024;

pub const Memory = @import("process_memory.zig").Memory;

pub const Host = struct {
    instance: [16]u8 = @splat(0),
    started_at: u64,
    slots: u64,
    slots_in_use: u64,
    /// The connection names the Host serves, from its reported capabilities.
    served: connection_names.NameSet = .{},
};

pub const StopOutcome = union(enum) {
    stopped,

    failed: []const u8,

    unconfirmed: []const u8,
};

pub const PinRequest = struct { reference: Reference, pinned: bool };
pub const PinResult = struct { request: PinRequest, outcome: union(enum) { accepted, failed: []const u8, unconfirmed: []const u8 } };

pub const ArchiveRequest = struct {
    reference: Reference,
    archived: bool = true,
};

pub const ArchiveResult = struct {
    request: ArchiveRequest,
    outcome: union(enum) {
        requested: enum { pending, completed },
        failed: []const u8,
        unconfirmed: []const u8,
    },
};

pub const StopResult = struct {
    reference: Reference,
    outcome: StopOutcome,
};

pub const CreateResult = union(enum) {
    created: struct { reference: Reference, handle: []const u8 },

    failed: []const u8,

    unconfirmed: []const u8,
};

/// The span of list lines the shell is showing, first through end (exclusive), as the list drew them.
pub const Viewport = struct { first: usize, end: usize };
/// The same span by the references of its first and last Session rows.
const ViewRows = struct { first: Reference, last: Reference };
/// The order indices a window must keep, first through end (exclusive).
const Focus = struct { first: usize, end: usize };

const ParentClick = struct {
    reference: Reference,
    deadline_ms: u64,
    released: bool = false,

    const interval_ms = 300;
};

pub const Event = union(enum) {
    input: InputDelivery,
    list_settled: struct { wide: bool, focused: bool, click_clock_ms: ?u64 = null },
    list_presence: struct { at_ms: u64, pointer_over: bool },
    /// The pointer after a press, over the drawn target under it: a left drag, its release, or a move with no
    /// button held. Lists report it wherever the press landed (see `Carry`).
    pointer: Pointer,
    /// The lines the list shows after a wheel scroll, reported after the draw that applies it.
    viewport: Viewport,

    resized: Size,
    launch_start: LaunchIntent,
    launch_size: struct { size: Size, wide: bool },
    launch_poll,
    presentation_start: u64,
    presentation_presented,
    presentation_tick: struct { now_ms: u64, list_visible: ?bool, host_unavailable: bool },

    tick: u64,
    list: ListReply,
    archived: ArchivedAnswer,
    first_line: FirstLine,
    stop: StopResult,
    archive: ArchiveResult,
    pin: PinResult,
    created: CreateResult,

    leave,

    open: Reference,

    host: ?Host,

    memory: Memory,

    upgrade: upgrade_status.Run,
    available_upgrade: ?upgrade_status.Version,
    conversed: Conversed,

    models: ModelsRead,

    defaults_saved: ?Default,

    start_upgrade,

    observed: Observed,
    conversation: ?Reference,

    clicked: struct { target: Click, upgrade_admitted: bool = true, at_ms: ?u64 = null },

    unconfirmed: Unconfirmed,
};

pub const Click = union(enum) {
    open: Reference,
    pin: PinRequest,
    new_session,
    sessions,
    archived,
    settings,
    update: upgrade_status.Target,
};

pub const Unconfirmed = struct { reference: Reference, recovery: submission.Recovery };

pub const Pointer = struct { over: ?Click, phase: enum { held, released, free } };

/// A chat row pressed and dragged onto a tab: a live chat dropped on Archived is archived, an archived one dropped
/// on Chats is restored, through the same requests as Alt-A and restore. The press itself opens the row as a click
/// does; the drag starts once a held pointer leaves that row. Any other release, any press or move with no button
/// held anywhere on screen (Root reports those as `free`), a key or another click ends it.
pub const Carry = struct {
    /// The row receiving the primary press, until that press ends.
    pressed: ?Reference = null,
    /// The pressed row's drag has left it.
    carrying: bool = false,
    /// The drawn target under the held pointer.
    over: ?Click = null,

    /// The tab that takes the carried row, if any: Archived for a live chat, Chats for an archived one, none for
    /// one already being archived (Alt-A refuses it too).
    pub fn dropTarget(self: Carry, state: *const State) ?Click {
        if (!self.carrying) return null;
        const row = state.find(self.pressed.?) orelse return null;
        return switch (row.archive_state) {
            .active => .archived,
            .archived => .sessions,
            .archiving => null,
        };
    }

    fn dropping(self: Carry, state: *const State) bool {
        const target = self.dropTarget(state) orelse return false;
        return self.over != null and std.meta.eql(self.over.?, target);
    }
};

pub const max_unconfirmed_line_bytes = 80;

/// The newest send whose outcome is unknown, as the words that name its recovery; the sign is written where it is drawn.
pub fn unconfirmedLine(state: *const State, buffer: *[max_unconfirmed_line_bytes]u8) ?state_marks.Say {
    var configure = false;
    var at = state.request_count;
    while (at > 0) {
        at -= 1;
        const request = &state.requests[at];
        if (request.status != .unknown) continue;
        if (request.kind == .configure) configure = true;
        if (request.kind != .send) continue;
        return .attention(switch (request.sent) {
            .saved => |saved| std.fmt.bufPrint(buffer, "Not confirmed · rui request recover {s}", .{&saved.original.key}),
            else => std.fmt.bufPrint(buffer, "{s}: send not confirmed; details on exit", .{&request.session.?}),
        } catch unreachable);
    }
    // A Send's recovery key is the actionable line; a Configure's Store and intent are printed on departure.
    return if (configure) .attention("Config unconfirmed · exit for Store and intent") else null;
}

pub const StatusBuffer = [@max(upgrade_status.max_line_bytes, max_unconfirmed_line_bytes)]u8;

/// What the status rows above the footer say: the words and tone (the sign is written where drawn), and the colour they take.
/// The Upgrade that holds draws in the attention colour without a sign, so colour and sign are separate facts.
pub const StatusLine = struct {
    say: state_marks.Say,
    colour: Colour,

    /// The line as drawn: the sign for attention, then the words.
    fn drawn(self: StatusLine, buffer: *[max_status_bytes]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ self.say.sign(), self.say.words }) catch unreachable;
    }
};

const max_status_bytes = state_marks.attention_sign.len + @typeInfo(StatusBuffer).array.len;

pub fn statusLine(state: *const State, caps: Caps, buffer: *StatusBuffer) ?StatusLine {
    if (statusSaid(state, caps, buffer[0..upgrade_status.max_line_bytes])) |line| return line;
    const unconfirmed = unconfirmedLine(state, buffer[0..max_unconfirmed_line_bytes]) orelse return null;
    return .{ .say = unconfirmed, .colour = .attention };
}

pub const max_notice_rows = 2;

fn noticeRows(text: []const u8, width: u16, caps: Caps, rows: *[max_notice_rows][]const u8) []const []const u8 {
    const glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs;
    const room = width -| 2;
    const lines = @min(1 + std.mem.count(u8, text, "\n"), rows.len);
    var spare = rows.len - lines;
    var count: usize = 0;
    var texts = std.mem.splitScalar(u8, text, '\n');
    for (0..lines) |_| {
        var rest = texts.next().?;
        while (spare > 0) : (spare -= 1) {
            const cut = wrapAt(caps, glyphs, rest, room) orelse break;
            rows[count] = rest[0..cut];
            count += 1;
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
        rows[count] = rest;
        count += 1;
    }
    return rows[0..count];
}

fn wrapAt(caps: Caps, glyphs: Glyphs, line: []const u8, room: usize) ?usize {
    if (measured(caps, glyphs, line) <= room) return null;
    var cut: ?usize = null;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, at, ' ')) |space| : (at = space + 1) {
        if (measured(caps, glyphs, line[0..space]) > room) break;
        if (space != 0) cut = space;
    }
    return cut;
}

pub fn noticeSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}!?[]const Segment {
    var buffer: StatusBuffer = undefined;
    const line = statusLine(state, caps, &buffer) orelse return null;
    var drawn: [max_status_bytes]u8 = undefined;
    var rows: [max_notice_rows][]const u8 = undefined;
    var built: Spans = .of(arena, caps, width);
    const newline: []const Segment = &.{.{ .text = "\n", .style = .{} }};
    var parts: [2 * max_notice_rows][]const Segment = undefined;
    var count: usize = 0;
    for (noticeRows(line.drawn(&drawn), width, caps, &rows), 0..) |row, at| {
        if (at != 0) {
            parts[count] = newline;
            count += 1;
        }
        built.begin();
        _ = try built.put(1, row, width -| 2, .{ .colour = line.colour });
        parts[count] = try segmentsOf(arena, try built.finish(), width, .{});
        count += 1;
    }
    return try std.mem.concat(arena, Segment, parts[0..count]);
}

fn unknownConfigure(request: *const Request, reference: Reference) bool {
    return request.kind == .configure and request.status == .unknown and request.session != null and
        std.mem.eql(u8, &request.session.?, &reference) and request.text.len == 36;
}

fn originalOf(request: *const Request) @import("configure_outcome.zig").Original {
    return .{ .key = request.text.slice()[0..36].*, .store = request.configure_store };
}

pub fn unknownConfigureKeys(state: *const State, reference: Reference, out_keys: *[max_requests]@import("configure_outcome.zig").Original) usize {
    var count: usize = 0;
    for (state.requests[0..state.request_count]) |*request| {
        if (!unknownConfigure(request, reference)) continue;
        out_keys[count] = originalOf(request);
        count += 1;
    }
    return count;
}

/// The newest unconfirmed Configure of this Session: the one a just-settled attempt appended.
pub fn latestUnknownConfigure(state: *const State, reference: Reference) ?@import("configure_outcome.zig").Original {
    var at = state.request_count;
    while (at > 0) {
        at -= 1;
        if (unknownConfigure(&state.requests[at], reference)) return originalOf(&state.requests[at]);
    }
    return null;
}

pub fn canHoldSend(state: *const State) bool {
    return state.request_count < max_requests;
}

pub const ModelsRead = union(enum) {
    menu: model_picker.Menu,

    unanswered,

    invalid,

    pub fn failed(err: anyerror) ModelsRead {
        return switch (err) {
            error.InvalidModelList, error.InvalidResponse, error.ResponseTooLarge => .invalid,
            else => .unanswered,
        };
    }
};

const ReasoningEffort = model_capability.ReasoningEffort;

pub const Observed = struct { read_version: Token, reference: Reference, work: session_work.Work, opening: bool };

pub const ConversationInput = union(enum) {
    other,
    stop: bool,
    archive: ArchiveState,
    unarchive,
    pin: bool,
    configure: union(enum) {
        reserve: []const u8,
        completed: @import("configure_outcome.zig").Outcome,
        observed: @import("configure_outcome.zig").Original,
    },

    cancel_upgrade,

    upgrade_failed,
};
pub const Conversed = struct { reference: Reference, work: Kind, input: ConversationInput };

pub const Read = struct { reference: Reference, position: u64, admission: u64, content: content_value.Value };

pub const Reads = struct {
    items: [max_first_line_reads]Read = undefined,
    len: usize = 0,

    pub fn slice(self: *const Reads) []const Read {
        return self.items[0..self.len];
    }
};

/// The Archived window read: rows `from` a cursor, answered only in the `epoch` it was issued in.
pub const ArchivedRead = struct { from: session_list.ArchivedCursor, rows: u8, epoch: u32 };

/// The page the Overview asks the Host for: a reader's choice, bounded by what one reply may cost (`session_list.max_window_rows`).
pub const archived_page_rows: u8 = 40;
comptime {
    std.debug.assert(archived_page_rows >= 1 and archived_page_rows <= session_list.max_window_rows);
}

pub const ArchivedAnswer = struct {
    read: ArchivedRead,
    /// Null when the read failed.
    page: ?ArchivedPage,
};

/// The Archived window. The held archived rows are the window (`listed`, `archive_state` archived), so
/// its first and last keys are read from them, never kept beside them. Only the facts that cannot be
/// read from the rows live here.
pub const ArchivedWindow = struct {
    /// Bumped when the Archived tab is left and when the window re-anchors. Answers from older epochs are dropped.
    epoch: u32 = 0,
    /// Nothing newer than the window's first row is missing: the window starts at the head.
    at_head: bool = false,
    /// The Host holds Archived Sessions older than the window's last row.
    more_below: bool = false,
    /// One read is in flight. It is never cleared by leaving the tab: its answer clears it when it lands.
    inflight: bool = false,
    /// The window must be re-read from the head before it is trusted (a full roster walk or an empty page).
    reanchor: bool = false,
    /// The last read failed. The window keeps the rows it holds, and the list interval retries from `retry_ms`.
    failed: bool = false,
    retry_ms: u64 = 0,
    /// A window re-read a routed archive owes the Host. At most one is issued at a time; a second routed archive
    /// while one is owed coalesces into a head re-read.
    refresh: ?session_list.ArchivedCursor = null,

    fn leave(self: *ArchivedWindow) void {
        self.epoch +%= 1;
        self.failed = false;
    }
};

/// One roster walk's request. The core picks the archive filter once per walk: a walk with a since token
/// also asks for the archived Sessions that changed, so the Archived window can take them.
pub const ListRequest = struct { since: ?Token, archive: ArchiveFilter };

pub const Effect = union(enum) {
    list: ListRequest,
    read_first_lines: Reads,
    read_archived: ArchivedRead,

    create: ?Default,
    open: Reference,
    focus_chat,
    new_session,
    open_settings,

    stop: Reference,
    archive: ArchiveRequest,
    pin: PinRequest,

    list_models,

    cancel_upgrade,

    exit,
};

/// A Session's connection, by name. Labels, sign-in commands and usage pages
/// come from the built-in facts its name spells; any other name shows as itself.
pub const Provider = connection.Name;

pub fn pn(provider: provider_name.Provider) Provider {
    return connection.Name.parse(@tagName(provider)).?;
}

fn shownOf(name: Provider) []const u8 {
    return if (provider_route.builtInOf(name)) |built_in| built_in.shown() else name.slice();
}

fn loginOf(name: Provider) ?[]const u8 {
    return if (provider_route.builtInOf(name)) |built_in| built_in.login() else null;
}

fn usageOf(name: Provider) ?[]const u8 {
    return if (provider_route.builtInOf(name)) |built_in| built_in.usage() else null;
}

pub const Default = struct {
    provider: Provider,
    model: Bounded(model_capability.max_model_bytes),

    pub fn of(provider: ?[]const u8, model: ?[]const u8) ?Default {
        var binding: Default = .{ .provider = connection.Name.parse(provider orelse return null) orelse return null, .model = .{} };
        binding.model.set(model orelse return null) catch return null;
        return binding;
    }

    pub fn eql(self: *const Default, other: *const Default) bool {
        return self.provider.eql(other.provider) and self.model.eql(other.model.slice());
    }
};

/// What the command line asks the wide launch to open. Only `defaults` and
/// `named` wait for the listing to choose between reopening and creating.
/// The binding is never carried here: `chooseLaunch` reads `State.default`
/// at poll time, the same value creation uses.
pub const LaunchIntent = enum {
    defaults,
    named,
    explicit_session,
    restoring,
};

pub const Binding = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const Size = struct { width: u16 = 0, height: u16 = 0 };

pub const IntentAdmission = enum { admitted, refused };

pub const Effects = struct {
    browse_open: bool = false,
    redraw: bool = false,
    intent_admission: IntentAdmission = .refused,
    items: [4]Effect = undefined,
    len: usize = 0,

    pub fn slice(self: *const Effects) []const Effect {
        return self.items[0..self.len];
    }

    fn add(self: *Effects, effect: Effect) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = effect;
        self.len += 1;
    }
};

pub const Said = struct {
    notice: ?state_marks.Say = null,
    stoppable: bool,
};

pub fn conversation(state: *const State, ref: Reference, can_stop: bool) Said {
    return .{ .notice = footerNotice(state), .stoppable = can_stop and state.openStop(ref) == null };
}

fn statusSaid(state: *const State, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) ?StatusLine {
    const upgrade: ?upgrade_status.Line = if (state.upgrade.run) |run| upgrade_status.line(run, buffer, if (caps.unicode) .unicode else .ascii) else null;
    if (upgrade) |line| if (line.lasts == .until_done) return .{ .say = .quiet(line.text), .colour = .normal };
    if (upgrade) |line| if (line.lasts == .persistent)
        return .{ .say = .quiet(line.text), .colour = if (line.tone == .attention) .attention else .normal };
    return null;
}

const StopBaseline = struct {
    version: Token,
    work: session_work.Work,
};

pub const Request = struct {
    kind: enum { create, stop, archive, unarchive, pin, unpin, send, configure },

    session: ?Reference = null,
    status: enum { pending, done, failed, unknown } = .pending,
    stop_baseline: ?StopBaseline = null,
    stop_overlay: bool = true,

    text: Bounded(@max(max_handle_bytes, session_work.max_code_bytes)) = .{},

    sent: submission.Recovery = .none,
    configure_intent: Bounded(max_configure_intent_bytes) = .{},
    configure_store: Bounded(@import("store_path.zig").max_bytes) = .{},
};

pub const Notice = struct {
    bytes: [768]u8 = undefined,
    len: usize = 0,
    colour: Colour,

    /// The words alone; `said` is what the footer draws.
    pub fn text(self: *const Notice) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn said(self: *const Notice) state_marks.Say {
        return .{ .words = self.text(), .tone = if (self.colour == .attention) .attention else .quiet };
    }
};

const FirstLineRead = union(enum) { unread, requested, unavailable, read: u32 };

/// Archived rows sort after every live row, in the Host's order: their sort key sets this bit.
const archived_sort_bit: u128 = 1 << 127;

pub const Row = struct {
    membership_superseded: bool = false,
    reference: Reference,
    creator: ?Reference = null,
    listed: bool = true,
    read_version: ?Token = null,
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,
    archive_seq: ?u64 = null,
    archived_since: ?u64 = null,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    created_at: u64 = 0,
    state_change_at: u64 = 0,
    subtree_state_change_at: u64 = 0,
    descendant_count: u64 = 0,
    descendant_needs_you_count: u64 = 0,
    /// Whether the list answer that carried `descendant_needs_you_count` found this Session needing a decision; the count and this fact share one snapshot.
    list_needs_you: bool = false,
    clock_version: ?Token = null,
    sibling_rank: u64 = std.math.maxInt(u64),
    born_held: bool = false,
    flash_until_ms: u64 = 0,

    workspace: u32,
    provider: ?Provider = null,
    model: Bounded(model_capability.max_model_bytes) = .{},
    label: ?Bounded(max_label_bytes),
    state: WorkState,

    turn: ?u64,

    first_action: ?u64,
    actions: session_work.Actions = .{},
    first: ?First,
    from_person_at: ?u64,
    line: FirstLineRead = .unread,

    fn adoptArchived(self: *Row, incoming: *const Row) void {
        const was = self.*;
        self.* = incoming.*;
        if (was.read_version != null) {
            self.read_version = was.read_version;
            self.state = was.state;
            self.turn = was.turn;
            self.operation = was.operation;
            self.first_action = was.first_action;
            self.actions = was.actions;
            self.clock_version = was.clock_version;
            self.state_change_at = was.state_change_at;
            self.subtree_state_change_at = was.subtree_state_change_at;
            self.descendant_count = was.descendant_count;
            self.descendant_needs_you_count = was.descendant_needs_you_count;
            self.list_needs_you = was.list_needs_you;
        }
    }

    fn setArchivedSince(self: *Row, since: u64) void {
        self.archived_since = if (self.archive_state == .archived) since else null;
    }

    fn adoptMembership(self: *Row, incoming: *const Row) void {
        self.archive_state = incoming.archive_state;
        self.archive_seq = incoming.archive_seq;
        self.archived_since = incoming.archived_since;
    }

    fn sinceAsOf(self: *const Row, now_ms: u64) u64 {
        if (self.archive_state == .archived) if (self.archived_since) |since| return since;
        return self.state.asOf(now_ms).since();
    }

    fn supersedeMembership(self: *Row, reference: Reference, version: Token) void {
        const read = self.read_version orelse return;
        if (std.mem.eql(u8, &self.reference, &reference) and std.mem.eql(u8, &read.instance, &version.instance) and read.generation < version.generation) self.membership_superseded = true;
    }

    fn hasMembership(self: *const Row) bool {
        return !self.membership_superseded;
    }

    fn work(self: *const Row) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .operation = self.operation, .first_action = self.first_action, .actions = self.actions };
    }
};

pub const State = struct {
    gpa: Allocator,
    home: []const u8,

    cwd: u32,
    now_ms: u64 = 0,

    login_at: ?u64 = null,

    archive: ArchiveFilter = .active,

    /// Set while a roster walk is wanted; cleared when a host failure or a rejected page discards it.
    listing_wanted: bool = false,
    rows: Vec(Row) = .{},
    archived: ArchivedWindow = .{},
    /// The first and last Session rows the list showed at its last wheel scroll, by reference. A selection move
    /// clears it (step), so it holds the most recent input only: the wheel while it is set, else the selection.
    viewport: ?ViewRows = null,

    by_reference: Vec(Keyed) = .{},

    order: Vec(u32) = .{},

    summary: Summary = .{},

    workspaces: Vec([]const u8) = .{},
    workspace_order: Vec(Keyed) = .{},

    lines: Vec(Bounded(max_line_bytes)) = .{},

    selected: Selection = .new_session,
    /// The exact Session queued for wide browse; null means no pending preview.
    browse_target: ?Reference = null,

    conversing: ?Reference = null,
    read_instance: ?[16]u8 = null,
    notice: ?Notice = null,

    requests: [max_requests]Request = undefined,
    request_count: usize = 0,

    left: bool = false,

    host: ?Host = null,

    memory: ?Memory = null,

    upgrade: session_upgrade.Upgrade = .{},

    default: ?Default = null,

    size: Size = .{},
    sidebar_rule: ?u16 = null,
    launch: enum { sizing, waiting, creating, done } = .done,
    launch_intent: LaunchIntent = .defaults,
    presentation: union(enum) { done, holding: u64, released } = .done,
    presentation_fell_back: bool = false,

    host_line: bool = false,

    menu: model_picker.Menu = .{},

    menu_revision: u64 = 0,

    menu_read: model_picker_view.Read = .unread,

    asking_models: bool = false,

    token: ?Token = null,
    /// The walk in flight began with a since token. Set when the walk starts, so a restart can start a full one.
    walk_since: bool = false,
    /// How many since walks the Host answered in full and the core restarted from no token.
    full_restarts: u32 = 0,

    seen: Vec(Seen) = .{},

    unsettled: usize = 0,

    status_changes: u64 = 0,

    presentation_revision: u64 = 0,
    tree_presentation: ?u64 = null,

    arrivals: Vec(Seen) = .{},

    listing: bool = false,

    pending: Vec(Row) = .{},
    next_list_ms: u64 = 0,
    listed_at_ms: ?u64 = null,

    list_stale: bool = false,

    sort_keys: Vec(SortKey) = .{},
    nodes: Vec(Node) = .{},
    scratch: Vec(u32) = .{},
    folded: Vec(Reference) = .{},
    parent_click: ?ParentClick = null,
    pin_end: usize = 0,
    ordered_refs: Vec(Reference) = .{},
    full_order: Vec(u32) = .{},
    last_question: ?Reference = null,
    next_rank: u64 = 0,
    pointer_over: bool = false,
    key_until_ms: u64 = 0,
    carry: Carry = .{},
    releasing: bool = false,

    pub const Options = struct {
        cwd: []const u8,
        home: []const u8,
        login_at: ?u64 = null,
        default: ?Default = null,
    };

    pub fn init(self: *State, gpa: Allocator, options: Options) error{OutOfMemory}!void {
        self.* = .{ .gpa = gpa, .home = options.home, .cwd = 0, .login_at = options.login_at, .default = options.default };
        errdefer self.deinit();
        self.cwd = try self.intern(options.cwd);
    }

    pub fn modelsReady(self: *const State) bool {
        if (self.asking_models) return false;
        return switch (self.menu_read) {
            .unread => false,
            .read => !self.menu.loading(),
            .unanswered, .invalid => true,
        };
    }

    pub fn savedProvider(self: *const State, explicit: ?[]const u8, saved: ?[]const u8) ?[]const u8 {
        return explicit orelse saved orelse if (self.default) |*binding| binding.provider.slice() else null;
    }

    pub fn nextBinding(self: *const State) Binding {
        return .{ .provider = if (self.default) |*binding| binding.provider.slice() else null, .model = if (self.default) |*binding| binding.model.slice() else null };
    }
    pub fn nextStart(self: *const State) ?Default {
        return self.default;
    }
    fn releaseModels(self: *State) void {
        self.menu_revision += 1;
        self.menu.deinit(self.gpa);
        self.menu_read = .unread;
    }

    fn parentPress(self: *State, candidate: ?Reference, at_ms: ?u64) enum { open, wait, toggle } {
        const pending = self.parent_click;
        self.cancelParentClick();
        const reference = candidate orelse return .open;
        const now = at_ms orelse return .open;
        if (pending) |prior| {
            if (prior.released and now < prior.deadline_ms and std.mem.eql(u8, &prior.reference, &reference)) return .toggle;
        }
        self.parent_click = .{ .reference = reference, .deadline_ms = now +| ParentClick.interval_ms };
        return .wait;
    }

    fn parentPressHeld(self: *const State) bool {
        const pending = self.parent_click orelse return false;
        return !pending.released;
    }

    fn cancelParentClick(self: *State) void {
        self.parent_click = null;
    }

    fn releaseParentClick(self: *State, over: ?Reference) void {
        if (self.parent_click) |*pending| {
            if (over != null and std.mem.eql(u8, &over.?, &pending.reference)) {
                pending.released = true;
            } else self.cancelParentClick();
        }
    }

    fn readyParentClick(self: *State, focused: bool, at_ms: ?u64) ?Reference {
        if (!focused) {
            self.cancelParentClick();
            return null;
        }
        const pending = self.parent_click orelse return null;
        const now = at_ms orelse return null;
        if (!pending.released or now < pending.deadline_ms) return null;
        self.cancelParentClick();
        return pending.reference;
    }

    pub fn deinit(self: *State) void {
        self.menu.deinit(self.gpa);
        for (self.workspaces.items) |bytes| self.gpa.free(bytes);
        inline for (.{ &self.rows, &self.by_reference, &self.order, &self.workspaces, &self.workspace_order, &self.lines, &self.pending, &self.sort_keys, &self.nodes, &self.scratch, &self.folded, &self.ordered_refs, &self.full_order, &self.seen, &self.arrivals }) |vec| vec.deinit(self.gpa);
    }

    pub fn find(self: *const State, ref: Reference) ?*const Row {
        const at = lookup(self.by_reference.items, ref) orelse return null;
        return &self.rows.items[at];
    }

    pub fn workOf(_: *const State, row: *const Row) session_work.Work {
        return row.work();
    }

    pub fn lineOf(self: *const State, row: *const Row) ?[]const u8 {
        return if (row.line == .read) self.lines.items[row.line.read].slice() else null;
    }

    pub fn wakeAt(self: *const State) ?u64 {
        var at: ?u64 = if (self.listing) null else self.next_list_ms;
        if (self.key_until_ms > self.now_ms) at = @min(at orelse self.key_until_ms, self.key_until_ms);
        for (self.rows.items) |*row| {
            if (!row.listed) continue;
            if (row.flash_until_ms > self.now_ms) at = @min(at orelse row.flash_until_ms, row.flash_until_ms);
            if (row.archive_state == .archived) continue;
            const work = (&row.state);
            if (work.* == .retrying) at = @min(at orelse work.retrying.due_at_ms, work.retrying.due_at_ms);
        }
        if (band(self)) |trouble| if (trouble.resets_at) |resets| {
            at = @min(at orelse resets *| 1000, resets *| 1000);
        };
        return at;
    }

    pub fn upgrading(self: *const State) bool {
        return self.upgrade.going();
    }

    pub fn holdsHost(self: *const State) bool {
        return self.upgrade.held();
    }

    fn queueBrowseTarget(self: *State, wide: bool, moved: bool) void {
        const pending = self.browse_target != null;
        self.browse_target = if (wide and (pending or moved) and self.selected == .session) self.selected.session else null;
    }

    fn cancelBrowseTarget(self: *State) void {
        self.browse_target = null;
    }

    fn cancelBrowseTargetIf(self: *State, reference: Reference) void {
        if (self.browse_target) |target| {
            if (std.mem.eql(u8, &reference, &target)) self.browse_target = null;
        }
    }

    fn takeReadyBrowse(self: *State, wide: bool, focused: bool) ?Reference {
        const target = self.browse_target;
        self.browse_target = null;
        if (target) |reference| if (wide and focused and self.selected == .session and self.selectedRow() != null and std.mem.eql(u8, &self.selected.session, &reference)) return reference;
        return null;
    }

    fn selectedRow(self: *const State) ?*const Row {
        if (self.selected != .session) return null;
        const index = lookup(self.by_reference.items, self.selected.session) orelse return null;
        return if (index < self.nodes.items.len and self.nodes.items[index].included) &self.rows.items[index] else null;
    }

    pub fn initialPresentation(self: *const State, list_visible: bool) enum { holding, released, done } {
        return switch (self.presentation) {
            .done => .done,
            .released => .released,
            .holding => if (list_visible) .holding else .done,
        };
    }

    pub fn hidesOverview(self: *const State) bool {
        return !self.presentation_fell_back and (self.launch == .waiting or self.launch == .creating);
    }

    pub fn creating(self: *const State) bool {
        return blk: {
            for (self.requests[0..self.request_count]) |held| {
                if (held.kind == .create and (held.status == .pending or held.status == .unknown)) break :blk true;
            }
            break :blk false;
        };
    }

    fn openStop(self: *const State, ref: Reference) ?*const Request {
        for (self.requests[0..self.request_count]) |*held| {
            if (held.kind == .stop and std.mem.eql(u8, &held.session.?, &ref) and (held.status == .pending or held.status == .unknown)) return held;
        }
        return null;
    }

    fn stopOverlays(self: *const State, ref: Reference) bool {
        const held = self.openStop(ref) orelse return false;
        return held.stop_overlay;
    }

    fn pendingAt(self: *const State, kind: @FieldType(Request, "kind"), ref: ?Reference) ?usize {
        for (self.requests[0..self.request_count], 0..) |*held, at| {
            if (held.kind != kind or held.status != .pending) continue;
            if (ref == null or std.mem.eql(u8, &held.session.?, &ref.?)) return at;
        }
        return null;
    }

    fn request(self: *State, kind: @FieldType(Request, "kind"), ref: ?Reference) bool {
        if (self.request_count == max_requests) {
            self.say(.attention, "Busy; try again shortly.", .{});
            return false;
        }
        self.requests[self.request_count] = .{ .kind = kind, .session = ref };
        self.request_count += 1;
        return true;
    }

    fn answer(self: *State, at: usize, status: @FieldType(Request, "status"), text: []const u8) void {
        if (status != .unknown and !self.left) {
            std.mem.copyForwards(Request, self.requests[at .. self.request_count - 1], self.requests[at + 1 .. self.request_count]);
            self.request_count -= 1;
            return;
        }
        const held = &self.requests[at];
        held.status = status;
        const end = utf8_validation.scalarStart(text, @min(text.len, held.text.bytes.len));
        held.text.set(text[0..end]) catch unreachable;
    }

    fn observe(self: *State, read: Observed) error{OutOfMemory}!void {
        if (!self.accepts(read.read_version)) return;
        if (self.conversing) |open| if (std.mem.eql(u8, &open, &read.reference)) {
            var at = lookup(self.by_reference.items, read.reference);
            if (at == null) {
                at = @intCast(self.rows.items.len);
                try self.rows.append(self.gpa, .{
                    .reference = read.reference,
                    .listed = false,
                    .workspace = self.cwd,
                    .label = null,
                    .state = .{ .idle = .{ .since = 0 } },
                    .turn = null,
                    .first_action = null,
                    .first = null,
                    .from_person_at = null,
                });
                try reindex(self);
            }
            const row = &self.rows.items[at.?];
            const before = RowPresentation.of(self, row);
            settleRow(self, row, .{ .read_version = read.read_version, .work = read.work });
            const after = RowPresentation.of(self, row);
            if (position(self, row.reference) != null and !before.eql(&after)) self.presentation_revision +%= 1;
            try arrange(self);
        };
        if (!read.opening or session_work.attention(read.work) == null) return;
        _ = attention.observe(&(try self.record(read.reference)).acknowledged, read.work);
    }

    fn accepts(self: *const State, version: Token) bool {
        const instance = self.read_instance orelse return false;
        return std.mem.eql(u8, &instance, &version.instance);
    }

    fn readListed(self: *State, ref: Reference, work: session_work.Work, opening: bool) error{OutOfMemory}!void {
        if (self.entryOf(ref)) |entry| {
            const now: attention.Reading = .of(work, entry.acknowledged);
            const status = attention.Status.next(entry.status, entry.listed, now, opening);
            const later = status == entry.status and if (entry.listed) |was| now.after(was) else false;
            self.want(entry, status, later);
            entry.listed = now;
            return;
        }
        const now: attention.Reading = .of(work, null);
        try self.arrivals.append(self.gpa, .{ .key = referenceKey(ref), .listed = now, .status = attention.Status.next(null, null, now, opening) });
    }

    fn settleArrivals(self: *State) error{OutOfMemory}!void {
        const arrivals = self.arrivals.items;
        if (arrivals.len == 0) return;
        defer self.arrivals.items.len = 0;
        std.mem.sortUnstable(Seen, arrivals, {}, struct {
            fn less(_: void, a: Seen, b: Seen) bool {
                return a.key < b.key;
            }
        }.less);
        const old = self.seen.items.len;
        try self.seen.ensure(self.gpa, old + arrivals.len);
        for (arrivals) |arrival| self.unsettled += @intFromBool(!arrival.settled());
        self.status_changes +%= 1;
        self.seen.items.len = old + arrivals.len;
        const seen = self.seen.items;
        var from = old;
        var next = arrivals.len;
        var to = seen.len;
        while (next != 0) {
            to -= 1;
            if (from != 0 and seen[from - 1].key > arrivals[next - 1].key) {
                from -= 1;
                seen[to] = seen[from];
            } else {
                next -= 1;
                seen[to] = arrivals[next];
            }
        }
    }

    fn record(self: *State, ref: Reference) error{OutOfMemory}!*Seen {
        if (self.entryOf(ref)) |entry| return entry;
        const key = referenceKey(ref);
        const at = self.seenAt(key);
        try self.seen.ensure(self.gpa, self.seen.items.len + 1);
        self.seen.insertAssumeCapacity(at, .{ .key = key });
        return &self.seen.items[at];
    }

    fn entryOf(self: *State, ref: Reference) ?*Seen {
        const key = referenceKey(ref);
        const at = self.seenAt(key);
        return if (at < self.seen.items.len and self.seen.items[at].key == key) &self.seen.items[at] else null;
    }

    fn seenAt(self: *const State, key: u64) usize {
        const seen = self.seen.items;
        var low: usize = 0;
        var high = seen.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (seen[middle].key < key) low = middle + 1 else high = middle;
        }
        return low;
    }

    fn want(self: *State, entry: *Seen, status: ?attention.Status, again: bool) void {
        if (entry.status == status and !again) return;
        const was = entry.settled();
        entry.status = status;
        entry.version +%= 1;
        self.status_changes +%= 1;
        const now = status == null and entry.delivered == .none;
        if (was and !now) self.unsettled += 1;
        if (!was and now) self.unsettled -= 1;
    }

    pub fn statusesSettled(self: *const State) bool {
        return self.unsettled == 0;
    }

    pub fn unsettledStatuses(self: *const State) Unsettled {
        return .{ .state = self, .left = self.unsettled };
    }

    pub const Unsettled = struct {
        state: *const State,
        at: usize = 0,
        left: usize,

        pub fn next(self: *Unsettled) ?StatusRecord {
            if (self.left == 0) return null;
            const seen = self.state.seen.items;
            while (self.at < seen.len) {
                const entry = &seen[self.at];
                self.at += 1;
                if (entry.settled()) continue;
                self.left -= 1;
                var reference: Reference = undefined;
                std.mem.writeInt(u48, &reference, @intCast(entry.key), .big);
                const row = self.state.find(reference);
                return .{ .reference = reference, .name = if (row) |found| title(self.state, found).text else "", .status = entry.status, .version = entry.version };
            }
            unreachable;
        }
    };

    pub fn statusTaken(self: *State, taken: StatusRecord.Taken) void {
        const entry = self.entryOf(taken.reference) orelse return;
        const was = entry.settled();
        entry.delivered = taken.delivered;
        const now = entry.settled();
        if (was and !now) self.unsettled += 1;
        if (!was and now) self.unsettled -= 1;
    }

    pub fn statusesClearing(self: *State) void {
        self.recount(.unknown);
    }

    pub fn statusesCleared(self: *State) void {
        self.recount(.none);
    }

    fn recount(self: *State, cleared: Delivered) void {
        self.unsettled = 0;
        for (self.seen.items) |*entry| {
            if (entry.delivered != .none) entry.delivered = cleared;
            self.unsettled += @intFromBool(!entry.settled());
        }
    }

    fn intern(self: *State, bytes: []const u8) error{OutOfMemory}!u32 {
        const key = workspaceKey(bytes);
        const order = self.workspace_order.items;
        var low: usize = 0;
        var high = order.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (order[middle].key < key) low = middle + 1 else high = middle;
        }
        while (low < order.len and order[low].key == key) : (low += 1) {
            if (std.mem.eql(u8, self.workspaces.items[order[low].index], bytes)) return order[low].index;
        }
        try self.workspaces.ensure(self.gpa, self.workspaces.items.len + 1);
        try self.workspace_order.ensure(self.gpa, self.workspace_order.items.len + 1);
        const added: u32 = @intCast(self.workspaces.items.len);
        self.workspaces.appendAssumeCapacity(try self.gpa.dupe(u8, bytes));
        self.workspace_order.insertAssumeCapacity(low, .{ .key = key, .index = added });
        return added;
    }

    fn say(self: *State, colour: Colour, comptime format: []const u8, args: anytype) void {
        var notice: Notice = .{ .colour = colour };
        var writer = std.Io.Writer.fixed(&notice.bytes);
        writer.print(format, args) catch {};
        notice.len = writer.buffered().len;
        self.notice = notice;
    }
};

pub const Counts = session_class.Counts;

pub const Summary = struct { counts: Counts = .{} };

const Keyed = struct { key: u64, index: u32 };

const Seen = struct {
    key: u64,
    acknowledged: ?attention.Attention = null,
    listed: ?attention.Reading = null,
    status: ?attention.Status = null,

    version: u16 = 0,

    delivered: Delivered = .none,

    fn settled(self: *const Seen) bool {
        return switch (self.delivered) {
            .none => self.status == null,
            .unknown => false,
            .version => |version| self.status != null and version == self.version,
        };
    }
};

const Delivered = union(enum) { none, unknown, version: u16 };

pub const StatusRecord = struct {
    reference: Reference,
    name: []const u8,
    status: ?attention.Status,
    version: u16 = 0,

    pub const Taken = struct { reference: Reference, delivered: Delivered };

    pub fn taken(self: StatusRecord) Taken {
        return .{ .reference = self.reference, .delivered = if (self.status != null) .{ .version = self.version } else .none };
    }
};
const Node = struct {
    included: bool = false,
    logical_parent: ?u32 = null,
    parent: ?u32 = null,
    first_child: ?u32 = null,
    next_sibling: ?u32 = null,
    remaining: u32 = 0,
    descendants: u64 = 0,
    attention: u64 = 0,
    depth: u32 = 0,
    last_sibling: bool = true,
    hidden: bool = false,
    old_position: ?usize = null,
    line: ?usize = null,
    representative: ?u32 = null,
};

const SortKey = struct { pin_order: ?u64, key: u128, index: u32 };

fn Vec(comptime T: type) type {
    return struct {
        items: []T = &.{},
        capacity: usize = 0,
        const Self = @This();

        fn ensure(self: *Self, gpa: Allocator, total: usize) error{OutOfMemory}!void {
            if (total <= self.capacity) return;
            const capacity = @max(total, 2 * self.capacity, 8);
            const memory = try gpa.realloc(self.items.ptr[0..self.capacity], capacity);
            self.items = memory[0..self.items.len];
            self.capacity = capacity;
        }

        fn appendAssumeCapacity(self: *Self, value: T) void {
            std.debug.assert(self.items.len < self.capacity);
            self.items.len += 1;
            self.items[self.items.len - 1] = value;
        }

        fn append(self: *Self, gpa: Allocator, value: T) error{OutOfMemory}!void {
            try self.ensure(gpa, self.items.len + 1);
            self.appendAssumeCapacity(value);
        }

        fn insertAssumeCapacity(self: *Self, at: usize, value: T) void {
            std.debug.assert(self.items.len < self.capacity);
            self.items.len += 1;
            std.mem.copyBackwards(T, self.items[at + 1 ..], self.items[at .. self.items.len - 1]);
            self.items[at] = value;
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.items.ptr[0..self.capacity]);
            self.* = .{};
        }
    };
}

fn workspaceKey(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash;
}

fn referenceKey(ref: Reference) u64 {
    return std.mem.readInt(u48, &ref, .big);
}

fn lookup(keyed: []const Keyed, ref: Reference) ?u32 {
    const key = referenceKey(ref);
    var low: usize = 0;
    var high = keyed.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (keyed[middle].key == key) return keyed[middle].index;
        if (keyed[middle].key < key) low = middle + 1 else high = middle;
    }
    return null;
}

const RowPresentation = struct {
    name: Bounded(@max(max_label_bytes, max_line_bytes)),
    kind: Kind,
    since: u64,
    archive: ArchiveState,
    pin: ?@import("session_pin.zig").PinOrder,
    yours: bool,
    quiet: bool,

    fn of(state: *const State, row: *const Row) RowPresentation {
        const class = classOf(state, row);
        return .{
            .name = Bounded(@max(max_label_bytes, max_line_bytes)).from(title(state, row).text) catch unreachable,
            .kind = class.kind,
            .since = shownSince(state, row),
            .archive = row.archive_state,
            .pin = row.pin_order,
            .yours = class.yours,
            .quiet = class.quiet,
        };
    }

    fn eql(a: *const RowPresentation, b: *const RowPresentation) bool {
        inline for (.{ "kind", "since", "archive", "pin", "yours", "quiet" }) |field| {
            if (!std.meta.eql(@field(a, field), @field(b, field))) return false;
        }
        return a.name.eql(b.name.slice());
    }
};

pub fn step(state: *State, event: Event) error{OutOfMemory}!Effects {
    const selected_before = state.selected;
    const effects = try stepEvent(state, event);
    // A selection move or click is the most recent input: it releases the rows a wheel scroll held (archivedFocus).
    const moved = !std.meta.eql(selected_before, state.selected);
    if (event == .clicked or (event != .viewport and moved)) state.viewport = null;
    return effects;
}

fn stepEvent(state: *State, event: Event) error{OutOfMemory}!Effects {
    switch (event) {
        .tick, .list, .host, .memory, .observed, .first_line, .resized, .launch_size, .launch_poll, .presentation_start, .presentation_presented, .presentation_tick, .list_settled, .list_presence => {},
        else => state.presentation_revision +%= 1,
    }
    switch (event) {
        .input, .clicked, .open, .leave => if (state.presentation_fell_back and state.launch == .waiting) {
            state.launch = .done;
        },
        else => {},
    }

    var effects: Effects = .{};
    switch (event) {
        .input => |input| {
            // Ignored keys must not discard the held parent press before its matching release arrives.
            if (!state.parentPressHeld() or (!input.pasted and input.key != .ignored)) endCarry(state);
            if (input.list_origin and !input.pasted and !input.under and input.key != .ignored) {
                const was_held = holding(state);
                state.now_ms = @max(state.now_ms, input.at_ms orelse state.now_ms);
                if (was_held and !holding(state)) try releaseOrder(state);
                state.key_until_ms = state.now_ms +| 3000;
            }
            if (input.key != .ignored) state.launch = .done;
            try listInput(state, input, &effects);
        },
        .viewport => |span| {
            state.cancelParentClick();
            state.viewport = viewportRows(state, span);
            try archivedReads(state, &effects);
        },
        .list_presence => |presence| {
            const was_held = holding(state);
            state.now_ms = @max(state.now_ms, presence.at_ms);
            state.pointer_over = presence.pointer_over;
            if (was_held and !holding(state)) try releaseOrder(state);
        },
        .list_settled => |frame| {
            if (state.readyParentClick(frame.focused, frame.click_clock_ms)) |reference| {
                state.presentation_revision +%= 1;
                try clickOpen(state, reference, &effects);
            }
            if (state.takeReadyBrowse(frame.wide, frame.focused) != null) {
                state.presentation_revision +%= 1;
                try activateList(state, .browse, &effects);
            }
        },
        .tick => |now_ms| try tick(state, now_ms, &effects),
        .list => |reply| {
            switch (reply) {
                .page => |page| try listPage(state, page, &effects),
                .failed => {
                    std.debug.assert(state.listing);
                    state.listing = false;
                    state.pending.items.len = 0;
                    if (!state.list_stale) state.presentation_revision +%= 1;
                    state.list_stale = true;
                },
            }
            if (state.listed_at_ms == null and state.list_stale and (state.launch == .sizing or state.launch == .waiting)) state.launch = .done;
            if (state.listed_at_ms != null or state.list_stale) releaseInitialPresentation(state, &effects);
        },
        .first_line => |result| try firstLine(state, result),
        .archived => |answer| try archivedAnswer(state, answer, &effects),
        .pointer => |pointer| try carryPointer(state, pointer, &effects),
        .clicked => |input| {
            state.cancelBrowseTarget();
            state.launch = .done;
            endCarry(state);
            const candidate = if (!state.creating() and input.target == .open) input.target.open else null;
            const parent = if (candidate) |reference|
                if (position(state, reference) != null and foldable(state, reference)) reference else null
            else
                null;
            const gesture = state.parentPress(parent, input.at_ms);
            if (!state.creating()) switch (input.target) {
                .open => |reference| {
                    // Only an admitted press can carry its row: while a chat is being created, clicks are refused.
                    state.carry.pressed = reference;
                    switch (gesture) {
                        .open => try clickOpen(state, reference, &effects),
                        .wait, .toggle => {
                            state.selected = .{ .session = reference };
                            if (gesture == .toggle) {
                                endCarry(state);
                                try foldSelected(state, !isFolded(state, reference));
                            }
                        },
                    }
                },
                .pin => |request| pinIntent(state, request, &effects),
                .new_session => {
                    state.selected = .new_session;
                    try enterSelected(state, &effects);
                },
                .sessions => try selectView(state, .active, &effects),
                .archived => try selectView(state, .archived, &effects),
                .update => |target| if (input.upgrade_admitted and std.meta.eql(target, upgrade_status.Target{ .available = state.upgrade.available, .run = state.upgrade.run }) and !state.upgrading()) startUpgrade(state),
                .settings => effects.add(.open_settings),
            };
        },
        .unconfirmed => |left| {
            std.debug.assert(canHoldSend(state));
            state.requests[state.request_count] = .{ .kind = .send, .session = left.reference, .status = .unknown, .sent = left.recovery };
            state.request_count += 1;
            state.notice = null;
        },
        .conversed => |input| {
            switch (input.input) {
                .other => state.notice = null,
                .stop => |can_stop| stopKey(state, .{ .reference = input.reference, .work = input.work, .can_stop = can_stop }, &effects),
                .archive => |archive| archiveIntent(state, .{ .ask = .{ .reference = input.reference, .work = input.work, .archive = archive } }, &effects),
                .unarchive => archiveIntent(state, .{ .restore = input.reference }, &effects),
                .pin => |pinned| pinIntent(state, .{ .reference = input.reference, .pinned = pinned }, &effects),
                .configure => |configure_event| switch (configure_event) {
                    .reserve => |intent| {
                        if (intent.len <= max_configure_intent_bytes and std.unicode.utf8ValidateSlice(intent) and state.pendingAt(.configure, input.reference) == null and state.request(.configure, input.reference)) {
                            state.requests[state.request_count - 1].configure_intent.set(intent) catch unreachable;
                            effects.intent_admission = .admitted;
                        }
                    },
                    .completed => |outcome| {
                        if (state.pendingAt(.configure, input.reference)) |at| switch (outcome) {
                            .accepted, .rejected, .not_sent => state.answer(at, .done, ""),
                            .unconfirmed => |original| {
                                state.requests[at].configure_store = original.store;
                                state.answer(at, .unknown, &original.key);
                            },
                        };
                    },
                    .observed => |original| {
                        for (state.requests[0..state.request_count], 0..) |*request, at| {
                            if (request.kind != .configure or request.status != .unknown or request.session == null or
                                !std.mem.eql(u8, &request.session.?, &input.reference) or !request.text.eql(&original.key) or
                                !request.configure_store.eql(original.store.slice())) continue;
                            state.answer(at, .done, "");
                            break;
                        }
                    },
                },
                .cancel_upgrade => if (state.upgrade.takesEscape()) effects.add(.cancel_upgrade),
                .upgrade_failed => {
                    state.upgrade.block();
                    if (state.upgrade.takesEscape()) effects.add(.cancel_upgrade);
                },
            }
        },
        .pin => |result| {
            const kind: @FieldType(Request, "kind") = if (result.request.pinned) .pin else .unpin;
            const at = state.pendingAt(kind, result.request.reference).?;
            const ref = result.request.reference;
            switch (result.outcome) {
                .accepted => state.answer(at, .done, ""),
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "{s} not {s}: {s}", .{ &ref, if (result.request.pinned) "pinned" else "unpinned", code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "{s} pin unsure; recover {s}.", .{ &ref, handle });
                },
            }
            state.next_list_ms = 0;
        },
        .archive => |result| {
            const kind: @FieldType(Request, "kind") = if (result.request.archived) .archive else .unarchive;
            const at = state.pendingAt(kind, result.request.reference).?;
            const ref = result.request.reference;
            switch (result.outcome) {
                .requested => state.answer(at, .done, ""),
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "{s} not {s}: {s}", .{ &ref, if (result.request.archived) "archived" else "restored", code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "{s} {s} unsure; recover {s}.", .{ &ref, if (result.request.archived) "archive" else "restore", handle });
                },
            }
            state.next_list_ms = 0;
        },
        .stop => |result| {
            const at = state.pendingAt(.stop, result.reference).?;
            switch (result.outcome) {
                .stopped => state.answer(at, .done, ""),
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "{s} not stopped: {s}", .{ &result.reference, code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "{s} stop unsure; details on exit", .{&result.reference});
                },
            }
            state.next_list_ms = 0;
        },
        .created => |result| {
            if (state.launch == .creating) state.launch = .done;
            const at = state.pendingAt(.create, null).?;
            switch (result) {
                .created => |created| {
                    state.requests[at].session = created.reference;
                    state.answer(at, .done, created.handle);
                    if (state.left) return effects;
                    state.selected = .{ .session = created.reference };
                    state.next_list_ms = 0;
                    effects.add(.{ .open = created.reference });
                },
                .failed => |code| {
                    state.answer(at, .failed, code);
                    const next = state.nextBinding().provider;
                    const missing = if (std.mem.eql(u8, code, "model_capability_unavailable")) connection.Name.parse(next orelse "") else null;
                    if (missing) |provider| {
                        if (loginOf(provider)) |command|
                            state.say(.attention, "{s} sign-in missing · {s}", .{ shownOf(provider), command })
                        else
                            state.say(.attention, "{s} sign-in missing · this terminal cannot sign in to it yet", .{shownOf(provider)});
                    } else state.say(.attention, "Not created: {s}", .{code});
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.next_list_ms = 0;
                    state.say(.attention, "Creation unsure; details on exit", .{});
                },
            }
        },
        .leave => {
            state.left = true;
            state.releaseModels();
        },
        .resized => |size| state.size = size,
        .presentation_start => |now_ms| state.presentation = .{ .holding = now_ms +| 150 },
        .presentation_presented => if (state.presentation == .released) {
            state.presentation = .done;
        },
        .presentation_tick => |frame| if (state.presentation == .holding) {
            const deadline = state.presentation.holding;
            if (frame.now_ms >= deadline or frame.host_unavailable or frame.list_visible == false) {
                state.presentation_fell_back = true;
                releaseInitialPresentation(state, &effects);
            }
        },
        .launch_start => |intent| switch (intent) {
            .defaults, .named => if (!state.left and state.conversing == null) {
                state.launch = .sizing;
                state.launch_intent = intent;
            },
            .explicit_session, .restoring => {},
        },
        .launch_size => |frame| {
            state.size = frame.size;
            if (state.launch == .sizing and frame.size.width != 0) state.launch = if (frame.wide) .waiting else .done;
        },
        .launch_poll => {
            if (state.launch == .waiting and state.listed_at_ms != null and !state.list_stale) {
                switch (chooseLaunch(state.launch_intent, state.default, state.rows.items)) {
                    .wait => {},
                    .reopen => |reference| {
                        state.launch = .done;
                        state.selected = .{ .session = reference };
                        effects.add(.{ .open = reference });
                        effects.redraw = true;
                    },
                    .create => {
                        state.selected = .new_session;
                        try enterSelected(state, &effects);
                        state.launch = if (state.pendingAt(.create, null) != null) .creating else .done;
                        effects.redraw = true;
                    },
                }
            }
        },
        .observed => |read| {
            const trouble = band(state);
            try state.observe(read);
            if (!std.meta.eql(trouble, band(state))) state.presentation_revision +%= 1;
        },
        .conversation => |ref| {
            const selected_at = if (state.selected == .session) position(state, state.selected.session) else null;
            state.conversing = ref;
            try retainRows(state);
            try arrange(state);
            reconcileSelection(state, selected_at, false);
        },
        .open => |ref| {
            state.selected = .{ .session = ref };
            effects.add(.{ .open = ref });
        },
        .host => |facts| {
            if (!std.meta.eql(state.host, facts)) state.presentation_revision +%= 1;
            if (facts == null) {
                state.launch = .done;
                releaseInitialPresentation(state, &effects);
            }
            state.host = facts;
            if (facts) |host| {
                if (state.read_instance) |known| if (!std.mem.eql(u8, &known, &host.instance)) {
                    state.pending.items.len = 0;
                    state.token = null;
                    if (state.listing) state.listing_wanted = false;
                };
                state.read_instance = host.instance;
            }
        },
        .memory => |memory| {
            if (!std.meta.eql(state.memory, @as(?Memory, memory))) state.presentation_revision +%= 1;
            state.memory = memory;
        },
        .upgrade => |run| {
            state.upgrade.stand(run);
            if (run == .ended) {
                state.next_list_ms = 0;
            }
        },
        .models => |read| readModels(state, read),
        .defaults_saved => |saved| {
            if (saved) |binding| state.default = binding;
        },
        .available_upgrade => |available| state.upgrade.available = available,
        .start_upgrade => startUpgrade(state),
    }
    try archivedReads(state, &effects);
    for (effects.slice()) |effect| switch (effect) {
        .open => |reference| {
            if (state.entryOf(reference)) |entry| state.want(entry, attention.Status.opened(entry.status), false);
            askModels(state, &effects);
        },
        .open_settings => askModels(state, &effects),
        else => {},
    };
    return effects;
}

fn releaseInitialPresentation(state: *State, effects: *Effects) void {
    if (state.presentation != .holding) return;
    state.presentation = .released;
    state.presentation_revision +%= 1;
    effects.redraw = true;
}

fn readModels(state: *State, read: ModelsRead) void {
    state.asking_models = false;
    switch (read) {
        .menu => |menu| {
            var owned = menu;
            if (state.left) return owned.deinit(state.gpa);
            state.menu_revision += 1;
            state.menu.deinit(state.gpa);
            state.menu = owned;
            state.menu_read = .read;
        },
        .unanswered => {
            state.menu_read = .unanswered;
        },
        .invalid => {
            state.menu_read = .invalid;
        },
    }
}

pub fn writeDeparture(state: *const State, _: ?ReasoningEffort, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (state.requests[0..state.request_count]) |*request| {
        const text = request.text.slice();
        switch (request.kind) {
            .create => switch (request.status) {
                .pending => try writer.writeAll("rui: The new chat was not created.\n"),
                .failed => try writer.print("rui: The new chat was not created ({s}); try again from the overview.\n", .{text}),
                .unknown => try writer.print("rui: Not sure the new chat was created. Check with: rui request recover {s}\n", .{text}),
                .done => try writer.print("rui: Created {s}.\n", .{&request.session.?}),
            },
            .archive, .unarchive => switch (request.status) {
                .pending => try writer.print("rui: {s} request for {s} did not run.\n", .{ if (request.kind == .archive) "Archive" else "Restore", &request.session.? }),
                .failed => try writer.print("rui: Could not {s} {s}: {s}\n", .{ if (request.kind == .archive) "archive" else "restore", &request.session.?, text }),
                .unknown => try writer.print("rui: Not sure {s} {s}. Check with: rui request recover {s}\n", .{ &request.session.?, if (request.kind == .archive) "archived" else "restored", text }),
                .done => try writer.print("rui: {s} request accepted for {s}.\n", .{ if (request.kind == .archive) "Archive" else "Restore", &request.session.? }),
            },
            .pin, .unpin => switch (request.status) {
                .pending => try writer.print("rui: {s} request for {s} did not run.\n", .{ if (request.kind == .pin) "Pin" else "Unpin", &request.session.? }),
                .failed => try writer.print("rui: Could not {s} {s}: {s}\n", .{ if (request.kind == .pin) "pin" else "unpin", &request.session.?, text }),
                .unknown => try writer.print("rui: Not sure {s} {s}. Check with: rui request recover {s}\n", .{ &request.session.?, if (request.kind == .pin) "pinned" else "unpinned", text }),
                .done => try writer.print("rui: {s} request accepted for {s}.\n", .{ if (request.kind == .pin) "Pin" else "Unpin", &request.session.? }),
            },
            .stop => switch (request.status) {
                .pending => try writer.print("rui: {s} was not stopped.\n", .{&request.session.?}),
                .failed => try writer.print("rui: Could not stop {s}: {s}\n", .{ &request.session.?, text }),
                .unknown => try writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ &request.session.?, text }),
                .done => try writer.print("rui: Stopped {s}.\n", .{&request.session.?}),
            },
            .send => try submission.writeGuide(request.sent, writer),
            .configure => switch (request.status) {
                .pending => try writer.print("rui: Configure for {s} did not finish.\n", .{&request.session.?}),
                .unknown => {
                    try writer.print(configure_departure_prefix, .{&request.session.?});
                    var safe: TerminalText = .{ .mode = .line };
                    safe.feed(writer, request.configure_store.slice()) catch return error.WriteFailed;
                    safe.finish(writer) catch return error.WriteFailed;
                    try writer.print(configure_departure_suffix, .{ request.configure_intent.slice(), text, text });
                },
                .done, .failed => {},
            },
        }
    }
}

fn tick(state: *State, now_ms: u64, effects: *Effects) error{OutOfMemory}!void {
    const was_held = holding(state);
    const trouble = band(state);
    state.now_ms = now_ms;
    const released = was_held and !holding(state);
    if (released) try releaseOrder(state);
    var changed = false;
    var redraw = false;
    for (state.rows.items, 0..) |*row, index| {
        if (row.flash_until_ms != 0 and row.flash_until_ms <= now_ms) {
            if (index < state.nodes.items.len and state.nodes.items[index].line != null) redraw = true;
            row.flash_until_ms = 0;
        }
        if (row.archive_state == .archived) continue;
        const was = std.meta.activeTag(row.state);
        if (row.read_version) |version| settleRow(state, row, .{ .read_version = version, .work = row.work() });
        const settled = was != std.meta.activeTag(row.state);
        changed = changed or settled;
        redraw = redraw or (settled and classOf(state, row).visible);
    }
    if (changed and !released) try arrange(state);
    if (redraw or !std.meta.eql(trouble, band(state))) state.presentation_revision +%= 1;
    // A failed Archived window read retries on the list interval, whatever the roster walk is doing.
    if (state.archived.failed and now_ms >= state.archived.retry_ms) state.archived.failed = false;
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.listing_wanted = true;
        state.next_list_ms = now_ms + list_interval_ms;
        state.walk_since = state.token != null;
        // Active deltas still carry archived change seeds, while their creator rollups follow active membership.
        effects.add(.{ .list = .{ .since = state.token, .archive = .active } });
        if (state.menu.loading()) askModels(state, effects);
    }
}

fn askModels(state: *State, effects: *Effects) void {
    if (state.left or state.holdsHost() or state.asking_models) return;
    if (state.menu_read == .read and !state.menu.loading()) return;
    state.asking_models = true;
    effects.add(.list_models);
}

pub fn admitsDefaultsEdit(state: *const State) bool {
    return !state.left and !state.upgrade.held();
}

fn listPage(state: *State, page: Page, effects: *Effects) error{OutOfMemory}!void {
    std.debug.assert(state.listing);
    if (!state.listing_wanted) {
        if (page.answer != null) {
            state.listing = false;
            state.next_list_ms = 0;
            try tick(state, state.now_ms, effects);
        }
        return;
    }
    if (page.answer) |answer| if (!state.accepts(answer.since)) {
        rejectPage(state, page);
        return;
    };
    if (page.restarts) state.pending.items.len = 0;
    try state.pending.ensure(state.gpa, state.pending.items.len + page.rows.len);
    for (page.rows) |listed| {
        if (!state.accepts(listed.read_version)) {
            rejectPage(state, page);
            return;
        }
        state.pending.appendAssumeCapacity(try pendingRow(state, listed));
    }
    const answer = page.answer orelse return;
    // A since walk the Host answers in full is not a delta. Its pages are dropped unrouted, and the roster walks
    // afresh from no token. The Archived window re-anchors, as any full walk does.
    if (answer.delta == .full and state.walk_since) {
        state.pending.items.len = 0;
        state.walk_since = false;
        state.full_restarts +%= 1;
        restartArchivedAtHead(state);
        effects.add(.{ .list = .{ .since = null, .archive = .active } });
        return;
    }
    try readListing(state);
    try commit(state, answer);
    state.listing = false;
    const held = state.holdsHost();
    state.upgrade.reobserved();
    if (held != state.holdsHost()) state.presentation_revision +%= 1;
    try readFirstLines(state, effects);
    if (answer.delta == .full) restartArchivedAtHead(state);
}

/// The Row a listed Session becomes while its page is pending (or, for an Archived window row, placed).
fn rejectPage(state: *State, page: Page) void {
    state.pending.items.len = 0;
    if (!state.list_stale) state.presentation_revision +%= 1;
    state.list_stale = true;
    state.token = null;
    if (page.answer != null) state.listing = false else state.listing_wanted = false;
}

fn readListing(state: *State) error{OutOfMemory}!void {
    const opening = state.token == null;
    state.arrivals.items.len = 0;
    for (state.pending.items) |*incoming| {
        if (!incoming.hasMembership() or incoming.archive_state == .archived) continue;
        try state.readListed(incoming.reference, incoming.work(), opening);
    }
    try state.settleArrivals();
}

fn labelOf(text: []const u8) Bounded(max_label_bytes) {
    return Bounded(max_label_bytes).from(text) catch unreachable;
}

fn commit(state: *State, answer: Answer) error{OutOfMemory}!void {
    const selected = state.selected;
    const trouble = band(state);
    const summary = state.summary;
    const count = state.order.items.len;
    const stale = state.list_stale;
    const selected_at = if (state.selected == .session) position(state, state.selected.session) else null;
    const selected_ref = if (state.selected == .session) state.selected.session else null;
    const opening = state.token == null;
    if (answer.delta == .full) for (state.rows.items) |*row| {
        if (row.archive_state != .archived) row.listed = false;
    };
    if (answer.delta != .not_modified) {
        const before = state.rows.items.len;
        for (state.pending.items) |incoming| if (incoming.hasMembership() and incoming.archive_state != .archived and lookup(state.by_reference.items, incoming.reference) == null) {
            var row = incoming;
            row.read_version = null;
            row.born_held = holding(state);
            try state.rows.append(state.gpa, row);
            if (classOf(state, &row).visible) state.presentation_revision +%= 1;
        };
        if (before != state.rows.items.len) try reindex(state);
    }
    // Archived Sessions never enter the roster. A changed one leaves it, and the window re-reads its archive from the Host.
    if (answer.delta != .not_modified) for (state.pending.items) |*incoming| {
        if (incoming.hasMembership() and incoming.archive_state == .archived) try routeArchived(state, incoming);
    };
    if (answer.delta != .not_modified) for (state.pending.items) |*incoming| {
        if (!incoming.hasMembership()) {
            if (lookup(state.by_reference.items, incoming.reference)) |at| {
                const row = &state.rows.items[at];
                const before = RowPresentation.of(state, row);
                settleRow(state, row, .{ .read_version = incoming.read_version.?, .work = incoming.work() });
                const after = RowPresentation.of(state, row);
                if (classOf(state, row).visible and !before.eql(&after)) state.presentation_revision +%= 1;
            }
            continue;
        }
        if (incoming.archive_state == .archived) continue;
        const at = lookup(state.by_reference.items, incoming.reference).?;
        const row = &state.rows.items[at];
        const was = row.*;
        const before = RowPresentation.of(state, row);
        // The last arrange gave every drawn row a line; rows added by this commit have no node yet.
        const was_visible = at < state.nodes.items.len and state.nodes.items[at].line != null;
        const same = if (incoming.first) |first| if (row.first) |known| first.admission == known.admission else false else false;
        row.creator = incoming.creator;
        row.adoptMembership(incoming);
        row.pin_order = incoming.pin_order;
        row.created_at = incoming.created_at;
        if (row.clock_version == null or !std.mem.eql(u8, &row.clock_version.?.instance, &incoming.read_version.?.instance) or incoming.read_version.?.generation > row.clock_version.?.generation) {
            row.state_change_at = incoming.state_change_at;
            row.subtree_state_change_at = incoming.subtree_state_change_at;
            row.descendant_count = incoming.descendant_count;
            row.descendant_needs_you_count = incoming.descendant_needs_you_count;
            row.list_needs_you = incoming.list_needs_you;
            row.clock_version = incoming.read_version;
        }
        row.workspace = incoming.workspace;
        row.provider = incoming.provider;
        row.model = incoming.model;
        row.label = incoming.label;
        row.first = incoming.first;
        row.from_person_at = incoming.from_person_at;
        if (!same) row.line = .unread;
        row.listed = true;
        settleRow(state, row, .{ .read_version = incoming.read_version.?, .work = incoming.work() });
        retitle(state, row, title(state, &was).text);
        const after = RowPresentation.of(state, row);
        if (was_visible and classOf(state, row).visible and !before.eql(&after)) state.presentation_revision +%= 1;
    };
    for (state.rows.items) |row| if (!row.listed) {
        if (state.entryOf(row.reference)) |entry| {
            state.want(entry, null, false);
            entry.listed = null;
        }
    };
    try retainRows(state);
    state.pending.items.len = 0;
    state.token = answer.since;
    state.listed_at_ms = state.now_ms;
    state.list_stale = false;
    try arrange(state);
    reconcileSelection(state, selected_at, opening);
    if (selected_ref) |reference| {
        const physically_trimmed = state.archive == .archived and if (state.find(reference)) |row| row.archive_state == .archived else false;
        if (position(state, reference) == null and !physically_trimmed) {
            state.selected = .none;
            state.cancelBrowseTargetIf(reference);
        } else {
            state.selected = .{ .session = reference };
        }
    }
    if (stale or count != state.order.items.len or !std.meta.eql(selected, state.selected) or !std.meta.eql(summary, state.summary) or !std.meta.eql(trouble, band(state))) state.presentation_revision +%= 1;
}

/// The first line a row reads. Inline text is held now (the raw prefix of a window row, or the live row's text), and
/// the line rule and cut are applied here; a parts Message reads through the first-line job when it has content.
fn readableLine(state: *State, first: ?First) error{OutOfMemory}!FirstLineRead {
    const message = first orelse return .unread;
    if (message.line) |text| {
        try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(text)));
        return .{ .read = @intCast(state.lines.items.len - 1) };
    }
    return if (message.content == null) .unavailable else .unread;
}

fn archivedBounds(state: *const State) struct { first: ?u64, last: ?u64 } {
    var first: ?u64 = null;
    var last: ?u64 = null;
    for (state.rows.items) |*row| {
        if (!row.listed or row.archive_state != .archived) continue;
        const key = row.archive_seq orelse continue;
        first = if (first) |known| @max(known, key) else key;
        last = if (last) |known| @min(known, key) else key;
    }
    return .{ .first = first, .last = last };
}

/// Whether an archived Session with this key belongs in the window: at or above its first row only while
/// the window is at the head, inside [last, first], and below its last row only when the tail is held.
fn coversArchived(state: *const State, key: u64) bool {
    const bounds = archivedBounds(state);
    const first = bounds.first orelse return state.archived.at_head;
    if (key > first) return state.archived.at_head;
    if (key < bounds.last.?) return !state.archived.more_below;
    return true;
}

fn selectedAt(state: *const State) usize {
    return switch (state.selected) {
        .session => |ref| position(state, ref) orelse 0,
        else => 0,
    };
}

/// Replaces an archived row with the incoming one. A row whose first Message is unchanged keeps its line.
fn applyArchived(state: *State, row: *Row, incoming: *const Row) error{OutOfMemory}!void {
    const before = RowPresentation.of(state, row);
    const same = if (incoming.first) |first| if (row.first) |known| first.admission == known.admission else false else false;
    const line = if (same) row.line else try readableLine(state, incoming.first);
    row.adoptArchived(incoming);
    row.listed = true;
    row.line = line;
    retitle(state, row, before.name.slice());
    const after = RowPresentation.of(state, row);
    if (classOf(state, row).visible and !before.eql(&after)) state.presentation_revision +%= 1;
}

/// A changed Session that is archived leaves the roster. Its archive is not synthesized into the window: when its
/// key falls where the window reads, the window re-reads from the Host.
fn routeArchived(state: *State, incoming: *const Row) error{OutOfMemory}!void {
    if (lookup(state.by_reference.items, incoming.reference)) |index| state.rows.items[index].listed = false;
    const key = incoming.archive_seq orelse return;
    if (coversArchived(state, key)) scheduleRefresh(state, key);
}

/// Owes the window one re-read for an archive at `key`: the range below the new row when it sits inside the
/// window, or the head when it is newer than the window or another re-read is already owed.
fn scheduleRefresh(state: *State, key: u64) void {
    const bounds = archivedBounds(state);
    const from: session_list.ArchivedCursor = if (state.archived.refresh != null or bounds.first == null or key > bounds.first.?) .head else .{ .below = key +| 1 };
    state.archived.refresh = from;
}

fn namesArchived(rows: []const Listed, reference: Reference) bool {
    for (rows) |listed| if (std.mem.eql(u8, &listed.reference, &reference)) return true;
    return false;
}

/// Places one Archived window answer. Archived rows in the answer's key range that it does not name were
/// restored or moved since the read, so they leave the window; the named rows are upserted.
fn placeArchived(state: *State, read: ArchivedRead, page: ArchivedPage) error{OutOfMemory}!void {
    const selected_ref = if (state.selected == .session) state.selected.session else null;
    const selected_key = if (selected_ref) |reference| if (state.find(reference)) |row| row.archive_seq else null else null;
    const range: [2]u64 = switch (read.from) {
        .head => .{ 0, std.math.maxInt(u64) },
        .below => |key| .{ if (page.more_below) page.last orelse 0 else 0, key - 1 },
        .above => |key| .{ key + 1, if (page.more_above) page.first orelse std.math.maxInt(u64) else std.math.maxInt(u64) },
        .tail => unreachable,
    };
    const authority_range: [2]u64 = if (read.from == .head and page.more_below)
        .{ page.last orelse std.math.maxInt(u64), std.math.maxInt(u64) }
    else
        range;
    const selected_omitted = if (selected_ref) |reference| if (selected_key) |key|
        key >= authority_range[0] and key <= authority_range[1] and !namesArchived(page.rows, reference)
    else
        false else false;
    for (state.rows.items) |*row| {
        if (!row.listed or row.archive_state != .archived) continue;
        const key = row.archive_seq orelse continue;
        if (key < range[0] or key > range[1] or namesArchived(page.rows, row.reference)) continue;
        row.listed = false;
    }
    for (page.rows) |listed| {
        for (state.pending.items) |*staged| staged.supersedeMembership(listed.reference, page.since);
        var incoming = try pendingRow(state, listed);
        incoming.read_version = null;
        if (lookup(state.by_reference.items, listed.reference)) |index| {
            try applyArchived(state, &state.rows.items[index], &incoming);
        } else {
            incoming.line = try readableLine(state, incoming.first);
            try state.rows.append(state.gpa, incoming);
            try reindex(state);
        }
        if (state.entryOf(listed.reference)) |entry| {
            state.want(entry, null, false);
            entry.listed = null;
        }
    }
    switch (read.from) {
        .head => {
            state.archived.at_head = true;
            state.archived.more_below = page.more_below;
            state.archived.reanchor = false;
        },
        .below => state.archived.more_below = page.more_below,
        .above => state.archived.at_head = !page.more_above,
        .tail => unreachable,
    }
    try retainRows(state);
    try arrange(state);
    if (selected_omitted) {
        state.selected = .none;
        state.cancelBrowseTargetIf(selected_ref.?);
    }
}

fn archivedAnswer(state: *State, answer: ArchivedAnswer, effects: *Effects) error{OutOfMemory}!void {
    // Any answer clears the one read in flight. A stale-epoch answer is dropped, and archivedReads decides again.
    state.archived.inflight = false;
    if (answer.read.epoch != state.archived.epoch) return;
    if (answer.page == null or !state.accepts(answer.page.?.since)) {
        state.archived.failed = true;
        state.archived.retry_ms = state.now_ms + list_interval_ms;
        // A failed refresh is owed again. A failed re-anchor stays owed: `reanchor` clears only when a head is placed.
        if (!state.archived.reanchor and state.archived.refresh == null) state.archived.refresh = answer.read.from;
        return;
    }
    const page = answer.page.?;
    // A page with no rows (no first or last key) off the head is a restored or stale anchor: re-read the
    // head in a new epoch rather than trust the flags beside it (inspection.md, Archived window).
    if (page.rows.len == 0 and answer.read.from != .head) {
        restartArchivedAtHead(state);
        return;
    }
    try placeArchived(state, answer.read, page);
    // Only rows the window now holds are visible in the Archived view, so only they read a line.
    try readFirstLines(state, effects);
}

/// Asks for the Archived window page the screen needs next, one at a time: the head when the window is
/// empty or re-anchored, the next older page when the selection nears the bottom, the newer page when a
/// trimmed window's top comes into reach. Rows far from the selection are trimmed on both sides first, so
/// the window holds the shown rows and about two screens of margin each way.
fn archivedReads(state: *State, effects: *Effects) error{OutOfMemory}!void {
    if (state.archive != .archived or state.archived.inflight or state.archived.failed) return;
    // A re-anchor is owed until a head answer is placed. A refresh is owed for a routed archive.
    if (state.archived.reanchor) return readArchived(state, effects, .head);
    if (state.archived.refresh) |from| {
        state.archived.refresh = null;
        return readArchived(state, effects, from);
    }
    // The margin is at least one page, so a trim never drops rows the next page just brought in.
    const screen = @max(@as(usize, state.size.height), 1);
    const margin = @max(screen, archived_page_rows);
    var focus = archivedFocus(state);
    if (focus.first > 3 * margin) {
        const cutoff = state.rows.items[state.order.items[focus.first - 2 * margin]].archive_seq orelse return;
        for (state.rows.items) |*row| {
            if (!row.listed or row.archive_state != .archived) continue;
            if ((row.archive_seq orelse 0) > cutoff) row.listed = false;
        }
        state.archived.at_head = false;
        try retainRows(state);
        try arrange(state);
        focus = archivedFocus(state);
    }
    if (state.order.items.len -| focus.end > 3 * margin) {
        // Rows older than the one two margins below the shown rows are dropped; the Host still holds them.
        const cutoff = state.rows.items[state.order.items[focus.end + 2 * margin]].archive_seq orelse return;
        for (state.rows.items) |*row| {
            if (!row.listed or row.archive_state != .archived) continue;
            if ((row.archive_seq orelse 0) < cutoff) row.listed = false;
        }
        state.archived.more_below = true;
        try retainRows(state);
        try arrange(state);
        focus = archivedFocus(state);
    }
    const bounds = archivedBounds(state);
    const shown = state.order.items.len;
    if (bounds.first == null) {
        if (state.archived.at_head) return;
        return readArchived(state, effects, .head);
    }
    // Reads are asked for within one screen of an edge; the margin only decides what is trimmed.
    // The last shown row is focus.end - 1: a read is asked once it is within one screen of the held end.
    if (state.archived.more_below and shown -| (focus.end -| 1) <= screen) return readArchived(state, effects, .{ .below = bounds.last.? });
    if (!state.archived.at_head and focus.first < screen) return readArchived(state, effects, .{ .above = bounds.first.? });
}

/// The order indices the Archived window must keep: the rows the list shows after its last wheel scroll, or else
/// the selected Session. Only the most recent input holds rows, so a long wheel scroll holds the shown span
/// alone and a selection move releases the wheel's span. Trimming and reads take their edges from here.
fn archivedFocus(state: *const State) Focus {
    if (state.viewport) |span| if (position(state, span.first)) |top| if (position(state, span.last)) |bottom| {
        return .{ .first = @min(top, bottom), .end = @max(top, bottom) + 1 };
    };
    if (state.selected == .session) if (position(state, state.selected.session)) |at| return .{ .first = at, .end = at + 1 };
    return .{ .first = 0, .end = 0 };
}

fn readArchived(state: *State, effects: *Effects, from: session_list.ArchivedCursor) void {
    state.archived.inflight = true;
    effects.add(.{ .read_archived = .{ .from = from, .rows = archived_page_rows, .epoch = state.archived.epoch } });
}

/// The Session rows at the first and last Session lines of a reported span, by reference, so a later trim cannot
/// move them out from under the list. Headings and the pinned gap hold no row and are skipped. Only the Archived
/// list reports a viewport, and its rows are the Host's order.
fn viewportRows(state: *const State, span: Viewport) ?ViewRows {
    if (state.archive != .archived) return null;
    var first: ?usize = null;
    var last: usize = 0;
    var line = span.first;
    while (line < span.end and line < Lines.count(state)) : (line += 1) {
        const entry = Lines.kind(state, line) orelse break;
        if (entry != .row) continue;
        first = first orelse entry.row;
        last = entry.row;
    }
    const top = first orelse return null;
    return .{ .first = state.rows.items[state.order.items[top]].reference, .last = state.rows.items[state.order.items[last]].reference };
}

/// Re-anchors the Archived window at the head in a new epoch. A full roster walk and an empty page off the
/// head both come here, and so does tab re-entry through archivedReads. The head answer replaces every
/// held archived row the Host does not name, so a stale window cannot survive a re-anchor. A read in
/// flight is not replaced: its answer is stale now, and archivedReads reads the head once it lands.
fn restartArchivedAtHead(state: *State) void {
    state.archived.epoch +%= 1;
    state.archived.failed = false;
    state.archived.reanchor = true;
    state.archived.refresh = null;
}

fn reconcileSelection(state: *State, selected_at: ?usize, opening: bool) void {
    if (state.selected == .session and state.selectedRow() == null) {
        if (state.archive == .archived and if (state.find(state.selected.session)) |row| row.archive_state == .archived else false) return;
        state.selected = if (selected_at) |at| if (at < state.order.items.len) .{ .session = state.rows.items[state.order.items[at]].reference } else .new_session else .new_session;
    } else if (opening and state.selected == .new_session and state.order.items.len != 0) {
        state.selected = .{ .session = state.rows.items[state.order.items[0]].reference };
    }
}

fn workChanged(old: session_work.Work, work: session_work.Work) bool {
    if (std.meta.activeTag(old.state) != std.meta.activeTag(work.state) or old.state.since() != work.state.since()) return true;
    if (!std.meta.eql(old.turn, work.turn) or !std.meta.eql(old.operation, work.operation) or
        !std.meta.eql(old.first_action, work.first_action) or !std.meta.eql(old.actions, work.actions)) return true;
    return switch (old.state) {
        .retrying => |value| value.due_at_ms != work.state.retrying.due_at_ms or value.attempt != work.state.retrying.attempt or !value.cause.eql(work.state.retrying.cause.slice()),
        .bash => |value| changed: {
            const other = work.state.bash;
            const description_changed = if (value.description) |description|
                if (other.description) |text| !description.eql(text.slice()) else true
            else
                other.description != null;
            break :changed value.call != other.call or value.running != other.running or value.approvals != other.approvals or description_changed;
        },
        .failed => |value| value.resets_at != work.state.failed.resets_at or !value.code.eql(work.state.failed.code.slice()),
        .stopped => |value| value.cause != work.state.stopped.cause,
        .idle, .pending, .working, .approval, .stopping, .finished => |value| value.compaction != switch (work.state) {
            .idle, .pending, .working, .approval, .stopping, .finished => |other| other.compaction,
            else => unreachable,
        },
    };
}

fn settleRow(state: *State, row: *Row, read: session_list.Snapshot) void {
    row.state = row.state.asOf(state.now_ms);
    if (!state.accepts(read.read_version)) return;
    if (row.read_version) |known| {
        if (std.mem.eql(u8, &known.instance, &read.read_version.instance) and read.read_version.generation <= known.generation) return;
    }
    var next = read.work;
    next.state = next.state.asOf(state.now_ms);
    for (state.requests[0..state.request_count]) |*held| {
        if (held.kind != .stop or !held.stop_overlay or !std.mem.eql(u8, &held.session.?, &row.reference)) continue;
        const baseline = held.stop_baseline orelse continue;
        const later = !std.mem.eql(u8, &baseline.version.instance, &read.read_version.instance) or read.read_version.generation > baseline.version.generation;
        var original = baseline.work;
        original.state = original.state.asOf(state.now_ms);
        if (later and workChanged(original, next)) held.stop_overlay = false;
    }
    row.read_version = read.read_version;
    row.state = next.state;
    row.turn = read.work.turn;
    row.operation = read.work.operation;
    row.first_action = read.work.first_action;
    row.actions = read.work.actions;
}

fn retainRows(state: *State) error{OutOfMemory}!void {
    var kept: usize = 0;
    for (state.rows.items) |row| {
        const open = if (state.conversing) |ref| std.mem.eql(u8, &ref, &row.reference) else false;
        const selected_archive = state.archive == .archived and state.selected == .session and row.archive_state == .archived and std.mem.eql(u8, &state.selected.session, &row.reference);
        if (!row.listed and !open and !selected_archive) continue;
        state.rows.items[kept] = row;
        kept += 1;
    }
    if (kept != state.rows.items.len) {
        state.rows.items.len = kept;
        try reindex(state);
        try compactLines(state);
    }
}

/// Keeps only the first-line text a surviving row reads, so dropped rows free their lines.
fn compactLines(state: *State) error{OutOfMemory}!void {
    var fresh: Vec(Bounded(max_line_bytes)) = .{};
    errdefer fresh.deinit(state.gpa);
    for (state.rows.items) |*row| switch (row.line) {
        .read => |index| {
            try fresh.ensure(state.gpa, fresh.items.len + 1);
            fresh.appendAssumeCapacity(state.lines.items[index]);
            row.line = .{ .read = @intCast(fresh.items.len - 1) };
        },
        else => {},
    };
    state.lines.deinit(state.gpa);
    state.lines = fresh;
}

fn retitle(state: *State, row: *const Row, was: []const u8) void {
    if (std.mem.eql(u8, title(state, row).text, was)) return;
    if (state.entryOf(row.reference)) |entry| state.want(entry, entry.status, true);
}

fn reindex(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.by_reference.ensure(state.gpa, rows.len);
    state.by_reference.items.len = rows.len;
    for (state.by_reference.items, rows, 0..) |*keyed, *row, at| keyed.* = .{ .key = referenceKey(row.reference), .index = @intCast(at) };
    std.mem.sortUnstable(Keyed, state.by_reference.items, {}, struct {
        fn less(_: void, a: Keyed, b: Keyed) bool {
            return a.key < b.key or (a.key == b.key and a.index < b.index);
        }
    }.less);
    var kept: usize = 0;
    for (state.by_reference.items, 0..) |keyed, at| {
        const next = at + 1;
        if (next < state.by_reference.items.len and state.by_reference.items[next].key == keyed.key) continue;
        state.by_reference.items[kept] = keyed;
        kept += 1;
    }
    if (kept == rows.len) return;
    const survivors = state.by_reference.items[0..kept];
    std.mem.sortUnstable(Keyed, survivors, {}, struct {
        fn less(_: void, a: Keyed, b: Keyed) bool {
            return a.index < b.index;
        }
    }.less);
    for (survivors, 0..) |*keyed, at| {
        rows[at] = rows[keyed.index];
        keyed.index = @intCast(at);
    }
    std.mem.sortUnstable(Keyed, survivors, {}, struct {
        fn less(_: void, a: Keyed, b: Keyed) bool {
            return a.key < b.key;
        }
    }.less);
    state.rows.items.len = kept;
    state.by_reference.items.len = kept;
}

/// The Row a listed Session becomes while its page is pending, or placed as an Archived window row.
fn pendingRow(state: *State, input: Listed) error{OutOfMemory}!Row {
    const listed = input;
    const shown = listed.state.asOf(state.now_ms);
    var row: Row = .{
        .reference = listed.reference,
        .creator = listed.creator,
        .read_version = listed.read_version,
        .operation = listed.operation,
        .archive_state = listed.archive_state,
        .archive_seq = listed.archive_seq,
        .pin_order = listed.pin_order,
        .created_at = listed.created_at,
        .state_change_at = listed.state_change_at,
        .subtree_state_change_at = listed.subtree_state_change_at,
        .descendant_count = listed.descendant_count,
        .descendant_needs_you_count = listed.descendant_needs_you_count,
        .list_needs_you = session_work.standing(listed.state, listed.actions.decide != null) == .needs_you,
        .workspace = try state.intern(listed.workspace),
        .provider = listed.provider,
        .model = bounded(model_capability.max_model_bytes, listed.model),
        .label = if (listed.label) |text| labelOf(text) else null,
        .state = shown,
        .turn = listed.turn,
        .first_action = listed.first_action,
        .actions = listed.actions,
        .first = listed.first,
        .from_person_at = listed.from_person_at,
    };
    row.setArchivedSince(listed.state.since());
    return row;
}

fn factsOf(state: *const State, row: *const Row) session_class.Facts {
    return .{
        .state = &row.state,
        .archive = row.archive_state,
        .in_list = row.listed,
        .creator = row.creator != null,
        .pinned = row.pin_order != null,
        .first_message = row.first != null,
        .from_person = row.from_person_at != null,
        .decidable = row.actions.decide != null,
        .open = if (state.conversing) |open| std.mem.eql(u8, &open, &row.reference) else false,
        .stop_pending = state.stopOverlays(row.reference),
        .provider = row.provider,
        .model = row.model.slice(),
    };
}

fn viewerOf(state: *const State) session_class.Viewer {
    return .{ .filter = state.archive, .now_ms = state.now_ms, .login_at = state.login_at };
}

fn classOf(state: *const State, row: *const Row) session_class.Class {
    return session_class.classify(factsOf(state, row), viewerOf(state));
}

fn arrange(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.nodes.ensure(state.gpa, rows.len);
    try state.scratch.ensure(state.gpa, rows.len);
    try state.sort_keys.ensure(state.gpa, rows.len);
    try state.order.ensure(state.gpa, rows.len);
    state.nodes.items.len = rows.len;
    try state.ordered_refs.ensure(state.gpa, rows.len);
    try state.full_order.ensure(state.gpa, rows.len);
    const nodes = state.nodes.items;
    for (rows, 0..) |*row, i| {
        nodes[i] = .{
            .included = classOf(state, row).visible,
            .descendants = if (row.archive_state == .archived) 0 else row.descendant_count,
            .attention = if (row.archive_state == .archived) 0 else row.descendant_needs_you_count,
        };
        // Archived rows are never nested: they come from the window in the Host's order.
        if (!row.listed or row.archive_state == .archived) continue;
        if (row.creator) |creator| if (lookup(state.by_reference.items, creator)) |parent| {
            // An available creator is a live row, or an archived one when the filter shows it; an archived
            // creator is never pulled in, so a live Session never enters the Archived view through it.
            if (parent != i and rows[parent].listed and rows[parent].archive_state != .archived and state.archive.includes(rows[parent].archive_state)) nodes[i].logical_parent = parent;
        };
    }
    for (state.ordered_refs.items, 0..) |reference, old_position| {
        if (lookup(state.by_reference.items, reference)) |index| nodes[index].old_position = old_position;
    }
    // An available creator of a visible agent must itself be visible.
    for (nodes, 0..) |*node, i| if (node.included) {
        var parent = nodes[i].logical_parent;
        while (parent) |index| {
            if (nodes[index].included) break;
            nodes[index].included = true;
            parent = nodes[index].logical_parent;
        }
    };
    for (nodes) |node| if (node.included) if (node.logical_parent) |parent| {
        if (nodes[parent].included) nodes[parent].remaining += 1;
    };
    state.scratch.items.len = 0;
    for (nodes, 0..) |node, i| if (node.included and node.remaining == 0) state.scratch.appendAssumeCapacity(@intCast(i));
    var cursor: usize = 0;
    while (cursor < state.scratch.items.len) : (cursor += 1) {
        const index = state.scratch.items[cursor];
        if (nodes[index].logical_parent) |parent| if (nodes[parent].included) {
            nodes[parent].remaining -= 1;
            if (nodes[parent].remaining == 0) state.scratch.appendAssumeCapacity(parent);
        };
    }
    // A malformed cycle has no creator root. Promote its members to roots.
    for (nodes) |*node| if (node.remaining != 0) {
        node.logical_parent = null;
        node.remaining = 0;
    };
    state.sort_keys.items.len = 0;
    const latest = std.math.maxInt(u64);
    for (rows, 0..) |*row, i| {
        if (!nodes[i].included) continue;
        nodes[i].parent = if (row.pin_order == null) nodes[i].logical_parent else null;
        if (row.sibling_rank == std.math.maxInt(u64)) {
            row.sibling_rank = state.next_rank;
            state.next_rank += 1;
        }
        if (row.archive_state == .archived) {
            // Archived rows keep the Host's order: newest archive first, after the live rows.
            state.sort_keys.appendAssumeCapacity(.{ .pin_order = row.pin_order, .key = archived_sort_bit | (std.math.maxInt(i64) -| (row.archive_seq orelse 0)), .index = @intCast(i) });
            continue;
        }
        const rank: u128 = if (holding(state)) row.sibling_rank else latest - @min(row.subtree_state_change_at, latest);
        state.sort_keys.appendAssumeCapacity(.{ .pin_order = row.pin_order, .key = rank << 48 | referenceKey(row.reference), .index = @intCast(i) });
    }
    std.mem.sortUnstable(SortKey, state.sort_keys.items, {}, struct {
        fn less(_: void, a: SortKey, b: SortKey) bool {
            if (a.pin_order) |rank| return if (b.pin_order) |other| rank > other else true;
            if (b.pin_order != null) return false;
            return a.key < b.key;
        }
    }.less);
    if (!holding(state)) {
        state.next_rank = 0;
        for (state.sort_keys.items) |key| {
            rows[key.index].sibling_rank = state.next_rank;
            state.next_rank += 1;
        }
    }
    for (state.sort_keys.items) |key| if (nodes[key.index].parent) |parent| {
        nodes[key.index].next_sibling = nodes[parent].first_child;
        nodes[parent].first_child = key.index;
    };
    state.order.items.len = 0;
    for (0..2) |phase| {
        state.scratch.items.len = 0;
        var at = state.sort_keys.items.len;
        while (at != 0) {
            at -= 1;
            const index = state.sort_keys.items[at].index;
            if (nodes[index].parent == null and (rows[index].pin_order != null) == (phase == 0)) state.scratch.appendAssumeCapacity(index);
        }
        while (state.scratch.items.len != 0) {
            state.scratch.items.len -= 1;
            const index = state.scratch.items.ptr[state.scratch.items.len];
            state.order.appendAssumeCapacity(index);
            var child = nodes[index].first_child;
            var last = true;
            while (child) |next| {
                nodes[next].depth = nodes[index].depth + 1;
                nodes[next].last_sibling = last;
                last = false;
                state.scratch.appendAssumeCapacity(next);
                child = nodes[next].next_sibling;
            }
        }
        if (phase == 0) state.pin_end = state.order.items.len;
    }
    state.full_order.items.len = state.order.items.len;
    @memcpy(state.full_order.items, state.order.items);
    // A pinned subtree is displayed once. Subtract each nearest pinned frontier
    // from its logical ancestors using only facts from the same LIST snapshot.
    for (state.sort_keys.items) |key| {
        const index = key.index;
        if (rows[index].pin_order == null) continue;
        const hidden_count = rows[index].descendant_count +| 1;
        const question_count = rows[index].descendant_needs_you_count +| @as(u64, @intFromBool(rows[index].list_needs_you));
        var ancestor = nodes[index].logical_parent;
        while (ancestor) |parent| {
            nodes[parent].descendants -|= hidden_count;
            nodes[parent].attention -|= question_count;
            if (rows[parent].pin_order != null) break;
            ancestor = nodes[parent].logical_parent;
        }
    }
    var kept: usize = 0;
    var pin_kept: usize = 0;
    for (state.order.items, 0..) |index, index_in_full| {
        if (nodes[index].parent) |parent| {
            nodes[index].hidden = nodes[parent].hidden or isFolded(state, rows[parent].reference);
            if (nodes[index].hidden) nodes[index].representative = nodes[parent].representative orelse parent;
        }
        if (nodes[index].hidden) continue;
        state.order.items[kept] = index;
        kept += 1;
        if (index_in_full < state.pin_end) pin_kept += 1;
    }
    state.order.items.len = kept;
    state.pin_end = pin_kept;
    state.ordered_refs.items.len = 0;
    for (state.order.items, 0..) |index, position_| {
        nodes[index].line = position_ + @intFromBool(state.pin_end != 0 and state.pin_end < state.order.items.len and position_ >= state.pin_end);
        if (state.releasing and !rows[index].born_held) if (nodes[index].old_position) |old| {
            if (old != position_) rows[index].flash_until_ms = state.now_ms +| 700;
        };
        if (state.releasing) rows[index].born_held = false;
        state.ordered_refs.appendAssumeCapacity(rows[index].reference);
    }
    if (state.releasing) for (rows) |*row| {
        row.born_held = false;
    };
    state.summary.counts = counts(state);
    var hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&state.pin_end));
    for (state.order.items) |index| {
        const node = nodes[index];
        hash = std.hash.Wyhash.hash(hash, &rows[index].reference);
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&node.depth));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&node.last_sibling));
        const folded = isFolded(state, rows[index].reference) and node.descendants != 0;
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&folded));
        if (folded) {
            hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&node.descendants));
            hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&node.attention));
        }
    }
    const tree = hash;
    if (state.tree_presentation == null or state.tree_presentation.? != tree) state.presentation_revision +%= 1;
    state.tree_presentation = tree;
}

fn holding(state: *const State) bool {
    return state.pointer_over or state.now_ms < state.key_until_ms;
}

fn releaseOrder(state: *State) error{OutOfMemory}!void {
    state.releasing = true;
    defer state.releasing = false;
    try arrange(state);
}

fn isFolded(state: *const State, reference: Reference) bool {
    for (state.folded.items) |folded| if (std.mem.eql(u8, &folded, &reference)) return true;
    return false;
}

fn foldable(state: *const State, reference: Reference) bool {
    const index = lookup(state.by_reference.items, reference) orelse return false;
    return index < state.nodes.items.len and state.nodes.items[index].descendants != 0;
}

fn foldSelected(state: *State, folded: bool) error{OutOfMemory}!void {
    if (state.selected != .session) return;
    const reference = state.selected.session;
    if (!foldable(state, reference)) return;
    for (state.folded.items, 0..) |known, at| {
        if (!std.mem.eql(u8, &known, &reference)) continue;
        if (folded) return;
        std.mem.copyForwards(Reference, state.folded.items[at .. state.folded.items.len - 1], state.folded.items[at + 1 ..]);
        state.folded.items.len -= 1;
        try arrange(state);
        return;
    }
    if (!folded) return;
    try state.folded.append(state.gpa, reference);
    try arrange(state);
}

fn counts(state: *const State) Counts {
    var result: Counts = .{};
    for (state.rows.items) |*row| result.add(classOf(state, row));
    return result;
}

/// A Session's place in the drawn order. A Session hidden in a collapsed
/// branch takes its collapsed ancestor's place, so selection, highlight,
/// list moves and Alt-Up/Down work from a hidden open chat without unfolding.
fn position(state: *const State, ref: Reference) ?usize {
    for (state.order.items, 0..) |row, at| if (std.mem.eql(u8, &state.rows.items[row].reference, &ref)) return at;
    const index = lookup(state.by_reference.items, ref) orelse return null;
    if (index >= state.nodes.items.len) return null;
    const representative = state.nodes.items[index].representative orelse return null;
    for (state.order.items, 0..) |row, at| if (row == representative) return at;
    return null;
}

fn readFirstLines(state: *State, effects: *Effects) error{OutOfMemory}!void {
    var reads: Reads = .{};
    for (state.order.items) |at| {
        if (reads.len == reads.items.len) break;
        const row = &state.rows.items[at];
        const first = row.first orelse continue;
        const content = first.content orelse continue;
        if (row.label != null or row.line != .unread) continue;
        row.line = .requested;
        reads.items[reads.len] = .{ .reference = row.reference, .position = first.position, .admission = first.admission, .content = content };
        reads.len += 1;
    }
    if (reads.len != 0) effects.add(.{ .read_first_lines = reads });
}

fn firstLine(state: *State, result: FirstLine) error{OutOfMemory}!void {
    const at = lookup(state.by_reference.items, result.reference) orelse return;
    const row = &state.rows.items[at];
    if (row.line != .requested) return;
    const first = row.first orelse return;
    if (first.admission != result.admission) return;
    if (result.unanswered) {
        row.line = .unread;
        return;
    }
    const bytes = result.line orelse {
        row.line = .unavailable;
        return;
    };
    const before = RowPresentation.of(state, row);
    try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(bytes)));
    row.line = .{ .read = @intCast(state.lines.items.len - 1) };
    retitle(state, row, before.name.slice());
    const after = RowPresentation.of(state, row);
    if (classOf(state, row).visible and !before.eql(&after)) state.presentation_revision +%= 1;
}

const StopTarget = struct { reference: Reference, work: Kind, can_stop: bool };

fn stopKey(state: *State, exact: ?StopTarget, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    state.notice = null;
    const target = exact orelse selected: {
        const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
        break :selected StopTarget{ .reference = row.reference, .work = if (row.archive_state == .archived) .stopped else (&row.state).asOf(state.now_ms), .can_stop = row.archive_state != .archived and row.actions.stop };
    };
    const ref = target.reference;
    const kind = session_class.withStop(target.work, state.stopOverlays(ref));
    if (!target.can_stop or state.openStop(ref) != null) return refuseStop(state, ref, kind);
    if (state.request(.stop, ref)) {
        if (state.find(ref)) |row| if (row.read_version) |version| {
            if (state.accepts(version)) state.requests[state.request_count - 1].stop_baseline = .{ .version = version, .work = row.work() };
        };
        effects.add(.{ .stop = ref });
    }
}

fn refuseStop(state: *State, ref: Reference, kind: Kind) void {
    if (state.openStop(ref)) |held| if (held.status == .unknown)
        return state.say(.attention, "{s} stop unsure; details on exit", .{&ref});
    if (rules.get(kind).word) |word_| return state.say(.quiet, "{s} is already {s}.", .{ &ref, word_ });
    if (kind == .stopping) return state.say(.quiet, "{s}: {s}", .{ &ref, work_line.stopping.words });
    state.say(.quiet, "{s} cannot be stopped now.", .{&ref});
}

fn shownSince(state: *const State, row: *const Row) u64 {
    return row.sinceAsOf(state.now_ms);
}

fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    if (row.archive_state == .archived) return null;
    return if (state.stopOverlays(row.reference)) work_line.stopping else work_line.of(words, (&row.state), null, state.now_ms);
}

fn clickOpen(state: *State, reference: Reference, effects: *Effects) error{OutOfMemory}!void {
    _ = position(state, reference) orelse return;
    state.selected = .{ .session = reference };
    try enterSelected(state, effects);
}

fn select(state: *State, action: Action) void {
    move(state, action);
}

pub const upgrade_recovery = session_upgrade.recovery_words;

fn admitHostRequest(state: *State) bool {
    if (!state.holdsHost()) return true;
    state.say(.attention, upgrade_recovery, .{});
    return false;
}

fn startUpgrade(state: *State) void {
    if (state.upgrade.start()) state.notice = null;
}

fn listInput(state: *State, delivery: InputDelivery, effects: *Effects) error{OutOfMemory}!void {
    const input = delivery.key;
    if (delivery.pasted or input == .ignored) return;
    const browse_move = input == .action and (input.action == .previous or input.action == .next);
    if (!browse_move) state.cancelBrowseTarget();
    if (input == .action and input.action == .exit) {
        effects.add(.exit);
        return;
    }
    if (input == .action and input.action == .clear and state.upgrade.takesEscape()) {
        effects.add(.cancel_upgrade);
        return;
    }
    if (delivery.under or state.creating()) return;
    state.cancelParentClick();
    const before = state.selected;
    switch (input) {
        .ignored => unreachable,
        .enter => try activateList(state, .enter, effects),
        .left => if (state.selected == .archived) {
            state.selected = .sessions;
        },
        .action => |action| switch (action) {
            .exit => unreachable,
            .open_session => {
                switch (state.selected) {
                    .session => try activateList(state, .open_session, effects),
                    .sessions => state.selected = .archived,
                    .none, .new_session, .archived, .settings => {},
                }
            },
            .collapse_tree => try foldSelected(state, true),
            .expand_tree => try foldSelected(state, false),
            .clear => {
                state.notice = null;
                if (state.archive == .archived) try changeArchiveView(state, .active, effects);
            },
            .stop => stopKey(state, null, effects),
            .archive => archiveIntent(state, .selected_archive, effects),
            .next_question => try nextQuestion(state, effects),
            .select_previous => select(state, .previous),
            .select_next => select(state, .next),
            .previous_session => try adjacentSession(state, .previous, effects),
            .next_session => try adjacentSession(state, .next, effects),
            else => {
                state.notice = null;
                select(state, action);
            },
        },
    }
    if (input == .action and (input.action == .previous or input.action == .next)) {
        state.queueBrowseTarget(delivery.wide, !std.meta.eql(before, state.selected));
    }
}

fn nextQuestion(state: *State, effects: *Effects) error{OutOfMemory}!void {
    const order = state.full_order.items;
    if (order.len == 0) return;
    const anchor = state.last_question orelse state.conversing;
    var start: usize = 0;
    if (anchor) |reference| for (order, 0..) |index, at| {
        if (std.mem.eql(u8, &state.rows.items[index].reference, &reference)) {
            start = (at + 1) % order.len;
            break;
        }
    };
    for (0..order.len) |offset| {
        const row = &state.rows.items[order[(start + offset) % order.len]];
        if (!row.listed or classOf(state, row).standing != .needs_you) continue;
        state.selected = .{ .session = row.reference };
        state.last_question = row.reference;
        try enterSelected(state, effects);
        return;
    }
}

fn adjacentSession(state: *State, direction: Action, effects: *Effects) error{OutOfMemory}!void {
    const order = state.order.items;
    if (order.len == 0) return;
    const anchor = if (state.conversing) |open|
        position(state, open) orelse return
    else if (state.selected == .session)
        position(state, state.selected.session)
    else
        null;
    const target = if (anchor) |at| switch (direction) {
        .previous => at -| 1,
        .next => @min(at + 1, order.len - 1),
        else => unreachable,
    } else if (direction == .previous) order.len - 1 else 0;
    state.selected = .{ .session = state.rows.items[order[target]].reference };
    try enterSelected(state, effects);
}

fn enterSelected(state: *State, effects: *Effects) error{OutOfMemory}!void {
    try activateList(state, .enter, effects);
}

/// Enter activates any row; Right (`open_session`) and a settled browse
/// act only on a Session row.
const ListIntent = enum { enter, open_session, browse };
fn activateList(state: *State, intent: ListIntent, effects: *Effects) error{OutOfMemory}!void {
    if (state.creating() or state.selected == .none) return;
    if (intent != .enter and state.selected != .session) return;
    if (state.selected == .settings) {
        effects.add(.open_settings);
        return;
    }
    if (state.selected == .sessions) return selectView(state, .active, effects);
    if (state.selected == .archived) return selectView(state, .archived, effects);
    if (state.selected == .session) if (state.conversing) |open| if (std.mem.eql(u8, &state.selected.session, &open)) {
        if (intent != .browse) effects.add(.focus_chat);
        return;
    };
    if (!admitHostRequest(state)) return;
    if (state.selected == .new_session and state.conversing != null) {
        effects.add(.new_session);
        return;
    }
    switch (state.selected) {
        .none => {},
        .settings, .sessions, .archived => unreachable,
        .session => if (state.selectedRow()) |row| {
            effects.add(.{ .open = row.reference });
            effects.browse_open = intent == .browse;
        },
        .new_session => {
            if (state.request(.create, null)) effects.add(.{ .create = state.nextStart() });
        },
    }
}

const ArchiveIntent = union(enum) {
    selected_archive,
    selected_restore,
    ask: struct { reference: Reference, work: Kind, archive: ArchiveState },
    restore: Reference,
};

fn archiveIntent(state: *State, intent: ArchiveIntent, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    state.notice = null;
    effects.intent_admission = switch (intent) {
        .selected_archive => blk: {
            const row = state.selectedRow() orelse {
                state.say(.attention, no_selection, .{});
                break :blk .refused;
            };
            break :blk askArchive(state, row.reference, (&row.state).asOf(state.now_ms), row.archive_state, effects);
        },
        .selected_restore => blk: {
            const row = state.selectedRow() orelse {
                state.say(.attention, no_selection, .{});
                break :blk .refused;
            };
            break :blk archiveSession(state, .{ .reference = row.reference, .archived = false }, effects);
        },
        .ask => |target| askArchive(state, target.reference, target.work, target.archive, effects),
        .restore => |ref| archiveSession(state, .{ .reference = ref, .archived = false }, effects),
    };
}

fn askArchive(state: *State, ref: Reference, work: Kind, archive: ArchiveState, effects: *Effects) IntentAdmission {
    _ = work;
    if (archive != .active) return .refused;
    return archiveSession(state, .{ .reference = ref }, effects);
}

fn carryPointer(state: *State, pointer: Pointer, effects: *Effects) error{OutOfMemory}!void {
    const pressed = state.carry.pressed orelse return;
    if (pointer.phase == .held) {
        const before = state.carry;
        if (!state.carry.carrying) {
            // A drag still inside the pressed row is a click that wobbled.
            if (pointer.over != null and pointer.over.? == .open and std.mem.eql(u8, &pointer.over.?.open, &pressed)) return;
            state.cancelParentClick();
            state.carry.carrying = true;
        }
        state.carry.over = pointer.over;
        if (!std.meta.eql(before, state.carry)) state.presentation_revision +%= 1;
        return;
    }
    if (pointer.phase == .released) {
        const over = if (pointer.over != null and pointer.over.? == .open) pointer.over.?.open else null;
        state.releaseParentClick(over);
    } else state.cancelParentClick();
    const dropped = pointer.phase == .released and state.carry.carrying and blk: {
        state.carry.over = pointer.over;
        break :blk state.carry.dropping(state);
    };
    const target = state.carry.dropTarget(state);
    endCarry(state);
    if (!dropped) return;
    switch (target.?) {
        .archived => {
            const row = state.find(pressed).?;
            archiveIntent(state, .{ .ask = .{ .reference = pressed, .work = (&row.state).asOf(state.now_ms), .archive = row.archive_state } }, effects);
        },
        .sessions => archiveIntent(state, .{ .restore = pressed }, effects),
        else => unreachable,
    }
}

fn endCarry(state: *State) void {
    if (state.carry.carrying) state.presentation_revision +%= 1;
    state.carry = .{};
}

fn organizationHeld(state: *State, reference: Reference) bool {
    for (state.requests[0..state.request_count]) |held| {
        if (held.kind != .archive and held.kind != .unarchive and held.kind != .pin and held.kind != .unpin) continue;
        if (held.status != .pending and held.status != .unknown) continue;
        if (std.mem.eql(u8, &held.session.?, &reference)) {
            state.say(.attention, "{s} organization request {s}; details on exit.", .{ &reference, if (held.status == .pending) "pending" else "unsure" });
            return true;
        }
    }
    return false;
}

fn pinIntent(state: *State, request: PinRequest, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    if (organizationHeld(state, request.reference)) return;
    if (state.request(if (request.pinned) .pin else .unpin, request.reference)) {
        effects.add(.{ .pin = request });
        effects.intent_admission = .admitted;
    }
}

fn archiveSession(state: *State, request: ArchiveRequest, effects: *Effects) IntentAdmission {
    if (organizationHeld(state, request.reference)) return .refused;
    if (state.request(if (request.archived) .archive else .unarchive, request.reference)) {
        effects.add(.{ .archive = request });
        return .admitted;
    }
    return .refused;
}

fn selectView(state: *State, filter: ArchiveFilter, effects: *Effects) error{OutOfMemory}!void {
    std.debug.assert(filter != .all);
    try changeArchiveView(state, filter, effects);
    state.selected = if (filter == .archived) .archived else .sessions;
}

fn changeArchiveView(state: *State, filter: ArchiveFilter, effects: *Effects) error{OutOfMemory}!void {
    if (state.archive == filter) return;
    if (state.archive == .archived) state.archived.leave();
    state.archive = filter;
    state.viewport = null;
    state.selected = .new_session;
    try arrange(state);
    state.presentation_revision +%= 1;
    try archivedReads(state, effects);
}

const no_selection = "Select a chat first.";

fn move(state: *State, action: Action) void {
    const order = state.order.items;
    if (state.selected == .none and (action == .previous or action == .next)) {
        if (action == .previous) {
            state.selected = if (state.archive == .archived) .archived else .sessions;
        } else if (order.len != 0) {
            state.selected = .{ .session = state.rows.items[order[0]].reference };
        } else {
            state.selected = .settings;
        }
        return;
    }
    const current: usize = switch (state.selected) {
        .none => 1,
        .new_session => 0,
        .sessions, .archived => 1,
        // A selection a trim dropped from the held rows sits just above the top shown Session, so the next move
        // starts from the rows on screen.
        .session => |ref| if (position(state, ref)) |at| at + 2 else if (state.viewport) |span| (if (position(state, span.first)) |top| top + 1 else 0) else 0,
        .settings => order.len + 2,
    };
    const target = switch (action) {
        .first => 0,
        .last => order.len + 2,
        .next => @min(current + 1, order.len + 2),
        .previous => current -| 1,
        else => unreachable,
    };
    state.selected = if (target == 0) .new_session else if (target == 1)
        (if (state.archive == .archived) .archived else .sessions)
    else if (target > order.len + 1) .settings else .{ .session = state.rows.items[order[target - 2]].reference };
}

pub const Band = session_class.Band;

/// The provider trouble the visible Sessions share, if any; `session_class.trouble` decides it.
pub fn band(state: *const State) ?Band {
    const Reader = struct {
        fn at(context: *const anyopaque, index: usize) session_class.Facts {
            const owner: *const State = @ptrCast(@alignCast(context));
            return factsOf(owner, &owner.rows.items[index]);
        }
    };
    const rows: session_class.Rows = .{ .context = state, .count = state.rows.items.len, .at = Reader.at };
    return session_class.trouble(rows, viewerOf(state));
}

pub const Rgb = @import("theme.zig").Rgb;

pub const Skin = enum { day, night };

pub const Caps = struct {
    unicode: bool = true,
    devanagari: bool = false,

    width: gwidth.Method = .wcwidth,

    depth: Depth = .direct,

    background: ?Rgb = null,

    pub const Depth = enum { none, indexed, direct };

    pub const Environment = struct {
        lc_all: ?[]const u8 = null,
        lc_ctype: ?[]const u8 = null,
        lang: ?[]const u8 = null,
        no_color: ?[]const u8 = null,
        colorterm: ?[]const u8 = null,
        /// Windows Terminal sets WT_SESSION and forwards it into WSL, where COLORTERM does not reach.
        wt_session: ?[]const u8 = null,
    };

    pub fn of(environment: Environment) Caps {
        const locale = for ([_]?[]const u8{ environment.lc_all, environment.lc_ctype, environment.lang }) |value| {
            if (value) |text| if (text.len != 0) break text;
        } else null;
        const utf8 = if (locale) |text| for (0..text.len) |at| {
            if (std.ascii.startsWithIgnoreCase(text[at..], "utf-8") or std.ascii.startsWithIgnoreCase(text[at..], "utf8")) break true;
        } else false else true;
        const colorterm: []const u8 = environment.colorterm orelse "";
        const no_color: []const u8 = environment.no_color orelse "";
        const windows_terminal: []const u8 = environment.wt_session orelse "";
        const depth: Depth = if (no_color.len != 0)
            .none
        else if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit") or windows_terminal.len != 0)
            .direct
        else
            .indexed;
        return .{ .unicode = utf8, .depth = depth };
    }

    pub fn skin(self: Caps) Skin {
        const rgb = self.background orelse return .night;
        const luminance = 2126 * @as(u32, rgb[0]) + 7152 * @as(u32, rgb[1]) + 722 * @as(u32, rgb[2]);
        return if (luminance >= 10000 * 128) .day else .night;
    }
};

pub const Style = overview_style.Style;
pub const Segment = overview_style.Segment;

pub const Span = struct {
    column: u16,

    cells: u16,
    text: []const u8,
    style: Style,
};

const Glyphs = struct { prompt: []const u8, dot: []const u8, ellipsis: []const u8, arrows: []const u8, sides: []const u8, up: []const u8, down: []const u8, newline: []const u8 };
const unicode_glyphs: Glyphs = .{ .prompt = "›", .dot = work_line.glyphs.get(.unicode).dot, .ellipsis = work_line.glyphs.get(.unicode).ellipsis, .arrows = "↑↓", .sides = "←→", .up = "↑", .down = "↓", .newline = "↵" };
const ascii_glyphs: Glyphs = .{ .prompt = ">", .dot = work_line.glyphs.get(.ascii).dot, .ellipsis = work_line.glyphs.get(.ascii).ellipsis, .arrows = "^v", .sides = "<>", .up = "^", .down = "v", .newline = "|" };

pub const Layout = struct {
    top: u16 = 0,
    list: Rows = .{},

    settings: Rows = .{},

    host: Rows = .{},

    input: u16 = 0,

    pub const Rows = struct {
        start: u16 = 0,
        end: u16 = 0,

        pub fn len(self: Rows) u16 {
            return self.end - self.start;
        }
    };
};

pub fn layout(state: *const State) Layout {
    const height = state.size.height;
    if (height == 0 or state.size.width == 0) return .{};
    const settings = state.sidebar_rule orelse (@import("draft_layout.zig").fixedBottom(height, 0, .overview).rule orelse height);
    const top: u16 = @intCast(@min(topRows(state), settings));
    const footer_rows: u16 = @intFromBool(footerShown(state));
    const input = @max(top, settings -| (statusRows(state) + footer_rows));
    const host = @max(top, input -| @intFromBool(state.host_line));
    return .{ .top = top, .list = .{ .start = top, .end = host }, .settings = .{ .start = settings, .end = height }, .host = .{ .start = host, .end = input }, .input = input };
}

fn statusRows(state: *const State) u16 {
    var buffer: StatusBuffer = undefined;
    const line = statusLine(state, .{}, &buffer) orelse return 0;
    var drawn: [max_status_bytes]u8 = undefined;
    var rows: [max_notice_rows][]const u8 = undefined;
    return @intCast(noticeRows(line.drawn(&drawn), state.size.width, .{}, &rows).len);
}

fn topRows(state: *const State) usize {
    return @as(usize, @intFromBool(band(state) != null)) + 3;
}

const Spans = struct {
    arena: Allocator,
    caps: Caps,
    glyphs: Glyphs,
    width: u16,
    spans: [24]Span = undefined,
    count: usize = 0,
    column: usize = 0,

    fn of(arena: Allocator, caps: Caps, width: u16) Spans {
        return .{ .arena = arena, .caps = caps, .glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs, .width = width };
    }

    fn script(self: *const Spans) work_line.Script {
        return if (self.caps.unicode) .unicode else .ascii;
    }

    fn begin(self: *Spans) void {
        self.count = 0;
        self.column = 0;
    }

    fn finish(self: *Spans) error{OutOfMemory}![]const Span {
        return self.arena.dupe(Span, self.spans[0..self.count]);
    }

    fn pad(self: *Spans, column: usize, wanted: Style) error{OutOfMemory}!void {
        const to = @min(column, self.width);
        if (to <= self.column) return;
        if (wanted.reverse or wanted.background != .ground) {
            const blank = try self.arena.alloc(u8, to - self.column);
            @memset(blank, ' ');
            self.push(blank, to - self.column, wanted);
        }
        self.column = to;
    }

    fn push(self: *Spans, bytes: []const u8, cells: usize, wanted: Style) void {
        if (self.count == self.spans.len or cells == 0) return;
        self.spans[self.count] = .{ .column = @intCast(self.column), .cells = @intCast(cells), .text = bytes, .style = wanted };
        self.count += 1;
        self.column += cells;
    }

    fn put(self: *Spans, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        return self.putKept(column, bytes, limit, wanted, .head);
    }

    fn putTail(self: *Spans, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        return self.putKept(column, bytes, limit, wanted, .tail);
    }

    fn putKept(self: *Spans, column: usize, bytes: []const u8, limit: usize, wanted: Style, keep: Keep) error{OutOfMemory}!usize {
        try self.pad(column, wanted);
        const room = @min(limit, self.width -| self.column);
        if (room == 0) return 0;
        const shown = try fitted(self.arena, self.caps, bytes, room, keep);
        self.push(shown.bytes, shown.cells, wanted);
        return shown.cells;
    }

    fn putRight(self: *Spans, end: usize, bytes: []const u8, wanted: Style) error{OutOfMemory}!void {
        const cells = self.measure(bytes);
        if (cells > end or end - cells < self.column) return;
        _ = try self.put(end - cells, bytes, cells, wanted);
    }

    fn measure(self: *const Spans, bytes: []const u8) usize {
        return measured(self.caps, self.glyphs, bytes);
    }
};

pub const Keep = enum { head, tail };

pub fn fitted(arena: Allocator, caps: Caps, bytes: []const u8, room: usize, keep: Keep) error{OutOfMemory}!Piece {
    return (try fittedMarked(arena, caps, bytes, room, keep, null)).piece;
}

/// A half-open byte interval in source text or its fitted display text.
pub const ByteSpan = struct { start: usize, len: usize };

pub const MarkedPiece = struct {
    piece: Piece,
    /// Only retained display bytes whose source intersects the requested
    /// span, expanded to complete display pieces; never the ellipsis.
    span: ?ByteSpan = null,
};

/// Fit through the same terminal-safe pieces as `fitted`, translating one
/// source span as those pieces are retained. Normalization can change byte
/// lengths before or within a match, so output equality is not provenance.
pub fn fittedMarked(arena: Allocator, caps: Caps, bytes: []const u8, room: usize, keep: Keep, source_span: ?ByteSpan) error{OutOfMemory}!MarkedPiece {
    if (room == 0) return .{ .piece = .{ .bytes = "", .cells = 0 } };
    const glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs;
    const total = measured(caps, glyphs, bytes);
    const ellipsis = glyphs.ellipsis;
    const budget = if (total <= room) total else room - 1;
    var out = try arena.alloc(u8, bytes.len * 3 + ellipsis.len);
    var used: usize = 0;
    var cells: usize = 0;
    if (keep == .tail and total > room) {
        @memcpy(out[0..ellipsis.len], ellipsis);
        used = ellipsis.len;
    }
    var skip = if (keep == .tail) total - budget else 0;
    var pieces: Pieces = .{ .bytes = bytes, .caps = caps, .glyphs = glyphs };
    var displayed: ?ByteSpan = null;
    while (true) {
        const source_start = pieces.at;
        const piece = pieces.next() orelse break;
        if (skip > 0) {
            skip -|= piece.cells;
            continue;
        }
        if (cells + piece.cells > budget) break;
        const display_start = used;
        @memcpy(out[used..][0..piece.bytes.len], piece.bytes);
        used += piece.bytes.len;
        cells += piece.cells;
        if (source_span) |mark| {
            if (mark.len != 0 and mark.start < pieces.at and source_start < mark.start +| mark.len) {
                if (displayed) |*mapped| mapped.len = used - mapped.start else displayed = .{ .start = display_start, .len = used - display_start };
            }
        }
    }
    if (keep == .head and total > room) {
        @memcpy(out[used..][0..ellipsis.len], ellipsis);
        used += ellipsis.len;
    }
    return .{ .piece = .{ .bytes = out[0..used], .cells = cells + @intFromBool(total > room) }, .span = displayed };
}

fn measured(caps: Caps, glyphs: Glyphs, bytes: []const u8) usize {
    var total: usize = 0;
    var pieces: Pieces = .{ .bytes = bytes, .caps = caps, .glyphs = glyphs };
    while (pieces.next()) |piece| total += piece.cells;
    return total;
}

fn standIn(caps: Caps, glyphs: Glyphs, codepoint: u21) ?[]const u8 {
    if (codepoint == '\n') return glyphs.newline;
    if (codepoint == '\t') return " ";
    if (TerminalText.isControl(codepoint) or codepoint == replacement) return "?";
    if (!caps.unicode and codepoint > 0x7e) return "?";
    return null;
}

pub const Piece = struct { bytes: []const u8, cells: usize };

const Pieces = struct {
    bytes: []const u8,
    caps: Caps,
    glyphs: Glyphs,
    at: usize = 0,

    fn next(self: *Pieces) ?Piece {
        if (self.at == self.bytes.len) return null;
        const rest = self.bytes[self.at..];
        const first = decode(rest);
        if (standIn(self.caps, self.glyphs, first.codepoint)) |glyph| {
            self.at += first.len;
            return .{ .bytes = glyph, .cells = 1 };
        }
        if (!self.caps.unicode or (first.codepoint < 0x80 and (rest.len == 1 or rest[1] < 0x80))) {
            self.at += 1;
            return .{ .bytes = rest[0..1], .cells = 1 };
        }
        var clusters = unicode.graphemeIterator(rest);
        const cluster = clusters.next().?.len;
        var end = first.len;
        while (end < cluster) {
            const decoded = decode(rest[end..]);
            if (standIn(self.caps, self.glyphs, decoded.codepoint) != null) break;
            end += decoded.len;
        }
        self.at += end;
        return .{ .bytes = rest[0..end], .cells = gwidth.gwidth(rest[0..end], self.caps.width) };
    }
};

const replacement = 0xfffd;

fn decode(bytes: []const u8) struct { codepoint: u21, len: usize } {
    const first = bytes[0];
    const len: usize = switch (first) {
        0x00...0x7f => return .{ .codepoint = first, .len = 1 },
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return .{ .codepoint = replacement, .len = 1 },
    };
    if (bytes.len < len or !std.unicode.utf8ValidateSlice(bytes[0..len])) return .{ .codepoint = replacement, .len = 1 };
    var codepoint: u21 = first & (@as(u8, 0x7f) >> @intCast(len));
    for (bytes[1..len]) |byte| codepoint = codepoint << 6 | (byte & 0x3f);
    return .{ .codepoint = codepoint, .len = len };
}

fn emptyLine(built: *Spans, state: *const State) error{OutOfMemory}![]const Span {
    built.begin();
    const text = if (state.listed_at_ms == null)
        try std.fmt.allocPrint(built.arena, "Loading{s}", .{built.glyphs.ellipsis})
    else if (state.archive == .archived)
        "No archived chats."
    else if (state.archive == .all)
        "No chats yet."
    else
        "No chats yet.";
    _ = try built.put(1, text, built.width -| 2, .{ .colour = .quiet });
    return built.finish();
}

fn bandLine(built: *Spans, text: []const u8) error{OutOfMemory}![]const Span {
    built.begin();
    const style: Style = .{ .colour = .on_band, .background = .band, .bold = true };
    try built.pad(1, style);
    _ = try built.put(1, text, built.width -| 2, style);
    try built.pad(built.width, style);
    return built.finish();
}

fn providerBand(built: *Spans, trouble: Band, now_ms: u64) error{OutOfMemory}![]const Span {
    var buffer: [8]u8 = undefined;
    return bandLine(built, switch (trouble.trouble) {
        .sign_in => sign_in: {
            if (loginOf(trouble.provider.?)) |command| {
                const run = try std.fmt.allocPrint(built.arena, "Sign-in expired. Run {s}.", .{command});
                if (run.len <= built.width -| 2) break :sign_in run;
            }
            break :sign_in try std.fmt.allocPrint(built.arena, "{s} sign-in expired.", .{shownOf(trouble.provider.?)});
        },
        .api_key => if (loginOf(trouble.provider.?)) |command|
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Run {s}, then rui host pause.", .{ shownOf(trouble.provider.?), command })
        else
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Save a new key, then rui host pause.", .{shownOf(trouble.provider.?)}),
        .quota => quota: {
            const used = if (trouble.resets_at) |at|
                try std.fmt.allocPrint(built.arena, "Quota used up. Resets in {s}.", .{(Age{ .remaining = at }).text(&buffer, now_ms)})
            else
                "Quota used up.";
            if (usageOf(trouble.provider.?)) |usage| {
                const managed = try std.fmt.allocPrint(built.arena, "{s} {s}", .{ used, usage });
                if (managed.len <= built.width -| 2) break :quota managed;
            }
            break :quota used;
        },
        .rate_limit => try std.fmt.allocPrint(built.arena, "Rate limited. {d} chat{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
    });
}

pub fn grouped(buffer: *[32]u8, count: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{count}) catch unreachable;
    var used: usize = 0;
    const head = text.len -| 3;
    for (text, 0..) |digit, at| {
        if (at != 0 and at <= head and (head - at) % 2 == 0) {
            buffer[used] = ',';
            used += 1;
        }
        buffer[used] = digit;
        used += 1;
    }
    return buffer[0..used];
}

pub const Drawn = struct {
    first: usize = 0,
    end: usize = 0,
    header: bool = false,
};

pub fn nextRedrawAt(state: *const State, drawn: Drawn, caps: Caps, awake_ms: u64) ?u64 {
    var next: ?u64 = null;
    if (!state.pointer_over and state.key_until_ms > state.now_ms) {
        next = awake_ms +| (state.key_until_ms - state.now_ms);
    }
    for (drawn.first..drawn.end) |at| {
        const kind = Lines.kind(state, at) orelse break;
        if (kind != .row) continue;
        const row = &state.rows.items[state.order.items[kind.row]];
        if (row.flash_until_ms > state.now_ms) {
            const deadline = awake_ms +| (row.flash_until_ms - state.now_ms);
            next = @min(next orelse deadline, deadline);
        }
        switch (rowActivity(state, kind.row, caps)) {
            .spin => {
                const deadline = awake_ms +| (spin_interval_ms - awake_ms % spin_interval_ms);
                next = @min(next orelse deadline, deadline);
            },
            // A held word never changes on its own.
            .held => {},
            .none => {
                if ((Age{ .elapsed = shownSince(state, row) }).nextAt(state.now_ms)) |epoch_ms| {
                    const deadline = awake_ms +| (epoch_ms -| state.now_ms);
                    next = @min(next orelse deadline, deadline);
                }
            },
        }
    }
    if (drawn.header) if (band(state)) |trouble| if (trouble.trouble == .quota) {
        if (trouble.resets_at) |at| if ((Age{ .remaining = at }).nextAt(state.now_ms)) |epoch_ms| {
            const deadline = awake_ms +| (epoch_ms -| state.now_ms);
            next = @min(next orelse deadline, deadline);
        };
    };
    return next;
}

const new_session_name = "New chat";

pub const Target = Click;

/// An on-demand list line. Segments and regions live in the supplied arena.
pub const Line = struct {
    segments: []const Segment,
    heading: bool = false,
    target: ?Target = null,
    alternate: ?Target = null,
    regions: []const Region = &.{},
    spins: bool = false,
};

pub const Region = struct { start: u16, end: u16, target: Target, selected: bool = false };

/// Indexed projection of the committed visible order; never materializes the list.
pub const Lines = struct {
    const Entry = union(enum) { gap, row: usize, empty };

    fn gapAt(state: *const State) ?usize {
        return if (state.pin_end != 0 and state.pin_end < state.order.items.len) state.pin_end else null;
    }

    pub fn count(state: *const State) usize {
        return @max(1, state.order.items.len + @intFromBool(gapAt(state) != null));
    }

    fn lineOf(state: *const State, row: usize) usize {
        return row + @intFromBool(if (gapAt(state)) |gap| row >= gap else false);
    }

    pub fn sessionsFrom(state: *const State, line: usize) usize {
        const before = line -| @intFromBool(if (gapAt(state)) |gap| line > gap else false);
        return state.order.items.len -| before;
    }

    /// The conversation-first row whose name is bold, also highlighted off-list.
    pub fn named(state: *const State) ?usize {
        const ref = namedSession(state) orelse return null;
        return if (position(state, ref)) |row| lineOf(state, row) else null;
    }

    /// Keyboard selection while focused; the open conversation otherwise.
    pub fn highlighted(state: *const State, focused: bool) ?usize {
        if (!focused) return named(state);
        return switch (state.selected) {
            .session => |ref| if (position(state, ref)) |row| lineOf(state, row) else null,
            .none, .new_session, .sessions, .archived, .settings => null,
        };
    }

    fn namedSession(state: *const State) ?Reference {
        return state.conversing orelse switch (state.selected) {
            .session => |ref| ref,
            .none, .new_session, .sessions, .archived, .settings => null,
        };
    }

    fn kind(state: *const State, line: usize) ?Entry {
        if (line >= count(state)) return null;
        if (state.order.items.len == 0) return .empty;
        const row = if (gapAt(state)) |gap| blk: {
            if (line == gap) return .gap;
            break :blk line - @intFromBool(line > gap);
        } else line;
        return .{ .row = row };
    }

    /// The same animation decision used by rendering and redraw scheduling.
    pub fn spins(state: *const State, line: usize, caps: Caps) bool {
        const entry = kind(state, line) orelse return false;
        return entry == .row and rowActivity(state, entry.row, caps) == .spin;
    }

    pub fn at(arena: Allocator, state: *const State, line: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}!?Line {
        const entry = kind(state, line) orelse return null;
        if (entry == .row) {
            const row = &state.rows.items[state.order.items[entry.row]];
            return .{
                .segments = try rowSegments(arena, state, entry.row, width, caps, frame),
                .target = .{ .open = row.reference },
                .alternate = .{ .pin = .{ .reference = row.reference, .pinned = row.pin_order == null } },
                .spins = rowActivity(state, entry.row, caps) == .spin,
            };
        }
        var built: Spans = .of(arena, caps, width);
        built.begin();
        const spans = if (entry == .empty) try emptyLine(&built, state) else &.{};
        return .{ .segments = try segmentsOf(arena, spans, width, .{}), .heading = entry == .empty };
    }
};

pub const Edge = enum { above, below };
pub fn edgeAttention(state: *const State, edge: Edge, first: usize, end: usize) usize {
    var result: usize = 0;
    for (state.order.items) |index| {
        const row = &state.rows.items[index];
        const node = state.nodes.items[index];
        if (classOf(state, row).standing != .needs_you and !(row.archive_state != .archived and isFolded(state, row.reference) and node.attention != 0)) continue;
        const line = node.line orelse continue;
        if (switch (edge) {
            .above => line < first,
            .below => line >= end,
        }) result += 1;
    }
    return result;
}
pub fn sessionsFrom(state: *const State, line: usize) usize {
    return Lines.sessionsFrom(state, line);
}
pub fn lineOfReference(state: *const State, reference: Reference) ?usize {
    return if (position(state, reference)) |at| Lines.lineOf(state, at) else null;
}
pub fn selectedLine(state: *const State) ?usize {
    return Lines.highlighted(state, true);
}
pub fn listLength(state: *const State) usize {
    return Lines.count(state);
}

fn rowSelected(state: *const State, row: *const Row) bool {
    const ref = Lines.namedSession(state) orelse return false;
    return std.mem.eql(u8, &ref, &row.reference);
}

/// How a listed row shows that it is active. Every reader (glyph, colour, age
/// column and redraw deadlines) asks this one owner.
pub const Activity = union(enum) { none, spin, held: []const u8 };

/// The rule that draws a row's mark. An Archived window row has no work state, so it has no mark.
const no_work_rule: Rule = .{ .colour = .normal };

/// The mark a row wears: its shown work kind's sign; an Archived window row has no work state, so no mark.
fn rowMark(state: *const State, row: *const Row) Mark {
    if (row.archive_state == .archived) return .none;
    return classOf(state, row).kind.sign();
}

fn markRule(state: *const State, row: *const Row) Rule {
    if (row.archive_state == .archived) return no_work_rule;
    return rules.get(classOf(state, row).kind);
}

fn rowActivity(state: *const State, at: usize, caps: Caps) Activity {
    const row = &state.rows.items[state.order.items[at]];
    const rule = markRule(state, row);
    if (rowMark(state, row) != .active) return .none;
    if (rule.spins and !state.list_stale and caps.unicode and caps.depth != .none) return .spin;
    return .{ .held = rule.held.? };
}

fn rowSegments(arena: Allocator, state: *const State, at: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    const index = state.order.items[at];
    const row = &state.rows.items[index];
    const node = state.nodes.items[index];
    const quiet = classOf(state, row).quiet;
    const rule = markRule(state, row);
    const flash = row.flash_until_ms > state.now_ms;
    const background: Background = if (flash) .hover else .ground;
    built.begin();
    const activity = rowActivity(state, at, caps);
    var age_buffer: [8]u8 = undefined;
    const age: []const u8 = switch (activity) {
        .none => (Age{ .elapsed = shownSince(state, row) }).text(&age_buffer, state.now_ms),
        .spin => "",
        .held => |word| word,
    };
    const title_floor: usize = 24;
    // Leave room for a two-cell title grapheme and an ellipsis.
    const useful_title_cells: usize = 3;
    const mark_and_gap: usize = 2;
    const inset: usize = 1;
    const row_width: usize = width;
    const folded = isFolded(state, row.reference) and node.descendants != 0;
    const normal_hidden = if (folded) try std.fmt.allocPrint(arena, " {s} {d}", .{ if (caps.unicode) "▸" else ">", node.descendants }) else "";
    const normal_attention = if (folded and node.attention != 0) try std.fmt.allocPrint(arena, " {s} {d} ?", .{ if (caps.unicode) "·" else ".", node.attention }) else "";
    const archived = if (row.archive_state == .archived and state.archive != .archived)
        if (caps.unicode) " · archived" else " . archived"
    else
        "";
    const normal_badge_cells = built.measure(normal_hidden) + built.measure(normal_attention);
    const archived_cells = built.measure(archived);
    const normal_suffix_cells = normal_badge_cells + archived_cells;
    // Budget guides against the spaced badges, so gaining room can never cost a guide.
    const depth_budget = (row_width -| (2 * inset + mark_and_gap + title_floor + normal_suffix_cells)) / 2;
    const depth: usize = @min(node.depth, depth_budget);

    // Folded rows keep room for an ordinary age where possible. The fixed budgets
    // retain spaced badges at 40 cells and allow compact badges and 999d at 36.
    const compact = folded and row_width < mark_and_gap + title_floor + normal_badge_cells + 4;
    const hidden = if (compact) try std.fmt.allocPrint(arena, "{s}{d}", .{ if (caps.unicode) "▸" else ">", node.descendants }) else normal_hidden;
    const attention_badge = if (compact and node.attention != 0) try std.fmt.allocPrint(arena, "{s}{d}?", .{ if (caps.unicode) "·" else ".", node.attention }) else normal_attention;
    const hidden_cells = built.measure(hidden);
    const attention_cells = built.measure(attention_badge);
    const tight = folded and row_width < 2 * inset + mark_and_gap + title_floor + archived_cells + hidden_cells + attention_cells + 5;
    const end = row_width -| (if (tight) @as(usize, 0) else inset);
    const origin = if (tight and end < inset + mark_and_gap + title_floor + normal_suffix_cells) 0 else inset;
    if (depth != 0) {
        const path = try arena.alloc(u32, depth);
        var current: u32 = index;
        var remaining = depth;
        while (remaining != 0) {
            remaining -= 1;
            path[remaining] = current;
            current = state.nodes.items[current].parent orelse break;
        }
        const guides = try arena.alloc(u8, depth * 4);
        var used: usize = 0;
        for (path, 0..) |member, level| {
            const last = state.nodes.items[member].last_sibling;
            const segment = if (!caps.unicode) "  " else if (level + 1 == depth)
                if (last) "╰ " else "│ "
            else if (last) "  " else "│ ";
            @memcpy(guides[used..][0..segment.len], segment);
            used += segment.len;
        }
        _ = try built.put(origin, guides[0..used], depth * 2, .{ .colour = .quiet, .background = background, .dim = quiet });
    }
    const mark_at = origin + depth * 2;
    const mark = marks.get(rowMark(state, row));
    const glyph = switch (activity) {
        .spin => spinner[frame % spinner.len],
        .held, .none => if (caps.unicode) mark.unicode else mark.ascii,
    };
    var words: [work_line.max_words_bytes]u8 = undefined;
    const progress = workLine(&words, state, row);
    const colour = if (progress) |line| switch (line.tone) {
        .normal => rule.colour,
        .quiet => Colour.quiet,
        .attention => Colour.attention,
    } else rule.colour;
    _ = try built.put(mark_at, glyph, 1, .{ .colour = colour, .background = background, .dim = quiet });
    const start_name = mark_at + mark_and_gap;
    const room = end -| start_name;
    const named = title(state, row).text;
    const name = if (row.archive_state == .archiving) try std.fmt.allocPrint(arena, "[Archiving] {s}", .{named}) else named;
    const Suffix = struct { text: []const u8, cells: usize, colour: Colour = .quiet };
    var suffixes = [_]Suffix{
        .{ .text = archived, .cells = archived_cells },
        .{ .text = hidden, .cells = hidden_cells },
        .{ .text = attention_badge, .cells = attention_cells, .colour = .attention },
    };
    // On very narrow rows leave space for the title and omit badges whole.
    var suffix_cells: usize = 0;
    for (&suffixes) |*suffix| {
        if (suffix.cells > room -| useful_title_cells -| suffix_cells) suffix.cells = 0;
        suffix_cells += suffix.cells;
    }
    const age_cells = built.measure(age);
    const age_room = room -| (suffix_cells + age_cells + 1);
    const show_age = age_cells != 0 and room > suffix_cells + age_cells and
        (age_room >= useful_title_cells or age_room >= built.measure(name));
    const name_room = if (show_age) age_room else room -| suffix_cells;
    const selected = rowSelected(state, row);
    const used = try built.put(start_name, name, name_room, .{ .colour = if (selected) .strong else .normal, .background = background, .bold = selected, .dim = quiet });
    var suffix_at = start_name + used;
    for (suffixes) |suffix| {
        if (suffix.cells == 0) continue;
        suffix_at += try built.put(suffix_at, suffix.text, suffix.cells, .{ .colour = suffix.colour, .background = background, .dim = quiet and suffix.colour != .attention });
    }
    if (show_age) _ = try built.put(end - age_cells, age, age_cells, .{ .colour = .quiet, .background = background, .dim = quiet });
    return segmentsOf(arena, try built.finish(), width, .{ .background = background, .dim = quiet });
}

pub fn headerSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    const trouble = band(state) orelse return &.{};
    var built: Spans = .of(arena, caps, width);
    return segmentsOf(arena, try providerBand(&built, trouble, state.now_ms), width, .{});
}

/// The fixed New Session and archive-filter controls, with captured tab regions.
pub fn controls(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![2]Line {
    var built: Spans = .of(arena, caps, width);
    built.begin();
    _ = try built.put(mark_column, "+", 1, .{});
    _ = try built.put(text_column, new_session_name, width -| (text_column + 1), .{});
    const new_session = try segmentsOf(arena, try built.finish(), width, .{});
    built.begin();
    var regions: [2]Region = undefined;
    var region_count: usize = 0;
    const drop = state.carry.dropTarget(state);
    const dropping = state.carry.dropping(state);
    inline for (.{ .{ "Chats", Selection.sessions, ArchiveFilter.active, Click.sessions }, .{ "Archived", Selection.archived, ArchiveFilter.archived, Click.archived } }, 0..) |tab, index| {
        const start = text_column + index * ("Chats".len + 2);
        const active = state.archive == tab[2];
        const focused = state.selected == tab[1];
        // A carried row's tab takes the hover shade, and the selection shade while the pointer holds it there.
        const target = drop != null and std.meta.eql(drop.?, tab[3]);
        try built.pad(start, .{});
        const cells = try built.put(start, tab[0], width -| 1 -| start, .{
            .colour = if (active or focused or target) .strong else .quiet,
            .bold = active or (target and dropping),
            .background = if (!target) .ground else if (dropping) .selection else .hover,
        });
        if (cells > 0) {
            regions[region_count] = .{ .start = @intCast(start), .end = @intCast(start + cells), .target = tab[3], .selected = focused };
            region_count += 1;
        }
    }
    const hint_at = text_column + "Chats".len + 2 + "Archived".len + 2;
    // The shaded tab names what the drop does; the words only say that it takes one, and fit a sidebar.
    if (drop != null) {
        _ = try built.put(hint_at, if (caps.unicode) "· drop here" else ". drop here", width -| hint_at, .{ .colour = if (dropping) .strong else .quiet });
    }
    return .{
        .{ .segments = new_session, .target = .new_session },
        .{ .segments = try segmentsOf(arena, try built.finish(), width, .{}), .regions = try arena.dupe(Region, regions[0..region_count]) },
    };
}

/// What a waiting launch does at poll time. `wait` keeps the launch open until
/// sign-in saves a default, so a named launch never creates under another binding.
pub const LaunchChoice = union(enum) { reopen: Reference, create, wait };

/// The one launch choice, read at poll time from `default`, the binding that
/// creation uses. `defaults` reopens the newest empty Session of any binding,
/// or creates when none exists, including with no `default` yet.
/// `named` with a `default` reopens only an empty Session with that provider
/// and model, otherwise creates; with no `default` yet it waits for sign-in.
/// Only `defaults` and `named` reach this choice: `launch_poll` runs only while
/// `launch_start` has set one of them.
pub fn chooseLaunch(intent: LaunchIntent, default: ?Default, rows: []const Row) LaunchChoice {
    const reference = switch (intent) {
        .defaults => newestEmpty(rows, null),
        .named => if (default) |binding| newestEmpty(rows, binding) else return .wait,
        .explicit_session, .restoring => unreachable,
    };
    return if (reference) |found| .{ .reopen = found } else .create;
}

/// The newest unarchived Session with no first Message, restricted to
/// `binding`'s provider and model when one is given.
pub fn newestEmpty(rows: []const Row, binding: ?Default) ?Reference {
    var newest: ?*const Row = null;
    for (rows) |*row| {
        if (!row.listed or row.archive_state == .archived or row.first != null) continue;
        if (binding) |want| if (!Provider.eqlOptional(row.provider, want.provider) or !row.model.eql(want.model.slice())) continue;
        if (newest == null or row.created_at > newest.?.created_at or
            (row.created_at == newest.?.created_at and std.mem.order(u8, &row.reference, &newest.?.reference) == .gt)) newest = row;
    }
    return if (newest) |row| row.reference else null;
}

pub fn footerShown(state: *const State) bool {
    return footerRight(state).len > 0 or footerNotice(state) != null;
}

pub fn footerRight(state: *const State) []const u8 {
    if (state.upgrade.takesEscape()) return "esc cancels";
    return "";
}

pub fn footerNotice(state: *const State) ?state_marks.Say {
    return if (state.notice) |*notice| notice.said() else null;
}

fn segmentsOf(arena: Allocator, spans: []const Span, width: u16, fill: Style) error{OutOfMemory}![]const Segment {
    const segments = try arena.alloc(Segment, spans.len * 2 + 1);
    var count: usize = 0;
    var column: usize = 0;
    for (spans) |span| {
        if (span.column > column) {
            segments[count] = .{ .text = try blankCells(arena, span.column - column), .style = fill };
            count += 1;
        }
        segments[count] = .{ .text = span.text, .style = span.style };
        count += 1;
        column = @as(usize, span.column) + span.cells;
    }
    if (width > column) {
        segments[count] = .{ .text = try blankCells(arena, width - column), .style = fill };
        count += 1;
    }
    return segments[0..count];
}

fn blankCells(arena: Allocator, cells: usize) error{OutOfMemory}![]const u8 {
    const bytes = try arena.alloc(u8, cells);
    @memset(bytes, ' ');
    return bytes;
}

fn title(state: *const State, row: *const Row) session_line.Name {
    if (row.first == null) return .{ .text = new_session_name, .hint = false };
    return session_line.name(if (row.label) |*text| text.slice() else null, state.lineOf(row), &row.reference);
}

const Age = union(enum) {
    elapsed: u64,
    remaining: u64,

    const Unit = struct { seconds: u64, suffix: u8 };

    fn unit(duration: u64) Unit {
        for ([_]Unit{ .{ .seconds = 86400, .suffix = 'd' }, .{ .seconds = 3600, .suffix = 'h' } }) |value| {
            if (duration >= value.seconds) return value;
        }
        return .{ .seconds = 60, .suffix = 'm' };
    }

    fn seconds(self: Age, now_ms: u64) u64 {
        return switch (self) {
            .elapsed => |since| now_ms / 1000 -| since,
            .remaining => |until| until -| now_ms / 1000,
        };
    }

    fn text(self: Age, buffer: *[8]u8, now_ms: u64) []const u8 {
        const duration = self.seconds(now_ms);
        if (duration < 60) return switch (self) {
            .elapsed => "now",
            .remaining => "under a minute",
        };
        const value = unit(duration);
        return std.fmt.bufPrint(buffer, "{d}{c}", .{ @min(duration / value.seconds, 999), value.suffix }) catch unreachable;
    }

    fn nextAt(self: Age, now_ms: u64) ?u64 {
        const duration = self.seconds(now_ms);
        const value = unit(duration);
        return switch (self) {
            .elapsed => |since| if (duration / value.seconds >= 999) null else (since +| ((duration / value.seconds +| 1) *| value.seconds)) *| 1000,
            .remaining => |until| if (duration < 60) until *| 1000 else (until -| (@min(duration / value.seconds, 999) * value.seconds - 1)) *| 1000,
        };
    }
};

const test_now_s = 1_792_937_000;

fn testState() error{OutOfMemory}!State {
    var state: State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/home/d/code/rui", .home = "/home/d" });
    _ = try step(&state, .{ .host = .{ .instance = testToken(0).instance, .started_at = test_now_s, .slots = 2, .slots_in_use = 0 } });
    return state;
}

fn testToken(generation: u64) Token {
    return .{ .instance = @splat(0xab), .generation = generation };
}

fn bounded(comptime capacity: usize, text: []const u8) Bounded(capacity) {
    return Bounded(capacity).from(text) catch unreachable;
}

const test_first: content_value.Value = .{ .text = .{ .length = 5, .digest = @splat(0xa1) } };

const TestSession = struct {
    read_version: Token = testToken(0),
    creator: ?Reference = null,
    archive_state: ArchiveState = .active,
    archive_seq: ?u64 = null,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    label: ?[]const u8 = null,
    workspace: []const u8 = "/home/d/code/rui",
    provider: Provider = pn(.codex),
    model: []const u8 = "gpt-6-luna",
    first: ?First = .{ .position = 1, .admission = 4, .sender = null, .content = test_first },
    yours: bool = false,
    turn: ?u64 = null,
    first_action: ?u64 = null,
    state_change_at: ?u64 = null,
    subtree_state_change_at: ?u64 = null,
    descendant_count: u64 = 0,
    descendant_needs_you_count: u64 = 0,
};

fn session(ref: *const [6]u8, state: WorkState, options: TestSession) Listed {
    const standing = session_work.standing(state.asOf(test_now_s * 1000), false);
    return .{
        .reference = ref.*,
        .creator = options.creator,
        .read_version = options.read_version,
        .archive_state = options.archive_state,
        .archive_seq = options.archive_seq,
        .pin_order = options.pin_order,
        .workspace = options.workspace,
        .provider = options.provider,
        .model = options.model,
        .label = options.label,
        .state = state,
        .state_change_at = options.state_change_at orelse state.since(),
        .subtree_state_change_at = options.subtree_state_change_at orelse options.state_change_at orelse state.since(),
        .descendant_count = options.descendant_count,
        .descendant_needs_you_count = options.descendant_needs_you_count,
        .turn = options.turn,
        .first_action = options.first_action,
        .actions = .{ .stop = switch (std.meta.activeTag(state)) {
            .pending, .working, .retrying, .bash, .approval => true,
            else => false,
        }, .decide = if (standing == .needs_you) options.first_action orelse 1 else null },
        .first = options.first,
        .from_person_at = if (options.yours) test_now_s - 3600 else null,
    };
}

fn fixtureWork(value: session_work.Work) session_work.Work {
    var work = value;
    work.actions.stop = switch (std.meta.activeTag(work.state)) {
        .pending, .working, .retrying, .bash, .approval => true,
        else => false,
    };
    work.actions.decide = if (session_work.standing(work.state, false) == .needs_you) work.first_action orelse 1 else null;
    return work;
}

fn ago(seconds: u64) WorkState.Since {
    return .{ .since = test_now_s - seconds };
}

fn opened(rows: []const Listed) !State {
    var state = try testState();
    errdefer state.deinit();
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), rows);
    return state;
}

/// Delivers one roster walk's pages and answer, returning the effects of its last page.
/// Delivers one roster walk's rows and answer. A since walk the Host answers in full is walked again from no
/// token: the core restarts it, and that second walk is the answer the caller sees.
fn respond(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    const restarts = state.full_restarts;
    const effects = try answerWalk(state, delta, since, rows);
    if (state.full_restarts == restarts) return effects;
    return answerWalk(state, delta, since, rows);
}

fn answerWalk(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    var at: usize = 0;
    while (true) {
        const end = @min(at + max_page_rows, rows.len);
        const last: ?Answer = if (end == rows.len) .{ .delta = delta, .since = since } else null;
        var stamped: [max_page_rows]Listed = undefined;
        for (rows[at..end], stamped[0 .. end - at]) |row, *copy| {
            copy.* = row;
            if (copy.read_version.generation == 0) copy.read_version = since;
        }
        const effects = try step(state, .{ .list = .{ .page = .{ .rows = stamped[0 .. end - at], .answer = last } } });
        if (end == rows.len) return effects;
        try std.testing.expectEqual(@as(usize, 0), effects.len);
        at = end;
    }
}

fn refresh(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    const asked = try step(state, .{ .tick = state.now_ms + list_interval_ms });
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expect(asked.items[0] == .list);
    return respond(state, delta, since, rows);
}

var test_edits: u32 = 0;

fn press(state: *State, action: Action) !Effects {
    return step(state, .{ .input = .{ .key = .{ .action = action } } });
}
fn submit(state: *State) !Effects {
    return step(state, .{ .input = .{ .key = .enter } });
}

fn expectEffects(expected: []const Effect, actual: Effects) !void {
    const effects = actual.slice();
    try std.testing.expectEqual(expected.len, effects.len);
    for (expected, effects) |want, got| {
        try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .list => |request| {
                try std.testing.expectEqual(request.since, got.list.since);
                try std.testing.expectEqual(request.archive, got.list.archive);
            },
            .read_first_lines => |reads| {
                try std.testing.expectEqual(reads.len, got.read_first_lines.len);
                for (reads.slice(), got.read_first_lines.slice()) |a, b| {
                    try std.testing.expectEqualStrings(&a.reference, &b.reference);
                    try std.testing.expectEqual(a.position, b.position);
                    try std.testing.expectEqual(a.admission, b.admission);
                }
            },
            .read_archived => |read| try std.testing.expect(std.meta.eql(read, got.read_archived)),
            .open => |ref| try std.testing.expectEqualStrings(&ref, &got.open),
            .stop => |ref| try std.testing.expectEqualStrings(&ref, &got.stop),
            .pin => |request| {
                try std.testing.expectEqualStrings(&request.reference, &got.pin.reference);
                try std.testing.expectEqual(request.pinned, got.pin.pinned);
            },
            .archive => |request| {
                try std.testing.expectEqualStrings(&request.reference, &got.archive.reference);
                try std.testing.expectEqual(request.archived, got.archive.archived);
            },
            .list_models, .cancel_upgrade, .open_settings, .focus_chat, .new_session, .exit => {},
            .create => |binding| {
                try std.testing.expectEqual(binding == null, got.create == null);
                if (binding) |expected_binding| try std.testing.expect(expected_binding.eql(&got.create.?));
            },
        }
    }
}

test "SUI-172 an attention notice starts with the sign and the other tones carry none" {
    var state = try opened(&.{session("aaaaaa", .{ .idle = ago(1) }, .{})});
    defer state.deinit();
    for (std.enums.values(Colour)) |colour| {
        state.say(colour, "Select {s}.", .{"a chat"});
        var expected: [32]u8 = undefined;
        const sign = if (colour == .attention) state_marks.attention_sign else "";
        try say_text.expect(try std.fmt.bufPrint(&expected, "{s}Select a chat.", .{sign}), state.notice.?.said());
        try std.testing.expectEqual(colour, state.notice.?.colour);
    }
}

fn expectNotice(state: *State, expected: ?[]const u8) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try say_text.expect(text, notice.said());
    } else if (state.notice) |*notice| try std.testing.expectEqualStrings("", notice.text());
}

fn expectSelected(state: *const State, expected: *const [6]u8) !void {
    try std.testing.expectEqualStrings(expected, &(if (state.selected == .session) state.selected.session else return error.TestExpectedSelection));
}

fn screenText(state: *State, width: u16, height: u16, caps: Caps) ![]u8 {
    return frameText(state, width, height, caps, 0);
}

const Frame = struct {
    arena: std.heap.ArenaAllocator,
    lines: []const []const Segment,

    list: []const []const Segment,
    caps: Caps,
    fn of(state: *State, width: u16, height: u16, caps: Caps, frame: u64) !Frame {
        try expectEffects(&.{}, try step(state, .{ .resized = .{ .width = width, .height = height } }));
        var self: Frame = .{ .arena = .init(std.testing.allocator), .lines = &.{}, .list = &.{}, .caps = caps };
        errdefer self.arena.deinit();
        const gpa = self.arena.allocator();
        const top = try headerSegments(gpa, state, width, caps);
        const list_count = Lines.count(state);
        const lines = try gpa.alloc([]const Segment, top.len + list_count + max_notice_rows + 2);
        var count: usize = 0;
        var start: usize = 0;
        for (top, 0..) |segment, at| if (std.mem.eql(u8, segment.text, "\n")) {
            lines[count] = top[start..at];
            count += 1;
            start = at + 1;
        };
        if (top.len != 0) {
            lines[count] = top[start..];
            count += 1;
        }
        const first = count;
        for (try controls(gpa, state, width, caps)) |control| {
            lines[count] = control.segments;
            count += 1;
        }
        var list_at: usize = 0;
        while (list_at < Lines.count(state)) : (list_at += 1) {
            lines[count] = ((try Lines.at(gpa, state, list_at, width, caps, frame)).?).segments;
            count += 1;
        }
        const last = count;
        if (try noticeSegments(gpa, state, width, caps)) |notice| {
            var start_: usize = 0;
            for (notice, 0..) |segment, at| if (std.mem.eql(u8, segment.text, "\n")) {
                lines[count] = notice[start_..at];
                count += 1;
                start_ = at + 1;
            };
            lines[count] = notice[start_..];
            count += 1;
        }
        self.lines = lines[0..count];
        self.list = lines[first..last];
        return self;
    }

    fn deinit(self: *Frame) void {
        self.arena.deinit();
    }

    fn text(self: *const Frame) ![]u8 {
        return textOf(self.lines);
    }

    fn textOf(lines: []const []const Segment) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer out.deinit();
        for (lines, 0..) |line, at| {
            if (at != 0) try out.writer.writeByte('\n');
            for (line) |segment| try out.writer.writeAll(segment.text);
        }
        const all = try out.toOwnedSlice();
        defer std.testing.allocator.free(all);
        var trimmed: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer trimmed.deinit();
        var rows = std.mem.splitScalar(u8, all, '\n');
        var first = true;
        while (rows.next()) |row| : (first = false) {
            if (!first) try trimmed.writer.writeByte('\n');
            try trimmed.writer.writeAll(std.mem.trimEnd(u8, row, " "));
        }
        return trimmed.toOwnedSlice();
    }

    fn styleAt(self: *Frame, row: usize, column: usize) ?Style {
        if (row >= self.lines.len) return null;
        var at: usize = 0;
        for (self.lines[row]) |segment| {
            at += gwidth.gwidth(segment.text, self.caps.width);
            if (column >= at) continue;
            const blank = std.mem.trim(u8, segment.text, " ").len == 0;
            return if (blank and std.meta.eql(segment.style, Style{})) null else segment.style;
        }
        return null;
    }
};

fn frameText(state: *State, width: u16, height: u16, caps: Caps, frame: u64) ![]u8 {
    var shown: Frame = try .of(state, width, height, caps, frame);
    defer shown.deinit();
    return shown.text();
}

fn expectScreen(state: *State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    const actual = try screenText(state, width, height, caps);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

const mixed = [_]Listed{
    session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Fix the flaky resize test", .yours = true }),
    session("h8q2mz", .{ .finished = ago(12 * 60) }, .{ .yours = true }),
    session("r4t9vw", .{ .approval = ago(3 * 60) }, .{ .label = "Review PR 412", .yours = true }),
    session("a1b2c3", .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .{ .label = "Find why store tests fail" }),
    session("b2c3d4", .{ .working = ago(2 * 60) }, .{ .label = "Profile the curl send queue" }),
    session("c3d4e5", .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 12) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .{ .label = "Audit permission paths" }),
    session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Trace Host shutdown order" }),
    session("e5f6g7", .{ .stopping = ago(8) }, .{ .label = "List unused build steps" }),
    session("f6g7h8", .{ .working = ago(90) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".*, .content = test_first } }),
    session("g7h8j9", .{ .idle = ago(2 * 3600) }, .{ .label = "Check macOS socket cleanup" }),
    session("m1n2p3", .{ .finished = ago(20 * 60) }, .{ .label = "Explain provider output parsing" }),
    session("n2p3q4", .{ .finished = ago(45 * 60) }, .{ .label = "Find the commit that broke WAL" }),
    session("p3q4r5", .{ .finished = ago(3600) }, .{}),
    session("q4r5s6", .{ .finished = ago(3 * 3600) }, .{ .label = "Summarize the build cache study" }),
    session("s6t7v8", .{ .finished = ago(2 * 86400) }, .{ .label = "Check the release notes", .workspace = "/srv/work" }),
    session("v8w9x0", .{ .finished = ago(3 * 86400) }, .{ .label = "Count flaky tests" }),
    session("w9x0y1", .{ .finished = ago(4 * 86400) }, .{ .label = "Map the CI shards" }),
    session("t7v8w9", .{ .failed = .{ .since = test_now_s - 15 * 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Bisect the WAL regression", .first = .{ .position = 1, .admission = 2, .sender = "k7m2qx".*, .content = test_first } }),
    session("x0y1z2", .{ .stopped = .{ .since = test_now_s - 30 * 60, .cause = .stop } }, .{ .label = "Rename the session tables", .first = .{ .position = 1, .admission = 3, .sender = "zzzzzz".*, .content = test_first } }),
    session("y1z2a3", .{ .failed = .{ .since = test_now_s - 50 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .label = "Retry the flaky upload" }),
};

const kind_cases = [_]struct { state: WorkState, unicode: []const u8, ascii: []const u8, colour: Colour, stoppable: bool }{
    .{ .state = .{ .idle = ago(7200) }, .unicode = " ○ Write the notes                                                           2h", .ascii = " o Write the notes                                                           2h", .colour = .normal, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .unicode = " ◌ Write the notes                                                          now", .ascii = " : Write the notes                                                          now", .colour = .quiet, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .unicode = " ◜ Write the notes", .ascii = " * Write the notes                                                      working", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .unicode = " ◝ Write the notes                                                     retrying", .ascii = " * Write the notes                                                     retrying", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .unicode = " ◜ Write the notes", .ascii = " * Write the notes                                                      working", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .unicode = " ● Write the notes                                                           3m", .ascii = " ? Write the notes                                                           3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .unicode = " ◝ Write the notes                                                     stopping", .ascii = " * Write the notes                                                     stopping", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .unicode = "   Write the notes                                                          12m", .ascii = "   Write the notes                                                          12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .unicode = " × Write the notes                                                           3h", .ascii = " x Write the notes                                                           3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .unicode = " ▪ Write the notes                                                           2d", .ascii = " # Write the notes                                                           2d", .colour = .normal, .stoppable = false },
};

fn projectionCase4() !void {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{session("k7m2qx", due, .{ .label = "Write the notes" })});
    defer state.deinit();
    state.selected = .new_session;
    const text = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "Write the notes").?;
    const start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    try std.testing.expectEqualStrings(" ◌ Write the notes                                                          now", text[start..end]);
    try std.testing.expect(std.mem.indexOf(u8, text, " Active ·") == null);
    var screen = try Frame.of(&state, 80, 24, .{ .depth = .none }, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .quiet, .dim = true }, screen.styleAt(2, 1).?);
}

fn projectionCase5() !void {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = try screenText(&state, 80, 40, .{});
    defer std.testing.allocator.free(text);
    inline for (.{ " Needs you ·", " Yours ·", " Active ·", " Idle ·", " Finished ·", " Stopped or failed ·", " more" }) |heading| try std.testing.expect(std.mem.indexOf(u8, text, heading) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ New chat") != null);
    try std.testing.expectEqual(mixed.len, Lines.count(&state));
}

fn expectOrder(state: *const State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.order.items.len);
    for (expected, state.order.items) |label, index| try std.testing.expectEqualStrings(label, state.rows.items[index].label.?.slice());
}

test "SUI-100 creator tree uses served subtree facts and disjoint nested pins" {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(80) }, .{ .label = "Root", .subtree_state_change_at = test_now_s - 1, .descendant_count = 4294967300, .descendant_needs_you_count = 4 }),
        session("b4n8wd", .{ .approval = ago(20) }, .{ .label = "Pinned", .creator = "a1b2c3".*, .pin_order = 9, .descendant_count = 3, .descendant_needs_you_count = 2 }),
        session("c3d4e5", .{ .approval = ago(10) }, .{ .label = "Nested pin", .creator = "b4n8wd".*, .pin_order = 8, .descendant_count = 1, .descendant_needs_you_count = 1 }),
        session("d4e5f6", .{ .finished = ago(2) }, .{ .label = "Other root" }),
    });
    defer state.deinit();
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = "b4n8wd".* } } });
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = "a1b2c3".* } } });
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    const text = try screenText(&state, 140, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Pinned ▸ 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 4294967296 · 1 ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root").? < std.mem.indexOf(u8, text, "Other root").?);
    try creatorSnapshotCase();
    try creatorPagesCase();
    try creatorFilteredCase();
    try creatorEmptyCase();
    try creatorEdgesCase();
    try creatorClockCase();
    try creatorPinsCase();
    try creatorRootOrderCase();
    try creatorSenderOrderCase();
    try creatorQueuedOrderCase();
}

test "SUI-21 opening a Session records its outcome as seen from the work state alone" {
    var state = try opened(&.{session("b4n8wd", .{ .idle = ago(20) }, .{ .label = "Pinned" })});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = "b4n8wd".* });
    // The finished state is what the person opened and saw.
    const work: session_work.Work = .{ .state = .{ .finished = ago(1) }, .turn = 2 };
    _ = try step(&state, .{ .observed = .{ .reference = "b4n8wd".*, .read_version = testToken(3), .work = work, .opening = true } });
    const seen = (try state.record("b4n8wd".*)).acknowledged.?;
    try std.testing.expectEqual(session_work.attention(work).?, seen);
    // A state that asks nothing records nothing, as before.
    var quiet = try opened(&.{session("c5d9xe", .{ .idle = ago(20) }, .{ .label = "Quiet" })});
    defer quiet.deinit();
    _ = try step(&quiet, .{ .conversation = "c5d9xe".* });
    _ = try step(&quiet, .{ .observed = .{ .reference = "c5d9xe".*, .read_version = testToken(3), .work = fixtureWork(.{ .state = .{ .working = ago(1) } }), .opening = true } });
    try std.testing.expectEqual(@as(?attention.Attention, null), (try quiet.record("c5d9xe".*)).acknowledged);
}

fn creatorSnapshotCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(20) }, .{ .label = "Root", .subtree_state_change_at = test_now_s - 1, .descendant_count = 3, .descendant_needs_you_count = 2 }),
        session("b4n8wd", .{ .approval = ago(10) }, .{ .label = "Pinned", .creator = "a1b2c3".*, .pin_order = 7, .descendant_count = 1, .descendant_needs_you_count = 1 }),
    });
    defer state.deinit();
    _ = try step(&state, .{ .conversation = "b4n8wd".* });
    _ = try step(&state, .{ .observed = .{ .reference = "b4n8wd".*, .read_version = testToken(3), .work = fixtureWork(.{ .state = .{ .working = ago(1) } }), .opening = false } });
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = "a1b2c3".* } } });
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    const text = try screenText(&state, 140, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 1 ·") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "◝ Pinned") != null);
}

fn creatorPagesCase() !void {
    var root = session("a1b2c3", .{ .working = ago(10) }, .{ .label = "Root", .descendant_count = 1 });
    var state = try opened(&.{root});
    defer state.deinit();
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = root.reference } } });
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    root.read_version = testToken(2);
    root.descendant_count = 2;
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{root}, .answer = null } } });
    var text = try screenText(&state, 140, 24, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 1") != null);
    std.testing.allocator.free(text);
    root.descendant_count = 3;
    root.descendant_needs_you_count = 1;
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{root}, .restarts = true, .answer = null } } });
    text = try screenText(&state, 140, 24, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 1") != null);
    std.testing.allocator.free(text);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{}, .answer = .{ .delta = .changed, .since = testToken(2) } } } });
    text = try screenText(&state, 140, 24, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 3 · 1 ?") != null);
    std.testing.allocator.free(text);
    root.read_version = testToken(1);
    root.descendant_count = 7;
    _ = try refresh(&state, .changed, testToken(3), &.{root});
    text = try screenText(&state, 140, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root ▸ 3 · 1 ?") != null);
}

test "SUI-101 creator tree folding and expansion" {
    try creatorFoldCase();
    try creatorClickCase();
    try creatorHiddenOpenCase();
}

test "SUI-102 creator tree order hold and release" {
    try creatorPointerHoldCase();
    try creatorKeyHoldCase();
    try creatorKeyOriginCase();
    try creatorPresentationCase();
    try creatorFlashDeadlineCase();
}

test "SUI-103 creator tree attention representatives" {
    try creatorAttentionCase();
    try creatorEdgeCase();
}

test "SUI-104 creator tree width and badges" {
    try creatorWidthCase();
    try creatorActivityWidthCase();
    try creatorSidebarCase();
}

fn creatorFilteredCase() !void {
    const root = session("a1b2c3", .{ .finished = ago(10) }, .{ .label = "Root" });
    const middle = session("b4n8wd", .{ .finished = ago(5) }, .{ .label = "Archived middle", .creator = "a1b2c3".*, .archive_state = .archived, .archive_seq = 5 });
    const leaf = session("c3d4e5", .{ .finished = ago(1) }, .{ .label = "Leaf", .creator = "b4n8wd".* });
    var state = try opened(&.{ root, middle, leaf });
    defer state.deinit();
    var text = try screenText(&state, 140, 24, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "Leaf").? < std.mem.indexOf(u8, text, "Root").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Archived middle") == null);
    std.testing.allocator.free(text);
    // The Archived view reads its rows from the window; the roster (root, leaf) is never listed for it.
    const switched = try step(&state, .{ .clicked = .{ .target = .archived } });
    try serveWindow(&state, &.{middle}, switched);
    text = try screenText(&state, 140, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Archived middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Leaf") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Root") == null);
}

fn creatorEmptyCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .idle = ago(10) }, .{ .first = null, .label = "Human root", .subtree_state_change_at = test_now_s - 1, .descendant_count = 1 }),
        session("b4n8wd", .{ .idle = ago(1) }, .{ .first = null, .label = "Agent", .creator = "a1b2c3".* }),
        session("c3d4e5", .{ .idle = ago(5) }, .{ .first = null, .label = "Other empty" }),
    });
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 2), Lines.count(&state));
    const first = (try Lines.at(arena.allocator(), &state, 0, 140, .{}, 0)).?;
    const second = (try Lines.at(arena.allocator(), &state, 1, 140, .{}, 0)).?;
    try std.testing.expect(first.target.? == .open);
    try std.testing.expectEqualStrings("a1b2c3", &first.target.?.open);
    try std.testing.expect(second.target.? == .open);
    try std.testing.expectEqualStrings("b4n8wd", &second.target.?.open);
}

fn creatorEdgesCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .finished = ago(80) }, .{ .label = "A", .subtree_state_change_at = test_now_s - 1, .descendant_count = 1 }),
        session("b4n8wd", .{ .finished = ago(20) }, .{ .label = "B", .subtree_state_change_at = test_now_s - 10, .descendant_count = 1 }),
        session("c3d4e5", .{ .working = ago(1) }, .{ .label = "A child", .creator = "a1b2c3".* }),
        session("d4e5f6", .{ .finished = ago(10) }, .{ .label = "B child", .creator = "b4n8wd".* }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{ "A", "A child", "B", "B child" });
}

fn creatorFoldCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(10) }, .{ .label = "A", .descendant_count = 1, .descendant_needs_you_count = 1 }),
        session("b4n8wd", .{ .approval = ago(1) }, .{ .label = "Child", .creator = "a1b2c3".* }),
    });
    defer state.deinit();
    state.selected = .{ .session = "a1b2c3".* };
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    try expectOrder(&state, &.{"A"});
    const right_effects = try press(&state, .open_session);
    try expectEffects(&.{ .{ .open = "a1b2c3".* }, .list_models }, right_effects);
    try expectOrder(&state, &.{"A"});
    try expectEffects(&.{}, try press(&state, .expand_tree));
    try expectOrder(&state, &.{ "A", "Child" });
}

fn creatorClickCase() !void {
    const parent: Reference = "a1b2c3".*;
    const child: Reference = "b4n8wd".*;
    const target: Click = .{ .open = parent };
    const press_parent = Event{ .clicked = .{ .target = target, .at_ms = 100 } };
    const release_parent = Event{ .pointer = .{ .phase = .released, .over = target } };
    const last_before_deadline = 100 + ParentClick.interval_ms - 1;
    const deadline = last_before_deadline + 1;
    for ([_]bool{ false, true }) |wide| for (std.enums.values(enum { single, double, childless, focus_left, drag, ignored, paste, navigation, held_single, held_paste, late_drag, release_elsewhere })) |gesture| {
        var state = try opened(&.{
            session(&parent, .{ .working = ago(10) }, .{ .label = "Parent", .descendant_count = 1 }),
            session(&child, .{ .finished = ago(1) }, .{ .label = "Child", .creator = parent }),
        });
        defer state.deinit();
        if (gesture == .childless) {
            try expectEffects(&.{ .{ .open = child }, .list_models }, try step(&state, .{ .clicked = .{ .target = .{ .open = child }, .at_ms = 100 } }));
            continue;
        }
        try expectEffects(&.{}, try step(&state, press_parent));
        try expectOrder(&state, &.{ "Parent", "Child" });
        const after_deadline: Event = .{ .list_settled = .{ .wide = wide, .focused = true, .click_clock_ms = deadline + 1 } };
        switch (gesture) {
            .held_single, .held_paste, .late_drag, .release_elsewhere => {
                try expectEffects(&.{}, try step(&state, after_deadline));
                switch (gesture) {
                    .held_single, .held_paste => {
                        const ignored = if (gesture == .held_paste) InputDelivery{ .key = .enter, .pasted = true } else InputDelivery{ .key = .ignored };
                        try expectEffects(&.{}, try step(&state, .{ .input = ignored }));
                        try expectEffects(&.{}, try step(&state, release_parent));
                        try expectEffects(&.{ .{ .open = parent }, .list_models }, try step(&state, after_deadline));
                    },
                    .late_drag => {
                        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .phase = .held, .over = .archived } }));
                        try expectEffects(&.{.{ .archive = .{ .reference = parent, .archived = true } }}, try step(&state, .{ .pointer = .{ .phase = .released, .over = .archived } }));
                    },
                    .release_elsewhere => try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .phase = .free, .over = null } })),
                    else => unreachable,
                }
                try expectEffects(&.{}, try step(&state, after_deadline));
                continue;
            },
            else => {},
        }
        if (gesture == .drag) {
            _ = try step(&state, .{ .pointer = .{ .phase = .held, .over = .archived } });
        } else {
            try expectEffects(&.{}, try step(&state, release_parent));
        }
        switch (gesture) {
            .ignored => try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .ignored } })),
            .paste => try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter, .pasted = true } })),
            .navigation => try expectEffects(&.{}, try press(&state, .select_next)),
            else => {},
        }
        try expectEffects(&.{}, try step(&state, .{ .list_settled = .{ .wide = wide, .focused = gesture != .focus_left, .click_clock_ms = last_before_deadline } }));
        if (gesture == .double) {
            try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = target, .at_ms = last_before_deadline } }));
            try expectOrder(&state, &.{"Parent"});
            try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = target, .at_ms = deadline } }));
            try expectEffects(&.{}, try step(&state, release_parent));
            try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = target, .at_ms = deadline + 1 } }));
            try expectOrder(&state, &.{ "Parent", "Child" });
        }
        if (gesture == .paste) try expectEffects(&.{}, try step(&state, .{ .list_settled = .{ .wide = wide, .focused = true } }));
        const settled = try step(&state, .{ .list_settled = .{ .wide = wide, .focused = true, .click_clock_ms = deadline + 1 } });
        const open_parent = gesture == .single or gesture == .ignored or gesture == .paste;
        try expectEffects(if (open_parent) &.{ .{ .open = parent }, .list_models } else &.{}, settled);
    };
}

fn creatorHiddenOpenCase() !void {
    // An open or selected Session folded away takes its collapsed ancestor's place.
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(10) }, .{ .label = "A", .subtree_state_change_at = test_now_s - 1, .descendant_count = 1 }),
        session("b4n8wd", .{ .finished = ago(1) }, .{ .label = "Child", .creator = "a1b2c3".* }),
        session("c3d4e5", .{ .finished = ago(30) }, .{ .label = "B" }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{ "A", "Child", "B" });
    state.selected = .{ .session = "a1b2c3".* };
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    try expectOrder(&state, &.{ "A", "B" });
    _ = try step(&state, .{ .conversation = "b4n8wd".* });
    state.selected = .{ .session = "b4n8wd".* };
    try expectOrder(&state, &.{ "A", "B" });
    const a_line = Lines.lineOf(&state, 0);
    try std.testing.expectEqual(@as(?usize, a_line), Lines.named(&state));
    try std.testing.expectEqual(@as(?usize, a_line), Lines.highlighted(&state, true));
    try std.testing.expectEqual(@as(?usize, a_line), lineOfReference(&state, "b4n8wd".*));
    const effects = try press(&state, .next_session);
    try std.testing.expectEqualStrings("c3d4e5", &state.selected.session);
    var opens: usize = 0;
    for (effects.slice()) |effect| if (effect == .open) {
        opens += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), opens);
}

fn creatorPointerHoldCase() !void {
    const a = session("a1b2c3", .{ .working = ago(20) }, .{ .label = "A" });
    var b = session("b4n8wd", .{ .working = ago(30) }, .{ .label = "B" });
    var state = try opened(&.{ a, b });
    defer state.deinit();
    _ = try step(&state, .{ .list_presence = .{ .at_ms = state.now_ms, .pointer_over = true } });
    b.state = .{ .approval = ago(1) };
    b.state_change_at = test_now_s - 1;
    b.subtree_state_change_at = test_now_s - 1;
    const c = session("c3d4e5", .{ .finished = ago(2) }, .{ .label = "C" });
    _ = try refresh(&state, .changed, testToken(2), &.{ b, c });
    try expectOrder(&state, &.{ "A", "B", "C" });
    try std.testing.expect(holding(&state));
    _ = try step(&state, .{ .list_presence = .{ .at_ms = state.now_ms, .pointer_over = false } });
    try expectOrder(&state, &.{ "B", "C", "A" });
    try std.testing.expect(state.find("a1b2c3".*).?.flash_until_ms > state.now_ms);
    try std.testing.expectEqual(@as(u64, 0), state.find("c3d4e5".*).?.flash_until_ms);
    const flash = state.find("a1b2c3".*).?.flash_until_ms;
    _ = try step(&state, .{ .tick = flash });
    try std.testing.expectEqual(@as(u64, 0), state.find("a1b2c3".*).?.flash_until_ms);
}

fn creatorKeyHoldCase() !void {
    const a = session("a1b2c3", .{ .working = ago(20) }, .{ .label = "A" });
    var b = session("b4n8wd", .{ .working = ago(30) }, .{ .label = "B" });
    var state = try opened(&.{ a, b });
    defer state.deinit();
    const start = state.now_ms;
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .next }, .at_ms = start } });
    b.state_change_at = test_now_s - 1;
    b.subtree_state_change_at = test_now_s - 1;
    _ = try refresh(&state, .changed, testToken(2), &.{b});
    _ = try step(&state, .{ .tick = start + 2999 });
    try expectOrder(&state, &.{ "A", "B" });
    const held = state.presentation_revision;
    _ = try step(&state, .{ .tick = start + 3000 });
    try expectOrder(&state, &.{ "B", "A" });
    // A release that moves rows repaints; one that moves nothing does not (creatorPresentationCase).
    try std.testing.expect(state.presentation_revision != held);
}

fn creatorKeyOriginCase() !void {
    for ([_]Action{ .previous_session, .next_session, .next_question }) |action| {
        for ([_]bool{ false, true }) |origin| {
            var state = try opened(&.{});
            defer state.deinit();
            _ = try step(&state, .{ .input = .{ .key = .{ .action = action }, .list_origin = origin, .at_ms = state.now_ms } });
            try std.testing.expectEqual(origin, holding(&state));
        }
    }
}

fn creatorClockCase() !void {
    const a = session("a1b2c3", .{ .working = ago(20) }, .{ .label = "A", .state_change_at = test_now_s - 20 });
    var b = session("b4n8wd", .{ .working = ago(30) }, .{ .label = "B", .state_change_at = test_now_s - 30 });
    var state = try opened(&.{ a, b });
    defer state.deinit();
    b.state = .{ .bash = .{ .since = test_now_s - 1, .call = 1, .description = null, .running = 1, .approvals = 0 } };
    _ = try refresh(&state, .changed, testToken(2), &.{b});
    try expectOrder(&state, &.{ "A", "B" });
}

test "SUI-169 a decision waiting on a Session that is not in an approval state counts as needing the person in every overview reader" {
    var waiting = session("a1b2c3", .{ .finished = ago(5) }, .{ .label = "Waiting" });
    waiting.actions.decide = 7;
    const quiet = session("b4n8wd", .{ .finished = ago(5) }, .{ .label = "Done" });
    var state = try opened(&.{ waiting, quiet });
    defer state.deinit();
    const row = state.find("a1b2c3".*).?;
    // The folded-parent count reads the same rule as the Store's roll-up, at list time.
    try std.testing.expect(row.list_needs_you);
    try std.testing.expect(!state.find("b4n8wd".*).?.list_needs_you);
    try std.testing.expectEqual(session_work.Standing.needs_you, classOf(&state, row).standing);
    try std.testing.expectEqual(session_work.Standing.done, classOf(&state, state.find("b4n8wd".*).?).standing);
    try std.testing.expectEqual(@as(usize, 1), state.summary.counts.needs_you);
}

fn creatorAttentionCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(5) }, .{ .label = "Parent", .subtree_state_change_at = test_now_s - 1, .descendant_count = 2, .descendant_needs_you_count = 1 }),
        session("b4n8wd", .{ .approval = ago(1) }, .{ .label = "Question", .creator = "a1b2c3".* }),
        session("c3d4e5", .{ .failed = .{ .since = test_now_s - 2, .code = .{}, .resets_at = null } }, .{ .label = "Failure", .creator = "a1b2c3".* }),
    });
    defer state.deinit();
    state.selected = .{ .session = "a1b2c3".* };
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    const index = lookup(state.by_reference.items, "a1b2c3".*).?;
    try std.testing.expectEqual(@as(u64, 2), state.nodes.items[index].descendants);
    try std.testing.expectEqual(@as(u64, 1), state.nodes.items[index].attention);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try segmentText(arena.allocator(), try rowSegments(arena.allocator(), &state, 0, 46, .{}, 0));
    try std.testing.expect(std.mem.indexOf(u8, text, "▸ 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "· 1 ?") != null);
}

fn creatorPinsCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(10) }, .{ .label = "Parent" }),
        session("b4n8wd", .{ .working = ago(5) }, .{ .label = "Pinned child", .creator = "a1b2c3".*, .pin_order = 7 }),
        session("c3d4e5", .{ .working = ago(1) }, .{ .label = "Pin descendant", .creator = "b4n8wd".* }),
        session("d4e5f6", .{ .working = ago(2) }, .{ .label = "Orphan", .creator = "h8q2mz".* }),
    });
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 2), state.pin_end);
    try expectOrder(&state, &.{ "Pinned child", "Pin descendant", "Orphan", "Parent" });
}

fn creatorEdgeCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(5) }, .{ .label = "Parent", .descendant_count = 2, .descendant_needs_you_count = 2 }),
        session("b4n8wd", .{ .approval = ago(1) }, .{ .label = "Question", .creator = "a1b2c3".* }),
        session("c3d4e5", .{ .approval = ago(2) }, .{ .label = "Another question", .creator = "a1b2c3".* }),
        session("d4e5f6", .{ .working = ago(20) }, .{ .label = "Other" }),
    });
    defer state.deinit();
    state.selected = .{ .session = "a1b2c3".* };
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
    try std.testing.expectEqual(@as(usize, 0), edgeAttention(&state, .below, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), edgeAttention(&state, .above, 1, 2));
}

fn creatorRootOrderCase() !void {
    var state = try opened(&.{
        session("a1b2c3", .{ .approval = ago(60) }, .{ .label = "Older question" }),
        session("b4n8wd", .{ .finished = ago(5) }, .{ .label = "Newer finished" }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{ "Newer finished", "Older question" });
}

fn creatorSenderOrderCase() !void {
    const beside_bash: WorkState = .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 1 } };
    const running_bash: WorkState = .{ .bash = .{ .since = test_now_s - 20, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the store tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{
        session("y0urs1", .{ .working = ago(40) }, .{ .label = "Mine, thinking", .yours = true }),
        session("y0urs2", .{ .approval = ago(9) }, .{ .label = "Mine, asking", .yours = true }),
        session("a5k1ng", .{ .approval = ago(5) }, .{ .label = "Theirs, asking" }),
        session("b4sh01", beside_bash, .{ .label = "Theirs, asking beside Bash" }),
        session("b4sh02", running_bash, .{ .label = "Theirs, running Bash" }),
        session("f1n1sh", .{ .finished = ago(60) }, .{ .label = "Theirs, finished" }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{ "Theirs, asking", "Mine, asking", "Theirs, running Bash", "Mine, thinking", "Theirs, asking beside Bash", "Theirs, finished" });
    try std.testing.expectEqualStrings("a5k1ng", &state.selected.session);
}

fn creatorQueuedOrderCase() !void {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    const later: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 18) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{
        session("q00010", .{ .pending = ago(10) }, .{ .label = "Queued 10s" }),
        session("w00040", .{ .working = ago(40) }, .{ .label = "Working 40s" }),
        session("q00040", .{ .pending = ago(40) }, .{ .label = "Queued 40s" }),
        session("r3try0", later, .{ .label = "Retrying in 18s" }),
        session("d0e000", due, .{ .label = "Retry due" }),
        session("q00025", .{ .pending = ago(25) }, .{ .label = "Queued 25s" }),
        session("s70p00", .{ .stopping = ago(50) }, .{ .label = "Stopping 50s" }),
        session("y0q070", .{ .pending = ago(70) }, .{ .label = "Mine, queued 70s", .yours = true }),
        session("y0w050", .{ .working = ago(50) }, .{ .label = "Mine, working 50s", .yours = true }),
        session("y0f005", .{ .finished = ago(5) }, .{ .label = "Mine, finished 5s", .yours = true }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{ "Mine, finished 5s", "Queued 10s", "Queued 25s", "Retry due", "Retrying in 18s", "Queued 40s", "Working 40s", "Stopping 50s", "Mine, working 50s", "Mine, queued 70s" });
}

test "the summary counts row marks: needs you, working, queued and failed" {
    const beside_bash: WorkState = .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = null, .running = 1, .approvals = 2 } };
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    const later: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 18) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{
        session("a5k1ng", .{ .approval = ago(5) }, .{ .label = "Asking", .yours = true }),
        session("b4sh01", beside_bash, .{ .label = "Asking beside Bash" }),
        session("w00001", .{ .working = ago(40) }, .{ .label = "Working", .yours = true }),
        session("r3try0", later, .{ .label = "Retrying" }),
        session("s70p00", .{ .stopping = ago(8) }, .{ .label = "Stopping" }),
        session("q00001", .{ .pending = ago(10) }, .{ .label = "Queued" }),
        session("q00002", .{ .pending = ago(20) }, .{ .label = "Mine, queued", .yours = true }),
        session("d0e000", due, .{ .label = "Retry due" }),
        failedRow("f4iled", 60, "provider_output_invalid", null),
        session("s70pd0", .{ .stopped = .{ .since = test_now_s - 90, .cause = .stop } }, .{ .label = "Stopped" }),
        session("f1n1sh", .{ .finished = ago(60) }, .{ .label = "Finished" }),
        session("1d1e00", .{ .idle = ago(600) }, .{ .label = "Idle" }),
    });
    defer state.deinit();
    try std.testing.expectEqual(Counts{ .needs_you = 2, .working = 3, .queued = 3, .failed = 1 }, state.summary.counts);
}

fn rowOf(arena: Allocator, state: *State, label: []const u8, width: u16, caps: Caps) ![]const Segment {
    const selected = state.selected;
    state.selected = .new_session;
    defer state.selected = selected;
    for (state.order.items, 0..) |index, at| {
        const row = &state.rows.items[index];
        if (row.label != null and std.mem.eql(u8, row.label.?.slice(), label)) return (try Lines.at(arena, state, Lines.lineOf(state, at), width, caps, 0)).?.segments;
    }
    return error.TestUnexpectedResult;
}

fn expectRow(segments: []const Segment, width: u16, expected: []const struct { []const u8, Colour }) !void {
    var said: usize = 0;
    var cells: usize = 0;
    for (segments) |segment| {
        for (segment.text) |byte| cells += @intFromBool(byte & 0xc0 != 0x80);
        const text = std.mem.trim(u8, segment.text, " ");
        if (text.len == 0) continue;
        try std.testing.expect(said < expected.len);
        try std.testing.expectEqualStrings(expected[said][0], text);
        try std.testing.expectEqual(expected[said][1], segment.style.colour);
        said += 1;
    }
    try std.testing.expectEqual(expected.len, said);
    try std.testing.expectEqual(@as(usize, width), cells);
}

fn styleOf(segments: []const Segment, needle: []const u8) !Style {
    for (segments) |segment| if (std.mem.indexOf(u8, segment.text, needle) != null) return segment.style;
    return error.TestUnexpectedResult;
}

fn expectLine(segments: []const Segment, width: u16, expected: []const []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    var cells: usize = 0;
    for (segments) |segment| {
        cells += measured(.{}, unicode_glyphs, segment.text);
        try line.writer.writeAll(segment.text);
    }
    var said: usize = 0;
    var pieces = std.mem.tokenizeSequence(u8, line.written(), "  ");
    while (pieces.next()) |piece| {
        const text = std.mem.trim(u8, piece, " ");
        if (text.len == 0) continue;
        try std.testing.expect(said < expected.len);
        try std.testing.expectEqualStrings(expected[said], text);
        said += 1;
    }
    try std.testing.expectEqual(expected.len, said);
    try std.testing.expectEqual(@as(usize, width), cells);
}

test "App header preserves provider recovery without a counts or Host-stopped band" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var state = try opened(&.{failedRow("aaaaaa", 60, "provider_http_401", null)});
    defer state.deinit();
    state.list_stale = true;
    const segments = try headerSegments(arena.allocator(), &state, 100, .{});
    try std.testing.expectEqual(Background.band, (try styleOf(segments, "Sign-in expired. Run ")).background);
    const text = try segmentText(arena.allocator(), segments);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host stopped") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, text, "\n"));
}

test "the band names the provider of the newest sign-in or key failure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]Listed{
        session("aaaaaa", .{ .failed = .{ .since = test_now_s - 90, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .provider = pn(.codex) }),
        session("bbbbbb", .{ .failed = .{ .since = test_now_s - 30, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .provider = pn(.chatgpt) }),
    };
    for ([_]struct { []const Listed, []const u8 }{
        .{ &rows, "Sign-in expired. Run rui auth login chatgpt." },
        .{ rows[0..1], "Sign-in expired. Run rui auth login chatgpt --device-code." },
        .{ &.{session("cccccc", .{ .failed = .{ .since = test_now_s - 60, .code = bounded(session_work.max_code_bytes, failure_class.api_key_rejected), .resets_at = null } }, .{ .provider = pn(.openai) })}, "OpenAI API key rejected. Run rui auth login openai, then rui host pause." },
    }) |case| {
        var state = try opened(case[0]);
        defer state.deinit();
        const text = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, 200, .{}));
        try std.testing.expect(std.mem.indexOf(u8, text, case[1]) != null);
    }
    var state = try opened(&rows);
    defer state.deinit();
    const narrow = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, 40, .{}));
    try std.testing.expectEqualStrings("ChatGPT sign-in expired.", std.mem.trim(u8, narrow, " "));
    var device = try opened(rows[0..1]);
    defer device.deinit();
    const sixty = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &device, 60, .{}));
    try std.testing.expectEqualStrings("Sign-in expired. Run rui auth login chatgpt --device-code.", std.mem.trim(u8, sixty, " "));
    const forty = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &device, 40, .{}));
    try std.testing.expectEqualStrings("ChatGPT (device code) sign-in expired.", std.mem.trim(u8, forty, " "));
}

const spinning = [_]Listed{
    session("y0urs1", .{ .working = ago(40) }, .{ .label = "Mine, thinking", .yours = true }),
    session("y0urs2", .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .{ .label = "Mine, running", .yours = true }),
    session("y0urs3", .{ .approval = ago(2) }, .{ .label = "Mine, asking", .yours = true }),
    session("y0urs4", .{ .pending = ago(3) }, .{ .label = "Mine, queued", .yours = true }),
    session("y0urs5", .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 60) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .{ .label = "Mine, retrying", .yours = true }),
    session("y0urs6", .{ .stopping = ago(4) }, .{ .label = "Mine, stopping", .yours = true }),
    session("w0rk00", .{ .working = ago(0) }, .{ .label = "Theirs, thinking" }),
    session("f1n1sh", .{ .finished = ago(1) }, .{ .label = "Theirs, finished" }),
};

fn markOf(text: []const u8, label: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, label).?;
    const line = text[if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |newline| newline + 1 else 0..at];
    return std.mem.trim(u8, line, " ");
}

fn anySpins(state: *const State, caps: Caps) bool {
    var line: usize = 0;
    while (line < Lines.count(state)) : (line += 1) if (Lines.spins(state, line, caps)) return true;
    return false;
}

test "OVM-5 a working row spins while live, and every other active row holds its word" {
    const caps_domain = [_]Caps{ .{}, .{ .depth = .none }, .{ .unicode = false } };
    for (kind_cases) |case| for ([_]bool{ false, true }) |is_yours| for ([_]bool{ false, true }) |stale| for (caps_domain) |caps| {
        var state = try opened(&.{session("aaaaaa", case.state, .{ .label = "Write the notes", .yours = is_yours })});
        defer state.deinit();
        state.list_stale = stale;
        const kind = classOf(&state, &state.rows.items[0]).kind;
        const held_word: ?[]const u8 = switch (kind) {
            .working, .bash => "working",
            .retrying => "retrying",
            .stopping => "stopping",
            else => null,
        };
        const live = !stale and caps.unicode and caps.depth != .none;
        const want: Activity = if (held_word) |word| blk: {
            if (live and (kind == .working or kind == .bash)) break :blk .spin;
            break :blk .{ .held = word };
        } else .none;
        const got = rowActivity(&state, 0, caps);
        try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        if (want == .held) try std.testing.expectEqualStrings(want.held, got.held);

        const frame: u64 = 3;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const row = (try Lines.at(arena.allocator(), &state, 0, 80, caps, frame)).?;
        const text = try segmentText(arena.allocator(), row.segments);
        const mark = marks.get(kind.sign());
        const glyph: []const u8 = switch (want) {
            .spin => spinner[frame % spinner.len],
            .held, .none => if (caps.unicode) mark.unicode else mark.ascii,
        };
        const name_at = std.mem.indexOf(u8, text, "Write the notes").?;
        try std.testing.expectEqualStrings(std.mem.trim(u8, glyph, " "), std.mem.trim(u8, text[0..name_at], " "));
        const ending = std.mem.trimEnd(u8, text, " ");
        switch (want) {
            .spin => try std.testing.expect(std.mem.endsWith(u8, ending, "Write the notes")),
            .held => |word| {
                try std.testing.expect(std.mem.endsWith(u8, ending, word));
                try std.testing.expectEqual(Colour.quiet, (try styleOf(row.segments, word)).colour);
            },
            .none => {
                var buffer: [8]u8 = undefined;
                const age = (Age{ .elapsed = shownSince(&state, &state.rows.items[0]) }).text(&buffer, state.now_ms);
                try std.testing.expect(std.mem.endsWith(u8, ending, age));
            },
        }
        try std.testing.expectEqual(want == .spin, row.spins);
        try std.testing.expectEqual(want == .spin, Lines.spins(&state, 0, caps));

        const awake_ms: u64 = 1000;
        const deadline = nextRedrawAt(&state, .{ .end = 1 }, caps, awake_ms);
        switch (want) {
            .spin => try std.testing.expectEqual(@as(?u64, awake_ms + (spin_interval_ms - awake_ms % spin_interval_ms)), deadline),
            .held => try std.testing.expectEqual(@as(?u64, null), deadline),
            .none => {},
        }
    };
}

test "OVM-4 stop gestures follow the work state" {
    for (kind_cases) |case| for ([_]bool{ false, true }) |served_stop| {
        const rule = rules.get(case.state);
        try std.testing.expectEqual(case.state.progress() == null, rule.word != null);
        var listed = session("k7m2qx", case.state, .{ .label = "Write the notes" });
        listed.actions.stop = served_stop;
        var state = try opened(&.{listed});
        defer state.deinit();
        if (!served_stop) {
            try expectEffects(&.{}, try press(&state, .stop));
            var buffer: [64]u8 = undefined;
            const expected = if (rules.get(case.state).word) |said| try std.fmt.bufPrint(&buffer, "k7m2qx is already {s}.", .{said}) else if (case.state == .stopping) "k7m2qx: Stopping" else "k7m2qx cannot be stopped now.";
            try expectNotice(&state, expected);
            continue;
        }
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .stop));
        try expectNotice(&state, null);
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqual(Kind.stopping, classOf(&state, state.find("k7m2qx".*).?).kind);
        try std.testing.expect(std.mem.indexOf(u8, text, "ctrl+x yes") == null);
        try expectEffects(&.{}, try press(&state, .stop));
        try expectNotice(&state, "k7m2qx: Stopping");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    };
}

fn expectSaid(notice: ?[]const u8, stoppable_: bool, said: Said) !void {
    try std.testing.expectEqualStrings(notice orelse "", if (said.notice) |shown| shown.words else "");
    try std.testing.expectEqual(notice == null, said.notice == null);
    try std.testing.expectEqual(stoppable_, said.stoppable);
}

test "conversation footer domain carries chat notices but never upgrade status" {
    var state = try testState();
    defer state.deinit();
    const version: upgrade_status.Version = .{ .schema = 60, .patch = 0 };
    const endings = [_]upgrade_status.Ended{
        .{ .up_to_date = version },    .{ .superseded = version }, .cancelled,
        .{ .refused = .source_build }, .{ .failed = .download },   .{ .upgraded = .{ .version = version, .restarted = true } },
        .{ .incompatible = version },
    };
    const runs = [_]?upgrade_status.Run{
        null,                                                                    .checking,                                                                .cancelling,
        .{ .installing = .{ .found = .{ .host = .none }, .step = .preparing } }, .{ .installing = .{ .found = .{ .host = .none }, .step = .publishing } }, .{ .installing = .{ .found = .{ .host = .none }, .step = .restarting } },
    };
    for ([_]?upgrade_status.Version{ null, version }) |available| for (runs) |run| for ([_]bool{ false, true }) |notice| {
        state.upgrade.available = available;
        state.upgrade.run = run;
        state.notice = null;
        if (notice) state.say(.normal, "Copied 3 lines", .{});
        const said = conversation(&state, "k7m2qx".*, true);
        try std.testing.expectEqualStrings(if (notice) "Copied 3 lines" else "", if (said.notice) |shown| shown.words else "");
    };
    for (endings) |how| for (std.enums.values(upgrade_status.Outcome)) |outcome| {
        state.notice = null;
        state.upgrade.run = .checking;
        _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = how, .outcome = outcome } } });
        const said = conversation(&state, "k7m2qx".*, false);
        try std.testing.expect(said.notice == null);
        try std.testing.expect(!said.stoppable);
    };
}

fn stopCase1() !void {
    var state = try testState();
    defer state.deinit();
    const ref = "k7m2qx".*;
    const ctrl_x: Conversed = .{ .reference = ref, .work = .working, .input = .{ .stop = true } };
    try expectSaid(null, true, conversation(&state, ref, true));
    try expectEffects(&.{.{ .stop = ref }}, try step(&state, .{ .conversed = ctrl_x }));
    try std.testing.expect(!conversation(&state, ref, true).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectNotice(&state, "k7m2qx: Stopping");
    try expectSaid("k7m2qx: Stopping", false, conversation(&state, ref, true));
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .other } }));
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNotice(&state, "! k7m2qx not stopped: session_not_found");
    try std.testing.expect(conversation(&state, ref, true).stoppable and !conversation(&state, ref, false).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .finished, .input = .{ .stop = false } } }));
    try expectNotice(&state, "k7m2qx is already finished.");
}

const read_order_states = [_]WorkState{
    .{ .idle = ago(10) },                                                                                                                                                              .{ .pending = ago(10) },                                                                                  .{ .working = ago(10) },
    .{ .retrying = .{ .since = test_now_s - 10, .due_at_ms = (test_now_s + 60) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 1 } }, .{ .bash = .{ .since = test_now_s - 10, .call = 1, .description = null, .running = 1, .approvals = 0 } }, .{ .approval = ago(10) },
    .{ .stopping = ago(10) },                                                                                                                                                          .{ .finished = ago(10) },                                                                                 .{ .failed = .{ .since = test_now_s - 10, .code = bounded(session_work.max_code_bytes, "malformed_provider_output"), .resets_at = null } },
    .{ .stopped = .{ .since = test_now_s - 10, .cause = .stop } },
};

test "listing and activity settle one row by source revision in every state and completion order" {
    const ref = "k7m2qx".*;
    const states = read_order_states;
    try std.testing.expectEqual(std.meta.tags(Kind).len, states.len);
    for ([_]Delta{ .full, .changed }) |delta| for (states) |older| for (states) |newer| for ([_]bool{ false, true }) |activity_newer| for ([_]bool{ false, true }) |activity_first| {
        var latest = newer;
        switch (latest) {
            inline else => |*value| value.since = test_now_s - 5,
        }
        var state = try opened(&.{session(&ref, .{ .idle = ago(20) }, .{ .label = "Same Session" })});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        const listed_state = if (activity_newer) older else latest;
        var listed = session(&ref, listed_state, .{ .label = "Same Session", .turn = if (activity_newer) 2 else 3 });
        listed.operation = listed.turn;
        listed.read_version = testToken(if (activity_newer) 2 else 3);
        const observed: Observed = .{
            .read_version = testToken(if (activity_newer) 3 else 2),
            .reference = ref,
            .work = fixtureWork(.{ .state = if (activity_newer) latest else older, .turn = if (activity_newer) 3 else 2, .operation = if (activity_newer) 3 else 2 }),
            .opening = false,
        };
        if (activity_first) _ = try step(&state, .{ .observed = observed });
        _ = try respond(&state, delta, testToken(3), &.{listed});
        if (!activity_first) _ = try step(&state, .{ .observed = observed });
        for ([_]bool{ false, true }) |depart| {
            if (depart) _ = try step(&state, .{ .conversation = null });
            const row = state.find(ref).?;
            try std.testing.expectEqualDeep(latest, row.state);
            try std.testing.expectEqual(@as(?u64, 3), row.turn);
            try std.testing.expectEqual(@as(?u64, 3), row.operation);
            try std.testing.expectEqual(latest.since(), shownSince(&state, row));
            try std.testing.expectEqualDeep(testToken(3), row.read_version.?);
        }
    };
}

test "older and newer activity reads settle by revision in either order before departure and listing" {
    const ref = "aaaaaa".*;
    for ([_]Delta{ .full, .changed }) |delta| for (read_order_states) |older| for (read_order_states) |newer| for ([_]bool{ false, true }) |newer_first| {
        var latest = newer;
        switch (latest) {
            inline else => |*value| value.since = test_now_s - 5,
        }
        var state = try opened(&.{session(&ref, .{ .idle = ago(20) }, .{})});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        for (0..2) |at| {
            const is_newer = (at == 0) == newer_first;
            _ = try step(&state, .{ .observed = .{
                .read_version = testToken(if (is_newer) 3 else 2),
                .reference = ref,
                .work = fixtureWork(.{ .state = if (is_newer) latest else older }),
                .opening = false,
            } });
        }
        _ = try step(&state, .{ .conversation = null });
        _ = try respond(&state, delta, testToken(2), &.{session(&ref, older, .{})});
        const row = state.find(ref).?;
        try std.testing.expectEqualDeep(latest, row.state);
        try std.testing.expectEqual(latest.since(), shownSince(&state, row));
    };
}

fn stopCase3() !void {
    const ref = "k7m2qx".*;
    for ([_]Delta{ .full, .changed }) |delta| {
        const old = session(&ref, .{ .stopping = ago(10) }, .{ .label = "Same Session", .turn = 7 });
        var state = try opened(&.{old});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        const stopped: session_work.Work = fixtureWork(.{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .turn = 7 });
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(3), .reference = ref, .work = stopped, .opening = false } });
        _ = try step(&state, .{ .conversation = null });
        _ = try respond(&state, delta, testToken(2), &.{old});
        _ = try refresh(&state, .not_modified, testToken(3), &.{});
        try std.testing.expect(std.meta.eql(stopped, state.workOf(state.find(ref).?)));
        try std.testing.expectEqual(Kind.stopped, classOf(&state, state.find(ref).?).kind);
        try std.testing.expectEqual(@as(u64, test_now_s), shownSince(&state, state.find(ref).?));
        const finished = session(&ref, .{ .finished = ago(0) }, .{ .label = "Same Session", .turn = 8 });
        _ = try refresh(&state, delta, testToken(4), &.{finished});
        try std.testing.expectEqual(Kind.finished, classOf(&state, state.find(ref).?).kind);
    }
}

test "snapshot and listing rows render identical stopped failed and done endings" {
    const ref = "k7m2qx".*;
    const cases = [_]struct { state: WorkState }{
        .{ .state = .{ .stopped = .{ .since = test_now_s - 5, .cause = .stop } } },
        .{ .state = .{ .failed = .{ .since = test_now_s - 5, .code = bounded(session_work.max_code_bytes, "malformed_provider_output"), .resets_at = null } } },
        .{ .state = .{ .finished = ago(5) } },
    };
    for (cases) |case| {
        const initial = session(&ref, .{ .working = ago(10) }, .{ .label = "Same Session", .turn = 7 });
        var state = try opened(&.{initial});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(2), .reference = ref, .work = fixtureWork(.{ .state = case.state, .turn = 8 }), .opening = false } });
        try std.testing.expectEqualDeep(case.state, state.find(ref).?.state);
        const snapshot = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(snapshot);
        var from_list = try opened(&.{initial});
        defer from_list.deinit();
        _ = try step(&from_list, .{ .conversation = ref });
        _ = try step(&from_list, .{ .tick = state.now_ms });
        const listed = session(&ref, case.state, .{ .label = "Same Session", .turn = 8 });
        _ = try respond(&from_list, .changed, testToken(2), &.{listed});
        const listing = try screenText(&from_list, 80, 24, .{});
        defer std.testing.allocator.free(listing);
        try std.testing.expectEqualStrings(listing, snapshot);
    }
}

fn projectionCase6() !void {
    const ref = "aaaaaa".*;
    for ([_]Delta{ .full, .changed }) |delta| {
        const retry = retryRow(&ref, "provider_temporary_http_429", 5);
        var state = try opened(&.{retry});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = (test_now_s + 5) * 1000 });
        try std.testing.expectEqual(Kind.pending, classOf(&state, state.find(ref).?).kind);
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(1), .reference = ref, .work = fixtureWork(.{ .state = retry.state }), .opening = false } });
        _ = try respond(&state, delta, testToken(1), &.{retry});
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(Kind.pending, classOf(&state, state.find(ref).?).kind);
        try std.testing.expectEqual(test_now_s + 5, shownSince(&state, state.find(ref).?));
    }
}

test "activity before metadata and an omitted open row use the same bounded row owner" {
    const ref = "aaaaaa".*;
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    const settled: Observed = .{ .read_version = testToken(3), .reference = ref, .work = fixtureWork(.{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } } }), .opening = false };
    _ = try step(&state, .{ .observed = settled });
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    try std.testing.expect(!state.find(ref).?.listed);
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    _ = try respond(&state, .full, testToken(2), &.{session(&ref, .{ .stopping = ago(5) }, .{ .label = "New metadata" })});
    try std.testing.expectEqualDeep(settled.work, state.workOf(state.find(ref).?));
    try std.testing.expectEqualStrings("New metadata", state.find(ref).?.label.?.slice());
    try std.testing.expectEqual(@as(usize, 1), state.order.items.len);
    _ = try refresh(&state, .full, testToken(4), &.{});
    try std.testing.expectEqualDeep(settled.work, state.workOf(state.find(ref).?));
    try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    _ = try step(&state, .{ .conversation = null });
    _ = try step(&state, .{ .observed = settled });
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
}

test "full and changed metadata supply every provider without replacing newer activity work" {
    const ref = "aaaaaa".*;
    const providers = std.enums.values(provider_name.Provider);
    for ([_]Delta{ .full, .changed }) |delta| for ([_]bool{ false, true }) |known| for (providers, 0..) |provider, i| {
        const other = providers[(i + 1) % providers.len];
        var state = if (known)
            try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .provider = pn(other) })})
        else
            try testState();
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        const latest: Observed = .{
            .reference = ref,
            .read_version = testToken(3),
            .work = fixtureWork(.{ .state = .{ .failed = .{ .since = test_now_s, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .turn = 8 }),
            .opening = false,
        };
        _ = try step(&state, .{ .observed = latest });
        try std.testing.expectEqual(if (known) @as(?Provider, pn(other)) else null, state.find(ref).?.provider);
        if (!known) try std.testing.expect(band(&state) == null);
        _ = try step(&state, .{ .tick = (test_now_s * 1000) + list_interval_ms });
        const metadata = session(&ref, .{ .stopping = ago(5) }, .{ .provider = pn(provider), .label = "Listed metadata" });
        _ = try respond(&state, delta, testToken(2), &.{metadata});
        try std.testing.expectEqual(@as(?Provider, pn(provider)), state.find(ref).?.provider);
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
        try std.testing.expectEqual(testToken(3), state.find(ref).?.read_version.?);
        try std.testing.expectEqual(test_now_s, shownSince(&state, state.find(ref).?));
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = pn(provider) }, band(&state).?);
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = pn(provider) }, band(&state).?);
        const changed = session(&ref, latest.work.state, .{ .provider = pn(other), .turn = 8 });
        _ = try refresh(&state, delta, testToken(4), &.{changed});
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = pn(other) }, band(&state).?);
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
    };
}

test "only a Host handshake rebases read revisions and rejects old traversals and replies" {
    const ref = "aaaaaa".*;
    var state = try opened(&.{session(&ref, .{ .stopping = ago(10) }, .{})});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    const stopped: session_work.Work = fixtureWork(.{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } } });
    _ = try step(&state, .{ .observed = .{ .read_version = testToken(100), .reference = ref, .work = stopped, .opening = false } });
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    const old_page = [_]Listed{session(&ref, .{ .stopping = ago(10) }, .{})};
    var row = old_page[0];
    row.read_version = testToken(101);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{row}, .answer = null } } });
    const next: Token = .{ .instance = @splat(0x11), .generation = 1 };
    _ = try step(&state, .{ .host = .{ .instance = next.instance, .started_at = test_now_s + 1, .slots = 2, .slots_in_use = 0 } });
    _ = try respond(&state, .full, testToken(101), &.{});
    try std.testing.expectEqualDeep(stopped, state.workOf(state.find(ref).?));
    try std.testing.expect(state.token == null);
    const finished: session_work.Work = fixtureWork(.{ .state = .{ .finished = ago(0) } });
    _ = try step(&state, .{ .observed = .{ .read_version = next, .reference = ref, .work = finished, .opening = false } });
    _ = try step(&state, .{ .observed = .{ .read_version = testToken(200), .reference = ref, .work = stopped, .opening = false } });
    _ = try respond(&state, .not_modified, testToken(200), &.{});
    try std.testing.expect(state.token == null);
    try std.testing.expectEqualDeep(finished, state.workOf(state.find(ref).?));
    _ = try step(&state, .{ .tick = state.next_list_ms });
    _ = try respond(&state, .full, next, &.{session(&ref, finished.state, .{})});
    try std.testing.expectEqualDeep(next, state.token.?);
    try std.testing.expectEqualDeep(finished, state.workOf(state.find(ref).?));
}

test "SUI-135 Configure ledger retains each unknown through later edits and Session switches" {
    const ref = "k7m2qx".*;
    const a: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const b: [36]u8 = "01234567-89ab-4cde-8012-0123456789ac".*;
    const store = try @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes).from("/store-a");
    for ([_]bool{ false, true }) |second_unknown| {
        var state = try opened(&.{session(&ref, .{ .idle = ago(0) }, .{})});
        defer state.deinit();
        const first = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort medium" } } } });
        try std.testing.expectEqual(IntentAdmission.admitted, first.intent_admission);
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .completed = .{ .unconfirmed = .{ .key = a, .store = store } } } } } });
        const next = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort high" } } } });
        try std.testing.expectEqual(IntentAdmission.admitted, next.intent_admission);
        const second: @import("configure_outcome.zig").Outcome = if (second_unknown) .{ .unconfirmed = .{ .key = b, .store = store } } else .accepted;
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .completed = second } } } });
        _ = try step(&state, .{ .conversation = null });
        _ = try step(&state, .{ .conversation = ref });
        try std.testing.expectEqual(@as(usize, if (second_unknown) 2 else 1), state.request_count);
        try std.testing.expect(state.requests[0].text.eql(&a));
        if (second_unknown) try std.testing.expect(state.requests[1].text.eql(&b));
        var guidance: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer guidance.deinit();
        try writeDeparture(&state, null, &guidance.writer);
        try std.testing.expect(std.mem.indexOf(u8, guidance.written(), &a) != null);
        try std.testing.expect(std.mem.indexOf(u8, guidance.written(), "effort medium") != null);
        try std.testing.expectEqual(second_unknown, std.mem.indexOf(u8, guidance.written(), &b) != null);
        var status: [max_unconfirmed_line_bytes]u8 = undefined;
        try std.testing.expect(unconfirmedLine(&state, &status) != null);
        const other_store = try @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes).from("/store-b");
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .observed = .{ .key = a, .store = other_store } } } } });
        try std.testing.expectEqual(@as(usize, if (second_unknown) 2 else 1), state.request_count);
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .observed = .{ .key = a, .store = store } } } } });
        try std.testing.expectEqual(@as(usize, @intFromBool(second_unknown)), state.request_count);
        if (second_unknown) try std.testing.expect(state.requests[0].text.eql(&b));
    }
}

test "SUI-135 Configure ledger capacity is released only by the matching observed receipt" {
    const ref = "k7m2qx".*;
    var state = try opened(&.{session(&ref, .{ .idle = ago(0) }, .{})});
    defer state.deinit();
    var first: [36]u8 = undefined;
    const store = try @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes).from("/store-a");
    for (0..max_requests) |at| {
        var key: [36]u8 = "01234567-89ab-4cde-8012-0123456789a0".*;
        key[35] = '0' + @as(u8, @intCast(at));
        if (at == 0) first = key;
        const reserved = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort: high" } } } });
        try std.testing.expectEqual(IntentAdmission.admitted, reserved.intent_admission);
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .completed = .{ .unconfirmed = .{ .key = key, .store = store } } } } } });
    }
    const refused = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort: low" } } } });
    try std.testing.expectEqual(IntentAdmission.refused, refused.intent_admission);
    const unrelated: [36]u8 = "01234567-89ab-4cde-8012-0123456789af".*;
    _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .observed = .{ .key = unrelated, .store = store } } } } });
    try std.testing.expectEqual(@as(usize, max_requests), state.request_count);
    _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .observed = .{ .key = first, .store = store } } } } });
    try std.testing.expectEqual(@as(usize, max_requests - 1), state.request_count);
    const next = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort: low" } } } });
    try std.testing.expectEqual(IntentAdmission.admitted, next.intent_admission);
}

test "SUI-135 identical Configure keys in different Stores retire independently" {
    const ref = "k7m2qx".*;
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const Original = @import("configure_outcome.zig").Original;
    const a: Original = .{ .key = key, .store = try .from("/store-a") };
    const b: Original = .{ .key = key, .store = try .from("/store-b") };
    var state = try opened(&.{session(&ref, .{ .idle = ago(0) }, .{})});
    defer state.deinit();
    for ([_]Original{ a, b }) |original| {
        const reserved = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .reserve = "effort: medium" } } } });
        try std.testing.expectEqual(IntentAdmission.admitted, reserved.intent_admission);
        _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .completed = .{ .unconfirmed = original } } } } });
    }
    var snapshot: [max_requests]Original = undefined;
    try std.testing.expectEqual(@as(usize, 2), unknownConfigureKeys(&state, ref, &snapshot));
    _ = try step(&state, .{ .conversed = .{ .reference = ref, .work = .idle, .input = .{ .configure = .{ .observed = b } } } });
    try std.testing.expectEqual(@as(usize, 1), state.request_count);
    try std.testing.expect(state.requests[0].text.eql(&key));
    try std.testing.expect(state.requests[0].configure_store.eql("/store-a"));
}

test "SUI-135 maximum Configure departure guidance fits its shared bound" {
    const ref = "k7m2qx".*;
    var state = try opened(&.{session(&ref, .{ .idle = ago(0) }, .{})});
    defer state.deinit();
    const store: [@import("store_path.zig").max_bytes]u8 = @splat(0x1b);
    const intent: [max_configure_intent_bytes]u8 = @splat('i');
    const key: [max_handle_bytes]u8 = @splat('a');
    for (0..max_requests) |at| {
        state.requests[at] = .{ .kind = .configure, .session = ref, .status = .unknown };
        try state.requests[at].text.set(&key);
        try state.requests[at].configure_store.set(&store);
        try state.requests[at].configure_intent.set(&intent);
    }
    state.request_count = max_requests;
    var bytes: [max_departure_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try writeDeparture(&state, null, &out);
    try std.testing.expectEqual(@as(usize, max_requests), std.mem.count(u8, out.buffered(), "may apply this older setting"));
    try std.testing.expectEqual(@as(usize, max_requests * store.len), std.mem.count(u8, out.buffered(), "\\x1b"));
    try state.requests[0].configure_store.set("/tmp/\u{202e}store");
    out = .fixed(&bytes);
    try writeDeparture(&state, null, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\\u202e") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\u{202e}") == null);
}

test "SUI-135 an unknown Send's key outranks a newer unconfirmed Configure on the status line" {
    const ref = "k7m2qx".*;
    var state = try opened(&.{session(&ref, .{ .idle = ago(0) }, .{})});
    defer state.deinit();
    state.requests[0] = .{ .kind = .send, .session = ref, .status = .unknown };
    state.requests[1] = .{ .kind = .configure, .session = ref, .status = .unknown };
    state.request_count = 2;
    var line: [max_unconfirmed_line_bytes]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, unconfirmedLine(&state, &line).?.words, "send not confirmed") != null);
    state.requests[0].status = .done;
    try std.testing.expect(std.mem.indexOf(u8, unconfirmedLine(&state, &line).?.words, "Config unconfirmed") != null);
}

test "an original Esc left unconfirmed is named at once and recovered on departure, until the ledger is full" {
    var line: [max_unconfirmed_line_bytes]u8 = undefined;
    const refs = [_]Reference{ "k7m2qx".*, "r4t9vw".* };
    var rows: [refs.len]Listed = undefined;
    for (&rows, &refs, 0..) |*row, *ref, n| row.* = session(ref, .{ .working = ago(10 * (n + 1)) }, .{});
    var state = try opened(&rows);
    defer state.deinit();
    const saved_key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const reserved_key: [36]u8 = "fedcba98-7654-4321-8fed-cba987654321".*;
    try std.testing.expectEqual(null, unconfirmedLine(&state, &line));
    try expectEffects(&.{}, try step(&state, .{ .unconfirmed = .{ .reference = refs[0], .recovery = .{ .saved = .{ .original = .{ .kind = .decision, .key = saved_key }, .rejected = false } } } }));
    try say_text.expect("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    try std.testing.expectEqual(null, state.notice);
    _ = try press(&state, .next);
    try say_text.expect("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    try expectEffects(&.{}, try step(&state, .{ .unconfirmed = .{ .reference = refs[1], .recovery = .{ .uncertain = reserved_key } } }));
    try say_text.expect("! r4t9vw: send not confirmed; details on exit", unconfirmedLine(&state, &line).?);
    while (canHoldSend(&state)) try expectEffects(&.{}, try step(&state, .{ .unconfirmed = .{ .reference = refs[0], .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = saved_key }, .rejected = false } } } }));
    try std.testing.expectEqual(@as(usize, max_requests), state.request_count);
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    const lines = departure.written();
    try std.testing.expect(std.mem.startsWith(u8, lines, "rui: Decision not confirmed. Use rui request recover " ++ saved_key ++ " to retry the exact original; do not resubmit it.\n" ++
        "rui: Capture not confirmed. Inspect rui request list for reserved key " ++ reserved_key ++ "; reservation does not prove publication. Recover only that original, never replacement input.\n"));
    try std.testing.expectEqual(@as(usize, max_requests - 2), std.mem.count(u8, lines, "rui: Message not confirmed. Use rui request recover " ++ saved_key));
}

fn stopCase2() !void {
    const refs = [_]Reference{ "k7m2qx".*, "r4t9vw".*, "a1b2c3".*, "b2c3d4".*, "c3d4e5".*, "d4e5f6".*, "f6g7h8".*, "g7h8j9".*, "m1n2p3".* };
    comptime std.debug.assert(refs.len == max_requests + 1);
    var rows: [refs.len]Listed = undefined;
    for (&rows, &refs, 0..) |*row, *ref, n| row.* = session(ref, .{ .working = ago(10 * (n + 1)) }, .{});
    var state = try opened(&rows);
    defer state.deinit();
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var stopped: [max_requests]Reference = undefined;
    for (&stopped, 0..) |*ref, n| {
        if (n != 0) try expectEffects(&.{}, try press(&state, .next));
        ref.* = state.selected.session;
        for (stopped[0..n]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, ref));
        var bytes: [32]u8 = undefined;
        const handle = try std.fmt.bufPrint(&bytes, "stop-handle-{d}", .{n});
        var notice: [128]u8 = undefined;
        const recover = try std.fmt.bufPrint(&notice, "! {s} stop unsure; details on exit", .{ref});
        try expectEffects(&.{.{ .stop = ref.* }}, try press(&state, .stop));
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref.*, .outcome = .{ .unconfirmed = handle } } }));
        try expectNotice(&state, recover);
        try std.testing.expectEqual(Kind.stopping, classOf(&state, state.find(ref.*).?).kind);
        state.notice = null;
        try expectEffects(&.{}, try press(&state, .stop));
        try expectEffects(&.{}, try press(&state, .stop));
        try expectNotice(&state, recover);
        try expected.writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ ref, handle });
    }
    try expectEffects(&.{}, try press(&state, .next));
    const last = state.selected.session;
    for (stopped) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, &last));
    try expectEffects(&.{}, try press(&state, .stop));
    try expectEffects(&.{}, try press(&state, .stop));
    try expectNotice(&state, "! Busy; try again shortly.");
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings(expected.written(), departure.written());
}

fn expectLines(text: []const u8, first: usize, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..first) |_| _ = lines.next();
    for (expected) |line| try std.testing.expectEqualStrings(line, std.mem.trimEnd(u8, lines.next().?, " "));
}

fn expectScreenLine(state: *State, line: usize, expected: []const u8) !void {
    const text = try screenText(state, 80, 24, .{ .devanagari = true });
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..line) |_| _ = lines.next();
    try std.testing.expectEqualStrings(expected, lines.next().?);
}

test "session resume opens its Session through the overview, which then keeps it selected" {
    var state = try testState();
    defer state.deinit();
    try expectEffects(&.{ .{ .open = "c3d4e5".* }, .list_models }, try step(&state, .{ .open = "c3d4e5".* }));
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectSelected(&state, "c3d4e5");
}

test "caps follow the locale that sets the character set, NO_COLOR, COLORTERM and Windows Terminal" {
    for ([_]struct { Caps.Environment, Caps }{
        .{ .{}, .{ .depth = .indexed } },
        .{ .{ .lang = "en_US.UTF-8" }, .{ .depth = .indexed } },
        .{ .{ .lang = "C" }, .{ .unicode = false, .depth = .indexed } },
        .{ .{ .lang = "C.utf8" }, .{ .depth = .indexed } },
        .{ .{ .lc_all = "C", .lang = "en_US.UTF-8" }, .{ .unicode = false, .depth = .indexed } },
        .{ .{ .lc_all = "", .lc_ctype = "POSIX", .lang = "en_US.UTF-8" }, .{ .unicode = false, .depth = .indexed } },
        .{ .{ .lc_ctype = "en_GB.utf-8", .lang = "C" }, .{ .depth = .indexed } },
        .{ .{ .lang = "C", .no_color = "1" }, .{ .unicode = false, .depth = .none } },
        .{ .{ .no_color = "1", .colorterm = "truecolor" }, .{ .depth = .none } },
        .{ .{ .no_color = "" }, .{ .depth = .indexed } },
        .{ .{ .colorterm = "truecolor" }, .{} },
        .{ .{ .colorterm = "24bit" }, .{} },
        .{ .{ .colorterm = "yes" }, .{ .depth = .indexed } },
        .{ .{ .wt_session = "5f8a6c2e-3b1d-4e7a-9c0f-1a2b3c4d5e6f" }, .{} },
        .{ .{ .wt_session = "" }, .{ .depth = .indexed } },
        .{ .{ .wt_session = "5f8a6c2e-3b1d-4e7a-9c0f-1a2b3c4d5e6f", .no_color = "1" }, .{ .depth = .none } },
    }) |case| try std.testing.expectEqual(case[1], Caps.of(case[0]));
}

test "a first line read one byte past the kept bound shows it was cut" {
    var line: [max_line_read_bytes]u8 = @splat('a');
    try std.testing.expect(std.mem.endsWith(u8, session_line.cut(max_line_bytes, session_line.firstLine(&line)).slice(), "…"));
    try std.testing.expect(!std.mem.endsWith(u8, session_line.cut(max_line_bytes, session_line.firstLine(line[0..max_line_bytes])).slice(), "…"));
}

test "a first line arriving titles its unlabelled row" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    var reads: Reads = .{};
    for ([_]struct { *const [6]u8, u64 }{ .{ "f6g7h8", 9 }, .{ "h8q2mz", 4 }, .{ "p3q4r5", 4 } }) |read| {
        reads.items[reads.len] = .{ .reference = read[0].*, .position = 1, .admission = read[1], .content = test_first };
        reads.len += 1;
    }
    try expectEffects(&.{.{ .read_first_lines = reads }}, try respond(&state, .full, testToken(1), &mixed));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "  summarize yesterday's CI failures\r\nand say which are new" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = null } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "p3q4r5".*, .admission = 5, .line = "not this one" } }));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(FirstLineRead.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqual(FirstLineRead.requested, state.find("p3q4r5".*).?.line);
    try expectScreenLine(&state, position(&state, "h8q2mz".*).? + 2, "   summarize yesterday's CI failures                                        12m");
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{session("h8q2mz", .{ .working = ago(0) }, .{ .yours = true })}));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".*, .content = test_first } });
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{f6g7h8}));
    var next_turn = mixed;
    next_turn[1].turn = 2;
    try expectEffects(&.{}, try refresh(&state, .full, testToken(4), &next_turn));
    try std.testing.expectEqual(FirstLineRead.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "a second answer" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = "a late answer" } }));
    try std.testing.expectEqual(@as(usize, 1), state.lines.items.len);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(FirstLineRead.unavailable, state.find("f6g7h8".*).?.line);
    var again: Reads = .{};
    again.items[0] = .{ .reference = "f6g7h8".*, .position = 2, .admission = 12, .content = test_first };
    again.len = 1;
    try expectEffects(&.{.{ .read_first_lines = again }}, try refresh(&state, .changed, testToken(5), &.{session("f6g7h8", .{ .idle = ago(0) }, .{ .first = .{ .position = 2, .admission = 12, .sender = null, .content = test_first } })}));
}

test "a first line with no answer is asked for again by the next listing" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    const rows = [_]Listed{session("h8q2mz", .{ .finished = ago(60) }, .{})};
    var reads: Reads = .{};
    reads.items[0] = .{ .reference = "h8q2mz".*, .position = 1, .admission = 4, .content = test_first };
    reads.len = 1;
    try expectEffects(&.{.{ .read_first_lines = reads }}, try respond(&state, .full, testToken(1), &rows));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = null, .unanswered = true } }));
    try std.testing.expectEqual(FirstLineRead.unread, state.find("h8q2mz".*).?.line);
    try expectEffects(&.{.{ .read_first_lines = reads }}, try refresh(&state, .not_modified, testToken(1), &.{}));
}

test "Host facts change only the counts line, and a row from before a restart still says working" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Admitted before the restart" }),
        session("h8q2mz", .{ .working = ago(5) }, .{ .label = "Admitted after it" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
    });
    defer state.deinit();
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try expectScreenLine(&state, 0, " + New chat");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 0, " + New chat");
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, " + New chat").?..], after[std.mem.indexOf(u8, after, " + New chat").?..]);
    try std.testing.expect(std.mem.indexOf(u8, after, " ◜ Admitted before the restart") != null);
}

test "a row from another Workspace keeps its title at every width" {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(5) }, .{ .label = "Profile the queue", .workspace = "/srv/elsewhere/project" }),
        session("d4e5f6", .{ .working = ago(5) }, .{ .label = "Trace the shutdown", .workspace = "/srv/elsewhere/project" }),
    });
    defer state.deinit();
    for (40..120) |width| {
        const text = try screenText(&state, @intCast(width), 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "Profile") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Trace") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "project") == null);
    }
}

test "the selection stays on its Session when it moves from active to finished" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try press(&state, .next);
    try expectSelected(&state, "e5f6g7");
    _ = try refresh(&state, .changed, testToken(2), &.{session("e5f6g7", .{ .finished = ago(0) }, .{ .label = "List unused build steps" })});
    try expectSelected(&state, "e5f6g7");
    try std.testing.expectEqual(session_class.Standing.done, classOf(&state, state.find("e5f6g7".*).?).standing);
    try expectEffects(&.{ .{ .open = "e5f6g7".* }, .list_models }, try submit(&state));
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   List unused build steps") != null);
    _ = try press(&state, .next);
    try expectSelected(&state, "c3d4e5");
    _ = try press(&state, .next);
    try expectSelected(&state, "k7m2qx");
    state.selected = .{ .session = "m1n2p3".* };
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expectEqual(state.order.items.len, Lines.count(&state));
}

fn sentRecords(state: *State, into: []StatusRecord) []StatusRecord {
    var count: usize = 0;
    var unsettled = state.unsettledStatuses();
    while (unsettled.next()) |record| : (count += 1) into[count] = record;
    for (into[0..count]) |record| state.statusTaken(record.taken());
    return into[0..count];
}

fn expectRecords(expected: []const StatusRecord, actual: []const StatusRecord) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(&want.reference, &got.reference);
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.status, got.status);
    }
}

test "SUI-139 Archived window withdraws its prior program status" {
    const ref = "b4n8wd".*;
    for ([_]bool{ false, true }) |delivered| for ([_]bool{ false, true }) |current_host| {
        var state = try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .label = "Busy", .turn = 1 })});
        defer state.deinit();
        if (delivered) {
            var before: [8]StatusRecord = undefined;
            const sent = sentRecords(&state, &before);
            try std.testing.expectEqual(@as(usize, 1), sent.len);
            try std.testing.expectEqualStrings(&ref, &sent[0].reference);
            try std.testing.expectEqual(attention.Status.working, sent[0].status.?);
        }
        var effects: Effects = .{};
        try changeArchiveView(&state, .archived, &effects);
        const read = effects.slice()[0].read_archived;
        const archived = session(&ref, .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .label = "Busy", .archive_state = .archived, .archive_seq = 10 });
        var version = testToken(2);
        if (!current_host) version.instance = @splat(0xcd);
        _ = try step(&state, .{ .archived = .{ .read = read, .page = .{ .since = version, .rows = &.{archived}, .first = 10, .last = 10, .more_above = false, .more_below = false } } });
        var after: [8]StatusRecord = undefined;
        const records = sentRecords(&state, &after);
        const changed = delivered == current_host;
        try std.testing.expectEqual(@as(usize, @intFromBool(changed)), records.len);
        if (changed) {
            try std.testing.expectEqualStrings(&ref, &records[0].reference);
            if (current_host) {
                try std.testing.expectEqual(null, records[0].status);
            } else {
                try std.testing.expectEqual(attention.Status.working, records[0].status.?);
            }
        }
        try std.testing.expect(state.statusesSettled());
    };
}

test "listings give each Session one program status record that follows its changes, and clear it once unlisted" {
    const listed = [_]Listed{
        session("m2j7fs", .{ .finished = ago(0) }, .{ .label = "Old finish", .turn = 1 }),
        session("b4n8wd", .{ .working = ago(0) }, .{ .label = "Busy", .turn = 1 }),
        session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Waits", .turn = 1, .first_action = 3 }),
        session("p3c6tz", .{ .idle = ago(0) }, .{ .label = "Resting" }),
    };
    var state = try opened(&listed);
    defer state.deinit();
    var records: [8]StatusRecord = undefined;
    try expectRecords(&.{
        .{ .reference = "a1b2c3".*, .name = "Waits", .status = .blocked },
        .{ .reference = "b4n8wd".*, .name = "Busy", .status = .working },
    }, sentRecords(&state, &records));
    _ = try refresh(&state, .full, testToken(2), &listed);
    try std.testing.expect(state.statusesSettled());
    _ = try refresh(&state, .full, testToken(3), &.{
        listed[0],
        session("b4n8wd", .{ .finished = ago(0) }, .{ .label = "Busy", .turn = 1 }),
        listed[3],
        session("z9y8x7", .{ .failed = .{ .since = test_now_s, .code = .{}, .resets_at = null } }, .{ .label = "New", .turn = 1 }),
    });
    try expectRecords(&.{
        .{ .reference = "a1b2c3".*, .name = "", .status = null },
        .{ .reference = "b4n8wd".*, .name = "Busy", .status = .done },
        .{ .reference = "z9y8x7".*, .name = "New", .status = .failed },
    }, sentRecords(&state, &records));
    _ = try step(&state, .{ .open = "b4n8wd".* });
    try expectRecords(&.{.{ .reference = "b4n8wd".*, .name = "Busy", .status = .idle }}, sentRecords(&state, &records));
    _ = try refresh(&state, .changed, testToken(4), &.{session("b4n8wd", .{ .finished = ago(0) }, .{ .label = "Busy", .turn = 1 })});
    try std.testing.expect(state.statusesSettled());
    _ = try refresh(&state, .changed, testToken(5), &.{session("b4n8wd", .{ .finished = ago(0) }, .{ .label = "Busy", .turn = 2 })});
    try expectRecords(&.{.{ .reference = "b4n8wd".*, .name = "Busy", .status = .done }}, sentRecords(&state, &records));
    _ = try refresh(&state, .changed, testToken(6), &.{session("b4n8wd", .{ .finished = ago(0) }, .{ .label = "Busy", .turn = 3 })});
    try expectRecords(&.{.{ .reference = "b4n8wd".*, .name = "Busy", .status = .done }}, sentRecords(&state, &records));
    state.statusesCleared();
    try expectRecords(&.{
        .{ .reference = "b4n8wd".*, .name = "Busy", .status = .done },
        .{ .reference = "z9y8x7".*, .name = "New", .status = .failed },
    }, sentRecords(&state, &records));
}

test "a later wait is a blocked record again, though no listing read the Session at work between" {
    const waiting = session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Waits", .turn = 1, .first_action = 3 });
    var state = try opened(&.{waiting});
    defer state.deinit();
    var records: [8]StatusRecord = undefined;
    const blocked: StatusRecord = .{ .reference = "a1b2c3".*, .name = "Waits", .status = .blocked };
    try expectRecords(&.{blocked}, sentRecords(&state, &records));
    _ = try refresh(&state, .full, testToken(2), &.{waiting});
    try std.testing.expect(state.statusesSettled());
    _ = try refresh(&state, .full, testToken(3), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Waits", .turn = 1, .first_action = 4 })});
    try expectRecords(&.{blocked}, sentRecords(&state, &records));
    _ = try refresh(&state, .full, testToken(4), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Waits", .turn = 2, .first_action = 9 })});
    try expectRecords(&.{blocked}, sentRecords(&state, &records));
}

test "overview selection walks both ends and every row without folding" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try press(&state, .first);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    try std.testing.expectEqual(null, Lines.named(&state));
    _ = try press(&state, .previous);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.sessions, state.selected);
    for (state.order.items, 0..) |index, at| {
        _ = try press(&state, .next);
        try expectSelected(&state, &state.rows.items[index].reference);
        try std.testing.expectEqual(@as(?usize, at), Lines.named(&state));
    }
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.settings, state.selected);
    try std.testing.expectEqual(null, Lines.named(&state));
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.settings, state.selected);
    var at = state.order.items.len;
    while (at != 0) {
        at -= 1;
        _ = try press(&state, .previous);
        try expectSelected(&state, &state.rows.items[state.order.items[at]].reference);
    }
    _ = try press(&state, .previous);
    try std.testing.expectEqual(Selection.sessions, state.selected);
    _ = try press(&state, .previous);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try press(&state, .last);
    try std.testing.expectEqual(Selection.settings, state.selected);
}

test "one click on a row opens it, under Enter's rules" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{ .{ .open = "b2c3d4".* }, .list_models }, try step(&state, .{ .clicked = .{ .target = .{ .open = "b2c3d4".* } } }));
    try expectSelected(&state, "b2c3d4");
    state.upgrade.run = .checking;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .{ .open = "g7h8j9".* } } }));
    try expectSelected(&state, "g7h8j9");
}

test "a click that names a Session gone from the list since it was drawn changes nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.session;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .{ .open = "n0n0n0".* } } }));
    try expectSelected(&state, &selected);
}

test "SUI-130 Active roster walks commit one complete listing at a time" {
    try activeRosterPaging();
    try activeRosterDuplicates();
    try activeRosterRetry();
    try activeRosterFullFallback();
}

fn expectEachOnce(state: *const State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, Lines.count(state));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (expected) |ref| {
        var seen: usize = 0;
        for (0..Lines.count(state)) |at| {
            const line = (try Lines.at(arena.allocator(), state, at, 80, .{}, 0)).?;
            if (line.target) |target| if (target == .open and std.mem.eql(u8, ref, &target.open)) {
                seen += 1;
            };
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

fn activeRosterPaging() !void {
    const a = session("aaaaaa", .{ .working = ago(10) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(20) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(30) }, .{ .label = "C" });
    var state = try opened(&.{ a, b, c });
    defer state.deinit();
    try std.testing.expectEqual(testToken(1), state.token.?);

    _ = try refresh(&state, .changed, testToken(2), &.{ session("bbbbbb", .{ .finished = ago(0) }, .{ .label = "B" }), session("dddddd", .{ .pending = ago(0) }, .{ .label = "D" }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    try std.testing.expect(state.find("bbbbbb".*).?.state == .finished);
    try std.testing.expectEqual(testToken(2), state.token.?);

    var nine: [9]Listed = undefined;
    for (&nine, 0..) |*row, n| row.* = session(&[6]u8{ 'e', 'e', 'e', 'e', 'e', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n) }, .{ .label = "E" });
    var asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{.{ .list = .{ .since = testToken(2), .archive = .active } }}, asked);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = nine[0..8], .answer = null } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{ a, b, c, nine[0] }, .restarts = true, .answer = null } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    const restart = try step(&state, .{ .list = .{ .page = .{ .rows = &.{nine[8]}, .answer = .{ .delta = .full, .since = testToken(6) } } } });
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, restart);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{ a, b, c, nine[0], nine[8] }, .answer = .{ .delta = .full, .since = testToken(6) } } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "eeeee0", "eeeee8" });
    try std.testing.expectEqual(testToken(6), state.token.?);

    asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{.{ .list = .{ .since = testToken(6), .archive = .active } }}, asked);
    _ = try respond(&state, .not_modified, testToken(6), &.{});
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "eeeee0", "eeeee8" });

    _ = try refresh(&state, .full, testToken(7), &.{ session("aaaaaa", a.state, .{ .label = "A", .read_version = testToken(6) }), b, session("aaaaaa", .{ .finished = ago(0) }, .{ .label = "A", .read_version = testToken(7) }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb" });
    try std.testing.expect(state.find("aaaaaa".*).?.state == .finished);
}

fn activeRosterDuplicates() !void {
    const a = session("aaaaaa", .{ .working = ago(10) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(20) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(30) }, .{ .label = "C" });
    var state = try opened(&.{ b, c, a, session("bbbbbb", .{ .finished = ago(0) }, .{ .label = "B", .read_version = testToken(2) }) });
    defer state.deinit();
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc" });
    try std.testing.expect(state.find("bbbbbb".*).?.state == .finished);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const at = lineOfReference(&state, "cccccc".*) orelse return error.MissingRosterRow;
    const drawn = (try Lines.at(arena.allocator(), &state, at, 80, .{}, 0)).?;
    try std.testing.expect(for (drawn.segments) |segment| {
        if (std.mem.eql(u8, segment.text, "C")) break true;
    } else false);
    for (0..3) |_| {
        if (std.mem.eql(u8, &state.selected.session, "cccccc")) break;
        _ = try press(&state, .next);
    }
    try expectSelected(&state, "cccccc");
    try expectEffects(&.{.{ .stop = "cccccc".* }}, try press(&state, .stop));

    var rows: [10]Listed = undefined;
    for (&rows, 0..) |*row, n| row.* = session(&[6]u8{ 'r', 'r', 'r', 'r', 'r', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n) }, .{ .label = "R" });
    try expectEffects(&.{.{ .list = .{ .since = testToken(1), .archive = .active } }}, try step(&state, .{ .tick = state.now_ms + list_interval_ms }));
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[0..8], .answer = null } } });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[0..8], .answer = null } } });
    const restart = try step(&state, .{ .list = .{ .page = .{ .rows = rows[8..], .answer = .{ .delta = .full, .since = testToken(2) } } } });
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, restart);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[0..8], .answer = null } } });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[8..], .answer = .{ .delta = .full, .since = testToken(2) } } } });
    try expectEachOnce(&state, &.{ "rrrrr0", "rrrrr1", "rrrrr2", "rrrrr3", "rrrrr4", "rrrrr5", "rrrrr6", "rrrrr7", "rrrrr8", "rrrrr9" });
    for (&rows) |*row| try std.testing.expectEqual(row.state, state.find(row.reference).?.state);
}

test "the overview says when it next needs a tick" {
    var state = try testState();
    defer state.deinit();
    const start = test_now_s * 1000;
    try std.testing.expectEqual(@as(?u64, 0), state.wakeAt());
    _ = try step(&state, .{ .tick = start });
    try std.testing.expectEqual(@as(?u64, null), state.wakeAt());
    const quota = failedRow("q1q1q1", 60, "provider_quota", test_now_s + 300);
    _ = try respond(&state, .full, testToken(1), &.{ retryRow("r1r1r1", "provider_temporary_http_429", 12), quota });
    try std.testing.expectEqual(@as(?u64, start + list_interval_ms), state.wakeAt());
    _ = try step(&state, .{ .tick = start + list_interval_ms });
    try std.testing.expectEqual(@as(?u64, start + 12_000), state.wakeAt());
    _ = try step(&state, .{ .list = .failed });
    _ = try step(&state, .{ .tick = start + 12_000 });
    try std.testing.expect(state.find("r1r1r1".*).?.state == .pending);
    try std.testing.expectEqual(@as(?u64, (test_now_s + 300) * 1000), state.wakeAt());
    _ = try respond(&state, .full, testToken(2), &.{failedRow("q1q1q1", 60, "provider_quota", std.math.maxInt(i64))});
    _ = try step(&state, .{ .tick = start + 16_000 });
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), state.wakeAt());
}

fn activeRosterRetry() !void {
    var state = try testState();
    defer state.deinit();
    const start = test_now_s * 1000;
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, try step(&state, .{ .tick = start }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectEffects(&.{.{ .list = .{ .since = testToken(1), .archive = .active } }}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms + 500 }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectEffects(&.{.{ .list = .{ .since = testToken(1), .archive = .active } }}, try step(&state, .{ .tick = start + 3 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectScreenLine(&state, 0, " + New chat");
    var screen = try Frame.of(&state, 80, 24, .{}, 0);
    defer screen.deinit();
    try expectScreenLine(&state, 2, " ◌ Trace Host shutdown order                                                now");
    try std.testing.expectEqual(Colour.quiet, screen.styleAt(2, 1).?.colour);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 0, " + New chat");
}

fn projectionCase7() !void {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(state.find("c3d4e5".*).?.state == .retrying);
    _ = try step(&state, .{ .tick = (test_now_s + 12) * 1000 });
    const row = state.find("c3d4e5".*).?;
    try std.testing.expectEqual(WorkState{ .pending = .{ .since = test_now_s + 12 } }, row.state);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " ◌ Audit permission paths") != null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(std.mem.endsWith(u8, try segmentText(arena.allocator(), try rowOf(arena.allocator(), &state, "Audit permission paths", 80, .{})), "now "));
}

fn failedRow(ref: *const [6]u8, seconds_ago: u64, code: []const u8, resets_at: ?u64) Listed {
    return session(ref, .{ .failed = .{ .since = test_now_s - seconds_ago, .code = bounded(session_work.max_code_bytes, code), .resets_at = resets_at } }, .{ .label = "Ask the model" });
}

fn retryRow(ref: *const [6]u8, cause: []const u8, due_in_s: u64) Listed {
    return session(ref, .{ .retrying = .{ .since = test_now_s - 5, .due_at_ms = (test_now_s + due_in_s) * 1000, .cause = bounded(session_work.max_code_bytes, cause), .attempt = 1 } }, .{ .label = "Ask the model again" });
}

fn bandOf(rows: []const Listed, login_at: ?u64) !?Band {
    var state = try opened(rows);
    defer state.deinit();
    state.login_at = login_at;
    return band(&state);
}

test "provider bands derive from the same conversation work as rows" {
    const ref = "aaaaaa".*;
    for ([_]Listed{ retryRow(&ref, "provider_temporary_http_429", 10), failedRow(&ref, 10, "provider_quota", test_now_s + 60) }) |listed| {
        var state = try opened(&.{listed});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        try std.testing.expect(band(&state) != null);
        var revision: u64 = 1;
        for ([_]WorkState{ .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .finished = ago(0) } }) |settled| {
            revision += 1;
            _ = try step(&state, .{ .observed = .{ .read_version = testToken(revision), .reference = ref, .work = fixtureWork(.{ .state = settled }), .opening = false } });
            try std.testing.expectEqual(@as(?Band, null), band(&state));
            try std.testing.expectEqual(@as(?u64, null), state.wakeAt());
        }
        for ([_][]const u8{ "provider_quota", "provider_http_401" }) |code| {
            const failed = failedRow(&ref, 0, code, test_now_s + 120);
            revision += 1;
            _ = try step(&state, .{ .observed = .{ .read_version = testToken(revision), .reference = ref, .work = fixtureWork(.{ .state = failed.state }), .opening = false } });
            try std.testing.expect(band(&state) != null);
            try std.testing.expectEqual(@as(?u64, (test_now_s + 120) * 1000), state.wakeAt());
        }
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expect(band(&state) != null);
    }
}

fn projectionCase3() !void {
    const ref = "aaaaaa".*;
    for ([_]u64{ 0, 2 }) |occupied| for ([_]bool{ false, true }) |activity| for ([_]bool{ false, true }) |started| {
        if (occupied == 2 and started) continue;
        const retry = retryRow(&ref, "provider_temporary_http_429", 5);
        var state = try opened(&.{ retry, session("bbbbbb", .{ .finished = ago(10) }, .{}) });
        defer state.deinit();
        _ = try step(&state, .{ .host = .{ .instance = testToken(0).instance, .started_at = test_now_s, .slots = 2, .slots_in_use = occupied } });
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = (test_now_s + 5) * 1000 });
        try std.testing.expectEqual(Kind.pending, classOf(&state, state.find(ref).?).kind);
        // An equal revision cannot replace the old snapshot before the Host publishes the crossing.
        const due = retry.state.asOf(state.now_ms);
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(1), .reference = ref, .work = fixtureWork(.{ .state = due }), .opening = false } });
        _ = try respond(&state, .changed, testToken(1), &.{retry});
        // The row's work is the one observed fact: it reads pending in its mark, its count and its order alike.
        try std.testing.expectEqual(@as(u32, 1), state.summary.counts.queued);
        try std.testing.expectEqual(@as(u32, 0), state.summary.counts.working);
        const served: WorkState = if (started) .{ .working = .{ .since = test_now_s + 5 } } else due;
        if (activity) {
            _ = try step(&state, .{ .observed = .{ .read_version = testToken(2), .reference = ref, .work = fixtureWork(.{ .state = served }), .opening = false } });
        } else {
            _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
            const listed = session(&ref, served, .{});
            _ = try respond(&state, .changed, testToken(2), &.{listed});
        }
        if (started) {
            try std.testing.expectEqual(@as(u32, 1), state.summary.counts.working);
            try std.testing.expectEqualStrings(&ref, &state.rows.items[state.order.items[0]].reference);
        } else {
            try std.testing.expectEqual(@as(u32, 1), state.summary.counts.queued);
            try std.testing.expectEqualStrings("aaaaaa", &state.rows.items[state.order.items[0]].reference);
        }
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(if (started) Kind.working else Kind.pending, classOf(&state, state.find(ref).?).kind);
    };
}

test "the band derives provider trouble from rows, in priority order" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Done" });
    for ([_][]const u8{ "provider_http_401", "provider_sign_in_required", "provider_sign_in_refresh_token_expired" }) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = pn(.codex) }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ session("ffffff", .{ .finished = ago(30) }, .{}), failedRow("aaaaaa", 60, "provider_http_401", null) }, null));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_http_401", null) }, test_now_s - 30));
    try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = pn(.codex) }, (try bandOf(&.{ done, failedRow("aaaaaa", 10, "provider_http_401", null) }, test_now_s - 30)).?);
    try std.testing.expectEqual(Band{ .trouble = .api_key, .provider = pn(.codex) }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, failure_class.api_key_rejected, null) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota, .resets_at = test_now_s + 1200, .provider = pn(.codex) }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 1200) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota, .provider = pn(.codex) }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_plan", test_now_s) }, null));
    try std.testing.expectEqual(Band{ .trouble = .rate_limit, .sessions = 2 }, (try bandOf(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20), retryRow("cccccc", "provider_temporary_error", 20) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{retryRow("aaaaaa", "provider_temporary_error", 10)}, null));
    var state = try opened(&.{retryRow("aaaaaa", "provider_temporary_http_429", 10)});
    defer state.deinit();
    state.now_ms = (test_now_s + 10) * 1000;
    try std.testing.expectEqual(@as(?Band, null), band(&state));
    try std.testing.expectEqual(failure_class.Trouble.sign_in, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), failedRow("bbbbbb", 90, "provider_http_401", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
    try std.testing.expectEqual(failure_class.Trouble.quota, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
}

test "a quota reset far in the future still draws its band" {
    var state = try opened(&.{failedRow("q1q1q1", 60, "provider_quota", 100_000_000_000_000_000)});
    defer state.deinit();
    try expectScreenLine(&state, 0, " Quota used up. Resets in 999d.");
}

test "a quota band adds where its provider raises the limit only when the line holds it whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const usage = "Manage usage: https://chatgpt.com/settings/usage";
    const managed = "Quota used up. " ++ usage;
    const Case = struct { provider: Provider, resets_at: ?u64 = null, width: u16, shown: []const u8 };
    for ([_]Case{
        .{ .provider = pn(.chatgpt), .width = 200, .shown = managed },
        .{ .provider = pn(.chatgpt), .width = managed.len + 2, .shown = managed },
        .{ .provider = pn(.chatgpt), .width = managed.len + 1, .shown = "Quota used up." },
        .{ .provider = pn(.chatgpt), .width = 60, .shown = "Quota used up." },
        .{ .provider = pn(.chatgpt), .width = 40, .shown = "Quota used up." },
        .{ .provider = pn(.chatgpt), .resets_at = test_now_s + 1200, .width = 200, .shown = "Quota used up. Resets in 20m. " ++ usage },
        .{ .provider = pn(.chatgpt), .resets_at = test_now_s + 1200, .width = 60, .shown = "Quota used up. Resets in 20m." },
        .{ .provider = pn(.openai), .resets_at = test_now_s + 59, .width = 200, .shown = "Quota used up. Resets in under a minute." },
        .{ .provider = pn(.codex), .width = 200, .shown = "Quota used up." },
        .{ .provider = pn(.openai), .resets_at = test_now_s + 1200, .width = 200, .shown = "Quota used up. Resets in 20m." },
    }) |case| {
        var state = try opened(&.{session("q1q1q1", .{ .failed = .{ .since = test_now_s - 60, .code = bounded(session_work.max_code_bytes, "provider_quota"), .resets_at = case.resets_at } }, .{ .provider = case.provider })});
        defer state.deinit();
        const text = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, case.width, .{}));
        try std.testing.expectEqualStrings(case.shown, std.mem.trim(u8, text, " "));
    }
}

test "the overview's rows draw each band" {
    for ([_][]const u8{ "provider_http_401", "provider_quota", "provider_temporary_http_429" }) |cause| {
        var state = try opened(&.{failedRow("aaaaaa", 60, cause, test_now_s + 600)});
        defer state.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const segments = try headerSegments(arena.allocator(), &state, 80, .{});
        if (segments.len == 0) continue;
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, " + New chat") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Host stopped") == null);
        try std.testing.expectEqual(Background.band, segments[0].style.background);
    }
}

test "the overview's rows draw an empty Store" {
    var state = try opened(&.{});
    defer state.deinit();
    for ([_]u16{ 40, 80, 200 }) |width| {
        const text = try screenText(&state, width, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.startsWith(u8, text, " + New chat") and std.mem.indexOf(u8, text, "Archived\n") != null);
        try std.testing.expectEqualStrings("", footerRight(&state));
        try std.testing.expect(std.mem.indexOf(u8, text, "new Session ·") == null);
    }
}

test "the overview's rows draw twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_]u16{ 80, 200 }) |width| {
        var shown = try Frame.of(&state, width, 60, .{}, 0);
        defer shown.deinit();
        try std.testing.expectEqual(@as(usize, mixed.len + 2), shown.list.len);
        const text = try shown.text();
        defer std.testing.allocator.free(text);
        for (mixed) |row| if (row.label) |label| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, label));
        for (shown.list) |line| {
            const text_ = try segmentText(shown.arena.allocator(), line);
            try std.testing.expect(session_line.cells(text_, .unicode) <= width);
        }
    }
}

test "the overview's rows stay ASCII and keep semantic roles without colour" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "résumé the naïve café ☕ notes" } });
    for ([_]u16{ 80, 200 }) |width| {
        var shown = try Frame.of(&state, width, 60, .{ .unicode = false, .depth = .none }, 0);
        defer shown.deinit();
        const text = try shown.text();
        defer std.testing.allocator.free(text);
        for (text) |byte| try std.testing.expect(byte < 0x80 and (byte >= 0x20 or byte == '\n'));
        try std.testing.expect(std.mem.indexOf(u8, text, "r?sum? the na?ve caf? ? notes") != null);
        var direct = try Frame.of(&state, width, 60, .{ .unicode = false }, 0);
        defer direct.deinit();
        try std.testing.expectEqualDeep(direct.list, shown.list);
    }
}

test "the overview's rows fit any screen size" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_][2]u16{ .{ 0, 0 }, .{ 8, 2 }, .{ 20, 5 }, .{ 40, 10 }, .{ 119, 30 }, .{ 2048, 24 }, .{ 4096, 6 } }) |size| {
        const text = try screenText(&state, size[0], size[1], .{});
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, .unicode) <= size[0]);
    }
}

fn repeated(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime {
        var bytes: [text.len * count]u8 = undefined;
        for (0..count) |at| @memcpy(bytes[at * text.len ..][0..text.len], text);
        const result = bytes;
        return &result;
    }
}

test "bidi controls in a title cannot reorder a row" {
    const bidi = "\u{202e}\u{2066}\u{200f}\u{061c}";
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(5) }, .{ .label = "Pay " ++ bidi ++ "evil" }),
        session("t7v8w9", .{ .stopped = .{ .since = test_now_s - 30, .cause = .stop } }, .{ .label = "Next", .first = .{ .position = 1, .admission = 2, .sender = "k7m2qx".*, .content = test_first } }),
    });
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Pay ????evil") != null);
    for ([_][]const u8{ "\u{202e}", "\u{2066}", "\u{200f}", "\u{061c}" }) |control| try std.testing.expect(std.mem.indexOf(u8, text, control) == null);
}

test "untrusted text cannot reach the terminal as control bytes" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(5) }, .{ .label = "Bell\x07 and \x1b[31mred" })});
    defer state.deinit();
    try expectScreenLine(&state, 2, " ◜ Bell? and ?[31mred");
}

test "overview idle rows never fold" {
    var rows: [8]Listed = undefined;
    for (&rows, 0..) |*row, n| row.* = session(&[6]u8{ 'i', 'i', 'i', 'i', 'i', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n * 60) }, .{ .label = "Wait for review" });
    var state = try opened(&rows);
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, text, "○ Wait for review"));
    try std.testing.expect(std.mem.indexOf(u8, text, " more") == null);
}

test "numbers group the Indian way" {
    for ([_]struct { u64, []const u8 }{
        .{ 0, "0" },
        .{ 999, "999" },
        .{ 1_000, "1,000" },
        .{ 99_999, "99,999" },
        .{ 1_00_000, "1,00,000" },
        .{ 12_34_567, "12,34,567" },
        .{ 1_00_00_000, "1,00,00,000" },
        .{ std.math.maxInt(u64), "1,84,46,74,40,73,70,95,51,615" },
    }) |case| {
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(case[1], grouped(&buffer, case[0]));
    }
}

test "the skin follows the terminal's background, night when it gave none" {
    try std.testing.expectEqual(Skin.night, (Caps{}).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 0x12, 0x18, 0x33 } }).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 0, 0, 0 } }).skin());
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 0xf3, 0xee, 0xe2 } }).skin());
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 0xff, 0xff, 0xff } }).skin());
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 128, 128, 128 } }).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 127, 127, 127 } }).skin());
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 0, 200, 0 } }).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 0, 0, 255 } }).skin());
}

test "the status bar says the Upgrade at work, else the newest notice, else an Upgrade that holds, else an unconfirmed send" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(10) }, .{})});
    defer state.deinit();
    var buffer: StatusBuffer = undefined;
    try std.testing.expectEqual(null, statusLine(&state, .{}, &buffer));
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    _ = try step(&state, .{ .unconfirmed = .{ .reference = "k7m2qx".*, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    _ = try step(&state, .start_upgrade);
    try expectStatus(&state, "Checking for updates…", .normal);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    try expectStatus(&state, "Preparing Upgrade · no Hosts running · esc cancels", .normal);
    state.say(.attention, "Select a chat first.", .{});
    try expectStatus(&state, "Preparing Upgrade · no Hosts running · esc cancels", .normal);
    _ = try press(&state, .next);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 0 }, .restarted = false } }, .outcome = .compatible } } });
    try std.testing.expect(footerNotice(&state) == null);
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    _ = try press(&state, .next);
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    _ = try press(&state, .next);
    try expectStatus(&state, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention);
    var ascii: StatusBuffer = undefined;
    try std.testing.expectEqualStrings("Rui 0.61.0 installed - restart rui to continue - your draft is kept until you leave", statusLine(&state, .{ .unicode = false }, &ascii).?.say.words);
}

test "SUI-172 the status rows write the sign from the line's tone: an unconfirmed send carries it in no words, the Upgrade that holds draws none" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(10) }, .{})});
    defer state.deinit();
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    _ = try step(&state, .{ .unconfirmed = .{ .reference = "k7m2qx".*, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
    var buffer: StatusBuffer = undefined;
    const unconfirmed = statusLine(&state, .{}, &buffer).?;
    try std.testing.expect(unconfirmed.say.tone == .attention);
    try std.testing.expect(!std.mem.startsWith(u8, unconfirmed.say.words, "!"));
    var drawn: [max_status_bytes]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, unconfirmed.drawn(&drawn), state_marks.attention_sign));
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    const holds = statusLine(&state, .{}, &buffer).?;
    try std.testing.expect(holds.say.tone == .quiet and holds.colour == .attention);
    try std.testing.expect(std.mem.startsWith(u8, holds.drawn(&drawn), "Rui 0.61.0"));
}

test "the status rows above the Footer say the status bar's line" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(10) }, .{})});
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    _ = try step(&state, .{ .unconfirmed = .{ .reference = "k7m2qx".*, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
    const unconfirmed = try segmentText(arena.allocator(), (try noticeSegments(arena.allocator(), &state, 120, .{})).?);
    try std.testing.expect(std.mem.startsWith(u8, unconfirmed, " ! Not confirmed · rui request recover " ++ key));
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    const upgrading = try segmentText(arena.allocator(), (try noticeSegments(arena.allocator(), &state, 120, .{ .unicode = false })).?);
    try std.testing.expect(std.mem.startsWith(u8, upgrading, " Preparing Upgrade - no Hosts running - esc cancels"));
}

fn expectStatus(state: *const State, text: []const u8, colour: Colour) !void {
    var buffer: StatusBuffer = undefined;
    const line = statusLine(state, .{}, &buffer).?;
    var drawn: [max_status_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(text, line.drawn(&drawn));
    try std.testing.expectEqual(colour, line.colour);
}

fn segmentText(arena: Allocator, segments: []const Segment) ![]const u8 {
    var texts = try arena.alloc([]const u8, segments.len);
    for (segments, 0..) |segment, n| texts[n] = segment.text;
    return std.mem.concat(arena, u8, texts);
}

test "SUI-132 overview removal clears activation and arrows re-enter current rows" {
    const rows = [_]Listed{
        session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" }),
        session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" }),
        session("cccccc", .{ .finished = ago(3) }, .{ .label = "third" }),
    };
    for ([_]bool{ false, true }) |wide| for (0..3) |removed_at| for ([_]Action{ .previous, .next }) |direction| {
        var state = try opened(&rows);
        defer state.deinit();
        const removed = rows[removed_at];
        _ = try step(&state, .{ .conversation = removed.reference });
        state.selected = .{ .session = removed.reference };
        var archived = removed;
        archived.archive_state = .archived;
        archived.archive_seq = 10;
        _ = try refresh(&state, .changed, testToken(2), &.{archived});
        try std.testing.expect(state.selected == .none);
        try std.testing.expectEqual(null, state.selectedRow());
        try std.testing.expectEqualStrings(&removed.reference, &state.conversing.?);
        try std.testing.expectEqual(null, Lines.highlighted(&state, true));
        var effects = try submit(&state);
        try std.testing.expectEqual(@as(usize, 0), effects.len);
        effects = try press(&state, .open_session);
        try std.testing.expectEqual(@as(usize, 0), effects.len);
        effects = try press(&state, .archive);
        try std.testing.expectEqual(@as(usize, 0), effects.len);
        try expectNotice(&state, state_marks.attention_sign ++ no_selection);
        _ = try step(&state, .{ .input = .{ .wide = wide, .key = .{ .action = direction } } });
        if (direction == .previous) {
            try std.testing.expect(state.selected == .sessions);
        } else if (removed_at != 0) {
            try expectSelected(&state, &rows[0].reference);
        } else {
            try expectSelected(&state, &rows[1].reference);
        }
    };

    // Further authoritative removals cannot make Down target a stale Session.
    var removals = try opened(&rows);
    defer removals.deinit();
    removals.selected = .{ .session = rows[1].reference };
    var removed_b = rows[1];
    removed_b.archive_state = .archived;
    removed_b.archive_seq = 13;
    _ = try refresh(&removals, .changed, testToken(2), &.{removed_b});
    var removed_c = rows[2];
    removed_c.archive_state = .archived;
    removed_c.archive_seq = 14;
    _ = try refresh(&removals, .changed, testToken(3), &.{removed_c});
    try std.testing.expect(removals.selected == .none);
    _ = try press(&removals, .next);
    try expectSelected(&removals, &rows[0].reference);

    // With no conversation open, Enter on the cleared selection cannot create a New Chat.
    var only = try opened(rows[0..1]);
    defer only.deinit();
    only.selected = .{ .session = rows[0].reference };
    _ = try refresh(&only, .full, testToken(2), &.{});
    try std.testing.expect(only.selected == .none);
    try expectEffects(&.{}, try submit(&only));
    try std.testing.expectEqual(@as(usize, 0), only.request_count);
    _ = try press(&only, .next);
    try std.testing.expect(only.selected == .settings);

    // A queued wide preview for the removed exact target cannot activate the fallback row.
    var preview = try opened(&rows);
    defer preview.deinit();
    _ = try step(&preview, .{ .conversation = "aaaaaa".* });
    preview.selected = .{ .session = rows[0].reference };
    _ = try step(&preview, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
    try expectSelected(&preview, &rows[1].reference);
    var archived = rows[1];
    archived.archive_state = .archived;
    archived.archive_seq = 11;
    _ = try refresh(&preview, .changed, testToken(2), &.{archived});
    try expectEffects(&.{}, try step(&preview, .{ .list_settled = .{ .wide = true, .focused = true } }));
    try std.testing.expectEqualStrings("aaaaaa", &preview.conversing.?);

    // Re-entry into the Archived view still retains and renders the changed Session.
    var views = try opened(&rows);
    defer views.deinit();
    archived = rows[1];
    archived.archive_state = .archived;
    archived.archive_seq = 10;
    _ = try refresh(&views, .changed, testToken(2), &.{archived});
    var effects: Effects = .{};
    try changeArchiveView(&views, .archived, &effects);
    const read = effects.slice()[0].read_archived;
    _ = try step(&views, .{ .archived = .{ .read = read, .page = .{ .since = testToken(0), .rows = &.{archived}, .first = archived.archive_seq, .last = archived.archive_seq, .more_above = false, .more_below = false } } });
    try std.testing.expect(views.find(archived.reference) != null);
    try std.testing.expect(views.selected == .new_session);

    // Window trim retains the selected record's archive sequence. A capped head is not evidence about older rows.
    _ = try step(&views, .{ .conversation = rows[0].reference });
    views.selected = .{ .session = archived.reference };
    try std.testing.expect(views.find(archived.reference).?.listed);
    var newer = rows[0];
    newer.archive_state = .archived;
    newer.archive_seq = 20;
    var reanchor_effects: Effects = .{};
    readArchived(&views, &reanchor_effects, .head);
    const reanchor = reanchor_effects.slice()[0].read_archived;
    try std.testing.expect(reanchor.from == .head);
    _ = try step(&views, .{ .archived = .{ .read = reanchor, .page = .{ .since = testToken(0), .rows = &.{newer}, .first = 20, .last = 20, .more_above = false, .more_below = true } } });
    try std.testing.expectEqualStrings(&archived.reference, &views.selected.session);
    try std.testing.expect(views.find(archived.reference) != null);

    // The next page starts from the replacement head boundary and its covered range resolves the trimmed ref.
    try std.testing.expectEqual(@as(?u64, 20), archivedBounds(&views).last);
    var middle = session("dddddd", .{ .finished = ago(4) }, .{ .label = "middle archived" });
    middle.archive_state = .archived;
    middle.archive_seq = 14;
    var tail = session("eeeeee", .{ .finished = ago(5) }, .{ .label = "tail archived" });
    tail.archive_state = .archived;
    tail.archive_seq = 11;
    const bounds = archivedBounds(&views);
    try std.testing.expectEqual(@as(?u64, 20), bounds.last);
    var next_page: Effects = .{};
    readArchived(&views, &next_page, .{ .below = bounds.last.? });
    try std.testing.expectEqual(@as(usize, 1), next_page.len);
    try std.testing.expect(next_page.items[0] == .read_archived);
    try std.testing.expect(next_page.items[0].read_archived.from == .below);
    try std.testing.expectEqual(@as(u64, 20), next_page.items[0].read_archived.from.below);
    const below_read = next_page.items[0].read_archived;
    _ = try step(&views, .{ .archived = .{ .read = below_read, .page = .{ .since = testToken(0), .rows = &.{ middle, tail }, .first = 14, .last = 11, .more_above = false, .more_below = false } } });
    try std.testing.expect(views.selected == .none);
    try std.testing.expectEqualStrings("aaaaaa", &views.conversing.?);
    try expectEffects(&.{}, try submit(&views));
    try expectEffects(&.{}, try press(&views, .open_session));
    try expectEffects(&.{}, try press(&views, .archive));
    try expectNotice(&views, state_marks.attention_sign ++ no_selection);

    // A completed newer-page answer also proves omissions above its newest returned key.
    var above = try opened(&.{});
    defer above.deinit();
    var above_effects: Effects = .{};
    try changeArchiveView(&above, .archived, &above_effects);
    const initial_read = above_effects.slice()[0].read_archived;
    const selected_archived = session("zz0001", .{ .finished = ago(1) }, .{ .archive_state = .archived, .archive_seq = 30 });
    _ = try step(&above, .{ .archived = .{ .read = initial_read, .page = .{ .since = testToken(0), .rows = &.{selected_archived}, .first = 30, .last = 30, .more_above = false, .more_below = false } } });
    above.selected = .{ .session = selected_archived.reference };
    const above_page_row = session("zz0002", .{ .finished = ago(2) }, .{ .archive_state = .archived, .archive_seq = 25 });
    above_effects = .{};
    readArchived(&above, &above_effects, .{ .above = 20 });
    const above_read = above_effects.slice()[0].read_archived;
    _ = try step(&above, .{ .archived = .{ .read = above_read, .page = .{ .since = testToken(0), .rows = &.{above_page_row}, .first = 25, .last = 25, .more_above = false, .more_below = true } } });
    try std.testing.expect(above.selected == .none);

    _ = try press(&views, .previous);
    try std.testing.expect(views.selected == .archived);
    _ = try step(&views, .{ .input = .{ .key = .left } });
    try std.testing.expect(views.selected == .sessions);

    try sUI132RefreshCase();
    try sUI132AdjacentBrowseCase();
    try sUI132ExplicitBrowseCase();
    try sUI132IgnoredPasteBrowseCase();
    try sUI132ArchivedTrimCase();
}

test "a pressed chat dropped on the other tab archives or restores it, and no other drop does" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    const b = session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" });
    const drops = [_]?Click{ null, .sessions, .archived, .new_session, .settings, .{ .open = a.reference }, .{ .open = b.reference } };
    for ([_]bool{ false, true }) |archived_row| for (drops) |over| {
        var state = try opened(&.{ a, b });
        defer state.deinit();
        if (archived_row) state.rows.items[0].archive_state = .archived;
        _ = try step(&state, .{ .clicked = .{ .target = .{ .open = a.reference } } });
        // A held pointer that has not left the pressed row is still a click.
        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .{ .open = a.reference }, .phase = .held } }));
        try std.testing.expect(!state.carry.carrying);
        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .{ .open = b.reference }, .phase = .held } }));
        try std.testing.expect(state.carry.carrying);
        // Coming back over the pressed row keeps carrying it.
        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .{ .open = a.reference }, .phase = .held } }));
        try std.testing.expect(state.carry.carrying);
        const target: Click = if (archived_row) .sessions else .archived;
        try std.testing.expectEqual(target, state.carry.dropTarget(&state).?);
        const takes = over != null and std.meta.eql(over.?, target);
        const effects = try step(&state, .{ .pointer = .{ .over = over, .phase = .released } });
        if (takes)
            try expectEffects(&.{.{ .archive = .{ .reference = a.reference, .archived = !archived_row } }}, effects)
        else
            try expectEffects(&.{}, effects);
        try std.testing.expectEqual(Carry{}, state.carry);
    };
}

test "a chat already being archived takes no drop, as Alt-A refuses it" {
    var archiving = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    archiving.archive_state = .archiving;
    const b = session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" });
    var state = try opened(&.{ archiving, b });
    defer state.deinit();
    try std.testing.expectEqual(ArchiveState.archiving, state.find(archiving.reference).?.archive_state);
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = archiving.reference } } });
    _ = try step(&state, .{ .pointer = .{ .over = .archived, .phase = .held } });
    try std.testing.expect(state.carry.carrying and state.carry.dropTarget(&state) == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ((try controls(arena.allocator(), &state, 38, .{}))[1].segments) |segment| try std.testing.expectEqual(Background.ground, segment.style.background);
    for ([_]Click{ .archived, .sessions }) |over| {
        _ = try step(&state, .{ .clicked = .{ .target = .{ .open = archiving.reference } } });
        _ = try step(&state, .{ .pointer = .{ .over = over, .phase = .held } });
        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = over, .phase = .released } }));
    }
}

test "a press refused while a chat is being created carries nothing" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    var state = try opened(&.{a});
    defer state.deinit();
    _ = try step(&state, .{ .clicked = .{ .target = .new_session } });
    try std.testing.expect(state.creating());
    _ = try step(&state, .{ .clicked = .{ .target = .{ .open = a.reference } } });
    try std.testing.expect(state.carry.pressed == null);
    _ = try step(&state, .{ .pointer = .{ .over = .archived, .phase = .held } });
    try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .archived, .phase = .released } }));
}

test "a carry ends without a request on a free move, a key, another click or a release before any drag" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    const b = session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" });
    const Ending = enum { free, key, click, released_in_row, no_press };
    for (std.enums.values(Ending)) |ending| {
        var state = try opened(&.{ a, b });
        defer state.deinit();
        if (ending != .no_press) _ = try step(&state, .{ .clicked = .{ .target = .{ .open = a.reference } } });
        if (ending != .released_in_row) _ = try step(&state, .{ .pointer = .{ .over = .archived, .phase = .held } });
        try std.testing.expectEqual(ending != .no_press and ending != .released_in_row, state.carry.carrying);
        switch (ending) {
            .free => try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .archived, .phase = .free } })),
            .key => _ = try step(&state, .{ .input = .{ .key = .{ .action = .select_next } } }),
            .click => _ = try step(&state, .{ .clicked = .{ .target = .new_session } }),
            .released_in_row => try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .{ .open = a.reference }, .phase = .released } })),
            .no_press => {},
        }
        try std.testing.expect(!state.carry.carrying);
        try std.testing.expect(state.carry.pressed == null);
        // Nothing carried, so a release over Archived asks for nothing.
        try expectEffects(&.{}, try step(&state, .{ .pointer = .{ .over = .archived, .phase = .released } }));
        try std.testing.expect(state.find(a.reference).?.archive_state == .active);
    }
}

test "the tab that takes a carried chat is shaded, strongly while the pointer holds it there, and the tabs line says so" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    for ([_]bool{ false, true }) |archived_row| for ([_]bool{ false, true }) |over_target| for ([_]bool{ false, true }) |unicode_caps| {
        var state = try opened(&.{a});
        defer state.deinit();
        if (archived_row) state.rows.items[0].archive_state = .archived;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const caps: Caps = .{ .unicode = unicode_caps };
        _ = try step(&state, .{ .clicked = .{ .target = .{ .open = a.reference } } });
        const target: Click = if (archived_row) .sessions else .archived;
        _ = try step(&state, .{ .pointer = .{ .over = if (over_target) target else null, .phase = .held } });
        const tabs = (try controls(arena.allocator(), &state, 38, caps))[1].segments;
        const text = try segmentText(arena.allocator(), tabs);
        try std.testing.expect(std.mem.indexOf(u8, text, if (unicode_caps) "Archived  · drop here" else "Archived  . drop here") != null);
        const shaded = try styleOf(tabs, if (archived_row) "Chats" else "Archived");
        try std.testing.expectEqual(if (over_target) Background.selection else Background.hover, shaded.background);
        try std.testing.expectEqual(Colour.strong, shaded.colour);
        const other = try styleOf(tabs, if (archived_row) "Archived" else "Chats");
        try std.testing.expectEqual(Background.ground, other.background);
        // Only the tab's own word is shaded, never the gap before it.
        for (tabs) |segment| if (segment.style.background != .ground) try std.testing.expectEqualStrings(if (archived_row) "Chats" else "Archived", segment.text);
        _ = try step(&state, .{ .pointer = .{ .over = null, .phase = .free } });
        const after = try segmentText(arena.allocator(), (try controls(arena.allocator(), &state, 38, caps))[1].segments);
        try std.testing.expect(std.mem.indexOf(u8, after, "drop here") == null);
    };
}

test "archive row marker follows the whole filter and row-state domain" {
    for ([_]ArchiveFilter{ .active, .archived, .all }) |filter| for ([_]ArchiveState{ .active, .archived }) |archive| for ([_]bool{ false, true }) |selected| for ([_]u16{ 40, 46, 140 }) |width| for ([_]bool{ false, true }) |unicode_marks| {
        var state = try opened(&.{session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "Archive audit" })});
        defer state.deinit();
        state.archive = filter;
        state.rows.items[0].archive_state = archive;
        state.selected = if (selected) .{ .session = "aaaaaa".* } else .new_session;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const segments = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{ .unicode = unicode_marks }, 0)).?.segments;
        const text = try segmentText(arena.allocator(), segments);
        const expected = archive == .archived and filter != .archived;
        const marker = if (unicode_marks) " · archived" else " . archived";
        try std.testing.expectEqual(@as(usize, @intFromBool(expected)), std.mem.count(u8, text, marker));
        try std.testing.expect(std.mem.indexOf(u8, text, "[Archived]") == null);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, text, " "), "Archive audit"));
        try std.testing.expectEqual(selected, (try styleOf(segments, "Archive audit")).bold);
        if (expected) {
            try std.testing.expect(std.mem.indexOf(u8, text, if (unicode_marks) "Archive audit · archived" else "Archive audit . archived") != null);
            const style = try styleOf(segments, "archived");
            try std.testing.expectEqual(Colour.quiet, style.colour);
            try std.testing.expect(!style.bold);
        }
    };
}

test "archive row marker survives a clipped name without overlapping the age" {
    var state = try opened(&.{session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "A long archived Session name that needs clipping" })});
    defer state.deinit();
    state.archive = .all;
    state.rows.items[0].archive_state = .archived;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try expectRow((try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 40, .{}, 0)).?.segments, 40, &.{ .{ "A long archived Sess…", .strong }, .{ "· archived", .quiet }, .{ "now", .quiet } });
}

const window_test_page = 5;

/// The Host for the window tests: `host` holds archived Sessions newest first, and an Archived read answers
/// up to `rows.len` rows the way the Host does: from the head, strictly below a key, or the nearest rows above one.
fn hostPage(host: []const Listed, cursor: session_list.ArchivedCursor, rows: []Listed) ArchivedPage {
    var from: usize = 0;
    var to: usize = 0;
    switch (cursor) {
        .head => to = @min(host.len, rows.len),
        .below => |key| {
            while (from < host.len and host[from].archive_seq.? >= key) from += 1;
            to = @min(host.len, from + rows.len);
        },
        .above => |key| {
            while (to < host.len and host[to].archive_seq.? > key) to += 1;
            from = to -| rows.len;
        },
        .tail => unreachable,
    }
    const count = to - from;
    @memcpy(rows[0..count], host[from..to]);
    return .{
        .since = testToken(0),
        .rows = rows[0..count],
        .first = if (count != 0) host[from].archive_seq else null,
        .last = if (count != 0) host[to - 1].archive_seq else null,
        .more_above = from > 0,
        .more_below = to < host.len,
    };
}

/// Serves every Archived read the effects ask for, from `host`, a page of `size` rows, until none is left.
fn serveWindowWith(comptime size: usize, state: *State, host: []const Listed, first: Effects) !void {
    var effects = first;
    for (0..8) |_| {
        var next: Effects = .{};
        var served = false;
        for (effects.slice()) |effect| switch (effect) {
            .read_archived => |read| {
                var buffer: [size]Listed = undefined;
                next = try step(state, .{ .archived = .{ .read = read, .page = hostPage(host, read.from, &buffer) } });
                served = true;
            },
            else => {},
        };
        if (!served) return;
        effects = next;
    }
    return error.TestWindowDidNotSettle;
}

fn serveWindow(state: *State, host: []const Listed, first: Effects) !void {
    return serveWindowWith(window_test_page, state, host, first);
}

/// The held Archived window equals the Host's rows over the window's key range (all of the Host's rows
/// from the head), and says whether the Host holds anything older.
fn expectWindowMatchesHost(state: *const State, host: []const Listed) !void {
    const Held = struct { reference: Reference, seq: u64 };
    const bounds = archivedBounds(state);
    if (bounds.first == null and !state.archived.at_head) return;
    var held: [512]Held = undefined;
    var held_count: usize = 0;
    for (state.rows.items) |row| {
        if (!row.listed or row.archive_state != .archived) continue;
        held[held_count] = .{ .reference = row.reference, .seq = row.archive_seq.? };
        held_count += 1;
    }
    // The window's keys: from its last row up to its first, or to the Host's newest while it is at the head.
    const low = bounds.last orelse 0;
    const high = if (state.archived.at_head) std.math.maxInt(u64) else bounds.first orelse 0;
    var expected_count: usize = 0;
    for (host) |row| {
        const key = row.archive_seq.?;
        if (key >= low and key <= high) expected_count += 1;
    }
    try std.testing.expectEqual(expected_count, held_count);
    for (host) |row| {
        const key = row.archive_seq.?;
        if (key < low or key > high) continue;
        var found = false;
        for (held[0..held_count]) |got| {
            if (std.mem.eql(u8, &got.reference, &row.reference) and got.seq == key) found = true;
        }
        try std.testing.expect(found);
    }
    if (bounds.last) |last| {
        var older = false;
        for (host) |row| {
            if (row.archive_seq.? < last) older = true;
        }
        try std.testing.expectEqual(older, state.archived.more_below);
    }
}

test "archived window matches a fresh read over the whole domain" {
    var refs: [40][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "w{d:0>5}", .{at}) catch unreachable;
    // Host rows newest first: archive keys 20 down to 1 under w00001..w00020.
    var host_buffer: [40]Listed = undefined;
    for (0..20) |index| {
        const key: u64 = 20 - index;
        host_buffer[index] = session(&refs[key], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    for ([_]bool{ false, true }) |scrolled| for ([_]u8{ 0, 1, 2, 3, 4 }) |scenario| {
        var host: [40]Listed = host_buffer;
        var count: usize = 20;
        var state = try opened(&.{});
        defer state.deinit();
        state.size = .{ .width = 80, .height = 2 };
        var effects: Effects = .{};
        try changeArchiveView(&state, .archived, &effects);
        try serveWindow(&state, host[0..count], effects);
        try expectWindowMatchesHost(&state, host[0..count]);
        var token: u64 = 2;
        if (scrolled) for ([_]usize{ 4, 9 }) |at| {
            state.selected = .{ .session = host[at].reference };
            const ticked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
            try serveWindow(&state, host[0..count], ticked);
            try expectWindowMatchesHost(&state, host[0..count]);
        };
        // The change: each scenario touches the window in its own way and answers one roster delta. `inside` is
        // a row the window holds in both modes.
        const inside: usize = if (scrolled) 8 else 2;
        var delta_buffer: [1]Listed = undefined;
        switch (scenario) {
            0 => {
                // newly archived, above the window's first row
                const top = session(&refs[21], .{ .stopped = .{ .since = test_now_s + 1, .cause = .stop } }, .{ .label = "new", .archive_state = .archived, .archive_seq = 21 });
                std.mem.copyBackwards(Listed, host[1 .. count + 1], host[0..count]);
                host[0] = top;
                count += 1;
                delta_buffer[0] = top;
            },
            1 => {
                // unarchived: a held row goes live
                var live = host[inside];
                live.archive_state = .active;
                live.archive_seq = null;
                std.mem.copyForwards(Listed, host[inside .. count - 1], host[inside + 1 .. count]);
                count -= 1;
                delta_buffer[0] = live;
            },
            2 => {
                // changed in place: a held row gets a new label
                var changed = host[inside];
                changed.label = "renamed";
                host[inside] = changed;
                delta_buffer[0] = changed;
            },
            3 => {
                // below the window: the oldest Host row changes, and the window does not hold it
                var older = host[count - 1];
                older.label = "older";
                host[count - 1] = older;
                delta_buffer[0] = older;
            },
            4 => {
                // archiving: a live Session with a pending archive is roster, not window
                delta_buffer[0] = session(&refs[30], .{ .stopping = .{ .since = test_now_s } }, .{ .label = "archiving", .archive_state = .archiving, .archive_seq = 30 });
            },
            else => unreachable,
        }
        const ticked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        try serveWindow(&state, host[0..count], ticked);
        token += 1;
        const delta = try respond(&state, .changed, testToken(token), delta_buffer[0..1]);
        try serveWindow(&state, host[0..count], delta);
        try expectWindowMatchesHost(&state, host[0..count]);
    };
}

fn lineRead(line: FirstLineRead) bool {
    return switch (line) {
        .read => true,
        else => false,
    };
}

/// Expects one `read_first_lines` read per `expected` reference, in order, and no other reads.
fn expectLineReads(effects: Effects, expected: []const Reference) !void {
    var seen: usize = 0;
    for (effects.slice()) |effect| switch (effect) {
        .read_first_lines => |reads| for (reads.slice()) |read| {
            try std.testing.expect(seen < expected.len);
            try std.testing.expectEqualSlices(u8, &expected[seen], &read.reference);
            seen += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(expected.len, seen);
}

test "archived window reads the line of a window row that has none, once, and drops the read when the row leaves" {
    var host: [2]Listed = undefined;
    host[0] = session("w00010", .{ .stopped = .{ .since = test_now_s - 10, .cause = .stop } }, .{ .archive_state = .archived, .archive_seq = 10, .first = .{ .position = 0, .admission = 10, .sender = null, .content = null, .line = "inline line" } });
    host[1] = session("w00009", .{ .stopped = .{ .since = test_now_s - 9, .cause = .stop } }, .{ .archive_state = .archived, .archive_seq = 9, .first = .{ .position = 3, .admission = 9, .sender = null, .content = test_first } });
    var buffer: [window_test_page]Listed = undefined;

    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    const answered = try step(&state, .{ .archived = .{ .read = effects.slice()[0].read_archived, .page = hostPage(&host, .head, &buffer) } });
    // Only the window row with content and no inline line reads; the inline row has its line already.
    try expectLineReads(answered, &.{"w00009".*});
    try std.testing.expect(lineRead(state.find("w00010".*).?.line));
    try std.testing.expectEqual(FirstLineRead.requested, state.find("w00009".*).?.line);
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "w00009".*, .admission = 9, .line = "parts line" } }));
    try std.testing.expect(lineRead(state.find("w00009".*).?.line));

    // A row that leaves the window while its read is pending drops the read: its late answer is not kept.
    var moved = try opened(&.{});
    defer moved.deinit();
    moved.size = .{ .width = 80, .height = 2 };
    var moved_effects: Effects = .{};
    try changeArchiveView(&moved, .archived, &moved_effects);
    const pending = try step(&moved, .{ .archived = .{ .read = moved_effects.slice()[0].read_archived, .page = hostPage(&host, .head, &buffer) } });
    try expectLineReads(pending, &.{"w00009".*});
    _ = try step(&moved, .{ .tick = moved.now_ms + list_interval_ms });
    var live = [_]Listed{session("w00009", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other" })};
    _ = try respond(&moved, .changed, testToken(2), &live);
    try std.testing.expectEqual(ArchiveState.active, moved.find("w00009".*).?.archive_state);
    try std.testing.expectEqual(FirstLineRead.unread, moved.find("w00009".*).?.line);
    const lines_before = moved.lines.items.len;
    try expectEffects(&.{}, try step(&moved, .{ .first_line = .{ .reference = "w00009".*, .admission = 9, .line = "late answer" } }));
    try std.testing.expectEqual(lines_before, moved.lines.items.len);
    try std.testing.expectEqual(FirstLineRead.unread, moved.find("w00009".*).?.line);
}

test "archived window names a row by the same line the first-line read gives: control bytes and long lines" {
    const long: [300]u8 = @splat('a');
    for ([_][]const u8{ "x\x1b[31my", &long }) |raw| {
        // The Host sends the raw prefix; the window path applies the line rule and cut itself.
        const sent = raw[0..@min(raw.len, session_list.max_first_prefix_bytes)];

        var window = try opened(&.{});
        defer window.deinit();
        window.size = .{ .width = 80, .height = 2 };
        var window_effects: Effects = .{};
        try changeArchiveView(&window, .archived, &window_effects);
        var window_row = [_]Listed{session("w00009", .{ .stopped = .{ .since = test_now_s - 9, .cause = .stop } }, .{ .archive_state = .archived, .archive_seq = 9, .first = .{ .position = 0, .admission = 9, .sender = null, .content = null, .line = sent } })};
        _ = try step(&window, .{ .archived = .{ .read = window_effects.slice()[0].read_archived, .page = .{ .since = testToken(0), .rows = &window_row, .first = 9, .last = 9, .more_above = false, .more_below = false } } });

        // The first-line read of the same Message: the worker's raw line, then the overview's own rule.
        var read = try opened(&.{});
        defer read.deinit();
        read.size = .{ .width = 80, .height = 2 };
        var read_effects: Effects = .{};
        try changeArchiveView(&read, .archived, &read_effects);
        var read_row = [_]Listed{session("w00009", .{ .stopped = .{ .since = test_now_s - 9, .cause = .stop } }, .{ .archive_state = .archived, .archive_seq = 9, .first = .{ .position = 3, .admission = 9, .sender = null, .content = test_first } })};
        _ = try step(&read, .{ .archived = .{ .read = read_effects.slice()[0].read_archived, .page = .{ .since = testToken(0), .rows = &read_row, .first = 9, .last = 9, .more_above = false, .more_below = false } } });
        _ = try step(&read, .{ .first_line = .{ .reference = "w00009".*, .admission = 9, .line = raw } });

        const window_name = window.lineOf(window.find("w00009".*).?).?;
        const read_name = read.lineOf(read.find("w00009".*).?).?;
        try std.testing.expectEqualStrings(read_name, window_name);
        try std.testing.expect(window_name.len <= session_line.max_line_bytes);
    }
}

test "an empty Archived page off the head re-reads the head in a new epoch" {
    var host: [3]Listed = undefined;
    const refs = [_][6]u8{ "e00030".*, "e00029".*, "e00028".* };
    for (&host, refs, 0..) |*row, ref, at| {
        const key: u64 = 30 - @as(u64, @intCast(at));
        row.* = session(&ref, .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var buffer: [window_test_page]Listed = undefined;

    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    _ = try step(&state, .{ .archived = .{ .read = effects.slice()[0].read_archived, .page = hostPage(&host, .head, &buffer) } });
    const epoch = state.archived.epoch;

    // A stale anchor below the window answers with no rows: the Host has nothing for it.
    const stale = try step(&state, .{ .archived = .{ .read = .{ .from = .{ .below = 28 }, .rows = archived_page_rows, .epoch = epoch }, .page = .{ .since = testToken(0), .rows = &.{}, .first = null, .last = null, .more_above = true, .more_below = false } } });
    try std.testing.expectEqual(@as(usize, 1), stale.slice().len);
    const restart = stale.slice()[0].read_archived;
    try std.testing.expectEqual(session_list.ArchivedCursor.head, restart.from);
    try std.testing.expectEqual(epoch +% 1, restart.epoch);
    try std.testing.expect(state.archived.inflight);

    // An empty head answer is taken as the Archived list being empty: no further read.
    const empty_head = try step(&state, .{ .archived = .{ .read = restart, .page = .{ .since = testToken(0), .rows = &.{}, .first = null, .last = null, .more_above = false, .more_below = false } } });
    try std.testing.expectEqual(@as(usize, 0), empty_head.slice().len);
    try std.testing.expect(!state.archived.inflight);
    try std.testing.expect(state.archived.at_head);
}

test "an Archived window row has no mark: its name and age show, and no count reads it" {
    var host: [2]Listed = undefined;
    host[0] = session("w00010", .{ .stopped = .{ .since = test_now_s - 10, .cause = .stop } }, .{ .archive_state = .archived, .archive_seq = 10, .first = .{ .position = 0, .admission = 10, .sender = null, .content = null, .line = "inline line" } });
    host[1] = session("w00009", .{ .failed = .{ .since = test_now_s - 9, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .archive_state = .archived, .archive_seq = 9, .first = .{ .position = 0, .admission = 9, .sender = null, .content = null, .line = "failed line" } });

    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 24 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    // No row draws a work mark: neither the stopped mark nor the failed one.
    try std.testing.expect(std.mem.indexOf(u8, text, marks.get(.stopped).unicode) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, marks.get(.failed).unicode) == null);
    // Each name stays at the text column (3) and the mark cell (1) is blank.
    for ([_][]const u8{ "inline line", "failed line" }) |name| {
        const at = std.mem.indexOf(u8, text, name).?;
        const begin = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |newline| newline + 1 else 0;
        try std.testing.expectEqual(@as(usize, text_column), at - begin);
        try std.testing.expectEqualStrings("  ", text[begin .. begin + mark_column + 1]);
    }
    // The age is the stop time, and the failed row is not counted: Archived rows are never counted.
    try std.testing.expectEqual(Counts{}, state.summary.counts);
    try std.testing.expectEqual(WorkState.stopped, std.meta.activeTag(state.find("w00010".*).?.state));
    try std.testing.expect(session_work.standing(state.find("w00009".*).?.state, false) == .failed);
}

test "archived window scrolls back up after trimming and reads the rows above with an above cursor" {
    var refs: [200][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "a{d:0>5}", .{at}) catch unreachable;
    var host: [200]Listed = undefined;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, host[0..], effects);
    // Scrolling down one row at a time trims the window's top once the selection is three margins deep.
    for (0..150) |_| try serveWindow(&state, host[0..], try selectRowBelow(&state, 1));
    try std.testing.expect(!state.archived.at_head);
    const top = archivedBounds(&state).first.?;
    // Scrolling back up reads the rows above the window, with an above cursor.
    var above: usize = 0;
    for (0..200) |_| {
        if (selectedAt(&state) == 0) break;
        const ticked = try selectRowBelow(&state, -1);
        for (ticked.slice()) |effect| switch (effect) {
            .read_archived => |read| {
                above += @intFromBool(read.from == .above);
                try std.testing.expect(read.from == .above);
            },
            else => {},
        };
        try serveWindow(&state, host[0..], ticked);
    }
    try std.testing.expect(above > 0);
    try std.testing.expect(archivedBounds(&state).first.? > top);
    try expectWindowMatchesHost(&state, host[0..]);
}

/// Moves the selection `step_rows` rows down the Archived view (up when negative) and ticks the view.
fn selectRowBelow(state: *State, step_rows: i64) !Effects {
    const at = selectedAt(state);
    const count: i64 = @intCast(state.order.items.len);
    const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(at)) + step_rows, 0, count - 1));
    state.selected = .{ .session = state.rows.items[state.order.items[target]].reference };
    return step(state, .{ .tick = state.now_ms });
}

fn countReads(effects: Effects) usize {
    var reads: usize = 0;
    for (effects.slice()) |effect| reads += @intFromBool(effect == .read_archived);
    return reads;
}

test "archive filter switch keeps the roster and reads the window once per entry" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "private active title" });
    const archived = session("bbbbbb", .{ .stopped = .{ .since = test_now_s - 1, .cause = .stop } }, .{ .label = "saved title", .archive_state = .archived, .archive_seq = 7 });
    var state = try opened(&.{row});
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), effects.len);
    const read = effects.slice()[0].read_archived;
    try std.testing.expect(read.from == .head);
    try std.testing.expect(state.archived.inflight);
    var stale = read;
    stale.epoch +%= 1;
    const retry = try step(&state, .{ .archived = .{ .read = stale, .page = .{ .since = testToken(0), .rows = &.{archived}, .first = 7, .last = 7, .more_above = false, .more_below = false } } });
    try std.testing.expect(state.find(archived.reference) == null);
    try std.testing.expectEqual(@as(usize, 1), retry.slice().len);
    const again = retry.slice()[0].read_archived;
    try std.testing.expect(again.from == .head and again.epoch == read.epoch);
    try std.testing.expect(state.archived.inflight);
    _ = try step(&state, .{ .archived = .{ .read = again, .page = .{ .since = testToken(0), .rows = &.{archived}, .first = 7, .last = 7, .more_above = false, .more_below = false } } });
    try std.testing.expect(state.find(archived.reference) != null);
    try std.testing.expect(!state.archived.inflight);
    effects = .{};
    try changeArchiveView(&state, .active, &effects);
    try std.testing.expectEqual(@as(usize, 0), effects.len);
    try std.testing.expectEqual(@as(usize, 1), state.order.items.len);
    effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try std.testing.expectEqual(@as(usize, 0), effects.len);
    try std.testing.expectEqual(@as(usize, 1), state.order.items.len);
}

test "archived window stays bounded when scrolled far down and back up" {
    var refs: [600][6]u8 = undefined;
    var host: [600]Listed = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "b{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    const margin: usize = archived_page_rows;
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);
    // The held rows never exceed this bound, however far the selection travels in either direction.
    const bound = 6 * margin + 2 * window_test_page;
    var most: usize = 0;
    for (0..host.len + 8) |_| {
        const at = selectedAt(&state);
        state.selected = .{ .session = state.rows.items[state.order.items[@min(at + 1, state.order.items.len - 1)]].reference };
        try serveWindow(&state, &host, try step(&state, .{ .tick = state.now_ms }));
        most = @max(most, heldArchived(&state));
    }
    try std.testing.expect(!state.archived.more_below);
    try std.testing.expect(most <= bound);
    for (0..host.len + 8) |_| {
        const at = selectedAt(&state);
        state.selected = .{ .session = state.rows.items[state.order.items[at -| 1]].reference };
        try serveWindow(&state, &host, try step(&state, .{ .tick = state.now_ms }));
        most = @max(most, heldArchived(&state));
    }
    try std.testing.expect(state.archived.at_head);
    try std.testing.expect(most <= bound);
    try expectWindowMatchesHost(&state, &host);
}

/// The archive key of a row, by reference or by line: stable across the trims that shift indices.
fn archiveSeqOf(state: *const State, ref: Reference) u64 {
    return archiveSeqAt(state, position(state, ref) orelse return 0);
}

fn archiveSeqAt(state: *const State, at: usize) u64 {
    return state.rows.items[state.order.items[at]].archive_seq orelse 0;
}

fn heldArchived(state: *const State) usize {
    var count: usize = 0;
    for (state.rows.items) |row| {
        if (row.listed and row.archive_state == .archived) count += 1;
    }
    return count;
}

test "a full roster walk re-anchors the Archived window at the head and shows a newer archive" {
    var old: [4]Listed = undefined;
    var old_refs: [4][6]u8 = undefined;
    for (&old_refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "o{d:0>5}", .{at}) catch unreachable;
    for (0..old.len) |index| {
        const key: u64 = 40 - 10 * index;
        old[index] = session(&old_refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &old, effects);
    try std.testing.expect(state.archived.at_head);
    const epoch = state.archived.epoch;

    // While the Host was away, Session X was archived above the window and the roster walk lost its deltas.
    const newer = session("xxxxxx", .{ .stopped = .{ .since = test_now_s - 50, .cause = .stop } }, .{ .label = "newer", .archive_state = .archived, .archive_seq = 50 });
    var host: [5]Listed = undefined;
    host[0] = newer;
    @memcpy(host[1..], &old);
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    // The first pass of the since walk restarts the window; the head read it issues is the one checked here.
    const walked = try answerWalk(&state, .full, testToken(2), &.{});
    var reads: usize = 0;
    for (walked.slice()) |effect| switch (effect) {
        .read_archived => |read| {
            reads += 1;
            try std.testing.expect(read.from == .head);
            try std.testing.expectEqual(epoch +% 1, read.epoch);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), reads);
    try serveWindow(&state, &host, walked);
    try std.testing.expect(state.find(newer.reference) != null);
    try expectWindowMatchesHost(&state, &host);
}

test "archive tab flips keep one Archived read in flight and drop its stale answer" {
    var host: [3]Listed = undefined;
    var refs: [3][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "f{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = 30 - 10 * index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try std.testing.expectEqual(@as(usize, 1), effects.len);
    const read = effects.slice()[0].read_archived;

    // Flipping tabs while the head read is in flight queues no further read: the one read is still outstanding.
    var flipped: usize = 0;
    for (0..6) |_| {
        var flip: Effects = .{};
        try changeArchiveView(&state, .active, &flip);
        try changeArchiveView(&state, .archived, &flip);
        for (flip.slice()) |effect| switch (effect) {
            .read_archived => flipped += 1,
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 0), flipped);
    try std.testing.expect(state.archived.inflight);

    // The answer lands in the epoch it was asked in, but the tab was left since: it is dropped, and the
    // one read that follows is the only one outstanding.
    var buffer: [window_test_page]Listed = undefined;
    const landed = try step(&state, .{ .archived = .{ .read = read, .page = hostPage(&host, .head, &buffer) } });
    var outstanding: usize = 0;
    for (landed.slice()) |effect| switch (effect) {
        .read_archived => |next| {
            outstanding += 1;
            try std.testing.expect(next.from == .head and next.epoch == state.archived.epoch);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), outstanding);
    try std.testing.expect(state.archived.inflight);
    try serveWindow(&state, &host, landed);
    try std.testing.expect(!state.archived.inflight);
    try expectWindowMatchesHost(&state, &host);
}

test "a failed Archived read keeps its rows and the list interval retries it" {
    var host: [20]Listed = undefined;
    var refs: [20][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "g{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = 20 - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);
    const held = heldArchived(&state);
    try std.testing.expectEqual(window_test_page, held);

    // Selecting the last shown row asks for the next older page; the Host fails to answer it.
    state.selected = .{ .session = state.rows.items[state.order.items[state.order.items.len - 1]].reference };
    const asked = try step(&state, .{ .tick = state.now_ms });
    var read: ?ArchivedRead = null;
    for (asked.slice()) |effect| switch (effect) {
        .read_archived => |next| read = next,
        else => {},
    };
    try std.testing.expect(read != null and read.?.from == .below);
    _ = try step(&state, .{ .archived = .{ .read = read.?, .page = null } });
    try std.testing.expect(state.archived.failed);
    try std.testing.expectEqual(held, heldArchived(&state));

    // Nothing is re-read until the list interval comes round; then the read is asked again and succeeds.
    const quiet = try step(&state, .{ .tick = state.now_ms });
    for (quiet.slice()) |effect| try std.testing.expect(effect != .read_archived);
    const retried = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var asked_again = false;
    for (retried.slice()) |effect| switch (effect) {
        .read_archived => |next| {
            asked_again = true;
            try std.testing.expect(next.from == .below and next.epoch == read.?.epoch);
        },
        else => {},
    };
    try std.testing.expect(asked_again);
    try serveWindow(&state, &host, retried);
    try std.testing.expect(!state.archived.failed);
    try std.testing.expect(heldArchived(&state) > held);
    try expectWindowMatchesHost(&state, &host);
}

test "a restored Archived row draws its live mark again" {
    const archived = session("rrrrrr", .{ .stopped = .{ .since = test_now_s - 5, .cause = .stop } }, .{ .label = "restored", .archive_state = .archived, .archive_seq = 5, .first = .{ .position = 0, .admission = 5, .sender = null, .content = null, .line = "restored line" } });
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 24 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &.{archived}, effects);
    try std.testing.expectEqual(ArchiveState.archived, state.find(archived.reference).?.archive_state);

    // The Session is restored: the roster walk reports it live, failed, and the window row becomes a roster row.
    const live = session("rrrrrr", .{ .failed = .{ .since = test_now_s - 3, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .label = "restored", .first = .{ .position = 0, .admission = 5, .sender = null, .content = null, .line = "restored line" } });
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    _ = try respond(&state, .changed, testToken(2), &.{live});
    try changeArchiveView(&state, .active, &effects);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, marks.get(.failed).unicode) != null);
}

test "an archived delta refreshes the window from the Host and is never synthesized into it" {
    var host: [4]Listed = undefined;
    var refs: [4][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "d{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = 40 - 10 * index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);

    // Session X is archived between two held rows, and a changed roster walk reports it.
    const archived = session("xxxxxx", .{ .stopped = .{ .since = test_now_s - 25, .cause = .stop } }, .{ .label = "newly archived", .archive_state = .archived, .archive_seq = 25 });
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    const walked = try respond(&state, .changed, testToken(2), &.{archived});
    // The delta does not put X into the window: it owes the window one re-read from the Host, below X.
    try std.testing.expect(state.find(archived.reference) == null);
    var reads: usize = 0;
    for (walked.slice()) |effect| switch (effect) {
        .read_archived => |read| {
            reads += 1;
            try std.testing.expect(read.from == .below and read.from.below == 26);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), reads);

    var newer: [5]Listed = undefined;
    newer[0] = host[0];
    newer[1] = host[1];
    newer[2] = archived;
    newer[3] = host[2];
    newer[4] = host[3];
    try serveWindow(&state, &newer, walked);
    try std.testing.expect(state.find(archived.reference) != null);
    try expectWindowMatchesHost(&state, &newer);
}

fn activeRosterFullFallback() !void {
    const live = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "kept" });
    const archived = session("bbbbbb", .{ .stopped = .{ .since = test_now_s - 9, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = 9 });
    var state = try opened(&.{live});
    defer state.deinit();
    const asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{.{ .list = .{ .since = testToken(1), .archive = .active } }}, asked);

    // The Host answers the since walk in full, with an archived row in its page. The walk is dropped unrouted.
    const walked = try answerWalk(&state, .full, testToken(2), &.{archived});
    try expectEffects(&.{.{ .list = .{ .since = null, .archive = .active } }}, walked);
    try std.testing.expect(state.find(archived.reference) == null);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
    try std.testing.expectEqual(testToken(1), state.token.?);
    try std.testing.expect(state.find(live.reference) != null);
}

test "a failed re-anchor stays owed until a head answer lands" {
    var host: [20]Listed = undefined;
    var refs: [20][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "g{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = 20 - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 2 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);

    // A newer archive appears, and a full walk re-anchors the window: the head read fails.
    const newer = session("nnnnnn", .{ .stopped = .{ .since = test_now_s - 30, .cause = .stop } }, .{ .label = "newest", .archive_state = .archived, .archive_seq = 30 });
    var grown: [21]Listed = undefined;
    grown[0] = newer;
    @memcpy(grown[1..], &host);
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    const walked = try answerWalk(&state, .full, testToken(2), &.{});
    var head: ?ArchivedRead = null;
    for (walked.slice()) |effect| switch (effect) {
        .read_archived => |read| head = read,
        else => {},
    };
    try std.testing.expect(head != null and head.?.from == .head);
    _ = try step(&state, .{ .archived = .{ .read = head.?, .page = null } });
    try std.testing.expect(state.archived.failed);
    try std.testing.expect(state.archived.reanchor);

    // Nothing is read until the list interval comes round; the retry is the head read, and its answer is placed.
    const quiet = try step(&state, .{ .tick = state.now_ms });
    try std.testing.expectEqual(@as(usize, 0), countReads(quiet));
    const retried = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try std.testing.expectEqual(@as(usize, 1), countReads(retried));
    try serveWindow(&state, &grown, retried);
    try std.testing.expect(!state.archived.failed and !state.archived.reanchor);
    try std.testing.expect(state.find(newer.reference) != null);
    try expectWindowMatchesHost(&state, &grown);
}

test "at a short height a page of margin keeps a scroll of one margin from reading again" {
    var refs: [200][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "h{d:0>5}", .{at}) catch unreachable;
    var host: [200]Listed = undefined;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 10 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindowWith(archived_page_rows, &state, &host, effects);
    try std.testing.expectEqual(@as(usize, archived_page_rows), heldArchived(&state));

    // Down to one screen short of the page's last row: no read.
    for (0..archived_page_rows - 11) |_| try std.testing.expectEqual(@as(usize, 0), countReads(try selectRowBelow(&state, 1)));
    // One row further asks for the next page, and that page lands.
    const asked = try selectRowBelow(&state, 1);
    try std.testing.expectEqual(@as(usize, 1), countReads(asked));
    try serveWindowWith(archived_page_rows, &state, &host, asked);
    // A whole margin of scrolling from there reads nothing: the held page is not refetched.
    for (0..10) |_| try std.testing.expectEqual(@as(usize, 0), countReads(try selectRowBelow(&state, 1)));
}

test "wheel scrolling through the Archived window reads each page edge, stays bounded and matches the Host" {
    // Wheel events move the shown rows and report them as a viewport; the selection never moves. Each event is
    // four rows, ten events a page, as the shell reports them. The top row is held by reference, the way the
    // shell anchors it, so a trim above the list moves nothing on screen.
    var refs: [1200][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "w{d:0>5}", .{at}) catch unreachable;
    var host: [1200]Listed = undefined;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    const page = archived_page_rows;
    const height: usize = 10;
    state.size = .{ .width = 80, .height = height };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindowWith(page, &state, &host, effects);
    var top_ref = state.rows.items[state.order.items[0]].reference;
    var most: usize = 0;
    var reads: usize = 0;
    // Five pages down: 50 wheel events of four rows.
    for (0..50) |_| {
        const at = position(&state, top_ref) orelse return error.TestExpectedEqual;
        const next = @min(at + 4, state.order.items.len -| 1);
        top_ref = state.rows.items[state.order.items[next]].reference;
        const asked = try step(&state, .{ .viewport = .{ .first = next, .end = next + height } });
        try std.testing.expect(countReads(asked) <= 1);
        reads += countReads(asked);
        try serveWindowWith(page, &state, &host, asked);
        most = @max(most, heldArchived(&state));
    }
    // The list reached row 200 and each page edge read once: five pages, five reads.
    try std.testing.expectEqual(@as(u64, 1200 - 200), archiveSeqOf(&state, top_ref));
    try std.testing.expectEqual(@as(usize, 5), reads);
    try std.testing.expect(state.archived.more_below);
    // Five pages back up, and the top of the window is read again on the way.
    for (0..50) |_| {
        const at = position(&state, top_ref) orelse return error.TestExpectedEqual;
        const next = at -| 4;
        top_ref = state.rows.items[state.order.items[next]].reference;
        const asked = try step(&state, .{ .viewport = .{ .first = next, .end = next + height } });
        try std.testing.expect(countReads(asked) <= 1);
        try serveWindowWith(page, &state, &host, asked);
        most = @max(most, heldArchived(&state));
    }
    try std.testing.expectEqual(@as(u64, 1200), archiveSeqOf(&state, top_ref));
    try std.testing.expect(state.archived.at_head);
    try std.testing.expect(most <= 6 * page + 2 * height);
    try expectWindowMatchesHost(&state, &host);
}

test "Down past the end of the held Archived rows reads the next page and keeps moving" {
    var refs: [200][6]u8 = undefined;
    for (&refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "d{d:0>5}", .{at}) catch unreachable;
    var host: [200]Listed = undefined;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    defer state.deinit();
    const page = archived_page_rows;
    state.size = .{ .width = 80, .height = 10 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindowWith(page, &state, &host, effects);
    // Down through the held rows: every press lands on the next row, and the held end is read ahead of the press.
    for (1..150) |want| {
        try serveWindowWith(page, &state, &host, try selectRowBelow(&state, 1));
        // Trims above the selection shift indices, so the row is checked by its key: row want is key 200 - want.
        try std.testing.expectEqual(@as(u64, 200 - want), archiveSeqAt(&state, selectedAt(&state)));
    }
    try std.testing.expect(heldArchived(&state) > page);
}

/// The 1200-row Archived list at its head, ten rows a screen, with its first window served.
fn archivedWheelFixture(refs: *[1200][6]u8, host: *[1200]Listed) !State {
    for (refs, 0..) |*ref, at| _ = std.fmt.bufPrint(ref, "x{d:0>5}", .{at}) catch unreachable;
    for (0..host.len) |index| {
        const key: u64 = host.len - index;
        host[index] = session(&refs[index], .{ .stopped = .{ .since = test_now_s - key, .cause = .stop } }, .{ .label = "archived", .archive_state = .archived, .archive_seq = key });
    }
    var state = try opened(&.{});
    errdefer state.deinit();
    state.size = .{ .width = 80, .height = 10 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindowWith(archived_page_rows, &state, host, effects);
    return state;
}

/// One wheel event of four rows, as the shell reports it: the viewport moves and the selection does not.
fn wheelRows(state: *State, host: []const Listed, top_ref: *Reference, down: bool) !usize {
    const at = position(state, top_ref.*) orelse return error.TestExpectedEqual;
    const next = if (down) @min(at + 4, state.order.items.len -| 1) else at -| 4;
    top_ref.* = state.rows.items[state.order.items[next]].reference;
    const asked = try step(state, .{ .viewport = .{ .first = next, .end = next + 10 } });
    try serveWindowWith(archived_page_rows, state, host, asked);
    return countReads(asked);
}

test "archived window: a long wheel scroll after a selection holds the shown rows, not every row from the selection down" {
    var refs: [1200][6]u8 = undefined;
    var host: [1200]Listed = undefined;
    var state = try archivedWheelFixture(&refs, &host);
    defer state.deinit();
    for (0..4) |_| try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    var top_ref = state.rows.items[state.order.items[0]].reference;
    var most: usize = 0;
    // 250 events, 1000 rows: the span from the selection to the shown rows would hold every one of them.
    for (0..250) |_| {
        _ = try wheelRows(&state, &host, &top_ref, true);
        most = @max(most, heldArchived(&state));
    }
    try std.testing.expect(most <= 6 * @as(usize, archived_page_rows) + 2 * 10);
    try std.testing.expect(state.viewport != null);
}

test "archived window: a selection move after a wheel scroll releases the wheel's rows and focuses the selection" {
    var refs: [1200][6]u8 = undefined;
    var host: [1200]Listed = undefined;
    var state = try archivedWheelFixture(&refs, &host);
    defer state.deinit();
    for (0..4) |_| try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    var top_ref = state.rows.items[state.order.items[0]].reference;
    for (0..20) |_| _ = try wheelRows(&state, &host, &top_ref, true);
    try std.testing.expect(state.viewport != null);
    try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    try std.testing.expectEqual(@as(?ViewRows, null), state.viewport);
    const at = selectedAt(&state);
    try std.testing.expectEqual(Focus{ .first = at, .end = at + 1 }, archivedFocus(&state));
}

test "archived window: a trim that drops the selected row, then Down, selects from the shown rows" {
    var refs: [1200][6]u8 = undefined;
    var host: [1200]Listed = undefined;
    var state = try archivedWheelFixture(&refs, &host);
    defer state.deinit();
    for (0..4) |_| try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    var top_ref = state.rows.items[state.order.items[0]].reference;
    // 100 events, 400 rows: the trim drops the rows above the shown span, the selected row among them.
    for (0..100) |_| _ = try wheelRows(&state, &host, &top_ref, true);
    const span = state.viewport orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?usize, null), position(&state, state.selected.session));
    const shown_top = position(&state, span.first) orelse return error.TestExpectedEqual;
    try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    // Down starts from the top shown row: it selects the row the list shows at its top.
    try std.testing.expectEqual(shown_top, selectedAt(&state));
}

fn sUI132ArchivedTrimCase() !void {
    var refs: [1200][6]u8 = undefined;
    var host: [1200]Listed = undefined;
    var state = try archivedWheelFixture(&refs, &host);
    defer state.deinit();
    for (0..4) |_| try serveWindowWith(archived_page_rows, &state, &host, try press(&state, .next));
    const selected = state.selected.session;
    const selected_row = state.find(selected) orelse return error.TestExpectedEqual;
    const selected_key = selected_row.archive_seq orelse return error.TestExpectedEqual;
    var top_ref = state.rows.items[state.order.items[0]].reference;
    for (0..100) |_| _ = try wheelRows(&state, &host, &top_ref, true);
    const span = state.viewport orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?usize, null), position(&state, selected));
    try std.testing.expect(state.find(selected) != null);

    _ = try step(&state, .{ .conversation = span.first });
    try std.testing.expectEqualSlices(u8, &selected, &state.selected.session);
    try std.testing.expectEqualSlices(u8, &span.first, &state.conversing.?);
    try commit(&state, .{ .delta = .changed, .since = testToken(2) });
    try std.testing.expectEqualSlices(u8, &selected, &state.selected.session);
    try std.testing.expectEqual(state.find(selected).?.archive_seq, selected_key);

    var changed = false;
    for (&host) |*row| if (std.mem.eql(u8, &row.reference, &selected)) {
        row.archive_state = .active;
        row.archive_seq = null;
        changed = true;
        break;
    };
    try std.testing.expect(changed);
    var head_rows: [archived_page_rows]Listed = undefined;
    var head_count: usize = 0;
    for (host) |row| if (row.archive_state == .archived and head_count < head_rows.len) {
        head_rows[head_count] = row;
        head_count += 1;
    };
    try std.testing.expect(head_count != 0);
    var effects: Effects = .{};
    readArchived(&state, &effects, .head);
    const read = effects.slice()[0].read_archived;
    const head = ArchivedPage{
        .since = testToken(0),
        .rows = head_rows[0..head_count],
        .first = head_rows[0].archive_seq,
        .last = head_rows[head_count - 1].archive_seq,
        .more_above = false,
        .more_below = true,
    };
    _ = try step(&state, .{ .archived = .{ .read = read, .page = head } });
    try std.testing.expect(state.selected == .none);
    try std.testing.expectEqualSlices(u8, &span.first, &state.conversing.?);
    try std.testing.expect(selected_key >= head.last.?);
}

test "archived window: a viewport's lines map to rows past a pinned gap" {
    var refs: [1200][6]u8 = undefined;
    var host: [1200]Listed = undefined;
    var state = try archivedWheelFixture(&refs, &host);
    defer state.deinit();
    // A gap at line 3 moves the rows from row 3 on down one line, as the list draws them.
    state.pin_end = 3;
    // Lines 2..5 are rows 2, the gap, 3 and 4: the viewport's ends are rows 2 and 4, not lines 2 and 5.
    _ = try step(&state, .{ .viewport = .{ .first = 2, .end = 6 } });
    try std.testing.expectEqual(Focus{ .first = 2, .end = 5 }, archivedFocus(&state));
}

test "the Archived view lists Sessions flat in the Host's order, with no nesting and no pins first" {
    // A window row carries no pin and no creator (its wire row has neither), so none can reorder or nest it.
    const parent = session("p00001", .{ .stopped = .{ .since = test_now_s - 30, .cause = .stop } }, .{ .label = "parent", .archive_state = .archived, .archive_seq = 30 });
    const pinned = session("q00002", .{ .stopped = .{ .since = test_now_s - 20, .cause = .stop } }, .{ .label = "pinned", .archive_state = .archived, .archive_seq = 20 });
    const child = session("c00003", .{ .stopped = .{ .since = test_now_s - 10, .cause = .stop } }, .{ .label = "child", .archive_state = .archived, .archive_seq = 10 });
    const host = [_]Listed{ parent, pinned, child };
    var state = try opened(&.{});
    defer state.deinit();
    state.size = .{ .width = 80, .height = 24 };
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try serveWindow(&state, &host, effects);
    try std.testing.expectEqual(host.len, state.order.items.len);
    for (host, 0..) |want, at| {
        const index = state.order.items[at];
        try std.testing.expectEqualSlices(u8, &want.reference, &state.rows.items[index].reference);
        try std.testing.expectEqual(@as(?u32, null), state.nodes.items[index].logical_parent);
    }
}

test "archive failure and unconfirmed requests stay visible and surface recoverable errors" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "kept" });
    var state = try opened(&.{row});
    defer state.deinit();
    var effects: Effects = .{};
    archiveIntent(&state, .selected_archive, &effects);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    _ = try step(&state, .{ .archive = .{ .request = .{ .reference = row.reference }, .outcome = .{ .failed = "archive_pending" } } });
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "not archived: archive_pending") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    effects = .{};
    archiveIntent(&state, .selected_archive, &effects);
    _ = try step(&state, .{ .archive = .{ .request = .{ .reference = row.reference }, .outcome = .{ .unconfirmed = "saved-handle" } } });
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "recover saved-handle") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    effects = .{};
    archiveIntent(&state, .selected_archive, &effects);
    for (effects.slice()) |effect| try std.testing.expect(effect != .archive);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeDeparture(&state, null, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "rui request recover saved-handle") != null);
}

test "archive tab switches keep the roster traversal and its pages" {
    var rows: [max_page_rows + 1]Listed = undefined;
    for (&rows, 0..) |*row, at| row.* = session(&.{ 'a', 'a', 'a', 'a', 'a', '0' + @as(u8, @intCast(at)) }, .{ .idle = ago(1) }, .{ .label = "kept" });
    var state = try opened(&rows);
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[0..max_page_rows], .answer = null } } });
    try std.testing.expectEqual(max_page_rows, state.pending.items.len);
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try changeArchiveView(&state, .active, &effects);
    // The since walk the Host answers in full is walked again, so the full roster is delivered.
    _ = try respond(&state, .full, testToken(2), &rows);
    try std.testing.expectEqual(rows.len, state.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
    for (rows) |row| try std.testing.expect(state.find(row.reference) != null);
    try std.testing.expectEqual(testToken(2), state.token.?);
}

test "archive tab switches keep an unanswered not_modified roster walk" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "kept" });
    var state = try opened(&.{row});
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try changeArchiveView(&state, .active, &effects);
    _ = try respond(&state, .not_modified, testToken(1), &.{});
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    try std.testing.expectEqual(testToken(1), state.token.?);
    _ = try refresh(&state, .full, testToken(2), &.{row});
    try std.testing.expect(state.find(row.reference) != null);
    try std.testing.expectEqual(testToken(2), state.token.?);
}

test "Alt-A conversation archive uses exact unlisted Session at once and shares guards and ledger" {
    const ref = "k7m2qx".*;
    for ([_]Kind{ .idle, .working, .approval }) |work| {
        var state = try testState();
        defer state.deinit();
        const archive: Event = .{ .conversed = .{ .reference = ref, .work = work, .input = .{ .archive = .active } } };
        try expectEffects(&.{.{ .archive = .{ .reference = ref } }}, try step(&state, archive));
        try expectEffects(&.{}, try step(&state, archive));
        try std.testing.expectEqual(@as(usize, 1), state.request_count);
        _ = try step(&state, .{ .archive = .{ .request = .{ .reference = ref }, .outcome = .{ .unconfirmed = "saved-handle" } } });
        try expectEffects(&.{}, try step(&state, archive));
        try std.testing.expectEqual(@as(usize, 1), state.request_count);
    }
    for ([_]ArchiveState{ .archived, .archiving }) |archive| {
        var state = try testState();
        defer state.deinit();
        try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .{ .archive = archive } } }));
        try std.testing.expect(state.notice == null);
        try std.testing.expectEqual(@as(usize, 0), state.request_count);
    }
}

test "upgrade holds settle accepted archive restore and stop completions without readmission" {
    const ref = "aaaaaa".*;
    const outcomes = [_]@FieldType(ArchiveResult, "outcome"){
        .{ .requested = .pending }, .{ .requested = .completed }, .{ .failed = "archive_pending" }, .{ .unconfirmed = "saved-handle" },
    };
    for ([_]bool{ false, true }) |blocked| for ([_]bool{ false, true }) |left| {
        for ([_]bool{ false, true }) |archived| {
            for (outcomes) |outcome| {
                var state = try testState();
                defer state.deinit();
                try std.testing.expect(state.request(if (archived) .archive else .unarchive, ref));
                state.left = left;
                state.upgrade.after = if (blocked) .blocked else .reobserving;
                try expectEffects(&.{}, try step(&state, .{ .archive = .{ .request = .{ .reference = ref, .archived = archived }, .outcome = outcome } }));
                const retained = left or outcome == .unconfirmed;
                try std.testing.expectEqual(@as(usize, if (retained) 1 else 0), state.request_count);
                if (retained) {
                    const expected: @FieldType(Request, "status") = switch (outcome) {
                        .requested => .done,
                        .failed => .failed,
                        .unconfirmed => .unknown,
                    };
                    try std.testing.expectEqual(expected, state.requests[0].status);
                    if (outcome == .unconfirmed) try std.testing.expectEqualStrings("saved-handle", state.requests[0].text.slice());
                }
            }
        }
        for ([_]StopOutcome{ .stopped, .{ .failed = "stop_failed" }, .{ .unconfirmed = "saved-handle" } }) |outcome| {
            var state = try testState();
            defer state.deinit();
            try std.testing.expect(state.request(.stop, ref));
            state.left = left;
            state.upgrade.after = if (blocked) .blocked else .reobserving;
            try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref, .outcome = outcome } }));
            const retained = left or outcome == .unconfirmed;
            try std.testing.expectEqual(@as(usize, if (retained) 1 else 0), state.request_count);
            if (retained) {
                const expected: @FieldType(Request, "status") = switch (outcome) {
                    .stopped => .done,
                    .failed => .failed,
                    .unconfirmed => .unknown,
                };
                try std.testing.expectEqual(expected, state.requests[0].status);
                if (outcome == .unconfirmed) try std.testing.expectEqualStrings("saved-handle", state.requests[0].text.slice());
            }
        }
    };
}

test "a model list Rui cannot read says so; any other failure is no answer" {
    try std.testing.expectEqual(ModelsRead.invalid, ModelsRead.failed(error.InvalidModelList));
    try std.testing.expectEqual(ModelsRead.invalid, ModelsRead.failed(error.ResponseTooLarge));
    try std.testing.expectEqual(ModelsRead.invalid, ModelsRead.failed(error.InvalidResponse));
    try std.testing.expectEqual(ModelsRead.unanswered, ModelsRead.failed(error.ConnectionResetByPeer));
}

test "an Upgrade's end lists again at once, whatever it leaves Host intents" {
    var state: State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    for ([_]session_upgrade.Outcome{ .unchanged, .incompatible, .unchanged, .compatible }, [_]session_upgrade.After{ .reobserving, .blocked, .blocked, .reobserving }) |outcome, after| {
        state.next_list_ms = 10_000;
        _ = try step(&state, .start_upgrade);
        _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = outcome } } });
        try std.testing.expect(state.upgrade.after == after and state.next_list_ms == 0);
    }
}

test "a saved MCP running line fits overview rows without narrowing its saved bound" {
    const description = "a" ++ comptime repeated("é", 99) ++ "z";
    const running: WorkState = .{ .bash = .{
        .since = test_now_s - 75,
        .call = 0,
        .description = bounded(session_work.max_description_bytes, description),
        .running = 1,
        .approvals = 0,
    } };
    var state = try opened(&.{session("k7m2qx", running, .{ .label = "Fetch the page" })});
    defer state.deinit();
    for (20..241) |width| {
        const text = try screenText(&state, @intCast(width), 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(session_line.cells(line, .unicode) <= width);
    }
    try std.testing.expectEqualStrings(description, state.rows.items[0].state.bash.description.?.slice());
}

fn projectionCase0() !void {
    var rows: [kind_cases.len * 2 + 4]Listed = undefined;
    for (kind_cases, 0..) |case, at| {
        for (0..2) |owner| {
            const ref: Reference = .{ 'k', '0' + @as(u8, @intCast(at)), '0', '0', '0', '0' + @as(u8, @intCast(owner)) };
            var work = case.state;
            switch (work) {
                .retrying => |*retry| {
                    retry.since = test_now_s - 60;
                    retry.due_at_ms = (test_now_s + 10) * 1000;
                },
                inline else => |*value| value.since = test_now_s - 60,
            }
            rows[at * 2 + owner] = session(&ref, work, .{ .label = "row", .yours = owner == 1 });
        }
    }
    rows[20] = session("newwrk", .{ .working = ago(1) }, .{ .label = "new work" });
    rows[21] = session("newend", .{ .idle = ago(1) }, .{ .label = "new end" });
    rows[22] = session("oldque", .{ .pending = ago(120) }, .{ .label = "old queue" });
    rows[23] = session("dueque", .{ .retrying = .{ .since = test_now_s - 120, .due_at_ms = (test_now_s - 2) * 1000, .cause = .{}, .attempt = 1 } }, .{ .label = "due queue" });
    var state = try opened(&rows);
    defer state.deinit();
    const expected = [_][]const u8{
        "newend", "newwrk",
        "k00000", "k00001",
        "k10000", "k10001",
        "k20000", "k20001",
        "k30000", "k30001",
        "k40000", "k40001",
        "k50000", "k50001",
        "k60000", "k60001",
        "k70000", "k70001",
        "k80000", "k80001",
        "k90000", "k90001",
        "dueque", "oldque",
    };
    try std.testing.expectEqual(expected.len, state.order.items.len);
    for (expected, state.order.items) |ref, at| try std.testing.expectEqualStrings(ref, &state.rows.items[at].reference);
    var waiting = rows[8];
    waiting.state.bash.approvals = 1;
    waiting.actions.decide = 1;
    _ = try refresh(&state, .changed, testToken(2), &.{waiting});
    try std.testing.expectEqualStrings("newend", &state.rows.items[state.order.items[0]].reference);
}

fn sUI132RefreshCase() !void {
    const a = session("aaaaaa", .{ .working = ago(1) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(2) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(3) }, .{ .label = "C" });
    var state = try opened(&.{ a, b, c });
    defer state.deinit();
    _ = try press(&state, .next);
    _ = try refresh(&state, .full, testToken(2), &.{ a, c });
    try std.testing.expect(state.selected == .none);
    _ = try refresh(&state, .full, testToken(3), &.{a});
    try std.testing.expect(state.selected == .none);
    _ = try refresh(&state, .full, testToken(4), &.{ a, b });
    try std.testing.expect(state.selected == .none);
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .next } } });
    try expectSelected(&state, &a.reference);
    _ = try press(&state, .first);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try press(&state, .last);
    try std.testing.expectEqual(Selection.settings, state.selected);
    var empty = try opened(&.{});
    defer empty.deinit();
    try std.testing.expectEqual(Selection.new_session, empty.selected);
}

fn projectionCase1() !void {
    var listed = session("asking", .{ .approval = ago(1) }, .{ .first_action = 7, .label = "Superseded" });
    listed.actions = .{ .stop = false, .decide = null };
    const genuine = session("real00", .{ .approval = ago(100) }, .{ .first_action = 8, .label = "Genuine" });
    var state = try opened(&.{ listed, genuine });
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Superseded").? < std.mem.indexOf(u8, text, "Genuine").?);
    const row = state.find("asking".*).?;
    try std.testing.expectEqual(session_work.Standing.needs_you, session_work.standing(row.state, false));
    state.selected = .{ .session = row.reference };
    try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .{ .action = .stop } } }));
    try std.testing.expect(!conversation(&state, row.reference, row.actions.stop).stoppable);
}

fn projectionCase2() !void {
    const protocol = @import("protocol.zig");
    var source: protocol.SessionRow = .{};
    try source.reference.set("k7m2qx");
    try source.workspace.set("/work/rui/");
    source.read_version = testToken(1);
    source.work = .{ .state = .{ .approval = ago(1) }, .turn = 1, .operation = 2, .actions = .{ .stop = true, .interrupt = .{ .turn = 1, .operation = 2 }, .decide = null } };
    var state = try opened(&.{Listed.of(&source)});
    defer state.deinit();
    const row = @constCast(state.find("k7m2qx".*).?);
    try std.testing.expect(std.meta.eql(source.work.core(), row.work()));
    var observed = source.work.core();
    observed.actions.interrupt = null;
    settleRow(&state, row, .{ .read_version = testToken(2), .work = observed });
    try std.testing.expect(std.meta.eql(observed, row.work()));
}

test "overview quiet rows: a chat never written in recedes unless it needs you, in every kind, stop, selection, width and depth" {
    const Stop = enum { none, pending, unconfirmed };
    const cases = .{
        .{ kind_cases[0].state, false },
        .{ kind_cases[1].state, false },
        .{ kind_cases[2].state, false },
        .{ kind_cases[3].state, false },
        .{ kind_cases[4].state, false },
        .{ kind_cases[5].state, true },
        .{ kind_cases[6].state, false },
        .{ kind_cases[7].state, false },
        .{ kind_cases[8].state, true },
        .{ kind_cases[9].state, false },
        .{ WorkState{ .bash = .{ .since = test_now_s, .call = 0, .description = null, .running = 1, .approvals = 1 } }, true },
    };
    comptime std.debug.assert(cases.len == std.enums.values(Kind).len + 1);
    inline for (cases) |case| for (std.enums.values(Stop)) |stop| for ([_]bool{ false, true }) |wrote| for ([_]bool{ false, true }) |selected| for ([_]u16{ 46, 140 }) |width| for ([_]Caps.Depth{ .direct, .indexed, .none }) |depth| {
        const caps: Caps = .{ .depth = depth };
        const listed = session("k7m2qx", case[0], .{ .label = "Quiet row", .yours = wrote });
        var state = try opened(&.{listed});
        defer state.deinit();
        const stoppable_kind = switch (std.meta.activeTag(case[0])) {
            .pending, .working, .retrying, .bash, .approval => true,
            else => false,
        };
        if (stop != .none) {
            if (!stoppable_kind) continue;
            state.selected = .{ .session = listed.reference };
            try expectEffects(&.{.{ .stop = listed.reference }}, try press(&state, .stop));
            if (stop == .unconfirmed) _ = try step(&state, .{ .stop = .{ .reference = listed.reference, .outcome = .{ .unconfirmed = "stop-handle" } } });
            try std.testing.expect(state.openStop(listed.reference) != null);
        }
        state.selected = if (selected) .{ .session = listed.reference } else .new_session;
        const quiet = !wrote and !case[1];
        try std.testing.expectEqual(quiet, classOf(&state, state.find(listed.reference).?).quiet);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const first = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, caps, 0)).?;
        const name = try styleOf(first.segments, "Quiet row");
        try std.testing.expectEqual(selected, name.bold);
        try std.testing.expectEqual(if (selected) Colour.strong else Colour.normal, name.colour);
        for (first.segments) |segment| try std.testing.expectEqual(quiet, segment.style.dim);
    };
    var empty = try opened(&.{session("newone", .{ .idle = ago(0) }, .{ .first = null })});
    defer empty.deinit();
    _ = try step(&empty, .{ .conversation = "newone".* });
    try std.testing.expect(!classOf(&empty, empty.find("newone".*).?).quiet);
}

test "overview long name truncates while mark and state age remain visible" {
    const name = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij";
    const listed = session("k7m2qx", .{ .finished = ago(19) }, .{ .label = name, .workspace = "/work/drift" });
    var state = try opened(&.{listed});
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const first = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 40, .{}, 0)).?.segments;
    try std.testing.expectEqualStrings("   abcdefghijklmnopqrstuvwxyzABCDE… now ", try segmentText(arena.allocator(), first));
    state.list_stale = true;
    const faded = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 40, .{}, 0)).?.segments;
    try std.testing.expectEqual(Colour.strong, (try styleOf(faded, "abcdefghijklmnopqrstuvwxyzABCDE…")).colour);
}

test "overview Footer reserves the Upgrade cancellation key before clipping progress" {
    var state = try opened(&.{});
    defer state.deinit();
    const found: upgrade_status.Found = .{ .host = .{ .running = 20 } };
    const cases = [_]struct { run: upgrade_status.Run, right: []const u8 }{
        .{ .run = .checking, .right = "esc cancels" },
        .{ .run = .{ .installing = .{ .found = found, .step = .preparing } }, .right = "esc cancels" },
        .{ .run = .{ .installing = .{ .found = found, .step = .publishing } }, .right = "" },
        .{ .run = .{ .installing = .{ .found = found, .step = .restarting } }, .right = "" },
        .{ .run = .cancelling, .right = "esc cancels" },
        .{ .run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } }, .right = "" },
    };
    for (cases) |case| {
        state.upgrade.run = case.run;
        try std.testing.expectEqualStrings(case.right, footerRight(&state));
    }
}

const TestModelOpening = enum { settings_click, settings_enter, session_click, session_enter, resumed };

fn openModelConsumer(state: *State, opening: TestModelOpening) !Effects {
    return switch (opening) {
        .settings_click => step(state, .{ .clicked = .{ .target = .settings } }),
        .settings_enter => blk: {
            state.selected = .settings;
            break :blk submit(state);
        },
        .session_click => step(state, .{ .clicked = .{ .target = .{ .open = "models".* } } }),
        .session_enter => blk: {
            state.selected = .{ .session = "models".* };
            break :blk submit(state);
        },
        .resumed => step(state, .{ .open = "models".* }),
    };
}

test "shared model reads are admitted by core openings and deduplicated across failed loading and complete answers" {
    for (std.enums.values(TestModelOpening)) |opening| {
        var state = try opened(&.{session("models", .{ .finished = ago(1) }, .{})});
        defer state.deinit();
        const show: Effect = switch (opening) {
            .settings_click, .settings_enter => .open_settings,
            else => .{ .open = "models".* },
        };
        try expectEffects(&.{ show, .list_models }, try openModelConsumer(&state, opening));
        try std.testing.expect(state.asking_models);
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        for ([_]ModelsRead{ .invalid, .unanswered }) |answer| {
            try expectEffects(&.{}, try step(&state, .{ .models = answer }));
            try std.testing.expect(!state.asking_models);
            try expectEffects(&.{ show, .list_models }, try openModelConsumer(&state, opening));
            try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        }
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = provider_route.nameOf(.codex), .list = .pending }}) } }));
        try std.testing.expect(state.menu.loading() and !state.asking_models);
        try expectEffects(&.{ show, .list_models }, try openModelConsumer(&state, opening));
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = provider_route.nameOf(.codex), .list = .pending }}) } }));
        try expectEffects(&.{ .{ .list = .{ .since = testToken(1), .archive = .active } }, .list_models }, try step(&state, .{ .tick = state.next_list_ms }));
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = provider_route.nameOf(.codex), .list = .{ .live = .{ .bytes = "model-a\n" } } }}) } }));
        try std.testing.expect(!state.asking_models and !state.menu.loading());
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        const revision = state.menu_revision;
        try expectEffects(&.{}, try step(&state, .leave));
        try expectEffects(&.{.{ .open = "models".* }}, try step(&state, .{ .open = "models".* }));
        try std.testing.expect(!state.asking_models and state.menu_revision > revision);
    }
}

test "shared model reads respect every Upgrade hold for opening and loading retries then resume after reobservation" {
    const Hold = enum { active, checking, reobserving, blocked };
    const ReadState = enum { unread, invalid, unanswered, loading, complete };
    for (std.enums.values(Hold)) |hold| for (std.enums.values(ReadState)) |answer| {
        var state = try opened(&.{});
        defer state.deinit();
        switch (answer) {
            .unread => {},
            .invalid => _ = try step(&state, .{ .models = .invalid }),
            .unanswered => _ = try step(&state, .{ .models = .unanswered }),
            .loading, .complete => _ = try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = provider_route.nameOf(.codex), .list = if (answer == .loading) .pending else .{ .live = .{ .bytes = "model-a\n" } } }}) } }),
        }
        if (hold != .active) {
            try expectEffects(&.{}, try step(&state, .start_upgrade));
            if (hold != .checking) try expectEffects(&.{}, try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = if (hold == .blocked) .incompatible else .unchanged } } }));
        }
        const wanted = hold == .active and answer != .complete;
        try expectEffects(if (wanted) &.{ .open_settings, .list_models } else &.{.open_settings}, try step(&state, .{ .clicked = .{ .target = .settings } }));
        try std.testing.expectEqual(wanted, state.asking_models);
        try expectEffects(&.{.open_settings}, try step(&state, .{ .clicked = .{ .target = .settings } }));
        const ticked = try step(&state, .{ .tick = state.next_list_ms });
        try expectEffects(&.{.{ .list = .{ .since = testToken(1), .archive = .active } }}, ticked);
        if (hold == .reobserving) {
            _ = try respond(&state, .full, testToken(2), &.{});
            try std.testing.expect(!state.holdsHost());
            try expectEffects(if (answer == .complete) &.{.open_settings} else &.{ .open_settings, .list_models }, try step(&state, .{ .clicked = .{ .target = .settings } }));
        }
    };
}

test "list input has no text domain and ignored printable or slash input preserves state" {
    const ignored: Input = .ignored;
    try std.testing.expect(switch (ignored) {
        .action, .enter, .left => false,
        .ignored => true,
    });
    var state = try opened(&.{session("aaaaaa", .{ .idle = ago(1) }, .{})});
    defer state.deinit();
    state.say(.quiet, "retained notice", .{});
    const selected = state.selected;
    try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .ignored } }));
    try std.testing.expectEqual(selected, state.selected);
    try std.testing.expect(state.notice != null);
    try say_text.expect("retained notice", state.notice.?.said());
    try std.testing.expectEqual(@as(usize, 0), state.request_count);
}

fn hasEffect(effects: Effects, tag: std.meta.Tag(Effect)) bool {
    for (effects.slice()) |effect| if (effect == tag) return true;
    return false;
}

test "New Session Enter and click create exactly once with a copied default" {
    for ([_]bool{ false, true }) |click| {
        var state = try opened(&.{});
        defer state.deinit();
        state.default = Default.of("openai", "gpt-6-sol");
        const input: Event = if (click) .{ .clicked = .{ .target = .new_session } } else .{ .input = .{ .key = .enter } };
        const effects = try step(&state, input);
        try expectEffects(&.{.{ .create = state.default }}, effects);
        state.default.?.model.set("changed-after-admission") catch unreachable;
        state.default.?.provider = pn(.codex);
        try std.testing.expect(pn(.openai).eql(effects.slice()[0].create.?.provider));
        try std.testing.expectEqualStrings("gpt-6-sol", effects.slice()[0].create.?.model.slice());
        state.default = null;
        try std.testing.expect(state.creating());
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
        try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .new_session } }));
        try std.testing.expectEqual(@as(usize, 1), state.request_count);
        try std.testing.expectEqual(.create, state.requests[0].kind);
        try expectEffects(&.{.exit}, try press(&state, .exit));
    }
}

test "creation accepted opens its known reference and rejected creation permits retry" {
    var state = try opened(&.{});
    defer state.deinit();
    _ = try submit(&state);
    try expectEffects(&.{}, try step(&state, .{ .created = .{ .failed = "rejected" } }));
    try std.testing.expect(!state.creating());
    try say_text.expect("! Not created: rejected", state.notice.?.said());
    try expectEffects(&.{.{ .create = null }}, try submit(&state));
    try expectEffects(&.{ .{ .open = "n3w5es".* }, .list_models }, try step(&state, .{ .created = .{ .created = .{ .reference = "n3w5es".*, .handle = "capture" } } }));
    try std.testing.expectEqualStrings("n3w5es", &state.selected.session);
    try std.testing.expect(!state.creating());
}

test "uncertain creation retains recovery and refuses duplicate keys and clicks" {
    var state = try opened(&.{});
    defer state.deinit();
    _ = try submit(&state);
    _ = try step(&state, .{ .created = .{ .unconfirmed = "saved-capture" } });
    try std.testing.expect(state.creating());
    try std.testing.expectEqualStrings("saved-capture", state.requests[0].text.slice());
    try std.testing.expectEqual(.unknown, state.requests[0].status);
    try expectEffects(&.{}, try submit(&state));
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .new_session } }));
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeDeparture(&state, null, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "rui request recover saved-capture") != null);
}

test "creation settlement after departure retains accepted identity and recovery" {
    var state = try opened(&.{});
    defer state.deinit();
    _ = try submit(&state);
    _ = try step(&state, .leave);
    try expectEffects(&.{}, try step(&state, .{ .created = .{ .created = .{ .reference = "n3w5es".*, .handle = "capture" } } }));
    try std.testing.expectEqualStrings("n3w5es", &state.requests[0].session.?);
    try std.testing.expectEqualStrings("capture", state.requests[0].text.slice());
    try std.testing.expectEqual(.done, state.requests[0].status);
}

test "list creation obeys Host holds and ledger capacity while Settings stays local" {
    for ([_]bool{ false, true }) |full| {
        var state = try opened(&.{});
        defer state.deinit();
        if (full) {
            while (state.request_count < max_requests) {
                try std.testing.expect(state.request(.stop, "aaaaaa".*));
            }
        } else state.upgrade.after = .blocked;
        try expectEffects(&.{}, try submit(&state));
        try std.testing.expect(!state.creating());
        state.selected = .settings;
        const effects = try submit(&state);
        try std.testing.expect(effects.slice()[0] == .open_settings);
    }
}

test "overview footer slot follows only visible notices and upgrade cancellation" {
    var state = try opened(&.{});
    defer state.deinit();
    for ([_]bool{ false, true }) |notice| for ([_]bool{ false, true }) |upgrading| {
        state.notice = null;
        state.upgrade.run = if (upgrading) .checking else null;
        if (notice) state.say(.normal, "Copied 3 lines", .{});
        try std.testing.expectEqual(notice or upgrading, footerShown(&state));
        for ([_]u16{ 0, 1, 2, 3, 4, 10, 30, 40 }) |height| {
            state.size = .{ .width = 46, .height = height };
            const rows = layout(&state);
            try std.testing.expect(rows.list.end <= rows.settings.start);
            try std.testing.expect(rows.host.end <= rows.settings.start);
            try std.testing.expect(rows.host.end <= rows.input);
            try std.testing.expect(rows.input <= height);
        }
    };
}

test "SUI-36 overview bottom layout reserves visible rows" {
    for ([_]u16{ 0, 1, 46, 140 }) |width| {
        for ([_]bool{ false, true }) |notice| {
            for ([_]bool{ false, true }) |host| for ([_]bool{ false, true }) |upgrading| {
                var state = try opened(&.{});
                defer state.deinit();
                if (notice) state.say(.normal, "Copied 3 lines", .{});
                if (upgrading) state.upgrade.run = .checking;
                state.host_line = host;
                for (0..41) |h| {
                    const height: u16 = @intCast(h);
                    state.size = .{ .width = width, .height = height };
                    const rows = layout(&state);
                    if (width == 0 or height == 0) {
                        try std.testing.expectEqual(Layout{}, rows);
                        continue;
                    }
                    const settings: u16 = if (height >= 2) height - 2 else height;
                    if (width == 1 and upgrading) {
                        try std.testing.expect(rows.list.start <= rows.list.end);
                        try std.testing.expectEqual(rows.list.end, rows.host.start);
                        try std.testing.expectEqual(rows.host.end, rows.input);
                        try std.testing.expect(rows.input <= settings);
                        try std.testing.expectEqual(settings, rows.settings.start);
                        try std.testing.expectEqual(height, rows.settings.end);
                        continue;
                    }
                    const top = @min(@as(u16, 3), settings);
                    const reserved: u16 = @as(u16, @intFromBool(notice or upgrading)) + @as(u16, @intFromBool(upgrading));
                    const input = @max(top, settings -| reserved);
                    const host_start = @max(top, input -| @as(u16, @intFromBool(host)));
                    try std.testing.expectEqual(settings, rows.settings.start);
                    try std.testing.expectEqual(height, rows.settings.end);
                    try std.testing.expectEqual(input, rows.input);
                    try std.testing.expectEqual(host_start, rows.host.start);
                    try std.testing.expectEqual(input, rows.host.end);
                    try std.testing.expectEqual(top, rows.list.start);
                    try std.testing.expectEqual(host_start, rows.list.end);
                }
            };
        }
    }
}

test "a busy Session archives at once, asking nothing, and never hides before settled server state" {
    var row = session("aaaaaa", .{ .working = ago(1) }, .{ .label = "busy" });
    var state = try opened(&.{row});
    defer state.deinit();
    var effects: Effects = .{};
    archiveIntent(&state, .selected_archive, &effects);
    try expectEffects(&.{.{ .archive = .{ .reference = row.reference } }}, effects);
    const asked = try screenText(&state, 100, 24, .{});
    defer std.testing.allocator.free(asked);
    try std.testing.expect(std.mem.indexOf(u8, asked, "Stop and archive") == null);
    try std.testing.expectEqual(ArchiveState.active, state.find(row.reference).?.archive_state);
    _ = try step(&state, .{ .archive = .{ .request = .{ .reference = row.reference }, .outcome = .{ .requested = .pending } } });
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    row.archive_state = .archiving;
    row.state = .{ .stopping = ago(0) };
    _ = try refresh(&state, .changed, testToken(2), &.{row});
    const settling = try screenText(&state, 100, 24, .{});
    defer std.testing.allocator.free(settling);
    try std.testing.expect(std.mem.indexOf(u8, settling, "[Archiving] busy") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    row.archive_state = .archived;
    row.state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } };
    _ = try refresh(&state, .changed, testToken(3), &.{row});
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.notice == null);
}

test "Alt-A archives the selected row at once, busy or not, without a composer" {
    const a = session("aaaaaa", .{ .working = ago(1) }, .{});
    const b = session("bbbbbb", .{ .idle = ago(2) }, .{});
    for ([_]Reference{ a.reference, b.reference }) |ref| {
        var state = try opened(&.{ a, b });
        defer state.deinit();
        state.selected = .{ .session = ref };
        try expectEffects(&.{.{ .archive = .{ .reference = ref } }}, try step(&state, .{ .input = .{ .key = .{ .action = .archive } } }));
        try std.testing.expectEqual(ArchiveState.active, state.find(ref).?.archive_state);
        _ = try step(&state, .{ .archive = .{ .request = .{ .reference = ref }, .outcome = .{ .failed = "archive_pending" } } });
        try std.testing.expect(state.find(ref) != null);
    }
}

fn stopCase4() !void {
    const ref = "aaaaaa".*;
    const events = [_]Event{
        .{ .input = .{ .key = .{ .action = .stop } } },
        .{ .conversed = .{ .reference = ref, .work = .working, .input = .{ .stop = true } } },
    };
    for ([_]bool{ false, true }) |blocked| {
        for (events) |event| {
            var state = try opened(&.{session(&ref, .{ .working = ago(1) }, .{})});
            defer state.deinit();
            state.upgrade.after = if (blocked) .blocked else .reobserving;
            try expectEffects(&.{}, try step(&state, event));
            try std.testing.expectEqual(@as(usize, 0), state.request_count);
            try say_text.expect(state_marks.attention_sign ++ upgrade_recovery, state.notice.?.said());
            state.upgrade.after = .open;
            try expectEffects(&.{.{ .stop = ref }}, try step(&state, event));
        }
    }
}

test "archive admission reports only a new ledger request across every surface capacity duplicate and Host guard" {
    const Held = enum { none, pending, unknown };
    const Hold = enum { active, checking, reobserving, blocked };
    const ref = "archiv".*;
    for ([_]bool{ false, true }) |full| for (std.enums.values(Held)) |held| for (std.enums.values(Hold)) |hold| for ([_]ArchiveState{ .active, .archiving, .archived }) |archive| {
        const cases = [_]struct { event: Event, restore: bool = false }{
            .{ .event = .{ .conversed = .{ .reference = ref, .work = .working, .input = .{ .archive = archive } } } },
            .{ .event = .{ .input = .{ .key = .{ .action = .archive } } } },
            .{ .event = .{ .conversed = .{ .reference = ref, .work = .working, .input = .unarchive } }, .restore = true },
        };
        for (cases) |case| {
            var state = try testState();
            defer state.deinit();
            state.archive = .all;
            _ = try step(&state, .{ .tick = test_now_s * 1000 });
            if (archive == .archived) {
                _ = try respond(&state, .full, testToken(1), &.{});
                _ = try step(&state, .{ .archived = .{ .read = .{ .from = .head, .rows = 40, .epoch = state.archived.epoch }, .page = .{ .since = testToken(0), .rows = &.{session(&ref, .{ .working = ago(1) }, .{ .archive_state = .archived, .archive_seq = 5 })}, .first = 5, .last = 5, .more_above = false, .more_below = false } } });
                state.selected = .{ .session = ref };
            } else _ = try respond(&state, .full, testToken(1), &.{session(&ref, .{ .working = ago(1) }, .{ .archive_state = archive })});
            if (held != .none) {
                try std.testing.expect(state.request(if (case.restore) .archive else .unarchive, ref));
                if (held == .unknown) state.answer(0, .unknown, "01234567-89ab-4cde-8012-0123456789ab");
            }
            if (full) while (state.request_count < max_requests) {
                try std.testing.expect(state.request(.stop, "other0".*));
            };
            if (hold != .active) {
                _ = try step(&state, .start_upgrade);
                if (hold != .checking) _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = if (hold == .blocked) .incompatible else .unchanged } } });
            }
            const before = state.request_count;
            const retained = state.requests;
            const effects = try step(&state, case.event);
            const admitted = hold == .active and !full and held == .none and (case.restore or archive == .active);
            try std.testing.expectEqual(if (admitted) IntentAdmission.admitted else .refused, effects.intent_admission);
            var requests: usize = 0;
            for (effects.slice()) |effect| if (effect == .archive) {
                requests += 1;
                try std.testing.expectEqual(ref, effect.archive.reference);
                try std.testing.expectEqual(!case.restore, effect.archive.archived);
            };
            try std.testing.expectEqual(@as(usize, @intFromBool(admitted)), requests);
            try std.testing.expectEqual(before + @intFromBool(admitted), state.request_count);
            for (retained[0..before], state.requests[0..before]) |expected_request, actual_request| {
                try std.testing.expectEqual(expected_request.kind, actual_request.kind);
                try std.testing.expectEqual(expected_request.session, actual_request.session);
                try std.testing.expectEqual(expected_request.status, actual_request.status);
                try std.testing.expectEqualStrings(expected_request.text.slice(), actual_request.text.slice());
                try std.testing.expectEqual(expected_request.sent, actual_request.sent);
            }
            if (hold != .active) {
                try say_text.expect(state_marks.attention_sign ++ upgrade_recovery, state.notice.?.said());
            } else if (!case.restore and archive != .active) {
                try std.testing.expect(state.notice == null);
            } else if (held != .none) {
                try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), if (held == .pending) "request pending" else "request unsure") != null);
            } else if (full) {
                try say_text.expect("! Busy; try again shortly.", state.notice.?.said());
            }
            try std.testing.expectEqual(IntentAdmission.refused, (try step(&state, .{ .resized = .{ .width = 46, .height = 18 } })).intent_admission);
        }
    };
    var empty = try opened(&.{});
    defer empty.deinit();
    const refused = try press(&empty, .archive);
    try std.testing.expectEqual(IntentAdmission.refused, refused.intent_admission);
    try std.testing.expectEqual(@as(usize, 0), empty.request_count);
}

test "Upgrade runs inline: Esc cancels it before the draft, checking or preparing, and its end sets the Host hold" {
    var state = try opened(&.{});
    defer state.deinit();
    var buffer: [upgrade_status.max_line_bytes]u8 = undefined;
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try std.testing.expectEqualStrings("Checking for updates…", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);

    try expectEffects(&.{.cancel_upgrade}, try press(&state, .clear));

    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } });
    try std.testing.expect(state.notice == null);
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });

    try expectEffects(&.{.cancel_upgrade}, try press(&state, .clear));

    try std.testing.expectEqualStrings("Preparing Upgrade · no Hosts running · esc cancels", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .cancelling });

    try expectEffects(&.{.cancel_upgrade}, try press(&state, .clear));
    try std.testing.expectEqualStrings("Cancelling…", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } });
    try std.testing.expectEqual(session_upgrade.After.reobserving, state.upgrade.after);

    try expectEffects(&.{}, try press(&state, .clear));

    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .{ .running = 1 } }, .step = .publishing } } });
    try expectEffects(&.{}, try press(&state, .clear));
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);
    try std.testing.expectEqual(upgrade_status.Lasts.persistent, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).lasts);

    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 61, .patch = 0 } }, .outcome = .unchanged } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 61, .patch = 0 } }, .outcome = .compatible } } });
    try std.testing.expect(state.upgrade.after == .reobserving);

    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .{ .running = 0 } } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 61, .patch = 1 }, .restarted = true } }, .outcome = .compatible } } });
    try std.testing.expect(state.upgrade.after == .reobserving);
}

test "every place an Upgrade run can stand decides the hold, Esc and another Upgrade from that one value" {
    const found: upgrade_status.Found = .{ .host = .{ .running = 2 } };
    const Case = struct { run: ?upgrade_status.Run, going: bool, escape: bool };
    const cases = [_]Case{
        .{ .run = null, .going = false, .escape = false },
        .{ .run = .checking, .going = true, .escape = true },
        .{ .run = .{ .installing = .{ .found = found, .step = .preparing } }, .going = true, .escape = true },
        .{ .run = .{ .installing = .{ .found = found, .step = .publishing } }, .going = true, .escape = false },
        .{ .run = .{ .installing = .{ .found = found, .step = .restarting } }, .going = true, .escape = false },
        .{ .run = .cancelling, .going = true, .escape = true },
        .{ .run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } }, .going = false, .escape = false },
        .{ .run = .{ .ended = .{ .how = .{ .superseded = upgrade_status.Version{ .schema = 60, .patch = 0 } }, .outcome = .unchanged } }, .going = false, .escape = false },
        .{ .run = .{ .ended = .{ .how = .{ .incompatible = upgrade_status.Version{ .schema = 60, .patch = 0 } }, .outcome = .incompatible } }, .going = false, .escape = false },
    };
    for (cases) |case| {
        var state = try opened(&.{});
        defer state.deinit();
        state.upgrade.run = case.run;

        try std.testing.expectEqual(case.going, state.upgrading());
        try std.testing.expectEqual(case.going, state.holdsHost());

        try expectEffects(if (case.escape) &.{.cancel_upgrade} else &.{}, try press(&state, .clear));
        try std.testing.expectEqual(case.run, state.upgrade.run);

        try expectEffects(&.{}, try step(&state, .start_upgrade));
        if (case.going) try std.testing.expectEqual(case.run, state.upgrade.run) else try std.testing.expect(state.upgrade.run.? == .checking);
        try std.testing.expect(state.holdsHost());
    }
}

test "another Upgrade while one runs changes nothing: its progress and Esc stay" {
    var state = try opened(&.{});
    defer state.deinit();
    var buffer: [upgrade_status.max_line_bytes]u8 = undefined;
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    const preparing = try std.testing.allocator.dupe(u8, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    defer std.testing.allocator.free(preparing);
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try std.testing.expectEqualStrings(preparing, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none }, .step = .publishing } } });
    const publishing = try std.testing.allocator.dupe(u8, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    defer std.testing.allocator.free(publishing);
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try std.testing.expectEqualStrings(publishing, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);

    try expectEffects(&.{}, try press(&state, .clear));
}

test "Upgrade is never refused as a Host request: the status bar shows its run at first, while it runs and after a hold" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try expectStatus(&state, "Checking for updates…", .normal);

    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try expectStatus(&state, "Checking for updates…", .normal);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);

    try expectEffects(&.{}, try submit(&state));
    try say_text.expect(state_marks.attention_sign ++ upgrade_recovery, footerNotice(&state).?);
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try expectStatus(&state, "Checking for updates…", .normal);
}

test "a creation the Host refuses for want of its sign-in names the sign-in and its login, if it has one" {
    for ([_]provider_name.Provider{ .codex, .chatgpt }) |provider| {
        var state = try opened(&.{});
        state.default = Default.of(@tagName(provider), "gpt-6-luna");
        defer state.deinit();
        _ = try submit(&state);
        try expectEffects(&.{}, try step(&state, .{ .created = .{ .failed = "model_capability_unavailable" } }));
        const said = state.notice.?.text();
        try std.testing.expect(std.mem.indexOf(u8, said, shownOf(pn(provider))) != null);
        if (loginOf(pn(provider))) |command|
            try std.testing.expect(std.mem.indexOf(u8, said, command) != null)
        else
            try std.testing.expect(std.mem.indexOf(u8, said, "cannot sign in to it yet") != null and std.mem.indexOf(u8, said, "rui auth login") == null);
        try std.testing.expect(std.mem.indexOf(u8, said, "model_capability_unavailable") == null);
    }
}

test "every line fits the screen as the terminal measures it" {
    const rockets = comptime repeated("🚀", 50);
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(1) }, .{ .label = rockets[0..max_label_bytes] }),
        session("r4t9vw", .{ .idle = ago(60) }, .{ .label = "修复存储测试在第二次运行时失败的原因并说明哪些是新问题", .workspace = "/home/d/代码/存储" }),
        session("h8q2mz", .{ .finished = ago(90) }, .{ .label = comptime repeated("👨‍👩‍👧‍👦", 4) }),
        session("m3n8pd", .{ .failed = .{ .since = test_now_s - 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = comptime repeated("Cafe\u{301} ", 14) }),
    });
    defer state.deinit();
    for ([_]Caps{ .{ .width = .unicode }, .{ .width = .wcwidth }, .{ .unicode = false } }) |caps| for ([_]u16{ 80, 41, 24 }) |width| {
        var shown: Frame = try .of(&state, width, 24, caps, 0);
        defer shown.deinit();
        const text = try shown.text();
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, caps.width) <= width);
    };
}
test "Enter opens the selected Session and Settings rather than creating" {
    var state = try opened(&.{session("aaaaaa", .{ .idle = ago(1) }, .{})});
    defer state.deinit();
    try expectEffects(&.{ .{ .open = "aaaaaa".* }, .list_models }, try submit(&state));
    state.selected = .settings;
    try expectEffects(&.{.open_settings}, try submit(&state));
    try std.testing.expectEqual(@as(usize, 0), state.request_count);
}

test "empty overview rows state only the empty archive filter without removed input or commands" {
    const cases = [_]struct { filter: ArchiveFilter, text: []const u8 }{
        .{ .filter = .active, .text = "No chats yet." },
        .{ .filter = .archived, .text = "No archived chats." },
        .{ .filter = .all, .text = "No chats yet." },
    };
    for (cases) |case| {
        var state = try opened(&.{});
        defer state.deinit();
        state.archive = case.filter;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const row = (try Lines.at(arena.allocator(), &state, 0, 80, .{}, 0)).?;
        const text = try segmentText(arena.allocator(), row.segments);
        try std.testing.expectEqualStrings(case.text, std.mem.trim(u8, text, " "));
        try std.testing.expect(std.mem.indexOf(u8, text, "What shall we work on?") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "/sessions") == null);
    }
}

test "empty Session projection retains full and delta metadata until any sender's first admission" {
    for ([_]?Reference{ null, "sender".* }) |sender| {
        var empty = session("empty1", .{ .idle = ago(10) }, .{ .first = null, .label = "Configured" });
        var state = try opened(&.{empty});
        defer state.deinit();
        try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
        try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
        try std.testing.expect(state.selected == .new_session);
        empty.label = "Renamed";
        empty.workspace = "/another/workspace";
        empty.provider = pn(.openai);
        _ = try refresh(&state, .changed, testToken(2), &.{empty});
        const row = state.find(empty.reference).?;
        try std.testing.expectEqualStrings("Renamed", row.label.?.slice());
        try std.testing.expectEqualStrings("/another/workspace", state.workspaces.items[row.workspace]);
        try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
        _ = try refresh(&state, .not_modified, testToken(2), &.{});
        try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
        empty.first = .{ .position = 8, .admission = 9, .sender = sender, .content = test_first };
        _ = try refresh(&state, .changed, testToken(3), &.{empty});
        try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
        try expectOrder(&state, &.{"Renamed"});
        try std.testing.expectEqual(empty.first, state.find(empty.reference).?.first);
        empty.first = null;
        _ = try refresh(&state, .full, testToken(4), &.{empty});
        try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
        try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    }
}

test "empty Session projection shows only the current open empty and reconciles selection on leave" {
    var state = try opened(&.{
        session("empty1", .{ .idle = ago(1) }, .{ .first = null, .label = "First empty" }),
        session("empty2", .{ .idle = ago(2) }, .{ .first = null, .label = "Second empty" }),
        session("filled", .{ .idle = ago(3) }, .{ .label = "Admitted" }),
    });
    defer state.deinit();
    try expectOrder(&state, &.{"Admitted"});
    _ = try step(&state, .{ .conversation = "empty1".* });
    try expectOrder(&state, &.{ "First empty", "Admitted" });
    state.selected = .{ .session = "empty1".* };
    _ = try step(&state, .{ .conversation = "empty2".* });
    try expectOrder(&state, &.{ "Second empty", "Admitted" });
    try expectSelected(&state, "empty2");
    _ = try step(&state, .{ .conversation = null });
    try expectOrder(&state, &.{"Admitted"});
    try expectSelected(&state, "filled");
    try std.testing.expectEqual(@as(usize, 3), state.rows.items.len);
    state.selected = .{ .session = "empty1".* };
    try std.testing.expect(state.selectedRow() == null);
    try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
}

test "empty Session projection leaving the last visible empty selects New Session" {
    var state = try opened(&.{
        session("empty1", .{ .idle = ago(1) }, .{ .first = null }),
        session("empty2", .{ .idle = ago(2) }, .{ .first = null }),
    });
    defer state.deinit();
    _ = try step(&state, .{ .conversation = "empty1".* });
    state.selected = .{ .session = "empty1".* };
    _ = try step(&state, .{ .conversation = null });
    try std.testing.expect(state.selected == .new_session);
    try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.rows.items.len);
}

test "empty Session projection keeps archive membership independent of the open exception" {
    var state = try opened(&.{});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = "empty1".* });
    _ = try refresh(&state, .full, testToken(2), &.{session("empty1", .{ .idle = ago(1) }, .{ .first = null, .label = "Active empty" })});
    try expectOrder(&state, &.{"Active empty"});
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    const read = effects.slice()[0].read_archived;
    _ = try step(&state, .{ .archived = .{ .read = read, .page = .{
        .since = testToken(0),
        .rows = &.{
            session("empty2", .{ .stopped = .{ .since = test_now_s - 2, .cause = .stop } }, .{ .first = null, .label = "Archived empty", .archive_state = .archived, .archive_seq = 9 }),
            session("filled", .{ .stopped = .{ .since = test_now_s - 3, .cause = .stop } }, .{ .label = "Archived admitted", .archive_state = .archived, .archive_seq = 8 }),
        },
        .first = 9,
        .last = 8,
        .more_above = false,
        .more_below = false,
    } } });
    try expectOrder(&state, &.{"Archived admitted"});
    _ = try step(&state, .{ .conversation = "empty2".* });
    try expectOrder(&state, &.{ "Archived empty", "Archived admitted" });
}

test "empty Session projection promotes listing metadata without rolling newer observed work back" {
    var empty = session("empty1", .{ .idle = ago(5) }, .{ .first = null, .label = "Promotion" });
    var state = try opened(&.{empty});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = empty.reference });
    const newest: session_work.Work = fixtureWork(.{ .state = .{ .working = ago(1) }, .turn = 7 });
    _ = try step(&state, .{ .observed = .{ .reference = empty.reference, .read_version = testToken(4), .work = newest, .opening = false } });
    _ = try step(&state, .{ .conversation = null });
    try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    empty.first = .{ .position = 8, .admission = 9, .sender = null, .content = test_first };
    _ = try refresh(&state, .changed, testToken(3), &.{empty});
    try expectOrder(&state, &.{"Promotion"});
    const row = state.find(empty.reference).?;
    try std.testing.expectEqual(testToken(4), row.read_version.?);
    try std.testing.expectEqual(newest, row.work());
    try std.testing.expectEqual(empty.first, row.first);
}

test "empty Session projection counts and provider bands share visible rows" {
    var failed = failedRow("empty1", 1, "provider_http_401", null);
    failed.first = null;
    var state = try opened(&.{
        failed,
        session("empty2", .{ .working = ago(2) }, .{ .first = null }),
        session("empty3", .{ .pending = ago(3) }, .{ .first = null }),
        session("empty4", .{ .approval = ago(4) }, .{ .first = null }),
        session("filled", .{ .working = ago(5) }, .{ .label = "Admitted" }),
    });
    defer state.deinit();
    try std.testing.expectEqual(Counts{ .working = 1 }, state.summary.counts);
    try std.testing.expect(band(&state) == null);
    _ = try step(&state, .{ .conversation = "empty1".* });
    try std.testing.expectEqual(Counts{ .working = 1, .failed = 1 }, state.summary.counts);
    try std.testing.expect(band(&state) != null);
    _ = try step(&state, .{ .conversation = "empty4".* });
    try std.testing.expectEqual(Counts{ .working = 1, .needs_you = 1 }, state.summary.counts);
    try std.testing.expect(band(&state) == null);
    _ = try step(&state, .{ .conversation = null });
    try std.testing.expectEqual(Counts{ .working = 1 }, state.summary.counts);
}

test "empty chat name and selection agree across listing arrival orders and first admission" {
    for ([_]bool{ false, true }) |listed_first| for ([_]?[]const u8{ null, "Configured name" }) |label| {
        const empty = session("empty1", .{ .idle = ago(1) }, .{ .first = null, .label = label });
        var state = try opened(if (listed_first) &.{empty} else &.{});
        defer state.deinit();
        _ = try step(&state, .{ .open = empty.reference });
        _ = try step(&state, .{ .conversation = empty.reference });
        if (!listed_first) {
            try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
            try std.testing.expect(Lines.named(&state) == null);
            _ = try step(&state, .{ .observed = .{ .reference = empty.reference, .read_version = testToken(2), .work = fixtureWork(.{ .state = failedRow("empty1", 1, "provider_http_401", null).state }), .opening = false } });
            try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
            try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
            try std.testing.expect(band(&state) == null);
            _ = try refresh(&state, .changed, testToken(3), &.{empty});
        }
        for ([_]Selection{ .new_session, .settings, .{ .session = "other1".* } }) |navigation| {
            state.selected = navigation;
            try std.testing.expectEqual(@as(?usize, 0), Lines.named(&state));
            try std.testing.expectEqualStrings("New chat", title(&state, &state.rows.items[state.order.items[0]]).text);
            for ([_]u16{ 46, 140 }) |width| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const built = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{}, 0)).?;
                var name_found = false;
                for (built.segments) |segment| {
                    try std.testing.expect(std.mem.indexOf(u8, segment.text, &empty.reference) == null);
                    if (std.mem.indexOf(u8, segment.text, "New chat") != null) {
                        name_found = true;
                        try std.testing.expect(segment.style.bold);
                        try std.testing.expectEqual(Colour.strong, segment.style.colour);
                    }
                }
                try std.testing.expect(name_found);
            }
        }
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
        try std.testing.expect(Lines.named(&state) == null);
        var admitted = empty;
        admitted.first = .{ .position = 1, .admission = 4, .sender = null, .content = test_first };
        _ = try refresh(&state, .changed, testToken(4), &.{admitted});
        state.rows.items[0].line = .requested;
        _ = try step(&state, .{ .first_line = .{ .reference = admitted.reference, .admission = 4, .line = "The first admitted task" } });
        try std.testing.expectEqualStrings(label orelse "The first admitted task", title(&state, &state.rows.items[0]).text);
        try std.testing.expectEqual(@as(usize, 1), state.order.items.len);
    };
}

test "semantic list admission owns covered Settings paste creation and Upgrade precedence" {
    const phases = [_]struct { upgrade: session_upgrade.Upgrade, escape: bool = false, held: bool = false }{
        .{ .upgrade = .{} },
        .{ .upgrade = .{ .run = .checking }, .escape = true, .held = true },
        .{ .upgrade = .{ .run = .{ .installing = .{ .found = .{ .host = .none }, .step = .preparing } } }, .escape = true, .held = true },
        .{ .upgrade = .{ .run = .{ .installing = .{ .found = .{ .host = .none }, .step = .publishing } } }, .held = true },
        .{ .upgrade = .{ .run = .{ .installing = .{ .found = .{ .host = .none }, .step = .restarting } } }, .held = true },
        .{ .upgrade = .{ .run = .cancelling }, .escape = true, .held = true },
        .{ .upgrade = .{ .run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } } },
        .{ .upgrade = .{ .after = .reobserving }, .held = true },
        .{ .upgrade = .{ .after = .blocked }, .held = true },
    };
    const creations = enum { none, pending, uncertain };
    var inputs: [std.enums.values(Action).len + 3]Input = undefined;
    for (std.enums.values(Action), 0..) |action, at| inputs[at] = .{ .action = action };
    inputs[inputs.len - 3] = .left;
    inputs[inputs.len - 2] = .enter;
    inputs[inputs.len - 1] = .ignored;
    for ([_]bool{ false, true }) |sidebar| for ([_]bool{ false, true }) |under| for ([_]bool{ false, true }) |pasted| for (std.enums.values(creations)) |creation| for (phases) |phase| for (inputs) |key| {
        var state = try opened(&.{});
        defer state.deinit();
        if (creation != .none) {
            _ = try submit(&state);
            if (creation == .uncertain) _ = try step(&state, .{ .created = .{ .unconfirmed = "saved-create" } });
        }
        state.conversing = if (sidebar) "aaaaaa".* else null;
        state.upgrade = phase.upgrade;
        state.say(.quiet, "Kept notice", .{});
        const before_notice = state.notice;
        const before_requests = state.request_count;
        const effects = try step(&state, .{ .input = .{ .key = key, .under = under, .pasted = pasted } });
        try std.testing.expect(std.meta.eql(phase.upgrade, state.upgrade));
        if (pasted or key == .ignored) {
            try expectEffects(&.{}, effects);
            try std.testing.expect(std.meta.eql(before_notice, state.notice));
            try std.testing.expectEqual(Selection.new_session, state.selected);
            try std.testing.expectEqual(before_requests, state.request_count);
        } else if (key == .action and key.action == .exit) {
            try expectEffects(&.{.exit}, effects);
            try std.testing.expect(std.meta.eql(before_notice, state.notice));
            try std.testing.expectEqual(before_requests, state.request_count);
        } else if (key == .action and key.action == .clear and phase.escape) {
            try expectEffects(&.{.cancel_upgrade}, effects);
            try std.testing.expect(std.meta.eql(before_notice, state.notice));
            try std.testing.expectEqual(before_requests, state.request_count);
        } else if (under or creation != .none) {
            try expectEffects(&.{}, effects);
            try std.testing.expect(std.meta.eql(before_notice, state.notice));
            try std.testing.expectEqual(Selection.new_session, state.selected);
            try std.testing.expectEqual(before_requests, state.request_count);
        } else switch (key) {
            .ignored => unreachable,
            .left => {
                try expectEffects(&.{}, effects);
                try std.testing.expect(std.meta.eql(before_notice, state.notice));
                try std.testing.expectEqual(Selection.new_session, state.selected);
            },
            .enter => {
                if (phase.held) {
                    try expectEffects(&.{}, effects);
                    try expectNotice(&state, state_marks.attention_sign ++ upgrade_recovery);
                    try std.testing.expectEqual(before_requests, state.request_count);
                } else {
                    try expectEffects(if (sidebar) &.{.new_session} else &.{.{ .create = null }}, effects);
                    try std.testing.expectEqual(before_requests + @intFromBool(!sidebar), state.request_count);
                    try std.testing.expectEqual(!sidebar, state.creating());
                }
            },
            .action => |action| {
                try expectEffects(&.{}, effects);
                try std.testing.expectEqual(before_requests, state.request_count);
                switch (action) {
                    .exit => unreachable,
                    .open_session, .collapse_tree, .expand_tree => {
                        try std.testing.expect(std.meta.eql(before_notice, state.notice));
                        try std.testing.expectEqual(Selection.new_session, state.selected);
                    },
                    .previous_session, .next_session, .next_question => {
                        try std.testing.expect(std.meta.eql(before_notice, state.notice));
                        try std.testing.expectEqual(Selection.new_session, state.selected);
                    },
                    .clear => try expectNotice(&state, null),
                    .stop, .archive => try expectNotice(&state, if (phase.held) state_marks.attention_sign ++ upgrade_recovery else state_marks.attention_sign ++ no_selection),
                    .previous, .next, .first, .last, .select_previous, .select_next => {
                        const expected: Selection = if (action == .last) .settings else if (action == .next or action == .select_next) .sessions else .new_session;
                        try std.testing.expectEqual(expected, state.selected);
                        if (action == .select_previous or action == .select_next) {
                            try std.testing.expect(std.meta.eql(before_notice, state.notice));
                        } else try expectNotice(&state, null);
                    },
                }
            },
        }
    };
}

test "Overview list activation resumes same or opens other chat at wide and narrow widths" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |same| for ([_]Input{ .enter, .{ .action = .open_session } }) |key| {
        var state = try opened(&mixed);
        defer state.deinit();
        _ = try step(&state, .{ .resized = .{ .width = width, .height = 30 } });
        _ = try step(&state, .{ .conversation = "b2c3d4".* });
        state.selected = .{ .session = if (same) "b2c3d4".* else "g7h8j9".* };
        const effects = try step(&state, .{ .input = .{ .key = key } });
        var opens: usize = 0;
        var resumes: usize = 0;
        for (effects.slice()) |effect| switch (effect) {
            .open => |reference| {
                opens += 1;
                try std.testing.expectEqualStrings("g7h8j9", &reference);
            },
            .focus_chat => resumes += 1,
            .create => return error.UnexpectedCreate,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, @intFromBool(!same)), opens);
        try std.testing.expectEqual(@as(usize, @intFromBool(same)), resumes);
    };
}

test "Overview list Right does not create or open Settings and clicks share resume owner" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_]Selection{ .new_session, .settings }) |selection| {
        state.selected = selection;
        const effects = try step(&state, .{ .input = .{ .key = .{ .action = .open_session } } });
        for (effects.slice()) |effect| try std.testing.expect(effect != .create and effect != .open_settings);
    }
    _ = try step(&state, .{ .conversation = "b2c3d4".* });
    const effects = try step(&state, .{ .clicked = .{ .target = .{ .open = "b2c3d4".* } } });
    var resumes: usize = 0;
    for (effects.slice()) |effect| {
        if (effect == .focus_chat) resumes += 1;
        try std.testing.expect(effect != .open);
    }
    try std.testing.expectEqual(@as(usize, 1), resumes);
}

test "Overview browse settles only the last wide list move and never activates controls" {
    const rows = [_]Listed{
        session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "One" }),
        session("bbbbbb", .{ .idle = ago(2) }, .{ .label = "Two" }),
        session("cccccc", .{ .idle = ago(3) }, .{ .label = "Three" }),
        session("dddddd", .{ .idle = ago(4) }, .{ .label = "Four" }),
    };
    for ([_]bool{ false, true }) |wide| for (std.enums.values(enum { chat, new_session, settings, rapid })) |landing| {
        var state = try opened(&rows);
        defer state.deinit();
        _ = try step(&state, .{ .conversation = "aaaaaa".* });
        state.selected = .{ .session = "aaaaaa".* };
        if (landing == .settings) state.selected = .{ .session = "dddddd".* };
        const moves: usize = if (landing == .rapid) 3 else 1;
        var reads: usize = 0;
        for (0..moves) |_| {
            const effects = try step(&state, .{ .input = .{ .wide = wide, .key = .{ .action = if (landing == .new_session) .previous else .next } } });
            for (effects.slice()) |effect| {
                if (effect == .open) reads += 1;
                try std.testing.expect(effect != .create and effect != .open_settings);
            }
        }
        try std.testing.expectEqual(@as(usize, 0), reads);
        const settled = try step(&state, .{ .list_settled = .{ .wide = wide, .focused = true } });
        for (settled.slice()) |effect| {
            if (effect == .open) {
                reads += 1;
                try std.testing.expectEqualStrings(if (landing == .rapid) "dddddd" else "bbbbbb", &effect.open);
            }
            try std.testing.expect(effect != .create and effect != .open_settings and effect != .focus_chat);
        }
        const expected = wide and (landing == .chat or landing == .rapid);
        try std.testing.expectEqual(@as(usize, @intFromBool(expected)), reads);
        try std.testing.expectEqual(expected, settled.browse_open);
        try std.testing.expectEqual(@as(usize, 0), (try step(&state, .{ .list_settled = .{ .wide = wide, .focused = true } })).len);
    };
}

test "Overview browse explicit Enter and Right share activation and focus departure cancels settle" {
    for ([_]bool{ false, true }) |wide| for ([_]Input{ .enter, .{ .action = .open_session } }) |key| for ([_]Selection{ .new_session, .settings, .{ .session = "b2c3d4".* }, .{ .session = "g7h8j9".* } }) |selection| {
        var state = try opened(&mixed);
        defer state.deinit();
        _ = try step(&state, .{ .conversation = "b2c3d4".* });
        state.selected = selection;
        const effects = try step(&state, .{ .input = .{ .wide = wide, .key = key } });
        try std.testing.expect(!effects.browse_open);
        const expected: std.meta.Tag(Effect) = switch (selection) {
            .none, .sessions, .archived => unreachable,
            .new_session => if (key == .enter) .new_session else continue,
            .settings => if (key == .enter) .open_settings else continue,
            .session => |reference| if (std.mem.eql(u8, &reference, "b2c3d4")) .focus_chat else .open,
        };
        var count: usize = 0;
        for (effects.slice()) |effect| if (std.meta.activeTag(effect) == expected) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), count);
    };
    var none = try opened(&mixed);
    defer none.deinit();
    none.selected = .none;
    try expectEffects(&.{}, try submit(&none));
    try expectEffects(&.{}, try press(&none, .open_session));
    try expectEffects(&.{}, try press(&none, .archive));
    try expectNotice(&none, state_marks.attention_sign ++ no_selection);
    try std.testing.expect(none.selected == .none);

    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
    const cancelled = try step(&state, .{ .list_settled = .{ .wide = true, .focused = false } });
    try std.testing.expectEqual(@as(usize, 0), cancelled.len);
}

fn sUI132AdjacentBrowseCase() !void {
    const rows = [_]Listed{
        session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" }),
        session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" }),
        session("cccccc", .{ .finished = ago(3) }, .{ .label = "third" }),
    };
    var state = try opened(&rows);
    defer state.deinit();
    _ = try step(&state, .{ .conversation = rows[0].reference });
    state.selected = .{ .session = rows[0].reference };
    _ = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
    try std.testing.expectEqualSlices(u8, &rows[1].reference, &state.selected.session);
    const activated = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next_session } } });
    try expectEffects(&.{ .{ .open = rows[1].reference }, .list_models }, activated);
    const settled = try step(&state, .{ .list_settled = .{ .wide = true, .focused = true } });
    try expectEffects(&.{}, settled);
    try std.testing.expect(!settled.browse_open);
}

fn sUI132ExplicitBrowseCase() !void {
    const rows = [_]Listed{
        session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" }),
        session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" }),
        session("cccccc", .{ .finished = ago(3) }, .{ .label = "third" }),
    };
    for ([_]Input{ .enter, .{ .action = .open_session } }) |key| {
        var state = try opened(&rows);
        defer state.deinit();
        _ = try step(&state, .{ .conversation = rows[0].reference });
        state.selected = .{ .session = rows[0].reference };
        _ = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
        try expectSelected(&state, &rows[1].reference);

        try expectEffects(&.{ .{ .open = rows[1].reference }, .list_models }, try step(&state, .{ .input = .{ .wide = true, .key = key } }));
        const settled = try step(&state, .{ .list_settled = .{ .wide = true, .focused = true } });
        try expectEffects(&.{}, settled);
        try std.testing.expect(!settled.browse_open);
    }
}

fn sUI132IgnoredPasteBrowseCase() !void {
    const rows = [_]Listed{
        session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" }),
        session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" }),
    };
    for ([_]InputDelivery{
        .{ .key = .ignored, .wide = true },
        .{ .key = .enter, .pasted = true, .wide = true },
    }) |delivery| {
        var state = try opened(&rows);
        defer state.deinit();
        _ = try step(&state, .{ .conversation = rows[0].reference });
        state.selected = .{ .session = rows[0].reference };
        _ = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
        try expectSelected(&state, &rows[1].reference);
        _ = try step(&state, .{ .input = delivery });
        const settled = try step(&state, .{ .list_settled = .{ .wide = true, .focused = true } });
        try expectEffects(&.{ .{ .open = rows[1].reference }, .list_models }, settled);
        try std.testing.expect(settled.browse_open);
    }
}

test "Overview browse New Session never activates until Enter and remains reachable from chat lists" {
    for ([_]bool{ false, true }) |wide| {
        var state = try opened(&mixed);
        defer state.deinit();
        state.selected = .new_session;
        const settled = try step(&state, .{ .list_settled = .{ .wide = wide, .focused = true } });
        try std.testing.expectEqual(@as(usize, 0), settled.len);
        _ = try step(&state, .{ .conversation = "b2c3d4".* });
        _ = try step(&state, .{ .input = .{ .wide = wide, .key = .{ .action = .first } } });
        try std.testing.expect(state.selected == .new_session);
        _ = try step(&state, .{ .input = .{ .wide = wide, .key = .{ .action = .previous } } });
        try std.testing.expect(state.selected == .new_session);
    }
}

test "the shared row fitter translates source marks through normalization and clipping" {
    const Case = struct {
        text: []const u8,
        source: ?ByteSpan,
        room: usize = 40,
        keep: Keep = .head,
        unicode: bool = true,
        shown: []const u8,
        span: ?ByteSpan = null,
    };
    const cases = [_]Case{
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .shown = "Verify", .span = .{ .start = 0, .len = 6 } },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .shown = "界 Verify the project", .span = .{ .start = 4, .len = 6 } },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .unicode = false, .shown = "? Verify the project", .span = .{ .start = 2, .len = 6 } },
        .{ .text = "Verify 界", .source = .{ .start = 0, .len = 6 }, .shown = "Verify 界", .span = .{ .start = 0, .len = 6 } },
        .{ .text = "Verify 界", .source = .{ .start = 0, .len = 6 }, .unicode = false, .shown = "Verify ?", .span = .{ .start = 0, .len = 6 } },
        .{ .text = "界Verify", .source = .{ .start = 0, .len = 9 }, .shown = "界Verify", .span = .{ .start = 0, .len = 9 } },
        .{ .text = "界Verify", .source = .{ .start = 0, .len = 9 }, .unicode = false, .shown = "?Verify", .span = .{ .start = 0, .len = 7 } },
        .{ .text = "\tVerify", .source = .{ .start = 1, .len = 6 }, .shown = " Verify", .span = .{ .start = 1, .len = 6 } },
        .{ .text = "\tVerify", .source = .{ .start = 1, .len = 6 }, .unicode = false, .shown = " Verify", .span = .{ .start = 1, .len = 6 } },
        .{ .text = "\x01 Verify", .source = .{ .start = 2, .len = 6 }, .shown = "? Verify", .span = .{ .start = 2, .len = 6 } },
        .{ .text = "\xff Verify", .source = .{ .start = 2, .len = 6 }, .shown = "? Verify", .span = .{ .start = 2, .len = 6 } },
        .{ .text = "Ver\tify", .source = .{ .start = 0, .len = 7 }, .shown = "Ver ify", .span = .{ .start = 0, .len = 7 } },
        .{ .text = "Ver\nify", .source = .{ .start = 0, .len = 7 }, .shown = "Ver↵ify", .span = .{ .start = 0, .len = 9 } },
        .{ .text = "Ver\nify", .source = .{ .start = 0, .len = 7 }, .unicode = false, .shown = "Ver|ify", .span = .{ .start = 0, .len = 7 } },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .room = 9, .shown = "界 Verif…", .span = .{ .start = 4, .len = 5 } },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .room = 9, .unicode = false, .shown = "? Verify.", .span = .{ .start = 2, .len = 6 } },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .room = 3, .shown = "界…" },
        .{ .text = "界 Verify the project", .source = .{ .start = 4, .len = 6 }, .room = 3, .unicode = false, .shown = "? ." },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .room = 0, .shown = "" },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .room = 1, .shown = "…" },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .room = 1, .unicode = false, .shown = "." },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .room = 1, .keep = .tail, .shown = "…" },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 6 }, .room = 1, .keep = .tail, .unicode = false, .shown = "." },
        .{ .text = "界 Verify", .source = .{ .start = 4, .len = 6 }, .room = 6, .keep = .tail, .shown = "…erify", .span = .{ .start = 3, .len = 5 } },
        .{ .text = "界 Verify", .source = .{ .start = 4, .len = 6 }, .room = 6, .keep = .tail, .unicode = false, .shown = ".erify", .span = .{ .start = 1, .len = 5 } },
        .{ .text = "界 Verify", .source = .{ .start = 0, .len = 3 }, .room = 6, .keep = .tail, .shown = "…erify" },
        .{ .text = "界 Verify", .source = .{ .start = 0, .len = 3 }, .room = 6, .keep = .tail, .unicode = false, .shown = ".erify" },
        .{ .text = "Verify 界", .source = .{ .start = 0, .len = 10 }, .room = 4, .keep = .tail, .shown = "… 界", .span = .{ .start = 3, .len = 4 } },
        .{ .text = "Verify 界", .source = .{ .start = 0, .len = 10 }, .room = 4, .keep = .tail, .unicode = false, .shown = ".y ?", .span = .{ .start = 1, .len = 3 } },
        .{ .text = "e\u{301}clair", .source = .{ .start = 0, .len = 1 }, .room = 5, .shown = "e\u{301}cla…", .span = .{ .start = 0, .len = 3 } },
        .{ .text = "e\u{301}clair", .source = .{ .start = 0, .len = 1 }, .room = 5, .unicode = false, .shown = "e?cl.", .span = .{ .start = 0, .len = 1 } },
        .{ .text = "e\u{301}clair", .source = .{ .start = 1, .len = 2 }, .room = 5, .shown = "e\u{301}cla…", .span = .{ .start = 0, .len = 3 } },
        .{ .text = "e\u{301}clair", .source = .{ .start = 1, .len = 2 }, .room = 5, .unicode = false, .shown = "e?cl.", .span = .{ .start = 1, .len = 1 } },
        .{ .text = "Verify", .source = null, .shown = "Verify" },
        .{ .text = "Verify", .source = .{ .start = 0, .len = 0 }, .shown = "Verify" },
        .{ .text = "Verify", .source = .{ .start = 99, .len = 1 }, .shown = "Verify" },
        .{ .text = "Verify", .source = .{ .start = 5, .len = std.math.maxInt(usize) }, .shown = "Verify", .span = .{ .start = 5, .len = 1 } },
    };
    for (std.enums.values(gwidth.Method)) |method| for (cases) |case| {
        errdefer std.debug.print("source={s} unicode={} room={} keep={t} method={t}\n", .{ case.text, case.unicode, case.room, case.keep, method });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const caps: Caps = .{ .unicode = case.unicode, .width = method };
        const shown = try fittedMarked(arena.allocator(), caps, case.text, case.room, case.keep, case.source);
        try std.testing.expectEqualStrings(case.shown, shown.piece.bytes);
        try std.testing.expectEqualDeep(case.span, shown.span);
        const plain = try fitted(arena.allocator(), caps, case.text, case.room, case.keep);
        try std.testing.expectEqualDeep(plain, shown.piece);
    };
}

test "the shared row fitter handles no description cells without allocating or underflowing" {
    for ([_]Keep{ .head, .tail }) |keep| {
        var storage: [0]u8 = .{};
        var fixed: std.heap.FixedBufferAllocator = .init(&storage);
        const shown = try fitted(fixed.allocator(), .{}, "description", 0, keep);
        try std.testing.expectEqualStrings("", shown.bytes);
        try std.testing.expectEqual(@as(usize, 0), shown.cells);
        const marked = try fittedMarked(fixed.allocator(), .{}, "description", 0, keep, .{ .start = 0, .len = 6 });
        try std.testing.expectEqualDeep(shown, marked.piece);
        try std.testing.expectEqual(@as(?ByteSpan, null), marked.span);
    }
}

test "Option session navigation opens adjacent projected chats anchored to conversation" {
    for ([_]u16{ 46, 140 }) |width| for ([_]Action{ .previous_session, .next_session }) |action| {
        var state = try opened(&mixed);
        defer state.deinit();
        _ = try step(&state, .{ .resized = .{ .width = width, .height = 30 } });
        for (0..state.order.items.len) |at| {
            const open = state.rows.items[state.order.items[at]].reference;
            _ = try step(&state, .{ .conversation = open });
            state.selected = .settings;
            const target = if (action == .previous_session) at -| 1 else @min(at + 1, state.order.items.len - 1);
            const reference = state.rows.items[state.order.items[target]].reference;
            const effects = try step(&state, .{ .input = .{ .key = .{ .action = action } } });
            var navigations: usize = 0;
            for (effects.slice()) |effect| switch (effect) {
                .focus_chat => {
                    try std.testing.expectEqual(at, target);
                    navigations += 1;
                },
                .open => |actual| {
                    try std.testing.expect(target != at);
                    try std.testing.expectEqual(reference, actual);
                    navigations += 1;
                },
                .create, .new_session, .open_settings => return error.UnexpectedNavigation,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), navigations);
            try std.testing.expectEqual(Selection{ .session = reference }, state.selected);
            try std.testing.expectEqual(@as(?Reference, open), state.conversing);
        }
        _ = try step(&state, .{ .conversation = "zzzzzz".* });
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .{ .action = action } } }));
    };
}

test "Option session navigation retains populated creation and Upgrade admission guards" {
    for ([_]Action{ .previous_session, .next_session }) |action| for ([_]enum { pending, uncertain, upgrade }{ .pending, .uncertain, .upgrade }) |guard| {
        var state = try opened(&mixed);
        defer state.deinit();
        if (guard != .upgrade) {
            state.selected = .new_session;
            _ = try submit(&state);
            if (guard == .uncertain) _ = try step(&state, .{ .created = .{ .unconfirmed = "saved-create" } });
        } else state.upgrade = .{ .after = .blocked };
        const open = state.rows.items[state.order.items[1]].reference;
        _ = try step(&state, .{ .conversation = open });
        const before = state.selected;
        const effects = try step(&state, .{ .input = .{ .key = .{ .action = action } } });
        for (effects.slice()) |effect| try std.testing.expect(effect != .open and effect != .create and effect != .open_settings);
        try std.testing.expectEqual(@as(?Reference, open), state.conversing);
        if (guard != .upgrade) try std.testing.expectEqual(before, state.selected) else try expectNotice(&state, state_marks.attention_sign ++ upgrade_recovery);
    };
}

test "Option session navigation skips paired New Session Archived and Settings controls" {
    for ([_]u16{ 46, 140 }) |width| for ([_]Action{ .previous_session, .next_session }) |action| for ([_]Selection{ .new_session, .sessions, .archived, .settings }) |control| for ([_]bool{ false, true }) |chat_open| {
        var state = try opened(&mixed);
        defer state.deinit();
        _ = try step(&state, .{ .resized = .{ .width = width, .height = 30 } });
        const anchor: usize = state.order.items.len / 2;
        if (chat_open) _ = try step(&state, .{ .conversation = state.rows.items[state.order.items[anchor]].reference });
        state.selected = control;
        const target = if (chat_open) (if (action == .previous_session) anchor - 1 else anchor + 1) else (if (action == .previous_session) state.order.items.len - 1 else 0);
        const expected = state.rows.items[state.order.items[target]].reference;
        const effects = try step(&state, .{ .input = .{ .key = .{ .action = action } } });
        var opens: usize = 0;
        for (effects.slice()) |effect| switch (effect) {
            .open => |reference| {
                try std.testing.expectEqual(expected, reference);
                opens += 1;
            },
            .create, .new_session, .open_settings => return error.UnexpectedNavigation,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), opens);
        try std.testing.expectEqual(Selection{ .session = expected }, state.selected);
    };
    for ([_]Action{ .previous_session, .next_session }) |action| for ([_]Selection{ .new_session, .sessions, .archived, .settings }) |control| {
        var empty = try opened(&.{});
        defer empty.deinit();
        empty.selected = control;
        const effects = try step(&empty, .{ .input = .{ .key = .{ .action = action } } });
        try expectEffects(&.{}, effects);
        try std.testing.expectEqual(control, empty.selected);
    };
}

fn projectionCase8() !void {
    var baseline = try opened(&mixed);
    defer baseline.deinit();
    var rows = mixed;
    rows[0].pin_order = 7;
    rows[1].pin_order = std.math.maxInt(i64);
    var state = try opened(&rows);
    defer state.deinit();
    try std.testing.expectEqual(rows[1].reference, state.rows.items[state.order.items[0]].reference);
    try std.testing.expectEqual(rows[0].reference, state.rows.items[state.order.items[1]].reference);
    var remaining: usize = 2;
    for (baseline.order.items) |index| {
        const reference = baseline.rows.items[index].reference;
        if (std.mem.eql(u8, &reference, &rows[0].reference) or std.mem.eql(u8, &reference, &rows[1].reference)) continue;
        try std.testing.expectEqual(reference, state.rows.items[state.order.items[remaining]].reference);
        remaining += 1;
    }
    try std.testing.expectEqual(mixed.len, remaining);
    rows[0].state = .{ .working = ago(0) };
    rows[1].state = .{ .idle = ago(100) };
    _ = try refresh(&state, .changed, testToken(3), rows[0..2]);
    try std.testing.expectEqual(rows[1].reference, state.rows.items[state.order.items[0]].reference);
    try std.testing.expectEqual(rows[0].reference, state.rows.items[state.order.items[1]].reference);
    try std.testing.expectEqual(mixed.len, state.order.items.len);
}

test "Session pin empty visibility keeps archive membership and never counts a row twice" {
    for (std.enums.values(ArchiveFilter)) |filter| for (std.enums.values(ArchiveState)) |archive| {
        const row = session("k7m2qx", .{ .idle = ago(1) }, .{ .first = null, .pin_order = 1, .archive_state = archive });
        var state = try opened(&.{});
        defer state.deinit();
        state.archive = filter;
        // The window holds nothing here and is not read: the roster's own rows are what this case checks.
        state.archived.at_head = true;
        state.archived.reanchor = false;
        _ = try refresh(&state, .full, testToken(1), &.{row});
        const shown = @intFromBool(filter.includes(archive) and archive != .archived);
        try std.testing.expectEqual(shown, state.order.items.len);
        _ = try step(&state, .{ .conversation = row.reference });
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(shown, state.order.items.len);
    };
}

test "Session pin captured intent changes no selection or conversation and awaits canonical listing" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .conversation = mixed[1].reference });
    state.selected = .{ .session = mixed[1].reference };
    const selected = state.selected;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const captured = (try Lines.at(arena.allocator(), &state, 0, 80, .{}, 0)).?.alternate.?;
    const target = captured.pin.reference;
    const row = state.find(target).?;
    try std.testing.expect(row.pin_order == null);
    state.selected = .settings;
    const effects = try step(&state, .{ .clicked = .{ .target = captured } });
    try expectEffects(&.{.{ .pin = .{ .reference = target, .pinned = true } }}, effects);
    try std.testing.expectEqual(IntentAdmission.admitted, effects.intent_admission);
    try std.testing.expectEqual(Selection.settings, state.selected);
    try std.testing.expectEqual(mixed[1].reference, state.conversing.?);
    try std.testing.expect(state.find(target).?.pin_order == null);
    try std.testing.expectEqual(IntentAdmission.refused, (try step(&state, .{ .clicked = .{ .target = captured } })).intent_admission);
    _ = try step(&state, .{ .pin = .{ .request = captured.pin, .outcome = .{ .unconfirmed = "pin-handle" } } });
    try std.testing.expectEqual(IntentAdmission.refused, (try step(&state, .{ .conversed = .{ .reference = target, .work = .idle, .input = .{ .pin = false } } })).intent_admission);
    try std.testing.expect(state.find(target).?.pin_order == null);
    state.selected = selected;
}

test "session list tabs have explicit destinations active no-op and one selection owner" {
    for ([_]bool{ false, true }) |sidebar| for ([_]bool{ false, true }) |some| {
        var state = try opened(if (some) &mixed else &.{});
        defer state.deinit();
        if (sidebar) state.conversing = mixed[0].reference;
        try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .sessions } }));
        try std.testing.expectEqual(Selection.sessions, state.selected);
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
        _ = try step(&state, .{ .input = .{ .key = .{ .action = .open_session } } });
        try std.testing.expectEqual(Selection.archived, state.selected);
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try std.testing.expect(hasEffect(try step(&state, .{ .input = .{ .key = .enter } }), .read_archived));
        try std.testing.expectEqual(Selection.archived, state.selected);
        try std.testing.expectEqual(ArchiveFilter.archived, state.archive);
        _ = try refresh(&state, .full, testToken(2), &.{});
        try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .archived } }));
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
        _ = try step(&state, .{ .input = .{ .key = .left } });
        try std.testing.expectEqual(Selection.sessions, state.selected);
        try std.testing.expectEqual(ArchiveFilter.archived, state.archive);
        // Leaving Archived shows the live roster at once: no list effect.
        try std.testing.expect(!hasEffect(try step(&state, .{ .input = .{ .key = .enter } }), .list));
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try std.testing.expectEqual(@as(usize, 0), state.request_count);
        try std.testing.expectEqual(@as(?Reference, if (sidebar) mixed[0].reference else null), state.conversing);
    };
}

test "session list state ages are compact stable against redraw and reset on state transition" {
    const cases = .{ .{ @as(u64, 120), "2m" }, .{ @as(u64, 18 * 3600), "18h" }, .{ @as(u64, 86400), "1d" }, .{ @as(u64, 3 * 86400), "3d" } };
    inline for (cases) |case| for (kind_cases) |kind| {
        var work = kind.state;
        switch (work) {
            inline else => |*value| value.since = test_now_s - case[0],
        }
        if (work == .retrying) work.retrying.due_at_ms = (test_now_s + 60) * 1000;
        var state = try opened(&.{session("aaaaaa", work, .{ .label = "A useful session" })});
        defer state.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const first = try segmentText(arena.allocator(), (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 46, .{}, 0)).?.segments);
        try std.testing.expect(std.mem.endsWith(u8, first, try std.fmt.allocPrint(arena.allocator(), "{s} ", .{if (rules.get(work).spins) "" else rules.get(work).held orelse case[1]})));
        const again = try segmentText(arena.allocator(), (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 46, .{}, 9)).?.segments);
        try std.testing.expect(std.mem.endsWith(u8, again, try std.fmt.allocPrint(arena.allocator(), "{s} ", .{if (rules.get(work).spins) "" else rules.get(work).held orelse case[1]})));
        const now = state.now_ms;
        _ = try step(&state, .{ .conversation = "aaaaaa".* });
        _ = try step(&state, .{ .observed = .{ .reference = "aaaaaa".*, .read_version = testToken(2), .work = fixtureWork(.{ .state = .{ .finished = .{ .since = test_now_s - 1 } } }), .opening = false } });
        const changed = try segmentText(arena.allocator(), (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 46, .{}, 0)).?.segments);
        try std.testing.expectEqualStrings("now ", changed[changed.len - 4 ..]);
        try std.testing.expectEqual(now, state.now_ms);
    };
}

test "approval rows require no command reads across waiting Action and conversation changes" {
    const states = [_]WorkState{
        .{ .approval = ago(10) },
        .{ .bash = .{ .since = test_now_s - 10, .call = 0, .description = null, .running = 1, .approvals = 1 } },
    };
    for (states) |work| for ([_]?Reference{ null, "asking".*, "other1".* }) |open| {
        var state = try testState();
        defer state.deinit();
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        state.conversing = open;
        var waiting = session("asking", work, .{ .label = "Waiting", .first_action = 41 });
        try expectEffects(&.{}, try respond(&state, .full, testToken(1), &.{waiting}));
        waiting.first_action = 42;
        waiting.actions.decide = 42;
        try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{waiting}));
        state.conversing = null;
        try expectEffects(&.{}, try refresh(&state, .not_modified, testToken(2), &.{}));
    };
}

test "OVM-1 overview marks and ages across states and spinner frames" {
    {
        var state = try opened(&spinning);
        defer state.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var changed: usize = 0;
        for (0..Lines.count(&state)) |line| {
            const two = (try Lines.at(arena.allocator(), &state, line, 80, .{}, 2)).?;
            const three = (try Lines.at(arena.allocator(), &state, line, 80, .{}, 3)).?;
            try std.testing.expectEqual(two.segments.len, three.segments.len);
            for (two.segments, three.segments) |a, b| if (!std.mem.eql(u8, a.text, b.text)) {
                try std.testing.expectEqualStrings(spinner[2], a.text);
                try std.testing.expectEqualStrings(spinner[3], b.text);
                try std.testing.expect(Lines.spins(&state, line, .{}));
                changed += 1;
            };
            try std.testing.expect(!Lines.spins(&state, line, .{ .depth = .none }));
        }
        try std.testing.expectEqual(@as(usize, 3), changed);
    }

    {
        comptime std.debug.assert(kind_cases.len == std.enums.values(Kind).len);
        for (kind_cases, std.enums.values(Kind)) |case, kind| {
            try std.testing.expectEqual(kind, std.meta.activeTag(case.state));
            var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
            defer state.deinit();
            for ([_]Caps{ .{}, .{ .unicode = false } }, [_][]const u8{ case.unicode, case.ascii }) |caps, expected| {
                const text = try screenText(&state, 80, 24, caps);
                defer std.testing.allocator.free(text);
                var lines = std.mem.splitScalar(u8, text, '\n');
                try std.testing.expectEqualStrings(" + New chat", lines.next().?);
                try std.testing.expectEqualStrings("   Chats  Archived", lines.next().?);
                try std.testing.expectEqualStrings(expected, lines.next().?);
            }
            state.selected = .new_session;
            var unselected = try Frame.of(&state, 80, 24, .{}, 0);
            defer unselected.deinit();
            try std.testing.expectEqual(case.colour, unselected.styleAt(2, 1).?.colour);
        }
    }
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const later: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 18) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
        const beside_bash: WorkState = .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 1 } };
        const started = First{ .position = 1, .admission = 4, .sender = "a5k1ng".*, .content = test_first };
        var state = try opened(&.{
            session("a5k1ng", .{ .approval = ago(120) }, .{ .label = "Fix flaky store test" }),
            session("b4sh01", beside_bash, .{ .label = "Asking beside Bash" }),
            session("q00001", .{ .pending = ago(10) }, .{ .label = "Check install script" }),
            session("r3try0", later, .{ .label = "Investigate retry storm" }),
            session("f4iled", .{ .failed = .{ .since = test_now_s - 20 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .label = "Benchmark memory", .first = started }),
            session("0ther0", .{ .failed = .{ .since = test_now_s - 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Odd failure", .first = started }),
            session("s70pd0", .{ .stopped = .{ .since = test_now_s - 90, .cause = .stop } }, .{ .label = "Stopped by me", .first = started }),
        });
        defer state.deinit();
        state.selected = .new_session;
        const a = arena.allocator();
        try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "●", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
        try expectRow(try rowOf(a, &state, "Asking beside Bash", 100, .{}), 100, &.{ .{ "●", .attention }, .{ "Asking beside Bash", .normal }, .{ "1m", .quiet } });
        try expectRow(try rowOf(a, &state, "Check install script", 100, .{}), 100, &.{ .{ "◌", .quiet }, .{ "Check install script", .normal }, .{ "now", .quiet } });
        try expectRow(try rowOf(a, &state, "Investigate retry storm", 100, .{}), 100, &.{ .{ "◝", .attention }, .{ "Investigate retry storm", .normal }, .{ "retrying", .quiet } });
        try expectRow(try rowOf(a, &state, "Benchmark memory", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Benchmark memory", .normal }, .{ "20m", .quiet } });
        try expectRow(try rowOf(a, &state, "Odd failure", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Odd failure", .normal }, .{ "1m", .quiet } });
        try expectRow(try rowOf(a, &state, "Stopped by me", 100, .{}), 100, &.{ .{ "▪", .normal }, .{ "Stopped by me", .normal }, .{ "1m", .quiet } });
    }
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var state = try opened(&.{
            session("f4iled", .{ .failed = .{ .since = test_now_s - 20 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .label = "Benchmark memory" }),
        });
        defer state.deinit();
        state.selected = .new_session;
        try expectRow(try rowOf(arena.allocator(), &state, "Benchmark memory", 40, .{}), 40, &.{ .{ "×", .failure }, .{ "Benchmark memory", .normal }, .{ "20m", .quiet } });
    }
    {
        for (kind_cases, 0..) |case, index| for ([_]u16{ 40, 140 }) |width| {
            var listed = session("k7m2qx", case.state, .{ .label = "A useful Session name", .first_action = 7, .workspace = "/work/drift" });
            var state = try opened(&.{listed});
            defer state.deinit();
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const first = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{}, 0)).?.segments;
            const prefix = try std.fmt.allocPrint(arena.allocator(), "{s}A useful Session name", .{([_][]const u8{ "○ ", "◌ ", "◜ ", "◝ ", "◜ ", "● ", "◝ ", "", "× ", "▪ " })[index]});
            var buffer: [8]u8 = undefined;
            const shown = rules.get(classOf(&state, &state.rows.items[0]).kind);
            const age_text = if (shown.spins) "" else shown.held orelse (Age{ .elapsed = listed.state.since() }).text(&buffer, state.now_ms);
            const expected = [_][]const u8{ prefix, age_text };
            try expectLine(first, width, if (age_text.len == 0) expected[0..1] else expected[0..]);
            try std.testing.expectEqual(Colour.strong, (try styleOf(first, "A useful Session name")).colour);
            try std.testing.expect((try styleOf(first, "A useful Session name")).bold);
            const first_text = try segmentText(arena.allocator(), first);
            try std.testing.expect(std.mem.startsWith(u8, first_text, " "));
            try std.testing.expect(std.mem.endsWith(u8, first_text, " "));
            try std.testing.expect(std.mem.indexOf(u8, first_text, "drift") == null);
            try std.testing.expect(std.mem.indexOf(u8, first_text, "All tests pass.") == null);
            state.selected = .new_session;
            try std.testing.expectEqual(Colour.normal, (try styleOf((try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{}, 0)).?.segments, "A useful Session name")).colour);
        };
    }
    {
        var state = try opened(&spinning);
        defer state.deinit();
        state.selected = .new_session;
        for (0..spinner.len + 1) |frame| {
            const text = try frameText(&state, 80, 24, .{}, frame);
            defer std.testing.allocator.free(text);
            const turn = spinner[frame % spinner.len];
            try std.testing.expectEqualStrings(turn, markOf(text, "Mine, thinking"));
            try std.testing.expectEqualStrings(turn, markOf(text, "Mine, running"));
            try std.testing.expectEqualStrings("●", markOf(text, "Mine, asking"));
            try std.testing.expectEqualStrings("◌", markOf(text, "Mine, queued"));
            try std.testing.expectEqualStrings("◝", markOf(text, "Mine, retrying"));
            try std.testing.expectEqualStrings("◝", markOf(text, "Mine, stopping"));
            try std.testing.expectEqualStrings(turn, markOf(text, "Theirs, thinking"));
            try std.testing.expectEqualStrings("", markOf(text, "Theirs, finished"));
            var screen = try Frame.of(&state, 80, 24, .{}, frame);
            defer screen.deinit();
            try std.testing.expect(anySpins(&state, .{}));
            const mine = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Mine, thinking").?], "\n");
            try std.testing.expectEqual(Style{ .colour = .ink }, screen.styleAt(mine, 1).?);
        }
        state.selected = .{ .session = "y0urs1".* };
        _ = try press(&state, .stop);
        _ = try press(&state, .stop);
        try std.testing.expect(state.openStop("y0urs1".*) != null);
        const asked = try frameText(&state, 80, 24, .{}, 1);
        defer std.testing.allocator.free(asked);
        try std.testing.expectEqualStrings(spinner[1], markOf(asked, "Mine, thinking"));
        for ([_]Caps{ .{ .unicode = false }, .{ .depth = .none }, .{ .unicode = false, .depth = .none }, .{} }, 0..) |caps, at| {
            if (at == 3) state.list_stale = true;
            const first = try screenText(&state, 80, 24, caps);
            defer std.testing.allocator.free(first);
            for (1..spinner.len + 1) |frame| {
                const text = try frameText(&state, 80, 24, caps, frame);
                defer std.testing.allocator.free(text);
                try std.testing.expectEqualStrings(first, text);
                try std.testing.expect(!anySpins(&state, caps));
            }
        }
    }
    const ages = [_]struct { seconds: u64, text: []const u8 }{
        .{ .seconds = 0, .text = "now" },
        .{ .seconds = 59, .text = "now" },
        .{ .seconds = 60, .text = "1m" },
        .{ .seconds = 119, .text = "1m" },
        .{ .seconds = 120, .text = "2m" },
        .{ .seconds = 3599, .text = "59m" },
        .{ .seconds = 3600, .text = "1h" },
        .{ .seconds = 7200, .text = "2h" },
        .{ .seconds = 86399, .text = "23h" },
        .{ .seconds = 86400, .text = "1d" },
    };
    const expected_marks = [_][]const u8{ "○", "◌", "◝", "◝", "◝", "●", "◝", " ", "×", "▪" };
    const expected_ascii = [_][]const u8{ "o", ":", "*", "*", "*", "?", "*", " ", "x", "#" };
    for (kind_cases, 0..) |case, kind| for (ages) |age| for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |sidebar| for ([_]bool{ false, true }) |unicode_marks| {
        var work = case.state;
        switch (work) {
            inline else => |*value| value.since = test_now_s - age.seconds,
        }
        if (work == .retrying) work.retrying.due_at_ms = (test_now_s + 120) * 1000;
        var state = try opened(&.{session("aaaaaa", work, .{ .label = "Domain row", .yours = true })});
        defer state.deinit();
        if (sidebar) state.conversing = "aaaaaa".*;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const caps: Caps = .{ .unicode = unicode_marks };
        const segments = ((try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, caps, 1)).?).segments;
        const text = try segmentText(arena.allocator(), segments);
        const mark = if (unicode_marks) expected_marks[kind] else expected_ascii[kind];
        const prefix = try std.fmt.allocPrint(arena.allocator(), " {s} Domain row", .{mark});
        try std.testing.expectEqualStrings(prefix, text[0..prefix.len]);
        const is_spinning = unicode_marks and (work == .working or work == .bash);
        const held: ?[]const u8 = switch (work) {
            .working, .bash => "working",
            .retrying => "retrying",
            .stopping => "stopping",
            else => null,
        };
        if (is_spinning) {
            try std.testing.expectEqualStrings(prefix, std.mem.trimEnd(u8, text, " "));
        } else if (held) |word| {
            const suffix = try std.fmt.allocPrint(arena.allocator(), "{s} ", .{word});
            try std.testing.expectEqualStrings(suffix, text[text.len - suffix.len ..]);
        } else {
            const suffix = try std.fmt.allocPrint(arena.allocator(), "{s} ", .{age.text});
            try std.testing.expectEqualStrings(suffix, text[text.len - suffix.len ..]);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, "✓") == null);
        try std.testing.expectEqual(@as(usize, width), measured(caps, unicode_glyphs, text));
        const action = try segmentText(arena.allocator(), ((try controls(arena.allocator(), &state, width, caps))[0]).segments);
        try std.testing.expect(std.mem.startsWith(u8, action, " + New chat"));
        try std.testing.expectEqual(@as(usize, text_column), std.mem.indexOf(u8, action, "New chat").?);
    };
}

test "OVM-2 overview redraw deadlines follow visible changing content" {
    try std.testing.expectEqual(@as(u64, 200), spin_interval_ms);
    {
        var rows: [31]Listed = undefined;
        rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes", .yours = true });
        for (rows[1..], 1..) |*row, at| {
            var ref: [6]u8 = "idle00".*;
            _ = std.fmt.bufPrint(ref[4..], "{d:0>2}", .{at}) catch unreachable;
            row.* = session(&ref, .{ .idle = ago(7200 + at) }, .{ .label = "Wait for a reply" });
        }
        {
            var state = try opened(&rows);
            defer state.deinit();
            try std.testing.expect(anySpins(&state, .{}));
            _ = try refresh(&state, .changed, testToken(2), &.{session("w0rk00", .{ .finished = ago(0) }, .{ .label = "Write the notes", .yours = true })});
            try std.testing.expect(!anySpins(&state, .{}));
        }
        rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes" });
        var state = try opened(&rows);
        defer state.deinit();
        try std.testing.expect(anySpins(&state, .{}));
    }
    const Case = struct { remaining: ?u64, text: []const u8, delay: ?u64 };
    const cases = [_]Case{
        .{ .remaining = null, .text = "Quota used up.", .delay = null },
        .{ .remaining = 0, .text = "", .delay = null },
        .{ .remaining = 1, .text = "Quota used up. Resets in under a minute.", .delay = 750 },
        .{ .remaining = 59, .text = "Quota used up. Resets in under a minute.", .delay = 58_750 },
        .{ .remaining = 60, .text = "Quota used up. Resets in 1m.", .delay = 750 },
        .{ .remaining = 61, .text = "Quota used up. Resets in 1m.", .delay = 1_750 },
        .{ .remaining = 119, .text = "Quota used up. Resets in 1m.", .delay = 59_750 },
        .{ .remaining = 120, .text = "Quota used up. Resets in 2m.", .delay = 750 },
        .{ .remaining = 180, .text = "Quota used up. Resets in 3m.", .delay = 750 },
        .{ .remaining = 200, .text = "Quota used up. Resets in 3m.", .delay = 20_750 },
        .{ .remaining = 3599, .text = "Quota used up. Resets in 59m.", .delay = 59_750 },
        .{ .remaining = 3600, .text = "Quota used up. Resets in 1h.", .delay = 750 },
        .{ .remaining = 86399, .text = "Quota used up. Resets in 23h.", .delay = 3_599_750 },
        .{ .remaining = 86400, .text = "Quota used up. Resets in 1d.", .delay = 750 },
    };
    const Screen = enum { unicode, indexed, ascii, colourless, stale, peer };
    for (cases) |case| for ([_]bool{ false, true }) |header| for ([_]bool{ false, true }) |ages| for ([_]bool{ false, true }) |working| for (std.enums.values(Screen)) |screen| for ([_]u64{ 1000, 1199 }) |awake_ms| for ([_]u16{ 46, 140 }) |width| {
        var state = try opened(&.{
            failedRow("quota0", 120, "provider_quota", if (case.remaining) |seconds| test_now_s + seconds else null),
            session("age000", .{ .idle = ago(50) }, .{ .label = "Age row", .yours = true }),
            session("work00", .{ .working = ago(10) }, .{ .label = "Working row", .yours = screen != .peer }),
        });
        defer state.deinit();
        state.now_ms += 250;
        state.list_stale = screen == .stale;
        const caps: Caps = .{ .unicode = screen != .ascii, .depth = if (screen == .colourless) .none else if (screen == .indexed) .indexed else .direct };
        const row_age = position(&state, "age000".*).?;
        const row_work = position(&state, "work00".*).?;
        const drawn: Drawn = .{
            .first = if (working) row_work else if (ages) row_age else 0,
            .end = if (ages) row_age + 1 else if (working) row_work + 1 else 0,
            .header = header,
        };
        try std.testing.expect(position(&state, "quota0".*).? >= drawn.end);
        var expected: ?u64 = if (header) case.delay else null;
        if (ages) expected = @min(expected orelse 9_750, 9_750);
        if (working and (screen == .unicode or screen == .indexed or screen == .peer)) {
            const delay: u64 = if (awake_ms == 1000) 200 else 1;
            expected = @min(expected orelse delay, delay);
        }
        try std.testing.expectEqual(if (expected) |delay| @as(?u64, awake_ms + delay) else null, nextRedrawAt(&state, drawn, caps, awake_ms));
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const text = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, width, caps));
        try std.testing.expectEqualStrings(case.text, std.mem.trim(u8, text, " "));
        if (header and !ages and !working) if (case.delay) |delay| {
            state.now_ms += delay;
            const changed = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, width, caps));
            try std.testing.expect(!std.mem.eql(u8, text, changed));
        };
    };
}

test "presentation age owner shares minute hour and day text boundaries without seconds" {
    const cases = [_]struct { age: u64, text: []const u8, delay: ?u64 }{
        .{ .age = 0, .text = "now", .delay = 59_750 },
        .{ .age = 59, .text = "now", .delay = 750 },
        .{ .age = 60, .text = "1m", .delay = 59_750 },
        .{ .age = 3599, .text = "59m", .delay = 750 },
        .{ .age = 3600, .text = "1h", .delay = 3_599_750 },
        .{ .age = 86399, .text = "23h", .delay = 750 },
        .{ .age = 86400, .text = "1d", .delay = 86_399_750 },
        .{ .age = 999 * 86400, .text = "999d", .delay = null },
    };
    const now_ms = test_now_s * 1000 + 250;
    for (cases) |case| {
        const age: Age = .{ .elapsed = test_now_s - case.age };
        var buffer: [8]u8 = undefined;
        try std.testing.expectEqualStrings(case.text, age.text(&buffer, now_ms));
        try std.testing.expectEqual(if (case.delay) |delay| @as(?u64, now_ms + delay) else null, age.nextAt(now_ms));
    }
}

test "sidebar update admission binds drawn availability run and frontend readiness" {
    const versions = [_]?upgrade_status.Version{ null, .{ .schema = 76, .patch = 0 }, .{ .schema = 77, .patch = 0 } };
    const failed: upgrade_status.Run = .{ .ended = .{ .how = .{ .failed = .download }, .outcome = .unchanged } };
    for (versions) |drawn| for (versions) |current| for ([_]?upgrade_status.Run{ null, failed, .checking }) |drawn_run| for ([_]?upgrade_status.Run{ null, failed, .checking }) |current_run| for ([_]bool{ false, true }) |admitted| {
        var state: State = undefined;
        try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
        defer state.deinit();
        _ = try step(&state, .{ .available_upgrade = current });
        state.upgrade.run = current_run;
        const expected = admitted and std.meta.eql(drawn, current) and std.meta.eql(drawn_run, current_run) and (current_run == null or !current_run.?.going());
        _ = try step(&state, .{ .clicked = .{ .target = .{ .update = .{ .available = drawn, .run = drawn_run } }, .upgrade_admitted = admitted } });
        if (expected) try std.testing.expect(state.upgrade.run.? == .checking) else try std.testing.expect(std.meta.eql(current_run, state.upgrade.run));
    };
}

test "initial presentation core releases for live answer deadline failure and Host loss" {
    const Outcome = enum { early, late, failed, empty, host_lost, host_unavailable };
    for ([_]u16{ 46, 140 }) |width| for (std.enums.values(Outcome)) |outcome| {
        var state = try testState();
        defer state.deinit();
        _ = try step(&state, .{ .launch_start = .defaults });
        _ = try step(&state, .{ .presentation_start = 1000 });
        try std.testing.expect(state.initialPresentation(true) == .holding);
        _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = width, .height = 30 }, .wide = width >= 100 } });
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        const unknown = try step(&state, .{ .presentation_tick = .{ .now_ms = 1001, .list_visible = null, .host_unavailable = false } });
        try std.testing.expect(!unknown.redraw);
        const before = try step(&state, .{ .presentation_tick = .{ .now_ms = 1149, .list_visible = true, .host_unavailable = false } });
        try std.testing.expect(!before.redraw);
        try std.testing.expect(state.initialPresentation(true) == .holding);
        const revision = state.presentation_revision;
        switch (outcome) {
            .early, .empty => {
                const partial = try step(&state, .{ .list = .{ .page = .{ .rows = &.{}, .answer = null } } });
                try std.testing.expect(!partial.redraw);
                try std.testing.expect(state.initialPresentation(true) == .holding);
                const rows = [_]Listed{session("live01", .{ .idle = ago(1) }, .{ .label = "Live Session" })};
                const answer = try respond(&state, .full, testToken(1), if (outcome == .empty) &.{} else &rows);
                try std.testing.expect(answer.redraw);
                try std.testing.expect(state.listed_at_ms != null);
                const text = try screenText(&state, width, 30, .{});
                defer std.testing.allocator.free(text);
                try std.testing.expect(std.mem.indexOf(u8, text, "Loading") == null);
                try std.testing.expect(std.mem.indexOf(u8, text, if (outcome == .empty) "No chats yet." else "Live Session") != null);
            },
            .late => {
                const deadline = try step(&state, .{ .presentation_tick = .{ .now_ms = 1150, .list_visible = true, .host_unavailable = false } });
                try std.testing.expect(deadline.redraw);
                try std.testing.expect(if (width >= 100) state.launch == .waiting else state.launch == .done);
                try std.testing.expect(state.listed_at_ms == null);
                const fallback = try screenText(&state, width, 30, .{});
                defer std.testing.allocator.free(fallback);
                try std.testing.expect(std.mem.indexOf(u8, fallback, "Loading") != null);
                const rows = [_]Listed{session("live01", .{ .idle = ago(1) }, .{ .label = "Live Session" })};
                _ = try respond(&state, .full, testToken(1), &rows);
                try std.testing.expect(state.listed_at_ms != null);
            },
            .failed => {
                const failed = try step(&state, .{ .list = .failed });
                try std.testing.expect(failed.redraw);
                try std.testing.expect(state.list_stale);
                try std.testing.expectEqual(.done, state.launch);
            },
            .host_lost => {
                const lost = try step(&state, .{ .host = null });
                try std.testing.expect(lost.redraw);
                try std.testing.expectEqual(.done, state.launch);
            },
            .host_unavailable => {
                const lost = try step(&state, .{ .presentation_tick = .{ .now_ms = 1001, .list_visible = true, .host_unavailable = true } });
                try std.testing.expect(lost.redraw);
                try std.testing.expect(if (width >= 100) state.launch == .waiting else state.launch == .done);
                try std.testing.expect(!state.hidesOverview());
            },
        }
        try std.testing.expect(state.initialPresentation(true) != .holding);
        try std.testing.expect(state.presentation_revision > revision);
        try std.testing.expectEqual(.released, state.initialPresentation(true));
        _ = try step(&state, .presentation_presented);
        try std.testing.expectEqual(.done, state.initialPresentation(true));
        const again = try step(&state, .{ .presentation_tick = .{ .now_ms = 1200, .list_visible = true, .host_unavailable = false } });
        try std.testing.expect(!again.redraw);
    };
}

test "launch core handles late list after presentation release" {
    const Release = enum { deadline, hidden, unavailable };
    const Listing = enum { empty, sessions };
    for ([_]u16{ 46, 140 }) |width| for (std.enums.values(Release)) |release| for (std.enums.values(Listing)) |listing| for ([_]bool{ false, true }) |size_first| {
        var state = try testState();
        defer state.deinit();
        _ = try step(&state, .{ .launch_start = .defaults });
        _ = try step(&state, .{ .presentation_start = 1000 });
        if (size_first) _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = width, .height = 30 }, .wide = width >= 100 } });
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        _ = try step(&state, .{ .presentation_tick = .{
            .now_ms = if (release == .deadline) 1150 else 1001,
            .list_visible = release != .hidden,
            .host_unavailable = release == .unavailable,
        } });
        try std.testing.expectEqual(.released, state.initialPresentation(true));
        if (!size_first) _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = width, .height = 30 }, .wide = width >= 100 } });
        var older = session("aaaaaa", .{ .idle = ago(1) }, .{ .first = null });
        var newest = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null });
        older.created_at = 1;
        newest.created_at = 2;
        const rows = [_]Listed{ older, newest };
        _ = try respond(&state, .full, testToken(1), if (listing == .empty) &.{} else &rows);
        const effects = try step(&state, .launch_poll);
        if (width < 100) {
            try expectEffects(&.{}, effects);
        } else if (listing == .empty) {
            try expectEffects(&.{.{ .create = null }}, effects);
        } else {
            try expectEffects(&.{ .{ .open = "bbbbbb".* }, .list_models }, effects);
        }
        try expectEffects(&.{}, try step(&state, .launch_poll));
    };
}

test "launch core drops a late launch once the overview is used" {
    for ([_]bool{ false, true }) |leave| {
        var state = try testState();
        defer state.deinit();
        _ = try step(&state, .{ .launch_start = .defaults });
        _ = try step(&state, .{ .presentation_start = 1000 });
        _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 30 }, .wide = true } });
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        _ = try step(&state, .{ .presentation_tick = .{ .now_ms = 1150, .list_visible = true, .host_unavailable = false } });
        try std.testing.expect(!state.hidesOverview());
        if (leave) {
            _ = try step(&state, .leave);
        } else {
            _ = try step(&state, .{ .open = "aaaaaa".* });
        }
        try std.testing.expectEqual(.done, state.launch);
        _ = try respond(&state, .full, testToken(1), &.{});
        try expectEffects(&.{}, try step(&state, .launch_poll));
    }
}

test "initial presentation core does not hold a narrow resumed chat" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .launch_start = .explicit_session });
    _ = try step(&state, .{ .presentation_start = 1000 });
    try std.testing.expect(state.initialPresentation(false) != .holding);
    try std.testing.expect(state.initialPresentation(true) == .holding);
    const release = try step(&state, .{ .presentation_tick = .{ .now_ms = 1001, .list_visible = false, .host_unavailable = false } });
    try std.testing.expect(release.redraw);
    try std.testing.expect(state.initialPresentation(true) != .holding);
    try std.testing.expectEqual(.done, state.launch);
}

test "launch core creation outcomes reveal or open exactly once" {
    const Outcome = enum { accepted, refused, unconfirmed };
    for (std.enums.values(Outcome)) |outcome| {
        var state = try opened(&.{});
        defer state.deinit();
        state.launch = .sizing;
        try expectEffects(&.{}, try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } }));
        try std.testing.expect(state.hidesOverview());
        const admitted = try step(&state, .launch_poll);
        try expectEffects(&.{.{ .create = null }}, admitted);
        try std.testing.expect(admitted.redraw);
        try std.testing.expect(state.hidesOverview());
        const answered = try step(&state, .{ .created = switch (outcome) {
            .accepted => .{ .created = .{ .reference = "abcdef".*, .handle = "created" } },
            .refused => .{ .failed = "model_required" },
            .unconfirmed => .{ .unconfirmed = "unknown-create" },
        } });
        try expectEffects(if (outcome == .accepted) &.{ .{ .open = "abcdef".* }, .list_models } else &.{}, answered);
        try std.testing.expect(!state.hidesOverview());
        try std.testing.expectEqual(.done, state.launch);
        switch (outcome) {
            .accepted => try std.testing.expectEqual(@as(usize, 0), state.request_count),
            .refused => try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "Not created") != null),
            .unconfirmed => {
                try std.testing.expectEqual(.unknown, state.requests[0].status);
                try std.testing.expect(state.creating());
                try say_text.expect("! Creation unsure; details on exit", state.notice.?.said());
            },
        }
        try expectEffects(&.{}, try step(&state, .launch_poll));
    }
}

test "launch core reopens newest active empty Session" {
    var older = session("aaaaaa", .{ .idle = ago(1) }, .{ .first = null });
    var newest = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null });
    var archived = session("cccccc", .{ .idle = ago(1) }, .{ .first = null, .archive_state = .archived });
    var populated = session("dddddd", .{ .idle = ago(1) }, .{});
    older.created_at = 1;
    newest.created_at = 2;
    archived.created_at = 3;
    populated.created_at = 4;
    var state = try opened(&.{ older, newest, archived, populated });
    defer state.deinit();
    state.launch = .sizing;
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    const opened_effect = try step(&state, .launch_poll);
    try expectEffects(&.{ .{ .open = "bbbbbb".* }, .list_models }, opened_effect);
    try std.testing.expect(opened_effect.redraw);
    try std.testing.expectEqual(@as(usize, 0), state.request_count);
    try std.testing.expect(!state.hidesOverview());
    try expectEffects(&.{}, try step(&state, .launch_poll));
}

/// Store rows for the launch core's domain. The matching row for `luna` is
/// older than a newer non-matching row in `behind_newer_other`; the archived
/// and populated rows match `luna` but must never be reopened.
const LaunchStore = enum { none, same, other_provider, other_model, behind_newer_other, archived_and_populated };

fn launchStoreRows(store: LaunchStore, buffer: *[2]Listed) []const Listed {
    switch (store) {
        .none => return buffer[0..0],
        .same => {
            buffer[0] = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null, .provider = pn(.codex), .model = "gpt-6-luna" });
            return buffer[0..1];
        },
        .other_provider => {
            buffer[0] = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null, .provider = pn(.openai), .model = "gpt-6-luna" });
            return buffer[0..1];
        },
        .other_model => {
            buffer[0] = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null, .provider = pn(.codex), .model = "gpt-6-sol" });
            return buffer[0..1];
        },
        .behind_newer_other => {
            buffer[0] = session("aaaaaa", .{ .idle = ago(1) }, .{ .first = null, .provider = pn(.codex), .model = "gpt-6-luna" });
            buffer[0].created_at = 1;
            buffer[1] = session("bbbbbb", .{ .idle = ago(1) }, .{ .first = null, .provider = pn(.openai), .model = "gpt-6-luna" });
            buffer[1].created_at = 2;
            return buffer[0..2];
        },
        .archived_and_populated => {
            buffer[0] = session("cccccc", .{ .idle = ago(1) }, .{ .first = null, .archive_state = .archived, .provider = pn(.codex), .model = "gpt-6-luna" });
            buffer[0].created_at = 3;
            buffer[1] = session("dddddd", .{ .idle = ago(1) }, .{ .provider = pn(.codex), .model = "gpt-6-luna" });
            buffer[1].created_at = 4;
            return buffer[0..2];
        },
    }
}

const LaunchKind = enum { defaults, named };

fn bindingIs(poll: ?Default, want: Default) bool {
    return if (poll) |resolved| resolved.eql(&want) else false;
}

/// The reference the core must reopen for this store and launch, or null for create.
fn launchReopen(store: LaunchStore, intent: LaunchKind, binding: ?Default) ?[6]u8 {
    const luna = Default.of("codex", "gpt-6-luna").?;
    const sol = Default.of("codex", "gpt-6-sol").?;
    const other_provider = Default.of("openai", "gpt-6-luna").?;
    return switch (store) {
        .none, .archived_and_populated => null,
        .same => if (intent == .defaults or bindingIs(binding, luna)) "bbbbbb".* else null,
        .other_provider => if (intent == .defaults or bindingIs(binding, other_provider)) "bbbbbb".* else null,
        .other_model => if (intent == .defaults or bindingIs(binding, sol)) "bbbbbb".* else null,
        .behind_newer_other => switch (intent) {
            .defaults => "bbbbbb".*,
            .named => if (bindingIs(binding, luna)) "aaaaaa".* else null,
        },
    };
}

test "launch core reopens the empty Session that the binding read at poll time resolves to" {
    const luna = Default.of("codex", "gpt-6-luna").?;
    const sol = Default.of("codex", "gpt-6-sol").?;
    // Bindings arrive only as `defaults_saved` events, which a null save leaves unchanged.
    // A named launch with no binding yet waits for sign-in; the poll-time binding is what
    // the later `defaults_saved` supplies, and that poll decides.
    const at_starts = [_]?Default{ null, sol };
    const at_polls = [_]?Default{ null, luna, sol };
    for (std.enums.values(LaunchKind)) |intent| for (at_starts) |at_start| for (at_polls) |at_poll| for (std.enums.values(LaunchStore)) |store| {
        var buffer: [2]Listed = undefined;
        var state = try opened(launchStoreRows(store, &buffer));
        defer state.deinit();
        if (at_start) |start| _ = try step(&state, .{ .defaults_saved = start });
        _ = try step(&state, .{ .launch_start = switch (intent) {
            .defaults => .defaults,
            .named => .named,
        } });
        _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
        if (intent == .named and at_start == null) {
            // Still waiting for sign-in: a poll and a null save both leave the overview hidden with no effect.
            try expectEffects(&.{}, try step(&state, .launch_poll));
            try std.testing.expectEqual(.waiting, state.launch);
            try std.testing.expect(state.hidesOverview());
            _ = try step(&state, .{ .defaults_saved = null });
            try expectEffects(&.{}, try step(&state, .launch_poll));
            try std.testing.expectEqual(.waiting, state.launch);
            try std.testing.expect(state.hidesOverview());
        }
        if (at_poll) |saved| _ = try step(&state, .{ .defaults_saved = saved });
        if (intent == .named and state.default == null) {
            // Still waiting: no effect until a binding is saved.
            try expectEffects(&.{}, try step(&state, .launch_poll));
            try std.testing.expectEqual(.waiting, state.launch);
            try std.testing.expect(state.hidesOverview());
            continue;
        }
        const binding = state.default;
        const effects = try step(&state, .launch_poll);
        if (launchReopen(store, intent, binding)) |reference| {
            try expectEffects(&.{ .{ .open = reference }, .list_models }, effects);
            try std.testing.expectEqual(@as(usize, 0), state.request_count);
        } else {
            try expectEffects(&.{.{ .create = binding }}, effects);
            try std.testing.expect(state.hidesOverview());
        }
        try expectEffects(&.{}, try step(&state, .launch_poll));
    };
}

test "launch core exposes overview after unsuccessful first listing" {
    for ([_]bool{ false, true }) |first_frame| {
        var state = try testState();
        defer state.deinit();
        state.launch = .sizing;
        if (first_frame) _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
        try std.testing.expectEqual(.done, state.launch);
        try std.testing.expect(!state.hidesOverview());
        _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
        try expectEffects(&.{}, try step(&state, .launch_poll));
    }
}

test "launch core exposes overview after an invalid first listing" {
    var state = try testState();
    defer state.deinit();
    state.launch = .sizing;
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    const wrong: Token = .{ .instance = @splat(0xff), .generation = 1 };
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{}, .answer = .{ .delta = .full, .since = wrong } } } });
    try std.testing.expect(state.list_stale);
    try std.testing.expectEqual(.done, state.launch);
    try std.testing.expect(!state.hidesOverview());
}

test "launch core exposes overview when Host becomes unavailable" {
    for ([_]bool{ false, true }) |first_frame| {
        var state = try testState();
        defer state.deinit();
        state.launch = .sizing;
        if (first_frame) _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
        try expectEffects(&.{}, try step(&state, .{ .host = null }));
        try std.testing.expectEqual(.done, state.launch);
        try std.testing.expect(!state.hidesOverview());
        _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
        try expectEffects(&.{}, try step(&state, .launch_poll));
    }
}

test "launch core exposes overview when Host is lost during creation" {
    var state = try opened(&.{});
    defer state.deinit();
    state.launch = .sizing;
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    _ = try step(&state, .launch_poll);
    try std.testing.expect(state.hidesOverview());
    _ = try step(&state, .{ .host = null });
    try std.testing.expectEqual(.done, state.launch);
    try std.testing.expect(!state.hidesOverview());
    try std.testing.expect(state.creating());
    _ = try step(&state, .{ .created = .{ .unconfirmed = "lost-create" } });
    try say_text.expect("! Creation unsure; details on exit", state.notice.?.said());
}

test "launch core leaves narrow overview alone after widening" {
    var state = try opened(&.{});
    defer state.deinit();
    state.launch = .sizing;
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 46, .height = 30 }, .wide = false } });
    try std.testing.expectEqual(.done, state.launch);
    try std.testing.expect(!state.hidesOverview());
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 30 }, .wide = true } });
    try expectEffects(&.{}, try step(&state, .launch_poll));
    try std.testing.expectEqual(@as(usize, 0), state.request_count);
}

test "launch admission belongs to bare app startup" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.done, state.launch);
    _ = try step(&state, .{ .launch_start = .explicit_session });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.done, state.launch);
    _ = try step(&state, .{ .launch_start = .restoring });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.done, state.launch);
    _ = try step(&state, .{ .launch_start = .defaults });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.waiting, state.launch);
}

fn creatorWidthCase() !void {
    const name = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for ([_]struct { seconds: u64, text: []const u8 }{
        .{ .seconds = 60, .text = "1m" },
        .{ .seconds = 18 * 3600, .text = "18h" },
        .{ .seconds = 24 * 3600, .text = "1d" },
    }) |age| for ([_]bool{ false, true }) |use_unicode| for ([_]u16{ 5, 8, 30, 32, 36, 40, 46, 140 }) |width| {
        var state = try opened(&.{
            session("a1b2c3", .{ .working = ago(age.seconds) }, .{ .label = "Ancestor" }),
            session("b4n8wd", .{ .finished = ago(age.seconds) }, .{ .label = name, .creator = "a1b2c3".*, .descendant_count = 2, .descendant_needs_you_count = 1 }),
            session("c3d4e5", .{ .approval = ago(1) }, .{ .label = "Question", .creator = "b4n8wd".* }),
            session("d4e5f6", .{ .working = ago(2) }, .{ .label = "Other", .creator = "b4n8wd".* }),
        });
        defer state.deinit();
        state.selected = .{ .session = "b4n8wd".* };
        _ = try press(&state, .collapse_tree);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const row = (try Lines.at(arena.allocator(), &state, 1, width, .{ .unicode = use_unicode }, 0)).?;
        try std.testing.expectEqualStrings("b4n8wd", &row.target.?.open);
        const text = try segmentText(arena.allocator(), row.segments);
        const expected_badges = switch (width) {
            5 => "",
            8 => if (use_unicode) "▸2" else ">2",
            30, 32, 36 => if (use_unicode) "▸2·1?" else ">2.1?",
            else => if (use_unicode) "▸ 2 · 1 ?" else "> 2 . 1 ?",
        };
        const badge_at = std.mem.indexOf(u8, text, if (use_unicode) "▸" else ">");
        if (expected_badges.len == 0) {
            try std.testing.expectEqual(@as(?usize, null), badge_at);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, text[badge_at.?..], expected_badges));
        }
        if (width <= 8) try std.testing.expect(std.mem.indexOfScalar(u8, text, '?') == null);
        if (width >= 30) try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, text, " "), age.text));
        const minimum_title: usize = switch (width) {
            5, 8 => 2,
            30 => 18,
            32, 40 => 20,
            else => 23,
        };
        try std.testing.expect(std.mem.indexOf(u8, text, name[0..minimum_title]) != null);
    };
}

fn creatorActivityWidthCase() !void {
    const root = session("a1b2c3", .{ .finished = ago(8) }, .{ .label = "Root" });
    const first = session("b4n8wd", .{ .finished = ago(7) }, .{ .label = "First", .creator = root.reference });
    const second = session("c3d4e5", .{ .finished = ago(6) }, .{ .label = "Second", .creator = first.reference });
    const changes = [_]struct { work: WorkState, age: []const u8, ascii_age: ?[]const u8 = null }{
        .{ .work = .{ .pending = ago(5) }, .age = "now" },
        .{ .work = .{ .working = ago(4) }, .age = "", .ascii_age = "working" },
        .{ .work = .{ .finished = ago(60) }, .age = "1m" },
        .{ .work = .{ .finished = ago(999 * 86400) }, .age = "999d" },
        .{ .work = .{ .stopping = ago(1) }, .age = "stopping" },
    };
    const widths = [_]struct { width: u16, direct_col: u16, deep_col: u16 }{
        .{ .width = 20, .direct_col = 3, .deep_col = 3 },
        .{ .width = 29, .direct_col = 3, .deep_col = 3 },
        .{ .width = 30, .direct_col = 5, .deep_col = 5 },
        .{ .width = 32, .direct_col = 5, .deep_col = 7 },
        .{ .width = 36, .direct_col = 5, .deep_col = 9 },
        .{ .width = 140, .direct_col = 5, .deep_col = 9 },
    };
    const Placement = enum { alone, direct, deep };
    for ([_]bool{ false, true }) |use_unicode| for (std.enums.values(Placement)) |placement| for ([_][]const u8{
        "Leaf café",
        "Leaf ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    }) |name| {
        const options: TestSession = .{ .label = name, .creator = switch (placement) {
            .alone => null,
            .direct => root.reference,
            .deep => second.reference,
        } };
        const leaf = session("d4e5f6", changes[0].work, options);
        const rows = [_]Listed{ leaf, root, first, second };
        const leaf_at: usize = switch (placement) {
            .alone => 0,
            .direct => 1,
            .deep => 3,
        };
        var state = try opened(rows[0 .. leaf_at + 1]);
        defer state.deinit();
        for (changes, 0..) |change, generation| {
            if (generation != 0) _ = try refresh(&state, .changed, testToken(1 + generation), &.{session("d4e5f6", change.work, options)});
            for (widths) |size| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const row = (try Lines.at(arena.allocator(), &state, leaf_at, size.width, .{ .unicode = use_unicode }, 0)).?;
                try std.testing.expectEqualStrings("d4e5f6", &row.target.?.open);
                const text = try segmentText(arena.allocator(), row.segments);
                const name_start = std.mem.indexOf(u8, text, "Leaf").?;
                const expected_col: u16 = switch (placement) {
                    .alone => 3,
                    .direct => size.direct_col,
                    .deep => size.deep_col,
                };
                const prefix = text[0..name_start];
                try std.testing.expectEqual(expected_col, gwidth.gwidth(prefix, .unicode));
                try std.testing.expectEqual(use_unicode and expected_col > 3, std.mem.indexOf(u8, prefix, "╰") != null);
                const trimmed_row = std.mem.trimEnd(u8, text, " ");
                const age_text = if (use_unicode) change.age else change.ascii_age orelse change.age;
                if (age_text.len == 0) {
                    try std.testing.expect(row.spins);
                    try std.testing.expect(!std.mem.endsWith(u8, trimmed_row, " working"));
                } else {
                    try std.testing.expect(std.mem.endsWith(u8, trimmed_row, age_text));
                }
                if (size.width >= 29 and std.mem.eql(u8, name, "Leaf café")) {
                    const shown = if (use_unicode) name else "Leaf caf?";
                    try std.testing.expect(std.mem.startsWith(u8, text[name_start..], shown));
                }
            }
        }
    };
}

fn creatorSidebarCase() !void {
    const name = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for ([_]bool{ false, true }) |use_unicode| for ([_]u16{ 36, 37, 38 }) |width| {
        var state = try opened(&.{session("a1b2c3", .{ .finished = ago(999 * 86400) }, .{ .label = name, .descendant_count = 2, .descendant_needs_you_count = 1 })});
        defer state.deinit();
        state.selected = .{ .session = "a1b2c3".* };
        _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree } } });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const line = (try Lines.at(arena.allocator(), &state, 0, width, .{ .unicode = use_unicode }, 0)).?;
        const text = try segmentText(arena.allocator(), line.segments);
        try std.testing.expect(std.mem.indexOf(u8, text, name[0..23]) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (use_unicode) "W…" else "W.") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (use_unicode) "▸2·1?" else ">2.1?") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "999d") != null);
    };
}

fn creatorPresentationCase() !void {
    const a = session("a1b2c3", .{ .working = ago(20) }, .{ .label = "A", .descendant_count = 1 });
    var b = session("b4n8wd", .{ .working = ago(30) }, .{ .label = "B" });
    var state = try opened(&.{ a, b });
    defer state.deinit();
    const unchanged = state.presentation_revision;
    _ = try refresh(&state, .full, testToken(2), &.{ a, b });
    try std.testing.expectEqual(unchanged, state.presentation_revision);
    b.creator = a.reference;
    _ = try refresh(&state, .changed, testToken(3), &.{b});
    try std.testing.expect(state.presentation_revision != unchanged);
    const nesting = state.presentation_revision;
    state.selected = .{ .session = a.reference };
    _ = try step(&state, .{ .input = .{ .key = .{ .action = .collapse_tree }, .at_ms = state.now_ms } });
    try std.testing.expect(state.presentation_revision != nesting);
    const collapsed = state.presentation_revision;
    _ = try refresh(&state, .full, testToken(4), &.{ a, b });
    try std.testing.expectEqual(collapsed, state.presentation_revision);
    const start = state.now_ms;
    const deadline = nextRedrawAt(&state, .{ .first = 0, .end = 1, .header = true }, .{ .depth = .none }, 1000).?;
    try std.testing.expectEqual(@as(u64, 1000) + state.key_until_ms - start, deadline);
    _ = try step(&state, .{ .tick = start + 3000 });
    try std.testing.expectEqual(collapsed, state.presentation_revision);
}

fn creatorFlashDeadlineCase() !void {
    const a = session("a1b2c3", .{ .working = ago(20) }, .{ .label = "A" });
    var b = session("b4n8wd", .{ .working = ago(30) }, .{ .label = "B" });
    var state = try opened(&.{ a, b });
    defer state.deinit();
    const initial = state.presentation_revision;
    _ = try step(&state, .{ .list_presence = .{ .at_ms = state.now_ms, .pointer_over = true } });
    try std.testing.expectEqual(initial, state.presentation_revision);
    b.state_change_at = test_now_s - 1;
    b.subtree_state_change_at = test_now_s - 1;
    _ = try refresh(&state, .changed, testToken(2), &.{b});
    try expectOrder(&state, &.{ "A", "B" });
    const held = state.presentation_revision;
    _ = try step(&state, .{ .list_presence = .{ .at_ms = state.now_ms, .pointer_over = false } });
    try expectOrder(&state, &.{ "B", "A" });
    try std.testing.expect(state.presentation_revision != held);
    const released = state.presentation_revision;
    const deadline = nextRedrawAt(&state, .{ .first = 0, .end = 2 }, .{ .depth = .none }, 1000).?;
    try std.testing.expectEqual(@as(u64, 1700), deadline);
    _ = try step(&state, .{ .tick = state.now_ms + 700 });
    try std.testing.expect(state.presentation_revision != released);
    try std.testing.expectEqual(@as(u64, 0), state.find(a.reference).?.flash_until_ms);
}

// Frozen against 03aa26d0. The fixture is in the base's visible order:
// approval, work (newest first), done (newest first), pending. Input is sent
// backwards; pinned ranks preserve the fixture order. No oracle reads order,
// Lines, rules, or yours. This preserves the oracle from the base test, except
// that held active rows (#1938) keep their still mark and show their word.
// Base semantics intentionally differ: focused highlight follows selected;
// unfocused highlight AND bold names follow conversing orelse selected, even
// when that reference is absent. Archive membership precedes empty projection.
const LinesDomainBase = struct {
    const Shape = enum { empty, unpinned, pinned, both };
    const Fixture = struct { listed: Listed };
    const Expected = struct { fixture: ?usize = null, gap: bool = false };
    const absent: Reference = "zzzzzz".*;

    fn fixtures() [12]Fixture {
        return .{
            .{ .listed = session("f00000", .{ .approval = ago(1) }, .{ .label = "Approval", .yours = true }) },
            .{ .listed = session("f00001", .{ .working = ago(2) }, .{ .label = "My work", .yours = true }) },
            .{ .listed = session("f00002", .{ .bash = .{ .since = test_now_s - 3, .call = 0, .description = bounded(session_work.max_description_bytes, "Build"), .running = 1, .approvals = 0 } }, .{ .label = "My Bash", .yours = true }) },
            .{ .listed = session("f00003", .{ .working = ago(4) }, .{ .label = "Other work" }) },
            .{ .listed = session("f00004", .{ .bash = .{ .since = test_now_s - 5, .call = 0, .description = bounded(session_work.max_description_bytes, "Build"), .running = 1, .approvals = 0 } }, .{ .label = "Other Bash" }) },
            .{ .listed = session("f00005", .{ .retrying = .{ .since = test_now_s - 6, .due_at_ms = (test_now_s + 60) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .{ .label = "Retry", .yours = true }) },
            .{ .listed = session("f00006", .{ .stopping = ago(7) }, .{ .label = "Stopping", .yours = true }) },
            .{ .listed = session("f00007", .{ .idle = ago(8) }, .{ .label = "Idle", .yours = true }) },
            .{ .listed = session("f00008", .{ .finished = ago(9) }, .{ .label = "Finished", .yours = true }) },
            .{ .listed = session("f00009", .{ .failed = .{ .since = test_now_s - 10, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Failed", .yours = true }) },
            .{ .listed = session("f00010", .{ .stopped = .{ .since = test_now_s - 11, .cause = .stop } }, .{ .label = "Stopped", .yours = true }) },
            .{ .listed = session("f00011", .{ .pending = ago(12) }, .{ .label = "Pending", .yours = true }) },
        };
    }

    /// The slim wire row an Archived window read carries for a Session: the decoder's shape, mapped by
    /// `Listed.archived` exactly as a window answer is.
    const WireText = struct {
        text: []const u8,

        fn slice(self: *const WireText) []const u8 {
            return self.text;
        }
    };
    const WireRow = struct {
        reference: WireText,
        archive_seq: u64,
        stopped_at: u64,
        label: ?WireText,
        first: ?struct { position: u64, admission: u64, sender: ?struct { session: WireText }, content: @FieldType(First, "content") },
        first_prefix: ?WireText,
    };

    fn throughWindow(listed: Listed, seq: u64) Listed {
        const wire: WireRow = .{
            .reference = .{ .text = &listed.reference },
            .archive_seq = seq,
            .stopped_at = test_now_s - seq,
            .label = if (listed.label) |label| WireText{ .text = label } else null,
            // A window row a Session is listed by carries its first Message, which makes it visible.
            .first = .{ .position = 0, .admission = seq, .sender = null, .content = null },
            .first_prefix = .{ .text = "archived line" },
        };
        return Listed.archived(wire);
    }

    fn selectionRef(selected: Selection) ?Reference {
        return switch (selected) {
            .session => |ref| ref,
            .none, .new_session, .sessions, .archived, .settings => null,
        };
    }

    fn same(a: ?Reference, b: Reference) bool {
        return if (a) |ref| std.mem.eql(u8, &ref, &b) else false;
    }

    fn lineOf(expected: []const Expected, fixture: []const Fixture, ref: ?Reference) ?usize {
        for (expected, 0..) |line, at| {
            if (line.fixture) |index| if (same(ref, fixture[index].listed.reference)) return at;
        }
        return null;
    }

    fn remaining(expected: []const Expected, start: usize) usize {
        var count: usize = 0;
        for (expected[@min(start, expected.len)..]) |line| count += @intFromBool(line.fixture != null);
        return count;
    }

    fn checkMove(state: *State, expected: []const Expected, fixture: []const Fixture, selected: Selection) !void {
        const at = lineOf(expected, fixture, selectionRef(selected)) orelse return;
        // A next/previous pair round-trips every row, including the last row
        // through Settings and the rows on either side of the pin gap.
        move(state, .next);
        var next: ?usize = null;
        for (expected[at + 1 ..], at + 1..) |line, index| {
            if (line.fixture != null) {
                next = index;
                break;
            }
        }
        try std.testing.expectEqual(next, Lines.highlighted(state, true));
        if (next) |index| {
            try std.testing.expect(same(selectionRef(state.selected), fixture[expected[index].fixture.?].listed.reference));
        } else try std.testing.expect(state.selected == .settings);
        move(state, .previous);
        try std.testing.expect(std.meta.eql(selected, state.selected));
        try std.testing.expectEqual(@as(?usize, at), Lines.highlighted(state, true));
    }
    fn checkBoundaries() !void {
        // Preserve the base's small-list and every pin-split boundaries without
        // multiplying the work-state Cartesian domain above.
        for (0..9) |total| for (0..total + 1) |pins| {
            var rows: [8]Listed = undefined;
            for (rows[0..total], 0..) |*row, index| {
                var ref = "aaaaaa".*;
                ref[5] += @intCast(index);
                row.* = session(&ref, .{ .finished = ago(index + 1) }, .{});
                row.pin_order = if (index < pins) 8 - index else null;
            }
            var state = try opened(rows[0..total]);
            defer state.deinit();
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const gap = pins > 0 and pins < total;
            const count = @max(1, total + @intFromBool(gap));
            try std.testing.expectEqual(count, Lines.count(&state));
            var before: usize = 0;
            for (0..count) |line| {
                const built = (try Lines.at(arena.allocator(), &state, line, 80, .{}, 0)).?;
                try std.testing.expectEqual(total - before, Lines.sessionsFrom(&state, line));
                if (total == 0 or (gap and line == pins)) {
                    try std.testing.expect(built.target == null);
                    try std.testing.expect(built.alternate == null);
                    try std.testing.expectEqual(total == 0, built.heading);
                } else {
                    const ref = rows[before].reference;
                    try std.testing.expectEqual(ref, built.target.?.open);
                    try std.testing.expectEqual(ref, built.alternate.?.pin.reference);
                    try std.testing.expectEqual(before >= pins, built.alternate.?.pin.pinned);
                    state.selected = .{ .session = ref };
                    try std.testing.expectEqual(@as(?usize, line), Lines.highlighted(&state, true));
                    try std.testing.expectEqual(@as(?usize, line), Lines.named(&state));
                    before += 1;
                }
            }
            try std.testing.expectEqual(total, before);
            try std.testing.expect((try Lines.at(arena.allocator(), &state, count, 80, .{}, 0)) == null);
            try std.testing.expectEqual(@as(usize, 0), Lines.sessionsFrom(&state, count));
            state.selected = .sessions;
            for (rows[0..total]) |row| {
                move(&state, .next);
                try std.testing.expectEqual(row.reference, state.selected.session);
            }
            move(&state, .next);
            try std.testing.expect(state.selected == .settings);
        };
    }
};

test "OVM-3 overview lines preserve navigation targets and presentation across list states" {
    var bytes_and_styles: u64 = 0;
    const D = LinesDomainBase;
    const caps_domain = [_]Caps{ .{}, .{ .depth = .none }, .{ .unicode = false } };
    // One owned fixture per outer case; frame allocations are reused per line,
    // keeping the full Cartesian product bounded independently of its size.
    for (std.enums.values(D.Shape)) |shape| for (std.enums.values(ArchiveFilter)) |filter| for (std.enums.values(ArchiveState)) |archive| {
        var fixture = D.fixtures();
        const total: usize = if (shape == .empty) 0 else fixture.len;
        // An Archived row is never pinned: its window row has no pin, so the Archived view is flat.
        const pins: usize = if (archive == .archived) 0 else switch (shape) {
            .empty, .unpinned => 0,
            .pinned => total,
            .both => total / 2,
        };
        for (fixture[0..total], 0..) |*entry, index| {
            entry.listed.archive_state = archive;
            entry.listed.pin_order = if (index < pins) @intCast(100 - index) else null;
            if (archive == .archived) {
                // The Host keys archived rows newest first; fixture order is the Host order. Each archived
                // row is the Listed that the Host's window read maps to, not a hand-set archived flag.
                entry.listed = D.throughWindow(entry.listed, total - index);
            }
        }
        if (pins > 1) {
            // Covers the first == null arm of ownership, independently of
            // from_person_at. Its pin keeps it visible with every conversation.
            fixture[1].listed.first = null;
            fixture[1].listed.from_person_at = null;
        }
        const included = switch (filter) {
            .active => archive != .archived,
            .archived => archive == .archived,
            .all => true,
        };
        const visible_count: usize = if (included) total else 0;
        const gap = visible_count != 0 and pins != 0 and pins < total;
        var expected_buffer: [13]D.Expected = undefined;
        var count: usize = 0;
        for (0..visible_count) |index| {
            if (gap and index == pins) {
                expected_buffer[count] = .{ .gap = true };
                count += 1;
            }
            expected_buffer[count] = .{ .fixture = index };
            count += 1;
        }
        if (count == 0) {
            expected_buffer[0] = .{};
            count = 1;
        }
        const expected = expected_buffer[0..count];
        var input: [12]Listed = undefined;
        for (0..total) |index| input[index] = fixture[total - 1 - index].listed;
        var state = try testState();
        defer state.deinit();
        state.size = .{ .width = 80, .height = 24 };
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        _ = try respond(&state, .full, testToken(1), input[0..total]);
        // Archived rows reach the overview through the Archived window only: the Host answers them in one page,
        // newest first, and the Archived view then holds them. The other filters take the same rows directly.
        if (archive == .archived) {
            var host: [12]Listed = undefined;
            for (0..total) |index| host[index] = fixture[index].listed;
            var window: Effects = .{};
            try changeArchiveView(&state, .archived, &window);
            try serveWindowWith(12, &state, host[0..total], window);
        }
        if (filter != .archived or archive != .archived) {
            state.archive = filter;
            try arrange(&state);
        }
        try std.testing.expectEqual(visible_count, state.order.items.len);

        var selections: [17]Selection = undefined;
        selections[0..5].* = .{ .new_session, .sessions, .archived, .settings, .{ .session = D.absent } };
        for (fixture, 5..) |entry, index| selections[index] = .{ .session = entry.listed.reference };
        for (selections) |selected| {
            const selected_ref = D.selectionRef(selected);
            const same_ref = selected_ref orelse fixture[0].listed.reference;
            const other_ref = if (D.same(same_ref, fixture[0].listed.reference)) fixture[1].listed.reference else fixture[0].listed.reference;
            for ([_]?Reference{ null, same_ref, other_ref, D.absent }) |conversing| for ([_]bool{ false, true }) |focused| for (caps_domain) |caps| for ([_]bool{ false, true }) |stale| {
                state.selected = selected;
                state.conversing = conversing;
                state.list_stale = stale;
                const bold_ref = conversing orelse selected_ref;
                const expected_selected = D.lineOf(expected, &fixture, bold_ref);
                const expected_highlight = D.lineOf(expected, &fixture, if (focused) selected_ref else bold_ref);
                try std.testing.expectEqual(@max(1, visible_count + @intFromBool(gap)), Lines.count(&state));
                try std.testing.expectEqual(expected_selected, Lines.named(&state));
                const highlight = Lines.highlighted(&state, focused);
                try std.testing.expectEqual(expected_highlight, highlight);
                var highlights: usize = 0;
                var row_at: usize = 0;
                for (expected, 0..) |line, index| {
                    try std.testing.expectEqual(D.remaining(expected, index), Lines.sessionsFrom(&state, index));
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    const row = (try Lines.at(arena.allocator(), &state, index, 80, caps, 3)) orelse return error.TestExpectedDomainLine;
                    for (row.segments) |segment| {
                        bytes_and_styles = std.hash.Wyhash.hash(bytes_and_styles, segment.text);
                        bytes_and_styles = std.hash.Wyhash.hash(bytes_and_styles, &.{ @backingInt(segment.style.colour), @backingInt(segment.style.background), @intFromBool(segment.style.bold), @intFromBool(segment.style.dim), @intFromBool(segment.style.reverse) });
                        try std.testing.expectEqual(Background.ground, segment.style.background);
                    }
                    if (highlight == index) {
                        highlights += 1;
                        try std.testing.expect(line.fixture != null);
                    }
                    if (line.fixture) |fixture_index| {
                        const entry = fixture[fixture_index];
                        row_at += 1;
                        const target = row.target orelse return error.TestExpectedDomainTarget;
                        try std.testing.expect(target == .open);
                        try std.testing.expectEqual(entry.listed.reference, target.open);
                        const alternate = row.alternate orelse return error.TestExpectedDomainAlternate;
                        try std.testing.expect(alternate == .pin);
                        try std.testing.expectEqual(entry.listed.reference, alternate.pin.reference);
                        try std.testing.expectEqual(entry.listed.pin_order == null, alternate.pin.pinned);
                        try std.testing.expectEqual(Lines.spins(&state, index, caps), row.spins);
                        const name = if (entry.listed.first == null) "New chat" else entry.listed.label.?;
                        try std.testing.expectEqual(D.same(bold_ref, entry.listed.reference), (try styleOf(row.segments, name)).bold);
                        const text = try segmentText(arena.allocator(), row.segments);
                        const marker = if (caps.unicode) " · archived" else " . archived";
                        try std.testing.expectEqual(@as(usize, @intFromBool(archive == .archived and filter != .archived)), std.mem.count(u8, text, marker));
                        try std.testing.expectEqual(@as(usize, @intFromBool(archive == .archiving)), std.mem.count(u8, text, "[Archiving]"));
                        try std.testing.expect(!row.heading);
                    } else {
                        try std.testing.expect(row.target == null);
                        try std.testing.expect(row.alternate == null);
                        try std.testing.expect(!row.spins);
                        try std.testing.expect(!Lines.spins(&state, index, caps));
                        try std.testing.expectEqual(!line.gap, row.heading);
                        const text = try segmentText(arena.allocator(), row.segments);
                        if (line.gap) {
                            try std.testing.expectEqualStrings("", std.mem.trim(u8, text, " "));
                        } else {
                            try std.testing.expect(std.mem.indexOf(u8, text, switch (filter) {
                                .active => "No chats yet",
                                .archived => "No archived chats",
                                .all => "No chats",
                            }) != null);
                        }
                    }
                }
                try std.testing.expect(highlights <= 1);
                try std.testing.expectEqual(@as(usize, @intFromBool(expected_highlight != null)), highlights);
                try std.testing.expectEqual(visible_count, row_at);
                for ([_]usize{ count, count + 1, count + 20 }) |outside| {
                    var outside_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer outside_arena.deinit();
                    try std.testing.expect((try Lines.at(outside_arena.allocator(), &state, outside, 80, caps, 3)) == null);
                    try std.testing.expectEqual(@as(usize, 0), Lines.sessionsFrom(&state, outside));
                }
                if (focused) try D.checkMove(&state, expected, &fixture, selected);
            };
        }
        // Full keyboard traversal independently checks both controls, every
        // fixture row, the gap skip, and the Settings tail in both directions.
        state.conversing = null;
        state.selected = .new_session;
        move(&state, .previous);
        try std.testing.expect(state.selected == .new_session);
        move(&state, .next);
        try std.testing.expect(std.meta.eql(state.selected, if (filter == .archived) Selection.archived else Selection.sessions));
        for (fixture[0..visible_count]) |entry| {
            move(&state, .next);
            try std.testing.expect(D.same(D.selectionRef(state.selected), entry.listed.reference));
            try std.testing.expectEqual(D.lineOf(expected, &fixture, entry.listed.reference), Lines.highlighted(&state, true));
        }
        move(&state, .next);
        try std.testing.expect(state.selected == .settings);
        move(&state, .next);
        try std.testing.expect(state.selected == .settings);
        var back = visible_count;
        while (back != 0) {
            back -= 1;
            move(&state, .previous);
            try std.testing.expect(D.same(D.selectionRef(state.selected), fixture[back].listed.reference));
            try std.testing.expectEqual(D.lineOf(expected, &fixture, fixture[back].listed.reference), Lines.highlighted(&state, true));
        }
        move(&state, .previous);
        try std.testing.expect(std.meta.eql(state.selected, if (filter == .archived) Selection.archived else Selection.sessions));
        move(&state, .previous);
        try std.testing.expect(state.selected == .new_session);
    };
    try D.checkBoundaries();
    // Recorded against base 03aa26d0, then re-recorded when #1938 made every working row spin and held rows show their word.
    // Re-recorded for the Archived window (Fix 3c). What moved, and only this:
    // - The Sessions frames (filter active, every archive state) equal main's: 431d67fdd2f5901d.
    // - An Archived row shows no mark and no work word: archived rows carry no work state.
    // - Every Archived row shows its age since stop, from the window row's stopped_at.
    // - The Archived view is flat, in the Host's order: no pin-first order and no nesting.
    try std.testing.expectEqual(@as(u64, 0x55abcd8ea50af260), bytes_and_styles);
}

fn projectionArchivedFullWalkCase() !void {
    const ref = "b4n8wd".*;
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    const active = session(&ref, .{ .working = ago(10) }, .{ .label = "Archive target", .read_version = testToken(10) });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{active}, .answer = null } } });
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    const read = effects.slice()[0].read_archived;
    const archived = session(&ref, .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .label = "Archive target", .archive_state = .archived, .archive_seq = 10 });
    _ = try step(&state, .{ .archived = .{ .read = read, .page = .{ .since = testToken(11), .rows = &.{archived}, .first = 10, .last = 10, .more_above = false, .more_below = false } } });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{}, .answer = .{ .delta = .full, .since = testToken(10) } } } });
    const row = state.find(ref).?;
    try std.testing.expectEqual(ArchiveState.archived, row.archive_state);
    try std.testing.expectEqual(@as(?u64, 10), row.archive_seq);
    try std.testing.expect(std.meta.eql(testToken(10), row.read_version.?));
    try std.testing.expectEqual(Kind.working, std.meta.activeTag(row.state));
}

fn projectionArchivedFoldCase() !void {
    const ref = "b4n8wd".*;
    var state = try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .label = "Archive target", .descendant_count = 2, .descendant_needs_you_count = 1 })});
    defer state.deinit();
    try expectEffects(&.{}, try press(&state, .collapse_tree));
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "▸ 2") != null);
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    const read = effects.slice()[0].read_archived;
    const archived = session(&ref, .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .label = "Archive target", .archive_state = .archived, .archive_seq = 10 });
    _ = try step(&state, .{ .archived = .{ .read = read, .page = .{ .since = testToken(2), .rows = &.{archived}, .first = 10, .last = 10, .more_above = false, .more_below = false } } });
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "Archive target") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "▸") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "1 ?") == null);
    try expectEffects(&.{}, try press(&state, .next_question));
}

test "SUI-3 overview_projection" {
    try projectionArchivedFullWalkCase();
    try projectionArchivedFoldCase();
    try projectionCase4();
    try projectionCase5();
    try projectionCase6();
    try projectionCase7();
    try projectionCase8();
    try projectionCase0();
    try projectionCase1();
    try projectionCase2();
    try projectionCase3();
}

fn stopLaterObservationCase() !void {
    const ref = "k7m2qx".*;
    const cases = [_]struct { work: WorkState, mark: []const u8, action: ?u64 }{
        .{ .work = .{ .approval = ago(0) }, .mark = "●", .action = 42 },
        .{ .work = .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .mark = "▪", .action = null },
    };
    for (cases) |case| for ([_]u16{ 46, 80 }) |width| {
        var state = try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .label = "Later work", .turn = 7 })});
        defer state.deinit();
        try expectEffects(&.{.{ .stop = ref }}, try press(&state, .stop));
        _ = try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .unconfirmed = "original-stop-key" } } });
        var later = session(&ref, case.work, .{ .label = "Later work", .turn = 8, .first_action = case.action });
        later.read_version = testToken(2);
        _ = try refresh(&state, .changed, testToken(2), &.{later});
        var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer departure.deinit();
        try writeDeparture(&state, null, &departure.writer);
        try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover original-stop-key") != null);
        const text = try screenText(&state, width, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.mark, markOf(text, "Later work"));
    };
}

fn stopObservationFreshnessCase() !void {
    const ref = "k7m2qx".*;
    for ([_]bool{ false, true }) |unconfirmed| {
        var state = try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .label = "Later work", .turn = 7, .read_version = testToken(10) })});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        try expectEffects(&.{.{ .stop = ref }}, try press(&state, .stop));
        if (unconfirmed) _ = try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .unconfirmed = "original-stop-key" } } });
        var foreign = testToken(12);
        foreign.instance = @splat(0xcd);
        _ = try step(&state, .{ .observed = .{
            .reference = ref,
            .read_version = foreign,
            .work = fixtureWork(.{ .state = .{ .approval = ago(0) }, .turn = 8, .first_action = 42 }),
            .opening = false,
        } });
        const foreign_text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(foreign_text);
        try std.testing.expectEqualStrings("◝", markOf(foreign_text, "Later work"));
        const reads = [_]struct { generation: u64, changed: bool, mark: []const u8 }{
            .{ .generation = 9, .changed = true, .mark = "◝" },
            .{ .generation = 10, .changed = true, .mark = "◝" },
            .{ .generation = 11, .changed = false, .mark = "◝" },
            .{ .generation = 12, .changed = true, .mark = "●" },
            .{ .generation = 10, .changed = false, .mark = "●" },
        };
        for (reads) |read| {
            _ = try step(&state, .{ .observed = .{
                .reference = ref,
                .read_version = testToken(read.generation),
                .work = if (read.changed)
                    fixtureWork(.{ .state = .{ .approval = ago(0) }, .turn = 8, .first_action = 42 })
                else
                    fixtureWork(.{ .state = .{ .working = ago(10) }, .turn = 7 }),
                .opening = false,
            } });
            const text = try screenText(&state, 80, 24, .{});
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings(read.mark, markOf(text, "Later work"));
        }
        try std.testing.expect(!conversation(&state, ref, true).stoppable);
        try expectEffects(&.{}, try press(&state, .stop));
        if (unconfirmed) {
            var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer departure.deinit();
            try writeDeparture(&state, null, &departure.writer);
            try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover original-stop-key") != null);
        }
    }
}

fn stopHostReplacementCase() !void {
    const ref = "k7m2qx".*;
    var state = try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .label = "Later work", .turn = 7 })});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    try expectEffects(&.{.{ .stop = ref }}, try press(&state, .stop));
    _ = try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .unconfirmed = "original-stop-key" } } });
    const instance: [16]u8 = @splat(0x11);
    _ = try step(&state, .{ .host = .{ .instance = instance, .started_at = test_now_s + 1, .slots = 2, .slots_in_use = 0 } });
    _ = try step(&state, .{ .observed = .{
        .reference = ref,
        .read_version = .{ .instance = instance, .generation = 1 },
        .work = fixtureWork(.{ .state = .{ .working = ago(10) }, .turn = 7 }),
        .opening = false,
    } });
    _ = try step(&state, .{ .observed = .{
        .reference = ref,
        .read_version = testToken(50),
        .work = fixtureWork(.{ .state = .{ .approval = ago(0) }, .turn = 8, .first_action = 42 }),
        .opening = false,
    } });
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("◝", markOf(before, "Later work"));
    _ = try step(&state, .{ .observed = .{
        .reference = ref,
        .read_version = .{ .instance = instance, .generation = 2 },
        .work = fixtureWork(.{ .state = .{ .approval = ago(0) }, .turn = 8, .first_action = 42 }),
        .opening = false,
    } });
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("●", markOf(after, "Later work"));
    try std.testing.expect(!conversation(&state, ref, true).stoppable);
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover original-stop-key") != null);
}

fn stopUnlistedConversationCase() !void {
    const ref = "k7m2qx".*;
    var state = try opened(&.{});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    _ = try step(&state, .{ .observed = .{
        .reference = ref,
        .read_version = testToken(2),
        .work = fixtureWork(.{ .state = .{ .working = ago(10) }, .turn = 7 }),
        .opening = false,
    } });
    try expectEffects(&.{.{ .stop = ref }}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .{ .stop = true } } }));
    _ = try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .unconfirmed = "original-stop-key" } } });
    _ = try step(&state, .{ .observed = .{
        .reference = ref,
        .read_version = testToken(3),
        .work = fixtureWork(.{ .state = .{ .approval = ago(0) }, .turn = 8, .first_action = 42 }),
        .opening = false,
    } });
    const later = session(&ref, .{ .approval = ago(0) }, .{ .label = "Later work", .turn = 8, .first_action = 42 });
    _ = try refresh(&state, .changed, testToken(4), &.{later});
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("●", markOf(text, "Later work"));
    try std.testing.expect(!conversation(&state, ref, true).stoppable);
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover original-stop-key") != null);
}

fn stopRestoredRowCase() !void {
    const ref = "k7m2qx".*;
    for ([_]bool{ false, true }) |open| for ([_]bool{ false, true }) |changed| {
        const original = session(&ref, .{ .working = ago(10) }, .{ .label = "Later work", .turn = 7 });
        var state = try opened(&.{original});
        defer state.deinit();
        try expectEffects(&.{.{ .stop = ref }}, try press(&state, .stop));
        _ = try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .unconfirmed = "original-stop-key" } } });
        if (open) _ = try step(&state, .{ .conversation = ref });
        var archived = original;
        archived.archive_state = .archived;
        archived.archive_seq = 10;
        _ = try refresh(&state, .changed, testToken(2), &.{archived});
        var restored = if (changed)
            session(&ref, .{ .approval = ago(0) }, .{ .label = "Later work", .turn = 8, .first_action = 42 })
        else
            original;
        restored.read_version = testToken(3);
        _ = try refresh(&state, .changed, testToken(3), &.{restored});
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(if (changed) "●" else "◝", markOf(text, "Later work"));
        try std.testing.expect(!conversation(&state, ref, true).stoppable);
        try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .{ .stop = true } } }));
        var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer departure.deinit();
        try writeDeparture(&state, null, &departure.writer);
        try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover original-stop-key") != null);
    };
}

test "SUI-5 stop_intent" {
    try stopRestoredRowCase();
    try stopUnlistedConversationCase();
    try stopHostReplacementCase();
    try stopLaterObservationCase();
    try stopObservationFreshnessCase();
    try stopCase2();
    try stopCase3();
    try stopCase4();
    try stopCase1();
}
