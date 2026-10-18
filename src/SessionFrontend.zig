//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
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
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const stderr = @import("stderr.zig");
const TerminalText = @import("TerminalText.zig");
const Self = @This();

pub const Command = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []u8) anyerror!void;
pub const Inspect = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []const u8, *std.Io.Writer) anyerror!void;
pub const Files = struct { scratch: std.Io.File, action: std.Io.File, inspection: std.Io.File };
const Inspection = enum { status, requests, help, command };
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
command: Command,
inspect: Inspect = undefined,
inspection_kind: Inspection = .status,
// The shown inspection page is /status; it reloads when the work it
// describes changes, so it never reports finished work as running.
status_page: bool = false,
status_stale: bool = false,
// An inspection or Host command started and its result has not been
// presented. A command may change configuration, so Messages and consent wait
// for every inspection; exit prints an unshown command's output, which can
// carry recovery warnings.
command_running: bool = false,
terminal: Terminal,
colour: bool,
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
// Each transcript gets a new identity, so a page loaded for one is never
// joined to another.
transcript: u64 = 0,
// A failed older load waits for the next scroll rather than retrying at once.
older_failed: bool = false,
history_requested: ?enum { older, latest } = null,
// Where each read's live output began, so a transcript whose live copy lost
// its front still continues from a canonical position without a gap.
marks: Marks = .{},
read_phase: ReadPhase = .activity,
prepared_action: ?u64 = null,
prepared_summary: View.ActionSummary = .{},
action_summary: View.ActionSummary = .{},
reader_output_started: bool = false,
consent: ConsentPolicy.Consent = .{},
choice_buffer: [64]u8 = undefined,
choice: Editor = undefined,
opening: bool = true,
poll_at: i96 = 0,
dirty: bool = true,
detached: bool = false,
notice: ?[]const u8 = null,
// One joined read at a time; no reuse until its live diagnostic is delivered.
pending_diagnostic: ?struct { failure: client.ReadFailure, phase: ReadPhase, recoverable: bool } = null,
notice_buffer: [1536]u8 = undefined,
previous_signals: [2]std.posix.Sigaction = undefined,

/// Read boundaries in live output, oldest first. A boundary pairs the
/// absolute live offset where a read's output began with the canonical cursor
/// for everything before it (null: the conversation's start).
const Marks = struct {
    const Mark = struct { offset: u64, cursor: ?client.ConversationCursor };
    items: [64]Mark = undefined,
    count: usize = 0,

    fn record(self: *Marks, offset: u64, cursor: ?client.ConversationCursor) void {
        if (self.count == self.items.len) {
            // The oldest boundary is the first to leave live output anyway.
            std.mem.copyForwards(Mark, self.items[0 .. self.count - 1], self.items[1..self.count]);
            self.count -= 1;
        }
        self.items[self.count] = .{ .offset = offset, .cursor = cursor };
        self.count += 1;
    }

    /// The first boundary still retained when live output starts at `front`.
    fn from(self: *const Marks, front: u64) ?Mark {
        for (self.items[0..self.count]) |mark| if (mark.offset >= front) return mark;
        return null;
    }
};

test "transcript boundaries survive live eviction and bounded recording" {
    var marks: Marks = .{};
    try std.testing.expect(marks.from(0) == null);
    marks.record(0, null);
    marks.record(40, .{ .end = 9, .before_position = 7 });
    try std.testing.expectEqual(@as(u64, 0), marks.from(0).?.offset);
    try std.testing.expect(marks.from(0).?.cursor == null);
    // Live output lost its first 10 bytes: continue from the next boundary.
    try std.testing.expectEqual(@as(u64, 7), marks.from(10).?.cursor.?.before_position);
    try std.testing.expect(marks.from(41) == null);
    for (0..100) |index| marks.record(100 + index, .{ .end = 200, .before_position = 100 + index });
    try std.testing.expectEqual(@as(usize, 64), marks.count);
    try std.testing.expectEqual(@as(u64, 136), marks.from(0).?.offset);
}

/// One read. Inputs are frozen at launch; the worker writes only `lead`,
/// before its first output window, and `result`, which the UI reads after
/// join. No worker reads or writes the controller.
const Job = struct {
    init: std.process.Init = undefined,
    store: []const u8 = "",
    session: []const u8 = "",
    scratch: std.Io.File = undefined,
    action_file: std.Io.File = undefined,
    inspection_file: std.Io.File = undefined,
    colour: bool = false,
    command: Command = undefined,
    inspect: Inspect = undefined,
    phase: ReadPhase = .activity,
    cursor: client.ActivityCursor = .{},
    opening: bool = false,
    older: ?client.ConversationCursor = null,
    transcript: u64 = 0,
    inspection_kind: Inspection = .status,
    command_text: [@typeInfo(@FieldType(Input, "command_buffer")).array.len]u8 = undefined,
    command_text_length: usize = 0,
    inspection_submission: ?Submission.View = null,
    inspection_action: ?u64 = null,
    // A /status reload shows only while its page is still the one on screen.
    refresh: bool = false,
    /// What the first window's output belongs to. The UI applies it with that
    /// window (the window handoff orders it), so streamed history and the live
    /// footer always come from one canonical capture.
    /// A boundary's cursor is null at the conversation's start; a page
    /// without items records no boundary.
    lead: struct { mark: ?struct { cursor: ?client.ConversationCursor } = null, live: ?View.Live = null } = .{},
    result: struct {
        current: client.Current = undefined,
        live: View.Live = .{},
        cursor: client.ActivityCursor = .{},
        compact_tools: bool = false,
        history_cursor: ?client.ConversationCursor = null,
        // Output custody began; a later failure is not a silent preparation one.
        rendering: bool = false,
        action: ?u64 = null,
        summary: View.ActionSummary = .{},
    } = .{},
};

fn freeze(self: *const Self, phase: ReadPhase) Job {
    var job: Job = .{ .init = self.init, .store = self.store, .session = self.session, .scratch = self.scratch, .action_file = self.action_file, .inspection_file = self.inspection_file, .colour = self.colour, .command = self.command, .inspect = self.inspect, .phase = phase, .cursor = self.cursor, .opening = self.opening, .older = self.transcript_older, .transcript = self.transcript, .inspection_kind = self.inspection_kind };
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

pub fn run(init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, files: Files, command: Command, inspect: Inspect, initial_text: ?[]const u8) !void {
    const no_colour: []const u8 = init.environ_map.get("NO_COLOR") orelse "";
    const colour = no_colour.len == 0;
    const screen = try init.gpa.create(Screen);
    defer init.gpa.destroy(screen);
    try screen.init(init.io, init.environ_map, colour);
    defer screen.deinit();
    var self: Self = .{ .init = init, .store = store, .session = session, .directory = directory, .scratch = files.scratch, .action_file = files.action, .inspection_file = files.inspection, .command = command, .inspect = inspect, .terminal = undefined, .colour = colour };
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
        @import("TerminalText.zig").diagnostic("rui: Read failed: {s}\n", .{out.buffered()});
    }
    const cause: ?anyerror = if (result) |_| null else |err| err;
    const plan = departure.exit(settled, cause, self.submission.view() != null);
    if (plan.recovery_before_notice) self.recoveryGuide();
    if (self.command_running and self.inspection_kind == .command) self.commandOutputGuide();
    if (plan.failure) |err| {
        switch (err) {
            error.TerminalTooSmall => @import("TerminalText.zig").diagnostic("rui: Enlarge the terminal and resume this Session. Required instructions do not fit; nothing was authorized by the clipped view.\n", .{}),
            error.TerminalTooLarge => @import("TerminalText.zig").diagnostic("rui: Rui supports at most 49,152 terminal cells (for example 256 × 192). Shrink the terminal and resume; saved content is unchanged.\n", .{}),
            error.OutOfMemory, error.UnrepresentableTerminalGrapheme, error.DisplayGraphemeTooLarge => @import("TerminalText.zig").diagnostic("rui: This frame exceeds Rui's bounded display. Shrink the terminal and resume; saved content is unchanged. One-shot session, request and action commands remain available.\n", .{}),
            else => {},
        }
        if (screen.action_view != null) {
            if (settled.restored) |_| {
                self.terminal.detached(store, session, self.current.first_action) catch |notice_error|
                    @import("TerminalText.zig").diagnostic("rui: Action recovery notice failed: {s}\n", .{@errorName(notice_error)});
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
    if (self.reader.take() != null) self.reader.acknowledge();
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
    if (out.buffered().len != 0) @import("TerminalText.zig").diagnostic("{s}", .{out.buffered()});
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

/// A slash command typed in the choice field, which never decides.
fn choiceCommand(self: *Self, text: []const u8) void {
    if (std.mem.eql(u8, text, "/exit")) {
        self.detached = true;
    } else if (std.mem.eql(u8, text, "/details") or std.mem.eql(u8, text, "/history")) {
        self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
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

test "frontend cleanup joins both borrowers and retires output before reporting restoration failure" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *Task) !void {
            try task.feed("borrowed nonempty prefix");
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
        while (self.reader.take() == null) std.Thread.yield() catch {};
        self.reader_output_started = true;
        const settled = self.quiesce();
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(.inspection, error.InteractiveInterrupted).?);
        try std.testing.expectEqual(error.CanonicalStoreFailure, settled.admission_error.?);
        try std.testing.expect(settled.reader.cancelled.output_owned);
        try std.testing.expect(self.reader.thread == null and self.submission.task.thread == null);
        try std.testing.expect(self.reader.take() == null);
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
        const inspecting = self.input.command_length != null;
        if (inspecting and self.reader.thread != null and !self.reader.completed()) {
            // Finish an owned prefix before inspection rather than cancelling
            // and replaying it. Silent reads may be superseded; keep servicing
            // input until completion, never join unfinished work in raw mode.
            if (!self.reader_output_started) self.reader.cancel();
        }
        if (self.reader.take()) |bytes| {
            if ((!inspecting or self.reader_output_started) and bytes.len != 0) {
                // A notice can end the group while a read is still silent.
                // Restore its separator before the first compact heading.
                const live = self.read_phase == .activity or self.read_phase == .permission;
                if (!self.reader_output_started and live) {
                    if (self.job.lead.mark) |mark| self.marks.record(self.terminal.screen.liveEnd(), mark.cursor);
                    if (self.job.lead.live) |footer| self.live = footer;
                }
                if (!self.reader_output_started and live and !self.opening and !self.compact_tools and bytes[0] != '\n')
                    try self.terminal.permanent("\n");
                self.reader_output_started = true;
                try self.terminal.permanent(bytes);
                self.dirty = true;
            }
            self.reader.acknowledge();
        }
        if (self.reader.thread != null and self.reader.completed()) try self.settleReader();
        if (self.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(&self.terminal);
        }
        if (self.status_stale and self.reader.thread == null and self.input.command_length == null) {
            self.status_stale = false;
            if (self.terminal.screen.view == .inspection and self.status_page) {
                self.inspection_kind = .status;
                var job = self.freeze(.inspection);
                job.inspection_submission = self.submission.view();
                job.refresh = true;
                try self.launch(job, inspectPage);
            }
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
            try self.launch(job, if (kind == .command) runCommand else inspectPage);
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
                    try self.launch(self.freeze(.details), history);
                } else {
                    // /history scrolls the transcript to its top; older pages
                    // then load there as for any scroll.
                    const screen = self.terminal.screen;
                    if (screen.view != .transcript) {
                        try screen.latest();
                        if (screen.view == .live) try self.beginTranscript();
                    }
                    if (screen.view == .transcript) screen.browsing.top = .{};
                    self.dirty = true;
                }
            }
            if (self.reader.thread != null) {} else if (self.olderWanted()) {
                self.notice = "Loading earlier messages…";
                try self.launch(self.freeze(.history), history);
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                try self.launch(self.freeze(.activity), scan);
            } else if (!self.consent.active() and !self.opening and self.submission.view() == null and self.current.first_action != null and self.input.pending() == .none) {
                try self.launch(self.freeze(.permission), permission);
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
        if (self.consent.active() and self.current.first_action != self.consent.action and self.input.pending() == .none) {
            // Another client decided, or the Turn ended. Its choice can no
            // longer decide; a fragmented sequence finishes under the choice
            // decoder first, so none of it reaches the draft.
            self.consent.interrupt();
            self.terminal.screen.withdrawAction();
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.dirty = true;
        }
        if (self.dirty) {
            const screen = self.terminal.screen;
            if (screen.actionVisible() and !screen.preview_complete) self.consent.presentation = .preview;
            const view: Input.View = if (self.consent.active()) .{ .bytes = self.choice.buffer[0..self.choice.length], .cursor = self.choice.cursor } else self.input.composition();
            const action_visible = self.actionVisible();
            const approval_ready = self.approvalReady();
            const base_status = if (self.opening) "Opening…" else if (self.consent.active()) (if (self.consent.presentation == .preview) "Approval disabled · /help for exact shell commands" else if (action_visible) (if (approval_ready) Frame.approval_choice else "PgDn reads the rest · then a/d + Enter") else "Approval paused · Esc returns to Action") else if (self.submission.view()) |submission| switch (submission.state) {
                .not_started => "Not sent · Ctrl-R retries original",
                .submitting => "Sending…",
                .unconfirmed => if (submission.kind == .decision) "! Decision not confirmed · Ctrl-R retries original" else "! Not confirmed · Ctrl-R retries original",
                .rejected => "Rejected · /discard",
            } else workStatus(self.current.work.status.value);
            var context_buffer: [4 * std.Io.Dir.max_path_bytes + 32]u8 = undefined;
            var context = std.Io.Writer.fixed(&context_buffer);
            if (self.consent.active() and action_visible)
                try approvalContext(&context, screen.actionTopHidden(), self.current.settings.workspace.slice(), self.action_summary);
            var status_buffer: [context_buffer.len + 2048]u8 = undefined;
            var status = std.Io.Writer.fixed(&status_buffer);
            // Bypass is the default and stays quiet: /status shows Permission.
            for ([_][]const u8{ self.notice orelse "", context.buffered(), base_status }) |line| {
                if (line.len == 0) continue;
                if (status.buffered().len != 0) try status.writeAll("\n");
                try status.writeAll(line);
            }
            self.dirty = false;
            try self.terminal.redraw(view.bytes, view.cursor, status.buffered(), if (self.consent.active() and action_visible) "> " else "› ", &self.live);
            if (!approval_ready and self.approvalReady()) {
                // Reading completes only after delivery. Old choice text must
                // not become a decision, but fragmented decoder/paste custody
                // must survive until the existing empty-input freshness gate.
                self.choice.length = 0;
                self.choice.cursor = 0;
                self.choice.plain_ascii = true;
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

/// The choice keeps the Action's heading lines beside it once paging hides
/// them; they leave again when the heading is back on screen.
fn approvalContext(out: *std.Io.Writer, top_hidden: bool, workspace: []const u8, summary: View.ActionSummary) !void {
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
    try location.feed(out, workspace);
    try location.finish(out);
    if (summary.timeout_ms) |timeout| try out.print(" · Time limit: {d} ms", .{timeout}) else try out.writeAll(" · Time limit: Host default");
}

test "a paged Action keeps what runs, where and for how long beside the choice" {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var summary: View.ActionSummary = .{ .timeout_ms = 5000 };
    try approvalContext(&out, false, "/work", summary);
    try std.testing.expectEqualStrings("", out.buffered());
    try summary.description.set("Record\x1b[2J steps");
    try approvalContext(&out, true, "/work/a\x1bb", summary);
    try std.testing.expectEqualStrings("Run Bash · Record\\x1b[2J steps\nWorkspace: /work/a\\x1bb · Time limit: 5000 ms", out.buffered());
    out = std.Io.Writer.fixed(&buffer);
    try approvalContext(&out, true, "/work", .{});
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
/// boundary, so older canonical pages continue it without a gap.
fn beginTranscript(self: *Self) !void {
    const screen = self.terminal.screen;
    self.transcript += 1;
    if (self.marks.from(screen.live.origin)) |mark| {
        try screen.beginTranscript(mark.offset);
        self.transcript_older = mark.cursor;
        if (mark.cursor == null) try screen.markBeginning();
    } else {
        // No read boundary remains in view (one read exceeded it). Show the
        // gap instead of joining older pages to the wrong row.
        try screen.beginTranscript(screen.live.origin);
        self.transcript_older = null;
        try screen.markGap();
    }
}

fn olderWanted(self: *const Self) bool {
    return self.transcript_older != null and !self.older_failed and self.terminal.screen.transcriptAtTop() and !self.opening;
}

fn step(self: *Self, wait: i32) !ConsentPolicy.Service {
    const stream = &self.input.stream;
    const pending = stream.pending();
    const byte = (self.terminal.next(self.init.io, pending, wait) catch |err| switch (err) {
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
    if (!self.consent.active() and pending == .none and byte == 18) {
        try self.submission.requestRecovery(null);
        return .byte;
    }
    // One stream decodes every byte; replies never reach an editor, and an
    // event left in a suffix is delivered in order before the next byte.
    var decoded = stream.feed(byte);
    while (decoded != .none) : (decoded = stream.next()) switch (decoded) {
        .report => |report| switch (report) {
            .width => |method| self.terminal.screen.setWidth(method),
            .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
        },
        else => if (self.consent.active()) try self.choiceEvent(decoded) else try self.draftEvent(decoded),
    };
    return .byte;
}

fn choiceEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const stream = &self.input.stream;
    const visible = self.actionVisible();
    if (!visible) self.consent.invalidate();
    if (visible and !self.consent.acceptsInput()) {
        // Discard text; the stream keeps any fragmented sequence.
        const event = self.choice.apply(decoded);
        if (event == .interrupt or event == .eof) {
            self.consent.interrupt();
            self.detached = true;
        }
        try self.navigation(event);
        // Only a slash command survives: it can never become a decision.
        const text = self.choice.buffer[0..self.choice.length];
        const command = text.len != 0 and text[0] == '/';
        if (event == .submit and command) self.choiceCommand(text);
        if (stream.pending() == .none and (event == .submit or !command)) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
        return;
    }
    const event = self.choice.apply(decoded);
    try self.navigation(event);
    switch (event) {
        .latest, .close_view => {
            if (!visible) {
                self.consent.invalidate();
                self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            }
        },
        .submit => {
            const text = self.choice.buffer[0..self.choice.length];
            const decision = if (self.approvalReady()) self.consent.submit(text) else null;
            if (decision) |selected| {
                self.terminal.screen.releaseAction();
                try self.submission.begin(.{ .decision = .{ .action = selected.action, .decision = if (selected.choice == .allow_once) .allow_once else .deny } });
            } else if (std.mem.startsWith(u8, text, "/")) {
                self.choiceCommand(text);
            } else self.notice = if (visible) (if (self.approvalReady()) "! Choose a or d. Nothing authorized." else "! Read the whole Action first; nothing authorized.") else "! Nothing authorized. Esc returns to the Action before deciding.";
            self.consent.invalidate();
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
        },
        .invalid, .edit_rejected, .overflow => {
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.consent.invalidate();
            self.notice = "! Decision input rejected. Type a or d; pasted text cannot authorize.";
        },
        .interrupt, .eof => {
            self.consent.interrupt();
            self.detached = true;
        },
        else => {},
    }
}

fn draftEvent(self: *Self, decoded: TerminalInput.Decoded) !void {
    const submission = self.submission.view();
    // A Message waits for a pending command, which may change its configuration.
    switch (self.input.applySelected(decoded, !self.opening and self.read_phase != .permission and !self.commandActive() and (submission == null or submission.?.kind == .message))) {
        .message => |ticket| {
            try self.beginMessage(ticket);
        },
        .command => {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/history") or std.mem.eql(u8, text, "/details")) {
                // Local read work never cancels the independent Admission owner.
                self.input.command_length = null;
                self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
            } else self.admitCommand();
        },
        .busy => self.notice = if (self.commandActive()) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .page_up, .page_down, .scroll_up, .scroll_down, .latest, .close_view => try self.navigation(event),
            .interrupt, .eof => self.detached = true,
            .invalid, .edit_rejected => self.notice = "! Input rejected; nothing sent. Enter plain text or paste again.",
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
            if (accepted.confirmed) self.notice = if (accepted.kind == .decision) "  • Decision confirmed." else "  • Original confirmed.";
        },
        .rejected => |rejected| {
            var writer = std.Io.Writer.fixed(&self.notice_buffer);
            var text: @import("TerminalText.zig") = .{ .mode = .line };
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
            self.transcript_older = self.job.result.history_cursor;
            if (self.transcript_older == null) try screen.markBeginning();
        }
    } else if (end == .complete and self.job.refresh) {
        if (self.terminal.screen.view == .inspection and self.status_page) try self.showInspection();
    } else if (end == .complete and (self.read_phase == .details or self.read_phase == .inspection)) {
        try self.showInspection();
        self.command_running = false; // Shown; exit no longer prints it.
    }
    self.applyReader(end);
}

fn joinReader(self: *Self) ReadEnd {
    if (self.reader.thread == null) return .absent;
    const result = self.reader.join();
    const progress: ReadEnd.Progress = .{ .phase = self.read_phase, .rendering = self.job.result.rendering, .output_owned = self.reader_output_started };
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

fn applyReader(self: *Self, end: ReadEnd) void {
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
        self.notice = null; // Clears "Loading older conversation…".
    } else if (self.read_phase == .details or self.read_phase == .inspection) {
        // showInspection selected the notice.
    } else if (self.read_phase == .permission) {
        self.status_stale = self.status_stale or (self.status_page and !sameWork(self.current, self.job.result.current));
        self.current = self.job.result.current;
        self.live = self.job.result.live;
        self.cursor = self.job.result.cursor;
        self.prepared_action = self.job.result.action;
        self.prepared_summary = self.job.result.summary;
        if (self.prepared_action == null) self.read_phase = .activity;
    } else {
        self.status_stale = self.status_stale or (self.status_page and !self.opening and !sameWork(self.current, self.job.result.current));
        self.current = self.job.result.current;
        self.live = self.job.result.live;
        self.cursor = self.job.result.cursor;
        self.opening = false;
    }
    self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
    self.dirty = true;
}

test "frontend commits spacing only for completed visible reads" {
    const progress: ReadEnd.Progress = .{ .phase = .activity, .rendering = false, .output_owned = true };
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
        self.job.result = .{ .current = std.mem.zeroes(client.Current), .cursor = .{ .position = 12 }, .compact_tools = case.next };
        self.init.io = std.testing.io;
        self.applyReader(case.end);
        try std.testing.expectEqual(case.expected, self.compact_tools);
        try std.testing.expectEqual(@as(u64, if (case.end == .complete) 12 else 7), self.cursor.position);
    }
}

/// What /status reports about the work and its settings.
fn sameWork(shown: client.Current, observed: client.Current) bool {
    return shown.work.status.value == observed.work.status.value and std.meta.eql(shown.work.turn, observed.work.turn) and
        std.meta.eql(shown.work.operation, observed.work.operation) and shown.first_action == observed.first_action and
        std.meta.eql(shown.settings.revision, observed.settings.revision);
}

fn showInspection(self: *Self) !void {
    // Any completed inspection or command requires a fresh choice afterwards.
    self.consent.invalidate();
    self.status_page = false;
    if (self.consent.active()) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
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
    self.status_page = self.read_phase == .inspection and self.inspection_kind == .status;
    // The page heading already says how to return.
    self.notice = null;
}

/// Host commands keep their one-shot output owners. Their complete stdout and
/// stderr become an inspection page while the Session screen keeps drawing
/// through its own descriptor. No command reads terminal input.
fn runCommand(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.inspection_file, 0);
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    defer for (saved) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    if (saved[0] < 0 or saved[1] < 0) return error.TerminalCleanupFailed;
    // Redirected descriptors are output custody: any failure now is fatal.
    job.result.rendering = true;
    const page = job.inspection_file.handle;
    const result = if (std.c.dup2(page, 1) < 0 or std.c.dup2(page, 2) < 0) error.TerminalCleanupFailed else job.command(job.init, .{ .io = task.io, .cancellation = &interrupted }, job.store, job.session, job.command_text[0..job.command_text_length]);
    if (std.c.dup2(saved[0], 1) < 0 or std.c.dup2(saved[1], 2) < 0) return error.TerminalCleanupFailed;
    return result;
}

fn permission(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (job.result.current.first_action) |action| {
        try job.action_file.setLength(task.io, 0);
        var output: DisplayCapture = .{ .task = task, .file = job.action_file };
        job.result.summary = try View.permission(task.requests(), job.store, job.session, action, job.result.current.settings.workspace.slice(), job.scratch, &output, job.colour);
        job.result.compact_tools = false;
        job.result.action = action;
    }
}

fn scan(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    job.result.current = try View.current(requests, job.store, job.session, job.scratch);
    var cursor = job.cursor;
    if (job.opening) cursor.direction = .backward;
    const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    job.lead.live = View.Live.init(page.facts.call_activity);
    if (job.opening) {
        var mark: ?client.ConversationCursor = if (page.facts.more) .{ .end = page.facts.end } else null;
        if (page.facts.more) for (page.facts.items[0..page.facts.count]) |item| {
            switch (item.value) {
                .user, .assistant, .tool_result => mark = .{ .end = page.facts.end, .before_position = item.position, .before_ordinal = item.ordinal },
                else => {},
            }
        };
        job.lead.mark = .{ .cursor = mark };
        const pending = try View.pending(requests, job.store, job.session, page.facts.end);
        try pending.render(requests, job.store, job.session, task);
    } else if (page.facts.count != 0) {
        // Everything before this page's first item precedes its live output.
        const first = page.facts.items[0];
        job.lead.mark = .{ .cursor = .{ .end = page.facts.end, .before_position = first.position, .before_ordinal = first.ordinal } };
    }
    try View.render(requests, job.store, job.session, &page, task, job.colour, &job.result.compact_tools);
    if (job.opening) {
        job.result.cursor = .{ .position = page.facts.end };
    } else {
        job.result.cursor = page.continuation() orelse .{ .position = page.facts.end };
        if (!page.facts.more) job.result.cursor.end = null;
    }
    // A read without output commits its footer with its cursor after join.
    job.result.live = job.lead.live.?;
}

fn history(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const latest = job.phase == .details;
    const prepared = try History.prepare(task.requests(), job.store, job.session, if (latest) .{ .end = 0 } else job.older.?, job.scratch);
    // Joined errors before this point retain the cursor without visible content.
    job.result.rendering = true;
    try job.inspection_file.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.inspection_file };
    if (latest) try output.feed("\nRecent conversation — tool details\n");
    try prepared.render(task.io, job.scratch, job.store, job.session, &output, if (latest) .details else .transcript, job.colour);
    if (!latest) job.result.history_cursor = prepared.page.continuation();
}

const DisplayCapture = struct {
    task: *Task,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        try self.file.writePositionalAll(self.task.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

fn inspectPage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.inspection_file, 0);
    var buffer: [4096]u8 = undefined;
    var output = job.inspection_file.writerStreaming(task.io, &buffer);
    if (job.inspection_kind == .help) {
        if (job.inspection_action) |action| {
            const Text = @import("TerminalText.zig");
            try output.interface.writeAll("This Action exceeds the in-app preview. Approval here is disabled.\nDetach with Ctrl-C, inspect the complete exact Action, then decide in your shell:\n");
            for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
                try output.interface.print("rui action {s} --store ", .{command});
                try Text.writeShellWord(&output.interface, job.store);
                try Text.writeShellSession(&output.interface, job.session, false);
                try output.interface.print(" --action {d}\n", .{action});
            }
            try output.interface.writeAll("\n");
        }
        try output.interface.writeAll("Enter sends · Shift-Enter or Alt-J adds a line\nPgUp/PgDn, arrows or the wheel scroll · Esc or Ctrl-G returns to latest or the pending Action\nIn tmux with mouse on, the wheel enters copy mode; use PgUp or arrows\n/status shows whether Bash asks first · an Action takes a or d + Enter\n/status settings and work · /requests recovery handles\n/details saved tool output · /history older conversation\nCtrl-R retries the exact original request, retaining the draft\n/result KEY saved answer · /recover KEY original request\n/discard releases rejected input, retaining the draft\n/setup future defaults · /configure this Session\n/inspect-action exact one-shot diagnostics\n/exit detaches; Host work continues, unsent draft is lost\nLogin: rui auth login codex in your shell.\n");
    } else {
        try job.inspect(job.init, task.requests(), job.store, job.session, if (job.inspection_kind == .status) "/status" else "/requests", &output.interface);
        // Snapshot before launch: this read cannot race Admission settlement.
        if (job.inspection_submission) |submission| {
            try output.interface.print("Original reserved request: {s}\n{s}\n", .{ submission.key, if (submission.state == .rejected) "Submission rejected; /discard releases only this original, retaining the next draft." else "Publication/admission may be incomplete; Ctrl-R retries this exact original." });
            if (submission.last_error) |err| try output.interface.print("Last submission error: {s}\n", .{@errorName(err)});
        }
    }
    try output.flush();
}
