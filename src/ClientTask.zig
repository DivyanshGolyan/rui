//! One joined Client borrower and one acknowledged output window, not a queue.
const std = @import("std");
const client = @import("client.zig");
const Self = @This();

pub const Run = *const fn (*anyopaque, *Self) anyerror!void;
io: std.Io = undefined,
context: *anyopaque = undefined,
run: Run = undefined,
thread: ?std.Thread = null,
cancellation: client.Cancellation = .{},
mutex: std.Io.Mutex = .init,
changed: std.Io.Condition = .init,
window: [4096]u8 = undefined,
pending: ?usize = null,
result: ?anyerror!void = null,

/// All arguments and this owner stay in final storage through join.
pub fn start(self: *Self, io: std.Io, context: *anyopaque, run: Run) !void {
    std.debug.assert(self.thread == null and self.pending == null);
    self.io = io;
    self.context = context;
    self.run = run;
    self.cancellation = .{};
    self.result = null;
    self.thread = try std.Thread.spawn(.{}, execute, .{self});
}

fn execute(self: *Self) void {
    const result = self.run(self.context, self);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.result = result;
    self.changed.broadcast(self.io);
}

pub fn requests(self: *Self) client.Requests {
    return .{ .io = self.io, .cancellation = &self.cancellation };
}

/// Worker sink. No source slice escapes feed. Stop wakes a blocked delivery.
pub fn feed(self: *Self, bytes: []const u8) !void {
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

/// UI loan remains valid through cancel/join, until acknowledge.
pub fn take(self: *Self) ?[]const u8 {
    if (self.thread == null) return if (self.pending) |count| self.window[0..count] else null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return if (self.pending) |count| self.window[0..count] else null;
}

pub fn acknowledge(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    std.debug.assert(self.pending != null);
    self.pending = null;
    self.changed.broadcast(self.io);
}

pub fn completed(self: *Self) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.result != null;
}

pub fn cancel(self: *Self) void {
    if (self.thread == null) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.cancellation.requestStop();
    self.changed.broadcast(self.io);
}

/// Reap before exposing completion, closing captures or reusing arguments.
/// A repeated join does no I/O and cannot report the result twice.
pub fn join(self: *Self) !void {
    const thread = self.thread orelse return;
    thread.join();
    self.thread = null;
    try self.result.?;
}

test "ClientTask cancelled delivery remains borrowed until acknowledged after join" {
    var task: Self = .{};
    const Worker = struct {
        fn run(_: *anyopaque, owner: *Self) !void {
            try owner.feed("original window");
        }
    };
    var context: u8 = 0;
    try task.start(std.testing.io, &context, Worker.run);
    while (task.take() == null) std.Thread.yield() catch {};
    const bytes = task.take().?;
    task.cancel();
    try std.testing.expectError(error.Cancelled, task.join());
    try task.join();
    try std.testing.expectEqualStrings("original window", bytes);
    task.acknowledge();
    try std.testing.expect(task.take() == null);
}
