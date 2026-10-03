const std = @import("std");
const client = @import("client.zig");
const Self = @This();

/// One scoped read borrower. Construct in final storage; cancel, restore the
/// terminal, and join before releasing any argument, result or content loan.
cancellation: client.Cancellation = .{},
thread: ?std.Thread = null,
done: std.atomic.Value(bool) = .init(false),
window: []const u8 = &.{},
custody: std.atomic.Value(Custody) = .init(.empty),

const Custody = enum(u8) { empty, offered, borrowed };
// glibc places the executable's static TLS in each pthread allocation. Zig's
// configured alternate signal stack is TLS too, in safety/debug builds.
pub const stack_bytes = 256 * 1024 + (std.options.signal_stack_size orelse 0);

pub fn requests(self: *Self) client.Requests {
    return .{ .io = std.Io.Threaded.global_single_threaded.io(), .cancellation = &self.cancellation };
}

pub fn Job(comptime function: anytype, comptime Args: type) type {
    const Result = @TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ @as(Args, undefined)));
    return struct {
        args: Args,
        result: Result = undefined,

        pub fn run(self: *@This(), lane: *Self) void {
            self.result = @call(.auto, function, .{lane.requests()} ++ self.args);
            lane.done.store(true, .release);
        }
    };
}

pub fn start(self: *Self, job: anytype) !void {
    std.debug.assert(self.thread == null and self.custody.load(.acquire) == .empty);
    self.cancellation = .{};
    self.done.store(false, .release);
    self.thread = try std.Thread.spawn(.{ .stack_size = stack_bytes }, @TypeOf(job.*).run, .{ job, self });
}

pub fn stop(self: *Self) void {
    self.cancellation.requestStop();
}

pub fn join(self: *Self) void {
    std.debug.assert(self.custody.load(.acquire) != .borrowed);
    if (self.thread) |thread| thread.join();
    self.thread = null;
}

/// The slice borrows the producer's existing <=4-KiB read buffer. Cancellation
/// may withdraw an unclaimed offer, but cannot revoke a loan in renderer.feed.
pub fn feed(self: *Self, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try self.cancellation.check();
        const end = @min(bytes.len, offset + 4096);
        std.debug.assert(self.custody.load(.acquire) == .empty);
        self.window = bytes[offset..end];
        self.custody.store(.offered, .release);
        while (self.custody.load(.acquire) != .empty) {
            if (self.cancellation.stopped.load(.acquire)) {
                if (self.custody.cmpxchgStrong(.offered, .empty, .acq_rel, .acquire) == null) return error.Cancelled;
                // An acquired loan remains valid until the consumer unwinds.
            }
            std.Io.sleep(self.requests().io, .fromMilliseconds(1), .awake) catch unreachable;
        }
        offset = end;
    }
    try self.cancellation.check();
}

pub fn borrow(self: *Self) ?[]const u8 {
    if (self.custody.cmpxchgStrong(.offered, .borrowed, .acq_rel, .acquire) != null) return null;
    return self.window;
}

pub fn release(self: *Self) void {
    std.debug.assert(self.custody.load(.acquire) == .borrowed);
    self.custody.store(.empty, .release);
}

test "FrontendRead streams exact bounded loans without staging complete content" {
    const Source = struct {
        fn send(_: client.Requests, lane: *Self, bytes: []const u8) !void {
            try lane.feed(bytes);
        }
    };
    var bytes: [9001]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var lane: Self = .{};
    var job: Job(Source.send, std.meta.Tuple(&.{ *Self, []const u8 })) = .{ .args = .{ &lane, &bytes } };
    try lane.start(&job);
    defer {
        lane.stop();
        lane.join();
    }
    var offset: usize = 0;
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 2000000000;
    while (!lane.done.load(.acquire)) {
        if (lane.borrow()) |window| {
            defer lane.release();
            try std.testing.expect(window.len <= 4096);
            try std.testing.expectEqual(@intFromPtr(bytes[offset..].ptr), @intFromPtr(window.ptr));
            try std.testing.expectEqualSlices(u8, bytes[offset..][0..window.len], window);
            offset += window.len;
        }
        try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try job.result;
    try std.testing.expectEqual(bytes.len, offset);
}

test "FrontendRead cancellation withdraws offers but retains acquired loan until release" {
    const Source = struct {
        fn send(_: client.Requests, lane: *Self) !void {
            var bytes = [_]u8{ 3, 7, 11 };
            try lane.feed(&bytes);
            @memset(&bytes, 0);
        }
    };
    for ([_]bool{ false, true }) |acquire| {
        var lane: Self = .{};
        var job: Job(Source.send, std.meta.Tuple(&.{*Self})) = .{ .args = .{&lane} };
        try lane.start(&job);
        defer {
            lane.stop();
            lane.join();
        }
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 2000000000;
        while (lane.custody.load(.acquire) == .empty) {
            try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        const loan = if (acquire) lane.borrow().? else null;
        lane.stop();
        if (loan) |bytes| {
            defer lane.release();
            try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
            try std.testing.expect(!lane.done.load(.acquire));
            try std.testing.expectEqualSlices(u8, &.{ 3, 7, 11 }, bytes);
        }
        while (!lane.done.load(.acquire)) {
            try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectError(error.Cancelled, job.result);
        try std.testing.expectEqual(Custody.empty, lane.custody.load(.acquire));
    }
}
