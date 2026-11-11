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
const session_archive = @import("session_archive.zig");
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
const model_picker_view = @import("model_picker_view.zig");
const overview_style = @import("overview_style.zig");
const provider_name = @import("provider_name.zig");
const session_work = @import("session_work.zig");
const session_upgrade = @import("session_upgrade.zig");
const upgrade_status = @import("upgrade_status.zig");
const slash_commands = @import("slash_commands.zig");
const skill_completion = @import("skill_completion.zig");
const skill_suggestions = @import("skill_suggestions.zig");
const submission = @import("submission_state.zig");
pub const commands = slash_commands.overview;
const TerminalText = @import("TerminalText.zig");
const theme = @import("theme.zig");
const work_line = @import("work_line.zig");
const workspace_path = @import("workspace_path.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

const Allocator = std.mem.Allocator;
pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;
pub const Token = change_ring.Token;
pub const ArchiveState = session_archive.State;
pub const ArchiveFilter = session_archive.Filter;

fn archiveViewName(filter: ArchiveFilter) []const u8 {
    return switch (filter) {
        .active => "Unarchived",
        .archived => "Archived",
        .all => "All",
    };
}
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

pub const Group = enum { needs_you, yours, active, idle, finished, ended };
pub const Mark = enum { needs_you, active, queued, waiting, finished, failed, stopped };
pub const Colour = overview_style.Colour;
pub const Background = overview_style.Background;

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
    /// A failed row names its failure's cause.
    cause: bool = false,
    /// Ctrl-X may stop a Session in this state.
    stoppable: bool,
};

/// The one per-kind table. `step` and `render` read it and switch on no kind.
pub const rules = std.enums.EnumArray(Kind, Rule).init(.{
    .idle = .{ .group = .idle, .mark = .waiting, .colour = .normal, .word = "idle", .stoppable = false },
    .pending = .{ .group = .active, .mark = .queued, .colour = .quiet, .stoppable = true },
    .working = .{ .group = .active, .mark = .active, .colour = .ink, .spins = true, .stoppable = true },
    .retrying = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .stoppable = true },
    .bash = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .spins = true, .stoppable = true },
    .approval = .{ .group = .needs_you, .mark = .needs_you, .colour = .attention, .stoppable = true },
    .stopping = .{ .group = .active, .mark = .active, .colour = .ink, .says = true, .stoppable = false },
    .finished = .{ .group = .finished, .mark = .finished, .colour = .mark, .word = "finished", .stoppable = false },
    .failed = .{ .group = .ended, .mark = .failed, .colour = .failure, .word = "failed", .cause = true, .stoppable = false },
    .stopped = .{ .group = .ended, .mark = .stopped, .colour = .normal, .word = "stopped", .stoppable = false },
});

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8 }).init(.{
    .needs_you = .{ .unicode = "?", .ascii = "?" },
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
    .needs_you = .{ .title = "Needs you", .folds = false },
    .yours = .{ .title = "Yours", .folds = false },
    .active = .{ .title = "Active", .folds = false, .under_way = true },
    .idle = .{ .title = "Idle", .folds = false },
    .finished = .{ .title = "Finished", .folds = true },
    .ended = .{ .title = "Stopped or failed", .folds = true },
});

/// What a key does in the overview. `clear` empties the draft, else the
/// held start settings. `select_*` choose a Session even while the picker
/// shows; `previous` and `next` move the picker's highlight there.
pub const Action = enum { previous, next, select_previous, select_next, first, last, clear, exit, stop, archive };

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

/// Where the next input goes: the composer, or frozen while a start waits.
pub const InputMode = enum { compose, frozen };

/// How the shell takes one input: editing, or the frozen composer's keys.
pub const Route = enum { edit, frozen };

/// What one input did, and the draft as that input left it.
pub const Composed = struct { input: Input, draft: Draft };

/// One input through the composer or the frozen composer.
pub const Input = union(enum) {
    composer: keymap.Outcome(Action),
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
    archive_state: ArchiveState = .active,
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
            .archive_state = row.archive_state,
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
/// Bytes in a mebibyte, the unit memory shows in below a gibibyte.
pub const mib = 1024 * 1024;

/// Live physical memory, as the shell reads it about once a second.
pub const Memory = @import("process_memory.zig").Memory;

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
    picker_action: struct { action: model_picker_view.Action, draft: Draft },
    /// The size of the screen the shell draws next; keys read until the
    /// next one act on that screen.
    resized: Size,
    /// The shell's clock, in Unix milliseconds.
    tick: u64,
    list: ListReply,
    first_line: FirstLine,
    stop: StopResult,
    archive: ArchiveResult,
    start: StartResult,
    /// The overview ended: later results are kept for `writeDeparture`.
    leave,
    /// Opens a Session named outside the overview, as `session resume` does.
    open: Reference,
    /// The Host's facts, read as a listing starts; null when it gave none.
    host: ?Host,
    /// A memory read ended.
    memory: Memory,
    /// A needs-you row's command read ended.
    command: CommandText,
    /// Where the run /upgrade started stands now.
    upgrade: upgrade_status.Run,
    conversed: Conversed,
    /// A model-list read ended.
    models: ModelsRead,
    /// A save of the default ended.
    saved: SaveAnswer,
    /// A read the open conversation applied.
    observed: Observed,
    /// The command `step` asked the shell to run ended.
    ran: Ran,
    /// A pointer press on something a click acts on.
    clicked: Click,
    /// Esc left a conversation whose original is unconfirmed. The shell
    /// sends it only while `canHoldSend` says the ledger has room.
    unconfirmed: Unconfirmed,
};

/// What a click names, as the widget under it drew it: a Session to open,
/// a folded group to unfold, or the counts line's view name, which shows
/// only off the default view. A click names the thing and never a place,
/// so it means what the person saw whatever the list has become since.
pub const Click = union(enum) { open: Reference, unfold: Group, view };

/// What a click on a Sessions list line names; null for a heading, a gap
/// or the empty list's line, which take none.
pub fn clickOf(state: *const State, item: Item) ?Click {
    return switch (item) {
        .gap, .heading, .empty => null,
        .row => |at| .{ .open = state.rows.items[state.order.items[at]].reference },
        .more => |more| .{ .unfold = more.group },
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

/// What fills the list's lines; `State.listArea` says which.
pub const ListArea = enum { sessions, panel, picker };

pub const StatusLine = struct { text: []const u8, colour: Colour };

/// The overview's status bar: what `statusSaid` says, a notice by its first
/// line; else the newest unconfirmed send; null when all is quiet.
/// Borrows `state` and `buffer`.
pub fn statusLine(state: *const State, caps: Caps, buffer: *StatusBuffer) ?StatusLine {
    if (statusSaid(state, caps, buffer[0..upgrade_status.max_line_bytes])) |line| {
        const first = std.mem.indexOfScalar(u8, line.text, '\n') orelse line.text.len;
        return .{ .text = line.text[0..first], .colour = line.colour };
    }
    const unconfirmed = unconfirmedLine(state, buffer[0..max_unconfirmed_line_bytes]) orelse return null;
    return .{ .text = unconfirmed, .colour = .attention };
}

/// The ledger can hold a conversation's unconfirmed original.
pub fn canHoldSend(state: *const State) bool {
    return state.request_count < max_requests;
}

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

    /// A command that printed `printed` bytes, the first of which `kept`
    /// holds, and ran to the end if `ok`. Its failure counts as one while
    /// it ran only once its output went to the page (`rendering`); before
    /// that it never started.
    pub fn of(kept: []const u8, printed: usize, ok: bool, rendering: bool) Ran {
        return .{
            .output = kept[0..@min(printed, max_output_bytes)],
            .cut = printed > max_output_bytes,
            .outcome = if (ok) .done else if (rendering) .failed else .not_run,
        };
    }

    /// The shell reads the default saved defaults now give only after a
    /// `/setup` that ran.
    pub fn readsDefault(self: Ran, name: commands.Name) bool {
        return self.outcome == .done and name == .setup;
    }
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

    fn text(self: *const Panel) []const u8 {
        return switch (self.*) {
            .help => help_text,
            .output => |output| output.text,
        };
    }

    /// Rows it takes whole: its heading and its lines.
    fn rows(self: *const Panel) usize {
        return 2 + std.mem.count(u8, self.text(), "\n");
    }
};

/// What /help shows under its heading: the overview's keys, then its
/// commands, which its table lists.
const help_text = "Up/Down select · Shift-Up/Down always · Home/End first/last on empty draft\n" ++
    "Enter opens · Alt-A archives · Ctrl-X twice stops · Type a task to start\n" ++
    "Shift-Enter or Ctrl-J adds a line\n" ++
    "/ lists commands · Up/Down choose · Tab or Enter takes it\n" ++
    "Esc/Ctrl-G closes list, panel, draft, settings · Ctrl-C/Ctrl-D leaves\n" ++
    "\n" ++ std.mem.trimEnd(u8, commands.help, "\n");

/// How a model-list read ended.
pub const ModelsRead = union(enum) {
    /// The menu of the Host's lists, which the core now owns.
    menu: model_picker.Menu,
    /// The Host did not answer.
    unanswered,
    /// The Host answered with a list Rui cannot read.
    invalid,

    /// How a failed read ended: a list Rui cannot read, else no answer,
    /// which leaves the person nothing to do but try /model again, as when
    /// the Host is gone.
    pub fn failed(err: anyerror) ModelsRead {
        return switch (err) {
            error.InvalidModelList, error.InvalidResponse, error.ResponseTooLarge => .invalid,
            else => .unanswered,
        };
    }
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
/// work as `work`; `opening` when it is the read the conversation opened on.
pub const Observed = struct { reference: Reference, work: session_work.Work, opening: bool };

/// An input in the open conversation of `reference`, whose work it shows as
/// `work`: Ctrl-X there stops it as Ctrl-X on the Session's row does, and
/// any other input clears the overview's notice.
pub const ConversationInput = union(enum) {
    other,
    stop,
    archive: ArchiveState,
    unarchive,
    /// /upgrade: the same run the overview's starts.
    upgrade,
    /// Esc, while the run can still change nothing.
    cancel_upgrade,
    /// The conversation could not settle its Client work for the run, or
    /// read itself again after it: Host intents wait until another /upgrade.
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
    /// No answer came, as when the Host is down: the next listing asks again.
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
    start: StartRequest,
    open: Reference,
    stop: Reference,
    archive: ArchiveRequest,
    /// Read the Host's model lists.
    list_models,
    /// Save the person's default for new Sessions, as `rui defaults
    /// configure --provider --model` does, and answer with `saved`.
    save_default: Default,
    /// Esc asked the running Upgrade to cancel before it publishes.
    cancel_upgrade,
    /// Empty the line editor.
    clear_draft,
    /// Put this in place of part of the draft, as Tab does.
    replace: skill_completion.Replacement,
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
    effort: ?ReasoningEffort = null,

    pub fn of(provider: ?[]const u8, model: ?[]const u8) ?Default {
        var binding: Default = .{ .provider = std.meta.stringToEnum(Provider, provider orelse return null) orelse return null, .model = .{} };
        binding.model.set(model orelse return null) catch return null;
        return binding;
    }

    pub fn eql(self: *const Default, other: *const Default) bool {
        return self.provider == other.provider and self.model.eql(other.model.slice()) and self.effort == other.effort;
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

/// The model picker /model opens.
pub const Picker = struct {
    /// The highlighted model's ID, which a new list keeps highlighted while
    /// it holds the model; empty until a list holds any.
    highlight: Bounded(model_capability.max_model_bytes) = .{ .len = 0 },
    choice: ?model_picker_view.Choice = null,
    edits: ?u32 = null,
    query_effort: ?ReasoningEffort = null,
    query_provider: ?Provider = null,
};

/// Each event brings at most two effects today; the shell runs them in order.
pub const Effects = struct {
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
pub const LocalEffort = struct {
    value: ?ReasoningEffort,
    only_when_explicit: bool,

    pub fn applies(self: LocalEffort, reads_preferences: bool) bool {
        return !self.only_when_explicit or !reads_preferences;
    }
};
pub const StartRequest = struct {
    settings: *const StartSettings,
    text: []const u8,
    /// The provider and model, `nextBinding`'s: the shell reads these, never
    /// the settings' own.
    binding: Binding = .{},
    local_effort: ?LocalEffort = null,

    pub fn own(self: StartRequest, gpa: Allocator) error{OutOfMemory}!OwnedStart {
        const provider = self.binding.provider orelse "";
        const model = self.binding.model orelse "";
        const bytes = try gpa.alloc(u8, self.text.len + self.settings.used + provider.len + model.len);
        var writer = std.Io.Writer.fixed(bytes);
        inline for (.{ self.text, self.settings.bytes[0..self.settings.used], provider, model }) |part| writer.writeAll(part) catch unreachable;
        return .{ .bytes = bytes, .text_len = self.text.len, .held = self.settings.held, .provider_len = if (self.binding.provider) |name| name.len else null, .model_len = if (self.binding.model) |name| name.len else null, .local_effort = self.local_effort };
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
    local_effort: ?LocalEffort = null,

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

/// The overview's notice for the exact conversation, and whether Ctrl-X
/// stops it.
pub const Said = struct {
    /// Null when the overview says nothing; the conversation's own notice
    /// then shows.
    text: ?[]const u8,
    stoppable: bool,
};

pub fn conversation(state: *const State, ref: Reference, work: Kind, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) Said {
    return .{ .text = if (statusSaid(state, caps, buffer)) |line| line.text else null, .stoppable = stoppable(state, ref, work) };
}

/// What both screens' status rows say first: an Upgrade while it runs,
/// since its line is where Esc is offered; else the newest notice; else
/// an Upgrade that holds. Borrows `state` and `buffer`.
fn statusSaid(state: *const State, caps: Caps, buffer: *[upgrade_status.max_line_bytes]u8) ?StatusLine {
    const upgrade: ?upgrade_status.Line = if (state.upgrade.run) |run| upgrade_status.line(run, buffer, if (caps.unicode) .unicode else .ascii) else null;
    if (upgrade) |line| if (line.lasts == .until_done) return .{ .text = line.text, .colour = .normal };
    if (state.notice) |*notice| return .{ .text = notice.text(), .colour = notice.colour };
    if (upgrade) |line| if (line.lasts == .persistent)
        return .{ .text = line.text, .colour = if (line.tone == .attention) .attention else .normal };
    return null;
}

/// A start or stop `step` asked the shell to send. Only its answer removes
/// it, and only while the overview shows that answer; one that may have
/// reached the Host keeps its recover handle until departure. A `send` is
/// a conversation's original left unconfirmed, held for its departure line.
/// Nothing is evicted: a full ledger refuses new requests.
pub const Request = struct {
    kind: enum { start, stop, archive, unarchive, send },
    /// The Session a stop names, or the one an accepted start made.
    session: ?Reference = null,
    status: enum { pending, done, failed, unknown } = .pending,
    /// The failure code, or the handle of an unknown or accepted request.
    text: Bounded(@max(max_handle_bytes, session_work.max_code_bytes)) = .{},
    /// A `send`'s recovery, as the conversation would have printed it.
    sent: submission.Recovery = .none,
};

pub const Notice = struct {
    /// Room for a refused environment's reason, its longest notice.
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
    archive_state: ArchiveState = .active,
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
    /// The command of the Action `first_action` names, while the row
    /// needs you.
    command: Line = .unread,

    /// What the listing said of the row's work, as `attention.observe` reads it.
    fn work(self: *const Row) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .first_action = self.first_action };
    }

    /// An Action waiting on the person leads, whoever started the
    /// Session; Yours keeps the rest of your own.
    pub fn group(self: *const Row) Group {
        if (self.needsYou()) return .needs_you;
        return if (self.from_person_at != null) .yours else rules.get(self.state).group;
    }

    /// An Action awaits a decision: alone, or beside running Bash.
    pub fn needsYou(self: *const Row) bool {
        return switch (self.state) {
            .approval => true,
            .bash => |bash| bash.approvals != 0,
            else => false,
        };
    }
};

/// The overview's one value: rows keyed by Session reference, the selection
/// as a reference, the composer and its held start settings
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

    archive: ArchiveFilter = .active,
    /// The in-flight traversal's filter, or null once a view change
    /// invalidates it. Returning to that filter cannot revive its pages.
    listing_archive: ?ArchiveFilter = .active,
    /// The Session last archived here, so its notice says when the Host
    /// finishes archiving it.
    last_archived: ?Reference = null,
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
    /// The Session whose conversation holds the terminal, if any.
    conversing: ?Reference = null,
    notice: ?Notice = null,
    settings: StartSettings = .{},
    /// Every start and stop without an answer the overview showed, oldest first.
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,
    /// The person left, so answers wait for `writeDeparture`.
    left: bool = false,
    /// The serving Host's facts, from the latest host-info read.
    host: ?Host = null,
    /// The latest memory read; null before the first.
    memory: ?Memory = null,
    /// The Upgrade: /upgrade's run and what the last one left Host intents.
    /// The one value both screens read.
    upgrade: session_upgrade.Upgrade = .{},

    /// The person's default for new Sessions. A pick replaces it at once,
    /// and a save follows it to the preferences file. `nextBinding` says
    /// what the next Session starts on.
    default: ?Default = null,
    default_sign_in_shown: bool = false,
    save: Save = .{},
    /// The screen the shell draws, which `layout` divides.
    size: Size = .{},
    /// Open from /model until a pick, Esc or typing; it acts only while
    /// `layout` shows it.
    picker: ?Picker = null,
    /// The command list the latest frame built for the draft, which the
    /// shell keeps from each `Screen.commands`: the one value Enter, Esc,
    /// the arrows and Tab act on, as in a conversation.
    commands: ?slash_commands.Shown = null,
    /// The composer's skill suggestions reads, and the rows they list.
    skills: skill_completion.Reads = .{},
    /// The Workspace those reads asked in; another one's pages answer
    /// nothing.
    skills_workspace: Bounded(workspace_path.max_bytes) = .{},
    skill_rows: skill_completion.Rows = .{},
    /// The open picker's latest model lists, freed when it closes.
    menu: model_picker.Menu = .{},
    /// How the open picker's latest model-list read ended.
    menu_read: model_picker_view.Read = .unread,
    /// A model-list read is in flight.
    asking_models: bool = false,
    /// Shown in the Sessions' rows while open.
    panel: ?Panel = null,
    /// The command the shell runs, until its answer; one the overview
    /// could not show, until the way out.
    command: ?Command = null,

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

    /// Where the next input goes.
    pub fn inputMode(self: *const State) InputMode {
        if (self.starting()) return .frozen;
        return .compose;
    }

    /// How the shell takes an input.
    pub fn route(self: *const State, _: keymap.Selection(Action)) Route {
        return switch (self.inputMode()) {
            .compose => .edit,
            .frozen => .frozen,
        };
    }

    /// What fills the list's lines: the model picker over a panel, a panel
    /// over the Sessions. The frame draws this and a click lands on it, so
    /// neither decides it again.
    pub fn listArea(self: *const State) ListArea {
        if (self.picker != null) return .picker;
        if (self.panel != null) return .panel;
        return .sessions;
    }

    /// The picker remains actionable even on a screen too small to show it.
    pub fn shownPicker(self: *const State) ?*const Picker {
        return if (self.picker) |*open| open else null;
    }

    /// What the next Session starts on: what `/configure` holds, else the
    /// default.
    /// What `/configure --reasoning-effort` holds for the next start.
    fn heldEffort(self: *const State) ?[]const u8 {
        return self.settings.get(startOption("reasoning-effort").?);
    }

    pub fn nextBinding(self: *const State) Binding {
        const default = if (self.default) |*binding| binding else null;
        return .{
            .provider = self.settings.get(startOption("provider").?) orelse if (default) |binding| @tagName(binding.provider) else null,
            .model = self.settings.get(startOption("model").?) orelse if (default) |binding| binding.model.slice() else null,
        };
    }

    pub fn localEffort(self: *const State) ?LocalEffort {
        const binding = self.default orelse return null;
        const pending = self.save.wanted != null or self.save.running != null;
        const last = self.save.last;
        const same = if (last) |ended| ended.binding.eql(&binding) else false;
        if (!pending and !same) return null;
        const failed = if (last) |ended| same and ended.outcome == .failed else false;
        return .{ .value = binding.effort, .only_when_explicit = !pending and !failed };
    }

    /// The menu as the picker shows it, the next Session's model first.
    fn shownMenu(self: *const State) model_picker.Shown {
        return self.menu.shown(self.nextBinding().model);
    }

    /// The open picker's highlighted entry of `menu`.
    fn highlighted(self: *const State) ?usize {
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
        if (self.skills.reset()) |page| {
            var held = page;
            held.deinit(self.gpa);
        }
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

    /// /upgrade's run has not ended: the shell runs and polls its worker.
    pub fn upgrading(self: *const State) bool {
        return self.upgrade.going();
    }

    /// Host intents wait: an Upgrade runs, or the last one left them held.
    /// The one rule every Host intent and the shell's lending ask.
    pub fn holdsHost(self: *const State) bool {
        return self.upgrade.held();
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
        // A long failure, such as a refused environment, keeps its start,
        // cut between characters.
        var end = @min(text.len, held.text.bytes.len);
        while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
        held.text.set(text[0..end]) catch unreachable;
    }

    /// Records the state the open conversation opened on in `seen`: an
    /// outcome the person has seen.
    fn observe(self: *State, read: Observed) error{OutOfMemory}!void {
        if (!read.opening or attention.Attention.of(read.work) == null) return;
        _ = attention.observe(&(try self.record(read.reference)).acknowledged, read.work);
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

pub const Summary = struct {
    counts: Counts = .{},
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
/// One Session's record: the latest state a conversation opened on, an
/// outcome the person has seen; what the last listing read; and the program status the
/// terminal should show, from listings alone, which read in order, beside
/// the one it holds. A Session no longer listed has no program status.
const Seen = struct {
    key: u64,
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
        // A click is input as a key is: the screen that takes no key takes
        // no click, wherever it lands.
        .clicked => |clicked| if (state.inputMode() != .frozen) switch (clicked) {
            .open => |reference| try clickOpen(state, reference, &effects),
            .unfold => |group| clickUnfold(state, group),
            // As `/sessions` does; the default view shows no name.
            .view => if (state.archive != .active) try changeArchiveView(state, .active, &effects),
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
                .upgrade => startUpgrade(state),
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
                .requested => |completion| {
                    state.answer(at, .done, "");
                    if (result.request.archived) {
                        state.last_archived = ref;
                        if (completion == .pending) state.say(.attention, "{s}: Stopping and archiving; waiting for work to settle.", .{&ref}) else state.say(.quiet, "Archived {s}.", .{&ref});
                    } else state.say(.quiet, "Restored {s}; work was not restarted.", .{&ref});
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
        .observed => |read| try state.observe(read),
        .open => |ref| {
            state.selected = ref;
            effects.add(.{ .open = ref });
        },
        .host => |facts| state.host = facts,
        .memory => |memory| state.memory = memory,
        .command => |answer| try commandRead(state, answer),
        .upgrade => |run| {
            // The shell reports only the run /upgrade asked for.
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
        .picker_action => |input| if (state.picker) |*shown| {
            syncPicker(state, input.draft);
            _ = model_picker_view.step(&state.menu, pickerWords(input.draft.bytes), pickerDefaults(state), &shown.choice, input.action);
        },
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
                const local = state.localEffort();
                const effort = if (local) |value| if (value.applies(true)) value.value else answer.saved_effort else answer.saved_effort;
                const effort_suffix = effortSuffix(start.applied(effort));
                switch (ended.outcome) {
                    .done => {},
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
            var retained: ?model_picker_view.Choice = null;
            if (picker.choice) |choice| {
                const id = state.menu.entries[choice.index].id;
                picker.highlight.set(id) catch unreachable;
                if (owned.find(id)) |index| {
                    const row = model_picker.Query.parse("").row(owned.entries[index], pickerDefaults(state)).?;
                    retained = model_picker_view.retain(.{ .index = index, .row = row }, choice);
                }
            }
            picker.choice = retained;
            picker.edits = null;
            state.menu.deinit(state.gpa);
            state.menu = owned;
            state.menu_read = .read;
            // The highlight stays on its model while the list holds it.
            if (state.highlighted() == null) {
                if (owned.entries.len != 0) picker.highlight.set(state.shownMenu().entry(0).id) catch unreachable;
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
        const next = row.state.asOf(now_ms);
        if (std.meta.activeTag(next) == std.meta.activeTag(row.state)) continue;
        changed = true;
        row.state = next;
    }
    if (changed) try arrange(state);
    if (!state.listing and now_ms >= state.next_list_ms) {
        state.listing = true;
        state.listing_archive = state.archive;
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
    if (state.listing_archive == null) {
        if (page.answer != null) {
            state.listing = false;
            state.next_list_ms = 0;
            try tick(state, state.now_ms, effects);
        }
        return;
    }
    std.debug.assert(state.listing_archive.? == state.archive);
    if (page.restarts) state.pending.items.len = 0;
    try state.pending.ensure(state.gpa, state.pending.items.len + page.rows.len);
    for (page.rows) |listed| {
        const shown = listed.state.asOf(state.now_ms);
        // A row new to the overview takes its state's start as its mark's.
        state.pending.appendAssumeCapacity(.{
            .reference = listed.reference,
            .archive_state = listed.archive_state,
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
    try readListing(state);
    try commit(state, answer);
    state.listing = false;
    state.upgrade.reobserved();
    try readFirstLines(state, effects);
    readCommands(state, effects);
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
    const selected_at = if (state.selected) |ref| position(state, ref) orelse 0 else 0;
    var completed_archive: ?Reference = null;
    if (state.last_archived) |ref| for (state.pending.items) |incoming| {
        if (!std.mem.eql(u8, &incoming.reference, &ref) or incoming.archive_state != .archived) continue;
        if (state.find(ref)) |old| if (old.archive_state != .archived) {
            completed_archive = ref;
        };
    };
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
    var kept: usize = 0;
    for (state.rows.items) |row| {
        if (!state.archive.includes(row.archive_state)) {
            if (state.entryOf(row.reference)) |entry| {
                state.want(entry, null, false);
                entry.listed = null;
            }
            continue;
        }
        state.rows.items[kept] = row;
        kept += 1;
    }
    if (kept != state.rows.items.len) {
        state.rows.items.len = kept;
        try reindex(state);
    }
    state.pending.items.len = 0;
    state.token = answer.since;
    state.listed_at_ms = state.now_ms;
    state.unreachable_since_ms = null;
    try arrange(state);
    if (completed_archive) |ref| state.say(.quiet, "Archived {s}.", .{&ref});
    if (state.selectedRow() == null) {
        state.selected = if (state.order.items.len == 0) null else state.rows.items[state.order.items[@min(selected_at, state.order.items.len - 1)]].reference;
        if (state.selectedRow()) |row| state.unfolded.insert(row.group());
    }
}

/// What a listing's row keeps of the row it replaces.
fn carry(state: *State, incoming: *Row, old: *const Row) void {
    // What the overview knows of the same first Message's first line, read,
    // unreadable or asked for, still holds.
    const same = if (incoming.first) |first| if (old.first) |known| first.admission == known.admission else false else false;
    if (same) incoming.line = old.line;
    // The same waiting Action has the same command.
    if (incoming.first_action != null and incoming.first_action == old.first_action) incoming.command = old.command;
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
        const queued = shownKind(state, row) == .pending;
        // Work first, newest first; then queued rows, longest wait first.
        const since = @min(shownSince(state, row), latest);
        const age: u128 = if (queued) since else latest - since;
        key.* = .{ .key = @as(u128, @backingInt(row.group())) << 83 | @as(u128, @intFromBool(queued)) << 82 | age << 48 | referenceKey(row.reference), .index = @intCast(at) };
    }
    std.mem.sortUnstable(SortKey, state.sort_keys.items, {}, struct {
        fn less(_: void, a: SortKey, b: SortKey) bool {
            return a.key < b.key;
        }
    }.less);
    state.summary.counts = counts(state);
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

/// How many rows show each mark the counts line counts.
fn counts(state: *const State) Counts {
    var result: Counts = .{};
    for (state.rows.items) |*row| switch (rules.get(shownKind(state, row)).mark) {
        .needs_you => result.needs_you += 1,
        .active => result.working += 1,
        .queued => result.queued += 1,
        .failed => result.failed += 1,
        .waiting, .finished, .stopped => {},
    };
    return result;
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

/// Keys act on the picker only while the screen shows it. A key that acts
/// on a Session closes a panel, so it acts where the Sessions show.
fn compose(state: *State, value: Composed, effects: *Effects) error{OutOfMemory}!void {
    // Session mutations enter their semantic owner before the generic
    // notice clearing below.
    const action: ?Action = switch (value.input) {
        .composer => |outcome| if (outcome == .action) outcome.action else null,
    };
    if (state.picker != null) if (action) |pressed| switch (pressed) {
        .archive, .stop, .select_previous, .select_next => return,
        else => {},
    };
    if (action) |pressed| switch (pressed) {
        .archive => return archiveIntent(state, .{ .selected_archive = .keep }, effects),
        .stop => return stopKey(state, null, effects),
        else => {},
    };
    state.notice = null;
    const model_draft = std.mem.eql(u8, value.draft.bytes, "/model") or std.mem.startsWith(u8, value.draft.bytes, "/model ");
    if (state.picker == null and model_draft) {
        openModelPicker(state, effects);
    } else if (state.picker != null and !model_draft) {
        state.closePicker();
    }
    if (state.picker != null) syncPicker(state, value.draft);
    const outcome: keymap.Outcome(Action) = switch (value.input) {
        .composer => |outcome| outcome,
    };
    const picker: ?*Picker = if (state.shownPicker() != null) &state.picker.? else null;
    switch (outcome) {
        .action => |pressed| switch (pressed) {
            .previous, .next, .first, .last => if (picker) |shown| {
                const operation: model_picker_view.Action = if (pressed == .previous or pressed == .first) .previous else .next;
                _ = model_picker_view.step(&state.menu, pickerWords(value.draft.bytes), pickerDefaults(state), &shown.choice, operation);
            } else if (pressed == .previous or pressed == .next) {
                // A shown command list takes the arrows, as the picker
                // does. Home and End stay the draft's: the list shows only
                // over a draft, where the composer takes them.
                if (shownCommands(state, value.draft)) |shown| shown.move(pressed == .next) else select(state, pressed);
            } else select(state, pressed),
            .select_previous => select(state, .previous),
            .select_next => select(state, .next),
            // Esc closes the picker; else it cancels an Upgrade that can
            // still change nothing, as the status row offers, even while the
            // draft still lists `/upgrade`; else a shown command list closes,
            // then a panel, each keeping the draft.
            .clear => if (picker != null) {
                state.closePicker();
                effects.add(.clear_draft);
            } else if (state.upgrade.takesEscape()) {
                effects.add(.cancel_upgrade);
            } else if (shownCommands(state, value.draft)) |shown| {
                shown.close();
            } else if (state.panel != null) state.closePanel() else if (value.draft.bytes.len != 0) effects.add(.clear_draft) else {
                state.settings = .{};
            },
            .exit => effects.add(.exit),
            .archive, .stop => unreachable, // Routed before input cancellation.

        },
        .none, .append, .redraw => {},
        // Enter in a list the latest frame drew takes the highlighted
        // entry: it runs the command that entry completes, or adds the word
        // another follows. A screen too short for the list shows none.
        .submit => if (picker != null) {
            pick(state, effects);
        } else if (shownCommands(state, value.draft)) |shown| {
            const taken = shown.list.enter(shown.highlight);
            if (taken.runs and value.draft.bytes.len + taken.rest.len <= draft_capacity) {
                var line: [draft_capacity]u8 = undefined;
                @memcpy(line[0..value.draft.bytes.len], value.draft.bytes);
                @memcpy(line[value.draft.bytes.len..][0..taken.rest.len], taken.rest);
                const completed = line[0 .. value.draft.bytes.len + taken.rest.len];
                if (std.mem.eql(u8, completed, "/model")) {
                    effects.add(.{ .replace = .{ .start = value.draft.bytes.len, .end = value.draft.bytes.len, .text = "/model "[value.draft.bytes.len..] } });
                    openModelPicker(state, effects);
                } else try enter(state, completed, effects);
            } else {
                // The draft grows, or refuses a word it cannot hold, so the
                // next list starts at its top.
                effects.add(.{ .replace = skill_completion.edit(value.draft.bytes, value.draft.cursor, shown) });
                shown.highlight = 0;
            }
        } else try enter(state, value.draft.bytes, effects),
        .refused => |why| {
            if (why.endsLine()) effects.add(.clear_draft);
            switch (why) {
                .invalid => state.say(.attention, "! Not valid text; nothing sent.", .{}),
                .overflow => state.say(.attention, "! Too long to send.", .{}),
                .paste_overflow => state.say(.attention, "! Paste too long; draft unchanged.", .{}),
                .edit_rejected => state.say(.attention, "! Can't add that character alone.", .{}),
                .unbound => state.say(.attention, "! That key does nothing here.", .{}),
            }
        },
    }
}

fn openModelPicker(state: *State, effects: *Effects) void {
    state.picker = .{};
    state.closePanel();
    askModels(state, effects);
}

const StopTarget = struct { reference: Reference, work: Kind };

/// Ctrl-X on either screen stops at once: null targets the selection,
/// otherwise the exact conversation. Stopping loses nothing the Host cannot
/// replay, so it asks nothing.
fn stopKey(state: *State, exact: ?StopTarget, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    state.notice = null;
    const target = exact orelse selected: {
        state.closePanel();
        const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
        break :selected StopTarget{ .reference = row.reference, .work = row.state.asOf(state.now_ms) };
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
    if (state.openStop(row.reference) == null and row.needsYou()) return .approval;
    return kindShown(state, row.reference, row.state.asOf(state.now_ms));
}

/// When the row's shown state began: a retry that has fallen due waits
/// from its due time.
fn shownSince(state: *const State, row: *const Row) u64 {
    return row.state.asOf(state.now_ms).since();
}

/// What a row's work is doing now, as `shownKind` reads it; null for idle or
/// ended work.
fn workLine(words: *[work_line.max_words_bytes]u8, state: *const State, row: *const Row) ?work_line.Line {
    return if (state.openStop(row.reference) != null) work_line.stopping else work_line.of(words, &row.state, null, state.now_ms);
}

/// One click on a row opens it, as selecting it and Enter on a blank draft
/// do. A Session that left the list since it was drawn opens nothing.
fn clickOpen(state: *State, reference: Reference, effects: *Effects) error{OutOfMemory}!void {
    const at = position(state, reference) orelse return;
    state.unfolded.insert(state.rows.items[state.order.items[at]].group());
    state.selected = reference;
    try enter(state, "", effects);
}

/// A click on a folded group's "more" line opens the group at its first
/// hidden row, as moving into them does. A group with nothing hidden any
/// more stays as it is.
fn clickUnfold(state: *State, group: Group) void {
    if (!folded(state, group)) return;
    state.unfolded.insert(group);
    state.selected = state.rows.items[state.order.items[state.runs.get(group).start + fold_rows]].reference;
}

/// Moves the selection where the Sessions show.
fn select(state: *State, action: Action) void {
    state.closePanel();
    move(state, action);
}

pub const upgrade_recovery = "! Host requests paused after Upgrade; draft retained. /upgrade or reopen with the selected Rui.";

/// Admission applies only to new Host intents, never to their completions.
fn admitHostRequest(state: *State) bool {
    if (!state.holdsHost()) return true;
    state.say(.attention, upgrade_recovery, .{});
    return false;
}

/// /upgrade checks at once; Host intents wait until it ends. The shell
/// runs the worker for as long as `upgrading` says.
fn startUpgrade(state: *State) void {
    // The run going on keeps its progress and its Esc. An ending that
    // holds is newer than any notice.
    if (state.upgrade.start()) state.notice = null;
}

fn enter(state: *State, text: []const u8, effects: *Effects) error{OutOfMemory}!void {
    const parsed: ?commands.Parsed = if (text.len != 0 and text[0] == '/' and !std.mem.startsWith(u8, text, "//")) commands.parse(text) else null;
    if (parsed) |result| switch (result) {
        .command => |command| switch (command.name) {
            .archive => return archiveIntent(state, .{ .selected_archive = .submitted }, effects),
            .unarchive => return archiveIntent(state, .selected_restore, effects),
            else => {},
        },
        else => {},
    };
    // The Upgrade's own command and leaving are no Host requests, so no
    // hold refuses them.
    if (parsed) |result| switch (result) {
        .command => |command| switch (command.name) {
            .upgrade => return startUpgrade(state),
            .exit => return effects.add(.exit),
            else => {},
        },
        else => {},
    };
    if (!admitHostRequest(state)) return;
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
        return effects.add(.{ .start = .{ .settings = &state.settings, .text = if (text[0] == '/') text[1..] else text, .binding = state.nextBinding(), .local_effort = state.localEffort() } });
    }
    const command = switch (parsed.?) {
        .unknown => {
            var buffer: [slash_commands.unknown_bytes]u8 = undefined;
            return state.say(.attention, "{s}", .{slash_commands.unknown(&buffer, text)});
        },
        .misused => |name| return state.say(.attention, "! Usage: {s}", .{commands.usage.get(name)}),
        .command => |command| command,
    };
    switch (command.name) {
        .archive, .unarchive => unreachable, // Routed through archiveIntent.
        .sessions => {
            const filter: ArchiveFilter = if (std.mem.eql(u8, command.argument, "archived")) .archived else if (std.mem.eql(u8, command.argument, "all")) .all else if (std.mem.eql(u8, command.argument, "unarchived")) .active else {
                state.say(.quiet, "Sessions: {s}. /sessions unarchived|archived|all", .{archiveViewName(state.archive)});
                effects.add(.clear_draft);
                return;
            };
            effects.add(.clear_draft);
            try changeArchiveView(state, filter, effects);
        },
        .exit => effects.add(.exit),
        .upgrade => startUpgrade(state),
        .model => unreachable, // The draft-backed picker takes /model before submission.
        .configure => if (configure(state, command.argument)) effects.add(.clear_draft),
        .help => {
            const help: Panel = .help;
            // A panel the screen cannot show whole never opens.
            if (layout(state).list.len() < help.rows()) return state.say(.attention, "! Screen too small for /help", .{});
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

const ArchiveDraft = enum { keep, submitted };
const ArchiveIntent = union(enum) {
    selected_archive: ArchiveDraft,
    selected_restore,
    ask: struct { reference: Reference, work: Kind, archive: ArchiveState },
    restore: Reference,
};

/// All archive surfaces converge here, before the request ledger or
/// submitted drafts change. Transport completions settle outside admission.
fn archiveIntent(state: *State, intent: ArchiveIntent, effects: *Effects) void {
    if (!admitHostRequest(state)) return;
    state.notice = null;
    switch (intent) {
        .selected_archive => |draft| {
            state.closePanel();
            const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
            askArchive(state, row.reference, row.state.asOf(state.now_ms), row.archive_state, draft, effects);
        },
        .selected_restore => {
            state.closePanel();
            const row = state.selectedRow() orelse return state.say(.attention, no_selection, .{});
            archiveSession(state, .{ .reference = row.reference, .archived = false }, effects);
            effects.add(.clear_draft);
        },
        .ask => |target| askArchive(state, target.reference, target.work, target.archive, .keep, effects),
        .restore => |ref| archiveSession(state, .{ .reference = ref, .archived = false }, effects),
    }
}

/// Slash commands consume their submitted line; a key leaves its draft alone.
/// A working Session archives at once too: the Host stops its work first,
/// and `/unarchive` restores it, so nothing is asked.
fn askArchive(state: *State, ref: Reference, work: Kind, archive: ArchiveState, draft: ArchiveDraft, effects: *Effects) void {
    _ = work;
    if (archive == .archiving) {
        state.say(.attention, "{s}: Stopping and archiving; waiting for work to settle.", .{&ref});
        return;
    }
    if (archive == .archived) {
        state.say(.quiet, "{s} is already archived. /unarchive restores it.", .{&ref});
        return;
    }
    if (draft == .submitted) effects.add(.clear_draft);
    archiveSession(state, .{ .reference = ref }, effects);
}

fn archiveSession(state: *State, request: ArchiveRequest, effects: *Effects) void {
    for (state.requests[0..state.request_count]) |held| {
        if (held.kind != .archive and held.kind != .unarchive) continue;
        if (held.status != .pending and held.status != .unknown) continue;
        if (std.mem.eql(u8, &held.session.?, &request.reference)) {
            state.say(.attention, "! {s} archive request {s}; details on exit.", .{ &request.reference, if (held.status == .pending) "pending" else "unsure" });
            return;
        }
    }
    if (state.request(if (request.archived) .archive else .unarchive, request.reference)) {
        effects.add(.{ .archive = request });
        state.say(.quiet, "{s} request pending for {s}; waiting for the Host.", .{ if (request.archived) "Archive" else "Restore", &request.reference });
    }
}

fn changeArchiveView(state: *State, filter: ArchiveFilter, effects: *Effects) error{OutOfMemory}!void {
    state.closePanel();
    if (state.archive == filter) return;
    state.archive = filter;
    if (state.listing) state.listing_archive = null;
    state.token = null;
    state.rows.items.len = 0;
    state.by_reference.items.len = 0;
    state.pending.items.len = 0;
    state.lines.items.len = 0;
    state.selected = null;
    state.listed_at_ms = null;
    state.next_list_ms = 0;
    for (state.seen.items) |*entry| {
        state.want(entry, null, false);
        entry.listed = null;
    }
    try arrange(state);
    if (!state.listing) try tick(state, state.now_ms, effects);
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

pub fn pickerWords(draft: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, draft, "/model")) std.mem.trimStart(u8, draft[6..], " ") else draft;
}

pub fn pickerDefaults(state: *const State) model_picker.Defaults {
    const binding = state.nextBinding();
    return .{
        .model = binding.model,
        .provider = std.meta.stringToEnum(Provider, binding.provider orelse ""),
        .effort = if (state.default) |default| default.effort else null,
    };
}

pub fn syncPicker(state: *State, draft: Draft) void {
    const shown = &state.picker.?;
    if (shown.edits != null and shown.edits.? == draft.edits and shown.choice != null) return;
    const previous = shown.choice;
    const wanted = if (shown.choice) |choice| choice.index else if (shown.highlight.len != 0) state.menu.find(shown.highlight.slice()) else if (state.nextBinding().model) |id| state.menu.find(id) else null;
    const words = pickerWords(draft.bytes);
    const query = model_picker.Query.parse(words);
    shown.choice = model_picker_view.select(&state.menu, words, pickerDefaults(state), wanted);
    if (previous) |old| if (shown.choice) |current| {
        if (old.index == current.index) {
            var kept = model_picker_view.retain(current, old);
            if (query.effort != null and query.effort != shown.query_effort) kept.row.effort = current.row.effort;
            if (query.provider != null and query.provider != shown.query_provider) kept.row.provider = current.row.provider;
            shown.choice = kept;
        }
    };
    shown.query_effort = query.effort;
    shown.query_provider = query.provider;
    shown.edits = draft.edits;
}

/// Enter saves the highlighted model, sign-in and effort together.
fn pick(state: *State, effects: *Effects) void {
    const picker = &state.picker.?;
    const choice = picker.choice orelse return;
    const entry = state.menu.entries[choice.index];
    var binding: Default = .{ .provider = choice.row.provider, .model = .{ .len = 0 }, .effort = choice.row.effort };
    binding.model.set(entry.id) catch unreachable;
    state.default = binding;
    state.default_sign_in_shown = choice.row.providers.count() > 1;
    // The pick is newer than what /configure holds for the next Session.
    var kept: StartSettings = .{};
    inline for (start_options, 0..) |name, option| if (comptime !std.mem.eql(u8, name, "provider") and !std.mem.eql(u8, name, "model")) {
        if (state.settings.get(option)) |value| kept.put(option, value) catch unreachable;
    };
    state.settings = kept;
    state.save.wanted = binding;
    state.closePicker();
    effects.add(.clear_draft);
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

/// Where App's rows go: the counts line and any bands from row 0, the
/// list, the picker right above the input, then the input area. The core
/// reads it to know what shows, and the overview's widgets draw by it.
pub const Layout = struct {
    top: u16 = 0,
    list: Rows = .{},
    /// The input area's first row: the composer's top rule.
    input: u16 = 0,

    pub const Rows = struct {
        start: u16 = 0,
        end: u16 = 0,

        pub fn len(self: Rows) u16 {
            return self.end - self.start;
        }
    };
};

/// The rows of `state`'s screen. The input area is the composer's rules
/// around its draft row, the facts row and the status. The list occupies
/// the rows above the input.
pub fn layout(state: *const State) Layout {
    const height = state.size.height;
    if (height == 0 or state.size.width == 0) return .{};
    const top: u16 = @intCast(@min(topRows(state), height));
    const input = @max(top, height -| (3 + 1 + hintRows(state)));
    return .{ .top = top, .list = .{ .start = top, .end = input }, .input = input };
}

/// Rows the line under the input takes: one, or as many as a notice has
/// lines, up to a command's short result. A picker's keys share the first.
fn hintRows(state: *const State) u16 {
    if (state.picker != null) return 1;
    const notice = state.notice orelse return 1;
    return @intCast(@min(1 + std.mem.count(u8, notice.text(), "\n"), slash_commands.short_result_lines));
}

/// The counts line and its bands, as `headerSegments` draws them.
fn topRows(state: *const State) usize {
    return 1 + @as(usize, @intFromBool(state.unreachable_since_ms != null)) + @intFromBool(band(state.rows.items, state.now_ms, state.login_at) != null);
}

/// The list between the rule and the draft as it is now, while the person
/// types a command, after the latest frame's; null for any other draft or
/// when nothing matches. The next Session's model offers its efforts.
pub fn nextCommands(state: *State, draft: Draft) ?slash_commands.Shown {
    if (state.inputMode() != .compose or state.picker != null) return null;
    const held = state.heldEffort();
    const context: slash_commands.Context = .{
        .model = state.nextBinding().model,
        .effort = if (held) |text| std.meta.stringToEnum(model_capability.ReasoningEffort, text) else null,
    };
    return state.skills.shown(&state.skill_rows, draft.bytes, draft.cursor, draft.edits, commands.suggest(draft.bytes, context), state.commands);
}

/// The name of the `/word` the caret is in, or null.
fn caretName(draft: Draft) ?[]const u8 {
    const at = skill_completion.skillWordAt(draft.bytes, draft.cursor) orelse return null;
    return at.name(draft.bytes);
}

/// The skill suggestions read the caret's `/word` in `draft` needs, if
/// any: the shell asks after each composer input and each answer, runs it
/// on its worker in `state.skills_workspace`, and answers it with
/// `skillsRead`. Its prefix borrows the state until then.
pub fn askSkills(state: *State, draft: Draft) ?skill_completion.Ask {
    // The Host may not speak this protocol while an Upgrade is under way.
    if (state.inputMode() != .compose or state.holdsHost()) return null;
    // A Message binds the skills of the Workspace its Session starts in:
    // a held `/configure --workspace`, else the overview's. When that
    // changes, nothing held or in flight answers.
    const workspace = state.settings.get(startOption("workspace").?) orelse state.workspaces.items[state.cwd];
    if (!std.mem.eql(u8, state.skills_workspace.slice(), workspace)) {
        if (state.skills.reset()) |page| {
            var held = page;
            held.deinit(state.gpa);
        }
        state.skills_workspace = .{};
        // The Host refuses a longer Workspace, so nothing is read in it.
        state.skills_workspace.set(workspace) catch return null;
    }
    return state.skills.ask(caretName(draft) orelse return null);
}

/// Read `read` ended with `page`, owned by the state's allocator, or null
/// when it failed; `draft` is the composer's now.
pub fn skillsRead(state: *State, read: u64, page: ?skill_suggestions.Page, draft: Draft) void {
    const answered = page orelse return state.skills.fail(read);
    var unheld = state.skills.answer(read, answered, caretName(draft)) orelse return;
    unheld.deinit(state.gpa);
}

/// The list for `draft`, which Enter, Esc and the arrows act on when the
/// latest frame drew a list.
fn shownCommands(state: *State, draft: Draft) ?*slash_commands.Shown {
    return slash_commands.Shown.drawnNow(&state.commands, nextCommands(state, draft));
}

/// One line's spans, placed left to right at their columns, its text made
/// terminal-safe and clipped to the room it has. Each span keeps the role
/// it was given, as `plain` leaves it without colour; the widget that
/// draws the line makes the role a colour through `widget_style`.
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
        const drawn = plain(self.caps, wanted);
        if (drawn.reverse or drawn.background != .ground) {
            const blank = try self.arena.alloc(u8, to - self.column);
            @memset(blank, ' ');
            self.push(blank, to - self.column, wanted);
        }
        self.column = to;
    }

    fn push(self: *Spans, bytes: []const u8, cells: usize, wanted: Style) void {
        if (self.count == self.spans.len or cells == 0) return;
        self.spans[self.count] = .{ .column = @intCast(self.column), .cells = @intCast(cells), .text = bytes, .style = plain(self.caps, wanted) };
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
        const shown = try fitted(self.arena, self.caps, self.glyphs, bytes, room, keep);
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

const Keep = enum { head, tail };

/// `wanted` as a terminal without colour shows it: only bold and reverse
/// remain, the band and the selection reverse, and every other ground is
/// the terminal's own.
fn plain(caps: Caps, wanted: Style) Style {
    if (caps.depth != .none) return wanted;
    return .{
        .bold = wanted.bold or wanted.background == .band,
        .reverse = wanted.reverse or wanted.background == .band or wanted.background == .selection,
    };
}

/// `bytes` made terminal-safe and clipped to `room` cells, as `Pieces`
/// shows it, with an ellipsis where it was cut: at the end, or at the
/// start when keeping the tail.
fn fitted(arena: Allocator, caps: Caps, glyphs: Glyphs, bytes: []const u8, room: usize, keep: Keep) error{OutOfMemory}!Piece {
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

const Piece = struct { bytes: []const u8, cells: usize };

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

/// The list's line while it has no rows: loading, or what the view holds
/// and where the rest are.
fn emptyLine(built: *Spans, state: *const State) error{OutOfMemory}![]const Span {
    built.begin();
    const text = if (state.listed_at_ms == null)
        try std.fmt.allocPrint(built.arena, "Loading{s}", .{built.glyphs.ellipsis})
    else if (state.archive == .archived)
        "No archived Sessions. /sessions changes the view."
    else if (state.archive == .all)
        "No Sessions yet. Type a task below."
    else
        "No unarchived Sessions. /sessions archived shows the archive.";
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
        // A row does not carry its provider, so each names the one provider
        // with that kind of credential.
        .sign_in => "Sign-in expired. Run " ++ comptime Provider.onlyWith(.sign_in).login() ++ ".",
        .api_key => comptime Provider.onlyWith(.api_key).shown() ++ " API key rejected. Run " ++ Provider.onlyWith(.api_key).login() ++ ", then rui host pause.",
        .quota => if (trouble.resets_at) |at|
            try std.fmt.allocPrint(built.arena, "Quota used up. Resets in {s}.", .{ageText(&buffer, at -| now_ms / 1000)})
        else
            "Quota used up.",
        .rate_limit => try std.fmt.allocPrint(built.arena, "Rate limited. {d} Session{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
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

/// The line under the input. `listed`: this frame shows the command list.
fn hints(built: *Spans, state: *const State, draft: Draft, listed: bool) error{OutOfMemory}![]const Span {
    built.begin();
    const room = built.width -| 2;
    const dot = built.glyphs.dot;
    // What Esc does here, as `compose` reads it: a list or a panel closes
    // before the draft and the held settings clear.
    var status: StatusBuffer = undefined;
    const esc_does: ?[]const u8 = if (listed or state.panel != null) "esc close" else if (draft.bytes.len != 0 or !state.settings.empty()) "esc clear" else null;
    if (state.shownPicker() != null) {
        _ = try built.put(1, if (built.caps.unicode) "←→ effort · tab sign-in" else "<> effort - tab sign-in", room, .{ .colour = .quiet });
    } else if (statusLine(state, built.caps, &status)) |line| {
        // A notice, else the Upgrade at work or held, else an unconfirmed
        // send: each says what the keys below cannot.
        _ = try built.put(1, line.text, room, .{ .colour = line.colour });
    } else if (state.starting()) {
        _ = try built.put(1, try std.fmt.allocPrint(built.arena, "Starting{s}", .{built.glyphs.ellipsis}), room, .{ .colour = .quiet });
    } else if (!state.settings.empty()) {
        var text: std.Io.Writer.Allocating = .init(built.arena);
        text.writer.writeAll("start settings:") catch return error.OutOfMemory;
        writeSettings(&state.settings, &text.writer) catch return error.OutOfMemory;
        // Long settings are cut so the way out stays on screen.
        const suffix = try std.fmt.allocPrint(built.arena, " {s} {s}", .{ dot, esc_does.? });
        const used = try built.put(1, text.written(), room -| built.measure(suffix), .{ .colour = .quiet });
        _ = try built.put(1 + used, suffix, room -| used, .{ .colour = .quiet });
    } else if (draft.bytes.len != 0) {
        // What Enter and Esc do to this draft, as `enter` and `compose` read it.
        const slashed = draft.bytes[0] == '/' and !std.mem.startsWith(u8, draft.bytes, "//");
        const enter_does: []const u8 = if (!slashed) (if (listed) "enter pick " else "enter start ") else if (commands.parse(draft.bytes) == .command) "enter run " else "";
        const text = try std.fmt.allocPrint(built.arena, "{s}{s}{s}", .{ enter_does, if (enter_does.len != 0) try std.fmt.allocPrint(built.arena, "{s} ", .{dot}) else "", esc_does.? });
        _ = try built.put(1, text, room, .{ .colour = .quiet });
    } else if (state.selectedRow()) |row| {
        const stop = if (stoppable(state, row.reference, row.state.asOf(state.now_ms))) try std.fmt.allocPrint(built.arena, " {s} " ++ session_line.stop_hint, .{dot}) else "";
        const close = if (esc_does) |does| try std.fmt.allocPrint(built.arena, " {s} {s}", .{ dot, does }) else "";
        const text = try std.fmt.allocPrint(built.arena, "{s} select {s} enter open{s}{s}", .{ built.glyphs.arrows, dot, stop, close });
        _ = try built.put(1, text, room, .{ .colour = .quiet });
    } else if (esc_does) |does| {
        _ = try built.put(1, does, room, .{ .colour = .quiet });
    }
    return built.finish();
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

/// A line of the Sessions list: the gap before a group, its heading, the
/// row at an index of `order`, or the line that counts a folded group's
/// hidden rows; with no rows, the one line that says why.
pub const Item = union(enum) { gap, heading: Group, row: usize, more: More, empty };
pub const More = struct { group: Group, hidden: usize };

/// How many lines the Sessions list has; `listItem` names each.
pub fn listLength(state: *const State) usize {
    if (state.rows.items.len == 0) return 1;
    const lines_of = ListLines.of(state);
    var end: usize = 0;
    for (std.enums.values(Group)) |group| {
        const run = state.runs.get(group);
        if (run.len == 0) continue;
        const shown = lines_of.shown.get(group);
        end = lines_of.first_line.get(group) + 1 + shown + @intFromBool(shown < run.len);
    }
    return end;
}

/// The list line of the selected Session, when one is listed.
pub fn selectedLine(state: *const State) ?usize {
    const at = position(state, state.selected orelse return null) orelse return null;
    return ListLines.of(state).lineOf(state, at);
}

/// The Sessions list's line `line`, counted from its first, or null past
/// its end. The list draws these lines; `clickOf` says what a click on
/// one names.
pub fn listItem(state: *const State, line: usize) ?Item {
    if (state.rows.items.len == 0) return if (line == 0) .empty else null;
    return ListLines.of(state).item(state, line);
}

/// The panel in the Sessions' rows: its heading, with the way back at the
/// right, then its lines. When more lines come than rows, the last row
/// counts the rest.
fn panelLines(built: *Spans, panel: *const Panel, lines: [][]const Span) error{OutOfMemory}!void {
    built.begin();
    const name = switch (panel.*) {
        .help => "Help",
        .output => |output| try std.fmt.allocPrint(built.arena, "/{s}", .{@tagName(output.name)}),
    };
    _ = try built.put(1, name, built.width -| 2, .{ .colour = .ink, .bold = true });
    try built.putRight(built.width -| 1, "Esc returns", .{ .colour = .quiet });
    lines[0] = try built.finish();
    const total = panel.rows() - 1;
    const room = lines.len - 1;
    const shown = if (total <= room) total else room -| 1;
    var texts = std.mem.splitScalar(u8, panel.text(), '\n');
    for (lines[1..][0..shown]) |*line| {
        built.begin();
        _ = try built.put(1, texts.next().?, built.width -| 2, .{});
        line.* = try built.finish();
    }
    if (shown == total or room == 0) return;
    built.begin();
    _ = try built.put(1, try std.fmt.allocPrint(built.arena, "+{d} more lines", .{total - shown}), built.width -| 2, .{ .colour = .quiet });
    lines[1 + shown] = try built.finish();
}

/// Lines of the list, group by group: a gap before each group but the
/// first, its heading, its shown rows, then its "more" line when folded.
const ListLines = struct {
    first_line: std.enums.EnumArray(Group, usize),
    shown: std.enums.EnumArray(Group, usize),

    fn of(state: *const State) ListLines {
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

    fn lineOf(self: *const ListLines, state: *const State, at: usize) usize {
        const group = state.rows.items[state.order.items[at]].group();
        return self.first_line.get(group) + 1 + (at - state.runs.get(group).start);
    }

    fn item(self: *const ListLines, state: *const State, line: usize) ?Item {
        var previous_end: usize = 0;
        for (std.enums.values(Group)) |group| {
            const run = state.runs.get(group);
            if (run.len == 0) continue;
            const first = self.first_line.get(group);
            if (line < first) return if (line >= previous_end) .gap else null;
            const shown = self.shown.get(group);
            if (line == first) return .{ .heading = group };
            if (line <= first + shown) return .{ .row = run.start + (line - first - 1) };
            if (shown < run.len and line == first + shown + 1) return .{ .more = .{ .group = group, .hidden = run.len - shown } };
            previous_end = first + 1 + shown + @intFromBool(shown < run.len);
        }
        return null;
    }
};

/// A group's heading: its title and how many Sessions it holds, folded
/// ones included.
fn heading(built: *Spans, group: Group, count: usize) error{OutOfMemory}![]const Span {
    built.begin();
    const info = groups.get(group);
    var column = 1 + try built.put(1, info.title, built.width -| 2, .{ .colour = .ink, .bold = true });
    var buffer: [32]u8 = undefined;
    const counted = try std.fmt.allocPrint(built.arena, " {s} {s}", .{ built.glyphs.dot, grouped(&buffer, count) });
    column += try built.put(column, counted, built.width -| column -| 1, .{ .colour = .quiet });
    if (info.help.len != 0) _ = try built.put(column + 2, info.help, built.width -| column -| 3, .{ .colour = .quiet });
    return built.finish();
}

fn moreLine(built: *Spans, hidden: usize) error{OutOfMemory}![]const Span {
    built.begin();
    const text = try std.fmt.allocPrint(built.arena, "{d} more", .{hidden});
    _ = try built.put(3, text, built.width -| 4, .{ .colour = .quiet });
    return built.finish();
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

fn rowLine(built: *Spans, state: *const State, at: usize, columns: Columns, frame: u64) error{OutOfMemory}![]const Span {
    const row = &state.rows.items[state.order.items[at]];
    built.begin();
    const kind = shownKind(state, row);
    const rule = rules.get(kind);
    var words: [work_line.max_words_bytes]u8 = undefined;
    const line = workLine(&words, state, row);
    const faded = state.unreachable_since_ms != null;
    const mark = marks.get(rule.mark);
    const spins = markSpins(state, .{ .row = at }, built.caps);
    const glyph = if (spins) spinner[frame % spinner.len] else if (built.caps.unicode) mark.unicode else mark.ascii;
    _ = try built.put(2, glyph, 1, .{ .colour = if (faded) .quiet else if (line) |shown| toneColour(shown.tone, rule.colour) else rule.colour });

    // Yours in the brightest ink, then named work; unnamed and ended grey.
    const yours = row.group() == .yours;
    const ended = rule.group == .finished or rule.group == .ended;
    const named = title(state, row);
    const row_title = switch (row.archive_state) {
        .active => named.text,
        .archiving => try std.fmt.allocPrint(built.arena, "[Archiving] {s}", .{named.text}),
        .archived => try std.fmt.allocPrint(built.arena, "[Archived] {s}", .{named.text}),
    };
    const title_colour: Colour = if (faded) .quiet else if (yours) .strong else if (named.hint or ended) .quiet else .ink;
    // Only a row outside the working directory names its Workspace, at the
    // end of its title's room.
    const workspace: []const u8 = if (columns.workspace != 0 and row.workspace != state.cwd) workspace: {
        const path = shortPath(state.home, state.workspaces.items[row.workspace]);
        break :workspace try std.mem.concat(built.arena, u8, &.{ path.prefix, path.rest });
    } else "";
    // A word longer than its column, such as a retry's countdown, starts
    // early and takes from the title's room, down to `min_title` cells.
    var word_bytes: [max_word_bytes]u8 = undefined;
    const text = if (columns.word != columns.end) word(&word_bytes, state, row, rule, line, built.script()) else "";
    const word_end = columns.end -| Columns.age_cells -| 1;
    const overflow = built.measure(text) -| (word_end -| columns.word);
    const word_column = @max(columns.word -| overflow, @min(columns.word, Columns.title + Columns.min_title + 2));
    const workspace_cells = if (word_column < columns.word) 0 else @min(built.measure(workspace), columns.workspace);
    // Without a detail column the title still leaves the age its room.
    const title_end = @min((word_column -| 2) -| (if (workspace_cells == 0) 0 else workspace_cells + 2), word_end -| 1);
    _ = try built.put(Columns.title, row_title, title_end -| Columns.title, .{ .colour = title_colour, .bold = yours and !faded });
    _ = try built.putTail(title_end + 2, workspace, workspace_cells, .{ .colour = if (faded) .quiet else .normal });

    if (columns.word != columns.end) {
        // Colour only for what needs the person, or quiet as the work asks.
        const settled: Colour = if (rule.colour == .failure) .failure else .normal;
        // A needs-you row's command is plain: the mark already asks.
        const tone = if (faded) .quiet else if (row.needsYou()) .normal else if (line) |shown| toneColour(shown.tone, .normal) else settled;
        _ = try built.put(word_column, text, word_end -| word_column, .{ .colour = tone });
    }
    var buffer: [8]u8 = undefined;
    try built.putRight(columns.end, ageText(&buffer, (state.now_ms / 1000) -| row.state.since()), .{ .colour = .quiet });
    return built.finish();
}

/// The Session row at `at` in screen order, laid out for `width` cells as
/// segments that fill the width, so a list draws it as given. The list
/// marks the selection; the segments never do. Allocates from `arena`.
pub fn rowSegments(arena: Allocator, state: *const State, at: usize, width: u16, caps: Caps, frame: u64) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    const spans = try rowLine(&built, state, at, Columns.of(width), frame);
    return segmentsOf(arena, spans, width, .{});
}

/// Whether `item`'s mark turns with the frame. Your own Session at work
/// turns the spinner, every one in step; any other mark holds still. Only
/// Unicode in colour spins, and a faded row's state is stale, so it holds
/// still.
pub fn markSpins(state: *const State, item: Item, caps: Caps) bool {
    if (item != .row or state.unreachable_since_ms != null or !caps.unicode or caps.depth == .none) return false;
    const row = &state.rows.items[state.order.items[item.row]];
    return row.group() == .yours and rules.get(shownKind(state, row)).spins;
}

/// Counts and any actionable Host/provider warnings, above the list.
pub fn headerSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    return (try header(arena, state, width, caps)).segments;
}

/// The header's lines, and where its first line, the counts line, shows
/// the view name a click takes back to the default view.
pub fn header(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}!CountsLine {
    const top = try countsLine(arena, state, width, caps);
    var lines: [3][]const Segment = undefined;
    lines[0] = top.segments;
    var count: usize = 1;
    var built: Spans = .of(arena, caps, width);
    if (state.unreachable_since_ms) |since| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.allocPrint(arena, "Host stopped {s} ago. Run rui host start.", .{spanText(&buffer, (state.now_ms -| since) / 1000)});
        lines[count] = try segmentsOf(arena, try bandLine(&built, text), width, .{});
        count += 1;
    }
    if (band(state.rows.items, state.now_ms, state.login_at)) |trouble| {
        lines[count] = try segmentsOf(arena, try providerBand(&built, trouble, state.now_ms), width, .{});
        count += 1;
    }
    var length = count - 1;
    for (lines[0..count]) |line| length += line.len;
    const segments = try arena.alloc(Segment, length);
    var offset: usize = 0;
    for (lines[0..count], 0..) |line, at| {
        if (at != 0) {
            segments[offset] = .{ .text = "\n", .style = .{} };
            offset += 1;
        }
        @memcpy(segments[offset..][0..line.len], line);
        offset += line.len;
    }
    return .{ .segments = segments, .view = top.view };
}

pub const ListRow = struct { segments: []const Segment, heading: bool, selected: bool };

pub fn listSegments(arena: Allocator, state: *const State, item: Item, width: u16, caps: Caps, frame: u64) error{OutOfMemory}!ListRow {
    if (item == .row) {
        const row = &state.rows.items[state.order.items[item.row]];
        return .{ .segments = try rowSegments(arena, state, item.row, width, caps, frame), .heading = false, .selected = if (state.selected) |selected| std.mem.eql(u8, &selected, &row.reference) else false };
    }
    var built: Spans = .of(arena, caps, width);
    const spans = switch (item) {
        .gap => &.{},
        .heading => |group| try heading(&built, group, state.runs.get(group).len),
        .more => |more| try moreLine(&built, more.hidden),
        .empty => try emptyLine(&built, state),
        .row => unreachable,
    };
    return .{ .segments = try segmentsOf(arena, spans, width, .{}), .heading = true, .selected = false };
}

pub fn statusSegments(arena: Allocator, state: *const State, draft: Draft, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    // An open list is the one Esc closes; a closed one leaves Esc the draft.
    const listed = if (state.commands) |shown| shown.seen != .closed else false;
    const first = try segmentsOf(arena, try hints(&built, state, draft, listed), width, .{});
    // A notice's later lines follow on lines of their own.
    const rows = hintRows(state);
    if (rows == 1) return first;
    var shown: [slash_commands.short_result_lines][]const Segment = undefined;
    shown[0] = first;
    var length = first.len;
    var lines = std.mem.splitScalar(u8, state.notice.?.text(), '\n');
    _ = lines.next();
    for (shown[1..rows]) |*line| {
        built.begin();
        _ = try built.put(1, lines.next().?, width -| 2, .{ .colour = state.notice.?.colour });
        line.* = try segmentsOf(arena, try built.finish(), width, .{});
        length += 1 + line.len;
    }
    const segments = try arena.alloc(Segment, length);
    var offset: usize = 0;
    for (shown[0..rows], 0..) |line, at| {
        if (at != 0) {
            segments[offset] = .{ .text = "\n", .style = .{} };
            offset += 1;
        }
        @memcpy(segments[offset..][0..line.len], line);
        offset += line.len;
    }
    return segments;
}

pub fn factsSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    var built: Spans = .of(arena, caps, width);
    built.begin();
    const path = shortPath(state.home, state.workspaces.items[state.cwd]);
    const binding = state.nextBinding();
    const model = binding.model orelse "no model";
    const held = state.heldEffort();
    const saved = if (state.default) |default| default.effort else null;
    const applied = (StartEffort{ .held = held, .model = binding.model }).applied(saved);
    const effort = held orelse if (applied) |value| @tagName(value) else null;
    const sign_in = if (state.default_sign_in_shown) state.nextBinding().signIn() else null;
    const text = try std.fmt.allocPrint(arena, "new Session {s} {s}{s}{s}{s}{s} {s} {s}{s}", .{ built.glyphs.dot, model, if (effort != null) " · " else "", effort orelse "", if (sign_in != null) " · " else "", sign_in orelse "", built.glyphs.dot, path.prefix, path.rest });
    const facts_style: Style = .{ .colour = .quiet, .background = .bar };
    _ = try built.put(1, text, width -| 2, facts_style);
    return segmentsOf(arena, try built.finish(), width, plain(caps, facts_style));
}

/// A panel or model picker supplies its own rows instead of Session groups.
/// A panel's rows in the list's place, as many as `layout` gives the
/// list; null while no panel shows.
pub fn panelItems(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}!?[]const ListRow {
    const panel = if (state.panel) |*shown| shown else return null;
    var built: Spans = .of(arena, caps, width);
    const spans = try arena.alloc([]const Span, @min(panel.rows(), layout(state).list.len()));
    if (spans.len != 0) try panelLines(&built, panel, spans);
    return try rowsOf(arena, spans, width);
}

fn rowsOf(arena: Allocator, spans: []const []const Span, width: u16) error{OutOfMemory}![]const ListRow {
    const items = try arena.alloc(ListRow, spans.len);
    for (spans, items) |line, *item| item.* = .{ .segments = try segmentsOf(arena, line, width, .{}), .heading = true, .selected = false };
    return items;
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

/// The overview's top line: the wordmark, then each mark's count where it
/// is not zero, with the model slots while a Session waits for one; on the
/// right, live memory and the archive view when it is not the default.
/// Memory drops first on a narrow screen, `rui` before `tools`.
pub fn countsSegments(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}![]const Segment {
    return (try countsLine(arena, state, width, caps)).segments;
}

/// The counts line, and the columns its view name takes, `start` up to
/// `end`, when it shows one: a click there returns to the default view.
pub const CountsLine = struct { segments: []const Segment, view: ?struct { start: u16, end: u16 } = null };

pub fn countsLine(arena: Allocator, state: *const State, width: u16, caps: Caps) error{OutOfMemory}!CountsLine {
    var result: CountsLine = .{ .segments = &.{} };
    var built: Spans = .of(arena, caps, width);
    built.begin();
    const bar: Style = .{ .background = .bar };
    const end = built.width -| 1;
    var column: usize = 1;
    // रुई beside rui, as on a station board, where the terminal draws it;
    // elsewhere rui alone.
    const wordmark: Style = .{ .colour = .strong, .background = .bar };
    if (caps.unicode and caps.devanagari) column += try built.put(column, "रुई", end -| column, .{ .colour = .ink, .background = .bar }) + 1;
    column += try built.put(column, "rui", end -| column, wordmark);
    const counts_ = state.summary.counts;
    const shown = [_]struct { Mark, usize, Colour }{
        .{ .needs_you, counts_.needs_you, .attention },
        .{ .active, counts_.working, .normal },
        .{ .queued, counts_.queued, .normal },
        .{ .failed, counts_.failed, .failure },
    };
    for (shown) |entry| {
        const mark, const count, const colour = entry;
        if (count == 0) continue;
        const glyph = if (caps.unicode) marks.get(mark).unicode else marks.get(mark).ascii;
        var number: [32]u8 = undefined;
        const text = if (mark == .queued and state.host != null)
            try std.fmt.allocPrint(arena, "{s} {s} {s} slots {d}/{d}", .{ glyph, grouped(&number, count), built.glyphs.dot, state.host.?.slots_in_use, state.host.?.slots })
        else
            try std.fmt.allocPrint(arena, "{s} {s}", .{ glyph, grouped(&number, count) });
        column = column + 2 + try built.put(column + 2, text, end -| (column + 2), .{ .colour = colour, .background = .bar });
    }
    // The right side, widest first, dropping what does not fit.
    const view: []const u8 = if (state.archive == .active) "" else archiveViewName(state.archive);
    var rui_buffer: [16]u8 = undefined;
    var tools_buffer: [16]u8 = undefined;
    const choices: [3][]const u8 = if (state.memory) |memory| choices: {
        const rui = try std.fmt.allocPrint(arena, "rui {s}", .{sizeText(&rui_buffer, memory.rui)});
        const tools = if (memory.tools) |bytes| try std.fmt.allocPrint(arena, "tools {s}", .{sizeText(&tools_buffer, bytes)}) else "";
        break :choices if (tools.len == 0) .{ rui, "", "" } else .{ try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ rui, built.glyphs.dot, tools }), tools, "" };
    } else .{ "", "", "" };
    for (choices) |memory| {
        const text = if (memory.len == 0) view else if (view.len == 0) memory else try std.fmt.allocPrint(arena, "{s}  {s}", .{ memory, view });
        const cells = built.measure(text);
        if (text.len != 0 and column + 2 + cells > end) continue;
        try built.pad(end -| cells, bar);
        try built.putRight(end, text, bar);
        if (view.len != 0) result.view = .{ .start = @intCast(end - built.measure(view)), .end = @intCast(end) };
        break;
    }
    try built.pad(built.width, bar);
    result.segments = try segmentsOf(arena, try built.finish(), width, bar);
    return result;
}

/// Memory in whole mebibytes, or gibibytes to a tenth, as `42 MB` or `1.8 GB`.
fn sizeText(buffer: *[16]u8, bytes: u64) []const u8 {
    const gib = 1024 * mib;
    if (bytes >= gib) {
        const tenths = (bytes / (gib / 10)) + @intFromBool(bytes % (gib / 10) >= gib / 20);
        return std.fmt.bufPrint(buffer, "{d}.{d} GB", .{ tenths / 10, tenths % 10 }) catch unreachable;
    }
    return std.fmt.bufPrint(buffer, "{d} MB", .{(bytes + mib / 2) / mib}) catch unreachable;
}

fn blankCells(arena: Allocator, cells: usize) error{OutOfMemory}![]const u8 {
    const bytes = try arena.alloc(u8, cells);
    @memset(bytes, ' ');
    return bytes;
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

/// Bytes the row's word takes at most: work's words and its clock, or a
/// failure's cause or saved code.
const max_word_bytes = @max(work_line.max_words_bytes + work_line.max_clock_bytes, session_work.max_code_bytes);

/// What the row says in its detail column, only where the mark and the
/// group leave something out: a wait's countdown, work that explains a
/// wait, or a failure's cause. Otherwise nothing.
fn word(buffer: *[max_word_bytes]u8, state: *const State, row: *const Row, rule: Rule, line: ?work_line.Line, script: work_line.Script) []const u8 {
    if (row.archive_state == .archiving) return "Stopping and archiving";
    // A needs-you row names the command its Action would run, once read.
    if (row.needsYou() and state.openStop(row.reference) == null) return switch (row.command) {
        .read => |index| state.lines.items[index].slice(),
        else => "",
    };
    if (line) |shown| {
        if (!rule.says) return "";
        var clock: [work_line.max_clock_bytes]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ shown.words, work_line.clockText(&clock, shown.clock, .row, script) }) catch unreachable;
    }
    if (!rule.cause) return "";
    return switch (row.state) {
        .failed => |*failed| causeOf(failed.code.slice()),
        else => "",
    };
}

/// A failure's cause in a few words, else its saved code.
fn causeOf(code: []const u8) []const u8 {
    return switch (failure_class.of(code)) {
        .policy => "Refused by the provider",
        .quota => "Out of quota",
        .plan => "Model not in plan",
        .model => "Model not served",
        .sign_in => "Sign-in expired",
        .api_key => "API key rejected",
        .overflow => "Context full",
        .unreachable_provider => "Provider unreachable",
        .retries_exhausted => "Retries ran out",
        .interrupted => "Interrupted",
        .refused, .other => code,
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
    archive_state: ArchiveState = .active,
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
        .archive_state = options.archive_state,
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
    const input: Input = .{ .composer = .{ .action = action } };
    return step(state, .{ .composed = .{ .input = input, .draft = draft } });
}

/// Renders `state` at `width` by `height`, which the shell steps before it
/// draws.
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
    const input: Input = .{ .composer = .submit };
    return step(state, .{ .composed = .{ .input = input, .draft = draft } });
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
            .archive => |request| {
                try std.testing.expectEqualStrings(&request.reference, &got.archive.reference);
                try std.testing.expectEqual(request.archived, got.archive.archived);
            },
            .save_default => |binding| {
                try std.testing.expectEqual(binding.provider, got.save_default.provider);
                try std.testing.expectEqualStrings(binding.model.slice(), got.save_default.model.slice());
            },
            .replace => |change| {
                try std.testing.expectEqual(change.start, got.replace.start);
                try std.testing.expectEqual(change.end, got.replace.end);
                try std.testing.expectEqualStrings(change.text, got.replace.text);
            },
            .command => |command| {
                try std.testing.expectEqual(command.name, got.command.name);
                try std.testing.expectEqualStrings(command.text, got.command.text);
                try std.testing.expectEqual(command.session, got.command.session);
            },
            .read_commands => |reads| {
                try std.testing.expectEqual(reads.len, got.read_commands.len);
                for (reads.slice(), got.read_commands.slice()) |x, y| {
                    try std.testing.expectEqualStrings(&x.reference, &y.reference);
                    try std.testing.expectEqual(x.action, y.action);
                }
            },
            .list_models, .clear_draft, .cancel_upgrade, .exit => {},
        }
    }
}

/// A notice, which reads whole on a 40-column overview in the rows under
/// its input, a row for each line.
fn expectNotice(state: *State, expected: ?[]const u8) !void {
    return expectNoticeAt(state, expected, true);
}

/// A notice whose data (a Host's code, the list of start settings) may be
/// cut at the edge of a narrow overview; its wording is not.
fn expectNoticeWithData(state: *State, expected: []const u8) !void {
    return expectNoticeAt(state, expected, false);
}

fn expectNoticeAt(state: *State, expected: ?[]const u8, whole_at_40: bool) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try std.testing.expectEqualStrings(text, notice.text());
        if (whole_at_40) {
            const screen = try screenText(state, 40, 24, .{});
            defer std.testing.allocator.free(screen);
            // The status row ends the screen, a line for each of the
            // notice's.
            var lines = std.mem.splitScalar(u8, screen, '\n');
            for (0..std.mem.count(u8, screen, "\n") - std.mem.count(u8, text, "\n")) |_| _ = lines.next();
            var said = std.mem.splitScalar(u8, text, '\n');
            while (said.next()) |line| try std.testing.expectEqualStrings(line, std.mem.trim(u8, lines.next().?, " "));
        }
    } else if (state.notice) |*notice| try std.testing.expectEqualStrings("", notice.text());
}

fn expectSelected(state: *const State, expected: *const [6]u8) !void {
    try std.testing.expectEqualStrings(expected, &(state.selected orelse return error.TestExpectedSelection));
}

fn screenText(state: *State, width: u16, height: u16, caps: Caps) ![]u8 {
    return frameText(state, width, height, caps, 0);
}

/// What the App overview's rows show at a size, from the segments each of
/// its widgets draws: the header lines, the list or panel rows, the facts
/// row and the status row under `draft`. The App lays them out; this keeps
/// only their order, with the panel given the rows the core's layout gives
/// it.
const Frame = struct {
    arena: std.heap.ArenaAllocator,
    lines: []const []const Segment,
    /// The list's or panel's lines.
    list: []const []const Segment,
    caps: Caps,
    width: u16,

    fn of(state: *State, width: u16, height: u16, caps: Caps, frame: u64) !Frame {
        return drafted(state, .{}, width, height, caps, frame);
    }

    fn drafted(state: *State, draft: Draft, width: u16, height: u16, caps: Caps, frame: u64) !Frame {
        try expectEffects(&.{}, try step(state, .{ .resized = .{ .width = width, .height = height } }));
        var self: Frame = .{ .arena = .init(std.testing.allocator), .lines = &.{}, .list = &.{}, .caps = caps, .width = width };
        errdefer self.arena.deinit();
        const gpa = self.arena.allocator();
        const top = try headerSegments(gpa, state, width, caps);
        const panel = try panelItems(gpa, state, width, caps);
        var list_count: usize = 0;
        if (panel) |items| {
            list_count = items.len;
        } else {
            while (listItem(state, list_count) != null) : (list_count += 1) {}
        }
        const lines = try gpa.alloc([]const Segment, top.len + 1 + list_count + 2);
        var count: usize = 0;
        var start: usize = 0;
        for (top, 0..) |segment, at| if (std.mem.eql(u8, segment.text, "\n")) {
            lines[count] = top[start..at];
            count += 1;
            start = at + 1;
        };
        lines[count] = top[start..];
        count += 1;
        const first = count;
        if (panel) |items| {
            for (items) |item| {
                lines[count] = item.segments;
                count += 1;
            }
        } else {
            var at: usize = 0;
            while (listItem(state, at)) |item| : (at += 1) {
                lines[count] = (try listSegments(gpa, state, item, width, caps, frame)).segments;
                count += 1;
            }
        }
        const last = count;
        lines[count] = try factsSegments(gpa, state, width, caps);
        count += 1;
        lines[count] = try statusSegments(gpa, state, draft, width, caps);
        count += 1;
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
    .{ .state = .{ .pending = ago(5) }, .heading = " Active", .unicode = "  ◌ Write the notes                                                          5s", .ascii = "  : Write the notes                                                          5s", .colour = .quiet, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .heading = " Active", .unicode = "  ● Write the notes                                                         40s", .ascii = "  * Write the notes                                                         40s", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .heading = " Active", .unicode = "  ● Write the notes                          Provider error · retry in 12s  30s", .ascii = "  * Write the notes                          Provider error - retry in 12s  30s", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .heading = " Active", .unicode = "  ● Write the notes                                  Run the logic tests     1m", .ascii = "  * Write the notes                                  Run the logic tests     1m", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .heading = " Needs you", .unicode = "  ? Write the notes                                                          3m", .ascii = "  ? Write the notes                                                          3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .heading = " Active", .unicode = "  ● Write the notes                                  Stopping…               8s", .ascii = "  * Write the notes                                  Stopping.               8s", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .heading = " Finished", .unicode = "  ✓ Write the notes                                                         12m", .ascii = "  + Write the notes                                                         12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .heading = " Stopped or failed", .unicode = "  × Write the notes                                provider_output_invalid   3h", .ascii = "  x Write the notes                                provider_output_invalid   3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .heading = " Stopped or failed", .unicode = "  ■ Write the notes                                                          2d", .ascii = "  # Write the notes                                                          2d", .colour = .normal, .stoppable = false },
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
            _ = lines.next();
            // The heading counts the one Session.
            const counted = try std.fmt.allocPrint(std.testing.allocator, "{s} {s} 1", .{ case.heading, if (caps.unicode) unicode_glyphs.dot else ascii_glyphs.dot });
            defer std.testing.allocator.free(counted);
            try std.testing.expectEqualStrings(counted, lines.next().?);
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
        // The mark takes its colour, and the word one only when it needs
        // the person or is quiet. (GroupedList paints the selection.)
        state.selected = null;
        var unselected = try Frame.of(&state, 80, 24, .{}, 0);
        defer unselected.deinit();
        try std.testing.expectEqual(Style{ .colour = case.colour }, unselected.styleAt(2, 2).?);
        const tone: Colour = switch (case.colour) {
            .attention, .failure, .quiet => case.colour,
            else => .normal,
        };
        if (unselected.styleAt(2, 53)) |style| try std.testing.expectEqual(Style{ .colour = tone }, style);
    }
}

test "a description's controls read escaped in its row's words, as its call row shows them" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run\t\x1b[2J\u{202e}tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{session("k7m2qx", bash, .{ .label = "Write the notes" })});
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..2) |_| _ = lines.next();
    try std.testing.expectEqualStrings("  ● Write the notes                                Run\\t\\x1b[2J\\u202etests   1m", lines.next().?);
}

test "a retry that has fallen due reads as queued in its group, mark and colour" {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{session("k7m2qx", due, .{ .label = "Write the notes" })});
    defer state.deinit();
    state.selected = null;
    const text = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "Write the notes").?;
    const start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n').?;
    try std.testing.expectEqualStrings("  ◌ Write the notes                                                          2s", text[start..end]);
    try std.testing.expect(std.mem.indexOf(u8, text, " Active · 1\n") != null);
    var screen = try Frame.of(&state, 80, 24, .{ .depth = .none }, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .normal }, screen.styleAt(2, 2).?);
}

test "each heading counts its group, and Yours takes a Session from the group it would join" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Thinking" }),
        session("h8q2mz", .{ .approval = ago(5) }, .{ .label = "Asking" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
        session("e5f6g7", .{ .pending = ago(9) }, .{ .label = "Mine, waiting", .yours = true }),
        session("m1n2p3", .{ .finished = ago(60) }, .{ .label = "Done" }),
    });
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    inline for (.{ " Needs you · 1\n", " Yours · 1\n", " Active · 2\n", " Finished · 1\n" }) |heading_line| {
        try std.testing.expect(std.mem.indexOf(u8, text, heading_line) != null);
    }
    // A queued row shows its own mark, under Yours too, and no word.
    try std.testing.expect(std.mem.indexOf(u8, text, "  ◌ Mine, waiting                                                            9s\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Waiting for a slot                                                       5s\n") != null);
}

/// Each group's labels, in screen order.
fn expectGroups(state: *const State, expected: []const struct { Group, []const []const u8 }) !void {
    var seen: usize = 0;
    for (expected) |entry| {
        const group, const labels = entry;
        const run = state.runs.get(group);
        try std.testing.expectEqual(labels.len, run.len);
        for (labels, state.order.items[run.start..][0..run.len]) |label, index| {
            try std.testing.expectEqualStrings(label, state.rows.items[index].label.?.slice());
        }
        seen += run.len;
    }
    try std.testing.expectEqual(state.rows.items.len, seen);
}

test "a Session waiting on an Action leads in Needs you, yours or not, and Yours keeps the rest" {
    const beside_bash: WorkState = .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 1 } };
    const running_bash: WorkState = .{ .bash = .{ .since = test_now_s - 20, .call = 0, .description = bounded(max_label_bytes, "Run the store tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{
        session("y0urs1", .{ .working = ago(40) }, .{ .label = "Mine, thinking", .yours = true }),
        session("y0urs2", .{ .approval = ago(9) }, .{ .label = "Mine, asking", .yours = true }),
        session("a5k1ng", .{ .approval = ago(5) }, .{ .label = "Theirs, asking" }),
        session("b4sh01", beside_bash, .{ .label = "Theirs, asking beside Bash" }),
        session("b4sh02", running_bash, .{ .label = "Theirs, running Bash" }),
        session("f1n1sh", .{ .finished = ago(60) }, .{ .label = "Theirs, finished" }),
    });
    defer state.deinit();
    // Newest wait first, as every group orders its rows; your own wait
    // leaves Yours for Needs you.
    try expectGroups(&state, &.{
        .{ .needs_you, &.{ "Theirs, asking", "Mine, asking", "Theirs, asking beside Bash" } },
        .{ .yours, &.{"Mine, thinking"} },
        .{ .active, &.{"Theirs, running Bash"} },
        .{ .finished, &.{"Theirs, finished"} },
    });
    try std.testing.expectEqualStrings("Needs you", groups.get(.needs_you).title);
    // The list opens on what needs you.
    try std.testing.expectEqualStrings("a5k1ng", &state.selected.?);
}

test "queued rows sit last in their group, longest wait first, after work newest first" {
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
    try expectGroups(&state, &.{
        .{ .yours, &.{ "Mine, finished 5s", "Mine, working 50s", "Mine, queued 70s" } },
        .{ .active, &.{ "Retrying in 18s", "Working 40s", "Stopping 50s", "Queued 40s", "Queued 25s", "Queued 10s", "Retry due" } },
    });
}

test "the summary counts what the counts line shows by mark: needs you, working, queued and failed" {
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
    const beside_bash: WorkState = .{ .bash = .{ .since = test_now_s - 60, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 1 } };
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
    state.selected = null;
    const a = arena.allocator();
    // Needs you: `?` in the attention colour and no word, beside running
    // Bash too; the command comes from the Action once read.
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .ink }, .{ "2m", .quiet } });
    try expectRow(try rowOf(a, &state, "Asking beside Bash", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Asking beside Bash", .ink }, .{ "1m", .quiet } });
    // Queued: a dim `◌`, the title and the wait, no word.
    try expectRow(try rowOf(a, &state, "Check install script", 100, .{}), 100, &.{ .{ "◌", .quiet }, .{ "Check install script", .ink }, .{ "10s", .quiet } });
    // A rate limit counts down without the attempt number.
    try expectRow(try rowOf(a, &state, "Investigate retry storm", 100, .{}), 100, &.{ .{ "●", .attention }, .{ "Investigate retry storm", .ink }, .{ "Rate limited · retry in 18s", .attention }, .{ "30s", .quiet } });
    // A failure names its cause in the failure colour, else its saved
    // code; a stop says nothing beyond its mark, and neither names the
    // Session that started it.
    try expectRow(try rowOf(a, &state, "Benchmark memory", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Benchmark memory", .quiet }, .{ "Sign-in expired", .failure }, .{ "20m", .quiet } });
    try expectRow(try rowOf(a, &state, "Odd failure", 100, .{}), 100, &.{ .{ "×", .failure }, .{ "Odd failure", .quiet }, .{ "provider_output_invalid", .failure }, .{ "1m", .quiet } });
    try expectRow(try rowOf(a, &state, "Stopped by me", 100, .{}), 100, &.{ .{ "■", .normal }, .{ "Stopped by me", .quiet }, .{ "1m", .quiet } });
}

test "row segments drop the detail column on a narrow screen and keep mark, title and age" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var state = try opened(&.{
        session("f4iled", .{ .failed = .{ .since = test_now_s - 20 * 60, .code = bounded(session_work.max_code_bytes, "provider_http_401"), .resets_at = null } }, .{ .label = "Benchmark memory" }),
    });
    defer state.deinit();
    state.selected = null;
    try expectRow(try rowOf(arena.allocator(), &state, "Benchmark memory", 40, .{}), 40, &.{ .{ "×", .failure }, .{ "Benchmark memory", .quiet }, .{ "20m", .quiet } });
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

test "App header preserves simultaneous Host and sign-in recovery instructions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var state = try opened(&.{failedRow("aaaaaa", 60, "provider_http_401", null)});
    defer state.deinit();
    state.unreachable_since_ms = state.now_ms - 5000;
    const segments = try headerSegments(arena.allocator(), &state, 100, .{});
    try std.testing.expectEqual(Background.bar, (try styleOf(segments, "rui")).background);
    try std.testing.expectEqual(Background.band, (try styleOf(segments, "Host stopped 5s ago. Run rui host start.")).background);
    try std.testing.expectEqual(Background.band, (try styleOf(segments, "Sign-in expired. Run ")).background);
    var breaks: usize = 0;
    for (segments) |segment| breaks += std.mem.count(u8, segment.text, "\n");
    try std.testing.expectEqual(@as(usize, 2), breaks);
}

test "the counts line counts by mark, leaves zeros out, and colours only needs you and failures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try opened(&.{
        session("a5k1ng", .{ .approval = ago(5) }, .{ .label = "Asking" }),
        session("w00001", .{ .working = ago(40) }, .{ .label = "Working" }),
        session("w00002", .{ .working = ago(30) }, .{ .label = "Working too" }),
        failedRow("f4iled", 60, "provider_output_invalid", null),
    });
    defer state.deinit();
    const line = try countsSegments(a, &state, 100, .{ .devanagari = true });
    try expectLine(line, 100, &.{ "रुई rui", "? 1", "● 2", "× 1" });
    try std.testing.expectEqual(Colour.attention, (try styleOf(line, "? 1")).colour);
    try std.testing.expectEqual(Colour.normal, (try styleOf(line, "● 2")).colour);
    try std.testing.expectEqual(Colour.failure, (try styleOf(line, "× 1")).colour);
    // Every cell sits on the bar.
    for (line) |segment| try std.testing.expectEqual(Background.bar, segment.style.background);
    // ASCII: rui alone, and the ASCII marks.
    try expectLine(try countsSegments(a, &state, 100, .{ .unicode = false }), 100, &.{ "rui", "? 1", "* 2", "x 1" });
}

test "the counts line shows the slots only while something queues, and memory on the right" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try opened(&.{
        session("w00001", .{ .working = ago(40) }, .{ .label = "Working" }),
        session("q00001", .{ .pending = ago(10) }, .{ .label = "Queued" }),
    });
    defer state.deinit();
    // No Host facts yet: the queue counts without slots.
    try expectLine(try countsSegments(a, &state, 100, .{ .devanagari = true }), 100, &.{ "रुई rui", "● 1", "◌ 1" });
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 60, .slots = 2, .slots_in_use = 2 } });
    _ = try step(&state, .{ .memory = .{ .rui = 42 * mib, .tools = 1843 * mib } });
    try expectLine(try countsSegments(a, &state, 100, .{ .devanagari = true }), 100, &.{ "रुई rui", "● 1", "◌ 1 · slots 2/2", "rui 42 MB · tools 1.8 GB" });
    // Nothing queued: no slots, and no tools while none run.
    _ = try refresh(&state, .changed, testToken(2), &.{session("q00001", .{ .working = ago(0) }, .{ .label = "Queued" })});
    _ = try step(&state, .{ .memory = .{ .rui = 37 * mib, .tools = null } });
    try expectLine(try countsSegments(a, &state, 100, .{ .devanagari = true }), 100, &.{ "रुई rui", "● 2", "rui 37 MB" });
    // Narrow: memory drops before the counts, rui before tools.
    _ = try step(&state, .{ .memory = .{ .rui = 42 * mib, .tools = 1843 * mib } });
    try expectLine(try countsSegments(a, &state, 30, .{ .devanagari = true }), 30, &.{ "रुई rui", "● 2", "tools 1.8 GB" });
    try expectLine(try countsSegments(a, &state, 16, .{ .devanagari = true }), 16, &.{ "रुई rui", "● 2" });
}

test "the counts line names the archive view only off the default" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try opened(&.{});
    defer state.deinit();
    try expectLine(try countsSegments(a, &state, 80, .{ .devanagari = true }), 80, &.{"रुई rui"});
    state.archive = .archived;
    try expectLine(try countsSegments(a, &state, 80, .{ .devanagari = true }), 80, &.{ "रुई rui", "Archived" });
    state.archive = .all;
    try expectLine(try countsSegments(a, &state, 80, .{ .devanagari = true }), 80, &.{ "रुई rui", "All" });
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
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .ink }, .{ "2m", .quiet } });
    // A command's first line shows, in the row's normal ink.
    _ = try step(&state, .{ .command = .{ .reference = "a5k1ng".*, .action = 41, .text = "zig build test-store\n-Dfilter=retry" } });
    state.selected = null;
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .ink }, .{ "zig build test-store", .normal }, .{ "2m", .quiet } });
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
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .ink }, .{ "2m", .quiet } });
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
    try expectRow(try rowOf(a, &state, "Fix flaky store test", 100, .{}), 100, &.{ .{ "?", .attention }, .{ "Fix flaky store test", .ink }, .{ "2m", .quiet } });
    // While its conversation is open, that conversation alone reads the
    // Action; the row asks once the conversation returns.
    next.first_action = 43;
    state.conversing = "a5k1ng".*;
    for ((try refresh(&state, .changed, testToken(6), &.{next})).slice()) |effect| try std.testing.expect(effect != .read_commands);
    state.conversing = null;
    var returned: ?Commands = null;
    for ((try refresh(&state, .changed, testToken(7), &.{next})).slice()) |effect| if (effect == .read_commands) {
        returned = effect.read_commands;
    };
    try std.testing.expectEqual(@as(u64, 43), returned.?.items[0].action);
}

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

test "your Sessions at work turn the spinner in step, and every other mark holds still" {
    var state = try opened(&spinning);
    defer state.deinit();
    state.selected = null;
    for (0..spinner.len + 1) |frame| {
        const text = try frameText(&state, 80, 24, .{}, frame);
        defer std.testing.allocator.free(text);
        const turn = spinner[frame % spinner.len];
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, thinking"));
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, running"));
        try std.testing.expectEqualStrings("?", markOf(text, "Mine, asking"));
        try std.testing.expectEqualStrings("◌", markOf(text, "Mine, queued"));
        try std.testing.expectEqualStrings("●", markOf(text, "Mine, retrying"));
        try std.testing.expectEqualStrings("●", markOf(text, "Mine, stopping"));
        try std.testing.expectEqualStrings("●", markOf(text, "Theirs, thinking"));
        try std.testing.expectEqualStrings("✓", markOf(text, "Theirs, finished"));
        var screen = try Frame.of(&state, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(anySpins(&state, .{}));
        // The spinner keeps its rule's colour.
        const mine = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Mine, thinking").?], "\n");
        try std.testing.expectEqual(Style{ .colour = .ink }, screen.styleAt(mine, 2).?);
    }
    // A stop the person asked for holds the mark still before the Host
    // reports it.
    state.selected = "y0urs1".*;
    _ = try press(&state, .{}, .stop);
    _ = try press(&state, .{}, .stop);
    try std.testing.expect(state.openStop("y0urs1".*) != null);
    const asked = try frameText(&state, 80, 24, .{}, 1);
    defer std.testing.allocator.free(asked);
    try std.testing.expectEqualStrings("●", markOf(asked, "Mine, thinking"));
    // ASCII, NO_COLOR and a faded screen hold still on every frame.
    for ([_]Caps{ .{ .unicode = false }, .{ .depth = .none }, .{ .unicode = false, .depth = .none }, .{} }, 0..) |caps, at| {
        if (at == 3) state.unreachable_since_ms = state.now_ms;
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
            try expectEffects(&.{}, try press(&state, .{}, .stop));
            var buffer: [64]u8 = undefined;
            const expected = if (rules.get(case.state).word) |said| try std.fmt.bufPrint(&buffer, "k7m2qx is already {s}.", .{said}) else "k7m2qx: Stopping";
            try expectNotice(&state, expected);
            continue;
        }
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .{}, .stop));
        try expectNotice(&state, null);
        // Until its result arrives the row says it is stopping, and a second
        // ctrl-x finds nothing to stop.
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "● Write the notes                                  Stopping…") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "ctrl+x yes") == null);
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectNotice(&state, "k7m2qx: Stopping");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    }
}

fn expectSaid(text: ?[]const u8, stoppable_: bool, said: Said) !void {
    try std.testing.expectEqualStrings(text orelse "", said.text orelse "");
    try std.testing.expectEqual(text == null, said.text == null);
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
    try expectNoticeWithData(&state, "! k7m2qx not stopped: session_not_found");
    // Ended work takes no stop.
    try std.testing.expect(conversation(&state, ref, .working, .{}, &test_said).stoppable and !conversation(&state, ref, .finished, .{}, &test_said).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .finished, .input = .stop } }));
    try expectNotice(&state, "k7m2qx is already finished.");
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
    _ = try press(&state, .{}, .next);
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
        if (n != 0) try expectEffects(&.{}, try press(&state, .{}, .next));
        ref.* = state.selected.?;
        for (stopped[0..n]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, ref));
        var bytes: [32]u8 = undefined;
        const handle = try std.fmt.bufPrint(&bytes, "stop-handle-{d}", .{n});
        var notice: [128]u8 = undefined;
        const recover = try std.fmt.bufPrint(&notice, "! {s} stop unsure; details on exit", .{ref});
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
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings(expected.written(), departure.written());
}

test "enter on a row opens it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    // Needs you leads; the next row is the first of Yours.
    try expectEffects(&.{}, try press(&state, draft, .next));
    try expectEffects(&.{.{ .open = "k7m2qx".* }}, try submit(&state, draft));
    // A blank draft is no request: Enter still opens the row.
    draft = try typeText(&state, "  ");
    try expectEffects(&.{ .clear_draft, .{ .open = "k7m2qx".* } }, try submit(&state, draft));
    try expectSelected(&state, "k7m2qx");
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
    try expectSelected(&state, "r4t9vw");
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
    try expectNoticeWithData(&state, "! Unknown command /home/me/project · /help");
    draft = try typeText(&state, "//home/me/project needs investigating");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "/home/me/project needs investigating" } }}, try submit(&state, draft));
}

/// The lines of `state` with `draft` at `width` by `height`.
fn draftLines(state: *State, draft: Draft, width: u16, height: u16) ![]u8 {
    var shown: Frame = try .drafted(state, draft, width, height, .{}, 0);
    defer shown.deinit();
    return shown.text();
}

/// The status row under `draft` reads `expected`.
fn expectLastLine(state: *State, draft: Draft, expected: []const u8) !void {
    const text = try draftLines(state, draft, 80, 24);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text[std.mem.lastIndexOfScalar(u8, text, '\n').? + 1 ..]);
}

fn expectLines(text: []const u8, first: usize, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..first) |_| _ = lines.next();
    for (expected) |line| try std.testing.expectEqualStrings(line, std.mem.trimEnd(u8, lines.next().?, " "));
}

test "typing / lists the overview's commands between the rule and the draft, as a conversation does" {
    var state = try opened(&mixed);
    defer state.deinit();
    // App's palette draws the list (Overview's tests); the core keeps it.
    _ = try typeText(&state, "/");
    try std.testing.expectEqual(@as(usize, 10), state.commands.?.list.shown().len);
    // Typing narrows the list; Tab completes the one left.
    _ = try typeText(&state, "/m");
    try std.testing.expectEqualStrings("odel", state.commands.?.list.completion(0));
    _ = try typeText(&state, "/c");
    try std.testing.expectEqualStrings("onfigure ", state.commands.?.list.completion(0));
    // No list for text, `//`, a word past its command, or a name no command
    // starts.
    for ([_][]const u8{ "fix it", "//home", "/status" }) |text| {
        errdefer std.debug.print("draft={s}\n", .{text});
        _ = try typeText(&state, text);
        try std.testing.expect(state.commands == null);
    }
    const model: Draft = .{ .bytes = "/model ", .cursor = 7, .edits = test_edits +% 1 };
    try expectEffects(&.{.list_models}, try step(&state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = model } }));
    try std.testing.expect(state.picker != null);
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
    _ = try press(&state, draft, .next);
    try expectEffects(&.{.exit}, try submit(&state, draft));
    // /configure alone only says its usage: Enter adds its word and a
    // space, for an option.
    state.commands.?.highlight = 1;
    try expectEffects(&.{.{ .replace = .{ .start = 1, .end = 1, .text = "configure " } }}, try submit(&state, draft));
    // An option that takes a value is added for it, and the next list
    // starts at its top, however far down the highlight was.
    draft = try typeText(&state, "/configure ");
    state.commands.?.highlight = 4;
    try expectEffects(&.{.{ .replace = .{ .start = "/configure ".len, .end = "/configure ".len, .text = "--label " } }}, try submit(&state, draft));
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

test "Enter runs a command by the overview's table and names its usage when misused" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/exit now")));
    try expectNotice(&state, "! Usage: /exit");
    try expectEffects(&.{.exit}, try submit(&state, try typeText(&state, "/exit ")));
}

test "Esc closes a shown command list and keeps the draft; a change opens it again" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    var draft: Draft = .{ .bytes = "/m", .cursor = 2, .edits = 2 };
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = draft } }));
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.drawn, state.commands.?.seen);
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expectEqual(.closed, state.commands.?.seen);
    try expectLastLine(&state, draft, " esc clear");
    // With the list closed, Esc clears the draft.
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.closed, state.commands.?.seen);
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    // An edit opens it again.
    draft = .{ .bytes = "/mo", .cursor = 3, .edits = 3 };
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.drawn, state.commands.?.seen);
    // The hint says what Enter does to each slash draft.
    try expectLastLine(&state, try typeText(&state, "/exit "), " enter run · esc clear");
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
    try expectStatusLines(&state, &.{" start settings: --permission-mode ask --label \"lane four\" · esc clear"});
    // A later value replaces an earlier one; the rest stay.
    draft = try typeText(&state, "/configure --label \"lane \\\"five\\\"\" --model gpt-5.5");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    var buffer: [2 * start_options.len][]const u8 = undefined;
    const args = state.settings.args(&buffer);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    for ([_][]const u8{ "--model", "gpt-5.5", "--permission-mode", "ask", "--label", "lane \"five\"" }, args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try expectStatusLines(&state, &.{" start settings: --model gpt-5.5 --permission-mode ask --label \"la… · esc clear"});

    var held: StartSettings = .{};
    try held.put(startOption("model").?, "gpt-5.5");
    try held.put(startOption("permission-mode").?, "ask");
    try held.put(startOption("label").?, "lane \"five\"");
    draft = try typeText(&state, "Run the tests");
    try expectEffects(&.{.{ .start = .{ .settings = &held, .text = "Run the tests" } }}, try submit(&state, draft));
    _ = try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } });
    try std.testing.expect(state.settings.empty());

    // Only `session start` options, in the conversation's grammar, are held.
    for ([_]struct { []const u8, []const u8 }{
        .{ "/configure --instructions -", "! Set --instructions after the start" },
        .{ "/configure --text-output", "! Set --text-output after the start" },
        .{ "/configure --help", configure_usage },
        .{ "/configure --bogus 1", configure_usage },
        .{ "/configure --label \"open", configure_usage },
        // The Host would admit it; its Turns would fail at the provider.
        .{ "/configure --model \"gpt 5\"", "! Not a model ID; session configure -h" },
        .{ "/status", "! Unknown command /status · /help" },
    }) |case| {
        draft = try typeText(&state, case[0]);
        try expectEffects(&.{}, try submit(&state, draft));
        try if (case[1].ptr == configure_usage.ptr) expectNoticeWithData(&state, case[1]) else expectNotice(&state, case[1]);
        try std.testing.expect(state.settings.empty());
    }
    // Alone, /configure waits for an option: Enter on it in the list adds
    // the space that shows them.
    draft = try typeText(&state, "/configure");
    try expectEffects(&.{.{ .replace = .{ .start = "/configure".len, .end = "/configure".len, .text = " " } }}, try submit(&state, draft));
    // A model Rui does not list is held, with a quiet word on its limits.
    draft = try typeText(&state, "/configure --model unlisted-model");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try std.testing.expectEqualStrings("unlisted-model", state.settings.get(startOption("model").?).?);
    try std.testing.expectEqual(Colour.quiet, state.notice.?.colour);
}

test "the composer's /word asks the Workspace's skills, but not while an Upgrade holds Host requests" {
    var state = try opened(&mixed);
    defer state.deinit();
    const draft: Draft = .{ .bytes = "use /re", .cursor = "use /re".len, .edits = 1 };
    try std.testing.expectEqual(@as(?skill_completion.Ask, null), askSkills(&state, .{ .bytes = "use it", .cursor = 3, .edits = 1 }));
    state.upgrade.after = .reobserving;
    try std.testing.expectEqual(@as(?skill_completion.Ask, null), askSkills(&state, draft));
    state.upgrade.after = .open;
    const read = askSkills(&state, draft).?;
    try std.testing.expectEqualStrings("re", read.prefix);
    // Its page, owned by the state, lists over the draft once a frame draws it.
    const gpa = state.gpa;
    const entries = try gpa.alloc(skill_suggestions.Entry, 1);
    entries[0] = .{ .name = try gpa.dupe(u8, "review"), .description = try gpa.dupe(u8, "Review a change") };
    skillsRead(&state, read.read, .{ .entries = entries, .total = 1 }, draft);
    const shown = nextCommands(&state, draft).?;
    try std.testing.expectEqualStrings("/review", shown.list.entries[0].shown);
    // Over the drawn list, Enter picks the skill rather than starting.
    drawWithRoom(&state, draft);
    try expectLastLine(&state, draft, " enter pick · esc close");
}

test "start settings are the options session start shares with /configure" {
    const expected = [_][]const u8{ "provider", "model", "workspace", "tools", "loaded-tools", "permission-mode", "compaction-trigger", "output-reservation", "reasoning-effort", "label" };
    try std.testing.expectEqual(expected.len, start_options.len);
    for (expected, start_options) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectStyle(state: *State, row: usize, column: usize, expected: Style) !void {
    var shown: Frame = try .of(state, 80, 24, .{}, 0);
    defer shown.deinit();
    try std.testing.expectEqual(expected, shown.styleAt(row, column).?);
}

/// The status row and the rows a longer notice takes above it read
/// `expected`, as the bottom of the screen.
fn expectStatusLines(state: *State, expected: []const []const u8) !void {
    const text = try screenText(state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..std.mem.count(u8, text, "\n") + 1 - expected.len) |_| _ = lines.next();
    for (expected) |line| try std.testing.expectEqualStrings(line, lines.next().?);
}

fn expectScreenLine(state: *State, line: usize, expected: []const u8) !void {
    const text = try screenText(state, 80, 24, .{ .devanagari = true });
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
        .{ .{ .refused = .paste_overflow }, "! Paste too long; draft unchanged.", false },
        .{ .{ .refused = .edit_rejected }, "! Can't add that character alone.", false },
        .{ .{ .refused = .unbound }, "! That key does nothing here.", false },
    }) |case| {
        var state = try opened(&mixed);
        defer state.deinit();
        draft = try typeText(&state, "first");
        const effects = try step(&state, .{ .composed = .{ .input = .{ .composer = case[0] }, .draft = draft } });
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
    try writeDeparture(&state, null, &departure.writer);
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
    try expectStatusLines(&state, &.{" ! Start unsure; details on exit"});
    // The next tick lists at once, so a start that did land shows.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));
    // A second unconfirmed start keeps the first one's handle.
    const second = "9a0b1c2d-3e4f-4a6b-8c7d-0f8e2c1a7b3d";
    draft = try typeText(&state, "Fix it again");
    _ = try submit(&state, draft);
    try expectEffects(&.{.clear_draft}, try step(&state, .{ .start = .{ .unconfirmed = second } }));
    try writeDeparture(&state, null, &departure.writer);
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
    try expectScreenLine(&state, 6, "  ✓ summarize yesterday's CI failures                                       12m");
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
    try expectScreenLine(&state, 0, " रुई rui  ● 2  ◌ 1");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 0, " रुई rui  ● 2  ◌ 1 · slots 2/2");
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, " Active").?..], after[std.mem.indexOf(u8, after, " Active").?..]);
    try std.testing.expect(std.mem.indexOf(u8, after, "  ● Admitted before the restart") != null);
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

test "the selection stays on its Session when it moves from active to finished" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (0..3) |_| _ = try press(&state, .{}, .next);
    try expectSelected(&state, "e5f6g7");
    _ = try refresh(&state, .changed, testToken(2), &.{session("e5f6g7", .{ .finished = ago(0) }, .{ .label = "List unused build steps" })});
    try expectSelected(&state, "e5f6g7");
    try std.testing.expectEqual(Group.finished, state.find("e5f6g7".*).?.group());
    try expectEffects(&.{.{ .open = "e5f6g7".* }}, try submit(&state, .{}));
    // It leads the finished, newest first.
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " Finished · 8\n  ✓ List unused build steps                                                  1s\n") != null);
    // Moving on goes to the next row on screen, not the next old index.
    _ = try press(&state, .{}, .next);
    try expectSelected(&state, "m1n2p3");
    // A selected row that lands among a folded group's hidden rows opens the group.
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expect(state.unfolded.contains(.finished));
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
    try expectSelected(&state, "r4t9vw");
}

test "one click on a row opens it, under Enter's rules" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{.{ .open = "b2c3d4".* }}, try step(&state, .{ .clicked = .{ .open = "b2c3d4".* } }));
    try expectSelected(&state, "b2c3d4");
    // While Host requests wait on an Upgrade, the click selects but does
    // not open, as Enter would not.
    state.upgrade.run = .checking;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .open = "g7h8j9".* } }));
    try expectSelected(&state, "g7h8j9");
}

test "a click while a start waits changes nothing, as keys do, and the start then opens" {
    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.?;
    _ = try submit(&state, try typeText(&state, "go"));
    try std.testing.expectEqual(InputMode.frozen, state.inputMode());
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .open = "b2c3d4".* } }));
    try expectSelected(&state, &selected);
    try expectEffects(&.{ .clear_draft, .{ .open = "z9y8x7".* } }, try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } }));
}

test "a click on a folded group's more line opens it at its first hidden row" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(folded(&state, .finished));
    var line: usize = 0;
    const more = while (listItem(&state, line)) |item| : (line += 1) {
        if (item == .more) break item.more;
    } else return error.TestUnexpectedResult;
    // Seven finished rows show five, then "2 more".
    try std.testing.expectEqual(More{ .group = .finished, .hidden = 2 }, more);
    try std.testing.expectEqual(Click{ .unfold = .finished }, clickOf(&state, listItem(&state, line).?).?);
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .unfold = .finished } }));
    try std.testing.expect(!folded(&state, .finished));
    try expectSelected(&state, "v8w9x0");
    // The line is gone with the fold; a click that still names it moves
    // nothing.
    _ = try press(&state, .{}, .first);
    const first = state.selected.?;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .unfold = .finished } }));
    try expectSelected(&state, &first);
}

test "a heading, a gap and the empty list's line name nothing to click; a row names its Session" {
    var state = try opened(&mixed);
    defer state.deinit();
    var rows: usize = 0;
    var line: usize = 0;
    while (listItem(&state, line)) |item| : (line += 1) switch (item) {
        .gap, .heading, .empty => try std.testing.expectEqual(null, clickOf(&state, item)),
        .row => |at| {
            rows += 1;
            try std.testing.expectEqualStrings(&state.rows.items[state.order.items[at]].reference, &clickOf(&state, item).?.open);
        },
        .more => |more| try std.testing.expectEqual(Click{ .unfold = more.group }, clickOf(&state, item).?),
    };
    try std.testing.expect(rows > 0);
    // Still loading, and listed with nothing in the view.
    var loading = try testState();
    defer loading.deinit();
    try std.testing.expectEqual(null, clickOf(&loading, listItem(&loading, 0).?));
    var empty = try opened(&.{});
    defer empty.deinit();
    try std.testing.expectEqual(null, clickOf(&empty, listItem(&empty, 0).?));
}

test "a click that names a Session gone from the list since it was drawn changes nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.?;
    try expectEffects(&.{}, try step(&state, .{ .clicked = .{ .open = "n0n0n0".* } }));
    try expectSelected(&state, &selected);
}

test "a click on a Session while a panel shows opens it and closes the panel, as Enter does" {
    var state = try opened(&mixed);
    defer state.deinit();
    state.panel = .help;
    try expectEffects(&.{.{ .open = "b2c3d4".* }}, try step(&state, .{ .clicked = .{ .open = "b2c3d4".* } }));
    try std.testing.expectEqual(null, state.panel);
}

test "every click obeys the input mode: a frozen screen takes none, whatever it names" {
    const ref = "b2c3d4";
    for ([_]bool{ false, true }) |frozen| for ([_]Click{ .{ .open = ref.* }, .{ .unfold = .finished }, .view }) |clicked| {
        var state = try opened(&mixed);
        defer state.deinit();
        if (clicked == .view) {
            _ = try submit(&state, .{ .bytes = "/sessions archived" });
            _ = try respond(&state, .full, testToken(2), &.{});
        } else try std.testing.expect(folded(&state, .finished));
        if (frozen) {
            _ = try submit(&state, try typeText(&state, "go"));
            try std.testing.expectEqual(InputMode.frozen, state.inputMode());
        }
        const selected = state.selected;
        const effects = try step(&state, .{ .clicked = clicked });
        if (frozen) {
            // No key moves a frozen screen, and no click does.
            try expectEffects(&.{}, effects);
            try std.testing.expectEqual(selected, state.selected);
            try std.testing.expectEqual(clicked == .view, state.archive == .archived);
            if (clicked != .view) try std.testing.expect(folded(&state, .finished));
        } else switch (clicked) {
            .open => try expectEffects(&.{.{ .open = ref.* }}, effects),
            .unfold => try std.testing.expect(!folded(&state, .finished)),
            .view => {
                try expectEffects(&.{.{ .list = null }}, effects);
                try std.testing.expectEqual(ArchiveFilter.active, state.archive);
            },
        }
    };
}

test "a click on the counts line's view name returns to the default view, as /sessions does" {
    var state = try opened(&mixed);
    defer state.deinit();
    // The default view names nothing to click.
    try expectEffects(&.{}, try step(&state, .{ .clicked = .view }));
    try std.testing.expectEqual(ArchiveFilter.active, state.archive);
    _ = try submit(&state, .{ .bytes = "/sessions archived" });
    try std.testing.expectEqual(ArchiveFilter.archived, state.archive);
    _ = try respond(&state, .full, testToken(2), &.{});
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .clicked = .view }));
    try std.testing.expectEqual(ArchiveFilter.active, state.archive);
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
    var screen = try Frame.of(&state, 80, 24, .{}, 0);
    defer screen.deinit();
    try expectScreenLine(&state, 3, "  ? Review PR 412                                                            3m");
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(3, 2).?);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 1, " Needs you · 1");
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
    try std.testing.expect(std.mem.indexOf(u8, text, "  ◌ Audit permission paths                                                   0s\n") != null);
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

/// Renders `state` at 80x24 and 200x60 and compares both screens, and the
/// 80x24 screen's styles.
fn expectScreens(state: *State, caps: Caps, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    try expectScreen(state, 80, 24, caps, small);
    try expectStyles(state, 80, 24, caps, small_styles);
    try expectScreen(state, 200, 60, caps, large);
}

/// One letter per cell: `.` unstyled; `s`trong, `i`nk, `n`ormal, `q`uiet,
/// `m`ark, ru`l`e, `a`ttention, `f`ailure or `b`and colour; `r` selected or
/// reversed. Capitals are bold.
fn expectStyles(state: *State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    var shown: Frame = try .of(state, width, height, caps, 0);
    defer shown.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (0..shown.lines.len) |row| {
        const start = text.written().len;
        for (0..width) |column| {
            const style = shown.styleAt(row, column) orelse {
                try text.writer.writeByte('.');
                continue;
            };
            const letter: u8 = if (style.reverse or style.background == .selection) 'r' else switch (style.colour) {
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
            try text.writer.writeByte(if (style.bold) std.ascii.toUpper(letter) else letter);
        }
        text.shrinkRetainingCapacity(start + std.mem.trimEnd(u8, text.written()[start..], ".").len);
        try text.writer.writeByte('\n');
    }
    try std.testing.expectEqualStrings(expected, text.written());
}

fn expectBand(rows: []const Listed, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    var state = try opened(rows);
    defer state.deinit();
    try expectScreens(&state, .{}, small, small_styles, large);
    // The band spans the line, in its colour or, without colour, reversed.
    for ([_]Caps{ .{}, .{ .depth = .none } }, [_]Style{ .{ .colour = .on_band, .background = .band, .bold = true }, .{ .bold = true, .reverse = true } }) |caps, style| {
        var shown: Frame = try .of(&state, 80, 24, caps, 0);
        defer shown.deinit();
        try std.testing.expectEqual(style, shown.styleAt(1, 0).?);
        try std.testing.expectEqual(style, shown.styleAt(1, 79).?);
    }
}

test "a quota reset far in the future still draws its band" {
    var state = try opened(&.{failedRow("q1q1q1", 60, "provider_quota", 100_000_000_000_000_000)});
    defer state.deinit();
    try expectScreenLine(&state, 1, " Quota used up. Resets in 999d.");
}

test "the overview's rows draw each band" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Summarize the CI failures" });
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_sign_in_refresh_token_expired", null) },
        \\ rui  × 1
        \\ Sign-in expired. Run rui auth login codex.
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                    Sign-in expired         1m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open
    ,
        \\ssssfffffnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\.IIIIIIIIqqqq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqqqq...............................................qqq
        \\
        \\.IIIIIIIIIIIIIIIIIqqqq
        \\..f.qqqqqqqqqqqqq....................................fffffffffffffff.........qq
        \\qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  × 1
        \\ Sign-in expired. Run rui auth login codex.
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                                                                                                    Sign-in expired                                 1m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open
    );
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 20 * 60) },
        \\ rui  × 1
        \\ Quota used up. Resets in 20m.
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                    Out of quota            1m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open
    ,
        \\ssssfffffnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\.IIIIIIIIqqqq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqqqq...............................................qqq
        \\
        \\.IIIIIIIIIIIIIIIIIqqqq
        \\..f.qqqqqqqqqqqqq....................................ffffffffffff............qq
        \\qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  × 1
        \\ Quota used up. Resets in 20m.
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                                                                                                    Out of quota                                    1m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open
    );
    try expectBand(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20) },
        \\ rui  ● 2
        \\ Rate limited. 2 Sessions will retry.
        \\ Active · 2
        \\  ● Ask the model again                        Rate limited · retry in 10s   5s
        \\  ● Ask the model again                        Rate limited · retry in 20s   5s
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open · ctrl+x stop
    ,
        \\ssssnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\.IIIIIIqqqq
        \\..a.iiiiiiiiiiiiiiiiiii........................aaaaaaaaaaaaaaaaaaaaaaaaaaa...qq
        \\..a.iiiiiiiiiiiiiiiiiii........................aaaaaaaaaaaaaaaaaaaaaaaaaaa...qq
        \\qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ● 2
        \\ Rate limited. 2 Sessions will retry.
        \\ Active · 2
        \\  ● Ask the model again                                                                                                                              Rate limited · retry in 10s                     5s
        \\  ● Ask the model again                                                                                                                              Rate limited · retry in 20s                     5s
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open · ctrl+x stop
    );
}

test "the overview's rows draw an empty Store" {
    var state = try opened(&.{});
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ rui
        \\ No unarchived Sessions. /sessions archived shows the archive.
        \\ new Session · no model · ~/code/rui
        \\
    ,
        \\ssssnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
    ,
        \\ rui
        \\ No unarchived Sessions. /sessions archived shows the archive.
        \\ new Session · no model · ~/code/rui
        \\
    );
}

test "the overview's rows draw twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ rui  ? 1  ● 6  ◌ 1  × 2
        \\ Needs you · 1
        \\  ? Review PR 412                                                            3m
        \\
        \\ Yours · 2
        \\  ⠋ Fix the flaky resize test                                               40s
        \\  ✓ h8q2mz                                                                  12m
        \\
        \\ Active · 6
        \\  ● List unused build steps                          Stopping…               8s
        \\  ● Audit permission paths                   Provider error · retry in 12s  30s
        \\  ● Find why store tests fail                        Run the logic tests     1m
        \\  ● f6g7h8                             ~/code/other                          1m
        \\  ● Profile the curl send queue                                              2m
        \\  ◌ Trace Host shutdown order                                                5s
        \\
        \\ Idle · 1
        \\  ○ Check macOS socket cleanup                                               2h
        \\
        \\ Finished · 7
        \\  ✓ Explain provider output parsing                                         20m
        \\  ✓ Find the commit that broke WAL                                          45m
        \\  ✓ p3q4r5                                                                   1h
        \\  ✓ Summarize the build cache study                                          3h
        \\  ✓ Check the release notes               /srv/work                          2d
        \\   2 more
        \\
        \\ Stopped or failed · 3
        \\  × Bisect the WAL regression                      provider_output_invalid  15m
        \\  ■ Rename the session tables                                               30m
        \\  × Retry the flaky upload                           provider_http_500      50m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open · ctrl+x stop
    ,
        \\ssssaaaaannnnnnnnnnfffffnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.IIIIIIIIIqqqq
        \\..a.iiiiiiiiiiiii............................................................qq
        \\
        \\.IIIIIqqqq
        \\..i.SSSSSSSSSSSSSSSSSSSSSSSSS...............................................qqq
        \\..m.SSSSSS..................................................................qqq
        \\
        \\.IIIIIIqqqq
        \\..q.iiiiiiiiiiiiiiiiiiiiiii..........................qqqqqqqqq...............qq
        \\..a.iiiiiiiiiiiiiiiiiiiiii...................aaaaaaaaaaaaaaaaaaaaaaaaaaaaa..qqq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiii........................nnnnnnnnnnnnnnnnnnn.....qq
        \\..i.qqqqqq.............................nnnnnnnnnnnn..........................qq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiiiii..............................................qq
        \\..q.iiiiiiiiiiiiiiiiiiiiiiiii................................................qq
        \\
        \\.IIIIqqqq
        \\..n.iiiiiiiiiiiiiiiiiiiiiiiiii...............................................qq
        \\
        \\.IIIIIIIIqqqq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq.........................................qqq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq..........................................qqq
        \\..m.qqqqqq...................................................................qq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq..........................................qq
        \\..m.qqqqqqqqqqqqqqqqqqqqqqq...............nnnnnnnnn..........................qq
        \\...qqqqqq
        \\
        \\.IIIIIIIIIIIIIIIIIqqqq
        \\..f.qqqqqqqqqqqqqqqqqqqqqqqqq......................fffffffffffffffffffffff..qqq
        \\..n.qqqqqqqqqqqqqqqqqqqqqqqqq...............................................qqq
        \\..f.qqqqqqqqqqqqqqqqqqqqqq...........................fffffffffffffffff......qqq
        \\qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ rui  ? 1  ● 6  ◌ 1  × 2
        \\ Needs you · 1
        \\  ? Review PR 412                                                                                                                                                                                    3m
        \\
        \\ Yours · 2
        \\  ⠋ Fix the flaky resize test                                                                                                                                                                       40s
        \\  ✓ h8q2mz                                                                                                                                                                                          12m
        \\
        \\ Active · 6
        \\  ● List unused build steps                                                                                                                          Stopping…                                       8s
        \\  ● Audit permission paths                                                                                                                           Provider error · retry in 12s                  30s
        \\  ● Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  ● f6g7h8                                                                                                                             ~/code/other                                                  1m
        \\  ● Profile the curl send queue                                                                                                                                                                      2m
        \\  ◌ Trace Host shutdown order                                                                                                                                                                        5s
        \\
        \\ Idle · 1
        \\  ○ Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished · 7
        \\  ✓ Explain provider output parsing                                                                                                                                                                 20m
        \\  ✓ Find the commit that broke WAL                                                                                                                                                                  45m
        \\  ✓ p3q4r5                                                                                                                                                                                           1h
        \\  ✓ Summarize the build cache study                                                                                                                                                                  3h
        \\  ✓ Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed · 3
        \\  × Bisect the WAL regression                                                                                                                        provider_output_invalid                        15m
        \\  ■ Rename the session tables                                                                                                                                                                       30m
        \\  × Retry the flaky upload                                                                                                                           provider_http_500                              50m
        \\ new Session · no model · ~/code/rui
        \\ ↑↓ select · enter open · ctrl+x stop
    );
}

test "the overview's rows draw ASCII without colour" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "résumé the naïve café ☕ notes" } });
    const caps: Caps = .{ .unicode = false, .depth = .none };
    try expectScreens(&state, caps,
        \\ rui  ? 1  * 6  : 1  x 2
        \\ Needs you - 1
        \\  ? Review PR 412                                                            3m
        \\
        \\ Yours - 2
        \\  * Fix the flaky resize test                                               40s
        \\  + r?sum? the na?ve caf? ? notes                                           12m
        \\
        \\ Active - 6
        \\  * List unused build steps                          Stopping.               8s
        \\  * Audit permission paths                   Provider error - retry in 12s  30s
        \\  * Find why store tests fail                        Run the logic tests     1m
        \\  * f6g7h8                             ~/code/other                          1m
        \\  * Profile the curl send queue                                              2m
        \\  : Trace Host shutdown order                                                5s
        \\
        \\ Idle - 1
        \\  o Check macOS socket cleanup                                               2h
        \\
        \\ Finished - 7
        \\  + Explain provider output parsing                                         20m
        \\  + Find the commit that broke WAL                                          45m
        \\  + p3q4r5                                                                   1h
        \\  + Summarize the build cache study                                          3h
        \\  + Check the release notes               /srv/work                          2d
        \\   2 more
        \\
        \\ Stopped or failed - 3
        \\  x Bisect the WAL regression                      provider_output_invalid  15m
        \\  # Rename the session tables                                               30m
        \\  x Retry the flaky upload                           provider_http_500      50m
        \\ new Session - no model - ~/code/rui
        \\ ^v select - enter open - ctrl+x stop
    ,
        \\nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.NNNNNNNNNnnnn
        \\..n.nnnnnnnnnnnnn............................................................nn
        \\
        \\.NNNNNnnnn
        \\..n.NNNNNNNNNNNNNNNNNNNNNNNNN...............................................nnn
        \\..n.NNNNNNNNNNNNNNNNNNNNNNNNNNNNN...........................................nnn
        \\
        \\.NNNNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnn..........................nnnnnnnnn...............nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnn...................nnnnnnnnnnnnnnnnnnnnnnnnnnnnn..nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn........................nnnnnnnnnnnnnnnnnnn.....nn
        \\..n.nnnnnn.............................nnnnnnnnnnnn..........................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnn..............................................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn................................................nn
        \\
        \\.NNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnn...............................................nn
        \\
        \\.NNNNNNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn.........................................nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnn..........................................nnn
        \\..n.nnnnnn...................................................................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn..........................................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnn...............nnnnnnnnn..........................nn
        \\...nnnnnn
        \\
        \\.NNNNNNNNNNNNNNNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn......................nnnnnnnnnnnnnnnnnnnnnnn..nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn...............................................nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnn...........................nnnnnnnnnnnnnnnnn......nnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
    ,
        \\ rui  ? 1  * 6  : 1  x 2
        \\ Needs you - 1
        \\  ? Review PR 412                                                                                                                                                                                    3m
        \\
        \\ Yours - 2
        \\  * Fix the flaky resize test                                                                                                                                                                       40s
        \\  + r?sum? the na?ve caf? ? notes                                                                                                                                                                   12m
        \\
        \\ Active - 6
        \\  * List unused build steps                                                                                                                          Stopping.                                       8s
        \\  * Audit permission paths                                                                                                                           Provider error - retry in 12s                  30s
        \\  * Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  * f6g7h8                                                                                                                             ~/code/other                                                  1m
        \\  * Profile the curl send queue                                                                                                                                                                      2m
        \\  : Trace Host shutdown order                                                                                                                                                                        5s
        \\
        \\ Idle - 1
        \\  o Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished - 7
        \\  + Explain provider output parsing                                                                                                                                                                 20m
        \\  + Find the commit that broke WAL                                                                                                                                                                  45m
        \\  + p3q4r5                                                                                                                                                                                           1h
        \\  + Summarize the build cache study                                                                                                                                                                  3h
        \\  + Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed - 3
        \\  x Bisect the WAL regression                                                                                                                        provider_output_invalid                        15m
        \\  # Rename the session tables                                                                                                                                                                       30m
        \\  x Retry the flaky upload                                                                                                                           provider_http_500                              50m
        \\ new Session - no model - ~/code/rui
        \\ ^v select - enter open - ctrl+x stop
    );
    var screen = try Frame.of(&state, 200, 60, caps, 0);
    defer screen.deinit();
    for (screen.lines) |line| for (line) |span| {
        try std.testing.expectEqual(Colour.normal, span.style.colour);
        for (span.text) |byte| try std.testing.expect(byte < 0x80);
    };
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
        var shown: Frame = try .drafted(&state, draft, width, 24, caps, 0);
        defer shown.deinit();
        const text = try shown.text();
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, caps.width) <= width);
    };
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
    try expectScreenLine(&state, 2, "  ● Bell? and ?[31mred                                                       5s");
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
    var screen = try Frame.of(&state, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(Style{ .colour = .strong, .bold = true }, screen.styleAt(2, 4).?);
    try std.testing.expectEqual(Style{ .colour = .quiet }, screen.styleAt(5, 4).?);
}

test "the overview indexed palettes retain every colour" {
    const expected = [_]struct { skin: Skin, colours: [9]u8, backgrounds: [4]u8 }{
        .{ .skin = .day, .colours = .{ 235, 17, 239, 60, 103, 187, 94, 124, 233 }, .backgrounds = .{ 255, 253, 254, 214 } },
        .{ .skin = .night, .colours = .{ 255, 188, 249, 247, 60, 237, 214, 210, 233 }, .backgrounds = .{ 234, 235, 238, 214 } },
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

test "the top is the counts line, then the counted groups" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 7500, .slots = 100, .slots_in_use = 3 } });
    try expectScreenLine(&state, 0, " रुई rui  ? 1  ● 6  ◌ 1 · slots 3/100  × 2");
    try expectScreenLine(&state, 1, " Needs you · 1");
    // The Devanagari wordmark is indigo, while rui is strong, at equal weight.
    var shown: Frame = try .of(&state, 80, 24, .{ .devanagari = true }, 0);
    defer shown.deinit();
    try std.testing.expectEqual(Colour.ink, shown.styleAt(0, 1).?.colour);
    try std.testing.expectEqual(Colour.strong, shown.styleAt(0, 4).?.colour);
    for ([_]usize{ 1, 4 }) |column| try std.testing.expect(!shown.styleAt(0, column).?.bold);
    try std.testing.expect(!shown.styleAt(0, 10).?.bold);
    // ASCII has rui alone.
    const text = try screenText(&state, 80, 24, .{ .unicode = false });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, " rui  ? 1  * 6  : 1 - slots 3/100  x 2\n Needs you - 1\n"));
}

test "overview top stays compact through completion failure Host changes and input" {
    const Check = struct {
        fn screen(state: *State, top: []const u8, group: []const u8) !void {
            const text = try screenText(state, 80, 24, .{ .devanagari = true });
            defer std.testing.allocator.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            for ([_][]const u8{ top, group }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
            try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
        }
    };
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Finish later" }),
        session("b2c3d4", .{ .working = ago(20) }, .{ .label = "Fail later" }),
    });
    defer state.deinit();
    try Check.screen(&state, " रुई rui  ● 2", " Active · 2");
    const host: Host = .{ .started_at = test_now_s - 600, .slots = 4, .slots_in_use = 2 };
    _ = try step(&state, .{ .host = host });
    try Check.screen(&state, " रुई rui  ● 2", " Active · 2");

    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .finished = .{ .since = test_now_s + 60 } }, .{ .label = "Finish later" })});
    try Check.screen(&state, " रुई rui  ● 1", " Active · 1");

    _ = try step(&state, .{ .tick = (test_now_s + 120) * 1000 });
    _ = try respond(&state, .changed, testToken(3), &.{session("b2c3d4", .{ .failed = .{ .since = test_now_s + 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Fail later" })});
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    try expectScreenLine(&state, 4, " Stopped or failed · 1");
    try expectScreenLine(&state, 5, "  × Fail later                                     provider_output_invalid   0s");

    _ = try step(&state, .{ .host = null });
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    _ = try step(&state, .{ .host = host });
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    for ([_]u64{ test_now_s + 60, test_now_s + 120, test_now_s + 120 }) |started_at| {
        _ = try step(&state, .{ .host = .{ .started_at = started_at, .slots = 8, .slots_in_use = 0 } });
        try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    }
    _ = try step(&state, .{ .tick = (test_now_s + 121) * 1000 });
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    _ = try press(&state, .{}, .next);
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
    _ = try typeText(&state, "a task");
    try Check.screen(&state, " रुई rui  × 1", " Finished · 1");
}

test "overview compact top leaves a failed row visible in a narrow viewport" {
    var state = try opened(&.{session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Fail later" })});
    defer state.deinit();
    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .failed = .{ .since = test_now_s + 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Fail later" })});
    // One line of top, so the row is the list's second line at any height.
    const text = try screenText(&state, 40, 9, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{
        " rui  × 1",
        " Stopped or failed · 1",
        "  × Fail later                       0s",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
}

test "overview compact top preserves both alarm bands before the list" {
    var state = try opened(&.{session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Fail later" })});
    defer state.deinit();
    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .failed = .{ .since = test_now_s + 60, .code = bounded(session_work.max_code_bytes, "provider_sign_in_refresh_token_expired"), .resets_at = null } }, .{ .label = "Fail later" })});
    _ = try step(&state, .{ .tick = (test_now_s + 61) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    _ = try step(&state, .{ .tick = (test_now_s + 121) * 1000 });
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{
        " rui  × 1",
        " Host stopped 1m ago. Run rui host start.",
        " Sign-in expired. Run rui auth login codex.",
        " Stopped or failed · 1",
        "  × Fail later                                       Sign-in expired         1m",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
}

test "the Host-stopped band comes first, over the provider bands and the faded rows" {
    var state = try opened(&.{ failedRow("aaaaaa", 60, "provider_sign_in_refresh_token_expired", null), session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Profile it" }) });
    defer state.deinit();
    try expectScreenLine(&state, 1, " Sign-in expired. Run rui auth login codex.");
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    try std.testing.expectEqual(@as(?u64, (test_now_s + 1) * 1000), state.unreachable_since_ms);
    _ = try step(&state, .{ .tick = (test_now_s + 181) * 1000 });
    try expectScreenLine(&state, 1, " Host stopped 3m ago. Run rui host start.");
    try expectScreenLine(&state, 2, " Sign-in expired. Run rui auth login codex.");
    try expectStyle(&state, 1, 0, .{ .colour = .on_band, .background = .band, .bold = true });
    // The rows fade under it.
    try expectScreenLine(&state, 4, "  ● Profile it                                                               3m");
    try expectStyle(&state, 4, 4, .{ .colour = .quiet });
}

/// Answers the picker's model-list read with the menu of `lists`.
fn answerModels(state: *State, lists: []const model_list.Entry) !void {
    try expectEffects(&.{}, try step(state, .{ .models = .{ .menu = try model_picker.testMenu(lists) } }));
}

/// Types /model and answers its model-list read with `lists`.
fn openPicker(state: *State, lists: []const model_list.Entry) !void {
    test_edits +%= 1;
    const draft: Draft = .{ .bytes = "/model", .cursor = 6, .edits = test_edits };
    try expectEffects(&.{.list_models}, try step(state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = draft } }));
    try answerModels(state, lists);
}

/// An overview on a 60 by 24 screen with `default`.
fn pickerState(default: ?Default) !State {
    var state = try opened(&picker_rows);
    state.default = default;
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 24 } }));
    return state;
}

fn highlightModel(state: *State, draft: Draft, model: []const u8) !void {
    const index = state.menu.find(model) orelse return error.TestModelNotOffered;
    try expectEffects(&.{}, try step(state, .{ .picker_action = .{ .draft = draft, .action = .{ .select = index } } }));
}

// A bounded menu for navigation tests; catalog-list coverage belongs to model_list.
const chatgpt: model_list.Entry = .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-6.1-sol\ngpt-6.1-terra\ngpt-6-sol\ngpt-6-astra\ngpt-5.6-sol\ngpt-5.6-terra\ngpt-5.6-luna\ngpt-5.5\n" } } };
const both = [_]model_list.Entry{ chatgpt, .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-5.5\nunlisted-a\nunlisted-z\n" } } } };

test "/model filters and saves a model with its effort" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    const draft = try typeText(&state, "/model gpt-6-luna high");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(usize, 2), effects.len);
    try std.testing.expectEqualStrings("gpt-6-luna", effects.items[1].save_default.model.slice());
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), effects.items[1].save_default.effort);
    try std.testing.expect(state.picker == null and state.menu.entries.len == 0);
    try std.testing.expectEqualStrings("gpt-6-luna", state.default.?.model.slice());
    try std.testing.expectEqual(Provider.codex, state.default.?.provider);
}

test "/model retains selected row and effort when a pending list refreshes" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{ chatgpt, .{ .provider = .openai, .list = .pending } });
    const draft = try typeText(&state, "/model gpt-6-luna");
    _ = try step(&state, .{ .picker_action = .{ .action = .higher_effort, .draft = draft } });
    const chosen = state.picker.?.choice.?;
    const expected = chosen.row.effort;
    try answerModels(&state, &both);
    try std.testing.expectEqual(true, state.picker.?.choice != null);
    const refreshed = state.picker.?.choice.?;
    try std.testing.expectEqualStrings("gpt-6-luna", state.menu.entries[refreshed.index].id);
    try std.testing.expectEqual(expected, refreshed.row.effort);
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(expected, effects.items[1].save_default.effort);
}

test "/model keeps adjusted controls after a whitespace edit" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    var draft = try typeText(&state, "/model gpt-6-luna");
    _ = try step(&state, .{ .picker_action = .{ .action = .higher_effort, .draft = draft } });
    _ = try step(&state, .{ .picker_action = .{ .action = .next_sign_in, .draft = draft } });
    const adjusted = state.picker.?.choice.?.row;
    try std.testing.expect(adjusted.effort != null);
    try std.testing.expectEqual(Provider.openai, adjusted.provider);
    draft = try typeText(&state, "/model gpt-6-luna ");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(adjusted.effort, effects.items[1].save_default.effort);
    try std.testing.expectEqual(adjusted.provider, effects.items[1].save_default.provider);
}

test "/model explicit effort overrides an adjusted control" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    var draft = try typeText(&state, "/model gpt-6-luna");
    _ = try step(&state, .{ .picker_action = .{ .action = .higher_effort, .draft = draft } });
    _ = try step(&state, .{ .picker_action = .{ .action = .next_sign_in, .draft = draft } });
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), state.picker.?.choice.?.row.effort);
    draft = try typeText(&state, "/model gpt-6-luna high");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), effects.items[1].save_default.effort);
    try std.testing.expectEqual(Provider.openai, effects.items[1].save_default.provider);
}

test "/model explicit sign-in overrides an adjusted control" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    var draft = try typeText(&state, "/model gpt-6-luna");
    _ = try step(&state, .{ .picker_action = .{ .action = .higher_effort, .draft = draft } });
    _ = try step(&state, .{ .picker_action = .{ .action = .next_sign_in, .draft = draft } });
    draft = try typeText(&state, "/model gpt-6-luna chatgpt");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), effects.items[1].save_default.effort);
    try std.testing.expectEqual(Provider.codex, effects.items[1].save_default.provider);
}

test "with both sign-ins, one Enter saves the selected sign-in and Escape closes the picker" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "/model gpt-6-luna api");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(usize, 2), effects.len);
    try std.testing.expectEqual(Provider.openai, effects.items[1].save_default.provider);
    try std.testing.expectEqualStrings("gpt-6-luna", effects.items[1].save_default.model.slice());
    try std.testing.expect(state.picker == null);
    try openPicker(&state, &both);
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    try std.testing.expect(state.picker == null);
}

test "a model Rui does not list shows under Other models and is picked like any other" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "/model unlisted-z");
    try highlightModel(&state, draft, "unlisted-z");
    const choice = state.picker.?.choice.?;
    try std.testing.expect(!state.menu.entries[choice.index].known);
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(Provider.openai, effects.items[1].save_default.provider);
    try std.testing.expectEqualStrings("unlisted-z", effects.items[1].save_default.model.slice());
}

test "a pick remains selected before its save ends and refresh preserves its identity" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    const picked = try typeText(&state, "/model gpt-5.5");
    const effects = try submit(&state, picked);
    try std.testing.expectEqualStrings("gpt-5.5", effects.items[1].save_default.model.slice());
    const running = state.save.running.?;
    try openPicker(&state, &.{chatgpt});
    const draft = try typeText(&state, "/model");
    try std.testing.expectEqualStrings("gpt-5.5", state.menu.entries[state.picker.?.choice.?.index].id);
    try highlightModel(&state, draft, "gpt-6.1-sol");
    try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = running, .outcome = .done } } }));
    try std.testing.expectEqualStrings("gpt-6.1-sol", state.menu.entries[state.picker.?.choice.?.index].id);
    try answerModels(&state, &.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-sol\ngpt-6.1-sol\n" } } }});
    try std.testing.expectEqualStrings("gpt-6.1-sol", state.menu.entries[state.picker.?.choice.?.index].id);
    try answerModels(&state, &.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\n" } } }});
    syncPicker(&state, draft);
    try std.testing.expectEqualStrings("gpt-5.5", state.menu.entries[state.picker.?.choice.?.index].id);
}

test "a start submitted before the pick's save ends runs on the pick" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    var draft = try typeText(&state, "/model gpt-6-luna high");
    const pick_effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(usize, 2), pick_effects.len);
    try std.testing.expectEqualStrings("gpt-6-luna", pick_effects.items[1].save_default.model.slice());
    // The save is left unanswered.
    draft = try typeText(&state, "Try");
    const effects = try submit(&state, draft);
    try std.testing.expectEqual(@as(usize, 1), effects.len);
    const binding = effects.slice()[0].start.binding;
    try std.testing.expectEqualStrings("codex", binding.provider.?);
    try std.testing.expectEqualStrings("gpt-6-luna", binding.model.?);
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), effects.slice()[0].start.local_effort.?.value);
}

test "picks made during one save are saved after it, only the newest" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    const first = try submit(&state, try typeText(&state, "/model gpt-5.5"));
    try std.testing.expectEqualStrings("gpt-5.5", first.items[1].save_default.model.slice());
    const running = state.save.running.?;
    // Two more picks while it runs: neither is refused, and neither saves yet.
    for ([_][]const u8{ "gpt-6-luna", "gpt-6.1-sol" }) |model| {
        try openPicker(&state, &.{chatgpt});
        var input: [64]u8 = undefined;
        const draft = try typeText(&state, try std.fmt.bufPrint(&input, "/model {s}", .{model}));
        try expectEffects(&.{.clear_draft}, try submit(&state, draft));
        try std.testing.expectEqualStrings(model, state.default.?.model.slice());
        try std.testing.expect(state.notice == null);
    }
    // The first save ends: the newest pick is saved next, and the overview
    // does not claim the first one stands.
    const next = try step(&state, .{ .saved = .{ .ended = .{ .binding = running, .outcome = .done } } });
    try std.testing.expectEqual(@as(usize, 1), next.len);
    try std.testing.expectEqualStrings("gpt-6.1-sol", next.items[0].save_default.model.slice());
    try std.testing.expect(state.notice == null);
    try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = .done } } }));
    try std.testing.expect(state.notice == null);
}

test "every pick is saved, even of the default the overview opened on, and an untouched overview saves nothing" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try std.testing.expect(state.save.wanted == null and state.save.running == null);
    for (0..2) |_| {
        try openPicker(&state, &.{chatgpt});
        const effects = try submit(&state, try typeText(&state, "/model gpt-6-luna"));
        try std.testing.expectEqual(@as(usize, 2), effects.len);
        try std.testing.expectEqualStrings("gpt-6-luna", effects.items[1].save_default.model.slice());
        try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = .done } } }));
    }
}

test "a failed save is not retried, but picking the same model again saves it" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    const first = try submit(&state, try typeText(&state, "/model gpt-5.5"));
    try std.testing.expectEqualStrings("gpt-5.5", first.items[1].save_default.model.slice());
    try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = .{ .failed = null } } } }));
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "not saved") != null);
    try openPicker(&state, &.{chatgpt});
    const second = try submit(&state, try typeText(&state, "/model gpt-5.5"));
    try std.testing.expectEqualStrings("gpt-5.5", second.items[1].save_default.model.slice());
    try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = .done } } }));
    try std.testing.expect(state.notice == null);
}

test "the lines that name the next Session's model name the saved effort its start applies" {
    // gpt-6-luna offers max and gpt-5.5 does not. An effort /configure
    // holds, `default` included, keeps the saved one from the next start,
    // but not from launches after this overview.
    const Case = struct { model: []const u8, held: ?[]const u8 = null, saved: ?ReasoningEffort, later: []const u8 };
    const cases = [_]Case{
        .{ .model = "gpt-6-luna", .saved = .max, .later = " · max" },
        .{ .model = "gpt-6-luna", .saved = null, .later = "" },
        .{ .model = "gpt-5.5", .saved = .max, .later = "" },
        .{ .model = "gpt-6-luna", .held = "low", .saved = .max, .later = " · max" },
        .{ .model = "gpt-6-luna", .held = "default", .saved = .max, .later = " · max" },
    };
    for (cases) |case| for ([_]Saved{ .done, .{ .failed = null }, .unconfirmed }) |outcome| {
        var state = try pickerState(Default.of("codex", case.model));
        defer state.deinit();
        var line: [64]u8 = undefined;
        if (case.held) |held| try expectEffects(&.{.clear_draft}, try submit(&state, try typeText(&state, try std.fmt.bufPrint(&line, "/configure --reasoning-effort {s}", .{held}))));
        try openPicker(&state, &.{chatgpt});
        const effects = try submit(&state, try typeText(&state, try std.fmt.bufPrint(&line, "/model {s}", .{case.model})));
        try std.testing.expectEqualStrings(case.model, effects.items[1].save_default.model.slice());
        var ended: Event = .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = outcome } } };
        ended.saved.saved_effort = case.saved;
        // Each outcome but `unconfirmed` is said on screen, the one after
        // leaving on the way out.
        if (outcome == .unconfirmed) _ = try step(&state, .leave);
        try expectEffects(&.{}, try step(&state, ended));
        var expected: [160]u8 = undefined;
        switch (outcome) {
            .done => try std.testing.expect(state.notice == null),
            .failed => {
                const next = if (case.held == null) " · low" else "";
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Default not saved (check ~/.config/rui/preferences); new Sessions here still use {s}{s} · ChatGPT", .{ case.model, next }), state.notice.?.text());
            },
            .unconfirmed => {
                var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer departure.deinit();
                try writeDeparture(&state, case.saved, &departure.writer);
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "rui: New Sessions use {s}{s} · ChatGPT; durability unconfirmed, inspect ~/.config/rui/preferences.\n", .{ case.model, case.later }), departure.written());
            },
        }
    };
}

test "a loading list is read again with the next listing, and a failed read keeps the list under a note" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{.{ .provider = .openai, .list = .pending }});
    // The next listing asks for the lists again, once.
    const asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{ .{ .list = testToken(1) }, .list_models }, asked);
    try answerModels(&state, &.{.{ .provider = .openai, .list = .catalog_fallback }});
    const count = state.menu.entries.len;
    try std.testing.expect(count > 0);
    for ([_]ModelsRead{ .unanswered, .invalid }) |read| {
        try expectEffects(&.{}, try step(&state, .{ .models = read }));
        try std.testing.expectEqual(count, state.menu.entries.len);
        try std.testing.expectEqual(if (read == .unanswered) model_picker_view.Read.unanswered else .invalid, state.menu_read);
    }
}

test "picker tag columns admit ids at and beyond the 24-column cap" {
    for ([_]usize{ 24, model_capability.max_model_bytes }) |length| {
        var state = try pickerState(null);
        defer state.deinit();
        const id: [model_capability.max_model_bytes]u8 = @splat('m');
        var bytes: [model_capability.max_model_bytes + 1]u8 = undefined;
        @memcpy(bytes[0..length], id[0..length]);
        bytes[length] = '\n';
        try openPicker(&state, &.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = bytes[0 .. length + 1] } } }});
        try std.testing.expectEqual(length, state.menu.widest);
        const draft = try typeText(&state, "/model");
        try highlightModel(&state, draft, id[0..length]);
        try std.testing.expectEqualStrings(id[0..length], state.menu.entries[state.picker.?.choice.?.index].id);
    }
}

test "a long model list identifies the highlighted row for the list widget" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-6.1-sol\ngpt-6-sol\ngpt-6-astra\ngpt-5.6-sol\ngpt-5.6-terra\ngpt-5.6-luna\ngpt-5.5\no1\no2\no3\no4\n" } } }});
    const draft = try typeText(&state, "/model");
    try highlightModel(&state, draft, "o4");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try model_picker_view.rows(arena.allocator(), &state.menu, "", pickerDefaults(&state), state.picker.?.choice, 60, .unicode, true, .read);
    const selected = try rows.row(arena.allocator(), rows.selected.?);
    try std.testing.expectEqualStrings("o4", state.menu.entries[selected.model.?].id);
    try std.testing.expect(rows.count > 10);
}

test "picker retains highlighted model across narrow widths" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "/model");
    try highlightModel(&state, draft, "unlisted-z");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 10, 20, 40, 60 }) |width| {
        const rows = try model_picker_view.rows(arena.allocator(), &state.menu, "", pickerDefaults(&state), state.picker.?.choice, width, .unicode, true, .read);
        const selected = try rows.row(arena.allocator(), rows.selected.?);
        try std.testing.expectEqualStrings("unlisted-z", state.menu.entries[selected.model.?].id);
    }
}

test "Shift-Up and Shift-Down leave hidden Sessions unchanged while picking a model" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "/model");
    const chosen = state.selected.?;
    const picker_choice = state.picker.?.choice;
    try expectEffects(&.{}, try press(&state, draft, .select_next));
    try expectEffects(&.{}, try press(&state, draft, .select_previous));
    try std.testing.expectEqualSlices(u8, &chosen, &state.selected.?);
    try std.testing.expect(std.meta.eql(picker_choice, state.picker.?.choice));
}

test "with no sign-in served, the picker shows each login line instead of models" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &.{});
    const draft = try typeText(&state, "/model");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try model_picker_view.rows(arena.allocator(), &state.menu, "", pickerDefaults(&state), state.picker.?.choice, 80, .unicode, true, .read);
    var codex = false;
    var openai = false;
    for (0..rows.count) |index| {
        const row = try rows.row(arena.allocator(), index);
        codex = codex or std.mem.indexOf(u8, row.text, Provider.codex.login()) != null;
        openai = openai or std.mem.indexOf(u8, row.text, Provider.openai.login()) != null;
    }
    try std.testing.expect(codex and openai);
    try expectEffects(&.{}, try submit(&state, draft));
    try std.testing.expect(state.default == null);
}

test "a save that ends after the person left is told on the way out" {
    for ([_]Saved{ .done, .unconfirmed, .{ .failed = null } }) |saved| {
        var state = try pickerState(null);
        defer state.deinit();
        try openPicker(&state, &.{chatgpt});
        const effects = try submit(&state, try typeText(&state, "/model gpt-6-luna"));
        try std.testing.expectEqualStrings("gpt-6-luna", effects.items[1].save_default.model.slice());
        try expectEffects(&.{}, try step(&state, .leave));
        try expectEffects(&.{}, try step(&state, .{ .saved = .{ .ended = .{ .binding = state.save.running.?, .outcome = saved } } }));
        var bytes: [max_late_save_bytes]u8 = undefined;
        var departure = std.Io.Writer.fixed(&bytes);
        try writeDeparture(&state, null, &departure);
        try std.testing.expect(std.mem.indexOf(u8, departure.buffered(), "gpt-6-luna") != null);
    }
}

test "the unknown-command notice fits a 40-column screen" {
    var state = try pickerState(null);
    defer state.deinit();
    const draft = try typeText(&state, "/status");
    _ = try submit(&state, draft);
    const screen = try screenText(&state, 40, 24, .{ .unicode = true });
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, state.notice.?.text()) != null);
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

test "a picker survives a tiny screen" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 1, .height = 1 } }));
    try std.testing.expect(state.shownPicker() != null);
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 24 } }));
    try std.testing.expect(state.shownPicker() != null);
}

/// The rows the Sessions' list or a panel takes on an 80 by 24 screen.
fn listRows(state: *State, draft: Draft) ![]u8 {
    var shown: Frame = try .drafted(state, draft, 80, 24, .{}, 0);
    defer shown.deinit();
    const text = try Frame.textOf(shown.list);
    defer std.testing.allocator.free(text);
    var trimmed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer trimmed.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try trimmed.writer.print("{s}\n", .{std.mem.trimEnd(u8, line, " ")});
    return trimmed.toOwnedSlice();
}

test "/help shows the overview's keys and commands in the Sessions' rows until Esc" {
    var state = try opened(&mixed);
    defer state.deinit();
    const label = "Fix the flaky resize test";
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    _ = try submit(&state, try typeText(&state, "/configure --permission-mode ask"));
    try expectEffects(&.{.clear_draft}, try submit(&state, try typeText(&state, "/help")));
    const shown = try listRows(&state, .{});
    defer std.testing.allocator.free(shown);
    var lines = std.mem.splitScalar(u8, shown, '\n');
    const top = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, top, " Help "));
    try std.testing.expect(std.mem.endsWith(u8, top, "Esc returns"));
    try std.testing.expectEqual(@as(usize, 79), top.len);
    for ([_][]const u8{
        " Up/Down select · Shift-Up/Down always · Home/End first/last on empty draft",
        " Enter opens · Alt-A archives · Ctrl-X twice stops · Type a task to start",
        " Shift-Enter or Ctrl-J adds a line",
        " / lists commands · Up/Down choose · Tab or Enter takes it",
        " Esc/Ctrl-G closes list, panel, draft, settings · Ctrl-C/Ctrl-D leaves",
        "",
        " /archive              archive the selected Session; stop active work first",
        " /configure [OPTIONS]  hold settings for the next Session",
        " /exit                 leave; Host work continues",
        " /help                 keys and commands",
        " /model                choose the model new Sessions use",
        " /rename NAME          name the selected Session",
        " /sessions [VIEW]      view Unarchived, Archived or All Sessions",
        " /setup [OPTIONS]      future defaults",
        " /unarchive            restore the selected Session without restarting work",
        " /upgrade              check stable Rui; install restarts this Store's Host",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, shown, label) == null);
    // The line under the input says Esc closes it, over held settings or a
    // typed draft.
    try expectStatusLines(&state, &.{" start settings: --permission-mode ask · esc close"});
    const draft = try typeText(&state, "fix the build");
    const held = state.settings;
    state.settings = .{};
    const hinted = try draftLines(&state, draft, 80, 24);
    defer std.testing.allocator.free(hinted);
    state.settings = held;
    try std.testing.expect(std.mem.indexOf(u8, hinted, " enter start · esc close") != null);
    // A draft typed under it stays when Esc closes it, and so do the held
    // start settings: Esc returns to the Sessions first. (Over a shown
    // command list, Esc closes the list first.)
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.panel == null);
    try std.testing.expect(!state.settings.empty());
    const back = try listRows(&state, .{});
    defer std.testing.allocator.free(back);
    try std.testing.expect(std.mem.indexOf(u8, back, label) != null);
    // Ctrl-G closes it as Esc does.
    _ = try submit(&state, try typeText(&state, "/help"));
    try expectEffects(&.{}, try press(&state, .{}, .clear));
    try std.testing.expect(state.panel == null);
    try std.testing.expect(!state.settings.empty());
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
        if (action != .stop) try std.testing.expect(!std.mem.eql(u8, &first, &state.selected.?));
    }
    // Enter on an empty draft opens the selected Session from under it.
    _ = try submit(&state, try typeText(&state, "/help"));
    try expectEffects(&.{.{ .open = state.selected.? }}, try submit(&state, .{}));
    try std.testing.expect(state.panel == null);
}

test "/help says when the screen is too small for it, and a screen that shrinks under it counts the lines it hides" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 12 } }));
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/help")));
    try std.testing.expect(state.panel == null);
    try expectNotice(&state, "! Screen too small for /help");
    try std.testing.expectEqual(Colour.attention, state.notice.?.colour);
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    _ = try submit(&state, try typeText(&state, "/help"));
    const text = try draftLines(&state, .{}, 80, 12);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " Help ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/setup [OPTIONS]") == null);
}

/// The answer to the command in flight.
fn ranWith(state: *State, ran: Ran) !void {
    try expectEffects(&.{}, try step(state, .{ .ran = ran }));
}

test "/rename names the selected Session through the shell, as a conversation does, one command at a time" {
    var empty = try opened(&.{});
    defer empty.deinit();
    try expectEffects(&.{}, try submit(&empty, try typeText(&empty, "/rename lane four")));
    try expectNotice(&empty, "! Select a Session first.");
    try std.testing.expectEqual(Colour.attention, empty.notice.?.colour);
    try expectEffects(&.{}, try press(&empty, .{}, .stop));
    try expectNotice(&empty, "! Select a Session first.");

    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.?;
    var line = "/rename lane four".*;
    try expectEffects(&.{ .clear_draft, .{ .command = .{ .name = .rename, .session = selected, .text = &line } } }, try submit(&state, try typeText(&state, &line)));
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/rename ")));
    try expectNotice(&state, "! Usage: /rename NAME");
    // One runs at a time, and the Session it names does not open under it.
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/setup")));
    try expectNotice(&state, "! Wait for /rename to finish.");
    try expectEffects(&.{}, try submit(&state, .{}));
    try expectNotice(&state, "! Wait for /rename to finish.");
    // Its line is a notice, as in a conversation, and the next listing,
    // which shows the new label, goes at once.
    try ranWith(&state, .{ .output = "Rui: Configured.\n" });
    try expectNotice(&state, "Configured.");
    try std.testing.expectEqual(Colour.quiet, state.notice.?.colour);
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms }));
    _ = try respond(&state, .full, testToken(2), &mixed);
    for ([_]struct { Ran, []const u8, Colour }{
        .{ .{ .output = "rui: no session k7m2qx in this Store\n" }, "! no session k7m2qx in this Store", .attention },
        .{ .{ .output = "" }, slash_commands.no_output, .quiet },
        .{ .{ .output = "", .outcome = .not_run }, "! /rename unavailable.", .attention },
        // Two lines are a notice too, as in a conversation.
        .{ .{ .output = "Rui: Configured.\nrui: label saved locally only\n" }, "Configured.\n! label saved locally only", .quiet },
    }) |case| {
        _ = try submit(&state, try typeText(&state, "/rename x"));
        try ranWith(&state, case[0]);
        try expectNotice(&state, case[1]);
        try std.testing.expectEqual(case[2], state.notice.?.colour);
    }
    // Both lines show under the input.
    try expectStatusLines(&state, &.{ " Configured.", " ! label saved locally only" });
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

test "/setup needs no Session, and output of more than a line takes the Sessions' rows until Esc" {
    var state = try opened(&.{});
    defer state.deinit();
    var line = "/setup --notifications off".*;
    try expectEffects(&.{ .clear_draft, .{ .command = .{ .name = .setup, .text = &line } } }, try submit(&state, try typeText(&state, &line)));
    try ranWith(&state, .{ .output = "Saved defaults for future Sessions.\nStore: /s (saved)\nNotifications: off\n" });
    try expectNotice(&state, null);
    const shown = try listRows(&state, .{});
    defer std.testing.allocator.free(shown);
    try expectLines(shown, 1, &.{ " Saved defaults for future Sessions.", " Store: /s (saved)", " Notifications: off", "" });
    try std.testing.expect(std.mem.startsWith(u8, shown, " /setup "));
    try expectEffects(&.{}, try press(&state, .{}, .clear));
    try std.testing.expect(state.panel == null);
    // Output past what the overview keeps says it was cut.
    _ = try submit(&state, try typeText(&state, "/setup"));
    try ranWith(&state, .{ .output = "Defaults (read only):", .cut = true });
    const cut = try listRows(&state, .{});
    defer std.testing.allocator.free(cut);
    try expectLines(cut, 1, &.{ " Defaults (read only):", " Output cut at 8 KiB." });
    // Typing "/" lists /setup's options as a conversation does.
    _ = try typeText(&state, "/setup ");
    try std.testing.expectEqualStrings("--model ", state.commands.?.list.shown()[0].word);
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

test "upgrade emits only its local effect and preserves selection settings and unresolved handles" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    const selected = state.selected;
    const configured = try typeText(&state, "/configure --permission-mode ask");
    _ = try submit(&state, configured);
    const settings = state.settings;
    try std.testing.expect(state.request(.stop, selected));
    state.answer(0, .unknown, "01234567-89ab-4cde-8012-0123456789ab");
    const request = state.requests[0];
    const draft = try typeText(&state, "/upgrade");
    try expectEffects(&.{}, try submit(&state, draft));
    try std.testing.expectEqual(selected, state.selected);
    try std.testing.expect(std.meta.eql(settings, state.settings));
    try std.testing.expectEqual(@as(usize, 1), state.request_count);
    try std.testing.expect(std.meta.eql(request, state.requests[0]));
    try std.testing.expectEqualStrings("/upgrade", draft.bytes);
    try std.testing.expect(state.command == null);
}

test "/upgrade runs inline: Esc cancels it before the draft, checking or preparing, and its end sets the Host hold" {
    var state = try opened(&.{});
    defer state.deinit();
    var buffer: [upgrade_status.max_line_bytes]u8 = undefined;
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try std.testing.expectEqualStrings("Checking for updates…", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    // Esc cancels the check too, keeping the draft, even while the draft
    // is still `/upgrade` and lists its command: the status row says esc
    // cancels.
    const typed = try typeText(&state, "/upgrade");
    try std.testing.expect(shownCommands(&state, typed) != null);
    try expectEffects(&.{.cancel_upgrade}, try press(&state, typed, .clear));
    const draft = try typeText(&state, "keep me");
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } });
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", state.notice.?.text());
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .none } } } });
    // Esc cancels the Upgrade and keeps the draft.
    try expectEffects(&.{.cancel_upgrade}, try press(&state, draft, .clear));
    // The worker says whether the stop held; until then the line stands.
    try std.testing.expectEqualStrings("Upgrading to 0.60.0 · no Host running · esc cancels", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .cancelling });
    // A second Esc is still the Upgrade's while it winds down.
    try expectEffects(&.{.cancel_upgrade}, try press(&state, draft, .clear));
    try std.testing.expectEqualStrings("Cancelling…", upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } });
    try std.testing.expectEqual(session_upgrade.After.reobserving, state.upgrade.after);
    // Once it ended, Esc clears the draft again.
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));

    // Past publishing Esc is the draft's, and an incompatible end holds.
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 61, .patch = 0 }, .host = .{ .running = 1 } }, .step = .publishing } } });
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);
    try std.testing.expectEqual(upgrade_status.Lasts.persistent, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).lasts);

    // A retry that installs nothing keeps the hold unless the job found
    // the Host it left usable, though both say up to date.
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 61, .patch = 0 } }, .outcome = .unchanged } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 61, .patch = 0 } }, .outcome = .compatible } } });
    try std.testing.expect(state.upgrade.after == .reobserving);

    // Another /upgrade that upgrades lifts the hold until the next listing.
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 61, .patch = 1 }, .host = .{ .running = 0 } } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 61, .patch = 1 }, .restarted = true } }, .outcome = .compatible } } });
    try std.testing.expect(state.upgrade.after == .reobserving);
}

test "every place an Upgrade run can stand decides the hold, Esc and another /upgrade from that one value" {
    const found: upgrade_status.Found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 2 } };
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
        .{ .run = .{ .ended = .{ .how = .{ .incompatible = found.version }, .outcome = .incompatible } }, .going = false, .escape = false },
    };
    for (cases) |case| {
        var state = try opened(&.{});
        defer state.deinit();
        state.upgrade.run = case.run;
        // With nothing left held by an earlier run, the run alone holds
        // Host intents.
        try std.testing.expectEqual(case.going, state.upgrading());
        try std.testing.expectEqual(case.going, state.holdsHost());
        // Esc is the run's exactly while it can still change nothing.
        const draft = try typeText(&state, "keep me");
        try expectEffects(if (case.escape) &.{.cancel_upgrade} else &.{.clear_draft}, try press(&state, draft, .clear));
        try std.testing.expectEqual(case.run, state.upgrade.run);
        // Another /upgrade starts a check only when none is going.
        try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
        if (case.going) try std.testing.expectEqual(case.run, state.upgrade.run) else try std.testing.expect(state.upgrade.run.? == .checking);
        try std.testing.expect(state.holdsHost());
    }
}

test "another /upgrade while one runs changes nothing: its progress and Esc stay" {
    var state = try opened(&.{});
    defer state.deinit();
    var buffer: [upgrade_status.max_line_bytes]u8 = undefined;
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .none } } } });
    const preparing = try std.testing.allocator.dupe(u8, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    defer std.testing.allocator.free(preparing);
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try std.testing.expectEqualStrings(preparing, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .none }, .step = .publishing } } });
    const publishing = try std.testing.allocator.dupe(u8, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    defer std.testing.allocator.free(publishing);
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try std.testing.expectEqualStrings(publishing, upgrade_status.line(state.upgrade.run.?, &buffer, .unicode).text);
    // Past publishing Esc is still the draft's: nothing cancels.
    try expectEffects(&.{.clear_draft}, try press(&state, try typeText(&state, "x"), .clear));
}

test "the status bar says the Upgrade at work, else the newest notice, else an Upgrade that holds, else an unconfirmed send" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(10) }, .{})});
    defer state.deinit();
    var buffer: StatusBuffer = undefined;
    try std.testing.expectEqual(null, statusLine(&state, .{}, &buffer));
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    _ = try step(&state, .{ .unconfirmed = .{ .reference = "k7m2qx".*, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    try expectStatus(&state, "Checking for updates…", .normal);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .none } } } });
    try expectStatus(&state, "Upgrading to 0.60.0 · no Host running · esc cancels", .normal);
    // A notice never hides the run's line, where Esc is offered.
    state.say(.attention, "! Select a Session first.", .{});
    try expectStatus(&state, "Upgrading to 0.60.0 · no Host running · esc cancels", .normal);
    _ = try press(&state, .{}, .next);
    // An ending that is news is a notice: it goes with the next key and
    // the unconfirmed send shows again.
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 0 }, .restarted = false } }, .outcome = .compatible } } });
    try expectStatus(&state, "Upgraded to 0.60.0", .normal);
    _ = try press(&state, .{}, .next);
    try expectStatus(&state, "! Not confirmed · rui request recover " ++ key, .attention);
    // A release this client cannot use stays until another /upgrade.
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 61, .patch = 0 }, .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    _ = try press(&state, .{}, .next);
    try expectStatus(&state, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention);
    // ASCII spells the line's dots.
    var ascii: StatusBuffer = undefined;
    try std.testing.expectEqualStrings("Rui 0.61.0 installed - restart rui to continue - your draft is kept until you leave", statusLine(&state, .{ .unicode = false }, &ascii).?.text);
}

test "the status row under the input says the status bar's line" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(10) }, .{})});
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    _ = try step(&state, .{ .unconfirmed = .{ .reference = "k7m2qx".*, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
    const unconfirmed = try segmentText(arena.allocator(), try statusSegments(arena.allocator(), &state, .{}, 120, .{}));
    try std.testing.expect(std.mem.startsWith(u8, unconfirmed, " ! Not confirmed · rui request recover " ++ key));
    _ = try submit(&state, try typeText(&state, "/upgrade"));
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .none } } } });
    const upgrading = try segmentText(arena.allocator(), try statusSegments(arena.allocator(), &state, .{}, 120, .{ .unicode = false }));
    try std.testing.expect(std.mem.startsWith(u8, upgrading, " Upgrading to 0.60.0 - no Host running - esc cancels"));
}

test "/upgrade is never refused as a Host request: the status bar shows its run at first, while it runs and after a hold" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try expectStatus(&state, "Checking for updates…", .normal);
    // Enter again while it runs starts nothing and hides nothing.
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try expectStatus(&state, "Checking for updates…", .normal);
    _ = try step(&state, .{ .upgrade = .{ .installing = .{ .found = .{ .version = .{ .schema = 61, .patch = 0 }, .host = .none } } } });
    _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } } });
    try std.testing.expectEqual(session_upgrade.After.blocked, state.upgrade.after);
    // A Host request is refused in words; the retry shows its own progress.
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "start this")));
    try expectStatus(&state, upgrade_recovery, .attention);
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try expectStatus(&state, "Checking for updates…", .normal);
}

fn expectStatus(state: *const State, text: []const u8, colour: Colour) !void {
    var buffer: StatusBuffer = undefined;
    const line = statusLine(state, .{}, &buffer).?;
    try std.testing.expectEqualStrings(text, line.text);
    try std.testing.expectEqual(colour, line.colour);
}

test "the counts line says where its view name sits, for a click" {
    var state = try opened(&mixed);
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, (try countsLine(arena.allocator(), &state, 100, .{ .unicode = false })).view);
    state.archive = .archived;
    state.memory = .{ .rui = 42 * mib, .tools = null };
    for ([_]u16{ 100, 40 }) |width| {
        const line = try countsLine(arena.allocator(), &state, width, .{ .unicode = false });
        const text = try segmentText(arena.allocator(), line.segments);
        const view = line.view.?;
        // ASCII text, so a column is a byte.
        try std.testing.expectEqualStrings("Archived", text[view.start..view.end]);
        try std.testing.expectEqual(@as(u16, width - 1), view.end);
    }
    // Too narrow for the name: nothing to click.
    try std.testing.expectEqual(null, (try countsLine(arena.allocator(), &state, 12, .{ .unicode = false })).view);
}

fn segmentText(arena: Allocator, segments: []const Segment) ![]const u8 {
    var texts = try arena.alloc([]const u8, segments.len);
    for (segments, 0..) |segment, n| texts[n] = segment.text;
    return std.mem.concat(arena, u8, texts);
}

test "upgrade protocol hold refuses starts opens stops and Host commands but permits local recovery" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    state.upgrade.after = .blocked;
    const selected = state.selected;
    for ([_][]const u8{ "new model work", "", "/rename new name", "/setup --model gpt-5.5" }) |text| {
        try expectEffects(&.{}, try submit(&state, try typeText(&state, text)));
        try std.testing.expectEqual(selected, state.selected);
        try std.testing.expectEqual(@as(usize, 0), state.request_count);
        try std.testing.expectEqualStrings(upgrade_recovery, state.notice.?.text());
    }
    try expectEffects(&.{}, try press(&state, try typeText(&state, "draft"), .stop));
    try std.testing.expectEqual(@as(usize, 0), state.request_count);
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
    try expectEffects(&.{.exit}, try submit(&state, try typeText(&state, "/exit")));
}

test "archive views remove changed rows outside the server filter and select the nearest Session" {
    const a = session("aaaaaa", .{ .finished = ago(1) }, .{ .label = "first" });
    var b = session("bbbbbb", .{ .finished = ago(2) }, .{ .label = "second" });
    const c = session("cccccc", .{ .finished = ago(3) }, .{ .label = "third" });
    var state = try opened(&.{ a, b, c });
    defer state.deinit();
    try std.testing.expectEqual(ArchiveFilter.active, state.archive);
    state.selected = b.reference;
    b.archive_state = .archived;
    _ = try refresh(&state, .changed, testToken(2), &.{b});
    try std.testing.expectEqual(@as(usize, 2), state.rows.items.len);
    try std.testing.expect(state.find(b.reference) == null);
    try std.testing.expectEqualStrings(&c.reference, &state.selected.?);
    var effects: Effects = .{};
    try enter(&state, "/sessions archived", &effects);
    try std.testing.expectEqual(ArchiveFilter.archived, state.listing_archive.?);
    try std.testing.expect(state.token == null);
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    _ = try respond(&state, .full, testToken(3), &.{ a, b });
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Archived") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Archived] second") != null);
    b.archive_state = .active;
    _ = try refresh(&state, .changed, testToken(4), &.{b});
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.selected == null);
}

test "archive filter switch clears hidden data and discards every stale traversal page" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "private active title" });
    const archived = session("bbbbbb", .{ .stopped = .{ .since = test_now_s - 1, .cause = .stop } }, .{ .label = "saved title", .archive_state = .archived });
    var state = try opened(&.{row});
    defer state.deinit();
    _ = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    var effects: Effects = .{};
    try enter(&state, "/sessions archived", &effects);
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
    try enter(&state, "/sessions all", &effects);
    _ = try respond(&state, .full, testToken(4), &.{ row, archived });
    try std.testing.expectEqual(@as(usize, 2), state.rows.items.len);
}

test "a busy Session archives at once, asking nothing, and never hides before settled server state" {
    var row = session("aaaaaa", .{ .working = ago(1) }, .{ .label = "busy" });
    var state = try opened(&.{row});
    defer state.deinit();
    var effects: Effects = .{};
    try enter(&state, "/archive", &effects);
    try expectEffects(&.{ .clear_draft, .{ .archive = .{ .reference = row.reference } } }, effects);
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
    try std.testing.expect(std.mem.indexOf(u8, settling, "Stopping and archiving") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    row.archive_state = .archived;
    row.state = .{ .stopped = .{ .since = test_now_s, .cause = .stop } };
    _ = try refresh(&state, .changed, testToken(3), &.{row});
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expectEqualStrings("Archived aaaaaa.", state.notice.?.text());
    // /undo is gone; /unarchive restores from the archived view.
    effects = .{};
    try enter(&state, "/undo", &effects);
    try std.testing.expect(effects.len == 0 or effects.slice()[0] != .archive);
}

test "archive failure and unconfirmed requests stay visible and surface recoverable errors" {
    const row = session("aaaaaa", .{ .idle = ago(1) }, .{ .label = "kept" });
    var state = try opened(&.{row});
    defer state.deinit();
    var effects: Effects = .{};
    try enter(&state, "/archive", &effects);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    _ = try step(&state, .{ .archive = .{ .request = .{ .reference = row.reference }, .outcome = .{ .failed = "archive_pending" } } });
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "not archived: archive_pending") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    effects = .{};
    try enter(&state, "/archive", &effects);
    _ = try step(&state, .{ .archive = .{ .request = .{ .reference = row.reference }, .outcome = .{ .unconfirmed = "saved-handle" } } });
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "recover saved-handle") != null);
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    effects = .{};
    try enter(&state, "/archive", &effects);
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
    try enter(&state, "/sessions archived", &effects);
    try enter(&state, "/sessions unarchived", &effects);
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
    try enter(&state, "/sessions archived", &effects);
    try enter(&state, "/sessions unarchived", &effects);
    try expectEffects(&.{.{ .list = null }}, try respond(&state, .not_modified, testToken(1), &.{}));
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.token == null);
    _ = try respond(&state, .full, testToken(2), &.{row});
    try std.testing.expect(state.find(row.reference) != null);
    try std.testing.expectEqual(testToken(2), state.token.?);
}

test "Alt-A archives the selected row at once, busy or not, and keeps the draft" {
    const a = session("aaaaaa", .{ .working = ago(1) }, .{});
    const b = session("bbbbbb", .{ .idle = ago(2) }, .{});
    const draft: Draft = .{ .bytes = "/rename unfinished", .cursor = 4, .edits = 17 };
    for ([_]Reference{ a.reference, b.reference }) |ref| {
        var state = try opened(&.{ a, b });
        defer state.deinit();
        state.selected = ref;
        try expectEffects(&.{.{ .archive = .{ .reference = ref } }}, try step(&state, .{ .composed = .{ .draft = draft, .input = .{ .composer = .{ .action = .archive } } } }));
        try std.testing.expectEqual(ArchiveState.active, state.find(ref).?.archive_state);
        _ = try step(&state, .{ .archive = .{ .request = .{ .reference = ref }, .outcome = .{ .failed = "archive_pending" } } });
        try std.testing.expect(state.find(ref) != null);
    }
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
        try std.testing.expect(state.notice != null);
        try std.testing.expectEqual(@as(usize, 0), state.request_count);
    }
}

test "upgrade holds admit no archive surface before draft or ledger mutation" {
    const ref = "aaaaaa".*;
    const draft: Draft = .{ .bytes = "/rename unfinished", .cursor = 4, .anchor = 1, .edits = 17 };
    for ([_]bool{ false, true }) |blocked| {
        for ([_]bool{ false, true }) |busy| {
            for ([_]ArchiveState{ .active, .archiving, .archived }) |archive| {
                const work: Kind = if (busy) .working else .idle;
                var row = session(&ref, if (busy) .{ .working = ago(1) } else .{ .idle = ago(1) }, .{});
                row.archive_state = archive;
                const cases = [_]struct { event: Event }{
                    .{ .event = .{ .composed = .{ .draft = draft, .input = .{ .composer = .{ .action = .archive } } } } },
                    .{ .event = .{ .composed = .{ .draft = .{ .bytes = "/archive", .cursor = 3, .edits = 18 }, .input = .{ .composer = .submit } } } },
                    .{ .event = .{ .composed = .{ .draft = .{ .bytes = "/unarchive", .cursor = 3, .edits = 19 }, .input = .{ .composer = .submit } } } },
                    .{ .event = .{ .conversed = .{ .reference = "k7m2qx".*, .work = work, .input = .{ .archive = archive } } } },
                    .{ .event = .{ .conversed = .{ .reference = "k7m2qx".*, .work = work, .input = .unarchive } } },
                };
                for (cases) |case| {
                    var state = try testState();
                    defer state.deinit();
                    // Set the server view before its first listing: opened's
                    // default active view correctly excludes archived rows.
                    state.archive = .all;
                    _ = try step(&state, .{ .tick = test_now_s * 1000 });
                    _ = try respond(&state, .full, testToken(1), &.{row});
                    try std.testing.expectEqual(@as(?Reference, ref), state.selected);
                    state.upgrade.after = if (blocked) .blocked else .reobserving;
                    state.last_archived = "bbbbbb".*;
                    state.panel = .help;
                    // Preserve both an unknown handle and accepted in-flight work.
                    try std.testing.expect(state.request(.stop, "zzzzzz".*));
                    state.answer(0, .unknown, "01234567-89ab-4cde-8012-0123456789ab");
                    try std.testing.expect(state.request(.archive, "yyyyyy".*));
                    const unknown = state.requests[0];
                    const pending = state.requests[1];
                    // Exercise the drawn command-list Enter as well as direct
                    // shortcut/confirmation routing. No effect may consume,
                    // append to or otherwise replace the shell-owned draft.
                    if (case.event == .composed) drawWithRoom(&state, case.event.composed.draft);
                    try expectEffects(&.{}, try step(&state, case.event));
                    try std.testing.expectEqual(@as(usize, 2), state.request_count);
                    try std.testing.expectEqual(unknown, state.requests[0]);
                    try std.testing.expectEqual(pending, state.requests[1]);
                    try std.testing.expectEqualStrings("bbbbbb", &state.last_archived.?);
                    try std.testing.expectEqualStrings(&ref, &state.selected.?);
                    try std.testing.expectEqual(archive, state.find(ref).?.archive_state);
                    try std.testing.expect(state.panel != null and state.panel.? == .help);
                    try std.testing.expect(state.command == null);
                    try std.testing.expectEqualStrings(upgrade_recovery, state.notice.?.text());
                }
            }
        }
    }
}

test "upgrade holds share stop admission for both screens, and the stop goes once they clear" {
    const ref = "aaaaaa".*;
    const draft: Draft = .{ .bytes = "unfinished draft", .cursor = 4, .edits = 71 };
    const events = [_]Event{
        .{ .composed = .{ .draft = draft, .input = .{ .composer = .{ .action = .stop } } } },
        .{ .conversed = .{ .reference = ref, .work = .working, .input = .stop } },
    };
    for ([_]bool{ false, true }) |blocked| {
        for (events) |event| {
            var state = try opened(&.{session(&ref, .{ .working = ago(1) }, .{})});
            defer state.deinit();
            state.upgrade.after = if (blocked) .blocked else .reobserving;
            state.panel = .help;
            try expectEffects(&.{}, try step(&state, event));
            try std.testing.expectEqual(@as(usize, 0), state.request_count);
            try std.testing.expect(state.panel != null and state.panel.? == .help);
            try std.testing.expectEqualStrings(upgrade_recovery, state.notice.?.text());
            state.upgrade.after = .open;
            try expectEffects(&.{.{ .stop = ref }}, try step(&state, event));
        }
    }
}

test "upgrade holds refuse archive until admitted and allow local draft recovery" {
    const ref = "aaaaaa".*;
    const draft: Draft = .{ .bytes = "/rename unfinished", .cursor = 4, .edits = 31 };
    for ([_]bool{ false, true }) |blocked| {
        var state = try opened(&.{session(&ref, .{ .working = ago(1) }, .{})});
        defer state.deinit();
        state.upgrade.after = if (blocked) .blocked else .reobserving;
        try expectEffects(&.{}, try press(&state, draft, .archive));
        try std.testing.expectEqual(@as(usize, 0), state.request_count);
        // Edits stay local; existing local exit and recovery commands still
        // bypass the hold.
        try expectEffects(&.{}, try step(&state, .{ .composed = .{ .draft = draft, .input = .{ .composer = .redraw } } }));
        try expectEffects(&.{.exit}, try submit(&state, try typeText(&state, "/exit")));
        try expectEffects(&.{}, try submit(&state, try typeText(&state, "/upgrade")));
        try std.testing.expect(state.upgrading());
        // That run ends having changed nothing, and the overview lists again.
        try expectEffects(&.{}, try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } }));
        state.upgrade.after = .open;
        try expectEffects(&.{.{ .archive = .{ .reference = ref } }}, try press(&state, draft, .archive));
        try std.testing.expectEqual(@as(usize, 1), state.request_count);
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
                if (outcome == .requested and archived) try std.testing.expectEqual(@as(?Reference, ref), state.last_archived);
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
        _ = try submit(&state, try typeText(&state, "/upgrade"));
        _ = try step(&state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = outcome } } });
        try std.testing.expect(state.upgrade.after == after and state.next_list_ms == 0);
    }
}

test "the one-pick model flow leaves typing with the composer" {
    var state = try opened(&.{});
    defer state.deinit();
    try std.testing.expectEqual(Route.edit, state.route(.enter));
    try std.testing.expectEqual(Route.edit, state.route(.{ .action = .previous }));
    var picked = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer picked.deinit();
    try openPicker(&picked, &both);
    _ = try typeText(&picked, "/model");
    try std.testing.expectEqual(Route.edit, picked.route(.enter));
    try std.testing.expectEqual(Route.edit, picked.route(.left));
    try std.testing.expectEqual(Route.edit, picked.route(.right));
    try std.testing.expectEqual(Route.edit, picked.route(.text));
}

test "while a start waits the composer is frozen" {
    var state = try opened(&.{});
    defer state.deinit();
    try expectEffects(&.{.{ .start = .{ .settings = &state.settings, .text = "go", .binding = state.nextBinding() } }}, try submit(&state, try typeText(&state, "go")));
    try std.testing.expectEqual(InputMode.frozen, state.inputMode());
    try std.testing.expectEqual(Route.frozen, state.route(.{ .action = .previous }));
    try std.testing.expectEqual(Route.frozen, state.route(.text));
    try std.testing.expectEqual(Route.frozen, state.route(.enter));
}

test "a command's output is cut at what the overview keeps, and its failure ends the overview only once its output was kept" {
    var kept: [max_output_bytes + 1]u8 = @splat('x');
    const whole = Ran.of(&kept, 5, true, true);
    try std.testing.expectEqual(@as(usize, 5), whole.output.len);
    try std.testing.expect(!whole.cut and whole.outcome == .done and whole.default == null);
    const full = Ran.of(&kept, max_output_bytes, true, false);
    try std.testing.expect(full.output.len == max_output_bytes and !full.cut);
    const cut = Ran.of(&kept, max_output_bytes + 1, true, true);
    try std.testing.expect(cut.output.len == max_output_bytes and cut.cut);
    try std.testing.expectEqual(.failed, Ran.of(&kept, 0, false, true).outcome);
    try std.testing.expectEqual(.not_run, Ran.of(&kept, 0, false, false).outcome);
    // Only a /setup that ran reads the saved defaults again.
    try std.testing.expect(whole.readsDefault(.setup));
    try std.testing.expect(!whole.readsDefault(.rename));
    try std.testing.expect(!Ran.of(&kept, 0, false, true).readsDefault(.setup));
    try std.testing.expect(!Ran.of(&kept, 0, false, false).readsDefault(.setup));
}
