//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const AppScreen = @import("AppScreen.zig");
const InputArea = @import("InputArea.zig");
const Transcript = @import("Transcript.zig");
const Root = @import("Root.zig");
const ActionConsent = @import("ActionConsent.zig");
const PermissionCard = @import("PermissionCard.zig");
const Palette = @import("Palette.zig");
const SessionChrome = @import("SessionChrome.zig");
const FactsRow = @import("FactsRow.zig");
const viewport = @import("ConversationViewport.zig");
const style = @import("widget_style.zig");
const session_chrome = @import("session_chrome.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const activity_reply = @import("activity_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const original_state = @import("submission_state.zig");
const Task = @import("ClientTask.zig");
const Screen = @import("SessionScreen.zig");
const Editor = @import("TerminalEditor.zig");
const keymap = @import("keymap.zig");
const overview_view = @import("overview_view.zig");
const test_poll = @import("test_poll");
const View = @import("session_view.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const reader_policy = @import("session_reading.zig");
const session_notice = @import("session_notice.zig");
const session_id = @import("session_id.zig");
const session_keys = @import("session_keys.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const session_upgrade = @import("session_upgrade.zig");
const Self = @This();
const empty_app_text: vxfw.Text = .{ .text = "" };

const reads = @import("session_reads.zig");
const session_line = @import("session_line.zig");
const slash_commands_shared = @import("slash_commands.zig");
const skill_completion = @import("skill_completion.zig");
const skill_suggestions = @import("skill_suggestions.zig");
const slash_commands = slash_commands_shared.conversation;
const model_capability = @import("model_capability.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const status_page = @import("status_page.zig");
const preferences = @import("preferences.zig");
pub const Command = reads.Command;
pub const Requests = reads.Requests;
pub const Status = reads.Status;
const Job = reads.Job;
pub const Files = reads.Files;
const Inspection = reads.Inspection;
const ReadPhase = departure.ReadPhase;
const ReadEnd = departure.ReadEnd;
const AdmissionEnd = Submission.End;
const Settled = departure.Settled;
init: std.process.Init,
/// The process's borrowed HOME, empty without one; used for answer links
/// and the /status page's `~` paths.
home: []const u8 = "",
store: []const u8,
session: []const u8,
directory: []const u8,
files: Files,
command: Command,
requests: Requests = undefined,
status: Status = undefined,
screen: *Screen = undefined,
// `begin` points it at the live Document. Shared paths such as `idleReader`
// ask whether it drags, so until then it holds no press or drag.
app_content: Transcript = .{ .document = undefined },
app_input: InputArea = undefined,
app_screen: AppScreen.Session = undefined,
app_preview: Transcript = undefined,
app_consent: ActionConsent = .{},
app_card: PermissionCard = undefined,
app_palette: Palette = undefined,
app_hooks: AppHooks = undefined,
app_caps: overview_view.Caps = .{},
/// Stops when the caller is signalled; a running command stops with it.
interrupted: *client.Cancellation = undefined,
/// The overview this Session belongs to; a frame drawn without one says nothing.
lender: Lender = quiet_overview,
colour: bool,
input: Input = undefined,
submission: Submission = undefined,
/// What the latest /requests page offers to act on, which its list shows
/// while the page does.
saved_requests: reads.SavedRequests = .{},
/// The /recover row's line for the original, written each time the rows
/// are listed.
recover_line: [slash_commands_shared.recover_line_bytes]u8 = undefined,
reader: Task = .{},
/// The composer's skill suggestions reads and the rows they list. One read
/// runs at a time on `skill_task`, apart from the reader, whose only
/// context is `skill_job`.
skills: skill_completion.Reads = .{},
skill_rows: skill_completion.Rows = .{},
skill_task: Task = .{},
skill_job: SkillJob = .{},
/// Reads the Session's skills whose names start a prefix; tests substitute it.
skill_read: SkillRead = clientSkills,
/// This conversation's reading of the Session predates an Upgrade's run:
/// Host requests wait until a read settles. The Upgrade itself is the
/// lender's value.
upgrade_stale: bool = false,
// The reader's only context; the UI reads its result after join.
job: Job = .{},
// When the next live read may start.
poll_at: i96 = 0,
// The reader's phase and what its result left for the UI.
reading: struct {
    phase: ReadPhase = .activity,
    opening: bool = true,
    output_started: bool = false,
    // An Action the reader found, adopted once input is idle.
    prepared_action: ?u64 = null,
    prepared_summary: View.ActionSummary = .{},
    // One joined read at a time; no reuse until its live diagnostic is delivered.
    pending_diagnostic: ?struct { failure: protocol_reply.ReadFailure, phase: ReadPhase, recoverable: bool } = null,
} = .{},
// The inspection page and the command that may fill it.
inspection: struct {
    kind: Inspection = .status,
    // /status was asked for; the next scan shows it.
    status_requested: bool = false,
    // What two /status reads took of the Session, each listing its Actions
    // in the matching `files.actions`: the shown page's, named by `status`,
    // and the one the next read takes, so neither is copied. Null while the
    // shown inspection page is not /status. Each scan replaces the page, in
    // the same frame as its own, when anything it reports changed. Its one
    // Current read follows the page's, so it is never older than the
    // history it shows with.
    sessions: [2]status_page.Session = undefined,
    status: ?u1 = null,
    // The defaults new Sessions start from, read when /status opens and
    // after a command run over it.
    defaults: status_page.Defaults = error.Unread,
    // The row Up and Down move `›` over and Enter changes. Each /status
    // starts at the first; a page that comes back after a change keeps it.
    selected: status_page.Setting = status_page.first,
    // The submission the shown page shows under it.
    submission: ?Submission.View = null,
    // An inspection or Host command started and its result has not been
    // presented. A command may change configuration, so Messages and consent wait
    // for every inspection; exit prints an unshown command's output, which can
    // carry recovery warnings.
    command_running: bool = false,
} = .{},
// Messages sent.
admission: struct {
    /// Messages begun; a /details read begun before the latest one never covers it.
    sent: u64 = 0,
    details_sent: u64 = 0,
} = .{},
// Live output and the page that last extended it.
live: struct {
    view: View.Live = .{},
    // The work the latest applied page carried.
    work: protocol.SessionWork = .{},
    cursor: protocol_reply.ActivityCursor = .{},
    // UI commits layout alongside delivered Activity; workers borrow a snapshot.
    compact_tools: bool = false,
    // The Messages of collapsed blocks in live output.
    blocks: View.Blocks = .{},
    // Where each read's live output began, so a transcript whose live copy lost
    // its front still continues from a canonical position without a gap.
    marks: reads.Marks = .{},
    // Messages shown live so far, which decide where a later read may mark.
    messages: reads.Messages = .{},
    // The Messages live output shows since its newest mark.
    echoes: reads.Record = .{},
    // How many entries live output has shown, as its reads counted them.
    entries: u64 = 0,
    // Where a transcript's search for the Messages a seam lists may stop
    // (see reads.listed): at most the lowest position of one seen or not yet
    // searched for; a stale value only costs reads.
    lowest: ?u64 = null,
    // The Messages a person or script sent that wait behind the work, as
    // the Host reported them at the cursor; the first line the queued row
    // last read, with its Message; and the newest live output showed while
    // it waited (see View.Taking).
    queued: protocol.Queued = .{},
    queued_line: ?queued_line.Shown = null,
    drawn: queued_line.Drawn = .{},
} = .{},
// The transcript above live output.
transcript: struct {
    // Each transcript gets a new identity, so a page loaded for one is never
    // joined to another.
    id: u64 = 0,
    // Continues the transcript above its oldest shown row; null at the start.
    older: ?protocol_reply.ConversationCursor = null,
    // What the transcript shows above its copy before older pages (see
    // reads.Plan); its echoes are listed newest first, so `count` falls.
    plan: reads.Plan = .{ .start = 0 },
    // Older pages reach the conversation's start, so the transcript says so.
    beginning: bool = false,
    // A failed older load waits for the next scroll rather than retrying at once.
    older_failed: bool = false,
    history_requested: ?History = null,
    // The Messages of collapsed blocks in the transcript.
    blocks: View.Blocks = .{},
} = .{},
// One collapsed Message shown in full.
expansion: struct {
    // Ctrl-O waits for the frame it names a block in; the read then waits for
    // the reader, and its page shows only over the view it was asked from.
    // A newer Ctrl-O may queue while an older page is still being read.
    queued: union(enum) { none, after_frame, ready: MessageRequest } = .none,
    // The page being read. Each request holds where it was asked from;
    // Esc, Ctrl-G, a send or a newer Ctrl-O supersedes it.
    reading: ?MessageRequest = null,
    generation: u64 = 0,
} = .{},
action_summary: View.ActionSummary = .{},
// A frontend-owned change the next frame must show: input, notices, status,
// live text or scrolling. The Screen's own changes make it stale() instead.
dirty: bool = true,
/// How the person is leaving, once they asked to.
leaving: ?Outcome = null,
/// Shown under the input until the next key, in place of the Session line.
notice: ?[]const u8 = null,
notice_buffer: [notice_capacity]u8 = undefined,
/// On the App: what `notice` said, until the next key or its time runs
/// out. Each App event moves `notice` here.
shown_notice: session_chrome.Notice(notice_capacity) = .{},
/// What the held original's last attempt failed with, while that original
/// is held in the state the failure left: its status-bar line, and for
/// /status what to do. It needs the person, so it is no notice.
failure: ?struct { key: [36]u8, state: Submission.State, bar: session_notice.Failure, page: ?[]const u8 = null } = null,
failure_buffer: [failure_capacity]u8 = undefined,
/// The `?` shortcuts are open.
shortcuts_open: bool = false,
/// How many entries live output had shown when the view was scrolled back,
/// so the marker counts the ones that arrived since.
browsed_from: ?u64 = null,
chrome: SessionChrome = undefined,
/// The Session line's facts from the latest read that took them, the
/// unlabelled Session's name, and the line as last written.
line: reads.Line = .{},
hint: reads.Hint = .unread,
shown: session_line.Shown = .{},

const rejection_suffix = " · /discard";
/// This process's environment cannot change, so the original goes from a
/// shell with a smaller one.
const too_large_advice = "\nUnset or shorten them in another shell, then run rui request recover there.";
/// The longest failure line: a rejection with its code escaped (four bytes
/// per byte at most), or a refused environment and its fix.
const failure_capacity = @max(
    "! Decision rejected: ".len + 4 * protocol.max_code_bytes + rejection_suffix.len,
    "! ".len + client.Environment.too_large_bytes + too_large_advice.len,
);
/// The longest built notice: a short result with a failure mark on each
/// line, or the model's facts.
const notice_capacity = @max(
    slash_commands_shared.result_notice_bytes,
    protocol.max_model_bytes + " · ".len + unknown_sign_in.len + model_tail.len,
);

/// Fills the reader's job in place; the caller may add to it before launch.
fn freeze(self: *Self, phase: ReadPhase) *Job {
    std.debug.assert(self.reader.thread == null);
    self.job = .{ .init = self.init, .home = self.home, .store = self.store, .session = self.session, .files = self.files, .colour = self.colour, .command = self.command, .requests = self.requests, .status = self.status, .phase = phase, .cursor = self.live.cursor, .opening = self.reading.opening, .older = self.transcript.older, .target = if (phase == .history) if (self.transcript.plan.next()) |listing| .{ .listing = listing } else .older else .older, .messages = self.live.messages, .queued = self.live.queued, .drawn = self.live.drawn, .queued_line = if (self.live.queued_line) |shown| shown.admission else 0, .transcript = self.transcript.id, .held = self.live.work.state.holdsQueue(), .inspection_kind = self.inspection.kind, .interrupted = self.interrupted, .line_read = self.line.read, .provider = self.line.provider, .hint_wanted = self.hint == .unread };
    const job = &self.job;
    if (phase == .activity or phase == .permission) {
        job.open_status = self.inspection.status_requested;
        job.watch_status = self.statusShown();
        const shown = self.inspection.status;
        const taken: u1 = if (shown) |index| ~index else 0;
        job.status_shown = if (shown) |index| &self.inspection.sessions[index] else null;
        job.status_taken = &self.inspection.sessions[taken];
        job.status_actions = self.files.actions[taken];
    }
    job.result.compact_tools = self.live.compact_tools;
    return job;
}

test "reader freezes borrowed HOME independently of process initialization" {
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    for ([_][]const u8{ "", "/home/a b" }) |home| {
        for (std.enums.values(ReadPhase)) |phase| {
            self.* = .{ .init = undefined, .home = home, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
            const job = self.freeze(phase);
            self.home = "/changed-after-freeze";
            try std.testing.expectEqualStrings(home, job.home);
            try std.testing.expectEqual(home.ptr, job.home.ptr);
        }
    }
}

pub const SkillRead = *const fn (client.Requests, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!skill_suggestions.Page;

fn clientSkills(requests: client.Requests, gpa: std.mem.Allocator, store: []const u8, session: []const u8, prefix: []const u8) !skill_suggestions.Page {
    return requests.skillSuggestions(gpa, store, .{ .session = session }, prefix);
}

/// A skills read's inputs, copied when it starts, and its page.
const SkillJob = struct {
    run: SkillRead = clientSkills,
    gpa: std.mem.Allocator = undefined,
    store: []const u8 = "",
    session: []const u8 = "",
    read: u64 = 0,
    prefix: protocol.Bounded(skill_completion.max_prefix_bytes) = .{},
    page: ?skill_suggestions.Page = null,

    fn work(raw: *anyopaque, task: *Task) !void {
        const job: *SkillJob = @ptrCast(@alignCast(raw));
        job.page = try job.run(task.requests(), job.gpa, job.store, job.session, job.prefix.slice());
    }
};

/// Answers a finished skills read, then starts the read the caret's
/// `/word` needs, if any. A canonical Store failure ends the conversation,
/// as the reader's does; any other failure only stops that name's reads.
fn serviceSkills(self: *Self) !void {
    if (self.skill_task.thread != null) {
        if (!self.skill_task.completed()) return;
        const outcome = self.skill_task.join();
        const job = &self.skill_job;
        if (outcome) |_| {
            const draft = self.input.composition();
            const word = skill_completion.skillWordAt(draft.bytes, draft.cursor);
            if (self.skills.answer(job.read, job.page.?, if (word) |at| at.name(draft.bytes) else null)) |unheld| {
                var freed = unheld;
                freed.deinit(self.init.gpa);
            }
            job.page = null;
        } else |err| {
            self.skills.fail(job.read);
            if (err == error.CanonicalStoreFailure) return err;
        }
        self.dirty = true;
    }
    if (self.upgradeHeld()) return;
    const draft = self.input.composition();
    const word = skill_completion.skillWordAt(draft.bytes, draft.cursor) orelse return;
    const ask = self.skills.ask(word.name(draft.bytes)) orelse return;
    self.skill_job = .{ .run = self.skill_read, .gpa = self.init.gpa, .store = self.store, .session = self.session, .read = ask.read };
    self.skill_job.prefix.set(ask.prefix) catch unreachable; // The core asks for no longer name.
    self.skill_task.start(self.init.io, &self.skill_job, SkillJob.work) catch |err| {
        self.skills.fail(ask.read);
        return err;
    };
}

/// Stops and joins the skills read, and lets every page go: the
/// conversation ends, or an Upgrade may change the Host. Returns the
/// read's canonical Store failure, which ends the conversation as the
/// reader's does; any other failure, cancellation among them, goes.
fn dropSkills(self: *Self) ?anyerror {
    self.skill_task.cancel();
    const ended = self.skill_task.join();
    if (self.skill_job.page) |*page| page.deinit(self.init.gpa);
    self.skill_job.page = null;
    if (self.skills.reset()) |page| {
        var held = page;
        held.deinit(self.init.gpa);
    }
    ended catch |err| if (err == error.CanonicalStoreFailure) return err;
    return null;
}

/// Starts the job `freeze` filled.
fn launch(self: *Self, job: *const Job, worker: Task.Run) !void {
    std.debug.assert(self.reader.thread == null and job == &self.job);
    self.reading.phase = job.phase;
    self.reading.output_started = false;
    try self.reader.start(self.init.io, &self.job, worker);
}

/// The overview that lent the terminal decides stop and archive intents and
/// sends the stop, so a conversation stops its Session exactly as the
/// Session's row does. Each call names the work the conversation shows.
pub const Lender = struct {
    context: *anyopaque,
    /// Steps the overview with semantic input for this exact conversation.
    step: *const fn (context: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) anyerror!void,
    /// Runs the overview between the conversation's frames, without the
    /// screen or input: answers its finished job, keeps its listing going,
    /// so another Session's news still notifies, and starts its next stop
    /// or listing job. True when an answer came. Its failure is the
    /// overview's and ends the conversation.
    service: *const fn (context: *anyopaque) anyerror!bool,
    /// What the overview says under the input, until its next step.
    line: *const fn (context: *anyopaque, work: protocol.session_work.Kind) Said,
    /// Hands the overview each read of the Session's work; the read the
    /// conversation opens on is an outcome the person has seen. Its failure
    /// is the overview's and ends the conversation.
    observed: *const fn (context: *anyopaque, work: protocol.session_work.Work, opening: bool) anyerror!void,

    /// The Upgrade, the overview's one value: its run, and what the last
    /// run left Host requests.
    upgrade: *const fn (context: *anyopaque) session_upgrade.Upgrade,

    pub const Said = struct {
        /// The overview's notice; null for none.
        text: ?[]const u8 = null,
        /// Ctrl-X would stop the work.
        stoppable: bool = false,
    };
};

/// How the frontend stopped. Either way it stopped only its own client waits;
/// Host work it started continues. `returned` goes back to the overview that
/// lent the terminal, which stays begun.
pub const Outcome = enum { detached, interrupted, returned };

pub fn begin(self: *Self, init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, requests: Requests, status: Status, screen: *Screen, interrupted: *client.Cancellation, lender: Lender) void {
    self.* = .{ .init = init, .home = init.environ_map.get("HOME") orelse "", .store = store, .session = session, .directory = directory, .files = files, .command = command, .requests = requests, .status = status, .screen = screen, .interrupted = interrupted, .lender = lender, .colour = screen.colour };
    self.startInput();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input, .environment = .{ .map = init.environ_map } };
    self.app_content = .{ .document = &screen.live, .colour = self.colour, .handler = .{ .userdata = self, .on_open = appOpen, .on_notice = appNotice, .on_scroll = appDragScroll, .on_click = appClick } };
    self.app_input = .{ .composer = .{ .editor = &self.input.editors[self.input.active] } };
    self.app_screen = .{ .content = &self.app_content, .input = &self.app_input, .userdata = self, .on_event = appEvent };
}

pub const AppHooks = struct {
    root: *Root,
    context: *anyopaque,
    leave: *const fn (*anyopaque, *vxfw.EventContext, Outcome) anyerror!void,
    copy: *const fn (*anyopaque, std.Io.File, u64, u64) anyerror!void,
    /// A Session link was clicked and this Session is about to be left:
    /// the linked Session's ID, opened once `leave` returns to the overview.
    on_open: *const fn (*anyopaque, *vxfw.EventContext, *const [session_id.bytes]u8) anyerror!void,
};

pub fn attach(self: *Self, hooks: AppHooks, caps: overview_view.Caps) vxfw.Widget {
    self.app_hooks = hooks;
    self.app_caps = caps;
    self.screen.setWidth(caps.width);
    self.app_preview = .{ .document = &self.screen.browsing, .colour = self.colour, .more = "shift+↓" };
    self.app_card = .{ .consent = &self.app_consent, .pasting = &hooks.root.pasting, .description = "", .body = self.app_preview.widget(), .userdata = self, .on_decision = appDecision };
    self.chrome = .init(.{ .userdata = self, .key = chromeClick(.needs), .stop = chromeClick(.{ .action = .stop }), .back = chromeClick(.{ .action = .close }), .latest = chromeClick(.{ .action = .latest }), .status_page = chromeClick(.status) });
    return self.widget();
}

/// What a click on the chrome runs: what its key runs.
const Click = union(enum) {
    action: ConversationAction,
    /// `+N more running · /status`.
    status,
    /// The key that ends what needs the person: Ctrl-R's retry, or the
    /// command the held original's line names (`session_notice.key`).
    needs,
};

/// Every chrome click meets the rules a key does: none once leaving, the
/// last reply dismissed, then what follows any input.
fn chromeClick(comptime click: Click) *const fn (*anyopaque, *vxfw.EventContext) anyerror!void {
    return struct {
        fn run(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.leaving != null) return;
            self.shown_notice.dismiss();
            switch (click) {
                .action => |action| try self.perform(action),
                .status => try self.clickCommand("/status"),
                .needs => if (self.heldOriginal()) |held| if (session_notice.key(held)) |key| switch (key) {
                    .retry => try self.perform(.recover),
                    .discard => try self.clickCommand("/discard"),
                    .status => try self.clickCommand("/status"),
                },
            }
            self.dirty = true;
            try self.afterInput(ctx);
        }
    }.run;
}

/// A key that types `?`, as the editor reads text: the codepoint itself or
/// its text (Shift-/ on some terminals), with no modifier but Shift.
fn typesQuestion(key: vaxis.Key) bool {
    const mods = key.mods;
    if (mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta) return false;
    return key.codepoint == '?' or if (key.text) |text| std.mem.eql(u8, text, "?") else false;
}

/// A command a click runs, admitted as a typed one is (`SessionInput`):
/// while another command waits its turn, it says so and runs nothing.
fn clickCommand(self: *Self, text: []const u8) !void {
    if (!self.input.admitsCommand()) return self.sayBusy(null, false);
    try self.slashCommand(text);
}

/// Says why input the draft refused waits, for a typed line or a click.
fn sayBusy(self: *Self, action: ?session_notice.Action, letter: bool) void {
    // An Upgrade's hold names itself, unless a command of the draft's own waits.
    const phase = self.upgradePhase();
    const command = self.input.queuedCommand() != null or self.inspection.command_running;
    self.notice = if (phase != .active and !command) session_upgrade.refusal(phase) else session_notice.busy(.{ .command = self.commandActive(), .held = self.heldOriginal(), .preparing = self.reading.phase == .permission, .action = action, .letter = letter });
}

/// The Session's name as the terminal title leads with it.
pub fn titleName(self: *const Self) []const u8 {
    return if (self.line.facts(&self.hint, self.session)) |facts| facts.name else self.session;
}

fn nowMs(self: *const Self) u64 {
    return @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = appEvent, .drawFn = appDraw };
}

/// What a drag in the Transcript did, on the status bar.
fn appNotice(raw: *anyopaque, ctx: *vxfw.EventContext, text: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.shown_notice.show(text, self.nowMs());
    ctx.redraw = true;
}

/// A click on a peer's name: leave for that Session where Esc would leave,
/// else say what keeps this one open. The draft and Session stay as they are.
fn appOpen(raw: *anyopaque, ctx: *vxfw.EventContext, id: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.follow(ctx, id);
    try self.depart(ctx);
}

/// Opens the peer `id` names, by a click or Ctrl-O, under Esc's rules. Its
/// caller departs once, as `appEvent` does after every event: the screen
/// opens the peer on that departure.
fn follow(self: *Self, ctx: *vxfw.EventContext, id: []const u8) !void {
    if (self.leaving != null or id.len != session_id.bytes or !session_id.valid(id) or std.mem.eql(u8, id, self.session)) return;
    const screen = self.screen;
    const action = screen.action_view != null or self.live.work.first_action != null or self.reading.prepared_action != null;
    const original: ?Submission.State = if (self.submission.view()) |submission| submission.state else null;
    switch (session_notice.follow(original, self.submission.published(), self.input.composition().bytes.len == 0, action, self.commandActive())) {
        .stay => |why| {
            self.notice = why;
            ctx.redraw = true;
        },
        .leave => {
            try self.app_hooks.on_open(self.app_hooks.context, ctx, id[0..session_id.bytes]);
            self.leaving = .returned;
        },
    }
}

/// A click on a `┄ N more lines` row opens that Message, as Ctrl-O opens
/// the lowest one in view; a click anywhere else does nothing.
fn appClick(raw: *anyopaque, ctx: *vxfw.EventContext, at: viewport.Position) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.leaving != null or self.pagePlace() == .elsewhere) return;
    const index = self.app_content.document.summaryAt(at.offset) orelse return;
    self.shown_notice.dismiss();
    if (self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
    } else {
        self.dropMessageRequest();
        self.openCollapsed(index);
    }
    try self.afterInput(ctx);
}

fn appDragScroll(raw: *anyopaque, _: *vxfw.EventContext, up: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.screen.dragScroll(up);
}

fn appDecision(raw: *anyopaque, ctx: *vxfw.EventContext, decision: ConsentPolicy.Decision) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.screen.releaseAction();
    self.app_input.permission = null;
    // Refused by an Upgrade's hold, the Action waits at the Host and its
    // card shows again once the conversation has read again.
    _ = try self.beginSubmission(.{ .decision = .{ .action = decision.action, .decision = switch (decision.choice) {
        .allow_once => .allow_once,
        .deny => .deny,
    } } });
    try ctx.requestFocus(self.app_input.composer.widget());
}

fn appEvent(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.leaving != null) return;
    switch (event) {
        .init, .focus_in => try ctx.requestFocus(if (self.app_input.permission) |card| card.widget() else self.app_input.composer.widget()),
        .tick => {
            _ = try self.update();
            // An Upgrade's hold shows no choice: nothing decided could be
            // sent. The read after the hold finds the Action again.
            const held = self.upgradeHeld();
            if (held and self.reading.prepared_action != null) {
                self.reading.prepared_action = null;
                if (self.reader.thread == null) self.reading.phase = .activity;
            }
            if (self.app_consent.request) |request| if (held or self.live.work.first_action != request) {
                self.app_consent.withdraw();
                self.screen.withdrawAction();
                self.app_input.permission = null;
                try ctx.requestFocus(self.app_input.composer.widget());
                self.dirty = true;
            };
            if (self.reader.thread == null) if (self.reading.prepared_action) |request| {
                // Close the editor's paste transaction before hiding it. Root
                // keeps the terminal paste flag until its actual end arrives.
                const blurred = self.input.appEvent(conversation_keys, .focus_out, self.app_hooks.root.pasting, false);
                if (blurred == .editor and blurred.editor == .refused) self.notice = refusedNotice(blurred.editor.refused);
                try self.screen.showFile(self.init.io, self.files.action, true);
                self.action_summary = self.reading.prepared_summary;
                self.reading.prepared_action = null;
                self.reading.phase = .activity;
                self.app_consent.adopt(request);
                self.app_input.permission = &self.app_card;
                try ctx.requestFocus(self.app_card.widget());
                self.dirty = true;
            };
            try self.app_card.widget().handleEvent(ctx, .tick);
            if (self.expansion.queued == .after_frame) if (try self.expand()) |peer| try self.follow(ctx, &peer);
            if (self.shown_notice.expire(self.nowMs())) self.dirty = true;
            ctx.redraw = ctx.redraw or self.dirty;
        },
        .key_press, .paste_start, .paste_end, .invalid_key => {
            const pasting = self.app_hooks.root.pasting;
            self.shown_notice.dismiss();
            const question = event == .key_press and !pasting and typesQuestion(event.key_press);
            const shortcut = session_chrome.shortcut(self.shortcuts_open, self.input.composition().bytes.len == 0, question);
            self.shortcuts_open = shortcut == .open;
            if (shortcut == .open) {
                // The key types nothing.
            } else if (self.app_consent.request != null) {
                if (event == .key_press and !pasting) if (Editor.selectKey(conversation_keys, event.key_press) == .action) {
                    try self.perform(Editor.selectKey(conversation_keys, event.key_press).action);
                };
            } else {
                self.notice = null;
                // One submission at a time: a decision or Message in flight,
                // or an original still held, makes Enter say so and keep the draft.
                const allowed = !self.reading.opening and self.reading.phase != .permission and !self.commandActive() and self.submission.intent == null;
                if (!(event == .key_press and !pasting and Editor.isEnter(event.key_press) and (self.startChange() or self.takeShownRow()))) {
                    switch (self.input.appEvent(conversation_keys, event, pasting, allowed)) {
                        .message => |ticket| try self.beginMessage(.{ .message = ticket }),
                        .command => try self.commandLine(),
                        .busy => self.sayBusy(null, false),
                        .editor => |outcome| switch (outcome) {
                            .action => |action| try self.perform(action),
                            .refused => |why| self.notice = refusedNotice(why),
                            .submit => if (self.shownCommands() != null) try self.commandLine(),
                            .none, .append, .redraw => {},
                        },
                    }
                }
            }
            ctx.consumeEvent();
            ctx.redraw = true;
        },
        .mouse => |mouse| switch (mouse.button) {
            .wheel_up, .wheel_down => {
                try self.scroll(mouse.button == .wheel_down, 1);
                ctx.consumeEvent();
                ctx.redraw = true;
            },
            else => {},
        },
        else => {},
    }
    try self.afterInput(ctx);
}

/// After any App input: moves what was said into the notice, prepares the
/// documents and, once the person asked to leave, leaves.
fn afterInput(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.notice) |text| {
        self.shown_notice.show(text, self.nowMs());
        self.notice = null;
        self.dirty = true;
    }
    ctx.redraw = ctx.redraw or self.dirty;
    if (self.leaving == null) try self.serviceSkills();
    try self.screen.live.prepare();
    try self.screen.browsing.prepare();
    try self.screen.staging.prepare();
    self.app_input.composer.editor = &self.input.editors[self.input.active];
    try self.depart(ctx);
}

/// Hands the Session back to the overview once it is leaving.
fn depart(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.leaving) |outcome| {
        const blurred = self.input.appEvent(conversation_keys, .focus_out, self.app_hooks.root.pasting, false);
        if (blurred == .editor and blurred.editor == .refused) self.notice = refusedNotice(blurred.editor.refused);
        self.app_consent.withdraw();
        self.app_card.ready_pending = false;
        self.stop();
        try self.app_hooks.leave(self.app_hooks.context, ctx, outcome);
    }
}

fn appDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const screen = self.screen;
    const normal = style.of(self.app_caps, .{});
    const quiet = style.of(self.app_caps, .{ .colour = .quiet });
    const facts_style = style.of(self.app_caps, .{ .colour = .quiet, .background = .bar });
    self.app_screen.style = normal;
    self.app_input.composer.style = normal;
    self.app_input.composer.quiet = quiet;
    self.app_input.composer.method = self.app_caps.width;
    self.app_input.composer.editor = &self.input.editors[self.input.active];
    self.app_card.style = normal;
    self.app_card.quiet = quiet;
    self.app_card.description = self.action_summary.description.slice();
    self.app_card.method = self.app_caps.width;
    self.app_preview.style = normal;
    self.app_preview.quiet = quiet.fg;
    self.app_preview.method = self.app_caps.width;
    self.app_content.style = normal;
    self.app_content.quiet = quiet.fg;
    self.app_content.method = self.app_caps.width;
    self.app_content.document = switch (screen.view) {
        .live => &screen.live,
        .message => &screen.staging,
        .transcript, .inspection, .action => &screen.browsing,
    };
    // Live output follows the latest rows; only a drag held at its top
    // edge moves it, until the drag ends.
    if (screen.view == .live and !self.app_content.dragging()) screen.live.top = null;
    const attention = style.of(self.app_caps, .{ .colour = .attention });
    screen.commands = self.nextCommands(screen.commands);
    var palette: ?vxfw.Widget = null;
    if (self.app_consent.request == null) if (screen.commands) |*shown| {
        self.app_palette = .{ .shown = shown, .method = self.app_caps.width, .style = normal, .quiet = quiet };
        palette = self.app_palette.widget();
    };
    const now_ms = self.nowMs();
    const work = self.live.work.state.asOf(now_ms);
    const said = self.lender.line(self.lender.context, work);
    const browsing = screen.view != .live;
    if (!browsing) self.browsed_from = null else if (self.browsed_from == null) self.browsed_from = self.live.entries;
    const chrome = &self.chrome;
    chrome.activity.live = self.live.view;
    chrome.activity.work = if (self.app_consent.request != null) null else work_line.of(try ctx.arena.create([work_line.max_words_bytes]u8), &self.live.work.state, self.live.work.operation, now_ms);
    // Browsing draws no tail, so no waiting row.
    const queued = if (browsing) null else self.queuedRow();
    chrome.activity.queued = if (queued) |row| row.waiting else null;
    chrome.activity.method = self.app_caps.width;
    chrome.activity.styles = .{ .normal = normal, .quiet = quiet, .attention = attention, .failure = attention };
    chrome.status.method = self.app_caps.width;
    chrome.status.quiet = quiet;
    chrome.status.attention = attention;
    chrome.facts.method = self.app_caps.width;
    chrome.facts.style = facts_style;
    chrome.marker.method = self.app_caps.width;
    chrome.marker.style = .{ .reverse = true };
    chrome.shortcuts.method = self.app_caps.width;
    chrome.shortcuts.style = normal;
    const held = self.heldOriginal();
    const send = session_chrome.send(session_notice.status(self.reading.opening, self.app_consent.request != null, held), self.reading.opening or (held != null and held.?.state == .submitting));
    const facts_buffer = try ctx.arena.create([session_chrome.facts_bytes]u8);
    chrome.place(&self.app_screen, .{
        .browsing = browsing,
        .new_entries = if (self.browsed_from) |from| self.live.entries - from else 0,
        .needs = send.needs,
        .needs_key = if (send.needs) |needs| session_chrome.needsKey(needs) else "",
        // A conversation reading itself again says so until Host requests go on.
        .progress = if (self.upgradePhase() == .reobserving) session_upgrade.rereading else send.progress,
        .stoppable = said.stoppable,
        .facts = session_chrome.factsRow(facts_buffer, self.line.facts(&self.hint, self.session), self.session, status_page.archiveBadge(self.line.archive_state), ctx.max.width.? -| FactsRow.text_column, self.app_caps.width),
        .notice = self.shown_notice.current(now_ms),
        .overview = said.text,
        .shortcuts = self.shortcuts_open,
        .overlay = palette,
        .width = ctx.max.width.?,
    });
    self.app_preview.size = .{};
    var surface = try self.app_screen.widget().draw(ctx);
    const visible = if (self.app_consent.request != null) &self.app_preview else &self.app_content;
    screen.height = visible.size.height;
    screen.browsing_height = screen.height;
    screen.marker_rows = @intFromBool(self.app_screen.marker != null);
    screen.vx.screen.width = visible.size.width;
    screen.drawn = .{ .first = visible.first, .rows = screen.height };
    surface.widget = self.widget();
    self.dirty = false;
    return surface;
}

test "App Session retains the draft across a permission card arriving during paste" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    try page.writeStreamingAll(std.testing.io, "$ echo safe\n");
    for (0..60) |_| try page.writeStreamingAll(std.testing.io, "preview row\n");
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    init.environ_map = &environ;
    var interrupted: client.Cancellation = .{};
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
    const Hooks = struct {
        fn leave(_: *anyopaque, _: *vxfw.EventContext, _: Outcome) !void {
            return error.UnexpectedLeave;
        }
        fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
            return error.UnexpectedCopy;
        }
        fn open(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {
            return error.UnexpectedOpen;
        }
    };
    var root: Root = .{ .overview = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    try screen.append("\x1b[2mtheme witness\x1b[0m");
    for ([_]struct { caps: overview_view.Caps, ground: vaxis.Color, band: vaxis.Color }{
        .{ .caps = .{}, .ground = .{ .rgb = .{ 0x12, 0x19, 0x33 } }, .band = .{ .rgb = .{ 0x1a, 0x22, 0x46 } } },
        .{ .caps = .{ .background = .{ 255, 255, 255 } }, .ground = .{ .rgb = .{ 0xf3, 0xee, 0xe2 } }, .band = .{ .rgb = .{ 0xe6, 0xdd, 0xc8 } } },
        .{ .caps = .{ .depth = .indexed }, .ground = .{ .index = 234 }, .band = .{ .index = 236 } },
        .{ .caps = .{ .depth = .none }, .ground = .default, .band = .default },
    }) |case| {
        self.app_caps = case.caps;
        self.app_content.colour = case.caps.depth != .none;
        const surface = try widget_.draw(draw_context);
        try std.testing.expectEqual(case.ground, surface.readCell(79, 10).style.bg);
        var rendered: vaxis.Screen = try .init(arena.allocator(), .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &rendered };
        surface.render(window, self.app_input.composer.widget());
        const user = rendered.readCell(0, 0).?;
        try std.testing.expectEqualStrings("t", user.char.grapheme);
        try std.testing.expectEqual(style.of(case.caps, .{ .colour = .quiet }).fg, user.style.fg);
        try std.testing.expect(!user.style.dim);
        try std.testing.expectEqual(case.ground, rendered.readCell(79, 10).?.style.bg);
        try std.testing.expectEqual(case.band, rendered.readCell(79, 22).?.style.bg);
        try std.testing.expectEqual(case.ground, rendered.readCell(79, 23).?.style.bg);
    }
    self.app_caps = .{ .depth = .none };
    _ = self.input.append("headTAIL");
    self.input.editors[self.input.active].cursor = 4;
    root.pasting = true;
    try widget_.handleEvent(&ctx, .paste_start);
    try widget_.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 0, .text = "12" } });
    self.reading.prepared_action = 17;
    self.live.work.first_action = 17;
    try widget_.handleEvent(&ctx, .tick);
    _ = try widget_.draw(draw_context);
    try std.testing.expectEqual(@as(?u64, 17), self.app_consent.drawn);
    try self.app_card.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(@as(?u64, 17), self.app_consent.request);
    root.pasting = false;
    const before_scroll = self.app_preview.first;
    try std.testing.expect(screen.height > 0);
    const page_down: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.page_down } };
    ctx.consume_event = false;
    try self.app_card.widget().handleEvent(&ctx, page_down);
    try std.testing.expect(!ctx.consume_event);
    try widget_.handleEvent(&ctx, page_down);
    _ = try widget_.draw(draw_context);
    try std.testing.expect(self.app_preview.first.order(before_scroll) == .gt);
    try std.testing.expectEqualStrings("head12TAIL", self.input.composition().bytes);
    root.pasting = true;
    self.live.work.first_action = null;
    try widget_.handleEvent(&ctx, .tick);
    try widget_.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 0, .text = "discarded" } });
    root.pasting = false;
    try widget_.handleEvent(&ctx, .paste_end);
    try std.testing.expectEqualStrings("head12TAIL", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 6), self.input.composition().cursor);
    _ = try widget_.draw(draw_context);
    try std.testing.expectEqual(null, self.app_input.permission);
    try std.testing.expectEqual(null, self.submission.task.thread);
}

test "App Session leaves from a permission card on Ctrl-C or Ctrl-D and keeps the hidden draft" {
    for ([_][]const u8{ "\x03", "\x04", "\x1b[99;5u", "\x1b[100;5u" }) |bytes| {
        errdefer std.debug.print("bytes={x}\n", .{bytes});
        var environ = try std.testing.environ.createMap(std.testing.allocator);
        defer environ.deinit();
        const screen = try std.testing.allocator.create(Screen);
        defer std.testing.allocator.destroy(screen);
        try screen.init(std.testing.io, &environ, false);
        defer screen.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
        defer page.close(std.testing.io);
        try page.writeStreamingAll(std.testing.io, "$ echo safe\n");
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        init.gpa = std.testing.allocator;
        init.environ_map = &environ;
        var interrupted: client.Cancellation = .{};
        const self = try std.testing.allocator.create(Self);
        defer std.testing.allocator.destroy(self);
        self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
        const Hooks = struct {
            var left: ?Outcome = null;
            fn leave(_: *anyopaque, _: *vxfw.EventContext, outcome: Outcome) !void {
                left = outcome;
            }
            fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
                return error.UnexpectedCopy;
            }
            fn open(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {
                return error.UnexpectedOpen;
            }
        };
        Hooks.left = null;
        var root: Root = .{ .overview = empty_app_text.widget() };
        const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
        self.reading.opening = false;
        self.poll_at = std.math.maxInt(i96);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        // A hidden draft with its caret at the start: leaving never deletes
        // what the card hides.
        _ = self.input.append("kept");
        self.input.editors[self.input.active].cursor = 0;
        self.reading.prepared_action = 17;
        self.live.work.first_action = 17;
        try widget_.handleEvent(&ctx, .tick);
        _ = try widget_.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(?u64, 17), self.app_consent.request);
        // The key as App decodes it: the focused card first, then the Session.
        var parser: vaxis.Parser = .{};
        const key = (try parser.parse(bytes, null)).event.?.key_press;
        ctx.consume_event = false;
        try self.app_card.widget().handleEvent(&ctx, .{ .key_press = key });
        if (!ctx.consume_event) try widget_.handleEvent(&ctx, .{ .key_press = key });
        try std.testing.expectEqual(@as(?Outcome, .detached), Hooks.left);
        try std.testing.expect(self.app_consent.request == null);
        try std.testing.expectEqualStrings("kept", self.input.composition().bytes);
        _ = self.submission.join();
        self.submission.close();
    }
}

test "App Session drag copies the live rows it crosses once, says so and clears" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    init.environ_map = &environ;
    var interrupted: client.Cancellation = .{};
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
    const Hooks = struct {
        fn leave(_: *anyopaque, _: *vxfw.EventContext, _: Outcome) !void {
            return error.UnexpectedLeave;
        }
        fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
            return error.UnexpectedCopy;
        }
        fn open(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {
            return error.UnexpectedOpen;
        }
    };
    var root: Root = .{ .overview = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    for (0..40) |index| {
        var line: [16]u8 = undefined;
        try screen.live.append(try std.fmt.bufPrint(&line, "row {d}\n", .{index}));
    }
    _ = try widget_.draw(draw_context);
    const shown = self.app_content.size.height;
    try std.testing.expect(shown > 3 and shown < 40);
    const content = self.app_content.widget();
    const Clip = struct {
        fn take(context: *vxfw.EventContext, buffer: []u8) []const u8 {
            var length: usize = 0;
            for (context.cmds.items) |command| if (command == .copy_to_clipboard) {
                @memcpy(buffer[length..][0..command.copy_to_clipboard.len], command.copy_to_clipboard);
                length += command.copy_to_clipboard.len;
                std.testing.allocator.free(command.copy_to_clipboard);
            };
            context.cmds.clearRetainingCapacity();
            return buffer[0..length];
        }
    };
    var copied: [256]u8 = undefined;
    const press = struct {
        fn at(kind: vaxis.Mouse.Type, col: i16, row: u16) vxfw.Event {
            return .{ .mouse = .{ .col = col, .row = @intCast(row), .button = .left, .mods = .{}, .type = kind } };
        }
    }.at;
    // Rows drawn end "row 37", "row 38", "row 39"; the last row is an edge.
    try content.handleEvent(&ctx, press(.press, 0, shown - 3));
    try content.handleEvent(&ctx, press(.drag, 4, shown - 2));
    _ = try widget_.draw(draw_context);
    try std.testing.expect(self.app_content.dragging());
    try content.handleEvent(&ctx, press(.release, 4, shown - 2));
    try std.testing.expectEqualStrings("row 37\nrow 3", Clip.take(&ctx, &copied));
    try std.testing.expectEqualStrings("Copied 2 lines", self.shown_notice.current(self.nowMs()).?);
    try std.testing.expect(!self.app_content.dragging());
    // Held at the top edge, the live view scrolls through rows it already
    // holds; released, it follows the latest rows again.
    try content.handleEvent(&ctx, press(.press, 2, 1));
    try content.handleEvent(&ctx, press(.drag, 0, 0));
    for (ctx.cmds.items) |command| std.debug.assert(command != .copy_to_clipboard);
    ctx.cmds.clearRetainingCapacity();
    const before = self.app_content.first;
    for (0..2) |_| {
        try content.handleEvent(&ctx, .tick);
        _ = try widget_.draw(draw_context);
    }
    ctx.cmds.clearRetainingCapacity();
    try std.testing.expectEqual(Screen.ViewKind.live, screen.view);
    try std.testing.expect(self.app_content.first.order(before) == .lt);
    try content.handleEvent(&ctx, press(.release, 0, 0));
    const first_row = 40 - @as(usize, shown) - 2;
    var expected: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "row {d}\nrow {d}\nrow {d}\nrow", .{ first_row, first_row + 1, first_row + 2 }), Clip.take(&ctx, &copied));
    _ = try widget_.draw(draw_context);
    try std.testing.expect(self.app_content.first.order(screen.live.bottom(.{ .width = 80, .method = self.app_caps.width }, shown)) == .eq);
    // A transcript at its top reads an older page in, but not under a
    // press or drag: that waits for the release.
    screen.view = .transcript;
    defer screen.view = .live;
    try std.testing.expect(self.idleReader().at_top);
    try content.handleEvent(&ctx, press(.press, 0, 0));
    try std.testing.expect(!self.idleReader().at_top);
}

test "App Session link click leaves for the peer only where Esc would leave" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    init.environ_map = &environ;
    var interrupted: client.Cancellation = .{};
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
    const Hooks = struct {
        var opened: ?[session_id.bytes]u8 = null;
        var left: ?Outcome = null;
        fn leave(_: *anyopaque, _: *vxfw.EventContext, outcome: Outcome) !void {
            // The overview hears which Session to open before the leave.
            std.debug.assert(opened != null);
            left = outcome;
        }
        fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
            return error.UnexpectedCopy;
        }
        fn open(_: *anyopaque, _: *vxfw.EventContext, id: *const [session_id.bytes]u8) !void {
            opened = id.*;
        }
    };
    Hooks.opened = null;
    Hooks.left = null;
    var root: Root = .{ .overview = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    try screen.live.append("\x1b[2;8m← Received message from " ++ TerminalText.link_open ++ TerminalText.session_link ++ "m3n4p5" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m\x1b[0m\n");
    _ = try widget_.draw(draw_context);
    const content = self.app_content.widget();
    const click = struct {
        fn on(context: *vxfw.EventContext, target: vxfw.Widget, col: i16) !void {
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try target.handleEvent(context, .{ .mouse = .{ .col = col, .row = 0, .button = .left, .mods = .{}, .type = kind } });
        }
    }.on;
    // "Plan" is at columns 24 to 27. With a draft, the click is refused as
    // Esc is, and the Session and its draft stay as they were.
    _ = self.input.append("keep me");
    try click(&ctx, content, 25);
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", self.notice.?);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    try std.testing.expectEqual(@as(?Outcome, null), self.leaving);
    try std.testing.expectEqualStrings("keep me", self.input.composition().bytes);
    // Beside the name nothing opens.
    self.input.init();
    self.notice = null;
    try click(&ctx, content, 10);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    // On the name, with nothing to lose, the Session leaves for the peer.
    try click(&ctx, content, 25);
    try std.testing.expectEqualStrings("m3n4p5", &Hooks.opened.?);
    try std.testing.expectEqual(Outcome.returned, Hooks.left.?);
}

test "App Session Ctrl-O follows the lowest drawn peer name, or opens the lower Message" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    init.environ_map = &environ;
    var interrupted: client.Cancellation = .{};
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
    const Hooks = struct {
        var opened: ?[session_id.bytes]u8 = null;
        var leaves: usize = 0;
        fn leave(_: *anyopaque, _: *vxfw.EventContext, _: Outcome) !void {
            leaves += 1;
        }
        fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
            return error.UnexpectedCopy;
        }
        fn open(_: *anyopaque, _: *vxfw.EventContext, id: *const [session_id.bytes]u8) !void {
            opened = id.*;
        }
    };
    Hooks.opened = null;
    Hooks.leaves = 0;
    var root: Root = .{ .overview = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const peer = "\x1b[2;8m← Received message from " ++ TerminalText.link_open ++ TerminalText.session_link ++ "m3n4p5" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m\x1b[0m\n";
    const ctrl_o: vxfw.Event = .{ .key_press = .{ .codepoint = 'o', .mods = .{ .ctrl = true } } };
    // A collapsed Message above, its block kept, and a peer row below it.
    try screen.live.append("\n› " ++ View.Mark.body ++ "preview\n" ++ View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n");
    self.live.blocks.append(.{ .source = .conversation, .position = 0, .ordinal = 1, .content = undefined, .row = false });
    try screen.live.append(peer);
    // While an Action waits, Ctrl-O opens no peer: the Action's card
    // holds the keys, and the Session stays.
    try page.writeStreamingAll(std.testing.io, "$ echo safe\n");
    self.reading.prepared_action = 9;
    self.live.work.first_action = 9;
    try widget_.handleEvent(&ctx, .tick);
    _ = try widget_.draw(draw_context);
    try std.testing.expectEqual(@as(?u64, 9), self.app_consent.drawn);
    try widget_.handleEvent(&ctx, ctrl_o);
    try widget_.handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings("! Ctrl-O opens a message or Session name from the conversation.", self.shown_notice.current(self.nowMs()).?);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    try std.testing.expectEqual(@as(?Outcome, null), self.leaving);
    self.live.work.first_action = null;
    try widget_.handleEvent(&ctx, .tick);
    // A Message drawn lower than the name is what Ctrl-O opens.
    try screen.live.append("\n› " ++ View.Mark.body ++ "later\n" ++ View.Mark.summary ++ "┄ 4 more lines" ++ View.Mark.reset ++ "\n");
    self.live.blocks.append(.{ .source = .conversation, .position = 0, .ordinal = 2, .content = undefined, .row = false });
    _ = try widget_.draw(draw_context);
    try widget_.handleEvent(&ctx, ctrl_o);
    try widget_.handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings("Opening message…", self.shown_notice.current(self.nowMs()).?);
    try std.testing.expectEqual(@as(u64, 2), self.expansion.queued.ready.target.ordinal);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    // With the peer row lowest again, Ctrl-O follows the peer, unless the
    // row is too narrow to show any of its name: then the Message above is
    // the lowest thing drawn that Ctrl-O can open.
    self.dropMessageRequest();
    try screen.live.append(peer);
    var narrow = draw_context;
    narrow.max.width = 20;
    _ = try widget_.draw(narrow);
    try widget_.handleEvent(&ctx, ctrl_o);
    try widget_.handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    try std.testing.expectEqualStrings("Opening message…", self.shown_notice.current(self.nowMs()).?);
    try std.testing.expectEqual(@as(u64, 2), self.expansion.queued.ready.target.ordinal);
    self.dropMessageRequest();
    _ = try widget_.draw(draw_context);
    try widget_.handleEvent(&ctx, ctrl_o);
    try widget_.handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings("m3n4p5", &Hooks.opened.?);
    try std.testing.expectEqual(Outcome.returned, self.leaving.?);
    // The Session leaves once: the screen opens the peer on that leave, so
    // a second one would leave the peer too.
    try std.testing.expectEqual(@as(usize, 1), Hooks.leaves);
}

/// A Session's input starts empty, and no frame of it has drawn a list yet:
/// the screen's list was the previous Session's, at revisions this input
/// counts again.
fn startInput(self: *Self) void {
    self.input.init();
    self.input.complete(.{ .context = self, .add = tabCompletion });
    self.screen.commands = null;
}

/// Where Esc leads once the frontend stopped.
pub const Back = union(enum) {
    /// The overview, which names the original left unconfirmed, if any,
    /// until it ends and then prints its recovery.
    overview: original_state.Recovery,
    /// The ending of a normal `leave` instead.
    ended: anyerror!Outcome,
};

/// After the Session left with `returned`, which Esc only asks for: settles the
/// stopped borrowers as `leave` does, while the terminal stays lent. Esc
/// needs no running command or submission, so they observe their stop
/// within one transport poll. A rejected original is released as /discard
/// does. An unconfirmed one goes to the overview while it has `room` for
/// it; otherwise, or on a failure, the frontend leaves as `leave` would.
pub fn back(self: *Self, room: bool) Back {
    std.debug.assert(self.leaving == .returned);
    const plan = departure.exit(self.settle({}), null, false);
    if (plan.failure) |err| return .{ .ended = err };
    if (self.reading.pending_diagnostic != null) return .{ .ended = .detached };
    if (self.submission.view()) |held| if (held.state == .rejected) self.submission.discardRejected() catch unreachable;
    const recovery: original_state.Recovery = if (self.submission.view() != null) self.submission.recovery() else .none;
    if (recovery != .none and !room) return .{ .ended = .detached };
    self.submission.close();
    return .{ .overview = recovery };
}

/// What the restored screen shows after `leave`.
pub const Departure = struct {
    /// How the frontend stopped, or the failure the caller returns.
    end: anyerror!Outcome,
    /// The pending Action the Detached notice names, when one was on screen.
    action: ?u64,
    /// A failure still gets the notice when an Action was on screen and the
    /// terminal was restored, so the main screen names the exact commands.
    failure_notice: bool,
    /// The recovery guide is written; otherwise a failed notice writes it.
    recovery_shown: bool,
};

/// Joins what the Session stopped, after the caller restored the terminal, and writes
/// the guidance that follows restoration. The caller prints the Detached notice.
pub fn leave(self: *Self, ended: anyerror!Outcome, restored: anyerror!void) Departure {
    const settled = self.settle(restored);
    self.submission.close();
    if (self.reading.pending_diagnostic != null) {
        var bytes: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        self.writePendingDiagnostic(&out) catch unreachable;
        stderr.diagnostic("rui: Read failed: {s}\n", .{out.buffered()});
    }
    const cause: ?anyerror = if (ended) |_| null else |err| err;
    const plan = departure.exit(settled, cause, self.submission.view() != null);
    if (plan.recovery_before_notice) self.recoveryGuide();
    if (self.inspection.command_running and self.inspection.kind == .command) self.commandOutputGuide();
    if (plan.failure) |err| switch (err) {
        error.TerminalTooSmall => stderr.diagnostic("rui: Enlarge the terminal and resume this Session. Required instructions do not fit; nothing was authorized by the clipped view.\n", .{}),
        error.TerminalTooLarge => stderr.diagnostic("rui: Rui supports at most 49,152 terminal cells (for example 256 × 192). Shrink the terminal and resume; saved content is unchanged.\n", .{}),
        error.OutOfMemory, error.UnrepresentableTerminalGrapheme, error.DisplayGraphemeTooLarge => stderr.diagnostic("rui: This frame exceeds Rui's bounded display. Shrink the terminal and resume; saved content is unchanged. One-shot session, request and action commands remain available.\n", .{}),
        else => {},
    };
    const action_view = self.screen.action_view != null;
    return .{
        .end = if (plan.failure) |err| err else ended,
        .action = if (action_view) self.live.work.first_action else null,
        // Never a main-screen notice before confirmed restoration.
        .failure_notice = action_view and !std.meta.isError(restored),
        .recovery_shown = plan.recovery_before_notice,
    };
}

pub fn stop(self: *Self) void {
    // A running command observes exit as an interruption, exactly as a signal.
    if (self.inspection.command_running) self.interrupted.requestStop();
    self.reader.cancel();
    self.skill_task.cancel();
    self.submission.cancel();
}

fn settle(self: *Self, restored: anyerror!void) Settled {
    const skills_error = self.dropSkills();
    const reader = self.joinReader();
    var admission = self.submission.join();
    self.followAdmission(admission) catch |err| {
        admission = .{ .failed = .{ .err = err } };
    };
    // One Enter asked for the reason and the denial: leaving after the
    // reason was accepted still sends the denial, and waits for it.
    if (self.submission.task.thread != null) admission = self.joinAdmission();
    return .{ .restored = restored, .reader = reader, .admission_error = admission.failure(), .skills_error = skills_error };
}

test "Ctrl-D leaves the Session detached with no notice" {
    for ([_][]const u8{ "\x04", "\x1b[100;5u" }) |key| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        try held.settle();
        try held.keys(key);
        try std.testing.expectEqual(@as(?Outcome, .detached), held.left);
        try std.testing.expect(held.self.notice == null);
    }
}

/// Exit interrupted a Host command before its output was shown. That output
/// can name a saved request to recover, so it follows restoration on stderr.
fn commandOutputGuide(self: *const Self) void {
    // Failed restoration may leave fd 2 pointing at this same scratch file.
    // Drop optional guidance rather than append the page to itself.
    if (!self.job.result.command_stderr_restored) return;
    const io = self.init.io;
    const size = (self.files.inspection.stat(io) catch return).size;
    if (size == 0) return;
    // Optional like every exit diagnostic: a full or stopped stderr drops the
    // rest instead of holding the restored caller.
    if (!stderr.tryAcquire()) return;
    defer stderr.release();
    if (!stderr.writeHeld("rui: Interrupted command output:\n")) return;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const wanted: usize = @intCast(@min(buffer.len, size - offset));
        const count = self.files.inspection.readPositionalAll(io, buffer[0..wanted], offset) catch return;
        if (count == 0 or !stderr.writeHeld(buffer[0..count])) return;
        offset += count;
    }
}

pub fn recoveryGuide(self: *const Self) void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    self.writeRecoveryGuide(&out) catch unreachable;
    if (out.buffered().len != 0) stderr.diagnostic("{s}", .{out.buffered()});
}

fn writeRecoveryGuide(self: *const Self, out: *std.Io.Writer) !void {
    try original_state.writeGuide(self.submission.recovery(), out);
}

test "frontend exit guidance preserves accepted identity and never substitutes it for current intent" {
    const key = "01234567-89ab-4cde-8012-0123456789ab";
    const cases = .{
        .{ Submission.Kind.message, "rui: Message accepted; do not resubmit it. Use rui request read-result " ++ key ++ " for the same Message's answer.\n" },
        .{ Submission.Kind.decision, "rui: Decision accepted; do not repeat it. Use rui request inspect " ++ key ++ " to inspect the same saved admission.\n" },
    };
    inline for (cases) |case| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .accepted = .{ .kind = case[0], .key = key.* } };
        self.submission.close(); // Releasing capture custody cannot erase acceptance.
        var bytes: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        try self.writeRecoveryGuide(&out);
        try std.testing.expectEqualStrings(case[1], out.buffered());
        // A newer unsent original outranks an older accepted identity.
        self.submission.intent = .{ .message = self.input.submitText("new original") };
        out = .fixed(&bytes);
        try self.writeRecoveryGuide(&out);
        try std.testing.expectEqualStrings("rui: Message was not sent: capture did not begin. You may submit it again; no recovery record was published for this attempt.\n", out.buffered());
    }
}

const History = enum { older, latest };

/// What each slash command does here.
const Slash = union(enum) {
    exit,
    archive,
    unarchive,
    history: History,
    /// Waits for the reader, then shows its page; Host commands included.
    inspection: Inspection,
    /// The Session's model and sign-in, which never change.
    model,
    upgrade,
    discard,
    recover: []const u8,
    wait,
    login,
    misused: slash_commands.Name,
    unknown,
};

fn parse(text: []const u8) Slash {
    const command = switch (slash_commands.parse(text)) {
        .unknown => return .unknown,
        .misused => |name| return .{ .misused = name },
        .command => |command| command,
    };
    return switch (command.name) {
        .exit => .exit,
        .archive => .archive,
        .unarchive => .unarchive,
        .history => .{ .history = .older },
        .details => .{ .history = .latest },
        .status => .{ .inspection = .status },
        .requests => .{ .inspection = .requests },
        .help => .{ .inspection = .help },
        // The table's /copy words are `reads.Copy`'s own names.
        .copy => .{ .inspection = .{ .copy = if (command.argument.len == 0) .answer else std.meta.stringToEnum(reads.Copy, command.argument).? } },
        .@"inspect-action", .setup, .configure, .result, .rename, .effort, .@"reload-skills" => .{ .inspection = .command },
        .recover => .{ .recover = command.argument },
        .discard => .discard,
        .wait => .wait,
        .login => .login,
        .model => .model,
        .upgrade => .upgrade,
    };
}

/// The page asked for last is the one shown: a /status not yet rendered
/// yields to a later /history or /details.
fn requestHistory(self: *Self, history: History) void {
    self.transcript.history_requested = history;
    self.inspection.status_requested = false;
}

/// Runs one slash command the draft admitted; it never decides. Local
/// commands answer at once; an inspection queues for the reader.
fn slashCommand(self: *Self, text: []const u8) !void {
    const parsed = parse(text);
    // Lender intents have one admission boundary in converse, shared with
    // shortcuts and confirmation. Other commands retain their own hold policy.
    const admitted_elsewhere = switch (parsed) {
        .archive, .unarchive, .upgrade, .exit, .model => true,
        else => false,
    };
    if (self.upgradeHeld() and !admitted_elsewhere) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return;
    }
    switch (parsed) {
        .upgrade => try self.converse(.upgrade),
        .archive => try self.perform(.archive),
        .unarchive => try self.converse(.unarchive),
        .exit => self.leaving = .detached,
        .history => |history| self.requestHistory(history),
        .inspection => self.input.queueCommand(text),
        .discard => {
            self.submission.discardRejected() catch {
                self.notice = "! Cannot discard an unresolved submission; Ctrl-R recovers the original.";
            };
            if (self.submission.view() == null) self.poll_at = 0;
        },
        .recover => |key| if (self.submission.view() != null) {
            self.recover(key) catch {
                self.notice = "! Recovery key does not match this original submission; nothing sent.";
            };
        } else self.unknownCommand(text),
        .wait => self.notice = "Work continues while you compose.",
        .login => {
            // The Session's own provider, else the one that signs in.
            const provider = self.line.provider orelse comptime protocol.Provider.onlyWith(.sign_in);
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            writer.print("Login uses {s} in your shell.", .{provider.login()}) catch unreachable;
            self.notice = writer.buffered();
        },
        .model => self.notice = self.modelFacts(),
        .misused => |name| {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            writer.print("! Usage: {s}", .{slash_commands.usage.get(name)}) catch unreachable;
            self.notice = writer.buffered();
        },
        .unknown => self.unknownCommand(text),
    }
}

const model_tail = " · new Session: /model in overview";
const unknown_sign_in = "sign-in unknown";

/// The Session's model and sign-in, first, so a narrow screen cuts only
/// the tail. A Session keeps both for life, so a different model starts a
/// new Session from the overview's /model.
fn modelFacts(self: *Self) []const u8 {
    if (self.line.read == null) return "The model shows once the Session is read.";
    var writer = std.Io.Writer.fixed(&self.notice_buffer);
    writer.print("{s} · {s}" ++ model_tail, .{ self.line.model.slice(), if (self.line.provider) |provider| provider.signIn() else unknown_sign_in }) catch unreachable;
    return writer.buffered();
}

fn unknownCommand(self: *Self, text: []const u8) void {
    self.notice = slash_commands_shared.unknown(self.notice_buffer[0..slash_commands_shared.unknown_bytes], text);
}

test "frontend answers local and unknown commands in place and keeps Host commands for inspection" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    const cases = .{
        .{ "/foo bar", "! Unknown command /foo · /help" },
        .{ "/\x1b[2J", "! Unknown command · /help" },
        .{ "/result", "! Usage: /result KEY" },
        .{ "/rename", "! Usage: /rename NAME" },
        .{ "/rename lane four", "" },
        .{ "/effort", "! Usage: /effort LEVEL" },
        .{ "/effort high", "" },
        .{ "/recover 01234567-89ab-4cde-8012-0123456789ab", "! Unknown command /recover · /help" },
        .{ "/wait", "Work continues while you compose." },
        .{ "/model", "The model shows once the Session is read." },
        .{ "/model gpt-5.5", "! Usage: /model" },
        .{ "/configure --permission-mode ask", "" },
        .{ "/result 01234567-89ab-4cde-8012-0123456789ab", "" },
        .{ "/inspect-action", "" },
        .{ "/archive other", "! Usage: /archive" },
        .{ "/unarchive other", "! Usage: /unarchive" },
        .{ "/status", "" },
        .{ "/copy", "" },
        .{ "/copy code", "" },
        .{ "/copy file", "" },
        .{ "/copy all", "! Usage: /copy [code|file]" },
    };
    inline for (cases) |case| {
        self.notice = null;
        try self.slashCommand(case[0]);
        if (case[1].len != 0) {
            try std.testing.expectEqualStrings(case[1], self.notice.?);
            try std.testing.expect(self.input.queuedCommand() == null);
        } else {
            try std.testing.expect(self.notice == null);
            try std.testing.expectEqualStrings(case[0], self.input.takeCommand().?);
        }
    }
}

test "frontend /model shows the Session's model and sign-in within 60 columns and offers no pick" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
    self.input.init();
    for ([_][]const u8{ "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5" }) |id| for ([_]?protocol.Provider{ .codex, .openai, null }) |provider| {
        self.line = .{ .read = .{ .revision = 1, .end = 1 }, .provider = provider };
        try self.line.model.set(id);
        self.notice = null;
        try self.slashCommand("/model");
        const said = self.notice.?;
        // The model, then the sign-in, lead the line.
        try std.testing.expect(std.mem.startsWith(u8, said, id));
        const rest = said[id.len..];
        if (provider) |known| {
            try std.testing.expect(std.mem.indexOf(u8, rest, known.signIn()) != null);
            try std.testing.expect(std.unicode.utf8CountCodepoints(said) catch unreachable <= 60);
        } else for (std.enums.values(protocol.Provider)) |other| try std.testing.expect(std.mem.indexOf(u8, rest, other.signIn()) == null);
        // A sign-in is never dropped silently: something stands in its place.
        try std.testing.expect(!std.mem.startsWith(u8, std.mem.trimStart(u8, rest[" · ".len..], " "), "new Session"));
        try std.testing.expect(self.input.queuedCommand() == null);
        try std.testing.expectEqualStrings(id, self.line.model.slice());
    };
}

test "a Session lists the skills it saved for the caret's /word, and Tab or Enter on a drawn row replaces the name" {
    const Fake = struct {
        var calls: usize = 0;
        var session: [6]u8 = undefined;
        fn read(_: client.Requests, gpa: std.mem.Allocator, _: []const u8, reference: []const u8, prefix: []const u8) !skill_suggestions.Page {
            calls += 1;
            @memcpy(&session, reference);
            const entries = try gpa.alloc(skill_suggestions.Entry, 2);
            entries[0] = .{ .name = try gpa.dupe(u8, "recap"), .description = try gpa.dupe(u8, "Summarise") };
            entries[1] = .{ .name = try gpa.dupe(u8, "review"), .description = try gpa.dupe(u8, "Review a change") };
            try std.testing.expectEqualStrings("", prefix);
            return .{ .entries = entries, .total = 2 };
        }
        /// App's ticks until the worker's page is in and drawn.
        fn answered(held: *HeldFrontend) !void {
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &held.self, struct {
                fn done(self: *Self) bool {
                    return self.skill_task.completed();
                }
            }.done);
            try held.settle();
            try std.testing.expect(held.self.skill_task.thread == null);
        }
    };
    Fake.calls = 0;
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.session = "k7m2qx";
    held.self.skill_read = Fake.read;
    // The draft's first word makes it a command line, which Enter runs:
    // no skill is read or listed there.
    try held.keys("/re");
    try std.testing.expect(held.self.skill_task.thread == null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "/recap") == null);
    try held.keys("\x15");
    // So are its arguments: Enter sends the whole line as the command.
    try held.keys("/rename /re");
    try held.settle();
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "/recap") == null);
    try held.keys("\x15");
    // The draft Q2 typed in a real terminal: the caret moved back to just
    // after `/re`, in the middle of a Message. The page comes in while the
    // caret is in the word; one that came in after it left would be
    // dropped and read again.
    try held.keys("please /re");
    try Fake.answered(held);
    try held.keys(" now\x1b[D\x1b[D\x1b[D\x1b[D");
    try held.settle();
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expectEqualStrings("k7m2qx", &Fake.session);
    var shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "/recap") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Review a change") != null);
    // The page held every skill: narrowing reads nothing and lists fewer.
    try held.keys("v");
    try held.settle();
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "/recap") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Review a change") != null);
    // Mid-draft, Tab replaces the caret's name, adds no space and leaves
    // the caret after it.
    try held.keys("\t");
    try std.testing.expectEqualStrings("please /review now", held.self.input.composition().bytes);
    try std.testing.expectEqual("please /review".len, held.self.input.composition().cursor);
    // At the draft's end, Enter on the drawn row puts the highlighted skill
    // in with a space, and sends nothing.
    try held.keys("\x1b[F and /");
    try held.settle();
    try held.keys("\r");
    try std.testing.expectEqualStrings("please /review now and /recap ", held.self.input.composition().bytes);
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "a Session's /reload-skills drops the skills it listed, and the next read lists the reloaded catalog" {
    const Fake = struct {
        var reloaded = false;
        var calls: usize = 0;
        fn read(_: client.Requests, gpa: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !skill_suggestions.Page {
            calls += 1;
            const entries = try gpa.alloc(skill_suggestions.Entry, 1);
            entries[0] = .{ .name = try gpa.dupe(u8, if (reloaded) "release" else "recap"), .description = try gpa.dupe(u8, "") };
            return .{ .entries = entries, .total = 1 };
        }
        fn done(self: *Self) bool {
            return self.skill_task.completed();
        }
        fn command(_: *anyopaque, _: *Task) !void {}
    };
    Fake.reloaded = false;
    Fake.calls = 0;
    const io = std.testing.io;
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.skill_read = Fake.read;
    try held.keys("use /r");
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &held.self, Fake.done);
    try held.settle();
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "/recap") != null);
    // `/reload-skills` settles as its command read does, with a short
    // reply, after the catalog changed.
    Fake.reloaded = true;
    const reply = try held.tmp.dir.createFile(io, "reloaded", .{ .read = true });
    defer reply.close(io);
    try reply.writePositionalAll(io, "Skills reloaded.\n", 0);
    held.self.files.inspection = reply;
    held.self.reading.phase = .inspection;
    held.self.inspection.kind = .command;
    held.self.inspection.command_running = true;
    const line = "/reload-skills";
    @memcpy(held.self.job.command_text[0..line.len], line);
    held.self.job.command_text_length = line.len;
    try held.self.reader.start(io, &held.self, Fake.command);
    while (!held.self.reader.completed()) std.Thread.yield() catch {};
    try held.self.settleReader();
    // The caret still in `/r` reads the reloaded catalog, which replaces
    // the rows.
    try held.settle();
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &held.self, Fake.done);
    try held.settle();
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);
    const shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "/release") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "/recap") == null);
}

test "frontend lists the efforts of the Session's model once it is read, the one in force marked" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
    self.input.init();
    _ = self.input.typed("/effort ");
    try std.testing.expectEqualStrings("/effort ", self.input.composition().bytes);
    try std.testing.expect(self.nextCommands(null) == null);
    self.line = .{ .read = .{ .revision = 1, .end = 1 }, .effort = .medium };
    try self.line.model.set("gpt-5.5");
    var shown = self.nextCommands(null).?;
    try std.testing.expectEqualStrings("none", shown.list.shown()[0].word);
    try std.testing.expectEqualStrings("current", shown.list.shown()[2].description);
    // Down moves the highlight, which the next frame keeps and Tab puts in
    // the draft.
    shown.move(true);
    shown.move(true);
    shown = self.nextCommands(shown).?;
    try std.testing.expectEqualStrings("medium", shown.completion());
    // Typing moves it back to the first.
    _ = self.input.typed("m");
    try std.testing.expectEqualStrings("/effort m", self.input.composition().bytes);
    shown = self.nextCommands(shown).?;
    try std.testing.expectEqualStrings("edium", shown.completion());
}

test "frontend consumed canonical reader and admission failures survive external interruption" {
    const Worker = struct {
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.CanonicalStoreFailure;
        }
    };
    for ([_]bool{ false, true }) |admission| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
        const failure: anyerror = blk: {
            if (admission) {
                self.submission.intent = .{ .message = self.input.submitText("original B") };
                try self.submission.task.start(std.testing.io, &self, Worker.fail);
                if (self.joinAdmission().failure()) |err| break :blk err;
            } else {
                try self.reader.start(std.testing.io, &self, Worker.fail);
                self.settleReader() catch |err| break :blk err;
            }
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(error.CanonicalStoreFailure, failure);
    }
}

test "a skills read's canonical failure survives leaving the Session" {
    const Worker = struct {
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.CanonicalStoreFailure;
        }
    };
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false, .leaving = .returned };
    self.init.io = std.testing.io;
    self.init.gpa = std.testing.allocator;
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    // The read failed as Esc returned, before any frame answered it.
    try self.skill_task.start(std.testing.io, &self.skill_job, Worker.fail);
    while (!self.skill_task.completed()) std.Thread.yield() catch {};
    self.stop();
    const failure: ?anyerror = switch (self.back(true)) {
        .overview => null,
        .ended => |ending| if (ending) |_| error.TestUnexpectedResult else |err| err,
    };
    try std.testing.expectEqual(@as(?anyerror, error.CanonicalStoreFailure), failure);
}

test "Esc goes back to the overview only when the joined reader leaves nothing to show" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *Task) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.CanonicalStoreFailure;
        }
    };
    for ([_]struct { Task.Run, ?anyerror }{ .{ Worker.read, null }, .{ Worker.fail, error.CanonicalStoreFailure } }) |case| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false, .leaving = .returned };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
        // The reader is still running as Esc returns.
        try self.reader.start(std.testing.io, &self, case[0]);
        self.stop();
        const failure: ?anyerror = switch (self.back(true)) {
            .overview => null,
            .ended => |ending| if (ending) |_| error.TestUnexpectedResult else |err| err,
        };
        try std.testing.expectEqual(case[1], failure);
    }
}

test "Esc hands an unconfirmed original to the overview while it has room, and releases a rejected one" {
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const Case = struct { state: Submission.State, room: bool };
    for ([_]Case{
        .{ .state = .unconfirmed, .room = true },
        .{ .state = .unconfirmed, .room = false },
        .{ .state = .rejected, .room = true },
        .{ .state = .rejected, .room = false },
    }) |case| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false, .leaving = .returned };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = self.input.submitText("original A") }, .state = case.state, .publication = .published, .key = key };
        const went = self.back(case.room);
        if (case.state == .rejected) {
            // Released whatever the room: nothing is left to recover.
            try std.testing.expectEqual(original_state.Recovery.none, went.overview);
            try std.testing.expectEqual(@as(?Submission.View, null), self.submission.view());
        } else if (case.room) {
            try std.testing.expectEqual(original_state.Recovery{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } }, went.overview);
        } else {
            // No room: the frontend leaves as Ctrl-C would, printing it.
            try std.testing.expectEqual(Outcome.detached, try went.ended);
        }
    }
}

/// The Upgrade as this conversation meets it.
fn upgradePhase(self: *const Self) session_upgrade.Phase {
    return self.lender.upgrade(self.lender.context).phase(self.upgrade_stale);
}

/// Host requests wait: on the Upgrade, or on this conversation's next read.
fn upgradeHeld(self: *const Self) bool {
    return self.upgradePhase() != .active;
}

/// No Client work of this conversation's is in flight, so an Upgrade's run
/// may start. A command's read still running is joined before this holds.
pub fn atRest(self: *const Self) bool {
    return self.reader.thread == null and self.submission.task.thread == null and self.skill_task.thread == null;
}

/// Settles this conversation's Client work for an Upgrade's run. The
/// overview starts the run once `atRest` says so. No command waits its
/// turn here: /upgrade is admitted only while none does, and the run's
/// hold refuses every command after it, so only a running one is left to
/// finish.
fn quiesceUpgrade(self: *Self) !void {
    std.debug.assert(self.input.queuedCommand() == null);
    self.upgrade_stale = true;
    self.submission.retry = null;
    self.submission.cancel();
    if (self.submission.task.thread != null and self.submission.task.completed()) {
        const end = self.submission.join();
        try self.followAdmission(end);
        if (end.failure()) |err| if (err != error.Cancelled) return err;
    }
    if (self.reader.thread != null) {
        if (!self.inspection.command_running) self.reader.cancel();
        if (self.reader.completed()) try self.settleReader();
    }
    if (self.reading.pending_diagnostic != null and self.reader.thread == null) try self.presentReadDiagnostic(self.screen);
    if (self.dropSkills()) |err| return err;
}

fn startQueuedCommand(self: *Self) !void {
    if (self.reader.thread == null) if (self.input.takeCommand()) |text| {
        const kind = parse(text).inspection;
        try self.leaveFor(kind);
        self.inspection.kind = kind;
        // The worker borrows its own copy; the editor may queue another.
        const job = self.freeze(.inspection);
        @memcpy(job.command_text[0..text.len], text);
        job.command_text_length = text.len;
        job.inspection_submission = self.submission.view();
        const consent = self.screen.consent;
        job.inspection_action = if (consent) |pending| (if (pending.presentation == .preview) pending.action else null) else null;
        // The newer inspection replaces a /status not yet shown.
        self.inspection.status_requested = false;
        try self.launch(job, switch (kind) {
            .command => reads.runCommand,
            .copy => reads.copyAnswer,
            else => reads.inspectPage,
        });
        self.inspection.command_running = true;
    };
}

const Updated = enum { active, waiting, retry };

fn update(self: *Self) !Updated {
    if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
    // An Upgrade's pass ends with a frame and a wait even when the run
    // ends or the read settles; Host work resumes on the next.
    const phase = self.upgradePhase();
    switch (phase) {
        .quiescing => self.quiesceUpgrade() catch |err| {
            if (err == error.CanonicalStoreFailure) return err;
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            try writer.print("! Upgrade could not settle Client work: {s}. Draft and original retained; /upgrade to retry.", .{@errorName(err)});
            self.notice = writer.buffered();
            self.dirty = true;
            try self.lender.step(self.lender.context, self.shownWork(), .upgrade_failed);
            return .retry;
        },
        .blocked => if (self.notice == null) {
            self.notice = session_upgrade.refusal(self.upgradePhase());
        },
        .reobserving => {
            if (self.reader.thread != null and self.reader.completed()) {
                self.settleReader() catch |err| {
                    if (err == error.CanonicalStoreFailure) return err;
                    var writer = std.Io.Writer.fixed(&self.notice_buffer);
                    try writer.print("! Reattach failed: {s}. Draft and original retained; /upgrade or reopen with selected Rui.", .{@errorName(err)});
                    self.notice = writer.buffered();
                    try self.lender.step(self.lender.context, self.shownWork(), .upgrade_failed);
                };
                self.withdrawDecided();
            }
            if (self.upgradePhase() == .reobserving and self.reader.thread == null) try self.launch(self.freeze(.activity), reads.scan);
        },
        .active => {},
    }
    if (phase != .active) return .waiting;
    try self.admit();
    if (self.input.queuedCommand()) |text| if (parse(text).inspection == .status) {
        // /status is the next scan's: one capture for the page, the
        // history and the composer status.
        _ = self.input.takeCommand();
        try self.screen.latest();
        self.inspection.status_requested = true;
        self.inspection.selected = status_page.first;
        self.poll_at = 0;
    };
    if (self.input.queuedCommand() != null and self.reader.thread != null and !self.reader.completed()) {
        // No read shows anything before it joins, so an inspection
        // supersedes it. Keep servicing input until completion; never join
        // unfinished work in raw mode.
        self.reader.cancel();
    }
    // A joined read may hide or withdraw the Action.
    if (self.reader.thread != null and self.reader.completed()) {
        try self.settleReader();
        self.withdrawDecided();
    }
    if (self.reading.pending_diagnostic) |pending| {
        if (pending.recoverable) try self.presentReadDiagnostic(self.screen);
    }
    try self.startQueuedCommand();
    // Scans continue during consent, so an Action decided elsewhere leaves.
    if (self.reader.thread == null and self.reading.prepared_action == null) {
        if (self.transcript.history_requested != null and !self.reading.opening) {
            const requested = self.transcript.history_requested.?;
            self.transcript.history_requested = null;
            if (requested == .latest) {
                try self.screen.latest();
                self.admission.details_sent = self.admission.sent;
                try self.launch(self.freeze(.details), reads.history);
            } else {
                // /history scrolls the transcript to its top; older pages
                // then load there as for any scroll.
                const screen = self.screen;
                if (screen.view != .transcript) {
                    try screen.latest();
                    if (screen.view == .live) try self.beginTranscript();
                }
                if (screen.view == .transcript) screen.browsing.top = .{} else self.notice = "/history opens once the Action is decided.";
                self.dirty = true;
            }
        }
        if (self.reader.thread == null and self.expansion.queued == .ready) {
            const request = self.expansion.queued.ready;
            self.expansion.queued = .none;
            self.expansion.reading = request;
            const job = self.freeze(.message);
            job.target = .{ .message = request.target };
            try self.launch(job, reads.fullMessage);
        }
        if (self.reader.thread == null and !self.reading.opening) if (self.input.nextStep()) |recall| {
            const job = self.freeze(.recall);
            job.recall = recall;
            try self.launch(job, reads.recall);
        };
        if (self.reader.thread == null) if (reader_policy.background(self.idleReader())) |read| switch (read) {
            .history => {
                self.notice = "Loading earlier messages…";
                try self.launch(self.freeze(.history), reads.history);
            },
            .activity => try self.launch(self.freeze(.activity), reads.scan),
            .permission => try self.launch(self.freeze(.permission), reads.permission),
        };
    }
    return .active;
}

/// The list above the draft as it is now, after `previous`: the commands
/// its command word starts, or the choices for the word typed after one.
/// Null when nothing matches.
fn nextCommands(self: *Self, previous: ?slash_commands_shared.Shown) ?slash_commands_shared.Shown {
    // The Session's model offers its efforts once a read names it.
    const context: slash_commands_shared.Context = if (self.line.read != null) .{ .model = self.line.model.slice(), .effort = self.line.effort } else .{};
    const draft = self.input.composition().bytes;
    if (draft.len != 0) return self.skills.shown(&self.skill_rows, draft, self.input.composition().cursor, self.input.revision, slash_commands.suggest(draft, context), previous);
    // The rows change without the draft: other rows are another list.
    const rows = self.requestList() orelse return null;
    var named = std.hash.Wyhash.init(0);
    for (rows.shown()) |entry| {
        named.update(entry.word);
        named.update("\n");
    }
    return slash_commands_shared.Shown.nextOf(previous, self.input.revision, named.final(), rows);
}

/// The rows of the /requests page on screen, which an empty draft lists:
/// the original's /recover while it can be retried now, then each saved
/// Message's /result.
fn requestList(self: *Self) ?slash_commands_shared.List {
    if (self.screen.view != .inspection or self.inspection.kind != .requests or self.inspection.status != null) return null;
    const lead = if (self.recoverable()) |key| slash_commands_shared.recoverEntry(&self.recover_line, key) else null;
    return self.saved_requests.list(lead);
}

/// The original a /recover row retries: a plain unconfirmed Message,
/// nothing in flight, and no Action waiting, at which Ctrl-R and /recover
/// retry nothing.
fn recoverable(self: *const Self) ?*const [36]u8 {
    if (self.screen.consent != null) return null;
    return self.submission.unconfirmedMessage();
}

/// Ctrl-R, or /recover with the original's key: retries the original,
/// except while an Action waits, which only its choice decides.
fn recover(self: *Self, key: ?[]const u8) !void {
    if (self.waitingAction()) |action| {
        self.notice = session_notice.decision(action);
        return;
    }
    try self.submission.requestRecovery(key);
}

/// The draft's list, which Enter, Esc and the arrows act on when the latest
/// frame drew a list.
fn shownCommands(self: *Self) ?*slash_commands_shared.Shown {
    const stored = &self.screen.commands;
    return slash_commands_shared.Shown.drawnNow(stored, self.nextCommands(stored.*));
}

/// Tab: the rest of the highlighted entry's word in the draft's list,
/// shown, hidden or closed; null for a draft no list is for, which takes
/// the tab.
fn tabCompletion(context: *const anyopaque, draft: []const u8, caret: usize) ?Editor.Replacement {
    // The editor lends back the frontend `startInput` registered, whose
    // rows' lines this writes.
    const self: *Self = @ptrCast(@alignCast(@constCast(context)));
    if (draft.len == 0) {
        const rows = self.nextCommands(self.screen.commands) orelse return null;
        return .append(draft, rows.completion());
    }
    const shown = self.nextCommands(self.screen.commands) orelse
        return if (slash_commands.suggest(draft, .{}) != null) .append(draft, "") else null;
    const change = skill_completion.edit(draft, caret, &shown);
    return .{ .start = change.start, .end = change.end, .text = change.text };
}

/// The instructions always fit; a long context line is shortened, on a
/// UTF-8 boundary, rather than pushing them out of the status region.
/// The most bytes the status lines take.
const status_capacity = 2048;

fn statusLines(buffer: *[status_capacity]u8, context: []const u8, base: []const u8, archive_state: protocol.SessionArchiveState) []const u8 {
    std.debug.assert(base.len <= 256);
    var status = std.Io.Writer.fixed(buffer);
    const badge = status_page.archiveBadge(archive_state);
    const room = buffer.len - base.len - (if (badge) |text| text.len else 0) - "\n… · ".len;
    var context_line = context;
    if (context_line.len > room) {
        var end = room;
        while (end > 0 and (context_line[end] & 0xc0) == 0x80) end -= 1;
        context_line = context_line[0..end];
    }
    if (context_line.len != 0) {
        status.writeAll(context_line) catch unreachable;
        if (context_line.len < context.len) status.writeAll("…") catch unreachable;
    }
    if (badge != null or base.len != 0) {
        if (status.buffered().len != 0) status.writeAll("\n") catch unreachable;
        if (badge) |text| {
            status.writeAll(text) catch unreachable;
            if (base.len != 0) status.writeAll(" · ") catch unreachable;
        }
        status.writeAll(base) catch unreachable;
    }
    return status.buffered();
}

test "status lines keep the instructions beside an oversized context" {
    var buffer: [status_capacity]u8 = undefined;
    // A context whose cut falls inside a two-byte scalar.
    var context: [4000]u8 = undefined;
    for (0..context.len / 2) |index| context[index * 2 ..][0..2].* = "é".*;
    const lines = statusLines(&buffer, &context, "Sent", .active);
    try std.testing.expect(std.mem.endsWith(u8, lines, "…\nSent"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(lines));
    try std.testing.expectEqualStrings("Sent", statusLines(&buffer, "", "Sent", .active));
    try std.testing.expectEqualStrings("? Delete /w\nSent", statusLines(&buffer, "? Delete /w", "Sent", .active));
}

test "archive badges keep submission status and whole instructions beside oversized context" {
    var buffer: [status_capacity]u8 = undefined;
    var context: [4000]u8 = undefined;
    for (0..context.len / 2) |index| context[index * 2 ..][0..2].* = "é".*;
    for ([_]struct { state: protocol.SessionArchiveState, expected: []const u8 }{
        .{ .state = .active, .expected = "Sent" },
        .{ .state = .archiving, .expected = "Stopping and archiving · Sent" },
        .{ .state = .archived, .expected = "Archived · /unarchive · Sent" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, statusLines(&buffer, "", "Sent", case.state));
        const text = statusLines(&buffer, &context, "Sent", case.state);
        try std.testing.expect(std.mem.endsWith(u8, text, case.expected));
        try std.testing.expect(std.mem.indexOf(u8, text, "…\n") != null);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
    try std.testing.expectEqualStrings("Stopping and archiving", statusLines(&buffer, "", "", .archiving));
    try std.testing.expectEqualStrings("Archived · /unarchive", statusLines(&buffer, "", "", .archived));
}

/// Another client decided, or the Turn ended: the choice can no longer decide.
/// It leaves before more input is read, so no key decides.
fn withdrawDecided(self: *Self) void {
    const pending = self.screen.consent orelse return;
    if (self.live.work.first_action == pending.action) return;
    self.screen.withdrawAction();
}

/// Sends a Message, alone or as the reason an Action is denied.
fn beginMessage(self: *Self, intent: Submission.Intent) !void {
    if (!try self.beginSubmission(intent)) return;
    // A sent Message continues the conversation: show it and its reply
    // rather than the frozen transcript or page the reader was browsing,
    // or a page asked for before it.
    self.admission.sent += 1;
    self.inspection.status_requested = false;
    self.transcript.history_requested = null;
    self.dropMessageRequest();
    try self.screen.latest();
}

/// A queued or running command holds the choice until it completes.
fn commandActive(self: *const Self) bool {
    return self.upgradeHeld() or self.input.queuedCommand() != null or self.inspection.command_running;
}

/// What a key does in a conversation, beside the draft or an Action's choice.
const ConversationAction = session_keys.Action;
const conversation_keys = session_keys.keys;

fn perform(self: *Self, action: ConversationAction) !void {
    if (self.upgradeHeld() and (action == .recover or action == .expand)) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return;
    }
    const screen = self.screen;
    switch (action) {
        // A shown list takes the arrows, as the overview's model list does.
        .previous, .next => if (self.shownCommands()) |shown| {
            shown.move(action == .next);
            self.dirty = true;
        } else if (!try self.moveSelection(action == .next)) try self.scroll(action == .next, 1),
        // Shift-Up/Down move half a screen; PgUp/PgDn are their aliases.
        .scroll_up, .scroll_down => if (self.shownCommands()) |shown| {
            shown.move(action == .scroll_down);
            self.dirty = true;
        } else try self.scroll(action == .scroll_down, session_chrome.halfScreen(screen.height)),
        .page_up, .page_down => try self.scroll(action == .page_down, session_chrome.halfScreen(screen.height)),
        .older, .newer => if (self.input.press(action == .older) == .typed) {
            self.notice = "Ctrl-P recalls sent messages once the draft is empty.";
        },
        .latest, .close => {
            // Esc is first an Upgrade's that can still change nothing, as
            // on the overview.
            if (action == .close and self.lender.upgrade(self.lender.context).takesEscape()) {
                try self.converse(.cancel_upgrade);
                self.dirty = true;
                return;
            }
            // Esc closes only a list the person saw.
            if (action == .close) if (self.shownCommands()) |shown| {
                shown.close();
                self.dirty = true;
                return;
            };
            // Leaving also abandons a Message page not yet shown, and returns
            // the input row to a waiting Action's choice.
            self.dropMessageRequest();
            screen.moveRow(.selector);
            if (action == .close and self.settledView()) {
                const original: ?Submission.State = if (self.submission.view()) |submission| submission.state else null;
                switch (session_notice.close(original, self.submission.published(), self.input.composition().bytes.len == 0)) {
                    .leave => {
                        self.leaving = .returned;
                        return;
                    },
                    .stay => |why| self.notice = why,
                }
            }
            if (action != .latest and screen.view == .message) try screen.leaveMessage() else try screen.latest();
        },
        .expand => if (screen.view == .message) try screen.leaveMessage() else {
            // A newer Ctrl-O replaces any page asked for before it, even
            // before its own target is found, or if none is.
            self.dropMessageRequest();
            self.expansion.queued = .after_frame;
        },
        .detach => self.leaving = .detached,
        // While approval is paused, recovery waits for the Action and the
        // paused draft stays as it is.
        .recover => try self.recover(null),
        // Until the opening read the Session's work is unknown.
        .stop => if (self.reading.opening) {
            self.notice = "Ctrl-X stops the Session once it opens.";
        } else try self.converse(.stop),
        .archive => if (self.reading.opening) {
            self.notice = "Archive is available once the Session opens.";
        } else try self.converse(.{ .archive = self.line.archive_state }),
    }
    self.dirty = true;
}

/// Steps the overview with an input here, Ctrl-X or another.
fn converse(self: *Self, input: overview_view.ConversationInput) !void {
    // The Upgrade's own inputs are no Host requests, so no hold refuses them.
    const host_intent = switch (input) {
        .other, .upgrade, .cancel_upgrade, .upgrade_failed => false,
        .stop, .archive, .unarchive => true,
    };
    if (host_intent and self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return;
    }
    try self.lender.step(self.lender.context, self.shownWork(), input);
}

/// The work the conversation shows now.
fn shownWork(self: *const Self) protocol.session_work.Kind {
    const now_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
    return self.live.work.state.asOf(now_ms);
}

fn scroll(self: *Self, down: bool, rows: usize) !void {
    const screen = self.screen;
    if (screen.view == .live) {
        if (down) return; // Live output already shows the latest rows.
        try self.beginTranscript();
    }
    self.transcript.older_failed = false; // A new scroll may retry a failed load.
    for (0..rows) |_| if (screen.browse(down, false)) return screen.latest();
}

/// Lands a read recall step on the draft it began from.
fn showRecalled(self: *Self) !void {
    const passed = self.job.result.recall_passed;
    switch (self.input.land(self.job.recall.?, self.job.result.recalled)) {
        .stale => {},
        .oldest => self.notice = if (passed) "No earlier message the draft can hold." else "No earlier message.",
        .emptied => if (passed) {
            self.notice = "Passed over a sent message the draft cannot hold.";
        },
        .show => |found| {
            try self.input.fill(self.init.io, self.files.scratch, found);
            if (passed) self.notice = "Passed over a sent message the draft cannot hold.";
        },
    }
}

/// The latest view with nothing to dismiss: no Action, sub-view or command.
/// Esc leaves it once no submission or draft would be lost.
fn settledView(self: *const Self) bool {
    const screen = self.screen;
    return screen.view == .live and screen.action_view == null and self.live.work.first_action == null and
        self.reading.prepared_action == null and !self.commandActive();
}

const MessageRequest = struct { target: View.Collapsed, asked: reader_policy.Asked };

/// Where a Message page would be asked from now.
fn pagePlace(self: *const Self) reader_policy.Place {
    return switch (self.screen.view) {
        .live => .live,
        .transcript => .{ .transcript = self.transcript.id },
        .inspection, .action, .message => .elsewhere,
    };
}

/// What a Message page asked for now is asked over.
fn pageAsked(self: *const Self) reader_policy.Asked {
    return .{ .place = self.pagePlace(), .sent = self.admission.sent, .generation = self.expansion.generation };
}

/// No Message page asked for so far opens.
fn dropMessageRequest(self: *Self) void {
    self.expansion.generation += 1;
    self.expansion.queued = .none;
}

/// Ctrl-O: opens the lowest collapsed Message the latest frame drew, or
/// returns the peer whose name is drawn lower, for `follow`.
fn expand(self: *Self) !?[session_id.bytes]u8 {
    self.expansion.queued = .none;
    self.dirty = true;
    const screen = self.screen;
    if (self.pagePlace() == .elsewhere) {
        self.notice = "! Ctrl-O opens a message or Session name from the conversation.";
        return null;
    }
    const index = switch (try screen.openableInView(self.init.gpa) orelse {
        self.notice = "Nothing to open in view; scroll to one, then Ctrl-O.";
        return null;
    }) {
        .message => |index| index,
        .session => |id| return id,
    };
    self.openCollapsed(index);
    return null;
}

/// Asks for the collapsed Message `index` from the shown document's end.
fn openCollapsed(self: *Self, index: usize) void {
    const screen = self.screen;
    self.dirty = true;
    const blocks = if (screen.view == .live) &self.live.blocks else &self.transcript.blocks;
    const target = blocks.fromEnd(index) orelse {
        self.notice = "! That message's full text is no longer held here; /history shows it again.";
        return;
    };
    self.expansion.queued = .{ .ready = .{ .target = target, .asked = self.pageAsked() } };
    self.notice = "Opening message…";
}

/// Freezes live output for scrolling. The copy starts at a recorded read
/// boundary, so older canonical pages continue it without a gap. With none
/// retained, the gap's shown Messages and those at its seam are listed above
/// the copy, and older pages continue before the newest boundary that left.
fn beginTranscript(self: *Self) !void {
    const screen = self.screen;
    self.transcript.id += 1;
    const front = try screen.liveStart();
    self.transcript.plan = reads.plan(&self.live.marks, &self.live.echoes, front, self.live.lowest);
    try screen.beginTranscript(self.transcript.plan.start);
    self.transcript.blocks = self.live.blocks.newest(screen.transcriptCollapsed());
    self.transcript.older = self.transcript.plan.older;
    // Without any boundary, where the conversation starts is unknown.
    self.transcript.beginning = self.transcript.older == null and !(self.transcript.plan.gap and self.live.marks.count == 0);
    try self.showOlderLabels();
}

/// Shows the gap's label once its Messages are listed, and the
/// conversation's start once nothing older remains.
fn showOlderLabels(self: *Self) !void {
    const screen = self.screen;
    const plan = &self.transcript.plan;
    if (plan.gap and plan.echo_count == 0 and plan.dropped == null) {
        // A label can push newer rows, and their blocks, off the end.
        self.transcript.blocks.dropNewest(try screen.markGap());
        plan.gap = false;
    }
    if (self.transcript.beginning and self.transcript.plan.next() == null and self.transcript.older == null) {
        self.transcript.blocks.dropNewest(try screen.markBeginning());
        self.transcript.beginning = false;
    }
}

/// What the idle reader may start from, read now.
fn idleReader(self: *const Self) reader_policy.Idle {
    return .{
        .now_ns = std.Io.Clock.awake.now(self.init.io).nanoseconds,
        .scan_due_ns = self.poll_at,
        .opening = self.reading.opening,
        .older_remain = self.transcript.plan.next() != null or self.transcript.older != null,
        .older_failed = self.transcript.older_failed,
        // An older page waits until a press or drag over the text ends.
        .at_top = self.screen.transcriptAtTop() and !self.app_content.dragging(),
        .choice_open = self.screen.consent != null or self.app_consent.request != null,
        .action_named = self.live.work.first_action != null,
        .submission = self.submission.view() != null,
    };
}

/// The waiting Action, as the screen shows it now.
fn waitingAction(self: *const Self) ?session_notice.Action {
    const screen = self.screen;
    const pending = screen.consent orelse return null;
    return .{ .preview = pending.presentation == .preview, .visible = screen.actionVisible(), .reason = screen.liveApproval(self.commandActive()) == .reason };
}

/// The original the submission holds, as the conversation shows it.
fn heldOriginal(self: *const Self) ?session_notice.Held {
    const submission = self.submission.view() orelse return null;
    return .{ .kind = submission.kind, .state = submission.state, .failure = if (self.heldFailure()) |failure| failure.bar else null };
}

/// Enter on a command line, or in a shown list, which takes its highlighted
/// entry: it runs the command that entry completes, or adds the word
/// another follows. Only a list the latest frame drew for this draft: a
/// screen too short for one shows none, and Enter there runs the line as
/// typed.
fn commandLine(self: *Self) !void {
    if (self.shownCommands()) |shown| {
        const taken = shown.list.enter(shown.highlight);
        if (!taken.runs) return self.takeRow(shown);
        switch (self.input.append(taken.rest)) {
            .refused => |why| self.notice = refusedNotice(why),
            else => if (taken.runs) try self.runLine(),
        }
    } else try self.runLine();
}

/// Runs the draft as a command and takes its line. A line a hold refused
/// stays; /upgrade is the hold's own command, so its line is always taken.
fn runLine(self: *Self) !void {
    const text = self.input.composition().bytes;
    const takes = parse(text) == .upgrade or !self.upgradeHeld();
    defer if (takes) self.input.clear();
    try self.slashCommand(text);
}

/// Enter on a Message draft whose list the latest frame drew: takes its
/// highlighted row. A command line's Enter goes to `commandLine`.
fn takeShownRow(self: *Self) bool {
    // A rejected line is the editor's to refuse and clear.
    if (self.input.editors[self.input.active].rejected != null) return false;
    const draft = self.input.composition().bytes;
    if (draft.len == 0 or (draft[0] == '/' and !std.mem.startsWith(u8, draft, "//"))) return false;
    const shown = self.shownCommands() orelse return false;
    self.takeRow(shown);
    return true;
}

/// Enter on a row that runs nothing: its word in place of the caret's
/// `/word` name, or after the command's word, for the next.
fn takeRow(self: *Self, shown: *slash_commands_shared.Shown) void {
    const draft = self.input.composition();
    const change = skill_completion.edit(draft.bytes, draft.cursor, shown);
    switch (self.input.replace(.{ .start = change.start, .end = change.end, .text = change.text })) {
        .refused => |why| self.notice = refusedNotice(why),
        else => {},
    }
}

fn refusedNotice(why: keymap.Refusal) []const u8 {
    return switch (why) {
        .invalid, .edit_rejected => "! Input rejected; nothing sent. Enter plain text or paste again.",
        .unbound => "! Key combination not recognized; ignored. Draft unchanged.",
        .overflow => "! input too long; nothing sent. Draft cleared. Enter a shorter message.",
        .paste_overflow => "! Paste too long; draft unchanged.",
    };
}

/// Joins a completed Admission, or launches a requested retry, and follows
/// its end.
fn admit(self: *Self) !void {
    const admission = try self.submission.advance();
    try self.followAdmission(admission);
    if (admission.failure()) |err| if (err == error.CanonicalStoreFailure) return err;
}

/// Presents an Admission's end. An accepted reason then begins its Action's
/// denial, only after the Message is shown: a denial that cannot start
/// leaves the Message shown and itself retained as not sent.
fn followAdmission(self: *Self, end: AdmissionEnd) !void {
    try self.presentAdmission(end);
    if (end == .accepted) if (end.accepted.denies) |action| {
        _ = try self.beginSubmission(.{ .decision = .{ .action = action, .decision = .deny } });
    };
}

/// The one place a fresh submission starts, a Message or a decision. An
/// Upgrade's hold refuses it and says why; one already in flight settles
/// on its own.
fn beginSubmission(self: *Self, intent: Submission.Intent) !bool {
    const phase = self.upgradePhase();
    if (phase != .active) {
        self.notice = session_upgrade.refusal(phase);
        return false;
    }
    try self.submission.begin(intent);
    return true;
}

fn joinAdmission(self: *Self) AdmissionEnd {
    const end = self.submission.join();
    self.presentAdmission(end) catch |err| return .{ .failed = .{ .err = err } };
    return end;
}

fn presentAdmission(self: *Self, end: AdmissionEnd) !void {
    if (end == .absent) return;
    self.dirty = true;
    self.failure = null;
    switch (end) {
        .accepted => |accepted| {
            self.poll_at = 0;
            if (accepted.confirmed) self.notice = if (accepted.kind == .decision) "  • Decision confirmed." else "  • Original confirmed.";
        },
        .rejected => |rejected| {
            var writer = std.Io.Writer.fixed(&self.failure_buffer);
            var text: TerminalText = .{ .mode = .line };
            try writer.writeAll(if (rejected.kind == .decision) "! Decision rejected: " else "! Input rejected: ");
            try text.feed(&writer, rejected.code.slice());
            try text.finish(&writer);
            try writer.writeAll(rejection_suffix);
            self.holdFailure(.{ .line = writer.buffered(), .key = .discard }, null);
        },
        .failed => |failed| if (failed.err == error.EnvironmentTooLarge) {
            var writer = std.Io.Writer.fixed(&self.failure_buffer);
            try writer.writeAll("! ");
            try self.submission.environment.describeTooLarge(&writer);
            try writer.writeAll(too_large_advice);
            self.holdFailure(.{ .line = session_notice.too_large, .key = .status }, writer.buffered());
        },
        .absent => {},
    }
}

/// Keeps `bar` and `page` for the original the submission holds, in the
/// state the failure left it.
fn holdFailure(self: *Self, bar: session_notice.Failure, page: ?[]const u8) void {
    const held = self.submission.view() orelse return;
    self.failure = .{ .key = held.key, .state = held.state, .bar = bar, .page = page };
}

/// The held original's failure, while it is held as the failure left it.
fn heldFailure(self: *const Self) ?@TypeOf(self.failure.?) {
    const held = self.submission.view() orelse return null;
    const failure = self.failure orelse return null;
    return if (failure.state == held.state and std.mem.eql(u8, &failure.key, &held.key)) failure else null;
}

fn settleReader(self: *Self) !void {
    const end = self.joinReader();
    if (self.reading.phase == .recall and end != .complete) self.input.abandonStep();
    // A fatal failure leaves command output for exit to print.
    if (end.failure(reader_policy.settleMode(self.upgradePhase() == .quiescing, self.input.queuedCommand() != null))) |err| return err;
    const phase = self.reading.phase;
    const inspection = self.readInspection();
    if (end == .complete) switch (reader_policy.shows(phase, inspection)) {
        .older => try self.showOlder(),
        .message => {
            const request = self.expansion.reading.?;
            self.expansion.reading = null;
            if (reader_policy.messageShows(request.asked, self.pageAsked())) try self.screen.showMessage(self.init.io, self.files.inspection);
        },
        .recalled => try self.showRecalled(),
        .staged => try self.showStaged(),
        .copy => try self.showCopy(),
        .page => if (phase != .details or reader_policy.detailsShows(self.admission.details_sent, self.admission.sent)) try self.showInspection(),
    };
    // Shown, or never written: exit no longer prints it.
    if (reader_policy.commandSettled(end == .complete, phase)) self.inspection.command_running = false;
    // A reload changed what this Session's Messages bind: its held skills
    // are stale.
    if (end == .complete and phase == .inspection and inspection == .command) switch (slash_commands.parse(self.job.command_text[0..self.job.command_text_length])) {
        .command => |command| if (command.name == .@"reload-skills") if (self.dropSkills()) |err| return err,
        else => {},
    };
    if (end == .complete and reader_policy.defaultsChanged(phase, inspection, self.statusShown())) {
        self.inspection.defaults = savedDefaults(self.home);
        try self.refreshStatusPage();
    }
    try self.applyReader(end);
}

/// The inspection the joined read ran for, as settling needs it.
fn readInspection(self: *const Self) reader_policy.Inspection {
    return switch (self.inspection.kind) {
        .copy => .copy,
        .command => .command,
        .status, .requests, .help => .other,
    };
}

/// Prepends a completed older page to the transcript it was read for.
fn showOlder(self: *Self) !void {
    // What a seam's search found holds whatever the view now shows.
    if (self.job.result.searched) |floor| if (self.live.lowest) |known| {
        self.live.lowest = @max(known, floor);
    };
    // The user may have left the transcript while this page loaded.
    const screen = self.screen;
    if (screen.view == .transcript and self.job.transcript == self.transcript.id) {
        const prepended = try screen.prependFile(self.init.io, self.files.inspection);
        // The page's newest blocks are those its kept rows show.
        const collapsed = &self.job.result.collapsed;
        var older: [reads.Collected.capacity]?View.Collapsed = @splat(null);
        const kept = @min(prepended.older, older.len);
        for (0..kept) |index| {
            const from_end = kept - index;
            older[index] = if (from_end <= collapsed.count) collapsed.at(collapsed.count - from_end) else null;
        }
        self.transcript.blocks.prepend(older[0..kept]);
        self.transcript.blocks.dropNewest(prepended.trimmed);
        if (self.job.target == .listing) self.transcript.plan.listed(self.job.target.listing, self.job.result.listing) else {
            self.transcript.older = self.job.result.history_cursor;
            self.transcript.beginning = self.transcript.older == null;
        }
        try self.showOlderLabels();
    }
}

/// What the queued row shows, if it shows (see `queued_line.unshown`): the
/// newest waiting Message, by the line read from it, and how many wait
/// that live output has not shown.
pub fn queuedRow(self: *const Self) ?struct { newest: u64, waiting: queued_line.Waiting } {
    const queued = self.live.queued;
    const count = queued_line.unshown(queued.count, queued.oldest_position, self.live.drawn);
    if (count == 0) return null;
    const shown = if (self.live.queued_line) |*shown| shown else return null;
    if (shown.admission != queued.newest_admission) return null;
    return .{ .newest = queued.newest_admission, .waiting = .{ .line = shown.line.slice(), .count = count } };
}

/// Appends a joined read's staged live output; none of it showed before.
/// Its boundaries and echoes take the live offsets where writing reaches
/// them: live output keeps text, not the styling the scratch file also
/// counts, and escapes clusters it cannot show, so each is the settled end
/// once writing reaches it. A page's own start precedes its separator.
fn showStaged(self: *Self) !void {
    const result = &self.job.result;
    self.live.messages = result.messages;
    self.live.entries += result.entries;
    if (result.lowest) |lowest| self.live.lowest = if (self.live.lowest) |known| @min(known, lowest) else lowest;
    var staged: Staged = .{ .frontend = self, .length = result.output_length, .start = try self.screen.liveEnd() };
    // Every cut in output order; at one offset an echo ends before a
    // boundary prunes it, and a boundary prunes before an echo begins.
    const Cut = struct { output: u64, kind: enum { echo_end, boundary, echo_start }, index: usize };
    var cuts: [@typeInfo(@FieldType(reads.Boundaries, "items")).array.len + 2 * @typeInfo(@FieldType(reads.Echoes, "items")).array.len]Cut = undefined;
    var count: usize = 0;
    for (result.boundaries.slice(), 0..) |mark, index| {
        cuts[count] = .{ .output = mark.output, .kind = .boundary, .index = index };
        count += 1;
    }
    for (result.echoes.slice(), 0..) |echo, index| {
        cuts[count] = .{ .output = echo.output, .kind = .echo_start, .index = index };
        cuts[count + 1] = .{ .output = echo.end, .kind = .echo_end, .index = index };
        count += 2;
    }
    std.sort.insertion(Cut, cuts[0..count], {}, struct {
        fn less(_: void, left: Cut, right: Cut) bool {
            return left.output < right.output or (left.output == right.output and @backingInt(left.kind) < @backingInt(right.kind));
        }
    }.less);
    var echoes = result.echoes;
    for (cuts[0..count]) |cut| {
        const offset = try staged.to(cut.output);
        switch (cut.kind) {
            .boundary => {
                const mark = result.boundaries.items[cut.index];
                self.live.marks.record(.{ .offset = offset, .cursor = mark.cursor, .admitted = mark.admitted });
                self.live.echoes.prune(offset);
            },
            .echo_start => echoes.items[cut.index].output = offset,
            .echo_end => {
                var echo = echoes.items[cut.index];
                echo.end = offset;
                if (echo.message.state != .applied) self.live.lowest = if (self.live.lowest) |known| @min(known, echo.position) else echo.position;
                self.live.echoes.add(echo, self.reading.opening);
            },
        }
    }
    _ = try staged.to(staged.length);
    for (0..result.collapsed.count) |index| self.live.blocks.append(result.collapsed.at(index));
    if (staged.length != 0) self.reading.output_started = true;
}

/// Writes staged output to live output up to an output offset.
const Staged = struct {
    frontend: *Self,
    length: u64,
    start: u64,
    written: u64 = 0,
    buffer: [4096]u8 = undefined,

    fn to(self: *Staged, output: u64) !u64 {
        const frontend = self.frontend;
        while (self.written < output) {
            const count = try frontend.files.inspection.readPositionalAll(frontend.init.io, self.buffer[0..@intCast(@min(self.buffer.len, output - self.written))], self.written);
            if (count == 0) return error.TruncatedDisplayScratch;
            // A notice can end the group while a read is still silent. Restore
            // its separator before the first compact heading.
            if (self.written == 0 and !frontend.reading.opening and !frontend.live.compact_tools and self.buffer[0] != '\n') try frontend.screen.append("\n");
            try frontend.screen.append(self.buffer[0..count]);
            self.written += count;
        }
        return if (output == 0) self.start else try frontend.screen.liveEnd();
    }
};

fn joinReader(self: *Self) ReadEnd {
    if (self.reader.thread == null) return .absent;
    const result = self.reader.join();
    const progress: ReadEnd.Progress = .{ .phase = self.reading.phase, .rendering = self.job.result.rendering };
    const end: ReadEnd = if (result) |_| .complete else |err| if (err == error.Cancelled) .{ .cancelled = progress } else .{ .failed = .{ .err = err, .progress = progress } };
    if (self.reader.read_failure) |failure| {
        std.debug.assert(self.reading.pending_diagnostic == null);
        self.reading.pending_diagnostic = .{ .failure = failure, .phase = self.reading.phase, .recoverable = end.preparationFailure() };
        self.reader.read_failure = null;
    }
    return end;
}

fn writePendingDiagnostic(self: *const Self, out: *std.Io.Writer) !void {
    try writeReadDiagnostic(self.reading.pending_diagnostic.?.failure, out);
}

/// The Host's words reach the terminal only as escaped single-line text.
fn writeReadDiagnostic(failure: protocol_reply.ReadFailure, out: *std.Io.Writer) !void {
    try out.print("HTTP {d}; type: ", .{failure.status});
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, failure.diagnostic.type.slice());
    try text.finish(out);
    try out.writeAll("; code: ");
    try text.feed(out, failure.diagnostic.code.slice());
    try text.finish(out);
}

test "read diagnostic shows the Host's type and code as escaped line text" {
    var failure: protocol_reply.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
    try failure.diagnostic.type.set("busy");
    var bytes: [1024]u8 = undefined;
    for ([_][2][]const u8{
        .{ "classification_capacity_exhausted", "HTTP 503; type: busy; code: classification_capacity_exhausted" },
        .{ "other\x1b\n", "HTTP 503; type: busy; code: other\\x1b\\n" },
    }) |case| {
        try failure.diagnostic.code.set(case[0]);
        var out = std.Io.Writer.fixed(&bytes);
        try writeReadDiagnostic(failure, &out);
        try std.testing.expectEqualStrings(case[1], out.buffered());
    }
}

fn presentReadDiagnostic(self: *Self, sink: anytype) !void {
    const pending = self.reading.pending_diagnostic.?;
    self.live.compact_tools = false;
    var bytes: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    const summary = switch (pending.phase) {
        .details => "! Details unavailable; draft retained.",
        .inspection => if (self.inspection.kind == .copy) "! Copy unavailable; draft retained." else "! Inspection unavailable; draft retained.",
        .recall => "! Sent message unavailable; draft retained.",
        else => "! Earlier messages unavailable; scroll up to retry. Draft retained.",
    };
    try out.writeAll(summary);
    try out.writeAll(" ");
    try self.writePendingDiagnostic(&out);
    try sink.append("\n");
    try sink.append(View.Style.failure.code(self.colour));
    try sink.append(out.buffered());
    try sink.append(View.Style.normal.code(self.colour));
    try sink.append("\n");
    // The transcript keeps the details; the notice stays one terse row.
    self.notice = summary;
    self.reading.pending_diagnostic = null;
    self.dirty = true;
}

test "frontend joined read diagnostic survives failed notice and worker reset" {
    const Worker = struct {
        fn fail(_: *anyopaque, task: *Task) !void {
            var failure: protocol_reply.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
            try failure.diagnostic.type.set("busy");
            try failure.diagnostic.code.set("host_busy\x1b\n");
            return task.requests().failRead(failure);
        }
        fn idle(_: *anyopaque, _: *Task) !void {}
    };
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        calls: usize = 0,
        fail_at: ?usize,

        fn append(self: *@This(), bytes: []const u8) !void {
            self.calls += 1;
            if (self.fail_at == self.calls) return error.WriteFailed;
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    for ([_]ReadPhase{ .history, .details }) |phase| {
        for (1..6) |fail_at| {
            var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false, .reading = .{ .phase = phase } };
            self.init.io = std.testing.io;
            self.input.init();
            try self.reader.start(std.testing.io, &self, Worker.fail);
            try self.settleReader(); // Preparation is recoverable, not fatal.
            try std.testing.expect(self.reading.pending_diagnostic != null);
            try std.testing.expect(self.reader.read_failure == null);
            var sink: Sink = .{ .fail_at = fail_at };
            try std.testing.expectError(error.WriteFailed, self.presentReadDiagnostic(&sink));
            try std.testing.expect(self.reading.pending_diagnostic != null);
            // Exercise the actual Task reset, also performed before spawn can fail.
            try self.reader.start(std.testing.io, &self, Worker.idle);
            try self.reader.join();
            self.input.init();
            self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
            self.stop();
            const settled = self.settle({});
            for ([_]anyerror{ error.WriteFailed, error.SystemResources }) |cause|
                try std.testing.expectEqual(cause, settled.failure(.final_exit, cause).?);
            var bytes: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try self.writePendingDiagnostic(&out);
            try std.testing.expectEqualStrings("HTTP 503; type: busy; code: host_busy\\x1b\\n", out.buffered());
            sink = .{ .fail_at = null };
            try self.presentReadDiagnostic(&sink);
            try std.testing.expect(self.reading.pending_diagnostic == null);
            try std.testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.length], out.buffered()) != null);
            try std.testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.length], if (phase == .details) "Details unavailable" else "Earlier messages unavailable") != null);
            try std.testing.expectEqualStrings(if (phase == .details) "! Details unavailable; draft retained." else "! Earlier messages unavailable; scroll up to retry. Draft retained.", self.notice.?);
        }
    }
}

fn applyReader(self: *Self, end: ReadEnd) !void {
    if (end.preparationFailure()) {
        if (self.reading.phase == .history) self.transcript.older_failed = true;
        if (self.reading.pending_diagnostic == null)
            self.notice = switch (reader_policy.unavailable(self.reading.phase, self.readInspection())) {
                .say => |text| text,
                .copy => reader_policy.copyFailure(self.inspection.kind.copy == .file, end.failed.err),
            };
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    var observed: ?struct { work: protocol.session_work.Work, opening: bool } = null;
    if (self.reading.output_started)
        self.live.compact_tools = if (self.reading.phase == .activity or self.reading.phase == .permission) self.job.result.compact_tools else false;
    if (self.reading.phase == .history or self.reading.phase == .message) {
        self.notice = null; // Clears "Loading earlier messages…" or "Opening message…".
    } else if (self.reading.phase == .recall) {
        // showRecalled selected the notice.
    } else if (self.reading.phase == .details or self.reading.phase == .inspection) {
        // showInspection selected the notice.
    } else {
        // History, footer, status and /status change together, in one frame.
        const result = &self.job.result;
        observed = .{ .work = result.work.work, .opening = self.reading.opening };
        self.live.work = .fromCore(result.work.work);
        // A taken Message leaves the queued row in the frame that shows it.
        self.live.queued = result.queued;
        if (result.queued_line) |shown| self.live.queued_line = shown;
        self.live.drawn = self.job.drawn;
        if (self.job.open_status or self.job.watch_status) try self.applyStatus();
        if (result.line) |*line| self.line = line.*;
        if (result.hint) |*hint| self.hint = hint.*;
        self.live.view = result.live;
        self.live.cursor = result.cursor;
        self.reading.opening = false;
        self.upgrade_stale = false;
        if (self.reading.phase == .permission) {
            self.reading.prepared_action = result.action;
            self.reading.prepared_summary = result.summary;
            if (self.reading.prepared_action == null) self.reading.phase = .activity;
        }
    }
    // A /status asked for during this read is the next read's, at once.
    self.poll_at = reader_policy.scanDue(std.Io.Clock.awake.now(self.init.io).nanoseconds, self.inspection.status_requested);
    // News goes out first in the next frame, once the read is applied.
    if (observed) |read| try self.lender.observed(self.lender.context, read.work, read.opening);
    self.dirty = true;
}

test "archive badges follow only completed server snapshots and stay distinct from work" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.line = .{ .read = .{ .revision = 1, .end = 1 } };
    self.live.work.state = .{ .working = .{ .since = 1 } };
    self.reading.phase = .activity;
    var buffer: [status_capacity]u8 = undefined;
    for ([_]struct { archive: protocol.SessionArchiveState, work: protocol.WorkState, status: []const u8 }{
        .{ .archive = .archiving, .work = .{ .stopping = .{ .since = 1 } }, .status = "Command accepted\nStopping and archiving" },
        .{ .archive = .archived, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .status = "Command accepted\nArchived · /unarchive" },
        .{ .archive = .active, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .status = "Command accepted" },
    }) |case| {
        const previous = self.line.archive_state;
        self.job.result = .{ .line = .{ .read = .{ .revision = 1, .end = 2 }, .archive_state = case.archive }, .work = .{ .work = .{ .state = case.work } } };
        try self.applyReader(.{ .cancelled = .{ .phase = .activity, .rendering = false } });
        try std.testing.expectEqual(previous, self.line.archive_state);
        try self.applyReader(.complete);
        try std.testing.expectEqual(case.archive, self.line.archive_state);
        try std.testing.expectEqualDeep(case.work, self.live.work.state);
        // The badge is the archive state's, never the work's.
        try std.testing.expectEqualStrings(case.status, statusLines(&buffer, "Command accepted", "", self.line.archive_state));
        try std.testing.expectEqualStrings("unused", self.session);
    }
}

test "frontend commits spacing only for completed visible reads" {
    const progress: ReadEnd.Progress = .{ .phase = .activity, .rendering = false };
    const Case = struct { end: ReadEnd = .complete, output: bool, prior: bool, next: bool, expected: bool };
    for ([_]Case{
        // A notice may clear UI grouping after a worker snapshots it.
        .{ .output = false, .prior = false, .next = true, .expected = false },
        .{ .output = false, .prior = true, .next = false, .expected = true },
        .{ .output = true, .prior = false, .next = true, .expected = true },
        .{ .output = true, .prior = true, .next = false, .expected = false },
        .{ .end = .{ .cancelled = progress }, .output = true, .prior = false, .next = true, .expected = false },
        .{ .end = .{ .failed = .{ .err = error.Cancelled, .progress = progress } }, .output = true, .prior = true, .next = false, .expected = true },
    }) |case| {
        var self: Self = .{
            .init = undefined,
            .store = "unused",
            .session = "unused",
            .directory = "unused",
            .files = undefined,
            .command = undefined,
            .colour = false,
            .reading = .{ .opening = false, .output_started = case.output },
            .live = .{ .cursor = .{ .position = 7 }, .compact_tools = case.prior },
        };
        self.job.result = .{ .cursor = .{ .position = 12 }, .compact_tools = case.next };
        self.init.io = std.testing.io;
        try self.applyReader(case.end);
        try std.testing.expectEqual(case.expected, self.live.compact_tools);
        try std.testing.expectEqual(@as(u64, if (case.end == .complete) 12 else 7), self.live.cursor.position);
    }
}

test "the queued row shows what waits until it is taken, whatever the work is doing" {
    const some: protocol.Queued = .{ .count = 2, .oldest_position = 30, .newest_admission = 9, .newest_position = 34 };
    const Case = struct { queued: protocol.Queued, state: protocol.WorkState, drawn: queued_line.Drawn = .{}, line: ?u64 = 9, count: u64 = 2, shown: bool };
    var line: queued_line.Line = .{ .len = 0 };
    try line.set("check the cache");
    for ([_]Case{
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .shown = true },
        .{ .queued = some, .state = .{ .approval = .{ .since = 1 } }, .shown = true },
        // A Message held back and then left pending, which live output
        // shows only once taken: the row shows it meanwhile.
        .{ .queued = some, .state = .{ .pending = .{ .since = 1 } }, .shown = true },
        .{ .queued = some, .state = .{ .idle = .{ .since = 1 } }, .shown = true },
        // Sent while the Session stayed pending: the first showed at its
        // Admission and still waits, so the row counts only the second.
        .{ .queued = some, .state = .{ .pending = .{ .since = 1 } }, .drawn = .{ .admission = 7, .position = 30 }, .count = 1, .shown = true },
        // Nothing waits, or the one waiting showed while it waited.
        .{ .queued = .{}, .state = .{ .working = .{ .since = 1 } }, .shown = false },
        .{ .queued = .{ .count = 1, .oldest_position = 34, .newest_admission = 9, .newest_position = 34 }, .state = .{ .pending = .{ .since = 1 } }, .drawn = .{ .admission = 9, .position = 34 }, .shown = false },
        // The line held is another Message's, or none was read.
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .line = 8, .shown = false },
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .line = null, .shown = false },
    }) |case| {
        var self: Self = .{
            .init = undefined,
            .store = "unused",
            .session = "unused",
            .directory = "unused",
            .files = undefined,
            .command = undefined,
            .colour = false,
            .live = .{ .queued = case.queued, .work = .{ .state = case.state }, .drawn = case.drawn, .queued_line = if (case.line) |admission| .{ .admission = admission, .line = line } else null },
        };
        const row = self.queuedRow() orelse {
            try std.testing.expect(!case.shown);
            continue;
        };
        try std.testing.expect(case.shown);
        try std.testing.expectEqual(@as(u64, 9), row.newest);
        try std.testing.expectEqual(case.count, row.waiting.count);
        try std.testing.expectEqualStrings("check the cache", row.waiting.line);
    }
}

fn showInspection(self: *Self) !void {
    const size = (try self.files.inspection.stat(self.init.io)).size;
    // A short command result is a notice, not a page, worded as the
    // overview words it.
    if (self.reading.phase == .inspection and self.inspection.kind == .command) {
        var bytes: [slash_commands_shared.short_result_bytes + 1]u8 = undefined;
        const read = try self.files.inspection.readPositionalAll(self.init.io, bytes[0..@intCast(@min(size, bytes.len))], 0);
        if (slash_commands_shared.resultNotice(self.notice_buffer[0..slash_commands_shared.result_notice_bytes], bytes[0..read])) |said| if (session_chrome.fitsBar(said)) {
            self.notice = said;
            return;
        };
    } else if (size == 0) {
        self.notice = slash_commands_shared.no_output;
        return;
    }
    self.inspection.status = null;
    try self.screen.showFile(self.init.io, self.files.inspection, false);
    if (self.inspection.kind == .requests) self.saved_requests = self.job.result.requests;
    // The page heading already says how to return.
    self.notice = null;
}

/// A joined /copy. The clipboard's bytes go out between frames, so no frame
/// splits the sequence.
fn showCopy(self: *Self) !void {
    self.dirty = true;
    self.notice = switch (self.job.result.copied) {
        .no_answer => "No answer to copy yet.",
        .no_code => "No code block in the last answer.",
        .too_large => TerminalText.clipboard_too_large,
        // Rui cannot see whether the clipboard took it.
        .clipboard => |range| sent: {
            try self.app_hooks.copy(self.app_hooks.context, self.files.scratch, range.start, range.length);
            break :sent "Sent to clipboard";
        },
        .saved => saved: {
            var name: [reads.copy_name_bytes]u8 = undefined;
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            writer.print("Saved to ./{s}", .{reads.copyName(&name, self.session)}) catch unreachable;
            break :saved writer.buffered();
        },
    };
}

/// Only a failure the person can act on is named.
/// A settled scan's /status: the page asked for, or the shown page updated in
/// place. An update keeps the reader's place, notice and consent.
fn applyStatus(self: *Self) !void {
    const screen = self.screen;
    const open = self.job.open_status and self.inspection.status_requested;
    if (!open and !self.statusShown()) return;
    const submission = self.submission.view();
    if (!self.job.result.status and std.meta.eql(submission, self.inspection.submission)) return;
    if (self.job.result.status) self.inspection.status = @intFromBool(self.job.status_taken == &self.inspection.sessions[1]);
    self.inspection.submission = submission;
    if (open) {
        self.inspection.status_requested = false;
        self.inspection.defaults = savedDefaults(self.home);
        try self.writeStatusPage();
        try screen.showFile(self.init.io, self.files.status, false);
        self.notice = null;
    } else try self.refreshStatusPage();
}

/// The defaults new Sessions start from, as the page shows them.
fn savedDefaults(home: []const u8) status_page.Defaults {
    const values = try preferences.load(home);
    var saved: status_page.Saved = .{
        .provider = if (values.provider.len == 0) status_page.Saved.rui else std.meta.stringToEnum(protocol.Provider, values.provider.slice()) orelse error.UnsupportedPreferenceProvider,
        .model = .{ .len = 0 },
        .effort = values.reasoning_effort,
        .notifications = values.notifications,
        .store = .{ .len = 0 },
    };
    try saved.model.set(values.model.slice());
    if (saved.store) |*store| {
        var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (values.store.len != 0) try store.set(values.store.slice()) else if (preferences.defaultStore(home, &fallback)) |path| try store.set(path) else |err| saved.store = err;
    } else |_| unreachable;
    return saved;
}

/// What the shown /status page reports.
fn statusFacts(self: *const Self) status_page.Facts {
    return .{ .home = self.home, .store = self.store, .session = &self.inspection.sessions[self.inspection.status.?], .defaults = &self.inspection.defaults };
}

/// Renders the /status page, `›` on the selected row, into the status file
/// the screen shows: its facts, the Actions its read listed, then the
/// submission under it.
fn writeStatusPage(self: *Self) !void {
    const io = self.init.io;
    const file = self.files.status;
    try file.setLength(io, 0);
    try io.vtable.fileSeekTo(io.userdata, file, 0);
    var buffer: [4096]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const out = &output.interface;
    const facts = self.statusFacts();
    try status_page.render(facts, self.inspection.selected, out);
    var actions = self.files.actions[self.inspection.status.?].reader(io, &.{});
    _ = actions.interface.streamRemaining(out) catch |err| return switch (err) {
        error.ReadFailed => actions.err.?,
        error.WriteFailed => output.err.?,
    };
    try status_page.writeWorkEnd(&facts.session.work, out);
    try reads.writeSubmission(self.inspection.submission, if (self.heldFailure()) |failure| failure.page else null, out);
    try output.flush();
}

/// Renders the shown /status page again and shows it in place.
fn refreshStatusPage(self: *Self) !void {
    try self.writeStatusPage();
    try self.screen.refreshFile(self.init.io, self.files.status);
}

/// The view an inspection runs over. Input goes to the editor the latest
/// frame shows; this stales it, so the view returned to is drawn while the
/// inspection runs. A command run on the /status page leaves the page shown:
/// a short reply is a notice under it, and the next read shows the change on it.
fn leaveFor(self: *Self, kind: Inspection) !void {
    if (kind == .command and self.statusShown()) self.dirty = true else try self.screen.latest();
}

/// The /status page is the view shown.
fn statusShown(self: *const Self) bool {
    return self.inspection.status != null and self.screen.view == .inspection;
}

/// Up or Down on the /status page with an empty draft moves `›` to the
/// next changeable row, scrolling the page to show it; false otherwise.
fn moveSelection(self: *Self, down: bool) !bool {
    if (!self.statusShown() or self.input.composition().bytes.len != 0) return false;
    self.inspection.selected = status_page.step(self.inspection.selected, down);
    try self.refreshStatusPage();
    self.screen.revealLine(status_page.line(self.inspection.selected));
    return true;
}

/// Enter on the /status page with an empty draft starts the selected row's
/// change: its command in the draft, whose list offers a choice row's
/// choices, or a typed row's current value to edit. False otherwise.
fn startChange(self: *Self) bool {
    if (!self.statusShown() or self.input.composition().bytes.len != 0) return false;
    var buffer: [status_page.max_draft_bytes]u8 = undefined;
    // Up and Down select only changeable rows.
    switch (self.input.append(status_page.draft(self.inspection.selected, self.statusFacts(), &buffer).?)) {
        // A value too long for the draft says so, as a list word does.
        .refused => |why| self.notice = refusedNotice(why),
        else => {},
    }
    return true;
}

test "a transcript begun before grown live output is drawn shows the gap, not a lost join" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .screen = screen, .colour = false, .reading = .{ .opening = false } };
    try screen.append("GROWS-FIRST\n");
    self.live.marks.record(.{ .offset = 12, .cursor = .{ .end = 3 }, .admitted = 4 });
    // Unescaped, the rows after the mark fit; escaped, they evict it.
    try Screen.appendEscapeGrowth(screen);
    try screen.append("\nGROWS-END\n");
    try self.beginTranscript();
    try std.testing.expect(std.mem.indexOf(u8, screen.browsing.text(), "Earlier rows left this view.") != null);
    try std.testing.expectEqual(@as(?u64, 3), if (self.transcript.older) |cursor| cursor.end else null);
}

/// A frontend attached to App as `rui` attaches it: Root before it, a
/// permission card that holds focus while it shows, and hooks that record
/// leaving and an Upgrade instead of acting on them.
const HeldFrontend = struct {
    self: Self,
    screen: *Screen,
    environ: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    directory: [std.Io.Dir.max_path_bytes]u8 = undefined,
    interrupted: client.Cancellation = .{},
    root: Root = .{ .overview = empty_app_text.widget() },
    arena: std.heap.ArenaAllocator,
    /// What the frontend asked of its lender, in order.
    left: ?Outcome = null,
    /// The Upgrade its lender shows.
    upgrade: session_upgrade.Upgrade = .{},
    size: vxfw.MaxSize = .{ .width = 80, .height = 24 },

    fn create() !*HeldFrontend {
        const held = try std.testing.allocator.create(HeldFrontend);
        errdefer std.testing.allocator.destroy(held);
        const screen = try std.testing.allocator.create(Screen);
        held.* = .{ .self = undefined, .screen = screen, .environ = try std.testing.environ.createMap(std.testing.allocator), .tmp = std.testing.tmpDir(.{}), .arena = .init(std.testing.allocator) };
        try screen.init(std.testing.io, &held.environ, false);
        const directory = try held.tmp.dir.realPath(std.testing.io, &held.directory);
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        init.gpa = std.testing.allocator;
        init.environ_map = &held.environ;
        var lender = quiet_overview;
        lender.context = held;
        lender.upgrade = shownUpgrade;
        held.self.begin(init, "unused", "unused", held.directory[0..directory], undefined, undefined, undefined, undefined, screen, &held.interrupted, lender);
        held.self.reading.opening = false;
        // No read is due: a test hands the frontend what a read would.
        held.self.poll_at = std.math.maxInt(i96);
        held.self.submission.environment = .empty;
        _ = held.self.attach(.{ .root = &held.root, .context = held, .leave = onLeave, .copy = onCopy, .on_open = onOpen }, .{ .depth = .none });
        return held;
    }

    fn destroy(held: *HeldFrontend) void {
        _ = held.self.dropSkills();
        // As `settle` does: a read a key started, such as /help's page, may
        // still be running, and it borrows the frontend freed below.
        held.self.stop();
        _ = held.self.joinReader();
        _ = held.self.submission.join();
        held.self.submission.close();
        held.screen.deinit();
        std.testing.allocator.destroy(held.screen);
        held.tmp.cleanup();
        held.environ.deinit();
        held.arena.deinit();
        std.testing.allocator.destroy(held);
    }

    fn onLeave(raw: *anyopaque, _: *vxfw.EventContext, outcome: Outcome) !void {
        const held: *HeldFrontend = @ptrCast(@alignCast(raw));
        held.left = outcome;
    }

    fn shownUpgrade(raw: *anyopaque) session_upgrade.Upgrade {
        const held: *HeldFrontend = @ptrCast(@alignCast(raw));
        return held.upgrade;
    }

    fn onCopy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {
        return error.UnexpectedCopy;
    }

    fn onOpen(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {
        return error.UnexpectedOpen;
    }

    fn context(held: *HeldFrontend) vxfw.EventContext {
        return .{ .io = std.testing.io, .alloc = held.arena.allocator(), .cmds = .empty };
    }

    /// One event as App delivers it: Root's capture first, then the
    /// focused permission card when one shows, then the Session, which
    /// takes what the card leaves.
    fn deliver(held: *HeldFrontend, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        ctx.consume_event = false;
        ctx.phase = .capturing;
        try held.root.widget().captureEvent(ctx, event);
        if (ctx.consume_event) return;
        ctx.phase = .at_target;
        if (held.self.app_input.permission) |card| {
            try card.widget().handleEvent(ctx, event);
            if (ctx.consume_event) return;
        }
        try held.self.widget().handleEvent(ctx, event);
    }

    /// Terminal bytes, decoded by vaxis's Parser as App decodes them.
    fn keys(held: *HeldFrontend, bytes: []const u8) !void {
        var ctx = held.context();
        var parser: vaxis.Parser = .{};
        var at: usize = 0;
        while (at < bytes.len) {
            const result = try parser.parse(bytes[at..], null);
            if (result.n == 0) return error.TestUnexpectedResult;
            at += result.n;
            const event: vxfw.Event = switch (result.event orelse continue) {
                .key_press => |key| .{ .key_press = key },
                .key_release => |key| .{ .key_release = key },
                .paste_start => .paste_start,
                .paste_end => .paste_end,
                .invalid_key => .invalid_key,
                else => continue,
            };
            try held.deliver(&ctx, event);
        }
    }

    /// App's tick, then a draw: the latest frame.
    fn settle(held: *HeldFrontend) !void {
        var ctx = held.context();
        try held.deliver(&ctx, .tick);
        _ = try held.draw();
    }

    fn draw(held: *HeldFrontend) !vxfw.Surface {
        return held.self.widget().draw(.{ .arena = held.arena.allocator(), .min = .{}, .max = held.size, .cell_size = .{} });
    }

    /// The latest frame's rows as text, one per line.
    fn shown(held: *HeldFrontend) ![]const u8 {
        const width = held.size.width.?;
        const height = held.size.height.?;
        const gpa = held.arena.allocator();
        const surface = try held.draw();
        var screen: vaxis.Screen = try .init(gpa, .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        surface.render(window, held.self.app_input.composer.widget());
        var text: std.Io.Writer.Allocating = .init(gpa);
        for (0..height) |row| {
            for (0..width) |col| try text.writer.writeAll(screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
            try text.writer.writeByte('\n');
        }
        return text.written();
    }

    /// A pending Action the reader found: its card shows on the next frame.
    fn adopt(held: *HeldFrontend, rows: usize) !std.Io.File {
        const file = try held.tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
        var line: [16]u8 = undefined;
        for (0..rows) |row| try file.writePositionalAll(std.testing.io, try std.fmt.bufPrint(&line, "row {d:0>3}\n", .{row}), row * 8);
        held.self.files.action = file;
        held.self.reading.prepared_action = 0xa;
        held.self.live.work.first_action = 0xa;
        try held.settle();
        return file;
    }
};

test "a held frontend stops a read still running and joins it before it is freed" {
    const Worker = struct {
        var stopped: std.atomic.Value(bool) = .init(false);
        fn read(_: *anyopaque, task: *Task) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            stopped.store(true, .release);
            return error.Cancelled;
        }
    };
    const held = try HeldFrontend.create();
    try held.self.reader.start(std.testing.io, &held.self, Worker.read);
    held.destroy();
    try std.testing.expect(Worker.stopped.load(.acquire));
}

/// Terminal bytes into the frontend's App, as `HeldFrontend.keys`.
/// What the next frame's last row, the status bar, shows.
fn barShows(held: *HeldFrontend) ![]const u8 {
    const rows = std.mem.trimEnd(u8, try held.shown(), "\n");
    const last = rows[if (std.mem.lastIndexOfScalar(u8, rows, '\n')) |at| at + 1 else 0..];
    return std.mem.trim(u8, last, " ");
}

fn sendKeys(frontend: *Self, bytes: []const u8) !void {
    const held: *HeldFrontend = @fieldParentPtr("self", frontend);
    try held.keys(bytes);
}

test "a history page read for an earlier transcript never joins the current one" {
    const Worker = struct {
        fn read(_: *anyopaque, _: *Task) !void {}
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "older", .{ .read = true });
    defer self.files.inspection.close(std.testing.io);
    try self.files.inspection.writePositionalAll(std.testing.io, "STALE PAGE ROW\n", 0);
    try held.settle();
    try held.keys("\x1b[5~");
    self.job.transcript = self.transcript.id;
    self.reading.phase = .history;
    try self.reader.start(std.testing.io, self, Worker.read);
    defer {
        self.reader.cancel();
        self.reader.join() catch {};
    }
    try held.keys("\x07\x1b[5~");
    try std.testing.expect(self.job.transcript != self.transcript.id);
    while (!self.reader.completed()) std.Thread.yield() catch {};
    try held.settle();
    try held.keys("\x1b[5~");
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "STALE PAGE ROW") == null);
}

test "sending a Message drops an older-page read still waiting to start" {
    const Worker = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn read(_: *anyopaque, _: *Task) !void {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    Worker.release.store(false, .release);
    try self.reader.start(std.testing.io, self, Worker.read);
    defer {
        Worker.release.store(true, .release);
        self.reader.cancel();
        self.reader.join() catch {};
    }
    try held.keys("/history\r");
    try std.testing.expect(self.transcript.history_requested != null);
    try held.keys("hello\r");
    try std.testing.expect(self.transcript.history_requested == null);
    Worker.release.store(true, .release);
    while (!self.reader.completed()) std.Thread.yield() catch {};
    try self.settleReader();
    try held.settle();
    try std.testing.expect(self.transcript.history_requested == null);
    try std.testing.expect(self.reader.thread == null);
}

test "sending a Message drops a /status read still waiting to start" {
    const Worker = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn read(_: *anyopaque, _: *Task) !void {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    Worker.release.store(false, .release);
    try self.reader.start(std.testing.io, self, Worker.read);
    defer {
        Worker.release.store(true, .release);
        self.reader.cancel();
        self.reader.join() catch {};
    }
    try held.keys("/status\r");
    try held.settle();
    try std.testing.expect(self.inspection.status_requested);
    try held.keys("hello\r");
    try std.testing.expect(!self.inspection.status_requested);
    Worker.release.store(true, .release);
    while (!self.reader.completed()) std.Thread.yield() catch {};
    try self.settleReader();
    try held.settle();
    try std.testing.expect(!self.inspection.status_requested);
    try std.testing.expect(self.reader.thread == null);
}

test "sending a Message from a browsed page returns the screen to the latest conversation" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.screen.append("OLDER ROW\n");
    for (0..60) |_| try held.screen.append("conversation row\n");
    try held.screen.append("LATEST ROW\n");
    try held.settle();
    for (0..6) |_| try held.keys("\x1b[5~");
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "OLDER ROW") != null);
    try held.keys("hello\r");
    const shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "LATEST ROW") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "OLDER ROW") == null);
}

/// Terminal bytes, then App's next tick.
fn stepKeys(held: *HeldFrontend, bytes: []const u8) !void {
    try held.keys(bytes);
    var ctx = held.context();
    try held.deliver(&ctx, .tick);
}

test "Ctrl-R while an Action waits recovers nothing and keeps the draft" {
    for ([_][]const u8{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" }) |ctrl_r| {
        errdefer std.debug.print("ctrl_r={s}\n", .{ctrl_r[1..]});
        const held = try HeldFrontend.create();
        defer held.destroy();
        try sendKeys(&held.self, "kept");
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try std.testing.expectEqual(@as(?u64, 0xa), held.self.app_consent.request);
        try stepKeys(held, ctrl_r);
        try std.testing.expectEqualStrings("kept", held.self.input.composition().bytes);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqual(@as(?u64, 0xa), held.self.app_consent.request);
    }
}

test "every way out of the conversation ends consent, from the card" {
    for ([_][]const u8{ "\x03", "\x1b[99;5u" }) |key| {
        errdefer std.debug.print("key={x}\n", .{key});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try std.testing.expect(held.self.app_consent.request != null);
        try stepKeys(held, key);
        try std.testing.expectEqual(@as(?Outcome, .detached), held.self.leaving);
        try std.testing.expectEqual(@as(?Outcome, .detached), held.left);
        try std.testing.expect(held.self.app_consent.request == null);
    }
}

test "each source admits a slash command while another is active as it always did" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    // A running command: a draft inspection queues behind it.
    self.inspection.command_running = true;
    try sendKeys(self, "/requests\r");
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    // A queued one: every draft command waits, local ones too, and keeps the draft.
    for ([_][]const u8{ "/wait", "/exit", "/help" }) |text| {
        self.notice = null;
        self.shown_notice.dismiss();
        try sendKeys(self, text);
        try sendKeys(self, "\r");
        try std.testing.expectEqualStrings(text, self.input.composition().bytes);
        try std.testing.expectEqualStrings("! Command still running. Draft retained.", try barShows(held));
        try std.testing.expect(self.leaving == null);
        try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
        self.input.clear();
    }
}

test "Esc at the latest view returns to the overview unless unsent text or a choice would be lost" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    // No draft outlives the frontend: Esc keeps it and says why.
    try sendKeys(self, "draft\x07");
    try std.testing.expect(self.leaving == null);
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", try barShows(held));
    try std.testing.expectEqualStrings("draft", self.input.composition().bytes);
    self.input.clear();
    // An original not yet saved keeps the conversation open and says what
    // resolves it; a saved one, rejected or not, lets it go.
    self.submission.intent = .{ .decision = .{ .action = 1, .decision = .deny } };
    defer self.submission.intent = null;
    for ([_]struct { Submission.State, Submission.Publication, ?[]const u8 }{
        .{ .not_started, .not_sent, "Esc returns to the overview once Ctrl-R retries the original." },
        .{ .rejected, .published, null },
        // A capture that failed before publishing may have saved nothing.
        .{ .unconfirmed, .unknown, "Esc returns to the overview once Ctrl-R retries the original." },
        .{ .unconfirmed, .published, null },
    }) |case| {
        self.submission.state = case[0];
        self.submission.publication = case[1];
        self.notice = null;
        self.shown_notice.dismiss();
        self.leaving = null;
        try sendKeys(self, "\x07");
        if (case[2]) |why| {
            try std.testing.expect(self.leaving == null);
            // Esc says why, but what needs the person, which names the
            // same key, outranks it on the bar.
            try std.testing.expectEqualStrings(why, self.shown_notice.current(self.nowMs()).?);
            try std.testing.expectEqualStrings(session_notice.status(false, false, self.heldOriginal()).?, try barShows(held));
        } else try std.testing.expectEqual(@as(?Outcome, .returned), self.leaving);
    }
    self.leaving = null;
    self.submission.intent = null;
    self.submission.state = .not_started;
    self.submission.publication = .not_sent;
    // A running command keeps the conversation open.
    self.inspection.command_running = true;
    try sendKeys(self, "\x07");
    try std.testing.expect(self.leaving == null);
    self.inspection.command_running = false;
    // A pending Action: Esc returns to it, not to the overview.
    const file = try held.adopt(4);
    defer file.close(std.testing.io);
    try sendKeys(self, "\x07");
    try std.testing.expect(self.leaving == null);
    try std.testing.expectEqual(@as(?u64, 0xa), self.app_consent.request);
    // Another client decided: the next tick withdraws the card.
    self.live.work.first_action = null;
    try held.settle();
    try std.testing.expect(self.app_input.permission == null);
    // Ctrl-G stands for Esc and Alt-Esc.
    try sendKeys(self, "\x07");
    try std.testing.expectEqual(@as(?Outcome, .returned), self.leaving);
}

test "Up, Down and Enter take a row only from a list the latest frame drew" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    // The latest frame drew no list: Down scrolls rather than move a
    // highlight never seen, and Enter runs the line as typed.
    try stepKeys(held, "/\x1b[B");
    try std.testing.expectEqual(@as(usize, 0), held.screen.commands.?.highlight);
    try stepKeys(held, "\x15/he\r");
    try std.testing.expectEqualStrings("! Unknown command /he · /help", try barShows(held));
    // Drawn: Enter takes the highlighted /help.
    try stepKeys(held, "/he");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\r");
    try std.testing.expect(!std.mem.startsWith(u8, try barShows(held), "! Unknown command"));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
}

test "a key on a draft changed since the latest frame acts on that draft's list when the frame drew one" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    // The frame drew the list for `/h`; `e` changes the draft before any
    // frame lists it, and Enter takes /help from `/he`'s list.
    try stepKeys(held, "/h");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "e\r");
    try std.testing.expect(!std.mem.startsWith(u8, try barShows(held), "! Unknown command"));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    // Down on `/c`, typed after the frame drew `/`'s list, moves the
    // highlight to `/c`'s second row, which the next frame keeps.
    try stepKeys(held, "/");
    try held.settle();
    try stepKeys(held, "c\x1b[B");
    try std.testing.expectEqual(@as(usize, 1), held.screen.commands.?.highlight);
    try held.settle();
    try std.testing.expectEqualStrings("c", held.screen.commands.?.list.typed);
    try std.testing.expectEqual(@as(usize, 1), held.screen.commands.?.highlight);
    // Esc on `/co`, typed after the frame drew `/c`'s list, closes the list.
    try stepKeys(held, "o\x07");
    try std.testing.expect((try barShows(held)).len == 0);
    try held.settle();
    try std.testing.expectEqual(.closed, held.screen.commands.?.seen);
}

test "Tab completes from the draft's own list, however many keys arrive before a frame" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    try stepKeys(held, "/he\t");
    try std.testing.expectEqualStrings("/help", self.input.composition().bytes);
    // Two Tabs in one batch: the second completes from the list the first
    // one's word calls for.
    try stepKeys(held, "\x15/conf\t\t");
    try std.testing.expectEqualStrings("/configure --permission-mode ", self.input.composition().bytes);
}

test "a key before a new Session's first frame finds no list the previous Session drew" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    try stepKeys(held, "/h");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    // The next Session's input starts over; no frame of it drew a list, so
    // Enter runs `/he` as typed, and Tab still completes.
    self.startInput();
    try stepKeys(held, "/he\r");
    try std.testing.expectEqualStrings("! Unknown command /he · /help", try barShows(held));
    try stepKeys(held, "/he\t");
    try std.testing.expectEqualStrings("/help", self.input.composition().bytes);
}

test "Esc closes the command list first only when the latest frame drew it" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.settle();
    // Drawn: the first Esc closes only the list, the next one acts as Esc.
    try stepKeys(held, "/st");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try std.testing.expect((try barShows(held)).len == 0);
    try held.settle();
    try std.testing.expectEqual(.closed, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", try barShows(held));
    // The latest frame drew no list, the first being closed: Esc acts at
    // once.
    try stepKeys(held, "\x15/st\x07");
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", try barShows(held));
}

test "the /requests page lists its rows over an empty draft, and Enter or Tab takes the row's command as typed" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const original = "01234567-89ab-4cde-8012-0123456789ab";
    const older = "22222222-89ab-4cde-8012-0123456789ab";
    const newer = "33333333-89ab-4cde-8012-0123456789ab";
    self.submission.intent = .{ .message = self.input.submitText("unconfirmed original") };
    self.submission.state = .unconfirmed;
    self.submission.key = original.*;
    self.saved_requests.offer(.{ .nanoseconds = 1 }, "09:00", older);
    self.saved_requests.offer(.{ .nanoseconds = 2 }, "09:05", newer);
    self.saved_requests.offer(.{ .nanoseconds = 3 }, "09:10", original);
    try held.settle();
    // No rows until the page shows.
    try std.testing.expect(held.screen.commands == null);
    const page = try held.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    try page.writePositionalAll(std.testing.io, "Rui: Local recovery handles (not Host work status):\n", 0);
    try held.screen.showFile(std.testing.io, page, false);
    self.inspection.kind = .requests;
    self.dirty = true;
    try held.settle();
    const drawn = held.screen.commands.?;
    try std.testing.expectEqual(.drawn, drawn.seen);
    // The original has its /recover row only, not a /result row too.
    try std.testing.expectEqual(@as(usize, 3), drawn.list.count);
    try std.testing.expectEqualStrings("/recover " ++ original, drawn.list.entries[0].shown);
    try std.testing.expectEqualStrings("/result " ++ newer, drawn.list.entries[1].shown);
    try std.testing.expectEqualStrings("09:05 · read this Message's saved answer", drawn.list.entries[1].description);
    // Enter on the original's row retries it, as Ctrl-R does.
    try held.keys("\r");
    try std.testing.expectEqualSlices(u8, original, &(self.submission.retry orelse return error.TestUnexpectedResult));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    self.submission.retry = null;
    // Down twice reaches the older Message, and Enter queues its /result.
    try held.settle();
    try held.keys("\x1b[B\x1b[B");
    try std.testing.expectEqual(@as(usize, 2), held.screen.commands.?.highlight);
    try held.keys("\r");
    try std.testing.expectEqualStrings("/result " ++ older, self.input.takeCommand().?);
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    // The original resolves after a frame drew its row highlighted: until
    // a frame draws the rows that are left, Enter takes none of them.
    try held.settle();
    try std.testing.expectEqualStrings("/recover " ++ original, held.screen.commands.?.completion());
    self.submission.intent = null;
    try held.keys("\r");
    try std.testing.expect(self.input.queuedCommand() == null);
    try std.testing.expect(self.submission.retry == null);
    try held.settle();
    try std.testing.expectEqualStrings("/result " ++ original, held.screen.commands.?.list.entries[0].word);
    // Tab puts the highlighted row's line in the draft, for editing.
    try held.keys("\x1b[B\t");
    try std.testing.expectEqualStrings("/result " ++ newer, self.input.composition().bytes);
    try held.settle();
    try std.testing.expect(held.screen.commands == null);
    // Esc closes the rows first, then leaves the page, which takes them.
    try held.keys("\x15");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try held.keys("\x07");
    try held.settle();
    try std.testing.expectEqual(.closed, held.screen.commands.?.seen);
    try std.testing.expectEqual(Screen.ViewKind.inspection, held.screen.view);
    try held.keys("\x07");
    try held.settle();
    try std.testing.expect(held.screen.view != .inspection);
    try std.testing.expect(held.screen.commands == null);
    // Enter on an empty draft with no rows does nothing, and Tab is a tab.
    try held.keys("\r");
    try std.testing.expect(self.input.queuedCommand() == null);
    try held.keys("\t");
    try std.testing.expectEqualStrings("\t", self.input.composition().bytes);
}

test "a pending decision, or a Message that carries one, has no /recover row, and Enter on the page sends nothing" {
    for (0..3) |case| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        const original = "01234567-89ab-4cde-8012-0123456789ab";
        const newer = "33333333-89ab-4cde-8012-0123456789ab";
        self.submission.intent = switch (case) {
            0 => .{ .decision = .{ .action = 0xa, .decision = .allow_once } },
            1 => .{ .message_then_deny = .{ .ticket = self.input.submitText("reason"), .action = 0xa } },
            else => .{ .message = self.input.submitText("in flight") },
        };
        // The third is a Message whose reply has not come back yet.
        self.submission.state = if (case == 2) .submitting else .unconfirmed;
        self.submission.key = original.*;
        self.saved_requests.offer(.{ .nanoseconds = 2 }, null, newer);
        const page = try held.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
        defer page.close(std.testing.io);
        try page.writePositionalAll(std.testing.io, "Rui: Local recovery handles (not Host work status):\n", 0);
        try held.screen.showFile(std.testing.io, page, false);
        self.inspection.kind = .requests;
        self.dirty = true;
        try held.settle();
        const drawn = held.screen.commands.?;
        try std.testing.expectEqual(@as(usize, 1), drawn.list.count);
        try std.testing.expectEqualStrings("/result " ++ newer, drawn.list.entries[0].word);
        try held.keys("\r");
        try std.testing.expect(self.submission.retry == null);
        try std.testing.expectEqualStrings("/result " ++ newer, self.input.takeCommand().?);
        self.submission.intent = null;
    }
}

test "Enter on a rejected draft clears it even while a skill list shows" {
    const Fake = struct {
        fn read(_: client.Requests, gpa: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !skill_suggestions.Page {
            const entries = try gpa.alloc(skill_suggestions.Entry, 1);
            entries[0] = .{ .name = try gpa.dupe(u8, "recap"), .description = try gpa.dupe(u8, "") };
            return .{ .entries = entries, .total = 1 };
        }
        fn done(self: *Self) bool {
            return self.skill_task.completed();
        }
    };
    const io = std.testing.io;
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.skill_read = Fake.read;
    try held.keys("use /re");
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &held.self, Fake.done);
    try held.settle();
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "/recap") != null);
    // A malformed byte rejects the line; Enter clears it as it does with
    // no list, rather than taking the row the list still offers.
    try held.keys("\xff");
    try held.keys("\r");
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try std.testing.expect(held.self.submission.view() == null);
    try held.keys("hi");
    try std.testing.expectEqualStrings("hi", held.self.input.composition().bytes);
}

test "End on an empty draft does nothing and never leaves the conversation" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    for ([_][]const u8{ "\x1b[F", "\x1bOF" }) |end| {
        try sendKeys(self, end);
        try std.testing.expect(self.leaving == null);
    }
    // A rejected draft changes no key's meaning: Esc still returns.
    try sendKeys(self, "\xff\x1b[27u");
    try std.testing.expectEqual(@as(?Outcome, .returned), self.leaving);
}

test "permission resolved between the activity scan and Current keeps the frontend open without approval" {
    const Host = struct {
        fn respond(listener: *std.Io.net.Server, route: []const u8, body: []const u8) !void {
            var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 2000) == 0) return error.TestUnexpectedResult;
            const peer = try listener.accept(std.testing.io);
            defer peer.close(std.testing.io);
            var request: [4096]u8 = undefined;
            var used: usize = 0;
            while (true) {
                const count = try std.posix.read(peer.socket.handle, request[used..]);
                if (count == 0) return error.UnexpectedEof;
                used += count;
                if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |end| {
                    const start = std.mem.indexOf(u8, request[0..end], "Content-Length: ").? + "Content-Length: ".len;
                    const finish = std.mem.indexOf(u8, request[start..end], "\r\n").? + start;
                    if (used == end + 4 + try std.fmt.parseInt(usize, request[start..finish], 10)) break;
                }
            }
            var prefix: [96]u8 = undefined;
            try std.testing.expectStringStartsWith(request[0..used], try std.fmt.bufPrint(&prefix, "POST {s} HTTP/1.1\r\n", .{route}));
            var header: [256]u8 = undefined;
            var writer = peer.writer(std.testing.io, &.{});
            try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{body.len}));
            try writer.interface.writeAll(body);
        }
    };
    const io = std.testing.io;
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var lease = try @import("platform.zig").StoreLease.acquire(io, root);
    defer lease.release();
    try lease.prepareForServing(false);
    const paths = lease.paths;
    var listener = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, paths.socket.slice()) catch @panic("unable to remove fixture socket");
    }
    const scratch = try held.tmp.dir.createFile(io, "scratch", .{ .read = true });
    defer scratch.close(io);
    const action = try held.tmp.dir.createFile(io, "action", .{ .read = true });
    defer action.close(io);
    const inspection = try held.tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer inspection.close(io);
    self.files = .{ .scratch = scratch, .action = action, .inspection = inspection, .status = inspection, .actions = .{ inspection, inspection } };
    self.store = root;
    self.session = "k7m2qx";
    self.line.read = .{ .revision = 1, .end = 0 };
    try sendKeys(self, "draft retained");
    defer {
        self.reader.cancel();
        self.reader.join() catch |err| switch (err) {
            error.Cancelled => {},
            else => @panic(@errorName(err)),
        };
    }
    try self.launch(self.freeze(.permission), reads.permission);
    var facts: protocol.ActivityFacts = .{ .end = 0, .work = .{ .revision = 1, .work = .{ .state = .{ .approval = .{ .since = 1 } }, .turn = 1, .operation = 1, .first_action = 7 } } };
    try facts.work.workspace.set("/w");
    var page_buffer: [4096]u8 = undefined;
    var page = std.Io.Writer.fixed(&page_buffer);
    try activity_reply.writePage(&page, &facts);
    try Host.respond(&listener, "/v1/activity-page", page.buffered());
    // Another client denies the selected Action (or its Turn stops/finishes)
    // before the next read: Current no longer has that unresolved row.
    const resolved =
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"session\":{\"reference\":\"k7m2qx\",\"parent\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"gpt-5.5\",\"revision\":\"1\",\"tools\":[],\"loaded_tools\":[],\"permission_mode\":\"ask\",\"instructions\":{\"bytes\":\"0\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"output_schema\":null,\"reasoning_effort\":null,\"reasoning_effort_override\":null,\"compaction_trigger\":null,\"context_estimate\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"},\"archive_state\":\"active\",\"pending_messages\":\"0\",\"work\":{\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"latest_outcome\":null},\"peers\":{\"from_person_at\":null},\"first_message\":null,\"selected_message\":null,\"recent_messages\":[],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}";
    try Host.respond(&listener, "/v1/inspect-session", resolved);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, struct {
        fn completed(frontend: *Self) !bool {
            return frontend.reader.completed();
        }
    }.completed);
    try self.settleReader();
    try std.testing.expect(self.leaving == null);
    try std.testing.expect(self.reading.pending_diagnostic == null);
    try std.testing.expect(self.reading.prepared_action == null);
    try std.testing.expect(self.job.result.action == null);
    try std.testing.expectEqual(ReadPhase.activity, self.reading.phase);
    try std.testing.expect(held.self.app_consent.request == null);
    try std.testing.expectEqual(@as(u64, 0), try action.length(io));
    try std.testing.expectEqualStrings("draft retained", self.input.composition().bytes);
    // The ordinary refresh takes the newer work; the conversation stays usable.
    try self.launch(self.freeze(.activity), reads.scan);
    facts.work.work = .{ .state = .{ .idle = .{ .since = 1 } } };
    page = std.Io.Writer.fixed(&page_buffer);
    try activity_reply.writePage(&page, &facts);
    try Host.respond(&listener, "/v1/activity-page", page.buffered());
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, struct {
        fn completed(frontend: *Self) !bool {
            return frontend.reader.completed();
        }
    }.completed);
    try self.settleReader();
    try held.settle();
    try std.testing.expect(self.leaving == null);
    try std.testing.expect(self.live.work.first_action == null);
    try std.testing.expect(held.self.app_consent.request == null);
    try sendKeys(self, "!");
    try std.testing.expectEqualStrings("draft retained!", self.input.composition().bytes);
}

test "a details page read before a Message was sent never covers it" {
    const Worker = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn read(_: *anyopaque, _: *Task) !void {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const page = try held.tmp.dir.createFile(std.testing.io, "details", .{ .read = true });
    defer page.close(std.testing.io);
    try page.writePositionalAll(std.testing.io, "Saved tool output\n", 0);
    self.files.inspection = page;
    for ([_]bool{ true, false }) |send| {
        Worker.release.store(false, .release);
        try held.screen.latest();
        // /details begins its read, as its command does.
        self.admission.details_sent = self.admission.sent;
        self.reading.phase = .details;
        try self.reader.start(std.testing.io, self, Worker.read);
        if (send) {
            try self.beginMessage(.{ .message = self.input.submitText("sent while the page loaded") });
            self.submission.cancel();
            _ = self.submission.join();
            self.submission.close();
            self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = self.directory, .input = &self.input, .environment = .empty };
            self.input.init();
        }
        Worker.release.store(true, .release);
        while (!self.reader.completed()) std.Thread.yield() catch {};
        try self.settleReader();
        // The sent Message keeps the latest view; an unrelated page still opens.
        try std.testing.expectEqual(if (send) Screen.ViewKind.live else .inspection, held.screen.view);
    }
}

test "Ctrl-R recovers only as Ctrl-R, never with Shift hidden by its reported text" {
    for ([_]struct { bytes: []const u8, recovery: bool }{
        .{ .bytes = "\x12", .recovery = true },
        .{ .bytes = "\x1b[114;5u", .recovery = true },
        .{ .bytes = "\x1b[114;69u", .recovery = true },
        .{ .bytes = "\x1b[27;5;114~", .recovery = true },
        .{ .bytes = "\x1b[114;6;114u", .recovery = false },
        .{ .bytes = "\x1b[114:114;6u", .recovery = false },
    }) |case| {
        errdefer std.debug.print("bytes={s}\n", .{case.bytes[1..]});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.submission.intent = .{ .message = self.input.submitText("unconfirmed original") };
        self.submission.state = .unconfirmed;
        self.submission.key = "01234567-89ab-4cde-8012-0123456789ab".*;
        try held.keys(case.bytes);
        try std.testing.expectEqual(case.recovery, self.submission.retry != null);
    }
}

/// An overview that lent the terminal and says nothing under its input.
const quiet_overview: Lender = .{ .context = undefined, .step = struct {
    fn step(_: *anyopaque, _: protocol.session_work.Kind, _: overview_view.ConversationInput) !void {}
}.step, .service = struct {
    fn service(_: *anyopaque) !bool {
        return false;
    }
}.service, .line = struct {
    fn line(_: *anyopaque, _: protocol.session_work.Kind) Lender.Said {
        return .{};
    }
}.line, .observed = struct {
    fn observed(_: *anyopaque, _: protocol.session_work.Work, _: bool) !void {}
}.observed, .upgrade = struct {
    fn upgrade(_: *anyopaque) session_upgrade.Upgrade {
        return .{};
    }
}.upgrade };

/// The Upgrade's three holds, as tests number them: a run going, then
/// what a run left.
fn heldUpgrade(hold: usize, afters: [2]session_upgrade.After) session_upgrade.Upgrade {
    return if (hold == 0) .{ .run = .checking } else .{ .after = afters[hold - 1] };
}

/// An overview that lent the terminal, reduced to one Session's stop
/// prompt, stop and notice.
const FakeOverview = struct {
    stopping: bool = false,
    stops: usize = 0,
    notice: ?[]const u8 = null,

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
        const fake: *FakeOverview = @ptrCast(@alignCast(raw));
        fake.notice = null;
        if (input != .stop) return;
        if (fake.stopping or work != .working) {
            fake.notice = "unused: Stopping";
        } else {
            fake.stops += 1;
            fake.stopping = true;
        }
    }

    fn service(_: *anyopaque) !bool {
        return false;
    }

    fn line(raw: *anyopaque, work: protocol.session_work.Kind) Lender.Said {
        const fake: *FakeOverview = @ptrCast(@alignCast(raw));
        return .{ .text = fake.notice, .stoppable = work == .working and !fake.stopping };
    }

    fn lender(fake: *FakeOverview) Lender {
        return .{ .context = fake, .step = FakeOverview.step, .service = FakeOverview.service, .line = FakeOverview.line, .observed = quiet_overview.observed, .upgrade = quiet_overview.upgrade };
    }
};

test "Ctrl-X stops the open Session through the overview at once, asking nothing" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    var overview: FakeOverview = .{};
    held.self.lender = overview.lender();
    held.self.line = .{ .read = .{ .revision = 1, .end = 1 } };
    try held.self.line.model.set("gpt-6-sol");
    held.self.live.work.state = .{ .working = .{ .since = 1 } };
    // One Ctrl-X stops, with the draft kept and nothing asked.
    try sendKeys(&held.self, "x\x18");
    try std.testing.expectEqual(@as(usize, 1), overview.stops);
    try std.testing.expectEqualStrings("x", held.self.input.composition().bytes);
    try std.testing.expect(held.self.leaving == null);
    try std.testing.expect(held.self.app_consent.request == null);
    // Another while it stops stops nothing more.
    try sendKeys(&held.self, "\x18");
    try std.testing.expectEqual(@as(usize, 1), overview.stops);
    // Until the Session opens its work is unknown: Ctrl-X says so and
    // stops nothing.
    overview = .{};
    held.self.reading.opening = true;
    try sendKeys(&held.self, "\x18");
    try std.testing.expectEqual(@as(usize, 0), overview.stops);
    try std.testing.expect(try rowWith(held, "Ctrl-X stops the Session once it opens.") != null);
}

/// The latest frame's first row that holds `needle`, without its trailing
/// blanks.
fn rowWith(held: *HeldFrontend, needle: []const u8) !?[]const u8 {
    var rows = std.mem.splitScalar(u8, try held.shown(), '\n');
    while (rows.next()) |row| {
        const text = std.mem.trimEnd(u8, row, " ");
        if (std.mem.indexOf(u8, text, needle) != null) return text;
    }
    return null;
}

/// Shows a /status page as a scan that read it does: the page asked for,
/// or, with `open` false, the page shown refreshed in place. Its Session is
/// the sample's named `label`, with the model the composer names and no
/// web search.
fn showStatus(held: *HeldFrontend, open: bool, label: []const u8) !void {
    const self = &held.self;
    const session = &self.inspection.sessions[if (self.inspection.status) |shown| ~shown else 0];
    status_page.sample(session);
    session.tools.remove(.web_search);
    try session.model.set("gpt-5.5");
    try session.label.set(label);
    self.job.status_taken = session;
    self.job.result.status = true;
    self.job.open_status = open;
    self.inspection.status_requested = open;
    try self.applyStatus();
    self.dirty = true;
    try held.settle();
}

/// Gives `held` the files a /status page needs, and a HOME with no saved
/// defaults.
fn statusFiles(held: *HeldFrontend) !void {
    const io = std.testing.io;
    held.self.files.status = try held.tmp.dir.createFile(io, "status", .{ .read = true });
    for (&held.self.files.actions, 0..) |*file, index| file.* = try held.tmp.dir.createFile(io, if (index == 0) "actions0" else "actions1", .{ .read = true });
    held.self.home = held.self.directory;
}

fn closeStatusFiles(held: *HeldFrontend) void {
    held.self.files.status.close(std.testing.io);
    for (held.self.files.actions) |file| file.close(std.testing.io);
}

test "defaults no path or file names are unreadable, and none saved are Rui's" {
    try std.testing.expectError(error.InvalidHome, savedDefaults(""));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    const saved = try savedDefaults(home);
    try std.testing.expectEqual(status_page.Saved.rui, try saved.provider);
    var store: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&store, "{s}/.local/share/rui/store", .{home}), (try saved.store).slice());
}

test "the /status page marks one changeable row, which Up and Down move and Enter starts changing" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try statusFiles(held);
    defer closeStatusFiles(held);
    held.self.line = .{ .read = .{ .revision = 1, .end = 1 }, .effort = .high };
    try held.self.line.model.set("gpt-5.5");
    try showStatus(held, true, "fix-safari-export");
    try std.testing.expectEqualStrings(" › Effort          high  Session override", (try rowWith(held, "Effort ")).?);
    try std.testing.expectEqualStrings("   Permissions     bypass · Bash and MCP run without asking", (try rowWith(held, "Permissions")).?);
    // Shift-Down scrolls as before; the mark stays.
    try sendKeys(&held.self, "\x1b[1;2B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Effort ")).?, " › Effort"));
    // Down moves the mark, past the Session's fixed Model, Store and
    // Instructions to the defaults' Model; PageUp and PageDown still scroll.
    try sendKeys(&held.self, "\x1b[B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Effort ")).?, "   Effort"));
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Permissions")).?, " › Permissions"));
    for (0..6) |_| try sendKeys(&held.self, "\x1b[B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Rui default")).?, " › Model"));
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "fixed for this Session")).?, "   Model"));
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "set from a shell")).?, "   Instructions"));
    // A refresh, as the open page's next read, keeps the mark.
    try showStatus(held, false, "fix-safari-export");
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Rui default")).?, " › Model"));
    try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Headroom")).?, " › Headroom"));
    // Enter on Headroom drafts only its command, whose list offers
    // `default`: the model's default never becomes an override of its value.
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqualStrings("/configure --output-reservation ", held.self.input.composition().bytes);
    // With a draft, Up and Down keep their meaning: the mark stays.
    try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Headroom")).?, " › Headroom"));
    held.self.input.clear();
    for (0..8) |_| try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Effort ")).?, " › Effort"));
    // Enter on a choice row lists its choices; Down and Enter take one and run it.
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqualStrings("/configure --reasoning-effort ", held.self.input.composition().bytes);
    // The list the next frame draws takes the arrows and Enter.
    held.self.dirty = true;
    try held.settle();
    const list = held.screen.commands.?.list;
    for (list.shown()) |entry| try std.testing.expectEqual(std.mem.eql(u8, entry.word, "high"), std.mem.eql(u8, entry.description, "current"));
    try sendKeys(&held.self, "\x1b[B\r");
    var expected: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/configure --reasoning-effort {s}", .{list.shown()[1].word}), held.self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try std.testing.expect(std.mem.startsWith(u8, (try rowWith(held, "Effort ")).?, " › Effort"));
}

test "a change run from the /status page replies under the page, which shows the new value on its row; a long failure opens as before" {
    const Reply = struct {
        var text: []const u8 = undefined;
        fn write(context: *anyopaque, _: *Task) !void {
            const frontend: *Self = @ptrCast(@alignCast(context));
            try frontend.files.inspection.writePositionalAll(std.testing.io, text, 0);
        }
    };
    const long = comptime long: {
        var text: []const u8 = "";
        for (0..40) |_| text = text ++ "rui: --label is 1-100 printable characters; nothing changed\n";
        break :long text;
    };
    for ([_]bool{ true, false }) |configured| {
        errdefer std.debug.print("configured={}\n", .{configured});
        const held = try HeldFrontend.create();
        defer held.destroy();
        try statusFiles(held);
        defer closeStatusFiles(held);
        held.self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "inspection", .{ .read = true });
        defer held.self.files.inspection.close(std.testing.io);
        try showStatus(held, true, "fix-safari-export");
        // The defaults are read as the page opens, not on each read after.
        const readiness: preferences.Readinesses = .initFill(.missing);
        _ = try preferences.update(held.self.home, .{ .notifications = false }, &readiness);
        try showStatus(held, false, "fix-safari-export");
        try std.testing.expectEqualStrings("   Notifications   on", (try rowWith(held, "Notifications")).?);
        for (0..3) |_| try sendKeys(&held.self, "\x1b[B");
        try sendKeys(&held.self, "\r");
        try std.testing.expectEqualStrings("/configure --label fix-safari-export", held.self.input.composition().bytes);
        // Edited, and run as the loop runs a queued command.
        for (0.."fix-safari-export".len) |_| try sendKeys(&held.self, "\x7f");
        try sendKeys(&held.self, "\"lane four\"\r");
        const text = held.self.input.takeCommand().?;
        try std.testing.expectEqualStrings("/configure --label \"lane four\"", text);
        try held.self.leaveFor(parse(text).inspection);
        held.self.inspection.kind = .command;
        held.self.inspection.command_running = true;
        held.self.reading.phase = .inspection;
        @memcpy(held.self.job.command_text[0..text.len], text);
        held.self.job.command_text_length = text.len;
        Reply.text = if (configured) "Rui: Configured.\n" else long;
        try held.self.reader.start(std.testing.io, &held.self, Reply.write);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), &held.self, struct {
            fn joined(frontend: *Self) !bool {
                return frontend.reader.completed();
            }
        }.joined);
        try held.self.settleReader();
        held.self.dirty = true;
        try held.settle();
        if (configured) {
            // The reply is the notice on the last row, under the page.
            try std.testing.expectEqualStrings("Configured.", (try rowWith(held, "Configured.")).?);
            // A command run over the page reads them again.
            try std.testing.expectEqualStrings("   Notifications   off", (try rowWith(held, "Notifications")).?);
            try std.testing.expectEqualStrings(" › Name            fix-safari-export", (try rowWith(held, "Name")).?);
            // The open page's next read shows the new value, its mark where it was.
            try showStatus(held, false, "lane four");
            try std.testing.expectEqualStrings(" › Name            lane four", (try rowWith(held, "Name")).?);
        } else {
            try std.testing.expect((try rowWith(held, "--label is 1-100")) != null);
            try std.testing.expect((try rowWith(held, " Name ")) == null);
        }
    }
}

test "/upgrade starts the overview's run, consumes only its line and keeps the original submission; Esc is the run's" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    var overview: ArchiveOverview = .{ .state = undefined };
    try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
    defer overview.state.deinit();
    held.self.lender = overview.lender();
    const self = &held.self;
    const original = self.input.submitText("original indeterminate model input");
    self.submission.intent = .{ .message = original };
    self.submission.state = .unconfirmed;
    self.submission.key = @splat('K');
    self.submission.retry = @splat('K');
    // Blocked by an earlier run, as free: /upgrade is the hold's own command.
    for ([_]session_upgrade.After{ .open, .blocked }) |after| {
        overview.state.upgrade = .{ .after = after };
        try sendKeys(self, "/upgrade\r");
        try std.testing.expect(overview.state.upgrade.run.? == .checking);
        try std.testing.expectEqualStrings("", self.input.composition().bytes);
        try std.testing.expect(self.input.queuedCommand() == null);
        try std.testing.expectEqual(session_upgrade.Phase.quiescing, self.upgradePhase());
        try std.testing.expectEqualStrings("Checking for updates…", self.lender.line(self.lender.context, .idle).text.?);
        // Another /upgrade changes nothing, and Esc asks the run to stop
        // before it does anything else.
        try sendKeys(self, "/upgrade\r");
        try std.testing.expect(overview.state.upgrade.run.? == .checking);
        try sendKeys(self, "keep\x1b");
        try std.testing.expectEqual(@as(usize, 1), overview.cancels);
        overview.cancels = 0;
        try std.testing.expectEqualStrings("keep", self.input.composition().bytes);
        try std.testing.expect(self.leaving == null);
        try sendKeys(self, "\x15");
        _ = try overview_view.step(&overview.state, .{ .upgrade = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } });
    }
    try std.testing.expectEqualStrings("original indeterminate model input", try self.input.message(original));
    try std.testing.expectEqualStrings(&@as([36]u8, @splat('K')), &self.submission.view().?.key);
    try std.testing.expectEqual(Submission.State.unconfirmed, self.submission.view().?.state);
    try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
}

test "a run quiesces the conversation's Client work, and its end holds Host requests until the conversation reads again" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try std.testing.expect(self.atRest() and !self.upgradeHeld());
    held.upgrade = .{ .run = .checking };
    try std.testing.expectEqual(Updated.waiting, try self.update());
    try std.testing.expect(self.atRest() and self.upgrade_stale);
    // The listing is read again before this conversation is: still held.
    held.upgrade = .{ .run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } };
    try std.testing.expectEqual(session_upgrade.Phase.reobserving, self.upgradePhase());
    try sendKeys(self, "not yet\r");
    try std.testing.expect(self.submission.view() == null);
    try std.testing.expectEqualStrings("not yet", self.input.composition().bytes);
    try std.testing.expectEqualStrings(session_upgrade.refusal(.reobserving), self.shown_notice.current(self.nowMs()).?);
    // Its status row says so in place of the run's ending, which shows
    // only once Host requests go on.
    self.shown_notice.dismiss();
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), session_upgrade.rereading) != null);
    self.upgrade_stale = false;
    try std.testing.expect(!self.upgradeHeld());
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), session_upgrade.rereading) == null);
}

test "a conversation is at rest for an Upgrade only with no work running or finished and not yet joined" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *Task) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
        fn idle(_: *anyopaque, _: *Task) !void {}
        fn completed(reader: *Task) bool {
            return reader.completed();
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try std.testing.expect(self.atRest());
    // Running, then finished and not yet joined.
    try self.reader.start(std.testing.io, self, Worker.read);
    try std.testing.expect(!self.atRest());
    self.reader.cancel();
    _ = self.joinReader();
    try std.testing.expect(self.atRest());
    try self.reader.start(std.testing.io, self, Worker.idle);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &self.reader, Worker.completed);
    try std.testing.expect(!self.atRest());
    _ = self.joinReader();
    try std.testing.expect(self.atRest());
}

test "no command waits its turn across an Upgrade: /upgrade is refused while one does, and a run's hold refuses every one after" {
    const lines = [_][]const u8{ "/status", "/requests", "/help", "/copy", "/configure --reasoning-effort low" };
    for (lines) |line| {
        errdefer std.debug.print("line={s}\n", .{line});
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        const self = &held.self;
        // Queued, then /upgrade before the conversation's next pass.
        self.input.queueCommand(line);
        try sendKeys(self, "/upgrade\r");
        try std.testing.expect(!overview.state.upgrading());
        try std.testing.expectEqualStrings("/upgrade", self.input.composition().bytes);
        try std.testing.expectEqualStrings(line, self.input.queuedCommand().?);
        // The other order: the run first, then the command.
        _ = self.input.takeCommand();
        try sendKeys(self, "\r");
        try std.testing.expect(overview.state.upgrading());
        try sendKeys(self, line);
        try sendKeys(self, "\r");
        try std.testing.expect(self.input.queuedCommand() == null);
        try std.testing.expectEqualStrings(line, self.input.composition().bytes);
        try std.testing.expectEqual(Updated.waiting, try self.update());
        try std.testing.expect(self.atRest());
    }
}

test "an Upgrade's hold shows no permission card and sends no decision, shown or prepared" {
    for (0..3) |hold| for ([_]bool{ false, true }) |shown| for ([_]bool{ false, true }) |ticked| {
        errdefer std.debug.print("hold={d} shown={} ticked={}\n", .{ hold, shown, ticked });
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        var file: ?std.Io.File = null;
        defer if (file) |open| open.close(std.testing.io);
        if (shown) {
            file = try held.adopt(3);
            try std.testing.expectEqual(@as(?u64, 0xa), self.app_consent.request);
        } else {
            // A permission read that finished and is not yet shown.
            self.reading.prepared_action = 0xa;
            self.live.work.first_action = 0xa;
        }
        held.upgrade = heldUpgrade(hold, .{ .reobserving, .blocked });
        // The overview's pass may come first: a key before this
        // conversation's own pass still decides nothing.
        if (ticked) try held.settle();
        if (ticked) try std.testing.expect(self.app_input.permission == null and self.app_consent.request == null and self.reading.prepared_action == null);
        try stepKeys(held, "\r");
        try std.testing.expect(self.submission.view() == null and self.submission.task.thread == null);
        try held.settle();
        try std.testing.expect(self.app_input.permission == null and self.app_consent.request == null);
        try std.testing.expect(self.submission.view() == null and self.submission.task.thread == null);
    };
}

test "upgrade quiescing reobservation and protocol holds refuse a fresh Message without clearing its draft" {
    for (0..3) |hold| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.upgrade = heldUpgrade(hold, .{ .reobserving, .blocked });
        try sendKeys(&held.self, "never send before safe reattachment\r");
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expect(held.self.submission.task.thread == null);
        try std.testing.expectEqualStrings("never send before safe reattachment", held.self.input.composition().bytes);
    }
}

const ArchiveOverview = struct {
    state: overview_view.State,
    archives: usize = 0,
    stops: usize = 0,
    host_inputs: usize = 0,
    cancels: usize = 0,
    said: [256]u8 = undefined,
    archived: ?overview_view.Reference = null,
    requested: bool = true,

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        switch (input) {
            .other, .upgrade, .cancel_upgrade, .upgrade_failed => {},
            .stop, .archive, .unarchive => self.host_inputs += 1,
        }
        const effects = try overview_view.step(&self.state, .{ .conversed = .{ .reference = "k7m2qx".*, .work = work, .input = input } });
        for (effects.slice()) |effect| switch (effect) {
            .archive => |request| {
                self.archives += 1;
                self.archived = request.reference;
                self.requested = request.archived;
            },
            .stop => self.stops += 1,
            .cancel_upgrade => self.cancels += 1,
            else => return error.TestUnexpectedEffect,
        };
    }

    fn line(raw: *anyopaque, work: protocol.session_work.Kind) Lender.Said {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        const said = overview_view.conversation(&self.state, "k7m2qx".*, work, .{}, self.said[0..160]);
        return .{ .text = said.text, .stoppable = said.stoppable };
    }

    fn upgrade(raw: *anyopaque) session_upgrade.Upgrade {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        return self.state.upgrade;
    }

    fn lender(self: *ArchiveOverview) Lender {
        return .{ .context = self, .step = ArchiveOverview.step, .line = ArchiveOverview.line, .service = quiet_overview.service, .observed = quiet_overview.observed, .upgrade = ArchiveOverview.upgrade };
    }
};

test "Alt-A archives the open conversation at once without submitting or changing its draft or retained original" {
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| for ([_]bool{ false, true }) |original| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        const ticket: ?Input.Ticket = if (original) held.self.input.submitText("retained original") else null;
        try sendKeys(&held.self, "/rename unfinished\x1b[D\x1b[D");
        const before = held.self.input.composition();
        const revision = held.self.input.revision;
        try sendKeys(&held.self, chord);
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        try std.testing.expect(held.self.leaving == null);
        _ = try overview_view.step(&overview.state, .{ .archive = .{ .request = .{ .reference = "k7m2qx".* }, .outcome = .{ .failed = "archive_pending" } } });
        try std.testing.expectEqualStrings("/rename unfinished", held.self.input.composition().bytes);
        try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.submission.view() == null);
        if (original) try std.testing.expectEqualStrings("retained original", try held.self.input.message(ticket.?));
    };
}

test "Alt-A and Ctrl-X during opening forward no intent and keep the draft" {
    for ([_][]const u8{ "\x1ba", "\x18" }) |chord| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        try sendKeys(&held.self, "keep draft\x1b[D");
        const revision = held.self.input.revision;
        const cursor = held.self.input.composition().cursor;
        held.self.reading.opening = true;
        try sendKeys(&held.self, chord);
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
        try std.testing.expectEqualStrings("keep draft", held.self.input.composition().bytes);
        try std.testing.expectEqual(cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
    }
}

const UnusedArchiveCommand = struct {
    var calls: usize = 0;

    fn command(_: std.process.Init, _: client.Requests, _: []const u8, _: []const u8, _: []u8) !void {
        calls += 1;
        return error.TestUnexpectedCommand;
    }
};

test "conversation slash archive archives a busy Session at once and consumes only its submitted command" {
    for ([_]bool{ false, true }) |completion| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.command = UnusedArchiveCommand.command;
        UnusedArchiveCommand.calls = 0;
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        const original = held.self.input.submitText("retained original");
        // A second /archive while the first is pending sends nothing more.
        for (0..2) |attempt| {
            errdefer std.debug.print("slash archive completion={} attempt={d} draft={s} notice={s}\n", .{ completion, attempt, held.self.input.composition().bytes, held.self.notice orelse "" });
            try sendKeys(&held.self, if (completion) "/arch" else "/archive");
            if (completion) try held.settle();
            try sendKeys(&held.self, "\r");
            try std.testing.expectEqual(@as(usize, 1), overview.archives);
            try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
            try std.testing.expect(held.self.input.queuedCommand() == null);
        }
        try std.testing.expectEqual(@as(usize, 0), UnusedArchiveCommand.calls);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        try std.testing.expect(overview.requested);
        try std.testing.expectEqual(protocol.SessionArchiveState.active, held.self.line.archive_state);
        try std.testing.expectEqualStrings("retained original", try held.self.input.message(original));
        try std.testing.expect(held.self.submission.view() == null);
    }
}

test "conversation slash and shortcut archive restore share one pending or unknown ledger and recovery handle" {
    for ([_]bool{ false, true }) |restore| for ([_]bool{ false, true }) |unknown| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.command = UnusedArchiveCommand.command;
        UnusedArchiveCommand.calls = 0;
        try sendKeys(&held.self, if (restore) "/unarchive\r" else "/archive\r");
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(!restore, overview.requested);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        if (unknown) _ = try overview_view.step(&overview.state, .{ .archive = .{ .request = .{ .reference = "k7m2qx".*, .archived = !restore }, .outcome = .{ .unconfirmed = "saved-archive-handle" } } });
        try sendKeys(&held.self, if (restore) "/archive\r" else "/unarchive\r");
        try sendKeys(&held.self, "\x1ba");
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(@as(usize, 1), overview.state.request_count);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.input.submitted == null);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqual(@as(usize, 0), UnusedArchiveCommand.calls);
        if (unknown) {
            var bytes: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try overview_view.writeDeparture(&overview.state, null, &out);
            try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "saved-archive-handle") != null);
        }
    };
}

test "Ctrl-X stops at once beside a typed slash archive, and Enter then archives" {
    for ([_][]const u8{"\r"}) |enter| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        try sendKeys(&held.self, "/archive\x18");
        try std.testing.expectEqual(@as(usize, 1), overview.stops);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqualStrings("/archive", held.self.input.composition().bytes);
        try sendKeys(&held.self, enter);
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    }
}

test "conversation slash archive errors propagate and consume only the submitted line" {
    const Failed = struct {
        fn step(_: *anyopaque, _: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
            if (input == .archive or input == .unarchive) return error.TestArchiveDispatchFailed;
        }
    };
    for ([_][]const u8{ "/archive\r", "/unarchive\r" }) |command| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.self.lender.step = Failed.step;
        const original = held.self.input.submitText("original");
        try std.testing.expectError(error.TestArchiveDispatchFailed, sendKeys(&held.self, command));
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        try std.testing.expectEqualStrings("original", try held.self.input.message(original));
        try std.testing.expect(held.self.input.queuedCommand() == null);
    }
}

test "upgrade holds classify every lender intent before forwarding and allow local cancellation" {
    const inputs: []const overview_view.ConversationInput = &.{ .stop, .{ .archive = .active }, .unarchive };
    for (0..3) |hold| for (inputs) |input| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        overview.state.upgrade = heldUpgrade(hold, .{ .blocked, .reobserving });
        try held.self.converse(input);
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
        try std.testing.expectEqualStrings(session_upgrade.refusal(held.self.upgradePhase()), held.self.notice.?);
        try held.self.converse(.other);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
    };
}

test "upgrade holds refuse archive shortcuts and slash commands without consuming custody" {
    const Path = enum { alt_a, kitty_alt_a, legacy_alt_a, slash_archive, slash_unarchive };
    for (0..3) |hold| for ([_]protocol.session_work.Kind{ .idle, .working, .approval }) |work| for (std.enums.values(Path)) |path| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = switch (work) {
            .idle => .{ .idle = .{ .since = 1 } },
            .working => .{ .working = .{ .since = 1 } },
            .approval => .{ .approval = .{ .since = 1 } },
            else => unreachable,
        };
        const original = held.self.input.submitText("original request");
        held.self.submission.intent = .{ .message = original };
        held.self.submission.state = .unconfirmed;
        held.self.submission.key = @splat('H');
        try sendKeys(&held.self, switch (path) {
            .slash_archive => "/archive",
            .slash_unarchive => "/unarchive",
            else => "next é!\x1b[D",
        });
        const before = held.self.input.composition();
        const revision = held.self.input.revision;
        overview.state.upgrade = heldUpgrade(hold, .{ .blocked, .reobserving });
        try sendKeys(&held.self, switch (path) {
            .alt_a => "\x1ba",
            .kitty_alt_a => "\x1b[97;3u",
            .legacy_alt_a => "\x1b[27;3;97~",
            .slash_archive, .slash_unarchive => "\r",
        });
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
        try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
        try std.testing.expectEqualStrings(switch (path) {
            .slash_archive => "/archive",
            .slash_unarchive => "/unarchive",
            else => "next é!",
        }, held.self.input.composition().bytes);
        try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
        try std.testing.expectEqualStrings("original request", try held.self.input.message(original));
        try std.testing.expectEqualStrings(&@as([36]u8, @splat('H')), &held.self.submission.view().?.key);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.reader.thread == null and held.self.submission.task.thread == null);
    };
}

test "upgrade reobservation retains a refused archive command from the completion list" {
    for ([_][]const u8{ "/arch", "/unar" }) |line| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        try sendKeys(&held.self, line);
        try held.settle();
        overview.state.upgrade.after = .reobserving;
        try sendKeys(&held.self, "\r");
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, line, "/arch")) "/archive" else "/unarchive", held.self.input.composition().bytes);
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
    }
}

test "malformed UTF-8 rejects its line, and typing after it reaches the draft" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.settle();
    // A lead byte cut short by a character, then by Enter: vaxis reports
    // each as U+FFFD carrying the malformed bytes.
    for ([_][]const u8{ "\xc3(\r", "\xc3\r" }) |invalid| {
        errdefer std.debug.print("invalid={x}\n", .{invalid});
        try held.keys(invalid);
        try held.settle();
        const shown = try held.shown();
        try std.testing.expect(std.mem.indexOf(u8, shown, "Input rejected; nothing sent.") != null);
        try std.testing.expectEqual(null, held.self.input.submitted);
        try held.keys("hi");
        try held.settle();
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "› hi") != null);
        try held.keys("\x15");
        try held.settle();
    }
}

test "Alt-J adds no line and keeps the draft; Ctrl-J, Shift-Enter and Alt-Enter each add one" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.settle();
    const Case = struct { key: []const u8, draft: []const u8 };
    for ([_]Case{
        // Alt-J: legacy ESC prefix, Kitty and modifyOtherKeys.
        .{ .key = "\x1bj", .draft = "onetwo" },
        .{ .key = "\x1b[106;3u", .draft = "onetwo" },
        .{ .key = "\x1b[27;3;106~", .draft = "onetwo" },
        // Ctrl-J, Shift-Enter, and Alt-Enter as ESC CR, Kitty and modifyOtherKeys.
        .{ .key = "\n", .draft = "one\ntwo" },
        .{ .key = "\x1b[13;2u", .draft = "one\ntwo" },
        .{ .key = "\x1b\r", .draft = "one\ntwo" },
        .{ .key = "\x1b[13;3u", .draft = "one\ntwo" },
        .{ .key = "\x1b[27;3;13~", .draft = "one\ntwo" },
    }) |case| {
        errdefer std.debug.print("key={any}\n", .{case.key});
        held.self.input.clear();
        try held.keys("one");
        try held.keys(case.key);
        try held.keys("two");
        try held.settle();
        try std.testing.expectEqualStrings(case.draft, held.self.input.composition().bytes);
        try std.testing.expectEqual(null, held.self.input.submitted);
    }
}

test "a malformed key sequence rejects its line like malformed text: kept until Enter reports and clears it" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.settle();
    // Kitty and modifyOtherKeys keys past U+10FFFF: vaxis reports each as
    // an invalid key.
    for ([_][]const u8{ "\x1b[1114112u", "\x1b[27;3;1114112~" }) |invalid| {
        errdefer std.debug.print("invalid={any}\n", .{invalid});
        try held.keys("kept");
        try held.keys(invalid);
        try held.settle();
        try std.testing.expectEqualStrings("kept", held.self.input.composition().bytes);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "› kept") != null);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "Input rejected") == null);
        try held.keys("\r");
        try held.settle();
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "Input rejected; nothing sent.") != null);
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        try std.testing.expectEqual(null, held.self.input.submitted);
    }
}

test "a card taller than the screen says how many lines it hides and Shift-Down shows them" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.size = .{ .width = 100, .height = 30 };
    const file = try held.adopt(32);
    defer file.close(std.testing.io);
    for (0..40) |press| {
        errdefer std.debug.print("press={d}\n{s}\n", .{ press, held.shown() catch "" });
        const shown = try held.shown();
        // The last command row in view, and the rows of the 32 after it.
        var last: ?usize = null;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, shown, at, "row ")) |found| : (at = found + 4) last = try std.fmt.parseInt(usize, shown[found + 4 ..][0..3], 10);
        const hidden = 31 - last.?;
        var expected: [64]u8 = undefined;
        const hint = try std.fmt.bufPrint(&expected, "{d} more lines · shift+↓", .{hidden});
        if (hidden == 0) {
            try std.testing.expect(std.mem.indexOf(u8, shown, "more lines") == null);
            try std.testing.expect(press > 0);
            break;
        }
        try std.testing.expect(std.mem.indexOf(u8, shown, hint) != null);
        try std.testing.expect(std.mem.indexOf(u8, shown, " Allow once ") != null);
        try stepKeys(held, "\x1b[1;2B");
        try held.settle();
    } else return error.TestUnexpectedResult;
}

/// An App Session with a settled live view, for the chrome's tests.
const ChromeFixture = struct {
    /// What the fixture's overview says under the input.
    var overview_says: ?[]const u8 = null;

    environ: std.process.Environ.Map,
    screen: *Screen,
    tmp: std.testing.TmpDir,
    page: std.Io.File,
    interrupted: client.Cancellation = .{},
    self: *Self,
    root: Root,
    widget: vxfw.Widget = undefined,
    arena: std.heap.ArenaAllocator,
    ctx: vxfw.EventContext = undefined,

    const Hooks = struct {
        fn leave(_: *anyopaque, _: *vxfw.EventContext, _: Outcome) !void {}
        fn upgrade(_: *anyopaque, _: *vxfw.EventContext) !void {}
        fn copy(_: *anyopaque, _: std.Io.File, _: u64, _: u64) !void {}
        fn open(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {}
    };

    fn init(fixture: *ChromeFixture) !void {
        fixture.environ = try std.testing.environ.createMap(std.testing.allocator);
        fixture.screen = try std.testing.allocator.create(Screen);
        try fixture.screen.init(std.testing.io, &fixture.environ, false);
        fixture.tmp = std.testing.tmpDir(.{});
        fixture.page = try fixture.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
        var init_: std.process.Init = undefined;
        init_.io = std.testing.io;
        init_.gpa = std.testing.allocator;
        init_.environ_map = &fixture.environ;
        fixture.self = try std.testing.allocator.create(Self);
        const page = fixture.page;
        // The overview decides whether Ctrl-X has work to stop.
        var lender = quiet_overview;
        lender.line = struct {
            fn line(_: *anyopaque, kind: protocol.session_work.Kind) Lender.Said {
                return .{ .text = ChromeFixture.overview_says, .stoppable = kind == .working };
            }
        }.line;
        fixture.self.begin(init_, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } }, undefined, undefined, undefined, fixture.screen, &fixture.interrupted, lender);
        fixture.root = .{ .overview = empty_app_text.widget() };
        fixture.widget = fixture.self.attach(.{ .root = &fixture.root, .context = fixture.self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
        fixture.self.reading.opening = false;
        fixture.self.poll_at = std.math.maxInt(i96);
        fixture.arena = .init(std.testing.allocator);
        fixture.ctx = .{ .io = std.testing.io, .alloc = fixture.arena.allocator(), .cmds = .empty };
        var history: [100 * 20]u8 = undefined;
        var writer = std.Io.Writer.fixed(&history);
        for (0..100) |number| try writer.print("History line {d:0>3}\n", .{number});
        try fixture.screen.live.append(writer.buffered());
    }

    fn deinit(fixture: *ChromeFixture) void {
        fixture.arena.deinit();
        std.testing.allocator.destroy(fixture.self);
        fixture.page.close(std.testing.io);
        fixture.tmp.cleanup();
        fixture.screen.deinit();
        std.testing.allocator.destroy(fixture.screen);
        fixture.environ.deinit();
    }

    fn draw(fixture: *ChromeFixture) !vxfw.Surface {
        return fixture.widget.draw(.{ .arena = fixture.arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} });
    }

    fn press(fixture: *ChromeFixture, key: vaxis.Key) !void {
        try fixture.widget.handleEvent(&fixture.ctx, .{ .key_press = key });
    }

    fn now() u64 {
        return @intCast(@max(std.Io.Clock.real.now(std.testing.io).toMilliseconds(), 0));
    }

    /// The 80x24 screen a terminal shows after the next frame, one string
    /// per row with trailing blanks dropped, in the fixture's arena.
    fn rows(fixture: *ChromeFixture) ![24][]const u8 {
        const arena = fixture.arena.allocator();
        const surface = try fixture.draw();
        var screen: vaxis.Screen = try .init(arena, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
        surface.render(window, fixture.self.app_input.composer.widget());
        var result: [24][]const u8 = undefined;
        for (&result, 0..) |*line, row| {
            var out: std.Io.Writer.Allocating = .init(arena);
            var col: u16 = 0;
            while (screen.readCell(col, @intCast(row))) |cell| : (col += 1) {
                if (cell.char.width == 0 and cell.char.grapheme.len == 0) continue;
                try out.writer.writeAll(if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
                if (cell.char.width == 2) col += 1;
            }
            line.* = std.mem.trim(u8, out.written(), " ");
        }
        return result;
    }

    /// The first row at or after `from` that starts with `prefix`.
    fn find(shown: *const [24][]const u8, prefix: []const u8) ?usize {
        for (shown, 0..) |line, row| if (std.mem.startsWith(u8, line, prefix)) return row;
        return null;
    }

    fn call(operation: u64, ordinal: u64, description: []const u8) View.Live.Entry {
        var value: View.Live.Entry = std.mem.zeroes(View.Live.Entry);
        value.operation = operation;
        value.ordinal = ordinal;
        value.presentation.code = .unresolved;
        value.presentation.description = .{};
        value.presentation.description.?.set(description) catch unreachable;
        return value;
    }
};

test "App Session shows running calls in order above the input, with +N more running and the work line below them" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.live.view.entries = .{ ChromeFixture.call(7, 1, "Read src/overview_view.zig"), ChromeFixture.call(7, 2, "Run zig build test"), ChromeFixture.call(7, 3, "Read docs/using-rui.md") };
    self.live.view.count = 3;
    self.live.view.total = 5;
    self.live.work.state = .{ .working = .{ .since = ChromeFixture.now() / 1000 - 12 } };
    const shown = try fixture.rows();
    const first = ChromeFixture.find(&shown, "• Read src/overview_view.zig").?;
    try std.testing.expectEqualStrings("• Run zig build test", shown[first + 1]);
    try std.testing.expectEqualStrings("• Read docs/using-rui.md", shown[first + 2]);
    try std.testing.expectEqualStrings("+2 more running · /status", shown[first + 3]);
    // No shown call carries the clock, so the work line follows, once.
    try std.testing.expect(std.mem.eql(u8, shown[first + 4], "• Waiting · 12s") or std.mem.eql(u8, shown[first + 4], "• Waiting · 13s"));
    // The tail sits right above the input's top rule.
    try std.testing.expect(std.mem.startsWith(u8, shown[first + 5], "─"));
    var waiting: usize = 0;
    for (shown) |line| waiting += @intFromBool(std.mem.startsWith(u8, line, "• Waiting"));
    try std.testing.expectEqual(@as(usize, 1), waiting);
    // Work ends: the tail goes, and history reaches the rule again.
    self.live.view = .{};
    self.live.work.state = .{ .idle = .{ .since = 0 } };
    const idle = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&idle, "•") == null and ChromeFixture.find(&idle, "+") == null);
}

test "App Session shows the newest waiting Message as ◌ [N ·] its first line, without the word queued" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.live.work.state = .{ .working = .{ .since = ChromeFixture.now() / 1000 } };
    self.live.queued = .{ .count = 3, .oldest_position = 50, .newest_admission = 9, .newest_position = 70 };
    self.live.queued_line = .{ .admission = 9, .line = .{} };
    try self.live.queued_line.?.line.set("also update docs/using-rui.md");
    const three = try fixture.rows();
    const row = ChromeFixture.find(&three, "◌").?;
    try std.testing.expectEqualStrings("◌ 3 · also update docs/using-rui.md", three[row]);
    // The waiting row is the tail's last, under the work line.
    try std.testing.expect(std.mem.startsWith(u8, three[row - 1], "• Waiting"));
    try std.testing.expect(std.mem.startsWith(u8, three[row + 1], "─"));
    for (three) |line| try std.testing.expect(std.ascii.findIgnoreCase(line, "queued") == null);
    // One waiting: no count. A first line read for an older Message shows nothing.
    self.live.queued.count = 1;
    self.live.queued.oldest_position = 70;
    try std.testing.expectEqualStrings("◌ also update docs/using-rui.md", (try fixture.rows())[row]);
    self.live.queued_line.?.admission = 8;
    try std.testing.expect(ChromeFixture.find(&(try fixture.rows()), "◌") == null);
}

test "App Session's frame after Enter shows the Message as sending, the same frame that clears the composer" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = path[0..try fixture.tmp.dir.realPath(std.testing.io, &path)];
    self.directory = directory;
    self.submission.directory = directory;
    defer {
        self.submission.cancel();
        _ = self.submission.join();
        self.submission.close();
    }
    for ("hi") |byte| try fixture.press(.{ .codepoint = byte, .text = &.{byte} });
    try fixture.press(.{ .codepoint = vaxis.Key.enter });
    // No tick runs between Enter and this frame.
    const shown = try fixture.rows();
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    try std.testing.expectEqualStrings("Sending…", shown[23]);
    try std.testing.expectEqual(session_chrome.Tone.quiet, self.chrome.status.bar.tone);
}

test "App Session's status bar never says Sent: an accepted Message's row is its feedback, at the latest view and scrolled back" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    // Accepted with no original held: the bar is empty, so the overview's
    // line shows there.
    try std.testing.expectEqualStrings("", (try fixture.rows())[23]);
    ChromeFixture.overview_says = "Port overview to vxfw finished";
    defer ChromeFixture.overview_says = null;
    try std.testing.expectEqualStrings("Port overview to vxfw finished", (try fixture.rows())[23]);
    ChromeFixture.overview_says = null;
    // A Message waiting behind work shows as its waiting row at the latest
    // view; scrolled back, where that row is out of view, nothing says Sent.
    self.live.work.state = .{ .working = .{ .since = ChromeFixture.now() / 1000 } };
    self.live.queued = .{ .count = 1, .oldest_position = 70, .newest_admission = 9, .newest_position = 70 };
    self.live.queued_line = .{ .admission = 9, .line = .{} };
    try self.live.queued_line.?.line.set("also update docs/using-rui.md");
    const latest = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&latest, "◌ also update docs/using-rui.md") != null);
    for (latest) |row| try std.testing.expect(std.mem.indexOf(u8, row, "Sent") == null);
    try fixture.press(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    const browsing = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&browsing, "◌") == null);
    for (browsing) |row| try std.testing.expect(std.mem.indexOf(u8, row, "Sent") == null);
}

test "App Session's Ctrl-X while the Session opens says why it stopped nothing, over Opening…, until the next key" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.reading.opening = true;
    try std.testing.expectEqualStrings("Opening…", (try fixture.rows())[23]);
    try fixture.press(.{ .codepoint = 'x', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("Ctrl-X stops the Session once it opens.", (try fixture.rows())[23]);
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    try std.testing.expectEqualStrings("Opening…", (try fixture.rows())[23]);
}

test "App Session's facts row ends with the archive badge while the Session is archived or archiving" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const facts = struct {
        fn row(shown: *const [24][]const u8) []const u8 {
            return shown[ChromeFixture.find(shown, "‹").?];
        }
    }.row;
    try std.testing.expectEqualStrings("‹ k7m2qx", facts(&try fixture.rows()));
    self.line.archive_state = .archived;
    try std.testing.expectEqualStrings("‹ k7m2qx · Archived · /unarchive", facts(&try fixture.rows()));
    self.line.archive_state = .archiving;
    try std.testing.expectEqualStrings("‹ k7m2qx · Stopping and archiving", facts(&try fixture.rows()));
    // A notice on the last row leaves the badge where it is.
    self.shown_notice.show("Copied 3 lines", ChromeFixture.now());
    const shown = try fixture.rows();
    try std.testing.expectEqualStrings("‹ k7m2qx · Stopping and archiving", facts(&shown));
    try std.testing.expectEqualStrings("Copied 3 lines", shown[23]);
}

test "App Session's facts fit the row after ‹ whole: a fact that would not fit drops, marked …" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    // 48 cells of name and 30 of the rest: 78 cells, one more than the 77
    // after ` ‹ ` on an 80-column row.
    self.line = .{ .read = .{ .revision = 1, .end = 1 }, .effort = .low, .left = 100, .label = .{} };
    try self.line.label.?.set("Port the overview to vxfw and keep its key table");
    try self.line.model.set("gpt-6-sol");
    const shown = try fixture.rows();
    try std.testing.expectEqualStrings("‹ Port the overview to vxfw and keep its key table · gpt-6-sol · low · …", shown[22]);
}

test "App Session's last row offers ctrl+x stop at the right while work runs, beside the overview's notice" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.live.work.state = .{ .working = .{ .since = ChromeFixture.now() / 1000 } };
    ChromeFixture.overview_says = "Port overview to vxfw finished";
    defer ChromeFixture.overview_says = null;
    const shown = try fixture.rows();
    try std.testing.expect(std.mem.startsWith(u8, shown[23], "Port overview to vxfw finished"));
    try std.testing.expect(std.mem.endsWith(u8, shown[23], " ctrl+x stop"));
    // Work ends: the stop key goes; the overview's notice stays its own.
    self.live.work.state = .{ .idle = .{ .since = 0 } };
    try std.testing.expectEqualStrings("Port overview to vxfw finished", (try fixture.rows())[23]);
}

test "App Session's last row says the send state, which stays past a key and five seconds" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const original = self.input.submitText("original model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .submitting, .key = @splat('K') };
    defer self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    try std.testing.expectEqualStrings("Sending…", (try fixture.rows())[23]);
    self.submission.state = .unconfirmed;
    // A notice arrives and goes; what needs the person outranks it and stays.
    self.shown_notice.show("Copied 3 lines", ChromeFixture.now() - 6_000);
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    const unconfirmed = try fixture.rows();
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries original", unconfirmed[23]);
    try std.testing.expectEqualStrings("ctrl+r retries original", self.chrome.status.key.label);
}

test "App Session's last row keeps a rejection's code until /discard, past a key and five seconds" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const original = self.input.submitText("original model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .rejected, .key = @splat('K') };
    defer self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("message_too_long");
    try self.presentAdmission(.{ .rejected = .{ .kind = .message, .code = code } });
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    self.shown_notice.show("Copied 3 lines", ChromeFixture.now() - 6_000);
    try std.testing.expectEqualStrings("! Input rejected: message_too_long · /discard", (try fixture.rows())[23]);
    try std.testing.expectEqualStrings("/discard", self.chrome.status.key.label);
    // Another original rejected keeps its own code, not this one's.
    self.submission.key = @splat('L');
    try std.testing.expectEqualStrings("Rejected · /discard", (try fixture.rows())[23]);
}

test "App Session's last row says a refused environment until the original goes, and /status says why and the fix" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try statusFiles(held);
    defer closeStatusFiles(held);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    const big: [200]u8 = @splat('x');
    try environ.put("BIG_TOKEN", &big);
    held.self.submission.environment = .{ .map = &environ };
    defer held.self.submission.environment = .empty;
    const original = held.self.input.submitText("original model input");
    held.self.submission.intent = .{ .message = original };
    held.self.submission.state = .not_started;
    held.self.submission.key = @splat('K');
    try held.self.presentAdmission(.{ .failed = .{ .err = error.EnvironmentTooLarge } });
    held.self.dirty = true;
    try held.settle();
    const bar = (try rowWith(held, "Environment too large")).?;
    try std.testing.expectEqualStrings("! Environment too large; nothing sent · /status", bar);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r") == null);
    try showStatus(held, true, "fix-safari-export");
    for (0..4) |_| try sendKeys(&held.self, "\x1b[6~");
    try held.settle();
    try std.testing.expect((try rowWith(held, "BIG_TOKEN")) != null);
    try std.testing.expectEqualStrings("Unset or shorten them in another shell, then run rui request recover there.", (try rowWith(held, "rui request recover")).?);
    try std.testing.expect((try rowWith(held, "Ctrl-R retries this exact original")) == null);
}

test "App Session shows a command's two-line result as a page, both lines whole" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "inspection", .{ .read = true });
    defer held.self.files.inspection.close(std.testing.io);
    try held.self.files.inspection.writePositionalAll(std.testing.io, "Rui: Saved defaults.\nrui: Host unavailable; the Session keeps its settings\n", 0);
    held.self.inspection.kind = .command;
    held.self.reading.phase = .inspection;
    try held.self.showInspection();
    held.self.dirty = true;
    try held.settle();
    try std.testing.expect((try rowWith(held, "Saved defaults.")) != null);
    try std.testing.expect((try rowWith(held, "Host unavailable; the Session keeps its settings")) != null);
}

test "App Session's chrome clicks that run a command say so while another waits its turn, and run nothing" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.input.queueCommand("/requests");
    // `+N more running · /status`, twice before any tick.
    for (0..2) |_| try self.chrome.activity.more.on_click(self.chrome.activity.more.userdata, &fixture.ctx);
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("! Command still running. Draft retained.", (try fixture.rows())[23]);
    // A typed command meets the same rule and says the same.
    self.shown_notice.dismiss();
    _ = self.input.append("/model");
    try fixture.press(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("/model", self.input.composition().bytes);
    try std.testing.expectEqualStrings("! Command still running. Draft retained.", (try fixture.rows())[23]);
    // A needs key that names a command: `/discard` on a rejected original.
    const original = self.input.submitText("original model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .rejected, .key = @splat('K') };
    defer self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    try self.chrome.status.key.on_click(self.chrome.status.key.userdata, &fixture.ctx);
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqual(Submission.State.rejected, self.submission.view().?.state);
    try std.testing.expectEqualStrings("! Command still running. Draft retained.", self.shown_notice.current(self.nowMs()).?);
    // Once none waits, the key runs what the held original's line names:
    // a refused environment's `/status`, never a retry.
    _ = self.input.takeCommand();
    self.submission.state = .not_started;
    self.holdFailure(.{ .line = session_notice.too_large, .key = .status }, null);
    try self.chrome.status.key.on_click(self.chrome.status.key.userdata, &fixture.ctx);
    try std.testing.expectEqualStrings("/status", self.input.queuedCommand().?);
    try std.testing.expectEqual(Submission.State.not_started, self.submission.view().?.state);
}

test "App Session shows work under way at the transcript's tail, and the ↓ marker in its place while scrolled back" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.live.work.state = .{ .working = .{ .since = ChromeFixture.now() / 1000 } };
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.tail != null);
    try std.testing.expect(self.app_screen.marker == null);
    try std.testing.expectEqualStrings("Waiting", self.chrome.activity.work.?.words);
    try std.testing.expect(self.chrome.status.bar.stop);

    try fixture.press(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.tail == null);
    try std.testing.expect(self.app_screen.marker.?.eql(self.chrome.marker.widget()));
    try std.testing.expectEqualStrings("↓", self.chrome.marker.label);
    // The marker counts entries live output showed since, never how far
    // the Activity's positions moved: a read of items that show nothing
    // adds none.
    self.live.cursor.position += 40;
    self.job.result = .{};
    try self.showStaged();
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("↓", self.chrome.marker.label);
    self.live.cursor.position += 1;
    self.job.result = .{ .entries = 2 };
    try self.showStaged();
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("↓ 2 new", self.chrome.marker.label);

    try fixture.press(.{ .codepoint = vaxis.Key.escape });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.marker == null);
    try std.testing.expect(self.app_screen.tail != null);
}

test "App Session's ↓ marker takes a row of its own while scrolled back, so no Message's time hides under it" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Messages whose time ends at the last column, each telling its row.
    var timed: [40 * 48]u8 = undefined;
    var writer = std.Io.Writer.fixed(&timed);
    for (0..40) |number| try writer.print("\x1b[94m›\x1b[39m \x1b[8m14:{d:0>2}\x1b[0mRow {d:0>2}\n", .{ number, number });
    try fixture.screen.live.append(writer.buffered());
    const live = try fixture.rows();
    try std.testing.expect(std.mem.startsWith(u8, live[18], "› Row 39") and std.mem.endsWith(u8, live[18], "14:39"));
    try fixture.press(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    const shown = try fixture.rows();
    // The marker alone at the right of the row above the input's rule.
    try std.testing.expectEqualStrings("↓", std.mem.trim(u8, shown[18], " "));
    try std.testing.expect(std.mem.startsWith(u8, shown[19], "─"));
    // Every Message the transcript drew keeps its whole time.
    var drawn: usize = 0;
    for (shown[0..18]) |row| if (std.mem.startsWith(u8, row, "› Row ")) {
        try std.testing.expectEqualStrings(row["› Row ".len..][0..2], row[row.len - 2 ..]);
        drawn += 1;
    };
    try std.testing.expectEqual(@as(usize, 18), drawn);
}

test "App Session's Shift-↓ returns to the latest once it reaches where the latest view starts, the marker's row included" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const latest = try fixture.rows();
    try fixture.press(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.marker != null);
    try fixture.press(.{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } });
    const returned = try fixture.rows();
    try std.testing.expect(self.app_screen.marker == null);
    try std.testing.expectEqualDeep(latest, returned);
}

test "App Session's End no longer returns to the latest; Esc and the marker do" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    try fixture.press(.{ .codepoint = vaxis.Key.page_up });
    _ = try fixture.draw();
    const anchor = self.app_content.first;
    try fixture.press(.{ .codepoint = vaxis.Key.end });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.marker != null);
    try std.testing.expectEqual(anchor, self.app_content.first);
    try self.chrome.marker.on_click(self.chrome.marker.userdata, &fixture.ctx);
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.marker == null);
}

test "App Session notice goes after five seconds or at the next key" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.shown_notice.show("Copied 12 lines", ChromeFixture.now() - 4_000);
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("Copied 12 lines", self.chrome.status.bar.left);
    self.shown_notice.show("Copied 12 lines", ChromeFixture.now() - 6_000);
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("", self.chrome.status.bar.left);
    self.shown_notice.show("Copied 12 lines", ChromeFixture.now());
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("", self.chrome.status.bar.left);
}

test "App Session ? on an empty draft shows the shortcuts; the next key closes them; ?? types one" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    try fixture.press(.{ .codepoint = '?', .text = "?" });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.overlay.?.eql(self.chrome.shortcuts.widget()));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.overlay == null);
    try std.testing.expectEqualStrings("a", self.input.composition().bytes);
    // On a draft with text, ? is a character.
    try fixture.press(.{ .codepoint = '?', .text = "?" });
    try std.testing.expectEqualStrings("a?", self.input.composition().bytes);
    _ = self.input.clear();
    try fixture.press(.{ .codepoint = '?', .text = "?" });
    try fixture.press(.{ .codepoint = '?', .text = "?" });
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.overlay == null);
    try std.testing.expectEqualStrings("?", self.input.composition().bytes);
    // A terminal that reports ? as Shift-/ with the text ?: the same.
    _ = self.input.clear();
    const shifted: vaxis.Key = .{ .codepoint = '/', .text = "?", .mods = .{ .shift = true } };
    try fixture.press(shifted);
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.overlay.?.eql(self.chrome.shortcuts.widget()));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    try fixture.press(shifted);
    _ = try fixture.draw();
    try std.testing.expect(self.app_screen.overlay == null);
    try std.testing.expectEqualStrings("?", self.input.composition().bytes);
}

test "App Session opens the collapsed Message whose ┄ row was clicked, as Ctrl-O does" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    try fixture.screen.live.append("› first\n  \x1b[2;8m┄ 2 more lines\x1b[0m\n› second\n  \x1b[2;8m┄ 3 more lines\x1b[0m\nTail line\n");
    const content: protocol.ActivityItem.Content = .{ .length = 0, .digest = @splat(0) };
    for ([_]u64{ 40, 50 }) |position| self.live.blocks.append(.{ .source = .activity, .position = position, .ordinal = 0, .content = content, .row = false });
    _ = try fixture.draw();
    const text = fixture.screen.live.text();
    const handler = self.app_content.handler.?;
    // Any other row opens nothing.
    try handler.on_click.?(handler.userdata, &fixture.ctx, .{ .offset = std.mem.indexOf(u8, text, "Tail line").? });
    try std.testing.expect(self.expansion.queued == .none);
    const older = std.mem.lastIndexOfScalar(u8, text[0..std.mem.indexOf(u8, text, "┄ 2").?], '\n').? + 1;
    try handler.on_click.?(handler.userdata, &fixture.ctx, .{ .offset = older });
    try std.testing.expectEqual(@as(u64, 40), self.expansion.queued.ready.target.position);
}

test "App Session drag-copy notices follow the notice rule" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const handler = self.app_content.handler.?;
    try handler.on_notice(handler.userdata, &fixture.ctx, "Copied 3 lines");
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("Copied 3 lines", self.chrome.status.bar.left);
    try std.testing.expect(self.shown_notice.expire(ChromeFixture.now() + 5_000));
    _ = try fixture.draw();
    try std.testing.expectEqualStrings("", self.chrome.status.bar.left);
}
