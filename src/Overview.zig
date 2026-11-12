//! The Session overview's shell: bare `rui`, and `rui session resume` around
//! the Session it opens.
//!
//! It owns the terminal and one loop. Keys, ticks at `State.wakeAt` and the
//! worker's replies enter `overview_view.step` as events; the loop runs the
//! effects `step` returns and draws `overview_view.render`. It branches only
//! on which effect to run, so every screen decision stays in the core. One
//! worker runs the client requests in order, so one list read is in flight
//! at a time, and the core only ever hears list replies for the listing it
//! asked for. An opened Session borrows the terminal through
//! `SessionFrontend`, with ticks paused, and gives it back on Esc.
const std = @import("std");
const session_list = @import("session_list.zig");
const model_catalog = @import("model_catalog.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const TerminalApp = @import("TerminalApp.zig");
const Root = @import("Root.zig");
const AppSettings = @import("app_settings.zig");
const SignIn = @import("SignIn.zig");
const AppScreen = @import("AppScreen.zig");
const InputArea = @import("InputArea.zig");
const GroupedList = @import("GroupedList.zig");
const Hover = @import("widgets/Hover.zig");
const Chip = @import("Chip.zig");
const host_identity = @import("host_identity.zig");
const platform = @import("platform.zig");
const host_restart = @import("host_restart.zig");
const OverviewLines = @import("OverviewLines.zig");
const Palette = @import("Palette.zig");
const slash_commands = @import("slash_commands.zig");
const skill_completion = @import("skill_completion.zig");
const skill_suggestions = @import("skill_suggestions.zig");
const client = @import("client.zig");
const configure_input = @import("configure_input.zig");
const process_memory = @import("process_memory.zig");
const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const model_list = @import("model_list.zig");
const model_picker = @import("model_picker.zig");
const stderr = @import("stderr.zig");
const test_poll = @import("test_poll");
const app_events = @import("testing/app_events.zig");
const view = @import("overview_view.zig");
const ClientTask = @import("ClientTask.zig");
const UpgradeJob = @import("UpgradeJob.zig");
const session_upgrade = @import("session_upgrade.zig");
const upgrade_status = @import("upgrade_status.zig");
const session_chrome = @import("session_chrome.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const session_reads = @import("session_reads.zig");
const SessionInput = @import("SessionInput.zig");
const SessionScreen = @import("SessionScreen.zig");
const session_id = @import("session_id.zig");
const Follow = @import("session_follow.zig").Follow;
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalText = @import("TerminalText.zig");
const keymap = @import("keymap.zig");
const session_view = @import("session_view.zig");
const model_capability = @import("model_capability.zig");
const new_session_selection = @import("new_session_selection.zig");
const preferences = @import("preferences.zig");
const marks = @import("marks.zig");
const handoff = @import("relaunch_handoff.zig");

comptime {
    // The draft holds what a conversation's does.
    std.debug.assert(view.draft_capacity == SessionInput.capacity);
}
const Self = @This();

pub const Options = struct {
    store: []const u8,
    /// The canonical cwd: the Workspace the composer starts Sessions in.
    workspace: []const u8,
    home: []const u8,
    /// Where request captures go.
    directory: []const u8,
    /// The binding new Sessions get unless /configure picks another. Without
    /// one, the Host refuses a start that names none.
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// This terminal's own successful login, Unix seconds.
    login_at: ?u64 = null,
    sign_in: bool = false,
    /// The launch's own `--store`, `--provider` and `--model`, as given.
    /// When it named all three, a start reads no saved defaults, the saved
    /// effort included. Otherwise a `/setup` that ran re-resolves the
    /// default from them and the saved defaults, as a fresh launch would.
    selectors: new_session_selection.Intent = .{},
    /// A Session to open first, as `session resume` names it.
    open: ?view.Reference = null,
    /// CLI-authenticated one-shot handoff, borrowed through run and copied
    /// before any terminal startup. No environment or file reads live here.
    restoration: ?*const handoff.Payload = null,
};

/// A settled departure the CLI can replace. All slices are owned by the caller;
/// no terminal, worker or editor remains borrowed when `run` returns it.
pub const Relaunch = struct {
    executable: []const u8,
    handoff: []const u8,
    receipt: []const u8,
    open: ?view.Reference,

    pub fn deinit(self: Relaunch, gpa: std.mem.Allocator) void {
        gpa.free(self.executable);
        gpa.free(self.handoff);
        gpa.free(self.receipt);
    }

    pub fn writeFallback(self: Relaunch, store: []const u8) void {
        _ = stderr.writeReceipt(self.receipt);
        TerminalApp.detached(store, if (self.open) |*id| id else null, null);
    }
};

/// What the CLI lends the overview and its conversations: scratch files and
/// the slash commands both run.
pub const Hooks = struct {
    scratch: *const fn (std.process.Init) anyerror!std.Io.File,
    command: SessionFrontend.Command,
    configure: ?session_reads.Configure = null,
    requests: SessionFrontend.Requests,
    status: SessionFrontend.Status,
    /// Runs between a start's capture and its send, as the CLI's other
    /// captures do.
    captured: *const fn (std.Io) anyerror!void,
    activate: ?SignIn.Activate = null,
    ready: ?SignIn.Ready = null,
    /// The launch owner, without terminal output while App holds the screen.
    start_host: *const fn (std.process.Init, []const u8) HostLaunch,
};

pub const HostLaunch = @import("host_launch.zig").Summary;

/// One discovery observation, not a UI phase or a launch outcome. A pause
/// belongs only to a reachable Host; a free Store lease proves it stopped.
const HostObservation = union(enum) {
    /// Nothing read yet. The launch that opened this screen saw its Host
    /// ready, so the first frames say nothing and hold nothing.
    unread,
    ready: struct { facts: view.Host, paused: bool = false },
    /// The lease is free; the stop record says whether someone asked.
    stopped: platform.StoreLease.LastStop,
    /// A Host holds the Store and gave no answer: starting, stopping or lost.
    unavailable,
    /// A Host answered in another Rui version's protocol.
    incompatible,
    /// The Store's location could not be read, so nothing is known.
    unreadable,

    fn facts(self: HostObservation) ?view.Host {
        return switch (self) {
            .ready => |ready| ready.facts,
            else => null,
        };
    }

    fn restartSeen(self: HostObservation) host_restart.Seen {
        return switch (self) {
            .unread, .ready => .up,
            .stopped => |stop| .{ .stopped = stop },
            .unavailable, .incompatible, .unreadable => .held,
        };
    }
};

/// One worker read supplies availability, admission and counts together.
pub const HostRead = struct {
    observation: HostObservation = .unavailable,
    /// This TUI's memory, with the Host's and its tools' while one runs;
    /// null when the read sampled none.
    memory: ?view.Memory = null,
};

/// The client operations the effects run. The worker runs all but
/// `converse`, each with its own cancellable requests; the loop runs
/// `converse`. Each returns what the Host answered, failures included, and
/// an error when there was no answer. Tests substitute their own.
pub const Operations = struct {
    /// One Host read: host-info's facts and the memory sampled with them.
    host: *const fn (*Self) HostRead,
    start_host: *const fn (*Self) HostLaunch,
    /// Reads one `session list` page into `page`, or returns the Host's
    /// failure.
    list: *const fn (*Self, client.Requests, protocol_reply.SessionListCursor, *protocol_reply.SessionListPage) anyerror!?protocol_reply.ReadFailure,
    /// The first line of a Session's first Message, read into `buffer`.
    first_line: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!protocol_reply.ActivityPrefixReply,
    /// The leading bytes of the command a waiting Action would run, read
    /// into `buffer`; null when the read is refused or its tool has no
    /// command to show.
    action_command: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!?[]const u8,
    /// Write the request's fate into the Reply, and return the error that
    /// ends the overview after a canonical Store failure.
    start: *const fn (*Self, client.Requests, client.MessageInput, *Reply) anyerror!void,
    stop: *const fn (*Self, client.Requests, client.SessionStopInput, *Reply) anyerror!void,
    archive: *const fn (*Self, client.Requests, client.SessionArchiveInput, *Reply) anyerror!void,
    /// The Host's `model_list` reply, owned by the allocator.
    models: *const fn (*Self, client.Requests, std.mem.Allocator) anyerror![]u8,
    /// The skills of `workspace` whose names start `prefix`, owned by the
    /// allocator.
    skills: *const fn (*Self, client.Requests, std.mem.Allocator, []const u8, []const u8) anyerror!skill_suggestions.Page,
    /// Runs a command line for a Session, or for none when it is empty,
    /// keeping what it printed in `output`.
    command: *const fn (*Self, client.ReadContext, []const u8, []u8) anyerror!void,
    /// Opens `opened` as a Session widget under Root.
    open: *const fn (*Self, *vxfw.EventContext) anyerror!void,
};

pub const client_operations: Operations = .{ .host = hostFacts, .start_host = startHost, .list = listPage, .first_line = firstLine, .action_command = actionCommand, .start = startSession, .stop = stopSession, .archive = archiveSession, .models = listModels, .skills = skillSuggestions, .command = runCommand, .open = openSession };

/// A conversation the person left from. Until the terminal is restored it
/// holds its borrowers; `frontend` is null when it never started.
pub const Left = struct {
    session: view.Reference,
    frontend: ?*SessionFrontend,
    files: ?SessionFrontend.Files,
    ended: anyerror!SessionFrontend.Outcome,
};

/// The outcome of a `session start` or `session stop`, held until the loop
/// steps it.
pub const Reply = struct {
    outcome: enum { accepted, failed, unconfirmed } = .failed,
    session: view.Reference = undefined,
    archive_pending: bool = false,
    /// The failure code, why an environment was refused, or the handle
    /// that recovers an unconfirmed request.
    text: protocol.Bounded(@max(protocol.max_code_bytes, client.Environment.too_large_bytes)) = .{},
    /// The request's handle, for guidance after an accepted start.
    handle: protocol.Bounded(protocol.max_key_bytes) = .{},

    fn refused(code: []const u8) Reply {
        var reply: Reply = .{};
        reply.text.set(code[0..@min(code.len, protocol.max_code_bytes)]) catch {};
        return reply;
    }

    /// Nothing was sent: the environment is over what a Message carries.
    fn environmentTooLarge(environment: client.Environment) Reply {
        var reply: Reply = .{};
        var buffer: [client.Environment.too_large_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        environment.describeTooLarge(&writer) catch unreachable;
        reply.text.set(writer.buffered()) catch unreachable;
        return reply;
    }

    /// Records a send of the captured request `handle`. Only the Host's
    /// answer settles it: a failed send, or a reply that could not be read,
    /// leaves the saved request to recover. A canonical Store failure leaves
    /// it too, and is returned, since it fences the Host.
    fn record(self: *Reply, sent: anytype, handle: []const u8) error{CanonicalStoreFailure}!void {
        const reply = switch (sent) {
            .failed => {
                self.* = unconfirmed(handle);
                return;
            },
            .done => |reply| reply,
        };
        const answer = reply.answer catch |err| {
            self.* = unconfirmed(handle);
            return switch (err) {
                error.CanonicalStoreFailure => |fenced| fenced,
                else => {},
            };
        };
        var result: Reply = switch (answer.result) {
            .accepted => .{ .outcome = .accepted },
            .rejected => |code| refused(code.slice()),
            .conflict => refused("conflict"),
        };
        if (result.outcome == .accepted) {
            const session = reply.context.session.slice();
            const len = @typeInfo(view.Reference).array.len;
            if (session.len == len) result.session = session[0..len].*;
        }
        if (answer.result == .accepted and answer.result.accepted == .session_archive)
            result.archive_pending = answer.result.accepted.session_archive.completion == .pending;
        result.handle.set(handle) catch {};
        self.* = result;
    }

    fn unconfirmed(handle: []const u8) Reply {
        var reply: Reply = .{ .outcome = .unconfirmed };
        reply.text.set(handle) catch {};
        reply.handle.set(handle) catch {};
        return reply;
    }

    fn start(self: *const Reply) view.StartResult {
        return switch (self.outcome) {
            .accepted => .{ .started = .{ .reference = self.session, .handle = self.handle.slice() } },
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        };
    }

    fn archive(self: *const Reply, request: view.ArchiveRequest) view.ArchiveResult {
        return .{ .request = request, .outcome = switch (self.outcome) {
            .accepted => .{ .requested = if (self.archive_pending) .pending else .completed },
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        } };
    }

    fn stop(self: *const Reply) view.StopOutcome {
        return switch (self.outcome) {
            .accepted => .stopped,
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        };
    }
};

/// A queued edit owns only its set strings in one allocation. One settings
/// save may be outstanding; keeping this out of the fixed queue avoids a
/// full preference snapshot (and Store path) in every job slot.
const DefaultsEdit = struct {
    edit: preferences.Edit,
    bytes: []u8,

    fn init(gpa: std.mem.Allocator, edit: preferences.Edit) !DefaultsEdit {
        var length: usize = 0;
        inline for (.{ "store", "provider", "model" }) |field| {
            const change = @field(edit, field);
            if (change == .set) length = std.math.add(usize, length, change.set.len) catch return error.OutOfMemory;
        }
        const bytes = try gpa.alloc(u8, length);
        var owned = edit;
        var offset: usize = 0;
        inline for (.{ "store", "provider", "model" }) |field| {
            const change = @field(edit, field);
            if (change == .set) {
                const text = bytes[offset..][0..change.set.len];
                @memcpy(text, change.set);
                @field(owned, field) = .{ .set = text };
                offset += text.len;
            }
        }
        return .{ .edit = owned, .bytes = bytes };
    }

    fn deinit(self: DefaultsEdit, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

const Job = union(enum) {
    /// host-info, read as each listing starts.
    host,
    start_host,
    /// The traversal's next page.
    list,
    lines: view.Reads,
    commands: view.Commands,
    /// Owns what Enter captured: nothing the core or the composer holds is
    /// read on the worker's thread.
    start: view.OwnedStart,
    stop: view.Reference,
    archive: view.ArchiveRequest,
    models,
    /// A skill suggestions read, numbered by the core, for its own copy of
    /// the Workspace and the name.
    skills: struct { read: u64, workspace: protocol.Bounded(protocol.max_workspace_bytes), prefix: protocol.Bounded(skill_completion.max_prefix_bytes) },
    defaults: DefaultsEdit,
    /// Owns its line, as a start owns its text.
    command: struct { name: view.commands.Name, session: ?view.Reference, line: []u8 },

    const Quiescence = enum { cancel_read, settle_effect };

    /// Already accepted effects keep custody through their answer; reads may
    /// retire early. Both archive and restore are the same mutation job.
    fn quiescence(self: Job) Quiescence {
        return switch (self) {
            .host, .list, .lines, .commands, .models, .skills => .cancel_read,
            .start_host, .start, .stop, .archive, .defaults, .command => .settle_effect,
        };
    }

    /// A job owns its inputs until it is replaced or the overview ends,
    /// whether or not it ran.
    fn deinit(self: Job, gpa: std.mem.Allocator) void {
        switch (self) {
            .start => |start| start.deinit(gpa),
            .defaults => |edit| edit.deinit(gpa),
            .command => |command| gpa.free(command.line),
            else => {},
        }
    }
};

/// What a job leaves, as one value in its job's shape. The job that runs
/// is its only writer and `deliver`, for that job, its only reader, so no
/// job reads what another left. A job that fails partway leaves the part
/// it wrote.
const Answer = union(enum) {
    /// No job has run since the last answer was taken, or the job leaves
    /// only its outcome.
    none,
    host: HostRead,
    start_host: struct { read: HostRead, launch: HostLaunch },
    page: protocol_reply.SessionListPage,
    lines: [view.max_first_line_reads]Line,
    /// Each command read's leading bytes, null when it has none to show.
    commands: [view.max_first_line_reads]Command,
    /// A start's, stop's or archive's.
    reply: Reply,
    menu: model_picker.Menu,
    skills: skill_suggestions.Page,
    /// What a command printed, as far as the core takes it.
    output: Output,

    /// Frees an answer no one took.
    fn deinit(self: *Answer, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .menu => |*menu| menu.deinit(gpa),
            .skills => |*page| page.deinit(gpa),
            else => {},
        }
        self.* = .none;
    }
};

/// One host read and list page, at most one first-line batch, one
/// command-read batch, one model-list read, one skills read,
/// one settings save, one Host start, one command and the requests the core's
/// ledger allows can wait at once.
const max_jobs = 10 + view.max_requests;

/// The longest the first frame waits for the terminal's background.
const background_wait_ms = 200;

const Line = struct { bytes: [view.max_line_read_bytes]u8 = undefined, result: enum { line, refused, unanswered } = .unanswered, len: usize = 0 };

const Command = struct { bytes: [view.max_line_read_bytes]u8 = undefined, text: ?[]const u8 = null, answered: bool = false };

/// A command's output: one byte past what the core takes tells it was cut.
const Output = struct {
    bytes: [view.max_output_bytes + 1]u8 = undefined,
    len: usize = 0,
    /// Its stdout and stderr went to the page, so a failure is a failure
    /// while it ran.
    kept: bool = false,
};

/// Stops a running command when App ends on a signal.
const Signals = struct {
    var cancellation: client.Cancellation = .{};
};

init: std.process.Init,
options: Options,
signed_in_store: protocol.Bounded(protocol.max_store_bytes) = .{},
hooks: Hooks,
ops: Operations,
state: view.State,
/// The typed save owns this outcome from acceptance through its worker answer.
defaults_save: AppSettings.SaveState = .idle,
caps: view.Caps,
app: ?*TerminalApp = null,
/// Program status records beside App's frames.
attention: *TerminalApp.Attention = undefined,
root: Root = undefined,
/// The sign-in page Root shows as an opaque widget; its worker is this owner's.
sign_in: SignIn = .{},
app_screen: AppScreen.Overview = undefined,
app_input: InputArea = undefined,
/// What can fill the list's place, each its own widget: the screen shows
/// the one the core names. Only the Sessions hear a press.
app_sessions: GroupedList = .{},
app_new_session: OverviewLines.NewSession = undefined,
session_drafts: @import("session_drafts.zig").Drafts = .{},
app_panel: GroupedList = .{},
app_settings_line: OverviewLines.Settings = undefined,
/// The counts line and its bands, which take the view-name click.
app_header: OverviewLines.Header = undefined,
app_palette: Palette = .{ .shown = undefined },
app_frame: u64 = 0,
app_host_hover: Hover = .{},
app_model: Chip = undefined,
app_effort: Chip = undefined,
app_choice_pick: Chip = undefined,
app_choice_close: Chip = undefined,
session_screen: *SessionScreen = undefined,
app_session: ?Left = null,
/// Where leaving a Session goes when Session links are followed.
follow: Follow = .{},
retired: std.ArrayList(struct { left: Left, frame: u64 }) = .empty,
interrupted: *client.Cancellation,
/// The composer's line editor, the conversation's, which owns the draft.
composer: TerminalEditor = undefined,
draft: [view.draft_capacity]u8 = undefined,
/// The byte the latest frame's first composer line starts at, kept first by
/// the next frame so the composer scrolls only when its caret leaves view.
draft_anchor: usize = 0,
worker: ClientTask = .{},
/// The Upgrade run's worker, for as long as the core says one runs, and
/// the receipts runs left, which print on exit.
upgrade_job: UpgradeJob = .{},
/// The serving Host's pid, read once per Host start.
host_process: ?struct { started_at: u64, pid: i32 } = null,
/// Last discovery observation, invalidated by a Session transport loss.
/// Counts in the view core are a projection of this same read, not a probe.
host_observation: HostObservation = .unread,
/// The last launch's typed summary, never a boolean standing in for a cause.
host_launch: ?HostLaunch = null,
/// This run's one automatic start after a crash (`host_restart`).
restart_allowance: host_restart.Allowance = .unspent,
upgrade_report: ?std.Io.Writer.Allocating = null,
/// The finished publication is retained after its worker frees the Check.
relaunch_build: ?[]const u8 = null,
upgrade_guidance: bool = false,
relaunch_line: [upgrade_status.max_line_bytes]u8 = undefined,
relaunch_line_len: usize = 0,
/// What the overview last said under the open conversation.
conversation_said: [upgrade_status.max_line_bytes]u8 = undefined,
/// The terminal title as last set: the open Session's name, if any, and how
/// many Sessions need the person.
title: session_chrome.Title = .{},
jobs: [max_jobs]Job = undefined,
job_count: usize = 0,
/// The job the worker runs or last ran, and what it left.
job: Job = .list,
answer: Answer = .none,
traversal: protocol_reply.SessionTraversal = .init(null),
traversal_archive: protocol.SessionArchiveFilter = .active,
/// Unlinked scratch for list pages.
scratch: ?std.Io.File = null,
/// Unlinked scratch a command's output goes to, made for the first command.
command_page: ?std.Io.File = null,

/// The Session a conversation borrows, in stable storage.
opened: view.Reference = undefined,
/// The overview's own step or job failed while a conversation held the
/// terminal: the failure is the overview's, not the Session's.
lent_failed: bool = false,
/// The Session the last accepted start made, for guidance if its
/// conversation fails.
started: ?view.Reference = null,
/// The screen holds no Session's state, so a conversation may use it as is.
screen_fresh: bool = true,
/// The screen is initialized, so `run` disposes of it.
screen_ready: bool = false,

/// Opens the overview and returns once the person leaves it, or a signal
/// stops it. Every way out restores the terminal, then returns a relaunch
/// value or prints the ordinary Detached notice once.
pub fn run(init: std.process.Init, options: Options, hooks: Hooks) !?Relaunch {
    const self = try create(init, options, hooks, client_operations, &Signals.cancellation);
    defer self.destroy();
    try self.restoreRelaunch();
    const screen = try init.gpa.create(SessionScreen);
    defer init.gpa.destroy(screen);
    const prepared: anyerror!void = prepare: {
        self.scratch = hooks.scratch(init) catch |err| break :prepare err;
        self.initScreen(screen) catch |err| break :prepare err;
        self.caps.width = screen.vx.caps.unicode;
    };
    prepared catch |err| return self.failed(err, options.open);
    defer if (self.screen_ready) screen.deinit();
    self.session_screen = screen;
    Signals.cancellation.stopped.store(false, .release);
    var app: TerminalApp = undefined;
    app.init(init.io, init.environ_map) catch |err| return self.failed(err, self.options.open);
    self.app = &app;
    self.attention = &app.attention;
    // Establish the read epoch before a direct resume can start its reader.
    // No worker exists yet; every later handshake uses the single worker.
    const ended = startup: {
        _ = self.takeHostRead(self.ops.host(self)) catch |err| break :startup @as(anyerror!void, err);
        break :startup app.run(self.root.widget());
    };
    self.stopApp();
    app.deinit();
    return self.finishApp(ended);
}

/// Stops the open Session's workers and the overview's before App releases
/// the terminal. A Session that failed to open has no frontend to stop.
fn stopApp(self: *Self) void {
    self.root.settings_page.closeStandaloneChoice();
    self.root.closeMainPresentation();
    self.sign_in.cancel();
    if (self.app_session) |left| if (left.frontend) |frontend| frontend.stop();
    self.worker.cancel();
}

fn initScreen(self: *Self, screen: *SessionScreen) !void {
    const no_colour: []const u8 = self.init.environ_map.get("NO_COLOR") orelse "";
    try screen.init(self.init.io, self.init.environ_map, no_colour.len == 0);
    self.screen_ready = true;
}

fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = appEvent, .drawFn = appDraw };
}

fn listWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = appListDraw };
}

fn composeWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = appEvent, .drawFn = appComposeDraw };
}

fn paintDivider(self: *Self) void {
    self.root.divider = .{
        .grapheme = if (self.caps.unicode) "│" else "|",
        .style = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet }),
    };
}

fn paintCursor(self: *Self) !void {
    self.paintDivider();
    if (self.caps.depth == .none) return;
    const theme = @import("theme.zig");
    const mode: theme.Mode = if (self.caps.skin() == .day) .light else .dark;
    const colour = theme.text(mode, .direct, .strong, .ground).direct;
    try self.attention.vx.setTerminalCursorColor(self.attention.out, colour);
}

fn paintGround(self: *Self) !void {
    if (self.caps.depth != .direct) return;
    const theme = @import("theme.zig");
    const mode: theme.Mode = if (self.caps.skin() == .day) .light else .dark;
    const colour = theme.background(mode, .direct, .ground).direct;
    try self.attention.vx.setTerminalBackgroundColor(self.attention.out, colour);
}

fn appEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .init => {
            const app = &self.app.?.app;
            self.caps.width = app.vx.caps.unicode;
            try app.vx.queryColor(app.tty.writer(), .bg);
            try self.paintCursor();
            try ctx.requestFocus(self.app_input.composer.widget());
            if (self.options.open) |reference| try self.appNext(ctx, try self.event(.{ .open = reference }));
        },
        .focus_in => try ctx.requestFocus(self.app_input.composer.widget()),
        .color_report => |report| if (report.kind == .bg) {
            self.caps.background = report.value;
            try self.paintCursor();
            try self.paintGround();
            if (self.app_session) |left| left.frontend.?.app_caps = self.caps;
            ctx.redraw = true;
        },
        .color_scheme => {
            const app = &self.app.?.app;
            try app.tty.writer().writeAll(vaxis.ctlseqs.osc11_reset);
            try app.vx.queryColor(app.tty.writer(), .bg);
        },
        .tick => {
            // A subsequent event is after App has replaced both the focus
            // path and mouse hit list, including their mouse_leave callbacks.
            if (self.signInIsFirstRun()) return;
            while (self.retired.items.len != 0 and self.retired.items[0].frame < self.root.frames) {
                self.disposeSession(self.retired.orderedRemove(0).left);
            }
            if (self.root.session != null) {
                // Under a Session the overview serves as it did when lending:
                // a failure there is the overview's, not the Session's. An
                // Upgrade holds Host work here as it does on the overview.
                if (self.state.upgrading()) try self.appUpgrade(ctx) else {
                    const answered = try service(self);
                    ctx.redraw = ctx.redraw or answered;
                }
            } else {
                if (self.worker.thread != null and self.worker.completed()) {
                    try self.appNext(ctx, try self.complete());
                    ctx.redraw = true;
                }
                const now = self.realMs();
                // An Upgrade holds Host work until it ends.
                if (self.state.upgrading()) try self.appUpgrade(ctx) else {
                    if (self.state.wakeAt()) |at| if (now >= at) {
                        try self.appNext(ctx, try self.event(.{ .tick = now }));
                        ctx.redraw = true;
                    };
                    try self.dispatch(.all);
                }
            }
            if (!self.root.input.layer.settingsOpen()) try self.root.settings_page.widget().handleEvent(ctx, .tick);
            if (self.wantsFrame()) ctx.redraw = true;
            const open: ?[]const u8 = if (self.app_session) |shown| if (shown.frontend) |frontend| frontend.titleName() else null else null;
            if (self.title.next(open, self.state.summary.counts.needs_you)) |text| try ctx.setTitle(text);
        },
        .mouse => |mouse| if (mouse.button == .left and mouse.type == .press and !self.root.input.layer.settingsOpen() and !self.root.settings_page.standaloneOpen()) {
            _ = try self.event(.{ .footer_input = .{ .click = null } });
            ctx.redraw = true;
        },
        else => {},
    }
}

/// Root hands the overview each key, paste mark and malformed key it
/// routes here, with what it arrived under and whether it is pasted. The
/// core decides what it means; this applies that and reads only the facts
/// other owners hold: the draft, the footer choice's answer and whether the
/// Host can start.
fn appKey(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event, delivery: @import("app_input.zig").Effects.Delivery) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const page = &self.root.settings_page;
    const result = try self.eventResult(.{ .key = .{
        .key = overviewKey(input),
        .pasted = delivery.pasted,
        .under = delivery.under,
        .draft = self.composerDraft(),
        .choice = if (page.standaloneField() != null) .{
            .shown = page.standaloneOpen(),
            .takes = if (delivery.pasted or input != .key_press) page.takesPaste() else page.takesKey(input.key_press),
        } else null,
        .host_startable = self.hostNext() != null,
    } });
    try self.appNext(ctx, result.next);
    switch (result.take) {
        .drop => {},
        .taken => ctx.redraw = true,
        .choice => {
            try page.standaloneWidget().handleEvent(ctx, input);
            ctx.redraw = true;
        },
        .close_choice => try self.closeStandaloneChoice(ctx),
        .start_host => try self.requestedHostStart(ctx),
        .edit => {
            const composed = self.composer.appEvent(view.keys, input, delivery.pasted);
            try self.appNext(ctx, try self.event(.{ .composed = .{ .input = .{ .composer = composed }, .draft = self.composerDraft() } }));
            ctx.redraw = true;
        },
    }
}

/// The overview core's name for one terminal input. Bindings match exact
/// modifiers, as the line editor's do.
fn overviewKey(input: vxfw.Event) view.Key {
    return switch (input) {
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .invalid_key => .invalid,
        .key_press => |key| if (TerminalEditor.named(key)) |name| .{ .named = name } else if (TerminalEditor.isEnter(key)) .enter else if (key.matchExact(vaxis.Key.tab, .{})) .tab else if (key.matchExact(vaxis.Key.tab, .{ .shift = true })) .shift_tab else if (SessionFrontend.hostStartKey(key)) .host_start else if (TerminalEditor.selectKey(view.keys, key) == .text) .text else .other,
        // Root routes only these to the overview.
        else => unreachable,
    };
}

/// A click the screen's widgets name steps the core as a key does.
fn appClick(raw: *anyopaque, ctx: *vxfw.EventContext, click: view.Click) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.appNext(ctx, try self.event(.{ .clicked = .{ .target = click, .draft = self.composerDraft(), .pasting = self.root.input.pasting } }));
    if (click == .new_session and self.state.inputMode() != .frozen and self.root.session == null) try ctx.requestFocus(self.widget());
    ctx.redraw = true;
}

/// A press on a command list row names the row as the frame drew it; the
/// core decides what it does, as for every other click.
fn appPaletteSelect(raw: *anyopaque, ctx: *vxfw.EventContext, pressed: slash_commands.Shown.Pick) anyerror!void {
    try appClick(raw, ctx, .{ .command = pressed });
}

fn appNext(self: *Self, ctx: *vxfw.EventContext, next: ?Next) !void {
    switch (next orelse return) {
        .leave => {
            self.root.settings_page.closeStandaloneChoice();
            self.root.closeMainPresentation();
            ctx.quit = true;
        },
        .open_settings => try self.root.openSettings(ctx),
        .open_choice => |field| {
            try self.root.settings_page.openStandaloneChoice(ctx, switch (field) {
                .model => .model,
                .effort => .effort,
            }, self.state.nextStart());
            try ctx.requestFocus(self.app_input.composer.widget());
            ctx.redraw = true;
        },
        .open => |reference| {
            try self.root.showMain(ctx);
            if (self.root.session != null) {
                try self.app_session.?.frontend.?.openPeer(ctx, &reference);
                return;
            }
            _ = self.composer.blur();
            self.opened = reference;
            self.ops.open(self, ctx) catch |err| {
                // Departure names the Session that could not open.
                if (self.app_session == null) self.app_session = .{ .session = reference, .frontend = null, .files = null, .ended = err };
                ctx.quit = true;
            };
        },
    }
}

/// Opens `self.opened` as a Session widget under Root.
fn openSession(self: *Self, ctx: *vxfw.EventContext) !void {
    const reference = self.opened;
    const screen = self.session_screen;
    if (!self.screen_fresh) {
        screen.deinit();
        self.screen_ready = false;
        try self.initScreen(screen);
    }
    self.screen_fresh = false;
    var opened: [6]std.Io.File = undefined;
    var count: usize = 0;
    errdefer for (opened[0..count]) |file| file.close(self.init.io);
    for (&opened) |*file| {
        file.* = try self.hooks.scratch(self.init);
        count += 1;
    }
    const files: SessionFrontend.Files = .{ .scratch = opened[0], .action = opened[1], .inspection = opened[2], .details = opened[3], .actions = opened[4..6].* };
    const frontend = try self.init.gpa.create(SessionFrontend);
    const lender: SessionFrontend.Lender = .{ .context = self, .step = conversed, .service = service, .line = conversationLine, .observed = observed, .upgrade = upgradeValue, .archive_state = archiveState, .models = modelsSnapshot };
    frontend.begin(self.init, self.options.store, &self.opened, self.options.directory, files, self.hooks.command, self.hooks.requests, self.hooks.status, screen, self.interrupted, lender);
    const child = frontend.attach(.{ .configure = self.hooks.configure, .drafts = &self.session_drafts, .root = &self.root, .context = self, .leave = appSessionLeft, .copy = appCopy, .on_open = appSessionFollow, .host = .{ .context = self, .held = hostHeld, .lost = hostLost, .start = requestHostStart, .notice = hostNotice } }, self.caps);
    // Custody transfers before focus delivery: on failure the exit
    // path cancels and joins the same frontend before freeing it.
    self.app_session = .{ .session = reference, .frontend = frontend, .files = files, .ended = .detached };
    count = 0;
    _ = try self.event(.{ .conversation = reference });
    try self.root.openSession(ctx, child);
}

fn appSessionLeft(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const left = &self.app_session.?;
    const from = left.session;
    left.ended = outcome;
    if (outcome == .returned) switch (left.frontend.?.back(view.canHoldSend(&self.state))) {
        .ended => |ended| left.ended = ended,
        .overview => |recovery| {
            if (recovery != .none) _ = try self.event(.{ .unconfirmed = .{ .reference = left.session, .recovery = recovery } });
            if (self.options.selectors.needsPreferences()) {
                if (self.savedEffort()) |effort| {
                    if (self.state.default) |*binding| binding.effort = effort;
                } else |_| {}
            }
            try self.retired.append(self.init.gpa, .{ .left = left.*, .frame = self.root.frames });
            self.app_session = null;
            _ = try self.event(.{ .conversation = null });
            try self.root.closeSession(ctx);
            // App's last frame can still point at the old widgets. Dispose
            // only after the next frame replaces that focus/hit-test tree.
            return self.followNext(ctx, from);
        },
    };
    ctx.quit = true;
}

/// A clicked Session link: open it once the current Session has left.
fn appSessionFollow(raw: *anyopaque, _: *vxfw.EventContext, target: *const [session_id.bytes]u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.follow.pending = target.*;
}

/// After leaving `from`, opens the Session a link named, or the one a
/// followed link left, as opening it from the overview does.
fn followNext(self: *Self, ctx: *vxfw.EventContext, from: view.Reference) !void {
    if (self.follow.next(from)) |target| try self.appNext(ctx, try self.event(.{ .open = target }));
}

fn appCopy(raw: *anyopaque, file: std.Io.File, start: u64, length: u64) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const bytes = try self.init.gpa.alloc(u8, @intCast(length));
    defer self.init.gpa.free(bytes);
    if (try file.readPositionalAll(self.init.io, bytes, start) != bytes.len) return error.TruncatedDisplayScratch;
    const app = &self.app.?.app;
    try app.vx.copyToSystemClipboard(app.tty.writer(), bytes, self.init.gpa);
}

/// Runs the Upgrade the core says is going: once the overview's own Host
/// work has settled, the check and install run on their worker. The core
/// is told where the run stands whenever that differs from what it holds,
/// so the worker is the one place the run's state is decided.
fn appUpgrade(self: *Self, ctx: *vxfw.EventContext) !void {
    const job = &self.upgrade_job;
    // A failed start finishes the run, which the core is told below.
    if (!job.started and try self.quiesceUpgrade() and self.conversationSettled()) job.begin(self.init, self.options.store) catch {};
    const done = job.started and try job.advance();
    const stands = job.status();
    if (!std.meta.eql(stands, self.state.upgrade.run.?)) {
        try self.appNext(ctx, try self.event(.{ .upgrade = stands }));
        ctx.redraw = true;
    }
    if (done) {
        const installed = job.relaunchBuild() != null;
        try self.keepUpgrade();
        if (installed) self.leaveForUpgrade(ctx, stands.ended.outcome);
    }
}

fn leaveForUpgrade(self: *Self, ctx: *vxfw.EventContext, outcome: session_upgrade.Outcome) void {
    if (self.relaunch_build == null) return;
    if (session_upgrade.relaunch(outcome, self.upgrade_guidance or self.pendingDepartureGuidance())) {
        ctx.quit = true;
    } else {
        // A guided run retains today's screen and exit behavior. A later
        // ordinary quit is not a delayed request to relaunch.
        self.init.gpa.free(self.relaunch_build.?);
        self.relaunch_build = null;
    }
}

/// Do not leave the screen automatically when guidance is already known.
/// The settled departure is still authoritative for failures found on leave.
noinline fn pendingDepartureGuidance(self: *const Self) bool {
    var bytes: [view.max_requests * 512 + view.max_late_command_bytes]u8 = undefined;
    var text = std.Io.Writer.fixed(&bytes);
    self.departureText(&text);
    if (text.buffered().len != 0) return true;
    if (self.app_session) |left| return if (left.frontend) |frontend| frontend.hasDepartureGuidance() else true;
    return false;
}

/// The open conversation, if any, has no Client work of its own in flight.
fn conversationSettled(self: *const Self) bool {
    const shown = self.app_session orelse return true;
    const frontend = shown.frontend orelse return true;
    return self.root.session == null or frontend.atRest();
}

/// Keeps a finished run's receipt for exit, the full report when it
/// failed, retained cleanup or left an unusable Host, and frees the run.
fn keepUpgrade(self: *Self) !void {
    const job = &self.upgrade_job;
    if (!job.started) return;
    self.upgrade_guidance = self.upgrade_guidance or job.hasGuidance();
    if (self.relaunch_build) |build| self.init.gpa.free(build);
    self.relaunch_build = null;
    if (job.relaunchBuild()) |build| {
        self.relaunch_build = try self.init.gpa.dupe(u8, build);
        const stands = job.status();
        const line = upgrade_status.relaunchLine(stands, &self.relaunch_line, if (self.caps.unicode) .unicode else .ascii);
        self.relaunch_line_len = line.len;
    }
    const detailed = job.failure != null or job.cleanup.any() or job.outcome == .incompatible;
    if (detailed or job.result != null) {
        if (self.upgrade_report == null) self.upgrade_report = .init(self.init.gpa);
        const writer = &self.upgrade_report.?.writer;
        if (detailed) try job.writeReport(writer) else try job.writeReceipt(writer);
    }
    job.deinit();
}

fn disposeSession(self: *Self, left: Left) void {
    if (left.files) |files| {
        inline for (.{ "scratch", "action", "inspection", "details" }) |name| @field(files, name).close(self.init.io);
        for (files.actions) |file| file.close(self.init.io);
    }
    if (left.frontend) |frontend| self.init.gpa.destroy(frontend);
}

fn finishApp(self: *Self, ended: anyerror!void) !?Relaunch {
    const sign_in_ended = self.sign_in.stop();
    defer {
        for (self.retired.items) |retired| self.disposeSession(retired.left);
        self.retired.deinit(self.init.gpa);
    }
    self.upgrade_job.settle();
    const kept = self.keepUpgrade();
    self.worker.cancel();
    const answered: anyerror!?Next = if (self.event(.leave)) |_| self.complete() else |err| err;
    const saved = self.flushSaves();
    var left = self.app_session;
    self.app_session = null;
    defer if (left) |held| self.disposeSession(held);
    var departure: ?SessionFrontend.Departure = null;
    if (left) |*held| {
        ended catch |err| {
            held.ended = err;
        };
        if (answered) |_| {} else |err| {
            held.ended = err;
        }
        saved catch |err| {
            held.ended = err;
        };
        kept catch |err| {
            held.ended = err;
        };
        sign_in_ended catch |err| {
            held.ended = err;
        };
        if (held.frontend) |frontend| departure = frontend.settleDeparture(held.ended, {});
    }
    return self.finishDeparture(ended, answered, saved, kept, sign_in_ended, left, departure);
}

/// One rendered departure supplies both the pure decision and fallback output.
/// Keep its bounded scratch off the ordinary finish frame.
noinline fn finishDeparture(self: *Self, ended: anyerror!void, answered: anyerror!?Next, saved: anyerror!void, kept: anyerror!void, sign_in_ended: anyerror!void, left: ?Left, departure: ?SessionFrontend.Departure) !?Relaunch {
    var bytes: [view.max_requests * 512 + view.max_late_command_bytes]u8 = undefined;
    var text = std.Io.Writer.fixed(&bytes);
    self.departureText(&text);
    const has_failure = std.meta.isError(ended) or std.meta.isError(answered) or std.meta.isError(saved) or std.meta.isError(kept) or std.meta.isError(sign_in_ended);
    const guidance = has_failure or self.upgrade_guidance or text.buffered().len != 0 or
        (if (departure) |value| value.has_guidance else left != null);
    // The core decides only after all leave work has settled. Encoding failure
    // preserves today's departure instead of losing an unsent draft.
    const outcome: session_upgrade.Outcome = if (self.state.upgrade.run) |stands| if (stands == .ended) stands.ended.outcome else .unchanged else .unchanged;
    if (session_upgrade.relaunch(outcome, guidance) and self.relaunch_build != null) {
        if (self.makeRelaunch(left)) |request| return request else |_| {}
    }
    if (self.upgrade_report) |*report| _ = stderr.writeReceipt(report.written());
    _ = stderr.write(text.buffered());
    if (left) |held| {
        // `finish` has already joined this frontend. Leave only emits the
        // original guidance; the defer above disposes its scratch and editor.
        try self.leaveFinished(held, departure);
        return null;
    }
    try sign_in_ended;
    TerminalApp.detached(self.options.store, null, null);
    try ended;
    _ = try answered;
    try saved;
    try kept;
    return null;
}

fn makeRelaunch(self: *Self, left: ?Left) !Relaunch {
    const gpa = self.init.gpa;
    // Put the open editor back under the sparse draft owner before encoding.
    // The copied snapshot remains owned here until encoding succeeds.
    if (left) |held| if (held.frontend) |frontend| {
        try self.session_drafts.put(gpa, &held.session, frontend.input.snapshot());
    };
    var entries: std.ArrayList(handoff.Entry) = .empty;
    defer entries.deinit(gpa);
    var drafts = self.session_drafts.iterator();
    while (drafts.next()) |entry| try entries.append(gpa, .{ .id = entry.id, .snapshot = entry.snapshot });
    const bytes = try handoff.encode(gpa, .{
        .v = 1,
        .store = self.options.store,
        .open = if (left) |*held| &held.session else null,
        .overview = .{ .bytes = self.draft[0..self.composer.length], .cursor = self.composer.cursor, .rejected = self.composer.rejected },
        .drafts = entries.items,
        .line = self.relaunch_line[0..self.relaunch_line_len],
    });
    errdefer gpa.free(bytes);
    const executable = try std.fmt.allocPrint(gpa, "{s}/bin/rui", .{self.relaunch_build.?});
    errdefer gpa.free(executable);
    const receipt = try gpa.dupe(u8, if (self.upgrade_report) |*report| report.written() else "");
    return .{ .executable = executable, .handoff = bytes, .receipt = receipt, .open = if (left) |held| held.session else null };
}

/// Apply the CLI-owned startup value once; every restored byte becomes owned.
fn restoreRelaunch(self: *Self) !void {
    const value = self.options.restoration orelse return;
    self.options.restoration = null;
    // Copy every inactive draft before restoring the composer or opening a chat.
    // An allocation failure refuses startup rather than showing a partial handoff.
    for (value.drafts) |entry| try self.session_drafts.put(self.init.gpa, entry.id, entry.snapshot);
    @memcpy(self.draft[0..value.overview.bytes.len], value.overview.bytes);
    self.composer.length = value.overview.bytes.len;
    self.composer.cursor = value.overview.cursor;
    self.composer.rejected = value.overview.rejected;
    if (value.open) |id| self.options.open = id[0..session_id.bytes].*;
    var notice: view.Notice = .{ .colour = .normal };
    @memcpy(notice.bytes[0..value.line.len], value.line);
    notice.len = value.line.len;
    self.state.notice = notice;
}

/// The Sessions list's rows for one frame, each with what a click on it
/// names.
const SessionRows = struct {
    state: *const view.State,
    width: u16,
    caps: view.Caps,
    frame: u64,

    fn count(raw: *const anyopaque, first: u32) u32 {
        const self: *const SessionRows = @ptrCast(@alignCast(raw));
        return @intCast(self.state.order.items.len -| (first -| view.firstRowLine(self.state)));
    }

    fn above(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!@import("widgets/List.zig").Line {
        return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count_}) }});
    }

    fn below(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!@import("widgets/List.zig").Line {
        const segments = try arena.alloc(vaxis.Segment, 1);
        segments[0] = .{ .text = try std.fmt.allocPrint(arena, "↓ {d} more", .{count_}) };
        return segments;
    }

    fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!GroupedList.Row {
        const self: *const SessionRows = @ptrCast(@alignCast(raw));
        const item = view.listItem(self.state, index).?;
        const built = try view.listSegments(arena, self.state, item, self.width, self.caps, self.frame);
        return .{ .segments = built.segments, .second = if (item == .row) try view.rowSecondSegments(arena, self.state, item.row, self.width, self.caps) else null, .height = if (item == .row) 2 else 1, .heading = built.heading, .target = view.clickOf(self.state, item) };
    }
};

/// A panel's lines for one frame.
const PanelRows = struct {
    items: []const view.ListRow,

    fn row(raw: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!GroupedList.Row {
        const self: *const PanelRows = @ptrCast(@alignCast(raw));
        return .{ .segments = self.items[index].segments, .heading = self.items[index].heading };
    }
};

fn rich(ctx: vxfw.DrawContext, caps: view.Caps, segments: []const view.Segment) !vxfw.Widget {
    const spans = try ctx.arena.alloc(vaxis.Segment, segments.len);
    for (segments, spans) |segment, *span| span.* = .{ .text = segment.text, .style = @import("widget_style.zig").of(caps, segment.style) };
    const text = try ctx.arena.create(vxfw.RichText);
    text.* = .{ .text = spans, .softwrap = false, .width_basis = .parent };
    return text.widget();
}

fn wantsFrame(self: *const Self) bool {
    return self.wantsFrameAt(self.animationFrame());
}

/// Whether a spinning mark on screen has a step to turn at spinner `frame`.
fn wantsFrameAt(self: *const Self, frame: u64) bool {
    return self.root.listVisible() and frame != self.app_frame and self.listSpins();
}

/// The drawn viewport is history; which current rows spin is derived. No
/// animation-eligibility flag survives a row, capability or list-area change.
fn listSpins(self: *const Self) bool {
    if (self.state.listArea() != .sessions) return false;
    for (self.app_sessions.shown.first..self.app_sessions.shown.end) |at| {
        const item = view.listItem(&self.state, at) orelse break;
        if (view.markSpins(&self.state, item, self.caps)) return true;
    }
    return false;
}

fn animationFrame(self: *const Self) u64 {
    const now = std.Io.Clock.awake.now(self.init.io).nanoseconds;
    return @intCast(@divFloor(@max(now, 0), std.time.ns_per_ms * view.spin_interval_ms));
}

fn appDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawPart(ctx, .whole);
}

fn appListDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawPart(ctx, .list);
}

fn appComposeDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawPart(ctx, .compose);
}

/// A visible conversation determines the highlight without changing the
/// overview's own selection or borrowing a row's storage across frames.
fn selectedListLine(self: *const Self) ?u32 {
    const open = self.state.conversing orelse return if (view.selectedLine(&self.state)) |line| @intCast(line) else null;
    var line: usize = 0;
    while (view.listItem(&self.state, line)) |item| : (line += 1) {
        const target = view.clickOf(&self.state, item) orelse continue;
        if (target == .open and std.mem.eql(u8, &target.open, &open)) return @intCast(line);
    }
    return null;
}

/// Each visible part prepares only what it draws, at that part's width:
/// rows once on the left, the Footer once on the right, or both when narrow.
fn drawPart(self: *Self, ctx: vxfw.DrawContext, part: AppScreen.Overview.Part) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    self.caps.width = self.attention.vx.caps.unicode;
    const normal = @import("widget_style.zig").of(self.caps, .{});
    self.sign_in.style = normal;
    self.sign_in.quiet = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet });
    const quiet = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet });
    self.app_screen.style = normal;
    var list: ?*GroupedList = null;
    const host = if (part == .list) null else hostNotice(self);
    if (part != .compose) {
        // The list pane alone carries no Host line; elsewhere `layout`
        // counts its row so the list and Settings tail end above it.
        self.state.host_line = host != null;
        _ = try view.step(&self.state, .{ .resized = .{ .width = size.width, .height = size.height } });
        const frame = self.animationFrame();
        self.app_frame = frame;
        // The core says what fills the list; this frame draws that widget.
        const prepared: *GroupedList = switch (self.state.listArea()) {
            .panel => panel: {
                const rows = try ctx.arena.create(PanelRows);
                rows.* = .{ .items = (try view.panelItems(ctx.arena, &self.state, size.width, self.caps)).? };
                self.app_panel.rows = .{ .userdata = rows, .count = @intCast(rows.items.len), .rowFn = PanelRows.row };
                break :panel &self.app_panel;
            },
            .sessions => sessions: {
                const rows = try ctx.arena.create(SessionRows);
                rows.* = .{ .state = &self.state, .width = size.width, .caps = self.caps, .frame = frame };
                self.app_sessions.selected = self.selectedListLine();
                self.app_sessions.rows = .{ .userdata = rows, .count = @intCast(view.listLength(&self.state)), .rowFn = SessionRows.row, .countFromFn = SessionRows.count };
                self.app_sessions.aboveFn = SessionRows.above;
                self.app_sessions.belowFn = SessionRows.below;
                break :sessions &self.app_sessions;
            },
        };
        self.app_settings_line.selected = self.state.selected == .settings;
        self.app_settings_line.caps = self.caps;
        prepared.tail = .{ .widget = self.app_settings_line.widget(), .rows = view.layout(&self.state).settings.len() };
        prepared.caps = self.caps;
        self.app_screen.content = prepared;
        list = prepared;
        self.app_header.caps = self.caps;
        if (view.showsNewSession(&self.state)) {
            self.app_new_session.caps = self.caps;
            const header = try ctx.arena.create(@import("widgets/Stack.zig"));
            header.* = .{ .priority = .top, .children = try ctx.arena.dupe(@import("widgets/Stack.zig").Child, &.{
                .{ .widget = self.app_new_session.widget() },
                .{ .widget = self.app_header.widget() },
            }) };
            self.app_screen.header = header.widget();
        } else self.app_screen.header = self.app_header.widget();
    }
    if (part != .list) {
        self.app_input.composer.style = normal;
        self.app_input.composer.quiet = quiet;
        self.app_input.composer.method = self.caps.width;
        self.app_input.composer.ascii = !self.caps.unicode;
        self.app_input.composer.caret = self.state.inputMode() != .frozen and self.state.footer.focus == .input and !self.root.settings_page.standaloneOpen();
        self.state.commands = view.nextCommands(&self.state, self.composerDraft());
        self.app_input.facts = .{ .userdata = self, .drawFn = appFooterDraw };
        self.app_input.status = if (try view.noticeSegments(ctx.arena, &self.state, size.width, self.caps)) |notice| try rich(ctx, self.caps, notice) else .{ .userdata = self, .drawFn = emptyStatus };
        self.app_screen.tail = null;
        self.app_screen.overlay = null;
        self.app_screen.overlay_reserves_space = false;
        if (self.root.settings_page.standaloneOpen()) {
            self.app_screen.overlay = self.root.settings_page.standaloneWidget();
            self.app_screen.overlay_reserves_space = true;
        } else if (self.state.commands) |*shown| {
            self.app_palette.shown = shown;
            self.app_palette.style = normal;
            self.app_palette.quiet = quiet;
            self.app_palette.hover_style = @import("widget_style.zig").of(self.caps, .{ .background = .hover });
            self.app_palette.method = self.caps.width;
            self.app_palette.userdata = self;
            self.app_palette.on_select = appPaletteSelect;
            self.app_screen.overlay = self.app_palette.widget();
        }
    }
    defer {
        if (list) |prepared| {
            prepared.rows = .none;
            prepared.tail = null;
        }
        self.app_screen.header = null;
        self.app_screen.tail = null;
        self.app_input.facts = app_empty.widget();
        self.app_input.status = app_empty.widget();
    }
    self.app_screen.host = host;
    var surface = try self.app_screen.drawPart(ctx, part);
    // The overview remains the compose ancestor in either layout, so a
    // resize never changes the composer's focus identity or key route.
    surface.widget = if (part == .list) self.listWidget() else self.widget();
    return surface;
}

fn appModelClick(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    try appClick(raw, ctx, .{ .footer = .model });
}

fn appEffortClick(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    try appClick(raw, ctx, .{ .footer = .effort });
}

/// Both Escape and its drawn action close only this presentation.
fn closeStandaloneChoice(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.root.settings_page.standaloneField() == null) return;
    self.root.settings_page.closeStandaloneChoice();
    _ = try self.event(.{ .footer_input = .escape });
    try ctx.requestFocus(self.app_input.composer.widget());
    ctx.redraw = true;
}

fn appChoiceClose(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.root.input.pasting) return;
    try self.closeStandaloneChoice(ctx);
}

fn appChoicePick(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!self.root.settings_page.standaloneOpen() or self.root.input.pasting) return;
    try self.root.settings_page.standaloneWidget().handleEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
}

/// Footer owns the cells; the core's spans supply their drawn identities.
fn appFooterDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    const choice: ?view.ChoiceKeys = if (self.root.settings_page.standaloneOpen()) view.choiceKeys(self.root.settings_page.hasChoice()) else null;
    const keys = if (choice) |shown| shown.text else view.footerKeys(&self.state, self.composerDraft(), false);
    var footer: @import("widgets/Footer.zig") = .{
        .left = "",
        .right = keys,
        .notice = if (view.footerNotice(&self.state)) |notice| try @import("session_chrome.zig").noticeLine(ctx.arena, notice) else null,
        .style = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet, .background = .bar }),
    };
    if (self.state.notice) |notice| footer.right_style = @import("widget_style.zig").of(self.caps, .{ .colour = notice.colour, .background = .bar });
    const width = size.width -| @as(u16, @intCast(@min(ctx.stringWidth(footer.rightText()), size.width)));
    const spans = try view.footerSpans(ctx.arena, &self.state, width, self.caps);
    var text: std.ArrayList(u8) = .empty;
    var column: usize = 0;
    for (spans) |fact| {
        try text.appendNTimes(ctx.arena, ' ', fact.span.column - column);
        try text.appendSlice(ctx.arena, fact.span.text);
        column = fact.span.column + fact.span.cells;
    }
    footer.left = text.items;
    var surface = try footer.widget().draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = appFooterDraw };
    const children = try ctx.arena.alloc(vxfw.SubSurface, 4);
    var count: usize = 0;
    if (surface.size.height != 0) for (spans) |fact| if (fact.button) |field| {
        const chip = switch (field) {
            .model => &self.app_model,
            .effort => &self.app_effort,
        };
        chip.label = fact.span.text;
        chip.method = self.caps.width;
        const focused = switch (field) {
            .model => self.state.footer.focus == .model,
            .effort => self.state.footer.focus == .effort,
        };
        chip.style = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet, .background = if (focused) .selection else .bar });
        chip.hover = chip.style;
        chip.hover.ul_style = .single;
        children[count] = .{ .origin = .{ .row = 0, .col = fact.span.column }, .surface = try chip.widget().draw(ctx.withConstraints(.{}, .{ .width = fact.span.cells, .height = 1 })) };
        count += 1;
    };
    if (surface.size.height != 0 and footer.notice == null) if (choice) |shown| {
        const right_width: u16 = @intCast(@min(ctx.stringWidth(keys), size.width));
        var col: usize = size.width - right_width;
        for (shown.actions, 0..) |action, index| {
            if (index > 0) col += ctx.stringWidth(" · ");
            const chip = switch (action.action) {
                .pick => &self.app_choice_pick,
                .close => &self.app_choice_close,
            };
            chip.label = action.text;
            chip.method = self.caps.width;
            chip.style = footer.style;
            chip.hover = chip.style;
            chip.hover.ul_style = .single;
            if (col < size.width) {
                const cells: u16 = @intCast(@min(ctx.stringWidth(action.text), size.width - col));
                children[count] = .{ .origin = .{ .row = 0, .col = @intCast(col) }, .surface = try chip.widget().draw(ctx.withConstraints(.{}, .{ .width = cells, .height = 1 })) };
                count += 1;
            }
            col += ctx.stringWidth(action.text);
        }
    };
    surface.children = children[0..count];
    return surface;
}

fn emptyStatus(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    return .empty(app_empty.widget());
}

const app_empty: vxfw.Text = .{ .text = "" };

fn failed(self: *const Self, err: anyerror, session: ?view.Reference) anyerror {
    return printFailure(err, self.options.store, session, self.started);
}

/// Prints guidance for a failure and returns it: how to fix TMPDIR, and the
/// Session to resume when one was being opened.
pub fn printFailure(err: anyerror, store: []const u8, session: ?view.Reference, started: ?view.Reference) anyerror {
    // Four bytes per escaped selector byte, plus labels and hex syntax.
    var bytes: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 384]u8 = undefined;
    var notice = std.Io.Writer.fixed(&bytes);
    write: {
        if (err == error.InvalidTemporaryDirectory)
            notice.writeAll(if (session == null) "rui: Fix or unset TMPDIR before opening the overview.\n" else "rui: Fix or unset TMPDIR before resuming.\n") catch break :write;
        const reference = session orelse break :write;
        if (started) |start| if (std.mem.eql(u8, &start, &reference)) {
            notice.print("\nrui: Started {s}.\n", .{&reference}) catch break :write;
        };
        notice.writeAll("\nResume: rui session resume --store ") catch break :write;
        TerminalText.writeShellWord(&notice, store) catch break :write;
        TerminalText.writeShellSession(&notice, &reference, true) catch break :write;
        notice.writeByte('\n') catch break :write;
    }
    _ = stderr.write(notice.buffered());
    return err;
}

fn create(init: std.process.Init, options: Options, hooks: Hooks, ops: Operations, interrupted: *client.Cancellation) !*Self {
    const self = try init.gpa.create(Self);
    errdefer init.gpa.destroy(self);
    self.* = .{
        .init = init,
        .options = options,
        .hooks = hooks,
        .ops = ops,
        .state = undefined,
        .caps = .of(.{ .lc_all = init.environ_map.get("LC_ALL"), .lc_ctype = init.environ_map.get("LC_CTYPE"), .lang = init.environ_map.get("LANG"), .no_color = init.environ_map.get("NO_COLOR"), .colorterm = init.environ_map.get("COLORTERM") }),
        .interrupted = interrupted,
    };
    self.composer = self.emptyComposer(0);
    self.root = .{ .main_presentation = .{ .context = self, .close = closeMainPresentation }, .overview = self.widget(), .overview_keys = .{ .context = self, .take = appKey }, .list = self.listWidget(), .compose = self.composeWidget(), .settings_page = .{ .backend = self.settingsBackend(), .version = @import("transport_options").version }, .input = .{ .layer = if (options.sign_in) .{ .sign_in = .{ .over = .main } } else .main } };
    self.sign_in = .{ .init = init, .selectors = options.selectors, .activate = hooks.activate, .ready = hooks.ready, .userdata = self, .on_done = signedIn, .on_close = closeSignIn, .list_visible = listVisible };
    self.root.sign_in = self.sign_in.widget();
    self.paintDivider();
    // The status's rows sit above the one Footer row.
    self.app_input = .{ .composer = .{ .editor = &self.composer, .placeholder = "Type a task" }, .facts_at = .bottom };
    self.app_screen = .{ .content = &self.app_sessions, .input = &self.app_input, .userdata = self, .on_event = appEvent };
    self.app_header = .{ .state = &self.state };
    self.app_new_session = .{ .state = &self.state, .caps = self.caps, .userdata = self, .on_click = appClick };
    self.app_model = .{ .label = "", .userdata = self, .on_click = appModelClick };
    self.app_effort = .{ .label = "", .userdata = self, .on_click = appEffortClick };
    self.app_choice_pick = .{ .label = "", .userdata = self, .on_click = appChoicePick };
    self.app_choice_close = .{ .label = "", .userdata = self, .on_click = appChoiceClose };
    self.app_settings_line = .{ .selected = false, .caps = self.caps, .userdata = self, .on_click = appClick };
    self.app_sessions.on_press = .{ .userdata = self, .pressed = appClick };
    try self.state.init(init.gpa, .{ .cwd = options.workspace, .home = options.home, .login_at = options.login_at, .default = .of(options.provider, options.model) });
    errdefer self.state.deinit();
    if (self.state.default) |*binding| binding.effort = self.savedEffort() catch null;
    return self;
}

fn closeMainPresentation(raw: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = self.state.footer.step(false, .escape);
    if (self.app_session) |left| if (left.frontend) |frontend| frontend.closePresentation();
}

fn openSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.sign_in.task.thread != null) return;
    if (!view.admitsDefaultsEdit(&self.state) or self.defaults_save == .pending) return error.DefaultsUnavailable;
    self.sign_in.reset();
    self.sign_in.selectors = self.options.selectors;
    self.sign_in.selectors.store = self.options.store;
    try self.root.openSignIn(ctx);
}

fn listVisible(raw: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.root.listVisible();
}

/// The first-run screen is the only thing the app can do, so it stays until
/// sign-in gives a default; a screen opened from Settings always returns there.
fn signInIsFirstRun(self: *const Self) bool {
    return self.root.input.layer.signInOpen() and !self.root.input.layer.settingsOpen() and self.state.default == null;
}

fn closeSignIn(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.signInIsFirstRun()) return;
    try self.root.closeSignIn(ctx);
}

fn signedIn(raw: *anyopaque, ctx: *vxfw.EventContext, activation: SignIn.Activation) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const effort = try self.savedEffort();
    if (!std.mem.eql(u8, self.options.store, activation.store.slice())) {
        // Only first-run selection can change the Store. Settings pins the
        // current Store, whose ongoing readers retain their borrowed path.
        std.debug.assert(self.worker.thread == null);
        self.signed_in_store = activation.store;
        self.options.store = self.signed_in_store.slice();
    }
    var saved = view.Default.of(activation.binding.provider.slice(), activation.binding.model.slice());
    if (saved) |*value| value.effort = effort;
    try self.appNext(ctx, try self.event(.{ .defaults_saved = saved }));
    self.state.login_at = self.realMs() / 1000;
    self.state.next_list_ms = 0;
    const warning = if (activation.launch) |*launch| launch.warning else null;
    if (activation.default_failed or warning != null) {
        var notice: view.Notice = .{ .colour = .failure };
        var writer = std.Io.Writer.fixed(&notice.bytes);
        if (warning != null) {
            try @import("host_launch.zig").writeSignIn(&writer, .{ .ready = warning }, activation.default_failed, false);
        } else try writer.writeAll("Sign-in saved; couldn't save default");
        notice.len = writer.buffered().len;
        self.state.notice = notice;
    }
    try self.root.signedIn(ctx);
    if (self.root.session == null) try ctx.requestFocus(self.app_input.composer.widget());
}

/// Accept one typed preference edit. Only this owner writes its worker queue;
/// the page borrows the saved values and the answered status, never the job.
pub fn saveDefaults(self: *Self, edit: preferences.Edit) !void {
    if (!view.admitsDefaultsEdit(&self.state) or self.defaults_save == .pending or self.job_count == max_jobs) return error.DefaultsUnavailable;
    const owned = try DefaultsEdit.init(self.init.gpa, edit);
    self.queue(.{ .defaults = owned });
    self.defaults_save = .pending;
}

/// Use the same Upgrade transition and worker lifecycle as the other screens.
pub fn startUpgrade(self: *Self) !void {
    if (self.state.left) return error.UpgradeUnavailable;
    if (self.app_session) |shown| if (shown.frontend) |frontend| {
        if (!frontend.admitsUpgrade()) return error.UpgradeUnavailable;
    };
    const next = try self.event(.start_upgrade);
    std.debug.assert(next == null);
}

/// The bridge stays with its concrete owner, avoiding both an import back into
/// Overview and a generic adapter with access to this owner's representation.
fn settingsBackend(self: *Self) AppSettings.Backend {
    const Callbacks = struct {
        fn owner(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }
        fn read(raw: *anyopaque) !preferences.Values {
            return preferences.load(owner(raw).options.home);
        }
        fn save(raw: *anyopaque, edit: preferences.Edit) !void {
            return owner(raw).saveDefaults(edit);
        }
        fn saveState(raw: *anyopaque) AppSettings.SaveState {
            return owner(raw).defaults_save;
        }
        fn upgrade(raw: *anyopaque) !void {
            return owner(raw).startUpgrade();
        }
        fn run(raw: *anyopaque) ?upgrade_status.Run {
            return owner(raw).state.upgrade.run;
        }
        fn signIn(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
            try owner(raw).openSignIn(ctx);
        }
        fn caps(raw: *anyopaque) view.Caps {
            return owner(raw).caps;
        }
    };
    return .{ .context = self, .read = Callbacks.read, .save = Callbacks.save, .save_state = Callbacks.saveState, .upgrade = Callbacks.upgrade, .run = Callbacks.run, .caps = Callbacks.caps, .models = modelsSnapshot, .sign_in = Callbacks.signIn };
}

fn destroy(self: *Self) void {
    self.session_drafts.deinit(self.init.gpa);
    std.debug.assert(self.worker.thread == null);
    self.upgrade_job.deinit();
    if (self.relaunch_build) |build| self.init.gpa.free(build);
    if (self.upgrade_report) |*report| report.deinit();
    self.job.deinit(self.init.gpa);
    for (self.jobs[0..self.job_count]) |job| job.deinit(self.init.gpa);
    if (self.scratch) |file| file.close(self.init.io);
    if (self.command_page) |file| file.close(self.init.io);
    self.state.deinit();
    self.answer.deinit(self.init.gpa);
    self.init.gpa.destroy(self);
}

const Ending = union(enum) { overview, conversation: Left };

/// What the core asks of the loop: to leave or present a pane under Root.
const Next = union(enum) { leave, open: view.Reference, open_settings, open_choice: view.FooterField };

/// Steps the core with one event and queues the jobs it asks for. Presenting
/// panes and leaving are the loop's to do.
fn event(self: *Self, value: view.Event) !?Next {
    return (try self.eventResult(value)).next;
}

const EventResult = struct { next: ?Next = null, archive_admission: view.ArchiveAdmission = .refused, take: view.Take = .drop };

/// Keep the core's synchronous admission with the jobs this exact step queued.
fn eventResult(self: *Self, value: view.Event) !EventResult {
    const held_host = self.state.holdsHost();
    const effects = try view.step(&self.state, value);
    if (held_host and !self.state.holdsHost()) {
        // An observation from the swap cannot authorize a start after the
        // Upgrade releases custody. Discover the new owner first.
        self.host_observation = .unavailable;
        self.queueHost();
    }
    var next: ?Next = null;
    var refused: ?keymap.Refusal = null;
    for (effects.slice()) |effect| switch (effect) {
        .open_settings => next = .open_settings,
        .open_choice => |field| next = .{ .open_choice = field },
        .list => |since| {
            self.traversal = .init(since);
            self.traversal_archive = self.state.listing_archive.?;
            self.queueHost();
            self.queue(.list);
        },
        .read_first_lines => |reads| self.queue(.{ .lines = reads }),
        .read_commands => |reads| self.queue(.{ .commands = reads }),
        .start => |request| self.queue(.{ .start = try request.own(self.init.gpa) }),
        .stop => |reference| self.queue(.{ .stop = reference }),
        .cancel_upgrade => self.upgrade_job.cancel(),
        .archive => |request| self.queue(.{ .archive = request }),
        .list_models => self.queue(.models),
        .command => |command| self.queue(.{ .command = .{ .name = command.name, .session = command.session, .line = try self.init.gpa.dupe(u8, command.text) } }),
        .open => |reference| next = .{ .open = reference },
        .clear_draft => self.composer = self.emptyComposer(self.composer.edits +% 1),
        // A refused addition says so as a refused key does.
        .replace => |change| switch (self.composer.replace(.{ .start = change.start, .end = change.end, .text = change.text })) {
            .refused => |why| refused = why,
            else => {},
        },
        .exit => return .{ .next = .leave, .archive_admission = effects.archive_admission, .take = effects.take },
    };
    if (refused) |why| if (next == null) {
        const settled = try self.eventResult(.{ .composed = .{ .input = .{ .composer = .{ .refused = why } }, .draft = self.composerDraft() } });
        return .{ .next = settled.next, .archive_admission = effects.archive_admission, .take = effects.take };
    };
    self.askSkills();
    self.sendStatuses();
    return .{ .next = next, .archive_admission = effects.archive_admission, .take = effects.take };
}

/// Brings the terminal's program status records to what the core wants:
/// a report for each Session whose record the terminal does not hold as
/// wanted, as many as a frame takes, or with notifications off one clear of
/// every record Rui may have set. The core learns what the terminal holds
/// only from a frame that wrote the reports whole, so reports a cut frame
/// may have dropped wait for the next frame.
fn sendStatuses(self: *Self) void {
    if (self.state.left) return;
    const out = self.attention;
    // Nothing to report or clear: every event ends here, so a keystroke
    // never reads the preferences file.
    if (self.state.statusesSettled() and !out.statuses_shown) return;
    if (!(preferences.load(self.options.home) catch preferences.Values{}).notifications) {
        out.clear() catch return;
        self.state.statusesCleared();
        return;
    }
    var records = self.state.unsettledStatuses();
    while (records.next()) |record| {
        if (out.report(&record.reference, record.name, record.status) catch return) self.state.statusTaken(record.taken());
    }
}

/// Queues the skills read the draft's caret word needs, if any.
fn askSkills(self: *Self) void {
    const ask = view.askSkills(&self.state, self.composerDraft()) orelse return;
    var prefix: protocol.Bounded(skill_completion.max_prefix_bytes) = .{};
    prefix.set(ask.prefix) catch unreachable; // The core asks for no longer name.
    // The core asks again only once it forgot the earlier read, as when the
    // Workspace changed: a read still queued answers nothing, so it goes. One
    // the worker runs settles on its own.
    var index: usize = 0;
    while (index < self.job_count) {
        if (self.jobs[index] == .skills) _ = self.take(index) else index += 1;
    }
    self.queue(.{ .skills = .{ .read = ask.read, .workspace = self.state.skills_workspace, .prefix = prefix } });
}

fn composerDraft(self: *const Self) view.Draft {
    return .{ .bytes = self.draft[0..self.composer.length], .cursor = self.composer.cursor, .anchor = self.draft_anchor, .edits = self.composer.edits };
}

/// Takes the queued job at `index` out of the queue.
fn take(self: *Self, index: usize) Job {
    const job = self.jobs[index];
    std.mem.copyForwards(Job, self.jobs[index .. self.job_count - 1], self.jobs[index + 1 .. self.job_count]);
    self.job_count -= 1;
    return job;
}

fn queue(self: *Self, job: Job) void {
    std.debug.assert(self.job_count < max_jobs);
    self.jobs[self.job_count] = job;
    self.job_count += 1;
}

/// Starts the next job once the worker is free. While a conversation
/// holds the terminal (`lent`) a stop goes first, and a start waits for
/// the overview.
fn dispatch(self: *Self, jobs: enum { all, lent }) !void {
    if (self.worker.thread != null) return;
    const queued = self.jobs[0..self.job_count];
    const at = switch (jobs) {
        .all => if (queued.len == 0) return else 0,
        .lent => for (queued, 0..) |job, index| {
            if (job == .stop) break index;
        } else for (queued, 0..) |job, index| {
            if (job != .start) break index;
        } else return,
    };
    const next = self.take(at);
    self.job.deinit(self.init.gpa);
    self.job = next;
    self.worker.start(self.init.io, self, work) catch |err| {
        if (next != .start_host) return err;
        self.host_launch = .{ .failed = .{ .kind = .worker, .err = err } };
    };
}

/// The worker: runs one job and writes only that job's answer. Its
/// result is the job's outcome, which `complete` settles.
fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.runJob(task.readContext());
}

/// Runs `job`, on the worker's thread or, for a save on the way out, the
/// loop's, and leaves its answer.
fn runJob(self: *Self, context: client.ReadContext) !void {
    const requests = context.requests();
    std.debug.assert(self.answer == .none);
    switch (self.job) {
        .host => self.answer = .{ .host = self.ops.host(self) },
        .start_host => {
            const launch = self.ops.start_host(self);
            // Failure is not a reachability observation. Recheck even then.
            self.answer = .{ .start_host = .{ .launch = launch, .read = self.ops.host(self) } };
        },
        .list => {
            self.answer = .{ .page = undefined };
            if (try self.ops.list(self, requests, self.traversal.cursor, &self.answer.page)) |failure| return failure.err();
        },
        .lines => |reads| {
            self.answer = .{ .lines = @splat(.{}) };
            for (reads.slice(), self.answer.lines[0..reads.len]) |read, *line| switch (try self.ops.first_line(self, requests, &read.reference, read.position, &line.bytes)) {
                .line => |text| {
                    line.result = .line;
                    line.len = text.len;
                },
                // A refusal answers the row; a canonical Store failure ends
                // the overview.
                .failure => |failure| switch (failure.err()) {
                    error.HostInvocationFailed => line.result = .refused,
                    error.CanonicalStoreFailure => |err| return err,
                },
            };
        },
        .commands => |reads| {
            self.answer = .{ .commands = @splat(.{}) };
            for (reads.slice(), self.answer.commands[0..reads.len]) |read, *command| {
                command.text = try self.ops.action_command(self, requests, &read.reference, read.action, &command.bytes);
                command.answered = true;
            }
        },
        .start => |*start| {
            // An unreadable saved effort sends nothing, as a failed capture does.
            var compaction_buffer: [20]u8 = undefined;
            const input = self.startInput(start, &compaction_buffer) catch |err| {
                self.answer = .{ .reply = .refused(@errorName(err)) };
                return;
            };
            self.answer = .{ .reply = .refused("start_request_failed") };
            try self.ops.start(self, requests, input, &self.answer.reply);
        },
        .stop => |*reference| {
            self.answer = .{ .reply = .refused("stop_request_failed") };
            try self.ops.stop(self, requests, .{ .store = self.options.store, .session = reference }, &self.answer.reply);
        },
        .archive => |*request| {
            self.answer = .{ .reply = .refused("archive_request_failed") };
            try self.ops.archive(self, requests, .{ .store = self.options.store, .session = &request.reference, .archived = request.archived }, &self.answer.reply);
        },
        .models => {
            const gpa = self.init.gpa;
            const body = try self.ops.models(self, requests, gpa);
            defer gpa.free(body);
            self.answer = .{ .menu = try model_picker.read(gpa, try protocol_reply.modelListProviders(body)) };
        },
        .skills => |*read| self.answer = .{ .skills = try self.ops.skills(self, requests, self.init.gpa, read.workspace.slice(), read.prefix.slice()) },
        .defaults => |edit| {
            // These are explicit field choices, not recommendations inferred
            // from credential readiness. Validation/publication has one owner.
            const readiness: preferences.Readinesses = .initFill(.configured);
            _ = try preferences.update(self.options.home, edit.edit, &readiness);
        },
        .command => |*command| {
            self.answer = .{ .output = .{} };
            try self.ops.command(self, context, if (command.session) |*session| session else "", command.line);
        },
    }
}

/// On the way out, runs each save the core asked for that the worker never
/// started, as the worker would, each answer stepping the core: a save is a
/// local file write that outlives the overview, and the departure says how
/// it ended. No other queued job runs.
fn flushSaves(self: *Self) !void {
    var origin: client.FailureOrigin = .local;
    const requests: client.ReadContext = .{ .io = self.init.io, .origin = &origin };
    var failure: ?anyerror = null;
    while (for (self.jobs[0..self.job_count], 0..) |job, index| {
        if (job == .defaults) break index;
    } else null) |index| {
        self.job.deinit(self.init.gpa);
        self.job = self.take(index);
        _ = self.deliver(self.runJob(requests)) catch |err| {
            // Settle every accepted save, keeping the first failure primary.
            if (failure == null) failure = err;
        };
    }
    if (failure) |err| return err;
}

/// Joins the finished job and steps the core with what it left: a failed
/// job is one without an answer. After a canonical Store failure the
/// overview then ends, as every other caller does, once the core holds any
/// request the job left unconfirmed.
fn complete(self: *Self) !?Next {
    if (self.worker.thread == null) return null;
    const outcome = self.worker.join();
    const next = try self.deliver(outcome);
    outcome catch |err| if (err == error.CanonicalStoreFailure) return err;
    return next;
}

/// Steps the core with the job's answer, read where the job wrote it, since
/// an answer may point into its own bytes, and then clears it: a job the
/// core hears of leaves nothing behind for the next.
fn deliver(self: *Self, outcome: anyerror!void) !?Next {
    const answer = &self.answer;
    defer answer.deinit(self.init.gpa);
    switch (self.job) {
        .start_host => {
            outcome catch |err| {
                self.host_launch = .{ .failed = .{ .kind = .worker, .err = err } };
                return null;
            };
            const launch = answer.start_host.launch;
            const next = try self.takeHostRead(answer.start_host.read);
            self.host_launch = switch (launch) {
                .ready => |warning| if (warning == null) null else launch,
                .failed => if (self.host_observation == .ready) null else launch,
            };
            return next;
        },
        .host => return self.takeHostRead(answer.host),
        .list => {
            outcome catch return self.event(.{ .list = .failed });
            var rows: [view.max_page_rows]view.Listed = undefined;
            const page: view.Page = .of(&self.traversal, &answer.page, &rows);
            // The next page goes before anything this page's result queues.
            if (page.answer == null) self.queue(.list);
            return self.event(.{ .list = .{ .page = page } });
        },
        .lines => |reads| for (reads.slice(), answer.lines[0..reads.len]) |read, *line| {
            const result: view.FirstLine = .{ .reference = read.reference, .admission = read.admission, .line = if (line.result == .line) line.bytes[0..line.len] else null, .unanswered = line.result == .unanswered };
            if (try self.event(.{ .first_line = result })) |next| return next;
        },
        // A batch that failed partway leaves the rest unanswered.
        .commands => |reads| for (reads.slice(), answer.commands[0..reads.len]) |read, *command| {
            if (try self.event(.{ .command = .{ .reference = read.reference, .action = read.action, .text = command.text, .unanswered = !command.answered } })) |next| return next;
        },
        .start => {
            if (answer.reply.outcome == .accepted) self.started = answer.reply.session;
            return self.event(.{ .start = answer.reply.start() });
        },
        .stop => |reference| return self.event(.{ .stop = .{ .reference = reference, .outcome = answer.reply.stop() } }),
        .archive => |request| {
            const result = answer.reply.archive(request);
            if (self.app_session) |attached| if (attached.frontend) |frontend| {
                if (std.mem.eql(u8, &result.request.reference, &attached.session)) frontend.archiveAnswered(result);
            };
            return self.event(.{ .archive = result });
        },
        .skills => |read| {
            // The core owns the page it is given.
            const page: ?skill_suggestions.Page = if (outcome) |_| answer.skills else |_| null;
            answer.* = .none;
            view.skillsRead(&self.state, read.read, page, self.composerDraft());
            self.askSkills();
            return null;
        },
        .models => {
            outcome catch |err| return self.event(.{ .models = .failed(err) });
            // The core owns the menu it is given.
            const menu = answer.menu;
            answer.* = .none;
            return self.event(.{ .models = .{ .menu = menu } });
        },
        .defaults => {
            const written = if (outcome) |_| true else |err| preferences.failure(err).saved;
            // As setup does, respect launch selectors and leave any local
            // Configure override to nextBinding's existing precedence. The
            // core decides whether a newer pick stands instead.
            const next = if (written) try self.event(.{ .defaults_saved = self.savedDefault() }) else null;
            std.debug.assert(next == null);
            if (outcome) |_| {
                self.defaults_save = .saved;
            } else |err| {
                self.defaults_save = .failed;
                // With no page left to show the answer, the departure owns it.
                if (self.state.left) return err;
            }
        },
        .command => |command| {
            const output = &answer.output;
            // As a conversation drops an inspection that could not start,
            // the overview says only that it did not run.
            var ran: view.Ran = .of(&output.bytes, output.len, if (outcome) |_| true else |_| false, output.kept);
            if (ran.readsDefault(command.name)) ran.default = self.savedDefault();
            const next = self.event(.{ .ran = ran });
            // As in a conversation, a command that failed while it ran ends
            // the overview, and its failure is the one reported, not one
            // from taking the answer; the core keeps its output for the way
            // out.
            if (ran.outcome == .failed) try outcome;
            return next;
        },
    }
    return null;
}

/// Read a confirmed saved snapshot, resolve it with the core's provider
/// authority, then let .defaults_saved apply the complete result.
fn savedDefault(self: *const Self) ?view.Default {
    if (!self.options.selectors.needsPreferences() or self.options.home.len == 0) return null;
    return resolveDefault(&self.state, .{
        .intent = self.options.selectors,
        .defaults = preferences.load(self.options.home) catch return null,
    });
}

/// Snapshot owns provider/model validation. The core supplies only the
/// missing provider authority; this local enrichment cannot pin its model.
fn resolveDefault(state: *const view.State, saved: new_session_selection.Snapshot) ?view.Default {
    if (!saved.intent.needsPreferences()) return null;
    var snapshot = saved;
    snapshot.intent.provider = state.savedProvider(snapshot.intent.provider, if (snapshot.defaults.provider.len != 0) snapshot.defaults.provider.slice() else null);
    const binding = (snapshot.resolve(&.initFill(.configured)) catch return null) orelse return null;
    var result = view.Default.of(binding.provider.slice(), binding.model.slice()) orelse return null;
    result.effort = snapshot.defaults.reasoning_effort;
    return result;
}

/// The effort the saved defaults hold, as a start reads it: none when the
/// launch named its Store, provider and model, so it reads no saved
/// defaults, or has no home.
fn savedEffort(self: *const Self) !?model_capability.ReasoningEffort {
    if (!self.options.selectors.needsPreferences() or self.options.home.len == 0) return null;
    return (try preferences.load(self.options.home)).reasoning_effort;
}

/// One captured `session start`: the composer's text and start settings
/// over the defaults a fresh Session gets.
fn startInput(self: *const Self, start: *const view.OwnedStart, compaction_buffer: *[20]u8) !client.MessageInput {
    const held = struct {
        fn at(from: *const view.OwnedStart, comptime name: []const u8) ?[]const u8 {
            inline for (view.start_options, 0..) |option, index| if (comptime std.mem.eql(u8, option, name)) return from.get(index);
            @compileError("not a start setting: " ++ name);
        }
        fn given(value: ?[]const u8) configure_input.OptionalText {
            return if (value) |present| .{ .present = true, .value = present } else .{};
        }
        fn policy(value: ?[]const u8) configure_input.OptionalPolicy {
            return configure_input.policy(value orelse return .{});
        }
    };
    const label: configure_input.OptionalPolicy = if (held.at(start, "label")) |value| .{ .present = true, .value = if (value.len == 0) null else value } else .{};
    const held_effort = held.at(start, "reasoning-effort");
    const start_effort: view.StartEffort = .{ .held = held_effort, .model = start.binding().model };
    // An unsaved pick takes precedence. Once saved, read at each start so
    // a later /effort applies, unless explicit selectors bypass preferences.
    const saved_effort = if (start_effort.readsSaved()) try self.savedEffort() else null;
    var configuration: configure_input.ConfigureInput = .{
        .store = self.options.store,
        .session = .create,
        .require_model = true,
        .workspace = .{ .present = true, .value = held.at(start, "workspace") orelse self.options.workspace },
        .provider = held.given(start.binding().provider),
        .model = held.given(start.binding().model),
        .tools = held.at(start, "tools"),
        .loaded_tools = held.at(start, "loaded-tools"),
        .permission_mode = held.given(held.at(start, "permission-mode")),
        .compaction_trigger = held.policy(held.at(start, "compaction-trigger")),
        .output_reservation = held.policy(held.at(start, "output-reservation")),
        .reasoning_effort = held.policy(held_effort),
        .label = label,
    };
    const saved_permission = if (configuration.permission_mode.present or self.options.home.len == 0) null else (try preferences.load(self.options.home)).permission_mode;
    configuration.completeCreation(std.meta.stringToEnum(protocol.Provider, start.binding().provider orelse product_defaults.provider).?, start.binding().model orelse product_defaults.recommended_model, saved_effort, saved_permission, compaction_buffer);
    return .{ .store = self.options.store, .session = "", .text_path = "", .text = start.text(), .configuration = configuration };
}

fn skillSuggestions(self: *Self, requests: client.Requests, gpa: std.mem.Allocator, workspace: []const u8, prefix: []const u8) !skill_suggestions.Page {
    return requests.skillSuggestions(gpa, self.options.store, .{ .workspace = workspace }, prefix);
}

fn listModels(self: *Self, requests: client.Requests, gpa: std.mem.Allocator) ![]u8 {
    return requests.modelList(self.options.store, gpa);
}

/// Runs a command line through the CLI's hook, as a conversation runs it,
/// and keeps what it printed.
fn runCommand(self: *Self, requests: client.ReadContext, session: []const u8, line: []u8) !void {
    const page = self.command_page orelse page: {
        const file = try self.hooks.scratch(self.init);
        self.command_page = file;
        break :page file;
    };
    const command: session_reads.CommandRun = .{ .command = self.hooks.command, .init = self.init, .requests = requests, .store = self.options.store, .session = session, .line = line };
    const ended = command.into(page);
    const output = &self.answer.output;
    output.kept = ended.rendering;
    // Failed restoration may leave fd 2 on the page, so, as a conversation
    // does, keep nothing for the way out to write there.
    if (!ended.rendering or !ended.stderr_restored) return ended.outcome;
    // What it printed shows whether it ran to the end or not.
    output.len = page.readPositionalAll(self.init.io, &output.bytes, 0) catch |err| {
        try ended.outcome;
        return err;
    };
    return ended.outcome;
}

/// The wall clock in Unix milliseconds, as the core's times are.
fn realMs(self: *const Self) u64 {
    return @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
}

/// An empty draft, whose Tab puts in the command list's highlighted word.
/// `edits` continues the count, so no two drafts share one.
fn emptyComposer(self: *Self, edits: u32) TerminalEditor {
    return .{ .buffer = &self.draft, .completion = .{ .context = self, .add = tabCompletion }, .edits = edits };
}

/// Tab: the highlighted entry of the draft's list, shown, hidden or
/// closed, in place of the caret's `/word` name or after a command's word;
/// null for a draft no list is for, which takes the tab.
fn tabCompletion(context: *const anyopaque, draft: []const u8, caret: usize) ?TerminalEditor.Replacement {
    // The editor lends back the overview `emptyComposer` registered, whose
    // skill rows this writes.
    const self: *Self = @ptrCast(@alignCast(@constCast(context)));
    const shown = view.nextCommands(&self.state, self.composerDraft()) orelse
        return if (view.commands.suggest(draft, .{}) != null) .append(draft, "") else null;
    const change = skill_completion.edit(draft, caret, &shown);
    return .{ .start = change.start, .end = change.end, .text = change.text };
}

/// An input in the opened Session's conversation, whose work shows as
/// `kind`, stepped as the overview's own: a stop it asks for is sent at
/// once.
fn conversed(raw: *anyopaque, kind: view.Kind, input: view.ConversationInput) !view.ArchiveAdmission {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const result = try self.eventResult(.{ .conversed = .{ .reference = self.opened, .work = kind, .input = input } });
    std.debug.assert(result.next == null);
    try self.dispatch(.lent);
    return result.archive_admission;
}

/// A read the opened Session's conversation applied: the outcome it opened
/// on is one the person has seen.
fn observed(raw: *anyopaque, read: session_list.Snapshot, opening: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const next = try self.event(.{ .observed = .{ .reference = self.opened, .read_version = read.read_version, .work = read.work, .last_line = read.last_line, .opening = opening } });
    std.debug.assert(next == null);
}

/// While a conversation has input focus the overview keeps its list current.
/// Its ticks refresh other Sessions, including the visible pane, and a
/// finished job is answered here, so a
/// stop never waits behind a listing. Starts wait for the overview.
fn service(raw: *anyopaque) !bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    if (self.state.upgrade.after == .blocked) return false;
    const now_ms = self.realMs();
    if (self.state.wakeAt()) |at| if (now_ms >= at) {
        _ = try self.event(.{ .tick = now_ms });
    };
    const answered = self.worker.thread != null and self.worker.completed();
    if (answered) {
        // Only a start's answer opens a Session, and none is in flight
        // while a conversation is open.
        const next = try self.complete();
        std.debug.assert(next == null);
    }
    try self.dispatch(.lent);
    return answered;
}

fn quiesceUpgrade(self: *Self) !bool {
    // The Upgrade may change the Host: the composer reads its skills again
    // after it. A read not yet started never runs, and a running one's
    // answer is dropped.
    for (self.jobs[0..self.job_count], 0..) |job, index| if (job == .skills) {
        _ = self.take(index);
        break;
    };
    if (self.state.skills.reset()) |page| {
        var held = page;
        held.deinit(self.init.gpa);
    }
    if (self.worker.thread == null) try self.dispatch(.all);
    if (self.worker.thread != null) {
        switch (self.job.quiescence()) {
            .cancel_read => self.worker.cancel(),
            .settle_effect => {},
        }
        if (self.worker.completed()) {
            if (try self.complete()) |next| switch (next) {
                .leave => return error.InteractiveInterrupted,
                .open => |reference| self.started = reference,
                // Only direct list input asks for settings, never a worker answer.
                .open_settings, .open_choice => unreachable,
            };
        }
    }
    return self.worker.thread == null and self.job_count == 0;
}

/// One borrowed source for app settings and the open conversation's choices.
fn modelsSnapshot(raw: *anyopaque) @import("model_choice.zig").Snapshot {
    const self: *Self = @ptrCast(@alignCast(raw));
    const state = &self.state;
    return .{ .menu = if (state.menu_read == .read or state.menu.entries.len > 0) &state.menu else null, .revision = state.menu_revision, .ready = state.modelsReady() };
}

/// Project the latest archive request for this exact conversation.
fn archiveState(raw: *anyopaque) @import("chat_info.zig").SaveState {
    const self: *Self = @ptrCast(@alignCast(raw));
    var at = self.state.request_count;
    while (at > 0) {
        at -= 1;
        const request = self.state.requests[at];
        if (request.kind != .archive or request.session == null or !std.mem.eql(u8, &request.session.?, &self.opened)) continue;
        return switch (request.status) {
            .pending => .pending,
            .done => .saved,
            .failed, .unknown => .failed,
        };
    }
    return .idle;
}

/// The Upgrade, as the open conversation reads it.
fn upgradeValue(raw: *anyopaque) session_upgrade.Upgrade {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.state.upgrade;
}

/// What the overview says under the opened Session's conversation.
fn conversationLine(raw: *anyopaque, kind: view.Kind) SessionFrontend.Lender.Said {
    const self: *Self = @ptrCast(@alignCast(raw));
    const said = view.conversation(&self.state, self.opened, kind, self.caps, &self.conversation_said);
    return .{ .text = said.text, .notice = said.notice, .stoppable = said.stoppable };
}

/// Render the core departure into the caller's bounded finish scratch.
fn departureText(self: *const Self, out: *std.Io.Writer) void {
    view.writeDeparture(&self.state, null, out) catch unreachable;
}

/// Lets the conversation the person left join its borrowers and write its
/// guidance, then names the Session to resume.
fn leaveFinished(self: *Self, left: Left, settled: ?SessionFrontend.Departure) !void {
    const session = &left.session;
    const store = self.options.store;
    const outcome: anyerror!void = run: {
        const frontend = left.frontend orelse {
            _ = left.ended catch |err| break :run err;
            break :run {};
        };
        const departure = settled.?;
        frontend.writeDeparture(departure);
        const end = departure.end catch |err| {
            if (departure.failure_notice) TerminalApp.detached(store, session, departure.action);
            break :run err;
        };
        switch (end) {
            .detached, .interrupted => TerminalApp.detached(store, session, departure.action),
            .returned => unreachable,
        }
    };
    return outcome catch |err| {
        if (self.lent_failed) return err;
        return self.failed(err, left.session);
    };
}

/// The same observation feeds the notice, Session service and core counts.
fn takeHostRead(self: *Self, read: HostRead) !?Next {
    const previous = self.host_observation;
    self.host_observation = read.observation;
    // A ready Host outlives what the last start said: a failure lost to a
    // competing owner, and a warning once the next read has shown it.
    if (read.observation == .ready) self.host_launch = null;
    const restart = host_restart.decide(.{
        .previous = previous.restartSeen(),
        .next = read.observation.restartSeen(),
        .allowance = self.restart_allowance,
        .upgrade_holds = self.state.holdsHost(),
        .start_available = !self.hostStarting() and self.launchNext() != null,
    });
    self.restart_allowance = restart.allowance;
    if (restart.start) self.queueHostStart();
    if (read.memory) |memory| _ = try self.event(.{ .memory = memory });
    return self.event(.{ .host = read.observation.facts() });
}

/// Starting is the effect's actual custody, including a queued job and a
/// finished worker whose result the UI has not joined. No mirrored phase.
fn hostStarting(self: *const Self) bool {
    if (self.worker.thread != null and self.job == .start_host) return true;
    for (self.jobs[0..self.job_count]) |job| if (job == .start_host) return true;
    return false;
}

/// All Host ending words and their optional key live beside their one owner.
const HostState = enum {
    ready,
    stopped,
    paused,
    incompatible,
    unreadable,
    starting,

    fn line(self: HostState) struct { mark: marks.Mark, words: []const u8 } {
        return switch (self) {
            // Shown only beside a start's warning: the Host is up.
            .ready => .{ .mark = .finished, .words = "Host ready" },
            .stopped => .{ .mark = .stopped, .words = "Host stopped" },
            .paused => .{ .mark = .stopped, .words = "Host paused" },
            .incompatible => .{ .mark = .stopped, .words = "Host is a different Rui version" },
            .unreadable => .{ .mark = .stopped, .words = "Host unreachable" },
            .starting => .{ .mark = .active, .words = "Host starting" },
        };
    }
};

fn hostState(self: *const Self) HostState {
    // The upgrade owns the swap and reobservation. A stale pre-swap read
    // cannot offer a start while that transition still owns the Host.
    if (self.state.holdsHost()) return .paused;
    if (self.hostStarting()) return .starting;
    return switch (self.host_observation) {
        .unread => .ready,
        .ready => |ready| if (ready.paused) .paused else .ready,
        .unavailable => .paused,
        .incompatible => .incompatible,
        .unreadable => .unreadable,
        .stopped => .stopped,
    };
}

fn hostHeld(raw: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return switch (self.host_observation) {
        .unread, .ready => false,
        .stopped, .unavailable, .incompatible, .unreadable => true,
    };
}

fn hostLost(raw: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!hostHeld(self)) self.host_observation = .unavailable;
    if (self.state.upgrading()) return;
    if (self.worker.thread != null and self.job == .host) return;
    self.queueHost();
}

fn queueHost(self: *Self) void {
    for (self.jobs[0..self.job_count]) |job| if (job == .host) return;
    self.queue(.host);
}

/// One rule admits the gesture and supplies the exact key tail to the line.
fn hostNext(self: *const Self) ?HostLaunch.Next {
    if (self.state.holdsHost() or self.hostStarting() or self.host_observation != .stopped) return null;
    return self.launchNext();
}

/// The key the last launch leaves for a stopped Host: a start, a retry, or
/// none when no start can mend its failure.
fn launchNext(self: *const Self) ?HostLaunch.Next {
    return if (self.host_launch) |launch| switch (launch) {
        .failed => |cause| cause.next(),
        .ready => .start,
    } else .start;
}

/// Queues the one start job, `r`'s or a restart's; the loop's dispatch runs it.
fn queueHostStart(self: *Self) void {
    self.host_launch = null;
    self.queue(.start_host);
}

fn requestHostStart(raw: *anyopaque, ctx: *vxfw.EventContext) !bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.hostNext() == null) return false;
    try self.requestedHostStart(ctx);
    return true;
}

/// Starts the stopped Host that `hostNext` says a start can mend.
fn requestedHostStart(self: *Self, ctx: *vxfw.EventContext) !void {
    self.queueHostStart();
    try self.dispatch(if (self.root.session == null) .all else .lent);
    ctx.redraw = true;
}

fn hostNotice(raw: *anyopaque) ?vxfw.Widget {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.hostState() == .ready and self.host_launch == null) {
        self.app_host_hover.targets = &.{};
        return null;
    }
    return .{ .userdata = self, .drawFn = drawHostNotice, .eventHandler = hostNoticeEvent };
}

fn hostNoticeEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.app_host_hover.handleEvent(ctx, input);
    if (input == .mouse and input.mouse.button == .left and input.mouse.type == .press) {
        for (self.app_host_hover.targets) |target| if (target.contains(input.mouse.col, input.mouse.row)) {
            _ = try requestHostStart(raw, ctx);
            break;
        };
        ctx.consumeEvent();
    }
}

fn drawHostNotice(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const state = self.hostState();
    const line = state.line();
    // These two states already say why no start can help.
    const detail = if (self.state.holdsHost() or state == .incompatible or state == .unreadable) null else self.host_launch;
    const mark = marks.marks.get(if (detail != null and detail.? == .failed) .failed else line.mark);
    const notice = if (detail) |value| value.words() else "";
    const key = if (self.hostNext()) |next| next.label() else "";
    const text = try std.fmt.allocPrint(ctx.arena, "{s} {s}{s}{s}{s}{s}", .{
        if (self.caps.unicode) mark.unicode else mark.ascii,
        line.words,
        if (notice.len == 0) "" else " · ",
        notice,
        if (key.len == 0) "" else " · ",
        key,
    });
    const label: vxfw.Text = .{ .text = text, .softwrap = false, .style = @import("widget_style.zig").of(self.caps, .{ .colour = switch (mark.tone) {
        .ink => .ink,
        .normal => .normal,
        .quiet => .quiet,
        .attention => .attention,
        .failure => .failure,
    } }) };
    var surface = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width, .height = @min(1, ctx.max.height.?) }));
    const target: Hover.Rect = .{ .row = 0, .width = surface.size.width, .height = surface.size.height };
    self.app_host_hover.targets = if (self.hostNext() != null and surface.size.width > 0 and surface.size.height > 0) try ctx.arena.dupe(Hover.Rect, &.{target}) else &.{};
    if (self.app_host_hover.targets.len != 0 and self.app_host_hover.contains(target)) {
        const hover = @import("widget_style.zig").of(self.caps, .{ .background = .hover });
        for (surface.buffer) |*cell| {
            cell.style.bg = hover.bg;
            cell.style.reverse = hover.reverse;
            cell.style.ul_style = hover.ul_style;
        }
    }
    surface.widget = hostNotice(self).?;
    return surface;
}

fn startHost(self: *Self) HostLaunch {
    return self.hooks.start_host(self.init, self.options.store);
}

fn hostFacts(self: *Self) HostRead {
    const observation: HostObservation = switch (client.hostStatus(self.init.io, self.options.store)) {
        .ready => |host| .{ .ready = .{
            .facts = .{ .instance = host.instance, .started_at = host.started_at, .slots = host.active_capacity, .slots_in_use = host.custody_occupied },
            .paused = host.paused,
        } },
        .unavailable => .{ .stopped = platform.StoreLease.lastStop(self.init.io, self.options.store) },
        .owned_unavailable => .unavailable,
        .incompatible => .incompatible,
        .access_failure => .unreadable,
    };
    // The same read samples the counts line's memory.
    return .{ .observation = observation, .memory = self.liveMemory(if (observation.facts()) |host| host.started_at else null) };
}

/// The counts line's memory: this TUI, the Host that started at
/// `host_started_at` and its tools. With no Host ready it is this TUI alone.
/// The Host's pid is read once per Host start.
fn liveMemory(self: *Self, host_started_at: ?u64) view.Memory {
    if (host_started_at) |started_at| {
        if (self.host_process == null or self.host_process.?.started_at != started_at) {
            self.host_process = if (client.observeHostProcess(self.init.io, self.options.store, null)) |process|
                .{ .started_at = started_at, .pid = process.pid }
            else |_|
                null;
        }
    } else self.host_process = null;
    var processes: host_identity.Processes = .{};
    return process_memory.read(&processes, std.c.getpid(), if (self.host_process) |host| host.pid else null);
}

fn listPage(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
    // Each page overwrites the one before from offset zero.
    const Sink = struct {
        io: std.Io,
        file: std.Io.File,
        at: u64 = 0,

        pub fn feed(sink: *@This(), bytes: []const u8) !void {
            try sink.file.writePositionalAll(sink.io, bytes, sink.at);
            sink.at += bytes.len;
        }
    };
    const file = self.scratch.?;
    var sink: Sink = .{ .io = self.init.io, .file = file };
    var buffer: client.ReplyBuffer = .{};
    const reply = try requests.listSessionsFiltered(self.options.store, null, self.traversal_archive, cursor, &sink, &buffer);
    switch (try protocol_reply.SessionListReply.decode(self.init.io, file, null, cursor, reply)) {
        .page => |value| page.* = value,
        .failure => |failure| return failure,
    }
    return null;
}

fn firstLine(self: *Self, requests: client.Requests, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    return requests.readActivityPrefix(self.options.store, session, position, buffer);
}

/// The leading bytes of a waiting Bash Action's command, read as the
/// conversation reads an Action: its tool first, then its arguments. Null
/// for any other tool, an Action resolved since the listing, or a refused
/// read.
fn actionCommand(self: *Self, requests: client.Requests, session: []const u8, action: u64, buffer: []u8) !?[]const u8 {
    const io = self.init.io;
    const file = self.scratch.?;
    const tool = try session_view.actionTool(requests, self.options.store, session, action, file) orelse return null;
    // Action reads write at the descriptor's streaming offset.
    try io.vtable.fileSeekTo(io.userdata, file, 0);
    try file.setLength(io, 0);
    var reply: client.ReplyBuffer = .{};
    const result = try requests.readActionArguments(self.options.store, session, action, file, &reply);
    if (result == .command) {
        try protocol_reply.checkCanonicalFailure(result.command);
        return null;
    }
    return session_view.bashCommand(io, file, &tool, buffer);
}

fn startSession(self: *Self, requests: client.Requests, input: client.MessageInput, reply: *Reply) !void {
    const io = self.init.io;
    // A capture that fails sends nothing, so the text can be sent again.
    var captured = client.captureMessage(io, input, .{ .generated = self.options.directory }).get() catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    self.hooks.captured(io) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    var buffer: client.ReplyBuffer = .{};
    const environment: client.Environment = .{ .map = self.init.environ_map };
    const sent = requests.sendCaptured(&captured, environment, &buffer);
    if (sent == .failed and sent.failed.err == error.EnvironmentTooLarge) {
        reply.* = .environmentTooLarge(environment);
        return;
    }
    return reply.record(sent, captured.identity().key.slice());
}

fn stopSession(self: *Self, requests: client.Requests, input: client.SessionStopInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionStop(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .{ .map = self.init.environ_map }, &buffer), captured.identity().key.slice());
}

fn archiveSession(self: *Self, requests: client.Requests, input: client.SessionArchiveInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionArchive(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .{ .map = self.init.environ_map }, &buffer), captured.identity().key.slice());
}

const test_now_s: u64 = 1_800_000_000;

/// What the fake operations were asked, for the wiring tests.
const Seen = struct {
    hosts: usize = 0,
    skill_reads: usize = 0,
    /// The Workspace the latest skills read asked in.
    skill_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    lists: usize = 0,
    since: ?protocol.SinceToken = null,
    line: struct { session: view.Reference = @splat(0), position: u64 = 0 } = .{},
    starts: usize = 0,
    start: struct {
        text: protocol.Bounded(64) = .{},
        require_model: bool = false,
        workspace: protocol.Bounded(64) = .{},
        provider: ?protocol.Bounded(64) = null,
        model: ?protocol.Bounded(64) = null,
        permission_mode: protocol.Bounded(64) = .{},
        tools: ?protocol.Bounded(64) = null,
        loaded_tools: ?protocol.Bounded(64) = null,
        label: ?protocol.Bounded(64) = null,
        reasoning_effort: ?protocol.Bounded(64) = null,
    } = .{},
    stops: usize = 0,
    archives: usize = 0,
    archive_session: view.Reference = @splat(0),
    archive_requested: bool = true,
    archive_filter: protocol.SessionArchiveFilter = .active,
    stopped: view.Reference = @splat(0),
    conversations: usize = 0,
    conversed: view.Reference = @splat(0),
    model_lists: usize = 0,
    /// How many Sessions the fake listing returns, from `listed_references`.
    listed: usize = 1,
    /// How many of them are at work; the rest are idle.
    working: usize = listed_references.len,

    var now: Seen = .{};

    fn bounded(bytes: []const u8) protocol.Bounded(64) {
        var value: protocol.Bounded(64) = .{};
        value.set(bytes) catch unreachable;
        return value;
    }
};

const listed_references = [_][]const u8{ "k7m2qx", "b4n8wd", "p3c6tz", "h5r9vy", "m2j7fs" };

/// Operations that answer from fixed facts and record what they were asked.
/// The skills the fake Host's Workspace catalog holds.
const test_skills = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "Summarise" }, .{ .name = "review", .description = "Review a change" }, .{ .name = "triage", .description = "Sort issues" } };
/// The skills another Workspace, `/other`, holds.
const other_skills = [_]skill_suggestions.Entry{.{ .name = "release", .description = "Cut a release" }};

const fake_operations: Operations = .{
    .start_host = struct {
        fn start(_: *Self) HostLaunch {
            return .{ .failed = .{ .kind = .setup, .err = error.TestUnexpectedResult } };
        }
    }.start,
    .skills = struct {
        fn skills(_: *Self, _: client.Requests, gpa: std.mem.Allocator, workspace: []const u8, prefix: []const u8) !skill_suggestions.Page {
            Seen.now.skill_reads += 1;
            Seen.now.skill_workspace.set(workspace) catch unreachable;
            var entries: std.ArrayList(skill_suggestions.Entry) = .empty;
            errdefer {
                for (entries.items) |entry| {
                    gpa.free(entry.name);
                    gpa.free(entry.description);
                }
                entries.deinit(gpa);
            }
            const catalog: []const skill_suggestions.Entry = if (std.mem.eql(u8, workspace, "/other")) &other_skills else &test_skills;
            for (catalog) |entry| if (std.mem.startsWith(u8, entry.name, prefix)) {
                const name = try gpa.dupe(u8, entry.name);
                errdefer gpa.free(name);
                const description = try gpa.dupe(u8, entry.description);
                errdefer gpa.free(description);
                try entries.append(gpa, .{ .name = name, .description = description });
            };
            const owned = try entries.toOwnedSlice(gpa);
            return .{ .entries = owned, .total = owned.len };
        }
    }.skills,
    .host = struct {
        fn host(_: *Self) HostRead {
            Seen.now.hosts += 1;
            return .{ .observation = .{ .ready = .{ .facts = .{ .instance = @splat(1), .started_at = test_now_s - 60, .slots = 4, .slots_in_use = 1 } } } };
        }
    }.host,
    .list = struct {
        fn list(self: *Self, _: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            Seen.now.lists += 1;
            Seen.now.archive_filter = self.traversal_archive;
            Seen.now.since = cursor.since;
            page.* = .{ .count = Seen.now.listed, .delta = .full, .since = .{ .instance = @splat(1), .generation = Seen.now.lists }, .next = null };
            for (page.rows[0..Seen.now.listed], listed_references[0..Seen.now.listed], 0..) |*row, reference, at| {
                const since = test_now_s - 10 - at;
                row.* = .{ .read_version = page.since, .work = .{ .state = if (at < Seen.now.working) .{ .working = .{ .since = since } } else .{ .idle = .{ .since = since } }, .turn = 1, .operation = 1 } };
                row.reference.set(reference) catch unreachable;
                row.workspace.set("/work") catch unreachable;
                row.model.set("gpt-5.5") catch unreachable;
                row.first_message = .{ .position = 1, .admission = 4, .admitted_at = since, .sender = null, .content = .{ .length = 27, .digest = @splat(0) } };
                row.peers.from_person_at = since;
            }
            return null;
        }
    }.list,
    .first_line = struct {
        fn firstLine(_: *Self, _: client.Requests, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
            Seen.now.line = .{ .session = session[0..6].*, .position = position };
            const text = "Fix the flaky test\nand more";
            @memcpy(buffer[0..text.len], text);
            return .{ .line = buffer[0..text.len] };
        }
    }.firstLine,
    .action_command = struct {
        fn actionCommand(_: *Self, _: client.Requests, _: []const u8, _: u64, buffer: []u8) !?[]const u8 {
            const text = "zig build test-store";
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        }
    }.actionCommand,
    .start = struct {
        fn start(_: *Self, _: client.Requests, input: client.MessageInput, reply: *Reply) !void {
            const settings = input.configuration.?;
            Seen.now.starts += 1;
            Seen.now.start = .{
                .text = Seen.bounded(input.text.?),
                .require_model = settings.require_model and settings.session == .create,
                .workspace = Seen.bounded(settings.workspace.value),
                .provider = if (settings.provider.present) Seen.bounded(settings.provider.value) else null,
                .model = if (settings.model.present) Seen.bounded(settings.model.value) else null,
                .permission_mode = Seen.bounded(settings.permission_mode.value),
                .tools = if (settings.tools) |tools| Seen.bounded(tools) else null,
                .loaded_tools = if (settings.loaded_tools) |loaded| Seen.bounded(loaded) else null,
                .label = if (settings.label.value) |label| Seen.bounded(label) else null,
                .reasoning_effort = if (settings.reasoning_effort.present) Seen.bounded(settings.reasoning_effort.value orelse "") else null,
            };
            reply.* = .{ .outcome = .accepted, .session = "n3w5es".* };
            reply.handle.set("start-handle") catch unreachable;
        }
    }.start,
    .stop = struct {
        fn stop(_: *Self, _: client.Requests, input: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            Seen.now.stopped = input.session[0..6].*;
            reply.* = .{ .outcome = .accepted };
        }
    }.stop,
    .archive = struct {
        fn archive(_: *Self, _: client.Requests, input: client.SessionArchiveInput, reply: *Reply) !void {
            Seen.now.archives += 1;
            Seen.now.archive_session = input.session[0..6].*;
            Seen.now.archive_requested = input.archived;
            reply.* = .{ .outcome = .accepted, .archive_pending = input.archived };
        }
    }.archive,
    .models = struct {
        fn models(_: *Self, _: client.Requests, gpa: std.mem.Allocator) ![]u8 {
            Seen.now.model_lists += 1;
            var reply: std.Io.Writer.Allocating = .init(gpa);
            errdefer reply.deinit();
            try reply.writer.writeAll(protocol.model_list_reply.head);
            // Navigation tests offer a small set, independent of catalog releases.
            try model_list.writeProviders(&reply.writer, model_catalog.shipped, &.{
                .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\n" } } },
                .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nwhisper-1\n" } } },
            });
            try reply.writer.writeAll(protocol.model_list_reply.tail);
            return reply.toOwnedSlice();
        }
    }.models,
    .command = runCommand,
    .open = struct {
        fn open(self: *Self, _: *vxfw.EventContext) !void {
            Seen.now.conversations += 1;
            Seen.now.conversed = self.opened;
        }
    }.open,
};

/// A terminal's screen after one App frame.
const Shown = struct {
    arena: std.heap.ArenaAllocator,
    screen: vaxis.Screen,

    fn deinit(self: *Shown) void {
        self.arena.deinit();
    }

    /// Row `row` as the terminal shows it, trailing blanks trimmed.
    fn line(self: *Shown, row: u16) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var col: u16 = 0;
        while (self.screen.readCell(col, row)) |cell| {
            try out.appendSlice(self.arena.allocator(), cell.char.grapheme);
            col += @max(1, cell.char.width);
        }
        return std.mem.trimEnd(u8, out.items, " ");
    }

    /// Every row, joined by newlines.
    fn text(self: *Shown) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..self.screen.height) |row| {
            if (row != 0) try out.append(self.arena.allocator(), '\n');
            try out.appendSlice(self.arena.allocator(), try self.line(@intCast(row)));
        }
        return out.items;
    }

    /// The rows from `first` on read `expected`.
    fn expectLines(self: *Shown, first: u16, expected: []const []const u8) !void {
        for (expected, first..) |want, row| try std.testing.expectEqualStrings(want, try self.line(@intCast(row)));
    }

    fn cursor(self: *const Shown) ?vaxis.Screen.Cursor {
        return if (self.screen.cursor_vis) self.screen.cursor else null;
    }
};

/// An overview over fake operations, reading keys from a pipe and drawing
/// into another.
const Rig = struct {
    environ: std.process.Environ.Map,
    init: std.process.Init = undefined,
    screen: *SessionScreen = undefined,
    overview: *Self = undefined,
    out: std.Io.Writer.Allocating = undefined,
    taken: [64 * 1024]u8 = undefined,
    attention: TerminalApp.Attention = undefined,

    fn open(options: Options, ops: Operations, interrupted: *client.Cancellation) !*Rig {
        Seen.now = .{};
        const rig = try std.testing.allocator.create(Rig);
        errdefer std.testing.allocator.destroy(rig);
        rig.* = .{ .environ = try std.testing.environ.createMap(std.testing.allocator) };
        errdefer rig.environ.deinit();
        rig.init.gpa = std.testing.allocator;
        rig.init.io = std.testing.io;
        rig.init.environ_map = &rig.environ;
        rig.screen = try std.testing.allocator.create(SessionScreen);
        errdefer std.testing.allocator.destroy(rig.screen);
        try rig.screen.init(std.testing.io, &rig.environ, true);
        errdefer rig.screen.deinit();
        rig.overview = try create(rig.init, options, undefined, ops, interrupted);
        // What a test's frames show never depends on the environment the
        // test binary runs in: `zig build` sets NO_COLOR for it and `check`
        // does not, and a coloured working row's mark turns with the clock.
        // A test of colour or locale sets its own caps.
        rig.overview.caps = .{ .depth = .none };
        rig.overview.session_screen = rig.screen;
        rig.out = .init(std.testing.allocator);
        rig.attention = .{ .vx = &rig.screen.vx, .out = &rig.out.writer };
        rig.overview.attention = &rig.attention;
        // The production run establishes its launch epoch before App starts.
        rig.overview.state.read_instance = @splat(1);
        // As App's first frame does, at the size a PTY opens with.
        _ = try view.step(&rig.overview.state, .{ .resized = .{ .width = 80, .height = 24 } });
        return rig;
    }

    fn close(rig: *Rig) void {
        rig.overview.worker.cancel();
        if (rig.overview.worker.thread != null) rig.overview.worker.join() catch {};
        rig.overview.destroy();
        rig.out.deinit();
        rig.screen.deinit();
        std.testing.allocator.destroy(rig.screen);
        rig.environ.deinit();
        std.testing.allocator.destroy(rig);
    }

    /// The bytes a terminal sends for `bytes`, delivered as App delivers
    /// them to the overview. Enter is CR, as a real terminal sends it.
    fn press(rig: *Rig, bytes: []const u8) !?Ending {
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try app_events.send(&ctx, bytes, rig.overview.root.widget(), rig.overview.widget());
        return if (ctx.quit) .overview else null;
    }

    /// A left press at `column`, `row` on the frame a terminal of `width`
    /// by `height` shows, delivered as App delivers it.
    fn click(rig: *Rig, column: u16, row: u16, width: u16, height: u16) !?Ending {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const frame = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try app_events.mouse(&ctx, frame, .{ .col = @intCast(column), .row = @intCast(row), .button = .left, .type = .press, .mods = .{} });
        return if (ctx.quit) .overview else null;
    }

    /// What the overview wrote beside App's frames since the last call:
    /// program status records.
    fn signalled(rig: *Rig) []const u8 {
        const written = rig.out.written();
        @memcpy(rig.taken[0..written.len], written);
        rig.out.clearRetainingCapacity();
        return rig.taken[0..written.len];
    }

    /// What a terminal of `width` by `height` shows: the overview drawn
    /// and composited as App's render does, with the composer focused.
    fn shown(rig: *Rig, width: u16, height: u16) !Shown {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        const surface = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        surface.render(window, rig.overview.app_input.composer.widget());
        return .{ .arena = arena, .screen = screen };
    }

    fn context(_: *Rig) vxfw.EventContext {
        return .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    }

    /// Takes the core's request as App's overview does.
    fn next(rig: *Rig, value: ?Next) !?Ending {
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try rig.overview.appNext(&ctx, value);
        return if (ctx.quit) .overview else null;
    }

    /// Runs queued jobs as the loop would, each result stepping the core.
    fn settle(rig: *Rig) !?Ending {
        const overview = rig.overview;
        while (true) {
            try overview.dispatch(.all);
            if (overview.worker.thread == null) return null;
            try rig.answered();
            if (try rig.next(try overview.complete())) |ending| return ending;
        }
    }

    /// Waits for the running job's answer.
    fn answered(rig: *Rig) !void {
        const Worker = struct {
            fn completed(overview: *Self) !bool {
                return overview.worker.completed();
            }
        };
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), rig.overview, Worker.completed);
    }

    /// Services the overview as a conversation does, until no job it may
    /// start is left.
    fn lend(rig: *Rig) !void {
        const overview = rig.overview;
        for (0..100) |_| {
            _ = try service(overview);
            const queued = for (overview.jobs[0..overview.job_count]) |job| {
                if (job != .start) break true;
            } else false;
            if (overview.worker.thread == null and !queued) return;
            if (overview.worker.thread != null) try rig.answered();
        }
        return error.TestUnexpectedResult;
    }
};

test "App overview paints its ground and both selvedge rows" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    for ([_]struct { caps: view.Caps, ground: vaxis.Color, band: vaxis.Color }{
        .{ .caps = .{}, .ground = .{ .rgb = .{ 0x12, 0x19, 0x33 } }, .band = .{ .rgb = .{ 0x1a, 0x22, 0x46 } } },
        .{ .caps = .{ .background = .{ 255, 255, 255 } }, .ground = .{ .rgb = .{ 0xf3, 0xee, 0xe2 } }, .band = .{ .rgb = .{ 0xe6, 0xdd, 0xc8 } } },
        .{ .caps = .{ .depth = .indexed }, .ground = .{ .index = 234 }, .band = .{ .index = 236 } },
        .{ .caps = .{ .depth = .none }, .ground = .default, .band = .default },
    }) |case| {
        rig.overview.caps = case.caps;
        var shown = try rig.shown(80, 24);
        defer shown.deinit();
        try std.testing.expectEqual(@import("widget_style.zig").of(case.caps, .{ .background = .selection }).bg, shown.screen.readCell(79, 0).?.style.bg);
        try std.testing.expectEqual(case.ground, shown.screen.readCell(79, 10).?.style.bg);
        try std.testing.expectEqual(case.ground, shown.screen.readCell(79, 22).?.style.bg);
        try std.testing.expectEqual(case.band, shown.screen.readCell(79, 23).?.style.bg);
    }
}

test "a blank line on the ground sits under New Session, selected or not, at narrow and wide widths" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(overview.state.order.items.len != 0);
    overview.caps = .{};
    const ground = @import("widget_style.zig").of(overview.caps, .{}).bg;
    const highlight = @import("widget_style.zig").of(overview.caps, .{ .background = .selection }).bg;
    const first: view.Selection = .{ .session = overview.state.rows.items[overview.state.order.items[0]].reference };
    for ([_]view.Selection{ .new_session, first }) |selection| for ([_]u16{ 46, 140 }) |width| {
        errdefer std.debug.print("selection={s}, width={d}\n", .{ @tagName(selection), width });
        overview.state.selected = selection;
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "  + New Session"));
        try std.testing.expectEqual(selection == .new_session, std.meta.eql(highlight, shown.screen.readCell(1, 0).?.style.bg));
        // The gap is blank ground in every column of the list, never part
        // of the New Session row's highlight.
        for (0..30) |col| {
            const cell = shown.screen.readCell(@intCast(col), 1).?;
            try std.testing.expect(std.mem.trim(u8, cell.char.grapheme, " ").len == 0);
            try std.testing.expectEqual(ground, cell.style.bg);
        }
        try std.testing.expect((try shown.line(2)).len != 0);
    };
}

test "App cursor contrasts with the painted ground after terminal theme reports" {
    const Check = struct {
        fn luminance(channels: [3]u8) f64 {
            var result: f64 = 0;
            for (channels, [_]f64{ 0.2126, 0.7152, 0.0722 }) |byte, weight| {
                const value = @as(f64, @floatFromInt(byte)) / 255;
                result += weight * (if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4));
            }
            return result;
        }
        fn rgb(colour: vaxis.Color) [3]u8 {
            return switch (colour) {
                .rgb => |value| value,
                .index => |i| if (i < 232) blk: {
                    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
                    const n: usize = i - 16;
                    break :blk .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] };
                } else @splat(@intCast(8 + 10 * (@as(u16, i) - 232))),
                else => unreachable,
            };
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
        for ([_][3]u8{ .{ 255, 255, 255 }, .{ 0, 0, 0 } }) |terminal| {
            rig.overview.caps.depth = depth;
            var ctx = rig.context();
            defer ctx.cmds.deinit(std.testing.allocator);
            try appEvent(rig.overview, &ctx, .{ .color_report = .{ .kind = .bg, .value = terminal } });
            const emitted = rig.signalled();
            const prefix = "\x1b]12;rgb:";
            const start = std.mem.indexOf(u8, emitted, prefix) orelse return error.TestUnexpectedResult;
            const colour = emitted[start + prefix.len ..];
            try std.testing.expect(colour.len >= 14);
            const cursor: [3]u8 = .{
                try std.fmt.parseInt(u8, colour[0..2], 16),
                try std.fmt.parseInt(u8, colour[5..7], 16),
                try std.fmt.parseInt(u8, colour[10..12], 16),
            };
            var shown = try rig.shown(80, 24);
            defer shown.deinit();
            const ground = Check.rgb(shown.screen.readCell(79, 10).?.style.bg);
            const background_prefix = "\x1b]11;rgb:";
            if (depth == .direct) {
                const background_start = std.mem.indexOf(u8, emitted, background_prefix);
                try std.testing.expectEqual(true, background_start != null);
                const background = emitted[background_start.? + background_prefix.len ..];
                try std.testing.expect(background.len >= 14);
                const painted: [3]u8 = .{
                    try std.fmt.parseInt(u8, background[0..2], 16),
                    try std.fmt.parseInt(u8, background[5..7], 16),
                    try std.fmt.parseInt(u8, background[10..12], 16),
                };
                try std.testing.expectEqual(ground, painted);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, emitted, "\x1b]11;") == null);
            }
            const a = Check.luminance(cursor);
            const b = Check.luminance(ground);
            const contrast = (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
            if (contrast < 4.5) std.debug.print("cursor on {s}: {d:.3}\n", .{ @tagName(depth), contrast });
            try std.testing.expect(contrast >= 4.5);
        }
    }
    try rig.screen.vx.resetState(&rig.out.writer);
    const reset = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, reset, "\x1b]112\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset, "\x1b]111\x1b\\") != null);
    rig.overview.caps.depth = .none;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appEvent(rig.overview, &ctx, .{ .color_report = .{ .kind = .bg, .value = .{ 255, 255, 255 } } });
    try std.testing.expectEqualStrings("", rig.signalled());
}

test "each effect runs its client operation and each result reaches the core" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    // A tick lists: the Host's facts, the page, then the first lines it asks for.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.lists);
    try std.testing.expect(Seen.now.since == null);
    try std.testing.expectEqual(@as(u64, 4), overview.state.host.?.slots);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.line.session);
    try std.testing.expectEqual(@as(u64, 1), Seen.now.line.position);
    const row = overview.state.find("k7m2qx".*).?;
    try std.testing.expectEqualStrings("Fix the flaky test", overview.state.lineOf(row).?);
    // The next listing asks from the token the first one answered.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(?u64, 1), if (Seen.now.since) |since| since.generation else null);

    // The composer starts a Session with /configure's settings over the
    // defaults, then opens it.
    try std.testing.expect(try rig.press("/configure --permission-mode ask --label \"lane four\"\r") == null);
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    const start = &Seen.now.start;
    try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    try std.testing.expectEqualStrings("hello", start.text.slice());
    try std.testing.expect(start.require_model);
    try std.testing.expectEqualStrings("/work", start.workspace.slice());
    try std.testing.expectEqualStrings("codex", start.provider.?.slice());
    try std.testing.expectEqualStrings("gpt-5.5", start.model.?.slice());
    try std.testing.expectEqualStrings("ask", start.permission_mode.slice());
    try std.testing.expectEqualStrings("lane four", start.label.?.slice());
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
    try std.testing.expectEqualStrings("n3w5es", &overview.started.?);

    // Ctrl-X twice stops the selected Session.
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.stopped);

    // Enter on an empty composer opens it; Ctrl-D leaves.
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    const ending = (try rig.press("\x04")).?;
    try std.testing.expect(ending == .overview);
}

test "returning from a Session refreshes saved effort in facts and app settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .low } }, &.initFill(.configured));
    var ops = fake_operations;
    ops.open = openSession;
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
    defer {
        for (rig.overview.retired.items) |retired| rig.overview.disposeSession(retired.left);
        rig.overview.retired.deinit(std.testing.allocator);
    }
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    rig.overview.app_session.?.frontend.?.leaving = .returned;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appSessionLeft(rig.overview, &ctx, .returned);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), rig.overview.state.default.?.effort);
    const values = try rig.overview.root.settings_page.backend.?.read(rig.overview);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), values.reasoning_effort);
}

test "facts omit an unsupported saved effort that the next start will not use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .max } }, &.initFill(.configured));
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    {
        var shown = try rig.shown(100, 24);
        defer shown.deinit();
        try std.testing.expectEqual(false, std.mem.indexOf(u8, try shown.text(), "· max") != null);
    }
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.start.reasoning_effort.?.slice());
}

test "a /word reads the Workspace's skills on the worker and Enter completes the caret's word" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    // The draft's first word makes it a command line, which Enter runs:
    // no skill is read or listed there.
    try std.testing.expect(try rig.press("/re") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.skill_reads);
    {
        var shown = try rig.shown(60, 24);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "/recap") == null);
    }
    // So are its arguments: Enter runs the whole line as the command.
    try std.testing.expect(try rig.press("\x15/configure --workspace /re") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.skill_reads);
    {
        var shown = try rig.shown(60, 24);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "/recap") == null);
    }
    try std.testing.expect(try rig.press("\x15") == null);
    try std.testing.expect(try rig.press("use /re") == null);
    try std.testing.expect(try rig.settle() == null);
    // The read went out at the bare `/`, for every skill.
    try std.testing.expectEqual(@as(usize, 1), Seen.now.skill_reads);
    {
        var shown = try rig.shown(60, 24);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "/recap") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Review a change") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "/triage") == null);
    }
    // That page held the whole catalog: narrowing reads nothing.
    try std.testing.expect(try rig.press("v") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.skill_reads);
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqualStrings("use /review ", overview.composerDraft().bytes);
    // Mid-draft, Enter replaces the caret's name and adds no space.
    try std.testing.expect(try rig.press("it\x1b[D\x1b[D\x1b[D\x7f\x7f\x7f") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("use /rev it", overview.composerDraft().bytes);
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqualStrings("use /review it", overview.composerDraft().bytes);
    // Enter in a drawn list of skills puts the highlighted one in and sends
    // nothing.
    try std.testing.expect(try rig.press("\x1b[F /t") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.skill_reads);
    var drawn = try rig.shown(60, 24);
    drawn.deinit();
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqualStrings("use /review it /triage ", overview.composerDraft().bytes);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
}

test "the composer's /word reads skills in the Workspace the next Session starts in" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("use /re") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("/work", Seen.now.skill_workspace.slice());
    // /configure moves the next Session to another Workspace: the held
    // page is the old one's, so it lists nothing and the read asks again.
    try std.testing.expect(try rig.press("\x15/configure --workspace /other\r") == null);
    try std.testing.expect(try rig.press("use /re") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.skill_reads);
    try std.testing.expectEqualStrings("/other", Seen.now.skill_workspace.slice());
    var shown = try rig.shown(60, 24);
    defer shown.deinit();
    const text = try shown.text();
    try std.testing.expect(std.mem.indexOf(u8, text, "/release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/recap") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/review") == null);
}

test "changing Workspace while a skills read waits keeps one skills read queued" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    // The worker runs nothing until the rig settles, so each read waits.
    for (0..2 * max_jobs) |index| {
        var line: [64]u8 = undefined;
        const configure = try std.fmt.bufPrint(&line, "\x15/configure --workspace /w{d}\r", .{index});
        try std.testing.expect(try rig.press(configure) == null);
        try std.testing.expect(try rig.press("use /re") == null);
        var skills: usize = 0;
        for (rig.overview.jobs[0..rig.overview.job_count]) |job| skills += @intFromBool(job == .skills);
        try std.testing.expectEqual(@as(usize, 1), skills);
    }
    // The one left reads the latest Workspace.
    try std.testing.expect(try rig.settle() == null);
    var last: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&last, "/w{d}", .{2 * max_jobs - 1}), Seen.now.skill_workspace.slice());
}

/// Pins `provider` and `model` in the preferences file under `home`, as
/// /setup or another terminal would.
fn pin(home: []const u8, provider: []const u8, model: []const u8) !void {
    const readiness: preferences.Readinesses = .initFill(.configured);
    _ = try preferences.update(home, .{ .provider = .{ .set = provider }, .model = .{ .set = model } }, &readiness);
}

/// Selectors a launch that named the Store, provider and model gives.
const explicit_selectors: new_session_selection.Intent = .{ .store = "/store", .provider = "codex", .model = "gpt-6-luna" };

test "an overview left without a pick writes no default, pinned or not" {
    for ([_]bool{ false, true }) |pinned| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        if (pinned) try pin(home, "openai", "gpt-6-luna");
        var cancellation: client.Cancellation = .{};
        // Without a pin, the overview opens on the built-in default.
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = if (pinned) "openai" else "codex", .model = if (pinned) "gpt-6-luna" else "gpt-5.5" }, fake_operations, &cancellation);
        defer rig.close();
        var buffer: [1024]u8 = undefined;
        const guidance = try finishedGuidance(rig, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, guidance, "New Sessions use") == null);
        const values = try preferences.load(home);
        try std.testing.expectEqualStrings(if (pinned) "openai" else "", values.provider.slice());
        try std.testing.expectEqualStrings(if (pinned) "gpt-6-luna" else "", values.model.slice());
    }
}

test "a default saved elsewhere while the overview is open outlasts its exit without a pick" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    try pin(home, "codex", "gpt-5.5");
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.settle() == null);
    try pin(home, "openai", "gpt-6-luna");
    var buffer: [1024]u8 = undefined;
    _ = try finishedGuidance(rig, &buffer);
    const values = try preferences.load(home);
    try std.testing.expectEqualStrings("openai", values.provider.slice());
    try std.testing.expectEqualStrings("gpt-6-luna", values.model.slice());
}

test "a start with no saved binding names no model, so the Host refuses it" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(Seen.now.start.require_model);
    try std.testing.expect(Seen.now.start.provider == null and Seen.now.start.model == null);
    try std.testing.expectEqualStrings(product_defaults.permission_mode, Seen.now.start.permission_mode.slice());
    try std.testing.expect(Seen.now.start.label == null);
}

test "a start sends the held tools and loaded tools" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("/configure --tools bash --loaded-tools none\rhello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("bash", Seen.now.start.tools.?.slice());
    try std.testing.expectEqualStrings("none", Seen.now.start.loaded_tools.?.slice());
}

test "overview starts read saved permissions even with explicit selectors and held flags win" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    for ([_]?protocol.PermissionMode{ null, .ask, .bypass }) |saved| {
        if (saved) |mode| _ = try preferences.update(home, .{ .permission_mode = .{ .set = mode } }, &.initFill(.configured));
        for ([_]bool{ false, true }) |explicit| {
            for ([_]?protocol.PermissionMode{ null, .ask, .bypass }) |flag| {
                var cancellation: client.Cancellation = .{};
                const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = if (explicit) explicit_selectors else .{} }, fake_operations, &cancellation);
                defer rig.close();
                if (flag) |mode| {
                    var buffer: [64]u8 = undefined;
                    const command = try std.fmt.bufPrint(&buffer, "/configure --permission-mode {s}\r", .{@tagName(mode)});
                    try std.testing.expect(try rig.press(command) == null);
                }
                try std.testing.expect(try rig.press("hello\r") == null);
                try std.testing.expect(try rig.settle() == null);
                try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
                const expected = if (flag orelse saved) |mode| @tagName(mode) else product_defaults.permission_mode;
                try std.testing.expectEqualStrings(expected, Seen.now.start.permission_mode.slice());
            }
        }
    }
}

test "a start with no held loaded tools sends none" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(Seen.now.start.loaded_tools == null);
}

test "a start takes the saved effort only when the launch read saved defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" }, .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    inline for (.{ false, true }) |explicit| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = if (explicit) explicit_selectors else .{} }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("hello\r") == null);
        try std.testing.expect(try rig.settle() == null);
        if (explicit) try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.start.reasoning_effort.?.slice()) else try std.testing.expectEqualStrings("high", Seen.now.start.reasoning_effort.?.slice());
    }
    // Naming the binding and permission mode bypasses an unreadable file.
    var config = try tmp.dir.openDir(std.testing.io, ".config/rui", .{});
    defer config.close(std.testing.io);
    const bad = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
    try bad.writeStreamingAll(std.testing.io, "version=1\n");
    bad.close(std.testing.io);
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = explicit_selectors }, fake_operations, &cancellation);
    defer rig.close();
    const starts = Seen.now.starts;
    try std.testing.expect(try rig.press("/configure --permission-mode bypass\rhello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(starts + 1, Seen.now.starts);
}

test "the overview opens the resumed Session first, lists on its tick and leaves on Ctrl-D" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .open = "k7m2qx".* }, fake_operations, &cancellation);
    defer rig.close();
    // As App's init does with the launch's Session.
    try std.testing.expect(try rig.next(try rig.overview.event(.{ .open = rig.overview.options.open.? })) == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.press("\x04"));
}

test "only your working Session's mark spins, at the frame's step, and without colour it holds still" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{};
    try std.testing.expect(try overview.event(.{ .tick = (test_now_s - 10) * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var spinning: usize = 0;
    var line: usize = 0;
    while (view.listItem(&overview.state, line)) |item| : (line += 1) {
        const at_two = try view.listSegments(arena.allocator(), &overview.state, item, 80, overview.caps, 2);
        const at_three = try view.listSegments(arena.allocator(), &overview.state, item, 80, overview.caps, 3);
        try std.testing.expectEqual(at_two.segments.len, at_three.segments.len);
        for (at_two.segments, at_three.segments) |two, three| if (!std.mem.eql(u8, two.text, three.text)) {
            // The mark turns a step; nothing else in the row moves.
            try std.testing.expectEqualStrings(view.spinner[2], two.text);
            try std.testing.expectEqualStrings(view.spinner[3], three.text);
            try std.testing.expect(view.markSpins(&overview.state, item, overview.caps));
            spinning += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), spinning);
    overview.caps = .{ .depth = .none };
    line = 0;
    while (view.listItem(&overview.state, line)) |item| : (line += 1) try std.testing.expect(!view.markSpins(&overview.state, item, overview.caps));
}

test "the overview asks for frames only while a spinning mark is on screen" {
    const rig = try openComposer();
    defer rig.close();
    rig.overview.caps = .{};
    // Your newest Session works; four more of yours are idle.
    Seen.now.listed = listed_references.len;
    Seen.now.working = 1;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const Frames = struct {
        /// Whether, a spinner step after drawing at `height` rows, the
        /// overview asks App for another frame. The next step is passed in
        /// rather than waited for, so the clock never decides the result.
        fn after(from: *Rig, height: u16) !bool {
            var shown = try from.shown(80, height);
            defer shown.deinit();
            const drawn = from.overview.app_frame;
            if (from.overview.wantsFrameAt(drawn)) return error.TestUnexpectedResult;
            return from.overview.wantsFrameAt(drawn +% 1);
        }
    };
    try std.testing.expect(try Frames.after(rig, 24));
    // With the last row selected on a short screen, the spinning row is
    // above it and needs no frames.
    _ = try rig.press("\x1b[F\x1b[A");
    try std.testing.expect(!try Frames.after(rig, 9));
    try std.testing.expect(try Frames.after(rig, 24));
    // A panel over the list shows no marks.
    try showOutputPanel(rig);
    try std.testing.expect(!try Frames.after(rig, 24));
}

/// The Reply a send leaves, whatever else it returns.
fn recorded(sent: anytype, handle: []const u8) Reply {
    var reply: Reply = .{};
    reply.record(sent, handle) catch {};
    return reply;
}

test "a captured request is unconfirmed until the Host answers it" {
    const Sent = client.Stepped(client.MutationSendError, protocol_reply.MutationReply);
    var context: protocol_reply.MutationIdentity = .{ .kind = .message };
    context.session.set("n3w5es") catch unreachable;
    const target: protocol_reply.MutationTarget = .{ .message = .{ .bytes = 5, .digest = @splat(0), .creates_session = true } };
    const accepted: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .accepted = .{ .message = .{ .admission = 1 } } }, .replayed = false } } };
    var started: Reply = .{};
    try started.record(accepted, "h1");
    try std.testing.expectEqual(.accepted, started.outcome);
    try std.testing.expectEqualStrings("n3w5es", &started.session);
    try std.testing.expectEqualStrings("h1", started.handle.slice());
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    code.set("model_unsupported") catch unreachable;
    const rejected: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .rejected = code }, .replayed = false } } };
    try std.testing.expectEqualStrings("model_unsupported", recorded(rejected, "h1").start().failed);
    const unread: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = error.InvalidResponse } };
    var lost: Reply = .{};
    try lost.record(unread, "h1");
    try std.testing.expectEqualStrings("h1", lost.start().unconfirmed);
    // Even a send that never connected leaves a saved request to recover.
    const unsent: Sent = .{ .failed = .{ .step = .connect, .err = error.FileNotFound } };
    try std.testing.expectEqualStrings("h1", recorded(unsent, "h1").start().unconfirmed);
    // A refused environment sent nothing: the start failed, and says why.
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const large = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try environ.put("LARGE_VARIABLE", large);
    const too_large = Reply.environmentTooLarge(.{ .map = &environ }).start().failed;
    try std.testing.expect(std.mem.indexOf(u8, too_large, "nothing was sent") != null);
    try std.testing.expect(std.mem.endsWith(u8, too_large, "Largest variables: LARGE_VARIABLE."));
    const uploaded: Sent = .{ .failed = .{ .step = .upload, .err = error.Cancelled } };
    try std.testing.expectEqualStrings("h1", recorded(uploaded, "h1").start().unconfirmed);
    try std.testing.expectEqualStrings("h1", recorded(uploaded, "h1").stop().unconfirmed);
    try std.testing.expect(recorded(accepted, "h1").stop() == .stopped);
    // A canonical Store failure is unconfirmed, and its error ends the overview.
    const fenced: Sent = .{ .done = .{ .status = 500, .context = context, .target = target, .answer = error.CanonicalStoreFailure } };
    var unknown: Reply = .{};
    try std.testing.expectError(error.CanonicalStoreFailure, unknown.record(fenced, "h1"));
    try std.testing.expectEqualStrings("h1", unknown.start().unconfirmed);
}

test "a canonical Store failure ends the overview, which names the start's recovery" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) !void {
            reply.* = .unconfirmed("fenced-handle");
            return error.CanonicalStoreFailure;
        }
    }.start;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, null, &departure.writer);
    try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover fenced-handle") != null);
}

/// A Host's failure reply with `code`, as the client validated it.
fn readFailure(code: []const u8) protocol_reply.ReadFailure {
    var failure: protocol_reply.ReadFailure = .{ .status = 500, .diagnostic = .{ .type = .{}, .code = .{} } };
    failure.diagnostic.type.set("invocation_error") catch unreachable;
    failure.diagnostic.code.set(code) catch unreachable;
    return failure;
}

test "a canonical Store failure in a listing ends the overview" {
    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
}

test "a refused first line answers its row, and a canonical Store failure ends the overview" {
    const Refuse = struct {
        var code: []const u8 = "";
        fn firstLine(_: *Self, _: client.Requests, _: []const u8, _: u64, _: []u8) !protocol_reply.ActivityPrefixReply {
            return .{ .failure = readFailure(code) };
        }
    };
    var ops = fake_operations;
    ops.first_line = Refuse.firstLine;
    var cancellation: client.Cancellation = .{};
    for ([_][]const u8{ "session_not_found", "canonical_store_failure" }) |code| {
        Refuse.code = code;
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
        if (std.mem.eql(u8, code, "canonical_store_failure")) {
            try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
        } else {
            try std.testing.expect(try rig.settle() == null);
            const row = rig.overview.state.find("k7m2qx".*).?;
            try std.testing.expect(rig.overview.state.lineOf(row) == null);
        }
    }
}

test "Ctrl-C ends the overview" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.press("\x03"));
}

test "a stop whose reply was lost names its request on departure" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            reply.* = .unconfirmed("stop-handle");
        }
    }.stop;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    const guidance = "rui: Not sure k7m2qx stopped. Check with: rui request recover stop-handle\n";
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, null, &departure.writer);
    try std.testing.expectEqualStrings(guidance, departure.written());
    // Its row takes no second stop: Ctrl-X names the recovery and sends nothing.
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    rig.overview.state.notice = null;
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    // A stop still running as the overview ends is named the same way.
    const running = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer running.close();
    try std.testing.expect(try running.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try running.settle() == null);
    try std.testing.expect(try running.press("\x1b[H\x1b[B\x18\x18") == null);
    try running.overview.dispatch(.all);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(running.overview.job));
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(guidance, try finishedGuidance(running, &buffer));
}

/// Runs `finish` over a terminal whose restore failed, which writes nothing
/// to stdout, and returns what it wrote to stderr.
fn finishedGuidance(rig: *Rig, buffer: []u8) ![]const u8 {
    const written = try finishedWith(rig, {}, null, buffer);
    // The overview's departure precedes the Detached notice App's exit writes.
    const at = std.mem.indexOf(u8, written, "\nDetached. Host work continues.\nOverview: rui --store ") orelse return error.TestExpectedDetached;
    return written[0..at];
}

/// Runs App's `finishApp` after App ended with `ended`, expecting
/// `failure`, and returns what it wrote to stderr.
fn finishedWith(rig: *Rig, ended: anyerror!void, failure: ?anyerror, buffer: []u8) ![]const u8 {
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.SystemResources;
    // A way out that writes nothing must read as nothing, not wait.
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (std.c.fcntl(pipe[0], std.c.F.SETFL, std.c.fcntl(pipe[0], std.c.F.GETFL) | nonblock) < 0) return error.SystemResources;
    defer for (pipe) |fd| {
        _ = std.c.close(fd);
    };
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    const finished = rig.overview.finishApp(ended);
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    if (failure) |expected| try std.testing.expectError(expected, finished) else if (try finished) |request| request.deinit(rig.overview.init.gpa);
    const count = std.c.read(pipe[0], buffer.ptr, buffer.len);
    return if (count > 0) buffer[0..@intCast(count)] else "";
}

test "while a conversation holds the terminal its stop goes first, the listing goes on, and a listing's failure stays the overview's" {
    const Lent = struct {
        fn answered(overview: *Self) !bool {
            return service(overview);
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    // A listing is due as the conversation opens.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    overview.opened = "k7m2qx".*;
    // The due Host read starts before the stop is asked for.
    try overview.dispatch(.lent);
    try std.testing.expectEqual(Job.host, std.meta.activeTag(overview.job));
    _ = try conversed(overview, .working, .stop);
    // The Host read already running answers first; the stop goes before
    // the page queued ahead of it.
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(overview.job));
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    // The listing goes on under the conversation, so records stay current; the
    // stop's answer asks for another at once.
    try rig.lend();
    try std.testing.expect(Seen.now.hosts >= 1 and Seen.now.lists >= 1);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);

    // A listing's canonical Store failure under a conversation ends the
    // overview, with no guidance to resume the Session.
    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    const failing = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer failing.close();
    try std.testing.expect(try failing.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try failing.overview.dispatch(.all);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), failing.overview, Lent.answered);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(failing.overview.job));
    failing.overview.opened = "k7m2qx".*;
    try std.testing.expectError(error.CanonicalStoreFailure, test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), failing.overview, Lent.answered));
    var buffer: [1024]u8 = undefined;
    failing.overview.app_session = .{ .session = "k7m2qx".*, .frontend = null, .files = null, .ended = .returned };
    try std.testing.expectEqualStrings("", try finishedWith(failing, error.CanonicalStoreFailure, error.CanonicalStoreFailure, &buffer));
}

test "a terminal that answers the program status probe gets each Session's record, and nothing else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished = false;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (finished) page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 };
            return null;
        }
    };
    Listing.finished = false;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    // The probe's answer and the device attributes behind it are reports:
    // the composer takes none of their bytes, nor the key after them.
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22cx\x1b[O") == null);
    try std.testing.expectEqualStrings("x", overview.composerDraft().bytes);
    try std.testing.expect(try rig.press("\x7f") == null);
    // The overview opens on k7m2qx working: its record, named by its first
    // line once read, while away.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var written = rig.signalled();
    const working = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, written, working) != null);
    // Its finish replaces the record, away as it is.
    Listing.finished = true;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    // The conversation reading it first writes nothing.
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
    // Opening the Session shows the person its outcome.
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    // Turned off, Rui clears its records; turned on, it sets them again.
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    Listing.finished = false;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=clear:id=rui\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    _ = try preferences.update(home, .{ .notifications = true }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 240_000 }) == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, working));
}

test "turning notifications off clears records already sent, with no Session changing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=clear:id=rui\x1b\\"));
}

test "a Session's record takes its new name when only its Label changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var label: ?[]const u8 = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (label) |text| {
                page.rows[0].label = .{};
                page.rows[0].label.?.set(text) catch unreachable;
            }
            return null;
        }
    };
    Listing.label = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    const by_line = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), by_line) != null);
    // Named while it still works: the record keeps its state, under the Label.
    Listing.label = "Lane four";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=TGFuZSBmb3Vy\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    // The Label cleared, its first line names it again.
    Listing.label = null;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), by_line));
}

test "each later finish, and each later wait, is a record again though no listing read the Session at work between" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var read: ?protocol.SessionWork = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (read) |listed| page.rows[0].work = listed;
            return null;
        }
    };
    Listing.read = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    const done = "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    const blocked = "\x1b]7501;state=blocked:id=rui/k7m2qx:kind=permission:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    const finished = struct {
        fn of(id: u64) protocol.SessionWork {
            return .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = id, .operation = id };
        }
    }.of;
    const waiting = struct {
        fn of(id: u64, action: u64) protocol.SessionWork {
            return .{ .state = .{ .approval = .{ .since = test_now_s } }, .turn = id, .operation = id, .first_action = action };
        }
    }.of;
    for ([_]struct { work: ?protocol.SessionWork, record: ?[]const u8 }{
        .{ .work = null, .record = "\x1b]7501;state=working:id=rui/k7m2qx:" },
        .{ .work = finished(1), .record = done },
        // Turn 2 began and finished between listings.
        .{ .work = finished(2), .record = done },
        .{ .work = finished(2), .record = null },
        .{ .work = waiting(3, 7), .record = blocked },
        // Action 7 was decided and Action 8 waits.
        .{ .work = waiting(3, 8), .record = blocked },
        .{ .work = waiting(3, 8), .record = null },
        .{ .work = waiting(4, 2), .record = blocked },
    }, 0..) |listing, at| {
        Listing.read = listing.work;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + at * 60_000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        const written = rig.signalled();
        if (listing.record) |record|
            try std.testing.expect(std.mem.startsWith(u8, written, record))
        else
            try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    }
}

test "a later Turn's finish the conversation read first is still a record when the next listing shows it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished_turn: u64 = 1;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = finished_turn, .operation = finished_turn };
            return null;
        }
    };
    Listing.finished_turn = 1;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    // Opened on Turn 1's finish, then a listing that reads it again: no record.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    // Turn 2 finishes and its conversation reads that before any listing.
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
}

test "a finish the conversation opened on is no done record when a listing reads it later, and a later Turn's is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished_turn: ?u64 = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (finished_turn) |finished| page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = finished, .operation = finished };
            return null;
        }
    };
    Listing.finished_turn = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    // Turn 1 finishes; the person opens the Session before a listing reads
    // that, and its conversation opens on the finish.
    Listing.finished_turn = 1;
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 } }, true);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    // Back on the overview, later listings of that finish leave the record.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    // Turn 2's finish, which the person has not opened, is done.
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
}

test "records go out though the terminal never answered the probe, and nothing else does, inside tmux or screen too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try rig.environ.put("TMUX", "/tmp/tmux-1000/default,1,0");
    try rig.environ.put("STY", "1.pts-0.host");
    const overview = rig.overview;
    rig.overview.options.home = home;
    // Away, with no answer to the probe.
    try std.testing.expect(try rig.press("\x1b[O") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const written = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, written, 0x07) == null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
}

test "a stop answered under a conversation says so there, and goes before a listing" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            reply.* = .unconfirmed("stop-handle");
        }
    }.stop;
    const unsure = "! k7m2qx stop unsure; details on exit";
    var cancellation: client.Cancellation = .{};
    // A stop the worker finished as the conversation opened.
    const finished = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer finished.close();
    try std.testing.expect(try finished.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try finished.settle() == null);
    try std.testing.expect(try finished.press("\x1b[H\x1b[B\x18\x18") == null);
    try finished.overview.dispatch(.all);
    try finished.answered();
    try std.testing.expect(try finished.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    finished.overview.opened = "k7m2qx".*;
    try finished.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(finished.overview, .working).notice.?);

    // A stop still queued when the conversation opened goes before the
    // listing queued ahead of it.
    const queued = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer queued.close();
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try queued.settle() == null);
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try queued.press("\x1b[H\x1b[B\x18\x18") == null);
    queued.overview.opened = "k7m2qx".*;
    _ = try service(queued.overview);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(queued.overview.job));
    try queued.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(queued.overview, .working).notice.?);
}

test "a failed terminal restore still prints the departure guidance" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) !void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.start;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: Not sure the new Session started. Check with: rui request recover lost-handle\n", try finishedGuidance(rig, &buffer));
}

/// Faults cross the same joined-worker boundary as a real lost connection.
const HostRecovery = struct {
    const Availability = enum { ready, paused, stopping, stopped, incompatible, unreadable };
    var availability: Availability = .ready;
    /// What a stopped Host's record says. Asked by default: the manual line.
    var last_stop: platform.StoreLease.LastStop = .asked;
    var starts: usize = 0;
    var fail_start: bool = false;
    var start_warning: ?HostLaunch.Warning = null;
    var forced_start: ?HostLaunch = null;
    var after_start: ?Availability = null;
    var worker_id: ?std.Thread.Id = null;
    var dir: std.Io.Dir = undefined;
    var files: u8 = 0;

    fn operations() Operations {
        availability = .ready;
        last_stop = .asked;
        starts = 0;
        fail_start = false;
        start_warning = null;
        forced_start = null;
        after_start = null;
        worker_id = null;
        files = 0;
        var ops = fake_operations;
        ops.host = host;
        ops.start_host = start;
        ops.open = openSession;
        return ops;
    }
    fn host(_: *Self) HostRead {
        return .{ .observation = switch (availability) {
            .ready, .paused => .{ .ready = .{ .facts = .{ .instance = @splat(1), .started_at = test_now_s, .slots = 4, .slots_in_use = 0 }, .paused = availability == .paused } },
            .stopped => .{ .stopped = last_stop },
            .stopping => .unavailable,
            .incompatible => .incompatible,
            .unreadable => .unreadable,
        } };
    }
    fn start(overview: *Self) HostLaunch {
        std.testing.expectEqualStrings("/store", overview.options.store) catch @panic("wrong launch Store");
        worker_id = std.Thread.getCurrentId();
        starts += 1;
        if (forced_start) |result| {
            if (after_start) |after| availability = after;
            return result;
        }
        if (fail_start) return .{ .failed = .{ .kind = .child_refused, .err = error.HostStartupFailed } };
        availability = .ready;
        return .{ .ready = start_warning };
    }
    fn scratch(init: std.process.Init) !std.Io.File {
        files += 1;
        return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
    }
    fn lost(_: *anyopaque, task: *ClientTask) !void {
        task.result.failure_origin = .host_transport;
        return error.ConnectionRefused;
    }
    fn completed(frontend: *SessionFrontend) !bool {
        return frontend.reader.completed();
    }
};

test "Host line appears once in overview and chat at wide and narrow widths, never from list failure" {
    const UnavailableList = struct {
        fn read(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return error.ConnectionRefused;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (std.enums.values(HostRecovery.Availability)) |availability| for ([_]bool{ false, true }) |open| {
        errdefer std.debug.print("availability={s}, chat={}\n", .{ @tagName(availability), open });
        const ops = HostRecovery.operations();
        HostRecovery.dir = tmp.dir;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = HostRecovery.scratch;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        defer if (overview.app_session) |left| {
            left.frontend.?.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        };
        if (open) try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
        // A failed listing fades the held rows but says nothing about the
        // Host. Discovery remains the shell Host line's sole observation.
        overview.ops.list = UnavailableList.read;
        HostRecovery.availability = availability;
        overview.state.next_list_ms = 0;
        try std.testing.expect(try overview.event(.{ .tick = (test_now_s + 1) * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(overview.state.list_stale);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 30);
            defer shown.deinit();
            const text = try shown.text();
            const expected: ?[]const u8 = switch (availability) {
                .ready => null,
                .paused, .stopping => "■ Host paused",
                .stopped => "■ Host stopped · r start",
                .incompatible => "■ Host is a different Rui version",
                .unreadable => "■ Host unreachable",
            };
            try std.testing.expectEqual(@as(usize, @intFromBool(expected != null)), std.mem.count(u8, text, "Host "));
            if (expected) |line| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, line));
            try std.testing.expectEqual(availability == .stopped, std.mem.indexOf(u8, text, "· r start") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "rui host") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, " ago. Run ") == null);
        }
    };
}

test "Host line and Settings tail show together without overlap at wide and narrow widths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = HostRecovery.operations();
    HostRecovery.dir = tmp.dir;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = HostRecovery.scratch;
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    for ([_]u16{ 46, 140 }) |width| for ([_]u16{ 9, 12, 30 }) |height| {
        errdefer std.debug.print("width={d}, height={d}\n", .{ width, height });
        var shown = try rig.shown(width, height);
        defer shown.deinit();
        const at = view.layout(&overview.state);
        const text = try shown.text();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Host stopped · r start"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "  Settings"));
        if (width >= Root.split_at) {
            // Split: the list pane ends in its Settings tail and the Host
            // line sits over the input in the compose pane, so the list
            // pane counts no Host row.
            try std.testing.expectEqual(@as(u16, 0), at.host.len());
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(height - 2), "─"));
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(height - 1), "  Settings"));
            for (0..height) |row| {
                const line = try shown.line(@intCast(row));
                if (std.mem.indexOf(u8, line, "Host stopped")) |column| try std.testing.expect(column > (std.mem.indexOf(u8, line, "│") orelse 0));
            }
            continue;
        }
        // One owner places every row: list, Settings tail, Host line, input.
        try std.testing.expectEqual(at.list.end, at.settings.start);
        try std.testing.expectEqual(@as(u16, 2), at.settings.len());
        try std.testing.expectEqual(at.settings.end, at.host.start);
        try std.testing.expectEqual(@as(u16, 1), at.host.len());
        try std.testing.expectEqual(at.host.end, at.input);
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start), "─"));
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start + 1), "  Settings"));
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.host.start), "■ Host stopped · r start"));
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.input), "─"));
        for (at.list.start..at.list.end) |row| {
            const line = try shown.line(@intCast(row));
            try std.testing.expect(std.mem.indexOf(u8, line, "Host") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "Settings") == null);
        }
    };
    // Once the Host is ready again its row returns to the list.
    HostRecovery.availability = .ready;
    overview.host_observation = .unread;
    var shown = try rig.shown(46, 12);
    defer shown.deinit();
    const at = view.layout(&overview.state);
    try std.testing.expectEqual(@as(u16, 0), at.host.len());
    try std.testing.expectEqual(at.settings.end, at.input);
}

test "Host recovery keeps the open widget drafts and scroll and starts only on an empty draft r" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = HostRecovery.operations();
    HostRecovery.dir = tmp.dir;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = HostRecovery.scratch;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("list draft") == null);
    try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
    const frontend = overview.app_session.?.frontend.?;
    defer {
        frontend.stop();
        frontend.reader.join() catch {};
        overview.disposeSession(overview.app_session.?);
        overview.app_session = null;
    }
    const child = overview.root.session.?;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    frontend.reading.opening = false;
    frontend.poll_at = std.math.maxInt(i96);
    try app_events.send(&ctx, "chat draft", overview.root.widget(), child);
    // The reader scrolled up to an earlier row: that place is theirs to keep.
    rig.screen.anchor.anchor = .{ .at = .{ .key = .{ .position = 7 }, .line = 1 } };
    const anchor = rig.screen.anchor;
    try frontend.reader.start(std.testing.io, frontend, HostRecovery.lost);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), frontend, HostRecovery.completed);
    HostRecovery.availability = .stopped;
    try child.handleEvent(&ctx, .tick);
    try rig.lend();
    try std.testing.expect(!ctx.quit);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    for ([_]u16{ 140, 46 }) |width| {
        var shown = try rig.shown(width, 26);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped · r start") != null);
    }
    try std.testing.expect(overview.root.session.?.eql(child));
    try std.testing.expectEqualStrings("list draft", overview.composerDraft().bytes);
    try std.testing.expectEqualStrings("chat draft", frontend.input.composition().bytes);
    try std.testing.expectEqualDeep(anchor, rig.screen.anchor);
    try app_events.send(&ctx, "r", overview.root.widget(), child);
    try std.testing.expectEqualStrings("chat draftr", frontend.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    _ = frontend.input.replace(.{ .start = 0, .end = frontend.input.composition().bytes.len, .text = "" });
    try app_events.send(&ctx, "r", overview.root.widget(), child);
    try std.testing.expectEqual(HostState.starting, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx)); // One attempt in flight.
    var starting = try rig.shown(46, 26);
    defer starting.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try starting.text(), "Host starting") != null);
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expect(HostRecovery.worker_id.? != std.Thread.getCurrentId());
    try std.testing.expect(hostNotice(overview) == null);
    try std.testing.expect(overview.root.session.?.eql(child));
    try std.testing.expectEqualDeep(anchor, rig.screen.anchor);
    try child.handleEvent(&ctx, .tick);
    try std.testing.expect(frontend.reader.thread != null); // Normal reads resume.
    try std.testing.expect(!ctx.quit);
}

test "Host recovery failed start waits for r retry and the line also accepts a click" {
    const ops = HostRecovery.operations();
    HostRecovery.availability = .stopped;
    HostRecovery.fail_start = true;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    _ = try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "× Host stopped · refused to start · r retry") != null);
    // r retries once, never a poll or a previous failed attempt.
    try std.testing.expect(try rig.press("r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 2), HostRecovery.starts);
    HostRecovery.fail_start = false;
    var row: u16 = 0;
    while (row < shown.screen.height) : (row += 1) {
        if (std.mem.indexOf(u8, try shown.line(row), "Host stopped") != null) break;
    }
    try std.testing.expect(row < shown.screen.height);
    try std.testing.expect(try rig.click(4, row, 46, 26) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 3), HostRecovery.starts);
    try std.testing.expect(hostNotice(overview) == null);
}

test "Host recovery paused shutting down and upgrading offer no start gesture" {
    for ([_]HostRecovery.Availability{ .paused, .stopping }) |availability| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = availability;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(HostState.paused, overview.hostState());
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try std.testing.expect(!try requestHostStart(overview, &ctx));
        try std.testing.expect(try rig.press("r") == null);
        try std.testing.expectEqualStrings("r", overview.composerDraft().bytes);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        var shown = try rig.shown(140, 26);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "■ Host paused") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "· r start") == null);
        HostRecovery.availability = .ready;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(hostNotice(overview) == null);
        overview.host_observation = .{ .stopped = .asked };
        overview.state.upgrade.after = .blocked;
        try std.testing.expectEqual(HostState.paused, overview.hostState());
        try std.testing.expect(!try requestHostStart(overview, &ctx));
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    }
}

test "Host recovery availability is independent of admission pause for the whole Session service" {
    const Inspection = struct {
        fn requests(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, out: *std.Io.Writer, saved: *session_reads.SavedRequests) !void {
            saved.* = .{};
            try out.writeAll("No requests.\n");
        }
    };
    for ([_]HostRecovery.Availability{ .ready, .paused, .stopping, .stopped }) |availability| {
        errdefer std.debug.print("availability={s}\n", .{@tagName(availability)});
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const ops = HostRecovery.operations();
        HostRecovery.dir = tmp.dir;
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_length = try tmp.dir.realPath(std.testing.io, &directory_buffer);
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = directory_buffer[0..directory_length] }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = HostRecovery.scratch;
        // The frontend freezes its callbacks when the Session opens.
        overview.hooks.requests = Inspection.requests;
        try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
        const frontend = overview.app_session.?.frontend.?;
        defer {
            frontend.stop();
            frontend.reader.join() catch {};
            _ = frontend.submission.join();
            overview.disposeSession(overview.app_session.?);
            overview.app_session = null;
        }
        frontend.reading.opening = false;
        frontend.poll_at = std.math.maxInt(i96);
        // A running Action, a sibling awaiting permission, and an already
        // queued Message are all live while admission of NEW Turns is held.
        frontend.live.work = .{ .state = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .turn = 1, .operation = 2, .first_action = 0xa };
        frontend.live.queued = .{ .count = 1, .oldest_position = 30, .newest_admission = 9, .newest_position = 30 };
        try frontend.files.action.writePositionalAll(std.testing.io, "pending permission\n", 0);
        frontend.reading.prepared_action = 0xa;
        overview.queue(.host);
        try rig.lend();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        const child = overview.root.session.?;
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?u64, 0xa), frontend.app_consent.request);
        HostRecovery.availability = availability;
        overview.queue(.host);
        try rig.lend();
        const reachable = availability == .ready or availability == .paused;
        try std.testing.expectEqual(!reachable, hostHeld(overview));
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(if (reachable) @as(?u64, 0xa) else null, frontend.app_consent.request);
        try std.testing.expectEqual(reachable, frontend.app_input.permission != null);
        try std.testing.expectEqual(@as(u64, 1), frontend.live.queued.count);
        try std.testing.expectEqual(@as(u64, 1), frontend.live.work.state.bash.running);
        // A scan still runs behind a permission card, ready and paused alike.
        frontend.poll_at = 0;
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(reachable, frontend.reader.thread != null);
        frontend.reader.cancel();
        frontend.reader.join() catch {};
        // A queued inspection has the same reachability boundary.
        frontend.input.queueCommand("/requests");
        frontend.poll_at = std.math.maxInt(i96);
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(reachable, frontend.inspection.command_running);
        try std.testing.expectEqual(!reachable, frontend.input.queuedCommand() != null);
        frontend.reader.cancel();
        frontend.reader.join() catch {};
        frontend.inspection.command_running = false;
        _ = frontend.input.takeCommand();
        // Once no permission card owns input, a new Message is admitted even
        // when new Turns are paused. A disconnected Host retains the draft.
        frontend.app_consent.withdraw();
        frontend.app_input.permission = null;
        rig.screen.withdrawAction();
        frontend.live.work.first_action = null;
        try app_events.send(&ctx, "another Message\r", overview.root.widget(), child);
        try std.testing.expectEqual(reachable, frontend.submission.intent != null);
        try std.testing.expectEqualStrings(if (reachable) "" else "another Message", frontend.input.composition().bytes);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    }
}

test "Host recovery waits across upgrade swap and reobservation before offering a start" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    // Even a free lease observed during the swap cannot offer a competing
    // start. The Upgrade owns that transition until reobservation finishes.
    try std.testing.expect(overview.state.upgrade.start());
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    overview.state.upgrade.run = null;
    overview.state.upgrade.after = .reobserving;
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    // The successful reobservation releases the Upgrade, but must not
    // expose the free-lease sample from the swap as a start gesture.
    overview.state.listing = true;
    overview.state.listing_archive = overview.state.archive;
    try std.testing.expect(try overview.event(.{ .list = .{ .page = .{ .rows = &.{}, .answer = .{ .delta = .full, .since = .{ .instance = @splat(1), .generation = 1 } } } } }) == null);
    try std.testing.expect(!overview.state.holdsHost());
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    // An owner with an unavailable listener is not an admission pause, and
    // not a stopped Host either. No start while it still owns the Store.
    HostRecovery.availability = .stopping;
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(std.meta.Tag(HostObservation).unavailable, std.meta.activeTag(overview.host_observation));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    HostRecovery.availability = .ready;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expect(!hostHeld(overview));
    try std.testing.expect(hostNotice(overview) == null);
    // Outside the swap, only confirmed absence of the owner offers start.
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
}

test "Host recovery derives launch progress from job custody without copying reachability" {
    const Busy = struct {
        fn run(_: *anyopaque, task: *ClientTask) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
    };
    const ops = HostRecovery.operations();
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    // Another job owns the sole worker. Starting is already true in the
    // queue, not just once the launch worker gets its thread.
    try overview.worker.start(std.testing.io, overview, Busy.run);
    defer {
        overview.worker.cancel();
        overview.worker.join() catch {};
    }
    try std.testing.expect(try requestHostStart(overview, &ctx));
    try std.testing.expect(overview.hostStarting());
    try std.testing.expectEqual(HostState.starting, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    // A discovery read is independently authoritative even with a launch
    // queued. One sample supplies pause, reachability and counts together.
    for ([_]HostRecovery.Availability{ .paused, .ready }) |availability| {
        HostRecovery.availability = availability;
        const read = overview.ops.host(overview);
        try std.testing.expect(try overview.takeHostRead(read) == null);
        try std.testing.expectEqual(read.observation.facts(), overview.state.host);
        try std.testing.expect(!hostHeld(overview));
        try std.testing.expect(overview.hostStarting());
        try std.testing.expectEqual(HostState.starting, overview.hostState());
        try std.testing.expect(!try requestHostStart(overview, &ctx));
    }
    overview.worker.cancel();
    overview.worker.join() catch {};
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expect(!overview.hostStarting());
    try std.testing.expectEqual(HostState.ready, overview.hostState());
    // A transport hint invalidates only discovery; it is not proof that
    // the lease is free, and cannot start anything without a fresh sample.
    hostLost(overview);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
}

test "Host recovery renders the launch result cause without confusing failure and reachability" {
    const Case = struct { launch: HostLaunch, words: []const u8, retry: bool = false };
    const cases = [_]Case{
        .{ .launch = .{ .ready = null }, .words = "" },
        .{ .launch = .{ .ready = .invalid_openai_base_url }, .words = "OpenAI URL invalid" },
        .{ .launch = .{ .failed = .{ .kind = .os_launch, .err = error.HostLaunchFailed } }, .words = "could not start", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .child_refused, .err = error.HostStartupFailed } }, .words = "refused to start", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .readiness_timeout, .err = error.HostReadinessUnconfirmed } }, .words = "start timed out", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .store_identity, .err = error.StoreIdentityMismatch } }, .words = "not the same Store" },
        .{ .launch = .{ .failed = .{ .kind = .incompatible, .err = error.IncompatibleHost } }, .words = "different Rui version" },
        .{ .launch = .{ .failed = .{ .kind = .provider_unserved, .err = error.HostModelUnavailable } }, .words = "does not serve this provider" },
        .{ .launch = .{ .failed = .{ .kind = .store_format, .err = error.HostStartupFailed } }, .words = "needs a compatible Rui" },
    };
    for (cases) |case| for ([_]HostRecovery.Availability{ .ready, .stopping, .stopped }) |after| {
        errdefer std.debug.print("after={s} words={s}\n", .{ @tagName(after), case.words });
        var cancellation: client.Cancellation = .{};
        const ops = HostRecovery.operations();
        HostRecovery.availability = .stopped;
        HostRecovery.forced_start = case.launch;
        HostRecovery.after_start = after;
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(try rig.press("r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expectEqual(after != .ready, hostHeld(overview));
        const failure = case.launch == .failed;
        if (after == .ready) {
            // A competing ready owner wins over a failure at once. A warning
            // about the Host that did start is shown with the up mark.
            var first = try rig.shown(140, 26);
            defer first.deinit();
            const text = try first.text();
            try std.testing.expectEqual(!failure and case.words.len != 0, std.mem.indexOf(u8, text, "✓ Host ready · ") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "× Host") == null);
        }
        // The next read of a ready Host retires what the start said.
        const detail = case.words.len != 0 and after != .ready;
        const next: ?HostLaunch.Next = if (after != .stopped) null else if (failure) (if (case.retry) .retry else null) else .start;
        try std.testing.expectEqual(next, overview.hostNext());
        // Another discovery read cannot erase the cause while the Host is
        // still down, or automatically retry an accepted effect.
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 26);
            defer shown.deinit();
            const text = try shown.text();
            if (case.words.len != 0) try std.testing.expectEqual(detail, std.mem.indexOf(u8, text, case.words) != null);
            try std.testing.expectEqual(next == .retry, std.mem.indexOf(u8, text, "· r retry") != null);
            try std.testing.expectEqual(next == .start, std.mem.indexOf(u8, text, "· r start") != null);
            if (after != .ready) try std.testing.expect(std.mem.indexOf(u8, text, if (after == .stopped) "Host stopped" else "Host paused") != null);
            if (failure and after != .ready) try std.testing.expect(std.mem.indexOf(u8, text, "× Host") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "rui host") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "HostStartupFailed") == null);
        }
        overview.state.upgrade.after = .blocked;
        try std.testing.expect(overview.hostNext() == null);
        var held = try rig.shown(140, 26);
        defer held.deinit();
        const text = try held.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "■ Host paused") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "· r retry") == null);
    };
}

/// Runs one Host read and steps the overview with it, leaving queued any job
/// the read asked for.
fn readHostOnce(rig: *Rig) !void {
    const overview = rig.overview;
    std.debug.assert(overview.job_count == 0 and overview.worker.thread == null);
    overview.queue(.host);
    try overview.dispatch(.all);
    try rig.answered();
    try std.testing.expect(try rig.next(try overview.complete()) == null);
}

test "a Host that stopped unasked starts again once by itself; any other stop waits for r" {
    const Case = struct { availability: HostRecovery.Availability = .stopped, last_stop: platform.StoreLease.LastStop, upgrading: bool = false, starts: usize };
    const cases = [_]Case{
        .{ .last_stop = .unasked, .starts = 1 },
        .{ .last_stop = .asked, .starts = 0 },
        .{ .last_stop = .unknown, .starts = 0 },
        .{ .last_stop = .unasked, .upgrading = true, .starts = 0 },
        .{ .last_stop = .asked, .upgrading = true, .starts = 0 },
        .{ .last_stop = .unknown, .upgrading = true, .starts = 0 },
        // A Host that holds the Store unanswered, answers in another Rui
        // version, or a Store that cannot be read is held, not crashed.
        .{ .availability = .stopping, .last_stop = .unasked, .starts = 0 },
        .{ .availability = .incompatible, .last_stop = .unasked, .starts = 0 },
        .{ .availability = .unreadable, .last_stop = .unasked, .starts = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {any}\n", .{case});
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(hostNotice(overview) == null);
        if (case.upgrading) overview.state.upgrade.after = .blocked;
        HostRecovery.availability = case.availability;
        HostRecovery.last_stop = case.last_stop;
        try readHostOnce(rig);
        if (case.starts == 1) {
            // The start is queued, not yet run: the line says so meanwhile.
            try std.testing.expectEqual(HostState.starting, overview.hostState());
            var starting = try rig.shown(46, 26);
            defer starting.deinit();
            const text = try starting.text();
            try std.testing.expect(std.mem.indexOf(u8, text, "Host starting") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "r start") == null);
        } else {
            const held: HostState = switch (case.availability) {
                .stopped => if (case.upgrading) .paused else .stopped,
                .stopping => .paused,
                .incompatible => .incompatible,
                .unreadable => .unreadable,
                .ready, .paused => unreachable,
            };
            try std.testing.expectEqual(held, overview.hostState());
        }
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(case.starts, HostRecovery.starts);
        if (case.starts == 1) {
            try std.testing.expect(HostRecovery.worker_id.? != std.Thread.getCurrentId());
            try std.testing.expect(hostNotice(overview) == null);
        } else if (!case.upgrading and case.availability == .stopped) {
            var shown = try rig.shown(46, 26);
            defer shown.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped · r start") != null);
        }
    }
}

test "the automatic start is spent once per run: a second crash and a failed start leave r" {
    // A second crash after the one automatic start succeeded.
    {
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        HostRecovery.last_stop = .unasked;
        HostRecovery.availability = .stopped;
        try readHostOnce(rig);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
        HostRecovery.availability = .stopped;
        try readHostOnce(rig);
        try std.testing.expectEqual(HostState.stopped, overview.hostState());
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        var shown = try rig.shown(46, 26);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped · r start") != null);
        // r still starts it, as before any crash.
        try std.testing.expect(try rig.press("r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 2), HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
    }
    // The one automatic start fails: the line offers a retry and later
    // reads of the same stop start nothing.
    {
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        HostRecovery.last_stop = .unasked;
        HostRecovery.availability = .stopped;
        HostRecovery.fail_start = true;
        try readHostOnce(rig);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expectEqual(HostState.stopped, overview.hostState());
        for (0..2) |_| {
            try readHostOnce(rig);
            try std.testing.expect(try rig.settle() == null);
        }
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        var shown = try rig.shown(46, 26);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expectEqual(HostLaunch.Failure.Kind.child_refused, overview.host_launch.?.failed.kind);
        try std.testing.expect(std.mem.indexOf(u8, text, "× Host stopped · ") != null and std.mem.indexOf(u8, text, " · r retry") != null);
    }
}

test "Host recovery retains a worker failure in the same typed launch result" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.host_observation = .{ .stopped = .asked };
    overview.job = .start_host;
    try std.testing.expect(try overview.deliver(error.SystemResources) == null);
    try std.testing.expectEqual(HostLaunch.Failure.Kind.worker, overview.host_launch.?.failed.kind);
    try std.testing.expectEqual(error.SystemResources, overview.host_launch.?.failed.err);
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Host stopped · could not start · r retry") != null);
}

test "before the first Host read the screen says nothing about the Host and holds no Session" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.host_observation = .unread;
    try std.testing.expectEqual(HostState.ready, overview.hostState());
    try std.testing.expect(hostNotice(overview) == null);
    try std.testing.expect(!hostHeld(overview));
    try std.testing.expect(overview.hostNext() == null);
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Host") == null);
    // A Session's lost request still holds it until the Host is read again.
    hostLost(overview);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
}

test "a conversation that fails to open still names the unconfirmed start on departure" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) !void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.start;
    ops.open = openSession;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = struct {
        fn scratch(_: std.process.Init) !std.Io.File {
            return error.AccessDenied;
        }
    }.scratch;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.press("\x1b[H\x1b[B\r"));
    try std.testing.expect(rig.overview.app_session.?.frontend == null);
    // App's exit path stops what opened; nothing did.
    rig.overview.stopApp();
    var buffer: [1024]u8 = undefined;
    const written = try finishedWith(rig, {}, error.AccessDenied, &buffer);
    try std.testing.expectEqualStrings("rui: Not sure the new Session started. Check with: rui request recover lost-handle\n" ++
        "\nResume: rui session resume --store $'/store' k7m2qx\n", written);
}

test "a listing failure under a conversation ends the overview once the terminal is restored" {
    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    ops.open = openSession;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = store, .workspace = "/work", .home = "/home", .directory = store }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = Scratch.scratch;
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try overview.dispatch(.all);
    try std.testing.expectEqual(Job.host, std.meta.activeTag(overview.job));
    try rig.answered();
    try std.testing.expect(try overview.complete() == null);
    // The listing fails on the worker, and the conversation's first step
    // under it collects the failure.
    try overview.dispatch(.all);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    try rig.answered();
    // The Session opens over the overview; the overview's next tick under
    // it collects the failure, which ends App.
    try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
    try std.testing.expect(overview.app_session.?.frontend != null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expectError(error.CanonicalStoreFailure, appEvent(overview, &ctx, .tick));
    var buffer: [4096]u8 = undefined;
    const written = try finishedWith(rig, error.CanonicalStoreFailure, error.CanonicalStoreFailure, &buffer);
    // The failure is the overview's: no guidance to resume the Session.
    try std.testing.expectEqualStrings("", written);
}

test "App sets the terminal title once per change, with how many Sessions need the person" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try appEvent(rig.overview, &ctx, .tick);
    try appEvent(rig.overview, &ctx, .tick);
    rig.overview.state.summary.counts.needs_you = 2;
    try appEvent(rig.overview, &ctx, .tick);
    var titles: std.ArrayList([]const u8) = .empty;
    for (ctx.cmds.items) |command| if (command == .set_title) try titles.append(arena.allocator(), command.set_title);
    try std.testing.expectEqual(@as(usize, 2), titles.items.len);
    try std.testing.expectEqualStrings("rui", titles.items[0]);
    try std.testing.expectEqualStrings("rui · 2 needs you", titles.items[1]);
}

test "leaving while a start is queued or running says what became of it" {
    var cancellation: client.Cancellation = .{};
    var buffer: [1024]u8 = undefined;
    // Enter and Ctrl-C in one read: the start is queued and never sent.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect((try rig.press("race start\r\x03")).? == .overview);
        try std.testing.expectEqualStrings("rui: The new Session did not start.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    }
    // The start ran as the overview ended: the Host accepted it.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("hello\r") == null);
        try rig.overview.dispatch(.all);
        try std.testing.expectEqualStrings("rui: Started n3w5es.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    }
}

test "a stop captured and then not sent keeps its handle, here and on departure" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            // The Host stopped: the saved request never connected.
            const Sent = client.Stepped(client.MutationSendError, protocol_reply.MutationReply);
            return reply.record(Sent{ .failed = .{ .step = .connect, .err = error.FileNotFound } }, "stop-handle");
        }
    }.stop;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: Not sure k7m2qx stopped. Check with: rui request recover stop-handle\n", try finishedGuidance(rig, &buffer));
}

test "leaving with a stop still queued says it was not sent" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    // Ctrl-X twice and Ctrl-C in one read: the stop is queued and never sent.
    try std.testing.expect((try rig.press("\x1b[H\x1b[B\x18\x18\x03")).? == .overview);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: k7m2qx was not stopped.\n", try finishedGuidance(rig, &buffer));
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
}

/// Types `bytes` into a fresh overview and returns the first Message of the
/// Session Enter started, or null when none started.
fn startFrom(rig: *Rig, bytes: []const u8) !?[]const u8 {
    const before = Seen.now.starts;
    var at: usize = 0;
    // Each read takes at most 4096 bytes; a pipe holds less than a draft.
    while (at < bytes.len) : (at = @min(at + 4096, bytes.len)) {
        try std.testing.expect(try rig.press(bytes[at..@min(at + 4096, bytes.len)]) == null);
    }
    try std.testing.expect(try rig.settle() == null);
    return if (Seen.now.starts == before) null else Seen.now.start.text.slice();
}

fn expectStarted(rig: *Rig, bytes: []const u8, expected: ?[]const u8) !void {
    const text = try startFrom(rig, bytes);
    if (expected) |want| try std.testing.expectEqualStrings(want, text orelse return error.TestExpectedStart) else try std.testing.expectEqual(@as(?[]const u8, null), text);
}

fn openComposer() !*Rig {
    const Shared = struct {
        var cancellation: client.Cancellation = .{};
    };
    return Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &Shared.cancellation);
}

test "bytes that are not text reject the composer's line at Enter, as in a conversation" {
    const rig = try openComposer();
    defer rig.close();
    try expectStarted(rig, "\x1b[200~first\xffsecond\x1b[201~\r", null);
    try std.testing.expectEqualStrings("! Not valid text; nothing sent.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "typed\xff\r", null);
    // The rejected line is gone; the next one starts alone.
    try expectStarted(rig, "next\r", "next");
    // A malformed key sequence (Kitty, past U+10FFFF) rejects the line the
    // same way: it stays as typed until Enter, which reports and clears it.
    try std.testing.expect(try rig.press("kept\x1b[1114112u") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("kept", rig.overview.composerDraft().bytes);
    try std.testing.expectEqual(null, rig.overview.state.notice);
    try expectStarted(rig, "\r", null);
    try std.testing.expectEqualStrings("! Not valid text; nothing sent.", rig.overview.state.notice.?.text());
    try std.testing.expectEqualStrings("", rig.overview.composerDraft().bytes);
}

test "Shift-Enter and Alt-Enter add a line in every encoding, and a paste keeps its line ends" {
    const rig = try openComposer();
    defer rig.close();
    for ([_][]const u8{ "\x1b\r", "\x1b[13;2u", "\x1b[13;2;13u", "\x1b[13:13;2u", "\x1b[27;2;13~", "\x1b[13;3u", "\x1b[13;3;13u", "\x1b[27;3;13~" }) |chord| {
        var bytes: [32]u8 = undefined;
        try expectStarted(rig, try std.fmt.bufPrint(&bytes, "one{s}two\r", .{chord}), "one\ntwo");
    }
    try expectStarted(rig, "\x1b[200~one\ntwo\n\x1b[201~\r", "one\ntwo\n");
    // Terminals send a pasted line break as CR, and a CRLF clipboard as both.
    try expectStarted(rig, "\x1b[200~one\rtwo\r\nthree\x1b[201~\r", "one\ntwo\nthree");
    try std.testing.expectEqual(@as(usize, 10), Seen.now.starts);
}

test "a paste past the editor's capacity leaves the draft unchanged" {
    const rig = try openComposer();
    defer rig.close();
    const pasted = "\x1b[200~" ++ @as([SessionInput.capacity + 1]u8, @splat('x')) ++ "\x1b[201~";
    try expectStarted(rig, "kept", null);
    try expectStarted(rig, pasted, null);
    try std.testing.expectEqualStrings("! Paste too long; draft unchanged.", rig.overview.state.notice.?.text());
    try std.testing.expectEqualStrings("kept", rig.overview.composerDraft().bytes);
    try expectStarted(rig, "\r", "kept");
}

test "a command word wrapped past the composer's rows shows no list, and Esc clears it" {
    const rig = try openListed();
    defer rig.close();
    _ = try rig.press("/configure");
    // At 8x4 the composer shows the last of the word's three rows.
    var shown = try rig.shown(8, 4);
    defer shown.deinit();
    try shown.expectLines(1, &.{"   gure"});
    for (0..4) |row| try std.testing.expect(std.mem.indexOf(u8, try shown.line(@intCast(row)), "/configu") == null);
    // With no list drawn, Esc clears the draft rather than closing one.
    _ = try rig.press("\x1b");
    try std.testing.expectEqualStrings("", rig.overview.composerDraft().bytes);
}

test "a full-capacity draft of spaces keeps the composer's caret on screen" {
    const rig = try openComposer();
    defer rig.close();
    const pasted = "\x1b[200~" ++ @as([SessionInput.capacity]u8, @splat(' ')) ++ "\x1b[201~";
    _ = try rig.press(pasted);
    try std.testing.expectEqual(@as(usize, SessionInput.capacity), rig.overview.composerDraft().bytes.len);
    var shown = try rig.shown(80, 24);
    defer shown.deinit();
    // The composer sits between the rules at rows 19 and 22; the caret
    // shows inside it.
    for ([_]u16{ 19, 22 }) |row| {
        const line = try shown.line(row);
        try std.testing.expectEqual(@as(usize, 80), std.mem.count(u8, line, "─"));
        try std.testing.expectEqual(@as(usize, 80 * "─".len), line.len);
    }
    const caret = shown.cursor() orelse return error.TestExpectedCaret;
    try std.testing.expect(caret.row > 19 and caret.row < 22 and caret.col < 80);
}

test "the composer edits at its caret, as a conversation's draft does" {
    const rig = try openComposer();
    defer rig.close();
    try expectStarted(rig, "abd\x1b[Dc\r", "abcd");
    // Home and End move the caret once there is a draft.
    try expectStarted(rig, "bc\x1b[Ha\x1b[Fd\r", "abcd");
    // Up moves to the line above; Ctrl-D deletes forward in a draft.
    try expectStarted(rig, "a\x1b\rb\x1b[AX\x1b[D\x04\r", "a\nb");
    try expectStarted(rig, "one two\x17three\r", "one three");
    // Esc clears the draft, a rejected one included.
    try expectStarted(rig, "junk\xff\x1b[27uok\r", "ok");
}

test "a start freezes the composer until its answer, and the overview's keys still act" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("hello\r") == null);
    // Typing, edits and caret keys change nothing while it waits.
    try std.testing.expect(try rig.press("\x7f\x7fXY\x1b[D\x15\r") == null);
    try std.testing.expectEqualStrings("hello", rig.overview.draft[0..rig.overview.composer.length]);
    // Up, Down, Home and End select rows, whatever the draft holds.
    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1b[H", "\x1b[F" }, [_]view.Selection{ .new_session, .{ .session = "k7m2qx".* }, .new_session, .settings }) |key, expected| {
        rig.overview.state.selected = .new_session;
        try std.testing.expect(try rig.press(key) == null);
        try std.testing.expectEqual(expected, rig.overview.state.selected);
    }
    // Esc clears the draft; the start still sends what Enter captured.
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.composer.length);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    try std.testing.expectEqualStrings("hello", Seen.now.start.text.slice());
    try expectStarted(rig, "next\r", "next");
}

/// A composer over five listed Sessions, the middle one selected, so the
/// row above, below, first and last are four different rows.
fn openListed() !*Rig {
    const rig = try openComposer();
    errdefer rig.close();
    Seen.now.listed = listed_references.len;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(listed_references.len, rig.overview.state.order.items.len);
    rig.overview.state.selected = .{ .session = shownRow(rig, 2) };
    return rig;
}

/// The Session shown at `at` in screen order.
fn shownRow(rig: *const Rig, at: usize) view.Reference {
    const state = &rig.overview.state;
    return state.rows.items[state.order.items[at]].reference;
}

test "Overview footer Tab navigates instead of completing a command before a frame" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("/set\t") == null);
    try std.testing.expectEqualStrings("/set", rig.overview.composerDraft().bytes);
    try std.testing.expectEqual(view.FooterFocus.model, rig.overview.state.footer.focus);
    // A fresh batch still navigates the facts; it never completes either
    // a command word or its next argument behind the focused buttons.
    rig.overview.composer = rig.overview.emptyComposer(rig.overview.composer.edits +% 1);
    rig.overview.state.footer.focus = .input;
    try std.testing.expect(try rig.press("/conf\t\t") == null);
    try std.testing.expectEqualStrings("/conf", rig.overview.composerDraft().bytes);
    try std.testing.expectEqual(view.FooterFocus.input, rig.overview.state.footer.focus);
}

test "Shift-Up and Shift-Down select the row above and below, whatever the draft holds" {
    const rig = try openListed();
    defer rig.close();
    for ([_][]const u8{ "", "two\x1b\rlines", "junk\xff" }) |draft| {
        for ([_]struct { bytes: []const u8, row: usize }{
            .{ .bytes = "\x1b[1;2A", .row = 1 },
            .{ .bytes = "\x1b[1;2:1A", .row = 1 },
            .{ .bytes = "\x1b[1;2B", .row = 3 },
            .{ .bytes = "\x1b[1;2:1B", .row = 3 },
        }) |case| {
            errdefer std.debug.print("draft={s} key={s}\n", .{ draft, case.bytes[1..] });
            rig.overview.composer = rig.overview.emptyComposer(rig.overview.composer.edits +% 1);
            try std.testing.expect(try rig.press(draft) == null);
            rig.overview.state.selected = .{ .session = shownRow(rig, 2) };
            try std.testing.expect(try rig.press(case.bytes) == null);
            try std.testing.expectEqualStrings(&shownRow(rig, case.row), &(if (rig.overview.state.selected == .session) rig.overview.state.selected.session else return error.TestExpectedSelection));
        }
    }
}

/// Every encoding of every key a screen may bind: raw or legacy, Kitty's
/// CSI-u, and xterm's modifyOtherKeys where the key has them.
const key_encodings = std.enums.EnumArray(keymap.Key, []const []const u8).init(.{
    .escape = &.{ "\x1b", "\x1b[27u", "\x1b[27;3u", "\x1b[27;1;27~" },
    .ctrl_c = &.{ "\x03", "\x1b[99;5u", "\x1b[27;5;99~" },
    .ctrl_d = &.{ "\x04", "\x1b[100;5u", "\x1b[27;5;100~" },
    .ctrl_g = &.{ "\x07", "\x1b[103;5u", "\x1b[27;5;103~" },
    .ctrl_n = &.{ "\x0e", "\x1b[110;5u", "\x1b[27;5;110~" },
    .ctrl_o = &.{ "\x0f", "\x1b[111;5u", "\x1b[27;5;111~" },
    .ctrl_p = &.{ "\x10", "\x1b[112;5u", "\x1b[27;5;112~" },
    .ctrl_r = &.{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" },
    .ctrl_x = &.{ "\x18", "\x1b[120;5u", "\x1b[27;5;120~" },
    .alt_a = &.{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" },
    .up = &.{ "\x1b[A", "\x1bOA", "\x1b[1;1A" },
    .down = &.{ "\x1b[B", "\x1bOB", "\x1b[1;1B" },
    .shift_up = &.{ "\x1b[1;2A", "\x1b[1;2:1A" },
    .shift_down = &.{ "\x1b[1;2B", "\x1b[1;2:1B" },
    .page_up = &.{ "\x1b[5~", "\x1b[5;1~", "\x1b[5;2~" },
    .page_down = &.{ "\x1b[6~", "\x1b[6;1~", "\x1b[6;2~" },
    .home = &.{ "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~", "\x1b[1;1H" },
    .end = &.{ "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~", "\x1b[1;1F" },
    .ctrl_end = &.{ "\x1b[1;5F", "\x1b[4;5~" },
});

/// The key a lone editor reads `bytes` as, decoded as App decodes them.
fn keyOf(bytes: []const u8) !?keymap.Key {
    var storage: [8]u8 = undefined;
    var editor: TerminalEditor = .{ .buffer = &storage };
    var parser: vaxis.Parser = .{};
    var found: ?keymap.Key = null;
    var at: usize = 0;
    while (at < bytes.len) {
        const result = try parser.parse(bytes[at..], null);
        if (result.n == 0) return error.TestIncompleteKey;
        at += result.n;
        const pressed = switch (result.event orelse continue) {
            .key_press => |key| key,
            else => continue,
        };
        switch (editor.appEvent(keymap.every, .{ .key_press = pressed }, false)) {
            .action => |key| found = key,
            else => {},
        }
    }
    return found;
}

test "every key does what the overview's table says, through the editor, in every encoding, on an empty and on a rejected draft" {
    for (std.enums.values(keymap.Key)) |key| for (key_encodings.get(key)) |bytes| for ([_][]const u8{ "", "\xff" }) |draft| {
        errdefer std.debug.print("key={s} bytes={s} draft={s}\n", .{ @tagName(key), bytes[1..], draft });
        try std.testing.expectEqual(@as(?keymap.Key, key), try keyOf(bytes));
        const rig = try openListed();
        defer rig.close();
        try std.testing.expect(try rig.press("/configure --permission-mode ask\r") == null);
        try std.testing.expect(try rig.press(draft) == null);
        const ending = try rig.press(bytes);
        const state = &rig.overview.state;
        const selected = state.selected;
        const action = view.keys.get(key) orelse {
            // Nothing happens, and the line is not rejected by it.
            try std.testing.expect(ending == null);
            try std.testing.expectEqualStrings(&shownRow(rig, 2), &selected.session);
            try std.testing.expect(state.request_count == 0 and !state.settings.empty());
            if (draft.len == 0) try expectStarted(rig, "ok\r", "ok");
            continue;
        };
        if (action == .exit) {
            try std.testing.expectEqual(@as(?Ending, .overview), ending);
            continue;
        }
        try std.testing.expect(ending == null);
        switch (action) {
            .first => try std.testing.expectEqual(view.Selection.new_session, selected),
            .last => try std.testing.expectEqual(view.Selection.settings, selected),
            .previous, .next, .select_previous, .select_next => {
                const row: usize = switch (action) {
                    .previous, .select_previous => 1,
                    .next, .select_next => 3,
                    else => unreachable,
                };
                try std.testing.expectEqualStrings(&shownRow(rig, row), &selected.session);
            },
            .clear => try std.testing.expect(state.settings.empty()),
            // Both act at once on the selected row, asking nothing.
            .archive, .stop => {
                try std.testing.expectEqual(@as(usize, 1), state.request_count);
                try std.testing.expectEqualStrings(&shownRow(rig, 2), &state.requests[0].session.?);
            },
            .exit => unreachable,
        }
    };
}

test "a start sends what its Enter captured, whatever Esc clears before it runs" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("/configure --permission-mode ask\rhello\r") == null);
    try std.testing.expect(rig.overview.state.starting());
    // Esc clears the draft, then the held settings, while the start waits.
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.composer.length);
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    try std.testing.expect(rig.overview.state.settings.empty());
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("hello", Seen.now.start.text.slice());
    try std.testing.expectEqualStrings("ask", Seen.now.start.permission_mode.slice());
}

test "keys the editor declines say so and leave the draft" {
    const rig = try openComposer();
    defer rig.close();
    try expectStarted(rig, "\u{200d}", null);
    try std.testing.expectEqualStrings("! Can't add that character alone.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "ab\x1bx", null);
    try std.testing.expect(rig.overview.state.notice == null);
    try expectStarted(rig, "c\r", "abc");
}

/// The CLI's command hook as a test gives it: it records what it ran and
/// prints what the test says to stdout and stderr, as `sessionCommand` does.
const Printing = struct {
    var stdout: []const u8 = "";
    var stderr_text: []const u8 = "";
    var failure: ?anyerror = null;
    var line: protocol.Bounded(64) = .{};
    var session: protocol.Bounded(64) = .{};
    var store: protocol.Bounded(64) = .{};
    var runs: usize = 0;
    var dir: std.Io.Dir = undefined;

    /// Lends `rig` these hooks, with pages in `pages`.
    fn use(rig: *Rig, pages: std.Io.Dir) void {
        stdout = "";
        stderr_text = "";
        failure = null;
        runs = 0;
        dir = pages;
        rig.overview.hooks.command = command;
        rig.overview.hooks.scratch = scratch;
    }

    fn command(_: std.process.Init, _: client.ReadContext, to: []const u8, reference: []const u8, text: []u8) anyerror!void {
        runs += 1;
        line = Seen.bounded(text);
        session = Seen.bounded(reference);
        store = Seen.bounded(to);
        for ([_]c_int{ 1, 2 }, [_][]const u8{ stdout, stderr_text }) |fd, bytes| {
            if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.TestUnexpectedResult;
        }
        if (failure) |err| return err;
    }

    fn scratch(_: std.process.Init) !std.Io.File {
        return dir.createFile(std.testing.io, "page", .{ .read = true });
    }
};

/// An overview whose first listing selected k7m2qx, running commands
/// through `Printing`.
fn commandRig(pages: std.Io.Dir, cancellation: *client.Cancellation) !*Rig {
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, cancellation);
    errdefer rig.close();
    Printing.use(rig, pages);
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    return rig;
}

test "a two-line command result uses the Footer right side without an extra row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const rig = try commandRig(tmp.dir, &cancellation);
    defer rig.close();
    Printing.stdout = "Rui: Configured.\nrui: label saved locally only\n";
    try std.testing.expect(try rig.press("/rename lane four\r") == null);
    try std.testing.expect(try rig.settle() == null);
    var shown = try rig.shown(80, 24);
    defer shown.deinit();
    const footer = try shown.line(23);
    try std.testing.expect(std.mem.startsWith(u8, footer, " no model"));
    try std.testing.expect(std.mem.endsWith(u8, footer, "Configured. ! label saved locally only"));
    try std.testing.expectEqual(@as(usize, 0), (try statusRowsShown(&shown, 24)).len);
}

/// The rows between the composer's bottom rule and the Footer, which ends
/// a screen `height` rows tall, in the composer's pane: right of the list
/// pane's divider on a wide screen.
fn statusRowsShown(shown: *Shown, height: u16) ![]const []const u8 {
    var draft: u16 = 0;
    while (std.mem.indexOf(u8, try shown.line(draft), "› Type a task") == null) draft += 1;
    const rows = try shown.arena.allocator().alloc([]const u8, height - 3 - draft);
    for (rows, draft + 2..) |*row, at| {
        const line = try shown.line(@intCast(at));
        const pane = if (std.mem.lastIndexOf(u8, line, "│")) |divider| line[divider + "│".len ..] else line;
        row.* = std.mem.trim(u8, pane, " ");
    }
    return rows;
}

test "Footer notice domain uses production clipping sanitization and colour" {
    const overflowing = "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789";
    const cases = [_]struct { raw: []const u8, displayed: []const u8 }{
        .{ .raw = "Configured.", .displayed = "Configured." },
        .{ .raw = overflowing, .displayed = overflowing },
        .{ .raw = "Saved.\nNext", .displayed = "Saved. Next" },
        .{ .raw = "Saved.\rNext", .displayed = "Saved. Next" },
        .{ .raw = "First\nSecond\rThird\x1b", .displayed = "First Second Third\\x1b" },
        .{ .raw = "! Unknown command /status", .displayed = "! Unknown command /status" },
        .{ .raw = "Configured.\n! label saved locally only", .displayed = "Configured. ! label saved locally only" },
    };
    const rig = try openComposer();
    defer rig.close();
    for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]view.Colour{ .quiet, .attention }) |colour| for (cases) |case| for ([_]u16{ 40, 46, 99, 140 }) |width| {
        errdefer std.debug.print("depth={s}, colour={s}, width={d}, notice={s}\n", .{ @tagName(depth), @tagName(colour), width, case.raw });
        rig.overview.caps.depth = depth;
        var notice: view.Notice = .{ .colour = colour, .len = case.raw.len };
        @memcpy(notice.bytes[0..notice.len], case.raw);
        rig.overview.state.notice = notice;
        // Draw the real Overview, including noticeLine and Footer. Expected
        // single-line text above is independent of either implementation.
        var shown = try rig.shown(width, 24);
        defer shown.deinit();
        const pane_start: u16 = if (width >= Root.split_at) Root.list_width + 1 else 0;
        const pane_width = width - pane_start;
        const visible = case.displayed[0..@min(case.displayed.len, pane_width)];
        const footer = try shown.line(23);
        try std.testing.expectEqualStrings(visible, footer[footer.len - @min(footer.len, visible.len) ..]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, try shown.text(), visible));
        try std.testing.expectEqual(@as(usize, 0), (try statusRowsShown(&shown, 24)).len);
        try std.testing.expect(std.mem.indexOf(u8, footer, "enter start") == null);
        const style = @import("widget_style.zig").of(rig.overview.caps, .{ .colour = colour, .background = .bar });
        // Compare actual cells: Footer keeps a prefix, not an ellipsis, and
        // notice colour survives sanitizing, clipping and terminal mapping.
        for (visible, width - visible.len..width) |byte, col| {
            const cell = shown.screen.readCell(@intCast(col), 23).?;
            try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
            try std.testing.expectEqual(style, cell.style);
        }
    };
}

test "Footer notices fit or truncate on the right without adding rows; persistent recovery keeps its rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const cases = [_]struct { printed: ?[]const u8, notice: []const u8 }{
        .{ .printed = "Rui: Configured.\n", .notice = "Configured." },
        .{ .printed = "Rui: Configured.\nrui: label saved locally only\n", .notice = "Configured.\n! label saved locally only" },
        .{ .printed = null, .notice = "! Not confirmed · rui request recover " ++ key },
    };
    for (cases) |case| {
        const rig = try commandRig(tmp.dir, &cancellation);
        defer rig.close();
        if (case.printed) |printed| {
            Printing.stdout = printed;
            try std.testing.expect(try rig.press("/rename lane four\r") == null);
            try std.testing.expect(try rig.settle() == null);
        } else {
            const reference = rig.overview.state.selected.session;
            _ = try view.step(&rig.overview.state, .{ .unconfirmed = .{ .reference = reference, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
        }
        for ([_]u16{ 46, 80, 140 }) |width| {
            var shown = try rig.shown(width, 24);
            defer shown.deinit();
            const rows = try statusRowsShown(&shown, 24);
            const footer = try shown.line(23);
            if (case.printed != null) {
                try std.testing.expectEqual(@as(usize, 0), rows.len);
                const expected = try std.mem.replaceOwned(u8, shown.arena.allocator(), case.notice, "\n", " ");
                try std.testing.expect(std.mem.endsWith(u8, footer, expected));
                try std.testing.expect(std.mem.indexOf(u8, footer, "enter open") == null);
            } else {
                const joined = try std.mem.join(shown.arena.allocator(), " ", rows);
                try std.testing.expectEqualStrings(case.notice, joined);
                try std.testing.expect(std.mem.endsWith(u8, footer, "enter open"));
            }
        }
    }
}

test "Settings Keys opens from the overview and Esc returns to settings" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        const selected = overview.state.selected;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        overview.root.settings_page.select(.keys);
        try overview.root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(overview.root.settings_page.keys_open);
        var shown = try rig.shown(width, 24);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "ctrl+x") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "stop") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "/help") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Ctrl-X twice") == null);
        try std.testing.expect(try rig.press("\x1b") == null);
        try std.testing.expect(!overview.root.settings_page.keys_open);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expect(overview.root.session == null);
        try std.testing.expect(try rig.press("\x1b") == null);
        try std.testing.expect(!overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(selected, overview.state.selected);
    }
}

/// Owned command output for tests of the surrounding overview surface.
fn showOutputPanel(rig: *Rig) !void {
    const state = &rig.overview.state;
    try std.testing.expect(state.panel == null);
    state.panel = .{ .output = .{ .name = .setup, .text = try state.gpa.dupe(u8, "Defaults\nStore: /s\nNotifications: off\nModel: test") } };
}

test "a command output panel stays above the pinned Settings row, with or without a provider band" {
    for ([_]bool{ false, true }) |banded| {
        const rig = try openListed();
        defer rig.close();
        const state = &rig.overview.state;
        if (banded) {
            const row = &state.rows.items[state.order.items[0]];
            row.state = .{ .failed = .{ .since = test_now_s, .code = .{}, .resets_at = null } };
            try row.state.failed.code.set("provider_http_401");
            try std.testing.expect(view.band(state) != null);
        }
        var clipped = false;
        var whole = false;
        var height: u16 = 8;
        while (height <= 40) : (height += 1) {
            // Esc closes a panel or a notice the last height left.
            _ = try rig.press("\x1b");
            _ = try rig.press("\x1b");
            var sized = try rig.shown(80, height);
            sized.deinit();
            try showOutputPanel(rig);
            var shown = try rig.shown(80, height);
            defer shown.deinit();
            const at = view.layout(state);
            try std.testing.expectEqual(@as(u16, @intFromBool(banded)), at.top);
            try std.testing.expectEqual(@as(u16, 2), at.settings.len());
            const items = (try view.panelItems(shown.arena.allocator(), state, 80, rig.overview.caps)).?;
            try std.testing.expect(items.len <= at.list.len());
            whole = whole or items.len == 5;
            // Each line the panel built shows in its row, none under the
            // Settings tail. A short panel counts the lines it hides.
            for (items, at.top..) |item, row| {
                var text: std.ArrayList(u8) = .empty;
                for (item.segments) |segment| try text.appendSlice(shown.arena.allocator(), segment.text);
                try std.testing.expectEqualStrings(std.mem.trimEnd(u8, text.items, " "), try shown.line(@intCast(row)));
                clipped = clipped or std.mem.indexOf(u8, text.items, "more lines") != null;
            }
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start), "─"));
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start + 1), "  Settings"));
        }
        try std.testing.expect(clipped and whole);
    }
}

test "/rename and /setup run through the conversation's command hook on the worker, and what they print reaches the overview" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const rig = try commandRig(tmp.dir, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const lists = Seen.now.lists;
    Printing.stdout = "Rui: Configured.\n";
    try std.testing.expect(try rig.press("/rename lane four\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("/rename lane four", Printing.line.slice());
    try std.testing.expectEqualStrings("k7m2qx", Printing.session.slice());
    try std.testing.expectEqualStrings("/store", Printing.store.slice());
    try std.testing.expectEqualStrings("Configured.", overview.state.notice.?.text());
    // The next listing, which shows the new label, goes at once.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(lists + 1, Seen.now.lists);

    // /setup names no Session; both its streams reach the overview, in
    // the order it wrote them.
    Printing.stdout = "Defaults (read only):\nNotifications: on\n";
    Printing.stderr_text = "rui: Host unavailable\n";
    try std.testing.expect(try rig.press("/setup\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("/setup", Printing.line.slice());
    try std.testing.expectEqualStrings("", Printing.session.slice());
    try std.testing.expectEqualStrings("Defaults (read only):\nNotifications: on\nrui: Host unavailable", overview.state.panel.?.output.text);
    try std.testing.expectEqual(@as(usize, 2), Printing.runs);
}

test "a /setup that saves another model starts the next Session on it, unless the launch named it or /configure holds one" {
    const Case = struct { selectors: new_session_selection.Intent = .{}, setup: []const u8 = "/setup --model gpt-5.5\r", edit: preferences.Edit, configure: ?[]const u8 = null, model: []const u8 };
    for ([_]Case{
        .{ .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-5.5" },
        .{ .setup = "/setup --clear-model\r", .edit = .{ .model = .clear }, .model = product_defaults.recommended_model },
        .{ .selectors = .{ .model = "gpt-6-luna" }, .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-6-luna" },
        .{ .selectors = explicit_selectors, .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-6-luna" },
        .{ .edit = .{ .model = .{ .set = "gpt-5.5" } }, .configure = "/configure --model gpt-6-sol\r", .model = "gpt-6-sol" },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        try pin(home, "codex", "gpt-6-luna");
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = case.selectors }, fake_operations, &cancellation);
        defer rig.close();
        Printing.use(rig, tmp.dir);
        // The CLI's /setup saves as `rui defaults configure` does.
        const Setup = struct {
            var at: []const u8 = "";
            var edit: preferences.Edit = .{};
            fn command(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, _: []u8) anyerror!void {
                _ = try preferences.update(at, edit, &.initFill(.configured));
                const said = "Rui: Saved.\n";
                if (std.c.write(1, said.ptr, said.len) != said.len) return error.TestUnexpectedResult;
            }
        };
        Setup.at = home;
        Setup.edit = case.edit;
        rig.overview.hooks.command = Setup.command;
        if (case.configure) |line| try std.testing.expect(try rig.press(line) == null);
        try std.testing.expect(try rig.press(case.setup) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(try rig.press("hello\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings("codex", Seen.now.start.provider.?.slice());
        try std.testing.expectEqualStrings(case.model, Seen.now.start.model.?.slice());
    }
}

test "a command that cannot start says why, and one that fails while it runs ends the overview, whose way out prints its output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const rig = try commandRig(tmp.dir, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = struct {
        fn scratch(_: std.process.Init) !std.Io.File {
            return error.FileNotFound;
        }
    }.scratch;
    try std.testing.expect(try rig.press("/setup\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Printing.runs);
    try std.testing.expectEqualStrings("! /setup unavailable.", rig.overview.state.notice.?.text());

    rig.overview.hooks.scratch = Printing.scratch;
    const said = "rui: configure: CanonicalStoreFailure; check saved requests before retrying\n";
    Printing.stderr_text = said;
    Printing.failure = error.CanonicalStoreFailure;
    try std.testing.expect(try rig.press("/rename x\r") == null);
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
    var buffer: [1024]u8 = undefined;
    const written = try finishedGuidance(rig, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "rui: /rename output:\n" ++ said) != null);
}

test "a command that fails while it runs is the failure reported, even when taking its answer runs out of memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const rig = try commandRig(tmp.dir, &cancellation);
    defer rig.close();
    Printing.stderr_text = "rui: configure: CanonicalStoreFailure\n";
    Printing.failure = error.CanonicalStoreFailure;
    try std.testing.expect(try rig.press("/rename x\r") == null);
    // The core keeps the output for the way out with memory it cannot get.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = rig.overview.state.gpa;
    rig.overview.state.gpa = failing.allocator();
    defer rig.overview.state.gpa = gpa;
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
    try std.testing.expect(failing.has_induced_failure);
}

test "overview archive effects preserve server filter, pending visibility, and restore intent" {
    const Listing = struct {
        var archive_state: protocol.SessionArchiveState = .active;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            for (page.rows[0..page.count]) |*row| {
                row.archive_state = archive_state;
                row.work.state = switch (archive_state) {
                    .active => .{ .working = .{ .since = test_now_s } },
                    .archiving => .{ .stopping = .{ .since = test_now_s } },
                    .archived => .{ .stopped = .{ .since = test_now_s, .cause = .stop } },
                };
            }
            return null;
        }
    };
    var ops = fake_operations;
    ops.list = Listing.list;
    Listing.archive_state = .active;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(protocol.SessionArchiveFilter.active, Seen.now.archive_filter);
    try std.testing.expect(try rig.press("/archive\r") == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.archive_session);
    try std.testing.expect(Seen.now.archive_requested);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    try std.testing.expectEqual(view.ArchiveState.active, overview.state.rows.items[0].archive_state);
    Listing.archive_state = .archiving;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(view.ArchiveState.archiving, overview.state.rows.items[0].archive_state);
    Listing.archive_state = .archived;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 2 * view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), overview.state.rows.items.len);
    try std.testing.expect(try rig.press("/sessions archived\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(protocol.SessionArchiveFilter.archived, Seen.now.archive_filter);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    try std.testing.expect(try rig.press("/unarchive\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.archives);
    try std.testing.expect(!Seen.now.archive_requested);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    Listing.archive_state = .active;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 3 * view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), overview.state.rows.items.len);
}

test "Alt-A overview archives at once and preserves draft bytes caret and revision through the server answer" {
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| for ([_]bool{ false, true }) |rejected| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expect(try rig.press("/rename unfinished\x1b[D\x1b[D") == null);
        if (rejected) try std.testing.expect(try rig.press("\xff") == null);
        const before = overview.composerDraft();
        const target = overview.state.selected.session;
        try std.testing.expect(try rig.press(chord) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
        try std.testing.expectEqualStrings(&target, &Seen.now.archive_session);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
        const after = overview.composerDraft();
        try std.testing.expectEqualStrings("/rename unfinished", after.bytes);
        try std.testing.expectEqual(before.cursor, after.cursor);
        try std.testing.expectEqual(before.edits, after.edits);
        try std.testing.expectEqual(rejected, overview.composer.rejected != null);
    };
}

test "a command read shows the bytes its operation returned" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    const row = &overview.state.rows.items[0];
    row.command = .requested;
    row.first_action = 7;
    var reads: view.Commands = .{};
    reads.items[0] = .{ .reference = row.reference, .action = 7 };
    reads.len = 1;
    overview.queue(.{ .commands = reads });
    try std.testing.expect(try rig.settle() == null);
    const shown = &overview.state.rows.items[0];
    try std.testing.expectEqualStrings("zig build test-store", overview.state.lines.items[shown.command.read].slice());
}

test "a stop that ends with no answer reads as failed, whatever the job before it left" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    // The Host accepts an archive: the job before the stop left an accepted reply.
    try std.testing.expect(try rig.press("\x1ba") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    overview.ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, _: *Reply) !void {
            Seen.now.stops += 1;
            return error.ConnectionRefused;
        }
    }.stop;
    overview.state.notice = null;
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! k7m2qx not stopped: stop_request_failed", overview.state.notice.?.text());
}

test "conversation archive and restore use the exact unlisted opened reference through the existing worker" {
    const rig = try openListed();
    defer rig.close();
    rig.overview.opened = "x9y8z7".*;
    const selected = rig.overview.state.selected.session;
    _ = try conversed(rig.overview, .idle, .{ .archive = .active });
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expect(Seen.now.archive_requested);
    _ = try conversed(rig.overview, .idle, .unarchive);
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.archives);
    try std.testing.expect(!Seen.now.archive_requested);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expectEqualStrings(&selected, &rig.overview.state.selected.session);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
}

test "upgrade quiescence settles accepted queued and running archive mutations before releasing the panel" {
    const Gate = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);
        var observed_cancel: bool = false;
        var calls: usize = 0;

        fn archive(_: *Self, requests: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            calls += 1;
            entered.store(true, .release);
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &release, test_poll.isSet);
            // Record before replying: cleanup or joining cannot repair this fact.
            observed_cancel = requests.cancellation.?.stopped.load(.acquire);
            reply.* = .unconfirmed("original-archive-handle");
        }

        fn completed(overview: *Self) bool {
            return overview.worker.completed();
        }
    };
    for ([_]bool{ false, true }) |running| for ([_]bool{ false, true }) |archived| {
        var ops = fake_operations;
        ops.archive = Gate.archive;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        Gate.entered.store(false, .release);
        Gate.release.store(false, .release);
        Gate.observed_cancel = false;
        Gate.calls = 0;
        defer Gate.release.store(true, .release);
        const overview = rig.overview;
        _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = if (archived) .{ .archive = .active } else .unarchive } });
        try std.testing.expectEqual(@as(usize, 1), overview.job_count);
        if (running) try overview.dispatch(.all);
        try overview.startUpgrade();
        try std.testing.expect(overview.state.upgrading());
        try std.testing.expect(!try overview.quiesceUpgrade());
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &Gate.entered, test_poll.isSet);
        try std.testing.expect(!try overview.quiesceUpgrade());
        try std.testing.expectEqual(@as(usize, 1), overview.state.request_count);
        try std.testing.expectEqual(@as(@FieldType(view.Request, "status"), .pending), overview.state.requests[0].status);
        // A fresh opposite intent is not another accepted job to drain.
        _ = try overview.event(.{ .conversed = .{ .reference = "b4n8wd".*, .work = .idle, .input = if (archived) .unarchive else .{ .archive = .active } } });
        try std.testing.expectEqual(@as(usize, 1), overview.state.request_count);
        try std.testing.expectEqual(@as(usize, 0), overview.job_count);
        Gate.release.store(true, .release);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), overview, Gate.completed);
        try std.testing.expect(try overview.quiesceUpgrade());
        try std.testing.expect(!Gate.observed_cancel);
        try std.testing.expectEqual(@as(usize, 1), Gate.calls);
        try std.testing.expectEqual(@as(@FieldType(view.Request, "status"), .unknown), overview.state.requests[0].status);
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try view.writeDeparture(&overview.state, null, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "original-archive-handle") != null);
        try std.testing.expect(overview.worker.thread == null);
    };
}

test "Esc while Upgrade waits for a held archive keeps the cancel: nothing checks or installs" {
    const Gate = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);

        fn archive(_: *Self, requests: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            entered.store(true, .release);
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &release, test_poll.isSet);
            reply.* = .{ .outcome = .accepted };
        }

        fn completed(overview: *Self) bool {
            return overview.worker.completed();
        }
    };
    var ops = fake_operations;
    ops.archive = Gate.archive;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    Gate.entered.store(false, .release);
    Gate.release.store(false, .release);
    defer Gate.release.store(true, .release);
    const overview = rig.overview;
    _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = .{ .archive = .active } } });
    try overview.dispatch(.all);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &Gate.entered, test_poll.isSet);
    try overview.startUpgrade();
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    // The archive holds the handoff: the run has not started.
    try overview.appUpgrade(&ctx);
    try std.testing.expect(overview.state.upgrading() and !overview.upgrade_job.started);
    // Kitty's Esc, unambiguous on its own.
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    Gate.release.store(true, .release);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), overview, Gate.completed);
    var turns: usize = 0;
    while (overview.state.upgrading()) : (turns += 1) {
        try std.testing.expect(turns < 100);
        try overview.appUpgrade(&ctx);
    }
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", overview.state.notice.?.text());
    try std.testing.expect(overview.upgrade_report == null);
}

test "memory counts this TUI alone while no Host runs, at open and after a Host it sampled is gone" {
    var cancellation: client.Cancellation = .{};
    // No Host serves this Store.
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const first = overview.hostFacts();
    try std.testing.expect(first.observation.facts() == null);
    const alone = first.memory orelse return error.TestUnexpectedResult;
    try std.testing.expect(alone.rui > 0 and alone.tools == null);
    // As after one good sample of a Host and its tools, which then stopped:
    // the read after it carries nothing over from that sample.
    overview.host_process = .{ .started_at = 1, .pid = std.c.getpid() };
    const second = overview.hostFacts();
    try std.testing.expect(second.observation.facts() == null);
    try std.testing.expect(overview.host_process == null);
    const after = second.memory orelse return error.TestUnexpectedResult;
    try std.testing.expect(after.rui > 0 and after.tools == null);
}

test "a conversation's Upgrade waits for the conversation's running read, though the overview ticks first" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *ClientTask) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var ops = fake_operations;
    ops.open = openSession;
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
    defer {
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    try std.testing.expect(try rig.settle() == null);
    const frontend = overview.app_session.?.frontend.?;
    try std.testing.expect(overview.root.session != null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    // Version's backend preserves every admitted inspection before a run.
    const backend = overview.settingsBackend();
    for ([_]bool{ false, true }) |typed| for ([_]bool{ false, true }) |queued| for ([_]bool{ false, true }) |running| {
        if (!typed and !queued and !running) continue;
        if (typed) frontend.info_edit = .{ .permission = .ask };
        if (queued) frontend.input.queueCommand("/requests");
        frontend.inspection.command_running = running;
        try std.testing.expectError(error.UpgradeUnavailable, backend.upgrade(backend.context));
        try std.testing.expect(!overview.state.upgrading());
        if (typed) try std.testing.expectEqual(@as(@FieldType(@import("status_page.zig").Session, "permission"), .ask), frontend.info_edit.?.permission);
        if (queued) try std.testing.expectEqualStrings("/requests", frontend.input.takeCommand().?);
        frontend.info_edit = null;
        frontend.inspection.command_running = false;
    };
    // A read the conversation still runs, then Upgrade before its tick.
    try frontend.reader.start(std.testing.io, frontend, Worker.read);
    try overview.startUpgrade();
    try std.testing.expect(overview.state.upgrading());
    for (0..3) |_| try overview.appUpgrade(&ctx);
    try std.testing.expect(overview.state.upgrading() and !overview.upgrade_job.started);
    // Esc ends the run that never started, as on the overview.
    _ = try conversed(overview, .idle, .cancel_upgrade);
    frontend.reader.cancel();
    frontend.reader.join() catch {};
    var turns: usize = 0;
    while (overview.state.upgrading()) : (turns += 1) {
        try std.testing.expect(turns < 100);
        try overview.appUpgrade(&ctx);
    }
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", overview.state.notice.?.text());
    try std.testing.expect(overview.upgrade_report == null);
    frontend.leaving = .returned;
    try appSessionLeft(overview, &ctx, .returned);
}

test "upgrade quiescence cancels read jobs rather than granting them mutation custody" {
    const Read = struct {
        var cancelled: bool = false;

        fn models(_: *Self, requests: client.Requests, _: std.mem.Allocator) ![]u8 {
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &requests.cancellation.?.stopped, test_poll.isSet);
            cancelled = requests.cancellation.?.stopped.load(.acquire);
            return error.Cancelled;
        }

        fn settled(overview: *Self) !bool {
            return overview.quiesceUpgrade();
        }
    };
    var ops = fake_operations;
    ops.models = Read.models;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    Read.cancelled = false;
    rig.overview.queue(.models);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), rig.overview, Read.settled);
    try std.testing.expect(Read.cancelled);
    try std.testing.expect(rig.overview.worker.thread == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
}

test "App overview applies command draft endings to its composer" {
    for ([_]struct { line: []const u8, escape: bool = false }{
        .{ .line = "/configure --permission-mode ", .escape = true },
        .{ .line = "/nope" },
        .{ .line = "/sessions" },
        .{ .line = "/sessions nope" },
    }) |case| {
        const rig = try openListed();
        defer rig.close();
        _ = try rig.press(case.line);
        var listed = try rig.shown(80, 24);
        defer listed.deinit();
        if (case.escape) try std.testing.expectEqual(.drawn, rig.overview.state.commands.?.seen);
        _ = try rig.press(if (case.escape) "\x1b" else "\r");
        try std.testing.expectEqualStrings("", rig.overview.composerDraft().bytes);
    }
}

test "typing / lists the overview's commands over the Sessions, and a short screen counts the rest" {
    const rig = try openListed();
    defer rig.close();
    _ = try rig.press("/");
    var all = try rig.shown(80, 24);
    defer all.deinit();
    try all.expectLines(14, &.{
        "/archive",
        "/configure",
        "/rename",
        "/sessions   unarchived · archived · all",
        "/setup",
        "/unarchive",
        "────────────────────────────────────────────────────────────────────────────────",
        " › /",
    });
    try std.testing.expect(std.mem.endsWith(u8, try all.line(23), "enter pick / esc close"));
    // The pinned control leaves four commands and a count of the rest.
    var short = try rig.shown(80, 10);
    defer short.deinit();
    try short.expectLines(0, &.{
        "  + New Session",
        "/archive",
        "/configure",
        "/rename",
        "/sessions   unarchived · archived · all",
        "+2 more · type to narrow",
        "────────────────────────────────────────────────────────────────────────────────",
    });
    // Typing narrows it; Esc closes it and consumes the command draft.
    _ = try rig.press("r");
    var narrowed = try rig.shown(80, 24);
    defer narrowed.deinit();
    try narrowed.expectLines(19, &.{ "/rename", "────────────────────────────────────────────────────────────────────────────────", " › /r" });
    _ = try rig.press("\x1b");
    var closed = try rig.shown(80, 24);
    defer closed.deinit();
    try closed.expectLines(20, &.{ "────────────────────────────────────────────────────────────────────────────────", " › Type a task" });
    try std.testing.expectEqualStrings("", rig.overview.composerDraft().bytes);
}

test "the cursor sits at the composer's caret and hides while a start is pending" {
    const rig = try openListed();
    defer rig.close();
    _ = try rig.press("Fix 中");
    var typed = try rig.shown(80, 24);
    defer typed.deinit();
    try std.testing.expectEqualStrings(" › Fix 中", try typed.line(21));
    try std.testing.expectEqual(@as(?vaxis.Screen.Cursor, .{ .row = 21, .col = 9 }), typed.cursor());
    // Left steps over the wide character's two cells.
    _ = try rig.press("\x1b[D");
    var left = try rig.shown(80, 24);
    defer left.deinit();
    try std.testing.expectEqual(@as(?vaxis.Screen.Cursor, .{ .row = 21, .col = 7 }), left.cursor());
    _ = try rig.press("\x1b[F\r");
    try std.testing.expectEqual(view.InputMode.frozen, rig.overview.state.inputMode());
    var pending = try rig.shown(80, 24);
    defer pending.deinit();
    // The frozen composer takes no Enter, so the Footer offers none.
    try std.testing.expect(std.mem.indexOf(u8, try pending.line(23), "enter ") == null);
    try std.testing.expectEqual(@as(?vaxis.Screen.Cursor, null), pending.cursor());
}

test "a draft past its cap scrolls inside the composer, and the rule counts what it hides in Unicode or ASCII" {
    const rig = try openListed();
    defer rig.close();
    _ = try rig.press("1\x0a2\x0a3\x0a4\x0a5\x0a6\x0a7\x0a8\x0a9\x0a10\x0a11\x0a12\x0a13");
    var tail = try rig.shown(40, 40);
    defer tail.deinit();
    // Ten rows of draft between the rules, the caret on the last.
    try tail.expectLines(27, &.{ "──────────── ↑ 3 more lines ────────────", "   4" });
    try tail.expectLines(37, &.{ "   13", "────────────────────────────────────────" });
    try std.testing.expectEqual(@as(?vaxis.Screen.Cursor, .{ .row = 37, .col = 5 }), tail.cursor());
    // The caret moving above the shown lines takes them up with it.
    for (0..11) |_| _ = try rig.press("\x1b[A");
    var up = try rig.shown(40, 40);
    defer up.deinit();
    try up.expectLines(27, &.{ "───────── ↑ 1 · ↓ 2 more lines ─────────", "   2" });
    try std.testing.expectEqual(@as(?vaxis.Screen.Cursor, .{ .row = 28, .col = 4 }), up.cursor());
    // Without Unicode the rules, marks and prompt are ASCII.
    rig.overview.caps.unicode = false;
    _ = try rig.press("\x1b[A");
    var ascii = try rig.shown(40, 40);
    defer ascii.deinit();
    try ascii.expectLines(27, &.{ "------------ v 3 more lines ------------", " > 1" });
}

test "a click on a Session row, as a terminal sends it, opens the row under it after the list scrolls" {
    const rig = try openListed();
    defer rig.close();
    rig.overview.state.selected = .{ .session = shownRow(rig, 4) };
    var shown = try rig.shown(60, 13);
    defer shown.deinit();
    const row: u16 = for (0..7) |at| {
        const line = try shown.line(@intCast(at));
        if (std.mem.indexOf(u8, line, "Fix the flaky test") != null and std.mem.endsWith(u8, line, "13s")) break @intCast(at);
    } else return error.TestExpectedRow;
    try std.testing.expectEqualStrings("────────────────────────────────────────────────────────────", try shown.line(7));
    try std.testing.expect(try rig.click(10, 7, 60, 13) == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expect(try rig.click(10, row, 60, 13) == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings(&shownRow(rig, 3), &Seen.now.conversed);
}

test "a click on New Session, as a terminal sends it, selects the composer" {
    const rig = try openListed();
    defer rig.close();
    var shown = try rig.shown(60, 16);
    defer shown.deinit();
    const row: u16 = for (0..16) |at| {
        if (std.mem.indexOf(u8, try shown.line(@intCast(at)), "+ New Session") != null) break @intCast(at);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(try rig.click(3, row, 60, 16) == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expectEqual(view.Selection.new_session, rig.overview.state.selected);
}

test "a click on an output panel opens no Session because only the Sessions hear a press" {
    const rig = try openListed();
    defer rig.close();
    try showOutputPanel(rig);
    try std.testing.expect(rig.overview.state.listArea() != .sessions);
    const selected = rig.overview.state.selected.session;
    for (0..18) |row| try std.testing.expect(try rig.click(10, @intCast(row), 80, 24) == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expectEqualStrings(&selected, &rig.overview.state.selected.session);
    try std.testing.expect(rig.overview.state.listArea() != .sessions);
}

test "a followed Session link opens the peer, Esc reopens the Session it left, then the overview" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    // A link in k7m2qx names m3n4p5; k7m2qx then leaves.
    overview.follow.pending = "m3n4p5".*;
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("m3n4p5", &Seen.now.conversed);
    // Esc in m3n4p5 reopens k7m2qx; Esc there reaches the overview.
    try overview.followNext(&ctx, "m3n4p5".*);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expect(!ctx.quit);
}

test "a Session link that no longer opens ends as any failed open, naming that Session" {
    var ops = fake_operations;
    ops.open = struct {
        fn open(_: *Self, _: *vxfw.EventContext) !void {
            return error.SessionNotFound;
        }
    }.open;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    overview.follow.pending = "m3n4p5".*;
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expect(ctx.quit);
    const unopened = overview.app_session.?;
    try std.testing.expectEqualStrings("m3n4p5", &unopened.session);
    try std.testing.expectError(error.SessionNotFound, unopened.ended);
    // The way back names the Session the person left, never the failed one.
    try std.testing.expectEqualStrings("k7m2qx", &overview.follow.return_to.?);
    try std.testing.expectEqual(@as(?view.Reference, null), overview.follow.pending);
    overview.app_session = null;
}

test "App overview schedules spinning rows only while Root shows the list" {
    const session: vxfw.Text = .{ .text = "Session" };
    for ([_]bool{ false, true }) |spinning| {
        const rig = try openComposer();
        defer rig.close();
        const overview = rig.overview;
        overview.caps = .{};
        Seen.now.working = @intFromBool(spinning);
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        // Keep unrelated listing refreshes from requesting a frame.
        overview.state.next_list_ms = std.math.maxInt(u64);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const Layout = struct { width: u16, open: bool, visible: bool };
        for ([_]Layout{
            .{ .width = 140, .open = false, .visible = true },
            .{ .width = 99, .open = false, .visible = true },
            .{ .width = 100, .open = false, .visible = true },
            .{ .width = 46, .open = false, .visible = true },
            // Opening at phone width hides the last drawn spinning row.
            .{ .width = 46, .open = true, .visible = false },
            .{ .width = 99, .open = true, .visible = false },
            .{ .width = 100, .open = true, .visible = true },
            .{ .width = 99, .open = true, .visible = false },
            .{ .width = 140, .open = true, .visible = true },
            .{ .width = 46, .open = true, .visible = false },
            // Closing at phone width makes the same list eligible again.
            .{ .width = 46, .open = false, .visible = true },
        }) |layout| {
            if (layout.open and overview.root.session == null) try overview.root.openSession(&ctx, session.widget());
            if (!layout.open and overview.root.session != null) try overview.root.closeSession(&ctx);
            _ = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = layout.width, .height = 24 }, .cell_size = .{} });
            try std.testing.expectEqual(spinning, overview.listSpins());
            // Force a due animation step without waiting for the clock. A
            // hidden list cannot advance its last frame, even on later ticks.
            overview.app_frame = std.math.maxInt(u64);
            // Current facts govern animation even before another draw. None
            // of these changes can leave a cached spinning flag behind.
            const caps = overview.caps;
            overview.caps.depth = .none;
            try std.testing.expectEqual(false, overview.wantsFrame());
            overview.caps = caps;
            overview.state.list_stale = true;
            try std.testing.expectEqual(false, overview.wantsFrame());
            overview.state.list_stale = false;
            const row_state = overview.state.rows.items[0].state;
            overview.state.rows.items[0].state = .{ .idle = .{ .since = test_now_s } };
            try std.testing.expectEqual(false, overview.wantsFrame());
            overview.state.rows.items[0].state = row_state;
            for (0..2) |_| {
                ctx.redraw = false;
                try overview.root.widget().handleEvent(&ctx, .tick);
                try std.testing.expectEqual(spinning and layout.visible, ctx.redraw);
            }
        }
    }
}

test "App overview panes prepare rows and compose only at their actual widths" {
    const Find = struct {
        fn count(surface: vxfw.Surface, target: vxfw.Widget) usize {
            var found: usize = @intFromBool(surface.widget.eql(target));
            for (surface.children) |child| found += count(child.surface, target);
            return found;
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try rig.press("/") == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const wide = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
    const panes = wide.children[0].surface.children;
    try std.testing.expectEqual(@as(u16, 40), overview.state.size.width);
    try std.testing.expectEqual(@as(u16, 40), panes[0].surface.size.width);
    try std.testing.expectEqual(@as(u16, 99), panes[2].surface.size.width);
    const composer = overview.app_input.composer.widget();
    const header = overview.app_header.widget();
    const palette = overview.app_palette.widget();
    try std.testing.expectEqual(@as(usize, 1), Find.count(panes[0].surface, header));
    try std.testing.expectEqual(@as(usize, 0), Find.count(panes[0].surface, composer));
    try std.testing.expectEqual(@as(usize, 0), Find.count(panes[0].surface, palette));
    try std.testing.expectEqual(@as(usize, 0), Find.count(panes[2].surface, header));
    try std.testing.expectEqual(@as(usize, 1), Find.count(panes[2].surface, composer));
    try std.testing.expectEqual(@as(usize, 1), Find.count(panes[2].surface, palette));
    try std.testing.expect(panes[2].surface.widget.eql(overview.widget()));
    try std.testing.expectEqualStrings("/", overview.composerDraft().bytes);
    const phone = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 26 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 46), overview.state.size.width);
    try std.testing.expectEqual(@as(usize, 1), Find.count(phone, header));
    try std.testing.expectEqual(@as(usize, 1), Find.count(phone, composer));
    try std.testing.expectEqual(@as(usize, 1), Find.count(phone, palette));
    try std.testing.expectEqualStrings("/", overview.composerDraft().bytes);
}

test "App overview list stays live beside a focused child and wheels stay in their panes" {
    const Peer = struct {
        wheels: usize = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .mouse and (input.mouse.button == .wheel_down or input.mouse.button == .wheel_up)) {
                self.wheels += 1;
                ctx.consumeEvent();
            }
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = listed_references.len;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var peer: Peer = .{};
    overview.root.session = peer.widget();
    _ = try overview.event(.{ .conversation = "k7m2qx".* });
    overview.state.selected = .{ .session = "b4n8wd".* };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 4 }, .cell_size = .{} };
    const frame = try overview.root.widget().draw(draw);
    const selected = overview.app_sessions.selected.?;
    const target = view.clickOf(&overview.state, view.listItem(&overview.state, selected).?).?;
    try std.testing.expectEqualStrings("k7m2qx", &target.open);
    try std.testing.expectEqualStrings("b4n8wd", &overview.state.selected.session);
    const before = overview.app_sessions.list.scroll;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = 2, .button = .wheel_down, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 0), peer.wheels);
    try std.testing.expect(!std.meta.eql(before, overview.app_sessions.list.scroll));
    const scrolled = overview.app_sessions.list.scroll;
    try app_events.mouse(&ctx, frame, .{ .col = 45, .row = 2, .button = .wheel_down, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 1), peer.wheels);
    try std.testing.expectEqualDeep(scrolled, overview.app_sessions.list.scroll);
    // A later listing is still adopted and drawn at 40 cells with a child open.
    Seen.now.listed = 2;
    overview.state.next_list_ms = 0;
    _ = try service(overview);
    try rig.answered();
    ctx.redraw = false;
    try appEvent(overview, &ctx, .tick);
    try std.testing.expect(ctx.redraw);
    try rig.lend();
    _ = try overview.root.widget().draw(draw);
    try std.testing.expectEqual(@as(usize, 2), overview.state.rows.items.len);
    try std.testing.expectEqual(@as(u16, 40), overview.state.size.width);
    try std.testing.expect(overview.root.session.?.eql(peer.widget()));
}

test "App overview list press follows only after the open child settles and opens once" {
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    const Find = struct {
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (@This().origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
        fn row(overview: *Self, id: []const u8) i17 {
            for (overview.app_sessions.shown_at) |span| if (span.target) |target| {
                if (target == .open and std.mem.eql(u8, &target.open, id)) return span.row;
            };
            unreachable;
        }
        fn leave(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
            const overview: *Self = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("b4n8wd", &overview.follow.pending.?);
            const frontend = overview.app_session.?.frontend.?;
            try std.testing.expect(frontend.reader.thread == null);
            try std.testing.expect(frontend.skill_task.thread == null);
            try appSessionLeft(raw, ctx, outcome);
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            try std.testing.expectEqual(@as(usize, 1), overview.retired.items.len);
            try std.testing.expectEqualStrings("k7m2qx", &overview.follow.return_to.?);
            try std.testing.expectEqualStrings("b4n8wd", &overview.opened);
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, overview.app_sessions.widget());
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    overview.ops.open = openSession;
    overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
    defer {
        if (overview.app_session) |left| {
            if (left.frontend) |frontend| frontend.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        }
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    overview.app_session.?.frontend.?.app_hooks.leave = Find.leave;
    overview.ops.open = Find.open;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
    const origin = Find.origin(frame, overview.app_sessions.widget(), .{ .row = 0, .col = 0 }).?;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const original = overview.root.session.?;
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(origin.row + Find.row(overview, "k7m2qx")), .button = .left, .type = .press, .mods = .{} });
    try std.testing.expect(overview.root.session.?.eql(original));
    try std.testing.expect(overview.follow.pending == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(origin.row + Find.row(overview, "b4n8wd")), .button = .left, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("b4n8wd", &Seen.now.conversed);
    try std.testing.expect(overview.follow.pending == null);
    try std.testing.expect(!ctx.quit);
}

test "App shell divider follows overview locale across layouts and screen selection" {
    const rig = try openComposer();
    defer rig.close();
    try rig.environ.put("NO_COLOR", "1");
    const session: vxfw.Text = .{ .text = "Session" };
    for ([_]struct { locale: []const u8, glyph: []const u8, unicode: bool }{
        .{ .locale = "C", .glyph = "|", .unicode = false },
        .{ .locale = "en_US.UTF-8", .glyph = "│", .unicode = true },
    }) |case| {
        try rig.environ.put("LC_ALL", case.locale);
        var cancellation: client.Cancellation = .{};
        const overview = try create(rig.init, rig.overview.options, undefined, fake_operations, &cancellation);
        defer overview.destroy();
        overview.attention = &rig.attention;
        try std.testing.expectEqual(case.unicode, overview.caps.unicode);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        // Cover both construction and later theme/cursor repainting.
        for (0..2) |paint| {
            if (paint != 0) try overview.paintCursor();
            for ([_]bool{ false, true }) |open| {
                if (open) try overview.root.openSession(&events, session.widget()) else try overview.root.closeSession(&events);
                for ([_]u16{ 46, 99, 100, 140 }) |width| {
                    const surface = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} });
                    const layout = surface.children[0].surface;
                    if (width >= Root.split_at) {
                        const divider = layout.children[1].surface;
                        for (divider.buffer) |cell| try std.testing.expectEqualStrings(case.glyph, cell.char.grapheme);
                        try std.testing.expectEqualDeep(@import("widget_style.zig").of(overview.caps, .{ .colour = .quiet }), divider.buffer[0].style);
                    } else try std.testing.expect(layout.widget.eql(if (open) session.widget() else overview.widget()));
                    var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
                    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 24, .screen = &screen };
                    surface.render(window, overview.app_input.composer.widget());
                    if (!case.unicode) for (screen.buf) |cell| {
                        for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
                    };
                }
            }
        }
    }
}

test "App list clicks validate present and removed targets with open and closed chats" {
    const Click = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
        fn leave(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
            const overview: *Self = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("b4n8wd", &overview.follow.pending.?);
            const frontend = overview.app_session.?.frontend.?;
            try std.testing.expect(frontend.reader.thread == null);
            try std.testing.expect(frontend.skill_task.thread == null);
            try appSessionLeft(raw, ctx, outcome);
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, overview.app_sessions.widget());
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Click.dir = tmp.dir;
    for ([_]bool{ false, true }) |open| {
        for ([_]bool{ true, false }) |present| {
            Click.files = 0;
            var cancellation: client.Cancellation = .{};
            const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
            defer rig.close();
            const overview = rig.overview;
            Seen.now.listed = 2;
            try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
            try std.testing.expect(try rig.settle() == null);
            defer {
                if (overview.app_session) |left| {
                    if (left.frontend) |frontend| frontend.stop();
                    overview.disposeSession(left);
                    overview.app_session = null;
                }
                for (overview.retired.items) |retired| overview.disposeSession(retired.left);
                overview.retired.deinit(std.testing.allocator);
            }
            if (open) {
                overview.hooks.scratch = Click.scratch;
                overview.ops.open = openSession;
                try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
                overview.app_session.?.frontend.?.app_hooks.leave = Click.leave;
            }
            overview.ops.open = Click.open;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
            const at = Click.origin(frame, overview.app_sessions.widget(), .{ .row = 0, .col = 0 }).?;
            const row = for (overview.app_sessions.shown_at) |span| {
                if (span.target) |target| if (target == .open and std.mem.eql(u8, &target.open, "b4n8wd")) break span.row;
            } else unreachable;
            // Refresh the core without replacing the drawn hit targets.
            if (!present) {
                Seen.now.listed = 1;
                overview.state.next_list_ms = 0;
                try std.testing.expect(try overview.event(.{ .tick = (test_now_s + 1) * 1000 }) == null);
                try std.testing.expect(try rig.settle() == null);
                try std.testing.expect(overview.state.find("b4n8wd".*) == null);
            }
            const previous = overview.root.session;
            const selected = overview.state.selected;
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(at.row + row), .button = .left, .type = .press, .mods = .{} });
            try std.testing.expectEqual(@as(usize, @intFromBool(present)), Seen.now.conversations);
            try std.testing.expect(overview.follow.pending == null);
            try std.testing.expect(!ctx.quit);
            if (present) {
                try std.testing.expectEqualStrings("b4n8wd", &Seen.now.conversed);
                try std.testing.expectEqualStrings("b4n8wd", &overview.state.selected.session);
                try std.testing.expectEqual(@as(usize, @intFromBool(open)), overview.retired.items.len);
            } else {
                try std.testing.expectEqual(selected, overview.state.selected);
                try std.testing.expectEqual(@as(usize, 0), overview.retired.items.len);
                if (previous) |widget_| try std.testing.expect(overview.root.session.?.eql(widget_)) else try std.testing.expect(overview.root.session == null);
            }
        }
    }
}

test "App root navigation shows and focuses the main pane before every Session selection" {
    const Nav = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        var inits: usize = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            try std.testing.expect(!overview.root.input.layer.settingsOpen());
            try std.testing.expect((try focus(ctx)).eql(overview.widget()));
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, @This().widget(overview));
        }
        fn widget(overview: *Self) vxfw.Widget {
            return .{ .userdata = overview, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            if (input == .init) inits += 1;
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const overview: *Self = @ptrCast(@alignCast(raw));
            return .{ .widget = @This().widget(overview), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
        fn contains(surface: vxfw.Surface, target: vxfw.Widget) bool {
            if (surface.widget.eql(target)) return true;
            for (surface.children) |child| if (contains(child.surface, target)) return true;
            return false;
        }
        fn focus(ctx: *vxfw.EventContext) !vxfw.Widget {
            var i = ctx.cmds.items.len;
            while (i > 0) {
                i -= 1;
                if (ctx.cmds.items[i] == .request_focus) return ctx.cmds.items[i].request_focus;
            }
            return error.TestUnexpectedResult;
        }
    };
    // App-owned drafts can leave safely; SessionFrontend tests own their
    // handoff policy. Exercise unresolved-work guards, not draft emptiness.
    const Guard = enum { allowed, pending, action, command };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Nav.dir = tmp.dir;
    for ([_]bool{ true, false }) |settings_open| {
        for ([_]u16{ 140, 46 }) |width| {
            for ([_]bool{ false, true }) |retained| {
                for ([_]view.Reference{ "k7m2qx".*, "b4n8wd".* }) |target| {
                    for (std.enums.values(Guard)) |guard| {
                        // Without a retained Session there is nothing to depart.
                        if (!retained and guard != .allowed) continue;
                        errdefer std.debug.print("navigation: settings={any}, width={d}, retained={any}, target={s}, guard={s}\n", .{ settings_open, width, retained, target, @tagName(guard) });
                        Nav.files = 0;
                        Nav.inits = 0;
                        var cancellation: client.Cancellation = .{};
                        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
                        defer rig.close();
                        const overview = rig.overview;
                        Seen.now.listed = 2;
                        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
                        try std.testing.expect(try rig.settle() == null);
                        defer {
                            if (overview.app_session) |left| {
                                if (left.frontend) |frontend| frontend.stop();
                                overview.disposeSession(left);
                                overview.app_session = null;
                            }
                            for (overview.retired.items) |retired_session| overview.disposeSession(retired_session.left);
                            overview.retired.deinit(std.testing.allocator);
                        }
                        if (retained) {
                            overview.hooks.scratch = Nav.scratch;
                            overview.ops.open = openSession;
                            try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
                        }
                        overview.ops.open = Nav.open;
                        const original = overview.root.session;
                        const frontend = if (overview.app_session) |left| left.frontend else null;
                        const same = retained and std.mem.eql(u8, &target, "k7m2qx");
                        if (frontend) |held| {
                            held.reading.opening = false;
                            // Hold one owner fact without a tick/worker that
                            // could consume it before the selection observes it.
                            switch (guard) {
                                .allowed => {},
                                .pending => {
                                    held.submission.intent = .{ .message = held.input.submitText("pending message") };
                                    held.submission.state = .submitting;
                                },
                                .action => held.reading.prepared_action = 42,
                                .command => held.inspection.command_running = true,
                            }
                        }
                        var ctx = rig.context();
                        defer ctx.cmds.deinit(std.testing.allocator);
                        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                        defer arena.deinit();
                        const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} };
                        _ = try overview.root.widget().draw(draw_context);
                        if (settings_open) {
                            try overview.root.openSettings(&ctx);
                            const settings = try overview.root.widget().draw(draw_context);
                            try std.testing.expect(Nav.contains(settings, overview.root.settings_page.widget()));
                            try std.testing.expect((try Nav.focus(&ctx)).eql(overview.root.settings_page.widget()));
                        }
                        ctx.cmds.clearRetainingCapacity();
                        ctx.redraw = false;
                        // The list's semantic selection has one presentation
                        // transition, independent of the later departure result.
                        try overview.appNext(&ctx, try overview.event(.{ .clicked = .{ .target = .{ .open = target } } }));
                        try std.testing.expect(!ctx.quit);
                        try std.testing.expect(ctx.redraw);
                        try std.testing.expect(!overview.root.input.layer.settingsOpen());
                        try std.testing.expect(!overview.root.settings_page.hasChoice());
                        try std.testing.expect(overview.follow.pending == null);
                        const kept = retained and (same or guard != .allowed);
                        try std.testing.expectEqual(@as(usize, @intFromBool(!kept)), Seen.now.conversations);
                        try std.testing.expectEqual(@as(usize, @intFromBool(!kept)), Nav.inits);
                        try std.testing.expectEqual(@as(usize, @intFromBool(retained and !kept)), overview.retired.items.len);
                        const notice: ?[]const u8 = if (kept and !same) switch (guard) {
                            .allowed => unreachable,
                            .pending => "Esc returns to the overview once the original is confirmed.",
                            .action => "Links open once the Action is decided.",
                            .command => "Links open once the command ends.",
                        } else null;
                        if (kept) {
                            if (notice) |reason| {
                                try std.testing.expectEqualStrings(reason, frontend.?.notice orelse return error.TestUnexpectedResult);
                            } else try std.testing.expect(frontend.?.notice == null);
                        }
                        const requested = try Nav.focus(&ctx);
                        try std.testing.expect(requested.eql(overview.root.session.?));
                        // App processes focus_in on the requested retained
                        // widget; its normal afterInput also presents the notice.
                        try requested.handleEvent(&ctx, .focus_in);
                        const selected = try overview.root.widget().draw(draw_context);
                        try std.testing.expect(Nav.contains(selected, overview.root.session.?));
                        try std.testing.expect(!Nav.contains(selected, overview.root.settings_page.widget()));
                        const focused = try Nav.focus(&ctx);
                        try std.testing.expect(focused.eventHandler != null);
                        try std.testing.expect(Nav.contains(selected, focused));
                        try std.testing.expectEqual(width >= Root.split_at, overview.root.listVisible());
                        if (kept) {
                            const held = frontend.?;
                            try std.testing.expect(overview.root.session.?.eql(original.?));
                            try std.testing.expect(overview.app_session.?.frontend.? == held);
                            try std.testing.expect(focused.eql(held.app_input.composer.widget()));
                            switch (guard) {
                                .allowed => {},
                                .pending => {
                                    try std.testing.expectEqual(.submitting, held.submission.state);
                                    try std.testing.expectEqualStrings("pending message", try held.input.message(held.submission.intent.?.message));
                                },
                                .action => try std.testing.expectEqual(@as(?u64, 42), held.reading.prepared_action),
                                .command => try std.testing.expect(held.inspection.command_running),
                            }
                            if (notice) |reason| {
                                var shown = try rig.shown(width, 24);
                                defer shown.deinit();
                                // Even phone chrome must show the reason, not
                                // merely store it on a hidden frontend.
                                try std.testing.expect(std.mem.indexOf(u8, try shown.text(), reason[0..31]) != null);
                            }
                        } else try std.testing.expectEqualStrings(&target, &Seen.now.conversed);
                    }
                }
            }
        }
    }
}

test "App settings Enter reaches Root at both widths with and without a retained Session" {
    const Settings = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Settings.dir = tmp.dir;
    for ([_]u16{ 46, 140 }) |width| {
        for ([_]bool{ false, true }) |retained| {
            errdefer std.debug.print("Settings row: width={d}, retained={any}\n", .{ width, retained });
            Settings.files = 0;
            var cancellation: client.Cancellation = .{};
            const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
            defer rig.close();
            const overview = rig.overview;
            Seen.now.listed = 2;
            try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
            try std.testing.expect(try rig.settle() == null);
            defer {
                if (overview.app_session) |left| {
                    if (left.frontend) |frontend| frontend.stop();
                    overview.disposeSession(left);
                    overview.app_session = null;
                }
                overview.retired.deinit(std.testing.allocator);
            }
            if (retained) {
                overview.hooks.scratch = Settings.scratch;
                overview.ops.open = openSession;
                try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
                _ = overview.app_session.?.frontend.?.input.append("retained draft");
            }
            const previous = overview.root.session;
            const frontend = if (overview.app_session) |left| left.frontend else null;
            var ctx = rig.context();
            defer ctx.cmds.deinit(std.testing.allocator);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} };
            _ = try overview.root.widget().draw(draw_context);
            // Real parser/overview handlers select the last list row;
            // do not synthesize a core click or set selected directly.
            // While a Session is the main pane Root gives it the keys, so
            // there the Settings row's own press opens the page.
            if (retained) {
                try appClick(overview, &ctx, .settings);
            } else {
                try app_events.send(&ctx, "\x1b[F", overview.root.widget(), overview.widget());
                try std.testing.expect(overview.state.selected == .settings);
                try std.testing.expect(!overview.root.input.layer.settingsOpen());
                try app_events.send(&ctx, "\r", overview.root.widget(), overview.widget());
            }
            try std.testing.expect(overview.root.input.layer.settingsOpen());
            try std.testing.expect(overview.state.selected == .settings);
            try std.testing.expect(!ctx.quit);
            try std.testing.expect(ctx.redraw);
            const focus = ctx.cmds.items[ctx.cmds.items.len - 1].request_focus;
            try std.testing.expect(focus.eql(overview.root.settings_page.widget()));
            try focus.handleEvent(&ctx, .focus_in);
            const opened = try overview.root.widget().draw(draw_context);
            try std.testing.expect(Settings.origin(opened, focus, .{ .row = 0, .col = 0 }) != null);
            try std.testing.expectEqual(width < Root.split_at, overview.root.settings_page.narrow);
            try std.testing.expectEqual(width >= Root.split_at, overview.root.listVisible());
            var shown = try rig.shown(width, 24);
            defer shown.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Rui") != null);
            try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Notifications") != null);
            if (previous) |widget_| {
                try std.testing.expect(overview.root.session.?.eql(widget_));
                try std.testing.expect(overview.app_session.?.frontend.? == frontend.?);
                try std.testing.expectEqualStrings("retained draft", frontend.?.input.composition().bytes);
                try std.testing.expect(Settings.origin(opened, widget_, .{ .row = 0, .col = 0 }) == null);
            } else try std.testing.expect(overview.root.session == null);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
            try std.testing.expectEqual(@as(usize, 0), overview.retired.items.len);
        }
    }
}

test "App settings receives the build version from its Overview owner" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expectEqualStrings(@import("transport_options").version, rig.overview.root.settings_page.version);
}

test "App settings typed saves own their strings and settle through the Overview worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const backend = overview.root.settings_page.backend.?;
    try std.testing.expectEqual(AppSettings.SaveState.idle, backend.save_state(backend.context));
    try std.testing.expect(try rig.press("kept draft") == null);
    var provider = "codex".*;
    var model = "gpt-5.5".*;
    try overview.saveDefaults(.{ .provider = .{ .set = &provider }, .model = .{ .set = &model }, .reasoning_effort = .{ .set = .low }, .notifications = false, .permission_mode = .{ .set = .ask } });
    @memset(&provider, 'x');
    @memset(&model, 'x');
    try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
    try std.testing.expect((try preferences.load(home)).notifications);
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = true }));
    try std.testing.expect(try rig.settle() == null);
    const saved = try preferences.load(home);
    try std.testing.expectEqualStrings("codex", saved.provider.slice());
    try std.testing.expectEqualStrings("gpt-5.5", saved.model.slice());
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .low), saved.reasoning_effort);
    try std.testing.expect(!saved.notifications);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), saved.permission_mode);
    try std.testing.expectEqual(AppSettings.SaveState.saved, backend.save_state(backend.context));
    try std.testing.expectEqualStrings("gpt-5.5", overview.state.default.?.model.slice());
    try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
    try std.testing.expect(overview.state.command == null and overview.state.panel == null);

    // Exercise the wired page, not a manually installed adapter. Its Enter
    // queues the same typed job and its tick reads the completed saved value.
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    const page = &overview.root.settings_page;
    page.select(.notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
    try std.testing.expect(!page.values.notifications);
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.values.notifications);
    try std.testing.expect(page.failures.get(.notifications) == null);
    try std.testing.expect(overview.state.command == null and overview.state.panel == null);
    try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);

    page.select(.permissions);
    for ([_]protocol.PermissionMode{ .bypass, .ask }) |mode| {
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.hasChoice());
        page.panel.choice.?.selected = if (mode == .bypass) 0 else 1;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
        try std.testing.expectEqual(@as(?AppSettings.Row, .permissions), page.saving_row);
        try std.testing.expect(try rig.settle() == null);
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(mode, (try preferences.load(home)).permission_mode.?);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, mode), page.values.permission_mode);
        try std.testing.expectEqual(@as(?AppSettings.Row, null), page.saving_row);
        try std.testing.expectEqualStrings("gpt-5.5", overview.state.default.?.model.slice());
        try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
    }
}

test "App settings typed worker failure reaches its row and a later save recovers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    const page = &overview.root.settings_page;
    page.select(.notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    // Refuse the real preference writer only after the page's edit is accepted.
    const obstruction = try tmp.dir.createFile(std.testing.io, ".config", .{});
    obstruction.close(std.testing.io);
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(overview.defaults_save == .failed);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures.get(.notifications).?);
    try std.testing.expect(!overview.state.left);
    try tmp.dir.deleteFile(std.testing.io, ".config");
    try std.testing.expect((try preferences.load(home)).notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.values.notifications);
    try std.testing.expect(page.failures.get(.notifications) == null);
    try std.testing.expect(overview.defaults_save == .saved);
}

test "App settings typed admission and Upgrade stay within the Overview owner" {
    const rig = try openComposer();
    defer rig.close();
    const overview = rig.overview;
    const backend = overview.root.settings_page.backend.?;
    const gpa = overview.init.gpa;
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    overview.init.gpa = failing.allocator();
    const refused = overview.saveDefaults(.{ .model = .{ .set = "example-chat" } });
    overview.init.gpa = gpa;
    try std.testing.expectError(error.OutOfMemory, refused);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    try std.testing.expectEqual(AppSettings.SaveState.idle, backend.save_state(backend.context));
    @memset(&overview.jobs, .host);
    overview.job_count = overview.jobs.len;
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
    overview.job_count = 0;
    try overview.startUpgrade();
    try std.testing.expectEqual(@as(?upgrade_status.Run, .checking), backend.run(backend.context));
    try std.testing.expect(!overview.upgrade_job.started);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
    try overview.startUpgrade();
    try std.testing.expectEqual(@as(?upgrade_status.Run, .checking), backend.run(backend.context));
    // Esc is the run's while it can still change nothing, settings open or not.
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    ctx.phase = .capturing;
    try overview.root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(overview.upgrade_job.cancelling);
    try std.testing.expect(overview.root.input.layer.settingsOpen());
    // Under the page nothing reaches the hidden draft or moves the list,
    // and leaving works as on the overview.
    const page = overview.root.settings_page.widget();
    const selected = overview.state.selected;
    try app_events.send(&ctx, "x\x1b[H\x18", overview.root.widget(), page);
    try std.testing.expectEqual(@as(usize, 0), overview.composerDraft().bytes.len);
    try std.testing.expectEqual(selected, overview.state.selected);
    try std.testing.expect(!ctx.quit and overview.root.input.layer.settingsOpen());
    try app_events.send(&ctx, "\x03", overview.root.widget(), page);
    try std.testing.expect(ctx.quit);
    ctx.quit = false;
    _ = try overview.event(.leave);
    try std.testing.expectError(error.UpgradeUnavailable, overview.startUpgrade());
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
}

test "App settings typed queued saves settle on departure and retain failures" {
    for ([_]bool{ false, true }) |fail| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        if (fail) try overview.saveDefaults(.{ .provider = .{ .set = "not-a-provider" } }) else try overview.saveDefaults(.{ .notifications = false });
        _ = try overview.event(.leave);
        if (fail) {
            try std.testing.expectError(error.UnsupportedPreferenceProvider, overview.flushSaves());
            try std.testing.expect(overview.defaults_save == .failed);
        } else {
            try overview.flushSaves();
            try std.testing.expect(!(try preferences.load(home)).notifications);
            try std.testing.expect(overview.defaults_save == .saved);
        }
        try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    }
}

test "pinned New Session remains above the end marker and responds to clicks and Enter" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        // End selects Settings; Up selects the last Session, without changing
        // the pinned control's position or stealing the selection's space.
        _ = try rig.press("\x1b[F\x1b[A");
        const selected = rig.overview.state.selected.session;
        for (0..2) |_| {
            var shown = try rig.shown(width, 11);
            defer shown.deinit();
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "  + New Session"));
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "↑") != null);
            const span = for (rig.overview.app_sessions.shown_at) |span| {
                if (span.target) |target| if (target == .open and std.mem.eql(u8, &target.open, &selected)) break span;
            } else return error.SelectedSessionMissing;
            try std.testing.expectEqual(@as(u16, 2), span.height);
        }
        try std.testing.expect(try rig.click(3, 0, width, 11) == null);
        try std.testing.expectEqual(view.Selection.new_session, rig.overview.state.selected);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expect(try rig.press("a new pinned task\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings("a new pinned task", Seen.now.start.text.slice());
        try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
    }
}

test "chat omits New Session at every width and overview restores its pinned control" {
    const Chat = struct {
        const child: vxfw.Text = .{ .text = "Chat transcript" };
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            overview.state.conversing = overview.opened;
            try overview.root.openSession(ctx, child.widget());
        }
    };
    const rig = try openListed();
    defer rig.close();
    rig.overview.ops.open = Chat.open;
    // Exercise the same list instance before opening, beside the chat, and on
    // return, including a prefix change while the list had scrolled.
    _ = try rig.press("\x1b[F\x1b[A");
    var before = try rig.shown(140, 11);
    defer before.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try before.text(), "+ New Session") != null);
    const selected = rig.overview.state.selected.session;
    _ = try rig.press("\r");
    for ([_]u16{ 140, 46, 140, 46 }) |width| {
        var shown = try rig.shown(width, 20);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "Chat transcript") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "+ New Session") == null);
        if (width == 140) {
            const line = rig.overview.app_sessions.selected.?;
            const target = view.clickOf(&rig.overview.state, view.listItem(&rig.overview.state, line).?).?;
            try std.testing.expectEqualStrings(&selected, &target.open);
        }
    }
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    rig.overview.state.conversing = null;
    try rig.overview.root.closeSession(&ctx);
    for ([_]u16{ 46, 140 }) |width| {
        var shown = try rig.shown(width, 20);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "  + New Session"));
    }
}

test "pinned New Session wins the last header row over a provider band" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        const state = &rig.overview.state;
        const row = &state.rows.items[state.order.items[0]];
        row.state = .{ .failed = .{ .since = test_now_s, .code = .{}, .resets_at = null } };
        try row.state.failed.code.set("provider_http_401");
        try std.testing.expect(view.band(state) != null);
        // Narrow screens reserve four input rows; the wide list has no input.
        var shown = try rig.shown(width, if (width == 46) 5 else 1);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "  + New Session"));
    }
}

test "relaunch departure matrix preserves every screen and all unsent drafts" {
    const gpa = std.testing.allocator;
    for (std.enums.values(session_upgrade.Outcome)) |outcome| {
        for ([_]bool{ false, true }) |conversation| {
            for ([_]bool{ false, true }) |guidance| {
                for ([_]bool{ false, true }) |drafted| {
                    var cancellation: client.Cancellation = .{};
                    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "", .directory = "/requests" }, fake_operations, &cancellation);
                    defer rig.close();
                    const overview = rig.overview;
                    // Exercise the real joined receipt -> keepUpgrade -> departure
                    // route, not a synthetic no-guidance incompatible outcome.
                    var arena: std.heap.ArenaAllocator = .init(gpa);
                    defer arena.deinit();
                    const a = arena.allocator();
                    const receipt: @import("Installation.zig").Receipt = .{
                        .operation_build = try a.dupe(u8, "/published/build"),
                        .selected_after = try a.dupe(u8, "/published/build"),
                        .selected_version = .{ .schema = 60, .patch = 0 },
                    };
                    overview.upgrade_job = .{
                        .allocator = a,
                        .started = true,
                        .finished = true,
                        .operation = .install,
                        .outcome = outcome,
                        .failure = if (guidance) error.ConnectionRefused else null,
                        .checked = .{
                            .candidate = .{
                                .version = .{ .schema = 60, .patch = 0 },
                                .tag = try a.dupe(u8, "v0.60.0"),
                                .archive_name = try a.dupe(u8, "fixture"),
                                .archive_url = try a.dupe(u8, "fixture"),
                                .checksum_url = try a.dupe(u8, "fixture"),
                                .sha256 = @splat(0),
                            },
                            .selected = .absent,
                            .hosts = .{},
                            .home = try a.dupe(u8, "/home"),
                            .store = try a.dupe(u8, "/store"),
                            .running_executable = try a.dupeSentinel(u8, "/old/rui", 0),
                            .path = .{ .state = .selected },
                        },
                        .result = .{
                            .installation = if (outcome == .unchanged) .{ .unchanged = receipt } else .{ .installed = receipt },
                            .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = try a.dupe(@import("host_restart_all.zig").Entry, &.{.{ .socket = try a.dupe(u8, ""), .store = try a.dupe(u8, "/store"), .state = .{ .outcome = switch (outcome) {
                                .unchanged => .not_needed,
                                .compatible => .{ .ready = .{ .instance = @splat(1), .pid = 42 } },
                                .incompatible => .{ .client_incompatible = 42 },
                            } } }}) },
                            .store = try a.dupe(u8, "/store"),
                        },
                    };
                    overview.state.upgrade.run = overview.upgrade_job.status();
                    try overview.keepUpgrade();
                    try std.testing.expectEqual(guidance, overview.upgrade_guidance);
                    var ending_buffer: [upgrade_status.max_line_bytes]u8 = undefined;
                    const ending = upgrade_status.relaunchLine(overview.state.upgrade.run.?, &ending_buffer, .unicode);
                    if (outcome == .incompatible) {
                        const report = overview.upgrade_report.?.written();
                        try std.testing.expect(std.mem.indexOf(u8, report, "This client cannot safely resume Host requests") != null);
                        try std.testing.expect(std.mem.indexOf(u8, report, "Next: inspect") == null);
                        try std.testing.expect(std.mem.indexOf(u8, ending, "restart rui") == null);
                    }
                    if (drafted) {
                        @memcpy(overview.draft[0.."overview α".len], "overview α");
                        overview.composer.length = "overview α".len;
                        overview.composer.cursor = 3;
                        try overview.session_drafts.put(gpa, "aaaaaa", .{ .bytes = "inactive α", .cursor = 2, .anchor = .{ .position = 7, .end = 9 } });
                        try overview.session_drafts.put(gpa, "bbbbbb", .{ .bytes = "another", .cursor = 0, .rejected = .invalid });
                    }
                    if (conversation) {
                        overview.opened = "cccccc".*;
                        const frontend = try gpa.create(SessionFrontend);
                        frontend.begin(rig.init, "/store", &overview.opened, "/requests", undefined, undefined, undefined, undefined, rig.screen, &cancellation, undefined);
                        if (drafted) frontend.input.restore(.{ .bytes = "open α", .cursor = 2, .anchor = .{ .position = 11, .end = 13 } });
                        overview.app_session = .{ .session = overview.opened, .frontend = frontend, .files = null, .ended = .detached };
                        overview.state.conversing = overview.opened;
                    }
                    var ctx = rig.context();
                    defer ctx.cmds.deinit(gpa);
                    overview.leaveForUpgrade(&ctx, outcome);
                    try std.testing.expectEqual(outcome != .unchanged and !guidance, ctx.quit);
                    // Finishing a guided run later must not be a delayed exec.
                    const request = try overview.finishApp({});
                    try std.testing.expectEqual(outcome != .unchanged and !guidance, request != null);
                    if (request) |value| {
                        defer value.deinit(gpa);
                        try std.testing.expectEqualStrings("/published/build/bin/rui", value.executable);
                        if (outcome == .incompatible) try std.testing.expect(std.mem.indexOf(u8, value.receipt, "This client cannot safely resume Host requests") != null);
                        try std.testing.expectEqual(conversation, value.open != null);
                        var parsed = try handoff.decode(gpa, value.handoff, "/store");
                        defer parsed.deinit();
                        try std.testing.expectEqual(conversation, parsed.value.open != null);
                        if (conversation) try std.testing.expectEqualStrings("cccccc", parsed.value.open.?);
                        try std.testing.expectEqualStrings(if (drafted) "overview α" else "", parsed.value.overview.bytes);
                        try std.testing.expectEqual(@as(usize, if (drafted) 3 else 0), parsed.value.overview.cursor);
                        try std.testing.expectEqual(@as(usize, if (drafted) (if (conversation) 3 else 2) else 0), parsed.value.drafts.len);
                        for (parsed.value.drafts) |entry| {
                            if (std.mem.eql(u8, entry.id, "aaaaaa")) {
                                try std.testing.expectEqualStrings("inactive α", entry.snapshot.bytes);
                                try std.testing.expectEqual(@as(usize, 2), entry.snapshot.cursor);
                                try std.testing.expectEqual(SessionInput.Recalled{ .position = 7, .end = 9 }, entry.snapshot.anchor.?);
                            } else if (std.mem.eql(u8, entry.id, "bbbbbb")) {
                                try std.testing.expectEqualStrings("another", entry.snapshot.bytes);
                                try std.testing.expectEqual(.invalid, entry.snapshot.rejected.?);
                            } else {
                                try std.testing.expectEqualStrings("cccccc", entry.id);
                                try std.testing.expectEqualStrings("open α", entry.snapshot.bytes);
                                try std.testing.expectEqual(SessionInput.Recalled{ .position = 11, .end = 13 }, entry.snapshot.anchor.?);
                            }
                        }
                        try std.testing.expectEqualStrings(ending, parsed.value.line);
                    }
                }
            }
        }
    }
}

test "relaunch startup restores copied drafts open conversation and ending notice exactly once" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview_draft: SessionInput.Snapshot = .{ .bytes = "overview α", .cursor = 3, .rejected = .overflow };
    const chat: SessionInput.Snapshot = .{ .bytes = "chat β", .cursor = 2, .anchor = .{ .position = 7, .end = 9 }, .rejected = .invalid };
    const line = "Upgraded to 0.60.0 · Host restarted";
    const bytes = try handoff.encode(gpa, .{
        .v = 1,
        .store = "/store",
        .open = "bbbbbb",
        .overview = overview_draft,
        .drafts = &.{ .{ .id = "aaaaaa", .snapshot = chat }, .{ .id = "bbbbbb", .snapshot = .{ .bytes = "open draft", .cursor = 1 } } },
        .line = line,
    });
    defer gpa.free(bytes);
    const parsed = try handoff.decode(gpa, bytes, "/store");
    rig.overview.options.restoration = &parsed.value;
    try rig.overview.restoreRelaunch();
    parsed.deinit();
    try std.testing.expectEqualStrings(overview_draft.bytes, rig.overview.composerDraft().bytes);
    try std.testing.expectEqual(overview_draft.cursor, rig.overview.composer.cursor);
    try std.testing.expectEqual(overview_draft.rejected, rig.overview.composer.rejected);
    try std.testing.expectEqualStrings("bbbbbb", &rig.overview.options.open.?);
    try std.testing.expectEqualStrings(line, view.footerNotice(&rig.overview.state).?);
    var status: view.StatusBuffer = undefined;
    try std.testing.expect(view.statusLine(&rig.overview.state, rig.overview.caps, &status) == null);
    for ([_][]const u8{ "aaaaaa", "bbbbbb" }) |id| {
        const draft = rig.overview.session_drafts.take(gpa, id).?;
        defer draft.deinit(gpa);
        if (std.mem.eql(u8, id, "aaaaaa")) {
            try std.testing.expectEqualStrings(chat.bytes, draft.snapshot.bytes);
            try std.testing.expectEqual(chat.cursor, draft.snapshot.cursor);
            try std.testing.expectEqual(chat.anchor, draft.snapshot.anchor);
            try std.testing.expectEqual(chat.rejected, draft.snapshot.rejected);
        } else try std.testing.expectEqualStrings("open draft", draft.snapshot.bytes);
    }
    try rig.overview.restoreRelaunch();
    try std.testing.expect(rig.overview.session_drafts.first == null);
    try std.testing.expect(rig.overview.options.restoration == null);
}

test "App settings Model borrow ends on every Overview menu replacement or release" {
    for ([_]bool{ false, true }) |release| {
        const rig = try openComposer();
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "future-chat\ngpt-5.5\n" } } }}) } }) == null);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.model_choice.active);
        try std.testing.expectEqual(&overview.state.menu, page.model_choice.menu);
        // A failed refresh retains the same immutable list and its choice.
        try std.testing.expect(try overview.event(.{ .models = .unanswered }) == null);
        try std.testing.expect(page.model_choice.active);
        if (release) {
            try std.testing.expect(try overview.event(.leave) == null);
        } else {
            try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\n" } } }}) } }) == null);
        }
        // The next page event validates before using an old index.
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(AppSettings.SaveState.idle, overview.defaults_save);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
    }
}

test "App settings Model keeps every named app binding live while filter text stays local" {
    for (std.enums.values(keymap.Key)) |key| for (key_encodings.get(key)) |bytes| {
        // A lone ESC is deliberately incomplete in the byte fixture.
        if (std.mem.eql(u8, bytes, "\x1b")) continue;
        errdefer std.debug.print("settings Model key={s} bytes={x}\n", .{ @tagName(key), bytes });
        const rig = try openComposer();
        defer rig.close();
        const overview = rig.overview;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.hasChoice());
        const selected = overview.state.selected;
        try app_events.send(&ctx, bytes, overview.root.widget(), page.widget());
        const action = view.keys.get(key);
        try std.testing.expectEqual(action == .exit, ctx.quit);
        try std.testing.expectEqual(selected, overview.state.selected);
        try std.testing.expectEqual(@as(usize, 0), overview.composerDraft().bytes.len);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        // Terminal departure ends the transient edit; every non-exit app
        // binding retains the same filter ownership as before.
        try std.testing.expectEqual(action != .exit and key != .escape and key != .ctrl_g, page.hasChoice());
    };
}

test "App settings Model filters live choices and saves the next Session at both widths" {
    for ([_]u16{ 140, 46 }) |width| for ([_][]const u8{ "codex", "openai" }) |provider| for ([_][]const u8{ "gpt-6-luna", "future-chat" }) |id| {
        errdefer std.debug.print("Model width={d} provider={s} id={s}\n", .{ width, provider, id });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        try pin(home, provider, "gpt-5.5");
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .high }, .permission_mode = .{ .set = .ask } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = provider, .model = "gpt-5.5" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        // Core opening intents share one read; snapshots never enqueue.
        try std.testing.expect((try overview.event(.{ .clicked = .{ .target = .settings } })).? == .open_settings);
        const initial = modelsSnapshot(overview);
        try std.testing.expect(initial.menu == null);
        _ = modelsSnapshot(overview);
        try std.testing.expect((try overview.event(.{ .clicked = .{ .target = .settings } })).? == .open_settings);
        try std.testing.expectEqual(@as(usize, 1), overview.job_count);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.model_lists);
        try std.testing.expect(try overview.event(.{ .clicked = .{ .target = .new_session } }) == null);
        try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{
            .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nfuture-chat\n" } } },
            .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nfuture-chat\n" } } },
        }) } }) == null);
        try std.testing.expect(try rig.press("kept draft") == null);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.model_choice.active);
        try std.testing.expectEqual(&overview.state.menu, page.model_choice.menu);
        try app_events.send(&ctx, id, overview.root.widget(), page.widget());
        var filtered = try rig.shown(width, 24);
        defer filtered.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try filtered.text(), id) != null);
        try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
        try app_events.send(&ctx, "\r", overview.root.widget(), page.widget());
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(AppSettings.SaveState.pending, overview.defaults_save);
        try std.testing.expect(try rig.settle() == null);
        try page.widget().handleEvent(&ctx, .tick);
        const saved = try preferences.load(home);
        try std.testing.expectEqualStrings(id, saved.model.slice());
        try std.testing.expectEqualStrings(provider, saved.provider.slice());
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), saved.reasoning_effort);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), saved.permission_mode);
        try std.testing.expectEqualStrings(id, overview.state.default.?.model.slice());
        try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        try std.testing.expect(!overview.root.input.layer.settingsOpen());
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings("kept draft", Seen.now.start.text.slice());
        try std.testing.expectEqualStrings(id, Seen.now.start.model.?.slice());
        try std.testing.expectEqualStrings(provider, Seen.now.start.provider.?.slice());
    };
}

test "chat info archive status projects only the latest exact Session ledger request" {
    const rig = try openComposer();
    defer rig.close();
    const overview = rig.overview;
    overview.opened = "k7m2qx".*;
    try std.testing.expectEqual(@import("chat_info.zig").SaveState.idle, archiveState(overview));
    overview.state.requests[0] = .{ .kind = .archive, .session = overview.opened, .status = .done };
    overview.state.requests[1] = .{ .kind = .archive, .session = "b4n8wd".*, .status = .pending };
    overview.state.requests[2] = .{ .kind = .stop, .session = overview.opened, .status = .pending };
    overview.state.requests[3] = .{ .kind = .unarchive, .session = overview.opened, .status = .pending };
    overview.state.request_count = 4;
    try std.testing.expectEqual(@import("chat_info.zig").SaveState.saved, archiveState(overview));
    for ([_]@FieldType(view.Request, "status"){ .pending, .done, .failed, .unknown }) |status| {
        overview.state.requests[4] = .{ .kind = .archive, .session = overview.opened, .status = status };
        overview.state.request_count = 5;
        const expected: @import("chat_info.zig").SaveState = switch (status) {
            .pending => .pending,
            .done => .saved,
            .failed, .unknown => .failed,
        };
        try std.testing.expectEqual(expected, archiveState(overview));
    }
}

test "chat info Archive receives its worker answer after the ordinary ledger entry retires" {
    const Archive = struct {
        const Outcome = enum { completed, pending, failed, unknown };
        var outcome: Outcome = .completed;
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn archive(_: *Self, _: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            reply.* = switch (outcome) {
                .completed => .{ .outcome = .accepted },
                .pending => .{ .outcome = .accepted, .archive_pending = true },
                .failed => .refused("archive_refused"),
                .unknown => .unconfirmed("archive-handle"),
            };
        }
    };
    for (std.enums.values(Archive.Outcome)) |outcome| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        Archive.dir = tmp.dir;
        Archive.files = 0;
        Archive.outcome = outcome;
        var ops = fake_operations;
        ops.open = openSession;
        ops.archive = Archive.archive;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Archive.scratch;
        try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
        }
        try std.testing.expect(try rig.settle() == null);
        const frontend = overview.app_session.?.frontend.?;
        // Opening has settled; invoke the panel's wired typed Archive action.
        frontend.reading.opening = false;
        const backend = frontend.app_info.backend;
        _ = try backend.archive(backend.context);
        try std.testing.expectEqual(@import("chat_info.zig").SaveState.pending, backend.state(backend.context));
        try std.testing.expect(try rig.settle() == null);
        const accepted = outcome == .completed or outcome == .pending;
        try std.testing.expectEqual(if (accepted) @import("chat_info.zig").SaveState.saved else .failed, backend.state(backend.context));
        // Definite answers retire; only uncertainty remains in the ledger.
        try std.testing.expectEqual(@as(usize, @intFromBool(outcome == .unknown)), overview.state.request_count);
    }
}

test "chat info Archive backend forwards exact core ledger admission through the real Overview lender" {
    const Files = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    const Held = enum { none, pending, unknown };
    for ([_]bool{ false, true }) |full| for (std.enums.values(Held)) |held| for ([_]view.ArchiveState{ .active, .archiving, .archived }) |archive| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        Files.dir = tmp.dir;
        Files.count = 0;
        var ops = fake_operations;
        ops.open = openSession;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Files.scratch;
        try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
        }
        try std.testing.expect(try rig.settle() == null);
        const frontend = overview.app_session.?.frontend.?;
        frontend.reading.opening = false;
        frontend.line.archive_state = archive;
        if (held != .none) {
            overview.state.requests[0] = .{ .kind = .archive, .session = overview.opened, .status = if (held == .pending) .pending else .unknown };
            overview.state.request_count = 1;
        }
        if (full) while (overview.state.request_count < view.max_requests) {
            overview.state.requests[overview.state.request_count] = .{ .kind = .stop, .session = "other0".*, .status = .unknown };
            overview.state.request_count += 1;
        };
        const before = overview.state.request_count;
        const retained = overview.state.requests;
        const backend = frontend.app_info.backend;
        if (full or held != .none or archive != .active) {
            try std.testing.expectEqual(view.ArchiveAdmission.refused, try backend.archive(backend.context));
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.idle, backend.state(backend.context));
            try std.testing.expectEqual(before, overview.state.request_count);
            try std.testing.expectEqualDeep(retained[0..before], overview.state.requests[0..before]);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
            try std.testing.expectEqual(@as(usize, 0), overview.job_count);
        } else {
            try std.testing.expectEqual(view.ArchiveAdmission.admitted, try backend.archive(backend.context));
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.pending, backend.state(backend.context));
            try std.testing.expect(try rig.settle() == null);
            try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.saved, backend.state(backend.context));
        }
    };
}

test "Overview mouse Settings hover persists across frames and never changes selection or focus" {
    const rig = try openListed();
    defer rig.close();
    var plain = try rig.shown(80, 24);
    defer plain.deinit();
    const row: u16 = for (0..24) |y| {
        if (std.mem.startsWith(u8, try plain.line(@intCast(y)), "  Settings")) break @intCast(y);
    } else return error.TestExpectedSettingsRow;
    const selection = rig.overview.state.selected;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .mouse_enter);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 4, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    var hovered = try rig.shown(80, 24);
    defer hovered.deinit();
    try std.testing.expectEqual(@import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover }).bg, hovered.screen.readCell(4, row).?.style.bg);
    try std.testing.expectEqual(@import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover }).reverse, hovered.screen.readCell(4, row).?.style.reverse);
    try std.testing.expectEqual(selection, rig.overview.state.selected);
    for (ctx.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .mouse_leave);
    var left = try rig.shown(80, 24);
    defer left.deinit();
    try std.testing.expectEqual(plain.screen.readCell(4, row).?.style, left.screen.readCell(4, row).?.style);
    try std.testing.expect(try rig.click(4, row, 80, 24) == null);
    try std.testing.expect(rig.overview.root.input.layer.settingsOpen());
}

test "Overview mouse Palette hover survives redraw and a click follows Enter except during paste" {
    const rig = try openListed();
    defer rig.close();
    try std.testing.expect(try rig.press("/") == null);
    var plain = try rig.shown(80, 24);
    defer plain.deinit();
    const row: u16 = for (0..24) |y| {
        if (std.mem.startsWith(u8, try plain.line(@intCast(y)), "/rename")) break @intCast(y);
    } else return error.TestExpectedPaletteRow;
    const index = for (rig.overview.state.commands.?.list.shown(), 0..) |entry, i| {
        if (std.mem.startsWith(u8, entry.shown, "/rename")) break i;
    } else return error.TestExpectedRenameCommand;
    const highlight = rig.overview.state.commands.?.highlight;
    const selection = rig.overview.state.selected;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const local_row: i16 = @intCast(index - rig.overview.app_palette.first);
    try rig.overview.app_palette.widget().handleEvent(&ctx, .mouse_enter);
    try rig.overview.app_palette.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 4, .row = local_row, .button = .none, .type = .motion, .mods = .{} } });
    var hovered = try rig.shown(80, 24);
    defer hovered.deinit();
    try std.testing.expect(highlight != index);
    try std.testing.expect(!hovered.screen.readCell(4, row).?.style.reverse);
    try std.testing.expectEqual(@import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover }).bg, hovered.screen.readCell(4, row).?.style.bg);
    try std.testing.expect(hovered.screen.readCell(4, row - @as(u16, @intCast(local_row)) + @as(u16, @intCast(highlight - rig.overview.app_palette.first))).?.style.reverse);
    try std.testing.expectEqual(highlight, rig.overview.state.commands.?.highlight);
    try std.testing.expectEqual(selection, rig.overview.state.selected);
    for (ctx.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    try rig.overview.app_palette.widget().handleEvent(&ctx, .mouse_leave);
    var left = try rig.shown(80, 24);
    defer left.deinit();
    try std.testing.expectEqual(plain.screen.readCell(4, row).?.style, left.screen.readCell(4, row).?.style);
    rig.overview.root.input.pasting = true;
    try std.testing.expect(try rig.click(4, row, 80, 24) == null);
    try std.testing.expectEqualStrings("/", rig.overview.composerDraft().bytes);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
    rig.overview.root.input.pasting = false;
    try std.testing.expect(try rig.click(4, row, 80, 24) == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
    try std.testing.expect(std.mem.startsWith(u8, rig.overview.composerDraft().bytes, "/rename"));
}

test "Overview mouse Palette click on a row drawn before the draft changed runs nothing" {
    const rig = try openListed();
    defer rig.close();
    try std.testing.expect(try rig.press("/") == null);
    var shown = try rig.shown(80, 24);
    defer shown.deinit();
    const row: u16 = for (0..24) |y| {
        if (std.mem.startsWith(u8, try shown.line(@intCast(y)), "/archive")) break @intCast(y);
    } else return error.TestExpectedArchiveRow;
    // The same frame, as the widgets a press lands on hold it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frame = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} });
    // `s` arrives before the next frame: `/s` lists /sessions where /archive was.
    try std.testing.expect(try rig.press("s") == null);
    try std.testing.expectEqualStrings("/s", rig.overview.composerDraft().bytes);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try app_events.mouse(&ctx, frame, .{ .col = 1, .row = @intCast(row), .button = .left, .type = .press, .mods = .{} });
    try std.testing.expect(!ctx.quit);
    try std.testing.expectEqualStrings("/s", rig.overview.composerDraft().bytes);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
}

test "Overview mouse New Session forwards blank whitespace task command and paste drafts" {
    for ([_][]const u8{ "", "   ", "a mouse task", "/configure --reasoning-effort high" }) |draft| for ([_]bool{ false, true }) |pasting| {
        const rig = try openListed();
        defer rig.close();
        try std.testing.expect(try rig.press(draft) == null);
        var shown = try rig.shown(80, 24);
        defer shown.deinit();
        const row: u16 = for (0..24) |y| {
            if (std.mem.indexOf(u8, try shown.line(@intCast(y)), "+ New Session") != null) break @intCast(y);
        } else return error.TestExpectedNewRow;
        rig.overview.root.input.pasting = pasting;
        try std.testing.expect(try rig.click(4, row, 80, 24) == null);
        try std.testing.expect(try rig.settle() == null);
        const starts = !pasting and std.mem.eql(u8, draft, "a mouse task");
        try std.testing.expectEqual(@as(usize, if (starts) 1 else 0), Seen.now.starts);
        try std.testing.expectEqual(@as(usize, if (starts) 1 else 0), Seen.now.conversations);
        if (starts) try std.testing.expectEqualStrings(draft, Seen.now.start.text.slice());
        if (!pasting and std.mem.startsWith(u8, draft, "/configure")) {
            try std.testing.expectEqualStrings("", rig.overview.composerDraft().bytes);
            var args: [2 * view.start_options.len][]const u8 = undefined;
            const held = rig.overview.state.settings.args(&args);
            try std.testing.expectEqual(@as(usize, 2), held.len);
            try std.testing.expectEqualStrings("--reasoning-effort", held[0]);
            try std.testing.expectEqualStrings("high", held[1]);
        }
    };
}

test "Overview mouse Palette activates fixed choices and skills through the same Enter policy" {
    for ([_][]const u8{ "/configure --permission-mode ", "use /rec" }) |draft| {
        const keyed = try openListed();
        defer keyed.close();
        try std.testing.expect(try keyed.press(draft) == null);
        try std.testing.expect(try keyed.settle() == null);
        var key_frame = try keyed.shown(80, 24);
        defer key_frame.deinit();
        try std.testing.expect(keyed.overview.state.commands != null);
        const index = keyed.overview.state.commands.?.list.count - 1;
        for (0..index) |_| try std.testing.expect(try keyed.press("\x1b[B") == null);
        try std.testing.expect(try keyed.press("\r") == null);
        const expected = try std.testing.allocator.dupe(u8, keyed.overview.composerDraft().bytes);
        defer std.testing.allocator.free(expected);
        const clicked = try openListed();
        defer clicked.close();
        try std.testing.expect(try clicked.press(draft) == null);
        try std.testing.expect(try clicked.settle() == null);
        var click_frame = try clicked.shown(80, 24);
        defer click_frame.deinit();
        const entry = clicked.overview.state.commands.?.list.entries[index];
        const row: u16 = for (0..24) |y| {
            if (std.mem.startsWith(u8, try click_frame.line(@intCast(y)), entry.shown)) break @intCast(y);
        } else return error.TestExpectedPaletteChoice;
        try std.testing.expect(try clicked.click(1, row, 80, 24) == null);
        try std.testing.expectEqualStrings(expected, clicked.overview.composerDraft().bytes);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    }
}

test "Overview mouse Host start and retry hover preserve foreground selection and focus and click invokes the action" {
    for ([_]bool{ false, true }) |retry| for ([_]view.Caps.Depth{ .none, .direct }) |depth| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = .stopped;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.caps.depth = depth;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        if (retry) {
            HostRecovery.fail_start = true;
            try std.testing.expect(try rig.press("r") == null);
            try std.testing.expect(try rig.settle() == null);
            HostRecovery.fail_start = false;
        }
        const starts = HostRecovery.starts;
        try std.testing.expectEqual(@as(?HostLaunch.Next, if (retry) .retry else .start), overview.hostNext());
        const host_widget = hostNotice(overview).?;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 1 }, .cell_size = .{} };
        const plain = try host_widget.draw(draw_ctx);
        const selected = overview.state.selected;
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try host_widget.handleEvent(&events, .mouse_enter);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
        const hovered = try host_widget.draw(draw_ctx);
        const hover = @import("widget_style.zig").of(overview.caps, .{ .background = .hover });
        for (hovered.buffer, plain.buffer) |cell, before| {
            try std.testing.expectEqual(hover.bg, cell.style.bg);
            try std.testing.expectEqual(hover.ul_style, cell.style.ul_style);
            try std.testing.expectEqual(before.style.fg, cell.style.fg);
        }
        try std.testing.expect(overview.app_host_hover.pointing);
        try std.testing.expectEqual(selected, overview.state.selected);
        try std.testing.expectEqual(starts, HostRecovery.starts);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
        try host_widget.handleEvent(&events, .mouse_leave);
        const left = try host_widget.draw(draw_ctx);
        try std.testing.expectEqual(plain.readCell(2, 0).style, left.readCell(2, 0).style);
        // Clipping removes the target, including from an old widget handle.
        for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 60, .height = 0 } }) |size| {
            _ = try host_widget.draw(draw_ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
            try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
            try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = .left, .type = .press, .mods = .{} } });
            try std.testing.expectEqual(starts, HostRecovery.starts);
        }
        var frame = try rig.shown(80, 24);
        defer frame.deinit();
        const row: u16 = for (0..24) |y| {
            if (std.mem.indexOf(u8, try frame.line(@intCast(y)), "Host stopped") != null) break @intCast(y);
        } else return error.TestExpectedHostLine;
        try std.testing.expect(try rig.click(2, row, 80, 24) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(starts + 1, HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
        try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
    };
}

test "Overview mouse Host line without a start or retry has no hover or click action" {
    const Case = enum { paused, stopping, upgrading, starting, incompatible, store_identity, ready_warning };
    for (std.enums.values(Case)) |case| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = switch (case) {
            .paused => .paused,
            .stopping => .stopping,
            .ready_warning => .ready,
            else => .stopped,
        };
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        switch (case) {
            .upgrading => overview.state.upgrade.after = .blocked,
            .starting => overview.queue(.start_host),
            .incompatible => overview.host_launch = .{ .failed = .{ .kind = .incompatible, .err = error.IncompatibleHost } },
            .store_identity => overview.host_launch = .{ .failed = .{ .kind = .store_identity, .err = error.StoreIdentityMismatch } },
            .ready_warning => overview.host_launch = .{ .ready = .invalid_openai_base_url },
            else => {},
        }
        try std.testing.expectEqual(null, overview.hostNext());
        const host_widget = hostNotice(overview).?;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 1 }, .cell_size = .{} };
        const plain = try host_widget.draw(draw_ctx);
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try host_widget.handleEvent(&events, .mouse_enter);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
        const hovered = try host_widget.draw(draw_ctx);
        try std.testing.expectEqual(plain.readCell(2, 0).style, hovered.readCell(2, 0).style);
        try std.testing.expect(!overview.app_host_hover.pointing);
        try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
        try host_widget.handleEvent(&events, .mouse_leave);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    }
}

test "Overview pinned New Session hover survives unchanged frames without selecting or focusing" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        _ = try rig.press("\x1b[B");
        const selected = rig.overview.state.selected;
        try std.testing.expect(selected == .session);
        var plain = try rig.shown(width, 30);
        defer plain.deinit();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        const pinned = rig.overview.app_new_session.widget();
        const motion: vxfw.Event = .{ .mouse = .{ .col = 4, .row = 0, .button = .none, .type = .motion, .mods = .{} } };
        try pinned.handleEvent(&ctx, .mouse_enter);
        try pinned.handleEvent(&ctx, motion);
        for (0..2) |_| {
            var hovered = try rig.shown(width, 30);
            defer hovered.deinit();
            const style = @import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover });
            try std.testing.expectEqual(style.bg, hovered.screen.readCell(4, 0).?.style.bg);
            try std.testing.expectEqual(style.reverse, hovered.screen.readCell(4, 0).?.style.reverse);
            try std.testing.expect(rig.overview.app_new_session.row.inner.hover.pointing);
            try std.testing.expectEqual(selected, rig.overview.state.selected);
            for (ctx.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
            ctx.cmds.clearRetainingCapacity();
            ctx.redraw = false;
            try pinned.handleEvent(&ctx, motion);
            try std.testing.expect(!ctx.redraw);
            try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        }
        try pinned.handleEvent(&ctx, .mouse_leave);
        var left = try rig.shown(width, 30);
        defer left.deinit();
        try std.testing.expectEqual(plain.screen.readCell(4, 0).?.style, left.screen.readCell(4, 0).?.style);
        try std.testing.expect(!rig.overview.app_new_session.row.inner.hover.pointing);
    }
}
test "App settings Sign-in Enter and click use the Overview owner and return to settings" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |click| for ([_]bool{ false, true }) |busy| {
        errdefer std.debug.print("settings sign-in width={d} click={} busy={}\n", .{ width, click, busy });
        const rig = try openComposer();
        defer rig.close();
        const overview = rig.overview;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try std.testing.expect(page.backend.?.models != null);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        _ = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} });
        if (busy) overview.defaults_save = .pending;
        ctx.cmds.clearRetainingCapacity();
        if (click) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 3, .row = 2 + @backingInt(AppSettings.Row.sign_in), .button = .left, .type = .press, .mods = .{} } });
        } else {
            page.select(.sign_in);
            try app_events.send(&ctx, "\r", overview.root.widget(), page.widget());
        }
        try std.testing.expectEqual(!busy, overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expect(!page.hasChoice());
        if (busy) {
            try std.testing.expectEqualStrings(" · settings busy", page.failures.get(.sign_in).?);
            for (ctx.cmds.items) |command| try std.testing.expect(command != .request_focus);
            continue;
        }
        try std.testing.expect(overview.root.sign_in.?.eql(overview.sign_in.widget()));
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(overview.sign_in.widget()));
        // Defaultless Settings is not first-run: its owner returns here on Esc.
        try std.testing.expect(!overview.signInIsFirstRun());
        try app_events.send(&ctx, "\x1b", overview.root.widget(), overview.sign_in.widget());
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen() and !ctx.quit);
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(page.widget()));
    };
}

test "Sign-in completion applies the core default and restores only a visible focus target" {
    for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |warning| for ([_]bool{ false, true }) |default_failed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .low } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        const session: vxfw.Text = .{ .text = "Retained Session" };
        if (session_open) overview.root.session = session.widget();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        try overview.root.openSignIn(&ctx);
        ctx.cmds.clearRetainingCapacity();
        var activation: SignIn.Activation = .{ .binding = .{}, .store = .{} };
        try activation.binding.provider.set("openai");
        try activation.binding.model.set(@import("product_defaults.zig").recommended_model);
        try activation.store.set("/store");
        activation.default_failed = default_failed;
        if (warning) activation.launch = .{ .outcome = .{ .ready = .{ .facts = .{ .store = activation.store, .instance = @splat(1), .active_capacity = 4, .started_at = 1, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .providers = .{ .codex = .chatgpt_device, .openai = .unserved, .chatgpt = .unserved } } } } }, .warning = .invalid_openai_base_url };
        try signedIn(overview, &ctx, activation);
        if (warning or default_failed) {
            try std.testing.expectEqual(true, overview.state.notice != null);
            const text = overview.state.notice.?.text();
            try std.testing.expectEqual(warning, std.mem.indexOf(u8, text, "OpenAI URL invalid") != null);
            try std.testing.expectEqual(default_failed, std.mem.indexOf(u8, text, if (warning) "default not saved" else "couldn't save default") != null);
            try std.testing.expect(std.mem.indexOfAny(u8, text, "\r\n\x1b") == null);
        }
        try std.testing.expectEqual(protocol.Provider.openai, overview.state.default.?.provider);
        try std.testing.expectEqualStrings(activation.binding.model.slice(), overview.state.default.?.model.slice());
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .low), overview.state.default.?.effort);
        try std.testing.expect(overview.state.login_at != null);
        try std.testing.expect(!overview.root.input.layer.signInOpen() and !overview.root.input.layer.settingsOpen());
        const expected = if (session_open) session.widget() else overview.app_input.composer.widget();
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(expected));
        if (session_open) {
            for (ctx.cmds.items) |command| if (command == .request_focus) {
                try std.testing.expect(command.request_focus.eql(session.widget()));
            };
        }
    };
}

test "Sign-in admission waits for every pending default writer and Host upgrade" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "", .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const Busy = enum { defaults_pending, departed, upgrade_checking, upgrade_reobserving, upgrade_blocked };
    for (std.enums.values(Busy)) |busy| {
        switch (busy) {
            .defaults_pending => overview.defaults_save = .pending,
            .departed => overview.state.left = true,
            .upgrade_checking => overview.state.upgrade = .{ .run = .checking },
            .upgrade_reobserving => overview.state.upgrade = .{ .after = .reobserving },
            .upgrade_blocked => overview.state.upgrade = .{ .after = .blocked },
        }
        try std.testing.expectError(error.DefaultsUnavailable, overview.openSignIn(&ctx));
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        overview.defaults_save = .idle;
        overview.state.left = false;
        overview.state.upgrade = .{};
    }
    try overview.openSignIn(&ctx);
    try std.testing.expect(overview.root.input.layer.signInOpen());
}

test "Sign-in keeps the pane through Session and Settings clicks with and without a Session" {
    const Origin = enum { first_run, settings };
    const Click = enum { session, settings };
    const Nav = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        var opens: usize = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn open(_: *Self, _: *vxfw.EventContext) !void {
            opens += 1;
        }
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
        fn focus(ctx: *vxfw.EventContext) ?vxfw.Widget {
            var i = ctx.cmds.items.len;
            while (i > 0) {
                i -= 1;
                if (ctx.cmds.items[i] == .request_focus) return ctx.cmds.items[i].request_focus;
            }
            return null;
        }
    };
    const Stage = @import("sign_in.zig").Stage;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Nav.dir = tmp.dir;
    for (std.enums.values(Origin)) |from| for ([_]bool{ false, true }) |retained| for ([_]Stage{ .choice, .key_entry }) |stage| for (std.enums.values(Click)) |click| {
        errdefer std.debug.print("sign-in click: from={s} retained={} stage={s} click={s}\n", .{ @tagName(from), retained, @tagName(stage), @tagName(click) });
        Nav.files = 0;
        Nav.opens = 0;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .sign_in = from == .first_run }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        Seen.now.listed = 2;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        defer {
            if (overview.app_session) |left| {
                if (left.frontend) |frontend| frontend.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired_session| overview.disposeSession(retired_session.left);
            overview.retired.deinit(std.testing.allocator);
        }
        if (retained) {
            overview.hooks.scratch = Nav.scratch;
            overview.ops.open = openSession;
            try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
            overview.app_session.?.frontend.?.reading.opening = false;
        }
        overview.ops.open = Nav.open;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        const page = &overview.sign_in;
        // The rig gives no launch hooks; nothing here begins an attempt.
        page.activate = null;
        page.ready = null;
        if (from == .settings) {
            try overview.root.openSettings(&ctx);
            try overview.openSignIn(&ctx);
        }
        try std.testing.expect(overview.root.input.layer.signInOpen());
        const typed = "sk-typed-before-click";
        if (stage == .key_entry) try app_events.send(&ctx, "\x1b[C\r" ++ typed, overview.root.widget(), page.widget());
        try std.testing.expectEqual(stage, page.state.stage);
        const session = overview.root.session;
        const frontend = if (overview.app_session) |held| held.frontend else null;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
        try std.testing.expect(overview.root.listVisible());
        const at: vxfw.RelativePoint = switch (click) {
            .session => session: {
                const list = Nav.origin(frame, overview.app_sessions.widget(), .{ .row = 0, .col = 0 }).?;
                const row = for (overview.app_sessions.shown_at) |span| {
                    if (span.target) |target| if (target == .open and std.mem.eql(u8, &target.open, "b4n8wd")) break span.row;
                } else return error.TestMissingSessionHit;
                break :session .{ .row = list.row + row, .col = 4 };
            },
            .settings => .{ .row = 39, .col = 4 },
        };
        ctx.cmds.clearRetainingCapacity();
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| {
            try app_events.mouse(&ctx, frame, .{ .col = @intCast(at.col), .row = @intCast(at.row), .button = .left, .type = kind, .mods = .{} });
        }
        try std.testing.expect(!ctx.quit);
        try std.testing.expect(overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(from == .settings, overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(session != null, overview.root.session != null);
        if (session) |kept| try std.testing.expect(overview.root.session.?.eql(kept));
        if (frontend) |held| try std.testing.expect(overview.app_session.?.frontend.? == held);
        try std.testing.expectEqual(@as(usize, 0), Nav.opens);
        try std.testing.expectEqual(stage, page.state.stage);
        try std.testing.expectEqualStrings(if (stage == .key_entry) typed else "", page.key.slice());
        for (ctx.cmds.items) |command| if (command == .request_focus) {
            try std.testing.expect(command.request_focus.eql(page.widget()));
        };
        // The page names the app on its top row only when the list is hidden,
        // as it was when Root set the page's title from its width.
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 40);
            defer shown.deinit();
            const top = try shown.line(0);
            errdefer std.debug.print("top row at {d}: '{s}'\n", .{ width, top });
            try std.testing.expectEqual(@as(usize, @intFromBool(width < Root.split_at)), std.mem.count(u8, top, "rui"));
        }
        // Esc leaves as before: from the key back to the choice, then out.
        ctx.cmds.clearRetainingCapacity();
        try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        if (stage == .key_entry) {
            try std.testing.expect(overview.root.input.layer.signInOpen());
            try std.testing.expectEqual(Stage.choice, page.state.stage);
            try std.testing.expectEqual(@as(usize, 0), page.key.len);
            try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        }
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(from == .settings, overview.root.input.layer.settingsOpen());
        const back = if (from == .settings) overview.root.settings_page.widget() else overview.root.session orelse overview.widget();
        try std.testing.expect(Nav.focus(&ctx).?.eql(back));
    };
}

test "Sign-in Esc at the choice leaves unless the first-run screen has no default, and only that screen holds the overview's tick" {
    const Origin = enum { first_run, settings };
    const Nav = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn focus(ctx: *vxfw.EventContext) ?vxfw.Widget {
            var i = ctx.cmds.items.len;
            while (i > 0) {
                i -= 1;
                if (ctx.cmds.items[i] == .request_focus) return ctx.cmds.items[i].request_focus;
            }
            return null;
        }
        fn titled(ctx: *vxfw.EventContext) bool {
            for (ctx.cmds.items) |command| if (command == .set_title) return true;
            return false;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Nav.dir = tmp.dir;
    for (std.enums.values(Origin)) |from| for ([_]bool{ false, true }) |default| for ([_]bool{ false, true }) |retained| {
        errdefer std.debug.print("sign-in escape: from={s} default={} retained={}\n", .{ @tagName(from), default, retained });
        Nav.files = 0;
        var cancellation: client.Cancellation = .{};
        // A resumed Session with unreadable saved defaults has no default
        // and reaches sign-in only from Settings.
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = if (default) "codex" else null, .model = if (default) "gpt-6-luna" else null, .sign_in = from == .first_run }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expectEqual(default, overview.state.default != null);
        Seen.now.listed = 2;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        defer {
            if (overview.app_session) |left| {
                if (left.frontend) |frontend| frontend.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired_session| overview.disposeSession(retired_session.left);
            overview.retired.deinit(std.testing.allocator);
        }
        if (retained) {
            overview.hooks.scratch = Nav.scratch;
            overview.ops.open = openSession;
            try std.testing.expect(try rig.next(.{ .open = "k7m2qx".* }) == null);
            overview.app_session.?.frontend.?.reading.opening = false;
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const page = &overview.sign_in;
        // The rig gives no launch hooks; nothing here begins an attempt.
        page.activate = null;
        page.ready = null;
        if (from == .settings) {
            try overview.root.openSettings(&ctx);
            try overview.openSignIn(&ctx);
        }
        try std.testing.expect(overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(@import("sign_in.zig").Stage.choice, page.state.stage);
        const stays = from == .first_run and !default;
        // Only the first-run screen with no default holds the overview's
        // tick; under any other sign-in the overview and Session are served.
        ctx.cmds.clearRetainingCapacity();
        try appEvent(overview, &ctx, .tick);
        try std.testing.expectEqual(!stays, Nav.titled(&ctx));
        ctx.cmds.clearRetainingCapacity();
        try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        try std.testing.expect(!ctx.quit);
        try std.testing.expectEqual(stays, overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(from == .settings, overview.root.input.layer.settingsOpen());
        if (stays) {
            try std.testing.expect(Nav.focus(&ctx) == null);
            continue;
        }
        const back = if (from == .settings) overview.root.settings_page.widget() else overview.root.session orelse overview.widget();
        try std.testing.expect(Nav.focus(&ctx).?.eql(back));
        try std.testing.expectEqual(retained, overview.root.session != null);
    };
}

test "Overview footer choices preserve draft and save defaults through Settings owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6.1-sol" }, .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const page = &overview.root.settings_page;
    try std.testing.expect(try rig.press("kept draft") == null);
    // Legacy and Kitty encodings of reverse Tab preserve the draft; Enter chooses
    // a field instead of submitting the draft.
    for ([_][]const u8{ "\x1b[Z", "\x1b[9;2;9u", "\x1b[9:9;2u" }) |reverse_tab| {
        try std.testing.expect(try rig.press("\t") == null);
        try std.testing.expectEqual(view.FooterFocus.model, overview.state.footer.focus);
        try std.testing.expect(try rig.press(reverse_tab) == null);
        try std.testing.expectEqual(view.FooterFocus.input, overview.state.footer.focus);
    }
    try std.testing.expect(try rig.press("\t\t\r") == null);
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expect(try rig.press("ignored\x1b[200~pasted\ttext\x1b[201~") == null);
    try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    try std.testing.expect(try rig.press("\x1b[B\r") == null);
    try std.testing.expectEqual(AppSettings.SaveState.pending, overview.defaults_save);
    try std.testing.expect(!page.standaloneOpen());
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), overview.state.default.?.effort);
    try std.testing.expect(try rig.settle() == null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .xhigh), overview.state.default.?.effort);
    try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
    try overview.root.openSettings(&ctx);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .xhigh), page.values.reasoning_effort);
    try overview.root.showMain(&ctx);
    // A model pick takes the identical defaults writer, not a footer-only
    // assignment; filtering never edits the task's draft.
    try std.testing.expect(try rig.press("\t\r") == null);
    try std.testing.expect(!page.standaloneOpen());
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expect(try rig.press("gpt-5.5\r") == null);
    try std.testing.expectEqual(AppSettings.SaveState.pending, overview.defaults_save);
    try std.testing.expectEqualStrings("gpt-6.1-sol", overview.state.default.?.model.slice());
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings("gpt-5.5", overview.state.default.?.model.slice());
    try overview.root.openSettings(&ctx);
    try std.testing.expectEqualStrings("gpt-5.5", page.values.model.slice());
    var settings = try rig.shown(140, 40);
    defer settings.deinit();
    var visible_model = false;
    for (0..settings.screen.height) |row| {
        const text = try settings.line(@intCast(row));
        if (std.mem.indexOf(u8, text, "Model") != null and std.mem.indexOf(u8, text, "gpt-5.5") != null) visible_model = true;
    }
    try std.testing.expect(visible_model);
    try std.testing.expectEqualStrings("gpt-5.5", (try preferences.load(home)).model.slice());
    try overview.root.showMain(&ctx);
    try std.testing.expect(try rig.press("\t\r\x1b") == null);
    try std.testing.expect(!page.standaloneOpen());
    try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
    // Printable input leaves button focus and reaches the editor; marked
    // paste, including its tab, retains its existing path.
    try std.testing.expect(try rig.press("\tx\t\x1b[200~a\tb\x1b[201~") == null);
    try std.testing.expectEqual(view.FooterFocus.input, overview.state.footer.focus);
    try std.testing.expectEqualStrings("kept draftxa\tb", overview.composerDraft().bytes);
}

test "Overview footer drawn model and effort cells click and underline at both widths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6.1-sol" }, .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    for ([_]u16{ 46, 140 }) |width| {
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try appFooterDraw(overview, draw);
        try std.testing.expectEqual(@as(usize, 2), footer.children.len);
        for (footer.children, [_]view.FooterField{ .model, .effort }) |child, field| {
            const chip = if (field == .model) &overview.app_model else &overview.app_effort;
            try chip.widget().handleEvent(&ctx, .mouse_enter);
            const hovered = try chip.widget().draw(draw);
            try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.readCell(0, 0).style.ul_style);
            try chip.widget().handleEvent(&ctx, .mouse_leave);
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, footer, .{ .row = 0, .col = @intCast(child.origin.col), .button = .left, .mods = .{}, .type = kind });
            try std.testing.expect(try rig.settle() == null);
            try std.testing.expect(overview.root.settings_page.standaloneOpen());
            try std.testing.expectEqual(if (field == .model) AppSettings.Row.model else AppSettings.Row.effort, overview.root.settings_page.standaloneField().?);
            overview.root.settings_page.closeStandaloneChoice();
        }
        overview.state.footer.focus = .model;
        const selected = try appFooterDraw(overview, draw);
        try std.testing.expect(selected.children[0].surface.readCell(0, 0).style.reverse);
        try app_events.mouse(&ctx, selected, .{ .row = 0, .col = 0, .button = .left, .mods = .{}, .type = .press });
        // Direct footer drawing has no screen ancestor, so exercise the
        // screen's background route for a click with no button identity.
        try overview.widget().handleEvent(&ctx, .{ .mouse = .{ .row = 0, .col = 0, .button = .left, .mods = .{}, .type = .press } });
        try std.testing.expectEqual(view.FooterFocus.input, overview.state.footer.focus);
        try std.testing.expect(!overview.root.settings_page.standaloneOpen());
    }
}

test "Overview footer text table covers default explicit effort ask bypass and both widths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    for ([_]protocol.PermissionMode{ .ask, .bypass }) |permission| for ([_]?model_capability.ReasoningEffort{ null, .xhigh }) |effort| {
        _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6.1-sol" }, .reasoning_effort = if (effort) |value| .{ .set = value } else .clear, .permission_mode = .{ .set = permission } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/code/a-very-long-project-name", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
        defer rig.close();
        for ([_]u16{ 140, 46 }) |width| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const footer = try appFooterDraw(rig.overview, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
            var text: std.Io.Writer.Allocating = .init(arena.allocator());
            for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
            const right_at = std.mem.indexOf(u8, text.written(), "enter start").?;
            const left = std.mem.trimEnd(u8, text.written()[0..right_at], " ");
            const expected = try std.fmt.allocPrint(arena.allocator(), " gpt-6.1-sol · {s}{s}", .{ if (effort) |value| @tagName(value) else product_defaults.reasoning_effort, if (width == 140) " · /code/a-very-long-project-name" else "" });
            try std.testing.expectEqualStrings(expected, left);
            // Permissions are chat facts, never new-chat/defaults facts.
            try std.testing.expect(std.mem.indexOf(u8, text.written(), " · ask") == null);
            try std.testing.expect(std.mem.endsWith(u8, text.written(), "enter start"));
        }
    };
}

test "Overview footer routing preserves global exit and draft during frozen starts" {
    for ([_][]const u8{ "\x03", "\x04" }) |exit_key| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("start a task\r") == null);
        try std.testing.expectEqual(view.InputMode.frozen, rig.overview.state.inputMode());
        const draft = try std.testing.allocator.dupe(u8, rig.overview.composerDraft().bytes);
        defer std.testing.allocator.free(draft);
        try std.testing.expect(try rig.press("\t\x1b[Znot inserted") == null);
        try std.testing.expectEqualStrings(draft, rig.overview.composerDraft().bytes);
        try std.testing.expectEqual(view.FooterFocus.input, rig.overview.state.footer.focus);
        try std.testing.expect((try rig.press(exit_key)).? == .overview);
    }
}

test "Overview footer unpinned effort and model picks refresh defaults and the next start" {
    for ([_]view.FooterField{ .effort, .model }) |field| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        const page = &overview.root.settings_page;
        const before = try preferences.load(home);
        try std.testing.expect(before.provider.len == 0 and before.model.len == 0);
        try std.testing.expect(try rig.press("kept draft") == null);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try appClick(overview, &ctx, .{ .footer = field });
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(page.standaloneOpen());
        if (field == .model) {
            try std.testing.expect(try rig.press("gpt-5.5\r") == null);
        } else {
            for (0..page.panel.choice.?.labels.len) |_| {
                if (std.mem.eql(u8, page.panel.choice.?.labels[page.panel.choice.?.selected], "xhigh")) break;
                try std.testing.expect(try rig.press("\x1b[B") == null);
            }
            try std.testing.expectEqualStrings("xhigh", page.panel.choice.?.labels[page.panel.choice.?.selected]);
            try std.testing.expect(try rig.press("\r") == null);
        }
        try std.testing.expectEqual(AppSettings.SaveState.pending, overview.defaults_save);
        try std.testing.expect(!page.standaloneOpen());
        try std.testing.expectEqualStrings("gpt-6.1-sol", overview.state.default.?.model.slice());
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, null), overview.state.default.?.effort);
        try std.testing.expect(try rig.settle() == null);
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(AppSettings.SaveState.saved, overview.defaults_save);
        const saved = try preferences.load(home);
        const model = if (field == .model) "gpt-5.5" else "gpt-6.1-sol";
        const effort: ?model_capability.ReasoningEffort = if (field == .effort) .xhigh else null;
        try std.testing.expectEqualStrings(model, overview.state.nextBinding().model.?);
        try std.testing.expectEqual(effort, overview.state.default.?.effort);
        try std.testing.expectEqual(effort, saved.reasoning_effort);
        if (field == .effort) try std.testing.expect(saved.provider.len == 0 and saved.model.len == 0) else {
            try std.testing.expectEqualStrings("codex", saved.provider.slice());
            try std.testing.expectEqualStrings(model, saved.model.slice());
        }
        try overview.root.openSettings(&ctx);
        try std.testing.expectEqual(effort, page.values.reasoning_effort);
        try std.testing.expectEqualStrings(saved.model.slice(), page.values.model.slice());
        try overview.root.showMain(&ctx);
        try std.testing.expectEqualStrings("kept draft", overview.composerDraft().bytes);
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings(model, Seen.now.start.model.?.slice());
        try std.testing.expectEqualStrings(if (field == .effort) "xhigh" else product_defaults.reasoning_effort, Seen.now.start.reasoning_effort.?.slice());
        try std.testing.expectEqualStrings("kept draft", Seen.now.start.text.slice());
    }
}

test "Overview saved defaults projection covers unpinned picks selectors and held overrides" {
    const Case = struct {
        current: ?protocol.Provider = .codex,
        current_model: []const u8 = "gpt-6.1-sol",
        intent: new_session_selection.Intent = .{},
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        effort: ?model_capability.ReasoningEffort = .xhigh,
        expected: ?protocol.Provider = .codex,
        expected_model: []const u8 = "gpt-6.1-sol",
    };
    const cases = [_]Case{
        .{}, // No saved pin: the effort is still a confirmed default.
        .{ .effort = null },
        .{ .provider = "codex", .model = "gpt-5.5", .expected_model = "gpt-5.5" },
        .{ .provider = "openai", .model = "gpt-5.5", .expected = .openai, .expected_model = "gpt-5.5" },
        .{ .intent = .{ .provider = "codex" }, .provider = "openai", .model = "gpt-5.5" },
        .{ .intent = .{ .model = "gpt-6-sol" }, .provider = "codex", .model = "gpt-5.5", .expected_model = "gpt-6-sol" },
        .{ .intent = .{ .provider = "openai" }, .expected = .openai },
        .{ .intent = .{ .store = "/s", .provider = "codex", .model = "gpt-6-sol" }, .expected = null },
        .{ .current = .openai, .expected = .openai }, // A later sign-in owns the committed provider.
        .{ .current = null, .expected = null }, // No first-run authority is invented.
        .{ .current = null, .provider = "codex", .model = "gpt-5.5", .expected_model = "gpt-5.5" },
        .{ .provider = "missing-provider", .expected = null },
        .{ .provider = "codex", .model = "bad model", .expected = null },
        .{ .current_model = "gpt-5.5", .provider = "codex" }, // Clear model goes back to the recommendation.
    };
    for (cases) |case| for ([_]bool{ false, true }) |held| {
        var state: view.State = undefined;
        try state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer state.deinit();
        state.default = if (case.current) |provider| view.Default.of(@tagName(provider), case.current_model) else null;
        if (state.default) |*binding| binding.effort = .low;
        const before = state.default;
        if (held) _ = try view.step(&state, .{ .composed = .{ .input = .{ .composer = .submit }, .draft = .{ .bytes = "/configure --provider openai --model gpt-6-sol --reasoning-effort medium" } } });
        var snapshot: new_session_selection.Snapshot = .{ .intent = case.intent, .defaults = .{ .reasoning_effort = case.effort } };
        if (case.provider) |provider| try snapshot.defaults.provider.set(provider);
        if (case.model) |model| try snapshot.defaults.model.set(model);
        const refreshed = resolveDefault(&state, snapshot);
        try std.testing.expectEqual(case.expected != null, refreshed != null);
        if (case.expected) |provider| {
            try std.testing.expectEqual(provider, refreshed.?.provider);
            try std.testing.expectEqualStrings(case.expected_model, refreshed.?.model.slice());
            try std.testing.expectEqual(case.effort, refreshed.?.effort);
        }
        try std.testing.expectEqual(@as(usize, 0), (try view.step(&state, .{ .defaults_saved = refreshed })).len);
        const expected = refreshed orelse before;
        if (expected) |binding| {
            try std.testing.expect(binding.eql(&state.default.?));
            const next = state.nextBinding();
            try std.testing.expectEqualStrings(if (held) "openai" else @tagName(binding.provider), next.provider.?);
            try std.testing.expectEqualStrings(if (held) "gpt-6-sol" else binding.model.slice(), next.model.?);
            const effort = (view.StartEffort{ .held = if (held) "medium" else null, .model = next.model }).shown(binding.effort);
            try std.testing.expectEqual(if (held) @as(?model_capability.ReasoningEffort, .medium) else binding.effort orelse .low, effort);
        } else {
            try std.testing.expect(state.default == null);
            if (!held) try std.testing.expect(state.nextBinding().provider == null);
        }
        // The fallback enriched only a local value, never launch intent or
        // persisted pins, and never used a Configure-held provider/model.
        try std.testing.expectEqual(case.intent.provider, snapshot.intent.provider);
        try std.testing.expectEqualStrings(case.provider orelse "", snapshot.defaults.provider.slice());
    };
}

test "Overview footer effort matches submitted creation for catalog saved and held policies" {
    const Effort = model_capability.ReasoningEffort;
    const Case = struct { model: []const u8, supported: ?Effort, unsupported: Effort };
    const cases = [_]Case{
        .{ .model = "openai/whisper-1", .supported = null, .unsupported = .high },
        .{ .model = "gpt-5.5", .supported = .high, .unsupported = .max },
        .{ .model = "azure/gpt-5-pro", .supported = .high, .unsupported = .low },
    };
    for (cases) |case| for ([_]?Effort{ null, case.supported, case.unsupported }) |saved| for ([_]?[]const u8{ null, "high", "max", "default" }) |held| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        _ = try preferences.update(home, .{
            .provider = .{ .set = "openai" },
            .model = .{ .set = case.model },
            .reasoning_effort = if (saved) |value| .{ .set = value } else .clear,
        }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "openai", .model = case.model }, fake_operations, &cancellation);
        defer rig.close();
        if (held) |value| {
            var command: [80]u8 = undefined;
            try std.testing.expect(try rig.press(try std.fmt.bufPrint(&command, "/configure --reasoning-effort {s}\r", .{value})) == null);
        }
        const shown = rig.overview.state.nextEffort();
        try std.testing.expect(try rig.press("same effort\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
        try std.testing.expectEqualStrings(if (shown) |value| @tagName(value) else "", Seen.now.start.reasoning_effort.?.slice());
        try std.testing.expectEqualStrings(case.model, Seen.now.start.model.?.slice());
        try std.testing.expectEqualStrings("openai", Seen.now.start.provider.?.slice());
    };
}

test "Overview footer standalone choices receive the held creation binding and effort" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-5.5" }, .reasoning_effort = .{ .set = .low } }, &.initFill(.configured));
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const page = &overview.root.settings_page;
    try std.testing.expect(try rig.press("/configure --provider openai --model azure/gpt-5-pro --reasoning-effort default\r") == null);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), overview.state.nextEffort());
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appClick(overview, &ctx, .{ .footer = .effort });
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expectEqual(@as(usize, 2), page.effort_count);
    try std.testing.expectEqualStrings("model default", page.effort_choices[0]);
    try std.testing.expectEqualStrings("high", page.effort_choices[1]);
    try std.testing.expectEqual(@as(?usize, 1), page.panel.choice.?.current);
    try std.testing.expect(try rig.press("\x1b") == null);
    try appClick(overview, &ctx, .{ .footer = .model });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expectEqual(protocol.Provider.openai, page.model_choice.provider);
    try std.testing.expectEqualStrings("azure/gpt-5-pro", page.model_choice.current);
    try std.testing.expect(try rig.press("gpt-5.5\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    const saved = try preferences.load(home);
    try std.testing.expectEqualStrings("openai", saved.provider.slice());
    try std.testing.expectEqualStrings("gpt-5.5", saved.model.slice());
    // Saving defaults never overwrites an independently held binding.
    try std.testing.expectEqualStrings("azure/gpt-5-pro", overview.state.nextBinding().model.?);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), overview.state.nextEffort());
}

test "Overview standalone footer close clicks match Escape preserve paste and preserve admitted saves" {
    const Rejected = struct {
        fn save(_: *anyopaque, _: preferences.Edit) !void {
            return error.AccessDenied;
        }
    };
    for ([_]u16{ 140, 46 }) |width| for ([_]AppSettings.Row{ .model, .effort }) |row| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
        defer rig.close();
        const self = rig.overview;
        const page = &self.root.settings_page;
        try std.testing.expect(try rig.press("kept draft\x1b[D") == null);
        const draft = self.composerDraft();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        for ([_]bool{ false, true }) |retained_failure| {
            try page.openStandaloneChoice(&ctx, row, self.state.nextStart());
            if (retained_failure) {
                const save = page.backend.?.save;
                page.backend.?.save = Rejected.save;
                try page.standaloneWidget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
                page.backend.?.save = save;
            }
            const footer = try appFooterDraw(self, draw);
            var text: std.Io.Writer.Allocating = .init(arena.allocator());
            for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
            try std.testing.expect(std.mem.endsWith(u8, text.written(), if (retained_failure) "enter retry · esc close" else "enter pick · esc close"));
            const close = for (footer.children) |child| {
                if (child.surface.widget.eql(self.app_choice_close.widget())) break child;
            } else return error.TestExpectedCloseTarget;
            try std.testing.expectEqual(@as(u16, 9), close.surface.size.width);
            try std.testing.expect(close.origin.col + close.surface.size.width <= width);
            self.root.input.pasting = true;
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, footer, .{ .row = 0, .col = @intCast(close.origin.col), .button = .left, .mods = .{}, .type = kind });
            try std.testing.expect(page.standaloneOpen());
            self.root.input.pasting = false;
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, footer, .{ .row = 0, .col = @intCast(close.origin.col), .button = .left, .mods = .{}, .type = kind });
            try std.testing.expect(!page.standaloneOpen());
            try std.testing.expectEqual(view.FooterFocus.input, self.state.footer.focus);
            try std.testing.expectEqualStrings(draft.bytes, self.composerDraft().bytes);
            try std.testing.expectEqual(draft.cursor, self.composerDraft().cursor);
            try std.testing.expect(page.saving_row == null);
            // The keyboard closes the same presentation, preserving the same draft.
            try page.openStandaloneChoice(&ctx, row, self.state.nextStart());
            try std.testing.expect(try rig.press("\x1b") == null);
            try std.testing.expect(!page.standaloneOpen());
            try std.testing.expectEqualStrings(draft.bytes, self.composerDraft().bytes);
        }
        try page.openStandaloneChoice(&ctx, row, self.state.nextStart());
        const stale_footer = try appFooterDraw(self, draw);
        const close = for (stale_footer.children) |child| {
            if (child.surface.widget.eql(self.app_choice_close.widget())) break child;
        } else return error.TestExpectedCloseTarget;
        const pick = for (stale_footer.children) |child| {
            if (child.surface.widget.eql(self.app_choice_pick.widget())) break child;
        } else return error.TestExpectedPickTarget;
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, stale_footer, .{ .row = 0, .col = @intCast(pick.origin.col), .button = .left, .mods = .{}, .type = kind });
        try std.testing.expect(!page.standaloneOpen());
        try std.testing.expectEqual(@as(?AppSettings.Row, row), page.saving_row);
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, stale_footer, .{ .row = 0, .col = @intCast(close.origin.col), .button = .left, .mods = .{}, .type = kind });
        try std.testing.expect(page.standaloneField() == null);
        try std.testing.expectEqual(@as(?AppSettings.Row, row), page.saving_row);
        try std.testing.expectEqualStrings(draft.bytes, self.composerDraft().bytes);
        try std.testing.expectEqual(draft.cursor, self.composerDraft().cursor);
    };
}

test "Overview standalone lifetime shared domain closes every phase through real screen endings" {
    const Cases = @import("session_chrome.zig").StandaloneCases;
    const Fault = struct {
        fn read(_: *anyopaque) !preferences.Values {
            return error.AccessDenied;
        }
        fn save(_: *anyopaque, _: preferences.Edit) !void {
            return error.AccessDenied;
        }
    };
    for (Cases.all) |case| {
        if (case.screen != .new_chat) continue;
        errdefer std.debug.print("Overview lifecycle {s}/{s}/{s}\n", .{ @tagName(case.field), @tagName(case.phase), @tagName(case.ending) });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
        defer rig.close();
        const self = rig.overview;
        const page = &self.root.settings_page;
        const row: AppSettings.Row = if (case.field == .model) .model else .effort;
        try std.testing.expect(try rig.press("kept draft") == null);
        const cursor = self.composerDraft().cursor;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        if (case.phase == .read_failed) page.backend.?.read = Fault.read;
        if (case.phase == .save_failed) page.backend.?.save = Fault.save;
        try page.openStandaloneChoice(&ctx, row, self.state.nextStart());
        // Retain the actual drawn close target before admission hides pending.
        const footer = try appFooterDraw(self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
        const close = for (footer.children) |child| {
            if (child.surface.widget.eql(self.app_choice_close.widget())) break child;
        } else return error.TestExpectedCloseTarget;
        if (case.phase == .pending or case.phase == .save_failed) try page.standaloneWidget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expectEqual(@as(?AppSettings.Row, row), page.standaloneField());
        try std.testing.expectEqual(case.phase == .pending, page.saving_row != null);
        try std.testing.expectEqual(case.phase != .pending, page.standaloneOpen());
        switch (case.ending) {
            .escape => try std.testing.expect(try rig.press("\x1b") == null),
            .close_click => for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, footer, .{ .row = 0, .col = @intCast(close.origin.col), .button = .left, .mods = .{}, .type = kind }),
            .navigate => {
                const session: vxfw.Text = .{ .text = "Session" };
                try self.root.openSession(&ctx, session.widget());
                try std.testing.expect(!page.standaloneOpen() and page.standaloneField() == null);
                try self.root.closeSession(&ctx);
            },
            .refresh => try page.refresh(),
        }
        try std.testing.expect(!page.standaloneOpen());
        try std.testing.expect(page.standaloneField() == null);
        try std.testing.expectEqualStrings("kept draft", self.composerDraft().bytes);
        try std.testing.expectEqual(cursor, self.composerDraft().cursor);
        if (case.phase == .pending) {
            try std.testing.expectEqual(@as(?AppSettings.Row, row), page.saving_row);
            self.defaults_save = .failed;
            try page.widget().handleEvent(&ctx, .tick);
            try std.testing.expect(page.saving_row == null);
            try std.testing.expect(!page.standaloneOpen() and page.standaloneField() == null);
        }
        try std.testing.expect(try rig.press("!") == null);
        try std.testing.expectEqualStrings("kept draft!", self.composerDraft().bytes);
        try std.testing.expectEqual(cursor + 1, self.composerDraft().cursor);
    }
}

test "Overview settings and admitted sign-in navigation end deferred footer intent" {
    const rig = try openComposer();
    defer rig.close();
    const self = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expect(try rig.press("kept draft") == null);
    self.state.footer.pending = .model;
    try self.root.openSettings(&ctx);
    try std.testing.expect(self.state.footer.pending == null);
    try self.root.showMain(&ctx);
    try self.root.settings_page.openStandaloneChoice(&ctx, .effort, self.state.nextStart());
    self.state.footer.pending = .model;
    try self.openSignIn(&ctx);
    try std.testing.expect(self.root.input.layer.signInOpen());
    try std.testing.expect(self.root.settings_page.standaloneField() == null);
    try std.testing.expect(self.state.footer.pending == null);
    try std.testing.expectEqualStrings("kept draft", self.composerDraft().bytes);
}
