//! Detached custody for the shared restart-all owner. Task input contains only
//! routing and a pinned target; private launch state never crosses this boundary.
const std = @import("std");
const HostLifecycle = @import("HostLifecycle.zig");
const restart_all = @import("host_restart_all.zig");
const release = @import("release_candidate.zig");
const stderr = @import("stderr.zig");

// Two filesystem paths, including worst-case JSON escaping, plus framing.
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
    // Error sets are not JSON-decodable. Preserve cancellation semantically;
    // other global failures retain their original diagnostic in the worker.
    failure: enum { cancelled, unconfirmed },
    done,
};

fn submit(init: std.process.Init, allocator: std.mem.Allocator, task: Task, stdout: std.process.SpawnOptions.StdIo) !std.process.Child {
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    defer allocator.free(executable);
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ executable, "--host-coordinator" },
        .environ_map = init.environ_map,
        .stdin = .pipe,
        .stdout = stdout,
    });
    // Before EOF there is no stop authority. Failed submission can be reaped.
    errdefer child.kill(init.io);
    var buffer: [2048]u8 = undefined;
    var input = child.stdin.?.writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(task, .{}, &input.interface);
    try input.flush();
    child.stdin.?.close(init.io);
    child.stdin = null;
    return child;
}

pub fn restartAll(init: std.process.Init, allocator: std.mem.Allocator) !void {
    var child = try submit(init, allocator, .{ .home = init.environ_map.get("HOME") orelse return error.HomeNotFound, .report = .lines }, .inherit);
    const term = try child.wait(init.io);
    if (!term.success()) return error.HostRestartFailed;
}

/// Cancellation owns preparation up to EOF. After handoff, the worker retains
/// custody of the entire batch even if the caller (or its Host) disappears.
pub fn restart(init: std.process.Init, allocator: std.mem.Allocator, options: restart_all.Options) !restart_all.Batch {
    try @import("upgrade_process.zig").check(options.cancellation);
    var child = try submit(init, allocator, .{
        .home = options.home,
        .target = if (options.target) |target| target.* else null,
        .report = .events,
    }, .pipe);
    const received = readEvents(init.io, allocator, child.stdout.?, options.progress);
    // A failed reader must close before waiting: never strand the worker on a
    // full report pipe. Report loss is diagnostic, not loss of stop custody.
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
        for (entries.items) |entry| {
            allocator.free(entry.socket);
            if (entry.store) |store| allocator.free(store);
        }
        entries.deinit(allocator);
    }
    var result: restart_all.Batch = .{};
    while (try output.interface.takeDelimiter('\n')) |line| {
        const parsed = try std.json.parseFromSlice(Event, allocator, line, .{});
        defer parsed.deinit();
        switch (parsed.value) {
            .progress => |stage| if (progress) |value| value.report(value.context, stage),
            .version => |version| result.version = version,
            .failure => |failure| result.failure = switch (failure) {
                .cancelled => error.Cancelled,
                .unconfirmed => error.HostRestartFailed,
            },
            .entry => |entry| {
                if (entry.state == .observed) return error.HostRestartFailed;
                const socket = try allocator.dupe(u8, entry.socket);
                errdefer allocator.free(socket);
                const store = if (entry.store) |path| try allocator.dupe(u8, path) else null;
                errdefer if (store) |path| allocator.free(path);
                try entries.append(allocator, .{ .socket = socket, .store = store, .state = entry.state });
            },
            .done => {
                result.entries = try entries.toOwnedSlice(allocator);
                return result;
            },
        }
    }
    return error.HostRestartFailed;
}

fn event(init: std.process.Init, value: Event) void {
    var buffer: [event_limit]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(value, .{}, &writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
    std.Io.File.stdout().writeStreamingAll(init.io, writer.buffered()) catch {
        // Neither a closed report pipe nor closed stderr abandons later Hosts.
        stderr.diagnosticBytes(writer.buffered());
    };
}

fn progressEvent(raw: *anyopaque, stage: HostLifecycle.Stage) void {
    const init: *std.process.Init = @ptrCast(@alignCast(raw));
    event(init.*, .{ .progress = stage });
}

/// Private CLI entry. No Host is stopped until the complete task is accepted.
pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    // A fresh PID cannot lead the inherited group. Leave both session and group
    // before accepting stop authority, including when Bash exec'd the caller.
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
    return .{ .entry = .{ .socket = "/socket", .store = "/store/雪\n", .state = .{ .outcome = outcome } } };
}

test "coordinator transfers every batch outcome and progress without reduction" {
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
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
    try expectRoundTrip(outcomeEvent(.{ .ready = .{ .pid = 123, .instance = @splat(42) } }));
    try expectRoundTrip(outcomeEvent(.{ .already_ready = .{ .pid = 456, .instance = @splat(17) } }));
    try expectRoundTrip(outcomeEvent(.{ .client_incompatible = 789 }));
    inline for (std.enums.values(restart_all.Failure)) |failure| {
        try expectRoundTrip(Event{ .entry = .{ .socket = "/socket", .state = .{ .failed = failure } } });
    }
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
