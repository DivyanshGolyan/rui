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

/// Replace an identified older managed Host on an ordinary detached start.
pub fn activateOlderHostForStart(init: std.process.Init, directory: []const u8) !?activation.Execution {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    const allocator = init.gpa;
    var observation = try HostLifecycle.observe(allocator, init.io, home, directory, null);
    defer observation.deinit(allocator);
    switch (observation) {
        .absent => return .{ .outcome = .not_needed },
        .unsupported => |reason| return .{ .outcome = .{ .unsupported = reason } },
        .managed => {},
    }
    const target = Target.init(init, allocator, home, null, null) catch |err| switch (err) {
        error.IneligibleInstallation => return null,
        else => return err,
    };
    defer target.deinit(allocator);
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{target.build});
    defer allocator.free(binary);
    const actual = try std.Io.Dir.cwd().realPathFileAlloc(init.io, binary, allocator);
    defer allocator.free(actual);
    if (!activation.startHandoverEligible(observation.managed.observed.foreign, observation.managed.version.order(target.version), std.mem.eql(u8, actual, try @import("self_executable.zig").path(init.io)))) return null;
    return HostLifecycle.activate(init, allocator, &observation, .same, target.build, target.version, null, null);
}

test "SH-123 absent Store owner is not started by handover observation" {
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
    const result = (try activateOlderHostForStart(init, root)).?;
    try std.testing.expectEqual(std.meta.Tag(activation.Outcome).not_needed, std.meta.activeTag(result.outcome));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "host.lock", .{}));
}

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
    cause_owned: bool = false,

    fn of(stage: Stage, err: anyerror) Failure {
        return .{ .stage = stage, .cause = @errorName(err) };
    }
};
pub const Fault = struct {
    effect: std.meta.Tag(activation.Effect),
    cause: []const u8,
    cause_owned: bool = false,

    fn of(fault: activation.Fault) Fault {
        return .{ .effect = fault.effect, .cause = @errorName(fault.cause) };
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
        fault: Fault,
    },

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.socket) |socket| allocator.free(socket);
        if (self.directory) |directory| allocator.free(directory);
        if (self.store) |store| allocator.free(store);
        if (self.state == .failed and self.state.failed.cause_owned) allocator.free(self.state.failed.cause);
        if (self.state == .fault and self.state.fault.cause_owned) allocator.free(self.state.fault.cause);
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

    /// The aggregate exit retains uncertainty if any Host may have been stopped.
    pub fn result(self: *const Batch) !void {
        for (self.entries) |entry| switch (entry.state) {
            .fault => |fault| if (fault.effect.stage() != null) return error.HostRestartUnconfirmed,
            .outcome => |outcome| if (outcome == .unconfirmed) return error.HostRestartUnconfirmed,
            .observed => return error.HostRestartUnconfirmed,
            .failed => {},
        };
        if (self.failure) |err| if (err == error.HostRestartUnconfirmed) return error.HostRestartUnconfirmed;
        if (self.totals().failed != 0) return error.HostRestartFailed;
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
    pub fn summary(self: *const Batch, store: ?[]const u8) activation.Summary {
        var tally: activation.Tally = .{};
        for (self.entries) |entry| tally.add(.{
            .place = if (entry.directory orelse entry.store) |path|
                (if (store != null and std.mem.eql(u8, path, store.?)) .own else .other)
            else
                .unlocated,
            .state = switch (entry.state) {
                .outcome => |outcome| .{ .outcome = outcome },
                .fault => |fault| if (fault.effect.stage()) |stage| .{ .outcome = .{ .unconfirmed = stage } } else .{ .outcome = .{ .pre_stop_failed = fault.effect } },
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
            .fault => |fault| try writeEntryFault(writer, &entry, fault),
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
        };
        try writeTotals(self.totals(), writer);
    }

    pub fn writeWarning(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.entries.len == 0 and self.failure == null) {
            return writer.writeAll("No running Hosts discovered now; Hosts running after publication will also be considered.\n");
        }
        try writer.print("Upgrade restarts every running Host it can safely activate, interrupting work across ALL Sessions in those Stores. Discovered {d} Hosts:\n", .{self.entries.len});
        for (self.entries) |entry| switch (entry.state) {
            .observed => {
                try field(writer, entry.directory orelse entry.store.?);
                try writer.writeAll(": running; will restart on the selected installed build\n");
            },
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
            .failed => |failure| try writeEntryFailure(writer, &entry, failure),
            .fault => |fault| try writeEntryFault(writer, &entry, fault),
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
            .unanswered => unreachable,
            .failed => |err| .{ .failed = .of(.discovery, err) },
            .observed => |facts| state: {
                entry.store = try allocator.dupe(u8, facts.facts.store.slice());
                var observation = HostLifecycle.observe(allocator, init.io, home, facts.directory(), cancellation) catch |err| break :state .{ .failed = .of(.observation, err) };
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
        entry.state = state: {
            process.check(options.cancellation) catch break :state .{ .outcome = .cancelled };
            var observation = HostLifecycle.observe(allocator, init.io, options.home, facts.directory(), options.cancellation) catch |err| {
                entry.state = .{ .failed = .of(.observation, err) };
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
                    entry.state = .{ .failed = .of(.selection, err) };
                    continue;
                };
                batch.version = selected.?.version;
            }
            const target = options.target orelse &selected.?;
            const current = observation.managed.observed;
            const census: @FieldType(activation.Facts, "census") = if (current.pid != facts.pid or !std.mem.eql(u8, &current.facts.instance, &facts.facts.instance) or
                !std.mem.eql(u8, current.facts.store.slice(), entry.store.?)) .replaced else .same;
            break :state switch (HostLifecycle.activate(init, allocator, &observation, census, target.build, target.version, options.cancellation, options.progress)) {
                .outcome => |outcome| .{ .outcome = outcome },
                .fault => |fault| .{ .fault = .of(fault) },
            };
        };
    }
    return batch;
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    var batch = restart(init, allocator, .{ .home = home }) catch |err| Batch{ .failure = err };
    defer batch.deinit(allocator);
    var buffer: [2048]u8 = undefined;
    var output = OptionalOutput.init(init.io, .stdout(), &buffer);
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

fn writeEntryFault(writer: *std.Io.Writer, entry: *const Entry, fault: Fault) !void {
    try field(writer, entry.directory orelse entry.store orelse "Store unknown");
    if (fault.effect.stage()) |stage| {
        try writer.print(": unconfirmed at {s} during {s} ({s}); inspect with its owning client, then retry.\n", .{ @tagName(stage), @tagName(fault.effect), fault.cause });
    } else {
        try writer.print(": failed during {s} ({s}); inspect with its owning client, then retry.\n", .{ @tagName(fault.effect), fault.cause });
    }
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

pub const writeOutcome = @import("host_activation_report.zig").writeOutcome;

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
        .{ .outcome = .{ .pre_stop_failed = .resolve_target }, .text = "failed before stopping during resolve_target; Host left running", .result = .failed },
        .{ .outcome = .{ .target_unusable = .resolving }, .text = "failed at resolving the target: the target build could not be resolved; Host left running; check the installation, then retry", .result = .failed },
        .{ .outcome = .{ .target_unusable = .checking }, .text = "failed at checking the target: the target build could not be checked; Host left running; check the installation, then retry", .result = .failed },
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
    const without_version = [_]struct { outcome: HostLifecycle.ActivationOutcome, text: []const u8, result: Result }{
        .{ .outcome = .{ .ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "restarted", .result = .restarted },
        .{ .outcome = .{ .client_incompatible = identity.pid }, .text = "restarted with a different Host protocol; inspect with the selected Rui client", .result = .restarted },
        .{ .outcome = .{ .already_ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "already on the selected build", .result = .current },
        .{ .outcome = .superseded, .text = "left running: newer than the selected build; no downgrade", .result = .skipped },
    };
    for (without_version) |case| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(case.result, try writeOutcome(&writer, "", case.outcome, null));
        var expected: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Host handover: {s}\n", .{case.text}), writer.buffered());
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
            var unscoped: [1024]u8 = undefined;
            var unscoped_writer = std.Io.Writer.fixed(&unscoped);
            try std.testing.expectEqual(Result.failed, try writeOutcome(&unscoped_writer, "", @unionInit(HostLifecycle.ActivationOutcome, @tagName(tag), stage), null));
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Host handover: failed at {s}: {s}; inspect Host status with its owning client, then retry\n", .{ @tagName(stage), reason }), unscoped_writer.buffered());
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

test "SH-125 lifecycle faults report the exact effect and cause at every stage" {
    const cases = [_]struct { effect: std.meta.Tag(activation.Effect), expected: []const u8 }{
        .{ .effect = .resolve_target, .expected = "failed during resolve_target (OutOfMemory)" },
        .{ .effect = .confirm_current, .expected = "failed during confirm_current (OutOfMemory)" },
        .{ .effect = .reconstruct_sources, .expected = "failed during reconstruct_sources (OutOfMemory)" },
        .{ .effect = .check_target, .expected = "failed during check_target (OutOfMemory)" },
        .{ .effect = .reobserve, .expected = "failed during reobserve (OutOfMemory)" },
        .{ .effect = .snapshot, .expected = "failed during snapshot (OutOfMemory)" },
        .{ .effect = .stop, .expected = "unconfirmed at stopping during stop (OutOfMemory)" },
        .{ .effect = .await_retirement, .expected = "unconfirmed at awaiting_retirement during await_retirement (OutOfMemory)" },
        .{ .effect = .start, .expected = "unconfirmed at starting during start (OutOfMemory)" },
        .{ .effect = .verify, .expected = "unconfirmed at verifying during verify (OutOfMemory)" },
    };
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(activation.Effect)).len - 1, cases.len);
    for (cases) |case| {
        const fault = Fault.of(.{ .effect = case.effect, .cause = error.OutOfMemory });
        const entries = [_]Entry{.{ .directory = "/store", .state = .{ .fault = fault } }};
        const batch: Batch = .{ .entries = @constCast(&entries) };
        var bytes: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        try batch.write(&writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), case.expected) != null);
        try std.testing.expectEqual(@as(usize, 1), batch.totals().failed);
        if (case.effect.stage()) |stage| {
            try std.testing.expectEqual(stage, batch.selectedOutcome("/store").unconfirmed);
        } else {
            try std.testing.expectEqual(case.effect, batch.selectedOutcome("/store").pre_stop_failed);
        }
    }
}

test "SH-127 batch exit preserves uncertainty across mixed Host results" {
    const pre: Entry = .{ .state = .{ .fault = .{ .effect = .check_target, .cause = "OutOfMemory" } } };
    const post: Entry = .{ .state = .{ .fault = .{ .effect = .verify, .cause = "OutOfMemory" } } };
    const unconfirmed: Entry = .{ .state = .{ .outcome = .{ .unconfirmed = .stopping } } };
    const success: Entry = .{ .state = .{ .outcome = .not_needed } };
    const cases = [_]struct { entries: []const Entry, failure: ?anyerror = null, expected: ?anyerror }{
        .{ .entries = &.{success}, .expected = null },
        .{ .entries = &.{pre}, .expected = error.HostRestartFailed },
        .{ .entries = &.{post}, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{unconfirmed}, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{ pre, post, success }, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{ post, pre }, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{}, .failure = error.HostRestartUnconfirmed, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{}, .failure = error.OutOfMemory, .expected = error.HostRestartFailed },
    };
    for (cases) |case| {
        const batch: Batch = .{ .entries = @constCast(case.entries), .failure = case.failure };
        if (case.expected) |err| try std.testing.expectError(err, batch.result()) else try batch.result();
    }
}
