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
read_failure: ?client.ReadFailure = null,

/// All arguments and this owner stay in final storage through join.
pub fn start(self: *Self, io: std.Io, context: *anyopaque, run: Run) !void {
    std.debug.assert(self.thread == null and self.pending == null);
    self.io = io;
    self.context = context;
    self.run = run;
    self.cancellation = .{};
    self.result = null;
    self.read_failure = null;
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
    return .{ .io = self.io, .cancellation = &self.cancellation, .read_failure = &self.read_failure };
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

test "ClientTask read diagnostic survives join with isolated borrowers and resets on reuse" {
    const Worker = struct {
        fn run(raw: *anyopaque, owner: *Self) !void {
            const code: *[]const u8 = @ptrCast(@alignCast(raw));
            if (code.*.len == 0) return;
            var failure: client.ReadFailure = .{ .status = 503, .diagnostic = .{ .type = .{}, .code = .{} } };
            try failure.diagnostic.type.set("busy");
            try failure.diagnostic.code.set(code.*);
            const borrower = owner.requests();
            try std.testing.expectEqual(error.HostInvocationFailed, borrower.failRead(failure));
            failure.status = 500;
            try failure.diagnostic.code.set("canonical_store_failure");
            return borrower.failRead(failure);
        }
    };
    var first: Self = .{};
    var second: Self = .{};
    var first_code: []const u8 = "classification_capacity_exhausted";
    var second_code: []const u8 = "other\x1b\n";
    try first.start(std.testing.io, @ptrCast(&first_code), Worker.run);
    try second.start(std.testing.io, @ptrCast(&second_code), Worker.run);
    try std.testing.expectError(error.CanonicalStoreFailure, first.join());
    try std.testing.expectError(error.CanonicalStoreFailure, second.join());
    var bytes: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try first.read_failure.?.writeDiagnostic(&out);
    try std.testing.expectEqualStrings("HTTP 503; type: busy; code: classification_capacity_exhausted", out.buffered());
    out = std.Io.Writer.fixed(&bytes);
    try second.read_failure.?.writeDiagnostic(&out);
    try std.testing.expectEqualStrings("HTTP 503; type: busy; code: other\\x1b\\n", out.buffered());
    first_code = "";
    try first.start(std.testing.io, @ptrCast(&first_code), Worker.run);
    try first.join();
    try std.testing.expect(first.read_failure == null);
    try std.testing.expectEqualStrings(second_code, second.read_failure.?.diagnostic.code.slice());
}
