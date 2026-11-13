const std = @import("std");
const client = @import("client.zig");
const HostStartupWait = @import("HostStartupWait.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const platform = @import("platform.zig");
const identity = @import("host_identity.zig");
const process = @import("upgrade_process.zig");
const Installation = @import("Installation.zig");
const candidate = @import("release_candidate.zig");
const cli_args = @import("cli_args.zig");
const product_defaults = @import("product_defaults.zig");
const host_start = @import("host_start.zig");

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
    observed: client.HostControlObservation,
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
    /// The exact launched build answered, but only a new client can read its
    /// protocol. No activation failure or uncertain process identity is hidden.
    client_incompatible: c_int,
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
        .incompatible => {},
        .access_failure => return .{ .unsupported = .inaccessible },
        .ready => {},
    }
    if (platform.isMysqlClientSelection(store)) return .{ .unsupported = .application_owned };
    const observed = client.observeHostForUpgrade(io, store, null) catch return .{ .unsupported = .ownership_unconfirmed };
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
        .source => source: {
            const reported = try process.output(allocator, io, &.{ snapshot.executable, "--version" }, cancellation, 512);
            defer allocator.free(reported);
            break :source releaseVersion(reported) orelse {
                snapshot.deinit(allocator);
                return .{ .unsupported = .configuration_unavailable };
            };
        },
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
    const confirmed = client.observeHostForUpgradeProfile(io, store, observed.profile, null) catch {
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
    if (parsed.help or parsed.missing() != null or std.mem.eql(u8, parsed.get("settings") orelse "", "-")) return error.UnsupportedHostConfiguration;
    try host_start.validateRestartOptions(allocator, &parsed);
    // Relaunch appends one authoritative capacity assignment. Refuse before
    // disruption when the target parser would have no repeat slot for it.
    if (parsed.repeat_count == parsed.repeats.len) return error.UnsupportedHostConfiguration;
    var options: std.ArrayList(LaunchOption) = .empty;
    errdefer options.deinit(allocator);
    for (grammar.options) |option| {
        if (std.mem.eql(u8, option.hex_of orelse option.name, "store")) continue;
        if (option.hidden and parsed.hasNamed(option.name)) return error.UnsupportedHostConfiguration;
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
    return std.mem.indexOf(u8, first, "[--store ") != null and std.mem.indexOf(u8, first, "[--set ") != null;
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
    const store = plan.observed.facts.store.slice();
    process.check(cancellation) catch return .cancelled;
    if (plan.version.order(version) == .gt) return .superseded;
    var prepared = PreparedActivation.init(init, allocator, plan, target, cancellation) catch |err| {
        if (err == error.Cancelled) return .cancelled;
        return .{ .unsupported = .configuration_unavailable };
    };
    defer prepared.deinit(allocator);
    if (std.mem.eql(u8, prepared.executable, plan.snapshot.executable)) {
        const current = client.observeHostProcess(io, store, null) catch return .{ .unconfirmed = .verifying };
        if (plan.observed.profile != .current or current.pid != plan.observed.pid or !std.mem.eql(u8, &current.ready.instance, &plan.observed.facts.instance)) return .{ .unconfirmed = .verifying };
        return .{ .already_ready = .{ .instance = current.ready.instance, .pid = current.pid } };
    }
    process.check(cancellation) catch return .cancelled;
    if (client.hostLockState(io, store) != .free) {
        const current = client.observeHostForUpgradeProfile(io, store, plan.observed.profile, null) catch return .{ .unconfirmed = .stopping };
        if (!sameHost(plan.observed, current)) return .replacement_observed;
        var fresh = identity.snapshot(allocator, current.pid) catch return .{ .unconfirmed = .stopping };
        defer fresh.deinit(allocator);
        if (!sameSnapshot(&plan.snapshot, &fresh)) return .{ .unsupported = .configuration_unavailable };
        Progress.send(progress, .stopping);
        const stopped = stopObserved(io, allocator, plan) catch {
            if (client.hostLockState(io, store) != .free) {
                if (client.observeHostForUpgrade(io, store, null)) |replacement| {
                    if (!sameHost(plan.observed, replacement)) return .replacement_observed;
                } else |_| {}
                return .{ .unconfirmed = .stopping };
            }
            return startPinned(init, allocator, plan, &prepared, version, progress);
        };
        switch (stopped) {
            .instance_changed => return .replacement_observed,
            .unavailable => if (client.hostLockState(io, store) != .free) return .{ .unconfirmed = .stopping },
            .acknowledged => {},
        }
        Progress.send(progress, .awaiting_retirement);
        if (!try awaitRetirement(io, store)) {
            if (client.observeHostForUpgrade(io, store, null)) |replacement| {
                if (!sameHost(plan.observed, replacement)) return .replacement_observed;
            } else |_| {}
            return .{ .unconfirmed = .awaiting_retirement };
        }
    }
    return startPinned(init, allocator, plan, &prepared, version, progress);
}

fn stopObserved(io: std.Io, allocator: std.mem.Allocator, plan: *const Plan) !client.HostStopResult {
    const store = plan.observed.facts.store.slice();
    if (plan.observed.profile.historical()) {
        const instance = std.fmt.bytesToHex(plan.observed.facts.instance, .lower);
        const result = try process.runWithTimeout(allocator, io, &.{ plan.snapshot.executable, "host", "pause", "--store", store, "--instance", &instance }, null, 8192, .fromSeconds(product_defaults.host_shutdown_seconds + 5));
        defer process.dispose(allocator, result);
        if (!result.term.success()) return error.UpgradeChildFailed;
        return .acknowledged;
    }
    var reply: client.ReplyBuffer = .{};
    return client.stopHost(io, .{ .store = store, .instance = plan.observed.facts.instance }, &reply);
}

const PreparedActivation = struct {
    executable: [:0]u8,
    helper: [:0]u8,
    buffers: ?PrivateLaunch,

    fn init(process_init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, target: []const u8, cancellation: ?*const client.Cancellation) !PreparedActivation {
        if (plan.observed.profile.historical()) {
            const stop_help = try process.output(allocator, process_init.io, &.{ plan.snapshot.executable, "host", "pause", "--help" }, cancellation, 32768);
            defer allocator.free(stop_help);
            const first = stop_help[0 .. std.mem.indexOfScalar(u8, stop_help, '\n') orelse stop_help.len];
            if (std.mem.indexOf(u8, first, "[--instance ") == null or std.mem.indexOf(u8, first, "[--store ") == null) return error.UnsupportedHostConfiguration;
        }
        const target_path = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{target});
        defer allocator.free(target_path);
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(process_init.io, target_path, allocator);
        defer allocator.free(resolved);
        const executable = try allocator.dupeSentinel(u8, resolved, 0);
        errdefer allocator.free(executable);
        const help = try process.output(allocator, process_init.io, &.{ executable, "host", "serve", "--help" }, cancellation, 32768);
        defer allocator.free(help);
        if (!supportedByHelp(&plan.launch, help)) return error.UnsupportedHostConfiguration;
        const helper = try std.process.executablePathAlloc(process_init.io, allocator);
        errdefer allocator.free(helper);
        const buffers = try PrivateLaunch.init(allocator, executable, plan.launch.options, plan.observed.facts.store.slice(), plan.observed.facts.active_capacity, plan.snapshot.environment);
        return .{ .executable = executable, .helper = helper, .buffers = buffers };
    }

    fn releaseBuffers(self: *PreparedActivation, allocator: std.mem.Allocator) void {
        if (self.buffers) |*buffers| buffers.deinit(allocator);
        self.buffers = null;
    }

    fn deinit(self: *PreparedActivation, allocator: std.mem.Allocator) void {
        self.releaseBuffers(allocator);
        allocator.free(self.helper);
        allocator.free(self.executable);
    }
};

extern "c" fn rui_launch_pinned(helper: [*:0]const u8, executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, envp: [*:null]const ?[*:0]const u8, startup_read: *c_int, launched_pid: *c_int, launched_started: *c_ulonglong) c_int;

const PrivateLaunch = struct {
    storage: []u8,
    pointers: []?[*:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, executable: []const u8, options: []const LaunchOption, store: []const u8, active_capacity: usize, environment: []const []const u8) !PrivateLaunch {
        var capacity_buffer: [128]u8 = undefined;
        const capacity = try host_start.capacityAssignment(active_capacity, &capacity_buffer);
        // Replay overrides first; the observed capacity is authoritative last.
        const arguments = [_][]const u8{ executable, "host", "serve", "--store", store, "--set", capacity };
        var argc: usize = arguments.len;
        var byte_count: usize = 0;
        for (arguments) |argument| {
            byte_count = try addSize(byte_count, try addSize(argument.len, 1));
        }
        for (options) |option| {
            argc = try addSize(argc, 1);
            byte_count = try addSize(byte_count, try addSize(option.name.len, 3));
            if (option.value) |value| {
                argc = try addSize(argc, 1);
                byte_count = try addSize(byte_count, try addSize(value.len, 1));
            }
        }
        for (environment) |entry| {
            byte_count = try addSize(byte_count, try addSize(entry.len, 1));
        }
        const pointer_count = try addSize(try addSize(argc, environment.len), 2);
        const pointers = try allocator.alloc(?[*:0]const u8, pointer_count);
        errdefer wipeAllocation(?[*:0]const u8, allocator, pointers);
        const storage = try allocator.alloc(u8, byte_count);
        @memset(pointers, null);
        var result: PrivateLaunch = .{
            .storage = storage,
            .pointers = pointers,
            .argv = pointers[0..argc :null],
            .envp = pointers[argc + 1 .. pointer_count - 1 :null],
        };
        var slot: usize = 0;
        var offset: usize = 0;
        for (arguments[0..3]) |argument| result.put(&slot, &offset, "", argument);
        for (options) |option| {
            result.put(&slot, &offset, "--", option.name);
            if (option.value) |value| result.put(&slot, &offset, "", value);
        }
        for (arguments[3..]) |argument| result.put(&slot, &offset, "", argument);
        std.debug.assert(slot == argc);
        slot += 1;
        for (environment) |entry| result.put(&slot, &offset, "", entry);
        std.debug.assert(slot == pointer_count - 1 and offset == storage.len);
        return result;
    }

    fn addSize(left: usize, right: usize) error{OutOfMemory}!usize {
        return std.math.add(usize, left, right) catch error.OutOfMemory;
    }

    fn put(self: *PrivateLaunch, slot: *usize, offset: *usize, prefix: []const u8, value: []const u8) void {
        const start = offset.*;
        @memcpy(self.storage[start..][0..prefix.len], prefix);
        @memcpy(self.storage[start + prefix.len ..][0..value.len], value);
        offset.* += prefix.len + value.len;
        self.storage[offset.*] = 0;
        self.pointers[slot.*] = self.storage[start..offset.* :0].ptr;
        offset.* += 1;
        slot.* += 1;
    }

    fn wipeAllocation(comptime T: type, allocator: std.mem.Allocator, allocation: []T) void {
        const bytes = std.mem.sliceAsBytes(allocation);
        std.crypto.secureZero(u8, bytes);
        allocator.rawFree(bytes, .of(T), @returnAddress());
    }

    fn deinit(self: *PrivateLaunch, allocator: std.mem.Allocator) void {
        wipeAllocation(u8, allocator, self.storage);
        wipeAllocation(?[*:0]const u8, allocator, self.pointers);
        self.* = undefined;
    }
};

fn startPinned(init: std.process.Init, allocator: std.mem.Allocator, plan: *const Plan, prepared: *PreparedActivation, version: candidate.Version, progress: ?Progress) !ActivationOutcome {
    const io = init.io;
    const store = plan.observed.facts.store.slice();
    if (client.hostLockState(io, store) != .free) return .replacement_observed;
    var startup_read: c_int = -1;
    var launched_pid: c_int = -1;
    var launched_started: c_ulonglong = 0;
    Progress.send(progress, .starting);
    const buffers = &prepared.buffers.?;
    const launched = rui_launch_pinned(prepared.helper.ptr, prepared.executable.ptr, buffers.argv.ptr, buffers.argv.len, buffers.envp.ptr, &startup_read, &launched_pid, &launched_started);
    prepared.releaseBuffers(allocator);
    defer if (startup_read >= 0) {
        _ = std.c.close(startup_read);
    };
    if (launched != 0 or launched_pid <= 0 or launched_started == 0) return .{ .failed = .starting };
    Progress.send(progress, .verifying);
    // A Host of a newer release may first back up and migrate the Store.
    var wait = HostStartupWait.init(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
    var startup: [8192]u8 = undefined;
    var used: usize = 0;
    while (!wait.expired(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds)) {
        if (used < startup.len) {
            const n = std.c.read(startup_read, startup[used..].ptr, startup.len - used);
            if (n > 0) used += @intCast(n);
            if (n == 0 and client.hostLockState(io, store) == .free) return .{ .failed = .starting };
        }
        wait.observe(startup[0..used], std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
        const until = wait.until(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
        if (client.observeHostProcessForUpgrade(io, store, until)) |reading| {
            if (reading.pid() != launched_pid) return .replacement_observed;
            var snapshot = identity.snapshot(allocator, reading.pid()) catch return .{ .unconfirmed = .verifying };
            defer snapshot.deinit(allocator);
            const activation = activationReading(reading, launched_pid, launched_started, &snapshot, prepared.executable, plan.observed.facts.active_capacity);
            if (activation != .ready and activation != .client_incompatible) return activation;
            const reported = process.output(allocator, io, &.{ prepared.executable, "--version" }, null, 512) catch return .{ .unconfirmed = .verifying };
            defer allocator.free(reported);
            if (releaseVersion(reported)) |actual| {
                if (actual.order(version) != .eq) return .{ .unconfirmed = .verifying };
            } else return .{ .unconfirmed = .verifying };
            return activation;
        } else |_| {}
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining > 0) try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 50 * std.time.ns_per_ms))), .awake);
    }
    return .{ .unconfirmed = .verifying };
}

/// Both wire-compatible and wire-incompatible replies require the same pinned
/// launch identity. A mismatch never grants ordinary Host request readiness.
fn activationReading(reading: client.HostProcessReading, launched_pid: c_int, launched_started: u64, snapshot: *const identity.Snapshot, executable: []const u8, capacity: usize) ActivationOutcome {
    if (reading.pid() != launched_pid) return .replacement_observed;
    if (!matchesLaunch(launched_pid, launched_started, snapshot, executable)) return .{ .unconfirmed = .verifying };
    return switch (reading) {
        .incompatible => |pid| .{ .client_incompatible = pid },
        .ready => |observed| if (observed.ready.active_capacity != capacity)
            .{ .unconfirmed = .verifying }
        else
            .{ .ready = .{ .instance = observed.ready.instance, .pid = observed.pid } },
    };
}

fn matchesLaunch(pid: c_int, started: u64, snapshot: *const identity.Snapshot, executable: []const u8) bool {
    return pid > 0 and started != 0 and snapshot.pid == pid and snapshot.started == started and std.mem.eql(u8, snapshot.executable, executable);
}

test "upgrade private launch buffers wipe argv environment and sentinels on every construction exit" {
    const Capturing = struct {
        backing: std.mem.Allocator,
        allocations: usize = 0,
        frees: usize = 0,
        allocated_bytes: usize = 0,
        freed_bytes: usize = 0,
        dirty_free: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }

        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const memory = self.backing.rawAlloc(len, alignment, ret) orelse return null;
            @memset(memory[0..len], 0xa5);
            self.allocations += 1;
            self.allocated_bytes += len;
            return memory;
        }

        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.allEqual(u8, memory, 0)) self.dirty_free = true;
            self.frees += 1;
            self.freed_bytes += memory.len;
            self.backing.rawFree(memory, alignment, ret);
        }

        fn expectWiped(self: *const @This()) !void {
            try std.testing.expectEqual(false, self.dirty_free);
            try std.testing.expectEqual(self.allocations, self.frees);
            try std.testing.expectEqual(self.allocated_bytes, self.freed_bytes);
        }

        fn exercise(gpa: std.mem.Allocator, environment: []const []const u8, fail_after_construction: bool) !void {
            const endpoint = "https://example.test/v1?token=synthetic-launch-only";
            const options = [_]LaunchOption{
                .{ .name = "set", .value = endpoint },
                .{ .name = "synthetic-flag", .value = null },
                .{ .name = "synthetic-empty", .value = "" },
            };
            var buffers = try PrivateLaunch.init(gpa, "/synthetic/bin/rui", &options, "/synthetic/private-store", 17, environment);
            defer buffers.deinit(gpa);
            var capacity_buffer: [128]u8 = undefined;
            const capacity = try host_start.capacityAssignment(17, &capacity_buffer);
            const expected = [_][]const u8{ "/synthetic/bin/rui", "host", "serve", "--set", endpoint, "--synthetic-flag", "--synthetic-empty", "", "--store", "/synthetic/private-store", "--set", capacity };
            try std.testing.expectEqual(expected.len, buffers.argv.len);
            try std.testing.expectEqual(environment.len, buffers.envp.len);
            for (expected, buffers.argv) |argument, pointer| {
                try std.testing.expectEqualStrings(argument, std.mem.span(pointer.?));
                try std.testing.expect(@intFromPtr(pointer.?) >= @intFromPtr(buffers.storage.ptr));
                try std.testing.expect(@intFromPtr(pointer.?) + argument.len < @intFromPtr(buffers.storage.ptr) + buffers.storage.len);
            }
            for (environment, buffers.envp) |entry, pointer| try std.testing.expectEqualStrings(entry, std.mem.span(pointer.?));
            try std.testing.expect(buffers.argv[buffers.argv.len] == null);
            try std.testing.expect(buffers.envp[buffers.envp.len] == null);
            try std.testing.expectEqual(buffers.argv.len + buffers.envp.len + 2, buffers.pointers.len);
            try std.testing.expect(std.mem.indexOf(u8, buffers.storage, endpoint) != null);
            if (environment.len > 0) try std.testing.expect(std.mem.indexOf(u8, buffers.storage, environment[0]) != null);
            if (fail_after_construction) return error.SyntheticLaunchFailure;
        }
    };
    const environment: []const []const u8 = &.{ "RUI_PRIVATE=synthetic-only", "EMPTY=" };
    for ([_]bool{ false, true }) |arena_backed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const backing = if (arena_backed) arena.allocator() else std.testing.allocator;
        for ([_]bool{ false, true }) |fail_after_construction| {
            for ([_][]const []const u8{ &.{}, environment }) |entries| {
                var capture: Capturing = .{ .backing = backing };
                if (fail_after_construction) {
                    try std.testing.expectError(error.SyntheticLaunchFailure, Capturing.exercise(capture.allocator(), entries, true));
                } else {
                    try Capturing.exercise(capture.allocator(), entries, false);
                }
                try std.testing.expectEqual(@as(usize, 2), capture.allocations);
                try capture.expectWiped();
            }
        }
        var successful: Capturing = .{ .backing = backing };
        try Capturing.exercise(successful.allocator(), environment, false);
        try successful.expectWiped();
        for (0..successful.allocations) |fail_index| {
            var capture: Capturing = .{ .backing = backing };
            var failing: std.testing.FailingAllocator = .init(capture.allocator(), .{ .fail_index = fail_index });
            try std.testing.expectError(error.OutOfMemory, Capturing.exercise(failing.allocator(), environment, false));
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(fail_index, capture.allocations);
            try capture.expectWiped();
        }
    }
}

test "upgrade launch identity rejects same PID with a replacement generation" {
    const snapshot: identity.Snapshot = .{ .pid = 42, .started = 12, .executable = "/pinned/rui", .argv = &.{}, .environment = &.{}, .storage = &.{}, .entries = &.{} };
    try std.testing.expect(matchesLaunch(42, 12, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 11, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 0, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(43, 12, &snapshot, "/pinned/rui"));
    try std.testing.expect(!matchesLaunch(42, 12, &snapshot, "/other/rui"));
}

test "relaunch activation reading requires the pinned launch for either wire" {
    const good: identity.Snapshot = .{ .pid = 42, .started = 12, .executable = "/pinned/rui", .argv = &.{}, .environment = &.{}, .storage = &.{}, .entries = &.{} };
    for ([_]bool{ false, true }) |incompatible| {
        for (0..6) |fault| {
            var snapshot = good;
            var reading: client.HostProcessReading = if (incompatible) .{ .incompatible = 42 } else .{ .ready = .{ .pid = 42, .ready = .{
                .store = .{},
                .instance = @splat(1),
                .active_capacity = 17,
                .started_at = 1,
                .custody_occupied = 0,
                .paused = false,
                .capabilities = .{ .bash = false, .providers = .{ .codex = .unserved, .openai = .unserved, .chatgpt = .unserved } },
            } } };
            switch (fault) {
                0 => {},
                1 => if (incompatible) {
                    reading.incompatible = 43;
                } else {
                    reading.ready.pid = 43;
                },
                2 => snapshot.pid = 43,
                3 => snapshot.started = 13,
                4 => snapshot.executable = "/other/rui",
                5 => if (!incompatible) {
                    reading.ready.ready.active_capacity = 18;
                },
                else => unreachable,
            }
            const result = activationReading(reading, 42, 12, &snapshot, "/pinned/rui", 17);
            const expected: std.meta.Tag(ActivationOutcome) = if (fault == 1) .replacement_observed else if (fault >= 2 and fault <= 4 or (fault == 5 and !incompatible)) .unconfirmed else if (incompatible) .client_incompatible else .ready;
            try std.testing.expectEqual(expected, std.meta.activeTag(result));
        }
    }
}

test "upgrade lifecycle derives launch semantics before disruption" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedHostConfiguration, deriveLaunch(allocator, &.{ "rui", "host", "serve", "--settings", "-" }));
    for ([_][]const []const u8{
        &.{ "rui", "session", "start" },
        &.{ "rui", "host", "serve", "--test-observation-fd", "8" },
        &.{ "rui", "host", "serve", "--set", "missing-equals" },
        &.{ "rui", "host", "serve", "--unknown-new-option", "value" },
    }) |args| {
        if (deriveLaunch(allocator, args)) |*result| {
            result.deinit(allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    var first_buffer: [128]u8 = undefined;
    var last_buffer: [128]u8 = undefined;
    const first = try host_start.capacityAssignment(3, &first_buffer);
    const last = try host_start.capacityAssignment(5, &last_buffer);
    for ([_][]const u8{ "--store", "--store-hex" }, [_][]const u8{ "/some/store", "2f736f6d652f73746f7265" }) |spelling, value| {
        var launch = try deriveLaunch(allocator, &.{ "rui", "host", "serve", spelling, value, "--set", first, "--set", last });
        defer launch.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), launch.options.len);
        try std.testing.expectEqualStrings("set", launch.options[0].name);
        try std.testing.expectEqualStrings(first, launch.options[0].value.?);
        try std.testing.expectEqualStrings("set", launch.options[1].name);
        try std.testing.expectEqualStrings(last, launch.options[1].value.?);
        try std.testing.expect(supportedByHelp(&launch, "rui host serve [--store PATH] [--set PATH=VALUE]\n"));
        try std.testing.expect(!supportedByHelp(&launch, "rui host serve [--store PATH]\n"));
    }
    const repeat_limit = @as(cli_args.Parsed, undefined).repeats.len;
    var full: [3 + 2 * repeat_limit][]const u8 = undefined;
    @memcpy(full[0..3], &[_][]const u8{ "rui", "host", "serve" });
    for (0..repeat_limit) |index| {
        full[3 + 2 * index] = "--set";
        full[4 + 2 * index] = first;
    }
    try std.testing.expectError(error.UnsupportedHostConfiguration, deriveLaunch(allocator, &full));
    var almost_full = try deriveLaunch(allocator, full[0 .. full.len - 2]);
    defer almost_full.deinit(allocator);
    try std.testing.expectEqual(repeat_limit - 1, almost_full.options.len);
    // File-backed documents, unlike an exhausted stdin document, retain
    // the same argv replay and help-admission behavior as ordinary flags.
    for ([_][]const u8{ "/private/host.json", "relative/host.json" }) |file| {
        var launch = try deriveLaunch(allocator, &.{ "rui", "host", "serve", "--settings", file });
        defer launch.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), launch.options.len);
        try std.testing.expectEqualStrings("settings", launch.options[0].name);
        try std.testing.expectEqualStrings(file, launch.options[0].value.?);
        try std.testing.expect(supportedByHelp(&launch, "rui host serve [--store PATH] [--set PATH=VALUE] [--settings FILE|-]\n"));
        try std.testing.expect(!supportedByHelp(&launch, "rui host serve [--store PATH] [--set PATH=VALUE]\n"));
    }
    try std.testing.expect(!restartableEnvironment(&.{"SSL_CERT_FILE=relative.pem"}));
    try std.testing.expect(!restartableEnvironment(&.{"SSL_CERT_DIR=/absolute:relative"}));
    try std.testing.expect(!restartableEnvironment(&.{"DYLD_LIBRARY_PATH=/custom"}));
    try std.testing.expect(restartableEnvironment(&.{ "HOME=/home/fixture", "SSL_CERT_DIR=/one:/two", "PRIVATE=synthetic-only" }));
    try std.testing.expect(releaseVersion("rui unreleased (abc)\n") == null);
    try std.testing.expectEqual(@as(u32, 56), releaseVersion("rui 0.56.4 (abc)\n").?.schema);
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
