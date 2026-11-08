//! One invocation's original intent and Admission borrower. Initialize in final
//! storage; this owner must not move until its borrower joins.
const std = @import("std");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Input = @import("SessionInput.zig");
const TerminalInput = @import("TerminalInput.zig");
const Task = @import("ClientTask.zig");
const Self = @This();

pub const Intent = union(enum) {
    message: []const u8,
    /// A Message sent as the reason `action` is denied. The Message goes
    /// first and its acceptance names the denial to begin next: the Host
    /// holds the Message until the denial settles the call group, so the
    /// model reads both in one request.
    message_then_deny: struct { text: []const u8, action: u64 },
    decision: struct { action: u64, decision: protocol.PermissionDecision },

    pub fn kind(self: Intent) Kind {
        return switch (self) {
            .message, .message_then_deny => .message,
            .decision => .decision,
        };
    }

    /// The Message's sealed text; null for a decision.
    pub fn text(self: Intent) ?[]const u8 {
        return switch (self) {
            .message => |message| message,
            .message_then_deny => |reason| reason.text,
            .decision => null,
        };
    }
};
/// An explicit confirmation bound to the Host that supplied the Action.
pub const ObservedDecision = struct {
    action: u64,
    decision: protocol.PermissionDecision,
    observed_instance: protocol.InstanceId,
};

pub const Kind = enum { message, decision };
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
    // A Message's admission orders it among delivered ones. An accepted
    // reason names the Action whose denial the caller begins next.
    accepted: struct { kind: Kind, confirmed: bool, admission: ?u64 = null, denies: ?u64 = null, session: ?[protocol.session_id_bytes]u8 = null },
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
/// The terminal's environment, carried by each Message for its Bash.
environment: client.Environment,
/// Creation settings are stable for this admission until its worker joins.
configuration: ?client.ConfigureInput = null,
captured_hook: ?*const fn (std.Io) anyerror!void = null,
intent: ?Intent = null,
/// The first send of an observed Action stays fenced until transmission may
/// have reached a Host. A retry can never clear earlier ambiguity.
observed_instance: ?protocol.InstanceId = null,
transmission_may_have_reached_host: bool = false,
/// Original Message bytes, frozen before starting the worker.
message_bytes: [65_536]u8 = undefined,
state: State = .not_started,
task: Task = .{},
key: [36]u8 = @splat(0),
path: [std.Io.Dir.max_path_bytes]u8 = undefined,
target: client.CaptureTarget = undefined,
target_reserved: bool = false,
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
    return .{ .kind = intent.kind(), .state = self.state, .key = self.key, .last_error = self.last_error };
}

/// Recovery guidance is read only after both frontend borrowers have joined.
pub fn recovery(self: *const Self) Recovery {
    std.debug.assert(self.task.thread == null);
    if (self.intent) |intent| {
        const kind = intent.kind();
        if (self.state == .not_started) return .{ .not_sent = kind };
        if (self.publication != .published) return .{ .uncertain = self.key };
        return .{ .saved = .{ .original = .{ .kind = kind, .key = self.key }, .rejected = self.state == .rejected } };
    }
    return if (self.accepted) |accepted| .{ .accepted = accepted } else .none;
}

pub fn begin(self: *Self, intent: Intent) !void {
    return self.beginWithFence(intent, null);
}

pub fn beginObservedDecision(self: *Self, decision: ObservedDecision) !void {
    return self.beginWithFence(.{ .decision = .{ .action = decision.action, .decision = decision.decision } }, decision.observed_instance);
}

fn beginWithFence(self: *Self, intent: Intent, instance: ?protocol.InstanceId) !void {
    std.debug.assert(self.intent == null and self.task.thread == null);
    // Freeze the original before randomness, reservation or launch can fail.
    // Neither retries nor a later draft borrow the caller's editor.
    self.intent = switch (intent) {
        .message => |text| .{ .message = try self.freezeMessage(text) },
        .message_then_deny => |reason| .{ .message_then_deny = .{ .text = try self.freezeMessage(reason.text), .action = reason.action } },
        .decision => intent,
    };
    self.observed_instance = instance;
    self.transmission_may_have_reached_host = false;
    self.state = .not_started;
    self.reply = null;
    self.publication = .not_sent;
    self.target_reserved = false;
    try self.reserveTarget();
    try self.startWorker(submit);
    self.state = .submitting;
}

fn reserveTarget(self: *Self) !void {
    const target: client.CaptureTarget = .{ .generated = self.directory };
    self.target = .{ .reserved = try target.resolve(self.io, &self.path, &self.key) };
    self.target_reserved = true;
}

fn freezeMessage(self: *Self, text: []const u8) ![]const u8 {
    if (text.len > self.message_bytes.len) return error.MessageTooLarge;
    @memcpy(self.message_bytes[0..text.len], text);
    return self.message_bytes[0..text.len];
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
    const key = self.retryable() orelse return false;
    return std.mem.eql(u8, &requested, key);
}

/// The original's key while a retry of it may go: it is not rejected.
fn retryable(self: *const Self) ?*const [36]u8 {
    return if (self.intent != null and self.state != .rejected) &self.key else null;
}

/// The original a retry would send now and could only send as a Message:
/// a plain Message whose Admission is unconfirmed, with nothing in flight.
/// Never a decision, or a Message that carries one.
pub fn unconfirmedMessage(self: *const Self) ?*const [36]u8 {
    const key = self.retryable() orelse return null;
    if (self.task.thread != null or self.state != .unconfirmed or self.intent.? != .message) return null;
    return key;
}

fn launchRetry(self: *Self) !void {
    if (!self.target_reserved) {
        try self.reserveTarget();
        try self.startWorker(submit);
    } else {
        try self.startWorker(resend);
    }
    self.state = .submitting;
}

// ClientTask's pthread entry is shared with frontend readers. Let the native
// fixture identify this spawn's purpose, without guessing from thread order or
// opaque std.Thread arguments. The optional preload hook only scopes identity;
// pthread_create still owns the injected failure and its normal error mapping.
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
            var stream: TerminalInput = .{};
            var input: Input = undefined;
            input.init(&stream);
            var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .environment = .empty };
            // An idle gesture has no authority over a future original.
            try self.requestRecovery(null);
            self.intent = if (kind == 0) .{ .message = "B" } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
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
                var stream: TerminalInput = .{};
                var input: Input = undefined;
                input.init(&stream);
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .environment = .empty, .key = @splat('B'), .state = .unconfirmed, .publication = .published };
                self.intent = if (kind == 0) .{ .message = "original B" } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
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
                self.intent = if (kind == 0) .{ .message = "replacement C" } else .{ .decision = .{ .action = 20, .decision = if (kind == 1) .allow_once else .deny } };
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
        self.state = if (self.publication == .not_sent or (self.observed_instance != null and !self.transmission_may_have_reached_host)) .not_started else .unconfirmed;
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
        self.release();
        const admission: ?u64 = switch (answer.result.accepted) {
            .message => |message| message.admission,
            else => null,
        };
        const denies: ?u64 = if (intent == .message_then_deny) intent.message_then_deny.action else null;
        const resolved = self.reply.?.context.session.slice();
        const session: ?[protocol.session_id_bytes]u8 = if (resolved.len == protocol.session_id_bytes) resolved[0..protocol.session_id_bytes].* else null;
        return .{ .accepted = .{ .kind = kind, .confirmed = confirmed, .admission = admission, .denies = denies, .session = session } };
    }
    self.state = .rejected;
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    if (answer.result == .rejected) code = answer.result.rejected else try code.set("request conflict");
    return .{ .rejected = .{ .kind = kind, .code = code } };
}

/// Only a joined, definitely unsent or authoritatively rejected original may
/// be released without confirmation of its admission.
pub fn discardUnsentOrRejected(self: *Self) !void {
    if (self.intent == null) return;
    if (self.task.thread != null) return error.SubmissionUnresolved;
    const definitely_unsent = self.state == .not_started and (self.publication == .not_sent or (self.observed_instance != null and !self.transmission_may_have_reached_host));
    if (self.state != .rejected and !definitely_unsent) return error.SubmissionUnresolved;
    self.release();
}

pub fn discardRejected(self: *Self) !void {
    if (self.intent == null) return;
    if (self.task.thread != null or self.state != .rejected) return error.SubmissionUnresolved;
    self.release();
}

fn release(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    self.close();
    self.intent = null;
    self.observed_instance = null;
    self.transmission_may_have_reached_host = false;
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
        .message, .message_then_deny => try client.captureMessage(task.io, .{ .store = self.store, .session = self.session, .text_path = "", .text = self.intent.?.text().?, .configuration = self.configuration }, self.target).get(),
        .decision => |decision| try client.capturePermissionDecision(task.io, .{ .store = self.store, .session = self.session, .action_id = decision.action, .decision = decision.decision }, self.target),
    };
    self.publication = .published;
    if (self.captured_hook) |hook| try hook(task.io);
    try self.sendOriginal(task);
}

/// Capture custody and wire custody are distinct: published local bytes do not
/// prove a request ever reached a Host. Only an explicit retry may reuse this
/// function after a potentially transmitted attempt.
fn sendOriginal(self: *Self, task: *Task) !void {
    var requests = task.requests();
    requests.host_instance = self.firstTransmissionFence();
    switch (requests.sendCaptured(&self.captured.?, self.environment, &self.reply_buffer)) {
        .failed => |failure| {
            self.noteSendFailure(failure.step);
            return failure.err;
        },
        .done => |reply| {
            self.noteSendReply(reply);
            self.reply = reply;
        },
    }
}

fn firstTransmissionFence(self: *const Self) ?*const protocol.InstanceId {
    if (self.transmission_may_have_reached_host) return null;
    if (self.observed_instance) |*instance| return instance;
    return null;
}

fn noteSendFailure(self: *Self, step: ?client.Step) void {
    if (step) |value| if (value.mayHaveReachedHost()) {
        self.transmission_may_have_reached_host = true;
    };
}

fn noteSendReply(self: *Self, reply: protocol_reply.MutationReply) void {
    // A validated instance-mismatch reply means this attempt was refused
    // before admission, but can never erase ambiguity from an earlier attempt.
    const mismatch = reply.status == 409 and if (reply.diagnostic) |diagnostic|
        diagnostic.type.eql("invocation_error") and diagnostic.code.eql("host_instance_changed")
    else
        false;
    if (!mismatch) self.transmission_may_have_reached_host = true;
}

test "native observed decision retains fence until transmission may reach Host" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .environment = .empty };
    defer {
        self.cancel();
        _ = self.join();
        self.close();
    }
    const instance: protocol.InstanceId = @splat(0xa7);
    try self.beginObservedDecision(.{ .action = 19, .decision = .allow_once, .observed_instance = instance });
    const end = self.join();
    try std.testing.expect(end == .failed);
    try std.testing.expectEqual(State.not_started, self.view().?.state);
    try std.testing.expect(self.recovery() == .not_sent);
    try std.testing.expectEqualSlices(u8, &instance, self.firstTransmissionFence().?);
    try std.testing.expect(self.captured != null);
    const key = self.key;
    self.noteSendFailure(null);
    self.noteSendFailure(.connect);
    const refusal = protocol_reply.decodeMutationReply(.{ .status = 409, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"host_instance_changed\"}" }, "k7m2qx", .{ .permission_decision = .{ .action = 19, .decision = .allow_once } });
    self.noteSendReply(refusal);
    try std.testing.expectEqualSlices(u8, &instance, self.firstTransmissionFence().?);
    try std.testing.expectEqualSlices(u8, &key, &self.key);
    self.noteSendFailure(.admission_response);
    try std.testing.expect(self.firstTransmissionFence() == null);
    self.noteSendFailure(.connect);
    self.noteSendReply(refusal);
    try std.testing.expect(self.firstTransmissionFence() == null);
    try std.testing.expectEqualSlices(u8, &key, &self.key);
    self.state = .unconfirmed;
    try std.testing.expectError(error.SubmissionUnresolved, self.discardUnsentOrRejected());
    try std.testing.expect(self.recovery() == .saved);
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
        var stream: TerminalInput = .{};
        var input: Input = undefined;
        input.init(&stream);
        var self: Self = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .store = "unused", .session = "k7m2qx", .directory = "unused", .environment = .empty, .accepted = .{ .kind = .message, .key = @splat('A') } };
        const intent: Intent = if (kind == 0) .{ .message = "original café!" } else .{ .decision = .{ .action = 9, .decision = if (kind == 1) .allow_once else .deny } };
        for ("next té!\x1b[D") |byte| _ = input.feed(byte);
        try std.testing.expectError(error.EntropyUnavailable, self.begin(intent));
        try std.testing.expectEqual(.not_started, self.view().?.state);
        try std.testing.expectEqual(intent.kind(), self.recovery().not_sent);
        try std.testing.expect(self.join() == .absent);
        try std.testing.expectError(error.SubmissionUnresolved, self.discardRejected());
        if (kind == 0) try std.testing.expectEqualStrings("original café!", self.intent.?.text().?);
        try std.testing.expectEqualStrings("next té!", input.composition().bytes);
        try std.testing.expectEqual("next té".len, input.composition().cursor);
    }
}

test "a failed reservation retries frozen bytes and only unsent originals can be discarded" {
    const Failing = struct {
        fn random(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Failing.random;
    var original = [_]u8{ 'o', 'l', 'd' };
    var self: Self = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .store = directory, .session = "k7m2qx", .directory = directory, .environment = .empty };
    defer {
        self.cancel();
        _ = self.join();
        self.close();
    }
    try std.testing.expectError(error.EntropyUnavailable, self.begin(.{ .message = &original }));
    original[0] = 'n';
    try std.testing.expectEqualStrings("old", self.intent.?.text().?);
    try std.testing.expect(!self.target_reserved);
    vtable.randomSecure = std.testing.io.vtable.randomSecure;
    try self.requestRecovery(null);
    try std.testing.expect(try self.advance() == .absent);
    try std.testing.expect(self.target_reserved);
    try std.testing.expect(client.validRequestHandle(&self.key));
    _ = self.join();
    try std.testing.expectEqualStrings("old", self.intent.?.text().?);
    self.state = .unconfirmed;
    try std.testing.expectError(error.SubmissionUnresolved, self.discardUnsentOrRejected());
    self.state = .not_started;
    self.publication = .not_sent;
    try self.discardUnsentOrRejected();
    try std.testing.expect(self.view() == null);
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
        var stream: TerminalInput = .{};
        var input: Input = undefined;
        input.init(&stream);
        var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = directory, .environment = .empty, .key = @splat('B'), .state = .unconfirmed, .publication = .published };
        self.intent = .{ .message_then_deny = .{ .text = "skip", .action = 19 } };
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
                // Ctrl-R never retries a rejected original, and /discard
                // drops the denial with it.
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
                // Ctrl-R retries the Message, and its acceptance brings the
                // denial.
                try self.requestRecovery(null);
                try std.testing.expect(try self.advanceWithLaunch(Worker.accept) == .absent);
                end = try Worker.settle(&self, Worker.forbidden);
            },
        }
        try std.testing.expectEqual(Kind.message, end.accepted.kind);
        try std.testing.expectEqual(@as(?u64, 37), end.accepted.admission);
        try std.testing.expectEqual(@as(?u64, 19), end.accepted.denies);
        // The Message is released; the caller begins the denial.
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
                var stream: TerminalInput = .{};
                var input: Input = undefined;
                input.init(&stream);
                var self: Self = .{ .io = std.testing.io, .store = "unused", .session = "k7m2qx", .directory = "unused", .environment = .empty, .accepted = .{ .kind = .message, .key = @splat('A') }, .publication = publication, .key = @splat('B'), .state = .unconfirmed };
                self.intent = if (kind == 0) .{ .message = "original B café!" } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
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
            var stream: TerminalInput = .{};
            var input: Input = undefined;
            input.init(&stream);
            var vtable = io.vtable.*;
            vtable.fileSync = Failure.sync;
            var self: Self = .{ .io = .{ .userdata = io.userdata, .vtable = &vtable }, .store = root, .session = "k7m2qx", .directory = root, .environment = .empty };
            defer self.close();
            const intent: Intent = if (kind == 0) .{ .message = "original café!" } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
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
            .message, .message_then_deny => blk: {
                const bytes = self.intent.?.text().?;
                break :blk .{ .message = .{ .bytes = bytes.len, .digest = protocol.contentDigest(bytes) } };
            },
            .decision => |decision| .{ .permission_decision = .{ .action = decision.action, .decision = decision.decision } },
        };
        const expected: client.Binding = .{ .store = self.store, .session = self.session, .key = &self.key, .target = original };
        if (!expected.matches(&self.captured.?.saved, self.captured.?.target)) return error.OriginalBindingMismatch;
        self.publication = .published;
    }
    try self.sendOriginal(task);
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
            try body.print("{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"{s}_reply\",\"answer\":{{\"status\":\"{s}\",\"replayed\":false,\"session\":\"k7m2qx\"", .{ if (kind == 0) "message" else "permission_decision", status });
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
            const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{s}", .{ if (conflict) "409 Conflict" else "200 OK", body.buffered().len, body.buffered() });
            var stream: TerminalInput = .{};
            var input: Input = undefined;
            input.init(&stream);
            var self: Self = .{ .io = io, .store = root, .session = "k7m2qx", .directory = root, .environment = .empty };
            defer {
                self.cancel();
                _ = self.join();
                self.close();
            }
            const intent: Intent = if (kind == 0) .{ .message = "original café!" } else .{ .decision = .{ .action = 19, .decision = if (kind == 1) .allow_once else .deny } };
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
                try std.testing.expect(try self.advance() == .absent);
                try std.testing.expect(self.join() == .absent);
            }
        }
    }
}

test "admission freezes original bytes before reservation failure" {
    const Failing = struct {
        fn random(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Failing.random;
    var self: Self = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .store = "unused", .session = "k7m2qx", .directory = "unused", .environment = .empty };
    var draft = "first\nMessage é".*;
    try std.testing.expectError(error.EntropyUnavailable, self.begin(.{ .message = &draft }));
    @memset(&draft, 'x');
    try std.testing.expectEqualStrings("first\nMessage é", self.intent.?.text().?);
    try std.testing.expect(self.recovery() == .not_sent);
}
