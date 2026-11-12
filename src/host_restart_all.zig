//! Restart-all composes discovery, installed selection and the existing exact-instance
//! lifecycle. No registry, launch policy or activation state is kept here.
const std = @import("std");
const client = @import("client.zig");
const platform = @import("platform.zig");
const HostLifecycle = @import("HostLifecycle.zig");
const Installation = @import("Installation.zig");
const release = @import("release_candidate.zig");
const process = @import("upgrade_process.zig");
const TerminalText = @import("TerminalText.zig");

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
};

const Result = enum { restarted, current, skipped, failed };
const Totals = struct {
    restarted: usize = 0,
    current: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,

    fn add(self: *Totals, result: Result) void {
        switch (result) {
            .restarted => self.restarted += 1,
            .current => self.current += 1,
            .skipped => self.skipped += 1,
            .failed => self.failed += 1,
        }
    }

    fn write(self: Totals, writer: *std.Io.Writer) !void {
        const total = self.restarted + self.current + self.skipped + self.failed;
        if (total == 0) return writer.writeAll("No running Hosts.\n");
        try writer.print("{d} Hosts: {d} restarted, {d} already current, {d} left unchanged, {d} failed.\n", .{ total, self.restarted, self.current, self.skipped, self.failed });
    }
};

pub const Failure = enum { discovery, observation, selection };
pub const Entry = struct {
    socket: []const u8,
    store: ?[]const u8 = null,
    state: union(enum) {
        /// Read-only census, never an activation plan. Reobserve before acting.
        observed: client.HostControlObservation,
        outcome: HostLifecycle.ActivationOutcome,
        failed: Failure,
    },
};

/// Owns only routing strings and read-only facts, not private launch snapshots.
/// A census has observed entries; execution replaces each with its one outcome.
pub const Batch = struct {
    entries: []Entry = &.{},
    version: ?release.Version = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.socket);
            if (entry.store) |store| allocator.free(store);
        }
        allocator.free(self.entries);
        self.* = .{};
    }

    pub fn selectedOutcome(self: *const Batch, store: []const u8) HostLifecycle.ActivationOutcome {
        var unknown = self.failure != null;
        for (self.entries) |entry| {
            const path = entry.store orelse {
                unknown = true;
                continue;
            };
            if (!std.mem.eql(u8, path, store)) continue;
            return switch (entry.state) {
                .outcome => |outcome| outcome,
                .failed, .observed => .{ .unconfirmed = .verifying },
            };
        }
        if ((self.failure orelse error.Unexpected) == error.Cancelled) return .cancelled;
        return if (unknown) .{ .unconfirmed = .verifying } else .not_needed;
    }

    pub fn hasGuidance(self: *const Batch) bool {
        if (self.failure != null) return true;
        for (self.entries) |entry| switch (entry.state) {
            .failed => return true,
            .observed => unreachable,
            .outcome => |outcome| switch (outcome) {
                .unsupported, .replacement_observed, .cancelled, .failed, .unconfirmed => return true,
                .not_needed, .superseded, .already_ready, .ready, .client_incompatible => {},
            },
        };
        return false;
    }

    pub fn totals(self: *const Batch) Totals {
        var result: Totals = .{};
        if (self.failure != null) result.add(.failed);
        for (self.entries) |entry| switch (entry.state) {
            .observed => unreachable,
            .failed => result.add(.failed),
            .outcome => |outcome| result.add(category(outcome)),
        };
        return result;
    }

    pub fn write(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.failure) |err| try writer.print("Host restart could not finish ({s}); inspect this user's Hosts with their owning clients, then retry.\n", .{@errorName(err)});
        for (self.entries) |entry| switch (entry.state) {
            .observed => unreachable,
            .failed => |stage| try writeEntryFailure(writer, &entry, stage),
            .outcome => |outcome| _ = try writeOutcome(writer, entry.store.?, outcome, self.version),
        };
        try self.totals().write(writer);
    }

    pub fn writeWarning(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.entries.len == 0 and self.failure == null) return writer.writeAll("No running Hosts discovered now; Hosts running after publication will also be considered.\n");
        try writer.print("Upgrade restarts every running Host it can safely activate, interrupting work across ALL Sessions in those Stores. Discovered {d} Hosts:\n", .{self.entries.len});
        for (self.entries) |entry| switch (entry.state) {
            .observed => {
                try field(writer, entry.store.?);
                try writer.writeAll(": running; will restart on the selected installed build\n");
            },
            .outcome => |outcome| _ = try writeOutcome(writer, entry.store.?, outcome, self.version),
            .failed => |stage| try writeEntryFailure(writer, &entry, stage),
        };
    }
};

/// One discovery owner for the pre-install warning and post-publication run.
/// Eligibility is read-only here; no launch snapshot survives the census.
pub fn discover(init: std.process.Init, allocator: std.mem.Allocator, home: []const u8, cancellation: ?*const client.Cancellation) !Batch {
    const sockets = try platform.listHostSockets(allocator, init.io);
    defer {
        for (sockets) |socket| allocator.free(socket);
        allocator.free(sockets);
    }
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.socket);
            if (entry.store) |store| allocator.free(store);
        }
        entries.deinit(allocator);
    }
    for (sockets) |socket| {
        try process.check(cancellation);
        const facts = client.observeHostForUpgradeAtSocket(allocator, init.io, socket, null) catch {
            const path = try allocator.dupe(u8, socket);
            errdefer allocator.free(path);
            try entries.append(allocator, .{ .socket = path, .state = .{ .failed = .discovery } });
            continue;
        } orelse continue;
        const path = try allocator.dupe(u8, socket);
        errdefer allocator.free(path);
        const store = try allocator.dupe(u8, facts.facts.store.slice());
        errdefer allocator.free(store);
        const state: @FieldType(Entry, "state") = state: {
            var observation = HostLifecycle.observe(allocator, init.io, home, store, cancellation) catch break :state .{ .failed = .observation };
            defer observation.deinit(allocator);
            break :state switch (observation) {
                .absent => .{ .outcome = .not_needed },
                .unsupported => |reason| .{ .outcome = .{ .unsupported = reason } },
                .managed => .{ .observed = facts },
            };
        };
        try entries.append(allocator, .{ .socket = path, .store = store, .state = state });
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub const Options = struct {
    home: []const u8,
    target: ?*const Target = null,
    cancellation: ?*const client.Cancellation = null,
    progress: ?HostLifecycle.Progress = null,
};

pub fn restart(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Batch {
    var batch = try discover(init, allocator, options.home, options.cancellation);
    errdefer batch.deinit(allocator);
    var selected: ?Target = null;
    defer if (selected) |target| target.deinit(allocator);
    if (options.target) |target| batch.version = target.version;
    for (batch.entries) |*entry| {
        if (entry.state != .observed) continue;
        const facts = entry.state.observed;
        entry.state = .{ .outcome = outcome: {
            process.check(options.cancellation) catch break :outcome .cancelled;
            var observation = HostLifecycle.observe(allocator, init.io, options.home, entry.store.?, options.cancellation) catch {
                entry.state = .{ .failed = .observation };
                continue;
            };
            defer observation.deinit(allocator);
            switch (observation) {
                .absent => break :outcome .not_needed,
                .unsupported => |reason| break :outcome .{ .unsupported = reason },
                .managed => {},
            }
            if (options.target == null and selected == null) {
                selected = Target.init(init, allocator, options.home, null, options.cancellation) catch {
                    entry.state = .{ .failed = .selection };
                    continue;
                };
                batch.version = selected.?.version;
            }
            const target = options.target orelse &selected.?;
            const current = observation.managed.observed;
            if (current.pid != facts.pid or !std.mem.eql(u8, &current.facts.instance, &facts.facts.instance) or
                !std.mem.eql(u8, current.facts.store.slice(), entry.store.?)) break :outcome .replacement_observed;
            break :outcome HostLifecycle.activate(init, allocator, &observation, target.build, target.version, options.cancellation, options.progress) catch .{ .unconfirmed = .starting };
        } };
    }
    return batch;
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    var batch = restart(init, allocator, .{ .home = home }) catch |err| Batch{ .failure = err };
    defer batch.deinit(allocator);
    var buffer: [2048]u8 = undefined;
    var output = OptionalOutput.init(init.io, .stdout(), &buffer);
    try batch.write(&output.writer);
    try output.writer.flush();
    if (batch.totals().failed != 0) return error.HostRestartFailed;
}

fn writeEntryFailure(writer: *std.Io.Writer, entry: *const Entry, stage: Failure) !void {
    if (entry.store) |store| return writeFailure(writer, store, @tagName(stage), switch (stage) {
        .discovery => unreachable,
        .observation => "could not confirm this Host; inspect with its owning client, then retry.",
        .selection => "selected installed build has no verified release version; install a managed release and retry.",
    });
    try writer.writeAll("Store unknown (socket ");
    try field(writer, entry.socket);
    try writer.writeAll("): failed at discovery: Host state is unconfirmed; inspect this socket and its Store with the owning client, then retry. A refused or missing socket alone does not prove the Host stopped.\n");
}

/// Reports are not custody: a departed tool closes stdout, but all remaining
/// Stores must still be processed. Retain each failed write at the existing
/// optional diagnostic boundary, without turning output failure into a stop.
const OptionalOutput = struct {
    io: std.Io,
    destination: std.Io.File,
    writer: std.Io.Writer,

    fn init(io: std.Io, destination: std.Io.File, buffer: []u8) OptionalOutput {
        return .{ .io = io, .destination = destination, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn emit(self: *OptionalOutput, bytes: []const u8) void {
        self.destination.writeStreamingAll(self.io, bytes) catch {
            @import("stderr.zig").diagnosticBytes(bytes);
        };
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *OptionalOutput = @alignCast(@fieldParentPtr("writer", writer));
        self.emit(writer.buffered());
        writer.end = 0;
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            self.emit(part);
            count += part.len;
        }
        for (0..splat) |_| self.emit(parts[parts.len - 1]);
        return count + splat * parts[parts.len - 1].len;
    }
};

fn field(writer: *std.Io.Writer, text: []const u8) !void {
    var terminal: TerminalText = .{ .mode = .line };
    try terminal.feed(writer, text);
    try terminal.finish(writer);
}

fn writeFailure(writer: *std.Io.Writer, store: []const u8, stage: []const u8, remedy: []const u8) !void {
    try field(writer, store);
    try writer.print(": failed at {s}: {s}\n", .{ stage, remedy });
}

/// Pure exit/total policy over the lifecycle's own values, not a mirrored union.
/// Both entry rendering and aggregation call this one classification.
fn category(outcome: HostLifecycle.ActivationOutcome) Result {
    return switch (outcome) {
        .ready, .client_incompatible => .restarted,
        .already_ready => .current,
        .superseded, .not_needed, .unsupported => .skipped,
        .replacement_observed, .cancelled, .failed, .unconfirmed => .failed,
    };
}

fn writeOutcome(writer: *std.Io.Writer, store: []const u8, outcome: HostLifecycle.ActivationOutcome, version: ?release.Version) !Result {
    try field(writer, store);
    try writer.writeAll(": ");
    switch (outcome) {
        .ready => {
            try writer.print("restarted on 0.{d}.{d}", .{ version.?.schema, version.?.patch });
        },
        .client_incompatible => {
            // The lifecycle verified the exact pinned launch and version, not
            // ordinary readiness. Preserve that certainty and name the limit.
            try writer.print("restarted on 0.{d}.{d}; different Host protocol; inspect with the selected Rui client", .{ version.?.schema, version.?.patch });
        },
        .already_ready => {
            try writer.print("already on 0.{d}.{d}", .{ version.?.schema, version.?.patch });
        },
        .superseded => {
            try writer.print("left running: newer than 0.{d}.{d}; no downgrade", .{ version.?.schema, version.?.patch });
        },
        .not_needed => {
            try writer.writeAll("no longer running; no Host started");
        },
        .unsupported => |limitation| {
            try writer.print("left running: {s}", .{switch (limitation) {
                .inaccessible => "Store or Host is inaccessible; check access with its owning client",
                .incompatible => "Host protocol is unsupported; use its owning client",
                .ownership_unconfirmed => "ownership is unconfirmed; do not stop a guessed Host",
                .application_owned => "application-owned Host (including MySQL); restart through its application",
                .configuration_unavailable => "launch configuration cannot be safely reconstructed; restart through its owner",
            }});
        },
        .replacement_observed => {
            try writer.writeAll("failed at verifying: a replacement Host was observed; inspect with its owning client, then retry");
        },
        .cancelled => {
            try writer.writeAll("failed at activation: cancelled; inspect Host status, then retry");
        },
        .failed, .unconfirmed => |stage| {
            try writer.print("failed at {s}: {s}; inspect Host status with its owning client, then retry", .{ @tagName(stage), if (outcome == .failed) "restart failed" else "restart is unconfirmed" });
        },
    }
    try writer.writeByte('\n');
    return category(outcome);
}

test "restart all reports every activation outcome and limitation with exit truth" {
    const identity = .{ .instance = @as([16]u8, @splat(1)), .pid = @as(c_int, 42) };
    const Case = struct { outcome: HostLifecycle.ActivationOutcome, text: []const u8, result: Result };
    const cases = [_]Case{
        .{ .outcome = .{ .ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "restarted on 0.1.2", .result = .restarted },
        .{ .outcome = .{ .client_incompatible = identity.pid }, .text = "restarted on 0.1.2; different Host protocol; inspect with the selected Rui client", .result = .restarted },
        .{ .outcome = .{ .already_ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "already on 0.1.2", .result = .current },
        .{ .outcome = .superseded, .text = "left running: newer than 0.1.2; no downgrade", .result = .skipped },
        .{ .outcome = .not_needed, .text = "no longer running; no Host started", .result = .skipped },
        .{ .outcome = .replacement_observed, .text = "failed at verifying: a replacement Host was observed; inspect with its owning client, then retry", .result = .failed },
        .{ .outcome = .cancelled, .text = "failed at activation: cancelled; inspect Host status, then retry", .result = .failed },
    };
    var covered: std.EnumSet(std.meta.Tag(HostLifecycle.ActivationOutcome)) = .empty;
    for (cases) |case| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(case.result, try writeOutcome(&writer, "/store", case.outcome, .{ .schema = 1, .patch = 2 }));
        var expected: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/store: {s}\n", .{case.text}), writer.buffered());
        covered.insert(std.meta.activeTag(case.outcome));
    }
    const limitations = [_][]const u8{
        "Store or Host is inaccessible; check access with its owning client",
        "Host protocol is unsupported; use its owning client",
        "ownership is unconfirmed; do not stop a guessed Host",
        "application-owned Host (including MySQL); restart through its application",
        "launch configuration cannot be safely reconstructed; restart through its owner",
    };
    inline for (std.meta.tags(HostLifecycle.Limitation), limitations) |limitation, text| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(Result.skipped, try writeOutcome(&writer, "/store", .{ .unsupported = limitation }, .{ .schema = 1, .patch = 2 }));
        try std.testing.expectEqualStrings("/store: left running: " ++ text ++ "\n", writer.buffered());
    }
    covered.insert(.unsupported);
    inline for (.{ .failed, .unconfirmed }) |tag| {
        inline for (std.meta.tags(HostLifecycle.Stage)) |stage| {
            var bytes: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try std.testing.expectEqual(Result.failed, try writeOutcome(&writer, "/store", @unionInit(HostLifecycle.ActivationOutcome, @tagName(tag), stage), .{ .schema = 1, .patch = 2 }));
            const reason = comptime if (tag == .failed) "restart failed" else "restart is unconfirmed";
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/store: failed at {s}: {s}; inspect Host status with its owning client, then retry\n", .{ @tagName(stage), reason }), writer.buffered());
        }
        covered.insert(tag);
    }
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(HostLifecycle.ActivationOutcome)).len, covered.count());
}

test "restart all totals distinguish no Hosts success skips and failures" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try (Totals{}).write(&writer);
    try std.testing.expectEqualStrings("No running Hosts.\n", writer.buffered());
    writer.end = 0;
    var totals: Totals = .{};
    for ([_]Result{ .restarted, .current, .skipped, .failed }) |result| totals.add(result);
    try totals.write(&writer);
    try std.testing.expectEqualStrings("4 Hosts: 1 restarted, 1 already current, 1 left unchanged, 1 failed.\n", writer.buffered());
}

test "restart all counts every outcome even after its output reader closes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    _ = std.c.close(fds[0]);
    const destination: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer destination.close(std.testing.io);
    // Small enough to drive both buffered flush and direct drain/splat paths.
    var buffer: [16]u8 = undefined;
    var output = OptionalOutput.init(std.testing.io, destination, &buffer);
    var totals: Totals = .{};
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const outcome = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        totals.add(try writeOutcome(&output.writer, "/store", outcome, .{ .schema = 1, .patch = 2 }));
        try output.writer.flush();
    }
    try totals.write(&output.writer);
    try output.writer.flush();
    try std.testing.expectEqual(info.field_names.len, totals.restarted + totals.current + totals.skipped + totals.failed);
}
