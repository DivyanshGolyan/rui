//! One invocation's original intent and Admission borrower. Initialize in final
//! storage; neither this owner nor its input may move until the borrower joins.
const std = @import("std");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Task = @import("ClientTask.zig");
const Self = @This();

pub const Intent = union(enum) {
    message: Input.Ticket,
    decision: struct { action: u64, decision: protocol.PermissionDecision },
};
pub const Kind = std.meta.Tag(Intent);
pub const State = enum { not_started, submitting, unconfirmed, rejected };
const Publication = enum { not_sent, unknown, published };
pub const Accepted = struct { kind: Kind, key: [36]u8 };
pub const View = struct { kind: Kind, state: State, key: [36]u8, last_error: ?anyerror };
pub const Recovery = union(enum) {
    none,
    not_sent: Kind,
    uncertain: [36]u8,
    saved: struct { original: Accepted, rejected: bool },
    accepted: Accepted,
};
pub const End = union(enum) {
    absent,
    // A Message's admission orders it among delivered ones.
    accepted: struct { kind: Kind, confirmed: bool, admission: ?u64 = null },
    rejected: struct { kind: Kind, code: protocol.Bounded(protocol.max_code_bytes) },
    failed: struct { err: anyerror },

    pub fn failure(self: End) ?anyerror {
        return if (self == .failed) self.failed.err else null;
    }
};

io: std.Io,
store: []const u8,
session: []const u8,
directory: []const u8,
input: *Input,
intent: ?Intent = null,
state: State = .not_started,
task: Task = .{},
key: [36]u8 = @splat(0),
path: [std.Io.Dir.max_path_bytes]u8 = undefined,
target: client.CaptureTarget = undefined,
captured: ?client.CapturedRecord = null,
reply_buffer: client.ReplyBuffer = .{},
reply: ?protocol_reply.MutationReply = null,
// These capture facts are worker-owned until join, independent of Admission.
publication: Publication = .not_sent,
last_error: ?anyerror = null,
accepted: ?Accepted = null,
retry: ?[36]u8 = null,

pub fn view(self: *const Self) ?View {
    const intent = self.intent orelse return null;
    return .{ .kind = std.meta.activeTag(intent), .state = self.state, .key = self.key, .last_error = self.last_error };
}

/// Recovery guidance is read only after both frontend borrowers have joined.
pub fn recovery(self: *const Self) Recovery {
    std.debug.assert(self.task.thread == null);
    if (self.intent) |intent| {
        const kind = std.meta.activeTag(intent);
        if (self.state == .not_started) return .{ .not_sent = kind };
        if (self.publication != .published) return .{ .uncertain = self.key };
        return .{ .saved = .{ .original = .{ .kind = kind, .key = self.key }, .rejected = self.state == .rejected } };
    }
    return if (self.accepted) |accepted| .{ .accepted = accepted } else .none;
}

pub fn begin(self: *Self, intent: Intent) !void {
    std.debug.assert(self.intent == null and self.task.thread == null);
    // Retain intent before randomness, path reservation or launch can fail.
    self.intent = intent;
    self.state = .not_started;
    self.reply = null;
    self.publication = .not_sent;
    const target: client.CaptureTarget = .{ .generated = self.directory };
    self.target = .{ .reserved = try target.resolve(self.io, &self.path, &self.key) };
    try self.task.start(self.io, self, submit);
    self.state = .submitting;
}

/// A deferred gesture is bound to this original, never the next intent.
/// A supplied key is checked here, not by the terminal adapter.
pub fn requestRecovery(self: *Self, key: ?[]const u8) !void {
    if (self.intent == null) return;
    if (key) |requested| if (!std.mem.eql(u8, requested, &self.key)) return error.OriginalBindingMismatch;
    self.retry = if (self.canRetry(self.key)) self.key else null;
}

/// Join a completed Admission before scheduling a pending same-original retry.
pub fn advance(self: *Self) !End {
    return self.advanceWithLaunch(launchRetry);
}

// The launch seam changes only the effect, not thread/completion authority.
fn advanceWithLaunch(self: *Self, launch: *const fn (*Self) anyerror!void) !End {
    if (self.task.thread != null and self.task.completed()) return self.join();
    if (self.task.thread == null) if (self.retry) |requested| {
        // Consume before launch: a failed start needs another explicit gesture.
        self.retry = null;
        if (self.canRetry(requested)) try launch(self);
    };
    return .absent;
}

fn canRetry(self: *const Self, requested: [36]u8) bool {
    return self.intent != null and self.state != .rejected and std.mem.eql(u8, &requested, &self.key);
}

fn launchRetry(self: *Self) !void {
    try self.task.start(self.io, self, resend);
}

test "submission bounded gestures consume only the original and do not requeue failed launch" {
    const Launch = struct {
        fn fail(owner: *Self) !void {
            try std.testing.expectEqual(State.unconfirmed, owner.view().?.state);
            return error.LaunchFailed;
        }
    };
    for (0..3) |kind| {
        for (1..4) |gestures| {
            errdefer std.debug.print("submission gestures: kind={d}, gestures={d}\n", .{ kind, gestures });
            var input: Input = undefined;
            input.init();
            var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input };
            // An idle gesture has no authority over a future original.
            try self.requestRecovery(null);
            self.intent = if (kind == 0) .{ .message = input.submitText("B") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
            self.key = @splat('B');
            self.state = .unconfirmed;
            self.publication = .published;
            self.accepted = .{ .kind = .message, .key = @splat('A') };
            try std.testing.expect(try self.advanceWithLaunch(Launch.fail) == .absent);
            try std.testing.expectEqualSlices(u8, &@as([36]u8, @splat('B')), &self.recovery().saved.original.key);
            for (0..gestures) |_| try self.requestRecovery(null);
            try std.testing.expectError(error.OriginalBindingMismatch, self.requestRecovery(&self.accepted.?.key));
            try std.testing.expectError(error.LaunchFailed, self.advanceWithLaunch(Launch.fail));
            try std.testing.expect(try self.advanceWithLaunch(Launch.fail) == .absent);
            try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
            // A stale queued B must not select replacement C, even if C is
            // otherwise eligible. This injects stale authority, not a worker.
            try self.requestRecovery(null);
            self.key = @splat('C');
            try std.testing.expect(try self.advanceWithLaunch(Launch.fail) == .absent);
            try self.requestRecovery(&self.key);
            try std.testing.expectError(error.LaunchFailed, self.advanceWithLaunch(Launch.fail));
            self.state = .rejected;
            try self.discardRejected();
        }
    }
}

test "submission bounded joined outcomes precede retry and retire original authority" {
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
        fn lost(_: *anyopaque, _: *Task) !void {
            return error.ConnectionResetByPeer;
        }
        fn cancelled(_: *anyopaque, task: *Task) !void {
            const deadline = std.Io.Clock.awake.now(task.io).nanoseconds + 5_000_000_000;
            while (!task.cancellation.stopped.load(.acquire)) {
                if (std.Io.Clock.awake.now(task.io).nanoseconds >= deadline) return error.TestCancellationDeadline;
                std.Thread.yield() catch {};
            }
            return error.Cancelled;
        }
        fn forbidden(_: *Self) !void {
            return error.UnexpectedRetry;
        }
    };
    const Outcome = enum { accepted, rejected, conflict, lost, cancelled };
    for (0..3) |kind| {
        for (std.enums.values(Outcome)) |outcome| {
            for (1..4) |gestures| {
                errdefer std.debug.print("submission join: kind={d}, outcome={s}, gestures={d}\n", .{ kind, @tagName(outcome), gestures });
                var input: Input = undefined;
                input.init();
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .key = @splat('B'), .state = .unconfirmed, .publication = .published };
                self.intent = if (kind == 0) .{ .message = input.submitText("original B") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
                self.reply = .{ .status = 200, .context = .{ .kind = if (kind == 0) .message else .permission_decision }, .target = if (kind == 0) .{ .message = .{ .bytes = 10, .digest = protocol.contentDigest("original B") } } else .{ .permission_decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } }, .answer = .{ .replayed = false, .result = switch (outcome) {
                    .accepted => .{ .accepted = if (kind == 0) .{ .message = .{ .admission = 37 } } else .permission_decision },
                    .rejected => .{ .rejected = .{} },
                    else => .conflict,
                } } };
                try self.task.start(self.io, &self, switch (outcome) {
                    .lost => Worker.lost,
                    .cancelled => Worker.cancelled,
                    else => Worker.done,
                });
                defer {
                    self.cancel();
                    _ = self.join();
                    self.close();
                }
                for (0..gestures) |_| try self.requestRecovery(null);
                if (outcome == .cancelled) {
                    try std.testing.expect(try self.advanceWithLaunch(Worker.forbidden) == .absent);
                    try std.testing.expect(self.retry != null);
                }
                self.cancel();
                const deadline = std.Io.Clock.awake.now(self.io).nanoseconds + 6_000_000_000;
                while (!self.task.completed()) {
                    if (std.Io.Clock.awake.now(self.io).nanoseconds >= deadline) return error.TestCompletionDeadline;
                    std.Thread.yield() catch {};
                }
                // advance must return the joined outcome, never launch first.
                const end = try self.advanceWithLaunch(Worker.forbidden);
                try std.testing.expect(self.task.thread == null);
                try std.testing.expect(self.join() == .absent);
                switch (outcome) {
                    .accepted => {
                        try std.testing.expect(end.accepted.confirmed);
                        try std.testing.expect(self.view() == null);
                        try std.testing.expect(self.retry == null);
                        try std.testing.expectEqualSlices(u8, &@as([36]u8, @splat('B')), &self.recovery().accepted.key);
                    },
                    .rejected, .conflict => {
                        try std.testing.expect(end == .rejected);
                        // Rejection may retain the gesture until advance, but
                        // must never launch or silently discard the original.
                        try std.testing.expect(self.recovery().saved.rejected);
                        try std.testing.expect(try self.advanceWithLaunch(Worker.forbidden) == .absent);
                        try self.requestRecovery(null);
                        try std.testing.expect(try self.advanceWithLaunch(Worker.forbidden) == .absent);
                        try self.discardRejected();
                        try std.testing.expect(self.retry == null);
                    },
                    .lost, .cancelled => {
                        try std.testing.expectEqual(if (outcome == .lost) error.ConnectionResetByPeer else error.Cancelled, end.failed.err);
                        try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
                        try std.testing.expect(self.retry != null);
                        try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
                        try std.testing.expectError(error.UnexpectedRetry, self.advanceWithLaunch(Worker.forbidden));
                        // Explicitly settle for replacement; failure itself is
                        // not nonadmission and cannot release this original.
                        self.state = .rejected;
                        try self.discardRejected();
                    },
                }
                // Release then replacement C: neither history nor B's gesture
                // can cause a launch; fresh C recovery is still available.
                self.intent = if (kind == 0) .{ .message = input.submitText("replacement C") } else .{ .decision = .{ .action = 20, .decision = if (kind == 1) .allow_once else .deny } };
                self.key = @splat('C');
                self.state = .unconfirmed;
                self.publication = .published;
                try std.testing.expect(try self.advanceWithLaunch(Worker.forbidden) == .absent);
                try std.testing.expectEqualSlices(u8, &@as([36]u8, @splat('C')), &self.recovery().saved.original.key);
                try std.testing.expectError(error.OriginalBindingMismatch, self.requestRecovery(&@as([36]u8, @splat('B'))));
                try self.requestRecovery(null);
                try std.testing.expectError(error.UnexpectedRetry, self.advanceWithLaunch(Worker.forbidden));
                self.state = .rejected;
                try self.discardRejected();
            }
        }
    }
}

/// Local cancellation never sends a Host control or releases original intent.
pub fn cancel(self: *Self) void {
    self.task.cancel();
}

pub fn join(self: *Self) End {
    if (self.task.thread == null) return .absent;
    const result = self.task.join();
    return self.apply(result) catch |err| {
        self.last_error = err;
        self.state = if (self.publication == .not_sent) .not_started else .unconfirmed;
        return .{ .failed = .{ .err = err } };
    };
}

fn apply(self: *Self, result: anyerror!void) !End {
    try result;
    const answer = try self.reply.?.answer;
    self.last_error = null;
    const kind = std.meta.activeTag(self.intent.?);
    if (answer.result == .accepted) {
        const confirmed = self.state == .unconfirmed;
        self.accepted = .{ .kind = kind, .key = self.key };
        self.release();
        const admission: ?u64 = switch (answer.result.accepted) {
            .message => |message| message.admission,
            else => null,
        };
        return .{ .accepted = .{ .kind = kind, .confirmed = confirmed, .admission = admission } };
    }
    self.state = .rejected;
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    if (answer.result == .rejected) code = answer.result.rejected else try code.set("request conflict");
    return .{ .rejected = .{ .kind = kind, .code = code } };
}

pub fn discardRejected(self: *Self) !void {
    if (self.intent == null) return;
    if (self.task.thread != null or self.state != .rejected) return error.SubmissionUnresolved;
    self.release();
}

fn release(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    switch (self.intent.?) {
        .message => |ticket| self.input.release(ticket) catch unreachable,
        .decision => {},
    }
    self.close();
    self.intent = null;
    self.publication = .not_sent;
    self.last_error = null;
    self.retry = null;
}

/// Final invocation disposal, not command handoff. Join does not close the
/// pinned saved reader: subsequent recovery must keep using its original inode.
pub fn close(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    if (self.captured) |*capture| capture.close(self.io);
    self.captured = null;
}

fn submit(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
    if (self.publication == .not_sent) self.publication = .unknown;
    self.captured = switch (self.intent.?) {
        .message => |ticket| try client.captureMessage(task.io, .{ .store = self.store, .session = self.session, .text_path = "", .text = try self.input.message(ticket) }, self.target).get(),
        .decision => |decision| try client.capturePermissionDecision(task.io, .{ .store = self.store, .session = self.session, .action_id = decision.action, .decision = decision.decision }, self.target),
    };
    self.publication = .published;
    self.reply = try task.requests().sendCaptured(&self.captured.?, &self.reply_buffer).get();
}

test "submission reservation failure retains unsent intent ahead of accepted history" {
    const Failing = struct {
        fn random(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Failing.random;
    for (0..3) |kind| {
        var input: Input = undefined;
        input.init();
        var self: Self = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .accepted = .{ .kind = .message, .key = @splat('A') } };
        const intent: Intent = if (kind == 0) .{ .message = input.submitText("original café!") } else .{ .decision = .{ .action = 9, .decision = if (kind == 1) .allow_once else .deny } };
        for ("next té!\x1b[D") |byte| _ = input.feed(byte);
        try std.testing.expectError(error.EntropyUnavailable, self.begin(intent));
        try std.testing.expectEqual(.not_started, self.view().?.state);
        try std.testing.expectEqual(std.meta.activeTag(intent), self.recovery().not_sent);
        try std.testing.expect(self.join() == .absent);
        try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
        if (kind == 0) try std.testing.expectEqualStrings("original café!", try input.message(intent.message));
        try std.testing.expectEqualStrings("next té!", input.composition().bytes);
        try std.testing.expectEqual("next té".len, input.composition().cursor);
    }
}

test "submission cancelled and failed joins preserve independent publication facts" {
    const Worker = struct {
        fn cancelled(raw: *anyopaque, task: *Task) !void {
            task.cancellation.requestStop();
            try resend(raw, task);
        }
        fn initial(raw: *anyopaque, task: *Task) !void {
            task.cancellation.requestStop();
            try submit(raw, task);
        }
        fn failed(_: *anyopaque, _: *Task) !void {
            return error.ConnectionResetByPeer;
        }
    };
    for (0..3) |kind| {
        for ([_]Publication{ .not_sent, .unknown, .published }) |publication| {
            for ([_]Task.Run{ Worker.initial, Worker.cancelled, Worker.failed }) |run| {
                var input: Input = undefined;
                input.init();
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .accepted = .{ .kind = .message, .key = @splat('A') }, .publication = publication, .key = @splat('B'), .state = .unconfirmed };
                self.intent = if (kind == 0) .{ .message = input.submitText("original B café!") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
                for ("newer té!\x1b[D") |byte| _ = input.feed(byte);
                try self.task.start(self.io, &self, run);
                const end = self.join();
                try std.testing.expectEqual(if (run == Worker.failed) error.ConnectionResetByPeer else error.Cancelled, end.failed.err);
                try std.testing.expectEqual(if (publication == .not_sent) State.not_started else State.unconfirmed, self.view().?.state);
                const recovery_view = self.recovery();
                switch (publication) {
                    .not_sent => try std.testing.expect(recovery_view == .not_sent),
                    .unknown => try std.testing.expectEqualSlices(u8, &self.key, &recovery_view.uncertain),
                    .published => try std.testing.expectEqualSlices(u8, &self.key, &recovery_view.saved.original.key),
                }
                try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
                try std.testing.expectEqualStrings("newer té!", input.composition().bytes);
                try std.testing.expectEqual("newer té".len, input.composition().cursor);
                try std.testing.expect(self.join() == .absent);
            }
        }
    }
}

test "submission recovery validates reopened originals and pins the saved reader through handoff" {
    const Failure = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    try tmp.dir.createDir(io, "other-store", .fromMode(0o700));
    var other_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const other_store = try std.fmt.bufPrint(&other_buffer, "{s}/other-store", .{root});
    const Variant = enum { absent, matching, store, session, key, content, length, action, decision, kind };
    for (0..3) |kind| {
        for (std.enums.values(Variant)) |variant| {
            errdefer std.debug.print("intent {d}, reopened variant {s}\n", .{ kind, @tagName(variant) });
            var input: Input = undefined;
            input.init();
            var vtable = io.vtable.*;
            vtable.fileSync = Failure.sync;
            var self: Self = .{ .io = .{ .userdata = io.userdata, .vtable = &vtable }, .store = root, .session = "k7m2qx", .directory = root, .input = &input };
            defer self.close();
            const intent: Intent = if (kind == 0) .{ .message = input.submitText("original café!") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
            try self.begin(intent);
            try std.testing.expectEqual(error.NoSpaceLeft, self.join().failed.err);
            const key = self.view().?.key;
            try std.testing.expectEqualSlices(u8, &key, &self.recovery().uncertain);
            vtable.fileSync = io.vtable.fileSync;
            if (variant != .absent) {
                const target: client.CaptureTarget = .{ .explicit = .{ .record = self.target.reserved.record, .key = if (variant == .key) "wrong-key" else &key } };
                const store = if (variant == .store) other_store else root;
                const session = if (variant == .session) "09azvw" else "k7m2qx";
                var record = if ((kind == 0) != (variant == .kind))
                    try client.captureMessage(io, .{ .store = store, .session = session, .text_path = "", .text = switch (variant) {
                        .content => "modified café!",
                        .length => "short",
                        else => "original café!",
                    } }, target).get()
                else
                    try client.capturePermissionDecision(io, .{ .store = store, .session = session, .action_id = if (variant == .action) 20 else 19, .decision = if ((kind == 1) != (variant == .decision)) .allow_once else .deny }, target);
                record.close(io);
            }
            for ("newer té!\x1b[D") |byte| _ = input.feed(byte);
            try std.testing.expectError(error.OriginalBindingMismatch, self.requestRecovery("wrong-gesture"));
            try std.testing.expect(try self.advance() == .absent);
            try std.testing.expect(self.join() == .absent);
            try self.requestRecovery(&key);
            _ = try self.advance();
            const matching = variant == .absent or variant == .matching or (kind == 0 and (variant == .action or variant == .decision)) or (kind != 0 and (variant == .content or variant == .length));
            const end = self.join();
            try std.testing.expectEqual(if (matching) error.FileNotFound else if (variant == .key) error.InvalidRequestRecord else error.OriginalBindingMismatch, end.failed.err);
            try std.testing.expectEqualStrings("newer té!", input.composition().bytes);
            try std.testing.expectEqual("newer té".len, input.composition().cursor);
            try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
            if (matching) {
                // Cancel/join is handoff, not final close. Replacing the public
                // path must not make the next retry select a different inode.
                self.cancel();
                try std.testing.expect(self.join() == .absent);
                try std.Io.Dir.cwd().deleteFile(io, self.target.reserved.record);
                try self.requestRecovery(null);
                _ = try self.advance();
                try std.testing.expectEqual(error.FileNotFound, self.join().failed.err);
                try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, self.target.reserved.record, .{}));
                self.close();
                try std.testing.expectEqualSlices(u8, &key, &self.recovery().saved.original.key);
            }
        }
    }
}

fn resend(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
    if (self.captured == null) {
        // Only absent publication permits capture of the SAME reserved intent.
        self.captured = client.openCaptured(task.io, .{ .generated = .{ .directory = self.directory, .handle = &self.key } }) catch |err| switch (err) {
            error.FileNotFound => return submit(raw, task),
            else => return err,
        };
        errdefer {
            self.captured.?.close(task.io);
            self.captured = null;
        }
        const original: protocol_reply.MutationTarget = switch (self.intent.?) {
            .message => |ticket| blk: {
                const bytes = try self.input.message(ticket);
                break :blk .{ .message = .{ .bytes = bytes.len, .digest = protocol.contentDigest(bytes) } };
            },
            .decision => |decision| .{ .permission_decision = .{ .action = decision.action, .decision = decision.decision } },
        };
        const expected: client.Binding = .{ .store = self.store, .session = self.session, .key = &self.key, .target = original };
        if (!expected.matches(&self.captured.?.saved, self.captured.?.target)) return error.OriginalBindingMismatch;
        self.publication = .published;
    }
    self.reply = try task.requests().sendCaptured(&self.captured.?, &self.reply_buffer).get();
}

test "submission settles wire Admission only after join and releases only accepted or discarded intent" {
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
    for (0..3) |kind| {
        for ([_][]const u8{ "accepted", "rejected", "conflict", "invalid" }) |status| {
            errdefer std.debug.print("intent {d}, Admission {s}\n", .{ kind, status });
            const accepted = std.mem.eql(u8, status, "accepted");
            const conflict = std.mem.eql(u8, status, "conflict");
            const invalid = std.mem.eql(u8, status, "invalid");
            var body_buffer: [1024]u8 = undefined;
            var body = std.Io.Writer.fixed(&body_buffer);
            try body.print("{{\"version\":\"2\",\"type\":\"{s}_reply\",\"answer\":{{\"status\":\"{s}\",\"replayed\":false,\"session\":\"k7m2qx\"", .{ if (kind == 0) "message" else "permission_decision", status });
            if (!accepted) try body.print(",\"code\":\"{s}\"", .{if (conflict) "idempotency_key_conflict" else "not_allowed"});
            if (kind != 0) try body.print(",\"action\":\"19\",\"decision\":\"{s}\"", .{if (kind == 1) "allow_once" else "deny"});
            if (kind == 0 and accepted) try body.writeAll(",\"admission\":\"37\"");
            try body.writeAll("}");
            if (kind == 0) {
                try body.writeAll(",\"execution\":{\"status\":\"queued\"}");
                // SHA-256 of length-prefixed rui/content/v1 then original café!.
                if (!conflict) try body.writeAll(",\"input\":{\"type\":\"text\",\"bytes\":\"15\",\"sha256\":\"d02342cf8f590cb32eff9b3d74fffa781a3caa7ea94c4145612c09244fd25d00\"}");
                if (accepted) try body.writeAll(",\"queue\":{\"status\":\"queued\",\"admission\":\"37\"}");
            }
            try body.writeAll("}");
            var response_buffer: [1536]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 2\r\n\r\n{s}", .{ if (conflict) "409 Conflict" else "200 OK", body.buffered().len, body.buffered() });
            var input: Input = undefined;
            input.init();
            var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .input = &input };
            defer {
                self.cancel();
                _ = self.join();
                self.close();
            }
            const intent: Intent = if (kind == 0) .{ .message = input.submitText("original café!") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
            try self.begin(intent);
            const peer = try listener.accept(io);
            defer peer.close(io);
            const file: std.Io.File = .{ .handle = peer.socket.handle, .flags = .{ .nonblocking = false } };
            try file.writeStreamingAll(io, response);
            // Even a fully received reply cannot release a loan before join.
            try std.testing.expectEqual(.submitting, self.view().?.state);
            try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
            try self.requestRecovery(null);
            for ("next té!\x1b[D") |byte| _ = input.feed(byte);
            const key = self.view().?.key;
            const end = self.join();
            // Acceptance releases the record; an unresolved one keeps its route.
            if (!accepted) try std.testing.expect(self.captured.?.replay == .generated);
            if (accepted) {
                try std.testing.expect(end == .accepted);
                try std.testing.expect(self.view() == null);
                try std.testing.expectEqualSlices(u8, &key, &self.recovery().accepted.key);
            } else if (invalid) {
                try std.testing.expectEqual(error.InvalidResponse, end.failed.err);
                try std.testing.expectEqual(.unconfirmed, self.view().?.state);
                try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
            } else {
                try std.testing.expectEqualStrings(if (conflict) "request conflict" else "not_allowed", end.rejected.code.slice());
                try std.testing.expectEqual(.rejected, self.view().?.state);
                try self.discardRejected();
            }
            try std.testing.expectEqualStrings("next té!", input.composition().bytes);
            try std.testing.expectEqual("next té".len, input.composition().cursor);
            if (!invalid) {
                if (kind == 0) try std.testing.expectError(error.NoSubmission, input.message(intent.message));
                try std.testing.expect(try self.advance() == .absent);
                try std.testing.expect(self.join() == .absent);
            }
        }
    }
}
