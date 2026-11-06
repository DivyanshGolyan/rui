//! Session overview: every decision behind bare `rui`, over values.
//!
//! `step` applies one event (a key, a tick, a list page, a first line, a
//! stop or start result) to the overview's `State` and returns the effects
//! its shell runs: list again, read first lines, start, open, stop or exit.
//! Layout and presentation roles are values too; `OverviewPaint` writes them
//! directly into the invocation backend. This core reads no clock or Host:
//! time arrives as a tick at `State.wakeAt`. What each
//! work state looks like lives in `rules`, what each key does in `keys`.
//! The rows are a client view over `session list`; the Host keeps no
//! overview state.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const attention = @import("attention.zig");
const change_ring = @import("change_ring.zig");
const cli_args = @import("cli_args.zig");
const command_value = @import("command_value.zig");
const shortPath = @import("home_path.zig").shortPath;
const draft_layout = @import("draft_layout.zig");
const failure_class = @import("failure_class.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const model_picker = @import("model_picker.zig");
const provider_name = @import("provider_name.zig");
const session_work = @import("session_work.zig");
const slash_commands = @import("slash_commands.zig");
pub const commands = slash_commands.overview;
const TerminalText = @import("TerminalText.zig");
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
/// How long each frame of the spinner shows: one turn in two seconds.
pub const spin_interval_ms = 200;
/// A generated request handle, as `rui request recover` takes it.
pub const max_handle_bytes = 36;

pub const Group = enum { yours, active, queued, idle, finished, ended };
pub const Mark = enum { active, queued, waiting, finished, failed, stopped };
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

/// How one work state looks and what Ctrl-X may do to it. A row that
/// `says` its work says what `work_line` says, in its tone; `word` names an
/// idle or ended state, which has no work line.
pub const Rule = struct {
    group: Group,
    mark: Mark,
    /// The mark's colour, unless the work line's tone asks for attention
    /// or quiet.
    colour: Colour,
    word: ?[]const u8 = null,
    /// The row says its work line beside its title: what needs the person
    /// or explains a wait. The mark and the group say the rest. The line's
    /// tone colours the mark either way.
    says: bool = false,
    /// The model or a tool is at work, so your own row's mark turns the
    /// spinner. A retry counting down or a stop holds still.
    spins: bool = false,
    /// A failed or stopped row names the Session that sent its first
    /// Message, by Label, else reference.
    starter: bool = false,
    /// Ctrl-X may stop a Session in this state.
    stoppable: bool,
};

/// The one per-kind table. `step` and `render` read it and switch on no kind.
pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .group = .idle, .mark = .waiting, .colour = .normal, .word = "idle", .stoppable = false },
    .pending = .{ .group = .queued, .mark = .queued, .colour = .normal, .stoppable = true },
    .working = .{ .group = .active, .mark = .active, .colour = .ink, .spins = true, .stoppable = true },
    .retrying = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .stoppable = true },
    .bash = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .spins = true, .stoppable = true },
    .approval = .{ .group = .active, .mark = .waiting, .colour = .normal, .says = true, .stoppable = true },
    .stopping = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .stoppable = false },
    .finished = .{ .group = .finished, .mark = .finished, .colour = .mark, .word = "finished", .stoppable = false },
    .failed = .{ .group = .ended, .mark = .failed, .colour = .failure, .word = "failed", .starter = true, .stoppable = false },
    .stopped = .{ .group = .ended, .mark = .stopped, .colour = .normal, .word = "stopped", .starter = true, .stoppable = false },
});

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8 }).init(.{
    .active = .{ .unicode = "●", .ascii = "*" },
    .queued = .{ .unicode = "◌", .ascii = ":" },
    .waiting = .{ .unicode = "○", .ascii = "o" },
    .finished = .{ .unicode = "✓", .ascii = "+" },
    .failed = .{ .unicode = "×", .ascii = "x" },
    .stopped = .{ .unicode = "■", .ascii = "#" },
});

/// Your own Session's active mark turns through these, one per frame.
pub const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// `under_way`: its rows' work is under way, so the headline says "Running."
pub const groups = std.enums.EnumArray(Group, struct { title: []const u8, help: []const u8 = "", folds: bool, under_way: bool = false }).init(.{
    .yours = .{ .title = "Yours", .folds = false },
    .active = .{ .title = "Active", .folds = false, .under_way = true },
    .queued = .{ .title = "Queued", .folds = false, .under_way = true },
    .idle = .{ .title = "Idle", .folds = false },
    .finished = .{ .title = "Finished", .folds = true },
    .ended = .{ .title = "Stopped or failed", .folds = true },
});

/// What a key does in the overview. `clear` empties the draft, else the
/// held start settings. `select_*` choose a Session even while the picker
/// shows; `previous` and `next` move the picker's highlight there.
pub const Action = enum { previous, next, select_previous, select_next, first, last, clear, exit, stop };

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
    .up = .previous,
    .down = .next,
    .shift_up = .select_previous,
    .shift_down = .select_next,
    .page_up = null,
    .page_down = null,
    .home = .first,
    .end = .last,
    .ctrl_end = null,
});

/// The composer's text and caret, as the shell's line editor holds them,
/// and the draft line the previous frame showed first.
/// `anchor` is the byte that started the composer's first shown line last
/// frame. `edits` counts changes to its bytes and never repeats for a new
/// draft.
/// The most bytes a draft holds, as the shell's line editor caps it.
pub const draft_capacity = 65_536;

pub const Draft = struct { bytes: []const u8 = "", cursor: usize = 0, anchor: usize = 0, edits: u32 = 0 };

/// Where the next input goes, which the shell's route and `render` both
/// read: the composer, the composer frozen while a start waits, or the
/// sign-in choice drawn in its place.
pub const InputMode = enum { compose, frozen, choice };

/// What one input did, and the draft as that input left it.
pub const Composed = struct { input: Input, draft: Draft };

/// One input as its route took it: through the composer (or the frozen
/// composer), or at the sign-in choice. Typing and a paste at the choice go
/// to the composer, so a `composer` input in `choice` mode leaves the choice.
pub const Input = union(enum) {
    composer: keymap.Outcome(Action),
    choice: Choice,
};

/// An input at the sign-in choice, as `TerminalEditor.select` names it
/// apart from typing: the screen's keys, the choice's own arrows and Enter,
/// a refused chord, or nothing.
pub const Choice = union(enum) { none, action: Action, left, right, enter, refused };

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
    /// The Turn the state belongs to.
    turn: ?u64 = null,
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
            .turn = row.work.turn,
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
    /// The size of the screen the shell draws next; keys read until the
    /// next one act on that screen.
    resized: Size,
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
    conversed: Conversed,
    /// A model-list read ended.
    models: ModelsRead,
    /// A save of the default ended.
    saved: SaveAnswer,
    /// A read the open conversation applied.
    observed: Observed,
    /// The command `step` asked the shell to run ended.
    ran: Ran,
};

/// How the command `step` asked for ended, and what it printed, cut at
/// `max_output_bytes`, borrowed until the next `step`.
pub const Ran = struct {
    output: []const u8,
    /// It printed more than `output` holds.
    cut: bool = false,
    outcome: enum {
        done,
        /// It never started.
        not_run,
        /// It failed once its output was being kept, which ends the
        /// overview, as a conversation ends.
        failed,
    } = .done,
    /// The default saved defaults now give the next Session, after a
    /// `/setup` that ran; null leaves the one in force.
    default: ?Default = null,
};

/// The most a command's output the overview keeps.
pub const max_output_bytes = 8192;

/// A command line the shell runs as a conversation runs it, from Enter to
/// its answer. One runs at a time.
pub const Command = struct {
    name: commands.Name,
    /// The Session /rename names.
    session: ?Reference = null,
    /// Owned: the line as typed until the answer; then, for an answer the
    /// overview could not show, what the command printed, for
    /// `writeDeparture`.
    text: []u8,
    answered: bool = false,
};

/// What takes the Sessions' rows until Esc or a key that acts on a
/// Session: /help, or a command's output of more than one line.
pub const Panel = union(enum) {
    help,
    /// The text is owned.
    output: struct { name: commands.Name, text: []u8 },

    pub fn text(self: *const Panel) []const u8 {
        return switch (self.*) {
            .help => help_text,
            .output => |output| output.text,
        };
    }

    /// Rows it takes whole: its heading and its lines.
    pub fn rows(self: *const Panel) usize {
        return 2 + std.mem.count(u8, self.text(), "\n");
    }
};

/// What /help shows under its heading: the overview's keys, then its
/// commands, which its table lists.
const help_text = "Up/Down select a Session past the draft's lines · Shift-Up/Down always\n" ++
    "Home/End select the first or last Session while the draft is empty\n" ++
    "Enter on an empty draft opens the selected Session · Ctrl-X twice stops it\n" ++
    "A message and Enter starts a new Session with it\n" ++
    "/ lists the commands · Up/Down move the highlight · Tab or Enter takes it\n" ++
    "Esc or Ctrl-G closes the list, this panel, the draft, then held settings\n" ++
    "Ctrl-C, or Ctrl-D on an empty draft, leaves; Host work continues\n" ++
    "\n" ++ std.mem.trimEnd(u8, commands.help, "\n");

/// How a model-list read ended.
pub const ModelsRead = union(enum) {
    /// The menu of the Host's lists, which the core now owns.
    menu: model_picker.Menu,
    /// The Host did not answer.
    unanswered,
    /// The Host answered with a list Rui cannot read.
    invalid,
};

/// A save of `binding` as the default ended as `outcome`.
pub const SaveEnded = struct { binding: Default, outcome: Saved };

/// How a save ended, with the effort the saved defaults hold once it
/// ended, as this overview's starts read them: null when the launch reads
/// none or they could not be read.
pub const SaveAnswer = struct { ended: SaveEnded, saved_effort: ?ReasoningEffort = null };

const ReasoningEffort = model_capability.ReasoningEffort;

/// Which effort from the saved defaults a start applies: none when the
/// start holds an effort of its own, `default` included, or names no model;
/// else the saved one when the model offers it.
pub const StartEffort = struct {
    /// What `/configure --reasoning-effort` holds for the start.
    held: ?[]const u8,
    model: ?[]const u8,

    /// Whether the saved effort can reach the start, so the shell reads it.
    pub fn readsSaved(self: StartEffort) bool {
        return self.held == null and self.model != null;
    }

    /// The effort the start applies from `saved`, which is null when the
    /// launch reads no saved defaults.
    pub fn applied(self: StartEffort, saved: ?ReasoningEffort) ?ReasoningEffort {
        if (!self.readsSaved()) return null;
        return model_capability.startEffort(saved, self.model.?);
    }
};

/// A saved effort as the lines that name the next Session's model show it
/// after the model, as a conversation's status line does.
fn effortSuffix(effort: ?ReasoningEffort) []const u8 {
    return switch (effort orelse return "") {
        inline else => |tag| session_line.separator ++ @tagName(tag),
    };
}

/// How a save of the default ended.
pub const Saved = union(enum) {
    done,
    /// The file holds the pick, but a crash may yet lose it.
    unconfirmed,
    /// Not saved; why, in words, when more than the file's path helps.
    failed: ?[]const u8,
};

/// A read the open conversation of `reference` applied, which showed its
/// work as `work`. Its news is named `name`, as the conversation names the
/// Session; the read the conversation opens on is not news.
pub const Observed = struct { reference: Reference, work: session_work.Work, name: []const u8, opening: bool };

/// An input in the open conversation of `reference`, whose work it shows as
/// `work`: Ctrl-X there asks for and confirms a stop as Ctrl-X on the
/// Session's row does, and any other input cancels the prompt.
pub const Conversed = struct { reference: Reference, work: Kind, stop: bool };

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
    /// Read the Host's model lists.
    list_models,
    /// Save the person's default for new Sessions, as `rui defaults
    /// configure --provider --model` does, and answer with `saved`.
    save_default: Default,
    /// Empty the line editor.
    clear_draft,
    /// Add these static bytes at the draft's end, as Tab does.
    append: []const u8,
    /// Tell the person, if they look away, of the listing's news.
    notify: Alert,
    /// Run the command's line as a conversation runs it, and answer with
    /// `ran`. It borrows the state until that answer.
    command: Command,
    exit,
};

pub const Provider = provider_name.Provider;

/// The provider and model new Sessions get.
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

/// What the next Session starts on: the provider and the model `/configure`
/// holds, else the default's. Its slices borrow the state until the next
/// `step`.
pub const Binding = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    /// The provider's sign-in, as the terminal names it, else as given.
    fn signIn(self: Binding) []const u8 {
        const name = self.provider orelse return "sign-in unknown";
        return if (std.meta.stringToEnum(Provider, name)) |provider| provider.signIn() else name;
    }
};

/// Picks on their way to the preferences file. One save runs at a time:
/// a pick made while one runs waits, and only the newest waits. Only `step`
/// changes it.
pub const Save = struct {
    /// The newest pick waiting for the running save to end.
    wanted: ?Default = null,
    /// The pick the shell is saving.
    running: ?Default = null,
    /// The newest save that ended since the person left, which the way out
    /// tells; one that ended before, the overview said.
    last: ?SaveEnded = null,
};

/// The screen in cells.
pub const Size = struct { width: u16 = 0, height: u16 = 0 };

/// The model picker /model opens: the models, then, for a model more than
/// one sign-in offers, the sign-in choice on the input row.
pub const Picker = struct {
    /// The highlighted model's ID, which a new list keeps highlighted while
    /// it holds the model; empty until a list holds any.
    highlight: Bounded(model_capability.max_model_bytes) = .{ .len = 0 },
    step: union(enum) {
        models,
        /// Enter took the highlighted model, which more than one sign-in
        /// offers; this one is highlighted.
        sign_in: Provider,
    } = .models,
};

/// The most model rows the picker shows at once.
pub const max_picker_rows = 8;

/// News: the most urgent Session that newly wants the person, by the name
/// its row or the conversation shows, which borrows the state or the event
/// until the next `step`, and how many others brought news with it.
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

    pub fn put(self: *StartSettings, option: usize, value: []const u8) error{NoSpaceLeft}!void {
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
    /// The provider and model, `nextBinding`'s: the shell reads these, never
    /// the settings' own.
    binding: Binding = .{},

    pub fn own(self: StartRequest, gpa: Allocator) error{OutOfMemory}!OwnedStart {
        const provider = self.binding.provider orelse "";
        const model = self.binding.model orelse "";
        const bytes = try gpa.alloc(u8, self.text.len + self.settings.used + provider.len + model.len);
        var writer = std.Io.Writer.fixed(bytes);
        inline for (.{ self.text, self.settings.bytes[0..self.settings.used], provider, model }) |part| writer.writeAll(part) catch unreachable;
        return .{ .bytes = bytes, .text_len = self.text.len, .held = self.settings.held, .provider_len = if (self.binding.provider) |name| name.len else null, .model_len = if (self.binding.model) |name| name.len else null };
    }
};

/// A start's text and held settings in one allocation sized to them. Its
/// owner reads it on any thread and frees it once the start is answered.
pub const OwnedStart = struct {
    bytes: []u8,
    text_len: usize,
    held: [start_options.len]?StartSettings.Range,
    /// The binding's lengths, its bytes last: the provider, then the model.
    provider_len: ?usize = null,
    model_len: ?usize = null,

    pub fn text(self: *const OwnedStart) []const u8 {
        return self.bytes[0..self.text_len];
    }

    /// The provider and model the Session starts on.
    pub fn binding(self: *const OwnedStart) Binding {
        const model_len = self.model_len orelse 0;
        const provider_end = self.bytes.len - model_len;
        return .{
            .provider = if (self.provider_len) |len| self.bytes[provider_end - len .. provider_end] else null,
            .model = if (self.model_len != null) self.bytes[provider_end..] else null,
        };
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

/// What both screens say while a stop waits for its second Ctrl-X: the
/// Session's reference and a separator dot.
pub const stop_prompt = "Stop {s}? ctrl+x yes {s} esc no";

/// The bytes the conversation's stop prompt takes.
pub const max_prompt_bytes = stop_prompt.len - 2 * "{s}".len + @typeInfo(Reference).array.len + "·".len;

/// What the overview says under the input of the conversation of `ref`,
/// whose work shows as `work`: its stop prompt for that Session, else its
/// notice, and whether Ctrl-X would ask to stop the work.
pub const Said = struct {
    /// Null when the overview says nothing; the conversation's own notice
    /// then shows.
    text: ?[]const u8,
    /// The text is the stop prompt, which Esc or Ctrl-G only cancels.
    asking: bool,
    stoppable: bool,
};

pub fn conversation(state: *const State, ref: Reference, work: Kind, buffer: *[max_prompt_bytes]u8) Said {
    const asking = if (state.prompt) |open| std.mem.eql(u8, &open.stop, &ref) else false;
    const text: ?[]const u8 = if (asking)
        std.fmt.bufPrint(buffer, stop_prompt, .{ &ref, "·" }) catch unreachable
    else if (state.notice) |*notice| notice.text() else null;
    return .{ .text = text, .asking = asking, .stoppable = stoppable(state, ref, work) };
}

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
    /// Room for a refused environment's reason, its longest notice.
    bytes: [768]u8 = undefined,
    len: usize = 0,
    colour: Colour,

    pub fn text(self: *const Notice) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn firstLine(self: *const Notice) []const u8 {
        const all = self.text();
        return all[0 .. std.mem.indexOfScalar(u8, all, '\n') orelse all.len];
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
    /// The Turn the state belongs to: which finish or failure the row shows.
    turn: ?u64,
    /// The earliest Action awaiting a decision: which wait for approval the
    /// row shows.
    first_action: ?u64,
    first: ?First,
    from_person_at: ?u64,
    line: Line = .unread,

    /// What the listing said of the row's work, as `attention.observe` reads it.
    fn work(self: *const Row) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .first_action = self.first_action };
    }

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

    /// The person's default for new Sessions. A pick replaces it at once,
    /// and a save follows it to the preferences file. `nextBinding` says
    /// what the next Session starts on.
    default: ?Default = null,
    save: Save = .{},
    /// The screen the shell draws, which `layout` divides.
    size: Size = .{},
    /// Open from /model until a pick, Esc or typing; it acts only while
    /// `layout` shows it.
    picker: ?Picker = null,
    /// The command list the latest frame built for the draft, which the
    /// shell keeps from each `OverviewPaint.Drawn.commands`: the one value Enter, Esc,
    /// the arrows and Tab act on, as in a conversation.
    commands: ?slash_commands.Shown = null,
    /// The open picker's latest model lists, freed when it closes.
    menu: model_picker.Menu = .{},
    /// How the open picker's latest model-list read ended.
    menu_read: enum { unread, read, unanswered, invalid } = .unread,
    /// A model-list read is in flight.
    asking_models: bool = false,
    /// Shown in the Sessions' rows while open.
    panel: ?Panel = null,
    /// The command the shell runs, until its answer; one the overview
    /// could not show, until the way out.
    command: ?Command = null,

    /// The token of the last completed listing.
    token: ?Token = null,
    /// What wanted the person when a read, by the listing or the open
    /// conversation, last showed it, by Session reference key: one record
    /// both read against, so neither gives news the other gave. Beside it,
    /// the program status record the terminal should show and the one it
    /// holds.
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
    /// The Host has not answered a list request since this time.
    unreachable_since_ms: ?u64 = null,
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

    /// Where the next input goes. The sign-in choice holds the input row
    /// only while the screen shows the picker.
    pub fn inputMode(self: *const State) InputMode {
        if (self.starting()) return .frozen;
        if (self.shownPicker()) |picker| if (picker.step == .sign_in) return .choice;
        return .compose;
    }

    /// The picker, while the screen shows it: keys act on nothing else.
    /// The picker shows only over an empty draft, one row.
    pub fn shownPicker(self: *const State) ?*const Picker {
        const picker = if (self.picker) |*open| open else return null;
        return if (layout(self, 1, 0).picker.len() != 0) picker else null;
    }

    /// What the next Session starts on: what `/configure` holds, else the
    /// default.
    /// What `/configure --reasoning-effort` holds for the next start.
    pub fn heldEffort(self: *const State) ?[]const u8 {
        return self.settings.get(startOption("reasoning-effort").?);
    }

    pub fn nextBinding(self: *const State) Binding {
        const default = if (self.default) |*binding| binding else null;
        return .{
            .provider = self.settings.get(startOption("provider").?) orelse if (default) |binding| @tagName(binding.provider) else null,
            .model = self.settings.get(startOption("model").?) orelse if (default) |binding| binding.model.slice() else null,
        };
    }

    /// The menu as the picker shows it, the next Session's model first.
    pub fn shownMenu(self: *const State) model_picker.Shown {
        return self.menu.shown(self.nextBinding().model);
    }

    /// The open picker's highlighted entry of `menu`.
    pub fn highlighted(self: *const State) ?usize {
        const picker = self.picker orelse return null;
        return self.menu.find(picker.highlight.slice());
    }

    fn closePicker(self: *State) void {
        self.picker = null;
        self.menu.deinit(self.gpa);
        self.menu_read = .unread;
    }

    fn showPanel(self: *State, panel: Panel) void {
        self.closePanel();
        self.panel = panel;
    }

    /// The Sessions show again.
    fn closePanel(self: *State) void {
        const panel = self.panel orelse return;
        if (panel == .output) self.gpa.free(panel.output.text);
        self.panel = null;
    }

    pub fn deinit(self: *State) void {
        self.menu.deinit(self.gpa);
        self.closePanel();
        if (self.command) |command| self.gpa.free(command.text);
        for (self.workspaces.items) |bytes| self.gpa.free(bytes);
        inline for (.{ &self.rows, &self.by_reference, &self.order, &self.workspaces, &self.workspace_order, &self.lines, &self.pending, &self.sort_keys, &self.seen, &self.arrivals }) |vec| vec.deinit(self.gpa);
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
    /// listing, a retry falling due, or the shown
    /// quota reset passing. Null while nothing falls due before the listing
    /// in flight answers. A time already past means at once. The shell keeps
    /// no timer of its own.
    pub fn wakeAt(self: *const State) ?u64 {
        var at: ?u64 = if (self.listing) null else self.next_list_ms;
        for (self.rows.items) |*row| {
            if (row.state == .retrying) at = @min(at orelse row.state.retrying.due_at_ms, row.state.retrying.due_at_ms);
        }
        if (band(self.rows.items, self.now_ms, self.login_at)) |trouble| if (trouble.resets_at) |resets| {
            at = @min(at orelse resets *| 1000, resets *| 1000);
        };
        return at;
    }

    pub fn selectedRow(self: *const State) ?*const Row {
        return self.find(self.selected orelse return null);
    }

    /// A start is in flight. The composer is frozen until its answer, so
    /// a failed start leaves its text to retry.
    pub fn starting(self: *const State) bool {
        return self.pendingAt(.start, null) != null;
    }

    /// A stop of `ref` still in flight, or one that may have reached the
    /// Host. While one is open the row takes no other stop.
    pub fn openStop(self: *const State, ref: Reference) ?*const Request {
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

    /// Records the open conversation's read in `seen` and returns its news.
    /// The read it opens on is what the person opened.
    fn observe(self: *State, read: Observed) error{OutOfMemory}!?attention.Kind {
        const ref = read.reference;
        const work = read.work;
        if (read.opening and attention.Attention.of(work) != null) _ = attention.observe(&(try self.record(ref)).acknowledged, work);
        if (self.entryOf(ref)) |entry| return attention.observe(&entry.attention, work);
        var first: ?attention.Attention = null;
        const kind = attention.observe(&first, work) orelse return null;
        (try self.record(ref)).attention = first;
        return kind;
    }

    /// Records a listing's read of `ref`'s work, its news and its program
    /// status record, and returns its news. A Session new to `seen` waits
    /// in `arrivals` until `settleArrivals`, so a listing inserts all at
    /// once.
    fn readListed(self: *State, ref: Reference, work: session_work.Work, opening: bool) error{OutOfMemory}!?attention.Kind {
        if (self.entryOf(ref)) |entry| {
            const now: attention.Reading = .of(work, entry.acknowledged);
            const status = attention.Status.next(entry.status, entry.listed, now, opening);
            // A later finish or wait in the same status is a record again.
            const later = status == entry.status and if (entry.listed) |was| now.after(was) else false;
            self.want(entry, status, later);
            entry.listed = now;
            return attention.observe(&entry.attention, work);
        }
        const now: attention.Reading = .of(work, null);
        var arrival: Seen = .{ .key = referenceKey(ref), .listed = now, .status = attention.Status.next(null, null, now, opening) };
        const kind = attention.observe(&arrival.attention, work);
        try self.arrivals.append(self.gpa, arrival);
        return kind;
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

pub const Summary = struct {
    /// A row works: its state's group has work under way, whatever its section.
    working: bool = false,
    approvals: usize = 0,
    failed: usize = 0,
    /// The newest state's time, Unix seconds.
    latest: u64 = 0,
    /// Every Session you messaged has finished.
    answered: bool = true,
};

const Run = struct { start: usize = 0, len: usize = 0 };
const Keyed = struct { key: u64, index: u32 };
/// One Session's record: the latest news any read gave, which decides
/// notifications; the latest state a conversation opened on, an outcome the
/// person has seen; what the last listing read; and the program status the
/// terminal should show, from listings alone, which read in order, beside
/// the one it holds. A Session no longer listed has no program status.
const Seen = struct {
    key: u64,
    attention: ?attention.Attention = null,
    acknowledged: ?attention.Attention = null,
    listed: ?attention.Reading = null,
    status: ?attention.Status = null,
    /// Names each record wanted: a new status, a later outcome or wait in
    /// the same one, or a new title. It wraps; sixteen bits keep `Seen` at
    /// two cache lines, which the 10,000-row listing benchmark feels, and a
    /// Session would need 65,536 changes between two frames to repeat one.
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
        .composed => |value| try compose(state, value, &effects),
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
        .conversed => |input| {
            state.notice = null;
            const prompt = state.prompt;
            state.prompt = null;
            if (input.stop) stopKey(state, prompt, input.reference, input.work, &effects);
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
                    // The Host serves no sign-in for the start's provider,
                    // which the frozen composer kept as it started.
                    const next = state.nextBinding().provider;
                    const missing = if (std.mem.eql(u8, code, "model_capability_unavailable")) std.meta.stringToEnum(Provider, next orelse "") else null;
                    if (missing) |provider| {
                        state.say(.attention, "! {s} sign-in missing · {s}", .{ provider.signIn(), provider.login() });
                    } else state.say(.attention, "! Not started: {s}", .{code});
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
        .leave => {
            state.left = true;
            // The person saw how every earlier save ended.
            state.save.last = null;
        },
        .resized => |size| state.size = size,
        .observed => |read| if (try state.observe(read)) |kind| if (!read.opening) effects.add(.{ .notify = .{ .name = read.name, .kind = kind, .more = 0 } }),
        .open => |ref| {
            state.selected = ref;
            effects.add(.{ .open = ref });
        },
        .host => |facts| state.host = facts,
        .models => |read| readModels(state, read),
        .ran => |ran| try ranCommand(state, ran),
        .saved => |answer| {
            const ended = answer.ended;
            // That pick's save ended, failed or not: only a new pick asks again.
            std.debug.assert(ended.binding.eql(&state.save.running.?));
            state.save.running = null;
            state.save.last = ended;
            // A pick that came while this save ran is said by its own save.
            if (state.save.wanted == null) {
                const next = state.nextBinding();
                const model = next.model orelse "";
                const sign_in = next.signIn();
                const start: StartEffort = .{ .held = state.heldEffort(), .model = next.model };
                const effort_suffix = effortSuffix(start.applied(answer.saved_effort));
                switch (ended.outcome) {
                    .done => state.say(.quiet, "New Sessions use {s}{s} · {s}", .{ model, effort_suffix, sign_in }),
                    .unconfirmed => state.say(.attention, "! Saved {s} · {s}; durability unconfirmed", .{ ended.binding.model.slice(), ended.binding.provider.signIn() }),
                    .failed => |why| state.say(.quiet, "Default not saved ({s}); new Sessions here still use {s}{s} · {s}", .{ why orelse "check ~/.config/rui/preferences", model, effort_suffix, sign_in }),
                }
            }
            startSave(state, &effects);
        },
    }
    // Opening a Session shows the person its outcome.
    for (effects.slice()) |effect| if (effect == .open) if (state.entryOf(effect.open)) |entry| state.want(entry, attention.Status.opened(entry.status), false);
    return effects;
}

/// Takes a model-list answer. A failed read keeps the open picker's list.
fn readModels(state: *State, read: ModelsRead) void {
    state.asking_models = false;
    switch (read) {
        .menu => |menu| {
            var owned = menu;
            // The answer came after the picker closed.
            const picker = if (state.picker) |*open| open else return owned.deinit(state.gpa);
            state.menu.deinit(state.gpa);
            state.menu = owned;
            state.menu_read = .read;
            // The highlight stays on its model while the list holds it, and
            // a sign-in choice while the model's sign-ins hold it.
            const at = state.highlighted() orelse {
                picker.step = .models;
                if (owned.entries.len != 0) picker.highlight.set(state.shownMenu().entry(0).id) catch unreachable;
                return;
            };
            switch (picker.step) {
                .models => {},
                .sign_in => |provider| if (!owned.entries[at].providers.contains(provider)) {
                    picker.step = .models;
                },
            }
        },
        .unanswered => if (state.picker != null) {
            state.menu_read = .unanswered;
        },
        .invalid => if (state.picker != null) {
            state.menu_read = .invalid;
        },
    }
}

/// The sign-in beside `current` that `providers` holds, in provider order.
fn nextSignIn(providers: model_picker.Providers, current: Provider, side: enum { left, right }) Provider {
    const order = std.enums.values(Provider);
    var at = std.mem.indexOfScalar(Provider, order, current).?;
    while (true) {
        switch (side) {
            .left => at = std.math.sub(usize, at, 1) catch return current,
            .right => {
                at += 1;
                if (at == order.len) return current;
            },
        }
        if (providers.contains(order[at])) return order[at];
    }
}

/// The most bytes `writeDeparture` writes for a save the person did not see
/// end.
pub const max_late_save_bytes = 512;

/// The most bytes `writeDeparture` writes for a command the person did not
/// see end: its name, its output and a line that says it was cut.
pub const max_late_command_bytes = max_output_bytes + 96;

/// What the shell prints once the terminal is restored: one line for each
/// request left in the ledger, and one for a save the person did not see
/// end. `saved_effort` is the effort the saved defaults hold now, which a
/// later launch that reads them applies.
pub fn writeDeparture(state: *const State, saved_effort: ?ReasoningEffort, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (state.save.last) |*late| {
        const model = late.binding.model.slice();
        const sign_in = late.binding.provider.signIn();
        // Held start settings end with the overview.
        const effort_suffix = effortSuffix((StartEffort{ .held = null, .model = model }).applied(saved_effort));
        switch (late.outcome) {
            .done => try writer.print("rui: New Sessions use {s}{s} · {s}.\n", .{ model, effort_suffix, sign_in }),
            .unconfirmed => try writer.print("rui: New Sessions use {s}{s} · {s}; durability unconfirmed, inspect ~/.config/rui/preferences.\n", .{ model, effort_suffix, sign_in }),
            .failed => |why| try writer.print("rui: {s} · {s} was not saved as the default ({s}).\n", .{ model, sign_in, why orelse "check ~/.config/rui/preferences" }),
        }
    }
    if (state.command) |*command| {
        const name = @tagName(command.name);
        if (!command.answered) {
            try writer.print("rui: /{s} did not run.\n", .{name});
        } else if (command.text.len != 0) {
            try writer.print("rui: /{s} output:\n{s}\n", .{ name, command.text });
        }
    }
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
    var changed = false;
    for (state.rows.items) |*row| {
        const next = row.state.asOf(now_ms);
        if (std.meta.activeTag(next) == std.meta.activeTag(row.state)) continue;
        changed = true;
        row.state = next;
    }
    if (changed) try arrange(state);
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.next_list_ms = now_ms + list_interval_ms;
        effects.add(.{ .list = state.token });
        // A list still loading is read again with the next listing.
        if (state.picker != null and state.menu.loading()) askModels(state, effects);
    }
}

fn askModels(state: *State, effects: *Effects) void {
    if (state.asking_models) return;
    state.asking_models = true;
    effects.add(.list_models);
}

/// Hands the waiting pick to the shell to save once no save runs. A
/// failed save is not retried; picking again is.
fn startSave(state: *State, effects: *Effects) void {
    if (state.save.running != null) return;
    const binding = state.save.wanted orelse return;
    state.save = .{ .running = binding, .last = state.save.last };
    effects.add(.{ .save_default = binding });
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
            .turn = listed.turn,
            .first_action = listed.first_action,
            .first = listed.first,
            .from_person_at = listed.from_person_at,
        });
    }
    const answer = page.answer orelse return;
    const alert = try newsworthy(state);
    try commit(state, answer);
    if (alert) |found| {
        const row = state.find(found.reference).?;
        effects.add(.{ .notify = .{ .name = title(state, row).text, .kind = found.kind, .more = found.more } });
    }
    state.listing = false;
    try readFirstLines(state, effects);
}

const Newsworthy = struct { reference: Reference, kind: attention.Kind, more: usize };

/// Records each Session the pending listing shows and returns those newly
/// wanting the person; the most urgent first, the first listed among equals.
/// The first listing is what the overview opened on, not news.
fn newsworthy(state: *State) error{OutOfMemory}!?Newsworthy {
    const opening = state.token == null;
    var found: ?Newsworthy = null;
    // Left by a listing that failed to settle them.
    state.arrivals.items.len = 0;
    for (state.pending.items) |*incoming| {
        const kind = try state.readListed(incoming.reference, incoming.work(), opening) orelse continue;
        if (opening) continue;
        if (found) |*held| {
            held.more += 1;
            if (@backingInt(kind) < @backingInt(held.kind)) {
                held.reference = incoming.reference;
                held.kind = kind;
            }
        } else found = .{ .reference = incoming.reference, .kind = kind, .more = 0 };
    }
    try state.settleArrivals();
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
                    carry(state, incoming, &state.rows.items[at]);
                    state.rows.items[at] = incoming.*;
                } else try state.rows.append(state.gpa, incoming.*);
            }
            try reindex(state);
        },
        .full => {
            std.mem.swap(Vec(Row), &state.rows, &state.pending);
            try reindex(state);
            for (state.pending.items) |*old| {
                if (lookup(state.by_reference.items, old.reference)) |at| {
                    carry(state, &state.rows.items[at], old);
                } else if (state.entryOf(old.reference)) |entry| {
                    state.want(entry, null, false);
                    entry.listed = null;
                }
            }
        },
    }
    state.pending.items.len = 0;
    state.token = answer.since;
    state.listed_at_ms = state.now_ms;
    state.unreachable_since_ms = null;
    try arrange(state);
}

/// What a listing's row keeps of the row it replaces.
fn carry(state: *State, incoming: *Row, old: *const Row) void {
    // What the overview knows of the same first Message's first line, read,
    // unreadable or asked for, still holds.
    const same = if (incoming.first) |first| if (old.first) |known| first.admission == known.admission else false else false;
    if (same) incoming.line = old.line;
    retitle(state, incoming, title(state, old).text);
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

/// Rebuilds the screen order, each group's run and the summary, then keeps the
/// selection on a listed, visible row.
fn arrange(state: *State) error{OutOfMemory}!void {
    const rows = state.rows.items;
    try state.sort_keys.ensure(state.gpa, rows.len);
    try state.order.ensure(state.gpa, rows.len);
    state.sort_keys.items.len = rows.len;
    state.summary = .{};
    const latest = std.math.maxInt(u34);
    for (state.sort_keys.items, rows, 0..) |*key, *row, at| {
        const rule = rules.get(row.state);
        state.summary.failed += @intFromBool(row.state == .failed);
        state.summary.working = state.summary.working or groups.get(rule.group).under_way;
        state.summary.approvals += @intFromBool(row.state == .approval);
        state.summary.latest = @max(state.summary.latest, row.state.since());
        if (row.group() == .yours and row.state != .finished) state.summary.answered = false;
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

pub fn position(state: *const State, ref: Reference) ?usize {
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
    // A Label or the reference, not a read line: `lines` growing leaves it.
    const was = title(state, row).text;
    try state.lines.append(state.gpa, session_line.cut(max_line_bytes, session_line.firstLine(bytes)));
    row.line = .{ .read = @intCast(state.lines.items.len - 1) };
    retitle(state, row, was);
}

/// Any input clears the notice and cancels a stop prompt. Ctrl-X confirms
/// the prompt and Esc only cancels it. Keys act on the picker only while
/// the screen shows it. A key that acts on a Session closes a panel, so it
/// acts where the Sessions show.
fn compose(state: *State, value: Composed, effects: *Effects) error{OutOfMemory}!void {
    state.notice = null;
    const prompt = state.prompt;
    state.prompt = null;
    const mode = state.inputMode();
    const outcome: keymap.Outcome(Action) = switch (value.input) {
        .choice => |choice| choice: {
            std.debug.assert(mode == .choice);
            const picker = &state.picker.?;
            break :choice switch (choice) {
                .none => .none,
                .action => |pressed| .{ .action = pressed },
                .refused => .{ .refused = .unbound },
                .left, .right => {
                    const providers = state.menu.entries[state.highlighted().?].providers;
                    picker.step = .{ .sign_in = nextSignIn(providers, picker.step.sign_in, if (choice == .left) .left else .right) };
                    return;
                },
                .enter => return pick(state, effects),
            };
        },
        .composer => |outcome| composer: {
            // Typing leaves the picker for the draft; at the choice, so
            // does a paste, which the composer takes from its start.
            if (state.picker != null and (value.draft.bytes.len != 0 or mode == .choice)) state.closePicker();
            break :composer outcome;
        },
    };
    const picker: ?*Picker = if (state.shownPicker() != null) &state.picker.? else null;
    switch (outcome) {
        .action => |pressed| switch (pressed) {
            .previous, .next, .first, .last => if (picker) |shown| {
                if (shown.step == .models) pickerMove(state, shown, pressed);
            } else if (pressed == .previous or pressed == .next) {
                // A shown command list takes the arrows, as the picker
                // does. Home and End stay the draft's: the list shows only
                // over a draft, where the composer takes them.
                if (shownCommands(state, value.draft)) |shown| shown.move(pressed == .next) else select(state, pressed);
            } else select(state, pressed),
            .select_previous => select(state, .previous),
            .select_next => select(state, .next),
            // Esc steps back: from the sign-in choice to the models, then
            // out of the picker; else a shown command list closes, then a
            // panel, each keeping the draft.
            .clear => if (prompt != null) {} else if (picker) |shown| switch (shown.step) {
                .sign_in => shown.step = .models,
                .models => state.closePicker(),
            } else if (shownCommands(state, value.draft)) |shown| {
                shown.close();
            } else if (state.panel != null) state.closePanel() else if (value.draft.bytes.len != 0) effects.add(.clear_draft) else {
                state.settings = .{};
            },
            .exit => effects.add(.exit),
            .stop => {
                state.closePanel();
                const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
                stopKey(state, prompt, row.reference, row.state.asOf(state.now_ms), effects);
            },
        },
        .none, .append, .redraw => {},
        // Enter in a list the latest frame drew takes the highlighted
        // entry: it runs the command that entry completes, or adds the word
        // another follows. A screen too short for the list shows none.
        .submit => if (picker != null) pick(state, effects) else if (shownCommands(state, value.draft)) |shown| {
            const taken = shown.list.enter(shown.highlight);
            if (taken.runs and value.draft.bytes.len + taken.rest.len <= draft_capacity) {
                var line: [draft_capacity]u8 = undefined;
                @memcpy(line[0..value.draft.bytes.len], value.draft.bytes);
                @memcpy(line[value.draft.bytes.len..][0..taken.rest.len], taken.rest);
                try enter(state, line[0 .. value.draft.bytes.len + taken.rest.len], effects);
            } else {
                // The draft grows, or refuses a word it cannot hold, so the
                // next list starts at its top.
                shown.highlight = 0;
                effects.add(.{ .append = taken.rest });
            }
        } else try enter(state, value.draft.bytes, effects),
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

/// Ctrl-X on either screen, for the Session `ref` whose work shows as
/// `work`: the first asks, and a second while `prompt` names it sends the stop.
fn stopKey(state: *State, prompt: ?Prompt, ref: Reference, work: Kind, effects: *Effects) void {
    const kind = kindShown(state, ref, work);
    if (!rules.get(kind).stoppable) return refuseStop(state, ref, kind);
    const asked = if (prompt) |open| std.mem.eql(u8, &open.stop, &ref) else false;
    if (!asked) {
        state.prompt = .{ .stop = ref };
    } else if (state.request(.stop, ref)) effects.add(.{ .stop = ref });
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
pub fn stoppable(state: *const State, ref: Reference, work: Kind) bool {
    return rules.get(kindShown(state, ref, work)).stoppable;
}

/// The kind a row shows, with a retry that has fallen due as the work it
/// became.
pub fn shownKind(state: *const State, row: *const Row) Kind {
    return kindShown(state, row.reference, row.state.asOf(state.now_ms));
}

/// What a row's work is doing now, as `shownKind` reads it; null for idle or
/// ended work.
pub fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    return if (state.openStop(row.reference) != null) work_line.stopping else work_line.of(words, &row.state, null, state.now_ms);
}

/// Moves the selection where the Sessions show.
fn select(state: *State, action: Action) void {
    state.closePanel();
    move(state, action);
}

fn enter(state: *State, text: []const u8, effects: *Effects) error{OutOfMemory}!void {
    // As in a conversation, the draft is sent byte for byte; only a blank
    // draft opens the selected row instead.
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        if (text.len != 0) effects.add(.clear_draft);
        const row = state.selectedRow() orelse return;
        // The conversation's own commands write where this one does.
        if (waitForCommand(state)) return;
        state.closePanel();
        return effects.add(.{ .open = row.reference });
    }
    // As in a conversation, `//` starts text with one slash.
    if (text[0] != '/' or std.mem.startsWith(u8, text, "//")) {
        if (!state.request(.start, null)) return;
        return effects.add(.{ .start = .{ .settings = &state.settings, .text = if (text[0] == '/') text[1..] else text, .binding = state.nextBinding() } });
    }
    const command = switch (commands.parse(text)) {
        .unknown => {
            var buffer: [slash_commands.unknown_bytes]u8 = undefined;
            return state.say(.attention, "{s}", .{slash_commands.unknown(&buffer, text)});
        },
        .misused => |name| return state.say(.attention, "! Usage: {s}", .{commands.usage.get(name)}),
        .command => |command| command,
    };
    switch (command.name) {
        .exit => effects.add(.exit),
        .model => {
            state.picker = .{};
            // Visible equals actionable: a picker the screen cannot show never opens.
            if (state.shownPicker() == null) {
                state.picker = null;
                return state.say(.attention, "! Screen too small for /model", .{});
            }
            state.closePanel();
            effects.add(.clear_draft);
            askModels(state, effects);
        },
        .configure => if (configure(state, command.argument)) effects.add(.clear_draft),
        .help => {
            const help: Panel = .help;
            // As for /model, a panel the screen cannot show whole never opens.
            if (layout(state, 1, 0).list.len() < help.rows()) return state.say(.attention, "! Screen too small for /help", .{});
            state.showPanel(help);
            effects.add(.clear_draft);
        },
        .rename => {
            // As a key that acts on a Session, it acts where the Sessions
            // show, so the list shows the row it names.
            state.closePanel();
            const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
            try requestCommand(state, .rename, row.reference, text, effects);
        },
        .setup => try requestCommand(state, .setup, null, text, effects),
    }
}

/// Asks the shell to run `text`, the line of command `name`, once no other
/// command runs.
fn requestCommand(state: *State, name: commands.Name, ref: ?Reference, text: []const u8, effects: *Effects) error{OutOfMemory}!void {
    if (waitForCommand(state)) return;
    state.command = .{ .name = name, .session = ref, .text = try state.gpa.dupe(u8, text) };
    effects.add(.clear_draft);
    effects.add(.{ .command = state.command.? });
}

/// True, and says so, while a command runs: one runs at a time.
fn waitForCommand(state: *State) bool {
    const running = state.command orelse return false;
    state.say(.attention, "! Wait for /{s} to finish.", .{@tagName(running.name)});
    return true;
}

/// What a key or command that needs a selected Session says without one.
const no_selection = "! Select a Session first.";

/// Takes a command's answer: short output is a notice, as a conversation
/// shows it, and more opens a panel. What the overview cannot show (an
/// answer after the person left, a failure that ends it) waits for the way
/// out.
fn ranCommand(state: *State, ran: Ran) error{OutOfMemory}!void {
    const command = &state.command.?;
    std.debug.assert(!command.answered);
    const name = command.name;
    const text = std.mem.trimEnd(u8, ran.output, "\n");
    if (state.left or ran.outcome == .failed) {
        const kept = try keptOutput(state.gpa, text, ran.cut);
        state.gpa.free(command.text);
        command.text = kept;
        command.answered = true;
        return;
    }
    state.gpa.free(command.text);
    state.command = null;
    // What /configure holds still leads, as `nextBinding` says.
    if (ran.default) |binding| state.default = binding;
    // The next listing shows the new label.
    if (name == .rename) state.next_list_ms = 0;
    switch (ran.outcome) {
        .done => {},
        // As a conversation says of an inspection that could not start.
        .not_run => return state.say(.attention, "! /{s} unavailable.", .{@tagName(name)}),
        .failed => unreachable,
    }
    var said: [slash_commands.result_notice_bytes]u8 = undefined;
    if (!ran.cut) if (slash_commands.resultNotice(&said, ran.output)) |notice| {
        return state.say(if (std.mem.startsWith(u8, notice, "!")) .attention else .quiet, "{s}", .{notice});
    };
    state.showPanel(.{ .output = .{ .name = name, .text = try keptOutput(state.gpa, text, ran.cut) } });
}

/// A command's output as the overview keeps it: a final line says when it
/// was cut.
fn keptOutput(gpa: Allocator, text: []const u8, cut: bool) error{OutOfMemory}![]u8 {
    if (!cut) return gpa.dupe(u8, text);
    return std.fmt.allocPrint(gpa, "{s}\nOutput cut at {d} KiB.", .{ text, max_output_bytes / 1024 });
}

fn pickerMove(state: *const State, picker: *Picker, action: Action) void {
    const count = state.menu.entries.len;
    const shown = state.shownMenu();
    const row = shown.row(state.highlighted() orelse return);
    const next = switch (action) {
        .first => 0,
        .last => count - 1,
        .next => @min(row + 1, count - 1),
        .previous => row -| 1,
        else => unreachable,
    };
    picker.highlight.set(shown.entry(next).id) catch unreachable;
}

/// Enter in the picker. A model one sign-in offers is the whole pick; one
/// that more offer turns the input row into the sign-in choice, at the
/// default's sign-in. A model Rui does not list runs with default limits.
fn pick(state: *State, effects: *Effects) void {
    const picker = &state.picker.?;
    const entry = state.menu.entries[state.highlighted() orelse return];
    const provider = switch (picker.step) {
        .sign_in => |chosen| chosen,
        .models => choice: {
            var offering = entry.providers.iterator();
            const first = offering.next().?;
            if (offering.next() == null) break :choice first;
            const next = std.meta.stringToEnum(Provider, state.nextBinding().provider orelse "") orelse first;
            picker.step = .{ .sign_in = if (entry.providers.contains(next)) next else first };
            return;
        },
    };
    var binding: Default = .{ .provider = provider, .model = .{ .len = 0 } };
    binding.model.set(entry.id) catch unreachable;
    state.default = binding;
    // The pick is newer than what /configure holds for the next Session.
    var kept: StartSettings = .{};
    inline for (start_options, 0..) |name, option| if (comptime !std.mem.eql(u8, name, "provider") and !std.mem.eql(u8, name, "model")) {
        if (state.settings.get(option)) |value| kept.put(option, value) catch unreachable;
    };
    state.settings = kept;
    state.save.wanted = binding;
    state.closePicker();
    startSave(state, effects);
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
    var problem: cli_args.Refusal = undefined;
    const parsed = cli_args.live_configure.parse(tokens[0..count], nothing.allocator(), &problem) catch {
        state.say(.attention, configure_usage, .{});
        return false;
    };
    if (parsed.help or parsed.seen == 0) {
        state.say(.attention, configure_usage, .{});
        return false;
    }
    inline for (cli_args.live_configure.options) |option| {
        if (parsed.has(option.name) and startOption(option.name) == null) {
            state.say(.attention, "! Set --{s} after the start", .{option.name});
            return false;
        }
    }
    // The Host admits any model name, so the client checks its syntax, as
    // `session start` does.
    const unlisted: ?[]const u8 = if (parsed.get("model")) |model| blk: {
        if (!model_capability.validModelSyntax(model)) {
            state.say(.attention, "! Not a model ID; session configure -h", .{});
            return false;
        }
        break :blk if (model_capability.supportsModel(model)) null else model;
    } else null;
    var next: StartSettings = .{};
    inline for (start_options, 0..) |name, option| {
        if (parsed.get(name) orelse state.settings.get(option)) |value| next.put(option, value) catch {
            state.say(.attention, "! Settings over {d} bytes", .{StartSettings.max_bytes});
            return false;
        };
    }
    state.settings = next;
    if (unlisted) |model| state.say(.quiet, "Rui does not list {s}; it uses default limits", .{model});
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
pub const Trouble = enum { sign_in, api_key, quota, rate_limit };
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

/// One table per skin, from the Rui Khadi mock's `SKINS`. the direct painter reads
/// roles only and looks each up here.
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
pub const indexed = blk: {
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

/// Where the screen's rows go: the top from row 0, a gap, the list, the
/// picker right above the input, then the input's rule, composer rows and
/// hints. The core reads it to know what shows; the direct painter draws from it.
pub const Layout = struct {
    top: u16 = 0,
    list: Rows = .{},
    /// Empty while the picker is closed or the screen leaves it no row.
    picker: Rows = .{},
    /// The rule's row; `size.height` when the screen is too small for the
    /// input.
    input: u16 = 0,
    /// The command list, between the rule and the draft.
    commands: Rows = .{},

    pub const Rows = struct {
        start: u16 = 0,
        end: u16 = 0,

        pub fn len(self: Rows) u16 {
            return self.end - self.start;
        }
    };
};

/// The rows of `state`'s screen when the draft takes `draft_rows` rows and
/// `command_rows` commands match its command word. As in a conversation,
/// the commands list between the rule and the draft, in rows the draft's
/// cap leaves. The picker takes the rows right above the input, as many as
/// it needs; the Sessions keep the rest, and at least the selected
/// Session's row, which Ctrl-X stops.
pub fn layout(state: *const State, draft_rows: u16, command_rows: usize) Layout {
    const height = state.size.height;
    if (height == 0 or state.size.width == 0) return .{};
    const top: u16 = @intCast(@min(topRows(state), height));
    const kept: u16 = @intFromBool(state.selected != null and state.rows.items.len != 0);
    const fits = height >= 6 and state.size.width >= 6;
    const below = if (fits) height - 1 - hintRows(state) - draft_rows else height;
    const listed: u16 = if (fits) @intCast(@min(command_rows, draft_layout.cap(height) -| draft_rows, below -| (top + 1 + kept))) else 0;
    const input = below - listed;
    var picker: Layout.Rows = .{ .start = input, .end = input };
    if (state.picker != null and top + 1 + kept < input) {
        picker.start = input - @as(u16, @intCast(pickerFit(state, input - (top + 1 + kept)).used()));
    }
    return .{ .top = top, .list = if (top + 1 < picker.start) .{ .start = top + 1, .end = picker.start } else .{}, .picker = picker, .input = input, .commands = .{ .start = input + 1, .end = below + 1 } };
}

/// Rows the line under the input takes: one, or as many as a notice has
/// lines, up to a command's short result. A picker's keys share the first.
pub fn hintRows(state: *const State) u16 {
    if (state.prompt != null or state.picker != null) return 1;
    const notice = state.notice orelse return 1;
    return @intCast(@min(1 + std.mem.count(u8, notice.text(), "\n"), slash_commands.short_result_lines));
}

pub fn topRows(state: *const State) usize {
    const bands = @as(usize, @intFromBool(state.unreachable_since_ms != null)) + @intFromBool(band(state.rows.items, state.now_ms, state.login_at) != null);
    return 1 + @max(bands, 1) + 1;
}

/// The list between the rule and the draft as it is now, while the person
/// types a command, after the latest frame's; null for any other draft or
/// when nothing matches. The next Session's model offers its efforts.
pub fn nextCommands(state: *const State, draft: Draft) ?slash_commands.Shown {
    if (state.inputMode() != .compose) return null;
    const held = state.heldEffort();
    const context: slash_commands.Context = .{
        .model = state.nextBinding().model,
        .effort = if (held) |text| std.meta.stringToEnum(model_capability.ReasoningEffort, text) else null,
    };
    return slash_commands.Shown.next(state.commands, draft.edits, commands.suggest(draft.bytes, context));
}

/// The list for `draft`, which Enter, Esc and the arrows act on when the
/// latest frame drew a list.
fn shownCommands(state: *State, draft: Draft) ?*slash_commands.Shown {
    return slash_commands.Shown.drawnNow(&state.commands, nextCommands(state, draft));
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

/// ` --name value` per held setting, quoting values the /configure grammar
/// would split.
pub fn writeSettings(settings: *const StartSettings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (start_options, 0..) |name, option| {
        const value = settings.get(option) orelse continue;
        try writer.print(" --{s} ", .{name});
        try command_value.write(writer, value);
    }
}

/// What the picker shows in `room` rows: at the sign-in choice only the
/// chosen model. Otherwise a note while the list loads or after a read
/// failed, the models from the highlighted one's window with those Rui does
/// not list under "Other models", then a line for each sign-in the Host
/// does not serve and each list that is loading or unavailable. The
/// highlighted model always shows; the notes and "N more" take only the
/// rows the models leave.
const PickerFit = struct {
    above: bool = false,
    /// Model rows, the "Other models" heading among them.
    shown: usize = 0,
    more: bool = false,
    notes: usize = 0,

    pub fn used(self: PickerFit) usize {
        return @as(usize, @intFromBool(self.above)) + self.shown + @intFromBool(self.more) + self.notes;
    }
};

pub fn pickerFit(state: *const State, room: usize) PickerFit {
    if (room == 0) return .{};
    if (state.picker.?.step == .sign_in) return .{ .shown = 1 };
    const above = state.menu_read != .read;
    var note_count: usize = 0;
    for (std.enums.values(Provider)) |provider| note_count += @intFromBool(pickerNote(state, provider) != null);
    const items = pickerItems(state);
    const notes_room = room -| @intFromBool(above) -| note_count;
    const shown = @min(items, max_picker_rows, @max(notes_room, @min(items, 1)));
    var spare = room - shown;
    const show_above = above and spare != 0;
    spare -= @intFromBool(show_above);
    const show_notes = @min(note_count, spare);
    spare -= show_notes;
    return .{ .above = show_above, .shown = shown, .more = shown < items and spare != 0, .notes = show_notes };
}

/// The picker's model rows: each entry, and the "Other models" heading
/// before the first one the Host does not know.
pub fn pickerItems(state: *const State) usize {
    return state.menu.entries.len + @intFromBool(state.shownMenu().others() < state.menu.entries.len);
}

/// Why the picker has a line for `provider`'s sign-in: its list loads or
/// stands in for an unavailable live one, or the Host does not serve it.
pub fn pickerNote(state: *const State, provider: Provider) ?enum { pending, fallback, login } {
    const menu = &state.menu;
    const kept = menu.entries.len != 0 or for (menu.sources.values) |source| {
        if (source != null) break true;
    } else false;
    if (state.menu_read != .read and !kept) return null;
    const source = menu.sources.get(provider) orelse return .login;
    return switch (source) {
        .pending => .pending,
        .catalog_fallback => .fallback,
        .catalog, .live => null,
    };
}

const Item = union(enum) { gap, heading: Group, row: usize, more: usize };

/// Lines of the list, group by group: a gap before each group but the
/// first, its heading, its shown rows, then its "more" line when folded.
pub const ListLines = struct {
    first_line: std.enums.EnumArray(Group, usize),
    shown: std.enums.EnumArray(Group, usize),

    pub fn of(state: *const State) ListLines {
        var lines_of: ListLines = .{ .first_line = .initFill(0), .shown = .initFill(0) };
        var line: usize = 0;
        for (std.enums.values(Group)) |group| {
            const run = state.runs.get(group);
            if (run.len == 0) continue;
            if (line != 0) line += 1;
            const shown = if (folded(state, group)) fold_rows else run.len;
            lines_of.first_line.set(group, line);
            lines_of.shown.set(group, shown);
            line += 1 + shown + @intFromBool(shown < run.len);
        }
        return lines_of;
    }

    pub fn lineOf(self: *const ListLines, state: *const State, at: usize) usize {
        const group = state.rows.items[state.order.items[at]].group();
        return self.first_line.get(group) + 1 + (at - state.runs.get(group).start);
    }

    pub fn item(self: *const ListLines, state: *const State, line: usize) ?Item {
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

/// The row title: its Label, else the first line of its first Message (a
/// greyed hint), else its reference.
pub fn title(state: *const State, row: *const Row) session_line.Name {
    return session_line.name(if (row.label) |*text| text.slice() else null, state.lineOf(row), &row.reference);
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
    turn: ?u64 = null,
    first_action: ?u64 = null,
};

fn session(ref: *const [6]u8, state: WorkState, options: TestSession) Listed {
    return .{
        .reference = ref.*,
        .workspace = options.workspace,
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
/// A key the table binds, through the route the state's input mode picks.
fn press(state: *State, draft: Draft, action: Action) !Effects {
    const input: Input = if (state.inputMode() == .choice) .{ .choice = .{ .action = action } } else .{ .composer = .{ .action = action } };
    return step(state, .{ .composed = .{ .input = input, .draft = draft } });
}

/// ← or → at the sign-in choice.
fn choose(state: *State, side: enum { left, right }) !Effects {
    std.debug.assert(state.inputMode() == .choice);
    return step(state, .{ .composed = .{ .input = .{ .choice = if (side == .left) .left else .right }, .draft = .{} } });
}

var test_edits: u32 = 0;

/// Types `text` as the whole draft, its caret at the end, as the shell's
/// line editor reports an edit, and returns that draft.
fn typeText(state: *State, text: []const u8) !Draft {
    // Each typed draft is a new edit, as the line editor counts them.
    test_edits +%= 1;
    const draft: Draft = .{ .bytes = text, .cursor = text.len, .edits = test_edits };
    try expectEffects(&.{}, try step(state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = draft } }));
    drawWithRoom(state, draft);
    return draft;
}

/// What a frame with room for the command list leaves the shell keeping.
fn drawWithRoom(state: *State, draft: Draft) void {
    state.commands = nextCommands(state, draft);
    if (state.commands) |*shown| shown.drew(true);
}

/// The line editor's Enter on `draft`.
fn submit(state: *State, draft: Draft) !Effects {
    const input: Input = if (state.inputMode() == .choice) .{ .choice = .enter } else .{ .composer = .submit };
    return step(state, .{ .composed = .{ .input = input, .draft = draft } });
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
            .save_default => |binding| {
                try std.testing.expectEqual(binding.provider, got.save_default.provider);
                try std.testing.expectEqualStrings(binding.model.slice(), got.save_default.model.slice());
            },

            .notify => |alert| {
                try std.testing.expectEqualStrings(alert.name, got.notify.name);
                try std.testing.expectEqual(alert.kind, got.notify.kind);
                try std.testing.expectEqual(alert.more, got.notify.more);
            },
            .append => |text| try std.testing.expectEqualStrings(text, got.append),
            .command => |command| {
                try std.testing.expectEqual(command.name, got.command.name);
                try std.testing.expectEqualStrings(command.text, got.command.text);
                try std.testing.expectEqual(command.session, got.command.session);
            },
            .list_models, .clear_draft, .exit => {},
        }
    }
}

fn expectSelected(state: *const State, expected: *const [6]u8) !void {
    try std.testing.expectEqualStrings(expected, &(state.selected orelse return error.TestExpectedSelection));
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

/// The rows the picker tests open on: work, ends and an approval.
const picker_rows = [_]Listed{
    session("s0rt00", .{ .working = ago(0) }, .{ .label = "Started just now" }),
    session("f1n1sh", .{ .finished = ago(1) }, .{ .label = "Finished a second ago" }),
    session("a5k1ng", .{ .approval = ago(2) }, .{ .label = "Asked two seconds ago" }),
    session("f4iled", .{ .failed = .{ .since = test_now_s - 3, .code = bounded(session_work.max_code_bytes, "provider_error"), .resets_at = null } }, .{ .label = "Failed three seconds ago" }),
    session("w0rk00", .{ .working = ago(40) }, .{ .label = "Working a while" }),
};

/// Your Sessions at work and waiting, beside others' work and ends.
const spinning = [_]Listed{
    session("y0urs1", .{ .working = ago(40) }, .{ .label = "Mine, thinking", .yours = true }),
    session("y0urs2", .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .{ .label = "Mine, running", .yours = true }),
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
    const line = text[std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1 .. at];
    return std.mem.trim(u8, line, " ");
}

fn expectSaid(text: ?[]const u8, asking: bool, stoppable_: bool, said: Said) !void {
    try std.testing.expectEqualStrings(text orelse "", said.text orelse "");
    try std.testing.expectEqual(text == null, said.text == null);
    try std.testing.expectEqual(asking, said.asking);
    try std.testing.expectEqual(stoppable_, said.stoppable);
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

fn expectLines(text: []const u8, first: usize, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..first) |_| _ = lines.next();
    for (expected) |line| try std.testing.expectEqualStrings(line, std.mem.trimEnd(u8, lines.next().?, " "));
}

test "Enter takes a row only from a list the latest frame drew, and a long line still runs" {
    var state = try opened(&mixed);
    defer state.deinit();
    // A screen too short for the list drew none: Enter runs `/e` as typed.
    var draft = try typeText(&state, "/e");
    state.commands.?.drew(false);
    const unlisted = try submit(&state, draft);
    for (unlisted.slice()) |effect| try std.testing.expect(effect != .exit);
    draft = try typeText(&state, "/e");
    try expectEffects(&.{.exit}, try submit(&state, draft));
    // A value that completes a line longer than any scratch line runs it.
    const long: [600]u8 = @splat('w');
    draft = try typeText(&state, "/configure --workspace /" ++ long ++ " --permission-mode a");
    try std.testing.expect(draft.bytes.len > 512);
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try std.testing.expectEqualStrings("ask", state.settings.get(startOption("permission-mode").?).?);
}

test "a key on a draft changed since the latest frame acts on that draft's list when the frame drew one" {
    var state = try opened(&mixed);
    defer state.deinit();
    // The frame drew `/e`'s list; `x` changes the draft before a frame
    // lists it, and Enter takes /exit from `/ex`'s list.
    const drawn = try typeText(&state, "/e");
    try std.testing.expectEqual(.drawn, state.commands.?.seen);
    const typed: Draft = .{ .bytes = "/ex", .cursor = 3, .edits = drawn.edits +% 1 };
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .composer = .append }, .draft = typed } }));
    try expectEffects(&.{.exit}, try submit(&state, typed));
    // The frame drew `/m`'s list; Backspace leaves `/`, whose list Down
    // moves through, the selected Session kept.
    const model = try typeText(&state, "/m");
    const erased: Draft = .{ .bytes = "/", .cursor = 1, .edits = model.edits +% 1 };
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = erased } }));
    const selected = state.selected;
    try expectEffects(&.{}, try press(&state, erased, .next));
    try std.testing.expectEqual(selected, state.selected);
    try std.testing.expectEqual(@as(usize, 1), state.commands.?.highlight);
    // Esc closes that list and keeps the draft.
    try expectEffects(&.{}, try press(&state, erased, .clear));
    try std.testing.expectEqual(.closed, state.commands.?.seen);
}

test "arrows move the command list's highlight, and Enter takes it: a word another follows, or the command it completes" {
    var state = try opened(&mixed);
    defer state.deinit();
    var draft = try typeText(&state, "/");
    // The selected Session's row stays put while the list takes the arrows.
    const selected = state.selected;
    _ = try step(&state, .{ .composed = .{ .input = .{ .composer = .{ .action = .next } }, .draft = draft } });
    try std.testing.expectEqual(@as(usize, 1), state.commands.?.highlight);
    try std.testing.expectEqual(selected, state.selected);
    // Enter on /exit, highlighted, runs it.
    try expectEffects(&.{.exit}, try submit(&state, draft));
    // /configure alone only says its usage: Enter adds its word and a
    // space, for an option.
    state.commands.?.highlight = 0;
    try expectEffects(&.{.{ .append = "configure " }}, try submit(&state, draft));
    // An option that takes a value is added for it, and the next list
    // starts at its top, however far down the highlight was.
    draft = try typeText(&state, "/configure ");
    state.commands.?.highlight = 4;
    try expectEffects(&.{.{ .append = "--label " }}, try submit(&state, draft));
    // A draft too full for the word refuses it and stays as it was; its
    // next frame lists it from the top too.
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(@as(usize, 0), state.commands.?.highlight);
    draft = try typeText(&state, "/configure --permission-mode ");
    const modes = state.commands.?.list;
    try std.testing.expectEqualStrings("ask", modes.shown()[0].word);
    // A value is whole: Enter holds the setting.
    state.commands.?.highlight = 1;
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try std.testing.expectEqualStrings("bypass", state.settings.get(startOption("permission-mode").?).?);
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

test "start settings are the options session start shares with /configure" {
    const expected = [_][]const u8{ "provider", "model", "workspace", "tools", "loaded-tools", "permission-mode", "compaction-trigger", "output-reservation", "reasoning-effort", "label" };
    try std.testing.expectEqual(expected.len, start_options.len);
    for (expected, start_options) |want, got| try std.testing.expectEqualStrings(want, got);
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

test "session resume opens its Session through the overview, which then keeps it selected" {
    var state = try testState();
    defer state.deinit();
    try expectEffects(&.{.{ .open = "c3d4e5".* }}, try step(&state, .{ .open = "c3d4e5".* }));
    // The first listing finds the row; the selection waited for it.
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = test_now_s * 1000 }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectSelected(&state, "c3d4e5");
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
        try writeDeparture(&state, null, &departure.writer);
        try std.testing.expectEqualStrings(case.departure, departure.written());
    }
    // With no start in flight, leaving says nothing of one.
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .leave));
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings("", departure.written());
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

test "a listing notifies once of each Session that newly finished, failed or needs approval, naming the most urgent" {
    // What the overview opened on is not news.
    var state = try opened(&mixed);
    defer state.deinit();
    const fixing = session("k7m2qx", .{ .finished = ago(0) }, .{ .label = "Fix the flaky resize test", .yours = true, .turn = 1 });
    try expectEffects(&.{.{ .notify = .{ .name = "Fix the flaky resize test", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(2), &.{fixing}));
    // Rereading the same finish, or a full listing of unchanged rows, is not news.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{fixing}));
    var unchanged = mixed;
    unchanged[0] = fixing;
    try expectEffects(&.{}, try refresh(&state, .full, testToken(4), &unchanged));
    // The next Turn's finish in the same second is news of its own.
    var next_turn = fixing;
    next_turn.turn = 2;
    try expectEffects(&.{.{ .notify = .{ .name = "Fix the flaky resize test", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(5), &.{next_turn}));
    // Approval outranks a failure and a finish listed before it; a stop and
    // work under way are no news; an unseen Session's finish is.
    try expectEffects(&.{.{ .notify = .{ .name = "Find why store tests fail", .kind = .approval, .more = 2 } }}, try refresh(&state, .changed, testToken(6), &.{
        session("b2c3d4", .{ .failed = .{ .since = test_now_s, .code = bounded(session_work.max_code_bytes, "provider_http_500"), .resets_at = null } }, .{ .label = "Profile the curl send queue" }),
        session("e5f6g7", .{ .stopped = .{ .since = test_now_s, .cause = .stop } }, .{ .label = "List unused build steps" }),
        session("d4e5f6", .{ .working = ago(0) }, .{ .label = "Trace Host shutdown order" }),
        session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 1 }),
        session("zz9zz9", .{ .finished = ago(0) }, .{ .first = null }),
    }));
    // A Session the overview never saw, unnamed, is named by its reference.
    try expectEffects(&.{.{ .notify = .{ .name = "yy8yy8", .kind = .finished, .more = 0 } }}, try refresh(&state, .changed, testToken(7), &.{session("yy8yy8", .{ .finished = ago(0) }, .{ .first = null })}));
    // The next Action to wait, once the first is decided, is a new wait.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(8), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 1 })}));
    try expectEffects(&.{.{ .notify = .{ .name = "Find why store tests fail", .kind = .approval, .more = 0 } }}, try refresh(&state, .changed, testToken(9), &.{session("a1b2c3", .{ .approval = ago(0) }, .{ .label = "Find why store tests fail", .first_action = 2 })}));
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

test "the listing and the open conversation read one record, so each news comes once, whichever reads it first" {
    var state = try opened(&mixed);
    defer state.deinit();
    const fixing = session("k7m2qx", .{ .finished = ago(0) }, .{ .label = "Fix the flaky resize test", .yours = true, .turn = 1 });
    const read: Observed = .{ .reference = "k7m2qx".*, .work = .{ .state = .{ .finished = ago(0) }, .turn = 1 }, .name = "Fix the flaky resize test", .opening = false };
    const finished: Alert = .{ .name = "Fix the flaky resize test", .kind = .finished, .more = 0 };
    // The conversation reads the finish first and notifies. Back on the
    // overview before a listing caught up, the listing that does is no news.
    try expectEffects(&.{.{ .notify = finished }}, try step(&state, .{ .observed = read }));
    try expectEffects(&.{}, try step(&state, .{ .observed = read }));
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{fixing}));
    // Under the conversation the listing reads the next Turn's finish first,
    // with another Session's; the conversation's read of it is no news.
    var next_turn = fixing;
    next_turn.turn = 2;
    try expectEffects(&.{.{ .notify = .{ .name = "Fix the flaky resize test", .kind = .finished, .more = 1 } }}, try refresh(&state, .changed, testToken(3), &.{
        next_turn,
        session("b2c3d4", .{ .finished = ago(0) }, .{ .label = "Profile the curl send queue" }),
    }));
    var read_next = read;
    read_next.work.turn = 2;
    try expectEffects(&.{}, try step(&state, .{ .observed = read_next }));
    // A Session no listing has shown yet: the read its conversation opens on
    // is no news, nor is the listing that first shows it; its finish, once
    // the conversation notified it, is no news to the listing either.
    const started = session("n3w5es", .{ .approval = ago(0) }, .{ .label = "Start the notes", .first = null, .first_action = 3 });
    try expectEffects(&.{}, try step(&state, .{ .observed = .{ .reference = "n3w5es".*, .work = .{ .state = .{ .approval = ago(0) }, .first_action = 3 }, .name = "Start the notes", .opening = true } }));
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(4), &.{started}));
    try expectEffects(&.{.{ .notify = .{ .name = "Start the notes", .kind = .finished, .more = 0 } }}, try step(&state, .{ .observed = .{ .reference = "n3w5es".*, .work = .{ .state = .{ .finished = ago(0) }, .turn = 1 }, .name = "Start the notes", .opening = false } }));
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(5), &.{session("n3w5es", .{ .finished = ago(0) }, .{ .label = "Start the notes", .first = null, .turn = 1 })}));
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
    for ([_][]const u8{ "provider_http_401", "provider_sign_in_required", "provider_sign_in_refresh_token_expired" }) |code| try std.testing.expectEqual(Band{ .trouble = .sign_in }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, code, null) }, null)).?);
    try std.testing.expect(signInCode("provider_sign_in_refresh_token_expired") and signInCode("provider_http_401") and signInCode("provider_sign_in_required"));
    try std.testing.expect(!signInCode("provider_authentication_backend_failed"));
    // A later completion clears it; a login in this terminal hides it until a newer failure.
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ session("ffffff", .{ .finished = ago(30) }, .{}), failedRow("aaaaaa", 60, "provider_http_401", null) }, null));
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_http_401", null) }, test_now_s - 30));
    try std.testing.expectEqual(Band{ .trouble = .sign_in }, (try bandOf(&.{ done, failedRow("aaaaaa", 10, "provider_http_401", null) }, test_now_s - 30)).?);
    // A rejected API key: its own remedy, not a sign-in.
    try std.testing.expectEqual(Band{ .trouble = .api_key }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, failure_class.api_key_rejected, null) }, null)).?);
    try std.testing.expect(!signInCode(failure_class.api_key_rejected));
    // Quota: shown with its reset time until that time passes.
    try std.testing.expectEqual(Band{ .trouble = .quota, .resets_at = test_now_s + 1200 }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 1200) }, null)).?);
    try std.testing.expectEqual(Band{ .trouble = .quota }, (try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_quota", null) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{ done, failedRow("aaaaaa", 60, "provider_plan", test_now_s) }, null));
    // Rate limit: while any row retries for a 429.
    try std.testing.expectEqual(Band{ .trouble = .rate_limit, .sessions = 2 }, (try bandOf(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20), retryRow("cccccc", "provider_temporary_error", 20) }, null)).?);
    try std.testing.expectEqual(@as(?Band, null), try bandOf(&.{retryRow("aaaaaa", "provider_temporary_error", 10)}, null));
    // A retry already due is pending, not retrying.
    var state = try opened(&.{retryRow("aaaaaa", "provider_temporary_http_429", 10)});
    defer state.deinit();
    try std.testing.expectEqual(@as(?Band, null), band(state.rows.items, (test_now_s + 10) * 1000, null));
    // Priority: sign-in, then quota, then rate limit.
    try std.testing.expectEqual(Trouble.sign_in, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), failedRow("bbbbbb", 90, "provider_http_401", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
    try std.testing.expectEqual(Trouble.quota, (try bandOf(&.{ failedRow("aaaaaa", 60, "provider_quota", null), retryRow("cccccc", "provider_temporary_http_429", 10) }, null)).?.trouble);
}

fn repeated(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime {
        var bytes: [text.len * count]u8 = undefined;
        for (0..count) |at| @memcpy(bytes[at * text.len ..][0..text.len], text);
        const result = bytes;
        return &result;
    }
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
fn answerModels(state: *State, lists: []const model_list.Entry) !void {
    try expectEffects(&.{}, try step(state, .{ .models = .{ .menu = try model_picker.testMenu(lists) } }));
}

/// Types /model and answers its model-list read with `lists`.
fn openPicker(state: *State, lists: []const model_list.Entry) !void {
    const draft = try typeText(state, "/model");
    try expectEffects(&.{ .clear_draft, .list_models }, try submit(state, draft));
    try answerModels(state, lists);
}

/// An overview on a 60 by 24 screen with `default`.
fn pickerState(default: ?Default) !State {
    var state = try opened(&picker_rows);
    state.default = default;
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 24 } }));
    return state;
}

/// The save of `model` with `provider` ended as `outcome`.
fn saveEnded(provider: []const u8, model: []const u8, outcome: Saved) Event {
    return .{ .saved = .{ .ended = .{ .binding = Default.of(provider, model).?, .outcome = outcome } } };
}

/// The model the picker shows at `row`, the default first.
fn shownRow(state: *const State, row: usize) []const u8 {
    return state.shownMenu().entry(row).id;
}

fn highlightModel(state: *State, draft: Draft, model: []const u8) !void {
    try expectEffects(&.{}, try press(state, draft, .first));
    for (0..state.menu.entries.len) |_| {
        if (state.picker.?.highlight.eql(model)) return;
        try expectEffects(&.{}, try press(state, draft, .next));
    }
    return error.TestModelNotOffered;
}

/// The picker's "N more" line shows: the list's own sit a column left.
fn pickerMore(screen: []const u8) bool {
    var lines = std.mem.splitScalar(u8, screen, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trimEnd(u8, line, " ");
        if (text.len > 4 and std.mem.startsWith(u8, text, "    ") and std.ascii.isDigit(text[4]) and std.mem.endsWith(u8, text, " more")) return true;
    }
    return false;
}

// A bounded menu for navigation tests; catalog-list coverage belongs to model_list.
const chatgpt: model_list.Entry = .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-6.1-sol\ngpt-6.1-terra\ngpt-6-sol\ngpt-6-astra\ngpt-5.6-sol\ngpt-5.6-terra\ngpt-5.6-luna\ngpt-5.5\n" } } };
const both = [_]model_list.Entry{ chatgpt, .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-5.5\nunlisted-a\nunlisted-z\n" } } } };

test "a start submitted before the pick's save ends runs on the pick" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    var draft = try typeText(&state, "");
    try highlightModel(&state, draft, "gpt-6-luna");
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6-luna").? }}, try submit(&state, draft));
    // The save is left unanswered.
    draft = try typeText(&state, "Try");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(usize, 1), effects.len);
    const binding = effects.slice()[0].start.binding;
    try std.testing.expectEqualStrings("codex", binding.provider.?);
    try std.testing.expectEqualStrings("gpt-6-luna", binding.model.?);
}

test "picks made during one save are saved after it, only the newest" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    const draft = try typeText(&state, "");
    try openPicker(&state, &.{chatgpt});
    try highlightModel(&state, draft, "gpt-5.5");
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-5.5").? }}, try submit(&state, draft));
    // Two more picks while it runs: neither is refused, and neither saves yet.
    for ([_][]const u8{ "gpt-6-luna", "gpt-6.1-sol" }) |model| {
        try openPicker(&state, &.{chatgpt});
        while (!state.picker.?.highlight.eql(model)) try expectEffects(&.{}, try press(&state, draft, .next));
        try expectEffects(&.{}, try submit(&state, draft));
        try std.testing.expectEqualStrings(model, state.default.?.model.slice());
        try std.testing.expect(state.notice == null);
    }
    // The first save ends: the newest pick is saved next, and the overview
    // does not claim the first one stands.
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6.1-sol").? }}, try step(&state, saveEnded("codex", "gpt-5.5", .done)));
    try std.testing.expect(state.notice == null);
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-6.1-sol", .done)));
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "gpt-6.1-sol") != null);
}

test "every pick is saved, even of the default the overview opened on, and an untouched overview saves nothing" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try std.testing.expect(state.save.wanted == null and state.save.running == null);
    const draft = try typeText(&state, "");
    try openPicker(&state, &.{chatgpt});
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6-luna").? }}, try submit(&state, draft));
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-6-luna", .done)));
    try openPicker(&state, &.{chatgpt});
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6-luna").? }}, try submit(&state, draft));
}

test "a failed save is not retried, but picking the same model again saves it" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    const draft = try typeText(&state, "");
    try openPicker(&state, &.{chatgpt});
    try highlightModel(&state, draft, "gpt-5.5");
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-5.5").? }}, try submit(&state, draft));
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-5.5", .{ .failed = null })));
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "not saved") != null);
    try openPicker(&state, &.{chatgpt});
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-5.5").? }}, try submit(&state, draft));
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-5.5", .done)));
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "New Sessions use gpt-5.5") != null);
}

test "the lines that name the next Session's model name the saved effort its start applies" {
    // gpt-6-luna offers max and gpt-5.5 does not. An effort /configure
    // holds, `default` included, keeps the saved one from the next start,
    // but not from launches after this overview.
    const Case = struct { model: []const u8, held: ?[]const u8 = null, saved: ?ReasoningEffort, next: []const u8, later: []const u8 };
    const cases = [_]Case{
        .{ .model = "gpt-6-luna", .saved = .max, .next = " · max", .later = " · max" },
        .{ .model = "gpt-6-luna", .saved = null, .next = "", .later = "" },
        .{ .model = "gpt-5.5", .saved = .max, .next = "", .later = "" },
        .{ .model = "gpt-6-luna", .held = "low", .saved = .max, .next = "", .later = " · max" },
        .{ .model = "gpt-6-luna", .held = "default", .saved = .max, .next = "", .later = " · max" },
    };
    for (cases) |case| for ([_]Saved{ .done, .{ .failed = null }, .unconfirmed }) |outcome| {
        var state = try pickerState(Default.of("codex", case.model));
        defer state.deinit();
        var line: [64]u8 = undefined;
        if (case.held) |held| try expectEffects(&.{.clear_draft}, try submit(&state, try typeText(&state, try std.fmt.bufPrint(&line, "/configure --reasoning-effort {s}", .{held}))));
        const draft = try typeText(&state, "");
        try openPicker(&state, &.{chatgpt});
        try expectEffects(&.{.{ .save_default = Default.of("codex", case.model).? }}, try submit(&state, draft));
        var ended = saveEnded("codex", case.model, outcome);
        ended.saved.saved_effort = case.saved;
        // Each outcome but `unconfirmed` is said on screen, the one after
        // leaving on the way out.
        if (outcome == .unconfirmed) _ = try step(&state, .leave);
        try expectEffects(&.{}, try step(&state, ended));
        var expected: [160]u8 = undefined;
        switch (outcome) {
            .done => try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "New Sessions use {s}{s} · ChatGPT", .{ case.model, case.next }), state.notice.?.text()),
            .failed => try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Default not saved (check ~/.config/rui/preferences); new Sessions here still use {s}{s} · ChatGPT", .{ case.model, case.next }), state.notice.?.text()),
            .unconfirmed => {
                var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer departure.deinit();
                try writeDeparture(&state, case.saved, &departure.writer);
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "rui: New Sessions use {s}{s} · ChatGPT; durability unconfirmed, inspect ~/.config/rui/preferences.\n", .{ case.model, case.later }), departure.written());
            },
        }
    };
}

test "Shift-Up and Shift-Down choose a Session in both picker steps, and leave the picker as it was" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    const draft = try typeText(&state, "");
    try openPicker(&state, &both);
    for (0..2) |_| {
        const chosen = state.selected.?;
        const highlight = state.picker.?.highlight;
        const picker_step = state.picker.?.step;
        try expectEffects(&.{}, try press(&state, draft, .select_next));
        try std.testing.expect(!std.mem.eql(u8, &chosen, &state.selected.?));
        try expectEffects(&.{}, try press(&state, draft, .select_previous));
        try std.testing.expectEqualSlices(u8, &chosen, &state.selected.?);
        try std.testing.expect(state.picker.?.highlight.eql(highlight.slice()));
        try std.testing.expectEqual(std.meta.activeTag(picker_step), std.meta.activeTag(state.picker.?.step));
        // gpt-6-luna is offered by both sign-ins: Enter asks which.
        if (state.picker.?.step == .models) try expectEffects(&.{}, try submit(&state, draft));
    }
    try std.testing.expect(state.inputMode() == .choice);
}

test "a save that ends after the person left is told on the way out" {
    for ([_]Saved{ .done, .unconfirmed, .{ .failed = null } }) |saved| {
        var state = try pickerState(null);
        defer state.deinit();
        try openPicker(&state, &.{chatgpt});
        const draft = try typeText(&state, "");
        try highlightModel(&state, draft, "gpt-6-luna");
        _ = try submit(&state, draft);
        try expectEffects(&.{}, try step(&state, .leave));
        try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-6-luna", saved)));
        var bytes: [max_late_save_bytes]u8 = undefined;
        var departure = std.Io.Writer.fixed(&bytes);
        try writeDeparture(&state, null, &departure);
        try std.testing.expect(std.mem.indexOf(u8, departure.buffered(), "gpt-6-luna") != null);
    }
}

test "a start the Host refuses for want of its sign-in names the sign-in and its login" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    const draft = try typeText(&state, "Try");
    _ = try submit(&state, draft);
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .failed = "model_capability_unavailable" } }));
    const said = state.notice.?.text();
    try std.testing.expect(std.mem.indexOf(u8, said, Provider.codex.signIn()) != null);
    try std.testing.expect(std.mem.indexOf(u8, said, Provider.codex.login()) != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "model_capability_unavailable") == null);
}

test "a key that acts on a Session brings the Sessions back first, so it acts where they show" {
    var state = try opened(&mixed);
    defer state.deinit();
    const first = state.selected.?;
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    for ([_]Action{ .next, .select_next, .last, .stop }) |action| {
        errdefer std.debug.print("action={t}\n", .{action});
        _ = try submit(&state, try typeText(&state, "/help"));
        try std.testing.expect(state.panel != null);
        state.selected = first;
        _ = try press(&state, .{}, action);
        try std.testing.expect(state.panel == null);
        if (action == .stop) try std.testing.expectEqualStrings(&first, &state.prompt.?.stop) else try std.testing.expect(!std.mem.eql(u8, &first, &state.selected.?));
        state.prompt = null;
    }
    // Enter on an empty draft opens the selected Session from under it.
    _ = try submit(&state, try typeText(&state, "/help"));
    try expectEffects(&.{.{ .open = state.selected.? }}, try submit(&state, .{}));
    try std.testing.expect(state.panel == null);
}

/// The answer to the command in flight.
fn ranWith(state: *State, ran: Ran) !void {
    try expectEffects(&.{}, try step(state, .{ .ran = ran }));
}

test "/rename under a panel brings the Sessions back, so the list shows the row it names" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    _ = try submit(&state, try typeText(&state, "/help"));
    try std.testing.expect(state.panel != null);
    var line = "/rename lane four".*;
    try expectEffects(&.{ .clear_draft, .{ .command = .{ .name = .rename, .session = state.selected.?, .text = &line } } }, try submit(&state, try typeText(&state, &line)));
    try std.testing.expect(state.panel == null);
}

test "a command the person did not see end is named on the way out" {
    const Case = struct { ran: ?Ran, leave_first: bool, expected: []const u8 };
    for ([_]Case{
        .{ .ran = null, .leave_first = true, .expected = "rui: /setup did not run.\n" },
        .{ .ran = .{ .output = "Saved defaults.\nStore: /s" }, .leave_first = true, .expected = "rui: /setup output:\nSaved defaults.\nStore: /s\n" },
        // A failure while it ran ends the overview before it can show.
        .{ .ran = .{ .output = "rui: setup save failed\n", .outcome = .failed }, .leave_first = false, .expected = "rui: /setup output:\nrui: setup save failed\n" },
        .{ .ran = .{ .output = "" }, .leave_first = true, .expected = "" },
        .{ .ran = .{ .output = "Store: /s\n", .cut = true }, .leave_first = true, .expected = "rui: /setup output:\nStore: /s\nOutput cut at 8 KiB.\n" },
    }) |case| {
        var state = try opened(&.{});
        defer state.deinit();
        _ = try submit(&state, try typeText(&state, "/setup"));
        if (case.leave_first) _ = try step(&state, .leave);
        if (case.ran) |ran| try ranWith(&state, ran);
        if (!case.leave_first) _ = try step(&state, .leave);
        var bytes: [max_late_command_bytes]u8 = undefined;
        var departure = std.Io.Writer.fixed(&bytes);
        try writeDeparture(&state, null, &departure);
        try std.testing.expectEqualStrings(case.expected, departure.buffered());
    }
}

/// Shared pure fixtures for the UI-root grid assertions.
const Core = @This();
pub const Test = struct {
    pub const ago = Core.ago;
    pub const answerModels = Core.answerModels;
    pub const both = Core.both;
    pub const bounded = Core.bounded;
    pub const chatgpt = Core.chatgpt;
    pub const choose = Core.choose;
    pub const configure_usage = Core.configure_usage;
    pub const drawWithRoom = Core.drawWithRoom;
    pub const expectEffects = Core.expectEffects;
    pub const expectLines = Core.expectLines;
    pub const expectSaid = Core.expectSaid;
    pub const expectSelected = Core.expectSelected;
    pub const failedRow = Core.failedRow;
    pub const highlightModel = Core.highlightModel;
    pub const markOf = Core.markOf;
    pub const mixed = Core.mixed;
    pub const openPicker = Core.openPicker;
    pub const opened = Core.opened;
    pub const pickerMore = Core.pickerMore;
    pub const pickerState = Core.pickerState;
    pub const press = Core.press;
    pub const ranWith = Core.ranWith;
    pub const refresh = Core.refresh;
    pub const repeated = Core.repeated;
    pub const respond = Core.respond;
    pub const retryRow = Core.retryRow;
    pub const saveEnded = Core.saveEnded;
    pub const session = Core.session;
    pub const shownRow = Core.shownRow;
    pub const spinning = Core.spinning;
    pub const startOption = Core.startOption;
    pub const submit = Core.submit;
    pub const testState = Core.testState;
    pub const testToken = Core.testToken;
    pub const test_now_s = Core.test_now_s;
    pub const typeText = Core.typeText;
};
