//! One invocation's terminal, draft, read borrower and captured Admission.
//! Construct in final storage. Workers publish results, never terminal output
//! or Input transitions; the UI joins and applies each result exactly once.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Editor = @import("TerminalEditor.zig");
const Task = @import("ClientTask.zig");
const View = @import("SessionView.zig");
const History = @import("SessionHistory.zig");
const TerminalText = @import("TerminalText.zig");
const Self = @This();

pub const Commands = struct {
    parse: *const fn ([]u8, [][]const u8) anyerror!usize,
    // Called only after terminal/read handoff. Draft ownership stays here.
    run: *const fn (*Self, []const []const u8) anyerror!void,
    pick: *const fn (*Self) anyerror!?protocol.Bounded(protocol.max_session_bytes),
};

init: std.process.Init,
commands: Commands,
store: protocol.Bounded(protocol.max_store_bytes),
session: protocol.Bounded(protocol.max_session_bytes) = .{},
target: protocol.Bounded(protocol.max_session_bytes),
directory: []const u8,
scratch: std.Io.File,
terminal: Editor.Terminal,
input: Input = undefined,
reads: Task = .{},
admission: Task = .{},
read_kind: enum { stage, render, page } = .stage,
staged: View.Stage = undefined,
cursor: client.ActivityCursor = .{},
older: client.ConversationCursor = .{},
history_done: bool = false,
permanent_partial: bool = false,
end: u64 = 0,
poll_at: i96 = 0,
selected: bool = false,
dirty: bool = true,
detached: bool = false,
command_pending: bool = false,
// Borrowed only while a CLI command owns its publication/cancellation gate.
// UI cancellation claims that gate before worker stop or any cleanup wait.
command_cancel: ?*const fn () void = null,
focus_buffer: [64]u8 = undefined,
focus_parser: Editor = undefined,
choice_parser: ?*Editor = null,
choice_ready: bool = false,
choice_result: ?Editor.Event = null,
deferred_retry: bool = false,
deferred_approval: bool = false,
pending_notice: ?[]const u8 = null,
fatal: ?anyerror = null,
mask_failure: ?anyerror = null,
borrower: bool = false,
capturing: bool = false,
ticket: ?Input.Ticket = null,
capture_bytes: []const u8 = &.{},
capture_target: client.CaptureTarget = undefined,
capture_store: protocol.Bounded(protocol.max_store_bytes) = .{},
capture_session: protocol.Bounded(protocol.max_session_bytes) = .{},
capture_key: [36]u8 = undefined,
capture_reserved: bool = false,
capture_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
captured: ?client.CapturedRecord = null,
original: ?struct { identity: client.CapturedIdentity, outcome: Input.Outcome } = null,
reply: client.MutationReply = undefined,
reply_buffer: client.ReplyBuffer = .{},

pub fn run(init: std.process.Init, store: []const u8, session: ?[]const u8, directory: []const u8, scratch: std.Io.File, commands: Commands) !void {
    var self: Self = .{
        .init = init,
        .store = .{},
        .target = .{},
        .directory = directory,
        .scratch = scratch,
        .commands = commands,
        .terminal = try Editor.Terminal.begin(init.io),
    };
    self.input.init();
    self.terminal.pump = .{ .context = &self, .service = pump };
    const outcome = self.drive(store, session);
    self.cancelCommand();
    // Restore before any potentially blocked read/capture/drain borrower join.
    // Always settle every owner even when restoration itself failed.
    const restored = self.restoreTerminal();
    self.reads.cancel();
    self.admission.cancel();
    const read_result = self.reads.join();
    const admission_result = self.settleAdmission(true);
    if (self.reads.take() != null) self.reads.acknowledge();
    if (self.captured) |*captured| captured.close(init.io);
    const output_failed = (if (outcome) |_| false else |_| true) or (if (restored) |_| false else |_| true) or
        (if (read_result) |_| false else |err| err != error.Cancelled) or
        (if (admission_result) |_| false else |err| err != error.Cancelled) or
        self.fatal != null or self.mask_failure != null;
    if (output_failed) if (self.original) |original| {
        // Best-effort explanation cannot replace the retained fatal outcome.
        self.originalDiagnostic(&original.identity, original.outcome) catch {};
    };
    try restored;
    if (self.mask_failure) |err| return err;
    if (self.fatal) |err| return err;
    admission_result catch |err| if (err == error.CanonicalStoreFailure) return err;
    read_result catch |err| if (err == error.CanonicalStoreFailure) return err;
    outcome catch |err| if (err == error.CanonicalStoreFailure) return err;
    outcome catch |err| if (err != error.InteractiveInterrupted) return err;
    read_result catch |err| if (err != error.Cancelled) return err;
    admission_result catch |err| if (err != error.Cancelled) return err;
    const detached_notice = "Rui: Detached. Host work continues.\n";
    const vectors = [_]std.posix.iovec_const{.{ .base = detached_notice, .len = detached_notice.len }};
    try Editor.writeAvailable(1, &vectors);
}

fn drive(self: *Self, store: []const u8, session: ?[]const u8) !void {
    try self.store.set(store);
    if (session) |reference| {
        try self.stageTarget(reference);
    } else if (try self.commands.pick(self)) |reference| {
        try self.stageTarget(reference.slice());
    } else {
        self.detached = true;
    }
    while (!self.detached) {
        try self.service();
        try self.step();
    }
}

fn stageTarget(self: *Self, reference: []const u8) !void {
    std.debug.assert(self.reads.thread == null);
    try self.target.set(reference);
    self.read_kind = .stage;
    try self.startTask(&self.reads, self, read);
}

fn originalDiagnostic(self: *Self, original: *const client.CapturedIdentity, outcome: Input.Outcome) !void {
    _ = self;
    // At most twelve escaped bytes per identity byte, plus fixed labels. This
    // is transient final-report storage, not retained output or a retry queue.
    var storage: [12 * (protocol.max_store_bytes + protocol.max_session_bytes + protocol.max_key_bytes) + 256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writer.writeAll(switch (outcome) {
        .accepted => "Rui: Original Admission accepted; do not replace intent.\n",
        .rejected => "Rui: Original Admission rejected; inspect the same saved request.\n",
        .not_sent => "Rui: Original Admission not sent; recover the same saved request.\n",
        .unconfirmed => "Rui: Original Admission unconfirmed; recover the same saved request, never replacement intent.\n",
    });
    inline for (.{ "Store: ", "Session: ", "Key: " }, .{ original.store.slice(), original.session.slice(), original.key.slice() }) |label, value| {
        try writer.writeAll(label);
        var text: TerminalText = .{ .mode = .line };
        try text.feed(&writer, value);
        try text.finish(&writer);
        try writer.writeAll("\n");
    }
    const vectors = [_]std.posix.iovec_const{.{ .base = storage[0..writer.end].ptr, .len = writer.end }};
    Editor.writeDiagnostic(&vectors);
}

fn read(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    switch (self.read_kind) {
        .stage => self.staged = try View.stage(requests, self.store.slice(), self.target.slice(), self.scratch),
        .page => {
            // Separate current attention from the page's captured historical end.
            self.staged.current = try View.inspectCurrent(requests, self.store.slice(), self.session.slice(), self.scratch);
            self.staged.page = switch (try requests.activityPage(self.store.slice(), self.session.slice(), self.cursor)) {
                .page => |page| page,
                .failure => |failure| return failure.err(),
            };
        },
        .render => try View.render(requests, self.store.slice(), self.session.slice(), &self.staged.page, task),
    }
}

fn service(self: *Self) anyerror!void {
    if (self.fatal) |err| return err;
    if (self.reads.take()) |bytes| {
        defer self.reads.acknowledge();
        try self.terminal.writePermanent(self.init.io, bytes);
        if (bytes.len != 0) self.permanent_partial = bytes[bytes.len - 1] != '\n';
        // Do not redraw a footer into the middle of a streamed public value.
        self.dirty = true;
    }
    try self.settleAdmission(false);
    if (self.input.submissionState() == .ready and self.admission.thread == null) {
        self.captured = self.input.capture(self.ticket.?, self) catch |err| {
            self.pending_notice = "Capture failed; recover the original record.";
            if (err == error.CanonicalStoreFailure or self.detached) return err;
            return;
        };
        try self.startSend();
    }
    if (self.deferred_retry and self.admission.thread == null and self.input.submissionState() == .capture_failed) {
        self.deferred_retry = false;
        self.captured = self.input.recover(self.ticket.?, self) catch |err| {
            if (err == error.CanonicalStoreFailure or self.detached) return err;
            self.pending_notice = "Original record unavailable or binding mismatch; nothing sent.";
            return;
        };
        try self.startSend();
    }
    if (self.deferred_retry and self.admission.thread == null and self.captured != null and self.input.submissionState() != .rejected) {
        self.deferred_retry = false;
        try self.startSend();
    }
    if (!self.permanent_partial and self.choice_parser == null) if (self.pending_notice) |message| {
        self.pending_notice = null;
        try self.notice(message);
    };
    if (self.borrower or (self.choice_parser != null and !self.deferred_approval)) {
        // A command's blocked I/O cannot hide ordinary composition edits.
        // Never insert a footer into a partial stream or a focused choice.
        if (self.borrower and self.choice_parser == null and self.dirty and !self.permanent_partial)
            try self.redraw();
        return;
    }
    if (self.reads.completed() and self.reads.thread != null) {
        const finished_kind = self.read_kind;
        self.reads.join() catch |err| {
            if (finished_kind != .stage or !self.selected or err == error.CanonicalStoreFailure) return err;
            try self.notice("Resume metadata unavailable; old Session and draft retained.");
            self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + std.time.ns_per_s;
            return;
        };
        if (finished_kind == .stage) {
            self.session = self.target;
            self.selected = true;
            self.cursor = .{};
            self.older = .{ .end = self.staged.page.facts.end };
            // Conversation's zero cursor means a new traversal, not a frozen
            // empty opening. Do not backfill later rows as "older" history.
            self.history_done = self.staged.page.facts.end == 0;
            for (self.staged.page.facts.items[0..self.staged.page.facts.count]) |item| {
                switch (item.value) {
                    .user, .assistant, .tool_result => {
                        if (self.older.before_position == 0 or item.position < self.older.before_position or
                            (item.position == self.older.before_position and item.ordinal < self.older.before_ordinal))
                        {
                            self.older.before_position = item.position;
                            self.older.before_ordinal = item.ordinal;
                        }
                    },
                    else => {},
                }
            }
            const Sink = struct {
                owner: *Self,
                pub fn feed(s: @This(), bytes: []const u8) !void {
                    try s.owner.write(bytes);
                }
            };
            try View.header(&self.staged, Sink{ .owner = self });
            self.end = self.staged.page.facts.end;
            self.read_kind = .render;
            try self.startTask(&self.reads, self, read);
        } else if (finished_kind == .page) {
            self.read_kind = .render;
            try self.startTask(&self.reads, self, read);
        } else {
            const page = &self.staged.page;
            if (page.facts.direction == .forward and page.continuation() != null) {
                self.cursor = page.continuation().?;
                self.read_kind = .page;
                self.poll_at = 0;
            } else {
                self.end = page.facts.end;
                self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + 250 * std.time.ns_per_ms;
            }
            self.dirty = true;
        }
    }
    try self.serviceCommand();
    if (self.deferred_approval and self.reads.thread == null and self.admission.thread == null) {
        self.deferred_approval = false;
        try self.handoff(&.{"/approve"});
    }
    if (!self.detached and self.selected and self.reads.thread == null and std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
        if (self.read_kind != .page)
            self.cursor = .{ .end = null, .position = self.end, .ordinal = null, .direction = .forward };
        self.read_kind = .page;
        try self.startTask(&self.reads, self, read);
    }
    if (!self.detached and self.dirty and self.reads.thread == null and !self.permanent_partial) try self.redraw();
}

fn settleAdmission(self: *Self, force: bool) !void {
    if (self.capturing) return;
    if (self.admission.thread != null) {
        if (!force and !self.admission.completed()) return;
        const joined = self.admission.join();
        try self.applyAdmission(joined);
        // Interactive transport failure remains recoverable, but a terminal
        // unwind must retain the actual joined failure, not a successful detach.
        if (!self.terminal.active) try joined;
    }
}

/// The recovery worker returns owned decoded facts before fallible display.
/// Only the exact outstanding Message may settle this caller's input custody.
pub fn settleRecovered(self: *Self, reply: client.MutationReply) !void {
    if (self.ticket == null) {
        if (reply.isAccepted()) self.original = .{ .identity = reply.context, .outcome = .accepted };
        return;
    }
    if (!reply.context.kind.eql("message") or !reply.context.store.eql(self.capture_store.slice()) or
        !reply.context.session.eql(self.capture_session.slice()) or !reply.context.key.eql(&self.capture_key)) return;
    const retained = self.input.retained().?.bytes;
    const bytes = if (std.mem.startsWith(u8, retained, "//")) retained[1..] else retained;
    switch (reply.target) {
        .message => |message| {
            if (message.bytes != bytes.len or !std.mem.eql(u8, &message.digest, &protocol.contentDigest(bytes))) return;
        },
        else => return,
    }
    // A concurrent original send still borrows its pinned capture. Join and
    // apply that actual outcome before recovery can release/reopen the owner.
    self.admission.cancel();
    const joined = self.settleAdmission(true);
    if (self.ticket == null or self.input.submissionState() == .rejected) {
        try joined;
        return;
    }
    if (self.input.submissionState() == .capture_failed)
        self.captured = try self.input.recover(self.ticket.?, self);
    try validateOriginal(&self.captured.?, self.capture_store.slice(), self.capture_session.slice(), &self.capture_key, bytes);
    self.reply = reply;
    try self.applyAdmission({});
    try joined;
}

fn applyAdmission(self: *Self, result: anyerror!void) !void {
    if (result) |_| {
        const accepted = self.reply.isAccepted();
        const outcome: Input.Outcome = if (accepted) .accepted else if (self.reply.answer) |_| .rejected else |_| .unconfirmed;
        self.original = .{ .identity = self.captured.?.saved, .outcome = outcome };
        try self.input.resolve(self.ticket.?, outcome);
        self.releaseSettledCapture();
        if (!accepted) {
            self.pending_notice = if (self.ticket == null)
                "Submission rejected; original draft and cursor restored."
            else
                "Submission not accepted; recover the original request, never replacement intent.";
            if (self.reply.answer) |_| {} else |err| if (err == error.CanonicalStoreFailure) {
                self.fatal = err;
                return err;
            }
        }
    } else |err| {
        try self.input.resolve(self.ticket.?, .unconfirmed);
        if (self.captured) |captured| self.original = .{ .identity = captured.saved, .outcome = .unconfirmed };
        self.pending_notice = "Admission unconfirmed. Ctrl-R retries the original capture; editing remains available.";
        if (err == error.CanonicalStoreFailure) {
            self.fatal = err;
            return err;
        }
    }
    self.dirty = true;
}

fn redraw(self: *Self) !void {
    const view = self.input.composition();
    var storage: [256]u8 = undefined;
    var status = std.Io.Writer.fixed(&storage);
    try status.writeAll(if (!self.selected) "Rui: opening" else if (self.borrower) "Rui: command running" else if (self.input.submissionState()) |state| switch (state) {
        .unconfirmed => "Rui: unconfirmed; Ctrl-R original",
        .capture_failed => "Rui: capture failed; /recover KEY",
        .rejected => "Rui: rejected; /discard original",
        .ready, .not_sent => "Rui: submitting; draft retained",
    } else "Rui");
    if (self.selected) {
        const current = &self.staged.current;
        try status.print(": {s}", .{@tagName(current.work.status.value)});
        if (current.pending_messages != 0) try status.print("; pending {d}", .{current.pending_messages});
        if (current.actionable_count != 0) try status.print("; Ctrl-G {d} actionable", .{current.actionable_count});
        if (current.indeterminate_count != 0) try status.print("; indeterminate {d}", .{current.indeterminate_count});
    }
    self.dirty = false;
    try self.terminal.redraw(self.init.io, view.bytes, view.cursor, status.buffered());
}

fn notice(self: *Self, bytes: []const u8) !void {
    try self.terminal.writePermanent(self.init.io, "\nRui: ");
    try self.terminal.writePermanent(self.init.io, bytes);
    try self.terminal.writePermanent(self.init.io, "\n");
    self.permanent_partial = false;
    self.dirty = true;
}

fn releaseSettledCapture(self: *Self) void {
    if (self.input.submissionState() != null) return;
    if (self.captured) |*captured| captured.close(self.init.io);
    self.captured = null;
    self.ticket = null;
    self.deferred_retry = false;
}

fn serviceCommand(self: *Self) !void {
    if (!self.command_pending or self.reads.thread != null) return;
    self.command_pending = false;
    try self.input.withCommand(self);
}

fn feed(self: *Self, byte: u8) Input.Event {
    // Do not seal an Admission against an absent or not-yet-selected target.
    // Parser-owned paste/escape/scalar bytes still belong to Input unchanged.
    const event = self.input.feedForSelection(byte, self.selected and !(self.read_kind == .stage and self.reads.thread != null));
    if (event == .editor and (event.editor == .invalid or event.editor == .overflow)) {
        // Enter completed the rejected attempt. Reset only active composition,
        // never the separately sealed Admission or its outstanding capture loan.
        self.input.clearComposition();
        self.dirty = true;
        self.pending_notice = "Whole input rejected; nothing sent.";
    }
    return event;
}

fn step(self: *Self) !void {
    if (self.choice_parser) |parser| {
        switch (try self.terminal.next(self.init.io, parser.pending())) {
            .tick, .retry, .approve => {},
            .timeout => try parser.expire(),
            .physical_eof => return error.IncompleteTerminalLine,
            .byte => |byte| try self.choiceByte(byte),
        }
        return;
    }
    switch (try self.terminal.next(self.init.io, self.input.pending())) {
        .tick => {},
        .timeout => try self.input.expire(),
        .physical_eof => return error.IncompleteTerminalLine,
        .retry => self.deferred_retry = true,
        .approve => self.requestApproval(),
        .byte => |byte| switch (self.feed(byte)) {
            .message => |ticket| {
                self.ticket = ticket;
                self.dirty = true;
            },
            .command => self.command_pending = true,
            .busy => self.pending_notice = "Submission busy; draft retained.",
            .editor => |event| switch (event) {
                .append, .redraw => self.dirty = true,
                .eof, .interrupt => {
                    self.cancelCommand();
                    self.detached = true;
                },
                .none, .invalid, .overflow => {},
                .submit => unreachable,
            },
        },
    }
    // Approval is deliberate, never a reaction to an unsolicited hint.
}

fn requestApproval(self: *Self) void {
    self.deferred_approval = true;
    if (self.choice_parser == null) {
        self.focus_parser = .{ .buffer = &self.focus_buffer, .allow_paste = false };
        self.choice_parser = &self.focus_parser;
        self.choice_ready = false;
        self.choice_result = null;
    }
}

fn choiceByte(self: *Self, byte: u8) !void {
    const parser = self.choice_parser.?;
    if (self.choice_result) |event| switch (event) {
        .submit, .invalid, .overflow => {
            if (byte == 3) {
                self.cancelCommand();
                self.detached = true;
                return error.InteractiveInterrupted;
            }
            return; // Completed choice bytes remain immutable through output.
        },
        else => {},
    };
    const event = parser.feed(byte);
    if (event == .interrupt or event == .eof) {
        self.cancelCommand();
        self.detached = true;
        return error.InteractiveInterrupted;
    }
    if (self.choice_ready) self.choice_result = event else if (event == .submit) {
        parser.length = 0;
        parser.cursor = 0;
    }
}

// Input.capture holds its sealed-bank loan while the actual worker captures.
// Only ordinary editing is serviced during that loan; no recursive settlement.
pub fn capture(self: *Self, bytes: []const u8) !client.CapturedRecord {
    self.capture_reserved = false;
    self.capture_bytes = bytes;
    self.capture_store = self.store;
    self.capture_session = self.session;
    const target: client.CaptureTarget = .{ .generated = self.directory };
    self.capture_target = .{ .explicit = try target.resolve(self.init.io, &self.capture_path, &self.capture_key) };
    self.capture_reserved = true;
    self.capturing = true;
    defer self.capturing = false;
    try self.startTask(&self.admission, self, captureRun);
    return self.waitCapture();
}

fn joinCapture(self: *Self) !void {
    const joined = self.admission.join();
    // A completed capture still owns recovery identity when UI/mask cleanup
    // fails. Actual capture failure leaves the preceding original fact intact.
    if (self.admission.result()) |result| if (result == .succeeded) {
        self.original = .{ .identity = self.captured.?.saved, .outcome = .not_sent };
    };
    try joined;
}

fn waitCapture(self: *Self) !client.CapturedRecord {
    while (!self.admission.completed()) {
        self.captureStep() catch |err| {
            // The capture borrows the sealed bank through exact join. Restore
            // first, even when disk I/O cannot respond to cancellation yet.
            self.detached = true;
            const restored = self.restoreTerminal();
            self.admission.cancel();
            const joined = self.joinCapture();
            try restored;
            // UI interruption cannot turn an actual capture failure into a
            // successful detach. Cancellation alone leaves captured intent.
            joined catch |failure| if (failure != error.Cancelled) return failure;
            return err;
        };
    }
    try self.joinCapture();
    const captured = self.captured.?;
    self.captured = null;
    return captured;
}

fn captureRun(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.captured = try client.captureMessage(task.io, .{
        .store = self.capture_store.slice(),
        .session = self.capture_session.slice(),
        .text = self.capture_bytes,
        .text_path = "",
    }, self.capture_target);
}

fn captureStep(self: *Self) !void {
    if (self.choice_parser != null) return self.step();
    switch (try self.terminal.next(self.init.io, self.input.pending())) {
        .tick => {},
        .retry => self.deferred_retry = true,
        .approve => self.requestApproval(),
        .timeout => try self.input.expire(),
        .physical_eof => return error.IncompleteTerminalLine,
        .byte => |byte| switch (self.feed(byte)) {
            .editor => |event| switch (event) {
                .interrupt, .eof => return error.InteractiveInterrupted,
                .append, .redraw => self.dirty = true,
                else => {},
            },
            .command => self.command_pending = true,
            // Message remains owned until the loan ends.
            else => {},
        },
    }
}

fn send(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.reply = try task.requests().sendCaptured(&self.captured.?, null, &self.reply_buffer);
}

fn startTask(self: *Self, task: *Task, context: *anyopaque, function: Task.Run) !void {
    return self.startTaskUsing(task, context, function, std.c.sigprocmask);
}

fn startTaskUsing(self: *Self, task: *Task, context: *anyopaque, function: Task.Run, comptime mask: anytype) !void {
    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .INT);
    var previous: std.posix.sigset_t = undefined;
    if (mask(@as(c_int, @intCast(std.posix.SIG.BLOCK)), &blocked, &previous) != 0) return error.SignalMaskBlockFailed;
    const started = task.start(self.init.io, context, function);
    if (mask(@as(c_int, @intCast(std.posix.SIG.SETMASK)), &previous, null) != 0) {
        self.mask_failure = error.SignalMaskRestoreFailed;
        self.cancelCommand();
        self.detached = true;
        // The caller's stack context still lives here. Never return a failed
        // launch with an already-started borrower left outside its join guard.
        const restored = self.restoreTerminal();
        task.cancel();
        if (task == &self.admission and self.capturing) {
            self.joinCapture() catch {}; // Terminal/mask failure outranks worker result.
        } else task.join() catch {}; // Other borrowers retain their ordinary outcome.
        if (task.take() != null) task.acknowledge();
        try restored;
        return error.SignalMaskRestoreFailed;
    }
    try started;
}

pub fn recover(self: *Self, bytes: []const u8) !client.CapturedRecord {
    if (!self.capture_reserved) return error.OriginalKeyUnavailable;
    self.capture_bytes = bytes;
    self.capturing = true;
    defer self.capturing = false;
    try self.startTask(&self.admission, self, recoverRun);
    return self.waitCapture();
}

fn recoverRun(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    var record = try client.openCaptured(task.io, self.directory, &self.capture_key);
    errdefer record.close(task.io);
    try validateOriginal(&record, self.capture_store.slice(), self.capture_session.slice(), &self.capture_key, self.capture_bytes);
    self.captured = record;
}

fn validateOriginal(record: *const client.CapturedRecord, store: []const u8, session: []const u8, key: []const u8, bytes: []const u8) !void {
    if (!record.saved.store.eql(store) or !record.saved.session.eql(session) or !record.saved.key.eql(key) or !record.saved.kind.eql("message")) return error.OriginalBindingMismatch;
    switch (record.target) {
        .message => |message| {
            if (message.bytes != bytes.len or !std.mem.eql(u8, &message.digest, &protocol.contentDigest(bytes))) return error.OriginalBindingMismatch;
        },
        else => return error.OriginalBindingMismatch,
    }
}

fn restoreTerminal(self: *Self) !void {
    try self.terminal.finish();
}

fn cancelCommand(self: *Self) void {
    if (self.command_cancel) |cancel| cancel();
}

fn pump(raw: *anyopaque, io: std.Io, wait: i32) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.detached) {
        try self.settleAdmission(false);
        try std.Io.sleep(io, .fromMilliseconds(wait), .awake);
        return;
    }
    try self.step();
    try self.settleAdmission(false);
    if (self.detached) return error.InteractiveInterrupted;
}

fn startSend(self: *Self) !void {
    self.startTask(&self.admission, self, send) catch |err| {
        try self.sendLaunchFailed(err);
    };
}

fn sendLaunchFailed(self: *Self, err: anyerror) !void {
    if (self.mask_failure != null) if (self.admission.result()) |result| {
        // Failed parent restoration may follow a completed exchange. The
        // launch owner already joined; apply that original outcome only once.
        try self.applyAdmission(switch (result) {
            .succeeded => {},
            .cancelled => error.Cancelled,
            .failed => |failure| failure,
        });
        return err;
    };
    try self.sendNotStarted();
    if (self.mask_failure != null) return err;
}

fn sendNotStarted(self: *Self) !void {
    try self.input.resolve(self.ticket.?, .not_sent);
    if (self.captured) |captured| self.original = .{
        .identity = captured.saved,
        .outcome = if (self.input.submissionState() == .unconfirmed) .unconfirmed else .not_sent,
    };
    self.pending_notice = "Send worker unavailable; Ctrl-R retries the original capture.";
    self.dirty = true;
}

pub fn write(self: *Self, bytes: []const u8) !void {
    try self.terminal.writePermanent(self.init.io, bytes);
    if (bytes.len != 0) self.permanent_partial = bytes[bytes.len - 1] != '\n';
    self.dirty = true;
}

/// Explicit focus only. Preparation may borrow Client reads while this small
/// parser retains input deadlines; it never lends or edits ordinary composition.
/// The returned choice borrows caller storage through its immediate command.
pub fn choose(self: *Self, buffer: []u8, comptime prepare: anytype, args: anytype) !?[]const u8 {
    // Ctrl-G may already own preparation focus while earlier reads drain.
    // Complete its parser custody before replacing that bounded input storage.
    if (self.choice_parser) |prior| while (prior.pending() == .incomplete) try self.step();
    var parser: Editor = .{ .buffer = buffer, .allow_paste = false };
    self.choice_parser = &parser;
    self.choice_ready = false;
    self.choice_result = null;
    defer {
        self.choice_parser = null;
        self.choice_ready = false;
        self.dirty = true;
    }
    if (!try @call(.auto, prepare, .{self} ++ args)) return null;
    // An incomplete prior sequence cannot silently become a later choice.
    while (parser.pending() == .incomplete) try self.step();
    try self.terminal.prepareChoice(self.init.io, &parser);
    parser = .{ .buffer = buffer, .allow_paste = false };
    self.choice_ready = true;
    while (!self.detached) {
        try self.settleAdmission(false);
        try self.step();
        if (self.choice_result) |event| {
            switch (event) {
                .submit => {
                    try self.write("\n");
                    return parser.buffer[0..parser.length];
                },
                .invalid => return error.InvalidTerminalInput,
                .overflow => return error.StreamTooLong,
                .append, .redraw => {
                    self.choice_result = null;
                    try self.terminal.redraw(self.init.io, parser.buffer[0..parser.length], parser.cursor, "Rui: fresh exact choice");
                },
                else => self.choice_result = null,
            }
        }
    }
    return null;
}

pub fn call(self: *Self, comptime function: anytype, args: anytype) !@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args))).error_union.payload {
    return self.borrow(function, args, false);
}

/// Pace a selected command's observations without relinquishing draft service
/// or starting another read while that command still borrows its arguments.
pub fn pause(self: *Self, milliseconds: u64) !void {
    const until = std.Io.Clock.awake.now(self.init.io).nanoseconds + @as(i96, milliseconds) * std.time.ns_per_ms;
    self.borrower = true;
    defer self.borrower = false;
    while (std.Io.Clock.awake.now(self.init.io).nanoseconds < until) {
        try self.service();
        try self.step();
        if (self.detached) return error.InteractiveInterrupted;
    }
}

pub fn stream(self: *Self, comptime function: anytype, args: anytype) !@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args ++ .{@as(*Task, undefined)}))).error_union.payload {
    return self.borrow(function, args, true);
}

fn borrow(self: *Self, comptime function: anytype, args: anytype, comptime streaming: bool) !@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args ++ (if (streaming) .{@as(*Task, undefined)} else .{})))).error_union.payload {
    std.debug.assert(self.reads.thread == null);
    const Result = @TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args ++ (if (streaming) .{@as(*Task, undefined)} else .{})));
    const Context = struct {
        args: @TypeOf(args),
        result: Result = undefined,
        fn run(raw: *anyopaque, task: *Task) !void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            context.result = @call(.auto, function, .{task.requests()} ++ context.args ++ (if (streaming) .{task} else .{}));
        }
    };
    var context: Context = .{ .args = args };
    self.borrower = true;
    defer self.borrower = false;
    try self.startTask(&self.reads, &context, Context.run);
    var joined = false;
    errdefer if (!joined) {
        self.cancelCommand();
        self.restoreTerminal() catch {}; // Failure retained by restore owner.
        self.reads.cancel();
        self.reads.join() catch |err| {
            if (err != error.Cancelled and ((self.fatal orelse error.Cancelled) != error.CanonicalStoreFailure or err == error.CanonicalStoreFailure)) self.fatal = err;
        };
        if (self.reads.take() != null) self.reads.acknowledge();
        // The task wrapper stores the semantic result separately. Cleanup
        // must retain actual failure after an earlier UI error, while local
        // cancellation alone never erases a failure or becomes one itself.
        if (context.result) |_| {} else |err| if (err != error.Cancelled and
            ((self.fatal orelse error.Cancelled) != error.CanonicalStoreFailure or err == error.CanonicalStoreFailure))
        {
            self.fatal = err;
        }
    };
    while (!self.reads.completed()) {
        try self.service();
        try self.step();
        if (self.detached) return error.InteractiveInterrupted;
    }
    // Completion cannot race an unacknowledged successful stream window.
    try self.service();
    try self.reads.join();
    joined = true;
    return context.result catch |err| {
        if (streaming or err == error.CanonicalStoreFailure) self.fatal = err;
        return err;
    };
}

pub fn command(self: *Self, bytes: []u8) !void {
    var argv: [24][]const u8 = undefined;
    const count = self.commands.parse(bytes, &argv) catch {
        try self.notice("Malformed command quoting; no effect sent.");
        return;
    };
    const args = argv[0..count];
    if (count == 0) return;
    if (std.mem.eql(u8, args[0], "/exit") and count == 1) {
        self.detached = true;
        return;
    }
    if (std.mem.eql(u8, args[0], "/recover") and count == 1) {
        self.deferred_retry = true;
        return;
    }
    if (std.mem.eql(u8, args[0], "/discard") and count == 1) {
        if (self.ticket) |ticket| {
            self.input.discardRejected(ticket) catch {
                try self.notice("Only a definite rejected original can be discarded.");
                return;
            };
            if (self.captured) |*captured| captured.close(self.init.io);
            self.captured = null;
            self.ticket = null;
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "/resume") and (count == 1 or count == 2)) {
        if (self.reads.thread != null) {
            try self.notice("Read in progress; old Session and draft retained.");
            return;
        }
        if (count == 2) {
            try self.stageTarget(args[1]);
        } else {
            const picked = self.commands.pick(self) catch |err| {
                if (err != error.ResumeListingUnavailable) return err;
                try self.notice("Resume selection unavailable; old Session and draft retained.");
                return;
            };
            if (picked) |reference| try self.stageTarget(reference.slice());
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "/history") and count == 1) {
        if (self.history_done) {
            try self.notice("No older Conversation rows.");
            return;
        }
        const prepared = self.call(History.prepare, .{ self.store.slice(), self.session.slice(), self.older, self.scratch }) catch |err| {
            if (err == error.CanonicalStoreFailure or self.detached) return err;
            try self.notice("History unavailable; old cursor retained.");
            return;
        };
        if (prepared.continuation()) |next| self.older = next else self.history_done = true;
        if (prepared.page.count == 0) return self.notice("No older Conversation rows.");
        const Sink = struct {
            owner: *Self,
            pub fn feed(s: @This(), text: []const u8) !void {
                try s.owner.write(text);
            }
        };
        try prepared.render(self.init.io, self.scratch, Sink{ .owner = self });
        return;
    }
    if (std.mem.eql(u8, args[0], "/approve") and count == 1) {
        self.requestApproval();
        return;
    }
    try self.handoff(args);
}

fn handoff(self: *Self, args: []const []const u8) !void {
    // Only a completed read can hand off: never cancel/retry a partial value.
    std.debug.assert(self.reads.thread == null);
    self.commands.run(self, args) catch |err| {
        if (self.fatal != null or self.detached or err == error.CanonicalStoreFailure or
            err == error.IncompleteTerminalInput or err == error.IncompleteTerminalLine or
            err == error.TerminalCleanupFailed or err == error.TerminalRestoreFailed or
            err == error.TerminalFlushFailed or err == error.UncertainTerminalCursor) return err;
        try self.notice(@errorName(err));
    };
    self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + std.time.ns_per_s;
    self.dirty = true;
}

test "SessionFrontend opening Enter preserves draft and cursor until selection" {
    var self: Self = undefined;
    self.input.init();
    self.selected = false;
    for ("aéZ\x1b[D") |byte| _ = self.feed(byte);
    try std.testing.expectEqual(.busy, std.meta.activeTag(self.feed('\r')));
    try std.testing.expect(self.input.submissionState() == null);
    try std.testing.expectEqualStrings("aéZ", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), self.input.composition().cursor);
    self.selected = true;
    self.read_kind = .render;
    try std.testing.expectEqual(.message, std.meta.activeTag(self.feed('\r')));
    try std.testing.expectEqualStrings("aéZ", self.input.retained().?.bytes);
}

test "SessionFrontend command stays in Input bank while a read owns the stream" {
    var self: Self = undefined;
    self.input.init();
    self.selected = true;
    self.read_kind = .render;
    self.reads = .{};
    self.command_pending = false;
    self.detached = false;
    const CommandsFixture = struct {
        fn parse(bytes: []u8, argv: [][]const u8) !usize {
            try std.testing.expectEqualStrings("/exit", bytes);
            argv[0] = bytes;
            return 1;
        }
        fn run(_: *Self, _: []const []const u8) !void {
            return error.UnexpectedHandoff;
        }
        fn pick(_: *Self) !?protocol.Bounded(protocol.max_session_bytes) {
            return error.UnexpectedHandoff;
        }
    };
    self.commands = .{ .parse = CommandsFixture.parse, .run = CommandsFixture.run, .pick = CommandsFixture.pick };
    for ("/exit") |byte| _ = self.feed(byte);
    try std.testing.expectEqual(.command, std.meta.activeTag(self.feed('\r')));
    self.command_pending = true;
    // Only nullness is observed: no OS thread or timing-dependent fixture.
    self.reads.thread = @as(std.Thread, undefined);
    try self.serviceCommand();
    try std.testing.expect(self.command_pending);
    try std.testing.expect(!self.detached);
    try std.testing.expect(!self.reads.cancellation.stopped.load(.acquire));
    for ("/next") |byte| _ = self.feed(byte);
    try std.testing.expectEqual(.busy, std.meta.activeTag(self.feed('\r')));
    self.reads.thread = null;
    try self.serviceCommand();
    try std.testing.expect(self.detached);
    try std.testing.expect(!self.command_pending);
    try std.testing.expectEqualStrings("/next", self.input.composition().bytes);
}

test "SessionFrontend pristine rejection releases ticket rather than stale recovery" {
    var self: Self = undefined;
    self.input.init();
    self.selected = true;
    self.read_kind = .render;
    self.captured = null;
    for ("old\x1b[D") |byte| _ = self.feed(byte);
    self.ticket = self.feed('\r').message;
    const Capture = struct {
        pub fn capture(_: @This(), _: []const u8) !void {}
    };
    try self.input.capture(self.ticket.?, Capture{});
    try self.input.resolve(self.ticket.?, .rejected);
    self.releaseSettledCapture();
    try std.testing.expect(self.ticket == null);
    try std.testing.expectEqualStrings("old", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), self.input.composition().cursor);
}

test "SessionFrontend production entry compiles" {
    std.mem.doNotOptimizeAway(&run);
}

test "SessionFrontend settlement is semantic even without output and canonical is retained" {
    var self: Self = undefined;
    self.input.init();
    self.selected = true;
    self.read_kind = .render;
    self.captured = null;
    self.pending_notice = null;
    self.fatal = null;
    for ("original") |byte| _ = self.feed(byte);
    self.ticket = self.feed('\r').message;
    const Capture = struct {
        pub fn capture(_: @This(), _: []const u8) !void {}
    };
    try self.input.capture(self.ticket.?, Capture{});
    try self.sendNotStarted();
    try std.testing.expectEqual(Input.State.not_sent, self.input.submissionState().?);
    try self.applyAdmission(error.ConnectionLost);
    try self.sendNotStarted();
    try std.testing.expectEqual(Input.State.unconfirmed, self.input.submissionState().?);
    try std.testing.expectError(error.CanonicalStoreFailure, self.applyAdmission(error.CanonicalStoreFailure));
    try std.testing.expectEqual(error.CanonicalStoreFailure, self.fatal.?);
    try std.testing.expectEqualStrings("original", self.input.retained().?.bytes);

    const Worker = struct {
        fn fail(_: *anyopaque, _: *Task) !void {
            return error.ConnectionLost;
        }
    };
    self.init.io = std.testing.io;
    self.admission = .{};
    self.capturing = false;
    self.captured = .{
        .file = undefined, // Failure settlement borrows identity, never reads/closes it.
        .length = 0,
        .saved = .{},
        .target = .{ .message = .{ .bytes = 8, .digest = protocol.contentDigest("original") } },
    };
    try self.captured.?.saved.store.set("store/original");
    try self.captured.?.saved.session.set("session/original");
    try self.captured.?.saved.key.set("key/original");
    try self.captured.?.saved.kind.set("message");
    self.fatal = null;
    self.terminal.active = true;
    try self.admission.start(std.testing.io, &self, Worker.fail);
    try self.settleAdmission(true); // Ordinary interactive failure stays recoverable.
    self.terminal.active = false;
    try self.admission.start(std.testing.io, &self, Worker.fail);
    try std.testing.expectError(error.ConnectionLost, self.settleAdmission(true));
    try std.testing.expect(self.admission.thread == null);
    try std.testing.expectEqual(Input.State.unconfirmed, self.input.submissionState().?);
    try std.testing.expectEqualStrings("original", self.input.retained().?.bytes);
    try std.testing.expectEqual(Input.Outcome.unconfirmed, self.original.?.outcome);
    try std.testing.expectEqualStrings("store/original", self.original.?.identity.store.slice());
    try std.testing.expectEqualStrings("session/original", self.original.?.identity.session.slice());
    try std.testing.expectEqualStrings("key/original", self.original.?.identity.key.slice());
}

test "SessionFrontend original recovery checks destination key bytes and scoped digest" {
    var record: client.CapturedRecord = .{
        .file = undefined,
        .length = 0,
        .saved = .{},
        .target = .{ .message = .{ .bytes = 4, .digest = protocol.contentDigest("text") } },
    };
    try record.saved.store.set("store");
    try record.saved.session.set("session");
    try record.saved.key.set("key");
    try record.saved.kind.set("message");
    try validateOriginal(&record, "store", "session", "key", "text");
    try std.testing.expectError(error.OriginalBindingMismatch, validateOriginal(&record, "other", "session", "key", "text"));
    try std.testing.expectError(error.OriginalBindingMismatch, validateOriginal(&record, "store", "other", "key", "text"));
    try std.testing.expectError(error.OriginalBindingMismatch, validateOriginal(&record, "store", "session", "other", "text"));
    try std.testing.expectError(error.OriginalBindingMismatch, validateOriginal(&record, "store", "session", "key", "next"));
    try std.testing.expectError(error.OriginalBindingMismatch, validateOriginal(&record, "store", "session", "key", "text!"));
}

test "SessionFrontend call and stream adapters compile with typed result" {
    const Fixture = struct {
        fn request(_: client.Requests, value: u32) !u32 {
            return value;
        }
        fn requestStream(_: client.Requests, value: u32, sink: *Task) !u32 {
            try sink.feed("value\n");
            return value;
        }
        fn adapters(self: *Self) !void {
            const value: u32 = try self.call(request, .{@as(u32, 42)});
            _ = try self.stream(requestStream, .{value});
        }
    };
    std.mem.doNotOptimizeAway(&Fixture.adapters);
}

test "SessionFrontend approval takes preparation focus before held read joins" {
    var self: Self = undefined;
    self.input.init();
    self.selected = true;
    self.read_kind = .render;
    self.choice_parser = null;
    self.choice_ready = false;
    self.choice_result = null;
    self.detached = false;
    for ("éZ\x1b[D") |byte| _ = self.feed(byte);
    self.requestApproval();
    try std.testing.expect(self.choice_parser != null);
    for ("a\n") |byte| try self.choiceByte(byte);
    try std.testing.expect(self.input.submissionState() == null);
    try std.testing.expectEqualStrings("éZ", self.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), self.input.composition().cursor);
}

test "SessionFrontend fresh choice remains sealed while output pumps later bytes" {
    var self: Self = undefined;
    self.input.init();
    var buffer: [64]u8 = undefined;
    var parser: Editor = .{ .buffer = &buffer, .allow_paste = false };
    self.choice_parser = &parser;
    self.choice_ready = true;
    self.choice_result = null;
    self.detached = false;
    try self.choiceByte('a');
    try self.choiceByte('\n');
    try self.choiceByte('X');
    try std.testing.expectEqual(Editor.Event.submit, self.choice_result.?);
    try std.testing.expectEqualStrings("a", parser.buffer[0..parser.length]);
}

test "SessionFrontend cancellation claims scoped command gate before detaching" {
    const Fixture = struct {
        var called = false;
        var owner: *Self = undefined;
        fn cancel() void {
            std.debug.assert(!owner.detached);
            called = true;
        }
    };
    var self: Self = undefined;
    var buffer: [16]u8 = undefined;
    var parser: Editor = .{ .buffer = &buffer };
    self.choice_parser = &parser;
    self.choice_result = null;
    self.choice_ready = true;
    self.detached = false;
    self.command_cancel = Fixture.cancel;
    Fixture.owner = &self;
    Fixture.called = false;
    try std.testing.expectError(error.InteractiveInterrupted, self.choiceByte(3));
    try std.testing.expect(Fixture.called);
    try std.testing.expect(self.detached);
}

test "SessionFrontend released terminal retains restoration failure ahead of worker failure" {
    var self: Self = undefined;
    self.terminal.active = false;
    self.terminal.finish_result = error.TerminalRestoreFailed;
    self.fatal = error.CanonicalStoreFailure;
    try std.testing.expectError(error.TerminalRestoreFailed, self.restoreTerminal());
    self.terminal.finish_result = error.TerminalCleanupFailed;
    try std.testing.expectError(error.TerminalCleanupFailed, self.restoreTerminal());
}

test "SessionFrontend borrower cleanup retains actual failure but not cancellation after input fails" {
    const Worker = struct {
        fn request(_: client.Requests) !void {
            return error.CanonicalStoreFailure;
        }
        fn failed(_: client.Requests) !void {
            return error.TestReadFailure;
        }
        fn cancelled(_: client.Requests) !void {
            return error.Cancelled;
        }
    };
    var self: Self = undefined;
    self.init.io = std.testing.io;
    self.reads = .{};
    self.terminal.active = false;
    self.terminal.finish_result = {};
    self.fatal = error.TestInputFailure;
    self.command_cancel = null;
    try std.testing.expectError(error.TestInputFailure, self.call(Worker.request, .{}));
    try std.testing.expect(self.reads.thread == null);
    try std.testing.expectEqual(error.CanonicalStoreFailure, self.fatal.?);
    self.fatal = error.TestInputFailure;
    try std.testing.expectError(error.TestInputFailure, self.call(Worker.failed, .{}));
    try std.testing.expect(self.reads.thread == null);
    try std.testing.expectEqual(error.TestReadFailure, self.fatal.?);
    self.fatal = error.TestInputFailure;
    try std.testing.expectError(error.TestInputFailure, self.call(Worker.cancelled, .{}));
    try std.testing.expect(self.reads.thread == null);
    try std.testing.expectEqual(error.TestInputFailure, self.fatal.?);
}

test "SessionFrontend worker inherits blocked SIGINT and parent mask is restored" {
    const Worker = struct {
        blocked: bool = false,
        fn run(raw: *anyopaque, _: *Task) !void {
            const worker: *@This() = @ptrCast(@alignCast(raw));
            var current = std.posix.sigemptyset();
            if (std.c.sigprocmask(@intCast(std.posix.SIG.SETMASK), null, &current) != 0) return error.TestMaskReadFailed;
            worker.blocked = std.posix.sigismember(&current, .INT);
        }
    };
    var before = std.posix.sigemptyset();
    try std.testing.expectEqual(0, std.c.sigprocmask(@intCast(std.posix.SIG.SETMASK), null, &before));
    var self: Self = undefined;
    self.init.io = std.testing.io;
    self.reads = .{};
    var worker: Worker = .{};
    try self.startTask(&self.reads, &worker, Worker.run);
    try self.reads.join();
    try std.testing.expect(worker.blocked);
    var after = std.posix.sigemptyset();
    try std.testing.expectEqual(0, std.c.sigprocmask(@intCast(std.posix.SIG.SETMASK), null, &after));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "SessionFrontend failed parent mask restore joins launched borrower and retains precedence" {
    const Worker = struct {
        finished: bool = false,
        fn run(raw: *anyopaque, task: *Task) !void {
            const worker: *@This() = @ptrCast(@alignCast(raw));
            defer worker.finished = true;
            try task.feed("borrowed");
        }
    };
    const Mask = struct {
        fn failRestore(how: c_int, _: ?*const std.posix.sigset_t, previous: ?*std.posix.sigset_t) c_int {
            if (previous) |old| old.* = std.posix.sigemptyset();
            return if (how == std.posix.SIG.SETMASK) -1 else 0;
        }
        fn failBlock(_: c_int, _: ?*const std.posix.sigset_t, _: ?*std.posix.sigset_t) c_int {
            return -1;
        }
    };
    for ([_]?anyerror{ null, error.TerminalRestoreFailed }) |terminal_error| {
        var self: Self = undefined;
        self.init.io = std.testing.io;
        self.reads = .{};
        self.terminal.active = false;
        self.terminal.finish_result = if (terminal_error) |err| err else {};
        self.mask_failure = null;
        self.command_cancel = null;
        self.detached = false;
        var worker: Worker = .{};
        defer {
            self.reads.cancel();
            self.reads.join() catch {};
            if (self.reads.take() != null) self.reads.acknowledge();
        }
        try std.testing.expectError(terminal_error orelse error.SignalMaskRestoreFailed, self.startTaskUsing(&self.reads, &worker, Worker.run, Mask.failRestore));
        try std.testing.expect(worker.finished and self.detached);
        try std.testing.expect(self.reads.thread == null and self.reads.take() == null);
        try std.testing.expectEqual(error.SignalMaskRestoreFailed, self.mask_failure.?);
        self.mask_failure = null;
        worker.finished = false;
        try std.testing.expectError(error.SignalMaskBlockFailed, self.startTaskUsing(&self.reads, &worker, Worker.run, Mask.failBlock));
        try std.testing.expect(!worker.finished and self.reads.thread == null);
        try std.testing.expect(self.mask_failure == null);
    }
}

test "SessionFrontend mask failure settles already joined accepted or uncertain Admission" {
    for ([_]Task.Result{ .succeeded, .cancelled, .{ .failed = error.ConnectionLost } }) |result| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var self: Self = undefined;
        self.init.io = std.testing.io;
        self.input.init();
        self.selected = true;
        self.read_kind = .render;
        self.admission = .{ .terminal = result };
        self.mask_failure = error.SignalMaskRestoreFailed;
        self.original = null;
        self.fatal = null;
        self.deferred_retry = false;
        for ("original") |byte| _ = self.feed(byte);
        self.ticket = self.feed('\r').message;
        const Capture = struct {
            pub fn capture(_: @This(), _: []const u8) !void {}
        };
        try self.input.capture(self.ticket.?, Capture{});
        self.captured = .{ .file = try tmp.dir.createFile(std.testing.io, "capture", .{}), .length = 0, .saved = .{}, .target = undefined };
        defer if (self.captured) |*captured| captured.close(std.testing.io);
        try self.captured.?.saved.store.set("original-store");
        try self.captured.?.saved.session.set("original-session");
        try self.captured.?.saved.key.set("original-key");
        self.reply = .{ .status = 200, .target = undefined, .answer = .{ .result = .{ .accepted = .{ .message = .{ .admission = 7 } } }, .replayed = false } };
        try std.testing.expectError(error.SignalMaskRestoreFailed, self.sendLaunchFailed(error.SignalMaskRestoreFailed));
        try std.testing.expect(self.original != null);
        try std.testing.expectEqualStrings("original-key", self.original.?.identity.key.slice());
        if (result == .succeeded) {
            try std.testing.expectEqual(Input.Outcome.accepted, self.original.?.outcome);
            try std.testing.expect(self.ticket == null and self.captured == null);
        } else {
            try std.testing.expectEqual(Input.State.unconfirmed, self.input.submissionState().?);
            try std.testing.expectEqualStrings("original", self.input.retained().?.bytes);
            try std.testing.expectEqual(Input.Outcome.unconfirmed, self.original.?.outcome);
        }
    }
}
