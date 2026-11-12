//! Process custody for work which may stop the Host running its caller.
//! A fresh image in its own session, never a forked Zig continuation.
const std = @import("std");
const HostLifecycle = @import("HostLifecycle.zig");
const client = @import("client.zig");
const identity = @import("host_identity.zig");
const release = @import("release_candidate.zig");
const stderr = @import("stderr.zig");

// host_identity bounds argv/environment at 2 MiB. JSON's worst-case escaping
// needs six bytes per byte, including a second copy of argv-derived launch
// options. The remainder covers paths, facts and JSON framing. Only one task
// exists per coordinator, and its input storage is wiped before process exit.
const input_limit = 32 * 1024 * 1024;
const Activation = struct {
    observed: client.HostControlObservation,
    started: u64,
    executable: []const u8,
    argv: []const []const u8,
    environment: []const []const u8,
    launch: HostLifecycle.LaunchSpecification,
    previous_version: release.Version,
    target: []const u8,
    version: release.Version,
};
const Task = union(enum) { restart_all, activate: Activation };
const Event = union(enum) { progress: HostLifecycle.Stage, outcome: HostLifecycle.ActivationOutcome };

/// Child owns the complete task after stdin closes. No cancellation or cleanup
/// of the caller may kill it after that handoff: it may already have stopped a
/// Host. Its process group is independent even if Bash exec'd the caller.
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
    var child = try submit(init, allocator, .restart_all, .inherit);
    const term = try child.wait(init.io);
    if (!term.success()) return error.HostRestartFailed;
}

// Bounded values contain unwritten capacity. Transfer their values, never
// uninitialized/private tail bytes through generic JSON array serialization.
fn wireObservation(value: client.HostControlObservation) client.HostControlObservation {
    var result = value;
    @memset(result.facts.store.bytes[result.facts.store.len..], 0);
    if (result.facts.innodb_doublewrite) |*text| @memset(text.bytes[text.len..], 0);
    return result;
}

pub fn activate(init: std.process.Init, allocator: std.mem.Allocator, observation: *const HostLifecycle.Observation, target: []const u8, version: release.Version, cancellation: ?*const client.Cancellation, progress: ?HostLifecycle.Progress) !HostLifecycle.ActivationOutcome {
    const plan = switch (observation.*) {
        .absent => return .not_needed,
        .unsupported => |reason| return .{ .unsupported = reason },
        .managed => |*value| value,
    };
    @import("upgrade_process.zig").check(cancellation) catch return .cancelled;
    var child = try submit(init, allocator, .{ .activate = .{
        .observed = wireObservation(plan.observed),
        .started = plan.snapshot.started,
        .executable = plan.snapshot.executable,
        .argv = plan.snapshot.argv,
        .environment = plan.snapshot.environment,
        .launch = plan.launch,
        .previous_version = plan.version,
        .target = target,
        .version = version,
    } }, .pipe);
    const received = readEvents(init.io, allocator, child.stdout.?, progress);
    const term = try child.wait(init.io);
    const outcome = try received;
    return if (term.success()) outcome else .{ .unconfirmed = .starting };
}

fn readEvents(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, progress: ?HostLifecycle.Progress) !HostLifecycle.ActivationOutcome {
    var buffer: [2048]u8 = undefined;
    var output = file.readerStreaming(io, &buffer);
    var outcome: HostLifecycle.ActivationOutcome = .{ .unconfirmed = .starting };
    while (try output.interface.takeDelimiter('\n')) |line| {
        const parsed = try std.json.parseFromSlice(Event, allocator, line, .{});
        defer parsed.deinit();
        switch (parsed.value) {
            .progress => |stage| if (progress) |value| value.report(value.context, stage),
            .outcome => |value| outcome = value,
        }
    }
    return outcome;
}

fn event(init: std.process.Init, value: Event) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(value, .{}, &writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
    std.Io.File.stdout().writeStreamingAll(init.io, writer.buffered()) catch {
        // Same optional diagnostic boundary as other CLI receipts. Neither
        // a closed report pipe nor a closed stderr abandons Host activation.
        stderr.diagnosticBytes(writer.buffered());
    };
}

fn progressEvent(raw: *anyopaque, stage: HostLifecycle.Stage) void {
    const init: *std.process.Init = @ptrCast(@alignCast(raw));
    event(init.*, .{ .progress = stage });
}

/// Private CLI worker entry. No Host, Store, or runtime directory is created
/// until a complete, bounded task has been received and decoded.
pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    // Spawn inherited the caller's group: this fresh PID cannot be its leader.
    // Leave both group and session before accepting any stop authority. Unlike
    // detaching the caller in place, this also works when Bash exec'd Rui, and
    // prevents terminal job-control signals from stopping a standalone worker.
    if (std.c.setsid() < 0) return error.HostRestartFailed;
    var buffer: [2048]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const bytes = try input.interface.allocRemaining(allocator, .limited(input_limit));
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const parsed = try std.json.parseFromSlice(Task, allocator, bytes, .{ .max_value_len = input_limit });
    defer parsed.deinit();
    switch (parsed.value) {
        .restart_all => try @import("host_restart_all.zig").run(init, allocator),
        .activate => |value| {
            if (value.observed.facts.store.len > value.observed.facts.store.bytes.len) return error.InvalidArguments;
            if (value.observed.facts.innodb_doublewrite) |text| {
                if (text.len > text.bytes.len) return error.InvalidArguments;
            }
            // All slices borrow the decoded task. The parser owns their storage,
            // not Observation.deinit; no argv/environment is written to disk.
            const observation: HostLifecycle.Observation = .{ .managed = .{
                .observed = value.observed,
                .snapshot = identity.Snapshot{
                    .pid = value.observed.pid,
                    .started = value.started,
                    .executable = value.executable,
                    .argv = value.argv,
                    .environment = value.environment,
                    .storage = &.{},
                    .entries = &.{},
                },
                .launch = value.launch,
                .version = value.previous_version,
            } };
            var process_init = init;
            const outcome: HostLifecycle.ActivationOutcome = HostLifecycle.activate(init, allocator, &observation, value.target, value.version, null, .{ .context = &process_init, .report = progressEvent }) catch .{ .unconfirmed = .starting };
            event(init, .{ .outcome = outcome });
        },
    }
}

fn expectRoundTrip(value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(@TypeOf(value), std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
}

test "coordinator transfers every activation outcome and progress without reduction" {
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const outcome = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        try expectRoundTrip(Event{ .outcome = outcome });
    }
    inline for (std.enums.values(HostLifecycle.Stage)) |stage| {
        try expectRoundTrip(Event{ .progress = stage });
        try expectRoundTrip(Event{ .outcome = .{ .failed = stage } });
        try expectRoundTrip(Event{ .outcome = .{ .unconfirmed = stage } });
    }
    inline for (std.enums.values(HostLifecycle.Limitation)) |limitation| {
        try expectRoundTrip(Event{ .outcome = .{ .unsupported = limitation } });
    }
    try expectRoundTrip(Event{ .outcome = .{ .ready = .{ .pid = 123, .instance = @splat(42) } } });
    try expectRoundTrip(Event{ .outcome = .{ .already_ready = .{ .pid = 456, .instance = @splat(17) } } });
    try expectRoundTrip(Event{ .outcome = .{ .client_incompatible = 789 } });
}

test "coordinator transfers the original checked plan including private launch values" {
    var observed: client.HostControlObservation = .{
        .profile = .current,
        .pid = 123,
        .facts = .{ .store = .{ .len = 0 }, .instance = @splat(19), .active_capacity = 2, .intake_capacity = 17, .descriptor_limit = 4096, .started_at = 100, .custody_occupied = 3, .paused = true, .innodb_doublewrite = .{ .len = 0 }, .capabilities = .{ .bash = true, .providers = .{ .codex = .unserved, .openai = .unserved, .chatgpt = .unserved } } },
    };
    try observed.facts.store.set("/store/雪\n");
    try observed.facts.innodb_doublewrite.?.set("ON");
    inline for (std.enums.values(@FieldType(client.HostControlObservation, "profile"))) |profile| {
        observed.profile = profile;
        const wire = wireObservation(observed);
        for (wire.facts.store.bytes[wire.facts.store.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        var options = [_]HostLifecycle.LaunchOption{.{ .name = "provider", .value = "codex" }};
        try expectRoundTrip(Task{ .activate = .{
            .observed = wire,
            .started = 456,
            .executable = "/retained/bin/rui",
            .argv = &.{ "/retained/bin/rui", "host", "serve", "--provider", "codex" },
            .environment = &.{ "HOME=/home/fixture", "PRIVATE=雪\n\"value\\" },
            .launch = .{ .options = &options },
            .previous_version = .{ .schema = 1, .patch = 2 },
            .target = "/selected",
            .version = .{ .schema = 3, .patch = 4 },
        } });
    }
    try expectRoundTrip(Task.restart_all);
}
