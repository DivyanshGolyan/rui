const std = @import("std");
const HostLifecycle = @import("HostLifecycle.zig");
const restart_all = @import("host_restart_all.zig");
const release = @import("release_candidate.zig");
const stderr = @import("stderr.zig");
const activation = @import("host_activation.zig");
const caller_error = @import("caller_error.zig");

const input_limit = 12 * std.fs.max_path_bytes + 1024;
const event_limit = input_limit;
const Task = struct {
    home: []const u8,
    target: ?restart_all.Target = null,
    report: enum { lines, events, single },
    directory: ?[]const u8 = null,
};
const Event = union(enum) {
    progress: HostLifecycle.Stage,
    version: release.Version,
    entry: restart_all.Entry,
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
    single_ineligible,
    single_fault: struct { effect: activation.EffectTag, cause: []const u8, code: caller_error.Code },
    single_failure: struct { cause: []const u8, code: caller_error.Code },
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

/// Complete an ordinary-start handover in a detached coordinator.
pub fn activateOlderHostForStart(init: std.process.Init, directory: []const u8) !?activation.Execution {
    var child = try submit(init, .{ .home = "", .directory = directory, .report = .single }, .pipe);
    const received = readSingle(init.io, init.gpa, child.stdout.?);
    child.stdout.?.close(init.io);
    child.stdout = null;
    const term = try waitResult(child.wait(init.io));
    return settleSingle(received, term);
}

fn settleSingle(received: anyerror!?activation.Execution, term: std.process.Child.Term) !?activation.Execution {
    if (!term.success()) return error.HostRestartUnconfirmed;
    return received catch return error.HostRestartUnconfirmed;
}

fn readSingle(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !?activation.Execution {
    var buffer: [event_limit]u8 = undefined;
    var input = file.readerStreaming(io, &buffer);
    const bytes = try input.interface.allocRemaining(allocator, .limited(event_limit));
    defer allocator.free(bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.InvalidCoordinatorEvent;
    const parsed = try std.json.parseFromSlice(Event, allocator, bytes[0 .. bytes.len - 1], .{});
    defer parsed.deinit();
    return switch (parsed.value) {
        .single_ineligible => null,
        .entry => |entry| if (entry.socket != null or entry.directory != null or entry.store != null or entry.pid != null or entry.state != .outcome or entry.state.outcome == .refused)
            error.InvalidCoordinatorEvent
        else
            .{ .outcome = entry.state.outcome },
        .refused => |refusal| result: {
            if (refusal.socket != null or refusal.directory != null or refusal.store != null or refusal.pid != null) return error.InvalidCoordinatorEvent;
            const failure = (try @import("start_report.zig").parseLine(allocator, refusal.failure_line)) orelse return error.InvalidCoordinatorEvent;
            break :result .{ .outcome = .{ .refused = .{ .stage = refusal.stage, .failure = failure } } };
        },
        .single_fault => |fault| result: {
            if (fault.effect == .done or fault.cause.len == 0) return error.InvalidCoordinatorEvent;
            const failure: activation.RemoteFailure = .{ .cause = try @import("bounded.zig").Bounded(256).from(fault.cause), .code = fault.code };
            break :result .{ .remote_fault = .{ .effect = fault.effect, .failure = failure } };
        },
        .single_failure => |failure| result: {
            if (failure.cause.len == 0) return error.InvalidCoordinatorEvent;
            break :result .{ .remote_failure = .{ .cause = try @import("bounded.zig").Bounded(256).from(failure.cause), .code = failure.code } };
        },
        else => error.InvalidCoordinatorEvent,
    };
}

pub fn restartAll(init: std.process.Init) !void {
    var child = try submit(init, .{ .home = init.environ_map.get("HOME") orelse return error.HomeNotFound, .report = .lines }, .inherit);
    const term = try waitResult(child.wait(init.io));
    lineResult(term) catch |err| {
        if (err == error.HostRestartUnconfirmed) switch (term) {
            .exited => |code| if (code != @backingInt(@import("caller_exit.zig").Status.unconfirmed)) stderr.diagnostic("Host coordinator exited with status {d}; Host state is unconfirmed.\n", .{code}),
            else => stderr.diagnostic("Host coordinator terminated unexpectedly; Host state is unconfirmed.\n", .{}),
        };
        return err;
    };
}

fn waitResult(result: anyerror!std.process.Child.Term) !std.process.Child.Term {
    return waitResultTo(result, null);
}

fn waitResultTo(result: anyerror!std.process.Child.Term, output: ?*std.Io.Writer) !std.process.Child.Term {
    return result catch |err| {
        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "\nHost coordinator wait failed ({s}); Host state is unconfirmed.\n", .{@errorName(err)}) catch return error.HostRestartUnconfirmed;
        if (output) |writer| writer.writeAll(message) catch {} else stderr.diagnosticBytes(message);
        return error.HostRestartUnconfirmed;
    };
}

fn lineResult(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| switch (code) {
            0 => return,
            @backingInt(@import("caller_exit.zig").Status.environment) => return error.HostRestartFailed,
            else => return error.HostRestartUnconfirmed,
        },
        else => return error.HostRestartUnconfirmed,
    }
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
        _ = waitResult(child.wait(init.io)) catch {};
        stderr.diagnostic("Host coordinator result could not be read ({s}); Host state is unconfirmed.\n", .{@errorName(err)});
        return error.HostRestartUnconfirmed;
    };
    errdefer batch.deinit(allocator);
    const term = try waitResult(child.wait(init.io));
    if (!term.success()) batch.failure = error.HostRestartUnconfirmed;
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
            .failure => |failure| result.failure = switch (failure) {
                .cancelled => error.Cancelled,
                .unconfirmed => error.HostRestartUnconfirmed,
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
            .single_ineligible, .single_fault, .single_failure => return error.InvalidCoordinatorEvent,
            .done => {
                result.entries = try entries.toOwnedSlice(allocator);
                return result;
            },
        }
    }
    return error.HostRestartUnconfirmed;
}

fn receiveEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(restart_all.Entry), entry: restart_all.Entry) !void {
    const socket = if (entry.socket) |path| try allocator.dupe(u8, path) else null;
    errdefer if (socket) |path| allocator.free(path);
    const directory = if (entry.directory) |path| try allocator.dupe(u8, path) else null;
    errdefer if (directory) |path| allocator.free(path);
    const store = if (entry.store) |path| try allocator.dupe(u8, path) else null;
    errdefer if (store) |path| allocator.free(path);
    var state = entry.state;
    if (state == .failed) {
        state.failed.cause = try allocator.dupe(u8, state.failed.cause);
        state.failed.cause_owned = true;
    }
    errdefer if (state == .failed) allocator.free(state.failed.cause);
    if (state == .fault) {
        state.fault.cause = try allocator.dupe(u8, state.fault.cause);
        state.fault.cause_owned = true;
    }
    errdefer if (state == .fault) allocator.free(state.fault.cause);
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

// Single-Store activation emits nothing until its last effect has settled.
fn singleEvent(init: std.process.Init, value: Event) void {
    var buffer: [event_limit]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeEvent(value, &writer) catch return;
    writer.writeByte('\n') catch return;
    const ignored: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &ignored, &previous);
    defer std.posix.sigaction(.PIPE, &previous, null);
    std.Io.File.stdout().writeStreamingAll(init.io, writer.buffered()) catch {};
}

fn singleTask(init: std.process.Init, task: Task, activate: *const fn (std.process.Init, []const u8) anyerror!?activation.Execution) void {
    const directory = task.directory orelse return;
    const execution = activate(init, directory) catch |err| {
        singleEvent(init, .{ .single_failure = .{ .cause = @errorName(err), .code = caller_error.of(err) } });
        return;
    } orelse {
        singleEvent(init, .single_ineligible);
        return;
    };
    switch (execution) {
        .outcome => |outcome| singleEvent(init, .{ .entry = .{ .state = .{ .outcome = outcome } } }),
        .fault => |fault| singleEvent(init, .{ .single_fault = .{ .effect = fault.effect, .cause = @errorName(fault.cause), .code = caller_error.of(fault.cause) } }),
        .remote_fault => |fault| singleEvent(init, .{ .single_fault = .{ .effect = fault.effect, .cause = fault.failure.cause.slice(), .code = fault.failure.code } }),
        .remote_failure => |failure| singleEvent(init, .{ .single_failure = .{ .cause = failure.cause.slice(), .code = failure.code } }),
    }
}

fn progressEvent(raw: *anyopaque, stage: HostLifecycle.Stage) void {
    const init: *std.process.Init = @ptrCast(@alignCast(raw));
    event(init.*, .{ .progress = stage });
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    return runWith(init, allocator, restart_all.activateOlderHostForStart);
}

pub fn runWith(init: std.process.Init, allocator: std.mem.Allocator, activate: *const fn (std.process.Init, []const u8) anyerror!?activation.Execution) !void {
    if (std.c.setsid() < 0) return error.HostRestartFailed;
    var buffer: [2048]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const bytes = try input.interface.allocRemaining(allocator, .limited(input_limit));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Task, allocator, bytes, .{ .max_value_len = input_limit });
    defer parsed.deinit();
    const task = parsed.value;
    if (task.report == .single) return singleTask(init, task, activate);
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

test "SH-128 coordinator retains lifecycle faults and later Host outcomes" {
    for (std.meta.tags(@import("host_activation.zig").EffectTag)) |effect| {
        if (effect == .done) continue;
        try expectRoundTrip(Event{ .entry = .{ .directory = "/host", .state = .{ .fault = .{ .effect = effect, .cause = "OutOfMemory" } } } });
    }
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var lines: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lines.deinit();
    for ([_]Event{
        .{ .entry = .{ .directory = "/first", .state = .{ .fault = .{ .effect = .resolve_target, .cause = "OutOfMemory" } } } },
        .{ .entry = .{ .directory = "/second", .state = .{ .fault = .{ .effect = .await_retirement, .cause = "ConnectionResetByPeer" } } } },
        .{ .entry = .{ .directory = "/third", .state = .{ .outcome = .not_needed } } },
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
    try std.testing.expectEqual(@as(usize, 3), batch.entries.len);
    try std.testing.expectEqual(.resolve_target, batch.entries[0].state.fault.effect);
    try std.testing.expectEqualStrings("OutOfMemory", batch.entries[0].state.fault.cause);
    try std.testing.expectEqual(.resolve_target, batch.selectedOutcome("/first").pre_stop_failed);
    try std.testing.expectEqual(.await_retirement, batch.entries[1].state.fault.effect);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", batch.entries[1].state.fault.cause);
    try std.testing.expectEqual(.awaiting_retirement, batch.selectedOutcome("/second").unconfirmed);
    try std.testing.expectEqual(.not_needed, batch.entries[2].state.outcome);
    try std.testing.expectError(error.HostRestartUnconfirmed, batch.result());
}

test "SH-130 coordinator exit preserves certainty across the child boundary" {
    var buffer: [1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try waitResultTo(.{ .exited = 0 }, &output));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectError(error.HostRestartUnconfirmed, waitResultTo(error.AccessDenied, &output));
    try std.testing.expectEqualStrings("\nHost coordinator wait failed (AccessDenied); Host state is unconfirmed.\n", output.buffered());
    try lineResult(.{ .exited = 0 });
    try std.testing.expectError(error.HostRestartFailed, lineResult(.{ .exited = @backingInt(@import("caller_exit.zig").Status.environment) }));
    try std.testing.expectError(error.HostRestartUnconfirmed, lineResult(.{ .exited = @backingInt(@import("caller_exit.zig").Status.unconfirmed) }));
    try std.testing.expectError(error.HostRestartUnconfirmed, lineResult(.{ .exited = 1 }));
    try std.testing.expectError(error.HostRestartUnconfirmed, lineResult(.{ .unknown = 0 }));
}

fn readSingleFixture(dir: std.Io.Dir, bytes: []const u8) !?activation.Execution {
    try dir.writeFile(std.testing.io, .{ .sub_path = "single-event", .data = bytes });
    const file = try dir.openFile(std.testing.io, "single-event", .{});
    defer file.close(std.testing.io);
    return readSingle(std.testing.io, std.testing.allocator, file);
}

fn roundTripSingle(dir: std.Io.Dir, value: Event) !?activation.Execution {
    var storage: [event_limit]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writeEvent(value, &writer);
    try writer.writeByte('\n');
    return readSingleFixture(dir, writer.buffered());
}

test "SH-132 single coordinator preserves every outcome and remote failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect((try roundTripSingle(tmp.dir, .single_ineligible)) == null);
    const info = @typeInfo(activation.Outcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        if (comptime std.mem.eql(u8, name, "refused")) continue;
        const outcome = @unionInit(activation.Outcome, name, std.mem.zeroes(Payload));
        const received = (try roundTripSingle(tmp.dir, .{ .entry = .{ .state = .{ .outcome = outcome } } })).?;
        try std.testing.expectEqualDeep(outcome, received.outcome);
    }
    inline for (.{ .checking, .starting }) |stage| {
        var refusal = @import("start_report.zig").Failure.init(.settings_invalid, "specific\nrefusal");
        @memset(refusal.message.bytes[refusal.message.len..], 'X');
        const received = (try roundTripSingle(tmp.dir, .{ .entry = .{ .state = .{ .outcome = .{ .refused = .{ .stage = stage, .failure = refusal } } } } })).?;
        try std.testing.expectEqual(stage, received.outcome.refused.stage);
        try std.testing.expectEqual(refusal.code, received.outcome.refused.failure.code);
        try std.testing.expectEqualStrings(refusal.message.slice(), received.outcome.refused.failure.message.slice());
    }
    for (std.meta.tags(activation.EffectTag)) |effect| {
        if (effect == .done) continue;
        const result = (try roundTripSingle(tmp.dir, .{ .single_fault = .{ .effect = effect, .cause = "UnusualRealError", .code = .internal_unexpected } })).?;
        try std.testing.expectEqual(effect, result.remote_fault.effect);
        try std.testing.expectEqualStrings("UnusualRealError", result.remote_fault.failure.cause.slice());
        try std.testing.expectEqual(caller_error.Code.internal_unexpected, result.remote_fault.failure.code);
    }
    const failure = (try roundTripSingle(tmp.dir, .{ .single_failure = .{ .cause = "AccessDenied", .code = caller_error.of(error.AccessDenied) } })).?;
    try std.testing.expectEqualStrings("AccessDenied", failure.remote_failure.cause.slice());
    try std.testing.expectEqual(caller_error.of(error.AccessDenied), failure.remote_failure.code);
}

test "SH-132 single coordinator rejects missing truncated oversized or invalid responses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "",                                                                                                   "not json\n",                                                            "\"single_ineligible\"",                                                 "\"done\"\n", "\"single_ineligible\"\n\"done\"\n",
        "{\"single_fault\":{\"effect\":\"done\",\"cause\":\"OutOfMemory\",\"code\":\"memory_exhausted\"}}\n", "{\"single_failure\":{\"cause\":\"\",\"code\":\"memory_exhausted\"}}\n", "{\"single_failure\":{\"cause\":\"Oops\",\"code\":\"invalid_code\"}}\n",
    }) |bytes| try std.testing.expectError(error.HostRestartUnconfirmed, settleSingle(readSingleFixture(tmp.dir, bytes), .{ .exited = 0 }));
    const oversized = try std.testing.allocator.alloc(u8, event_limit + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.StreamTooLong, readSingleFixture(tmp.dir, oversized));
    try std.testing.expectError(error.HostRestartUnconfirmed, settleSingle(error.AccessDenied, .{ .exited = 0 }));
    try std.testing.expectError(error.HostRestartUnconfirmed, settleSingle(null, .{ .exited = 1 }));
    try std.testing.expect((try settleSingle(null, .{ .exited = 0 })) == null);
    try std.testing.expectError(error.InvalidCoordinatorEvent, roundTripSingle(tmp.dir, .{ .refused = .{ .stage = .checking, .failure_line = "bad" } }));
    const long_cause: [257]u8 = @splat('x');
    try std.testing.expectError(error.ValueTooLong, roundTripSingle(tmp.dir, .{ .single_failure = .{ .cause = &long_cause, .code = .internal_unexpected } }));
}
