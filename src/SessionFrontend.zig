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
history_requested: ?enum { older, latest } = null,
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
consent: ConsentPolicy.Consent = .{},
choice_buffer: [64]u8 = undefined,
choice: Editor = undefined,
// A line typed at the choice keeps the keyboard through its Enter, even once
// the Action leaves or a page hides it, so none of it reaches the draft.
choice_line: bool = false,
opening: bool = true,
poll_at: i96 = 0,
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

fn inspection(text: []const u8) ?Inspection {
    if (std.mem.eql(u8, text, "/status")) return .status;
    if (std.mem.eql(u8, text, "/requests")) return .requests;
    if (std.mem.eql(u8, text, "/help")) return .help;
    for ([_][]const u8{ "/inspect-action", "/setup", "/configure" }) |name| {
        if (std.mem.eql(u8, text, name)) return .command;
    }
    for ([_][]const u8{ "/setup ", "/configure ", "/result " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return .command;
    }
    return null;
}

/// The page asked for last is the one shown: a /status not yet rendered
/// yields to a later /history or /details.
fn requestHistory(self: *Self, text: []const u8) void {
    self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
    self.status_requested = false;
}

/// A slash command typed in the choice field, which never decides.
fn choiceCommand(self: *Self, text: []const u8) void {
    if (std.mem.eql(u8, text, "/exit")) {
        self.detached = true;
    } else if (std.mem.eql(u8, text, "/details") or std.mem.eql(u8, text, "/history")) {
        self.requestHistory(text);
    } else if (self.command_running) {
        self.notice = "! Command still running. Try again when it finishes.";
    } else if (self.input.command_length == null) {
        @memcpy(self.input.command_buffer[0..text.len], text);
        self.input.command_length = text.len;
        self.admitCommand();
    } else self.notice = "! Preparing inspection; try again when it finishes.";
}

/// Answers local commands at once. Inspections, including Host commands,
/// wait for the reader and then show their page.
fn admitCommand(self: *Self) void {
    const text = self.input.command_buffer[0..self.input.command_length.?];
    if (inspection(text) != null) return;
    self.input.command_length = null;
    if (std.mem.eql(u8, text, "/discard")) {
        self.submission.discardRejected() catch {
            self.notice = "! Cannot discard an unresolved submission; Ctrl-R recovers the original.";
        };
        if (self.submission.view() == null) self.poll_at = 0;
    } else if (std.mem.startsWith(u8, text, "/recover ") and self.submission.view() != null) {
        self.submission.requestRecovery(text[9..]) catch {
            self.notice = "! Recovery key does not match this original submission; nothing sent.";
        };
    } else if (std.mem.eql(u8, text, "/wait")) {
        self.notice = "Work continues while you compose.";
    } else if (std.mem.eql(u8, text, "/login")) {
        self.notice = "Login uses rui auth login codex in your shell.";
    } else {
        // Name the command only when it is short printable ASCII.
        const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
        var shown = name.len <= 32;
        for (name) |byte| shown = shown and byte > ' ' and byte < 0x7f;
        var writer = std.Io.Writer.fixed(&self.notice_buffer);
        writer.print("! Unknown command{s}{s} · /help", .{ if (shown) " " else "", if (shown) name else "" }) catch unreachable;
        self.notice = writer.buffered();
    }
}

test "frontend answers local and unknown commands in place and keeps Host commands for inspection" {
    var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = undefined, .colour = false };
    self.input.init();
    self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input };
    const cases = .{
        .{ "/foo bar", "! Unknown command /foo · /help" },
        .{ "/\x1b[2J", "! Unknown command · /help" },
        .{ "/result", "! Unknown command /result · /help" },
        .{ "/wait", "Work continues while you compose." },
        .{ "/configure --permission-mode ask", "" },
        .{ "/result 01234567-89ab-4cde-8012-0123456789ab", "" },
        .{ "/inspect-action", "" },
        .{ "/status", "" },
    };
    inline for (cases) |case| {
        self.notice = null;
        @memcpy(self.input.command_buffer[0..case[0].len], case[0]);
        self.input.command_length = case[0].len;
        self.admitCommand();
        if (case[1].len != 0) {
            try std.testing.expectEqualStrings(case[1], self.notice.?);
            try std.testing.expect(self.input.command_length == null);
        } else {
            try std.testing.expect(self.notice == null);
            try std.testing.expectEqual(@as(?usize, case[0].len), self.input.command_length);
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
        if (self.input.command_length) |length| if (inspection(self.input.command_buffer[0..length]) == .status) {
            // /status is the next scan's: one capture for the page, the
            // history and the composer status.
            self.input.command_length = null;
            try self.terminal.screen.latest();
            self.status_requested = true;
            self.poll_at = 0;
        };
        if (self.input.command_length != null and self.reader.thread != null and !self.reader.completed()) {
            // No read shows anything before it joins, so an inspection
            // supersedes it. Keep servicing input until completion; never join
            // unfinished work in raw mode.
            self.reader.cancel();
        }
        // A joined read may hide or withdraw the Action, so a sequence the
        // choice is decoding finishes there first and none reaches the draft.
        if (self.reader.thread != null and self.reader.completed() and !(self.choiceInput() and self.input.pending() != .none)) {
            try self.settleReader();
            self.withdrawDecided();
        }
        if (self.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(&self.terminal);
        }
        if (self.reader.thread == null and self.input.command_length != null) {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            const kind = inspection(text).?;
            try self.terminal.screen.latest();
            self.inspection_kind = kind;
            // The worker borrows its own copy; the editor may queue another.
            var job = self.freeze(.inspection);
            @memcpy(job.command_text[0..text.len], text);
            job.command_text_length = text.len;
            job.inspection_submission = self.submission.view();
            job.inspection_action = if (self.consent.presentation == .preview) self.consent.action else null;
            // The newer inspection replaces a /status not yet shown.
            self.status_requested = false;
            try self.launch(job, if (kind == .command) reads.runCommand else reads.inspectPage);
            self.command_running = true;
            self.input.command_length = null;
        }
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
            if (self.reader.thread != null) {} else if (self.olderWanted()) {
                self.notice = "Loading earlier messages…";
                try self.launch(self.freeze(.history), reads.history);
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                try self.launch(self.freeze(.activity), reads.scan);
            } else if (!self.consent.active() and !self.choice_line and !self.opening and self.submission.view() == null and self.current.first_action != null and self.input.pending() == .none) {
                // A line begun at an earlier choice ends before the next
                // Action is presented, so it never decides that one.
                try self.launch(self.freeze(.permission), reads.permission);
            }
        }
        for (0..1024) |_| {
            if (try self.step(0) != .byte) break;
            if (self.detached) break;
        }
        if (self.detached) break;
        // Finish chat paste/UTF-8 under its original decoder before consent.
        if (self.reader.thread == null and self.prepared_action != null and self.input.pending() == .none) {
            try self.terminal.screen.prepareAction(self.init.io, self.action_file);
            // Preparation is complete and the file remains immutable through
            // this choice. A bounded preview is export-only, never consent.
            const presentation: ConsentPolicy.Presentation = if ((try self.action_file.stat(self.init.io)).size <= @import("ConversationViewport.zig").capacity) .complete else .preview;
            self.consent.adopt(self.prepared_action.?, presentation);
            self.action_summary = self.prepared_summary;
            self.prepared_action = null;
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.read_phase = .activity;
            self.dirty = true;
        }
        self.withdrawDecided();
        if (self.dirty) {
            const screen = self.terminal.screen;
            if (screen.actionVisible() and !screen.preview_complete) self.consent.presentation = .preview;
            const action_visible = self.actionVisible();
            const choice_input = self.choiceInput();
            const view: Input.View = if (choice_input) .{ .bytes = self.choice.buffer[0..self.choice.length], .cursor = self.choice.cursor } else self.input.composition();
            const approval_ready = self.approvalReady();
            const base_status = if (self.opening) "Opening…" else if (self.consent.active()) (if (self.consent.presentation == .preview) "Approval disabled · /help for exact shell commands" else if (action_visible) (if (approval_ready) Frame.approval_choice else "PgDn reads the rest · then a/d + Enter") else "Approval paused · Esc returns to Action") else if (self.submission.view()) |submission| switch (submission.state) {
                .not_started => "Not sent · Ctrl-R retries original",
                .submitting => "Sending…",
                .unconfirmed => if (submission.kind == .decision) "! Decision not confirmed · Ctrl-R retries original" else "! Not confirmed · Ctrl-R retries original",
                .rejected => "Rejected · /discard",
            } else if (self.echo != null) "Sent" else workStatus(self.current.work.status.value);
            var context_buffer: [4 * std.Io.Dir.max_path_bytes + 32]u8 = undefined;
            var context = std.Io.Writer.fixed(&context_buffer);
            if (self.consent.active() and action_visible)
                try approvalContext(&context, screen.actionTopHidden(), self.action_summary)
            else if (self.tmux and !self.consent.active() and !choice_input and view.bytes.len != 0)
                try context.writeAll("In tmux, Shift-Enter sends · Alt-J adds a line");
            var status_buffer: [Frame.status_capacity]u8 = undefined;
            const status = statusLines(&status_buffer, self.notice orelse "", context.buffered(), base_status);
            self.dirty = false;
            try self.terminal.redraw(view.bytes, view.cursor, status, if (choice_input) "> " else "› ", &self.live);
            if (!approval_ready and self.approvalReady()) {
                // Reading completes only after delivery. Old choice text must
                // not become a decision, but fragmented decoder/paste custody
                // must survive until the existing empty-input freshness gate.
                self.retainChoiceCommand();
                self.consent.invalidate();
                self.dirty = true;
            }
            if (self.consent.active() and action_visible and self.actionVisible() and !self.dirty and !self.consent.acceptsInput() and self.input.pending() == .none) {
                // Every prompt byte was accepted by stdout. Discard input
                // through its decoder, not tcflush: a paste prefix or Ctrl-C
                // arriving during the final write must retain its meaning.
                var service: ConsentPolicy.Service = .budget_exhausted;
                for (0..1024) |_| {
                    service = try self.step(0);
                    if (service != .byte) break;
                    service = .budget_exhausted;
                    if (self.detached) break;
                }
                if (interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
                if (self.detached) break;
                if (self.consent.promptCompleted(service, self.input.pending() != .none, self.commandActive() or !self.actionVisible() or self.dirty)) {
                    try Editor.testChoiceReady(self.init.io);
                }
            }
        }
        _ = try self.step(16);
    }
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
    if (!self.consent.active() or self.current.first_action == self.consent.action or self.input.pending() != .none) return;
    self.consent.interrupt();
    self.terminal.screen.withdrawAction();
    self.retainChoiceCommand();
    self.dirty = true;
}

/// A change the choice did not see keeps only a slash command, which can
/// never decide; other text could become a stale decision. Either way the
/// line, its rejection and its paste custody stay the choice's until Enter.
fn retainChoiceCommand(self: *Self) void {
    if (std.mem.startsWith(u8, self.choice.buffer[0..self.choice.length], "/")) return;
    self.choice.length = 0;
    self.choice.cursor = 0;
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
    try self.terminal.screen.latest();
}

fn actionVisible(self: *const Self) bool {
    const screen = self.terminal.screen;
    return self.consent.presentation == .complete and screen.actionVisible() and screen.preview_complete;
}

/// A queued or running command ends consent freshness until it completes.
fn commandActive(self: *const Self) bool {
    return self.input.command_length != null or self.command_running;
}

fn approvalReady(self: *const Self) bool {
    if (!self.actionVisible() or self.commandActive()) return false;
    const size = self.terminal.geometry();
    return size.row == self.terminal.size.row and size.col == self.terminal.size.col and self.terminal.screen.approvalReady();
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
        .latest, .close_view => try screen.latest(),
        else => {},
    }
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
        try screen.markGap();
        plan.gap = false;
    }
    if (self.transcript_beginning and self.transcript_plan.next() == null and self.transcript_older == null) {
        try screen.markBeginning();
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
        .event => |value| if (!value.pasted and isRecovery(value.event) and !self.choiceInput()) {
            if (self.consent.active()) {
                self.consent.invalidate();
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

/// The choice takes input beside its Action, and keeps a line begun there
/// through its Enter.
fn choiceInput(self: *const Self) bool {
    return self.choice_line or (self.consent.active() and self.actionVisible());
}

fn inputEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    switch (decoded) {
        // While approval is paused, typing goes to the draft shown in the
        // composer; it never decides, and returning to the Action needs a
        // fresh choice.
        else => if (self.choiceInput()) try self.choiceEvent(decoded) else {
            if (self.consent.active()) {
                self.consent.invalidate();
                self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            }
            try self.draftEvent(decoded);
            if (self.detached) self.consent.interrupt();
        },
    }
}

fn choiceEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const stream = &self.input.stream;
    const event = self.choice.apply(decoded);
    // Typed, rejected or dropped input begins a line; only Enter ends it.
    const typed = self.choice.length != 0 or self.choice.rejected != null or event == .unbound or event == .edit_rejected;
    self.choice_line = !Editor.endsLine(event) and (self.choice_line or typed);
    if (!self.consent.acceptsInput()) {
        // Discard text; the stream keeps any fragmented sequence.
        if (event == .interrupt or event == .eof) {
            self.consent.interrupt();
            self.detached = true;
        }
        try self.navigation(event);
        switch (event) {
            .invalid, .edit_rejected, .unbound, .overflow => self.notice = choiceRejection(event, false),
            else => {},
        }
        // Only a slash command survives: it can never become a decision.
        const text = self.choice.buffer[0..self.choice.length];
        const command = text.len != 0 and text[0] == '/';
        if (event == .submit and command) self.choiceCommand(text);
        if (stream.pending() == .none and (Editor.endsLine(event) or !command)) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
        return;
    }
    try self.navigation(event);
    switch (event) {
        .submit => {
            const text = self.choice.buffer[0..self.choice.length];
            const decision = if (self.approvalReady()) self.consent.submit(text) else null;
            if (decision) |selected| {
                self.terminal.screen.releaseAction();
                try self.submission.begin(.{ .decision = .{ .action = selected.action, .decision = if (selected.choice == .allow_once) .allow_once else .deny } });
            } else if (std.mem.startsWith(u8, text, "/")) {
                self.choiceCommand(text);
            } else self.notice = if (self.approvalReady()) "! Choose a or d. Nothing authorized." else "! Read the whole Action first; nothing authorized.";
            self.consent.invalidate();
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
        },
        .invalid, .edit_rejected, .unbound, .overflow => {
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.consent.invalidate();
            self.notice = choiceRejection(event, self.approvalReady());
        },
        .interrupt, .eof => {
            self.consent.interrupt();
            self.detached = true;
        },
        else => {},
    }
}

/// Why a draft waits for the Action: a previewed Action is decided only in the shell.
fn decisionNotice(self: *const Self) []const u8 {
    return if (self.consent.presentation == .preview) "! Approval disabled · /help for exact shell commands. Draft retained." else "! Action needs a decision; Esc returns to it. Draft retained.";
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
    switch (self.input.applySelected(decoded, !self.opening and self.read_phase != .permission and !self.consent.active() and !self.commandActive() and (submission == null or submission.?.kind == .message))) {
        .message => |ticket| {
            try self.beginMessage(ticket);
        },
        .command => {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/history") or std.mem.eql(u8, text, "/details")) {
                // Local read work never cancels the independent Admission owner.
                self.input.command_length = null;
                self.requestHistory(text);
            } else self.admitCommand();
        },
        .busy => self.notice = if (self.commandActive()) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (self.consent.active()) self.decisionNotice() else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .page_up, .page_down, .scroll_up, .scroll_down, .latest, .close_view => try self.navigation(event),
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
    const mode: departure.Mode = if (self.input.command_length != null) .inspection else .active;
    // A fatal failure leaves command output for exit to print.
    if (end.failure(mode)) |err| return err;
    if (end != .complete and self.command_running) {
        // Nothing to show: the command failed before writing output.
        self.command_running = false;
        self.consent.invalidate();
    }
    if (end == .complete and self.read_phase == .history) {
        // The user may have left the transcript while this page loaded.
        const screen = self.terminal.screen;
        if (screen.view == .transcript and self.job.transcript == self.transcript) {
            try screen.prependFile(self.init.io, self.inspection_file);
            if (self.job.listing) |listed| self.transcript_plan.listed(listed, self.job.result.listing) else {
                self.transcript_older = self.job.result.history_cursor;
                self.transcript_beginning = self.transcript_older == null;
            }
            try self.showOlderLabels();
        }
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
                .inspection => "! Inspection unavailable; draft retained.",
                else => "! Earlier messages unavailable; scroll up to retry. Draft retained.",
            };
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    if (self.reader_output_started)
        self.compact_tools = if (self.read_phase == .activity or self.read_phase == .permission) self.job.result.compact_tools else false;
    if (self.read_phase == .history) {
        self.notice = null; // Clears "Loading earlier messages…".
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
    self.consent.invalidate();
    self.status_page = false;
    if (self.consent.active()) self.retainChoiceCommand();
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
        self.consent.invalidate();
        if (self.consent.active()) self.retainChoiceCommand();
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
        self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
        self.current.first_action = 7;
        self.consent.adopt(7, .complete);
        screen.view = .action;
        screen.preview_complete = true;
        try std.testing.expect(self.consent.promptCompleted(.empty, false, false));
        try Keys.send(&self, line[0]);
        switch (change) {
            .decided_elsewhere => {
                self.current.first_action = null;
                self.withdrawDecided();
                try std.testing.expect(!self.consent.active());
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
        try std.testing.expect(!self.actionVisible());
        try Keys.send(&self, line[1]);
        try std.testing.expectEqualStrings("kept", self.input.composition().bytes);
        try Keys.send(&self, "\r");
        // Nothing reached the draft or was sent, and nothing was decided.
        try std.testing.expectEqualStrings("kept", self.input.composition().bytes);
        try std.testing.expect(self.submission.view() == null);
        if (change != .decided_elsewhere) try std.testing.expectEqual(@as(?u64, 7), self.consent.action);
        // A slash command still runs as typed.
        const command: ?[]const u8 = if (self.input.command_length) |length| self.input.command_buffer[0..length] else null;
        if (line[0][0] == '/') try std.testing.expectEqualStrings("/status", command orelse "") else try std.testing.expect(command == null);
        // The next line is the draft's again.
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
        for (case.bytes) |byte| switch (stream.feed(byte)) {
            .event => |decoded| found = isRecovery(decoded.event),
            else => {},
        };
        try std.testing.expectEqual(@as(?bool, case.recovery), found);
    }
}
