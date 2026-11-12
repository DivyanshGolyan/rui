const std = @import("std");
const client = @import("client.zig");
const release = @import("release_candidate.zig");
const Installation = @import("Installation.zig");
const HostLifecycle = @import("HostLifecycle.zig");
const restart_all = @import("host_restart_all.zig");
const platform = @import("platform.zig");
const TerminalText = @import("TerminalText.zig");
const process = @import("upgrade_process.zig");
const installation_path = @import("installation_path.zig");

pub const Phase = enum(u8) { checking, preparing, publishing, stopping, awaiting_retirement, starting, verifying, finished };
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, Phase) void,

    fn send(self: ?Progress, phase: Phase) void {
        if (self) |value| value.report(value.context, phase);
    }
};

pub const CleanupReceipts = struct {
    pub const Phase = enum { preparation, publication, disposal };
    const Receipt = struct {
        causes: ?struct { primary: ?anyerror, secondary: anyerror } = null,
        path: [std.fs.max_path_bytes]u8 = undefined,
        length: usize = 0,

        fn capture(raw: ?*anyopaque, failure: Installation.CleanupFailure) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(self.causes == null and failure.retained_path.len <= self.path.len);
            @memcpy(self.path[0..failure.retained_path.len], failure.retained_path);
            self.length = failure.retained_path.len;
            self.causes = .{ .primary = failure.primary, .secondary = failure.secondary };
        }

        fn write(self: *const @This(), writer: *std.Io.Writer) !void {
            const causes = self.causes orelse return;
            try Installation.writeCleanupFailure(writer, .{ .primary = causes.primary, .secondary = causes.secondary, .retained_path = self.path[0..self.length] });
        }
    };

    preparation: Receipt = .{},
    publication: Receipt = .{},
    disposal: Receipt = .{},

    pub fn reporter(self: *CleanupReceipts, phase: CleanupReceipts.Phase) Installation.CleanupReporter {
        const receipt = switch (phase) {
            .preparation => &self.preparation,
            .publication => &self.publication,
            .disposal => &self.disposal,
        };
        return .{ .context = receipt, .report = Receipt.capture };
    }

    pub fn any(self: *const CleanupReceipts) bool {
        return self.preparation.causes != null or self.publication.causes != null or self.disposal.causes != null;
    }

    pub fn write(self: *const CleanupReceipts, writer: *std.Io.Writer) !void {
        try self.preparation.write(writer);
        try self.publication.write(writer);
        try self.disposal.write(writer);
    }
};

pub const DownloadDiagnostic = process.DownloadDiagnostic;

pub const Check = struct {
    candidate: release.ReleaseCandidate,
    selected: Installation.Selection,
    hosts: restart_all.Batch = .{},
    home: []const u8,
    store: []const u8,
    /// As `executablePathAlloc` allocates it, so `deinit` frees all of it.
    running_executable: [:0]const u8,
    path: installation_path.Observation = .{ .state = .unavailable },

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        self.candidate.deinit(allocator);
        self.selected.deinit(allocator);
        self.hosts.deinit(allocator);
        self.path.deinit(allocator);
        allocator.free(self.home);
        allocator.free(self.store);
        allocator.free(self.running_executable);
    }
};

pub const Result = struct {
    installation: Installation.InstallationOutcome,
    hosts: restart_all.Batch = .{},
    store: []const u8,

    pub fn selectedActivation(self: *const Result) HostLifecycle.ActivationOutcome {
        return self.hosts.selectedOutcome(self.store);
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.installation.deinit(allocator);
        self.hosts.deinit(allocator);
        allocator.free(self.store);
    }
};

pub fn check(init: std.process.Init, allocator: std.mem.Allocator, store: []const u8, cancellation: ?*client.Cancellation, diagnostic: *DownloadDiagnostic) !Check {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    const endpoint = if (init.environ_map.get("RUI_TEST_UPGRADE_RELEASES_URL")) |base| try std.fmt.allocPrint(allocator, "{s}/latest", .{base}) else null;
    defer if (endpoint) |url| allocator.free(url);
    var selected = try Installation.inspectCancellable(allocator, init.io, home, cancellation);
    errdefer selected.deinit(allocator);
    var candidate = try release.discover(allocator, init.io, endpoint orelse release.default_endpoint, cancellation, diagnostic);
    errdefer candidate.deinit(allocator);
    var hosts = try restart_all.discover(init, allocator, home, cancellation);
    errdefer hosts.deinit(allocator);
    const owned_home = try allocator.dupe(u8, home);
    errdefer allocator.free(owned_home);
    const paths = platform.resolveClientPaths(init.io, store) catch null;
    const owned_store = try allocator.dupe(u8, if (paths) |value| value.store.slice() else store);
    errdefer allocator.free(owned_store);
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    errdefer allocator.free(executable);
    const path_observation = installation_path.inspect(allocator, init.io, home, init.environ_map.get("PATH") orelse "") catch installation_path.Observation{ .state = .unavailable };
    return .{ .candidate = candidate, .selected = selected, .hosts = hosts, .home = owned_home, .store = owned_store, .running_executable = executable, .path = path_observation };
}

pub fn canInstall(checked: *const Check) bool {
    return checked.selected == .released;
}

/// The selected build already is the release, or newer: an install
/// reselects it and prepares nothing.
pub fn holdsRelease(checked: *const Check) bool {
    return checked.selected == .released and checked.selected.released.version.order(checked.candidate.version) != .lt;
}

const ActivationProgress = struct {
    progress: ?Progress,

    fn report(raw: *anyopaque, stage: HostLifecycle.Stage) void {
        const self: *ActivationProgress = @ptrCast(@alignCast(raw));
        Progress.send(self.progress, switch (stage) {
            .stopping => .stopping,
            .awaiting_retirement => .awaiting_retirement,
            .starting => .starting,
            .verifying => .verifying,
        });
    }
};

pub fn install(init: std.process.Init, allocator: std.mem.Allocator, checked: *const Check, cancellation: ?*client.Cancellation, progress: ?Progress, cleanup: *CleanupReceipts, diagnostic: *DownloadDiagnostic) !Result {
    try process.check(cancellation);
    if (!canInstall(checked)) return error.UpgradeIneligible;
    const store = try allocator.dupe(u8, checked.store);
    errdefer allocator.free(store);
    var installation: Installation.InstallationOutcome = undefined;
    const selected = checked.selected.released;
    if (holdsRelease(checked)) {
        // Reselecting the installed build publishes too.
        Progress.send(progress, .publishing);
        try process.check(cancellation);
        installation = try Installation.publishExistingWithReporter(allocator, init.io, checked.home, selected.build, .released_upgrade, cancellation, cleanup.reporter(.publication));
    } else {
        Progress.send(progress, .preparing);
        var prepared = try Installation.prepareWithReporter(allocator, init.io, checked.home, &checked.candidate, cancellation, cleanup.reporter(.preparation), diagnostic);
        defer prepared.disposeWithReporter(allocator, init.io, cleanup.reporter(.disposal)) catch {};
        Progress.send(progress, .publishing);
        try process.check(cancellation);
        installation = try Installation.publishWithReporter(allocator, init.io, checked.home, &prepared, .released_upgrade, cancellation, cleanup.reporter(.publication));
    }
    errdefer installation.deinit(allocator);
    var activation_progress: ActivationProgress = .{ .progress = progress };
    const receipt = installation.receipt();
    // Once publication succeeds, every restart failure belongs to the receipt,
    // never the pre-publication error path. Discover again to include Hosts
    // started during preparation, and pin the receipt rather than following PATH.
    const hosts: restart_all.Batch = hosts: {
        waitAfterPublication(init, cancellation) catch |err| break :hosts .{ .failure = err };
        var target = restart_all.Target.init(init, allocator, checked.home, receipt.selected_after, cancellation) catch |err| break :hosts .{ .failure = err };
        defer target.deinit(allocator);
        break :hosts @import("host_coordinator.zig").restart(init, allocator, .{
            .home = checked.home,
            .target = &target,
            .cancellation = cancellation,
            .progress = .{ .context = &activation_progress, .report = ActivationProgress.report },
        }) catch |err| .{ .failure = err };
    };
    Progress.send(progress, .finished);
    return .{ .installation = installation, .hosts = hosts, .store = store };
}

fn waitAfterPublication(init: std.process.Init, cancellation: ?*const client.Cancellation) !void {
    if (init.environ_map.get("RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE")) |gate| {
        while (true) {
            try process.check(cancellation);
            const file = std.Io.Dir.cwd().openFile(init.io, gate, .{}) catch |err| {
                if (err == error.FileNotFound) break;
                return err;
            };
            file.close(init.io);
            try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
        }
    }
}

pub fn compatible(result: *const Result) bool {
    return switch (result.selectedActivation()) {
        .client_incompatible, .unconfirmed, .failed, .replacement_observed => false,
        else => true,
    };
}

fn field(writer: *std.Io.Writer, value: []const u8) !void {
    var text: TerminalText = .{ .mode = .line };
    try text.feed(writer, value);
    try text.finish(writer);
}

pub fn writeCheck(writer: *std.Io.Writer, checked: *const Check) !void {
    try writer.print("Running client: Rui {s}\nClient executable: ", .{@import("transport_options").version});
    try field(writer, checked.running_executable);
    try writer.writeAll("\nInstallation destination: ");
    try field(writer, checked.home);
    try writer.writeAll("/.local/bin/rui\nSelected managed release: ");
    switch (checked.selected) {
        .released => |selected| try writer.print("0.{d}.{d}", .{ selected.version.schema, selected.version.patch }),
        .absent => try writer.writeAll("none (use the release installer for first installation)"),
        .source => try writer.writeAll("intentional source build (use the standalone release installer to switch)"),
        .unknown_managed => try writer.writeAll("managed build with unknown release identity (use the standalone release installer to switch)"),
        .ineligible => try writer.writeAll("unsupported or application-owned; use its installer/package manager"),
    }
    try writer.print("\nLatest published stable: 0.{d}.{d}\nClient Store: ", .{ checked.candidate.version.schema, checked.candidate.version.patch });
    try field(writer, checked.store);
    try writer.writeAll("\n");
    try installation_path.write(writer, &checked.path, checked.home);
    try checked.hosts.writeWarning(writer);
    try writer.writeAll("Store compatibility is validated by the target Host at startup; checking/installing never migrates it.\nThe running client and bundled/custom application binaries are not replaced.\n");
    if (!canInstall(checked)) try writer.writeAll("Upgrade cannot replace this destination. Use the existing manual release installer or application owner.\n");
}

/// Whether the result receipt contains instructions that a TUI relaunch must
/// not swallow. Installation and activation are independent: a published Rui
/// can still leave an unresolved or application-owned Host behind.
pub fn hasGuidance(result: *const Result) bool {
    return result.hosts.hasGuidance();
}

pub fn writeResult(writer: *std.Io.Writer, result: *const Result) !void {
    try writer.writeAll(switch (result.installation) {
        .installed => "Installed Rui. Complete build: ",
        .unchanged => "Installation unchanged. Selected complete build: ",
    });
    const receipt = result.installation.receipt();
    try field(writer, receipt.selected_after);
    if (!std.mem.eql(u8, receipt.operation_build, receipt.selected_after)) {
        try writer.writeAll("\nThis operation prepared/published: ");
        try field(writer, receipt.operation_build);
    }
    try writer.writeAll("\n");
    try result.hosts.write(writer);
    if (hasGuidance(result)) try writer.writeAll("Installation was not rolled back. Follow each Host's recovery instructions; do not restore/reset Stores or replay uncertain requests.\n");
}

test "a check frees exactly the executable path the system gave it" {
    const allocator = std.testing.allocator;
    var checked: Check = .{
        .candidate = .{ .version = .{ .schema = 99, .patch = 0 }, .tag = try allocator.dupe(u8, "v0.99.0"), .archive_name = try allocator.dupe(u8, "fixture"), .archive_url = try allocator.dupe(u8, "fixture"), .checksum_url = try allocator.dupe(u8, "fixture"), .sha256 = @splat(0) },
        .selected = .absent,
        .hosts = .{},
        .home = try allocator.dupe(u8, "/synthetic/home"),
        .store = try allocator.dupe(u8, "/synthetic/store"),
        .running_executable = try std.process.executablePathAlloc(std.testing.io, allocator),
    };
    checked.deinit(allocator);
}

test "upgrade owns cleanup facts by phase after native borrowed paths are reclaimed" {
    for (std.enums.values(CleanupReceipts.Phase)) |phase| {
        var cleanup: CleanupReceipts = .{};
        const reporter = cleanup.reporter(phase);
        var path: [std.fs.max_path_bytes]u8 = @splat('p');
        path[0] = '/';
        reporter.report(reporter.context, .{ .primary = error.ReleaseChecksumMismatch, .secondary = error.AccessDenied, .retained_path = &path });
        @memset(&path, 'x');
        try std.testing.expect(cleanup.any());
        var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer writer.deinit();
        try cleanup.write(&writer.writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "ReleaseChecksumMismatch") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "AccessDenied") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "/pppppp") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "xxxxxxx") == null);
    }
}

test "upgrade restart results cover every activation for selected and other Stores" {
    const receipt: Installation.Receipt = .{ .operation_build = "/prepared", .selected_after = "/selected" };
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const activation = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        for ([_]bool{ false, true }) |selected| {
            for ([_]bool{ false, true }) |installed| {
                var entries = [_]restart_all.Entry{.{ .socket = "/socket", .store = if (selected) "/selected-store" else "/other-store", .state = .{ .outcome = activation } }};
                const result: Result = .{
                    .installation = if (installed) .{ .installed = receipt } else .{ .unchanged = receipt },
                    .hosts = .{ .entries = &entries, .version = .{ .schema = 99, .patch = 0 } },
                    .store = "/selected-store",
                };
                const guided = switch (activation) {
                    .not_needed, .superseded, .already_ready, .ready, .client_incompatible => false,
                    .unsupported, .replacement_observed, .cancelled, .failed, .unconfirmed => true,
                };
                const safe = !selected or switch (activation) {
                    .client_incompatible, .unconfirmed, .failed, .replacement_observed => false,
                    else => true,
                };
                try std.testing.expectEqual(safe, compatible(&result));
                try std.testing.expectEqual(guided, hasGuidance(&result));
                try std.testing.expectEqualDeep(if (selected) activation else HostLifecycle.ActivationOutcome.not_needed, result.selectedActivation());
                var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer output.deinit();
                try writeResult(&output.writer, &result);
                var shared: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer shared.deinit();
                try result.hosts.write(&shared.writer);
                try std.testing.expect(std.mem.indexOf(u8, output.written(), shared.written()) != null);
                try std.testing.expectEqual(guided, std.mem.indexOf(u8, output.written(), "Installation was not rolled back") != null);
            }
        }
    }
}

test "upgrade restart results retain unknown failures and other Store guidance without borrowing compatibility" {
    const receipt: Installation.Receipt = .{ .operation_build = "/prepared", .selected_after = "/selected" };
    var entries = [_]restart_all.Entry{
        .{ .socket = "/other.sock", .store = "/other", .state = .{ .outcome = .{ .client_incompatible = 123 } } },
        .{ .socket = "/selected.sock", .store = "/store", .state = .{ .outcome = .{ .ready = .{ .instance = @splat(1), .pid = 42 } } } },
    };
    var result: Result = .{ .installation = .{ .installed = receipt }, .store = "/store", .hosts = .{ .entries = &entries, .version = .{ .schema = 99, .patch = 0 } } };
    try std.testing.expect(compatible(&result));
    try std.testing.expect(!hasGuidance(&result));
    try std.testing.expectEqual(@as(usize, 2), result.hosts.totals().restarted);
    entries[0].state = .{ .outcome = .{ .failed = .starting } };
    try std.testing.expect(compatible(&result));
    try std.testing.expect(hasGuidance(&result));
    try std.testing.expectEqual(@as(usize, 1), result.hosts.totals().failed);
    // An unidentified socket may belong to this Store; known selected facts
    // remain usable, but its missing identity can never become an absence.
    entries[0].store = null;
    entries[0].state = .{ .failed = .discovery };
    try std.testing.expect(compatible(&result));
    result.hosts.entries = entries[0..1];
    try std.testing.expect(!compatible(&result));
    try std.testing.expect(hasGuidance(&result));
    result.hosts = .{ .failure = error.AccessDenied };
    try std.testing.expect(!compatible(&result));
    try std.testing.expect(hasGuidance(&result));
    result.hosts = .{};
    try std.testing.expect(compatible(&result));
    try std.testing.expect(!hasGuidance(&result));
    var bytes: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try result.hosts.write(&out);
    try std.testing.expectEqualStrings("No running Hosts.\n", out.buffered());
}
