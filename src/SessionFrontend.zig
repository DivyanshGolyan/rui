//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Task = @import("ClientTask.zig");
const Terminal = @import("SessionTerminal.zig");
const Editor = @import("TerminalEditor.zig");
const View = @import("session_view.zig");
const History = @import("session_history.zig");
const Self = @This();

pub const Command = *const fn (std.process.Init, []const u8, []const u8, []u8) anyerror!void;
const Submission = union(enum) {
    message: Input.Ticket,
    decision: struct { action: u64, decision: protocol.PermissionDecision, state: Input.State = .submitting },
};
init: std.process.Init,
store: []const u8,
session: []const u8,
directory: []const u8,
scratch: std.Io.File,
command: Command,
terminal: Terminal,
input: Input = undefined,
admission: Task = .{},
reader: Task = .{},
submission: ?Submission = null,
capture_key: [36]u8 = undefined,
capture_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
capture_target: client.CaptureTarget = undefined,
captured: ?client.CapturedRecord = null,
reply_buffer: client.ReplyBuffer = .{},
reply: ?client.MutationReply = null,
current: client.Current = undefined,
observed: client.Current = undefined,
cursor: client.ActivityCursor = .{},
next_cursor: client.ActivityCursor = .{},
history_cursor: ?client.ConversationCursor = null,
next_history_cursor: ?client.ConversationCursor = null,
history_requested: ?enum { older, latest } = null,
read_phase: enum { activity, history, details, permission } = .activity,
read_columns: usize = 0,
// Worker result is inspected only after join; input policy stays UI-owned.
history_render_started: bool = false,
prepared_action: ?u64 = null,
permission_output_started: bool = false,
choice_action: ?u64 = null,
choice_buffer: [64]u8 = undefined,
choice: Editor = undefined,
choice_ready: bool = false,
opening: bool = true,
poll_at: i96 = 0,
dirty: bool = true,
detached: bool = false,
retry: ?[36]u8 = null,
notice: ?[]const u8 = null,
notice_buffer: [512]u8 = undefined,
previous_signals: [2]std.posix.Sigaction = undefined,

var interrupted = std.atomic.Value(bool).init(false);
fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

fn signals(self: *Self, install: bool) void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    inline for (.{ std.posix.SIG.INT, std.posix.SIG.TERM }, 0..) |signal, i| {
        if (install) std.posix.sigaction(signal, &action, &self.previous_signals[i]) else std.posix.sigaction(signal, &self.previous_signals[i], null);
    }
}

pub fn run(init: std.process.Init, store: []const u8, session: []const u8, directory: []const u8, scratch: std.Io.File, command: Command) !void {
    var self: Self = .{ .init = init, .store = store, .session = session, .directory = directory, .scratch = scratch, .command = command, .terminal = undefined };
    self.input.init();
    interrupted.store(false, .release);
    self.signals(true);
    defer self.signals(false);
    self.terminal = try Terminal.begin();
    self.terminal.pump = .{ .context = &self, .step = pump };
    const result = self.drive();
    const restored = self.terminal.finish();
    self.reader.cancel();
    self.admission.cancel();
    const read_result = self.reader.join();
    const admission_result = self.settleAdmission();
    if (self.reader.take() != null) self.reader.acknowledge();
    if (self.captured) |*capture| capture.close(init.io);
    try restored;
    read_result catch |err| if (err == error.CanonicalStoreFailure) return err;
    admission_result catch |err| if (err == error.CanonicalStoreFailure) return err;
    result catch |err| if (err != error.InteractiveInterrupted) return err;
    read_result catch |err| if (err != error.Cancelled) return err;
    admission_result catch |err| if (err != error.Cancelled) return err;
    try self.terminal.detached();
}

fn drive(self: *Self) !void {
    while (!self.detached) {
        self.driveActive() catch |err| {
            if (interrupted.load(.acquire)) return error.InteractiveInterrupted;
            if (err != error.CommandHandoff) return err;
            try self.handoff();
        };
    }
}

fn pendingHandoff(self: *Self) bool {
    return self.input.command_length != null;
}

fn requestRetry(self: *Self) void {
    self.retry = if (self.submission != null and self.submissionState() != .rejected) self.capture_key else null;
}

fn submissionState(self: *const Self) Input.State {
    return switch (self.submission.?) {
        .message => self.input.submitted.?.state,
        .decision => |decision| decision.state,
    };
}

fn settleSubmission(self: *Self, state: ?Input.State) !void {
    switch (self.submission.?) {
        .message => |ticket| try self.input.settle(ticket, state),
        .decision => {
            if (state) |value| self.submission.?.decision.state = value;
        },
    }
    if (state == null) {
        if (self.captured) |*capture| capture.close(self.init.io);
        self.captured = null;
        self.submission = null;
        self.poll_at = 0;
    }
}

fn startSubmission(self: *Self, submission: Submission) !void {
    std.debug.assert(self.submission == null);
    self.submission = submission;
    const target: client.CaptureTarget = .{ .generated = self.directory };
    self.capture_target = .{ .explicit = try target.resolve(self.init.io, &self.capture_path, &self.capture_key) };
    self.reply = null;
    try self.admission.start(self.init.io, self, submit);
}

fn driveActive(self: *Self) !void {
    while (!self.detached) {
        if (interrupted.load(.acquire)) return error.InteractiveInterrupted;
        if (self.pendingHandoff()) return error.CommandHandoff;
        if (self.admission.thread != null and self.admission.completed()) {
            self.settleAdmission() catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                self.notice = if (self.submission.? == .decision) "! Decision not confirmed. Draft retained." else "! Not confirmed. Next draft retained.";
            };
            self.dirty = true;
        }
        if (self.reader.take()) |bytes| {
            if (self.read_phase == .permission) self.permission_output_started = true;
            try self.terminal.permanent(bytes);
            self.reader.acknowledge();
        }
        if (self.reader.thread != null and self.reader.completed()) try self.settleReader();
        if (self.admission.thread == null) if (self.retry) |requested| {
            self.retry = null;
            if (self.submission != null) {
                if (std.mem.eql(u8, &requested, &self.capture_key) and self.submissionState() != .rejected)
                    try self.admission.start(self.init.io, self, resend);
            }
        };
        if (self.reader.thread == null and (self.choice_action == null or self.history_requested != null) and self.prepared_action == null) {
            self.read_columns = Terminal.geometry().col;
            if (self.history_requested != null and !self.opening) {
                const requested = self.history_requested.?;
                self.history_requested = null;
                if (requested == .latest or self.history_cursor != null) {
                    self.read_phase = if (requested == .latest) .details else .history;
                    self.history_render_started = false;
                    try self.reader.start(self.init.io, self, history);
                } else self.notice = "  No older Conversation rows.";
            } else if (std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at) {
                self.read_phase = .activity;
                try self.reader.start(self.init.io, self, scan);
            } else if (!self.opening and self.submission == null and self.current.first_action != null and self.input.pending() == .none) {
                self.read_phase = .permission;
                self.prepared_action = null;
                self.permission_output_started = false;
                try self.reader.start(self.init.io, self, permission);
            }
        }
        // A transcript stream is indivisible: notices cannot split its text.
        if (self.notice != null and self.reader.thread == null) {
            const notice = self.notice.?;
            self.notice = null;
            try self.terminal.permanent("\n");
            try self.terminal.permanent(notice);
            try self.terminal.permanent("\n");
            self.dirty = true;
        }
        for (0..1024) |_| {
            if (!try self.step(0)) break;
            if (self.detached) break;
        }
        if (self.detached) break;
        if (self.pendingHandoff()) return error.CommandHandoff;
        // Finish chat paste/UTF-8 under its original decoder before consent.
        if (self.reader.thread == null and self.prepared_action != null and self.input.pending() == .none) {
            self.choice_action = self.prepared_action;
            self.prepared_action = null;
            self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.choice_ready = false;
            self.read_phase = .activity;
            self.dirty = true;
        }
        if (self.dirty and !self.opening and (self.reader.thread == null or self.read_phase == .permission and !self.permission_output_started)) {
            const view: Input.View = if (self.choice_action != null) .{ .bytes = self.choice.buffer[0..self.choice.length], .cursor = self.choice.cursor } else self.input.composition();
            const status = if (self.choice_action != null) "a: Allow once / d: Deny (Enter)" else if (self.submission != null) switch (self.submissionState()) {
                .submitting => "Sending…",
                .unconfirmed => "Unconfirmed · Ctrl-R retries original",
                .rejected => "Rejected · /discard",
            } else switch (self.current.work.status.value) {
                .runnable, .in_flight => "Working…",
                .waiting_for_permission => "Needs approval",
                .failed => "Work failed · /status",
                .cancelled => "Work stopped · /status",
                .idle, .completed => "",
            };
            self.dirty = false;
            try self.terminal.redraw(view.bytes, view.cursor, status, if (self.choice_action != null) "> " else "rui> ");
            if (self.choice_action != null and !self.choice_ready and self.choice.pending() == .none) {
                try Editor.freshChoice(self.init.io);
                self.choice_ready = true;
            }
        }
        _ = try self.step(16);
    }
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = try self.step(16);
    if (self.detached or interrupted.load(.acquire)) return error.InteractiveInterrupted;
    // Unwind the terminal write and its window loan before handing off.
    if (self.pendingHandoff()) return error.CommandHandoff;
}

fn step(self: *Self, wait: i32) !bool {
    // The selected handoff owns the next transition, including queued bytes.
    if (self.pendingHandoff()) return false;
    const pending = if (self.choice_action != null) self.choice.pending() else self.input.pending();
    const byte = (self.terminal.next(self.init.io, pending, wait) catch |err| switch (err) {
        error.InputDeadline => {
            if (self.choice_action != null) try self.choice.expire() else try self.input.expire();
            return false;
        },
        else => return err,
    }) orelse return false;
    if (self.choice_action) |action| {
        if (!self.choice_ready) {
            // Discard text but retain fragmented input's decoder custody.
            const event = self.choice.feed(byte);
            if (event == .interrupt or event == .eof) self.detached = true;
            if (self.choice.pending() == .none) self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
            self.dirty = true;
            return true;
        }
        switch (self.choice.feed(byte)) {
            .submit => {
                const text = self.choice.buffer[0..self.choice.length];
                if (std.mem.eql(u8, text, "a") or std.mem.eql(u8, text, "d")) {
                    self.choice_action = null;
                    try self.startSubmission(.{ .decision = .{ .action = action, .decision = if (text[0] == 'a') .allow_once else .deny } });
                } else if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/details") or std.mem.eql(u8, text, "/history")) {
                    self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
                } else if (std.mem.startsWith(u8, text, "/")) {
                    @memcpy(self.input.command_buffer[0..text.len], text);
                    self.input.command_length = text.len;
                } else self.notice = "! Choose a or d. Nothing authorized.";
                self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
                self.choice_ready = false;
            },
            .invalid, .overflow => {
                self.choice = .{ .buffer = &self.choice_buffer, .allow_paste = false };
                self.choice_ready = false;
                self.notice = "! Decision input rejected. Type a or d; pasted text cannot authorize.";
            },
            .interrupt, .eof => self.detached = true,
            else => {},
        }
        self.dirty = true;
        return true;
    }
    if (self.input.pending() == .none) switch (byte) {
        18 => {
            self.requestRetry();
            return true;
        },
        else => {},
    };
    switch (self.input.feedSelected(byte, !self.opening and self.read_phase != .permission and (self.submission == null or self.submission.? == .message))) {
        .message => |ticket| {
            try self.startSubmission(.{ .message = ticket });
        },
        .command => {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            if (std.mem.eql(u8, text, "/exit")) self.detached = true else if (std.mem.eql(u8, text, "/history") or std.mem.eql(u8, text, "/details")) {
                // Local read work never cancels the independent Admission owner.
                self.input.command_length = null;
                self.history_requested = if (std.mem.eql(u8, text, "/details")) .latest else .older;
            }
        },
        .busy => self.notice = if (self.read_phase == .permission) "! Action needs a decision. Draft retained." else if (self.submission != null and self.submission.? == .decision) "! Decision pending. Keep editing; Ctrl-R retries that decision." else "! Input still pending. Keep editing; Ctrl-R retries the original.",
        .editor => |event| switch (event) {
            .interrupt, .eof => self.detached = true,
            .invalid => self.notice = "! Input rejected; nothing sent.",
            .overflow => self.notice = "! input too long; nothing sent. Use rui message --text FILE for longer input.",
            else => {},
        },
    }
    self.dirty = true;
    return true;
}

fn submit(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
    self.captured = switch (self.submission.?) {
        .message => |ticket| try client.captureMessage(task.io, .{ .store = self.store, .session = self.session, .text_path = "", .text = try self.input.message(ticket) }, self.capture_target),
        .decision => |decision| try client.capturePermissionDecision(task.io, .{ .store = self.store, .session = self.session, .action_id = decision.action, .decision = decision.decision }, self.capture_target),
    };
    self.reply = try task.requests().sendCaptured(&self.captured.?, null, &self.reply_buffer);
}

fn resend(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.captured == null) {
        // Capture never returned, hence send never began. Reconcile publication
        // first; absent publication may be retried with the SAME reserved intent.
        self.captured = client.openCaptured(task.io, self.directory, &self.capture_key) catch |err| switch (err) {
            error.FileNotFound => return submit(raw, task),
            else => return err,
        };
        errdefer {
            self.captured.?.close(task.io);
            self.captured = null;
        }
        const capture = &self.captured.?;
        if (!capture.saved.store.eql(self.store) or !capture.saved.session.eql(self.session) or !capture.saved.key.eql(&self.capture_key)) return error.OriginalBindingMismatch;
        switch (self.submission.?) {
            .message => |ticket| {
                const bytes = try self.input.message(ticket);
                if (!capture.saved.kind.eql("message") or capture.target != .message or capture.target.message.bytes != bytes.len or !std.mem.eql(u8, &capture.target.message.digest, &protocol.contentDigest(bytes))) return error.OriginalBindingMismatch;
            },
            .decision => |decision| if (!capture.saved.kind.eql("permission_decision") or capture.target != .permission_decision or capture.target.permission_decision.action != decision.action or capture.target.permission_decision.decision != decision.decision) return error.OriginalBindingMismatch,
        }
    }
    self.reply = try task.requests().sendCaptured(&self.captured.?, null, &self.reply_buffer);
}

fn settleAdmission(self: *Self) !void {
    if (self.admission.thread == null) return;
    const result = self.admission.join();
    result catch |err| {
        try self.settleSubmission(.unconfirmed);
        return err;
    };
    const reply = self.reply.?;
    const answer = reply.answer catch |err| {
        try self.settleSubmission(.unconfirmed);
        return err;
    };
    if (reply.isAccepted()) {
        if (self.submissionState() == .unconfirmed) self.notice = if (self.submission.? == .decision) "  • Decision confirmed." else "  • Original confirmed.";
        try self.settleSubmission(null);
    } else {
        try self.settleSubmission(.rejected);
        var writer = std.Io.Writer.fixed(&self.notice_buffer);
        var text: @import("TerminalText.zig") = .{ .mode = .line };
        try writer.writeAll(if (self.submission.? == .decision) "! Decision rejected: " else "! Input rejected: ");
        try text.feed(&writer, if (answer.result == .rejected) answer.result.rejected.slice() else "request conflict");
        try text.finish(&writer);
        try writer.writeAll(". /discard clears it; the next draft is safe.");
        self.notice = writer.buffered();
    }
}

fn settleReader(self: *Self) !void {
    if (self.reader.thread == null) return;
    self.reader.join() catch |err| {
        if ((self.read_phase != .history and self.read_phase != .details) or self.history_render_started or err == error.CanonicalStoreFailure or err == error.Cancelled) return err;
        self.notice = if (self.read_phase == .details) "! Details unavailable; draft retained." else "! History unavailable; older cursor and draft retained.";
        self.dirty = true;
        return;
    };
    if (self.read_phase == .history) {
        self.history_cursor = self.next_history_cursor;
        self.notice = "  History page complete.";
    } else if (self.read_phase == .details) {
        self.notice = "  Details complete.";
    } else if (self.read_phase == .permission) {
        self.current = self.observed;
        if (self.prepared_action == null) self.read_phase = .activity;
    } else {
        self.current = self.observed;
        self.cursor = self.next_cursor;
        if (self.opening) self.history_cursor = self.next_history_cursor;
        self.opening = false;
    }
    self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
    self.dirty = true;
}

fn handoff(self: *Self) !void {
    const restored = self.terminal.finish();
    self.reader.cancel();
    self.admission.cancel();
    const read_result = self.settleReader();
    const joined = self.settleAdmission();
    if (self.reader.take() != null) self.reader.acknowledge();
    try restored;
    read_result catch |err| if (err == error.CanonicalStoreFailure) return err;
    joined catch |err| if (err == error.CanonicalStoreFailure) return err;
    read_result catch |err| {
        if (err != error.Cancelled) return err;
        self.notice = "! Activity observation interrupted; displayed prefix may be incomplete. Host work unchanged.";
    };
    joined catch {
        self.notice = if (read_result) |_|
            "! Not confirmed. Ctrl-R retries the original; the next draft is safe."
        else |_|
            "! Observation interrupted; displayed text may be incomplete. Not confirmed. Ctrl-R retries the original; the next draft is safe.";
    };
    if (interrupted.load(.acquire)) return error.InteractiveInterrupted;
    try std.Io.File.stdout().writeStreamingAll(self.init.io, "\n");
    {
        self.signals(false);
        defer self.signals(true);
        {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            defer self.input.command_length = null;
            if (std.mem.eql(u8, text, "/discard")) {
                if (self.submission != null) {
                    if (self.submissionState() == .rejected) {
                        try self.settleSubmission(null);
                    } else self.notice = "! Cannot discard an unresolved submission; Ctrl-R recovers the original.";
                }
            } else if (std.mem.startsWith(u8, text, "/recover ") and self.submission != null) {
                if (std.mem.eql(u8, text[9..], &self.capture_key)) self.requestRetry() else self.notice = "! Recovery key does not match this original submission; nothing sent.";
            } else if (std.mem.eql(u8, text, "/wait") or std.mem.eql(u8, text, "/login")) {
                self.notice = "! Actions ask here when ready. Login uses rui login codex in your shell.";
            } else if (std.mem.eql(u8, text, "/help")) {
                try std.Io.File.stdout().writeStreamingAll(self.init.io, "Actions show their command here. Type a + Enter to allow once, d + Enter to deny.\n/status settings and work · /inspect-action exact diagnostics\n/details recent conversation with full saved tool output\n/history older conversation\nCtrl-R: retry the same unconfirmed input or decision, keeping the draft\n/requests recovery records · /result KEY saved answer\n/setup future defaults · /configure Session settings\n/recover KEY original intent · /discard rejected intent\n/exit detach (Host work continues; unsent draft is lost)\nLogin: rui login codex in your shell.\n");
            } else {
                try self.command(self.init, self.store, self.session, text);
                if (self.submission != null and (std.mem.eql(u8, text, "/status") or std.mem.eql(u8, text, "/requests"))) {
                    // A reserved key is diagnostic identity, not proof that a
                    // capture exists. Ctrl-R also repairs prepublication failure.
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, "Original reserved request: ");
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, &self.capture_key);
                    try std.Io.File.stdout().writeStreamingAll(self.init.io, if (self.submissionState() == .rejected) "\nSubmission rejected; /discard releases only this original, retaining the next draft.\n" else "\nPublication/admission may be incomplete; Ctrl-R retries this exact original.\n");
                }
            }
        }
    }
    self.terminal = try Terminal.begin();
    self.terminal.pump = .{ .context = self, .step = pump };
    self.choice_ready = false;
    self.dirty = true;
}

fn permission(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.observed = try View.current(task.requests(), self.store, self.session, self.scratch);
    if (self.observed.first_action) |action| {
        try View.permission(task.requests(), self.store, self.session, action, self.observed.settings.workspace.slice(), self.scratch, task, self.read_columns);
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
        .failure => |failure| return failure.err(),
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
    try View.render(requests, self.store, self.session, &page, task, self.read_columns);
    if (self.opening) {
        self.next_cursor = .{ .position = page.facts.end };
        return;
    }
    self.next_cursor = page.continuation() orelse .{ .position = page.facts.end };
    if (page.facts.more) return;
    self.next_cursor.end = null;
}

fn history(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const latest = self.read_phase == .details;
    const prepared = try History.prepare(task.requests(), self.store, self.session, if (latest) .{ .end = 0 } else self.history_cursor.?, self.scratch);
    // Joined errors before this point retain the cursor without visible content.
    self.history_render_started = true;
    if (latest) try task.feed("\nRecent conversation — tool details\n");
    try prepared.render(task.io, self.scratch, self.store, self.session, task, self.read_columns);
    if (!latest) self.next_history_cursor = prepared.page.continuation();
}
