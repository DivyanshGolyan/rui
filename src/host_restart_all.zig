const std = @import("std");
const client = @import("client.zig");
const HostLifecycle = @import("HostLifecycle.zig");
const activation = @import("host_activation.zig");
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

const Result = activation.Category;
const Totals = activation.Counts;

fn writeTotals(totals: Totals, writer: *std.Io.Writer) !void {
    const total = totals.restarted + totals.current + totals.skipped + totals.failed;
    if (total == 0) return writer.writeAll("No running Hosts.\n");
    try writer.print("{d} Hosts: {d} restarted, {d} already current, {d} left unchanged, {d} failed.\n", .{ total, totals.restarted, totals.current, totals.skipped, totals.failed });
}

pub const Stage = enum { discovery, observation, selection };
pub const Failure = struct {
    stage: Stage,
    cause: []const u8,

    fn of(allocator: std.mem.Allocator, stage: Stage, err: anyerror) !Failure {
        return .{ .stage = stage, .cause = try allocator.dupe(u8, @errorName(err)) };
    }
};
pub const Entry = struct {
    socket: ?[]const u8 = null,
    /// Persistent local routing selector; never replace it with wire Store identity.
    directory: ?[]const u8 = null,
    /// Explains a positively identified Host whose sources could not be read.
    pid: ?c_int = null,
    store: ?[]const u8 = null,
    state: union(enum) {
        observed: client.HostControlObservation,
        outcome: HostLifecycle.ActivationOutcome,
        failed: Failure,
    },

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.socket) |socket| allocator.free(socket);
        if (self.directory) |directory| allocator.free(directory);
        if (self.store) |store| allocator.free(store);
        if (self.state == .failed) allocator.free(self.state.failed.cause);
    }
};

pub const Batch = struct {
    entries: []Entry = &.{},
    version: ?release.Version = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = .{};
    }

    pub fn selectedOutcome(self: *const Batch, store: []const u8) HostLifecycle.ActivationOutcome {
        return self.summary(store).own;
    }

    pub fn hasGuidance(self: *const Batch) bool {
        self.assertSettled();
        return self.summary(null).guidance;
    }

    pub fn totals(self: *const Batch) Totals {
        self.assertSettled();
        return self.summary(null).counts;
    }

    /// Every entry placed against `store` (none when null) and folded by
    /// `host_activation`; an entry still only observed counts as failed there.
    fn summary(self: *const Batch, store: ?[]const u8) activation.Summary {
        var tally: activation.Tally = .{};
        for (self.entries) |entry| tally.add(.{
            .place = if (entry.directory orelse entry.store) |path|
                (if (store != null and std.mem.eql(u8, path, store.?)) .own else .other)
            else
                .unlocated,
            .state = switch (entry.state) {
                .outcome => |outcome| .{ .outcome = outcome },
                .failed, .observed => .failed,
            },
        });
        return tally.finish(if (self.failure) |err| if (err == error.Cancelled) .cancelled else .other else null);
    }

    /// A restart batch has settled every Host it observed.
    fn assertSettled(self: *const Batch) void {
        for (self.entries) |entry| if (entry.state == .observed) unreachable;
    }

    pub fn write(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.failure) |err| try writer.print("Host restart could not finish ({s}); inspect this user's Hosts with their owning clients, then retry.\n", .{@errorName(err)});
        for (self.entries) |entry| switch (entry.state) {
            .observed => unreachable,
            .failed => |failure| try writeEntryFailure(writer, &entry, failure),
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
        };
        try writeTotals(self.totals(), writer);
    }

    pub fn writeWarning(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.entries.len == 0 and self.failure == null) return writer.writeAll("No running Hosts discovered now; Hosts running after publication will also be considered.\n");
        try writer.print("Upgrade restarts every running Host it can safely activate, interrupting work across ALL Sessions in those Stores. Discovered {d} Hosts:\n", .{self.entries.len});
        for (self.entries) |entry| switch (entry.state) {
            .observed => {
                try field(writer, entry.directory orelse entry.store.?);
                try writer.writeAll(": running; will restart on the selected installed build\n");
            },
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
            .failed => |failure| try writeEntryFailure(writer, &entry, failure),
        };
    }
};

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
            var observation = HostLifecycle.observe(allocator, init.io, options.home, facts.directory(), options.cancellation) catch |err| {
                entry.state = .{ .failed = try .of(allocator, .observation, err) };
                continue;
            };
            defer observation.deinit(allocator);
            switch (observation) {
                .absent => break :outcome .not_needed,
                .unsupported => |reason| break :outcome .{ .unsupported = reason },
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

fn writeEntryFailure(writer: *std.Io.Writer, entry: *const Entry, failure: Failure) !void {
    if (entry.directory orelse entry.store) |store| {
        try field(writer, store);
        return writer.print(": failed at {s} ({s}): {s}\n", .{ @tagName(failure.stage), failure.cause, switch (failure.stage) {
            .discovery => "could not read this Host's sources; inspect with its owning client, then retry.",
            .observation => "could not confirm this Host; inspect with its owning client, then retry.",
            .selection => "selected installed build has no verified release version; install a managed release and retry.",
        } });
    }
    try writer.writeAll("Store unknown (");
    if (entry.socket) |socket| {
        try writer.writeAll("socket ");
        try field(writer, socket);
    } else if (entry.pid) |pid| {
        try writer.print("Host process {d}", .{pid});
    } else try writer.writeAll("Host sources unavailable");
    try writer.print("): failed at discovery: Host state is unconfirmed ({s}); inspect this {s} with the owning client, then retry. A refused or missing socket alone does not prove the Host stopped.\n", .{ failure.cause, if (entry.socket != null) "socket and its Store" else "Host process" });
}

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

fn writeOutcome(writer: *std.Io.Writer, store: []const u8, outcome: HostLifecycle.ActivationOutcome, version: ?release.Version) !Result {
    try field(writer, store);
    try writer.writeAll(": ");
    switch (outcome) {
        .ready => {
            try writer.print("restarted on 0.{d}.{d}", .{ version.?.schema, version.?.patch });
        },
        .client_incompatible => {
            // The lifecycle verified a new instance and answering target
            // release, but this client's protocol cannot read ordinary replies.
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
                .ownership_status => "ownership is unconfirmed; do not stop a guessed Host (Host status unavailable while owned)",
                .ownership_observation => "ownership is unconfirmed; do not stop a guessed Host (initial Host observation failed)",
                .ownership_directory_unavailable => "ownership is unconfirmed; do not stop a guessed Host (Host directory could not be canonicalized)",
                .ownership_directory_mismatch => "ownership is unconfirmed; do not stop a guessed Host (Host directories differ)",
                .ownership_confirmation => "ownership is unconfirmed; do not stop a guessed Host (Host identity confirmation failed)",
                .application_owned => "application-owned Host (including MySQL); restart through its application",
                .configuration_unavailable => "launch configuration cannot be safely reconstructed; restart through its owner",
                .target_capability => "target build cannot safely check a detached restart; Host left running",
            }});
        },
        .replacement_observed => {
            try writer.writeAll("failed at verifying: a replacement Host was observed; inspect with its owning client, then retry");
        },
        .cancelled => {
            try writer.writeAll("failed at activation: cancelled; inspect Host status, then retry");
        },
        .refused => |refusal| {
            try writer.print("refused at {s}\n", .{@tagName(refusal.stage)});
            var line: [@import("start_report.zig").max_line_bytes]u8 = undefined;
            try writer.writeAll(@import("start_report.zig").line(&refusal.failure, &line));
            return activation.category(outcome);
        },
        .failed, .unconfirmed => |stage| {
            try writer.print("failed at {s}: {s}; inspect Host status with its owning client, then retry", .{ @tagName(stage), if (outcome == .failed) "restart failed" else "restart is unconfirmed" });
        },
    }
    try writer.writeByte('\n');
    return activation.category(outcome);
}

test "SH-50 restart all reports every activation outcome and limitation with exit truth" {
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
        "ownership is unconfirmed; do not stop a guessed Host (Host status unavailable while owned)",
        "ownership is unconfirmed; do not stop a guessed Host (initial Host observation failed)",
        "ownership is unconfirmed; do not stop a guessed Host (Host directory could not be canonicalized)",
        "ownership is unconfirmed; do not stop a guessed Host (Host directories differ)",
        "ownership is unconfirmed; do not stop a guessed Host (Host identity confirmation failed)",
        "application-owned Host (including MySQL); restart through its application",
        "launch configuration cannot be safely reconstructed; restart through its owner",
        "target build cannot safely check a detached restart; Host left running",
    };
    inline for (std.meta.tags(HostLifecycle.Limitation), limitations) |limitation, text| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(Result.skipped, try writeOutcome(&writer, "/store", .{ .unsupported = limitation }, .{ .schema = 1, .patch = 2 }));
        try std.testing.expectEqualStrings("/store: left running: " ++ text ++ "\n", writer.buffered());
    }
    covered.insert(.unsupported);
    inline for (.{ .checking, .starting }) |stage| {
        const refusal: HostLifecycle.ActivationOutcome = .{ .refused = .{ .stage = stage, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "typed refusal") } };
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(Result.failed, try writeOutcome(&writer, "/store", refusal, null));
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "rui_start_error") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "typed refusal") != null);
    }
    covered.insert(.refused);
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
    try writeTotals(.{}, &writer);
    try std.testing.expectEqualStrings("No running Hosts.\n", writer.buffered());
    writer.end = 0;
    var totals: Totals = .{};
    for ([_]Result{ .restarted, .current, .skipped, .failed }) |result| totals.add(result);
    try writeTotals(totals, &writer);
    try std.testing.expectEqualStrings("4 Hosts: 1 restarted, 1 already current, 1 left unchanged, 1 failed.\n", writer.buffered());
}

test "restart all counts every outcome even after its output reader closes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    _ = std.c.close(fds[0]);
    const destination: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer destination.close(std.testing.io);
    var buffer: [16]u8 = undefined;
    var output = OptionalOutput.init(std.testing.io, destination, &buffer);
    var totals: Totals = .{};
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const outcome = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        totals.add(try writeOutcome(&output.writer, "/store", outcome, .{ .schema = 1, .patch = 2 }));
        try output.writer.flush();
    }
    try writeTotals(totals, &output.writer);
    try output.writer.flush();
    try std.testing.expectEqual(info.field_names.len, totals.restarted + totals.current + totals.skipped + totals.failed);
}

test "every failed stage names its cause" {
    var buffer: [512]u8 = undefined;
    for ([_]Stage{ .discovery, .observation, .selection }) |stage| {
        var writer: std.Io.Writer = .fixed(&buffer);
        const entry: Entry = .{ .socket = "/run/x.sock", .store = if (stage == .discovery) null else "/store", .state = .{ .failed = .{ .stage = stage, .cause = "ConnectionRefused" } } };
        try writeEntryFailure(&writer, &entry, entry.state.failed);
        const text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "(ConnectionRefused)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, @tagName(stage)) != null);
    }
}

test "restart batch retains DIR selection independently of wire identity and outcomes" {
    var entries = [_]Entry{.{
        .directory = "/host-directory",
        .store = "mysql-opaque-identity",
        .state = .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "cannot start") } } },
    }};
    const batch: Batch = .{ .entries = &entries };
    try std.testing.expect(batch.selectedOutcome("/host-directory") == .refused);
    try std.testing.expect(batch.selectedOutcome("mysql-opaque-identity") == .not_needed);
    try std.testing.expect(batch.hasGuidance());
    try std.testing.expectEqual(@as(usize, 1), batch.totals().failed);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try batch.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "/host-directory: refused at checking") != null);
}

test "restart reports a positively identified Host without a socket or directory" {
    const entry: Entry = .{ .pid = 42, .state = .{ .failed = .{ .stage = .discovery, .cause = "HostServeStoreMissing" } } };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEntryFailure(&writer, &entry, entry.state.failed);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Host process 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "HostServeStoreMissing") != null);
}
