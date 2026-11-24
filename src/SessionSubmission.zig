const std = @import("std");
const host_endpoint = @import("host_endpoint.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const Task = @import("ClientTask.zig");
const original_state = @import("submission_state.zig");
const Self = @This();

pub const Intent = union(enum) {
    message: Input.Ticket,
    message_then_deny: struct { ticket: Input.Ticket, action: u64 },
    decision: struct { action: u64, decision: protocol.PermissionDecision },

    pub fn kind(self: Intent) Kind {
        return switch (self) {
            .message, .message_then_deny => .message,
            .decision => .decision,
        };
    }

    pub fn ticket(self: Intent) ?Input.Ticket {
        return switch (self) {
            .message => |message| message,
            .message_then_deny => |reason| reason.ticket,
            .decision => null,
        };
    }
};
pub const Kind = original_state.Kind;
pub const State = original_state.State;
pub const Publication = original_state.Publication;
pub const Accepted = original_state.Accepted;
pub const View = struct { kind: Kind, state: State, key: [36]u8, last_error: ?anyerror };
pub const Recovery = original_state.Recovery;
pub const End = union(enum) {
    absent,
    accepted: struct { kind: Kind, confirmed: bool, admission: ?u64 = null, denies: ?u64 = null },
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
environment: client.Environment,
intent: ?Intent = null,
state: State = .not_started,
task: Task = .{},
key: [36]u8 = @splat(0),
path: [std.Io.Dir.max_path_bytes]u8 = undefined,
target: client.CaptureTarget = undefined,
captured: ?client.CapturedRecord = null,
reply_buffer: client.ReplyBuffer = .{},
reply: ?protocol_reply.MutationReply = null,
publication: Publication = .not_sent,
last_error: ?anyerror = null,
accepted: ?Accepted = null,
retry: ?[36]u8 = null,
retain_message: bool = false,
projected: bool = false,
settled_message: ?struct { ticket: Input.Ticket, key: [36]u8, admission: ?u64 = null, store: protocol.Bounded(protocol.max_store_bytes) = .{} } = null,

pub const AppliedProbe = struct { key: [36]u8, store: protocol.Bounded(protocol.max_store_bytes) };
pub const AppliedResult = enum { taken, queued, excluded, unverified };

pub fn view(self: *const Self) ?View {
    const intent = self.intent orelse return null;
    return .{ .kind = intent.kind(), .state = self.state, .key = self.key, .last_error = self.last_error };
}

pub fn published(self: *const Self) bool {
    return self.task.thread == null and self.publication == .published;
}

pub fn recovery(self: *const Self) Recovery {
    std.debug.assert(self.task.thread == null);
    const original: ?original_state.Original = if (self.intent) |intent| .{ .kind = intent.kind(), .state = self.state, .publication = self.publication, .key = self.key } else null;
    return original_state.recovery(original, self.accepted);
}

pub fn begin(self: *Self, intent: Intent) !void {
    std.debug.assert(self.intent == null and self.task.thread == null);
    std.debug.assert(intent.ticket() == null or self.settled_message == null);
    self.intent = intent;
    self.projected = false;
    self.state = .not_started;
    self.reply = null;
    self.publication = .not_sent;
    self.key = @splat(0);
    const target: client.CaptureTarget = .{ .generated = self.directory };
    self.target = .{ .reserved = try target.resolve(self.io, &self.path, &self.key) };
    try self.startWorker(submit);
    self.state = .submitting;
}

pub fn requestRecovery(self: *Self, key: ?[]const u8) !void {
    if (self.intent == null) return;
    if (key) |requested| if (!std.mem.eql(u8, requested, &self.key)) return error.OriginalBindingMismatch;
    self.retry = if (self.canRetry(self.key)) self.key else null;
}

pub fn advance(self: *Self) !End {
    return self.advanceWithLaunch(launchRetry);
}

fn advanceWithLaunch(self: *Self, launch: *const fn (*Self) anyerror!void) !End {
    if (self.task.thread != null and self.task.completed()) return self.join();
    if (self.task.thread == null) if (self.retry) |requested| {
        self.retry = null;
        if (self.canRetry(requested)) try launch(self);
    };
    return .absent;
}

fn canRetry(self: *const Self, requested: [36]u8) bool {
    const key = self.retryable() orelse return false;
    return std.mem.eql(u8, &requested, key);
}

fn retryable(self: *const Self) ?*const [36]u8 {
    return if (self.intent != null and original_state.retries(self.state)) &self.key else null;
}

pub fn unconfirmedMessage(self: *const Self) ?*const [36]u8 {
    const key = self.retryable() orelse return null;
    return if (original_state.retriesAsMessage(self.state, self.intent.? == .message, self.task.thread != null)) key else null;
}

fn launchRetry(self: *Self) !void {
    try self.startWorker(resend);
}

fn startWorker(self: *Self, run: Task.Run) !void {
    const image = if (std.c.getenv("RUI_TEST_SUBMISSION_START") != null)
        std.c.dlopen(null, .{ .LAZY = true })
    else
        null;
    defer if (image) |handle| {
        _ = std.c.dlclose(handle);
    };
    const mark: ?*const fn (c_int) callconv(.c) void = if (image) |handle|
        @ptrCast(@alignCast(std.c.dlsym(handle, "rui_test_submission_start")))
    else
        null;
    if (mark) |notify| notify(1);
    defer if (mark) |notify| notify(0);
    try self.task.start(self.io, self, run);
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
            var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty };
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
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .key = @splat('B'), .state = .unconfirmed, .publication = .published };
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
                        self.state = .rejected;
                        try self.discardRejected();
                    },
                }
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

pub fn cancel(self: *Self) void {
    self.task.cancel();
}

pub fn join(self: *Self) End {
    if (self.task.thread == null) return .absent;
    const result = self.task.join();
    return self.apply(result) catch |err| {
        self.last_error = err;
        self.state = original_state.failed(self.publication);
        return .{ .failed = .{ .err = err } };
    };
}

fn apply(self: *Self, result: anyerror!void) !End {
    try result;
    const answer = try self.reply.?.answer;
    self.last_error = null;
    const intent = self.intent.?;
    const kind = intent.kind();
    if (answer.result == .accepted) {
        const confirmed = self.state == .unconfirmed;
        self.accepted = .{ .kind = kind, .key = self.key };
        const admission: ?u64 = switch (answer.result.accepted) {
            .message => |message| message.admission,
            else => null,
        };
        const denies: ?u64 = if (intent == .message_then_deny) intent.message_then_deny.action else null;
        if (self.retain_message and intent.ticket() != null and !self.projected) {
            std.debug.assert(self.settled_message == null);
            self.settled_message = .{ .ticket = intent.ticket().?, .key = self.key, .admission = admission, .store = self.reply.?.context.store };
            self.retire();
            return .{ .accepted = .{ .kind = kind, .confirmed = confirmed, .admission = admission, .denies = denies } };
        }
        self.release();
        return .{ .accepted = .{ .kind = kind, .confirmed = confirmed, .admission = admission, .denies = denies } };
    }
    self.state = .rejected;
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    if (answer.result == .rejected) code = answer.result.rejected else try code.set("request conflict");
    return .{ .rejected = .{ .kind = kind, .code = code } };
}

fn heldTicket(self: *const Self) ?Input.Ticket {
    const ticket = if (self.intent) |intent| intent.ticket() else null;
    return ticket orelse if (self.settled_message) |settled| settled.ticket else null;
}

pub fn messageText(self: *const Self) ?[]const u8 {
    const ticket = self.heldTicket() orelse return null;
    return self.input.message(ticket) catch unreachable;
}

pub fn messageHasImage(self: *const Self) bool {
    const ticket = self.heldTicket() orelse return false;
    return (self.input.messageImage(ticket) catch unreachable) != null;
}

pub fn observeMessage(self: *Self, key: [36]u8) void {
    if (self.settled_message) |settled| {
        if (std.mem.eql(u8, &key, &settled.key)) {
            self.input.release(settled.ticket) catch unreachable;
            self.settled_message = null;
        }
    }
    if (self.intent) |intent| if (intent.ticket() != null and std.mem.eql(u8, &key, &self.key)) {
        self.projected = true;
    };
}

/// The canonical Store belongs to the accepted receipt, not a later selector resolution.
pub fn appliedProbe(self: *const Self) ?AppliedProbe {
    const held = self.settled_message orelse return null;
    return .{ .key = held.key, .store = held.store };
}

/// An applied Host observation can account for an accepted ticket outside the loaded feed.
/// It cannot settle an uncertain intent or a queued/excluded admission.
pub fn observeApplied(self: *Self, store_identity: []const u8, observed: protocol_reply.CommandObservation) !AppliedResult {
    const held = self.settled_message orelse return .unverified;
    if (held.store.len == 0 or !held.store.eql(store_identity) or !observed.key.eql(&held.key) or
        observed.status != .accepted or observed.kind != .message or
        observed.target == null or !observed.target.?.eql(self.session)) return .unverified;
    const state = observed.state orelse return .unverified;
    const input = observed.input orelse return .unverified;
    const queue = observed.queue orelse return .unverified;
    if (held.admission) |admission| if (queue.admission != admission) return .unverified;
    if (!@import("mutation_answer.zig").matchesMessageAdmission(input, queue.admission)) return .unverified;
    const expected = (try self.draftTarget(held.ticket)).message;
    const identity = input.identity();
    if (std.meta.activeTag(input) != expected.form or identity.length != expected.bytes or
        !std.mem.eql(u8, &identity.digest, &expected.digest)) return .unverified;
    if (observed.binding == null) return switch (state) {
        .queued => .queued,
        .cancelled => .excluded,
        else => .unverified,
    };
    if (state == .queued or state == .rejected) return .unverified;
    self.observeMessage(held.key);
    return .taken;
}

pub fn messageKey(self: *const Self) ?[36]u8 {
    if (self.intent) |intent| if (intent.ticket() != null) return self.key;
    return if (self.settled_message) |settled| settled.key else null;
}

pub fn messageProjected(self: *const Self) bool {
    if (self.intent) |intent| if (intent.ticket() != null) return self.projected;
    return false;
}

pub fn messageHeld(self: *const Self) bool {
    return self.settled_message != null;
}

pub fn disposeMessage(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    const settled = self.settled_message orelse return;
    self.input.release(settled.ticket) catch unreachable;
    self.settled_message = null;
}

pub fn discardRejected(self: *Self) !void {
    if (self.intent == null) return;
    if (!original_state.discardable(self.state, self.task.thread != null)) return error.SubmissionUnresolved;
    self.release();
}

fn release(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    if (self.intent.?.ticket()) |ticket| self.input.release(ticket) catch unreachable;
    self.retire();
}

fn retire(self: *Self) void {
    self.close();
    self.intent = null;
    self.publication = .not_sent;
    self.last_error = null;
    self.retry = null;
    self.projected = false;
}

pub fn close(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    if (self.captured) |*capture| capture.close(self.io);
    self.captured = null;
}

fn submit(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
    self.publication = original_state.capturing(self.publication);
    self.captured = switch (self.intent.?) {
        .message, .message_then_deny => try self.captureDraft(task.io, self.intent.?.ticket().?),
        .decision => |decision| try client.capturePermissionDecision(task.io, .{ .store = self.store, .session = self.session, .action_id = decision.action, .decision = decision.decision }, self.target),
    };
    self.publication = .published;
    self.reply = try task.requests().sendCaptured(&self.captured.?, self.environment, &self.reply_buffer).get();
}

fn captureDraft(self: *Self, io: std.Io, ticket: Input.Ticket) !client.CapturedRecord {
    const text = try self.input.message(ticket);
    var message: client.MessageInput = .{ .store = self.store, .session = self.session, .text_path = "", .text = text, .require_model = true };
    var operands: [2]client.MessageOperand = undefined;
    if (try self.input.messageImage(ticket)) |image| {
        operands = .{ .{ .text = text }, .{ .image_bytes = image.bytes } };
        message.text = null;
        message.operands = operands[@intFromBool(text.len == 0)..];
        message.operand_stdin = .none;
    }
    return client.captureMessage(io, message, self.target).get();
}

fn draftTarget(self: *const Self, ticket: Input.Ticket) !protocol_reply.MutationTarget {
    const bytes = try self.input.message(ticket);
    if (try self.input.messageImage(ticket)) |image| {
        const parts = @import("input_parts.zig");
        var manifest: parts.Manifest.Encoder = .{};
        var encoded: [parts.Manifest.max_entry_bytes]u8 = undefined;
        if (bytes.len != 0) _ = try manifest.append(&.{ .length = bytes.len, .digest = protocol.contentDigest(bytes), .kind = .text }, &encoded);
        _ = try manifest.append(&image.identity, &encoded);
        const identity = (try manifest.finish()).parts;
        return .{ .message = .{ .bytes = identity.length, .digest = identity.digest, .form = .parts } };
    }
    return .{ .message = .{ .bytes = bytes.len, .digest = protocol.contentDigest(bytes) } };
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
        var self: Self = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .key = @splat('A'), .projected = true, .accepted = .{ .kind = .message, .key = @splat('A') } };
        const intent: Intent = if (kind == 0) .{ .message = input.submitText("original café!") } else .{ .decision = .{ .action = 9, .decision = if (kind == 1) .allow_once else .deny } };
        _ = input.typed("next té!\x1b[D");
        try std.testing.expectError(error.EntropyUnavailable, self.begin(intent));
        try std.testing.expectEqual(.not_started, self.view().?.state);
        try std.testing.expectEqual(@as([36]u8, @splat(0)), self.view().?.key);
        self.observeMessage(@splat('A'));
        try std.testing.expect(!self.messageProjected());
        try std.testing.expectEqual(@as([36]u8, @splat('A')), self.accepted.?.key);
        try std.testing.expectEqual(intent.kind(), self.recovery().not_sent);
        try std.testing.expect(self.join() == .absent);
        try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
        if (kind == 0) try std.testing.expectEqualStrings("original café!", try input.message(intent.message));
        try std.testing.expectEqualStrings("next té!", input.composition().bytes);
        try std.testing.expectEqual("next té".len, input.composition().cursor);
    }
}

test "an accepted reason names its Action's denial; a rejected one denies nothing; an unconfirmed one keeps the denial for Ctrl-R" {
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
        fn lost(_: *anyopaque, _: *Task) !void {
            return error.ConnectionResetByPeer;
        }
        fn forbidden(_: *Self) !void {
            return error.UnexpectedRetry;
        }
        fn accept(owner: *Self) !void {
            owner.reply = reply(true);
            try owner.task.start(owner.io, owner, done);
        }
        fn reply(accepted: bool) protocol_reply.MutationReply {
            return .{ .status = 200, .context = .{ .kind = .message }, .target = .{ .message = .{ .bytes = 4, .digest = protocol.contentDigest("skip") } }, .answer = .{ .replayed = false, .result = if (accepted) .{ .accepted = .{ .message = .{ .admission = 37 } } } else .{ .rejected = .{} } } };
        }
        fn settle(owner: *Self, launch: *const fn (*Self) anyerror!void) !End {
            const deadline = std.Io.Clock.awake.now(owner.io).nanoseconds + 6_000_000_000;
            while (!owner.task.completed()) {
                if (std.Io.Clock.awake.now(owner.io).nanoseconds >= deadline) return error.TestCompletionDeadline;
                std.Thread.yield() catch {};
            }
            return owner.advanceWithLaunch(launch);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    for ([_]enum { accepted, rejected, lost }{ .accepted, .rejected, .lost }) |outcome| {
        errdefer std.debug.print("reason outcome={s}\n", .{@tagName(outcome)});
        var input: Input = undefined;
        input.init();
        var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = directory, .input = &input, .environment = .empty, .key = @splat('B'), .state = .unconfirmed, .publication = .published };
        self.intent = .{ .message_then_deny = .{ .ticket = input.submitText("skip"), .action = 19 } };
        self.reply = Worker.reply(outcome == .accepted);
        try self.task.start(self.io, &self, if (outcome == .lost) Worker.lost else Worker.done);
        defer {
            self.cancel();
            _ = self.join();
            self.close();
        }
        var end = try Worker.settle(&self, Worker.forbidden);
        switch (outcome) {
            .accepted => {},
            .rejected => {
                try std.testing.expect(end == .rejected);
                try std.testing.expectEqual(Kind.message, self.view().?.kind);
                try self.requestRecovery(null);
                try std.testing.expect(try self.advanceWithLaunch(Worker.forbidden) == .absent);
                try self.discardRejected();
                try std.testing.expect(self.view() == null);
                continue;
            },
            .lost => {
                try std.testing.expectEqual(error.ConnectionResetByPeer, end.failed.err);
                try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
                try std.testing.expectEqual(@as(u64, 19), self.intent.?.message_then_deny.action);
                try self.requestRecovery(null);
                try std.testing.expect(try self.advanceWithLaunch(Worker.accept) == .absent);
                end = try Worker.settle(&self, Worker.forbidden);
            },
        }
        try std.testing.expectEqual(Kind.message, end.accepted.kind);
        try std.testing.expectEqual(@as(?u64, 37), end.accepted.admission);
        try std.testing.expectEqual(@as(?u64, 19), end.accepted.denies);
        try std.testing.expect(self.view() == null);
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
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .accepted = .{ .kind = .message, .key = @splat('A') }, .publication = publication, .key = @splat('B'), .state = .unconfirmed };
                self.intent = if (kind == 0) .{ .message = input.submitText("original B café!") } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
                _ = input.typed("newer té!\x1b[D");
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

test "a chat Message captures require_model so the Host refuses a Session whose provider is unserved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var input: Input = undefined;
    input.init();
    var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .input = &input, .environment = .empty };
    defer self.close();
    try self.begin(.{ .message = input.submitText("hello") });
    _ = self.join();
    const captured = &(self.captured orelse return error.TestExpectedCapture);
    var bytes: [4096]u8 = undefined;
    const length = try captured.file.readPositionalAll(io, &bytes, 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("require_model").?.bool);
    try std.testing.expectEqualStrings("k7m2qx", parsed.value.object.get("session").?.string);
}

test "SUI-114 clipboard image submission recovers the original multipart identity" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_][]const u8{ "", "caption" }) |caption| {
        var input: Input = undefined;
        input.init();
        defer input.deinit();
        const attachment = try Input.Image.validate(@embedFile("codecs/fixtures/image-input/pixel.png"));
        input.setImage(try attachment.clone());
        _ = input.append(caption);
        const ticket = input.typed("\r").message;
        var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .input = &input, .environment = .empty };
        defer self.close();
        try self.begin(.{ .message = ticket });
        _ = self.join();
        const capture = self.captured orelse return error.TestExpectedCapture;
        try std.testing.expectEqual(.parts, capture.target.message.form);
        try std.testing.expectEqualDeep(try self.draftTarget(ticket), capture.target);
        const key = self.key;
        self.close();
        _ = input.append("next draft");
        try self.requestRecovery(&key);
        _ = try self.advance();
        _ = self.join();
        const recovered = self.captured orelse return error.TestExpectedCapture;
        try std.testing.expectEqualDeep(capture.target, recovered.target);
        try std.testing.expectEqualSlices(u8, &key, &self.key);
        try std.testing.expectEqualStrings("next draft", input.composition().bytes);
        try std.testing.expectEqualSlices(u8, attachment.bytes, (try input.messageImage(ticket)).?.bytes);
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
            var self: Self = .{ .io = .{ .userdata = io.userdata, .vtable = &vtable }, .store = root, .session = "k7m2qx", .directory = root, .input = &input, .environment = .empty };
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
            _ = input.typed("newer té!\x1b[D");
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
        self.captured = client.openCaptured(task.io, .{ .generated = .{ .directory = self.directory, .handle = &self.key } }) catch |err| switch (err) {
            error.FileNotFound => return submit(raw, task),
            else => return err,
        };
        errdefer {
            self.captured.?.close(task.io);
            self.captured = null;
        }
        const original: protocol_reply.MutationTarget = switch (self.intent.?) {
            .message, .message_then_deny => try self.draftTarget(self.intent.?.ticket().?),
            .decision => |decision| .{ .permission_decision = .{ .action = decision.action, .decision = decision.decision } },
        };
        const expected: client.Binding = .{ .store = self.store, .session = self.session, .key = &self.key, .target = original };
        if (!expected.matches(&self.captured.?.saved, self.captured.?.target)) return error.OriginalBindingMismatch;
        self.publication = .published;
    }
    self.reply = try task.requests().sendCaptured(&self.captured.?, self.environment, &self.reply_buffer).get();
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
    var endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
    defer endpoint.retire() catch @panic("unable to retire fixture endpoint");
    var listener = try endpoint.listen(.{});
    defer listener.deinit(io);
    for (0..3) |kind| {
        for ([_][]const u8{ "accepted", "rejected", "conflict", "invalid" }) |status| {
            errdefer std.debug.print("intent {d}, Admission {s}\n", .{ kind, status });
            const accepted = std.mem.eql(u8, status, "accepted");
            const conflict = std.mem.eql(u8, status, "conflict");
            const invalid = std.mem.eql(u8, status, "invalid");
            var body_buffer: [1024]u8 = undefined;
            var body = std.Io.Writer.fixed(&body_buffer);
            try body.print("{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"{s}_reply\",\"answer\":{{\"status\":\"{s}\",\"replayed\":false,\"session\":\"k7m2qx\"", .{ if (kind == 0) "message" else "permission_decision", status });
            if (!accepted) try body.print(",\"code\":\"{s}\"", .{if (conflict) "idempotency_key_conflict" else "not_allowed"});
            if (kind == 0 and !accepted and !conflict and !invalid) try body.writeAll(",\"missing\":null");
            if (kind != 0) try body.print(",\"action\":\"19\",\"decision\":\"{s}\"", .{if (kind == 1) "allow_once" else "deny"});
            if (kind == 0 and accepted) try body.writeAll(",\"admission\":\"37\"");
            try body.writeAll("}");
            if (kind == 0) {
                try body.writeAll(",\"execution\":{\"status\":\"queued\"}");
                if (!conflict) try body.writeAll(",\"input\":{\"type\":\"text\",\"bytes\":\"15\",\"sha256\":\"d02342cf8f590cb32eff9b3d74fffa781a3caa7ea94c4145612c09244fd25d00\"}");
                if (accepted) try body.writeAll(",\"queue\":{\"status\":\"queued\",\"admission\":\"37\"}");
            }
            try body.writeAll("}");
            var response_buffer: [1536]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{s}", .{ if (conflict) "409 Conflict" else "200 OK", body.buffered().len, body.buffered() });
            var input: Input = undefined;
            input.init();
            var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .input = &input, .environment = .empty };
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
            try std.testing.expectEqual(.submitting, self.view().?.state);
            try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
            try self.requestRecovery(null);
            _ = input.typed("next té!\x1b[D");
            const key = self.view().?.key;
            const end = self.join();
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

test "accepted native Message keeps its exact input loan until canonical insertion" {
    var input: Input = undefined;
    input.init();
    const ticket = input.submitText("same text\nsecond line");
    var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .intent = .{ .message = ticket }, .key = @splat('A'), .state = .submitting, .retain_message = true };
    self.reply = .{ .status = 200, .context = .{ .kind = .message }, .target = .{ .message = .{ .bytes = 21, .digest = protocol.contentDigest("same text\nsecond line") } }, .answer = .{ .replayed = false, .result = .{ .accepted = .{ .message = .{ .admission = 37 } } } } };
    try self.reply.?.context.store.set("/canonical-store");
    const end = try self.apply({});
    try std.testing.expect(end == .accepted);
    try std.testing.expect(self.intent == null and self.view() == null);
    try std.testing.expect(self.messageHeld());
    try std.testing.expect(self.appliedProbe().?.store.eql("/canonical-store"));
    try std.testing.expectEqual(@as(?u64, 37), self.settled_message.?.admission);
    try std.testing.expectEqualStrings("same text\nsecond line", self.messageText().?);
    try std.testing.expectEqual(@as([36]u8, @splat('A')), self.messageKey().?);
    _ = input.append("next draft");
    try std.testing.expect(input.typed("\r") == .busy);
    try std.testing.expectEqualStrings("next draft", input.composition().bytes);
    try self.requestRecovery(null);
    try std.testing.expect(self.retry == null);
    try std.testing.expect(self.recovery() == .accepted);
    self.observeMessage(@splat('B'));
    try std.testing.expect(self.messageHeld());
    self.observeMessage(@splat('A'));
    try std.testing.expect(!self.messageHeld() and self.messageText() == null);
    try std.testing.expectError(error.NoSubmission, input.message(ticket));
    self.observeMessage(@splat('A'));
    const next = input.typed("\r");
    try std.testing.expect(next == .message);
    self.intent = .{ .message = next.message };
    self.key = @splat('B');
    self.observeMessage(@splat('A'));
    try std.testing.expect(!self.messageProjected());
    try std.testing.expectEqualStrings("next draft", self.messageText().?);
    self.state = .rejected;
    try self.discardRejected();
}

test "SUI-146 applied observation releases only the exact accepted Message identity" {
    const Variant = enum { exact, completed, failed, cancelled_bound, permission_bound, wrong_store, wrong_key, wrong_session, absent, rejected, wrong_kind, queued, forged_queue, excluded, unbound, missing_input, missing_queue, wrong_admission, wrong_length, wrong_digest, wrong_form, wrong_parts_owner };
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    for ([_]bool{ false, true }) |image| for (std.enums.values(Variant)) |variant| {
        var input: Input = undefined;
        input.init();
        defer input.deinit();
        if (image) {
            const attachment = try Input.Image.validate(@embedFile("codecs/fixtures/image-input/pixel.png"));
            input.setImage(try attachment.clone());
        }
        _ = input.append("original text");
        const ticket = input.typed("\r").message;
        var self: Self = .{ .io = std.testing.io, .store = "/private-store", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .settled_message = .{ .ticket = ticket, .key = key, .admission = 37, .store = try .from("/private-store") } };
        _ = input.append("next draft");
        const expected = (try self.draftTarget(ticket)).message;
        const reference: @import("content_value.zig").Reference = .{ .length = expected.bytes, .digest = expected.digest };
        var observed: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = .message, .target = .{}, .state = .processing, .queue = .{ .admission = 37, .admitted_at = 1 }, .binding = .{ .turn = 2, .operation = 3, .attempt = 1 } };
        try observed.key.set(&key);
        try observed.target.?.set("k7m2qx");
        observed.input = if (image) .{ .parts = .{ .identity = reference, .owner = .{ .message = 37 } } } else .{ .text = reference };
        switch (variant) {
            .exact, .wrong_store => {},
            .completed => observed.state = .completed,
            .failed => observed.state = .failed,
            .cancelled_bound => observed.state = .cancelled,
            .permission_bound => observed.state = .waiting_for_permission,
            .absent => observed.status = .absent,
            .wrong_key => try observed.key.set("01234567-89ab-4cde-8012-0123456789ac"),
            .wrong_session => try observed.target.?.set("a1b2c3"),
            .rejected => observed.status = .rejected,
            .wrong_kind => observed.kind = .configure,
            .queued => {
                observed.state = .queued;
                observed.binding = null;
            },
            .forged_queue => observed.state = .queued,
            .excluded => {
                observed.state = .cancelled;
                observed.binding = null;
            },
            .unbound => observed.binding = null,
            .missing_input => observed.input = null,
            .missing_queue => observed.queue = null,
            .wrong_admission => observed.queue.?.admission = 38,
            .wrong_length => switch (observed.input.?) {
                .text => |*value| value.length += 1,
                .parts => |*value| value.identity.length += 1,
            },
            .wrong_digest => switch (observed.input.?) {
                .text => |*value| value.digest[0] ^= 1,
                .parts => |*value| value.identity.digest[0] ^= 1,
            },
            .wrong_form => observed.input = if (image) .{ .text = reference } else .{ .parts = .{ .identity = reference, .owner = .{ .message = 37 } } },
            .wrong_parts_owner => if (image) {
                observed.input.?.parts.owner = .{ .message = 38 };
            },
        }
        const matches = variant == .exact or variant == .completed or variant == .failed or variant == .cancelled_bound or variant == .permission_bound or (variant == .wrong_parts_owner and !image);
        const result: AppliedResult = if (matches) .taken else switch (variant) {
            .queued => .queued,
            .excluded => .excluded,
            else => .unverified,
        };
        try std.testing.expectEqual(result, try self.observeApplied(if (variant == .wrong_store) "/other-store" else "/private-store", observed));
        try std.testing.expectEqual(!matches, self.messageHeld());
        try std.testing.expectEqualStrings("next draft", input.composition().bytes);
        if (!matches) self.disposeMessage();
    };
}

test "SUI-146 an alias retarget cannot substitute a different Store for the accepted receipt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    try tmp.dir.createDir(io, "first", .fromMode(0o700));
    try tmp.dir.createDir(io, "second", .fromMode(0o700));
    try tmp.dir.symLink(io, "first", "alias", .{ .is_directory = true });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const alias = try std.fmt.bufPrint(&path_buffer, "{s}/alias", .{root});
    const original = try client.resolveClientPaths(io, alias);
    try tmp.dir.deleteFile(io, "alias");
    try tmp.dir.symLink(io, "second", "alias", .{ .is_directory = true });
    const retargeted = try client.resolveClientPaths(io, alias);
    try std.testing.expect(!original.store_identity.eql(retargeted.store_identity.slice()));
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    var input: Input = undefined;
    input.init();
    defer input.deinit();
    const ticket = input.submitText("original text");
    var self: Self = .{ .io = io, .store = alias, .session = "k7m2qx", .directory = root, .input = &input, .environment = .empty, .settled_message = .{ .ticket = ticket, .key = key, .admission = 37, .store = original.store_identity } };
    defer if (self.messageHeld()) self.disposeMessage();
    _ = input.append("next draft");
    var observed: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = .message, .target = .{}, .state = .processing, .queue = .{ .admission = 37, .admitted_at = 1 }, .binding = .{ .turn = 2, .operation = 3, .attempt = 1 }, .input = .{ .text = .{ .length = "original text".len, .digest = protocol.contentDigest("original text") } } };
    try observed.key.set(&key);
    try observed.target.?.set("k7m2qx");
    try std.testing.expectEqual(AppliedResult.unverified, try self.observeApplied(retargeted.store_identity.slice(), observed));
    try std.testing.expect(self.messageHeld());
    try std.testing.expectEqualStrings("next draft", input.composition().bytes);
    try std.testing.expectEqual(AppliedResult.taken, try self.observeApplied(original.store_identity.slice(), observed));
}

test "SUI-146 applied Message evidence preserves a separate unconfirmed Decision" {
    const a: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const b: [36]u8 = "01234567-89ab-4cde-8012-0123456789ac".*;
    var input: Input = undefined;
    input.init();
    defer input.deinit();
    const ticket = input.submitText("reason");
    var self: Self = .{ .io = std.testing.io, .store = "/private-store", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .settled_message = .{ .ticket = ticket, .key = a, .admission = 37, .store = try .from("/private-store") }, .intent = .{ .decision = .{ .action = 19, .decision = .deny } }, .state = .unconfirmed, .publication = .published, .key = b };
    var observed: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = .message, .target = .{}, .state = .processing, .queue = .{ .admission = 37, .admitted_at = 1 }, .binding = .{ .turn = 2, .operation = 3, .attempt = 1 }, .input = .{ .text = .{ .length = "reason".len, .digest = protocol.contentDigest("reason") } } };
    try observed.key.set(&a);
    try observed.target.?.set("k7m2qx");
    try std.testing.expectEqual(AppliedResult.taken, try self.observeApplied("/private-store", observed));
    try std.testing.expect(!self.messageHeld());
    try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
    try std.testing.expectEqual(b, self.view().?.key);
    try self.requestRecovery(&b);
    try std.testing.expectEqual(b, self.retry.?);
}

test "SUI-146 an applied observation never releases an unconfirmed original" {
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    var input: Input = undefined;
    input.init();
    defer input.deinit();
    const ticket = input.submitText("original text");
    var self: Self = .{ .io = std.testing.io, .store = "/private-store", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .intent = .{ .message = ticket }, .key = key, .state = .unconfirmed, .publication = .published };
    _ = input.append("next draft");
    var observed: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = .message, .target = .{}, .state = .processing, .queue = .{ .admission = 37, .admitted_at = 1 }, .binding = .{ .turn = 2, .operation = 3, .attempt = 1 }, .input = .{ .text = .{ .length = "original text".len, .digest = protocol.contentDigest("original text") } } };
    try observed.key.set(&key);
    try observed.target.?.set("k7m2qx");
    try std.testing.expectEqual(AppliedResult.unverified, try self.observeApplied("/private-store", observed));
    try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
    try self.requestRecovery(&key);
    try std.testing.expectEqual(key, self.retry.?);
    try std.testing.expectEqualStrings("next draft", input.composition().bytes);
}

test "uncertain canonical observation hides only the echo and retains original recovery" {
    var input: Input = undefined;
    input.init();
    const ticket = input.submitText("same text");
    var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .intent = .{ .message = ticket }, .key = @splat('A'), .state = .unconfirmed, .publication = .published, .retain_message = true };
    self.observeMessage(@splat('B'));
    try std.testing.expect(!self.messageProjected());
    self.observeMessage(@splat('A'));
    try std.testing.expect(self.messageProjected());
    try std.testing.expectEqual(State.unconfirmed, self.view().?.state);
    try std.testing.expectEqualStrings("same text", try input.message(ticket));
    try self.requestRecovery(null);
    try std.testing.expectEqual(@as([36]u8, @splat('A')), self.retry.?);
    try std.testing.expect(self.recovery() == .saved);
    self.reply = .{ .status = 200, .context = .{ .kind = .message }, .target = .{ .message = .{ .bytes = 9, .digest = protocol.contentDigest("same text") } }, .answer = .{ .replayed = true, .result = .{ .accepted = .{ .message = .{ .admission = 37 } } } } };
    const end = try self.apply({});
    try std.testing.expect(end.accepted.confirmed);
    try std.testing.expect(self.intent == null and !self.messageHeld());
    try std.testing.expectError(error.NoSubmission, input.message(ticket));
    try std.testing.expect(self.retry == null);
}

test "accepted reason presentation loan never delays or borrows the denial authority" {
    const Worker = struct {
        fn done(_: *anyopaque, _: *Task) !void {}
    };
    var input: Input = undefined;
    input.init();
    const ticket = input.submitText("reason");
    var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .intent = .{ .message_then_deny = .{ .ticket = ticket, .action = 19 } }, .key = @splat('A'), .state = .submitting, .retain_message = true };
    self.reply = .{ .status = 200, .context = .{ .kind = .message }, .target = .{ .message = .{ .bytes = 6, .digest = protocol.contentDigest("reason") } }, .answer = .{ .replayed = false, .result = .{ .accepted = .{ .message = .{ .admission = 37 } } } } };
    const end = try self.apply({});
    try std.testing.expectEqual(@as(?u64, 19), end.accepted.denies);
    try std.testing.expect(self.intent == null and self.messageHeld());
    self.intent = .{ .decision = .{ .action = 19, .decision = .deny } };
    self.key = @splat('B');
    self.state = .submitting;
    self.reply = .{ .status = 200, .context = .{ .kind = .permission_decision }, .target = .{ .permission_decision = .{ .action = 19, .decision = .deny } }, .answer = .{ .replayed = false, .result = .{ .accepted = .permission_decision } } };
    try self.task.start(self.io, &self, Worker.done);
    try std.testing.expectEqual(@as([36]u8, @splat('A')), self.messageKey().?);
    try std.testing.expectEqualStrings("reason", self.messageText().?);
    self.observeMessage(@splat('A'));
    try std.testing.expect(!self.messageHeld());
    try std.testing.expect(self.task.thread != null and self.intent.? == .decision);
    try std.testing.expectError(error.NoSubmission, input.message(ticket));
    const decision = self.join();
    try std.testing.expectEqual(Kind.decision, decision.accepted.kind);
    try std.testing.expect(self.intent == null and self.messageText() == null);
    try std.testing.expectEqual(@as([36]u8, @splat('B')), self.accepted.?.key);
    self.disposeMessage();
}

test "leaving disposes accepted presentation custody without changing current original" {
    var input: Input = undefined;
    input.init();
    const ticket = input.submitText("accepted reason");
    var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .input = &input, .environment = .empty, .intent = .{ .decision = .{ .action = 19, .decision = .deny } }, .key = @splat('B'), .state = .unconfirmed, .publication = .published, .settled_message = .{ .ticket = ticket, .key = @splat('A') } };
    self.disposeMessage();
    self.disposeMessage();
    try std.testing.expect(input.submitted == null);
    try std.testing.expectEqual(Kind.decision, self.view().?.kind);
    try std.testing.expectEqual(@as([36]u8, @splat('B')), self.recovery().saved.original.key);
}
