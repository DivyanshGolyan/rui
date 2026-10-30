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
const view = @import("overview_view.zig");
const ClientTask = @import("ClientTask.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const SessionScreen = @import("SessionScreen.zig");
const SessionTerminal = @import("SessionTerminal.zig");
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

/// An accepted start: the Session it made and its request's handle.
pub const Started = struct { session: view.Reference, handle: protocol.Bounded(protocol.max_key_bytes) };

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
/// `converse`. Tests substitute their own.
pub const Operations = struct {
    /// host-info's facts, or null when the Host gives none.
    host: *const fn (*Self) ?view.Host,
    /// Reads one `session list` page into `page`; false when the Host
    /// answered with a failure.
    list: *const fn (*Self, client.Requests, protocol_reply.SessionListCursor, *protocol_reply.SessionListPage) anyerror!bool,
    /// The first line of a Session's first Message, read into `buffer`, or
    /// null when the Host refused it. An error is no answer.
    first_line: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!?[]const u8,
    start: *const fn (*Self, client.Requests, client.MessageInput, *Reply) void,
    stop: *const fn (*Self, client.Requests, client.SessionStopInput, *Reply) void,
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
    /// `fatal` is unconfirmed too, from a canonical Store failure, which
    /// fences the Host.
    outcome: enum { accepted, failed, unconfirmed, fatal } = .failed,
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

    /// From a send of the captured request `handle`. Only a send that may
    /// have reached the Host, or a reply that could not be read, leaves the
    /// outcome unknown.
    fn of(sent: anytype, handle: []const u8) Reply {
        const reply = switch (sent) {
            .failed => |failure| return if (failure.step != null and failure.step.?.mayHaveReachedHost()) unconfirmed(handle) else refused(@errorName(failure.err)),
            .done => |reply| reply,
        };
        const answer = reply.answer catch |err| {
            var unknown = unconfirmed(handle);
            if (err == error.CanonicalStoreFailure) unknown.outcome = .fatal;
            return unknown;
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
        return result;
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
            .unconfirmed, .fatal => .{ .unconfirmed = self.text.slice() },
        };
    }

    fn stop(self: *const Reply) view.StopOutcome {
        return switch (self.outcome) {
            .accepted => .stopped,
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed, .fatal => .{ .unconfirmed = self.text.slice() },
        };
    }
};

const Job = union(enum) {
    /// host-info, read as each listing starts.
    host,
    /// The traversal's next page.
    list,
    lines: view.Reads,
    /// Borrows the state, whose composer stays locked until the result.
    start: struct { settings: *const view.StartSettings, text: []const u8 },
    stop: view.Reference,
};

/// One host read and list page, at most one first-line batch, one start and
/// the stops the core allows can wait at once.
const max_jobs = 4 + view.max_stops;

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
listed: bool = false,
host: ?view.Host = null,
page: protocol_reply.SessionListPage = undefined,
lines: [view.max_first_line_reads]Line = @splat(.{}),
reply: Reply = .{},
/// Unlinked scratch for list pages.
scratch: ?std.Io.File = null,

/// The last frame written, so an unchanged one is not written again.
drawn: std.ArrayList(u8) = .empty,
frame: std.ArrayList(u8) = .empty,
/// The Session a conversation borrows, in stable storage.
opened: view.Reference = undefined,
/// The last accepted start, for guidance if its conversation fails.
started: ?Started = null,
/// The screen holds no Session's state, so a conversation may use it as is.
screen_fresh: bool = true,
/// The screen is initialized, so `run` disposes of it.
screen_ready: bool = false,

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
pub fn printFailure(err: anyerror, store: []const u8, session: ?view.Reference, started: ?Started) anyerror {
    // Four bytes per escaped selector byte, plus labels and hex syntax.
    var bytes: [4 * (protocol.max_store_bytes + protocol.max_session_bytes + protocol.max_key_bytes) + 384]u8 = undefined;
    var notice = std.Io.Writer.fixed(&bytes);
    write: {
        if (err == error.InvalidTemporaryDirectory)
            notice.writeAll(if (session == null) "rui: Fix or unset TMPDIR before opening the overview.\n" else "rui: Fix or unset TMPDIR before resuming.\n") catch break :write;
        const reference = session orelse break :write;
        if (started) |*start| if (std.mem.eql(u8, &start.session, &reference)) {
            // Admission only: the Message may not have run yet.
            notice.print("\nrui: Session start accepted.\nMessage request: {s} (rui request inspect {s})\n", .{ start.handle.slice(), start.handle.slice() }) catch break :write;
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
        .caps = .of(.{ .lc_all = init.environ_map.get("LC_ALL"), .lc_ctype = init.environ_map.get("LC_CTYPE"), .lang = init.environ_map.get("LANG"), .no_color = init.environ_map.get("NO_COLOR") }),
        .terminal = undefined,
        .interrupted = interrupted,
    };
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
    self.drawn.deinit(self.init.gpa);
    self.frame.deinit(self.init.gpa);
    self.state.deinit();
    self.init.gpa.destroy(self);
}

const Ending = union(enum) { overview, conversation: Left };

/// Runs until the person leaves the overview or a conversation, or a signal
/// stops it. The terminal is still begun when it returns.
fn loop(self: *Self) !Ending {
    if (self.options.open) |reference| if (try self.event(.{ .open = reference })) |ending| return ending;
    while (true) {
        if (self.interrupted.stopped.load(.acquire)) return .overview;
        const now_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
        if (self.state.wakeAt()) |at| if (now_ms >= at) if (try self.event(.{ .tick = now_ms })) |ending| return ending;
        try self.dispatch();
        try self.draw();
        // The core says when it next needs a tick; until then only input,
        // the worker or a signal wakes the loop.
        const budget: i32 = if (self.state.wakeAt()) |at| @intCast(@min(at -| now_ms, std.math.maxInt(i32))) else -1;
        const timeout = switch (self.input.wait(std.Io.Clock.awake.now(self.init.io).nanoseconds, budget)) {
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
            if (try self.complete()) |ending| return ending;
        }
        if (fds[0].revents != 0 or timeout == 0) if (try self.readInput()) |ending| return ending;
    }
}

fn drain(fd: c_int) void {
    var bytes: [64]u8 = undefined;
    while (std.c.read(fd, &bytes, bytes.len) > 0) {}
}

/// Steps the core with one event and runs the effects it returns.
fn event(self: *Self, value: view.Event) !?Ending {
    const effects = try view.step(&self.state, value);
    for (effects.slice()) |effect| switch (effect) {
        .list => |since| {
            self.traversal = .init(since);
            self.queue(.host);
            self.queue(.list);
        },
        .read_first_lines => |reads| self.queue(.{ .lines = reads }),
        .start => |start| self.queue(.{ .start = .{ .settings = start.settings, .text = start.text } }),
        .stop => |reference| self.queue(.{ .stop = reference }),
        .open => |reference| {
            self.opened = reference;
            if (self.ops.converse(self, self.opened)) |left| return .{ .conversation = left };
            // The conversation drew over the overview.
            self.drawn.clearRetainingCapacity();
        },
        .exit => return .overview,
    };
    return null;
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

/// The worker: runs one job and writes only its own output fields.
fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    defer {
        const byte = [1]u8{0};
        _ = std.c.write(self.done[1], &byte, 1);
    }
    const requests = task.requests();
    switch (self.job) {
        .host => self.host = self.ops.host(self),
        .list => self.listed = self.ops.list(self, requests, self.traversal.cursor, &self.page) catch false,
        .lines => |reads| for (reads.slice(), self.lines[0..reads.len]) |read, *line| {
            line.result = .unanswered;
            const text = (self.ops.first_line(self, requests, &read.reference, read.position, &line.bytes) catch continue) orelse {
                line.result = .refused;
                continue;
            };
            line.result = .line;
            line.len = text.len;
        },
        .start => |start| self.ops.start(self, requests, self.startInput(start.settings, start.text), &self.reply),
        .stop => |*reference| self.ops.stop(self, requests, .{ .store = self.options.store, .session = reference }, &self.reply),
    }
}

/// Joins the finished job and steps the core with its result.
fn complete(self: *Self) !?Ending {
    if (self.worker.thread == null) return null;
    self.worker.join() catch {};
    switch (self.job) {
        .host => return self.event(.{ .host = self.host }),
        .list => {
            if (!self.listed) return self.event(.{ .list = .failed });
            var rows: [view.max_page_rows]view.Listed = undefined;
            const page: view.Page = .of(&self.traversal, &self.page, &rows);
            // The next page goes before anything this page's result queues.
            if (page.answer == null) self.queue(.list);
            return self.event(.{ .list = .{ .page = page } });
        },
        .lines => |reads| for (reads.slice(), self.lines[0..reads.len]) |read, *line| {
            const result: view.FirstLine = .{ .reference = read.reference, .admission = read.admission, .line = if (line.result == .line) line.bytes[0..line.len] else null, .unanswered = line.result == .unanswered };
            if (try self.event(.{ .first_line = result })) |ending| return ending;
        },
        .start => {
            if (self.reply.outcome == .accepted) self.started = .{ .session = self.reply.session, .handle = self.reply.handle };
            return self.settled(.{ .start = self.reply.start() });
        },
        .stop => |reference| return self.settled(.{ .stop = .{ .reference = reference, .outcome = self.reply.stop() } }),
    }
    return null;
}

/// Steps a start's or stop's result. After a canonical Store failure the
/// overview ends, as every other caller does.
fn settled(self: *Self, result: view.Event) !?Ending {
    const ending = try self.event(result);
    return if (self.reply.outcome == .fatal) error.CanonicalStoreFailure else ending;
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

/// Reads what the terminal holds and steps each key. A lone Esc becomes a
/// key once the stream says it expired.
fn readInput(self: *Self) !?Ending {
    for (0..4096) |_| {
        const read = (self.terminal.next(self.init.io, &self.input, 0) catch |err| switch (err) {
            error.InputDeadline => {
                if (try self.input.expire()) if (try self.event(.{ .key = .escape })) |ending| return ending;
                continue;
            },
            else => return err,
        }) orelse return null;
        var decoded = self.input.feed(read.byte, read.at);
        while (decoded != .none) : (decoded = self.input.next()) switch (decoded) {
            .report => |report| switch (report) {
                .width => |method| {
                    self.terminal.screen.setWidth(method);
                    self.caps.width = method;
                },
                .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
            },
            else => if (keyOf(decoded)) |key| if (try self.event(.{ .key = key })) |ending| return ending,
        };
    }
    return null;
}

/// The overview key a decoded terminal event names, if any. Bracketed paste
/// arrives as text, its line ends included.
fn keyOf(decoded: TerminalInput.Decoded) ?view.Key {
    const value = switch (decoded) {
        .event => |value| value,
        else => return null,
    };
    const key = switch (value.event) {
        .key_press => |key| key,
        else => return null,
    };
    const Key = vaxis.Key;
    if (value.pasted) {
        if (key.matchExact('j', .{ .ctrl = true }) or key.matchExact(Key.enter, .{})) return .{ .text = "\n" };
        return if (key.text) |text| .{ .text = text } else null;
    }
    // The terminal keeps ICRNL, so Enter arrives as Ctrl-J.
    if (key.matchExact(Key.enter, .{}) or key.matchExact('j', .{ .ctrl = true })) return .enter;
    if (key.matchExact('c', .{ .ctrl = true })) return .ctrl_c;
    if (key.matchExact('d', .{ .ctrl = true })) return .ctrl_d;
    if (key.matchExact('x', .{ .ctrl = true })) return .ctrl_x;
    if (key.matchExact(Key.escape, .{}) or key.matchExact(Key.escape, .{ .alt = true })) return .escape;
    if (key.matchExact(Key.up, .{})) return .up;
    if (key.matchExact(Key.down, .{})) return .down;
    if (key.matchExact(Key.home, .{})) return .home;
    if (key.matchExact(Key.end, .{})) return .end;
    if (key.matchExact(Key.backspace, .{})) return .backspace;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return null;
    return if (key.text) |text| .{ .text = text } else null;
}

/// Draws the core's screen, unless the terminal already shows it.
fn draw(self: *Self) !void {
    const size = self.terminal.geometry();
    var screen = try view.render(self.init.gpa, &self.state, size.col, size.row, self.caps, 0);
    defer screen.deinit();
    self.frame.clearRetainingCapacity();
    var bytes: std.Io.Writer.Allocating = .fromArrayList(self.init.gpa, &self.frame);
    screen.writeFrame(&bytes.writer) catch return error.OutOfMemory;
    self.frame = bytes.toArrayList();
    if (std.mem.eql(u8, self.frame.items, self.drawn.items)) return;
    self.terminal.pump = .{ .context = self, .step = waitForOutput };
    defer self.terminal.pump = null;
    // A failed write leaves the screen unknown: the next frame draws whole.
    self.drawn.clearRetainingCapacity();
    try self.terminal.write(self.frame.items);
    std.mem.swap(std.ArrayList(u8), &self.frame, &self.drawn);
}

/// Waits for output credit; a signal ends the wait.
fn waitForOutput(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
    var fds = [_]std.posix.pollfd{.{ .fd = self.terminal.output, .events = std.posix.POLL.OUT, .revents = 0 }};
    _ = std.posix.poll(&fds, 100) catch {};
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
    const ended = frontend.run(self.init, self.options.store, &self.opened, self.options.directory, files, self.hooks.command, self.hooks.requests, self.hooks.status, self.terminal, self.interrupted);
    // The conversation may have read the terminal's width report.
    self.caps.width = screen.vx.caps.unicode;
    const returned = if (ended) |outcome| outcome == .returned else |_| false;
    if (returned) {
        frontend.close();
        self.init.gpa.destroy(frontend);
        for (opened) |file| file.close(io);
        return null;
    }
    return .{ .session = session, .frontend = frontend, .files = files, .ended = ended };
}

/// Every way out: restores the terminal, joins the worker, then writes the
/// guidance and the Detached notice once.
fn finish(self: *Self, ended: anyerror!Ending) !void {
    const restored = self.terminal.finish();
    self.worker.cancel();
    // The core records what became of a start or stop the worker ran.
    var start: ?view.StartResult = null;
    if (self.worker.thread != null) {
        self.worker.join() catch {};
        switch (self.job) {
            .start => start = self.reply.start(),
            .stop => |reference| _ = view.step(&self.state, .{ .stop = .{ .reference = reference, .outcome = self.reply.stop() } }) catch {},
            else => {},
        }
    }
    _ = view.step(&self.state, .{ .depart = start }) catch {};
    var guidance: std.Io.Writer.Allocating = .init(self.init.gpa);
    defer guidance.deinit();
    view.writeDeparture(&self.state, &guidance.writer) catch {};
    const ending = ended catch |err| {
        _ = stderr.write(guidance.written());
        return err;
    };
    switch (ending) {
        .overview => {
            _ = stderr.write(guidance.written());
            try restored;
            try self.terminal.detached(self.options.store, null, null);
        },
        .conversation => |left| return self.leave(left, restored, guidance.written()),
    }
}

/// Lets the conversation the person left join its borrowers and write its
/// guidance, then names the Session to resume.
fn leave(self: *Self, left: Left, restored: anyerror!void, guidance: []const u8) !void {
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
        _ = stderr.write(guidance);
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

fn listPage(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !bool {
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
        .failure => return false,
    }
    return true;
}

fn firstLine(self: *Self, requests: client.Requests, session: []const u8, position: u64, buffer: []u8) !?[]const u8 {
    return switch (try requests.readActivityPrefix(self.options.store, session, position, buffer)) {
        .line => |line| line,
        .failure => null,
    };
}

fn startSession(self: *Self, requests: client.Requests, input: client.MessageInput, reply: *Reply) void {
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
    reply.* = .of(requests.sendCaptured(&captured, &buffer), captured.identity().key.slice());
}

fn stopSession(self: *Self, requests: client.Requests, input: client.SessionStopInput, reply: *Reply) void {
    const io = self.init.io;
    var captured = client.captureSessionStop(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    reply.* = .of(requests.sendCaptured(&captured, &buffer), captured.identity().key.slice());
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
        fn list(_: *Self, _: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !bool {
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
            return true;
        }
    }.list,
    .first_line = struct {
        fn firstLine(_: *Self, _: client.Requests, session: []const u8, position: u64, buffer: []u8) !?[]const u8 {
            Seen.now.line = .{ .session = session[0..6].*, .position = position };
            const text = "Fix the flaky test\nand more";
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        }
    }.firstLine,
    .start = struct {
        fn start(_: *Self, _: client.Requests, input: client.MessageInput, reply: *Reply) void {
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
        fn stop(_: *Self, _: client.Requests, input: client.SessionStopInput, reply: *Reply) void {
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
        return rig.overview.readInput();
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
            if (try overview.complete()) |ending| return ending;
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
    try std.testing.expectEqualStrings("start-handle", overview.started.?.handle.slice());

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
    // Ctrl-D waits in the terminal until the overview is back.
    if (std.c.write(rig.keys[1], "\x04", 1) != 1) return error.TestUnexpectedResult;
    try std.testing.expect(try rig.overview.loop() == .overview);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    // The first tick listed: the worker took the Host read.
    rig.overview.worker.join() catch {};
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    var buffer: [64 * 1024]u8 = undefined;
    const frame = rig.drawn(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[?2026l"));
    // The terminal already shows an unchanged screen.
    try rig.overview.draw();
    try std.testing.expectEqualStrings("", rig.drawn(&buffer));
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

test "a reply is unconfirmed only when the request may have reached the Host" {
    const Sent = client.Stepped(client.MutationSendError, protocol_reply.MutationReply);
    var context: protocol_reply.MutationIdentity = .{ .kind = .message };
    context.session.set("n3w5es") catch unreachable;
    const target: protocol_reply.MutationTarget = .{ .message = .{ .bytes = 5, .digest = @splat(0), .creates_session = true } };
    const accepted: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .accepted = .{ .message = .{ .admission = 1 } } }, .replayed = false } } };
    const started = Reply.of(accepted, "h1");
    try std.testing.expectEqual(.accepted, started.outcome);
    try std.testing.expectEqualStrings("n3w5es", &started.session);
    try std.testing.expectEqualStrings("h1", started.handle.slice());
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    code.set("model_unsupported") catch unreachable;
    const rejected: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .rejected = code }, .replayed = false } } };
    try std.testing.expectEqualStrings("model_unsupported", Reply.of(rejected, "h1").start().failed);
    const unread: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = error.InvalidResponse } };
    try std.testing.expectEqualStrings("h1", Reply.of(unread, "h1").start().unconfirmed);
    // Refused before upload: nothing reached the Host, so the text can go again.
    const unsent: Sent = .{ .failed = .{ .step = .connect, .err = error.Cancelled } };
    try std.testing.expectEqualStrings("Cancelled", Reply.of(unsent, "h1").start().failed);
    const uploaded: Sent = .{ .failed = .{ .step = .upload, .err = error.Cancelled } };
    try std.testing.expectEqualStrings("h1", Reply.of(uploaded, "h1").start().unconfirmed);
    try std.testing.expectEqualStrings("h1", Reply.of(uploaded, "h1").stop().unconfirmed);
    try std.testing.expect(Reply.of(accepted, "h1").stop() == .stopped);
    // A canonical Store failure is unconfirmed and fatal.
    const fenced: Sent = .{ .done = .{ .status = 500, .context = context, .target = target, .answer = error.CanonicalStoreFailure } };
    try std.testing.expectEqual(.fatal, Reply.of(fenced, "h1").outcome);
    try std.testing.expectEqualStrings("h1", Reply.of(fenced, "h1").start().unconfirmed);
    try std.testing.expectEqual(.unconfirmed, Reply.of(unread, "h1").outcome);
}

test "a canonical Store failure ends the overview, which names the start's recovery" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) void {
            reply.* = .unconfirmed("fenced-handle");
            reply.outcome = .fatal;
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

test "a stop whose reply was lost names its request on departure" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) void {
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
    try std.testing.expectEqualStrings("! Unconfirmed stop of k7m2qx: rui request recover stop-handle", rig.overview.state.notice.?.text());
    const guidance = "rui: Stopping k7m2qx was not confirmed; use rui request recover stop-handle. Do not stop it again.\n";
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, &departure.writer);
    try std.testing.expectEqualStrings(guidance, departure.written());
    // A stop still running as the overview ends is named the same way.
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\x18\x18") == null);
    try rig.overview.dispatch();
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(rig.overview.job));
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(guidance ++ guidance, try finishedGuidance(rig, &buffer));
}

/// Runs `finish` over a terminal whose restore failed, which writes nothing
/// to stdout, and returns what it wrote to stderr.
fn finishedGuidance(rig: *Rig, buffer: []u8) ![]const u8 {
    rig.terminal.active = false;
    rig.terminal.result = error.TerminalRestoreFailed;
    var pipe: [2]c_int = undefined;
    try openPipe(&pipe);
    defer for (pipe) |fd| {
        _ = std.c.close(fd);
    };
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    const finished = rig.overview.finish(.overview);
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    try std.testing.expectError(error.TerminalRestoreFailed, finished);
    const count = std.c.read(pipe[0], buffer.ptr, buffer.len);
    return if (count > 0) buffer[0..@intCast(count)] else "";
}

test "a failed terminal restore still prints the departure guidance" {
    var ops = fake_operations;
    ops.start = struct {
        fn start(_: *Self, _: client.Requests, _: client.MessageInput, reply: *Reply) void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.start;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("hello\n") == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: A new Session's start was not confirmed; use rui request recover lost-handle. Do not start it again.\n", try finishedGuidance(rig, &buffer));
}

test "leaving while a start is queued or running says what became of it" {
    var cancellation: client.Cancellation = .{};
    var buffer: [1024]u8 = undefined;
    // Enter and Ctrl-C in one read: the start is queued and never sent.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect((try rig.press("race start\n\x03")).? == .overview);
        try std.testing.expectEqualStrings("rui: The new Session was not started (cancelled); start it again from the overview.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 0), Seen.now.starts);
    }
    // The start ran as the overview ended: the Host accepted it.
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("hello\n") == null);
        try rig.overview.dispatch();
        try std.testing.expectEqualStrings("rui: Session start accepted: n3w5es.\nMessage request: start-handle (rui request inspect start-handle)\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 1), Seen.now.starts);
    }
}

test "terminal keys reach the core as overview keys, and pasted line ends as text" {
    const Case = struct { bytes: []const u8, keys: []const view.Key };
    const cases = [_]Case{
        .{ .bytes = "\n", .keys = &.{.enter} },
        .{ .bytes = "\r", .keys = &.{.enter} },
        .{ .bytes = "\x03\x04\x18\x7f", .keys = &.{ .ctrl_c, .ctrl_d, .ctrl_x, .backspace } },
        .{ .bytes = "\x1b[A\x1b[B\x1b[H\x1b[F", .keys = &.{ .up, .down, .home, .end } },
        .{ .bytes = "a\xc3\xa9", .keys = &.{ .{ .text = "a" }, .{ .text = "\xc3\xa9" } } },
        .{ .bytes = "\x1b[200~a\nb\x1b[201~", .keys = &.{ .{ .text = "a" }, .{ .text = "\n" }, .{ .text = "b" } } },
        // Other control keys do nothing.
        .{ .bytes = "\x01\x1b[1;5A", .keys = &.{} },
    };
    for (cases) |case| {
        var input: TerminalInput = .{};
        var count: usize = 0;
        for (case.bytes) |byte| {
            var decoded = input.feed(byte, 0);
            // Text borrows the decoder until its next event.
            while (decoded != .none) : (decoded = input.next()) if (keyOf(decoded)) |key| {
                try std.testing.expect(count < case.keys.len);
                const want = case.keys[count];
                try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(key));
                if (want == .text) try std.testing.expectEqualStrings(want.text, key.text);
                count += 1;
            };
        }
        try std.testing.expectEqual(case.keys.len, count);
    }
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
