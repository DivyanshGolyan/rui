const std = @import("std");
const client = @import("client.zig");
const release = @import("release_candidate.zig");
const Installation = @import("Installation.zig");
const HostLifecycle = @import("HostLifecycle.zig");
const host_activation = @import("host_activation.zig");
const restart_all = @import("host_restart_all.zig");
const platform = @import("platform.zig");
const TerminalText = @import("TerminalText.zig");
const process = @import("upgrade_process.zig");
const installation_path = @import("installation_path.zig");
const caller_error = @import("caller_error.zig");
const upgrade_run = @import("upgrade_run.zig");

pub const Phase = upgrade_run.Phase;
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

pub const Download = process.Download;

pub const Check = struct {
    candidate: release.ReleaseCandidate,
    selected: Installation.Selection,
    hosts: restart_all.Batch = .{},
    home: []const u8,
    store: []const u8,
    running_executable: [:0]const u8,
    path: installation_path.Observation = .{ .state = .unavailable },

    /// What this check observed, as `upgrade_run` reads it.
    pub fn facts(self: *const Check, mode: upgrade_run.Mode) upgrade_run.Facts {
        return .{
            .mode = mode,
            .selection = .{ .ok = selectionOf(self.selected) },
            .release = .{ .ok = versionOf(self.candidate.version) },
            .census = .{ .ok = self.hosts.entries.len },
        };
    }

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

    /// What the finished install of `checked` read, as `upgrade_run` reads it.
    /// A batch that failed after publication is a failed restart batch,
    /// whichever step failed.
    pub fn facts(self: *const Result, checked: *const Check) upgrade_run.Facts {
        var value = checked.facts(.install);
        value.resumed = true;
        if (!upgrade_run.holdsRelease(value)) value.prepared = .{ .ok = {} };
        self.addFacts(&value);
        value.pinned = .{ .ok = {} };
        return value;
    }

    /// Add the receipt and restart batch to facts already held by the caller.
    pub fn addFacts(self: *const Result, value: *upgrade_run.Facts) void {
        value.published = .{ .ok = publishedOf(self.installation) };
        value.hosts = .{ .ok = self.hosts.summary(self.store) };
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.installation.deinit(allocator);
        self.hosts.deinit(allocator);
        allocator.free(self.store);
    }
};

fn selectionOf(selected: Installation.Selection) upgrade_run.Selection {
    return switch (selected) {
        .absent => .absent,
        .ineligible => .ineligible,
        .source => .source,
        .unknown_managed => .unknown_managed,
        .released => |value| .{ .released = versionOf(value.version) },
    };
}

pub fn versionOf(version: release.Version) upgrade_run.Version {
    return .{ .schema = version.schema, .patch = version.patch };
}

fn publishedOf(installation: Installation.InstallationOutcome) upgrade_run.Published {
    return .{ .changed = installation == .installed, .selected = versionOf(installation.receipt().selected_version.?) };
}

/// The class `upgrade_run` records for an effect's error.
pub fn causeOf(err: anyerror) upgrade_run.Cause {
    if (err == error.Cancelled) return .cancelled;
    return causeOfCode(caller_error.of(err));
}

fn causeOfCode(code: caller_error.Code) upgrade_run.Cause {
    return switch (code) {
        .upgrade_download_failed => .download,
        .upgrade_release_invalid => .release,
        .upgrade_preparation_failed => .preparation,
        else => .other,
    };
}

pub fn discoverRelease(init: std.process.Init, allocator: std.mem.Allocator, cancellation: ?*client.Cancellation, diagnostic: *Download) !release.ReleaseCandidate {
    try process.check(cancellation);
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    var selected = try Installation.inspectCancellable(allocator, init.io, home, cancellation);
    defer selected.deinit(allocator);
    return fetchRelease(init, allocator, cancellation, diagnostic);
}

fn fetchRelease(init: std.process.Init, allocator: std.mem.Allocator, cancellation: ?*client.Cancellation, diagnostic: *Download) !release.ReleaseCandidate {
    try process.check(cancellation);
    const endpoint = if (init.environ_map.get("RUI_TEST_UPGRADE_RELEASES_URL")) |base| try std.fmt.allocPrint(allocator, "{s}/latest", .{base}) else null;
    defer if (endpoint) |url| allocator.free(url);
    return release.discover(allocator, init.io, endpoint orelse release.default_endpoint, cancellation, diagnostic);
}

pub fn check(init: std.process.Init, allocator: std.mem.Allocator, store: []const u8, cancellation: ?*client.Cancellation, diagnostic: *Download) !Check {
    var discovered: ?release.ReleaseCandidate = null;
    return checkDiscovered(init, allocator, store, cancellation, diagnostic, &discovered);
}

pub fn checkDiscovered(init: std.process.Init, allocator: std.mem.Allocator, store: []const u8, cancellation: ?*client.Cancellation, diagnostic: *Download, discovered: *?release.ReleaseCandidate) !Check {
    try process.check(cancellation);
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    // The mode is read only once a caller continues past the check.
    var facts: upgrade_run.Facts = .{ .mode = .check, .adopted = discovered.* != null };
    var selected: ?Installation.Selection = null;
    errdefer if (selected) |*value| value.deinit(allocator);
    var candidate: ?release.ReleaseCandidate = null;
    errdefer if (candidate) |*value| value.deinit(allocator);
    var hosts: ?restart_all.Batch = null;
    errdefer if (hosts) |*value| value.deinit(allocator);
    // Each effect polls the cancellation token where it did before this loop;
    // an error ends the check, so it is returned rather than recorded.
    while (true) switch (upgrade_run.next(facts)) {
        .inspect_selection => {
            selected = try Installation.inspectCancellable(allocator, init.io, home, cancellation);
            facts.selection = .{ .ok = selectionOf(selected.?) };
        },
        .release => |source| {
            try process.check(cancellation);
            candidate = switch (source) {
                .adopt => take: {
                    const value = discovered.*.?;
                    discovered.* = null;
                    break :take value;
                },
                .discover => try fetchRelease(init, allocator, cancellation, diagnostic),
            };
            facts.release = .{ .ok = versionOf(candidate.?.version) };
        },
        .census => {
            hosts = try restart_all.discover(init, allocator, home, cancellation);
            facts.census = .{ .ok = hosts.?.entries.len };
        },
        .checked => break,
        .prepare, .publish, .pin_target, .restart_hosts, .end => unreachable,
    };
    const owned_home = try allocator.dupe(u8, home);
    errdefer allocator.free(owned_home);
    const paths = platform.resolveClientPaths(init.io, store) catch null;
    const owned_store = try allocator.dupe(u8, if (paths) |value| value.selector() else store);
    errdefer allocator.free(owned_store);
    const executable = try allocator.dupeSentinel(u8, try @import("self_executable.zig").path(init.io), 0);
    errdefer allocator.free(executable);
    const path_observation = installation_path.inspect(allocator, init.io, home, init.environ_map.get("PATH") orelse "") catch installation_path.Observation{ .state = .unavailable };
    return .{ .candidate = candidate.?, .selected = selected.?, .hosts = hosts.?, .home = owned_home, .store = owned_store, .running_executable = executable, .path = path_observation };
}

pub fn canInstall(checked: *const Check) bool {
    return upgrade_run.installable(checked.facts(.install));
}

pub fn holdsRelease(checked: *const Check) bool {
    return upgrade_run.holdsRelease(checked.facts(.install));
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

pub fn install(init: std.process.Init, allocator: std.mem.Allocator, checked: *const Check, cancellation: ?*client.Cancellation, progress: ?Progress, cleanup: *CleanupReceipts, diagnostic: *Download) !Result {
    try process.check(cancellation);
    var facts = checked.facts(.install);
    facts.resumed = true;
    if (upgrade_run.next(facts) == .end) return error.UpgradeIneligible;
    const store = try allocator.dupe(u8, checked.store);
    errdefer allocator.free(store);
    var prepared: ?Installation.PreparedBuild = null;
    // A run that ends before publishing still disposes what it prepared.
    defer if (prepared) |*build| build.disposeWithReporter(allocator, init.io, cleanup.reporter(.disposal)) catch {};
    var installation: ?Installation.InstallationOutcome = null;
    errdefer if (installation) |*value| value.deinit(allocator);
    var target: ?restart_all.Target = null;
    defer if (target) |value| value.deinit(allocator);
    var activation_progress: ActivationProgress = .{ .progress = progress };
    var hosts: restart_all.Batch = .{};
    // Errors before publication end the run and are returned; errors after
    // it are recorded beside the kept receipt as a failed restart batch.
    while (true) switch (upgrade_run.next(facts)) {
        .prepare => {
            Progress.send(progress, .preparing);
            prepared = try Installation.prepareWithReporter(allocator, init.io, checked.home, &checked.candidate, cancellation, cleanup.reporter(.preparation), diagnostic);
            facts.prepared = .{ .ok = {} };
        },
        .publish => |source| {
            Progress.send(progress, .publishing);
            try process.check(cancellation);
            installation = switch (source) {
                .selected => try Installation.publishExistingWithReporter(allocator, init.io, checked.home, checked.selected.released.build, .released_upgrade, cancellation, cleanup.reporter(.publication)),
                .prepared => published: {
                    const value = try Installation.publishWithReporter(allocator, init.io, checked.home, &prepared.?, .released_upgrade, cancellation, cleanup.reporter(.publication));
                    prepared.?.disposeWithReporter(allocator, init.io, cleanup.reporter(.disposal)) catch {};
                    prepared = null;
                    break :published value;
                },
            };
            facts.published = .{ .ok = publishedOf(installation.?) };
        },
        .pin_target => {
            const receipt = installation.?.receipt();
            pinTarget(init, allocator, checked.home, receipt, cancellation, &target) catch |err| {
                hosts = .{ .failure = err };
                facts = upgrade_run.failing(facts, causeOf(err));
                continue;
            };
            facts.pinned = .{ .ok = {} };
        },
        .restart_hosts => {
            defer {
                target.?.deinit(allocator);
                target = null;
            }
            hosts = @import("host_coordinator.zig").restart(init, allocator, .{
                .home = checked.home,
                .target = &target.?,
                .cancellation = cancellation,
                .progress = .{ .context = &activation_progress, .report = ActivationProgress.report },
            }) catch |err| {
                hosts = .{ .failure = err };
                facts = upgrade_run.failing(facts, causeOf(err));
                continue;
            };
            facts.hosts = .{ .ok = hosts.summary(store) };
        },
        .end => break,
        .inspect_selection, .release, .census, .checked => unreachable,
    };
    hosts.version = installation.?.receipt().selected_version;
    Progress.send(progress, .finished);
    return .{ .installation = installation.?, .hosts = hosts, .store = store };
}

/// The published build, re-read once the after-publication test gate opens,
/// must have the receipt's version.
fn pinTarget(init: std.process.Init, allocator: std.mem.Allocator, home: []const u8, receipt: Installation.Receipt, cancellation: ?*client.Cancellation, target: *?restart_all.Target) !void {
    try waitAfterPublication(init, cancellation);
    const pinned = try restart_all.Target.init(init, allocator, home, receipt.selected_after, cancellation);
    target.* = pinned;
    if (pinned.version.order(receipt.selected_version.?) != .eq) return error.ReleaseExecutableVersionMismatch;
}

fn waitAfterPublication(init: std.process.Init, cancellation: ?*const client.Cancellation) !void {
    return process.waitForTestGate(init.arena.allocator(), init.io, init.environ_map.get("RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"), cancellation, .fromSeconds(300));
}

pub fn compatible(result: *const Result) bool {
    return host_activation.clientSafe(result.selectedActivation());
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

pub fn hasGuidance(result: *const Result) bool {
    return result.hosts.hasGuidance();
}

/// The line between the check report and the result, so a download never
/// leaves the check's closing notes standing as the run's answer (#1854).
pub fn writeInstalling(writer: *std.Io.Writer, checked: *const Check) !void {
    var facts = checked.facts(.install);
    facts.resumed = true;
    if (upgrade_run.holdsRelease(facts)) {
        const selected = facts.selection.?.ok.released;
        return writer.print("Rui 0.{d}.{d} is already selected; publishing it again and checking running Hosts...\n", .{ selected.schema, selected.patch });
    }
    try writer.print("Installing Rui 0.{d}.{d}...\n", .{ checked.candidate.version.schema, checked.candidate.version.patch });
}

/// The first line is the verdict: upgraded or unchanged, before any Host detail.
pub fn writeResult(writer: *std.Io.Writer, result: *const Result) !void {
    const receipt = result.installation.receipt();
    try writer.writeAll(switch (result.installation) {
        .installed => "Upgraded to Rui",
        .unchanged => "Installation unchanged at Rui",
    });
    if (receipt.selected_version) |version| try writer.print(" 0.{d}.{d}", .{ version.schema, version.patch });
    try writer.writeAll(switch (result.installation) {
        .installed => ". Complete build: ",
        .unchanged => ". Selected complete build: ",
    });
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
        .running_executable = try allocator.dupeSentinel(u8, try @import("self_executable.zig").path(std.testing.io), 0),
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

// SH-69 owns which outcomes guide and which keep the client safe; this checks only
// that the upgrade report routes the selected Store's outcome and renders the Host lines.
test "upgrade result report embeds the Host lines and its rollback note follows guidance" {
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
                try std.testing.expectEqualDeep(if (selected) activation else HostLifecycle.ActivationOutcome.not_needed, result.selectedActivation());
                var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer output.deinit();
                try writeResult(&output.writer, &result);
                var shared: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer shared.deinit();
                try result.hosts.write(&shared.writer);
                try std.testing.expect(std.mem.indexOf(u8, output.written(), shared.written()) != null);
                try std.testing.expectEqual(hasGuidance(&result), std.mem.indexOf(u8, output.written(), "Installation was not rolled back") != null);
            }
        }
    }
}

test "#1854 a non-interactive install says it is installing, then opens its result with the verdict" {
    const candidate: release.ReleaseCandidate = .{ .version = .{ .schema = 83, .patch = 0 }, .tag = "v0.83.0", .archive_name = "fixture", .archive_url = "fixture", .checksum_url = "fixture", .sha256 = @splat(0) };
    for ([_]struct { selected: release.Version, says: []const u8 }{
        .{ .selected = .{ .schema = 82, .patch = 0 }, .says = "Installing Rui 0.83.0...\n" },
        .{ .selected = .{ .schema = 83, .patch = 0 }, .says = "Rui 0.83.0 is already selected; publishing it again and checking running Hosts...\n" },
        .{ .selected = .{ .schema = 84, .patch = 1 }, .says = "Rui 0.84.1 is already selected; publishing it again and checking running Hosts...\n" },
    }) |case| {
        const checked: Check = .{ .candidate = candidate, .selected = .{ .released = .{ .build = "/selected", .version = case.selected } }, .home = "/home", .store = "/store", .running_executable = "/rui" };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try writeInstalling(&output.writer, &checked);
        try std.testing.expectEqualStrings(case.says, output.written());
    }
    const receipt: Installation.Receipt = .{ .operation_build = "/b", .selected_after = "/b", .selected_version = .{ .schema = 83, .patch = 0 } };
    for ([_]struct { installation: Installation.InstallationOutcome, first: []const u8 }{
        .{ .installation = .{ .installed = receipt }, .first = "Upgraded to Rui 0.83.0. Complete build: /b\n" },
        .{ .installation = .{ .unchanged = receipt }, .first = "Installation unchanged at Rui 0.83.0. Selected complete build: /b\n" },
    }) |case| {
        const result: Result = .{ .installation = case.installation, .store = "/store" };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try writeResult(&output.writer, &result);
        try std.testing.expect(std.mem.startsWith(u8, output.written(), case.first));
    }
}

test "adopted candidate stays owned until fresh check preconditions permit consumption" {
    const allocator = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = allocator;
    init.environ_map = &environ;
    try environ.put("RUI_TEST_UPGRADE_RELEASES_URL", "not-a-fixture");
    var candidate: ?release.ReleaseCandidate = try release.fromEffectiveUrl(allocator, "https://fixture/releases/tag/v0.999.2", "https://fixture", "https://fixture", "linux-x86_64");
    defer if (candidate) |*owned| owned.deinit(allocator);
    const identity = candidate.?.archive_url.ptr;
    var download: Download = .{ .family = .ipv4 };
    defer download.deinit(allocator);
    var cancellation: client.Cancellation = .{};
    cancellation.requestStop();
    try std.testing.expectError(error.Cancelled, discoverRelease(init, allocator, &cancellation, &download));
    try std.testing.expectError(error.HomeUnavailable, discoverRelease(init, allocator, null, &download));
    try std.testing.expectError(error.Cancelled, checkDiscovered(init, allocator, "/fixture", &cancellation, &download, &candidate));
    try std.testing.expectEqual(identity, candidate.?.archive_url.ptr);
    try std.testing.expectError(error.HomeUnavailable, checkDiscovered(init, allocator, "/fixture", null, &download, &candidate));
    try std.testing.expectEqual(identity, candidate.?.archive_url.ptr);
    try std.testing.expectEqual(.ipv4, download.family);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    try environ.put("HOME", home);
    try std.testing.expectError(error.InvalidReleaseEndpoint, discoverRelease(init, allocator, null, &download));
    try std.testing.expectEqual(identity, candidate.?.archive_url.ptr);
    try environ.put("HOME", "relative");
    try std.testing.expectError(error.InvalidInstallationHome, discoverRelease(init, allocator, null, &download));
    try std.testing.expectError(error.InvalidInstallationHome, checkDiscovered(init, allocator, home, null, &download, &candidate));
    try std.testing.expectEqual(identity, candidate.?.archive_url.ptr);
    try std.testing.expectEqual(.ipv4, download.family);
}

test "upgrade selected activation routes by Host directory not SQLite data or MySQL identity" {
    const receipt: Installation.Receipt = .{ .operation_build = "/prepared", .selected_after = "/selected" };
    for ([_][]const u8{ "/data", "0123456789abcdef0123456789abcdef" }) |identity| {
        var entries = [_]restart_all.Entry{
            .{ .socket = "/first.sock", .directory = "/first-host", .store = "/selected-host", .state = .{ .outcome = .not_needed } },
            .{ .socket = "/selected.sock", .directory = "/selected-host", .store = identity, .state = .{ .outcome = .{ .unsupported = .configuration_unavailable } } },
        };
        const result: Result = .{ .installation = .{ .installed = receipt }, .store = "/selected-host", .hosts = .{ .entries = &entries } };
        try std.testing.expectEqual(HostLifecycle.Limitation.configuration_unavailable, result.selectedActivation().unsupported);
        try std.testing.expect(result.hosts.selectedOutcome(identity) == .not_needed);
    }
}

test "SH-76 Upgrade fact conversions preserve every classified error and receipt" {
    // Every error classified as an Upgrade download, release, or preparation
    // failure by caller_error, plus cancellation and the catch-all class.
    const cases = [_]struct { anyerror, upgrade_run.Cause }{
        .{ error.Cancelled, .cancelled },
        .{ error.ReleaseDownloadFailed, .download },
        .{ error.InvalidReleaseVersion, .release },
        .{ error.InvalidReleaseChecksum, .release },
        .{ error.DuplicateReleaseChecksum, .release },
        .{ error.MissingReleaseChecksum, .release },
        .{ error.InvalidReleaseEndpoint, .release },
        .{ error.UnsupportedReleasePlatform, .release },
        .{ error.InvalidManagedBuild, .preparation },
        .{ error.InvalidReleaseExecutable, .preparation },
        .{ error.ReleaseArchiveTooLarge, .preparation },
        .{ error.ReleaseChecksumMismatch, .preparation },
        .{ error.ReleaseExecutableVersionMismatch, .preparation },
        .{ error.UnsafeReleaseArchive, .preparation },
        .{ error.UpgradeChildFailed, .preparation },
        .{ error.UpgradeIneligible, .other },
        .{ error.HostRestartFailed, .other },
        .{ error.OutOfMemory, .other },
        .{ error.AccessDenied, .other },
        .{ error.UnclassifiedUpgradeTestFailure, .other },
    };
    for (cases) |row| try std.testing.expectEqual(row[1], causeOf(row[0]));
    // `anyerror` is open-ended; after cancellation every possible classifier
    // result belongs to this finite domain, including all non-Upgrade codes.
    for (std.enums.values(caller_error.Code)) |code| {
        const expected: upgrade_run.Cause = switch (code) {
            .upgrade_download_failed => .download,
            .upgrade_release_invalid => .release,
            .upgrade_preparation_failed => .preparation,
            else => .other,
        };
        try std.testing.expectEqual(expected, causeOfCode(code));
    }

    const receipt: Installation.Receipt = .{ .operation_build = "/operation", .selected_after = "/selected", .selected_version = .{ .schema = 61, .patch = 7 } };
    const check_value: Check = .{
        .candidate = .{ .version = .{ .schema = 60, .patch = 1 }, .tag = "", .archive_name = "", .archive_url = "", .checksum_url = "", .sha256 = @splat(0) },
        .selected = .{ .released = .{ .build = "/old", .version = .{ .schema = 59, .patch = 2 } } },
        .home = "/home",
        .store = "/store",
        .running_executable = "/rui",
    };
    for ([_]bool{ false, true }) |changed| {
        const result: Result = .{ .installation = if (changed) .{ .installed = receipt } else .{ .unchanged = receipt }, .store = "/store" };
        const expected: upgrade_run.Published = .{ .changed = changed, .selected = .{ .schema = 61, .patch = 7 } };
        try std.testing.expectEqualDeep(expected, publishedOf(result.installation));
        const full = result.facts(&check_value);
        var partial: upgrade_run.Facts = .{ .mode = .install };
        result.addFacts(&partial);
        try std.testing.expectEqualDeep(expected, full.published.?.ok);
        try std.testing.expectEqualDeep(expected, partial.published.?.ok);
        try std.testing.expectEqualDeep(full.hosts.?.ok, partial.hosts.?.ok);
        try std.testing.expectEqualDeep(upgrade_run.Version{ .schema = 60, .patch = 1 }, check_value.facts(.install).release.?.ok);
    }
}
