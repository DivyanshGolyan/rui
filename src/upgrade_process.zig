const std = @import("std");
const client = @import("client.zig");

pub fn check(cancellation: ?*const client.Cancellation) error{Cancelled}!void {
    if (cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
}

pub const Result = std.process.RunResult;

pub fn dispose(allocator: std.mem.Allocator, result: Result) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn capture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, limit: usize, deadline: std.Io.Clock.Timestamp, done: *std.atomic.Value(bool)) std.process.RunError!Result {
    defer done.store(true, .release);
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = deadline },
    });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize) !Result {
    return runWithTimeout(allocator, io, argv, cancellation, limit, .fromSeconds(300));
}

pub fn runWithTimeout(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, timeout: std.Io.Duration) !Result {
    try check(cancellation);
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = timeout, .clock = .awake });
    var done: std.atomic.Value(bool) = .init(false);
    var future = try io.concurrent(capture, .{ allocator, io, argv, limit, deadline, &done });
    while (!done.load(.acquire)) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) {
            if (future.cancel(io)) |result| dispose(allocator, result) else |_| {}
            return error.Timeout;
        }
        check(cancellation) catch |err| {
            if (future.cancel(io)) |result| dispose(allocator, result) else |_| {}
            return err;
        };
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| {
            if (future.cancel(io)) |result| dispose(allocator, result) else |_| {}
            return err;
        };
    }
    return future.await(io);
}

pub fn output(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize) ![]u8 {
    const result = try run(allocator, io, argv, cancellation, limit);
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (!result.term.success()) return error.UpgradeChildFailed;
    return result.stdout;
}

test "upgrade process pre-cancellation starts no child" {
    var token: client.Cancellation = .{};
    token.requestStop();
    try std.testing.expectError(error.Cancelled, run(std.testing.allocator, std.testing.io, &.{"definitely-not-a-program"}, &token, 10));
}

test "upgrade process cancellation kills a child after it records readiness" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const marker = try std.fmt.allocPrint(allocator, "{s}/ready", .{directory});
    defer allocator.free(marker);
    var token: client.Cancellation = .{};
    const Worker = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        marker: []const u8,
        token: *const client.Cancellation,
        failure: ?anyerror = null,
        fn execute(self: *@This()) void {
            const result = run(self.allocator, self.io, &.{ "sh", "-c", ": > \"$1\"; exec sleep 300", "upgrade-child", self.marker }, self.token, 1024) catch |err| {
                self.failure = err;
                return;
            };
            dispose(self.allocator, result);
        }
        fn ready(self: *@This()) !bool {
            _ = std.Io.Dir.cwd().statFile(self.io, self.marker, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
    };
    var worker: Worker = .{ .allocator = allocator, .io = io, .marker = marker, .token = &token };
    {
        const thread = try std.Thread.spawn(.{}, Worker.execute, .{&worker});
        defer thread.join();
        defer token.requestStop();
        const poll = @import("test_poll");
        try poll.waitUntil(io, poll.after(io, .fromSeconds(5)), &worker, Worker.ready);
        token.requestStop();
    }
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
}

test "upgrade process deadline covers wait after child closes its output pipes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const marker = try std.fmt.allocPrint(allocator, "{s}/ready", .{directory});
    defer allocator.free(marker);
    try std.testing.expectError(error.Timeout, runWithTimeout(allocator, io, &.{ "sh", "-c", ": > \"$1\"; exec 1>&- 2>&-; exec sleep 300", "upgrade-child", marker }, null, 1024, .fromSeconds(1)));
    _ = try std.Io.Dir.cwd().statFile(io, marker, .{});
}
