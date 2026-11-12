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

/// At most the existing 4096-byte child stderr capture, owned by one run.
/// Only a failed download transfers it; successful probes retain nothing.
pub const DownloadDiagnostic = struct {
    stderr: ?[]u8 = null,

    pub fn deinit(self: *DownloadDiagnostic, allocator: std.mem.Allocator) void {
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = .{};
    }

    pub fn write(self: *const DownloadDiagnostic, writer: *std.Io.Writer) !void {
        const bytes = self.stderr orelse return;
        const trimmed = std.mem.trimEnd(u8, bytes, "\r\n");
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
        if (trimmed.len == start) return;
        var text: @import("TerminalText.zig") = .{ .mode = .line };
        try text.feed(writer, trimmed[start..]);
        try text.finish(writer);
        try writer.writeAll("\n");
    }
};

/// Curl failures are download failures, not archive validation failures.
/// Preserve stderr before unwinding so shell and restored TUI reports agree.
pub fn downloadOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, diagnostic: ?*DownloadDiagnostic) ![]u8 {
    const result = try run(allocator, io, argv, cancellation, limit);
    errdefer allocator.free(result.stdout);
    if (!result.term.success()) {
        if (diagnostic) |receipt| {
            receipt.deinit(allocator);
            receipt.stderr = result.stderr;
        } else allocator.free(result.stderr);
        return error.ReleaseDownloadFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

test "upgrade process download failure retains only the last diagnostic line for reports" {
    const allocator = std.testing.allocator;
    var diagnostic: DownloadDiagnostic = .{};
    defer diagnostic.deinit(allocator);
    try std.testing.expectError(error.ReleaseDownloadFailed, downloadOutput(allocator, std.testing.io, &.{ "sh", "-c", "printf 'earlier line\\nlast curl failure\\n' >&2; exit 22" }, null, 1024, &diagnostic));
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try diagnostic.write(&writer);
    try std.testing.expectEqualStrings("last curl failure\n", writer.buffered());
    try std.testing.expectError(error.UpgradeChildFailed, output(allocator, std.testing.io, &.{ "sh", "-c", "exit 1" }, null, 1024));
}

test "upgrade process download diagnostic handles empty CRLF and hostile terminal bytes" {
    const allocator = std.testing.allocator;
    var diagnostic: DownloadDiagnostic = .{};
    defer diagnostic.deinit(allocator);
    for ([_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "\r\n", "" },
        .{ "first\r\nlast\r\n", "last\n" },
        .{ "curl: \x1b[31m\xff\n", "curl: \\x1b[31m\\xff\n" },
    }) |case| {
        diagnostic.deinit(allocator);
        diagnostic.stderr = try allocator.dupe(u8, case[0]);
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try diagnostic.write(&writer);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
    // A later failed download replaces (and frees) the previous capture.
    try std.testing.expectError(error.ReleaseDownloadFailed, downloadOutput(allocator, std.testing.io, &.{ "sh", "-c", "printf replacement >&2; exit 1" }, null, 1024, &diagnostic));
    try std.testing.expectEqualStrings("replacement", diagnostic.stderr.?);
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
