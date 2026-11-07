//! The Session overview's shell: bare `rui`, and `rui session resume` around
//! the Session it opens.
//!
//! It owns the terminal and one loop. Keys, ticks at `State.wakeAt` and the
//! worker's replies enter `overview_view.step` as events; the loop runs the
//! effects `step` returns and paints `OverviewPaint.draw` into the shared backend.
//! It branches only
//! on which effect to run, so every screen decision stays in the core. One
//! worker runs the client requests in order, so one list read is in flight
//! at a time, and the core only ever hears list replies for the listing it
//! asked for. An opened Session borrows the terminal through
//! `SessionFrontend`, with ticks paused, and gives it back on Esc.
const std = @import("std");
const vaxis = @import("vaxis");
const client = @import("client.zig");
const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const model_list = @import("model_list.zig");
const model_picker = @import("model_picker.zig");
const stderr = @import("stderr.zig");
const test_poll = @import("test_poll");
const view = @import("overview_view.zig");
const OverviewPaint = @import("OverviewPaint.zig");
const ClientTask = @import("ClientTask.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const session_reads = @import("session_reads.zig");
const SessionInput = @import("SessionInput.zig");
const SessionScreen = @import("SessionScreen.zig");
const RenderBackend = @import("RenderBackend.zig");
const SessionTerminal = @import("SessionTerminal.zig");
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalInput = @import("TerminalInput.zig");
const TerminalText = @import("TerminalText.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const new_session_selection = @import("new_session_selection.zig");
const preferences = @import("preferences.zig");

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
    /// The launch's own `--store`, `--provider` and `--model`, as given.
    /// When it named all three, a start reads no saved defaults, the saved
    /// effort included. Otherwise a `/setup` that ran re-resolves the
    /// default from them and the saved defaults, as a fresh launch would.
    selectors: new_session_selection.Intent = .{},
    /// A Session to open first, as `session resume` names it.
    open: ?view.Reference = null,
};

/// What the CLI lends the overview and its conversations: scratch files and
/// the slash commands both run.
pub const Hooks = struct {
    scratch: *const fn (std.process.Init) anyerror!std.Io.File,
    command: SessionFrontend.Command,
    requests: SessionFrontend.Requests,
    status: SessionFrontend.Status,
    /// Runs between a start's capture and its send, as the CLI's other
    /// captures do.
    captured: *const fn (std.Io) anyerror!void,
};

/// The client operations the effects run. The worker runs all but
/// `converse`, each with its own cancellable requests; the loop runs
/// `converse`. Each returns what the Host answered, failures included, and
/// an error when there was no answer. Tests substitute their own.
pub const Operations = struct {
    /// host-info's facts, or null when the Host gives none.
    host: *const fn (*Self) ?view.Host,
    /// Whether no Host owns the Store: it stopped, rather than failing to
    /// answer discovery.
    stopped: *const fn (*Self) bool,
    /// Reads one `session list` page into `page`, or returns the Host's
    /// failure.
    list: *const fn (*Self, client.Requests, protocol_reply.SessionListCursor, *protocol_reply.SessionListPage) anyerror!?protocol_reply.ReadFailure,
    /// The first line of a Session's first Message, read into `buffer`.
    first_line: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!protocol_reply.ActivityPrefixReply,
    /// Write the request's fate into the Reply, and return the error that
    /// ends the overview after a canonical Store failure.
    start: *const fn (*Self, client.Requests, client.MessageInput, *Reply) anyerror!void,
    stop: *const fn (*Self, client.Requests, client.SessionStopInput, *Reply) anyerror!void,
    archive: *const fn (*Self, client.Requests, client.SessionArchiveInput, *Reply) anyerror!void,
    /// The Host's `model_list` reply, owned by the allocator.
    models: *const fn (*Self, client.Requests, std.mem.Allocator) anyerror![]u8,
    /// Saves the person's default for new Sessions.
    save_default: *const fn (*Self, view.Default) anyerror!void,
    /// Runs a command line for a Session, or for none when it is empty,
    /// keeping what it printed in `output`.
    command: *const fn (*Self, client.Requests, []const u8, []u8) anyerror!void,
    /// Lends the terminal to the Session's conversation. Null once the
    /// person returned to the overview.
    converse: *const fn (*Self, view.Reference) ?Left,
};

pub const client_operations: Operations = .{ .host = hostFacts, .stopped = hostStopped, .list = listPage, .first_line = firstLine, .start = startSession, .stop = stopSession, .archive = archiveSession, .models = listModels, .save_default = saveDefault, .command = runCommand, .converse = converse };

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

const Job = union(enum) {
    /// host-info, read as each listing starts.
    host,
    /// The traversal's next page.
    list,
    lines: view.Reads,
    /// Owns what Enter captured: nothing the core or the composer holds is
    /// read on the worker's thread.
    start: view.OwnedStart,
    stop: view.Reference,
    archive: view.ArchiveRequest,
    models,
    save: view.Default,
    /// Owns its line, as a start owns its text.
    command: struct { name: view.commands.Name, session: ?view.Reference, line: []u8 },

    /// A job owns its inputs until it is replaced or the overview ends,
    /// whether or not it ran.
    fn deinit(self: Job, gpa: std.mem.Allocator) void {
        switch (self) {
            .start => |start| start.deinit(gpa),
            .command => |command| gpa.free(command.line),
            else => {},
        }
    }
};

/// One host read and list page, at most one first-line batch, one
/// model-list read, one save, one command and the requests the core's
/// ledger allows can wait at once.
const max_jobs = 6 + view.max_requests;

/// The longest the first frame waits for the terminal's background.
const background_wait_ms = 200;

const Line = struct { bytes: [view.max_line_read_bytes]u8 = undefined, result: enum { line, refused, unanswered } = .unanswered, len: usize = 0 };

/// A command's output: one byte past what the core takes tells it was cut.
const Output = struct {
    bytes: [view.max_output_bytes + 1]u8 = undefined,
    len: usize = 0,
    /// Its stdout and stderr went to the page, so a failure is a failure
    /// while it ran.
    kept: bool = false,
};

/// Wakes the loop from a signal handler: SIGINT and SIGTERM stop it, and
/// SIGWINCH redraws.
const Signals = struct {
    var cancellation: client.Cancellation = .{};
    var wake: c_int = -1;
    var previous: [3]std.posix.Sigaction = undefined;
    const handled = .{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.WINCH };

    fn handle(signal: std.posix.SIG) callconv(.c) void {
        if (signal != std.posix.SIG.WINCH) cancellation.requestStop();
        const byte = [1]u8{0};
        _ = std.c.write(wake, &byte, 1);
    }

    fn install(on: bool) void {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handle }, .mask = std.posix.sigemptyset(), .flags = 0 };
        inline for (handled, 0..) |signal, at| {
            if (on) std.posix.sigaction(signal, &action, &previous[at]) else std.posix.sigaction(signal, &previous[at], null);
        }
    }
};

init: std.process.Init,
options: Options,
hooks: Hooks,
ops: Operations,
state: view.State,
caps: view.Caps,
terminal: *SessionTerminal,
interrupted: *client.Cancellation,
/// The composer's line editor, the conversation's, which owns the draft.
composer: TerminalEditor = undefined,
draft: [view.draft_capacity]u8 = undefined,
/// The byte the latest frame's first composer line starts at, kept first by
/// the next frame so the composer scrolls only when its caret leaves view.
draft_anchor: usize = 0,
/// The worker's descriptors: it writes one byte as its job ends.
done: [2]c_int = .{ -1, -1 },
/// Signal wakes.
signalled: [2]c_int = .{ -1, -1 },

worker: ClientTask = .{},
jobs: [max_jobs]Job = undefined,
job_count: usize = 0,
/// The job the worker runs or last ran, and its output.
job: Job = .list,
traversal: protocol_reply.SessionTraversal = .init(null),
traversal_archive: protocol.SessionArchiveFilter = .active,
host: ?view.Host = null,
page: protocol_reply.SessionListPage = undefined,
lines: [view.max_first_line_reads]Line = @splat(.{}),
reply: Reply = .{},
/// The menu a model-list read built, until the core takes it.
menu: model_picker.Menu = .{},
/// Unlinked scratch for list pages.
scratch: ?std.Io.File = null,
/// Unlinked scratch a command's output goes to, made for the first command.
command_page: ?std.Io.File = null,
/// What the last command printed, as far as the core takes it.
output: Output = .{},

/// Whether the current semantic rows need another animation tick. The
/// backend, not the overview, owns the retained cells and diff reference.
spins: bool = false,
/// What a key read while output waited asks of the loop.
pumped: ?Next = null,
/// The Session a conversation borrows, in stable storage.
opened: view.Reference = undefined,
/// The stop prompt the conversation shows.
prompt: [view.max_prompt_bytes]u8 = undefined,
/// The overview's own step or job failed while a conversation held the
/// terminal: the failure is the overview's, not the Session's.
lent_failed: bool = false,
/// The Session the last accepted start made, for guidance if its
/// conversation fails.
started: ?view.Reference = null,
/// The terminal has not yet answered the DA1 that follows the background
/// question.
asking: bool = false,
/// The program status reports waiting on the terminal.
sending: Sending = .{},

/// Program status reports handed to the terminal, by its number for them,
/// and what each leaves it holding once a frame writes them whole. They
/// stand while neither the preference nor, with notifications on, any
/// wanted record changed.
const Sending = struct {
    batch: ?u64 = null,
    clears: bool = false,
    on: bool = true,
    changes: u64 = 0,
    taken: [max_reports]view.StatusRecord.Taken = undefined,
    len: usize = 0,

    /// The fewest bytes a report takes is a clear's.
    const max_reports = @sizeOf(@FieldType(SessionTerminal, "status_bytes")) / ("\x1b]7501;state=clear:id=rui/".len + @sizeOf(view.Reference) + "\x1b\\".len);
};

/// Opens the overview and returns once the person leaves it, or a signal
/// stops it. Every way out restores the terminal and then prints the
/// Detached notice once.
pub fn run(init: std.process.Init, options: Options, hooks: Hooks) !void {
    const self = try create(init, options, hooks, client_operations, &Signals.cancellation);
    defer self.destroy();
    const screen = try init.gpa.create(SessionScreen);
    defer init.gpa.destroy(screen);
    var backend: RenderBackend = .{};
    defer backend.deinit();
    const prepared: anyerror!void = prepare: {
        backend.init(init.io, init.environ_map, .{ .width = self.caps.width, .depth = switch (self.caps.depth) {
            .none => .none,
            .indexed => .indexed,
            .direct => .direct,
        } }) catch |err| break :prepare err;
        screen.init(&backend);
        self.scratch = hooks.scratch(init) catch |err| break :prepare err;
    };
    prepared catch |err| return self.failed(err, options.open);
    Signals.cancellation.stopped.store(false, .release);
    Signals.wake = self.signalled[1];
    Signals.install(true);
    defer Signals.install(false);
    const notices: SessionTerminal.Notices = .of(init.environ_map, options.home);
    var terminal = SessionTerminal.begin(screen, !notices.multiplexed) catch |err| return self.failed(err, options.open);
    terminal.notices = notices;
    self.terminal = &terminal;
    const ended = self.loop();
    return self.finish(ended);
}

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
        .terminal = undefined,
        .interrupted = interrupted,
    };
    self.composer = self.emptyComposer(0);
    try self.state.init(init.gpa, .{ .cwd = options.workspace, .home = options.home, .login_at = options.login_at, .default = .of(options.provider, options.model) });
    errdefer self.state.deinit();
    errdefer self.closePipes();
    for ([_]*[2]c_int{ &self.done, &self.signalled }) |pipe| try openPipe(pipe);
    return self;
}

/// A signal handler and the worker write without blocking; no child
/// inherits either end.
fn openPipe(pipe: *[2]c_int) !void {
    if (std.c.pipe(pipe) != 0) return error.SystemResources;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    for (pipe) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SystemResources;
    }
}

fn closePipes(self: *Self) void {
    for ([_]*[2]c_int{ &self.done, &self.signalled }) |pipe| for (pipe) |*fd| if (fd.* >= 0) {
        _ = std.c.close(fd.*);
        fd.* = -1;
    };
}

fn destroy(self: *Self) void {
    std.debug.assert(self.worker.thread == null);
    self.job.deinit(self.init.gpa);
    for (self.jobs[0..self.job_count]) |job| job.deinit(self.init.gpa);
    if (self.scratch) |file| file.close(self.init.io);
    if (self.command_page) |file| file.close(self.init.io);
    self.closePipes();
    self.state.deinit();
    self.menu.deinit(self.init.gpa);
    self.init.gpa.destroy(self);
}

const Ending = union(enum) { overview, conversation: Left };

/// What the core asks of the loop: to leave, or to lend the terminal to a
/// Session.
const Next = union(enum) { leave, open: view.Reference };

/// Runs until the person leaves the overview or a conversation, or a signal
/// stops it. The terminal is still begun when it returns.
fn loop(self: *Self) !Ending {
    if (try self.resize(self.terminal.geometry())) |value| if (self.proceed(value)) |ending| return ending;
    if (self.options.open) |reference| if (try self.event(.{ .open = reference })) |value| if (self.proceed(value)) |ending| return ending;
    // After the open: keys typed during the wait act on the overview.
    var next = try self.askBackground();
    while (true) {
        if (next) |value| if (self.proceed(value)) |ending| return ending;
        if (self.interrupted.stopped.load(.acquire)) return .overview;
        next = try self.turn();
    }
}

/// One pass: a due tick, the next job and a frame, then one wait for input,
/// the worker or a signal.
fn turn(self: *Self) !?Next {
    const now_ms = self.realMs();
    if (self.state.wakeAt()) |at| if (now_ms >= at) if (try self.event(.{ .tick = now_ms })) |next| return next;
    try self.dispatch(.all);
    // Frames count on the monotonic clock, so a wall-clock step cannot
    // stall or race the spinner; ticks keep the Host's wall clock.
    const awake_ns = std.Io.Clock.awake.now(self.init.io).nanoseconds;
    const awake_ms: u64 = @intCast(@max(@divFloor(awake_ns, std.time.ns_per_ms), 0));
    if (try self.draw(awake_ms / view.spin_interval_ms)) |next| return next;
    const spins = self.spins;
    const timeout = switch (self.terminal.stream.wait(awake_ns, self.budget(now_ms, awake_ms, spins))) {
        .expire => 0,
        .poll => |milliseconds| milliseconds,
    };
    var fds = [_]std.posix.pollfd{
        .{ .fd = self.terminal.input, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = self.done[0], .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = self.signalled[0], .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&fds, timeout);
    if (fds[2].revents != 0) drain(self.signalled[0]);
    if (fds[1].revents != 0) {
        drain(self.done[0]);
        if (try self.complete()) |next| return next;
    }
    if (fds[0].revents != 0 or timeout == 0) return self.readInput(0, 4096);
    return null;
}

/// Leaves, or lends the terminal to a Session until the person returns.
fn proceed(self: *Self, next: Next) ?Ending {
    switch (next) {
        .leave => return .overview,
        .open => |reference| {
            self.opened = reference;
            // Both views paint the SAME retained grid; changing the borrower
            // is not a reason to discard a healthy libvaxis diff reference.
            if (self.ops.converse(self, self.opened)) |left| return .{ .conversation = left };
            return null;
        },
    }
}

fn drain(fd: c_int) void {
    var bytes: [64]u8 = undefined;
    while (std.c.read(fd, &bytes, bytes.len) > 0) {}
}

/// Steps the core with one event and queues the jobs it asks for. Opening a
/// Session and leaving are the loop's to do.
fn event(self: *Self, value: view.Event) !?Next {
    const effects = try view.step(&self.state, value);
    var next: ?Next = null;
    var refused: ?keymap.Refusal = null;
    for (effects.slice()) |effect| switch (effect) {
        .list => |since| {
            self.traversal = .init(since);
            self.traversal_archive = self.state.listing_archive.?;
            self.queue(.host);
            self.queue(.list);
        },
        .read_first_lines => |reads| self.queue(.{ .lines = reads }),
        .start => |request| self.queue(.{ .start = try request.own(self.init.gpa) }),
        .stop => |reference| self.queue(.{ .stop = reference }),
        .archive => |request| self.queue(.{ .archive = request }),
        .list_models => self.queue(.models),
        .save_default => |binding| self.queue(.{ .save = binding }),
        .command => |command| self.queue(.{ .command = .{ .name = command.name, .session = command.session, .line = try self.init.gpa.dupe(u8, command.text) } }),
        .open => |reference| next = .{ .open = reference },
        .clear_draft => self.composer = self.emptyComposer(self.composer.edits +% 1),
        // A refused addition says so as a refused key does.
        .append => |text| switch (self.composer.append(text)) {
            .refused => |why| refused = why,
            else => {},
        },
        .notify => |alert| self.terminal.notify(alert.name, alert.kind, alert.more),
        .exit => return .leave,
    };
    if (refused) |why| if (next == null) return self.event(.{ .composed = .{ .input = .{ .composer = .{ .refused = why } }, .draft = self.composerDraft() } });
    self.sendStatuses();
    return next;
}

/// Brings the terminal's program status records to what the core wants:
/// a report for each Session whose record the terminal does not hold as
/// wanted, as many as a frame takes, or with notifications off one clear of
/// every record Rui may have set. The core learns what the terminal holds
/// only from a frame that wrote the reports whole, so reports a cut frame
/// may have dropped wait for the next frame.
fn sendStatuses(self: *Self) void {
    const terminal = self.terminal;
    if (terminal.program_status != .supported) return;
    // Keep the semantic receipt for writeWaiting's frozen batch until wrote.
    // Pumped facts may change wanted records, never replace that receipt.
    if (terminal.writing) return;
    const sending = &self.sending;
    if (sending.batch) |batch| if (terminal.statusesTaken(batch)) {
        if (sending.clears) self.state.statusesCleared() else for (sending.taken[0..sending.len]) |taken| self.state.statusTaken(taken);
        sending.* = .{};
    };
    if (sending.batch == null and self.state.statusesSettled() and !terminal.statuses_shown) return;
    const on = terminal.notificationsOn();
    // Off, the records wanted do not matter.
    if (sending.batch != null and sending.on == on and (!on or sending.changes == self.state.status_changes)) return;
    sending.* = .{ .batch = terminal.beginStatuses(), .on = on, .changes = self.state.status_changes };
    if (!on) {
        if (!terminal.statuses_shown) return;
        terminal.clearStatuses();
        sending.clears = true;
        self.state.statusesClearing();
        return;
    }
    var unsettled = self.state.unsettledStatuses();
    while (unsettled.next()) |record| {
        if (sending.len == sending.taken.len or !terminal.reportStatus(&record.reference, record.name, record.status)) return;
        sending.taken[sending.len] = record.taken();
        sending.len += 1;
    }
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
    try self.worker.start(self.init.io, self, work);
}

/// The worker: runs one job and writes only its own output fields. Its
/// result is the job's outcome, which `complete` settles.
fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    defer {
        const byte = [1]u8{0};
        _ = std.c.write(self.done[1], &byte, 1);
    }
    return self.runJob(task.requests());
}

/// Runs `job`, on the worker's thread or, for a save on the way out, the
/// loop's.
fn runJob(self: *Self, requests: client.Requests) !void {
    switch (self.job) {
        .host => self.host = self.ops.host(self),
        .list => if (try self.ops.list(self, requests, self.traversal.cursor, &self.page)) |failure| return failure.err(),
        .lines => |reads| {
            const lines = self.lines[0..reads.len];
            for (lines) |*line| line.result = .unanswered;
            for (reads.slice(), lines) |read, *line| switch (try self.ops.first_line(self, requests, &read.reference, read.position, &line.bytes)) {
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
        .start => |*start| {
            // An unreadable saved effort sends nothing, as a failed capture does.
            var compaction_buffer: [20]u8 = undefined;
            const input = self.startInput(start, &compaction_buffer) catch |err| {
                self.reply = .refused(@errorName(err));
                return;
            };
            try self.ops.start(self, requests, input, &self.reply);
        },
        .stop => |*reference| try self.ops.stop(self, requests, .{ .store = self.options.store, .session = reference }, &self.reply),
        .archive => |*request| {
            self.reply = .refused("archive_request_failed");
            try self.ops.archive(self, requests, .{ .store = self.options.store, .session = &request.reference, .archived = request.archived }, &self.reply);
        },
        .models => {
            const gpa = self.init.gpa;
            const body = try self.ops.models(self, requests, gpa);
            defer gpa.free(body);
            self.menu = try model_picker.read(gpa, try protocol_reply.modelListProviders(body));
        },
        .save => |binding| try self.ops.save_default(self, binding),
        .command => |*command| {
            self.output = .{};
            try self.ops.command(self, requests, if (command.session) |*session| session else "", command.line);
        },
    }
}

/// On the way out, runs each save the core asked for that the worker never
/// started, as the worker would, each answer stepping the core: a save is a
/// local file write that outlives the overview, and the departure says how
/// it ended. No other queued job runs.
fn flushSaves(self: *Self) !void {
    const requests: client.Requests = .{ .io = self.init.io };
    while (for (self.jobs[0..self.job_count], 0..) |job, index| {
        if (job == .save) break index;
    } else null) |index| {
        self.job.deinit(self.init.gpa);
        self.job = self.take(index);
        _ = try self.deliver(self.runJob(requests));
    }
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

fn deliver(self: *Self, outcome: anyerror!void) !?Next {
    switch (self.job) {
        .host => return self.event(.{ .host = self.host }),
        .list => {
            outcome catch return self.event(.{ .list = .failed });
            var rows: [view.max_page_rows]view.Listed = undefined;
            const page: view.Page = .of(&self.traversal, &self.page, &rows);
            // The next page goes before anything this page's result queues.
            if (page.answer == null) self.queue(.list);
            return self.event(.{ .list = .{ .page = page } });
        },
        .lines => |reads| for (reads.slice(), self.lines[0..reads.len]) |read, *line| {
            const result: view.FirstLine = .{ .reference = read.reference, .admission = read.admission, .line = if (line.result == .line) line.bytes[0..line.len] else null, .unanswered = line.result == .unanswered };
            if (try self.event(.{ .first_line = result })) |next| return next;
        },
        .start => {
            if (self.reply.outcome == .accepted) self.started = self.reply.session;
            return self.event(.{ .start = self.reply.start() });
        },
        .stop => |reference| return self.event(.{ .stop = .{ .reference = reference, .outcome = self.reply.stop() } }),
        .archive => |request| return self.event(.{ .archive = self.reply.archive(request) }),
        .models => {
            outcome catch |err| return self.event(.{
                .models = switch (err) {
                    error.InvalidModelList, error.InvalidResponse, error.ResponseTooLarge => .invalid,
                    // Any other failure leaves the person nothing to do but
                    // try /model again, as when the Host is gone.
                    else => .unanswered,
                },
            });
            const menu = self.menu;
            self.menu = .{};
            return self.event(.{ .models = .{ .menu = menu } });
        },
        .save => |binding| return self.event(.{
            .saved = .{
                .ended = .{ .binding = binding, .outcome = savedAs(outcome) },
                // An unreadable file only leaves the effort out of the notice:
                // the save that wrote it reports its own failure, and the next
                // start reads the file again and is refused with the error.
                .saved_effort = self.savedEffort() catch null,
            },
        }),
        .command => |command| {
            const output = &self.output;
            const ran: view.Ran = .{
                .output = output.bytes[0..@min(output.len, view.max_output_bytes)],
                .cut = output.len > view.max_output_bytes,
                // As a conversation drops an inspection that could not
                // start, the overview says only that it did not run.
                .outcome = if (outcome) |_| .done else |_| if (output.kept) .failed else .not_run,
                .default = if (outcome) |_| if (command.name == .setup) self.savedDefault() else null else |_| null,
            };
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

/// The default a fresh launch with this overview's selectors would take
/// from the saved defaults now; null when they decide none, so the one in
/// force stays. Readiness is the Host's to answer at the start, as for any
/// caller that cannot ask, so every provider counts as ready here, and only
/// a launch that named no provider and saved none needs the chooser.
fn savedDefault(self: *const Self) ?view.Default {
    const selectors = self.options.selectors;
    if (!selectors.needsPreferences() or self.options.home.len == 0) return null;
    const snapshot: new_session_selection.Snapshot = .{ .intent = selectors, .defaults = preferences.load(self.options.home) catch return null };
    const binding = (snapshot.resolve(&.initFill(.configured)) catch return null) orelse return null;
    return .of(binding.provider.slice(), binding.model.slice());
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
        fn given(value: ?[]const u8) client.OptionalText {
            return if (value) |present| .{ .present = true, .value = present } else .{};
        }
        fn policy(value: ?[]const u8) client.OptionalPolicy {
            const given_value = value orelse return .{};
            return .{ .present = true, .value = if (std.mem.eql(u8, given_value, "default")) null else given_value };
        }
    };
    const label: client.OptionalPolicy = if (held.at(start, "label")) |value| .{ .present = true, .value = if (value.len == 0) null else value } else .{};
    const held_effort = held.at(start, "reasoning-effort");
    const effort = held.policy(held_effort);
    const start_effort: view.StartEffort = .{ .held = held_effort, .model = start.binding().model };
    // Read at each start, so an /effort chosen in a conversation since this
    // overview opened applies.
    const saved_effort = start_effort.applied(if (start_effort.readsSaved()) try self.savedEffort() else null);
    return .{ .store = self.options.store, .session = "", .text_path = "", .text = start.text(), .configuration = .{
        .store = self.options.store,
        .session = .create,
        .require_model = true,
        .workspace = .{ .present = true, .value = held.at(start, "workspace") orelse self.options.workspace },
        .provider = held.given(start.binding().provider),
        .model = held.given(start.binding().model),
        .tools = held.at(start, "tools") orelse product_defaults.tools,
        .loaded_tools = held.at(start, "loaded-tools"),
        .permission_mode = .{ .present = true, .value = held.at(start, "permission-mode") orelse product_defaults.permission_mode },
        .compaction_trigger = if (held.at(start, "compaction-trigger") != null and !std.mem.eql(u8, held.at(start, "compaction-trigger").?, "default")) held.policy(held.at(start, "compaction-trigger")) else .{ .present = true, .value = try std.fmt.bufPrint(compaction_buffer, "{d}", .{client.defaultCompactionTrigger(std.meta.stringToEnum(protocol.Provider, start.binding().provider orelse product_defaults.provider).?, start.binding().model orelse product_defaults.recommended_model)}) },
        .output_reservation = held.policy(held.at(start, "output-reservation")),
        .reasoning_effort = if (effort.present and effort.value != null) effort else client.defaultStartEffort(start.binding().model orelse product_defaults.recommended_model, if (effort.present) null else saved_effort),
        .label = label,
    } };
}

fn listModels(self: *Self, requests: client.Requests, gpa: std.mem.Allocator) ![]u8 {
    return requests.modelList(self.options.store, gpa);
}

/// How a save ended, in the words `/setup` uses for the same failure.
fn savedAs(outcome: anyerror!void) view.Saved {
    outcome catch |err| {
        const said = preferences.failure(err);
        return if (said.saved) .unconfirmed else .{ .failed = said.reason };
    };
    return .done;
}

/// Runs a command line through the CLI's hook, as a conversation runs it,
/// and keeps what it printed.
fn runCommand(self: *Self, requests: client.Requests, session: []const u8, line: []u8) !void {
    const page = self.command_page orelse page: {
        const file = try self.hooks.scratch(self.init);
        self.command_page = file;
        break :page file;
    };
    const command: session_reads.CommandRun = .{ .command = self.hooks.command, .init = self.init, .requests = requests, .store = self.options.store, .session = session, .line = line };
    const ended = command.into(page);
    self.output.kept = ended.rendering;
    // Failed restoration may leave fd 2 on the page, so, as a conversation
    // does, keep nothing for the way out to write there.
    if (!ended.rendering or !ended.stderr_restored) return ended.outcome;
    // What it printed shows whether it ran to the end or not.
    self.output.len = page.readPositionalAll(self.init.io, &self.output.bytes, 0) catch |err| {
        try ended.outcome;
        return err;
    };
    return ended.outcome;
}

/// Saves the pick as `rui defaults configure --provider --model` would.
fn saveDefault(self: *Self, binding: view.Default) !void {
    // Both are named, so no sign-in's readiness decides anything.
    const readiness: preferences.Readinesses = .initFill(.configured);
    _ = try preferences.update(self.options.home, .{ .provider = .{ .set = @tagName(binding.provider) }, .model = .{ .set = binding.model.slice() } }, &readiness);
}

/// Reads up to `bytes` of what the terminal holds, waiting `wait`
/// milliseconds for the first byte, and steps each key. A lone Esc becomes a
/// key once the stream says it expired.
fn readInput(self: *Self, wait: i32, bytes: usize) !?Next {
    for (0..bytes) |count| {
        const read = (self.terminal.next(self.init.io, if (count == 0) wait else 0) catch |err| switch (err) {
            error.InputDeadline => {
                const expired = try self.terminal.stream.expire();
                if (expired != .none) {
                    if (try self.compose(expired)) |next| return next;
                }
                continue;
            },
            else => return err,
        }) orelse return null;
        var decoded = self.terminal.stream.feed(read.byte, read.at);
        while (decoded != .none) : (decoded = self.terminal.stream.next()) switch (decoded) {
            .event => |value| switch (value.event) {
                // An answer applies whenever it comes; a late one repaints.
                .color_report => |report| if (report.kind == .bg) {
                    self.caps.background = report.value;
                },
                else => if (try self.compose(decoded)) |next| return next,
            },
            .report => |report| switch (report) {
                .width => |method| {
                    self.terminal.widthReported(method);
                    self.caps.width = method;
                },
                .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
                .focus => |focused| self.terminal.focused = focused,
                .program_status => {
                    _ = self.terminal.answered(.program_status);
                    self.sendStatuses();
                },
                // Every terminal answers the background question's request,
                // after the probe's.
                .device_attributes => if (!self.terminal.answered(.device_attributes)) {
                    self.asking = false;
                } else self.sendStatuses(),
            },
            else => if (try self.compose(decoded)) |next| return next,
        };
    }
    return null;
}

/// The wall clock in Unix milliseconds, as the core's times are.
fn realMs(self: *const Self) u64 {
    return @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
}

/// Asks the terminal for its background, then waits up to
/// `background_wait_ms` so the first frame has its skin. Every terminal
/// answers the DA1 that follows the question, so its answer ends the wait
/// early on one that does not answer OSC 11.
fn askBackground(self: *Self) !?Next {
    if (self.caps.depth == .none) return null;
    const ask = "\x1b]11;?\x1b\\\x1b[c";
    {
        self.terminal.pump = .{ .context = self, .step = pump };
        defer self.terminal.pump = null;
        self.pumped = null;
        self.terminal.write(ask) catch |err| {
            self.terminal.screen.backend.poison();
            if (err == error.InteractiveInterrupted) return .leave;
            return err;
        };
        if (self.pumped) |next| {
            self.pumped = null;
            return next;
        }
    }
    self.asking = true;
    // The wait ends here; a late answer still applies when it comes.
    defer self.asking = false;
    const deadline = std.Io.Clock.awake.now(self.init.io).toMilliseconds() + background_wait_ms;
    while (self.asking and self.caps.background == null) {
        const left = deadline - std.Io.Clock.awake.now(self.init.io).toMilliseconds();
        if (left <= 0) break;
        // A byte at a time, so keys typed after the answer wait for the
        // first frame.
        if (try self.readInput(@intCast(left), 1)) |next| return next;
    }
    return null;
}

/// Every input takes one route, the one the core's input mode names, then
/// one core step, whether or not anything changed.
fn compose(self: *Self, decoded: TerminalInput.Decoded) !?Next {
    // Once a target was accepted, keep decoding but discard complete ordinary
    // interactive events. No draft/command/approval mutation and no replay.
    if (self.terminal.writing and self.pumped != null) {
        if (TerminalEditor.frozenAction(view.keys, decoded) == .exit) return .leave;
        return null;
    }
    const input = if (self.state.prompt != null and self.state.prompt.?.action == .archive and TerminalEditor.plainEnter(decoded))
        view.Input{ .composer = .submit }
    else if (self.state.prompt != null and self.state.prompt.?.action == .archive and TerminalEditor.select(view.keys, decoded) == .enter)
        view.Input{ .composer = .none }
    else
        route(self.state.inputMode(), &self.composer, decoded);
    return self.event(.{ .composed = .{ .input = input, .draft = self.composerDraft() } });
}

/// An empty draft, whose Tab puts in the command list's highlighted word.
/// `edits` continues the count, so no two drafts share one.
fn emptyComposer(self: *Self, edits: u32) TerminalEditor {
    return .{ .buffer = &self.draft, .completion = .{ .context = self, .add = tabCompletion }, .edits = edits };
}

/// Tab: the rest of the highlighted entry's word in the draft's list,
/// shown, hidden or closed; null for a draft no list is for, which takes
/// the tab.
fn tabCompletion(context: *const anyopaque, draft: []const u8) ?[]const u8 {
    const self: *const Self = @ptrCast(@alignCast(context));
    if (view.commands.suggest(draft, .{}) == null) return null;
    const shown = view.nextCommands(&self.state, self.composerDraft()) orelse return "";
    return shown.completion();
}

/// One input through `mode`'s route, with the overview's one key table.
/// The composer edits. Frozen while a start waits, the keys the table binds
/// still act, and nothing edits the text a failed start leaves to retry.
/// At the sign-in choice, as at an Action's choice in a conversation, the
/// arrows and Enter are the choice's; typing and a paste go to the
/// composer, which takes a paste from its start to its end.
fn route(mode: view.InputMode, composer: *TerminalEditor, decoded: TerminalInput.Decoded) view.Input {
    return switch (mode) {
        .compose => .{ .composer = composer.apply(view.keys, decoded) },
        .frozen => .{ .composer = if (TerminalEditor.frozenAction(view.keys, decoded)) |action| .{ .action = action } else .none },
        .choice => switch (TerminalEditor.select(view.keys, decoded)) {
            .none => .{ .choice = .none },
            .action => |action| .{ .choice = .{ .action = action } },
            .left => .{ .choice = .left },
            .right => .{ .choice = .right },
            .enter => .{ .choice = .enter },
            .refused => .{ .choice = .refused },
            .text => .{ .composer = composer.apply(view.keys, decoded) },
        },
    };
}

/// Paints semantic rows at animation `frame`; libvaxis alone diffs its grid.
/// Encoded bytes remain frozen until the existing pumped write completes.
fn draw(self: *Self, frame: u64) !?Next {
    // Domain and grid must share one snapshot, even during a terminal resize.
    return self.drawFrame(frame, self.terminal.geometry());
}

fn drawFrame(self: *Self, frame: u64, size: std.posix.winsize) !?Next {
    if (try self.resize(size)) |next| return next;
    self.terminal.applyReports();
    const backend = self.terminal.screen.backend;
    _ = backend.setPolicy(.{ .width = self.caps.width, .depth = switch (self.caps.depth) {
        .none => .none,
        .indexed => .indexed,
        .direct => .direct,
    } });
    try backend.begin(.{ .cols = size.col, .rows = size.row, .x_pixel = size.xpixel, .y_pixel = size.ypixel });
    defer {
        backend.end();
        self.terminal.applyReports();
    }
    errdefer backend.poison();
    // Waiting reports go first, while this is still only allocating memory.
    self.terminal.writeWaiting(backend.prefixWriter()) catch return error.OutOfMemory;
    const drawn = try OverviewPaint.draw(backend.window(), backend.scratch(), &self.state, self.composerDraft(), self.caps, frame);
    self.draft_anchor = drawn.draft_anchor;
    self.state.commands = drawn.commands;
    self.spins = drawn.spins;
    const bytes = try backend.encode();
    self.terminal.pump = .{ .context = self, .step = pump };
    defer self.terminal.pump = null;
    self.pumped = null;
    defer self.pumped = null;
    self.terminal.write(bytes) catch |err| {
        // A normal leave is still a failed frozen frame: poison BEFORE the
        // catch converts the I/O interruption into the loop's normal result.
        backend.poison();
        if (err == error.InteractiveInterrupted) return .leave;
        return err;
    };
    // Also the existing acknowledgement point for a genuinely empty frame.
    self.terminal.wrote();
    return self.pumped;
}

/// Steps the terminal's size when it changed, so the frame drawn next and
/// the keys read until the one after act on one layout.
fn resize(self: *Self, size: std.posix.winsize) !?Next {
    if (size.col == self.state.size.width and size.row == self.state.size.height) return null;
    return self.event(.{ .resized = .{ .width = size.col, .height = size.row } });
}

/// How long the loop may wait, in milliseconds, -1 for ever: until the
/// core's next tick, and while the screen spins, no later than its next
/// frame. Until then only input, the worker or a signal wakes it.
fn budget(self: *const Self, now_ms: u64, awake_ms: u64, spins: bool) i32 {
    const tick: i32 = if (self.state.wakeAt()) |at| @intCast(@min(at -| now_ms, std.math.maxInt(i32))) else -1;
    if (!spins) return tick;
    const frame: i32 = @intCast(view.spin_interval_ms - awake_ms % view.spin_interval_ms);
    return if (tick < 0) frame else @min(tick, frame);
}

/// Complete the frozen bytes before an ordinary view transition. The first
/// accepted target stays immutable; only urgent typed exit/signals may abort.
fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
    const next = try self.readInput(0, 4096) orelse return;
    if (next == .leave) return error.InteractiveInterrupted;
    std.debug.assert(self.pumped == null);
    self.pumped = next;
    self.terminal.screen.invalidateScope();
}

/// Lends the terminal to the Session's conversation until the person
/// leaves it.
fn converse(self: *Self, session: view.Reference) ?Left {
    var left: Left = .{ .session = session, .frontend = null, .files = null, .ended = error.OutOfMemory };
    const io = self.init.io;
    const screen = self.terminal.screen;
    // Fresh domain state borrows the SAME invocation grids and decoder.
    screen.init(screen.backend);
    var opened: [6]std.Io.File = undefined;
    for (&opened, 0..) |*file, count| file.* = self.hooks.scratch(self.init) catch |err| {
        for (opened[0..count]) |done| done.close(io);
        left.ended = err;
        return left;
    };
    const files: SessionFrontend.Files = .{ .scratch = opened[0], .action = opened[1], .inspection = opened[2], .status = opened[3], .actions = opened[4..6].* };
    const frontend = self.init.gpa.create(SessionFrontend) catch |err| {
        for (opened) |file| file.close(io);
        left.ended = err;
        return left;
    };
    const lender: SessionFrontend.Lender = .{ .context = self, .step = conversed, .service = service, .line = conversationLine, .observed = observed };
    var ended = frontend.run(self.init, self.options.store, &self.opened, self.options.directory, files, self.hooks.command, self.hooks.requests, self.hooks.status, self.terminal, self.interrupted, lender);
    // The conversation may have read the terminal's width report.
    self.caps.width = screen.backend.widthMethod();
    const returned = if (ended) |outcome| outcome == .returned else |_| false;
    if (returned) ended = frontend.back() orelse {
        self.init.gpa.destroy(frontend);
        for (opened) |file| file.close(io);
        return null;
    };
    return .{ .session = session, .frontend = frontend, .files = files, .ended = ended };
}

/// An input in the opened Session's conversation, whose work shows as
/// `kind`, stepped as the overview's own: a stop it asks for is sent at
/// once.
fn conversed(raw: *anyopaque, kind: view.Kind, input: view.ConversationInput) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const next = try self.event(.{ .conversed = .{ .reference = self.opened, .work = kind, .input = input } });
    std.debug.assert(next == null);
    try self.dispatch(.lent);
}

/// A read the opened Session's conversation applied, recorded as the
/// listing's are, so its news is notified once whichever reads it first.
fn observed(raw: *anyopaque, read: protocol.session_work.Work, name: []const u8, opening: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const next = try self.event(.{ .observed = .{ .reference = self.opened, .work = read, .name = name, .opening = opening } });
    std.debug.assert(next == null);
}

/// While a conversation holds the terminal the overview goes on without
/// the screen or input: its ticks keep the listing going, so another
/// Session's news still notifies, and a finished job is answered here, so a
/// stop never waits behind a listing. Starts wait for the overview.
fn service(raw: *anyopaque) !bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const now_ms = self.realMs();
    if (self.state.wakeAt()) |at| if (now_ms >= at) {
        _ = try self.event(.{ .tick = now_ms });
    };
    const answered = self.worker.thread != null and self.worker.completed();
    if (answered) {
        drain(self.done[0]);
        // Only a start's answer opens a Session, and none is in flight
        // while a conversation is open.
        const next = try self.complete();
        std.debug.assert(next == null);
    }
    try self.dispatch(.lent);
    return answered;
}

/// What the overview says under the opened Session's conversation.
fn conversationLine(raw: *anyopaque, kind: view.Kind) SessionFrontend.Lender.Said {
    const self: *Self = @ptrCast(@alignCast(raw));
    const said = view.conversation(&self.state, self.opened, kind, &self.prompt);
    return .{ .text = said.text, .asking = said.asking, .stoppable = said.stoppable };
}

/// Every way out: restores the terminal, answers the worker's job through
/// `complete` as the loop does, runs the saves the core asked for, then
/// writes the ledger's guidance before anything that can return. The
/// departure is whole before the restore result is read. A conversation's
/// own guidance and the Detached notice follow.
fn finish(self: *Self, ended: anyerror!Ending) !void {
    const restored = self.terminal.finish();
    self.worker.cancel();
    const answered: anyerror!?Next = if (self.event(.leave)) |_| self.complete() else |err| err;
    const saved = self.flushSaves();
    self.writeDeparture();
    var ending = try ended;
    switch (ending) {
        .overview => {
            try restored;
            _ = try answered;
            try saved;
            try self.terminal.detached(self.options.store, null, null);
        },
        .conversation => |*left| {
            if (answered) |_| {} else |err| left.ended = err;
            saved catch |err| {
                left.ended = err;
            };
            return self.leave(left.*, restored);
        },
    }
}

/// Writes the core's departure to stderr in one write. Never inlined: its
/// buffer stays off `finish`'s frame.
noinline fn writeDeparture(self: *const Self) void {
    // A ledger entry prints well under 512 bytes.
    var bytes: [view.max_requests * 512 + view.max_late_save_bytes + view.max_late_command_bytes]u8 = undefined;
    var guidance = std.Io.Writer.fixed(&bytes);
    // Read now and whatever this launch named, since the line speaks for
    // later launches. An unreadable file only leaves the effort out: the
    // next launch that reads it reports the error.
    const saved_effort = if (self.options.home.len == 0) null else if (preferences.load(self.options.home)) |values| values.reasoning_effort else |_| null;
    view.writeDeparture(&self.state, saved_effort, &guidance) catch unreachable;
    _ = stderr.write(guidance.buffered());
}

/// Lets the conversation the person left join its borrowers and write its
/// guidance, then names the Session to resume.
fn leave(self: *Self, left: Left, restored: anyerror!void) !void {
    const io = self.init.io;
    defer if (left.files) |files| {
        inline for (.{ "scratch", "action", "inspection", "status" }) |name| @field(files, name).close(io);
        for (files.actions) |file| file.close(io);
    };
    defer if (left.frontend) |frontend| self.init.gpa.destroy(frontend);
    const session = &left.session;
    const store = self.options.store;
    const outcome: anyerror!void = run: {
        const frontend = left.frontend orelse {
            restored catch {};
            _ = left.ended catch |err| break :run err;
            break :run {};
        };
        const departure = frontend.leave(left.ended, restored);
        const end = departure.end catch |err| {
            if (departure.failure_notice) self.terminal.detached(store, session, departure.action) catch |notice_error|
                stderr.diagnostic("rui: Action recovery notice failed: {s}\n", .{@errorName(notice_error)});
            break :run err;
        };
        switch (end) {
            .detached, .interrupted => self.terminal.detached(store, session, departure.action) catch |err| {
                if (!departure.recovery_shown) frontend.recoveryGuide();
                break :run err;
            },
            .returned => unreachable,
        }
    };
    return outcome catch |err| {
        if (self.lent_failed) return err;
        if (!client.hostUnreachable(err) or !self.ops.stopped(self)) return self.failed(err, left.session);
        // Name this Store: a bare host start may pick another one.
        var bytes: [4 * protocol.max_store_bytes + 96]u8 = undefined;
        var notice = std.Io.Writer.fixed(&bytes);
        write: {
            notice.writeAll("\nrui: The Host stopped. Run rui host start --store ") catch break :write;
            TerminalText.writeShellWord(&notice, self.options.store) catch break :write;
            notice.writeAll(", then resume this Session.\n") catch break :write;
        }
        _ = stderr.write(notice.buffered());
        return self.failed(error.HostStopped, left.session);
    };
}

fn hostStopped(self: *Self) bool {
    return client.hostStatus(self.init.io, self.options.store) == .unavailable;
}

fn hostFacts(self: *Self) ?view.Host {
    const ready = switch (client.hostStatus(self.init.io, self.options.store)) {
        .ready => |ready| ready,
        else => return null,
    };
    return .{ .started_at = ready.started_at, .slots = ready.active_capacity, .slots_in_use = ready.custody_occupied };
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
    saved: ?struct { provider: view.Provider, model: protocol.Bounded(64) } = null,
    saves: usize = 0,
    /// How many Sessions the fake listing returns, from `listed_references`.
    listed: usize = 1,

    var now: Seen = .{};

    fn bounded(bytes: []const u8) protocol.Bounded(64) {
        var value: protocol.Bounded(64) = .{};
        value.set(bytes) catch unreachable;
        return value;
    }
};

const listed_references = [_][]const u8{ "k7m2qx", "b4n8wd", "p3c6tz", "h5r9vy", "m2j7fs" };

/// Operations that answer from fixed facts and record what they were asked.
const fake_operations: Operations = .{
    .host = struct {
        fn host(_: *Self) ?view.Host {
            Seen.now.hosts += 1;
            return .{ .started_at = test_now_s - 60, .slots = 4, .slots_in_use = 1 };
        }
    }.host,
    .stopped = struct {
        fn stopped(_: *Self) bool {
            return false;
        }
    }.stopped,
    .list = struct {
        fn list(self: *Self, _: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            Seen.now.lists += 1;
            Seen.now.archive_filter = self.traversal_archive;
            Seen.now.since = cursor.since;
            page.* = .{ .count = Seen.now.listed, .delta = .full, .since = .{ .instance = @splat(1), .generation = 1 }, .next = null };
            for (page.rows[0..Seen.now.listed], listed_references[0..Seen.now.listed], 0..) |*row, reference, at| {
                const since = test_now_s - 10 - at;
                row.* = .{ .work = .{ .state = .{ .working = .{ .since = since } }, .turn = 1, .operation = 1 } };
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
            try model_list.writeProviders(&reply.writer, &.{
                .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\n" } } },
                .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nwhisper-1\n" } } },
            });
            try reply.writer.writeAll(protocol.model_list_reply.tail);
            return reply.toOwnedSlice();
        }
    }.models,
    .save_default = struct {
        fn save(_: *Self, binding: view.Default) !void {
            Seen.now.saved = .{ .provider = binding.provider, .model = Seen.bounded(binding.model.slice()) };
            Seen.now.saves += 1;
        }
    }.save,
    // Through the hooks `Printing` gives.
    .command = runCommand,
    .converse = struct {
        fn converse(_: *Self, session: view.Reference) ?Left {
            Seen.now.conversations += 1;
            Seen.now.conversed = session;
            return null;
        }
    }.converse,
};

/// An overview over fake operations, reading keys from a pipe and drawing
/// into another.
const Rig = struct {
    environ: std.process.Environ.Map,
    init: std.process.Init = undefined,
    terminal: SessionTerminal = undefined,
    screen: *SessionScreen = undefined,
    keys: [2]c_int = .{ -1, -1 },
    output: [2]c_int = .{ -1, -1 },
    overview: *Self = undefined,

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
        try SessionScreen.Test.init(rig.screen, std.testing.io, &rig.environ, true);
        errdefer SessionScreen.Test.deinit(rig.screen);
        errdefer for (rig.keys ++ rig.output) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        try openPipe(&rig.keys);
        try openPipe(&rig.output);
        rig.terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = rig.screen, .input = rig.keys[0], .output = rig.output[1] };
        rig.overview = try create(rig.init, options, undefined, ops, interrupted);
        rig.overview.terminal = &rig.terminal;
        // As the loop does before it reads a key.
        _ = try rig.overview.resize(rig.terminal.geometry());
        return rig;
    }

    fn close(rig: *Rig) void {
        rig.overview.worker.cancel();
        if (rig.overview.worker.thread != null) rig.overview.worker.join() catch {};
        rig.overview.destroy();
        for (rig.keys ++ rig.output) |fd| _ = std.c.close(fd);
        SessionScreen.Test.deinit(rig.screen);
        std.testing.allocator.destroy(rig.screen);
        rig.environ.deinit();
        std.testing.allocator.destroy(rig);
    }

    fn press(rig: *Rig, bytes: []const u8) !?Ending {
        if (std.c.write(rig.keys[1], bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.TestUnexpectedResult;
        const next = try rig.overview.readInput(0, 4096) orelse return null;
        return rig.overview.proceed(next);
    }

    /// Runs queued jobs as the loop would, each result stepping the core.
    fn settle(rig: *Rig) !?Ending {
        const overview = rig.overview;
        while (true) {
            try overview.dispatch(.all);
            if (overview.worker.thread == null) return null;
            var fds = [_]std.posix.pollfd{.{ .fd = overview.done[0], .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 10_000) == 0) return error.TestUnexpectedResult;
            drain(overview.done[0]);
            if (try overview.complete()) |next| if (overview.proceed(next)) |ending| return ending;
        }
    }

    /// Services the overview as a conversation does, until no job it may
    /// start is left.
    fn lend(rig: *Rig) !void {
        const Worker = struct {
            fn completed(overview: *Self) !bool {
                return overview.worker.completed();
            }
        };
        const overview = rig.overview;
        for (0..100) |_| {
            _ = try service(overview);
            const queued = for (overview.jobs[0..overview.job_count]) |job| {
                if (job != .start) break true;
            } else false;
            if (overview.worker.thread == null and !queued) return;
            if (overview.worker.thread != null) try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), overview, Worker.completed);
        }
        return error.TestUnexpectedResult;
    }

    /// A full output pipe forces the real pump to consume the queued key
    /// before this reader grants credit. Never wait for draw to return before
    /// granting credit: benign navigation now completes the frozen write.
    fn completeAfterKey(rig: *Rig, comptime operation: enum { frame, background }, buffer: []u8, padding: usize) !struct { next: ?Next, written: []const u8 } {
        const Reading = struct {
            rig: *Rig,
            bytes: []u8,
            len: usize = 0,
            padding: usize,
            done: std.atomic.Value(bool) = .init(false),
            failed: bool = false,
            fn keyTaken(self: *@This()) !bool {
                var fds = [_]std.posix.pollfd{.{ .fd = self.rig.keys[0], .events = std.posix.POLL.IN, .revents = 0 }};
                return try std.posix.poll(&fds, 0) == 0;
            }
            fn drained(self: *@This()) bool {
                var bytes: [4096]u8 = undefined;
                while (true) {
                    const n = std.c.read(self.rig.output[0], &bytes, bytes.len);
                    if (n <= 0) return self.done.load(.acquire);
                    const skip = @min(self.padding, @as(usize, @intCast(n)));
                    self.padding -= skip;
                    const count: usize = @as(usize, @intCast(n)) - skip;
                    if (count > self.bytes.len - self.len) {
                        self.failed = true;
                    } else {
                        @memcpy(self.bytes[self.len..][0..count], bytes[skip..][0..count]);
                        self.len += count;
                    }
                }
            }
            fn run(self: *@This()) void {
                test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), self, keyTaken) catch {
                    self.failed = true;
                };
                test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), self, drained) catch {
                    self.failed = true;
                };
            }
        };
        var reading: Reading = .{ .rig = rig, .bytes = buffer, .padding = padding };
        const thread = try std.Thread.spawn(.{}, Reading.run, .{&reading});
        const next = switch (operation) {
            .frame => rig.overview.draw(0),
            .background => rig.overview.askBackground(),
        };
        reading.done.store(true, .release);
        thread.join();
        errdefer std.debug.print("credit reader failed={any} bytes={d}\n", .{ reading.failed, reading.len });
        try std.testing.expect(!reading.failed and reading.padding == 0);
        return .{ .next = try next, .written = buffer[0..reading.len] };
    }

    fn drawn(rig: *Rig, buffer: []u8) []const u8 {
        const count = std.c.read(rig.output[0], buffer.ptr, buffer.len);
        return if (count > 0) buffer[0..@intCast(count)] else "";
    }
};

test "the first pumped overview target is frozen while reports and split input retain their meaning" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const first = shownRow(rig, 0);
    const backend = rig.screen.backend;
    const stream = &rig.terminal.stream;
    const Gate = struct {
        rig: *Rig,
        first: view.Reference,
        captured: bool = false,
        credited: bool = false,
        fn step(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            try pump(gate.rig.overview);
            try std.testing.expect(!gate.rig.screen.backend.idle());
            try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, gate.rig.screen.backend.widthMethod());
            if (gate.rig.overview.pumped) |next| {
                try std.testing.expect(next == .open);
                try std.testing.expectEqualStrings(&gate.first, &next.open);
                if (!gate.captured) {
                    gate.captured = true;
                    // A second target, command, pasted Ctrl-C and ordinary
                    // text cannot overwrite the first target or mutate draft.
                    const tail = "\x1b[B\r/status\r\x1b[200~\x03\x1b[201~\x1b[?2027;3$y\x1b[";
                    try std.testing.expect(std.c.write(gate.rig.keys[1], tail, tail.len) == tail.len);
                }
            }
            var fds = [_]std.posix.pollfd{.{ .fd = gate.rig.keys[0], .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 0) != 0) return;
            try std.testing.expect(gate.captured);
            try std.testing.expectEqualStrings("", gate.rig.overview.composerDraft().bytes);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
            try std.testing.expectEqual(TerminalInput.Pending.incomplete, gate.rig.terminal.stream.pending());
            gate.credited = true;
            var sink: [65536]u8 = undefined;
            while (std.c.read(gate.rig.output[0], &sink, sink.len) > 0) {}
        }
    };
    var gate: Gate = .{ .rig = rig, .first = first };
    rig.terminal.pump = .{ .context = &gate, .step = Gate.step };
    defer rig.terminal.pump = null;
    const filler: [4096]u8 = @splat('x');
    while (std.c.write(rig.output[1], &filler, filler.len) > 0) {}
    while (std.c.write(rig.output[1], &filler, 1) > 0) {}
    try std.testing.expect(std.c.write(rig.keys[1], "\r", 1) == 1);
    {
        try backend.begin(.{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
        defer backend.end();
        errdefer backend.poison();
        const bytes = try backend.encode();
        const hash = std.hash.Wyhash.hash(0, bytes);
        try rig.terminal.write(bytes);
        try std.testing.expectEqual(hash, std.hash.Wyhash.hash(0, bytes));
        try std.testing.expect(gate.captured and gate.credited);
        try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, backend.widthMethod());
        try std.testing.expectEqual(vaxis.gwidth.Method.unicode, overview.caps.width);
    }
    rig.terminal.applyReports();
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, backend.widthMethod());
    try std.testing.expect(overview.proceed(overview.pumped.?) == null);
    try std.testing.expectEqualStrings(&first, &Seen.now.conversed);
    try std.testing.expect(rig.screen.backend == backend and &rig.terminal.stream == stream);
    const decoded = stream.feed('A', std.Io.Clock.awake.now(std.testing.io).nanoseconds);
    try std.testing.expect(decoded == .event and decoded.event.event.key_press.matchExact(vaxis.Key.up, .{}));
    try std.testing.expect(stream.next() == .none and stream.pending() == .none);
}

test "urgent overview exit and signal poison output before returning a normal leave" {
    for ([_]bool{ false, true }) |background| for ([_]bool{ false, true }) |signal| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        rig.overview.caps.depth = .indexed;
        rig.terminal.program_status = .supported;
        const batch = rig.terminal.beginStatuses();
        try std.testing.expect(rig.terminal.reportStatus("k7m2qx", "Frozen", .done));
        const filler: [4096]u8 = @splat('x');
        while (std.c.write(rig.output[1], &filler, filler.len) > 0) {}
        while (std.c.write(rig.output[1], &filler, 1) > 0) {}
        if (signal) cancellation.stopped.store(true, .release) else try std.testing.expect(std.c.write(rig.keys[1], "\r\x03", 2) == 2);
        const started = std.Io.Clock.awake.now(std.testing.io);
        const next = if (background) try rig.overview.askBackground() else try rig.overview.draw(0);
        try std.testing.expect(next.? == .leave);
        try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started.nanoseconds < std.time.ns_per_s);
        try std.testing.expect(!rig.terminal.statusesTaken(batch));
        try std.testing.expectError(error.RenderBackendPoisoned, rig.screen.backend.begin(.{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 }));
    };
}

test "a background query completes its captured open before waiting for reports" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    rig.overview.caps.depth = .indexed;
    const filler: [4096]u8 = @splat('x');
    var padding: usize = 0;
    while (true) {
        const n = std.c.write(rig.output[1], &filler, filler.len);
        if (n <= 0) break;
        padding += @intCast(n);
    }
    while (std.c.write(rig.output[1], &filler, 1) > 0) padding += 1;
    try std.testing.expect(std.c.write(rig.keys[1], "\r", 1) == 1);
    var bytes: [256]u8 = undefined;
    const completed = try rig.completeAfterKey(.background, &bytes, padding);
    try std.testing.expect(completed.next.? == .open);
    try std.testing.expectEqualStrings(&shownRow(rig, 0), &completed.next.?.open);
    try std.testing.expectEqualStrings("\x1b]11;?\x1b\\\x1b[c", completed.written);
    try std.testing.expect(!rig.overview.asking and rig.overview.pumped == null);
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
    try std.testing.expect(try rig.press("/configure --permission-mode ask --label \"lane four\"\n") == null);
    try std.testing.expect(try rig.press("hello\n") == null);
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
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.stopped);

    // Enter on an empty composer opens it; Ctrl-D leaves.
    try std.testing.expect(try rig.press("\n") == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    const ending = (try rig.press("\x04")).?;
    try std.testing.expect(ending == .overview);
}

test "/model reads the lists on the worker, the sign-in choice takes the arrows, and the pick is saved and starts the next Session" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.model_lists);
    // Down to gpt-6-luna, which both sign-ins offer: Enter shows the choice
    // at the default's sign-in, Right moves it, and Enter picks.
    try std.testing.expect(try rig.press("\x1b[B\n") == null);
    try std.testing.expect(overview.state.inputMode() == .choice);
    try std.testing.expect(try rig.press("\x1b[C\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(view.Provider.openai, Seen.now.saved.?.provider);
    try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.saved.?.model.slice());
    try std.testing.expect(overview.state.picker == null);
    // The next Session takes the pick.
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("openai", Seen.now.start.provider.?.slice());
    try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.start.model.?.slice());
}

test "any key at the sign-in choice cancels a stop prompt, arrows and ignored keys alike" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = listed_references.len;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    // A working Session, which Ctrl-X asks to stop.
    overview.state.selected = shownRow(rig, 2);
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[B\n") == null);
    try std.testing.expect(overview.state.inputMode() == .choice);
    try std.testing.expect(try rig.press("\x18") == null);
    try std.testing.expect(overview.state.prompt != null);
    // Arrows, and keys the choice ignores: Backspace, Delete, Tab.
    for ([_][]const u8{ "\x1b[D", "\x1b[C", "\x7f", "\x1b[3~", "\t" }) |arrow| {
        try std.testing.expect(try rig.press(arrow) == null);
        try std.testing.expect(overview.state.prompt == null);
        // Ctrl-X asks again rather than stopping.
        try std.testing.expect(try rig.press("\x18") == null);
        try std.testing.expect(overview.state.prompt != null);
    }
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
}

test "a save still queued as the overview ends runs, and the way out names it" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    // Down to gpt-6-luna, which both sign-ins offer: Enter opens the choice, Enter picks.
    try std.testing.expect(try rig.press("\x1b[B\n\n") == null);
    try std.testing.expectEqual(Job.save, std.meta.activeTag(rig.overview.jobs[rig.overview.job_count - 1]));
    var buffer: [1024]u8 = undefined;
    const guidance = try finishedGuidance(rig, &buffer);
    try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.saved.?.model.slice());
    try std.testing.expect(std.mem.indexOf(u8, guidance, "gpt-6-luna") != null);
}

/// Fake operations whose saves write the preferences file under the
/// overview's home, counted in `Seen.now.saves`.
const file_saving_operations: Operations = blk: {
    var ops = fake_operations;
    ops.save_default = struct {
        fn save(self: *Self, binding: view.Default) !void {
            Seen.now.saves += 1;
            try saveDefault(self, binding);
        }
    }.save;
    break :blk ops;
};

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
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = if (pinned) "openai" else "codex", .model = if (pinned) "gpt-6-luna" else "gpt-5.5" }, file_saving_operations, &cancellation);
        defer rig.close();
        var buffer: [1024]u8 = undefined;
        const guidance = try finishedGuidance(rig, &buffer);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.saves);
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
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, file_saving_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.settle() == null);
    try pin(home, "openai", "gpt-6-luna");
    var buffer: [1024]u8 = undefined;
    _ = try finishedGuidance(rig, &buffer);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.saves);
    const values = try preferences.load(home);
    try std.testing.expectEqualStrings("openai", values.provider.slice());
    try std.testing.expectEqualStrings("gpt-6-luna", values.model.slice());
}

test "a pick made while a save runs is written before the departure, which names only it" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    // Down to gpt-6-luna; Enter opens the sign-in choice, Enter picks ChatGPT.
    try std.testing.expect(try rig.press("\x1b[B\n\n") == null);
    // Its save starts, and nothing answers it before the next pick.
    try overview.dispatch(.all);
    try std.testing.expect(overview.worker.thread != null and overview.job == .save);
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-6.1-sol\n" } } }}) } }) == null);
    try std.testing.expect(try rig.press("\x1b[B\n") == null);
    try std.testing.expectEqualStrings("gpt-6.1-sol", overview.state.default.?.model.slice());
    var buffer: [1024]u8 = undefined;
    const guidance = try finishedGuidance(rig, &buffer);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.saves);
    try std.testing.expectEqualStrings("gpt-6.1-sol", Seen.now.saved.?.model.slice());
    try std.testing.expect(std.mem.indexOf(u8, guidance, "New Sessions use gpt-6.1-sol") != null);
    try std.testing.expect(std.mem.indexOf(u8, guidance, "gpt-6-luna") == null);
}

test "a pick after /configure --model starts the pick, not the held model" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-6.1-sol" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("/configure --model gpt-5.5\n") == null);
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    // The held model leads; Down to gpt-6-luna, Enter shows the sign-in
    // choice at ChatGPT, and Enter picks.
    try std.testing.expect(try rig.press("\x1b[B\n\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.saved.?.model.slice());
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("codex", Seen.now.start.provider.?.slice());
    try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.start.model.?.slice());
}

test "a paste the composer rejects at the sign-in choice leaves the choice, and typing after it starts a Session" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    // Down to gpt-6-luna, which both sign-ins offer: Enter shows the choice.
    try std.testing.expect(try rig.press("\x1b[B\n") == null);
    try std.testing.expect(rig.overview.state.inputMode() == .choice);
    // A standalone combining mark, which the composer cannot add alone.
    try std.testing.expect(try rig.press("\x1b[200~\xcc\x81\x1b[201~") == null);
    try std.testing.expect(rig.overview.state.picker == null);
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    try std.testing.expectEqualStrings("hello", Seen.now.start.text.slice());
    try std.testing.expect(Seen.now.saved == null);
}

test "a model list the Host cannot answer and one Rui cannot read reach the core apart" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try rig.press("/model\n") == null);
    overview.job = .models;
    try std.testing.expect(try overview.deliver(error.ConnectionRefused) == null);
    try std.testing.expect(overview.state.menu_read == .unanswered);
    try std.testing.expect(try overview.deliver(error.InvalidModelList) == null);
    try std.testing.expect(overview.state.menu_read == .invalid);
}

test "a start with no saved binding names no model, so the Host refuses it" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("hello\n") == null);
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

test "a start with no held loaded tools sends none" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("hello\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(Seen.now.start.loaded_tools == null);
}

test "the save's notice names the effort the next start applies, as the start sends it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-5.5" }, .reasoning_effort = .{ .set = .max } }, &.initFill(.configured));
    // gpt-6-luna offers max and gpt-5.5 does not; Down reaches gpt-6-luna
    // and Enter alone keeps gpt-5.5, each then picked with ChatGPT.
    const Case = struct { explicit: bool = false, configure: ?[]const u8 = null, keys: []const u8, notice: []const u8, sent: ?[]const u8 };
    const cases = [_]Case{
        .{ .keys = "\x1b[B\n\n", .notice = "New Sessions use gpt-6-luna · max · ChatGPT", .sent = "max" },
        .{ .explicit = true, .keys = "\x1b[B\n\n", .notice = "New Sessions use gpt-6-luna · ChatGPT", .sent = null },
        .{ .configure = "/configure --reasoning-effort low\n", .keys = "\x1b[B\n\n", .notice = "New Sessions use gpt-6-luna · ChatGPT", .sent = "low" },
        .{ .keys = "\n\n", .notice = "New Sessions use gpt-5.5 · ChatGPT", .sent = null },
    };
    for (cases) |case| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5", .selectors = if (case.explicit) explicit_selectors else .{} }, file_saving_operations, &cancellation);
        defer rig.close();
        if (case.configure) |line| try std.testing.expect(try rig.press(line) == null);
        try std.testing.expect(try rig.press("/model\n") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(try rig.press(case.keys) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.saves);
        try std.testing.expectEqualStrings(case.notice, rig.overview.state.notice.?.text());
        try std.testing.expect(try rig.press("hello\n") == null);
        try std.testing.expect(try rig.settle() == null);
        if (case.sent) |effort| try std.testing.expectEqualStrings(effort, Seen.now.start.reasoning_effort.?.slice()) else try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.start.reasoning_effort.?.slice());
    }
}

test "the departure names the effort saved now, even after a launch that named its binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var ops = file_saving_operations;
    ops.save_default = struct {
        fn save(self: *Self, binding: view.Default) !void {
            Seen.now.saves += 1;
            try saveDefault(self, binding);
            return error.PreferenceDirectorySyncFailed;
        }
    }.save;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5", .selectors = .{ .store = "/store", .provider = "codex", .model = "gpt-5.5" } }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    // Down to gpt-6-luna, picked with ChatGPT; max is saved before the
    // person leaves and the save ends.
    try std.testing.expect(try rig.press("\x1b[B\n\n") == null);
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .max } }, &.initFill(.configured));
    var buffer: [1024]u8 = undefined;
    const guidance = try finishedGuidance(rig, &buffer);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.saves);
    try std.testing.expect(std.mem.indexOf(u8, guidance, "rui: New Sessions use gpt-6-luna · max · ChatGPT; durability unconfirmed") != null);
}

test "an unreadable preferences file leaves the effort out of the notice and refuses the start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .max } }, &.initFill(.configured));
    var config = try tmp.dir.openDir(std.testing.io, ".config/rui", .{});
    defer config.close(std.testing.io);
    const bad = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
    try bad.writeStreamingAll(std.testing.io, "version=1\n");
    bad.close(std.testing.io);
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, file_saving_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("/model\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[B\n\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("Default not saved (check ~/.config/rui/preferences); new Sessions here still use gpt-6-luna · ChatGPT", rig.overview.state.notice.?.text());
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    try std.testing.expectEqualStrings("! Not started: InvalidPreferences", rig.overview.state.notice.?.text());
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
        try std.testing.expect(try rig.press("hello\n") == null);
        try std.testing.expect(try rig.settle() == null);
        if (explicit) try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.start.reasoning_effort.?.slice()) else try std.testing.expectEqualStrings("high", Seen.now.start.reasoning_effort.?.slice());
    }
    // A launch that named everything starts even over an unreadable file.
    var config = try tmp.dir.openDir(std.testing.io, ".config/rui", .{});
    defer config.close(std.testing.io);
    const bad = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
    try bad.writeStreamingAll(std.testing.io, "version=1\n");
    bad.close(std.testing.io);
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = explicit_selectors }, fake_operations, &cancellation);
    defer rig.close();
    const starts = Seen.now.starts;
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(starts + 1, Seen.now.starts);
}

test "the loop opens the resumed Session first, lists on its tick, draws once and leaves on Ctrl-D" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .open = "k7m2qx".* }, fake_operations, &cancellation);
    defer rig.close();
    // The overview asks for the background whatever the test's environment
    // says about colour. The terminal answers the question's DA1 first,
    // without a background; Ctrl-D waits behind it until the overview has
    // drawn.
    rig.overview.caps.depth = .indexed;
    const keys = "\x1b[?1;2;4c\x04";
    if (std.c.write(rig.keys[1], keys, keys.len) != keys.len) return error.TestUnexpectedResult;
    try std.testing.expect(try rig.overview.loop() == .overview);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    // The first tick listed: the worker took the Host read.
    rig.overview.worker.join() catch {};
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    var buffer: [64 * 1024]u8 = undefined;
    const written = rig.drawn(&buffer);
    const question = "\x1b]11;?\x1b\\\x1b[c";
    try std.testing.expect(std.mem.startsWith(u8, written, question));
    const frame = written[question.len..];
    // The backend may stage resize controls before its synchronized render.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[?2026l" ++ vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset));
    // The terminal already shows an unchanged screen. The Host read may
    // have answered after that frame, so draw what it changed first.
    try std.testing.expect(try rig.overview.draw(0) == null);
    _ = rig.drawn(&buffer);
    try std.testing.expect(try rig.overview.draw(0) == null);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
}

test "each frame rewrites your working Session's spinner alone, and without colour it holds still" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{};
    // The listed row is yours and working, so its mark is the spinner, at
    // the frame's step.
    try std.testing.expect(try overview.event(.{ .tick = (test_now_s - 10) * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(2) == null and overview.spins);
    const first = rig.drawn(&buffer);
    const first_len = first.len;
    try std.testing.expect(first_len != 0);
    try std.testing.expect(try overview.draw(2) == null and overview.spins);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
    try std.testing.expect(try overview.draw(3) == null and overview.spins);
    const turned = rig.drawn(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, turned, view.spinner[3]) != null);
    try std.testing.expect(turned.len < first_len);
    try std.testing.expect(std.mem.indexOf(u8, turned, "Type a task") == null);
    overview.caps = .{ .depth = .none };
    try std.testing.expect(try overview.draw(4) == null and !overview.spins);
}

test "the loop waits for the core's next tick, and while the screen spins no later than its next frame" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const start = test_now_s * 1000;
    // While a listing is in flight the core needs no tick.
    try std.testing.expect(try overview.event(.{ .tick = start }) == null);
    try std.testing.expectEqual(@as(i32, -1), overview.budget(start, 280, false));
    try std.testing.expectEqual(@as(i32, 120), overview.budget(start, 280, true));
    try std.testing.expectEqual(@as(i32, 1), overview.budget(start, 399, true));
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(i32, 100), overview.budget(start + 900, 40, false));
    try std.testing.expectEqual(@as(i32, 100), overview.budget(start + 900, 40, true));
    try std.testing.expectEqual(@as(i32, 10), overview.budget(start + 990, 40, true));
    try std.testing.expectEqual(@as(i32, 0), overview.budget(start + 1000, 40, true));
}

test "a signal wakes the waiting loop and ends it" {
    const Raise = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn host(_: *Self) ?view.Host {
            std.posix.raise(std.posix.SIG.TERM) catch {};
            // Only the signal's wake can end the loop's wait.
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            return null;
        }
    };
    var ops = fake_operations;
    ops.host = Raise.host;
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &Signals.cancellation);
    defer rig.close();
    defer Raise.release.store(true, .release);
    Signals.cancellation.stopped.store(false, .release);
    defer Signals.cancellation.stopped.store(false, .release);
    Signals.wake = rig.overview.signalled[1];
    Signals.install(true);
    defer Signals.install(false);
    try std.testing.expect(try rig.overview.loop() == .overview);
    try std.testing.expect(Signals.cancellation.stopped.load(.acquire));
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
    try std.testing.expect(try rig.press("hello\n") == null);
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

test "Ctrl-C ends the overview while the terminal takes no output" {
    const Blocked = struct {
        var release: std.atomic.Value(bool) = .init(false);
        var drained: std.atomic.Value(bool) = .init(false);
        /// Frees the terminal only if the overview has not left within two
        /// seconds.
        fn drain(fd: c_int) void {
            const io = std.testing.io;
            test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(2)), &release, test_poll.isSet) catch {
                drained.store(true, .release);
                var bytes: [4096]u8 = undefined;
                while (std.c.read(fd, &bytes, bytes.len) > 0) {}
            };
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const zeros: [4096]u8 = @splat(0);
    while (std.c.write(rig.output[1], &zeros, zeros.len) > 0) {}
    if (std.c.write(rig.keys[1], "\x03", 1) != 1) return error.TestUnexpectedResult;
    Blocked.release.store(false, .release);
    Blocked.drained.store(false, .release);
    const drainer = try std.Thread.spawn(.{}, Blocked.drain, .{rig.output[0]});
    const ended = rig.overview.loop();
    Blocked.release.store(true, .release);
    drainer.join();
    try std.testing.expect(try ended == .overview);
    try std.testing.expect(!Blocked.drained.load(.acquire));
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
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
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
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    // A stop still running as the overview ends is named the same way.
    const running = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer running.close();
    try std.testing.expect(try running.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try running.settle() == null);
    try std.testing.expect(try running.press("\x1b[H\x18\x18") == null);
    try running.overview.dispatch(.all);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(running.overview.job));
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(guidance, try finishedGuidance(running, &buffer));
}

/// Runs `finish` over a terminal whose restore failed, which writes nothing
/// to stdout, and returns what it wrote to stderr.
fn finishedGuidance(rig: *Rig, buffer: []u8) ![]const u8 {
    return finishedWith(rig, .overview, error.TerminalRestoreFailed, error.TerminalRestoreFailed, buffer);
}

/// Runs `finish` on `ending` over a terminal whose restore ended with
/// `restored`, expecting `failure`, and returns what it wrote to stderr.
fn finishedWith(rig: *Rig, ending: Ending, restored: anyerror!void, failure: anyerror, buffer: []u8) ![]const u8 {
    rig.terminal.active = false;
    rig.terminal.result = restored;
    var pipe: [2]c_int = undefined;
    try openPipe(&pipe);
    defer for (pipe) |fd| {
        _ = std.c.close(fd);
    };
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    const finished = rig.overview.finish(ending);
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    try std.testing.expectError(failure, finished);
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
    try conversed(overview, .working, .stop);
    try std.testing.expectEqual(view.Prompt.Action.stop, conversationLine(overview, .working).asking.?);
    try conversed(overview, .working, .stop);
    // The Host read already running answers first; the stop goes before
    // the page queued ahead of it.
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(overview.job));
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    // The listing goes on under the conversation, so its news notifies; the
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
    const left: Left = .{ .session = "k7m2qx".*, .frontend = null, .files = null, .ended = error.CanonicalStoreFailure };
    try std.testing.expectEqualStrings("", try finishedWith(failing, .{ .conversation = left }, error.TerminalRestoreFailed, error.CanonicalStoreFailure, &buffer));
}

test "a finish the conversation notified is no news to the listing that reads it after Esc, out of focus" {
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    try std.testing.expect(try rig.press("\x1b[O") == null);
    // The overview opens on k7m2qx working.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("", rig.terminal.takeNotification());
    // Its conversation reads the finish before any listing does.
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 }, "Fix the flaky test", false);
    try std.testing.expectEqualStrings("\x1b]9;Rui: Fix the flaky test finished\x07", rig.terminal.takeNotification());
    // Esc, back in focus, then away again before the listing catches up.
    try std.testing.expect(try rig.press("\x1b[I") == null);
    try std.testing.expect(try rig.press("\x1b[O") == null);
    Listing.finished = true;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(overview.state.find("k7m2qx".*).?.state == .finished);
    try std.testing.expectEqualStrings("", rig.terminal.takeNotification());
}

test "a terminal that answers the program status probe gets each Session's record, and no notification" {
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    // The probe's answer and the device attributes behind it are reports:
    // the composer takes none of their bytes, nor the key after them.
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22cx\x1b[O") == null);
    try std.testing.expectEqualStrings("x", overview.composerDraft().bytes);
    try std.testing.expect(try rig.press("\x7f") == null);
    // The overview opens on k7m2qx working: its record, named by its first
    // line once read, while away. No notification.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(0) == null);
    var written = rig.drawn(&buffer);
    const working = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, written, working) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?2026h").? > std.mem.indexOf(u8, written, working).?);
    // Its finish replaces the record and writes no OSC 9, away as it is.
    Listing.finished = true;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    written = rig.drawn(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]9;") == null);
    // The conversation reading it first gives no OSC 9 either.
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 }, "Fix the flaky test", false);
    try std.testing.expectEqualStrings("", rig.terminal.takeNotification());
    // Opening the Session shows the person its outcome.
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    try std.testing.expect(try overview.draw(0) == null);
    written = rig.drawn(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    // Turned off, Rui clears its records; turned on, it sets them again.
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    Listing.finished = false;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    written = rig.drawn(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=clear:id=rui\x1b\\\x1b[?2026h"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    written = rig.drawn(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    _ = try preferences.update(home, .{ .notifications = true }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 240_000 }) == null);
    try std.testing.expect(try overview.draw(0) == null);
    written = rig.drawn(&buffer);
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), "\x1b]7501;state=clear:id=rui\x1b\\\x1b[?2026h"));
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    const by_line = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), by_line) != null);
    // Named while it still works: the record keeps its state, under the Label.
    Listing.label = "Lane four";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=TGFuZSBmb3Vy\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;") == null);
    // The Label cleared, its first line names it again.
    Listing.label = null;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), by_line));
}

test "opening during a blocked frame completes and acknowledges its records before handoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished = false;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (finished) for (page.rows[0..page.count]) |*row| {
                row.work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 };
            };
            return null;
        }
    };
    Listing.finished = false;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    Seen.now.listed = 2;
    const overview = rig.overview;
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;state=working:id=rui/b4n8wd:") != null);
    // Both finish; the terminal takes no output, and Enter opens one
    // while the frozen frame with their records waits for output credit.
    Listing.finished = true;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const filler: [4096]u8 = @splat('x');
    var padding: usize = 0;
    while (true) {
        const n = std.c.write(rig.output[1], &filler, filler.len);
        if (n <= 0) break;
        padding += @intCast(n);
    }
    while (std.c.write(rig.output[1], &filler, 1) > 0) padding += 1;
    try std.testing.expect(std.c.write(rig.keys[1], "\r", 1) == 1);
    const completed = try rig.completeAfterKey(.frame, &buffer, padding);
    const next = completed.next.?;
    try std.testing.expect(rig.terminal.statusesTaken(overview.sending.batch.?));
    try std.testing.expect(std.mem.indexOf(u8, completed.written, "\x1b]7501;state=done:id=rui/") != null);
    try std.testing.expect(overview.proceed(next) == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 61_000 }) == null);
    try std.testing.expect(try overview.draw(0) == null);
    const written = rig.drawn(&buffer);
    const other = if (std.mem.eql(u8, &next.open, "k7m2qx")) "b4n8wd" else "k7m2qx";
    var record: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, written, try std.fmt.bufPrint(&record, "\x1b]7501;state=done:id=rui/{s}:", .{other})) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, try std.fmt.bufPrint(&record, "\x1b]7501;state=idle:id=rui/{s}:", .{&next.open})) != null);
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    const done = "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    const blocked = "\x1b]7501;state=blocked:id=rui/k7m2qx:app=rui:kind=permission:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
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
        try std.testing.expect(try overview.draw(0) == null);
        const written = rig.drawn(&buffer);
        if (listing.record) |record|
            try std.testing.expect(std.mem.startsWith(u8, written, record))
        else
            try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    }
}

test "opening during a blocked clear acknowledges it once before handoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    // Turned off; Enter captures a target while the clear waits for credit.
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 1_000 }) == null);
    const filler: [4096]u8 = @splat('x');
    var padding: usize = 0;
    while (true) {
        const n = std.c.write(rig.output[1], &filler, filler.len);
        if (n <= 0) break;
        padding += @intCast(n);
    }
    while (std.c.write(rig.output[1], &filler, 1) > 0) padding += 1;
    try std.testing.expect(std.c.write(rig.keys[1], "\r", 1) == 1);
    const completed = try rig.completeAfterKey(.frame, &buffer, padding);
    const next = completed.next.?;
    try std.testing.expect(rig.terminal.statusesTaken(overview.sending.batch.?));
    try std.testing.expect(std.mem.indexOf(u8, completed.written, "\x1b]7501;state=clear:id=rui\x1b\\") != null);
    try std.testing.expect(overview.proceed(next) == null);
    // The complete frozen frame already carried the clear; no retry.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 2_000 }) == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;state=clear:id=rui\x1b\\") == null);
    // Nothing more goes while they stay off.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;") == null);
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    // Opened on Turn 1's finish, then a listing that reads it again: no record.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;") == null);
    // Turn 2 finishes and its conversation reads that before any listing.
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 }, "Fix the flaky test", false);
    try std.testing.expectEqualStrings("", rig.terminal.takeNotification());
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
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
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    // Turn 1 finishes; the person opens the Session before a listing reads
    // that, and its conversation opens on the finish.
    Listing.finished_turn = 1;
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 }, "Fix the flaky test", true);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    // Back on the overview, later listings of that finish leave the record.
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "\x1b]7501;") == null);
    // Turn 2's finish, which the person has not opened, is done.
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.drawn(&buffer), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
}

test "a terminal that answers device attributes before the probe keeps the notification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    rig.terminal.program_status = .asking;
    // A late answer to the probe changes nothing.
    try std.testing.expect(try rig.press("\x1b[?62;22c\x1b]7501;?\x1b\\\x1b[O") == null);
    try std.testing.expectEqualStrings("", overview.composerDraft().bytes);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 }, "Fix the flaky test", false);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(0) == null);
    const written = rig.drawn(&buffer);
    const notice = "\x1b]9;Rui: Fix the flaky test finished\x07";
    try std.testing.expect(std.mem.startsWith(u8, written, notice));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written[notice.len..], "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, written, vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset));
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    // The background question's device attributes answer still ends its
    // wait.
    overview.asking = true;
    try std.testing.expect(try rig.press("\x1b[?62;22c") == null);
    try std.testing.expect(!overview.asking);
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
    try std.testing.expect(try finished.press("\x1b[H\x18\x18") == null);
    try finished.overview.dispatch(.all);
    var fds = [_]std.posix.pollfd{.{ .fd = finished.overview.done[0], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 10_000));
    try std.testing.expect(try finished.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    finished.overview.opened = "k7m2qx".*;
    try finished.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(finished.overview, .working).text.?);

    // A stop still queued when the conversation opened goes before the
    // listing queued ahead of it.
    const queued = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer queued.close();
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try queued.settle() == null);
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try queued.press("\x1b[H\x18\x18") == null);
    queued.overview.opened = "k7m2qx".*;
    _ = try service(queued.overview);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(queued.overview.job));
    try queued.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(queued.overview, .working).text.?);
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
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: Not sure the new Session started. Check with: rui request recover lost-handle\n", try finishedGuidance(rig, &buffer));
}

test "a conversation ended by its Host stopping says how to start it again" {
    const Down = struct {
        var stopped: bool = false;
        fn host(_: *Self) bool {
            return stopped;
        }
    };
    var ops = fake_operations;
    ops.stopped = Down.host;
    ops.converse = converse;
    var cancellation: client.Cancellation = .{};
    var buffer: [1024]u8 = undefined;
    // Not stopped covers a Host that runs or owns the Store but does not
    // answer discovery: neither shows that it stopped.
    for ([_]bool{ true, false }) |stopped| {
        Down.stopped = stopped;
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        rig.overview.hooks.scratch = struct {
            fn scratch(_: std.process.Init) !std.Io.File {
                return error.FileNotFound;
            }
        }.scratch;
        try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        const ending = (try rig.press("\x1b[H\n")).?;
        const resume_line = "\nResume: rui session resume --store $'/store' k7m2qx\n";
        if (stopped) {
            const written = try finishedWith(rig, ending, {}, error.HostStopped, &buffer);
            try std.testing.expectEqualStrings("\nrui: The Host stopped. Run rui host start --store $'/store', then resume this Session.\n" ++ resume_line, written);
        } else {
            const written = try finishedWith(rig, ending, {}, error.FileNotFound, &buffer);
            try std.testing.expectEqualStrings(resume_line, written);
        }
    }
}

test "a conversation that fails to open still names the unconfirmed start on departure" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) !void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.start;
    ops.converse = converse;
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
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    const ending = (try rig.press("\x1b[H\n")).?;
    try std.testing.expect(ending.conversation.frontend == null);
    var buffer: [1024]u8 = undefined;
    const written = try finishedWith(rig, ending, error.TerminalRestoreFailed, error.AccessDenied, &buffer);
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
    ops.converse = converse;
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
    var fds = [_]std.posix.pollfd{.{ .fd = overview.done[0], .events = std.posix.POLL.IN, .revents = 0 }};
    try overview.dispatch(.all);
    try std.testing.expectEqual(Job.host, std.meta.activeTag(overview.job));
    if (try std.posix.poll(&fds, 10_000) == 0) return error.TestUnexpectedResult;
    drain(overview.done[0]);
    try std.testing.expect(try overview.complete() == null);
    // The listing fails on the worker, and the conversation's first step
    // under it collects the failure.
    try overview.dispatch(.all);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    if (try std.posix.poll(&fds, 10_000) == 0) return error.TestUnexpectedResult;
    const ending = overview.proceed(.{ .open = "k7m2qx".* }).?;
    try std.testing.expectError(error.CanonicalStoreFailure, ending.conversation.ended);
    try std.testing.expect(ending.conversation.frontend != null);
    // The terminal stays lent until `finish` restores it.
    try std.testing.expect(rig.terminal.active and rig.terminal.pump == null);
    var buffer: [4096]u8 = undefined;
    const written = try finishedWith(rig, ending, {}, error.CanonicalStoreFailure, &buffer);
    // The failure is the overview's: no guidance to resume the Session.
    try std.testing.expectEqualStrings("", written);
}

test "leaving while a start is queued or running says what became of it" {
    var cancellation: client.Cancellation = .{};
    var buffer: [1024]u8 = undefined;
    // Enter and Ctrl-C in one read: the start is queued and never sent.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect((try rig.press("race start\n\x03")).? == .overview);
        try std.testing.expectEqualStrings("rui: The new Session did not start.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    }
    // The start ran as the overview ended: the Host accepted it.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("hello\n") == null);
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
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
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
    try std.testing.expect((try rig.press("\x1b[H\x18\x18\x03")).? == .overview);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: k7m2qx was not stopped.\n", try finishedGuidance(rig, &buffer));
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
}

test "any input but Ctrl-X ends the stop prompt, whether or not it changed the draft" {
    var cancellation: client.Cancellation = .{};
    // On an empty composer Backspace, Left and PageUp change nothing; while
    // a start holds the draft the editor takes nothing at all.
    for ([_]struct { draft: []const u8 = "", key: []const u8 }{ .{ .key = "\x7f" }, .{ .key = "\x1b[D" }, .{ .key = "\x1b[5~" }, .{ .draft = "held\r", .key = "a" } }) |case| {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        if (case.draft.len != 0) try std.testing.expect(try rig.press(case.draft) == null);
        try std.testing.expect(try rig.press("\x1b[H\x18") == null);
        try std.testing.expectEqualStrings("k7m2qx", &rig.overview.state.prompt.?.stop);
        try std.testing.expect(try rig.press(case.key) == null);
        try std.testing.expect(rig.overview.state.prompt == null);
        // The next Ctrl-X asks afresh and stops nothing.
        try std.testing.expect(try rig.press("\x18") == null);
        try std.testing.expectEqualStrings("k7m2qx", &rig.overview.state.prompt.?.stop);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
    }
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
}

test "Shift-Enter and Alt-Enter add a line in every encoding, and a paste keeps its line ends" {
    const rig = try openComposer();
    defer rig.close();
    for ([_][]const u8{ "\x1b\r", "\x1b\n", "\x1b[13;2u", "\x1b[13;2;13u", "\x1b[13:13;2u", "\x1b[27;2;13~", "\x1b[13;3u", "\x1b[13;3;13u", "\x1b[27;3;13~" }) |chord| {
        var bytes: [32]u8 = undefined;
        try expectStarted(rig, try std.fmt.bufPrint(&bytes, "one{s}two\r", .{chord}), "one\ntwo");
    }
    try expectStarted(rig, "\x1b[200~one\ntwo\n\x1b[201~\r", "one\ntwo\n");
    try std.testing.expectEqual(@as(usize, 10), Seen.now.starts);
}

test "a draft past the editor's capacity starts nothing" {
    const rig = try openComposer();
    defer rig.close();
    const pasted = "\x1b[200~" ++ @as([SessionInput.capacity + 1]u8, @splat('x')) ++ "\x1b[201~\r";
    try expectStarted(rig, pasted, null);
    try std.testing.expectEqualStrings("! Too long to send.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "next\r", "next");
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
    try expectStarted(rig, "junk\x02\x1b[27uok\r", "ok");
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
    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1b[H", "\x1b[F" }) |key| {
        rig.overview.state.selected = null;
        try std.testing.expect(try rig.press(key) == null);
        try std.testing.expectEqualStrings("k7m2qx", &(rig.overview.state.selected orelse return error.TestExpectedSelection));
    }
    // Esc clears the draft; the start still sends what Enter captured.
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.composer.length);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    try std.testing.expectEqualStrings("hello", Seen.now.start.text.slice());
    // The next frame shows the empty composer, not the text it sent.
    try std.testing.expect(try rig.overview.draw(0) == null);
    var buffer: [64 * 1024]u8 = undefined;
    const frame = rig.drawn(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Type a task to start a Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "hello") == null);
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
    rig.overview.state.selected = shownRow(rig, 2);
    return rig;
}

/// The Session shown at `at` in screen order.
fn shownRow(rig: *const Rig, at: usize) view.Reference {
    const state = &rig.overview.state;
    return state.rows.items[state.order.items[at]].reference;
}

test "Tab completes from the draft's own list, however many keys arrive before a frame" {
    const rig = try openComposer();
    defer rig.close();
    try std.testing.expect(try rig.press("/he\t") == null);
    try std.testing.expectEqualStrings("/help", rig.overview.composerDraft().bytes);
    // Two Tabs in one batch: the second completes from the list the first
    // one's word calls for.
    rig.overview.composer = rig.overview.emptyComposer(rig.overview.composer.edits +% 1);
    try std.testing.expect(try rig.press("/conf\t\t") == null);
    try std.testing.expectEqualStrings("/configure --permission-mode ", rig.overview.composerDraft().bytes);
}

test "Shift-Up and Shift-Down select the row above and below, whatever the draft holds" {
    const rig = try openListed();
    defer rig.close();
    for ([_][]const u8{ "", "two\x1b\rlines", "junk\x00" }) |draft| {
        for ([_]struct { bytes: []const u8, row: usize }{
            .{ .bytes = "\x1b[1;2A", .row = 1 },
            .{ .bytes = "\x1b[1;2:1A", .row = 1 },
            .{ .bytes = "\x1b[1;2B", .row = 3 },
            .{ .bytes = "\x1b[1;2:1B", .row = 3 },
        }) |case| {
            errdefer std.debug.print("draft={s} key={s}\n", .{ draft, case.bytes[1..] });
            rig.overview.composer = rig.overview.emptyComposer(rig.overview.composer.edits +% 1);
            try std.testing.expect(try rig.press(draft) == null);
            rig.overview.state.selected = shownRow(rig, 2);
            try std.testing.expect(try rig.press(case.bytes) == null);
            try std.testing.expectEqualStrings(&shownRow(rig, case.row), &(rig.overview.state.selected orelse return error.TestExpectedSelection));
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

/// The key a lone editor reads `bytes` as, a lone ESC once it expires.
fn keyOf(bytes: []const u8) !?keymap.Key {
    var storage: [8]u8 = undefined;
    var editor: TerminalEditor = .{ .buffer = &storage };
    var input: TerminalInput = .{};
    var found: ?keymap.Key = null;
    for (bytes) |byte| {
        var decoded = input.feed(byte, 0);
        while (decoded != .none) : (decoded = input.next()) switch (editor.apply(keymap.every, decoded)) {
            .action => |key| found = key,
            else => {},
        };
    }
    if (input.pending() == .escape) switch (editor.apply(keymap.every, try input.expire())) {
        .action => |key| found = key,
        else => {},
    };
    return found;
}

/// Presses `bytes`, then lets a lone ESC expire into Esc, as the loop does.
fn pressKey(rig: *Rig, bytes: []const u8) !?Ending {
    if (try rig.press(bytes)) |ending| return ending;
    const Expiry = struct {
        fn done(overview: *Self) !bool {
            if (try overview.readInput(0, 1) != null) return error.TestUnexpectedResult;
            return overview.terminal.stream.pending() == .none;
        }
    };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), rig.overview, Expiry.done);
    return null;
}

test "every key does what the overview's table says, through the editor, in every encoding, on an empty and on a rejected draft" {
    for (std.enums.values(keymap.Key)) |key| for (key_encodings.get(key)) |bytes| for ([_][]const u8{ "", "\x00" }) |draft| {
        errdefer std.debug.print("key={s} bytes={s} draft={s}\n", .{ @tagName(key), bytes[1..], draft });
        try std.testing.expectEqual(@as(?keymap.Key, key), try keyOf(bytes));
        const rig = try openListed();
        defer rig.close();
        try std.testing.expect(try rig.press("/configure --permission-mode ask\r") == null);
        try std.testing.expect(try rig.press(draft) == null);
        const ending = try pressKey(rig, bytes);
        const state = &rig.overview.state;
        const selected = state.selected orelse return error.TestExpectedSelection;
        const action = view.keys.get(key) orelse {
            // Nothing happens, and the line is not rejected by it.
            try std.testing.expect(ending == null);
            try std.testing.expectEqualStrings(&shownRow(rig, 2), &selected);
            try std.testing.expect(state.prompt == null and !state.settings.empty());
            if (draft.len == 0) try expectStarted(rig, "ok\r", "ok");
            continue;
        };
        if (action == .exit) {
            try std.testing.expectEqual(@as(?Ending, .overview), ending);
            continue;
        }
        try std.testing.expect(ending == null);
        switch (action) {
            .previous, .next, .select_previous, .select_next, .first, .last => {
                const row: usize = switch (action) {
                    .previous, .select_previous => 1,
                    .next, .select_next => 3,
                    .first => 0,
                    .last => listed_references.len - 1,
                    else => unreachable,
                };
                try std.testing.expectEqualStrings(&shownRow(rig, row), &selected);
            },
            .clear => try std.testing.expect(state.settings.empty()),
            .archive, .stop => try std.testing.expectEqualStrings(&shownRow(rig, 2), &(state.prompt orelse return error.TestExpectedPrompt).stop),
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
    try std.testing.expectEqualStrings("! That key does nothing here.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "c\r", "abc");
}

test "the terminal's width report sets how the core measures text" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, rig.overview.caps.width);
    try std.testing.expect(try rig.press("\x1b[?2027;3$y") == null);
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, rig.overview.caps.width);
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, rig.screen.backend.widthMethod());
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

    fn command(_: std.process.Init, _: client.Requests, to: []const u8, reference: []const u8, text: []u8) anyerror!void {
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

test "/rename and /setup run through the conversation's command hook on the worker, and what they print reaches the overview" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancellation: client.Cancellation = .{};
    const rig = try commandRig(tmp.dir, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const lists = Seen.now.lists;
    Printing.stdout = "Rui: Configured.\n";
    try std.testing.expect(try rig.press("/rename lane four\n") == null);
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
    try std.testing.expect(try rig.press("/setup\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("/setup", Printing.line.slice());
    try std.testing.expectEqualStrings("", Printing.session.slice());
    try std.testing.expectEqualStrings("Defaults (read only):\nNotifications: on\nrui: Host unavailable", overview.state.panel.?.output.text);
    try std.testing.expectEqual(@as(usize, 2), Printing.runs);
}

test "a /setup that saves another model starts the next Session on it, unless the launch named it or /configure holds one" {
    const Case = struct { selectors: new_session_selection.Intent = .{}, setup: []const u8 = "/setup --model gpt-5.5\n", edit: preferences.Edit, configure: ?[]const u8 = null, model: []const u8 };
    for ([_]Case{
        .{ .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-5.5" },
        .{ .setup = "/setup --clear-model\n", .edit = .{ .model = .clear }, .model = product_defaults.recommended_model },
        .{ .selectors = .{ .model = "gpt-6-luna" }, .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-6-luna" },
        .{ .selectors = explicit_selectors, .edit = .{ .model = .{ .set = "gpt-5.5" } }, .model = "gpt-6-luna" },
        .{ .edit = .{ .model = .{ .set = "gpt-5.5" } }, .configure = "/configure --model gpt-6-sol\n", .model = "gpt-6-sol" },
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
            fn command(_: std.process.Init, _: client.Requests, _: []const u8, _: []const u8, _: []u8) anyerror!void {
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
        try std.testing.expect(try rig.press("hello\n") == null);
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
    try std.testing.expect(try rig.press("/setup\n") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Printing.runs);
    try std.testing.expectEqualStrings("! /setup unavailable.", rig.overview.state.notice.?.text());

    rig.overview.hooks.scratch = Printing.scratch;
    const said = "rui: configure: CanonicalStoreFailure; check saved requests before retrying\n";
    Printing.stderr_text = said;
    Printing.failure = error.CanonicalStoreFailure;
    try std.testing.expect(try rig.press("/rename x\n") == null);
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
    try std.testing.expect(try rig.press("/rename x\n") == null);
    // The core keeps the output for the way out with memory it cannot get.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = rig.overview.state.gpa;
    rig.overview.state.gpa = failing.allocator();
    defer rig.overview.state.gpa = gpa;
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
    try std.testing.expect(failing.has_induced_failure);
}

test "one captured overview frame geometry sizes the domain and backend through shrink and grow" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    const selected = overview.state.selected.?;
    const backend = rig.screen.backend;
    const decoder = &rig.terminal.stream;
    const fallback = rig.terminal.geometry();
    const captured = [_]std.posix.winsize{
        .{ .col = 60, .row = 20, .xpixel = 600, .ypixel = 400 },
        .{ .col = 120, .row = 40, .xpixel = 1200, .ypixel = 800 },
        .{ .col = 100, .row = 30, .xpixel = 1000, .ypixel = 600 },
        .{ .col = 132, .row = 44, .xpixel = 1320, .ypixel = 880 },
    };
    var buffer: [64 * 1024]u8 = undefined;
    for (captured) |size| {
        // The real frame consumes its snapshot, not another terminal read.
        try std.testing.expect(size.col != fallback.col and size.row != fallback.row);
        try std.testing.expect(try overview.drawFrame(0, size) == null);
        try std.testing.expectEqual(size.col, overview.state.size.width);
        try std.testing.expectEqual(size.row, overview.state.size.height);
        const actual = backend.geometry();
        try std.testing.expectEqual(size.col, actual.cols);
        try std.testing.expectEqual(size.row, actual.rows);
        try std.testing.expectEqual(size.xpixel, actual.x_pixel);
        try std.testing.expectEqual(size.ypixel, actual.y_pixel);
        try std.testing.expectEqualStrings(&selected, &overview.state.selected.?);
        try std.testing.expect(rig.screen.backend == backend and &rig.terminal.stream == decoder);
        try std.testing.expect(backend.idle());
        try std.testing.expect(rig.drawn(&buffer).len != 0);
        try std.testing.expect(try overview.drawFrame(0, size) == null);
        try std.testing.expectEqualStrings("", rig.drawn(&buffer));
    }
}

test "overview detail overview paints one healthy backend and retains the invocation decoder" {
    var phase: []const u8 = "setup";
    errdefer std.debug.print("roundtrip phase={s}\n", .{phase});
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{ .depth = .indexed };
    Seen.now.listed = 3;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const backend = rig.screen.backend;
    const decoder = &rig.terminal.stream;
    overview.state.selected = shownRow(rig, 1);
    const selected = overview.state.selected.?;
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(rig.drawn(&buffer).len != 0);
    // A borrower that changes no cell needs no cache retirement at either boundary.
    phase = "healthy empty borrower";
    try std.testing.expect(overview.proceed(.{ .open = selected }) == null);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
    // Carry an unfinished CSI across actual overview/detail/overview painting.
    phase = "split prefix";
    try std.testing.expect(try rig.press("\x1b[") == null);
    rig.screen.init(backend);
    try rig.screen.append("A detail answer\n");
    phase = "detail redraw";
    const delivered = try rig.terminal.redraw("detail draft", 12, .{}, &.{});
    phase = "detail receipt";
    try std.testing.expect(!rig.screen.ticket.?.delivered);
    _ = rig.screen.presented(delivered);
    try std.testing.expect(rig.screen.ticket.?.delivered);
    try std.testing.expect(rig.drawn(&buffer).len != 0);
    phase = "return to overview";
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expect(rig.drawn(&buffer).len != 0);
    try std.testing.expect(try overview.draw(0) == null);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
    try std.testing.expect(rig.screen.backend == backend and &rig.terminal.stream == decoder);
    try std.testing.expectEqualStrings(&selected, &overview.state.selected.?);
    phase = "split tail";
    try std.testing.expectEqual(@as(@import("TerminalInput.zig").Pending, .incomplete), decoder.pending());
    try std.testing.expect(try rig.press("B") == null);
    try std.testing.expectEqual(@as(@import("TerminalInput.zig").Pending, .none), decoder.pending());
    try std.testing.expect(!std.mem.eql(u8, &selected, &overview.state.selected.?));
    try std.testing.expectEqualStrings("", overview.composerDraft().bytes);
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

test "Alt-A overview preserves draft bytes caret and revision through ask cancel confirm and server answer" {
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| for ([_]bool{ false, true }) |rejected| for ([_][]const u8{ "\r", "\n", "\x1b[13u", "\x1b[27;1;13~" }) |confirmation| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expect(try rig.press("/rename unfinished\x1b[D\x1b[D") == null);
        if (rejected) try std.testing.expect(try rig.press("\x00") == null);
        const before = overview.composerDraft();
        const target = overview.state.selected.?;
        try std.testing.expect(try rig.press(chord) == null);
        try std.testing.expectEqual(view.Prompt.Action.archive, overview.state.prompt.?.action);
        try std.testing.expect(try pressKey(rig, "\x1b") == null);
        try std.testing.expect(overview.state.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
        try std.testing.expect(try rig.press(chord) == null);
        overview.state.selected = shownRow(rig, 3);
        try std.testing.expect(try rig.press(confirmation) == null);
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

test "Alt-A overview confirmation precedes the visible model sign-in choice" {
    const rig = try openListed();
    defer rig.close();
    try std.testing.expect(try rig.press("/model\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[B\r") == null);
    const overview = rig.overview;
    try std.testing.expectEqual(view.InputMode.choice, overview.state.inputMode());
    const target = overview.state.selected.?;
    try std.testing.expect(try rig.press("\x1ba\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqualStrings(&target, &Seen.now.archive_session);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.saves);
    try std.testing.expectEqual(view.InputMode.choice, overview.state.inputMode());
}

test "Alt-A overview ignores paste and modified confirmation without submitting the draft" {
    for ([_][]const u8{ "\x1b[13;2u", "\x1b[13;3u", "\x1b[13;5u", "\x1b[200~\r\x1b[201~", "\x1b[200~\n\x1b[201~", "\x18" }) |other| {
        const rig = try openListed();
        defer rig.close();
        try std.testing.expect(try rig.press("keep me\x1b[D\x1ba") == null);
        try std.testing.expect(try rig.press(other) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
        if (rig.overview.state.prompt) |prompt| try std.testing.expectEqual(view.Prompt.Action.stop, prompt.action);
    }
}

test "conversation archive and restore use the exact unlisted opened reference through the existing worker" {
    const rig = try openListed();
    defer rig.close();
    rig.overview.opened = "x9y8z7".*;
    const selected = rig.overview.state.selected.?;
    try conversed(rig.overview, .idle, .{ .archive = .active });
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expect(Seen.now.archive_requested);
    try conversed(rig.overview, .idle, .unarchive);
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.archives);
    try std.testing.expect(!Seen.now.archive_requested);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expectEqualStrings(&selected, &rig.overview.state.selected.?);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
}
