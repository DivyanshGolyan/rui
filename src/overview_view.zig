//! Session overview: every decision behind bare `rui`, over values.
//!
//! `step` applies one event (a key, a tick, a list page, a first line, a
//! stop or start result) to the overview's `State` and returns the effects
//! its shell runs: list again, read first lines, start, open, stop or exit.
//! `render` turns the state into the screen as styled lines. Neither reads a
//! clock or the Host: time arrives as a tick at `State.wakeAt`, the
//! animation frame as an argument, and the shell branches only on which
//! effect to run. What each
//! work state looks like lives in `rules`, what each key does in `keys`.
//! The rows are a client view over `session list`; the Host keeps no
//! overview state.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const attention = @import("attention.zig");
const change_ring = @import("change_ring.zig");
const cli_args = @import("cli_args.zig");
const codex_credential_policy = @import("codex_credential_policy.zig");
const draft_layout = @import("draft_layout.zig");
const failure_class = @import("failure_class.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const session_work = @import("session_work.zig");
const work_line = @import("work_line.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

const Allocator = std.mem.Allocator;
pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;
pub const Token = change_ring.Token;
/// A Session reference: six characters of the Session alphabet.
pub const Reference = change_ring.Id;

/// A Label obeys the saved Bash description rule.
pub const max_label_bytes = session_work.max_description_bytes;
/// Rows on one `session list` page.
pub const max_page_rows = 8;
/// First lines one refresh asks for.
pub const max_first_line_reads = 8;
/// Bytes of a first line kept for its title; a longer line ends in an ellipsis.
pub const max_line_bytes = session_line.max_line_bytes;
/// The shell reads this much of a first line: one byte more than a row keeps,
/// so a longer line shows that it was cut.
pub const max_line_read_bytes = max_line_bytes + 1;
/// Rows a folded group shows before its "more" line.
pub const fold_rows = 5;
/// Starts and stops the ledger holds at once.
pub const max_requests = 8;
/// The least time between two list requests.
pub const list_interval_ms = 1000;
/// How long each frame of a mark's pulse shows.
pub const pulse_interval_ms = 140;
/// A row's mark pulses until this long after the second it changed.
/// The overview hears of a change up to a listing later, so a pulse shows
/// for about two seconds.
pub const pulse_window_ms = 3000;
/// A generated request handle, as `rui request recover` takes it.
pub const max_handle_bytes = 36;

pub const Group = enum { yours, working, idle, finished, ended };
pub const Mark = enum { active, waiting, finished, failed, stopped };
/// Text roles. Each skin's `palettes` entry gives each its colour; without
/// colour every role draws in the terminal's own.
pub const Colour = enum {
    /// The brightest ink: the wordmark, your Sessions, the headline's opening.
    strong,
    /// What works or matters: named Sessions, headings.
    ink,
    normal,
    quiet,
    /// A finished mark.
    mark,
    rule,
    attention,
    failure,
    /// Text on the band.
    on_band,
};
/// Cell grounds. The overview paints `ground` under every cell it owns.
pub const Background = enum { ground, bar, selection, band };

/// How one work state looks and what Ctrl-X may do to it. Work under way
/// says what `work_line` says, in its tone; `word` names an idle or ended
/// state, which has no work line.
pub const Rule = struct {
    group: Group,
    mark: Mark,
    /// The mark's colour, unless the work line's tone asks for attention
    /// or quiet.
    colour: Colour,
    word: ?[]const u8 = null,
    /// The group heading already says `word`, so rows under it omit it.
    said_by_group: bool = false,
    /// A failed or stopped row names the Session that sent its first
    /// Message, by Label, else reference.
    starter: bool = false,
    /// Ctrl-X may stop a Session in this state.
    stoppable: bool,
};

/// The one per-kind table. `step` and `render` read it and switch on no kind.
pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .group = .idle, .mark = .waiting, .colour = .normal, .word = "idle", .said_by_group = true, .stoppable = false },
    .pending = .{ .group = .working, .mark = .waiting, .colour = .normal, .stoppable = true },
    .working = .{ .group = .working, .mark = .active, .colour = .ink, .stoppable = true },
    .retrying = .{ .group = .working, .mark = .active, .colour = .ink, .stoppable = true },
    .bash = .{ .group = .working, .mark = .active, .colour = .ink, .stoppable = true },
    .approval = .{ .group = .working, .mark = .waiting, .colour = .normal, .stoppable = true },
    .stopping = .{ .group = .working, .mark = .active, .colour = .ink, .stoppable = false },
    .finished = .{ .group = .finished, .mark = .finished, .colour = .mark, .word = "finished", .said_by_group = true, .stoppable = false },
    .failed = .{ .group = .ended, .mark = .failed, .colour = .failure, .word = "failed", .starter = true, .stoppable = false },
    .stopped = .{ .group = .ended, .mark = .stopped, .colour = .normal, .word = "stopped", .starter = true, .stoppable = false },
});

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8 }).init(.{
    .active = .{ .unicode = "●", .ascii = "*" },
    .waiting = .{ .unicode = "○", .ascii = "o" },
    .finished = .{ .unicode = "✓", .ascii = "+" },
    .failed = .{ .unicode = "×", .ascii = "x" },
    .stopped = .{ .unicode = "■", .ascii = "#" },
});

/// A pulsing mark steps through its steady mark and these, one per frame.
pub const pulse_dots = [_][]const u8{ "·", "∙", "•" };

pub const groups = std.enums.EnumArray(Group, struct { title: []const u8, help: []const u8 = "", folds: bool }).init(.{
    .yours = .{ .title = "Yours", .folds = false },
    .working = .{ .title = "Working", .folds = false },
    .idle = .{ .title = "Idle", .folds = false },
    .finished = .{ .title = "Finished", .folds = true },
    .ended = .{ .title = "Stopped or failed", .folds = true },
});

/// What a key does in the overview. `clear` empties the draft, else the
/// held start settings.
pub const Action = enum { previous, next, first, last, clear, exit, stop };

/// The one key table.
pub const keys: keymap.Keymap(Action) = .init(.{
    .escape = .clear,
    .ctrl_g = .clear,
    .ctrl_c = .exit,
    .ctrl_d = .exit,
    .ctrl_o = null,
    .ctrl_r = null,
    .ctrl_x = .stop,
    .up = .previous,
    .down = .next,
    .shift_up = .previous,
    .shift_down = .next,
    .page_up = null,
    .page_down = null,
    .home = .first,
    .end = .last,
    .ctrl_end = null,
});

/// The composer's text and caret, as the shell's line editor holds them,
/// and the draft line the previous frame showed first.
/// `anchor` is the byte that started the composer's first shown line last
/// frame.
pub const Draft = struct { bytes: []const u8 = "", cursor: usize = 0, anchor: usize = 0 };

/// What the composer made of one input, and its draft as that input left it.
pub const Composed = struct { outcome: keymap.Outcome(Action), draft: Draft };

pub const Delta = enum {
    not_modified,
    changed,
    full,

    /// The same answer from a decoded list page's `protocol.ListDelta`.
    pub fn of(delta: anytype) Delta {
        return switch (delta) {
            .not_modified => .not_modified,
            .changed => .changed,
            .full => .full,
        };
    }
};

pub const First = struct {
    /// The first Message's activity position and admission; neither changes.
    position: u64,
    admission: u64,
    /// The Session that sent it; null for a person or a script.
    sender: ?Reference,
};

/// One list row as the shell decoded it. Slices borrow the page.
pub const Listed = struct {
    reference: Reference,
    workspace: []const u8,
    label: ?[]const u8 = null,
    state: WorkState,
    /// The earliest Action awaiting a decision.
    first_action: ?u64 = null,
    first: ?First = null,
    /// When the latest Message with no Session sender was admitted.
    from_person_at: ?u64 = null,

    /// From a decoded `*const protocol.SessionRow`, whose bytes it borrows.
    pub fn of(row: anytype) Listed {
        return .{
            .reference = referenceOf(row.reference.slice()),
            .workspace = row.workspace.slice(),
            .label = if (row.label) |*text| text.slice() else null,
            .state = row.work.state,
            .first_action = row.work.first_action,
            .first = if (row.first_message) |*message| .{
                .position = message.position,
                .admission = message.admission,
                .sender = if (message.sender) |*sender| referenceOf(sender.session.slice()) else null,
            } else null,
            .from_person_at = row.peers.from_person_at,
        };
    }

    fn referenceOf(bytes: []const u8) Reference {
        std.debug.assert(bytes.len == change_ring.id_bytes);
        return bytes[0..change_ring.id_bytes].*;
    }
};

/// What a whole listing answers, relative to the token it was asked with.
pub const Answer = struct { delta: Delta, since: Token };

/// One `session list` page, as the listing's traversal reads it.
pub const Page = struct {
    rows: []const Listed,
    /// The page starts the listing over: earlier pages' rows no longer belong to it.
    restarts: bool = false,
    /// Set on the listing's last page.
    answer: ?Answer,

    /// Takes `page`, a decoded `*const protocol_reply.SessionListPage` that
    /// `traversal`'s cursor returned, into that `*protocol_reply.SessionTraversal`.
    /// While `answer` is null, the traversal's cursor asks for the next page.
    /// Rows borrow the page through `buffer`.
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

/// A list request's answer: a page, or no answer from the Host.
pub const ListReply = union(enum) { page: Page, failed };

pub const FirstLine = struct {
    reference: Reference,
    admission: u64,
    /// The unverified first line, or null when the Host refused it.
    line: ?[]const u8,
    /// No answer came, as when the Host is down: the next listing asks again.
    unanswered: bool = false,
};

/// What host-info says of the serving Host.
pub const Host = struct {
    /// Unix seconds.
    started_at: u64,
    slots: u64,
    slots_in_use: u64,
};

pub const StopOutcome = union(enum) {
    stopped,
    /// The Host refused it, or it was never captured.
    failed: []const u8,
    /// It may have reached the Host. Its saved request handle recovers it.
    unconfirmed: []const u8,
};

pub const StopResult = struct {
    reference: Reference,
    outcome: StopOutcome,
};

pub const StartResult = union(enum) {
    started: struct { reference: Reference, handle: []const u8 },
    /// The Host refused it, or it was never captured: the text can be sent again.
    failed: []const u8,
    /// It may have reached the Host. Its saved request handle recovers it;
    /// another Enter would start a second Session.
    unconfirmed: []const u8,
};

pub const Event = union(enum) {
    composed: Composed,
    /// The shell's clock, in Unix milliseconds.
    tick: u64,
    list: ListReply,
    first_line: FirstLine,
    stop: StopResult,
    start: StartResult,
    /// The overview ended: later results are kept for `writeDeparture`.
    leave,
    /// Opens a Session named outside the overview, as `session resume` does.
    open: Reference,
    /// The Host's facts, read as a listing starts; null when it gave none.
    host: ?Host,
    /// The person pressed a key, at this Unix millisecond.
    looked: u64,
    /// A conversation opened on this Session, or null as it closes. The
    /// conversation notifies of its own Session's news.
    conversing: ?Reference,
};

pub const Read = struct { reference: Reference, position: u64, admission: u64 };
pub const Reads = struct {
    items: [max_first_line_reads]Read = undefined,
    len: usize = 0,

    pub fn slice(self: *const Reads) []const Read {
        return self.items[0..self.len];
    }
};

pub const Effect = union(enum) {
    /// List every Session again through a `protocol_reply.SessionTraversal`
    /// from the last completed listing's token.
    list: ?Token,
    read_first_lines: Reads,
    start: StartRequest,
    open: Reference,
    stop: Reference,
    /// Empty the line editor.
    clear_draft,
    /// Tell the person, if they look away, of the listing's news.
    notify: Alert,
    exit,
};

/// A listing's news: the most urgent Session that newly wants the person, by
/// the name its row shows, which borrows the state until the next `step`,
/// and how many others brought news with it.
pub const Alert = struct { name: []const u8, kind: attention.Kind, more: usize };

/// Each event brings at most two effects today; the shell runs them in order.
pub const Effects = struct {
    items: [2]Effect = undefined,
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

/// The options `session start` shares with the live /configure, in
/// /configure's order.
pub const start_options = blk: {
    const start = cli_args.Command.session_start.definition();
    var names: []const []const u8 = &.{};
    for (cli_args.live_configure.options) |option| {
        for (start.options) |other| if (std.mem.eql(u8, option.name, other.name)) {
            names = names ++ .{option.name};
        };
    }
    break :blk names[0..names.len].*;
};

/// `/configure` values held for the Session the composer's next Enter starts.
pub const StartSettings = struct {
    held: [start_options.len]?Range = @splat(null),
    bytes: [max_bytes]u8 = undefined,
    used: usize = 0,

    /// A Workspace, a model and a Label at their bounds, with the rest.
    pub const max_bytes = 5 * 1024;
    const Range = struct { start: usize, len: usize };

    pub fn get(self: *const StartSettings, option: usize) ?[]const u8 {
        const range = self.held[option] orelse return null;
        return self.bytes[range.start..][0..range.len];
    }

    pub fn empty(self: *const StartSettings) bool {
        for (self.held) |range| if (range != null) return false;
        return true;
    }

    /// The held values as `session start` arguments, `--name value` pairs.
    /// The slices borrow these settings.
    pub fn args(self: *const StartSettings, buffer: *[2 * start_options.len][]const u8) []const []const u8 {
        var count: usize = 0;
        inline for (start_options, 0..) |name, option| if (self.get(option)) |value| {
            buffer[count] = "--" ++ name;
            buffer[count + 1] = value;
            count += 2;
        };
        return buffer[0..count];
    }

    fn put(self: *StartSettings, option: usize, value: []const u8) error{NoSpaceLeft}!void {
        if (value.len > self.bytes.len - self.used) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.used..][0..value.len], value);
        self.held[option] = .{ .start = self.used, .len = value.len };
        self.used += value.len;
    }
};

/// A start Enter asked for. Its slices borrow the state and the event's
/// draft until the next `step`, as every slice the core hands out does; the
/// shell keeps an `own` copy.
pub const StartRequest = struct {
    settings: *const StartSettings,
    text: []const u8,

    pub fn own(self: StartRequest, gpa: Allocator) error{OutOfMemory}!OwnedStart {
        const bytes = try gpa.alloc(u8, self.text.len + self.settings.used);
        @memcpy(bytes[0..self.text.len], self.text);
        @memcpy(bytes[self.text.len..], self.settings.bytes[0..self.settings.used]);
        return .{ .bytes = bytes, .text_len = self.text.len, .held = self.settings.held };
    }
};

/// A start's text and held settings in one allocation sized to them. Its
/// owner reads it on any thread and frees it once the start is answered.
pub const OwnedStart = struct {
    bytes: []u8,
    text_len: usize,
    held: [start_options.len]?StartSettings.Range,

    pub fn text(self: *const OwnedStart) []const u8 {
        return self.bytes[0..self.text_len];
    }

    pub fn get(self: *const OwnedStart, option: usize) ?[]const u8 {
        const range = self.held[option] orelse return null;
        return self.bytes[self.text_len + range.start ..][0..range.len];
    }

    pub fn deinit(self: OwnedStart, gpa: Allocator) void {
        gpa.free(self.bytes);
    }
};

pub const Prompt = struct { stop: Reference };

/// A start or stop `step` asked the shell to send. Only its answer removes
/// it, and only while the overview shows that answer; one that may have
/// reached the Host keeps its recover handle until departure. Nothing is
/// evicted: a full ledger refuses new requests.
pub const Request = struct {
    kind: enum { start, stop },
    /// The Session a stop names, or the one an accepted start made.
    session: ?Reference = null,
    status: enum { pending, done, failed, unknown } = .pending,
    /// The failure code, or the handle of an unknown or accepted request.
    text: Bounded(@max(max_handle_bytes, session_work.max_code_bytes)) = .{},
};

pub const Notice = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    colour: Colour,

    pub fn text(self: *const Notice) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A first line, as far as the overview has read it. A read line is its
/// index in `State.lines`, which keeps rows small to copy.
pub const Line = union(enum) { unread, requested, unavailable, read: u32 };

/// What the overview keeps of one Session.
pub const Row = struct {
    reference: Reference,
    /// Index of its Workspace in `State.workspaces`.
    workspace: u32,
    label: ?Bounded(max_label_bytes),
    state: WorkState,
    /// The earliest Action awaiting a decision: which wait for approval the
    /// row shows.
    first_action: ?u64,
    /// The `since` of the state that brought the row's mark: the second the
    /// mark last changed. A state change under the same mark keeps it.
    mark_since: u64,
    first: ?First,
    from_person_at: ?u64,
    line: Line = .unread,

    pub fn group(self: *const Row) Group {
        return if (self.from_person_at != null) .yours else rules.get(self.state).group;
    }

    fn mark(self: *const Row) Mark {
        return rules.get(self.state).mark;
    }
};

/// The overview's one value: rows keyed by Session reference, the selection
/// as a reference, the composer and its held start settings, the open prompt
/// and the listing in progress. Rows regroup on every refresh, so nothing
/// here names a row by index across events.
pub const State = struct {
    gpa: Allocator,
    home: []const u8,
    /// The Workspace the composer starts Sessions in, as an index in `workspaces`.
    cwd: u32,
    now_ms: u64 = 0,
    /// The terminal's own last successful `rui auth login`, Unix seconds.
    login_at: ?u64 = null,

    rows: Vec(Row) = .{},
    /// Row indices by reference.
    by_reference: Vec(Keyed) = .{},
    /// Row indices in screen order: by group, newest state first.
    order: Vec(u32) = .{},
    /// Each group's run in `order`.
    runs: std.enums.EnumArray(Group, Run) = .initFill(.{}),
    /// What the top lines say of the rows, kept as they change so a frame
    /// reads it without walking every row.
    summary: Summary = .{},
    /// Folding groups the selection has opened.
    unfolded: std.enums.EnumSet(Group) = .{},
    /// Distinct Workspaces, owned, and their indices by `workspaceKey`.
    workspaces: Vec([]const u8) = .{},
    workspace_order: Vec(Keyed) = .{},
    /// First lines read, for rows whose `line` is `.read`: at most one per
    /// Session, since a Session's first Message never changes.
    lines: Vec(Bounded(max_line_bytes)) = .{},

    selected: ?Reference = null,
    prompt: ?Prompt = null,
    notice: ?Notice = null,
    settings: StartSettings = .{},
    /// Every start and stop without an answer the overview showed, oldest first.
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,
    /// The person left, so answers wait for `writeDeparture`.
    left: bool = false,
    /// The serving Host's facts, from the latest host-info read.
    host: ?Host = null,
    /// The person's last keypress, else the first tick, in Unix milliseconds.
    looked_ms: ?u64 = null,
    /// Host restarts seen since `looked_ms`: changes of `started_at`.
    restarts: u32 = 0,
    /// The last Host start host-info gave, kept while the Host gives none.
    started_at: ?u64 = null,

    /// The token of the last completed listing.
    token: ?Token = null,
    /// The Session an open conversation shows, whose news is its own.
    conversing: ?Reference = null,
    /// A list request is in flight.
    listing: bool = false,
    /// Rows the listing in progress has read.
    pending: Vec(Row) = .{},
    next_list_ms: u64 = 0,
    listed_at_ms: ?u64 = null,
    /// The Host has not answered a list request since this time.
    unreachable_since_ms: ?u64 = null,
    /// Sort scratch reused across refreshes.
    sort_keys: Vec(SortKey) = .{},

    pub const Options = struct {
        cwd: []const u8,
        home: []const u8,
        login_at: ?u64 = null,
    };

    /// The caller owns `home` for the state's lifetime.
    pub fn init(self: *State, gpa: Allocator, options: Options) error{OutOfMemory}!void {
        self.* = .{ .gpa = gpa, .home = options.home, .cwd = 0, .login_at = options.login_at };
        errdefer self.deinit();
        self.cwd = try self.intern(options.cwd);
    }

    pub fn deinit(self: *State) void {
        for (self.workspaces.items) |bytes| self.gpa.free(bytes);
        inline for (.{ &self.rows, &self.by_reference, &self.order, &self.workspaces, &self.workspace_order, &self.lines, &self.pending, &self.sort_keys }) |vec| vec.deinit(self.gpa);
    }

    /// The row of `reference`, if listed.
    pub fn find(self: *const State, ref: Reference) ?*const Row {
        const at = lookup(self.by_reference.items, ref) orelse return null;
        return &self.rows.items[at];
    }

    /// The first line read for `row`, if any. It borrows the state until the
    /// next `step`.
    pub fn lineOf(self: *const State, row: *const Row) ?[]const u8 {
        return if (row.line == .read) self.lines.items[row.line.read].slice() else null;
    }

    /// When the overview next needs a `tick`, in Unix milliseconds: the next
    /// listing, a retry falling due, a mark's pulse ending, or the shown
    /// quota reset passing. Null while nothing falls due before the listing
    /// in flight answers. A time already past means at once. The shell keeps
    /// no timer of its own.
    pub fn wakeAt(self: *const State) ?u64 {
        var at: ?u64 = if (self.listing) null else self.next_list_ms;
        for (self.rows.items) |*row| {
            if (row.state == .retrying) at = @min(at orelse row.state.retrying.due_at_ms, row.state.retrying.due_at_ms);
            const ends = pulseEnd(row);
            if (ends > self.now_ms) at = @min(at orelse ends, ends);
        }
        if (band(self.rows.items, self.now_ms, self.login_at)) |trouble| if (trouble.resets_at) |resets| {
            at = @min(at orelse resets *| 1000, resets *| 1000);
        };
        return at;
    }

    fn selectedRow(self: *const State) ?*const Row {
        return self.find(self.selected orelse return null);
    }

    /// A start is in flight. The composer is frozen until its answer, so
    /// a failed start leaves its text to retry.
    pub fn starting(self: *const State) bool {
        return self.pendingAt(.start, null) != null;
    }

    /// A stop of `ref` still in flight, or one that may have reached the
    /// Host. While one is open the row takes no other stop.
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

    /// Records a request `step` asks the shell to send; false when the
    /// ledger is full, and the overview says so.
    fn request(self: *State, kind: @FieldType(Request, "kind"), ref: ?Reference) bool {
        if (self.request_count == max_requests) {
            self.say(.attention, "! Busy; try again shortly.", .{});
            return false;
        }
        self.requests[self.request_count] = .{ .kind = kind, .session = ref };
        self.request_count += 1;
        return true;
    }

    /// The answer to the request at `at`. One shown on screen is gone; one
    /// that may have reached the Host, or that came after the person left,
    /// stays for `writeDeparture`.
    fn answer(self: *State, at: usize, status: @FieldType(Request, "status"), text: []const u8) void {
        if (status != .unknown and !self.left) {
            std.mem.copyForwards(Request, self.requests[at .. self.request_count - 1], self.requests[at + 1 .. self.request_count]);
            self.request_count -= 1;
            return;
        }
        const held = &self.requests[at];
        held.status = status;
        held.text.set(text) catch unreachable;
    }

    /// Interns a Workspace: Sessions share few, and a row keeps an index.
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

pub const Summary = struct {
    /// A row works: its state is in the working group, whatever its section.
    working: bool = false,
    approvals: usize = 0,
    failed: usize = 0,
    /// The newest state's time, Unix seconds.
    latest: u64 = 0,
    /// Every Session you messaged has finished.
    answered: bool = true,
    /// Rows that finished or failed since the person looked.
    finished_since: usize = 0,
    failed_since: usize = 0,

    /// Counts `row` if it finished or failed at or after `looked_s`. A
    /// state's time is in whole seconds: one in the second of the keypress
    /// counts, so nothing after it is missed.
    fn count(self: *Summary, row: *const Row, looked_s: u64) void {
        if (row.state.since() < looked_s) return;
        switch (row.state) {
            .finished => self.finished_since += 1,
            .failed => self.failed_since += 1,
            else => {},
        }
    }
};

const Run = struct { start: usize = 0, len: usize = 0 };
const Keyed = struct { key: u64, index: u32 };
const SortKey = struct { key: u128, index: u32 };

/// A growable array of the state's allocator. Cores name no `std` list.
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

/// FNV-1a: Workspaces share long prefixes, so comparing bytes is slower.
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

/// Applies one event and returns what the shell runs next.
pub fn step(state: *State, event: Event) error{OutOfMemory}!Effects {
    var effects: Effects = .{};
    switch (event) {
        .composed => |value| compose(state, value, &effects),
        .tick => |now_ms| try tick(state, now_ms, &effects),
        .list => |reply| switch (reply) {
            .page => |page| try listPage(state, page, &effects),
            .failed => {
                std.debug.assert(state.listing);
                state.listing = false;
                state.pending.items.len = 0;
                if (state.unreachable_since_ms == null) state.unreachable_since_ms = state.now_ms;
            },
        },
        .first_line => |result| try firstLine(state, result),
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
        .start => |result| {
            const at = state.pendingAt(.start, null).?;
            switch (result) {
                .started => |started| {
                    state.requests[at].session = started.reference;
                    state.answer(at, .done, started.handle);
                    if (state.left) return effects;
                    effects.add(.clear_draft);
                    state.settings = .{};
                    state.selected = started.reference;
                    state.next_list_ms = 0;
                    effects.add(.{ .open = started.reference });
                },
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "! Not started: {s}", .{code});
                },
                .unconfirmed => |handle| {
                    // The saved request holds the text; recovery, not a
                    // second Enter, finds out whether it started.
                    state.answer(at, .unknown, handle);
                    if (!state.left) effects.add(.clear_draft);
                    state.settings = .{};
                    state.next_list_ms = 0;
                    state.say(.attention, "! Start unsure; details on exit", .{});
                },
            }
        },
        .leave => state.left = true,
        .conversing => |reference| state.conversing = reference,
        .open => |ref| {
            state.selected = ref;
            effects.add(.{ .open = ref });
        },
        .host => |facts| {
            state.host = facts;
            if (facts) |host| {
                if (state.started_at) |seen| state.restarts += @intFromBool(host.started_at != seen);
                state.started_at = host.started_at;
            }
        },
        .looked => |at_ms| {
            state.looked_ms = at_ms;
            state.restarts = 0;
            // A later look can only lower the counts, so none stay none.
            if (state.summary.finished_since + state.summary.failed_since != 0) countSinceLooked(state);
        },
    }
    return effects;
}

/// What the shell prints once the terminal is restored: one line for each
/// request left in the ledger.
pub fn writeDeparture(state: *const State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (state.requests[0..state.request_count]) |*request| {
        const text = request.text.slice();
        switch (request.kind) {
            .start => switch (request.status) {
                .pending => try writer.writeAll("rui: The new Session did not start.\n"),
                .failed => try writer.print("rui: The new Session was not started ({s}); start it again from the overview.\n", .{text}),
                .unknown => try writer.print("rui: Not sure the new Session started. Check with: rui request recover {s}\n", .{text}),
                .done => try writer.print("rui: Started {s}.\n", .{&request.session.?}),
            },
            .stop => switch (request.status) {
                .pending => try writer.print("rui: {s} was not stopped.\n", .{&request.session.?}),
                .failed => try writer.print("rui: Could not stop {s}: {s}\n", .{ &request.session.?, text }),
                .unknown => try writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ &request.session.?, text }),
                .done => try writer.print("rui: Stopped {s}.\n", .{&request.session.?}),
            },
        }
    }
}

fn tick(state: *State, now_ms: u64, effects: *Effects) error{OutOfMemory}!void {
    state.now_ms = now_ms;
    if (state.looked_ms == null) state.looked_ms = now_ms;
    var changed = false;
    for (state.rows.items) |*row| {
        const next = row.state.asOf(now_ms);
        if (std.meta.activeTag(next) == std.meta.activeTag(row.state)) continue;
        changed = true;
        // A retry falling due changes the mark without a listing.
        const was = row.mark();
        row.state = next;
        if (row.mark() != was) row.mark_since = next.since();
    }
    if (changed) try arrange(state);
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.next_list_ms = now_ms + list_interval_ms;
        effects.add(.{ .list = state.token });
    }
}

fn listPage(state: *State, page: Page, effects: *Effects) error{OutOfMemory}!void {
    std.debug.assert(state.listing);
    if (page.restarts) state.pending.items.len = 0;
    try state.pending.ensure(state.gpa, state.pending.items.len + page.rows.len);
    for (page.rows) |listed| {
        const shown = listed.state.asOf(state.now_ms);
        // A row new to the overview takes its state's start as its mark's.
        state.pending.appendAssumeCapacity(.{
            .reference = listed.reference,
            .workspace = try state.intern(listed.workspace),
            .label = if (listed.label) |text| labelOf(text) else null,
            .state = shown,
            .first_action = listed.first_action,
            .mark_since = shown.since(),
            .first = listed.first,
            .from_person_at = listed.from_person_at,
        });
    }
    const answer = page.answer orelse return;
    // The first listing is what the overview opened on, not news.
    const alert = if (state.token != null) newsworthy(state) else null;
    try commit(state, answer);
    if (alert) |found| {
        const row = state.find(found.reference).?;
        effects.add(.{ .notify = .{ .name = title(state, row).text, .kind = found.kind, .more = found.more } });
    }
    state.listing = false;
    try readFirstLines(state, effects);
}

const Newsworthy = struct { reference: Reference, kind: attention.Kind, more: usize };

/// Each Session the pending listing shows newly wanting the person, against
/// the row the overview has for it, if any; the most urgent first, the
/// first listed among equals. An open conversation's Session is its own.
fn newsworthy(state: *const State) ?Newsworthy {
    var found: ?Newsworthy = null;
    for (state.pending.items) |*incoming| {
        if (state.conversing) |open| if (std.mem.eql(u8, &open, &incoming.reference)) continue;
        const before: ?attention.Seen = if (lookup(state.by_reference.items, incoming.reference)) |at| .{ .state = state.rows.items[at].state, .first_action = state.rows.items[at].first_action } else null;
        const kind = attention.news(before, .{ .state = incoming.state, .first_action = incoming.first_action }) orelse continue;
        if (found) |*held| {
            held.more += 1;
            if (@backingInt(kind) < @backingInt(held.kind)) {
                held.reference = incoming.reference;
                held.kind = kind;
            }
        } else found = .{ .reference = incoming.reference, .kind = kind, .more = 0 };
    }
    return found;
}

fn labelOf(text: []const u8) Bounded(max_label_bytes) {
    var value: Bounded(max_label_bytes) = .{};
    // The list decoder validated the Label; this bound is its own.
    value.set(text) catch unreachable;
    return value;
}

/// Applies a completed listing: `changed` replaces rows by reference, `full`
/// replaces the set, `not_modified` keeps every row.
fn commit(state: *State, answer: Answer) error{OutOfMemory}!void {
    switch (answer.delta) {
        .not_modified => {},
        .changed => {
            for (state.pending.items) |*incoming| {
                if (lookup(state.by_reference.items, incoming.reference)) |at| {
                    carry(incoming, &state.rows.items[at]);
                    state.rows.items[at] = incoming.*;
                } else try state.rows.append(state.gpa, incoming.*);
            }
            try reindex(state);
        },
        .full => {
            std.mem.swap(Vec(Row), &state.rows, &state.pending);
            try reindex(state);
            for (state.pending.items) |*old| if (lookup(state.by_reference.items, old.reference)) |at| carry(&state.rows.items[at], old);
        },
    }
    state.pending.items.len = 0;
    state.token = answer.since;
    state.listed_at_ms = state.now_ms;
    state.unreachable_since_ms = null;
    try arrange(state);
}

/// What a listing's row keeps of the row it replaces.
fn carry(incoming: *Row, old: *const Row) void {
    keepMark(incoming, old);
    // What the overview knows of the same first Message's first line, read,
    // unreadable or asked for, still holds.
    const same = if (incoming.first) |first| if (old.first) |known| first.admission == known.admission else false else false;
    if (same) incoming.line = old.line;
}

/// The same mark keeps the second it last changed, so a state change under
/// it does not pulse.
fn keepMark(incoming: *Row, old: *const Row) void {
    if (incoming.mark() == old.mark()) incoming.mark_since = old.mark_since;
}

/// Rebuilds `by_reference`. A reference listed twice keeps its later row.
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
    // Move the survivors down in row order, so no copy lands on a survivor
    // not yet moved, then key them again.
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

/// Rebuilds the screen order, each group's run and the summary, then keeps the
/// selection on a listed, visible row.
fn arrange(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.sort_keys.ensure(state.gpa, rows.len);
    try state.order.ensure(state.gpa, rows.len);
    state.sort_keys.items.len = rows.len;
    state.summary = .{};
    const latest = std.math.maxInt(u34);
    const looked_s = if (state.looked_ms) |at| at / 1000 else null;
    for (state.sort_keys.items, rows, 0..) |*key, *row, at| {
        const rule = rules.get(row.state);
        state.summary.failed += @intFromBool(row.state == .failed);
        state.summary.working = state.summary.working or rule.group == .working;
        state.summary.approvals += @intFromBool(row.state == .approval);
        state.summary.latest = @max(state.summary.latest, row.state.since());
        if (row.group() == .yours and row.state != .finished) state.summary.answered = false;
        if (looked_s) |since| state.summary.count(row, since);
        const age: u128 = latest - @min(row.state.since(), latest);
        key.* = .{ .key = @as(u128, @backingInt(row.group())) << 82 | age << 48 | referenceKey(row.reference), .index = @intCast(at) };
    }
    std.mem.sortUnstable(SortKey, state.sort_keys.items, {}, struct {
        fn less(_: void, a: SortKey, b: SortKey) bool {
            return a.key < b.key;
        }
    }.less);
    state.order.items.len = rows.len;
    state.runs = .initFill(.{});
    for (state.order.items, state.sort_keys.items, 0..) |*slot, key, at| {
        slot.* = key.index;
        const run = state.runs.getPtr(rows[key.index].group());
        if (run.len == 0) run.start = at;
        run.len += 1;
    }
    if (state.selectedRow()) |row| {
        if (!visible(state, position(state, row.reference).?)) state.unfolded.insert(row.group());
    } else if (state.selected == null and rows.len != 0) state.selected = rows[state.order.items[0]].reference;
}

fn countSinceLooked(state: *State) void {
    state.summary.finished_since = 0;
    state.summary.failed_since = 0;
    const looked_ms = state.looked_ms orelse return;
    for (state.rows.items) |*row| state.summary.count(row, looked_ms / 1000);
}

fn folded(state: *const State, group: Group) bool {
    return groups.get(group).folds and state.runs.get(group).len > fold_rows + 1 and !state.unfolded.contains(group);
}

fn visible(state: *const State, at: usize) bool {
    const group = state.rows.items[state.order.items[at]].group();
    return !folded(state, group) or at - state.runs.get(group).start < fold_rows;
}

fn position(state: *const State, ref: Reference) ?usize {
    for (state.order.items, 0..) |row, at| if (std.mem.eql(u8, &state.rows.items[row].reference, &ref)) return at;
    return null;
}

/// Asks for the first lines of up to eight unlabelled rows a person can see.
fn readFirstLines(state: *State, effects: *Effects) error{OutOfMemory}!void {
    var reads: Reads = .{};
    for (state.order.items, 0..) |at, rank| {
        if (reads.len == reads.items.len) break;
        const row = &state.rows.items[at];
        const first = row.first orelse continue;
        if (row.label != null or row.line != .unread or !visible(state, rank)) continue;
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
    try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(bytes)));
    row.line = .{ .read = @intCast(state.lines.items.len - 1) };
}

/// Any input clears the notice and cancels a stop prompt. Ctrl-X confirms
/// the prompt and Esc only cancels it.
fn compose(state: *State, value: Composed, effects: *Effects) void {
    state.notice = null;
    const prompt = state.prompt;
    state.prompt = null;
    switch (value.outcome) {
        .action => |pressed| switch (pressed) {
            .previous, .next, .first, .last => move(state, pressed),
            .clear => if (prompt != null) {} else if (value.draft.bytes.len != 0) effects.add(.clear_draft) else {
                state.settings = .{};
            },
            .exit => effects.add(.exit),
            .stop => if (prompt) |asked| confirmStop(state, asked.stop, effects) else {
                const row = state.selectedRow() orelse return state.say(.quiet, "Select a Session first.", .{});
                if (rules.get(shownKind(state, row)).stoppable) {
                    state.prompt = .{ .stop = row.reference };
                } else refuseStop(state, row);
            },
        },
        .none, .append, .redraw => {},
        .submit => enter(state, value.draft.bytes, effects),
        .refused => |why| {
            if (why.endsLine()) effects.add(.clear_draft);
            switch (why) {
                .invalid => state.say(.attention, "! Not valid text; nothing sent.", .{}),
                .overflow => state.say(.attention, "! Too long to send.", .{}),
                .edit_rejected => state.say(.attention, "! Can't add that character alone.", .{}),
                .unbound => state.say(.attention, "! That key does nothing here.", .{}),
            }
        },
    }
}

fn confirmStop(state: *State, ref: Reference, effects: *Effects) void {
    const row = state.find(ref) orelse return;
    if (!rules.get(shownKind(state, row)).stoppable) return refuseStop(state, row);
    if (state.request(.stop, ref)) effects.add(.{ .stop = ref });
}

/// Says why `row` takes no stop. An unconfirmed one says leaving gives the
/// details; work being stopped says so in its row's words.
fn refuseStop(state: *State, row: *const Row) void {
    if (state.openStop(row.reference)) |held| if (held.status == .unknown)
        return state.say(.attention, "! {s} stop unsure; details on exit", .{&row.reference});
    if (rules.get(shownKind(state, row)).word) |word_| return state.say(.quiet, "{s} is already {s}.", .{ &row.reference, word_ });
    var words: [work_line.max_words_bytes]u8 = undefined;
    state.say(.quiet, "{s}: {s}", .{ &row.reference, workLine(&words, state, row).?.words });
}

/// The kind a row shows: `stopping` while a stop of it is open, and a retry
/// that has fallen due as the work it became.
fn shownKind(state: *const State, row: *const Row) Kind {
    return if (state.openStop(row.reference) != null) .stopping else row.state.asOf(state.now_ms);
}

/// What a row's work is doing now, as `shownKind` reads it; null for idle or
/// ended work.
fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    return if (state.openStop(row.reference) != null) work_line.stopping else work_line.of(words, &row.state, null, state.now_ms);
}

fn enter(state: *State, text: []const u8, effects: *Effects) void {
    // As in a conversation, the draft is sent byte for byte; only a blank
    // draft opens the selected row instead.
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        if (text.len != 0) effects.add(.clear_draft);
        const row = state.selectedRow() orelse return;
        return effects.add(.{ .open = row.reference });
    }
    // As in a conversation, `//` starts text with one slash.
    if (text[0] != '/' or std.mem.startsWith(u8, text, "//")) {
        if (!state.request(.start, null)) return;
        return effects.add(.{ .start = .{ .settings = &state.settings, .text = if (text[0] == '/') text[1..] else text } });
    }
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    if (std.mem.eql(u8, name, "/exit")) return effects.add(.exit);
    if (!std.mem.eql(u8, name, "/configure")) return state.say(.attention, "! Unknown; try /configure or /exit", .{});
    if (configure(state, text[name.len..])) effects.add(.clear_draft);
}

const configure_usage = blk: {
    var text: []const u8 = "! /configure takes start settings:";
    for (start_options, 0..) |name, at| text = text ++ (if (at == 0) " --" else ", --") ++ name;
    break :blk text;
};

/// Holds `/configure` start settings, the live /configure grammar limited to
/// the options of `session start`. Later values replace earlier ones.
fn configure(state: *State, arguments: []const u8) bool {
    var buffer: [StartSettings.max_bytes + 512]u8 = undefined;
    var tokens: [20][]const u8 = undefined;
    const count = split(arguments, &buffer, &tokens) catch {
        state.say(.attention, configure_usage, .{});
        return false;
    };
    var nothing = std.heap.FixedBufferAllocator.init(&.{});
    const parsed = cli_args.live_configure.parse(tokens[0..count], nothing.allocator()) catch {
        state.say(.attention, configure_usage, .{});
        return false;
    };
    if (parsed.help or parsed.seen == 0) {
        state.say(.attention, configure_usage, .{});
        return false;
    }
    for (cli_args.live_configure.options) |option| {
        if (parsed.has(option.name) and startOption(option.name) == null) {
            state.say(.attention, "! Set --{s} after the start", .{option.name});
            return false;
        }
    }
    // The Host admits any model name, so the client checks release support,
    // as `session start` does.
    if (parsed.get("model")) |model| if (!model_capability.supportsModel(model)) {
        state.say(.attention, "! Unsupported; session configure -h", .{});
        return false;
    };
    var next: StartSettings = .{};
    inline for (start_options, 0..) |name, option| {
        if (parsed.get(name) orelse state.settings.get(option)) |value| next.put(option, value) catch {
            state.say(.attention, "! Settings over {d} bytes", .{StartSettings.max_bytes});
            return false;
        };
    }
    state.settings = next;
    return true;
}

fn startOption(name: []const u8) ?usize {
    for (start_options, 0..) |option, at| if (std.mem.eql(u8, option, name)) return at;
    return null;
}

/// Splits command arguments as the conversation's /configure does: spaces
/// separate, double quotes group, and a backslash escapes a quote, a
/// backslash or a space. This is not shell expansion.
fn split(input: []const u8, buffer: []u8, tokens: [][]const u8) error{InvalidArguments}!usize {
    if (input.len > buffer.len) return error.InvalidArguments;
    var read: usize = 0;
    var write: usize = 0;
    var count: usize = 0;
    while (read < input.len) {
        while (read < input.len and input[read] == ' ') : (read += 1) {}
        if (read == input.len) break;
        if (count == tokens.len) return error.InvalidArguments;
        const start = write;
        var quoted = false;
        while (read < input.len) {
            const byte = input[read];
            if (!quoted and byte == ' ') break;
            if (byte == '"') {
                quoted = !quoted;
                read += 1;
                continue;
            }
            if (byte == '\\' and read + 1 < input.len and
                (input[read + 1] == '"' or input[read + 1] == '\\' or input[read + 1] == ' ')) read += 1;
            if (input[read] < 0x20 or input[read] == 0x7f) return error.InvalidArguments;
            buffer[write] = input[read];
            write += 1;
            read += 1;
        }
        if (quoted) return error.InvalidArguments;
        tokens[count] = buffer[start..write];
        count += 1;
    }
    return count;
}

/// Moves the selection through the rows a person can see, opening a folded
/// group when the selection walks into its hidden rows.
fn move(state: *State, action: Action) void {
    const order = state.order.items;
    if (order.len == 0) return;
    const current = if (state.selected) |ref| position(state, ref) else null;
    const target: usize = switch (action) {
        .first => 0,
        .last => lastVisible(state, order.len - 1),
        .next => if (current) |at| @min(at + 1, order.len - 1) else 0,
        .previous => if (current) |at| lastVisible(state, at -| 1) else 0,
        else => unreachable,
    };
    if (!visible(state, target)) state.unfolded.insert(state.rows.items[order[target]].group());
    state.selected = state.rows.items[order[target]].reference;
}

/// `at`, or the last row its folded group shows.
fn lastVisible(state: *const State, at: usize) usize {
    if (visible(state, at)) return at;
    return state.runs.get(state.rows.items[state.order.items[at]].group()).start + fold_rows - 1;
}

/// Sign-in, quota or rate-limit trouble that stops every Session reaching
/// the model, from rows alone: rows survive Host restarts, so no Host memory
/// is needed.
pub const Trouble = enum { sign_in, quota, rate_limit };
pub const Band = struct {
    trouble: Trouble,
    /// Rows retrying a rate limit.
    sessions: u32 = 0,
    /// When the provider said the quota resets, Unix seconds.
    resets_at: ?u64 = null,
};

const BandRule = struct {
    trouble: Trouble,
    /// `failed`: the newest failure with a matching code, when newer than
    /// the newest finished Turn. `retrying`: any row retrying for a
    /// matching cause.
    kind: Kind,
    matches: *const fn ([]const u8) bool,
    /// Hidden while not newer than this terminal's own login.
    after_login: bool = false,
    /// Hidden once its saved reset time passes.
    until_reset: bool = false,
};

/// In priority order.
const band_rules = [_]BandRule{
    .{ .trouble = .sign_in, .kind = .failed, .matches = signInCode, .after_login = true },
    .{ .trouble = .quota, .kind = .failed, .matches = quotaCode, .until_reset = true },
    .{ .trouble = .rate_limit, .kind = .retrying, .matches = failure_class.rateLimited },
};

fn signInCode(code: []const u8) bool {
    return failure_class.of(code) == .sign_in;
}

fn quotaCode(code: []const u8) bool {
    return switch (failure_class.of(code)) {
        .quota, .plan => true,
        else => false,
    };
}

pub fn band(rows: []const Row, now_ms: u64, login_at: ?u64) ?Band {
    var finished: u64 = 0;
    var newest: [band_rules.len]?WorkState.Failed = @splat(null);
    var retrying: [band_rules.len]u32 = @splat(0);
    for (rows) |*row| {
        const state = row.state.asOf(now_ms);
        switch (state) {
            .finished => |value| finished = @max(finished, value.since),
            .failed => |failed| for (band_rules, &newest) |rule, *held| {
                if (rule.kind == .failed and rule.matches(failed.code.slice()) and (held.* == null or held.*.?.since < failed.since)) held.* = failed;
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
        const failed = held orelse continue;
        if (failed.since <= finished) continue;
        if (rule.after_login) if (login_at) |at| if (failed.since <= at) continue;
        if (rule.until_reset) if (failed.resets_at) |at| if (at <= now_ms / 1000) continue;
        return .{ .trouble = rule.trouble, .resets_at = failed.resets_at };
    }
    return null;
}

pub const Rgb = [3]u8;

/// The Khadi skins. Day is an undyed cotton ground with indigo ink; night is
/// an indigo-dyed ground with cotton text. Both alarm in station-board
/// yellow with black and fail in madder.
pub const Skin = enum { day, night };

pub const Palette = struct {
    colours: std.enums.EnumArray(Colour, Rgb),
    backgrounds: std.enums.EnumArray(Background, Rgb),
};

fn hex(comptime text: *const [7]u8) Rgb {
    @setEvalBranchQuota(10_000);
    return .{
        std.fmt.parseInt(u8, text[1..3], 16) catch unreachable,
        std.fmt.parseInt(u8, text[3..5], 16) catch unreachable,
        std.fmt.parseInt(u8, text[5..7], 16) catch unreachable,
    };
}

/// One table per skin, from the Rui Khadi mock's `SKINS`. `render` reads
/// roles only; the frame looks each up here.
pub const palettes = std.enums.EnumArray(Skin, Palette).init(.{
    .day = .{
        .colours = .init(.{ .strong = hex("#121a44"), .ink = hex("#1d2a63"), .normal = hex("#3a4677"), .quiet = hex("#535c86"), .mark = hex("#7d84a6"), .rule = hex("#d8cfbb"), .attention = hex("#7a5200"), .failure = hex("#9e2328"), .on_band = hex("#141414") }),
        .backgrounds = .init(.{ .ground = hex("#f3eee2"), .bar = hex("#e7dfcc"), .selection = hex("#dcdcec"), .band = hex("#f2c200") }),
    },
    .night = .{
        .colours = .init(.{ .strong = hex("#f6f1e4"), .ink = hex("#e2dccb"), .normal = hex("#bdb8a9"), .quiet = hex("#9d9bb0"), .mark = hex("#6e7396"), .rule = hex("#2a3157"), .attention = hex("#f2c200"), .failure = hex("#ff8f7d"), .on_band = hex("#141414") }),
        .backgrounds = .init(.{ .ground = hex("#121833"), .bar = hex("#1a2142"), .selection = hex("#2b3568"), .band = hex("#f2c200") }),
    },
});

/// The 256-colour entry nearest `rgb`, from the 6x6x6 cube and the grey
/// ramp. Entries 0-15 are left out: each terminal themes its own.
pub fn nearestIndex(rgb: Rgb) u8 {
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var best: u8 = 16;
    var best_distance: u32 = std.math.maxInt(u32);
    for (16..256) |index| {
        const candidate: Rgb = if (index < 232) .{ levels[(index - 16) / 36], levels[(index - 16) / 6 % 6], levels[(index - 16) % 6] } else @splat(@intCast(8 + 10 * (index - 232)));
        var distance: u32 = 0;
        for (rgb, candidate) |want, have| {
            const delta = @as(i32, want) - have;
            distance += @intCast(delta * delta);
        }
        if (distance < best_distance) {
            best = @intCast(index);
            best_distance = distance;
        }
    }
    return best;
}

/// The same tables as 256-colour entries.
const indexed = blk: {
    @setEvalBranchQuota(400_000);
    var tables = std.enums.EnumArray(Skin, struct { colours: std.enums.EnumArray(Colour, u8), backgrounds: std.enums.EnumArray(Background, u8) }).initUndefined();
    for (std.enums.values(Skin)) |skin| {
        const palette = palettes.get(skin);
        var table = tables.getPtr(skin);
        for (std.enums.values(Colour)) |role| table.colours.set(role, nearestIndex(palette.colours.get(role)));
        for (std.enums.values(Background)) |role| table.backgrounds.set(role, nearestIndex(palette.backgrounds.get(role)));
    }
    break :blk tables;
};

pub const Caps = struct {
    /// Unicode marks and text; false draws ASCII only, a cell a character.
    unicode: bool = true,
    /// How the terminal measures Unicode text, from its report.
    width: gwidth.Method = .wcwidth,
    /// How many colours the terminal draws.
    depth: Depth = .direct,
    /// The terminal's background as it answered OSC 11; null without an
    /// answer.
    background: ?Rgb = null,

    /// `none` under NO_COLOR draws in the terminal's own colours with bold
    /// and reverse only; `indexed` uses the nearest 256-colour entries;
    /// `direct` uses 24-bit colour.
    pub const Depth = enum { none, indexed, direct };

    pub const Environment = struct {
        lc_all: ?[]const u8 = null,
        lc_ctype: ?[]const u8 = null,
        lang: ?[]const u8 = null,
        no_color: ?[]const u8 = null,
        colorterm: ?[]const u8 = null,
    };

    /// The locale that sets the character set is the first of LC_ALL,
    /// LC_CTYPE and LANG that is set; one that does not name UTF-8 draws
    /// ASCII. With none set, Unicode. A non-empty NO_COLOR turns colour off;
    /// otherwise COLORTERM `truecolor` or `24bit` gives 24-bit colour.
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

    /// Day on a light terminal background, night on a dark one or when the
    /// terminal did not say.
    pub fn skin(self: Caps) Skin {
        const rgb = self.background orelse return .night;
        // Relative luminance with the BT.709 weights, against half scale.
        const luminance = 2126 * @as(u32, rgb[0]) + 7152 * @as(u32, rgb[1]) + 722 * @as(u32, rgb[2]);
        return if (luminance >= 10000 * 128) .day else .night;
    }
};

pub const Style = struct {
    colour: Colour = .normal,
    background: Background = .ground,
    bold: bool = false,
    reverse: bool = false,
};

pub const Span = struct {
    column: u16,
    /// Display cells `text` takes.
    cells: u16,
    text: []const u8,
    style: Style,
};

/// The screen as lines of styled spans, top to bottom, each span at its
/// column. Every byte lives in the screen's arena.
pub const Screen = struct {
    arena: std.heap.ArenaAllocator,
    width: u16,
    lines: []const []const Span,
    /// Where the terminal's cursor shows: the composer's caret, unless the
    /// composer is locked.
    cursor: ?Cursor = null,
    /// The byte the composer's first shown line starts at, for the next
    /// frame's `Draft.anchor`.
    draft_anchor: usize = 0,
    /// A mark it drew changes with the frame: the shell draws the next one
    /// in `pulse_interval_ms`.
    pulses: bool = false,
    depth: Caps.Depth = .none,
    skin: Skin = .night,

    pub const Cursor = struct { row: u16, column: u16 };

    pub fn deinit(self: *Screen) void {
        self.arena.deinit();
    }

    /// The text alone, one line per row with trailing blanks trimmed.
    pub fn write(self: *const Screen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.lines) |spans| {
            var end = spans.len;
            while (end > 0 and std.mem.trimEnd(u8, spans[end - 1].text, " ").len == 0) end -= 1;
            var column: usize = 0;
            for (spans[0..end], 1..) |span, count| {
                if (span.column > column) try writer.splatByteAll(' ', span.column - column);
                try writer.writeAll(if (count == end) std.mem.trimEnd(u8, span.text, " ") else span.text);
                column = @max(column, span.column) + span.cells;
            }
            try writer.writeByte('\n');
        }
    }

    /// The terminal bytes that turn `shown`, the screen the terminal holds,
    /// into this one: one synchronized update, then the cursor at the caret
    /// or hidden. Without `shown`, or at another size, depth or skin, every
    /// line is cleared and drawn. Otherwise a line laid out as before writes
    /// only the spans that changed, and any other changed line is cleared
    /// and drawn. An unchanged screen writes nothing. With colour each
    /// cleared line takes the skin's ground and the frame ends in a reset,
    /// so the terminal's own colours hold between frames and whatever draws
    /// next starts from them.
    pub fn writeFrame(self: *const Screen, shown: ?*const Screen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const before = if (shown) |held| if (held.width == self.width and held.lines.len == self.lines.len and held.depth == self.depth and held.skin == self.skin) held else null else null;
        if (before) |held| if (self.sameAs(held)) return;
        try writer.writeAll("\x1b[?2026h\x1b[?25l");
        for (self.lines, 1..) |spans, row| {
            // With colour the pen carries, so a span in the last one's
            // style writes no SGR.
            var pen: ?Style = null;
            const old = if (before) |held| held.lines[row - 1] else null;
            if (old) |was| if (sameSpans(spans, was, .layout)) {
                for (spans, was) |span, prior| if (!sameSpan(span, prior, .all)) try self.writeSpan(writer, row, span, &pen);
                continue;
            };
            try writer.print("\x1b[{d};1H", .{row});
            if (self.depth != .none) {
                try writer.writeAll("\x1b[0");
                try self.writeColour(writer, 48, .{ .background = .ground });
                try writer.writeByte('m');
            }
            try writer.writeAll("\x1b[2K");
            for (spans) |span| try self.writeSpan(writer, row, span, &pen);
        }
        if (self.depth != .none) try writer.writeAll("\x1b[0m");
        if (self.cursor) |at| try writer.print("\x1b[{d};{d}H\x1b[?25h", .{ at.row + 1, at.column + 1 });
        try writer.writeAll("\x1b[?2026l");
    }

    fn sameAs(self: *const Screen, other: *const Screen) bool {
        if (!std.meta.eql(self.cursor, other.cursor)) return false;
        for (self.lines, other.lines) |a, b| if (!sameSpans(a, b, .all)) return false;
        return true;
    }

    const Same = enum { layout, all };

    /// Spans in the same cells, and with `.all` the same style and text too.
    fn sameSpan(a: Span, b: Span, same: Same) bool {
        if (a.column != b.column or a.cells != b.cells) return false;
        return same == .layout or (std.meta.eql(a.style, b.style) and std.mem.eql(u8, a.text, b.text));
    }

    fn sameSpans(a: []const Span, b: []const Span, same: Same) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!sameSpan(x, y, same)) return false;
        return true;
    }

    /// Places `span` by its own column, so a terminal that measures a
    /// grapheme differently shifts only that span.
    fn writeSpan(self: *const Screen, writer: *std.Io.Writer, row: usize, span: Span, pen: *?Style) std.Io.Writer.Error!void {
        try writer.print("\x1b[{d};{d}H", .{ row, span.column + 1 });
        if (self.depth == .none or !std.meta.eql(pen.*, span.style)) {
            try writer.writeAll("\x1b[0");
            if (span.style.bold) try writer.writeAll(";1");
            if (span.style.reverse) try writer.writeAll(";7");
            try self.writeColour(writer, 38, .{ .colour = span.style.colour });
            try self.writeColour(writer, 48, .{ .background = span.style.background });
            try writer.writeByte('m');
        }
        try writer.writeAll(span.text);
        if (self.depth == .none) try writer.writeAll("\x1b[0m");
        pen.* = span.style;
    }

    fn writeColour(self: *const Screen, writer: *std.Io.Writer, comptime layer: u8, role: union(enum) { colour: Colour, background: Background }) std.Io.Writer.Error!void {
        switch (self.depth) {
            .none => {},
            .indexed => try writer.print(";{d};5;{d}", .{ layer, switch (role) {
                .colour => |colour| indexed.get(self.skin).colours.get(colour),
                .background => |background| indexed.get(self.skin).backgrounds.get(background),
            } }),
            .direct => {
                const rgb = switch (role) {
                    .colour => |colour| palettes.get(self.skin).colours.get(colour),
                    .background => |background| palettes.get(self.skin).backgrounds.get(background),
                };
                try writer.print(";{d};2;{d};{d};{d}", .{ layer, rgb[0], rgb[1], rgb[2] });
            },
        }
    }

    /// The style at `column` of line `row`, if a span covers it.
    pub fn styleAt(self: *const Screen, row: usize, column: usize) ?Style {
        for (self.lines[row]) |span| if (column >= span.column and column < span.column + span.cells) return span.style;
        return null;
    }
};

const Glyphs = struct { prompt: []const u8, dot: []const u8, rule: []const u8, ellipsis: []const u8, arrows: []const u8, up: []const u8, down: []const u8, newline: []const u8 };
const unicode_glyphs: Glyphs = .{ .prompt = "›", .dot = work_line.glyphs.get(.unicode).dot, .rule = "─", .ellipsis = work_line.glyphs.get(.unicode).ellipsis, .arrows = "↑↓", .up = "↑", .down = "↓", .newline = "↵" };
const ascii_glyphs: Glyphs = .{ .prompt = ">", .dot = work_line.glyphs.get(.ascii).dot, .rule = "-", .ellipsis = work_line.glyphs.get(.ascii).ellipsis, .arrows = "^v", .up = "^", .down = "v", .newline = "|" };

/// Draws the overview. `frame` picks each pulsing mark's glyph.
pub fn render(gpa: Allocator, state: *const State, draft: Draft, width: u16, height: u16, caps: Caps, frame: u64) error{OutOfMemory}!Screen {
    var screen: Screen = .{ .arena = .init(gpa), .width = width, .lines = &.{}, .depth = caps.depth, .skin = caps.skin() };
    errdefer screen.deinit();
    var painter: Painter = .{ .arena = screen.arena.allocator(), .caps = caps, .glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs, .width = width, .frame = frame };
    const lines = try painter.arena.alloc([]const Span, height);
    @memset(lines, &.{});
    screen.lines = lines;
    if (height == 0 or width == 0) return screen;
    // The top: title, the alarm bands or else the headline, the Host's
    // health, what changed since the person looked, a gap.
    // At most: title, two bands, health, since.
    var top: [5][]const Span = undefined;
    var count: usize = 0;
    top[count] = try header(&painter, state);
    count += 1;
    var buffer: [16]u8 = undefined;
    if (state.unreachable_since_ms) |since| {
        top[count] = try bandLine(&painter, try std.fmt.allocPrint(painter.arena, "Host stopped {s} ago. Run rui host start.", .{spanText(&buffer, (state.now_ms -| since) / 1000)}));
        count += 1;
    }
    if (band(state.rows.items, state.now_ms, state.login_at)) |trouble| {
        top[count] = try providerBand(&painter, trouble, state.now_ms);
        count += 1;
    }
    // Without a band, the headline.
    if (count == 1) {
        top[count] = try headline(&painter, state);
        count += 1;
    }
    // The health line keeps its row before the first host-info read, so
    // the list does not move when it comes.
    top[count] = try healthLine(&painter, state);
    count += 1;
    if (sinceLooked(state)) |news| {
        top[count] = try sinceLine(&painter, news);
        count += 1;
    }
    const row = @min(count, height);
    @memcpy(lines[0..row], top[0..row]);
    // The bottom: the rule, the composer's rows and the hints, in the same
    // rows a conversation gives its input.
    var bottom = height;
    if (height >= 6 and width >= 6) {
        var layout: ComposerLayout = undefined;
        layout.plan(&painter, draft, height);
        bottom = height - 2 - layout.view.rows;
        lines[bottom] = try ruleLine(&painter, layout.view);
        try composer(&painter, state, draft, &layout, lines[bottom + 1 .. height - 1]);
        lines[height - 1] = try hints(&painter, state, draft);
        screen.draft_anchor = layout.lines[0].start;
        if (!state.starting()) screen.cursor = .{ .row = @intCast(bottom + 1 + layout.shape.caret_line - layout.view.first), .column = @intCast(@min(width - 1, 3 + layout.shape.caret_column)) };
    }
    if (row + 1 < bottom) try list(&painter, state, lines[row + 1 .. bottom]);
    screen.pulses = painter.pulsed;
    return screen;
}

/// Builds one line's spans left to right, sanitizing and clipping text.
const Painter = struct {
    arena: Allocator,
    caps: Caps,
    glyphs: Glyphs,
    width: u16,
    frame: u64,
    /// It drew a mark that changes with `frame`.
    pulsed: bool = false,
    spans: [24]Span = undefined,
    count: usize = 0,
    column: usize = 0,
    /// The selection's ground across the line, inside its margins.
    selected: bool = false,

    /// The glyph set `work_line` draws this screen's clocks with.
    fn script(self: *const Painter) work_line.Script {
        return if (self.caps.unicode) .unicode else .ascii;
    }

    fn begin(self: *Painter, selected: bool) void {
        self.count = 0;
        self.column = 0;
        self.selected = selected;
    }

    fn finish(self: *Painter) error{OutOfMemory}![]const Span {
        if (self.selected) try self.pad(self.width -| self.inset(), .{});
        return self.arena.dupe(Span, self.spans[0..self.count]);
    }

    /// The selection's margin: one cell when painted, as in the mock; none
    /// without colour, where it is reverse video across the line.
    fn inset(self: *const Painter) usize {
        return @intFromBool(self.caps.depth != .none);
    }

    /// The style drawn. Without colour, only bold and reverse remain: the
    /// band and the selection reverse, and every other ground is the
    /// terminal's own.
    fn style(self: *const Painter, wanted: Style) Style {
        var result = wanted;
        if (self.selected) result.background = .selection;
        if (self.caps.depth == .none) return .{
            .bold = result.bold or result.background == .band,
            .reverse = result.background == .band or result.background == .selection,
        };
        return result;
    }

    /// Moves to `column`, filling the cells passed when they show a ground
    /// of their own.
    fn pad(self: *Painter, column: usize, wanted: Style) error{OutOfMemory}!void {
        const to = @min(column, self.width);
        if (to <= self.column) return;
        const drawn = self.style(wanted);
        if (self.selected and self.column == 0) self.column = self.inset();
        if (to > self.column and (drawn.reverse or drawn.background != .ground)) {
            const blank = try self.arena.alloc(u8, to - self.column);
            @memset(blank, ' ');
            self.push(blank, to - self.column, wanted);
        }
        self.column = to;
    }

    fn push(self: *Painter, bytes: []const u8, cells: usize, wanted: Style) void {
        if (self.count == self.spans.len or cells == 0) return;
        self.spans[self.count] = .{ .column = @intCast(self.column), .cells = @intCast(cells), .text = bytes, .style = self.style(wanted) };
        self.count += 1;
        self.column += cells;
    }

    /// Puts `bytes` at `column` within `limit` cells, ending in an ellipsis
    /// when cut. Returns the cells it took.
    fn put(self: *Painter, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        try self.pad(column, wanted);
        const room = @min(limit, self.width -| self.column);
        if (room == 0) return 0;
        const shown = try self.clean(bytes, room, .head);
        self.push(shown.bytes, shown.cells, wanted);
        return shown.cells;
    }

    /// Like `put`, keeping the end of `bytes` when it is cut.
    fn putTail(self: *Painter, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        try self.pad(column, wanted);
        const room = @min(limit, self.width -| self.column);
        if (room == 0) return 0;
        const shown = try self.clean(bytes, room, .tail);
        self.push(shown.bytes, shown.cells, wanted);
        return shown.cells;
    }

    /// Puts `bytes` so they end at `end`.
    fn putRight(self: *Painter, end: usize, bytes: []const u8, wanted: Style) error{OutOfMemory}!void {
        const cells = self.measure(bytes);
        if (cells > end or end - cells < self.column) return;
        _ = try self.put(end - cells, bytes, cells, wanted);
    }

    /// Terminal-safe text clipped to `room` cells, as `Pieces` shows it.
    fn clean(self: *Painter, bytes: []const u8, room: usize, keep: enum { head, tail }) error{OutOfMemory}!Piece {
        const total = self.measure(bytes);
        const ellipsis = self.glyphs.ellipsis;
        const budget = if (total <= room) total else room - 1;
        var out = try self.arena.alloc(u8, bytes.len * 3 + ellipsis.len);
        var used: usize = 0;
        var cells: usize = 0;
        if (keep == .tail and total > room) {
            @memcpy(out[0..ellipsis.len], ellipsis);
            used = ellipsis.len;
        }
        var skip = if (keep == .tail) total - budget else 0;
        var pieces: Pieces = .{ .bytes = bytes, .painter = self };
        while (pieces.next()) |piece| {
            if (skip > 0) {
                skip -|= piece.cells;
                continue;
            }
            if (cells + piece.cells > budget) break;
            @memcpy(out[used..][0..piece.bytes.len], piece.bytes);
            used += piece.bytes.len;
            cells += piece.cells;
        }
        if (keep == .head and total > room) {
            @memcpy(out[used..][0..ellipsis.len], ellipsis);
            used += ellipsis.len;
        }
        return .{ .bytes = out[0..used], .cells = cells + @intFromBool(total > room) };
    }

    fn measure(self: *const Painter, bytes: []const u8) usize {
        var total: usize = 0;
        var pieces: Pieces = .{ .bytes = bytes, .painter = self };
        while (pieces.next()) |piece| total += piece.cells;
        return total;
    }

    /// The glyph shown for a code point that cannot reach the terminal: a
    /// control character or an invalid byte, or without Unicode anything
    /// past ASCII.
    fn standIn(self: *const Painter, codepoint: u21) ?[]const u8 {
        if (codepoint == '\n') return self.glyphs.newline;
        // A tab shows as one space, as in a conversation.
        if (codepoint == '\t') return " ";
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) or codepoint == replacement) return "?";
        if (!self.caps.unicode and codepoint > 0x7e) return "?";
        return null;
    }
};

const Piece = struct { bytes: []const u8, cells: usize };

/// Text as the terminal draws it: whole grapheme clusters, measured as the
/// terminal measures them, with a one-cell stand-in for each code point
/// that cannot reach it.
const Pieces = struct {
    bytes: []const u8,
    painter: *const Painter,
    at: usize = 0,

    fn next(self: *Pieces) ?Piece {
        if (self.at == self.bytes.len) return null;
        const rest = self.bytes[self.at..];
        const first = decode(rest);
        if (self.painter.standIn(first.codepoint)) |glyph| {
            self.at += first.len;
            return .{ .bytes = glyph, .cells = 1 };
        }
        // Printable ASCII before ASCII or the end is a whole cluster of one
        // cell under every method; this keeps long ASCII text cheap.
        if (!self.painter.caps.unicode or (first.codepoint < 0x80 and (rest.len == 1 or rest[1] < 0x80))) {
            self.at += 1;
            return .{ .bytes = rest[0..1], .cells = 1 };
        }
        var clusters = unicode.graphemeIterator(rest);
        const cluster = clusters.next().?.len;
        var end = first.len;
        while (end < cluster) {
            const decoded = decode(rest[end..]);
            if (self.painter.standIn(decoded.codepoint) != null) break;
            end += decoded.len;
        }
        self.at += end;
        return .{ .bytes = rest[0..end], .cells = gwidth.gwidth(rest[0..end], self.painter.caps.width) };
    }
};

const replacement = 0xfffd;

/// One UTF-8 code point; an invalid byte decodes alone as U+FFFD.
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

/// A home-relative Workspace: `~` for the home directory itself.
fn shortPath(home: []const u8, path: []const u8) struct { prefix: []const u8, rest: []const u8 } {
    if (home.len > 1 and std.mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        if (rest.len == 0 or rest[0] == '/') return .{ .prefix = "~", .rest = rest };
    }
    return .{ .prefix = "", .rest = path };
}

fn header(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const bar: Style = .{ .colour = .strong, .background = .bar, .bold = true };
    var column: usize = 1;
    // रुई beside rui, as on a station board; ASCII has rui alone.
    if (painter.caps.unicode) column += try painter.put(column, "रुई", painter.width, bar) + 1;
    column += try painter.put(column, "rui", 3, bar) + 2;
    const path = shortPath(state.home, state.workspaces.items[state.cwd]);
    const joined = try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
    _ = try painter.putTail(column, joined, painter.width -| column -| 1, .{ .background = .bar });
    try painter.pad(painter.width, .{ .background = .bar });
    return painter.finish();
}

/// One sentence under the title: whether anything works, and what needs
/// the person.
fn headline(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    if (state.listed_at_ms == null) {
        _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, "Loading{s}", .{painter.glyphs.ellipsis}), painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    if (state.rows.items.len == 0) {
        _ = try painter.put(1, "No Sessions yet. Type a task below.", painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    var span: [16]u8 = undefined;
    var number: [32]u8 = undefined;
    const summary = state.summary;
    const failed = state.summary.failed;
    const yours = state.runs.get(.yours).len;
    const sessions = state.rows.items.len;
    // Failures are counted. Waits for approval are not named, but they
    // keep the sentence from claiming calm; they count as working.
    const opening = if (summary.working) "Running." else try std.fmt.allocPrint(painter.arena, "Quiet for {s}.", .{spanText(&span, (state.now_ms / 1000) -| summary.latest)});
    const rest = if (summary.working)
        try std.fmt.allocPrint(painter.arena, "{s} Session{s}.{s}", .{ grouped(&number, sessions), if (sessions == 1) "" else "s", if (failed != 0 or summary.approvals != 0) "" else " Nothing needs you." })
    else if (failed != 0)
        ""
    else if (yours == 1 and summary.answered)
        "Your conversation has answered."
    else if (yours != 0 and summary.answered)
        try std.fmt.allocPrint(painter.arena, "All {s} of your conversations have answered.", .{grouped(&number, yours)})
    else
        "Nothing is working or waiting.";
    var failures: [32]u8 = undefined;
    const tail = if (failed == 0) rest else try std.fmt.allocPrint(painter.arena, "{s}{s}{s} failed.", .{ rest, if (rest.len == 0) "" else " ", grouped(&failures, failed) });
    const used = try painter.put(1, opening, painter.width -| 2, .{ .colour = .strong, .bold = true });
    _ = try painter.put(2 + used, tail, painter.width -| used -| 3, .{});
    return painter.finish();
}

fn healthLine(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    var span: [16]u8 = undefined;
    var column: usize = 1;
    if (state.unreachable_since_ms != null) {
        const text = if (state.listed_at_ms) |at|
            try std.fmt.allocPrint(painter.arena, "Host not responding. Last update {s} ago.", .{spanText(&span, (state.now_ms -| at) / 1000)})
        else
            "Host not responding.";
        column += try painter.put(column, text, painter.width -| column -| 1, .{ .colour = .failure }) + 3;
    } else if (state.host) |host| {
        const text = try std.fmt.allocPrint(painter.arena, "Host up {s}", .{spanText(&span, (state.now_ms / 1000) -| host.started_at)});
        column += try painter.put(column, text, painter.width -| column -| 1, .{}) + 3;
    }
    if (state.host) |host| {
        const text = try std.fmt.allocPrint(painter.arena, "slots {d}/{d}", .{ host.slots_in_use, host.slots });
        _ = try painter.put(column, text, painter.width -| column -| 1, .{ .colour = if (host.slots_in_use >= host.slots) .ink else .normal });
    }
    return painter.finish();
}

/// What changed since the person last looked, kept until their next key.
pub const News = struct { seconds: u64, finished: usize, failed: usize, restarts: u32 };

/// News once a Session failed or the Host restarted since the person's last
/// keypress, else null: finishes alone are no news.
pub fn sinceLooked(state: *const State) ?News {
    const looked_ms = state.looked_ms orelse return null;
    const news: News = .{ .seconds = (state.now_ms -| looked_ms) / 1000, .finished = state.summary.finished_since, .failed = state.summary.failed_since, .restarts = state.restarts };
    return if (news.failed != 0 or news.restarts != 0) news else null;
}

fn sinceLine(painter: *Painter, news: News) error{OutOfMemory}![]const Span {
    painter.begin(false);
    var span: [16]u8 = undefined;
    var finished: [32]u8 = undefined;
    var failed: [32]u8 = undefined;
    const restarted = switch (news.restarts) {
        0 => "",
        1 => ", Host restarted",
        else => try std.fmt.allocPrint(painter.arena, ", Host restarted {d} times", .{news.restarts}),
    };
    const text = try std.fmt.allocPrint(painter.arena, "Since you looked {s} ago: {s} finished, {s} failed{s}.", .{ spanText(&span, news.seconds), grouped(&finished, news.finished), grouped(&failed, news.failed), restarted });
    _ = try painter.put(1, text, painter.width -| 2, .{ .colour = .ink });
    return painter.finish();
}

/// A full-width alarm line, dark on yellow.
fn bandLine(painter: *Painter, text: []const u8) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const style: Style = .{ .colour = .on_band, .background = .band, .bold = true };
    try painter.pad(1, style);
    _ = try painter.put(1, text, painter.width -| 2, style);
    try painter.pad(painter.width, style);
    return painter.finish();
}

fn providerBand(painter: *Painter, trouble: Band, now_ms: u64) error{OutOfMemory}![]const Span {
    var buffer: [8]u8 = undefined;
    return bandLine(painter, switch (trouble.trouble) {
        .sign_in => "Sign-in expired. Run rui auth login codex.",
        .quota => if (trouble.resets_at) |at|
            try std.fmt.allocPrint(painter.arena, "Quota used up. Resets in {s}.", .{ageText(&buffer, at -| now_ms / 1000)})
        else
            "Quota used up.",
        .rate_limit => try std.fmt.allocPrint(painter.arena, "Rate limited. {d} Session{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
    });
}

/// A duration on the top lines: 42s, 7m, 2h05m, 3d04h.
fn spanText(buffer: *[16]u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    if (seconds < 3600) return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60}) catch unreachable;
    if (seconds < 86400) return std.fmt.bufPrint(buffer, "{d}h{d:0>2}m", .{ seconds / 3600, seconds % 3600 / 60 }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}d{d:0>2}h", .{ @min(seconds / 86400, 99999), seconds % 86400 / 3600 }) catch unreachable;
}

/// `count` grouped the Indian way: 1,00,000 and 1,00,00,000.
pub fn grouped(buffer: *[32]u8, count: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{count}) catch unreachable;
    var used: usize = 0;
    // The last three digits stand together; pairs go before them.
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

/// The rule above the composer. It names the draft lines hidden above or
/// below the composer when there are any.
fn ruleLine(painter: *Painter, view: draft_layout.View) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const cells = painter.width -| 2;
    var buffer: [64]u8 = undefined;
    const label = draft_layout.label(&buffer, view, .{ .up = painter.glyphs.up, .down = painter.glyphs.down, .dot = painter.glyphs.dot });
    const label_cells = painter.measure(label);
    try painter.pad(1, .{});
    const left = draft_layout.labelColumn(label_cells, cells) orelse {
        try ruleRun(painter, cells);
        return painter.finish();
    };
    try ruleRun(painter, left);
    _ = try painter.put(1 + left, label, label_cells, .{ .colour = .quiet });
    try ruleRun(painter, cells - left - label_cells);
    return painter.finish();
}

fn ruleRun(painter: *Painter, cells: usize) error{OutOfMemory}!void {
    if (cells == 0) return;
    const text = try painter.arena.alloc(u8, cells * painter.glyphs.rule.len);
    for (0..cells) |at| @memcpy(text[at * painter.glyphs.rule.len ..][0..painter.glyphs.rule.len], painter.glyphs.rule);
    painter.push(text, cells, .{ .colour = .rule });
}

/// The composer's lines as `draft_layout` breaks them, at three cells in.
const ComposerLayout = struct {
    shape: draft_layout.Shape,
    view: draft_layout.View,
    lines: [draft_layout.max_rows]draft_layout.Line,

    fn plan(self: *ComposerLayout, painter: *const Painter, draft: Draft, height: u16) void {
        const width = painter.width - 4;
        const pieces: DraftPieces = .{ .pieces = .{ .bytes = draft.bytes, .painter = painter }, .width = width };
        self.shape = draft_layout.shape(pieces, width, draft.cursor, draft.anchor);
        self.view = draft_layout.fit(pieces, width, draft.cursor, self.shape, draft_layout.cap(height), &self.lines);
    }
};

/// The draft as the composer draws it, for `draft_layout`: a newline breaks
/// the line, and every other piece is what `Pieces` draws. A cluster wider
/// than the line counts as filling it, which `put` shortens it to.
const DraftPieces = struct {
    pieces: Pieces,
    width: u16,

    pub fn next(self: *DraftPieces) ?draft_layout.Piece {
        const before = self.pieces.at;
        if (before < self.pieces.bytes.len and self.pieces.bytes[before] == '\n') {
            self.pieces.at += 1;
            return .{ .len = 1, .cells = 0, .kind = .newline };
        }
        const piece = self.pieces.next() orelse return null;
        return .{ .len = self.pieces.at - before, .cells = @intCast(@min(piece.cells, self.width)), .kind = draft_layout.kindOf(piece.bytes) };
    }
};

/// The draft's shown lines, one per row of `rows`, the prompt on its first.
fn composer(painter: *Painter, state: *const State, draft: Draft, layout: *const ComposerLayout, rows: [][]const Span) error{OutOfMemory}!void {
    std.debug.assert(rows.len == layout.view.rows);
    const room = painter.width -| 4;
    if (draft.bytes.len == 0) {
        painter.begin(false);
        _ = try painter.put(1, painter.glyphs.prompt, 1, .{});
        _ = try painter.put(3, "Type a task to start a Session", room, .{ .colour = .quiet });
        rows[0] = try painter.finish();
        return;
    }
    const style: Style = .{ .colour = if (state.starting()) .quiet else .strong };
    for (layout.lines[0..rows.len], rows, 0..) |line, *out, index| {
        painter.begin(false);
        if (layout.view.first + index == 0) _ = try painter.put(1, painter.glyphs.prompt, 1, .{});
        _ = try painter.put(3, draft.bytes[line.start..line.end], room, style);
        out.* = try painter.finish();
    }
}

fn hints(painter: *Painter, state: *const State, draft: Draft) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const room = painter.width -| 2;
    const dot = painter.glyphs.dot;
    if (state.prompt) |prompt| {
        const text = try std.fmt.allocPrint(painter.arena, "Stop {s}? ctrl+x yes {s} esc no", .{ &prompt.stop, dot });
        _ = try painter.put(1, text, room, .{ .colour = .attention });
    } else if (state.notice) |*notice| {
        _ = try painter.put(1, notice.text(), room, .{ .colour = notice.colour });
    } else if (state.starting()) {
        _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, "Starting{s}", .{painter.glyphs.ellipsis}), room, .{ .colour = .quiet });
    } else if (!state.settings.empty()) {
        var text: std.Io.Writer.Allocating = .init(painter.arena);
        text.writer.writeAll("start settings:") catch return error.OutOfMemory;
        writeSettings(&state.settings, &text.writer) catch return error.OutOfMemory;
        // Long settings are cut so the way out stays on screen.
        const suffix = try std.fmt.allocPrint(painter.arena, " {s} esc clear", .{dot});
        const used = try painter.put(1, text.written(), room -| painter.measure(suffix), .{ .colour = .quiet });
        _ = try painter.put(1 + used, suffix, room -| used, .{ .colour = .quiet });
    } else if (draft.bytes.len != 0) {
        const text = try std.fmt.allocPrint(painter.arena, "enter start {s} esc clear", .{dot});
        _ = try painter.put(1, text, room, .{ .colour = .quiet });
    } else if (state.selectedRow()) |row| {
        const stop = if (rules.get(shownKind(state, row)).stoppable) try std.fmt.allocPrint(painter.arena, " {s} ctrl+x stop", .{dot}) else "";
        const text = try std.fmt.allocPrint(painter.arena, "{s} select {s} enter open{s}", .{ painter.glyphs.arrows, dot, stop });
        _ = try painter.put(1, text, room, .{ .colour = .quiet });
    }
    return painter.finish();
}

/// ` --name value` per held setting, quoting values the /configure grammar
/// would split.
pub fn writeSettings(settings: *const StartSettings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (start_options, 0..) |name, option| {
        const value = settings.get(option) orelse continue;
        try writer.print(" --{s} ", .{name});
        const plain = value.len != 0 and std.mem.indexOfAny(u8, value, " \"\\") == null;
        if (plain) {
            try writer.writeAll(value);
            continue;
        }
        try writer.writeByte('"');
        for (value) |byte| {
            if (byte == '"' or byte == '\\') try writer.writeByte('\\');
            try writer.writeByte(byte);
        }
        try writer.writeByte('"');
    }
}

/// The list region: group headings, rows and "more" lines, scrolled so the
/// selection shows.
fn list(painter: *Painter, state: *const State, lines: [][]const Span) error{OutOfMemory}!void {
    if (state.rows.items.len == 0) return;
    const layout = Layout.of(state);
    const selected_line = if (state.selected) |ref| if (position(state, ref)) |at| layout.lineOf(state, at) else null else null;
    const offset = if (selected_line) |line| (line + 1) -| lines.len else 0;
    const columns = Columns.of(painter.width);
    for (lines, offset..) |*line, number| {
        const item = layout.item(state, number) orelse break;
        line.* = switch (item) {
            .gap => &.{},
            .heading => |group| try heading(painter, group),
            .row => |at| try rowLine(painter, state, at, columns),
            .more => |more| try moreLine(painter, more),
        };
    }
}

const Item = union(enum) { gap, heading: Group, row: usize, more: usize };

/// Lines of the list, group by group: a gap before each group but the
/// first, its heading, its shown rows, then its "more" line when folded.
const Layout = struct {
    first_line: std.enums.EnumArray(Group, usize),
    shown: std.enums.EnumArray(Group, usize),

    fn of(state: *const State) Layout {
        var layout: Layout = .{ .first_line = .initFill(0), .shown = .initFill(0) };
        var line: usize = 0;
        for (std.enums.values(Group)) |group| {
            const run = state.runs.get(group);
            if (run.len == 0) continue;
            if (line != 0) line += 1;
            const shown = if (folded(state, group)) fold_rows else run.len;
            layout.first_line.set(group, line);
            layout.shown.set(group, shown);
            line += 1 + shown + @intFromBool(shown < run.len);
        }
        return layout;
    }

    fn lineOf(self: *const Layout, state: *const State, at: usize) usize {
        const group = state.rows.items[state.order.items[at]].group();
        return self.first_line.get(group) + 1 + (at - state.runs.get(group).start);
    }

    fn item(self: *const Layout, state: *const State, line: usize) ?Item {
        var previous_end: usize = 0;
        for (std.enums.values(Group)) |group| {
            const run = state.runs.get(group);
            if (run.len == 0) continue;
            const first = self.first_line.get(group);
            if (line < first) return if (line >= previous_end) .gap else null;
            const shown = self.shown.get(group);
            if (line == first) return .{ .heading = group };
            if (line <= first + shown) return .{ .row = run.start + (line - first - 1) };
            if (shown < run.len and line == first + shown + 1) return .{ .more = run.len - shown };
            previous_end = first + 1 + shown + @intFromBool(shown < run.len);
        }
        return null;
    }
};

fn heading(painter: *Painter, group: Group) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const info = groups.get(group);
    const column = 1 + try painter.put(1, info.title, painter.width -| 2, .{ .colour = .ink, .bold = true });
    if (info.help.len != 0) _ = try painter.put(column + 2, info.help, painter.width -| column -| 3, .{ .colour = .quiet });
    return painter.finish();
}

fn moreLine(painter: *Painter, hidden: usize) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const text = try std.fmt.allocPrint(painter.arena, "{d} more", .{hidden});
    _ = try painter.put(3, text, painter.width -| 4, .{ .colour = .quiet });
    return painter.finish();
}

/// Row columns, as the Khadi mock sets them: the mark at 2, the title at 4,
/// the word 26 cells from the right edge (50 on a screen of 100 or more),
/// the age ending at the edge. A row outside the working directory puts its
/// Workspace at the end of its title's room. A narrow screen drops the word.
const Columns = struct {
    word: usize,
    workspace: usize,
    end: usize,

    const title = 4;
    const age_cells = 4;

    /// A Workspace column narrower than this names nothing, so it is left out.
    const min_workspace = 8;
    /// The cells a title keeps when a long word takes from its room.
    const min_title = 16;

    fn of(width: usize) Columns {
        const end = width -| 1;
        const room = width -| 2;
        if (room < 40) return .{ .word = end, .workspace = 0, .end = end };
        const status = end - @as(usize, if (room >= 100) 50 else 26);
        // The Workspace never takes more cells than the title keeps: half
        // of what lies between them, after the two-cell gap.
        const workspace = @min(@as(usize, if (room >= 100) 32 else 12), (status -| 2 -| Columns.title -| 2) / 2);
        return .{ .word = status, .workspace = if (workspace < min_workspace) 0 else workspace, .end = end };
    }
};

fn rowLine(painter: *Painter, state: *const State, at: usize, columns: Columns) error{OutOfMemory}![]const Span {
    const row = &state.rows.items[state.order.items[at]];
    const selected = if (state.selected) |*ref| std.mem.eql(u8, ref, &row.reference) else false;
    painter.begin(selected);
    const kind = shownKind(state, row);
    const rule = rules.get(kind);
    var words: [work_line.max_words_bytes]u8 = undefined;
    const line = workLine(&words, state, row);
    const faded = state.unreachable_since_ms != null;
    const mark = marks.get(rule.mark);
    // A mark pulses while its change is fresh, from a phase its change
    // second sets, so marks that changed apart pulse apart. Only Unicode in
    // colour pulses, and a faded row's state is stale, so it holds still.
    const pulses = !faded and painter.caps.unicode and painter.caps.depth != .none and state.now_ms < pulseEnd(row);
    painter.pulsed = painter.pulsed or pulses;
    const phase = if (pulses) (painter.frame +% row.mark_since) % (pulse_dots.len + 1) else 0;
    const glyph = if (phase != 0) pulse_dots[phase - 1] else if (painter.caps.unicode) mark.unicode else mark.ascii;
    _ = try painter.put(2, glyph, 1, .{ .colour = if (faded) .quiet else if (line) |shown| toneColour(shown.tone, rule.colour) else rule.colour });

    // Yours in the brightest ink, then named work; unnamed and ended grey.
    const yours = row.group() == .yours;
    const ended = rule.group == .finished or rule.group == .ended;
    const named = title(state, row);
    const title_colour: Colour = if (faded) .quiet else if (yours) .strong else if (named.hint or ended) .quiet else .ink;
    // Only a row outside the working directory names its Workspace, at the
    // end of its title's room.
    const workspace: []const u8 = if (columns.workspace != 0 and row.workspace != state.cwd) workspace: {
        const path = shortPath(state.home, state.workspaces.items[row.workspace]);
        break :workspace try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
    } else "";
    // A word longer than its column, such as a retry's countdown, starts
    // early and takes from the title's room, down to `min_title` cells.
    var word_bytes: [max_word_bytes]u8 = undefined;
    const text = if (columns.word != columns.end) word(&word_bytes, state, row, rule, line, painter.script()) else "";
    const word_end = columns.end -| Columns.age_cells -| 1;
    const overflow = painter.measure(text) -| (word_end -| columns.word);
    const word_column = @max(columns.word -| overflow, @min(columns.word, Columns.title + Columns.min_title + 2));
    const workspace_cells = if (word_column < columns.word) 0 else @min(painter.measure(workspace), columns.workspace);
    const title_end = (word_column -| 2) -| (if (workspace_cells == 0) 0 else workspace_cells + 2);
    _ = try painter.put(Columns.title, named.text, title_end -| Columns.title, .{ .colour = title_colour, .bold = yours and !faded });
    _ = try painter.putTail(title_end + 2, workspace, workspace_cells, .{ .colour = if (faded) .quiet else .normal });

    if (columns.word != columns.end) {
        // Colour only for what needs the person, or quiet as the work asks.
        const settled: Colour = if (rule.colour == .failure) .failure else .normal;
        const tone = if (faded) .quiet else if (line) |shown| toneColour(shown.tone, .normal) else settled;
        _ = try painter.put(word_column, text, word_end -| word_column, .{ .colour = tone });
    }
    var buffer: [8]u8 = undefined;
    try painter.putRight(columns.end, ageText(&buffer, (state.now_ms / 1000) -| row.state.since()), .{ .colour = .quiet });
    return painter.finish();
}

/// When a row's mark stops pulsing, in Unix milliseconds.
fn pulseEnd(row: *const Row) u64 {
    return row.mark_since *| 1000 +| pulse_window_ms;
}

/// The row title: its Label, else the first line of its first Message (a
/// greyed hint), else its reference.
fn title(state: *const State, row: *const Row) session_line.Name {
    return session_line.name(if (row.label) |*text| text.slice() else null, state.lineOf(row), &row.reference);
}

/// The colour a work line's tone asks for, else `neutral`.
fn toneColour(tone: work_line.Tone, neutral: Colour) Colour {
    return switch (tone) {
        .normal => neutral,
        .quiet => .quiet,
        .attention => .attention,
    };
}

/// Bytes the row's word takes at most: work's words and its clock, or an
/// ended state's word naming its starter by quoted Label or reference.
const max_word_bytes = max: {
    var said = 0;
    for (rules.values) |rule| if (rule.word) |text| {
        said = @max(said, text.len);
    };
    const starter = said + " ".len + work_line.max_dot_bytes + " for ".len + @max("\"\"".len + max_label_bytes, @sizeOf(Reference));
    break :max @max(work_line.max_words_bytes + work_line.max_clock_bytes, starter);
};

/// What the row says beside its title, unless its group heading says it:
/// work under way in the conversation's words, else the state's word.
fn word(buffer: *[max_word_bytes]u8, state: *const State, row: *const Row, rule: Rule, line: ?work_line.Line, script: work_line.Script) []const u8 {
    if (rule.said_by_group and row.group() == rule.group) return "";
    if (line) |shown| {
        var clock: [work_line.max_clock_bytes]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ shown.words, work_line.clockText(&clock, shown.clock, .row, script) }) catch unreachable;
    }
    const said = rule.word.?;
    if (!rule.starter) return said;
    const dot = work_line.glyphs.get(script).dot;
    const sender = (row.first orelse return said).sender orelse return said;
    if (state.find(sender)) |starter| if (starter.label) |*text| return std.fmt.bufPrint(buffer, "{s} {s} for \"{s}\"", .{ said, dot, text.slice() }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{s} {s} for {s}", .{ said, dot, &sender }) catch unreachable;
}

/// Compact age: 42s, 7m, 3h, 12d.
fn ageText(buffer: *[8]u8, seconds: u64) []const u8 {
    const units = [_]struct { u64, u8 }{ .{ 86400, 'd' }, .{ 3600, 'h' }, .{ 60, 'm' } };
    for (units) |unit| if (seconds >= unit[0]) return std.fmt.bufPrint(buffer, "{d}{c}", .{ @min(seconds / unit[0], 999), unit[1] }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
}

/// Host seconds at the tests' first tick.
const test_now_s = 1_792_937_000;

fn testState() error{OutOfMemory}!State {
    var state: State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/home/d/code/rui", .home = "/home/d" });
    return state;
}

fn testToken(generation: u64) Token {
    return .{ .instance = @splat(0xab), .generation = generation };
}

fn bounded(comptime capacity: usize, text: []const u8) Bounded(capacity) {
    var value: Bounded(capacity) = .{};
    value.set(text) catch unreachable;
    return value;
}

const TestSession = struct {
    label: ?[]const u8 = null,
    workspace: []const u8 = "/home/d/code/rui",
    first: ?First = .{ .position = 1, .admission = 4, .sender = null },
    yours: bool = false,
    first_action: ?u64 = null,
};

fn session(ref: *const [6]u8, state: WorkState, options: TestSession) Listed {
    return .{
        .reference = ref.*,
        .workspace = options.workspace,
        .label = options.label,
        .state = state,
        .first_action = options.first_action,
        .first = options.first,
        .from_person_at = if (options.yours) test_now_s - 3600 else null,
    };
}

fn ago(seconds: u64) WorkState.Since {
    return .{ .since = test_now_s - seconds };
}

/// Starts the overview's clock and answers its first list request with
/// `rows` as one full listing.
fn opened(rows: []const Listed) !State {
    var state = try testState();
    errdefer state.deinit();
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), rows);
    return state;
}

/// Answers the listing in flight with `rows`, eight per page.
fn respond(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    var at: usize = 0;
    while (true) {
        const end = @min(at + max_page_rows, rows.len);
        const last: ?Answer = if (end == rows.len) .{ .delta = delta, .since = since } else null;
        const effects = try step(state, .{ .list = .{ .page = .{ .rows = rows[at..end], .answer = last } } });
        if (end == rows.len) return effects;
        try std.testing.expectEqual(@as(usize, 0), effects.len);
        at = end;
    }
}

/// Lets the list interval pass and answers the request it brings.
fn refresh(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    const asked = try step(state, .{ .tick = state.now_ms + list_interval_ms });
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expect(asked.items[0] == .list);
    return respond(state, delta, since, rows);
}

/// A key the overview binds, pressed with `draft` in the composer.
fn press(state: *State, draft: Draft, action: Action) !Effects {
    return step(state, .{ .composed = .{ .outcome = .{ .action = action }, .draft = draft } });
}

/// Types `text` as the whole draft, its caret at the end, as the shell's
/// line editor reports an edit, and returns that draft.
fn typeText(state: *State, text: []const u8) !Draft {
    const draft: Draft = .{ .bytes = text, .cursor = text.len };
    try expectEffects(&.{}, try step(state, .{ .composed = .{ .outcome = .redraw, .draft = draft } }));
    return draft;
}

/// The line editor's Enter on `draft`.
fn submit(state: *State, draft: Draft) !Effects {
    return step(state, .{ .composed = .{ .outcome = .submit, .draft = draft } });
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
            .start => |start| {
                try std.testing.expectEqualStrings(start.text, got.start.text);
                var want_args: [2 * start_options.len][]const u8 = undefined;
                var got_args: [2 * start_options.len][]const u8 = undefined;
                const a = start.settings.args(&want_args);
                const b = got.start.settings.args(&got_args);
                try std.testing.expectEqual(a.len, b.len);
                for (a, b) |x, y| try std.testing.expectEqualStrings(x, y);
            },
            .open => |ref| try std.testing.expectEqualStrings(&ref, &got.open),
            .stop => |ref| try std.testing.expectEqualStrings(&ref, &got.stop),
            .notify => |alert| {
                try std.testing.expectEqualStrings(alert.name, got.notify.name);
                try std.testing.expectEqual(alert.kind, got.notify.kind);
                try std.testing.expectEqual(alert.more, got.notify.more);
            },
            .clear_draft, .exit => {},
        }
    }
}

/// A notice, which reads whole on a 40-column overview in the row under its
/// input.
fn expectNotice(state: *const State, expected: ?[]const u8) !void {
    return expectNoticeAt(state, expected, true);
}

/// A notice whose data (a Host's code, the list of start settings) may be
/// cut at the edge of a narrow overview; its wording is not.
fn expectNoticeWithData(state: *const State, expected: []const u8) !void {
    return expectNoticeAt(state, expected, false);
}

fn expectNoticeAt(state: *const State, expected: ?[]const u8, whole_at_40: bool) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try std.testing.expectEqualStrings(text, notice.text());
        if (whole_at_40 and state.prompt == null) {
            const screen = try screenText(state, 40, 24, .{});
            defer std.testing.allocator.free(screen);
            var lines = std.mem.splitScalar(u8, screen, '\n');
            for (0..23) |_| _ = lines.next();
            try std.testing.expectEqualStrings(text, std.mem.trim(u8, lines.next().?, " "));
        }
    } else if (state.notice) |*notice| try std.testing.expectEqualStrings("", notice.text());
}

fn expectSelected(state: *const State, expected: *const [6]u8) !void {
    try std.testing.expectEqualStrings(expected, &(state.selected orelse return error.TestExpectedSelection));
}

fn screenText(state: *const State, width: u16, height: u16, caps: Caps) ![]u8 {
    return frameText(state, width, height, caps, 0);
}

fn frameText(state: *const State, width: u16, height: u16, caps: Caps, frame: u64) ![]u8 {
    var screen = try render(std.testing.allocator, state, .{}, width, height, caps, frame);
    defer screen.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try screen.write(&text.writer);
    return text.toOwnedSlice();
}

fn expectScreen(state: *const State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    const actual = try screenText(state, width, height, caps);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

/// Twenty Sessions in every group, as the Rui Khadi mock shows them.
const mixed = [_]Listed{
    session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Fix the flaky resize test", .yours = true }),
    session("h8q2mz", .{ .finished = ago(12 * 60) }, .{ .yours = true }),
    session("r4t9vw", .{ .approval = ago(3 * 60) }, .{ .label = "Review PR 412", .yours = true }),
    session("a1b2c3", .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .{ .label = "Find why store tests fail" }),
    session("b2c3d4", .{ .working = ago(2 * 60) }, .{ .label = "Profile the curl send queue" }),
    session("c3d4e5", .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = (test_now_s + 12) * 1000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .{ .label = "Audit permission paths" }),
    session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Trace Host shutdown order" }),
    session("e5f6g7", .{ .stopping = ago(8) }, .{ .label = "List unused build steps" }),
    session("f6g7h8", .{ .working = ago(90) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } }),
    session("g7h8j9", .{ .idle = ago(2 * 3600) }, .{ .label = "Check macOS socket cleanup", .first = null }),
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

/// One row of each kind, its group heading and its row in Unicode and ASCII.
const kind_cases = [_]struct { state: WorkState, heading: []const u8, unicode: []const u8, ascii: []const u8, colour: Colour, stoppable: bool }{
    .{ .state = .{ .idle = ago(7200) }, .heading = " Idle", .unicode = "  ○ Write the notes                                                          2h", .ascii = "  o Write the notes                                                          2h", .colour = .normal, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .heading = " Working", .unicode = "  ○ Write the notes                                  Starting                5s", .ascii = "  o Write the notes                                  Starting                5s", .colour = .normal, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .heading = " Working", .unicode = "  ● Write the notes                                  Waiting                40s", .ascii = "  * Write the notes                                  Waiting                40s", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .heading = " Working", .unicode = "  ● Write the notes                        Provider error · retry 2 in 12s  30s", .ascii = "  * Write the notes                        Provider error - retry 2 in 12s  30s", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .heading = " Working", .unicode = "  ● Write the notes                                  Run the logic tests     1m", .ascii = "  * Write the notes                                  Run the logic tests     1m", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .heading = " Working", .unicode = "  ○ Write the notes                                  Needs approval          3m", .ascii = "  o Write the notes                                  Needs approval          3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .heading = " Working", .unicode = "  ● Write the notes                                  Stopping…               8s", .ascii = "  * Write the notes                                  Stopping.               8s", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .heading = " Finished", .unicode = "  ✓ Write the notes                                                         12m", .ascii = "  + Write the notes                                                         12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .heading = " Stopped or failed", .unicode = "  × Write the notes                                  failed                  3h", .ascii = "  x Write the notes                                  failed                  3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .heading = " Stopped or failed", .unicode = "  ■ Write the notes                                  stopped                 2d", .ascii = "  # Write the notes                                  stopped                 2d", .colour = .normal, .stoppable = false },
};

test "every work state follows the rules table, in Unicode and ASCII" {
    comptime std.debug.assert(kind_cases.len == std.enums.values(Kind).len);
    for (kind_cases, std.enums.values(Kind)) |case, kind| {
        try std.testing.expectEqual(kind, std.meta.activeTag(case.state));
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        const rule = rules.get(kind);
        try std.testing.expectEqual(case.stoppable, rule.stoppable);
        // Only work under way has a work line, and only idle or ended work
        // a word of its own.
        try std.testing.expectEqual(case.state.progress() == null, rule.word != null);
        for ([_]Caps{ .{}, .{ .unicode = false } }, [_][]const u8{ case.unicode, case.ascii }) |caps, expected| {
            const text = try screenText(&state, 80, 24, caps);
            defer std.testing.allocator.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            for (0..4) |_| _ = lines.next();
            try std.testing.expectEqualStrings(case.heading, lines.next().?);
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
        // The mark takes its colour, and the word one only when it needs
        // the person or is quiet.
        var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, 0);
        defer screen.deinit();
        try std.testing.expectEqual(Background.selection, screen.styleAt(5, 1).?.background);
        state.selected = null;
        var unselected = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, 0);
        defer unselected.deinit();
        try std.testing.expectEqual(Style{ .colour = case.colour }, unselected.styleAt(5, 2).?);
        const tone: Colour = switch (case.colour) {
            .attention, .failure, .quiet => case.colour,
            else => .normal,
        };
        if (unselected.styleAt(5, 53)) |style| try std.testing.expectEqual(Style{ .colour = tone }, style);
    }
}

test "a description's controls read escaped in its row's words, as its call row shows them" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run\t\x1b[2J\u{202e}tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{session("k7m2qx", bash, .{ .label = "Write the notes" })});
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..5) |_| _ = lines.next();
    try std.testing.expectEqualStrings("  ● Write the notes                                Run\\t\\x1b[2J\\u202etests   1m", lines.next().?);
}

test "a retry that has fallen due reads as starting in its words, mark and colour" {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{session("k7m2qx", due, .{ .label = "Write the notes" })});
    defer state.deinit();
    state.selected = null;
    const text = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "Write the notes").?;
    const start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n').?;
    try std.testing.expectEqualStrings("  ○ Write the notes                                  Starting                2s", text[start..end]);
    var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{ .depth = .none }, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .normal }, screen.styleAt(5, 2).?);
    try std.testing.expectEqual(Style{ .colour = .normal }, screen.styleAt(5, 53).?);
}

/// Rows whose state changed 0, 1 and 2 seconds ago, so their marks pulse,
/// beside two whose changes are older and hold still.
const fresh = [_]Listed{
    session("s0rt00", .{ .working = ago(0) }, .{ .label = "Started just now" }),
    session("f1n1sh", .{ .finished = ago(1) }, .{ .label = "Finished a second ago" }),
    session("a5k1ng", .{ .approval = ago(2) }, .{ .label = "Asked two seconds ago" }),
    session("f4iled", .{ .failed = .{ .since = test_now_s - 3, .code = bounded(session_work.max_code_bytes, "provider_error"), .resets_at = null } }, .{ .label = "Failed three seconds ago" }),
    session("w0rk00", .{ .working = ago(40) }, .{ .label = "Working a while" }),
};

/// The glyph that the row titled `label` shows on `text`.
fn markOf(text: []const u8, label: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, label).?;
    const line = text[std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1 .. at];
    return std.mem.trim(u8, line, " ");
}

test "a mark pulses out of step with others for a moment after its row changes, then holds still" {
    var state = try opened(&fresh);
    defer state.deinit();
    state.selected = null;
    const still = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(still);
    const pulsing = [_]struct { []const u8, u64 }{
        .{ "Started just now", test_now_s },
        .{ "Finished a second ago", test_now_s - 1 },
        .{ "Asked two seconds ago", test_now_s - 2 },
    };
    for (0..pulse_dots.len + 1) |frame| {
        const text = try frameText(&state, 80, 24, .{}, frame);
        defer std.testing.allocator.free(text);
        // A fresh row steps through its steady mark and the dots from a
        // phase its change second sets.
        for (pulsing) |row| {
            const phase = (frame + row[1]) % (pulse_dots.len + 1);
            const wanted = if (phase == 0) markOf(still, row[0]) else pulse_dots[phase - 1];
            try std.testing.expectEqualStrings(wanted, markOf(text, row[0]));
        }
        // Rows that changed apart do not pulse together.
        try std.testing.expect(!std.mem.eql(u8, markOf(text, "Started just now"), markOf(text, "Finished a second ago")));
        // Older changes hold still.
        try std.testing.expectEqualStrings("×", markOf(text, "Failed three seconds ago"));
        try std.testing.expectEqualStrings("●", markOf(text, "Working a while"));
        var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(screen.pulses);
        // A pulsing mark keeps its rule's colour.
        const asked = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Asked two seconds ago").?], "\n");
        try std.testing.expectEqual(Style{ .colour = .attention }, screen.styleAt(asked, 2).?);
    }
    // ASCII, NO_COLOR and a faded screen hold still on every frame.
    for ([_]Caps{ .{ .unicode = false }, .{ .depth = .none }, .{ .unicode = false, .depth = .none }, .{} }, 0..) |caps, at| {
        if (at == 3) state.unreachable_since_ms = state.now_ms;
        const first = try screenText(&state, 80, 24, caps);
        defer std.testing.allocator.free(first);
        for (1..pulse_dots.len + 1) |frame| {
            const text = try frameText(&state, 80, 24, caps, frame);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings(first, text);
            var screen = try render(std.testing.allocator, &state, .{}, 80, 24, caps, frame);
            defer screen.deinit();
            try std.testing.expect(!screen.pulses);
        }
    }
}

test "a state change under the same mark holds still, and a new mark pulses" {
    const Pulses = struct {
        fn at(state: *const State) !bool {
            var screen = try render(std.testing.allocator, state, .{}, 80, 24, .{}, 1);
            defer screen.deinit();
            return screen.pulses;
        }
    };
    for ([_]Delta{ .changed, .full }) |delta| {
        var state = try opened(&.{session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Keep working" })});
        defer state.deinit();
        // Working, then Bash, then working again: each refresh's state is
        // new, but the mark stays ●.
        const bash: WorkState = .{ .bash = .{ .since = state.now_ms / 1000 + 1, .call = 0, .description = null, .running = 1, .approvals = 0 } };
        _ = try refresh(&state, delta, testToken(2), &.{session("k7m2qx", bash, .{ .label = "Keep working" })});
        try std.testing.expect(!try Pulses.at(&state));
        const working: WorkState = .{ .working = .{ .since = state.now_ms / 1000 + 1 } };
        _ = try refresh(&state, delta, testToken(3), &.{session("k7m2qx", working, .{ .label = "Keep working" })});
        try std.testing.expect(!try Pulses.at(&state));
        // No pulse end to tick for: the next listing is the next wake.
        try std.testing.expectEqual(@as(?u64, state.next_list_ms), state.wakeAt());
        const finished: WorkState = .{ .finished = .{ .since = state.now_ms / 1000 + 1 } };
        _ = try refresh(&state, delta, testToken(4), &.{session("k7m2qx", finished, .{ .label = "Keep working" })});
        try std.testing.expect(try Pulses.at(&state));
    }
}

test "the overview ticks as each pulse ends, and once every change is old nothing pulses" {
    var state = try opened(&fresh);
    defer state.deinit();
    // The listing falls due first; while it is in flight, the next pulse to
    // end wakes the overview.
    try std.testing.expectEqual(@as(?u64, (test_now_s + 1) * 1000), state.wakeAt());
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    try std.testing.expect(state.listing);
    try std.testing.expectEqual(@as(?u64, (test_now_s + 2) * 1000), state.wakeAt());
    _ = try step(&state, .{ .tick = (test_now_s + 2) * 1000 });
    try std.testing.expectEqual(@as(?u64, (test_now_s + 3) * 1000), state.wakeAt());
    _ = try step(&state, .{ .tick = (test_now_s + 3) * 1000 });
    try std.testing.expectEqual(@as(?u64, null), state.wakeAt());
    for (0..pulse_dots.len + 1) |frame| {
        var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(!screen.pulses);
    }
}

test "the screen asks for frames only while a pulsing mark shows" {
    var rows: [31]Listed = undefined;
    rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes" });
    for (rows[1..], 1..) |*row, at| {
        var ref: [6]u8 = "idle00".*;
        _ = std.fmt.bufPrint(ref[4..], "{d:0>2}", .{at}) catch unreachable;
        row.* = session(&ref, .{ .idle = ago(7200 + at) }, .{ .label = "Wait for a reply" });
    }
    var state = try opened(&rows);
    defer state.deinit();
    const Pulses = struct {
        fn at(from: *const State, height: u16) !bool {
            var screen = try render(std.testing.allocator, from, .{}, 80, height, .{}, 1);
            defer screen.deinit();
            return screen.pulses;
        }
    };
    try std.testing.expect(try Pulses.at(&state, 24));
    // Scrolled out of sight, the pulsing row needs no frames.
    _ = try press(&state, .{}, .last);
    try std.testing.expect(!try Pulses.at(&state, 24));
    try std.testing.expect(try Pulses.at(&state, 60));
}

fn frameBytes(screen: *const Screen, shown: ?*const Screen) ![]u8 {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer bytes.deinit();
    try screen.writeFrame(shown, &bytes.writer);
    return bytes.toOwnedSlice();
}

test "a frame writes only what changed on the screen the terminal shows" {
    // Two rows changed this second, so their marks pulse in step.
    var rows = mixed;
    rows[0].state = .{ .working = ago(0) };
    rows[4].state = .{ .working = ago(0) };
    // In colour too: a cleared line takes the ground first, and a span
    // ends in the next one's SGR instead of a reset.
    for ([_]Caps{ .{ .depth = .none }, .{} }) |caps| {
        var state = try opened(&rows);
        defer state.deinit();
        state.selected = null;
        const plain = caps.depth == .none;
        var still = try render(std.testing.allocator, &state, .{}, 80, 24, caps, 0);
        defer still.deinit();
        var pulsed = try render(std.testing.allocator, &state, .{}, 80, 24, caps, 1);
        defer pulsed.deinit();
        var wider = try render(std.testing.allocator, &state, .{}, 81, 24, caps, 1);
        defer wider.deinit();
        // Unknown contents, or another size, clear and draw every line.
        for ([_]struct { *const Screen, ?*const Screen }{ .{ &still, null }, .{ &wider, &still } }) |case| {
            const bytes = try frameBytes(case[0], case[1]);
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqual(@as(usize, 24), std.mem.count(u8, bytes, "\x1b[2K"));
        }
        const unchanged = try frameBytes(&still, &still);
        defer std.testing.allocator.free(unchanged);
        try std.testing.expectEqualStrings("", unchanged);
        // The next pulse frame writes the two pulsing marks and nothing
        // else; without colour nothing pulses.
        const pulse = try frameBytes(&pulsed, &still);
        defer std.testing.allocator.free(pulse);
        if (plain) {
            try std.testing.expectEqualStrings("", pulse);
        } else {
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, pulse, "\x1b[2K"));
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pulse, "H\x1b[0"));
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pulse, "m·"));
        }
        // A line laid out anew is cleared and drawn whole; the others stay.
        const draft = try typeText(&state, "hi");
        var typed = try render(std.testing.allocator, &state, draft, 80, 24, caps, 0);
        defer typed.deinit();
        const composed = try frameBytes(&typed, &still);
        defer std.testing.allocator.free(composed);
        // The composer and its hints changed; the list did not.
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, composed, "\x1b[2K"));
        try std.testing.expect(std.mem.indexOf(u8, composed, if (plain) "\x1b[23;1H\x1b[2K" else "\x1b[23;1H\x1b[0;48;2;") != null);
        try std.testing.expect(std.mem.indexOf(u8, composed, if (plain) "\x1b[24;1H\x1b[2K" else "\x1b[24;1H\x1b[0;48;2;") != null);
    }
}

test "ctrl-x asks to stop only a row its rule lets it stop, and a second ctrl-x stops it" {
    for (kind_cases) |case| {
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        if (!case.stoppable) {
            try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
            var buffer: [64]u8 = undefined;
            const expected = if (rules.get(case.state).word) |said| try std.fmt.bufPrint(&buffer, "k7m2qx is already {s}.", .{said}) else "k7m2qx: Stopping";
            try expectNotice(&state, expected);
            continue;
        }
        try std.testing.expectEqualStrings("k7m2qx", &state.prompt.?.stop);
        try expectNotice(&state, null);
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .{}, .stop));
        try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
        // Until its result arrives the row says it is stopping, and a third
        // ctrl-x finds nothing to stop.
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "● Write the notes                                  Stopping…") != null);
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectNotice(&state, "k7m2qx: Stopping");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    }
}

test "a cancelled stop prompt sends nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectSelected(&state, "k7m2qx");
    // Esc only cancels: the draft stays.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{ .bytes = "keep", .cursor = 4 }, .clear));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "k7m2qx");
    // Another key cancels, then acts.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{}, .next));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "r4t9vw");
    // So does input that left the draft as it was.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .outcome = .none, .draft = .{} } }));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    // A row that finished after the prompt opened has nothing left to stop.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    _ = try refresh(&state, .changed, testToken(2), &.{session("r4t9vw", .{ .finished = ago(0) }, .{ .label = "Review PR 412", .yours = true })});
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectNotice(&state, "r4t9vw is already finished.");
    // A failed stop says why. The finished row moved to the top of its group.
    try expectEffects(&.{}, try press(&state, .{}, .next));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNoticeWithData(&state, "! k7m2qx not stopped: session_not_found");
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
        if (n != 0) try expectEffects(&.{}, try press(&state, .{}, .next));
        ref.* = state.selected.?;
        for (stopped[0..n]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, ref));
        var bytes: [32]u8 = undefined;
        const handle = try std.fmt.bufPrint(&bytes, "stop-handle-{d}", .{n});
        var notice: [128]u8 = undefined;
        const recover = try std.fmt.bufPrint(&notice, "! {s} stop unsure; details on exit", .{ref});
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectEffects(&.{.{ .stop = ref.* }}, try press(&state, .{}, .stop));
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref.*, .outcome = .{ .unconfirmed = handle } } }));
        try expectNotice(&state, recover);
        // The row stays stopping: another Ctrl-X sends nothing and says
        // so again.
        try std.testing.expectEqual(Kind.stopping, shownKind(&state, state.find(ref.*).?));
        state.notice = null;
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectNotice(&state, recover);
        try expected.writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ ref, handle });
    }
    // A full ledger refuses a stop of a Session it does not hold.
    try expectEffects(&.{}, try press(&state, .{}, .next));
    const last = state.selected.?;
    for (stopped) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, &last));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectNotice(&state, "! Busy; try again shortly.");
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings(expected.written(), departure.written());
}

test "enter on a row opens it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try press(&state, draft, .next));
    try expectEffects(&.{.{ .open = "r4t9vw".* }}, try submit(&state, draft));
    // A blank draft is no request: Enter still opens the row.
    draft = try typeText(&state, "  ");
    try expectEffects(&.{ .clear_draft, .{ .open = "r4t9vw".* } }, try submit(&state, draft));
    try expectSelected(&state, "r4t9vw");
}

test "esc clears the draft, then held start settings, and otherwise does nothing" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/configure --permission-mode ask");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    draft = try typeText(&state, "Fix the docs");
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    try std.testing.expect(!state.settings.empty());
    draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.settings.empty());
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try expectSelected(&state, "k7m2qx");
    try expectNotice(&state, null);
}

test "esc during a start clears the draft, then the settings, and the answer still settles it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/configure --permission-mode ask");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    draft = try typeText(&state, "Fix the docs");
    _ = try submit(&state, draft);
    try std.testing.expect(state.starting());
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.settings.empty());
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .failed = "model_capability_unavailable" } }));
    try std.testing.expect(!state.starting());
}

test "the composer starts a Session with its text and opens it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "Fix the flaky resize test");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "Fix the flaky resize test" } }}, try submit(&state, draft));
    try std.testing.expect(state.starting());
    try expectEffects(&.{ .clear_draft, .{ .open = "z9y8x7".* } }, try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } }));
    try std.testing.expect(!state.starting());
    try expectSelected(&state, "z9y8x7");
    // The next tick lists at once, so the new row is there on return.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));

    // A failed start keeps the text for another Enter.
    draft = try typeText(&state, "Try again");
    _ = try submit(&state, draft);
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .failed = "model_capability_unavailable" } }));
    try expectNoticeWithData(&state, "! Not started: model_capability_unavailable");
    try std.testing.expect(!state.starting());
}

test "the composer starts text with one slash from //, as a conversation does" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/home/me/project needs investigating");
    try expectEffects(&.{}, try submit(&state, draft));
    try expectNotice(&state, "! Unknown; try /configure or /exit");
    draft = try typeText(&state, "//home/me/project needs investigating");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "/home/me/project needs investigating" } }}, try submit(&state, draft));
}

test "the composer sends its draft byte for byte, as a conversation does" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "    return x\n");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "    return x\n" } }}, try submit(&state, draft));

    var other = try opened(&mixed);
    defer other.deinit();
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = " /exit" } }}, try submit(&other, try typeText(&other, " /exit")));
}

test "/configure holds start settings for the Session the next Enter starts" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/configure --permission-mode ask --label \"lane four\"");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try expectNotice(&state, null);
    try expectScreenLine(&state, 23, " start settings: --permission-mode ask --label \"lane four\" · esc clear");
    // A later value replaces an earlier one; the rest stay.
    draft = try typeText(&state, "/configure --label \"lane \\\"five\\\"\" --model gpt-5.5");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    var buffer: [2 * start_options.len][]const u8 = undefined;
    const args = state.settings.args(&buffer);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    for ([_][]const u8{ "--model", "gpt-5.5", "--permission-mode", "ask", "--label", "lane \"five\"" }, args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try expectScreenLine(&state, 23, " start settings: --model gpt-5.5 --permission-mode ask --label \"la… · esc clear");

    var held: StartSettings = .{};
    try held.put(1, "gpt-5.5");
    try held.put(4, "ask");
    try held.put(8, "lane \"five\"");
    draft = try typeText(&state, "Run the tests");
    try expectEffects(&.{.{ .start = .{ .settings = &held, .text = "Run the tests" } }}, try submit(&state, draft));
    _ = try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } });
    try std.testing.expect(state.settings.empty());

    // Only `session start` options, in the conversation's grammar, are held.
    for ([_]struct { []const u8, []const u8 }{
        .{ "/configure --instructions -", "! Set --instructions after the start" },
        .{ "/configure --text-output", "! Set --text-output after the start" },
        .{ "/configure", configure_usage },
        .{ "/configure --help", configure_usage },
        .{ "/configure --bogus 1", configure_usage },
        .{ "/configure --label \"open", configure_usage },
        // The Host would admit it; its Turns would fail at the provider.
        .{ "/configure --model gpt-5", "! Unsupported; session configure -h" },
        .{ "/status", "! Unknown; try /configure or /exit" },
    }) |case| {
        draft = try typeText(&state, case[0]);
        try expectEffects(&.{}, try submit(&state, draft));
        try if (case[1].ptr == configure_usage.ptr) expectNoticeWithData(&state, case[1]) else expectNotice(&state, case[1]);
        try std.testing.expect(state.settings.empty());
    }
}

test "start settings are the options session start shares with /configure" {
    const expected = [_][]const u8{ "provider", "model", "workspace", "tools", "permission-mode", "compaction-trigger", "output-reservation", "reasoning-effort", "label" };
    try std.testing.expectEqual(expected.len, start_options.len);
    for (expected, start_options) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectStyle(state: *const State, row: usize, column: usize, expected: Style) !void {
    var screen = try render(std.testing.allocator, state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(expected, screen.styleAt(row, column).?);
}

fn expectScreenLine(state: *const State, line: usize, expected: []const u8) !void {
    const text = try screenText(state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..line) |_| _ = lines.next();
    try std.testing.expectEqualStrings(expected, lines.next().?);
}

test "end of input, ctrl-c and /exit leave" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{.exit}, try press(&state, .{}, .exit));
    draft = try typeText(&state, "draft");
    try expectEffects(&.{.exit}, try press(&state, draft, .exit));
    draft = try typeText(&state, "/exit");
    try expectEffects(&.{.exit}, try submit(&state, draft));
}

test "a line the editor rejects says why once; text it could not take clears" {
    var draft: Draft = .{};
    for ([_]struct { keymap.Outcome(Action), []const u8, bool }{
        .{ .{ .refused = .invalid }, "! Not valid text; nothing sent.", true },
        .{ .{ .refused = .overflow }, "! Too long to send.", true },
        .{ .{ .refused = .edit_rejected }, "! Can't add that character alone.", false },
        .{ .{ .refused = .unbound }, "! That key does nothing here.", false },
    }) |case| {
        var state = try opened(&mixed);
        defer state.deinit();
        draft = try typeText(&state, "first");
        const effects = try step(&state, .{ .composed = .{ .outcome = case[0], .draft = draft } });
        try expectEffects(if (case[2]) &.{.clear_draft} else &.{}, effects);
        try expectNotice(&state, case[1]);
        // The next edit clears the notice.
        draft = try typeText(&state, "second");
        try expectNotice(&state, null);
    }
}

test "session resume opens its Session through the overview, which then keeps it selected" {
    var state = try testState();
    defer state.deinit();
    try expectEffects(&.{.{ .open = "c3d4e5".* }}, try step(&state, .{ .open = "c3d4e5".* }));
    // The first listing finds the row; the selection waited for it.
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectSelected(&state, "c3d4e5");
}

test "an unconfirmed start clears the composer and names the request that recovers it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings("", departure.written());

    draft = try typeText(&state, "/configure --permission-mode ask");
    _ = try submit(&state, draft);
    draft = try typeText(&state, "Fix the flaky resize test");
    _ = try submit(&state, draft);
    const handle = "0f8e2c1a-7b3d-4e5f-9a6b-1c2d3e4f5a6b";
    // Another Enter would be a second Session, so the text is not kept.
    try expectEffects(&.{.clear_draft}, try step(&state, .{ .start = .{ .unconfirmed = handle } }));
    try std.testing.expect(!state.starting());
    try std.testing.expect(state.settings.empty());
    try expectNotice(&state, "! Start unsure; details on exit");
    try expectScreenLine(&state, 23, " ! Start unsure; details on exit");
    // The next tick lists at once, so a start that did land shows.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));
    // A second unconfirmed start keeps the first one's handle.
    const second = "9a0b1c2d-3e4f-4a6b-8c7d-0f8e2c1a7b3d";
    draft = try typeText(&state, "Fix it again");
    _ = try submit(&state, draft);
    try expectEffects(&.{.clear_draft}, try step(&state, .{ .start = .{ .unconfirmed = second } }));
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings("rui: Not sure the new Session started. Check with: rui request recover " ++ handle ++ "\n" ++
        "rui: Not sure the new Session started. Check with: rui request recover " ++ second ++ "\n", departure.written());
}

test "leaving with a start in flight says what became of it" {
    var draft: Draft = .{};
    const handle = "0f8e2c1a-7b3d-4e5f-9a6b-1c2d3e4f5a6b";
    const Case = struct { result: ?StartResult, departure: []const u8 };
    for ([_]Case{
        .{ .result = null, .departure = "rui: The new Session did not start.\n" },
        .{ .result = .{ .failed = "Cancelled" }, .departure = "rui: The new Session was not started (Cancelled); start it again from the overview.\n" },
        .{ .result = .{ .started = .{ .reference = "n3w5es".*, .handle = handle } }, .departure = "rui: Started n3w5es.\n" },
        .{ .result = .{ .unconfirmed = handle }, .departure = "rui: Not sure the new Session started. Check with: rui request recover " ++ handle ++ "\n" },
    }) |case| {
        var state = try opened(&mixed);
        defer state.deinit();
        draft = try typeText(&state, "Fix the flaky resize test");
        _ = try submit(&state, draft);
        try expectEffects(&.{}, try step(&state, .leave));
        // An accepted start no longer opens: the terminal is gone.
        if (case.result) |result| try expectEffects(&.{}, try step(&state, .{ .start = result }));
        var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer departure.deinit();
        try writeDeparture(&state, &departure.writer);
        try std.testing.expectEqualStrings(case.departure, departure.written());
    }
    // With no start in flight, leaving says nothing of one.
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .leave));
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings("", departure.written());
}

test "the cursor sits at the composer's caret and hides while a start is pending" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    const Expect = struct {
        fn cursor(from: *const State, typed: Draft, width: u16, expected: ?Screen.Cursor) !void {
            var screen = try render(std.testing.allocator, from, typed, width, 24, .{}, 0);
            defer screen.deinit();
            try std.testing.expectEqual(expected, screen.cursor);
        }
        fn composerLine(from: *const State, typed: Draft, expected: []const u8) !void {
            var screen = try render(std.testing.allocator, from, typed, 80, 24, .{}, 0);
            defer screen.deinit();
            var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer text.deinit();
            try screen.write(&text.writer);
            var lines = std.mem.splitScalar(u8, text.written(), '\n');
            for (0..22) |_| _ = lines.next();
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
    };
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 3 });
    draft = try typeText(&state, "Fix 中");
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 9 });
    // The caret sits where the editor holds it, with the text after it.
    draft.cursor = 4;
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 7 });
    try Expect.composerLine(&state, draft, " › Fix 中");
    // A draft wider than the composer wraps between words into rows that
    // grow upward from the bottom: "Fix ", 76 x, then 24 x and " end".
    const long = "Fix " ++ @as([100]u8, @splat('x')) ++ " end";
    draft = try typeText(&state, long);
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 31 });
    // Two cells wide, the space before "end" hangs past the edge: "en",
    // then "d".
    try Expect.cursor(&state, draft, 6, .{ .row = 22, .column = 4 });
    // On the soft break after "Fix ", the caret starts the next row.
    draft.cursor = 4;
    try Expect.cursor(&state, draft, 80, .{ .row = 21, .column = 3 });
    try Expect.composerLine(&state, draft, "   " ++ @as([24]u8, @splat('x')) ++ " end");
    draft.cursor = long.len;
    _ = try submit(&state, draft);
    try Expect.cursor(&state, draft, 80, null);
}

test "a draft past its cap scrolls inside the composer and the rule counts what it hides" {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13";
    const Expect = struct {
        fn rows(from: *const State, typed: Draft, caps: Caps, rule: []const u8, top: []const u8, anchor: usize) !void {
            var screen = try render(std.testing.allocator, from, typed, 40, 40, caps, 0);
            defer screen.deinit();
            var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer written.deinit();
            try screen.write(&written.writer);
            var lines = std.mem.splitScalar(u8, written.written(), '\n');
            for (0..28) |_| _ = lines.next();
            // Ten rows of draft under the rule, the hints on the last row.
            try std.testing.expectEqualStrings(rule, lines.next().?);
            try std.testing.expectEqualStrings(top, lines.next().?);
            try std.testing.expectEqual(anchor, screen.draft_anchor);
        }
    };
    // At the end, the first three lines are hidden above.
    var draft: Draft = .{ .bytes = text, .cursor = text.len };
    try Expect.rows(&state, draft, .{}, " ─────────── ↑ 3 more lines ───────────", "   4", 6);
    // The caret moving up inside the shown lines keeps them.
    draft = .{ .bytes = text, .cursor = 10, .anchor = 2 };
    try Expect.rows(&state, draft, .{}, " ──────── ↑ 1 · ↓ 2 more lines ────────", "   2", 2);
    // Above them, the composer follows the caret to the top.
    draft = .{ .bytes = text, .cursor = 0, .anchor = 6 };
    try Expect.rows(&state, draft, .{}, " ─────────── ↓ 3 more lines ───────────", " › 1", 0);
    // Without Unicode the rule draws in ASCII.
    draft = .{ .bytes = text, .cursor = text.len };
    try Expect.rows(&state, draft, .{ .unicode = false }, " ----------- ^ 3 more lines -----------", "   4", 6);
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
    for ([_]struct { *const [6]u8, u64 }{ .{ "h8q2mz", 4 }, .{ "f6g7h8", 9 }, .{ "p3q4r5", 4 } }) |read| {
        reads.items[reads.len] = .{ .reference = read[0].*, .position = 1, .admission = read[1] };
        reads.len += 1;
    }
    // Rows in screen order; a labelled row or one with no Message needs none.
    try expectEffects(&.{.{ .read_first_lines = reads }}, try respond(&state, .full, testToken(1), &mixed));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "  summarize yesterday's CI failures\r\nand say which are new" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = null } }));
    // Another admission is another Message: ignored.
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "p3q4r5".*, .admission = 5, .line = "not this one" } }));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqual(Line.requested, state.find("p3q4r5".*).?.line);
    try expectScreenLine(&state, 7, "  ✓ summarize yesterday's CI failures                finished               12m");
    // Lines in flight or unreadable are not asked for again, and a refresh
    // that replaces a row keeps the line of its unchanged first Message.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{session("h8q2mz", .{ .working = ago(0) }, .{ .yours = true })}));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // An unreadable line is not asked for again while listings, changed or
    // full, name its unchanged first Message.
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } });
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{f6g7h8}));
    // The full listing finds h8q2mz finished again after the working above.
    try expectEffects(&.{.{ .notify = .{ .name = "summarize yesterday's CI failures", .kind = .finished, .more = 0 } }}, try refresh(&state, .full, testToken(4), &mixed));
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // Results nobody asked for are ignored: a second answer for a read line,
    // or one for a row whose line is unread.
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "a second answer" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = "a late answer" } }));
    try std.testing.expectEqual(@as(usize, 1), state.lines.items.len);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    // A new first Message is asked for.
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
    try std.testing.expectEqual(Line.unread, state.find("h8q2mz".*).?.line);
    try expectEffects(&.{.{ .read_first_lines = reads }}, try refresh(&state, .not_modified, testToken(1), &.{}));
}

test "Host facts give the health line, and a row from before a restart still says working" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Admitted before the restart" }),
        session("h8q2mz", .{ .working = ago(5) }, .{ .label = "Admitted after it" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
    });
    defer state.deinit();
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try expectScreenLine(&state, 2, "");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 2, " Host up 20s   slots 2/2");
    try expectStyle(&state, 2, 15, .{ .colour = .ink });
    // The restart is the Host's fact, said on the since line; the rows
    // keep their own words.
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, " Working").?..], after[std.mem.indexOf(u8, after, " Working").?..]);
    // Full slots draw in ink, free ones in the normal colour.
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 1 } });
    try expectScreenLine(&state, 2, " Host up 20s   slots 1/2");
    try expectStyle(&state, 2, 15, .{});
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
        // Each title shows at least its first word, and never fewer cells
        // than the Workspace beside it.
        try std.testing.expect(std.mem.indexOf(u8, text, "Profile") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Trace") != null);
        const columns = Columns.of(width);
        try std.testing.expect(columns.workspace == 0 or columns.word -| 2 -| Columns.title -| 2 -| columns.workspace >= columns.workspace);
    }
}

test "the selection stays on its Session when it moves from working to finished" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (0..4) |_| _ = try press(&state, .{}, .next);
    try expectSelected(&state, "e5f6g7");
    _ = try refresh(&state, .changed, testToken(2), &.{session("e5f6g7", .{ .finished = ago(0) }, .{ .label = "List unused build steps" })});
    try expectSelected(&state, "e5f6g7");
    try std.testing.expectEqual(Group.finished, state.find("e5f6g7".*).?.group());
    try expectEffects(&.{.{ .open = "e5f6g7".* }}, try submit(&state, .{}));
    try expectScreenLine(&state, 20, "  ✓ List unused build steps                                                  1s");
    // Moving on goes to the next row on screen, not the next old index.
    _ = try press(&state, .{}, .next);
    try expectSelected(&state, "m1n2p3");
    // A selected row that lands among a folded group's hidden rows opens the group.
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expect(state.unfolded.contains(.finished));
}

test "a listing notifies once of each Session that newly finished, failed or needs approval, naming the most urgent" {
    // What the overview opened on is not news.
    var state = try opened(&mixed);
    defer state.deinit();
    const fixing = session("k7m2qx", .{ .finished = ago(0) }, .{ .label = "Fix the flaky resize test", .yours = true });
    try expectEffects(&.{.{ .notify = .{ .name = "Fix the flaky resize test", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(2), &.{fixing}));
    // Rereading the same finish, or a full listing of unchanged rows, is not news.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{fixing}));
    var unchanged = mixed;
    unchanged[0] = fixing;
    try expectEffects(&.{}, try refresh(&state, .full, testToken(4), &unchanged));
    // Approval outranks a failure and a finish listed before it; a stop and
    // work under way are no news; an unseen Session's finish is.
    try expectEffects(&.{.{ .notify = .{ .name = "Find why store tests fail", .kind = .approval, .more = 2 } }}, try refresh(&state, .changed, testToken(5), &.{
        session("b2c3d4", .{ .failed = .{ .since = test_now_s, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .label = "Profile the curl send queue" }),
        session("e5f6g7", .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .label = "List unused build steps" }),
        session("d4e5f6", .{ .working = ago(0) }, .{ .label = "Trace Host shutdown order" }),
        session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 1 }),
        session("zz9zz9", .{ .finished = ago(0) }, .{ .first = null }),
    }));
    // A Session the overview never saw, unnamed, is named by its reference.
    try expectEffects(&.{.{ .notify = .{ .name = "yy8yy8", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(6), &.{session("yy8yy8", .{ .finished = ago(0) }, .{ .first = null })}));
    // The next Action to wait, once the first is decided, is a new wait.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(7), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 1 })}));
    try expectEffects(&.{.{ .notify = .{ .name = "Find why store tests fail", .kind = .approval, .more = 0 } }}, try refresh(&state, .changed, testToken(8), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 2 })}));
}

test "under an open conversation a listing notifies of other Sessions only, and its own news never comes twice" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .conversing = "k7m2qx".* }));
    try expectEffects(&.{.{ .notify = .{ .name = "Profile the curl send queue", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(2), &.{
        session("k7m2qx", .{ .finished = ago(0) }, .{ .label = "Fix the flaky resize test", .yours = true }),
        session("b2c3d4", .{ .finished = ago(0) }, .{ .label = "Profile the curl send queue" }),
    }));
    // Back on the overview, the catch-up listing finds nothing new.
    try expectEffects(&.{}, try step(&state, .{ .conversing = null }));
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{
        session("k7m2qx", .{ .finished = ago(0) }, .{ .label = "Fix the flaky resize test", .yours = true }),
        session("b2c3d4", .{ .finished = ago(0) }, .{ .label = "Profile the curl send queue" }),
    }));
}

test "moving into a folded group's hidden rows opens it" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(folded(&state, .finished));
    // Up from the first failed row lands on the last finished row shown.
    _ = try press(&state, .{}, .last);
    try expectSelected(&state, "y1z2a3");
    for (0..3) |_| _ = try press(&state, .{}, .previous);
    try expectSelected(&state, "s6t7v8");
    try std.testing.expect(folded(&state, .finished));
    _ = try press(&state, .{}, .next);
    try expectSelected(&state, "v8w9x0");
    try std.testing.expect(!folded(&state, .finished));
    _ = try press(&state, .{}, .first);
    try expectSelected(&state, "k7m2qx");
}

/// Each row once in `rows`, `by_reference` and `order`.
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

    // changed: replace by reference, insert what is new.
    _ = try refresh(&state, .changed, testToken(2), &.{ session("bbbbbb", .{ .finished = ago(0) }, .{ .label = "B" }), session("dddddd", .{ .pending = ago(0) }, .{ .label = "D" }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "dddddd" });
    try std.testing.expect(state.find("bbbbbb".*).?.state == .finished);
    try std.testing.expectEqual(testToken(2), state.token.?);

    // A page that restarts the listing supersedes the rows earlier pages
    // gave, and the listing replaces the set at its end.
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

    // not_modified keeps every row.
    asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{.{ .list = testToken(6) }}, asked);
    _ = try respond(&state, .not_modified, testToken(6), &.{});
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc", "eeeee0", "eeeee8" });

    // A full listing that names a Session twice keeps its later row.
    _ = try refresh(&state, .full, testToken(7), &.{ a, b, session("aaaaaa", .{ .finished = ago(0) }, .{ .label = "A" }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb" });
    try std.testing.expect(state.find("aaaaaa".*).?.state == .finished);
}

test "a Session listed twice keeps its later row, whatever the order" {
    const a = session("aaaaaa", .{ .working = ago(10) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(20) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(30) }, .{ .label = "C" });
    // The later duplicate sorts last by row but not by reference.
    var state = try opened(&.{ b, c, a, session("bbbbbb", .{ .finished = ago(0) }, .{ .label = "B" }) });
    defer state.deinit();
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb", "cccccc" });
    try std.testing.expect(state.find("bbbbbb".*).?.state == .finished);
    try std.testing.expectEqualStrings("C", state.find("cccccc".*).?.label.?.slice());
    for (0..3) |_| {
        if (std.mem.eql(u8, &state.selected.?, "cccccc")) break;
        _ = try press(&state, .{}, .next);
    }
    try expectSelected(&state, "cccccc");
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{.{ .stop = "cccccc".* }}, try press(&state, .{}, .stop));

    // One full listing that delivers the same page twice.
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
    // Nothing falls due while the first listing is in flight.
    try std.testing.expectEqual(@as(?u64, null), state.wakeAt());
    const quota = failedRow("q1q1q1", 60, "provider_usage_limit_reached", test_now_s + 300);
    _ = try respond(&state, .full, testToken(1), &.{ retryRow("r1r1r1", "provider_temporary_http_429", 12), quota });
    // The next listing comes first; while it is in flight, the retry falling
    // due, then the quota reset.
    try std.testing.expectEqual(@as(?u64, start + list_interval_ms), state.wakeAt());
    _ = try step(&state, .{ .tick = start + list_interval_ms });
    try std.testing.expectEqual(@as(?u64, start + 12_000), state.wakeAt());
    _ = try step(&state, .{ .list = .failed });
    _ = try step(&state, .{ .tick = start + 12_000 });
    try std.testing.expect(state.find("r1r1r1".*).?.state == .pending);
    // Falling due changed the row, so its mark's pulse ends next, then the
    // quota resets.
    try std.testing.expectEqual(@as(?u64, start + 12_000 + pulse_window_ms), state.wakeAt());
    _ = try step(&state, .{ .tick = start + 12_000 + pulse_window_ms });
    try std.testing.expectEqual(@as(?u64, (test_now_s + 300) * 1000), state.wakeAt());
    _ = try respond(&state, .full, testToken(2), &.{failedRow("q1q1q1", 60, "provider_usage_limit_reached", std.math.maxInt(i64))});
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
    // A Host that stops answering fades the rows and says since when.
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 3 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectScreenLine(&state, 1, " Host stopped 0s ago. Run rui host start.");
    try expectScreenLine(&state, 2, " Host not responding. Last update 1s ago.");
    var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(7, 2).?);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 1, " Running. 20 Sessions. 2 failed.");
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
    try std.testing.expect(std.mem.indexOf(u8, text, "  ○ Audit permission paths                           Starting                0s\n") != null);
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
    return band(state.rows.items, state.now_ms, login_at);
}

test "the band derives provider trouble from rows, in priority order" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Done" });
    // Sign-in: an authentication failure newer than the newest completion.
    for (codex_credential_policy.login_codes) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
    try std.testing.expect(signInCode("provider_refresh_token_expired") and signInCode("provider_http_401") and signInCode("provider_authentication_failed"));
    try std.testing.expect(!signInCode("provider_authentication_backend_failed"));
    // A later completion clears it; a login in this terminal hides it until a newer failure.
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ session("ffffff", .{ .finished = ago(30) }, .{}), failedRow("aaaaaa", 60, "provider_http_401", null) }, null));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_http_401", null) }, test_now_s - 30));
    try std.testing.expectEqual(Band{ .trouble = .sign_in }, (try bandOf(&.{ done, failedRow("aaaaaa", 10, "provider_http_401", null) }, test_now_s - 30)).?);
    // Quota: shown with its reset time until that time passes.
    try std.testing.expectEqual(Band{ .trouble = .quota, .resets_at = test_now_s + 1200 }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_usage_limit_reached", test_now_s + 1200) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_insufficient_quota", null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_usage_not_included", test_now_s) }, null));
    // Rate limit: while any row retries for a 429.
    try std.testing.expectEqual(Band{ .trouble = .rate_limit, .sessions = 2 }, (try bandOf(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20), retryRow("cccccc", "provider_temporary_error", 20) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{retryRow("aaaaaa", "provider_temporary_error", 10)}, null));
    // A retry already due is pending, not retrying.
    var state = try opened(&.{retryRow("aaaaaa", "provider_temporary_http_429", 10)});
    defer state.deinit();
    try std.testing.expectEqual(@as(?Band, null), band(state.rows.items, (test_now_s + 10) * 1000, null));
    // Priority: sign-in, then quota, then rate limit.
    try std.testing.expectEqual(Trouble.sign_in, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_usage_limit_reached", null), failedRow("bbbbbb", 90, "provider_http_401", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
    try std.testing.expectEqual(Trouble.quota, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_usage_limit_reached", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
}

/// Renders `state` at 80x24 and 200x60 and compares both screens.
/// Renders `state` at 80x24 and 200x60 and compares both screens, and the
/// 80x24 screen's styles.
fn expectScreens(state: *const State, caps: Caps, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    try expectScreen(state, 80, 24, caps, small);
    try expectStyles(state, 80, 24, caps, small_styles);
    try expectScreen(state, 200, 60, caps, large);
}

/// One letter per cell: `.` unstyled; `s`trong, `i`nk, `n`ormal, `q`uiet,
/// `m`ark, ru`l`e, `a`ttention, `f`ailure or `b`and colour; `r` selected or
/// reversed. Capitals are bold.
fn expectStyles(state: *const State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    var screen = try render(std.testing.allocator, state, .{}, width, height, caps, 0);
    defer screen.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (screen.lines) |line| {
        var cells: [512]u8 = @splat('.');
        var end: usize = 0;
        for (line) |span| {
            const letter: u8 = if (span.style.reverse or span.style.background == .selection) 'r' else switch (span.style.colour) {
                .strong => 's',
                .ink => 'i',
                .normal => 'n',
                .quiet => 'q',
                .mark => 'm',
                .rule => 'l',
                .attention => 'a',
                .failure => 'f',
                .on_band => 'b',
            };
            @memset(cells[span.column..][0..span.cells], if (span.style.bold) std.ascii.toUpper(letter) else letter);
            end = @max(end, span.column + span.cells);
        }
        try text.writer.print("{s}\n", .{cells[0..end]});
    }
    try std.testing.expectEqualStrings(expected, text.written());
}

fn expectBand(rows: []const Listed, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    var state = try opened(rows);
    defer state.deinit();
    try expectScreens(&state, .{}, small, small_styles, large);
    // The band spans the line, in its colour or, without colour, reversed.
    for ([_]Caps{ .{}, .{ .depth = .none } }, [_]Style{ .{ .colour = .on_band, .background = .band, .bold = true }, .{ .bold = true, .reverse = true } }) |caps, style| {
        var screen = try render(std.testing.allocator, &state, .{}, 80, 24, caps, 0);
        defer screen.deinit();
        try std.testing.expectEqual(style, screen.styleAt(1, 0).?);
        try std.testing.expectEqual(style, screen.styleAt(1, 79).?);
    }
}

test "a quota reset far in the future still draws its band" {
    var state = try opened(&.{failedRow("q1q1q1", 60, "provider_usage_limit_reached", 100_000_000_000_000_000)});
    defer state.deinit();
    try expectScreenLine(&state, 1, " Quota used up. Resets in 999d.");
}

test "render draws each band" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Summarize the CI failures" });
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_refresh_token_expired", null) },
        \\ रुई rui  ~/code/rui
        \\ Sign-in expired. Run rui auth login codex.
        \\
        \\
        \\ Finished
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed
        \\  × Ask the model                                    failed                  1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIIII
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.IIIIIIIIIIIIIIIII
        \\..f.qqqqqqqqqqqqq....................................ffffff..................qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Sign-in expired. Run rui auth login codex.
        \\
        \\
        \\ Finished
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed
        \\  × Ask the model                                                                                                                                    failed                                          1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    );
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_usage_limit_reached", test_now_s + 20 * 60) },
        \\ रुई rui  ~/code/rui
        \\ Quota used up. Resets in 20m.
        \\
        \\
        \\ Finished
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed
        \\  × Ask the model                                    failed                  1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIIII
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.IIIIIIIIIIIIIIIII
        \\..f.qqqqqqqqqqqqq....................................ffffff..................qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Quota used up. Resets in 20m.
        \\
        \\
        \\ Finished
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed
        \\  × Ask the model                                                                                                                                    failed                                          1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    );
    try expectBand(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20) },
        \\ रुई rui  ~/code/rui
        \\ Rate limited. 2 Sessions will retry.
        \\
        \\
        \\ Working
        \\  ● Ask the model again                      Rate limited · retry 1 in 10s   5s
        \\  ● Ask the model again                      Rate limited · retry 1 in 20s   5s
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIII
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..a.iiiiiiiiiiiiiiiiiii......................aaaaaaaaaaaaaaaaaaaaaaaaaaaaa...qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Rate limited. 2 Sessions will retry.
        \\
        \\
        \\ Working
        \\  ● Ask the model again                                                                                                                              Rate limited · retry 1 in 10s                   5s
        \\  ● Ask the model again                                                                                                                              Rate limited · retry 1 in 20s                   5s
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    );
}

test "render draws an empty Store" {
    var state = try opened(&.{});
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ रुई rui  ~/code/rui
        \\ No Sessions yet. Type a task below.
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ No Sessions yet. Type a task below.
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\
        \\
    );
}

test "render draws twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ रुई rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours
        \\  ● Fix the flaky resize test                        Waiting                40s
        \\  ○ Review PR 412                                    Needs approval          3m
        \\  ✓ h8q2mz                                           finished               12m
        \\
        \\ Working
        \\  ○ Trace Host shutdown order                        Starting                5s
        \\  ● List unused build steps                          Stopping…               8s
        \\  ● Audit permission paths                 Provider error · retry 2 in 12s  30s
        \\  ● Find why store tests fail                        Run the logic tests     1m
        \\  ● f6g7h8                             ~/code/other  Waiting                 1m
        \\  ● Profile the curl send queue                      Waiting                 2m
        \\
        \\ Idle
        \\  ○ Check macOS socket cleanup                                               2h
        \\
        \\ Finished
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.SSSSSSSS.nnnnnnnnnnnnnnnnnnnnnn
        \\
        \\
        \\.IIIII
        \\.rrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..a.SSSSSSSSSSSSS....................................aaaaaaaaaaaaaa..........qq
        \\..m.SSSSSS...........................................nnnnnnnn...............qqq
        \\
        \\.IIIIIII
        \\..n.iiiiiiiiiiiiiiiiiiiiiiiii........................nnnnnnnn................qq
        \\..q.iiiiiiiiiiiiiiiiiiiiiii..........................qqqqqqqqq...............qq
        \\..a.iiiiiiiiiiiiiiiiiiiiii.................aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..qqq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiii........................nnnnnnnnnnnnnnnnnnn.....qq
        \\..i.qqqqqq.............................nnnnnnnnnnnn..nnnnnnn.................qq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiiiii......................nnnnnnn.................qq
        \\
        \\.IIII
        \\..n.iiiiiiiiiiiiiiiiiiiiiiiiii...............................................qq
        \\
        \\.IIIIIIII
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours
        \\  ● Fix the flaky resize test                                                                                                                        Waiting                                        40s
        \\  ○ Review PR 412                                                                                                                                    Needs approval                                  3m
        \\  ✓ h8q2mz                                                                                                                                           finished                                       12m
        \\
        \\ Working
        \\  ○ Trace Host shutdown order                                                                                                                        Starting                                        5s
        \\  ● List unused build steps                                                                                                                          Stopping…                                       8s
        \\  ● Audit permission paths                                                                                                                           Provider error · retry 2 in 12s                30s
        \\  ● Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  ● f6g7h8                                                                                                                             ~/code/other  Waiting                                         1m
        \\  ● Profile the curl send queue                                                                                                                      Waiting                                         2m
        \\
        \\ Idle
        \\  ○ Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished
        \\  ✓ Explain provider output parsing                                                                                                                                                                 20m
        \\  ✓ Find the commit that broke WAL                                                                                                                                                                  45m
        \\  ✓ p3q4r5                                                                                                                                                                                           1h
        \\  ✓ Summarize the build cache study                                                                                                                                                                  3h
        \\  ✓ Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed
        \\  × Bisect the WAL regression                                                                                                                        failed · for "Fix the flaky resize test"       15m
        \\  ■ Rename the session tables                                                                                                                        stopped · for zzzzzz                           30m
        \\  × Retry the flaky upload                                                                                                                           failed                                         50m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    );
}

test "render draws ASCII without colour" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "résumé the naïve café ☕ notes" } });
    const caps: Caps = .{ .unicode = false, .depth = .none };
    try expectScreens(&state, caps,
        \\ rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours
        \\  * Fix the flaky resize test                        Waiting                40s
        \\  o Review PR 412                                    Needs approval          3m
        \\  + r?sum? the na?ve caf? ? notes                    finished               12m
        \\
        \\ Working
        \\  o Trace Host shutdown order                        Starting                5s
        \\  * List unused build steps                          Stopping.               8s
        \\  * Audit permission paths                 Provider error - retry 2 in 12s  30s
        \\  * Find why store tests fail                        Run the logic tests     1m
        \\  * f6g7h8                             ~/code/other  Waiting                 1m
        \\  * Profile the curl send queue                      Waiting                 2m
        \\
        \\ Idle
        \\  o Check macOS socket cleanup                                               2h
        \\
        \\ Finished
        \\ ------------------------------------------------------------------------------
        \\ > Type a task to start a Session
        \\ ^v select - enter open - ctrl+x stop
        \\
    ,
        \\.NNN..nnnnnnnnnn
        \\.NNNNNNNN.nnnnnnnnnnnnnnnnnnnnnn
        \\
        \\
        \\.NNNNN
        \\rrrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..n.NNNNNNNNNNNNN....................................nnnnnnnnnnnnnn..........nn
        \\..n.NNNNNNNNNNNNNNNNNNNNNNNNNNNNN....................nnnnnnnn...............nnn
        \\
        \\.NNNNNNN
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn........................nnnnnnnn................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnn..........................nnnnnnnnn...............nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnn.................nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn..nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn........................nnnnnnnnnnnnnnnnnnn.....nn
        \\..n.nnnnnn.............................nnnnnnnnnnnn..nnnnnnn.................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnn......................nnnnnnn.................nn
        \\
        \\.NNNN
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnn...............................................nn
        \\
        \\.NNNNNNNN
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
    ,
        \\ rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours
        \\  * Fix the flaky resize test                                                                                                                        Waiting                                        40s
        \\  o Review PR 412                                                                                                                                    Needs approval                                  3m
        \\  + r?sum? the na?ve caf? ? notes                                                                                                                    finished                                       12m
        \\
        \\ Working
        \\  o Trace Host shutdown order                                                                                                                        Starting                                        5s
        \\  * List unused build steps                                                                                                                          Stopping.                                       8s
        \\  * Audit permission paths                                                                                                                           Provider error - retry 2 in 12s                30s
        \\  * Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  * f6g7h8                                                                                                                             ~/code/other  Waiting                                         1m
        \\  * Profile the curl send queue                                                                                                                      Waiting                                         2m
        \\
        \\ Idle
        \\  o Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished
        \\  + Explain provider output parsing                                                                                                                                                                 20m
        \\  + Find the commit that broke WAL                                                                                                                                                                  45m
        \\  + p3q4r5                                                                                                                                                                                           1h
        \\  + Summarize the build cache study                                                                                                                                                                  3h
        \\  + Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed
        \\  x Bisect the WAL regression                                                                                                                        failed - for "Fix the flaky resize test"       15m
        \\  # Rename the session tables                                                                                                                        stopped - for zzzzzz                           30m
        \\  x Retry the flaky upload                                                                                                                           failed                                         50m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        \\ > Type a task to start a Session
        \\ ^v select - enter open - ctrl+x stop
        \\
    );
    var screen = try render(std.testing.allocator, &state, .{}, 200, 60, caps, 0);
    defer screen.deinit();
    for (screen.lines) |line| for (line) |span| {
        try std.testing.expectEqual(Colour.normal, span.style.colour);
        for (span.text) |byte| try std.testing.expect(byte < 0x80);
    };
    // The selection is reverse video across the whole line, as before the
    // painted skins.
    for ([_]usize{ 0, 1, 199 }) |column| try std.testing.expect(screen.styleAt(5, column).?.reverse);
}

test "render fits any screen size" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_][2]u16{ .{ 0, 0 }, .{ 8, 2 }, .{ 20, 5 }, .{ 40, 10 }, .{ 119, 30 }, .{ 2048, 24 }, .{ 4096, 6 } }) |size| {
        var screen = try render(std.testing.allocator, &state, .{}, size[0], size[1], .{}, 0);
        defer screen.deinit();
        try std.testing.expectEqual(@as(usize, size[1]), screen.lines.len);
        for (screen.lines) |line| for (line) |span| try std.testing.expect(span.column + span.cells <= size[0]);
        const text = try screenText(&state, size[0], size[1], .{});
        std.testing.allocator.free(text);
    }
}

test "the composer needs six rows and six columns, and shows nothing smaller" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (1..9) |w| for (1..9) |h| {
        const width: u16 = @intCast(w);
        const height: u16 = @intCast(h);
        var screen = try render(std.testing.allocator, &state, .{ .bytes = "draft", .cursor = 5 }, width, height, .{}, 0);
        defer screen.deinit();
        const fits = width >= 6 and height >= 6;
        try std.testing.expectEqual(fits, screen.cursor != null);
        if (screen.cursor) |cursor| {
            try std.testing.expectEqual(height - 2, cursor.row);
            try std.testing.expect(cursor.column < width);
        }
    };
}

test "a full-capacity draft of spaces keeps the composer's caret on screen" {
    var state = try opened(&mixed);
    defer state.deinit();
    const spaces: [65536]u8 = @splat(' ');
    var screen = try render(std.testing.allocator, &state, .{ .bytes = &spaces, .cursor = spaces.len }, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(@as(?Screen.Cursor, .{ .row = 22, .column = 3 }), screen.cursor);
}

fn repeated(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime {
        var bytes: [text.len * count]u8 = undefined;
        for (0..count) |at| @memcpy(bytes[at * text.len ..][0..text.len], text);
        const result = bytes;
        return &result;
    }
}

test "every line fits the screen as the terminal measures it" {
    var draft: Draft = .{};
    const rockets = comptime repeated("🚀", 50);
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(1) }, .{ .label = rockets[0..max_label_bytes] }),
        session("r4t9vw", .{ .idle = ago(60) }, .{ .label = "修复存储测试在第二次运行时失败的原因并说明哪些是新问题", .workspace = "/home/d/代码/存储" }),
        session("h8q2mz", .{ .finished = ago(90) }, .{ .label = comptime repeated("👨‍👩‍👧‍👦", 4) }),
        session("m3n8pd", .{ .failed = .{ .since = test_now_s - 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = comptime repeated("Cafe\u{301} ", 14) }),
    });
    defer state.deinit();
    draft = try typeText(&state, rockets);
    for ([_]Caps{ .{ .width = .unicode }, .{ .width = .wcwidth }, .{ .unicode = false } }) |caps| for ([_]u16{ 80, 41, 24 }) |width| {
        var screen = try render(std.testing.allocator, &state, draft, width, 24, caps, 0);
        defer screen.deinit();
        for (screen.lines) |line| for (line) |span| try std.testing.expectEqual(gwidth.gwidth(span.text, caps.width), span.cells);
        const text = try screenText(&state, width, 24, caps);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, caps.width) <= width);
    };
}

test "untrusted text cannot reach the terminal as control bytes" {
    // Older than a pulse, so the mark is steady.
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(5) }, .{ .label = "Bell\x07 and \x1b[31mred" })});
    defer state.deinit();
    try expectScreenLine(&state, 5, "  ● Bell? and ?[31mred                               Waiting                 5s");
}

test "only the finished and the failed or stopped groups fold" {
    var rows: [8]Listed = undefined;
    for (&rows, 0..) |*row, n| row.* = session(&[6]u8{ 'i', 'i', 'i', 'i', 'i', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n * 60) }, .{ .label = "Wait for review" });
    var state = try opened(&rows);
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, text, "○ Wait for review"));
    try std.testing.expect(std.mem.indexOf(u8, text, " more") == null);
}

test "your Sessions keep a bright title once they end" {
    var state = try opened(&.{ session("k7m2qx", .{ .finished = ago(60) }, .{ .label = "Fix it", .yours = true }), session("r4t9vw", .{ .finished = ago(90) }, .{ .label = "Map it" }) });
    defer state.deinit();
    state.selected = null;
    var screen = try render(std.testing.allocator, &state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .strong, .bold = true }, screen.styleAt(5, 4).?);
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(8, 4).?);
}

test "every role has an entry in both skins, and its 256-colour entry is the nearest" {
    for (std.enums.values(Skin)) |skin| {
        const palette = palettes.get(skin);
        for (std.enums.values(Colour)) |role| {
            const index = indexed.get(skin).colours.get(role);
            try std.testing.expect(index >= 16);
            try std.testing.expectEqual(nearestIndex(palette.colours.get(role)), index);
        }
        for (std.enums.values(Background)) |role| try std.testing.expectEqual(nearestIndex(palette.backgrounds.get(role)), indexed.get(skin).backgrounds.get(role));
    }
    try std.testing.expectEqual(@as(u8, 16), nearestIndex(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 231), nearestIndex(.{ 255, 255, 255 }));
    try std.testing.expectEqual(@as(u8, 214), nearestIndex(hex("#f2c200")));
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
    // Mid grey sits on the line; green weighs most.
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 128, 128, 128 } }).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 127, 127, 127 } }).skin());
    try std.testing.expectEqual(Skin.day, (Caps{ .background = .{ 0, 200, 0 } }).skin());
    try std.testing.expectEqual(Skin.night, (Caps{ .background = .{ 0, 0, 255 } }).skin());
}

/// A terminal cell as a frame leaves it.
const Cell = struct { fg: Ink = .default, bg: Ink = .default, bold: bool = false, reverse: bool = false, written: bool = false };
const Ink = union(enum) { default, index: u8, rgb: Rgb };

/// Plays a frame onto `cells` as a terminal with background colour erase
/// does: cursor moves, line erases, SGR and text.
fn playFrame(bytes: []const u8, cells: []Cell, width: usize, method: gwidth.Method) !void {
    var row: usize = 0;
    var column: usize = 0;
    var pen: Cell = .{};
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes[at] == 0x1b) {
            try std.testing.expectEqual(@as(u8, '['), bytes[at + 1]);
            const start = at + 2;
            var end = start;
            while (bytes[end] < 0x40 or bytes[end] > 0x7e) end += 1;
            const parameters = bytes[start..end];
            at = end + 1;
            switch (bytes[end]) {
                'H' => {
                    var parts = std.mem.splitScalar(u8, parameters, ';');
                    row = try std.fmt.parseUnsigned(usize, parts.next().?, 10) - 1;
                    column = try std.fmt.parseUnsigned(usize, parts.next().?, 10) - 1;
                },
                'K' => {
                    try std.testing.expectEqualStrings("2", parameters);
                    for (cells[row * width ..][0..width]) |*cell| cell.* = .{ .bg = pen.bg };
                },
                'm' => {
                    var parts = std.mem.splitScalar(u8, parameters, ';');
                    while (parts.next()) |part| {
                        const code = try std.fmt.parseUnsigned(u8, part, 10);
                        switch (code) {
                            0 => pen = .{},
                            1 => pen.bold = true,
                            7 => pen.reverse = true,
                            38, 48 => {
                                const ink: Ink = switch (try std.fmt.parseUnsigned(u8, parts.next().?, 10)) {
                                    5 => .{ .index = try std.fmt.parseUnsigned(u8, parts.next().?, 10) },
                                    2 => .{ .rgb = .{ try std.fmt.parseUnsigned(u8, parts.next().?, 10), try std.fmt.parseUnsigned(u8, parts.next().?, 10), try std.fmt.parseUnsigned(u8, parts.next().?, 10) } },
                                    else => return error.TestUnexpectedResult,
                                };
                                if (code == 38) pen.fg = ink else pen.bg = ink;
                            },
                            else => return error.TestUnexpectedResult,
                        }
                    }
                },
                'h', 'l' => {},
                else => return error.TestUnexpectedResult,
            }
            continue;
        }
        var clusters = unicode.graphemeIterator(bytes[at..]);
        const len = clusters.next().?.len;
        const cluster = bytes[at..][0..len];
        const cells_wide = if (cluster[0] < 0x80) 1 else gwidth.gwidth(cluster, method);
        for (0..cells_wide) |offset| {
            var cell = pen;
            cell.written = true;
            cells[row * width + column + offset] = cell;
        }
        column += cells_wide;
        at += len;
    }
    // Whatever draws next starts from the terminal's own colours.
    try std.testing.expect(std.mem.endsWith(u8, bytes[0 .. std.mem.lastIndexOf(u8, bytes, "\x1b[0m").? + 4], "\x1b[0m"));
    try std.testing.expectEqual(Cell{}, Cell{ .fg = pen.fg, .bg = pen.bg, .bold = pen.bold, .reverse = pen.reverse });
}

fn expectPainted(state: *const State, width: u16, height: u16, caps: Caps) !void {
    var screen = try render(std.testing.allocator, state, .{}, width, height, caps, 0);
    defer screen.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try screen.writeFrame(null, &bytes.writer);
    const cells = try std.testing.allocator.alloc(Cell, @as(usize, width) * height);
    defer std.testing.allocator.free(cells);
    @memset(cells, .{});
    try playFrame(bytes.written(), cells, width, caps.width);
    const skin = caps.skin();
    const ink = struct {
        fn of(depth: Caps.Depth, palette_skin: Skin, role: union(enum) { colour: Colour, background: Background }) Ink {
            return switch (depth) {
                .none => .default,
                .indexed => .{ .index = switch (role) {
                    .colour => |colour| indexed.get(palette_skin).colours.get(colour),
                    .background => |background| indexed.get(palette_skin).backgrounds.get(background),
                } },
                .direct => .{ .rgb = switch (role) {
                    .colour => |colour| palettes.get(palette_skin).colours.get(colour),
                    .background => |background| palettes.get(palette_skin).backgrounds.get(background),
                } },
            };
        }
    };
    for (0..height) |row| for (0..width) |column| {
        const cell = cells[row * width + column];
        const style = screen.styleAt(row, column) orelse Style{};
        // Every cell has the ground the screen gives it, empty rows included.
        try std.testing.expectEqual(ink.of(caps.depth, skin, .{ .background = style.background }), cell.bg);
        if (cell.written) {
            try std.testing.expectEqual(ink.of(caps.depth, skin, .{ .colour = style.colour }), cell.fg);
            try std.testing.expectEqual(style.bold, cell.bold);
            try std.testing.expectEqual(style.reverse, cell.reverse);
        }
    };
    if (caps.depth == .none) {
        try std.testing.expect(std.mem.indexOf(u8, bytes.written(), ";38;") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes.written(), ";48;") == null);
    }
}

test "a colour frame places every span, and restyles only where the style changes" {
    const plain: Style = .{ .colour = .normal };
    const line = [_]Span{
        .{ .column = 1, .cells = 2, .text = "ab", .style = plain },
        .{ .column = 3, .cells = 2, .text = "cd", .style = plain },
        .{ .column = 5, .cells = 1, .text = "e", .style = .{ .colour = .ink } },
        .{ .column = 8, .cells = 1, .text = "f", .style = .{ .colour = .ink } },
    };
    const lines = [_][]const Span{&line};
    var screen: Screen = .{ .arena = .init(std.testing.allocator), .width = 10, .lines = &lines, .depth = .indexed };
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try screen.writeFrame(null, &out.writer);
    const night = indexed.get(.night);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\x1b[?2026h\x1b[?25l\x1b[1;1H\x1b[0;48;5;{d}m\x1b[2K" ++
        "\x1b[1;2H\x1b[0;38;5;{d};48;5;{d}mab\x1b[1;4Hcd" ++
        "\x1b[1;6H\x1b[0;38;5;{d};48;5;{d}me" ++
        "\x1b[1;9Hf\x1b[0m\x1b[?2026l", .{
        night.backgrounds.get(.ground),
        night.colours.get(.normal),
        night.backgrounds.get(.ground),
        night.colours.get(.ink),
        night.backgrounds.get(.ground),
    });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "each skin paints every cell of the screen at each colour depth" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 7500, .slots = 100, .slots_in_use = 3 } });
    for ([_]?Rgb{ null, .{ 0x12, 0x18, 0x33 }, .{ 0xf3, 0xee, 0xe2 } }) |background| {
        for ([_]Caps.Depth{ .direct, .indexed, .none }) |depth| {
            for ([_][2]u16{ .{ 80, 24 }, .{ 200, 60 } }) |size| try expectPainted(&state, size[0], size[1], .{ .depth = depth, .background = background });
        }
    }
    // The band and the faded rows paint too.
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    for ([_]Caps.Depth{ .direct, .indexed, .none }) |depth| try expectPainted(&state, 80, 24, .{ .depth = depth });
}

test "the top reads as the mock: wordmark, headline, health, and no counts" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 7500, .slots = 100, .slots_in_use = 3 } });
    try expectScreenLine(&state, 0, " रुई rui  ~/code/rui");
    try expectScreenLine(&state, 1, " Running. 20 Sessions. 2 failed.");
    try expectScreenLine(&state, 2, " Host up 2h05m   slots 3/100");
    // The rows show what the counts said, so no line counts them.
    try expectScreenLine(&state, 3, "");
    try expectScreenLine(&state, 4, " Yours");
    // The wordmark and the headline's opening are the only bold on the top.
    try expectStyle(&state, 0, 1, .{ .colour = .strong, .background = .bar, .bold = true });
    try expectStyle(&state, 0, 5, .{ .colour = .strong, .background = .bar, .bold = true });
    try expectStyle(&state, 0, 79, .{ .background = .bar });
    try expectStyle(&state, 1, 1, .{ .colour = .strong, .bold = true });
    try expectStyle(&state, 1, 10, .{});
    // ASCII has rui alone.
    const text = try screenText(&state, 80, 24, .{ .unicode = false });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, " rui  ~/code/rui\n Running. 20 Sessions. 2 failed.\n Host up 2h05m   slots 3/100\n\n Yours\n"));
}

test "the headline says whether anything works, and counts failures" {
    const yours_done = session("k7m2qx", .{ .finished = ago(5 * 60) }, .{ .label = "Fix it", .yours = true });
    const other_done = session("h8q2mz", .{ .finished = ago(9 * 60) }, .{ .label = "Map it", .yours = true });
    const working = session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Profile it" });
    const failed = failedRow("aaaaaa", 60, "provider_output_invalid", null);
    const approval = session("r4t9vw", .{ .approval = ago(3 * 60) }, .{ .label = "Review PR 412" });
    for ([_]struct { rows: []const Listed, line: []const u8 }{
        .{ .rows = &.{ working, yours_done }, .line = " Running. 2 Sessions. Nothing needs you." },
        .{ .rows = &.{ approval, yours_done }, .line = " Running. 2 Sessions." },
        .{ .rows = &.{session("r4t9vw", .{ .working = ago(3) }, .{ .label = "Review it", .yours = true })}, .line = " Running. 1 Session. Nothing needs you." },
        .{ .rows = &.{ working, failed }, .line = " Running. 2 Sessions. 1 failed." },
        .{ .rows = &.{ yours_done, other_done }, .line = " Quiet for 5m. All 2 of your conversations have answered." },
        .{ .rows = &.{yours_done}, .line = " Quiet for 5m. Your conversation has answered." },
        .{ .rows = &.{ yours_done, failed }, .line = " Quiet for 1m. 1 failed." },
        .{ .rows = &.{session("g7h8j9", .{ .idle = ago(7200) }, .{ .label = "Wait" })}, .line = " Quiet for 2h00m. Nothing is working or waiting." },
        .{ .rows = &.{}, .line = " No Sessions yet. Type a task below." },
    }) |case| {
        var state = try opened(case.rows);
        defer state.deinit();
        try expectScreenLine(&state, 1, case.line);
        // The sentence reads the State the listing left.
        try std.testing.expectEqual(std.mem.startsWith(u8, case.line, " Running."), state.summary.working);
    }
}

test "since you looked: a failure or a Host restart shows until the next keypress" {
    var state = try opened(&mixed);
    defer state.deinit();
    const host: Host = .{ .started_at = test_now_s - 600, .slots = 100, .slots_in_use = 3 };
    _ = try step(&state, .{ .host = host });
    try std.testing.expectEqual(@as(?u64, test_now_s * 1000), state.looked_ms);
    try std.testing.expectEqual(@as(?News, null), sinceLooked(&state));
    // Finishes alone are no news.
    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("b2c3d4", .{ .finished = .{ .since = test_now_s + 60 } }, .{ .label = "Profile the curl send queue" })});
    try std.testing.expectEqual(@as(?News, null), sinceLooked(&state));
    try expectScreenLine(&state, 3, "");
    // A failure is news, with the finishes beside it.
    _ = try step(&state, .{ .tick = (test_now_s + 12 * 60) * 1000 });
    _ = try respond(&state, .changed, testToken(3), &.{session("a1b2c3", .{ .failed = .{ .since = test_now_s + 12 * 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Find why store tests fail" })});
    try std.testing.expectEqual(@as(?News, .{ .seconds = 12 * 60, .finished = 1, .failed = 1, .restarts = 0 }), sinceLooked(&state));
    try expectScreenLine(&state, 3, " Since you looked 12m ago: 1 finished, 1 failed.");
    try expectStyle(&state, 3, 1, .{ .colour = .ink });
    // A keypress clears it. A failure in the keypress's own second stays
    // until the next one, since states keep whole seconds.
    _ = try step(&state, .{ .looked = (test_now_s + 12 * 60) * 1000 + 500 });
    try std.testing.expect(sinceLooked(&state) != null);
    _ = try step(&state, .{ .looked = (test_now_s + 12 * 60 + 1) * 1000 });
    _ = try press(&state, .{}, .next);
    try std.testing.expectEqual(@as(?News, null), sinceLooked(&state));
    // A changed Host start is a restart, seen across the Host's silence.
    _ = try step(&state, .{ .host = null });
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s + 13 * 60, .slots = 100, .slots_in_use = 0 } });
    try std.testing.expectEqual(@as(u32, 1), state.restarts);
    _ = try step(&state, .{ .tick = (test_now_s + 14 * 60) * 1000 });
    try expectScreenLine(&state, 3, " Since you looked 1m ago: 0 finished, 0 failed, Host restarted.");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s + 14 * 60, .slots = 100, .slots_in_use = 0 } });
    try expectScreenLine(&state, 3, " Since you looked 1m ago: 0 finished, 0 failed, Host restarted 2 times.");
    _ = try step(&state, .{ .looked = (test_now_s + 14 * 60) * 1000 });
    try std.testing.expectEqual(@as(u32, 0), state.restarts);
    try std.testing.expectEqual(@as(?News, null), sinceLooked(&state));
}

test "the Host-stopped band comes first, over the provider bands and the faded rows" {
    var state = try opened(&.{ failedRow("aaaaaa", 60, "provider_refresh_token_expired", null), session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Profile it" }) });
    defer state.deinit();
    try expectScreenLine(&state, 1, " Sign-in expired. Run rui auth login codex.");
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    try std.testing.expectEqual(@as(?u64, (test_now_s + 1) * 1000), state.unreachable_since_ms);
    _ = try step(&state, .{ .tick = (test_now_s + 181) * 1000 });
    try expectScreenLine(&state, 1, " Host stopped 3m ago. Run rui host start.");
    try expectScreenLine(&state, 2, " Sign-in expired. Run rui auth login codex.");
    try expectStyle(&state, 1, 0, .{ .colour = .on_band, .background = .band, .bold = true });
    // No headline sentence claims calm under a band; the rows fade.
    try expectScreenLine(&state, 3, " Host not responding. Last update 3m ago.");
    try expectStyle(&state, 3, 1, .{ .colour = .failure });
    try expectStyle(&state, 9, 4, .{ .colour = .quiet });
}
