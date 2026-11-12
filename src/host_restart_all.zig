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

const Target = struct {
    build: []const u8,
    version: release.Version,

    fn init(process_init: std.process.Init, allocator: std.mem.Allocator, home: []const u8) !Target {
        var selected = try Installation.inspect(allocator, process_init.io, home);
        errdefer selected.deinit(allocator);
        switch (selected) {
            .released => |value| return .{ .build = value.build, .version = value.version },
            .source => |build| {
                const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{build});
                defer allocator.free(binary);
                const reported = try process.output(allocator, process_init.io, &.{ binary, "--version" }, null, 512);
                defer allocator.free(reported);
                // The existing lifecycle verifies a numeric release identity before
                // claiming readiness. Never invent one for an unreleased source build.
                const version = HostLifecycle.releaseVersion(reported) orelse return error.IneligibleInstallation;
                return .{ .build = build, .version = version };
            },
            else => return error.IneligibleInstallation,
        }
    }

    fn deinit(self: Target, allocator: std.mem.Allocator) void {
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

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const sockets = try platform.listHostSockets(allocator, init.io);
    defer {
        for (sockets) |socket| allocator.free(socket);
        allocator.free(sockets);
    }
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    var totals: Totals = .{};
    var target: ?Target = null;
    defer if (target) |value| value.deinit(allocator);
    // One observation and activation at a time: no concurrent Store interruption.
    for (sockets) |socket| {
        const discovered = client.observeHostForUpgradeAtSocket(allocator, init.io, socket, null) catch {
            // No verified Store means no lock-backed proof of absence. Even a
            // refused or removed socket must be reported, not silently skipped.
            try writer.writeAll("Store unknown (socket ");
            try field(writer, socket);
            try writer.writeAll("): failed at discovery: Host state is unconfirmed; inspect this socket and its Store with the owning client, then retry. A refused or missing socket alone does not prove the Host stopped.\n");
            totals.add(.failed);
            try output.flush();
            continue;
        } orelse continue; // Only a trusted Store hint and free lease prove absence.
        const store = discovered.facts.store.slice();
        const home = init.environ_map.get("HOME") orelse {
            try writeFailure(writer, store, "selection", "HOME is unavailable; restore it and retry.");
            totals.add(.failed);
            try output.flush();
            continue;
        };
        var observation = HostLifecycle.observe(allocator, init.io, home, store, null) catch {
            try writeFailure(writer, store, "observation", "could not confirm this Host; inspect with its owning client, then retry.");
            totals.add(.failed);
            try output.flush();
            continue;
        };
        defer observation.deinit(allocator);
        // A limitation needs no installed target and grants no activation plan.
        // Keep unsupported Hosts a successful, explained skip even on a source
        // install whose target cannot pass the existing release verifier.
        const inactive: ?HostLifecycle.ActivationOutcome = switch (observation) {
            .absent => .not_needed,
            .unsupported => |reason| .{ .unsupported = reason },
            .managed => null,
        };
        if (inactive) |outcome| {
            totals.add(try writeOutcome(writer, store, outcome, null));
            try output.flush();
            continue;
        }
        if (target == null) {
            target = Target.init(init, allocator, home) catch {
                try writeFailure(writer, store, "selection", "selected installed build has no verified release version; install a managed release and retry.");
                totals.add(.failed);
                try output.flush();
                continue;
            };
        }

        const outcome: HostLifecycle.ActivationOutcome = outcome: {
            // Discovery authorizes no mutation. The lifecycle must have observed
            // the same exact Host before we hand it the activation request.
            {
                const current = observation.managed.observed;
                if (current.pid != discovered.pid or
                    !std.mem.eql(u8, &current.facts.instance, &discovered.facts.instance) or
                    !std.mem.eql(u8, current.facts.store.slice(), store)) break :outcome .replacement_observed;
            }
            break :outcome HostLifecycle.activate(init, allocator, &observation, target.?.build, target.?.version, null, null) catch .{ .unconfirmed = .starting };
        };
        totals.add(try writeOutcome(writer, store, outcome, target.?.version));
        try output.flush();
    }
    try totals.write(writer);
    try output.flush();
    if (totals.failed != 0) return error.HostRestartFailed;
}

fn field(writer: *std.Io.Writer, text: []const u8) !void {
    var terminal: TerminalText = .{ .mode = .line };
    try terminal.feed(writer, text);
    try terminal.finish(writer);
}

fn writeFailure(writer: *std.Io.Writer, store: []const u8, stage: []const u8, remedy: []const u8) !void {
    try field(writer, store);
    try writer.print(": failed at {s}: {s}\n", .{ stage, remedy });
}

/// Pure reporting policy over the lifecycle's own values, not a mirrored union.
/// Returning the category from the same switch keeps line and exit truth together.
fn writeOutcome(writer: *std.Io.Writer, store: []const u8, outcome: HostLifecycle.ActivationOutcome, version: ?release.Version) !Result {
    try field(writer, store);
    try writer.writeAll(": ");
    const result: Result = switch (outcome) {
        .ready => result: {
            try writer.print("restarted on 0.{d}.{d}", .{ version.?.schema, version.?.patch });
            break :result .restarted;
        },
        .client_incompatible => result: {
            // The lifecycle verified the exact pinned launch and version, not
            // ordinary readiness. Preserve that certainty and name the limit.
            try writer.print("restarted on 0.{d}.{d}; different Host protocol; inspect with the selected Rui client", .{ version.?.schema, version.?.patch });
            break :result .restarted;
        },
        .already_ready => result: {
            try writer.print("already on 0.{d}.{d}", .{ version.?.schema, version.?.patch });
            break :result .current;
        },
        .superseded => result: {
            try writer.print("left running: newer than 0.{d}.{d}; no downgrade", .{ version.?.schema, version.?.patch });
            break :result .skipped;
        },
        .not_needed => result: {
            try writer.writeAll("no longer running; no Host started");
            break :result .skipped;
        },
        .unsupported => |limitation| result: {
            try writer.print("left running: {s}", .{switch (limitation) {
                .inaccessible => "Store or Host is inaccessible; check access with its owning client",
                .incompatible => "Host protocol is unsupported; use its owning client",
                .ownership_unconfirmed => "ownership is unconfirmed; do not stop a guessed Host",
                .application_owned => "application-owned Host (including MySQL); restart through its application",
                .configuration_unavailable => "launch configuration cannot be safely reconstructed; restart through its owner",
            }});
            break :result .skipped;
        },
        .replacement_observed => result: {
            try writer.writeAll("failed at verifying: a replacement Host was observed; inspect with its owning client, then retry");
            break :result .failed;
        },
        .cancelled => result: {
            try writer.writeAll("failed at activation: cancelled; inspect Host status, then retry");
            break :result .failed;
        },
        .failed, .unconfirmed => |stage| result: {
            try writer.print("failed at {s}: {s}; inspect Host status with its owning client, then retry", .{ @tagName(stage), if (outcome == .failed) "restart failed" else "restart is unconfirmed" });
            break :result .failed;
        },
    };
    try writer.writeByte('\n');
    return result;
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
