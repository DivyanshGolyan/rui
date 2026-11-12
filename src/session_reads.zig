//! The Session frontend's reads. Each worker borrows only its Job: inputs
//! frozen at launch and a result the UI applies after join. This module does
//! not import the frontend, so no worker can read or write it.

const std = @import("std");
const tool_fold = @import("tool_fold.zig");
const socket_os = @import("os/socket.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const activity_reply = @import("activity_reply.zig");
const Input = @import("SessionInput.zig");
const Submission = @import("SessionSubmission.zig");
const Task = @import("ClientTask.zig");
const View = @import("session_view.zig");
const Editor = @import("TerminalEditor.zig");
const History = @import("session_history.zig");
const departure = @import("session_departure.zig");
const TerminalText = @import("TerminalText.zig");
const Viewport = @import("ConversationViewport.zig");
const session_line = @import("session_line.zig");
const slash_commands = @import("slash_commands.zig");
const queued_line = @import("queued_line.zig");
const Bounded = @import("bounded.zig").Bounded;
const AnswerRenderer = @import("AnswerRenderer.zig");
const status_page = @import("status_page.zig");
const ChatInfo = @import("chat_info.zig");
const ReadPhase = departure.ReadPhase;
const feed_reads = @import("feed_reads.zig");
const feed_window = @import("feed_window.zig");
const Key = feed_window.Key;
const FeedPolicy = feed_reads.Policy(Key);
pub const LatestEnding = feed_reads.Ending(Key);

/// Independent raw rendering in inspection. The shell prepares the text and
/// pairs summary markers with the retained targets in emission order.
pub const RenderedRow = struct {
    key: Key,
    offset: u64,
    length: u64,
    tight: bool,
    provisional: bool,
    collapsed_targets: [16]View.Collapsed = undefined,
    collapsed_count: usize = 0,
};

pub const Configure = *const fn (std.process.Init, client.ReadContext, []const u8, []const u8, ChatInfo.Edit) anyerror!bool;
pub const Command = *const fn (std.process.Init, client.ReadContext, []const u8, []const u8, []u8) anyerror!void;
/// Writes /requests' recovery handles, and offers each saved Message among
/// them to the page's list.
pub const Requests = *const fn (std.process.Init, client.ReadContext, []const u8, []const u8, *std.Io.Writer, *SavedRequests) anyerror!void;
/// The saved Messages a /requests page offers, under the Store's key bound.
pub const SavedRequests = slash_commands.Requests(protocol.max_key_bytes);
/// Local-only adapter: consumes an already-read Current and files, never
/// Host transport. Takes the chat info inspection of the Session, whose
/// attention rows are in the first file, into the Session given. True when
/// it differs from the shown one (always without one): the second file then
/// lists its Actions awaiting approval, as the page shows them.
pub const Status = *const fn (std.Io, *const protocol_reply.Current, std.Io.File, *status_page.Session, ?*const status_page.Session, std.Io.File) anyerror!bool;

pub const Inspection = union(enum) { requests, command, copy: Copy };

/// What a /copy sends: the last answer or its last code block to the
/// clipboard, or the last answer to a file.
pub const Copy = slash_commands.Copy;

/// What a /copy read found. The clipboard takes its range of the scratch
/// file after the UI joins the read.
pub const Copied = union(enum) { no_answer, no_code, too_large, clipboard: AnswerRenderer.LastCode.Range, saved };

pub const copy_name_bytes = "rui--answer.md".len + protocol.session_id_bytes;

/// The file /copy file writes, in the directory Rui runs in.
pub fn copyName(buffer: *[copy_name_bytes]u8, session: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "rui-{s}-answer.md", .{session}) catch unreachable;
}

/// One read. Inputs are frozen at launch; the worker writes only `result`,
/// which the UI reads after join. No worker reads or writes the controller.
/// Live output renders into the inspection scratch file and shows whole, with
/// its footer, status and cursor, in one UI step after join.
/// The frontend's private scratch files, which a read borrows whole.
/// Inspection is worker-owned; details is UI-owned repair scratch.
/// The paired captures alternate without borrowing live widget storage.
pub const Files = struct { scratch: std.Io.File, action: std.Io.File, inspection: std.Io.File, details: std.Io.File, actions: [2]std.Io.File };

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
    provider: ?protocol.Provider = null,
    effort: ?protocol.ReasoningEffort = null,
    left: ?u8 = null,
    asks: bool = false,
    archive_state: protocol.SessionArchiveState = .active,

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
            .provider = settings.provider.value,
            .effort = if (settings.reasoning_effort) |effort| effort.value else null,
            .left = if (trigger != null and estimate != null) session_line.left(trigger.?.value, estimate.?.value) else null,
            .asks = settings.permission_mode.value == .ask,
            .archive_state = current.archive_state,
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

/// Reads the hint from the first Message at `position`. The name is only a
/// hint, so a Message the Host refuses or that is not text names the Session
/// by its reference instead.
fn readHint(requests: client.Requests, job: *const Job, position: u64) !Hint {
    const line = try readFirstLine(requests, job, position, .absent) orelse return .absent;
    return if (line.len == 0) .absent else .{ .line = line };
}

/// The first line of the Message at `position`, terminal-safe. A canonical
/// Store, transport or cancellation failure fails the read, as the page's
/// would; so does a refusal or bytes that are not text, unless `refused` is
/// `.absent`, which returns null for them.
fn readFirstLine(requests: client.Requests, job: *const Job, position: u64, refused: enum { absent, fails }) !?queued_line.Line {
    var buffer: [session_line.max_line_bytes + 1]u8 = undefined;
    const reply = requests.readActivityPrefix(job.store, job.session, position, &buffer) catch |err| switch (err) {
        error.InvalidResponse => return if (refused == .absent) null else err,
        else => return err,
    };
    return switch (reply) {
        .line => |bytes| plain(session_line.max_line_bytes, session_line.firstLine(bytes)),
        .failure => |failure| if (refused == .absent and failure.err() != error.CanonicalStoreFailure) null else requests.failRead(failure),
    };
}

/// Text the Host holds, without terminal controls and with its tabs and line
/// ends as spaces, within `limit` bytes: cut at a code point and ended with
/// an ellipsis when longer. One pass, straight into the value.
fn plain(comptime limit: usize, bytes: []const u8) Bounded(limit) {
    var value: Bounded(limit) = .{ .len = 0 };
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

/// What a Ctrl-O read renders.
pub const Target = union(enum) {
    /// This collapsed block's Message, in full.
    message: View.Collapsed,
    /// This tool row again, with its output shown or hidden.
    tool: struct { key: Key, open: bool },
};

pub const Job = struct {
    init: std.process.Init = undefined,
    /// Borrowed from the frontend until this read joins.
    home: []const u8 = "",
    store: []const u8 = "",
    session: []const u8 = "",
    files: Files = undefined,
    colour: bool = false,
    width_method: Viewport.Method = .wcwidth,
    command: Command = undefined,
    configure: ?Configure = null,
    info_edit: ?ChatInfo.Edit = null,
    requests: Requests = undefined,
    status: Status = undefined,
    phase: ReadPhase = .activity,
    cursor: protocol_reply.ActivityCursor = .{},
    opening: bool = false,
    feed_page: ?FeedPolicy.Page = null,
    target: ?Target = null,
    /// The tool rows the person left open, as of this read's start.
    opened: feed_window.Opened = .{},
    recall: ?Input.Step = null,
    /// Frozen live fact for scans; fills neither read nor publish it.
    latest_ending: ?LatestEnding = null,
    /// Retry request: newest person Message strictly before this ending.
    retry: ?Key = null,
    queued_line: u64 = 0,
    inspection_kind: Inspection = .requests,
    // A command observes exit or a signal as an interruption.
    interrupted: *client.Cancellation = undefined,
    command_text: [@typeInfo(@FieldType(Input, "command_buffer")).array.len]u8 = undefined,
    command_text_length: usize = 0,
    inspection_submission: ?Submission.View = null,

    // A scan takes chat info from its own Current capture: when the user

    // asks for it, or while the page shows `status_shown`, into
    // `status_taken`, listing its Actions in `status_actions`.
    open_status: bool = false,
    watch_status: bool = false,
    status_shown: ?*const status_page.Session = null,
    status_taken: *status_page.Session = undefined,
    status_actions: std.Io.File = undefined,
    // The moment the UI's Session line was read at, and whether it still
    // needs the unlabelled Session's name.
    line_read: ?Moment = null,
    hint_wanted: bool = false,
    // The Session's provider as the UI's Session line holds it, null until
    // that line is first read. A Session never changes provider.
    provider: ?protocol.Provider = null,
    result: struct {
        // The work the page's own Store read saw: its history, footer and
        // consent describe one moment.
        work: protocol.PageWork = .{},
        // The Session line's facts, when this read took them.
        line: ?Line = null,
        // The unlabelled Session's name, when this read looked it up.
        hint: ?Hint = null,
        // `status_taken` holds chat info from one Current capture, which
        // differs from the shown page.
        status: bool = false,
        rows: [16]RenderedRow = undefined,
        row_count: usize = 0,
        /// Activity edges include hidden rows, so filtered fills make progress.
        low: ?Key = null,
        high: ?Key = null,
        at_start: bool = false,
        at_end: bool = false,
        new_rows: usize = 0,
        // The Messages waiting at this read's cursor, and the newest one's
        // first line when the row shows it and does not hold it yet.
        queued: protocol.Queued = .{},
        queued_line: ?queued_line.Shown = null,
        live: View.Live = .{},
        latest_ending: ?LatestEnding = null,
        cursor: protocol_reply.ActivityCursor = .{},
        // Output custody began; a later failure is not a silent preparation one.
        rendering: bool = false,
        // Only confirmed stderr restoration permits exit to replay this page.
        command_stderr_restored: bool = false,
        info_saved: bool = false,
        action: ?u64 = null,
        summary: View.ActionSummary = .{},
        // Bytes of live output staged in the inspection scratch file.
        output_length: u64 = 0,
        copied: Copied = .no_answer,
        // What a /requests page offers to act on.
        requests: SavedRequests = .{},
        // The sent Message a recall step found, its text staged in scratch.
        recalled: ?Input.Found = null,
        // The step passed over a sent Message the draft cannot hold.
        recall_passed: bool = false,
        retry: ?Retry = null,
    } = .{},

    /// The Session's provider: this read's own Session line once it took
    /// one, else the UI's.
    fn sessionProvider(self: *const Job) ?protocol.Provider {
        return if (self.result.line) |line| line.provider else self.provider;
    }

    /// The worker borrows only its Job, including string edit storage.
    pub fn setInfoEdit(self: *Job, edit: ChatInfo.Edit) !void {
        self.info_edit = edit;
        switch (edit) {
            .label, .model => |text| {
                if (text.len > self.command_text.len) return error.ValueTooLong;
                @memcpy(self.command_text[0..text.len], text);
                self.info_edit = if (edit == .label) .{ .label = self.command_text[0..text.len] } else .{ .model = self.command_text[0..text.len] };
            },
            else => {},
        }
    }

    /// Call only after a successful reader join. Scratch is borrowed until the
    /// next reader starts; consume/copy the exact range before reusing it.
    pub fn retryCompletion(self: *const Job, latest: ?LatestEnding) RetryCompletion {
        const key = self.retry.?;
        if (latest == null or !latest.?.matches(key)) return .stale;
        return switch (self.result.retry.?) {
            .stale => .stale,
            .message => |message| .{ .message = message },
            .failure => |failure| .{ .failure = failure },
        };
    }
};

pub const RetryFailure = enum { no_message, too_large };
pub const RetryMessage = struct { ending: Key, position: u64, length: usize };
const Retry = union(enum) { stale, message: RetryMessage, failure: RetryFailure };
pub const RetryCompletion = union(enum) { stale, message: RetryMessage, failure: RetryFailure };

/// Runs on ClientTask, never on the key path. No fallback to an older Message:
/// failure of the one newest admission fails the request. Transport, canonical
/// Store, cancellation and local I/O failures retain ClientTask's error boundary.
pub fn retry(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const key = job.retry.?;
    const requests = task.requests();
    try job.files.scratch.setLength(task.io, 0);
    // Bind the backwards walk to Host truth, not the frontend's last scan.
    // Any activity after this ending supersedes the retry, even if a stale
    // observation still presents the ending as the latest one.
    const newest = switch (try requests.activityPage(job.store, job.session, .{
        .direction = .backward,
        .kinds = .full,
        .limit = 1,
    })) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    job.result.retry = .stale;
    if (newest.facts.count == 0) return;
    const head = newest.facts.items[0];
    if (head.position != key.position or head.ordinal != key.ordinal) return;
    const page = switch (try requests.activityPage(job.store, job.session, .{
        .end = newest.facts.end,
        .position = key.position,
        .ordinal = key.ordinal,
        .direction = .backward,
        .kinds = .initOne(.admission),
        .limit = 1,
    })) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    job.result.retry = .{ .failure = .no_message };
    if (page.facts.count == 0) return;
    const item = page.facts.items[0];
    const content = item.value.admission.content;
    if (content.length > Input.capacity) {
        job.result.retry = .{ .failure = .too_large };
        return;
    }
    var staging: RetryStaging = .{ .io = task.io, .file = job.files.scratch, .length = content.length };
    const reference: protocol_reply.CommandObservation.ContentReference = .{ .bytes = content.length, .digest = content.digest };
    if (try requests.readActivityContent(job.store, job.session, item.position, item.ordinal, reference, &staging)) |failure| return requests.failRead(failure);
    job.result.retry = .{ .message = .{ .ending = key, .position = item.position, .length = @intCast(staging.offset) } };
}

const RetryStaging = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    offset: u64 = 0,

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        if (bytes.len > self.length - self.offset) return error.ContentLengthMismatch;
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

/// One step over the Messages the person sent, from the one the draft
/// shows or from the newest: a one-row activity page of `admission` rows,
/// then that Message's content staged in scratch. One the draft cannot
/// hold as typed text (over its capacity, or with a control character) is
/// passed over, its content read at most once, and the result says so.
pub fn recall(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const step = job.recall.?;
    std.debug.assert(step.older or step.from != null);
    // A person's Messages are the activity page's `admission` rows. A
    // Message's position holds no other row, so the step from a shown one
    // starts at its position's boundary and needs no row identity.
    var cursor: protocol_reply.ActivityCursor = .{
        .end = if (step.from) |from| from.end else null,
        .position = if (step.from) |from| from.position else 0,
        .ordinal = null,
        .direction = if (step.older) .backward else .forward,
        .kinds = .initOne(.admission),
        .limit = 1,
    };
    while (true) {
        const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        if (page.facts.count == 0) return;
        const row = page.facts.items[0];
        const content = row.value.admission.content;
        const at: Input.Recalled = .{ .position = row.position, .end = page.facts.end };
        if (content.length <= Input.capacity) if (try stageRecalled(requests, job, task.io, at, content)) |found| {
            job.result.recalled = found;
            return;
        };
        job.result.recall_passed = true;
        cursor.end = page.facts.end;
        cursor.position = row.position;
    }
}

/// Stages a sent Message's text in scratch; null when the draft cannot hold
/// it as typed text.
fn stageRecalled(requests: client.Requests, job: *const Job, io: std.Io, at: Input.Recalled, content: protocol.ActivityItem.Content) !?Input.Found {
    try job.files.scratch.setLength(io, 0);
    var staging: RecallStaging = .{ .io = io, .file = job.files.scratch };
    const reference: protocol_reply.CommandObservation.ContentReference = .{ .bytes = content.length, .digest = content.digest };
    if (try requests.readActivityContent(job.store, job.session, at.position, 0, reference, &staging)) |failure| return requests.failRead(failure);
    if (staging.offset != content.length) return error.ContentLengthMismatch;
    const slash = staging.first == '/';
    if (!staging.editable or staging.need != 0 or staging.offset + @intFromBool(slash) > Input.capacity) return null;
    return .{ .at = at, .length = @intCast(staging.offset), .slash = slash };
}

/// A sent Message's text in scratch, checked scalar by scalar as the
/// editor checks literal text.
const RecallStaging = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    first: ?u8 = null,
    editable: bool = true,
    scalar: [4]u8 = undefined,
    have: u3 = 0,
    need: u3 = 0,

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
        if (self.first == null and bytes.len != 0) self.first = bytes[0];
        for (bytes) |byte| {
            if (!self.editable) return;
            if (self.need == 0) self.need = std.unicode.utf8ByteSequenceLength(byte) catch {
                self.editable = false;
                return;
            };
            self.scalar[self.have] = byte;
            self.have += 1;
            if (self.have != self.need) continue;
            Editor.validateText(self.scalar[0..self.have]) catch {
                self.editable = false;
            };
            self.have = 0;
            self.need = 0;
        }
    }
};

/// Host commands keep their one-shot output owners. Their complete stdout and
/// stderr become an inspection page while the Session screen keeps drawing
/// through its own descriptor. No command reads terminal input.
pub const runInfoConfigure = runCommand;

pub fn runCommand(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    var read = task.readContext();
    read.cancellation = job.interrupted;
    const run: CommandRun = .{ .command = job.command, .init = job.init, .requests = read, .store = job.store, .session = job.session, .line = job.command_text[0..job.command_text_length], .configure = job.configure, .edit = job.info_edit, .saved = &job.result.info_saved };
    const ended = run.into(job.files.inspection);
    job.result.rendering = ended.rendering;
    job.result.command_stderr_restored = ended.stderr_restored;
    return ended.outcome;
}

/// One Host command line, run as a screen runs it: by `command`, for
/// `session` when it names one.
pub const CommandRun = struct {
    command: Command,
    init: std.process.Init,
    requests: client.ReadContext,
    store: []const u8,
    session: []const u8,
    /// Decoded in place.
    line: []u8,
    configure: ?Configure = null,
    edit: ?ChatInfo.Edit = null,
    saved: ?*bool = null,

    fn execute(self: CommandRun) !void {
        if (self.edit) |edit| {
            const configure = self.configure orelse return error.ConfigureUnavailable;
            self.saved.?.* = try configure(self.init, self.requests, self.store, self.session, edit);
        } else try self.command(self.init, self.requests, self.store, self.session, self.line);
    }

    /// How a run ended.
    pub const Ended = struct {
        /// The output became the page's, after which any failure is the
        /// caller's to end on.
        rendering: bool = false,
        /// Stderr came back from the page. Only then may the caller write
        /// the page to stderr: otherwise fd 2 may still be the page.
        stderr_restored: bool = false,
        outcome: anyerror!void = {},
    };

    /// Runs the command with its complete stdout and stderr written to
    /// `page` from its start.
    pub fn into(self: CommandRun, page: std.Io.File) Ended {
        const io = self.requests.io;
        page.setLength(io, 0) catch |err| return .{ .outcome = err };
        io.vtable.fileSeekTo(io.userdata, page, 0) catch |err| return .{ .outcome = err };
        // Saved descriptors must not leak into anything the command executes.
        const saved = [2]c_int{ std.c.fcntl(1, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)), std.c.fcntl(2, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0)) };
        defer for (saved) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        if (saved[0] < 0 or saved[1] < 0) return .{ .outcome = error.TerminalCleanupFailed };
        // Redirected descriptors are output custody: any failure now is fatal.
        const result = if (std.c.dup2(page.handle, 1) < 0 or std.c.dup2(page.handle, 2) < 0) error.TerminalCleanupFailed else self.execute();
        const stdout_restored = std.c.dup2(saved[0], 1) >= 0;
        const stderr_restored = std.c.dup2(saved[1], 2) >= 0;
        if (!stdout_restored or !stderr_restored) {
            // Restoration replaced the command's outcome with a local failure.
            self.requests.origin.* = .local;
            return .{ .rendering = true, .stderr_restored = stderr_restored, .outcome = error.TerminalCleanupFailed };
        }
        return .{ .rendering = true, .stderr_restored = true, .outcome = result };
    }
};

pub fn permission(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try scan(raw, task);
    if (job.result.work.work.first_action) |action| {
        try job.files.action.setLength(task.io, 0);
        var output: DisplayCapture = .{ .task = task, .file = job.files.action };
        // A target resolved between reads is the same as a scan with no
        // pending Action: leave result.action empty and refresh, without consent.
        job.result.summary = (try View.permission(task.requests(), job.store, job.session, action, job.files.scratch, &output, job.colour)) orelse return;
        job.result.action = action;
    }
}

/// Activity cursors are exclusive. Inclusive replay names the preceding
/// ordinal, or the preceding position boundary when ordinal is zero.
fn pageCursor(job: *const Job, plan: FeedPolicy.Page) protocol_reply.ActivityCursor {
    var cursor: protocol_reply.ActivityCursor = .{
        .direction = if (plan.direction == .backward) .backward else .forward,
        .limit = plan.limit,
        .kinds = if (plan.kinds == .all) .full else .initMany(&.{ .admission, .received, .user, .assistant, .tool_result, .hosted_call, .turn_ended, .stop, .sent, .send_failed }),
        .end = if (plan.kinds == .all and plan.continuing) job.cursor.end else null,
    };
    if (plan.from) |from| {
        cursor.position = from.position;
        cursor.ordinal = if (from.ordinal == std.math.maxInt(u64)) (if (plan.direction == .backward) @as(u64, std.math.maxInt(i64)) else null) else from.ordinal;
        if (plan.replace_from != null and !plan.continuing) {
            std.debug.assert(from.ordinal != std.math.maxInt(u64));
            if (from.ordinal != 0) {
                cursor.ordinal = from.ordinal - 1;
            } else {
                cursor.position = from.position -| 1;
                cursor.ordinal = null;
            }
        }
    }
    return cursor;
}

pub fn scan(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const plan = job.feed_page orelse FeedPolicy.Page{
        .direction = if (job.opening) .backward else .forward,
        .kinds = .all,
        .started_from = if (job.cursor.position == 0) null else .{ .position = job.cursor.position, .ordinal = job.cursor.ordinal orelse std.math.maxInt(u64) },
        .from = if (job.opening or job.cursor.position == 0) null else .{ .position = job.cursor.position, .ordinal = job.cursor.ordinal orelse std.math.maxInt(u64) },
        .continuing = !job.opening and job.cursor.end != null,
        .novelty_after = if (job.opening or job.cursor.position == 0) null else .{ .position = job.cursor.position, .ordinal = job.cursor.ordinal orelse std.math.maxInt(u64) },
    };
    const page = switch (try requests.activityPage(job.store, job.session, pageCursor(job, plan))) {
        .page => |page| page,
        .failure => |failure| return requests.failRead(failure),
    };
    if (plan.kinds == .all) {
        job.result.work = page.facts.work;
        const line_stale = Line.stale(job.line_read, &page.facts);
        if (job.open_status or job.watch_status or line_stale) {
            const current = try View.current(requests, job.store, job.session, job.files.scratch);
            if (line_stale) Line.take(&job.result.line, &current, .{ .revision = page.facts.work.revision, .end = page.facts.end });
            if (job.open_status or job.watch_status) {
                job.result.status = try job.status(task.io, &current, job.files.scratch, job.status_taken, if (job.open_status) null else job.status_shown, job.status_actions);
            }
        }
        job.result.latest_ending = if (job.opening) null else job.latest_ending;
        for (page.facts.items[0..page.facts.count]) |item| observeEnding(&job.result.latest_ending, item, job.session, job.sessionProvider());
        if (job.opening and job.result.latest_ending == null and page.facts.more) {
            try latestEnding(requests, job, page.facts.end);
        }
        if (job.result.line) |*line| if (job.hint_wanted and line.label == null) if (line.first_position) |position| {
            job.result.hint = try readHint(requests, job, position);
        };
        job.result.live = View.Live.init(page.facts.call_activity);
        job.result.queued = page.facts.queued;
        const queued = page.facts.queued;
        const echoed = queued.count != 0 and !page.facts.work.work.state.holdsQueue();
        if (queued.count > @intFromBool(echoed) and queued.newest_admission != job.queued_line) {
            job.result.queued_line = .{ .admission = queued.newest_admission, .line = (try readFirstLine(requests, job, queued.newest_position, .fails)).? };
        }
    }
    try job.files.inspection.setLength(task.io, 0);
    // One open row at a time uses this buffer; closed rows never touch it.
    const toggled: ?@FieldType(Target, "tool") = if (job.target) |target| if (target == .tool) target.tool else null else null;
    const output: ?*tool_fold.Output = if (job.opened.count != 0 or toggled != null) try job.init.gpa.create(tool_fold.Output) else null;
    defer if (output) |held| job.init.gpa.destroy(held);
    var offset: u64 = 0;
    for (0..page.facts.count) |index| {
        const item = page.facts.items[if (page.facts.direction == .backward) page.facts.count - index - 1 else index];
        const key: Key = .{ .position = item.position, .ordinal = item.ordinal };
        if (job.result.low == null) job.result.low = key;
        job.result.high = key;
        // Hidden pending rows need replay too: the next idle page can make
        // an Admission visible without adding another Activity row.
        const pending = item.value == .admission and item.value.admission.state == .queued;
        var row: RenderedRow = .{ .key = key, .offset = offset, .length = 0, .tight = false, .provisional = pending };
        if (toggled != null and toggled.?.key.order(key) != .eq) continue;
        const open = if (toggled) |one| one.open else job.opened.has(key);
        var capture: RowCapture = .{ .task = task, .file = job.files.inspection, .start = offset, .row = &row, .cap_target = switch (item.value) {
            .assistant => |answer| .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .row = false, .content = answer.content },
            else => null,
        } };
        row.provisional = try View.render(requests, job.store, job.session, job.sessionProvider(), item, page.facts.queued, page.facts.work.work.state.holdsQueue(), &capture, job.colour, job.home, .{ .viewport = job.width_method }, if (open) .{ .open = output.? } else .closed) or pending;
        row.tight = View.tight(item.value);
        try capture.finish();
        row.length = capture.length;
        if (row.length == 0 and !row.provisional) continue;
        job.result.rows[job.result.row_count] = row;
        job.result.row_count += 1;
        offset += row.length;
        if (row.length != 0 and FeedPolicy.isNew(plan, key)) job.result.new_rows += 1;
    }
    job.result.output_length = offset;
    job.result.at_start = plan.direction == .backward and !page.facts.more;
    job.result.at_end = plan.direction == .backward or !page.facts.more;
    if (job.result.at_end) job.result.high = if (page.facts.end == 0) null else .{ .position = page.facts.end, .ordinal = std.math.maxInt(u64) };
    if (plan.kinds == .all) {
        job.result.cursor = if (plan.direction == .backward) .{ .position = page.facts.end } else page.continuation() orelse .{ .position = page.facts.end };
    }
}

/// Forward scans can replay older provisional rows; only a newer own ending
/// advances this fact. Child endings never grant retry authority for a parent.
fn observeEnding(latest: *?LatestEnding, item: protocol.ActivityItem, session: []const u8, provider: ?protocol.Provider) void {
    const key: Key = .{ .position = item.position, .ordinal = item.ordinal };
    if (latest.*) |old| if (key.order(old.key) != .gt) return;
    const marks = @import("marks.zig");
    const cause: marks.Cause = switch (item.value) {
        .turn_ended => |ended| if (!std.mem.eql(u8, ended.session.slice(), session)) return else if (ended.ending == .done) .{ .words = "Finished" } else marks.cause(ended.code.slice(), provider),
        .stop => |stop| if (stop.turn == null) marks.cause("cancelled", provider) else return,
        else => return,
    };
    latest.* = .{ .key = key, .cause = cause };
}

/// Opening's row page need not contain an ending. Find it with a separate,
/// snapshot-bound cursor, never by filling/rendering historical window rows.
fn latestEnding(requests: client.Requests, job: *Job, end: u64) !void {
    var cursor: protocol_reply.ActivityCursor = .{ .end = end, .direction = .backward, .kinds = .initMany(&.{ .turn_ended, .stop }) };
    while (true) {
        const page = switch (try requests.activityPage(job.store, job.session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| observeEnding(&job.result.latest_ending, item, job.session, job.sessionProvider());
        if (job.result.latest_ending != null) return;
        cursor = page.continuation() orelse return;
    }
}

/// Ctrl-O on a tool row: that one row again, with its output shown or hidden.
/// A cursor's ordinal must name a row the Host holds, and the row before
/// this one is not known here, so the read starts at the boundary before
/// the row's position and pages forward to it. Only that row is rendered.
pub fn tool(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const key = job.target.?.tool.key;
    var from: Key = .{ .position = key.position - 1, .ordinal = std.math.maxInt(u64) };
    while (true) {
        job.feed_page = .{ .direction = .forward, .kinds = .visible, .started_from = from, .from = from };
        try scan(raw, task);
        if (job.result.row_count == 1) return;
        const reached = job.result.high orelse return error.ToolRowMissing;
        if (job.result.at_end or reached.order(key) != .lt) return error.ToolRowMissing;
        from = reached;
    }
}

/// The submission the UI shows under a page.
/// `failure` is what its last attempt's failure says the person must do,
/// in place of the state's own words.
pub fn writeSubmission(view: ?Submission.View, failure: ?[]const u8, out: *std.Io.Writer) !void {
    const submission = view orelse return;
    try out.print("Original reserved request: {s}\n{s}\n", .{ submission.key, failure orelse if (submission.state == .rejected) "Submission rejected; /discard releases only this original, retaining the next draft." else "Publication/admission may be incomplete; Ctrl-R retries this exact original." });
    if (submission.last_error) |err| try out.print("Last submission error: {s}\n", .{@errorName(err)});
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

/// A bounded head, never an answer's tail. Rendering authenticates the whole
/// source even when full. Cuts end outside UTF-8 scalars and controls; the
/// marker closes any hyperlink and resets presentation before its notice.
const RowCapture = struct {
    const more = TerminalText.link_close ++ View.Mark.reset ++ "\n" ++ View.Mark.summary ++ "┄ More — Ctrl-O for whole message" ++ View.Mark.reset ++ "\n";
    const notice_capacity = 128;
    const unkeyed_more = TerminalText.link_close ++ View.Mark.reset ++ "\n" ++ View.Mark.summary ++ "┄ More content omitted" ++ View.Mark.reset ++ "\n";
    task: *Task,
    file: std.Io.File,
    row: *RenderedRow,
    start: u64,
    length: u64 = 0,
    cut: bool = false,
    cap_target: ?View.Collapsed = null,
    omitted_summaries: u64 = 0,
    boundary: u64 = 0,
    scalar_left: u3 = 0,
    control: enum { none, escape, csi, osc, osc_escape } = .none,

    pub fn feed(self: *@This(), raw: []const u8) !void {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        if (raw.len == 0 or self.cut) return;
        const bytes = raw;
        const fit = bytes[0..@intCast(@min(bytes.len, feed_window.row_capacity - notice_capacity - self.length))];
        if (fit.len != 0) try self.file.writePositionalAll(self.task.io, fit, self.start + self.length);
        for (fit, 0..) |byte, index| {
            const end = self.length + index + 1;
            switch (self.control) {
                .none => {
                    if (byte == 0x1b) {
                        self.control = .escape;
                    } else if (byte < 0x80) {
                        self.scalar_left = 0;
                        self.boundary = end;
                    } else if (byte & 0xc0 == 0x80) {
                        self.scalar_left -|= 1;
                        if (self.scalar_left == 0) self.boundary = end;
                    } else {
                        self.scalar_left = (std.unicode.utf8ByteSequenceLength(byte) catch unreachable) - 1;
                    }
                },
                .escape => self.control = switch (byte) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .none,
                },
                .csi => if (byte >= 0x40 and byte <= 0x7e) {
                    self.control = .none;
                },
                .osc => {
                    if (byte == 0x1b) self.control = .osc_escape else if (byte == 7) self.control = .none;
                },
                .osc_escape => {
                    self.control = if (byte == '\\') .none else .osc;
                },
            }
            if (self.control == .none and self.scalar_left == 0) self.boundary = end;
        }
        self.length += fit.len;
        self.cut = fit.len != bytes.len;
    }

    pub fn excluding(_: *@This(), _: u64) void {}

    /// One bounded admission for complete summary bytes and their target.
    fn retainSummary(self: *@This(), value: View.Collapsed, bytes: []const u8, limit: u64) !bool {
        if (self.task.cancellation.stopped.load(.acquire)) return error.Cancelled;
        if (self.row.collapsed_count == self.row.collapsed_targets.len or bytes.len > limit - self.length) return false;
        try self.file.writePositionalAll(self.task.io, bytes, self.start + self.length);
        self.length += bytes.len;
        self.boundary = self.length;
        self.row.collapsed_targets[self.row.collapsed_count] = value;
        self.row.collapsed_count += 1;
        return true;
    }

    pub fn collapsedSummary(self: *@This(), value: View.Collapsed, bytes: []const u8) !void {
        if (self.cut) return;
        if (try self.retainSummary(value, bytes, feed_window.row_capacity - notice_capacity)) return;
        if (self.row.collapsed_count == self.row.collapsed_targets.len) self.omitted_summaries += 1 else self.cut = true;
    }

    fn finish(self: *@This()) !void {
        var aggregate: [notice_capacity]u8 = undefined;
        if (!self.cut and self.omitted_summaries == 0) return;
        if (self.cut) self.length = self.boundary;
        // Both cap and count notices use the same admission decision as every
        // other summary. The final aggregate has no per-Message action.
        const notice = if (self.omitted_summaries != 0)
            try std.fmt.bufPrint(&aggregate, TerminalText.link_close ++ View.Mark.reset ++ "\n" ++ View.Mark.summary ++ "┄ {d} more summar{s}{s}" ++ View.Mark.reset ++ "\n", .{ self.omitted_summaries, if (self.omitted_summaries == 1) "y" else "ies", if (self.cut) "; more content omitted" else "" })
        else if (self.cap_target) |target| keyed: {
            if (try self.retainSummary(target, more, feed_window.row_capacity)) {
                try self.file.setLength(self.task.io, self.start + self.length);
                return;
            }
            break :keyed unkeyed_more;
        } else unkeyed_more;
        try self.file.writePositionalAll(self.task.io, notice, self.start + self.length);
        self.length += notice.len;
        try self.file.setLength(self.task.io, self.start + self.length);
    }
};

/// The Ctrl-O page. The Message's length, digest and end are validated
/// before anything shows; its full text then follows at column 0.
pub fn fullMessage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const target = job.target.?.message;
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

test "session_reads a Message page past the display limit keeps what fits and says what it cut" {
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

/// /copy: the newest answer, bound to its length and digest before its last
/// window arrives. A file takes it as it arrives; the clipboard's bytes wait
/// in scratch, which only the UI may write to the terminal.
/// The most bytes /copy sends: hterm's osc52.sh sends at most 100,000
/// base64 bytes, the smallest limit a terminal's own tooling documents.
pub const clipboard_limit = 100_000 / 4 * 3;

pub fn copyAnswer(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    const requests = task.requests();
    const answer = (try lastAnswer(requests, job.store, job.session)) orelse return;
    const Sink = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        code: ?AnswerRenderer.LastCode,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
            if (self.code) |*code| code.feed(bytes);
        }
    };
    const copy = job.inspection_kind.copy;
    if (copy == .file) {
        var name: [copy_name_bytes]u8 = undefined;
        const path = copyName(&name, job.session);
        const directory = std.Io.Dir.cwd();
        var random: [8]u8 = undefined;
        try std.Io.randomSecure(task.io, &random);
        var temporary_name: [copy_name_bytes + 22]u8 = undefined;
        const temporary = std.fmt.bufPrint(&temporary_name, ".{s}.{s}.tmp", .{ path, std.fmt.bytesToHex(random, .lower) }) catch unreachable;
        // Exclusive creation never follows a link planted at either name, and
        // the rename replaces whatever sits at the export name, never its
        // target.
        const file = try directory.createFile(task.io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        var published = false;
        defer if (!published) directory.deleteFile(task.io, temporary) catch {};
        {
            defer file.close(task.io);
            var sink: Sink = .{ .io = task.io, .file = file, .code = null };
            if (try requests.readConversationContent(job.store, job.session, answer.position, answer.ordinal, answer.content, &sink)) |failure| return requests.failRead(failure);
            if (sink.offset != answer.content.bytes) return error.ContentLengthMismatch;
        }
        try directory.rename(temporary, directory, path, task.io);
        published = true;
        job.result.copied = .saved;
        return;
    }
    if (copy == .answer and answer.content.bytes > TerminalText.clipboard_limit) {
        job.result.copied = .too_large;
        return;
    }
    try job.files.scratch.setLength(task.io, 0);
    var sink: Sink = .{ .io = task.io, .file = job.files.scratch, .code = if (copy == .code) .{} else null };
    if (try requests.readConversationContent(job.store, job.session, answer.position, answer.ordinal, answer.content, &sink)) |failure| return requests.failRead(failure);
    if (sink.offset != answer.content.bytes) return error.ContentLengthMismatch;
    const range: AnswerRenderer.LastCode.Range = if (sink.code) |*code|
        code.finish() orelse {
            job.result.copied = .no_code;
            return;
        }
    else
        .{ .start = 0, .length = sink.offset };
    job.result.copied = if (range.length > TerminalText.clipboard_limit) .too_large else .{ .clipboard = range };
}

/// The Conversation's newest assistant answer, or null before the first.
fn lastAnswer(requests: client.Requests, store: []const u8, session: []const u8) !?protocol_reply.ConversationPage.Item {
    var cursor: protocol_reply.ConversationCursor = .{ .end = 0 };
    while (true) {
        const page = switch (try requests.conversationPage(store, session, cursor)) {
            .page => |value| value,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.items[0..page.count]) |item| if (item.kind == .assistant) return item;
        cursor = page.continuation() orelse return null;
    }
}

pub fn inspectPage(raw: *anyopaque, task: *Task) !void {
    const job: *Job = @ptrCast(@alignCast(raw));
    try job.files.inspection.setLength(task.io, 0);
    try task.io.vtable.fileSeekTo(task.io.userdata, job.files.inspection, 0);
    var buffer: [4096]u8 = undefined;
    var output = job.files.inspection.writerStreaming(task.io, &buffer);
    std.debug.assert(job.inspection_kind == .requests);
    try job.requests(job.init, task.readContext(), job.store, job.session, &output.interface, &job.result.requests);
    try writeSubmission(job.inspection_submission, null, &output.interface);
    try output.flush();
}

test "session_reads a Host command writes its page and inherits no saved terminal descriptor" {
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

        fn command(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, _: []u8) anyerror!void {
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
    var job: Job = .{ .files = .{ .scratch = undefined, .action = undefined, .inspection = page, .details = undefined, .actions = undefined }, .command = Probe.command, .interrupted = &interrupted };
    var task: Task = .{ .io = io };
    Probe.before = Probe.inheritable();
    try runCommand(&job, &task);
    try std.testing.expectEqual(@as(?c_int, null), Probe.leaked);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("page\n", bytes[0..try page.readPositionalAll(io, &bytes, 0)]);
}

test "session_reads the Session line takes archive and other facts from Current and reads again after a change" {
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
        for ([_]protocol.SessionArchiveState{ .active, .archiving, .archived }) |archive| {
            var bytes: [4096]u8 = undefined;
            const report = try std.fmt.bufPrint(&bytes, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"session\":{{\"reference\":\"k7m2qx\",\"parent\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"gpt\\u0001x\",\"revision\":\"3\",\"tools\":[],\"loaded_tools\":[],\"permission_mode\":\"{s}\",\"instructions\":" ++ reference_format ++ ",\"output_schema\":null,\"reasoning_effort\":{s},\"reasoning_effort_override\":null,\"compaction_trigger\":{s},\"context_estimate\":{s},\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":{s},\"created_at\":\"1\"}},\"archive_state\":\"{s}\",\"pending_messages\":\"0\",\"work\":{{\"state\":{{\"kind\":\"idle\",\"since\":\"1\"}},\"turn\":null,\"operation\":null,\"first_action\":null,\"latest_outcome\":null}},\"peers\":{{\"from_person_at\":null}},\"first_message\":{s},\"selected_message\":null,\"recent_messages\":[],\"actions\":{{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]}},\"rejected_calls\":{{\"count\":\"0\",\"items\":[]}},\"actionable_permissions\":[],\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}}}", .{ case.mode, case.effort, case.trigger, case.estimate, case.label, @tagName(archive), case.first });
            try file.setLength(io, 0);
            try file.writePositionalAll(io, report, 0);
            const reply = protocol_reply.CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = report.len } }) catch |err| {
                std.debug.print("{s}\n", .{report});
                return err;
            };
            Line.take(&line, &reply.current, moment);
            try std.testing.expectEqual(archive, line.?.archive_state);
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
    page.work.work = .{ .state = .{ .idle = .{ .since = 0 } }, .turn = 9, .operation = 12 };
    try std.testing.expect(!Line.stale(moment, &page));
}

test "session_reads plain text keeps whole code points within its bound, escapes controls and cuts once" {
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

/// Tests derive provisional ownership from the returned rows, as the feed does.
fn firstProvisional(result: *const @FieldType(Job, "result")) ?Key {
    for (result.rows[0..result.row_count]) |row| if (row.provisional) return row.key;
    return null;
}

/// A Host for tests of what a Session read asks: it answers Activity pages
/// and Message content from a history of `history` completed Turns'
/// outcomes followed by `tail`, and counts the pages it served. The history
const FakeHost = struct {
    history: u64,
    history_users: bool = false,
    tail: []const Tail,
    /// The Store's end, which a page asked for at no end reads.
    end: u64,
    held: bool = false,
    refuse_content: bool = false,
    content_texts: ?[]const []const u8 = null,
    pages: usize = 0,
    contents: usize = 0,
    others: usize = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    output: [4096]u8 = undefined,
    shown: []const u8 = "",

    /// A tail item; a Message a stop at `excluded_at` excludes reads as
    /// excluded at that end and later.
    const Tail = struct { value: protocol.ActivityItem.Value, excluded_at: ?u64 = null, applied_at: ?u64 = null };
    const text = "please wait\nfor the build";

    fn content() protocol.ActivityItem.Content {
        var hash = protocol.contentHasher();
        hash.update(text);
        return .{ .length = text.len, .digest = hash.finalResult() };
    }

    fn message(admission: u64) protocol.ActivityItem.Value {
        return .{ .admission = .{ .admission = admission, .key = .{}, .turn = null, .state = .queued, .content = content(), .admitted_at = 1 } };
    }

    const Row = struct { position: u64, ordinal: u64 = 0 };

    fn step(row: Row, end: u64, direction: @FieldType(protocol.ActivityFacts, "direction")) ?Row {
        const following: Row = switch (direction) {
            .forward => .{ .position = row.position + 1 },
            .backward => if (row.position <= 1) return null else .{ .position = row.position - 1 },
        };
        return if (following.position <= end) following else null;
    }

    fn item(self: *const FakeHost, row: Row, end: u64) protocol.ActivityItem {
        const position = row.position;
        if (position <= self.history) {
            if (self.history_users) {
                var user = message(position).admission;
                user.state = .applied;
                user.turn = position;
                return .{ .position = position, .at = 1, .value = .{ .user = user } };
            }
            var code: Bounded(protocol.max_code_bytes) = .{};
            code.set("completed") catch unreachable;
            return .{ .position = position, .at = 1, .value = .{ .turn_ended = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .turn = position, .operation = position, .ending = .done, .code = code, .content = content() } } };
        }
        const tail = self.tail[position - self.history - 1];
        var value = tail.value;
        if (tail.excluded_at) |at| if (end >= at) {
            value.admission.state = .excluded;
        };
        if (tail.applied_at) |at| if (end >= at) {
            value.admission.state = .applied;
            value.admission.turn = 1;
        };
        return .{ .position = position, .at = 1, .value = value };
    }

    fn page(self: *const FakeHost, end: u64, position: u64, ordinal: ?u64, direction: @FieldType(protocol.ActivityFacts, "direction"), kinds: protocol.ActivityPage.Kinds, limit: u8) protocol.ActivityFacts {
        var facts: protocol.ActivityFacts = .{ .end = end, .direction = direction };
        var next: ?Row = if (ordinal) |at|
            (if (direction == .backward and at > 0) .{ .position = position } else step(.{ .position = position, .ordinal = at }, end, direction))
        else switch (direction) {
            .forward => step(.{ .position = position }, end, direction),
            .backward => if (position != 0) step(.{ .position = position }, end, direction) else if (end >= 1) .{ .position = end } else null,
        };
        while (next) |row| {
            const value = self.item(row, end);
            if (kinds.contains(std.meta.activeTag(value.value))) {
                if (facts.count == limit) break;
                facts.items[facts.count] = value;
                facts.count += 1;
            }
            next = step(row, end, direction);
        }
        facts.more = next != null;
        const boundary = if (direction == .forward and facts.more) facts.items[facts.count - 1].position else end;
        for (self.tail, @as(usize, @intCast(self.history)) + 1..) |_, at| {
            if (at > boundary) break;
            const value = self.item(.{ .position = at }, boundary).value;
            if (value != .admission or value.admission.state != .queued) continue;
            if (facts.queued.count == 0) facts.queued.oldest_position = at;
            facts.queued.count += 1;
            facts.queued.newest_admission = value.admission.admission;
            facts.queued.newest_position = at;
        }
        facts.work = .{ .work = if (self.held) .{ .state = .{ .working = .{ .since = 1 } }, .turn = 1, .operation = 1 } else .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 };
        facts.work.workspace.set("/") catch unreachable;
        return facts;
    }

    fn respond(fd: std.posix.fd_t, status: []const u8, kind: []const u8, extra: []const u8, body: []const u8) void {
        var header: [512]u8 = undefined;
        const head = std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{ status, kind, body.len, extra }) catch unreachable;
        // The client may close once it has what it needs.
        for ([_][]const u8{ head, body }) |bytes| {
            var sent: usize = 0;
            while (sent < bytes.len) {
                const count = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, socket_os.send_flags);
                if (count <= 0) return;
                sent += @intCast(count);
            }
        }
    }

    fn answer(self: *FakeHost, fd: std.posix.fd_t) !void {
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        const body_start = while (true) {
            const count = try std.posix.read(fd, request[used..]);
            if (count == 0) return;
            used += count;
            if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |at| break at + 4;
        };
        const marker = "Content-Length: ";
        const length_at = std.mem.indexOf(u8, request[0..body_start], marker).? + marker.len;
        const length = try std.fmt.parseInt(usize, request[length_at..std.mem.indexOfScalarPos(u8, request[0..body_start], length_at, '\r').?], 10);
        while (used < body_start + length) used += try std.posix.read(fd, request[used..]);
        const body = request[body_start .. body_start + length];
        var storage: [4096]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const Cursor = struct { end: ?[]const u8 = null, position: []const u8, ordinal: ?[]const u8 = null, direction: []const u8 = "forward", kinds: []const protocol.ActivityItem.Kind = &.{}, limit: []const u8 = "16" };
        const cursor = try std.json.parseFromSliceLeaky(Cursor, fixed.allocator(), body, .{ .ignore_unknown_fields = true });
        const position = try std.fmt.parseInt(u64, cursor.position, 10);
        if (std.mem.startsWith(u8, request[0..used], "POST /v1/activity-page ")) {
            self.pages += 1;
            const end = if (cursor.end) |value| try std.fmt.parseInt(u64, value, 10) else self.end;
            const ordinal = if (cursor.ordinal) |value| try std.fmt.parseInt(u64, value, 10) else null;
            var kinds: protocol.ActivityPage.Kinds = .{};
            for (cursor.kinds) |kind| kinds.insert(kind);
            const facts = self.page(end, position, ordinal, if (std.mem.eql(u8, cursor.direction, "backward")) .backward else .forward, kinds, try std.fmt.parseInt(u8, cursor.limit, 10));
            var out = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer out.deinit();
            try activity_reply.writePage(&out.writer, &facts);
            respond(fd, "200 OK", "application/json", "", out.written());
        } else if (std.mem.startsWith(u8, request[0..used], "POST /v1/activity-content ")) {
            self.contents += 1;
            if (self.refuse_content) {
                var out: [256]u8 = undefined;
                var writer = std.Io.Writer.fixed(&out);
                try protocol.writeShape(&writer, protocol.error_reply, .{ protocol.ErrorType.activity_unavailable, "ContentNotFound" });
                return respond(fd, "409 Conflict", "application/json", "", writer.buffered());
            }
            const body_text = if (self.content_texts) |texts| texts[@intCast(position - 1)] else text;
            var extra: [128]u8 = undefined;
            respond(fd, "200 OK", "application/octet-stream", try std.fmt.bufPrint(&extra, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ body_text.len, body_text.len }), body_text);
        } else self.others += 1;
    }

    fn serve(self: *FakeHost, listener: *std.Io.net.Server) void {
        while (true) {
            const peer = listener.accept(std.testing.io) catch return;
            defer peer.close(std.testing.io);
            if (self.stopping.load(.acquire)) return;
            if (!socket_os.suppressSigpipe(peer.socket.handle)) return;
            self.answer(peer.socket.handle) catch {};
        }
    }

    fn withHost(self: *FakeHost, action: anytype) !void {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.setPermissions(io, .fromMode(0o700));
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
        var lease = try @import("platform.zig").StoreLease.acquire(io, root);
        defer lease.release();
        try lease.prepareForServing(false);
        const paths = lease.paths;
        var listener = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).listen(io, .{});
        defer {
            listener.deinit(io);
            std.Io.Dir.cwd().deleteFile(io, paths.socket.slice()) catch @panic("unable to remove fixture socket");
        }
        const thread = try std.Thread.spawn(.{}, serve, .{ self, &listener });
        defer {
            self.stopping.store(true, .release);
            if ((std.Io.net.UnixAddress.init(paths.socket.slice()) catch unreachable).connect(io)) |wake| wake.close(io) else |_| {}
            thread.join();
            self.stopping.store(false, .release);
        }
        try action.run(self, tmp.dir, root);
    }

    /// Runs `job` as a read against this Host; output is then in `shown`.
    fn read(self: *FakeHost, job: *Job) !void {
        try self.readWith(job, scan);
    }

    fn readWith(self: *FakeHost, job: *Job, run_read: Task.Run) !void {
        const Read = struct {
            job: *Job,
            run_read: Task.Run,
            fn run(action: *@This(), host: *FakeHost, dir: std.Io.Dir, root: []const u8) !void {
                const io = std.testing.io;
                const inspection = try dir.createFile(io, "inspection", .{ .read = true });
                defer inspection.close(io);
                action.job.store = root;
                if (action.job.session.len == 0) action.job.session = "k7m2qx";
                action.job.files = .{ .scratch = inspection, .action = inspection, .inspection = inspection, .details = inspection, .actions = .{ inspection, inspection } };
                var task: Task = .{ .io = io };
                try action.run_read(action.job, &task);
                host.shown = host.output[0..try inspection.readPositionalAll(io, &host.output, 0)];
            }
        };
        var action: Read = .{ .job = job, .run_read = run_read };
        try self.withHost(&action);
    }
};

// Row-local placement is independent of the feed reader and traversal order.
test "session_view Message placement is identical in either direction at every page split" {
    const Domain = struct {
        const user = "› " ++ View.Mark.body ++ "please wait\n  for the build" ++ View.Mark.reset ++ "\n";
        const link = TerminalText.link_open ++ TerminalText.session_link ++ "9f8e7d" ++ TerminalText.link_end ++ "\x1b[4mPeer" ++ TerminalText.link_close ++ View.Mark.reset ++ View.Mark.summary;
        const received = View.Mark.summary ++ "← Received message from " ++ link ++ View.Mark.reset ++ "\n";
        const sent = View.Mark.summary ++ "→ Messaged " ++ link ++ View.Mark.reset ++ "\n";
        const Sink = struct {
            out: *std.Io.Writer,
            lowest: ?u64 = null,
            pub fn feed(self: *@This(), bytes: []const u8) !void {
                try self.out.writeAll(bytes);
            }
            pub fn excluding(self: *@This(), position: u64) void {
                self.lowest = position;
            }
        };
        const Expected = struct { text: []const u8 = "", provisional: bool = false, lowest: ?u64 = null };

        // Each possible boundary separates two reads; backward loads the newer
        // part first. Each part may itself span multiple bounded Activity pages.
        fn check(root: []const u8, rows: []const protocol.ActivityItem, expected: []const Expected, queued: protocol.Queued, held: bool) !void {
            const requests: client.Requests = .{ .io = std.testing.io };
            for ([_]bool{ false, true }) |backward| for (0..rows.len + 1) |split| {
                for (0..2) |part| {
                    const newer = (part == 1) != backward;
                    const low = if (newer) split else 0;
                    const high = if (newer) rows.len else split;
                    var offset: usize = 0;
                    while (offset < high - low) {
                        const count = @min(protocol.ActivityPage.items, high - low - offset);
                        for (0..count) |at| {
                            const index = if (backward) high - offset - at - 1 else low + offset + at;
                            var buffer: [8192]u8 = undefined;
                            var out = std.Io.Writer.fixed(&buffer);
                            var sink: Sink = .{ .out = &out };
                            const provisional = try View.render(requests, root, "k7m2qx", null, rows[index], queued, held, &sink, false, "", .{ .viewport = .wcwidth }, .none);
                            try std.testing.expectEqualStrings(expected[index].text, out.buffered());
                            try std.testing.expectEqual(expected[index].provisional, provisional);
                            try std.testing.expectEqual(expected[index].lowest, sink.lowest);
                        }
                        offset += count;
                    }
                }
            };
        }

        fn run(_: *@This(), host: *FakeHost, _: std.Io.Dir, root: []const u8) !void {
            var peer: protocol.NamedPeer = .{ .session = .{} };
            try peer.session.set("9f8e7d");
            try peer.label.set("Peer");
            const outbound: protocol.ActivityItem.Value = .{ .sent = .{ .admission = 99, .target = peer, .content = FakeHost.content(), .admitted_at = std.math.maxInt(u64) } };
            var incoming = FakeHost.message(90).admission;
            incoming.sender = peer;
            incoming.admitted_at = std.math.maxInt(u64);
            // People and scripts both have no Session sender; distinct keys do
            // not change placement. Peer Messages show at received in all states.
            for ([_]enum { person, script, session }{ .person, .script, .session }) |source| {
                for (std.enums.values(@FieldType(protocol.ActivityItem.Message, "state"))) |state| {
                    for ([_]bool{ false, true }) |oldest| for ([_]bool{ false, true }) |held| {
                        var value = FakeHost.message(1).admission;
                        value.state = state;
                        value.turn = if (state == .applied) 1 else null;
                        value.admitted_at = std.math.maxInt(u64);
                        if (source == .script) try value.key.set("script");
                        if (source == .session) value.sender = peer;
                        const rows = [_]protocol.ActivityItem{
                            .{ .position = 2, .at = 1, .value = if (source == .session) .{ .received = value } else .{ .admission = value } },
                            .{ .position = 3, .at = 1, .value = .{ .received = incoming } },
                            .{ .position = 4, .at = 1, .value = outbound },
                            .{ .position = 5, .at = 1, .value = if (state == .applied) .{ .user = value } else .{ .session_changed = .{ .revision = 2, .field = .label } } },
                        };
                        const echo = source != .session and state == .queued and oldest and !held;
                        const expected = [_]Expected{
                            .{ .text = if (source == .session) received else if (echo) user else "", .provisional = echo },
                            .{ .text = received },
                            .{ .text = sent },
                            .{ .text = if (state == .applied and source != .session) user else "" },
                        };
                        const queued: protocol.Queued = if (state == .queued and source != .session) .{ .count = if (oldest) 1 else 2, .oldest_position = if (oldest) 2 else 1, .newest_admission = 1, .newest_position = 2 } else .{};
                        try check(root, &rows, &expected, queued, held);
                    };
                }
            }

            // Two stops, a settled delimiter, and a newer Message beyond the
            // cutoff. Exclusions cross at least three admission-only pages.
            const max = protocol.ActivityPage.items * 2 + 7;
            var tail: [max]FakeHost.Tail = undefined;
            var rows: [max]protocol.ActivityItem = undefined;
            var texts: [max][]const u8 = undefined;
            var words: [max][32]u8 = undefined;
            var shown: [max][128]u8 = undefined;
            var expected: [max]Expected = undefined;
            var clock_buffer: [5]u8 = undefined;
            const time = View.clock(1, &clock_buffer).?;
            var prefix_buffer: [64]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buffer, "› " ++ View.Mark.sidenote ++ "{s}" ++ View.Mark.reset ++ View.Mark.body, .{time});
            for ([_]usize{ 0, 1, protocol.ActivityPage.items * 2 + 1 }) |excluded| {
                for ([_]bool{ false, true }) |applied_boundary| {
                    const stop_at = excluded + 5;
                    for (0..stop_at) |index| {
                        texts[index] = try std.fmt.bufPrint(&words[index], "Message {d}", .{index + 1});
                        var value = FakeHost.message(index + 1).admission;
                        value.admitted_at = 1;
                        value.content = .{ .length = texts[index].len, .digest = protocol.contentDigest(texts[index]) };
                        tail[index] = .{ .value = .{ .admission = value } };
                        expected[index] = .{};
                    }
                    tail[0].excluded_at = 2;
                    tail[1].value = .{ .stop = .{ .key = .{}, .turn = null, .cutoff = 1, .completion = .completed } };
                    // A previous stop's exclusion OR an applied Admission ends
                    // the search; neither may be attributed to the later stop.
                    if (applied_boundary) {
                        tail[2].value.admission.state = .applied;
                        tail[2].value.admission.turn = 1;
                    } else tail[2].value = .{ .session_changed = .{ .revision = 2, .field = .label } };
                    for (3..excluded + 3) |index| tail[index].excluded_at = stop_at;
                    tail[stop_at - 1].value = .{ .stop = .{ .key = .{}, .turn = null, .cutoff = excluded + 3, .completion = .completed } };
                    host.tail = tail[0..stop_at];
                    host.end = stop_at;
                    host.content_texts = texts[0..stop_at];
                    for (0..stop_at) |index| rows[index] = host.item(.{ .position = index + 1 }, stop_at);
                    expected[1] = .{ .text = try std.fmt.bufPrint(&shown[1], "◌ not sent\n{s}{s}" ++ View.Mark.reset ++ "\n\n■ Stopped\n", .{ prefix, texts[0] }), .lowest = 1 };
                    var stop_buffer: [8192]u8 = undefined;
                    var stop_out = std.Io.Writer.fixed(&stop_buffer);
                    for (3..excluded + 3) |index| try stop_out.print("{s}◌ not sent\n{s}{s}" ++ View.Mark.reset ++ "\n", .{ if (index == 3) "" else "\n", prefix, texts[index] });
                    try stop_out.writeAll(if (excluded == 0) "■ Stopped\n" else "\n■ Stopped\n");
                    expected[stop_at - 1] = .{ .text = stop_out.buffered(), .lowest = if (excluded == 0) null else 4 };
                    try check(root, rows[0..stop_at], expected[0..stop_at], .{}, false);
                }
            }
        }
    };
    var host: FakeHost = .{ .history = 0, .tail = &.{}, .end = 0 };
    var domain: Domain = .{};
    try host.withHost(&domain);
}

test "session_reads opening reads one Activity page whatever the history before it" {
    // A Store with 10 or 10,000 earlier rows and the same newest page: the
    // opening reads that page alone, not the rows before it.
    for ([_]u64{ 10, 10_000 }) |earlier| {
        var host: FakeHost = .{ .history = earlier, .tail = &.{}, .end = earlier };
        var job: Job = .{ .session = "k7m2qx", .opening = true, .line_read = .{ .revision = 1, .end = earlier } };
        try host.read(&job);
        try std.testing.expectEqual(@as(usize, 1), host.pages);
        try std.testing.expectEqual(@as(usize, 0), host.others);
    }
}

test "session_reads the queued row's line fails the read when the Host refuses it" {
    // One Message waits behind work at the opening. The row would show it
    // with no line; the read fails instead, as a refused page does.
    const tail = [_]FakeHost.Tail{.{ .value = FakeHost.message(1) }};
    var host: FakeHost = .{ .history = 20, .tail = &tail, .end = 21, .held = true, .refuse_content = true };
    var job: Job = .{ .session = "k7m2qx", .opening = true, .line_read = .{ .revision = 1, .end = 21 } };
    try std.testing.expectError(error.HostInvocationFailed, host.read(&job));
    try std.testing.expectEqual(@as(usize, 1), host.contents);
}

test "session_reads Messages waiting at an opening show in the queued row, unless one is taken next" {
    // 20 shows nothing, and A and B wait at 21 and 22. Behind work, both
    // wait in the queued row.
    const tail = [_]FakeHost.Tail{ .{ .value = FakeHost.message(1) }, .{ .value = FakeHost.message(2) } };
    var held: FakeHost = .{ .history = 20, .tail = &tail, .end = 22, .held = true };
    var behind: Job = .{ .session = "k7m2qx", .opening = true, .line_read = .{ .revision = 1, .end = 22 } };
    try held.read(&behind);
    try std.testing.expectEqualStrings("", held.shown);
    try std.testing.expectEqual(@as(u64, 2), behind.result.queued.count);
    // Idle, A is taken next and shows at its Admission; B still waits in
    // the row.
    var idle: FakeHost = .{ .history = 20, .tail = &tail, .end = 22 };
    var opening: Job = .{ .session = "k7m2qx", .opening = true, .line_read = .{ .revision = 1, .end = 22 } };
    try idle.read(&opening);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, idle.shown, "please wait"));
    try std.testing.expectEqual(@as(?Key, .{ .position = 21 }), firstProvisional(&opening.result));
}

// This golden exercises the public renderer, including reports that must never
// be fetched, and stop/ending pairs split over live or historical pages.
test "activity golden stop with interrupted ending draws one line across pages" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
        pub fn excluding(_: *@This(), _: u64) void {}
    };
    var session: protocol.Bounded(6) = .{};
    try session.set("a1b2c3");
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("cancelled");
    const stop: protocol.ActivityItem = .{ .position = 1, .at = 1, .value = .{ .stop = .{ .key = .{}, .turn = 2, .cutoff = 0, .completion = .completed } } };
    // A non-null report also proves the renderer does not request its content:
    // the Requests value is undefined and must remain unused.
    const ended: protocol.ActivityItem = .{ .position = 2, .at = 2, .value = .{ .turn_ended = .{ .session = session, .turn = 2, .operation = 3, .ending = .stopped, .code = code, .content = .{ .length = 99, .digest = @splat(0) } } } };
    const page = try std.testing.allocator.create(protocol_reply.ActivityPage);
    defer std.testing.allocator.destroy(page);
    for ([_]bool{ false, true }) |colour| {
        for ([_]bool{ false, true }) |historical| {
            for ([_]bool{ false, true }) |split| {
                var buffer: [256]u8 = undefined;
                var out = std.Io.Writer.fixed(&buffer);
                var sink: Sink = .{ .out = &out };
                page.* = .{ .facts = .{ .end = 2, .count = if (split) 1 else 2, .direction = if (historical) .backward else .forward } };
                page.facts.items[0] = if (historical and !split) ended else stop;
                if (!split) page.facts.items[1] = if (historical) stop else ended;
                for (0..page.facts.count) |index| {
                    const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
                    _ = try View.render(undefined, "unused", session.slice(), null, item, .{}, false, &sink, colour, "", .{ .viewport = .wcwidth }, .none);
                }
                if (split) {
                    try std.testing.expectEqualStrings("", out.buffered());
                    page.facts.items[0] = ended;
                    for (0..page.facts.count) |index| {
                        const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
                        _ = try View.render(undefined, "unused", session.slice(), null, item, .{}, false, &sink, colour, "", .{ .viewport = .wcwidth }, .none);
                    }
                }
                try std.testing.expectEqualStrings(if (colour) "\x1b[39m■\x1b[39m Stopped\n" else "■ Stopped\n", out.buffered());
            }
        }
    }
    // An idle stop has no terminal Turn to follow it and owns its own line.
    page.* = .{ .facts = .{ .end = 1, .count = 1 } };
    page.facts.items[0] = stop;
    page.facts.items[0].value.stop.turn = null;
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var sink: Sink = .{ .out = &out };
    _ = try View.render(undefined, "unused", session.slice(), null, page.facts.items[0], .{}, false, &sink, true, "", .{ .viewport = .wcwidth }, .none);
    try std.testing.expectEqualStrings("\x1b[39m■\x1b[39m Stopped\n", out.buffered());
}

// Rows render alone; feed_window draws the gap between them from `tight`.
test "session_reads rendered row kinds keep their own text and feed_window draws the gap from adjacency in every order" {
    const vaxis = @import("vaxis");
    const Window = feed_window.Window;
    const Entry = feed_window.Entry;
    const Text = feed_window.Text;
    const testing = std.testing;
    const Sink = struct {
        document: *Viewport.Sized(512, true),
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.document.append(bytes);
        }
        pub fn excluding(_: *@This(), _: u64) void {}
    };
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    var search: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try search.set("Search");
    var find: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try find.set("Find");
    const content: protocol.ActivityItem.Content = .{ .length = 3, .digest = @splat(0xab) };
    // Each kind with its line and whether it packed with a packing
    // neighbour before rows left the blank line to the feed: a tool row or
    // peer Message after another drew no blank line; anything else did.
    const Kind = struct { value: protocol.ActivityItem.Value, line: []const u8, packed_: bool };
    const kinds = [_]Kind{
        .{ .value = .{ .sent = .{ .admission = 4, .target = peer, .content = content, .admitted_at = std.math.maxInt(u64) } }, .line = "→ Messaged 9f8e7d", .packed_ = true },
        .{ .value = .{ .received = .{ .admission = 5, .key = .{}, .turn = 3, .state = .applied, .content = content, .admitted_at = std.math.maxInt(u64), .sender = peer } }, .line = "← Received message from 9f8e7d", .packed_ = true },
        .{ .value = .{ .hosted_call = .{ .description = search, .code = .succeeded, .publication_position = null } }, .line = "✓ Search", .packed_ = true },
        .{ .value = .{ .hosted_call = .{ .description = find, .code = .failed, .publication_position = null } }, .line = "× Find", .packed_ = false },
        .{ .value = .{ .send_failed = .{ .key = .{}, .target = null, .code = .{} } }, .line = "× Message not delivered", .packed_ = false },
        .{ .value = .{ .stop = .{ .key = .{}, .turn = null, .cutoff = 0, .completion = .completed } }, .line = "■ Stopped", .packed_ = false },
    };
    var documents: [kinds.len]Viewport.Sized(512, true) = undefined;
    var texts: [kinds.len]Text = undefined;
    for (kinds, &documents, &texts, 0..) |kind, *document, *text_, index| {
        document.* = .{};
        var sink: Sink = .{ .document = document };
        const item: protocol.ActivityItem = .{ .position = index + 1, .at = 1, .value = kind.value };
        try testing.expect(!try View.render(undefined, "unused", "k7m2qx", null, item, .{}, false, &sink, false, "", .{ .viewport = .wcwidth }, .none));
        try document.prepare();
        text_.* = Text.fromDocument(document);
        // Row text is the row's line alone: no blank line on either side.
        try testing.expect(text_.bytes[0] != '\n' and std.mem.count(u8, text_.bytes, "\n") == 1);
        try testing.expectEqual(kind.packed_, View.tight(kind.value));
    }
    var cells: [40 * 8]vaxis.Cell = undefined;
    var screen: vaxis.Screen = .{ .width = 40, .height = 8, .width_method = .unicode, .buf = &cells };
    const pane: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 8, .screen = &screen };
    var buffer: [64]u8 = undefined;
    const Rows = struct {
        fn at(drawn: *const vaxis.Screen, index: u16, storage: []u8) []const u8 {
            var used: usize = 0;
            var column: u16 = 0;
            while (column < drawn.width) {
                const cell = drawn.readCell(column, index).?;
                @memcpy(storage[used..][0..cell.char.grapheme.len], cell.char.grapheme);
                used += cell.char.grapheme.len;
                column += @max(1, cell.char.width);
            }
            return std.mem.trimEnd(u8, storage[0..used], " ");
        }
    };
    for (0..kinds.len) |a| for (0..kinds.len) |b| for (0..kinds.len) |c| {
        const order = [_]usize{ a, b, c };
        // Append all, prepend one or two over a seam, or append one at a time.
        for (0..3) |shape| {
            var window: Window = .{};
            var entries: [3]Entry = undefined;
            for (order, &entries, 0..) |kind, *entry, at| entry.* = .{ .key = .{ .position = at + 1 }, .text = texts[kind], .tight = View.tight(kinds[kind].value) };
            switch (shape) {
                0 => try window.append(&entries),
                1 => {
                    try window.append(entries[1..]);
                    try window.prepend(entries[0..1]);
                },
                else => {
                    try window.append(entries[2..]);
                    try window.prepend(entries[1..2]);
                    try window.prepend(entries[0..1]);
                },
            }
            // Neighbours never change a row's own bytes.
            for (entries) |entry| try testing.expectEqualStrings(entry.text.bytes, window.text(entry.key).bytes);
            _ = window.heights(.{ .width = 40, .method = .unicode });
            @memset(&cells, .{});
            window.draw(.{ .first = 0 }, pane, true, .{}, .{});
            var row: u16 = 0;
            for (order, 0..) |kind, at| {
                if (at != 0 and !(kinds[order[at - 1]].packed_ and kinds[kind].packed_)) {
                    try testing.expectEqualStrings("", Rows.at(&screen, row, &buffer));
                    row += 1;
                }
                try testing.expectEqualStrings(kinds[kind].line, Rows.at(&screen, row, &buffer));
                row += 1;
            }
            try testing.expectEqualStrings("", Rows.at(&screen, row, &buffer));
        }
    };
}

test "session_reads policy cursor is inclusive only for a fresh provisional replay" {
    const job: Job = .{ .cursor = .{ .end = 90, .position = 40, .ordinal = 2 } };
    for ([_]u64{ 0, 1, 7 }) |ordinal| {
        const key: Key = .{ .position = 40, .ordinal = ordinal };
        for ([_]bool{ false, true }) |continuing| {
            const cursor = pageCursor(&job, .{ .direction = .forward, .kinds = .all, .started_from = key, .from = key, .replace_from = key, .continuing = continuing });
            try cursor.validate();
            try std.testing.expectEqual(if (continuing or ordinal != 0) @as(u64, 40) else 39, cursor.position);
            try std.testing.expectEqual(if (continuing) @as(?u64, ordinal) else if (ordinal != 0) ordinal - 1 else null, cursor.ordinal);
            try std.testing.expectEqual(if (continuing) @as(?u64, 90) else null, cursor.end);
        }
    }
    const edge: Key = .{ .position = 40, .ordinal = std.math.maxInt(u64) };
    const cursor = pageCursor(&job, .{ .direction = .forward, .kinds = .all, .started_from = edge, .from = edge });
    try cursor.validate();
    try std.testing.expectEqual(@as(?u64, null), cursor.ordinal);
    const above = pageCursor(&job, .{ .direction = .backward, .kinds = .visible, .started_from = edge, .from = edge });
    try above.validate();
    try std.testing.expect(!above.kinds.contains(.call));
    try std.testing.expect(!above.kinds.contains(.approval_requested));
    try std.testing.expect(!above.kinds.contains(.session_changed));
    try std.testing.expect(!above.kinds.contains(.compacted));
    for ([_]protocol.ActivityItem.Kind{ .admission, .received, .user, .assistant, .tool_result, .hosted_call, .turn_ended, .stop, .sent, .send_failed }) |kind| try std.testing.expect(above.kinds.contains(kind));
}

test "session_reads opening exposes ordered rows and the normalized scan edge" {
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    const tail = [_]FakeHost.Tail{
        .{ .value = .{ .sent = .{ .admission = 1, .target = peer, .content = FakeHost.content(), .admitted_at = 1 } } },
        .{ .value = FakeHost.message(2) },
    };
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 2 };
    var job: Job = .{ .opening = true, .session = "k7m2qx", .line_read = .{ .revision = 1, .end = 2 } };
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 2), job.result.row_count);
    try std.testing.expectEqualDeep(@as(?Key, .{ .position = 1 }), job.result.low);
    try std.testing.expectEqualDeep(@as(?Key, .{ .position = 2, .ordinal = std.math.maxInt(u64) }), job.result.high);
    try std.testing.expectEqual(@as(u64, 2), job.result.cursor.position);
    try std.testing.expectEqual(@as(?u64, null), job.result.cursor.ordinal);
    try std.testing.expect(job.result.at_start and job.result.at_end);
    for (job.result.rows[0..job.result.row_count], 0..) |row, index| {
        try std.testing.expectEqual(@as(u64, index + 1), row.key.position);
        try std.testing.expectEqual(index == 1, row.provisional);
        try std.testing.expectEqual(index == 0, row.tight);
        const body = host.shown[@intCast(row.offset)..][0..@intCast(row.length)];
        try std.testing.expect(body.len != 0 and body[0] != '\n');
        try std.testing.expectEqual(@as(usize, if (index == 0) 1 else 0), std.mem.count(u8, body, "Messaged"));
        try std.testing.expectEqual(@as(usize, if (index == 1) 1 else 0), std.mem.count(u8, body, "please wait"));
    }
    try std.testing.expectEqual(job.result.rows[0].length, job.result.rows[1].offset);
    try std.testing.expectEqual(@as(usize, 2), job.result.new_rows);
    try std.testing.expectEqualDeep(@as(?Key, .{ .position = 2 }), firstProvisional(&job.result));

    var empty: FakeHost = .{ .history = 0, .tail = &.{}, .end = 0 };
    job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 0 } };
    try empty.read(&job);
    try std.testing.expectEqual(@as(usize, 0), job.result.row_count);
    try std.testing.expectEqual(@as(?Key, null), job.result.high);
    try std.testing.expect(job.result.at_start and job.result.at_end);
}

test "session_reads visible fills do not refresh line work queue live or scan cursor" {
    const tail = [_]FakeHost.Tail{.{ .value = FakeHost.message(1) }};
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 1, .held = true };
    const edge: Key = .{ .position = 1, .ordinal = std.math.maxInt(u64) };
    var job: Job = .{ .cursor = .{ .position = 80 }, .feed_page = .{ .direction = .backward, .kinds = .visible, .started_from = edge, .from = edge }, .open_status = true, .hint_wanted = true };
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 1), host.pages);
    try std.testing.expectEqual(@as(usize, 0), host.contents);
    try std.testing.expectEqual(@as(usize, 0), host.others);
    try std.testing.expect(job.result.line == null and job.result.hint == null and !job.result.status);
    try std.testing.expectEqual(@as(u64, 0), job.result.work.revision);
    try std.testing.expectEqual(@as(u64, 0), job.result.queued.count);
    try std.testing.expectEqual(@as(u64, 0), job.result.cursor.position);
    try std.testing.expectEqual(@as(u64, 80), job.cursor.position);
    try std.testing.expectEqual(@as(usize, 1), job.result.row_count);
    try std.testing.expectEqual(@as(u64, 0), job.result.rows[0].length);
    try std.testing.expect(job.result.rows[0].provisional);
    try std.testing.expectEqualDeep(@as(?Key, .{ .position = 1 }), firstProvisional(&job.result));
}

test "session_reads replay replaces a provisional echo after intervening rows and counts only new rows" {
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    var incoming = FakeHost.message(90).admission;
    incoming.sender = peer;
    var applied = FakeHost.message(1).admission;
    applied.state = .applied;
    applied.turn = 1;
    for ([_]bool{ false, true }) |excluded| {
        const tail = [_]FakeHost.Tail{
            .{ .value = FakeHost.message(1), .applied_at = if (excluded) null else 24, .excluded_at = if (excluded) 24 else null },
            .{ .value = .{ .received = incoming } },
            .{ .value = .{ .sent = .{ .admission = 91, .target = peer, .content = FakeHost.content(), .admitted_at = 1 } } },
            .{ .value = if (excluded) .{ .stop = .{ .key = .{}, .turn = null, .cutoff = 1, .completion = .completed } } else .{ .user = applied } },
        };
        var host: FakeHost = .{ .history = 20, .tail = &tail, .end = 21 };
        var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 21 } };
        try host.read(&job);
        for ([_]u64{ 23, 24 }) |end| {
            const previous = job.result.high;
            const replay = firstProvisional(&job.result);
            host.end = end;
            job.cursor = job.result.cursor;
            job.opening = false;
            job.feed_page = .{ .direction = .forward, .kinds = .all, .started_from = previous, .from = replay, .replace_from = replay, .novelty_after = previous };
            job.result = .{};
            job.line_read = .{ .revision = 1, .end = end };
            try host.read(&job);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, host.shown, "please wait"));
            try std.testing.expectEqual(@as(usize, if (end == 23) 2 else 1), job.result.new_rows);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, host.shown, "Received message"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, host.shown, "Messaged"));
            try std.testing.expectEqualDeep(if (end == 23) @as(?Key, .{ .position = 21 }) else null, firstProvisional(&job.result));
            if (end == 24) {
                try std.testing.expect(std.mem.indexOf(u8, host.shown, "Received message").? < std.mem.indexOf(u8, host.shown, "please wait").?);
                try std.testing.expectEqual(@as(usize, @intFromBool(excluded)), std.mem.count(u8, host.shown, "◌ not sent"));
            }
        }
    }
}

test "session_reads first provisional survives every continuation page" {
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    var tail: [40]FakeHost.Tail = undefined;
    tail[0] = .{ .value = FakeHost.message(1) };
    for (tail[1..], 2..) |*row, admission| row.* = .{ .value = .{ .sent = .{ .admission = admission, .target = peer, .content = FakeHost.content(), .admitted_at = 1 } } };
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 1 };
    var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 1 } };
    try host.read(&job);
    const provisional = firstProvisional(&job.result);
    const novelty_after = job.result.high;
    host.end = tail.len;
    var counted: usize = 0;
    for ([_]u64{ 16, 32, 40 }, 0..) |expected, page_index| {
        const edge = job.result.high;
        job.cursor = job.result.cursor;
        job.feed_page = .{ .direction = .forward, .kinds = .all, .started_from = edge, .from = if (page_index == 0) provisional else edge, .replace_from = provisional, .continuing = page_index != 0, .novelty_after = novelty_after };
        job.opening = false;
        job.result = .{};
        job.line_read = .{ .revision = 1, .end = host.end };
        try host.read(&job);
        counted += job.result.new_rows;
        try std.testing.expectEqual(expected, job.result.cursor.position);
        try std.testing.expectEqual(page_index == 2, job.result.at_end);
        try std.testing.expectEqualDeep(@as(?Key, .{ .position = 1 }), job.feed_page.?.replace_from);
        try std.testing.expectEqualDeep(if (page_index == 0) @as(?Key, .{ .position = 1 }) else null, firstProvisional(&job.result));
        try std.testing.expectEqual(@as(usize, if (page_index == 0) 1 else 0), std.mem.count(u8, host.shown, "please wait"));
    }
    try std.testing.expectEqual(@as(usize, 39), counted);
}

test "session_reads a hidden queued Admission replays when the queue becomes idle" {
    const tail = [_]FakeHost.Tail{.{ .value = FakeHost.message(1) }};
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 1, .held = true };
    var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 1 } };
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 1), job.result.row_count);
    try std.testing.expectEqual(@as(u64, 0), job.result.rows[0].length);
    try std.testing.expectEqual(@as(usize, 0), job.result.new_rows);
    const edge = job.result.high;
    const replay = firstProvisional(&job.result);
    job.cursor = job.result.cursor;
    job.feed_page = .{ .direction = .forward, .kinds = .all, .started_from = edge, .from = replay, .replace_from = replay, .novelty_after = edge };
    job.opening = false;
    job.result = .{};
    host.held = false;
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 1), job.result.row_count);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, host.shown, "please wait"));
    try std.testing.expectEqual(@as(usize, 0), job.result.new_rows);
}

test "session_reads row heads are bounded with ordered exact collapsed targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "row", .{ .read = true });
    defer file.close(io);
    var task: Task = .{ .io = io };
    var row: RenderedRow = .{ .key = .{ .position = 1 }, .offset = 0, .length = 0, .tight = false, .provisional = false };
    var capture: RowCapture = .{ .task = &task, .file = file, .start = 0, .row = &row };
    try capture.feed("head\n");
    for (0..20) |index| try capture.collapsedSummary(.{ .source = .activity, .position = index + 1, .ordinal = 0, .row = false, .content = FakeHost.content() }, View.Mark.summary ++ "┄ prior" ++ View.Mark.reset ++ "\n");
    try std.testing.expectEqual(@as(usize, 16), row.collapsed_count);
    for (row.collapsed_targets[0..row.collapsed_count], 1..) |target, position| try std.testing.expectEqual(@as(u64, position), target.position);
    const large = try std.testing.allocator.alloc(u8, 2 * feed_window.row_capacity);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try capture.feed(large);
    try capture.collapsedSummary(.{ .source = .activity, .position = 99, .ordinal = 0, .row = false, .content = FakeHost.content() }, View.Mark.summary ++ "┄ late" ++ View.Mark.reset);
    try capture.feed("tail");
    try capture.finish();
    const shown = large[0..try file.readPositionalAll(io, large, 0)];
    try std.testing.expect(shown.len <= feed_window.row_capacity);
    try std.testing.expect(std.mem.startsWith(u8, shown, "head\n"));
    try std.testing.expect(std.mem.endsWith(u8, shown, "┄ 4 more summaries; more content omitted" ++ View.Mark.reset ++ "\n"));
    try std.testing.expect(std.mem.indexOf(u8, shown, "tail") == null);
    try std.testing.expectEqual(@as(usize, 16), row.collapsed_count);
}

test "session_reads long Session opening and visible fill each cost one page of content reads" {
    var host: FakeHost = .{ .history = 10_000, .history_users = true, .tail = &.{}, .end = 10_000 };
    var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 10_000 } };
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 16), host.contents);
    try std.testing.expectEqual(@as(usize, 16), job.result.row_count);
    try std.testing.expect(!job.result.at_start and job.result.at_end);
    const low = job.result.low;
    const cursor = job.result.cursor;
    job.feed_page = .{ .direction = .backward, .kinds = .visible, .started_from = low, .from = low };
    job.cursor = cursor;
    job.opening = false;
    job.result = .{};
    try host.read(&job);
    try std.testing.expectEqual(@as(usize, 32), host.contents);
    try std.testing.expectEqual(@as(usize, 16), job.result.row_count);
    // One metadata-only ending lookup on opening, plus two visible pages.
    try std.testing.expectEqual(@as(usize, 3), host.pages);
}

test "session_reads row caps never split UTF-8 scalars or presentation controls" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "row", .{ .read = true });
    defer file.close(io);
    var task: Task = .{ .io = io };
    const bytes = try std.testing.allocator.alloc(u8, feed_window.row_capacity + 100);
    defer std.testing.allocator.free(bytes);
    const Document = Viewport.Sized(feed_window.row_capacity + 100, true);
    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);
    for ([_][]const u8{ "é", "💚", View.Mark.summary, TerminalText.link_open ++ "file:///tmp/a" ++ TerminalText.link_end, TerminalText.link_open ++ "file:///tmp/" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ TerminalText.link_end }) |piece| {
        for (0..piece.len + 1) |remaining| {
            @memset(bytes, 'x');
            var row: RenderedRow = .{ .key = .{ .position = 1 }, .offset = 0, .length = 0, .tight = false, .provisional = false };
            var capture: RowCapture = .{ .task = &task, .file = file, .start = 0, .row = &row };
            try file.setLength(io, 0);
            try capture.feed(bytes[0 .. feed_window.row_capacity - RowCapture.notice_capacity - remaining]);
            // Presentation and Unicode sequences can straddle renderer chunks.
            for (piece) |byte| try capture.feed(&.{byte});
            try capture.feed("exceeds the cap");
            try capture.finish();
            const shown = bytes[0..try file.readPositionalAll(io, bytes, 0)];
            try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
            document.* = .{};
            try document.append(shown);
            try document.prepare();
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "More") != null);
        }
    }
}

test "session_reads stopped collapsed Messages retain their exact ordered identities up to the metadata bound" {
    const text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen";
    for ([_]usize{ 3, 15, 16, 17 }) |count| {
        var tail: [18]FakeHost.Tail = undefined;
        var texts: [18][]const u8 = @splat(text);
        for (tail[0..count], 1..) |*row, position| {
            var message = FakeHost.message(position).admission;
            message.content = .{ .length = text.len, .digest = protocol.contentDigest(text) };
            row.* = .{ .value = .{ .admission = message }, .excluded_at = count + 1 };
        }
        tail[count] = .{ .value = .{ .stop = .{ .key = .{}, .turn = null, .cutoff = count, .completion = .completed } } };
        var host: FakeHost = .{ .history = 0, .tail = tail[0 .. count + 1], .content_texts = &texts, .end = count + 1 };
        var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = count + 1 } };
        try host.read(&job);
        try std.testing.expectEqual(@as(usize, 1), job.result.row_count);
        const row = &job.result.rows[0];
        try std.testing.expectEqual(@min(count, 16), row.collapsed_count);
        try std.testing.expectEqual(@min(count, 16) + @intFromBool(count > 16), std.mem.count(u8, host.shown, "┄"));
        try std.testing.expectEqual(@as(u64, count + 1), row.key.position);
        var document: Viewport.Sized(feed_window.row_capacity, true) = .{};
        try document.append(host.shown);
        try document.prepare();
        try std.testing.expectEqual(@min(count, 16) + @intFromBool(count > 16), document.collapsed(0, document.length).count);
        if (count > 16) try std.testing.expect(std.mem.endsWith(u8, document.text(), "┄ 1 more summary\n"));
        for (row.collapsed_targets[0..row.collapsed_count], 1..) |target, position| {
            try std.testing.expectEqual(@as(u64, position), target.position);
            try std.testing.expectEqual(View.Collapsed{ .source = .activity, .position = position, .ordinal = 0, .row = false, .content = .{ .length = text.len, .digest = protocol.contentDigest(text) } }, target);
        }
    }
}

fn testEnding(code: []const u8, kind: protocol.TurnEnding, session: []const u8) protocol.ActivityItem.Value {
    var ended: protocol.ActivityItem.TurnEnded = .{ .session = .{}, .turn = 1, .operation = 1, .ending = kind, .code = .{}, .content = if (kind == .done) FakeHost.content() else null };
    ended.session.set(session) catch unreachable;
    ended.code.set(code) catch unreachable;
    return .{ .turn_ended = ended };
}

test "session_reads latest ending follows scan cursor, survives empty scans, ignores child endings and fills" {
    const tail = [_]FakeHost.Tail{
        .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") },
        .{ .value = testEnding("provider_http_500", .failed, "9f8e7d") },
        .{ .value = testEnding("provider_quota", .failed, "k7m2qx") },
        .{ .value = testEnding("completed", .done, "k7m2qx") },
        .{ .value = .{ .stop = .{ .key = .{}, .turn = null, .cutoff = 0, .completion = .completed } } },
    };
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 1 };
    var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = 1 } };
    try host.read(&job);
    try std.testing.expectEqual(@as(u64, 1), job.result.latest_ending.?.key.position);
    try std.testing.expectEqualStrings("ctrl+r retries", job.result.latest_ending.?.cause.key.?);
    for ([_]u64{ 1, 2, 3, 4, 5 }) |end| {
        job.latest_ending = job.result.latest_ending;
        job.cursor = job.result.cursor;
        job.opening = false;
        job.result = .{};
        host.end = end;
        job.line_read = .{ .revision = 1, .end = end };
        try host.read(&job);
        try std.testing.expectEqual(if (end <= 2) @as(u64, 1) else end, job.result.latest_ending.?.key.position);
        try std.testing.expectEqual(end <= 2, job.result.latest_ending.?.cause.key != null);
        try std.testing.expect(std.mem.indexOf(u8, host.shown, "ctrl+r") == null);
    }
    job.latest_ending = job.result.latest_ending;
    job.feed_page = .{ .direction = .backward, .kinds = .visible, .from = null, .started_from = null };
    job.result = .{};
    try host.read(&job);
    try std.testing.expect(job.result.latest_ending == null);
}

test "session_reads opening finds own newest ending outside resident rows and across child ending pages" {
    var tail: [40]FakeHost.Tail = undefined;
    tail[0] = .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") };
    for (tail[1..]) |*item| item.* = .{ .value = testEnding("completed", .done, "9f8e7d") };
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = tail.len };
    var job: Job = .{ .opening = true, .line_read = .{ .revision = 1, .end = tail.len } };
    try host.read(&job);
    try std.testing.expectEqual(@as(u64, 1), job.result.latest_ending.?.key.position);
    try std.testing.expect(job.result.latest_ending.?.cause.key != null);
    try std.testing.expectEqual(@as(usize, 4), host.pages);
    try std.testing.expectEqual(@as(usize, 0), host.contents);
    try std.testing.expectEqual(@as(usize, 0), job.result.row_count);
}

test "session_reads retry stages exact multi-window bytes before its ending and rejects stale completion" {
    const text = try std.testing.allocator.alloc(u8, 3 * protocol.content_window_bytes + 7);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    // A scalar crosses a content window; no escaping, normalization or trimming.
    @memcpy(text[protocol.content_window_bytes - 1 ..][0.."💚é\n\t /".len], "💚é\n\t /");
    text[0] = '/';
    var message = FakeHost.message(1).admission;
    message.content = .{ .length = text.len, .digest = protocol.contentDigest(text) };
    const tail = [_]FakeHost.Tail{
        .{ .value = FakeHost.message(1) },
        .{ .value = .{ .admission = message } },
        .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") },
    };
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = tail.len, .content_texts = &.{ FakeHost.text, text, "" } };
    var job: Job = .{ .retry = .{ .position = 3 } };
    // FakeHost's scan capture is bounded; the large scratch is checked within
    // its lifetime instead, after the production Task's real join.
    const Read = struct {
        job: *Job,
        expected: []const u8,
        fn run(action: *@This(), _: *FakeHost, dir: std.Io.Dir, root: []const u8) !void {
            const io = std.testing.io;
            const file = try dir.createFile(io, "retry", .{ .read = true });
            defer file.close(io);
            action.job.store = root;
            action.job.session = "k7m2qx";
            action.job.files = .{ .scratch = file, .inspection = file, .action = file, .details = file, .actions = .{ file, file } };
            var task: Task = .{};
            try task.start(io, action.job, retry);
            try task.join();
            const latest: LatestEnding = .{ .key = .{ .position = 3 }, .cause = @import("marks.zig").cause("provider_http_500", null) };
            const completion = action.job.retryCompletion(latest);
            try std.testing.expectEqual(@as(u64, 2), completion.message.position);
            try std.testing.expectEqualDeep(latest.key, completion.message.ending);
            try std.testing.expectEqual(action.expected.len, completion.message.length);
            const bytes = try std.testing.allocator.alloc(u8, action.expected.len);
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, bytes, 0));
            try std.testing.expectEqualStrings(action.expected, bytes);
            for ([_]?LatestEnding{ null, .{ .key = .{ .position = 4 }, .cause = latest.cause }, .{ .key = .{ .position = 3, .ordinal = 1 }, .cause = latest.cause } }) |changed|
                try std.testing.expect(action.job.retryCompletion(changed) == .stale);
        }
    };
    var read: Read = .{ .job = &job, .expected = text };
    try host.withHost(&read);
    try std.testing.expectEqual(@as(usize, 2), host.pages);
    try std.testing.expectEqual(@as(usize, 1), host.contents);
}

test "session_reads retry reports only Message state without falling back" {
    for ([_]enum { absent, too_large }{ .absent, .too_large }) |case| {
        var message = FakeHost.message(2).admission;
        switch (case) {
            .too_large => message.content.length = Input.capacity + 1,
            else => {},
        }
        const tail = [_]FakeHost.Tail{
            .{ .value = if (case == .absent) testEnding("provider_http_500", .failed, "k7m2qx") else FakeHost.message(1) },
            .{ .value = .{ .admission = message } },
            .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") },
        };
        var host: FakeHost = .{ .history = 0, .tail = &tail, .end = if (case == .absent) 1 else tail.len };
        var job: Job = .{ .retry = .{ .position = if (case == .absent) 1 else 3 } };
        try host.readWith(&job, retry);
        const latest: LatestEnding = .{ .key = job.retry.?, .cause = @import("marks.zig").cause("provider_http_500", null) };
        const expected: RetryFailure = switch (case) {
            .absent => .no_message,
            .too_large => .too_large,
        };
        try std.testing.expectEqual(expected, job.retryCompletion(latest).failure);
        try std.testing.expectEqual(@as(usize, 2), host.pages);
        try std.testing.expectEqual(@as(usize, 0), host.contents);
    }
}

test "session_reads retry rejects newer Host activity before reading any Message" {
    var applied = FakeHost.message(4).admission;
    applied.state = .applied;
    applied.turn = 2;
    const newer = [_]FakeHost.Tail{
        .{ .value = FakeHost.message(4) },
        .{ .value = FakeHost.message(4), .excluded_at = 4 },
        .{ .value = .{ .user = applied } },
        .{ .value = .{ .assistant = .{ .content = FakeHost.content(), .final = true } } },
        .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") },
        .{ .value = .{ .session_changed = .{ .revision = 2, .field = .label } } },
    };
    for (newer) |row| {
        const tail = [_]FakeHost.Tail{
            .{ .value = FakeHost.message(1) },
            .{ .value = FakeHost.message(2) },
            .{ .value = testEnding("provider_http_500", .failed, "k7m2qx") },
            row,
        };
        var host: FakeHost = .{ .history = 0, .tail = &tail, .end = tail.len };
        var job: Job = .{ .retry = .{ .position = 3 } };
        try host.readWith(&job, retry);
        const latest: LatestEnding = .{ .key = job.retry.?, .cause = @import("marks.zig").cause("provider_http_500", null) };
        try std.testing.expect(job.retryCompletion(latest) == .stale);
        try std.testing.expectEqual(@as(usize, 1), host.pages);
        try std.testing.expectEqual(@as(usize, 0), host.contents);
    }
    // Empty history and a different row at the same position are stale too.
    for ([_]u64{ 0, 1 }) |end| {
        const tail = [_]FakeHost.Tail{.{ .value = testEnding("provider_http_500", .failed, "k7m2qx") }};
        var host: FakeHost = .{ .history = 0, .tail = &tail, .end = end };
        var job: Job = .{ .retry = .{ .position = 1, .ordinal = 1 } };
        try host.readWith(&job, retry);
        const latest: LatestEnding = .{ .key = job.retry.?, .cause = @import("marks.zig").cause("provider_http_500", null) };
        try std.testing.expect(job.retryCompletion(latest) == .stale);
        try std.testing.expectEqual(@as(usize, 0), host.contents);
    }
}

test "session_reads capped answer target opens the whole authenticated answer" {
    const Domain = struct {
        text: []const u8,
        reference: protocol.ActivityItem.Content,
        fn run(self: *@This(), host: *FakeHost, dir: std.Io.Dir, root: []const u8) !void {
            const io = std.testing.io;
            const inspection = try dir.createFile(io, "inspection", .{ .read = true });
            defer inspection.close(io);
            const scratch = try dir.createFile(io, "message-stage", .{ .read = true });
            defer scratch.close(io);
            var job: Job = .{ .opening = true, .store = root, .session = "k7m2qx", .line_read = .{ .revision = 1, .end = 1 }, .files = .{ .scratch = scratch, .inspection = inspection, .action = inspection, .details = inspection, .actions = .{ inspection, inspection } } };
            var task: Task = .{ .io = io };
            try scan(&job, &task);
            const row = job.result.rows[0];
            try std.testing.expect(row.length <= feed_window.row_capacity);
            try std.testing.expectEqual(@as(usize, 1), row.collapsed_count);
            const target = row.collapsed_targets[0];
            try std.testing.expectEqualDeep(self.reference, target.content);
            try std.testing.expectEqual(@as(u64, 1), target.position);
            try std.testing.expectEqual(@as(u64, 0), target.ordinal);
            try std.testing.expect(!target.row);
            var document: Viewport.Sized(feed_window.row_capacity + 100, true) = .{};
            var preview: [feed_window.row_capacity]u8 = undefined;
            try document.append(preview[0..try inspection.readPositionalAll(io, &preview, 0)]);
            try document.prepare();
            try std.testing.expectEqual(@as(usize, 1), document.collapsed(0, document.length).count);
            job.target = .{ .message = target };
            try fullMessage(&job, &task);
            const shown = try std.testing.allocator.alloc(u8, self.text.len + 1024);
            defer std.testing.allocator.free(shown);
            const length = try inspection.readPositionalAll(io, shown, 0);
            try std.testing.expect(std.mem.indexOf(u8, shown[0..length], self.text) != null);
            try std.testing.expectEqual(@as(usize, 2), host.contents);
        }
    };
    const text = try std.testing.allocator.alloc(u8, feed_window.row_capacity + 500);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    @memcpy(text[text.len - 12 ..], "WHOLE answer");
    var hash = protocol.contentHasher();
    hash.update(text);
    const reference: protocol.ActivityItem.Content = .{ .length = text.len, .digest = hash.finalResult() };
    const tail = [_]FakeHost.Tail{.{ .value = .{ .assistant = .{ .content = reference, .final = true } } }};
    var host: FakeHost = .{ .history = 0, .tail = &tail, .end = 1, .content_texts = &.{text} };
    var domain: Domain = .{ .text = text, .reference = reference };
    try host.withHost(&domain);
}

test "session_reads cap target follows prior collapsed markers without mispairing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "row", .{ .read = true });
    defer file.close(io);
    var task: Task = .{ .io = io };
    const large = try std.testing.allocator.alloc(u8, feed_window.row_capacity * 2);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    for (0..17) |prior| {
        try file.setLength(io, 0);
        var row: RenderedRow = .{ .key = .{ .position = 99 }, .offset = 0, .length = 0, .tight = false, .provisional = false };
        const target: View.Collapsed = .{ .source = .activity, .position = 99, .ordinal = 7, .row = false, .content = FakeHost.content() };
        var capture: RowCapture = .{ .task = &task, .file = file, .start = 0, .row = &row, .cap_target = target };
        for (0..prior) |index| {
            try capture.collapsedSummary(.{ .source = .activity, .position = index + 1, .ordinal = 0, .row = true, .content = FakeHost.content() }, View.Mark.summary ++ "┄ prior" ++ View.Mark.reset ++ "\n");
        }
        try capture.feed(large);
        try capture.finish();
        var document: Viewport.Sized(feed_window.row_capacity + 100, true) = .{};
        var preview: [feed_window.row_capacity]u8 = undefined;
        try document.append(preview[0..try file.readPositionalAll(io, &preview, 0)]);
        try document.prepare();
        const keyed = prior < row.collapsed_targets.len;
        try std.testing.expectEqual(prior + 1, document.collapsed(0, document.length).count);
        try std.testing.expectEqual(prior + @intFromBool(keyed), row.collapsed_count);
        for (row.collapsed_targets[0..prior], 1..) |value, position| try std.testing.expectEqual(@as(u64, position), value.position);
        if (keyed) try std.testing.expectEqualDeep(target, row.collapsed_targets[prior]);
    }
}

test "session_reads summary byte overflow retains neither partial mark nor target before exact source cap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "summary-cap", .{ .read = true });
    defer file.close(io);
    var task: Task = .{ .io = io };
    const bytes = try std.testing.allocator.alloc(u8, feed_window.row_capacity);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    for ([_]View.Collapsed{ .{ .source = .activity, .position = 37, .ordinal = 2, .row = false, .content = FakeHost.content() }, .{ .source = .conversation, .position = 39, .ordinal = 3, .row = true, .content = FakeHost.content() } }) |source| {
        try file.setLength(io, 0);
        @memset(bytes, 'x');
        var row: RenderedRow = .{ .key = .{ .position = source.position }, .offset = 0, .length = 0, .tight = false, .provisional = false };
        var capture: RowCapture = .{ .task = &task, .file = file, .start = 0, .row = &row, .cap_target = source };
        try capture.feed(bytes[0 .. feed_window.row_capacity - RowCapture.notice_capacity - 5]);
        var omitted = source;
        omitted.position = 100;
        try View.writeCollapsed(&capture, omitted, View.Mark.summary ++ "┄ missing summary" ++ View.Mark.reset);
        try std.testing.expect(capture.cut);
        try std.testing.expectEqual(@as(usize, 0), row.collapsed_count);
        try capture.finish();
        try std.testing.expectEqual(@as(usize, 1), row.collapsed_count);
        try std.testing.expectEqualDeep(source, row.collapsed_targets[0]);
        const shown = bytes[0..try file.readPositionalAll(io, bytes, 0)];
        try std.testing.expect(shown.len <= feed_window.row_capacity);
        try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        try std.testing.expect(std.mem.indexOf(u8, shown, "missing summary") == null);
        var document: Viewport.Sized(feed_window.row_capacity, true) = .{};
        try document.append(shown);
        try document.prepare();
        try std.testing.expectEqual(@as(usize, 1), document.collapsed(0, document.length).count);
    }
}

test "chat info worker owns typed model and label bytes until completion" {
    var job: Job = .{};
    var label = "lane four".*;
    try job.setInfoEdit(.{ .label = &label });
    @memset(&label, 'x');
    try std.testing.expectEqualStrings("lane four", job.info_edit.?.label);
    var model = "future-chat".*;
    try job.setInfoEdit(.{ .model = &model });
    @memset(&model, 'x');
    try std.testing.expectEqualStrings("future-chat", job.info_edit.?.model);
    try job.setInfoEdit(.{ .permission = .ask });
    try std.testing.expectEqual(ChatInfo.Edit{ .permission = .ask }, job.info_edit.?);
}
