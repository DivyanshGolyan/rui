const std = @import("std");
const client = @import("client.zig");
const release = @import("release_candidate.zig");
const Installation = @import("Installation.zig");
const HostLifecycle = @import("HostLifecycle.zig");
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

pub const Check = struct {
    candidate: release.ReleaseCandidate,
    selected: Installation.Selection,
    host: HostLifecycle.Observation,
    home: []const u8,
    store: []const u8,
    running_executable: []const u8,
    path: installation_path.Observation = .{ .state = .unavailable },

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        self.candidate.deinit(allocator);
        self.selected.deinit(allocator);
        self.host.deinit(allocator);
        self.path.deinit(allocator);
        allocator.free(self.home);
        allocator.free(self.store);
        allocator.free(self.running_executable);
    }
};

pub const Result = struct {
    installation: Installation.InstallationOutcome,
    activation: HostLifecycle.ActivationOutcome,
    store: []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.installation.deinit(allocator);
        allocator.free(self.store);
    }
};

pub fn check(init: std.process.Init, allocator: std.mem.Allocator, store: []const u8, cancellation: ?*client.Cancellation) !Check {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    const endpoint = init.environ_map.get("RUI_TEST_UPGRADE_API_URL") orelse release.default_endpoint;
    var selected = try Installation.inspectCancellable(allocator, init.io, home, cancellation);
    errdefer selected.deinit(allocator);
    var candidate = try release.discover(allocator, init.io, endpoint, cancellation);
    errdefer candidate.deinit(allocator);
    var host = try HostLifecycle.observe(allocator, init.io, home, store, cancellation);
    errdefer host.deinit(allocator);
    const owned_home = try allocator.dupe(u8, home);
    errdefer allocator.free(owned_home);
    const owned_store = try allocator.dupe(u8, store);
    errdefer allocator.free(owned_store);
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    errdefer allocator.free(executable);
    const path_observation = installation_path.inspect(allocator, init.io, home, init.environ_map.get("PATH") orelse "") catch installation_path.Observation{ .state = .unavailable };
    return .{ .candidate = candidate, .selected = selected, .host = host, .home = owned_home, .store = owned_store, .running_executable = executable, .path = path_observation };
}

pub fn canInstall(checked: *const Check) bool {
    return checked.selected == .released;
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

pub fn install(init: std.process.Init, allocator: std.mem.Allocator, checked: *const Check, cancellation: ?*client.Cancellation, progress: ?Progress, cleanup: *CleanupReceipts) !Result {
    try process.check(cancellation);
    if (!canInstall(checked)) return error.UpgradeIneligible;
    const store = try allocator.dupe(u8, checked.store);
    errdefer allocator.free(store);
    var installation: Installation.InstallationOutcome = undefined;
    const selected = checked.selected.released;
    if (selected.version.order(checked.candidate.version) != .lt) {
        installation = try Installation.publishExistingWithReporter(allocator, init.io, checked.home, selected.build, .released_upgrade, cancellation, cleanup.reporter(.publication));
    } else {
        Progress.send(progress, .preparing);
        var prepared = try Installation.prepareWithReporter(allocator, init.io, checked.home, &checked.candidate, cancellation, cleanup.reporter(.preparation));
        defer prepared.disposeWithReporter(allocator, init.io, cleanup.reporter(.disposal)) catch {};
        Progress.send(progress, .publishing);
        installation = try Installation.publishWithReporter(allocator, init.io, checked.home, &prepared, .released_upgrade, cancellation, cleanup.reporter(.publication));
    }
    errdefer installation.deinit(allocator);
    var activation_progress: ActivationProgress = .{ .progress = progress };
    const receipt = installation.receipt();
    const activation = activateSelected(init, allocator, checked, receipt.selected_after, cancellation, &activation_progress);

    Progress.send(progress, .finished);
    return .{ .installation = installation, .activation = activation, .store = store };
}

fn activateSelected(init: std.process.Init, allocator: std.mem.Allocator, checked: *const Check, selected: []const u8, cancellation: ?*client.Cancellation, progress: *ActivationProgress) HostLifecycle.ActivationOutcome {
    if (init.environ_map.get("RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE")) |gate| {
        while (true) {
            process.check(cancellation) catch return .cancelled;
            const file = std.Io.Dir.cwd().openFile(init.io, gate, .{}) catch |err| {
                if (err == error.FileNotFound) break;
                return .{ .unconfirmed = .starting };
            };
            file.close(init.io);
            std.Io.sleep(init.io, .fromMilliseconds(10), .awake) catch return .{ .unconfirmed = .starting };
        }
    }
    process.check(cancellation) catch return .cancelled;
    const binary = std.fmt.allocPrint(allocator, "{s}/bin/rui", .{selected}) catch return .{ .unconfirmed = .verifying };
    defer allocator.free(binary);
    const reported = process.output(allocator, init.io, &.{ binary, "--version" }, cancellation, 512) catch return .{ .unconfirmed = .verifying };
    defer allocator.free(reported);
    const version = HostLifecycle.releaseVersion(reported) orelse return .{ .unconfirmed = .verifying };
    if (version.order(checked.candidate.version) != .eq) return .superseded;
    return HostLifecycle.activate(init, allocator, &checked.host, selected, checked.candidate.version, cancellation, .{ .context = progress, .report = ActivationProgress.report }) catch .{ .unconfirmed = .starting };
}

pub fn compatible(result: *const Result) bool {
    return switch (result.activation) {
        .unconfirmed, .failed, .replacement_observed => false,
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
    try writer.print("\nLatest published stable: 0.{d}.{d}\nAffected Store: ", .{ checked.candidate.version.schema, checked.candidate.version.patch });
    try field(writer, checked.store);
    try writer.writeAll("\n");
    try installation_path.write(writer, &checked.path, checked.home);
    switch (checked.host) {
        .absent => try writer.writeAll("No Host was running. Upgrade installs only; no Host will be started.\n"),
        .managed => try writer.writeAll("Install restarts this Store's running Host and interrupts work across ALL Sessions in this Store.\n"),
        .unsupported => |reason| try writer.print("Host activation unavailable ({s}). Its owner must restart it; Upgrade will not pause it.\n", .{@tagName(reason)}),
    }
    try writer.writeAll("Store compatibility is validated by the target Host at startup; checking/installing never migrates it.\nThe running client and bundled/custom application binaries are not replaced.\n");
    if (!canInstall(checked)) try writer.writeAll("Upgrade cannot replace this destination. Use the existing manual release installer or application owner.\n");
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
    try writer.writeAll("\nActivation: ");
    switch (result.activation) {
        .not_needed => try writer.writeAll("not needed; no Host was initially running and none was started."),
        .superseded => try writer.writeAll("not attempted; a newer release is selected. No downgrade or restart occurred."),
        .already_ready => try writer.writeAll("already running the selected pinned build; no restart needed."),
        .ready => try writer.writeAll("ready; the exact launched Host instance, Store and pinned build identity were verified."),
        .unsupported => |reason| try writer.print("not permitted ({s}); the existing Host was left running. Use its application/launch owner.", .{@tagName(reason)}),
        .replacement_observed => try writer.writeAll("not confirmed; another Host instance owns this Store. It was not paused or accepted as this launch."),
        .cancelled => try writer.writeAll("cancelled after installation; publication was not rolled back."),
        .failed => |stage| try writer.print("failed at {s}; the release remains installed.", .{@tagName(stage)}),
        .unconfirmed => |stage| try writer.print("unconfirmed at {s}; the release remains installed. Do not retry indeterminate work.", .{@tagName(stage)}),
    }
    try writer.writeAll("\nStore: ");
    try field(writer, result.store);
    switch (result.activation) {
        .failed, .unconfirmed, .replacement_observed, .cancelled => {
            try writer.writeAll("\nNext: inspect rui host status --store ");
            try TerminalText.writeShellWord(writer, result.store);
            try writer.writeAll(". Do not restore/reset the Store or replay uncertain requests.\n");
        },
        else => try writer.writeAll("\n"),
    }
}

test "upgrade activation and publication are independent result facts" {
    var installation: Installation.InstallationOutcome = .{ .unchanged = .{ .operation_build = try std.testing.allocator.dupe(u8, "/managed/build"), .selected_after = try std.testing.allocator.dupe(u8, "/managed/build") } };
    defer installation.deinit(std.testing.allocator);
    const result: Result = .{ .installation = installation, .activation = .{ .unconfirmed = .verifying }, .store = "/store" };
    try std.testing.expect(!compatible(&result));
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeResult(&writer, &result);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Installation unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unconfirmed at verifying") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Do not restore/reset") != null);
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
