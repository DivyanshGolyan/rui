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
const vaxis = @import("vaxis");
const client = @import("client.zig");
const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const stderr = @import("stderr.zig");
const test_poll = @import("test_poll");
const view = @import("overview_view.zig");
const ClientTask = @import("ClientTask.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const SessionInput = @import("SessionInput.zig");
const SessionScreen = @import("SessionScreen.zig");
const SessionTerminal = @import("SessionTerminal.zig");
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalInput = @import("TerminalInput.zig");
const TerminalText = @import("TerminalText.zig");
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
    /// A Session to open first, as `session resume` names it.
    open: ?view.Reference = null,
};

/// What the CLI lends a conversation: its scratch files and slash commands.
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
    /// Reads one `session list` page into `page`, or returns the Host's
    /// failure.
    list: *const fn (*Self, client.Requests, protocol_reply.SessionListCursor, *protocol_reply.SessionListPage) anyerror!?protocol_reply.ReadFailure,
    /// The first line of a Session's first Message, read into `buffer`.
    first_line: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!protocol_reply.ActivityPrefixReply,
    /// Write the request's fate into the Reply, and return the error that
    /// ends the overview after a canonical Store failure.
    start: *const fn (*Self, client.Requests, client.MessageInput, *Reply) anyerror!void,
    stop: *const fn (*Self, client.Requests, client.SessionStopInput, *Reply) anyerror!void,
    /// Lends the terminal to the Session's conversation. Null once the
    /// person returned to the overview.
    converse: *const fn (*Self, view.Reference) ?Left,
};

pub const client_operations: Operations = .{ .host = hostFacts, .list = listPage, .first_line = firstLine, .start = startSession, .stop = stopSession, .converse = converse };

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
    /// The failure code, or the handle that recovers an unconfirmed request.
    text: protocol.Bounded(protocol.max_code_bytes) = .{},
    /// The request's handle, for guidance after an accepted start.
    handle: protocol.Bounded(protocol.max_key_bytes) = .{},

    fn refused(code: []const u8) Reply {
        var reply: Reply = .{};
        reply.text.set(code[0..@min(code.len, protocol.max_code_bytes)]) catch {};
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
    /// Borrows the draft, which takes no input until the result.
    start: struct { settings: *const view.StartSettings, text: []const u8 },
    stop: view.Reference,
};

/// One host read and list page, at most one first-line batch, and the
/// requests the core's ledger allows can wait at once.
const max_jobs = 3 + view.max_requests;

/// The longest the first frame waits for the terminal's background.
const background_wait_ms = 200;

const Line = struct { bytes: [view.max_line_read_bytes]u8 = undefined, result: enum { line, refused, unanswered } = .unanswered, len: usize = 0 };

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
input: TerminalInput = .{},
/// The composer's line editor, the conversation's, which owns the draft.
composer: TerminalEditor = undefined,
draft: [SessionInput.capacity]u8 = undefined,
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
host: ?view.Host = null,
page: protocol_reply.SessionListPage = undefined,
lines: [view.max_first_line_reads]Line = @splat(.{}),
reply: Reply = .{},
/// Unlinked scratch for list pages.
scratch: ?std.Io.File = null,

/// The screen the terminal shows, so a frame writes only what changed;
/// null when the terminal's contents are unknown.
shown: ?view.Screen = null,
frame: std.ArrayList(u8) = .empty,
/// What a key read while output waited asks of the loop.
pumped: ?Next = null,
/// The Session a conversation borrows, in stable storage.
opened: view.Reference = undefined,
/// The Session the last accepted start made, for guidance if its
/// conversation fails.
started: ?view.Reference = null,
/// The screen holds no Session's state, so a conversation may use it as is.
screen_fresh: bool = true,
/// The screen is initialized, so `run` disposes of it.
screen_ready: bool = false,
/// The terminal has not yet answered the DA1 that follows the background
/// question.
asking: bool = false,

/// Opens the overview and returns once the person leaves it, or a signal
/// stops it. Every way out restores the terminal and then prints the
/// Detached notice once.
pub fn run(init: std.process.Init, options: Options, hooks: Hooks) !void {
    const self = try create(init, options, hooks, client_operations, &Signals.cancellation);
    defer self.destroy();
    const screen = try init.gpa.create(SessionScreen);
    defer init.gpa.destroy(screen);
    const prepared: anyerror!void = prepare: {
        self.scratch = hooks.scratch(init) catch |err| break :prepare err;
        self.initScreen(screen) catch |err| break :prepare err;
        self.caps.width = screen.vx.caps.unicode;
    };
    prepared catch |err| return self.failed(err, options.open);
    defer if (self.screen_ready) screen.deinit();
    Signals.cancellation.stopped.store(false, .release);
    Signals.wake = self.signalled[1];
    Signals.install(true);
    defer Signals.install(false);
    var terminal = SessionTerminal.begin(screen) catch |err| return self.failed(err, options.open);
    self.terminal = &terminal;
    const ended = self.loop();
    return self.finish(ended);
}

fn initScreen(self: *Self, screen: *SessionScreen) !void {
    const no_colour: []const u8 = self.init.environ_map.get("NO_COLOR") orelse "";
    try screen.init(self.init.io, self.init.environ_map, no_colour.len == 0);
    self.screen_ready = true;
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
    self.composer = .{ .buffer = &self.draft };
    try self.state.init(init.gpa, .{ .cwd = options.workspace, .home = options.home, .login_at = options.login_at });
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
    if (self.scratch) |file| file.close(self.init.io);
    self.closePipes();
    self.forget();
    self.frame.deinit(self.init.gpa);
    self.state.deinit();
    self.init.gpa.destroy(self);
}

const Ending = union(enum) { overview, conversation: Left };

/// What the core asks of the loop: to leave, or to lend the terminal to a
/// Session.
const Next = union(enum) { leave, open: view.Reference };

/// Runs until the person leaves the overview or a conversation, or a signal
/// stops it. The terminal is still begun when it returns.
fn loop(self: *Self) !Ending {
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
    try self.dispatch();
    // Frames count on the monotonic clock, so a wall-clock step cannot
    // stall or race the pulse; ticks keep the Host's wall clock.
    const awake_ns = std.Io.Clock.awake.now(self.init.io).nanoseconds;
    const awake_ms: u64 = @intCast(@max(@divFloor(awake_ns, std.time.ns_per_ms), 0));
    if (try self.draw(awake_ms / view.pulse_interval_ms)) |next| return next;
    const pulses = if (self.shown) |*held| held.pulses else false;
    const timeout = switch (self.input.wait(awake_ns, self.budget(now_ms, awake_ms, pulses))) {
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
            if (self.ops.converse(self, self.opened)) |left| return .{ .conversation = left };
            // The conversation drew over the overview.
            self.forget();
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
    self.lendDraft();
    const effects = try view.step(&self.state, value);
    var next: ?Next = null;
    for (effects.slice()) |effect| switch (effect) {
        .list => |since| {
            self.traversal = .init(since);
            self.queue(.host);
            self.queue(.list);
        },
        .read_first_lines => |reads| self.queue(.{ .lines = reads }),
        .start => |start| self.queue(.{ .start = .{ .settings = start.settings, .text = start.text } }),
        .stop => |reference| self.queue(.{ .stop = reference }),
        .open => |reference| next = .{ .open = reference },
        .clear_draft => self.composer = .{ .buffer = &self.draft },
        .exit => return .leave,
    };
    return next;
}

fn lendDraft(self: *Self) void {
    self.state.draft = .{ .bytes = self.draft[0..self.composer.length], .cursor = self.composer.cursor };
}

fn queue(self: *Self, job: Job) void {
    std.debug.assert(self.job_count < max_jobs);
    self.jobs[self.job_count] = job;
    self.job_count += 1;
}

/// Starts the next job once the worker is free.
fn dispatch(self: *Self) !void {
    if (self.worker.thread != null or self.job_count == 0) return;
    self.job = self.jobs[0];
    std.mem.copyForwards(Job, self.jobs[0 .. self.job_count - 1], self.jobs[1..self.job_count]);
    self.job_count -= 1;
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
    const requests = task.requests();
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
        .start => |start| try self.ops.start(self, requests, self.startInput(start.settings, start.text), &self.reply),
        .stop => |*reference| try self.ops.stop(self, requests, .{ .store = self.options.store, .session = reference }, &self.reply),
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
    }
    return null;
}

/// One captured `session start`: the composer's text and start settings
/// over the defaults a fresh Session gets.
fn startInput(self: *const Self, settings: *const view.StartSettings, text: []const u8) client.MessageInput {
    const held = struct {
        fn at(from: *const view.StartSettings, comptime name: []const u8) ?[]const u8 {
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
    const label: client.OptionalPolicy = if (held.at(settings, "label")) |value| .{ .present = true, .value = if (value.len == 0) null else value } else .{};
    return .{ .store = self.options.store, .session = "", .text_path = "", .text = text, .configuration = .{
        .store = self.options.store,
        .session = .create,
        .require_model = true,
        .workspace = .{ .present = true, .value = held.at(settings, "workspace") orelse self.options.workspace },
        .provider = held.given(held.at(settings, "provider") orelse self.options.provider),
        .model = held.given(held.at(settings, "model") orelse self.options.model),
        .tools = held.at(settings, "tools") orelse product_defaults.tools,
        .permission_mode = .{ .present = true, .value = held.at(settings, "permission-mode") orelse product_defaults.permission_mode },
        .compaction_trigger = held.policy(held.at(settings, "compaction-trigger")),
        .output_reservation = held.policy(held.at(settings, "output-reservation")),
        .reasoning_effort = held.policy(held.at(settings, "reasoning-effort")),
        .label = label,
    } };
}

/// Reads up to `bytes` of what the terminal holds, waiting `wait`
/// milliseconds for the first byte, and steps each key. A lone Esc becomes a
/// key once the stream says it expired.
fn readInput(self: *Self, wait: i32, bytes: usize) !?Next {
    for (0..bytes) |count| {
        const read = (self.terminal.next(self.init.io, &self.input, if (count == 0) wait else 0) catch |err| switch (err) {
            error.InputDeadline => {
                if (try self.input.expire()) {
                    if (try self.look()) |next| return next;
                    if (try self.event(.{ .key = .escape })) |next| return next;
                }
                continue;
            },
            else => return err,
        }) orelse return null;
        var decoded = self.input.feed(read.byte, read.at);
        while (decoded != .none) : (decoded = self.input.next()) switch (decoded) {
            .event => |value| switch (value.event) {
                // An answer applies whenever it comes; a late one repaints.
                .color_report => |report| if (report.kind == .bg) {
                    self.caps.background = report.value;
                },
                .cap_da1 => self.asking = false,
                .key_press => {
                    if (try self.look()) |next| return next;
                    if (try self.compose(decoded)) |next| return next;
                },
                else => if (try self.compose(decoded)) |next| return next,
            },
            .report => |report| switch (report) {
                .width => |method| {
                    self.terminal.screen.setWidth(method);
                    self.caps.width = method;
                },
                .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
            },
            else => if (try self.compose(decoded)) |next| return next,
        };
    }
    return null;
}

/// Tells the core the person pressed a key now, before the key itself.
fn look(self: *Self) !?Next {
    return self.event(.{ .looked = self.realMs() });
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
        self.terminal.write(ask) catch |err| return self.pumped orelse err;
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

/// Gives the overview its own keys and the line editor everything else,
/// then steps the core with what the editor made of it. Every input is one
/// event, whether or not it changed the draft. A start borrows the draft,
/// so the editor takes nothing until its answer.
fn compose(self: *Self, decoded: TerminalInput.Decoded) !?Next {
    const locked = self.state.starting();
    if (overviewKey(decoded, locked or self.composer.length == 0)) |key| return self.event(.{ .key = key });
    return self.event(if (locked) .{ .composer = .input } else switch (self.composer.apply(decoded)) {
        .none, .page_up, .page_down, .latest, .expand, .append, .redraw => .{ .composer = .input },
        // Past the draft's first or last line, Up and Down select rows,
        // as they scroll a conversation.
        .scroll_up => .{ .key = .up },
        .scroll_down => .{ .key = .down },
        .close_view => .{ .key = .escape },
        .interrupt => .{ .key = .ctrl_c },
        inline .submit, .eof, .invalid, .overflow, .edit_rejected, .unbound => |outcome| .{ .composer = @field(view.Composed, @tagName(outcome)) },
    });
}

/// The overview's own key a decoded event names, if any. Ctrl-C leaves even
/// while a start holds the draft. The arrows, Home and End select rows only
/// while the editor has no draft to move through.
fn overviewKey(decoded: TerminalInput.Decoded, selects: bool) ?view.Key {
    const value = switch (decoded) {
        .event => |value| value,
        else => return null,
    };
    const key = switch (value.event) {
        .key_press => |key| key,
        else => return null,
    };
    if (value.pasted) return null;
    const Key = vaxis.Key;
    if (key.matchExact(Key.escape, .{}) or key.matchExact(Key.escape, .{ .alt = true })) return .escape;
    if (key.matchExact('c', .{ .ctrl = true })) return .ctrl_c;
    if (key.matchExact('x', .{ .ctrl = true })) return .ctrl_x;
    if (!selects) return null;
    if (key.matchExact(Key.up, .{})) return .up;
    if (key.matchExact(Key.down, .{})) return .down;
    if (key.matchExact(Key.home, .{})) return .home;
    if (key.matchExact(Key.end, .{})) return .end;
    return null;
}

/// Draws the core's screen at `frame`, writing only what the terminal does
/// not already show. The shown screen says whether it changes with the
/// next frame.
fn draw(self: *Self, frame: u64) !?Next {
    const size = self.terminal.geometry();
    self.lendDraft();
    var screen = try view.render(self.init.gpa, &self.state, size.col, size.row, self.caps, frame);
    errdefer screen.deinit();
    self.frame.clearRetainingCapacity();
    var bytes: std.Io.Writer.Allocating = .fromArrayList(self.init.gpa, &self.frame);
    screen.writeFrame(if (self.shown) |*held| held else null, &bytes.writer) catch return error.OutOfMemory;
    self.frame = bytes.toArrayList();
    // The terminal already shows it; keep the new screen, whose pulse is
    // current.
    if (self.frame.items.len == 0) {
        self.forget();
        self.shown = screen;
        return null;
    }
    self.terminal.pump = .{ .context = self, .step = pump };
    defer self.terminal.pump = null;
    // A failed write leaves the screen unknown: the next frame draws whole.
    self.forget();
    self.pumped = null;
    self.terminal.write(self.frame.items) catch |err| {
        const next = self.pumped orelse return err;
        screen.deinit();
        return next;
    };
    self.shown = screen;
    return null;
}

fn forget(self: *Self) void {
    if (self.shown) |*held| held.deinit();
    self.shown = null;
}

/// How long the loop may wait, in milliseconds, -1 for ever: until the
/// core's next tick, and while the screen pulses, no later than its next
/// frame. Until then only input, the worker or a signal wakes it.
fn budget(self: *const Self, now_ms: u64, awake_ms: u64, pulses: bool) i32 {
    const tick: i32 = if (self.state.wakeAt()) |at| @intCast(@min(at -| now_ms, std.math.maxInt(i32))) else -1;
    if (!pulses) return tick;
    const frame: i32 = @intCast(view.pulse_interval_ms - awake_ms % view.pulse_interval_ms);
    return if (tick < 0) frame else @min(tick, frame);
}

/// While the terminal takes no output, reads input as the loop does, as the
/// conversation's pump does. A key that leaves or opens a Session cuts the
/// stale frame short, and a signal ends the wait.
fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
    self.pumped = try self.readInput(16, 4096);
    if (self.pumped != null) return error.InteractiveInterrupted;
}

/// Lends the terminal to the Session's conversation until the person
/// leaves it.
fn converse(self: *Self, session: view.Reference) ?Left {
    var left: Left = .{ .session = session, .frontend = null, .files = null, .ended = error.OutOfMemory };
    const io = self.init.io;
    const screen = self.terminal.screen;
    if (!self.screen_fresh) {
        // Each Session draws on a fresh screen in the terminal's width mode.
        const method = screen.vx.caps.unicode;
        screen.deinit();
        self.screen_ready = false;
        self.initScreen(screen) catch |err| {
            left.ended = err;
            return left;
        };
        screen.setWidth(method);
    }
    self.screen_fresh = false;
    screen.vx.queueRefresh();
    var opened: [4]std.Io.File = undefined;
    for (&opened, 0..) |*file, count| file.* = self.hooks.scratch(self.init) catch |err| {
        for (opened[0..count]) |done| done.close(io);
        left.ended = err;
        return left;
    };
    const files: SessionFrontend.Files = .{ .scratch = opened[0], .action = opened[1], .inspection = opened[2], .status = opened[3] };
    const frontend = self.init.gpa.create(SessionFrontend) catch |err| {
        for (opened) |file| file.close(io);
        left.ended = err;
        return left;
    };
    var ended = frontend.run(self.init, self.options.store, &self.opened, self.options.directory, files, self.hooks.command, self.hooks.requests, self.hooks.status, self.terminal, self.interrupted);
    // The conversation may have read the terminal's width report.
    self.caps.width = screen.vx.caps.unicode;
    const returned = if (ended) |outcome| outcome == .returned else |_| false;
    if (returned) ended = frontend.back() orelse {
        self.init.gpa.destroy(frontend);
        for (opened) |file| file.close(io);
        return null;
    };
    return .{ .session = session, .frontend = frontend, .files = files, .ended = ended };
}

/// Every way out: restores the terminal, answers the worker's job through
/// `complete` as the loop does, then writes the ledger's guidance before
/// anything that can return. The departure is whole before the restore
/// result is read. A conversation's own guidance and the Detached notice
/// follow.
fn finish(self: *Self, ended: anyerror!Ending) !void {
    const restored = self.terminal.finish();
    self.worker.cancel();
    const answered: anyerror!?Next = if (view.step(&self.state, .leave)) |_| self.complete() else |err| err;
    // A ledger entry prints well under 512 bytes.
    var bytes: [view.max_requests * 512]u8 = undefined;
    var guidance = std.Io.Writer.fixed(&bytes);
    view.writeDeparture(&self.state, &guidance) catch unreachable;
    _ = stderr.write(guidance.buffered());
    var ending = try ended;
    switch (ending) {
        .overview => {
            try restored;
            _ = try answered;
            try self.terminal.detached(self.options.store, null, null);
        },
        .conversation => |*left| {
            if (answered) |_| {} else |err| left.ended = err;
            return self.leave(left.*, restored);
        },
    }
}

/// Lets the conversation the person left join its borrowers and write its
/// guidance, then names the Session to resume.
fn leave(self: *Self, left: Left, restored: anyerror!void) !void {
    const io = self.init.io;
    defer if (left.files) |files| inline for (.{ "scratch", "action", "inspection", "status" }) |name| @field(files, name).close(io);
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
                TerminalText.diagnostic("rui: Action recovery notice failed: {s}\n", .{@errorName(notice_error)});
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
    return outcome catch |err| self.failed(err, left.session);
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
    const reply = try requests.listSessions(self.options.store, null, cursor, &sink, &buffer);
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
    return reply.record(requests.sendCaptured(&captured, &buffer), captured.identity().key.slice());
}

fn stopSession(self: *Self, requests: client.Requests, input: client.SessionStopInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionStop(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, &buffer), captured.identity().key.slice());
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
        label: ?protocol.Bounded(64) = null,
    } = .{},
    stops: usize = 0,
    stopped: view.Reference = @splat(0),
    conversations: usize = 0,
    conversed: view.Reference = @splat(0),

    var now: Seen = .{};

    fn bounded(bytes: []const u8) protocol.Bounded(64) {
        var value: protocol.Bounded(64) = .{};
        value.set(bytes) catch unreachable;
        return value;
    }
};

/// Operations that answer from fixed facts and record what they were asked.
const fake_operations: Operations = .{
    .host = struct {
        fn host(_: *Self) ?view.Host {
            Seen.now.hosts += 1;
            return .{ .started_at = test_now_s - 60, .slots = 4, .slots_in_use = 1 };
        }
    }.host,
    .list = struct {
        fn list(_: *Self, _: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            Seen.now.lists += 1;
            Seen.now.since = cursor.since;
            page.* = .{ .count = 1, .delta = .full, .since = .{ .instance = @splat(1), .generation = 1 }, .next = null };
            var row: protocol.SessionRow = .{ .work = .{ .state = .{ .working = .{ .since = test_now_s - 10 } }, .turn = 1, .operation = 1 } };
            row.reference.set("k7m2qx") catch unreachable;
            row.workspace.set("/work") catch unreachable;
            row.model.set("gpt-5.5") catch unreachable;
            row.first_message = .{ .position = 1, .admission = 4, .admitted_at = test_now_s - 10, .sender = null, .content = .{ .length = 27, .digest = @splat(0) } };
            row.peers.from_person_at = test_now_s - 10;
            page.rows[0] = row;
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
                .label = if (settings.label.value) |label| Seen.bounded(label) else null,
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
        try rig.screen.init(std.testing.io, &rig.environ, true);
        errdefer rig.screen.deinit();
        errdefer for (rig.keys ++ rig.output) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        try openPipe(&rig.keys);
        try openPipe(&rig.output);
        rig.terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = rig.screen, .input = rig.keys[0], .output = rig.output[1] };
        rig.overview = try create(rig.init, options, undefined, ops, interrupted);
        rig.overview.terminal = &rig.terminal;
        return rig;
    }

    fn close(rig: *Rig) void {
        rig.overview.worker.cancel();
        if (rig.overview.worker.thread != null) rig.overview.worker.join() catch {};
        rig.overview.destroy();
        for (rig.keys ++ rig.output) |fd| _ = std.c.close(fd);
        rig.screen.deinit();
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
            try overview.dispatch();
            if (overview.worker.thread == null) return null;
            var fds = [_]std.posix.pollfd{.{ .fd = overview.done[0], .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 10_000) == 0) return error.TestUnexpectedResult;
            drain(overview.done[0]);
            if (try overview.complete()) |next| if (overview.proceed(next)) |ending| return ending;
        }
    }

    fn drawn(rig: *Rig, buffer: []u8) []const u8 {
        const count = std.c.read(rig.output[0], buffer.ptr, buffer.len);
        return if (count > 0) buffer[0..@intCast(count)] else "";
    }
};

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
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[?2026l"));
    // The terminal already shows an unchanged screen. The Host read may
    // have answered after that frame, so draw what it changed first.
    try std.testing.expect(try rig.overview.draw(0) == null);
    _ = rig.drawn(&buffer);
    try std.testing.expect(try rig.overview.draw(0) == null);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
}

test "each frame rewrites a pulsing mark alone, until its pulse ends" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{};
    // The listed row began working this second, so its mark pulses. Its
    // phase is its change second, 2 mod 4, so frame 2 shows the steady
    // mark and frame 3 the first dot.
    const changed = (test_now_s - 10) * 1000;
    try std.testing.expect(try overview.event(.{ .tick = changed }) == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(try overview.draw(2) == null and overview.shown.?.pulses);
    try std.testing.expect(std.mem.count(u8, rig.drawn(&buffer), "\x1b[2K") == 24);
    try std.testing.expect(try overview.draw(2) == null and overview.shown.?.pulses);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
    try std.testing.expect(try overview.draw(3) == null and overview.shown.?.pulses);
    const pulse = rig.drawn(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, pulse, "m·\x1b[0m") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pulse, "H\x1b[0"));
    try std.testing.expect(std.mem.indexOf(u8, pulse, "\x1b[2K") == null);
    // The tick that ends the pulse leaves the steady mark.
    try std.testing.expect(try overview.event(.{ .tick = changed + view.pulse_window_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.draw(4) == null and !overview.shown.?.pulses);
    try std.testing.expect(std.mem.indexOf(u8, rig.drawn(&buffer), "m●\x1b[0m") != null);
    try std.testing.expect(try overview.draw(5) == null and !overview.shown.?.pulses);
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
}

test "the loop waits for the core's next tick, and while the screen pulses no later than its next frame" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const start = test_now_s * 1000;
    // While a listing is in flight the core needs no tick.
    try std.testing.expect(try overview.event(.{ .tick = start }) == null);
    try std.testing.expectEqual(@as(i32, -1), overview.budget(start, 280, false));
    try std.testing.expectEqual(@as(i32, 140), overview.budget(start, 280, true));
    try std.testing.expectEqual(@as(i32, 1), overview.budget(start, 419, true));
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
    try view.writeDeparture(&rig.overview.state, &departure.writer);
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
    try std.testing.expectEqualStrings("! Not sure k7m2qx stopped. Details when you leave.", rig.overview.state.notice.?.text());
    const guidance = "rui: Not sure k7m2qx stopped. Check with: rui request recover stop-handle\n";
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, &departure.writer);
    try std.testing.expectEqualStrings(guidance, departure.written());
    // Its row takes no second stop: Ctrl-X names the recovery and sends nothing.
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    rig.overview.state.notice = null;
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! Not sure k7m2qx stopped. Details when you leave.", rig.overview.state.notice.?.text());
    // A stop still running as the overview ends is named the same way.
    const running = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer running.close();
    try std.testing.expect(try running.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try running.settle() == null);
    try std.testing.expect(try running.press("\x1b[H\x18\x18") == null);
    try running.overview.dispatch();
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(running.overview.job));
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(guidance, try finishedGuidance(running, &buffer));
}

/// Runs `finish` over a terminal whose restore failed, which writes nothing
/// to stdout, and returns what it wrote to stderr.
fn finishedGuidance(rig: *Rig, buffer: []u8) ![]const u8 {
    return finishedWith(rig, .overview, error.TerminalRestoreFailed, buffer);
}

/// Runs `finish` on `ending` as `finishedGuidance` does, expecting `failure`.
fn finishedWith(rig: *Rig, ending: Ending, failure: anyerror, buffer: []u8) ![]const u8 {
    rig.terminal.active = false;
    rig.terminal.result = error.TerminalRestoreFailed;
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
    const written = try finishedWith(rig, ending, error.AccessDenied, &buffer);
    try std.testing.expectEqualStrings("rui: A new Session's start was not confirmed; use rui request recover lost-handle. Do not start it again.\n" ++
        "\nResume: rui session resume --store $'/store' k7m2qx\n", written);
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
        try rig.overview.dispatch();
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
    try std.testing.expectEqualStrings("! Not sure k7m2qx stopped. Details when you leave.", rig.overview.state.notice.?.text());
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
    try std.testing.expectEqualStrings("! That text had bytes that are not text, so it was not sent.", rig.overview.state.notice.?.text());
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
    try std.testing.expectEqualStrings("! That's too long to send.", rig.overview.state.notice.?.text());
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

test "a start holds its draft until the answer; the editor takes nothing meanwhile" {
    const rig = try openComposer();
    defer rig.close();
    try expectStarted(rig, "hello\r\x7f\x7fXY\x1b[27u", "hello");
    try std.testing.expectEqual(@as(usize, 0), rig.overview.composer.length);
    // The next frame shows the empty composer, not the text it lent.
    try std.testing.expect(try rig.overview.draw(0) == null);
    var buffer: [64 * 1024]u8 = undefined;
    const frame = rig.drawn(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Type a task to start a Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "hello") == null);
    try expectStarted(rig, "next\r", "next");
}

test "keys the editor declines say so and leave the draft" {
    const rig = try openComposer();
    defer rig.close();
    try expectStarted(rig, "\u{200d}", null);
    try std.testing.expectEqualStrings("! That character cannot stand alone, so it was not added.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "ab\x1bx", null);
    try std.testing.expectEqualStrings("! That key combination does nothing here.", rig.overview.state.notice.?.text());
    try expectStarted(rig, "c\r", "abc");
}

test "the terminal's width report sets how the core measures text" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, rig.overview.caps.width);
    try std.testing.expect(try rig.press("\x1b[?2027;3$y") == null);
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, rig.overview.caps.width);
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, rig.screen.vx.caps.unicode);
}
