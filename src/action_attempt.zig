const std = @import("std");
const execution = @import("execution.zig");
const store = @import("store.zig");
const result_fault = @import("result_fault.zig");
const server_host = @import("server_host.zig");
const tool_delivery = @import("tool_delivery.zig");
const tool_result = @import("tool_result.zig");

/// The Host pieces an ActionAttempt needs. executionMain builds one value per
/// execution loop and hands it to every tool that runs Actions.
pub const Parts = struct {
    store: *store.Store,
    lifecycle: *server_host.Lifecycle,
    probes: *server_host.Probes,
    custody: *execution.CustodyPool,
};

/// Phase names for the fences a tool's attempt can raise. Each tool supplies its own.
pub const Labels = struct {
    admission: []const u8,
    custody: []const u8,
    stop: []const u8,
    result: []const u8,
    failure: []const u8,
};

/// Only `.attempt` carries an Attempt, so nothing can settle, launch or close
/// an attempt the Store did not admit.
pub const Admission = union(enum) {
    attempt: Attempt,
    busy,
    none,
    refused,
    unattached,
};

pub const Stop = union(enum) {
    running,
    stopped: store.SupersedingControl,
    fenced,
};

/// `effect` runs the start under the launch lock; `channel` runs it bare
/// (MCP transport start), with `dispatch` sending later under the lock.
pub const Start = enum { effect, channel };

pub const Resolution = union(enum) {
    text: struct { code: store.ActionResolutionCode, text: []const u8 },
    result: struct { code: store.ActionResolutionCode, value: tool_delivery.Value, retained: *tool_result.Result },
    /// Classified as storage-full text, suppressed (nothing delivered) or uncertain (fence at `phase`).
    failure: struct { fault: result_fault.Failure, phase: []const u8 },
    /// Fence the dispatch without a delivery.
    fence: struct { phase: []const u8, fault: result_fault.Failure },
};

pub const Delivered = enum { delivered, session_stop, lost, fenced };

/// Launch failures keep their origin: `authority` is the custody check that
/// spends launch authority, `handoff` is the Store handoff or the start itself.
pub const Launch = union(enum) {
    started,
    authority: anyerror,
    handoff: anyerror,
};

/// Reserves custody, admits the Action's attempt row in the Store, and attaches
/// custody to it. Failures release the reservation and fence here.
pub fn admit(parts: Parts, call: store.ReadyAction, timeout_ms: u64, labels: Labels) Admission {
    const token = parts.custody.reserve() orelse return .busy;
    var admission = (parts.store.admitActionAttempt(call, timeout_ms, parts.probes.storeFaults(.attempt_admission)) catch |err| {
        parts.custody.releaseUnused(token) catch unreachable;
        parts.lifecycle.fenceDispatch(labels.admission, err);
        return .refused;
    }) orelse {
        parts.custody.releaseUnused(token) catch unreachable;
        return .none;
    };
    const binding = parts.custody.attach(token, &admission.permit) catch |err| {
        parts.custody.releaseUnused(token) catch unreachable;
        parts.lifecycle.fenceDispatch(labels.custody, err);
        return .unattached;
    };
    return .{ .attempt = .{ .parts = parts, .token = token, .labels = labels, .binding = binding } };
}

/// One admitted attempt. Tools read `binding` and call the verbs below; the
/// stage asserts the order the verbs must run in.
pub const Attempt = struct {
    parts: Parts,
    token: execution.CustodyToken,
    labels: Labels,
    binding: store.ActionAttemptBinding,
    stage: Stage = .admitted,

    const Stage = enum { admitted, opened, launched };

    pub fn stopped(self: *Attempt) Stop {
        const control = self.parts.store.actionSupersededByStop(self.binding) catch |err| {
            self.parts.lifecycle.fenceDispatch(self.labels.stop, err);
            return .fenced;
        };
        return if (control) |value| .{ .stopped = value } else .running;
    }

    /// Consumes launch authority, then runs `begin` under the Store handoff
    /// and, for `.effect`, the launch lock. Message watching starts after the effect.
    pub fn launch(self: *Attempt, comptime start: Start, now: std.Io.Clock.Timestamp, context: anytype, comptime begin: anytype) Launch {
        self.parts.custody.consumeLaunchAuthority(self.token, .{ .action = self.binding }, now) catch |err| return .{ .authority = err };
        self.parts.store.withActionLaunchHandoff(self.binding, .{ .attempt = self, .context = context }, struct {
            fn handoff(handoff_context: anytype, cutoff: u64) !void {
                const attempt = handoff_context.attempt;
                switch (start) {
                    .effect => try attempt.parts.lifecycle.withEffectLaunch(handoff_context.context, begin),
                    .channel => try begin(handoff_context.context),
                }
                try attempt.parts.custody.watchMessages(attempt.token, cutoff);
            }
        }.handoff) catch |err| return .{ .handoff = err };
        self.stage = switch (start) {
            .effect => .launched,
            .channel => .opened,
        };
        return .started;
    }

    /// Sends under the Store dispatch handoff and the launch lock, after a `.channel` launch.
    /// A nonblocking send may leave the request unsent, so the caller runs this again on
    /// each poll until its request is out; every run takes the handoff and the lock anew.
    pub fn dispatch(self: *Attempt, context: anytype, comptime send: anytype) !void {
        std.debug.assert(self.stage == .opened);
        try self.parts.store.withActionDispatchHandoff(self.binding, .{ .lifecycle = self.parts.lifecycle, .context = context }, struct {
            fn handoff(handoff_context: anytype) !void {
                try handoff_context.lifecycle.withEffectLaunch(handoff_context.context, send);
            }
        }.handoff);
    }

    pub fn settle(self: *Attempt, resolution: Resolution) Delivered {
        return switch (resolution) {
            .text => |text| self.deliver(text.code, .{ .text = text.text }, null, self.labels.failure),
            .result => |result| self.deliver(result.code, result.value, result.retained, self.labels.result),
            .failure => |failure| switch (result_fault.classify(failure.fault)) {
                .storage_full => self.deliver(.storage_failed, .{ .text = result_fault.storage_failed_text }, null, self.labels.failure),
                .suppressed => .lost,
                .uncertain => self.fenceAt(failure.phase, failure.fault),
                .rejected, .superseded => unreachable,
            },
            .fence => |fence| self.fenceAt(fence.phase, fence.fault),
        };
    }

    /// Detaches custody. The returned Closing frees it once the caller has
    /// released everything the attempt pointed at.
    pub fn close(self: *Attempt) Closing {
        std.debug.assert(!self.parts.custody.holdsUndeliveredAction(self.token) or !self.parts.lifecycle.launchAllowed());
        self.parts.custody.detach(self.token) catch unreachable;
        return .{ .custody = self.parts.custody, .token = self.token };
    }

    fn deliver(self: *Attempt, code: store.ActionResolutionCode, value: tool_delivery.Value, retained: ?*tool_result.Result, phase: []const u8) Delivered {
        var kept = false;
        defer if (retained) |result_value| result_value.settleRetention(kept);
        if (!self.parts.custody.claimTerminalDelivery(self.token)) return .lost;
        const settlement = tool_delivery.deliver(self.parts.store, .{ .attempt = self.binding }, code, value, self.parts.probes.storeFaults(.action_result)) catch |err| {
            return self.fenceAt(phase, .{ .store = err });
        };
        kept = settlement.attempt.kept;
        return switch (settlement.attempt.outcome) {
            .effect => .delivered,
            .session_stop => .session_stop,
        };
    }

    fn fenceAt(self: *Attempt, phase: []const u8, fault: result_fault.Failure) Delivered {
        const err = switch (fault) {
            inline else => |value| value,
        };
        self.parts.lifecycle.fenceDispatch(phase, err);
        return .fenced;
    }
};

pub const Closing = struct {
    custody: *execution.CustodyPool,
    token: execution.CustodyToken,

    /// Frees the custody record after the attempt's resources are released.
    pub fn finish(self: Closing) void {
        self.custody.cleanupComplete(self.token) catch unreachable;
    }
};

const SessionRef = @FieldType(@FieldType(store.ConfigureReply, "accepted"), "session");
const protocol = @import("protocol.zig");
const action_read = @import("action_read.zig");
const tool_record = @import("tool_record.zig");

const test_labels: Labels = .{
    .admission = "test admission",
    .custody = "test custody",
    .stop = "test stop",
    .result = "test result",
    .failure = "test failure",
};

/// A temporary Store with one admissible read_image Action, and the Host
/// pieces an Attempt needs. Parts and Host point into this value, so it is
/// opened in place and never moved.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    storage: store.Store,
    session: SessionRef,
    selected: store.ReadyAction,
    lifecycle: server_host.Lifecycle,
    probes: server_host.Probes,
    records: [2]execution.CustodyRecord,
    custody: execution.CustodyPool,
    host: server_host.Host,

    fn open(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        try store.testing.testingSqliteStore(&self.storage, &self.tmp, std.testing.io);
        var root_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const root = root_buffer[0..try self.tmp.dir.realPath(std.testing.io, &root_buffer)];
        var configure = try store.testing.completeConfiguration("attempt-config", "", root, "model-a");
        configure.configuration.tools = try .of(&.{"read_image"});
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        self.session = (try self.storage.configure(&configure, .{})).accepted.session;
        try store.testing.submitTestMessage(&self.storage, &self.tmp, "attempt-input", "attempt-message", self.session.slice(), "Read an image.");
        const model = (try self.storage.admitNextModelAttempt(.{})).?.permit.binding;
        try store.settleCallsForTesting(&self.storage, &self.tmp, model, "attempt-call", &.{.{
            .item_id = "attempt-item",
            .name = "read_image",
            .encoded_call_id = "attempt-call",
            .decoded_call_id = "attempt-call",
            .encoded_arguments = "{\\\"path\\\":\\\"image.png\\\"}",
            .decoded_arguments = "{\"path\":\"image.png\"}",
        }});
        self.selected = (try self.storage.nextAction(.read_image, .{ .free_credit = .one, .mcp_open = false })).?;
        self.records = @splat(.{});
        self.custody = .initialize(&self.records);
        self.probes = .{};
        self.lifecycle = .init(std.testing.io, undefined, false, null);
        self.host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &self.storage };
    }

    /// Stops the Host from launching, as a fence does, so an undelivered Attempt can close.
    fn fence(self: *Fixture) void {
        _ = self.lifecycle.advance(.stopping);
    }

    fn stopping(self: *const Fixture) bool {
        return self.lifecycle.stopping();
    }

    fn release(self: *Fixture, attempt: *Attempt) void {
        // Closing asserts that the Host stopped launching while the Action is undelivered.
        if (self.custody.holdsUndeliveredAction(attempt.token)) self.fence();
        attempt.close().finish();
    }

    fn parts(self: *Fixture) Parts {
        return .{ .store = &self.storage, .lifecycle = &self.lifecycle, .probes = &self.probes, .custody = &self.custody };
    }

    fn close(self: *Fixture) void {
        self.storage.close() catch unreachable;
        self.tmp.cleanup();
    }

    fn expectPending(self: *Fixture) !void {
        var read: action_read.Read = undefined;
        try self.storage.readAction(&.{ .session = self.session, .action_id = self.selected.action_id }, &read);
        try std.testing.expect(std.meta.activeTag(read.status) == .pending);
    }

    fn expectResolved(self: *Fixture, code: []const u8, text: ?[]const u8) !void {
        var read: action_read.Read = undefined;
        try self.storage.readAction(&.{ .session = self.session, .action_id = self.selected.action_id }, &read);
        try std.testing.expect(std.meta.activeTag(read.status) == .resolved);
        try std.testing.expectEqualStrings(code, read.status.resolved.resolution.code.slice());
        if (text) |expected| try std.testing.expectEqualStrings(expected, read.status.resolved.window.text.slice());
    }

    fn expectStillReady(self: *Fixture) !void {
        const again = (try self.storage.nextAction(.read_image, .{ .free_credit = .one, .mcp_open = false })).?;
        try std.testing.expectEqual(self.selected.action_id, again.action_id);
    }
};

const admit_timeout_ms = 300_000;

fn admittedAttempt(fx: *Fixture) !Attempt {
    return switch (admit(fx.parts(), fx.selected, admit_timeout_ms, test_labels)) {
        .attempt => |attempt| attempt,
        else => error.TestUnexpectedAdmission,
    };
}

test "EXR-95 an admission that yields no attempt leaves no Store effect and holds no custody, and an admitted attempt holds custody until Closing.finish" {
    const Case = enum { busy, none, refused, admitted };
    for ([_]Case{ .busy, .none, .refused, .admitted }) |case| {
        var fx: Fixture = undefined;
        try fx.open();
        defer fx.close();
        switch (case) {
            .busy => {
                // Every custody record is held, so admission stops before the Store.
                for (0..fx.records.len) |_| _ = fx.custody.reserve().?;
                try std.testing.expectEqual(std.meta.Tag(Admission).busy, std.meta.activeTag(admit(fx.parts(), fx.selected, admit_timeout_ms, test_labels)));
                try std.testing.expectEqual(fx.records.len, fx.custody.occupied());
                try fx.expectStillReady();
            },
            .none => {
                // Admitting the same selection again finds it no longer ready.
                var first = try admittedAttempt(&fx);
                try std.testing.expectEqual(std.meta.Tag(Admission).none, std.meta.activeTag(admit(fx.parts(), fx.selected, admit_timeout_ms, test_labels)));
                try std.testing.expectEqual(@as(usize, 1), fx.custody.occupied());
                _ = first.settle(.{ .text = .{ .code = .succeeded, .text = "done" } });
                fx.release(&first);
                try std.testing.expectEqual(@as(usize, 0), fx.custody.occupied());
            },
            .refused => {
                // An invalid timeout is refused before any Store write and fences dispatch.
                // A commit failure would fence the Store itself, so its later reads could not show the absence of an effect.
                try std.testing.expectEqual(std.meta.Tag(Admission).refused, std.meta.activeTag(admit(fx.parts(), fx.selected, 0, test_labels)));
                try std.testing.expectEqual(@as(usize, 0), fx.custody.occupied());
                try std.testing.expect(fx.stopping());
                try fx.expectStillReady();
            },
            .admitted => {
                var attempt = try admittedAttempt(&fx);
                try std.testing.expectEqual(fx.selected.action_id, attempt.binding.action_id);
                try std.testing.expectEqual(@as(usize, 1), fx.custody.occupied());
                try std.testing.expect(fx.custody.holdsUndeliveredAction(attempt.token));
                _ = attempt.settle(.{ .text = .{ .code = .succeeded, .text = "done" } });
                try std.testing.expect(!fx.custody.holdsUndeliveredAction(attempt.token));
                // Custody stays until Closing.finish, then the record is free and the token is spent.
                const closing = attempt.close();
                try std.testing.expectEqual(@as(usize, 1), fx.custody.occupied());
                closing.finish();
                try std.testing.expectEqual(@as(usize, 0), fx.custody.occupied());
                if (fx.custody.detach(attempt.token)) |_| return error.TestUnexpectedResult else |_| {}
            },
        }
    }
}

const Starts = struct { begun: usize = 0, fail: bool = false };

fn beginStart(starts: *Starts) !void {
    starts.begun += 1;
    if (starts.fail) return error.BeginRefused;
}

const Sender = struct { attempts: usize = 0, sent: bool = false };

/// Sends nothing on its first two calls, then sends.
fn sendOnThird(sender: *Sender) !void {
    sender.attempts += 1;
    if (sender.attempts == 3) sender.sent = true;
}

fn expectStarted(launch: Launch) !void {
    switch (launch) {
        .started => {},
        else => return error.TestUnexpectedLaunch,
    }
}

fn expectLaunchFailure(launch: Launch, want: enum { authority, handoff }, err: anyerror) !void {
    switch (launch) {
        .authority => |actual| {
            try std.testing.expectEqual(.authority, want);
            try std.testing.expectEqual(err, actual);
        },
        .handoff => |actual| {
            try std.testing.expectEqual(.handoff, want);
            try std.testing.expectEqual(err, actual);
        },
        .started => return error.TestUnexpectedLaunch,
    }
}

test "EXR-96 launch spends authority once, reports authority and handoff failures apart, and dispatch after a channel launch repeats until sent" {
    const Scenario = enum { first_launch, relaunch, gate_closed, superseded, begin_failed };
    const chosen: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 1_000 * std.time.ns_per_ms }, .clock = .awake };
    inline for ([_]Start{ .effect, .channel }) |start| {
        for ([_]Scenario{ .first_launch, .relaunch, .gate_closed, .superseded, .begin_failed }) |scenario| {
            var fx: Fixture = undefined;
            try fx.open();
            defer fx.close();
            var attempt = try admittedAttempt(&fx);
            var starts: Starts = .{ .fail = scenario == .begin_failed };
            switch (scenario) {
                .first_launch => {
                    try expectStarted(attempt.launch(start, chosen, &starts, beginStart));
                    try std.testing.expectEqual(@as(usize, 1), starts.begun);
                    if (start == .channel) {
                        // Each dispatch takes the handoff anew; the caller repeats it until the request is out.
                        var sender: Sender = .{};
                        var rounds: usize = 0;
                        while (!sender.sent) : (rounds += 1) {
                            if (rounds == 8) return error.DispatchNeverSent;
                            try attempt.dispatch(&sender, sendOnThird);
                        }
                        try std.testing.expectEqual(@as(usize, 3), sender.attempts);
                    }
                },
                .relaunch => {
                    try expectStarted(attempt.launch(start, chosen, &starts, beginStart));
                    try expectLaunchFailure(attempt.launch(start, chosen, &starts, beginStart), .authority, error.DispatchPermitConsumed);
                    try std.testing.expectEqual(@as(usize, 1), starts.begun);
                },
                .gate_closed => {
                    // A closed launch lock suppresses the effect launch; a channel start is not gated here.
                    fx.fence();
                    if (start == .effect) {
                        try expectLaunchFailure(attempt.launch(start, chosen, &starts, beginStart), .handoff, error.HostDispatchSuppressed);
                        try std.testing.expectEqual(@as(usize, 0), starts.begun);
                    } else {
                        try expectStarted(attempt.launch(start, chosen, &starts, beginStart));
                        try std.testing.expectEqual(@as(usize, 1), starts.begun);
                        // Dispatch is gated by the same lock: nothing is sent once it is closed.
                        var sender: Sender = .{};
                        if (attempt.dispatch(&sender, sendOnThird)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.HostDispatchSuppressed, err);
                        try std.testing.expectEqual(@as(usize, 0), sender.attempts);
                    }
                },
                .superseded => {
                    // A stop that lands after admission fails the Store handoff before any launch.
                    var stop = try store.testingCompleteSessionStop("attempt-stop", fx.session.slice());
                    try std.testing.expect(fx.storage.stopSession(&stop, .{}) == .accepted);
                    try expectLaunchFailure(attempt.launch(start, chosen, &starts, beginStart), .handoff, error.SupersededByControl);
                    try std.testing.expectEqual(@as(usize, 0), starts.begun);
                },
                .begin_failed => {
                    try expectLaunchFailure(attempt.launch(start, chosen, &starts, beginStart), .handoff, error.BeginRefused);
                    try std.testing.expectEqual(@as(usize, 1), starts.begun);
                },
            }
            fx.release(&attempt);
        }
    }
}

test "EXR-97 settle maps each Resolution to one Delivered outcome, and a fenced outcome fences dispatch" {
    const Case = enum { text, result, storage_full, suppressed, uncertain, fence };
    for ([_]Case{ .text, .result, .storage_full, .suppressed, .uncertain, .fence }) |case| {
        var fx: Fixture = undefined;
        try fx.open();
        defer fx.close();
        var attempt = try admittedAttempt(&fx);
        switch (case) {
            .text => {
                try std.testing.expectEqual(Delivered.delivered, attempt.settle(.{ .text = .{ .code = .succeeded, .text = "done" } }));
                try fx.expectResolved("succeeded", "done");
                // Each attempt delivers one terminal outcome; a second settlement is lost.
                try std.testing.expectEqual(Delivered.lost, attempt.settle(.{ .text = .{ .code = .succeeded, .text = "again" } }));
                try fx.expectResolved("succeeded", "done");
                try std.testing.expect(!fx.stopping());
            },
            .result => {
                const retained = try tool_result.Result.create(&fx.host, fx.selected.action_id, tool_record.Runner.read_image.resultProfile(false));
                try std.testing.expectEqual(Delivered.delivered, attempt.settle(.{ .result = .{ .code = .succeeded, .value = .{ .text = "answer" }, .retained = retained } }));
                retained.destroy();
                try fx.expectResolved("succeeded", null);
                try std.testing.expect(!fx.stopping());
            },
            .storage_full => {
                const resolution: Resolution = .{ .failure = .{ .fault = .{ .capture = error.ScratchCapacityExceeded }, .phase = "test failure" } };
                try std.testing.expectEqual(Delivered.delivered, attempt.settle(resolution));
                try fx.expectResolved("storage_failed", result_fault.storage_failed_text);
                try std.testing.expect(!fx.stopping());
            },
            .suppressed => {
                // A suppressed outcome writes nothing and leaves custody holding the undelivered Action.
                const resolution: Resolution = .{ .failure = .{ .fault = .{ .store = error.HostDispatchSuppressed }, .phase = "test failure" } };
                try std.testing.expectEqual(Delivered.lost, attempt.settle(resolution));
                try std.testing.expect(fx.custody.holdsUndeliveredAction(attempt.token));
                try fx.expectPending();
                try std.testing.expect(!fx.stopping());
            },
            .uncertain => {
                // An uncertain outcome invents no terminal result and fences dispatch.
                const resolution: Resolution = .{ .failure = .{ .fault = .{ .store = error.InputOutput }, .phase = "test failure" } };
                try std.testing.expectEqual(Delivered.fenced, attempt.settle(resolution));
                try std.testing.expect(fx.stopping());
                try std.testing.expect(fx.custody.holdsUndeliveredAction(attempt.token));
                try fx.expectPending();
            },
            .fence => {
                const resolution: Resolution = .{ .fence = .{ .phase = "test fence", .fault = .{ .store = error.InputOutput } } };
                try std.testing.expectEqual(Delivered.fenced, attempt.settle(resolution));
                try std.testing.expect(fx.stopping());
                try fx.expectPending();
            },
        }
        fx.release(&attempt);
    }
}
