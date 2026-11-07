//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const OutputBlocks = @import("output_blocks.zig");
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
const overview_view = @import("overview_view.zig");
const test_poll = @import("test_poll");
const View = @import("session_view.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const UpgradePanel = @import("UpgradePanel.zig");
const Self = @This();

const reads = @import("session_reads.zig");
const session_line = @import("session_line.zig");
const slash_commands_shared = @import("slash_commands.zig");
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
terminal: *Terminal,
/// Stops when the caller is signalled; a running command stops with it.
interrupted: *client.Cancellation = undefined,
/// The overview that lent the terminal.
/// `run` always supplies the overview; a frame drawn without one says nothing.
lender: Lender = quiet_overview,
colour: bool,
/// Inside tmux, Shift-Enter reaches Rui as Enter; composing says so.
tmux: bool = false,
input: Input = undefined,
submission: Submission = undefined,
/// What the latest /requests page offers to act on, which its list shows
/// while the page does.
saved_requests: reads.SavedRequests = .{},
/// The /recover row's line for the original, written each time the rows
/// are listed.
recover_line: [slash_commands_shared.recover_line_bytes]u8 = undefined,
reader: Task = .{},
upgrade_requested: bool = false,
upgrade_blocked: bool = false,
upgrade_reobserving: bool = false,
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

const rejection_suffix = " · /discard clears it";
/// This process's environment cannot change, so the original goes from a
/// shell with a smaller one.
const too_large_advice = " Unset or shorten them in another shell, then run rui request recover there.";
/// The longest built notice: a rejection with its code escaped (four bytes
/// per byte at most), a refused environment, or a short result with a
/// failure mark on each line.
const notice_capacity = @max(
    "! Decision rejected: ".len + 4 * protocol.max_code_bytes + rejection_suffix.len,
    "! ".len + client.Environment.too_large_bytes + too_large_advice.len,
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
            self.* = .{ .init = undefined, .home = home, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
            const job = self.freeze(phase);
            self.home = "/changed-after-freeze";
            try std.testing.expectEqualStrings(home, job.home);
            try std.testing.expectEqual(home.ptr, job.home.ptr);
        }
    }
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
pub const UpgradeHandoff = enum { quiesce, ready, incompatible };

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
    /// Hands the overview each read of the Session's work, which it records
    /// against what its listing read of the Session and notifies of as
    /// news, named `name`, unless it is the read the conversation opens on.
    /// Its failure is the overview's and ends the conversation.
    observed: *const fn (context: *anyopaque, work: protocol.session_work.Work, name: []const u8, opening: bool) anyerror!void,

    upgrade: ?*const fn (context: *anyopaque, handoff: UpgradeHandoff) anyerror!bool = null,

    pub const Said = struct {
        /// The prompt or overview notice; null for neither.
        text: ?[]const u8 = null,
        /// The confirmation shown; Esc or Ctrl-G only cancels.
        asking: ?overview_view.Prompt.Action = null,
        /// Ctrl-X would ask to stop the work.
        stoppable: bool = false,
    };
};

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
pub fn run(self: *Self, init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, requests: Requests, status: Status, terminal: *Terminal, interrupted: *client.Cancellation, lender: Lender) !Outcome {
    self.* = .{ .init = init, .home = init.environ_map.get("HOME") orelse "", .store = store, .session = session, .directory = directory, .files = files, .command = command, .requests = requests, .status = status, .terminal = terminal, .interrupted = interrupted, .lender = lender, .colour = terminal.screen.colour, .tmux = if (terminal.notices) |notices| notices.tmux else false };
    terminal.screen.home = self.home;
    self.startInput();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input, .environment = .{ .map = init.environ_map } };
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

/// A Session's input starts empty, and no frame of it has drawn a list yet:
/// the screen's list was the previous Session's, at revisions this input
/// counts again.
fn startInput(self: *Self) void {
    self.input.init(&self.terminal.stream);
    self.input.complete(.{ .context = self, .add = tabCompletion });
    self.terminal.screen.commands = null;
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
    var admission = self.submission.join();
    self.followAdmission(admission) catch |err| {
        admission = .{ .failed = .{ .err = err } };
    };
    // One Enter asked for the reason and the denial: leaving after the
    // reason was accepted still sends the denial, and waits for it.
    if (self.submission.task.thread != null) admission = self.joinAdmission();
    return .{ .restored = restored, .reader = reader, .admission_error = admission.failure() };
}

test "run returns detached on Ctrl-D and leaves the lent terminal begun, with no notice written" {
    for ([_][]const u8{ "", "\x1b[", "\x1bO" }) |prefix| {
        var environ = try std.testing.environ.createMap(std.testing.allocator);
        defer environ.deinit();
        const screen = try std.testing.allocator.create(Screen);
        defer std.testing.allocator.destroy(screen);
        try Screen.Test.init(screen, std.testing.io, &environ, false);
        defer Screen.Test.deinit(screen);
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
            if (fd >= 0) _ = std.c.close(fd);
        };
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        _ = std.c.fcntl(output[0], std.c.F.SETFL, std.c.fcntl(output[0], std.c.F.GETFL) | nonblock);
        const keys: []const u8 = if (prefix.len == 0) "\x04" else "B\x04";
        try std.testing.expectEqual(@as(isize, @intCast(keys.len)), std.c.write(input[1], keys.ptr, keys.len));
        // A lost prefix would type B, so Ctrl-D would edit instead of detach.
        // EOF makes that failure deterministic rather than an input wait.
        _ = std.c.close(input[1]);
        input[1] = -1;
        var terminal: Terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = screen, .input = input[0], .output = output[1] };
        const now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (prefix) |byte| _ = terminal.stream.feed(byte, now);
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        init.gpa = std.testing.allocator;
        init.environ_map = &environ;
        var interrupted: client.Cancellation = .{};
        const self = try std.testing.allocator.create(Self);
        defer std.testing.allocator.destroy(self);
        const files: Files = .{ .scratch = page, .action = page, .inspection = page, .status = page, .actions = .{ page, page } };
        const outcome = try self.run(init, store, "k7m2qx", store, files, undefined, undefined, undefined, &terminal, &interrupted, quiet_overview);
        try std.testing.expectEqual(Outcome.detached, outcome);
        try std.testing.expectEqualStrings("", self.input.composition().bytes);
        try std.testing.expectEqual(TerminalInput.Pending.none, terminal.stream.pending());
        try std.testing.expect(self.input.stream == &terminal.stream);
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
}

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
        var stream: TerminalInput = .{};
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
        self.input.init(&stream);
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
        .@"inspect-action", .setup, .configure, .result, .rename, .effort, .skill, .@"reload-skills" => .{ .inspection = .command },
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
        self.notice = upgrade_recovery;
        return;
    }
    switch (parsed) {
        .upgrade => self.upgrade_requested = true,
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
    var stream: TerminalInput = .{};
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
    self.input.init(&stream);
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
    var stream: TerminalInput = .{};
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
    self.input.init(&stream);
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

test "frontend lists the efforts of the Session's model once it is read, the one in force marked" {
    var stream: TerminalInput = .{};
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
    self.input.init(&stream);
    for ("/effort ") |byte| _ = self.input.feed(byte);
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
    _ = self.input.feed('m');
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
        var stream: TerminalInput = .{};
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false };
        self.init.io = std.testing.io;
        self.input.init(&stream);
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
        var stream: TerminalInput = .{};
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .leaving = .returned };
        self.init.io = std.testing.io;
        self.input.init(&stream);
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
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
        var stream: TerminalInput = .{};
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .reading = .{ .phase = phase } };
        self.init.io = std.testing.io;
        self.input.init(&stream);
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = self.input.submitText("current original B") } };
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

const upgrade_recovery = "! Host requests paused after Upgrade; draft and original retained. /upgrade or use the selected Rui in a new terminal.";

fn upgradeHeld(self: *const Self) bool {
    return self.upgrade_requested or self.upgrade_blocked or self.upgrade_reobserving;
}

fn quiesceUpgrade(self: *Self) !bool {
    self.notice = "Upgrade: waiting for Client borrowers; draft and original retained.";
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
    if (self.reading.pending_diagnostic != null and self.reader.thread == null) try self.presentReadDiagnostic(self.terminal);
    try self.startQueuedCommand();
    const lender_ready = if (self.lender.upgrade) |handoff| try handoff(self.lender.context, .quiesce) else true;
    return lender_ready and self.reader.thread == null and self.submission.task.thread == null;
}

fn showUpgrade(self: *Self) !void {
    const outcome = try UpgradePanel.run(self.init, self.store, self.terminal, self.interrupted);
    self.upgrade_requested = false;
    self.applyUpgrade(outcome);
    if (self.lender.upgrade) |handoff| {
        _ = try handoff(self.lender.context, if (self.upgrade_blocked) .incompatible else .ready);
    }
}

fn applyUpgrade(self: *Self, outcome: UpgradePanel.Outcome) void {
    switch (outcome) {
        .unchanged => {},
        .compatible => {
            self.upgrade_blocked = false;
            self.poll_at = 0;
            self.upgrade_reobserving = true;
            self.reading.prepared_action = null;
        },
        .incompatible => {
            self.upgrade_blocked = true;
            self.upgrade_reobserving = false;
        },
    }
    self.notice = if (self.upgrade_blocked) upgrade_recovery else "Upgrade closed; draft and original retained. No work was resent.";
    self.dirty = true;
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
}

fn driveActive(self: *Self) !void {
    while (self.leaving == null) {
        if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
        if (!self.upgrade_requested and !self.upgrade_blocked) {
            if (try self.lender.service(self.lender.context)) self.dirty = true;
        }
        const size = self.terminal.geometry();
        if (size.row != self.terminal.size.row or size.col != self.terminal.size.col) self.dirty = true;
        if (self.upgrade_requested) {
            const ready = self.quiesceUpgrade() catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                self.upgrade_requested = false;
                self.upgrade_blocked = true;
                self.upgrade_reobserving = false;
                var writer = std.Io.Writer.fixed(&self.notice_buffer);
                try writer.print("! Upgrade could not settle Client work: {s}. Draft and original retained; /upgrade to retry.", .{@errorName(err)});
                self.notice = writer.buffered();
                self.dirty = true;
                if (self.lender.upgrade) |handoff| _ = try handoff(self.lender.context, .incompatible);
                continue;
            };
            if (ready) try self.showUpgrade();
            if (self.dirty or self.terminal.screen.stale()) _ = try self.draw();
            _ = try self.step(16);
            continue;
        }
        if (self.upgrade_blocked) {
            if (self.notice == null) self.notice = upgrade_recovery;
            if (self.dirty or self.terminal.screen.stale()) _ = try self.draw();
            _ = try self.step(16);
            continue;
        }
        if (self.upgrade_reobserving) {
            if (self.reader.thread != null and self.reader.completed()) {
                self.settleReader() catch |err| {
                    if (err == error.CanonicalStoreFailure) return err;
                    self.upgrade_blocked = true;
                    self.upgrade_reobserving = false;
                    var writer = std.Io.Writer.fixed(&self.notice_buffer);
                    try writer.print("! Reattach failed: {s}. Draft and original retained; /upgrade or reopen with selected Rui.", .{@errorName(err)});
                    self.notice = writer.buffered();
                    if (self.lender.upgrade) |handoff| _ = try handoff(self.lender.context, .incompatible);
                };
                self.withdrawDecided();
            }
            if (self.upgrade_reobserving and self.reader.thread == null) try self.launch(self.freeze(.activity), reads.scan);
            if (self.dirty or self.terminal.screen.stale()) _ = try self.draw();
            _ = try self.step(16);
            continue;
        }
        try self.admit();
        if (self.input.queuedCommand()) |text| if (parse(text).inspection == .status) {
            // /status is the next scan's: one capture for the page, the
            // history and the composer status.
            _ = self.input.takeCommand();
            try self.terminal.screen.latest();
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
        // A joined read may hide or withdraw the Action, so a sequence the
        // choice is decoding finishes there first and keeps its meaning.
        if (self.reader.thread != null and self.reader.completed() and !(self.terminal.screen.inputRow() == .selector and self.input.pending() != .none)) {
            try self.settleReader();
            self.withdrawDecided();
        }
        if (self.reading.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(self.terminal);
        }
        try self.startQueuedCommand();
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
                    if (screen.view == .transcript) screen.browsing.scroll.scroll.y = 0 else self.notice = "/history opens once the Action is decided.";
                    self.dirty = true;
                }
            }
            if (self.reader.thread == null) if (self.expansion.requested) |request| {
                self.expansion.requested = null;
                self.expansion.reading = request;
                const job = self.freeze(.message);
                job.target = .{ .message = request.target };
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
        // Another Session's notification goes out with the next frame.
        if (self.terminal.notificationWaiting()) self.dirty = true;
        if (self.dirty or self.terminal.screen.stale()) if (try self.draw()) break;
        if (self.expansion.pending) try self.expand();
        _ = try self.step(self.inputWait());
    }
}

/// Draws a frame, applies its receipt and, when the screen says that frame
/// awaits its offer, services input for the empty-input gate. Returns true
/// when that service detached the caller.
fn draw(self: *Self) !bool {
    const screen = self.terminal.screen;
    try self.drawFrame();
    // A benign return captured by the output pump belongs to the next owner
    // as soon as delivery finishes, before expansion or any freshness read.
    if (self.leaving != null) return true;
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
    const status = statusLines(&status_buffer, context.buffered(), base_status, self.line.archive_state);
    var queued_buffer: [Frame.status_capacity]u8 = undefined;
    const queued: ?Screen.Footer.Queued = if (self.queuedRow()) |row| .{
        .waiting = row.waiting,
        .status = statusLines(&queued_buffer, context.buffered(), submission_status orelse if (self.admission.echo) |echo| (if (echo <= row.newest) "" else "Sent") else "", self.line.archive_state),
    } else null;
    // The overview's stop prompt or notice, else the conversation's own.
    const said = self.lender.line(self.lender.context, self.live.work.state.asOf(now_ms));
    const notice = said.text orelse self.notice;
    var facts = self.line.facts(&self.hint, self.session);
    if (facts) |*shown| shown.stop = said.stoppable;
    self.dirty = false;
    // Reading completes only after delivery; the receipt stales the frame.
    _ = screen.presented(try self.terminal.redraw(view.bytes, view.cursor, .{ .command = self.commandActive(), .status = status, .notice = notice orelse "", .commands = self.nextCommands(self.terminal.screen.commands), .session = if (facts) |shown| .{ .facts = shown, .shown = &self.shown } else null, .live = live, .queued = queued }, &self.live.view));
}

/// The list above the draft as it is now, after `previous`: the commands
/// its command word starts, or the choices for the word typed after one.
/// Null when nothing matches.
fn nextCommands(self: *Self, previous: ?slash_commands_shared.Shown) ?slash_commands_shared.Shown {
    // The Session's model offers its efforts once a read names it.
    const context: slash_commands_shared.Context = if (self.line.read != null) .{ .model = self.line.model.slice(), .effort = self.line.effort } else .{};
    const draft = self.input.composition().bytes;
    if (draft.len != 0) return slash_commands_shared.Shown.next(previous, self.input.revision, slash_commands.suggest(draft, context));
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
    if (self.terminal.screen.view != .inspection or self.inspection.kind != .requests or self.inspection.status != null) return null;
    const lead = if (self.recoverable()) |key| slash_commands_shared.recoverEntry(&self.recover_line, key) else null;
    return self.saved_requests.list(lead);
}

/// The original a /recover row retries: a plain unconfirmed Message,
/// nothing in flight, and no Action waiting, at which Ctrl-R and /recover
/// retry nothing.
fn recoverable(self: *const Self) ?*const [36]u8 {
    if (self.terminal.screen.consent != null) return null;
    return self.submission.unconfirmedMessage();
}

/// Ctrl-R, or /recover with the original's key: retries the original,
/// except while an Action waits, which only its choice decides.
fn recover(self: *Self, key: ?[]const u8) !void {
    if (self.terminal.screen.consent != null) {
        self.notice = self.decisionNotice();
        return;
    }
    try self.submission.requestRecovery(key);
}

/// The draft's list, which Enter, Esc and the arrows act on when the latest
/// frame drew a list.
fn shownCommands(self: *Self) ?*slash_commands_shared.Shown {
    const stored = &self.terminal.screen.commands;
    return slash_commands_shared.Shown.drawnNow(stored, self.nextCommands(stored.*));
}

/// Tab: the rest of the highlighted entry's word in the draft's list,
/// shown, hidden or closed; null for a draft no list is for, which takes
/// the tab.
fn tabCompletion(context: *const anyopaque, draft: []const u8) ?[]const u8 {
    // The editor lends back the frontend `startInput` registered, whose
    // rows' lines this writes.
    const self: *Self = @ptrCast(@alignCast(@constCast(context)));
    if (draft.len == 0) {
        const rows = self.nextCommands(self.terminal.screen.commands) orelse return null;
        return rows.completion();
    }
    if (slash_commands.suggest(draft, .{}) == null) return null;
    const shown = self.nextCommands(self.terminal.screen.commands) orelse return "";
    return shown.completion();
}

// A notice fits the rows under the input as the status fits above it.
comptime {
    std.debug.assert(@typeInfo(@FieldType(Self, "notice_buffer")).array.len <= Frame.status_capacity);
}

/// The instructions always fit; a long context line is shortened, on a
/// UTF-8 boundary, rather than pushing them out of the status region.
fn statusLines(buffer: *[Frame.status_capacity]u8, context: []const u8, base: []const u8, archive_state: protocol.SessionArchiveState) []const u8 {
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
    var buffer: [Frame.status_capacity]u8 = undefined;
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
    var buffer: [Frame.status_capacity]u8 = undefined;
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
        var label: TerminalText = .{ .mode = .label };
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

/// The existing output owner distinguishes a nonblocking reentrant pump from
/// ordinary input service. No second mode flag or scheduler timing oracle.
fn inputWait(self: *const Self) i32 {
    return if (self.terminal.writing) 0 else 16;
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = try self.step(self.inputWait());
    // Returning to the overview is benign: finish this frozen frame first.
    // Detach/exit/signals retire the invocation and may abort promptly.
    if ((self.leaving != null and self.leaving != .returned) or self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
}

/// Sends a Message, alone or as the reason an Action is denied.
fn beginMessage(self: *Self, intent: Submission.Intent) !void {
    // Input can arrive with Enter before any redraw, including inside output
    // pumping. Sealed bytes render in the escaped transcript, not the composer.
    const size = self.terminal.geometry();
    Frame.validateGeometry(size.col, size.row) catch |err| {
        self.input.release(intent.ticket().?) catch unreachable;
        return err;
    };
    try self.submission.begin(intent);
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
    return self.upgradeHeld() or self.input.queuedCommand() != null or self.inspection.command_running;
}

/// What a key does in a conversation, beside the draft or an Action's choice.
const ConversationAction = enum {
    page_up,
    page_down,
    /// Up and Down: the shown list's highlight, the /status page's row,
    /// else a line of scrolling.
    previous,
    next,
    /// Shift-Up and Shift-Down: the shown list's highlight, else a line of
    /// scrolling, also on the /status page.
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
    /// Asks to stop the Session, and stops it at a second press.
    stop,
    archive,
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
    .ctrl_x = .stop,
    .alt_a = .archive,
    .up = .previous,
    .down = .next,
    .shift_up = .scroll_up,
    .shift_down = .scroll_down,
    .page_up = .page_up,
    .page_down = .page_down,
    .home = null,
    .end = .back,
    .ctrl_end = .latest,
});

fn perform(self: *Self, action: ConversationAction) !void {
    if (self.upgradeHeld() and (action == .recover or action == .expand)) {
        self.notice = upgrade_recovery;
        return;
    }
    const screen = self.terminal.screen;
    switch (action) {
        // A shown list takes the arrows, as the overview's model list does.
        .previous, .next => if (if (screen.inputRow() == .draft) self.shownCommands() else null) |shown| {
            shown.move(action == .next);
            self.dirty = true;
        } else if (screen.inputRow() != .draft or !try self.moveSelection(action == .next)) try self.scroll(action == .next, false),
        .scroll_up, .scroll_down => if (if (screen.inputRow() == .draft) self.shownCommands() else null) |shown| {
            shown.move(action == .scroll_down);
            self.dirty = true;
        } else try self.scroll(action == .scroll_down, false),
        .page_up, .page_down => try self.scroll(action == .page_down or action == .scroll_down, action == .page_up or action == .page_down),
        .older, .newer => if (self.input.press(action == .older) == .typed) {
            self.notice = "Ctrl-P recalls sent messages once the draft is empty.";
        },
        .latest, .back, .close => {
            // Esc closes only a list the person saw.
            if (action == .close and screen.inputRow() == .draft) if (self.shownCommands()) |shown| {
                shown.close();
                self.dirty = true;
                return;
            };
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
    const host_intent = switch (input) {
        .other => false,
        .stop, .archive, .unarchive, .confirm_archive => true,
    };
    if (host_intent and self.upgradeHeld()) {
        self.notice = upgrade_recovery;
        return;
    }
    try self.lender.step(self.lender.context, self.shownWork(), input);
}

fn overviewSays(self: *const Self) Lender.Said {
    return self.lender.line(self.lender.context, self.shownWork());
}

/// The work the conversation shows now.
fn shownWork(self: *const Self) protocol.session_work.Kind {
    const now_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
    return self.live.work.state.asOf(now_ms);
}

fn scroll(self: *Self, down: bool, page: bool) !void {
    const screen = self.terminal.screen;
    if (screen.view == .live) {
        if (down) return; // Live output already shows the latest rows.
        // All-fitting output with no canonical predecessor is unchanged by
        // Up: selecting a source is not itself backward movement.
        if (screen.live.scroll.scroll.y == 0) {
            const front = try screen.liveStart();
            const plan = reads.plan(&self.live.marks, &self.live.echoes, front, self.live.lowest);
            if (self.reading.opening or (plan.next() == null and plan.older == null and !plan.gap)) return;
        }
        try self.beginTranscript();
    }
    if (down and screen.view == .transcript) {
        const appended = try screen.catchUp();
        // Only the admitted prefix may have fit. Count the live blocks after
        // that exact normalized endpoint, not simply the newest N identities.
        const endpoint = switch (screen.tail) {
            .retained, .limited => |end| end,
            .gap => 0,
        };
        const after = if (endpoint >= screen.live.text.origin and endpoint <= screen.live.text.origin + screen.live.text.length)
            screen.live.text.collapsed(@intCast(endpoint - screen.live.text.origin), screen.live.text.length).count
        else
            0;
        var index = appended;
        while (index != 0) {
            index -= 1;
            self.transcript.blocks.append(self.live.blocks.fromEnd(after + index));
        }
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
    const stream = &self.terminal.stream;
    const pending = stream.pending();
    const read = (self.terminal.next(self.init.io, wait) catch |err| switch (err) {
        error.InputDeadline => {
            const expired = try stream.expire();
            if (expired != .none) {
                self.notice = null;
                try self.inputEvent(expired);
            }
            // Successful expiry releases decoder custody. Revisit redraw and
            // its drained-input readiness gate, just as after ordinary input.
            self.dirty = true;
            return .decoder_expired;
        },
        else => return err,
    }) orelse return if (pending == .none) .empty else .decoder_pending;
    self.dirty = true;
    // One stream decodes every byte; replies never reach an editor, and an
    // event left in a suffix is delivered in order before the next byte.
    // Input clears the notice; a reply, such as focus returning, keeps it.
    var decoded = stream.feed(read.byte, read.at);
    while (decoded != .none) : (decoded = stream.next()) switch (decoded) {
        .report => |report| switch (report) {
            .width => |method| self.terminal.widthReported(method),
            .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
            .focus => |focused| self.terminal.focused = focused,
            // The overview sends the records once a listing steps it.
            .program_status => _ = self.terminal.answered(.program_status),
            .device_attributes => _ = self.terminal.answered(.device_attributes),
        },
        else => {
            self.notice = null;
            try self.inputEvent(decoded);
        },
    };
    return .byte;
}

/// The entry of every input. It spends the offer first, whatever the key
/// does; only an arrow or Enter at the choice, or Enter in the draft beside
/// the Action, may use it. The input row the latest frame shows takes the
/// input.
fn inputEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    if (self.terminal.writing and self.leaving == .returned) {
        if (Editor.frozenAction(conversation_keys, decoded) == .detach) self.leaving = .detached;
        return;
    }
    const screen = self.terminal.screen;
    const offer = screen.spendOffer();
    const selected = Editor.select(conversation_keys, decoded);
    const asked = self.overviewSays().asking;
    if (asked == .archive and selected == .enter) {
        try self.converse(if (Editor.plainEnter(decoded)) .confirm_archive else .other);
        self.dirty = true;
        return;
    }
    if (asked != null and selected == .action and selected.action == .close) {
        try self.converse(.other);
        self.dirty = true;
        return;
    }
    const controls_prompt = !self.reading.opening and switch (selected) {
        .action => |action| action == .stop or action == .archive,
        else => false,
    };
    // Cancel the old context before ordinary input can create a new prompt.
    if (!controls_prompt) try self.converse(.other);
    if (screen.inputRow() == .selector) try self.choiceEvent(decoded, offer) else try self.draftEvent(decoded, offer);
    if (self.leaving != null) screen.interruptConsent();
}

/// One input at an Action's Allow once / Deny choice. Only arrows and Enter
/// act on it, and only with the offer this input spent.
fn choiceEvent(self: *Self, decoded: TerminalInput.Decoded, offer: ?Screen.Offer) !void {
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
            // No frame has shown this draft yet: the key offers nothing.
            try self.draftEvent(decoded, null);
        },
        .refused => self.notice = "! Key combination not recognized; nothing authorized.",
    }
}

/// An arrow or Enter at the choice, probed against current geometry,
/// command and the offer; one that cannot act says why.
fn choose(self: *Self, key: Screen.ChoiceKey, offer: ?Screen.Offer) !void {
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

/// Says what Enter in the draft does, so the frame showing it may offer the
/// denial.
const reason_not_ready = "! Not ready; nothing denied · " ++ Screen.deny_words;

/// Why Enter in the draft beside an Action sent nothing.
fn reasonNotice(self: *const Self, letter: bool) []const u8 {
    if (self.terminal.screen.liveApproval(self.commandActive()) != .reason) return self.decisionNotice();
    return if (letter) "! Use ←→ and Enter to choose; a message denies the call." else reason_not_ready;
}

/// One input in the draft, with the offer this input spent. Beside an Action
/// whose standing offer showed the draft as the reason, Enter sends it and
/// denies the Action.
fn draftEvent(self: *Self, decoded: TerminalInput.Decoded, offer: ?Screen.Offer) !void {
    const screen = self.terminal.screen;
    const submission = self.submission.view();
    // Only the first key after an offered frame carries an offer, so the
    // geometry probe runs at most once per frame.
    const reason = if (screen.consent == null or offer == null) null else screen.reasonOffered(offer, self.terminal.geometry(), self.commandActive());
    const letter = screen.consent != null and ConsentPolicy.choiceLetter(self.input.composition().bytes);
    // A Message waits for a pending command, which may change its configuration.
    // A live probe immediately before sealing, with no effect between them.
    const allowed = ConsentPolicy.messageAllowed(screen.consent, reason != null and !letter, .{
        .opening = self.reading.opening,
        .permission_preparing = self.reading.phase == .permission,
        .command = self.commandActive(),
        .original = if (submission) |value| (if (value.kind == .decision) .decision else .message) else .none,
    });
    if (Editor.select(conversation_keys, decoded) == .enter and self.startChange()) return;
    switch (self.input.applySelected(conversation_keys, decoded, allowed)) {
        .message => |ticket| if (reason) |denial| {
            // Consumption precedes fallible submission. The Message goes
            // first, so the Action holds it until the denial that follows.
            screen.decide(denial);
            screen.releaseAction();
            try self.beginMessage(.{ .message_then_deny = .{ .ticket = ticket, .action = denial.action } });
        } else try self.beginMessage(.{ .message = ticket }),
        .command => try self.commandLine(),
        .busy => self.notice = if (self.commandActive()) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.reading.phase == .permission) "! Action needs a decision. Draft retained." else if (screen.consent != null) self.reasonNotice(letter) else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |outcome| switch (outcome) {
            .action => |action| try self.perform(action),
            .refused => |why| self.notice = refusedNotice(why),
            // Enter on an empty draft takes a /requests row the frame drew.
            .submit => if (self.shownCommands() != null) {
                if (self.input.queuedCommand() != null) self.notice = "! Command still running." else try self.commandLine();
            },
            .none, .append, .redraw => {},
        },
    }
}

/// Enter on a command line, or in a shown list, which takes its highlighted
/// entry: it runs the command that entry completes, or adds the word
/// another follows. Only a list the latest frame drew for this draft: a
/// screen too short for one shows none, and Enter there runs the line as
/// typed.
fn commandLine(self: *Self) !void {
    if (self.shownCommands()) |shown| {
        const taken = shown.list.enter(shown.highlight);
        switch (self.input.append(taken.rest)) {
            .refused => |why| self.notice = refusedNotice(why),
            else => if (taken.runs) {
                defer if (!self.upgradeHeld()) self.input.clear();
                try self.slashCommand(self.input.composition().bytes);
            },
        }
    } else {
        defer if (!self.upgradeHeld()) self.input.clear();
        try self.slashCommand(self.input.composition().bytes);
    }
}

fn refusedNotice(why: keymap.Refusal) []const u8 {
    return switch (why) {
        .invalid, .edit_rejected => "! Input rejected; nothing sent. Enter plain text or paste again.",
        .unbound => "! Key combination not recognized; ignored. Draft unchanged.",
        .overflow => "! input too long; nothing sent. Draft cleared. Enter a shorter message.",
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
    if (end == .accepted) if (end.accepted.denies) |action| try self.submission.begin(.{ .decision = .{ .action = action, .decision = .deny } });
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
        .failed => |failed| if (failed.err == error.EnvironmentTooLarge) {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            try writer.writeAll("! ");
            try self.submission.environment.describeTooLarge(&writer);
            try writer.writeAll(too_large_advice);
            self.notice = writer.buffered();
        },
        .absent => {},
    }
}

fn settleReader(self: *Self) !void {
    const end = self.joinReader();
    if (self.reading.phase == .recall and end != .complete) self.input.abandonStep();
    // A pending inspection supersedes a silent read it cancelled.
    const mode: departure.Mode = if (self.upgrade_requested or self.input.queuedCommand() != null) .inspection else .active;
    // A fatal failure leaves command output for exit to print.
    if (end.failure(mode)) |err| return err;
    if (end != .complete and self.inspection.command_running) {
        // Nothing to show: the command failed before writing output.
        self.inspection.command_running = false;
    }
    if (end == .complete and self.reading.phase == .history) {
        // What a seam's search found holds whatever the view now shows.
        if (self.job.result.searched) |floor| if (self.live.lowest) |known| {
            self.live.lowest = @max(known, floor);
        };
        // The user may have left the transcript while this page loaded.
        const screen = self.terminal.screen;
        if (screen.view == .transcript and self.job.transcript == self.transcript.id) {
            const prepended = try screen.prependPreparedFile(self.init.io, self.files.inspection, &self.job.result.output_blocks);
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
        // A /setup run over the page may have changed the defaults it shows.
        if (self.reading.phase == .inspection and self.inspection.kind == .command and self.statusShown()) {
            self.inspection.defaults = savedDefaults(self.home);
            try self.refreshStatusPage();
        }
    }
    try self.applyReader(end);
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
    if (result.lowest) |lowest| self.live.lowest = if (self.live.lowest) |known| @min(known, lowest) else lowest;
    var staged: Staged = .{ .frontend = self, .length = result.output_length, .start = try self.terminal.screen.liveEnd(), .cursor = .{ .marks = &result.output_blocks } };
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
    if (staged.length != 0) {
        self.reading.output_started = true;
    }
}

/// Writes staged output to live output up to an output offset.
const Staged = struct {
    frontend: *Self,
    length: u64,
    start: u64,
    written: u64 = 0,
    buffer: [4096]u8 = undefined,
    cursor: OutputBlocks.Cursor,
    admission: @import("ConversationViewport.zig").Document.Admission = .{},

    fn to(self: *Staged, output: u64) !u64 {
        const frontend = self.frontend;
        while (self.written < output) {
            const part = self.cursor.part(self.written, output);
            const count = try frontend.files.inspection.readPositionalAll(frontend.init.io, self.buffer[0..@intCast(@min(self.buffer.len, part.end - self.written))], self.written);
            if (count == 0) return error.TruncatedDisplayScratch;
            // A notice can end the group while a read is still silent. Restore
            // its separator before the first compact heading.
            if (self.written == 0 and !frontend.reading.opening and !frontend.live.compact_tools and self.buffer[0] != '\n') try frontend.terminal.permanent("\n");
            try frontend.terminal.prepared(self.buffer[0..count], self.written, part.span, &self.admission);
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
            var stream: TerminalInput = .{};
            var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .reading = .{ .phase = phase } };
            self.init.io = std.testing.io;
            self.input.init(&stream);
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
            self.input.init(&stream);
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
        // History, footer, status, Sent and /status change together, in one frame.
        const result = &self.job.result;
        self.admission.delivered = @max(self.admission.delivered, result.delivered);
        observed = .{ .work = result.work.work.core(), .opening = self.reading.opening };
        self.live.work = result.work.work;
        // A taken Message leaves the queued row in the frame that shows it.
        self.live.queued = result.queued;
        if (result.queued_line) |shown| self.live.queued_line = shown;
        self.live.drawn = self.job.drawn;
        if (self.admission.echo) |admission| if (admission <= self.admission.delivered) {
            self.admission.echo = null;
        };
        if (self.job.open_status or self.job.watch_status) try self.applyStatus();
        if (result.line) |*line| self.line = line.*;
        if (result.hint) |*hint| self.hint = hint.*;
        self.live.view = result.live;
        self.live.cursor = result.cursor;
        self.reading.opening = false;
        self.upgrade_reobserving = false;
        if (self.reading.phase == .permission) {
            self.reading.prepared_action = result.action;
            self.reading.prepared_summary = result.summary;
            if (self.reading.prepared_action == null) self.reading.phase = .activity;
        }
    }
    // A /status asked for during this read is the next read's, at once.
    self.poll_at = if (self.inspection.status_requested) 0 else std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
    // News goes out first in the next frame, once the read is applied.
    if (observed) |read| try self.lender.observed(self.lender.context, read.work, if (self.line.facts(&self.hint, self.session)) |facts| facts.name else self.session, read.opening);
    self.dirty = true;
}

test "archive badges follow only completed server snapshots and stay distinct from work" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    self.line = .{ .read = .{ .revision = 1, .end = 1 } };
    self.live.work.state = .{ .working = .{ .since = 1 } };
    self.reading.phase = .activity;
    self.notice = "Command accepted";
    var storage: [512]u8 = undefined;
    for ([_]struct { archive: protocol.SessionArchiveState, work: protocol.WorkState, badge: ?[]const u8 }{
        .{ .archive = .archiving, .work = .{ .stopping = .{ .since = 1 } }, .badge = "Stopping and archiving" },
        .{ .archive = .archived, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .badge = "Archived · /unarchive" },
        .{ .archive = .active, .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .badge = null },
    }) |case| {
        const previous = self.line.archive_state;
        self.job.result = .{ .line = .{ .read = .{ .revision = 1, .end = 2 }, .archive_state = case.archive }, .work = .{ .work = .{ .state = case.work } } };
        try self.applyReader(.{ .cancelled = .{ .phase = .activity, .rendering = false } });
        try std.testing.expectEqual(previous, self.line.archive_state);
        try self.applyReader(.complete);
        try std.testing.expectEqual(case.archive, self.line.archive_state);
        try std.testing.expectEqualDeep(case.work, self.live.work.state);
        try held.settle();
        if (case.badge) |badge| {
            try std.testing.expectEqualStrings(badge, rowWith(held.screen, badge, &storage).?);
        } else {
            try std.testing.expect(rowWith(held.screen, "Archived", &storage) == null);
            try std.testing.expect(rowWith(held.screen, "Stopping and archiving", &storage) == null);
        }
        try std.testing.expectEqualStrings("Command accepted", rowWith(held.screen, "Command accepted", &storage).?);
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
            .terminal = undefined,
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
        if (slash_commands_shared.resultNotice(self.notice_buffer[0..slash_commands_shared.result_notice_bytes], bytes[0..read])) |said| {
            self.notice = said;
            return;
        }
    } else if (size == 0) {
        self.notice = slash_commands_shared.no_output;
        return;
    }
    self.inspection.status = null;
    try self.terminal.screen.showFile(self.init.io, self.files.inspection, false);
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
    try reads.writeSubmission(self.inspection.submission, out);
    try output.flush();
}

/// Renders the shown /status page again and shows it in place.
fn refreshStatusPage(self: *Self) !void {
    try self.writeStatusPage();
    try self.terminal.screen.refreshFile(self.init.io, self.files.status);
}

/// The view an inspection runs over. Input goes to the editor the latest
/// frame shows; this stales it, so the view returned to is drawn while the
/// inspection runs. A command run on the /status page leaves the page shown:
/// a short reply is a notice under it, and the next read shows the change on it.
fn leaveFor(self: *Self, kind: Inspection) !void {
    if (kind == .command and self.statusShown()) self.dirty = true else try self.terminal.screen.latest();
}

/// The /status page is the view shown.
fn statusShown(self: *const Self) bool {
    return self.inspection.status != null and self.terminal.screen.view == .inspection;
}

/// Up or Down on the /status page with an empty draft moves `›` to the
/// next changeable row, scrolling the page to show it; false otherwise.
fn moveSelection(self: *Self, down: bool) !bool {
    if (!self.statusShown() or self.input.composition().bytes.len != 0) return false;
    self.inspection.selected = status_page.step(self.inspection.selected, down);
    try self.refreshStatusPage();
    self.terminal.screen.revealLine(status_page.line(self.inspection.selected));
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

test "typing beside a ready Action moves to the draft, whose unoffered Enter decides nothing, and which keeps its text when a page opens or the Action leaves" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try Screen.Test.init(screen, std.testing.io, &environ, false);
    defer Screen.Test.deinit(screen);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const page = try directory.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer page.close(std.testing.io);
    const actions = try directory.dir.createFile(std.testing.io, "actions", .{ .read = true });
    defer actions.close(std.testing.io);
    // Longer than a notice, so it opens as a page and hides the Action.
    const rows: [512]u8 = @splat('\n');
    try page.writePositionalAll(std.testing.io, &rows, 0);
    const Change = enum { none, decided_elsewhere, command_page, status_page };
    for (std.enums.values(Change)) |change| for ([_][2][]const u8{ .{ "/", "/status" }, .{ "a", "a" } }) |line| {
        errdefer std.debug.print("change={s} line={s}\n", .{ @tagName(change), line[1] });
        var terminal: Terminal = .{ .original = undefined, .flags = undefined, .output = -1, .screen = screen };
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = .{ .scratch = undefined, .action = undefined, .inspection = page, .status = page, .actions = .{ actions, actions } }, .command = undefined, .terminal = &terminal, .lender = quiet_overview, .colour = false, .reading = .{ .opening = false } };
        self.init.io = std.testing.io;
        self.input.init(&self.terminal.stream);
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
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
        try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, screen.selected);
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
                self.job.status_taken = &self.inspection.sessions[0];
                status_page.sample(self.job.status_taken);
                self.job.result.status = true;
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
        // No frame showed the whole line, so its Enter has no offer: nothing
        // is decided, and the Action holds a Message back.
        try sendKeys(&self, "\r");
        try std.testing.expectEqual(@as(u64, 7), screen.consent.?.action);
        try std.testing.expect(self.submission.view() == null);
        // A slash command runs as typed; other text stays the draft.
        if (line[0][0] == '/') {
            try std.testing.expectEqualStrings("/status", self.input.queuedCommand().?);
            try std.testing.expectEqualStrings("", self.input.composition().bytes);
        } else {
            try std.testing.expect(self.input.queuedCommand() == null);
            try std.testing.expectEqualStrings("a", self.input.composition().bytes);
            try std.testing.expectEqualStrings(if (change == .none) "! Use ←→ and Enter to choose; a message denies the call." else "! Action needs a decision; Esc returns to it. Draft retained.", self.notice.?);
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
    try Screen.Test.init(screen, std.testing.io, &environ, false);
    defer Screen.Test.deinit(screen);
    var terminal: Terminal = .{ .original = undefined, .flags = undefined, .screen = screen };
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .files = undefined, .command = undefined, .terminal = &terminal, .colour = false, .reading = .{ .opening = false } };
    try screen.append("GROWS-FIRST\n");
    self.live.marks.record(.{ .offset = 12, .cursor = .{ .end = 3 }, .admitted = 4 });
    // Unescaped, the rows after the mark fit; escaped, they evict it.
    for (0..45000) |_| try screen.append("\u{200b}");
    try screen.append("\nGROWS-END\n");
    try self.beginTranscript();
    try std.testing.expect(std.mem.indexOf(u8, screen.browsing.text.text(), "Earlier rows left this view.") != null);
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
        try Screen.Test.init(screen, std.testing.io, &held.environ, false);
        const directory = try held.tmp.dir.realPath(std.testing.io, &held.directory);
        held.self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = held.directory[0..directory], .files = undefined, .command = undefined, .terminal = &held.terminal, .interrupted = &held.interrupted, .lender = quiet_overview, .colour = false, .reading = .{ .opening = false } };
        held.self.init.io = std.testing.io;
        held.self.live.work = .{};
        held.terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = screen, .input = pipes[0][0], .output = pipes[1][1], .pump = .{ .context = held, .step = pumpHeld } };
        held.self.startInput();
        held.self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = held.self.directory, .input = &held.self.input, .environment = .empty };
        return held;
    }

    fn destroy(held: *HeldFrontend) void {
        held.self.submission.cancel();
        _ = held.self.submission.join();
        held.self.submission.close();
        for (held.pipes) |pipe| for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        Screen.Test.deinit(held.screen);
        std.testing.allocator.destroy(held.screen);
        held.tmp.cleanup();
        held.environ.deinit();
        std.testing.allocator.destroy(held);
    }

    /// Queues terminal input and fills the output pipe so the next frame, a
    /// whole-screen refresh, waits.
    fn hold(held: *HeldFrontend, input: []const u8) !void {
        held.screen.backend.invalidate();
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

test "ordinary input service waits boundedly while the output pump never waits for input" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    // Independent expected budgets, not elapsed wall time or CPU thresholds.
    held.terminal.writing = false;
    try std.testing.expectEqual(@as(i32, 16), held.self.inputWait());
    held.terminal.writing = true;
    try std.testing.expectEqual(@as(i32, 0), held.self.inputWait());
    held.terminal.writing = false;
}

test "completed detail return hands queued input to the next owner before any old-owner read" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    held.self.poll_at = std.math.maxInt(i96); // No Host scan in this input/output fixture.
    const backend = held.screen.backend;
    const stream = &held.terminal.stream;
    const tail = "z\x03\x1b[";
    const Credit = struct {
        held: *HeldFrontend,
        injected: bool = false,
        credited: bool = false,
        fn step(raw: *anyopaque) !void {
            const credit: *@This() = @ptrCast(@alignCast(raw));
            if (!credit.injected) {
                const escape = "\x1b[27u";
                try std.testing.expect(std.c.write(credit.held.pipes[0][1], escape, escape.len) == escape.len);
                credit.injected = true;
            }
            try pump(&credit.held.self);
            if (credit.held.self.leaving != .returned or credit.credited) return;
            try std.testing.expect(!credit.held.screen.ticket.?.delivered);
            // Credit returns NOW, not after tail input is pumped/discarded.
            // These bytes belong to the next owner once this write completes.
            try std.testing.expect(std.c.write(credit.held.pipes[0][1], tail, tail.len) == tail.len);
            credit.credited = true;
            var sink: [65536]u8 = undefined;
            while (std.c.read(credit.held.pipes[1][0], &sink, sink.len) > 0) {}
        }
    };
    var credit: Credit = .{ .held = held };
    held.terminal.pump = .{ .context = &credit, .step = Credit.step };
    try held.hold("");
    try held.self.driveActive();
    try std.testing.expect(credit.injected and credit.credited);
    try std.testing.expectEqual(@as(?Outcome, .returned), held.self.leaving);
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
    try std.testing.expect(backend.idle() and held.screen.backend == backend and &held.terminal.stream == stream);
    var remaining: [16]u8 = undefined;
    const count = std.c.read(held.pipes[0][0], &remaining, remaining.len);
    try std.testing.expectEqual(@as(isize, tail.len), count);
    try std.testing.expectEqualStrings(tail, remaining[0..@intCast(count)]);
    try std.testing.expectEqual(TerminalInput.Pending.none, stream.pending());
    // The new owner sees the printable byte, its own urgent exit, then the
    // exact partial CSI; no raw byte was replayed, discarded or reclassified.
    var buffer: [64]u8 = undefined;
    var next: Editor = .{ .buffer = &buffer };
    var saw_exit = false;
    for (remaining[0..@intCast(count)]) |byte| {
        var decoded = stream.feed(byte, std.Io.Clock.awake.now(std.testing.io).nanoseconds);
        while (decoded != .none) : (decoded = stream.next()) {
            const result = next.apply(@import("overview_view.zig").keys, decoded);
            if (result == .action) saw_exit = result.action == .exit;
        }
    }
    try std.testing.expect(saw_exit);
    try std.testing.expectEqualStrings("z", next.buffer[0..next.length]);
    try std.testing.expectEqual(TerminalInput.Pending.incomplete, stream.pending());
    const up = stream.feed('A', std.Io.Clock.awake.now(std.testing.io).nanoseconds);
    try std.testing.expect(up == .event and up.event.event.key_press.matchExact(vaxis.Key.up, .{}));
    try std.testing.expect(stream.next() == .none and stream.pending() == .none);
}

test "a frozen detail return gates complete events but preserves reports and a split prefix through handoff" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const backend = held.screen.backend;
    const stream = &held.terminal.stream;
    const Gate = struct {
        held: *HeldFrontend,
        credited: bool = false,
        pumps: usize = 0,
        fn step(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            gate.pumps += 1;
            const frontend = &gate.held.self;
            try pump(frontend);
            // Neither delivered authority nor backend policy changes while
            // any frozen byte still waits for credit.
            try std.testing.expect(!gate.held.screen.backend.idle());
            try std.testing.expect(!gate.held.screen.ticket.?.delivered);
            try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, gate.held.screen.backend.widthMethod());
            var fds = [_]std.posix.pollfd{.{ .fd = gate.held.pipes[0][0], .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 0) != 0) return;
            try std.testing.expectEqual(@as(?Outcome, .returned), frontend.leaving);
            try std.testing.expectEqualStrings("", frontend.input.composition().bytes);
            try std.testing.expect(frontend.input.queuedCommand() == null and frontend.submission.view() == null);
            try std.testing.expectEqual(TerminalInput.Pending.incomplete, gate.held.terminal.stream.pending());
            try std.testing.expect(gate.held.screen.scope != gate.held.screen.ticket.?.scope);
            gate.credited = true;
            var sink: [65536]u8 = undefined;
            while (std.c.read(gate.held.pipes[1][0], &sink, sink.len) > 0) {}
        }
    };
    var gate: Gate = .{ .held = held };
    held.terminal.pump = .{ .context = &gate, .step = Gate.step };
    // Encoded Escape does not depend on its inactivity timer. Everything
    // after it is gated, including pasted Ctrl-C and command/approval keys.
    try held.hold("\x1b[27u/status\r\x1b[200~\x03\x1b[201~\x1b[?2027;3$y\x1b[");
    try held.self.drawFrame();
    try std.testing.expect(gate.credited and gate.pumps > 1);
    try std.testing.expect(backend.idle());
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, backend.widthMethod());
    try std.testing.expect(held.terminal.pending_width == null);
    try std.testing.expectEqual(@as(?Outcome, .returned), held.self.leaving);
    // Domain reset cannot reset the invocation decoder or replace its backend.
    held.screen.init(backend);
    held.self.startInput();
    try std.testing.expect(held.screen.backend == backend and &held.terminal.stream == stream);
    try std.testing.expectEqual(TerminalInput.Pending.incomplete, stream.pending());
    const decoded = stream.feed('A', std.Io.Clock.awake.now(std.testing.io).nanoseconds);
    try std.testing.expect(decoded == .event and !decoded.event.pasted);
    try std.testing.expect(decoded.event.event.key_press.matchExact(vaxis.Key.up, .{}));
    try std.testing.expect(stream.next() == .none and stream.pending() == .none);
}

test "urgent typed exit or signal abandons a zero-credit detail frame and poisons before release" {
    for ([_]bool{ false, true }) |signal| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        try held.hold(if (signal) "" else "\x1b[27u\x03");
        if (signal) held.interrupted.stopped.store(true, .release);
        const started = std.Io.Clock.awake.now(std.testing.io);
        try std.testing.expectError(error.InteractiveInterrupted, held.self.drawFrame());
        const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - started.nanoseconds;
        try std.testing.expect(elapsed < std.time.ns_per_s);
        try std.testing.expect(!held.screen.ticket.?.delivered);
        try std.testing.expectError(error.RenderBackendPoisoned, held.screen.backend.begin(.{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 }));
        if (!signal) try std.testing.expectEqual(@as(?Outcome, .detached), held.self.leaving);
    }
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

test "a line typed beside one Action keeps the input row when the next Action arrives, so its Enter can only deny that Action" {
    for ([_]bool{ false, true }) |deny| {
        errdefer std.debug.print("deny={}\n", .{deny});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const first = try held.adopt(3);
        defer first.close(std.testing.io);
        try held.settle();
        try sendKeys(&held.self, "\x1b[Dxy");
        try std.testing.expectEqualStrings("xy", held.self.input.composition().bytes);
        const second = try nextAction(held);
        defer second.close(std.testing.io);
        try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.selected);
        if (deny) {
            // The frame offered the line as the second Action's reason.
            try sendKeys(&held.self, "\r");
            try std.testing.expect(held.screen.consent == null);
            const reason = held.self.submission.intent.?.message_then_deny;
            try std.testing.expectEqualStrings("xy", try held.self.input.message(reason.ticket));
            try std.testing.expectEqual(@as(u64, 0xb), reason.action);
            continue;
        }
        // Esc ends the line and shows the second Action's choice at Allow once.
        try sendKeys(&held.self, "\x07");
        try held.settle();
        try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.selected.row);
        try std.testing.expect(held.screen.offered() != null);
        try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
        try std.testing.expectEqualStrings("xy", held.self.input.composition().bytes);
    }
}

test "a Message being written when an Action arrives keeps the input row, so its Enter can never approve" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try sendKeys(&held.self, "run the tests");
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    // The Enter meant to send the line, read before any frame showed the
    // Action, decides nothing.
    try sendKeys(&held.self, "\r");
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqualStrings("run the tests", held.self.input.composition().bytes);
    try std.testing.expectEqualStrings(reason_not_ready, held.self.notice.?);
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.selected);
    // Esc shows the choice at Allow once, and the draft stays.
    try sendKeys(&held.self, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, held.screen.selected);
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
    try std.testing.expectEqualStrings("run the tests", held.self.input.composition().bytes);
}

test "the draft beside an offered Action sends its line first and denies only that Action" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    try sendKeys(&held.self, "use the cached copy");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.selected);
    try std.testing.expectEqual(ConsentPolicy.Decision{ .action = 0xa, .choice = .deny }, held.screen.offered().?);
    var storage: [256]u8 = undefined;
    try std.testing.expectEqualStrings("enter denies the call and sends this · esc back to the choice", lastRow(held.screen, &storage));
    try sendKeys(&held.self, "\r");
    // The Action is consumed and left, and the Message is the original; its
    // acceptance begins the denial.
    try std.testing.expect(held.screen.consent == null);
    try std.testing.expect(!held.screen.actionVisible());
    const reason = held.self.submission.intent.?.message_then_deny;
    try std.testing.expectEqualStrings("use the cached copy", try held.self.input.message(reason.ticket));
    try std.testing.expectEqual(@as(u64, 0xa), reason.action);
    try std.testing.expectEqual(@as(u64, 1), held.self.admission.sent);
    try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
}

test "an Enter in the draft beside an Action before its frame is offered denies nothing; the next one may" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    // The line and its Enter in one burst: no frame showed the line.
    try sendKeys(&held.self, "skip it\r");
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqualStrings("skip it", held.self.input.composition().bytes);
    try std.testing.expectEqualStrings(reason_not_ready, held.self.notice.?);
    // A frame held while its write pumps the Enter: still not delivered.
    try held.hold("\r");
    _ = try held.self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expect(held.self.submission.view() == null);
    try std.testing.expectEqualStrings(reason_not_ready, held.self.notice.?);
    // The refusal is drawn and offered; the Enter after it sends the line.
    try held.settle();
    try sendKeys(&held.self, "\r");
    try std.testing.expect(held.screen.consent == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.self.submission.intent.?.message_then_deny.action);
}

test "a draft beside an Action denies only after a frame whose line under it says Enter denies" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try sendKeys(&held.self, "run the tests");
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    // The Enter meant to send the line, read before any frame showed the
    // Action, is refused.
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqualStrings(reason_not_ready, held.self.notice.?);
    // Another notice takes the line under the draft, as a confirmation of
    // an earlier Message would: the frame shows the reason but never says
    // what Enter does, so the Enter after it denies nothing.
    held.self.notice = "  • Original confirmed.";
    held.self.dirty = true;
    try held.settle();
    var storage: [256]u8 = undefined;
    try std.testing.expectEqualStrings("• Original confirmed.", std.mem.trim(u8, lastRow(held.screen, &storage), " "));
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.selected);
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqual(@as(?Submission.View, null), held.self.submission.view());
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    // That refusal says it; once its frame is offered, Enter denies.
    try std.testing.expectEqualStrings(reason_not_ready, held.self.notice.?);
    held.self.dirty = true;
    try held.settle();
    try std.testing.expectEqualStrings(reason_not_ready, lastRow(held.screen, &storage));
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqual(@as(?ConsentPolicy.Pending, null), held.screen.consent);
    const reason = held.self.submission.intent.?.message_then_deny;
    try std.testing.expectEqualStrings("run the tests", try held.self.input.message(reason.ticket));
    try std.testing.expectEqual(@as(u64, 0xa), reason.action);
}

/// Puts an accepted reason for Action 0xa in the submission, its Admission
/// completed and not yet joined.
fn acceptReason(held: *HeldFrontend) !void {
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
    };
    const submission = &held.self.submission;
    submission.intent = .{ .message_then_deny = .{ .ticket = held.self.input.submitText("skip"), .action = 0xa } };
    submission.key = @splat('B');
    submission.state = .submitting;
    submission.publication = .published;
    submission.reply = .{ .status = 200, .context = .{ .kind = .message }, .target = .{ .message = .{ .bytes = 4, .digest = protocol.contentDigest("skip") } }, .answer = .{ .replayed = false, .result = .{ .accepted = .{ .message = .{ .admission = 37 } } } } };
    try submission.task.start(std.testing.io, submission, Worker.done);
    while (!submission.task.completed()) std.Thread.yield() catch {};
}

/// The exit guidance the submission leaves.
fn recoveryText(self: *const Self, storage: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(storage);
    try self.writeRecoveryGuide(&out);
    return out.buffered();
}

test "leaving after a reason is accepted still sends its denial" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    try acceptReason(held);
    try sendKeys(&held.self, "/exit\r");
    try std.testing.expectEqual(@as(?Outcome, .detached), held.self.leaving);
    held.self.stop();
    const settled = held.self.settle({});
    // The Message shows, and the denial was begun and joined. No Store or
    // Host serves this test, so the denial is the original the exit guidance
    // names, under its own reserved key.
    try std.testing.expectEqual(@as(?u64, 37), held.self.admission.echo);
    try std.testing.expectEqual(@as(?std.Thread, null), held.self.submission.task.thread);
    try std.testing.expect(settled.admission_error != null);
    const denial = held.self.submission.intent.?.decision;
    try std.testing.expectEqual(@as(u64, 0xa), denial.action);
    try std.testing.expectEqual(protocol.PermissionDecision.deny, denial.decision);
    var storage: [512]u8 = undefined;
    const key = held.self.submission.key;
    try std.testing.expect(!std.mem.eql(u8, &key, &@as([36]u8, @splat('B'))));
    var expected: [512]u8 = undefined;
    try std.testing.expectStringStartsWith(try recoveryText(&held.self, &storage), try std.fmt.bufPrint(&expected, "rui: Capture not confirmed. Inspect rui request list for reserved key {s};", .{key}));
}

test "a denial that cannot start after its reason is accepted leaves the Message shown and the denial not sent" {
    const Failing = struct {
        fn random(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Failing.random;
    const held = try HeldFrontend.create();
    defer held.destroy();
    try acceptReason(held);
    held.self.submission.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    defer held.self.submission.io = std.testing.io;
    try std.testing.expectError(error.EntropyUnavailable, held.self.admit());
    try std.testing.expectEqual(@as(?u64, 37), held.self.admission.echo);
    try std.testing.expectEqual(Submission.Recovery{ .not_sent = .decision }, held.self.submission.recovery());
    var storage: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try recoveryText(&held.self, &storage), "rui: Decision was not sent: capture did not begin."));
}

test "a draft of one choice letter or a slash command beside an offered Action denies nothing" {
    for ([_][]const u8{ "a", "d", "y", "n", "A", "D", " Y", "N ", "/wait" }) |draft| {
        errdefer std.debug.print("draft={s}\n", .{draft});
        const held = try HeldFrontend.create();
        defer held.destroy();
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        try sendKeys(&held.self, draft);
        try held.settle();
        try std.testing.expect(held.screen.offered() != null);
        try sendKeys(&held.self, "\r");
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
        if (draft[0] == '/') {
            // The command ran, as anywhere else, and emptied the draft.
            try std.testing.expectEqualStrings("Work continues while you compose.", held.self.notice.?);
            try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        } else {
            try std.testing.expectEqualStrings("! Use ←→ and Enter to choose; a message denies the call.", held.self.notice.?);
            try std.testing.expectEqualStrings(draft, held.self.input.composition().bytes);
        }
    }
}

/// The screen's last row as drawn, trailing blanks trimmed.
fn lastRow(screen: *Screen, storage: []u8) []const u8 {
    const window = Screen.Test.window(screen);
    var length: usize = 0;
    for (0..window.width) |column| {
        const grapheme = (window.readCell(@intCast(column), window.height - 1) orelse break).char.grapheme;
        if (length + grapheme.len > storage.len) break;
        @memcpy(storage[length..][0..grapheme.len], grapheme);
        length += grapheme.len;
    }
    return std.mem.trimEnd(u8, storage[0..length], " ");
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
    try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.select(false));
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
    try std.testing.expectEqualStrings("! Unknown command /he · /help", self.notice.?);
    // Drawn: Enter takes the highlighted /help.
    try stepKeys(held, "/he");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\r");
    try std.testing.expect(self.notice == null or !std.mem.startsWith(u8, self.notice.?, "! Unknown command"));
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
    try std.testing.expect(self.notice == null or !std.mem.startsWith(u8, self.notice.?, "! Unknown command"));
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
    try std.testing.expect(self.notice == null);
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
    try std.testing.expectEqualStrings("! Unknown command /he · /help", self.notice orelse "");
    try stepKeys(held, "/he\t");
    try std.testing.expectEqualStrings("/help", self.input.composition().bytes);
}

test "Esc closes the command list first only when the latest frame drew it" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    try held.settle();
    // Drawn: the first Esc closes only the list, the next one acts as Esc.
    try stepKeys(held, "/st");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try std.testing.expect(self.notice == null);
    try held.settle();
    try std.testing.expectEqual(.closed, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", self.notice.?);
    // The latest frame drew no list, the first being closed: Esc acts at
    // once.
    try stepKeys(held, "\x15/st\x07");
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", self.notice.?);
    // Over a waiting Action: a shown list closes first, then Esc returns to
    // the choice; an unseen one never holds the choice back.
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Row.draft, held.screen.inputRow());
    try stepKeys(held, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.inputRow());
    try stepKeys(held, "x\x7f");
    try std.testing.expectEqual(ConsentPolicy.Row.draft, held.screen.inputRow());
    try std.testing.expectEqualStrings("/st", self.input.composition().bytes);
    try stepKeys(held, "\x07");
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Row.selector, held.screen.inputRow());
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
    try stepKeys(held, "\r");
    try std.testing.expectEqualSlices(u8, original, &(self.submission.retry orelse return error.TestUnexpectedResult));
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    self.submission.retry = null;
    // Down twice reaches the older Message, and Enter queues its /result.
    try held.settle();
    try stepKeys(held, "\x1b[B\x1b[B");
    try std.testing.expectEqual(@as(usize, 2), held.screen.commands.?.highlight);
    try stepKeys(held, "\r");
    try std.testing.expectEqualStrings("/result " ++ older, self.input.takeCommand().?);
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    // The original resolves after a frame drew its row highlighted: until
    // a frame draws the rows that are left, Enter takes none of them.
    try held.settle();
    try std.testing.expectEqualStrings("/recover " ++ original, held.screen.commands.?.completion());
    self.submission.intent = null;
    try stepKeys(held, "\r");
    try std.testing.expect(self.input.queuedCommand() == null);
    try std.testing.expect(self.submission.retry == null);
    try held.settle();
    try std.testing.expectEqualStrings("/result " ++ original, held.screen.commands.?.list.entries[0].word);
    // Tab puts the highlighted row's line in the draft, for editing.
    try stepKeys(held, "\x1b[B\t");
    try std.testing.expectEqualStrings("/result " ++ newer, self.input.composition().bytes);
    try held.settle();
    try std.testing.expect(held.screen.commands == null);
    // Esc closes the rows first, then leaves the page, which takes them.
    try stepKeys(held, "\x15");
    try held.settle();
    try std.testing.expectEqual(.drawn, held.screen.commands.?.seen);
    try stepKeys(held, "\x07");
    try held.settle();
    try std.testing.expectEqual(.closed, held.screen.commands.?.seen);
    try std.testing.expectEqual(Screen.ViewKind.inspection, held.screen.view);
    try stepKeys(held, "\x07");
    try held.settle();
    try std.testing.expect(held.screen.view != .inspection);
    try std.testing.expect(held.screen.commands == null);
    // Enter on an empty draft with no rows does nothing, and Tab is a tab.
    try stepKeys(held, "\r");
    try std.testing.expect(self.input.queuedCommand() == null);
    try stepKeys(held, "\t");
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
        try stepKeys(held, "\r");
        try std.testing.expect(self.submission.retry == null);
        try std.testing.expectEqualStrings("/result " ++ newer, self.input.takeCommand().?);
        self.submission.intent = null;
    }
}

test "/recover typed beside a waiting Action retries nothing, as Ctrl-R does" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const original = "01234567-89ab-4cde-8012-0123456789ab";
    self.submission.intent = .{ .message = self.input.submitText("unconfirmed original") };
    self.submission.state = .unconfirmed;
    self.submission.key = original.*;
    const file = try held.adopt(3);
    defer file.close(std.testing.io);
    try held.settle();
    try std.testing.expect(held.screen.consent != null);
    try stepKeys(held, "x\x7f/recover " ++ original ++ "\r");
    try std.testing.expect(self.submission.retry == null);
    try std.testing.expect(std.mem.startsWith(u8, self.notice.?, "! Action needs a decision"));
    self.submission.intent = null;
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
    try facts.writeJson(&page);
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
    try std.testing.expect(held.screen.consent == null);
    try std.testing.expectEqual(@as(u64, 0), try action.length(io));
    try std.testing.expectEqualStrings("draft retained", self.input.composition().bytes);
    // The ordinary refresh takes the newer work; the conversation stays usable.
    try self.launch(self.freeze(.activity), reads.scan);
    facts.work.work = .{ .state = .{ .idle = .{ .since = 1 } } };
    page = std.Io.Writer.fixed(&page_buffer);
    try facts.writeJson(&page);
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
    try std.testing.expect(held.screen.consent == null);
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
        // /details begins its read, as driveActive does.
        self.admission.details_sent = self.admission.sent;
        self.reading.phase = .details;
        try self.reader.start(std.testing.io, self, Worker.read);
        if (send) {
            try self.beginMessage(.{ .message = self.input.submitText("sent while the page loaded") });
            self.submission.cancel();
            _ = self.submission.join();
            self.submission.close();
            self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = self.directory, .input = &self.input, .environment = .empty };
            self.input.init(&self.terminal.stream);
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

test "choice readiness: keys pumped by a redraw of the same choice act on the choice shown, and the Enter after a move waits for a frame showing it" {
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
    // Left and Enter arrive while a redraw that still shows Deny is held:
    // Left acts on the Deny the delivered frame showed, and spends the
    // offer, so the Enter after it decides nothing.
    try held.hold("\x1b[D\r");
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expect(self.submission.view() == null);
    try std.testing.expectEqual(@as(u64, 0xa), held.screen.consent.?.action);
    try std.testing.expectEqual(ConsentPolicy.Choice.allow_once, held.screen.consent.?.highlight);
    try std.testing.expectEqualStrings("! Not ready; nothing authorized.", self.notice.?);
    // A delivered frame shows Allow once; then Enter decides it.
    try held.settle();
    try std.testing.expect(held.screen.offered() != null);
    try sendKeys(self, "\r");
    try std.testing.expectEqual(protocol.PermissionDecision.allow_once, self.submission.intent.?.decision.decision);
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
        try std.testing.expectEqual(ConsentPolicy.Projection{ .approval = .reason }, held.screen.selected);
        // An empty draft is no reason: its Enter sends nothing.
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
    fn observed(_: *anyopaque, _: protocol.session_work.Work, _: []const u8, _: bool) !void {}
}.observed };

/// An overview that lent the terminal, reduced to one Session's stop
/// prompt, stop and notice.
const FakeOverview = struct {
    asking: bool = false,
    stopping: bool = false,
    stops: usize = 0,
    notice: ?[]const u8 = null,

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
        const fake: *FakeOverview = @ptrCast(@alignCast(raw));
        const asked = fake.asking;
        fake.asking = false;
        fake.notice = null;
        if (input != .stop) return;
        if (fake.stopping or work != .working) {
            fake.notice = "unused: Stopping";
        } else if (asked) {
            fake.stops += 1;
            fake.stopping = true;
        } else fake.asking = true;
    }

    fn service(_: *anyopaque) !bool {
        return false;
    }

    fn line(raw: *anyopaque, work: protocol.session_work.Kind) Lender.Said {
        const fake: *FakeOverview = @ptrCast(@alignCast(raw));
        return .{ .text = if (fake.asking) "Stop unused? ctrl+x yes · esc no" else fake.notice, .asking = if (fake.asking) .stop else null, .stoppable = work == .working and !fake.stopping };
    }

    fn lender(fake: *FakeOverview) Lender {
        return .{ .context = fake, .step = FakeOverview.step, .service = FakeOverview.service, .line = FakeOverview.line, .observed = quiet_overview.observed };
    }
};

test "Ctrl-X twice stops the open Session through the overview; any other key only cancels the ask" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    var overview: FakeOverview = .{};
    held.self.lender = overview.lender();
    held.self.line = .{ .read = .{ .revision = 1, .end = 1 } };
    try held.self.line.model.set("gpt-6-sol");
    const Bottom = struct {
        fn row(frontend: *HeldFrontend, storage: []u8) ![]const u8 {
            frontend.self.dirty = true;
            try frontend.settle();
            const window = Screen.Test.window(frontend.screen);
            var length: usize = 0;
            for (0..window.width) |column| {
                const grapheme = (window.readCell(@intCast(column), window.height - 1) orelse break).char.grapheme;
                @memcpy(storage[length..][0..grapheme.len], grapheme);
                length += grapheme.len;
            }
            return std.mem.trimEnd(u8, storage[0..length], " ");
        }
    };
    var storage: [512]u8 = undefined;
    // The hint shows only while the overview says Ctrl-X would ask.
    try std.testing.expectEqualStrings("unused · gpt-6-sol", try Bottom.row(held, &storage));
    held.self.live.work.state = .{ .working = .{ .since = 1 } };
    try std.testing.expectEqualStrings("unused · gpt-6-sol · ctrl+x stop", try Bottom.row(held, &storage));
    try sendKeys(&held.self, "\x18");
    try std.testing.expectEqualStrings("Stop unused? ctrl+x yes · esc no", try Bottom.row(held, &storage));
    // Ctrl-G, like Esc, cancels and stays in the conversation.
    try sendKeys(&held.self, "\x07");
    try std.testing.expect(held.self.leaving == null and !overview.asking);
    try std.testing.expectEqualStrings("unused · gpt-6-sol · ctrl+x stop", try Bottom.row(held, &storage));
    // Typing cancels too and still types, so the next Ctrl-X asks again.
    try sendKeys(&held.self, "\x18x\x18");
    try std.testing.expectEqualStrings("x", held.self.input.composition().bytes);
    try std.testing.expect(overview.asking and overview.stops == 0);
    try sendKeys(&held.self, "\x18");
    try std.testing.expectEqual(@as(usize, 1), overview.stops);
    try std.testing.expectEqualStrings("unused · gpt-6-sol", try Bottom.row(held, &storage));
    // The overview's notice comes before the conversation's own.
    held.self.notice = "Work continues while you compose.";
    try sendKeys(&held.self, "\x18");
    try std.testing.expectEqualStrings("unused: Stopping", try Bottom.row(held, &storage));
    try sendKeys(&held.self, "y");
    try std.testing.expectEqualStrings("Work continues while you compose.", try Bottom.row(held, &storage));
    // Until the Session opens its work is unknown: Ctrl-X says so and asks
    // nothing.
    overview = .{};
    held.self.notice = null;
    held.self.reading.opening = true;
    try sendKeys(&held.self, "\x18");
    try std.testing.expect(!overview.asking);
    try std.testing.expectEqualStrings("Ctrl-X stops the Session once it opens.", try Bottom.row(held, &storage));
}

/// The screen row that contains `needle`, trailing blanks trimmed.
fn rowWith(screen: *Screen, needle: []const u8, storage: []u8) ?[]const u8 {
    const window = Screen.Test.window(screen);
    for (0..window.height) |row| {
        var length: usize = 0;
        for (0..window.width) |column| {
            const grapheme = (window.readCell(@intCast(column), @intCast(row)) orelse break).char.grapheme;
            if (length + grapheme.len > storage.len) break;
            @memcpy(storage[length..][0..grapheme.len], grapheme);
            length += grapheme.len;
        }
        const text = std.mem.trimEnd(u8, storage[0..length], " ");
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
    var storage: [512]u8 = undefined;
    try std.testing.expectEqualStrings(" › Effort          high  Session override", rowWith(held.screen, "Effort ", &storage).?);
    try std.testing.expectEqualStrings("   Permissions     bypass · Bash and MCP run without asking", rowWith(held.screen, "Permissions", &storage).?);
    // Shift-Down scrolls as before; the mark stays.
    try sendKeys(&held.self, "\x1b[1;2B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Effort ", &storage).?, " › Effort"));
    // Down moves the mark, past the Session's fixed Model, Store and
    // Instructions to the defaults' Model; PageUp and PageDown still scroll.
    try sendKeys(&held.self, "\x1b[B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Effort ", &storage).?, "   Effort"));
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Permissions", &storage).?, " › Permissions"));
    for (0..6) |_| try sendKeys(&held.self, "\x1b[B");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Rui default", &storage).?, " › Model"));
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "fixed for this Session", &storage).?, "   Model"));
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "set from a shell", &storage).?, "   Instructions"));
    // A refresh, as the open page's next read, keeps the mark.
    try showStatus(held, false, "fix-safari-export");
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Rui default", &storage).?, " › Model"));
    try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Headroom", &storage).?, " › Headroom"));
    // Enter on Headroom drafts only its command, whose list offers
    // `default`: the model's default never becomes an override of its value.
    try sendKeys(&held.self, "\r");
    try std.testing.expectEqualStrings("/configure --output-reservation ", held.self.input.composition().bytes);
    // With a draft, Up and Down keep their meaning: the mark stays.
    try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Headroom", &storage).?, " › Headroom"));
    held.self.input.clear();
    for (0..8) |_| try sendKeys(&held.self, "\x1b[A");
    try held.settle();
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Effort ", &storage).?, " › Effort"));
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
    try std.testing.expect(std.mem.startsWith(u8, rowWith(held.screen, "Effort ", &storage).?, " › Effort"));
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
        var storage: [512]u8 = undefined;
        // The defaults are read as the page opens, not on each read after.
        const readiness: preferences.Readinesses = .initFill(.missing);
        _ = try preferences.update(held.self.home, .{ .notifications = false }, &readiness);
        try showStatus(held, false, "fix-safari-export");
        try std.testing.expectEqualStrings("   Notifications   on", rowWith(held.screen, "Notifications", &storage).?);
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
            try std.testing.expectEqualStrings("Configured.", held.self.notice.?);
            // A command run over the page reads them again.
            try std.testing.expectEqualStrings("   Notifications   off", rowWith(held.screen, "Notifications", &storage).?);
            try std.testing.expectEqualStrings(" › Name            fix-safari-export", rowWith(held.screen, "Name", &storage).?);
            // The open page's next read shows the new value, its mark where it was.
            try showStatus(held, false, "lane four");
            try std.testing.expectEqualStrings(" › Name            lane four", rowWith(held.screen, "Name", &storage).?);
        } else {
            try std.testing.expect(rowWith(held.screen, "--label is 1-100", &storage) != null);
            try std.testing.expect(rowWith(held.screen, " Name ", &storage) == null);
        }
    }
}

test "all-fitting no-older Up and PgUp are identical cells, while real history and motion detach" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    for ([_]usize{ 0, 4, 9 }) |lines| {
        held.screen.live.text.clear();
        for (0..lines) |_| try held.screen.append("line\n");
        self.live.marks = .{};
        self.live.marks.record(.{ .offset = 0, .cursor = null, .admitted = 0 });
        _ = held.screen.presented(try Screen.Test.render(held.screen, &out.writer, size, "", 0, .{}, &.{}));
        const rendered = out.written().len;
        for ([_]bool{ false, true }) |page| {
            try self.scroll(false, page);
            try std.testing.expectEqual(Screen.ViewKind.live, held.screen.view);
            _ = held.screen.presented(try Screen.Test.render(held.screen, &out.writer, size, "", 0, .{}, &.{}));
            try std.testing.expectEqual(rendered, out.written().len);
        }
    }
    self.reading.opening = true;
    try self.scroll(false, true);
    try std.testing.expectEqual(Screen.ViewKind.live, held.screen.view);
    self.reading.opening = false;
    self.live.marks.items[0].cursor = .{ .end = 5 };
    try self.scroll(false, true);
    try std.testing.expectEqual(Screen.ViewKind.transcript, held.screen.view);
    try std.testing.expectEqual(@as(?u64, 5), self.transcript.older.?.end);
    try std.testing.expect(self.olderWanted());
    try held.screen.latest();
    for (0..40) |_| try held.screen.append("more\n");
    _ = held.screen.presented(try Screen.Test.render(held.screen, &out.writer, size, "", 0, .{}, &.{}));
    const before = held.screen.live.scroll.scroll.y;
    try self.scroll(false, false);
    try std.testing.expectEqual(before - 1, held.screen.browsing.scroll.scroll.y);
    try self.scroll(false, true);
    try std.testing.expectEqual(before - 1 - held.screen.height, held.screen.browsing.scroll.scroll.y);
    try sendKeys(self, "\x1b[200~draft\nsecond\x1b[201~");
    try sendKeys(self, "\x1b[1;5F");
    try std.testing.expectEqual(Screen.ViewKind.live, held.screen.view);
    try std.testing.expectEqualStrings("draft\nsecond", self.input.composition().bytes);
}

test "partial suffix catchup associates only complete collapsed Message proofs exactly once" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const line = "retained bytes\n";
    while (held.screen.live.text.length + line.len < @import("ConversationViewport.zig").capacity - 36) try held.screen.append(line);
    const size: std.posix.winsize = .{ .row = 12, .col = 60, .xpixel = 0, .ypixel = 0 };
    _ = held.screen.presented(try Screen.Test.render(held.screen, &out.writer, size, "", 0, .{}, &.{}));
    try held.screen.beginTranscript(held.screen.live.text.origin);
    self.transcript.blocks = .{};
    const block = "› " ++ View.Mark.body ++ "preview\n" ++ View.Mark.summary ++ "┄ more" ++ View.Mark.reset ++ "\n";
    try held.screen.append(block);
    try held.screen.append("a long second preview that cannot fit the remaining capacity\n" ++ block);
    for ([_]u64{ 101, 102 }) |id| self.live.blocks.append(.{ .source = .activity, .position = id, .ordinal = 0, .row = false, .content = .{ .length = id, .digest = @splat(@intCast(id)) } });
    try self.scroll(true, false);
    try std.testing.expect(held.screen.tail == .limited);
    try std.testing.expectEqual(@as(usize, 1), self.transcript.blocks.count);
    const proof = self.transcript.blocks.fromEnd(0).?;
    try std.testing.expectEqual(@as(u64, 101), proof.position);
    try std.testing.expectEqual(@as(u64, 101), proof.content.length);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(101)), &proof.content.digest);
    try self.scroll(true, false);
    try std.testing.expectEqual(@as(usize, 1), self.transcript.blocks.count);
}

test "an asynchronous older page joins only its transcript and preserves delivered content" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.tmp.dir.createFile(std.testing.io, "older", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "older A\nolder B\n", 0);
    self.files.inspection = file;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 60, .xpixel = 0, .ypixel = 0 };
    for (0..30) |_| try held.screen.append("retained\n");
    self.live.marks.record(.{ .offset = 0, .cursor = .{ .end = 9 }, .admitted = 0 });
    _ = held.screen.presented(try Screen.Test.render(held.screen, &out.writer, size, "", 0, .{}, &.{}));
    try self.beginTranscript();
    const initial = held.screen.browsing.anchor(held.screen.textLayout());
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
    };
    self.reading.phase = .history;
    self.job.transcript = self.transcript.id;
    self.job.result.history_cursor = .{ .end = 7 };
    try self.reader.start(std.testing.io, self, Worker.done);
    try self.settleReader();
    try std.testing.expectEqual(initial.offset + "older A\nolder B\n".len, held.screen.browsing.anchor(held.screen.textLayout()).offset);
    try std.testing.expectEqual(@as(?u64, 7), self.transcript.older.?.end);
    const length = held.screen.browsing.text.length;
    self.job.transcript = self.transcript.id;
    try self.reader.start(std.testing.io, self, Worker.done);
    self.transcript.id += 1; // A different snapshot now owns older results.
    try self.settleReader();
    try std.testing.expectEqual(length, held.screen.browsing.text.length);
    try std.testing.expectEqual(@as(?u64, 7), self.transcript.older.?.end);
}

test "upgrade command stays local and preserves the actual draft cursor and original submission" {
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    try Screen.Test.init(screen, std.testing.io, &env, false);
    defer Screen.Test.deinit(screen);
    var terminal: Terminal = .{ .original = undefined, .flags = undefined, .output = -1, .screen = screen };
    self.* = .{ .init = undefined, .store = "unused", .session = "k7m2qx", .directory = "unused", .files = undefined, .command = undefined, .terminal = &terminal, .colour = false };
    var stream: TerminalInput = .{};
    self.input.init(&stream);
    const original = self.input.submitText("original indeterminate model input");
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .unconfirmed, .key = @splat('K'), .retry = @splat('K') };
    _ = self.input.append("/upgrade");
    const before = self.input.composition();
    const revision = self.input.revision;
    try self.commandLine();
    try std.testing.expect(self.upgrade_requested);
    try std.testing.expectEqualStrings(before.bytes, self.input.composition().bytes);
    try std.testing.expectEqual(before.cursor, self.input.composition().cursor);
    try std.testing.expectEqual(revision, self.input.revision);
    try std.testing.expect(self.input.queuedCommand() == null);
    try std.testing.expect(self.reader.thread == null and self.submission.task.thread == null);
    try std.testing.expect(try self.quiesceUpgrade());
    try std.testing.expect(self.submission.retry == null);
    try std.testing.expectEqualStrings("original indeterminate model input", try self.input.message(original));
    try std.testing.expectEqualStrings(&@as([36]u8, @splat('K')), &self.submission.view().?.key);
    try std.testing.expectEqual(Submission.State.unconfirmed, self.submission.view().?.state);
    try std.testing.expectEqualStrings("/upgrade", self.input.composition().bytes);
}

test "upgrade outcomes retain Unicode draft cursor selection and unresolved original until safe reobservation" {
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    inline for (std.enums.values(UpgradePanel.Outcome)) |outcome| {
        for ([_]bool{ false, true }) |blocked| {
            self.* = .{ .init = undefined, .store = "unused", .session = "k7m2qx", .directory = "unused", .files = undefined, .command = undefined, .terminal = undefined, .colour = false, .upgrade_blocked = blocked };
            var stream: TerminalInput = .{};
            self.input.init(&stream);
            const original = self.input.submitText("the original request");
            self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty, .intent = .{ .message = original }, .state = .unconfirmed, .key = @splat('H') };
            for ("next é!\x1b[D") |byte| _ = self.input.feed(byte);
            const draft = self.input.composition();
            const revision = self.input.revision;
            self.inspection.selected = status_page.first;
            const selection = self.inspection.selected;
            self.applyUpgrade(outcome);
            try std.testing.expectEqualStrings("next é!", self.input.composition().bytes);
            try std.testing.expectEqual(draft.cursor, self.input.composition().cursor);
            try std.testing.expectEqual(revision, self.input.revision);
            try std.testing.expectEqual(selection, self.inspection.selected);
            try std.testing.expectEqualStrings("the original request", try self.input.message(original));
            try std.testing.expectEqualStrings(&@as([36]u8, @splat('H')), &self.submission.view().?.key);
            try std.testing.expect(self.reader.thread == null and self.submission.task.thread == null);
            try std.testing.expectEqual(outcome == .compatible, self.upgrade_reobserving);
            try std.testing.expectEqual(if (outcome == .unchanged) blocked else outcome == .incompatible, self.upgrade_blocked);
            if (outcome != .unchanged or blocked) try std.testing.expect(self.commandActive());
        }
    }
}

test "upgrade quiescing reobservation and protocol holds refuse a fresh Message without clearing its draft" {
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    try Screen.Test.init(screen, std.testing.io, &env, false);
    defer Screen.Test.deinit(screen);
    var terminal: Terminal = .{ .original = undefined, .flags = undefined, .output = -1, .screen = screen };
    for (0..3) |hold| {
        self.* = .{ .init = undefined, .store = "unused", .session = "k7m2qx", .directory = "unused", .files = undefined, .command = undefined, .terminal = &terminal, .colour = false, .reading = .{ .opening = false }, .upgrade_requested = hold == 0, .upgrade_reobserving = hold == 1, .upgrade_blocked = hold == 2 };
        var stream: TerminalInput = .{};
        self.input.init(&stream);
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .environment = .empty };
        _ = self.input.append("never send before safe reattachment");
        try self.draftEvent(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, .pasted = false } }, null);
        try std.testing.expect(self.submission.view() == null);
        try std.testing.expect(self.submission.task.thread == null);
        try std.testing.expectEqualStrings("never send before safe reattachment", self.input.composition().bytes);
    }
}

const ArchiveOverview = struct {
    state: overview_view.State,
    prompt: [overview_view.max_prompt_bytes]u8 = undefined,
    archives: usize = 0,
    stops: usize = 0,
    host_inputs: usize = 0,
    archived: ?overview_view.Reference = null,
    requested: bool = true,

    fn step(raw: *anyopaque, work: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        if (input != .other) self.host_inputs += 1;
        const effects = try overview_view.step(&self.state, .{ .conversed = .{ .reference = "k7m2qx".*, .work = work, .input = input } });
        for (effects.slice()) |effect| switch (effect) {
            .archive => |request| {
                self.archives += 1;
                self.archived = request.reference;
                self.requested = request.archived;
            },
            .stop => self.stops += 1,
            else => return error.TestUnexpectedEffect,
        };
    }

    fn line(raw: *anyopaque, work: protocol.session_work.Kind) Lender.Said {
        const self: *ArchiveOverview = @ptrCast(@alignCast(raw));
        const said = overview_view.conversation(&self.state, "k7m2qx".*, work, &self.prompt);
        return .{ .text = said.text, .asking = said.asking, .stoppable = said.stoppable };
    }

    fn lender(self: *ArchiveOverview) Lender {
        return .{ .context = self, .step = ArchiveOverview.step, .line = ArchiveOverview.line, .service = quiet_overview.service, .observed = quiet_overview.observed };
    }
};

test "Alt-A archives the open conversation without submitting or changing its draft or retained original" {
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| for ([_]bool{ false, true }) |original| for ([_][]const u8{ "\r", "\n", "\x1b[13u", "\x1b[27;1;13~" }) |confirmation| {
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
        try std.testing.expectEqual(overview_view.Prompt.Action.archive, held.self.overviewSays().asking.?);
        try std.testing.expectEqualStrings("Stop and archive k7m2qx? enter yes · esc no", held.self.overviewSays().text.?);
        try sendKeys(&held.self, "\x07");
        try std.testing.expect(held.self.overviewSays().asking == null);
        try std.testing.expect(held.self.leaving == null);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try sendKeys(&held.self, chord);
        try sendKeys(&held.self, confirmation);
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        _ = try overview_view.step(&overview.state, .{ .archive = .{ .request = .{ .reference = "k7m2qx".* }, .outcome = .{ .failed = "archive_pending" } } });
        try std.testing.expectEqualStrings("/rename unfinished", held.self.input.composition().bytes);
        try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.submission.view() == null);
        if (original) try std.testing.expectEqualStrings("retained original", try held.self.input.message(ticket.?));
    };
}

test "Alt-A confirmation precedes an offered approval and spends its offer without deciding or sending" {
    for ([_]bool{ false, true }) |draft| for ([_][]const u8{ "\r", "\n", "\x1b[13u", "\x1b[27;1;13~" }) |confirmation| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        errdefer std.debug.print("archive approval draft={} archives={} offered={} submission={} row={s}\n", .{ draft, overview.archives, held.screen.offered() != null, held.self.submission.view() != null, @tagName(held.screen.inputRow()) });
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .approval = .{ .since = 1 } };
        const file = try held.adopt(3);
        defer file.close(std.testing.io);
        try held.settle();
        if (draft) {
            try sendKeys(&held.self, "permission reason\x1b[D");
            try held.settle();
        }
        const before = held.self.input.composition();
        const revision = held.self.input.revision;
        const consent = held.screen.consent.?;
        try sendKeys(&held.self, "\x1ba\x07");
        try std.testing.expect(held.self.overviewSays().asking == null);
        try std.testing.expectEqual(consent, held.screen.consent.?);
        try sendKeys(&held.self, "\x1ba");
        try held.settle();
        if (!draft) try std.testing.expect(held.screen.offered() != null);
        const inputs = held.screen.inputs;
        try sendKeys(&held.self, confirmation);
        try std.testing.expectEqual(inputs + 1, held.screen.inputs);
        try std.testing.expect(held.screen.offered() == null);
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(consent, held.screen.consent.?);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expect(held.self.input.submitted == null);
        try std.testing.expectEqualStrings(if (draft) "permission reason" else "", held.self.input.composition().bytes);
        try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
        try sendKeys(&held.self, confirmation);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expectEqual(consent, held.screen.consent.?);
    };
}

test "Alt-A archive cannot be authorized by paste modified Enter or Ctrl-X" {
    for ([_][]const u8{ "\x1b[13;2u", "\x1b[13;3u", "\x1b[13;5u", "\x1b[200~\r\x1b[201~", "\x1b[200~\n\x1b[201~", "\x18" }) |other| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        try sendKeys(&held.self, "keep me\x1b[D\x1ba");
        try sendKeys(&held.self, other);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expect(held.self.submission.view() == null);
        try std.testing.expect(held.self.input.submitted == null);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.overviewSays().asking != .archive);
    }
}

test "Alt-A prompt replacement survives stop archive and repeated archive keys without confirming the wrong intent" {
    const Case = enum { stop_to_archive, archive_to_stop, repeat_archive };
    const Surface = enum { draft, approval_choice, approval_draft };
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| for (std.enums.values(Case)) |case| for (std.enums.values(Surface)) |surface| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        errdefer std.debug.print("prompt replacement case={s} surface={s} chord={s}\n", .{ @tagName(case), @tagName(surface), chord[1..] });
        held.self.lender = overview.lender();
        held.self.live.work.state = if (surface == .draft) .{ .working = .{ .since = 1 } } else .{ .approval = .{ .since = 1 } };
        const file: ?std.Io.File = if (surface == .draft) null else try held.adopt(3);
        defer if (file) |opened| opened.close(std.testing.io);
        if (surface != .draft) try held.settle();
        if (surface != .approval_choice) try sendKeys(&held.self, "unfinished message\x1b[D\x1b[D");
        const before = held.self.input.composition();
        const revision = held.self.input.revision;
        const consent = held.screen.consent;
        try sendKeys(&held.self, if (case == .stop_to_archive) "\x18" else chord);
        try std.testing.expectEqual(@as(?overview_view.Prompt.Action, if (case == .stop_to_archive) .stop else .archive), held.self.overviewSays().asking);
        try sendKeys(&held.self, if (case == .archive_to_stop) "\x18" else chord);
        const replacement: overview_view.Prompt.Action = if (case == .archive_to_stop) .stop else .archive;
        try std.testing.expectEqual(@as(?overview_view.Prompt.Action, replacement), held.self.overviewSays().asking);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
        try sendKeys(&held.self, if (case == .archive_to_stop) "\x18" else "\r");
        try std.testing.expectEqual(@as(usize, if (case == .archive_to_stop) 0 else 1), overview.archives);
        try std.testing.expectEqual(@as(usize, if (case == .archive_to_stop) 1 else 0), overview.stops);
        try std.testing.expect(held.self.overviewSays().asking == null);
        try std.testing.expectEqualStrings(if (surface == .approval_choice) "" else "unfinished message", held.self.input.composition().bytes);
        try std.testing.expectEqual(before.cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
        try std.testing.expectEqual(consent, held.screen.consent);
        try std.testing.expect(held.self.input.submitted == null);
        try std.testing.expect(held.self.input.queuedCommand() == null);
        try std.testing.expect(held.self.submission.view() == null);
    };
}

test "Alt-A and Ctrl-X during opening still cancel an old prompt without forwarding an intent" {
    for ([_][]const u8{ "\x1ba", "\x18" }) |chord| for (std.enums.values(overview_view.Prompt.Action)) |prompt| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        try sendKeys(&held.self, "keep draft\x1b[D");
        const revision = held.self.input.revision;
        const cursor = held.self.input.composition().cursor;
        overview.state.prompt = .{ .stop = "k7m2qx".*, .action = prompt };
        held.self.reading.opening = true;
        try sendKeys(&held.self, chord);
        try std.testing.expect(held.self.overviewSays().asking == null);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
        try std.testing.expectEqualStrings("keep draft", held.self.input.composition().bytes);
        try std.testing.expectEqual(cursor, held.self.input.composition().cursor);
        try std.testing.expectEqual(revision, held.self.input.revision);
    };
}

const UnusedArchiveCommand = struct {
    var calls: usize = 0;

    fn command(_: std.process.Init, _: client.Requests, _: []const u8, _: []const u8, _: []u8) !void {
        calls += 1;
        return error.TestUnexpectedCommand;
    }
};

test "conversation slash archive shares busy confirmation and consumes only its submitted command without approving" {
    for ([_]bool{ false, true }) |approval| for ([_][]const u8{ "\r", "\n" }) |confirmation| for ([_]bool{ false, true }) |completion| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.command = UnusedArchiveCommand.command;
        UnusedArchiveCommand.calls = 0;
        held.self.live.work.state = if (approval) .{ .approval = .{ .since = 1 } } else .{ .working = .{ .since = 1 } };
        const file: ?std.Io.File = if (approval) try held.adopt(3) else null;
        defer if (file) |opened| opened.close(std.testing.io);
        if (approval) try held.settle();
        const original = held.self.input.submitText("retained original");
        for (0..2) |attempt| {
            errdefer std.debug.print("slash archive approval={} completion={} attempt={d} enter={any} draft={s} notice={s}\n", .{ approval, completion, attempt, confirmation, held.self.input.composition().bytes, held.self.notice orelse "" });
            try sendKeys(&held.self, if (completion) "/arch" else "/archive");
            if (completion) try held.settle();
            const consent = held.screen.consent;
            try sendKeys(&held.self, confirmation);
            try std.testing.expectEqual(@as(?overview_view.Prompt.Action, .archive), held.self.overviewSays().asking);
            try std.testing.expectEqual(@as(usize, 0), overview.archives);
            try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
            try std.testing.expect(held.self.input.queuedCommand() == null);
            try std.testing.expectEqual(consent, held.screen.consent);
            const inputs = held.screen.inputs;
            try sendKeys(&held.self, if (attempt == 0) "\x07" else confirmation);
            try std.testing.expectEqual(inputs + 1, held.screen.inputs);
            try std.testing.expectEqual(@as(usize, attempt), overview.archives);
            try std.testing.expect(held.self.overviewSays().asking == null);
            try std.testing.expectEqual(consent, held.screen.consent);
            try std.testing.expect(held.screen.offered() == null);
        }
        try std.testing.expectEqual(@as(usize, 0), UnusedArchiveCommand.calls);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        try std.testing.expect(overview.requested);
        try std.testing.expectEqual(protocol.SessionArchiveState.active, held.self.line.archive_state);
        try std.testing.expectEqualStrings("retained original", try held.self.input.message(original));
        try std.testing.expect(held.self.submission.view() == null);
    };
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
        try sendKeys(&held.self, if (restore) "/unarchive\n" else "/archive\n");
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(!restore, overview.requested);
        try std.testing.expectEqualStrings("k7m2qx", &overview.archived.?);
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        if (unknown) _ = try overview_view.step(&overview.state, .{ .archive = .{ .request = .{ .reference = "k7m2qx".*, .archived = !restore }, .outcome = .{ .unconfirmed = "saved-archive-handle" } } });
        try sendKeys(&held.self, if (restore) "/archive\n" else "/unarchive\n");
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

test "conversation stop prompt is cancelled before submitting slash archive creates its own confirmation" {
    for ([_][]const u8{ "\r", "\n" }) |confirmation| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.live.work.state = .{ .working = .{ .since = 1 } };
        try sendKeys(&held.self, "/archive\x18");
        try std.testing.expectEqual(@as(?overview_view.Prompt.Action, .stop), held.self.overviewSays().asking);
        try sendKeys(&held.self, confirmation);
        try std.testing.expectEqual(@as(?overview_view.Prompt.Action, .archive), held.self.overviewSays().asking);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
        try std.testing.expectEqualStrings("", held.self.input.composition().bytes);
        try sendKeys(&held.self, confirmation);
        try std.testing.expectEqual(@as(usize, 1), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
    }
}

test "conversation slash archive errors propagate and consume only the submitted line" {
    const Failed = struct {
        fn step(_: *anyopaque, _: protocol.session_work.Kind, input: overview_view.ConversationInput) !void {
            if (input == .archive or input == .unarchive) return error.TestArchiveDispatchFailed;
        }
    };
    for ([_][]const u8{ "/archive\n", "/unarchive\n" }) |command| {
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

test "typed Staged live ingestion preserves message cuts raw controls and above 4GiB coordinates" {
    const held = try HeldFrontend.create();
    defer held.destroy();
    const self = &held.self;
    const file = try held.tmp.dir.createFile(std.testing.io, "typed-output", .{ .read = true });
    defer file.close(std.testing.io);
    self.files.inspection = file;
    const raw = "h|x\n---|---\na|\x1b[31m\xff\nlast|row";
    for ([_]u64{ 0, 1 << 34 }) |base| {
        try file.setLength(std.testing.io, 0);
        try file.writePositionalAll(std.testing.io, raw, base);
        held.screen.live.text.clear();
        self.job.result.output_blocks.clear();
        try std.testing.expect(self.job.result.output_blocks.reserve(.{ .start = base, .end = base + raw.len, .header_end = base + 4, .delimiter_end = base + 12, .complete_end = base + raw.len, .data = .{ .table = .{ .count = 2, .alignment = @splat(.left) } } }));
        var staged: Staged = .{ .frontend = self, .length = base + raw.len, .written = base, .start = 0, .cursor = .{ .marks = &self.job.result.output_blocks } };
        // These are the real normalized endpoints used by Message cuts, not
        // raw display-file offsets. No cut itself grants syntax/EOF authority.
        const cuts = [_]u64{ base + 2, base + 8, base + 12, base + raw.len - 1, base + raw.len };
        var previous: u64 = 0;
        for (cuts) |cut| {
            const end = try staged.to(cut);
            try std.testing.expect(end >= previous);
            previous = end;
        }
        const text = held.screen.live.text.text();
        // At offset zero an existing compact group needs its normal separator.
        const separator: usize = @intFromBool(base == 0);
        try std.testing.expectEqualStrings(raw, text[separator..]);
        const mark = held.screen.live.text.blocks.items[0];
        try std.testing.expectEqual(@as(u32, @intCast(separator)), mark.start);
        try std.testing.expectEqual(mark.end, mark.complete_end);
        try std.testing.expectEqual(@as(u6, 1), held.screen.live.text.blocks.count);
    }
}

test "upgrade holds classify every lender intent before forwarding and allow local cancellation" {
    const inputs: []const overview_view.ConversationInput = &.{ .stop, .{ .archive = .active }, .unarchive, .confirm_archive };
    for (0..3) |hold| for (inputs) |input| {
        const held = try HeldFrontend.create();
        defer held.destroy();
        var overview: ArchiveOverview = .{ .state = undefined };
        try overview.state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer overview.state.deinit();
        held.self.lender = overview.lender();
        held.self.upgrade_requested = hold == 0;
        held.self.upgrade_blocked = hold == 1;
        held.self.upgrade_reobserving = hold == 2;
        overview.state.prompt = .{ .stop = "k7m2qx".*, .action = .archive };
        try held.self.converse(input);
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
        try std.testing.expectEqualStrings(upgrade_recovery, held.self.notice.?);
        try held.self.converse(.other);
        try std.testing.expect(overview.state.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), overview.archives);
        try std.testing.expectEqual(@as(usize, 0), overview.stops);
    };
}

test "upgrade holds refuse archive shortcuts confirmations and slash commands without consuming custody" {
    const Path = enum { alt_a, kitty_alt_a, legacy_alt_a, confirm, kitty_confirm, slash_archive, slash_unarchive };
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
        held.self.upgrade_requested = hold == 0;
        held.self.upgrade_blocked = hold == 1;
        held.self.upgrade_reobserving = hold == 2;
        if (path == .confirm or path == .kitty_confirm) overview.state.prompt = .{ .stop = "k7m2qx".*, .action = .archive };
        try sendKeys(&held.self, switch (path) {
            .alt_a => "\x1ba",
            .kitty_alt_a => "\x1b[97;3u",
            .legacy_alt_a => "\x1b[27;3;97~",
            .kitty_confirm => "\x1b[13u",
            .confirm, .slash_archive, .slash_unarchive => "\r",
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
        held.self.upgrade_reobserving = true;
        try sendKeys(&held.self, "\r");
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, line, "/arch")) "/archive" else "/unarchive", held.self.input.composition().bytes);
        try std.testing.expectEqual(@as(usize, 0), overview.host_inputs);
        try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
    }
}
