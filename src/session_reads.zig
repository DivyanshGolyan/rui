//! The Session frontend's reads. Each worker borrows only its Job: inputs
//! frozen at launch and a result the UI applies after join. This module does
//! not import the frontend, so no worker can read or write it.

const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const View = @import("session_view.zig");
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const TerminalText = @import("TerminalText.zig");
const ReadPhase = departure.ReadPhase;

pub const Command = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []u8) anyerror!void;
pub const Requests = *const fn (std.process.Init, client.Requests, []const u8, []const u8, *std.Io.Writer) anyerror!void;
/// Writes /status from one Current capture whose attention rows are in the file.
pub const Status = *const fn (std.Io, []const u8, []const u8, *const client.Current, std.Io.File, *std.Io.Writer) anyerror!void;
pub const Inspection = enum { status, requests, help, command };

/// One read. Inputs are frozen at launch; the worker writes only `result`,
/// which the UI reads after join. No worker reads or writes the controller.
/// Live output renders into the inspection scratch file and shows whole, with
/// its footer, status and cursor, in one UI step after join.
pub const Job = struct {
    init: std.process.Init = undefined,
    store: []const u8 = "",
    session: []const u8 = "",
    scratch: std.Io.File = undefined,
    action_file: std.Io.File = undefined,
    inspection_file: std.Io.File = undefined,
    status_file: std.Io.File = undefined,
    colour: bool = false,
    command: Command = undefined,
    requests: Requests = undefined,
    status: Status = undefined,
    phase: ReadPhase = .activity,
    cursor: client.ActivityCursor = .{},
    opening: bool = false,
    older: ?client.ConversationCursor = null,
    transcript: u64 = 0,
    inspection_kind: Inspection = .status,
    // A command observes exit or a signal as an interruption.
    interrupted: *client.Cancellation = undefined,
    command_text: [@typeInfo(@FieldType(Input, "command_buffer")).array.len]u8 = undefined,
    command_text_length: usize = 0,
    inspection_submission: ?Submission.View = null,
    inspection_action: ?u64 = null,
    // A settled scan renders /status from its own capture: when the user
    // asks for it, or when the shown page (`status_shown`) would change.
    open_status: bool = false,
    watch_status: bool = false,
    status_shown: u64 = 0,
    // Apply the page even if the work changed while it was read.
    force: bool = false,
    result: struct {
        // The work did not change while the page was read, so its history,
        // footer and status describe one moment.
        settled: bool = false,
        current: client.Current = undefined,
        // /status from `current` is in the status file.
        status: bool = false,
        status_digest: u64 = 0,
        // The newest Message admission this page holds, for Sent.
        delivered: u64 = 0,
        // Where this read's output begins in the conversation; null cursor at
        // its start. A later read that shows nothing records no boundary.
        mark: ?struct { cursor: ?client.ConversationCursor } = null,
        // Admission ids, for whether a boundary is safe (see Marks): the
        // newest Message this read showed as an Admission or queued preview,
        // the newest conversation row it read, and the newest conversation
        // row before the item its boundary names.
        shown_admission: u64 = 0,
        answered: u64 = 0,
        answered_before: u64 = 0,
        live: View.Live = .{},
        cursor: client.ActivityCursor = .{},
        compact_tools: bool = false,
        history_cursor: ?client.ConversationCursor = null,
        // Output custody began; a later failure is not a silent preparation one.
        rendering: bool = false,
        action: ?u64 = null,
        summary: View.ActionSummary = .{},
        // Bytes of live output staged in the inspection scratch file.
        output_length: u64 = 0,
    } = .{},
};

/// What the composer status and consent read from Current.
pub fn sameWork(shown: client.Current, observed: client.Current) bool {
    return shown.work.status.value == observed.work.status.value and std.meta.eql(shown.work.turn, observed.work.turn) and
        std.meta.eql(shown.work.operation, observed.work.operation) and shown.first_action == observed.first_action and
        std.meta.eql(shown.settings.revision, observed.settings.revision);
}

/// Host commands keep their one-shot output owners. Their complete stdout and
/// stderr become an inspection page while the Session screen keeps drawing
/// through its own descriptor. No command reads terminal input.
pub fn runCommand(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.inspection_file, 0);
    // Saved descriptors must not leak into anything the command executes.
    const saved = [2]c_int{ std.c.fcntl(1, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)), std.c.fcntl(2, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)) };
    defer for (saved) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    if (saved[0] < 0 or saved[1] < 0) return error.TerminalCleanupFailed;
    // Redirected descriptors are output custody: any failure now is fatal.
    job.result.rendering = true;
    const page = job.inspection_file.handle;
    const result = if (std.c.dup2(page, 1) < 0 or std.c.dup2(page, 2) < 0) error.TerminalCleanupFailed else job.command(job.init, .{ .io = task.io, .cancellation = job.interrupted }, job.store, job.session, job.command_text[0..job.command_text_length]);
    if (std.c.dup2(saved[0], 1) < 0 or std.c.dup2(saved[1], 2) < 0) return error.TerminalCleanupFailed;
    return result;
}

pub fn permission(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (!job.result.settled) return;
    if (job.result.current.first_action) |action| {
        try job.action_file.setLength(task.io, 0);
        var output: DisplayCapture = .{ .task = task, .file = job.action_file };
        job.result.summary = try View.permission(task.requests(), job.store, job.session, action, job.result.current.settings.workspace.slice(), job.scratch, &output, job.colour);
        job.result.compact_tools = false;
        job.result.action = action;
    }
}

pub fn scan(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const before = try View.current(requests, job.store, job.session, job.scratch);
    var cursor = job.cursor;
    if (job.opening) cursor.direction = .backward;
    const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    // The page describes one moment only if the work did not change while it
    // was read; otherwise the UI reads again rather than pair them.
    job.result.current = try View.current(requests, job.store, job.session, job.scratch);
    if (!job.force and !sameWork(before, job.result.current)) return;
    job.result.settled = true;
    // Before anything else reuses scratch, which holds this capture's rows.
    if (job.open_status or job.watch_status) {
        job.result.status_digest = try statusDigest(job, task.io);
        if (job.open_status or job.result.status_digest != job.status_shown) {
            try job.status_file.setLength(task.io, 0);
            try task.io.vtable.fileSeekTo(task.io.userdata, job.status_file, 0);
            var buffer: [4096]u8 = undefined;
            var output = job.status_file.writerStreaming(task.io, &buffer);
            try writeStatus(job, task.io, &output.interface);
            try output.flush();
            job.result.status = true;
        }
    }
    job.result.live = View.Live.init(page.facts.call_activity);
    // Admission ids follow Session positions, so the newest one shown
    // means every earlier Message was delivered too.
    for (page.facts.items[0..page.facts.count]) |item| switch (item.value) {
        .admission, .user => |message| job.result.delivered = @max(job.result.delivered, message.admission),
        else => {},
    };
    if (job.opening) {
        var mark: ?client.ConversationCursor = if (page.facts.more) .{ .end = page.facts.end } else null;
        if (page.facts.more) for (page.facts.items[0..page.facts.count]) |item| {
            switch (item.value) {
                .user, .assistant, .tool_result => mark = .{ .end = page.facts.end, .before_position = item.position, .before_ordinal = item.ordinal },
                else => {},
            }
        };
        job.result.mark = .{ .cursor = mark };
    }
    try job.inspection_file.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.inspection_file };
    if (job.opening) {
        const pending = try View.pending(requests, job.store, job.session, page.facts.end);
        try pending.render(requests, job.store, job.session, &output);
        job.result.shown_admission = pending.newest;
    }
    try View.render(requests, job.store, job.session, &page, &output, job.colour, &job.result.compact_tools);
    job.result.output_length = output.offset;
    job.result.shown_admission = @max(job.result.shown_admission, output.shown_admission);
    // A later read's boundary sits where its first shown item begins. Rows
    // before it showed elsewhere (a Message's own Admission) or not at all, so
    // older pages must include them. A read that shows nothing marks nothing:
    // the next read that shows something starts at this same offset.
    var before_first = true;
    for (page.facts.items[0..page.facts.count]) |item| {
        if (output.first) |first| {
            if (item.position == first.position and item.ordinal == first.ordinal) before_first = false;
        }
        if (item.value == .user) {
            job.result.answered = @max(job.result.answered, item.value.user.admission);
            if (before_first) job.result.answered_before = @max(job.result.answered_before, item.value.user.admission);
        }
    }
    if (!job.opening) {
        if (output.first) |first| job.result.mark = .{ .cursor = beginningBefore(first, page.facts.end) };
    }
    if (job.opening) {
        job.result.cursor = .{ .position = page.facts.end };
    } else {
        job.result.cursor = page.continuation() orelse .{ .position = page.facts.end };
        if (!page.facts.more) job.result.cursor.end = null;
    }
}

/// The /status page for the Current capture whose rows are in scratch.
fn writeStatus(job: *const Job, io: std.Io, out: *std.Io.Writer) !void {
    try job.status(io, job.store, job.session, &job.result.current, job.scratch, out);
    try writeSubmission(job, out);
}

fn statusDigest(job: *const Job, io: std.Io) !u64 {
    var buffer: [256]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(.init(0), &buffer);
    try writeStatus(job, io, &hashing.writer);
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
    current: ?protocol.ActivityItem = null,
    /// The first item whose rendering wrote bytes.
    first: ?protocol.ActivityItem = null,
    /// The newest Message shown as an Admission row.
    shown_admission: u64 = 0,

    pub fn item(self: *@This(), value: protocol.ActivityItem) void {
        self.current = value;
    }

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        try self.file.writePositionalAll(self.task.io, bytes, self.offset);
        self.offset += bytes.len;
        if (bytes.len == 0) return;
        if (self.first == null) self.first = self.current;
        if (self.current) |current| if (current.value == .admission) {
            self.shown_admission = @max(self.shown_admission, current.value.admission.admission);
        };
    }
};

pub fn inspectPage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.inspection_file.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.inspection_file, 0);
    var buffer: [4096]u8 = undefined;
    var output = job.inspection_file.writerStreaming(task.io, &buffer);
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
        try output.interface.writeAll("Enter sends · Shift-Enter or Alt-J adds a line\nPgUp/PgDn, arrows or the wheel scroll · Esc or Ctrl-G returns to latest or the pending Action\nIn tmux with mouse on, the wheel enters copy mode; use PgUp or arrows\nIn tmux, Shift-Enter can arrive as Enter and send; Alt-J adds a line\n/status shows whether Bash asks first · an Action takes a or d + Enter\n/status settings and work · /requests recovery handles\n/details saved tool output · /history older conversation\nCtrl-R retries the exact original request, retaining the draft\n/result KEY saved answer · /recover KEY original request\n/discard releases rejected input, retaining the draft\n/setup future defaults · /configure this Session\n/inspect-action exact one-shot diagnostics\n/exit detaches; Host work continues, unsent draft is lost\nLogin: rui auth login codex in your shell.\n");
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
fn beginningBefore(first: protocol.ActivityItem, end: u64) ?client.ConversationCursor {
    return switch (first.value) {
        .user, .assistant, .tool_result => .{ .end = end, .before_position = first.position, .before_ordinal = first.ordinal },
        else => if (first.position > 1) .{ .end = first.position - 1 } else null,
    };
}

test "a live page's beginning precedes its first item, without repeating or skipping one" {
    const content: protocol.ActivityItem.Content = .{ .length = 0, .digest = @splat(0) };
    const message: protocol.ActivityItem.Message = .{ .admission = 1, .key = .{}, .turn = null, .state = .applied, .content = content };
    const outcome: protocol.ActivityItem.Outcome = .{ .turn = 1, .operation = 1, .code = .{}, .content = null };
    const Case = struct { item: protocol.ActivityItem, cursor: ?client.ConversationCursor };
    for ([_]Case{
        .{ .item = .{ .position = 5, .value = .{ .user = message } }, .cursor = .{ .end = 9, .before_position = 5 } },
        .{ .item = .{ .position = 7, .ordinal = 2, .value = .{ .tool_result = .{ .content = content, .presentation = undefined } } }, .cursor = .{ .end = 9, .before_position = 7, .before_ordinal = 2 } },
        // Rows at position 4 that are not conversation items: the
        // Conversation before them ends at 3, so position 4's results stay
        // live and none repeats in the older page.
        .{ .item = .{ .position = 4, .value = .{ .admission = message } }, .cursor = .{ .end = 3 } },
        .{ .item = .{ .position = 4, .value = .{ .outcome = outcome } }, .cursor = .{ .end = 3 } },
        .{ .item = .{ .position = 1, .value = .{ .admission = message } }, .cursor = null },
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
    var job: Job = .{ .inspection_file = page, .command = Probe.command, .interrupted = &interrupted };
    var task: Task = .{ .io = io };
    Probe.before = Probe.inheritable();
    try runCommand(&job, &task);
    try std.testing.expectEqual(@as(?c_int, null), Probe.leaked);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("page\n", bytes[0..try page.readPositionalAll(io, &bytes, 0)]);
}
