//! Upgrade owns the transition, not Host admission or child argv. Both the
//! precondition and replacement execute the target's public settings/starter.
const std = @import("std");
const credential_location = @import("credential_location.zig");
const settings_handoff = @import("host_settings_handoff.zig");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const platform = @import("platform.zig");
const identity = @import("host_identity.zig");
const process = @import("upgrade_process.zig");
const Installation = @import("Installation.zig");
const candidate = @import("release_candidate.zig");
const host_start = @import("host_start.zig");
const secret_value = @import("secret_value.zig");
const start_report = @import("start_report.zig");
const product_defaults = @import("product_defaults.zig");

pub const Stage = enum { stopping, awaiting_retirement, starting, verifying };
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, Stage) void,
    fn send(self: ?Progress, stage: Stage) void {
        if (self) |value| value.report(value.context, stage);
    }
};
pub const Limitation = enum { inaccessible, incompatible, ownership_unconfirmed, application_owned, configuration_unavailable, target_capability };
pub const ActivationOutcome = union(enum) {
    not_needed,
    superseded,
    already_ready: struct { instance: protocol.InstanceId, pid: c_int },
    ready: struct { instance: protocol.InstanceId, pid: c_int },
    /// Target public status, answering peer release and new instance were
    /// verified; only the calling client's wire is incompatible.
    client_incompatible: c_int,
    unsupported: Limitation,
    replacement_observed,
    cancelled,
    refused: struct { stage: enum { checking, starting }, failure: start_report.Failure },
    failed: Stage,
    unconfirmed: Stage,
};

// The arena's allocator context must not move when an Observation is returned.
// Its normalized assignments can contain secrets and are wiped on EVERY exit.
const Sources = struct {
    wiping: secret_value.WipingAllocator,
    arena: std.heap.ArenaAllocator,
    request: host_start.Spawn,

    fn init(gpa: std.mem.Allocator, argv: []const []const u8) !*Sources {
        const self = try gpa.create(Sources);
        self.wiping = .{ .backing = gpa };
        self.arena = .init(self.wiping.allocator());
        errdefer self.deinit(gpa);
        const running = try @import("serve_grammar.zig").runningSources(self.arena.allocator(), argv);
        if (!running.restartable) return error.UnsupportedHostConfiguration;
        const dir = running.dir orelse return error.UnsupportedHostConfiguration;
        if (!std.fs.path.isAbsolute(dir)) return error.UnsupportedHostConfiguration;
        self.request = .{ .dir = dir, .settings_file = running.settings_file, .assignments = running.assignments };
        return self;
    }
    fn deinit(self: *Sources, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};
pub const Plan = struct {
    observed: client.HostControlObservation,
    snapshot: identity.Snapshot,
    sources: *Sources,
    version: candidate.Version,
};
pub const Observation = union(enum) {
    absent,
    managed: Plan,
    unsupported: Limitation,
    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        if (self.* == .managed) {
            self.managed.sources.deinit(allocator);
            self.managed.snapshot.deinit(allocator);
        }
    }
};

fn installedVersion(allocator: std.mem.Allocator, io: std.Io, home: []const u8, executable: []const u8, cancellation: ?*const client.Cancellation) !?candidate.Version {
    if (!std.mem.endsWith(u8, executable, "/bin/rui")) return null;
    var build = try Installation.inspectBuild(allocator, io, home, executable[0 .. executable.len - "/bin/rui".len], cancellation);
    defer build.deinit(allocator);
    return switch (build) {
        .released => |value| value.version,
        .source => source: {
            const result = try process.runWithTimeout(allocator, io, &.{ executable, "--version" }, cancellation, 512, .fromSeconds(5));
            defer process.dispose(allocator, result);
            break :source if (result.term.success()) releaseVersion(result.stdout) else null;
        },
        else => null,
    };
}

pub fn observe(allocator: std.mem.Allocator, io: std.Io, home: []const u8, directory: []const u8, cancellation: ?*const client.Cancellation) !Observation {
    try process.check(cancellation);
    switch (client.hostStatus(io, directory)) {
        .unavailable => return .absent,
        .owned_unavailable => return .{ .unsupported = .ownership_unconfirmed },
        .access_failure => return .{ .unsupported = .inaccessible },
        .incompatible, .ready => {},
    }
    const observed = client.observeHostForUpgrade(io, directory, null) catch return .{ .unsupported = .ownership_unconfirmed };
    var snapshot = identity.snapshot(allocator, observed.pid) catch return .{ .unsupported = .configuration_unavailable };
    var owned = true;
    defer if (owned) snapshot.deinit(allocator);
    const version = (try installedVersion(allocator, io, home, snapshot.executable, cancellation)) orelse return .{ .unsupported = .application_owned };
    if (!restartableEnvironment(snapshot.environment)) return .{ .unsupported = .configuration_unavailable };
    const sources = Sources.init(allocator, snapshot.argv) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .unsupported = .configuration_unavailable };
    };
    var source_owned = true;
    defer if (source_owned) sources.deinit(allocator);
    // The argv spelling can be an absolute alias of the selected Host DIR.
    // Placement already canonicalizes selectors; compare the same fact here,
    // without changing settings-file or assignment byte spellings.
    var directory_buffer: [protocol.max_store_bytes]u8 = undefined;
    const canonical_directory = platform.canonicalStoreDestination(io, sources.request.dir, &directory_buffer) catch return .{ .unsupported = .ownership_unconfirmed };
    if (!std.mem.eql(u8, canonical_directory, observed.directory())) return .{ .unsupported = .ownership_unconfirmed };
    sources.request.dir = try sources.arena.allocator().dupe(u8, canonical_directory);
    const confirmed = client.observeHostForUpgradeProfile(io, directory, observed.profile, null) catch return .{ .unsupported = .ownership_unconfirmed };
    if (!sameHost(observed, confirmed) or (identity.generation(observed.pid) catch 0) != snapshot.started) return .{ .unsupported = .ownership_unconfirmed };
    owned = false;
    source_owned = false;
    return .{ .managed = .{ .observed = observed, .snapshot = snapshot, .sources = sources, .version = version } };
}

fn sameHost(a: client.HostControlObservation, b: client.HostControlObservation) bool {
    return a.profile == b.profile and a.pid == b.pid and std.mem.eql(u8, &a.facts.instance, &b.facts.instance) and std.mem.eql(u8, a.facts.store.slice(), b.facts.store.slice());
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
        for ([_][]const u8{ "HOME", "TMPDIR", "SSL_CERT_FILE" } ++ credential_location.variables) |path_name| {
            if (std.mem.eql(u8, name, path_name) and value.len != 0 and !std.fs.path.isAbsolute(value)) return false;
        }
        if (std.mem.eql(u8, name, "SSL_CERT_DIR")) {
            var paths = std.mem.tokenizeScalar(u8, value, ':');
            while (paths.next()) |path| if (!std.fs.path.isAbsolute(path)) return false;
        }
    }
    return true;
}

fn nowNanos(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// Sleeps toward `until` on the awake clock, at most 50 ms at a time, and
/// answers false without sleeping once `until` has passed.
fn sleepToward(io: std.Io, until: i96) !bool {
    const remaining = until - nowNanos(io);
    if (remaining <= 0) return false;
    try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 50 * std.time.ns_per_ms))), .awake);
    return true;
}

pub fn awaitRetirement(io: std.Io, store: []const u8) !bool {
    const until = nowNanos(io) + product_defaults.host_shutdown_seconds * std.time.ns_per_s;
    while (platform.StoreLease.observe(io, store) != .unowned) {
        if (!try sleepToward(io, until)) return false;
    }
    return true;
}

pub fn releaseVersion(reported: []const u8) ?candidate.Version {
    if (!std.mem.startsWith(u8, reported, "rui ")) return null;
    const end = std.mem.indexOf(u8, reported[4..], " (") orelse return null;
    return candidate.Version.parse(reported[4..][0..end]) catch null;
}

// Only public command argv are composed here. Host-child argv belong solely to
// host_start.spawn in the target process; values are never resolved into --set.
fn arguments(allocator: std.mem.Allocator, binary: []const u8, request: host_start.Spawn, command: enum { check, start, status }) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ binary, "host", switch (command) {
        .check => "settings",
        .start => "start",
        .status => "status",
    } });
    if (command == .check) try argv.appendSlice(allocator, &.{ "--check", "--" ++ settings_handoff.check_option });
    if (command == .start) try argv.appendSlice(allocator, &.{ "--" ++ settings_handoff.input_option, "0" });
    try argv.appendSlice(allocator, &.{ "--store", request.dir });
    if (command != .status) {
        if (request.settings_file) |file| try argv.appendSlice(allocator, &.{ "--settings", file });
        for (request.assignments) |value| try argv.appendSlice(allocator, &.{ "--set", value });
    }
    return argv.toOwnedSlice(allocator);
}

fn refusal(allocator: std.mem.Allocator, result: process.Result) !?start_report.Failure {
    // Public starters write the typed envelope on stdout; permit stderr too,
    // but never turn arbitrary server/child prose into a typed diagnostic.
    for ([_][]const u8{ result.stdout, result.stderr }) |bytes| {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |end| {
            if (try start_report.parseLine(allocator, bytes[start .. end + 1])) |failure| return failure;
            start = end + 1;
        }
    }
    return null;
}

fn knownBadTarget(build: Installation.Selection) bool {
    // Process-witnessed released v0.75.0 accepts stdin lifetime in check then
    // refuses detached start. A fixed intentional source build is NOT this
    // artifact, even if its version text is identical. No future cutoff guessed.
    return build == .released and build.released.version.schema == 75 and build.released.version.patch == 0;
}

fn stopObserved(io: std.Io, allocator: std.mem.Allocator, plan: *const Plan, context: process.Context) !client.HostStopResult {
    const directory = plan.sources.request.dir;
    if (plan.observed.profile.historical()) {
        const instance = std.fmt.bytesToHex(plan.observed.facts.instance, .lower);
        const result = try process.runIn(allocator, io, &.{ plan.snapshot.executable, "host", "pause", "--store", directory, "--instance", &instance }, null, 8192, .fromSeconds(product_defaults.host_shutdown_seconds + 5), context);
        defer process.dispose(allocator, result);
        if (!result.term.success()) return error.UpgradeChildFailed;
        return .acknowledged;
    }
    var reply: client.ReplyBuffer = .{};
    return client.stopHost(io, .{ .store = directory, .instance = plan.observed.facts.instance }, &reply);
}

fn retired(io: std.Io, allocator: std.mem.Allocator, plan: *const Plan) !bool {
    // Runtime retirement is NOT proof of MySQL GET_LOCK release. Only the
    // replacement starter's Store acquisition/readiness can establish that.
    const until = nowNanos(io) + product_defaults.host_shutdown_seconds * std.time.ns_per_s;
    while (true) {
        const process_retired = client.upgradeGenerationRetired(allocator, io, plan.snapshot.pid, plan.snapshot.started, until) catch false;
        if (process_retired) {
            if (platform.StoreLease.observe(io, plan.sources.request.dir) == .unowned) return true;
            // A concurrent starter may have acquired the lease after the old
            // generation retired. Never stop it: start adopts, proof decides.
            if (client.observeUpgradePeer(allocator, io, plan.sources.request.dir, until)) |value| {
                var peer = value;
                defer peer.deinit(allocator);
                if (peer.pid != plan.snapshot.pid or peer.started != plan.snapshot.started) return true;
            } else |_| {}
        }
        if (!try sleepToward(io, until)) return false;
    }
}

fn verify(init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, executable: []const u8, version: candidate.Version, context: process.Context) !ActivationOutcome {
    const until = nowNanos(init.io) + @import("HostStartupWait.zig").readiness_ns;
    const argv = try arguments(allocator, executable, plan.sources.request, .status);
    defer allocator.free(argv);
    while (nowNanos(init.io) < until) {
        if (client.observeUpgradePeer(allocator, init.io, plan.sources.request.dir, until)) |first| {
            var before = first;
            defer before.deinit(allocator);
            const result = process.runIn(allocator, init.io, argv, null, 8192, .fromNanoseconds(@intCast(@max(1, until - nowNanos(init.io)))), context) catch return .{ .unconfirmed = .verifying };
            defer process.dispose(allocator, result);
            if (result.term.success()) {
                if (try client.parseUpgradeStatus(allocator, result.stdout)) |facts| {
                    if (client.observeUpgradePeer(allocator, init.io, plan.sources.request.dir, until)) |last| {
                        var after = last;
                        defer after.deinit(allocator);
                        if (sameSnapshot(&before, &after)) {
                            const actual = (try installedVersion(allocator, init.io, init.environ_map.get("HOME") orelse return .{ .unconfirmed = .verifying }, after.executable, null)) orelse return .{ .unconfirmed = .verifying };
                            if (replacementMatches(plan, facts, actual, version)) {
                                const status = client.hostStatus(init.io, plan.sources.request.dir);
                                const usable = statusAgrees(status, facts);
                                if (usable) {
                                    if (client.observeUpgradePeer(allocator, init.io, plan.sources.request.dir, until)) |last_peer| {
                                        var final_peer = last_peer;
                                        defer final_peer.deinit(allocator);
                                        if (sameSnapshot(&after, &final_peer)) return if (status == .incompatible)
                                            .{ .client_incompatible = final_peer.pid }
                                        else
                                            .{ .ready = .{ .instance = facts.instance, .pid = final_peer.pid } };
                                    } else |_| {}
                                }
                            } else {
                                return .replacement_observed;
                            }
                        }
                    } else |_| {}
                }
            }
        } else |_| {}
        _ = try sleepToward(init.io, until);
    }
    return .{ .unconfirmed = .verifying };
}

/// Used ONLY after target-public readiness, instance and answering release
/// proof. An explicit negative final probe must never become success.
fn statusAgrees(status: protocol_reply.HostStatus, facts: client.ReplacementFacts) bool {
    return switch (status) {
        .ready => |ready| std.mem.eql(u8, &ready.instance, &facts.instance) and std.mem.eql(u8, ready.store.slice(), facts.store.slice()) and ready.active_capacity == facts.active_capacity,
        .incompatible => true,
        .unavailable, .owned_unavailable, .access_failure => false,
    };
}

fn replacementMatches(plan: *const Plan, facts: client.ReplacementFacts, actual: candidate.Version, target: candidate.Version) bool {
    return actual.order(target) == .eq and !std.mem.eql(u8, &facts.instance, &plan.observed.facts.instance) and
        std.mem.eql(u8, facts.store.slice(), plan.observed.facts.store.slice()) and facts.active_capacity == plan.observed.facts.active_capacity;
}

pub fn activate(init: std.process.Init, allocator: std.mem.Allocator, observation: *const Observation, target: []const u8, version: candidate.Version, cancellation: ?*const client.Cancellation, progress: ?Progress) !ActivationOutcome {
    const plan = switch (observation.*) {
        .absent => return .not_needed,
        .unsupported => |reason| return .{ .unsupported = reason },
        .managed => |*value| value,
    };
    process.check(cancellation) catch return .cancelled;
    if (plan.version.order(version) == .gt) return .superseded;
    var wiping: secret_value.WipingAllocator = .{ .backing = allocator };
    const private = wiping.allocator();
    var arena: std.heap.ArenaAllocator = .init(private);
    defer arena.deinit();
    var environment: std.process.Environ.Map = .init(private);
    defer environment.deinit();
    for (plan.snapshot.environment) |entry| {
        const equal = std.mem.indexOfScalar(u8, entry, '=') orelse return .{ .unsupported = .configuration_unavailable };
        try environment.put(entry[0..equal], entry[equal + 1 ..]);
    }
    const context: process.Context = .{ .environ_map = &environment, .cwd = .{ .path = "/" } };
    var captured = init;
    captured.gpa = private;
    captured.arena = &arena;
    captured.environ_map = &environment;
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/bin/rui", .{target});
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, path, arena.allocator());
    if (std.mem.eql(u8, executable, plan.snapshot.executable)) {
        const current = client.observeHostForUpgradeProfile(init.io, plan.sources.request.dir, plan.observed.profile, null) catch return .{ .unconfirmed = .verifying };
        if (!sameHost(current, plan.observed) or (identity.generation(current.pid) catch 0) != plan.snapshot.started) return .replacement_observed;
        return .{ .already_ready = .{ .instance = current.facts.instance, .pid = current.pid } };
    }
    var build = try Installation.inspectBuild(private, init.io, init.environ_map.get("HOME") orelse return error.HomeNotFound, target, cancellation);
    defer build.deinit(private);
    if (knownBadTarget(build)) return .{ .unsupported = .target_capability };
    const request = host_start.restartSources(captured, arena.allocator(), plan.sources.request, plan.version.order(.{ .schema = 75, .patch = 0 }) == .lt, plan.observed.facts.active_capacity) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .unsupported = .configuration_unavailable };
    };
    const check_argv = try arguments(arena.allocator(), executable, request, .check);
    const checked = process.runIn(private, init.io, check_argv, cancellation, settings_handoff.max_bytes, .fromSeconds(300), context) catch |err| {
        if (err == error.Cancelled) return .cancelled;
        return .{ .unsupported = .configuration_unavailable };
    };
    defer process.dispose(private, checked);
    if (!checked.term.success()) {
        if (try refusal(private, checked)) |failure| return .{ .refused = .{ .stage = .checking, .failure = failure } };
        return .{ .unsupported = .target_capability };
    }
    // The frame owner validates version/framing/bounds. Lifecycle neither
    // decodes settings nor reconstructs the target's admitted input.
    settings_handoff.accept(checked.stdout) catch return .{ .unsupported = .target_capability };
    process.check(cancellation) catch return .cancelled;
    const current = client.observeHostForUpgradeProfile(init.io, request.dir, plan.observed.profile, null) catch return .{ .unconfirmed = .stopping };
    if (!sameHost(current, plan.observed)) return .replacement_observed;
    var fresh = identity.snapshot(private, current.pid) catch return .{ .unconfirmed = .stopping };
    defer fresh.deinit(private);
    if (!sameSnapshot(&plan.snapshot, &fresh)) return .{ .unsupported = .configuration_unavailable };
    // EOF already transferred batch custody. After stop, caller cancellation
    // cannot abandon this or later entries; start and verification are bounded.
    Progress.send(progress, .stopping);
    const stopped = stopObserved(init.io, private, plan, context) catch return .{ .unconfirmed = .stopping };
    if (stopped == .instance_changed) return .replacement_observed;
    Progress.send(progress, .awaiting_retirement);
    if (!try retired(init.io, private, plan)) return .{ .unconfirmed = .awaiting_retirement };
    Progress.send(progress, .starting);
    process.waitForTestGate(allocator, init.io, init.environ_map.get("RUI_TEST_UPGRADE_BEFORE_START_GATE"), null, .fromSeconds(300)) catch return .{ .unconfirmed = .starting };
    const start_argv = try arguments(arena.allocator(), executable, request, .start);
    var start_context = context;
    start_context.input = checked.stdout;
    const started = process.runIn(private, init.io, start_argv, null, 8192, .fromSeconds(300), start_context) catch return .{ .unconfirmed = .starting };
    defer process.dispose(private, started);
    if (!started.term.success()) {
        if (try refusal(private, started)) |failure| return .{ .refused = .{ .stage = .starting, .failure = failure } };
        return .{ .failed = .starting };
    }
    Progress.send(progress, .verifying);
    return verify(init, private, plan, executable, version, context);
}

test "upgrade lifecycle control cannot equate different wire profiles or instances" {
    for (std.enums.values(protocol_reply.HostInfoProfile)) |profile| {
        var original: client.HostControlObservation = .{
            .profile = profile,
            .pid = 123,
            .facts = .{ .store = .{ .len = 0 }, .instance = @splat(1), .active_capacity = 2, .started_at = 0, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .providers = protocol.routesAll(.unserved) } },
        };
        try original.facts.store.set("/fixture/store");
        try std.testing.expect(sameHost(original, original));
        var replacement = original;
        for (std.enums.values(protocol_reply.HostInfoProfile)) |other| {
            replacement.profile = other;
            try std.testing.expectEqual(profile == other, sameHost(original, replacement));
        }
        replacement = original;
        replacement.facts.instance = @splat(2);
        try std.testing.expect(!sameHost(original, replacement));
        replacement = original;
        replacement.pid += 1;
        try std.testing.expect(!sameHost(original, replacement));
        replacement = original;
        try replacement.facts.store.set("/fixture/other");
        try std.testing.expect(!sameHost(original, replacement));
    }
}

test "upgrade public commands preserve semantic sources and Host directory routing" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]host_start.Spawn{
        .{ .dir = "/host" }, // bare or saved: saved placement stays with DIR
        .{ .dir = "/host", .settings_file = "/private/settings\xff.json" },
        .{ .dir = "/host", .assignments = &.{ "providers={}", "execution.activeCapacity=3", "execution.activeCapacity=7" } },
        .{ .dir = "/host", .settings_file = "-" }, // the target owns typed refusal
        .{ .dir = "/host", .settings_file = "relative.json" },
        .{ .dir = "/host", .assignments = &.{"store.sqlite.dir=/moved/data"} },
        .{ .dir = "/host", .assignments = &.{"interface.dir=/moved/interface"} },
        .{ .dir = "/host", .assignments = &.{"store.mysql.url=env:PRIVATE_DATABASE"} },
    }) |request| {
        inline for (.{ .check, .start, .status }) |command| {
            const argv = try arguments(arena.allocator(), "/target/bin/rui", request, command);
            try std.testing.expectEqualStrings("/target/bin/rui", argv[0]);
            try std.testing.expectEqualStrings("host", argv[1]);
            const at: usize = if (command == .status) 3 else 5;
            try std.testing.expectEqualStrings("--store", argv[at]);
            try std.testing.expectEqualStrings(request.dir, argv[at + 1]);
            var offset = at + 2;
            if (command != .status) {
                if (request.settings_file) |file| {
                    try std.testing.expectEqualStrings("--settings", argv[offset]);
                    try std.testing.expectEqualStrings(file, argv[offset + 1]);
                    offset += 2;
                }
                for (request.assignments) |value| {
                    try std.testing.expectEqualStrings("--set", argv[offset]);
                    try std.testing.expectEqualStrings(value, argv[offset + 1]);
                    offset += 2;
                }
            }
            try std.testing.expectEqual(offset, argv.len);
        }
    }
}

test "upgrade replacement proof accepts adopted target version but not old instance or guessed readiness" {
    var plan: Plan = undefined;
    plan.observed.facts = .{ .store = .{}, .instance = @splat(1), .active_capacity = 3, .started_at = 0, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .providers = protocol.routesAll(.unserved) } };
    try plan.observed.facts.store.set("database-wire-identity");
    const target: candidate.Version = .{ .schema = 76, .patch = 1 };
    var facts: client.ReplacementFacts = .{ .instance = @splat(2), .store = .{}, .active_capacity = 3 };
    try facts.store.set("database-wire-identity");
    try std.testing.expect(replacementMatches(&plan, facts, target, target));
    var ready = plan.observed.facts;
    ready.instance = facts.instance;
    try std.testing.expect(statusAgrees(.{ .ready = ready }, facts));
    for ([_]protocol_reply.HostStatus{ .unavailable, .owned_unavailable, .access_failure }) |status| try std.testing.expect(!statusAgrees(status, facts));
    try std.testing.expect(statusAgrees(.incompatible, facts));
    ready.instance = plan.observed.facts.instance;
    try std.testing.expect(!statusAgrees(.{ .ready = ready }, facts));
    ready.instance = facts.instance;
    ready.active_capacity += 1;
    try std.testing.expect(!statusAgrees(.{ .ready = ready }, facts));

    facts.instance = @splat(1);
    try std.testing.expect(!replacementMatches(&plan, facts, target, target));
    facts.instance = @splat(2);
    facts.active_capacity = 4;
    try std.testing.expect(!replacementMatches(&plan, facts, target, target));
    facts.active_capacity = 3;
    try std.testing.expect(!replacementMatches(&plan, facts, .{ .schema = 75, .patch = 9 }, target));
    try facts.store.set("other-store");
    try std.testing.expect(!replacementMatches(&plan, facts, target, target));
}

test "all credential location variables must be restartable paths" {
    inline for (credential_location.variables) |name| {
        try std.testing.expect(!restartableEnvironment(&.{name ++ "=relative"}));
        try std.testing.expect(restartableEnvironment(&.{name ++ "=/absolute"}));
        try std.testing.expect(restartableEnvironment(&.{name ++ "="}));
    }
}

test "upgrade target capability exception is the witnessed release not a future version threshold" {
    try std.testing.expect(knownBadTarget(.{ .released = .{ .build = "/managed", .version = .{ .schema = 75, .patch = 0 } } }));
    for ([_]candidate.Version{ .{ .schema = 74, .patch = 0 }, .{ .schema = 75, .patch = 1 }, .{ .schema = 76, .patch = 0 } }) |version| {
        try std.testing.expect(!knownBadTarget(.{ .released = .{ .build = "/managed", .version = version } }));
    }
    try std.testing.expect(!knownBadTarget(.{ .source = "/managed/fixed-source-same-version" }));
    try std.testing.expect(!restartableEnvironment(&.{"LD_PRELOAD=/custom"}));
    try std.testing.expect(!restartableEnvironment(&.{"SSL_CERT_FILE=relative.pem"}));
    try std.testing.expect(restartableEnvironment(&.{ "HOME=/home/fixture", "PRIVATE=secret\xff" }));
}

test "upgrade running sources wipe on success and every allocation failure" {
    const Probe = struct {
        backing: std.mem.Allocator,
        header: ?[*]u8 = null,
        stale: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const bytes = self.backing.rawAlloc(len, alignment, ret) orelse return null;
            if (self.header == null) self.header = bytes;
            return bytes;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (bytes.ptr != self.header) for (bytes) |byte| {
                if (byte != 0) self.stale = true;
            };
            self.backing.rawFree(bytes, alignment, ret);
        }
        fn exercise(gpa: std.mem.Allocator) !void {
            var probe: @This() = .{ .backing = gpa };
            defer std.debug.assert(!probe.stale);
            const source = try Sources.init(probe.allocator(), &.{ "rui", "host", "serve", "--store", "/host", "--provider-endpoint", "https://private-restart-key.test/responses" });
            defer source.deinit(probe.allocator());
            try std.testing.expect(source.request.assignments.len > 0);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.exercise, .{});
}
