//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const client = @import("client.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const Terminal = @import("SessionTerminal.zig");
const Editor = @import("TerminalEditor.zig");
const View = @import("session_view.zig");
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const ConsentPolicy = @import("session_consent.zig");
const Self = @This();

pub const Command = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []u8) anyerror!void;
const ReadPhase = departure.ReadPhase;
const ReadEnd = departure.ReadEnd;
const AdmissionEnd = Submission.End;
const Settled = departure.Settled;
init: std.process.Init,
store: []const u8,
session: []const u8,
directory: []const u8,
scratch: std.Io.File,
command: Command,
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
history_cursor: ?client.ConversationCursor = null,
next_history_cursor: ?client.ConversationCursor = null,
history_requested: ?enum { older, latest } = null,
read_phase: ReadPhase = .activity,
read_columns: usize = 0,
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
notice_buffer: [512]u8 = undefined,
previous_signals: [2]std.posix.Sigaction = undefined,

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

pub fn run(init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, scratch: std.Io.File, command: Command, initial_text: ?[]const u8) !void {
    const no_colour: []const u8 = init.environ_map.get("NO_COLOR") orelse "";
    const colour = no_colour.len == 0 and !std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb");
    var self: Self = .{ .init = init, .store = store, .session = session, .directory = directory, .scratch = scratch, .command = command, .terminal = undefined, .colour = colour };
    self.input.init();
    self.submission = .{ .io = init.io, .store = store, .session = session, .directory = directory, .input = &self.input };
    interrupted.stopped.store(false, .release);
    self.signals(true);
    defer self.signals(false);
    self.terminal = try Terminal.begin(colour);
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
    if (plan.failure) |err| return err;
    self.terminal.detached(store, session) catch |err| {
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
    if (initial_text) |text| try self.submission.begin(.{ .message = self.input.submitText(text) });
    while (!self.detached) {
        self.driveActive() catch |err| {
            const failure = departure.activeFailure(err, interrupted.stopped.load(.acquire));
            if (failure != error.CommandHandoff) return failure;
            try self.handoff();
        };
    }
}

fn pendingHandoff(self: *Self) bool {
    return self.input.command_length != null;
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
        try std.testing.expectEqual(error.CanonicalStoreFailure, departure.activeFailure(failure, true));
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
        var self: Self = .{ .init = undefined, .store = "unused", .session = "unused", .directory = "unused", .scratch = undefined, .command = undefined, .terminal = .{ .original = undefined, .flags = undefined, .colour = false, .active = false, .result = error.TerminalRestoreFailed }, .colour = false, .read_phase = phase };
        self.init.io = std.testing.io;
        self.input.init();
        self.submission = .{ .io = std.testing.io, .store = self.store, .session = self.session, .directory = self.directory, .input = &self.input, .intent = .{ .message = self.input.submitText("current original B") } };
        try self.reader.start(std.testing.io, &self, Worker.read);
        try self.submission.task.start(std.testing.io, &self, Worker.admit);
        while (self.reader.take() == null) std.Thread.yield() catch {};
        self.reader_output_started = true;
        const settled = self.quiesce();
        try std.testing.expectEqual(error.TerminalRestoreFailed, settled.failure(.handoff, error.InteractiveInterrupted).?);
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
        if (self.pendingHandoff()) return error.CommandHandoff;
        const admission = try self.submission.advance();
        try self.presentAdmission(admission);
        if (admission.failure()) |err| if (err == error.CanonicalStoreFailure) return err;
        if (self.reader.take()) |bytes| {
            if (bytes.len != 0) {
                self.reader_output_started = true;
                try self.terminal.permanent(bytes);
            }
            self.reader.acknowledge();
        }
        if (self.reader.thread != null and self.reader.completed()) try self.settleReader();
        if (self.pending_diagnostic) |pending| {
            if (pending.recoverable) try self.presentReadDiagnostic(&self.terminal);
        }
        if (self.reader.thread == null and (!self.consent.active() or self.history_requested != null) and self.prepared_action == null) {
            self.read_columns = Terminal.geometry().col;
            if (self.history_requested != null and !self.opening) {
                const requested = self.history_requested.?;
                self.history_requested = null;
                if (requested == .latest or self.history_cursor != null) {
                    self.read_phase = if (requested == .latest) .details else .history;
                    self.history_render_started = false;
                    self.reader_output_started = false;
                    try self.reader.start(self.init.io, self, history);
                } else self.notice = "  No older Conversation rows.";
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                self.read_phase = .activity;
                self.reader_output_started = false;
                try self.reader.start(self.init.io, self, scan);
            } else if (!self.opening and self.submission.view() == null and self.current.first_action != null and self.input.pending() == .none) {
                self.read_phase = .permission;
                self.prepared_action = null;
                self.reader_output_started = false;
                try self.reader.start(self.init.io, self, permission);
            }
        }
        // A transcript stream is indivisible: notices cannot split its text.
        if (self.notice != null and !self.opening and (self.reader.thread == null or !self.reader_output_started)) {
            const notice = self.notice.?;
            self.notice = null;
            try self.terminal.permanent("\n");
            try self.terminal.permanent((if (std.mem.startsWith(u8, notice, "!")) View.Style.failure else View.Style.normal).code(self.colour));
            try self.terminal.permanent(notice);
            try self.terminal.permanent(View.Style.normal.code(self.colour));
            try self.terminal.permanent("\n");
            self.dirty = true;
        }
        for (0..1024) |_| {
            if (try self.step(0) != .byte) break;
            if (self.detached) break;
        }
        if (self.detached) break;
        if (self.pendingHandoff()) return error.CommandHandoff;
        // Finish chat paste/UTF-8 under its original decoder before consent.
        if (self.reader.thread == null and self.prepared_action != null and self.input.pending() == .none) {
            self.consent.adopt(self.prepared_action.?);
            self.prepared_action = null;
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.read_phase = .activity;
            self.dirty = true;
        }
        if (self.dirty and !self.opening and (self.reader.thread == null or !self.reader_output_started)) {
            const view: Input.View = if (self.consent.active()) .{ .bytes = self.choice.buffer[0..self.choice.length], .cursor = self.choice.cursor } else self.input.composition();
            const status = if (self.consent.active()) "a: Allow once / d: Deny (Enter)" else if (self.submission.view()) |submission| switch (submission.state) {
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
            self.dirty = false;
            try self.terminal.redraw(view.bytes, view.cursor, status, if (self.consent.active()) "> " else "› ", &self.live);
            if (self.consent.active() and !self.consent.acceptsInput() and self.choice.pending() == .none) {
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
                if (self.consent.promptCompleted(service, self.choice.pending() != .none, self.pendingHandoff())) {
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
    // Unwind the terminal write and its window loan before handing off.
    if (self.pendingHandoff()) return error.CommandHandoff;
}

fn step(self: *Self, wait: i32) !ConsentPolicy.Service {
    // The selected handoff owns the next transition, including queued bytes.
    if (self.pendingHandoff()) return .handoff;
    const pending = if (self.consent.active()) self.choice.pending() else self.input.pending();
    const byte = (self.terminal.next(self.init.io, pending, wait) catch |err| switch (err) {
        error.InputDeadline => {
            if (self.consent.active()) try self.choice.expire() else try self.input.expire();
            // Successful expiry releases decoder custody. Revisit redraw and
            // its drained-input readiness gate, just as after ordinary input.
            self.dirty = true;
            return .decoder_expired;
        },
        else => return err,
    }) orelse return if (pending == .none) .empty else .decoder_pending;
    if (self.consent.active()) {
        if (!self.consent.acceptsInput()) {
            // Discard text but retain fragmented input's decoder custody.
            const event = self.choice.feed(byte);
            if (event == .interrupt or event == .eof) {
                self.consent.interrupt();
                self.detached = true;
            }
            if (self.choice.pending() == .none) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.dirty = true;
            return .byte;
        }
        switch (self.choice.feed(byte)) {
            .submit => {
                const text = self.choice.buffer[0..self.choice.length];
                if (self.consent.submit(text)) |decision| {
                    try self.submission.begin(.{ .decision = .{ .action = decision.action, .decision = if (decision.choice == .allow_once) .allow_once else .deny } });
                } else if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/details") or std.mem.eql(u8, text, "/history")) {
                    self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
                } else if (std.mem.startsWith(u8, text, "/")) {
                    @memcpy(self.input.command_buffer[0..text.len], text);
                    self.input.command_length = text.len;
                } else self.notice = "! Choose a or d. Nothing authorized.";
                self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            },
            .invalid, .overflow => {
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
    switch (self.input.feedSelected(byte, !self.opening and self.read_phase != .permission and (submission == null or submission.?.kind == .message))) {
        .message => |ticket| {
            try self.submission.begin(.{ .message = ticket });
        },
        .command => {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/history") or std.mem.eql(u8, text, "/details")) {
                // Local read work never cancels the independent Admission owner.
                self.input.command_length = null;
                self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
            }
        },
        .busy => self.notice = if (submission != null and submission.?.state == .rejected) "! Original rejected. Keep editing; /discard releases it. Draft retained." else if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (submission != null and submission.?.kind == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .interrupt, .eof => self.detached = true,
            .invalid => self.notice = "! Input rejected; nothing sent. Enter plain text or paste again.",
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
    self.applyReader(end);
    if (end.failure(.active)) |err| return err;
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
    var bytes: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try out.writeAll(if (pending.phase == .details) "! Details unavailable; draft retained. " else "! History unavailable; older cursor and draft retained. ");
    try self.writePendingDiagnostic(&out);
    try sink.permanent("\n");
    try sink.permanent(View.Style.failure.code(self.colour));
    try sink.permanent(out.buffered());
    try sink.permanent(View.Style.normal.code(self.colour));
    try sink.permanent("\n");
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
            self.terminal = .{ .original = undefined, .flags = undefined, .colour = false, .active = false };
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
            try std.testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.length], if (phase == .details) "Details unavailable" else "History unavailable") != null);
        }
    }
}

fn applyReader(self: *Self, end: ReadEnd) void {
    if (end.preparationFailure()) {
        if (self.pending_diagnostic == null)
            self.notice = if (self.read_phase == .details) "! Details unavailable; draft retained." else "! History unavailable; older cursor and draft retained.";
        self.dirty = true;
        return;
    }
    if (end != .complete) return;
    if (self.read_phase == .history) {
        self.history_cursor = self.next_history_cursor;
        self.notice = "  History page complete.";
    } else if (self.read_phase == .details) {
        self.notice = "  Details complete.";
    } else if (self.read_phase == .permission) {
        self.current = self.observed;
        self.live = self.observed_live;
        self.cursor = self.next_cursor;
        if (self.prepared_action == null) self.read_phase = .activity;
    } else {
        self.current = self.observed;
        self.live = self.observed_live;
        self.cursor = self.next_cursor;
        if (self.opening) self.history_cursor = self.next_history_cursor;
        self.opening = false;
    }
    self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
    self.dirty = true;
}

fn handoff(self: *Self) !void {
    const settled = self.quiesce();
    self.applyReader(settled.reader);
    try departure.handoff(settled, interrupted.stopped.load(.acquire));
    const result = self.dispatchCommand();
    try departure.commandReturn(result, interrupted.stopped.load(.acquire));
    self.terminal = try Terminal.begin(self.colour);
    self.terminal.pump = .{ .context = self, .step = pump };
    self.consent.invalidate();
    self.dirty = true;
}

fn dispatchCommand(self: *Self) !void {
    try std.Io.File.stdout().writeStreamingAll(self.init.io, "\n");
    {
        const text = self.input.command_buffer[0..self.input.command_length.?];
        defer self.input.command_length = null;
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
        } else if (std.mem.eql(u8, text, "/help")) {
            try std.Io.File.stdout().writeStreamingAll(self.init.io, "Actions show their command here. Type a + Enter to allow once, d + Enter to deny.\n/status settings and work · /inspect-action exact diagnostics\n/details recent conversation with full saved tool output\n/history older conversation\nCtrl-R: retry the same unconfirmed input or decision, keeping the draft\n/requests recovery records · /result KEY saved answer\n/setup future defaults · /configure Session settings\n/recover KEY original intent · /discard rejected intent\n/exit detach (Host work continues; unsent draft is lost)\nLogin: rui login codex in your shell.\n");
        } else {
            try self.command(self.init, .{ .io = self.init.io, .cancellation = &interrupted }, self.store, self.session, text);
            if (self.submission.view()) |submission| if (std.mem.eql(u8, text, "/status") or std.mem.eql(u8, text, "/requests")) {
                // A reserved key is diagnostic identity, not proof that a
                // capture exists. Ctrl-R also repairs prepublication failure.
                try std.Io.File.stdout().writeStreamingAll(self.init.io, "Original reserved request: ");
                try std.Io.File.stdout().writeStreamingAll(self.init.io, &submission.key);
                try std.Io.File.stdout().writeStreamingAll(self.init.io, if (submission.state == .rejected) "\nSubmission rejected; /discard releases only this original, retaining the next draft.\n" else "\nPublication/admission may be incomplete; Ctrl-R retries this exact original.\n");
                if (submission.last_error) |err| {
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, "Last submission error: ");
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, @errorName(err));
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, "\n");
                }
            };
        }
    }
}

fn permission(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (self.observed.first_action) |action| {
        try View.permission(task.requests(), self.store, self.session, action, self.observed.settings.workspace.slice(), self.scratch, task, self.read_columns, self.colour);
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
        const pending = try View.pending(requests, self.store, self.session, page.facts.end);
        try pending.render(requests, self.store, self.session, task);
    }
    try View.render(requests, self.store, self.session, &page, task, self.read_columns, self.colour);
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
    const prepared = try History.prepare(task.requests(), self.store, self.session, if (latest) .{ .end = 0 } else self.history_cursor.?, self.scratch);
    // Joined errors before this point retain the cursor without visible content.
    self.history_render_started = true;
    if (latest) try task.feed("\nRecent conversation — tool details\n");
    try prepared.render(task.io, self.scratch, self.store, self.session, task, self.read_columns, self.colour);
    if (!latest) self.next_history_cursor = prepared.page.continuation();
}
