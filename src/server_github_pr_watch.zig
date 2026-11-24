const std = @import("std");
const server_host = @import("server_host.zig");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store.Store,
    lifecycle: *server_host.Lifecycle,
    probes: *server_host.Probes,
    github_environment: ?*const std.process.Environ.Map,
};
const store = @import("store.zig");
const attempt = @import("action_attempt.zig");
const descriptor = @import("github_pr_watch_descriptor.zig");
const watch = @import("github_pr_watch.zig");
const transport = @import("github_transport.zig");
const fetch = @import("github_observation_fetch.zig");
const delivery = @import("github_watch_delivery.zig");
const pause = @import("testing/pause.zig");
const pressure = @import("github_watch_pressure.zig");
const signal_stack = @import("signal_stack.zig");

pub const capacity = 8;
const labels: attempt.Labels = .{ .admission = "watch admission", .custody = "watch custody", .stop = "watch stop", .result = "watch result", .failure = "watch failure" };

const Active = struct {
    action: attempt.Attempt,
    input: store.ActionExecutionInput = undefined,
    approved: descriptor.Descriptor = undefined,
    io: std.Io,
    allocator: std.mem.Allocator,
    lifecycle: *server_host.Lifecycle,
    environment: ?*const std.process.Environ.Map,
    deadline: std.Io.Clock.Timestamp,
    origin: ?[]const u8 = null,
    probes: *server_host.Probes,
    cancel: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    pending: ?watch.Reduction = null,
    pending_skipped: bool = false,
    done: bool = false,
    outcome: delivery.Outcome = .network_failure,
    retry_at: ?i64 = null,
    discovery: [transport.max_accounts * (transport.max_login_bytes + 3) + 64]u8 = undefined,
    discovery_len: usize = 0,
    thread: ?std.Thread = null,
    delivery: delivery.Delivery = .{},
    cache: pressure.Cache = .{},
    budget: fetch.Budget = undefined,
    next_publish_ms: i64 = 0,
    stopping: ?store.ActionResolutionCode = null,
    test_gate: enum { none, dropped, replayed, values_filled, backlog_full } = .none,
    test_gate_work: ?u64 = null,
    test_fill_remaining: u8 = 0,
    test_fill_enabled: bool = false,

    fn finish(self: *Active, result: delivery.Outcome) void {
        self.mutex.lockUncancelable(self.io);
        self.outcome = result;
        self.done = true;
        self.mutex.unlock(self.io);
        self.lifecycle.wakeDispatch();
    }
    fn run(self: *Active) void {
        self.work() catch |err| self.finish(switch (err) {
            error.Cancelled => .cancelled,
            error.Timeout => .deadline_expired,
            error.GhUnavailable => .gh_unavailable,
            error.GhFailed, error.InvalidToken => .account_unavailable,
            error.AuthenticationFailed, error.IdentityMismatch => .revoked,
            error.AccessDenied => .pr_inaccessible,
            else => .network_failure,
        });
    }
    fn work(self: *Active) !void {
        switch (self.approved) {
            .discovery_failed => |failure| {
                self.finish(switch (failure.reason) {
                    .gh_unavailable => .gh_unavailable,
                    .account_discovery_failed => .account_discovery_failed,
                });
                return;
            },
            .discover_accounts => {
                const environment = self.environment orelse return error.GhUnavailable;
                var accounts = transport.discover(self.allocator, self.io, environment, self.deadline, &self.cancel) catch |err| {
                    self.finish(switch (err) {
                        error.GhUnavailable => .gh_unavailable,
                        error.Cancelled => .cancelled,
                        error.Timeout => .deadline_expired,
                        else => .account_discovery_failed,
                    });
                    return;
                };
                defer accounts.deinit(self.allocator);
                var out: std.Io.Writer = .fixed(&self.discovery);
                if (accounts.names.len == 0) {
                    try out.writeAll("{\"outcome\":\"auth_required\",\"host\":\"github.com\"}");
                } else {
                    try out.writeAll("{\"outcome\":\"account_required\",\"host\":\"github.com\",\"usernames\":[");
                    for (accounts.names, 0..) |name, i| {
                        if (i != 0) try out.writeByte(',');
                        try out.print("\"{s}\"", .{name});
                    }
                    try out.writeAll("]}");
                }
                self.discovery_len = out.end;
                self.finish(.auth_required);
            },
            .watch => |*bound| {
                const environment = self.environment orelse return error.GhUnavailable;
                const pr = try watch.parseUrl(bound.url.slice());
                var secret = try transport.token(self.allocator, self.io, environment, bound.login.slice(), self.deadline, &self.cancel);
                defer secret.deinit(self.allocator);
                var previous: ?watch.Snapshot = null;
                var failures: u8 = 0;
                while (!self.cancel.load(.acquire)) {
                    if (self.deadline.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout;
                    const now: i64 = @intCast(std.Io.Clock.real.now(self.io).toSeconds());
                    const request_deadline = earlier(self.deadline, std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromMilliseconds(30_000), .clock = .awake }));
                    var retry_at: ?i64 = null;
                    var observed = (if (comptime pause.enabled) blk: {
                        if (self.origin) |origin| break :blk fetch.fetchForTest(self.allocator, self.io, &secret, bound.login.slice(), pr, now, request_deadline, &self.cancel, origin, &self.cache, &self.budget, &retry_at);
                        break :blk fetch.fetch(self.allocator, self.io, &secret, bound.login.slice(), pr, now, request_deadline, &self.cancel, &self.cache, &self.budget, &retry_at);
                    } else fetch.fetch(self.allocator, self.io, &secret, bound.login.slice(), pr, now, request_deadline, &self.cancel, &self.cache, &self.budget, &retry_at)) catch |err| {
                        switch (err) {
                            error.AuthenticationFailed, error.IdentityMismatch, error.AccessDenied, error.Cancelled => return err,
                            else => {},
                        }
                        if (err == error.RequestBudgetExhausted) {
                            try self.wait(40_000 + self.action.binding.action_id % 10_000);
                            continue;
                        }
                        failures +|= 1;
                        self.mutex.lockUncancelable(self.io);
                        self.retry_at = retry_at;
                        self.mutex.unlock(self.io);
                        if (failures >= 5) {
                            if (err == error.RateLimited) {
                                self.finish(.rate_limited);
                                return;
                            }
                            return error.NetworkFailure;
                        }
                        if (self.deadline.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout;
                        const fresh: i64 = @intCast(std.Io.Clock.real.now(self.io).toSeconds());
                        const seconds: i64 = if (retry_at) |r| @max(1, @min(3600, r - fresh)) else @as(i64, 1) << @intCast(failures);
                        const jitter = (self.action.binding.action_id *% 1103515245 +% @as(u64, failures) *% 12345) % 1000;
                        try self.wait(@as(u64, @intCast(seconds * 1000)) + jitter);
                        continue;
                    };
                    const reduced = watch.reduce(previous, observed.observation) catch |err| {
                        observed.deinit(self.allocator);
                        return err;
                    };
                    observed.deinit(self.allocator);
                    previous = reduced.snapshot;
                    failures = 0;
                    self.mutex.lockUncancelable(self.io);
                    if (self.pending) |prior| {
                        const before = prior.snapshot;
                        const after = reduced.snapshot;
                        if (!std.mem.eql(u8, &before.head, &after.head) or before.lifecycle != after.lifecycle or before.checks != after.checks or before.reviews != after.reviews) self.pending_skipped = true;
                    }
                    self.pending = reduced;
                    self.retry_at = null;
                    self.mutex.unlock(self.io);
                    self.lifecycle.wakeDispatch();
                    try self.probes.reachCancelable(.watch_after_observation, .{ .operation = self.action.binding.parent_operation_id, .action = self.action.binding.action_id, .attempt = @import("attempt.zig").action_attempt_ordinal }, &self.cancel);
                    switch (reduced.snapshot.lifecycle) {
                        .closed => {
                            self.finish(.closed);
                            return;
                        },
                        .merged => {
                            self.finish(.merged);
                            return;
                        },
                        else => {},
                    }
                    if (self.origin == null) try self.wait(60_000 + self.action.binding.action_id % 5000);
                }
                return error.Cancelled;
            },
        }
    }
    fn wait(self: *Active, milliseconds: u64) !void {
        var left = milliseconds;
        while (left > 0) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            if (self.deadline.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout;
            const step = @min(left, 100);
            try std.Io.sleep(self.io, .fromMilliseconds(@intCast(step)), .awake);
            left -= step;
        }
    }
};
fn earlier(a: std.Io.Clock.Timestamp, b: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    return if (a.raw.nanoseconds < b.raw.nanoseconds) a else b;
}
fn start(active: *Active) !void {
    active.thread = try signal_stack.spawn(.{}, Active.run, .{active});
}

pub const Calls = struct {
    entries: [capacity * 2]?*Active = @splat(null),
    budget: ?pressure.Budget = null,
    selection_cursor: store.GithubPrWatchCursor = .{},
    selection_rescan: @import("execution_turn.zig").WatchRescan = .{},
    next_test_work: u64 = 1,
    pub fn any(self: *const Calls) bool {
        for (self.entries) |e| if (e != null) {
            return true;
        };
        return false;
    }
    pub fn contains(self: *const Calls, id: u64) bool {
        for (self.entries) |e| if (e) |a| {
            if (a.action.binding.action_id == id) return true;
        };
        return false;
    }
    pub fn admit(self: *Calls, host: Context, parts: attempt.Parts, call: store.ReadyAction) @import("execution_turn.zig").Admission {
        const entry = for (&self.entries) |*e| {
            if (e.* == null) break e;
        } else return .retry_later;
        if (self.budget == null) self.budget = pressure.Budget.init(host.io);
        const env = host.github_environment;
        const admitted_at = std.Io.Clock.Timestamp.now(host.io, .awake);
        const active = host.allocator.create(Active) catch return .retry_later;
        active.* = .{ .action = undefined, .io = host.io, .allocator = std.heap.page_allocator, .lifecycle = host.lifecycle, .probes = host.probes, .environment = env, .deadline = admitted_at.addDuration(.{ .raw = .fromMilliseconds(3_600_000), .clock = .awake }) };
        active.budget = .{ .context = &self.budget.?, .acquire = pressure.Budget.acquireOpaque };
        active.action = switch (attempt.admit(parts, call, 3_600_000, labels)) {
            .attempt => |a| a,
            .busy, .refused => {
                host.allocator.destroy(active);
                return .retry_later;
            },
            .none, .unattached => {
                host.allocator.destroy(active);
                return .admitted;
            },
        };
        self.prepare(host, active, parts) catch |err| {
            if (active.thread) |thread| {
                cancel(active);
                thread.join();
                active.thread = null;
            }
            if (host.store.isFenced()) {
                _ = active.action.settle(.{ .fence = .{ .phase = "watch preparation", .fault = .{ .store = err } } });
            } else if (err == error.SupersededByControl) {
                _ = active.action.settle(.{ .text = .{ .code = .cancelled, .text = "{\"outcome\":\"cancelled\"}" } });
            } else if (err != error.HostDispatchSuppressed) {
                _ = active.action.settle(.{ .text = .{ .code = .failed, .text = "{\"outcome\":\"watch_start_failed\"}" } });
            }
            destroy(host, active);
            return .admitted;
        };
        if (active.thread == null) {
            destroy(host, active);
            return .admitted;
        }
        entry.* = active;
        return .admitted;
    }
    fn prepare(self: *Calls, host: Context, active: *Active, parts: attempt.Parts) !void {
        try host.store.readActionExecutionInput(.github_pr_watch, active.action.binding, &active.input);
        var bytes: [2048]u8 = undefined;
        const length = std.math.cast(usize, active.input.arguments.length) orelse return error.InvalidDescriptor;
        if (length > bytes.len) return error.InvalidDescriptor;
        var reader: store.ContentReader = undefined;
        reader.open(try host.store.openContent(active.input.arguments));
        defer reader.close();
        var offset: usize = 0;
        while (offset < length) {
            const n = try reader.read(offset, bytes[offset..length]);
            if (n == 0) return error.ShortCanonicalRead;
            offset += n;
        }
        active.approved = try descriptor.decodeDescriptor(host.allocator, bytes[0..length]);
        if (active.approved == .watch) {
            if (parts.custody.records.len <= 1) {
                settleCapacity(active);
                return;
            }
            for (self.entries) |entry| if (entry) |other| {
                if (other.approved == .watch and std.mem.eql(u8, active.input.session.slice(), other.input.session.slice())) {
                    settleCapacity(active);
                    return;
                }
            };
            if (self.count() >= @min(capacity, parts.custody.records.len - 1)) {
                settleCapacity(active);
                return;
            }
        }
        const now = std.Io.Clock.Timestamp.now(host.io, .awake);
        active.origin = host.probes.githubFixtureOrigin();
        switch (active.action.launch(.effect, now, active, start)) {
            .started => {},
            .authority, .handoff => |err| return err,
        }
    }
    fn count(self: *const Calls) usize {
        var n: usize = 0;
        for (self.entries) |e| if (e) |active| {
            if (active.approved == .watch) n += 1;
        };
        return n;
    }
    pub fn service(self: *Calls, host: Context) bool {
        var progress = false;
        for (&self.entries) |*entry| if (entry.*) |active| {
            if (active.stopping == null) switch (active.action.stopped()) {
                .fenced => {
                    cancel(active);
                },
                .stopped => {
                    active.stopping = .cancelled;
                    cancel(active);
                },
                .running => if (deadlineDue(host, active)) {
                    active.stopping = .timed_out;
                    cancel(active);
                },
            };
            active.mutex.lockUncancelable(host.io);
            const pending = active.pending;
            const skipped = active.pending_skipped;
            active.pending = null;
            active.pending_skipped = false;
            const done = active.done;
            const outcome = active.outcome;
            active.mutex.unlock(host.io);
            if (pending) |value| {
                active.delivery.observe(value);
                if (skipped) active.delivery.skipped = true;
                progress = true;
            }
            if (active.stopping == null) {
                if (comptime pause.enabled) {
                    if (active.origin != null and active.probes.takeWatchValueFill(active.action.binding.action_id)) {
                        active.test_fill_enabled = true;
                        active.test_fill_remaining = 32;
                    }
                    if (!self.testGateReady(host, active)) continue;
                    if (active.test_fill_remaining > 0) {
                        if (fillTestValue(host, active)) progress = true;
                        continue;
                    }
                }
                publish(host, active);
                if (comptime pause.enabled) if (active.test_gate != .none) continue;
            }
            if (!done) continue;
            active.thread.?.join();
            active.thread = null;
            var buffer: [2048]u8 = undefined;
            const final_outcome: delivery.Outcome = if (active.stopping) |s| if (s == .cancelled) .cancelled else .deadline_expired else outcome;
            const text = if (active.discovery_len != 0 and active.stopping == null) active.discovery[0..active.discovery_len] else delivery.encodeEnd(&active.delivery, final_outcome, active.retry_at, &buffer) catch "{\"outcome\":\"network_failure\"}";
            const code: store.ActionResolutionCode = active.stopping orelse switch (outcome) {
                .closed, .merged, .auth_required => .succeeded,
                .deadline_expired => .timed_out,
                .cancelled => .cancelled,
                else => .failed,
            };
            _ = active.action.settle(.{ .text = .{ .code = code, .text = text } });
            destroy(host, active);
            entry.* = null;
            progress = true;
        };
        return progress;
    }
    fn testGateReady(self: *Calls, host: Context, active: *Active) bool {
        const gate = active.test_gate;
        if (gate == .none) return true;
        const id = active.action.binding.action_id;
        const point: pause.Point = switch (gate) {
            .none => unreachable,
            .dropped => .watch_receipt_dropped,
            .replayed => .watch_receipt_replayed,
            .values_filled => .watch_values_filled,
            .backlog_full => .watch_backlog_full,
        };
        if (active.test_gate_work == null) {
            active.test_gate_work = self.next_test_work;
            self.next_test_work += 1;
        }
        const wake: pause.Wake = .{ .context = host.lifecycle, .call = struct {
            fn call(context: *anyopaque, _: u64) void {
                const lifecycle: *@import("server_host.zig").Lifecycle = @ptrCast(@alignCast(context));
                lifecycle.wakeDispatch();
            }
        }.call };
        const result = active.probes.pollWatchGate(active.test_gate_work.?, point, .{ .operation = active.action.binding.parent_operation_id, .action = id, .attempt = @import("attempt.zig").action_attempt_ordinal }, wake) catch return false;
        if (result == .pending) return false;
        active.test_gate = .none;
        active.test_gate_work = null;
        return true;
    }
    pub fn cancelAll(self: *Calls) void {
        for (self.entries) |entry| if (entry) |active| cancel(active);
    }
    pub fn shutdown(self: *Calls, host: Context) void {
        for (&self.entries) |*entry| if (entry.*) |active| {
            cancel(active);
            if (active.thread) |thread| thread.join();
            destroy(host, active);
            entry.* = null;
        };
    }
};
fn fillTestValue(host: Context, active: *Active) bool {
    const number = 33 - @as(u32, active.test_fill_remaining);
    var key: [32]u8 = undefined;
    var payload: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&key, "fixture-fill-{d}", .{number}) catch unreachable;
    const text = std.fmt.bufPrint(&payload, "{{\"fixture\":true,\"ordinal\":{d}}}", .{number}) catch unreachable;
    const result = host.store.publishHostActionValue(active.action.binding, name, text) catch |err| {
        _ = active.action.settle(.{ .fence = .{ .phase = "watch fixture publication", .fault = .{ .store = err } } });
        cancel(active);
        return false;
    };
    switch (result) {
        .accepted => {
            active.test_fill_remaining -= 1;
            if (active.test_fill_remaining == 0) active.test_gate = .values_filled;
            return true;
        },
        .refused => |reason| switch (reason) {
            .not_background, .backlog_full => return false,
            .stopped, .resolved => { cancel(active); return false; },
            else => {
                _ = active.action.settle(.{ .fence = .{ .phase = "watch fixture publication", .fault = .{ .store = error.InvalidWatchPublication } } });
                cancel(active);
                return false;
            },
        },
    }
}
fn deadlineDue(host: Context, active: *Active) bool {
    if (active.deadline.durationFromNow(host.io).raw.nanoseconds <= 0) return true;
    if (active.probes.watchActionExpired(active.action.binding.action_id)) return true;
    return false;
}
fn settleCapacity(active: *Active) void {
    var buffer: [512]u8 = undefined;
    const text = delivery.encodeEnd(&active.delivery, .capacity_exceeded, null, &buffer) catch unreachable;
    _ = active.action.settle(.{ .text = .{ .code = .failed, .text = text } });
}
fn publish(host: Context, active: *Active) void {
    const now = store.readUnixMilliseconds(host.io) catch return;
    if (active.origin == null and now < active.next_publish_ms) return;
    const value = active.delivery.candidate() orelse return;
    var bytes: [2048]u8 = undefined;
    const text = delivery.encodeValue(value, &bytes) catch return;
    var key_buffer: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{d}", .{value.sequence}) catch unreachable;
    const result = host.store.publishHostActionValue(active.action.binding, key, text) catch |err| {
        _ = active.action.settle(.{ .fence = .{ .phase = "watch publication", .fault = .{ .store = err } } });
        cancel(active);
        return;
    };
    switch (result) {
        .accepted => |receipt| {
            if (active.probes.takeDroppedWatchReceipt(active.action.binding.action_id)) {
                active.test_gate = .dropped;
                return;
            }
            active.delivery.acceptedValue();
            if (comptime pause.enabled) if (receipt.replayed) { active.test_gate = .replayed; };
            active.next_publish_ms = now + 1000;
        },
        .refused => |reason| switch (reason) {
            .not_background, .backlog_full => {
                active.delivery.refusedValue();
                active.next_publish_ms = now + 1000;
                if (comptime pause.enabled) if (reason == .backlog_full and active.test_fill_enabled) {
                    active.test_gate = .backlog_full;
                };
            },
            .stopped, .resolved => cancel(active),
            else => {
                _ = active.action.settle(.{ .fence = .{ .phase = "watch publication", .fault = .{ .store = error.InvalidWatchPublication } } });
                cancel(active);
            },
        },
    }
}
fn cancel(active: *Active) void {
    active.cancel.store(true, .release);
    active.probes.notifyCancellation();
}
fn destroy(host: Context, active: *Active) void {
    const closing = active.action.close();
    active.cache.deinit(active.allocator);
    host.allocator.destroy(active);
    closing.finish();
}
