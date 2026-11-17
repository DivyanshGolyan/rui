const std = @import("std");
const launch_transfer = @import("host_launch_transfer.zig");
const client = @import("client.zig");
const policy = @import("download_policy.zig");

pub fn check(cancellation: ?*const client.Cancellation) error{Cancelled}!void {
    if (cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
}

/// The existing file-held upgrade interposition, with an acknowledgement so
/// fixtures order peers by a reached transition rather than a scheduling race.
/// No gate variable means no effects. The fixture owns both temporary names.
pub fn waitForTestGate(allocator: std.mem.Allocator, io: std.Io, selected_gate: ?[]const u8, cancellation: ?*const client.Cancellation, timeout: std.Io.Duration) !void {
    const gate = selected_gate orelse return;
    try check(cancellation);
    const held = std.Io.Dir.cwd().openFile(io, gate, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    held.close(io);
    const entered = try std.fmt.allocPrint(allocator, "{s}.entered", .{gate});
    defer allocator.free(entered);
    const signal = try std.Io.Dir.cwd().createFile(io, entered, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    signal.close(io);
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = timeout, .clock = .awake });
    while (true) {
        try check(cancellation);
        const file = std.Io.Dir.cwd().openFile(io, gate, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        file.close(io);
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

pub const Result = std.process.RunResult;

/// Per-invocation context, never a mutation of the coordinator process. The
/// caller owns the map through completion (including cancellation/reaping).
pub const Context = struct {
    environ_map: ?*const std.process.Environ.Map = null,
    cwd: std.process.Child.Cwd = .inherit,
    /// Opaque checked launch frame, transported only through private stdin.
    input: ?[]const u8 = null,
};

pub fn dispose(allocator: std.mem.Allocator, result: Result) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn capture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, limit: usize, deadline: std.Io.Clock.Timestamp, context: Context, done: *std.atomic.Value(bool)) std.process.RunError!Result {
    defer done.store(true, .release);
    if (context.input) |bytes| return captureInput(allocator, io, argv, limit, deadline, context, bytes);
    return std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = context.environ_map,
        .cwd = context.cwd,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = deadline },
    });
}

fn captureInput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, limit: usize, deadline: std.Io.Clock.Timestamp, context: Context, bytes: []const u8) std.process.RunError!Result {
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = context.environ_map, .cwd = context.cwd, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    const input = child.stdin.?.handle;
    launch_transfer.nonblocking(input) catch return error.Unexpected;
    launch_transfer.nonblocking(child.stdout.?.handle) catch return error.Unexpected;
    launch_transfer.nonblocking(child.stderr.?.handle) catch return error.Unexpected;
    var delivery: launch_transfer.Transfer = .{ .input = input, .bytes = bytes };
    child.stdin = null;
    defer delivery.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    defer stderr_bytes.deinit(allocator);
    var closed = [2]bool{ false, false };
    var buffers: [2][8192]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&buffers));
    while (!closed[0] or !closed[1]) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
        const moved = delivery.step(.{}, .{
            .{ .fd = if (closed[0]) -1 else child.stdout.?.handle, .buffer = &buffers[0] },
            .{ .fd = if (closed[1]) -1 else child.stderr.?.handle, .buffer = &buffers[1] },
        }) catch return error.Unexpected;
        if (stdout.items.len + moved.counts[0] > limit or stderr_bytes.items.len + moved.counts[1] > 4096) return error.StreamTooLong;
        try stdout.appendSlice(allocator, buffers[0][0..moved.counts[0]]);
        try stderr_bytes.appendSlice(allocator, buffers[1][0..moved.counts[1]]);
        for (0..2) |i| closed[i] = closed[i] or moved.closed[i];
        if (!moved.progressed and (!closed[0] or !closed[1])) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const term = try child.wait(io);
    const captured_stdout = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(captured_stdout);
    return .{ .term = term, .stdout = captured_stdout, .stderr = try stderr_bytes.toOwnedSlice(allocator) };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize) !Result {
    return runWithTimeout(allocator, io, argv, cancellation, limit, .fromSeconds(300));
}

pub fn runWithTimeout(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, timeout: std.Io.Duration) !Result {
    return runIn(allocator, io, argv, cancellation, limit, timeout, .{});
}

pub fn runIn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, timeout: std.Io.Duration, context: Context) !Result {
    try check(cancellation);
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = timeout, .clock = .awake });
    return runUntilIn(allocator, io, argv, cancellation, limit, deadline, context);
}

fn runUntil(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, deadline: std.Io.Clock.Timestamp) !Result {
    return runUntilIn(allocator, io, argv, cancellation, limit, deadline, .{});
}

fn runUntilIn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cancellation: ?*const client.Cancellation, limit: usize, deadline: std.Io.Clock.Timestamp, context: Context) !Result {
    try check(cancellation);
    if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
    var done: std.atomic.Value(bool) = .init(false);
    var future = try io.concurrent(capture, .{ allocator, io, argv, limit, deadline, context, &done });
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

/// One upgrade run owns the working address family and its final diagnostic.
/// No family preference survives the run or changes the system resolver.
pub const Download = struct {
    family: policy.Family = .automatic,
    stderr: ?[]u8 = null,

    pub const Request = struct {
        url: []const u8,
        output: union(enum) { body, effective_url, archive: []const u8 } = .body,
    };

    pub fn deinit(self: *Download, allocator: std.mem.Allocator) void {
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = .{};
    }

    pub fn write(self: *const Download, writer: *std.Io.Writer) !void {
        const bytes = self.stderr orelse return;
        const trimmed = std.mem.trimEnd(u8, bytes, "\r\n");
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
        if (trimmed.len == start) return;
        var text: @import("TerminalText.zig") = .{ .mode = .line };
        try text.feed(writer, trimmed[start..]);
        try text.finish(writer);
        try writer.writeAll("\n");
    }

    pub fn output(self: *Download, allocator: std.mem.Allocator, io: std.Io, request: Request, cancellation: ?*const client.Cancellation, limit: usize) ![]u8 {
        return self.outputUntil(allocator, io, request, cancellation, limit, "curl", .fromNow(io, .{ .raw = .fromNanoseconds(policy.download_timeout_ns), .clock = .awake }));
    }

    fn outputUntil(self: *Download, allocator: std.mem.Allocator, io: std.Io, request: Request, cancellation: ?*const client.Cancellation, limit: usize, executable: []const u8, deadline: std.Io.Clock.Timestamp) ![]u8 {
        var family = self.family;
        while (true) {
            try check(cancellation);
            const remaining_ms = deadline.durationFromNow(io).raw.toMilliseconds();
            if (remaining_ms <= 0) return error.Timeout;
            const milliseconds: u64 = @intCast(remaining_ms);
            var time_buffer: [32]u8 = undefined;
            const max_time = try std.fmt.bufPrint(&time_buffer, "{d}.{d:0>3}", .{ milliseconds / 1000, milliseconds % 1000 });
            var connect_buffer: [16]u8 = undefined;
            const connect_time = try std.fmt.bufPrint(&connect_buffer, "{d}", .{@as(u64, @intCast(std.Io.Duration.fromNanoseconds(policy.connect_timeout_ns).toSeconds()))});
            const fixture = std.mem.startsWith(u8, request.url, "http://");
            const discovery = request.output == .effective_url;
            const common = [_][]const u8{
                executable,          "--disable",                        "--fail",        "--silent",                                       "--show-error", "--location",
                "--connect-timeout", connect_time,                       "--max-time",    max_time,                                         "--max-redirs", if (fixture and !discovery) "0" else "5",
                "--proto",           if (fixture) "=http" else "=https", "--proto-redir", if (fixture and discovery) "=http" else "=https",
            };
            var argv: [common.len + 7][]const u8 = undefined;
            argv[0..common.len].* = common;
            var count: usize = common.len;
            if (family == .ipv4) {
                argv[count] = "--ipv4";
                count += 1;
            }
            switch (request.output) {
                .body => {},
                .effective_url => {
                    argv[count..][0..4].* = .{ "--output", "/dev/null", "--write-out", "%{url_effective}" };
                    count += 4;
                },
                .archive => |path| {
                    argv[count..][0..4].* = .{ "--max-filesize", "268435456", "--output", path };
                    count += 4;
                },
            }
            argv[count..][0..2].* = .{ "--", request.url };
            count += 2;
            const result = try runUntil(allocator, io, argv[0..count], cancellation, limit, deadline);
            if (result.term.success()) {
                self.family = family;
                if (self.stderr) |bytes| allocator.free(bytes);
                self.stderr = null;
                allocator.free(result.stderr);
                return result.stdout;
            }
            const exit_code: ?u8 = switch (result.term) {
                .exited => |code| code,
                else => null,
            };
            if (policy.retry(family, exit_code, deadline.durationFromNow(io).raw.nanoseconds)) {
                dispose(allocator, result);
                family = .ipv4;
                continue;
            }
            allocator.free(result.stdout);
            if (self.stderr) |bytes| allocator.free(bytes);
            self.stderr = result.stderr;
            return error.ReleaseDownloadFailed;
        }
    }
};

pub fn downloadOutput(allocator: std.mem.Allocator, io: std.Io, request: Download.Request, cancellation: ?*const client.Cancellation, limit: usize, download: ?*Download) ![]u8 {
    var local: Download = .{};
    defer local.deinit(allocator);
    return (download orelse &local).output(allocator, io, request, cancellation, limit);
}

fn downloadFixture(allocator: std.mem.Allocator, script: []const u8, download: *Download) ![]u8 {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "curl", .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
    const executable = try temporary.dir.realPathFileAlloc(io, "curl", allocator);
    defer allocator.free(executable);
    return download.outputUntil(allocator, io, .{ .url = "https://fixture.invalid" }, null, 1024, executable, .fromNow(io, .{ .raw = .fromNanoseconds(policy.download_timeout_ns), .clock = .awake }));
}

test "upgrade process download failure retains only the last diagnostic line for reports" {
    const allocator = std.testing.allocator;
    var diagnostic: Download = .{};
    defer diagnostic.deinit(allocator);
    try std.testing.expectError(error.ReleaseDownloadFailed, downloadFixture(allocator, "#!/bin/sh\nprintf 'earlier line\\nlast curl failure\\n' >&2; exit 22\n", &diagnostic));
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try diagnostic.write(&writer);
    try std.testing.expectEqualStrings("last curl failure\n", writer.buffered());
    try std.testing.expectError(error.UpgradeChildFailed, output(allocator, std.testing.io, &.{ "sh", "-c", "exit 1" }, null, 1024));
}

test "upgrade process download diagnostic handles empty CRLF and hostile terminal bytes" {
    const allocator = std.testing.allocator;
    var diagnostic: Download = .{};
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
    try std.testing.expectError(error.ReleaseDownloadFailed, downloadFixture(allocator, "#!/bin/sh\nprintf replacement >&2; exit 1\n", &diagnostic));
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

test "upgrade process context is scoped to one invocation and closes stdin" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("RUI_CONTEXT_TEST", "captured\xff");
    const result = try runIn(gpa, std.testing.io, &.{ "/bin/sh", "-c", "printf '%s:' \"$RUI_CONTEXT_TEST\"; pwd; if read line; then exit 9; fi" }, null, 1024, .fromSeconds(5), .{ .environ_map = &env, .cwd = .{ .path = "/" } });
    defer dispose(gpa, result);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("captured\xff:/\n", result.stdout);
}

test "upgrade process download retry shares its deadline and retains IPv4 only for its run" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "curl", .data =
        \\#!/bin/sh
        \\family=automatic
        \\while [ "$#" -gt 0 ]; do
        \\  case "$1" in
        \\    --ipv4) family=ipv4 ;;
        \\    --max-time) shift; budget=$1 ;;
        \\  esac
        \\  shift
        \\done
        \\printf '%s %s\n' "$family" "$budget" >> "$0.log"
        \\if [ "$family" = automatic ]; then sleep 0.02; exit 6; fi
        \\printf recovered
    , .flags = .{ .permissions = .fromMode(0o700) } });
    const executable = try temporary.dir.realPathFileAlloc(io, "curl", allocator);
    defer allocator.free(executable);
    var download: Download = .{};
    defer download.deinit(allocator);
    for (0..2) |_| {
        const bytes = try download.outputUntil(allocator, io, .{ .url = "https://fixture.invalid" }, null, 1024, executable, .fromNow(io, .{ .raw = .fromSeconds(11), .clock = .awake }));
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings("recovered", bytes);
        try std.testing.expectEqual(policy.Family.ipv4, download.family);
    }
    const log = try temporary.dir.readFileAlloc(io, "curl.log", allocator, .limited(1024));
    defer allocator.free(log);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, first, "automatic "));
    try std.testing.expect(std.mem.startsWith(u8, second, "ipv4 "));
    const first_budget = try std.fmt.parseFloat(f64, first["automatic ".len..]);
    const second_budget = try std.fmt.parseFloat(f64, second["ipv4 ".len..]);
    try std.testing.expect(second_budget < first_budget);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "ipv4 "));
    try std.testing.expect(lines.next() == null);
}

test "upgrade process download with no connection budget or exhausted deadline never retries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(executable);
    const script_path = try std.fmt.allocPrint(allocator, "{s}/curl", .{executable});
    defer allocator.free(script_path);
    var download: Download = .{};
    defer download.deinit(allocator);
    for ([_]struct { script: []const u8, failure: anyerror }{
        .{ .script = "#!/bin/sh\nprintf attempt >> \"$0.log\"\nprintf 'connection timeout' >&2\nexit 28\n", .failure = error.ReleaseDownloadFailed },
        .{ .script = "#!/bin/sh\nprintf attempt >> \"$0.log\"\nprintf partial-body\nexec sleep 300\n", .failure = error.Timeout },
    }) |case| {
        try temporary.dir.writeFile(io, .{ .sub_path = "curl", .data = case.script, .flags = .{ .permissions = .fromMode(0o700) } });
        try std.testing.expectError(case.failure, download.outputUntil(allocator, io, .{ .url = "https://fixture.invalid" }, null, 1024, script_path, .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake })));
        const log = try temporary.dir.readFileAlloc(io, "curl.log", allocator, .limited(1024));
        defer allocator.free(log);
        try std.testing.expectEqualStrings("attempt", log);
        try temporary.dir.deleteFile(io, "curl.log");
    }
}

test "upgrade process download cancellation and expired deadline start no child" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var download: Download = .{};
    defer download.deinit(allocator);
    var cancellation: client.Cancellation = .{};
    cancellation.requestStop();
    const request: Download.Request = .{ .url = "https://fixture.invalid" };
    const missing = "/nonexistent/rui-download-child";
    try std.testing.expectError(error.Cancelled, download.outputUntil(allocator, io, request, &cancellation, 1024, missing, .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake })));
    try std.testing.expectError(error.Timeout, download.outputUntil(allocator, io, request, null, 1024, missing, .fromNow(io, .{ .raw = .fromSeconds(-1), .clock = .awake })));
}

test "upgrade test gate is opt-in, acknowledges only held gates and bounds cancellation and timeout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const gate = try std.fmt.allocPrint(allocator, "{s}/held", .{directory});
    defer allocator.free(gate);
    const entered = try std.fmt.allocPrint(allocator, "{s}.entered", .{gate});
    defer allocator.free(entered);
    var token: client.Cancellation = .{};
    token.requestStop();
    // Unset gate is inert, even for an already cancelled caller.
    try waitForTestGate(allocator, io, null, &token, .fromSeconds(0));
    // A released/absent gate creates no acknowledgement.
    try waitForTestGate(allocator, io, gate, null, .fromSeconds(0));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, entered, .{}));
    const file = try std.Io.Dir.cwd().createFile(io, gate, .{});
    file.close(io);
    try std.testing.expectError(error.Cancelled, waitForTestGate(allocator, io, gate, &token, .fromSeconds(0)));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, entered, .{}));
    try std.testing.expectError(error.Timeout, waitForTestGate(allocator, io, gate, null, .fromSeconds(0)));
    _ = try std.Io.Dir.cwd().statFile(io, entered, .{});
    // The held input still belongs to the fixture, including on timeout.
    _ = try std.Io.Dir.cwd().statFile(io, gate, .{});
}
