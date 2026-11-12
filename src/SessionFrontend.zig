//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const AppScreen = @import("AppScreen.zig");
const InputArea = @import("InputArea.zig");
const DocumentView = @import("DocumentView.zig");
const FeedView = @import("FeedView.zig");
const Root = @import("Root.zig");
const ActionConsent = @import("ActionConsent.zig");
const PermissionCard = @import("PermissionCard.zig");
const Palette = @import("Palette.zig");
const SessionChrome = @import("SessionChrome.zig");
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
const feed_reads = @import("feed_reads.zig");
const feed_window = @import("feed_window.zig");
const FeedPolicy = feed_reads.Policy(feed_window.Key);
const session_notice = @import("session_notice.zig");
const session_id = @import("session_id.zig");
const session_drafts = @import("session_drafts.zig");
const session_keys = @import("session_keys.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const session_upgrade = @import("session_upgrade.zig");
const Self = @This();
const RetryFence = struct { ending: feed_window.Key, sent: u64 };
const empty_app_text: vxfw.Text = .{ .text = "" };

const reads = @import("session_reads.zig");
const session_line = @import("session_line.zig");
const command_input = @import("command_input.zig");
const slash_commands_shared = @import("slash_commands.zig");
const skill_completion = @import("skill_completion.zig");
const skill_suggestions = @import("skill_suggestions.zig");
const slash_commands = slash_commands_shared.conversation;
const model_capability = @import("model_capability.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const status_page = @import("status_page.zig");
const ChatInfo = @import("chat_info.zig");
const ModelChoice = @import("model_choice.zig");
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
/// and the chat info panel's `~` paths.
home: []const u8 = "",
store: []const u8,
session: []const u8,
directory: []const u8,
files: Files,
command: Command,
requests: Requests = undefined,
status: Status = undefined,
screen: *Screen = undefined,
// One keyed widget for the feed; panels keep their own documents.
app_content: FeedView = .{ .window = undefined, .anchor = undefined },
app_document: DocumentView = .{ .document = undefined },
app_body: AppScreen.Content = undefined,
app_input: InputArea = undefined,
app_screen: AppScreen.Session = undefined,
app_preview: DocumentView = undefined,
app_consent: ActionConsent = .{},
app_card: PermissionCard = undefined,
app_palette: Palette = .{ .shown = undefined },
app_info: ChatInfo = undefined,
info_open: bool = false,
/// One panel effect, retained through its definite answer, even when closed.
info_effect: enum { idle, configure, refreshing, copy, archive, saved, failed } = .idle,
info_edit: ?ChatInfo.Edit = null,
info_bytes: [@max(status_page.max_label_bytes, status_page.max_model_bytes)]u8 = undefined,
app_hooks: AppHooks = .{ .root = undefined, .context = undefined, .leave = undefined, .copy = undefined, .on_open = undefined },
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
/// One gesture's authority, retained from scheduling through joined completion.
/// The counter is the existing Message owner's fact, not another sent marker.
retry_fence: ?RetryFence = null,
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
    feed_read: feed_reads.Read = .opening,
    fills: FeedPolicy.Fills = .{},
    // An Action the reader found, adopted once input is idle.
    prepared_action: ?u64 = null,
    prepared_summary: View.ActionSummary = .{},
    // One joined read at a time; no reuse until its live diagnostic is delivered.
    pending_diagnostic: ?struct { failure: protocol_reply.ReadFailure, phase: ReadPhase, recoverable: bool } = null,
} = .{},
// The inspection page and the command that may fill it.
queued_inspection: ?Inspection = null,
inspection: struct {
    kind: Inspection = .requests,
    // Chat info requested an inspection capture on the next scan.
    status_requested: bool = false,
    // The shown and next captures alternate, so the worker never changes
    // facts the panel is reading on the UI thread.
    sessions: [2]status_page.Session = undefined,
    status: ?u1 = null,
    // An inspection or Host command started and its result has not been
    // presented. A command may change configuration, so Messages and consent wait
    // for every inspection; exit prints an unshown command's output, which can
    // carry recovery warnings.
    command_running: bool = false,
} = .{},
// Messages sent.
admission: struct {
    /// Messages begun before Admission settles: fences retries and expansion
    /// reads against newer input without waiting for live work to catch up.
    sent: u64 = 0,
} = .{},
// Live facts have their own scan cursor, independent of the resident window.
live: struct {
    view: View.Live = .{},
    latest_ending: ?reads.LatestEnding = null,
    work: protocol.SessionWork = .{},
    scan: FeedPolicy.Cycle = .{},
    queued: protocol.Queued = .{},
    queued_line: ?queued_line.Shown = null,
} = .{},
// New rows observed while the anchor is held, not replayed provisional rows.
new_below: usize = 0,
// One collapsed Message shown in full.
expansion: struct {
    // Ctrl-O waits for the frame it names a block in; the read then waits for
    // the reader, and its page shows only over the view it was asked from.
    // A newer Ctrl-O may queue while an older page is still being read.
    queued: union(enum) { none, after_frame, ready: OpenRequest } = .none,
    // The page being read. Each request holds where it was asked from;
    // Esc, Ctrl-G, a send or a newer Ctrl-O supersedes it.
    reading: ?OpenRequest = null,
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
/// its repair details what to do. It needs the person, so it is no notice.
failure: ?struct { key: [36]u8, state: Submission.State, bar: session_notice.Failure, page: ?[]const u8 = null } = null,
failure_buffer: [failure_capacity]u8 = undefined,
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
/// A short command result with a failure mark on each line.
const notice_capacity = @max(2048, slash_commands_shared.result_notice_bytes);

test "a read freezes its viewport width method for live and historical answers" {
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    var environment = try std.testing.environ.createMap(std.testing.allocator);
    defer environment.deinit();
    try screen.init(std.testing.io, &environment, false);
    defer screen.deinit();
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .screen = screen, .colour = false };
    self.init.io = std.testing.io;
    self.app_content = .{ .window = &screen.feed, .anchor = &screen.anchor };
    self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = "unused", .input = &self.input, .environment = .empty };
    for (std.enums.values(@import("ConversationViewport.zig").Method)) |method| {
        screen.setWidth(method);
        for ([_]ReadPhase{ .activity, .message }) |phase| {
            const job = self.freeze(phase);
            try std.testing.expectEqual(method, job.width_method);
        }
    }
}

/// Fills the reader's job in place; the caller may add to it before launch.
fn freeze(self: *Self, phase: ReadPhase) *Job {
    std.debug.assert(self.reader.thread == null);

    self.job = .{ .init = self.init, .home = self.home, .store = self.store, .session = self.session, .files = self.files, .colour = self.colour, .width_method = self.screen.vx.caps.unicode, .command = self.command, .configure = self.app_hooks.configure, .requests = self.requests, .status = self.status, .phase = phase, .cursor = self.scanCursor(), .opening = self.reading.opening, .queued_line = if (self.live.queued_line) |shown| shown.admission else 0, .inspection_kind = self.inspection.kind, .interrupted = self.interrupted, .line_read = self.line.read, .hint_wanted = self.hint == .unread, .opened = self.screen.feed.opened };

    const job = &self.job;
    job.latest_ending = self.live.latest_ending;
    if (phase == .activity or phase == .permission) {
        job.open_status = self.inspection.status_requested;
        job.watch_status = self.statusShown();
        const shown = self.inspection.status;
        const taken: u1 = if (shown) |index| ~index else 0;
        job.status_shown = if (shown) |index| &self.inspection.sessions[index] else null;
        job.status_taken = &self.inspection.sessions[taken];
        job.status_actions = self.files.actions[taken];
    }
    if (phase == .activity or phase == .permission) {
        self.reading.feed_read = if (self.reading.opening and phase == .activity) .opening else .scan;
        job.feed_page = FeedPolicy.request(self.reading.feed_read, self.feedState());
    }
    return job;
}

test "reader freezes borrowed HOME independently of process initialization" {
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    var environment = try std.testing.environ.createMap(std.testing.allocator);
    defer environment.deinit();
    try screen.init(std.testing.io, &environment, false);
    defer screen.deinit();
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    for ([_][]const u8{ "", "/home/a b" }) |home| {
        for (std.enums.values(ReadPhase)) |phase| {
            self.* = .{ .init = undefined, .home = home, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .screen = screen, .colour = false };
            self.init.io = std.testing.io;
            self.app_content = .{ .window = &screen.feed, .anchor = &screen.anchor };
            self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = "unused", .input = &self.input, .environment = .empty };
            const job = self.freeze(phase);
            self.home = "/changed-after-freeze";
            try std.testing.expectEqualStrings(home, job.home);
            try std.testing.expectEqual(home.ptr, job.home.ptr);
        }
    }
}

pub const SkillRead = *const fn (client.ReadContext, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!skill_suggestions.Page;

fn clientSkills(read: client.ReadContext, gpa: std.mem.Allocator, store: []const u8, session: []const u8, prefix: []const u8) !skill_suggestions.Page {
    return read.requests().skillSuggestions(gpa, store, .{ .session = session }, prefix);
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
        job.page = try job.run(task.readContext(), job.gpa, job.store, job.session, job.prefix.slice());
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
            if (err != error.Cancelled and self.skill_task.result.failure_origin == .host_transport and self.hostFailure()) {
                self.skills.retry(job.read);
            } else self.skills.fail(job.read);
            if (err == error.CanonicalStoreFailure) return err;
        }
        self.dirty = true;
    }
    if (self.upgradeHeld() or self.hostHeld()) return;
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
    /// Returns whether this event admitted a new archive request; other inputs
    /// return refused, without changing their own effect semantics.
    step: *const fn (context: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) anyerror!overview_view.ArchiveAdmission,
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
    archive_state: ?*const fn (*anyopaque) ChatInfo.SaveState = null,
    models: ?*const fn (*anyopaque) ModelChoice.Snapshot = null,

    pub const Said = struct {
        /// The overview's notice; null for none.
        text: ?[]const u8 = null,
        /// Ctrl-X would stop the work.
        stoppable: bool = false,
    };
};

/// How the frontend stopped. Either way it stopped only its own client waits;
/// Host work it started continues. Navigation returns to the overview that
/// lent the terminal, which stays begun; new_session then creates an empty chat.
pub const Outcome = enum { detached, interrupted, returned, new_session };

pub fn begin(self: *Self, init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, requests: Requests, status: Status, screen: *Screen, interrupted: *client.Cancellation, lender: Lender) void {
    self.* = .{ .init = init, .home = init.environ_map.get("HOME") orelse "", .store = store, .session = session, .directory = directory, .files = files, .command = command, .requests = requests, .status = status, .screen = screen, .interrupted = interrupted, .lender = lender, .colour = screen.colour };
    self.startInput();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input, .environment = .{ .map = init.environ_map } };
    self.app_content = .{ .window = &screen.feed, .anchor = &screen.anchor, .colour = self.colour, .handler = .{ .userdata = self, .on_open = appOpen, .on_notice = appNotice, .on_scroll = appDragScroll, .on_click = appClick, .on_retry = appRetry } };
    self.app_input = .{ .composer = .{ .editor = &self.input.editors[self.input.active] } };
    self.app_document = .{ .document = &screen.browsing, .colour = self.colour, .handler = .{ .userdata = self, .on_open = appOpen, .on_notice = appNotice, .on_scroll = appDragScroll } };
    self.app_body = .{ .shown = self.app_content.widget() };
    self.app_screen = .{ .content = &self.app_body, .input = &self.app_input, .content_gutter = true, .userdata = self, .on_event = appEvent };
}

/// The shell owns Host availability; the Session only reads it and forwards
/// a transport loss or the person's explicit start gesture.
pub const HostAccess = struct {
    context: *anyopaque,
    /// Unreachable, not the reachable Host's new-Turn admission hold.
    held: *const fn (*anyopaque) bool,
    lost: *const fn (*anyopaque) void,
    start: *const fn (*anyopaque, *vxfw.EventContext) anyerror!bool,
    notice: *const fn (*anyopaque) ?vxfw.Widget,
};

pub const AppHooks = struct {
    host: ?HostAccess = null,
    configure: ?reads.Configure = null,
    drafts: ?*session_drafts.Drafts = null,
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
    self.app_info = .{ .backend = self.infoBackend(), .home = self.home };
    if (hooks.drafts) |drafts| if (drafts.take(self.init.gpa, self.session)) |draft| {
        defer draft.deinit(self.init.gpa);
        self.input.restore(draft.snapshot);
    };
    self.app_caps = caps;
    self.screen.setWidth(caps.width);
    self.app_preview = .{ .document = &self.screen.browsing, .colour = self.colour, .more = true, .handler = .{ .userdata = self, .on_notice = appNotice, .on_scroll = appDragScroll, .on_click = appPreviewClick } };
    self.app_card = .{ .consent = &self.app_consent, .pasting = &hooks.root.pasting, .description = "", .body = self.app_preview.widget(), .userdata = self, .on_decision = appDecision };
    self.chrome = .init(.{ .userdata = self, .key = chromeClick(.needs), .stop = chromeClick(.{ .action = .stop }), .back = chromeClick(.{ .action = .close }), .latest = chromeClick(.{ .action = .latest }), .status_page = chromeClick(.status), .details = chromeClick(.details), .unarchive = chromeClick(.unarchive) });
    return self.widget();
}

/// The chat's own line is the only entry to its settings panel.
fn openInfo(self: *Self, _: *vxfw.EventContext) !void {
    if (self.info_open) return;
    self.info_open = true;
    if (self.inspection.status != null) self.app_info.refresh();
    self.inspection.status_requested = true;
    self.poll_at = 0;
    self.dirty = true;
}

fn infoBackend(self: *Self) ChatInfo.Backend {
    const Backend = struct {
        fn owner(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }
        fn read(raw: *anyopaque, session: *status_page.Session) !void {
            const frontend = owner(raw);
            const index = frontend.inspection.status orelse return error.Unread;
            session.* = frontend.inspection.sessions[index];
        }
        fn configure(raw: *anyopaque, edit: ChatInfo.Edit) !void {
            const frontend = owner(raw);
            try frontend.infoMaySave();
            var held = edit;
            switch (edit) {
                .label, .model => |text| {
                    if (text.len > frontend.info_bytes.len) return error.ValueTooLong;
                    @memcpy(frontend.info_bytes[0..text.len], text);
                    if (edit == .label) held = .{ .label = frontend.info_bytes[0..text.len] } else held = .{ .model = frontend.info_bytes[0..text.len] };
                },
                else => {},
            }
            frontend.info_edit = held;
            frontend.info_effect = .configure;
            frontend.dirty = true;
        }
        fn archive(raw: *anyopaque) !overview_view.ArchiveAdmission {
            const frontend = owner(raw);
            frontend.infoMaySave() catch return .refused;
            const admission = try frontend.archive();
            if (admission == .admitted) frontend.info_effect = .archive;
            return admission;
        }
        fn copy(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const frontend = owner(raw);
            try frontend.infoMaySave();
            _ = frontend.queueInspection(.copy, "");
            frontend.info_effect = .copy;
        }
        fn state(raw: *anyopaque) ChatInfo.SaveState {
            const frontend = owner(raw);
            return switch (frontend.info_effect) {
                .idle => .idle,
                .configure, .refreshing, .copy => .pending,
                .saved => .saved,
                .failed => .failed,
                .archive => if (frontend.lender.archive_state) |read_state| switch (read_state(frontend.lender.context)) {
                    .idle, .pending => .pending,
                    .saved => .saved,
                    .failed => .failed,
                } else .pending,
            };
        }
        fn models(raw: *anyopaque) ModelChoice.Snapshot {
            const frontend = owner(raw);
            return if (frontend.lender.models) |read_models| read_models(frontend.lender.context) else .{};
        }
        fn caps(raw: *anyopaque) overview_view.Caps {
            return owner(raw).app_caps;
        }
    };
    return .{ .context = self, .read = Backend.read, .configure = Backend.configure, .archive = Backend.archive, .copy_last_answer = Backend.copy, .state = Backend.state, .models = Backend.models, .caps = Backend.caps };
}

/// The archive owner delivers its answer to the panel's one outstanding effect.
/// Its own ledger retains any uncertainty and departure guidance.
pub fn archiveAnswered(self: *Self, result: overview_view.ArchiveResult) void {
    if (self.info_effect != .archive or !std.mem.eql(u8, self.session, &result.request.reference)) return;
    self.info_effect = switch (result.outcome) {
        .requested => .saved,
        .failed, .unconfirmed => .failed,
    };
    self.dirty = true;
}

fn infoMaySave(self: *const Self) !void {
    if (self.hostHeld() or self.upgradeHeld() or self.reading.opening or self.commandActive() or self.submission.intent != null) return error.Busy;
}

/// A refused original keeps its repair information, independent of settings.
fn showSubmissionFailure(self: *Self) !void {
    // This file is never borrowed by the reader. A repair view cannot overwrite
    // staged feed rows, Message content or unshown Configure recovery output.
    self.dropMessageRequest();
    const file = self.files.details;
    try file.setLength(self.init.io, 0);
    try self.init.io.vtable.fileSeekTo(self.init.io.userdata, file, 0);
    var buffer: [4096]u8 = undefined;
    var output = file.writerStreaming(self.init.io, &buffer);
    try reads.writeSubmission(self.submission.view(), if (self.heldFailure()) |failure| failure.page else null, &output.interface);
    try output.flush();
    try self.screen.showFile(self.init.io, file, .details);
    self.dirty = true;
}

/// What a click on the chrome runs: what its key runs.
const Click = union(enum) {
    action: ConversationAction,
    /// The chat's info panel.
    status,
    details,
    unarchive,
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
                .status => try self.openInfo(ctx),
                .details => try self.showSubmissionFailure(),
                .unarchive => try self.converse(.unarchive),
                .needs => if (self.heldOriginal()) |held| if (session_notice.key(held)) |key| switch (key) {
                    .retry => try self.perform(.recover),
                    .discard => try self.clickCommand("/discard"),
                    .status => try self.showSubmissionFailure(),
                },
            }
            self.dirty = true;
            try self.afterInput(ctx);
        }
    }.run;
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

/// A captured empty chat has no Message-derived identity yet. Its footer
/// shows its saved model, effort and Folder; the title/info owners stay intact.
fn footerFacts(self: *const Self) ?session_line.Facts {
    var facts = self.line.facts(&self.hint, self.session) orelse return null;
    if (self.line.first_position == null and self.line.folder.len != 0 and self.line.label == null) {
        facts.name = "";
        facts.folder = self.line.folder.slice();
    }
    return facts;
}

/// The Session's name as the terminal title leads with it.
pub fn titleName(self: *const Self) []const u8 {
    return if (self.line.facts(&self.hint, self.session)) |facts| facts.name else self.session;
}

fn nowMs(self: *const Self) u64 {
    return @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .captureHandler = appCapture, .eventHandler = appEvent, .drawFn = appDraw };
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
    try self.openPeer(ctx, id);
}

/// A list row and an inline link share the same guarded, settled departure.
pub fn openPeer(self: *Self, ctx: *vxfw.EventContext, id: []const u8) !void {
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
    switch (session_notice.follow(original, self.submission.published(), self.draftSafeToLeave(), action, self.commandActive())) {
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
fn appClick(raw: *anyopaque, ctx: *vxfw.EventContext, at: feed_window.Point) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.leaving != null or self.pagePlace() == .elsewhere) return;
    const tool = self.app_content.toolAt(at);
    const message = self.app_content.messageAt(at);
    if (tool == null and message == null) return;
    self.shown_notice.dismiss();
    if (self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
    } else {
        self.dropMessageRequest();
        if (tool) |key| self.toggleTool(key) else self.openCollapsed(message.?);
    }
    try self.afterInput(ctx);
}

/// The synthetic feed link has exactly the key's admission and read path.
fn appRetry(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.leaving != null or self.retryable() == null) return;
    self.shown_notice.dismiss();
    try self.recover(null);
    self.dirty = true;
    try self.afterInput(ctx);
}

/// The request's continuation uses the same open action as Ctrl-O. The
/// complete request is already staged; reveal its omitted rows in this panel,
/// without another page, read, or independently owned expansion state.
fn appPreviewClick(raw: *anyopaque, ctx: *vxfw.EventContext, at: viewport.Position) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const next = self.app_preview.continuation() orelse return;
    if (!std.meta.eql(at, next) or self.leaving != null) return;
    self.dropMessageRequest();
    _ = try self.expand();
    try self.afterInput(ctx);
}

fn appDragScroll(raw: *anyopaque, _: *vxfw.EventContext, up: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.scroll(!up, 1);
}

fn appDecision(raw: *anyopaque, ctx: *vxfw.EventContext, decision: ConsentPolicy.Decision) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.hostHeld()) return;
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

pub fn hostStartKey(key: vaxis.Key) bool {
    return key.matchExact('r', .{});
}

fn hostHeld(self: *const Self) bool {
    const host = self.app_hooks.host orelse return false;
    return host.held(host.context);
}

fn hostFailure(self: *Self) bool {
    const host = self.app_hooks.host orelse return false;
    host.lost(host.context);
    self.dirty = true;
    return true;
}

/// A modal panel takes keys before a permission card or feed child can act.
fn appCapture(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const opens = event == .key_press and !self.app_hooks.root.pasting and (event.key_press.matches('i', .{ .alt = true }) or (self.submission.view() != null and event.key_press.matches('d', .{ .alt = true })));
    const input = switch (event) {
        .key_press, .paste_start, .paste_end, .invalid_key => true,
        else => false,
    };
    if (opens or (self.info_open and input)) {
        try appEvent(raw, ctx, event);
        ctx.consumeEvent();
    }
}

/// A palette click chooses the drawn row, then uses the input's Enter path:
/// command choices run, incomplete words and skills replace the draft.
fn appSelectCommand(raw: *anyopaque, ctx: *vxfw.EventContext, pressed: slash_commands_shared.Shown.Pick) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.app_consent.request != null or self.app_hooks.root.pasting) return;
    // A pointer names the row in the list the last frame drew, not the
    // list a key has stored since for a newly edited draft.
    const stored = &self.screen.commands;
    _ = slash_commands_shared.Shown.pickedNow(stored, self.nextCommands(stored.*), pressed) orelse return;
    try appEvent(raw, ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
}

fn appEvent(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.leaving != null) return;
    switch (event) {
        .init, .focus_in => try ctx.requestFocus(if (self.app_input.permission != null and self.app_consent.row == .selector) self.app_card.widget() else self.app_input.composer.widget()),
        .tick => {
            _ = try self.update();
            // An Upgrade's hold shows no choice: nothing decided could be
            // sent. The read after the hold finds the Action again.
            const held = self.upgradeHeld() or self.hostHeld();
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
                try self.screen.showFile(self.init.io, self.files.action, .action);
                self.action_summary = self.reading.prepared_summary;
                self.reading.prepared_action = null;
                self.reading.phase = .activity;
                self.app_consent.adopt(request);
                self.app_input.permission = &self.app_card;
                try ctx.requestFocus(self.app_card.widget());
                self.dirty = true;
            };
            try self.app_card.widget().handleEvent(ctx, .tick);
            try self.app_info.widget().handleEvent(ctx, .tick);
            if (self.expansion.queued == .after_frame) if (try self.expand()) |peer| try self.follow(ctx, &peer);
            if (self.shown_notice.expire(self.nowMs())) self.dirty = true;
            ctx.redraw = ctx.redraw or self.dirty;
        },
        .key_press, .paste_start, .paste_end, .invalid_key => {
            const pasting = self.app_hooks.root.pasting;
            self.shown_notice.dismiss();
            if (self.info_open) {
                if (event == .key_press and !pasting and self.submission.view() != null and event.key_press.matches('d', .{ .alt = true })) {
                    self.app_info.cancelChoice();
                    self.info_open = false;
                    try ctx.requestFocus(self.app_input.composer.widget());
                    try self.showSubmissionFailure();
                } else if (session_keys.panelAction(Editor.selectEvent(conversation_keys, event, pasting))) |action| {
                    try self.perform(action);
                } else if (event == .key_press and !pasting and (Editor.named(event.key_press) == .escape or Editor.named(event.key_press) == .ctrl_g)) {
                    if (self.app_info.hasChoice()) self.app_info.cancelChoice() else {
                        self.info_open = false;
                        try ctx.requestFocus(self.app_input.composer.widget());
                    }
                } else try self.app_info.widget().handleEvent(ctx, event);
                ctx.consumeAndRedraw();
                try self.afterInput(ctx);
                return;
            }
            // The empty-composer restart shortcut has no authority over a
            // panel's input, including its Rename and Model editors.
            if (event == .key_press and !pasting and self.input.composition().bytes.len == 0 and hostStartKey(event.key_press)) if (self.app_hooks.host) |host| {
                if (try host.start(host.context, ctx)) {
                    ctx.consumeEvent();
                    return;
                }
            };
            if (event == .key_press and !pasting and event.key_press.matches('i', .{ .alt = true })) {
                try self.openInfo(ctx);
                ctx.consumeAndRedraw();
                try self.afterInput(ctx);
                return;
            }
            if (event == .key_press and !pasting and self.submission.view() != null and event.key_press.matches('d', .{ .alt = true })) {
                try self.showSubmissionFailure();
                ctx.consumeAndRedraw();
                try self.afterInput(ctx);
                return;
            }
            if (self.app_consent.request != null) {
                // Choice classification has no authority over draft editing.
                // Only Esc and Enter bypass the normal editor on that row.
                const selected = if (self.app_consent.row == .selector) Editor.selectEvent(conversation_keys, event, pasting) else .none;
                const row_key: ActionConsent.RowKey = if (self.app_consent.row == .draft)
                    if (event == .key_press and !pasting) key: {
                        if (Editor.isEnter(event.key_press)) break :key .enter;
                        if (Editor.named(event.key_press)) |named| if (named == .escape or named == .ctrl_g) break :key .escape;
                        break :key .other;
                    } else .other
                else switch (selected) {
                    .text => if (event == .paste_start or pasting) .paste else if (event == .invalid_key) .other else .printable,
                    .enter => .enter,
                    .left, .right => .arrows,
                    .action => |action| if (action == .close) .escape else .screen,
                    else => .other,
                };
                const previous = self.app_consent.row;
                switch (self.app_consent.route(row_key)) {
                    .screen => if (selected == .action) {
                        try self.perform(selected.action);
                    },
                    .selector => try self.app_card.widget().handleEvent(ctx, event),
                    .blocked => if (row_key == .enter) {
                        self.notice = "Not sent: this Action needs a decision";
                    },
                    .draft => switch (self.input.appEvent(conversation_keys, event, pasting, false)) {
                        .busy => self.notice = "Not sent: this Action needs a decision",
                        .editor => |outcome| switch (outcome) {
                            .action => |action| try self.perform(action),
                            .refused => |why| if (why != .unbound) {
                                self.notice = refusedNotice(why);
                            },
                            .none, .append, .redraw, .submit => {},
                        },
                        .message, .command => unreachable, // Sending is disabled while consent waits.
                    },
                }
                if (self.app_consent.request != null and previous != self.app_consent.row) {
                    try ctx.requestFocus(if (self.app_consent.row == .selector) self.app_card.widget() else self.app_input.composer.widget());
                }
            } else {
                self.notice = null;
                // One submission at a time: a decision or Message in flight,
                // or an original still held, makes Enter say so and keep the draft.
                const allowed = self.admitsMessage();
                if (!(event == .key_press and !pasting and Editor.isEnter(event.key_press) and self.takeShownRow())) {
                    switch (self.input.appEvent(conversation_keys, event, pasting, allowed)) {
                        .message => |ticket| try self.beginMessage(.{ .message = ticket }),
                        .command => try self.commandLine(),
                        .busy => self.sayBusy(null, false),
                        .editor => |outcome| switch (outcome) {
                            .action => |action| try self.perform(action),
                            .refused => |why| if (why != .unbound) {
                                self.notice = refusedNotice(why);
                            },
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
    self.observeFeed();
    if (self.notice) |text| {
        self.shown_notice.show(text, self.nowMs());
        self.notice = null;
        self.dirty = true;
    }
    ctx.redraw = ctx.redraw or self.dirty;
    if (self.leaving == null) try self.serviceSkills();
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
        if (self.app_hooks.drafts) |drafts| {
            try drafts.put(self.init.gpa, self.session, self.input.snapshot());
        }
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
    const attention = style.of(self.app_caps, .{ .colour = .attention });
    const failure = style.of(self.app_caps, .{ .colour = .failure });
    const hover = style.of(self.app_caps, .{ .background = .hover });
    const colours: viewport.Colours = .{
        .quiet = quiet.fg,
        .user = style.of(self.app_caps, .{ .colour = .ink }).fg,
        .attention = attention.fg,
        .failure = failure.fg,
        .band = style.of(self.app_caps, .{ .background = .bar }).bg,
        .selection = style.of(self.app_caps, .{ .background = .selection }).bg,
    };
    const facts_style = style.of(self.app_caps, .{ .colour = .quiet, .background = .bar });
    self.app_screen.style = normal;
    self.app_input.composer.caret = !self.info_open;
    self.app_input.composer.style = normal;
    self.app_input.composer.quiet = quiet;
    self.app_input.composer.method = self.app_caps.width;
    self.app_input.composer.editor = &self.input.editors[self.input.active];
    self.app_card.style = normal;
    self.app_card.quiet = quiet;
    self.app_card.hover_style = hover;
    self.app_card.description = self.action_summary.description.slice();
    self.app_card.method = self.app_caps.width;
    self.app_preview.style = normal;
    self.app_preview.colours = colours;
    self.app_preview.hover_style = hover;
    self.app_preview.method = self.app_caps.width;
    self.app_content.style = normal;
    self.app_content.hover_style = hover;
    self.app_content.colours = colours;
    self.app_content.method = self.app_caps.width;
    self.app_document.style = normal;
    self.app_document.colours = colours;
    self.app_document.hover_style = hover;
    self.app_document.method = self.app_caps.width;
    self.app_document.document = if (screen.view == .message) &screen.staging else &screen.browsing;
    self.app_body.shown = if (screen.view == .feed) self.app_content.widget() else self.app_document.widget();
    screen.commands = self.nextCommands(screen.commands);
    var palette: ?vxfw.Widget = null;
    if (self.app_consent.request == null) if (screen.commands) |*shown| {
        self.app_palette.shown = shown;
        self.app_palette.method = self.app_caps.width;
        self.app_palette.style = normal;
        self.app_palette.quiet = quiet;
        self.app_palette.hover_style = hover;
        self.app_palette.userdata = self;
        self.app_palette.on_select = appSelectCommand;
        palette = self.app_palette.widget();
    };
    const now_ms = self.nowMs();
    const work = self.live.work.state.asOf(now_ms);
    const said = self.lender.line(self.lender.context, work);
    const browsing = screen.view != .feed or !screen.anchor.following();
    if (screen.anchor.following()) self.new_below = 0;
    const chrome = &self.chrome;
    chrome.activity.live = self.live.view;
    chrome.activity.work = if (self.app_consent.request != null) null else work_line.of(try ctx.arena.create([work_line.max_words_bytes]u8), &self.live.work.state, self.live.work.operation, now_ms);
    const queued = self.queuedRow();
    chrome.activity.queued = if (queued) |row| row.waiting else null;
    chrome.activity.method = self.app_caps.width;
    chrome.activity.styles = .{ .ink = style.of(self.app_caps, .{ .colour = .ink }), .normal = normal, .quiet = quiet, .attention = attention, .failure = failure };
    self.app_content.tail = chrome.activity.widget();
    self.app_content.latest_ending = self.live.latest_ending;
    self.app_content.retry_actionable = self.retryable() != null;
    chrome.status.method = self.app_caps.width;
    chrome.status.quiet = quiet;
    chrome.status.attention = attention;
    chrome.facts.method = self.app_caps.width;
    chrome.facts.style = facts_style;
    chrome.marker.method = self.app_caps.width;
    chrome.marker.style = .{ .reverse = true };
    const held = self.heldOriginal();
    const send = session_chrome.send(session_notice.status(self.reading.opening, self.app_consent.request != null, held), self.reading.opening or (held != null and held.?.state == .submitting));
    const list_visible = self.app_hooks.root.listVisible();
    chrome.place(&self.app_screen, .{
        .list_visible = list_visible,
        .browsing = browsing,
        .new_entries = self.new_below,
        .needs = send.needs,
        .needs_key = if (send.needs) |needs| session_chrome.needsKey(needs) else "",
        // A conversation reading itself again says so until Host requests go on.
        .progress = if (self.upgradePhase() == .reobserving) session_upgrade.rereading else send.progress,
        .stoppable = said.stoppable,
        .details = held != null and held.?.state != .submitting,
        .facts = .{ .current = self.footerFacts(), .name = self.session, .archive = self.line.archive_state },
        .notice = self.shown_notice.current(now_ms),
        .overview = said.text,

        .overlay = if (self.info_open) self.app_info.bodyWidget() else palette,

        .width = ctx.max.width.?,
    });
    self.app_screen.overlay_reserves_space = self.info_open;
    self.app_info.narrow = !list_visible;
    if (self.info_open) {
        // The panel supplies the one screen footer in the ordinary footer slot.
        // It is not an extra row inside the Layer above the input.
        self.app_input.facts = self.app_info.footerWidget();
        self.app_input.status = null;
    }
    self.app_preview.size = .{};
    self.app_content.size = .{};
    self.app_screen.host = if (self.app_hooks.host) |host| host.notice(host.context) else null;
    var surface = try self.app_screen.widget().draw(ctx);
    const size = if (self.app_consent.request != null) self.app_preview.size else if (screen.view == .feed) self.app_content.size else self.app_document.size;
    screen.height = size.height;
    screen.vx.screen.width = size.width;
    self.observeFeed();
    if (screen.view != .feed) screen.drawn = .{ .first = if (self.app_consent.request != null) self.app_preview.first else self.app_document.first, .rows = screen.height };
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
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .details = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
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
    var root: Root = .{ .overview = empty_app_text.widget(), .list = empty_app_text.widget(), .compose = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.screen.feed.at_end = true;
    self.screen.feed.at_start = true;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    try seedFeed(screen, "\x1b[2mtheme witness\x1b[0m");
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
        const user = rendered.readCell(1, @intCast(self.app_content.drawn.pad)).?;
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

test "App Session approval keeps typed abc through Esc and Allow once with its caret" {
    for ([_]bool{ false, true }) |existing_draft| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        if (existing_draft) {
            _ = self.input.append("leftTAIL");
            self.input.editors[self.input.active].cursor = 4;
        }
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try std.testing.expectEqual(ConsentPolicy.Row.selector, self.app_consent.row);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "Allow once") != null);
        try held.keys("abc");
        try std.testing.expectEqual(ConsentPolicy.Row.draft, self.app_consent.row);
        const expected = if (existing_draft) "leftabcTAIL" else "abc";
        const caret: usize = if (existing_draft) 7 else 3;
        try std.testing.expectEqualStrings(expected, self.input.composition().bytes);
        try std.testing.expectEqual(caret, self.input.composition().cursor);
        const drafting = try held.shown();
        try std.testing.expect(std.mem.indexOf(u8, drafting, expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, drafting, "row 000") != null);
        try std.testing.expect(std.mem.indexOf(u8, drafting, "Allow once") == null);
        try held.keys("\r"); // Draft Enter sends and decides nothing.
        try std.testing.expect(self.submission.intent == null);
        try std.testing.expectEqual(@as(?u64, 0xa), self.app_consent.request);
        try std.testing.expectEqualStrings("Not sent: this Action needs a decision", self.shown_notice.current(self.nowMs()).?);
        try held.keys("\x1b");
        try std.testing.expectEqual(ConsentPolicy.Row.selector, self.app_consent.row);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "Allow once") != null);
        try held.keys("\r");
        try std.testing.expect(self.app_input.permission == null);
        try std.testing.expect(self.app_consent.request == null);
        try std.testing.expectEqual(Submission.Intent{ .decision = .{ .action = 0xa, .decision = .allow_once } }, self.submission.intent.?);
        try std.testing.expectEqualStrings(expected, self.input.composition().bytes);
        try std.testing.expectEqual(caret, self.input.composition().cursor);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), expected) != null);
    }
}

test "App Session approval pastes into the kept draft and draft arrows never move the choice" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    _ = self.input.append("leftTAIL");
    self.input.editors[self.input.active].cursor = 4;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.keys("\x1b[200~abc\r\nxyz\x1b[201~");
    try std.testing.expectEqual(ConsentPolicy.Row.draft, self.app_consent.row);
    try std.testing.expectEqualStrings("leftabc\nxyzTAIL", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 11), self.input.composition().cursor);
    try held.keys("\x1b[D");
    try std.testing.expectEqual(@as(usize, 10), self.input.composition().cursor);
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, self.app_consent.highlight);
    try std.testing.expect(self.submission.intent == null);
    try held.keys("\x03");
    try std.testing.expectEqual(@as(?Outcome, .detached), held.left);
    try std.testing.expectEqualStrings("leftabc\nxyzTAIL", self.input.composition().bytes);
}

test "App Session approval routing gives the draft editor first refusal for single and multiline keys" {
    const Key = enum { up, down, home, end, left, right, delete_next };
    const Case = struct { key: Key, bytes: []const u8, press: vaxis.Key };
    const cases = [_]Case{
        .{ .key = .up, .bytes = "\x1b[A", .press = .{ .codepoint = vaxis.Key.up } },
        .{ .key = .down, .bytes = "\x1b[B", .press = .{ .codepoint = vaxis.Key.down } },
        .{ .key = .home, .bytes = "\x1b[H", .press = .{ .codepoint = vaxis.Key.home } },
        .{ .key = .end, .bytes = "\x1b[F", .press = .{ .codepoint = vaxis.Key.end } },
        .{ .key = .left, .bytes = "\x1b[D", .press = .{ .codepoint = vaxis.Key.left } },
        .{ .key = .right, .bytes = "\x1b[C", .press = .{ .codepoint = vaxis.Key.right } },
        .{ .key = .delete_next, .bytes = "\x04", .press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } },
    };
    const Draft = struct { text: []const u8, cursor: usize, carets: [cases.len]usize, deleted: []const u8, multiline: bool };
    for ([_]Draft{
        .{ .text = "alpha\nbravo\ncharlie", .cursor = 8, .carets = .{ 2, 14, 6, 11, 7, 9, 8 }, .deleted = "alpha\nbrvo\ncharlie", .multiline = true },
        .{ .text = "alphabet", .cursor = 3, .carets = .{ 3, 3, 0, 8, 2, 4, 3 }, .deleted = "alpabet", .multiline = false },
    }) |draft| for ([_]ConsentPolicy.Row{ .selector, .draft }) |row| for (cases, 0..) |case, index| {
        errdefer std.debug.print("row={s}, key={s}, multiline={}\n", .{ @tagName(row), @tagName(case.key), draft.multiline });
        const normal = try std.testing.allocator.create(Input);
        defer std.testing.allocator.destroy(normal);
        normal.init();
        _ = normal.appEvent(conversation_keys, .paste_start, true, true);
        _ = normal.appEvent(conversation_keys, .{ .key_press = .{ .codepoint = 0, .text = draft.text } }, true, true);
        _ = normal.appEvent(conversation_keys, .paste_end, false, true);
        try std.testing.expectEqualStrings(draft.text, normal.composition().bytes);
        normal.editors[normal.active].cursor = draft.cursor;
        const outcome = normal.appEvent(conversation_keys, .{ .key_press = case.press }, false, true);
        const vertical = case.key == .up or case.key == .down;
        const falls_through = vertical and !draft.multiline;
        if (falls_through) {
            try std.testing.expectEqual(Input.Event(ConversationAction){ .editor = .{ .action = if (case.key == .up) .previous else .next } }, outcome);
        } else {
            try std.testing.expectEqual(Input.Event(ConversationAction){ .editor = .redraw }, outcome);
        }
        try std.testing.expectEqual(draft.carets[index], normal.composition().cursor);
        const expected_text = if (case.key == .delete_next) draft.deleted else draft.text;
        try std.testing.expectEqualStrings(expected_text, normal.composition().bytes);

        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try held.keys("\x1b[200~");
        try held.keys(draft.text);
        try held.keys("\x1b[201~");
        try std.testing.expectEqualStrings(draft.text, self.input.composition().bytes);
        self.input.editors[self.input.active].cursor = draft.cursor;
        const file = try held.adopt(100);
        defer file.close(std.testing.io);
        if (row == .draft) try held.keys("x\x7f"); // Enter the draft row without changing its contents.
        try held.keys("\x1b[6~"); // Leave room to scroll in either direction.
        _ = try held.draw();
        const before = self.app_preview.first;
        try held.keys(case.bytes);
        if (row == .draft) {
            try std.testing.expectEqualStrings(normal.composition().bytes, self.input.composition().bytes);
            try std.testing.expectEqual(normal.composition().cursor, self.input.composition().cursor);
            try std.testing.expectEqual(ConsentPolicy.Row.draft, self.app_consent.row);
            try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, self.app_consent.highlight);
            try std.testing.expect(self.leaving == null);
        } else {
            try std.testing.expectEqualStrings(draft.text, self.input.composition().bytes);
            try std.testing.expectEqual(draft.cursor, self.input.composition().cursor);
            if (case.key == .delete_next) {
                try std.testing.expectEqual(@as(?Outcome, .detached), held.left);
                continue;
            }
            const highlight: ConsentPolicy.Choice = if (case.key == .right) .deny else .allow_once;
            try std.testing.expectEqual(highlight, self.app_consent.highlight);
        }
        _ = try held.draw();
        // Selector End is the screen's latest action, so it reopens the
        // pending Action at its top; draft End still only edits that line.
        const latest = row == .selector and case.key == .end;
        const scroll_order: std.math.Order = if (latest) .lt else if (vertical and (row == .selector or falls_through)) if (case.key == .up) .lt else .gt else .eq;
        try std.testing.expectEqual(scroll_order, self.app_preview.first.order(before));
        if (latest) try std.testing.expectEqualDeep(@as(viewport.Position, .{}), self.app_preview.first);
        try std.testing.expect(self.submission.intent == null);
        try std.testing.expectEqual(@as(?u64, 0xa), self.app_consent.request);
    };
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
        self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .details = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
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
        var root: Root = .{ .overview = empty_app_text.widget(), .list = empty_app_text.widget(), .compose = empty_app_text.widget() };
        const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
        self.reading.opening = false;
        self.screen.feed.at_end = true;
        self.screen.feed.at_start = true;
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
    self.begin(init, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .details = page, .actions = .{ page, page } }, undefined, undefined, undefined, screen, &interrupted, quiet_overview);
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
    var root: Root = .{ .overview = empty_app_text.widget(), .list = empty_app_text.widget(), .compose = empty_app_text.widget() };
    const widget_ = self.attach(.{ .root = &root, .context = self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
    self.reading.opening = false;
    self.screen.feed.at_end = true;
    self.screen.feed.at_start = true;
    self.poll_at = std.math.maxInt(i96);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    try seedFeed(screen, "\x1b[2;8m← Received message from " ++ TerminalText.link_open ++ TerminalText.session_link ++ "m3n4p5" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m\x1b[0m\n");
    _ = try widget_.draw(draw_context);
    const content = self.app_content.widget();
    const click = struct {
        fn on(context: *vxfw.EventContext, target: vxfw.Widget, row: i16, col: i16) !void {
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try target.handleEvent(context, .{ .mouse = .{ .col = col, .row = row, .button = .left, .mods = .{}, .type = kind } });
        }
    }.on;
    // "Plan" is at columns 24 to 27. With a draft, the click is refused as
    // Esc is, and the Session and its draft stay as they were.
    _ = self.input.append("keep me");
    try click(&ctx, content, @intCast(self.app_content.drawn.pad), 25);
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", self.notice.?);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    try std.testing.expectEqual(@as(?Outcome, null), self.leaving);
    try std.testing.expectEqualStrings("keep me", self.input.composition().bytes);
    // Beside the name nothing opens.
    self.input.init();
    self.notice = null;
    try click(&ctx, content, @intCast(self.app_content.drawn.pad), 10);
    try std.testing.expectEqual(@as(?[session_id.bytes]u8, null), Hooks.opened);
    // On the name, with nothing to lose, the Session leaves for the peer.
    try click(&ctx, content, @intCast(self.app_content.drawn.pad), 25);
    try std.testing.expectEqualStrings("m3n4p5", &Hooks.opened.?);
    try std.testing.expectEqual(Outcome.returned, Hooks.left.?);
}

/// The legacy leave policy protects text that would otherwise be lost.
/// An attached draft owner gives non-empty text the same safe departure.
fn draftSafeToLeave(self: *const Self) bool {
    return self.input.composition().bytes.len == 0 or self.app_hooks.drafts != null;
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

/// After the Session left for navigation, which Esc or a new-chat alias asks for: settles the
/// stopped borrowers as `leave` does, while the terminal stays lent. Esc
/// needs no running command or submission, so they observe their stop
/// within one transport poll. A rejected original is released as /discard
/// does. An unconfirmed one goes to the overview while it has `room` for
/// it; otherwise, or on a failure, the frontend leaves as `leave` would.
pub fn back(self: *Self, room: bool) Back {
    std.debug.assert(self.leaving == .returned or self.leaving == .new_session);
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
    /// Anything beyond the ordinary Detached notice must survive departure.
    has_guidance: bool,
    failure: ?anyerror,
};

/// Joins what the Session stopped, after the caller restored the terminal, and writes
/// the guidance that follows restoration. The caller prints the Detached notice.
pub fn leave(self: *Self, ended: anyerror!Outcome, restored: anyerror!void) Departure {
    const result = self.settleDeparture(ended, restored);
    self.writeDeparture(result);
    return result;
}

/// Settles every borrower before the caller decides whether departure can be
/// replaced by a new TUI. No terminal guidance is emitted here.
pub fn settleDeparture(self: *Self, ended: anyerror!Outcome, restored: anyerror!void) Departure {
    const settled = self.settle(restored);
    self.submission.close();
    const cause: ?anyerror = if (ended) |_| null else |err| err;
    const plan = departure.exit(settled, cause, self.submission.view() != null);
    const action_view = self.screen.action_view != null;
    return .{
        .end = if (plan.failure) |err| err else ended,
        .action = if (action_view) self.live.work.first_action else null,
        .failure_notice = action_view and !std.meta.isError(restored),
        .recovery_shown = plan.recovery_before_notice,
        .has_guidance = self.hasDepartureGuidance() or plan.recovery_before_notice or plan.failure != null,
        .failure = plan.failure,
    };
}

/// Known guidance while the screen is still open. A later settlement can add
/// failures, so `settleDeparture` always checks again before any replacement is allowed.
pub fn hasDepartureGuidance(self: *const Self) bool {
    return self.reading.pending_diagnostic != null or self.submission.view() != null or
        self.inspection.command_running or self.screen.action_view != null;
}

/// Emits the already-settled departure. Relaunch never swallows these bytes.
pub fn writeDeparture(self: *Self, result: Departure) void {
    if (self.reading.pending_diagnostic != null) {
        var bytes: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        self.writePendingDiagnostic(&out) catch unreachable;
        stderr.diagnostic("rui: Read failed: {s}\n", .{out.buffered()});
    }
    if (result.recovery_shown) self.recoveryGuide();
    if (self.inspection.command_running and self.inspection.kind == .command) self.commandOutputGuide();
    if (result.failure) |err| switch (err) {
        error.TerminalTooSmall => stderr.diagnostic("rui: Enlarge the terminal and resume this Session. Required instructions do not fit; nothing was authorized by the clipped view.\n", .{}),
        error.TerminalTooLarge => stderr.diagnostic("rui: Rui supports at most 49,152 terminal cells (for example 256 × 192). Shrink the terminal and resume; saved content is unchanged.\n", .{}),
        error.OutOfMemory, error.UnrepresentableTerminalGrapheme, error.DisplayGraphemeTooLarge => stderr.diagnostic("rui: This frame exceeds Rui's bounded display. Shrink the terminal and resume; saved content is unchanged. One-shot session, request and action commands remain available.\n", .{}),
        else => {},
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

/// What each slash command does here.
const Slash = union(enum) {
    new_session,
    inspection: Inspection,
    discard,
    recover: []const u8,
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
        .new, .clear => .new_session,
        .requests => .{ .inspection = .requests },
        .@"reload-skills" => .{ .inspection = .command },
        .recover => .{ .recover = command.argument },
        .discard => .discard,
    };
}

/// Queues a drawn inspection action. Payload is copied into the existing
/// command bank; its semantic kind travels with that queued record.
fn queueInspection(self: *Self, kind: Inspection, payload: []const u8) bool {
    if (!self.input.admitsCommand()) {
        self.sayBusy(null, false);
        return false;
    }
    if (self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return false;
    }
    self.input.queueCommand(payload);
    self.queued_inspection = kind;
    return true;
}

fn slashCommand(self: *Self, text: []const u8) !void {
    if (self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return;
    }
    switch (parse(text)) {
        .new_session => self.newChat(),
        .inspection => self.input.queueCommand(text),
        .discard => {
            self.submission.discardRejected() catch {
                self.notice = "! Unresolved submission retained.";
            };
            if (self.submission.view() == null) self.poll_at = 0;
        },
        .recover => |key| if (self.submission.view() != null) {
            self.recover(key) catch {
                self.notice = "! Recovery key does not match this original submission; nothing sent.";
            };
        } else self.unknownCommand(text),
        .misused => |name| {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            writer.print("! Usage: {s}", .{slash_commands.usage.get(name)}) catch unreachable;
            self.notice = writer.buffered();
        },
        .unknown => self.unknownCommand(text),
    }
}

/// A new chat is navigation, never a Message or a mutation of this Session.
/// Reuse peer navigation's guards and the settled return/retirement boundary.
fn newChat(self: *Self) void {
    if (self.leaving != null) return;
    const action = self.screen.action_view != null or self.live.work.first_action != null or self.reading.prepared_action != null;
    const original: ?Submission.State = if (self.submission.view()) |submission| submission.state else null;
    switch (session_notice.follow(original, self.submission.published(), self.draftSafeToLeave(), action, self.commandActive())) {
        .stay => |why| self.notice = why,
        .leave => self.leaving = .new_session,
    }
}

fn unknownCommand(self: *Self, text: []const u8) void {
    self.notice = slash_commands_shared.unknown(self.notice_buffer[0..slash_commands_shared.unknown_bytes], text);
}

test "frontend answers local and unknown commands in place and keeps Host commands for inspection" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false };
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    const cases = .{
        .{ "/foo bar", "! Unknown command /foo" },
        .{ "/\x1b[2J", "! Unknown command" },
        .{ "/result", "! Unknown command /result" },
        .{ "/rename", "! Unknown command /rename" },
        .{ "/rename lane four", "! Unknown command /rename" },
        .{ "/effort", "! Unknown command /effort" },
        .{ "/effort high", "! Unknown command /effort" },

        .{ "/recover 01234567-89ab-4cde-8012-0123456789ab", "! Unknown command /recover" },
        .{ "/wait", "! Unknown command /wait" },
        .{ "/model", "! Unknown command /model" },
        .{ "/model gpt-5.5", "! Unknown command /model" },
        .{ "/configure --permission-mode ask", "! Unknown command /configure" },

        .{ "/result 01234567-89ab-4cde-8012-0123456789ab", "! Unknown command /result" },
        .{ "/inspect-action", "! Unknown command /inspect-action" },
        .{ "/archive other", "! Unknown command /archive" },
        .{ "/unarchive other", "! Unknown command /unarchive" },
        .{ "/status", "! Unknown command /status" },
        .{ "/reload-skills", "" },
        .{ "/copy", "! Unknown command /copy" },
        .{ "/copy code", "! Unknown command /copy" },
        .{ "/copy file", "! Unknown command /copy" },
        .{ "/copy all", "! Unknown command /copy" },
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

test "a Session lists the skills it saved for the caret's /word, and Tab or Enter on a drawn row replaces the name" {
    const Fake = struct {
        var calls: usize = 0;
        var session: [6]u8 = undefined;
        fn read(_: client.ReadContext, gpa: std.mem.Allocator, _: []const u8, reference: []const u8, prefix: []const u8) !skill_suggestions.Page {
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
    // A leading slash shares the loaded skills with the listed commands.
    try held.keys("/");
    try Fake.answered(held);
    try std.testing.expectEqual(@as(usize, 5), held.screen.commands.?.list.count);
    try held.keys("re\x1b[B\r");
    try std.testing.expectEqualStrings("/recap ", held.self.input.composition().bytes);
    try std.testing.expect(held.self.submission.view() == null);
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
    try held.keys("\x15/review this change\r");
    try std.testing.expect(held.self.submission.intent.? == .message);
    try std.testing.expectEqualStrings("/review this change", try held.self.input.message(held.self.submission.intent.?.message));
    // Another original holds the Message lane, just as for ordinary text.
    try held.keys("/review another change\r");
    try std.testing.expectEqualStrings("/review another change", held.self.input.composition().bytes);
    try std.testing.expectEqualStrings("/review this change", try held.self.input.message(held.self.submission.intent.?.message));
}

test "a Session's /reload-skills drops the skills it listed, and the next read lists the reloaded catalog" {
    const Fake = struct {
        var reloaded = false;
        var calls: usize = 0;
        fn read(_: client.ReadContext, gpa: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !skill_suggestions.Page {
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

/// An admitted inspection edit or command finishes before app settings can
/// start an Upgrade; neither waits across the run's Host-request hold.
pub fn admitsUpgrade(self: *const Self) bool {
    return !self.inspectionQueued() and !self.inspection.command_running;
}

/// No Client work of this conversation's is in flight, so an Upgrade's run
/// may start. A command's read still running is joined before this holds.
pub fn atRest(self: *const Self) bool {
    return self.reader.thread == null and self.submission.task.thread == null and self.skill_task.thread == null;
}

/// Settles this conversation's Client work for an Upgrade's run. The
/// overview starts the run once `atRest` says so. No command waits its
/// turn here: app settings admits a run only while none does, and the run's
/// hold refuses every command after it, so only a running one is left to
/// finish.
fn quiesceUpgrade(self: *Self) !void {
    std.debug.assert(!self.inspectionQueued());
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
    if (self.reading.pending_diagnostic != null and self.reader.thread == null) try self.presentReadDiagnostic();
    if (self.dropSkills()) |err| return err;
}

fn startQueuedCommand(self: *Self) !void {
    if (self.reader.thread == null) if (self.info_edit) |edit| {
        self.inspection.kind = .command;
        const job = self.freeze(.inspection);
        try job.setInfoEdit(edit);
        self.info_edit = null;
        try self.launch(job, reads.runInfoConfigure);
        self.inspection.command_running = true;
        return;
    };
    if (self.reader.thread == null) if (self.input.takeCommand()) |text| {
        const kind = self.queued_inspection orelse parse(text).inspection;
        self.queued_inspection = null;
        try self.leaveFor(kind);
        self.inspection.kind = kind;
        // The worker borrows its own copy; the editor may queue another.
        const job = self.freeze(.inspection);
        @memcpy(job.command_text[0..text.len], text);
        job.command_text_length = text.len;
        job.inspection_submission = self.submission.view();

        // A command is independent of the next info capture.
        if (!self.info_open) self.inspection.status_requested = false;

        try self.launch(job, switch (kind) {
            .command, .result => reads.runCommand,
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
            try writer.print("! Upgrade could not settle Client work: {s}. Draft and original retained; select Version in app settings to retry.", .{@errorName(err)});
            self.notice = writer.buffered();
            self.dirty = true;
            _ = try self.lender.step(self.lender.context, self.shownWork(), .upgrade_failed);
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
                    try writer.print("! Reattach failed: {s}. Draft and original retained; select Version in app settings or reopen with selected Rui.", .{@errorName(err)});
                    self.notice = writer.buffered();
                    _ = try self.lender.step(self.lender.context, self.shownWork(), .upgrade_failed);
                };
                self.withdrawDecided();
            }
            if (self.upgradePhase() == .reobserving and self.reader.thread == null) try self.launch(self.freeze(.activity), reads.scan);
        },
        .active => {},
    }
    if (phase != .active) return .waiting;
    try self.admit();
    if (self.inspectionQueued() and self.reader.thread != null and !self.reader.completed()) {
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
        if (pending.recoverable) try self.presentReadDiagnostic();
    }
    if (self.hostHeld()) return .waiting;
    try self.startQueuedCommand();
    try self.startRetry();
    // Scans continue during consent, so an Action decided elsewhere leaves.
    if (self.reader.thread == null and self.reading.prepared_action == null) {
        if (self.expansion.queued == .ready) {
            const request = self.expansion.queued.ready;
            self.expansion.queued = .none;
            self.expansion.reading = request;
            const job = self.freeze(if (request.target == .tool) .tool else .message);
            job.target = request.target;
            try self.launch(job, if (request.target == .tool) reads.tool else reads.fullMessage);
        }
        if (self.reader.thread == null and !self.reading.opening) if (self.input.nextStep()) |recall| {
            const job = self.freeze(.recall);
            job.recall = recall;
            try self.launch(job, reads.recall);
        };
        if (self.reader.thread == null) if (FeedPolicy.nextRead(self.feedState())) |read| {
            if (read == .permission) {
                try self.launch(self.freeze(.permission), reads.permission);
            } else {
                const job = self.freeze(if (read == .fill_above or read == .fill_below) .fill else .activity);
                self.reading.feed_read = read;
                job.feed_page = FeedPolicy.request(read, self.feedState());
                try self.launch(job, reads.scan);
            }
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
/// Message's saved answer.
fn requestList(self: *Self) ?slash_commands_shared.List {
    if (self.screen.view != .inspection or self.inspection.kind != .requests) return null;
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
    if (self.hostHeld()) return;
    if (self.waitingAction()) |action| {
        self.notice = session_notice.decision(action);
        return;
    }
    if (self.submission.intent != null or key != null) {
        try self.submission.requestRecovery(key);
    } else if (self.retryable()) |fence| {
        self.retry_fence = fence;
    }
}

/// One eligibility value for the gesture, frame-local tail and asynchronous
/// completion. Live facts guard reopened chats; the submission count fences
/// local intent even before an Admission or a scan can report newer work.
fn retryable(self: *const Self) ?RetryFence {
    const ending = self.live.latest_ending orelse return null;
    if (ending.cause.key == null or self.hostHeld()) return null;
    if (self.live.work.state.progress() != null or self.live.queued.count != 0) return null;
    if (self.submission.intent != null or self.submission.task.thread != null or
        self.waitingAction() != null or self.live.work.first_action != null or
        self.reading.prepared_action != null or self.reading.opening or
        self.reading.phase == .permission or self.commandActive() or
        self.retry_fence != null) return null;
    return .{ .ending = ending.key, .sent = self.admission.sent };
}

/// A queued gesture never borrows a running reader's scratch or blocks input.
fn startRetry(self: *Self) !void {
    if (self.reader.thread != null) return;
    const fence = self.retry_fence orelse return;
    self.retry_fence = null;
    if (!std.meta.eql(fence, self.retryable() orelse return)) return;
    const job = self.freeze(.retry);
    job.retry = fence.ending;
    self.retry_fence = fence;
    errdefer self.retry_fence = null;
    try self.launch(job, reads.retry);
}

/// Applies only a successful retry result, after the shared reader owner has
/// joined, preserved its diagnostic and classified cancellation or failure.
fn finishRetry(self: *Self) !void {
    const fence = self.retry_fence orelse return;
    self.retry_fence = null;
    // Consume this gesture once. No ordering of Admission and reader completion
    // can revive it after any newer Message began, even with old live facts.
    if (!std.meta.eql(fence, self.retryable() orelse return)) return;
    const completion = self.job.retryCompletion(self.live.latest_ending);
    switch (completion) {
        .stale => {},
        .failure => |failure| self.notice = switch (failure) {
            .no_message => "! Retry unavailable: no earlier Message. Nothing sent.",
            .too_large => "! Retry unavailable: last Message too large. Nothing sent.",
        },
        .message => |message| {
            const ticket = try self.input.submitPreservingDraft(self.init.io, self.files.scratch, message.length);
            try self.beginMessage(.{ .message = ticket });
        },
    }
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
        if (rows.list.entries[rows.highlight].saved_result) {
            if (self.shownCommands() != null) _ = self.queueInspection(.result, rows.list.entries[rows.highlight].word);
            return .append(draft, "");
        }
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
        .{ .state = .archived, .expected = "Archived · Restore · Sent" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, statusLines(&buffer, "", "Sent", case.state));
        const text = statusLines(&buffer, &context, "Sent", case.state);
        try std.testing.expect(std.mem.endsWith(u8, text, case.expected));
        try std.testing.expect(std.mem.indexOf(u8, text, "…\n") != null);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
    try std.testing.expectEqualStrings("Stopping and archiving", statusLines(&buffer, "", "", .archiving));
    try std.testing.expectEqualStrings("Archived · Restore", statusLines(&buffer, "", "", .archived));
}

/// Another client decided, or the Turn ended: the choice can no longer decide.
/// It leaves before more input is read, so no key decides.
fn withdrawDecided(self: *Self) void {
    const pending = self.screen.consent orelse return;
    if (self.live.work.first_action == pending.action) return;
    self.screen.withdrawAction();
}

/// The normal Message lane, including a leading loaded skill. No draft loan
/// transfers while another submission or read holds it.
fn admitsMessage(self: *const Self) bool {
    return !self.hostHeld() and !self.reading.opening and self.reading.phase != .permission and !self.commandActive() and self.submission.intent == null and self.input.submitted == null;
}

/// Sends a Message, alone or as the reason an Action is denied.
fn beginMessage(self: *Self, intent: Submission.Intent) !void {
    if (!try self.beginSubmission(intent)) return;
    // A sent Message continues the conversation: show it and its reply
    // rather than a page the reader was browsing,
    // or a page asked for before it.
    self.admission.sent += 1;
    self.inspection.status_requested = false;
    self.dropMessageRequest();
    try self.jumpToEnd();
}

/// The same inspection intent supersedes a read at cancellation and settlement.
fn inspectionQueued(self: *const Self) bool {
    return self.info_edit != null or self.input.queuedCommand() != null;
}

/// A queued or running command holds the choice until it completes.
fn commandActive(self: *const Self) bool {
    return self.upgradeHeld() or self.inspectionQueued() or self.inspection.command_running;
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
        } else try self.scroll(action == .next, 1),
        // Shift-Up/Down move half a screen; PgUp/PgDn are their aliases.
        .scroll_up, .scroll_down => if (self.shownCommands()) |shown| {
            shown.move(action == .scroll_down);
            self.dirty = true;
        } else try self.scroll(action == .scroll_down, session_chrome.halfScreen(screen.height)),
        .page_up, .page_down => try self.scroll(action == .page_down, session_chrome.halfScreen(screen.height)),
        .older, .newer => if (self.input.press(action == .older) == .typed) {
            self.notice = "Draft is not empty.";
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
                if (command_input.consumesDraft(self.input.composition().bytes, .cancelled)) self.input.clear();
                self.dirty = true;
                return;
            };
            // Leaving also abandons a Message page not yet shown, and returns
            // the input row to a waiting Action's choice.
            self.dropMessageRequest();
            screen.moveRow(.selector);
            if (action == .close and self.settledView()) {
                const original: ?Submission.State = if (self.submission.view()) |submission| submission.state else null;
                switch (session_notice.close(original, self.submission.published(), self.draftSafeToLeave())) {
                    .leave => {
                        self.leaving = .returned;
                        return;
                    },
                    .stay => |why| self.notice = why,
                }
            }
            if (action != .latest and screen.view == .message) try screen.leaveMessage() else try self.jumpToEnd();
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
            self.notice = "Session is opening.";
        } else try self.converse(.stop),
        .archive => _ = try self.archive(),
    }
    self.dirty = true;
}

/// All archive surfaces use this admission result from the overview owner.
fn archive(self: *Self) !overview_view.ArchiveAdmission {
    if (self.reading.opening) {
        self.notice = "Archive is available once the Session opens.";
        return .refused;
    }
    return self.converseAdmission(.{ .archive = self.line.archive_state });
}

/// Steps the overview with an input here, Ctrl-X or another.
fn converse(self: *Self, input: overview_view.ConversationInput) !void {
    _ = try self.converseAdmission(input);
}

fn converseAdmission(self: *Self, input: overview_view.ConversationInput) !overview_view.ArchiveAdmission {
    // The Upgrade's own inputs are no Host requests, so no hold refuses them.
    const host_intent = switch (input) {
        .other, .cancel_upgrade, .upgrade_failed => false,
        .stop, .archive, .unarchive => true,
    };
    if (host_intent and self.hostHeld()) return .refused;
    if (host_intent and self.upgradeHeld()) {
        self.notice = session_upgrade.refusal(self.upgradePhase());
        return .refused;
    }
    return self.lender.step(self.lender.context, self.shownWork(), input);
}

/// The work the conversation shows now.
fn shownWork(self: *const Self) protocol.session_work.Kind {
    const now_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
    return self.live.work.state.asOf(now_ms);
}

fn scroll(self: *Self, down: bool, rows: usize) !void {
    const screen = self.screen;
    if (screen.view == .feed) {
        const amount: i32 = @intCast(@min(rows, std.math.maxInt(i32)));
        self.app_content.scroll(if (down) amount else -amount);
        self.reading.fills = self.reading.fills.scrolled(self.feedState(), down);
        if (screen.anchor.following()) self.new_below = 0;
    } else for (0..rows) |_| screen.browse(down, false);
    self.dirty = true;
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
    return screen.view == .feed and screen.anchor.following() and screen.action_view == null and self.live.work.first_action == null and
        self.reading.prepared_action == null and !self.commandActive();
}

/// One Ctrl-O read: a Message page, or a tool row opened or closed.
const OpenRequest = struct { target: reads.Target, asked: reader_policy.Asked };

/// Where a Message page would be asked from now.
fn pagePlace(self: *const Self) reader_policy.Place {
    return switch (self.screen.view) {
        .feed => .feed,
        .inspection, .details, .action, .message => .elsewhere,
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
    if (self.app_consent.request != null and self.screen.view == .action) {
        if (self.app_preview.continuation()) |next| self.screen.browsing.top = next;
        return null;
    }
    if (self.pagePlace() == .elsewhere) {
        self.notice = "! Nothing to open in this view.";
        return null;
    }
    const target = switch (try self.app_content.openable(self.init.gpa) orelse {
        self.notice = "Nothing to open in view.";
        return null;
    }) {
        .message => |target| target,
        .session => |id| return id,
        .tool => |key| {
            self.toggleTool(key);
            return null;
        },
    };
    self.openCollapsed(target);
    return null;
}

/// Ctrl-O or a click on a tool row: its saved output opens under it, or
/// closes. The row is read again either way; what is open changes when
/// that read lands.
fn toggleTool(self: *Self, key: feed_window.Key) void {
    const open = !self.screen.feed.opened.has(key);
    self.dirty = true;
    if (open and self.screen.feed.opened.full()) {
        self.notice = "! 64 tool rows are open; close one to open another.";
        return;
    }
    self.expansion.queued = .{ .ready = .{ .target = .{ .tool = .{ .key = key, .open = open } }, .asked = self.pageAsked() } };
    if (open) self.notice = "Opening tool output…";
}

/// The target belongs to a keyed row/offset, never a count from the end.
fn openCollapsed(self: *Self, target: View.Collapsed) void {
    self.dirty = true;
    self.expansion.queued = .{ .ready = .{ .target = .{ .message = target }, .asked = self.pageAsked() } };
    self.notice = "Opening message…";
}

/// The scan owner's progress translated once to the reader's wire cursor.
fn scanCursor(self: *const Self) protocol_reply.ActivityCursor {
    const scan = self.live.scan;
    return .{
        .position = if (scan.cursor) |cursor| cursor.position else 0,
        .ordinal = if (scan.cursor) |cursor| if (cursor.ordinal == std.math.maxInt(u64)) null else cursor.ordinal else null,
        .end = if (scan.catchup) |sweep| sweep.end else null,
    };
}

/// Inputs to the single read policy, derived from the current anchor/window.
fn feedState(self: *Self) FeedPolicy.State {
    const screen = self.screen;
    return .{
        .now_ns = std.Io.Clock.awake.now(self.init.io).nanoseconds,
        .scan_due_ns = self.poll_at,
        .opening = self.reading.opening,
        .need = screen.anchor.need(screen.feed.layoutEntriesWith(screen.textLayout(), self.app_content.presentation()), screen.height, screen.feed.edges()),
        .at_end = screen.feed.at_end,
        .low = screen.feed.low,
        .high = screen.feed.high,
        .scan = self.live.scan,
        .window_provisional = screen.feed.firstProvisional(),
        .window_continuing = screen.feed.forward_partial,
        .selection_held = self.app_content.dragging(),
        .fills = self.reading.fills,
        .choice_open = screen.consent != null or self.app_consent.request != null,
        .action_named = self.live.work.first_action != null,
        .submission = self.submission.view() != null,
    };
}

/// An evicted high edge needs a fresh opening; leave the old frame in place.
fn jumpToEnd(self: *Self) !void {
    try self.screen.latest();
    switch (feed_reads.jumpToEnd(self.screen.feed.at_end)) {
        .follow => self.screen.anchor.follow(),
        .opening_keep_frame => self.reading.opening = true,
    }
    self.new_below = 0;
    self.reading.fills = .{};
    self.dirty = true;
}

/// Observe every anchor/window transition, including while a read is active.
fn observeFeed(self: *Self) void {
    self.reading.fills = self.reading.fills.observe(self.feedState());
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
        if (shown.list.entries[shown.highlight].saved_result) {
            _ = self.queueInspection(.result, shown.list.entries[shown.highlight].word);
            return;
        }
        const taken = shown.list.enter(shown.highlight);
        if (!taken.runs) return self.takeRow(shown);
        switch (self.input.append(taken.rest)) {
            .refused => |why| self.notice = refusedNotice(why),
            else => if (taken.runs) try self.runLine(),
        }
    } else if (slash_commands.parse(self.input.composition().bytes) == .unknown and self.skills.startsSkill(self.input.composition().bytes)) {
        if (!self.admitsMessage()) return self.sayBusy(null, false);
        const ticket = self.input.submitText(self.input.composition().bytes);
        try self.beginMessage(.{ .message = ticket });
    } else try self.runLine();
}

/// Runs the draft as a command and takes its line. A line a hold refused
/// stays until the hold lifts.
fn runLine(self: *Self) !void {
    const text = self.input.composition().bytes;
    const end: command_input.DraftEnd = if (self.upgradeHeld()) .held else .submitted;
    defer if (command_input.consumesDraft(text, end)) self.input.clear();
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
    if (shown.list.entries[shown.highlight].saved_result) {
        _ = self.queueInspection(.result, shown.list.entries[shown.highlight].word);
        return;
    }
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
        .unbound => unreachable,
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
    const fenced = if (self.reading.pending_diagnostic) |pending|
        pending.failure.status == 503 and std.mem.eql(u8, pending.failure.diagnostic.code.slice(), "dispatch_fenced")
    else
        false;
    const lost = (fenced or (end == .failed and self.reader.result.failure_origin == .host_transport)) and self.hostFailure();
    // Each phase settles the request it owns first, whatever the read's end:
    // a request left outstanding would refuse every later one.
    if (self.reading.phase == .recall and end != .complete) self.input.abandonStep();
    const phase = self.reading.phase;
    if (phase == .inspection and self.info_effect == .configure and self.job.info_edit != null) {
        self.info_effect = if (end == .complete and self.job.result.info_saved) .refreshing else .failed;
        if (self.info_effect == .refreshing) {
            self.inspection.status_requested = true;
            self.poll_at = 0;
        }
    } else if (phase == .inspection and self.info_effect == .copy) {
        self.info_effect = if (end == .complete and self.job.result.copied == .clipboard) .saved else .failed;
    }
    // All terminal outcomes release the retry read, including supersession.
    // Keep its phase through policy/application; diagnostics retain their own.
    defer if (phase == .retry and end != .absent) {
        self.retry_fence = null;
        self.job.retry = null;
        self.reading.phase = .activity;
        self.dirty = true;
    };
    if (end != .complete and (phase == .message or phase == .tool)) self.expansion.reading = null;
    if (lost) {
        // A joined failed read has published no staged output. Keep its
        // cursor, opening state, documents, draft and scroll for the next scan.
        self.reading.pending_diagnostic = null;
        self.inspection.command_running = false;
        self.poll_at = 0;
        return;
    }
    // A fatal failure leaves command output for exit to print.
    if (end.failure(reader_policy.settleMode(self.upgradePhase() == .quiescing, self.inspectionQueued()))) |err| return err;
    const inspection = self.readInspection();
    if (end == .complete) switch (reader_policy.shows(phase, inspection)) {
        .tool => {
            const request = self.expansion.reading.?;
            self.expansion.reading = null;
            if (reader_policy.messageShows(request.asked, self.pageAsked())) try self.showTool(request.target.tool.key, request.target.tool.open);
        },
        .message => {
            const request = self.expansion.reading.?;
            self.expansion.reading = null;
            if (reader_policy.messageShows(request.asked, self.pageAsked())) try self.screen.showMessage(self.init.io, self.files.inspection);
        },
        .recalled => try self.showRecalled(),
        .retried => try self.finishRetry(),
        .staged => try self.showStaged(),
        .copy => try self.showCopy(),
        .page => try self.showInspection(),
    };
    // Shown, or never written: exit no longer prints it.
    if (reader_policy.commandSettled(end == .complete, phase)) self.inspection.command_running = false;
    // A reload changed what this Session's Messages bind: its held skills
    // are stale.
    if (end == .complete and phase == .inspection and inspection == .command and self.inspection.kind == .command and self.job.info_edit == null) switch (slash_commands.parse(self.job.command_text[0..self.job.command_text_length])) {
        .command => |command| if (command.name == .@"reload-skills") if (self.dropSkills()) |err| return err,
        else => {},
    };
    try self.applyReader(end);
}

/// The inspection the joined read ran for, as settling needs it.
fn readInspection(self: *const Self) reader_policy.Inspection {
    return switch (self.inspection.kind) {
        .copy => .copy,
        .command, .result => .command,

        .requests => .other,
    };
}

/// What the queued row shows, if it shows (see `queued_line.unshown`): the
/// newest waiting Message, by the line read from it, and how many wait
/// that live output has not shown.
pub fn queuedRow(self: *const Self) ?struct { newest: u64, waiting: queued_line.Waiting } {
    const queued = self.live.queued;
    const count = queued.count - @intFromBool(queued.count != 0 and !self.live.work.state.holdsQueue());
    if (count == 0) return null;
    const shown = if (self.live.queued_line) |*shown| shown else return null;
    if (shown.admission != queued.newest_admission) return null;
    return .{ .newest = queued.newest_admission, .waiting = .{ .line = shown.line.slice(), .count = count } };
}

/// Applies one page through the policy's single attachment decision. The
/// resident window owns rows; neither the scan nor a fill owns another copy.
fn showStaged(self: *Self) !void {
    defer self.observeFeed();
    const page = self.job.feed_page orelse return;
    const read = self.reading.feed_read;
    const window = &self.screen.feed;
    const provisional = window.firstProvisional();
    const edge = if (read == .fill_above) window.low else window.high;
    if (!FeedPolicy.applies(read, page.started_from, page.replace_from, edge, provisional)) return;
    const result = &self.job.result;
    if (read == .scan) {
        const scan = FeedPolicy.applyScan(window.high, page.started_from, page.replace_from, provisional, result.new_rows);
        if (!self.screen.anchor.following()) self.new_below += result.new_rows;
        if (scan.rows == .count_only) return;
    }
    if (read == .opening) {
        // Only now abandon the old frame of a jump whose high was evicted.
        window.trim(window.count, 0);
        self.screen.anchor.follow();
        self.new_below = 0;
    } else if (page.replace_from != null and !page.continuing and read != .fill_above) {
        try window.replaceFrom(page.replace_from.?, &.{});
    }
    const document = try self.init.gpa.create(viewport.Document);
    defer self.init.gpa.destroy(document);
    const backward = page.direction == .backward;
    var complete = true;
    var inserted: usize = 0;
    for (0..result.row_count) |step| {
        const row = &result.rows[if (backward) result.row_count - step - 1 else step];
        try self.stagedRow(row, document);
        var targets: [16]feed_window.MessageTarget = undefined;
        var target_count: usize = 0;
        var at: usize = 0;
        while (at < document.length and target_count < row.collapsed_count) : (at += 1) {
            if (document.collapsed(at, @min(at + "┄".len, document.length)).last == at) {
                targets[target_count] = .{ .offset = at, .target = row.collapsed_targets[target_count] };
                target_count += 1;
            }
        }
        const entry: feed_window.Entry = .{ .key = row.key, .text = feed_window.Text.fromDocument(document), .tight = row.tight, .provisional = row.provisional, .messages = targets[0..target_count] };
        if (!self.insertFeed(entry, backward)) {
            complete = false;
            break;
        }
        inserted += 1;
    }
    // A fill the window had no room for waits like a failed one: asking for
    // the same page again would read it again and place nothing.
    if (!complete and inserted == 0) self.reading.fills = self.reading.fills.failed(read, page);
    if (backward) {
        window.low = if (complete) result.low else if (window.count != 0) window.entries[0].key else window.low;
        window.at_start = complete and result.at_start;
        if (read == .opening) {
            window.high = result.high;
            window.at_end = result.at_end;
            window.forward_partial = false;
        }
        self.screen.anchor.prepend(window.layoutEntriesWith(self.screen.textLayout(), self.app_content.presentation()), self.screen.height, window.edges());
    } else {
        window.high = if (complete) result.high else if (window.count != 0) window.entries[window.count - 1].key else window.high;
        window.at_end = complete and result.at_end;
        window.forward_partial = !window.at_end;
        self.screen.anchor.append(window.layoutEntriesWith(self.screen.textLayout(), self.app_content.presentation()), self.screen.height, window.edges());
    }
    self.reading.output_started = self.reading.output_started or result.row_count != 0;
    self.dirty = true;
}

/// One staged row as prepared feed text.
fn stagedRow(self: *Self, row: *const reads.RenderedRow, document: *viewport.Document) !void {
    document.* = .{ .sidenotes = true, .quotes = true, .width_method = self.screen.vx.caps.unicode };
    var buffer: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < row.length) {
        const wanted: usize = @intCast(@min(buffer.len, row.length - copied));
        const got = try self.files.inspection.readPositionalAll(self.init.io, buffer[0..wanted], row.offset + copied);
        if (got != wanted) return error.TruncatedDisplayScratch;
        try document.append(buffer[0..got]);
        copied += got;
    }
    try document.prepare();
}

/// Lands a tool row read again for Ctrl-O. The open set changes first: a row
/// that left the window meanwhile reloads as asked. A row still here is
/// replaced in place, so the anchor keeps the view where it was.
fn showTool(self: *Self, key: feed_window.Key, open: bool) !void {
    const window = &self.screen.feed;
    window.opened.set(key, open);
    const document = try self.init.gpa.create(viewport.Document);
    defer self.init.gpa.destroy(document);
    try self.stagedRow(&self.job.result.rows[0], document);
    while (true) {
        const index = window.indexOf(key) orelse return;
        if (window.replace(key, feed_window.Text.fromDocument(document))) |_| {
            self.screen.anchor.replace(window.heights(self.screen.textLayout())[index]);
            break;
        } else |_| {}
        // Opened output needs room: rows outside the view and its loading
        // margins leave, as for any arriving row.
        const trim = self.screen.anchor.trim(window.heights(self.screen.textLayout()), self.screen.height, window.count -| 1);
        if (trim.drop_front == 0 and trim.drop_back == 0) {
            window.opened.set(key, !open);
            self.shown_notice.show("! Tool output does not fit this view; scroll and try again.", self.nowMs());
            break;
        }
        window.trim(trim.drop_front, trim.drop_back);
    }
    self.dirty = true;
}

/// Makes room on the side away from the insertion only, so the window stays
/// one contiguous run. A fill evicts only outside the view and its loading
/// margins and otherwise stops at its last inserted key. A row arriving at
/// the end being followed always goes in: capacity outranks the margin, and
/// the oldest rows leave even from the view the new row is about to replace.
fn insertFeed(self: *Self, entry: feed_window.Entry, backward: bool) bool {
    const window = &self.screen.feed;
    while (true) {
        const inserted = if (backward) window.prepend(&.{entry}) else window.append(&.{entry});
        if (inserted) |_| return true else |_| {}
        var trim = self.screen.anchor.trim(window.heightsWith(self.screen.textLayout(), self.app_content.presentation()), self.screen.height, window.count -| 1);
        if (backward) trim.drop_front = 0 else trim.drop_back = 0;
        if (trim.drop_front == 0 and trim.drop_back == 0) {
            if (backward or window.count == 0 or !self.screen.anchor.following()) return false;
            trim.drop_front = 1;
        }
        window.trim(trim.drop_front, trim.drop_back);
    }
}

/// Test fixtures seed the real resident owner, not a second live document.
fn seedFeed(screen: *Screen, bytes: []const u8) !void {
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{ .sidenotes = true, .width_method = screen.vx.caps.unicode };
    try document.append(bytes);
    try document.prepare();
    const key: feed_window.Key = .{ .position = if (screen.feed.high) |high| high.position + 1 else 1 };
    try screen.feed.append(&.{.{ .key = key, .text = feed_window.Text.fromDocument(document) }});
    screen.feed.high = key;
    if (screen.feed.low == null) screen.feed.low = key;
    screen.feed.at_start = true;
    screen.feed.at_end = true;
}

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

/// A read's diagnostic is a notice, never a feed row: the summary, then the
/// Host's own words.
fn presentReadDiagnostic(self: *Self) !void {
    const pending = self.reading.pending_diagnostic.?;
    var out = std.Io.Writer.fixed(&self.notice_buffer);
    try out.writeAll(switch (reader_policy.unavailable(pending.phase, self.readInspection())) {
        .say => |text| text,
        .copy => "! Copy unavailable; draft retained.",
    });
    try out.writeAll(" ");
    try self.writePendingDiagnostic(&out);
    self.notice = out.buffered();
    self.reading.pending_diagnostic = null;
    self.dirty = true;
}

test "frontend joined read diagnostic survives a worker reset and shows as the notice" {
    const Worker = struct {
        fn fail(_: *anyopaque, task: *Task) !void {
            var failure: protocol_reply.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
            try failure.diagnostic.type.set("busy");
            try failure.diagnostic.code.set("host_busy\x1b\n");
            return task.requests().failRead(failure);
        }
        fn idle(_: *anyopaque, _: *Task) !void {}
    };
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .colour = false, .reading = .{ .phase = .message } };
    self.init.io = std.testing.io;
    self.input.init();
    try self.reader.start(std.testing.io, &self, Worker.fail);
    try self.settleReader(); // Preparation is recoverable, not fatal.
    try std.testing.expect(self.reading.pending_diagnostic != null);
    try std.testing.expect(self.reader.read_failure == null);
    // Exercise the actual Task reset, also performed before spawn can fail.
    try self.reader.start(std.testing.io, &self, Worker.idle);
    try self.reader.join();
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    self.stop();
    const settled = self.settle({});
    for ([_]anyerror{ error.WriteFailed, error.SystemResources }) |cause|
        try std.testing.expectEqual(cause, settled.failure(.final_exit, cause).?);
    try self.presentReadDiagnostic();
    try std.testing.expect(self.reading.pending_diagnostic == null);
    try std.testing.expectEqualStrings("! Message unavailable. HTTP 503; type: busy; code: host_busy\\x1b\\n", self.notice.?);
}

fn applyReader(self: *Self, end: ReadEnd) !void {
    if (end.preparationFailure()) {
        if (self.reading.phase == .fill) {
            self.reading.fills = self.reading.fills.failed(self.reading.feed_read, self.job.feed_page.?);
            self.observeFeed();
        }
        if (self.reading.pending_diagnostic == null)
            self.notice = switch (reader_policy.unavailable(self.reading.phase, self.readInspection())) {
                .say => |text| text,
                .copy => reader_policy.copy_unavailable,
            };
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    var observed: ?struct { work: protocol.session_work.Work, opening: bool } = null;
    const phase = self.reading.phase;
    if (phase == .message or phase == .tool) {
        self.notice = null; // Clears "Opening message…" or "Opening tool output…".
    } else if (phase == .activity or phase == .permission) {
        const read = self.reading.feed_read;
        // Filtered fills never overwrite current work or move the scan cursor.
        if (read == .opening or read == .scan or phase == .permission) {
            const result = &self.job.result;
            observed = .{ .work = result.work.work, .opening = read == .opening };
            self.live.work = .fromCore(result.work.work);
            self.live.queued = result.queued;
            if (result.queued_line) |shown| self.live.queued_line = shown;
            if (self.job.open_status or self.job.watch_status) try self.applyStatus();
            if (result.line) |*line| self.line = line.*;
            if (result.hint) |*hint| self.hint = hint.*;
            self.live.view = result.live;
            self.live.latest_ending = result.latest_ending;
            const cursor = result.cursor;
            self.live.scan = self.live.scan.landed(self.job.feed_page.?, if (cursor.position != 0) .{ .position = cursor.position, .ordinal = cursor.ordinal orelse std.math.maxInt(u64) } else null, cursor.end);
            if (read == .opening) self.reading.opening = false;
            self.upgrade_stale = false;
            self.poll_at = feed_reads.scanDue(std.Io.Clock.awake.now(self.init.io).nanoseconds, self.inspection.status_requested);
        }
        if (phase == .permission) {
            self.reading.prepared_action = self.job.result.action;
            self.reading.prepared_summary = self.job.result.summary;
            if (self.reading.prepared_action == null) self.reading.phase = .activity;
        }
    }
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
        .{ .archive = .archived, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .status = "Command accepted\nArchived · Restore" },
        .{ .archive = .active, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .status = "Command accepted" },
    }) |case| {
        const previous = self.line.archive_state;
        self.job.result = .{ .line = .{ .read = .{ .revision = 1, .end = 2 }, .archive_state = case.archive }, .work = .{ .work = .{ .state = case.work } } };
        try self.applyReader(.{ .cancelled = .{ .phase = .activity, .rendering = false } });
        try std.testing.expectEqual(previous, self.line.archive_state);
        self.job.feed_page = FeedPolicy.request(.scan, self.feedState());
        try self.applyReader(.complete);
        try std.testing.expectEqual(case.archive, self.line.archive_state);
        try std.testing.expectEqualDeep(case.work, self.live.work.state);
        // The badge is the archive state's, never the work's.
        try std.testing.expectEqualStrings(case.status, statusLines(&buffer, "Command accepted", "", self.line.archive_state));
        try std.testing.expectEqualStrings("unused", self.session);
    }
}

test "the queued row shows what waits until it is taken, whatever the work is doing" {
    const some: protocol.Queued = .{ .count = 2, .oldest_position = 30, .newest_admission = 9, .newest_position = 34 };
    const Case = struct { queued: protocol.Queued, state: protocol.WorkState, line: ?u64 = 9, count: u64 = 2, shown: bool };
    var line: queued_line.Line = .{ .len = 0 };
    try line.set("check the cache");
    for ([_]Case{
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .shown = true },
        .{ .queued = some, .state = .{ .approval = .{ .since = 1 } }, .shown = true },
        // A Message held back and then left pending, which live output
        // shows only once taken: the row shows it meanwhile.
        .{ .queued = some, .state = .{ .pending = .{ .since = 1 } }, .count = 1, .shown = true },
        .{ .queued = some, .state = .{ .idle = .{ .since = 1 } }, .count = 1, .shown = true },
        // Sent while the Session stayed pending: the first showed at its
        // Admission and still waits, so the row counts only the second.
        .{ .queued = some, .state = .{ .pending = .{ .since = 1 } }, .count = 1, .shown = true },
        // Nothing waits, or the one waiting showed while it waited.
        .{ .queued = .{}, .state = .{ .working = .{ .since = 1 } }, .shown = false },
        .{ .queued = .{ .count = 1, .oldest_position = 34, .newest_admission = 9, .newest_position = 34 }, .state = .{ .pending = .{ .since = 1 } }, .shown = false },
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
            .live = .{ .queued = case.queued, .work = .{ .state = case.state }, .queued_line = if (case.line) |admission| .{ .admission = admission, .line = line } else null },
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
    try self.screen.showFile(self.init.io, self.files.inspection, .inspection);
    if (self.inspection.kind == .requests) self.saved_requests = self.job.result.requests;
    // The page heading already says how to return.
    self.notice = null;
}

/// A joined clipboard read. The clipboard's bytes go out between frames, so no frame
/// splits the sequence.
fn showCopy(self: *Self) !void {
    errdefer if (self.info_effect == .saved) {
        self.info_effect = .failed;
    };
    self.dirty = true;
    self.notice = switch (self.job.result.copied) {
        .no_answer => "No answer to copy",
        .too_large => TerminalText.clipboard_too_large,
        // Rui cannot see whether the clipboard took it.
        .clipboard => |range| sent: {
            try self.app_hooks.copy(self.app_hooks.context, self.files.scratch, range.start, range.length);
            break :sent "Sent to clipboard";
        },
    };
}

/// Adopt the inspection capture without ever replacing the feed with a page.
fn applyStatus(self: *Self) !void {
    if (!self.job.result.status and self.inspection.status == null) return;
    if (self.job.result.status) self.inspection.status = @intFromBool(self.job.status_taken == &self.inspection.sessions[1]);
    self.inspection.status_requested = false;
    if (self.info_effect == .refreshing) self.info_effect = .saved;
    if (self.info_open and !self.app_info.hasChoice() and self.app_info.pending == null) self.app_info.refresh();
    self.dirty = true;
}

fn leaveFor(self: *Self, _: Inspection) !void {
    if (!self.info_open) try self.screen.latest();
}

fn statusShown(self: *const Self) bool {
    return self.info_open or self.info_effect == .refreshing;
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
    root: Root = .{ .overview = empty_app_text.widget(), .list = empty_app_text.widget(), .compose = empty_app_text.widget() },
    arena: std.heap.ArenaAllocator,
    /// What the frontend asked of its lender, in order.
    left: ?Outcome = null,
    /// The Upgrade its lender shows.
    upgrade: session_upgrade.Upgrade = .{},
    size: vxfw.MaxSize = .{ .width = 80, .height = 24 },

    fn create() !*HeldFrontend {
        return createWithDrafts("unused", null);
    }

    fn createWithDrafts(id: []const u8, drafts: ?*session_drafts.Drafts) !*HeldFrontend {
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
        held.self.begin(init, "unused", id, held.directory[0..directory], undefined, undefined, undefined, undefined, screen, &held.interrupted, lender);
        held.self.reading.opening = false;
        screen.feed.at_end = true;
        screen.feed.at_start = true;
        // No read is due: a test hands the frontend what a read would.
        held.self.poll_at = std.math.maxInt(i96);
        held.self.submission.environment = .empty;
        _ = held.self.attach(.{ .drafts = drafts, .root = &held.root, .context = held, .leave = onLeave, .copy = onCopy, .on_open = onOpen }, .{ .depth = .none });
        return held;
    }

    fn destroy(held: *HeldFrontend) void {
        _ = held.self.dropSkills();
        // As `settle` does: a read a key started, such as /requests' page, may
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
        try held.self.widget().captureEvent(ctx, event);
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

test "App Session request overflow opens in place with Ctrl-O or a continuation click" {
    for ([_]vxfw.MaxSize{ .{ .width = 46, .height = 30 }, .{ .width = 140, .height = 40 } }) |size| {
        for ([_]bool{ false, true }) |typing| {
            for ([_]bool{ false, true }) |click| {
                const held = try HeldFrontend.create();
                defer held.destroy();
                held.size = size;
                const file = try held.adopt(40);
                defer file.close(std.testing.io);
                if (typing) try held.keys("kept draft");
                const before = try held.shown();
                // Footer/state, selector or single-line draft (five rows),
                // then one quiet row reporting the undisplayed request rows.
                const expected = if (size.height.? == 30) "… 16 more lines" else "… 6 more lines";
                try std.testing.expect(std.mem.indexOf(u8, before, expected) != null);
                try std.testing.expect(std.mem.indexOf(u8, before, "row 039") == null);
                try std.testing.expectEqual(.action, held.screen.view);
                if (click) {
                    var ctx = held.context();
                    const preview = &held.self.app_preview;
                    const row: i16 = @intCast(preview.drawn.height);
                    // The continuation row hovers in the hover role at every depth.
                    for ([_]overview_view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
                        errdefer std.debug.print("depth={s}\n", .{@tagName(depth)});
                        held.self.app_caps = .{ .depth = depth };
                        _ = try held.draw();
                        try preview.widget().handleEvent(&ctx, .mouse_enter);
                        try preview.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 2, .row = row, .button = .none, .type = .motion, .mods = .{} } });
                        const hovered = try preview.widget().draw(.{ .arena = held.arena.allocator(), .min = .{}, .max = .{ .width = preview.size.width, .height = preview.size.height }, .cell_size = .{} });
                        const role = style.of(held.self.app_caps, .{ .background = .hover });
                        for (0..hovered.size.width) |col| {
                            const cell = hovered.readCell(@intCast(col), @intCast(row)).style;
                            try std.testing.expectEqual(role.bg, cell.bg);
                            try std.testing.expectEqual(role.ul_style, cell.ul_style);
                            try std.testing.expectEqual(role.reverse, cell.reverse);
                        }
                        try preview.widget().handleEvent(&ctx, .mouse_leave);
                    }
                    held.self.app_caps = .{ .depth = .none };
                    _ = try held.draw();
                    for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| {
                        try preview.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 2, .row = row, .button = .left, .mods = .{}, .type = kind } });
                    }
                } else {
                    try held.keys("\x0f");
                    try held.settle();
                }
                const opened = try held.shown();
                try std.testing.expect(std.mem.indexOf(u8, opened, "row 039") != null);
                try std.testing.expect(std.mem.indexOf(u8, opened, "more lines") == null);
                try std.testing.expectEqual(.action, held.screen.view);
                try std.testing.expectEqual(@as(?u64, 0xa), held.self.app_consent.request);
                try std.testing.expectEqualStrings(if (typing) "kept draft" else "", held.self.input.composition().bytes);
                // The whole request remains in the same panel and ordinary
                // scrolling still reaches its first row after opening.
                try held.keys("\x1b[5~\x1b[5~\x1b[5~\x1b[5~");
                try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "row 000") != null);
            }
        }
    }
}

test "App Session binds the hover role to every widget it owns with a hover style at every depth" {
    for ([_]overview_view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
        errdefer std.debug.print("depth={s}\n", .{@tagName(depth)});
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.self.app_caps = .{ .depth = depth };
        // A shown palette binds too; it draws only without a request.
        try held.keys("/rel");
        _ = try held.draw();
        try std.testing.expect(held.screen.commands != null);
        const role = style.of(held.self.app_caps, .{ .background = .hover });
        var bound: usize = 0;
        const info = @typeInfo(Self).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            if (@typeInfo(Field) == .@"struct" and @hasField(Field, "hover_style")) {
                errdefer std.debug.print("field={s}\n", .{name});
                try std.testing.expectEqualDeep(role, @field(held.self, name).hover_style);
                bound += 1;
            }
        }
        // app_card, app_preview, app_content, app_document and app_palette.
        try std.testing.expectEqual(5, bound);
    }
}

test "App Session fitting request has no overflow state or open side effect" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    const before = try std.testing.allocator.dupe(u8, try held.shown());
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "row 002") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "more lines") == null);
    try std.testing.expectEqual(null, held.self.app_preview.continuation());
    try held.keys("\x0f");
    try held.settle();
    try std.testing.expectEqualStrings(before, try held.shown());
}

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
/// What the state notice below the footer shows.
fn barShows(held: *HeldFrontend) ![]const u8 {
    _ = try held.draw();
    return held.self.chrome.state.text;
}

fn sendKeys(frontend: *Self, bytes: []const u8) !void {
    const held: *HeldFrontend = @fieldParentPtr("self", frontend);
    try held.keys(bytes);
}

test "unbound chat input posts no notice and redraws" {
    for ([_][]const u8{ "", "abc" }) |draft| {
        for ([_]bool{ false, true }) |notice_present| {
            const held = try HeldFrontend.create();
            defer held.destroy();
            try held.keys(draft);
            if (notice_present) held.self.shown_notice.show("existing", held.self.nowMs());
            var parser: vaxis.Parser = .{};
            const parsed = try parser.parse("\x1bx", null);
            var ctx = held.context();
            ctx.redraw = false;
            try held.deliver(&ctx, .{ .key_press = parsed.event.?.key_press });
            try std.testing.expect(ctx.redraw);
            try std.testing.expectEqualStrings(draft, held.self.input.composition().bytes);
            try std.testing.expect(held.self.shown_notice.current(held.self.nowMs()) == null);
        }
    }
}

test "App Session draft storage still guards pending originals Actions and commands" {
    for ([_]enum { original, action, command }{ .original, .action, .command }) |pending| {
        var drafts: session_drafts.Drafts = .{};
        defer drafts.deinit(std.testing.allocator);
        const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
        defer a.destroy();
        try a.keys("kept");
        switch (pending) {
            .original => {
                a.self.submission.intent = .{ .decision = .{ .action = 1, .decision = .deny } };
                a.self.submission.state = .submitting;
            },
            .action => a.self.live.work.first_action = 1,
            .command => a.self.inspection.command_running = true,
        }
        defer {
            a.self.submission.intent = null;
            a.self.live.work.first_action = null;
            a.self.inspection.command_running = false;
        }
        var ctx = a.context();
        try a.self.openPeer(&ctx, "bbbbbb");
        try std.testing.expect(a.left == null);
        try std.testing.expectEqualStrings("kept", a.self.input.composition().bytes);
        try std.testing.expect(drafts.take(std.testing.allocator, "aaaaaa") == null);
    }
}

test "App Session draft save failure retains the active text and does not leave" {
    var drafts: session_drafts.Drafts = .{};
    defer drafts.deinit(std.testing.allocator);
    const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
    defer a.destroy();
    try a.keys("kept\x1b[D");
    var space: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&space);
    a.self.init.gpa = failing.allocator();
    defer a.self.init.gpa = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, a.keys("\x07"));
    try std.testing.expect(a.left == null);
    try std.testing.expectEqualStrings("kept", a.self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), a.self.input.composition().cursor);
    try std.testing.expect(drafts.take(std.testing.allocator, "aaaaaa") == null);
}

test "App Session draft handoff preserves valid overflow-rejected and malformed-rejected input" {
    const Open = struct {
        fn peer(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {}
    };
    const gpa = std.testing.allocator;
    const full = try gpa.alloc(u8, Input.capacity);
    defer gpa.free(full);
    @memset(full, 'x');
    const cases = [_]struct { bytes: []const u8, rejected: ?keymap.Refusal }{
        .{ .bytes = "first\nαbeta", .rejected = null },
        .{ .bytes = full, .rejected = .overflow },
        .{ .bytes = "first\nαbeta", .rejected = .invalid },
        .{ .bytes = "", .rejected = .invalid },
    };
    for (cases) |case| {
        for ([_]enum { back, peer, detached }{ .back, .peer, .detached }) |path| {
            var drafts: session_drafts.Drafts = .{};
            defer drafts.deinit(gpa);
            const cursor = case.bytes.len - @min(case.bytes.len, 2);
            {
                const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
                defer a.destroy();
                try a.keys(case.bytes);
                try a.keys("\x1b[D\x1b[D");
                if (case.rejected) |why| try a.keys(if (why == .overflow) "x" else "\xff");
                try std.testing.expectEqualStrings(case.bytes, a.self.input.composition().bytes);
                try std.testing.expectEqual(cursor, a.self.input.composition().cursor);
                try std.testing.expectEqual(case.rejected, a.self.input.snapshot().rejected);
                switch (path) {
                    .back => try a.keys("\x07"),
                    .peer => {
                        a.self.app_hooks.on_open = Open.peer;
                        var ctx = a.context();
                        try a.self.openPeer(&ctx, "bbbbbb");
                    },
                    .detached => try a.keys("\x03"),
                }
                try std.testing.expectEqual(if (path == .detached) Outcome.detached else Outcome.returned, a.left.?);
            }
            {
                const b = try HeldFrontend.createWithDrafts("bbbbbb", &drafts);
                defer b.destroy();
                try std.testing.expectEqualStrings("", b.self.input.composition().bytes);
                try b.keys("other\x1b[D\x07");
            }
            {
                const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
                defer a.destroy();
                try std.testing.expectEqualStrings(case.bytes, a.self.input.composition().bytes);
                try std.testing.expectEqual(cursor, a.self.input.composition().cursor);
                // Assert the boundary outcome, not just the restored flag.
                try a.keys("\r");
                try std.testing.expectEqual(@as(u64, if (case.rejected == null) 1 else 0), a.self.admission.sent);
                if (case.rejected) |why| try std.testing.expectEqualStrings(refusedNotice(why), a.self.shown_notice.current(a.self.nowMs()).?);
                try std.testing.expectEqualStrings("", a.self.input.composition().bytes);
            }
            {
                const b = try HeldFrontend.createWithDrafts("bbbbbb", &drafts);
                defer b.destroy();
                try std.testing.expectEqualStrings("other", b.self.input.composition().bytes);
                try std.testing.expectEqual(@as(usize, 4), b.self.input.composition().cursor);
            }
        }
    }
}

test "App Session drafts survive switching chats with their caret and sending removes only that chat's draft" {
    const Open = struct {
        fn peer(_: *anyopaque, _: *vxfw.EventContext, _: *const [session_id.bytes]u8) !void {}
    };
    for ([_]enum { back, peer, detached }{ .back, .peer, .detached }) |path| {
        var drafts: session_drafts.Drafts = .{};
        defer drafts.deinit(std.testing.allocator);
        {
            const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
            defer a.destroy();
            try a.keys("first\nαbeta\x1b[D\x1b[D");
            try std.testing.expectEqualStrings("first\nαbeta", a.self.input.composition().bytes);
            try std.testing.expectEqual(@as(usize, "first\nαbe".len), a.self.input.composition().cursor);
            switch (path) {
                .back => try a.keys("\x07"),
                .peer => {
                    a.self.app_hooks.on_open = Open.peer;
                    var ctx = a.context();
                    try a.self.openPeer(&ctx, "bbbbbb");
                },
                .detached => try a.keys("\x03"),
            }
            try std.testing.expectEqual(if (path == .detached) Outcome.detached else Outcome.returned, a.left.?);
        }
        {
            const b = try HeldFrontend.createWithDrafts("bbbbbb", &drafts);
            defer b.destroy();
            try std.testing.expectEqualStrings("", b.self.input.composition().bytes);
            try b.keys("second\x1b[D\x07");
            try std.testing.expectEqual(Outcome.returned, b.left.?);
        }
        {
            const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
            defer a.destroy();
            try std.testing.expectEqualStrings("first\nαbeta", a.self.input.composition().bytes);
            try std.testing.expectEqual(@as(usize, "first\nαbe".len), a.self.input.composition().cursor);
            // Taking, rather than copying, leaves no stale saved draft while active.
            try std.testing.expect(drafts.take(std.testing.allocator, "aaaaaa") == null);
            try a.keys("\r");
            try std.testing.expectEqual(@as(u64, 1), a.self.admission.sent);
            try std.testing.expectEqualStrings("", a.self.input.composition().bytes);
            try a.keys("\x03");
            try std.testing.expectEqual(Outcome.detached, a.left.?);
            try std.testing.expect(drafts.take(std.testing.allocator, "aaaaaa") == null);
        }
        {
            const a = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
            defer a.destroy();
            try std.testing.expectEqualStrings("", a.self.input.composition().bytes);
            try std.testing.expectEqual(@as(usize, 0), a.self.input.composition().cursor);
            const b = try HeldFrontend.createWithDrafts("bbbbbb", &drafts);
            defer b.destroy();
            try std.testing.expectEqualStrings("second", b.self.input.composition().bytes);
            try std.testing.expectEqual(@as(usize, 5), b.self.input.composition().cursor);
            const fresh = try HeldFrontend.createWithDrafts("cccccc", &drafts);
            defer fresh.destroy();
            try std.testing.expectEqualStrings("", fresh.self.input.composition().bytes);
        }
    }
}

test "sending a Message drops a closed chat-info capture still waiting to start" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.keys("\x1bi\x1b");
    try std.testing.expect(!held.self.info_open and held.self.inspection.status_requested);
    try std.testing.expect(held.self.reader.thread == null);
    try held.keys("hello\r");
    try std.testing.expect(held.self.submission.intent.? == .message);
    try std.testing.expect(!held.self.inspection.status_requested);
    try std.testing.expect(held.self.reader.thread == null);
}

test "sending a Message from a browsed page returns the screen to the latest conversation" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try seedFeed(held.screen, "OLDER ROW\n");
    for (0..60) |_| try seedFeed(held.screen, "conversation row\n");
    try seedFeed(held.screen, "LATEST ROW\n");
    try held.settle();
    for (0..16) |_| try held.keys("\x1b[5~");
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
        held.self.failedRetryForTest();
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
    for ([_][]const u8{ "/discard", "/archive", "/requests" }) |text| {
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
            try std.testing.expectEqualStrings(if (case[0] == .not_started) "Not sent" else "! Decision not confirmed", try barShows(held));
            try std.testing.expectEqualStrings("ctrl+r retries original", self.chrome.status.key.label);
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
    try stepKeys(held, "\x15/rel\r");
    try std.testing.expectEqualStrings("! Unknown command /rel", try barShows(held));
    // Drawn: Enter takes the highlighted /reload-skills, through its existing conversation action.
    try stepKeys(held, "/rel");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\r");
    try std.testing.expect(!std.mem.startsWith(u8, try barShows(held), "! Unknown command"));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
}

test "a key on a draft changed since the latest frame acts on that draft's list when the frame drew one" {
    {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try held.settle();
        // The frame drew `/re`; `n` changes the draft before any frame lists
        // it, and Enter takes /reload-skills from the current `/rel` list.
        try stepKeys(held, "/re");
        try held.settle();
        try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
        try stepKeys(held, "l\r");
        try std.testing.expect(!std.mem.startsWith(u8, try barShows(held), "! Unknown command"));
        try std.testing.expectEqualStrings("", self.input.composition().bytes);
    }
    // A separate fixture keeps the command outcome out of list-only assertions.
    const held = try HeldFrontend.create();
    defer held.destroy();
    // Down on `/r`, typed after the frame drew `/`'s list, moves the
    // highlight to `/r`'s second row, which the next frame keeps.
    try stepKeys(held, "/");
    try held.settle();
    try stepKeys(held, "r\x1b[B");
    try std.testing.expectEqual(@as(usize, 0), held.screen.commands.?.highlight);
    try held.settle();
    try std.testing.expectEqualStrings("r", held.screen.commands.?.list.typed);
    try std.testing.expectEqual(@as(usize, 0), held.screen.commands.?.highlight);
    // Esc on `/re`, typed after the frame drew `/r`'s list, cancels the command.
    try stepKeys(held, "e\x07");
    try std.testing.expectEqualStrings("", try barShows(held));
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try held.settle();
    try std.testing.expect(held.screen.commands == null);
}

test "Tab completes from the draft's own list, however many keys arrive before a frame" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    try stepKeys(held, "/rel\t");
    try std.testing.expectEqualStrings("/reload-skills", self.input.composition().bytes);
    // Two Tabs in one batch: the second completes from the list the first
    // one's word calls for.
    try stepKeys(held, "\x15/rel\t\t");
    try std.testing.expectEqualStrings("/reload-skills", self.input.composition().bytes);
}

test "a key before a new Session's first frame finds no list the previous Session drew" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    try stepKeys(held, "/r");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    // The next Session's input starts over; no frame of it drew a list, so
    // Enter runs `/rel` as typed, and Tab still completes.
    self.startInput();
    try stepKeys(held, "/rel\r");
    try std.testing.expectEqualStrings("! Unknown command /rel", try barShows(held));
    try stepKeys(held, "/rel\t");
    try std.testing.expectEqualStrings("/reload-skills", self.input.composition().bytes);
}

test "Esc closes the command list first only when the latest frame drew it" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.settle();
    held.self.line.read = .{ .revision = 1, .end = 1 };
    try held.self.line.model.set("gpt-6.1-sol");
    // The first Esc consumes a drawn command; it does not leave the chat.
    try stepKeys(held, "/rel");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try std.testing.expect(held.self.leaving == null);
    try std.testing.expect((try barShows(held)).len == 0);
    try held.settle();
    try std.testing.expect(held.screen.commands == null);
    // A command the latest frame did not list is not cancelled by Esc.
    try stepKeys(held, "/st\x07");
    try std.testing.expectEqualStrings("/st", held.self.input.composition().bytes);
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
    try held.screen.showFile(std.testing.io, page, .inspection);
    self.inspection.kind = .requests;
    self.dirty = true;
    try held.settle();
    const drawn = held.screen.commands.?;
    try std.testing.expectEqual(.drawn, drawn.seen);
    // The original has its /recover row only, not a /result row too.
    try std.testing.expectEqual(@as(usize, 3), drawn.list.count);
    try std.testing.expectEqualStrings("/recover " ++ original, drawn.list.entries[0].shown);
    try std.testing.expectEqualStrings("" ++ newer, drawn.list.entries[1].shown);
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
    try std.testing.expectEqualStrings(older, self.input.takeCommand().?);
    try std.testing.expectEqual(.result, self.queued_inspection.?);
    self.queued_inspection = null;
    held.screen.commands = null;
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
    try std.testing.expectEqualStrings("" ++ original, held.screen.commands.?.list.entries[0].word);
    // Tab puts the highlighted row's line in the draft, for editing.
    try held.keys("\x1b[B\t");
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    try std.testing.expectEqualStrings(newer, self.input.queuedCommand().?);
    _ = self.input.takeCommand();
    self.queued_inspection = null;
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
        try held.screen.showFile(std.testing.io, page, .inspection);
        self.inspection.kind = .requests;
        self.dirty = true;
        try held.settle();
        const drawn = held.screen.commands.?;
        try std.testing.expectEqual(@as(usize, 1), drawn.list.count);
        try std.testing.expectEqualStrings("" ++ newer, drawn.list.entries[0].word);
        try held.keys("\r");
        try std.testing.expect(self.submission.retry == null);
        try std.testing.expectEqualStrings("" ++ newer, self.input.takeCommand().?);
        self.submission.intent = null;
    }
}

test "Enter on a rejected draft clears it even while a skill list shows" {
    const Fake = struct {
        fn read(_: client.ReadContext, gpa: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !skill_suggestions.Page {
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

test "End on an empty draft stays at latest and never leaves the conversation" {
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
    self.files = .{ .scratch = scratch, .action = action, .inspection = inspection, .details = inspection, .actions = .{ inspection, inspection } };
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
        self.failedRetryForTest();
        self.submission.intent = .{ .message = self.input.submitText("unconfirmed original") };
        self.submission.state = .unconfirmed;
        self.submission.key = "01234567-89ab-4cde-8012-0123456789ab".*;
        try held.keys(case.bytes);
        try std.testing.expectEqual(case.recovery, self.submission.retry != null);
        try std.testing.expect(self.retry_fence == null);
    }
}

/// An overview that lent the terminal and says nothing under its input.
const quiet_overview: Lender = .{ .context = undefined, .step = struct {
    fn step(_: *anyopaque, _: protocol.session_work.Kind, _: overview_view.ConversationInput) !overview_view.ArchiveAdmission {
        return .refused;
    }
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

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !overview_view.ArchiveAdmission {
        const fake: *FakeOverview = @ptrCast(@alignCast(raw));
        fake.notice = null;
        if (input != .stop) return .refused;
        if (fake.stopping or work != .working) {
            fake.notice = "unused: Stopping";
        } else {
            fake.stops += 1;
            fake.stopping = true;
        }
        return .refused;
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
    try std.testing.expect(try rowWith(held, "Session is opening.") != null);
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

/// A scan hands the panel the same owned Session capture as the chat line.
fn captureInfo(held: *HeldFrontend, label: []const u8) !void {
    const self = &held.self;
    const session = &self.inspection.sessions[if (self.inspection.status) |shown| ~shown else 0];
    status_page.sample(session);
    session.tools.remove(.web_search);
    try session.model.set("gpt-5.5");
    try session.label.set(label);
    self.job.status_taken = session;
    self.job.result.status = true;
    try self.applyStatus();
    self.poll_at = std.math.maxInt(i96);
}

test "chat info opens from the chat line above the input at 140 and 46 columns and Escape closes only the top choice" {
    for ([_]u16{ 140, 46 }) |width| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.size = .{ .width = width, .height = 36 };
        try seedFeed(held.screen, "feed stays here\n");
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1b[D\x1b[D");
        const before = held.self.input.composition();
        const cursor = before.cursor;
        try held.keys("\x1bi");
        try std.testing.expect(held.self.info_open and held.self.inspection.status_requested);
        try std.testing.expectEqual(Screen.ViewKind.feed, held.screen.view);
        const surface = try held.draw();
        // Layer's panel is independent of the feed, immediately above input.
        try std.testing.expectEqual(@as(usize, 2), surface.children.len);
        const base = surface.children[0].surface;
        const panel = surface.children[1];
        try std.testing.expectEqual(@as(u8, 2), panel.z_index);
        try std.testing.expectEqual(base.children[base.children.len - 1].origin.row, panel.origin.row + panel.surface.size.height);
        try std.testing.expect((try rowWith(held, "Fix retry deadline")) != null);
        try std.testing.expect((try rowWith(held, "Folder")) != null);
        try std.testing.expect((try rowWith(held, "alt+i info")) == null);
        try std.testing.expect((try rowWith(held, "esc close")) != null);
        try held.keys("\r");
        try std.testing.expect(held.self.app_info.hasChoice());
        try held.keys("\x07");
        try std.testing.expect(held.self.info_open and !held.self.app_info.hasChoice());
        // The read-only Folder is skipped; Model opens the shared choice.
        try held.keys("\x1b[B\x1b[B\x1b[B\r");
        try std.testing.expect(held.self.app_info.model_choice.active);
        try std.testing.expect((try rowWith(held, "gpt-5.5")) != null);
        try held.keys("\x07\x07");
        try std.testing.expect(!held.self.info_open and held.left == null);
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
        try std.testing.expectEqual(cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(Screen.ViewKind.feed, held.screen.view);
    }
}

test "chat identity click and Alt-I share natural panel opening and Escape restores the feed" {
    for ([_]u16{ 46, 140 }) |width| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.size = .{ .width = width, .height = 40 };
        try seedFeed(held.screen, "earlier feed line\nlatest feed line\n");
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1b[D");
        const cursor = held.self.input.composition().cursor;
        const ordinary = try held.draw();
        const input = ordinary.children[0].surface.children[1];
        const facts = input.surface.children[1];
        // The displayed name begins after the gutter/back control; locate it
        // independently of whether the implementation installed a hit target.
        const col: i16 = if (held.self.chrome.list_visible) 1 else 3;
        const row: i16 = @intCast(input.origin.row + facts.origin.row);
        var ctx = held.context();
        defer ctx.cmds.deinit(held.arena.allocator());
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, ordinary, .{ .row = row, .col = col, .button = .left, .mods = .{}, .type = kind });
        try std.testing.expect(held.self.info_open and held.self.inspection.status_requested);
        const clicked = try held.draw();
        const panel = clicked.children[1];
        const base = clicked.children[0].surface;
        const draft = base.children[base.children.len - 1];
        try std.testing.expect(panel.origin.row > 0);
        try std.testing.expectEqual(base.children[0].surface.size.height, panel.origin.row);
        try std.testing.expectEqual(draft.origin.row, panel.origin.row + panel.surface.size.height);
        try std.testing.expect((try rowWith(held, "latest feed line")) != null);
        // The open panel's footer cannot toggle or reset its owner.
        const footer_row: i16 = @intCast(draft.origin.row + draft.surface.children[1].origin.row);
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, clicked, .{ .row = footer_row, .col = col, .button = .left, .mods = .{}, .type = kind });
        try std.testing.expect(held.self.info_open and !held.self.app_info.hasChoice());
        try std.testing.expectEqual(@as(usize, 0), held.self.app_info.panel.selected);
        try held.keys("\x1b");
        try std.testing.expect(!held.self.info_open and held.left == null);
        try held.keys("\x1bi");
        const keyed = try held.draw();
        try std.testing.expect(held.self.info_open);
        try std.testing.expectEqual(panel.origin, keyed.children[1].origin);
        try std.testing.expectEqual(panel.surface.size, keyed.children[1].surface.size);
        try held.keys("\x1b");
        try std.testing.expect(!held.self.info_open and held.left == null);
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
        try std.testing.expectEqual(cursor, held.self.input.composition().cursor);
        try std.testing.expect((try rowWith(held, "latest feed line")) != null);
    }
}

test "chat info owns typed keys before Host restart across every modal editor and choice" {
    const Host = struct {
        stopped: bool,
        starts: usize = 0,
        fn held(raw: *anyopaque) bool {
            return @as(*@This(), @ptrCast(@alignCast(raw))).stopped;
        }
        fn lost(_: *anyopaque) void {
            @panic("modal input must not touch Host custody");
        }
        fn start(raw: *anyopaque, _: *vxfw.EventContext) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
            return self.stopped;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
    };
    const Mode = enum { rows, effort, permissions, tools, rename, model };
    for ([_]bool{ false, true }) |stopped| for ([_]bool{ false, true }) |draft| for (std.enums.values(Mode)) |mode| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        try captureInfo(held, "Before");
        if (draft) try held.keys("kept draft");
        var host: Host = .{ .stopped = stopped };
        held.self.app_hooks.host = .{ .context = &host, .held = Host.held, .lost = Host.lost, .start = Host.start, .notice = Host.notice };
        defer held.self.app_hooks.host = null;
        try held.keys("\x1bi");
        const page = &held.self.app_info;
        page.panel.selected = switch (mode) {
            .rows, .effort => 0,
            .permissions => 1,
            .tools => 2,
            .model => 4,
            .rename => 6,
        };
        if (mode != .rows) try held.keys("\r");
        const selected = page.panel.selected;
        // Each successive query is listed (terra), so refusal rollback is
        // independent of the routing boundary under test.
        for ("rra") |key| {
            try held.keys(&.{key});
            try std.testing.expectEqual(@as(usize, 0), host.starts);
            try std.testing.expectEqual(stopped, host.stopped);
            try std.testing.expect(held.self.info_open and held.left == null);
            try std.testing.expect(held.self.submission.intent == null and held.self.info_edit == null);
            try std.testing.expectEqual(selected, page.panel.selected);
            try std.testing.expectEqualStrings(if (draft) "kept draft" else "", held.self.input.composition().bytes);
        }
        switch (mode) {
            .rename => {
                try std.testing.expect(page.renaming);
                try std.testing.expectEqualStrings("Beforerra", page.rename_editor.buffer[0..page.rename_editor.length]);
            },
            .model => {
                try std.testing.expect(page.model_choice.active);
                try std.testing.expectEqualStrings("rra", page.model_choice.editor.buffer[0..page.model_choice.editor.length]);
            },
            .rows => try std.testing.expect(!page.hasChoice()),
            .effort, .permissions, .tools => try std.testing.expect(page.panel.choice != null),
        }
        // Once the panel is closed, only an empty composer delegates r to Host.
        page.cancelChoice();
        try held.keys("\x1b");
        try held.keys("r");
        try std.testing.expectEqual(@as(usize, @intFromBool(!draft)), host.starts);
        try std.testing.expectEqualStrings(if (draft) "kept draftr" else if (stopped) "" else "r", held.self.input.composition().bytes);
    };
}

test "chat info inspection refresh preserves a choice and late captures never reopen a closed panel" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try captureInfo(held, "Before");
    try held.keys("\x1bi\r");
    try captureInfo(held, "After");
    try std.testing.expect(held.self.app_info.hasChoice());
    try held.keys("\x07\x07");
    try captureInfo(held, "Late");
    try std.testing.expect(!held.self.info_open);
    try held.keys("\x1bi");
    try std.testing.expect((try rowWith(held, "Late")) != null);
}

test "chat info saves typed edits without touching the draft and reports refusal on the field" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try captureInfo(held, "Fix retry deadline");
    try held.keys("kept draft\x1bi\x1b[B\r\x1b[B\r");
    try std.testing.expectEqual(ChatInfo.Edit{ .permission = .ask }, held.self.info_edit.?);
    try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
    try std.testing.expect(held.self.input.queuedCommand() == null);
    // The typed effect stays pending after closing, then lands on a fresh read.
    try held.keys("\x07");
    try std.testing.expect(!held.self.info_open);
    held.self.info_edit = null;
    held.self.info_effect = .refreshing;
    try captureInfo(held, "Renamed");
    var ctx = held.context();
    try held.self.app_info.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(held.self.app_info.pending == null);
    try held.keys("\x1bi");
    held.self.inspection.command_running = true;
    try held.keys("\r\r");
    try std.testing.expect((try rowWith(held, "couldn't save")) != null);
    try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
    held.self.inspection.command_running = false;
}

test "app settings starts the overview's run and keeps the original submission; Esc is the run's" {
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
    // App settings can start a new run after an earlier one blocked requests.
    for ([_]session_upgrade.After{ .open, .blocked }) |after| {
        overview.state.upgrade = .{ .after = after };
        _ = try overview_view.step(&overview.state, .start_upgrade);
        try std.testing.expect(overview.state.upgrade.run.? == .checking);
        try std.testing.expectEqualStrings("", self.input.composition().bytes);
        try std.testing.expect(self.input.queuedCommand() == null);
        try std.testing.expectEqual(session_upgrade.Phase.quiescing, self.upgradePhase());
        try std.testing.expectEqualStrings("Checking for updates…", self.lender.line(self.lender.context, .idle).text.?);
        // Another Version-row activation changes nothing, and Esc asks the run to stop
        // before it does anything else.
        _ = try overview_view.step(&overview.state, .start_upgrade);
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

test "app settings Upgrade admission includes pending typed chat edits and commands" {
    for ([_]bool{ false, true }) |typed| for ([_]bool{ false, true }) |command| for ([_]bool{ false, true }) |running| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try held.keys("kept draft");
        if (typed) self.info_edit = .{ .permission = .ask };
        if (command) self.input.queueCommand("/requests");
        self.inspection.command_running = running;
        try std.testing.expectEqual(!typed and !command and !running, self.admitsUpgrade());
        // Admission is a pure decision: refused work remains with its owner.
        try std.testing.expectEqual(typed, self.info_edit != null);
        try std.testing.expectEqual(command, self.input.queuedCommand() != null);
        try std.testing.expectEqual(running, self.inspection.command_running);
        try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
        self.info_edit = null;
        self.inspection.command_running = false;
    };
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

test "an Upgrade hold refuses commands without losing their drafts" {
    const lines = [_][]const u8{ "/requests", "/copy", "/effort low", "/setup" };

    for (lines) |line| {
        errdefer std.debug.print("line={s}\n", .{line});
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        const self = &held.self;
        _ = try overview_view.step(&overview.state, .start_upgrade);
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

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !overview_view.ArchiveAdmission {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        switch (input) {
            .other, .cancel_upgrade, .upgrade_failed => {},
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
        return effects.archive_admission;
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

    fn command(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, _: reads.CommandInput) !void {
        calls += 1;
        return error.TestUnexpectedCommand;
    }
};

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

test "a card taller than the screen stays scrollable without instruction lines" {
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
        try std.testing.expect(std.mem.indexOf(u8, shown, "more lines · shift+↓") == null);
        if (hidden == 0) {
            try std.testing.expect(std.mem.indexOf(u8, shown, "more lines") == null);
            try std.testing.expect(press > 0);
            break;
        }
        try std.testing.expect(std.mem.indexOf(u8, shown, " Allow once ") != null);
        try stepKeys(held, "\x1b[1;2B");
        try held.settle();
    } else return error.TestUnexpectedResult;
}

test "reader failure provenance keeps transport loss separate from local copy failures, reachable or held" {
    const Probe = struct {
        const Mode = enum { read_disconnect, copy_disconnect, command_disconnect, sink };
        var mode: Mode = undefined;
        var local_effects: usize = 0;
        fn write(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            if (mode == .sink) {
                local_effects += 1;
                return error.BrokenPipe;
            }
            return std.testing.io.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
        }
        fn command(_: std.process.Init, read: client.ReadContext, store: []const u8, session: []const u8, _: reads.CommandInput) !void {
            const requests = read.requests();
            try std.testing.expect(requests.cancellation != null);
            _ = try requests.activityPage(store, session, .{});
            return error.TestUnexpectedResult;
        }
    };
    const Peer = struct {
        mode: Probe.Mode,
        listener: *std.Io.net.Server,
        stopping: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = {},
        pages: usize = 0,
        contents: usize = 0,
        const answer = "answer";
        fn run(self: *@This()) void {
            self.result = self.serve();
        }
        fn request(self: *@This(), route: []const u8) !std.Io.net.Stream {
            const stream = try self.listener.accept(std.testing.io);
            errdefer stream.close(std.testing.io);
            if (self.stopping.load(.acquire)) return error.Cancelled;
            var bytes: [4096]u8 = undefined;
            var used: usize = 0;
            while (true) {
                const count = try std.posix.read(stream.socket.handle, bytes[used..]);
                if (count == 0) return error.UnexpectedEof;
                used += count;
                if (std.mem.indexOf(u8, bytes[0..used], "\r\n\r\n")) |end| {
                    const start = std.mem.indexOf(u8, bytes[0..end], "Content-Length: ").? + "Content-Length: ".len;
                    const finish = std.mem.indexOf(u8, bytes[start..end], "\r\n").? + start;
                    if (used == end + 4 + try std.fmt.parseInt(usize, bytes[start..finish], 10)) break;
                }
            }
            var prefix: [96]u8 = undefined;
            try std.testing.expectStringStartsWith(bytes[0..used], try std.fmt.bufPrint(&prefix, "POST {s} HTTP/1.1\r\n", .{route}));
            return stream;
        }
        fn reply(stream: std.Io.net.Stream, content_type: []const u8, length: usize, extra: []const u8, body: []const u8) !void {
            var header: [512]u8 = undefined;
            var writer = stream.writer(std.testing.io, &.{});
            try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Connection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ content_type, length, extra }));
            try writer.interface.writeAll(body);
        }
        fn serve(self: *@This()) !void {
            {
                const page = try self.request(if (self.mode == .read_disconnect or self.mode == .command_disconnect) "/v1/activity-page" else "/v1/conversation-page");
                defer page.close(std.testing.io);
                self.pages += 1;
                if (self.mode == .read_disconnect or self.mode == .command_disconnect) return; // Physical EOF, no response.
                var bytes: [1024]u8 = undefined;
                var body = std.Io.Writer.fixed(&bytes);
                const shape = protocol.conversation_page_reply;
                try protocol.writeShape(&body, shape.head, .{1});
                try protocol.writeShape(&body, shape.item(.assistant), .{ 1, 0, answer.len, protocol.contentDigest(answer) });
                try protocol.writeShape(&body, shape.item_end ++ shape.last, .{});
                try reply(page, "application/json", body.buffered().len, "", body.buffered());
            }
            const content = try self.request("/v1/conversation-content");
            defer content.close(std.testing.io);
            self.contents += 1;
            var extra: [128]u8 = undefined;
            try reply(content, "application/octet-stream", answer.len, try std.fmt.bufPrint(&extra, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ answer.len, answer.len }), if (self.mode == .copy_disconnect) answer[0..1] else answer);
        }
    };
    const Discovery = struct {
        unavailable: bool = false,
        losses: usize = 0,
        fn held(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.unavailable;
        }
        fn lost(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.unavailable = true;
            self.losses += 1;
        }
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return error.TestUnexpectedResult;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
    };
    const io = std.testing.io;
    for (std.enums.values(Probe.Mode)) |mode| for ([_]bool{ false, true }) |already_unavailable| {
        errdefer std.debug.print("mode={s}, already unavailable={}\n", .{ @tagName(mode), already_unavailable });
        Probe.mode = mode;
        Probe.local_effects = 0;
        var fixture: ChromeFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const self = fixture.self;
        var tmp = try @import("socket_fixture.zig").Directory.init();
        defer tmp.cleanup();
        const root = tmp.root[0..tmp.root_len];
        var lease: ?@import("platform.zig").StoreLease = try .acquire(io, root);
        defer if (lease) |*held| held.release();
        try lease.?.prepareForServing(false);
        const paths = lease.?.paths;
        var listener: ?std.Io.net.Server = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).listen(io, .{});
        defer if (listener) |*server| {
            server.deinit(io);
            std.Io.Dir.cwd().deleteFile(io, paths.socket.slice()) catch @panic("unable to remove fixture socket");
        };
        var peer: Peer = .{ .mode = mode, .listener = if (listener) |*server| server else undefined };
        const thread: ?std.Thread = if (listener != null) try std.Thread.spawn(.{}, Peer.run, .{&peer}) else null;
        var joined = false;
        defer if (!joined and thread != null) {
            peer.stopping.store(true, .release);
            if ((std.Io.net.UnixAddress.init(paths.socket.slice()) catch unreachable).connect(io)) |wake| wake.close(io) else |_| {}
            thread.?.join();
        };
        var vtable = io.vtable.*;
        vtable.fileWritePositional = Probe.write;
        self.init.io = .{ .userdata = io.userdata, .vtable = &vtable };
        self.store = root;
        self.live.scan.cursor = .{ .position = 19 };
        self.reading.opening = mode == .read_disconnect;
        _ = self.input.replace(.{ .start = 0, .end = 0, .text = "kept draft" });
        var discovery: Discovery = .{};
        self.app_hooks.host = .{ .context = &discovery, .held = Discovery.held, .lost = Discovery.lost, .start = Discovery.start, .notice = Discovery.notice };
        self.command = Probe.command;
        self.inspection.kind = if (mode == .command_disconnect) .command else .copy;
        const job = self.freeze(if (mode == .read_disconnect) .activity else .inspection);
        try self.launch(job, if (mode == .read_disconnect) reads.scan else if (mode == .command_disconnect) reads.runCommand else reads.copyAnswer);
        // An independent discovery change while this job is in flight must
        // not change where its own error came from or suppress a local notice.
        discovery.unavailable = already_unavailable;
        try self.settleReader();
        if (thread) |worker| worker.join();
        joined = true;
        try peer.result;
        const transport = mode == .read_disconnect or mode == .copy_disconnect or mode == .command_disconnect;
        try std.testing.expectEqual(if (transport) client.FailureOrigin.host_transport else .local, self.reader.result.failure_origin);
        try std.testing.expectError(if (transport) error.TruncatedResponse else if (mode == .sink) error.BrokenPipe else error.FileNotFound, self.reader.result.outcome.?);
        try std.testing.expectEqual(@as(usize, @intFromBool(transport)), discovery.losses);
        try std.testing.expectEqual(already_unavailable or transport, self.hostHeld());
        try std.testing.expectEqual(@as(usize, @intFromBool(!transport)), Probe.local_effects);
        try std.testing.expectEqual(@as(usize, 1), peer.pages);
        try std.testing.expectEqual(@as(usize, @intFromBool(mode != .read_disconnect and mode != .command_disconnect)), peer.contents);
        try std.testing.expect(self.reader.thread == null and self.leaving == null);
        try std.testing.expectEqual(mode == .read_disconnect, self.reading.opening);
        try std.testing.expectEqual(@as(u64, 19), self.live.scan.cursor.?.position);
        try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
        if (transport) {
            try std.testing.expect(self.notice == null);
        } else {
            try std.testing.expectEqualStrings("! Copy unavailable; draft retained.", self.notice.?);
            try self.afterInput(&fixture.ctx);
            const rows = try fixture.rows();
            for (rows) |line| {
                if (std.mem.indexOf(u8, line, "Copy unavailable; draft retained.") != null) break;
            } else {
                for (rows) |line| std.debug.print("{s}\n", .{line});
                return error.TestUnexpectedResult;
            }
        }
    };
}

test "required read adapter contexts cannot omit provenance" {
    inline for (.{ Command, Requests, SkillRead }, .{ 1, 1, 0 }) |Callback, index| {
        const signature = @typeInfo(@typeInfo(Callback).pointer.child).@"fn";
        try std.testing.expect(signature.param_types[index].? == client.ReadContext);
    }
    const context = @typeInfo(client.ReadContext).@"struct";
    inline for (context.field_names, context.field_types, context.field_attrs) |name, Type, attrs| {
        if (comptime std.mem.eql(u8, name, "origin")) {
            try std.testing.expect(Type == *client.FailureOrigin);
            try std.testing.expect(attrs.default_value_ptr == null);
        }
    }
}

test "skills transport recovery retains the held page and retries the same prefix after reobservation" {
    const Discovery = struct {
        unavailable: bool = false,
        losses: usize = 0,
        fn held(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.unavailable;
        }
        fn lost(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.losses += 1;
            self.unavailable = true;
        }
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return false;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
        fn completed(task: *Task) bool {
            return task.completed();
        }
    };
    const Peer = struct {
        listener: *std.Io.net.Server,
        stopping: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.serve();
        }
        fn serve(self: *@This()) !void {
            const stream = try self.listener.accept(std.testing.io);
            defer stream.close(std.testing.io);
            if (self.stopping.load(.acquire)) return error.Cancelled;
            var bytes: [4096]u8 = undefined;
            var used: usize = 0;
            while (true) {
                const count = try std.posix.read(stream.socket.handle, bytes[used..]);
                if (count == 0) return error.UnexpectedEof;
                used += count;
                if (std.mem.indexOf(u8, bytes[0..used], "\r\n\r\n")) |end| {
                    const start = std.mem.indexOf(u8, bytes[0..end], "Content-Length: ").? + "Content-Length: ".len;
                    const finish = std.mem.indexOf(u8, bytes[start..end], "\r\n").? + start;
                    if (used == end + 4 + try std.fmt.parseInt(usize, bytes[start..finish], 10)) break;
                }
            }
            try std.testing.expectStringStartsWith(bytes[0..used], "POST /v1/skill-suggestions HTTP/1.1\r\n");
            try std.testing.expect(std.mem.indexOf(u8, bytes[0..used], "\"prefix\":\"re\"") != null);
            const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"skill_suggestions\",\"revision\":\"2\",\"total\":\"1\",\"entries\":[{\"name\":\"recap\",\"description\":\"Summarise\"}]}";
            var header: [256]u8 = undefined;
            var out = stream.writer(std.testing.io, &.{});
            try out.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{body.len}));
            try out.interface.writeAll(body);
        }
    };
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    defer if (self.dropSkills()) |err| std.debug.panic("skills cleanup failed: {}", .{err});
    const io = std.testing.io;
    var directory = try @import("socket_fixture.zig").Directory.init();
    defer directory.cleanup();
    const root = directory.root[0..directory.root_len];
    var lease = try @import("platform.zig").StoreLease.acquire(io, root);
    defer lease.release();
    try lease.prepareForServing(false);
    self.store = root;
    var discovery: Discovery = .{};
    self.app_hooks.host = .{ .context = &discovery, .held = Discovery.held, .lost = Discovery.lost, .start = Discovery.start, .notice = Discovery.notice };
    const old = self.skills.ask("old").?;
    try std.testing.expect(self.skills.answer(old.read, .{}, "old") == null);
    _ = self.input.replace(.{ .start = 0, .end = 0, .text = "please /re" });
    try self.serviceSkills();
    const first = self.skill_job.read;
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &self.skill_task, Discovery.completed);
    try self.serviceSkills();
    try std.testing.expectError(error.FileNotFound, self.skill_task.result.outcome.?);
    try std.testing.expectEqual(client.FailureOrigin.host_transport, self.skill_task.result.failure_origin);
    try std.testing.expectEqual(@as(usize, 1), discovery.losses);
    try std.testing.expect(self.skill_task.thread == null and self.skills.failed == null and self.skills.pending == null);
    try std.testing.expectEqual(old.read, self.skills.held.?.read);
    try self.serviceSkills();
    try std.testing.expectEqual(first, self.skill_job.read); // No automatic attempt while held.
    var listener = try (try std.Io.net.UnixAddress.init(lease.paths.socket.slice())).listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, lease.paths.socket.slice()) catch @panic("unable to remove fixture socket");
    }
    var peer: Peer = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
    var joined = false;
    defer if (!joined) {
        peer.stopping.store(true, .release);
        if ((std.Io.net.UnixAddress.init(lease.paths.socket.slice()) catch unreachable).connect(io)) |wake| wake.close(io) else |_| {}
        thread.join();
    };
    defer self.stop();
    discovery.unavailable = false; // A fresh shell observation permits reads again.
    try self.serviceSkills();
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &self.skill_task, Discovery.completed);
    try self.serviceSkills();
    thread.join();
    joined = true;
    try peer.result;
    try std.testing.expect(self.skill_job.read > first);
    try std.testing.expectEqual(client.FailureOrigin.local, self.skill_task.result.failure_origin);
    try std.testing.expectEqual(@as(usize, 1), discovery.losses);
    try std.testing.expectEqualStrings("recap", self.skills.held.?.page.entries[0].name);
    try std.testing.expectEqualStrings("please /re", self.input.composition().bytes);
    try std.testing.expect(self.skill_task.thread == null and self.leaving == null);
}

test "Host recovery joins unavailable reads in every phase without losing the Session" {
    const Fault = struct {
        failure: anyerror,
        origin: client.FailureOrigin = .local,
        lost: usize = 0,
        fenced: bool = false,
        fn run(raw: *anyopaque, task: *Task) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fenced) {
                var failure: protocol_reply.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
                try failure.diagnostic.type.set("busy");
                try failure.diagnostic.code.set("dispatch_fenced");
                return task.requests().failRead(failure);
            }
            task.result.failure_origin = self.origin;
            return self.failure;
        }
        fn held(_: *anyopaque) bool {
            return false;
        }
        fn lose(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.lost += 1;
        }
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return false;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
    };
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    _ = self.input.replace(.{ .start = 0, .end = 0, .text = "kept draft" });
    for (std.enums.values(ReadPhase)) |phase| {
        for ([_]anyerror{ error.FileNotFound, error.ConnectionRefused, error.UnixConnectFailed, error.ConnectionResetByPeer, error.BrokenPipe, error.TruncatedResponse, error.ResponseInactive, error.HostNotServing, error.HostStopping }) |failure| {
            var fault: Fault = .{ .failure = failure, .origin = .host_transport };
            self.app_hooks.host = .{ .context = &fault, .held = Fault.held, .lost = Fault.lose, .start = Fault.start, .notice = Fault.notice };
            self.reading.phase = phase;
            self.reading.opening = true;
            self.inspection.command_running = phase == .inspection;
            try self.reader.start(std.testing.io, &fault, Fault.run);
            try self.settleReader();
            try std.testing.expectEqual(@as(usize, 1), fault.lost);
            try std.testing.expect(self.reader.thread == null);
            try std.testing.expect(self.reading.opening);
            try std.testing.expect(self.reading.pending_diagnostic == null);
            try std.testing.expect(self.leaving == null);
            try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
        }
    }
    {
        // A tool output read in flight when the Host goes settles its
        // request: the same row opens again once the Host is back.
        const key: feed_window.Key = .{ .position = 41, .ordinal = 1 };
        var fault: Fault = .{ .failure = error.ConnectionRefused, .origin = .host_transport };
        self.app_hooks.host = .{ .context = &fault, .held = Fault.held, .lost = Fault.lose, .start = Fault.start, .notice = Fault.notice };
        self.reading.opening = false;
        for (0..2) |round| {
            self.expansion.reading = .{ .target = .{ .tool = .{ .key = key, .open = true } }, .asked = self.pageAsked() };
            self.reading.phase = .tool;
            try self.reader.start(std.testing.io, &fault, Fault.run);
            try self.settleReader();
            try std.testing.expectEqual(round + 1, fault.lost);
            try std.testing.expect(self.expansion.reading == null);
            try std.testing.expect(!fixture.screen.feed.opened.has(key));
        }
    }
    var fenced: Fault = .{ .failure = error.HostInvocationFailed, .fenced = true };
    self.app_hooks.host = .{ .context = &fenced, .held = Fault.held, .lost = Fault.lose, .start = Fault.start, .notice = Fault.notice };
    self.reading.phase = .activity;
    try self.reader.start(std.testing.io, &fenced, Fault.run);
    try self.settleReader();
    try std.testing.expectEqual(@as(usize, 1), fenced.lost);
    try std.testing.expect(self.reading.pending_diagnostic == null);
    // Cancellation wins even if earlier work on this invocation touched transport.
    var cancelled: Fault = .{ .failure = error.Cancelled, .origin = .host_transport };
    self.app_hooks.host = .{ .context = &cancelled, .held = Fault.held, .lost = Fault.lose, .start = Fault.start, .notice = Fault.notice };
    self.reading.phase = .activity;
    try self.reader.start(std.testing.io, &cancelled, Fault.run);
    try std.testing.expectError(error.Cancelled, self.settleReader());
    try std.testing.expectEqual(@as(usize, 0), cancelled.lost);
    // A canonical or unrelated failure still has its original fatal boundary.
    for ([_]anyerror{ error.CanonicalStoreFailure, error.AccessDenied }) |failure| {
        var fault: Fault = .{ .failure = failure };
        self.app_hooks.host = .{ .context = &fault, .held = Fault.held, .lost = Fault.lose, .start = Fault.start, .notice = Fault.notice };
        self.reading.phase = .activity;
        try self.reader.start(std.testing.io, &fault, Fault.run);
        try std.testing.expectError(failure, self.settleReader());
        try std.testing.expectEqual(@as(usize, 0), fault.lost);
    }
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
        fixture.self.begin(init_, "unused", "k7m2qx", "unused", .{ .scratch = page, .action = page, .inspection = page, .details = page, .actions = .{ page, page } }, undefined, undefined, undefined, fixture.screen, &fixture.interrupted, lender);
        fixture.root = .{ .overview = empty_app_text.widget(), .list = empty_app_text.widget(), .compose = empty_app_text.widget() };
        fixture.widget = fixture.self.attach(.{ .root = &fixture.root, .context = fixture.self, .leave = Hooks.leave, .copy = Hooks.copy, .on_open = Hooks.open }, .{ .depth = .none });
        fixture.self.reading.opening = false;
        fixture.screen.feed.at_end = true;
        fixture.screen.feed.at_start = true;
        fixture.self.poll_at = std.math.maxInt(i96);
        fixture.arena = .init(std.testing.allocator);
        fixture.ctx = .{ .io = std.testing.io, .alloc = fixture.arena.allocator(), .cmds = .empty };
        var history: [100 * 20]u8 = undefined;
        var writer = std.Io.Writer.fixed(&history);
        for (0..100) |number| try writer.print("History line {d:0>3}\n", .{number});
        try seedFeed(fixture.screen, writer.buffered());
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

test "App Session shell gutter and back control follow list visibility through resize" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.line = .{ .read = .{ .revision = 1, .end = 1 }, .effort = .low, .left = 100, .label = .{} };
    try self.line.label.?.set("demo");
    try self.line.model.set("gpt-5.5");
    _ = self.input.replace(.{ .start = 0, .end = 0, .text = "kept draft" });
    try seedFeed(fixture.screen, "› Build the docs…\n✓ Build the docs\n");
    const anchor = fixture.screen.anchor;
    try fixture.root.openSession(&fixture.ctx, fixture.widget);
    const arena = fixture.arena.allocator();
    for ([_]u16{ 140, 46, 100, 99, 140, 46 }) |width| {
        const frame = try fixture.root.widget().draw(.{ .arena = arena, .min = .{}, .max = .{ .width = width, .height = 26 }, .cell_size = .{} });
        var screen: vaxis.Screen = try .init(arena, .{ .cols = width, .rows = 26, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 26, .screen = &screen };
        frame.render(window, self.app_input.composer.widget());
        const wide = width >= 100;
        const start: u16 = if (wide) 41 else 0;
        try std.testing.expectEqual(wide, fixture.root.listVisible());
        if (wide) try std.testing.expectEqualStrings("│", screen.readCell(40, 0).?.char.grapheme);
        // Exactly one shell-owned feed gutter, both beside the divider and alone.
        var sent: u16 = 0;
        while (!std.mem.eql(u8, screen.readCell(start + 1, sent).?.char.grapheme, "›")) sent += 1;
        try std.testing.expectEqualStrings(" ", screen.readCell(start, sent).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(start, sent + 1).?.char.grapheme);
        try std.testing.expectEqualStrings("✓", screen.readCell(start + 1, sent + 1).?.char.grapheme);
        try std.testing.expectEqualStrings(if (wide) "d" else "‹", screen.readCell(start + 1, 24).?.char.grapheme);
        var facts: std.Io.Writer.Allocating = .init(arena);
        for (start..width) |column| try facts.writer.writeAll(screen.readCell(@intCast(column), 24).?.char.grapheme);
        try std.testing.expectEqualStrings(if (wide) " demo · gpt-5.5 · low · 100% left" else " ‹ demo · gpt-5.5 · low · 100% left", std.mem.trimEnd(u8, facts.written()[0..std.mem.indexOf(u8, facts.written(), "alt+i info").?], " "));
        try std.testing.expect(fixture.root.session.?.eql(fixture.widget));
        try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
        try std.testing.expectEqualDeep(anchor, fixture.screen.anchor);
    }
    // The inset must remain bounded even when there is no room for feed text.
    for ([_]vxfw.Size{ .{ .width = 0, .height = 0 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }, .{ .width = 1, .height = 26 } }) |size| {
        const frame = try fixture.root.widget().draw(.{ .arena = arena, .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expectEqual(size, frame.size);
    }
}

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
    const first = ChromeFixture.find(&shown, "⠹ Read src/overview_view.zig").?;
    try std.testing.expectEqualStrings("⠹ Run zig build test", shown[first + 1]);
    try std.testing.expectEqualStrings("⠹ Read docs/using-rui.md", shown[first + 2]);
    try std.testing.expectEqualStrings("+2 more running · info", shown[first + 3]);
    // No shown call carries the clock, so the work line follows, once.
    try std.testing.expect(std.mem.eql(u8, shown[first + 4], "⠹ Thinking · 12s") or std.mem.eql(u8, shown[first + 4], "⠹ Thinking · 13s"));
    // The chip always reserves a row between the tail and the input rule.
    try std.testing.expectEqualStrings("", shown[first + 5]);
    try std.testing.expect(std.mem.startsWith(u8, shown[first + 6], "─"));
    var waiting: usize = 0;
    for (shown) |line| waiting += @intFromBool(std.mem.startsWith(u8, line, "⠹ Thinking"));
    try std.testing.expectEqual(@as(usize, 1), waiting);
    // Work ends: the tail goes, and history reaches the rule again.
    self.live.view = .{};
    self.live.work.state = .{ .idle = .{ .since = 0 } };
    const idle = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&idle, "⠹") == null and ChromeFixture.find(&idle, "+") == null);
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
    try std.testing.expect(std.mem.startsWith(u8, three[row - 1], "⠹ Thinking"));
    try std.testing.expectEqualStrings("", three[row + 1]);
    try std.testing.expect(std.mem.startsWith(u8, three[row + 2], "─"));
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
    try std.testing.expect(ChromeFixture.find(&shown, "Sending…") != null);
    try std.testing.expectEqual(session_chrome.Tone.quiet, self.chrome.status.bar.tone);
}

test "App Session's status bar never says Sent: an accepted Message's row is its feedback, at the latest view and scrolled back" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    // Accepted with no original held: the bar is empty, so the overview's
    // line shows there.
    try std.testing.expect(std.mem.startsWith(u8, (try fixture.rows())[22], "‹ k7m2qx"));
    try std.testing.expect(std.mem.endsWith(u8, (try fixture.rows())[22], "alt+i info"));
    ChromeFixture.overview_says = "Port overview to vxfw finished";
    defer ChromeFixture.overview_says = null;
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Port overview to vxfw finished") != null);
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
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Opening…") != null);
    try fixture.press(.{ .codepoint = 'x', .mods = .{ .ctrl = true } });
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Session is opening.") != null);
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Opening…") != null);
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
    try std.testing.expect(std.mem.startsWith(u8, facts(&try fixture.rows()), "‹ k7m2qx"));
    self.line.archive_state = .archived;
    const archived = facts(&try fixture.rows());
    try std.testing.expect(std.mem.startsWith(u8, archived, "‹ k7m2qx · Archived"));
    try std.testing.expect(std.mem.endsWith(u8, archived, "Restore"));
    self.line.archive_state = .archiving;
    try std.testing.expect(std.mem.startsWith(u8, facts(&try fixture.rows()), "‹ k7m2qx · Stopping and archiving"));
    // A notice on the last row leaves the badge where it is.
    self.shown_notice.show("Copied 3 lines", ChromeFixture.now());
    const shown = try fixture.rows();
    try std.testing.expect(std.mem.startsWith(u8, facts(&shown), "‹ k7m2qx · Stopping and archiving"));
    try std.testing.expect(ChromeFixture.find(&shown, "Copied 3 lines") != null);
}

test "App Session Footer clips identity in terminal cells" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    // Identity exceeds the cells left after ` ‹ `; Footer clips it,
    // without changing the chat name or the original facts.
    self.line = .{ .read = .{ .revision = 1, .end = 1 }, .effort = .low, .left = 100, .label = .{} };
    try self.line.label.?.set("Port the overview to vxfw and keep its key table");
    try self.line.model.set("gpt-6-sol");
    const shown = try fixture.rows();
    try std.testing.expect(std.mem.startsWith(u8, shown[22], "‹ Port the overview to vxfw and keep its key table · gpt-6-sol · …"));
    try std.testing.expect(session_line.cells(shown[22], .unicode) <= 80);
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
    try std.testing.expect(ChromeFixture.find(&shown, "Port overview to vxfw finished") != null);
    try std.testing.expect(std.mem.startsWith(u8, shown[22], "‹ k7m2qx"));
    try std.testing.expect(std.mem.endsWith(u8, shown[22], " ctrl+x stop"));
    // Work ends: the stop key goes; the overview's notice stays its own.
    self.live.work.state = .{ .idle = .{ .since = 0 } };
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Port overview to vxfw finished") != null);
}

test "App Session's last row says the send state, which stays past a key and five seconds" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const original = self.input.submitText("original model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .submitting, .key = @splat('K') };
    defer self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Sending…") != null);
    self.submission.state = .unconfirmed;
    // A notice arrives and goes; what needs the person outranks it and stays.
    self.shown_notice.show("Copied 3 lines", ChromeFixture.now() - 6_000);
    try fixture.press(.{ .codepoint = 'a', .text = "a" });
    const unconfirmed = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&unconfirmed, "! Not confirmed") != null);
    try std.testing.expect(std.mem.endsWith(u8, unconfirmed[22], "ctrl+r retries original"));
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
    const rejected = try fixture.rows();
    try std.testing.expect(ChromeFixture.find(&rejected, "! Input rejected: message_too_long") != null);
    try std.testing.expect(std.mem.endsWith(u8, rejected[22], "/discard"));
    try std.testing.expectEqualStrings("/discard", self.chrome.status.key.label);
    // Another original rejected keeps its own code, not this one's.
    self.submission.key = @splat('L');
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "Rejected") != null);
}

test "App Session keeps a refused environment and its repair details separate from chat info" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.files.details = try held.tmp.dir.createFile(std.testing.io, "details", .{ .read = true });
    defer held.self.files.details.close(std.testing.io);
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
    try std.testing.expectEqualStrings("! Environment too large; nothing sent", bar);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "details") != null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r") == null);
    try held.self.showSubmissionFailure();
    for (0..4) |_| try sendKeys(&held.self, "\x1b[6~");
    try held.settle();
    try std.testing.expect((try rowWith(held, "BIG_TOKEN")) != null);
    try std.testing.expectEqualStrings(" Unset or shorten them in another shell, then run rui request recover there.", (try rowWith(held, "rui request recover")).?);
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

test "App Session info opens while commands wait and refused originals keep their repair details" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    self.input.queueCommand("/requests");
    // Info is inspection, not another command; opening it never replaces one.
    for (0..2) |_| try self.chrome.info.on_click(self.chrome.info.userdata, &fixture.ctx);
    try std.testing.expect(self.info_open);
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try fixture.press(.{ .codepoint = vaxis.Key.escape });
    _ = self.input.append("/effort low");
    try fixture.press(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("/effort low", self.input.composition().bytes);
    try std.testing.expect(ChromeFixture.find(&try fixture.rows(), "! Command still running. Draft retained.") != null);
    const original = self.input.submitText("original model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .rejected, .key = @splat('K') };
    defer self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
    try self.chrome.status.key.on_click(self.chrome.status.key.userdata, &fixture.ctx);
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqual(Submission.State.rejected, self.submission.view().?.state);
    _ = self.input.takeCommand();
    self.submission.state = .not_started;
    self.holdFailure(.{ .line = session_notice.too_large, .key = .status }, null);
    self.files.details = try fixture.tmp.dir.createFile(std.testing.io, "repair-details", .{ .read = true });
    defer self.files.details.close(std.testing.io);
    try self.chrome.status.key.on_click(self.chrome.status.key.userdata, &fixture.ctx);
    try std.testing.expect(self.input.queuedCommand() == null);
    try std.testing.expectEqual(Screen.ViewKind.details, self.screen.view);
    try std.testing.expectEqual(Submission.State.not_started, self.submission.view().?.state);
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

test "App Session question mark encodings append ordinary text to empty and nonempty drafts" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    const keys = [_]vaxis.Key{
        .{ .codepoint = '?', .text = "?" },
        .{ .codepoint = '/', .text = "?", .mods = .{ .shift = true } },
        .{ .codepoint = '?', .text = "?", .mods = .{ .shift = true } },
    };
    for (keys) |key| {
        for ([_]bool{ false, true }) |has_draft| {
            _ = self.input.clear();
            if (has_draft) try fixture.press(.{ .codepoint = 'a', .text = "a" });
            try fixture.press(key);
            _ = try fixture.draw();
            try std.testing.expect(self.app_screen.overlay == null);
            try std.testing.expectEqualStrings(if (has_draft) "a?" else "?", self.input.composition().bytes);
            try fixture.press(key);
            _ = try fixture.draw();
            try std.testing.expect(self.app_screen.overlay == null);
            try std.testing.expectEqualStrings(if (has_draft) "a??" else "??", self.input.composition().bytes);
        }
    }
}

test "App Session copy notices are compact state phrases" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const self = fixture.self;
    for ([_]struct { result: reads.Copied, words: []const u8 }{
        .{ .result = .no_answer, .words = "No answer to copy" },
        .{ .result = .too_large, .words = TerminalText.clipboard_too_large },
        .{ .result = .{ .clipboard = .{ .start = 0, .length = 0 } }, .words = "Sent to clipboard" },
    }) |case| {
        self.dirty = false;
        self.job.result.copied = case.result;
        try self.showCopy();
        try std.testing.expectEqualStrings(case.words, self.notice.?);
        try std.testing.expect(self.dirty);
    }
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

test "App Session keeps its real draft browsing anchor and focused composer across the split threshold" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.root.openSession(&fixture.ctx, fixture.widget);
    const draw: vxfw.DrawContext = .{ .arena = fixture.arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 26 }, .cell_size = .{} };
    _ = try fixture.root.widget().draw(draw);
    try fixture.press(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    for ("kept") |byte| try fixture.press(.{ .codepoint = byte, .text = &.{byte} });
    _ = try fixture.root.widget().draw(draw);
    const view_before = fixture.screen.view;
    try std.testing.expectEqual(Screen.ViewKind.feed, view_before);
    const top = fixture.screen.anchor.anchor;
    try std.testing.expect(top == .at);
    const focused = fixture.self.app_input.composer.widget();
    const commands = fixture.ctx.cmds.items.len;
    try std.testing.expect(fixture.ctx.cmds.items[commands - 1].request_focus.eql(focused));
    var caret_col: ?u16 = null;
    for ([_]u16{ 140, 46, 99, 100, 46, 140 }) |width| {
        const surface = try fixture.root.widget().draw(draw.withConstraints(.{}, .{ .width = width, .height = 26 }));
        try std.testing.expect(fixture.root.session.?.eql(fixture.widget));
        try std.testing.expectEqualStrings("kept", fixture.self.input.composition().bytes);
        try std.testing.expectEqual(view_before, fixture.screen.view);
        try std.testing.expectEqualDeep(top, fixture.screen.anchor.anchor);
        try std.testing.expectEqual(commands, fixture.ctx.cmds.items.len);
        var screen: vaxis.Screen = try .init(fixture.arena.allocator(), .{ .cols = width, .rows = 26, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 26, .screen = &screen };
        surface.render(window, focused);
        try std.testing.expect(screen.cursor_vis);
        const col = screen.cursor.col - @as(u16, if (width >= 100) 41 else 0);
        if (caret_col) |expected| try std.testing.expectEqual(expected, col) else caret_col = col;
    }
}

test "App Session footer takes list visibility from Root across desktop and phone resizes" {
    var fixture: ChromeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.root.session = fixture.widget;
    for ([_]struct { width: u16, list: bool }{
        .{ .width = 140, .list = true },
        .{ .width = 46, .list = false },
        .{ .width = Root.split_at, .list = true },
        .{ .width = Root.split_at - 1, .list = false },
        .{ .width = 140, .list = true },
    }) |case| {
        const arena = fixture.arena.allocator();
        const surface = try fixture.root.widget().draw(.{ .arena = arena, .min = .{}, .max = .{ .width = case.width, .height = 30 }, .cell_size = .{} });
        try std.testing.expectEqual(case.list, fixture.root.listVisible());
        var screen: vaxis.Screen = try .init(arena, .{ .rows = 30, .cols = case.width, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = case.width, .height = 30, .screen = &screen };
        surface.render(window, fixture.self.app_input.composer.widget());
        const chat_col: u16 = if (case.list) Root.list_width + 1 else 0;
        var row: std.Io.Writer.Allocating = .init(arena);
        for (chat_col..case.width) |col| try row.writer.writeAll(screen.readCell(@intCast(col), 28).?.char.grapheme);
        try std.testing.expectEqual(@as(usize, if (case.list) 0 else 1), std.mem.count(u8, row.written(), "‹"));
        try std.testing.expect(std.mem.indexOf(u8, row.written(), "k7m2qx") != null);
        try std.testing.expectEqualStrings("─", screen.readCell(chat_col, 27).?.char.grapheme);
        for (chat_col..case.width) |col| try std.testing.expectEqualStrings(" ", screen.readCell(@intCast(col), 29).?.char.grapheme);
    }
}

test "SessionFrontend failed historical fills retain the edge while scans approval and directed retries progress" {
    const Worker = struct {
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.ConnectionResetByPeer;
        }
        fn complete(frontend: *Self) bool {
            return frontend.reader.completed();
        }
    };
    for ([_]feed_reads.Read{ .fill_above, .fill_below }) |read| {
        const fixture = try FeedFixture.create();
        defer fixture.destroy();
        const held = fixture.held;
        const self = &held.self;
        const down = read == .fill_below;
        try fixture.longPage(.opening, 100);
        _ = try held.draw();
        if (down) {
            try self.scroll(false, 1);
            held.screen.feed.at_end = false;
        } else try self.scroll(false, 200);
        _ = try held.draw();
        self.poll_at = std.math.maxInt(i96);
        try std.testing.expectEqual(read, FeedPolicy.nextRead(self.feedState()).?);
        const cycle = self.live.scan;
        const text = try std.testing.allocator.dupe(u8, held.screen.feed.document.text());
        defer std.testing.allocator.free(text);
        const job = self.freeze(.fill);
        self.reading.feed_read = read;
        job.feed_page = FeedPolicy.request(read, self.feedState());
        try self.launch(job, Worker.fail);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), self, Worker.complete);
        try self.settleReader();
        try std.testing.expectEqual(ReadPhase.fill, self.reading.phase);
        try std.testing.expectEqualDeep(cycle, self.live.scan);
        try std.testing.expectEqualStrings(text, held.screen.feed.document.text());
        try std.testing.expectEqualStrings("! Messages unavailable; scroll to retry.", self.notice.?);
        try std.testing.expect(self.reading.fills.blocked != null);
        for (0..3) |_| {
            _ = try held.draw();
            try std.testing.expect(FeedPolicy.nextRead(self.feedState()) == null);
        }
        // Successful unchanged live facts do not rearm the failed edge.
        try fixture.page(.scan, &.{}, false, !down);
        self.poll_at = std.math.maxInt(i96);
        try std.testing.expect(FeedPolicy.nextRead(self.feedState()) == null);
        self.poll_at = 0;
        try std.testing.expectEqual(feed_reads.Read.scan, FeedPolicy.nextRead(self.feedState()).?);
        self.live.work.first_action = 1;
        try std.testing.expectEqual(feed_reads.Read.scan, FeedPolicy.nextRead(self.feedState()).?);
        self.poll_at = std.math.maxInt(i96);
        try std.testing.expectEqual(feed_reads.Read.permission, FeedPolicy.nextRead(self.feedState()).?);
        self.live.work.first_action = null;
        // User scroll in the other direction stays inside the same margin.
        try self.scroll(!down, 1);
        try std.testing.expect(FeedPolicy.nextRead(self.feedState()) == null);
        try self.scroll(down, 1);
        try std.testing.expectEqual(read, FeedPolicy.nextRead(self.feedState()).?);
        // A deliberate jump starts a new lifecycle even at an unchanged edge.
        self.reading.fills = self.reading.fills.failed(read, FeedPolicy.request(read, self.feedState()).?);
        try self.jumpToEnd();
        try std.testing.expect(self.reading.fills.blocked == null);
    }
}

/// Feed-domain fixture: pages use the same staged-file handoff as the reader.
const FeedFixture = struct {
    held: *HeldFrontend,
    file: std.Io.File,
    const Row = struct { key: u64, text: []const u8, provisional: bool = false, target: ?View.Collapsed = null };

    fn create() !FeedFixture {
        return createWithDrafts("unused", null);
    }
    fn createWithDrafts(id: []const u8, drafts: ?*session_drafts.Drafts) !FeedFixture {
        const held = try HeldFrontend.createWithDrafts(id, drafts);
        errdefer held.destroy();
        const file = try held.tmp.dir.createFile(std.testing.io, "feed-page", .{ .read = true });
        held.self.files = .{ .scratch = file, .inspection = file, .action = file, .details = file, .actions = .{ file, file } };
        return .{ .held = held, .file = file };
    }
    fn destroy(self: FeedFixture) void {
        self.held.destroy();
        self.file.close(std.testing.io);
    }
    fn page(self: FeedFixture, read: feed_reads.Read, rows: []const Row, start: bool, end: bool) !void {
        const frontend = &self.held.self;
        // Freeze and settle exactly like the production read handoff. In
        // particular, fills must not advance the independent live cursor.
        if (read == .opening) frontend.reading.opening = true;
        const job = frontend.freeze(if (read == .fill_above or read == .fill_below) .fill else .activity);
        frontend.reading.feed_read = read;
        job.feed_page = FeedPolicy.request(read, frontend.feedState());
        frontend.job.result.row_count = rows.len;
        frontend.job.result.at_start = start;
        frontend.job.result.at_end = end;
        frontend.job.result.low = if (rows.len == 0) null else .{ .position = rows[0].key };
        frontend.job.result.high = if (rows.len == 0) frontend.screen.feed.high else .{ .position = rows[rows.len - 1].key, .ordinal = if (end) std.math.maxInt(u64) else 0 };
        if (frontend.job.result.high) |high| frontend.job.result.cursor = .{ .position = high.position, .ordinal = if (high.ordinal == std.math.maxInt(u64)) null else high.ordinal };
        var offset: u64 = 0;
        for (rows, 0..) |row, i| {
            try self.file.writePositionalAll(std.testing.io, row.text, offset);
            frontend.job.result.rows[i] = .{ .key = .{ .position = row.key }, .offset = offset, .length = row.text.len, .tight = false, .provisional = row.provisional };
            if (row.target) |target| {
                frontend.job.result.rows[i].collapsed_targets[0] = target;
                frontend.job.result.rows[i].collapsed_count = 1;
            }
            if (row.text.len != 0 and FeedPolicy.isNew(frontend.job.feed_page.?, .{ .position = row.key })) frontend.job.result.new_rows += 1;
            offset += row.text.len;
        }
        try frontend.launch(job, struct {
            fn complete(_: *anyopaque, _: *Task) !void {}
        }.complete);
        try frontend.settleReader();
    }
    fn longPage(self: FeedFixture, read: feed_reads.Read, first: u64) !void {
        var rows: [16]Row = undefined;
        var words: [16][160]u8 = undefined;
        for (&rows, 0..) |*row, i| {
            var out = std.Io.Writer.fixed(&words[i]);
            for (0..8) |line| try out.print("entry {d} line {d}\n", .{ first + i, line });
            row.* = .{ .key = first + i, .text = out.buffered() };
        }
        try self.page(read, &rows, false, read != .fill_above);
    }
};

fn firstRows(text: []const u8, count: usize) []const u8 {
    var end: usize = 0;
    for (0..count) |_| end = 1 + (std.mem.indexOfScalarPos(u8, text, end, '\n') orelse return text);
    return text[0..end];
}

test "SessionFrontend feed keeps following when full rows leave no room inside the margins" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const window = &held.screen.feed;
    const dense = try std.testing.allocator.alloc(u8, 3 * 30_000);
    defer std.testing.allocator.free(dense);
    for (dense, 0..) |*byte, index| byte.* = if (index % 100 == 99) '\n' else "abc"[index / 30_000];
    try fixture.page(.opening, &.{ .{ .key = 10, .text = dense[0..30_000] }, .{ .key = 11, .text = "between\n" }, .{ .key = 12, .text = dense[30_000..60_000] } }, true, true);
    try std.testing.expectEqual(@as(usize, 3), window.count);
    // On a pane so tall that every row is inside its loading margin, a row
    // as large as the two before it arrives: the oldest leaves, it goes in.
    _ = try held.shown();
    held.screen.height = 500;
    try fixture.page(.scan, &.{.{ .key = 13, .text = dense[60_000..] }}, false, true);
    try std.testing.expect(held.screen.anchor.following() and window.at_end and !window.at_start);
    try std.testing.expectEqual(@as(u64, 11), window.entries[0].key.position);
    try std.testing.expectEqual(@as(u64, 13), window.entries[window.count - 1].key.position);
    // The margin wants the row above back, and it no longer fits. Its fill
    // places nothing, then waits for a scroll instead of being read again
    // and again.
    try std.testing.expectEqual(@as(?feed_reads.Read, .fill_above), idleRead(&held.self));
    try fixture.page(.fill_above, &.{.{ .key = 10, .text = dense[0..30_000] }}, true, false);
    try std.testing.expectEqual(@as(u64, 11), window.entries[0].key.position);
    try std.testing.expectEqual(@as(?feed_reads.Read, null), idleRead(&held.self));
    try held.self.scroll(false, 1);
    try std.testing.expectEqual(@as(?feed_reads.Read, .fill_above), idleRead(&held.self));
}

/// The read the policy picks with no scan due.
fn idleRead(self: *Self) ?feed_reads.Read {
    var state = self.feedState();
    state.now_ns = 0;
    state.scan_due_ns = 1;
    return FeedPolicy.nextRead(state);
}

test "SessionFrontend feed opens full bottom aligned and page round trip is an identical frame" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    try fixture.longPage(.opening, 100);
    const held = fixture.held;
    const initial = try held.shown();
    errdefer std.debug.print("initial feed frame:\n{s}\nfinal feed frame:\n{s}\n", .{ initial, held.shown() catch "unavailable" });
    try std.testing.expectEqual(@as(u32, 0), held.screen.anchor.visible(held.screen.feed.layoutEntries(held.screen.textLayout()), held.screen.height).pad);
    try std.testing.expect(std.mem.indexOf(u8, firstRows(initial, 2), "entry ") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "entry 115 line 7") != null);
    for (0..3) |_| try held.keys("\x1b[5~");
    try std.testing.expect(!held.screen.anchor.following());
    for (0..3) |_| try held.keys("\x1b[6~");
    try std.testing.expect(held.screen.anchor.following());
    try std.testing.expectEqualStrings(initial, try held.shown());
}

test "SessionFrontend feed banks held PgUp across a fill and live arrivals keep the held rows still" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    try fixture.longPage(.opening, 100);
    _ = try held.draw();
    try held.self.scroll(false, 1000);
    try std.testing.expect(held.screen.anchor.banked_rows < 0);
    const before_key = held.screen.anchor.anchor.at.key;
    try fixture.longPage(.fill_above, 84);
    try std.testing.expect(held.screen.anchor.anchor == .at);
    try std.testing.expect(held.screen.anchor.anchor.at.key.order(before_key) == .lt);
    const held_anchor = held.screen.anchor.anchor;
    const held_frame = try held.shown();
    try fixture.longPage(.fill_above, 68);
    try std.testing.expectEqualDeep(held_anchor, held.screen.anchor.anchor);
    try std.testing.expectEqualStrings(held_frame, try held.shown());
    const before = try held.shown();
    const anchor = held.screen.anchor.anchor;
    try fixture.page(.scan, &.{ .{ .key = 116, .text = "new settled row\n" }, .{ .key = 117, .text = "another settled row\n" } }, false, true);
    try std.testing.expectEqualDeep(anchor, held.screen.anchor.anchor);
    try std.testing.expectEqual(@as(usize, 2), held.self.new_below);
    const after = try held.shown();
    try std.testing.expectEqualStrings(firstRows(before, held.screen.height), firstRows(after, held.screen.height));
    try std.testing.expect(std.mem.indexOf(u8, after, "↓ 2 new") != null);
}

test "SessionFrontend feed jump after high eviction keeps old rows until the opening lands" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    try fixture.longPage(.opening, 100);
    _ = try held.draw();
    try held.self.scroll(false, 80);
    held.screen.feed.trim(0, 4);
    const old = try held.shown();
    const anchor = held.screen.anchor.anchor;
    try held.self.jumpToEnd();
    try std.testing.expect(held.self.reading.opening);
    try std.testing.expectEqualDeep(anchor, held.screen.anchor.anchor);
    try std.testing.expectEqual(feed_reads.Read.opening, FeedPolicy.nextRead(held.self.feedState()).?);
    try std.testing.expectEqualStrings(firstRows(old, held.screen.height), firstRows(try held.shown(), held.screen.height));
    try fixture.longPage(.opening, 300);
    try std.testing.expect(held.screen.anchor.following());
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "entry 315 line 7") != null);
}

test "SessionFrontend feed reload restores keyed Ctrl-O target and replaces a provisional suffix once" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const target: View.Collapsed = .{ .source = .activity, .position = 40, .ordinal = 0, .content = .{ .length = 2000, .digest = @splat(7) }, .row = false };
    const summary = "› preview\n  " ++ View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n";
    try fixture.page(.opening, &.{ .{ .key = 40, .text = summary, .target = target }, .{ .key = 50, .text = "settled\n" } }, true, true);
    _ = try held.draw();
    _ = try held.self.expand();
    try std.testing.expectEqualDeep(target, held.self.expansion.queued.ready.target.message);
    held.screen.feed.opened.set(.{ .position = 40 }, true);
    held.screen.feed.trim(1, 0);
    held.screen.anchor.anchor = .{ .at = .{ .key = .{ .position = 50 } } };
    try fixture.page(.fill_above, &.{.{ .key = 40, .text = summary, .target = target }}, true, false);
    held.screen.anchor.follow();
    _ = try held.draw();
    _ = try held.self.expand();
    try std.testing.expectEqualDeep(target, held.self.expansion.queued.ready.target.message);
    try std.testing.expect(held.screen.feed.opened.has(.{ .position = 40 }));
    try fixture.page(.scan, &.{ .{ .key = 60, .text = "› provisional\n", .provisional = true }, .{ .key = 61, .text = "between\n" } }, false, true);
    try fixture.page(.scan, &.{ .{ .key = 61, .text = "between\n" }, .{ .key = 62, .text = "› applied\n" } }, false, true);
    try std.testing.expect(held.screen.feed.firstProvisional() == null);
    try std.testing.expectEqual(@as(usize, 4), held.screen.feed.count);
    try std.testing.expect(std.mem.indexOf(u8, held.screen.feed.document.text(), "provisional") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, held.screen.feed.document.text(), "› applied"));
}

test "SessionFrontend feed resize inside a long answer preserves the same logical line on top" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    var words: [8000]u8 = undefined;
    var out = std.Io.Writer.fixed(&words);
    for (0..50) |line| try out.print("logical {d:0>2} answer words that wrap on a narrow terminal but keep their identity\n", .{line});
    try fixture.page(.opening, &.{.{ .key = 10, .text = out.buffered() }}, true, true);
    held.screen.anchor.anchor = .{ .at = .{ .key = .{ .position = 10 }, .line = 12 } };
    try std.testing.expect(std.mem.indexOf(u8, firstRows(try held.shown(), 1), "logical 12") != null);
    const anchor = held.screen.anchor.anchor;
    held.size = .{ .width = 46, .height = 30 };
    try std.testing.expect(std.mem.indexOf(u8, firstRows(try held.shown(), 1), "logical 12") != null);
    try std.testing.expectEqualDeep(anchor, held.screen.anchor.anchor);
}

test "SessionFrontend feed latest ending is live state, not window fill state" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.reading.phase = .activity;
    const ending: reads.LatestEnding = .{ .key = .{ .position = 10 }, .cause = @import("marks.zig").cause("provider_http_500") };
    const newer: reads.LatestEnding = .{ .key = .{ .position = 20 }, .cause = @import("marks.zig").cause("provider_quota") };
    for ([_]feed_reads.Read{ .opening, .scan, .fill_above, .fill_below }) |read| {
        self.live.latest_ending = ending;
        self.reading.feed_read = read;
        self.job.feed_page = FeedPolicy.request(read, self.feedState());
        self.job.result = .{ .latest_ending = newer };
        try self.applyReader(.{ .cancelled = .{ .phase = .activity, .rendering = false } });
        try std.testing.expectEqualDeep(ending, self.live.latest_ending.?);
        try self.applyReader(.complete);
        try std.testing.expectEqualDeep(if (read == .opening or read == .scan) newer else ending, self.live.latest_ending.?);
        // The next reader freezes the live scan fact even with no resident rows.
        const job = self.freeze(.activity);
        try std.testing.expectEqualDeep(self.live.latest_ending, job.latest_ending);
    }
}

/// The shell tests use a joined worker result; session_reads' native Host
/// fixtures separately exercise the production retry worker's exact-byte I/O.
fn stageRetryForTest(self: *Self, completion: reads.RetryCompletion) !void {
    const Worker = struct {
        fn run(_: *anyopaque, _: *Task) !void {}
    };
    const fence = self.retry_fence.?;
    const job = self.freeze(.retry);
    job.retry = fence.ending;
    job.result.retry = switch (completion) {
        .message => |message| .{ .message = message },
        .failure => |failure| .{ .failure = failure },
        .stale => unreachable,
    };
    try self.launch(job, Worker.run);
    try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &self.reader, RetrySettlementWorker.completed);
}

fn failedRetryForTest(self: *Self) void {
    self.live.latest_ending = .{ .key = .{ .position = 3 }, .cause = @import("marks.zig").cause("malformed_provider_output") };
}

test "failed reply retry eligibility follows every live work state and admitted queue" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.failedRetryForTest();
    const State = protocol.WorkState;
    const cases = [_]struct { state: State, quiet: bool }{
        .{ .state = .{ .idle = .{ .since = 1 } }, .quiet = true },
        .{ .state = .{ .pending = .{ .since = 2 } }, .quiet = false },
        .{ .state = .{ .working = .{ .since = 2 } }, .quiet = false },
        .{ .state = .{ .retrying = .{ .since = 2, .due_at_ms = 3000, .cause = .{}, .attempt = 1 } }, .quiet = false },
        .{ .state = .{ .bash = .{ .since = 2, .call = 1, .description = null, .running = 1, .approvals = 0 } }, .quiet = false },
        .{ .state = .{ .approval = .{ .since = 2 } }, .quiet = false },
        .{ .state = .{ .stopping = .{ .since = 2 } }, .quiet = false },
        .{ .state = .{ .finished = .{ .since = 2 } }, .quiet = true },
        .{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .quiet = true },
        .{ .state = .{ .stopped = .{ .since = 2, .cause = .stop } }, .quiet = true },
    };
    comptime std.debug.assert(cases.len == @typeInfo(State).@"union".field_names.len);
    for (cases) |case| {
        self.live.work.state = case.state;
        for ([_]u64{ 0, 1, 2 }) |count| {
            self.live.queued.count = count;
            try std.testing.expectEqual(case.quiet and count == 0, self.retryable() != null);
        }
    }
}

/// The real begin transition retains the input and launches its borrower. The
/// fixture has no Host; join that failed transport, then supply a typed answer
/// through the same worker/advance/present handoff as Admission recovery.
fn stageMessageForRetryTest(self: *Self, accepted: bool) !void {
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
        fn completed(owner: *Submission) bool {
            return owner.task.completed();
        }
    };
    self.submission.cancel();
    try std.testing.expect(self.submission.join() == .failed);
    const bytes = try self.input.message(self.submission.intent.?.message);
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("not_allowed");
    self.submission.reply = .{
        .status = 200,
        .context = .{ .kind = .message },
        .target = .{ .message = .{ .bytes = bytes.len, .digest = protocol.contentDigest(bytes) } },
        .answer = .{ .replayed = false, .result = if (accepted) .{ .accepted = .{ .message = .{ .admission = 37 } } } else .{ .rejected = code } },
    };
    try self.submission.task.start(self.init.io, &self.submission, Worker.done);
    try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &self.submission, Worker.completed);
}

fn settleMessageForRetryTest(self: *Self, accepted: bool) !void {
    try self.stageMessageForRetryTest(accepted);
    try self.admit();
}

/// Gates order actor boundaries, never sleeps. The retry worker is still
/// running while the test submits/settles a person's newer Message.
const RetryFenceWorker = struct {
    const text = "/old literal\n\t café 💚\r\n";
    var entered: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);

    fn ready(task: *Task) bool {
        return release.load(.acquire) or task.cancellation.stopped.load(.acquire);
    }
    fn run(raw: *anyopaque, task: *Task) !void {
        const job: *Job = @ptrCast(@alignCast(raw));
        entered.store(true, .release);
        try test_poll.waitUntil(task.io, test_poll.after(task.io, .fromSeconds(10)), task, ready);
        if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        job.result.retry = .{ .message = .{ .ending = job.retry.?, .position = 2, .length = text.len } };
    }
    fn start(self: *Self) !void {
        entered.store(false, .release);
        release.store(false, .release);
        try self.files.scratch.writePositionalAll(self.init.io, text, 0);
        try self.launchRetrySettlementForTest(run);
        try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &entered, test_poll.isSet);
    }
    fn complete(self: *Self) !void {
        release.store(true, .release);
        try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &self.reader, RetrySettlementWorker.completed);
    }
};

test "failed reply newer Message accepted before retry completion supersedes the fence before live work" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const self = &held.self;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    const ending = self.live.latest_ending.?;
    const eligible = self.retryable().?;
    try held.keys("\x12");
    try std.testing.expectEqualDeep(eligible, self.retry_fence.?);
    try RetryFenceWorker.start(self);
    try held.keys("new Message\rkept éZ\x1b[D");
    const draft = self.input.snapshot();
    const newer_key = self.submission.key;
    try std.testing.expect(!self.reader.completed()); // Admission precedes read completion.
    try self.stageMessageForRetryTest(true);
    try RetryFenceWorker.complete(self);
    // Both borrowers are ready. Exercise update's actual admit-before-reader
    // order with exactly the OLD quiescent work/queue/ending, not a new scan.
    _ = try self.update();
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent); // Only the person's Message.
    try std.testing.expect(self.submission.intent == null);
    try std.testing.expectEqualSlices(u8, &newer_key, &self.submission.accepted.?.key);
    try std.testing.expect(self.retry_fence == null);
    try std.testing.expectEqualDeep(ending, self.live.latest_ending.?);
    try std.testing.expect(self.live.work.state == .idle and self.live.queued.count == 0);
    try std.testing.expectEqualDeep(draft, self.input.snapshot());
    // Acceptance requested an ordinary scan. The no-Host fixture cancels that
    // borrower before staging the LATER observed pending/working facts.
    self.reader.cancel();
    try std.testing.expect(self.joinReader() != .complete);
    self.job.result = .{
        .latest_ending = ending,
        .work = .{ .work = .{ .state = .{ .pending = .{ .since = 2 } }, .turn = 1 } },
        .queued = .{ .count = 1, .oldest_position = 4, .newest_admission = 37, .newest_position = 4 },
    };
    try self.applyReader(.complete);
    try std.testing.expect(self.retryable() == null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r retries") == null);
    try held.keys("\x12");
    try std.testing.expect(self.retry_fence == null);
    self.job.result.work.work = .{ .state = .{ .working = .{ .since = 3 } }, .turn = 2 };
    self.job.result.queued = .{};
    try self.applyReader(.complete);
    try std.testing.expect(self.retryable() == null);
}

test "failed reply stale pre-admission scan must not authorize a fresh Ctrl-R after acceptance" {
    const Worker = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);
        fn ready(task: *Task) bool {
            return release.load(.acquire) or task.cancellation.stopped.load(.acquire);
        }
        fn run(_: *anyopaque, task: *Task) !void {
            entered.store(true, .release);
            try test_poll.waitUntil(task.io, test_poll.after(task.io, .fromSeconds(10)), task, ready);
            if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        }
    };
    const Host = struct {
        frontend: *Self,
        listener: *std.Io.net.Server,
        pages: usize = 0,
        contents: usize = 0,
        const text = "old literal Message";

        // Service native HTTP requests while waiting for the actual ClientTask.
        // The old-Message responses also let a reverted head check reach the
        // erroneous second submission, rather than failing in the fixture.
        fn pump(host: *@This()) !bool {
            var fds = [_]std.posix.pollfd{.{ .fd = host.listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 0) != 0) {
                const peer = try host.listener.accept(std.testing.io);
                defer peer.close(std.testing.io);
                var request: [4096]u8 = undefined;
                var used: usize = 0;
                var body_start: usize = 0;
                while (true) {
                    const got = try std.posix.read(peer.socket.handle, request[used..]);
                    if (got == 0) return error.UnexpectedEof;
                    used += got;
                    if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |end| {
                        body_start = end + 4;
                        const start = std.mem.indexOf(u8, request[0..end], "Content-Length: ").? + "Content-Length: ".len;
                        const finish = std.mem.indexOfScalarPos(u8, request[0..end], start, '\r').?;
                        if (used == body_start + try std.fmt.parseInt(usize, request[start..finish], 10)) break;
                    }
                }
                var storage: [4096]u8 = undefined;
                var fixed = std.heap.FixedBufferAllocator.init(&storage);
                const cursor = try std.json.parseFromSliceLeaky(struct { position: []const u8 }, fixed.allocator(), request[body_start..used], .{ .ignore_unknown_fields = true });
                const position = try std.fmt.parseInt(u64, cursor.position, 10);
                var buffer: [4096]u8 = undefined;
                var out = std.Io.Writer.fixed(&buffer);
                var extra_buffer: [128]u8 = undefined;
                var extra: []const u8 = "";
                var kind: []const u8 = "application/json";
                if (std.mem.startsWith(u8, request[0..used], "POST /v1/activity-page ")) {
                    host.pages += 1;
                    // The newer Message is already admitted at Host, even
                    // though the frontend's just-installed snapshot is idle.
                    const reference: protocol.ActivityItem.Content = .{ .length = text.len, .digest = protocol.contentDigest(text) };
                    var facts: protocol.ActivityFacts = .{ .end = 3, .direction = .backward, .count = 1, .queued = .{ .count = 1, .oldest_position = 3, .newest_admission = 37, .newest_position = 3 }, .work = .{ .revision = 2, .work = .{ .state = .{ .pending = .{ .since = 2 } } } } };
                    try facts.work.workspace.set("/");
                    facts.items[0] = .{ .position = if (position == 0) 3 else 1, .at = 1, .value = .{ .admission = .{ .admission = if (position == 0) 37 else 1, .key = .{}, .turn = null, .state = .queued, .content = reference, .admitted_at = 1 } } };
                    try activity_reply.writePage(&out, &facts);
                } else {
                    try std.testing.expectStringStartsWith(request[0..used], "POST /v1/activity-content ");
                    try std.testing.expectEqual(@as(u64, 1), position);
                    host.contents += 1;
                    kind = "application/octet-stream";
                    extra = try std.fmt.bufPrint(&extra_buffer, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ text.len, text.len });
                    try out.writeAll(text);
                }
                var header: [512]u8 = undefined;
                var writer = peer.writer(std.testing.io, &.{});
                try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{ kind, out.buffered().len, extra }));
                try writer.interface.writeAll(out.buffered());
            }
            return host.frontend.reader.completed();
        }
    };
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const self = &held.self;
    try seedFeed(held.screen, "old literal Message\n");
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    const ending = self.live.latest_ending.?;
    // Capture old idle facts before Admission, but publish them only after it.
    const job = self.freeze(.activity);
    job.result.latest_ending = ending;
    job.result.work.work = .{ .state = .{ .idle = .{ .since = 1 } } };
    job.result.queued = .{};
    Worker.entered.store(false, .release);
    Worker.release.store(false, .release);
    try self.launch(job, Worker.run);
    try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &Worker.entered, test_poll.isSet);
    try held.keys("new Message\r");
    try self.settleMessageForRetryTest(true);
    try std.testing.expect(self.submission.intent == null);
    try std.testing.expect(!self.reader.completed());
    Worker.release.store(true, .release);
    try test_poll.waitUntil(self.init.io, test_poll.after(self.init.io, .fromSeconds(2)), &self.reader, RetrySettlementWorker.completed);
    try self.settleReader();
    try std.testing.expectEqualDeep(ending, self.live.latest_ending.?);
    try std.testing.expect(self.live.work.state == .idle and self.live.queued.count == 0);
    // A fresh gesture captures the ALREADY increased count, but the real
    // retry walk rejects the old ending against Host's newest admitted row.
    const io = self.init.io;
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
    self.store = root;
    self.session = "k7m2qx";
    defer {
        self.reader.cancel();
        self.reader.join() catch |err| switch (err) {
            error.Cancelled => {},
            else => @panic(@errorName(err)),
        };
    }
    try held.keys("kept éZ\x1b[D");
    const draft = self.input.snapshot();
    try held.keys("\x12");
    try std.testing.expect(self.retry_fence != null);
    try self.startRetry();
    var host: Host = .{ .frontend = self, .listener = &listener };
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), &host, Host.pump);
    try self.settleReader();
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
    try std.testing.expect(self.submission.intent == null and self.retry_fence == null);
    try std.testing.expectEqual(@as(usize, 1), host.pages);
    try std.testing.expectEqual(@as(usize, 0), host.contents);
    try std.testing.expectEqualDeep(draft, self.input.snapshot());
    // No local suppression marker: before observation another gesture may
    // read Host again, but cannot send. Once work is observed, the shared
    // predicate hides the tail and the key starts no read.
    try held.keys("\x12");
    try self.startRetry();
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), &host, Host.pump);
    try self.settleReader();
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
    _ = self.freeze(.activity);
    self.job.result = .{
        .latest_ending = ending,
        .work = .{ .work = .{ .state = .{ .working = .{ .since = 2 } }, .turn = 2 } },
    };
    try self.applyReader(.complete);
    try std.testing.expect(self.retryable() == null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r retries") == null);
    try held.keys("\x12");
    try std.testing.expect(self.retry_fence == null and self.reader.thread == null);
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
    try std.testing.expectEqualDeep(draft, self.input.snapshot());
}

test "failed reply retry completion before newer Message admission sends once and keeps the newer Message separate" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const self = &held.self;
    self.failedRetryForTest();
    try held.keys("\x12");
    try RetryFenceWorker.start(self);
    try RetryFenceWorker.complete(self);
    try self.settleReader();
    try std.testing.expect(self.retry_fence == null);
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
    try std.testing.expectEqualStrings(RetryFenceWorker.text, try self.input.message(self.submission.intent.?.message));
    const retry_key = self.submission.key;
    try self.settleMessageForRetryTest(true);
    try std.testing.expect(self.submission.intent == null);
    try std.testing.expectEqualSlices(u8, &retry_key, &self.submission.accepted.?.key);
    try held.keys("new Message\r");
    const newer_key = self.submission.key;
    try std.testing.expect(!std.mem.eql(u8, &retry_key, &newer_key));
    try std.testing.expectEqualStrings("new Message", try self.input.message(self.submission.intent.?.message));
    try std.testing.expectEqual(@as(u64, 2), self.admission.sent);
    try self.settleMessageForRetryTest(true);
    try std.testing.expect(self.submission.intent == null and self.retry_fence == null);
    try std.testing.expectEqualSlices(u8, &newer_key, &self.submission.accepted.?.key);
    try std.testing.expectEqual(@as(u64, 2), self.admission.sent);
}

test "failed reply rejected Message then discard supersedes pending retry but a fresh fence retries the unchanged ending" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    const self = &held.self;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    const ending = self.live.latest_ending.?;
    const original = self.retryable().?;
    try held.keys("\x12");
    try RetryFenceWorker.start(self);
    try held.keys("rejected Message\rkept éZ\x1b[D");
    const draft = self.input.snapshot();
    try std.testing.expect(!self.reader.completed());
    try self.settleMessageForRetryTest(false);
    try std.testing.expectEqual(original_state.State.rejected, self.submission.state);
    try self.slashCommand("/discard");
    try std.testing.expect(self.submission.intent == null);
    try RetryFenceWorker.complete(self);
    try self.settleReader();
    // Discard removes the submission hold, not the old gesture's supersession.
    try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
    try std.testing.expect(self.submission.intent == null and self.retry_fence == null);
    const fresh = self.retryable().?;
    try std.testing.expectEqualDeep(original.ending, fresh.ending);
    try std.testing.expectEqual(original.sent + 1, fresh.sent);
    try std.testing.expectEqualDeep(ending, self.live.latest_ending.?);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r retries") != null);
    try held.keys("\x12");
    try std.testing.expectEqualDeep(fresh, self.retry_fence.?);
    try self.stageRetryForTest(.{ .message = .{ .ending = ending.key, .position = 2, .length = RetryFenceWorker.text.len } });
    try self.settleReader();
    try std.testing.expectEqualStrings(RetryFenceWorker.text, try self.input.message(self.submission.intent.?.message));
    try std.testing.expectEqual(@as(u64, 2), self.admission.sent);
    try std.testing.expectEqualDeep(draft, self.input.snapshot());
}

test "failed reply reopening during newer work hides retry tail and ignores Ctrl-R and click" {
    const ending: reads.LatestEnding = .{ .key = .{ .position = 3 }, .cause = @import("marks.zig").cause("malformed_provider_output") };
    for ([_]bool{ false, true }) |queued| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try seedFeed(held.screen, "× Model reply unreadable\n");
        self.reading.opening = true;
        _ = self.freeze(.activity);
        // An opening can find the old failure while the newer Turn has not
        // ended. No invocation-local submission history exists in this chat.
        self.job.result = .{
            .latest_ending = .{ .key = held.screen.feed.high.?, .cause = ending.cause },
            .work = .{ .work = .{ .state = if (queued) .{ .pending = .{ .since = 2 } } else .{ .working = .{ .since = 2 } }, .turn = 2 } },
            .queued = if (queued) .{ .count = 1, .oldest_position = 4, .newest_admission = 37, .newest_position = 4 } else .{},
        };
        try self.applyReader(.complete);
        try std.testing.expect(!self.reading.opening);
        try std.testing.expect(self.live.latest_ending != null);
        try std.testing.expect(self.retryable() == null);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "ctrl+r retries") == null);
        try held.keys("draft éZ\x1b[D\x12");
        const before = self.input.snapshot();
        var ctx = held.context();
        try appRetry(self, &ctx);
        try std.testing.expect(self.retry_fence == null);
        try std.testing.expect(self.reader.thread == null);
        try std.testing.expect(self.submission.intent == null);
        try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
        try std.testing.expectEqualDeep(before, self.input.snapshot());
    }
}

test "failed reply Ctrl-R schedules exact literal Message bytes without changing draft or caret" {
    for ([_][]const u8{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" }) |key| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        const io = std.testing.io;
        const file = try held.tmp.dir.createFile(io, "retry", .{ .read = true });
        defer file.close(io);
        self.files.scratch = file;
        const text = "//not a command\n\t café 💚\r\n";
        try file.writePositionalAll(io, text, 0);
        self.failedRetryForTest();
        try held.keys("draft éZ\x1b[D");
        const before = self.input.snapshot();
        const revision = self.input.revision;
        try held.keys(key);
        try std.testing.expect(self.reader.thread == null); // Key never reads synchronously.
        try std.testing.expectEqualDeep(self.live.latest_ending.?.key, self.retry_fence.?.ending);
        try self.stageRetryForTest(.{ .message = .{ .ending = self.live.latest_ending.?.key, .position = 2, .length = text.len } });
        const fence = self.retry_fence.?;
        try held.keys(key); // A repeated gesture cannot replace the read's fence.
        try std.testing.expectEqualDeep(fence, self.retry_fence.?);
        try self.settleReader();
        try std.testing.expect(self.submission.intent.? == .message);
        try std.testing.expectEqualStrings(text, try self.input.message(self.submission.intent.?.message));
        try std.testing.expectEqualDeep(before, self.input.snapshot());
        try std.testing.expectEqual(revision, self.input.revision);
        try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
        try std.testing.expect(self.retryable() == null);
        _ = self.submission.join();
        self.submission.close();
        try self.input.release(self.submission.intent.?.message);
        self.submission.intent = null;
        // This fixture has no Host: no Message was admitted. Releasing an
        // unsent original must not suppress the unchanged failed ending.
        try std.testing.expect(self.retryable() != null);
    }
}

test "failed reply retry stale and every Message state refusal send nothing" {
    for ([_]?reads.RetryFailure{ null, .no_message, .too_large }) |failure| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.failedRetryForTest();
        try held.keys("kept\x1b[D\x12");
        const before = self.input.snapshot();
        try self.stageRetryForTest(if (failure) |reason| .{ .failure = reason } else .{ .message = .{ .ending = self.live.latest_ending.?.key, .position = 2, .length = 20 } });
        if (failure == null) self.live.latest_ending.?.key.ordinal += 1;
        try self.settleReader();
        try std.testing.expect(self.submission.intent == null);
        try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
        try std.testing.expectEqualDeep(before, self.input.snapshot());
        if (failure != null) try std.testing.expect(std.mem.endsWith(u8, self.notice.?, "Nothing sent."));
    }
}

test "failed reply retry completion revalidates every submission hold" {
    const Host = struct {
        fn held(_: *anyopaque) bool {
            return true;
        }
        fn lost(_: *anyopaque) void {}
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return false;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
    };
    const Hold = enum { original, action, prepared, opening, command, queued_command, upgrade, working, queued, host };
    for (std.enums.values(Hold)) |hold| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.failedRetryForTest();
        try held.keys("draft\x12");
        try self.stageRetryForTest(.{ .message = .{ .ending = self.live.latest_ending.?.key, .position = 2, .length = 20 } });
        switch (hold) {
            .original => self.submission.intent = .{ .decision = .{ .action = 1, .decision = .deny } },
            .action => self.live.work.first_action = 7,
            .prepared => self.reading.prepared_action = 7,
            .opening => self.reading.opening = true,
            .command => self.inspection.command_running = true,
            .queued_command => self.input.queueCommand("/requests"),
            .upgrade => held.upgrade = .{ .after = .blocked },
            .working => self.live.work.state = .{ .working = .{ .since = 2 } },
            .queued => self.live.queued.count = 1,
            .host => self.app_hooks.host = .{ .context = self, .held = Host.held, .lost = Host.lost, .start = Host.start, .notice = Host.notice },
        }
        try self.settleReader();
        try std.testing.expect(self.retryable() == null);
        try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
        try std.testing.expect(self.submission.intent == null or hold == .original);
        try std.testing.expectEqualStrings("draft", self.input.composition().bytes);
        self.submission.intent = null;
    }
}

test "failed reply retry tail follows only the latest ending and frontend eligibility" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    var shown = try held.shown();
    errdefer std.debug.print("retry tail screen:\n{s}\n", .{shown});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shown, "ctrl+r retries"));
    try std.testing.expect(std.mem.indexOf(u8, shown, "× Model reply unreadable · ctrl+r retries") != null);
    self.submission.intent = .{ .decision = .{ .action = 1, .decision = .deny } };
    shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "× Model reply unreadable · ctrl+r retries") == null);
    self.submission.intent = null;
    self.live.latest_ending.?.cause = @import("marks.zig").cause("provider_quota");
    shown = try held.shown();
    try std.testing.expect(std.mem.indexOf(u8, shown, "× Model reply unreadable · ctrl+r retries") == null);
}

test "failed reply retry gesture waits behind a reader and drops every superseded fence" {
    const Worker = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn ready(task: *Task) bool {
            return release.load(.acquire) or task.cancellation.stopped.load(.acquire);
        }
        fn run(_: *anyopaque, task: *Task) !void {
            try test_poll.waitUntil(task.io, test_poll.after(task.io, .fromSeconds(10)), task, ready);
        }
    };
    for ([_]enum { position, ordinal, message }{ .position, .ordinal, .message }) |changed| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.failedRetryForTest();
        Worker.release.store(false, .release);
        try self.launch(self.freeze(.activity), Worker.run);
        defer {
            Worker.release.store(true, .release);
            self.reader.join() catch {};
        }
        try held.keys("\x12");
        const requested = self.retry_fence.?;
        try self.startRetry();
        try std.testing.expectEqualDeep(requested, self.retry_fence.?);
        try std.testing.expect(self.job.retry == null);
        switch (changed) {
            .position => self.live.latest_ending.?.key.position += 1,
            .ordinal => self.live.latest_ending.?.key.ordinal += 1,
            .message => {
                try self.beginMessage(.{ .message = self.input.submitText("new Message") });
                try self.settleMessageForRetryTest(false);
                try self.slashCommand("/discard");
            },
        }
        Worker.release.store(true, .release);
        try self.reader.join();
        try self.startRetry();
        try std.testing.expectEqualDeep(@as(?feed_window.Key, null), self.job.retry);
        try std.testing.expect(self.retry_fence == null and self.reader.thread == null);
        try std.testing.expect(self.submission.intent == null);
    }
}

test "SessionFrontend backward fill supplies the scan replay boundary through the production handoff" {
    // Queued Admissions can be hidden while work holds the queue or echoed
    // while idle. Both are provisional rows, even outside the opening page.
    for ([_][]const u8{ "", "› queued\n" }) |pending| {
        const fixture = try FeedFixture.create();
        defer fixture.destroy();
        const held = fixture.held;
        try fixture.page(.opening, &.{ .{ .key = 100, .text = "older answer\n" }, .{ .key = 110, .text = "settled turn\n" } }, false, true);
        const scan = held.self.live.scan;
        try fixture.page(.fill_above, &.{.{ .key = 90, .text = pending, .provisional = true }}, true, false);
        try std.testing.expectEqualDeep(scan, held.self.live.scan);
        const replay: feed_window.Key = .{ .position = 90 };
        try std.testing.expectEqualDeep(@as(?feed_window.Key, replay), held.screen.feed.firstProvisional());
        const planned = FeedPolicy.request(.scan, held.self.feedState()).?;
        try std.testing.expectEqualDeep(@as(?feed_window.Key, replay), planned.from);
        try std.testing.expectEqualDeep(@as(?feed_window.Key, replay), planned.replace_from);
        try fixture.page(.scan, &.{ .{ .key = 100, .text = "older answer\n" }, .{ .key = 110, .text = "settled turn\n" }, .{ .key = 120, .text = "› applied\n" }, .{ .key = 130, .text = "new assistant answer\n" } }, true, true);
        try std.testing.expect(held.screen.feed.firstProvisional() == null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, held.screen.feed.document.text(), "older answer"));
        try std.testing.expectEqual(@as(usize, 4), held.screen.feed.count);
        try std.testing.expect(held.screen.feed.at_end);
        try std.testing.expectEqual(@as(usize, 0), held.self.new_below);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "new assistant answer") != null);
    }
}

test "SessionFrontend scan after provisional eviction appends without an obsolete replay boundary" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    try fixture.page(.opening, &.{ .{ .key = 100, .text = "older answer\n" }, .{ .key = 110, .text = "settled turn\n" } }, false, true);
    try fixture.page(.fill_above, &.{.{ .key = 90, .text = "", .provisional = true }}, true, false);
    const high = held.screen.feed.high;
    held.screen.feed.trim(1, 0);
    try std.testing.expect(held.screen.feed.firstProvisional() == null);
    try std.testing.expectEqualDeep(high, held.screen.feed.high);
    const planned = FeedPolicy.request(.scan, held.self.feedState()).?;
    try std.testing.expect(planned.replace_from == null);
    try std.testing.expectEqualDeep(high, planned.from);
    try fixture.page(.scan, &.{.{ .key = 120, .text = "answer after eviction\n" }}, false, true);
    try std.testing.expectEqual(@as(usize, 3), held.screen.feed.count);
    try std.testing.expect(held.screen.feed.at_end);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "answer after eviction") != null);
}

test "SessionFrontend feed press and drag hold both loading edges until release while scans continue" {
    for ([_]@FieldType(FeedPolicy.State, "need"){ .above, .below }) |edge| {
        const fixture = try FeedFixture.create();
        defer fixture.destroy();
        const held = fixture.held;
        var words: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&words);
        for (0..60) |line| try out.print("selection line {d:0>2}\n", .{line});
        try fixture.page(.opening, &.{.{ .key = 100, .text = out.buffered() }}, edge == .below, edge == .above);
        if (edge == .above) try held.self.scroll(false, 1000);
        _ = try held.draw();
        held.self.poll_at = std.math.maxInt(i96);
        try std.testing.expectEqual(edge, held.self.feedState().need);
        const fill: feed_reads.Read = if (edge == .above) .fill_above else .fill_below;
        try std.testing.expectEqual(fill, FeedPolicy.nextRead(held.self.feedState()).?);
        var ctx = held.context();
        for ([_]vaxis.Mouse{
            .{ .col = 0, .row = 1, .button = .left, .mods = .{}, .type = .press },
            .{ .col = 4, .row = 2, .button = .left, .mods = .{}, .type = .drag },
            .{ .col = 4, .row = 2, .button = .left, .mods = .{}, .type = .release },
        }) |mouse| {
            try held.self.app_content.widget().handleEvent(&ctx, .{ .mouse = mouse });
            try std.testing.expectEqual(mouse.type != .release, held.self.app_content.dragging());
            try std.testing.expectEqual(if (mouse.type == .release) @as(?feed_reads.Read, fill) else null, FeedPolicy.nextRead(held.self.feedState()));
            held.self.poll_at = 0;
            try std.testing.expectEqual(feed_reads.Read.scan, FeedPolicy.nextRead(held.self.feedState()).?);
            held.self.poll_at = std.math.maxInt(i96);
        }
    }
}

/// Answers one reader request on a fixture Store socket.
const FakeHost = struct {
    fn respond(listener: *std.Io.net.Server, route: []const u8, kind: []const u8, extra: []const u8, body: []const u8) !void {
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
        var header: [512]u8 = undefined;
        var writer = peer.writer(std.testing.io, &.{});
        try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{ kind, body.len, extra }));
        try writer.interface.writeAll(body);
    }
    fn completed(frontend: *Self) !bool {
        return frontend.reader.completed();
    }
};

test "SessionFrontend capped answer Ctrl-O opens the whole authenticated source" {
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
    const scratch = try held.tmp.dir.createFile(io, "message-source", .{ .read = true });
    defer scratch.close(io);
    const inspection = try held.tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer inspection.close(io);
    self.files = .{ .scratch = scratch, .action = inspection, .inspection = inspection, .details = inspection, .actions = .{ inspection, inspection } };
    self.store = root;
    self.session = "k7m2qx";
    self.line.read = .{ .revision = 1, .end = 1 };
    self.reading.opening = true;
    defer {
        self.reader.cancel();
        self.reader.join() catch |err| switch (err) {
            error.Cancelled => {},
            else => @panic(@errorName(err)),
        };
    }
    const source = try std.testing.allocator.alloc(u8, feed_window.row_capacity + 500);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    @memcpy(source[source.len - 12 ..], "WHOLE answer");
    var hash = protocol.contentHasher();
    hash.update(source);
    const reference: protocol.ActivityItem.Content = .{ .length = source.len, .digest = hash.finalResult() };
    var facts: protocol.ActivityFacts = .{ .end = 1, .direction = .backward, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/");
    facts.items[0] = .{ .position = 1, .ordinal = 0, .at = 1, .value = .{ .assistant = .{ .content = reference, .final = true } } };
    facts.count = 1;
    var page_buffer: [4096]u8 = undefined;
    var page = std.Io.Writer.fixed(&page_buffer);
    try activity_reply.writePage(&page, &facts);
    var extra_buffer: [128]u8 = undefined;
    const extra = try std.fmt.bufPrint(&extra_buffer, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ source.len, source.len });
    _ = try self.update();
    try FakeHost.respond(&listener, "/v1/activity-page", "application/json", "", page.buffered());
    try FakeHost.respond(&listener, "/v1/activity-content", "application/octet-stream", extra, source);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, FakeHost.completed);
    try self.settleReader();
    self.poll_at = std.math.maxInt(i96);
    try std.testing.expect(held.screen.feed.at_start and held.screen.feed.at_end);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "More") != null);
    try std.testing.expect(std.mem.indexOf(u8, held.screen.feed.document.text(), "WHOLE answer") == null);
    try held.keys("\x0f");
    try held.settle();
    try std.testing.expect(self.expansion.queued == .ready);
    try std.testing.expectEqualDeep(reference, self.expansion.queued.ready.target.message.content);
    _ = try self.update();
    try std.testing.expectEqual(ReadPhase.message, self.reading.phase);
    try FakeHost.respond(&listener, "/v1/activity-content", "application/octet-stream", extra, source);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, FakeHost.completed);
    try self.settleReader();
    try std.testing.expectEqual(.message, held.screen.view);
    try std.testing.expect(std.mem.indexOf(u8, held.screen.staging.text(), source) != null);
}

test "SessionFrontend tool row Ctrl-O opens saved output in place, closes it, and reloads it open" {
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
    var listener = try (try std.Io.net.UnixAddress.init(lease.paths.socket.slice())).listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, lease.paths.socket.slice()) catch @panic("unable to remove fixture socket");
    }
    const scratch = try held.tmp.dir.createFile(io, "tool-source", .{ .read = true });
    defer scratch.close(io);
    const inspection = try held.tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer inspection.close(io);
    self.files = .{ .scratch = scratch, .action = inspection, .inspection = inspection, .details = inspection, .actions = .{ inspection, inspection } };
    self.store = root;
    self.session = "k7m2qx";
    self.line.read = .{ .revision = 1, .end = 2 };
    self.reading.opening = true;
    defer {
        self.reader.cancel();
        self.reader.join() catch |err| switch (err) {
            error.Cancelled => {},
            else => @panic(@errorName(err)),
        };
    }
    const saved = "README.md\nbad \x1b[2J\n";
    const answer = "Listed.";
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("List project files");
    var facts: protocol.ActivityFacts = .{ .end = 2, .direction = .backward, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/");
    const tool: protocol.ActivityItem = .{ .position = 1, .ordinal = 1, .at = 1, .value = .{ .tool_result = .{ .content = .{ .length = saved.len, .digest = protocol.contentDigest(saved) }, .presentation = .{ .description = description, .code = .succeeded, .publication_position = 1 } } } };
    facts.items[0] = .{ .position = 2, .ordinal = 0, .at = 1, .value = .{ .assistant = .{ .content = .{ .length = answer.len, .digest = protocol.contentDigest(answer) }, .final = true } } };
    facts.items[1] = tool;
    facts.count = 2;
    var opening_buffer: [4096]u8 = undefined;
    var opening = std.Io.Writer.fixed(&opening_buffer);
    try activity_reply.writePage(&opening, &facts);
    // The toggle reads that one row again, forward.
    facts.direction = .forward;
    facts.items[0] = tool;
    facts.count = 1;
    var row_buffer: [4096]u8 = undefined;
    var row = std.Io.Writer.fixed(&row_buffer);
    try activity_reply.writePage(&row, &facts);
    var extras: [2][128]u8 = undefined;
    const saved_extra = try std.fmt.bufPrint(&extras[0], "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ saved.len, saved.len });
    const answer_extra = try std.fmt.bufPrint(&extras[1], "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ answer.len, answer.len });
    const key: feed_window.Key = .{ .position = 1, .ordinal = 1 };
    const window = &held.screen.feed;
    const Step = struct {
        fn open(frontend: *Self, server: *std.Io.net.Server, page: []const u8, tool_extra: []const u8, text_extra: []const u8) !void {
            _ = try frontend.update();
            try FakeHost.respond(server, "/v1/activity-page", "application/json", "", page);
            try FakeHost.respond(server, "/v1/activity-content", "application/octet-stream", tool_extra, saved);
            try FakeHost.respond(server, "/v1/activity-content", "application/octet-stream", text_extra, answer);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), frontend, FakeHost.completed);
            try frontend.settleReader();
            frontend.poll_at = std.math.maxInt(i96);
        }
        fn toggle(frontend: *Self, server: *std.Io.net.Server, page: []const u8, tool_extra: []const u8) !void {
            _ = try frontend.update();
            try std.testing.expectEqual(ReadPhase.tool, frontend.reading.phase);
            try FakeHost.respond(server, "/v1/activity-page", "application/json", "", page);
            try FakeHost.respond(server, "/v1/activity-content", "application/octet-stream", tool_extra, saved);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), frontend, FakeHost.completed);
            try frontend.settleReader();
        }
    };
    try Step.open(self, &listener, opening.buffered(), saved_extra, answer_extra);
    const closed = try std.testing.allocator.dupe(u8, try held.shown());
    defer std.testing.allocator.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "List project files") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, "README.md") == null);
    // A click on the heading asks as Ctrl-O on the lowest tool row does.
    var ctx = held.context();
    try appClick(self, &ctx, .{ .key = key, .offset = 0 });
    try std.testing.expectEqualDeep(reads.Target{ .tool = .{ .key = key, .open = true } }, self.expansion.queued.ready.target);
    self.dropMessageRequest();
    try held.keys("\x0f");
    try held.settle();
    try std.testing.expectEqualDeep(reads.Target{ .tool = .{ .key = key, .open = true } }, self.expansion.queued.ready.target);
    // Nothing is open until the read lands.
    try std.testing.expect(!window.opened.has(key));
    try Step.toggle(self, &listener, row.buffered(), saved_extra);
    try std.testing.expect(window.opened.has(key));
    try std.testing.expect(window.document.toolIsOpen(window.entries[window.indexOf(key).?].offset));
    const opened = try std.testing.allocator.dupe(u8, try held.shown());
    defer std.testing.allocator.free(opened);
    // Saved bytes show indented under the heading, controls escaped, and the
    // answer after the row stays after it.
    try std.testing.expect(std.mem.indexOf(u8, opened, "    README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, opened, "    bad \\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, opened, "    README.md").? < std.mem.indexOf(u8, opened, answer).?);
    try std.testing.expect(held.screen.anchor.following());
    // Trimmed away and read again, the row comes back open.
    window.trim(window.count, 0);
    self.reading.opening = true;
    try Step.open(self, &listener, opening.buffered(), saved_extra, answer_extra);
    try std.testing.expectEqualStrings(opened, try held.shown());
    // Ctrl-O on the open row closes it: the frame before it opened.
    try held.keys("\x0f");
    try held.settle();
    try std.testing.expectEqualDeep(reads.Target{ .tool = .{ .key = key, .open = false } }, self.expansion.queued.ready.target);
    try Step.toggle(self, &listener, row.buffered(), saved_extra);
    try std.testing.expect(!window.opened.has(key));
    try std.testing.expectEqualStrings(closed, try held.shown());
    // A send before the read lands leaves the row as it was.
    try held.keys("\x0f");
    try held.settle();
    _ = try self.update();
    try self.beginMessage(.{ .message = self.input.submitText("sent while the row was read") });
    self.submission.cancel();
    _ = self.submission.join();
    self.submission.close();
    self.submission = .{ .io = io, .store = "unused", .session = "unused", .directory = self.directory, .input = &self.input, .environment = .empty };
    self.input.init();
    try FakeHost.respond(&listener, "/v1/activity-page", "application/json", "", row.buffered());
    try FakeHost.respond(&listener, "/v1/activity-content", "application/octet-stream", saved_extra, saved);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, FakeHost.completed);
    try self.settleReader();
    try std.testing.expect(!window.opened.has(key));
    try std.testing.expect(!window.document.toolIsOpen(window.entries[window.indexOf(key).?].offset));
    // With 64 rows open another opening is refused before any read, so no
    // open row is ever forgotten.
    var position: u64 = 100;
    while (!window.opened.full()) : (position += 1) window.opened.set(.{ .position = position }, true);
    try held.keys("\x0f");
    try held.settle();
    try std.testing.expect(self.expansion.queued == .none);
    try std.testing.expect(!window.opened.has(key));
}

test "SessionFrontend history physical feed geometry" {
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    var buffer: [4096]u8 = undefined;
    var words = std.Io.Writer.fixed(&buffer);
    for (0..100) |line| try words.print("History line{d:0>3}\n", .{line});
    try words.writeAll("TD4 history end\n");
    try fixture.page(.opening, &.{.{ .key = 1, .text = words.buffered() }}, true, true);
    // Every feed row sits one column in: the shell owns that gutter.
    const initial = try held.shown();
    try std.testing.expectEqual(@as(u16, 18), held.screen.height);
    var initial_rows = std.mem.splitScalar(u8, initial, '\n');
    for (83..100) |line| {
        var expected: [32]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, " History line{d:0>3}", .{line}), std.mem.trimEnd(u8, initial_rows.next().?, " "));
    }
    try std.testing.expectEqualStrings(" TD4 history end", std.mem.trimEnd(u8, initial_rows.next().?, " "));
    try held.keys("\x1b[5~");
    var older_rows = std.mem.splitScalar(u8, try held.shown(), '\n');
    for (74..92) |line| {
        var expected: [32]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, " History line{d:0>3}", .{line}), std.mem.trimEnd(u8, older_rows.next().?, " "));
    }
}

test "SessionFrontend End encodings return to end only when the editor delegates them" {
    const cases = [_]struct { bytes: []const u8, ctrl: bool = false }{
        .{ .bytes = "\x1b[F" },                  .{ .bytes = "\x1bOF" },                  .{ .bytes = "\x1b[4~" },
        .{ .bytes = "\x1b[1;5F", .ctrl = true }, .{ .bytes = "\x1b[4;5~", .ctrl = true },
    };
    for (cases) |encoded| {
        for ([_][]const u8{ "", "single line", "first line\nsecond line" }) |draft| {
            const fixture = try FeedFixture.create();
            defer fixture.destroy();
            const held = fixture.held;
            try fixture.longPage(.opening, 100);
            _ = try held.draw();
            try held.self.scroll(false, 9);
            try std.testing.expect(!held.screen.anchor.following());
            if (draft.len != 0) {
                try held.keys("\x1b[200~");
                try held.keys(draft);
                try held.keys("\x1b[201~\x1b[H");
            }
            const before = held.self.input.composition();
            const anchor = held.screen.anchor.anchor;
            try held.keys(encoded.bytes);
            try std.testing.expectEqualStrings(draft, held.self.input.composition().bytes);
            if (!encoded.ctrl and draft.len != 0) {
                // Ordinary End still edits the current draft line, without
                // stealing the conversation's reading position.
                try std.testing.expectEqual(draft.len, held.self.input.composition().cursor);
                try std.testing.expectEqualDeep(anchor, held.screen.anchor.anchor);
            } else {
                try std.testing.expect(held.screen.anchor.following());
                try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
                // Unlike Esc at end, repeated End never leaves the Session.
                try held.keys(encoded.bytes);
            }
            try std.testing.expect(held.self.leaving == null);
            try std.testing.expect(held.self.input.queuedCommand() == null);
            try std.testing.expect(held.self.submission.view() == null);
        }
    }
}

test "SessionFrontend close from browsed feed returns to end before saving the chat draft" {
    for ([_][]const u8{ "\x1b", "\x07" }) |close| {
        var drafts: session_drafts.Drafts = .{};
        defer drafts.deinit(std.testing.allocator);
        const text = "first\nαbeta";
        const caret = "first\nαbe".len;
        {
            const fixture = try FeedFixture.createWithDrafts("aaaaaa", &drafts);
            defer fixture.destroy();
            const held = fixture.held;
            try fixture.longPage(.opening, 100);
            try held.keys("\x1b[200~" ++ text ++ "\x1b[201~\x1b[D\x1b[D");
            _ = try held.draw();
            try held.self.scroll(false, 18);
            try std.testing.expect(!held.screen.anchor.following());
            try held.keys(close);
            try std.testing.expect(held.screen.anchor.following());
            try std.testing.expect(held.left == null);
            try std.testing.expectEqualStrings(text, held.self.input.composition().bytes);
            try std.testing.expectEqual(caret, held.self.input.composition().cursor);
            try std.testing.expect(drafts.take(std.testing.allocator, "aaaaaa") == null);
            try held.keys(close);
            try std.testing.expectEqual(@as(?Outcome, .returned), held.left);
        }
        const reopened = try HeldFrontend.createWithDrafts("aaaaaa", &drafts);
        defer reopened.destroy();
        try std.testing.expectEqualStrings(text, reopened.self.input.composition().bytes);
        try std.testing.expectEqual(caret, reopened.self.input.composition().cursor);
    }
}

/// Find the key's first painted cell using an independent literal Document,
/// not the production EndingLine decorator or hit query.
fn retryCellForTest(self: *Self) !struct { row: i16, col: i16 } {
    const text = "× Model reply unreadable · ctrl+r retries\n";
    const start = std.mem.indexOf(u8, text, "ctrl+r retries").?;
    const width = self.app_content.drawn.width;
    var expected: viewport.Sized(128, true) = .{ .sidenotes = true, .quotes = true };
    try expected.append(text);
    try expected.prepare();
    const height = expected.lineRows(.{ .width = width, .method = self.app_content.method }, 0);
    const cells = try std.testing.allocator.alloc(vaxis.Cell, @as(usize, height) * width);
    defer std.testing.allocator.free(cells);
    @memset(cells, .{});
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = self.app_content.method, .buf = cells };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    _ = expected.draw(win, .{}, true, false, .{}, .{});
    for (cells, 0..) |cell, index| if (expected.cellOffset(cell) == start) return .{ .row = @intCast(self.app_content.drawn.pad + index / width), .col = @intCast(index % width) };
    return error.RetryKeyNotDrawn;
}

test "failed reply retry click schedules the same exact Message with draft and caret kept at wide and wrapped widths" {
    for ([_]u16{ 16, 80 }) |width| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.size.width = width;
        const self = &held.self;
        const file = try held.tmp.dir.createFile(std.testing.io, "retry-click", .{ .read = true });
        defer file.close(std.testing.io);
        self.files.scratch = file;
        const text = "/literal\n\t café 💚\r\n";
        try file.writePositionalAll(std.testing.io, text, 0);
        try seedFeed(held.screen, "× Model reply unreadable\n");
        self.failedRetryForTest();
        self.live.latest_ending.?.key = held.screen.feed.high.?;
        try held.keys("draft éZ\x1b[D");
        const before = self.input.snapshot();
        _ = try held.draw();
        const at = try self.retryCellForTest();
        var ctx = held.context();
        const content = self.app_content.widget();
        try content.handleEvent(&ctx, .{ .mouse = .{ .row = at.row, .col = at.col, .button = .left, .mods = .{}, .type = .press } });
        try std.testing.expect(self.retry_fence == null);
        try content.handleEvent(&ctx, .{ .mouse = .{ .row = at.row, .col = at.col, .button = .left, .mods = .{}, .type = .release } });
        try std.testing.expect(self.reader.thread == null); // A click schedules, never blocks on a read.
        try std.testing.expectEqualDeep(self.live.latest_ending.?.key, self.retry_fence.?.ending);
        try self.stageRetryForTest(.{ .message = .{ .ending = self.live.latest_ending.?.key, .position = 1, .length = text.len } });
        try self.settleReader();
        try std.testing.expect(self.submission.intent.? == .message);
        try std.testing.expectEqualStrings(text, try self.input.message(self.submission.intent.?.message));
        try std.testing.expectEqualDeep(before, self.input.snapshot());
        try std.testing.expectEqual(@as(u64, 1), self.admission.sent);
        try std.testing.expect(self.retryable() == null);
    }
}

test "failed reply retry click revalidates the frontend predicate before scheduling" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    _ = try held.draw();
    const at = try self.retryCellForTest();
    var ctx = held.context();
    const content = self.app_content.widget();
    try content.handleEvent(&ctx, .{ .mouse = .{ .row = at.row, .col = at.col, .button = .left, .mods = .{}, .type = .press } });
    // No redraw: FeedView's frame still offers the link, but admission changed.
    self.submission.intent = .{ .decision = .{ .action = 7, .decision = .deny } };
    defer self.submission.intent = null;
    try content.handleEvent(&ctx, .{ .mouse = .{ .row = at.row, .col = at.col, .button = .left, .mods = .{}, .type = .release } });
    try std.testing.expect(self.retry_fence == null and self.reader.thread == null);
    try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
}

const RetrySettlementWorker = struct {
    fn cancelled(_: *anyopaque, task: *Task) !void {
        try test_poll.waitUntil(task.io, test_poll.after(task.io, .fromSeconds(10)), &task.cancellation.stopped, test_poll.isSet);
        return error.Cancelled;
    }
    fn transport(_: *anyopaque, _: *Task) !void {
        return error.ConnectionResetByPeer;
    }
    fn host(_: *anyopaque, task: *Task) !void {
        return diagnostic(task, "retry_busy");
    }
    fn store(_: *anyopaque, task: *Task) !void {
        return diagnostic(task, "canonical_store_failure");
    }
    fn diagnostic(task: *Task, code: []const u8) !void {
        var failure: protocol_reply.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
        try failure.diagnostic.type.set("busy\x1b\n");
        try failure.diagnostic.code.set(code);
        return task.requests().failRead(failure);
    }
    fn idle(_: *anyopaque, _: *Task) !void {}
    fn completed(task: *Task) bool {
        return task.completed();
    }
    fn settled(self: *Self) !bool {
        _ = try self.update();
        return self.reader.thread == null and self.input.queuedCommand() == null and !self.inspection.command_running;
    }
    fn requests(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, out: *std.Io.Writer, _: *reads.SavedRequests) !void {
        try out.writeAll("RETRY-REQUESTS-PAGE\n");
    }
};

/// Freeze the real retry phase while substituting just the worker's I/O.
fn launchRetrySettlementForTest(self: *Self, worker: Task.Run) !void {
    const fence = self.retry_fence.?;
    const job = self.freeze(.retry);
    job.retry = fence.ending;
    try self.launch(job, worker);
}

test "failed reply retry reader keeps every read failure at the shared settlement boundary" {
    const Host = struct {
        frontend: *Self,
        listener: *std.Io.net.Server,
        fault: Fault,
        target: Stage,
        requests: usize = 0,
        losses: usize = 0,
        const Stage = enum { head, admission, content };
        const Fault = enum { canonical, fenced, refused, truncated, invalid, length, digest, cancelled };
        const text = "last literal Message";

        fn code(fault: Fault) ?[]const u8 {
            return switch (fault) {
                .canonical => "canonical_store_failure",
                .fenced => "dispatch_fenced",
                .refused => "ContentNotFound",
                else => null,
            };
        }
        fn failure(fault: Fault) anyerror {
            return switch (fault) {
                .canonical => error.CanonicalStoreFailure,
                .fenced, .refused => error.HostInvocationFailed,
                .truncated => error.TruncatedResponse,
                .invalid => error.InvalidResponse,
                .length, .digest => error.ContentBindingMismatch,
                .cancelled => error.Cancelled,
            };
        }
        fn held(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.losses != 0;
        }
        fn lost(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.losses += 1;
        }
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return error.TestUnexpectedResult;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
        fn pump(host: *@This()) !bool {
            const io = std.testing.io;
            var fds = [_]std.posix.pollfd{.{ .fd = host.listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 0) != 0) {
                const peer = try host.listener.accept(io);
                defer peer.close(io);
                var request: [4096]u8 = undefined;
                var used: usize = 0;
                while (true) {
                    const got = try std.posix.read(peer.socket.handle, request[used..]);
                    if (got == 0) return error.UnexpectedEof;
                    used += got;
                    if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |end| {
                        const start_at = std.mem.indexOf(u8, request[0..end], "Content-Length: ").? + "Content-Length: ".len;
                        const finish = std.mem.indexOfScalarPos(u8, request[0..end], start_at, '\r').?;
                        if (used == end + 4 + try std.fmt.parseInt(usize, request[start_at..finish], 10)) break;
                    }
                }
                const stage: Stage = switch (host.requests) {
                    0 => .head,
                    1 => .admission,
                    2 => .content,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectStringStartsWith(request[0..used], if (stage == .content) "POST /v1/activity-content " else "POST /v1/activity-page ");
                // Record the observed boundary before replying, closing or cancelling.
                host.requests += 1;
                const failing = stage == host.target;
                if (failing and host.fault == .cancelled) {
                    host.frontend.reader.cancel();
                    return host.frontend.reader.completed();
                }
                var buffer: [4096]u8 = undefined;
                var out = std.Io.Writer.fixed(&buffer);
                var extra_buffer: [128]u8 = undefined;
                var extra: []const u8 = "";
                var kind: []const u8 = "application/json";
                const status: []const u8 = if (!failing) "200 OK" else switch (host.fault) {
                    .canonical => "500 Internal Server Error",
                    .fenced => "503 Service Unavailable",
                    .refused => "409 Conflict",
                    else => "200 OK",
                };
                if (failing and code(host.fault) != null) {
                    try protocol.writeShape(&out, protocol.error_reply, .{ switch (host.fault) {
                        .canonical => protocol.ErrorType.invocation_error,
                        .fenced => protocol.ErrorType.busy,
                        .refused => protocol.ErrorType.activity_unavailable,
                        else => unreachable,
                    }, code(host.fault).? });
                } else if (stage == .content) {
                    kind = if (failing and host.fault == .invalid) "text/plain" else "application/octet-stream";
                    extra = try std.fmt.bufPrint(&extra_buffer, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ text.len, text.len });
                    try out.writeAll(if (failing and host.fault == .digest) "LOST literal Message" else text);
                } else {
                    var facts: protocol.ActivityFacts = .{ .end = 3, .direction = .backward, .count = 1, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
                    try facts.work.workspace.set("/");
                    const reference: protocol.ActivityItem.Content = .{ .length = text.len + @intFromBool(host.fault == .length), .digest = protocol.contentDigest(text) };
                    facts.items[0] = .{ .position = if (stage == .head) 3 else 2, .at = 1, .value = .{ .admission = .{ .admission = 2, .key = .{}, .turn = null, .state = .queued, .content = reference, .admitted_at = 1 } } };
                    if (stage == .head) {
                        var ending: protocol.ActivityItem.TurnEnded = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .turn = 1, .operation = 1, .ending = .failed, .code = .{}, .content = null };
                        try ending.code.set("malformed_provider_output");
                        facts.items[0].value = .{ .turn_ended = ending };
                    }
                    try activity_reply.writePage(&out, &facts);
                }
                var header: [512]u8 = undefined;
                var writer = peer.writer(io, &.{});
                try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{ status, kind, out.buffered().len, extra }));
                const body = out.buffered();
                try writer.interface.writeAll(if (failing and host.fault == .truncated) body[0..1] else body);
            }
            return host.frontend.reader.completed();
        }
    };
    const io = std.testing.io;
    for (std.enums.values(Host.Fault)) |fault| for (std.enums.values(Host.Stage)) |target| {
        if ((fault == .invalid or fault == .length or fault == .digest) and target != .content) continue;
        for ([_]bool{ false, true }) |app| for ([_]bool{ false, true }) |superseded| {
            if (superseded and fault != .cancelled) continue;
            errdefer std.debug.print("retry fault={s}, target={s}, app={}, superseded={}\n", .{ @tagName(fault), @tagName(target), app, superseded });
            const fixture = try FeedFixture.create();
            defer fixture.destroy();
            const held = fixture.held;
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
            self.store = root;
            self.session = "k7m2qx";
            self.failedRetryForTest();
            self.live.latest_ending.?.key = .{ .position = 3 };
            var host: Host = .{ .frontend = self, .listener = &listener, .fault = fault, .target = target };
            if (app) self.app_hooks.host = .{ .context = &host, .held = Host.held, .lost = Host.lost, .start = Host.start, .notice = Host.notice };
            defer self.app_hooks.host = null;
            defer {
                self.reader.cancel();
                // On an assertion failure, reap without replacing that failure.
                self.reader.join() catch {};
            }
            try held.keys("kept éZ\x1b[D\x12");
            const before = self.input.snapshot();
            try self.startRetry(); // The production worker, not a synthesized completion.
            if (superseded) self.input.queueCommand("/requests");
            try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &host, Host.pump);
            const loss = app and (fault == .fenced or fault == .truncated);
            if (loss or superseded) {
                try self.settleReader();
            } else try std.testing.expectError(Host.failure(fault), self.settleReader());
            try std.testing.expectEqual(@as(usize, @backingInt(target) + 1), host.requests);
            try std.testing.expectError(Host.failure(fault), self.reader.result.outcome.?);
            try std.testing.expectEqual(if (fault == .truncated) client.FailureOrigin.host_transport else .local, self.reader.result.failure_origin);
            try std.testing.expectEqual(@as(usize, @intFromBool(loss)), host.losses);
            try std.testing.expect(self.reader.thread == null and self.reader.read_failure == null);
            try std.testing.expect(self.retry_fence == null and self.job.retry == null and self.submission.intent == null);
            try std.testing.expectEqual(ReadPhase.activity, self.reading.phase);
            try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
            try std.testing.expectEqualDeep(before, self.input.snapshot());
            try std.testing.expect(self.notice == null and self.leaving == null);
            if (!loss and Host.code(fault) != null) {
                const pending = self.reading.pending_diagnostic.?;
                try std.testing.expectEqual(ReadPhase.retry, pending.phase);
                try std.testing.expect(!pending.recoverable);
                try std.testing.expectEqualStrings(Host.code(fault).?, pending.failure.diagnostic.code.slice());
                var bytes: [512]u8 = undefined;
                var out = std.Io.Writer.fixed(&bytes);
                try self.writePendingDiagnostic(&out);
                try std.testing.expect(std.mem.endsWith(u8, out.buffered(), Host.code(fault).?));
            } else try std.testing.expect(self.reading.pending_diagnostic == null);
            if (loss) try std.testing.expectEqual(@as(i64, 0), self.poll_at);
        };
    };
}

test "failed reply retry settlement lets queued inspections cancel the read and run without sending" {
    const io = std.testing.io;
    const command = "/requests";
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer file.close(io);
    self.files.inspection = file;
    self.requests = RetrySettlementWorker.requests;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    try held.keys("\x12");
    try self.launchRetrySettlementForTest(RetrySettlementWorker.cancelled);
    try held.keys(command);
    try held.keys("\rdraft éZ\x1b[D");
    const before = self.input.snapshot();
    try std.testing.expectEqualStrings(command, self.input.queuedCommand().?);
    try std.testing.expect(self.retryable() == null);
    // Drive update's actual cancel -> join -> next-command launch sequence.
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), self, RetrySettlementWorker.settled);
    try std.testing.expect(self.reader.thread == null and self.job.retry == null and self.retry_fence == null);
    try std.testing.expect(self.leaving == null and held.left == null);
    try std.testing.expect(self.submission.intent == null);
    try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
    try std.testing.expectEqualDeep(before, self.input.snapshot());
    try std.testing.expectEqual(@as(@TypeOf(self.screen.view), .inspection), self.screen.view);
    try std.testing.expect(std.mem.indexOf(u8, self.screen.browsing.text(), "RETRY-REQUESTS-PAGE") != null);
    try held.keys("\x07");
    try std.testing.expect(self.retryable() != null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "× Model reply unreadable · ctrl+r retries") != null);
}

test "failed reply retry settlement accepts upgrade cancellation and returns the tail after reobservation" {
    const io = std.testing.io;
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try seedFeed(held.screen, "× Model reply unreadable\n");
    self.failedRetryForTest();
    self.live.latest_ending.?.key = held.screen.feed.high.?;
    const ending = self.live.latest_ending;
    try held.keys("draft éZ\x1b[D\x12");
    const before = self.input.snapshot();
    try self.launchRetrySettlementForTest(RetrySettlementWorker.cancelled);
    held.upgrade = .{ .run = .checking };
    try std.testing.expectEqual(Updated.waiting, try self.update());
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), self, RetrySettlementWorker.settled);
    try std.testing.expectEqual(Updated.waiting, try self.update());
    try std.testing.expect(self.reader.thread == null and self.job.retry == null and self.retry_fence == null);
    try std.testing.expectEqual(ReadPhase.activity, self.reading.phase);
    try std.testing.expect(self.submission.intent == null and self.leaving == null);
    try std.testing.expect(self.retryable() == null);
    try std.testing.expectEqualDeep(before, self.input.snapshot());
    try std.testing.expectEqual(@as(u64, 0), self.admission.sent);
    // Host work resumes only after the normal observation clears the stale hold.
    held.upgrade = .{};
    const job = self.freeze(.activity);
    self.reading.feed_read = .scan;
    job.result.latest_ending = ending;
    try self.applyReader(.complete);
    try std.testing.expect(self.retryable() != null);
    try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "× Model reply unreadable · ctrl+r retries") != null);
}

test "failed reply retry settlement preserves fatal Host diagnostics across supersession and worker reset" {
    const io = std.testing.io;
    const Context = enum { active, inspection, upgrade };
    for ([_]struct { Task.Run, anyerror, []const u8 }{
        .{ RetrySettlementWorker.host, error.HostInvocationFailed, "retry_busy" },
        .{ RetrySettlementWorker.store, error.CanonicalStoreFailure, "canonical_store_failure" },
    }) |case| for (std.enums.values(Context)) |context| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.failedRetryForTest();
        try held.keys("draft éZ\x1b[D\x12");
        const before = self.input.snapshot();
        try self.launchRetrySettlementForTest(case[0]);
        switch (context) {
            .active => {},
            .inspection => self.input.queueCommand("/requests"),
            .upgrade => held.upgrade = .{ .run = .checking },
        }
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &self.reader, RetrySettlementWorker.completed);
        try std.testing.expectError(case[1], self.settleReader());
        try std.testing.expect(self.reader.read_failure == null);
        const pending = self.reading.pending_diagnostic.?;
        try std.testing.expectEqual(ReadPhase.retry, pending.phase);
        try std.testing.expect(!pending.recoverable);
        try std.testing.expectEqual(@as(u16, 503), pending.failure.status);
        try std.testing.expectEqualStrings("busy\x1b\n", pending.failure.diagnostic.type.slice());
        try std.testing.expectEqualStrings(case[2], pending.failure.diagnostic.code.slice());
        try std.testing.expect(self.job.retry == null and self.submission.intent == null and self.retry_fence == null);
        try std.testing.expectEqualDeep(before, self.input.snapshot());
        // A Task reset must not destroy the diagnostic already owned by the UI.
        try self.reader.start(io, &self.job, RetrySettlementWorker.idle);
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &self.reader, RetrySettlementWorker.completed);
        try std.testing.expect(self.joinReader() == .complete);
        var bytes: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        try self.writePendingDiagnostic(&out);
        try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP 503; type: busy\\x1b\\n; code: "));
        try std.testing.expect(std.mem.endsWith(u8, out.buffered(), case[2]));
        const settled = self.settle({});
        try std.testing.expectEqual(case[1], settled.failure(.final_exit, case[1]).?);
        try std.testing.expect(self.reading.pending_diagnostic != null);
    };
}

test "failed reply retry settlement propagates transport errors and unexpected active cancellation" {
    const io = std.testing.io;
    for ([_]struct { Task.Run, anyerror }{
        .{ RetrySettlementWorker.transport, error.ConnectionResetByPeer },
        .{ RetrySettlementWorker.cancelled, error.Cancelled },
    }) |case| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.failedRetryForTest();
        try held.keys("\x12");
        try self.launchRetrySettlementForTest(case[0]);
        if (case[1] == error.Cancelled) self.reader.cancel();
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &self.reader, RetrySettlementWorker.completed);
        try std.testing.expectError(case[1], self.settleReader());
        try std.testing.expect(self.submission.intent == null and self.job.retry == null and self.retry_fence == null);
        try std.testing.expect(self.reading.pending_diagnostic == null);
    }
}

test "SessionFrontend fixed and growing end replay cycles count arrivals once across reader pages" {
    const Host = struct {
        fn respond(listener: *std.Io.net.Server, bytes: []const u8) !void {
            const io = std.testing.io;
            var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 2000) == 0) return error.TestUnexpectedResult;
            const peer = try listener.accept(io);
            defer peer.close(io);
            var request: [4096]u8 = undefined;
            var used: usize = 0;
            while (true) {
                const got = try std.posix.read(peer.socket.handle, request[used..]);
                if (got == 0) return error.UnexpectedEof;
                used += got;
                if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |end| {
                    const start = std.mem.indexOf(u8, request[0..end], "Content-Length: ").? + "Content-Length: ".len;
                    const finish = std.mem.indexOfScalarPos(u8, request[0..end], start, '\r').?;
                    if (used == end + 4 + try std.fmt.parseInt(usize, request[start..finish], 10)) break;
                }
            }
            try std.testing.expectStringStartsWith(request[0..used], "POST /v1/activity-page HTTP/1.1\r\n");
            var header: [256]u8 = undefined;
            var writer = peer.writer(io, &.{});
            try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{bytes.len}));
            try writer.interface.writeAll(bytes);
        }
        fn page(frontend: *Self, listener: *std.Io.net.Server, read: feed_reads.Read, first: u64, last: u64, end: u64) !void {
            var facts: protocol.ActivityFacts = .{ .end = end, .direction = if (read == .opening or read == .fill_above) .backward else .forward, .count = @intCast(last - first + 1), .queued = .{ .count = 1, .oldest_position = 1, .newest_admission = 1, .newest_position = 1 }, .work = .{ .revision = 1, .work = .{ .state = .{ .working = .{ .since = 1 } }, .turn = 1, .operation = 1 } } };
            facts.more = if (facts.direction == .backward) first != 1 else last < end;
            try facts.work.workspace.set("/");
            var peer: protocol.NamedPeer = .{ .session = .{} };
            try peer.session.set("9f8e7d");
            const content: protocol.ActivityItem.Content = .{ .length = 0, .digest = protocol.contentDigest("") };
            for (facts.items[0..facts.count], 0..) |*item, i| {
                const position = if (facts.direction == .backward) last - i else first + i;
                item.* = .{ .position = position, .ordinal = 0, .at = 1, .value = if (position == 1) .{ .admission = .{ .admission = 1, .key = .{}, .turn = null, .state = .queued, .content = content, .admitted_at = 1 } } else .{ .sent = .{ .admission = position, .admitted_at = 1, .target = peer, .content = content } } };
            }
            const job = frontend.freeze(.activity);
            frontend.reading.feed_read = read;
            job.feed_page = FeedPolicy.request(read, frontend.feedState());
            // This fixture isolates feed pagination from unchanged Current
            // fields. No scan progress or novelty state is supplied by it.
            job.line_read = .{ .revision = 1, .end = end };
            job.queued_line = 1;
            try frontend.launch(job, reads.scan);
            var buffer: [16384]u8 = undefined;
            var out = std.Io.Writer.fixed(&buffer);
            try activity_reply.writePage(&out, &facts);
            try respond(listener, out.buffered());
            if (read == .opening and facts.more) {
                // This queued/sent-only history has no own ending. Opening
                // asks for that live fact independently of its resident rows.
                const endings: protocol.ActivityFacts = .{ .end = end, .direction = .backward, .work = facts.work };
                var ending_out = std.Io.Writer.fixed(&buffer);
                try activity_reply.writePage(&ending_out, &endings);
                try respond(listener, ending_out.buffered());
            }
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), frontend, struct {
                fn complete(self: *Self) bool {
                    return self.reader.completed();
                }
            }.complete);
            try frontend.settleReader();
        }
    };
    for ([_]bool{ false, true }) |growing| {
        const io = std.testing.io;
        const fixture = try FeedFixture.create();
        defer fixture.destroy();
        const held = fixture.held;
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
        self.store = root;
        self.session = "k7m2qx";
        self.reading.opening = true;
        defer {
            self.reader.cancel();
            self.reader.join() catch |err| switch (err) {
                error.Cancelled => {},
                else => @panic(@errorName(err)),
            };
        }
        try Host.page(self, &listener, .opening, 33, 48, 48);
        try Host.page(self, &listener, .fill_above, 17, 32, 48);
        try Host.page(self, &listener, .fill_above, 1, 16, 48);
        _ = try held.draw();
        try self.scroll(false, 12);
        try std.testing.expect(!held.screen.anchor.following());
        var watermark: u64 = 48;
        const ends: [2]u64 = if (growing) .{ 52, 54 } else .{ 48, 48 };
        var expected_new: usize = 0;
        for (ends) |frozen_end| {
            var first: u64 = 1;
            while (first <= frozen_end) : (first += 16) {
                const last = @min(first + 15, frozen_end);
                try Host.page(self, &listener, .scan, first, last, frozen_end);
                try std.testing.expectEqualDeep(@as(?feed_window.Key, .{ .position = watermark, .ordinal = std.math.maxInt(u64) }), self.job.feed_page.?.novelty_after);
                expected_new += @intCast(last - @min(last, @max(first - 1, watermark)));
                try std.testing.expectEqual(expected_new, self.new_below);
                if (last < frozen_end) {
                    try std.testing.expectEqual(frozen_end, self.live.scan.catchup.?.end);
                } else try std.testing.expect(self.live.scan.catchup == null);
            }
            watermark = frozen_end;
        }
        try std.testing.expectEqual(@as(usize, if (growing) 6 else 0), self.new_below);
    }
}

test "SessionFrontend huge person source keeps the following short answer bottom aligned through the reader handoff" {
    const Host = struct {
        fn respond(listener: *std.Io.net.Server, route: []const u8, kind: []const u8, body: []const u8) !void {
            const io = std.testing.io;
            var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 2000) == 0) return error.TestUnexpectedResult;
            const peer = try listener.accept(io);
            defer peer.close(io);
            var request: [4096]u8 = undefined;
            var used: usize = 0;
            while (true) {
                const got = try std.posix.read(peer.socket.handle, request[used..]);
                if (got == 0) return error.UnexpectedEof;
                used += got;
                if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |end| {
                    const start = std.mem.indexOf(u8, request[0..end], "Content-Length: ").? + "Content-Length: ".len;
                    const finish = std.mem.indexOfScalarPos(u8, request[0..end], start, '\r').?;
                    if (used == end + 4 + try std.fmt.parseInt(usize, request[start..finish], 10)) break;
                }
            }
            var prefix: [96]u8 = undefined;
            try std.testing.expectStringStartsWith(request[0..used], try std.fmt.bufPrint(&prefix, "POST {s} HTTP/1.1\r\n", .{route}));
            var header: [512]u8 = undefined;
            var writer = peer.writer(io, &.{});
            try writer.interface.writeAll(try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ kind, body.len, body.len, body.len }));
            try writer.interface.writeAll(body);
        }
        fn complete(frontend: *Self) !bool {
            return frontend.reader.completed();
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
    const scratch = try held.tmp.dir.createFile(io, "person-source", .{ .read = true });
    defer scratch.close(io);
    const inspection = try held.tmp.dir.createFile(io, "person-answer-page", .{ .read = true });
    defer inspection.close(io);
    self.files = .{ .scratch = scratch, .inspection = inspection, .action = inspection, .details = inspection, .actions = .{ inspection, inspection } };
    self.store = root;
    self.session = "k7m2qx";
    self.line.read = .{ .revision = 1, .end = 2 };
    self.reading.opening = true;
    defer {
        self.reader.cancel();
        self.reader.join() catch |err| switch (err) {
            error.Cancelled => {},
            else => @panic(@errorName(err)),
        };
    }
    // A huge person SOURCE collapses before the row byte cap: production
    // UserBody keeps two bounded preview lines, not an unbounded rendered row.
    const person = try std.testing.allocator.alloc(u8, feed_window.row_capacity + 500);
    defer std.testing.allocator.free(person);
    @memset(person, 'x');
    const answer = "SHORT ANSWER done.";
    const person_reference: protocol.ActivityItem.Content = .{ .length = person.len, .digest = protocol.contentDigest(person) };
    const answer_reference: protocol.ActivityItem.Content = .{ .length = answer.len, .digest = protocol.contentDigest(answer) };
    var facts: protocol.ActivityFacts = .{ .end = 2, .direction = .backward, .count = 2, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/");
    facts.items[0] = .{ .position = 2, .ordinal = 0, .at = 1, .value = .{ .assistant = .{ .content = answer_reference, .final = true } } };
    facts.items[1] = .{ .position = 1, .ordinal = 0, .at = 1, .value = .{ .user = .{ .admission = 1, .key = .{}, .turn = 1, .state = .applied, .content = person_reference, .admitted_at = 1 } } };
    var buffer: [4096]u8 = undefined;
    var page = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&page, &facts);
    _ = try self.update();
    try Host.respond(&listener, "/v1/activity-page", "application/json", page.buffered());
    try Host.respond(&listener, "/v1/activity-content", "application/octet-stream", person);
    try Host.respond(&listener, "/v1/activity-content", "application/octet-stream", answer);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), self, Host.complete);
    try self.settleReader();
    self.poll_at = std.math.maxInt(i96);
    try std.testing.expectEqual(@as(usize, 2), self.job.result.row_count);
    const person_row = self.job.result.rows[0];
    const answer_row = self.job.result.rows[1];
    try std.testing.expect(person_row.length < feed_window.row_capacity);
    try std.testing.expectEqual(person_row.length, answer_row.offset);
    try std.testing.expectEqual(@as(usize, 1), person_row.collapsed_count);
    try std.testing.expectEqualDeep(person_reference, person_row.collapsed_targets[0].content);
    try std.testing.expectEqual(@as(u64, 1), person_row.collapsed_targets[0].position);
    try std.testing.expectEqual(@as(u64, 2), answer_row.key.position);
    try std.testing.expectEqual(@as(usize, 2), held.screen.feed.count);
    try std.testing.expect(held.screen.feed.at_start and held.screen.feed.at_end);
    for ([_]vxfw.MaxSize{ .{ .width = 80, .height = 24 }, .{ .width = 30, .height = 12 } }) |size| {
        held.size = size;
        const frame = try held.shown();
        errdefer std.debug.print("huge person and short answer frame:\n{s}\n", .{frame});
        try std.testing.expect(held.screen.anchor.following());
        var rows = std.mem.splitScalar(u8, frame, '\n');
        var answer_line: ?usize = null;
        var row: usize = 0;
        while (rows.next()) |line| : (row += 1) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), " " ++ answer)) answer_line = row;
        }
        try std.testing.expectEqual(@as(?usize, held.screen.height - 1), answer_line);
        try std.testing.expect(std.mem.indexOf(u8, frame, "› ") != null);
    }
}

test "SessionFrontend summary bounds keep Ctrl-O and clicks exact across sixteen and five hundred twelve targets" {
    const Domain = struct {
        const line_length = "┄ item 00\n".len;
        fn target(key: u64, index: usize) View.Collapsed {
            return .{ .source = if (index % 2 == 0) .activity else .conversation, .position = key * 1000 + index, .ordinal = index, .content = .{ .length = 100 + index, .digest = @splat(@intCast(index)) }, .row = index % 2 != 0 };
        }
        fn page(fixture: FeedFixture, key: u64, aggregate: bool) !void {
            const frontend = &fixture.held.self;
            errdefer std.debug.print("boundary page {d} failed; rows {d}, targets {d}\n", .{ key, frontend.screen.feed.count, frontend.screen.feed.target_count });
            const read: feed_reads.Read = if (key == 1) .opening else .scan;
            if (read == .opening) frontend.reading.opening = true;
            const job = frontend.freeze(.activity);
            frontend.reading.feed_read = read;
            job.feed_page = FeedPolicy.request(read, frontend.feedState());
            var bytes: [2048]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            for (0..16) |index| try out.print(View.Mark.summary ++ "┄ item {d:0>2}" ++ View.Mark.reset ++ "\n", .{index});
            if (aggregate) try out.writeAll(View.Mark.summary ++ "┄ 9 more summaries" ++ View.Mark.reset ++ "\n");
            try fixture.file.writePositionalAll(std.testing.io, out.buffered(), 0);
            job.result.row_count = 1;
            job.result.rows[0] = .{ .key = .{ .position = key }, .offset = 0, .length = out.end, .tight = false, .provisional = false, .collapsed_count = 16 };
            for (job.result.rows[0].collapsed_targets[0..16], 0..) |*item, index| item.* = target(key, index);
            job.result.at_start = read == .opening;
            job.result.at_end = true;
            job.result.low = .{ .position = key };
            job.result.high = .{ .position = key, .ordinal = std.math.maxInt(u64) };
            job.result.cursor = .{ .position = key };
            job.result.new_rows = 1;
            try frontend.launch(job, struct {
                fn complete(_: *anyopaque, _: *Task) !void {}
            }.complete);
            try frontend.settleReader();
        }
        fn ctrlO(held: *HeldFrontend, expected: ?View.Collapsed) !void {
            held.self.dropMessageRequest();
            _ = try held.draw();
            try held.keys("\x0f");
            try held.settle();
            errdefer std.debug.print("boundary Ctrl-O expected {any}, got {s}\n{s}\n", .{ expected, @tagName(held.self.expansion.queued), held.shown() catch "frame unavailable" });
            if (expected) |value| {
                try std.testing.expect(held.self.expansion.queued == .ready);
                try std.testing.expectEqualDeep(value, held.self.expansion.queued.ready.target.message);
            } else try std.testing.expect(held.self.expansion.queued == .none);
            held.self.dropMessageRequest();
        }
        fn click(held: *HeldFrontend, key: u64, index: usize, expected: ?View.Collapsed) !void {
            held.self.dropMessageRequest();
            var ctx = held.context();
            // The feed's real click callback resolves this keyed byte position;
            // the test does not inject an expansion target or count from end.
            try appClick(&held.self, &ctx, .{ .key = .{ .position = key }, .offset = index * line_length });
            errdefer std.debug.print("boundary click key {d} summary {d}, expected {any}, got {s}\n", .{ key, index, expected, @tagName(held.self.expansion.queued) });
            if (expected) |value| {
                try std.testing.expect(held.self.expansion.queued == .ready);
                try std.testing.expectEqualDeep(value, held.self.expansion.queued.ready.target.message);
            } else try std.testing.expect(held.self.expansion.queued == .none);
            held.self.dropMessageRequest();
        }
    };
    const fixture = try FeedFixture.create();
    defer fixture.destroy();
    const held = fixture.held;
    for (1..33) |key| try Domain.page(fixture, key, false);
    try std.testing.expectEqual(@as(usize, 32), held.screen.feed.count);
    try std.testing.expectEqual(@as(usize, 512), held.screen.feed.target_count);
    try Domain.ctrlO(held, Domain.target(32, 15));
    try Domain.click(held, 32, 0, Domain.target(32, 0));
    try Domain.click(held, 32, 15, Domain.target(32, 15));
    // The 513th target reaches Window's actual atomic capacity refusal and
    // frontend trim/retry, rather than losing a target after text admission.
    try Domain.page(fixture, 33, false);
    try std.testing.expect(held.screen.feed.count < 33);
    try std.testing.expect(held.screen.feed.target_count <= 512);
    try std.testing.expect(held.screen.feed.indexOf(.{ .position = 33 }) != null);
    try std.testing.expect(held.screen.feed.messageAt(.{ .key = .{ .position = 1 }, .offset = 0 }) == null);
    try Domain.click(held, 1, 0, null);
    try Domain.ctrlO(held, Domain.target(33, 15));
    try Domain.click(held, 33, 0, Domain.target(33, 0));
    try Domain.click(held, 33, 15, Domain.target(33, 15));
    // Sixteen exact actionables followed by the reader's one aggregate: its
    // visible unkeyed mark blocks both Ctrl-O fallback and per-Message clicks.
    try Domain.page(fixture, 34, true);
    try Domain.ctrlO(held, null);
    try Domain.click(held, 34, 16, null);
    try Domain.click(held, 34, 0, Domain.target(34, 0));
    try Domain.click(held, 34, 15, Domain.target(34, 15));
    try std.testing.expect(held.screen.anchor.following());
}

test "chat info captures keys before a waiting permission card without deciding it" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try captureInfo(held, "Fix retry deadline");
    held.self.app_consent.adopt(10);
    held.self.app_input.permission = &held.self.app_card;
    held.self.live.work.first_action = 10;
    const choice = held.self.app_consent.highlight;
    try held.keys("\x1bi\x1b[B\r\x07\x07");
    try std.testing.expect(!held.self.info_open);
    try std.testing.expectEqual(choice, held.self.app_consent.highlight);
    try std.testing.expectEqual(@as(?u64, 10), held.self.app_consent.request);
    try std.testing.expect(held.self.submission.intent == null);
    try std.testing.expect(held.left == null);
}

test "chat info Archive delegates once and settles only its exact Session answer" {
    for (0..3) |ending| {
        const held = try HeldFrontend.createWithDrafts("k7m2qx", null);
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        try captureInfo(held, "Fix retry deadline");
        try held.keys("draft\x1bi");
        _ = try held.draw();
        held.self.app_info.panel.selected = 7;
        try held.keys("\r");
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(@as(?usize, 7), held.self.app_info.pending);
        const result: overview_view.ArchiveResult = .{ .request = .{ .reference = "k7m2qx".* }, .outcome = switch (ending) {
            0 => .{ .requested = .pending },
            1 => .{ .failed = "refused" },
            else => .{ .unconfirmed = "saved-handle" },
        } };
        var other = result;
        other.request.reference = "aaaaaa".*;
        held.self.archiveAnswered(other);
        try std.testing.expectEqual(.archive, held.self.info_effect);
        held.self.archiveAnswered(result);
        var ctx = held.context();
        try held.self.app_info.widget().handleEvent(&ctx, .tick);
        try std.testing.expect(held.self.app_info.pending == null);
        try std.testing.expectEqual(ending != 0, held.self.app_info.failures[7] != null);
        try std.testing.expectEqualStrings("draft", held.self.input.composition().bytes);
        try std.testing.expect(held.self.input.queuedCommand() == null);
    }
}

test "chat info archive admission refuses full and unresolved ledgers without trapping the panel" {
    const Existing = enum { none, archive_pending, archive_unknown, restore_pending, restore_unknown };
    for ([_]bool{ false, true }) |full| for (std.enums.values(Existing)) |existing| {
        const held = try HeldFrontend.createWithDrafts("k7m2qx", null);
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        if (full) {
            for (&overview.state.requests, 0..) |*request, i| {
                var reference: overview_view.Reference = "aaaaaa".*;
                reference[0] += @intCast(i);
                request.* = .{ .kind = .archive, .session = reference, .status = if (i % 2 == 0) .pending else .unknown };
            }
            overview.state.request_count = overview_view.max_requests;
        }
        if (existing != .none) {
            overview.state.requests[0] = .{
                .kind = if (existing == .restore_pending or existing == .restore_unknown) .unarchive else .archive,
                .session = "k7m2qx".*,
                .status = if (existing == .archive_unknown or existing == .restore_unknown) .unknown else .pending,
            };
            overview.state.request_count = @max(1, overview.state.request_count);
        }
        const refused = full or existing != .none;
        const before = overview.state.request_count;
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1bi");
        _ = try held.draw();
        held.self.app_info.panel.selected = 7;
        try held.keys("\r");
        try std.testing.expectEqual(@as(usize, @intFromBool(!refused)), overview.archives);
        try std.testing.expectEqual(before + @intFromBool(!refused), overview.state.request_count);
        try std.testing.expectEqual(@as(?usize, if (refused) null else 7), held.self.app_info.pending);
        try std.testing.expectEqual(refused, held.self.app_info.failures[7] != null);
        try std.testing.expectEqual(@as(@TypeOf(held.self.info_effect), if (refused) .idle else .archive), held.self.info_effect);
        // Reopening must not turn a refusal into a permanent modal hold.
        try held.keys("\x07\x1bi");
        _ = try held.draw();
        if (refused) {
            held.self.app_info.panel.selected = 6;
            try held.keys("\r");
            try std.testing.expect(held.self.app_info.renaming);
            try held.keys("\x07");
            // Once the owner has room again, the same action can be admitted.
            overview.state.request_count = 0;
            held.self.app_info.panel.selected = 7;
            try held.keys("\r");
            try std.testing.expectEqual(@as(usize, 1), overview.archives);
            try std.testing.expectEqual(@as(?usize, 7), held.self.app_info.pending);
        }
        // An unrelated answer cannot settle an admitted request, even hidden.
        try held.keys("\x07");
        const result: overview_view.ArchiveResult = .{ .request = .{ .reference = "k7m2qx".* }, .outcome = .{ .requested = .completed } };
        var other = result;
        other.request.reference = "zzzzzz".*;
        held.self.archiveAnswered(other);
        var ctx = held.context();
        try held.self.app_info.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?usize, 7), held.self.app_info.pending);
        held.self.archiveAnswered(result);
        try held.self.app_info.widget().handleEvent(&ctx, .tick);
        try std.testing.expect(held.self.app_info.pending == null);
        try std.testing.expect(held.self.app_info.failures[7] == null);
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
    };
}

test "chat info archive owner errors propagate instead of becoming ordinary admission refusals" {
    const Failed = struct {
        fn step(_: *anyopaque, _: protocol.session_work.Kind, _: overview_view.ConversationInput) !overview_view.ArchiveAdmission {
            return error.TestArchiveDispatchFailed;
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    try captureInfo(held, "Fix retry deadline");
    try held.keys("kept draft\x1bi");
    _ = try held.draw();
    held.self.lender.step = Failed.step;
    held.self.app_info.panel.selected = 7;
    try std.testing.expectError(error.TestArchiveDispatchFailed, held.keys("\r"));
    try std.testing.expect(held.self.app_info.pending == null);
    try std.testing.expect(held.self.app_info.failures[7] == null);
    try std.testing.expectEqual(.idle, held.self.info_effect);
    try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
}

test "chat info Configure and Copy admission either owns work or refuses before publishing pending" {
    const Hold = enum { none, host, upgrade_running, upgrade_blocked, upgrade_reobserving, opening, queued_command, running_command, typed_edit, message, decision };
    const Host = struct {
        fn held(_: *anyopaque) bool {
            return true;
        }
        fn lost(_: *anyopaque) void {
            @panic("admission must not start Host work");
        }
        fn start(_: *anyopaque, _: *vxfw.EventContext) !bool {
            return error.UnexpectedHostStart;
        }
        fn notice(_: *anyopaque) ?vxfw.Widget {
            return null;
        }
    };
    const edits: []const ChatInfo.Edit = &.{ .{ .effort = .low }, .{ .permission = .ask }, .{ .tools = .{} }, .{ .model = "gpt-6-luna" }, .{ .label = "Renamed" } };
    for (std.enums.values(Hold)) |hold| for (0..edits.len + 1) |effect| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try captureInfo(held, "Fix retry deadline");
        switch (hold) {
            .none => {},
            .host => self.app_hooks.host = .{ .context = held, .held = Host.held, .lost = Host.lost, .start = Host.start, .notice = Host.notice },
            .upgrade_running => held.upgrade = .{ .run = .checking },
            .upgrade_blocked => held.upgrade = .{ .after = .blocked },
            .upgrade_reobserving => held.upgrade = .{ .after = .reobserving },
            .opening => self.reading.opening = true,
            .queued_command => self.input.queueCommand("/requests"),
            .running_command => self.inspection.command_running = true,
            .typed_edit => {
                self.info_edit = .{ .permission = .bypass };
                self.info_effect = .configure;
            },
            .message => self.submission.intent = .{ .message = self.input.submitText("original") },
            .decision => self.submission.intent = .{ .decision = .{ .action = 10, .decision = .allow_once } },
        }
        defer self.app_hooks.host = null;
        try held.keys("kept draft");
        const before_effect = self.info_effect;
        const before_edit = self.info_edit;
        const before_command = self.input.queuedCommand();
        const cursor = self.input.composition().cursor;
        const backend = self.infoBackend();
        var ctx = held.context();
        const result = if (effect == edits.len) backend.copy_last_answer(backend.context, &ctx) else backend.configure(backend.context, edits[effect]);
        if (hold != .none) {
            try std.testing.expectError(error.Busy, result);
            try std.testing.expectEqual(overview_view.ArchiveAdmission.refused, try backend.archive(backend.context));
            try std.testing.expectEqual(before_effect, self.info_effect);
            try std.testing.expectEqualDeep(before_edit, self.info_edit);
            try std.testing.expectEqualDeep(before_command, self.input.queuedCommand());
        } else {
            try result;
            try std.testing.expectEqual(ChatInfo.SaveState.pending, backend.state(backend.context));
            if (effect == edits.len) {
                try std.testing.expectEqualStrings("", self.input.queuedCommand().?);
                try std.testing.expectEqual(.copy, self.queued_inspection.?);
                try std.testing.expect(self.info_edit == null);
            } else {
                try std.testing.expectEqualDeep(edits[effect], self.info_edit.?);
                try std.testing.expect(self.input.queuedCommand() == null);
            }
            // A second effect cannot overwrite an already admitted intent.
            try std.testing.expectError(error.Busy, backend.configure(backend.context, .{ .label = "Second" }));
            try std.testing.expectError(error.Busy, backend.copy_last_answer(backend.context, &ctx));
        }
        try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
        try std.testing.expectEqual(cursor, self.input.composition().cursor);
        try std.testing.expect(self.reader.thread == null);
        try std.testing.expect(self.app_info.pending == null);
    };
}

test "chat info typed configure completion never parses a slash line and retains definite failure" {
    const Configure = struct {
        var accepted: bool = false;
        fn run(init: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, edit: ChatInfo.Edit) !bool {
            try std.testing.expectEqual(ChatInfo.Edit{ .permission = .ask }, edit);
            if (!accepted) try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Configuration not confirmed; inspect the saved request before retrying.\n");
            return accepted;
        }
    };
    for ([_]bool{ true, false }) |accepted| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "typed-configure", .{ .read = true });
        defer held.self.files.inspection.close(std.testing.io);
        held.self.app_hooks.configure = Configure.run;
        held.self.inspection.kind = .command;
        held.self.info_effect = .configure;
        Configure.accepted = accepted;
        const job = held.self.freeze(.inspection);
        try job.setInfoEdit(.{ .permission = .ask });
        try held.self.launch(job, reads.runInfoConfigure);
        held.self.inspection.command_running = true;
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), &held.self, struct {
            fn done(self: *Self) !bool {
                return self.reader.completed();
            }
        }.done);
        try held.self.settleReader();
        try std.testing.expect(!held.self.inspection.command_running);
        try std.testing.expectEqual(@as(@TypeOf(held.self.info_effect), if (accepted) .refreshing else .failed), held.self.info_effect);
        try std.testing.expectEqual(@as(usize, 0), held.self.job.command_text_length);
        if (!accepted) {
            var bytes: [256]u8 = undefined;
            const count = try held.self.files.inspection.readPositionalAll(std.testing.io, &bytes, 0);
            try std.testing.expect(std.mem.indexOf(u8, bytes[0..count], "Configuration not confirmed") != null);
        }
    }
}

test "chat info retains Session detach keys with every topmost choice and preserves the hidden draft" {
    for ([_][]const u8{ "\x03", "\x04", "\x1b[99;5u", "\x1b[100;5u" }) |bytes| for (0..4) |choice| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1bi");
        _ = try held.draw();
        if (choice != 0) {
            held.self.app_info.panel.selected = switch (choice) {
                1 => 0,
                2 => 4,
                else => 6,
            };
            try held.keys("\r");
            try std.testing.expect(held.self.app_info.hasChoice());
        }
        try held.keys(bytes);
        try std.testing.expectEqual(@as(?Outcome, .detached), held.left);
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
        try std.testing.expect(held.self.submission.intent == null);
    };
}

test "chat info retains Session stop and archive bindings without closing the topmost choice" {
    for ([_][]const u8{ "\x18", "\x1ba" }) |bytes| {
        const held = try HeldFrontend.createWithDrafts("k7m2qx", null);
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1bi");
        _ = try held.draw();
        try held.keys("\r");
        try held.keys(bytes);
        try std.testing.expectEqual(@as(usize, 1), overview.stops + overview.archives);
        try std.testing.expect(held.self.info_open and held.self.app_info.hasChoice());
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
        try std.testing.expect(held.self.submission.intent == null);
    }
}

test "chat info typed configure supersedes every cancellable read without making cancellation fatal" {
    const Configure = struct {
        var calls: usize = 0;
        fn run(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, edit: ChatInfo.Edit) !bool {
            try std.testing.expectEqual(ChatInfo.Edit{ .permission = .ask }, edit);
            calls += 1;
            return false;
        }
        fn settled(self: *Self) !bool {
            _ = try self.update();
            return self.reader.thread == null and !self.inspectionQueued() and !self.inspection.command_running;
        }
    };
    for ([_]ReadPhase{ .activity, .permission, .fill, .message }) |phase| {
        errdefer std.debug.print("superseded read: {s}\n", .{@tagName(phase)});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        try captureInfo(held, "Fix retry deadline");
        self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "configure-cancel", .{ .read = true });
        defer self.files.inspection.close(std.testing.io);
        self.app_hooks.configure = Configure.run;
        Configure.calls = 0;
        try self.launch(self.freeze(phase), RetrySettlementWorker.cancelled);
        const backend = self.infoBackend();
        try backend.configure(backend.context, .{ .permission = .ask });
        try std.testing.expect(self.input.queuedCommand() == null);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), self, Configure.settled);
        try std.testing.expectEqual(@as(usize, 1), Configure.calls);
        try std.testing.expectEqual(.failed, self.info_effect);
        try std.testing.expect(self.leaving == null and held.left == null);
        try std.testing.expect(self.submission.intent == null);
    }
}

test "repair details rewrite from byte zero on first repeated and changed held failures" {
    const Entry = enum { owner, alt_d, details_control };
    const long_page = comptime page: {
        const line = "Changed environment guidance. Shorten these variables before recovery.\n";
        var bytes: [line.len * 80]u8 = undefined;
        for (0..80) |i| @memcpy(bytes[i * line.len ..][0..line.len], line);
        break :page bytes;
    };
    const cases = [_]struct { key: u8, state: Submission.State, page: ?[]const u8, body: []const u8, last_error: ?anyerror = null, error_line: []const u8 = "", replace_failure: bool = true }{
        .{ .key = 'K', .state = .not_started, .page = null, .body = "Publication/admission may be incomplete; Ctrl-R retries this exact original." },
        .{ .key = 'K', .state = .not_started, .page = &long_page, .body = &long_page },
        // Old advice belongs to the exact original and failure state only.
        .{ .key = 'K', .state = .rejected, .page = null, .body = "Submission rejected; /discard releases only this original, retaining the next draft.", .replace_failure = false },
        .{ .key = 'L', .state = .not_started, .page = null, .body = "Publication/admission may be incomplete; Ctrl-R retries this exact original.", .replace_failure = false },
        .{ .key = 'L', .state = .rejected, .page = "Changed refusal: inspect this original before discarding.", .body = "Changed refusal: inspect this original before discarding.", .last_error = error.RequestBindingMismatch, .error_line = "Last submission error: RequestBindingMismatch\n" },
        .{ .key = 'L', .state = .rejected, .page = null, .body = "Submission rejected; /discard releases only this original, retaining the next draft." },
    };
    for (std.enums.values(Entry)) |entry| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.files.details = try held.tmp.dir.createFile(std.testing.io, "repair-details", .{ .read = true });
        defer self.files.details.close(std.testing.io);
        const original = self.input.submitText("original message");
        self.submission.intent = .{ .message = original };
        try held.keys("kept draft\x1b[D");
        const cursor = self.input.composition().cursor;
        for (cases) |case| {
            self.submission.key = @splat(case.key);
            self.submission.state = case.state;
            self.submission.last_error = case.last_error;
            if (case.replace_failure) self.holdFailure(.{ .line = "! Original needs repair", .key = .status }, case.page);
            const expected = try std.fmt.allocPrint(std.testing.allocator, "Original reserved request: {s}\n{s}\n{s}", .{ self.submission.key, case.body, case.error_line });
            defer std.testing.allocator.free(expected);
            const bytes = try std.testing.allocator.alloc(u8, expected.len);
            defer std.testing.allocator.free(bytes);
            for (0..3) |opening| {
                errdefer std.debug.print("repair entry={s}, key={c}, page_bytes={d}, opening={d}\n", .{ @tagName(entry), case.key, case.body.len, opening });
                switch (entry) {
                    .owner => try self.showSubmissionFailure(),
                    .alt_d => try held.keys("\x1bd"),
                    .details_control => {
                        var ctx = held.context();
                        try chromeClick(.details)(self, &ctx);
                    },
                }
                try std.testing.expectEqual(@as(u64, expected.len), (try self.files.details.stat(std.testing.io)).size);
                try std.testing.expectEqual(expected.len, try self.files.details.readPositionalAll(std.testing.io, bytes, 0));
                try std.testing.expectEqualStrings(expected, bytes);
                try std.testing.expectEqualStrings(expected, self.screen.browsing.text());
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0) == null);
                try std.testing.expectEqual(Screen.ViewKind.details, self.screen.view);
                try std.testing.expect(self.screen.preview_complete);
                try std.testing.expectEqualStrings("kept draft", self.input.composition().bytes);
                try std.testing.expectEqual(cursor, self.input.composition().cursor);
                try std.testing.expectEqualStrings("original message", try self.input.message(original));
            }
        }
    }
}

test "repair details own their page identity and one Escape returns without inheriting request rows" {
    const Prior = enum { initial, requests_page, command_read, copy_read };
    const Original = enum { unconfirmed_message, rejected_message, unsaved_message, decision };
    const Entry = enum { owner, alt_d, details_control };
    const original_key = "01234567-89ab-4cde-8012-0123456789ab";
    for (std.enums.values(Prior)) |prior| for (std.enums.values(Original)) |original| {
        for ([_]bool{ false, true }) |saved| for ([_][]const u8{ "", "kept draft" }) |draft| {
            const held = try HeldFrontend.create();
            defer held.destroy();
            const self = &held.self;
            self.files.details = try held.tmp.dir.createFile(std.testing.io, "repair-details", .{ .read = true });
            defer self.files.details.close(std.testing.io);
            const requests = try held.tmp.dir.createFile(std.testing.io, "requests", .{ .read = true });
            defer requests.close(std.testing.io);
            try requests.writePositionalAll(std.testing.io, "Local recovery handles\n", 0);
            const message = self.input.submitText("exact original");
            self.submission.intent = if (original == .decision)
                .{ .decision = .{ .action = 7, .decision = .deny } }
            else
                .{ .message = message };
            self.submission.key = original_key.*;
            self.submission.state = switch (original) {
                .unconfirmed_message, .decision => .unconfirmed,
                .rejected_message => .rejected,
                .unsaved_message => .not_started,
            };
            self.submission.last_error = error.RequestBindingMismatch;
            if (saved) self.saved_requests.offer(.{ .nanoseconds = 1 }, "09:00", "22222222-89ab-4cde-8012-0123456789ab");
            self.inspection.kind = switch (prior) {
                .initial, .requests_page => .requests,
                .command_read => .command,
                .copy_read => .copy,
            };
            const read_kind = self.inspection.kind;
            if (draft.len != 0) try held.keys(draft);
            const cursor = self.input.composition().cursor;
            for (std.enums.values(Entry)) |entry| for ([_][]const u8{ "\x1b", "\x07" }) |close| {
                errdefer std.debug.print("repair close prior={s} original={s} saved={} draft={s} entry={s} key={x}\n", .{ @tagName(prior), @tagName(original), saved, draft, @tagName(entry), close[0] });
                if (prior == .requests_page) {
                    try self.screen.showFile(std.testing.io, requests, .inspection);
                    _ = try held.draw();
                    // A real requests page still owns its recovery palette.
                    if (draft.len == 0 and (saved or original == .unconfirmed_message))
                        try std.testing.expect(self.requestList() != null);
                }
                switch (entry) {
                    .owner => try self.showSubmissionFailure(),
                    .alt_d => try held.keys("\x1bd"),
                    .details_control => {
                        var ctx = held.context();
                        try chromeClick(.details)(self, &ctx);
                    },
                }
                // The current reader's operation is not the presented page.
                try std.testing.expectEqualDeep(read_kind, self.inspection.kind);
                try std.testing.expect(self.requestList() == null);
                _ = try held.draw();
                try std.testing.expect(self.screen.commands == null);
                try held.keys(close);
                try std.testing.expectEqual(Screen.ViewKind.feed, self.screen.view);
                try std.testing.expect(self.leaving == null and held.left == null);
                try std.testing.expectEqualStrings(draft, self.input.composition().bytes);
                try std.testing.expectEqual(cursor, self.input.composition().cursor);
                try std.testing.expectEqualStrings(original_key, &self.submission.key);
                try std.testing.expectEqualStrings("exact original", try self.input.message(message));
                try std.testing.expect(self.submission.intent != null and self.submission.retry == null);
                try std.testing.expect(self.input.queuedCommand() == null);
            };
        };
    };
}

test "repair details keep explicit command cancellation and return to the adopted Action" {
    for ([_]bool{ false, true }) |action| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        self.files.details = try held.tmp.dir.createFile(std.testing.io, "repair-details", .{ .read = true });
        defer self.files.details.close(std.testing.io);
        const action_file = if (action) try held.adopt(2) else null;
        defer if (action_file) |file| file.close(std.testing.io);
        self.submission.intent = .{ .message = self.input.submitText("exact original") };
        self.submission.state = .unconfirmed;
        self.submission.key = "01234567-89ab-4cde-8012-0123456789ab".*;
        try self.showSubmissionFailure();
        if (!action) {
            // A visible command still owns the first Escape. An adopted
            // Action intentionally hides command choices instead.
            try held.keys("/rel");
            _ = try held.draw();
            try std.testing.expectEqual(.drawn, self.screen.commands.?.seen);
            try held.keys("\x1b");
            try std.testing.expectEqual(Screen.ViewKind.details, self.screen.view);
            try std.testing.expectEqualStrings("", self.input.composition().bytes);
        }
        _ = try held.draw();
        try std.testing.expect(self.screen.commands == null);
        const consent = self.screen.consent;
        try held.keys("\x1b");
        try std.testing.expectEqual(if (action) Screen.ViewKind.action else Screen.ViewKind.feed, self.screen.view);
        try std.testing.expectEqualDeep(consent, self.screen.consent);
        try std.testing.expect(self.leaving == null and held.left == null);
        try std.testing.expectEqualStrings("exact original", try self.input.message(self.submission.intent.?.message));
        try std.testing.expect(self.submission.retry == null and self.input.queuedCommand() == null);
    }
}

test "chat info repair details never overwrite the active reader staging file" {
    const Staging = struct {
        var ready: std.atomic.Value(bool) = .init(false);
        const bytes = "staged feed and exact Configure diagnostics must survive";
        fn run(raw: *anyopaque, task: *Task) !void {
            const job: *Job = @ptrCast(@alignCast(raw));
            try job.files.inspection.writePositionalAll(task.io, bytes, 0);
            ready.store(true, .release);
            try test_poll.waitUntil(task.io, test_poll.after(task.io, .fromSeconds(10)), &task.cancellation.stopped, test_poll.isSet);
            return error.Cancelled;
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.files.inspection = try held.tmp.dir.createFile(std.testing.io, "active-staging", .{ .read = true });
    defer self.files.inspection.close(std.testing.io);
    self.files.details = try held.tmp.dir.createFile(std.testing.io, "original-details", .{ .read = true });
    defer self.files.details.close(std.testing.io);
    self.submission.intent = .{ .message = self.input.submitText("original message") };
    self.submission.state = .not_started;
    self.submission.key = @splat('K');
    Staging.ready.store(false, .release);
    try self.launch(self.freeze(.activity), Staging.run);
    defer {
        self.reader.cancel();
        _ = self.joinReader();
    }
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), &Staging.ready, test_poll.isSet);
    try self.showSubmissionFailure();
    try std.testing.expectEqual(Screen.ViewKind.details, self.screen.view);
    try std.testing.expect(std.mem.indexOf(u8, self.screen.browsing.text(), "Original reserved request: KKK") != null);
    var bytes: [128]u8 = undefined;
    const count = try self.files.inspection.readPositionalAll(std.testing.io, &bytes, 0);
    try std.testing.expectEqualStrings(Staging.bytes, bytes[0..count]);
    try std.testing.expect(self.reader.thread != null and !self.reader.completed());
}

test "chat info supplies the one bottom footer after the input and both dividers" {
    for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 30 } }) |size| for ([_]bool{ false, true }) |choice| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        held.size = .{ .width = size.width, .height = size.height };
        held.root.size = size;
        held.root.session = held.self.widget();
        try captureInfo(held, "Fix retry deadline");
        try held.keys("kept draft\x1bi");
        _ = try held.draw();
        if (choice) {
            try held.keys("\x1b[B\x1b[B\x1b[B\r");
            try std.testing.expect(held.self.app_info.model_choice.active);
        }
        const surface = try held.draw();
        const base = surface.children[0].surface;
        const input = base.children[base.children.len - 1];
        try std.testing.expectEqual(@as(usize, 2), input.surface.children.len);
        const footer = input.surface.children[1];
        try std.testing.expectEqual(@as(i17, size.height - 1), input.origin.row + footer.origin.row);
        try std.testing.expectEqual(@as(u16, 1), footer.surface.size.height);
        try std.testing.expectEqual(input.origin.row, surface.children[1].origin.row + surface.children[1].surface.size.height);
        const text = try held.shown();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "· info"));
        try std.testing.expect(std.mem.indexOf(u8, text, "alt+i info") == null);
        var rows = std.mem.splitScalar(u8, text, '\n');
        var row: usize = 0;
        var previous: []const u8 = "";
        while (rows.next()) |line| : (row += 1) {
            if (row == size.height - 1) {
                try std.testing.expect(std.mem.indexOf(u8, line, "Fix retry deadline · info") != null);
                try std.testing.expect(std.mem.indexOf(u8, line, "esc close") != null);
            } else if (row == size.height - 2 or row == size.height - 4) {
                try std.testing.expect(std.mem.startsWith(u8, line, "──"));
            } else if (row == size.height - 3) {
                try std.testing.expect(std.mem.indexOf(u8, line, "kept draft") != null);
            }
            if (std.mem.indexOf(u8, line, "Rename     Archive") != null) try std.testing.expectEqualStrings("", std.mem.trim(u8, previous, " "));
            previous = line;
        }
        try held.keys("\x07");
        if (choice) try held.keys("\x07");
        try std.testing.expect(!held.self.info_open);
        try std.testing.expect((try rowWith(held, "alt+i info")) != null);
        try std.testing.expectEqualStrings("kept draft", held.self.input.composition().bytes);
    };
}

test "App Session palette clicks follow Enter for command words options and values and retain hover across frames" {
    const Case = struct { draft: []const u8, word: []const u8, after: []const u8, queued: ?[]const u8 = null, notice: ?[]const u8 = null };
    for ([_]Case{
        .{ .draft = "/rel", .word = "reload-skills", .after = "", .queued = "/reload-skills" },
    }) |case| {
        errdefer std.debug.print("draft={s}, word={s}\n", .{ case.draft, case.word });
        const held = try HeldFrontend.create();
        defer held.destroy();
        try captureInfo(held, "Palette");
        held.self.line.read = .{ .revision = 1, .end = 1 };
        try held.self.line.model.set("gpt-5.5");
        try held.keys(case.draft);
        _ = try held.draw();
        const shown = if (held.screen.commands) |*shown| shown else return error.TestExpectedCommandList;
        const index = for (shown.list.shown(), 0..) |entry, index| {
            if (std.mem.eql(u8, case.word, entry.word)) break index;
        } else return error.TestExpectedRow;
        shown.highlight = if (index == 0) shown.list.count - 1 else 0;
        const selected = shown.highlight;
        _ = try held.draw();
        const row: i16 = @intCast(index - held.self.app_palette.first);
        const widget_ = held.self.app_palette.widget();
        var events = held.context();
        try widget_.handleEvent(&events, .mouse_enter);
        try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = row, .button = .none, .type = .motion, .mods = .{} } });
        // Parent redraws must not replace the widget's pointer state.
        _ = try held.draw();
        try std.testing.expect(held.self.app_palette.hover.pointing);
        const palette = try widget_.draw(.{ .arena = held.arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 20 }, .cell_size = .{} });
        const cell = palette.readCell(2, @intCast(row));
        if (selected == index) try std.testing.expect(cell.style.reverse) else {
            try std.testing.expect(!cell.style.reverse);
            try std.testing.expectEqual(held.self.app_palette.hover_style.bg, cell.style.bg);
            try std.testing.expectEqual(held.self.app_palette.hover_style.ul_style, cell.style.ul_style);
            try std.testing.expect(palette.readCell(2, @intCast(selected - held.self.app_palette.first)).style.reverse);
        }
        try std.testing.expectEqual(selected, held.screen.commands.?.highlight);
        try std.testing.expectEqualStrings(case.draft, held.self.input.composition().bytes);
        for (events.cmds.items) |command| try std.testing.expect(command != .request_focus);
        try widget_.handleEvent(&events, .mouse_leave);
        _ = try held.draw();
        try std.testing.expect(!held.self.app_palette.hover.pointing);
        if (selected != index) {
            const plain = try widget_.draw(.{ .arena = held.arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 20 }, .cell_size = .{} });
            try std.testing.expect(!plain.readCell(2, @intCast(row)).style.reverse);
        }
        try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = row, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqualStrings(case.after, held.self.input.composition().bytes);
        if (case.queued) |expected| try std.testing.expectEqualStrings(expected, held.self.input.queuedCommand().?) else try std.testing.expectEqual(null, held.self.input.queuedCommand());
        if (case.notice) |expected| try std.testing.expectEqualStrings(expected, held.self.shown_notice.current(held.self.nowMs()).?);
        try std.testing.expect(held.self.submission.view() == null);
    }
}

test "App Session palette refuses clicks on stale drafts closed lists and during paste or approval" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try held.keys("/r");
    _ = try held.draw();
    const widget_ = held.self.app_palette.widget();
    var events = held.context();
    const click: vxfw.Event = .{ .mouse = .{ .col = 2, .row = 0, .button = .left, .type = .press, .mods = .{} } };
    try held.keys("el"); // The drawn /reload-skills row is not the new /relame row.
    try widget_.handleEvent(&events, click);
    try std.testing.expectEqualStrings("/rel", held.self.input.composition().bytes);
    // A key that acts on `/rel`'s list before a frame draws it does not make
    // the drawn `/r` row its row.
    try held.keys("\x1b[B\x1b[A");
    try widget_.handleEvent(&events, click);
    try std.testing.expectEqualStrings("/rel", held.self.input.composition().bytes);
    try std.testing.expectEqual(null, held.self.input.queuedCommand());
    _ = try held.draw();
    held.root.pasting = true;
    try widget_.handleEvent(&events, click);
    try std.testing.expectEqualStrings("/rel", held.self.input.composition().bytes);
    held.root.pasting = false;
    held.self.app_consent.adopt(41);
    try widget_.handleEvent(&events, click);
    try std.testing.expectEqualStrings("/rel", held.self.input.composition().bytes);
    held.self.app_consent.withdraw();
    held.screen.commands.?.close();
    try widget_.handleEvent(&events, click);
    try std.testing.expectEqualStrings("/rel", held.self.input.composition().bytes);
    try std.testing.expectEqual(null, held.self.input.queuedCommand());
}

test "App Session palette clicks requests rows with an empty draft as Enter does" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const older = "01234567-89ab-4cde-8012-0123456789ab";
    const newer = "01234567-89ab-4cde-8012-0123456789ac";
    held.screen.view = .inspection;
    held.self.inspection.kind = .requests;
    held.self.saved_requests.offer(.{ .nanoseconds = 1 }, "09:00", older);
    held.self.saved_requests.offer(.{ .nanoseconds = 2 }, "09:05", newer);
    _ = try held.draw();
    var events = held.context();
    const widget_ = held.self.app_palette.widget();
    try widget_.handleEvent(&events, .mouse_enter);
    try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expectEqual(@as(usize, 0), held.screen.commands.?.highlight);
    try widget_.handleEvent(&events, .mouse_leave);
    try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 1, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqualStrings("" ++ older, held.self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
}

test "App Session palette clicks replace the caret skill without sending or moving focus on hover" {
    const Fake = struct {
        fn read(_: client.ReadContext, gpa: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !skill_suggestions.Page {
            const entries = try gpa.alloc(skill_suggestions.Entry, 2);
            entries[0] = .{ .name = try gpa.dupe(u8, "recap"), .description = try gpa.dupe(u8, "Summarise") };
            entries[1] = .{ .name = try gpa.dupe(u8, "review"), .description = try gpa.dupe(u8, "Review a change") };
            return .{ .entries = entries, .total = 2 };
        }
        fn completed(self: *Self) bool {
            return self.skill_task.completed();
        }
    };
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.skill_read = Fake.read;
    try held.keys("please /re");
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &held.self, Fake.completed);
    try held.settle();
    try held.keys(" now\x1b[D\x1b[D\x1b[D\x1b[D");
    _ = try held.draw();
    try std.testing.expectEqualStrings("/review", held.screen.commands.?.list.entries[1].shown);
    const widget_ = held.self.app_palette.widget();
    var events = held.context();
    try widget_.handleEvent(&events, .mouse_enter);
    try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    _ = try held.draw();
    try std.testing.expectEqual(@as(usize, 0), held.screen.commands.?.highlight);
    try std.testing.expectEqualStrings("please /re now", held.self.input.composition().bytes);
    for (events.cmds.items) |command| try std.testing.expect(command != .request_focus);
    try widget_.handleEvent(&events, .mouse_leave);
    try widget_.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 1, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqualStrings("please /review now", held.self.input.composition().bytes);
    try std.testing.expectEqual("please /review".len, held.self.input.composition().cursor);
    try std.testing.expectEqual(null, held.self.input.queuedCommand());
    try std.testing.expectEqual(null, held.self.submission.view());
}

test "new and clear navigate without sending or changing the old chat and reject arguments" {
    for ([_][]const u8{ "/new", "/clear" }) |name| {
        var drafts: session_drafts.Drafts = .{};
        const held = try HeldFrontend.createWithDrafts("k7m2qx", &drafts);
        defer held.destroy();
        held.self.line = .{ .read = .{ .revision = 7, .end = 10 }, .effort = .high, .first_position = 1 };
        try held.self.line.model.set("gpt-5.5");
        try seedFeed(held.screen, "OLD ANSWER\n");
        const work = held.self.live.work;
        const line = held.self.line;
        try held.keys(name);
        try held.keys(" foo\r");
        try std.testing.expect(held.left == null and held.self.submission.intent == null);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "! Usage:") != null);
        try held.keys(name);
        try held.keys("\r");
        try std.testing.expectEqual(@as(?Outcome, .new_session), held.left);
        try std.testing.expect(held.self.submission.intent == null and held.self.input.queuedCommand() == null);
        try std.testing.expectEqual(work, held.self.live.work);
        try std.testing.expectEqual(line, held.self.line);
        try std.testing.expect(std.mem.indexOf(u8, try held.shown(), "OLD ANSWER") != null);
    }
}

test "empty chat footer derives model effort and Folder from Current at both widths" {
    const held = try HeldFrontend.createWithDrafts("n3w5es", null);
    defer held.destroy();
    held.self.line = .{ .read = .{ .revision = 1, .end = 0 }, .effort = .low };
    try held.self.line.model.set("gpt-5.5");
    try held.self.line.folder.set("project");
    for ([_]u16{ 46, 140 }) |width| {
        held.size = .{ .width = width, .height = 30 };
        const text = try held.shown();
        try std.testing.expect(std.mem.indexOf(u8, text, "gpt-5.5 · low · project") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "n3w5es") == null);
    }
}
