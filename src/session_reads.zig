//! The Session frontend's reads. Each worker borrows only its Job: inputs
//! frozen at launch and a result the UI applies after join. This module does
//! not import the frontend, so no worker can read or write it.

const std = @import("std");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const View = @import("session_view.zig");
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const TerminalText = @import("TerminalText.zig");
const Viewport = @import("ConversationViewport.zig");
const session_line = @import("session_line.zig");
const Bounded = @import("bounded.zig").Bounded;
const unseen = @import("unseen.zig");
const ReadPhase = departure.ReadPhase;

pub const Command = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []u8) anyerror!void;
pub const Requests = *const fn (std.process.Init, client.Requests, []const u8, []const u8, *std.Io.Writer) anyerror!void;
/// Writes /status from one Current capture whose attention rows are in the file.
pub const Status = *const fn (std.Io, []const u8, []const u8, *const protocol_reply.Current, std.Io.File, *std.Io.Writer) anyerror!void;
pub const Inspection = enum { status, requests, help, command };

/// One read. Inputs are frozen at launch; the worker writes only `result`,
/// which the UI reads after join. No worker reads or writes the controller.
/// Live output renders into the inspection scratch file and shows whole, with
/// its footer, status and cursor, in one UI step after join.
/// The frontend's private scratch files, which a read borrows whole.
pub const Files = struct { scratch: std.Io.File, action: std.Io.File, inspection: std.Io.File, status: std.Io.File };

/// The moment a Session line was read at. Every input of the context
/// estimate takes a Session position and every settings change a revision,
/// so a page with another moment may show other facts.
pub const Moment = struct { revision: u64, end: u64 };

/// What the Session line shows from Current, as the UI keeps it between
/// reads. A scan reads Current again only when its page's moment differs.
pub const Line = struct {
    comptime {
        std.debug.assert(@max(protocol.max_label_bytes, protocol.max_session_bytes) <= session_line.max_name_bytes);
    }

    /// Null until the first read.
    read: ?Moment = null,
    label: ?Bounded(protocol.max_label_bytes) = null,
    first_position: ?u64 = null,
    model: Bounded(protocol.max_model_bytes) = .{},
    effort: ?protocol.ReasoningEffort = null,
    left: ?u8 = null,
    asks: bool = false,

    fn stale(read: ?Moment, page: *const protocol.ActivityFacts) bool {
        const moment = read orelse return true;
        return moment.revision != page.work.revision or moment.end != page.end;
    }

    /// Fills `line` with the facts this read's Current capture holds.
    fn take(line: *?Line, current: *const protocol_reply.Current, moment: Moment) void {
        const settings = &current.settings;
        const first = (current.first_message.value orelse null) orelse null;
        const trigger = settings.compaction_trigger;
        const estimate = (settings.context_estimate.value orelse null) orelse null;
        line.* = .{
            .read = moment,
            .label = if (settings.label) |label| plain(protocol.max_label_bytes, label.slice()) else null,
            .first_position = if (first) |message| message.value.position else null,
            .model = plain(protocol.max_model_bytes, settings.model.slice()),
            .effort = if (settings.reasoning_effort) |effort| effort.value else null,
            .left = if (trigger != null and estimate != null) session_line.left(trigger.?.value, estimate.?.value) else null,
            .asks = settings.permission_mode.value == .ask,
        };
    }

    /// Null until the first read.
    pub fn facts(self: *const Line, hint: *const Hint, reference: []const u8) ?session_line.Facts {
        if (self.read == null) return null;
        const label: ?[]const u8 = if (self.label) |*text| text.slice() else null;
        const line: ?[]const u8 = switch (hint.*) {
            .line => |*text| text.slice(),
            .unread, .absent => null,
        };
        return .{
            .name = session_line.name(label, line, reference).text,
            .model = self.model.slice(),
            .effort = self.effort,
            .left = self.left,
            .asks = self.asks,
        };
    }
};

/// An unlabelled Session's name: its first Message's first line, read once,
/// since that Message never changes.
pub const Hint = union(enum) {
    unread,
    /// The lookup found no line to show; the reference names the Session.
    absent,
    line: Bounded(session_line.max_line_bytes),
};

/// Reads the hint from the first Message at `position`. A refusal or content
/// that is not text answers it with the reference; a canonical Store,
/// transport or cancellation failure fails the read, as the page's would.
fn readHint(requests: client.Requests, job: *const Job, position: u64) !Hint {
    var buffer: [session_line.max_line_bytes + 1]u8 = undefined;
    const reply = requests.readActivityPrefix(job.store, job.session, position, &buffer) catch |err| switch (err) {
        error.InvalidResponse => return .absent,
        else => return err,
    };
    switch (reply) {
        .line => |bytes| {
            const line = session_line.firstLine(bytes);
            return if (line.len == 0) .absent else .{ .line = plain(session_line.max_line_bytes, line) };
        },
        .failure => |failure| {
            if (failure.err() == error.CanonicalStoreFailure) return requests.failRead(failure);
            return .absent;
        },
    }
}

/// Text the Host holds, without terminal controls and with its tabs and line
/// ends as spaces, within `limit` bytes: cut at a code point and ended with
/// an ellipsis when longer. One pass, straight into the value.
fn plain(comptime limit: usize, bytes: []const u8) Bounded(limit) {
    var value: Bounded(limit) = .{};
    var text: TerminalText = .{ .mode = .multiline };
    // The longest kept text an ellipsis can still follow.
    var room: usize = 0;
    for (bytes, 1..) |byte, count| {
        var storage: [32]u8 = undefined;
        var piece = std.Io.Writer.fixed(&storage);
        text.feed(&piece, &.{byte}) catch unreachable;
        if (count == bytes.len) text.finish(&piece) catch unreachable;
        const shown = piece.buffered();
        if (value.len + shown.len > limit) {
            value.len = room;
            @memcpy(value.bytes[room..][0..session_line.ellipsis.len], session_line.ellipsis);
            value.len += session_line.ellipsis.len;
            return value;
        }
        for (shown, value.bytes[value.len..][0..shown.len]) |from, *to| to.* = if (from == '\n' or from == '\t') ' ' else from;
        value.len += shown.len;
        if (value.len + session_line.ellipsis.len <= limit) room = value.len;
    }
    return value;
}

pub const Job = struct {
    init: std.process.Init = undefined,
    store: []const u8 = "",
    session: []const u8 = "",
    files: Files = undefined,
    colour: bool = false,
    command: Command = undefined,
    requests: Requests = undefined,
    status: Status = undefined,
    phase: ReadPhase = .activity,
    cursor: protocol_reply.ActivityCursor = .{},
    opening: bool = false,
    older: ?protocol_reply.ConversationCursor = null,
    // A history read renders this part of a transcript's listing instead.
    listing: ?Listing = null,
    // A message read shows this collapsed block's Message in full.
    message_target: ?View.Collapsed = null,
    // A history read renders the conversation after this cursor, for the
    // end of the transcript that starts at the "new since you looked" rule.
    newer: ?protocol_reply.ActivityCursor = null,
    // The latest live work held queued input: a listed echo, whose read
    // was earlier, is labelled by it.
    held: bool = false,
    // Messages shown in live output before this read.
    messages: Messages = .{},
    transcript: u64 = 0,
    inspection_kind: Inspection = .status,
    // A command observes exit or a signal as an interruption.
    interrupted: *client.Cancellation = undefined,
    command_text: [@typeInfo(@FieldType(Input, "command_buffer")).array.len]u8 = undefined,
    command_text_length: usize = 0,
    inspection_submission: ?Submission.View = null,
    inspection_action: ?u64 = null,
    // A scan renders /status from its own Current capture: when the user
    // asks for it, or when the shown page (`status_shown`) would change.
    open_status: bool = false,
    watch_status: bool = false,
    status_shown: u64 = 0,
    // The moment the UI's Session line was read at, and whether it still
    // needs the unlabelled Session's name.
    line_read: ?Moment = null,
    hint_wanted: bool = false,
    result: struct {
        // The work the page's own Store read saw: its history, footer and
        // consent describe one moment.
        work: protocol.PageWork = .{},
        // The Session line's facts, when this read took them.
        line: ?Line = null,
        // The unlabelled Session's name, when this read looked it up.
        hint: ?Hint = null,
        // /status from one Current capture is in the status file.
        status: bool = false,
        status_digest: u64 = 0,
        // The newest Message admission this page holds, for Sent.
        delivered: u64 = 0,
        // Where a transcript may begin in this read's output (see Marks),
        // oldest first, as offsets into the output.
        boundaries: Boundaries = .{},
        // Each Message this read's output shows, in order, as output offsets.
        echoes: Echoes = .{},
        // The Messages of the collapsed blocks in this read's output, in order.
        collapsed: Collected = .{},
        // The opening's lowest unapplied position (see View.Pending).
        lowest: ?u64 = null,
        // The Session's read-through position, as the opening's page read it.
        read_through: ?u64 = null,
        // Where the opening put the "new since you looked" rule, as an
        // output offset.
        rule: unseen.Rule = .none,
        // A newer page: where the conversation continues, null at the
        // opening's end, and the position its rows show every row through.
        newer: ?protocol_reply.ActivityCursor = null,
        through: u64 = 0,
        // The job's Messages after this read.
        messages: Messages = .{},
        live: View.Live = .{},
        cursor: protocol_reply.ActivityCursor = .{},
        compact_tools: bool = false,
        history_cursor: ?protocol_reply.ConversationCursor = null,
        // Where a listing range continues, or null when it is done.
        listing: ?Listing = null,
        // Output custody began; a later failure is not a silent preparation one.
        rendering: bool = false,
        // Only confirmed stderr restoration permits exit to replay this page.
        command_stderr_restored: bool = false,
        action: ?u64 = null,
        summary: View.ActionSummary = .{},
        // Bytes of live output staged in the inspection scratch file.
        output_length: u64 = 0,
    } = .{},
};

/// Host commands keep their one-shot output owners. Their complete stdout and
/// stderr become an inspection page while the Session screen keeps drawing
/// through its own descriptor. No command reads terminal input.
pub fn runCommand(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.files.inspection.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.files.inspection, 0);
    // Saved descriptors must not leak into anything the command executes.
    const saved = [2]c_int{ std.c.fcntl(1, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)), std.c.fcntl(2, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)) };
    defer for (saved) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    if (saved[0] < 0 or saved[1] < 0) return error.TerminalCleanupFailed;
    // Redirected descriptors are output custody: any failure now is fatal.
    job.result.rendering = true;
    const page = job.files.inspection.handle;
    const result = if (std.c.dup2(page, 1) < 0 or std.c.dup2(page, 2) < 0) error.TerminalCleanupFailed else job.command(job.init, .{ .io = task.io, .cancellation = job.interrupted }, job.store, job.session, job.command_text[0..job.command_text_length]);
    const stdout_restored = std.c.dup2(saved[0], 1) >= 0;
    job.result.command_stderr_restored = std.c.dup2(saved[1], 2) >= 0;
    if (!stdout_restored or !job.result.command_stderr_restored) return error.TerminalCleanupFailed;
    return result;
}

pub fn permission(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (job.result.work.work.first_action) |action| {
        try job.files.action.setLength(task.io, 0);
        var output: DisplayCapture = .{ .task = task, .file = job.files.action };
        job.result.summary = try View.permission(task.requests(), job.store, job.session, action, job.files.scratch, &output, job.colour);
        job.result.compact_tools = false;
        job.result.action = action;
    }
}

pub fn scan(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    var cursor = job.cursor;
    if (job.opening) cursor.direction = .backward;
    const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    // The page carries its work from its own Store read.
    job.result.work = page.facts.work;
    // /status and a stale Session line read Current, once; it may be newer
    // than the page.
    const line_stale = Line.stale(job.line_read, &page.facts);
    if (job.open_status or job.watch_status or line_stale) {
        const current = try View.current(requests, job.store, job.session, job.files.scratch);
        if (line_stale) Line.take(&job.result.line, &current, .{ .revision = page.facts.work.revision, .end = page.facts.end });
        // Before anything else reuses scratch, which holds this capture's rows.
        if (job.open_status or job.watch_status) {
            job.result.status_digest = try statusDigest(job, task.io, &current);
            if (job.open_status or job.result.status_digest != job.status_shown) {
                try job.files.status.setLength(task.io, 0);
                try task.io.vtable.fileSeekTo(task.io.userdata, job.files.status, 0);
                var buffer: [4096]u8 = undefined;
                var output = job.files.status.writerStreaming(task.io, &buffer);
                try writeStatus(job, task.io, &current, &output.interface);
                try output.flush();
                job.result.status = true;
            }
        }
    }
    if (job.result.line) |*line| if (job.hint_wanted and line.label == null) if (line.first_position) |position| {
        job.result.hint = try readHint(requests, job, position);
    };
    job.result.live = View.Live.init(page.facts.call_activity);
    // Admission ids follow Session positions, so the newest one shown
    // means every earlier Message was delivered too.
    for (page.facts.items[0..page.facts.count]) |item| switch (item.value) {
        .admission, .user => |message| job.result.delivered = @max(job.result.delivered, message.admission),
        else => {},
    };
    if (job.opening) {
        var mark: ?protocol_reply.ConversationCursor = if (page.facts.more) .{ .end = page.facts.end } else null;
        if (page.facts.more) for (page.facts.items[0..page.facts.count]) |item| {
            switch (item.value) {
                .user, .assistant, .tool_result => mark = .{ .end = page.facts.end, .before_position = item.position, .before_ordinal = item.ordinal },
                else => {},
            }
        };
        // Nothing showed before the opening, so its start is a boundary even
        // when it shows nothing. Every Message it shows is at or after its
        // page's lowest item, a row included; one admitted before that page
        // and not applied is listed there.
        const lowest = if (page.facts.count != 0) page.facts.items[page.facts.count - 1].position else page.facts.end + 1;
        job.result.boundaries.add(.{ .output = 0, .cursor = mark, .admitted = lowest });
    }
    try job.files.inspection.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.files.inspection, .messages = job.messages, .end = page.facts.end, .colour = job.colour };
    if (job.opening) {
        const pending = try View.pending(requests, job.store, job.session, page.facts.end);
        try pending.render(page.facts.work.work.state.holdsQueue(), &output);
        job.result.lowest = pending.lowest;
        // A queued Message older than the page shows only in a transcript's
        // listing, at the opening's seam. No later boundary may precede its
        // row, which shows nothing live.
        output.messages.shown = @max(output.messages.shown, pending.newest);
        job.result.read_through = page.facts.read_through;
        const oldest = if (page.facts.count != 0) page.facts.items[page.facts.count - 1].position else null;
        switch (unseen.place(page.facts.read_through, oldest, page.facts.more)) {
            .here => output.unseen_after = page.facts.read_through,
            .older => job.result.rule = .older,
            .none => {},
        }
    }
    try View.render(requests, job.store, job.session, &page, &output, job.colour, &job.result.compact_tools);
    if (output.rule_at) |offset| job.result.rule = .{ .at = offset };
    job.result.output_length = output.offset;
    job.result.messages = output.finish();
    job.result.echoes = output.echoes;
    job.result.collapsed = output.blocks;
    if (!job.opening) {
        job.result.boundaries = output.boundaries;
        if (readEnd(job.result.messages, page.facts.more, page.facts.end, output.offset)) |end| job.result.boundaries.add(end);
    }
    if (job.opening) {
        job.result.cursor = .{ .position = page.facts.end };
    } else {
        job.result.cursor = page.continuation() orelse .{ .position = page.facts.end };
        if (!page.facts.more) job.result.cursor.end = null;
    }
}

/// The /status page for the Current capture whose rows are in scratch.
fn writeStatus(job: *const Job, io: std.Io, current: *const protocol_reply.Current, out: *std.Io.Writer) !void {
    try job.status(io, job.store, job.session, current, job.files.scratch, out);
    try writeSubmission(job, out);
}

fn statusDigest(job: *const Job, io: std.Io, current: *const protocol_reply.Current) !u64 {
    var buffer: [256]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(.init(0), &buffer);
    try writeStatus(job, io, current, &hashing.writer);
    try hashing.writer.flush();
    return hashing.hasher.final();
}

/// Snapshot before launch: this read cannot race Admission settlement.
fn writeSubmission(job: *const Job, out: *std.Io.Writer) !void {
    const submission = job.inspection_submission orelse return;
    try out.print("Original reserved request: {s}\n{s}\n", .{ submission.key, if (submission.state == .rejected) "Submission rejected; /discard releases only this original, retaining the next draft." else "Publication/admission may be incomplete; Ctrl-R retries this exact original." });
    if (submission.last_error) |err| try out.print("Last submission error: {s}\n", .{@errorName(err)});
}

pub fn history(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const latest = job.phase == .details;
    if (!latest) if (job.listing) |step| return list(job, task, step);
    if (!latest) if (job.newer) |cursor| return newer(job, task, cursor);
    const prepared = try History.prepare(task.requests(), job.store, job.session, if (latest) .{ .end = 0 } else job.older.?, job.files.scratch);
    // Joined errors before this point retain the cursor without visible content.
    job.result.rendering = true;
    try job.files.inspection.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.files.inspection };
    if (latest) try output.feed("\nRecent conversation — tool details\n");
    try prepared.render(task.io, job.files.scratch, job.store, job.session, &output, if (latest) .details else .transcript, job.colour);
    job.result.collapsed = output.blocks;
    if (!latest) job.result.history_cursor = prepared.page.continuation();
}

/// Renders one Activity page after `cursor`, oldest first and as live
/// output shows it, for the end of the transcript that starts at the "new
/// since you looked" rule. The first page, which follows the read-through
/// position itself, starts with the rule.
fn newer(job: *Job, task: *Task, cursor: protocol_reply.ActivityCursor) !void {
    const requests = task.requests();
    const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    job.result.rendering = true;
    try job.files.inspection.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.files.inspection, .end = page.facts.end, .colour = job.colour };
    if (cursor.ordinal == null) try output.rule();
    var compact = false;
    try View.render(requests, job.store, job.session, &page, &output, job.colour, &compact);
    _ = output.finish();
    job.result.collapsed = output.blocks;
    job.result.newer = page.continuation();
    // Later rows of a page's last position may be on the next page.
    job.result.through = if (job.result.newer) |next| @max(next.position - 1, cursor.position) else page.facts.end;
}

/// Renders one listed Message, bound to its item's length and digest, and
/// where the listing continues. Nothing shows until the UI prepends it.
fn list(job: *Job, task: *Task, step: Listing) !void {
    const requests = task.requests();
    try job.files.inspection.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.files.inspection };
    defer job.result.collapsed = output.blocks;
    switch (step) {
        .echo => |echo| {
            const item: protocol.ActivityItem = .{ .position = echo.position, .ordinal = echo.ordinal, .at = echo.message.admitted_at, .value = .{ .admission = echo.message } };
            try View.message(requests, job.store, job.session, item, echo.message, .lasting(job.held), &output, job.colour);
            job.result.listing = null;
        },
        .range => |range| {
            var cursor = range.cursor;
            while (true) {
                const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
                    .page => |page| page,
                    .failure => |failure| return requests.failRead(failure),
                };
                for (page.facts.items[0..page.facts.count]) |item| {
                    if (item.position < range.lowest) break;
                    const value = switch (item.value) {
                        .admission => |value| value,
                        else => continue,
                    };
                    if (!range.all and value.state == .applied) continue;
                    try View.message(requests, job.store, job.session, item, value, .lasting(page.facts.work.work.state.holdsQueue()), &output, job.colour);
                    var next = range;
                    next.cursor = .{ .end = range.end, .position = item.position, .ordinal = item.ordinal, .direction = .backward };
                    job.result.listing = .{ .range = next };
                    return;
                } else if (page.continuation()) |next| {
                    cursor = next;
                    continue;
                }
                job.result.listing = null;
                return;
            }
        },
    }
}

/// The collapsed blocks one read writes: a page shows each item at most once.
pub const Collected = struct {
    items: [@max(@typeInfo(@FieldType(protocol.ActivityFacts, "items")).array.len, protocol.public_conversation_page_items)]View.Collapsed = undefined,
    count: usize = 0,

    pub fn slice(self: *const Collected) []const View.Collapsed {
        return self.items[0..self.count];
    }
};

const DisplayCapture = struct {
    task: *Task,
    file: std.Io.File,
    offset: u64 = 0,
    blocks: Collected = .{},
    /// The page's end, for boundary cursors.
    end: u64 = 0,
    /// Messages shown before the current item.
    messages: Messages = .{},
    /// Shown items where a transcript may begin.
    boundaries: Boundaries = .{},
    /// Shown Messages.
    echoes: Echoes = .{},
    current: ?protocol.ActivityItem = null,
    current_start: u64 = 0,
    current_shown: bool = false,
    /// The rule goes before the first shown item after this position.
    unseen_after: ?u64 = null,
    /// Where the rule went.
    rule_at: ?u64 = null,
    colour: bool = false,

    pub fn item(self: *@This(), value: protocol.ActivityItem) void {
        _ = self.finish();
        self.current = value;
        self.current_start = self.offset;
    }

    /// Writes the "new since you looked" rule here.
    fn rule(self: *@This()) !void {
        self.unseen_after = null;
        self.rule_at = self.offset;
        try self.write(View.Style.quiet.code(self.colour));
        try self.write(unseen.rule);
        try self.write(View.Style.normal.code(self.colour));
    }

    fn write(self: *@This(), bytes: []const u8) !void {
        try self.file.writePositionalAll(self.task.io, bytes, self.offset);
        self.offset += bytes.len;
    }

    pub fn collapsed(self: *@This(), value: View.Collapsed) !void {
        if (self.blocks.count == self.blocks.items.len) return error.TooManyCollapsedBlocks;
        self.blocks.items[self.blocks.count] = value;
        self.blocks.count += 1;
    }

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        // An item's first bytes follow the rule when it is the first unseen
        // one shown, and its echo and boundary start after the rule.
        if (bytes.len != 0 and !self.current_shown) if (self.current) |current| if (self.unseen_after) |after| if (current.position > after) {
            try self.rule();
            self.current_start = self.offset;
        };
        try self.write(bytes);
        if (bytes.len == 0 or self.current_shown) return;
        const current = self.current orelse return;
        self.current_shown = true;
        if (self.messages.settled())
            self.boundaries.add(.{ .output = self.current_start, .cursor = beginningBefore(current, self.end), .admitted = current.position });
    }

    /// Accounts for the last item; returns the Messages after it.
    fn finish(self: *@This()) Messages {
        if (self.current) |current| {
            self.messages.observe(current, self.current_shown);
            if (self.current_shown) switch (current.value) {
                .admission, .user => |message| self.echoes.add(.{ .output = self.current_start, .end = self.offset, .position = current.position, .ordinal = current.ordinal, .message = message, .read_end = self.end }),
                else => {},
            };
        }
        self.current = null;
        self.current_shown = false;
        return self.messages;
    }
};

test "the rule precedes the first shown item after the read-through position, once, outside its echo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "output", .{ .read = true });
    defer file.close(io);
    var task: Task = .{ .io = io };
    const content: protocol.ActivityItem.Content = .{ .length = 0, .digest = @splat(0) };
    const message: protocol.ActivityItem.Message = .{ .admission = 4, .key = .{}, .turn = null, .state = .queued, .content = content, .admitted_at = 1 };
    var output: DisplayCapture = .{ .task = &task, .file = file, .unseen_after = 3 };
    // Read items, and an unseen one that shows nothing, take no rule.
    output.item(.{ .position = 3, .at = 1, .value = .{ .assistant = content } });
    try output.feed("seen\n");
    output.item(.{ .position = 4, .at = 1, .value = .{ .call = undefined } });
    try output.feed("");
    output.item(.{ .position = 5, .at = 1, .value = .{ .admission = message } });
    try output.feed("\n› new\n");
    output.item(.{ .position = 6, .at = 1, .value = .{ .assistant = content } });
    try output.feed("later\n");
    _ = output.finish();
    var bytes: [128]u8 = undefined;
    const written = bytes[0..try file.readPositionalAll(io, &bytes, 0)];
    try std.testing.expectEqualStrings("seen\n" ++ unseen.rule ++ "\n› new\nlater\n", written);
    try std.testing.expectEqual(@as(?u64, 5), output.rule_at);
    // The Message's echo is its own rows, after the rule.
    try std.testing.expectEqual(@as(usize, 1), output.echoes.count);
    try std.testing.expectEqualStrings("\n› new\n", written[@intCast(output.echoes.items[0].output)..@intCast(output.echoes.items[0].end)]);
}

/// Messages shown in live output, by admission id. A Message shows first as
/// its Admission, or is listed at the opening's seam, and gains its
/// conversation row later:
/// at model-attempt admission, after a running tool's result when steered, or
/// after the answer it queued behind. Admission ids follow Session positions,
/// so the newest of each stands for every earlier one.
pub const Messages = struct {
    /// The newest Message shown as its Admission or listed at the opening's seam.
    shown: u64 = 0,
    /// The newest Message whose conversation row a read returned.
    answered: u64 = 0,

    /// Every shown Message has its conversation row before the next item, so
    /// no conversation item after it showed earlier in live output.
    pub fn settled(self: Messages) bool {
        return self.shown <= self.answered;
    }

    fn observe(self: *Messages, item: protocol.ActivityItem, shown: bool) void {
        switch (item.value) {
            .admission => |message| if (shown) {
                self.shown = @max(self.shown, message.admission);
            },
            .user => |message| self.answered = @max(self.answered, message.admission),
            else => {},
        }
    }
};

/// Where a read's output may begin a transcript. `output` counts the read's
/// staged bytes, styling included; live output keeps only text, so the UI
/// records the live offset where writing reaches it, never this number.
pub const Boundary = struct {
    output: u64,
    cursor: ?protocol_reply.ConversationCursor,
    /// Every Message admitted before this position that showed did so before
    /// the boundary; one admitted at or after it shows after it, if at all.
    admitted: u64,
};

/// One Message as a read's output shows it: its Admission live, or in the
/// opening its row or unapplied input. `output` and `end` are output offsets
/// until the UI records live ones. The state is as of `read_end`.
pub const Echo = struct {
    output: u64,
    end: u64,
    position: u64,
    ordinal: u64,
    message: protocol.ActivityItem.Message,
    read_end: u64,
};

/// The Messages one read shows, in order: a page holds at most one each.
pub const Echoes = struct {
    items: [@typeInfo(@FieldType(protocol.ActivityFacts, "items")).array.len]Echo = undefined,
    count: usize = 0,

    fn add(self: *Echoes, echo: Echo) void {
        self.items[self.count] = echo;
        self.count += 1;
    }

    pub fn slice(self: *const Echoes) []const Echo {
        return self.items[0..self.count];
    }
};

/// One step of a transcript's listing: a Message in full where older pages
/// and the retained copy cannot show it. Each step reads one Message.
pub const Listing = union(enum) {
    /// A shown Message whose output left the view, from its own item.
    echo: Echo,
    /// Admissions in `[lowest, before)` at `end`, newest first: every one, or
    /// only those not applied at `end`. `cursor` is where the next one is
    /// searched for, backward.
    range: struct { end: u64, lowest: u64, all: bool, cursor: protocol_reply.ActivityCursor },

    pub fn within(end: u64, lowest: u64, before: u64, all: bool) ?Listing {
        if (lowest >= before) return null;
        // Position 0 searches back from the end itself.
        return .{ .range = .{ .end = end, .lowest = lowest, .all = all, .cursor = .{ .end = end, .position = if (before > end) 0 else before, .direction = .backward } } };
    }
};

/// The Messages live output shows after its newest mark, as live offsets.
/// A mark prunes every echo before it: a transcript joined there reaches
/// those through older pages or its listing. Opening echoes (one page) are
/// never dropped; live ones beyond capacity are, keeping only their span.
pub const Record = struct {
    pub const capacity = 64;
    opening: [@typeInfo(@FieldType(Echoes, "items")).array.len]Echo = undefined,
    opening_count: usize = 0,
    live: [capacity]Echo = undefined,
    live_count: usize = 0,
    /// Live echoes dropped beyond capacity: admissions echo live in position
    /// order, so they are every admission in `[low, high]`.
    dropped: ?struct { low: u64, high: u64, end: u64, read_end: u64 } = null,

    pub fn add(self: *Record, echo: Echo, opening: bool) void {
        if (opening) {
            self.opening[self.opening_count] = echo;
            self.opening_count += 1;
            return;
        }
        if (self.live_count == self.live.len) {
            const old = self.live[0];
            self.dropped = if (self.dropped) |span| .{ .low = span.low, .high = old.position, .end = old.end, .read_end = @max(span.read_end, old.read_end) } else .{ .low = old.position, .high = old.position, .end = old.end, .read_end = old.read_end };
            std.mem.copyForwards(Echo, self.live[0 .. self.live_count - 1], self.live[1..self.live_count]);
            self.live_count -= 1;
        }
        self.live[self.live_count] = echo;
        self.live_count += 1;
    }

    pub fn prune(self: *Record, offset: u64) void {
        self.opening_count = keep(self.opening[0..self.opening_count], offset);
        self.live_count = keep(self.live[0..self.live_count], offset);
        if (self.dropped) |span| if (span.end <= offset) {
            self.dropped = null;
        };
    }

    fn keep(echoes: []Echo, offset: u64) usize {
        var kept: usize = 0;
        for (echoes) |echo| if (echo.output >= offset) {
            echoes[kept] = echo;
            kept += 1;
        };
        return kept;
    }
};

/// How a transcript of live output retained from `front` begins: where its
/// copy starts, then upward the listed Messages, the gap's label if any, the
/// Messages listed at its seam, and older pages before `older`.
pub const Plan = struct {
    start: u64,
    /// Shown Messages that left the view, oldest first; listed nearest the copy.
    echoes: [@typeInfo(@FieldType(Record, "opening")).array.len + Record.capacity]Echo = undefined,
    echo_count: usize = 0,
    /// How many of `echoes`, the oldest, are the opening's: older than every
    /// live one, the dropped span's included.
    opening: usize = 0,
    dropped: ?Listing = null,
    gap: bool = false,
    unapplied: ?Listing = null,
    older: ?protocol_reply.ConversationCursor = null,

    /// The listed Message a transcript reads next, if any comes before older
    /// pages. Each is prepended, so newest first: live echoes, the dropped
    /// span, the opening's echoes, then after the gap's label the seam's.
    pub fn next(self: *const Plan) ?Listing {
        if (self.echo_count > self.opening) return .{ .echo = self.echoes[self.echo_count - 1] };
        if (self.dropped) |range| return range;
        if (self.echo_count != 0) return .{ .echo = self.echoes[self.echo_count - 1] };
        if (!self.gap) if (self.unapplied) |range| return range;
        return null;
    }

    /// Passes the step `next` returned once it shows; a range continues at
    /// `rest`, or is done when null.
    pub fn listed(self: *Plan, step: Listing, rest: ?Listing) void {
        switch (step) {
            .echo => self.echo_count -= 1,
            .range => if (self.dropped != null) {
                self.dropped = rest;
            } else {
                self.unapplied = rest;
            },
        }
    }
};

pub fn plan(marks: *const Marks, record: *const Record, front: u64, lowest: ?u64) Plan {
    const mark: ?Marks.Mark = switch (marks.start(front)) {
        .joined => |mark| return .{ .start = mark.offset, .unapplied = seam(mark, lowest), .older = mark.cursor },
        .gap => |before| before,
    };
    var result: Plan = .{ .start = front, .gap = true, .older = if (mark) |value| value.cursor else null };
    if (mark) |value| result.unapplied = seam(value, lowest);
    // Live echoes dropped beyond capacity may reach past the front: start
    // after the newest so none shows twice, and list them all.
    if (record.dropped) |span| {
        result.start = @max(result.start, span.end);
        result.dropped = Listing.within(span.read_end, span.low, span.high + 1, true);
    }
    // An echo that the front cuts is listed whole, and the copy starts after it.
    const echoes = [_][]const Echo{ record.opening[0..record.opening_count], record.live[0..record.live_count] };
    for (echoes) |kept| for (kept) |echo| if (echo.output < result.start and echo.end > result.start) {
        result.start = echo.end;
    };
    for (echoes, 0..) |kept, index| for (kept) |echo| if (echo.end <= result.start) {
        result.echoes[result.echo_count] = echo;
        result.echo_count += 1;
        if (index == 0) result.opening += 1;
    };
    return result;
}

test "a transcript lists each recorded Message once, whole, before the copy that follows it" {
    const Make = struct {
        fn echo(position: u64, output: u64) Echo {
            return .{ .output = output, .end = output + 8, .position = position, .ordinal = 0, .read_end = 300, .message = .{ .admission = position, .key = .{}, .turn = null, .state = .queued, .content = .{ .length = 0, .digest = @splat(0) }, .admitted_at = 1 } };
        }
    };
    const opening: Marks.Mark = .{ .offset = 0, .cursor = .{ .end = 20 }, .admitted = 5 };
    var marks: Marks = .{};
    marks.record(opening);
    const Span = @typeInfo(@FieldType(Record, "dropped")).optional.child;
    var record: Record = .{};
    for (0..16) |index| record.add(Make.echo(5 + index, index * 4), true);
    // 64 live echoes fit; the 65th drops the oldest, keeping its span.
    for (0..64) |index| record.add(Make.echo(30 + index, 100 + 10 * index), false);
    try std.testing.expectEqual(@as(?Span, null), record.dropped);
    record.add(Make.echo(94, 740), false);
    try std.testing.expectEqual(@as(usize, 16), record.opening_count);
    try std.testing.expectEqual(@as(usize, 64), record.live_count);
    try std.testing.expectEqualDeep(Span{ .low = 30, .high = 30, .end = 108, .read_end = 300 }, record.dropped);
    // A second wrap widens the span to the next dropped echo and its end.
    var wrapped = record;
    wrapped.add(Make.echo(95, 750), false);
    try std.testing.expectEqualDeep(Span{ .low = 30, .high = 31, .end = 118, .read_end = 300 }, wrapped.dropped);
    try std.testing.expectEqualDeep(Listing.within(300, 30, 32, true), plan(&marks, &wrapped, 105, 3).dropped);
    try std.testing.expectEqual(@as(u64, 118), plan(&marks, &wrapped, 105, 3).start);

    // The newest dropped echo ends after the front: the copy starts at its
    // end, so it shows only in the listing, and every opening echo is listed.
    // Live echoes wrapped while no later mark recorded: the opening mark
    // still names older pages and the seam.
    var result = plan(&marks, &record, 105, 3);
    try std.testing.expectEqual(@as(u64, 108), result.start);
    try std.testing.expect(result.gap);
    try std.testing.expectEqualDeep(Listing.within(300, 30, 31, true), result.dropped);
    try std.testing.expectEqualDeep(Listing.within(20, 3, 5, false), result.unapplied);
    try std.testing.expectEqual(@as(u64, 20), result.older.?.end);
    try std.testing.expectEqual(@as(usize, 16), result.echo_count);
    // Before the front, it is listed as well; the copy starts at the front.
    result = plan(&marks, &record, 109, 3);
    try std.testing.expectEqual(@as(u64, 109), result.start);
    try std.testing.expect(result.dropped != null);
    // A front inside an echo lists that echo whole and starts after it.
    result = plan(&marks, &record, 112, 3);
    try std.testing.expectEqual(@as(u64, 118), result.start);
    try std.testing.expectEqual(@as(usize, 17), result.echo_count);
    try std.testing.expectEqual(@as(u64, 31), result.echoes[16].position);
    // Listed newest first: the live echo, the dropped span, then the opening's
    // older echoes; the gap's label precedes the seam.
    try std.testing.expectEqual(@as(u64, 31), result.next().?.echo.position);
    result.listed(result.next().?, null);
    try std.testing.expectEqualDeep(Listing.within(300, 30, 31, true), result.next());
    result.listed(result.next().?, null);
    for (0..16) |index| {
        try std.testing.expectEqual(@as(u64, 20 - index), result.next().?.echo.position);
        result.listed(result.next().?, null);
    }
    try std.testing.expectEqual(@as(?Listing, null), result.next());
    result.gap = false;
    try std.testing.expectEqualDeep(Listing.within(20, 3, 5, false), result.next());
    result.listed(result.next().?, null);
    try std.testing.expectEqual(@as(?Listing, null), result.next());

    // A mark prunes echoes strictly before it; one starting at it stays.
    record.prune(107);
    try std.testing.expect(record.dropped != null);
    record.prune(120);
    try std.testing.expectEqual(@as(?Span, null), record.dropped);
    try std.testing.expectEqual(@as(usize, 0), record.opening_count);
    try std.testing.expectEqual(@as(usize, 63), record.live_count);
    try std.testing.expectEqual(@as(u64, 120), record.live[0].output);
}

test "the opening mark is retained through 64 marks and dropped by the 65th" {
    var marks: Marks = .{};
    marks.record(.{ .offset = 0, .cursor = null, .admitted = 1 });
    for (1..64) |index| marks.record(.{ .offset = index, .cursor = .{ .end = index }, .admitted = index + 1 });
    try std.testing.expectEqual(@as(u64, 0), marks.start(0).joined.offset);
    marks.record(.{ .offset = 64, .cursor = .{ .end = 64 }, .admitted = 65 });
    try std.testing.expectEqual(@as(u64, 1), marks.start(0).joined.offset);
}

/// Messages a transcript joined at `mark` lists there: admitted before its
/// position and not applied at its end, so neither older pages nor the copy
/// show them.
fn seam(mark: Marks.Mark, lowest: ?u64) ?Listing {
    const cursor = mark.cursor orelse return null;
    return Listing.within(cursor.end, lowest orelse return null, mark.admitted, false);
}

/// A read's newest boundaries, oldest first. Any boundary at or after the
/// view's front joins its transcript, so dropping the oldest loses nothing
/// a newer one cannot replace.
pub const Boundaries = struct {
    items: [Marks.capacity]Boundary = undefined,
    count: usize = 0,

    pub fn add(self: *Boundaries, boundary: Boundary) void {
        if (self.count == self.items.len) {
            std.mem.copyForwards(Boundary, self.items[0 .. self.count - 1], self.items[1..self.count]);
            self.count -= 1;
        }
        self.items[self.count] = boundary;
        self.count += 1;
    }

    pub fn slice(self: *const Boundaries) []const Boundary {
        return self.items[0..self.count];
    }
};

/// A later read also marks the end of its output, even when it shows nothing,
/// if it reached its snapshot's end with every shown Message rowed.
/// Reads continue from the previous one, so every item through `end` was read
/// and has shown before `output` or never shows live; every later item,
/// a result included, takes a fresh position after `end`. A Message whose row
/// a read returned silently is then reachable through older pages. A page
/// with more to read ends before its snapshot's end, and an unrowed shown
/// Message would be in neither, so neither marks.
fn readEnd(messages: Messages, more: bool, end: u64, output: u64) ?Boundary {
    if (more or !messages.settled()) return null;
    // End 0 asks the Host for its current end; nothing precedes position 1.
    return .{ .output = output, .cursor = if (end == 0) null else .{ .end = end }, .admitted = end + 1 };
}

test "a silent read marks its end only when complete and every shown Message is rowed" {
    const rowed: Messages = .{ .shown = 4, .answered = 4 };
    try std.testing.expectEqualDeep(Boundary{ .output = 9, .cursor = .{ .end = 30 }, .admitted = 31 }, readEnd(rowed, false, 30, 9).?);
    try std.testing.expectEqual(@as(?Boundary, null), readEnd(rowed, true, 30, 9));
    try std.testing.expectEqual(@as(?Boundary, null), readEnd(.{ .shown = 5, .answered = 4 }, false, 30, 9));
    try std.testing.expectEqualDeep(Boundary{ .output = 0, .cursor = null, .admitted = 1 }, readEnd(.{}, false, 0, 0).?);
}

/// Read boundaries in live output, oldest first. A boundary pairs an absolute
/// live offset with the canonical cursor for everything before it (null: the
/// conversation's start). It is valid only if no conversation item at or after
/// its cursor showed before its offset. Reads record only valid ones: the
/// opening's start, and in a later read each shown item that follows every
/// shown Message's conversation row, and its output's end (see `readEnd`).
/// An incomplete read that shows nothing records none.
pub const Marks = struct {
    pub const Mark = struct { offset: u64, cursor: ?protocol_reply.ConversationCursor, admitted: u64 };
    pub const capacity = 64;
    items: [capacity]Mark = undefined,
    count: usize = 0,

    /// Where a transcript of live output retained from some front begins.
    pub const Start = union(enum) {
        /// Output from the boundary's offset continues the older pages
        /// before its cursor exactly.
        joined: Mark,
        /// No boundary is retained. Output before the front left the view;
        /// older pages continue before the newest boundary that did, if any.
        gap: ?Mark,
    };

    pub fn record(self: *Marks, mark: Mark) void {
        // Equal offsets: nothing showed between the two reads, so the later
        // cursor is valid too and names at least as much before the offset.
        if (self.count != 0 and self.items[self.count - 1].offset == mark.offset) {
            self.items[self.count - 1] = mark;
            return;
        }
        std.debug.assert(self.count == 0 or self.items[self.count - 1].offset < mark.offset);
        if (self.count == self.items.len) {
            // Dropping the oldest boundary keeps the newest before any front
            // until every retained one is after it.
            std.mem.copyForwards(Mark, self.items[0 .. self.count - 1], self.items[1..self.count]);
            self.count -= 1;
        }
        self.items[self.count] = mark;
        self.count += 1;
    }

    /// The first boundary retained from `front`; otherwise the newest before it.
    pub fn start(self: *const Marks, front: u64) Start {
        var before: ?Mark = null;
        for (self.items[0..self.count]) |mark| {
            if (mark.offset >= front) return .{ .joined = mark };
            before = mark;
        }
        return .{ .gap = before };
    }
};

test "a transcript joins at the first retained boundary or shows the gap after the newest evicted one" {
    var marks: Marks = .{};
    try std.testing.expectEqualDeep(Marks.Start{ .gap = null }, marks.start(0));
    marks.record(.{ .offset = 0, .cursor = null, .admitted = 1 });
    marks.record(.{ .offset = 40, .cursor = .{ .end = 9, .before_position = 7 }, .admitted = 7 });
    try std.testing.expectEqualDeep(Marks.Start{ .joined = .{ .offset = 0, .cursor = null, .admitted = 1 } }, marks.start(0));
    try std.testing.expectEqual(@as(u64, 7), marks.start(10).joined.cursor.?.before_position);
    // Past every boundary, older pages continue before the newest one, not
    // the oldest and not none: rows between it and the front are the gap.
    try std.testing.expectEqual(@as(u64, 7), marks.start(41).gap.?.cursor.?.before_position);
    // An equal offset replaces the cursor rather than adding a boundary.
    marks.record(.{ .offset = 40, .cursor = .{ .end = 9, .before_position = 8 }, .admitted = 8 });
    try std.testing.expectEqual(@as(usize, 2), marks.count);
    try std.testing.expectEqual(@as(u64, 8), marks.start(10).joined.cursor.?.before_position);
    for (0..100) |index| marks.record(.{ .offset = 100 + index, .cursor = .{ .end = 200, .before_position = 100 + index }, .admitted = 100 + index });
    try std.testing.expectEqual(@as(usize, 64), marks.count);
    try std.testing.expectEqual(@as(u64, 136), marks.start(0).joined.offset);
    try std.testing.expectEqual(@as(u64, 199), marks.start(500).gap.?.cursor.?.before_position);
}

/// The Ctrl-O page. The Message's length, digest and end are validated
/// before anything shows; its full text then follows at column 0.
pub fn fullMessage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const target = job.message_target.?;
    const Staging = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        newlines: u64 = 0,
        last: u8 = '\n',
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
            self.newlines += std.mem.count(u8, bytes, "\n");
            if (bytes.len != 0) self.last = bytes[bytes.len - 1];
        }
    };
    try job.files.scratch.setLength(task.io, 0);
    var staging: Staging = .{ .io = task.io, .file = job.files.scratch };
    const reference: protocol_reply.CommandObservation.ContentReference = .{ .bytes = target.content.length, .digest = target.content.digest };
    const failure = switch (target.source) {
        .activity => try requests.readActivityContent(job.store, job.session, target.position, target.ordinal, reference, &staging),
        .conversation => try requests.readConversationContent(job.store, job.session, target.position, target.ordinal, reference, &staging),
    };
    if (failure) |value| return requests.failRead(value);
    if (staging.offset != target.content.length) return error.ContentLengthMismatch;
    const lines = staging.newlines + @intFromBool(staging.last != '\n');
    try writeMessagePage(task.io, job.files.scratch, staging.offset, lines, staging.last, target, job.store, job.session, job.files.inspection);
}

/// Writes the Message page for the `length` validated bytes in `scratch`.
fn writeMessagePage(io: std.Io, scratch: std.Io.File, length: u64, lines: u64, last: u8, target: View.Collapsed, store: []const u8, session: []const u8, file: std.Io.File) !void {
    try file.setLength(io, 0);
    var page: MessagePage = .{ .io = io, .file = file };
    var size: [24]u8 = undefined;
    var heading: [96]u8 = undefined;
    try page.feed(View.Mark.summary);
    try page.feed(try std.fmt.bufPrint(&heading, "Message · {d} line{s} · {s}", .{ lines, if (lines == 1) "" else "s", View.kilobytes(target.content.length, &size) }));
    try page.feed(View.Mark.reset ++ "\n");
    if (target.row) {
        try History.writeExport(&page, store, session, target.position, target.ordinal);
        try page.feed("\n");
    }
    try page.feed("\n");
    // Room for the heading again covers the notice and its command.
    page.limit = Viewport.capacity - 2 * page.offset - 128;
    page.heading_lines = page.lines;
    var escaped: View.Escaped(*MessagePage) = .{ .sink = &page, .text = .{ .mode = .multiline } };
    var window: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length and !page.full) {
        const wanted: usize = @intCast(@min(window.len, length - offset));
        if (try scratch.readPositionalAll(io, window[0..wanted], offset) != wanted) return error.TruncatedDisplayScratch;
        try escaped.feed(window[0..wanted]);
        offset += wanted;
    }
    if (!page.full) try escaped.finish();
    if (!page.full) return if (last != '\n') page.feed("\n");
    // Escaped controls and invalid bytes can outgrow the view: keep whole
    // lines, or the first line's start when none fits whole, and say how
    // many lines are not shown in full, never cut silently.
    const whole = page.lines - page.heading_lines;
    const end = if (whole != 0) page.line_end else page.boundary;
    try file.setLength(io, end);
    page.offset = end;
    page.limit = std.math.maxInt(u64);
    page.full = false;
    var notice: [96]u8 = undefined;
    const hidden = lines - whole;
    try page.feed(try std.fmt.bufPrint(&notice, "\n! Display limit reached; {d} line{s} not shown in full\n", .{ hidden, if (hidden == 1) "" else "s" }));
    if (target.row) {
        try History.writeExport(&page, store, session, target.position, target.ordinal);
        try page.feed("\n");
    }
}

test "a Message page past the display limit keeps what fits and says what it cut" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "scratch", .{ .read = true });
    defer scratch.close(io);
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const target: View.Collapsed = .{ .source = .conversation, .position = 7, .ordinal = 0, .content = .{ .length = 0, .digest = @splat(0) }, .row = true };
    const page = try std.testing.allocator.alloc(u8, Viewport.capacity + 4096);
    defer std.testing.allocator.free(page);
    // One line wider than the view, ending in é so a cut could split it;
    // then lines of controls that escaping grows fourfold.
    const Case = struct { body: []const u8, lines: u64, kept: []const u8, notice: []const u8 };
    const wide = try std.testing.allocator.alloc(u8, Viewport.capacity + 5);
    defer std.testing.allocator.free(wide);
    @memset(wide[0 .. Viewport.capacity - 3], 'w');
    for (0..4) |index| @memcpy(wide[Viewport.capacity - 3 + 2 * index ..][0..2], "é");
    const controls = try std.testing.allocator.alloc(u8, 100 * 1000);
    defer std.testing.allocator.free(controls);
    @memset(controls, 0x01);
    for (0..1000) |index| controls[index * 100 + 99] = '\n';
    for ([_]Case{
        .{ .body = wide, .lines = 1, .kept = "wwww", .notice = "\n! Display limit reached; 1 line not shown in full\n" },
        .{ .body = controls, .lines = 1000, .kept = "\\x01\\x01", .notice = "lines not shown in full\n" },
    }) |case| {
        try scratch.setLength(io, 0);
        try scratch.writePositionalAll(io, case.body, 0);
        try writeMessagePage(io, scratch, case.body.len, case.lines, case.body[case.body.len - 1], target, "/s", "a", file);
        const text = page[0..try file.readPositionalAll(io, page, 0)];
        try std.testing.expect(text.len <= Viewport.capacity);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        try std.testing.expect(std.mem.indexOf(u8, text, case.kept) != null);
        const notice = std.mem.indexOf(u8, text, case.notice).?;
        // The export command follows the notice, so the bytes stay reachable.
        try std.testing.expect(std.mem.indexOfPos(u8, text, notice, "--position 7 --ordinal 0") != null);
    }
}

/// A Message page's file. Body bytes stop at `limit`; `line_end` is where
/// the last whole body line written ends.
const MessagePage = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    limit: u64 = std.math.maxInt(u64),
    line_end: u64 = 0,
    // Whole lines written, and how many of them are the heading's.
    lines: u64 = 0,
    heading_lines: u64 = 0,
    // Where the last character written that started before the limit ends:
    // the page never cuts inside a UTF-8 sequence.
    boundary: u64 = 0,
    full: bool = false,

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (self.full) return;
        const fit = bytes[0..@intCast(@min(bytes.len, self.limit -| self.offset))];
        try self.file.writePositionalAll(self.io, fit, self.offset);
        for (fit, 0..) |byte, index| {
            if (byte & 0xc0 != 0x80) self.boundary = self.offset + index;
            if (byte == '\n') {
                self.lines += 1;
                self.line_end = self.offset + index + 1;
            }
        }
        // A sequence that ended within what fit ends the cut there too.
        if (fit.len == bytes.len) self.boundary = self.offset + fit.len;
        self.offset += fit.len;
        self.full = fit.len != bytes.len;
    }
};

pub fn inspectPage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.files.inspection.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.files.inspection, 0);
    var buffer: [4096]u8 = undefined;
    var output = job.files.inspection.writerStreaming(task.io, &buffer);
    if (job.inspection_kind == .help) {
        if (job.inspection_action) |action| {
            try output.interface.writeAll("This Action exceeds the in-app preview. Approval here is disabled.\nDetach with Ctrl-C, inspect the complete exact Action, then decide in your shell:\n");
            for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
                try output.interface.print("rui action {s} --store ", .{command});
                try TerminalText.writeShellWord(&output.interface, job.store);
                try TerminalText.writeShellSession(&output.interface, job.session, false);
                try output.interface.print(" --action {d}\n", .{action});
            }
            try output.interface.writeAll("\n");
        }
        try output.interface.writeAll("Enter sends · Shift-Enter or Alt-J adds a line\nPgUp/PgDn, arrows or the wheel scroll · Esc or Ctrl-G returns to latest or the pending Action\nIn tmux with mouse on, the wheel enters copy mode; use PgUp or arrows\nIn tmux, Shift-Enter can arrive as Enter and send; Alt-J adds a line\nUnder the input: Session · model · effort · context left\nThat line ends with asks before Bash when Bash asks first\nAn Action takes a or d + Enter\n/status settings and work · /requests recovery handles\n/details saved tool output · /history older conversation\nCtrl-O shows the lowest collapsed message in full · Esc, Ctrl-G or Ctrl-O returns\nCtrl-R retries the exact original request, retaining the draft\n/result KEY saved answer · /recover KEY original request\n/discard releases rejected input, retaining the draft\n/setup future defaults · /configure this Session\n/inspect-action exact one-shot diagnostics\n/exit detaches; Host work continues, unsent draft is lost\nLogin: rui auth login codex in your shell.\n");
    } else {
        std.debug.assert(job.inspection_kind == .requests);
        try job.requests(job.init, task.requests(), job.store, job.session, &output.interface);
        try writeSubmission(job, &output.interface);
    }
    try output.flush();
}

/// Where the Conversation before a live page's first item ends: everything
/// earlier precedes its live output. Only a conversation item is a cursor
/// into the Conversation; before an Admission or call row it ends at the
/// previous position, and before the first position there is nothing.
fn beginningBefore(first: protocol.ActivityItem, end: u64) ?protocol_reply.ConversationCursor {
    return switch (first.value) {
        .user, .assistant, .tool_result => .{ .end = end, .before_position = first.position, .before_ordinal = first.ordinal },
        else => if (first.position > 1) .{ .end = first.position - 1 } else null,
    };
}

test "a live page's beginning precedes its first item, without repeating or skipping one" {
    const content: protocol.ActivityItem.Content = .{ .length = 0, .digest = @splat(0) };
    const message: protocol.ActivityItem.Message = .{ .admission = 1, .key = .{}, .turn = null, .state = .applied, .content = content, .admitted_at = 1 };
    const outcome: protocol.ActivityItem.Outcome = .{ .turn = 1, .operation = 1, .code = .{}, .content = null };
    const Case = struct { item: protocol.ActivityItem, cursor: ?protocol_reply.ConversationCursor };
    for ([_]Case{
        .{ .item = .{ .position = 5, .at = 1, .value = .{ .user = message } }, .cursor = .{ .end = 9, .before_position = 5 } },
        .{ .item = .{ .position = 7, .ordinal = 2, .at = 1, .value = .{ .tool_result = .{ .content = content, .presentation = undefined } } }, .cursor = .{ .end = 9, .before_position = 7, .before_ordinal = 2 } },
        // Rows at position 4 that are not conversation items: the
        // Conversation before them ends at 3, so position 4's results stay
        // live and none repeats in the older page.
        .{ .item = .{ .position = 4, .at = 1, .value = .{ .admission = message } }, .cursor = .{ .end = 3 } },
        .{ .item = .{ .position = 4, .at = 1, .value = .{ .outcome = outcome } }, .cursor = .{ .end = 3 } },
        .{ .item = .{ .position = 1, .at = 1, .value = .{ .admission = message } }, .cursor = null },
    }) |case| try std.testing.expectEqualDeep(case.cursor, beginningBefore(case.item, 9));
}

test "a Host command writes its page and inherits no saved terminal descriptor" {
    const Probe = struct {
        var before: [256]bool = undefined;
        var leaked: ?c_int = null;

        fn inheritable() [256]bool {
            var open: [256]bool = @splat(false);
            for (3..open.len) |fd| {
                const flags = std.c.fcntl(@intCast(fd), std.c.F.GETFD);
                open[fd] = flags >= 0 and flags & std.c.FD_CLOEXEC == 0;
            }
            return open;
        }

        fn command(_: std.process.Init, _: client.Requests, _: []const u8, _: []const u8, _: []u8) anyerror!void {
            for (inheritable(), before, 0..) |now, was, fd| if (now and !was) {
                leaked = @intCast(fd);
            };
            _ = std.c.write(1, "page\n", 5);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer page.close(io);
    var interrupted: client.Cancellation = .{};
    var job: Job = .{ .files = .{ .scratch = undefined, .action = undefined, .inspection = page, .status = undefined }, .command = Probe.command, .interrupted = &interrupted };
    var task: Task = .{ .io = io };
    Probe.before = Probe.inheritable();
    try runCommand(&job, &task);
    try std.testing.expectEqual(@as(?c_int, null), Probe.leaked);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("page\n", bytes[0..try page.readPositionalAll(io, &bytes, 0)]);
}

test "the Session line takes its facts from Current and reads again after a change" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const reference = "{\"bytes\":\"7\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}";
    const reference_format = "{{\"bytes\":\"7\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}}";
    var line: ?Line = null;
    const unread: Hint = .unread;
    try std.testing.expect((Line{}).facts(&unread, "k7m2qx") == null);
    const moment: Moment = .{ .revision = 3, .end = 40 };
    var page: protocol.ActivityFacts = .{ .end = 40, .work = .{ .revision = 3 } };
    try std.testing.expect(Line.stale(null, &page));
    for ([_]struct { label: []const u8, mode: []const u8, effort: []const u8, trigger: []const u8, estimate: []const u8, first: []const u8, name: []const u8, left: ?u8 }{
        .{ .label = "\"Fix \\u001b[31mtests\"", .mode = "ask", .effort = "\"low\"", .trigger = "\"1000\"", .estimate = "\"310\"", .first = "null", .name = "Fix \\x1b[31mtests", .left = 69 },
        .{ .label = "null", .mode = "bypass", .effort = "null", .trigger = "null", .estimate = "null", .first = "null", .name = "k7m2qx", .left = null },
        .{ .label = "null", .mode = "bypass", .effort = "\"high\"", .trigger = "\"1000\"", .estimate = "\"1000\"", .first = "{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1\",\"sender\":null,\"content\":" ++ reference ++ "}", .name = "k7m2qx", .left = 0 },
    }) |case| {
        var bytes: [4096]u8 = undefined;
        const report = try std.fmt.bufPrint(&bytes, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":{{\"reference\":\"k7m2qx\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"gpt\\u0001x\",\"revision\":\"3\",\"tools\":[],\"permission_mode\":\"{s}\",\"instructions\":" ++ reference_format ++ ",\"output_schema\":null,\"reasoning_effort\":{s},\"reasoning_effort_override\":null,\"compaction_trigger\":{s},\"context_estimate\":{s},\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":{s},\"created_at\":\"1\"}},\"pending_messages\":\"0\",\"work\":{{\"state\":{{\"kind\":\"idle\",\"since\":\"1\"}},\"turn\":null,\"operation\":null,\"first_action\":null,\"latest_outcome\":null}},\"peers\":{{\"from_person_at\":null}},\"first_message\":{s},\"selected_message\":null,\"recent_messages\":[],\"actions\":{{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]}},\"rejected_calls\":{{\"count\":\"0\",\"items\":[]}},\"actionable_permissions\":[],\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}}}", .{ case.mode, case.effort, case.trigger, case.estimate, case.label, case.first });
        try file.setLength(io, 0);
        try file.writePositionalAll(io, report, 0);
        const reply = protocol_reply.CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = report.len } }) catch |err| {
            std.debug.print("{s}\n", .{report});
            return err;
        };
        Line.take(&line, &reply.current, moment);
        try std.testing.expect(!Line.stale(line.?.read, &page));
        const facts = line.?.facts(&unread, "k7m2qx").?;
        try std.testing.expectEqualStrings(case.name, facts.name);
        // The model's control byte shows as text, not as a terminal control.
        try std.testing.expectEqualStrings("gpt\\x01x", facts.model);
        try std.testing.expectEqual(case.left, facts.left);
        try std.testing.expectEqual(std.mem.eql(u8, case.mode, "ask"), facts.asks);
        try std.testing.expectEqual(!std.mem.eql(u8, case.effort, "null"), facts.effort != null);
        try std.testing.expectEqual(!std.mem.eql(u8, case.first, "null"), line.?.first_position != null);
    }
    // The first line names an unlabelled Session once read; a blank one
    // leaves the reference.
    const hint: Hint = .{ .line = plain(session_line.max_line_bytes, session_line.firstLine("  Summarize\tCI\r\nand more")) };
    try std.testing.expectEqualStrings("Summarize CI", line.?.facts(&hint, "k7m2qx").?.name);
    const absent: Hint = .absent;
    try std.testing.expectEqualStrings("k7m2qx", line.?.facts(&absent, "k7m2qx").?.name);
    // Another revision or end position makes the facts stale; another page
    // of the same moment does not.
    for ([_]Moment{ .{ .revision = 4, .end = 40 }, .{ .revision = 3, .end = 41 } }) |next| {
        page.work.revision = next.revision;
        page.end = next.end;
        try std.testing.expect(Line.stale(moment, &page));
    }
    page.end = 40;
    page.work.revision = 3;
    page.work.work = .{ .turn = 9, .operation = 12 };
    try std.testing.expect(!Line.stale(moment, &page));
}

test "plain text keeps whole code points within its bound, escapes controls and cuts once" {
    try std.testing.expectEqualStrings("a b c", plain(16, "a\tb\nc").slice());
    try std.testing.expectEqualStrings("x\\x1b[31my", plain(16, "x\x1b[31my").slice());
    // Every length around the bound, with two-byte code points and escapes:
    // the value is the whole escaped text when it fits, else its longest
    // whole-code-point start that leaves room for the ellipsis, then one.
    for ([_][]const u8{ "é", "a", "\x01", "中" }) |unit| for (0..12) |count| {
        var bytes: [64]u8 = undefined;
        for (0..count) |at| @memcpy(bytes[at * unit.len ..][0..unit.len], unit);
        const source = bytes[0 .. count * unit.len];
        var escaped: [256]u8 = undefined;
        var out = std.Io.Writer.fixed(&escaped);
        var text: TerminalText = .{ .mode = .multiline };
        try text.feed(&out, source);
        try text.finish(&out);
        const whole = out.buffered();
        const value = plain(12, source);
        const shown = value.slice();
        try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        try std.testing.expect(shown.len <= 12);
        if (whole.len <= 12) {
            try std.testing.expectEqualStrings(whole, shown);
        } else {
            const kept = shown[0 .. shown.len - session_line.ellipsis.len];
            try std.testing.expect(std.mem.endsWith(u8, shown, session_line.ellipsis));
            try std.testing.expect(std.mem.startsWith(u8, whole, kept));
            // One more escaped unit would not leave room for the ellipsis.
            const unit_len = whole.len / count;
            try std.testing.expect(kept.len % unit_len == 0 and kept.len + unit_len + session_line.ellipsis.len > 12);
        }
    };
}
