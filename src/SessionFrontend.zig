//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const vaxis = @import("vaxis");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const TerminalInput = @import("TerminalInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const Terminal = @import("SessionTerminal.zig");
const Screen = @import("SessionScreen.zig");
const Frame = @import("TerminalFrame.zig");
const Editor = @import("TerminalEditor.zig");
const keymap = @import("keymap.zig");
const test_poll = @import("test_poll");
const View = @import("session_view.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const Self = @This();

const reads = @import("session_reads.zig");
const session_line = @import("session_line.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
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
store: []const u8,
session: []const u8,
directory: []const u8,
files: Files,
command: Command,
requests: Requests = undefined,
status: Status = undefined,
terminal: *Terminal,
/// Stops when the caller is signalled; a running command stops with it.
interrupted: *client.Cancellation = undefined,
colour: bool,
/// Inside tmux, Shift-Enter reaches Rui as Enter; composing says so.
tmux: bool = false,
input: Input = undefined,
submission: Submission = undefined,
reader: Task = .{},
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
    // The shown inspection page is /status. Each scan replaces it, in the same
    // frame as its page, when anything it reports changed. Its one Current read
    // follows the page's, so it is never older than the history it shows with.
    status_page: bool = false,
    status_digest: u64 = 0,
    // An inspection or Host command started and its result has not been
    // presented. A command may change configuration, so Messages and consent wait
    // for every inspection; exit prints an unshown command's output, which can
    // carry recovery warnings.
    command_running: bool = false,
} = .{},
// Messages sent and what live output has delivered of them.
admission: struct {
    // The newest accepted Message admission not yet in delivered output.
    // Admission order is Session order, so it stands for every earlier one.
    echo: ?u64 = null,
    // The newest Message admission live pages have taken: shown as its
    // conversation row, or at the stop that excluded it.
    delivered: u64 = 0,
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
    // The lowest position of a Message seen unapplied, where a transcript's
    // search for them may stop; a stale value only costs reads.
    lowest: ?u64 = null,
    // The Messages a person or script sent that wait behind the work, as
    // the Host reported them at the cursor; the first line the queued row
    // last read, with its Message; and the newest live output showed while
    // it waited (see View.Taking).
    queued: protocol.Queued = .{},
    queued_line: ?queued_line.Shown = null,
    drawn_waiting: u64 = 0,
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
    pending: bool = false,
    // A Message page asked for, and the one being read. Each holds where it was
    // asked from; Esc, Ctrl-G, a send or a newer Ctrl-O supersedes it.
    requested: ?MessageRequest = null,
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
/// The Session line's facts from the latest read that took them, the
/// unlabelled Session's name, and the line as last written.
line: reads.Line = .{},
hint: reads.Hint = .unread,
shown: session_line.Shown = .{},

/// A short command result shows as a notice up to this size.
const short_result_bytes = 256;
const rejection_suffix = " · /discard clears it";
/// The longest built notice: a rejection with its code escaped (four bytes
/// per byte at most), or a short result with a failure mark on each line.
const notice_capacity = @max("! Decision rejected: ".len + 4 * protocol.max_code_bytes + rejection_suffix.len, short_result_bytes + 2 * "! ".len);

/// Fills the reader's job in place; the caller may add to it before launch.
fn freeze(self: *Self, phase: ReadPhase) *Job {
    std.debug.assert(self.reader.thread == null);
    self.job = .{ .init = self.init, .store = self.store, .session = self.session, .files = self.files, .colour = self.colour, .command = self.command, .requests = self.requests, .status = self.status, .phase = phase, .cursor = self.live.cursor, .opening = self.reading.opening, .older = self.transcript.older, .listing = if (phase == .history) self.transcript.plan.next() else null, .messages = self.live.messages, .queued = self.live.queued, .drawn_waiting = self.live.drawn_waiting, .queued_line = if (self.live.queued_line) |shown| shown.admission else 0, .transcript = self.transcript.id, .held = self.live.work.state.holdsQueue(), .inspection_kind = self.inspection.kind, .interrupted = self.interrupted, .line_read = self.line.read, .hint_wanted = self.hint == .unread };
    const job = &self.job;
    if (phase == .activity or phase == .permission) {
        job.open_status = self.inspection.status_requested;
        job.watch_status = self.inspection.status_page and self.terminal.screen.view == .inspection;
        job.status_shown = self.inspection.status_digest;
        // The page reports the submission the UI shows with it.
        if (job.open_status or job.watch_status) job.inspection_submission = self.submission.view();
    }
    job.result.compact_tools = self.live.compact_tools;
    return job;
}

/// Starts the job `freeze` filled.
fn launch(self: *Self, job: *const Job, worker: Task.Run) !void {
    std.debug.assert(self.reader.thread == null and job == &self.job);
    self.reading.phase = job.phase;
    self.reading.output_started = false;
    try self.reader.start(self.init.io, &self.job, worker);
}

/// How the frontend stopped. Either way it stopped only its own client waits;
/// Host work it started continues. `returned` goes back to the overview that
/// lent the terminal, which stays begun.
pub const Outcome = enum { detached, interrupted, returned };

/// Draws the Session on a lent terminal until the person leaves or the caller's
/// `interrupted` stops. Returns with the terminal still begun and the reader,
/// the Admission wait and any running command told to stop but not joined. The
/// caller restores the terminal before `leave` joins them, so a borrower that
/// cannot stop at once never holds the terminal raw. `self` stays in the
/// caller's storage until `leave` returns.
pub fn run(self: *Self, init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, requests: Requests, status: Status, terminal: *Terminal, interrupted: *client.Cancellation) !Outcome {
    self.* = .{ .init = init, .store = store, .session = session, .directory = directory, .files = files, .command = command, .requests = requests, .status = status, .terminal = terminal, .interrupted = interrupted, .colour = terminal.screen.colour, .tmux = init.environ_map.get("TMUX") != null };
    self.input.init();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input };
    terminal.pump = .{ .context = self, .step = pump };
    defer terminal.pump = null;
    defer self.stop();
    self.driveActive() catch |err| switch (err) {
        // A pumped write reports a detach as an interruption too.
        error.InteractiveInterrupted => return if (interrupted.stopped.load(.acquire)) .interrupted else self.leaving orelse .detached,
        else => return err,
    };
    return self.leaving orelse .detached;
}

/// After `run` returned `returned`, which Esc only asks for: settles the
/// stopped borrowers as `leave` does, while the terminal stays lent. Esc
/// needs no running command and no unresolved submission, so they observe
/// their stop within one transport poll. Null goes back to the overview;
/// a failure or recovery to show is instead the ending of a normal `leave`.
pub fn back(self: *Self) ?(anyerror!Outcome) {
    std.debug.assert(self.leaving == .returned);
    const plan = departure.exit(self.settle({}), null, self.submission.view() != null);
    if (plan.failure) |err| return err;
    if (plan.recovery_before_notice or self.reading.pending_diagnostic != null) return .detached;
    self.submission.close();
    return null;
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

/// Joins what `run` stopped, after the caller restored the terminal, and writes
/// the guidance that follows restoration. The caller prints the Detached notice.
pub fn leave(self: *Self, ended: anyerror!Outcome, restored: anyerror!void) Departure {
    std.debug.assert(!self.terminal.active);
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
    const action_view = self.terminal.screen.action_view != null;
    return .{
        .end = if (plan.failure) |err| err else ended,
        .action = if (action_view) self.live.work.first_action else null,
        // Never a main-screen notice before confirmed restoration.
        .failure_notice = action_view and !std.meta.isError(restored),
        .recovery_shown = plan.recovery_before_notice,
    };
}

fn stop(self: *Self) void {
    // A running command observes exit as an interruption, exactly as a signal.
    if (self.inspection.command_running) self.interrupted.requestStop();
    self.reader.cancel();
    self.submission.cancel();
}

fn settle(self: *Self, restored: anyerror!void) Settled {
    const reader = self.joinReader();
    const admission = self.joinAdmission();
    return .{ .restored = restored, .reader = reader, .admission_error = admission.failure() };
}

test "run returns detached on Ctrl-D and leaves the lent terminal begun, with no notice written" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    const page = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    var input: [2]c_int = undefined;
    var output: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&input) == 0);
    try std.testing.expect(std.c.pipe(&output) == 0);
    defer for (input ++ output) |fd| {
        _ = std.c.close(fd);
    };
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    _ = std.c.fcntl(output[0], std.c.F.SETFL, std.c.fcntl(output[0], std.c.F.GETFL) | nonblock);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(input[1], "\x04", 1));
    var terminal: Terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = screen, .input = input[0], .output = output[1] };
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    init.environ_map = &environ;
    var interrupted: client.Cancellation = .{};
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    const files: Files = .{ .scratch = page, .action = page, .inspection = page, .status = page };
    const outcome = try self.run(init, store, "k7m2qx", store, files, undefined, undefined, undefined, &terminal, &interrupted);
    try std.testing.expectEqual(Outcome.detached, outcome);
    try std.testing.expect(terminal.active and terminal.pump == null);
    var written: [65536]u8 = undefined;
    const count = @max(std.c.read(output[0], &written, written.len), 0);
    try std.testing.expect(std.mem.indexOf(u8, written[0..@intCast(count)], "Detached") == null);
    // The caller's part: nothing has restored the terminal, so only the
    // borrowers run stopped are joined here.
    self.reader.join() catch {};
    _ = self.submission.join();
    self.submission.close();
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
    switch (self.submission.recovery()) {
        .none => {},
        .not_sent => |kind| try out.print("rui: {s} was not sent: capture did not begin. You may submit it again; no recovery record was published for this attempt.\n", .{if (kind == .decision) "Decision" else "Message"}),
        .uncertain => |key| try out.print("rui: Capture not confirmed. Inspect rui request list for reserved key {s}; reservation does not prove publication. Recover only that original, never replacement input.\n", .{key}),
        .saved => |saved| {
            if (saved.rejected) {
                try out.print("rui: Original request rejected. Use rui request inspect {s} to inspect its saved outcome.\n", .{saved.original.key});
            } else try out.print("rui: {s} not confirmed. Use rui request recover {s} to retry the exact original; do not resubmit it.\n", .{ if (saved.original.kind == .decision) "Decision" else "Message", saved.original.key });
        },
        .accepted => |accepted| {
            if (accepted.kind == .message) {
                try out.print("rui: Message accepted; do not resubmit it. Use rui request read-result {s} for the same Message's answer.\n", .{accepted.key});
            } else try out.print("rui: Decision accepted; do not repeat it. Use rui request inspect {s} to inspect the same saved admission.\n", .{accepted.key});
        },
    }
}

test "frontend exit guidance preserves accepted identity and never substitutes it for current intent" {
    const key = "01234567-89ab-4cde-8012-0123456789ab";
    const cases = .{
        .{ Submission.Kind.message, "rui: Message accepted; do not resubmit it. Use rui request read-result " ++ key ++ " for the same Message's answer.\n" },
        .{ Submission.Kind.decision, "rui: Decision accepted; do not repeat it. Use rui request inspect " ++ key ++ " to inspect the same saved admission.\n" },
    };
    inline for (cases) |case| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .accepted = .{ .kind = case[0], .key = key.* } };
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

/// Every slash command the draft accepts.
const Slash = union(enum) {
    exit,
    history: History,
    /// Waits for the reader, then shows its page; Host commands included.
    inspection: Inspection,
    discard,
    recover: []const u8,
    wait,
    login,
    unknown,
};

fn parse(text: []const u8) Slash {
    const exact = [_]struct { []const u8, Slash }{
        .{ "/exit", .exit },
        .{ "/history", .{ .history = .older } },
        .{ "/details", .{ .history = .latest } },
        .{ "/status", .{ .inspection = .status } },
        .{ "/requests", .{ .inspection = .requests } },
        .{ "/help", .{ .inspection = .help } },
        .{ "/inspect-action", .{ .inspection = .command } },
        .{ "/setup", .{ .inspection = .command } },
        .{ "/configure", .{ .inspection = .command } },
        .{ "/copy", .{ .inspection = .{ .copy = .answer } } },
        .{ "/copy code", .{ .inspection = .{ .copy = .code } } },
        .{ "/copy file", .{ .inspection = .{ .copy = .file } } },
        .{ "/discard", .discard },
        .{ "/wait", .wait },
        .{ "/login", .login },
    };
    for (exact) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
    for ([_][]const u8{ "/setup ", "/configure ", "/result " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return .{ .inspection = .command };
    }
    if (std.mem.startsWith(u8, text, "/recover ")) return .{ .recover = text["/recover ".len..] };
    return .unknown;
}

/// The page asked for last is the one shown: a /status not yet rendered
/// yields to a later /history or /details.
fn requestHistory(self: *Self, history: History) void {
    self.transcript.history_requested = history;
    self.inspection.status_requested = false;
}

/// Runs one slash command the draft admitted; it never decides. Local
/// commands answer at once; an inspection queues for the reader.
fn slashCommand(self: *Self, text: []const u8) void {
    switch (parse(text)) {
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
            self.submission.requestRecovery(key) catch {
                self.notice = "! Recovery key does not match this original submission; nothing sent.";
            };
        } else self.unknownCommand(text),
        .wait => self.notice = "Work continues while you compose.",
        .login => self.notice = "Login uses rui auth login codex in your shell.",
        .unknown => self.unknownCommand(text),
    }
}

fn unknownCommand(self: *Self, text: []const u8) void {
    // Name the command only when it is short printable ASCII.
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    var shown = name.len <= 32;
    for (name) |byte| shown = shown and byte > ' ' and byte < 0x7f;
    var writer = std.Io.Writer.fixed(&self.notice_buffer);
    writer.print("! Unknown command{s}{s} · /help", .{ if (shown) " " else "", if (shown) name else "" }) catch unreachable;
    self.notice = writer.buffered();
}

test "frontend answers local and unknown commands in place and keeps Host commands for inspection" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
    const cases = .{
        .{ "/foo bar", "! Unknown command /foo · /help" },
        .{ "/\x1b[2J", "! Unknown command · /help" },
        .{ "/result", "! Unknown command /result · /help" },
        .{ "/recover 01234567-89ab-4cde-8012-0123456789ab", "! Unknown command /recover · /help" },
        .{ "/wait", "Work continues while you compose." },
        .{ "/configure --permission-mode ask", "" },
        .{ "/result 01234567-89ab-4cde-8012-0123456789ab", "" },
        .{ "/inspect-action", "" },
        .{ "/status", "" },
        .{ "/copy", "" },
        .{ "/copy code", "" },
        .{ "/copy file", "" },
        .{ "/copy all", "! Unknown command /copy · /help" },
    };
    inline for (cases) |case| {
        self.notice = null;
        self.slashCommand(case[0]);
        if (case[1].len != 0) {
            try std.testing.expectEqualStrings(case[1], self.notice.?);
            try std.testing.expect(self.input.queuedCommand() == null);
        } else {
            try std.testing.expect(self.notice == null);
            try std.testing.expectEqualStrings(case[0], self.input.takeCommand().?);
        }
    }
}

test "frontend consumed canonical reader and admission failures survive external interruption" {
    const Worker = struct {
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.CanonicalStoreFailure;
        }
    };
    for ([_]bool{ false, true }) |admission| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
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
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .leaving = .returned };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
        // The reader is still running as Esc returns.
        try self.reader.start(std.testing.io, &self, case[0]);
        self.stop();
        const failure: ?anyerror = if (self.back()) |ending| if (ending) |_| error.TestUnexpectedResult else |err| err else null;
        try std.testing.expectEqual(case[1], failure);
    }
}

test "frontend cleanup joins both borrowers before reporting restoration failure" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *Task) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
        fn admit(_: *anyopaque, _: *Task) !void {
            return error.CanonicalStoreFailure;
        }
    };
    for ([_]ReadPhase{ .activity, .permission, .history, .details }) |phase| {
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .reading = .{ .phase = phase } };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .intent = .{ .message = self.input.submitText("current original B") } };
        try self.reader.start(std.testing.io, &self, Worker.read);
        try self.submission.task.start(std.testing.io, &self, Worker.admit);
        self.stop();
        const settled = self.settle(error.TerminalRestoreFailed);
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(.inspection, error.InteractiveInterrupted).?);
        try std.testing.expectEqual(error.CanonicalStoreFailure, settled.admission_error.?);
        try std.testing.expect(settled.reader == .cancelled);
        try std.testing.expect(self.reader.thread == null and self.submission.task.thread == null);
        // A second cleanup cannot reconstruct or consume the errors again.
        self.stop();
        const repeated = self.settle({});
        try std.testing.expect(repeated.reader == .absent and repeated.admission_error == null);
    }
}

fn driveActive(self: *Self) !void {
    while (self.leaving == null) {
        if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
        const size = self.terminal.geometry();
        if (size.row != self.terminal.size.row or size.col != self.terminal.size.col) self.dirty = true;
        const admission = try self.submission.advance();
        try self.presentAdmission(admission);
        if (admission.failure()) |err| if (err == error.CanonicalStoreFailure) return err;
        if (self.input.queuedCommand()) |text| if (parse(text).inspection == .status) {
            // /status is the next scan's: one capture for the page, the
            // history and the composer status.
            _ = self.input.takeCommand();
            try self.terminal.screen.latest();
            self.inspection.status_requested = true;
            self.poll_at = 0;
        };
        if (self.input.queuedCommand() != null and self.reader.thread != null and !self.reader.completed()) {
            // No read shows anything before it joins, so an inspection
            // supersedes it. Keep servicing input until completion; never join
            // unfinished work in raw mode.
            self.reader.cancel();
        }
        // A joined read may hide or withdraw the Action, so a sequence the
        // choice is decoding finishes there first and keeps its meaning.
        if (self.reader.thread != null and self.reader.completed() and !(self.terminal.screen.inputRow() == .selector and self.input.pending() != .none)) {
            try self.settleReader();
            self.withdrawDecided();
        }
        if (self.reading.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(self.terminal);
        }
        if (self.reader.thread == null) if (self.input.takeCommand()) |text| {
            const kind = parse(text).inspection;
            // Input goes to the editor the latest frame shows; this stales
            // it, so the view returned to is drawn while the inspection runs.
            try self.terminal.screen.latest();
            self.inspection.kind = kind;
            // The worker borrows its own copy; the editor may queue another.
            const job = self.freeze(.inspection);
            @memcpy(job.command_text[0..text.len], text);
            job.command_text_length = text.len;
            job.inspection_submission = self.submission.view();
            const consent = self.terminal.screen.consent;
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
        // Scans continue during consent, so an Action decided elsewhere leaves.
        if (self.reader.thread == null and self.reading.prepared_action == null) {
            if (self.transcript.history_requested != null and !self.reading.opening) {
                const requested = self.transcript.history_requested.?;
                self.transcript.history_requested = null;
                if (requested == .latest) {
                    try self.terminal.screen.latest();
                    self.admission.details_sent = self.admission.sent;
                    try self.launch(self.freeze(.details), reads.history);
                } else {
                    // /history scrolls the transcript to its top; older pages
                    // then load there as for any scroll.
                    const screen = self.terminal.screen;
                    if (screen.view != .transcript) {
                        try screen.latest();
                        if (screen.view == .live) try self.beginTranscript();
                    }
                    if (screen.view == .transcript) screen.browsing.top = .{} else self.notice = "/history opens once the Action is decided.";
                    self.dirty = true;
                }
            }
            if (self.reader.thread == null) if (self.expansion.requested) |request| {
                self.expansion.requested = null;
                self.expansion.reading = request;
                const job = self.freeze(.message);
                job.message_target = request.target;
                try self.launch(job, reads.fullMessage);
            };
            // An Action's choice holds the input: no press waits for it.
            if (self.terminal.screen.inputRow() == .selector) {
                self.input.dropPresses();
            } else if (self.reader.thread == null and !self.reading.opening) if (self.input.nextStep()) |recall| {
                const job = self.freeze(.recall);
                job.recall = recall;
                try self.launch(job, reads.recall);
            };
            if (self.reader.thread != null) {} else if (self.olderWanted()) {
                self.notice = "Loading earlier messages…";
                try self.launch(self.freeze(.history), reads.history);
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                try self.launch(self.freeze(.activity), reads.scan);
            } else if (self.terminal.screen.consent == null and !self.reading.opening and self.submission.view() == null and self.live.work.first_action != null and self.input.pending() == .none) {
                try self.launch(self.freeze(.permission), reads.permission);
            }
        }
        // Input routes by the latest frame's editor. Once a transition revokes
        // that frame, draw its replacement before reading further input.
        for (0..1024) |_| {
            if (try self.step(0) != .byte) break;
            if (self.leaving != null or self.terminal.screen.stale()) break;
        }
        if (self.leaving != null) break;
        // Finish chat paste/UTF-8 under its original decoder before consent.
        if (self.reader.thread == null and self.reading.prepared_action != null and self.input.pending() == .none) {
            // Preparation is complete and the file remains immutable through
            // this choice. A bounded preview is export-only, never consent.
            try self.terminal.screen.adopt(self.init.io, self.files.action, self.reading.prepared_action.?, self.input.composition().bytes.len == 0);
            self.action_summary = self.reading.prepared_summary;
            self.reading.prepared_action = null;
            self.reading.phase = .activity;
        }
        self.withdrawDecided();
        if (self.dirty or self.terminal.screen.stale()) if (try self.draw()) break;
        if (self.expansion.pending) try self.expand();
        _ = try self.step(16);
    }
}

/// Draws a frame, applies its receipt and, when the screen says that frame
/// awaits its offer, services input for the empty-input gate. Returns true
/// when that service detached the caller.
fn draw(self: *Self) !bool {
    const screen = self.terminal.screen;
    try self.drawFrame();
    if (screen.awaitsOffer()) {
        // Every prompt byte was accepted by stdout. Discard input through
        // its decoder, not tcflush: a paste prefix or Ctrl-C arriving
        // during the final write must retain its meaning.
        var service: ConsentPolicy.Service = .budget_exhausted;
        for (0..1024) |_| {
            service = try self.step(0);
            if (service != .byte) break;
            service = .budget_exhausted;
            if (self.leaving != null) break;
        }
        if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
        if (self.leaving != null) return true;
        if (self.consentReceipt(service)) try Editor.testChoiceReady(self.init.io);
    }
    return false;
}

/// The post-write consent observation: input serviced after a delivered
/// decision prompt offers it only when nothing arrived or remains.
fn consentReceipt(self: *Self, service: ConsentPolicy.Service) bool {
    return self.terminal.screen.promptCompleted(service, self.input.pending() != .none, self.commandActive() or self.dirty);
}

/// Writes one frame and applies its receipt.
fn drawFrame(self: *Self) !void {
    const screen = self.terminal.screen;
    const waiting = screen.consent != null;
    const view = self.input.composition();
    // A waiting Action says how to decide it under the input, not here. A
    // sent Message reads Sent until live output shows it: as its row, at
    // its stop, or in the queued row, which the frame may drop.
    const submission_status: ?[]const u8 = if (self.reading.opening) "Opening…" else if (waiting) "" else if (self.submission.view()) |submission| switch (submission.state) {
        .not_started => "Not sent · Ctrl-R retries original",
        .submitting => "Sending…",
        .unconfirmed => if (submission.kind == .decision) "! Decision not confirmed · Ctrl-R retries original" else "! Not confirmed · Ctrl-R retries original",
        .rejected => "Rejected · /discard",
    } else null;
    const base_status = submission_status orelse if (self.admission.echo != null) "Sent" else "";
    // A waiting Action speaks for itself; elsewhere the work says what it is
    // doing now, on every view.
    const now_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
    var live_words: [work_line.max_words_bytes]u8 = undefined;
    const live = if (waiting) null else work_line.of(&live_words, &self.live.work.state, self.live.work.operation, now_ms);
    var context_buffer: [4 * std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var context = std.Io.Writer.fixed(&context_buffer);
    if (screen.actionVisible())
        try approvalContext(&context, screen.actionTopHidden(), self.action_summary)
    else if (self.tmux and !waiting and view.bytes.len != 0)
        try context.writeAll("In tmux, Shift-Enter sends · Alt-J adds a line");
    var status_buffer: [Frame.status_capacity]u8 = undefined;
    const status = statusLines(&status_buffer, context.buffered(), base_status);
    var queued_buffer: [Frame.status_capacity]u8 = undefined;
    const queued: ?Screen.Footer.Queued = if (self.queuedRow()) |row| .{
        .waiting = row.waiting,
        .status = statusLines(&queued_buffer, context.buffered(), submission_status orelse if (self.admission.echo) |echo| (if (echo <= row.newest) "" else "Sent") else ""),
    } else null;
    self.dirty = false;
    // Reading completes only after delivery; the receipt stales the frame.
    _ = screen.presented(try self.terminal.redraw(view.bytes, view.cursor, .{ .command = self.commandActive(), .status = status, .notice = self.notice orelse "", .session = if (self.line.facts(&self.hint, self.session)) |facts| .{ .facts = facts, .shown = &self.shown } else null, .live = live, .queued = queued }, &self.live.view));
}

// A notice fits the rows under the input as the status fits above it.
comptime {
    std.debug.assert(@typeInfo(@FieldType(Self, "notice_buffer")).array.len <= Frame.status_capacity);
}

/// The instructions always fit; a long context line is shortened, on a
/// UTF-8 boundary, rather than pushing them out of the status region.
fn statusLines(buffer: *[Frame.status_capacity]u8, context: []const u8, base: []const u8) []const u8 {
    std.debug.assert(base.len <= 256);
    var status = std.Io.Writer.fixed(buffer);
    const room = buffer.len - base.len - "\n…".len;
    var context_line = context;
    if (context_line.len > room) {
        var end = room;
        while (end > 0 and (context_line[end] & 0xc0) == 0x80) end -= 1;
        context_line = context_line[0..end];
    }
    for ([_][]const u8{ context_line, base }, 0..) |line, index| {
        if (line.len == 0) continue;
        if (status.buffered().len != 0) status.writeAll("\n") catch unreachable;
        status.writeAll(line) catch unreachable;
        if (index == 0 and line.len < context.len) status.writeAll("…") catch unreachable;
    }
    return status.buffered();
}

test "status lines keep the instructions beside an oversized context" {
    var buffer: [Frame.status_capacity]u8 = undefined;
    // A context whose cut falls inside a two-byte scalar.
    var context: [4000]u8 = undefined;
    for (0..context.len / 2) |index| context[index * 2 ..][0..2].* = "é".*;
    const lines = statusLines(&buffer, &context, "Sent");
    try std.testing.expect(std.mem.endsWith(u8, lines, "…\nSent"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(lines));
    try std.testing.expectEqualStrings("Sent", statusLines(&buffer, "", "Sent"));
    try std.testing.expectEqualStrings("? Delete /w\nSent", statusLines(&buffer, "? Delete /w", "Sent"));
}

/// Another client decided, or the Turn ended: the choice can no longer decide.
/// It leaves before more input is read, so no key decides; a fragmented
/// sequence finishes at the choice first and keeps its meaning.
fn withdrawDecided(self: *Self) void {
    const pending = self.terminal.screen.consent orelse return;
    if (self.live.work.first_action == pending.action or self.input.pending() != .none) return;
    self.terminal.screen.withdrawAction();
}

/// A paged Action keeps what it is for above the rule once paging hides its
/// `?` row; it leaves again when that row is back on screen.
fn approvalContext(out: *std.Io.Writer, top_hidden: bool, summary: View.ActionSummary) !void {
    if (!top_hidden) return;
    try out.writeAll("?");
    if (summary.description.slice().len != 0) {
        try out.writeAll(" ");
        var label: TerminalText = .{ .mode = .line };
        try label.feed(out, summary.description.slice());
        try label.finish(out);
    }
}

test "a paged Action keeps what it is for beside the choice" {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var summary: View.ActionSummary = .{};
    try summary.description.set("Record\x1b[2J steps");
    try approvalContext(&out, false, summary);
    try std.testing.expectEqualStrings("", out.buffered());
    try approvalContext(&out, true, summary);
    try std.testing.expectEqualStrings("? Record\\x1b[2J steps", out.buffered());
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = try self.step(16);
    if (self.leaving != null or self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
}

fn beginMessage(self: *Self, ticket: Input.Ticket) !void {
    // Input can arrive with Enter before any redraw, including inside output
    // pumping. Sealed bytes render in the escaped transcript, not the composer.
    const size = self.terminal.geometry();
    Frame.validateGeometry(size.col, size.row) catch |err| {
        self.input.release(ticket) catch unreachable;
        return err;
    };
    try self.submission.begin(.{ .message = ticket });
    // A sent Message continues the conversation: show it and its reply
    // rather than the frozen transcript or page the reader was browsing,
    // or a page asked for before it.
    self.admission.sent += 1;
    self.inspection.status_requested = false;
    self.transcript.history_requested = null;
    self.dropMessageRequest();
    try self.terminal.screen.latest();
}

/// A queued or running command holds the choice until it completes.
fn commandActive(self: *const Self) bool {
    return self.input.queuedCommand() != null or self.inspection.command_running;
}

/// What a key does in a conversation, beside the draft or an Action's choice.
const ConversationAction = enum {
    page_up,
    page_down,
    scroll_up,
    scroll_down,
    /// On an empty or recalled draft, the Message sent before the one it
    /// shows.
    older,
    /// On a recalled draft, the Message sent after it, or past the newest
    /// an empty draft.
    newer,
    /// The latest view, which is the pending Action if there is one.
    latest,
    /// Out of a Message page, else to the latest view. It never leaves the
    /// conversation.
    back,
    /// As `back`, and from the settled latest view, once nothing would be
    /// lost, to the overview.
    close,
    /// Opens the lowest collapsed Message, or leaves a Message page.
    expand,
    /// Leaves the conversation; Host work continues.
    detach,
    /// Retries the uncertain original.
    recover,
};

/// The conversation's one key table.
const conversation_keys: keymap.Keymap(ConversationAction) = .init(.{
    .escape = .close,
    // A lone ESC acts only once it expires; Ctrl-G acts at once.
    .ctrl_g = .close,
    .ctrl_c = .detach,
    .ctrl_d = .detach,
    .ctrl_n = .newer,
    .ctrl_o = .expand,
    .ctrl_p = .older,
    .ctrl_r = .recover,
    .ctrl_x = null,
    .up = .scroll_up,
    .down = .scroll_down,
    .shift_up = .scroll_up,
    .shift_down = .scroll_down,
    .page_up = .page_up,
    .page_down = .page_down,
    .home = null,
    .end = .back,
    .ctrl_end = .latest,
});

fn perform(self: *Self, action: ConversationAction) !void {
    const screen = self.terminal.screen;
    switch (action) {
        .page_up, .page_down, .scroll_up, .scroll_down => try self.scroll(action == .page_down or action == .scroll_down, action == .page_up or action == .page_down),
        .older, .newer => if (self.input.press(action == .older) == .typed) {
            self.notice = "Ctrl-P recalls sent messages once the draft is empty.";
        },
        .latest, .back, .close => {
            // Leaving also abandons a Message page not yet shown, and returns
            // the input row to a waiting Action's choice.
            self.dropMessageRequest();
            screen.moveRow(.selector);
            if (action == .close and self.settledView()) {
                if (self.submission.view()) |submission| {
                    self.notice = switch (submission.state) {
                        .rejected => "Esc returns to the overview once /discard clears the rejected original.",
                        .submitting => "Esc returns to the overview once the original is confirmed.",
                        .not_started, .unconfirmed => "Esc returns to the overview once Ctrl-R retries the original.",
                    };
                } else if (self.input.composition().bytes.len == 0) {
                    self.leaving = .returned;
                    return;
                } else {
                    // No draft outlives the frontend, so leaving would lose it.
                    self.notice = "Esc returns to the overview once the draft is empty.";
                }
            }
            if (action != .latest and screen.view == .message) try screen.leaveMessage() else try screen.latest();
        },
        .expand => if (screen.view == .message) try screen.leaveMessage() else {
            // A newer Ctrl-O replaces any page asked for before it, even
            // before its own target is found, or if none is.
            self.dropMessageRequest();
            self.expansion.pending = true;
        },
        .detach => self.leaving = .detached,
        // While approval is paused, recovery waits for the Action and the
        // paused draft stays as it is.
        .recover => if (screen.consent != null) {
            self.notice = self.decisionNotice();
        } else try self.submission.requestRecovery(null),
    }
    self.dirty = true;
}

fn scroll(self: *Self, down: bool, page: bool) !void {
    const screen = self.terminal.screen;
    if (screen.view == .live) {
        if (down) return; // Live output already shows the latest rows.
        try self.beginTranscript();
    }
    self.transcript.older_failed = false; // A new scroll may retry a failed load.
    if (screen.browse(down, page)) try screen.latest();
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
    const screen = self.terminal.screen;
    return screen.view == .live and screen.action_view == null and self.live.work.first_action == null and
        self.reading.prepared_action == null and !self.commandActive();
}

const MessageRequest = struct { target: View.Collapsed, view: Screen.ViewKind, transcript: u64, sent: u64, generation: u64 };

/// No Message page asked for so far opens.
fn dropMessageRequest(self: *Self) void {
    self.expansion.generation += 1;
    self.expansion.requested = null;
    self.expansion.pending = false;
}

/// Ctrl-O: opens the lowest collapsed Message the latest frame drew.
fn expand(self: *Self) !void {
    self.expansion.pending = false;
    self.dirty = true;
    const screen = self.terminal.screen;
    if (screen.view != .live and screen.view != .transcript) {
        self.notice = "! Ctrl-O opens a collapsed message from the conversation.";
        return;
    }
    const index = screen.collapsedInView() orelse {
        self.notice = "No collapsed message in view; scroll to one, then Ctrl-O.";
        return;
    };
    const blocks = if (screen.view == .live) &self.live.blocks else &self.transcript.blocks;
    const target = blocks.fromEnd(index) orelse {
        self.notice = "! That message's full text is no longer held here; /history shows it again.";
        return;
    };
    self.expansion.requested = .{ .target = target, .view = screen.view, .transcript = self.transcript.id, .sent = self.admission.sent, .generation = self.expansion.generation };
    self.notice = "Opening message…";
}

/// Freezes live output for scrolling. The copy starts at a recorded read
/// boundary, so older canonical pages continue it without a gap. With none
/// retained, the gap's shown Messages and those at its seam are listed above
/// the copy, and older pages continue before the newest boundary that left.
fn beginTranscript(self: *Self) !void {
    const screen = self.terminal.screen;
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
    const screen = self.terminal.screen;
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

fn olderWanted(self: *const Self) bool {
    return (self.transcript.plan.next() != null or self.transcript.older != null) and !self.transcript.older_failed and self.terminal.screen.transcriptAtTop() and !self.reading.opening;
}

fn step(self: *Self, wait: i32) !ConsentPolicy.Service {
    const stream = &self.input.stream;
    const pending = stream.pending();
    const read = (self.terminal.next(self.init.io, stream, wait) catch |err| switch (err) {
        error.InputDeadline => {
            const expired = try stream.expire();
            if (expired != .none) try self.inputEvent(expired);
            // Successful expiry releases decoder custody. Revisit redraw and
            // its drained-input readiness gate, just as after ordinary input.
            self.dirty = true;
            return .decoder_expired;
        },
        else => return err,
    }) orelse return if (pending == .none) .empty else .decoder_pending;
    self.notice = null;
    self.dirty = true;
    // One stream decodes every byte; replies never reach an editor, and an
    // event left in a suffix is delivered in order before the next byte.
    var decoded = stream.feed(read.byte, read.at);
    while (decoded != .none) : (decoded = stream.next()) switch (decoded) {
        .report => |report| switch (report) {
            .width => |method| self.terminal.screen.setWidth(method),
            .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
        },
        else => try self.inputEvent(decoded),
    };
    return .byte;
}

/// The entry of every input. It spends the offer first, whatever the key
/// does; only an arrow or Enter at the choice may use it. The input row the
/// latest frame shows takes the input.
fn inputEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const screen = self.terminal.screen;
    const offer = screen.spendOffer();
    if (screen.inputRow() == .selector) try self.choiceEvent(decoded, offer) else try self.draftEvent(decoded);
    if (self.leaving != null) screen.interruptConsent();
}

/// One input at an Action's Allow once / Deny choice. Only arrows and Enter
/// act on it, and only with the offer this input spent.
fn choiceEvent(self: *Self, decoded: TerminalInput.Decoded, offer: ?u64) !void {
    const screen = self.terminal.screen;
    switch (Editor.select(conversation_keys, decoded)) {
        .none => {},
        // While an Action waits there is no original to retry.
        .action => |action| switch (action) {
            .recover => self.notice = "! Action needs a decision; nothing to retry.",
            // The draft is not the choice's; its sent Messages wait.
            .older, .newer => {},
            else => try self.perform(action),
        },
        .left => try self.choose(.{ .pick = .allow_once }, offer),
        .right => try self.choose(.{ .pick = .deny }, offer),
        .enter => try self.choose(.enter, offer),
        // The draft takes this key and those after it, beside the Action;
        // while a command runs, neither a Message nor a command could go.
        .text => if (screen.selected.approval == .held) {
            self.notice = "! Command still running. Input ignored.";
        } else {
            screen.moveRow(.draft);
            try self.draftEvent(decoded);
        },
        .refused => self.notice = "! Key combination not recognized; nothing authorized.",
    }
}

/// An arrow or Enter at the choice, probed against current geometry,
/// command and the offer; one that cannot act says why.
fn choose(self: *Self, key: Screen.ChoiceKey, offer: ?u64) !void {
    const screen = self.terminal.screen;
    switch (screen.choose(key, offer, self.terminal.geometry(), self.commandActive())) {
        .picked => {},
        .decision => |selected| {
            // Consumption precedes fallible submission.
            screen.releaseAction();
            try self.submission.begin(.{ .decision = .{ .action = selected.action, .decision = switch (selected.choice) {
                .allow_once => .allow_once,
                .deny => .deny,
            } } });
        },
        .blocked => |why| self.notice = switch (why) {
            .reading => "! Read the whole Action first; nothing authorized.",
            .command => "! Command still running. Nothing authorized.",
            .not_ready, .layout => "! Not ready; nothing authorized.",
        },
    }
}

/// Why a draft waits for the Action: a previewed Action is decided only in the shell.
fn decisionNotice(self: *const Self) []const u8 {
    const screen = self.terminal.screen;
    if (screen.consent.?.presentation == .preview) return "! Approval disabled · /help for exact shell commands. Draft retained.";
    return if (screen.actionVisible()) "! Action needs a decision; Esc returns to the choice. Draft retained." else "! Action needs a decision; Esc returns to it. Draft retained.";
}

fn draftEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const submission = self.submission.view();
    // A Message waits for a pending command, which may change its configuration.
    // A live probe immediately before sealing, with no effect between them.
    const allowed = ConsentPolicy.messageAllowed(self.terminal.screen.consent, .{
        .opening = self.reading.opening,
        .permission_preparing = self.reading.phase == .permission,
        .command = self.commandActive(),
        .original = if (submission) |value| (if (value.kind == .decision) .decision else .message) else .none,
    });
    switch (self.input.applySelected(conversation_keys, decoded, allowed)) {
        .message => |ticket| {
            try self.beginMessage(ticket);
        },
        .command => {
            self.slashCommand(self.input.composition().bytes);
            self.input.clear();
        },
        .busy => self.notice = if (self.commandActive()) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.reading.phase == .permission) "! Action needs a decision. Draft retained." else if (self.terminal.screen.consent != null) self.decisionNotice() else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |outcome| switch (outcome) {
            .action => |action| try self.perform(action),
            .refused => |why| self.notice = switch (why) {
                .invalid, .edit_rejected => "! Input rejected; nothing sent. Enter plain text or paste again.",
                .unbound => "! Key combination not recognized; ignored. Draft unchanged.",
                .overflow => "! input too long; nothing sent. Draft cleared. Enter a shorter message.",
            },
            .none, .append, .redraw, .submit => {},
        },
    }
}

fn joinAdmission(self: *Self) AdmissionEnd {
    const end = self.submission.join();
    self.presentAdmission(end) catch |err| return .{ .failed = .{ .err = err } };
    return end;
}

fn presentAdmission(self: *Self, end: AdmissionEnd) !void {
    if (end == .absent) return;
    self.dirty = true;
    switch (end) {
        .accepted => |accepted| {
            self.poll_at = 0;
            // A page may have delivered it before this acceptance joined.
            if (accepted.admission) |admission| self.admission.echo = if (admission > self.admission.delivered) admission else null;
            if (accepted.confirmed) self.notice = if (accepted.kind == .decision) "  • Decision confirmed." else "  • Original confirmed.";
        },
        .rejected => |rejected| {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            var text: TerminalText = .{ .mode = .line };
            try writer.writeAll(if (rejected.kind == .decision) "! Decision rejected: " else "! Input rejected: ");
            try text.feed(&writer, rejected.code.slice());
            try text.finish(&writer);
            try writer.writeAll(rejection_suffix);
            self.notice = writer.buffered();
        },
        .absent, .failed => {},
    }
}

fn settleReader(self: *Self) !void {
    const end = self.joinReader();
    if (self.reading.phase == .recall and end != .complete) self.input.abandonStep();
    // A pending inspection supersedes a silent read it cancelled.
    const mode: departure.Mode = if (self.input.queuedCommand() != null) .inspection else .active;
    // A fatal failure leaves command output for exit to print.
    if (end.failure(mode)) |err| return err;
    if (end != .complete and self.inspection.command_running) {
        // Nothing to show: the command failed before writing output.
        self.inspection.command_running = false;
    }
    if (end == .complete and self.reading.phase == .history) {
        // The user may have left the transcript while this page loaded.
        const screen = self.terminal.screen;
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
            if (self.job.listing) |listed| self.transcript.plan.listed(listed, self.job.result.listing) else {
                self.transcript.older = self.job.result.history_cursor;
                self.transcript.beginning = self.transcript.older == null;
            }
            try self.showOlderLabels();
        }
    } else if (end == .complete and self.reading.phase == .message) {
        const screen = self.terminal.screen;
        const request = self.expansion.reading.?;
        self.expansion.reading = null;
        // Only over the unchanged view it was asked from, before any send,
        // dismissal or newer Ctrl-O.
        if (request.generation == self.expansion.generation and request.sent == self.admission.sent and screen.view == request.view and
            (request.view == .live or request.transcript == self.transcript.id))
            try screen.showMessage(self.init.io, self.files.inspection);
    } else if (end == .complete and self.reading.phase == .recall) {
        try self.showRecalled();
    } else if (end == .complete and (self.reading.phase == .activity or self.reading.phase == .permission)) {
        try self.showStaged();
    } else if (end == .complete and self.reading.phase == .inspection and self.inspection.kind == .copy) {
        try self.showCopy();
        self.inspection.command_running = false;
    } else if (end == .complete and (self.reading.phase == .details or self.reading.phase == .inspection)) {
        if (self.reading.phase != .details or self.admission.details_sent == self.admission.sent) try self.showInspection();
        self.inspection.command_running = false; // Shown; exit no longer prints it.
    }
    try self.applyReader(end);
}

/// What the queued row shows, if it shows (see `queued_line.shows`): the
/// newest waiting Message, by the line read from it, and how many wait.
fn queuedRow(self: *const Self) ?struct { newest: u64, waiting: queued_line.Waiting } {
    const queued = self.live.queued;
    if (!queued_line.shows(queued, self.live.drawn_waiting)) return null;
    const shown = if (self.live.queued_line) |*shown| shown else return null;
    if (shown.admission != queued.newest_admission) return null;
    return .{ .newest = queued.newest_admission, .waiting = .{ .line = shown.line.slice(), .count = queued.count } };
}

/// Appends a joined read's staged live output; none of it showed before.
/// Its boundaries and echoes take the live offsets where writing reaches
/// them: live output keeps text, not the styling the scratch file also
/// counts, and escapes clusters it cannot show, so each is the settled end
/// once writing reaches it. A page's own start precedes its separator.
fn showStaged(self: *Self) !void {
    const result = &self.job.result;
    self.live.messages = result.messages;
    if (result.lowest) |lowest| self.live.lowest = if (self.live.lowest) |known| @min(known, lowest) else lowest;
    var staged: Staged = .{ .frontend = self, .length = result.output_length, .start = try self.terminal.screen.liveEnd() };
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
            if (self.written == 0 and !frontend.reading.opening and !frontend.live.compact_tools and self.buffer[0] != '\n') try frontend.terminal.permanent("\n");
            try frontend.terminal.permanent(self.buffer[0..count]);
            self.written += count;
        }
        return if (output == 0) self.start else try frontend.terminal.screen.liveEnd();
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
    try sink.permanent("\n");
    try sink.permanent(View.Style.failure.code(self.colour));
    try sink.permanent(out.buffered());
    try sink.permanent(View.Style.normal.code(self.colour));
    try sink.permanent("\n");
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

        fn permanent(self: *@This(), bytes: []const u8) !void {
            self.calls += 1;
            if (self.fail_at == self.calls) return error.WriteFailed;
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    for ([_]ReadPhase{ .history, .details }) |phase| {
        for (1..6) |fail_at| {
            var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .reading = .{ .phase = phase } };
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
            self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
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
            self.notice = switch (self.reading.phase) {
                .details => "! Details unavailable; draft retained.",
                .message => "! Message unavailable; Ctrl-O to retry. Draft retained.",
                .recall => "! Sent message unavailable; draft retained.",
                .inspection => if (self.inspection.kind == .copy) self.copyFailure(end.failed.err) else "! Inspection unavailable; draft retained.",
                else => "! Earlier messages unavailable; scroll up to retry. Draft retained.",
            };
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    if (self.reading.output_started)
        self.live.compact_tools = if (self.reading.phase == .activity or self.reading.phase == .permission) self.job.result.compact_tools else false;
    if (self.reading.phase == .history or self.reading.phase == .message) {
        self.notice = null; // Clears "Loading earlier messages…" or "Opening message…".
    } else if (self.reading.phase == .recall) {
        // showRecalled selected the notice.
    } else if (self.reading.phase == .details or self.reading.phase == .inspection) {
        // showInspection selected the notice.
    } else {
        // History, footer, status, Sent and /status change together, in one frame.
        const result = &self.job.result;
        self.admission.delivered = @max(self.admission.delivered, result.delivered);
        self.live.work = result.work.work;
        // A taken Message leaves the queued row in the frame that shows it.
        self.live.queued = result.queued;
        if (result.queued_line) |shown| self.live.queued_line = shown;
        self.live.drawn_waiting = self.job.drawn_waiting;
        if (self.admission.echo) |admission| if (admission <= self.admission.delivered) {
            self.admission.echo = null;
        };
        if (result.status) try self.applyStatus();
        if (result.line) |*line| {
            self.line = line.*;
            self.shown.width = null;
        }
        if (result.hint) |*hint| {
            self.hint = hint.*;
            self.shown.width = null;
        }
        self.live.view = result.live;
        self.live.cursor = result.cursor;
        self.reading.opening = false;
        if (self.reading.phase == .permission) {
            self.reading.prepared_action = result.action;
            self.reading.prepared_summary = result.summary;
            if (self.reading.prepared_action == null) self.reading.phase = .activity;
        }
    }
    // A /status asked for during this read is the next read's, at once.
    self.poll_at = if (self.inspection.status_requested) 0 else std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
    self.dirty = true;
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
            .terminal = undefined,
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
    const Case = struct { queued: protocol.Queued, state: protocol.WorkState, drawn_waiting: u64 = 0, line: ?u64 = 9, shown: bool };
    var line: queued_line.Line = .{ .len = 0 };
    try line.set("check the cache");
    for ([_]Case{
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .shown = true },
        .{ .queued = some, .state = .{ .approval = .{ .since = 1 } }, .shown = true },
        // A Message held back and then left pending, which live output
        // shows only once taken: the row shows it meanwhile.
        .{ .queued = some, .state = .{ .pending = .{ .since = 1 } }, .shown = true },
        .{ .queued = some, .state = .{ .idle = .{ .since = 1 } }, .shown = true },
        // Nothing waits, or the newest showed while it waited.
        .{ .queued = .{}, .state = .{ .working = .{ .since = 1 } }, .shown = false },
        .{ .queued = some, .state = .{ .working = .{ .since = 1 } }, .drawn_waiting = 9, .shown = false },
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
            .terminal = undefined,
            .colour = false,
            .live = .{ .queued = case.queued, .work = .{ .state = case.state }, .drawn_waiting = case.drawn_waiting, .queued_line = if (case.line) |admission| .{ .admission = admission, .line = line } else null },
        };
        const row = self.queuedRow() orelse {
            try std.testing.expect(!case.shown);
            continue;
        };
        try std.testing.expect(case.shown);
        try std.testing.expectEqual(@as(u64, 9), row.newest);
        try std.testing.expectEqual(@as(u64, 2), row.waiting.count);
        try std.testing.expectEqualStrings("check the cache", row.waiting.line);
    }
}

fn showInspection(self: *Self) !void {
    self.inspection.status_page = false;
    const size = (try self.files.inspection.stat(self.init.io)).size;
    if (size == 0) {
        self.notice = "Command finished with no output.";
        return;
    }
    // A short command result is a notice, not a page. Inside the Session the
    // speaker is known: CLI "Rui: " text loses its prefix and "rui: "
    // diagnostics become failure notices.
    if (self.reading.phase == .inspection and self.inspection.kind == .command and size <= short_result_bytes) {
        var bytes: [short_result_bytes]u8 = undefined;
        const text = std.mem.trimEnd(u8, bytes[0..try self.files.inspection.readPositionalAll(self.init.io, bytes[0..@intCast(size)], 0)], "\n");
        if (std.mem.count(u8, text, "\n") < 2) {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (writer.buffered().len != 0) try writer.writeAll("\n");
                if (std.mem.startsWith(u8, line, "Rui: ")) try writer.writeAll(line[5..]) else if (std.mem.startsWith(u8, line, "rui: ")) try writer.print("! {s}", .{line[5..]}) else try writer.writeAll(line);
            }
            self.notice = writer.buffered();
            return;
        }
    }
    try self.terminal.screen.showFile(self.init.io, self.files.inspection, false);
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
        .too_large => "Too large for the clipboard · /copy file",
        // Rui cannot see whether the clipboard took it.
        .clipboard => |range| sent: {
            try self.terminal.clipboard(self.init.io, self.files.scratch, range.start, range.length);
            break :sent if (self.tmux) "Sent to clipboard · tmux needs set-clipboard on" else "Sent to clipboard";
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
fn copyFailure(self: *const Self, err: anyerror) []const u8 {
    if (self.inspection.kind.copy == .file) switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return "! This directory is not writable; draft retained.",
        else => {},
    };
    return "! Copy unavailable; draft retained.";
}

/// A settled scan's /status: the page asked for, or the shown page updated in
/// place. An update keeps the reader's place, notice and consent.
fn applyStatus(self: *Self) !void {
    const screen = self.terminal.screen;
    if (self.job.open_status and self.inspection.status_requested) {
        self.inspection.status_requested = false;
        try screen.showFile(self.init.io, self.files.status, false);
        self.notice = null;
    } else if (self.inspection.status_page and screen.view == .inspection) {
        try screen.refreshFile(self.init.io, self.files.status);
    } else return;
    self.inspection.status_page = true;
    self.inspection.status_digest = self.job.result.status_digest;
}

test "typing beside a ready Action moves to the draft, which decides nothing and keeps its text when a page opens or the Action leaves" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const page = try directory.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    // Longer than a notice, so it opens as a page and hides the Action.
    const rows: [512]u8 = @splat('\n');
    try page.writePositionalAll(std.testing.io, &rows, 0);
    const Change = enum { none, decided_elsewhere, command_page, status_page };
    for (std.enums.values(Change)) |change| for ([_][2][]const u8{ .{ "/", "/status" }, .{ "a", "a" } }) |line| {
        errdefer std.debug.print("change={s} line={s}\n", .{ @tagName(change), line[1] });
        var terminal: Terminal = .{ .original = undefined, .flags = undefined, .output = -1, .screen = screen };
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = .{ .scratch = undefined, .action = undefined, .inspection = page, .status = page }, .command = undefined, .terminal = &terminal, .colour = false, .reading = .{ .opening = false } };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
        try screen.latest();
        screen.action_view = .{ .io = std.testing.io, .file = page };
        self.live.work.first_action = 7;
        screen.consent = .{ .action = 7, .presentation = .complete, .row = .selector };
        screen.view = .action;
        screen.preview_complete = true;
        screen.action_seen = .end;
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, screen.selected);
        // A delivered frame that showed the choice, then offered.
        screen.frames +%= 1;
        screen.ticket = .{ .frame = screen.frames, .scope = screen.scope, .action = 7, .shown = .allow_once, .inputs = screen.inputs, .first = .{}, .next = .{}, .delivered = true };
        try std.testing.expect(screen.promptCompleted(.empty, false, false));
        try std.testing.expect(screen.offered() != null);
        // The first key typed is the draft's, and the choice is no longer fresh.
        try sendKeys(&self, line[0]);
        try std.testing.expectEqualStrings(line[0], self.input.composition().bytes);
        try std.testing.expect(screen.offered() == null);
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .paused }, screen.selected);
        switch (change) {
            .none => {},
            .decided_elsewhere => {
                self.live.work.first_action = null;
                self.withdrawDecided();
                try std.testing.expect(screen.consent == null);
            },
            .command_page => {
                self.reading.phase = .inspection;
                self.inspection.kind = .command;
                try self.showInspection();
            },
            .status_page => {
                self.job.open_status = true;
                self.inspection.status_requested = true;
                try self.applyStatus();
            },
        }
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Row.draft, screen.selected.row);
        try sendKeys(&self, line[1][line[0].len..]);
        try std.testing.expectEqualStrings(line[1], self.input.composition().bytes);
        if (change == .decided_elsewhere) continue;
        try sendKeys(&self, "\r");
        // Nothing was decided, and the Action holds a Message back.
        try std.testing.expectEqual(@as(u64, 7), screen.consent.?.action);
        try std.testing.expect(self.submission.view() == null);
        // A slash command runs as typed; other text stays the draft.
        if (line[0][0] == '/') {
            try std.testing.expectEqualStrings("/status", self.input.queuedCommand().?);
            try std.testing.expectEqualStrings("", self.input.composition().bytes);
        } else {
            try std.testing.expect(self.input.queuedCommand() == null);
            try std.testing.expectEqualStrings("a", self.input.composition().bytes);
            try std.testing.expectEqualStrings(if (change == .none) "! Action needs a decision; Esc returns to the choice. Draft retained." else "! Action needs a decision; Esc returns to it. Draft retained.", self.notice.?);
        }
        // Esc returns to the choice, which needs fresh input again.
        try sendKeys(&self, "\x07");
        try std.testing.expect(screen.actionVisible() and screen.consent.?.row == .selector);
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Row.selector, screen.selected.row);
        try std.testing.expect(screen.offered() == null);
    };
}

test "a transcript begun before grown live output is drawn shows the gap, not a lost join" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var terminal: Terminal = .{ .original = undefined, .flags = undefined, .screen = screen };
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = &terminal, .colour = false, .reading = .{ .opening = false } };
    try screen.append("GROWS-FIRST\n");
    self.live.marks.record(.{ .offset = 12, .cursor = .{ .end = 3 }, .admitted = 4 });
    // Unescaped, the rows after the mark fit; escaped, they evict it.
    for (0..45000) |_| try screen.append("\u{200b}");
    try screen.append("\nGROWS-END\n");
    try self.beginTranscript();
    try std.testing.expect(std.mem.indexOf(u8, screen.browsing.text(), "Earlier rows left this view.") != null);
    try std.testing.expectEqual(@as(?u64, 3), if (self.transcript.older) |cursor| cursor.end else null);
}

/// A frontend whose terminal writes to a full nonblocking pipe, so every frame
/// is held and pumps the real dispatch until the queued input is consumed.
const HeldFrontend = struct {
    self: Self,
    screen: *Screen,
    environ: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    directory: [std.Io.Dir.max_path_bytes]u8 = undefined,
    pipes: [2][2]std.posix.fd_t,
    pumps: usize = 0,
    terminal: Terminal = undefined,
    interrupted: client.Cancellation = .{},

    fn create() !*HeldFrontend {
        const held = try std.testing.allocator.create(HeldFrontend);
        errdefer std.testing.allocator.destroy(held);
        var pipes: [2][2]std.posix.fd_t = undefined;
        for (&pipes) |*pipe| if (std.c.pipe(pipe) != 0) return error.TestUnexpectedResult;
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        for ([_]std.posix.fd_t{ pipes[0][0], pipes[1][0], pipes[1][1] }) |fd|
            _ = std.c.fcntl(fd, std.c.F.SETFL, std.c.fcntl(fd, std.c.F.GETFL) | nonblock);
        const screen = try std.testing.allocator.create(Screen);
        held.* = .{ .self = undefined, .screen = screen, .environ = try std.testing.environ.createMap(std.testing.allocator), .tmp = std.testing.tmpDir(.{}), .pipes = pipes };
        try screen.init(std.testing.io, &held.environ, false);
        const directory = try held.tmp.dir.realPath(std.testing.io, &held.directory);
        held.self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = held.directory[0..directory], .files = undefined, .command = undefined, .terminal = &held.terminal, .interrupted = &held.interrupted, .colour = false, .reading = .{ .opening = false } };
        held.self.init.io = std.testing.io;
        held.self.live.work = .{};
        held.self.input.init();
        held.self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = held.self.directory, .input = &held.self.input };
        held.terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = screen, .input = pipes[0][0], .output = pipes[1][1], .pump = .{ .context = held, .step = pumpHeld } };
        return held;
    }

    fn destroy(held: *HeldFrontend) void {
        held.self.submission.cancel();
        _ = held.self.submission.join();
        held.self.submission.close();
        for (held.pipes) |pipe| for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        held.screen.deinit();
        std.testing.allocator.destroy(held.screen);
        held.tmp.cleanup();
        held.environ.deinit();
        std.testing.allocator.destroy(held);
    }

    /// Queues terminal input and fills the output pipe so the next frame, a
    /// whole-screen refresh, waits.
    fn hold(held: *HeldFrontend, input: []const u8) !void {
        held.screen.vx.queueRefresh();
        held.self.dirty = true;
        if (std.c.write(held.pipes[0][1], input.ptr, input.len) != @as(isize, @intCast(input.len))) return error.TestUnexpectedResult;
        var block: [4096]u8 = @splat('x');
        while (std.c.write(held.pipes[1][1], &block, block.len) > 0) {}
    }

    /// Output credit returns only after every queued input byte was serviced
    /// through the frontend's own pump.
    fn pumpHeld(raw: *anyopaque) !void {
        const held: *HeldFrontend = @ptrCast(@alignCast(raw));
        held.pumps += 1;
        try pump(&held.self);
        var fds = [_]std.posix.pollfd{.{ .fd = held.pipes[0][0], .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 0) != 0 or held.self.input.pending() != .none) return;
        var sink: [65536]u8 = undefined;
        while (std.c.read(held.pipes[1][0], &sink, sink.len) > 0) {}
    }

    /// Delivers frames until the draw loop settles, without held output.
    fn settle(held: *HeldFrontend) !void {
        for (0..8) |_| {
            if (!held.self.dirty and !held.screen.stale()) return;
            _ = try held.self.draw();
        }
        return error.TestUnexpectedResult;
    }

    fn adopt(held: *HeldFrontend, rows: usize) !std.Io.File {
        const file = try held.tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
        var line: [16]u8 = undefined;
        for (0..rows) |row| try file.writePositionalAll(std.testing.io, try std.fmt.bufPrint(&line, "row {d:0>3}\n", .{row}), row * 8);
        held.self.files.action = file;
        try held.screen.adopt(std.testing.io, file, 0xa, held.self.input.composition().bytes.len == 0);
        held.self.live.work.first_action = 0xa;
        return file;
    }
};

/// Each byte through the frontend's one stream, as `step` delivers it.
fn sendKeys(frontend: *Self, bytes: []const u8) !void {
    for (bytes) |byte| {
        var decoded = frontend.input.stream.feed(byte, 0);
        while (decoded != .none) : (decoded = frontend.input.stream.next()) try frontend.inputEvent(decoded);
    }
}

/// A page over the Action: approval pauses and the draft is shown, and no
/// earlier frame's offer stands.
fn pauseApproval(held: *HeldFrontend) !void {
    try held.settle();
    const page = try held.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    try page.writePositionalAll(std.testing.io, "Status\n", 0);
    try held.screen.showFile(std.testing.io, page, false);
    held.self.dirty = true;
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Approval.paused, held.screen.selected.approval);
    try std.testing.expectEqual(ConsentPolicy.Row.draft, held.screen.selected.row);
    try std.testing.expect(held.screen.offered() == null);
}

/// Reads `bytes` through `step`, the loop's own input path, letting a lone
/// ESC expire.
fn stepKeys(held: *HeldFrontend, bytes: []const u8) !void {
    if (std.c.write(held.pipes[0][1], bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.TestUnexpectedResult;
    const Drained = struct {
        fn done(frontend: *Self) !bool {
            const service = try frontend.step(0);
            return service == .empty or service == .decoder_expired;
        }
    };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), &held.self, Drained.done);
}

test "Ctrl-R beside an offered Action spends the offer in every encoding, so the Enter after it decides nothing" {
    for ([_][]const u8{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" }) |ctrl_r| {
        errdefer std.debug.print("ctrl_r={s}\n", .{ctrl_r[1..]});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
        try sendKeys(&held.self, ctrl_r);
        try std.testing.expectEqualStrings("! Action needs a decision; nothing to retry.", held.self.notice.?);
        try sendKeys(&held.self, "\r");
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
        try std.testing.expectEqualStrings("! Not ready; nothing authorized.", held.self.notice.?);
    }
}

test "arrows move the choice only once input is fresh, and Enter decides the option shown" {
    for ([_]ConsentPolicy.Choice{ .allow_once, .deny }) |choice| {
        errdefer std.debug.print("choice={s}\n", .{@tagName(choice)});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
        // Allow once is the default; Right then Left returns to it. Each
        // move is shown before the next key counts.
        try sendKeys(&held.self, "\x1b[C");
        try held.settle();
        try std.testing.expectEqual(ConsentPolicy.Choice.deny, held.screen.consent.?.highlight);
        try sendKeys(&held.self, "\x1b[D");
        try held.settle();
        try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
        if (choice == .deny) {
            try sendKeys(&held.self, "\x1b[C");
            try held.settle();
        }
        try std.testing.expect(held.screen.offered() != null);
        try sendKeys(&held.self, "\r");
        try std.testing.expect(held.screen.consent == null);
        try std.testing.expect(!held.screen.actionVisible());
        const decision = held.self.submission.intent.?.decision;
        try std.testing.expectEqual(@as(u64, 0xa), decision.action);
        try std.testing.expectEqual(@as(protocol.PermissionDecision, if (choice == .deny) .deny else .allow_once), decision.decision);
    }
}

test "an Enter before the offer decides nothing, says so and spends the frame, so only a new frame offers again" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    // The frame that reads the whole Action, then the choice's first frame.
    try held.self.drawFrame();
    try held.self.drawFrame();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, held.screen.selected);
    try std.testing.expect(held.screen.awaitsOffer());
    // Two Enters in one burst: neither decides.
    try sendKeys(&held.self, "\r\r");
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqualStrings("! Not ready; nothing authorized.", held.self.notice.?);
    try std.testing.expect(!held.screen.awaitsOffer());
    // Only a new prompt frame and empty input make the choice fresh again.
    try std.testing.expect(!held.screen.promptCompleted(.empty, false, false));
    held.self.dirty = true;
    try held.settle();
    try std.testing.expect(held.screen.offered() != null);
}

test "an arrow before input is fresh moves nothing, says so and spends the prompt" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.self.drawFrame();
    try held.self.drawFrame();
    try sendKeys(&held.self, "\x1b[C");
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
    try std.testing.expectEqualStrings("! Not ready; nothing authorized.", held.self.notice.?);
    try std.testing.expect(!held.screen.awaitsOffer());
    held.self.dirty = true;
    try held.settle();
    try sendKeys(&held.self, "\x1b[C");
    try std.testing.expectEqual(ConsentPolicy.Choice.deny, held.screen.consent.?.highlight);
}

test "a line typed beside one Action keeps the input row when the next Action arrives, so its Enter decides nothing" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const first = try held.adopt(3);
    defer first.close(std.testing.io);
    try held.settle();
    try sendKeys(&held.self, "\x1b[Dx");
    try std.testing.expectEqualStrings("x", held.self.input.composition().bytes);
    const second = try nextAction(held);
    defer second.close(std.testing.io);
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .paused }, held.screen.selected);
    try sendKeys(&held.self, "\r");
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xb), held.screen.consent.?.action);
    try std.testing.expectEqualStrings("x", held.self.input.composition().bytes);
    try std.testing.expectEqualStrings("! Action needs a decision; Esc returns to the choice. Draft retained.", held.self.notice.?);
    // Esc ends the line and shows the second Action's choice at Allow once.
    try sendKeys(&held.self, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
    try std.testing.expect(held.screen.offered() != null);
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
}

test "a Message being written when an Action arrives keeps the input row, so its Enter decides nothing" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try sendKeys(&held.self, "run the tests");
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .paused }, held.screen.selected);
    // The Enter meant to send the line.
    try sendKeys(&held.self, "\r");
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqualStrings("run the tests", held.self.input.composition().bytes);
    try std.testing.expectEqualStrings("! Action needs a decision; Esc returns to the choice. Draft retained.", held.self.notice.?);
    // Esc shows the choice at Allow once, and the draft stays.
    try sendKeys(&held.self, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, held.screen.selected);
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
    try std.testing.expectEqualStrings("run the tests", held.self.input.composition().bytes);
}

test "a slash command typed beside one Action empties the draft, so the next Action arrives at its choice" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const first = try held.adopt(3);
    defer first.close(std.testing.io);
    try held.settle();
    try sendKeys(&held.self, "/wait\r");
    try std.testing.expectEqualStrings("Work continues while you compose.", held.self.notice.?);
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .paused }, held.screen.select(false));
    const second = try nextAction(held);
    defer second.close(std.testing.io);
    try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, held.screen.selected);
    try sendKeys(&held.self, "\r");
    const decision = held.self.submission.intent.?.decision;
    try std.testing.expectEqual(@as(u64, 0xb), decision.action);
    try std.testing.expectEqual(protocol.PermissionDecision.allow_once, decision.decision);
}

/// Another client decides Action 0xa; Action 0xb arrives and is drawn.
fn nextAction(held: *HeldFrontend) !std.Io.File {
    held.self.live.work.first_action = null;
    held.self.withdrawDecided();
    try std.testing.expect(held.screen.consent == null);
    const second = try held.tmp.dir.createFile(std.testing.io, "second", .{ .read = true });
    errdefer second.close(std.testing.io);
    try second.writePositionalAll(std.testing.io, "row 000\n", 0);
    try held.screen.adopt(std.testing.io, second, 0xb, held.self.input.composition().bytes.len == 0);
    held.self.live.work.first_action = 0xb;
    held.self.dirty = true;
    try held.settle();
    return second;
}

test "Ctrl-R while approval is paused keeps the draft, recovers nothing and says the Action waits" {
    for ([_][]const u8{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" }) |ctrl_r| {
        errdefer std.debug.print("ctrl_r={s}\n", .{ctrl_r[1..]});
        const held = try HeldFrontend.create();
        defer held.destroy();
        try sendKeys(&held.self, "kept");
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try pauseApproval(held);
        try stepKeys(held, ctrl_r);
        try std.testing.expectEqualStrings("kept", held.self.input.composition().bytes);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqualStrings("! Action needs a decision; Esc returns to it. Draft retained.", held.self.notice.?);
        try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
        try std.testing.expect(held.screen.offered() == null);
        // The draft took no rejection: it still edits.
        try sendKeys(&held.self, "!");
        try std.testing.expectEqualStrings("kept!", held.self.input.composition().bytes);
    }
}

test "an Esc that expires does what an Esc reported whole does, at the Action, from a paused draft and from the settled view" {
    const Place = enum { choice, paused, settled };
    for (std.enums.values(Place)) |place| for ([_][]const u8{ "\x1b", "\x1b[27u" }) |escape| {
        errdefer std.debug.print("place={s} escape={s}\n", .{ @tagName(place), escape[1..] });
        const held = try HeldFrontend.create();
        defer held.destroy();
        switch (place) {
            .settled => try held.settle(),
            .choice, .paused => {
                if (place == .paused) try sendKeys(&held.self, "kept");
                _ = try held.adopt(3);
                if (place == .paused) try pauseApproval(held) else {
                    try held.settle();
                    try sendKeys(&held.self, "\x1b[C");
                }
            },
        }
        defer if (place != .settled) held.self.files.action.close(std.testing.io);
        try stepKeys(held, escape);
        switch (place) {
            .settled => {
                try std.testing.expectEqual(@as(?Outcome, .returned), held.self.leaving);
                try std.testing.expect(held.screen.consent == null);
            },
            .choice, .paused => {
                try std.testing.expect(held.self.leaving == null);
                try std.testing.expect(held.screen.offered() == null);
                try held.settle();
                try std.testing.expect(held.screen.actionVisible());
                try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
                // The shown option survives the return.
                try std.testing.expectEqual(@as(ConsentPolicy.Choice, if (place == .choice) .deny else .allow_once), held.screen.consent.?.highlight);
                try std.testing.expectEqualStrings(if (place == .paused) "kept" else "", held.self.input.composition().bytes);
                try std.testing.expect(held.self.submission.view() == null);
            },
        }
    };
}

test "every way out of the conversation ends consent, from the choice and from a paused draft" {
    for ([_]bool{ false, true }) |paused| for ([_][]const u8{ "\x03", "\x04", "\x1b[99;5u", "\x1b[100;5u" }) |key| {
        errdefer std.debug.print("paused={} key={s}\n", .{ paused, key });
        const held = try HeldFrontend.create();
        defer held.destroy();
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        if (paused) try pauseApproval(held) else try held.settle();
        try std.testing.expect(held.screen.consent != null);
        try stepKeys(held, key);
        try std.testing.expectEqual(@as(?Outcome, .detached), held.self.leaving);
        try std.testing.expect(held.screen.consent == null);
    };
}

test "a command queued during a held draft frame blocks the later Message Enter" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.dirty = true;
    try held.settle();
    try held.hold("/configure --permission-mode ask\rnext\xc3\xa9Z\x1b[D\r");
    self.dirty = true;
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    // The command waits for the reader; the Message Enter after it sealed nothing.
    try std.testing.expectEqualStrings("/configure --permission-mode ask", self.input.queuedCommand().?);
    try std.testing.expect(self.submission.view() == null);
    try std.testing.expect(self.input.submitted == null);
    try std.testing.expectEqualStrings("next\xc3\xa9Z", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 6), self.input.composition().cursor);
    try std.testing.expectEqualStrings("! Command still running. Draft retained.", self.notice.?);
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
        try sendKeys(self, text);
        try sendKeys(self, "\r");
        try std.testing.expectEqualStrings(text, self.input.composition().bytes);
        try std.testing.expectEqualStrings("! Command still running. Draft retained.", self.notice.?);
        try std.testing.expect(self.leaving == null);
        try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
        self.input.clear();
    }
}

test "Esc at the latest view returns to the overview only with nothing to lose or dismiss" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    // No draft outlives the frontend: Esc keeps it and says why.
    try sendKeys(self, "draft\x07");
    try std.testing.expect(self.leaving == null);
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", self.notice.?);
    try std.testing.expectEqualStrings("draft", self.input.composition().bytes);
    self.input.clear();
    // An unresolved submission keeps the conversation open and says what
    // resolves it.
    self.submission.intent = .{ .decision = .{ .action = 1, .decision = .deny } };
    defer self.submission.intent = null;
    for ([_]struct { Submission.State, []const u8 }{
        .{ .rejected, "Esc returns to the overview once /discard clears the rejected original." },
        .{ .unconfirmed, "Esc returns to the overview once Ctrl-R retries the original." },
    }) |case| {
        self.submission.state = case[0];
        self.notice = null;
        try sendKeys(self, "\x07");
        try std.testing.expect(self.leaving == null);
        try std.testing.expectEqualStrings(case[1], self.notice.?);
    }
    self.submission.intent = null;
    self.submission.state = .not_started;
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
    held.screen.withdrawAction();
    self.live.work.first_action = null;
    // Ctrl-G stands for Esc and Alt-Esc.
    try sendKeys(self, "\x07");
    try std.testing.expectEqual(@as(?Outcome, .returned), self.leaving);
}

test "End on an empty draft goes to the latest view and never leaves the conversation" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    for ([_][]const u8{ "\x1b[F", "\x1bOF" }) |end| {
        try sendKeys(self, end);
        try std.testing.expect(self.leaving == null);
    }
    // A rejected draft changes no key's meaning: Esc still returns.
    try sendKeys(self, "\x00\x1b[27u");
    try std.testing.expectEqual(@as(?Outcome, .returned), self.leaving);
}

test "a held ready choice decides nothing after a command queued in the same frame" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    // Read, prompted and fresh: the decision prompt's frame was delivered and
    // input then drained empty.
    try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
    try std.testing.expect(held.screen.offered() != null);
    // Typing moves to the draft, which runs the command and holds the rest.
    try held.hold("/status\ra\r");
    self.dirty = true;
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expect(self.submission.view() == null);
    try std.testing.expectEqualStrings("/status", self.input.queuedCommand().?);
}

test "a transition inside a held frame leaves its remaining input with the frame's editor" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    // Leave the Action for a page; approval pauses and the draft is shown.
    const page = try held.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    try page.writePositionalAll(std.testing.io, "Status\n", 0);
    try held.screen.showFile(std.testing.io, page, false);
    self.dirty = true;
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Approval.paused, held.screen.selected.approval);
    // Ctrl-G returns to the Action mid-frame; "a" and Enter still edit the draft.
    try held.hold("\x07a\r");
    self.dirty = true;
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expect(held.screen.actionVisible());
    try std.testing.expectEqualStrings("a", self.input.composition().bytes);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expect(self.submission.view() == null);
    // The replacement frame selects the choice, which needs fresh input.
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
    try std.testing.expectEqualStrings("a", self.input.composition().bytes);
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
        // /details begins its read, as driveActive does.
        self.admission.details_sent = self.admission.sent;
        self.reading.phase = .details;
        try self.reader.start(std.testing.io, self, Worker.read);
        if (send) {
            try self.beginMessage(self.input.submitText("sent while the page loaded"));
            self.submission.cancel();
            _ = self.submission.join();
            self.submission.close();
            self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = self.directory, .input = &self.input };
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
        var storage: [8]u8 = undefined;
        var editor: Editor = .{ .buffer = &storage };
        var stream: TerminalInput = .{};
        var recovers = false;
        for (case.bytes) |byte| {
            var decoded = stream.feed(byte, 0);
            while (decoded != .none) : (decoded = stream.next()) {
                const outcome = editor.apply(conversation_keys, decoded);
                recovers = recovers or (outcome == .action and outcome.action == .recover);
            }
        }
        try std.testing.expectEqual(case.recovery, recovers);
    }
}

test "choice readiness: keys pumped by a held redraw act on nothing, and the Enter after its delivery decides the option shown" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    try sendKeys(self, "\x1b[C");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Choice.deny, held.screen.consent.?.highlight);
    try std.testing.expect(held.screen.offered() != null);
    // Left and Enter arrive while a redraw is held: that frame is not yet
    // delivered, so neither moves nor decides anything.
    try held.hold("\x1b[D\r");
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expect(self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqual(ConsentPolicy.Choice.deny, held.screen.consent.?.highlight);
    try std.testing.expectEqualStrings("! Not ready; nothing authorized.", self.notice.?);
    // A delivered frame still shows Deny; then Enter decides it.
    try held.settle();
    try std.testing.expect(held.screen.offered() != null);
    try sendKeys(self, "\r");
    try std.testing.expectEqual(protocol.PermissionDecision.deny, self.submission.intent.?.decision.decision);
}

test "choice readiness: a slash command typed beside the Action keeps the draft, so a second Enter decides nothing" {
    for ([_][]const u8{ "/wait", "/login", "/nonsense", "/status" }) |command| {
        errdefer std.debug.print("command={s}\n", .{command});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
        try sendKeys(self, command);
        try sendKeys(self, "\r");
        // As the loop runs a queued command: the latest view while it runs.
        if (self.input.takeCommand() != null) try held.screen.latest();
        self.dirty = true;
        try held.settle();
        try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .paused }, held.screen.selected);
        try sendKeys(self, "\r");
        try std.testing.expect(self.submission.view() == null);
        try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
        // Esc returns to the choice, which a later frame makes ready.
        try sendKeys(self, "\x07");
        try held.settle();
        try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
        try std.testing.expect(held.screen.offered() != null);
    }
}

test "choice readiness: typing while a command holds the choice revokes no frame per byte" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    self.inspection.command_running = true;
    self.dirty = true;
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Approval.held, held.screen.selected.approval);
    try sendKeys(self, "pasted text");
    try std.testing.expect(!held.screen.stale());
    try std.testing.expectEqualStrings("! Command still running. Input ignored.", self.notice.?);
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    try std.testing.expect(held.screen.offered() == null);
}

test "choice readiness: a key with no use at the choice spends it, so the Enter after it decides nothing" {
    // Tab, Backspace, Delete, Home, Ctrl-X and Up.
    for ([_][]const u8{ "\t", "\x7f", "\x1b[3~", "\x1b[H", "\x18", "\x1b[A" }) |key| {
        errdefer std.debug.print("key={s}\n", .{key});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const self = &held.self;
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
        try sendKeys(self, key);
        try std.testing.expect(held.screen.offered() == null);
        try sendKeys(self, "\r");
        try std.testing.expect(self.submission.view() == null);
        try std.testing.expectEqualStrings("! Not ready; nothing authorized.", self.notice.?);
        // A new frame and empty input make the choice ready again.
        self.dirty = true;
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
    }
}
