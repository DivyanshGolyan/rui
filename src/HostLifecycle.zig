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
const activation = @import("host_activation.zig");

pub const Stage = activation.Stage;
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, Stage) void,
    fn send(self: ?Progress, stage: Stage) void {
        if (self) |value| value.report(value.context, stage);
    }
};
pub const Limitation = activation.Limitation;
pub const TargetStep = activation.TargetStep;

pub const ActivationOutcome = activation.Outcome;

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

/// Reads what `host_activation.eligibility` asks for, in its order, and keeps
/// the handles of a managed Host as its Plan.
pub fn observe(allocator: std.mem.Allocator, io: std.Io, home: []const u8, directory: []const u8, cancellation: ?*const client.Cancellation) !Observation {
    try process.check(cancellation);
    var seen: activation.Seen = .{};
    var observed: client.HostControlObservation = undefined;
    var snapshot: ?identity.Snapshot = null;
    defer if (snapshot) |*value| value.deinit(allocator);
    var version: candidate.Version = undefined;
    var sources: ?*Sources = null;
    defer if (sources) |value| value.deinit(allocator);
    while (true) switch (activation.eligibility(seen)) {
        .read => |read| switch (read) {
            .status => seen.status = switch (client.hostStatus(io, directory)) {
                .unavailable => .unavailable,
                .owned_unavailable => .owned_unavailable,
                .access_failure => .access_failure,
                .incompatible => .incompatible,
                .ready => .ready,
            },
            .observe => seen.observed = if (client.observeHostForUpgrade(allocator, io, directory, null)) |value| observed: {
                observed = value;
                break :observed true;
            } else |err| if (err == error.OutOfMemory) return err else false,
            .snapshot => seen.snapshot = if (identity.snapshot(allocator, observed.pid)) |value| taken: {
                snapshot = value;
                break :taken true;
            } else |err| if (err == error.OutOfMemory) return err else false,
            .version => seen.managed = if (try installedVersion(allocator, io, home, snapshot.?.executable, cancellation)) |value| managed: {
                version = value;
                break :managed true;
            } else false,
            .environment => seen.environment = restartableEnvironment(snapshot.?.environment),
            .sources => seen.sources = if (Sources.init(allocator, snapshot.?.argv)) |value| reconstructed: {
                sources = value;
                break :reconstructed true;
            } else |err| if (err == error.OutOfMemory) return err else false,
            .directory => {
                // The argv spelling can be an absolute alias of the selected Host DIR.
                // Placement already canonicalizes selectors; compare the same fact here,
                // without changing settings-file or assignment byte spellings.
                var directory_buffer: [protocol.max_store_bytes]u8 = undefined;
                const request = &sources.?.request;
                const canonical = platform.canonicalStoreDestination(io, request.dir, &directory_buffer) catch {
                    seen.directory = .unavailable;
                    continue;
                };
                if (!std.mem.eql(u8, canonical, observed.directory())) {
                    seen.directory = .mismatch;
                    continue;
                }
                request.dir = try sources.?.arena.allocator().dupe(u8, canonical);
                seen.directory = .same;
            },
            .confirm => seen.confirmed = if (client.observeHostForUpgrade(allocator, io, directory, null)) |confirmed|
                sameHost(observed, confirmed) and (identity.generation(observed.pid) catch 0) == snapshot.?.started
            else |err| if (err == error.OutOfMemory) return err else false,
        },
        .absent => return .absent,
        .unsupported => |reason| return .{ .unsupported = reason },
        .managed => {
            defer snapshot = null;
            defer sources = null;
            return .{ .managed = .{ .observed = observed, .snapshot = snapshot.?, .sources = sources.?, .version = version } };
        },
    };
}

/// Identity is the process, its Host instance and its Store. The wire a Host
/// speaks is how it was read, not which Host it is.
fn sameHost(a: client.HostControlObservation, b: client.HostControlObservation) bool {
    return a.pid == b.pid and std.mem.eql(u8, &a.facts.instance, &b.facts.instance) and std.mem.eql(u8, a.facts.store.slice(), b.facts.store.slice());
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
    return awaitRetirementWithin(io, store, product_defaults.host_shutdown_seconds * std.time.ns_per_s);
}

/// Waits up to `within_ns` for the Host to release this Store.
pub fn awaitRetirementWithin(io: std.Io, store: []const u8, within_ns: u64) !bool {
    const until = nowNanos(io) + within_ns;
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

fn stopObserved(io: std.Io, allocator: std.mem.Allocator, plan: *const Plan, context: process.Context) !client.HostStopResult {
    const directory = plan.sources.request.dir;
    if (plan.observed.foreign) {
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

/// Repeats `host_activation.verdict` passes until it decides or the readiness
/// deadline passes. The shell owns the clock; each pass reads only what the
/// verdict asks for.
fn verify(init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, executable: []const u8, version: candidate.Version, context: process.Context) !ActivationOutcome {
    const until = nowNanos(init.io) + @import("HostStartupWait.zig").readiness_ns;
    const argv = try arguments(allocator, executable, plan.sources.request, .status);
    defer allocator.free(argv);
    while (nowNanos(init.io) < until) {
        if (try verifyPass(init, allocator, plan, argv, version, context, until)) |outcome| return outcome;
        _ = try sleepToward(init.io, until);
    }
    return .{ .unconfirmed = .verifying };
}

fn verifyPass(init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, argv: []const []const u8, version: candidate.Version, context: process.Context, until: i96) !?ActivationOutcome {
    const directory = plan.sources.request.dir;
    var probe: activation.Probe = .{ .stopped = .{
        .instance = plan.observed.facts.instance,
        .store = plan.observed.facts.store.slice(),
        .capacity = plan.observed.facts.active_capacity,
    } };
    var before: ?identity.Snapshot = null;
    defer if (before) |*peer| peer.deinit(allocator);
    var after: ?identity.Snapshot = null;
    defer if (after) |*peer| peer.deinit(allocator);
    var facts: client.StatusFacts = undefined;
    // The probe borrows Store bytes from both answers until the pass ends.
    var own: protocol_reply.HostStatus = undefined;
    while (true) switch (activation.verdict(probe)) {
        .read => |read| switch (read) {
            .before => probe.before = if (client.observeUpgradePeer(allocator, init.io, directory, until)) |peer| peer: {
                before = peer;
                break :peer true;
            } else |_| false,
            .status => {
                const result = process.runIn(allocator, init.io, argv, null, 8192, .fromNanoseconds(@intCast(@max(1, until - nowNanos(init.io)))), context) catch {
                    probe.status = .unavailable;
                    continue;
                };
                defer process.dispose(allocator, result);
                const parsed = if (result.term.success()) try client.parseUpgradeStatus(allocator, result.stdout) else null;
                if (parsed) |value| {
                    facts = value;
                    probe.status = .{ .answered = .{ .instance = facts.instance, .store = facts.store.slice(), .capacity = facts.active_capacity } };
                } else probe.status = .unanswered;
            },
            .after => probe.after = if (client.observeUpgradePeer(allocator, init.io, directory, until)) |peer| peer: {
                after = peer;
                break :peer sameSnapshot(&before.?, &after.?);
            } else |_| false,
            .version => probe.version = version: {
                const home = init.environ_map.get("HOME") orelse break :version .unknown;
                const actual = (try installedVersion(allocator, init.io, home, after.?.executable, null)) orelse break :version .unknown;
                break :version .{ .order = actual.order(version) };
            },
            .own => probe.own = own: {
                own = client.hostStatus(init.io, directory);
                break :own switch (own) {
                    .ready => |*ready| .{ .ready = .{ .instance = ready.instance, .store = ready.store.slice(), .capacity = ready.active_capacity } },
                    .incompatible => .incompatible,
                    .unavailable, .owned_unavailable, .access_failure => .unavailable,
                };
            },
            .final => probe.final = if (client.observeUpgradePeer(allocator, init.io, directory, until)) |peer| final: {
                var last = peer;
                defer last.deinit(allocator);
                break :final if (sameSnapshot(&after.?, &last)) .{ .same = last.pid } else .differs;
            } else |_| .differs,
        },
        .again => return null,
        .done => |outcome| return outcome,
    };
}

/// Executes the activation policy with a single effect owner. An effect failure
/// becomes `.faulted` at the exact effect that failed, so the outcome carries its
/// certainty to every caller.
pub fn runActivation(initial: activation.Facts, driver: anytype) activation.Outcome {
    var facts = initial;
    while (true) {
        const effect = activation.next(facts, driver.cancelled());
        if (effect == .done) return effect.done;
        driver.perform(effect, &facts) catch |err| return .{ .faulted = .{
            .effect = std.meta.activeTag(effect),
            .cause = protocol.Bounded(64).from(@errorName(err)) catch unreachable,
        } };
    }
}

const ActivationDriver = struct {
    init: std.process.Init,
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    private: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    environment: *std.process.Environ.Map,
    context: process.Context,
    target: []const u8,
    version: candidate.Version,
    cancellation: ?*const client.Cancellation,
    progress: ?Progress,
    executable: []const u8 = undefined,
    request: host_start.Spawn = undefined,
    checked: ?process.Result = null,
    current: client.HostControlObservation = undefined,

    fn cancelled(self: *ActivationDriver) bool {
        process.check(self.cancellation) catch return true;
        return false;
    }

    fn perform(self: *ActivationDriver, effect: activation.Effect, facts: *activation.Facts) !void {
        const plan = self.plan.?;
        switch (effect) {
            .resolve_target => {
                for (plan.snapshot.environment) |entry| {
                    const equal = std.mem.indexOfScalar(u8, entry, '=').?;
                    try self.environment.put(entry[0..equal], entry[equal + 1 ..]);
                }
                const path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/bin/rui", .{self.target});
                self.executable = std.Io.Dir.cwd().realPathFileAlloc(self.init.io, path, self.arena.allocator()) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    facts.target_failed = .resolving;
                    return;
                };
                facts.same_executable = std.mem.eql(u8, self.executable, plan.snapshot.executable);
            },
            .confirm_current => facts.current = if (client.observeHostForUpgrade(self.private, self.init.io, plan.sources.request.dir, null)) |value|
                (if (!sameHost(value, plan.observed) or (identity.generation(value.pid) catch 0) != plan.snapshot.started)
                    .changed
                else
                    .{ .same = .{ .running = .{ .instance = value.facts.instance, .pid = value.pid }, .settings = value.facts.settings_digest } })
            else |err| if (err == error.OutOfMemory) return err else .unreadable,
            .reconstruct_sources => facts.sources = if (host_start.restartSources(self.arena.allocator(), plan.sources.request, plan.observed.facts.active_capacity)) |value| sources: {
                self.request = value;
                break :sources true;
            } else |err| if (err == error.OutOfMemory) return err else false,
            .check_target => {
                const check_argv = try arguments(self.arena.allocator(), self.executable, self.request, .check);
                const result = process.runIn(self.private, self.init.io, check_argv, self.cancellation, settings_handoff.max_bytes, .fromSeconds(300), self.context) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    facts.check = if (err == error.Cancelled) .cancelled else .unavailable;
                    return;
                };
                self.checked = result;
                facts.check = if (!result.term.success())
                    (if (try refusal(self.private, result)) |failure| .{ .refused = failure } else .untyped)
                else if (settings_handoff.accept(result.stdout)) |_|
                    // The frame owner validates version/framing/bounds. Lifecycle neither
                    // decodes settings nor reconstructs the target's admitted input; it only
                    // digests the frame a new Host would be started with.
                    .{ .ok = settings_handoff.digest(result.stdout) }
                else |_|
                    .bad_frame;
            },
            .reobserve => facts.before_stop = if (client.observeHostForUpgrade(self.private, self.init.io, self.request.dir, null)) |value| reobserved: {
                self.current = value;
                break :reobserved if (sameHost(self.current, plan.observed)) .same else .changed;
            } else |err| if (err == error.OutOfMemory) return err else .unreadable,
            .snapshot => facts.snapshot = if (identity.snapshot(self.private, self.current.pid)) |value| fresh: {
                var taken = value;
                defer taken.deinit(self.private);
                break :fresh if (sameSnapshot(&plan.snapshot, &taken)) .same else .changed;
            } else |err| if (err == error.OutOfMemory) return err else .unreadable,
            .stop => {
                // EOF already transferred batch custody. After stop, caller cancellation
                // cannot abandon this or later entries; start and verification are bounded.
                Progress.send(self.progress, .stopping);
                const stopped = try stopObserved(self.init.io, self.private, plan, self.context);
                facts.stop = if (stopped == .instance_changed) .instance_changed else .done;
            },
            .await_retirement => {
                Progress.send(self.progress, .awaiting_retirement);
                facts.retired = try retired(self.init.io, self.private, plan);
            },
            .start => {
                Progress.send(self.progress, .starting);
                try process.waitForTestGate(self.allocator, self.init.io, self.init.environ_map.get("RUI_TEST_UPGRADE_BEFORE_START_GATE"), null, .fromSeconds(300));
                const start_argv = try arguments(self.arena.allocator(), self.executable, self.request, .start);
                var start_context = self.context;
                start_context.input = self.checked.?.stdout;
                const started = try process.runIn(self.private, self.init.io, start_argv, null, 8192, .fromSeconds(300), start_context);
                defer process.dispose(self.private, started);
                facts.start = if (started.term.success())
                    .started
                else if (try refusal(self.private, started)) |failure| .{ .refused = failure } else .untyped;
            },
            .verify => {
                Progress.send(self.progress, .verifying);
                facts.proof = try verify(self.init, self.private, plan, self.executable, self.version, self.context);
            },
            .done => unreachable,
        }
    }
};

/// Reads and does what `host_activation.next` asks for, in its order. The
/// captured environment and every secret it reaches stay in this wiping
/// allocator; handles and child results stay here.
pub fn activate(init: std.process.Init, allocator: std.mem.Allocator, observation: *const Observation, census: @FieldType(activation.Facts, "census"), target: []const u8, version: candidate.Version, cancellation: ?*const client.Cancellation, progress: ?Progress) ActivationOutcome {
    const facts: activation.Facts = .{
        .eligibility = switch (observation.*) {
            .absent => .absent,
            .unsupported => |reason| .{ .unsupported = reason },
            .managed => |*plan| .{ .managed = .{
                .order = plan.version.order(version),
                .environment_parses = for (plan.snapshot.environment) |entry| {
                    if (std.mem.indexOfScalar(u8, entry, '=') == null) break false;
                } else true,
            } },
        },
        .census = census,
    };
    const plan: ?*const Plan = if (observation.* == .managed) &observation.managed else null;
    var wiping: secret_value.WipingAllocator = .{ .backing = allocator };
    const private = wiping.allocator();
    var arena: std.heap.ArenaAllocator = .init(private);
    defer arena.deinit();
    var environment: std.process.Environ.Map = .init(private);
    defer environment.deinit();
    var driver: ActivationDriver = .{
        .init = init,
        .allocator = allocator,
        .plan = plan,
        .private = private,
        .arena = &arena,
        .environment = &environment,
        .context = .{ .environ_map = &environment, .cwd = .{ .path = "/" } },
        .target = target,
        .version = version,
        .cancellation = cancellation,
        .progress = progress,
    };
    defer if (driver.checked) |result| process.dispose(private, result);
    return runActivation(facts, &driver);
}

test "SH-136 lifecycle preserves the effect and cause of every unexpected failure" {
    const effects = [_]std.meta.Tag(activation.Effect){
        .resolve_target, .confirm_current, .reconstruct_sources, .check_target,
        .reobserve,      .snapshot,        .stop,                .await_retirement,
        .start,          .verify,
    };
    const stages = [_]?activation.Stage{
        null, null, null, null, null, null, .stopping, .awaiting_retirement, .starting, .verifying,
    };
    const Driver = struct {
        fail: ?std.meta.Tag(activation.Effect),
        seen: [effects.len]std.meta.Tag(activation.Effect) = undefined,
        count: usize = 0,

        fn cancelled(_: *@This()) bool {
            return false;
        }
        fn perform(self: *@This(), effect: activation.Effect, facts: *activation.Facts) !void {
            const tag = std.meta.activeTag(effect);
            self.seen[self.count] = tag;
            self.count += 1;
            if (self.fail == tag) return error.InjectedFailure;
            switch (effect) {
                .resolve_target => facts.same_executable = true,
                .confirm_current => facts.current = .{ .same = .{
                    .running = .{ .instance = @splat(1), .pid = 1 },
                    .settings = @splat(1),
                } },
                .reconstruct_sources => facts.sources = true,
                .check_target => facts.check = .{ .ok = @splat(2) },
                .reobserve => facts.before_stop = .same,
                .snapshot => facts.snapshot = .same,
                .stop => facts.stop = .done,
                .await_retirement => facts.retired = true,
                .start => facts.start = .started,
                .verify => facts.proof = .{ .unconfirmed = .verifying },
                .done => unreachable,
            }
        }
    };
    const initial: activation.Facts = .{ .eligibility = .{ .managed = .{
        .order = .lt,
        .environment_parses = true,
    } } };
    for (effects, stages, 0..) |effect, stage, index| {
        var driver: Driver = .{ .fail = effect };
        const result = runActivation(initial, &driver);
        try std.testing.expect(result == .faulted);
        try std.testing.expectEqual(effect, result.faulted.effect);
        try std.testing.expectEqualStrings("InjectedFailure", result.faulted.cause.slice());
        try std.testing.expectEqual(stage, result.faulted.effect.stage());
        try std.testing.expectEqualSlices(std.meta.Tag(activation.Effect), effects[0 .. index + 1], driver.seen[0..driver.count]);
    }
    var driver: Driver = .{ .fail = null };
    const result = runActivation(initial, &driver);
    try std.testing.expectEqual(activation.Stage.verifying, result.unconfirmed);
    try std.testing.expectEqualSlices(std.meta.Tag(activation.Effect), &effects, driver.seen[0..driver.count]);
}

test "upgrade lifecycle control equates a Host by process, instance and store, not by wire" {
    var original: client.HostControlObservation = .{
        .foreign = false,
        .pid = 123,
        .facts = .{ .store = .{ .len = 0 }, .instance = @splat(1), .active_capacity = 2 },
    };
    try original.facts.store.set("/fixture/store");
    try std.testing.expect(sameHost(original, original));
    var replacement = original;
    replacement.foreign = true;
    try std.testing.expect(sameHost(original, replacement));
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

test "all credential location variables must be restartable paths" {
    inline for (credential_location.variables) |name| {
        try std.testing.expect(!restartableEnvironment(&.{name ++ "=relative"}));
        try std.testing.expect(restartableEnvironment(&.{name ++ "=/absolute"}));
        try std.testing.expect(restartableEnvironment(&.{name ++ "="}));
    }
}

test "upgrade restartable environment refuses inherited unsafe variables" {
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
            const source = try Sources.init(probe.allocator(), &.{ "rui", "host", "serve", "--store", "/host", "--set", "providers.codex.endpoint=https://private-restart-key.test/responses" });
            defer source.deinit(probe.allocator());
            try std.testing.expect(source.request.assignments.len > 0);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.exercise, .{});
}
