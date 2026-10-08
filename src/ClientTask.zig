//! One interactive execution owner, initialized in final storage with `.{}.`
//! UI calls are serialized. Only the worker calls requests/feed; it must not
//! write terminal output or mutate SessionInput. Context and io live through
//! join. Restore the terminal before cancellation/join on UI exit or failure.
const std = @import("std");
const client = @import("client.zig");
const ClientTask = @This();

pub const Run = *const fn (*anyopaque, *ClientTask) anyerror!void;
pub const Result = union(enum) { succeeded, cancelled, failed: anyerror };

io: std.Io = undefined,
context: *anyopaque = undefined,
run: Run = undefined,
thread: ?std.Thread = null,
cancellation: client.Cancellation = .{},
mutex: std.Io.Mutex = .init,
changed: std.Io.Condition = .init,
window: [4096]u8 = undefined,
pending: ?usize = null,
terminal: ?Result = null,

/// Start only after exact join of the previous worker and acknowledgement of
/// every delivery. Spawn failure leaves an idle owner with no borrowed token.
pub fn start(self: *ClientTask, io: std.Io, context: *anyopaque, run: Run) !void {
    try self.startWith(io, context, run, spawn);
}

fn spawn(self: *ClientTask) !std.Thread {
    return std.Thread.spawn(.{}, execute, .{self});
}

fn startWith(self: *ClientTask, io: std.Io, context: *anyopaque, run: Run, comptime spawn_fn: anytype) !void {
    // No worker can access these fields when idle. The UI is the sole caller.
    if (self.thread != null) return error.TaskActive;
    if (self.pending != null) return error.DeliveryPending;
    self.io = io;
    self.context = context;
    self.run = run;
    self.cancellation = .{};
    self.terminal = null;
    self.thread = try spawn_fn(self);
}

fn execute(self: *ClientTask) void {
    const outcome: Result = if (self.run(self.context, self)) |_| .succeeded else |err| if (err == error.Cancelled) .cancelled else .{ .failed = err };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.terminal = outcome;
    self.changed.broadcast(self.io);
}

pub fn requests(self: *ClientTask) client.Requests {
    return .{ .io = self.io, .cancellation = &self.cancellation };
}

/// Synchronous worker sink. Large feeds split into ordered 4-KiB windows;
/// even an empty feed is a delivery requiring acknowledgement. No input slice
/// escapes this call. Only one worker is allowed to feed this owner.
pub fn feed(self: *ClientTask, bytes: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var offset: usize = 0;
    while (true) {
        if (self.cancellation.stopped.load(.acquire)) return error.Cancelled;
        std.debug.assert(self.pending == null);
        const count = @min(bytes.len - offset, self.window.len);
        @memcpy(self.window[0..count], bytes[offset..][0..count]);
        self.pending = count;
        self.changed.broadcast(self.io);
        while (self.pending != null and !self.cancellation.stopped.load(.acquire))
            self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.cancellation.stopped.load(.acquire)) return error.Cancelled;
        offset += count;
        if (offset == bytes.len) return;
    }
}

/// UI-only borrow, valid until acknowledge, including across cancel/join.
/// Repeated take returns the same delivery, not a dequeue. Null is distinct
/// from a non-null empty slice. The worker cannot overwrite a pending window.
pub fn take(self: *ClientTask) ?[]const u8 {
    if (self.thread == null)
        return if (self.pending) |count| self.window[0..count] else null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return if (self.pending) |count| self.window[0..count] else null;
}

pub fn acknowledge(self: *ClientTask) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    std.debug.assert(self.pending != null);
    self.pending = null;
    self.changed.broadcast(self.io);
}

pub fn completed(self: *ClientTask) bool {
    return self.result() != null;
}

/// Owned terminal fact; survives join, cleared by the next start (including
/// a failed spawn). Completion does not imply that a cancelled delivery was
/// acknowledged or that the thread has been joined.
pub fn result(self: *ClientTask) ?Result {
    if (self.thread == null) return self.terminal;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.terminal;
}

pub fn cancel(self: *ClientTask) void {
    if (self.thread == null) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.cancellation.requestStop();
    self.changed.broadcast(self.io);
}

/// UI-only exact join; does not cancel automatically. Drain/ack deliveries
/// for normal success, or cancel first. Returns the worker's error after reap.
/// A cancelled pending borrow remains valid and must be acknowledged before
/// reuse. A second join is an idle no-op, not a second error observation.
pub fn join(self: *ClientTask) !void {
    const thread = self.thread orelse return;
    thread.join();
    self.thread = null;
    switch (self.terminal.?) {
        .succeeded => {},
        .cancelled => return error.Cancelled,
        .failed => |err| return err,
    }
}

// Waits are synchronization, not timing assertions. No network or Host starts.
fn waitDelivery(task: *ClientTask) []const u8 {
    task.mutex.lockUncancelable(task.io);
    defer task.mutex.unlock(task.io);
    while (task.pending == null and task.terminal == null)
        task.changed.waitUncancelable(task.io, &task.mutex);
    return task.window[0..task.pending.?];
}

test "ClientTask ordered bounded windows and empty delivery" {
    const Worker = struct {
        bytes: [8193]u8,
        fn run(raw: *anyopaque, task: *ClientTask) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try task.feed(&self.bytes);
            try task.feed("");
        }
    };
    var worker: Worker = undefined;
    for (&worker.bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var task: ClientTask = .{};
    try task.start(std.testing.io, &worker, Worker.run);
    defer {
        task.cancel();
        task.join() catch {};
    }
    try std.testing.expectError(error.TaskActive, task.start(std.testing.io, &worker, Worker.run));
    var offset: usize = 0;
    for ([_]usize{ 4096, 4096, 1, 0 }) |count| {
        const bytes = waitDelivery(&task);
        try std.testing.expectEqual(count, bytes.len);
        try std.testing.expectEqualSlices(u8, worker.bytes[offset..][0..count], bytes);
        try std.testing.expectEqual(bytes.ptr, task.take().?.ptr);
        try std.testing.expect(!task.completed());
        task.acknowledge();
        offset += count;
    }
    try task.join();
    try std.testing.expect(task.take() == null);
    try std.testing.expectEqual(Result.succeeded, task.result().?);
}

test "ClientTask cancel wakes blocked sink and preserves borrow until acknowledgement" {
    const Worker = struct {
        fn run(_: *anyopaque, task: *ClientTask) !void {
            try task.feed("held");
            return error.MustNotReach;
        }
    };
    var context: u8 = 0;
    var task: ClientTask = .{};
    try task.start(std.testing.io, &context, Worker.run);
    defer {
        task.cancel();
        task.join() catch {};
    }
    const borrow = waitDelivery(&task);
    task.cancel();
    try std.testing.expectError(error.Cancelled, task.join());
    try std.testing.expect(task.completed());
    try std.testing.expectEqual(Result.cancelled, task.result().?);
    try std.testing.expect(task.requests().cancellation.?.stopped.load(.acquire));
    try std.testing.expectEqualStrings("held", borrow);
    try std.testing.expectError(error.DeliveryPending, task.start(std.testing.io, &context, Worker.run));
    task.acknowledge();
    try std.testing.expect(task.take() == null);
    try task.join();
    try task.start(std.testing.io, &context, Worker.run);
    try std.testing.expectEqualStrings("held", waitDelivery(&task));
    try std.testing.expect(!task.completed());
    task.cancel();
    try std.testing.expectError(error.Cancelled, task.join());
    task.acknowledge();
}

test "ClientTask worker error spawn failure and reuse have no stale completion" {
    const Worker = struct {
        fn fail(_: *anyopaque, _: *ClientTask) !void {
            return error.WorkerFailed;
        }
        fn run(_: *anyopaque, task: *ClientTask) !void {
            try task.feed("new");
        }
        fn failSpawn(_: *ClientTask) !std.Thread {
            return error.SpawnFailed;
        }
    };
    var context: u8 = 0;
    var task: ClientTask = .{};
    try std.testing.expect(task.take() == null);
    try std.testing.expect(!task.completed());
    task.cancel();
    try task.join();
    try task.start(std.testing.io, &context, Worker.fail);
    try std.testing.expectError(error.WorkerFailed, task.join());
    try std.testing.expectEqual(error.WorkerFailed, task.result().?.failed);
    try std.testing.expectError(error.SpawnFailed, task.startWith(std.testing.io, &context, Worker.run, Worker.failSpawn));
    try std.testing.expect(task.thread == null);
    try std.testing.expect(!task.completed());
    try task.join();
    try task.start(std.testing.io, &context, Worker.run);
    defer {
        task.cancel();
        task.join() catch {};
    }
    try std.testing.expectEqualStrings("new", waitDelivery(&task));
    try std.testing.expect(!task.completed());
    try std.testing.expect(!task.requests().cancellation.?.stopped.load(.acquire));
    task.acknowledge();
    try task.join();
    try std.testing.expect(task.take() == null);
}
