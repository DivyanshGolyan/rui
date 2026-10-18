//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const client = @import("client.zig");
const Input = @import("SessionInput.zig");
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
command_text: [@typeInfo(@FieldType(Input, "command_buffer")).array.len]u8 = undefined,
command_text_length: usize = 0,
inspection_submission: ?Submission.View = null,
inspection_action: ?u64 = null,
terminal: Terminal,
colour: bool,
input: Input = undefined,
submission: Submission = undefined,
reader: Task = .{},
current: client.Current = undefined,
observed: client.Current = undefined,
live: View.Live = .{},
observed_live: View.Live = .{},
cursor: client.ActivityCursor = .{},
next_cursor: client.ActivityCursor = .{},
// UI commits layout alongside delivered Activity; workers borrow a snapshot.
compact_tools: bool = false,
next_compact_tools: bool = false,
next_history_cursor: ?client.ConversationCursor = null,
// Continues the transcript above its oldest shown row; null at the start.
transcript_older: ?client.ConversationCursor = null,
// A failed older load waits for the next scroll rather than retrying at once.
older_failed: bool = false,
history_requested: ?enum { older, latest } = null,
// Where each read's live output began, so a transcript whose live copy lost
// its front still continues from a canonical position without a gap.
marks: Marks = .{},
read_mark: ?client.ConversationCursor = null,
read_phase: ReadPhase = .activity,
// Worker result is inspected only after join; input policy stays UI-owned.
history_render_started: bool = false,
prepared_action: ?u64 = null,
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
    if (plan.failure) |err| {
        switch (err) {
            error.TerminalTooSmall => @import("TerminalText.zig").diagnostic("rui: Enlarge the terminal and resume this Session. Required instructions do not fit; nothing was authorized by the clipped view.\n", .{}),
            error.TerminalTooLarge => @import("TerminalText.zig").diagnostic("rui: Rui supports at most 49,152 terminal cells (for example 256 × 192). Shrink the terminal and resume; saved content is unchanged.\n", .{}),
            error.OutOfMemory, error.UnrepresentableTerminalGrapheme, error.DisplayGraphemeTooLarge => @import("TerminalText.zig").diagnostic("rui: This frame exceeds Rui's bounded display. Shrink the terminal and resume; saved content is unchanged. Ordinary message, result and inspect-action commands remain available.\n", .{}),
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
    const restored = self.terminal.finish();
    self.reader.cancel();
    self.submission.cancel();
    const reader = self.joinReader();
    const admission = self.joinAdmission();
    if (self.reader.take() != null) self.reader.acknowledge();
    return .{ .restored = restored, .reader = reader, .admission_error = admission.failure() };
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
        .uncertain => |key| try out.print("rui: Capture not confirmed. Inspect rui requests for reserved key {s}; reservation does not prove publication. Recover only that original, never replacement input.\n", .{key}),
        .saved => |saved| {
            if (saved.rejected) {
                try out.print("rui: Original request rejected. Use rui recover {s} to inspect its saved outcome.\n", .{saved.original.key});
            } else try out.print("rui: {s} not confirmed. Use rui recover {s} to retry the exact original; do not resubmit it.\n", .{ if (saved.original.kind == .decision) "Decision" else "Message", saved.original.key });
        },
        .accepted => |accepted| {
            if (accepted.kind == .message) {
                try out.print("rui: Message accepted; do not resubmit it. Use rui result {s} to inspect the same Message.\n", .{accepted.key});
            } else try out.print("rui: Decision accepted; do not repeat it. Use rui recover {s} to inspect the same saved admission.\n", .{accepted.key});
        },
    }
}

test "frontend exit guidance preserves accepted identity and never substitutes it for current intent" {
    const key = "01234567-89ab-4cde-8012-0123456789ab";
    const cases = .{
        .{ Submission.Kind.message, "rui: Message accepted; do not resubmit it. Use rui result " ++ key ++ " to inspect the same Message.\n" },
        .{ Submission.Kind.decision, "rui: Decision accepted; do not repeat it. Use rui recover " ++ key ++ " to inspect the same saved admission.\n" },
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
        self.notice = "Login uses rui login codex in your shell.";
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
                if (!self.reader_output_started and live) self.marks.record(self.terminal.screen.liveEnd(), self.read_mark);
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
        if (self.reader.thread == null and self.input.command_length != null) {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            const kind = inspection(text).?;
            try self.terminal.screen.latest();
            // The worker borrows its own copy; the editor may queue another.
            @memcpy(self.command_text[0..text.len], text);
            self.command_text_length = text.len;
            self.inspection_kind = kind;
            self.inspection_submission = self.submission.view();
            self.inspection_action = if (self.consent.presentation == .preview) self.consent.action else null;
            self.read_phase = .inspection;
            self.history_render_started = false;
            self.reader_output_started = false;
            try self.reader.start(self.init.io, self, if (kind == .command) runCommand else inspectPage);
            self.input.command_length = null;
        }
        if (self.reader.thread == null and (!self.consent.active() or self.history_requested != null or self.olderWanted()) and self.prepared_action == null) {
            if (self.history_requested != null and !self.opening) {
                const requested = self.history_requested.?;
                self.history_requested = null;
                if (requested == .latest) {
                    try self.terminal.screen.latest();
                    self.read_phase = .details;
                    self.history_render_started = false;
                    self.reader_output_started = false;
                    try self.reader.start(self.init.io, self, history);
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
                self.read_phase = .history;
                self.history_render_started = false;
                self.reader_output_started = false;
                self.notice = "Loading earlier messages…";
                try self.reader.start(self.init.io, self, history);
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                self.read_phase = .activity;
                self.reader_output_started = false;
                self.next_compact_tools = self.compact_tools;
                try self.reader.start(self.init.io, self, scan);
            } else if (!self.opening and self.submission.view() == null and self.current.first_action != null and self.input.pending() == .none) {
                self.read_phase = .permission;
                self.prepared_action = null;
                self.reader_output_started = false;
                self.next_compact_tools = self.compact_tools;
                try self.reader.start(self.init.io, self, permission);
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
            self.prepared_action = null;
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.read_phase = .activity;
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
            } else switch (self.current.work.status.value) {
                .runnable, .in_flight => "Working…",
                .waiting_for_permission => "Needs approval",
                .failed => "Work failed · /status",
                .cancelled => "Work stopped · /status",
                .idle, .completed => "",
            };
            var status_buffer: [2048]u8 = undefined;
            var status = std.Io.Writer.fixed(&status_buffer);
            if (self.notice) |notice| try status.print("{s}\n", .{notice});
            try status.writeAll(base_status);
            if (!self.opening and self.current.settings.tools.bash and self.current.settings.permission_mode.value == .bypass)
                try status.writeAll("\nBash runs without approval.");
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
            if (self.consent.active() and action_visible and self.actionVisible() and !self.dirty and !self.consent.acceptsInput() and self.choice.pending() == .none) {
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
                if (self.consent.promptCompleted(service, self.choice.pending() != .none, self.input.command_length != null or !self.actionVisible() or self.dirty)) {
                    try Editor.testChoiceReady(self.init.io);
                }
            }
        }
        _ = try self.step(16);
    }
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

fn approvalReady(self: *const Self) bool {
    if (!self.actionVisible()) return false;
    const size = self.terminal.geometry();
    return size.row == self.terminal.size.row and size.col == self.terminal.size.col and self.terminal.screen.approvalReady();
}

fn navigation(self: *Self, event: Editor.Event, editor: *const Editor) !void {
    const screen = self.terminal.screen;
    switch (event) {
        .width_report => screen.setWidth(editor.input.report.?.width),
        .scroll_report => try self.terminal.enableAlternateScroll(),
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
    const pending = if (self.consent.active()) self.choice.pending() else self.input.pending();
    const byte = (self.terminal.next(self.init.io, pending, wait) catch |err| switch (err) {
        error.InputDeadline => {
            const event = if (self.consent.active()) try self.choice.expire() else try self.input.expire();
            if (event != .none) try self.navigation(event, if (self.consent.active()) &self.choice else &self.input.editors[self.input.active]);
            // Successful expiry releases decoder custody. Revisit redraw and
            // its drained-input readiness gate, just as after ordinary input.
            self.dirty = true;
            return .decoder_expired;
        },
        else => return err,
    }) orelse return if (pending == .none) .empty else .decoder_pending;
    self.notice = null;
    if (self.consent.active()) {
        const visible = self.actionVisible();
        if (!visible) self.consent.invalidate();
        if (visible and !self.consent.acceptsInput()) {
            // Discard text but retain fragmented input's decoder custody.
            const event = self.choice.feed(byte);
            if (event == .interrupt or event == .eof) {
                self.consent.interrupt();
                self.detached = true;
            }
            try self.navigation(event, &self.choice);
            if (self.choice.pending() == .none) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.dirty = true;
            return .byte;
        }
        const event = self.choice.feed(byte);
        try self.navigation(event, &self.choice);
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
                } else if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/details") or std.mem.eql(u8, text, "/history")) {
                    self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
                } else if (std.mem.startsWith(u8, text, "/")) {
                    if (self.input.command_length == null) {
                        @memcpy(self.input.command_buffer[0..text.len], text);
                        self.input.command_length = text.len;
                        self.admitCommand();
                    } else self.notice = "! Preparing inspection; try again when it finishes.";
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
        self.dirty = true;
        return .byte;
    }
    if (self.input.pending() == .none) switch (byte) {
        18 => {
            try self.submission.requestRecovery(null);
            return .byte;
        },
        else => {},
    };
    const submission = self.submission.view();
    // A Message waits for a pending command, which may change its configuration.
    switch (self.input.feedSelected(byte, !self.opening and self.read_phase != .permission and self.input.command_length == null and (submission == null or submission.?.kind == .message))) {
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
        .busy => self.notice = if (self.input.command_length != null) "! Command still running. Draft retained." else if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .width_report, .scroll_report, .page_up, .page_down, .scroll_up, .scroll_down, .latest, .close_view => try self.navigation(event, &self.input.editors[self.input.active]),
            .interrupt, .eof => self.detached = true,
            .invalid, .edit_rejected => self.notice = "! Input rejected; nothing sent. Enter plain text or paste again.",
            .overflow => self.notice = "! input too long; nothing sent. Draft cleared. Enter a shorter message.",
            else => {},
        },
    }
    self.dirty = true;
    return .byte;
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
    if (end.failure(mode)) |err| return err;
    if (end == .complete and self.read_phase == .history) {
        // The user may have left the transcript while this page loaded.
        const screen = self.terminal.screen;
        if (screen.view == .transcript) {
            try screen.prependFile(self.init.io, self.inspection_file);
            self.transcript_older = self.next_history_cursor;
            if (self.transcript_older == null) try screen.markBeginning();
        }
    } else if (end == .complete and (self.read_phase == .details or self.read_phase == .inspection)) {
        try self.showInspection();
    }
    self.applyReader(end);
}

fn joinReader(self: *Self) ReadEnd {
    if (self.reader.thread == null) return .absent;
    const result = self.reader.join();
    const progress: ReadEnd.Progress = .{ .phase = self.read_phase, .rendering = self.history_render_started, .output_owned = self.reader_output_started };
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
        self.compact_tools = if (self.read_phase == .activity or self.read_phase == .permission) self.next_compact_tools else false;
    if (self.read_phase == .history) {
        self.notice = null; // Clears "Loading older conversation…".
    } else if (self.read_phase == .details or self.read_phase == .inspection) {
        // showInspection selected the notice.
    } else if (self.read_phase == .permission) {
        self.current = self.observed;
        self.live = self.observed_live;
        self.cursor = self.next_cursor;
        if (self.prepared_action == null) self.read_phase = .activity;
    } else {
        self.current = self.observed;
        self.live = self.observed_live;
        self.cursor = self.next_cursor;
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
            .observed = std.mem.zeroes(client.Current),
            .cursor = .{ .position = 7 },
            .next_cursor = .{ .position = 12 },
            .compact_tools = case.prior,
            .next_compact_tools = case.next,
            .reader_output_started = case.output,
        };
        self.init.io = std.testing.io;
        self.applyReader(case.end);
        try std.testing.expectEqual(case.expected, self.compact_tools);
        try std.testing.expectEqual(@as(u64, if (case.end == .complete) 12 else 7), self.cursor.position);
    }
}

fn showInspection(self: *Self) !void {
    if ((try self.inspection_file.stat(self.init.io)).size == 0) {
        self.notice = "Command finished with no output.";
        return;
    }
    try self.terminal.screen.showFile(self.init.io, self.inspection_file, false);
    self.notice = Frame.inspection_ready;
    self.consent.invalidate();
    if (self.consent.active()) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
}

/// Host commands keep their one-shot output owners. Their complete stdout and
/// stderr become an inspection page while the Session screen keeps drawing
/// through its own descriptor. No command reads terminal input.
fn runCommand(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, self.inspection_file, 0);
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    defer for (saved) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    if (saved[0] < 0 or saved[1] < 0) return error.TerminalCleanupFailed;
    // Redirected descriptors are output custody: any failure now is fatal.
    self.history_render_started = true;
    const page = self.inspection_file.handle;
    const result = if (std.c.dup2(page, 1) < 0 or std.c.dup2(page, 2) < 0) error.TerminalCleanupFailed else self.command(self.init, .{ .io = task.io, .cancellation = &task.cancellation }, self.store, self.session, self.command_text[0..self.command_text_length]);
    if (std.c.dup2(saved[0], 1) < 0 or std.c.dup2(saved[1], 2) < 0) return error.TerminalCleanupFailed;
    return result;
}

fn permission(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (self.observed.first_action) |action| {
        try self.action_file.setLength(task.io, 0);
        var output: DisplayCapture = .{ .task = task, .file = self.action_file };
        try View.permission(task.requests(), self.store, self.session, action, self.observed.settings.workspace.slice(), self.scratch, &output, self.colour);
        self.next_compact_tools = false;
        self.prepared_action = action;
    }
}

fn scan(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    self.observed = try View.current(requests, self.store, self.session, self.scratch);
    var cursor = self.cursor;
    if (self.opening) cursor.direction = .backward;
    const page = switch (try requests.activityPage(self.store, self.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    if (self.opening) {
        self.next_history_cursor = if (page.facts.more) .{ .end = page.facts.end } else null;
        if (page.facts.more) for (page.facts.items[0..page.facts.count]) |item| {
            switch (item.value) {
                .user, .assistant, .tool_result => self.next_history_cursor = .{ .end = page.facts.end, .before_position = item.position, .before_ordinal = item.ordinal },
                else => {},
            }
        };
        self.read_mark = self.next_history_cursor;
        const pending = try View.pending(requests, self.store, self.session, page.facts.end);
        try pending.render(requests, self.store, self.session, task);
    } else if (page.facts.count != 0) {
        // Everything before this page's first item precedes its live output.
        const first = page.facts.items[0];
        self.read_mark = .{ .end = page.facts.end, .before_position = first.position, .before_ordinal = first.ordinal };
    }
    try View.render(requests, self.store, self.session, &page, task, self.colour, &self.next_compact_tools);
    if (self.opening) {
        self.next_cursor = .{ .position = page.facts.end };
    } else {
        self.next_cursor = page.continuation() orelse .{ .position = page.facts.end };
        if (!page.facts.more) self.next_cursor.end = null;
    }
    // The worker publishes this bounded snapshot only after every result window
    // was acknowledged; applyReader commits it alongside that successful cursor.
    self.observed_live = View.Live.init(page.facts.call_activity);
}

fn history(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const latest = self.read_phase == .details;
    const prepared = try History.prepare(task.requests(), self.store, self.session, if (latest) .{ .end = 0 } else self.transcript_older.?, self.scratch);
    // Joined errors before this point retain the cursor without visible content.
    self.history_render_started = true;
    try self.inspection_file.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = self.inspection_file };
    if (latest) try output.feed("\nRecent conversation — tool details\n");
    try prepared.render(task.io, self.scratch, self.store, self.session, &output, if (latest) .details else .transcript, self.colour);
    if (!latest) self.next_history_cursor = prepared.page.continuation();
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
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, self.inspection_file, 0);
    var buffer: [4096]u8 = undefined;
    var output = self.inspection_file.writerStreaming(task.io, &buffer);
    if (self.inspection_kind == .help) {
        if (self.inspection_action) |action| {
            const Text = @import("TerminalText.zig");
            try output.interface.writeAll("This Action exceeds the in-app preview. Approval here is disabled.\nDetach with Ctrl-C, inspect the complete exact Action, then decide in your shell:\n");
            for ([_][]const u8{ "inspect-action", "allow-action", "deny-action" }) |command| {
                try output.interface.print("rui {s} --store ", .{command});
                try Text.writeShellWord(&output.interface, self.store);
                try Text.writeShellSession(&output.interface, self.session, false);
                try output.interface.print(" --action {d}\n", .{action});
            }
            try output.interface.writeAll("\n");
        }
        try output.interface.writeAll("Enter sends · Shift-Enter or Alt-J adds a line\nPgUp/PgDn, arrows or the wheel scroll · Esc or Ctrl-G returns to latest or the pending Action\nIn tmux with mouse on, the wheel enters copy mode; use PgUp or arrows\nWhen approval is enabled: a + Enter allows once, d + Enter denies\n/status settings and work · /requests recovery handles\n/details saved tool output · /history older conversation\nCtrl-R retries the exact original request, retaining the draft\n/result KEY saved answer · /recover KEY original request\n/discard releases rejected input, retaining the draft\n/setup future defaults · /configure this Session\n/inspect-action exact one-shot diagnostics\n/exit detaches; Host work continues, unsent draft is lost\nLogin: rui login codex in your shell.\n");
    } else {
        try self.inspect(self.init, task.requests(), self.store, self.session, if (self.inspection_kind == .status) "/status" else "/requests", &output.interface);
        // Snapshot before launch: this read cannot race Admission settlement.
        if (self.inspection_submission) |submission| {
            try output.interface.print("Original reserved request: {s}\n{s}\n", .{ submission.key, if (submission.state == .rejected) "Submission rejected; /discard releases only this original, retaining the next draft." else "Publication/admission may be incomplete; Ctrl-R retries this exact original." });
            if (submission.last_error) |err| try output.interface.print("Last submission error: {s}\n", .{@errorName(err)});
        }
    }
    try output.flush();
}
