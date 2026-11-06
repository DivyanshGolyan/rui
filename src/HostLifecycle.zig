const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const platform = @import("platform.zig");
const identity = @import("host_identity.zig");
const process = @import("upgrade_process.zig");
const Installation = @import("Installation.zig");
const candidate = @import("release_candidate.zig");
const cli_args = @import("cli_args.zig");
const product_defaults = @import("product_defaults.zig");

pub const Stage = enum { stopping, awaiting_retirement, starting, verifying };
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, Stage) void,

    fn send(self: ?Progress, stage: Stage) void {
        if (self) |value| value.report(value.context, stage);
    }
};

pub const Limitation = enum {
    inaccessible,
    incompatible,
    ownership_unconfirmed,
    application_owned,
    configuration_unavailable,
};

pub const LaunchOption = struct { name: []const u8, value: ?[]const u8 };
pub const LaunchSpecification = struct {
    options: []LaunchOption,

    fn deinit(self: *const LaunchSpecification, allocator: std.mem.Allocator) void {
        allocator.free(self.options);
    }
};

pub const Plan = struct {
    observed: client.ObservedHost,
    snapshot: identity.Snapshot,
    launch: LaunchSpecification,
    version: candidate.Version,
};

pub const Observation = union(enum) {
    absent,
    managed: Plan,
    unsupported: Limitation,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        if (self.* == .managed) {
            self.managed.launch.deinit(allocator);
            self.managed.snapshot.deinit(allocator);
        }
    }
};

pub const ActivationOutcome = union(enum) {
    not_needed,
    superseded,
    already_ready: struct { instance: protocol.InstanceId, pid: c_int },
    ready: struct { instance: protocol.InstanceId, pid: c_int },
    unsupported: Limitation,
    replacement_observed,
    cancelled,
    failed: Stage,
    unconfirmed: Stage,
};

pub fn observe(allocator: std.mem.Allocator, io: std.Io, home: []const u8, store: []const u8, cancellation: ?*const client.Cancellation) !Observation {
    try process.check(cancellation);
    switch (client.hostStatus(io, store)) {
        .unavailable => return .absent,
        .owned_unavailable => return .{ .unsupported = .ownership_unconfirmed },
        .incompatible => return .{ .unsupported = .incompatible },
        .access_failure => return .{ .unsupported = .inaccessible },
        .ready => {},
    }
    if (platform.mysqlRuntimeDirectory(store) != null) return .{ .unsupported = .application_owned };
    const observed = client.observeHostProcess(io, store, null) catch return .{ .unsupported = .ownership_unconfirmed };
    var snapshot = identity.snapshot(allocator, observed.pid) catch return .{ .unsupported = .configuration_unavailable };
    errdefer snapshot.deinit(allocator);
    if (!std.mem.endsWith(u8, snapshot.executable, "/bin/rui")) {
        snapshot.deinit(allocator);
        return .{ .unsupported = .application_owned };
    }
    var build = try Installation.inspectBuild(allocator, io, home, snapshot.executable[0 .. snapshot.executable.len - "/bin/rui".len], cancellation);
    defer build.deinit(allocator);
    const version = switch (build) {
        .released => |released| released.version,
        else => {
            snapshot.deinit(allocator);
            return .{ .unsupported = .application_owned };
        },
    };
    if (!restartableEnvironment(snapshot.environment)) {
        snapshot.deinit(allocator);
        return .{ .unsupported = .configuration_unavailable };
    }
    var launch = deriveLaunch(allocator, snapshot.argv) catch {
        snapshot.deinit(allocator);
        return .{ .unsupported = .configuration_unavailable };
    };
    errdefer launch.deinit(allocator);
    const confirmed = client.observeHostProcess(io, store, null) catch {
        launch.deinit(allocator);
        snapshot.deinit(allocator);
        return .{ .unsupported = .ownership_unconfirmed };
    };
    if (!sameHost(observed, confirmed)) {
        launch.deinit(allocator);
        snapshot.deinit(allocator);
        return .{ .unsupported = .ownership_unconfirmed };
    }
    return .{ .managed = .{ .observed = observed, .snapshot = snapshot, .launch = launch, .version = version } };
}

fn sameHost(a: client.ObservedHost, b: client.ObservedHost) bool {
    return a.pid == b.pid and std.mem.eql(u8, &a.ready.instance, &b.ready.instance) and std.mem.eql(u8, a.ready.store.slice(), b.ready.store.slice());
}

fn sameSnapshot(a: *const identity.Snapshot, b: *const identity.Snapshot) bool {
    if (a.pid != b.pid or a.started != b.started or !std.mem.eql(u8, a.executable, b.executable)) return false;
    for ([_][]const []const u8{ a.argv, a.environment }, [_][]const []const u8{ b.argv, b.environment }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |l, r| if (!std.mem.eql(u8, l, r)) return false;
    }
    return true;
}

fn restartableEnvironment(environment: []const []const u8) bool {
    for (environment) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
        const name = entry[0..equals];
        const value = entry[equals + 1 ..];
        if (std.mem.startsWith(u8, name, "LD_") or std.mem.startsWith(u8, name, "DYLD_")) return false;
        for ([_][]const u8{ "HOME", "TMPDIR", "RUI_CODEX_CREDENTIAL_FILE", "RUI_OPENAI_KEY_FILE", "SSL_CERT_FILE" }) |path_name| {
            if (std.mem.eql(u8, name, path_name) and value.len != 0 and !std.fs.path.isAbsolute(value)) return false;
        }
        if (std.mem.eql(u8, name, "SSL_CERT_DIR")) {
            var paths = std.mem.tokenizeScalar(u8, value, ':');
            while (paths.next()) |path| if (!std.fs.path.isAbsolute(path)) return false;
        }
    }
    return true;
}

pub fn awaitRetirement(io: std.Io, store: []const u8) !bool {
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + product_defaults.host_shutdown_seconds * std.time.ns_per_s;
    while (platform.StoreLease.observe(io, store) != .unowned) {
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining <= 0) return false;
        try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 50 * std.time.ns_per_ms))), .awake);
    }
    return true;
}

fn deriveLaunch(allocator: std.mem.Allocator, argv: []const []const u8) !LaunchSpecification {
    if (argv.len < 3 or !std.mem.eql(u8, argv[1], "host") or !std.mem.eql(u8, argv[2], "serve")) return error.UnsupportedHostConfiguration;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const grammar = comptime cli_args.Command.host_serve.definition();
    var problem: cli_args.Refusal = undefined;
    const parsed = try grammar.parseSyntax(argv[3..], scratch.allocator(), &problem);
    try parsed.validateValues(&problem);
    if (parsed.help or parsed.missing() != null or parsed.has("launch-frame")) return error.UnsupportedHostConfiguration;
    inline for (.{ "bash-path", "provider-ca-file" }) |name| {
        if (parsed.get(name)) |value| if (!std.fs.path.isAbsolute(value)) return error.UnsupportedHostConfiguration;
    }
    var options: std.ArrayList(LaunchOption) = .empty;
    errdefer options.deinit(allocator);
    for (grammar.options) |option| {
        if (option.hidden and parsed.hasNamed(option.name)) return error.UnsupportedHostConfiguration;
        if (std.mem.eql(u8, option.hex_of orelse option.name, "store") or std.mem.eql(u8, option.name, "active-capacity")) continue;
        if (option.repeated) {
            for (parsed.allNamed(option.name)) |value| try options.append(allocator, .{ .name = option.name, .value = value });
        } else if (parsed.hasNamed(option.name)) {
            try options.append(allocator, .{ .name = option.name, .value = parsed.getNamed(option.name) });
        }
    }
    return .{ .options = try options.toOwnedSlice(allocator) };
}

fn supportedByHelp(specification: *const LaunchSpecification, help: []const u8) bool {
    const first = help[0 .. std.mem.indexOfScalar(u8, help, '\n') orelse help.len];
    for (specification.options) |option| {
        var needle: [128]u8 = undefined;
        const named = std.fmt.bufPrint(&needle, "[--{s}{s}", .{ option.name, if (option.value != null) " " else "]" }) catch return false;
        if (std.mem.indexOf(u8, first, named) == null) return false;
    }
    return std.mem.indexOf(u8, first, "[--store ") != null and std.mem.indexOf(u8, first, "[--active-capacity ") != null;
}

pub fn releaseVersion(reported: []const u8) ?candidate.Version {
    if (!std.mem.startsWith(u8, reported, "rui ")) return null;
    const end = std.mem.indexOf(u8, reported[4..], " (") orelse return null;
    return candidate.Version.parse(reported[4..][0..end]) catch null;
}

pub fn activate(init: std.process.Init, allocator: std.mem.Allocator, observation: *const Observation, target: []const u8, version: candidate.Version, cancellation: ?*const client.Cancellation, progress: ?Progress) !ActivationOutcome {
    const plan = switch (observation.*) {
        .absent => return .not_needed,
        .unsupported => |reason| return .{ .unsupported = reason },
        .managed => |*value| value,
    };
    const io = init.io;
    const store = plan.observed.ready.store.slice();
    process.check(cancellation) catch return .cancelled;
    if (plan.version.order(version) == .gt) return .superseded;
    const target_executable = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{target});
    defer allocator.free(target_executable);
    const canonical_target = try std.Io.Dir.cwd().realPathFileAlloc(io, target_executable, allocator);
    defer allocator.free(canonical_target);
    if (std.mem.eql(u8, canonical_target, plan.snapshot.executable)) {
        const current = client.observeHostProcess(io, store, null) catch return .{ .unconfirmed = .verifying };
        if (!sameHost(plan.observed, current)) return .replacement_observed;
        return .{ .already_ready = .{ .instance = current.ready.instance, .pid = current.pid } };
    }
    const help = process.output(allocator, io, &.{ canonical_target, "host", "serve", "--help" }, cancellation, 32768) catch return .{ .unsupported = .configuration_unavailable };
    defer allocator.free(help);
    if (!supportedByHelp(&plan.launch, help)) return .{ .unsupported = .configuration_unavailable };
    if (client.hostLockState(io, store) != .free) {
        const current = client.observeHostProcess(io, store, null) catch return .{ .unconfirmed = .stopping };
        if (!sameHost(plan.observed, current)) return .replacement_observed;
        var fresh = identity.snapshot(allocator, current.pid) catch return .{ .unconfirmed = .stopping };
        defer fresh.deinit(allocator);
        if (!sameSnapshot(&plan.snapshot, &fresh)) return .{ .unsupported = .configuration_unavailable };
        Progress.send(progress, .stopping);
        var reply: client.ReplyBuffer = .{};
        const stopped = client.stopHost(io, .{ .store = store, .instance = plan.observed.ready.instance }, &reply) catch {
            if (client.hostLockState(io, store) != .free) return .{ .unconfirmed = .stopping };
            return startPinned(init, allocator, plan, target, version, progress);
        };
        switch (stopped) {
            .instance_changed => return .replacement_observed,
            .unavailable => if (client.hostLockState(io, store) != .free) return .{ .unconfirmed = .stopping },
            .acknowledged => {},
        }
        Progress.send(progress, .awaiting_retirement);
        if (!try awaitRetirement(io, store)) {
            switch (client.hostStatus(io, store)) {
                .ready => |ready| if (!std.mem.eql(u8, &ready.instance, &plan.observed.ready.instance)) return .replacement_observed,
                else => {},
            }
            return .{ .unconfirmed = .awaiting_retirement };
        }
    }
    return startPinned(init, allocator, plan, target, version, progress);
}

extern "c" fn rui_launch_pinned(helper: [*:0]const u8, executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, envp: [*:null]const ?[*:0]const u8, startup_read: *c_int, launched_pid: *c_int, launched_started: *c_ulonglong) c_int;

fn startPinned(init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, target: []const u8, version: candidate.Version, progress: ?Progress) !ActivationOutcome {
    const io = init.io;
    const store = plan.observed.ready.store.slice();
    if (client.hostLockState(io, store) != .free) return .replacement_observed;
    const executable = try std.fmt.allocPrintSentinel(allocator, "{s}/bin/rui", .{target}, 0);
    defer allocator.free(executable);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, executable, allocator);
    defer allocator.free(canonical);
    const helper = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(helper);
    var arguments: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (arguments.items) |arg| allocator.free(arg);
        arguments.deinit(allocator);
    }
    try arguments.append(allocator, try allocator.dupeSentinel(u8, executable, 0));
    try arguments.append(allocator, try allocator.dupeSentinel(u8, "host", 0));
    try arguments.append(allocator, try allocator.dupeSentinel(u8, "serve", 0));
    for (plan.launch.options) |option| {
        try arguments.append(allocator, try std.fmt.allocPrintSentinel(allocator, "--{s}", .{option.name}, 0));
        if (option.value) |value| try arguments.append(allocator, try allocator.dupeSentinel(u8, value, 0));
    }
    for ([_][]const u8{ "--store", store, "--active-capacity" }) |arg| try arguments.append(allocator, try allocator.dupeSentinel(u8, arg, 0));
    try arguments.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{d}", .{plan.observed.ready.active_capacity}, 0));
    const argv = try allocator.allocSentinel(?[*:0]const u8, arguments.items.len, null);
    defer allocator.free(argv);
    for (arguments.items, argv) |arg, *ptr| ptr.* = arg.ptr;
    const envp = try allocator.allocSentinel(?[*:0]const u8, plan.snapshot.environment.len, null);
    defer allocator.free(envp);
    var allocated: usize = 0;
    defer for (envp[0..allocated]) |entry| {
        const bytes = std.mem.span(entry.?);
        std.crypto.secureZero(u8, @constCast(bytes));
        allocator.free(bytes);
    };
    for (plan.snapshot.environment, envp) |entry, *ptr| {
        ptr.* = (try allocator.dupeSentinel(u8, entry, 0)).ptr;
        allocated += 1;
    }
    Progress.send(progress, .starting);
    var startup_read: c_int = -1;
    var launched_pid: c_int = -1;
    var launched_started: c_ulonglong = 0;
    const launched = rui_launch_pinned(helper.ptr, executable.ptr, argv.ptr, argv.len, envp.ptr, &startup_read, &launched_pid, &launched_started);
    defer if (startup_read >= 0) {
        _ = std.c.close(startup_read);
    };
    if (launched != 0 or launched_pid <= 0 or launched_started == 0) return .{ .failed = .starting };
    Progress.send(progress, .verifying);
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
    var startup: [8192]u8 = undefined;
    var used: usize = 0;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until) {
        if (used < startup.len) {
            const n = std.c.read(startup_read, startup[used..].ptr, startup.len - used);
            if (n > 0) used += @intCast(n);
            if (n == 0 and client.hostLockState(io, store) == .free) return .{ .failed = .starting };
        }
        if (client.observeHostProcess(io, store, until)) |observed| {
            if (observed.pid != launched_pid) return .replacement_observed;
            var snapshot = identity.snapshot(allocator, observed.pid) catch return .{ .unconfirmed = .verifying };
            defer snapshot.deinit(allocator);
            if (!matchesLaunch(launched_pid, launched_started, &snapshot, canonical)) return .{ .unconfirmed = .verifying };
            const reported = process.output(allocator, io, &.{ canonical, "--version" }, null, 512) catch return .{ .unconfirmed = .verifying };
            defer allocator.free(reported);
            if (releaseVersion(reported)) |actual| {
                if (actual.order(version) != .eq) return .{ .unconfirmed = .verifying };
            } else return .{ .unconfirmed = .verifying };
            if (observed.ready.active_capacity != plan.observed.ready.active_capacity) return .{ .unconfirmed = .verifying };
            return .{ .ready = .{ .instance = observed.ready.instance, .pid = observed.pid } };
        } else |_| {}
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining > 0) try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 50 * std.time.ns_per_ms))), .awake);
    }
    return .{ .unconfirmed = .verifying };
}

fn matchesLaunch(pid: c_int, started: u64, snapshot: *const identity.Snapshot, executable: []const u8) bool {
    return pid > 0 and started != 0 and snapshot.pid == pid and snapshot.started == started and std.mem.eql(u8, snapshot.executable, executable);
}

test "upgrade launch identity rejects same PID with a replacement generation" {
    const snapshot: identity.Snapshot = .{ .pid = 42, .started = 12, .executable = "/pinned/rui", .argv = &.{}, .environment = &.{}, .storage = &.{}, .entries = &.{} };
    try std.testing.expect(matchesLaunch(42, 12, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 11, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 0, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(43, 12, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 12, &snapshot, "/other/rui"));
}

test "upgrade lifecycle derives launch semantics before disruption" {
    const allocator = std.testing.allocator;
    for ([_][]const []const u8{
        &.{ "rui", "host", "serve", "--launch-frame" },
        &.{ "rui", "session", "start" },
        &.{ "rui", "host", "serve", "--test-observation-fd", "8" },
        &.{ "rui", "host", "serve", "--bash-path", "relative/bash" },
        &.{ "rui", "host", "serve", "--provider-ca-file", "relative.pem", "--provider-endpoint", "https://example.test" },
        &.{ "rui", "host", "serve", "--unknown-new-option", "value" },
    }) |args| {
        if (deriveLaunch(allocator, args)) |*result| {
            result.deinit(allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    for ([_][]const u8{ "--store", "--store-hex" }, [_][]const u8{ "/some/store", "2f736f6d652f73746f7265" }) |spelling, value| {
        var launch = try deriveLaunch(allocator, &.{ "rui", "host", "serve", spelling, value, "--active-capacity", "3", "--provider-endpoint", "--store" });
        defer launch.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), launch.options.len);
        try std.testing.expectEqualStrings("provider-endpoint", launch.options[0].name);
        try std.testing.expectEqualStrings("--store", launch.options[0].value.?);
        try std.testing.expect(supportedByHelp(&launch, "rui host serve [--store PATH] [--active-capacity N] [--provider-endpoint URL]\n"));
        try std.testing.expect(!supportedByHelp(&launch, "rui host serve [--store PATH] [--active-capacity N]\n"));
    }
    try std.testing.expect(!restartableEnvironment(&.{"SSL_CERT_FILE=relative.pem"}));
    try std.testing.expect(!restartableEnvironment(&.{"SSL_CERT_DIR=/absolute:relative"}));
    try std.testing.expect(!restartableEnvironment(&.{"DYLD_LIBRARY_PATH=/custom"}));
    try std.testing.expect(restartableEnvironment(&.{ "HOME=/home/fixture", "SSL_CERT_DIR=/one:/two", "PRIVATE=synthetic-only" }));
    try std.testing.expect(releaseVersion("rui unreleased (abc)\n") == null);
    try std.testing.expectEqual(@as(u32, 56), releaseVersion("rui 0.56.4 (abc)\n").?.schema);
}
