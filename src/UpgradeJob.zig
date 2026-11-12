//! The app settings Version row's joined worker: check, then install.
//! The owner keeps this value at a stable address from begin through
//! completion, polls `advance` and tells the overview's core its `status`. The
//! full check and receipts print on exit.
const std = @import("std");
const upgrade = @import("upgrade.zig");
const installation_path = @import("installation_path.zig");
const caller_error = @import("caller_error.zig");
const ClientTask = @import("ClientTask.zig");
const upgrade_status = @import("upgrade_status.zig");
const Self = @This();

pub const Outcome = @import("session_upgrade.zig").Outcome;
const Operation = enum { check, install };

init: std.process.Init = undefined,
store: []const u8 = "",
allocator: std.mem.Allocator = undefined,
task: ClientTask = .{},
phase: std.atomic.Value(upgrade.Phase) = .init(.checking),
/// Who decided the run first: Esc cancelling it, or the worker committing
/// to publication. The one owner of whether Esc may still cancel.
gate: std.atomic.Value(enum(u8) { open, cancelled, committed }) = .init(.open),
operation: Operation = .check,
checked: ?upgrade.Check = null,
result: ?upgrade.Result = null,
cleanup: upgrade.CleanupReceipts = .{},
failure: ?anyerror = null,
outcome: Outcome = .unchanged,
/// A stop was asked for: an Esc that `gate` let through, or leaving the
/// overview, which stops the run whatever `gate` says.
cancelling: bool = false,
started: bool = false,
finished: bool = false,

/// The owner and its init/store must outlive the worker. Never move the job
/// between begin and join. Call deinit even when begin fails.
pub fn begin(self: *Self, init: std.process.Init, store: []const u8) !void {
    std.debug.assert(!self.started and self.task.thread == null);
    self.init = init;
    self.store = store;
    self.allocator = init.gpa;
    self.started = true;
    // Esc came while the overview settled its Host work: nothing checks.
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
        .check => self.checked = try upgrade.check(self.init, self.allocator, self.store, &task.cancellation),
        .install => self.result = try upgrade.install(self.init, self.allocator, &self.checked.?, &task.cancellation, .{ .context = self, .report = progress }, &self.cleanup),
    }
}

fn progress(raw: *anyopaque, phase: upgrade.Phase) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (phase == .publishing) {
        // Publication commits the run unless Esc closed the gate first;
        // then the worker stops itself before it publishes.
        if (self.gate.cmpxchgStrong(.open, .committed, .acq_rel, .acquire) != null) {
            self.task.cancellation.requestStop();
            return;
        }
    }
    self.phase.store(phase, .release);
}

/// Poll, join completed work, and automatically install an eligible check.
/// Worker failures are retained for status/writeReport rather than replacing
/// a caller's primary input, output or terminal-restoration failure.
pub fn advance(self: *Self) !bool {
    return self.advanceWith(work);
}

fn advanceWith(self: *Self, worker: ClientTask.Run) !bool {
    std.debug.assert(self.started);
    if (self.finished) return true;
    if (!self.task.completed()) return false;
    self.joinWorker();
    if (self.operation == .check and self.failure == null and !self.cancelling) {
        if (self.checked) |*checked| if (upgrade.canInstall(checked)) {
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
    if (self.operation == .install) self.outcome = if (self.result) |*result| if (upgrade.compatible(result)) .compatible else .incompatible else .unchanged;
    self.phase.store(.finished, .release);
    self.finished = true;
}

/// Esc: cancels only while nothing is published. The worker and Esc race
/// on `gate`, so whichever comes first holds; once publication committed,
/// Esc is refused and the status row hears the publication. One made
/// before `begin` holds: the run then ends without checking.
pub fn cancel(self: *Self) void {
    if (self.finished) return;
    if (self.gate.cmpxchgStrong(.open, .cancelled, .acq_rel, .acquire)) |gate| if (gate == .committed) return;
    self.cancelling = true;
    if (self.started) self.task.cancel();
}

/// Leaving the overview: stops the run wherever it is, publication or not.
fn abandon(self: *Self) void {
    if (self.finished) return;
    self.cancelling = true;
    if (self.started) self.task.cancel();
}

/// On a fatal UI exit, preserve the joined outcome for writeReport before
/// deinit. The caller retains its own primary error independently.
pub fn settle(self: *Self) void {
    if (!self.started or self.finished) return;
    self.abandon();
    self.joinWorker();
    self.finish();
}

pub fn deinit(self: *Self) void {
    self.settle();
    if (self.result) |*result| result.deinit(self.allocator);
    if (self.checked) |*checked| checked.deinit(self.allocator);
    self.* = .{};
}

/// Where the run stands now, whole: what the core shows and decides by.
/// `working` counts the Host's Sessions at work. A release the selected
/// build already is, with no older Host to restart, installs quietly: the
/// check goes on until it ends up to date.
pub fn status(self: *const Self, working: usize) upgrade_status.Run {
    if (self.finished) return .{ .ended = .{ .how = self.ending(), .outcome = self.outcome } };
    if (self.cancelling) return .cancelling;
    if (self.operation == .install) if (self.checked) |*checked| if (!current(checked)) return .{ .installing = .{
        .found = .{ .version = version(checked.candidate.version), .host = if (checked.host == .absent) .none else .{ .running = working } },
        .step = switch (self.phase.load(.acquire)) {
            .checking, .preparing, .finished => .preparing,
            .publishing => .publishing,
            .stopping, .awaiting_retirement, .starting, .verifying => .restarting,
        },
    } };
    return .checking;
}

/// The selected build already is the release, or newer, and no running
/// Host would restart onto it, so the run has nothing to show until it
/// ends. A newer selected build is never restarted onto the older release.
fn current(checked: *const upgrade.Check) bool {
    if (!upgrade.holdsRelease(checked)) return false;
    if (checked.selected.released.version.order(checked.candidate.version) == .gt) return true;
    return !(checked.host == .managed and checked.host.managed.version.order(checked.candidate.version) == .lt);
}

fn version(of: @FieldType(@FieldType(upgrade.Check, "candidate"), "version")) upgrade_status.Version {
    return .{ .schema = of.schema, .patch = of.patch };
}

fn ending(self: *const Self) upgrade_status.Ended {
    const checked = &(self.checked orelse return if (self.cancelling) .cancelled else .failed);
    const release = version(checked.candidate.version);
    if (self.result) |*result| {
        if (!upgrade.compatible(result)) return .{ .incompatible = release };
        if (result.activation == .superseded) return .superseded;
        const restarted = result.activation == .ready;
        if (result.installation == .unchanged and !restarted) return .{ .up_to_date = release };
        return .{ .upgraded = .{ .version = release, .restarted = restarted } };
    }
    if (self.cancelling) return .cancelled;
    if (self.failure != null) return .failed;
    return .{
        .refused = switch (checked.selected) {
            .absent => .first_install,
            .source => .source_build,
            .unknown_managed => .unknown_build,
            .ineligible => .package_managed,
            // An eligible check installs, so it ends with a result or a failure.
            .released => unreachable,
        },
    };
}

/// The concise but durable installation and activation receipt for an ordinary
/// exit or a subsequent command. The full check remains in writeReport.
pub fn writeReceipt(self: *const Self, writer: *std.Io.Writer) !void {
    std.debug.assert(!self.started or self.finished);
    if (self.result) |*result| try upgrade.writeResult(writer, result);
    // A shell that finds another rui first still needs telling.
    if (self.checked) |*checked| try installation_path.write(writer, &checked.path, checked.home);
    try self.cleanup.write(writer);
}

/// The publication's pinned selection, never PATH or this running image.
/// An activation-only run has installed nothing and must not replace the TUI.
pub fn relaunchBuild(self: *const Self) ?[]const u8 {
    std.debug.assert(!self.started or self.finished);
    const result = &(self.result orelse return null);
    if (result.installation != .installed) return null;
    return result.installation.receipt().selected_after;
}

pub fn hasGuidance(self: *const Self) bool {
    return self.failure != null or self.cleanup.any() or
        (if (self.result) |*result| upgrade.hasGuidance(result) else false) or
        (if (self.checked) |checked| checked.path.state != .selected else false);
}

/// Read only after finished/settle; always render the actual publication and
/// activation receipt and copied cleanup facts, including on cancellation.
pub fn writeReport(self: *const Self, writer: *std.Io.Writer) !void {
    std.debug.assert(!self.started or self.finished);
    if (self.checked) |*checked| try upgrade.writeCheck(writer, checked);
    if (self.result) |*result| {
        try writer.writeAll("\n");
        try upgrade.writeResult(writer, result);
    }
    if (self.failure) |err| {
        try writer.print("\nUpgrade {s} failed: {s}\n", .{ if (self.operation == .check) "check" else "installation", failureWords(err) });
        if (self.operation == .install and self.result == null) try writer.writeAll("No completed installation receipt; inspect the selected command and Host before retrying.\n");
    } else if (self.cancelling and self.result == null) {
        try writer.writeAll("\nUpgrade cancelled before installation.\n");
    }
    try self.cleanup.write(writer);
    if (self.outcome == .incompatible) try writer.writeAll("\nThis client cannot safely resume Host requests. Keep the draft and recovery handles; use the selected Rui in a new terminal. Do not resend indeterminate work.\n");
}

/// Why a run failed, in words: the caller code's own for the release and
/// preparation failures it names; anything else, such as a network or
/// file fault, only that it did not finish.
fn failureWords(err: anyerror) []const u8 {
    return switch (caller_error.of(err)) {
        .upgrade_release_invalid, .upgrade_preparation_failed, .upgrade_ineligible => |code| caller_error.facts(code).says,
        else => "Rui could not finish it. Check network access and disk space, then select Version in app settings again.",
    };
}

test "the Upgrade worker wipes its private Host snapshot before freeing with or without an install result" {
    const Capturing = struct {
        backing: std.mem.Allocator,
        private: ?[*]u8 = null,
        freed: usize = 0,
        wiped: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }

        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.backing.rawAlloc(len, alignment, ret);
        }

        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.backing.rawResize(memory, alignment, len, ret);
        }

        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.backing.rawRemap(memory, alignment, len, ret);
        }

        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.private == memory.ptr) {
                self.freed += 1;
                self.wiped = std.mem.allEqual(u8, memory, 0);
            }
            self.backing.rawFree(memory, alignment, ret);
        }
    };
    for ([_]bool{ false, true }) |installed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var capture: Capturing = .{ .backing = arena.allocator() };
        const allocator = capture.allocator();
        const private = try allocator.dupe(u8, "PRIVATE_SYNTHETIC_TOKEN=panel-cleanup-only");
        capture.private = private.ptr;
        const entries = try allocator.alloc([]const u8, 1);
        entries[0] = private;
        var self: Self = .{
            .init = undefined,
            .store = "unused",
            .allocator = allocator,
            .checked = .{
                .candidate = .{ .version = .{ .schema = 99, .patch = 0 }, .tag = try allocator.dupe(u8, "v0.99.0"), .archive_name = try allocator.dupe(u8, "fixture"), .archive_url = try allocator.dupe(u8, "fixture"), .checksum_url = try allocator.dupe(u8, "fixture"), .sha256 = @splat(0) },
                .selected = .absent,
                .host = .{ .managed = .{ .observed = undefined, .launch = .{ .options = &.{} }, .version = .{ .schema = 99, .patch = 0 }, .snapshot = .{ .pid = 0, .started = 0, .executable = private[0..0], .argv = entries[0..0], .environment = entries, .storage = private, .entries = entries } } },
                .home = try allocator.dupe(u8, "/synthetic/home"),
                .store = try allocator.dupe(u8, "/synthetic/store"),
                .running_executable = try allocator.dupeSentinel(u8, "/synthetic/rui", 0),
            },
        };
        if (installed) self.result = .{ .installation = .{ .unchanged = .{ .operation_build = try allocator.dupe(u8, "/synthetic/build"), .selected_after = try allocator.dupe(u8, "/synthetic/build") } }, .activation = .not_needed, .store = try allocator.dupe(u8, "/synthetic/store") };
        self.deinit();
        try std.testing.expect(capture.wiped);
        try std.testing.expectEqual(@as(usize, 1), capture.freed);
        try std.testing.expect(self.result == null and self.checked == null);
        self.deinit();
        try std.testing.expectEqual(@as(usize, 1), capture.freed);
    }
}

const test_result: upgrade.Result = .{
    .installation = .{ .installed = .{ .operation_build = "/synthetic/installed", .selected_after = "/synthetic/installed" } },
    .activation = .cancelled,
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
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "publication was not rolled back") != null);
    var receipt_bytes: [4096]u8 = undefined;
    var receipt = std.Io.Writer.fixed(&receipt_bytes);
    try job.writeReceipt(&receipt);
    try std.testing.expect(std.mem.indexOf(u8, receipt.buffered(), "Installed Rui. Complete build: /synthetic/installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.buffered(), "publication was not rolled back") != null);
    // Fixture strings are static, not owned allocations.
    job.result = null;
}

test "a failed run says why in plain words, not an error name" {
    const cases = [_]struct { Operation, anyerror, []const u8 }{
        .{ .check, error.InvalidReleaseVersion, "Upgrade check failed: Published stable release metadata or platform assets could not be validated." },
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
    // Esc after the worker reached publication: refused, nothing stops.
    {
        var job: Self = .{ .started = true, .operation = .install };
        progress(&job, .preparing);
        progress(&job, .publishing);
        job.cancel();
        try std.testing.expect(!job.cancelling);
        try std.testing.expect(!job.task.cancellation.stopped.load(.acquire));
        try std.testing.expectEqual(upgrade.Phase.publishing, job.phase.load(.acquire));
    }
    // Esc first: the worker's next step to publication stops itself.
    {
        var job: Self = .{ .started = true, .operation = .install };
        progress(&job, .preparing);
        job.cancel();
        try std.testing.expect(job.cancelling);
        progress(&job, .publishing);
        try std.testing.expect(job.task.cancellation.stopped.load(.acquire));
        try std.testing.expectEqual(upgrade.Phase.preparing, job.phase.load(.acquire));
    }
    // Leaving the overview still cancels after publication.
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
    // Esc while the overview still settles its own Host work.
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
        .host = .absent,
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
        // These checks and receipts use static fixture strings.
        job.checked = null;
        job.result = null;
        job.deinit();
    }
}

const news_check: upgrade.Check = .{
    .candidate = .{ .version = .{ .schema = 60, .patch = 1 }, .tag = "v0.60.1", .archive_name = "fixture", .archive_url = "fixture", .checksum_url = "fixture", .sha256 = @splat(0) },
    .selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 59, .patch = 7 } } },
    .host = .absent,
    .home = "/synthetic/home",
    .store = "/synthetic/store",
    .running_executable = "/synthetic/rui",
};

test "the run's status: checking, the release found, each restart step, then how it ended" {
    var job: Self = .{ .started = true, .checked = news_check };
    // Still checking, whatever the check has read.
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status(2));
    job.operation = .install;
    job.phase.store(.preparing, .release);
    const found: upgrade_status.Found = .{ .version = .{ .schema = 60, .patch = 1 }, .host = .none };
    try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = found } }, job.status(2));
    // A Host it would restart counts the Sessions at work.
    job.checked.?.host = .{ .unsupported = .incompatible };
    try std.testing.expectEqual(upgrade_status.Host{ .running = 2 }, job.status(2).installing.found.host);
    job.checked.?.host = .absent;
    for ([_]struct { upgrade.Phase, upgrade_status.Step }{
        .{ .publishing, .publishing }, .{ .stopping, .restarting }, .{ .awaiting_retirement, .restarting }, .{ .starting, .restarting }, .{ .verifying, .restarting },
    }) |case| {
        job.phase.store(case[0], .release);
        try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = found, .step = case[1] } }, job.status(2));
    }
    job.result = .{ .installation = .{ .installed = .{ .operation_build = "/b", .selected_after = "/b" } }, .activation = .{ .ready = .{ .instance = @splat(0), .pid = 1 } }, .store = "/s" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 1 }, .restarted = true } }, .outcome = .compatible } }, job.status(2));
    job.result = null;
    job.checked = null;
}

test "a stop asked for shows until the run ends, before the worker starts and while it prepares, and not once it published" {
    // Esc while the overview still settles its own Host work.
    var waiting: Self = .{};
    try std.testing.expectEqual(upgrade_status.Run.checking, waiting.status(0));
    waiting.cancel();
    try std.testing.expectEqual(upgrade_status.Run.cancelling, waiting.status(0));
    // Esc while preparing.
    var preparing: Self = .{ .started = true, .operation = .install, .checked = news_check };
    progress(&preparing, .preparing);
    preparing.cancel();
    try std.testing.expectEqual(upgrade_status.Run.cancelling, preparing.status(0));
    preparing.checked = null;
    // Esc after publication committed: refused, and the status says what happens.
    var published: Self = .{ .started = true, .operation = .install, .checked = news_check };
    progress(&published, .publishing);
    published.cancel();
    try std.testing.expectEqual(upgrade_status.Step.publishing, published.status(0).installing.step);
    published.checked = null;
}

test "a release already selected but not yet running in the Host is found, so its restart shows" {
    var entries: [0][]const u8 = .{};
    var private: [0]u8 = .{};
    const snapshot: @import("host_identity.zig").Snapshot = .{ .pid = 0, .started = 0, .executable = private[0..0], .argv = entries[0..0], .environment = &entries, .storage = &private, .entries = &entries };
    for ([_]struct { host: u16, found: bool }{ .{ .host = 0, .found = true }, .{ .host = 1, .found = false } }) |case| {
        var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
        job.checked.?.selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 60, .patch = 1 } } };
        job.checked.?.host = .{ .managed = .{ .observed = undefined, .launch = .{ .options = &.{} }, .version = .{ .schema = 60, .patch = case.host }, .snapshot = snapshot } };
        job.phase.store(.stopping, .release);
        if (case.found) {
            // An older Host restarts onto it: the status row says so.
            try std.testing.expectEqualDeep(upgrade_status.Run{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 1 }, .host = .{ .running = 3 } }, .step = .restarting } }, job.status(3));
        } else {
            // The Host already runs it: nothing to show until it ends.
            try std.testing.expectEqual(upgrade_status.Run.checking, job.status(3));
        }
        job.checked = null;
    }
}

test "how a run ends, as the status bar names it" {
    const installed: @FieldType(upgrade.Result, "installation") = .{ .installed = .{ .operation_build = "/b", .selected_after = "/b" } };
    const unchanged: @FieldType(upgrade.Result, "installation") = .{ .unchanged = .{ .operation_build = "/b", .selected_after = "/b" } };
    const ready: @FieldType(upgrade.Result, "activation") = .{ .ready = .{ .instance = @splat(0), .pid = 1 } };
    const v: upgrade_status.Version = .{ .schema = 60, .patch = 1 };
    const already_ready: @FieldType(upgrade.Result, "activation") = .{ .already_ready = .{ .instance = @splat(0), .pid = 1 } };
    const Case = struct { job: Self, ended: upgrade_status.Ended, outcome: Outcome };
    for ([_]Case{
        // Installed: restarted only when the new Host came up.
        .{ .job = .{ .operation = .install, .result = .{ .installation = installed, .activation = ready, .store = "" } }, .ended = .{ .upgraded = .{ .version = v, .restarted = true } }, .outcome = .compatible },
        .{ .job = .{ .operation = .install, .result = .{ .installation = installed, .activation = .not_needed, .store = "" } }, .ended = .{ .upgraded = .{ .version = v, .restarted = false } }, .outcome = .compatible },
        // Installed and published, though the run was cancelled after.
        .{ .job = .{ .operation = .install, .cancelling = true, .result = .{ .installation = installed, .activation = .cancelled, .store = "" } }, .ended = .{ .upgraded = .{ .version = v, .restarted = false } }, .outcome = .compatible },
        // Already the selected build: up to date, unless the Host restarted
        // onto it.
        // Up to date still admits the Host it left: a retry after an
        // Upgrade blocked requests lifts the block.
        .{ .job = .{ .operation = .install, .result = .{ .installation = unchanged, .activation = .not_needed, .store = "" } }, .ended = .{ .up_to_date = v }, .outcome = .compatible },
        .{ .job = .{ .operation = .install, .result = .{ .installation = unchanged, .activation = already_ready, .store = "" } }, .ended = .{ .up_to_date = v }, .outcome = .compatible },
        .{ .job = .{ .operation = .install, .result = .{ .installation = unchanged, .activation = ready, .store = "" } }, .ended = .{ .upgraded = .{ .version = v, .restarted = true } }, .outcome = .compatible },
        // Another install selected a newer build: not up to date with the
        // older candidate, and nothing restarted.
        .{ .job = .{ .operation = .install, .result = .{ .installation = unchanged, .activation = .superseded, .store = "" } }, .ended = .superseded, .outcome = .compatible },
        // The Host left cannot serve this client.
        .{ .job = .{ .operation = .install, .result = .{ .installation = installed, .activation = .{ .client_incompatible = 123 }, .store = "" } }, .ended = .{ .incompatible = v }, .outcome = .incompatible },
        .{ .job = .{ .operation = .install, .result = .{ .installation = installed, .activation = .{ .unconfirmed = .verifying }, .store = "" } }, .ended = .{ .incompatible = v }, .outcome = .incompatible },
        .{ .job = .{ .operation = .install, .result = .{ .installation = unchanged, .activation = .replacement_observed, .store = "" } }, .ended = .{ .incompatible = v }, .outcome = .incompatible },
        // No receipt: a cancel says so before a failure does.
        .{ .job = .{ .operation = .install, .cancelling = true, .failure = error.Cancelled }, .ended = .cancelled, .outcome = .unchanged },
        .{ .job = .{ .operation = .install, .failure = error.ReleaseChecksumMismatch }, .ended = .failed, .outcome = .unchanged },
        .{ .job = .{ .failure = error.ConnectionRefused }, .ended = .failed, .outcome = .unchanged },
        .{ .job = .{ .cancelling = true }, .ended = .cancelled, .outcome = .unchanged },
    }) |case| {
        var job = case.job;
        job.started = true;
        job.checked = news_check;
        job.finish();
        try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = case.ended, .outcome = case.outcome } }, job.status(0));
        job.result = null;
        job.checked = null;
    }
}

test "a check that may not install here names why" {
    for ([_]struct { @FieldType(upgrade.Check, "selected"), upgrade_status.Refusal }{
        .{ .absent, .first_install },
        .{ .{ .source = "/src" }, .source_build },
        .{ .{ .unknown_managed = "/opt" }, .unknown_build },
        .{ .ineligible, .package_managed },
    }) |case| {
        var job: Self = .{ .started = true, .checked = news_check };
        job.checked.?.selected = case[0];
        job.finish();
        try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .refused = case[1] }, .outcome = .unchanged } }, job.status(0));
        job.checked = null;
    }
}

test "a newer build already selected installs quietly: no older release found, then superseded" {
    var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
    job.checked.?.selected.released.version = .{ .schema = 60, .patch = 2 };
    job.phase.store(.publishing, .release);
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status(0));
    job.result = .{ .installation = .{ .unchanged = .{ .operation_build = "/b", .selected_after = "/b" } }, .activation = .superseded, .store = "" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .superseded, .outcome = .compatible } }, job.status(0));
    job.result = null;
    job.checked = null;
}

test "the selected build already current installs quietly: no found release, then up to date" {
    var job: Self = .{ .started = true, .operation = .install, .checked = news_check };
    job.checked.?.selected.released.version = .{ .schema = 60, .patch = 1 };
    job.phase.store(.publishing, .release);
    try std.testing.expectEqual(upgrade_status.Run.checking, job.status(0));
    job.result = .{ .installation = .{ .unchanged = .{ .operation_build = "/b", .selected_after = "/b" } }, .activation = .not_needed, .store = "" };
    job.finish();
    try std.testing.expectEqualDeep(upgrade_status.Run{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 60, .patch = 1 } }, .outcome = .compatible } }, job.status(0));
    job.result = null;
    job.checked = null;
}

test "relaunch uses only an installed receipt selection and keeps every guidance category" {
    const Installation = @import("Installation.zig");
    const receipt: Installation.Receipt = .{ .operation_build = "/downloaded/target", .selected_after = "/published/selection" };
    for ([_]bool{ false, true }) |installed| {
        var job: Self = .{ .finished = true, .result = .{ .installation = if (installed) .{ .installed = receipt } else .{ .unchanged = receipt }, .activation = .not_needed, .store = "/store" } };
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
        var checked: upgrade.Check = undefined;
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
    const receipt: Installation.Receipt = .{ .operation_build = "/prepared", .selected_after = "/selected" };
    const info = @typeInfo(HostLifecycle.ActivationOutcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const activation = @unionInit(HostLifecycle.ActivationOutcome, name, std.mem.zeroes(Payload));
        for ([_]bool{ false, true }) |installed| {
            const result: upgrade.Result = .{
                .installation = if (installed) .{ .installed = receipt } else .{ .unchanged = receipt },
                .activation = activation,
                .store = "/store",
            };
            const job: Self = .{ .finished = true, .result = result };
            try std.testing.expectEqual(upgrade.hasGuidance(&result), job.hasGuidance());
        }
    }
}
