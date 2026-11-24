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
    pub fn dispatch(self: *Attempt, context: anytype, comptime send: anytype) !void {
        std.debug.assert(self.stage == .opened);
        try self.parts.store.withActionDispatchHandoff(self.binding, .{ .lifecycle = self.parts.lifecycle, .context = context }, struct {
            fn handoff(handoff_context: anytype) !void {
                try handoff_context.lifecycle.withEffectLaunch(handoff_context.context, send);
            }
        }.handoff);
        self.stage = .launched;
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

// dispatch and the .channel start are used by MCP in a later unit. Referencing
// them here keeps them type-checked until that caller lands.
test "channel start and dispatch type-check" {
    _ = Attempt.dispatch;
    _ = Start.channel;
}
