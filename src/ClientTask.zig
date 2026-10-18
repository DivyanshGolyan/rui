//! One joined Client borrower. Its worker writes only its own context; the UI
//! reads that after join.
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
result: ?anyerror!void = null,
read_failure: ?client.ReadFailure = null,

/// All arguments and this owner stay in final storage through join.
pub fn start(self: *Self, io: std.Io, context: *anyopaque, run: Run) !void {
    std.debug.assert(self.thread == null);
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
}

pub fn requests(self: *Self) client.Requests {
    return .{ .io = self.io, .cancellation = &self.cancellation, .read_failure = &self.read_failure };
}

pub fn completed(self: *Self) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.result != null;
}

pub fn cancel(self: *Self) void {
    if (self.thread == null) return;
    self.cancellation.requestStop();
}

/// Reap before exposing completion, closing captures or reusing arguments.
/// A repeated join does no I/O and cannot report the result twice.
pub fn join(self: *Self) !void {
    const thread = self.thread orelse return;
    thread.join();
    self.thread = null;
    try self.result.?;
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
