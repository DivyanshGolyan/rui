//! Session overview: every decision behind bare `rui`, over values.
//!
//! `step` applies one event (a key, a tick, a list page, a first line, a
//! stop or start result) to the overview's `State` and returns the effects
//! its shell runs: list again, read first lines, start, open, stop or exit.
//! `render` turns the state into the screen as styled lines. Neither reads a
//! clock or the Host: time arrives as a tick at `State.wakeAt`, the
//! animation frame as an argument, and the shell branches only on which
//! effect to run. What each
//! work state looks like lives in `rules`, what each key does in `bindings`.
//! The rows are a client view over `session list`; the Host keeps no
//! overview state.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const change_ring = @import("change_ring.zig");
const cli_args = @import("cli_args.zig");
const codex_credential_policy = @import("codex_credential_policy.zig");
const model_capability = @import("model_capability.zig");
const session_work = @import("session_work.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");
const transport_policy = @import("transport_policy.zig");

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
pub const max_line_bytes = 256;
/// The shell reads this much of a first line: one byte more than a row keeps,
/// so a longer line shows that it was cut.
pub const max_line_read_bytes = max_line_bytes + 1;
/// The composer's text, which becomes a new Session's first Message.
pub const max_draft_bytes = 64 * 1024;
/// Rows a folded group shows before its "more" line.
pub const fold_rows = 5;
/// Starts and stops the ledger holds at once.
pub const max_requests = 8;
/// The least time between two list requests.
pub const list_interval_ms = 1000;
/// How long each frame of an active mark's pulse shows.
pub const pulse_interval_ms = 140;
/// A generated request handle, as `rui request recover` takes it.
pub const max_handle_bytes = 36;

pub const Group = enum { yours, working, idle, finished, ended };
pub const Mark = enum { active, waiting, finished, failed, stopped };
/// Presentation roles; the shell maps each to its terminal style.
pub const Colour = enum { normal, quiet, attention, failure, band };

/// What a row adds to its word.
pub const Detail = enum {
    none,
    /// The running Bash call's saved description, in place of the word.
    description,
    /// The seconds until the retry is due.
    due,
    /// The Session that sent the first Message, by Label, else reference.
    starter,
};

/// How one work state looks and what Ctrl-X may do to it.
pub const Rule = struct {
    group: Group,
    mark: Mark,
    colour: Colour,
    word: []const u8,
    /// The group heading already says `word`, so rows under it omit it.
    said_by_group: bool = false,
    detail: Detail = .none,
    /// Ctrl-X may stop a Session in this state.
    stoppable: bool,
    /// The state holds an Attempt in Host custody, which is process-local:
    /// entered before this Host started, it is being recovered.
    held: bool = false,
};

/// The one per-kind table. `step` and `render` read it and switch on no kind.
pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .group = .idle, .mark = .waiting, .colour = .quiet, .word = "idle", .said_by_group = true, .stoppable = false },
    .pending = .{ .group = .working, .mark = .waiting, .colour = .quiet, .word = "pending", .stoppable = true },
    .working = .{ .group = .working, .mark = .active, .colour = .normal, .word = "working", .said_by_group = true, .stoppable = true, .held = true },
    .retrying = .{ .group = .working, .mark = .active, .colour = .attention, .word = "retrying", .detail = .due, .stoppable = true },
    .bash = .{ .group = .working, .mark = .active, .colour = .normal, .word = "Bash", .detail = .description, .stoppable = true, .held = true },
    .approval = .{ .group = .working, .mark = .waiting, .colour = .attention, .word = "needs approval", .stoppable = true },
    .stopping = .{ .group = .working, .mark = .active, .colour = .quiet, .word = "stopping", .stoppable = false },
    .finished = .{ .group = .finished, .mark = .finished, .colour = .quiet, .word = "finished", .said_by_group = true, .stoppable = false },
    .failed = .{ .group = .ended, .mark = .failed, .colour = .failure, .word = "failed", .detail = .starter, .stoppable = false },
    .stopped = .{ .group = .ended, .mark = .stopped, .colour = .normal, .word = "stopped", .detail = .starter, .stoppable = false },
});

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8, word: []const u8 }).init(.{
    .active = .{ .unicode = "●", .ascii = "*", .word = "active" },
    .waiting = .{ .unicode = "○", .ascii = "o", .word = "waiting" },
    .finished = .{ .unicode = "✓", .ascii = "+", .word = "finished" },
    .failed = .{ .unicode = "×", .ascii = "x", .word = "failed" },
    .stopped = .{ .unicode = "■", .ascii = "#", .word = "stopped" },
});

/// An active mark's pulse, one per frame. Frame 0 is its static mark, so a
/// screen that holds still is frame 0.
pub const pulse_frames = [_][]const u8{ marks.get(.active).unicode, "·", "∙", "•" };
/// Headline order: finished last, so a narrow screen cuts the least telling count.
const headline_marks = [_]Mark{ .active, .waiting, .failed, .stopped, .finished };

pub const groups = std.enums.EnumArray(Group, struct { title: []const u8, help: []const u8 = "", folds: bool }).init(.{
    .yours = .{ .title = "Your conversations", .help = "Sessions you or your scripts messaged", .folds = false },
    .working = .{ .title = "Working", .folds = false },
    .idle = .{ .title = "Idle", .folds = false },
    .finished = .{ .title = "Finished", .folds = true },
    .ended = .{ .title = "Failed or stopped", .folds = true },
});

/// A key the shell decoded. Text is typed or pasted UTF-8.
pub const Key = union(enum) { text: []const u8, up, down, home, end, enter, escape, backspace, ctrl_c, ctrl_d, ctrl_x };
pub const Action = enum { insert, previous, next, first, last, enter, escape, erase, exit, end_of_input, stop };

/// The one key table.
pub const bindings = std.enums.EnumArray(std.meta.Tag(Key), Action).init(.{
    .text = .insert,
    .up = .previous,
    .down = .next,
    .home = .first,
    .end = .last,
    .enter = .enter,
    .escape = .escape,
    .backspace = .erase,
    .ctrl_c = .exit,
    .ctrl_d = .end_of_input,
    .ctrl_x = .stop,
});

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
    key: Key,
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
};

pub const Read = struct { reference: Reference, position: u64, admission: u64 };
pub const Reads = struct {
    items: [max_first_line_reads]Read = undefined,
    len: usize = 0,

    pub fn slice(self: *const Reads) []const Read {
        return self.items[0..self.len];
    }
};

/// What the shell does next. `start` borrows the state until its result:
/// the composer stays locked meanwhile.
pub const Effect = union(enum) {
    /// List every Session again through a `protocol_reply.SessionTraversal`
    /// from the last completed listing's token.
    list: ?Token,
    read_first_lines: Reads,
    start: struct { settings: *const StartSettings, text: []const u8 },
    open: Reference,
    stop: Reference,
    exit,
};

/// Each event brings at most one effect today; the shell runs them in order.
pub const Effects = struct {
    items: [1]Effect = undefined,
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
    first: ?First,
    from_person_at: ?u64,
    line: Line = .unread,

    pub fn group(self: *const Row) Group {
        return if (self.from_person_at != null) .yours else rules.get(self.state).group;
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
    counts: std.enums.EnumArray(Mark, u32) = .initFill(0),
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
    draft: [max_draft_bytes]u8 = undefined,
    draft_len: usize = 0,
    settings: StartSettings = .{},
    /// Every start and stop without an answer the overview showed, oldest first.
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,
    /// The person left, so answers wait for `writeDeparture`.
    left: bool = false,
    /// The serving Host's facts, from the latest host-info read.
    host: ?Host = null,

    /// The token of the last completed listing.
    token: ?Token = null,
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

    /// Initializes in place, since the state holds the whole draft. The
    /// caller owns `home` for the state's lifetime.
    pub fn init(self: *State, gpa: Allocator, options: Options) error{OutOfMemory}!void {
        self.* = .{ .gpa = gpa, .home = options.home, .cwd = 0, .login_at = options.login_at };
        errdefer self.deinit();
        self.cwd = try self.intern(options.cwd);
    }

    pub fn deinit(self: *State) void {
        for (self.workspaces.items) |bytes| self.gpa.free(bytes);
        inline for (.{ &self.rows, &self.by_reference, &self.order, &self.workspaces, &self.workspace_order, &self.lines, &self.pending, &self.sort_keys }) |vec| vec.deinit(self.gpa);
    }

    pub fn draftText(self: *const State) []const u8 {
        return self.draft[0..self.draft_len];
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
    /// listing, a retry falling due, or the shown quota reset passing. Null
    /// while nothing falls due before the listing in flight answers. A time
    /// already past means at once. The shell keeps no timer of its own.
    pub fn wakeAt(self: *const State) ?u64 {
        var at: ?u64 = if (self.listing) null else self.next_list_ms;
        for (self.rows.items) |*row| if (row.state == .retrying) {
            at = @min(at orelse row.state.retrying.due_at_ms, row.state.retrying.due_at_ms);
        };
        if (band(self.rows.items, self.now_ms, self.login_at)) |trouble| if (trouble.resets_at) |resets| {
            at = @min(at orelse resets *| 1000, resets *| 1000);
        };
        return at;
    }

    fn pendingCount(self: *const State) usize {
        var count: usize = 0;
        for (self.rows.items) |*row| count += @intFromBool(row.state == .pending);
        return count;
    }

    fn selectedRow(self: *const State) ?*const Row {
        return self.find(self.selected orelse return null);
    }

    /// A start is in flight; the composer is locked until its answer.
    pub fn starting(self: *const State) bool {
        return self.pendingAt(.start, null) != null;
    }

    fn stopping(self: *const State, ref: Reference) bool {
        return self.pendingAt(.stop, ref) != null;
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
            self.say(.attention, "! Wait for earlier requests, or leave to recover unconfirmed ones.", .{});
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
        .key => |key| keyPress(state, key, &effects),
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
                    state.say(.attention, "! Could not stop {s}: {s}", .{ &result.reference, code });
                },
                .unconfirmed => |handle| {
                    state.answer(at, .unknown, handle);
                    state.say(.attention, "! Unconfirmed stop of {s}: rui request recover {s}", .{ &result.reference, handle });
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
                    state.draft_len = 0;
                    state.settings = .{};
                    state.selected = started.reference;
                    state.next_list_ms = 0;
                    effects.add(.{ .open = started.reference });
                },
                .failed => |code| {
                    state.answer(at, .failed, code);
                    state.say(.attention, "! Could not start a Session: {s}", .{code});
                },
                .unconfirmed => |handle| {
                    // The saved request holds the text; recovery, not a
                    // second Enter, finds out whether it started.
                    state.answer(at, .unknown, handle);
                    state.draft_len = 0;
                    state.settings = .{};
                    state.next_list_ms = 0;
                    state.say(.attention, "! Unconfirmed: rui request recover {s}", .{handle});
                },
            }
        },
        .leave => state.left = true,
        .open => |ref| {
            state.selected = ref;
            effects.add(.{ .open = ref });
        },
        .host => |facts| state.host = facts,
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
                .pending => try writer.writeAll("rui: The new Session was not started (cancelled); start it again from the overview.\n"),
                .failed => try writer.print("rui: The new Session was not started ({s}); start it again from the overview.\n", .{text}),
                .unknown => try writer.print("rui: A new Session's start was not confirmed; use rui request recover {s}. Do not start it again.\n", .{text}),
                .done => try writer.print("rui: Session start accepted: {s}.\nMessage request: {s} (rui request inspect {s})\n", .{ &request.session.?, text, text }),
            },
            .stop => switch (request.status) {
                .pending => try writer.print("rui: Stopping {s} was not sent; stop it again from the overview.\n", .{&request.session.?}),
                .failed => try writer.print("rui: Could not stop {s}: {s}\n", .{ &request.session.?, text }),
                .unknown => try writer.print("rui: Stopping {s} was not confirmed; use rui request recover {s}. Do not stop it again.\n", .{ &request.session.?, text }),
                .done => try writer.print("rui: Stopped {s}.\n", .{&request.session.?}),
            },
        }
    }
}

fn tick(state: *State, now_ms: u64, effects: *Effects) error{OutOfMemory}!void {
    state.now_ms = now_ms;
    var changed = false;
    for (state.rows.items) |*row| {
        const next = row.state.asOf(now_ms);
        if (std.meta.activeTag(next) != std.meta.activeTag(row.state)) changed = true;
        row.state = next;
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
    for (page.rows) |listed| state.pending.appendAssumeCapacity(.{
        .reference = listed.reference,
        .workspace = try state.intern(listed.workspace),
        .label = if (listed.label) |text| labelOf(text) else null,
        .state = listed.state.asOf(state.now_ms),
        .first = listed.first,
        .from_person_at = listed.from_person_at,
    });
    const answer = page.answer orelse return;
    try commit(state, answer);
    state.listing = false;
    try readFirstLines(state, effects);
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
                    keepLine(incoming, &state.rows.items[at]);
                    state.rows.items[at] = incoming.*;
                } else try state.rows.append(state.gpa, incoming.*);
            }
            try reindex(state);
        },
        .full => {
            std.mem.swap(Vec(Row), &state.rows, &state.pending);
            try reindex(state);
            // Few rows have a line, so look up the old rows that do.
            for (state.pending.items) |*old| if (old.line != .unread) if (lookup(state.by_reference.items, old.reference)) |at| keepLine(&state.rows.items[at], old);
        },
    }
    state.pending.items.len = 0;
    state.token = answer.since;
    state.listed_at_ms = state.now_ms;
    state.unreachable_since_ms = null;
    try arrange(state);
}

/// What the overview knows of the same first Message's first line, read,
/// unreadable or asked for, still holds.
fn keepLine(incoming: *Row, old: *const Row) void {
    const same = if (incoming.first) |first| if (old.first) |known| first.admission == known.admission else false else false;
    if (same) incoming.line = old.line;
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

/// Rebuilds the screen order, each group's run and the counts, then keeps the
/// selection on a listed, visible row.
fn arrange(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.sort_keys.ensure(state.gpa, rows.len);
    try state.order.ensure(state.gpa, rows.len);
    state.sort_keys.items.len = rows.len;
    state.counts = .initFill(0);
    const latest = std.math.maxInt(u34);
    for (state.sort_keys.items, rows, 0..) |*key, *row, at| {
        state.counts.getPtr(rules.get(row.state).mark).* += 1;
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
    try state.lines.append(state.gpa, firstLineText(bytes));
    row.line = .{ .read = @intCast(state.lines.items.len - 1) };
}

/// The line up to its first line end, trimmed, within `max_line_bytes`.
fn firstLineText(bytes: []const u8) Bounded(max_line_bytes) {
    const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
    const line = std.mem.trim(u8, bytes[0..end], " \t");
    var value: Bounded(max_line_bytes) = .{};
    const ellipsis = "…";
    const kept = if (line.len <= max_line_bytes) line.len else codepointStart(line, max_line_bytes - ellipsis.len);
    @memcpy(value.bytes[0..kept], line[0..kept]);
    value.len = kept;
    if (kept < line.len) {
        @memcpy(value.bytes[kept..][0..ellipsis.len], ellipsis);
        value.len += ellipsis.len;
    }
    return value;
}

/// The start of the code point holding byte `at`, so a cut there keeps whole
/// code points.
fn codepointStart(bytes: []const u8, at: usize) usize {
    var start = at;
    while (start > 0 and start < bytes.len and bytes[start] & 0xc0 == 0x80) start -= 1;
    return start;
}

fn keyPress(state: *State, key: Key, effects: *Effects) void {
    const action = bindings.get(key);
    state.notice = null;
    if (state.prompt) |prompt| {
        state.prompt = null;
        if (action == .stop) return confirmStop(state, prompt.stop, effects);
        // Esc only cancels; any other key cancels and then acts.
        if (action == .escape) return;
    }
    switch (action) {
        .insert => insert(state, key.text),
        .erase => if (!state.starting() and state.draft_len != 0) {
            state.draft_len = codepointStart(state.draftText(), state.draft_len - 1);
        },
        .previous, .next, .first, .last => move(state, action),
        .enter => enter(state, effects),
        .escape => if (!state.starting()) {
            if (state.draft_len != 0) state.draft_len = 0 else state.settings = .{};
        },
        .exit => effects.add(.exit),
        .end_of_input => if (state.draft_len == 0 and !state.starting()) effects.add(.exit),
        .stop => {
            const row = state.selectedRow() orelse return state.say(.quiet, "Select a Session to stop.", .{});
            const rule = rules.get(shownKind(state, row));
            if (rule.stoppable) {
                state.prompt = .{ .stop = row.reference };
            } else state.say(.quiet, "Nothing to stop: {s} is {s}.", .{ &row.reference, rule.word });
        },
    }
}

fn confirmStop(state: *State, ref: Reference, effects: *Effects) void {
    const row = state.find(ref) orelse return;
    const rule = rules.get(shownKind(state, row));
    if (!rule.stoppable) return state.say(.quiet, "Nothing to stop: {s} is {s}.", .{ &ref, rule.word });
    if (state.request(.stop, ref)) effects.add(.{ .stop = ref });
}

/// The kind a row shows: `stopping` while its stop awaits a result.
fn shownKind(state: *const State, row: *const Row) Kind {
    return if (state.stopping(row.reference)) .stopping else row.state;
}

fn insert(state: *State, text: []const u8) void {
    if (state.starting()) return;
    if (text.len > max_draft_bytes - state.draft_len) return state.say(.attention, "! The composer holds at most 64 KiB.", .{});
    @memcpy(state.draft[state.draft_len..][0..text.len], text);
    state.draft_len += text.len;
}

fn enter(state: *State, effects: *Effects) void {
    if (state.starting()) return;
    // As in a conversation, the draft is sent byte for byte; only a blank
    // draft opens the selected row instead.
    const text = state.draftText();
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        state.draft_len = 0;
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
    if (!std.mem.eql(u8, name, "/configure")) return state.say(.attention, "! Unknown command · /configure sets the next Session's settings, /exit leaves", .{});
    if (configure(state, text[name.len..])) state.draft_len = 0;
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
            state.say(.attention, "! --{s} is not a start setting; set it once the Session starts.", .{option.name});
            return false;
        }
    }
    // The Host admits any model name, so the client checks release support,
    // as `session start` does.
    if (parsed.get("model")) |model| if (!model_capability.supportsModel(model)) {
        state.say(.attention, "! Unsupported model {s}; rui session configure --help lists them.", .{model});
        return false;
    };
    var next: StartSettings = .{};
    inline for (start_options, 0..) |name, option| {
        if (parsed.get(name) orelse state.settings.get(option)) |value| next.put(option, value) catch {
            state.say(.attention, "! Start settings hold at most {d} bytes.", .{StartSettings.max_bytes});
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
    .{ .trouble = .rate_limit, .kind = .retrying, .matches = rateLimitCode },
};

/// Failure codes a new `rui auth login` resolves.
const sign_in_codes = codes: {
    var codes: []const []const u8 = &.{"provider_http_401"};
    for (@typeInfo(codex_credential_policy.LoginRequired).error_set.error_names.?) |name| {
        const code = codex_credential_policy.failureCode(@field(anyerror, name));
        for (codes) |known| {
            if (std.mem.eql(u8, known, code)) break;
        } else codes = codes ++ .{code};
    }
    break :codes codes;
};

fn signInCode(code: []const u8) bool {
    for (sign_in_codes) |known| if (std.mem.eql(u8, known, code)) return true;
    return false;
}

fn quotaCode(code: []const u8) bool {
    return transport_policy.Quota.ofFailureCode(code) != null;
}

fn rateLimitCode(code: []const u8) bool {
    return std.mem.eql(u8, code, "provider_temporary_http_429");
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

pub const Caps = struct {
    /// Unicode marks and text; false draws ASCII only, a cell a character.
    unicode: bool = true,
    /// How the terminal measures Unicode text, from its report.
    width: gwidth.Method = .wcwidth,
    /// False under NO_COLOR: no colour, only bold and reverse.
    colour: bool = true,

    pub const Environment = struct {
        lc_all: ?[]const u8 = null,
        lc_ctype: ?[]const u8 = null,
        lang: ?[]const u8 = null,
        no_color: ?[]const u8 = null,
    };

    /// The locale that sets the character set is the first of LC_ALL,
    /// LC_CTYPE and LANG that is set; one that does not name UTF-8 draws
    /// ASCII. With none set, Unicode. A non-empty NO_COLOR turns colour off.
    pub fn of(environment: Environment) Caps {
        const locale = for ([_]?[]const u8{ environment.lc_all, environment.lc_ctype, environment.lang }) |value| {
            if (value) |text| if (text.len != 0) break text;
        } else null;
        const utf8 = if (locale) |text| for (0..text.len) |at| {
            if (std.ascii.startsWithIgnoreCase(text[at..], "utf-8") or std.ascii.startsWithIgnoreCase(text[at..], "utf8")) break true;
        } else false else true;
        return .{ .unicode = utf8, .colour = if (environment.no_color) |text| text.len == 0 else true };
    }
};

/// SGR parameters per colour, the conversation's palette. The band is dark
/// text on yellow.
const sgr = std.enums.EnumArray(Colour, []const u8).init(.{ .normal = "", .quiet = "90", .attention = "33", .failure = "91", .band = "30;43" });

pub const Style = struct {
    colour: Colour = .normal,
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
    /// An active mark it drew changes with the frame: the shell draws the
    /// next one in `pulse_interval_ms`.
    pulses: bool = false,

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
    /// or hidden. Without `shown`, or at another size, every line is cleared
    /// and drawn. Otherwise a line laid out as before writes only the spans
    /// that changed, and any other changed line is cleared and drawn. An
    /// unchanged screen writes nothing.
    pub fn writeFrame(self: *const Screen, shown: ?*const Screen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const before = if (shown) |held| if (held.width == self.width and held.lines.len == self.lines.len) held else null else null;
        if (before) |held| if (self.sameAs(held)) return;
        try writer.writeAll("\x1b[?2026h\x1b[?25l");
        for (self.lines, 1..) |spans, row| {
            const old = if (before) |held| held.lines[row - 1] else null;
            if (old) |was| if (sameSpans(spans, was, .layout)) {
                for (spans, was) |span, prior| if (!sameSpan(span, prior, .text)) try writeSpan(writer, row, span);
                continue;
            };
            try writer.print("\x1b[{d};1H\x1b[2K", .{row});
            for (spans) |span| try writeSpan(writer, row, span);
        }
        if (self.cursor) |at| try writer.print("\x1b[{d};{d}H\x1b[?25h", .{ at.row + 1, at.column + 1 });
        try writer.writeAll("\x1b[?2026l");
    }

    fn sameAs(self: *const Screen, other: *const Screen) bool {
        if (!std.meta.eql(self.cursor, other.cursor)) return false;
        for (self.lines, other.lines) |a, b| if (!sameSpans(a, b, .text)) return false;
        return true;
    }

    const Same = enum { layout, text };

    /// Spans in the same cells, and with `.text` the same style and text too.
    fn sameSpan(a: Span, b: Span, same: Same) bool {
        if (a.column != b.column or a.cells != b.cells) return false;
        return same == .layout or (std.meta.eql(a.style, b.style) and std.mem.eql(u8, a.text, b.text));
    }

    fn sameSpans(a: []const Span, b: []const Span, same: Same) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!sameSpan(x, y, same)) return false;
        return true;
    }

    fn writeSpan(writer: *std.Io.Writer, row: usize, span: Span) std.Io.Writer.Error!void {
        try writer.print("\x1b[{d};{d}H\x1b[0", .{ row, span.column + 1 });
        if (span.style.bold) try writer.writeAll(";1");
        if (span.style.reverse) try writer.writeAll(";7");
        const parameters = sgr.get(span.style.colour);
        if (parameters.len != 0) try writer.print(";{s}", .{parameters});
        try writer.print("m{s}\x1b[0m", .{span.text});
    }

    /// The style at `column` of line `row`, if a span covers it.
    pub fn styleAt(self: *const Screen, row: usize, column: usize) ?Style {
        for (self.lines[row]) |span| if (column >= span.column and column < span.column + span.cells) return span.style;
        return null;
    }
};

const Glyphs = struct { prompt: []const u8, dot: []const u8, rule: []const u8, ellipsis: []const u8, arrows: []const u8, newline: []const u8 };
const unicode_glyphs: Glyphs = .{ .prompt = "›", .dot = "·", .rule = "─", .ellipsis = "…", .arrows = "↑↓", .newline = "↵" };
const ascii_glyphs: Glyphs = .{ .prompt = ">", .dot = "-", .rule = "-", .ellipsis = ".", .arrows = "^v", .newline = "|" };

/// Draws the overview. `frame` picks each active mark's pulse.
pub fn render(gpa: Allocator, state: *const State, width: u16, height: u16, caps: Caps, frame: u64) error{OutOfMemory}!Screen {
    var screen: Screen = .{ .arena = .init(gpa), .width = width, .lines = &.{} };
    errdefer screen.deinit();
    var painter: Painter = .{ .arena = screen.arena.allocator(), .caps = caps, .glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs, .width = width, .frame = frame };
    const lines = try painter.arena.alloc([]const Span, height);
    @memset(lines, &.{});
    screen.lines = lines;
    if (height == 0 or width == 0) return screen;
    var row: usize = 0;
    lines[row] = try header(&painter, state);
    row += 1;
    if (row < height) {
        lines[row] = try headline(&painter, state);
        row += 1;
    }
    if (row < height) if (band(state.rows.items, state.now_ms, state.login_at)) |trouble| {
        lines[row] = try bandLine(&painter, trouble, state.now_ms);
        row += 1;
    };
    row += 1;
    const bottom = height -| 3;
    if (row < bottom) try list(&painter, state, lines[row..bottom]);
    if (height >= 6) {
        lines[height - 3] = try ruleLine(&painter);
        lines[height - 2] = try composer(&painter, state);
        lines[height - 1] = try hints(&painter, state);
        // The caret ends the draft, the composer's last span.
        const spans = lines[height - 2];
        const column = if (state.draft_len == 0 or spans.len == 0) 3 else spans[spans.len - 1].column + spans[spans.len - 1].cells;
        if (!state.starting()) screen.cursor = .{ .row = height - 2, .column = @min(width - 1, column) };
    }
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
    /// Reverse video across the line, for the selection.
    reverse: bool = false,

    fn begin(self: *Painter, reverse: bool) void {
        self.count = 0;
        self.column = 0;
        self.reverse = reverse;
    }

    fn finish(self: *Painter) error{OutOfMemory}![]const Span {
        if (self.reverse) try self.pad(self.width, .{});
        return self.arena.dupe(Span, self.spans[0..self.count]);
    }

    fn style(self: *const Painter, wanted: Style) Style {
        var result = wanted;
        if (!self.caps.colour) {
            if (result.colour == .band) {
                result.bold = true;
                result.reverse = true;
            }
            result.colour = .normal;
        }
        if (self.reverse) result = .{ .reverse = true, .bold = result.bold };
        return result;
    }

    fn pad(self: *Painter, column: usize, wanted: Style) error{OutOfMemory}!void {
        const to = @min(column, self.width);
        if (to <= self.column) return;
        if (self.reverse or wanted.colour == .band) {
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
    _ = try painter.put(1, "rui", 3, .{ .bold = true });
    const path = shortPath(state.home, state.workspaces.items[state.cwd]);
    const joined = try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
    _ = try painter.putTail(6, joined, painter.width -| 7, .{ .colour = .quiet });
    return painter.finish();
}

fn headline(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    if (state.unreachable_since_ms != null) {
        var buffer: [8]u8 = undefined;
        const text = if (state.listed_at_ms) |at|
            try std.fmt.allocPrint(painter.arena, "Host not responding; showing what it reported {s} ago", .{ageText(&buffer, (state.now_ms -| at) / 1000)})
        else
            "Host not responding";
        _ = try painter.put(1, text, painter.width -| 2, .{ .colour = .failure });
        return painter.finish();
    }
    if (state.listed_at_ms == null) {
        _ = try painter.put(1, "Reading Sessions", painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    if (state.rows.items.len == 0) {
        _ = try painter.put(1, "No Sessions yet. Describe a task below to start one.", painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    var column: usize = 1;
    var first = true;
    for (headline_marks) |mark| {
        const count = state.counts.get(mark);
        if (count == 0) continue;
        const text = try std.fmt.allocPrint(painter.arena, "{s}{d} {s}", .{ if (first) "" else try std.mem.concat(painter.arena, u8, &.{ " ", painter.glyphs.dot, " " }), count, marks.get(mark).word });
        const cells = painter.measure(text);
        if (column + cells > painter.width -| 1) break;
        column += try painter.put(column, text, cells, .{});
        first = false;
    }
    // Pending Sessions wait for a slot when every slot is held.
    if (state.host) |host| if (host.slots_in_use >= host.slots and state.pendingCount() != 0) {
        const text = try std.fmt.allocPrint(painter.arena, " {s} all {d} slots in use", .{ painter.glyphs.dot, host.slots });
        const cells = painter.measure(text);
        if (column + cells <= painter.width -| 1) _ = try painter.put(column, text, cells, .{ .colour = .quiet });
    };
    return painter.finish();
}

fn bandLine(painter: *Painter, trouble: Band, now_ms: u64) error{OutOfMemory}![]const Span {
    painter.begin(false);
    var buffer: [8]u8 = undefined;
    const text = switch (trouble.trouble) {
        .sign_in => "Sign-in expired. Sessions fail as they reach the model: rui auth login codex",
        .quota => if (trouble.resets_at) |at|
            try std.fmt.allocPrint(painter.arena, "Provider quota used up; resets in {s}. Sessions fail at the model.", .{ageText(&buffer, at -| now_ms / 1000)})
        else
            "Provider quota used up. Sessions fail at the model.",
        .rate_limit => try std.fmt.allocPrint(painter.arena, "Rate limited {s} {d} Session{s} retrying", .{ painter.glyphs.dot, trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
    };
    const style: Style = .{ .colour = .band, .bold = true };
    try painter.pad(1, style);
    _ = try painter.put(1, text, painter.width -| 2, style);
    try painter.pad(painter.width, style);
    return painter.finish();
}

fn ruleLine(painter: *Painter) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const cells = painter.width -| 2;
    const text = try painter.arena.alloc(u8, cells * painter.glyphs.rule.len);
    for (0..cells) |at| @memcpy(text[at * painter.glyphs.rule.len ..][0..painter.glyphs.rule.len], painter.glyphs.rule);
    try painter.pad(1, .{});
    painter.push(text, cells, .{ .colour = .quiet });
    return painter.finish();
}

fn composer(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    _ = try painter.put(1, painter.glyphs.prompt, 1, .{ .colour = .quiet });
    if (state.draft_len == 0) {
        _ = try painter.put(3, "describe a task for a new Session", painter.width -| 4, .{ .colour = .quiet });
    } else {
        _ = try painter.putTail(3, state.draftText(), painter.width -| 4, .{ .colour = if (state.starting()) .quiet else .normal });
    }
    return painter.finish();
}

fn hints(painter: *Painter, state: *const State) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const room = painter.width -| 2;
    const dot = painter.glyphs.dot;
    if (state.prompt) |prompt| {
        const text = try std.fmt.allocPrint(painter.arena, "ctrl+x again to stop {s}; Sessions it messaged keep running {s} esc cancels", .{ &prompt.stop, dot });
        _ = try painter.put(1, text, room, .{ .colour = .attention });
    } else if (state.notice) |*notice| {
        _ = try painter.put(1, notice.text(), room, .{ .colour = notice.colour });
    } else if (state.starting()) {
        _ = try painter.put(1, "Starting a Session", room, .{ .colour = .quiet });
    } else if (!state.settings.empty()) {
        var text: std.Io.Writer.Allocating = .init(painter.arena);
        text.writer.writeAll("start settings:") catch return error.OutOfMemory;
        writeSettings(&state.settings, &text.writer) catch return error.OutOfMemory;
        // Long settings are cut so the way out stays on screen.
        const suffix = try std.fmt.allocPrint(painter.arena, " {s} esc clears", .{dot});
        const used = try painter.put(1, text.written(), room -| painter.measure(suffix), .{ .colour = .quiet });
        _ = try painter.put(1 + used, suffix, room -| used, .{ .colour = .quiet });
    } else if (state.draft_len != 0) {
        const text = try std.fmt.allocPrint(painter.arena, "enter starts a new Session {s} esc clears", .{dot});
        _ = try painter.put(1, text, room, .{ .colour = .quiet });
    } else if (state.selectedRow()) |row| {
        const stop = if (rules.get(shownKind(state, row)).stoppable) try std.fmt.allocPrint(painter.arena, " {s} ctrl+x stop", .{dot}) else "";
        const text = try std.fmt.allocPrint(painter.arena, "{s} select {s} enter open{s} {s} type to start a new Session", .{ painter.glyphs.arrows, dot, stop, dot });
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
            .heading => |group| try heading(painter, state, group),
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

fn heading(painter: *Painter, state: *const State, group: Group) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const info = groups.get(group);
    var column = 1 + try painter.put(1, info.title, painter.width -| 2, .{ .bold = true });
    const count = try std.fmt.allocPrint(painter.arena, "  {d}", .{state.runs.get(group).len});
    column += try painter.put(column, count, painter.width -| column -| 1, .{ .colour = .quiet });
    if (info.help.len != 0) _ = try painter.put(column + 2, info.help, painter.width -| column -| 3, .{ .colour = .quiet });
    return painter.finish();
}

fn moreLine(painter: *Painter, hidden: usize) error{OutOfMemory}![]const Span {
    painter.begin(false);
    const text = try std.fmt.allocPrint(painter.arena, "{d} more", .{hidden});
    _ = try painter.put(3, text, painter.width -| 4, .{ .colour = .quiet });
    return painter.finish();
}

/// Row columns: mark, title, word, Workspace, age. A narrow screen drops the
/// Workspace, then the word; a wide one stops rows at 160 cells so the age
/// stays near its title.
const Columns = struct {
    title: usize,
    word: usize,
    workspace: usize,
    end: usize,

    fn of(screen_width: usize) Columns {
        const width = @min(screen_width, 160);
        const end = width -| 1;
        const fixed = 3 + 2 + 4 + 1;
        const word_cells: usize = if (width >= 120) 36 else 20;
        const workspace_cells: usize = if (width >= 120) 32 else 12;
        if (width >= fixed + word_cells + 2 + workspace_cells + 2 + 24) return .{ .title = width - fixed - word_cells - workspace_cells - 4, .word = word_cells, .workspace = workspace_cells, .end = end };
        if (width >= fixed + word_cells + 2 + 16) return .{ .title = width - fixed - word_cells - 2, .word = word_cells, .workspace = 0, .end = end };
        return .{ .title = width -| fixed, .word = 0, .workspace = 0, .end = end };
    }
};

fn rowLine(painter: *Painter, state: *const State, at: usize, columns: Columns) error{OutOfMemory}![]const Span {
    const row = &state.rows.items[state.order.items[at]];
    const selected = if (state.selected) |*ref| std.mem.eql(u8, ref, &row.reference) else false;
    painter.begin(selected);
    const kind = shownKind(state, row);
    const rule = rules.get(kind);
    const faded = state.unreachable_since_ms != null;
    const tone = if (faded) Colour.quiet else rule.colour;
    const mark = marks.get(rule.mark);
    // Only Unicode in colour pulses. A faded row may have stopped, so it
    // holds still.
    const pulses = rule.mark == .active and !faded and painter.caps.unicode and painter.caps.colour;
    painter.pulsed = painter.pulsed or pulses;
    const glyph = if (pulses) pulse_frames[painter.frame % pulse_frames.len] else if (painter.caps.unicode) mark.unicode else mark.ascii;
    _ = try painter.put(1, glyph, 1, .{ .colour = tone });

    const ended = rule.group == .finished or rule.group == .ended;
    const named = title(state, row);
    const title_colour: Colour = if (faded or named.hint or (ended and row.group() != .yours)) .quiet else .normal;
    _ = try painter.put(3, named.text, columns.title, .{ .colour = title_colour, .bold = row.group() == .yours and !faded });

    var column = 3 + columns.title + 2;
    if (columns.word != 0) {
        const text = try word(painter.arena, state, row, rule, painter.glyphs);
        _ = try painter.put(column, text, columns.word, .{ .colour = tone });
        column += columns.word + 2;
    }
    // Only a row outside the working directory names its Workspace.
    if (columns.workspace != 0 and row.workspace != state.cwd) {
        const path = shortPath(state.home, state.workspaces.items[row.workspace]);
        const joined = try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
        _ = try painter.putTail(column, joined, columns.workspace, .{ .colour = if (faded) .quiet else .normal });
    }
    var buffer: [8]u8 = undefined;
    try painter.putRight(columns.end, ageText(&buffer, (state.now_ms / 1000) -| row.state.since()), .{ .colour = .quiet });
    return painter.finish();
}

/// The row title: its Label, else the first line of its first Message (a
/// greyed hint), else its reference.
fn title(state: *const State, row: *const Row) struct { text: []const u8, hint: bool } {
    if (row.label) |*text| return .{ .text = text.slice(), .hint = false };
    if (state.lineOf(row)) |line| return .{ .text = line, .hint = true };
    return .{ .text = &row.reference, .hint = true };
}

/// What the row says beside its title, unless its group heading says it.
fn word(arena: Allocator, state: *const State, row: *const Row, rule: Rule, glyphs: Glyphs) error{OutOfMemory}![]const u8 {
    if (rule.held) if (state.host) |host| if (row.state.since() < host.started_at) return "recovering";
    const own = rule.said_by_group and row.group() == rule.group;
    return switch (rule.detail) {
        .none => if (own) "" else rule.word,
        .description => if (row.state == .bash) if (row.state.bash.description) |*text| text.slice() else rule.word else rule.word,
        .due => if (row.state == .retrying) try std.fmt.allocPrint(arena, "{s} in {d}s", .{ rule.word, (row.state.retrying.due_at_ms -| state.now_ms + 999) / 1000 }) else rule.word,
        .starter => {
            const sender = (row.first orelse return rule.word).sender orelse return rule.word;
            if (state.find(sender)) |starter| if (starter.label) |*text| return std.fmt.allocPrint(arena, "{s} {s} for \"{s}\"", .{ rule.word, glyphs.dot, text.slice() });
            return std.fmt.allocPrint(arena, "{s} {s} for {s}", .{ rule.word, glyphs.dot, &sender });
        },
    };
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
};

fn session(ref: *const [6]u8, state: WorkState, options: TestSession) Listed {
    return .{
        .reference = ref.*,
        .workspace = options.workspace,
        .label = options.label,
        .state = state,
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

fn press(state: *State, key: Key) !Effects {
    return step(state, .{ .key = key });
}

fn typeText(state: *State, text: []const u8) !void {
    try expectEffects(&.{}, try press(state, .{ .text = text }));
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
            .exit => {},
        }
    }
}

fn expectNotice(state: *const State, expected: ?[]const u8) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try std.testing.expectEqualStrings(text, notice.text());
    } else if (state.notice) |*notice| try std.testing.expectEqualStrings("", notice.text());
}

fn expectSelected(state: *const State, expected: *const [6]u8) !void {
    try std.testing.expectEqualStrings(expected, &(state.selected orelse return error.TestExpectedSelection));
}

fn screenText(state: *const State, width: u16, height: u16, caps: Caps) ![]u8 {
    return frameText(state, width, height, caps, 0);
}

fn frameText(state: *const State, width: u16, height: u16, caps: Caps, frame: u64) ![]u8 {
    var screen = try render(std.testing.allocator, state, width, height, caps, frame);
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
    session("a1b2c3", .{ .bash = .{ .since = test_now_s - 60, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .{ .label = "Find why store tests fail" }),
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
    .{ .state = .{ .idle = ago(7200) }, .heading = " Idle  1", .unicode = " ○ Write the notes                                                           2h", .ascii = " o Write the notes                                                           2h", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .heading = " Working  1", .unicode = " ○ Write the notes                     pending                               5s", .ascii = " o Write the notes                     pending                               5s", .colour = .quiet, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .heading = " Working  1", .unicode = " ● Write the notes                                                          40s", .ascii = " * Write the notes                                                          40s", .colour = .normal, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .heading = " Working  1", .unicode = " ● Write the notes                     retrying in 12s                      30s", .ascii = " * Write the notes                     retrying in 12s                      30s", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .heading = " Working  1", .unicode = " ● Write the notes                     Run the logic tests                   1m", .ascii = " * Write the notes                     Run the logic tests                   1m", .colour = .normal, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .heading = " Working  1", .unicode = " ○ Write the notes                     needs approval                        3m", .ascii = " o Write the notes                     needs approval                        3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .heading = " Working  1", .unicode = " ● Write the notes                     stopping                              8s", .ascii = " * Write the notes                     stopping                              8s", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .heading = " Finished  1", .unicode = " ✓ Write the notes                                                          12m", .ascii = " + Write the notes                                                          12m", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .heading = " Failed or stopped  1", .unicode = " × Write the notes                     failed                                3h", .ascii = " x Write the notes                     failed                                3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .heading = " Failed or stopped  1", .unicode = " ■ Write the notes                     stopped                               2d", .ascii = " # Write the notes                     stopped                               2d", .colour = .normal, .stoppable = false },
};

test "every work state follows the rules table, in Unicode and ASCII" {
    comptime std.debug.assert(kind_cases.len == std.enums.values(Kind).len);
    for (kind_cases, std.enums.values(Kind)) |case, kind| {
        try std.testing.expectEqual(kind, std.meta.activeTag(case.state));
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        const rule = rules.get(kind);
        try std.testing.expectEqual(case.colour, rule.colour);
        try std.testing.expectEqual(case.stoppable, rule.stoppable);
        for ([_]Caps{ .{}, .{ .unicode = false } }, [_][]const u8{ case.unicode, case.ascii }) |caps, expected| {
            const text = try screenText(&state, 80, 24, caps);
            defer std.testing.allocator.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            for (0..3) |_| _ = lines.next();
            try std.testing.expectEqualStrings(case.heading, lines.next().?);
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
        // The mark and the word take the rule's colour.
        var screen = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
        defer screen.deinit();
        try std.testing.expect(screen.styleAt(4, 1).?.reverse);
        state.selected = null;
        var unselected = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
        defer unselected.deinit();
        try std.testing.expectEqual(Style{ .colour = rule.colour }, unselected.styleAt(4, 1).?);
        if (unselected.styleAt(4, 39)) |style| try std.testing.expectEqual(Style{ .colour = rule.colour }, style);
    }
}

test "an active mark pulses frame by frame while every other mark, and ASCII or NO_COLOR, hold still" {
    var state = try opened(&mixed);
    defer state.deinit();
    state.selected = null;
    // Without colour the marks hold still, so this is every frame's text
    // but for the active marks.
    const still = try screenText(&state, 80, 24, .{ .colour = false });
    defer std.testing.allocator.free(still);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, still, "\n ● "));
    for (pulse_frames, 0..) |glyph, frame| {
        var buffer: [16]u8 = undefined;
        const wanted = try std.mem.replaceOwned(u8, std.testing.allocator, still, "\n ● ", try std.fmt.bufPrint(&buffer, "\n {s} ", .{glyph}));
        defer std.testing.allocator.free(wanted);
        const text = try frameText(&state, 80, 24, .{}, frame + pulse_frames.len);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(wanted, text);
        var screen = try render(std.testing.allocator, &state, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(screen.pulses);
        // The retrying row pulses in the rule's warning colour.
        const retrying = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Audit permission paths").?], "\n");
        try std.testing.expectEqual(Style{ .colour = .attention }, screen.styleAt(retrying, 1).?);
    }
    for ([_]Caps{ .{ .unicode = false }, .{ .colour = false }, .{ .unicode = false, .colour = false } }) |caps| {
        const first = try screenText(&state, 80, 24, caps);
        defer std.testing.allocator.free(first);
        for (1..pulse_frames.len) |frame| {
            const text = try frameText(&state, 80, 24, caps, frame);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings(first, text);
            var screen = try render(std.testing.allocator, &state, 80, 24, caps, frame);
            defer screen.deinit();
            try std.testing.expect(!screen.pulses);
        }
    }
}

test "the screen asks for frames only while an active mark shows" {
    var rows: [31]Listed = undefined;
    rows[0] = session("w0rk00", .{ .working = ago(40) }, .{ .label = "Write the notes" });
    for (rows[1..], 1..) |*row, at| {
        var ref: [6]u8 = "idle00".*;
        _ = std.fmt.bufPrint(ref[4..], "{d:0>2}", .{at}) catch unreachable;
        row.* = session(&ref, .{ .idle = ago(7200 + at) }, .{ .label = "Wait for a reply" });
    }
    var state = try opened(&rows);
    defer state.deinit();
    const Pulses = struct {
        fn at(from: *const State, height: u16) !bool {
            var screen = try render(std.testing.allocator, from, 80, height, .{}, 1);
            defer screen.deinit();
            return screen.pulses;
        }
    };
    try std.testing.expect(try Pulses.at(&state, 24));
    // Scrolled out of sight, the active row needs no frames.
    _ = try press(&state, .end);
    try std.testing.expect(!try Pulses.at(&state, 24));
    try std.testing.expect(try Pulses.at(&state, 60));
    // A faded row may have stopped, so it holds still until the Host answers.
    state.unreachable_since_ms = state.now_ms;
    try std.testing.expect(!try Pulses.at(&state, 60));
    const faded = try frameText(&state, 80, 60, .{}, 1);
    defer std.testing.allocator.free(faded);
    try std.testing.expect(std.mem.indexOf(u8, faded, " ● Write the notes") != null);
    // Once the last active row finishes, nothing pulses.
    rows[0] = session("w0rk00", .{ .finished = ago(1) }, .{ .label = "Write the notes" });
    _ = try refresh(&state, .full, testToken(2), &rows);
    try std.testing.expect(!try Pulses.at(&state, 60));
}

fn frameBytes(screen: *const Screen, shown: ?*const Screen) ![]u8 {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer bytes.deinit();
    try screen.writeFrame(shown, &bytes.writer);
    return bytes.toOwnedSlice();
}

test "a frame writes only what changed on the screen the terminal shows" {
    var state = try opened(&mixed);
    defer state.deinit();
    state.selected = null;
    var still = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
    defer still.deinit();
    var pulsed = try render(std.testing.allocator, &state, 80, 24, .{}, 1);
    defer pulsed.deinit();
    var wider = try render(std.testing.allocator, &state, 81, 24, .{}, 1);
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
    // The next pulse frame writes the six active marks and nothing else.
    const pulse = try frameBytes(&pulsed, &still);
    defer std.testing.allocator.free(pulse);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, pulse, "\x1b[2K"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, pulse, "H\x1b[0"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, pulse, "m·\x1b[0m"));
    // A line laid out anew is cleared and drawn whole; the others stay.
    try typeText(&state, "hi");
    var typed = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
    defer typed.deinit();
    const composed = try frameBytes(&typed, &still);
    defer std.testing.allocator.free(composed);
    // The composer and its hints changed; the list did not.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, composed, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, composed, "\x1b[23;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "\x1b[24;1H\x1b[2K") != null);
}

test "ctrl-x asks to stop only a row its rule lets it stop, and a second ctrl-x stops it" {
    for (kind_cases) |case| {
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        try expectEffects(&.{}, try press(&state, .ctrl_x));
        if (!case.stoppable) {
            try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
            var buffer: [64]u8 = undefined;
            try expectNotice(&state, try std.fmt.bufPrint(&buffer, "Nothing to stop: k7m2qx is {s}.", .{rules.get(case.state).word}));
            continue;
        }
        try std.testing.expectEqualStrings("k7m2qx", &state.prompt.?.stop);
        try expectNotice(&state, null);
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .ctrl_x));
        try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
        // Until its result arrives the row says it is stopping, and a third
        // ctrl-x finds nothing to stop.
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "● Write the notes                     stopping") != null);
        try expectEffects(&.{}, try press(&state, .ctrl_x));
        try expectNotice(&state, "Nothing to stop: k7m2qx is stopping.");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    }
}

test "a cancelled stop prompt sends nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectSelected(&state, "k7m2qx");
    // Esc only cancels.
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectEffects(&.{}, try press(&state, .escape));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "k7m2qx");
    // Another key cancels, then acts.
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectEffects(&.{}, try press(&state, .down));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "r4t9vw");
    // A row that finished after the prompt opened has nothing left to stop.
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    _ = try refresh(&state, .changed, testToken(2), &.{session("r4t9vw", .{ .finished = ago(0) }, .{ .label = "Review PR 412", .yours = true })});
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectNotice(&state, "Nothing to stop: r4t9vw is finished.");
    // A failed stop says why. The finished row moved to the top of its group.
    try expectEffects(&.{}, try press(&state, .down));
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .ctrl_x));
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNotice(&state, "! Could not stop k7m2qx: session_not_found");
}

test "unconfirmed stops keep their handles until departure; a full ledger refuses another" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectSelected(&state, "k7m2qx");
    const handles = comptime handles: {
        var handles: [8][]const u8 = undefined;
        for (&handles, 0..) |*handle, n| handle.* = std.fmt.comptimePrint("stop-handle-{d}", .{n});
        break :handles handles;
    };
    inline for (handles) |handle| {
        try expectEffects(&.{}, try press(&state, .ctrl_x));
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .ctrl_x));
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .{ .unconfirmed = handle } } }));
        try expectNotice(&state, "! Unconfirmed stop of k7m2qx: rui request recover " ++ handle);
    }
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectNotice(&state, "! Wait for earlier requests, or leave to recover unconfirmed ones.");
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, &departure.writer);
    const expected = comptime expected: {
        var text: []const u8 = "";
        for (handles) |handle| text = text ++ "rui: Stopping k7m2qx was not confirmed; use rui request recover " ++ handle ++ ". Do not stop it again.\n";
        break :expected text;
    };
    try std.testing.expectEqualStrings(expected, departure.written());
}

test "enter on a row opens it" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try press(&state, .down));
    try expectEffects(&.{.{ .open = "r4t9vw".* }}, try press(&state, .enter));
    // A blank draft is no request: Enter still opens the row.
    try typeText(&state, "  ");
    try expectEffects(&.{.{ .open = "r4t9vw".* }}, try press(&state, .enter));
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try expectSelected(&state, "r4t9vw");
}

test "esc clears the draft, then held start settings, and otherwise does nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    try typeText(&state, "/configure --permission-mode ask");
    try expectEffects(&.{}, try press(&state, .enter));
    try typeText(&state, "Fix the docs");
    try expectEffects(&.{}, try press(&state, .escape));
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try std.testing.expect(!state.settings.empty());
    try expectEffects(&.{}, try press(&state, .escape));
    try std.testing.expect(state.settings.empty());
    try expectEffects(&.{}, try press(&state, .escape));
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try expectSelected(&state, "k7m2qx");
    try expectNotice(&state, null);
}

test "the composer starts a Session with its text and opens it" {
    var state = try opened(&mixed);
    defer state.deinit();
    try typeText(&state, "Fix the flaky ");
    try typeText(&state, "resize testx");
    try expectEffects(&.{}, try press(&state, .backspace));
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "Fix the flaky resize test" } }}, try press(&state, .enter));
    try std.testing.expect(state.starting());
    // The composer stays locked until the result: the effect borrows it.
    try typeText(&state, "more");
    try expectEffects(&.{}, try press(&state, .enter));
    try expectEffects(&.{}, try press(&state, .escape));
    try std.testing.expectEqualStrings("Fix the flaky resize test", state.draftText());
    try expectEffects(&.{.{ .open = "z9y8x7".* }}, try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } }));
    try std.testing.expect(!state.starting());
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try expectSelected(&state, "z9y8x7");
    // The next tick lists at once, so the new row is there on return.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));

    // A failed start keeps the text for another Enter.
    try typeText(&state, "Try again");
    _ = try press(&state, .enter);
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .failed = "model_capability_unavailable" } }));
    try expectNotice(&state, "! Could not start a Session: model_capability_unavailable");
    try std.testing.expectEqualStrings("Try again", state.draftText());
    try std.testing.expect(!state.starting());
}

test "the composer starts text with one slash from //, as a conversation does" {
    var state = try opened(&mixed);
    defer state.deinit();
    try typeText(&state, "/home/me/project needs investigating");
    try expectEffects(&.{}, try press(&state, .enter));
    try expectNotice(&state, "! Unknown command · /configure sets the next Session's settings, /exit leaves");
    try expectEffects(&.{}, try press(&state, .escape));
    try typeText(&state, "//home/me/project needs investigating");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "/home/me/project needs investigating" } }}, try press(&state, .enter));
}

test "the composer sends its draft byte for byte, as a conversation does" {
    var state = try opened(&mixed);
    defer state.deinit();
    try typeText(&state, "    return x\n");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "    return x\n" } }}, try press(&state, .enter));

    var other = try opened(&mixed);
    defer other.deinit();
    try typeText(&other, " /exit");
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = " /exit" } }}, try press(&other, .enter));
}

test "/configure holds start settings for the Session the next Enter starts" {
    var state = try opened(&mixed);
    defer state.deinit();
    try typeText(&state, "/configure --permission-mode ask --label \"lane four\"");
    try expectEffects(&.{}, try press(&state, .enter));
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try expectNotice(&state, null);
    try expectScreenLine(&state, 23, " start settings: --permission-mode ask --label \"lane four\" · esc clears");
    // A later value replaces an earlier one; the rest stay.
    try typeText(&state, "/configure --label \"lane \\\"five\\\"\" --model gpt-5.5");
    try expectEffects(&.{}, try press(&state, .enter));
    var buffer: [2 * start_options.len][]const u8 = undefined;
    const args = state.settings.args(&buffer);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    for ([_][]const u8{ "--model", "gpt-5.5", "--permission-mode", "ask", "--label", "lane \"five\"" }, args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try expectScreenLine(&state, 23, " start settings: --model gpt-5.5 --permission-mode ask --label \"l… · esc clears");

    var held: StartSettings = .{};
    try held.put(1, "gpt-5.5");
    try held.put(4, "ask");
    try held.put(8, "lane \"five\"");
    try typeText(&state, "Run the tests");
    try expectEffects(&.{.{ .start = .{ .settings = &held, .text = "Run the tests" } }}, try press(&state, .enter));
    _ = try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } });
    try std.testing.expect(state.settings.empty());

    // Only `session start` options, in the conversation's grammar, are held.
    for ([_]struct { []const u8, []const u8 }{
        .{ "/configure --instructions -", "! --instructions is not a start setting; set it once the Session starts." },
        .{ "/configure --text-output", "! --text-output is not a start setting; set it once the Session starts." },
        .{ "/configure", configure_usage },
        .{ "/configure --help", configure_usage },
        .{ "/configure --bogus 1", configure_usage },
        .{ "/configure --label \"open", configure_usage },
        // The Host would admit it; its Turns would fail at the provider.
        .{ "/configure --model gpt-5", "! Unsupported model gpt-5; rui session configure --help lists them." },
        .{ "/status", "! Unknown command · /configure sets the next Session's settings, /exit leaves" },
    }) |case| {
        try typeText(&state, case[0]);
        try expectEffects(&.{}, try press(&state, .enter));
        try expectNotice(&state, case[1]);
        try std.testing.expect(state.settings.empty());
        try std.testing.expectEqualStrings(case[0], state.draftText());
        _ = try press(&state, .escape);
    }
}

test "start settings are the options session start shares with /configure" {
    const expected = [_][]const u8{ "provider", "model", "workspace", "tools", "permission-mode", "compaction-trigger", "output-reservation", "reasoning-effort", "label" };
    try std.testing.expectEqual(expected.len, start_options.len);
    for (expected, start_options) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectScreenLine(state: *const State, line: usize, expected: []const u8) !void {
    const text = try screenText(state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..line) |_| _ = lines.next();
    try std.testing.expectEqualStrings(expected, lines.next().?);
}

test "ctrl-d leaves from an empty composer; ctrl-c and /exit always leave" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{.exit}, try press(&state, .ctrl_d));
    try typeText(&state, "draft");
    try expectEffects(&.{}, try press(&state, .ctrl_d));
    try expectEffects(&.{.exit}, try press(&state, .ctrl_c));
    _ = try press(&state, .escape);
    try typeText(&state, "/exit");
    try expectEffects(&.{.exit}, try press(&state, .enter));
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
    var state = try opened(&mixed);
    defer state.deinit();
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings("", departure.written());

    try typeText(&state, "/configure --permission-mode ask");
    _ = try press(&state, .enter);
    try typeText(&state, "Fix the flaky resize test");
    _ = try press(&state, .enter);
    const handle = "0f8e2c1a-7b3d-4e5f-9a6b-1c2d3e4f5a6b";
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .unconfirmed = handle } }));
    try std.testing.expect(!state.starting());
    // Another Enter would be a second Session, so the text is not kept.
    try std.testing.expectEqual(@as(usize, 0), state.draft_len);
    try std.testing.expect(state.settings.empty());
    try expectNotice(&state, "! Unconfirmed: rui request recover " ++ handle);
    try expectScreenLine(&state, 23, " ! Unconfirmed: rui request recover " ++ handle);
    // The next tick lists at once, so a start that did land shows.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));
    // A second unconfirmed start keeps the first one's handle.
    const second = "9a0b1c2d-3e4f-4a6b-8c7d-0f8e2c1a7b3d";
    try typeText(&state, "Fix it again");
    _ = try press(&state, .enter);
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .unconfirmed = second } }));
    try writeDeparture(&state, &departure.writer);
    try std.testing.expectEqualStrings("rui: A new Session's start was not confirmed; use rui request recover " ++ handle ++ ". Do not start it again.\n" ++
        "rui: A new Session's start was not confirmed; use rui request recover " ++ second ++ ". Do not start it again.\n", departure.written());
}

test "leaving with a start in flight says what became of it" {
    const handle = "0f8e2c1a-7b3d-4e5f-9a6b-1c2d3e4f5a6b";
    const Case = struct { result: ?StartResult, departure: []const u8 };
    for ([_]Case{
        .{ .result = null, .departure = "rui: The new Session was not started (cancelled); start it again from the overview.\n" },
        .{ .result = .{ .failed = "Cancelled" }, .departure = "rui: The new Session was not started (Cancelled); start it again from the overview.\n" },
        .{ .result = .{ .started = .{ .reference = "n3w5es".*, .handle = handle } }, .departure = "rui: Session start accepted: n3w5es.\nMessage request: " ++ handle ++ " (rui request inspect " ++ handle ++ ")\n" },
        .{ .result = .{ .unconfirmed = handle }, .departure = "rui: A new Session's start was not confirmed; use rui request recover " ++ handle ++ ". Do not start it again.\n" },
    }) |case| {
        var state = try opened(&mixed);
        defer state.deinit();
        try typeText(&state, "Fix the flaky resize test");
        _ = try press(&state, .enter);
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

test "the cursor sits at the composer's caret and hides while a start is locked" {
    var state = try opened(&mixed);
    defer state.deinit();
    const expectCursor = struct {
        fn at(from: *const State, width: u16, expected: ?Screen.Cursor) !void {
            var screen = try render(std.testing.allocator, from, width, 24, .{}, 0);
            defer screen.deinit();
            try std.testing.expectEqual(expected, screen.cursor);
        }
    }.at;
    try expectCursor(&state, 80, .{ .row = 22, .column = 3 });
    try typeText(&state, "Fix 中");
    try expectCursor(&state, 80, .{ .row = 22, .column = 9 });
    // A draft wider than the composer keeps its end, and the caret, in view.
    const long: [100]u8 = @splat('x');
    try typeText(&state, &long);
    try expectCursor(&state, 80, .{ .row = 22, .column = 79 });
    try expectCursor(&state, 6, .{ .row = 22, .column = 5 });
    _ = try press(&state, .enter);
    try expectCursor(&state, 80, null);
}

test "caps follow the locale that sets the character set, and NO_COLOR" {
    for ([_]struct { Caps.Environment, Caps }{
        .{ .{}, .{} },
        .{ .{ .lang = "en_US.UTF-8" }, .{} },
        .{ .{ .lang = "C" }, .{ .unicode = false } },
        .{ .{ .lang = "C.utf8" }, .{} },
        .{ .{ .lc_all = "C", .lang = "en_US.UTF-8" }, .{ .unicode = false } },
        .{ .{ .lc_all = "", .lc_ctype = "POSIX", .lang = "en_US.UTF-8" }, .{ .unicode = false } },
        .{ .{ .lc_ctype = "en_GB.utf-8", .lang = "C" }, .{} },
        .{ .{ .lang = "C", .no_color = "1" }, .{ .unicode = false, .colour = false } },
        .{ .{ .no_color = "" }, .{} },
    }) |case| try std.testing.expectEqual(case[1], Caps.of(case[0]));
}

test "a first line read one byte past the kept bound shows it was cut" {
    var line: [max_line_read_bytes]u8 = @splat('a');
    try std.testing.expect(std.mem.endsWith(u8, firstLineText(&line).slice(), "…"));
    try std.testing.expect(!std.mem.endsWith(u8, firstLineText(line[0..max_line_bytes]).slice(), "…"));
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
    try expectScreenLine(&state, 6, " ✓ summarize yesterday's CI failures   finished                             12m");
    // Lines in flight or unreadable are not asked for again, and a refresh
    // that replaces a row keeps the line of its unchanged first Message.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{session("h8q2mz", .{ .working = ago(0) }, .{ .yours = true })}));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // An unreadable line is not asked for again while listings, changed or
    // full, name its unchanged first Message.
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } });
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{f6g7h8}));
    try expectEffects(&.{}, try refresh(&state, .full, testToken(4), &mixed));
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

test "Host facts word a held row recovering and say when pending Sessions wait for a slot" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Admitted before the restart" }),
        session("h8q2mz", .{ .working = ago(5) }, .{ .label = "Admitted after it" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
    });
    defer state.deinit();
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "recovering") == null);
    try expectScreenLine(&state, 1, " 2 active · 1 waiting");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 1, " 2 active · 1 waiting · all 2 slots in use");
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    var lines = std.mem.splitScalar(u8, after, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "before the restart") != null) try std.testing.expect(std.mem.indexOf(u8, line, "recovering") != null);
        if (std.mem.indexOf(u8, line, "after it") != null) try std.testing.expect(std.mem.indexOf(u8, line, "recovering") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "recovering"));
    // A free slot leaves nothing to say; no facts leave nothing to word.
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 1 } });
    try expectScreenLine(&state, 1, " 2 active · 1 waiting");
    _ = try step(&state, .{ .host = null });
    const unknown = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "recovering") == null);
}

test "a long first line keeps whole code points and ends in an ellipsis" {
    var line: [400]u8 = undefined;
    for (0..200) |at| @memcpy(line[at * 2 ..][0..2], "é");
    const kept = firstLineText(&line);
    try std.testing.expect(std.unicode.utf8ValidateSlice(kept.slice()));
    try std.testing.expect(std.mem.endsWith(u8, kept.slice(), "…"));
    try std.testing.expect(kept.len <= max_line_bytes);
    try std.testing.expectEqualStrings("short", firstLineText("short\nrest").slice());
}

test "the selection stays on its Session when it moves from working to finished" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (0..4) |_| _ = try press(&state, .down);
    try expectSelected(&state, "e5f6g7");
    _ = try refresh(&state, .changed, testToken(2), &.{session("e5f6g7", .{ .finished = ago(0) }, .{ .label = "List unused build steps" })});
    try expectSelected(&state, "e5f6g7");
    try std.testing.expectEqual(Group.finished, state.find("e5f6g7".*).?.group());
    try expectEffects(&.{.{ .open = "e5f6g7".* }}, try press(&state, .enter));
    try expectScreenLine(&state, 19, " ✓ List unused build steps                                                   1s");
    // Moving on goes to the next row on screen, not the next old index.
    _ = try press(&state, .down);
    try expectSelected(&state, "m1n2p3");
    // A selected row that lands among a folded group's hidden rows opens the group.
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expect(state.unfolded.contains(.finished));
}

test "moving into a folded group's hidden rows opens it" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(folded(&state, .finished));
    // Up from the first failed row lands on the last finished row shown.
    _ = try press(&state, .end);
    try expectSelected(&state, "y1z2a3");
    for (0..3) |_| _ = try press(&state, .up);
    try expectSelected(&state, "s6t7v8");
    try std.testing.expect(folded(&state, .finished));
    _ = try press(&state, .down);
    try expectSelected(&state, "v8w9x0");
    try std.testing.expect(!folded(&state, .finished));
    _ = try press(&state, .home);
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
        _ = try press(&state, .down);
    }
    try expectSelected(&state, "cccccc");
    try expectEffects(&.{}, try press(&state, .ctrl_x));
    try expectEffects(&.{.{ .stop = "cccccc".* }}, try press(&state, .ctrl_x));

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
    try std.testing.expectEqual(@as(?u64, (test_now_s + 300) * 1000), state.wakeAt());
    _ = try respond(&state, .full, testToken(2), &.{failedRow("q1q1q1", 60, "provider_usage_limit_reached", std.math.maxInt(i64))});
    _ = try step(&state, .{ .tick = start + 13_000 });
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
    try expectScreenLine(&state, 1, " Host not responding; showing what it reported 1s ago");
    var screen = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(6, 1).?);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 1, " 6 active · 3 waiting · 2 failed · 1 stopped · 8 finished");
}

test "a tick moves a retry that fell due to pending" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(state.find("c3d4e5".*).?.state == .retrying);
    _ = try step(&state, .{ .tick = (test_now_s + 12) * 1000 });
    const row = state.find("c3d4e5".*).?;
    try std.testing.expectEqual(WorkState{ .pending = .{ .since = test_now_s + 12 } }, row.state);
    try expectScreenLine(&state, 1, " 5 active · 4 waiting · 2 failed · 1 stopped · 8 finished");
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
    for (sign_in_codes) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
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

/// One letter per cell: `.` unstyled; `n`ormal, `q`uiet, `a`ttention,
/// `f`ailure or `b`and colour; `r` reverse. Capitals are bold.
fn expectStyles(state: *const State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    var screen = try render(std.testing.allocator, state, width, height, caps, 0);
    defer screen.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (screen.lines) |line| {
        var cells: [512]u8 = @splat('.');
        var end: usize = 0;
        for (line) |span| {
            const letter: u8 = if (span.style.reverse) 'r' else switch (span.style.colour) {
                .normal => 'n',
                .quiet => 'q',
                .attention => 'a',
                .failure => 'f',
                .band => 'b',
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
    for ([_]Caps{ .{}, .{ .colour = false } }, [_]Style{ .{ .colour = .band, .bold = true }, .{ .bold = true, .reverse = true } }) |caps, style| {
        var screen = try render(std.testing.allocator, &state, 80, 24, caps, 0);
        defer screen.deinit();
        try std.testing.expectEqual(style, screen.styleAt(2, 0).?);
        try std.testing.expectEqual(style, screen.styleAt(2, 79).?);
    }
}

test "a quota reset far in the future still draws its band" {
    var state = try opened(&.{failedRow("q1q1q1", 60, "provider_usage_limit_reached", 100_000_000_000_000_000)});
    defer state.deinit();
    try expectScreenLine(&state, 2, " Provider quota used up; resets in 999d. Sessions fail at the model.");
}

test "render draws each band" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Summarize the CI failures" });
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_refresh_token_expired", null) },
        \\ rui  ~/code/rui
        \\ 1 failed · 1 finished
        \\ Sign-in expired. Sessions fail as they reach the model: rui auth login codex
        \\
        \\ Finished  1
        \\ ✓ Summarize the CI failures                                                10m
        \\
        \\ Failed or stopped  1
        \\ × Ask the model                       failed                                1m
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · type to start a new Session
        \\
    ,
        \\.NNN..qqqqqqqqqq
        \\.nnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\.NNNNNNNNqqq
        \\rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.NNNNNNNNNNNNNNNNNqqq
        \\.f.qqqqqqqqqqqqq.......................ffffff................................qq
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
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ~/code/rui
        \\ 1 failed · 1 finished
        \\ Sign-in expired. Sessions fail as they reach the model: rui auth login codex
        \\
        \\ Finished  1
        \\ ✓ Summarize the CI failures                                                                                                                                10m
        \\
        \\ Failed or stopped  1
        \\ × Ask the model                                                                   failed                                                                    1m
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · type to start a new Session
        \\
    );
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_usage_limit_reached", test_now_s + 20 * 60) },
        \\ rui  ~/code/rui
        \\ 1 failed · 1 finished
        \\ Provider quota used up; resets in 20m. Sessions fail at the model.
        \\
        \\ Finished  1
        \\ ✓ Summarize the CI failures                                                10m
        \\
        \\ Failed or stopped  1
        \\ × Ask the model                       failed                                1m
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · type to start a new Session
        \\
    ,
        \\.NNN..qqqqqqqqqq
        \\.nnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\.NNNNNNNNqqq
        \\rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.NNNNNNNNNNNNNNNNNqqq
        \\.f.qqqqqqqqqqqqq.......................ffffff................................qq
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
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ~/code/rui
        \\ 1 failed · 1 finished
        \\ Provider quota used up; resets in 20m. Sessions fail at the model.
        \\
        \\ Finished  1
        \\ ✓ Summarize the CI failures                                                                                                                                10m
        \\
        \\ Failed or stopped  1
        \\ × Ask the model                                                                   failed                                                                    1m
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · type to start a new Session
        \\
    );
    try expectBand(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20) },
        \\ rui  ~/code/rui
        \\ 2 active
        \\ Rate limited · 2 Sessions retrying
        \\
        \\ Working  2
        \\ ● Ask the model again                 retrying in 10s                       5s
        \\ ● Ask the model again                 retrying in 20s                       5s
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · ctrl+x stop · type to start a new Session
        \\
    ,
        \\.NNN..qqqqqqqqqq
        \\.nnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\.NNNNNNNqqq
        \\rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\.a.nnnnnnnnnnnnnnnnnnn.................aaaaaaaaaaaaaaa.......................qq
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
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ~/code/rui
        \\ 2 active
        \\ Rate limited · 2 Sessions retrying
        \\
        \\ Working  2
        \\ ● Ask the model again                                                             retrying in 10s                                                           5s
        \\ ● Ask the model again                                                             retrying in 20s                                                           5s
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · ctrl+x stop · type to start a new Session
        \\
    );
}

test "render draws an empty Store" {
    var state = try opened(&.{});
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ rui  ~/code/rui
        \\ No Sessions yet. Describe a task below to start one.
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
        \\ › describe a task for a new Session
        \\
        \\
    ,
        \\.NNN..qqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
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
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
    ,
        \\ rui  ~/code/rui
        \\ No Sessions yet. Describe a task below to start one.
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
        \\ › describe a task for a new Session
        \\
        \\
    );
}

test "render draws twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ rui  ~/code/rui
        \\ 6 active · 3 waiting · 2 failed · 1 stopped · 8 finished
        \\
        \\ Your conversations  3  Sessions you or your scripts messaged
        \\ ● Fix the flaky resize test           working                              40s
        \\ ○ Review PR 412                       needs approval                        3m
        \\ ✓ h8q2mz                              finished                             12m
        \\
        \\ Working  6
        \\ ○ Trace Host shutdown order           pending                               5s
        \\ ● List unused build steps             stopping                              8s
        \\ ● Audit permission paths              retrying in 12s                      30s
        \\ ● Find why store tests fail           Run the logic tests                   1m
        \\ ● f6g7h8                                                    ~/code/other    1m
        \\ ● Profile the curl send queue                                               2m
        \\
        \\ Idle  1
        \\ ○ Check macOS socket cleanup                                                2h
        \\
        \\ Finished  7
        \\ ✓ Explain provider output parsing                                          20m
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · ctrl+x stop · type to start a new Session
        \\
    ,
        \\.NNN..qqqqqqqqqq
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
        \\.NNNNNNNNNNNNNNNNNNqqq..qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\rrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\.a.NNNNNNNNNNNNN.......................aaaaaaaaaaaaaa........................qq
        \\.q.QQQQQQ..............................qqqqqqqq.............................qqq
        \\
        \\.NNNNNNNqqq
        \\.q.nnnnnnnnnnnnnnnnnnnnnnnnn...........qqqqqqq...............................qq
        \\.q.nnnnnnnnnnnnnnnnnnnnnnn.............qqqqqqqq..............................qq
        \\.a.nnnnnnnnnnnnnnnnnnnnnn..............aaaaaaaaaaaaaaa......................qqq
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnn...........nnnnnnnnnnnnnnnnnnn...................qq
        \\.n.qqqqqq....................................................nnnnnnnnnnnn....qq
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnn...............................................qq
        \\
        \\.NNNNqqq
        \\.q.nnnnnnnnnnnnnnnnnnnnnnnnnn................................................qq
        \\
        \\.NNNNNNNNqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq..........................................qqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.q.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ~/code/rui
        \\ 6 active · 3 waiting · 2 failed · 1 stopped · 8 finished
        \\
        \\ Your conversations  3  Sessions you or your scripts messaged
        \\ ● Fix the flaky resize test                                                       working                                                                  40s
        \\ ○ Review PR 412                                                                   needs approval                                                            3m
        \\ ✓ h8q2mz                                                                          finished                                                                 12m
        \\
        \\ Working  6
        \\ ○ Trace Host shutdown order                                                       pending                                                                   5s
        \\ ● List unused build steps                                                         stopping                                                                  8s
        \\ ● Audit permission paths                                                          retrying in 12s                                                          30s
        \\ ● Find why store tests fail                                                       Run the logic tests                                                       1m
        \\ ● f6g7h8                                                                                                                ~/code/other                        1m
        \\ ● Profile the curl send queue                                                                                                                               2m
        \\
        \\ Idle  1
        \\ ○ Check macOS socket cleanup                                                                                                                                2h
        \\
        \\ Finished  7
        \\ ✓ Explain provider output parsing                                                                                                                          20m
        \\ ✓ Find the commit that broke WAL                                                                                                                           45m
        \\ ✓ p3q4r5                                                                                                                                                    1h
        \\ ✓ Summarize the build cache study                                                                                                                           3h
        \\ ✓ Check the release notes                                                                                               /srv/work                           2d
        \\   2 more
        \\
        \\ Failed or stopped  3
        \\ × Bisect the WAL regression                                                       failed · for "Fix the flaky resize …                                     15m
        \\ ■ Rename the session tables                                                       stopped · for zzzzzz                                                     30m
        \\ × Retry the flaky upload                                                          failed                                                                   50m
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
        \\ › describe a task for a new Session
        \\ ↑↓ select · enter open · ctrl+x stop · type to start a new Session
        \\
    );
}

test "render draws ASCII without colour" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "résumé the naïve café ☕ notes" } });
    const caps: Caps = .{ .unicode = false, .colour = false };
    try expectScreens(&state, caps,
        \\ rui  ~/code/rui
        \\ 6 active - 3 waiting - 2 failed - 1 stopped - 8 finished
        \\
        \\ Your conversations  3  Sessions you or your scripts messaged
        \\ * Fix the flaky resize test           working                              40s
        \\ o Review PR 412                       needs approval                        3m
        \\ + r?sum? the na?ve caf? ? notes       finished                             12m
        \\
        \\ Working  6
        \\ o Trace Host shutdown order           pending                               5s
        \\ * List unused build steps             stopping                              8s
        \\ * Audit permission paths              retrying in 12s                      30s
        \\ * Find why store tests fail           Run the logic tests                   1m
        \\ * f6g7h8                                                    ~/code/other    1m
        \\ * Profile the curl send queue                                               2m
        \\
        \\ Idle  1
        \\ o Check macOS socket cleanup                                                2h
        \\
        \\ Finished  7
        \\ + Explain provider output parsing                                          20m
        \\ ------------------------------------------------------------------------------
        \\ > describe a task for a new Session
        \\ ^v select - enter open - ctrl+x stop - type to start a new Session
        \\
    ,
        \\.NNN..nnnnnnnnnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
        \\.NNNNNNNNNNNNNNNNNNnnn..nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\rrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\.n.NNNNNNNNNNNNN.......................nnnnnnnnnnnnnn........................nn
        \\.n.NNNNNNNNNNNNNNNNNNNNNNNNNNNNN.......nnnnnnnn.............................nnn
        \\
        \\.NNNNNNNnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnn...........nnnnnnn...............................nn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnn.............nnnnnnnn..............................nn
        \\.n.nnnnnnnnnnnnnnnnnnnnnn..............nnnnnnnnnnnnnnn......................nnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnn...........nnnnnnnnnnnnnnnnnnn...................nn
        \\.n.nnnnnn....................................................nnnnnnnnnnnn....nn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnn...............................................nn
        \\
        \\.NNNNnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnn................................................nn
        \\
        \\.NNNNNNNNnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn..........................................nnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
    ,
        \\ rui  ~/code/rui
        \\ 6 active - 3 waiting - 2 failed - 1 stopped - 8 finished
        \\
        \\ Your conversations  3  Sessions you or your scripts messaged
        \\ * Fix the flaky resize test                                                       working                                                                  40s
        \\ o Review PR 412                                                                   needs approval                                                            3m
        \\ + r?sum? the na?ve caf? ? notes                                                   finished                                                                 12m
        \\
        \\ Working  6
        \\ o Trace Host shutdown order                                                       pending                                                                   5s
        \\ * List unused build steps                                                         stopping                                                                  8s
        \\ * Audit permission paths                                                          retrying in 12s                                                          30s
        \\ * Find why store tests fail                                                       Run the logic tests                                                       1m
        \\ * f6g7h8                                                                                                                ~/code/other                        1m
        \\ * Profile the curl send queue                                                                                                                               2m
        \\
        \\ Idle  1
        \\ o Check macOS socket cleanup                                                                                                                                2h
        \\
        \\ Finished  7
        \\ + Explain provider output parsing                                                                                                                          20m
        \\ + Find the commit that broke WAL                                                                                                                           45m
        \\ + p3q4r5                                                                                                                                                    1h
        \\ + Summarize the build cache study                                                                                                                           3h
        \\ + Check the release notes                                                                                               /srv/work                           2d
        \\   2 more
        \\
        \\ Failed or stopped  3
        \\ x Bisect the WAL regression                                                       failed - for "Fix the flaky resize .                                     15m
        \\ # Rename the session tables                                                       stopped - for zzzzzz                                                     30m
        \\ x Retry the flaky upload                                                          failed                                                                   50m
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
        \\ ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        \\ > describe a task for a new Session
        \\ ^v select - enter open - ctrl+x stop - type to start a new Session
        \\
    );
    var screen = try render(std.testing.allocator, &state, 200, 60, caps, 0);
    defer screen.deinit();
    for (screen.lines) |line| for (line) |span| {
        try std.testing.expectEqual(Colour.normal, span.style.colour);
        for (span.text) |byte| try std.testing.expect(byte < 0x80);
    };
    try std.testing.expect(screen.styleAt(4, 0).?.reverse);
}

test "render fits any screen size" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_][2]u16{ .{ 0, 0 }, .{ 8, 2 }, .{ 20, 5 }, .{ 40, 10 }, .{ 119, 30 }, .{ 2048, 24 }, .{ 4096, 6 } }) |size| {
        var screen = try render(std.testing.allocator, &state, size[0], size[1], .{}, 0);
        defer screen.deinit();
        try std.testing.expectEqual(@as(usize, size[1]), screen.lines.len);
        for (screen.lines) |line| for (line) |span| try std.testing.expect(span.column + span.cells <= size[0]);
        const text = try screenText(&state, size[0], size[1], .{});
        std.testing.allocator.free(text);
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

test "every line fits the screen as the terminal measures it" {
    const rockets = comptime repeated("🚀", 50);
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(1) }, .{ .label = rockets[0..max_label_bytes] }),
        session("r4t9vw", .{ .idle = ago(60) }, .{ .label = "修复存储测试在第二次运行时失败的原因并说明哪些是新问题", .workspace = "/home/d/代码/存储" }),
        session("h8q2mz", .{ .finished = ago(90) }, .{ .label = comptime repeated("👨‍👩‍👧‍👦", 4) }),
        session("m3n8pd", .{ .failed = .{ .since = test_now_s - 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = comptime repeated("Cafe\u{301} ", 14) }),
    });
    defer state.deinit();
    try typeText(&state, rockets);
    for ([_]Caps{ .{ .width = .unicode }, .{ .width = .wcwidth }, .{ .unicode = false } }) |caps| for ([_]u16{ 80, 41, 24 }) |width| {
        var screen = try render(std.testing.allocator, &state, width, 24, caps, 0);
        defer screen.deinit();
        for (screen.lines) |line| for (line) |span| try std.testing.expectEqual(gwidth.gwidth(span.text, caps.width), span.cells);
        const text = try screenText(&state, width, 24, caps);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, caps.width) <= width);
    };
}

test "untrusted text cannot reach the terminal as control bytes" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(1) }, .{ .label = "Bell\x07 and \x1b[31mred" })});
    defer state.deinit();
    try expectScreenLine(&state, 4, " ● Bell? and ?[31mred                                                        1s");
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
    var screen = try render(std.testing.allocator, &state, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .bold = true }, screen.styleAt(4, 3).?);
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(7, 3).?);
}
