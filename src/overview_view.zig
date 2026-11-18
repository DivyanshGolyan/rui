const std = @import("std");
const session_archive = @import("session_archive.zig");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const attention = @import("attention.zig");
const change_ring = @import("change_ring.zig");
const failure_class = @import("failure_class.zig");
const state_marks = @import("marks.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const model_picker = @import("model_picker.zig");
const model_picker_view = @import("model_picker_view.zig");
const overview_style = @import("overview_style.zig");
const provider_name = @import("provider_name.zig");
const session_list = @import("session_list.zig");
const session_work = @import("session_work.zig");
const session_upgrade = @import("session_upgrade.zig");
const upgrade_status = @import("upgrade_status.zig");
const submission = @import("submission_state.zig");
const TerminalText = @import("TerminalText.zig");
const work_line = @import("work_line.zig");
const utf8_validation = @import("utf8_validation.zig");
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

const OrderClass = enum { needs_you, working, done, queued };

pub const Selection = union(enum) { new_session, sessions, archived, session: Reference, settings };
pub const Mark = state_marks.Mark;
pub const Colour = overview_style.Colour;
pub const Background = overview_style.Background;

pub const Rule = struct {
    mark: Mark,

    colour: Colour,
    word: ?[]const u8 = null,

    says: bool = false,

    spins: bool = false,

    cause: bool = false,

    stoppable: bool,
};

pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .mark = .waiting, .colour = .normal, .word = "idle", .stoppable = false },
    .pending = .{ .mark = .queued, .colour = .quiet, .stoppable = true },
    .working = .{ .mark = .active, .colour = .ink, .spins = true, .stoppable = true },
    .retrying = .{ .mark = .active, .colour = .ink, .says = true, .stoppable = true },
    .bash = .{ .mark = .active, .colour = .ink, .says = true, .spins = true, .stoppable = true },
    .approval = .{ .mark = .needs_you, .colour = .attention, .stoppable = true },
    .stopping = .{ .mark = .active, .colour = .ink, .says = true, .stoppable = false },
    .finished = .{ .mark = .none, .colour = .mark, .word = "finished", .stoppable = false },
    .failed = .{ .mark = .failed, .colour = .failure, .word = "failed", .cause = true, .stoppable = false },
    .stopped = .{ .mark = .stopped, .colour = .normal, .word = "stopped", .stoppable = false },
});

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
        };
    }
};

pub const First = struct {
    position: u64,
    admission: u64,

    sender: ?Reference,
};

pub const Listed = struct {
    reference: Reference,
    read_version: Token = .{ .instance = @splat(0), .generation = 0 },
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    created_at: u64 = 0,
    workspace: []const u8,
    provider: Provider,
    label: ?[]const u8 = null,
    state: WorkState,

    turn: ?u64 = null,

    first_action: ?u64 = null,
    first: ?First = null,

    from_person_at: ?u64 = null,
    last_line: ?session_list.LastLine = null,

    pub fn of(row: anytype) Listed {
        return .{
            .reference = referenceOf(row.reference.slice()),
            .read_version = row.read_version,
            .operation = row.work.operation,
            .archive_state = row.archive_state,
            .pin_order = row.pin_order,
            .created_at = row.created_at,
            .workspace = row.workspace.slice(),
            .provider = row.provider,
            .label = if (row.label) |*text| text.slice() else null,
            .state = row.work.state,
            .turn = row.work.turn,
            .first_action = row.work.first_action,
            .first = if (row.first_message) |*message| .{
                .position = message.position,
                .admission = message.admission,
                .sender = if (message.sender) |*sender| referenceOf(sender.session.slice()) else null,
            } else null,
            .from_person_at = row.peers.from_person_at,
            .last_line = if (row.last_line) |*last| .{ .position = last.position, .text = if (last.text) |*text| text.slice() else null } else null,
        };
    }

    fn referenceOf(bytes: []const u8) Reference {
        std.debug.assert(bytes.len == change_ring.id_bytes);
        return bytes[0..change_ring.id_bytes].*;
    }
};

pub const Answer = struct { delta: Delta, since: Token };

pub const Page = struct {
    rows: []const Listed,

    restarts: bool = false,

    answer: ?Answer,

    pub fn of(traversal: anytype, page: anytype, buffer: *[max_page_rows]Listed) Page {
        for (page.rows[0..page.count], buffer[0..page.count]) |*row, *listed| listed.* = .of(row);
        const restarts = traversal.restarts(page);
        const more = traversal.advance(page);
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

pub const Event = union(enum) {
    input: InputDelivery,
    list_settled: struct { wide: bool, focused: bool },

    resized: Size,
    launch_start: struct { explicit_session: bool, restoring: bool },
    launch_size: struct { size: Size, wide: bool },
    launch_poll,
    presentation_start: u64,
    presentation_presented,
    presentation_tick: struct { now_ms: u64, list_visible: ?bool, host_unavailable: bool },

    tick: u64,
    list: ListReply,
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

    clicked: struct { target: Click, upgrade_admitted: bool = true },

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

pub const max_unconfirmed_line_bytes = 80;

pub fn unconfirmedLine(state: *const State, buffer: *[max_unconfirmed_line_bytes]u8) ?[]const u8 {
    var at = state.request_count;
    while (at > 0) {
        at -= 1;
        const request = &state.requests[at];
        if (request.kind != .send or request.status != .unknown) continue;
        return switch (request.sent) {
            .saved => |saved| std.fmt.bufPrint(buffer, "! Not confirmed · rui request recover {s}", .{&saved.original.key}),
            else => std.fmt.bufPrint(buffer, "! {s}: send not confirmed; details on exit", .{&request.session.?}),
        } catch unreachable;
    }
    return null;
}

pub const StatusBuffer = [@max(upgrade_status.max_line_bytes, max_unconfirmed_line_bytes)]u8;

pub const StatusLine = struct { text: []const u8, colour: Colour };

pub fn statusLine(state: *const State, caps: Caps, buffer: *StatusBuffer) ?StatusLine {
    if (statusSaid(state, caps, buffer[0..upgrade_status.max_line_bytes])) |line| return line;
    const unconfirmed = unconfirmedLine(state, buffer[0..max_unconfirmed_line_bytes]) orelse return null;
    return .{ .text = unconfirmed, .colour = .attention };
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
    var rows: [max_notice_rows][]const u8 = undefined;
    var built: Spans = .of(arena, caps, width);
    const newline: []const Segment = &.{.{ .text = "\n", .style = .{} }};
    var parts: [2 * max_notice_rows][]const Segment = undefined;
    var count: usize = 0;
    for (noticeRows(line.text, width, caps, &rows), 0..) |row, at| {
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

pub const Observed = struct { read_version: Token, reference: Reference, work: session_work.Work, last_line: ?session_list.SavedLastLine = null, opening: bool };

pub const ConversationInput = union(enum) {
    other,
    stop,
    archive: ArchiveState,
    unarchive,
    pin: bool,

    cancel_upgrade,

    upgrade_failed,
};
pub const Conversed = struct { reference: Reference, work: Kind, input: ConversationInput };

pub const Read = struct { reference: Reference, position: u64, admission: u64 };

pub const Reads = struct {
    items: [max_first_line_reads]Read = undefined,
    len: usize = 0,

    pub fn slice(self: *const Reads) []const Read {
        return self.items[0..self.len];
    }
};

pub const Effect = union(enum) {
    list: ?Token,
    read_first_lines: Reads,

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

pub const Provider = provider_name.Provider;

pub const Default = struct {
    provider: Provider,
    model: Bounded(model_capability.max_model_bytes),

    pub fn of(provider: ?[]const u8, model: ?[]const u8) ?Default {
        var binding: Default = .{ .provider = std.meta.stringToEnum(Provider, provider orelse return null) orelse return null, .model = .{} };
        binding.model.set(model orelse return null) catch return null;
        return binding;
    }

    pub fn eql(self: *const Default, other: *const Default) bool {
        return self.provider == other.provider and self.model.eql(other.model.slice());
    }
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
    items: [3]Effect = undefined,
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
    text: ?[]const u8,
    notice: ?[]const u8 = null,
    stoppable: bool,
};

pub fn conversation(state: *const State, ref: Reference, work: Kind) Said {
    return .{ .text = null, .notice = footerNotice(state), .stoppable = stoppable(state, ref, work) };
}

fn statusSaid(state: *const State, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) ?StatusLine {
    const upgrade: ?upgrade_status.Line = if (state.upgrade.run) |run| upgrade_status.line(run, buffer, if (caps.unicode) .unicode else .ascii) else null;
    if (upgrade) |line| if (line.lasts == .until_done) return .{ .text = line.text, .colour = .normal };
    if (upgrade) |line| if (line.lasts == .persistent)
        return .{ .text = line.text, .colour = if (line.tone == .attention) .attention else .normal };
    return null;
}

pub const Request = struct {
    kind: enum { create, stop, archive, unarchive, pin, unpin, send },

    session: ?Reference = null,
    status: enum { pending, done, failed, unknown } = .pending,

    text: Bounded(@max(max_handle_bytes, session_work.max_code_bytes)) = .{},

    sent: submission.Recovery = .none,
};

pub const Notice = struct {
    bytes: [768]u8 = undefined,
    len: usize = 0,
    colour: Colour,

    pub fn text(self: *const Notice) []const u8 {
        return self.bytes[0..self.len];
    }
};

const FirstLineRead = union(enum) { unread, requested, unavailable, read: u32 };

pub const Row = struct {
    reference: Reference,
    listed: bool = true,
    read_version: ?Token = null,
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    created_at: u64 = 0,

    workspace: u32,
    provider: ?Provider = null,
    label: ?Bounded(max_label_bytes),
    state: WorkState,

    turn: ?u64,

    first_action: ?u64,
    first: ?First,
    from_person_at: ?u64,
    last_line: ?session_list.SavedLastLine = null,
    line: FirstLineRead = .unread,

    fn work(self: *const Row) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .operation = self.operation, .first_action = self.first_action };
    }
};

fn needsDecision(work: *const WorkState) bool {
    return switch (work.*) {
        .approval => true,
        .bash => |bash| bash.approvals != 0,
        else => false,
    };
}

pub const State = struct {
    gpa: Allocator,
    home: []const u8,

    cwd: u32,
    now_ms: u64 = 0,

    login_at: ?u64 = null,

    archive: ArchiveFilter = .active,

    listing_archive: ?ArchiveFilter = .active,
    rows: Vec(Row) = .{},

    by_reference: Vec(Keyed) = .{},

    order: Vec(u32) = .{},

    summary: Summary = .{},

    workspaces: Vec([]const u8) = .{},
    workspace_order: Vec(Keyed) = .{},

    lines: Vec(Bounded(max_line_bytes)) = .{},

    selected: Selection = .new_session,
    /// Coalesce moves until the existing application tick; no feed cache.
    browse_pending: bool = false,

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
    presentation: union(enum) { done, holding: u64, released } = .done,
    presentation_fell_back: bool = false,

    host_line: bool = false,

    menu: model_picker.Menu = .{},

    menu_revision: u64 = 0,

    menu_read: model_picker_view.Read = .unread,

    asking_models: bool = false,

    token: ?Token = null,

    seen: Vec(Seen) = .{},

    unsettled: usize = 0,

    status_changes: u64 = 0,

    presentation_revision: u64 = 0,

    arrivals: Vec(Seen) = .{},

    listing: bool = false,

    pending: Vec(Row) = .{},
    next_list_ms: u64 = 0,
    listed_at_ms: ?u64 = null,

    list_stale: bool = false,

    sort_keys: Vec(SortKey) = .{},

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
        return explicit orelse saved orelse if (self.default) |binding| @tagName(binding.provider) else null;
    }

    pub fn nextBinding(self: *const State) Binding {
        return .{ .provider = if (self.default) |binding| @tagName(binding.provider) else null, .model = if (self.default) |*binding| binding.model.slice() else null };
    }
    pub fn nextStart(self: *const State) ?Default {
        return self.default;
    }
    fn releaseModels(self: *State) void {
        self.menu_revision += 1;
        self.menu.deinit(self.gpa);
        self.menu_read = .unread;
    }

    pub fn deinit(self: *State) void {
        self.menu.deinit(self.gpa);
        for (self.workspaces.items) |bytes| self.gpa.free(bytes);
        inline for (.{ &self.rows, &self.by_reference, &self.order, &self.workspaces, &self.workspace_order, &self.lines, &self.pending, &self.sort_keys, &self.seen, &self.arrivals }) |vec| vec.deinit(self.gpa);
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
        for (self.rows.items) |*row| {
            if (!row.listed) continue;
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

    fn selectedRow(self: *const State) ?*const Row {
        if (self.selected != .session) return null;
        const row = self.find(self.selected.session) orelse return null;
        return if (visible(self, row)) row else null;
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

    fn pendingAt(self: *const State, kind: @FieldType(Request, "kind"), ref: ?Reference) ?usize {
        for (self.requests[0..self.request_count], 0..) |*held, at| {
            if (held.kind != kind or held.status != .pending) continue;
            if (ref == null or std.mem.eql(u8, &held.session.?, &ref.?)) return at;
        }
        return null;
    }

    fn request(self: *State, kind: @FieldType(Request, "kind"), ref: ?Reference) bool {
        if (self.request_count == max_requests) {
            self.say(.attention, "! Busy; try again shortly.", .{});
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
            settleRow(self, row, .{ .read_version = read.read_version, .work = read.work, .last_line = read.last_line });
            const after = RowPresentation.of(self, row);
            if (visible(self, row) and !before.eql(&after)) self.presentation_revision +%= 1;
            try arrange(self);
        };
        if (!read.opening or attention.Attention.of(read.work) == null) return;
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

pub const Counts = struct { needs_you: usize = 0, working: usize = 0, queued: usize = 0, failed: usize = 0 };

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
        return .{
            .name = Bounded(@max(max_label_bytes, max_line_bytes)).from(title(state, row).text) catch unreachable,
            .kind = shownKind(state, row),
            .since = shownSince(state, row),
            .archive = row.archive_state,
            .pin = row.pin_order,
            .yours = yours(row),
            .quiet = rowQuiet(state, row),
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
    switch (event) {
        .tick, .list, .host, .memory, .observed, .first_line, .resized, .launch_size, .launch_poll, .presentation_start, .presentation_presented, .presentation_tick, .list_settled => {},
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
            if (input.key != .ignored) state.launch = .done;
            try listInput(state, input, &effects);
        },
        .list_settled => |frame| {
            const pending = state.browse_pending;
            state.browse_pending = false;
            if (pending and frame.wide and frame.focused) {
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
        .clicked => |input| {
            state.launch = .done;
            if (!state.creating()) switch (input.target) {
                .open => |reference| try clickOpen(state, reference, &effects),
                .pin => |request| pinIntent(state, request, &effects),
                .new_session => {
                    state.selected = .new_session;
                    try enter(state, &effects);
                },
                .sessions => try selectView(state, .active, &effects),
                .archived => try selectView(state, .archived, &effects),
                .update => |target| if (input.upgrade_admitted and std.meta.eql(target, upgrade_status.Target{ .available = state.upgrade.available, .run = state.upgrade.run }) and !state.upgrading()) startUpgrade(state),
                .settings => {
                    state.selected = .settings;
                    effects.add(.open_settings);
                },
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
                .stop => stopKey(state, .{ .reference = input.reference, .work = input.work }, &effects),
                .archive => |archive| archiveIntent(state, .{ .ask = .{ .reference = input.reference, .work = input.work, .archive = archive } }, &effects),
                .unarchive => archiveIntent(state, .{ .restore = input.reference }, &effects),
                .pin => |pinned| pinIntent(state, .{ .reference = input.reference, .pinned = pinned }, &effects),
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
                    state.say(.attention, "! {s} not {s}: {s}", .{ &ref, if (result.request.pinned) "pinned" else "unpinned", code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "! {s} pin unsure; recover {s}. Nothing reordered locally.", .{ &ref, handle });
                },
            }
            state.next_list_ms = 0;
        },
        .archive => |result| {
            const kind: @FieldType(Request, "kind") = if (result.request.archived) .archive else .unarchive;
            const at = state.pendingAt(kind, result.request.reference).?;
            const ref = result.request.reference;
            switch (result.outcome) {
                .requested => {
                    state.answer(at, .done, "");
                    if (!result.request.archived) state.say(.quiet, "Restored {s}; work was not restarted.", .{&ref});
                },
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "! {s} not {s}: {s}", .{ &ref, if (result.request.archived) "archived" else "restored", code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "! {s} {s} unsure; recover {s}. Nothing hidden locally.", .{ &ref, if (result.request.archived) "archive" else "restore", handle });
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
                    state.say(.attention, "! {s} not stopped: {s}", .{ &result.reference, code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "! {s} stop unsure; details on exit", .{&result.reference});
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
                    const missing = if (std.mem.eql(u8, code, "model_capability_unavailable")) std.meta.stringToEnum(Provider, next orelse "") else null;
                    if (missing) |provider| {
                        if (provider.login()) |command|
                            state.say(.attention, "! {s} sign-in missing · {s}", .{ provider.shown(), command })
                        else
                            state.say(.attention, "! {s} sign-in missing · this terminal cannot sign in to it yet", .{provider.shown()});
                    } else state.say(.attention, "! Not created: {s}", .{code});
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.next_list_ms = 0;
                    state.say(.attention, "! Creation unsure; details on exit", .{});
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
        .launch_start => |startup| {
            if (!startup.explicit_session and !startup.restoring and !state.left and state.conversing == null) state.launch = .sizing;
        },
        .launch_size => |frame| {
            state.size = frame.size;
            if (state.launch == .sizing and frame.size.width != 0) state.launch = if (frame.wide) .waiting else .done;
        },
        .launch_poll => {
            if (state.launch == .waiting and state.listed_at_ms != null and !state.list_stale) {
                if (newestEmpty(state)) |reference| {
                    state.launch = .done;
                    state.selected = .{ .session = reference };
                    effects.add(.{ .open = reference });
                } else {
                    state.selected = .new_session;
                    try enter(state, &effects);
                    state.launch = if (state.pendingAt(.create, null) != null) .creating else .done;
                }
                effects.redraw = true;
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
                    if (state.listing) state.listing_archive = null;
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
                .pending => try writer.writeAll("rui: The new Session was not created.\n"),
                .failed => try writer.print("rui: The new Session was not created ({s}); try again from the overview.\n", .{text}),
                .unknown => try writer.print("rui: Not sure the new Session was created. Check with: rui request recover {s}\n", .{text}),
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
        }
    }
}

fn tick(state: *State, now_ms: u64, effects: *Effects) error{OutOfMemory}!void {
    const trouble = band(state);
    state.now_ms = now_ms;
    var changed = false;
    var redraw = false;
    for (state.rows.items) |*row| {
        const was = std.meta.activeTag(row.state);
        if (row.read_version) |version| settleRow(state, row, .{ .read_version = version, .work = row.work(), .last_line = row.last_line });
        const settled = was != std.meta.activeTag(row.state);
        changed = changed or settled;
        redraw = redraw or (settled and visible(state, row));
    }
    if (changed) try arrange(state);
    if (redraw or !std.meta.eql(trouble, band(state))) state.presentation_revision +%= 1;
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.listing_archive = state.archive;
        state.next_list_ms = now_ms + list_interval_ms;
        effects.add(.{ .list = state.token });
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
    if (state.listing_archive == null) {
        if (page.answer != null) {
            state.listing = false;
            state.next_list_ms = 0;
            try tick(state, state.now_ms, effects);
        }
        return;
    }
    std.debug.assert(state.listing_archive.? == state.archive);
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
        const shown = listed.state.asOf(state.now_ms);
        state.pending.appendAssumeCapacity(.{
            .reference = listed.reference,
            .read_version = listed.read_version,
            .operation = listed.operation,
            .archive_state = listed.archive_state,
            .pin_order = listed.pin_order,
            .created_at = listed.created_at,
            .workspace = try state.intern(listed.workspace),
            .provider = listed.provider,
            .label = if (listed.label) |text| labelOf(text) else null,
            .state = shown,
            .turn = listed.turn,
            .first_action = listed.first_action,
            .first = listed.first,
            .from_person_at = listed.from_person_at,
            .last_line = if (listed.last_line) |last| .{ .position = last.position, .text = if (last.text) |text| bounded(session_list.max_last_line_bytes, text) else null } else null,
        });
    }
    const answer = page.answer orelse return;
    try readListing(state);
    try commit(state, answer);
    state.listing = false;
    const held = state.holdsHost();
    state.upgrade.reobserved();
    if (held != state.holdsHost()) state.presentation_revision +%= 1;
    try readFirstLines(state, effects);
}

fn rejectPage(state: *State, page: Page) void {
    state.pending.items.len = 0;
    if (!state.list_stale) state.presentation_revision +%= 1;
    state.list_stale = true;
    state.token = null;
    if (page.answer != null) state.listing = false else state.listing_archive = null;
}

fn readListing(state: *State) error{OutOfMemory}!void {
    const opening = state.token == null;
    state.arrivals.items.len = 0;
    for (state.pending.items) |*incoming| {
        if (!state.archive.includes(incoming.archive_state)) continue;
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
    const opening = state.token == null;
    if (answer.delta == .full) for (state.rows.items) |*row| {
        row.listed = false;
    };
    if (answer.delta != .not_modified) {
        const before = state.rows.items.len;
        for (state.pending.items) |incoming| if (lookup(state.by_reference.items, incoming.reference) == null) {
            var row = incoming;
            row.read_version = null;
            try state.rows.append(state.gpa, row);
            if (visible(state, &row)) state.presentation_revision +%= 1;
        };
        if (before != state.rows.items.len) try reindex(state);
    }
    if (answer.delta != .not_modified) for (state.pending.items) |*incoming| {
        const at = lookup(state.by_reference.items, incoming.reference).?;
        const row = &state.rows.items[at];
        const was = row.*;
        const before = RowPresentation.of(state, row);
        const same = if (incoming.first) |first| if (row.first) |known| first.admission == known.admission else false else false;
        row.archive_state = incoming.archive_state;
        row.pin_order = incoming.pin_order;
        row.created_at = incoming.created_at;
        row.workspace = incoming.workspace;
        row.provider = incoming.provider;
        row.label = incoming.label;
        row.first = incoming.first;
        row.from_person_at = incoming.from_person_at;
        if (!same) row.line = .unread;
        row.listed = state.archive.includes(incoming.archive_state);
        settleRow(state, row, .{ .read_version = incoming.read_version.?, .work = incoming.work(), .last_line = incoming.last_line });
        retitle(state, row, title(state, &was).text);
        const after = RowPresentation.of(state, row);
        if (visible(state, row) and !before.eql(&after)) state.presentation_revision +%= 1;
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
    if (stale or count != state.order.items.len or !std.meta.eql(selected, state.selected) or !std.meta.eql(summary, state.summary) or !std.meta.eql(trouble, band(state))) state.presentation_revision +%= 1;
}

fn reconcileSelection(state: *State, selected_at: ?usize, opening: bool) void {
    if (state.selected == .session and state.selectedRow() == null) {
        state.selected = if (selected_at) |at| if (at < state.order.items.len) .{ .session = state.rows.items[state.order.items[at]].reference } else .new_session else .new_session;
    } else if (opening and state.selected == .new_session and state.order.items.len != 0) {
        state.selected = .{ .session = state.rows.items[state.order.items[0]].reference };
    }
}

fn settleRow(state: *const State, row: *Row, read: session_list.Snapshot) void {
    row.state = row.state.asOf(state.now_ms);
    if (!state.accepts(read.read_version)) return;
    if (row.read_version) |known| {
        if (std.mem.eql(u8, &known.instance, &read.read_version.instance) and read.read_version.generation <= known.generation) return;
    }
    row.read_version = read.read_version;
    row.state = read.work.state.asOf(state.now_ms);
    row.turn = read.work.turn;
    row.operation = read.work.operation;
    row.first_action = read.work.first_action;
    row.last_line = read.last_line;
}

fn retainRows(state: *State) error{OutOfMemory}!void {
    var kept: usize = 0;
    for (state.rows.items) |row| {
        const open = if (state.conversing) |ref| std.mem.eql(u8, &ref, &row.reference) else false;
        if (!row.listed and !open) continue;
        state.rows.items[kept] = row;
        kept += 1;
    }
    if (kept != state.rows.items.len) {
        state.rows.items.len = kept;
        try reindex(state);
    }
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

fn visible(state: *const State, row: *const Row) bool {
    return row.listed and (row.pin_order != null or row.first != null or if (state.conversing) |open| std.mem.eql(u8, &open, &row.reference) else false);
}

fn arrange(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.sort_keys.ensure(state.gpa, rows.len);
    try state.order.ensure(state.gpa, rows.len);
    state.sort_keys.items.len = 0;
    state.summary = .{};
    const latest = std.math.maxInt(u34);
    for (rows, 0..) |*row, at| {
        if (!visible(state, row)) continue;
        const queued = shownKind(state, row) == .pending;
        const since = @min(shownSince(state, row), latest);
        const age: u128 = if (queued) since else latest - since;
        state.sort_keys.appendAssumeCapacity(.{ .pin_order = row.pin_order, .key = @as(u128, @backingInt(orderClass(state, row))) << 82 | age << 48 | referenceKey(row.reference), .index = @intCast(at) });
    }
    std.mem.sortUnstable(SortKey, state.sort_keys.items, {}, struct {
        fn less(_: void, a: SortKey, b: SortKey) bool {
            if (a.pin_order) |rank| return if (b.pin_order) |other| rank > other else true;
            if (b.pin_order != null) return false;
            return a.key < b.key;
        }
    }.less);
    state.summary.counts = counts(state);
    state.order.items.len = state.sort_keys.items.len;
    for (state.order.items, state.sort_keys.items) |*slot, key| slot.* = key.index;
}

fn counts(state: *const State) Counts {
    var result: Counts = .{};
    for (state.rows.items) |*row| if (visible(state, row)) switch (rules.get(shownKind(state, row)).mark) {
        .needs_you => result.needs_you += 1,
        .active => result.working += 1,
        .queued => result.queued += 1,
        .failed => result.failed += 1,
        .waiting, .finished, .stopped, .newer, .none => {},
    };
    return result;
}

fn orderClass(state: *const State, row: *const Row) OrderClass {
    if (needsDecision((&row.state))) return .needs_you;
    return switch (shownKind(state, row)) {
        .approval => .needs_you,
        .working, .bash, .retrying, .stopping => .working,
        .finished, .failed, .stopped, .idle => .done,
        .pending => .queued,
    };
}

fn position(state: *const State, ref: Reference) ?usize {
    for (state.order.items, 0..) |row, at| if (std.mem.eql(u8, &state.rows.items[row].reference, &ref)) return at;
    return null;
}

fn readFirstLines(state: *State, effects: *Effects) error{OutOfMemory}!void {
    var reads: Reads = .{};
    for (state.order.items) |at| {
        if (reads.len == reads.items.len) break;
        const row = &state.rows.items[at];
        const first = row.first orelse continue;
        if (row.label != null or row.line != .unread) continue;
        row.line = .requested;
        reads.items[reads.len] = .{ .reference = row.reference, .position = first.position, .admission = first.admission };
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
    if (visible(state, row) and !before.eql(&after)) state.presentation_revision +%= 1;
}

const StopTarget = struct { reference: Reference, work: Kind };

fn stopKey(state: *State, exact: ?StopTarget, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    state.notice = null;
    const target = exact orelse selected: {
        const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
        break :selected StopTarget{ .reference = row.reference, .work = (&row.state).asOf(state.now_ms) };
    };
    const ref = target.reference;
    const kind = kindShown(state, ref, target.work);
    if (!rules.get(kind).stoppable) return refuseStop(state, ref, kind);
    if (state.request(.stop, ref)) effects.add(.{ .stop = ref });
}

fn refuseStop(state: *State, ref: Reference, kind: Kind) void {
    if (state.openStop(ref)) |held| if (held.status == .unknown)
        return state.say(.attention, "! {s} stop unsure; details on exit", .{&ref});
    if (rules.get(kind).word) |word_| return state.say(.quiet, "{s} is already {s}.", .{ &ref, word_ });
    std.debug.assert(kind == .stopping);
    state.say(.quiet, "{s}: {s}", .{ &ref, work_line.stopping.words });
}

fn kindShown(state: *const State, ref: Reference, work: Kind) Kind {
    return if (state.openStop(ref) != null) .stopping else work;
}

fn stoppable(state: *const State, ref: Reference, work: Kind) bool {
    return rules.get(kindShown(state, ref, work)).stoppable;
}

fn shownKind(state: *const State, row: *const Row) Kind {
    if (state.openStop(row.reference) == null and needsDecision((&row.state))) return .approval;
    return kindShown(state, row.reference, (&row.state).asOf(state.now_ms));
}

fn shownSince(state: *const State, row: *const Row) u64 {
    return (&row.state).asOf(state.now_ms).since();
}

fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    return if (state.openStop(row.reference) != null) work_line.stopping else work_line.of(words, (&row.state), null, state.now_ms);
}

fn clickOpen(state: *State, reference: Reference, effects: *Effects) error{OutOfMemory}!void {
    _ = position(state, reference) orelse return;
    state.selected = .{ .session = reference };
    try enter(state, effects);
}

fn select(state: *State, action: Action) void {
    move(state, action);
}

pub const upgrade_recovery = "! Host requests paused after Upgrade; draft retained. Upgrade or reopen with the selected Rui.";

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
    if (input == .action and input.action == .exit) {
        effects.add(.exit);
        return;
    }
    if (input == .action and input.action == .clear and state.upgrade.takesEscape()) {
        effects.add(.cancel_upgrade);
        return;
    }
    if (delivery.under or state.creating()) return;
    const before = state.selected;
    switch (input) {
        .ignored => unreachable,
        .enter => {
            state.browse_pending = false;
            try activateList(state, .enter, effects);
        },
        .left => if (state.selected == .archived) {
            state.selected = .sessions;
        },
        .action => |action| switch (action) {
            .exit => unreachable,
            .open_session => {
                state.browse_pending = false;
                switch (state.selected) {
                    .session => try activateList(state, .open_session, effects),
                    .sessions => state.selected = .archived,
                    .new_session, .archived, .settings => {},
                }
            },
            .clear => {
                state.notice = null;
                if (state.archive == .archived) try changeArchiveView(state, .active, effects);
            },
            .stop => stopKey(state, null, effects),
            .archive => archiveIntent(state, .selected_archive, effects),
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
        state.browse_pending = delivery.wide and (state.browse_pending or !std.meta.eql(before, state.selected));
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
    try enter(state, effects);
}

fn enter(state: *State, effects: *Effects) error{OutOfMemory}!void {
    try activateList(state, .enter, effects);
}

/// Enter activates any row; Right (`open_session`) and a settled browse
/// act only on a Session row.
const ListIntent = enum { enter, open_session, browse };
fn activateList(state: *State, intent: ListIntent, effects: *Effects) error{OutOfMemory}!void {
    if (state.creating()) return;
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

fn organizationHeld(state: *State, reference: Reference) bool {
    for (state.requests[0..state.request_count]) |held| {
        if (held.kind != .archive and held.kind != .unarchive and held.kind != .pin and held.kind != .unpin) continue;
        if (held.status != .pending and held.status != .unknown) continue;
        if (std.mem.eql(u8, &held.session.?, &reference)) {
            state.say(.attention, "! {s} organization request {s}; details on exit.", .{ &reference, if (held.status == .pending) "pending" else "unsure" });
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
        if (!request.archived) state.say(.quiet, "Restore request pending for {s}; waiting for the Host.", .{&request.reference});
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
    state.archive = filter;
    if (state.listing) state.listing_archive = null;
    state.token = null;
    for (state.rows.items) |*row| row.listed = false;
    try retainRows(state);
    state.pending.items.len = 0;
    var saved: [1]Bounded(max_line_bytes) = undefined;
    var saved_count: usize = 0;
    for (state.rows.items) |*row| {
        if (row.line == .read) {
            saved[saved_count] = state.lines.items[row.line.read];
            row.line = .{ .read = @intCast(saved_count) };
            saved_count += 1;
        }
    }
    state.lines.items.len = saved_count;
    @memcpy(state.lines.items, saved[0..saved_count]);
    state.selected = .new_session;
    state.listed_at_ms = null;
    state.next_list_ms = 0;
    for (state.seen.items) |*entry| {
        state.want(entry, null, false);
        entry.listed = null;
    }
    try arrange(state);
    if (!state.listing) try tick(state, state.now_ms, effects);
}

const no_selection = "! Select a Session first.";

fn move(state: *State, action: Action) void {
    const order = state.order.items;
    const current: usize = switch (state.selected) {
        .new_session => 0,
        .sessions, .archived => 1,
        .session => |ref| if (position(state, ref)) |at| at + 2 else 0,
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

pub const Trouble = enum { sign_in, api_key, quota, rate_limit };
pub const Band = struct {
    trouble: Trouble,

    sessions: u32 = 0,

    resets_at: ?u64 = null,

    provider: ?Provider = null,
};

const BandRule = struct {
    trouble: Trouble,

    kind: Kind,
    matches: *const fn ([]const u8) bool,

    after_login: bool = false,

    until_reset: bool = false,
};

const band_rules = [_]BandRule{
    .{ .trouble = .sign_in, .kind = .failed, .matches = signInCode, .after_login = true },
    .{ .trouble = .api_key, .kind = .failed, .matches = apiKeyCode, .after_login = true },
    .{ .trouble = .quota, .kind = .failed, .matches = quotaCode, .until_reset = true },
    .{ .trouble = .rate_limit, .kind = .retrying, .matches = failure_class.rateLimited },
};

fn signInCode(code: []const u8) bool {
    return failure_class.of(code) == .sign_in;
}

fn apiKeyCode(code: []const u8) bool {
    return failure_class.of(code) == .api_key;
}

fn quotaCode(code: []const u8) bool {
    return switch (failure_class.of(code)) {
        .quota, .plan => true,
        else => false,
    };
}

pub fn band(state: *const State) ?Band {
    var finished: u64 = 0;
    var newest: [band_rules.len]?struct { failed: WorkState.Failed, provider: Provider } = @splat(null);
    var retrying: [band_rules.len]u32 = @splat(0);
    for (state.rows.items) |*row| {
        if (!visible(state, row)) continue;
        const work = (&row.state).asOf(state.now_ms);
        switch (work) {
            .finished => |value| finished = @max(finished, value.since),
            .failed => |failed| for (band_rules, &newest) |rule, *held| {
                if (rule.kind == .failed and rule.matches(failed.code.slice()) and (held.* == null or held.*.?.failed.since < failed.since)) held.* = .{ .failed = failed, .provider = row.provider.? };
            },
            .retrying => |retry| for (band_rules, &retrying) |rule, *count| {
                if (rule.kind == .retrying and rule.matches(retry.cause.slice())) count.* += 1;
            },
            else => {},
        }
    }
    for (band_rules, newest, retrying) |rule, held, count| {
        if (rule.kind == .retrying) {
            if (count != 0) return .{ .trouble = rule.trouble, .sessions = count };
            continue;
        }
        const failed = (held orelse continue).failed;
        if (failed.since <= finished) continue;
        if (rule.after_login) if (state.login_at) |at| if (failed.since <= at) continue;
        if (rule.until_reset) if (failed.resets_at) |at| if (at <= state.now_ms / 1000) continue;
        return .{ .trouble = rule.trouble, .resets_at = failed.resets_at, .provider = held.?.provider };
    }
    return null;
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
        const depth: Depth = if (no_color.len != 0)
            .none
        else if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit"))
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
    var rows: [max_notice_rows][]const u8 = undefined;
    return @intCast(noticeRows(line.text, state.size.width, .{}, &rows).len);
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
        "No archived Sessions."
    else if (state.archive == .all)
        "No Sessions yet."
    else
        "No unarchived Sessions.";
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
            if (trouble.provider.?.login()) |command| {
                const run = try std.fmt.allocPrint(built.arena, "Sign-in expired. Run {s}.", .{command});
                if (run.len <= built.width -| 2) break :sign_in run;
            }
            break :sign_in try std.fmt.allocPrint(built.arena, "{s} sign-in expired.", .{trouble.provider.?.shown()});
        },
        .api_key => if (trouble.provider.?.login()) |command|
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Run {s}, then rui host pause.", .{ trouble.provider.?.shown(), command })
        else
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Save a new key, then rui host pause.", .{trouble.provider.?.shown()}),
        .quota => quota: {
            const used = if (trouble.resets_at) |at|
                try std.fmt.allocPrint(built.arena, "Quota used up. Resets in {s}.", .{(Age{ .remaining = at }).text(&buffer, now_ms)})
            else
                "Quota used up.";
            if (trouble.provider.?.usage()) |usage| {
                const managed = try std.fmt.allocPrint(built.arena, "{s} {s}", .{ used, usage });
                if (managed.len <= built.width -| 2) break :quota managed;
            }
            break :quota used;
        },
        .rate_limit => try std.fmt.allocPrint(built.arena, "Rate limited. {d} Session{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
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
    for (drawn.first..drawn.end) |at| {
        const kind = Lines.kind(state, at) orelse break;
        if (Lines.spins(state, at, caps)) {
            const deadline = awake_ms +| (spin_interval_ms - awake_ms % spin_interval_ms);
            next = @min(next orelse deadline, deadline);
        }
        if (kind == .row and hasAge(state, kind.row)) {
            const row = &state.rows.items[state.order.items[kind.row]];
            if ((Age{ .elapsed = shownSince(state, row) }).nextAt(state.now_ms)) |epoch_ms| {
                const deadline = awake_ms +| (epoch_ms -| state.now_ms);
                next = @min(next orelse deadline, deadline);
            }
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

const new_session_name = "New Session";

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
        const order = state.order.items;
        if (order.len < 2 or state.rows.items[order[0]].pin_order == null or state.rows.items[order[order.len - 1]].pin_order != null) return null;
        var low: usize = 1;
        var high = order.len - 1;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (state.rows.items[order[mid]].pin_order != null) low = mid + 1 else high = mid;
        }
        return low;
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
            .new_session, .sessions, .archived, .settings => null,
        };
    }

    fn namedSession(state: *const State) ?Reference {
        return state.conversing orelse switch (state.selected) {
            .session => |ref| ref,
            .new_session, .sessions, .archived, .settings => null,
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
        return entry == .row and rowSpins(state, entry.row, caps);
    }

    pub fn at(arena: Allocator, state: *const State, line: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}!?Line {
        const entry = kind(state, line) orelse return null;
        if (entry == .row) {
            const row = &state.rows.items[state.order.items[entry.row]];
            return .{
                .segments = try rowSegments(arena, state, entry.row, width, caps, frame),
                .target = .{ .open = row.reference },
                .alternate = .{ .pin = .{ .reference = row.reference, .pinned = row.pin_order == null } },
                .spins = rowSpins(state, entry.row, caps),
            };
        }
        var built: Spans = .of(arena, caps, width);
        built.begin();
        const spans = if (entry == .empty) try emptyLine(&built, state) else &.{};
        return .{ .segments = try segmentsOf(arena, spans, width, .{}), .heading = entry == .empty };
    }
};

fn rowSelected(state: *const State, row: *const Row) bool {
    const ref = Lines.namedSession(state) orelse return false;
    return std.mem.eql(u8, &ref, &row.reference);
}

fn hasAge(state: *const State, row: usize) bool {
    return rules.get(shownKind(state, &state.rows.items[state.order.items[row]])).mark != .active;
}

fn rowSegments(arena: Allocator, state: *const State, at: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    const row = &state.rows.items[state.order.items[at]];
    const quiet = rowQuiet(state, row);
    const rule = rules.get(shownKind(state, row));
    built.begin();
    const mark = marks.get(rule.mark);
    const glyph = if (rowSpins(state, at, caps)) spinner[frame % spinner.len] else if (caps.unicode) mark.unicode else mark.ascii;
    var words: [work_line.max_words_bytes]u8 = undefined;
    const progress = workLine(&words, state, row);
    const colour = if (progress) |line| switch (line.tone) {
        .normal => rule.colour,
        .quiet => Colour.quiet,
        .attention => Colour.attention,
    } else rule.colour;
    _ = try built.put(mark_column, glyph, 1, .{ .colour = colour, .dim = quiet });
    const named = title(state, row);
    const name = switch (row.archive_state) {
        .active, .archived => named.text,
        .archiving => try std.fmt.allocPrint(arena, "[Archiving] {s}", .{named.text}),
    };
    var buffer: [8]u8 = undefined;
    const age = if (!hasAge(state, at)) "" else (Age{ .elapsed = shownSince(state, row) }).text(&buffer, state.now_ms);
    const end = width -| 1;
    const age_cells = @min(built.measure(age), end -| text_column);
    const name_end = end -| age_cells -| @intFromBool(age_cells != 0);
    const selected = rowSelected(state, row);
    const archived = if (row.archive_state == .archived and state.archive != .archived)
        if (caps.unicode) " · archived" else " . archived"
    else
        "";
    const name_room: usize = name_end -| text_column;
    const name_cells = try built.put(text_column, name, name_room -| built.measure(archived), .{ .colour = if (selected) .strong else .normal, .bold = selected, .dim = quiet });
    _ = try built.put(text_column + name_cells, archived, name_room -| name_cells, .{ .colour = .quiet, .dim = quiet });
    _ = try built.put(end -| age_cells, age, age_cells, .{ .colour = .quiet, .dim = quiet });
    return segmentsOf(arena, try built.finish(), width, .{ .dim = quiet });
}

fn rowSpins(state: *const State, at: usize, caps: Caps) bool {
    if (state.list_stale or !caps.unicode or caps.depth == .none) return false;
    const row = &state.rows.items[state.order.items[at]];
    return yours(row) and rules.get(shownKind(state, row)).spins;
}

fn yours(row: *const Row) bool {
    return row.first == null or row.from_person_at != null;
}

fn needsPerson(state: *const State, row: *const Row) bool {
    return orderClass(state, row) == .needs_you or row.state == .failed;
}

fn rowQuiet(state: *const State, row: *const Row) bool {
    return !yours(row) and !needsPerson(state, row);
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
    inline for (.{ .{ "Sessions", Selection.sessions, ArchiveFilter.active, Click.sessions }, .{ "Archived", Selection.archived, ArchiveFilter.archived, Click.archived } }, 0..) |tab, index| {
        const start = text_column + index * 10;
        const active = state.archive == tab[2];
        const focused = state.selected == tab[1];
        const cells = try built.put(start, tab[0], width -| 1 -| start, .{
            .colour = if (active or focused) .strong else .quiet,
            .bold = active,
        });
        if (cells > 0) {
            regions[region_count] = .{ .start = @intCast(start), .end = @intCast(start + cells), .target = tab[3], .selected = focused };
            region_count += 1;
        }
    }
    return .{
        .{ .segments = new_session, .target = .new_session },
        .{ .segments = try segmentsOf(arena, try built.finish(), width, .{}), .regions = try arena.dupe(Region, regions[0..region_count]) },
    };
}

pub fn newestEmpty(state: *const State) ?Reference {
    var newest: ?*const Row = null;
    for (state.rows.items) |*row| {
        if (!row.listed or row.archive_state == .archived or row.first != null) continue;
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

pub fn footerNotice(state: *const State) ?[]const u8 {
    return if (state.notice) |*notice| notice.text() else null;
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

const TestSession = struct {
    read_version: Token = testToken(0),
    archive_state: ArchiveState = .active,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    label: ?[]const u8 = null,
    workspace: []const u8 = "/home/d/code/rui",
    provider: Provider = .codex,
    first: ?First = .{ .position = 1, .admission = 4, .sender = null },
    yours: bool = false,
    turn: ?u64 = null,
    first_action: ?u64 = null,
};

fn session(ref: *const [6]u8, state: WorkState, options: TestSession) Listed {
    return .{
        .reference = ref.*,
        .read_version = options.read_version,
        .archive_state = options.archive_state,
        .pin_order = options.pin_order,
        .workspace = options.workspace,
        .provider = options.provider,
        .label = options.label,
        .state = state,
        .turn = options.turn,
        .first_action = options.first_action,
        .first = options.first,
        .from_person_at = if (options.yours) test_now_s - 3600 else null,
    };
}

fn ago(seconds: u64) WorkState.Since {
    return .{ .since = test_now_s - seconds };
}

fn opened(rows: []const Listed) !State {
    var state = try testState();
    errdefer state.deinit();
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), rows);
    return state;
}

fn respond(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
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
            .list => |since| try std.testing.expectEqual(since, got.list),
            .read_first_lines => |reads| {
                try std.testing.expectEqual(reads.len, got.read_first_lines.len);
                for (reads.slice(), got.read_first_lines.slice()) |a, b| {
                    try std.testing.expectEqualStrings(&a.reference, &b.reference);
                    try std.testing.expectEqual(a.position, b.position);
                    try std.testing.expectEqual(a.admission, b.admission);
                }
            },
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

fn expectNotice(state: *State, expected: ?[]const u8) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try std.testing.expectEqualStrings(text, notice.text());
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
    session("f6g7h8", .{ .working = ago(90) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } }),
    session("g7h8j9", .{ .idle = ago(2 * 3600) }, .{ .label = "Check macOS socket cleanup" }),
    session("m1n2p3", .{ .finished = ago(20 * 60) }, .{ .label = "Explain provider output parsing" }),
    session("n2p3q4", .{ .finished = ago(45 * 60) }, .{ .label = "Find the commit that broke WAL" }),
    session("p3q4r5", .{ .finished = ago(3600) }, .{}),
    session("q4r5s6", .{ .finished = ago(3 * 3600) }, .{ .label = "Summarize the build cache study" }),
    session("s6t7v8", .{ .finished = ago(2 * 86400) }, .{ .label = "Check the release notes", .workspace = "/srv/work" }),
    session("v8w9x0", .{ .finished = ago(3 * 86400) }, .{ .label = "Count flaky tests" }),
    session("w9x0y1", .{ .finished = ago(4 * 86400) }, .{ .label = "Map the CI shards" }),
    session("t7v8w9", .{ .failed = .{ .since = test_now_s - 15 * 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Bisect the WAL regression", .first = .{ .position = 1, .admission = 2, .sender = "k7m2qx".* } }),
    session("x0y1z2", .{ .stopped = .{ .since = test_now_s - 30 * 60, .cause = .stop } }, .{ .label = "Rename the session tables", .first = .{ .position = 1, .admission = 3, .sender = "zzzzzz".* } }),
    session("y1z2a3", .{ .failed = .{ .since = test_now_s - 50 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .label = "Retry the flaky upload" }),
};

const kind_cases = [_]struct { state: WorkState, unicode: []const u8, ascii: []const u8, colour: Colour, stoppable: bool }{
    .{ .state = .{ .idle = ago(7200) }, .unicode = " ○ Write the notes                                                           2h", .ascii = " o Write the notes                                                           2h", .colour = .normal, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .unicode = " ◌ Write the notes                                                          now", .ascii = " : Write the notes                                                          now", .colour = .quiet, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .unicode = " ◝ Write the notes", .ascii = " * Write the notes", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .unicode = " ◝ Write the notes", .ascii = " * Write the notes", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .unicode = " ◝ Write the notes", .ascii = " * Write the notes", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .unicode = " ● Write the notes                                                           3m", .ascii = " ? Write the notes                                                           3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .unicode = " ◝ Write the notes", .ascii = " * Write the notes", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .unicode = "   Write the notes                                                          12m", .ascii = "   Write the notes                                                          12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .unicode = " × Write the notes                                                           3h", .ascii = " x Write the notes                                                           3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .unicode = " ▪ Write the notes                                                           2d", .ascii = " # Write the notes                                                           2d", .colour = .normal, .stoppable = false },
};

test "a retry that has fallen due reads as queued in its group, mark and colour" {
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

test "overview rows draw a flat order without headings" {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = try screenText(&state, 80, 40, .{});
    defer std.testing.allocator.free(text);
    inline for (.{ " Needs you ·", " Yours ·", " Active ·", " Idle ·", " Finished ·", " Stopped or failed ·", " more" }) |heading| try std.testing.expect(std.mem.indexOf(u8, text, heading) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ New Session") != null);
    try std.testing.expectEqual(mixed.len, Lines.count(&state));
}

fn expectOrder(state: *const State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.order.items.len);
    for (expected, state.order.items) |label, index| try std.testing.expectEqualStrings(label, state.rows.items[index].label.?.slice());
}

test "overview an Action wait leads regardless of sender" {
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
    try expectOrder(&state, &.{ "Theirs, asking", "Mine, asking", "Theirs, asking beside Bash", "Theirs, running Bash", "Mine, thinking", "Theirs, finished" });
    try std.testing.expectEqualStrings("a5k1ng", &state.selected.session);
}

test "overview queued rows follow done and work, longest wait first" {
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
    try expectOrder(&state, &.{ "Retrying in 18s", "Working 40s", "Stopping 50s", "Mine, working 50s", "Mine, finished 5s", "Mine, queued 70s", "Queued 40s", "Queued 25s", "Queued 10s", "Retry due" });
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
        session("aaaaaa", .{ .failed = .{ .since = test_now_s - 90, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .provider = .codex }),
        session("bbbbbb", .{ .failed = .{ .since = test_now_s - 30, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .provider = .chatgpt }),
    };
    for ([_]struct { []const Listed, []const u8 }{
        .{ &rows, "Sign-in expired. Run rui auth login chatgpt." },
        .{ rows[0..1], "Sign-in expired. Run rui auth login chatgpt --device-code." },
        .{ &.{session("cccccc", .{ .failed = .{ .since = test_now_s - 60, .code = bounded(session_work.max_code_bytes, failure_class.api_key_rejected), .resets_at = null } }, .{ .provider = .openai })}, "OpenAI API key rejected. Run rui auth login openai, then rui host pause." },
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

test "OVM-4 stop gestures follow the work state" {
    for (kind_cases) |case| {
        const rule = rules.get(case.state);
        try std.testing.expectEqual(case.stoppable, rule.stoppable);
        try std.testing.expectEqual(case.state.progress() == null, rule.word != null);
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        if (!case.stoppable) {
            try expectEffects(&.{}, try press(&state, .stop));
            var buffer: [64]u8 = undefined;
            const expected = if (rules.get(case.state).word) |said| try std.fmt.bufPrint(&buffer, "k7m2qx is already {s}.", .{said}) else "k7m2qx: Stopping";
            try expectNotice(&state, expected);
            continue;
        }
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .stop));
        try expectNotice(&state, null);
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqual(Kind.stopping, shownKind(&state, state.find("k7m2qx".*).?));
        try std.testing.expect(std.mem.indexOf(u8, text, "ctrl+x yes") == null);
        try expectEffects(&.{}, try press(&state, .stop));
        try expectNotice(&state, "k7m2qx: Stopping");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    }
}

fn expectSaid(text: ?[]const u8, stoppable_: bool, said: Said) !void {
    try std.testing.expectEqualStrings(text orelse "", said.notice orelse said.text orelse "");
    try std.testing.expectEqual(text == null, (said.notice orelse said.text) == null);
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
        const said = conversation(&state, "k7m2qx".*, .working);
        try std.testing.expect(said.text == null);
        try std.testing.expectEqualStrings(if (notice) "Copied 3 lines" else "", said.notice orelse "");
    };
    for (endings) |how| for (std.enums.values(upgrade_status.Outcome)) |outcome| {
        state.notice = null;
        state.upgrade.run = .checking;
        _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = how, .outcome = outcome } } });
        const said = conversation(&state, "k7m2qx".*, .finished);
        try std.testing.expect(said.text == null);
        try std.testing.expect(said.notice == null);
        try std.testing.expect(!said.stoppable);
    };
}

test "ctrl-x in a conversation stops its Session as on its row, listed or not" {
    var state = try testState();
    defer state.deinit();
    const ref = "k7m2qx".*;
    const ctrl_x: Conversed = .{ .reference = ref, .work = .working, .input = .stop };
    try expectSaid(null, true, conversation(&state, ref, .working));
    try expectEffects(&.{.{ .stop = ref }}, try step(&state, .{ .conversed = ctrl_x }));
    try std.testing.expect(!conversation(&state, ref, .working).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectNotice(&state, "k7m2qx: Stopping");
    try expectSaid("k7m2qx: Stopping", false, conversation(&state, ref, .working));
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .other } }));
    try std.testing.expectEqual(@as(?[]const u8, null), conversation(&state, ref, .working).text);
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNotice(&state, "! k7m2qx not stopped: session_not_found");
    try std.testing.expect(conversation(&state, ref, .working).stoppable and !conversation(&state, ref, .finished).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .finished, .input = .stop } }));
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
        listed.last_line = .{ .position = listed.read_version.generation, .text = if (activity_newer) "Older answer" else "Newest answer" };
        const observed: Observed = .{
            .read_version = testToken(if (activity_newer) 3 else 2),
            .reference = ref,
            .work = .{ .state = if (activity_newer) latest else older, .turn = if (activity_newer) 3 else 2, .operation = if (activity_newer) 3 else 2 },
            .last_line = .{ .position = if (activity_newer) 3 else 2, .text = bounded(session_list.max_last_line_bytes, if (activity_newer) "Newest answer" else "Older answer") },
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
            try std.testing.expectEqualStrings("Newest answer", row.last_line.?.text.?.slice());
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
                .work = .{ .state = if (is_newer) latest else older },
                .last_line = .{ .position = if (is_newer) 3 else 2, .text = bounded(session_list.max_last_line_bytes, if (is_newer) "Newest answer" else "Older answer") },
                .opening = false,
            } });
        }
        _ = try step(&state, .{ .conversation = null });
        _ = try respond(&state, delta, testToken(2), &.{session(&ref, older, .{})});
        const row = state.find(ref).?;
        try std.testing.expectEqualDeep(latest, row.state);
        try std.testing.expectEqualStrings("Newest answer", row.last_line.?.text.?.slice());
        try std.testing.expectEqual(latest.since(), shownSince(&state, row));
    };
}

test "leaving before a stale full or changed listing never undoes a settled stop" {
    const ref = "k7m2qx".*;
    for ([_]Delta{ .full, .changed }) |delta| {
        const old = session(&ref, .{ .stopping = ago(10) }, .{ .label = "Same Session", .turn = 7 });
        var state = try opened(&.{old});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        const stopped: session_work.Work = .{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .turn = 7 };
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(3), .reference = ref, .work = stopped, .last_line = .{ .position = 4 }, .opening = false } });
        _ = try step(&state, .{ .conversation = null });
        _ = try respond(&state, delta, testToken(2), &.{old});
        _ = try refresh(&state, .not_modified, testToken(3), &.{});
        try std.testing.expectEqualDeep(stopped, state.workOf(state.find(ref).?));
        try std.testing.expectEqual(Kind.stopped, shownKind(&state, state.find(ref).?));
        try std.testing.expectEqual(@as(u64, test_now_s), shownSince(&state, state.find(ref).?));
        var finished = session(&ref, .{ .finished = ago(0) }, .{ .label = "Same Session", .turn = 8 });
        finished.last_line = .{ .position = 5, .text = "Later listing answer" };
        _ = try refresh(&state, delta, testToken(4), &.{finished});
        try std.testing.expectEqual(Kind.finished, shownKind(&state, state.find(ref).?));
        try std.testing.expectEqualStrings("Later listing answer", state.find(ref).?.last_line.?.text.?.slice());
    }
}

test "snapshot and listing rows render identical stopped failed and done endings" {
    const ref = "k7m2qx".*;
    const cases = [_]struct { state: WorkState, text: ?[]const u8 }{
        .{ .state = .{ .stopped = .{ .since = test_now_s - 5, .cause = .stop } }, .text = null },
        .{ .state = .{ .failed = .{ .since = test_now_s - 5, .code = bounded(session_work.max_code_bytes, "malformed_provider_output"), .resets_at = null } }, .text = null },
        .{ .state = .{ .finished = ago(5) }, .text = "New completed answer" },
    };
    for (cases) |case| {
        var initial = session(&ref, .{ .working = ago(10) }, .{ .label = "Same Session", .turn = 7 });
        initial.last_line = .{ .position = 2, .text = "Old completed answer" };
        var state = try opened(&.{initial});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        const line: session_list.SavedLastLine = .{ .position = 4, .text = if (case.text) |text| bounded(session_list.max_last_line_bytes, text) else null };
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(2), .reference = ref, .work = .{ .state = case.state, .turn = 8 }, .last_line = line, .opening = false } });
        try std.testing.expectEqualDeep(case.state, state.find(ref).?.state);
        const snapshot = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(snapshot);
        var from_list = try opened(&.{initial});
        defer from_list.deinit();
        _ = try step(&from_list, .{ .conversation = ref });
        _ = try step(&from_list, .{ .tick = state.now_ms });
        var listed = session(&ref, case.state, .{ .label = "Same Session", .turn = 8 });
        listed.last_line = .{ .position = 4, .text = case.text };
        _ = try respond(&from_list, .changed, testToken(2), &.{listed});
        const listing = try screenText(&from_list, 80, 24, .{});
        defer std.testing.allocator.free(listing);
        try std.testing.expectEqualStrings(listing, snapshot);
    }
}

test "same revision retry reads cannot regress elapsed work or age" {
    const ref = "aaaaaa".*;
    for ([_]Delta{ .full, .changed }) |delta| {
        const retry = retryRow(&ref, "provider_temporary_http_429", 5);
        var state = try opened(&.{retry});
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = (test_now_s + 5) * 1000 });
        try std.testing.expectEqual(Kind.pending, shownKind(&state, state.find(ref).?));
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(1), .reference = ref, .work = .{ .state = retry.state }, .opening = false } });
        _ = try respond(&state, delta, testToken(1), &.{retry});
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(Kind.pending, shownKind(&state, state.find(ref).?));
        try std.testing.expectEqual(test_now_s + 5, shownSince(&state, state.find(ref).?));
    }
}

test "activity before metadata and an omitted open row use the same bounded row owner" {
    const ref = "aaaaaa".*;
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    const settled: Observed = .{ .read_version = testToken(3), .reference = ref, .work = .{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } } }, .last_line = .{ .position = 4 }, .opening = false };
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
    const providers = std.enums.values(Provider);
    for ([_]Delta{ .full, .changed }) |delta| for ([_]bool{ false, true }) |known| for (providers, 0..) |provider, i| {
        const other = providers[(i + 1) % providers.len];
        var state = if (known)
            try opened(&.{session(&ref, .{ .working = ago(10) }, .{ .provider = other })})
        else
            try testState();
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        const latest: Observed = .{
            .reference = ref,
            .read_version = testToken(3),
            .work = .{ .state = .{ .failed = .{ .since = test_now_s, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .turn = 8 },
            .last_line = .{ .position = 9 },
            .opening = false,
        };
        _ = try step(&state, .{ .observed = latest });
        try std.testing.expectEqual(if (known) @as(?Provider, other) else null, state.find(ref).?.provider);
        if (!known) try std.testing.expect(band(&state) == null);
        _ = try step(&state, .{ .tick = (test_now_s * 1000) + list_interval_ms });
        const metadata = session(&ref, .{ .stopping = ago(5) }, .{ .provider = provider, .label = "Listed metadata" });
        _ = try respond(&state, delta, testToken(2), &.{metadata});
        try std.testing.expectEqual(@as(?Provider, provider), state.find(ref).?.provider);
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
        try std.testing.expectEqualDeep(latest.last_line, state.find(ref).?.last_line);
        try std.testing.expectEqual(testToken(3), state.find(ref).?.read_version.?);
        try std.testing.expectEqual(test_now_s, shownSince(&state, state.find(ref).?));
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = provider }, band(&state).?);
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = provider }, band(&state).?);
        var changed = session(&ref, latest.work.state, .{ .provider = other, .turn = 8 });
        changed.last_line = .{ .position = 9, .text = null };
        _ = try refresh(&state, delta, testToken(4), &.{changed});
        try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = other }, band(&state).?);
        try std.testing.expectEqualDeep(latest.work, state.find(ref).?.work());
        try std.testing.expectEqualDeep(latest.last_line, state.find(ref).?.last_line);
    };
}

test "only a Host handshake rebases read revisions and rejects old traversals and replies" {
    const ref = "aaaaaa".*;
    var state = try opened(&.{session(&ref, .{ .stopping = ago(10) }, .{})});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = ref });
    const stopped: session_work.Work = .{ .state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } } };
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
    const finished: session_work.Work = .{ .state = .{ .finished = ago(0) } };
    _ = try step(&state, .{ .observed = .{ .read_version = next, .reference = ref, .work = finished, .last_line = .{ .position = 5, .text = bounded(session_list.max_last_line_bytes, "New Host answer") }, .opening = false } });
    _ = try step(&state, .{ .observed = .{ .read_version = testToken(200), .reference = ref, .work = stopped, .opening = false } });
    _ = try respond(&state, .not_modified, testToken(200), &.{});
    try std.testing.expect(state.token == null);
    try std.testing.expectEqualDeep(finished, state.workOf(state.find(ref).?));
    try std.testing.expectEqualStrings("New Host answer", state.find(ref).?.last_line.?.text.?.slice());
    _ = try step(&state, .{ .tick = state.next_list_ms });
    _ = try respond(&state, .full, next, &.{session(&ref, finished.state, .{})});
    try std.testing.expectEqualDeep(next, state.token.?);
    try std.testing.expectEqualDeep(finished, state.workOf(state.find(ref).?));
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
    try std.testing.expectEqualStrings("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    try std.testing.expectEqual(null, state.notice);
    _ = try press(&state, .next);
    try std.testing.expectEqualStrings("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    try expectEffects(&.{}, try step(&state, .{ .unconfirmed = .{ .reference = refs[1], .recovery = .{ .uncertain = reserved_key } } }));
    try std.testing.expectEqualStrings("! r4t9vw: send not confirmed; details on exit", unconfirmedLine(&state, &line).?);
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

test "unconfirmed stops keep their handles until departure; a full ledger refuses another" {
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
        try std.testing.expectEqual(Kind.stopping, shownKind(&state, state.find(ref.*).?));
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
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectSelected(&state, "c3d4e5");
}

test "caps follow the locale that sets the character set, NO_COLOR and COLORTERM" {
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
        reads.items[reads.len] = .{ .reference = read[0].*, .position = 1, .admission = read[1] };
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
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } });
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
    again.items[0] = .{ .reference = "f6g7h8".*, .position = 2, .admission = 12 };
    again.len = 1;
    try expectEffects(&.{.{ .read_first_lines = again }}, try refresh(&state, .changed, testToken(5), &.{session("f6g7h8", .{ .idle = ago(0) }, .{ .first = .{ .position = 2, .admission = 12, .sender = null } })}));
}

test "a first line with no answer is asked for again by the next listing" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    const rows = [_]Listed{session("h8q2mz", .{ .finished = ago(60) }, .{})};
    var reads: Reads = .{};
    reads.items[0] = .{ .reference = "h8q2mz".*, .position = 1, .admission = 4 };
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
    try expectScreenLine(&state, 0, " + New Session");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 0, " + New Session");
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, " + New Session").?..], after[std.mem.indexOf(u8, after, " + New Session").?..]);
    try std.testing.expect(std.mem.indexOf(u8, after, " ◝ Admitted before the restart") != null);
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
    try std.testing.expectEqual(OrderClass.done, orderClass(&state, state.find("e5f6g7".*).?));
    try expectEffects(&.{ .{ .open = "e5f6g7".* }, .list_models }, try submit(&state));
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   List unused build steps") != null);
    _ = try press(&state, .next);
    try expectSelected(&state, "h8q2mz");
    _ = try press(&state, .next);
    try expectSelected(&state, "t7v8w9");
    _ = try press(&state, .next);
    try expectSelected(&state, "m1n2p3");
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

fn expectEachOnce(state: *const State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.rows.items.len);
    try std.testing.expectEqual(expected.len, state.order.items.len);
    try std.testing.expectEqual(expected.len, state.by_reference.items.len);
    for (expected) |ref| {
        var seen: usize = 0;
        for (state.order.items) |at| seen += @intFromBool(std.mem.eql(u8, ref, &state.rows.items[at].reference));
        try std.testing.expectEqual(@as(usize, 1), seen);
        try std.testing.expectEqualStrings(ref, &state.find(ref[0..6].*).?.reference);
    }
}

test "merging list pages keeps each Session once" {
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
    try expectEffects(&.{.{ .list = testToken(2) }}, asked);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = nine[0..8], .answer = null } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{ a, b, c, nine[0] }, .restarts = true, .answer = null } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{nine[8]}, .answer = .{ .delta = .full, .since = testToken(6) } } } });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "eeeee0", "eeeee8" });
    try std.testing.expectEqual(testToken(6), state.token.?);

    asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{.{ .list = testToken(6) }}, asked);
    _ = try respond(&state, .not_modified, testToken(6), &.{});
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "eeeee0", "eeeee8" });

    _ = try refresh(&state, .full, testToken(7), &.{ session("aaaaaa", a.state, .{ .label = "A", .read_version = testToken(6) }), b, session("aaaaaa", .{ .finished = ago(0) }, .{ .label = "A", .read_version = testToken(7) }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb" });
    try std.testing.expect(state.find("aaaaaa".*).?.state == .finished);
}

test "a Session listed twice keeps its later row, whatever the order" {
    const a = session("aaaaaa", .{ .working = ago(10) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(20) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(30) }, .{ .label = "C" });
    var state = try opened(&.{ b, c, a, session("bbbbbb", .{ .finished = ago(0) }, .{ .label = "B", .read_version = testToken(2) }) });
    defer state.deinit();
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc" });
    try std.testing.expect(state.find("bbbbbb".*).?.state == .finished);
    try std.testing.expectEqualStrings("C", state.find("cccccc".*).?.label.?.slice());
    for (0..3) |_| {
        if (std.mem.eql(u8, &state.selected.session, "cccccc")) break;
        _ = try press(&state, .next);
    }
    try expectSelected(&state, "cccccc");
    try expectEffects(&.{.{ .stop = "cccccc".* }}, try press(&state, .stop));

    var rows: [10]Listed = undefined;
    for (&rows, 0..) |*row, n| row.* = session(&[6]u8{ 'r', 'r', 'r', 'r', 'r', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n) }, .{ .label = "R" });
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + list_interval_ms }));
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = rows[0..8], .answer = null } } });
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

test "the overview lists once a second, one listing at a time" {
    var state = try testState();
    defer state.deinit();
    const start = test_now_s * 1000;
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = start }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms + 500 }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 3 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectScreenLine(&state, 0, " + New Session");
    var screen = try Frame.of(&state, 80, 24, .{}, 0);
    defer screen.deinit();
    try expectScreenLine(&state, 2, " ● Review PR 412                                                             3m");
    try std.testing.expectEqual(Colour.attention, screen.styleAt(2, 1).?.colour);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 0, " + New Session");
}

test "a tick moves a retry that fell due to pending" {
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
            _ = try step(&state, .{ .observed = .{ .read_version = testToken(revision), .reference = ref, .work = .{ .state = settled }, .opening = false } });
            try std.testing.expectEqual(@as(?Band, null), band(&state));
            try std.testing.expectEqual(@as(?u64, null), state.wakeAt());
        }
        for ([_][]const u8{ "provider_quota", "provider_http_401" }) |code| {
            const failed = failedRow(&ref, 0, code, test_now_s + 120);
            revision += 1;
            _ = try step(&state, .{ .observed = .{ .read_version = testToken(revision), .reference = ref, .work = .{ .state = failed.state }, .opening = false } });
            try std.testing.expect(band(&state) != null);
            try std.testing.expectEqual(@as(?u64, (test_now_s + 120) * 1000), state.wakeAt());
        }
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expect(band(&state) != null);
    }
}

test "an observed retry's own deadline updates row order counts and wake through departure" {
    const ref = "aaaaaa".*;
    for ([_]u64{ 5, 20 }) |delay| {
        var state = try opened(&.{ retryRow(&ref, "provider_temporary_http_429", 10), session("bbbbbb", .{ .finished = ago(10) }, .{}) });
        defer state.deinit();
        _ = try step(&state, .{ .conversation = ref });
        _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
        const retry = retryRow(&ref, "provider_temporary_http_429", delay);
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(2), .reference = ref, .work = .{ .state = retry.state }, .opening = false } });
        try std.testing.expectEqual(@as(?u64, (test_now_s + delay) * 1000), state.wakeAt());
        try std.testing.expectEqualStrings(&ref, &state.rows.items[state.order.items[0]].reference);
        _ = try step(&state, .{ .tick = (test_now_s + delay) * 1000 });
        try std.testing.expectEqual(Kind.pending, shownKind(&state, state.find(ref).?));
        try std.testing.expectEqual(@as(u32, 1), state.summary.counts.queued);
        try std.testing.expectEqualStrings("bbbbbb", &state.rows.items[state.order.items[0]].reference);
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(Kind.pending, shownKind(&state, state.find(ref).?));
    }
}

test "the band derives provider trouble from rows, in priority order" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Done" });
    for ([_][]const u8{ "provider_http_401", "provider_sign_in_required", "provider_sign_in_refresh_token_expired" }) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
    try std.testing.expect(signInCode("provider_sign_in_refresh_token_expired") and signInCode("provider_http_401") and signInCode("provider_sign_in_required"));
    try std.testing.expect(!signInCode("provider_authentication_backend_failed"));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ session("ffffff", .{ .finished = ago(30) }, .{}), failedRow("aaaaaa", 60, "provider_http_401", null) }, null));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_http_401", null) }, test_now_s - 30));
    try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 10, "provider_http_401", null) }, test_now_s - 30)).?);
    try std.testing.expectEqual(Band{ .trouble = .api_key, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, failure_class.api_key_rejected, null) }, null)).?);
    try std.testing.expect(!signInCode(failure_class.api_key_rejected));
    try std.testing.expectEqual(Band{ .trouble = .quota, .resets_at = test_now_s + 1200, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 1200) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_plan", test_now_s) }, null));
    try std.testing.expectEqual(Band{ .trouble = .rate_limit, .sessions = 2 }, (try bandOf(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20), retryRow("cccccc", "provider_temporary_error", 20) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{retryRow("aaaaaa", "provider_temporary_error", 10)}, null));
    var state = try opened(&.{retryRow("aaaaaa", "provider_temporary_http_429", 10)});
    defer state.deinit();
    state.now_ms = (test_now_s + 10) * 1000;
    try std.testing.expectEqual(@as(?Band, null), band(&state));
    try std.testing.expectEqual(Trouble.sign_in, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), failedRow("bbbbbb", 90, "provider_http_401", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
    try std.testing.expectEqual(Trouble.quota, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
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
        .{ .provider = .chatgpt, .width = 200, .shown = managed },
        .{ .provider = .chatgpt, .width = managed.len + 2, .shown = managed },
        .{ .provider = .chatgpt, .width = managed.len + 1, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .width = 60, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .width = 40, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .resets_at = test_now_s + 1200, .width = 200, .shown = "Quota used up. Resets in 20m. " ++ usage },
        .{ .provider = .chatgpt, .resets_at = test_now_s + 1200, .width = 60, .shown = "Quota used up. Resets in 20m." },
        .{ .provider = .openai, .resets_at = test_now_s + 59, .width = 200, .shown = "Quota used up. Resets in under a minute." },
        .{ .provider = .codex, .width = 200, .shown = "Quota used up." },
        .{ .provider = .openai, .resets_at = test_now_s + 1200, .width = 200, .shown = "Quota used up. Resets in 20m." },
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
        try std.testing.expect(std.mem.indexOf(u8, text, " + New Session") != null);
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
        try std.testing.expect(std.mem.startsWith(u8, text, " + New Session") and std.mem.indexOf(u8, text, "Archived\n") != null);
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
        session("t7v8w9", .{ .stopped = .{ .since = test_now_s - 30, .cause = .stop } }, .{ .label = "Next", .first = .{ .position = 1, .admission = 2, .sender = "k7m2qx".* } }),
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
    try expectScreenLine(&state, 2, " ◝ Bell? and ?[31mred");
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
    state.say(.attention, "! Select a Session first.", .{});
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
    try std.testing.expectEqualStrings("Rui 0.61.0 installed - restart rui to continue - your draft is kept until you leave", statusLine(&state, .{ .unicode = false }, &ascii).?.text);
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
    try std.testing.expectEqualStrings(text, line.text);
    try std.testing.expectEqual(colour, line.colour);
}

fn segmentText(arena: Allocator, segments: []const Segment) ![]const u8 {
    var texts = try arena.alloc([]const u8, segments.len);
    for (segments, 0..) |segment, n| texts[n] = segment.text;
    return std.mem.concat(arena, u8, texts);
}

test "archive views remove changed rows outside the server filter and select the nearest Session" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    var b = session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" });
    const c = session("cccccc", .{ .finished = ago(3) }, .{ .label = "third" });
    var state = try opened(&.{ a, b, c });
    defer state.deinit();
    try std.testing.expectEqual(ArchiveFilter.active, state.archive);
    state.selected = .{ .session = b.reference };
    b.archive_state = .archived;
    _ = try refresh(&state, .changed, testToken(2), &.{b});
    try std.testing.expectEqual(@as(usize, 2), state.rows.items.len);
    try std.testing.expect(state.find(b.reference) == null);
    try std.testing.expectEqualStrings(&c.reference, &state.selected.session);
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try std.testing.expectEqual(ArchiveFilter.archived, state.listing_archive.?);
    try std.testing.expect(state.token == null);
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    _ = try respond(&state, .full, testToken(3), &.{ a, b });
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Archived]") == null);
    b.archive_state = .active;
    _ = try refresh(&state, .changed, testToken(4), &.{b});
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.selected == .new_session);
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

test "archive filter switch clears hidden data and discards every stale traversal page" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "private active title" });
    const archived = session("bbbbbb", .{ .stopped = .{ .since = test_now_s - 1, .cause = .stop } }, .{ .label = "saved title", .archive_state = .archived });
    var state = try opened(&.{row});
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.token == null);
    try std.testing.expect(state.listing_archive == null);
    _ = try step(&state, .{ .list = .{ .page = .{ .rows = &.{row}, .answer = null } } });
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
    const restarted = try respond(&state, .changed, testToken(2), &.{row});
    try expectEffects(&.{.{ .list = null }}, restarted);
    try std.testing.expectEqual(ArchiveFilter.archived, state.listing_archive.?);
    _ = try respond(&state, .full, testToken(3), &.{archived});
    try std.testing.expect(state.find(row.reference) == null);
    try std.testing.expect(state.find(archived.reference) != null);
    effects = .{};
    try changeArchiveView(&state, .all, &effects);
    _ = try respond(&state, .full, testToken(4), &.{ row, archived });
    try std.testing.expectEqual(@as(usize, 2), state.rows.items.len);
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

test "archive traversal stays invalid after switching away and back between pages" {
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
    const old_tail = try respond(&state, .full, testToken(2), rows[max_page_rows..]);
    try expectEffects(&.{.{ .list = null }}, old_tail);
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
    try std.testing.expect(state.token == null);
    _ = try respond(&state, .full, testToken(3), &rows);
    try std.testing.expectEqual(rows.len, state.rows.items.len);
    for (rows) |row| try std.testing.expect(state.find(row.reference) != null);
    try std.testing.expectEqual(testToken(3), state.token.?);
}

test "archive traversal stays invalid after switching away and back before not_modified" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "kept" });
    var state = try opened(&.{row});
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var effects: Effects = .{};
    try changeArchiveView(&state, .archived, &effects);
    try changeArchiveView(&state, .active, &effects);
    try expectEffects(&.{.{ .list = null }}, try respond(&state, .not_modified, testToken(1), &.{}));
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.token == null);
    _ = try respond(&state, .full, testToken(2), &.{row});
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

test "overview order covers every Kind sender age queue and reference tie" {
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
        "k50000", "k50001",
        "newwrk", "k20000",
        "k20001", "k30000",
        "k30001", "k40000",
        "k40001", "k60000",
        "k60001", "newend",
        "k00000", "k00001",
        "k70000", "k70001",
        "k80000", "k80001",
        "k90000", "k90001",
        "oldque", "k10000",
        "k10001", "dueque",
    };
    try std.testing.expectEqual(expected.len, state.order.items.len);
    for (expected, state.order.items) |ref, at| try std.testing.expectEqualStrings(ref, &state.rows.items[at].reference);
    var waiting = rows[8];
    waiting.state.bash.approvals = 1;
    _ = try refresh(&state, .changed, testToken(2), &.{waiting});
    try std.testing.expectEqualStrings("k40000", &state.rows.items[state.order.items[0]].reference);
}

test "overview refresh removes selection to next row else New Session and preserves ends" {
    const a = session("aaaaaa", .{ .working = ago(1) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(2) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(3) }, .{ .label = "C" });
    var state = try opened(&.{ a, b, c });
    defer state.deinit();
    try expectSelected(&state, "aaaaaa");
    _ = try press(&state, .next);
    _ = try refresh(&state, .full, testToken(2), &.{ a, c });
    try expectSelected(&state, "cccccc");
    _ = try refresh(&state, .full, testToken(3), &.{a});
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try refresh(&state, .full, testToken(4), &.{ a, b });
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try press(&state, .last);
    _ = try refresh(&state, .full, testToken(5), &.{});
    try std.testing.expectEqual(Selection.settings, state.selected);
    _ = try press(&state, .first);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.sessions, state.selected);
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.settings, state.selected);
    var empty = try opened(&.{});
    defer empty.deinit();
    try std.testing.expectEqual(Selection.new_session, empty.selected);
}

test "overview Listed copies last line into bounded owned rows and refresh replaces it" {
    const protocol = @import("protocol.zig");
    var source: protocol.SessionRow = .{};
    try source.reference.set("k7m2qx");
    try source.workspace.set("/work/rui/");
    source.last_line = .{ .position = 19, .text = bounded(session_list.max_last_line_bytes, "Done") };
    var state = try opened(&.{Listed.of(&source)});
    defer state.deinit();
    source.last_line.?.text.?.bytes[0] = 'X';
    const row = state.find("k7m2qx".*).?;
    try std.testing.expectEqualStrings("Done", row.last_line.?.text.?.slice());
    const longest: [session_list.max_last_line_bytes]u8 = @splat('z');
    source.last_line = .{ .position = 20, .text = bounded(session_list.max_last_line_bytes, &longest) };
    _ = try refresh(&state, .changed, testToken(2), &.{Listed.of(&source)});
    try std.testing.expectEqualStrings(&longest, state.find("k7m2qx".*).?.last_line.?.text.?.slice());
    source.last_line = .{ .position = 20, .text = null };
    _ = try refresh(&state, .changed, testToken(3), &.{Listed.of(&source)});
    try std.testing.expectEqual(@as(u64, 20), state.find("k7m2qx".*).?.last_line.?.position);
    try std.testing.expectEqual(null, state.find("k7m2qx".*).?.last_line.?.text);
    source.last_line = null;
    _ = try refresh(&state, .changed, testToken(4), &.{Listed.of(&source)});
    try std.testing.expectEqual(null, state.find("k7m2qx".*).?.last_line);
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
        const stoppable_kind = rules.get(std.meta.activeTag(case[0])).stoppable;
        if (stop != .none) {
            if (!stoppable_kind) continue;
            state.selected = .{ .session = listed.reference };
            try expectEffects(&.{.{ .stop = listed.reference }}, try press(&state, .stop));
            if (stop == .unconfirmed) _ = try step(&state, .{ .stop = .{ .reference = listed.reference, .outcome = .{ .unconfirmed = "stop-handle" } } });
            try std.testing.expect(state.openStop(listed.reference) != null);
        }
        state.selected = if (selected) .{ .session = listed.reference } else .new_session;
        const quiet = !wrote and !case[1];
        try std.testing.expectEqual(quiet, rowQuiet(&state, state.find(listed.reference).?));
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
    try std.testing.expect(!rowQuiet(&empty, empty.find("newone".*).?));
}

test "overview long name truncates while mark and state age remain visible" {
    const name = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij";
    var listed = session("k7m2qx", .{ .finished = ago(19) }, .{ .label = name, .workspace = "/work/drift" });
    listed.last_line = .{ .position = 1, .text = "A very long result that must be cut before the folder starts" };
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
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .pending }}) } }));
        try std.testing.expect(state.menu.loading() and !state.asking_models);
        try expectEffects(&.{ show, .list_models }, try openModelConsumer(&state, opening));
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .pending }}) } }));
        try expectEffects(&.{ .{ .list = testToken(1) }, .list_models }, try step(&state, .{ .tick = state.next_list_ms }));
        try expectEffects(&.{show}, try openModelConsumer(&state, opening));
        try expectEffects(&.{}, try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "model-a\n" } } }}) } }));
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
            .loading, .complete => _ = try step(&state, .{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = if (answer == .loading) .pending else .{ .live = .{ .bytes = "model-a\n" } } }}) } }),
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
        try expectEffects(&.{.{ .list = testToken(1) }}, ticked);
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
    state.say(.attention, "retained notice", .{});
    const selected = state.selected;
    try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .ignored } }));
    try std.testing.expectEqual(selected, state.selected);
    try std.testing.expect(state.notice != null);
    try std.testing.expectEqualStrings("retained notice", state.notice.?.text());
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
        state.default.?.provider = .codex;
        try std.testing.expectEqual(Provider.openai, effects.slice()[0].create.?.provider);
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
    try std.testing.expectEqualStrings("! Not created: rejected", state.notice.?.text());
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

test "upgrade holds share stop admission for both screens, and the stop goes once they clear" {
    const ref = "aaaaaa".*;
    const events = [_]Event{
        .{ .input = .{ .key = .{ .action = .stop } } },
        .{ .conversed = .{ .reference = ref, .work = .working, .input = .stop } },
    };
    for ([_]bool{ false, true }) |blocked| {
        for (events) |event| {
            var state = try opened(&.{session(&ref, .{ .working = ago(1) }, .{})});
            defer state.deinit();
            state.upgrade.after = if (blocked) .blocked else .reobserving;
            try expectEffects(&.{}, try step(&state, event));
            try std.testing.expectEqual(@as(usize, 0), state.request_count);
            try std.testing.expectEqualStrings(upgrade_recovery, state.notice.?.text());
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
            _ = try respond(&state, .full, testToken(1), &.{session(&ref, .{ .working = ago(1) }, .{ .archive_state = archive })});
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
                try std.testing.expectEqualStrings(upgrade_recovery, state.notice.?.text());
            } else if (!case.restore and archive != .active) {
                try std.testing.expect(state.notice == null);
            } else if (held != .none) {
                try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), if (held == .pending) "request pending" else "request unsure") != null);
            } else if (full) {
                try std.testing.expectEqualStrings("! Busy; try again shortly.", state.notice.?.text());
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
    try std.testing.expectEqualStrings(upgrade_recovery, footerNotice(&state).?);
    try expectEffects(&.{}, try step(&state, .start_upgrade));
    try expectStatus(&state, "Checking for updates…", .normal);
}

test "a creation the Host refuses for want of its sign-in names the sign-in and its login, if it has one" {
    for ([_]Provider{ .codex, .chatgpt }) |provider| {
        var state = try opened(&.{});
        state.default = Default.of(@tagName(provider), "gpt-6-luna");
        defer state.deinit();
        _ = try submit(&state);
        try expectEffects(&.{}, try step(&state, .{ .created = .{ .failed = "model_capability_unavailable" } }));
        const said = state.notice.?.text();
        try std.testing.expect(std.mem.indexOf(u8, said, provider.shown()) != null);
        if (provider.login()) |command|
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
        .{ .filter = .active, .text = "No unarchived Sessions." },
        .{ .filter = .archived, .text = "No archived Sessions." },
        .{ .filter = .all, .text = "No Sessions yet." },
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
        try std.testing.expect(std.mem.indexOf(u8, text, "Type a task") == null);
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
        empty.provider = .openai;
        _ = try refresh(&state, .changed, testToken(2), &.{empty});
        const row = state.find(empty.reference).?;
        try std.testing.expectEqualStrings("Renamed", row.label.?.slice());
        try std.testing.expectEqualStrings("/another/workspace", state.workspaces.items[row.workspace]);
        try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
        _ = try refresh(&state, .not_modified, testToken(2), &.{});
        try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
        empty.first = .{ .position = 8, .admission = 9, .sender = sender };
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
    for ([_]ArchiveFilter{ .active, .archived, .all }) |filter| {
        var state = try opened(&.{});
        defer state.deinit();
        state.archive = filter;
        _ = try step(&state, .{ .conversation = "empty1".* });
        _ = try refresh(&state, .full, testToken(2), &.{
            session("empty1", .{ .idle = ago(1) }, .{ .first = null, .label = "Active empty" }),
            session("empty2", .{ .idle = ago(2) }, .{ .first = null, .label = "Archived empty", .archive_state = .archived }),
            session("filled", .{ .idle = ago(3) }, .{ .label = "Archived admitted", .archive_state = .archived }),
        });
        switch (filter) {
            .active => try expectOrder(&state, &.{"Active empty"}),
            .archived => try expectOrder(&state, &.{"Archived admitted"}),
            .all => try expectOrder(&state, &.{ "Active empty", "Archived admitted" }),
        }
        _ = try step(&state, .{ .conversation = "empty2".* });
        switch (filter) {
            .active => try expectOrder(&state, &.{}),
            .archived, .all => try expectOrder(&state, &.{ "Archived empty", "Archived admitted" }),
        }
    }
}

test "empty Session projection promotes listing metadata without rolling newer observed work back" {
    var empty = session("empty1", .{ .idle = ago(5) }, .{ .first = null, .label = "Promotion" });
    var state = try opened(&.{empty});
    defer state.deinit();
    _ = try step(&state, .{ .conversation = empty.reference });
    const newest: session_work.Work = .{ .state = .{ .working = ago(1) }, .turn = 7 };
    _ = try step(&state, .{ .observed = .{ .reference = empty.reference, .read_version = testToken(4), .work = newest, .opening = false } });
    _ = try step(&state, .{ .conversation = null });
    try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
    empty.first = .{ .position = 8, .admission = 9, .sender = null };
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
            _ = try step(&state, .{ .observed = .{ .reference = empty.reference, .read_version = testToken(2), .work = .{ .state = failedRow("empty1", 1, "provider_http_401", null).state }, .opening = false } });
            try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
            try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
            try std.testing.expect(band(&state) == null);
            _ = try refresh(&state, .changed, testToken(3), &.{empty});
        }
        for ([_]Selection{ .new_session, .settings, .{ .session = "other1".* } }) |navigation| {
            state.selected = navigation;
            try std.testing.expectEqual(@as(?usize, 0), Lines.named(&state));
            try std.testing.expectEqualStrings("New Session", title(&state, &state.rows.items[state.order.items[0]]).text);
            for ([_]u16{ 46, 140 }) |width| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const built = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{}, 0)).?;
                var name_found = false;
                for (built.segments) |segment| {
                    try std.testing.expect(std.mem.indexOf(u8, segment.text, &empty.reference) == null);
                    if (std.mem.indexOf(u8, segment.text, "New Session") != null) {
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
        admitted.first = .{ .position = 1, .admission = 4, .sender = null };
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
                    try expectNotice(&state, upgrade_recovery);
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
                    .open_session => {
                        try std.testing.expect(std.meta.eql(before_notice, state.notice));
                        try std.testing.expectEqual(Selection.new_session, state.selected);
                    },
                    .previous_session, .next_session => {
                        try std.testing.expect(std.meta.eql(before_notice, state.notice));
                        try std.testing.expectEqual(Selection.new_session, state.selected);
                    },
                    .clear => try expectNotice(&state, null),
                    .stop, .archive => try expectNotice(&state, if (phase.held) upgrade_recovery else no_selection),
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
        state.browse_pending = true;
        const effects = try step(&state, .{ .input = .{ .wide = wide, .key = key } });
        try std.testing.expect(!state.browse_pending and !effects.browse_open);
        const expected: std.meta.Tag(Effect) = switch (selection) {
            .sessions, .archived => unreachable,
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
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .input = .{ .wide = true, .key = .{ .action = .next } } });
    try std.testing.expect(state.browse_pending);
    const cancelled = try step(&state, .{ .list_settled = .{ .wide = true, .focused = false } });
    try std.testing.expectEqual(@as(usize, 0), cancelled.len);
    try std.testing.expect(!state.browse_pending);
}

test "Overview browse New Session never activates until Enter and remains reachable from chat lists" {
    for ([_]bool{ false, true }) |wide| {
        var state = try opened(&mixed);
        defer state.deinit();
        state.selected = .new_session;
        state.browse_pending = true;
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
        if (guard != .upgrade) try std.testing.expectEqual(before, state.selected) else try expectNotice(&state, upgrade_recovery);
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

test "Session pins precede exactly the existing unpinned order across work changes" {
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
        state.listing_archive = filter;
        _ = try refresh(&state, .full, testToken(1), &.{row});
        try std.testing.expectEqual(@as(usize, @intFromBool(filter.includes(archive))), state.order.items.len);
        _ = try step(&state, .{ .conversation = row.reference });
        _ = try step(&state, .{ .conversation = null });
        try std.testing.expectEqual(@as(usize, @intFromBool(filter.includes(archive))), state.order.items.len);
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
        const before = state.now_ms;
        try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .sessions } }));
        try std.testing.expectEqual(Selection.sessions, state.selected);
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
        _ = try step(&state, .{ .input = .{ .key = .{ .action = .open_session } } });
        try std.testing.expectEqual(Selection.archived, state.selected);
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try std.testing.expect(hasEffect(try step(&state, .{ .input = .{ .key = .enter } }), .list));
        try std.testing.expectEqual(Selection.archived, state.selected);
        try std.testing.expectEqual(ArchiveFilter.archived, state.archive);
        _ = try respond(&state, .full, testToken(2), &.{});
        try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .archived } }));
        try expectEffects(&.{}, try step(&state, .{ .input = .{ .key = .enter } }));
        _ = try step(&state, .{ .input = .{ .key = .left } });
        try std.testing.expectEqual(Selection.sessions, state.selected);
        try std.testing.expectEqual(ArchiveFilter.archived, state.archive);
        try std.testing.expect(hasEffect(try step(&state, .{ .input = .{ .key = .enter } }), .list));
        try std.testing.expectEqual(ArchiveFilter.active, state.archive);
        try std.testing.expectEqual(before, state.now_ms);
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
        try std.testing.expect(std.mem.endsWith(u8, first, if (rules.get(work).mark == .active) " " else case[1] ++ " "));
        const again = try segmentText(arena.allocator(), (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), 46, .{}, 9)).?.segments);
        try std.testing.expect(std.mem.endsWith(u8, again, if (rules.get(work).mark == .active) " " else case[1] ++ " "));
        const now = state.now_ms;
        _ = try step(&state, .{ .conversation = "aaaaaa".* });
        _ = try step(&state, .{ .observed = .{ .reference = "aaaaaa".*, .read_version = testToken(2), .work = .{ .state = .{ .finished = .{ .since = test_now_s - 1 } } }, .opening = false } });
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
        try std.testing.expectEqual(@as(usize, 2), changed);
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
                try std.testing.expectEqualStrings(" + New Session", lines.next().?);
                try std.testing.expectEqualStrings("   Sessions  Archived", lines.next().?);
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
        const started = First{ .position = 1, .admission = 4, .sender = "a5k1ng".* };
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
        try expectRow(try rowOf(a, &state, "Investigate retry storm", 100, .{}), 100, &.{ .{ "◝", .attention }, .{ "Investigate retry storm", .normal } });
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
            if (index == 7) listed.last_line = .{ .position = 1, .text = "All tests pass." };
            var state = try opened(&.{listed});
            defer state.deinit();
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const first = (try Lines.at(arena.allocator(), &state, Lines.lineOf(&state, 0), width, .{}, 0)).?.segments;
            const prefix = try std.fmt.allocPrint(arena.allocator(), "{s}A useful Session name", .{([_][]const u8{ "○ ", "◌ ", "◝ ", "◝ ", "◝ ", "● ", "◝ ", "", "× ", "▪ " })[index]});
            var buffer: [8]u8 = undefined;
            const expected = [_][]const u8{ prefix, (Age{ .elapsed = listed.state.since() }).text(&buffer, state.now_ms) };
            try expectLine(first, width, expected[0..if (rules.get(shownKind(&state, &state.rows.items[0])).mark == .active) @as(usize, 1) else 2]);
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
            try std.testing.expectEqualStrings("◝", markOf(text, "Theirs, thinking"));
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
        try std.testing.expectEqualStrings("◝", markOf(asked, "Mine, thinking"));
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
        const active = switch (work) {
            .working, .retrying, .bash, .stopping => true,
            else => false,
        };
        if (active) {
            try std.testing.expectEqualStrings(prefix, std.mem.trimEnd(u8, text, " "));
        } else {
            const suffix = try std.fmt.allocPrint(arena.allocator(), "{s} ", .{age.text});
            try std.testing.expectEqualStrings(suffix, text[text.len - suffix.len ..]);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, "✓") == null);
        try std.testing.expectEqual(@as(usize, width), measured(caps, unicode_glyphs, text));
        const action = try segmentText(arena.allocator(), ((try controls(arena.allocator(), &state, width, caps))[0]).segments);
        try std.testing.expect(std.mem.startsWith(u8, action, " + New Session"));
        try std.testing.expectEqual(@as(usize, text_column), std.mem.indexOf(u8, action, "New Session").?);
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
        try std.testing.expect(!anySpins(&state, .{}));
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
        if (working and (screen == .unicode or screen == .indexed)) {
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
        _ = try step(&state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
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
                try std.testing.expect(std.mem.indexOf(u8, text, if (outcome == .empty) "No unarchived Sessions." else "Live Session") != null);
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
        _ = try step(&state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
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
        _ = try step(&state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
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
    _ = try step(&state, .{ .launch_start = .{ .explicit_session = true, .restoring = false } });
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
                try std.testing.expectEqualStrings("! Creation unsure; details on exit", state.notice.?.text());
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
    try std.testing.expectEqualStrings("! Creation unsure; details on exit", state.notice.?.text());
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
    _ = try step(&state, .{ .launch_start = .{ .explicit_session = true, .restoring = false } });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.done, state.launch);
    _ = try step(&state, .{ .launch_start = .{ .explicit_session = false, .restoring = true } });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.done, state.launch);
    _ = try step(&state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
    _ = try step(&state, .{ .launch_size = .{ .size = .{ .width = 140, .height = 40 }, .wide = true } });
    try std.testing.expectEqual(.waiting, state.launch);
}
// Frozen against 03aa26d0. The fixture is in the base's visible order:
// approval, work (newest first), done (newest first), pending. Input is sent
// backwards; pinned ranks preserve the fixture order. No oracle reads order,
// Lines, rules, or yours. This preserves the oracle from the base test.
// Base semantics intentionally differ: focused highlight follows selected;
// unfocused highlight AND bold names follow conversing orelse selected, even
// when that reference is absent. Archive membership precedes empty projection.
const LinesDomainBase = struct {
    const Shape = enum { empty, unpinned, pinned, both };
    const Fixture = struct { listed: Listed, spins: bool };
    const Expected = struct { fixture: ?usize = null, gap: bool = false };
    const absent: Reference = "zzzzzz".*;

    fn fixtures() [12]Fixture {
        return .{
            .{ .listed = session("f00000", .{ .approval = ago(1) }, .{ .label = "Approval", .yours = true }), .spins = false },
            .{ .listed = session("f00001", .{ .working = ago(2) }, .{ .label = "My work", .yours = true }), .spins = true },
            .{ .listed = session("f00002", .{ .bash = .{ .since = test_now_s - 3, .call = 0, .description = bounded(session_work.max_description_bytes, "Build"), .running = 1, .approvals = 0 } }, .{ .label = "My Bash", .yours = true }), .spins = true },
            .{ .listed = session("f00003", .{ .working = ago(4) }, .{ .label = "Other work" }), .spins = false },
            .{ .listed = session("f00004", .{ .bash = .{ .since = test_now_s - 5, .call = 0, .description = bounded(session_work.max_description_bytes, "Build"), .running = 1, .approvals = 0 } }, .{ .label = "Other Bash" }), .spins = false },
            .{ .listed = session("f00005", .{ .retrying = .{ .since = test_now_s - 6, .due_at_ms = (test_now_s + 60) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .{ .label = "Retry", .yours = true }), .spins = false },
            .{ .listed = session("f00006", .{ .stopping = ago(7) }, .{ .label = "Stopping", .yours = true }), .spins = false },
            .{ .listed = session("f00007", .{ .idle = ago(8) }, .{ .label = "Idle", .yours = true }), .spins = false },
            .{ .listed = session("f00008", .{ .finished = ago(9) }, .{ .label = "Finished", .yours = true }), .spins = false },
            .{ .listed = session("f00009", .{ .failed = .{ .since = test_now_s - 10, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Failed", .yours = true }), .spins = false },
            .{ .listed = session("f00010", .{ .stopped = .{ .since = test_now_s - 11, .cause = .stop } }, .{ .label = "Stopped", .yours = true }), .spins = false },
            .{ .listed = session("f00011", .{ .pending = ago(12) }, .{ .label = "Pending", .yours = true }), .spins = false },
        };
    }

    fn selectionRef(selected: Selection) ?Reference {
        return switch (selected) {
            .session => |ref| ref,
            .new_session, .sessions, .archived, .settings => null,
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
        const pins: usize = switch (shape) {
            .empty, .unpinned => 0,
            .pinned => total,
            .both => total / 2,
        };
        for (fixture[0..total], 0..) |*entry, index| {
            entry.listed.archive_state = archive;
            entry.listed.pin_order = if (index < pins) @intCast(100 - index) else null;
        }
        if (pins > 1) {
            // Covers the first == null arm of ownership, independently of
            // from_person_at. Its pin keeps it visible with every conversation.
            fixture[1].listed.first = null;
            fixture[1].listed.from_person_at = null;
        }
        // Explicit base archive truth table; do not call Filter.includes.
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
        state.archive = filter;
        state.listing_archive = filter;
        _ = try step(&state, .{ .tick = test_now_s * 1000 });
        _ = try respond(&state, .full, testToken(1), input[0..total]);
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
                        try std.testing.expectEqual(entry.spins and !stale and caps.unicode and caps.depth != .none, row.spins);
                        try std.testing.expectEqual(entry.spins and !stale and caps.unicode and caps.depth != .none, Lines.spins(&state, index, caps));
                        const name = if (entry.listed.first == null) "New Session" else entry.listed.label.?;
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
                                .active => "No unarchived Sessions",
                                .archived => "No archived Sessions",
                                .all => "No Sessions",
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
    // The recorded domain includes the shared status marks and spinner frame.
    try std.testing.expectEqual(@as(u64, 0xcab0da6d038a025e), bytes_and_styles);
}
