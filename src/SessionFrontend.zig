//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const vaxis = @import("vaxis");
const client = @import("client.zig");
const Input = @import("SessionInput.zig");
const TerminalInput = @import("TerminalInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const Terminal = @import("SessionTerminal.zig");
const Screen = @import("SessionScreen.zig");
const Frame = @import("TerminalFrame.zig");
const Editor = @import("TerminalEditor.zig");
const View = @import("session_view.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const ChoiceLine = @import("ChoiceLine.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const Self = @This();

const reads = @import("session_reads.zig");
pub const Command = reads.Command;
pub const Requests = reads.Requests;
pub const Status = reads.Status;
const Job = reads.Job;
pub const Files = struct { scratch: std.Io.File, action: std.Io.File, inspection: std.Io.File, status: std.Io.File };
const Inspection = reads.Inspection;
const ReadPhase = departure.ReadPhase;
const ReadEnd = departure.ReadEnd;
const AdmissionEnd = Submission.End;
const Settled = departure.Settled;
init: std.process.Init,
store: []const u8,
session: []const u8,
directory: []const u8,
scratch: std.Io.File,
action_file: std.Io.File = undefined,
inspection_file: std.Io.File = undefined,
status_file: std.Io.File = undefined,
command: Command,
requests: Requests = undefined,
status: Status = undefined,
inspection_kind: Inspection = .status,
// /status was asked for; the next settled scan shows it.
status_requested: bool = false,
// The shown inspection page is /status. Each settled scan replaces it when
// anything it reports changed, with the history and composer status of the
// same capture, so it never reports finished work as running.
status_page: bool = false,
status_digest: u64 = 0,
// The newest accepted Message admission not yet in delivered output.
// Admission order is Session order, so it stands for every earlier one.
echo: ?u64 = null,
// The newest Message admission live pages have delivered.
delivered: u64 = 0,
// Consecutive reads whose work changed while their page was read.
unsettled: u8 = 0,
// An inspection or Host command started and its result has not been
// presented. A command may change configuration, so Messages and consent wait
// for every inspection; exit prints an unshown command's output, which can
// carry recovery warnings.
command_running: bool = false,
terminal: Terminal,
colour: bool,
/// Inside tmux, Shift-Enter reaches Rui as Enter; composing says so.
tmux: bool = false,
/// Messages begun; a /details read begun before the latest one never covers it.
sent: u64 = 0,
details_sent: u64 = 0,
input: Input = undefined,
submission: Submission = undefined,
reader: Task = .{},
// The reader's only context; the UI reads its result after join.
job: Job = .{},
current: client.Current = undefined,
live: View.Live = .{},
cursor: client.ActivityCursor = .{},
// UI commits layout alongside delivered Activity; workers borrow a snapshot.
compact_tools: bool = false,
// Continues the transcript above its oldest shown row; null at the start.
transcript_older: ?client.ConversationCursor = null,
// What the transcript shows above its copy before older pages (see
// reads.Plan); its echoes are listed newest first, so `count` falls.
transcript_plan: reads.Plan = .{ .start = 0 },
// Older pages reach the conversation's start, so the transcript says so.
transcript_beginning: bool = false,
// The Messages live output shows since its newest mark.
echoes: reads.Record = .{},
// The lowest position of a Message seen unapplied, where a transcript's
// search for them may stop; a stale value only costs reads.
lowest: ?u64 = null,
// Each transcript gets a new identity, so a page loaded for one is never
// joined to another.
transcript: u64 = 0,
// A failed older load waits for the next scroll rather than retrying at once.
older_failed: bool = false,
history_requested: ?History = null,
// The Messages of collapsed blocks in live output and in the transcript.
live_blocks: View.Blocks = .{},
transcript_blocks: View.Blocks = .{},
// Ctrl-O waits for the frame it names a block in; the read then waits for
// the reader, and its page shows only over the view it was asked from.
expand_pending: bool = false,
// A Message page asked for, and the one being read. Each holds where it was
// asked from; Esc, Ctrl-G, a send or a newer Ctrl-O supersedes it.
message_requested: ?MessageRequest = null,
message_reading: ?MessageRequest = null,
message_generation: u64 = 0,
// Where each read's live output began, so a transcript whose live copy lost
// its front still continues from a canonical position without a gap.
marks: reads.Marks = .{},
// Messages shown live so far, which decide where a later read may mark.
messages: reads.Messages = .{},
read_phase: ReadPhase = .activity,
prepared_action: ?u64 = null,
prepared_summary: View.ActionSummary = .{},
action_summary: View.ActionSummary = .{},
reader_output_started: bool = false,
opening: bool = true,
poll_at: i96 = 0,
// A frontend-owned change the next frame must show: input, notices, status,
// live text or scrolling. The Screen's own changes make it stale() instead.
dirty: bool = true,
detached: bool = false,
notice: ?[]const u8 = null,
// One joined read at a time; no reuse until its live diagnostic is delivered.
pending_diagnostic: ?struct { failure: client.ReadFailure, phase: ReadPhase, recoverable: bool } = null,
notice_buffer: [1536]u8 = undefined,
previous_signals: [2]std.posix.Sigaction = undefined,

fn freeze(self: *const Self, phase: ReadPhase) Job {
    var job: Job = .{ .init = self.init, .store = self.store, .session = self.session, .scratch = self.scratch, .action_file = self.action_file, .inspection_file = self.inspection_file, .status_file = self.status_file, .colour = self.colour, .command = self.command, .requests = self.requests, .status = self.status, .phase = phase, .cursor = self.cursor, .opening = self.opening, .older = self.transcript_older, .listing = if (phase == .history) self.transcript_plan.next() else null, .messages = self.messages, .transcript = self.transcript, .inspection_kind = self.inspection_kind, .interrupted = &interrupted, .force = self.unsettled >= 3 };
    if (phase == .activity or phase == .permission) {
        job.open_status = self.status_requested;
        job.watch_status = self.status_page and self.terminal.screen.view == .inspection;
        job.status_shown = self.status_digest;
        // The page reports the submission the UI shows with it.
        if (job.open_status or job.watch_status) job.inspection_submission = self.submission.view();
    }
    job.result.compact_tools = self.compact_tools;
    return job;
}

fn launch(self: *Self, job: Job, worker: Task.Run) !void {
    std.debug.assert(self.reader.thread == null);
    self.job = job;
    self.read_phase = job.phase;
    self.reader_output_started = false;
    try self.reader.start(self.init.io, &self.job, worker);
}

var interrupted: client.Cancellation = .{};
fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.requestStop();
}

fn signals(self: *Self, install: bool) void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    inline for (.{ std.posix.SIG.INT, std.posix.SIG.TERM }, 0..) |signal, i| {
        if (install) std.posix.sigaction(signal, &action, &self.previous_signals[i]) else std.posix.sigaction(signal, &self.previous_signals[i], null);
    }
}

pub fn run(init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, requests: Requests, status: Status, initial_text: ?[]const u8) !void {
    const no_colour: []const u8 = init.environ_map.get("NO_COLOR") orelse "";
    const colour = no_colour.len == 0;
    const screen = try init.gpa.create(Screen);
    defer init.gpa.destroy(screen);
    try screen.init(init.io, init.environ_map, colour);
    defer screen.deinit();
    var self: Self = .{ .init = init, .store = store, .session = session, .directory = directory, .scratch = files.scratch, .action_file = files.action, .inspection_file = files.inspection, .status_file = files.status, .command = command, .requests = requests, .status = status, .terminal = undefined, .colour = colour, .tmux = init.environ_map.get("TMUX") != null };
    self.input.init();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input };
    interrupted.stopped.store(false, .release);
    self.signals(true);
    defer self.signals(false);
    self.terminal = try Terminal.begin(screen);
    self.terminal.pump = .{ .context = &self, .step = pump };
    const result = self.drive(initial_text);
    const settled = self.quiesce();
    self.submission.close();
    if (self.pending_diagnostic != null) {
        var bytes: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        self.writePendingDiagnostic(&out) catch unreachable;
        TerminalText.diagnostic("rui: Read failed: {s}\n", .{out.buffered()});
    }
    const cause: ?anyerror = if (result) |_| null else |err| err;
    const plan = departure.exit(settled, cause, self.submission.view() != null);
    if (plan.recovery_before_notice) self.recoveryGuide();
    if (self.command_running and self.inspection_kind == .command) self.commandOutputGuide();
    if (plan.failure) |err| {
        switch (err) {
            error.TerminalTooSmall => TerminalText.diagnostic("rui: Enlarge the terminal and resume this Session. Required instructions do not fit; nothing was authorized by the clipped view.\n", .{}),
            error.TerminalTooLarge => TerminalText.diagnostic("rui: Rui supports at most 49,152 terminal cells (for example 256 × 192). Shrink the terminal and resume; saved content is unchanged.\n", .{}),
            error.OutOfMemory, error.UnrepresentableTerminalGrapheme, error.DisplayGraphemeTooLarge => TerminalText.diagnostic("rui: This frame exceeds Rui's bounded display. Shrink the terminal and resume; saved content is unchanged. One-shot session, request and action commands remain available.\n", .{}),
            else => {},
        }
        if (screen.action_view != null) {
            if (settled.restored) |_| {
                self.terminal.detached(store, session, self.current.first_action) catch |notice_error|
                    TerminalText.diagnostic("rui: Action recovery notice failed: {s}\n", .{@errorName(notice_error)});
            } else |_| {} // Never write a main-screen notice before confirmed restoration.
        }
        return err;
    }
    const action = if (screen.action_view != null) self.current.first_action else null;
    self.terminal.detached(store, session, action) catch |err| {
        if (!plan.recovery_before_notice) self.recoveryGuide();
        return err;
    };
}

fn quiesce(self: *Self) Settled {
    // A running command observes exit as an interruption, exactly as a signal.
    if (self.command_running) interrupted.requestStop();
    const restored = self.terminal.finish();
    self.reader.cancel();
    self.submission.cancel();
    const reader = self.joinReader();
    const admission = self.joinAdmission();
    return .{ .restored = restored, .reader = reader, .admission_error = admission.failure() };
}

/// Exit interrupted a Host command before its output was shown. That output
/// can name a saved request to recover, so it follows restoration on stderr.
fn commandOutputGuide(self: *const Self) void {
    const io = self.init.io;
    const size = (self.inspection_file.stat(io) catch return).size;
    if (size == 0) return;
    // Optional like every exit diagnostic: a full or stopped stderr drops the
    // rest instead of holding the restored caller.
    if (!stderr.tryAcquire()) return;
    defer stderr.release();
    if (!stderr.writeHeld("rui: Interrupted command output:\n")) return;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = self.inspection_file.readPositionalAll(io, &buffer, offset) catch return;
        if (count == 0 or !stderr.writeHeld(buffer[0..count])) return;
        offset += count;
    }
}

fn recoveryGuide(self: *const Self) void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    self.writeRecoveryGuide(&out) catch unreachable;
    if (out.buffered().len != 0) TerminalText.diagnostic("{s}", .{out.buffered()});
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
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false };
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

fn drive(self: *Self, initial_text: ?[]const u8) !void {
    if (initial_text) |text| try self.beginMessage(self.input.submitText(text));
    try self.driveActive();
}

const History = enum { older, latest };

/// Every slash command the draft or the choice accepts.
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
    self.history_requested = history;
    self.status_requested = false;
}

/// Runs one slash command its source admitted from the draft or the choice,
/// which never decides. Local commands answer at once; an inspection
/// queues for the reader.
fn slashCommand(self: *Self, text: []const u8) void {
    switch (parse(text)) {
        .exit => self.detached = true,
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

/// The choice ends its line at Enter, so a command it cannot run is lost.
/// Exit and page requests always run; others wait for any active command
/// rather than queueing behind it or replacing its page.
fn choiceCommand(self: *Self, text: []const u8) void {
    switch (parse(text)) {
        .exit, .history => {},
        else => if (self.command_running) {
            self.notice = "! Command still running. Try again when it finishes.";
            return;
        } else if (self.input.queuedCommand() != null) {
            self.notice = "! Preparing inspection; try again when it finishes.";
            return;
        },
    }
    self.slashCommand(text);
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
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false };
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
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false };
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
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = .{ .original = undefined, .flags = undefined, .screen = undefined, .active = false, .result = error.TerminalRestoreFailed }, .colour = false, .read_phase = phase };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .intent = .{ .message = self.input.submitText("current original B") } };
        try self.reader.start(std.testing.io, &self, Worker.read);
        try self.submission.task.start(std.testing.io, &self, Worker.admit);
        const settled = self.quiesce();
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(.inspection, error.InteractiveInterrupted).?);
        try std.testing.expectEqual(error.CanonicalStoreFailure, settled.admission_error.?);
        try std.testing.expect(settled.reader == .cancelled);
        try std.testing.expect(self.reader.thread == null and self.submission.task.thread == null);
        // A second cleanup cannot reconstruct or consume the errors again.
        const repeated = self.quiesce();
        try std.testing.expect(repeated.reader == .absent and repeated.admission_error == null);
    }
}

fn driveActive(self: *Self) !void {
    while (!self.detached) {
        if (interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
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
            self.status_requested = true;
            self.poll_at = 0;
        };
        if (self.input.queuedCommand() != null and self.reader.thread != null and !self.reader.completed()) {
            // No read shows anything before it joins, so an inspection
            // supersedes it. Keep servicing input until completion; never join
            // unfinished work in raw mode.
            self.reader.cancel();
        }
        // A joined read may hide or withdraw the Action, so a sequence the
        // choice is decoding finishes there first and none reaches the draft.
        if (self.reader.thread != null and self.reader.completed() and !(self.terminal.screen.selected.editor == .choice and self.input.pending() != .none)) {
            try self.settleReader();
            self.withdrawDecided();
        }
        if (self.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(&self.terminal);
        }
        if (self.reader.thread == null) if (self.input.takeCommand()) |text| {
            const kind = parse(text).inspection;
            // Input goes to the editor the latest frame shows; this stales
            // it, so the view returned to is drawn while the inspection runs.
            try self.terminal.screen.latest();
            self.inspection_kind = kind;
            // The worker borrows its own copy; the editor may queue another.
            var job = self.freeze(.inspection);
            @memcpy(job.command_text[0..text.len], text);
            job.command_text_length = text.len;
            job.inspection_submission = self.submission.view();
            const consent = self.terminal.screen.consent;
            job.inspection_action = if (consent.presentation == .preview) consent.action else null;
            // The newer inspection replaces a /status not yet shown.
            self.status_requested = false;
            try self.launch(job, if (kind == .command) reads.runCommand else reads.inspectPage);
            self.command_running = true;
        };
        // Scans continue during consent, so an Action decided elsewhere leaves.
        if (self.reader.thread == null and self.prepared_action == null) {
            if (self.history_requested != null and !self.opening) {
                const requested = self.history_requested.?;
                self.history_requested = null;
                if (requested == .latest) {
                    try self.terminal.screen.latest();
                    self.details_sent = self.sent;
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
            if (self.reader.thread == null) if (self.message_requested) |request| {
                self.message_requested = null;
                self.message_reading = request;
                var job = self.freeze(.message);
                job.message_target = request.target;
                try self.launch(job, reads.fullMessage);
            };
            if (self.reader.thread != null) {} else if (self.olderWanted()) {
                self.notice = "Loading earlier messages…";
                try self.launch(self.freeze(.history), reads.history);
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                try self.launch(self.freeze(.activity), reads.scan);
            } else if (!self.terminal.screen.consent.active() and !self.terminal.screen.choice_line.open and !self.opening and self.submission.view() == null and self.current.first_action != null and self.input.pending() == .none) {
                // A line begun at an earlier choice ends before the next
                // Action is presented, so it never decides that one.
                try self.launch(self.freeze(.permission), reads.permission);
            }
        }
        // Input routes by the latest frame's editor. Once a transition revokes
        // that frame, draw its replacement before reading further input.
        for (0..1024) |_| {
            if (try self.step(0) != .byte) break;
            if (self.detached or self.terminal.screen.stale()) break;
        }
        if (self.detached) break;
        // Finish chat paste/UTF-8 under its original decoder before consent.
        if (self.reader.thread == null and self.prepared_action != null and self.input.pending() == .none) {
            // Preparation is complete and the file remains immutable through
            // this choice. A bounded preview is export-only, never consent.
            try self.terminal.screen.adopt(self.init.io, self.action_file, self.prepared_action.?);
            self.action_summary = self.prepared_summary;
            self.prepared_action = null;
            self.read_phase = .activity;
        }
        self.withdrawDecided();
        if (self.dirty or self.terminal.screen.stale()) if (try self.draw()) break;
        if (self.expand_pending) try self.expand();
        _ = try self.step(16);
    }
}

/// Draws the selected projection, applies its receipt and, after a delivered
/// decision prompt, services input for the empty-input freshness gate.
/// Returns true when that service detached the caller.
fn draw(self: *Self) !bool {
    const screen = self.terminal.screen;
    try self.drawFrame();
    if (!self.dirty and screen.decisionPromptDelivered() and !screen.consent.acceptsInput() and self.input.pending() == .none) {
        // Every prompt byte was accepted by stdout. Discard input through
        // its decoder, not tcflush: a paste prefix or Ctrl-C arriving
        // during the final write must retain its meaning.
        var service: ConsentPolicy.Service = .budget_exhausted;
        for (0..1024) |_| {
            service = try self.step(0);
            if (service != .byte) break;
            service = .budget_exhausted;
            if (self.detached) break;
        }
        if (interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
        if (self.detached) return true;
        if (self.consentReceipt(service)) try Editor.testChoiceReady(self.init.io);
    }
    return false;
}

/// The post-write consent observation: input serviced after a delivered
/// decision prompt opens freshness only when nothing arrived or remains.
fn consentReceipt(self: *Self, service: ConsentPolicy.Service) bool {
    return self.terminal.screen.promptCompleted(service, self.input.pending() != .none, self.commandActive() or self.dirty);
}

/// Writes one frame of the selected projection and applies its receipt.
fn drawFrame(self: *Self) !void {
    const screen = self.terminal.screen;
    const projection = screen.select(self.commandActive());
    const choosing = projection.editor == .choice;
    const view: Input.View = if (choosing) .{ .bytes = screen.choiceText(), .cursor = screen.choice.cursor } else self.input.composition();
    const base_status = if (self.opening) "Opening…" else switch (projection.approval) {
        .preview => "Approval disabled · /help for exact shell commands",
        .paused => "Approval paused · Esc returns to Action",
        .reading => "PgDn reads the rest · then a/d + Enter",
        .held => "Command running · then a/d + Enter",
        .draining, .ready => Frame.approval_choice,
        .absent => if (self.submission.view()) |submission| switch (submission.state) {
            .not_started => "Not sent · Ctrl-R retries original",
            .submitting => "Sending…",
            .unconfirmed => if (submission.kind == .decision) "! Decision not confirmed · Ctrl-R retries original" else "! Not confirmed · Ctrl-R retries original",
            .rejected => "Rejected · /discard",
        } else if (self.echo != null) "Sent" else workStatus(self.current.work.status.value),
    };
    var context_buffer: [4 * std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var context = std.Io.Writer.fixed(&context_buffer);
    if (choosing and screen.actionVisible())
        try approvalContext(&context, screen.actionTopHidden(), self.action_summary)
    else if (self.tmux and projection.approval == .absent and view.bytes.len != 0)
        try context.writeAll("In tmux, Shift-Enter sends · Alt-J adds a line");
    var status_buffer: [Frame.status_capacity]u8 = undefined;
    const status = statusLines(&status_buffer, self.notice orelse "", context.buffered(), base_status);
    self.dirty = false;
    // Reading completes only after delivery; the receipt stales the frame.
    _ = screen.presented(try self.terminal.redraw(view.bytes, view.cursor, status, &self.live));
}

// Every notice and instruction line fits beside a shortened context line.
comptime {
    std.debug.assert(@typeInfo(@FieldType(Self, "notice_buffer")).array.len + 256 + "\n\n…".len <= Frame.status_capacity);
}

/// The notice and instructions always fit; a long context line is shortened,
/// on a UTF-8 boundary, rather than pushing them out of the status region.
/// Bypass is the default and stays quiet: /status shows Permission.
fn statusLines(buffer: *[Frame.status_capacity]u8, notice: []const u8, context: []const u8, base: []const u8) []const u8 {
    std.debug.assert(base.len <= 256);
    var status = std.Io.Writer.fixed(buffer);
    const room = buffer.len - notice.len - base.len - "\n\n…".len;
    var context_line = context;
    if (context_line.len > room) {
        var end = room;
        while (end > 0 and (context_line[end] & 0xc0) == 0x80) end -= 1;
        context_line = context_line[0..end];
    }
    for ([_][]const u8{ notice, context_line, base }, 0..) |line, index| {
        if (line.len == 0) continue;
        if (status.buffered().len != 0) status.writeAll("\n") catch unreachable;
        status.writeAll(line) catch unreachable;
        if (index == 1 and line.len < context.len) status.writeAll("…") catch unreachable;
    }
    return status.buffered();
}

test "status lines keep the notice and instructions beside an oversized context" {
    var buffer: [Frame.status_capacity]u8 = undefined;
    const notice: [1536]u8 = @splat('n');
    // A context whose cut falls inside a two-byte scalar.
    var context: [4000]u8 = undefined;
    for (0..context.len / 2) |index| context[index * 2 ..][0..2].* = "é".*;
    const lines = statusLines(&buffer, &notice, &context, "Type a + Enter");
    try std.testing.expect(std.mem.startsWith(u8, lines, &notice));
    try std.testing.expect(std.mem.endsWith(u8, lines, "…\nType a + Enter"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(lines));
    try std.testing.expectEqualStrings("Sent", statusLines(&buffer, "", "", "Sent"));
    try std.testing.expectEqualStrings("! x\nWorkspace: /w\nSent", statusLines(&buffer, "! x", "Workspace: /w", "Sent"));
}

/// Another client decided, or the Turn ended: the choice can no longer decide.
/// It leaves before more input is read, so no key decides; a fragmented
/// sequence finishes under the choice decoder first, and a line begun there
/// ends there, so none of either reaches the draft.
fn withdrawDecided(self: *Self) void {
    const consent = self.terminal.screen.consent;
    if (!consent.active() or self.current.first_action == consent.action or self.input.pending() != .none) return;
    self.terminal.screen.withdrawAction();
}

/// The choice keeps the Action's heading lines beside it once paging hides
/// them; they leave again when the heading is back on screen.
fn approvalContext(out: *std.Io.Writer, top_hidden: bool, summary: View.ActionSummary) !void {
    if (!top_hidden) return;
    try out.writeAll("Run Bash");
    if (summary.description.slice().len != 0) {
        try out.writeAll(" · ");
        var label: TerminalText = .{ .mode = .line };
        try label.feed(out, summary.description.slice());
        try label.finish(out);
    }
    try out.writeAll("\nWorkspace: ");
    var location: TerminalText = .{ .mode = .line };
    try location.feed(out, summary.workspace.slice());
    try location.finish(out);
    if (summary.timeout_ms) |timeout| try out.print(" · Time limit: {d} ms", .{timeout}) else try out.writeAll(" · Time limit: Host default");
}

test "a paged Action keeps what runs, where and for how long beside the choice" {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var summary: View.ActionSummary = .{ .timeout_ms = 5000 };
    try summary.workspace.set("/work");
    try approvalContext(&out, false, summary);
    try std.testing.expectEqualStrings("", out.buffered());
    try summary.description.set("Record\x1b[2J steps");
    try summary.workspace.set("/work/a\x1bb");
    try approvalContext(&out, true, summary);
    try std.testing.expectEqualStrings("Run Bash · Record\\x1b[2J steps\nWorkspace: /work/a\\x1bb · Time limit: 5000 ms", out.buffered());
    out = std.Io.Writer.fixed(&buffer);
    summary = .{};
    try summary.workspace.set("/work");
    try approvalContext(&out, true, summary);
    try std.testing.expectEqualStrings("Run Bash\nWorkspace: /work · Time limit: Host default", out.buffered());
}

const WorkStatus = @FieldType(@FieldType(client.Current.Work, "status"), "value");

fn workStatus(status: WorkStatus) []const u8 {
    return switch (status) {
        .runnable, .in_flight => "Working…",
        .waiting_for_permission => "Needs approval",
        .idle, .completed, .failed, .cancelled => "",
    };
}

test "the composer status shows only live work, not an ending the transcript already shows" {
    // The ended Turn's line sits directly above the composer; a second
    // copy pointing at /status would add nothing /status does not repeat.
    for ([_]WorkStatus{ .failed, .cancelled, .idle, .completed }) |ended|
        try std.testing.expectEqualStrings("", workStatus(ended));
    try std.testing.expectEqualStrings("Working…", workStatus(.in_flight));
    try std.testing.expectEqualStrings("Needs approval", workStatus(.waiting_for_permission));
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = try self.step(16);
    if (self.detached or interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
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
    self.sent += 1;
    self.status_requested = false;
    self.history_requested = null;
    self.dropMessageRequest();
    try self.terminal.screen.latest();
}

/// A queued or running command ends consent freshness until it completes.
fn commandActive(self: *const Self) bool {
    return self.input.queuedCommand() != null or self.command_running;
}

/// The choice shows decision instructions: its rows were all delivered and no
/// command holds it. Freshness and Enter are probed separately.
fn decisionShown(self: *const Self) bool {
    const approval = self.terminal.screen.selected.approval;
    return approval == .draining or approval == .ready;
}

fn navigation(self: *Self, event: Editor.Event) !void {
    const screen = self.terminal.screen;
    switch (event) {
        .page_up, .page_down, .scroll_up, .scroll_down => {
            const down = event == .page_down or event == .scroll_down;
            if (screen.view == .live) {
                if (down) return; // Live output already shows the latest rows.
                try self.beginTranscript();
            }
            self.older_failed = false; // A new scroll may retry a failed load.
            if (screen.browse(down, event == .page_up or event == .page_down)) try screen.latest();
        },
        .latest, .close_view => {
            // Leaving also abandons a Message page not yet shown.
            self.dropMessageRequest();
            if (event == .close_view and screen.view == .message) try screen.leaveMessage() else try screen.latest();
        },
        .expand => if (screen.view == .message) try screen.leaveMessage() else {
            // A newer Ctrl-O replaces any page asked for before it, even
            // before its own target is found, or if none is.
            self.dropMessageRequest();
            self.expand_pending = true;
        },
        // Every other event reaches here unhandled, and must not redraw.
        else => return,
    }
    self.dirty = true;
}

const MessageRequest = struct { target: View.Collapsed, view: Screen.ViewKind, transcript: u64, sent: u64, generation: u64 };

/// No Message page asked for so far opens.
fn dropMessageRequest(self: *Self) void {
    self.message_generation += 1;
    self.message_requested = null;
    self.expand_pending = false;
}

/// Ctrl-O: opens the lowest collapsed Message the latest frame drew.
fn expand(self: *Self) !void {
    self.expand_pending = false;
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
    const blocks = if (screen.view == .live) &self.live_blocks else &self.transcript_blocks;
    const target = blocks.fromEnd(index) orelse {
        self.notice = "! That message's full text is no longer held here; /history shows it again.";
        return;
    };
    self.message_requested = .{ .target = target, .view = screen.view, .transcript = self.transcript, .sent = self.sent, .generation = self.message_generation };
    self.notice = "Opening message…";
}

/// Freezes live output for scrolling. The copy starts at a recorded read
/// boundary, so older canonical pages continue it without a gap. With none
/// retained, the gap's shown Messages and those at its seam are listed above
/// the copy, and older pages continue before the newest boundary that left.
fn beginTranscript(self: *Self) !void {
    const screen = self.terminal.screen;
    self.transcript += 1;
    const front = try screen.liveStart();
    self.transcript_plan = reads.plan(&self.marks, &self.echoes, front, self.lowest);
    try screen.beginTranscript(self.transcript_plan.start);
    self.transcript_blocks = self.live_blocks.newest(screen.transcriptCollapsed());
    self.transcript_older = self.transcript_plan.older;
    // Without any boundary, where the conversation starts is unknown.
    self.transcript_beginning = self.transcript_older == null and !(self.transcript_plan.gap and self.marks.count == 0);
    try self.showOlderLabels();
}

/// Shows the gap's label once its Messages are listed, and the
/// conversation's start once nothing older remains.
fn showOlderLabels(self: *Self) !void {
    const screen = self.terminal.screen;
    const plan = &self.transcript_plan;
    if (plan.gap and plan.echo_count == 0 and plan.dropped == null) {
        // A label can push newer rows, and their blocks, off the end.
        self.transcript_blocks.dropNewest(try screen.markGap());
        plan.gap = false;
    }
    if (self.transcript_beginning and self.transcript_plan.next() == null and self.transcript_older == null) {
        self.transcript_blocks.dropNewest(try screen.markBeginning());
        self.transcript_beginning = false;
    }
}

fn olderWanted(self: *const Self) bool {
    return (self.transcript_plan.next() != null or self.transcript_older != null) and !self.older_failed and self.terminal.screen.transcriptAtTop() and !self.opening;
}

fn step(self: *Self, wait: i32) !ConsentPolicy.Service {
    const stream = &self.input.stream;
    const pending = stream.pending();
    const read = (self.terminal.next(self.init.io, stream, wait) catch |err| switch (err) {
        error.InputDeadline => {
            if (try stream.expire()) try self.navigation(.close_view);
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
        // Ctrl-R recovers in every encoding the terminal may send it, raw,
        // Kitty or modifyOtherKeys, but never from pasted text. Beside its
        // Action it is choice input; while approval is paused, recovery
        // waits for the Action and the paused draft stays as it is.
        .event => |value| if (!value.pasted and isRecovery(value.event) and self.terminal.screen.selected.editor != .choice) {
            if (self.terminal.screen.consent.active()) {
                self.terminal.screen.invalidateChoice();
                self.notice = self.decisionNotice();
            } else try self.submission.requestRecovery(null);
        } else try self.inputEvent(decoded),
        else => try self.inputEvent(decoded),
    };
    return .byte;
}

fn isRecovery(event: vaxis.Event) bool {
    return switch (event) {
        .key_press => |key| key.matchExact('r', .{ .ctrl = true }),
        else => false,
    };
}

fn inputEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    switch (decoded) {
        // The editor the latest frame encodes takes the input; a transition
        // changes it only at the next frame. While approval is paused, typing
        // goes to the draft shown in the composer; it never decides, and
        // returning to the Action needs a fresh choice.
        else => if (self.terminal.screen.selected.editor == .choice) try self.choiceEvent(decoded) else {
            const screen = self.terminal.screen;
            if (screen.consent.active()) {
                screen.invalidateChoice();
                screen.restartChoice();
            }
            try self.draftEvent(decoded);
            if (self.detached) screen.interruptConsent();
        },
    }
}

fn choiceEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const stream = &self.input.stream;
    const screen = self.terminal.screen;
    const event = screen.applyChoice(decoded);
    if (!screen.consent.acceptsInput()) {
        // Discard text; the stream keeps any fragmented sequence.
        if (event == .interrupt or event == .eof) {
            screen.interruptConsent();
            self.detached = true;
        }
        try self.navigation(event);
        switch (event) {
            .invalid, .edit_rejected, .unbound, .overflow => self.notice = choiceRejection(event, false),
            else => {},
        }
        // Only a slash command survives, or any text while the Action is
        // unread: reading its last row clears it, so neither can decide.
        const text = screen.choiceText();
        const command = std.mem.startsWith(u8, text, "/");
        const reading = screen.selected.approval == .reading;
        if (event == .submit and command) self.choiceCommand(text);
        // Enter on an unread Action says why nothing was decided.
        if (event == .submit and !command and reading) self.notice = "! Read the whole Action first; nothing authorized.";
        if (ChoiceLine.end(Editor.endsLine(event), text, reading, stream.pending() != .none)) screen.restartChoice();
        return;
    }
    try self.navigation(event);
    switch (event) {
        .submit => {
            const text = screen.choiceText();
            // Probe current geometry, command and selection; never the
            // readiness of the frame that drew the prompt.
            switch (screen.submitChoice(text, self.terminal.geometry(), self.commandActive())) {
                .decision => |selected| {
                    // Consumption precedes fallible submission.
                    screen.releaseAction();
                    try self.submission.begin(.{ .decision = .{ .action = selected.action, .decision = if (selected.choice == .allow_once) .allow_once else .deny } });
                },
                .blocked => |reason| if (std.mem.startsWith(u8, text, "/")) self.choiceCommand(text) else {
                    self.notice = if (reason == .command) "! Command still running. Nothing authorized." else "! Read the whole Action first; nothing authorized.";
                },
                .other => if (std.mem.startsWith(u8, text, "/")) self.choiceCommand(text) else {
                    self.notice = "! Choose a or d. Nothing authorized.";
                },
            }
            screen.invalidateChoice();
            screen.restartChoice();
        },
        .invalid, .edit_rejected, .unbound, .overflow => {
            screen.restartChoice();
            screen.invalidateChoice();
            self.notice = choiceRejection(event, self.decisionShown() and !self.commandActive());
        },
        .interrupt, .eof => {
            screen.interruptConsent();
            self.detached = true;
        },
        else => {},
    }
}

/// Why a draft waits for the Action: a previewed Action is decided only in the shell.
fn decisionNotice(self: *const Self) []const u8 {
    return if (self.terminal.screen.consent.presentation == .preview) "! Approval disabled · /help for exact shell commands. Draft retained." else "! Action needs a decision; Esc returns to it. Draft retained.";
}

/// Only a choice ready to decide can ask for a or d; until then the
/// status line names what the Action needs first, such as reading it.
fn choiceRejection(event: Editor.Event, ready: bool) []const u8 {
    if (!ready) return if (event == .unbound) "! Key combination not recognized; nothing authorized." else "! Decision input rejected; nothing authorized.";
    return if (event == .unbound) "! Key combination not recognized; nothing authorized. Type a or d." else "! Decision input rejected. Type a or d; pasted text cannot authorize.";
}

fn draftEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const submission = self.submission.view();
    // A Message waits for a pending command, which may change its configuration.
    // A live probe immediately before sealing, with no effect between them.
    const allowed = ConsentPolicy.messageAllowed(self.terminal.screen.consent, .{
        .opening = self.opening,
        .permission_preparing = self.read_phase == .permission,
        .command = self.commandActive(),
        .original = if (submission) |value| (if (value.kind == .decision) .decision else .message) else .none,
    });
    switch (self.input.applySelected(decoded, allowed)) {
        .message => |ticket| {
            try self.beginMessage(ticket);
        },
        .command => {
            self.slashCommand(self.input.composition().bytes);
            self.input.clear();
        },
        .busy => self.notice = if (self.commandActive()) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (self.terminal.screen.consent.active()) self.decisionNotice() else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .page_up, .page_down, .scroll_up, .scroll_down, .latest, .close_view, .expand => try self.navigation(event),
            .interrupt, .eof => self.detached = true,
            .invalid, .edit_rejected => self.notice = "! Input rejected; nothing sent. Enter plain text or paste again.",
            .unbound => self.notice = "! Key combination not recognized; ignored. Draft unchanged.",
            .overflow => self.notice = "! input too long; nothing sent. Draft cleared. Enter a shorter message.",
            else => {},
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
            if (accepted.admission) |admission| self.echo = if (admission > self.delivered) admission else null;
            if (accepted.confirmed) self.notice = if (accepted.kind == .decision) "  • Decision confirmed." else "  • Original confirmed.";
        },
        .rejected => |rejected| {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            var text: TerminalText = .{ .mode = .line };
            try writer.writeAll(if (rejected.kind == .decision) "! Decision rejected: " else "! Input rejected: ");
            try text.feed(&writer, rejected.code.slice());
            try text.finish(&writer);
            try writer.writeAll(". /discard clears it; the next draft is safe.");
            self.notice = writer.buffered();
        },
        .absent, .failed => {},
    }
}

fn settleReader(self: *Self) !void {
    const end = self.joinReader();
    // A pending inspection supersedes a silent read it cancelled.
    const mode: departure.Mode = if (self.input.queuedCommand() != null) .inspection else .active;
    // A fatal failure leaves command output for exit to print.
    if (end.failure(mode)) |err| return err;
    if (end != .complete and self.command_running) {
        // Nothing to show: the command failed before writing output.
        self.command_running = false;
        self.terminal.screen.invalidateChoice();
    }
    if (end == .complete and self.read_phase == .history) {
        // The user may have left the transcript while this page loaded.
        const screen = self.terminal.screen;
        if (screen.view == .transcript and self.job.transcript == self.transcript) {
            const prepended = try screen.prependFile(self.init.io, self.inspection_file);
            // The page's newest blocks are those its kept rows show.
            const collapsed = self.job.result.collapsed.slice();
            var older: [@typeInfo(@FieldType(reads.Collected, "items")).array.len]?View.Collapsed = @splat(null);
            const kept = @min(prepended.older, older.len);
            for (0..kept) |index| {
                const from_end = kept - index;
                older[index] = if (from_end <= collapsed.len) collapsed[collapsed.len - from_end] else null;
            }
            self.transcript_blocks.prepend(older[0..kept]);
            self.transcript_blocks.dropNewest(prepended.trimmed);
            if (self.job.listing) |listed| self.transcript_plan.listed(listed, self.job.result.listing) else {
                self.transcript_older = self.job.result.history_cursor;
                self.transcript_beginning = self.transcript_older == null;
            }
            try self.showOlderLabels();
        }
    } else if (end == .complete and self.read_phase == .message) {
        const screen = self.terminal.screen;
        const request = self.message_reading.?;
        self.message_reading = null;
        // Only over the unchanged view it was asked from, before any send,
        // dismissal or newer Ctrl-O.
        if (request.generation == self.message_generation and request.sent == self.sent and screen.view == request.view and
            (request.view == .live or request.transcript == self.transcript))
            try screen.showMessage(self.init.io, self.inspection_file);
    } else if (end == .complete and (self.read_phase == .activity or self.read_phase == .permission)) {
        if (self.job.result.settled) try self.showStaged();
    } else if (end == .complete and (self.read_phase == .details or self.read_phase == .inspection)) {
        if (self.read_phase != .details or self.details_sent == self.sent) try self.showInspection();
        self.command_running = false; // Shown; exit no longer prints it.
    }
    try self.applyReader(end);
}

/// Appends a joined read's staged live output; none of it showed before.
/// Its boundaries and echoes take the live offsets where writing reaches
/// them: live output keeps text, not the styling the scratch file also
/// counts, and escapes clusters it cannot show, so each is the settled end
/// once writing reaches it. A page's own start precedes its separator.
fn showStaged(self: *Self) !void {
    const result = &self.job.result;
    self.messages = result.messages;
    if (result.lowest) |lowest| self.lowest = if (self.lowest) |known| @min(known, lowest) else lowest;
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
                self.marks.record(.{ .offset = offset, .cursor = mark.cursor, .admitted = mark.admitted });
                self.echoes.prune(offset);
            },
            .echo_start => echoes.items[cut.index].output = offset,
            .echo_end => {
                var echo = echoes.items[cut.index];
                echo.end = offset;
                if (echo.message.state != .applied) self.lowest = if (self.lowest) |known| @min(known, echo.position) else echo.position;
                self.echoes.add(echo, self.opening);
            },
        }
    }
    _ = try staged.to(staged.length);
    for (result.collapsed.slice()) |block| self.live_blocks.append(block);
    if (staged.length != 0) self.reader_output_started = true;
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
            const count = try frontend.inspection_file.readPositionalAll(frontend.init.io, self.buffer[0..@intCast(@min(self.buffer.len, output - self.written))], self.written);
            if (count == 0) return error.TruncatedDisplayScratch;
            // A notice can end the group while a read is still silent. Restore
            // its separator before the first compact heading.
            if (self.written == 0 and !frontend.opening and !frontend.compact_tools and self.buffer[0] != '\n') try frontend.terminal.permanent("\n");
            try frontend.terminal.permanent(self.buffer[0..count]);
            self.written += count;
        }
        return if (output == 0) self.start else try frontend.terminal.screen.liveEnd();
    }
};

fn joinReader(self: *Self) ReadEnd {
    if (self.reader.thread == null) return .absent;
    const result = self.reader.join();
    const progress: ReadEnd.Progress = .{ .phase = self.read_phase, .rendering = self.job.result.rendering };
    const end: ReadEnd = if (result) |_| .complete else |err| if (err == error.Cancelled) .{ .cancelled = progress } else .{ .failed = .{ .err = err, .progress = progress } };
    if (self.reader.read_failure) |failure| {
        std.debug.assert(self.pending_diagnostic == null);
        self.pending_diagnostic = .{ .failure = failure, .phase = self.read_phase, .recoverable = end.preparationFailure() };
        self.reader.read_failure = null;
    }
    return end;
}

fn writePendingDiagnostic(self: *const Self, out: *std.Io.Writer) !void {
    try self.pending_diagnostic.?.failure.writeDiagnostic(out);
}

fn presentReadDiagnostic(self: *Self, sink: anytype) !void {
    const pending = self.pending_diagnostic.?;
    self.compact_tools = false;
    var bytes: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try out.writeAll(switch (pending.phase) {
        .details => "! Details unavailable; draft retained. ",
        .inspection => "! Inspection unavailable; draft retained. ",
        else => "! Earlier messages unavailable; scroll up to retry. Draft retained. ",
    });
    try self.writePendingDiagnostic(&out);
    try sink.permanent("\n");
    try sink.permanent(View.Style.failure.code(self.colour));
    try sink.permanent(out.buffered());
    try sink.permanent(View.Style.normal.code(self.colour));
    try sink.permanent("\n");
    @memcpy(self.notice_buffer[0..out.buffered().len], out.buffered());
    self.notice = self.notice_buffer[0..out.buffered().len];
    self.pending_diagnostic = null;
    self.dirty = true;
}

test "frontend joined read diagnostic survives failed notice and worker reset" {
    const Worker = struct {
        fn fail(_: *anyopaque, task: *Task) !void {
            var failure: client.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
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
            var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false, .read_phase = phase };
            self.init.io = std.testing.io;
            try self.reader.start(std.testing.io, &self, Worker.fail);
            try self.settleReader(); // Preparation is recoverable, not fatal.
            try std.testing.expect(self.pending_diagnostic != null);
            try std.testing.expect(self.reader.read_failure == null);
            var sink: Sink = .{ .fail_at = fail_at };
            try std.testing.expectError(error.WriteFailed, self.presentReadDiagnostic(&sink));
            try std.testing.expect(self.pending_diagnostic != null);
            // Exercise the actual Task reset, also performed before spawn can fail.
            try self.reader.start(std.testing.io, &self, Worker.idle);
            try self.reader.join();
            self.input.init();
            self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
            self.terminal = .{ .original = undefined, .flags = undefined, .screen = undefined, .active = false };
            const settled = self.quiesce();
            for ([_]anyerror{ error.WriteFailed, error.SystemResources }) |cause|
                try std.testing.expectEqual(cause, settled.failure(.final_exit, cause).?);
            var bytes: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try self.writePendingDiagnostic(&out);
            try std.testing.expectEqualStrings("HTTP 503; type: busy; code: host_busy\\x1b\\n", out.buffered());
            sink = .{ .fail_at = null };
            try self.presentReadDiagnostic(&sink);
            try std.testing.expect(self.pending_diagnostic == null);
            try std.testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.length], out.buffered()) != null);
            try std.testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.length], if (phase == .details) "Details unavailable" else "Earlier messages unavailable") != null);
            // The status region repeats it while the transcript holds the record.
            try std.testing.expect(std.mem.indexOf(u8, self.notice.?, out.buffered()) != null);
        }
    }
}

fn applyReader(self: *Self, end: ReadEnd) !void {
    if (end.preparationFailure()) {
        if (self.read_phase == .history) self.older_failed = true;
        if (self.pending_diagnostic == null)
            self.notice = switch (self.read_phase) {
                .details => "! Details unavailable; draft retained.",
                .message => "! Message unavailable; Ctrl-O to retry. Draft retained.",
                .inspection => "! Inspection unavailable; draft retained.",
                else => "! Earlier messages unavailable; scroll up to retry. Draft retained.",
            };
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    if (self.reader_output_started)
        self.compact_tools = if (self.read_phase == .activity or self.read_phase == .permission) self.job.result.compact_tools else false;
    if (self.read_phase == .history or self.read_phase == .message) {
        self.notice = null; // Clears "Loading earlier messages…" or "Opening message…".
    } else if (self.read_phase == .details or self.read_phase == .inspection) {
        // showInspection selected the notice.
    } else if (!self.job.result.settled) {
        // The work changed while the page was read: nothing applied; read again.
        self.unsettled +|= 1;
        self.read_phase = .activity;
        self.poll_at = 0;
        return;
    } else {
        // History, footer, status, Sent and /status change together, in one frame.
        const result = &self.job.result;
        self.unsettled = 0;
        self.delivered = @max(self.delivered, result.delivered);
        if (self.echo) |admission| if (admission <= self.delivered) {
            self.echo = null;
        };
        if (result.status) try self.applyStatus();
        self.current = result.current;
        self.live = result.live;
        self.cursor = result.cursor;
        self.opening = false;
        if (self.read_phase == .permission) {
            self.prepared_action = result.action;
            self.prepared_summary = result.summary;
            if (self.prepared_action == null) self.read_phase = .activity;
        }
    }
    // A /status asked for during this read is the next read's, at once.
    self.poll_at = if (self.status_requested) 0 else std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
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
            .scratch = undefined,
            .command = undefined,
            .terminal = undefined,
            .colour = false,
            .opening = false,
            .cursor = .{ .position = 7 },
            .compact_tools = case.prior,
            .reader_output_started = case.output,
        };
        self.job.result = .{ .settled = true, .current = std.mem.zeroes(client.Current), .cursor = .{ .position = 12 }, .compact_tools = case.next };
        self.init.io = std.testing.io;
        try self.applyReader(case.end);
        try std.testing.expectEqual(case.expected, self.compact_tools);
        try std.testing.expectEqual(@as(u64, if (case.end == .complete) 12 else 7), self.cursor.position);
    }
}

test "after three changed reads in a row the newest capture applies" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false, .opening = false };
    self.init.io = std.testing.io;
    for (0..3) |_| {
        try std.testing.expect(!self.freeze(.activity).force);
        self.read_phase = .activity;
        self.job.result = .{ .settled = false, .current = std.mem.zeroes(client.Current), .cursor = .{ .position = 9 } };
        try self.applyReader(.complete);
        // Nothing applied; the read repeats at once.
        try std.testing.expectEqual(@as(i96, 0), self.poll_at);
        try std.testing.expectEqual(@as(u64, 0), self.cursor.position);
    }
    try std.testing.expect(self.freeze(.activity).force);
    self.job.result = .{ .settled = true, .current = std.mem.zeroes(client.Current), .cursor = .{ .position = 3 } };
    try self.applyReader(.complete);
    try std.testing.expectEqual(@as(u64, 3), self.cursor.position);
    try std.testing.expect(!self.freeze(.activity).force);
}

fn showInspection(self: *Self) !void {
    // Any completed inspection or command requires a fresh choice afterwards.
    self.terminal.screen.invalidateChoice();
    self.status_page = false;
    const size = (try self.inspection_file.stat(self.init.io)).size;
    if (size == 0) {
        self.notice = "Command finished with no output.";
        return;
    }
    // A short command result is a notice, not a page. Inside the Session the
    // speaker is known: CLI "Rui: " text loses its prefix and "rui: "
    // diagnostics become failure notices.
    if (self.read_phase == .inspection and self.inspection_kind == .command and size <= 256) {
        var bytes: [256]u8 = undefined;
        const text = std.mem.trimEnd(u8, bytes[0..try self.inspection_file.readPositionalAll(self.init.io, bytes[0..@intCast(size)], 0)], "\n");
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
    try self.terminal.screen.showFile(self.init.io, self.inspection_file, false);
    // The page heading already says how to return.
    self.notice = null;
}

/// A settled scan's /status: the page asked for, or the shown page updated in
/// place. An update keeps the reader's place, choice, notice and consent.
fn applyStatus(self: *Self) !void {
    const screen = self.terminal.screen;
    if (self.job.open_status and self.status_requested) {
        self.status_requested = false;
        screen.invalidateChoice();
        try screen.showFile(self.init.io, self.status_file, false);
        self.notice = null;
    } else if (self.status_page and screen.view == .inspection) {
        try screen.refreshFile(self.init.io, self.status_file);
    } else return;
    self.status_page = true;
    self.status_digest = self.job.result.status_digest;
}

test "a line begun at the choice ends there when the Action leaves or a page opens without a key" {
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
    const Change = enum { decided_elsewhere, command_page, status_page };
    for (std.enums.values(Change)) |change| for ([_][2][]const u8{ .{ "/", "status" }, .{ "a", "" } }) |line| {
        errdefer std.debug.print("change={s} line={s}|{s}\n", .{ @tagName(change), line[0], line[1] });
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .inspection_file = page, .status_file = page, .command = undefined, .terminal = .{ .original = undefined, .flags = undefined, .output = -1, .screen = screen }, .colour = false, .opening = false };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
        const Keys = struct {
            fn send(frontend: *Self, bytes: []const u8) !void {
                for (bytes) |byte| {
                    var decoded = frontend.input.stream.feed(byte, 0);
                    while (decoded != .none) : (decoded = frontend.input.stream.next()) try frontend.inputEvent(decoded);
                }
            }
        };
        try Keys.send(&self, "kept");
        screen.restartChoice();
        self.current.first_action = 7;
        screen.consent = .{};
        screen.consent.adopt(7, .complete);
        screen.view = .action;
        screen.preview_complete = true;
        screen.action_seen = .end;
        try std.testing.expect(screen.consent.promptCompleted(.empty, false, false));
        // Each change is followed by the frame that shows it.
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Approval.ready, screen.selected.approval);
        try Keys.send(&self, line[0]);
        switch (change) {
            .decided_elsewhere => {
                self.current.first_action = null;
                self.withdrawDecided();
                try std.testing.expect(!screen.consent.active());
            },
            .command_page => {
                self.read_phase = .inspection;
                self.inspection_kind = .command;
                try self.showInspection();
            },
            .status_page => {
                self.job.open_status = true;
                self.status_requested = true;
                try self.applyStatus();
            },
        }
        try std.testing.expect(!screen.actionVisible());
        // The open line keeps the choice editor, with no decision prompt.
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Editor.choice, screen.selected.editor);
        try std.testing.expect(screen.selected.approval != .ready and screen.selected.approval != .draining);
        try Keys.send(&self, line[1]);
        try std.testing.expectEqualStrings("kept", self.input.composition().bytes);
        try Keys.send(&self, "\r");
        // Nothing reached the draft or was sent, and nothing was decided.
        try std.testing.expectEqualStrings("kept", self.input.composition().bytes);
        try std.testing.expect(self.submission.view() == null);
        if (change != .decided_elsewhere) try std.testing.expectEqual(@as(?u64, 7), screen.consent.action);
        // A slash command still runs as typed.
        const command = self.input.queuedCommand();
        if (line[0][0] == '/') try std.testing.expectEqualStrings("/status", command orelse "") else try std.testing.expect(command == null);
        // The next line is the draft's again.
        _ = screen.select(self.commandActive());
        try std.testing.expectEqual(ConsentPolicy.Editor.draft, screen.selected.editor);
        try Keys.send(&self, "!");
        try std.testing.expectEqualStrings("kept!", self.input.composition().bytes);
    };
}

test "a transcript begun before grown live output is drawn shows the gap, not a lost join" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false, .opening = false };
    self.terminal.screen = screen;
    try screen.append("GROWS-FIRST\n");
    self.marks.record(.{ .offset = 12, .cursor = .{ .end = 3 }, .admitted = 4 });
    // Unescaped, the rows after the mark fit; escaped, they evict it.
    for (0..45000) |_| try screen.append("\u{200b}");
    try screen.append("\nGROWS-END\n");
    try self.beginTranscript();
    try std.testing.expect(std.mem.indexOf(u8, screen.browsing.text(), "Earlier rows left this view.") != null);
    try std.testing.expectEqual(@as(?u64, 3), if (self.transcript_older) |cursor| cursor.end else null);
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
        held.self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = held.directory[0..directory], .scratch = undefined, .command = undefined, .terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = screen, .input = pipes[0][0], .output = pipes[1][1] }, .colour = false, .opening = false };
        held.self.init.io = std.testing.io;
        held.self.current = std.mem.zeroes(client.Current);
        held.self.input.init();
        held.self.submission = .{ .io = std.testing.io, .store = "unused", .session = "unused", .directory = held.self.directory, .input = &held.self.input };
        held.self.terminal.pump = .{ .context = held, .step = pumpHeld };
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
        held.self.action_file = file;
        try held.screen.adopt(std.testing.io, file, 0xa);
        held.self.current.first_action = 0xa;
        return file;
    }
};

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
    const Keys = struct {
        fn send(frontend: *Self, bytes: []const u8) !void {
            for (bytes) |byte| {
                var decoded = frontend.input.stream.feed(byte, 0);
                while (decoded != .none) : (decoded = frontend.input.stream.next()) try frontend.inputEvent(decoded);
            }
        }
    };
    // A running command: a draft inspection queues behind it.
    self.command_running = true;
    try Keys.send(self, "/requests\r");
    try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
    try std.testing.expectEqualStrings("", self.input.composition().bytes);
    // A queued one: every draft command waits, local ones too, and keeps the draft.
    for ([_][]const u8{ "/wait", "/exit", "/help" }) |text| {
        self.notice = null;
        try Keys.send(self, text);
        try Keys.send(self, "\r");
        try std.testing.expectEqualStrings(text, self.input.composition().bytes);
        try std.testing.expectEqualStrings("! Command still running. Draft retained.", self.notice.?);
        try std.testing.expect(!self.detached);
        try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
        self.input.clear();
    }
    // The choice runs nothing but exit and page requests meanwhile, and says why.
    for ([_]struct { bool, []const u8 }{
        .{ true, "! Command still running. Try again when it finishes." },
        .{ false, "! Preparing inspection; try again when it finishes." },
    }) |case| {
        self.command_running = case[0];
        for ([_][]const u8{ "/wait", "/recover 01234567-89ab-4cde-8012-0123456789ab", "/help" }) |text| {
            self.notice = null;
            self.choiceCommand(text);
            try std.testing.expectEqualStrings(case[1], self.notice.?);
            try std.testing.expectEqualStrings("/requests", self.input.queuedCommand().?);
        }
    }
    self.choiceCommand("/details");
    try std.testing.expectEqual(@as(?History, .latest), self.history_requested);
    self.choiceCommand("/exit");
    try std.testing.expect(self.detached);
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
    try std.testing.expectEqual(ConsentPolicy.Editor.choice, held.screen.selected.editor);
    try std.testing.expect(held.screen.consent.acceptsInput());
    try held.hold("/status\ra\r");
    self.dirty = true;
    _ = try self.draw();
    try std.testing.expect(held.pumps != 0);
    try std.testing.expectEqual(@as(?u64, 0xa), held.screen.consent.action);
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
    try std.testing.expectEqual(@as(?u64, 0xa), held.screen.consent.action);
    try std.testing.expect(self.submission.view() == null);
    // The replacement frame selects the choice, which needs fresh input.
    try held.settle();
    try std.testing.expectEqual(ConsentPolicy.Editor.choice, held.screen.selected.editor);
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
    self.inspection_file = page;
    for ([_]bool{ true, false }) |send| {
        Worker.release.store(false, .release);
        try held.screen.latest();
        // /details begins its read, as driveActive does.
        self.details_sent = self.sent;
        self.read_phase = .details;
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
        var stream: TerminalInput = .{};
        var found: ?bool = null;
        for (case.bytes) |byte| switch (stream.feed(byte, 0)) {
            .event => |decoded| found = isRecovery(decoded.event),
            else => {},
        };
        try std.testing.expectEqual(@as(?bool, case.recovery), found);
    }
}
