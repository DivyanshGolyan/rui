const std = @import("std");
const client = @import("client.zig");
const HostLifecycle = @import("HostLifecycle.zig");
const activation = @import("host_activation.zig");
const Installation = @import("Installation.zig");
const release = @import("release_candidate.zig");
const process = @import("upgrade_process.zig");
const TerminalText = @import("TerminalText.zig");
const report = @import("host_restart_report.zig");
const Batch = report.Batch;
const Entry = report.Entry;
const Failure = report.Failure;
const Stage = report.Stage;

pub const Target = struct {
    build: []const u8,
    version: release.Version,

    pub fn init(init_process: std.process.Init, allocator: std.mem.Allocator, home: []const u8, build: ?[]const u8, cancellation: ?*const client.Cancellation) !Target {
        var selected = if (build) |path|
            try Installation.inspectBuild(allocator, init_process.io, home, path, cancellation)
        else
            try Installation.inspectCancellable(allocator, init_process.io, home, cancellation);
        errdefer selected.deinit(allocator);
        switch (selected) {
            .released => |value| return .{ .build = value.build, .version = value.version },
            .source => |path| {
                const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{path});
                defer allocator.free(binary);
                const reported = try process.output(allocator, init_process.io, &.{ binary, "--version" }, cancellation, 512);
                defer allocator.free(reported);
                const version = HostLifecycle.releaseVersion(reported) orelse return error.IneligibleInstallation;
                return .{ .build = path, .version = version };
            },
            else => return error.IneligibleInstallation,
        }
    }

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.build);
    }

    /// Whether this build is the release `expected` names.
    pub fn isRelease(self: Target, expected: release.Version) bool {
        return self.version.order(expected) == .eq;
    }
};

test "SH-125 absent Store owner is not started by handover observation" {
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", root);
    const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = &environment, .preopens = .empty };
    var batch = try restart(init, std.testing.allocator, .{ .home = root, .scope = .{ .store = root } });
    defer batch.deinit(std.testing.allocator);
    // The Store scope names exactly one Host, and the absent owner needs no lease.
    try std.testing.expectEqual(@as(usize, 1), batch.entries.len);
    try std.testing.expectEqualStrings(root, batch.entries[0].directory.?);
    try std.testing.expectEqual(std.meta.Tag(activation.Outcome).not_needed, std.meta.activeTag(batch.selectedOutcome(root)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "host.lock", .{}));
}

test "SH-125 a Store scope names only its own directory, however many other Stores exist" {
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var other = try tmp.dir.createDirPathOpen(io, "other-store", .{ .permissions = .fromMode(0o700) });
    other.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", root);
    const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = &environment, .preopens = .empty };
    var batch = try restart(init, std.testing.allocator, .{ .home = root, .scope = .{ .store = root } });
    defer batch.deinit(std.testing.allocator);
    // The Store scope names exactly one Host, and an absent owner needs no lease.
    try std.testing.expectEqual(@as(usize, 1), batch.entries.len);
    try std.testing.expectEqualStrings(root, batch.entries[0].directory.?);
    try std.testing.expectEqual(std.meta.Tag(activation.Outcome).not_needed, std.meta.activeTag(batch.selectedOutcome(root)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "host.lock", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "other-store/host.lock", .{}));
}

pub fn discover(init: std.process.Init, allocator: std.mem.Allocator, home: []const u8, cancellation: ?*const client.Cancellation) !Batch {
    const candidates = try client.discoverUpgradeHosts(allocator, init.io, cancellation);
    defer {
        for (candidates) |candidate| candidate.deinit(allocator);
        allocator.free(candidates);
    }
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    for (candidates) |candidate| {
        try process.check(cancellation);
        try entries.ensureUnusedCapacity(allocator, 1);
        var entry: Entry = .{
            .socket = if (candidate.socket) |path| try allocator.dupe(u8, path) else null,
            .pid = candidate.pid,
            .state = undefined,
        };
        errdefer {
            if (entry.socket) |path| allocator.free(path);
            if (entry.directory) |path| allocator.free(path);
            if (entry.store) |path| allocator.free(path);
        }
        entry.directory = if (candidate.directory) |path| try allocator.dupe(u8, path) else null;
        entry.state = switch (candidate.result) {
            .unanswered => unreachable,
            .failed => |err| .{ .failed = try .of(allocator, .discovery, err) },
            .observed => |facts| state: {
                entry.store = try allocator.dupe(u8, facts.facts.store.slice());
                var observation = HostLifecycle.observe(allocator, init.io, home, facts.directory(), cancellation) catch |err| break :state .{ .failed = try .of(allocator, .observation, err) };
                defer observation.deinit(allocator);
                break :state switch (observation) {
                    .absent => .{ .outcome = .not_needed },
                    .unsupported => |reason| .{ .outcome = .{ .unsupported = reason } },
                    .managed => .{ .observed = facts },
                };
            },
        };
        entries.appendAssumeCapacity(entry);
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

/// Which Hosts a restart considers. `.store` is an ordinary start's handover:
/// one Store's directory, uid-wide discovery skipped, and only a Host that
/// `startHandoverEligible` admits is activated. Any other Host stays untouched.
pub const Scope = union(enum) {
    all,
    store: []const u8,
};

pub const Options = struct {
    home: []const u8,
    target: ?*const Target = null,
    scope: Scope = .all,
    cancellation: ?*const client.Cancellation = null,
    progress: ?HostLifecycle.Progress = null,
};

pub fn restart(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Batch {
    switch (options.scope) {
        .all => {},
        .store => |directory| return restartStore(init, allocator, options, directory),
    }
    var batch = try discover(init, allocator, options.home, options.cancellation);
    errdefer batch.deinit(allocator);
    var selected: ?Target = null;
    defer if (selected) |target| target.deinit(allocator);
    if (options.target) |target| batch.version = target.version;
    for (batch.entries) |*entry| {
        if (entry.state != .observed) continue;
        const facts = entry.state.observed;
        entry.state = state: {
            process.check(options.cancellation) catch break :state .{ .outcome = .cancelled };
            var observation = HostLifecycle.observe(allocator, init.io, options.home, facts.directory(), options.cancellation) catch |err| {
                entry.state = .{ .failed = try .of(allocator, .observation, err) };
                continue;
            };
            defer observation.deinit(allocator);
            switch (observation) {
                .absent => break :state .{ .outcome = .not_needed },
                .unsupported => |reason| break :state .{ .outcome = .{ .unsupported = reason } },
                .managed => {},
            }
            if (options.target == null and selected == null) {
                selected = Target.init(init, allocator, options.home, null, options.cancellation) catch |err| {
                    entry.state = .{ .failed = try .of(allocator, .selection, err) };
                    continue;
                };
                batch.version = selected.?.version;
            }
            const target = options.target orelse &selected.?;
            const current = observation.managed.observed;
            const census: @FieldType(activation.Facts, "census") = if (current.pid != facts.pid or !std.mem.eql(u8, &current.facts.instance, &facts.facts.instance) or
                !std.mem.eql(u8, current.facts.store.slice(), entry.store.?)) .replaced else .same;
            break :state .{ .outcome = HostLifecycle.activate(init, allocator, &observation, census, target.build, target.version, options.cancellation, options.progress) };
        };
    }
    return batch;
}

/// One Store's handover: the batch holds exactly one entry, placed by its directory.
fn restartStore(init: std.process.Init, allocator: std.mem.Allocator, options: Options, directory: []const u8) !Batch {
    const entries = try allocator.alloc(Entry, 1);
    entries[0] = .{ .state = .{ .outcome = .not_needed } };
    var batch: Batch = .{ .entries = entries };
    errdefer batch.deinit(allocator);
    entries[0].directory = try allocator.dupe(u8, directory);
    entries[0].state = try storeState(init, allocator, options, directory, &batch.version);
    return batch;
}

fn storeState(init: std.process.Init, allocator: std.mem.Allocator, options: Options, directory: []const u8, version: *?release.Version) !@FieldType(Entry, "state") {
    process.check(options.cancellation) catch return .{ .outcome = .cancelled };
    var observation = HostLifecycle.observe(allocator, init.io, options.home, directory, options.cancellation) catch |err|
        return .{ .failed = try .of(allocator, .observation, err) };
    defer observation.deinit(allocator);
    switch (observation) {
        .absent => return .{ .outcome = .not_needed },
        .unsupported => |reason| return .{ .outcome = .{ .unsupported = reason } },
        .managed => {},
    }
    // An unusable installation keeps the Host as it is: the caller keeps its original report.
    var owned: ?Target = null;
    defer if (owned) |target| target.deinit(allocator);
    const target: *const Target = options.target orelse selected: {
        owned = Target.init(init, allocator, options.home, null, options.cancellation) catch |err| switch (err) {
            error.IneligibleInstallation => return .{ .outcome = .{ .target_unusable = .resolving } },
            else => return .{ .failed = try .of(allocator, .selection, err) },
        };
        break :selected &owned.?;
    };
    version.* = target.version;
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{target.build});
    defer allocator.free(binary);
    const actual = std.Io.Dir.cwd().realPathFileAlloc(init.io, binary, allocator) catch |err| return .{ .failed = try .of(allocator, .selection, err) };
    defer allocator.free(actual);
    const selected_is_self = std.mem.eql(u8, actual, try @import("self_executable.zig").path(init.io));
    if (!activation.startHandoverEligible(observation.managed.observed.foreign, observation.managed.version.order(target.version), selected_is_self)) {
        return .{ .outcome = .{ .unsupported = .not_start_eligible } };
    }
    return .{ .outcome = HostLifecycle.activate(init, allocator, &observation, .same, target.build, target.version, options.cancellation, options.progress) };
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    var batch = restart(init, allocator, .{ .home = home }) catch |err| Batch{ .failure = err };
    defer batch.deinit(allocator);
    var buffer: [2048]u8 = undefined;
    var output = report.OptionalOutput.init(init.io, .stdout(), &buffer);
    batch.write(&output.writer) catch |err| {
        batch.result() catch |result_err| if (result_err == error.HostRestartUnconfirmed) return result_err;
        return err;
    };
    output.writer.flush() catch |err| {
        batch.result() catch |result_err| if (result_err == error.HostRestartUnconfirmed) return result_err;
        return err;
    };
    try batch.result();
}
