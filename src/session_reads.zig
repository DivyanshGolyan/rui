//! The Session frontend's reads. Each worker borrows only its Job: inputs
//! frozen at launch and a result the UI applies after join. This module does
//! not import the frontend, so no worker can read or write it.

const std = @import("std");
const client = @import("client.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const View = @import("session_view.zig");
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const TerminalText = @import("TerminalText.zig");
const ReadPhase = departure.ReadPhase;

pub const Command = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []u8) anyerror!void;
pub const Inspect = *const fn (std.process.Init, client.Requests, []const u8, []const u8, []const u8, *std.Io.Writer) anyerror!void;
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
    colour: bool = false,
    command: Command = undefined,
    inspect: Inspect = undefined,
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
    // A /status reload shows only while its page is still the one on screen.
    refresh: bool = false,
    // The /status page is shown: digest what it would now report.
    watch_status: bool = false,
    // Apply the page even if the work changed while it was read.
    force: bool = false,
    result: struct {
        // The work did not change while the page was read, so its history,
        // footer and status describe one moment.
        settled: bool = false,
        current: client.Current = undefined,
        status_digest: u64 = 0,
        // Message keys in this page, for Sent.
        keys: [16][36]u8 = undefined,
        key_count: usize = 0,
        // Where this read's output begins in the conversation; null cursor at
        // its start. A page without items records no boundary.
        mark: ?struct { cursor: ?client.ConversationCursor } = null,
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
    if (job.watch_status) job.result.status_digest = try statusDigest(job, task.io);
    job.result.live = View.Live.init(page.facts.call_activity);
    for (page.facts.items[0..page.facts.count]) |item| switch (item.value) {
        .admission, .user => |message| if (message.key.slice().len == 36) {
            job.result.keys[job.result.key_count] = message.key.slice()[0..36].*;
            job.result.key_count += 1;
        },
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
    } else if (page.facts.count != 0) {
        // Everything before this page's first item precedes its live output.
        const first = page.facts.items[0];
        job.result.mark = .{ .cursor = .{ .end = page.facts.end, .before_position = first.position, .before_ordinal = first.ordinal } };
    }
    try job.inspection_file.setLength(task.io, 0);
    var output: DisplayCapture = .{ .task = task, .file = job.inspection_file };
    if (job.opening) {
        const pending = try View.pending(requests, job.store, job.session, page.facts.end);
        try pending.render(requests, job.store, job.session, &output);
    }
    try View.render(requests, job.store, job.session, &page, &output, job.colour, &job.result.compact_tools);
    job.result.output_length = output.offset;
    if (job.opening) {
        job.result.cursor = .{ .position = page.facts.end };
    } else {
        job.result.cursor = page.continuation() orelse .{ .position = page.facts.end };
        if (!page.facts.more) job.result.cursor.end = null;
    }
}

/// What the /status page would now show, from the Current capture in scratch.
fn statusDigest(job: *const Job, io: std.Io) !u64 {
    var buffer: [256]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(.init(0), &buffer);
    try job.status(io, job.store, job.session, &job.result.current, job.scratch, &hashing.writer);
    try hashing.writer.flush();
    return hashing.hasher.final();
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

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        try self.file.writePositionalAll(self.task.io, bytes, self.offset);
        self.offset += bytes.len;
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
        try output.interface.writeAll("Enter sends · Shift-Enter or Alt-J adds a line\nPgUp/PgDn, arrows or the wheel scroll · Esc or Ctrl-G returns to latest or the pending Action\nIn tmux with mouse on, the wheel enters copy mode; use PgUp or arrows\n/status shows whether Bash asks first · an Action takes a or d + Enter\n/status settings and work · /requests recovery handles\n/details saved tool output · /history older conversation\nCtrl-R retries the exact original request, retaining the draft\n/result KEY saved answer · /recover KEY original request\n/discard releases rejected input, retaining the draft\n/setup future defaults · /configure this Session\n/inspect-action exact one-shot diagnostics\n/exit detaches; Host work continues, unsent draft is lost\nLogin: rui auth login codex in your shell.\n");
    } else {
        if (job.inspection_kind == .status) {
            // The page and its digest come from one capture, so a scan's
            // digest of the same facts matches it exactly.
            job.result.current = try View.current(task.requests(), job.store, job.session, job.scratch);
            try job.status(task.io, job.store, job.session, &job.result.current, job.scratch, &output.interface);
            job.result.status_digest = try statusDigest(job, task.io);
        } else try job.inspect(job.init, task.requests(), job.store, job.session, "/requests", &output.interface);
        // Snapshot before launch: this read cannot race Admission settlement.
        if (job.inspection_submission) |submission| {
            try output.interface.print("Original reserved request: {s}\n{s}\n", .{ submission.key, if (submission.state == .rejected) "Submission rejected; /discard releases only this original, retaining the next draft." else "Publication/admission may be incomplete; Ctrl-R retries this exact original." });
            if (submission.last_error) |err| try output.interface.print("Last submission error: {s}\n", .{@errorName(err)});
        }
    }
    try output.flush();
}
