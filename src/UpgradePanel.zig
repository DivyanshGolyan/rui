//! The /upgrade command's joined worker. The owner keeps this value at a
//! stable address from begin through completion and continues servicing input.
const std = @import("std");
const upgrade = @import("upgrade.zig");
const ClientTask = @import("ClientTask.zig");
const Self = @This();

pub const Outcome = enum { unchanged, compatible, incompatible };
const Operation = enum { check, install };

init: std.process.Init = undefined,
store: []const u8 = "",
allocator: std.mem.Allocator = undefined,
task: ClientTask = .{},
phase: std.atomic.Value(upgrade.Phase) = .init(.checking),
operation: Operation = .check,
checked: ?upgrade.Check = null,
result: ?upgrade.Result = null,
cleanup: upgrade.CleanupReceipts = .{},
failure: ?anyerror = null,
outcome: Outcome = .unchanged,
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

/// Cancellation is a request, never a promise that publication rolled back.
pub fn cancel(self: *Self) void {
    if (!self.started or self.finished) return;
    self.cancelling = true;
    self.task.cancel();
}

/// On a fatal UI exit, preserve the joined outcome for writeReport before
/// deinit. The caller retains its own primary error independently.
pub fn settle(self: *Self) void {
    if (!self.started or self.finished) return;
    self.cancel();
    self.joinWorker();
    self.finish();
}

pub fn deinit(self: *Self) void {
    self.settle();
    if (self.result) |*result| result.deinit(self.allocator);
    if (self.checked) |*checked| checked.deinit(self.allocator);
    self.* = .{};
}

pub fn status(self: *const Self) []const u8 {
    if (!self.started) return "Upgrade idle";
    if (self.finished) {
        const retained = self.cleanup.any();
        if (self.result) |*result| return switch (result.installation) {
            .installed => resultStatus("Upgrade installed", result.activation, retained),
            .unchanged => switch (result.activation) {
                .not_needed, .already_ready, .ready => resultStatus("Upgrade up to date", result.activation, retained),
                else => resultStatus("Upgrade installation unchanged", result.activation, retained),
            },
        };
        if (self.failure != null) {
            if (self.cancelling) return if (retained) "Upgrade cancelled; cleanup retained" else "Upgrade cancelled";
            if (self.operation == .check) return "Upgrade check failed";
            return if (retained) "Upgrade install failed; cleanup retained" else "Upgrade install failed";
        }
        if (self.cancelling) return "Upgrade cancelled before installation";
        return "Upgrade ineligible for this installation";
    }
    if (self.cancelling) return "Upgrade cancellation requested; waiting for outcome";
    return switch (self.phase.load(.acquire)) {
        .checking => "Upgrade: checking release and installation · Esc cancels",
        .preparing => "Upgrade: preparing and verifying · Esc cancels",
        .publishing => "Upgrade: publishing; Esc cancels, not rollback",
        .stopping => "Upgrade: stopping Host · Esc cancels",
        .awaiting_retirement => "Upgrade: waiting for Host retirement · Esc cancels",
        .starting => "Upgrade: starting Host · Esc cancels",
        .verifying => "Upgrade: verifying Host compatibility · Esc cancels",
        .finished => "Upgrade: finishing",
    };
}

fn resultStatus(comptime installation: []const u8, activation: @FieldType(upgrade.Result, "activation"), retained: bool) []const u8 {
    inline for (.{ false, true }) |has_cleanup| {
        if (retained == has_cleanup) return switch (activation) {
            .not_needed => installation ++ "; activation not needed" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .superseded => installation ++ "; activation superseded" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .already_ready => installation ++ "; Host already ready" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .ready => installation ++ "; Host ready" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .unsupported => installation ++ "; activation unsupported" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .replacement_observed => installation ++ "; replacement Host observed" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .cancelled => installation ++ "; activation cancelled" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .failed => installation ++ "; activation failed" ++ (if (has_cleanup) "; cleanup retained" else ""),
            .unconfirmed => installation ++ "; activation unconfirmed" ++ (if (has_cleanup) "; cleanup retained" else ""),
        };
    }
    unreachable;
}

/// Write into a caller-owned bounded writer. The caller may retain its buffer
/// after deinit; WriteFailed means the supplied buffer was too small.
pub fn writeSummary(self: *const Self, writer: *std.Io.Writer) !void {
    try writer.writeAll(self.status());
    if (!self.finished) return;
    if (self.failure) |err| try writer.print(" ({s})", .{@errorName(err)});
    if (self.result == null and self.failure == null and !self.cancelling) {
        if (self.checked) |*checked| switch (checked.selected) {
            .source, .unknown_managed, .absent => try writer.writeAll("; use the release installer"),
            .ineligible => try writer.writeAll("; use its installer or package manager"),
            .released => {},
        };
    }
    if (self.cleanup.any()) try writer.writeAll("; exit to see retained cleanup paths");
}

/// The concise but durable installation and activation receipt for an ordinary
/// exit or a subsequent command. The full check remains in writeReport.
pub fn writeReceipt(self: *const Self, writer: *std.Io.Writer) !void {
    std.debug.assert(!self.started or self.finished);
    if (self.result) |*result| try upgrade.writeResult(writer, result);
    try self.cleanup.write(writer);
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
        try writer.print("\nUpgrade {s} ended with {s}.\n", .{ if (self.operation == .check) "check" else "installation", @errorName(err) });
        if (self.operation == .install and self.result == null) try writer.writeAll("No completed installation receipt; inspect the selected command and Host before retrying.\n");
    } else if (self.cancelling and self.result == null) {
        try writer.writeAll("\nUpgrade cancelled before installation.\n");
    }
    try self.cleanup.write(writer);
    if (self.outcome == .incompatible) try writer.writeAll("\nThis client cannot safely resume Host requests. Keep the draft and recovery handles; use the selected Rui in a new terminal. Do not resend indeterminate work.\n");
}

test "upgrade panel owner wipes its private Host snapshot before freeing with or without an install result" {
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
                .running_executable = try allocator.dupe(u8, "/synthetic/rui"),
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
    var summary_bytes: [256]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_bytes);
    try job.writeSummary(&summary);
    try std.testing.expectEqualStrings("Upgrade installed; activation cancelled", summary.buffered());
    // Fixture strings are static, not owned allocations.
    job.result = null;
}

test "upgrade status distinguishes verified current from superseded or cancelled" {
    var result = test_result;
    result.installation = .{ .unchanged = .{ .operation_build = "/synthetic/installed", .selected_after = "/synthetic/installed" } };
    var job: Self = .{ .started = true, .finished = true, .result = result };
    job.result.?.activation = .not_needed;
    try std.testing.expectEqualStrings("Upgrade up to date; activation not needed", job.status());
    job.result.?.activation = .superseded;
    try std.testing.expectEqualStrings("Upgrade installation unchanged; activation superseded", job.status());
    job.result.?.activation = .cancelled;
    try std.testing.expectEqualStrings("Upgrade installation unchanged; activation cancelled", job.status());
    job.result = null; // static fixture storage
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
    var summary_bytes: [4096]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_bytes);
    try job.writeSummary(&summary);
    try std.testing.expect(std.mem.indexOf(u8, summary.buffered(), "ReleaseChecksumMismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.buffered(), "exit to see retained cleanup paths") != null);
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
