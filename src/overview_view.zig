//! Session overview: every decision behind bare `rui`, over values.
//!
//! `step` applies one event (a key, a tick, a list page, a first line, a
//! stop or creation result) to the overview's `State` and returns the effects
//! its shell runs: list again, read first lines, create, open, stop or exit.
//! Row projections turn the state into styled lines. Neither reads a
//! clock or the Host: time arrives as a tick at `State.wakeAt`, the
//! animation frame as an argument, and the shell branches only on which
//! effect to run. What each
//! work state looks like lives in `rules`, what each key does in `keys`.
//! The rows are a client view over `session list`; the Host keeps no
//! overview state.
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
const theme = @import("theme.zig");
const work_line = @import("work_line.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

const Allocator = std.mem.Allocator;
pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;
pub const Token = change_ring.Token;
pub const ArchiveState = session_archive.State;
pub const ArchiveFilter = session_archive.Filter;

/// A Session reference: six characters of the Session alphabet.
pub const Reference = change_ring.Id;

/// A Label obeys the saved Bash description rule.
pub const max_label_bytes = @import("tool_presentation.zig").max_label_bytes;

/// Rows on one `session list` page.
pub const max_page_rows = 8;

/// First lines one refresh asks for.
pub const max_first_line_reads = 8;

/// Bytes of a first line kept for its title; a longer line ends in an ellipsis.
pub const max_line_bytes = session_line.max_line_bytes;

/// The shell reads this much of a first line: one byte more than a row keeps,
/// so a longer line shows that it was cut.
pub const max_line_read_bytes = max_line_bytes + 1;

/// Starts and stops the ledger holds at once.
pub const max_requests = 8;

/// The least time between two list requests.
pub const list_interval_ms = 1000;

/// How long each frame of the spinner shows: one turn in two seconds.
pub const spin_interval_ms = 200;

/// A generated request handle, as `rui request recover` takes it.
pub const max_handle_bytes = 36;

const OrderClass = enum { needs_you, working, done, queued };

pub const Selection = union(enum) { new_session, session: Reference, settings };
pub const Mark = state_marks.Mark;
pub const Colour = overview_style.Colour;
pub const Background = overview_style.Background;

/// How one work state looks and what Ctrl-X may do to it. A row that
/// `says` its work says what `work_line` says, in its tone; `word` names an
/// idle or ended state, which has no work line.
pub const Rule = struct {
    mark: Mark,

    colour: Colour,
    word: ?[]const u8 = null,

    /// The row says its work line beside its title: what needs the person
    /// or explains a wait. The mark says the rest. The line's
    /// tone colours the mark either way.
    says: bool = false,

    /// The model or a tool is at work, so your own row's mark turns the
    /// spinner. A retry counting down or a stop holds still.
    spins: bool = false,

    /// A failed row names its failure's cause.
    cause: bool = false,

    stoppable: bool,
};

/// The one per-kind table. `step` and `render` read it and switch on no kind.
pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .mark = .waiting, .colour = .normal, .word = "idle", .stoppable = false },
    .pending = .{ .mark = .queued, .colour = .quiet, .stoppable = true },
    .working = .{ .mark = .active, .colour = .ink, .spins = true, .stoppable = true },
    .retrying = .{ .mark = .active, .colour = .ink, .says = true, .stoppable = true },
    .bash = .{ .mark = .active, .colour = .ink, .says = true, .spins = true, .stoppable = true },
    .approval = .{ .mark = .needs_you, .colour = .attention, .stoppable = true },
    .stopping = .{ .mark = .active, .colour = .ink, .says = true, .stoppable = false },
    .finished = .{ .mark = .finished, .colour = .mark, .word = "finished", .stoppable = false },
    .failed = .{ .mark = .failed, .colour = .failure, .word = "failed", .cause = true, .stoppable = false },
    .stopped = .{ .mark = .stopped, .colour = .normal, .word = "stopped", .stoppable = false },
});

pub const marks = state_marks.marks;

/// Your own Session's active mark turns through the shared frames.
pub const spinner = state_marks.spinner;

pub const Action = enum {
    previous,
    next,
    select_previous,
    select_next,
    first,
    last,
    clear,
    exit,
    stop,
    archive,
    /// Right: a Session row opens as Enter opens it; other rows do nothing.
    open_session,
};

/// The one key table.
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
    .up = .previous,
    .down = .next,
    .left = null,
    .right = .open_session,
    .shift_up = .select_previous,
    .shift_down = .select_next,
    .page_up = null,
    .page_down = null,
    .home = .first,
    .end = .last,
    .ctrl_end = null,
});

test "keys list covers both screens without unbound or duplicate keys" {
    try std.testing.expectEqual(@as(?keymap.ListError, null), keymap.listError(.{ keys, @import("session_keys.zig").keys }));
}

/// Semantic list input: printable text has no editing route.
pub const Input = union(enum) { action: Action, enter, ignored };

/// The screen and paste context captured when this semantic key arrived.
/// Covered Settings admits only exit and a still-cancellable Upgrade Escape.
pub const InputDelivery = struct {
    key: Input,
    under: bool = false,
    pasted: bool = false,
};

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
    read_version: Token = .{ .instance = @splat(0), .generation = 0 },
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,
    workspace: []const u8,
    provider: Provider,
    label: ?[]const u8 = null,
    state: WorkState,

    turn: ?u64 = null,

    first_action: ?u64 = null,
    first: ?First = null,

    /// When the latest Message with no Session sender was admitted.
    from_person_at: ?u64 = null,
    last_line: ?session_list.LastLine = null,

    /// From a decoded `*const protocol.SessionRow`, whose bytes it borrows.
    pub fn of(row: anytype) Listed {
        return .{
            .reference = referenceOf(row.reference.slice()),
            .read_version = row.read_version,
            .operation = row.work.operation,
            .archive_state = row.archive_state,
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

    unanswered: bool = false,
};

/// What host-info says of the serving Host.
/// Bytes in a mebibyte, the unit memory shows in below a gibibyte.
pub const mib = 1024 * 1024;

/// Live physical memory, as the shell reads it about once a second.
pub const Memory = @import("process_memory.zig").Memory;

pub const Host = struct {
    instance: [16]u8 = @splat(0),
    /// Unix seconds.
    started_at: u64,
    slots: u64,
    slots_in_use: u64,
};

pub const StopOutcome = union(enum) {
    stopped,

    /// The Host refused it, or it was never captured.
    failed: []const u8,

    unconfirmed: []const u8,
};

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

/// A complete captured Configure outcome for an empty Session.
pub const CreateResult = union(enum) {
    /// Configure accepted creation; retain the known reference before opening.
    created: struct { reference: Reference, handle: []const u8 },

    /// Creation was rejected or never captured, so another attempt is safe.
    failed: []const u8,

    /// The capture may have reached the Host; recover it instead of duplicating.
    unconfirmed: []const u8,
};

pub const Event = union(enum) {
    input: InputDelivery,

    /// The size of the screen the shell draws next; keys read until the
    /// next one act on that screen.
    resized: Size,

    /// The shell's clock, in Unix milliseconds.
    tick: u64,
    list: ListReply,
    first_line: FirstLine,
    stop: StopResult,
    archive: ArchiveResult,
    created: CreateResult,

    /// The overview ended: later results are kept for `writeDeparture`.
    leave,

    open: Reference,

    /// The Host's facts, read as a listing starts; null when it gave none.
    host: ?Host,

    /// A memory read ended.
    memory: Memory,

    /// A needs-you row's command read ended.
    command: CommandText,

    /// Where the run app settings started stands now.
    upgrade: upgrade_status.Run,
    conversed: Conversed,

    /// A model-list read ended.
    models: ModelsRead,

    /// A write of app settings ended: the default a
    /// fresh launch would now take from them, null when they decide none.
    defaults_saved: ?Default,

    /// The app settings page asked for the Upgrade the Version row starts.
    start_upgrade,

    /// A read the open conversation applied.
    observed: Observed,
    /// The conversation now shown, or null on return to the list.
    conversation: ?Reference,

    clicked: struct { target: Click },

    /// Esc left a conversation whose original is unconfirmed. The shell
    /// sends it only while `canHoldSend` says the ledger has room.
    unconfirmed: Unconfirmed,
};

pub const Click = union(enum) {
    open: Reference,
    new_session,
    settings,
};

/// What a click on a list item names; an empty slot takes none.
pub fn clickOf(state: *const State, item: Item) ?Click {
    return switch (item) {
        .empty, .gap => null,
        .new_session => .new_session,
        .row => |at| .{ .open = state.rows.items[state.order.items[at]].reference },
    };
}

pub const Unconfirmed = struct { reference: Reference, recovery: submission.Recovery };

/// Bytes `unconfirmedLine` takes at most.
pub const max_unconfirmed_line_bytes = 80;

/// What the status bar says while a send Esc left unconfirmed waits for
/// the person: the newest one, with its recover key when it has one. Every
/// one prints on departure. Null while none waits.
pub fn unconfirmedLine(state: *const State, buffer: *[max_unconfirmed_line_bytes]u8) ?[]const u8 {
    var at = state.request_count;
    while (at > 0) {
        at -= 1;
        const request = &state.requests[at];
        if (request.kind != .send or request.status != .unknown) continue;
        // Fits 80 columns whole, key included.
        return switch (request.sent) {
            .saved => |saved| std.fmt.bufPrint(buffer, "! Not confirmed · rui request recover {s}", .{&saved.original.key}),
            else => std.fmt.bufPrint(buffer, "! {s}: send not confirmed; details on exit", .{&request.session.?}),
        } catch unreachable;
    }
    return null;
}

pub const StatusBuffer = [@max(upgrade_status.max_line_bytes, max_unconfirmed_line_bytes)]u8;

pub const StatusLine = struct { text: []const u8, colour: Colour };

/// Persistent status: an Upgrade, else the newest unconfirmed send;
/// null when all is quiet. Transient notices belong to the Footer. It
/// shows on rows of its own above the Footer, as `noticeRows` lays it out.
/// Borrows `state` and `buffer`.
pub fn statusLine(state: *const State, caps: Caps, buffer: *StatusBuffer) ?StatusLine {
    if (statusSaid(state, caps, buffer[0..upgrade_status.max_line_bytes])) |line| return line;
    const unconfirmed = unconfirmedLine(state, buffer[0..max_unconfirmed_line_bytes]) orelse return null;
    return .{ .text = unconfirmed, .colour = .attention };
}

pub const max_notice_rows = 2;

/// The rows `text` takes above the Footer at `width`, borrowed from it.
/// Each of its lines gets a row first, as many as `max_notice_rows` hold,
/// so a result's warning is never dropped for its success; rows left over
/// wrap a line too long for one at its last space that fits, so a recover
/// handle stays whole on a narrow screen.
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

/// Where `line`, too long for `room` cells, breaks: at its last space
/// before which it fits; null when it fits or has no such space.
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

/// The status's rows above the Footer, as `noticeRows` lays them out at
/// `width`, joined by newline segments; null while all is quiet.
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

/// The ledger can hold a conversation's unconfirmed original.
pub fn canHoldSend(state: *const State) bool {
    return state.request_count < max_requests;
}

/// How a model-list read ended.
pub const ModelsRead = union(enum) {
    /// The menu of the Host's lists, which the core now owns.
    menu: model_picker.Menu,

    /// The Host did not answer.
    unanswered,

    /// The Host answered with a list Rui cannot read.
    invalid,

    /// How a failed read ended: a list Rui cannot read, else no answer,
    /// which leaves the person the catalog choices until a later read.
    pub fn failed(err: anyerror) ModelsRead {
        return switch (err) {
            error.InvalidModelList, error.InvalidResponse, error.ResponseTooLarge => .invalid,
            else => .unanswered,
        };
    }
};

const ReasoningEffort = model_capability.ReasoningEffort;

/// A read the open conversation of `reference` applied, which showed its
/// work as `work`; `opening` when it is the read the conversation opened on.
pub const Observed = struct { read_version: Token, reference: Reference, work: session_work.Work, last_line: ?session_list.SavedLastLine = null, opening: bool };

/// An input in the open conversation of `reference`, whose work it shows as
/// `work`: Ctrl-X there stops it as Ctrl-X on the Session's row does, and
/// any other input clears the overview's notice.
pub const ConversationInput = union(enum) {
    other,
    stop,
    archive: ArchiveState,
    unarchive,

    cancel_upgrade,

    /// The conversation could not settle its Client work for the run, or
    /// read itself again after it: Host intents wait until another Upgrade.
    upgrade_failed,
};
pub const Conversed = struct { reference: Reference, work: Kind, input: ConversationInput };

pub const Read = struct { reference: Reference, position: u64, admission: u64 };

/// A needs-you row's waiting Action, whose command the shell reads with
/// `read_action_arguments`.
pub const CommandRead = struct { reference: Reference, action: u64 };
pub const Commands = struct {
    items: [max_first_line_reads]CommandRead = undefined,
    len: usize = 0,

    pub fn slice(self: *const Commands) []const CommandRead {
        return self.items[0..self.len];
    }
};

/// A command read's answer: the Action's command, or null when the read
/// failed or its tool has no command to show.
pub const CommandText = struct {
    reference: Reference,
    action: u64,
    text: ?[]const u8,

    unanswered: bool = false,
};
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

    /// Read the commands of these needs-you rows' waiting Actions, and
    /// answer each with `command`.
    read_commands: Commands,
    /// Copied prospective configuration; the model bytes do not borrow state.
    create: ?Default,
    open: Reference,
    focus_chat,
    open_settings,

    stop: Reference,
    archive: ArchiveRequest,

    /// Read the Host's model lists.
    list_models,

    cancel_upgrade,

    exit,
};

pub const Provider = provider_name.Provider;

/// The provider and model prospective Sessions get.
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

/// The screen in cells.
pub const Size = struct { width: u16 = 0, height: u16 = 0 };

/// A synchronous archive intent either admitted one new request or did not.
/// Existing pending or uncertain requests are not a second admission.
pub const ArchiveAdmission = enum { admitted, refused };

/// Effects are run in order; admission describes only this event's attempt.
pub const Effects = struct {
    archive_admission: ArchiveAdmission = .refused,
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

/// The overview's notice for the exact conversation, and whether Ctrl-X
/// stops it.
pub const Said = struct {
    text: ?[]const u8,
    notice: ?[]const u8 = null,
    stoppable: bool,
};

pub fn conversation(state: *const State, ref: Reference, work: Kind, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) Said {
    const line = statusSaid(state, caps, buffer);
    return .{ .text = if (line) |value| value.text else null, .notice = footerNotice(state), .stoppable = stoppable(state, ref, work) };
}

/// Persistent Upgrade state, independent of the Footer's transient reply.
/// Borrows `state` and `buffer`.
fn statusSaid(state: *const State, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) ?StatusLine {
    const upgrade: ?upgrade_status.Line = if (state.upgrade.run) |run| upgrade_status.line(run, buffer, if (caps.unicode) .unicode else .ascii) else null;
    if (upgrade) |line| if (line.lasts == .until_done) return .{ .text = line.text, .colour = .normal };
    if (upgrade) |line| if (line.lasts == .persistent)
        return .{ .text = line.text, .colour = if (line.tone == .attention) .attention else .normal };
    return null;
}

/// A creation, stop or archive `step` asked the shell to send. Its answer removes
/// it, and only while the overview shows that answer; one that may have
/// reached the Host keeps its recover handle until departure. A `send` is
/// a conversation's original left unconfirmed, held for its departure line.
/// Nothing is evicted: a full ledger refuses new requests.
pub const Request = struct {
    kind: enum { create, stop, archive, unarchive, send },

    /// The request target, or the reference returned by accepted creation.
    session: ?Reference = null,
    status: enum { pending, done, failed, unknown } = .pending,

    /// The failure code, or the handle of an unknown or accepted request.
    text: Bounded(@max(max_handle_bytes, session_work.max_code_bytes)) = .{},

    /// A `send`'s recovery, as the conversation would have printed it.
    sent: submission.Recovery = .none,
};

pub const Notice = struct {
    /// Room for a Host failure or request-recovery notice.
    bytes: [768]u8 = undefined,
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
    /// Listing membership, independent of which read last settled presentation.
    listed: bool = true,
    read_version: ?Token = null,
    operation: ?u64 = null,
    archive_state: ArchiveState = .active,

    /// Index of its Workspace in `State.workspaces`.
    workspace: u32,
    /// Listing metadata: whose sign-in or key a failure names. Only a
    /// hidden row observed before its first listing can lack this fact.
    provider: ?Provider = null,
    label: ?Bounded(max_label_bytes),
    state: WorkState,

    /// The Turn the state belongs to: which finish or failure the row shows.
    turn: ?u64,

    /// The earliest Action awaiting a decision: which wait for approval the
    /// row shows.
    first_action: ?u64,
    first: ?First,
    from_person_at: ?u64,
    last_line: ?session_list.SavedLastLine = null,
    line: Line = .unread,

    /// The command of the Action `first_action` names, while the row
    /// needs you.
    command: Line = .unread,

    /// The one accepted presentation value, whatever read supplied it.
    fn work(self: *const Row) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .operation = self.operation, .first_action = self.first_action };
    }

    /// An Action awaits a decision: alone, or beside running Bash.
    pub fn needsYou(self: *const Row) bool {
        return needsDecision(&self.state);
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

    /// The terminal's own last successful `rui auth login`, Unix seconds.
    login_at: ?u64 = null,

    archive: ArchiveFilter = .active,

    /// The in-flight traversal's filter, or null once a view change
    /// invalidates it. Returning to that filter cannot revive its pages.
    listing_archive: ?ArchiveFilter = .active,
    rows: Vec(Row) = .{},

    /// Row indices by reference.
    by_reference: Vec(Keyed) = .{},

    /// Row indices in screen order: by group, newest state first.
    order: Vec(u32) = .{},

    /// What the top lines say of the rows, kept as they change so a frame
    /// reads it without walking every row.
    summary: Summary = .{},

    /// Distinct Workspaces, owned, and their indices by `workspaceKey`.
    workspaces: Vec([]const u8) = .{},
    workspace_order: Vec(Keyed) = .{},

    /// First lines read, for rows whose `line` is `.read`: at most one per
    /// Session, since a Session's first Message never changes.
    lines: Vec(Bounded(max_line_bytes)) = .{},

    selected: Selection = .new_session,

    /// The Session whose conversation holds the terminal, if any.
    conversing: ?Reference = null,
    /// Only a Host handshake establishes an epoch; row arrival cannot rebase it.
    read_instance: ?[16]u8 = null,
    notice: ?Notice = null,

    /// Unsettled requests and retained recovery outcomes, oldest first.
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,

    /// The person left, so answers wait for `writeDeparture`.
    left: bool = false,

    /// The serving Host's facts, from the latest host-info read.
    host: ?Host = null,

    /// The latest memory read; null before the first.
    memory: ?Memory = null,

    /// The Upgrade: Upgrade's run and what the last one left Host intents.
    /// The one value both screens read.
    upgrade: session_upgrade.Upgrade = .{},

    /// The prospective default, refreshed after confirmed shared settings saves.
    default: ?Default = null,

    /// The screen the shell draws, which `layout` divides.
    size: Size = .{},

    /// The shell shows its one Host line above the input this frame. The
    /// shell owns what the line says; `layout` owns the row it takes.
    host_line: bool = false,

    /// Shared live model choices, borrowed by app settings and chat info.
    menu: model_picker.Menu = .{},

    /// Changes before a borrowed list is replaced or released.
    menu_revision: u64 = 0,

    /// How the latest shared model-list read ended.
    menu_read: model_picker_view.Read = .unread,

    /// A model-list read is in flight.
    asking_models: bool = false,

    /// The token of the last completed listing.
    token: ?Token = null,

    /// Each Session's record, by reference key: the outcome the person
    /// opened, what the last listing read, the program status record the
    /// terminal should show and the one it holds.
    seen: Vec(Seen) = .{},

    /// Entries of `seen` whose record the terminal does not hold as wanted.
    unsettled: usize = 0,

    /// Counts changes to any wanted record, so the shell knows reports it
    /// built still stand.
    status_changes: u64 = 0,

    /// Sessions the listing in progress brings to `seen`.
    arrivals: Vec(Seen) = .{},

    /// A list request is in flight.
    listing: bool = false,

    /// Rows the listing in progress has read.
    pending: Vec(Row) = .{},
    next_list_ms: u64 = 0,
    listed_at_ms: ?u64 = null,

    /// The latest listing failed. Rows remain visible but faded and still;
    /// this is list freshness, not a Host availability observation.
    list_stale: bool = false,

    /// Sort scratch reused across refreshes.
    sort_keys: Vec(SortKey) = .{},

    pub const Options = struct {
        cwd: []const u8,
        home: []const u8,
        login_at: ?u64 = null,
        default: ?Default = null,
    };

    /// The caller owns `home` for the state's lifetime.
    pub fn init(self: *State, gpa: Allocator, options: Options) error{OutOfMemory}!void {
        self.* = .{ .gpa = gpa, .home = options.home, .cwd = 0, .login_at = options.login_at, .default = options.default };
        errdefer self.deinit();
        self.cwd = try self.intern(options.cwd);
    }

    /// A failed read deliberately permits the retained/shipped fallback;
    /// an unread or still-loading list cannot yet back a stable choice.
    pub fn modelsReady(self: *const State) bool {
        if (self.asking_models) return false;
        return switch (self.menu_read) {
            .unread => false,
            .read => !self.menu.loading(),
            .unanswered, .invalid => true,
        };
    }

    /// The provider for a confirmed defaults refresh. Keep explicit and
    /// saved authority ahead of the committed choice; never invent a
    /// first-run provider.
    pub fn savedProvider(self: *const State, explicit: ?[]const u8, saved: ?[]const u8) ?[]const u8 {
        return explicit orelse saved orelse if (self.default) |binding| @tagName(binding.provider) else null;
    }

    pub fn nextBinding(self: *const State) Binding {
        return .{ .provider = if (self.default) |binding| @tagName(binding.provider) else null, .model = if (self.default) |*binding| binding.model.slice() else null };
    }
    /// The prospective provider/model, copied into an admitted creation intent.
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

    /// The keyed row, including the active conversation before it is listed.
    pub fn find(self: *const State, ref: Reference) ?*const Row {
        const at = lookup(self.by_reference.items, ref) orelse return null;
        return &self.rows.items[at];
    }

    pub fn workOf(_: *const State, row: *const Row) session_work.Work {
        return row.work();
    }

    /// The first line read for `row`, if any. It borrows the state until the
    /// next `step`.
    pub fn lineOf(self: *const State, row: *const Row) ?[]const u8 {
        return if (row.line == .read) self.lines.items[row.line.read].slice() else null;
    }

    /// When the overview next needs a `tick`, in Unix milliseconds: the next
    /// listing, a retry falling due, or the shown
    /// quota reset passing. Null while nothing falls due before the listing
    /// in flight answers. A time already past means at once. The shell keeps
    /// no timer of its own.
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

    /// Upgrade's run has not ended: the shell runs and polls its worker.
    pub fn upgrading(self: *const State) bool {
        return self.upgrade.going();
    }

    /// Host intents wait: an Upgrade runs, or the last one left them held.
    /// The one rule every Host intent and the shell's lending ask.
    pub fn holdsHost(self: *const State) bool {
        return self.upgrade.held();
    }

    fn selectedRow(self: *const State) ?*const Row {
        if (self.selected != .session) return null;
        const row = self.find(self.selected.session) orelse return null;
        return if (visible(self, row)) row else null;
    }

    /// Pending or uncertain creation blocks duplicate submissions.
    pub fn creating(self: *const State) bool {
        return blk: {
            for (self.requests[0..self.request_count]) |held| {
                if (held.kind == .create and (held.status == .pending or held.status == .unknown)) break :blk true;
            }
            break :blk false;
        };
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
        // A long failure, such as a refused environment, keeps its start,
        // cut between characters.
        var end = @min(text.len, held.text.bytes.len);
        while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
        held.text.set(text[0..end]) catch unreachable;
    }

    /// Completed activity and listing reads settle exactly the same row.
    /// Only opening acknowledges attention; program status remains listing-owned.
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
            settleRow(self, &self.rows.items[at.?], .{ .read_version = read.read_version, .work = read.work, .last_line = read.last_line });
            try arrange(self);
        };
        if (!read.opening or attention.Attention.of(read.work) == null) return;
        _ = attention.observe(&(try self.record(read.reference)).acknowledged, read.work);
    }

    fn accepts(self: *const State, version: Token) bool {
        const instance = self.read_instance orelse return false;
        return std.mem.eql(u8, &instance, &version.instance);
    }

    /// Records a listing's read of `ref`'s work and its program status
    /// record. A Session new to `seen` waits in `arrivals` until
    /// `settleArrivals`, so a listing inserts all at once.
    fn readListed(self: *State, ref: Reference, work: session_work.Work, opening: bool) error{OutOfMemory}!void {
        if (self.entryOf(ref)) |entry| {
            const now: attention.Reading = .of(work, entry.acknowledged);
            const status = attention.Status.next(entry.status, entry.listed, now, opening);
            // A later finish or wait in the same status is a record again.
            const later = status == entry.status and if (entry.listed) |was| now.after(was) else false;
            self.want(entry, status, later);
            entry.listed = now;
            return;
        }
        const now: attention.Reading = .of(work, null);
        try self.arrivals.append(self.gpa, .{ .key = referenceKey(ref), .listed = now, .status = attention.Status.next(null, null, now, opening) });
    }

    /// Merges a listing's `arrivals` into `seen`, keeping it in key order.
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

    /// `ref`'s entry in `seen`, added empty if it has none.
    fn record(self: *State, ref: Reference) error{OutOfMemory}!*Seen {
        if (self.entryOf(ref)) |entry| return entry;
        const key = referenceKey(ref);
        const at = self.seenAt(key);
        try self.seen.ensure(self.gpa, self.seen.items.len + 1);
        self.seen.insertAssumeCapacity(at, .{ .key = key });
        return &self.seen.items[at];
    }

    /// `ref`'s entry in `seen`, if it has one.
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

    /// Sets the program status record `entry`'s Session should have on the
    /// terminal: `status`, a new record when `again` even in the same one.
    fn want(self: *State, entry: *Seen, status: ?attention.Status, again: bool) void {
        if (entry.status == status and !again) return;
        const was = entry.settled();
        entry.status = status;
        entry.version +%= 1;
        self.status_changes +%= 1;
        // A new version matches no report the terminal took.
        const now = status == null and entry.delivered == .none;
        if (was and !now) self.unsettled += 1;
        if (!was and now) self.unsettled -= 1;
    }

    /// Every Session's record is on the terminal as wanted.
    pub fn statusesSettled(self: *const State) bool {
        return self.unsettled == 0;
    }

    /// The records the terminal does not hold as wanted, in key order. They
    /// borrow the state until the next `step`.
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

    /// The terminal took `record` whole.
    pub fn statusTaken(self: *State, taken: StatusRecord.Taken) void {
        const entry = self.entryOf(taken.reference) orelse return;
        const was = entry.settled();
        entry.delivered = taken.delivered;
        const now = entry.settled();
        if (was and !now) self.unsettled += 1;
        if (!was and now) self.unsettled -= 1;
    }

    /// A clear of every record may reach the terminal from now on, whole or
    /// not: what it holds of each Session that had one is unknown.
    pub fn statusesClearing(self: *State) void {
        self.recount(.unknown);
    }

    /// The terminal took a clear of every record whole.
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

/// What the counts line shows, one count per mark.
pub const Counts = struct { needs_you: usize = 0, working: usize = 0, queued: usize = 0, failed: usize = 0 };

pub const Summary = struct { counts: Counts = .{} };

const Keyed = struct { key: u64, index: u32 };

/// One Session's record: the latest state a conversation opened on, an
/// outcome the person has seen; what the last listing read; and the program status the
/// terminal should show, from listings alone, which read in order, beside
/// the one it holds. A Session no longer listed has no program status.
const Seen = struct {
    key: u64,
    acknowledged: ?attention.Attention = null,
    listed: ?attention.Reading = null,
    status: ?attention.Status = null,

    version: u16 = 0,

    /// What the terminal holds of this Session's record.
    delivered: Delivered = .none,

    fn settled(self: *const Seen) bool {
        return switch (self.delivered) {
            .none => self.status == null,
            .unknown => false,
            .version => |version| self.status != null and version == self.version,
        };
    }
};

/// What the terminal holds of a Session's record: none, the `version` of a
/// report it took whole, or a record a clear of them all may have removed.
const Delivered = union(enum) { none, unknown, version: u16 };

/// A program status record for the shell to send: `status`, or a clear.
pub const StatusRecord = struct {
    reference: Reference,
    name: []const u8,
    status: ?attention.Status,
    version: u16 = 0,

    /// What the terminal holds once it takes this report whole.
    pub const Taken = struct { reference: Reference, delivered: Delivered };

    pub fn taken(self: StatusRecord) Taken {
        return .{ .reference = self.reference, .delivered = if (self.status != null) .{ .version = self.version } else .none };
    }
};
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
        .input => |input| try listInput(state, input, &effects),
        .tick => |now_ms| try tick(state, now_ms, &effects),
        .list => |reply| switch (reply) {
            .page => |page| try listPage(state, page, &effects),
            .failed => {
                std.debug.assert(state.listing);
                state.listing = false;
                state.pending.items.len = 0;
                state.list_stale = true;
            },
        },
        .first_line => |result| try firstLine(state, result),
        .clicked => |input| if (!state.creating()) switch (input.target) {
            .open => |reference| try clickOpen(state, reference, &effects),
            .new_session => {
                state.selected = .new_session;
                try enter(state, &effects);
            },
            .settings => {
                state.selected = .settings;
                effects.add(.open_settings);
            },
        },
        .unconfirmed => |left| {
            std.debug.assert(canHoldSend(state));
            state.requests[state.request_count] = .{ .kind = .send, .session = left.reference, .status = .unknown, .sent = left.recovery };
            state.request_count += 1;
            // `unconfirmedLine` says it until the overview ends.
            state.notice = null;
        },
        .conversed => |input| {
            switch (input.input) {
                .other => state.notice = null,
                .stop => stopKey(state, .{ .reference = input.reference, .work = input.work }, &effects),
                .archive => |archive| archiveIntent(state, .{ .ask = .{ .reference = input.reference, .work = input.work, .archive = archive } }, &effects),
                .unarchive => archiveIntent(state, .{ .restore = input.reference }, &effects),
                .cancel_upgrade => if (state.upgrade.takesEscape()) effects.add(.cancel_upgrade),
                .upgrade_failed => {
                    state.upgrade.block();
                    // A run that never got to start ends cancelled.
                    if (state.upgrade.takesEscape()) effects.add(.cancel_upgrade);
                },
            }
        },
        .archive => |result| {
            const kind: @FieldType(Request, "kind") = if (result.request.archived) .archive else .unarchive;
            const at = state.pendingAt(kind, result.request.reference).?;
            const ref = result.request.reference;
            switch (result.outcome) {
                .requested => {
                    state.answer(at, .done, "");
                    // Archive confirmation is the server's facts badge, not a reply.
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
                    // Name the configured provider when creation lacks its sign-in.
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
                    // Recovery, never a duplicate creation, settles the capture.
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
        .observed => |read| try state.observe(read),
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
            state.host = facts;
            if (facts) |host| {
                if (state.read_instance) |known| if (!std.mem.eql(u8, &known, &host.instance)) {
                    state.pending.items.len = 0;
                    state.token = null;
                    // An old traversal cannot commit membership or a token
                    // after the handshake establishes the replacement Host.
                    if (state.listing) state.listing_archive = null;
                };
                state.read_instance = host.instance;
            }
        },
        .memory => |memory| state.memory = memory,
        .command => |answer| try commandRead(state, answer),
        .upgrade => |run| {
            // The shell reports only the run Upgrade asked for.
            state.upgrade.stand(run);
            if (run == .ended) {
                // An ending that is only news is a notice, which the next
                // key clears; one that holds stays as the Upgrade's line.
                var said: [upgrade_status.max_line_bytes]u8 = undefined;
                const line = upgrade_status.line(run, &said, .unicode);
                if (line.lasts == .notice) state.say(if (line.tone == .attention) .attention else .normal, "{s}", .{line.text});
                // Unless blocked the overview lists again before Host intents resume.
                state.next_list_ms = 0;
            }
        },
        .models => |read| readModels(state, read),
        .defaults_saved => |saved| {
            if (saved) |binding| state.default = binding;
        },
        .start_upgrade => startUpgrade(state),
    }
    // Semantic openings request the shared choices here, never in a shell.
    // The same admission also owns a loading list's later retry.
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

/// Takes a shared model-list answer. A failed read keeps the last menu.
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

/// What the shell prints once the terminal is restored: one line for each
/// request left in the ledger and any command the person did not see end.
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
    state.now_ms = now_ms;
    var changed = false;
    for (state.rows.items) |*row| {
        const was = std.meta.activeTag(row.state);
        if (row.read_version) |version| settleRow(state, row, .{ .read_version = version, .work = row.work(), .last_line = row.last_line });
        changed = changed or was != std.meta.activeTag(row.state);
    }
    if (changed) try arrange(state);
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.listing_archive = state.archive;
        state.next_list_ms = now_ms + list_interval_ms;
        effects.add(.{ .list = state.token });
        // A list still loading is read again with the next listing.
        if (state.menu.loading()) askModels(state, effects);
    }
}

fn askModels(state: *State, effects: *Effects) void {
    if (state.left or state.holdsHost() or state.asking_models) return;
    if (state.menu_read == .read and !state.menu.loading()) return;
    state.asking_models = true;
    effects.add(.list_models);
}

/// Whether the shell may accept an app-settings write.
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
        // A row new to the overview takes its state's start as its mark's.
        state.pending.appendAssumeCapacity(.{
            .reference = listed.reference,
            .read_version = listed.read_version,
            .operation = listed.operation,
            .archive_state = listed.archive_state,
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
    state.upgrade.reobserved();
    try readFirstLines(state, effects);
    readCommands(state, effects);
}

/// Drain the current shell traversal without accepting any of its token or
/// membership. The next existing listing starts full against the known Host.
fn rejectPage(state: *State, page: Page) void {
    state.pending.items.len = 0;
    state.list_stale = true;
    state.token = null;
    if (page.answer != null) state.listing = false else state.listing_archive = null;
}

/// Records each Session the pending listing shows. The first listing is
/// what the overview opened on.
fn readListing(state: *State) error{OutOfMemory}!void {
    const opening = state.token == null;
    // Left by a listing that failed to settle them.
    state.arrivals.items.len = 0;
    for (state.pending.items) |*incoming| {
        if (!state.archive.includes(incoming.archive_state)) continue;
        try state.readListed(incoming.reference, incoming.work(), opening);
    }
    try state.settleArrivals();
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
    const selected_at = if (state.selected == .session) position(state, state.selected.session) else null;
    const opening = state.token == null;
    if (answer.delta == .full) for (state.rows.items) |*row| {
        row.listed = false;
    };
    if (answer.delta != .not_modified) {
        // Build the union index once, not once per new Session. Reindex also
        // collapses duplicate additions before any presentation is settled.
        const before = state.rows.items.len;
        for (state.pending.items) |incoming| if (lookup(state.by_reference.items, incoming.reference) == null) {
            var row = incoming;
            row.read_version = null;
            try state.rows.append(state.gpa, row);
        };
        if (before != state.rows.items.len) try reindex(state);
    }
    if (answer.delta != .not_modified) for (state.pending.items) |*incoming| {
        const at = lookup(state.by_reference.items, incoming.reference).?;
        const row = &state.rows.items[at];
        const was = row.*;
        const same = if (incoming.first) |first| if (row.first) |known| first.admission == known.admission else false else false;
        row.archive_state = incoming.archive_state;
        row.workspace = incoming.workspace;
        row.provider = incoming.provider;
        row.label = incoming.label;
        row.first = incoming.first;
        row.from_person_at = incoming.from_person_at;
        if (!same) row.line = .unread;
        row.listed = state.archive.includes(incoming.archive_state);
        settleRow(state, row, .{ .read_version = incoming.read_version.?, .work = incoming.work(), .last_line = incoming.last_line });
        retitle(state, row, title(state, &was).text);
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
}

/// Keep the same screen position when its selected row leaves the projection.
fn reconcileSelection(state: *State, selected_at: ?usize, opening: bool) void {
    if (state.selected == .session and state.selectedRow() == null) {
        state.selected = if (selected_at) |at| if (at < state.order.items.len) .{ .session = state.rows.items[state.order.items[at]].reference } else .new_session else .new_session;
    } else if (opening and state.selected == .new_session and state.order.items.len != 0) {
        state.selected = .{ .session = state.rows.items[state.order.items[0]].reference };
    }
}

/// One presentation transition for every read. Generation orders committed
/// facts within the handshake's epoch; arrival and conversation focus do not.
/// Equal revisions retain the accepted value, normalized at the common clock.
fn settleRow(state: *const State, row: *Row, read: session_list.Snapshot) void {
    row.state = row.state.asOf(state.now_ms);
    if (!state.accepts(read.read_version)) return;
    if (row.read_version) |known| {
        if (std.mem.eql(u8, &known.instance, &read.read_version.instance) and read.read_version.generation <= known.generation) return;
    }
    if (row.first_action != read.work.first_action) row.command = .unread;
    row.read_version = read.read_version;
    row.state = read.work.state.asOf(state.now_ms);
    row.turn = read.work.turn;
    row.operation = read.work.operation;
    row.first_action = read.work.first_action;
    row.last_line = read.last_line;
}

/// The list owns membership. Only its one active conversation may need a
/// hidden row before metadata arrives; closing retires that producer first.
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

/// The terminal's record names a Session by its row's title, so a row
/// whose title is no longer `was` wants a new record.
fn retitle(state: *State, row: *const Row, was: []const u8) void {
    if (std.mem.eql(u8, title(state, row).text, was)) return;
    if (state.entryOf(row.reference)) |entry| state.want(entry, entry.status, true);
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

/// List membership and observed facts survive independently of presentation.
/// An empty Session appears only while its conversation is open.
fn visible(state: *const State, row: *const Row) bool {
    return row.listed and (row.first != null or if (state.conversing) |open| std.mem.eql(u8, &open, &row.reference) else false);
}

/// Rebuilds the flat screen order and the summary.
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
        // Priority class first, then newest; queued rows keep longest wait first.
        const since = @min(shownSince(state, row), latest);
        const age: u128 = if (queued) since else latest - since;
        state.sort_keys.appendAssumeCapacity(.{ .key = @as(u128, @backingInt(orderClass(state, row))) << 82 | age << 48 | referenceKey(row.reference), .index = @intCast(at) });
    }
    std.mem.sortUnstable(SortKey, state.sort_keys.items, {}, struct {
        fn less(_: void, a: SortKey, b: SortKey) bool {
            return a.key < b.key;
        }
    }.less);
    state.summary.counts = counts(state);
    state.order.items.len = state.sort_keys.items.len;
    for (state.order.items, state.sort_keys.items) |*slot, key| slot.* = key.index;
}

/// How many rows show each mark the counts line counts.
fn counts(state: *const State) Counts {
    var result: Counts = .{};
    for (state.rows.items) |*row| if (visible(state, row)) switch (rules.get(shownKind(state, row)).mark) {
        .needs_you => result.needs_you += 1,
        .active => result.working += 1,
        .queued => result.queued += 1,
        .failed => result.failed += 1,
        .waiting, .finished, .stopped, .newer => {},
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

/// Asks for the first lines of up to eight unlabelled rows a person can see.
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

/// Asks for the commands of up to eight needs-you rows not yet read. The
/// open conversation's row waits: that conversation reads its Action, and
/// a second read could meet the failure the conversation must report.
fn readCommands(state: *State, effects: *Effects) void {
    var reads: Commands = .{};
    for (state.order.items) |at| {
        if (reads.len == reads.items.len) break;
        const row = &state.rows.items[at];
        if (!row.needsYou() or row.command != .unread) continue;
        if (state.conversing) |open| if (std.mem.eql(u8, &open, &row.reference)) continue;
        const action = row.first_action orelse continue;
        row.command = .requested;
        reads.items[reads.len] = .{ .reference = row.reference, .action = action };
        reads.len += 1;
    }
    if (reads.len != 0) effects.add(.{ .read_commands = reads });
}

/// Keeps a command's first line for the row still waiting on that Action.
fn commandRead(state: *State, answer: CommandText) error{OutOfMemory}!void {
    const at = lookup(state.by_reference.items, answer.reference) orelse return;
    const row = &state.rows.items[at];
    if (row.command != .requested or row.first_action != answer.action) return;
    if (answer.unanswered) {
        row.command = .unread;
        return;
    }
    const bytes = answer.text orelse {
        row.command = .unavailable;
        return;
    };
    try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(bytes)));
    row.command = .{ .read = @intCast(state.lines.items.len - 1) };
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
    // A Label or the reference, not a read line: `lines` growing leaves it.
    const was = title(state, row).text;
    try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(bytes)));
    row.line = .{ .read = @intCast(state.lines.items.len - 1) };
    retitle(state, row, was);
}

const StopTarget = struct { reference: Reference, work: Kind };

/// Ctrl-X on either screen stops at once: null targets the selection,
/// otherwise the exact conversation. Stopping loses nothing the Host cannot
/// replay, so it asks nothing.
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

/// Says why `ref` takes no stop. An unconfirmed one says leaving gives the
/// details; work being stopped says so in its work line's words.
fn refuseStop(state: *State, ref: Reference, kind: Kind) void {
    if (state.openStop(ref)) |held| if (held.status == .unknown)
        return state.say(.attention, "! {s} stop unsure; details on exit", .{&ref});
    if (rules.get(kind).word) |word_| return state.say(.quiet, "{s} is already {s}.", .{ &ref, word_ });
    std.debug.assert(kind == .stopping);
    state.say(.quiet, "{s}: {s}", .{ &ref, work_line.stopping.words });
}

/// The kind `ref` shows: `stopping` while a stop of it is open, else `work`.
fn kindShown(state: *const State, ref: Reference, work: Kind) Kind {
    return if (state.openStop(ref) != null) .stopping else work;
}

/// Ctrl-X would ask to stop `ref`, whose work shows as `work`.
fn stoppable(state: *const State, ref: Reference, work: Kind) bool {
    return rules.get(kindShown(state, ref, work)).stoppable;
}

/// The kind a row shows, with a retry that has fallen due as the work it
/// became.
fn shownKind(state: *const State, row: *const Row) Kind {
    if (state.openStop(row.reference) == null and needsDecision((&row.state))) return .approval;
    return kindShown(state, row.reference, (&row.state).asOf(state.now_ms));
}

/// When the row's shown state began: a retry that has fallen due waits
/// from its due time.
fn shownSince(state: *const State, row: *const Row) u64 {
    return (&row.state).asOf(state.now_ms).since();
}

/// What a row's work is doing now, as `shownKind` reads it; null for idle or
/// ended work.
fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    return if (state.openStop(row.reference) != null) work_line.stopping else work_line.of(words, (&row.state), null, state.now_ms);
}

fn clickOpen(state: *State, reference: Reference, effects: *Effects) error{OutOfMemory}!void {
    _ = position(state, reference) orelse return;
    state.selected = .{ .session = reference };
    try enter(state, effects);
}

/// Moves the selection where the Sessions show.
fn select(state: *State, action: Action) void {
    move(state, action);
}

pub const upgrade_recovery = "! Host requests paused after Upgrade; draft retained. Upgrade or reopen with the selected Rui.";

/// Admission applies only to new Host intents, never to their completions.
fn admitHostRequest(state: *State) bool {
    if (!state.holdsHost()) return true;
    state.say(.attention, upgrade_recovery, .{});
    return false;
}

/// Upgrade checks at once; Host intents wait until it ends. The shell
/// runs the worker for as long as `upgrading` says.
fn startUpgrade(state: *State) void {
    // The run going on keeps its progress and its Esc. An ending that
    // holds is newer than any notice.
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
    switch (input) {
        .ignored => unreachable,
        .enter => try enter(state, effects),
        .action => |action| switch (action) {
            .exit => unreachable,
            .open_session => if (state.selected == .session) try enter(state, effects),
            .clear => state.notice = null,
            .stop => stopKey(state, null, effects),
            .archive => archiveIntent(state, .selected_archive, effects),
            .select_previous => select(state, .previous),
            .select_next => select(state, .next),
            else => {
                state.notice = null;
                select(state, action);
            },
        },
    }
}

fn enter(state: *State, effects: *Effects) error{OutOfMemory}!void {
    if (state.creating()) return;
    if (state.selected == .settings) {
        effects.add(.open_settings);
        return;
    }
    // Resuming the drawn open chat is navigation, not a new Host intent.
    if (state.selected == .session) if (state.conversing) |open| if (std.mem.eql(u8, &state.selected.session, &open)) {
        effects.add(.focus_chat);
        return;
    };
    if (!admitHostRequest(state)) return;
    switch (state.selected) {
        .settings => unreachable,
        .session => if (state.selectedRow()) |row| {
            effects.add(.{ .open = row.reference });
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
    effects.archive_admission = switch (intent) {
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

fn askArchive(state: *State, ref: Reference, work: Kind, archive: ArchiveState, effects: *Effects) ArchiveAdmission {
    _ = work;
    if (archive != .active) return .refused; // Its durable badge already says so.
    return archiveSession(state, .{ .reference = ref }, effects);
}

fn archiveSession(state: *State, request: ArchiveRequest, effects: *Effects) ArchiveAdmission {
    for (state.requests[0..state.request_count]) |held| {
        if (held.kind != .archive and held.kind != .unarchive) continue;
        if (held.status != .pending and held.status != .unknown) continue;
        if (std.mem.eql(u8, &held.session.?, &request.reference)) {
            state.say(.attention, "! {s} archive request {s}; details on exit.", .{ &request.reference, if (held.status == .pending) "pending" else "unsure" });
            return .refused;
        }
    }
    if (state.request(if (request.archived) .archive else .unarchive, request.reference)) {
        effects.add(.{ .archive = request });
        if (!request.archived) state.say(.quiet, "Restore request pending for {s}; waiting for the Host.", .{&request.reference});
        return .admitted;
    }
    return .refused;
}

fn changeArchiveView(state: *State, filter: ArchiveFilter, effects: *Effects) error{OutOfMemory}!void {
    if (state.archive == filter) return;
    state.archive = filter;
    if (state.listing) state.listing_archive = null;
    state.token = null;
    for (state.rows.items) |*row| row.listed = false;
    try retainRows(state);
    state.pending.items.len = 0;
    // Only the active conversation can survive this membership reset.
    // Keep its at-most-two cached lines, not the old listing's population.
    var saved: [2]Bounded(max_line_bytes) = undefined;
    var saved_count: usize = 0;
    for (state.rows.items) |*row| {
        inline for (.{ &row.line, &row.command }) |line| if (line.* == .read) {
            saved[saved_count] = state.lines.items[line.read];
            line.* = .{ .read = @intCast(saved_count) };
            saved_count += 1;
        };
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

/// What a key or command that needs a selected Session says without one.
const no_selection = "! Select a Session first.";

/// Selection includes the two ends even when there are no Sessions.
fn move(state: *State, action: Action) void {
    const order = state.order.items;
    const current: usize = switch (state.selected) {
        .new_session => 0,
        .session => |ref| if (position(state, ref)) |at| at + 1 else 0,
        .settings => order.len + 1,
    };
    const target = switch (action) {
        .first => 0,
        .last => order.len + 1,
        .next => @min(current + 1, order.len + 1),
        .previous => current -| 1,
        else => unreachable,
    };
    state.selected = if (target == 0) .new_session else if (target > order.len) .settings else .{ .session = state.rows.items[order[target - 1]].reference };
}

/// Sign-in, quota or rate-limit trouble that stops every Session reaching
/// the model, from rows alone: rows survive Host restarts, so no Host memory
/// is needed.
pub const Trouble = enum { sign_in, api_key, quota, rate_limit };
pub const Band = struct {
    trouble: Trouble,

    /// Rows retrying a rate limit.
    sessions: u32 = 0,

    /// When the provider said the quota resets, Unix seconds.
    resets_at: ?u64 = null,

    /// The provider of the newest failure the band names; null for a rate
    /// limit, which counts rows.
    provider: ?Provider = null,
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
        .backgrounds = .init(.{ .ground = hex("#f3eee2"), .bar = hex("#e7dfcc"), .selection = hex("#dcdcec"), .hover = hex("#e1dddc"), .band = hex("#f2c200") }),
    },
    .night = .{
        .colours = .init(.{ .strong = hex("#f6f1e4"), .ink = hex("#e2dccb"), .normal = hex("#bdb8a9"), .quiet = hex("#9d9bb0"), .mark = hex("#6e7396"), .rule = hex("#2a3157"), .attention = hex("#f2c200"), .failure = hex("#ff8f7d"), .on_band = hex("#141414") }),
        .backgrounds = .init(.{ .ground = hex("#121833"), .bar = hex("#1a2142"), .selection = hex("#2b3568"), .hover = hex("#222b55"), .band = hex("#f2c200") }),
    },
});

/// The same tables as 256-colour entries.
pub const indexed = blk: {
    @setEvalBranchQuota(400_000);
    var tables = std.enums.EnumArray(Skin, struct { colours: std.enums.EnumArray(Colour, u8), backgrounds: std.enums.EnumArray(Background, u8) }).initUndefined();
    for (std.enums.values(Skin)) |skin| {
        const palette = palettes.get(skin);
        var table = tables.getPtr(skin);
        for (std.enums.values(Colour)) |role| table.colours.set(role, theme.nearestIndex(palette.colours.get(role)));
        for (std.enums.values(Background)) |role| table.backgrounds.set(role, theme.nearestIndex(palette.backgrounds.get(role)));
    }
    break :blk tables;
};

pub const Caps = struct {
    /// Unicode marks and text; false draws ASCII only, a cell a character.
    unicode: bool = true,
    devanagari: bool = false,

    /// How the terminal measures Unicode text, from its report.
    width: gwidth.Method = .wcwidth,

    /// How many colours the terminal draws.
    depth: Depth = .direct,

    /// The terminal's background as it answered OSC 11; null without an
    /// answer.
    background: ?Rgb = null,

    /// `none` under NO_COLOR draws in the terminal's own colours with bold,
    /// dim, reverse and underline; `indexed` uses the nearest 256-colour entries;
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

pub const Style = overview_style.Style;
pub const Segment = overview_style.Segment;

pub const Span = struct {
    column: u16,

    /// Display cells `text` takes.
    cells: u16,
    text: []const u8,
    style: Style,
};

const Glyphs = struct { prompt: []const u8, dot: []const u8, rule: []const u8, ellipsis: []const u8, arrows: []const u8, sides: []const u8, up: []const u8, down: []const u8, newline: []const u8 };
const unicode_glyphs: Glyphs = .{ .prompt = "›", .dot = work_line.glyphs.get(.unicode).dot, .rule = "─", .ellipsis = work_line.glyphs.get(.unicode).ellipsis, .arrows = "↑↓", .sides = "←→", .up = "↑", .down = "↓", .newline = "↵" };
const ascii_glyphs: Glyphs = .{ .prompt = ">", .dot = work_line.glyphs.get(.ascii).dot, .rule = "-", .ellipsis = work_line.glyphs.get(.ascii).ellipsis, .arrows = "^v", .sides = "<>", .up = "^", .down = "v", .newline = "|" };

pub const Layout = struct {
    top: u16 = 0,
    list: Rows = .{},

    /// The pinned tail under the list: its rule and the Settings row.
    settings: Rows = .{},

    /// The shell's Host line between the Settings tail and the input, when
    /// it shows.
    host: Rows = .{},

    /// The bottom stack's first row: status lines and one footer, not an editor.
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
    const top: u16 = @intCast(@min(topRows(state), height));
    const input = @max(top, height -| (statusRows(state) + 1));
    const host = @max(top, input -| @intFromBool(state.host_line));
    const settings = @max(top, host -| settings_rows);
    return .{ .top = top, .list = .{ .start = top, .end = settings }, .settings = .{ .start = settings, .end = host }, .host = .{ .start = host, .end = input }, .input = input };
}

/// The Settings tail's rows: its rule and the Settings row.
const settings_rows = 2;

/// Rows the status takes above the Footer: none while all is quiet.
fn statusRows(state: *const State) u16 {
    var buffer: StatusBuffer = undefined;
    const line = statusLine(state, .{}, &buffer) orelse return 0;
    var rows: [max_notice_rows][]const u8 = undefined;
    return @intCast(noticeRows(line.text, state.size.width, .{}, &rows).len);
}

/// Provider bands, as `headerSegments` draws them.
fn topRows(state: *const State) usize {
    return @intFromBool(band(state) != null) + @as(usize, @intFromBool(showsNewSession(state)));
}

/// One line's spans, placed left to right at their columns, its text made
/// terminal-safe and clipped to the room it has. Each span keeps the role
/// it was given; only `widget_style.of` normalizes that role for terminal
/// capabilities when the widget draws it.
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

    /// The glyph set `work_line` draws this screen's clocks with.
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

    /// Moves to `column`, filling the cells passed when `wanted` shows a
    /// ground of its own.
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

    /// Puts `bytes` at `column` within `limit` cells, ending in an ellipsis
    /// when cut. Returns the cells it took.
    fn put(self: *Spans, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        return self.putKept(column, bytes, limit, wanted, .head);
    }

    /// Like `put`, keeping the end of `bytes` when it is cut.
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

    /// Puts `bytes` so they end at `end`.
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

/// `bytes` made terminal-safe and clipped to `room` cells, as `Pieces`
/// shows it, with an ellipsis where it was cut: at the end, or at the
/// start when keeping the tail.
pub fn fitted(arena: Allocator, caps: Caps, bytes: []const u8, room: usize, keep: Keep) error{OutOfMemory}!Piece {
    if (room == 0) return .{ .bytes = "", .cells = 0 };
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

/// The cells `bytes` takes as `Pieces` shows it.
fn measured(caps: Caps, glyphs: Glyphs, bytes: []const u8) usize {
    var total: usize = 0;
    var pieces: Pieces = .{ .bytes = bytes, .caps = caps, .glyphs = glyphs };
    while (pieces.next()) |piece| total += piece.cells;
    return total;
}

/// The glyph shown for a code point that cannot reach the terminal: a
/// control character or an invalid byte, or without Unicode anything past
/// ASCII.
fn standIn(caps: Caps, glyphs: Glyphs, codepoint: u21) ?[]const u8 {
    if (codepoint == '\n') return glyphs.newline;
    // A tab shows as one space, as in a conversation.
    if (codepoint == '\t') return " ";
    if (TerminalText.isControl(codepoint) or codepoint == replacement) return "?";
    if (!caps.unicode and codepoint > 0x7e) return "?";
    return null;
}

pub const Piece = struct { bytes: []const u8, cells: usize };

/// Text as the terminal draws it: whole grapheme clusters, measured as the
/// terminal measures them, with a one-cell stand-in for each code point
/// that cannot reach it.
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
        // Printable ASCII before ASCII or the end is a whole cluster of one
        // cell under every method; this keeps long ASCII text cheap.
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

/// The list's line while it has no rows: loading, or the empty view.
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

/// A full-width alarm line, dark on yellow.
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
        // Each names the provider of the newest failure it shows.
        .sign_in => sign_in: {
            if (trouble.provider.?.login()) |command| {
                const run = try std.fmt.allocPrint(built.arena, "Sign-in expired. Run {s}.", .{command});
                if (run.len <= built.width -| 2) break :sign_in run;
            }
            // No command, or the narrow list pane cannot hold it whole: the
            // name alone, which fits.
            break :sign_in try std.fmt.allocPrint(built.arena, "{s} sign-in expired.", .{trouble.provider.?.shown()});
        },
        .api_key => if (trouble.provider.?.login()) |command|
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Run {s}, then rui host pause.", .{ trouble.provider.?.shown(), command })
        else
            try std.fmt.allocPrint(built.arena, "{s} API key rejected. Save a new key, then rui host pause.", .{trouble.provider.?.shown()}),
        .quota => quota: {
            const used = if (trouble.resets_at) |at|
                try std.fmt.allocPrint(built.arena, "Quota used up. Resets in {s}.", .{ageText(&buffer, at -| now_ms / 1000)})
            else
                "Quota used up.";
            if (trouble.provider.?.usage()) |usage| {
                const managed = try std.fmt.allocPrint(built.arena, "{s} {s}", .{ used, usage });
                if (managed.len <= built.width -| 2) break :quota managed;
            }
            // No place to raise the limit, or the narrow list pane cannot
            // hold it whole: the limit alone, which fits.
            break :quota used;
        },
        .rate_limit => try std.fmt.allocPrint(built.arena, "Rate limited. {d} Session{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
    });
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

/// Items use the same words and click meanings whether pinned or scrolled.
pub const Item = union(enum) { new_session, gap, row: usize, empty };

const new_session_name = "New Session";

/// The new-conversation control belongs to the overview, never a chat sidebar.
pub fn showsNewSession(state: *const State) bool {
    return state.conversing == null;
}

/// A blank line separates the pinned control from Sessions at the scroll origin.
/// It scrolls away, leaving the above marker immediately under the pinned row.
pub fn firstRowLine(state: *const State) usize {
    return @intFromBool(showsNewSession(state));
}

pub fn listLength(state: *const State) usize {
    return state.order.items.len + firstRowLine(state);
}

/// Pinned controls have no scrollable list line.
pub fn selectedLine(state: *const State) ?usize {
    const ref = selectedSession(state) orelse return null;
    return if (position(state, ref)) |at| at + firstRowLine(state) else null;
}

/// Keyboard list focus projects its selected row; otherwise the open chat
/// supplies the inactive highlight. The shell reads no parallel predicates.
pub fn focusedLine(state: *const State, list_focused: bool) ?usize {
    if (!list_focused) return selectedLine(state);
    return switch (state.selected) {
        .session => |ref| if (position(state, ref)) |at| at + firstRowLine(state) else null,
        .new_session, .settings => null,
    };
}

/// The open chat owns sidebar selection, independently of list navigation.
/// Until its canonical listing arrives there is no projected line to select.
fn selectedSession(state: *const State) ?Reference {
    return state.conversing orelse switch (state.selected) {
        .session => |ref| ref,
        .new_session, .settings => null,
    };
}

fn rowSelected(state: *const State, row: *const Row) bool {
    const ref = selectedSession(state) orelse return false;
    return std.mem.eql(u8, &ref, &row.reference);
}

pub fn listItem(state: *const State, line: usize) ?Item {
    const first = firstRowLine(state);
    if (line < first) return .gap;
    return if (line - first < state.order.items.len) .{ .row = line - first } else null;
}

/// First line: a mark, the whole available name, and an age at the edge.
pub fn rowSegments(arena: Allocator, state: *const State, at: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    const row = &state.rows.items[state.order.items[at]];
    const quiet = rowQuiet(state, row);
    const rule = rules.get(shownKind(state, row));
    built.begin();
    const mark = marks.get(rule.mark);
    const glyph = if (markSpins(state, .{ .row = at }, caps)) spinner[frame % spinner.len] else if (caps.unicode) mark.unicode else mark.ascii;
    var words: [work_line.max_words_bytes]u8 = undefined;
    const progress = workLine(&words, state, row);
    const colour = if (progress) |line| switch (line.tone) {
        .normal => rule.colour,
        .quiet => Colour.quiet,
        .attention => Colour.attention,
    } else rule.colour;
    _ = try built.put(1, glyph, 1, .{ .colour = colour, .dim = quiet });
    const named = title(state, row);
    const name = switch (row.archive_state) {
        .active, .archived => named.text,
        .archiving => try std.fmt.allocPrint(arena, "[Archiving] {s}", .{named.text}),
    };
    var buffer: [8]u8 = undefined;
    const age = if (orderClass(state, row) == .queued) "" else ageText(&buffer, (state.now_ms / 1000) -| (&row.state).since());
    const end = width -| 1;
    const age_cells = @min(built.measure(age), end -| 3);
    const name_end = end -| age_cells -| @intFromBool(age_cells != 0);
    const selected = rowSelected(state, row);
    // The archived-only list already supplies this fact; mixed lists do not.
    const archived = if (row.archive_state == .archived and state.archive != .archived)
        if (caps.unicode) " · archived" else " . archived"
    else
        "";
    const name_room: usize = name_end -| 3;
    const name_cells = try built.put(3, name, name_room -| built.measure(archived), .{ .colour = if (selected) .strong else .normal, .bold = selected, .dim = quiet });
    _ = try built.put(3 + name_cells, archived, name_room -| name_cells, .{ .colour = .quiet, .dim = quiet });
    _ = try built.put(end -| age_cells, age, age_cells, .{ .colour = .quiet, .dim = quiet });
    return segmentsOf(arena, try built.finish(), width, .{ .dim = quiet });
}

/// Second line: terminal-safe detail, then a non-overlapping folder and gap.
pub fn rowSecondSegments(arena: Allocator, state: *const State, at: usize, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    built.begin();
    const row = &state.rows.items[state.order.items[at]];
    const quiet = rowQuiet(state, row);
    const folder = folderOf(state, row);
    const end = width -| 1;
    const folder_cells = @min(built.measure(folder), end -| 3);
    const folder_start = end -| folder_cells;
    var buffer: [max_second_line_bytes]u8 = undefined;
    _ = try built.put(3, secondLine(state, row, &buffer), folder_start -| 1 -| 3, .{ .colour = .quiet, .dim = quiet });
    _ = try built.putTail(folder_start, folder, folder_cells, .{ .colour = .quiet, .dim = quiet });
    return segmentsOf(arena, try built.finish(), width, .{ .dim = quiet });
}

/// Whether `item`'s mark turns with the frame. Your own Session at work
/// turns the spinner, every one in step; any other mark holds still. Only
/// Unicode in colour spins, and a faded row's state is stale, so it holds
/// still.
pub fn markSpins(state: *const State, item: Item, caps: Caps) bool {
    if (item != .row or state.list_stale or !caps.unicode or caps.depth == .none) return false;
    const row = &state.rows.items[state.order.items[item.row]];
    return yours(row) and rules.get(shownKind(state, row)).spins;
}

/// The person wrote in this chat. The open empty chat is theirs even before
/// its first Message is admitted.
fn yours(row: *const Row) bool {
    return row.first == null or row.from_person_at != null;
}

/// The row needs the person: it sorts under Needs you, or its work failed.
fn needsPerson(state: *const State, row: *const Row) bool {
    return orderClass(state, row) == .needs_you or row.state == .failed;
}

/// A chat you never wrote in recedes unless it needs you.
fn rowQuiet(state: *const State, row: *const Row) bool {
    return !yours(row) and !needsPerson(state, row);
}

/// Provider recovery bands above the list. Archive views remain reachable
/// through /sessions, without a counts row or a separate clickable view name.
pub fn headerSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    const trouble = band(state) orelse return &.{};
    var built: Spans = .of(arena, caps, width);
    return segmentsOf(arena, try providerBand(&built, trouble, state.now_ms), width, .{});
}

pub const ListRow = struct { segments: []const Segment, heading: bool, selected: bool };

pub fn listSegments(arena: Allocator, state: *const State, item: Item, width: u16, caps: Caps, frame: u64) error{OutOfMemory}!ListRow {
    if (item == .row) {
        const row = &state.rows.items[state.order.items[item.row]];
        return .{ .segments = try rowSegments(arena, state, item.row, width, caps, frame), .heading = false, .selected = rowSelected(state, row) };
    }
    var built: Spans = .of(arena, caps, width);
    const spans = switch (item) {
        .new_session => new: {
            built.begin();
            _ = try built.put(2, "+", width -| 2, .{ .colour = .ink });
            _ = try built.put(3, " " ++ new_session_name, width -| 3, .{});
            break :new try built.finish();
        },
        .gap => &.{},
        .empty => try emptyLine(&built, state),
        .row => unreachable,
    };
    return .{ .segments = try segmentsOf(arena, spans, width, .{}), .heading = item == .empty, .selected = item == .new_session and state.selected == .new_session };
}

/// Enter opens the selected identity; no overview facts or focus domain exist.
pub fn footerRight(state: *const State) []const u8 {
    if (state.upgrade.takesEscape()) return "esc cancels";
    if (state.creating() or (state.holdsHost() and state.selected != .settings)) return "";
    return "enter open";
}

/// The transient reply belongs to the footer, not persistent status rows.
pub fn footerNotice(state: *const State) ?[]const u8 {
    return if (state.notice) |*notice| notice.text() else null;
}

/// `spans` as segments that fill `width` cells, gaps in `fill`.
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

/// Empty chats use the pinned control's words; admitted conversations use
/// their Label, first Message line, or reference in the usual precedence.
fn title(state: *const State, row: *const Row) session_line.Name {
    if (row.first == null) return .{ .text = new_session_name, .hint = false };
    return session_line.name(if (row.label) |*text| text.slice() else null, state.lineOf(row), &row.reference);
}

/// Maximum scratch space for a row's second line.
pub const max_second_line_bytes = @max(work_line.max_words_bytes + work_line.max_clock_bytes, session_work.max_code_bytes);

pub fn secondLine(state: *const State, row: *const Row, buffer: *[max_second_line_bytes]u8) []const u8 {
    if (state.openStop(row.reference) != null) return "Stopping";
    if (needsDecision(&row.state)) {
        return switch (row.command) {
            .read => |index| state.lines.items[index].slice(),
            else => "",
        };
    }
    const kind = shownKind(state, row);
    const rule = rules.get(kind);
    if (rule.says or rule.spins) {
        var words: [work_line.max_words_bytes]u8 = undefined;
        const line = workLine(&words, state, row) orelse return "";
        if (kind == .working) return "Thinking";
        if (kind == .stopping) return work_line.stopping.words;
        var clock: [work_line.max_clock_bytes]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ line.words, work_line.clockText(&clock, line.clock, .row, .unicode) }) catch unreachable;
    }
    if (kind == .pending) return "Queued";
    if (row.last_line) |*last| if (last.text) |*text| return text.slice();
    return switch ((&row.state).*) {
        .failed => |*failed| causeOf(failed.code.slice()),
        .stopped => "Stopped",
        else => "",
    };
}

pub fn folderOf(state: *const State, row: *const Row) []const u8 {
    const path = std.mem.trimEnd(u8, state.workspaces.items[row.workspace], "/");
    const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    return path[start..];
}

/// The shared cause words only: destinations remain chat-only, so the
/// provider, which picks only a destination, is not asked.
fn causeOf(code: []const u8) []const u8 {
    return state_marks.cause(code, null).words;
}

test "overview failure causes share plain words without chat destinations" {
    const cases = .{
        .{ "provider_policy", "Refused by the provider" },
        .{ "provider_quota", "Out of quota" },
        .{ "provider_plan", "Model not in plan" },
        .{ "provider_model_unavailable", "Model not served" },
        .{ "provider_http_401", "Sign-in expired" },
        .{ "provider_api_key_rejected", "API key rejected" },
        .{ "ResourceExceeded", "Context full" },
        .{ "provider_tls_verification_failed", "Provider unreachable" },
        .{ "retry_exhausted", "Retries ran out" },
        .{ "cancelled", "Stopped" },
        .{ "provider_http_500", "Provider refused the request" },
        .{ "unknown_code", "Something went wrong" },
        .{ "malformed_provider_output", "Model reply unreadable" },
    };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    inline for (cases) |case| {
        seen.insert(failure_class.of(case[0]));
        try std.testing.expectEqualStrings(case[1], causeOf(case[0]));
    }
    try std.testing.expect(seen.eql(.full));
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
    _ = try step(&state, .{ .host = .{ .instance = testToken(0).instance, .started_at = test_now_s, .slots = 2, .slots_in_use = 0 } });
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
    read_version: Token = testToken(0),
    archive_state: ArchiveState = .active,
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

/// Lets the list interval pass and answers the request it brings.
fn refresh(state: *State, delta: Delta, since: Token, rows: []const Listed) !Effects {
    const asked = try step(state, .{ .tick = state.now_ms + list_interval_ms });
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expect(asked.items[0] == .list);
    return respond(state, delta, since, rows);
}

/// Renders `state` at `width` by `height`, which the shell steps before it
/// draws.
var test_edits: u32 = 0;

fn press(state: *State, action: Action) !Effects {
    return step(state, .{ .input = .{ .key = .{ .action = action } } });
}
fn submit(state: *State) !Effects {
    return step(state, .{ .input = .{ .key = .enter } });
}

/// One needs-you row's command read.
fn commandReadOf(ref: *const [6]u8, action: u64) Effect {
    var reads: Commands = .{};
    reads.items[0] = .{ .reference = ref.*, .action = action };
    reads.len = 1;
    return .{ .read_commands = reads };
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
            .archive => |request| {
                try std.testing.expectEqualStrings(&request.reference, &got.archive.reference);
                try std.testing.expectEqual(request.archived, got.archive.archived);
            },
            .read_commands => |reads| {
                try std.testing.expectEqual(reads.len, got.read_commands.len);
                for (reads.slice(), got.read_commands.slice()) |x, y| {
                    try std.testing.expectEqualStrings(&x.reference, &y.reference);
                    try std.testing.expectEqual(x.action, y.action);
                }
            },
            .list_models, .cancel_upgrade, .open_settings, .focus_chat, .exit => {},
            .create => |binding| {
                try std.testing.expectEqual(binding == null, got.create == null);
                if (binding) |expected_binding| try std.testing.expect(expected_binding.eql(&got.create.?));
            },
        }
    }
}

/// The core's raw notice value. Production Footer rendering is covered by
/// Overview's widget tests, not by the logical list/status Frame below.
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
        var list_count: usize = 0;
        while (listItem(state, list_count) != null) : (list_count += 1) {}
        const lines = try gpa.alloc([]const Segment, top.len + list_count * 2 + max_notice_rows);
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
        if (showsNewSession(state)) {
            lines[count] = (try listSegments(gpa, state, .new_session, width, caps, frame)).segments;
            count += 1;
        }
        var list_at: usize = 0;
        while (listItem(state, list_at)) |item| : (list_at += 1) {
            lines[count] = (try listSegments(gpa, state, item, width, caps, frame)).segments;
            count += 1;
            if (item != .row) continue;
            lines[count] = try rowSecondSegments(gpa, state, item.row, width, caps);
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
        // A terminal shows trailing blanks as nothing.
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

    /// The style of the cell at `row`, `column`, as the terminal measures
    /// each segment's text; null for a blank on the ground, which shows no
    /// style.
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

/// Twenty Sessions in every order class, as the Rui Khadi mock shows them.
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

/// One row of each kind, in Unicode and ASCII.
const kind_cases = [_]struct { state: WorkState, unicode: []const u8, ascii: []const u8, colour: Colour, stoppable: bool }{
    .{ .state = .{ .idle = ago(7200) }, .unicode = " ○ Write the notes                                                           2h", .ascii = " o Write the notes                                                           2h", .colour = .normal, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .unicode = " ◌ Write the notes", .ascii = " : Write the notes", .colour = .quiet, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .unicode = " ⠹ Write the notes                                                          40s", .ascii = " * Write the notes                                                          40s", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .unicode = " ⠹ Write the notes                                                          30s", .ascii = " * Write the notes                                                          30s", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(session_work.max_description_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .unicode = " ⠹ Write the notes                                                           1m", .ascii = " * Write the notes                                                           1m", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .unicode = " ? Write the notes                                                           3m", .ascii = " ? Write the notes                                                           3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .unicode = " ⠹ Write the notes                                                           8s", .ascii = " * Write the notes                                                           8s", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .unicode = " ✓ Write the notes                                                          12m", .ascii = " + Write the notes                                                          12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .unicode = " × Write the notes                                                           3h", .ascii = " x Write the notes                                                           3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .unicode = " ■ Write the notes                                                           2d", .ascii = " # Write the notes                                                           2d", .colour = .normal, .stoppable = false },
};

var test_said: [upgrade_status.max_line_bytes]u8 = undefined;

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
            try std.testing.expectEqualStrings("  + New Session", lines.next().?);
            try std.testing.expectEqualStrings("", lines.next().?);
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
        // The mark takes its colour, and the word one only when it needs
        // the person or is quiet. (GroupedList paints the selection.)
        state.selected = .new_session;
        var unselected = try Frame.of(&state, 80, 24, .{}, 0);
        defer unselected.deinit();
        // The sender/work domain below owns whole-row dim expectations.
        try std.testing.expectEqual(case.colour, unselected.styleAt(2, 1).?.colour);
        try std.testing.expectEqual(Colour.quiet, unselected.styleAt(3, 79 - "rui".len).?.colour);
    }
}

test "a description's controls read escaped in its row's words, as its call row shows them" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(session_work.max_description_bytes, "Run\t\x1b[2J\u{202e}tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{session("k7m2qx", bash, .{ .label = "Write the notes" })});
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try expectLine(try rowSecondSegments(arena.allocator(), &state, 0, 80, .{}), 80, &.{ "Run\\t\\x1b[2J\\u202etests", "rui" });
}

test "a retry that has fallen due reads as queued in its group, mark and colour" {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{session("k7m2qx", due, .{ .label = "Write the notes" })});
    defer state.deinit();
    state.selected = .new_session;
    const text = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "Write the notes").?;
    const start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n').?;
    try std.testing.expectEqualStrings(" ◌ Write the notes", text[start..end]);
    try std.testing.expect(std.mem.indexOf(u8, text, " Active ·") == null);
    var screen = try Frame.of(&state, 80, 24, .{ .depth = .none }, 0);
    defer screen.deinit();
    // The core retains the pending mark's role, even without colour.
    try std.testing.expectEqual(Style{ .colour = .quiet, .dim = true }, screen.styleAt(2, 1).?);
}

test "overview rows draw a flat order without headings" {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = try screenText(&state, 80, 40, .{});
    defer std.testing.allocator.free(text);
    inline for (.{ " Needs you ·", " Yours ·", " Active ·", " Idle ·", " Finished ·", " Stopped or failed ·", " more" }) |heading| try std.testing.expect(std.mem.indexOf(u8, text, heading) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ New Session") != null);
    try std.testing.expectEqual(mixed.len + firstRowLine(&state), listLength(&state));
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
    // Newest wait first, regardless of who messaged the Session.
    try expectOrder(&state, &.{ "Theirs, asking", "Mine, asking", "Theirs, asking beside Bash", "Theirs, running Bash", "Mine, thinking", "Theirs, finished" });
    // The list opens on what needs you.
    try std.testing.expectEqualStrings("a5k1ng", &state.selected.session);
}

test "overview queued rows follow done and work, longest wait first" {
    // A retry already due waits for a slot as a queued Session does.
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

/// The row titled `label` as `rowSegments` gives it at `width`, unselected.
fn rowOf(arena: Allocator, state: *State, label: []const u8, width: u16, caps: Caps) ![]const Segment {
    const selected = state.selected;
    state.selected = .new_session;
    defer state.selected = selected;
    for (state.order.items, 0..) |index, at| {
        const row = &state.rows.items[index];
        if (row.label != null and std.mem.eql(u8, row.label.?.slice(), label)) return rowSegments(arena, state, at, width, caps, 0);
    }
    return error.TestUnexpectedResult;
}

/// What a row says, as its non-blank segments, and the cells it fills.
fn expectRow(segments: []const Segment, width: u16, expected: []const struct { []const u8, Colour }) !void {
    var said: usize = 0;
    var cells: usize = 0;
    for (segments) |segment| {
        // One cell per code point: these rows hold no wide text.
        for (segment.text) |byte| cells += @intFromBool(byte & 0xc0 != 0x80);
        const text = std.mem.trim(u8, segment.text, " ");
        if (text.len == 0) continue;
        try std.testing.expect(said < expected.len);
        try std.testing.expectEqualStrings(expected[said][0], text);
        try std.testing.expectEqual(expected[said][1], segment.style.colour);
        said += 1;
    }
    try std.testing.expectEqual(expected.len, said);
    // Padded to the width, so a list draws it as one row.
    try std.testing.expectEqual(@as(usize, width), cells);
}

test "row segments say each state with its mark, and words only for a cause or a wait's countdown" {
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
    // Needs you: `?` in the attention colour and no word, beside running
    // Bash too; the command comes from the Action once read.
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
    try expectRow(try rowOf(a, &state, "Asking beside Bash", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Asking beside Bash", .normal }, .{ "1m", .quiet } });
    // Queued: a dim `◌`, the title and the wait, no word.
    try expectRow(try rowOf(a, &state, "Check install script", 100, .{}), 100, &.{ .{ "◌", .quiet }, .{ "Check install script", .normal } });
    // A rate limit counts down without the attempt number.
    try expectRow(try rowOf(a, &state, "Investigate retry storm", 100, .{}), 100, &.{ .{ "⠹", .attention }, .{ "Investigate retry storm", .normal }, .{ "30s", .quiet } });
    // A failure names its shared cause in the failure colour;
    // a stop says nothing beyond its mark, and neither names the
    // Session that started it.
    try expectRow(try rowOf(a, &state, "Benchmark memory", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Benchmark memory", .normal }, .{ "20m", .quiet } });
    try expectRow(try rowOf(a, &state, "Odd failure", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Odd failure", .normal }, .{ "1m", .quiet } });
    try expectRow(try rowOf(a, &state, "Stopped by me", 100, .{}), 100, &.{ .{ "■", .normal }, .{ "Stopped by me", .normal }, .{ "1m", .quiet } });
}

test "row segments drop the detail column on a narrow screen and keep mark, title and age" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var state = try opened(&.{
        session("f4iled", .{ .failed = .{ .since = test_now_s - 20 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .label = "Benchmark memory" }),
    });
    defer state.deinit();
    state.selected = .new_session;
    try expectRow(try rowOf(arena.allocator(), &state, "Benchmark memory", 40, .{}), 40, &.{ .{ "×", .failure }, .{ "Benchmark memory", .normal }, .{ "20m", .quiet } });
}

/// The style of the segment that holds `needle`.
fn styleOf(segments: []const Segment, needle: []const u8) !Style {
    for (segments) |segment| if (std.mem.indexOf(u8, segment.text, needle) != null) return segment.style;
    return error.TestUnexpectedResult;
}

/// What a line of segments says, its non-blank pieces in order.
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
    // Too narrow for the command, the band still fits the 40-column list
    // pane whole.
    var state = try opened(&rows);
    defer state.deinit();
    const narrow = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &state, 40, .{}));
    try std.testing.expectEqualStrings("ChatGPT sign-in expired.", std.mem.trim(u8, narrow, " "));
    // A device-code chat's command fits a 60-column screen whole, and the
    // 40-column pane falls back to its name.
    var device = try opened(rows[0..1]);
    defer device.deinit();
    const sixty = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &device, 60, .{}));
    try std.testing.expectEqualStrings("Sign-in expired. Run rui auth login chatgpt --device-code.", std.mem.trim(u8, sixty, " "));
    const forty = try segmentText(arena.allocator(), try headerSegments(arena.allocator(), &device, 40, .{}));
    try std.testing.expectEqualStrings("ChatGPT (device code) sign-in expired.", std.mem.trim(u8, forty, " "));
}

test "a needs-you row reads its waiting Action's command once, and again only when the Action changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    const asking = session("a5k1ng", .{ .approval = ago(120) }, .{ .label = "Fix flaky store test", .turn = 3, .first_action = 41 });
    const working = session("w00001", .{ .working = ago(40) }, .{ .label = "Working", .turn = 2 });
    const listed = try respond(&state, .full, testToken(1), &.{ asking, working });
    // One read, for the row that needs you; none for the working row.
    var asked: ?Commands = null;
    for (listed.slice()) |effect| if (effect == .read_commands) {
        asked = effect.read_commands;
    };
    try std.testing.expectEqual(@as(usize, 1), asked.?.len);
    try std.testing.expectEqualStrings("a5k1ng", &asked.?.items[0].reference);
    try std.testing.expectEqual(@as(u64, 41), asked.?.items[0].action);
    // Until it answers, the row says nothing in its detail column.
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
    // A command's first line shows, in the row's normal ink.
    _ = try step(&state, .{ .command = .{ .reference = "a5k1ng".*, .action = 41, .text = "zig build test-store\n-Dfilter=retry" } });
    state.selected = .new_session;
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
    // The same Action listed again asks nothing.
    for ((try refresh(&state, .changed, testToken(2), &.{asking})).slice()) |effect| try std.testing.expect(effect != .read_commands);
    // A later Action asks again; an answer for the earlier one is dropped.
    var next = asking;
    next.first_action = 42;
    var again: ?Commands = null;
    for ((try refresh(&state, .changed, testToken(3), &.{next})).slice()) |effect| if (effect == .read_commands) {
        again = effect.read_commands;
    };
    try std.testing.expectEqual(@as(u64, 42), again.?.items[0].action);
    _ = try step(&state, .{ .command = .{ .reference = "a5k1ng".*, .action = 41, .text = "stale" } });
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
    // No answer asks again at the next listing.
    _ = try step(&state, .{ .command = .{ .reference = "a5k1ng".*, .action = 42, .text = null, .unanswered = true } });
    var retried: ?Commands = null;
    for ((try refresh(&state, .changed, testToken(4), &.{next})).slice()) |effect| if (effect == .read_commands) {
        retried = effect.read_commands;
    };
    try std.testing.expectEqual(@as(u64, 42), retried.?.items[0].action);
    // A tool with no command to show keeps the mark and title only, and
    // is not asked again.
    _ = try step(&state, .{ .command = .{ .reference = "a5k1ng".*, .action = 42, .text = null } });
    for ((try refresh(&state, .changed, testToken(5), &.{next})).slice()) |effect| try std.testing.expect(effect != .read_commands);
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .normal }, .{ "2m", .quiet } });
    // While its conversation is open, that conversation alone reads the
    // Action; the row asks once the conversation returns.
    next.first_action = 43;
    _ = try step(&state, .{ .conversation = "a5k1ng".* });
    for ((try refresh(&state, .changed, testToken(6), &.{next})).slice()) |effect| try std.testing.expect(effect != .read_commands);
    _ = try step(&state, .{ .conversation = null });
    var returned: ?Commands = null;
    for ((try refresh(&state, .changed, testToken(7), &.{next})).slice()) |effect| if (effect == .read_commands) {
        returned = effect.read_commands;
    };
    try std.testing.expectEqual(@as(u64, 43), returned.?.items[0].action);
}

/// Your Sessions at work and waiting, beside others' work and ends.
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

/// The glyph that the row titled `label` shows on `text`.
fn markOf(text: []const u8, label: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, label).?;
    const line = text[if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |newline| newline + 1 else 0..at];
    return std.mem.trim(u8, line, " ");
}

test "your Sessions at work turn the spinner in step, and every other mark holds still" {
    var state = try opened(&spinning);
    defer state.deinit();
    state.selected = .new_session;
    for (0..spinner.len + 1) |frame| {
        const text = try frameText(&state, 80, 24, .{}, frame);
        defer std.testing.allocator.free(text);
        const turn = spinner[frame % spinner.len];
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, thinking"));
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, running"));
        try std.testing.expectEqualStrings("?", markOf(text, "Mine, asking"));
        try std.testing.expectEqualStrings("◌", markOf(text, "Mine, queued"));
        try std.testing.expectEqualStrings("⠹", markOf(text, "Mine, retrying"));
        try std.testing.expectEqualStrings("⠹", markOf(text, "Mine, stopping"));
        try std.testing.expectEqualStrings("⠹", markOf(text, "Theirs, thinking"));
        try std.testing.expectEqualStrings("✓", markOf(text, "Theirs, finished"));
        var screen = try Frame.of(&state, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(anySpins(&state, .{}));
        // The spinner keeps its rule's colour.
        const mine = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Mine, thinking").?], "\n");
        try std.testing.expectEqual(Style{ .colour = .ink }, screen.styleAt(mine, 1).?);
    }
    // A stop the person asked for holds the mark still before the Host
    // reports it.
    state.selected = .{ .session = "y0urs1".* };
    _ = try press(&state, .stop);
    _ = try press(&state, .stop);
    try std.testing.expect(state.openStop("y0urs1".*) != null);
    const asked = try frameText(&state, 80, 24, .{}, 1);
    defer std.testing.allocator.free(asked);
    try std.testing.expectEqualStrings("⠹", markOf(asked, "Mine, thinking"));
    // ASCII, NO_COLOR and a faded screen hold still on every frame.
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

/// Whether any list line's mark spins.
fn anySpins(state: *const State, caps: Caps) bool {
    var line: usize = 0;
    while (listItem(state, line)) |item| : (line += 1) if (markSpins(state, item, caps)) return true;
    return false;
}

test "the screen asks for frames only while a spinner shows" {
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
        // Its work ending stops the frames.
        _ = try refresh(&state, .changed, testToken(2), &.{session("w0rk00", .{ .finished = ago(0) }, .{ .label = "Write the notes", .yours = true })});
        try std.testing.expect(!anySpins(&state, .{}));
    }
    // Others' work holds still, so it needs no frames.
    rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes" });
    var state = try opened(&rows);
    defer state.deinit();
    try std.testing.expect(!anySpins(&state, .{}));
}

test "ctrl-x stops at once a row its rule lets it stop, and asks nothing" {
    for (kind_cases) |case| {
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
        // Until its result arrives the row says it is stopping, and a second
        // ctrl-x finds nothing to stop.
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "Stopping") != null);
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

test "ctrl-x in a conversation stops its Session as on its row, listed or not" {
    var state = try testState();
    defer state.deinit();
    const ref = "k7m2qx".*;
    const ctrl_x: Conversed = .{ .reference = ref, .work = .working, .input = .stop };
    try expectSaid(null, true, conversation(&state, ref, .working, .{}, &test_said));
    try expectEffects(&.{.{ .stop = ref }}, try step(&state, .{ .conversed = ctrl_x }));
    // Until its answer the work is stopping: no hint, and ctrl-x says so.
    try std.testing.expect(!conversation(&state, ref, .working, .{}, &test_said).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectNotice(&state, "k7m2qx: Stopping");
    try expectSaid("k7m2qx: Stopping", false, conversation(&state, ref, .working, .{}, &test_said));
    // Any other input there clears the notice.
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .input = .other } }));
    try std.testing.expectEqual(@as(?[]const u8, null), conversation(&state, ref, .working, .{}, &test_said).text);
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNotice(&state, "! k7m2qx not stopped: session_not_found");
    // Ended work takes no stop.
    try std.testing.expect(conversation(&state, ref, .working, .{}, &test_said).stoppable and !conversation(&state, ref, .finished, .{}, &test_said).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .finished, .input = .stop } }));
    try expectNotice(&state, "k7m2qx is already finished.");
}

const read_order_states = [_]WorkState{
    // All tags, with independent older/newer source revisions below.
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
        var buffer: [max_second_line_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("Stopped", secondLine(&state, state.find(ref).?, &buffer));
        try std.testing.expectEqual(@as(u64, test_now_s), shownSince(&state, state.find(ref).?));
        var finished = session(&ref, .{ .finished = ago(0) }, .{ .label = "Same Session", .turn = 8 });
        finished.last_line = .{ .position = 5, .text = "Later listing answer" };
        _ = try refresh(&state, delta, testToken(4), &.{finished});
        try std.testing.expectEqual(Kind.finished, shownKind(&state, state.find(ref).?));
        try std.testing.expectEqualStrings("Later listing answer", secondLine(&state, state.find(ref).?, &buffer));
    }
}

test "snapshot and listing rows render identical stopped failed and done endings" {
    const ref = "k7m2qx".*;
    const cases = [_]struct { state: WorkState, text: ?[]const u8, detail: []const u8 }{
        .{ .state = .{ .stopped = .{ .since = test_now_s - 5, .cause = .stop } }, .text = null, .detail = "Stopped" },
        .{ .state = .{ .failed = .{ .since = test_now_s - 5, .code = bounded(session_work.max_code_bytes, "malformed_provider_output"), .resets_at = null } }, .text = null, .detail = "Model reply unreadable" },
        .{ .state = .{ .finished = ago(5) }, .text = "New completed answer", .detail = "New completed answer" },
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
        var detail: [max_second_line_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.detail, secondLine(&state, state.find(ref).?, &detail));
        const snapshot = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(snapshot);
        // Neither row's mark, detail nor age can depend on which read
        // supplied it. Use the same clock, with no intervening refresh.
        var from_list = try opened(&.{initial});
        defer from_list.deinit();
        // Compare the same sidebar presentation: the standalone list
        // additionally draws its pinned New Session control.
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
    _ = try step(&state, .{ .observed = settled }); // The producer was retired.
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
        // Existing metadata is replaced too, without a separate provider cache.
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

test "conversation permissions never borrow another Action's listed command" {
    const ref = "k7m2qx".*;
    var state = try opened(&.{session(&ref, .{ .approval = ago(10) }, .{ .first_action = 7 })});
    defer state.deinit();
    // The listing's own command read is still valid for its snapshot.
    _ = try step(&state, .{ .command = .{ .reference = ref, .action = 7, .text = "echo old" } });
    _ = try step(&state, .{ .conversation = ref });
    var buffer: [max_second_line_bytes]u8 = undefined;
    for ([_]?u64{ 7, 8, null }, 0..) |action, i| {
        const work: session_work.Work = .{ .state = if (action != null) .{ .approval = ago(0) } else .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .first_action = action };
        _ = try step(&state, .{ .observed = .{ .read_version = testToken(2 + i), .reference = ref, .work = work, .opening = false } });
        try std.testing.expectEqualStrings(if (action == 7) "echo old" else if (action == 8) "" else "Stopped", secondLine(&state, state.find(ref).?, &buffer));
        if (action != @as(?u64, 7)) {
            _ = try step(&state, .{ .command = .{ .reference = ref, .action = 7, .text = "stale command" } });
            try std.testing.expectEqualStrings(if (action == 8) "" else "Stopped", secondLine(&state, state.find(ref).?, &buffer));
        }
    }
    _ = try step(&state, .{ .conversation = null });
    try std.testing.expectEqualStrings("Stopped", secondLine(&state, state.find(ref).?, &buffer));
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
    // It needs the person, so it lives on the status bar, not as a notice
    // the next key clears.
    try std.testing.expectEqualStrings("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    try std.testing.expectEqual(null, state.notice);
    _ = try press(&state, .next);
    try std.testing.expectEqualStrings("! Not confirmed · rui request recover " ++ saved_key, unconfirmedLine(&state, &line).?);
    // A capture that may not be published has no key to recover yet; the
    // newest unconfirmed send is the one named.
    try expectEffects(&.{}, try step(&state, .{ .unconfirmed = .{ .reference = refs[1], .recovery = .{ .uncertain = reserved_key } } }));
    try std.testing.expectEqualStrings("! r4t9vw: send not confirmed; details on exit", unconfirmedLine(&state, &line).?);
    // Each takes a ledger slot, so the shell asks before the last one.
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
        // The row stays stopping: another Ctrl-X sends nothing and says
        // so again.
        try std.testing.expectEqual(Kind.stopping, shownKind(&state, state.find(ref.*).?));
        state.notice = null;
        try expectEffects(&.{}, try press(&state, .stop));
        try expectEffects(&.{}, try press(&state, .stop));
        try expectNotice(&state, recover);
        try expected.writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ ref, handle });
    }
    // A full ledger refuses a stop of a Session it does not hold.
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
    // The first listing finds the row; the selection waited for it.
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
    // Rows in screen order; a labelled row or one with no Message needs none.
    try expectEffects(&.{.{ .read_first_lines = reads }}, try respond(&state, .full, testToken(1), &mixed));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "  summarize yesterday's CI failures\r\nand say which are new" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = null } }));
    // Another admission is another Message: ignored.
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "p3q4r5".*, .admission = 5, .line = "not this one" } }));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqual(Line.requested, state.find("p3q4r5".*).?.line);
    try expectScreenLine(&state, position(&state, "h8q2mz".*).? * 2 + 2, " ✓ summarize yesterday's CI failures                                        12m");
    // Lines in flight or unreadable are not asked for again, and a refresh
    // that replaces a row keeps the line of its unchanged first Message.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{session("h8q2mz", .{ .working = ago(0) }, .{ .yours = true })}));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // An unreadable line is not asked for again while listings, changed or
    // full, name its unchanged first Message.
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } });
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{f6g7h8}));
    // The full listing finds h8q2mz's next Turn finished after the working
    // above.
    var next_turn = mixed;
    next_turn[1].turn = 2;
    try expectEffects(&.{}, try refresh(&state, .full, testToken(4), &next_turn));
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

test "Host facts change only the counts line, and a row from before a restart still says working" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Admitted before the restart" }),
        session("h8q2mz", .{ .working = ago(5) }, .{ .label = "Admitted after it" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
    });
    defer state.deinit();
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try expectScreenLine(&state, 0, "  + New Session");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 0, "  + New Session");
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, "  + New Session").?..], after[std.mem.indexOf(u8, after, "  + New Session").?..]);
    try std.testing.expect(std.mem.indexOf(u8, after, " ⠹ Admitted before the restart") != null);
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
        try std.testing.expect(std.mem.indexOf(u8, text, "project") != null);
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
    // It leads the finished, newest first.
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "✓ List unused build steps") != null);
    // Moving on goes to the next row on screen, not the next old index.
    _ = try press(&state, .next);
    try expectSelected(&state, "h8q2mz");
    _ = try press(&state, .next);
    try expectSelected(&state, "t7v8w9");
    _ = try press(&state, .next);
    try expectSelected(&state, "m1n2p3");
    // A selected row remains selected when its age moves it to the end.
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expectEqual(state.order.items.len + firstRowLine(&state), listLength(&state));
}

/// Takes every program status record waiting for the shell, as sent.
/// Takes every record the terminal does not hold as wanted, as delivered.
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
    // What the overview opened on: work under way and waiting, in key order.
    try expectRecords(&.{
        .{ .reference = "a1b2c3".*, .name = "Waits", .status = .blocked },
        .{ .reference = "b4n8wd".*, .name = "Busy", .status = .working },
    }, sentRecords(&state, &records));
    // Unchanged, nothing waits, not even the old finish.
    _ = try refresh(&state, .full, testToken(2), &listed);
    try std.testing.expect(state.statusesSettled());
    // b4n8wd finishes, a new Session fails, and a1b2c3 is listed no more.
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
    // Opening b4n8wd sees its finish; listing it again keeps that.
    _ = try step(&state, .{ .open = "b4n8wd".* });
    try expectRecords(&.{.{ .reference = "b4n8wd".*, .name = "Busy", .status = .idle }}, sentRecords(&state, &records));
    _ = try refresh(&state, .changed, testToken(4), &.{session("b4n8wd", .{ .finished = ago(0) }, .{ .label = "Busy", .turn = 1 })});
    try std.testing.expect(state.statusesSettled());
    // Its next Turn's finish is a record again, and the Turn after it,
    // though no listing read it working between; after the terminal
    // cleared every record, each held one waits again.
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
    try std.testing.expectEqual(null, selectedLine(&state));
    _ = try press(&state, .previous);
    try std.testing.expectEqual(Selection.new_session, state.selected);
    for (state.order.items, 0..) |index, at| {
        _ = try press(&state, .next);
        try expectSelected(&state, &state.rows.items[index].reference);
        try std.testing.expectEqual(@as(?usize, at + 1), selectedLine(&state));
    }
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.settings, state.selected);
    try std.testing.expectEqual(null, selectedLine(&state));
    _ = try press(&state, .next);
    try std.testing.expectEqual(Selection.settings, state.selected);
    var at = state.order.items.len;
    while (at != 0) {
        at -= 1;
        _ = try press(&state, .previous);
        try expectSelected(&state, &state.rows.items[state.order.items[at]].reference);
    }
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
    // While Host requests wait on an Upgrade, the click selects but does
    // not open, as Enter would not.
    state.upgrade.run = .checking;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .{ .open = "g7h8j9".* } } }));
    try expectSelected(&state, "g7h8j9");
}

test "overview scroll rows exclude the pinned New Session and chat omits its gap too" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(showsNewSession(&state));
    try std.testing.expectEqual(Item.gap, listItem(&state, 0).?);
    try std.testing.expectEqual(null, clickOf(&state, .gap));
    for ([_]bool{ false, true }) |chat| {
        state.conversing = if (chat) mixed[0].reference else null;
        try std.testing.expectEqual(!chat, showsNewSession(&state));
        for (state.order.items, 0..) |index, at| {
            const item = listItem(&state, at + @intFromBool(!chat)).?;
            try std.testing.expectEqual(Item{ .row = at }, item);
            try std.testing.expectEqualStrings(&state.rows.items[index].reference, &clickOf(&state, item).?.open);
            state.selected = .{ .session = state.rows.items[index].reference };
            try std.testing.expectEqual(@as(?usize, if (chat) position(&state, mixed[0].reference).? else at + 1), selectedLine(&state));
        }
        try std.testing.expectEqual(null, listItem(&state, listLength(&state)));
        state.selected = .new_session;
        try std.testing.expectEqual(if (chat) position(&state, mixed[0].reference) else null, selectedLine(&state));
    }
    var empty = try opened(&.{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), listLength(&empty));
    try std.testing.expectEqual(Item.gap, listItem(&empty, 0).?);
    try std.testing.expectEqual(null, listItem(&empty, 1));
}

test "a click that names a Session gone from the list since it was drawn changes nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.session;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .target = .{ .open = "n0n0n0".* } } }));
    try expectSelected(&state, &selected);
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
    _ = try refresh(&state, .full, testToken(7), &.{ session("aaaaaa", a.state, .{ .label = "A", .read_version = testToken(6) }), b, session("aaaaaa", .{ .finished = ago(0) }, .{ .label = "A", .read_version = testToken(7) }) });
    try expectEachOnce(&state, &.{ "aaaaaa", "bbbbbb" });
    try std.testing.expect(state.find("aaaaaa".*).?.state == .finished);
}

test "a Session listed twice keeps its later row, whatever the order" {
    const a = session("aaaaaa", .{ .working = ago(10) }, .{ .label = "A" });
    const b = session("bbbbbb", .{ .working = ago(20) }, .{ .label = "B" });
    const c = session("cccccc", .{ .working = ago(30) }, .{ .label = "C" });
    // The later duplicate sorts last by row but not by reference.
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
    const quota = failedRow("q1q1q1", 60, "provider_quota", test_now_s + 300);
    _ = try respond(&state, .full, testToken(1), &.{ retryRow("r1r1r1", "provider_temporary_http_429", 12), quota });
    // The next listing comes first; while it is in flight, the retry falling
    // due, then the quota reset.
    try std.testing.expectEqual(@as(?u64, start + list_interval_ms), state.wakeAt());
    _ = try step(&state, .{ .tick = start + list_interval_ms });
    try std.testing.expectEqual(@as(?u64, start + 12_000), state.wakeAt());
    _ = try step(&state, .{ .list = .failed });
    _ = try step(&state, .{ .tick = start + 12_000 });
    try std.testing.expect(state.find("r1r1r1".*).?.state == .pending);
    // Then the quota resets.
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
    // Host failures retain the rows without the removed Host-stopped band.
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 3 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectScreenLine(&state, 0, "  + New Session");
    var screen = try Frame.of(&state, 80, 24, .{}, 0);
    defer screen.deinit();
    try expectScreenLine(&state, 2, " ? Review PR 412                                                             3m");
    try std.testing.expectEqual(Colour.attention, screen.styleAt(2, 1).?.colour);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 0, "  + New Session");
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
    try std.testing.expect(std.mem.indexOf(u8, text, " ◌ Audit permission paths\n") != null);
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
    // Sign-in: an authentication failure newer than the newest completion.
    for ([_][]const u8{ "provider_http_401", "provider_sign_in_required", "provider_sign_in_refresh_token_expired" }) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
    try std.testing.expect(signInCode("provider_sign_in_refresh_token_expired") and signInCode("provider_http_401") and signInCode("provider_sign_in_required"));
    try std.testing.expect(!signInCode("provider_authentication_backend_failed"));
    // A later completion clears it; a login in this terminal hides it until a newer failure.
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ session("ffffff", .{ .finished = ago(30) }, .{}), failedRow("aaaaaa", 60, "provider_http_401", null) }, null));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_http_401", null) }, test_now_s - 30));
    try std.testing.expectEqual(Band{ .trouble = .sign_in, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 10, "provider_http_401", null) }, test_now_s - 30)).?);
    // A rejected API key: its own remedy, not a sign-in.
    try std.testing.expectEqual(Band{ .trouble = .api_key, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, failure_class.api_key_rejected, null) }, null)).?);
    try std.testing.expect(!signInCode(failure_class.api_key_rejected));
    // Quota: shown with its reset time until that time passes.
    try std.testing.expectEqual(Band{ .trouble = .quota, .resets_at = test_now_s + 1200, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 1200) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota, .provider = .codex }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_plan", test_now_s) }, null));
    // Rate limit: while any row retries for a 429.
    try std.testing.expectEqual(Band{ .trouble = .rate_limit, .sessions = 2 }, (try bandOf(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20), retryRow("cccccc", "provider_temporary_error", 20) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{retryRow("aaaaaa", "provider_temporary_error", 10)}, null));
    // A retry already due is pending, not retrying.
    var state = try opened(&.{retryRow("aaaaaa", "provider_temporary_http_429", 10)});
    defer state.deinit();
    state.now_ms = (test_now_s + 10) * 1000;
    try std.testing.expectEqual(@as(?Band, null), band(&state));
    // Priority: sign-in, then quota, then rate limit.
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
        // The band keeps one cell each side: the exact fit holds it, a cell
        // less does not.
        .{ .provider = .chatgpt, .width = managed.len + 2, .shown = managed },
        .{ .provider = .chatgpt, .width = managed.len + 1, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .width = 60, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .width = 40, .shown = "Quota used up." },
        .{ .provider = .chatgpt, .resets_at = test_now_s + 1200, .width = 200, .shown = "Quota used up. Resets in 20m. " ++ usage },
        .{ .provider = .chatgpt, .resets_at = test_now_s + 1200, .width = 60, .shown = "Quota used up. Resets in 20m." },
        // A provider with no such place keeps the limit alone at any width.
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
        try std.testing.expect(std.mem.indexOf(u8, text, "  + New Session") != null);
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
        try std.testing.expect(std.mem.startsWith(u8, text, "  + New Session\n"));
        try std.testing.expectEqualStrings("enter open", footerRight(&state));
        try std.testing.expect(std.mem.indexOf(u8, text, "new Session ·") == null);
    }
}

test "the overview's rows draw twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_]u16{ 80, 200 }) |width| {
        var shown = try Frame.of(&state, width, 60, .{}, 0);
        defer shown.deinit();
        try std.testing.expectEqual(@as(usize, mixed.len * 2 + 2), shown.list.len);
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
    try expectScreenLine(&state, 2, " ⠹ Bell? and ?[31mred                                                        5s");
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

test "the overview indexed palettes retain every colour" {
    const expected = [_]struct { skin: Skin, colours: [9]u8, backgrounds: [5]u8 }{
        .{ .skin = .day, .colours = .{ 235, 17, 239, 60, 103, 187, 94, 124, 233 }, .backgrounds = .{ 255, 253, 254, 253, 214 } },
        .{ .skin = .night, .colours = .{ 255, 188, 249, 247, 60, 237, 214, 210, 233 }, .backgrounds = .{ 234, 235, 238, 237, 214 } },
    };
    for (expected) |case| {
        for (std.enums.values(Colour), case.colours) |role, value| try std.testing.expectEqual(value, indexed.get(case.skin).colours.get(role));
        for (std.enums.values(Background), case.backgrounds) |role, value| try std.testing.expectEqual(value, indexed.get(case.skin).backgrounds.get(role));
    }
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
    // A notice never hides the run's line, where Esc is offered.
    state.say(.attention, "! Select a Session first.", .{});
    try expectStatus(&state, "Preparing Upgrade · no Hosts running · esc cancels", .normal);
    _ = try press(&state, .next);
    // An ending that is news is a notice: it goes with the next key and
    // the unconfirmed send shows again.
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 0 }, .restarted = false } }, .outcome = .compatible } } });
    try std.testing.expectEqualStrings("Upgraded to 0.60.0", footerNotice(&state).?);
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    _ = try press(&state, .next);
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    // A release this client cannot use stays until another Upgrade.
    _ = try step(&state, .start_upgrade);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    _ = try press(&state, .next);
    try expectStatus(&state, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention);
    // ASCII spells the line's dots.
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
    try std.testing.expect(std.mem.indexOf(u8, text, "✓ second") != null);
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
        // Exercise the draw owner even for pairs that a filtered listing omits.
        state.archive = filter;
        state.rows.items[0].archive_state = archive;
        state.selected = if (selected) .{ .session = "aaaaaa".* } else .new_session;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const segments = try rowSegments(arena.allocator(), &state, 0, width, .{ .unicode = unicode_marks }, 0);
        const text = try segmentText(arena.allocator(), segments);
        const expected = archive == .archived and filter != .archived;
        const marker = if (unicode_marks) " · archived" else " . archived";
        try std.testing.expectEqual(@as(usize, @intFromBool(expected)), std.mem.count(u8, text, marker));
        try std.testing.expect(std.mem.indexOf(u8, text, "[Archived]") == null);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, text, " "), if (unicode_marks) "✓ Archive audit" else "+ Archive audit"));
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
    try expectRow(try rowSegments(arena.allocator(), &state, 0, 40, .{}, 0), 40, &.{ .{ "✓", .mark }, .{ "A long archived Sessi…", .strong }, .{ "· archived", .quiet }, .{ "1s", .quiet } });
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
        // A second Alt-A while the first is pending sends nothing more.
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
                // Admit before the hold, then deliver the worker's answer.
                try std.testing.expect(state.request(if (archived) .archive else .unarchive, ref));
                state.left = left;
                state.upgrade.after = if (blocked) .blocked else .reobserving;
                try expectEffects(&.{}, try step(&state, .{ .archive = .{ .request = .{ .reference = ref, .archived = archived }, .outcome = outcome } }));
                // A confirmed answer retires from the attached ledger; only
                // unknown outcomes or departure custody retain a record.
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
    // Every kind appears twice at the same age. Sender never affects order;
    // references are the independent tie-break expectation within each class.
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
    // Bash with approvals belongs before every work row regardless of sender.
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
    try std.testing.expectEqual(Selection.settings, state.selected);
    var empty = try opened(&.{});
    defer empty.deinit();
    try std.testing.expectEqual(Selection.new_session, empty.selected);
}

test "overview second line and folder cover every work state with and without last text" {
    const expected = [_][]const u8{ "", "Queued", "Thinking", "Provider error · retry in 12s", "Run the logic tests", "Allow: echo yes", "Stopping", "", "Something went wrong", "Stopped" };
    for (kind_cases, 0..) |case, at| for ([_]?[]const u8{ null, "All tests pass.", "" }) |last_text| {
        var listed = session("k7m2qx", case.state, .{ .label = "Row", .first_action = 7, .workspace = "/work/rui" });
        listed.last_line = .{ .position = 42, .text = last_text };
        var state = try opened(&.{listed});
        defer state.deinit();
        if (case.state == .approval) _ = try step(&state, .{ .command = .{ .reference = listed.reference, .action = 7, .text = "Allow: echo yes" } });
        const row = state.find(listed.reference).?;
        var buffer: [max_second_line_bytes]u8 = undefined;
        const fallback = expected[at];
        const want = if (at == 0 or at >= 7) last_text orelse fallback else fallback;
        try std.testing.expectEqualStrings(want, secondLine(&state, row, &buffer));
        try std.testing.expectEqualStrings("rui", folderOf(&state, row));
        try std.testing.expectEqual(@as(u64, 42), row.last_line.?.position);
        state.rows.items[state.order.items[0]].last_line = null;
        try std.testing.expectEqualStrings(fallback, secondLine(&state, state.find(listed.reference).?, &buffer));
    };
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
    var buffer: [max_second_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Done", secondLine(&state, row, &buffer));
    try std.testing.expectEqualStrings("rui", folderOf(&state, row));
    const longest: [session_list.max_last_line_bytes]u8 = @splat('z');
    source.last_line = .{ .position = 20, .text = bounded(session_list.max_last_line_bytes, &longest) };
    _ = try refresh(&state, .changed, testToken(2), &.{Listed.of(&source)});
    try std.testing.expectEqualStrings(&longest, secondLine(&state, state.find("k7m2qx".*).?, &buffer));
    source.last_line = .{ .position = 20, .text = null };
    _ = try refresh(&state, .changed, testToken(3), &.{Listed.of(&source)});
    try std.testing.expectEqual(@as(u64, 20), state.find("k7m2qx".*).?.last_line.?.position);
    try std.testing.expectEqualStrings("", secondLine(&state, state.find("k7m2qx".*).?, &buffer));
    source.last_line = null;
    _ = try refresh(&state, .changed, testToken(4), &.{Listed.of(&source)});
    try std.testing.expectEqual(null, state.find("k7m2qx".*).?.last_line);
}

test "overview second line queues due retries and uses waiting Bash commands first" {
    var due = retryRow("dueque", "provider_temporary_error", 10);
    due.state.retrying.due_at_ms = test_now_s * 1000 - 1;
    due.workspace = "/other/drift/";
    due.last_line = .{ .position = 9, .text = "Old answer" };
    var bash = session("bash01", .{ .bash = .{ .since = test_now_s, .call = 0, .description = bounded(session_work.max_description_bytes, "Running tests"), .running = 1, .approvals = 1 } }, .{ .label = "Bash", .first_action = 7 });
    bash.last_line = due.last_line;
    var state = try opened(&.{ due, bash });
    defer state.deinit();
    var buffer: [max_second_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Queued", secondLine(&state, state.find(due.reference).?, &buffer));
    try std.testing.expectEqualStrings("drift", folderOf(&state, state.find(due.reference).?));
    try std.testing.expectEqualStrings("", secondLine(&state, state.find(bash.reference).?, &buffer));
    _ = try step(&state, .{ .command = .{ .reference = bash.reference, .action = 7, .text = "echo allowed" } });
    try std.testing.expectEqualStrings("echo allowed", secondLine(&state, state.find(bash.reference).?, &buffer));
}

test "overview quiet rows: a chat never written in recedes unless it needs you, in every kind, stop, selection, width and depth" {
    // Independent expectations from the approved mock: a chat the person
    // never wrote in recedes unless it waits for approval or failed. A stop
    // asked of an awaited decision, pending or unconfirmed, leaves the row
    // under Needs you as main sorts it, so it stays loud.
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
        const first = try listSegments(arena.allocator(), &state, .{ .row = 0 }, width, caps, 0);
        const name = try styleOf(first.segments, "Quiet row");
        try std.testing.expectEqual(selected, first.selected);
        try std.testing.expectEqual(selected, name.bold);
        try std.testing.expectEqual(if (selected) Colour.strong else Colour.normal, name.colour);
        const second = try rowSecondSegments(arena.allocator(), &state, 0, width, caps);
        // Quiet rows add dim without replacing the folder's muted role.
        try std.testing.expectEqual(Style{ .colour = .quiet, .dim = quiet }, try styleOf(second, "rui"));
        // The mark, name, age, detail, folder and padding all recede together.
        for (first.segments) |segment| try std.testing.expectEqual(quiet, segment.style.dim);
        for (second) |segment| try std.testing.expectEqual(quiet, segment.style.dim);
    };
    var empty = try opened(&.{session("newone", .{ .idle = ago(0) }, .{ .first = null })});
    defer empty.deinit();
    _ = try step(&empty, .{ .conversation = "newone".* });
    try std.testing.expect(!rowQuiet(&empty, empty.find("newone".*).?));
}

// PR3: independent layout expectations for the two-line list contract.
test "overview two-line rows at 40 and 140 columns cover every work state" {
    const details = [_][]const u8{ "", "Queued", "Thinking", "Provider error · retry in 12s", "Run the logic tests", "Allow: echo yes", "Stopping", "All tests pass.", "Something went wrong", "Stopped" };
    for (kind_cases, 0..) |case, index| for ([_]u16{ 40, 140 }) |width| {
        var listed = session("k7m2qx", case.state, .{ .label = "A useful Session name", .first_action = 7, .workspace = "/work/drift" });
        if (index == 7) listed.last_line = .{ .position = 1, .text = "All tests pass." };
        var state = try opened(&.{listed});
        defer state.deinit();
        if (index == 5) _ = try step(&state, .{ .command = .{ .reference = listed.reference, .action = 7, .text = "Allow: echo yes" } });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const first = try rowSegments(arena.allocator(), &state, 0, width, .{}, 0);
        const second = try rowSecondSegments(arena.allocator(), &state, 0, width, .{});
        try expectLine(first, width, if (index == 1) &.{"◌ A useful Session name"} else &.{ try std.fmt.allocPrint(arena.allocator(), "{s} A useful Session name", .{([_][]const u8{ "○", "◌", "⠹", "⠹", "⠹", "?", "⠹", "✓", "×", "■" })[index]}), age: {
            var buffer: [8]u8 = undefined;
            break :age try arena.allocator().dupe(u8, ageText(&buffer, (state.now_ms / 1000) -| listed.state.since()));
        } });
        try expectLine(second, width, if (details[index].len == 0) &.{"drift"} else &.{ details[index], "drift" });
        try std.testing.expectEqual(Colour.strong, (try styleOf(first, "A useful Session name")).colour);
        try std.testing.expect((try styleOf(first, "A useful Session name")).bold);
        try std.testing.expectEqual(Colour.quiet, (try styleOf(second, "drift")).colour);
        const first_text = try segmentText(arena.allocator(), first);
        const second_text = try segmentText(arena.allocator(), second);
        try std.testing.expect(std.mem.startsWith(u8, first_text, " "));
        try std.testing.expect(std.mem.startsWith(u8, second_text, "   "));
        try std.testing.expect(std.mem.endsWith(u8, first_text, " "));
        try std.testing.expect(std.mem.endsWith(u8, second_text, "drift "));
        state.selected = .new_session;
        try std.testing.expectEqual(Colour.normal, (try styleOf(try rowSegments(arena.allocator(), &state, 0, width, .{}, 0), "A useful Session name")).colour);
    };
}

test "overview long name fills to the age and detail never overlaps its folder" {
    const name = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij";
    var listed = session("k7m2qx", .{ .finished = ago(19) }, .{ .label = name, .workspace = "/work/drift" });
    listed.last_line = .{ .position = 1, .text = "A very long result that must be cut before the folder starts" };
    var state = try opened(&.{listed});
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const first = try rowSegments(arena.allocator(), &state, 0, 40, .{}, 0);
    const second = try rowSecondSegments(arena.allocator(), &state, 0, 40, .{});
    try std.testing.expectEqualStrings(" ✓ abcdefghijklmnopqrstuvwxyzABCDE… 19s ", try segmentText(arena.allocator(), first));
    try std.testing.expectEqualStrings("   A very long result that must … drift ", try segmentText(arena.allocator(), second));
    // A stale listing does not grey ended names, and unsafe bytes never escape.
    state.list_stale = true;
    const faded = try rowSegments(arena.allocator(), &state, 0, 40, .{}, 0);
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
        .{ .run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } }, .right = "enter open" },
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
        // A loading answer is retried on the next listing without any shell open.
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
        // Periodic loading retries must use exactly the same hold admission.
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
        .action, .enter => false,
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

test "New Session Enter and click create exactly once with a copied default" {
    for ([_]bool{ false, true }) |click| {
        var state = try opened(&.{});
        defer state.deinit();
        state.default = Default.of("openai", "gpt-6-sol");
        const input: Event = if (click) .{ .clicked = .{ .target = .new_session } } else .{ .input = .{ .key = .enter } };
        const effects = try step(&state, input);
        try expectEffects(&.{.{ .create = state.default }}, effects);
        // The effect owns its bounded binding, not the mutable defaults slot.
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

test "overview bottom layout reserves only status and one footer" {
    var state = try opened(&.{});
    defer state.deinit();
    for ([_]u16{ 0, 1, 2, 10, 30, 40 }) |height| {
        state.size = .{ .width = 46, .height = height };
        const rows = layout(&state);
        try std.testing.expectEqual(@max(rows.top, height -| 1), rows.input);
        try std.testing.expect(rows.list.end <= rows.settings.start);
        try std.testing.expect(rows.settings.end <= rows.host.start);
        try std.testing.expect(rows.host.end <= rows.input);
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
                // Either pending archive direction blocks another intent.
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
            try std.testing.expectEqual(if (admitted) ArchiveAdmission.admitted else .refused, effects.archive_admission);
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
                try std.testing.expect(state.notice == null); // The durable archive badge is the feedback.
            } else if (held != .none) {
                try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), if (held == .pending) "request pending" else "request unsure") != null);
            } else if (full) {
                try std.testing.expectEqualStrings("! Busy; try again shortly.", state.notice.?.text());
            }
            // Admission belongs to this one attempt, never retained State.
            try std.testing.expectEqual(ArchiveAdmission.refused, (try step(&state, .{ .resized = .{ .width = 46, .height = 18 } })).archive_admission);
        }
    };
    var empty = try opened(&.{});
    defer empty.deinit();
    const refused = try press(&empty, .archive);
    try std.testing.expectEqual(ArchiveAdmission.refused, refused.archive_admission);
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
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", state.notice.?.text());
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
        .{ .run = .{ .ended = .{ .how = .superseded, .outcome = .unchanged } }, .going = false, .escape = false },
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
        const row = try listSegments(arena.allocator(), &state, .empty, 80, .{}, 0);
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
        // A Label, workspace or provider choice alone does not admit a Message.
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
        // A full read applies the same visibility, without dropping empty rows.
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
    // An explicit stale selection cannot authorize hidden-row operations.
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
            // Neither opening nor a metadata-less Current fabricates a list
            // member. In particular a provider-less failure is not a band.
            try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
            try std.testing.expect(selectedLine(&state) == null);
            _ = try step(&state, .{ .observed = .{ .reference = empty.reference, .read_version = testToken(2), .work = .{ .state = failedRow("empty1", 1, "provider_http_401", null).state }, .opening = false } });
            try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
            try std.testing.expectEqual(@as(usize, 0), state.order.items.len);
            try std.testing.expect(band(&state) == null);
            _ = try refresh(&state, .changed, testToken(3), &.{empty});
        }
        // A pre-list reconciliation or a covered Settings selection cannot
        // choose a different sidebar row from the conversation being shown.
        for ([_]Selection{ .new_session, .settings, .{ .session = "other1".* } }) |navigation| {
            state.selected = navigation;
            try std.testing.expectEqual(@as(?usize, 0), selectedLine(&state));
            try std.testing.expectEqualStrings("New Session", title(&state, &state.rows.items[state.order.items[0]]).text);
            for ([_]u16{ 46, 140 }) |width| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const built = try listSegments(arena.allocator(), &state, .{ .row = 0 }, width, .{}, 0);
                try std.testing.expect(built.selected);
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
        try std.testing.expect(selectedLine(&state) == null);
        // Canonical admission, not naming/configuration choices, restores the
        // normal row title. It remains visible after leaving the chat.
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
    // The entire semantic key domain, independent of the terminal decoder.
    var inputs: [std.enums.values(Action).len + 2]Input = undefined;
    for (std.enums.values(Action), 0..) |action, at| inputs[at] = .{ .action = action };
    inputs[inputs.len - 2] = .enter;
    inputs[inputs.len - 1] = .ignored;
    for ([_]bool{ false, true }) |under| for ([_]bool{ false, true }) |pasted| for (std.enums.values(creations)) |creation| for (phases) |phase| for (inputs) |key| {
        var state = try opened(&.{});
        defer state.deinit();
        if (creation != .none) {
            _ = try submit(&state);
            if (creation == .uncertain) _ = try step(&state, .{ .created = .{ .unconfirmed = "saved-create" } });
        }
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
            // Exit remains live even while creation or a covered page waits.
            try expectEffects(&.{.exit}, effects);
            try std.testing.expect(std.meta.eql(before_notice, state.notice));
            try std.testing.expectEqual(before_requests, state.request_count);
        } else if (key == .action and key.action == .clear and phase.escape) {
            // Cancellable Escape precedes both Settings and creation isolation.
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
            .enter => {
                if (phase.held) {
                    try expectEffects(&.{}, effects);
                    try expectNotice(&state, upgrade_recovery);
                    try std.testing.expectEqual(before_requests, state.request_count);
                } else {
                    try expectEffects(&.{.{ .create = null }}, effects);
                    try std.testing.expectEqual(before_requests + 1, state.request_count);
                    try std.testing.expect(state.creating());
                }
            },
            .action => |action| {
                try expectEffects(&.{}, effects);
                try std.testing.expectEqual(before_requests, state.request_count);
                switch (action) {
                    .exit => unreachable,
                    // New Session is selected: Right neither creates nor clears.
                    .open_session => try std.testing.expect(std.meta.eql(before_notice, state.notice)),
                    .clear => try expectNotice(&state, null),
                    .stop, .archive => try expectNotice(&state, if (phase.held) upgrade_recovery else no_selection),
                    .previous, .next, .first, .last, .select_previous, .select_next => {
                        const expected: Selection = if (action == .next or action == .last or action == .select_next) .settings else .new_session;
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

test "the shared row fitter handles no description cells without allocating or underflowing" {
    for ([_]Keep{ .head, .tail }) |keep| {
        var storage: [0]u8 = .{};
        var fixed: std.heap.FixedBufferAllocator = .init(&storage);
        const shown = try fitted(fixed.allocator(), .{}, "description", 0, keep);
        try std.testing.expectEqualStrings("", shown.bytes);
        try std.testing.expectEqual(@as(usize, 0), shown.cells);
    }
}
