const std = @import("std");
const upgrade = @import("upgrade.zig");
const installation_path = @import("installation_path.zig");
const caller_error = @import("caller_error.zig");
const ClientTask = @import("ClientTask.zig");
const upgrade_status = @import("upgrade_status.zig");
const upgrade_run = @import("upgrade_run.zig");
const release_candidate = @import("release_candidate.zig");
const test_poll = @import("test_poll");
const Self = @This();

pub const Outcome = @import("session_upgrade.zig").Outcome;
const Operation = enum { discover, check, install };

init: std.process.Init = undefined,
store: []const u8 = "",
allocator: std.mem.Allocator = undefined,
task: ClientTask = .{},
phase: std.atomic.Value(upgrade.Phase) = .init(.checking),
gate: std.atomic.Value(enum(u8) { open, cancelled, committed }) = .init(.open),
operation: Operation = .check,
candidate: ?release_candidate.ReleaseCandidate = null,
discovery_attempted: bool = false,
discovery_adopted: bool = false,
checked: ?upgrade.Check = null,
result: ?upgrade.Result = null,
cleanup: upgrade.CleanupReceipts = .{},
download: upgrade.Download = .{},
failure: ?anyerror = null,
outcome: Outcome = .unchanged,
cancelling: bool = false,
started: bool = false,
finished: bool = false,

pub fn discover(self: *Self, init: std.process.Init) !void {
    std.debug.assert(!self.discovery_attempted);
    self.discovery_attempted = true;
    self.operation = .discover;
    try self.begin(init, "");
}

pub fn discovering(self: *const Self) bool {
    return self.operation == .discover;
}

pub fn retireDiscovery(self: *Self, cancelled: bool) !bool {
    std.debug.assert(self.discovering() and self.started);
    self.discovery_adopted = self.discovery_adopted or !self.finished;
    if (cancelled) {
        self.cancel();
        self.cancelling = true;
    }
    if (!try self.advance()) return false;
    if (cancelled or self.cancelling or (self.discovery_adopted and self.failure != null)) {
        if (self.candidate) |*candidate| candidate.deinit(self.allocator);
        self.candidate = null;
        self.operation = .check;
    } else if (self.failure != null or self.candidate == null) {
        self.deinit();
    } else {
        std.debug.assert(self.checked == null and self.result == null and self.task.thread == null);
        self.* = .{ .allocator = self.allocator, .candidate = self.candidate, .download = self.download, .discovery_attempted = true };
    }
    return true;
}

pub fn availability(self: *const Self) ?upgrade_status.Version {
    if (!self.discovering() or !self.finished or self.cancelling or self.failure != null) return null;
    const candidate = self.candidate orelse return null;
    return newerRelease(@import("transport_options").version, candidate.version);
}

pub fn begin(self: *Self, init: std.process.Init, store: []const u8) !void {
    std.debug.assert(!self.started and self.task.thread == null);
    self.init = init;
    self.store = store;
    self.allocator = init.gpa;
    self.started = true;
    self.discovery_attempted = true;
    if (self.cancelling) return self.finish();
    self.task.start(init.io, self, work) catch |err| {
        self.failure = err;
        self.finished = true;
        return err;
    };
}

fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (self.operation) {
        .discover => self.candidate = try upgrade.discoverRelease(self.init, self.allocator, &task.cancellation, &self.download),
        .check => self.checked = try upgrade.checkDiscovered(self.init, self.allocator, self.store, &task.cancellation, &self.download, &self.candidate),
        .install => self.result = try upgrade.install(self.init, self.allocator, &self.checked.?, &task.cancellation, .{ .context = self, .report = progress }, &self.cleanup, &self.download),
    }
}

fn newerRelease(running_text: []const u8, candidate: @import("release_candidate.zig").Version) ?upgrade_status.Version {
    const running = @import("release_candidate.zig").Version.parse(running_text) catch return null;
    return if (running.order(candidate) == .lt) upgrade.versionOf(candidate) else null;
}

fn progress(raw: *anyopaque, phase: upgrade.Phase) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    std.debug.assert(!self.finished);
    if (phase == .publishing) {
        if (self.gate.cmpxchgStrong(.open, .committed, .acq_rel, .acquire) != null) {
            self.task.cancellation.requestStop();
            return;
        }
    }
    self.phase.store(phase, .release);
}

pub fn advance(self: *Self) !bool {
    return self.advanceWith(work);
}

fn advanceWith(self: *Self, worker: ClientTask.Run) !bool {
    std.debug.assert(self.started);
    if (self.finished) return true;
    if (!self.task.completed()) return false;
    self.joinWorker();
    if (self.operation == .check and self.failure == null and !self.cancelling) {
        if (self.checked) |*checked| if (upgrade_run.next(resumed(checked)) != .end) {
            self.operation = .install;
            self.phase.store(.preparing, .release);
            self.task.start(self.init.io, self, worker) catch |err| {
                self.failure = err;
                self.finished = true;
                return true;
            };
            return false;
        };
    }
    self.finish();
    return true;
}

fn joinWorker(self: *Self) void {
    self.task.join() catch |err| {
        self.failure = err;
    };
}

fn finish(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    self.outcome = upgrade_run.outcome(self.facts());
    self.phase.store(.finished, .release);
    self.finished = true;
}

pub fn cancel(self: *Self) void {
    if (self.finished) return;
    if (self.gate.cmpxchgStrong(.open, .cancelled, .acq_rel, .acquire)) |gate| if (gate == .committed) return;
    self.abandon();
}

fn abandon(self: *Self) void {
    if (self.finished) return;
    self.cancelling = true;
    if (self.started) self.task.cancel();
}

pub fn settle(self: *Self) void {
    if (!self.started or self.finished) return;
    self.abandon();
    self.joinWorker();
    self.finish();
}

pub fn deinit(self: *Self) void {
    self.settle();
    if (self.result) |*result| result.deinit(self.allocator);
    if (self.candidate) |*candidate| candidate.deinit(self.allocator);
    if (self.checked) |*checked| checked.deinit(self.allocator);
    self.download.deinit(self.allocator);
    self.* = .{ .discovery_attempted = self.discovery_attempted };
}

fn resumed(checked: *const upgrade.Check) upgrade_run.Facts {
    var value = checked.facts(.install);
    value.resumed = true;
    return value;
}

// Only joined results are read here; progress is the existing atomic.
fn facts(self: *const Self) upgrade_run.Facts {
    var value: upgrade_run.Facts = .{ .mode = .install };
    if (self.operation == .install or self.task.thread == null) {
        if (self.checked) |*check| value = check.facts(.install);
    }
    value.resumed = self.operation == .install;
    if (self.task.thread == null) {
        if (self.result) |*result| {
            if (self.checked) |*check| {
                value = result.facts(check);
            } else {
                result.addFacts(&value);
            }
        }
        if (self.failure) |err| {
            const cause = upgrade.causeOf(err);
            if (self.checked == null) value.selection = .{ .failed = cause } else value.prepared = .{ .failed = cause };
        }
    }
    return value;
}

pub fn status(self: *const Self) upgrade_status.Run {
    return upgrade_run.run(self.facts(), self.cancelling, self.finished, self.phase.load(.acquire));
}

fn ending(self: *const Self) upgrade_status.Ended {
    return upgrade_run.ending(self.facts(), self.cancelling);
}

pub fn writeReceipt(self: *const Self, writer: *std.Io.Writer) !void {
    std.debug.assert(!self.started or self.finished);
    if (self.result) |*result| try upgrade.writeResult(writer, result);
    if (self.checked) |*checked| try installation_path.write(writer, &checked.path, checked.home);
    try self.cleanup.write(writer);
}

pub fn relaunchBuild(self: *const Self) ?[]const u8 {
    std.debug.assert(!self.started or self.finished);
    const result = &(self.result orelse return null);
    if (!upgrade_run.installed(self.facts())) return null;
    return result.installation.receipt().selected_after;
}

pub fn hasGuidance(self: *const Self) bool {
    return upgrade_run.guidance(self.facts(), self.cleanup.any(), if (self.checked) |checked| checked.path.state == .selected else true);
}

pub fn writeReport(self: *const Self, writer: *std.Io.Writer) !void {
    std.debug.assert(!self.started or self.finished);
    if (self.checked) |*checked| try upgrade.writeCheck(writer, checked);
    if (self.result) |*result| {
        try writer.writeAll("\n");
        try upgrade.writeResult(writer, result);
    }
    if (self.result == null and std.meta.activeTag(self.ending()) == .cancelled) {
        try writer.writeAll("\nUpgrade cancelled; nothing changed.\n");
    } else if (self.failure) |err| {
        try writer.print("\nUpgrade {s} failed: {s}\n", .{ if (self.operation == .check) "check" else "installation", failureWords(err) });
        try self.download.write(writer);
        if (self.operation == .install and self.result == null) try writer.writeAll("No completed installation receipt; inspect the selected command and Host before retrying.\n");
    }
    try self.cleanup.write(writer);
    if (self.outcome == .incompatible) try writer.writeAll("\nThis client cannot safely resume Host requests. Keep the draft and recovery handles; use the selected Rui in a new terminal. Do not resend indeterminate work.\n");
}

fn failureWords(err: anyerror) []const u8 {
    return switch (caller_error.of(err)) {
        .upgrade_download_failed, .upgrade_release_invalid, .upgrade_preparation_failed, .upgrade_ineligible => |code| caller_error.facts(code).says,
        else => "Rui could not finish it. Check network access and disk space, then select Version in app settings again.",
    };
}

const test_result: upgrade.Result = .{
    .installation = .{ .installed = .{ .operation_build = "/synthetic/installed", .selected_after = "/synthetic/installed", .selected_version = .{ .schema = 60, .patch = 1 } } },
    .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/synthetic/store", .state = .{ .outcome = .cancelled } }}) },
    .store = "/synthetic/store",
};

test "joined installation cancellation retains the actual publication receipt" {
    var job: Self = .{ .started = true, .operation = .install, .result = test_result, .cancelling = true };
    job.finish();
    try std.testing.expectEqual(Outcome.compatible, job.outcome);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try job.writeReport(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Installed Rui. Complete build: /synthetic/installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Installation was not rolled back") != null);
    var receipt_bytes: [4096]u8 = undefined;
    var receipt = std.Io.Writer.fixed(&receipt_bytes);
    try job.writeReceipt(&receipt);
    try std.testing.expect(std.mem.indexOf(u8, receipt.buffered(), "Installed Rui. Complete build: /synthetic/installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.buffered(), "Installation was not rolled back") != null);
    job.result = null;
}

test "a failed run says why in plain words, not an error name" {
    const cases = [_]struct { Operation, anyerror, []const u8 }{
        .{ .check, error.ReleaseDownloadFailed, "Upgrade check failed: Rui could not download release information or the archive from GitHub." },
        .{ .check, error.InvalidReleaseVersion, "Upgrade check failed: Published stable release tag or platform checksums could not be validated." },
        .{ .install, error.ReleaseChecksumMismatch, "Upgrade installation failed: Release preparation or validation failed." },
        .{ .check, error.ConnectionRefused, "Upgrade check failed: Rui could not finish it." },
    };
    for (cases) |case| {
        const job: Self = .{ .started = true, .finished = true, .operation = case[0], .failure = case[1] };
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try job.writeReport(&writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), case[2]) != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), @errorName(case[1])) == null);
    }
}

test "a failed download report retains curl's last stderr line" {
    const allocator = std.testing.allocator;
    var job: Self = .{ .allocator = allocator, .started = true, .finished = true, .failure = error.ReleaseDownloadFailed };
    defer job.deinit();
    job.download.stderr = try allocator.dupe(u8, "earlier diagnostic\ncurl: (22) The requested URL returned error: 403\n");
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try job.writeReport(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "curl: (22) The requested URL returned error: 403\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "earlier diagnostic") == null);
}

test "cleanup report retains copied paths and the worker error" {
    var job: Self = .{ .started = true, .finished = true, .operation = .install, .failure = error.ReleaseChecksumMismatch };
    var source = "/synthetic/retained-stage".*;
    const reporter = job.cleanup.reporter(.preparation);
    reporter.report(reporter.context, .{ .primary = error.ReleaseChecksumMismatch, .secondary = error.AccessDenied, .retained_path = &source });
    @memset(&source, 'x');
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try job.writeReport(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ReleaseChecksumMismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "$'/synthetic/retained-stage'") != null);
}

test "settle requests cancellation and joins before returning the failure" {
    const Gate = struct {
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        fn run(raw: *anyopaque, task: *ClientTask) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            gate.entered.set(task.io);
            gate.released.waitUncancelable(task.io);
            return error.Cancelled;
        }
    };
    var gate: Gate = .{};
    var job: Self = .{ .started = true };
    try job.task.start(std.testing.io, &gate, Gate.run);
    defer {
        gate.released.set(std.testing.io);
        job.task.join() catch {};
    }
    gate.entered.waitUncancelable(std.testing.io);
    job.cancel();
    try std.testing.expect(job.cancelling);
    try std.testing.expect(job.task.thread != null);
    gate.released.set(std.testing.io);
    job.settle();
    try std.testing.expect(job.finished and job.task.thread == null);
    try std.testing.expectEqual(error.Cancelled, job.failure.?);
    job.deinit();
}

test "Esc and publication race on one gate: whichever comes first holds" {
    {
        var job: Self = .{ .started = true, .operation = .install };
        progress(&job, .preparing);
        progress(&job, .publishing);
        job.cancel();
        try std.testing.expect(!job.cancelling);
        try std.testing.expect(!job.task.cancellation.stopped.load(.acquire));
        try std.testing.expectEqual(upgrade.Phase.publishing, job.phase.load(.acquire));
    }
    {
        var job: Self = .{ .started = true, .operation = .install };
        progress(&job, .preparing);
        job.cancel();
        try std.testing.expect(job.cancelling);
        progress(&job, .publishing);
        try std.testing.expect(job.task.cancellation.stopped.load(.acquire));
        try std.testing.expectEqual(upgrade.Phase.preparing, job.phase.load(.acquire));
    }
    {
        var job: Self = .{ .started = true, .operation = .install };
        progress(&job, .publishing);
        job.abandon();
        try std.testing.expect(job.cancelling);
    }
}

test "a cancel before the worker starts ends the run cancelled without checking" {
    var init: std.process.Init = undefined;
    init.io = std.testing.io;
    init.gpa = std.testing.allocator;
    var job: Self = .{};
    job.cancel();
    try std.testing.expect(job.cancelling);
    try job.begin(init, "/store");
    try std.testing.expect(try job.advance());
    try std.testing.expect(job.task.thread == null and job.checked == null and job.result == null);
    try std.testing.expectEqual(upgrade_status.Ended.cancelled, job.ending());
    job.deinit();
}

test "a successful receipt keeps the check's PATH advice: a shadowed or missing install says how to fix it" {
    for ([_]@FieldType(@FieldType(upgrade.Check, "path"), "state"){ .shadowed, .missing, .selected }) |state| {
        var checked = news_check;
        checked.path = .{ .state = state, .other = if (state == .selected) null else "/usr/bin/rui" };
        const job: Self = .{ .started = true, .finished = true, .operation = .install, .checked = checked, .result = test_result };
        var bytes: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try job.writeReceipt(&writer);
        const out = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, out, "Installation unchanged") != null or std.mem.indexOf(u8, out, "Installed Rui") != null);
        const advice = std.mem.indexOf(u8, out, "/usr/bin/rui") != null;
        try std.testing.expectEqual(state != .selected, advice);
    }
}

test "failed check finishes without installation" {
    const Worker = struct {
        fn run(_: *anyopaque, _: *ClientTask) !void {
            return error.ReleaseChecksumMismatch;
        }
    };
    var job: Self = .{ .started = true };
    try job.task.start(std.testing.io, &job, Worker.run);
    while (!try job.advance()) std.Thread.yield() catch {};
    try std.testing.expect(job.operation == .check);
    try std.testing.expectEqual(error.ReleaseChecksumMismatch, job.failure.?);
    try std.testing.expectEqual(Outcome.unchanged, job.outcome);
    job.deinit();
}

test "completed check starts install automatically only when eligible and not cancelled" {
    const check: upgrade.Check = .{
        .candidate = .{ .version = .{ .schema = 99, .patch = 1 }, .tag = "v0.99.1", .archive_name = "fixture", .archive_url = "fixture", .checksum_url = "fixture", .sha256 = @splat(0) },
        .selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 99, .patch = 0 } } },
        .hosts = .{},
        .home = "/synthetic/home",
        .store = "/synthetic/store",
        .running_executable = "/synthetic/rui",
    };
    const Worker = struct {
        fn run(raw: *anyopaque, _: *ClientTask) !void {
            const job: *Self = @ptrCast(@alignCast(raw));
            if (job.operation == .install) job.result = test_result;
        }
    };
    for (0..3) |case| {
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        var job: Self = .{ .init = init, .started = true, .checked = check };
        if (case == 1) job.checked.?.selected = .absent;
        try job.task.start(init.io, &job, Worker.run);
        while (!job.task.completed()) std.Thread.yield() catch {};
        if (case == 2) job.cancel();
        const finished = try job.advanceWith(Worker.run);
        if (case == 0) {
            try std.testing.expect(!finished and job.operation == .install);
            while (!try job.advanceWith(Worker.run)) std.Thread.yield() catch {};
            try std.testing.expect(job.result != null);
            try std.testing.expectEqual(Outcome.compatible, job.outcome);
        } else {
            try std.testing.expect(finished and job.operation == .check);
            try std.testing.expect(job.result == null);
        }
        job.checked = null;
        job.result = null;
        job.deinit();
    }
}

const news_check: upgrade.Check = .{
    .candidate = .{ .version = .{ .schema = 60, .patch = 1 }, .tag = "v0.60.1", .archive_name = "fixture", .archive_url = "fixture", .checksum_url = "fixture", .sha256 = @splat(0) },
    .selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 59, .patch = 7 } } },
    .hosts = .{},
    .home = "/synthetic/home",
    .store = "/synthetic/store",
    .running_executable = "/synthetic/rui",
};

test "the run's status: checking, the release found, each restart step, then how it ended" {
    var job: Self = .{ .started = true, .checked = news_check };
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status());
    job.operation = .install;
    job.phase.store(.preparing, .release);
    const found: upgrade_status.Found = .{ .host = .none };
    try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = found } }, job.status());
    job.checked.?.hosts = .{ .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/s", .state = .{ .outcome = .{ .unsupported = .incompatible } } }}) };
    try std.testing.expectEqual(upgrade_status.Host{ .running = 1 }, job.status().installing.found.host);
    job.checked.?.hosts = .{};
    for ([_]struct { upgrade.Phase, upgrade_status.Step }{
        .{ .publishing, .publishing }, .{ .stopping, .restarting }, .{ .awaiting_retirement, .restarting }, .{ .starting, .restarting }, .{ .verifying, .restarting },
    }) |case| {
        job.phase.store(case[0], .release);
        try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = found, .step = case[1] } }, job.status());
    }
    job.result = .{ .installation = .{ .installed = .{ .operation_build = "/b", .selected_after = "/b", .selected_version = .{ .schema = 60, .patch = 1 } } }, .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/s", .state = .{ .outcome = .{ .ready = .{ .instance = @splat(0), .pid = 1 } } } }}) }, .store = "/s" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 1 }, .restarted = true } }, .outcome = .compatible } }, job.status());
    job.result = null;
    job.checked = null;
}

test "a stop asked for shows until the run ends, before the worker starts and while it prepares, and not once it published" {
    var waiting: Self = .{};
    try std.testing.expectEqual(upgrade_status.Run.checking, waiting.status());
    waiting.cancel();
    try std.testing.expectEqual(upgrade_status.Run.cancelling, waiting.status());
    var preparing: Self = .{ .started = true, .operation = .install, .checked = news_check };
    progress(&preparing, .preparing);
    preparing.cancel();
    try std.testing.expectEqual(upgrade_status.Run.cancelling, preparing.status());
    preparing.checked = null;
    var published: Self = .{ .started = true, .operation = .install, .checked = news_check };
    progress(&published, .publishing);
    published.cancel();
    try std.testing.expectEqual(upgrade_status.Step.publishing, published.status().installing.step);
    published.checked = null;
}

test "a selected release still shows the census while its Hosts are checked for restart" {
    var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
    job.checked.?.selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 60, .patch = 1 } } };
    job.checked.?.hosts = .{ .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/s", .state = .{ .outcome = .not_needed } }}) };
    job.phase.store(.stopping, .release);
    try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = .{ .host = .{ .running = 1 } }, .step = .restarting } }, job.status());
    job.checked = null;
}

test "a newer build already selected installs quietly: no older release found, then superseded" {
    var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
    job.checked.?.selected.released.version = .{ .schema = 60, .patch = 2 };
    job.phase.store(.publishing, .release);
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status());
    job.result = .{ .installation = .{ .unchanged = .{ .operation_build = "/b", .selected_after = "/b", .selected_version = .{ .schema = 60, .patch = 2 } } }, .hosts = .{ .version = .{ .schema = 60, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "", .state = .{ .outcome = .superseded } }}) }, .store = "" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .superseded = .{ .schema = 60, .patch = 2 } }, .outcome = .compatible } }, job.status());
    job.result = null;
    job.checked = null;
}

test "the selected build already current installs quietly: no found release, then up to date" {
    var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
    job.checked.?.selected.released.version = .{ .schema = 60, .patch = 1 };
    job.phase.store(.publishing, .release);
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status());
    job.result = .{ .installation = .{ .unchanged = .{ .operation_build = "/b", .selected_after = "/b", .selected_version = .{ .schema = 60, .patch = 1 } } }, .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "", .state = .{ .outcome = .not_needed } }}) }, .store = "" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 60, .patch = 1 } }, .outcome = .compatible } }, job.status());
    job.result = null;
    job.checked = null;
}

test "relaunch uses only an installed receipt selection and keeps every guidance category" {
    const Installation = @import("Installation.zig");
    const receipt: Installation.Receipt = .{ .operation_build = "/downloaded/target", .selected_after = "/published/selection", .selected_version = .{ .schema = 60, .patch = 1 } };
    for ([_]bool{ false, true }) |installed| {
        var job: Self = .{ .finished = true, .result = .{ .installation = if (installed) .{ .installed = receipt } else .{ .unchanged = receipt }, .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/store", .state = .{ .outcome = .not_needed } }}) }, .store = "/store" } };
        if (installed) try std.testing.expectEqualStrings("/published/selection", job.relaunchBuild().?) else try std.testing.expect(job.relaunchBuild() == null);
        try std.testing.expect(!job.hasGuidance());
        job.failure = error.ConnectionRefused;
        try std.testing.expect(job.hasGuidance());
        job.failure = null;
        inline for (std.enums.values(upgrade.CleanupReceipts.Phase)) |phase| {
            job.cleanup = .{};
            const reporter = job.cleanup.reporter(phase);
            reporter.report(reporter.context, .{ .primary = null, .secondary = error.AccessDenied, .retained_path = "/retained" });
            try std.testing.expect(job.hasGuidance());
        }
        job.cleanup = .{};
        var checked: upgrade.Check = news_check;
        inline for (.{ .selected, .shadowed, .missing, .unavailable }) |state| {
            checked.path = .{ .state = state };
            job.checked = checked;
            try std.testing.expectEqual(state != .selected, job.hasGuidance());
        }
    }
}

test "relaunch job retains the result owner's guidance for every activation and installation" {
    const Installation = @import("Installation.zig");
    const HostLifecycle = @import("HostLifecycle.zig");
    const receipt: Installation.Receipt = .{ .operation_build = "/prepared", .selected_after = "/selected", .selected_version = .{ .schema = 60, .patch = 1 } };
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const activation = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        for ([_]bool{ false, true }) |installed| {
            const result: upgrade.Result = .{
                .installation = if (installed) .{ .installed = receipt } else .{ .unchanged = receipt },
                .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = @constCast(&[_]@import("host_restart_all.zig").Entry{.{ .socket = "", .store = "/store", .state = .{ .outcome = activation } }}) },
                .store = "/store",
            };
            const job: Self = .{ .finished = true, .result = result };
            try std.testing.expectEqual(upgrade.hasGuidance(&result), job.hasGuidance());
        }
    }
}

test "a failed release check never offers a relaunch" {
    const job: Self = .{ .started = true, .finished = true, .failure = error.ReleaseDownloadFailed };
    try std.testing.expect(job.relaunchBuild() == null);
    try std.testing.expect(job.hasGuidance());
    try std.testing.expectEqualDeep(upgrade_status.Ended{ .failed = .download }, job.ending());
}

test "#1792 Esc while preparing ends cancelled without failure guidance" {
    const job: Self = .{ .started = true, .finished = true, .operation = .install, .failure = error.Cancelled, .cancelling = true };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try job.writeReport(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Upgrade cancelled; nothing changed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "failed") == null);
    try std.testing.expect(!job.hasGuidance());
}

test "the Upgrade ending uses every Host result not the selected Store supersession" {
    var entries = [_]@import("host_restart_all.zig").Entry{
        .{ .socket = "", .store = "/selected", .state = .{ .outcome = .superseded } },
        .{ .socket = "", .store = "/other", .state = .{ .outcome = .{ .ready = .{ .instance = @splat(1), .pid = 42 } } } },
    };
    const job: Self = .{ .finished = true, .checked = news_check, .result = .{
        .installation = .{ .installed = .{ .operation_build = "/build", .selected_after = "/build", .selected_version = .{ .schema = 60, .patch = 1 } } },
        .hosts = .{ .entries = &entries, .version = .{ .schema = 60, .patch = 1 } },
        .store = "/selected",
    } };
    try std.testing.expectEqualDeep(upgrade_status.Ended{ .upgraded = .{ .version = .{ .schema = 60, .patch = 1 }, .restarted = true } }, job.ending());
}

test "Upgrade publication version survives cancellation and restart discovery or transport failure" {
    for ([_]anyerror{ error.Cancelled, error.HostRestartFailed, error.AccessDenied }) |failure| {
        var job: Self = .{ .started = true, .operation = .install, .checked = news_check, .result = .{
            .installation = .{ .installed = .{ .operation_build = "/operation", .selected_after = "/pinned/target", .selected_version = .{ .schema = 61, .patch = 2 } } },
            .hosts = .{ .failure = failure },
            .store = "/store",
        } };
        job.finish();
        const ended = job.status().ended.how;
        try std.testing.expectEqualDeep(upgrade_status.Version{ .schema = 61, .patch = 2 }, if (failure == error.Cancelled) ended.upgraded.version else ended.incompatible);
        try std.testing.expect(job.hasGuidance());
    }
}

test "background discovery domain covers version order publication failure cancellation and once-only retirement" {
    const Candidate = @import("release_candidate.zig").Version;
    const running_version = Candidate.parse(@import("transport_options").version) catch null;
    const newer_candidate = if (running_version) |running| running.order(.{ .schema = 999, .patch = 2 }) == .lt else false;
    for ([_]struct { []const u8, Candidate, bool }{
        .{ "0.60.1", .{ .schema = 60, .patch = 0 }, false },
        .{ "0.60.1", .{ .schema = 60, .patch = 1 }, false },
        .{ "0.60.1", .{ .schema = 60, .patch = 2 }, true },
        .{ "0.60.1", .{ .schema = 61, .patch = 0 }, true },
        .{ "0.60.1", .{ .schema = 59, .patch = 999 }, false },
        .{ "source", .{ .schema = 60, .patch = 2 }, false },
    }) |case| {
        const available = newerRelease(case[0], case[1]);
        try std.testing.expectEqual(case[2], available != null);
        if (available) |found| try std.testing.expectEqualDeep(upgrade_status.Version{ .schema = case[1].schema, .patch = case[1].patch }, found);
    }
    const Worker = struct {
        fn run(raw: *anyopaque, _: *ClientTask) !void {
            const job: *Self = @ptrCast(@alignCast(raw));
            std.debug.assert(job.operation == .discover);
        }
    };
    for (0..4) |case| {
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        var job: Self = .{ .init = init, .allocator = std.testing.allocator, .started = true, .operation = .discover, .discovery_attempted = true, .candidate = try release_candidate.fromEffectiveUrl(std.testing.allocator, "https://fixture/releases/tag/v0.999.2", "https://fixture", "https://fixture", "linux-x86_64") };
        defer job.deinit();
        try std.testing.expectEqual(@as(?upgrade_status.Version, null), job.availability());
        try job.task.start(init.io, &job, Worker.run);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &job.task, ClientTask.completed);
        if (case == 1) job.cancel();
        if (case == 2) job.failure = error.ConnectionRefused;
        if (case == 3) {
            job.candidate.?.deinit(std.testing.allocator);
            job.candidate = null;
        }
        try std.testing.expect(try job.advanceWith(Worker.run));
        try std.testing.expect(job.finished and job.operation == .discover);
        try std.testing.expect(job.task.thread == null and job.checked == null and job.result == null);
        try std.testing.expectEqual(Outcome.unchanged, job.outcome);
        try std.testing.expectEqual(case == 0 and newer_candidate, job.availability() != null);
        job.deinit();
        try std.testing.expect(job.discovery_attempted);
        try std.testing.expect(!job.started and !job.cancelling);
    }
}

test "discovery handoff domain retains validated candidate and transport only for its accepted attempt" {
    const Worker = struct {
        var release_worker: std.atomic.Value(bool) = .init(false);
        var fail: bool = false;

        fn run(raw: *anyopaque, _: *ClientTask) !void {
            const job: *Self = @ptrCast(@alignCast(raw));
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &release_worker, test_poll.isSet);
            job.download.family = .ipv4;
            if (fail) {
                job.download.stderr = try job.allocator.dupe(u8, "curl fixture final");
                return error.ReleaseDownloadFailed;
            }
            job.candidate = try release_candidate.fromEffectiveUrl(job.allocator, "https://fixture/releases/tag/v0.999.2", "https://fixture", "https://fixture", "linux-x86_64");
            job.candidate.?.sha256 = @splat(7);
        }
    };
    for ([_]bool{ false, true }) |background_finished| for ([_]bool{ false, true }) |discovery_failed| for ([_]bool{ false, true }) |cancelled| {
        var init: std.process.Init = undefined;
        init.io = std.testing.io;
        var job: Self = .{ .init = init, .allocator = std.testing.allocator, .started = true, .operation = .discover, .discovery_attempted = true };
        defer job.deinit();
        Worker.release_worker.store(background_finished, .release);
        Worker.fail = discovery_failed;
        defer Worker.release_worker.store(true, .release);
        try job.task.start(init.io, &job, Worker.run);
        if (background_finished) {
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &job.task, ClientTask.completed);
            try std.testing.expect(try job.advance());
        } else {
            try std.testing.expect(!try job.retireDiscovery(cancelled));
            try std.testing.expect(job.discovering() and job.task.thread != null and job.discovery_adopted);
            Worker.release_worker.store(true, .release);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &job.task, ClientTask.completed);
        }
        const candidate_url = if (job.candidate) |candidate| candidate.archive_url.ptr else null;
        try std.testing.expect(try job.retireDiscovery(cancelled));
        try std.testing.expect(!job.discovering() and job.task.thread == null and job.result == null and job.checked == null);
        if (cancelled or (!background_finished and discovery_failed)) {
            try std.testing.expect(job.started and job.finished and job.candidate == null);
            const ended = job.status().ended;
            try std.testing.expectEqual(Outcome.unchanged, ended.outcome);
            try std.testing.expectEqualDeep(if (cancelled) upgrade_status.Ended.cancelled else upgrade_status.Ended{ .failed = .download }, ended.how);
            if (!cancelled) try std.testing.expectEqualStrings("curl fixture final", job.download.stderr.?);
        } else if (discovery_failed) {
            try std.testing.expect(!job.started and !job.finished and job.candidate == null);
            try std.testing.expectEqual(.automatic, job.download.family);
            try std.testing.expect(job.download.stderr == null);
        } else {
            try std.testing.expect(!job.started and !job.finished and !job.cancelling);
            try std.testing.expectEqual(candidate_url.?, job.candidate.?.archive_url.ptr);
            try std.testing.expectEqual(.ipv4, job.download.family);
            try std.testing.expectEqual(@as([32]u8, @splat(7)), job.candidate.?.sha256);
            try std.testing.expect(!job.task.cancellation.stopped.load(.acquire));
            try std.testing.expectEqual(.open, job.gate.load(.acquire));
        }
        job.deinit();
        try std.testing.expect(job.candidate == null and job.download.stderr == null and !job.started);
        try std.testing.expectEqual(.automatic, job.download.family);
    };
}

test "SH-76 Upgrade job adapts joined errors and receipts through the shared owner" {
    const cases = [_]struct { anyerror, upgrade_run.Cause }{
        .{ error.Cancelled, .cancelled }, // #1792: a worker cancellation is the run's cancelled cause.
        .{ error.ReleaseDownloadFailed, .download },
        .{ error.InvalidReleaseVersion, .release },
        .{ error.ReleaseChecksumMismatch, .preparation },
        .{ error.AccessDenied, .other },
    };
    for (cases) |row| for ([_]bool{ false, true }) |has_check| {
        const job: Self = .{ .operation = .install, .checked = if (has_check) news_check else null, .failure = row[0] };
        const value = job.facts();
        try std.testing.expectEqual(row[1], if (has_check) value.prepared.?.failed else value.selection.?.failed);
    };
    for ([_]bool{ false, true }) |changed| for ([_]bool{ false, true }) |has_check| {
        var result = test_result;
        if (!changed) result.installation = .{ .unchanged = result.installation.receipt() };
        const job: Self = .{ .operation = .install, .checked = if (has_check) news_check else null, .result = result };
        const value = job.facts();
        try std.testing.expectEqualDeep(upgrade_run.Published{ .changed = changed, .selected = .{ .schema = 60, .patch = 1 } }, value.published.?.ok);
        try std.testing.expectEqual(@as(usize, 1), value.hosts.?.ok.counts.failed);
        try std.testing.expect(value.hosts.?.ok.guidance);
    };
}
