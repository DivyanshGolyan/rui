const std = @import("std");
const HostLifecycle = @import("HostLifecycle.zig");
const restart_all = @import("host_restart_all.zig");
const release = @import("release_candidate.zig");
const stderr = @import("stderr.zig");

const input_limit = 12 * std.fs.max_path_bytes + 1024;
const event_limit = input_limit;
const Task = struct {
    home: []const u8,
    target: ?restart_all.Target = null,
    report: enum { lines, events },
};
const Event = union(enum) {
    progress: HostLifecycle.Stage,
    version: release.Version,
    entry: restart_all.Entry,
    /// Leftover sockets with no running Host, counted only (#1855).
    stale: usize,
    /// Only the live typed refusal line crosses the private pipe, never the
    /// unused backing bytes of Failure.message.
    refused: struct {
        socket: ?[]const u8 = null,
        directory: ?[]const u8 = null,
        store: ?[]const u8 = null,
        pid: ?c_int = null,
        stage: @FieldType(@FieldType(HostLifecycle.ActivationOutcome, "refused"), "stage"),
        failure_line: []const u8,
    },
    // Error sets are not JSON-decodable. Preserve cancellation semantically;
    // other global failures retain their original diagnostic in the worker.
    failure: enum { cancelled, unconfirmed },
    done,
};

fn submit(init: std.process.Init, task: Task, stdout: std.process.SpawnOptions.StdIo) !std.process.Child {
    // The coordinator speaks this build's private pipe, so it must be this
    // build even after the upgrade published another one (self_executable).
    const executable = try @import("self_executable.zig").path(init.io);
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ executable, "--host-coordinator" },
        .environ_map = init.environ_map,
        .stdin = .pipe,
        .stdout = stdout,
    });
    errdefer child.kill(init.io);
    var buffer: [2048]u8 = undefined;
    var input = child.stdin.?.writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(task, .{}, &input.interface);
    try input.flush();
    child.stdin.?.close(init.io);
    child.stdin = null;
    return child;
}

pub fn restartAll(init: std.process.Init) !void {
    var child = try submit(init, .{ .home = init.environ_map.get("HOME") orelse return error.HomeNotFound, .report = .lines }, .inherit);
    const term = try child.wait(init.io);
    if (!term.success()) return error.HostRestartFailed;
}

pub fn restart(init: std.process.Init, allocator: std.mem.Allocator, options: restart_all.Options) !restart_all.Batch {
    try @import("upgrade_process.zig").check(options.cancellation);
    var child = try submit(init, .{
        .home = options.home,
        .target = if (options.target) |target| target.* else null,
        .report = .events,
    }, .pipe);
    const received = readEvents(init.io, allocator, child.stdout.?, options.progress);
    child.stdout.?.close(init.io);
    child.stdout = null;
    var batch = received catch |err| {
        _ = try child.wait(init.io);
        return err;
    };
    errdefer batch.deinit(allocator);
    const term = try child.wait(init.io);
    if (!term.success()) batch.failure = error.HostRestartFailed;
    return batch;
}

fn readEvents(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, progress: ?HostLifecycle.Progress) !restart_all.Batch {
    var buffer: [event_limit]u8 = undefined;
    var output = file.readerStreaming(io, &buffer);
    var entries: std.ArrayList(restart_all.Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var result: restart_all.Batch = .{};
    while (try output.interface.takeDelimiter('\n')) |line| {
        const parsed = try std.json.parseFromSlice(Event, allocator, line, .{});
        defer parsed.deinit();
        switch (parsed.value) {
            .progress => |stage| if (progress) |value| value.report(value.context, stage),
            .version => |version| result.version = version,
            .stale => |count| result.stale = count,
            .failure => |failure| result.failure = switch (failure) {
                .cancelled => error.Cancelled,
                .unconfirmed => error.HostRestartFailed,
            },
            .entry => |entry| {
                if (entry.state == .observed or (entry.state == .outcome and entry.state.outcome == .refused)) return error.InvalidCoordinatorEvent;
                try receiveEntry(allocator, &entries, entry);
            },
            .refused => |refusal| {
                const failure = (try @import("start_report.zig").parseLine(allocator, refusal.failure_line)) orelse return error.InvalidCoordinatorEvent;
                try receiveEntry(allocator, &entries, .{
                    .socket = refusal.socket,
                    .directory = refusal.directory,
                    .store = refusal.store,
                    .pid = refusal.pid,
                    .state = .{ .outcome = .{ .refused = .{ .stage = refusal.stage, .failure = failure } } },
                });
            },
            .done => {
                result.entries = try entries.toOwnedSlice(allocator);
                return result;
            },
        }
    }
    return error.HostRestartFailed;
}

fn receiveEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(restart_all.Entry), entry: restart_all.Entry) !void {
    const socket = if (entry.socket) |path| try allocator.dupe(u8, path) else null;
    errdefer if (socket) |path| allocator.free(path);
    const directory = if (entry.directory) |path| try allocator.dupe(u8, path) else null;
    errdefer if (directory) |path| allocator.free(path);
    const store = if (entry.store) |path| try allocator.dupe(u8, path) else null;
    errdefer if (store) |path| allocator.free(path);
    var state = entry.state;
    if (state == .failed) state.failed.cause = try allocator.dupe(u8, state.failed.cause);
    errdefer if (state == .failed) allocator.free(state.failed.cause);
    try entries.append(allocator, .{ .socket = socket, .directory = directory, .pid = entry.pid, .store = store, .state = state });
}

// std.json preserves OS-byte slices: valid UTF-8 is text; other bytes are
// numeric arrays. Keep that existing codec, not a second hex/path protocol.
fn writeEvent(value: Event, writer: *std.Io.Writer) !void {
    var line: [@import("start_report.zig").max_line_bytes]u8 = undefined;
    var encoded = value;
    if (encoded == .entry) {
        if (encoded.entry.state == .observed) return error.InvalidCoordinatorEvent;
        if (encoded.entry.state == .outcome and encoded.entry.state.outcome == .refused) {
            const entry = encoded.entry;
            const refusal = entry.state.outcome.refused;
            encoded = .{ .refused = .{
                .socket = entry.socket,
                .directory = entry.directory,
                .store = entry.store,
                .pid = entry.pid,
                .stage = refusal.stage,
                .failure_line = @import("start_report.zig").line(&refusal.failure, &line),
            } };
        }
    }
    try std.json.Stringify.value(encoded, .{}, writer);
}

fn event(init: std.process.Init, value: Event) void {
    var buffer: [event_limit]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeEvent(value, &writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
    std.Io.File.stdout().writeStreamingAll(init.io, writer.buffered()) catch {
        stderr.diagnosticBytes(writer.buffered());
    };
}

fn progressEvent(raw: *anyopaque, stage: HostLifecycle.Stage) void {
    const init: *std.process.Init = @ptrCast(@alignCast(raw));
    event(init.*, .{ .progress = stage });
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    if (std.c.setsid() < 0) return error.HostRestartFailed;
    var buffer: [2048]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const bytes = try input.interface.allocRemaining(allocator, .limited(input_limit));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Task, allocator, bytes, .{ .max_value_len = input_limit });
    defer parsed.deinit();
    const task = parsed.value;
    if (task.report == .lines) return restart_all.run(init, allocator);
    var process_init = init;
    var batch = restart_all.restart(init, allocator, .{
        .home = task.home,
        .target = if (task.target) |*target| target else null,
        .progress = .{ .context = &process_init, .report = progressEvent },
    }) catch |err| restart_all.Batch{ .failure = err };
    defer batch.deinit(allocator);
    if (batch.version) |version| event(init, .{ .version = version });
    for (batch.entries) |entry| event(init, .{ .entry = entry });
    if (batch.stale != 0) event(init, .{ .stale = batch.stale });
    if (batch.failure) |err| {
        stderr.diagnostic("Host restart could not finish ({s})\n", .{@errorName(err)});
        event(init, .{ .failure = if (err == error.Cancelled) .cancelled else .unconfirmed });
    }
    event(init, .done);
}

fn expectRoundTrip(value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(@TypeOf(value), std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
}

fn outcomeEvent(outcome: HostLifecycle.ActivationOutcome) Event {
    return .{ .entry = .{ .socket = "/socket", .directory = "/host/\xff", .store = "/store/雪\n", .state = .{ .outcome = outcome } } };
}

test "coordinator transfers every batch outcome and progress without reduction" {
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        if (comptime std.mem.eql(u8, name, "refused")) continue;
        try expectRoundTrip(outcomeEvent(@unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload))));
    }
    inline for (std.enums.values(HostLifecycle.Stage)) |stage| {
        try expectRoundTrip(Event{ .progress = stage });
        try expectRoundTrip(outcomeEvent(.{ .failed = stage }));
        try expectRoundTrip(outcomeEvent(.{ .unconfirmed = stage }));
    }
    inline for (std.enums.values(HostLifecycle.Limitation)) |limitation| {
        try expectRoundTrip(outcomeEvent(.{ .unsupported = limitation }));
    }
    inline for (std.enums.values(HostLifecycle.TargetStep)) |step| {
        try expectRoundTrip(outcomeEvent(.{ .target_unusable = step }));
    }
    try expectRoundTrip(outcomeEvent(.{ .ready = .{ .pid = 123, .instance = @splat(42) } }));
    try expectRoundTrip(outcomeEvent(.{ .already_ready = .{ .pid = 456, .instance = @splat(17) } }));
    try expectRoundTrip(outcomeEvent(.{ .client_incompatible = 789 }));
    inline for (std.enums.values(restart_all.Stage)) |stage| {
        try expectRoundTrip(Event{ .entry = .{ .socket = "/socket", .state = .{ .failed = .{ .stage = stage, .cause = "HostSocketStoreMismatch" } } } });
    }
    try expectRoundTrip(Event{ .stale = 212 });
    try expectRoundTrip(Event{ .failure = .cancelled });
    try expectRoundTrip(Event{ .failure = .unconfirmed });
    try expectRoundTrip(Event.done);
}

test "coordinator task pins only routing target and reporting not an activation plan" {
    inline for (.{ .lines, .events }) |report| {
        try expectRoundTrip(Task{ .home = "/home/雪\n", .report = report });
        try expectRoundTrip(Task{ .home = "/home/雪\n", .target = .{ .build = "/pinned/build", .version = .{ .schema = 3, .patch = 4 } }, .report = report });
    }
}

test "coordinator events keep each failed Host's cause after the line is freed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var lines: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lines.deinit();
    for ([_]Event{
        .{ .entry = .{ .socket = "/discovery.sock", .state = .{ .failed = .{ .stage = .discovery, .cause = "HostPeerPidMismatch" } } } },
        .{ .entry = .{ .socket = "/observed.sock", .directory = "/selected-host", .store = "/store", .state = .{ .failed = .{ .stage = .observation, .cause = "ConnectionRefused" } } } },
        .done,
    }) |value| {
        try writeEvent(value, &lines.writer);
        try lines.writer.writeByte('\n');
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "events", .data = lines.written() });
    const file = try tmp.dir.openFile(io, "events", .{});
    defer file.close(io);
    var batch = try readEvents(io, std.testing.allocator, file, null);
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("HostPeerPidMismatch", batch.entries[0].state.failed.cause);
    try std.testing.expectEqualStrings("ConnectionRefused", batch.entries[1].state.failed.cause);
    try std.testing.expectEqualStrings("/selected-host", batch.entries[1].directory.?);
    try std.testing.expectEqualStrings("/store", batch.entries[1].store.?);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try batch.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Host state is unconfirmed (HostPeerPidMismatch)") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "failed at observation (ConnectionRefused)") != null);
}

test "coordinator event transport preserves OS routing bytes and typed refusals" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var lines: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lines.deinit();
    const refusal = @import("start_report.zig").Failure.init(.runtime_dir_unusable, "private runtime required");
    try writeEvent(.{ .entry = .{
        .socket = "/runtime/\xff.sock",
        .directory = "/host/\xfe",
        .store = "/database/\xfd",
        .state = .{ .outcome = .{ .refused = .{ .stage = .starting, .failure = refusal } } },
    } }, &lines.writer);
    try lines.writer.writeByte('\n');
    try writeEvent(.{ .entry = .{ .pid = 42, .state = .{ .failed = .{ .stage = .discovery, .cause = "HostServeArgumentsUnreadable" } } } }, &lines.writer);
    try lines.writer.writeByte('\n');
    try writeEvent(.done, &lines.writer);
    try lines.writer.writeByte('\n');
    try tmp.dir.writeFile(io, .{ .sub_path = "events", .data = lines.written() });
    const file = try tmp.dir.openFile(io, "events", .{});
    defer file.close(io);
    var batch = try readEvents(io, std.testing.allocator, file, null);
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/runtime/\xff.sock", batch.entries[0].socket.?);
    try std.testing.expectEqualStrings("/host/\xfe", batch.entries[0].directory.?);
    try std.testing.expectEqualStrings("/database/\xfd", batch.entries[0].store.?);
    try std.testing.expectEqual(refusal.code, batch.entries[0].state.outcome.refused.failure.code);
    try std.testing.expectEqualStrings(refusal.message.slice(), batch.entries[0].state.outcome.refused.failure.message.slice());
    try std.testing.expectEqual(@as(?c_int, 42), batch.entries[1].pid);
    try std.testing.expect(batch.entries[1].socket == null);
}

test "coordinator never transmits unused typed refusal backing bytes" {
    var failure = @import("start_report.zig").Failure.init(.settings_invalid, "safe");
    @memset(failure.message.bytes[failure.message.len..], 'X');
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeEvent(.{ .entry = .{ .directory = "/host", .state = .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = failure } } } } }, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "XXXXXXXX") == null);
}

test "coordinator refusal envelopes preserve both stages and semantic failure fields" {
    inline for (.{ .checking, .starting }) |stage| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        const failure = @import("start_report.zig").Failure.init(.settings_invalid, "typed\nrefusal");
        try writeEvent(outcomeEvent(.{ .refused = .{ .stage = stage, .failure = failure } }), &output.writer);
        const parsed = try std.json.parseFromSlice(Event, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .refused);
        try std.testing.expectEqual(stage, parsed.value.refused.stage);
        const decoded = (try @import("start_report.zig").parseLine(std.testing.allocator, parsed.value.refused.failure_line)).?;
        try std.testing.expectEqual(failure.code, decoded.code);
        try std.testing.expectEqualStrings(failure.message.slice(), decoded.message.slice());
    }
}

test "coordinator task routing preserves OS bytes through the existing JSON slice codec" {
    try expectRoundTrip(Task{ .home = "/home/\xff", .target = .{ .build = "/target/\xfe", .version = .{ .schema = 75, .patch = 1 } }, .report = .events });
}
