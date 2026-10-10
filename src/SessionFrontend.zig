//! One persistent caller owns drafts, terminal and joined Client borrowers.
//! No worker writes the terminal; canonical activity supplies live output.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Task = @import("ClientTask.zig");
const Terminal = @import("SessionTerminal.zig");
const Text = @import("TerminalText.zig");
const Self = @This();

pub const Command = *const fn (std.process.Init, []const u8, []const u8, []u8) anyerror!void;
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
ticket: ?Input.Ticket = null,
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
opening: bool = true,
poll_at: i96 = 0,
dirty: bool = true,
detached: bool = false,
retry: bool = false,
inspect_action: bool = false,
notice: ?[]const u8 = null,
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
        if (interrupted.load(.acquire)) return error.InteractiveInterrupted;
        if (self.admission.thread != null and self.admission.completed()) {
            self.settleAdmission() catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                self.notice = "Admission unconfirmed; Ctrl-R retries the original capture. Next draft retained.";
            };
            self.dirty = true;
        }
        if (self.reader.take()) |bytes| {
            try self.terminal.permanent(bytes);
            self.reader.acknowledge();
        }
        if (self.reader.thread != null and self.reader.completed()) {
            try self.reader.join();
            self.current = self.observed;
            self.cursor = self.next_cursor;
            self.opening = false;
            self.poll_at = std.Io.Clock.awake.now(self.init.io).nanoseconds + 250_000_000;
            self.dirty = true;
        }
        if (self.reader.thread == null and (self.input.command_length != null or self.inspect_action)) {
            try self.handoff();
            continue;
        }
        if (self.ticket != null and self.admission.thread == null and self.retry) {
            self.retry = false;
            if (self.input.submitted.?.state != .rejected) try self.admission.start(self.init.io, self, resend);
        }
        if (self.reader.thread == null and std.Io.Clock.awake.now(self.init.io).nanoseconds >= self.poll_at)
            try self.reader.start(self.init.io, self, scan);
        if (self.notice) |notice| {
            self.notice = null;
            try self.terminal.permanent("\nRui: ");
            try self.terminal.permanent(notice);
            try self.terminal.permanent("\n");
            if (self.ticket != null) {
                try self.terminal.permanent("Original reserved request: ");
                try self.terminal.permanent(&self.capture_key);
                try self.terminal.permanent("\n");
            }
            self.dirty = true;
        }
        for (0..1024) |_| {
            if (!try self.step(0)) break;
            if (self.detached) break;
        }
        if (self.detached) break;
        if (self.dirty and self.reader.thread == null and !self.opening) {
            const view = self.input.composition();
            const status = if (self.ticket != null) switch (self.input.submitted.?.state) {
                .submitting => "Rui: submitting; next draft retained",
                .unconfirmed => "Rui: unconfirmed; Ctrl-R original /recover KEY",
                .rejected => "Rui: rejected; /discard retains next draft",
            } else if (self.opening) "Rui: opening" else if (self.current.actionable_count != 0) "Rui: attention; Ctrl-G inspects exact Action" else @tagName(self.current.work.status.value);
            self.dirty = false;
            try self.terminal.redraw(view.bytes, view.cursor, status);
        }
        _ = try self.step(16);
    }
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    _ = try self.step(16);
    if (self.detached or interrupted.load(.acquire)) return error.InteractiveInterrupted;
}

fn step(self: *Self, wait: i32) !bool {
    const byte = (self.terminal.next(self.init.io, self.input.pending(), wait) catch |err| switch (err) {
        error.InputDeadline => {
            try self.input.expire();
            return false;
        },
        else => return err,
    }) orelse return false;
    if (self.input.pending() == .none) switch (byte) {
        18 => {
            self.retry = true;
            return true;
        },
        7 => {
            self.inspect_action = true;
            return true;
        },
        else => {},
    };
    switch (self.input.feedSelected(byte, !self.opening)) {
        .message => |ticket| {
            self.ticket = ticket;
            // Reserve identity before capture, including post-publication error.
            const target: client.CaptureTarget = .{ .generated = self.directory };
            self.capture_target = .{ .explicit = try target.resolve(self.init.io, &self.capture_path, &self.capture_key) };
            self.reply = null;
            self.notice = "Capturing original request; next draft retained.";
            try self.admission.start(self.init.io, self, submit);
        },
        .command => {
            if (std.mem.eql(u8, self.input.command_buffer[0..self.input.command_length.?], "/exit")) self.detached = true;
        },
        .busy => self.notice = "Submission unresolved; editing remains available. Recover the original request, not replacement intent.",
        .editor => |event| switch (event) {
            .interrupt, .eof => self.detached = true,
            .invalid => self.notice = "input rejected (InvalidTerminalInput); nothing sent.",
            .overflow => self.notice = "input too long; nothing sent. Use rui message --text FILE for longer input.",
            else => {},
        },
    }
    self.dirty = true;
    return true;
}

fn submit(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
    self.captured = try client.captureMessage(task.io, .{ .store = self.store, .session = self.session, .text_path = "", .text = try self.input.message(self.ticket.?) }, self.capture_target);
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
        const bytes = try self.input.message(self.ticket.?);
        if (!capture.saved.store.eql(self.store) or !capture.saved.session.eql(self.session) or !capture.saved.key.eql(&self.capture_key) or !capture.saved.kind.eql("message")) return error.OriginalBindingMismatch;
        switch (capture.target) {
            .message => |message| if (message.bytes != bytes.len or !std.mem.eql(u8, &message.digest, &protocol.contentDigest(bytes))) return error.OriginalBindingMismatch,
            else => return error.OriginalBindingMismatch,
        }
    }
    self.reply = try task.requests().sendCaptured(&self.captured.?, null, &self.reply_buffer);
}

fn settleAdmission(self: *Self) !void {
    if (self.admission.thread == null) return;
    const result = self.admission.join();
    result catch |err| {
        try self.input.settle(self.ticket.?, .unconfirmed);
        return err;
    };
    const reply = self.reply.?;
    const answer = reply.answer catch |err| {
        try self.input.settle(self.ticket.?, .unconfirmed);
        return err;
    };
    if (reply.isAccepted()) {
        try self.input.settle(self.ticket.?, null);
        self.captured.?.close(self.init.io);
        self.captured = null;
        self.ticket = null;
    } else {
        try self.input.settle(self.ticket.?, .rejected);
        _ = answer;
        self.notice = "Submission rejected; original request retained. /discard abandons only that rejected draft; next composition is unchanged.";
    }
}

fn handoff(self: *Self) !void {
    try self.terminal.permanent("\n");
    const restored = self.terminal.finish();
    self.admission.cancel();
    const joined = self.settleAdmission();
    try restored;
    joined catch |err| {
        if (err == error.CanonicalStoreFailure) return err;
        self.notice = "Admission unconfirmed; Ctrl-R retries the original capture. Next draft retained.";
    };
    {
        self.signals(false);
        defer self.signals(true);
        if (self.inspect_action) {
            self.inspect_action = false;
            var text = "/inspect-action".*;
            try self.command(self.init, self.store, self.session, &text);
        } else {
            const text = self.input.command_buffer[0..self.input.command_length.?];
            defer self.input.command_length = null;
            if (std.mem.eql(u8, text, "/discard")) {
                if (self.ticket) |ticket| {
                    if (self.input.submitted.?.state == .rejected) {
                        try self.input.discard(ticket);
                        if (self.captured) |*capture| capture.close(self.init.io);
                        self.captured = null;
                        self.ticket = null;
                    } else self.notice = "Cannot discard an unresolved submission; Ctrl-R recovers the original.";
                }
            } else if (std.mem.startsWith(u8, text, "/recover ") and self.ticket != null) {
                if (std.mem.eql(u8, text[9..], &self.capture_key)) self.retry = true else self.notice = "Recovery key does not match this original submission; nothing sent.";
            } else if (std.mem.eql(u8, text, "/wait") or std.mem.eql(u8, text, "/login")) {
                self.notice = "Staged persistent mode has no nested approval/login prompt. Ctrl-G inspects; use explicit one-shot commands for decisions/login.";
            } else if (std.mem.eql(u8, text, "/help")) {
                try std.Io.File.stdout().writeStreamingAll(self.init.io, "Rui: /status /requests /result KEY /setup /configure /recover KEY /discard /exit. Ctrl-R retries the original uncertain capture; Ctrl-G inspects the fresh exact Action without granting approval. Decisions and login use explicit one-shot commands. This staged mode renders new activity only; full opening/history is not implemented.\n");
            } else try self.command(self.init, self.store, self.session, text);
        }
    }
    self.terminal = try Terminal.begin();
    self.terminal.pump = .{ .context = self, .step = pump };
    self.dirty = true;
}

fn scan(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    try self.scratch.setLength(task.io, 0);
    const Capture = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(s: *@This(), bytes: []const u8) !void {
            try s.file.writePositionalAll(s.io, bytes, s.offset);
            s.offset += bytes.len;
        }
    };
    var capture: Capture = .{ .io = task.io, .file = self.scratch };
    var response: client.ReplyBuffer = .{};
    const report = try requests.inspectSession(self.store, self.session, .current, &capture, &response);
    self.observed = switch (try client.CurrentReply.decode(task.io, self.scratch, self.session, report)) {
        .current => |current| current,
        .unconfigured => return error.SessionNotConfigured,
        .failure => |failure| return failure.err(),
    };
    var cursor = self.cursor;
    if (self.opening) cursor.direction = .backward;
    const page = switch (try requests.activityPage(self.store, self.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return failure.err(),
    };
    if (self.opening) {
        self.next_cursor = .{ .position = page.facts.end };
        return;
    }
    for (page.facts.items[0..page.facts.count]) |item| {
        switch (item.value) {
            .admission => |message| try content(self, task, item, message.content, "You: ", .line),
            .assistant => |reference| try content(self, task, item, reference, "Assistant: ", .multiline),
            .user, .tool_result => {},
            .call => |call| {
                var storage: [160]u8 = undefined;
                try task.feed(try std.fmt.bufPrint(&storage, "Rui: proposal {d} (inspection only); Ctrl-G for exact pending Action.\n", .{call.position}));
            },
            .outcome => |outcome| if (!outcome.code.eql("completed")) {
                try task.feed("Rui: saved work outcome: ");
                try task.feed(outcome.code.slice());
                try task.feed("\n");
            },
            .stop => try task.feed("Rui: Session stop accepted.\n"),
        }
    }
    self.next_cursor = page.continuation() orelse .{ .position = page.facts.end };
    if (page.facts.more) return;
    self.next_cursor.end = null;
}

fn content(self: *Self, task: *Task, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, label: []const u8, mode: Text.Mode) !void {
    const Sink = struct {
        task: *Task,
        text: Text,
        length: u64 = 0,
        hash: std.crypto.hash.sha2.Sha256 = protocol.contentHasher(),
        pub fn feed(s: *@This(), bytes: []const u8) !void {
            s.length += bytes.len;
            s.hash.update(bytes);
            var storage: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < 16) {
                    try s.task.feed(out.buffered());
                    out.end = 0;
                }
                try s.text.feed(&out, &.{byte});
            }
            if (out.end != 0) try s.task.feed(out.buffered());
        }
    };
    try task.feed(label);
    var sink: Sink = .{ .task = task, .text = .{ .mode = mode } };
    if (try task.requests().readActivityContent(self.store, self.session, item.position, item.ordinal, &sink)) |failure| return failure.err();
    var digest: [32]u8 = undefined;
    sink.hash.final(&digest);
    if (sink.length != reference.length or !std.mem.eql(u8, &digest, &reference.digest)) return error.ContentBindingMismatch;
    var storage: [16]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try sink.text.finish(&out);
    try task.feed(out.buffered());
    try task.feed("\n");
}
